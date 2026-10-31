import pytest
from pydantic import ValidationError

from saydrop_server.config import Settings


@pytest.mark.parametrize("field,value", [
    ("daily_quota", 51), ("timezone", "UTC"), ("max_audio_seconds", 121),
    ("max_audio_bytes", 8 * 1024 * 1024 + 1), ("result_ttl", 121),
    ("tombstone_days", 6), ("max_active_tasks", 5), ("max_results", 33),
    ("polish_max_chars", 16001), ("polish_max_tokens", 4096),
])
def test_configuration_cannot_exceed_approved_boundaries(field, value):
    with pytest.raises(ValidationError):
        Settings(token_pepper="p" * 64, fingerprint_key="f" * 64, **{field: value})


def test_validation_error_hides_input_secret():
    with pytest.raises(ValidationError) as raised:
        Settings(token_pepper="private-short-value", fingerprint_key="f" * 64)
    assert "private-short-value" not in str(raised.value)


def test_blank_budget_version_and_key_fail_closed():
    settings = Settings(token_pepper="p" * 64, fingerprint_key="f" * 64,
                        daily_budget_units=1000, raw_estimate_units=10,
                        polish_estimate_units=20, budget_config_version=" ",
                        provider_mode="mock")
    assert not settings.budget_available()
    settings.provider_mode = "openrouter"
    settings.budget_config_version = "v1"
    settings.openrouter_api_key = ""  # re-create rather than serialize any secret
    settings = Settings(**{**settings.model_dump(), "openrouter_api_key": " "})
    assert not settings.budget_available()
