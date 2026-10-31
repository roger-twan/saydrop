from saydrop_server.config import Settings
from saydrop_server.errors import ApiError


def estimate(settings: Settings, mode: str) -> int:
    return settings.polish_estimate_units if mode == "light_polish" else settings.raw_estimate_units


def require_budget(conn, settings: Settings, bucket: str, mode: str) -> int:
    if not settings.budget_available():
        raise ApiError("budget_unavailable", 503, retryable=True)
    held = conn.exec_driver_sql(
        "SELECT COALESCE(SUM(CASE WHEN state='settled' THEN actual_units ELSE estimated_units END),0) "
        "FROM budget_ledger WHERE bucket_date=? AND state!='released'", (bucket,),
    ).scalar_one()
    units = estimate(settings, mode)
    if held + units > settings.daily_budget_units:
        raise ApiError("budget_unavailable", 503, retryable=True)
    return units
