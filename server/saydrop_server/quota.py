from datetime import datetime, time, timedelta
from zoneinfo import ZoneInfo

from saydrop_server.errors import ApiError

TIMEZONE = ZoneInfo("Asia/Shanghai")


def bucket_date(now: datetime) -> str:
    return now.astimezone(TIMEZONE).date().isoformat()


def quota_payload(row: dict | None, now: datetime, limit: int = 50, bucket: str | None = None) -> dict:
    date = datetime.fromisoformat(bucket).date() if bucket else now.astimezone(TIMEZONE).date()
    reset = datetime.combine(date + timedelta(days=1), time.min, TIMEZONE)
    used = row["used"] if row else 0
    reserved = row["reserved"] if row else 0
    limit = row["limit_snapshot"] if row else limit
    return {"limit": limit, "used": used, "reserved": reserved,
            "remaining": max(0, limit - used - reserved), "resetAt": reset.isoformat()}


def reserve_quota(conn, owner: str, bucket: str, limit: int, now: str) -> None:
    """Caller MUST own a BEGIN IMMEDIATE transaction; this has no provider side effects."""
    conn.exec_driver_sql(
        "INSERT OR IGNORE INTO daily_quotas VALUES (?,?,?,0,0,?,?)",
        (owner, bucket, limit, now, now),
    )
    result = conn.exec_driver_sql(
        "UPDATE daily_quotas SET reserved=reserved+1,updated_at=? "
        "WHERE installation_id=? AND bucket_date=? AND used+reserved<limit_snapshot",
        (now, owner, bucket),
    )
    if result.rowcount != 1:
        raise ApiError("quota_exhausted", 429)
