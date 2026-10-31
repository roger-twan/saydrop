import pytest
from pydantic import ValidationError

from saydrop_server.config import Settings


@pytest.mark.parametrize("token", ["private-short-metric-token", "\u79D8\u5BC6" * 43, " " * 43])
def test_monitor_token_validation_does_not_echo_secret(token):
    with pytest.raises(ValidationError) as raised:
        Settings(token_pepper="p" * 64, fingerprint_key="f" * 64, metrics_token=token)
    assert token not in str(raised.value)


def test_monitoring_does_not_relax_retention_or_budgets():
    settings = Settings(token_pepper="p" * 64, fingerprint_key="f" * 64)
    assert settings.metrics_retention_days == 30
    assert settings.metrics_token.get_secret_value() == ""
    assert not settings.budget_available()
    with pytest.raises(ValidationError):
        Settings(token_pepper="p" * 64, fingerprint_key="f" * 64, metrics_retention_days=31)
