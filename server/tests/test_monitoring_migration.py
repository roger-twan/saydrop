import pytest

import saydrop_server.storage as storage_module
from saydrop_server.config import Settings
from saydrop_server.observability import MetricSample, MetricStore
from saydrop_server.storage import Store, migrate


def test_upgrade_from_v1_retains_token_quota_and_task(tmp_path, monkeypatch):
    path = tmp_path / "old.sqlite3"
    settings = Settings(token_pepper="p" * 64, fingerprint_key="f" * 64,
                        database_path=path, provider_mode="mock",
                        daily_budget_units=10000, raw_estimate_units=120,
                        polish_estimate_units=240, budget_config_version="mock-v1")
    monkeypatch.setattr(storage_module, "REVISION", 1)
    migrate(path)
    old = Store(settings)
    owner, token = old.register("0.1", "macos-arm64")
    old.reserve(owner, "existing", "fingerprint", "raw")
    old.dispatch(owner, "existing")
    old.finish(owner, "existing", "failed", "not_requested", failure_code="upstream_failed")
    previous = old.status(owner, "existing")
    old.engine.dispose()
    monkeypatch.setattr(storage_module, "REVISION", 2)
    with pytest.raises(RuntimeError, match="migrate"):
        Store(settings)
    migrate(path)
    upgraded = Store(settings)
    assert upgraded.authenticate(token) == owner
    assert upgraded.quota(owner)["used"] == 1
    assert upgraded.status(owner, "existing") == previous
    metrics = MetricStore(upgraded)
    metrics.record([MetricSample("rejectedCount", 1, outcome="rejected", reason="invalid_wav")])
    assert metrics.snapshot()["groups"][0]["reason"] == "invalid_wav"
    upgraded.engine.dispose()


def test_empty_metrics_summary_is_unavailable_not_zero_accuracy(tmp_path):
    settings = Settings(token_pepper="p" * 64, fingerprint_key="f" * 64,
                        database_path=tmp_path / "empty.sqlite3")
    migrate(settings.database_path)
    store = Store(settings)
    summary = MetricStore(store).snapshot()["summary"]
    for name in ("successRate", "failureRate", "unknownRate", "cancelledRate", "timeoutRate", "rejectionRate", "polishFallbackRate"):
        assert summary[name]["denominator"] == 0 and summary[name]["value"] is None
    assert summary["weightedQuality"] == []
    store.engine.dispose()
