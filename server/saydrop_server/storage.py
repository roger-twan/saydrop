import fcntl
import hashlib
import hmac
import os
import secrets
import threading
from contextlib import contextmanager
from datetime import datetime, timedelta
from pathlib import Path
from uuid import uuid4

from sqlalchemy import create_engine, event

from saydrop_server.budget import require_budget
from saydrop_server.config import SERVER_ROOT, Settings
from saydrop_server.errors import ApiError
from saydrop_server.quota import TIMEZONE, bucket_date, quota_payload, reserve_quota

REVISION = 3


def make_engine(path: Path):
    engine = create_engine(f"sqlite:///{path}", connect_args={"check_same_thread": False, "timeout": 5})

    @event.listens_for(engine, "connect")
    def setup(dbapi_connection, _):
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA foreign_keys=ON")
        cursor.execute("PRAGMA busy_timeout=5000")
        cursor.execute("PRAGMA journal_mode=WAL")
        cursor.close()

    return engine


@contextmanager
def process_lock(path: Path):
    """Refuse a second process using the same SQLite, including an accidental extra worker."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(str(path) + ".process.lock", os.O_CREAT | os.O_RDWR, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Saydrop requires one process and one worker") from None
        yield
    finally:
        os.close(descriptor)


def migrate(path: Path) -> None:
    """Explicit command, never a hidden application-startup ALTER/create operation."""
    with process_lock(path):
        # Create sensitive metadata file with restrictive permissions before SQLite opens it.
        fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
        os.close(fd)
        engine = make_engine(path)
        try:
            with engine.connect() as conn:
                conn.exec_driver_sql("BEGIN IMMEDIATE")
                try:
                    current = conn.exec_driver_sql("PRAGMA user_version").scalar_one()
                    if current > REVISION:
                        raise RuntimeError("database revision is newer than this server")
                    for revision in range(current + 1, REVISION + 1):
                        candidates = list((SERVER_ROOT / "migrations").glob(f"{revision:03d}_*.sql"))
                        if len(candidates) != 1:
                            raise RuntimeError("missing or ambiguous migration revision")
                        for statement in candidates[0].read_text().split(";"):
                            if statement.strip():
                                conn.exec_driver_sql(statement)
                        conn.exec_driver_sql(f"PRAGMA user_version={revision}")
                    conn.commit()
                except BaseException:
                    conn.rollback()
                    raise
        finally:
            engine.dispose()


class Store:
    def __init__(self, settings: Settings, wall_clock=None):
        self.settings = settings
        self.clock = wall_clock or (lambda: datetime.now(TIMEZONE))
        self.engine = make_engine(settings.database_path)
        self.lock = threading.RLock()
        with self.engine.connect() as conn:
            if conn.exec_driver_sql("PRAGMA user_version").scalar_one() != REVISION:
                self.engine.dispose()
                raise RuntimeError("run python -m saydrop_server.migrate before startup")

    def now_iso(self) -> str:
        return self.clock().astimezone(TIMEZONE).isoformat()

    @contextmanager
    def transaction(self):
        with self.lock, self.engine.connect() as conn:
            conn.exec_driver_sql("BEGIN IMMEDIATE")
            try:
                yield conn
                conn.commit()
            except BaseException:
                conn.rollback()
                raise

    def digest(self, value: str) -> str:
        return hmac.new(self.settings.token_pepper.get_secret_value().encode(),
                        value.encode(), hashlib.sha256).hexdigest()

    def fingerprint(self, audio: bytes) -> str:
        return hmac.new(self.settings.fingerprint_key.get_secret_value().encode(),
                        audio, hashlib.sha256).hexdigest()

    def register(self, version: str, platform: str) -> tuple[str, str]:
        owner, token, now = str(uuid4()), secrets.token_urlsafe(32), self.now_iso()
        with self.transaction() as conn:
            conn.exec_driver_sql("INSERT INTO installations VALUES (?,?,?,?,?,NULL,?,?)",
                                 (owner, self.digest(token), self.settings.token_key_version,
                                  now, now, version, platform))
        return owner, token

    def authenticate(self, token: str) -> str:
        if len(token) != 43 or not token.isascii():
            raise ApiError("invalid_token", 401)
        digest = self.digest(token)
        with self.transaction() as conn:
            row = conn.exec_driver_sql("SELECT * FROM installations WHERE token_hash=?", (digest,)).mappings().first()
            if row is None or not hmac.compare_digest(row["token_hash"], digest):
                raise ApiError("invalid_token", 401)
            if row["token_key_version"] != self.settings.token_key_version:
                raise ApiError("invalid_token", 401)
            if row["revoked_at"]:
                raise ApiError("installation_revoked", 401)
            return row["id"]

    def _quota(self, conn, owner: str, bucket: str | None = None) -> dict:
        bucket = bucket or bucket_date(self.clock())
        row = conn.exec_driver_sql("SELECT * FROM daily_quotas WHERE installation_id=? AND bucket_date=?",
                                   (owner, bucket)).mappings().first()
        return quota_payload(row, self.clock(), self.settings.daily_quota, bucket)

    def quota(self, owner: str, bucket: str | None = None) -> dict:
        with self.transaction() as conn:
            return self._quota(conn, owner, bucket)

    def _task(self, conn, owner: str, request_id: str) -> dict:
        row = conn.exec_driver_sql("SELECT * FROM transcription_tasks WHERE owner_installation_id=? AND request_id=?",
                                   (owner, request_id)).mappings().first()
        if row is None:
            raise ApiError("not_found", 404)
        return dict(row)

    def status(self, owner: str, request_id: str) -> dict:
        with self.transaction() as conn:
            return self._task(conn, owner, request_id)

    def existing(self, owner: str, request_id: str, fingerprint: str, mode: str):
        with self.transaction() as conn:
            row = conn.exec_driver_sql("SELECT * FROM transcription_tasks WHERE owner_installation_id=? AND request_id=?",
                                       (owner, request_id)).mappings().first()
            if row is None:
                return None
            if not hmac.compare_digest(row["input_fingerprint"], fingerprint) or row["output_mode"] != mode:
                raise ApiError("idempotency_conflict", 409)
            return dict(row)

    def reserve(self, owner: str, request_id: str, fingerprint: str, mode: str) -> tuple[dict, bool]:
        now, bucket = self.now_iso(), bucket_date(self.clock())
        expiry = (self.clock().astimezone(TIMEZONE) + timedelta(days=self.settings.tombstone_days)).isoformat()
        with self.transaction() as conn:
            row = conn.exec_driver_sql("SELECT * FROM transcription_tasks WHERE owner_installation_id=? AND request_id=?",
                                       (owner, request_id)).mappings().first()
            if row:
                if not hmac.compare_digest(row["input_fingerprint"], fingerprint) or row["output_mode"] != mode:
                    raise ApiError("idempotency_conflict", 409)
                return dict(row), False
            require_budget(conn, self.settings, bucket, mode)
            active = conn.exec_driver_sql("SELECT count(*) FROM transcription_tasks WHERE owner_installation_id=? AND status='processing'", (owner,)).scalar_one()
            if active:
                raise ApiError("rate_limited", 429, retryable=True)
            reserve_quota(conn, owner, bucket, self.settings.daily_quota, now)
            conn.exec_driver_sql(
                "INSERT INTO transcription_tasks (request_id,owner_installation_id,idempotency_key,input_fingerprint,output_mode,status,polish_status,quota_bucket_date,reservation_state,created_at,updated_at,tombstone_until) VALUES (?,?,?,?,?,'processing',?,?,'reserved',?,?,?)",
                (request_id, owner, request_id, fingerprint, mode,
                 "pending" if mode == "light_polish" else "not_requested", bucket, now, now, expiry),
            )
            return self._task(conn, owner, request_id), True

    def _release(self, conn, task: dict) -> None:
        if task["reservation_state"] == "reserved" and task["dispatch_marked_at"] is None:
            conn.exec_driver_sql("UPDATE daily_quotas SET reserved=reserved-1,updated_at=? WHERE installation_id=? AND bucket_date=?",
                                 (self.now_iso(), task["owner_installation_id"], task["quota_bucket_date"]))
            conn.exec_driver_sql("UPDATE transcription_tasks SET reservation_state='released' WHERE owner_installation_id=? AND request_id=?",
                                 (task["owner_installation_id"], task["request_id"]))

    def dispatch(self, owner: str, request_id: str) -> bool:
        with self.transaction() as conn:
            task = self._task(conn, owner, request_id)
            if task["status"] != "processing" or task["dispatch_marked_at"]:
                return False
            try:
                units = require_budget(conn, self.settings, task["quota_bucket_date"], task["output_mode"])
            except ApiError:
                self._release(conn, task)
                now = self.now_iso()
                conn.exec_driver_sql("UPDATE transcription_tasks SET status='failed',failure_code='budget_unavailable',terminal_at=?,updated_at=? WHERE owner_installation_id=? AND request_id=?",
                                     (now, now, owner, request_id))
                return False
            now = self.now_iso()
            conn.exec_driver_sql("UPDATE daily_quotas SET reserved=reserved-1,used=used+1,updated_at=? WHERE installation_id=? AND bucket_date=?",
                                 (now, owner, task["quota_bucket_date"]))
            conn.exec_driver_sql("UPDATE transcription_tasks SET dispatch_marked_at=?,reservation_state='used',updated_at=? WHERE owner_installation_id=? AND request_id=?",
                                 (now, now, owner, request_id))
            conn.exec_driver_sql("INSERT INTO budget_ledger VALUES (?,?,?,?,'committed',?,NULL,?,?,NULL)",
                                 (str(uuid4()), owner, request_id, task["quota_bucket_date"], units,
                                  self.settings.budget_config_version, now))
            return True

    def finish(self, owner: str, request_id: str, status: str, polish_status: str,
               *, failure_code: str | None = None, result_expires_at: str | None = None,
               actual_units: int | None = None) -> bool:
        with self.transaction() as conn:
            task = self._task(conn, owner, request_id)
            if task["status"] != "processing":
                return False  # late result after cancellation must be discarded
            self._release(conn, task)
            now = self.now_iso()
            conn.exec_driver_sql("UPDATE transcription_tasks SET status=?,polish_status=?,failure_code=?,result_expires_at=?,terminal_at=?,updated_at=? WHERE owner_installation_id=? AND request_id=?",
                                 (status, polish_status, failure_code, result_expires_at, now, now, owner, request_id))
            if task["dispatch_marked_at"]:
                if isinstance(actual_units, int) and not isinstance(actual_units, bool) and actual_units >= 0:
                    conn.exec_driver_sql("UPDATE budget_ledger SET state='settled',actual_units=?,settled_at=? WHERE owner_installation_id=? AND request_id=?",
                                         (actual_units, now, owner, request_id))
                else:
                    conn.exec_driver_sql("UPDATE budget_ledger SET state='held_unknown' WHERE owner_installation_id=? AND request_id=?", (owner, request_id))
            return True

    def expire_result(self, owner: str, request_id: str) -> None:
        with self.transaction() as conn:
            conn.exec_driver_sql("UPDATE transcription_tasks SET status='result_expired',failure_code='result_expired',updated_at=? WHERE owner_installation_id=? AND request_id=? AND status='ready'",
                                 (self.now_iso(), owner, request_id))

    def cancel(self, owner: str, request_id: str) -> dict:
        with self.transaction() as conn:
            task = self._task(conn, owner, request_id)
            self._release(conn, task)
            now = self.now_iso()
            conn.exec_driver_sql("UPDATE transcription_tasks SET status='cancelled',cancel_requested_at=COALESCE(cancel_requested_at,?),terminal_at=COALESCE(terminal_at,?),updated_at=?,failure_code='request_cancelled' WHERE owner_installation_id=? AND request_id=?",
                                 (now, now, now, owner, request_id))
            conn.exec_driver_sql("UPDATE budget_ledger SET state='held_unknown' WHERE owner_installation_id=? AND request_id=? AND state!='settled'", (owner, request_id))
            return self._task(conn, owner, request_id)

    def recover(self) -> dict[str, int]:
        counts = {"unknown": 0, "failed": 0, "result_expired": 0}
        with self.transaction() as conn:
            tasks = [dict(row) for row in conn.exec_driver_sql("SELECT * FROM transcription_tasks WHERE status IN ('processing','ready')").mappings()]
            for task in tasks:
                owner, request_id = task["owner_installation_id"], task["request_id"]
                if task["status"] == "ready":
                    status, failure = "result_expired", "result_expired"
                elif task["dispatch_marked_at"]:
                    status, failure = "unknown", "request_timeout"
                    conn.exec_driver_sql("UPDATE budget_ledger SET state='held_unknown' WHERE owner_installation_id=? AND request_id=? AND state!='settled'", (owner, request_id))
                else:
                    created = datetime.fromisoformat(task["created_at"])
                    if (self.clock() - created).total_seconds() < self.settings.task_timeout:
                        continue
                    self._release(conn, task)
                    status, failure = "failed", "request_timeout"
                now = self.now_iso()
                conn.exec_driver_sql("UPDATE transcription_tasks SET status=?,failure_code=?,terminal_at=COALESCE(terminal_at,?),updated_at=? WHERE owner_installation_id=? AND request_id=?",
                                     (status, failure, now, now, owner, request_id))
                counts[status] += 1
        return counts

    def cleanup(self) -> None:
        with self.transaction() as conn:
            conn.exec_driver_sql("DELETE FROM transcription_tasks WHERE tombstone_until<=? AND status!='processing'", (self.now_iso(),))

    def release_orphaned(self) -> None:
        """Revisit only expired, un-dispatched reservations; never alter live dispatched work."""
        with self.transaction() as conn:
            cutoff = (self.clock() - timedelta(seconds=self.settings.task_timeout)).astimezone(TIMEZONE).isoformat()
            tasks = [dict(row) for row in conn.exec_driver_sql("SELECT * FROM transcription_tasks WHERE status='processing' AND dispatch_marked_at IS NULL AND created_at<=?", (cutoff,)).mappings()]
            for task in tasks:
                self._release(conn, task)
                now = self.now_iso()
                conn.exec_driver_sql("UPDATE transcription_tasks SET status='failed',failure_code='request_timeout',terminal_at=?,updated_at=? WHERE owner_installation_id=? AND request_id=?",
                                     (now, now, task["owner_installation_id"], task["request_id"]))
