import httpx
import pytest
from pydantic import ValidationError

import saydrop_server.config as config
from saydrop_server.config import Settings
from saydrop_server.main import create_app
from saydrop_server.storage import migrate


def write_environment(tmp_path, value, monkeypatch):
    import os
    for key in list(os.environ):
        if key.startswith("SAYDROP_") or key == "OPENROUTER_API_KEY":
            monkeypatch.delenv(key)
    path = tmp_path / ".env"
    path.write_text(
        "SAYDROP_TOKEN_PEPPER=" + "p" * 64 + "\n"
        "SAYDROP_FINGERPRINT_KEY=" + "f" * 64 + "\n"
        "SAYDROP_METRICS_TOKEN=" + "m" * 43 + "\n"
        "SAYDROP_METRICS_RETENTION_DAYS=" + value + "\n"
        "SAYDROP_ENVIRONMENT=development\n"
        "SAYDROP_ALLOW_LOOPBACK_HTTP=true\n"
        "SAYDROP_PROVIDER_MODE=openrouter\n"
        "OPENROUTER_API_KEY=test-factory-key\n"
        "SAYDROP_DAILY_BUDGET_UNITS=10000\n"
        "SAYDROP_RAW_ESTIMATE_UNITS=120\n"
        "SAYDROP_POLISH_ESTIMATE_UNITS=240\n"
        "SAYDROP_BUDGET_CONFIG_VERSION=test-reviewed-v1\n"
        f"SAYDROP_DATABASE_PATH={tmp_path / 'factory.sqlite3'}\n"
    )
    return path


def test_dotenv_30_is_parsed_to_integer_without_changing_limit(tmp_path, monkeypatch):
    path = write_environment(tmp_path, "30", monkeypatch)
    settings = Settings.load(path)
    assert type(settings.metrics_retention_days) is int
    assert settings.metrics_retention_days == 30
    assert settings.budget_available()


@pytest.mark.parametrize("value", ["31", "0", "-1", "30.0", "private-invalid-value", ""])
def test_bad_dotenv_retention_is_not_silently_defaulted(tmp_path, monkeypatch, value):
    path = write_environment(tmp_path, value, monkeypatch)
    with pytest.raises(ValidationError) as raised:
        Settings.load(path)
    assert "metrics_retention_days" in str(raised.value)
    assert "private-invalid-value" not in str(raised.value)


def test_environment_override_also_parses_and_enforces_limit(tmp_path, monkeypatch):
    path = write_environment(tmp_path, "31", monkeypatch)
    monkeypatch.setenv("SAYDROP_METRICS_RETENTION_DAYS", "30")
    assert Settings.load(path).metrics_retention_days == 30
    monkeypatch.setenv("SAYDROP_METRICS_RETENTION_DAYS", "31")
    with pytest.raises(ValidationError):
        Settings.load(path)


async def test_factory_starts_from_dotenv_with_string_30(tmp_path, monkeypatch):
    path = write_environment(tmp_path, "30", monkeypatch)
    monkeypatch.setattr(config, "SERVER_ROOT", tmp_path)
    settings = Settings.load(path)
    migrate(settings.database_path)
    app = create_app()
    async with app.router.lifespan_context(app):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://127.0.0.1") as client:
            health = await client.get("/healthz")
            assert health.status_code == 200 and health.json() == {"status": "ok"}
            metrics = await client.get("/internal/metrics", headers={"Authorization": "Bearer " + "m" * 43})
            assert metrics.status_code == 200
            assert metrics.json()["retentionDays"] == 30
            assert metrics.json()["groups"] == []
