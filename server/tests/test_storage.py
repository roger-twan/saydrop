from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import pytest

from saydrop_server.config import Settings
from saydrop_server.errors import ApiError
from saydrop_server.quota import reserve_quota
from saydrop_server.storage import Store, migrate


def make_store(tmp_path):
    settings = Settings(token_pepper="t" * 64, fingerprint_key="f" * 64,
                        database_path=tmp_path / "test.sqlite3", provider_mode="mock",
                        daily_budget_units=10000, raw_estimate_units=120,
                        polish_estimate_units=240, budget_config_version="mock-v1")
    migrate(settings.database_path)
    now = [datetime(2026, 10, 26, 23, 59, 59, tzinfo=ZoneInfo("Asia/Shanghai"))]
    store = Store(settings, wall_clock=lambda: now[0])
    owner, _ = store.register("0.1.0", "macos-arm64")
    return store, owner, now


def test_51_atomic_reservations(tmp_path):
    store, owner, _ = make_store(tmp_path)
    def compete(_):
        try:
            with store.transaction() as conn:
                reserve_quota(conn, owner, "2026-10-26", 50, store.now_iso())
            return True
        except ApiError as exc:
            assert exc.code == "quota_exhausted"
            return False
    with ThreadPoolExecutor(max_workers=16) as pool:
        accepted = list(pool.map(compete, range(51)))
    assert sum(accepted) == 50
    assert store.quota(owner)["reserved"] == 50
    assert store.quota(owner)["remaining"] == 0


def test_dispatch_cancel_and_midnight(tmp_path):
    store, owner, now = make_store(tmp_path)
    task, new = store.reserve(owner, "first", "fingerprint", "raw")
    assert new and task["quota_bucket_date"] == "2026-10-26"
    now[0] += timedelta(seconds=2)
    assert store.dispatch(owner, "first")
    assert store.quota(owner)["used"] == 0  # new day
    assert store.quota(owner, "2026-10-26")["used"] == 1
    store.cancel(owner, "first")
    assert store.quota(owner, "2026-10-26")["used"] == 1
    assert store.status(owner, "first")["status"] == "cancelled"
    task, new = store.reserve(owner, "second", "fingerprint", "raw")
    store.cancel(owner, "second")
    assert store.quota(owner)["reserved"] == 0
    assert not store.dispatch(owner, "second")


def test_idempotency_and_owner_acl(tmp_path):
    store, owner, _ = make_store(tmp_path)
    store.reserve(owner, "first", "fingerprint", "raw")
    _, new = store.reserve(owner, "first", "fingerprint", "raw")
    assert not new and store.quota(owner)["reserved"] == 1
    with pytest.raises(ApiError, match="idempotency_conflict"):
        store.reserve(owner, "first", "changed", "raw")
    with pytest.raises(ApiError, match="idempotency_conflict"):
        store.reserve(owner, "first", "fingerprint", "light_polish")
    other, _ = store.register("0.1.0", "macos-arm64")
    with pytest.raises(ApiError, match="not_found"):
        store.status(other, "first")
    with pytest.raises(ApiError, match="not_found"):
        store.cancel(other, "first")


def test_recovery_no_replay(tmp_path):
    store, owner, now = make_store(tmp_path)
    store.reserve(owner, "dispatched", "f", "raw")
    store.dispatch(owner, "dispatched")
    store.recover()
    assert store.status(owner, "dispatched")["status"] == "unknown"
    assert store.quota(owner)["used"] == 1
    _, new = store.reserve(owner, "dispatched", "f", "raw")
    assert not new
    store.reserve(owner, "pending", "f", "raw")
    now[0] += timedelta(seconds=61)
    store.recover()
    assert store.status(owner, "pending")["status"] == "failed"
    assert store.quota(owner)["reserved"] == 0


def test_ready_recovery_and_tombstone(tmp_path):
    store, owner, now = make_store(tmp_path)
    store.reserve(owner, "ready", "f", "raw")
    store.dispatch(owner, "ready")
    store.finish(owner, "ready", "ready", "not_requested", result_expires_at=store.now_iso())
    store.recover()
    assert store.status(owner, "ready")["status"] == "result_expired"
    now[0] += timedelta(days=6)
    store.cleanup()
    assert store.status(owner, "ready")["status"] == "result_expired"
    now[0] += timedelta(days=2)
    store.cleanup()
    with pytest.raises(ApiError, match="not_found"):
        store.status(owner, "ready")


def test_budget_and_token_hash(tmp_path):
    store, owner, _ = make_store(tmp_path)
    other, token = store.register("0.1.0", "macos-arm64")
    assert len(token) == 43 and store.authenticate(token) == other
    with pytest.raises(ApiError, match="invalid_token"):
        store.authenticate("invalid")
    with store.transaction() as conn:
        conn.exec_driver_sql("UPDATE installations SET revoked_at=? WHERE id=?", (store.now_iso(), other))
    with pytest.raises(ApiError, match="installation_revoked"):
        store.authenticate(token)
    store.settings.daily_budget_units = 119
    with pytest.raises(ApiError, match="budget_unavailable"):
        store.reserve(owner, "no-budget", "f", "raw")
    assert store.quota(owner)["reserved"] == 0
    store.settings.daily_budget_units = 120
    store.reserve(owner, "fits", "f", "raw")
    store.dispatch(owner, "fits")
    store.finish(owner, "fits", "failed", "not_requested", failure_code="upstream_failed")
    with pytest.raises(ApiError, match="budget_unavailable"):
        store.reserve(owner, "exceeds", "f", "raw")
    store.engine.dispose()
    assert token.encode() not in store.settings.database_path.read_bytes()
