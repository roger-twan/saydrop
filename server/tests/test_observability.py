from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
from math import inf, nan
from zoneinfo import ZoneInfo

import pytest

import saydrop_server.storage as storage_module
from saydrop_server.config import Settings
from saydrop_server.observability import VALIDATION_ERROR, MetricSample, MetricStore
from saydrop_server.storage import Store


def make_metric_store(tmp_path, monkeypatch):
    monkeypatch.setattr(storage_module, "REVISION", 2)
    settings = Settings(
        token_pepper="t" * 64,
        fingerprint_key="f" * 64,
        database_path=tmp_path / "metrics.sqlite3",
        provider_mode="mock",
        daily_budget_units=10000,
        raw_estimate_units=120,
        polish_estimate_units=240,
        budget_config_version="mock-v1",
    )
    storage_module.migrate(settings.database_path)
    now = [datetime(2026, 10, 26, 12, 0, tzinfo=ZoneInfo("Asia/Shanghai"))]
    return MetricStore(Store(settings, wall_clock=lambda: now[0])), now


def group_for(snapshot, name, reason=None):
    return next(group for group in snapshot["groups"] if group["name"] == name and group["reason"] == reason)


def test_null_values_are_unavailable_and_do_not_enter_quantiles(tmp_path, monkeypatch):
    metrics, _ = make_metric_store(tmp_path, monkeypatch)
    metrics.record(
        [
            MetricSample("uploadSeconds", 1.0),
            MetricSample("uploadSeconds", 3.0),
            MetricSample("uploadSeconds", None, reason="not_observed"),
            MetricSample("ttftSeconds", None, reason="non_streaming"),
        ]
    )

    snapshot = metrics.snapshot()
    upload = group_for(snapshot, "uploadSeconds")
    unavailable = group_for(snapshot, "uploadSeconds", "not_observed")
    ttft = group_for(snapshot, "ttftSeconds", "non_streaming")

    assert upload["sampleCount"] == 2
    assert upload["unavailableCount"] == 0
    assert upload["mean"] == 2.0
    assert upload["p50"] == 1.0
    assert upload["p95"] == 3.0
    assert upload["p99"] == 3.0
    assert upload["min"] == 1.0
    assert upload["max"] == 3.0
    assert upload["sum"] == 4.0
    assert upload["unit"] == "seconds"
    assert unavailable["sampleCount"] == 1
    assert unavailable["unavailableCount"] == 1
    assert all(unavailable[key] is None for key in ("mean", "p50", "p95", "p99", "min", "max", "sum"))
    assert ttft["unavailableCount"] == 1
    assert ttft["p50"] is None
    assert snapshot["availability"] == {"ttft": "unavailable", "qualityRequiresReference": True}


def test_nearest_rank_percentiles_are_exact(tmp_path, monkeypatch):
    metrics, _ = make_metric_store(tmp_path, monkeypatch)
    metrics.record([MetricSample("sttSeconds", float(value)) for value in range(1, 101)])

    stt = group_for(metrics.snapshot(), "sttSeconds")
    assert stt["p50"] == 50.0
    assert stt["p95"] == 95.0
    assert stt["p99"] == 99.0


def test_cleanup_uses_fixed_expiry_without_renewal(tmp_path, monkeypatch):
    metrics, now = make_metric_store(tmp_path, monkeypatch)
    metrics.record([MetricSample("submitCount", 1.0)])
    assert group_for(metrics.snapshot(), "submitCount")["sampleCount"] == 1

    now[0] += timedelta(days=30)
    assert metrics.cleanup() == 1
    assert metrics.snapshot()["groups"] == []


def test_metrics_persist_after_store_restart(tmp_path, monkeypatch):
    metrics, _ = make_metric_store(tmp_path, monkeypatch)
    metrics.record([MetricSample("acceptedCount", 1.0, mode="raw", outcome="ready")])
    settings = metrics.store.settings
    metrics.store.engine.dispose()

    restarted = MetricStore(Store(settings, wall_clock=metrics.store.clock))
    accepted = group_for(restarted.snapshot(), "acceptedCount")
    assert accepted["sampleCount"] == 1
    assert accepted["sum"] == 1.0


def test_schema_has_no_sensitive_or_request_correlating_columns(tmp_path, monkeypatch):
    metrics, _ = make_metric_store(tmp_path, monkeypatch)
    with metrics.store.engine.connect() as conn:
        columns = {row[1] for row in conn.exec_driver_sql("PRAGMA table_info(metric_samples)")}
    forbidden_fragments = ("audio", "raw", "text", "token", "ip", "owner", "request", "correct")
    assert not any(fragment in column.lower() for column in columns for fragment in forbidden_fragments)
    assert columns == {
        "id",
        "name",
        "mode",
        "model",
        "outcome",
        "source",
        "reason",
        "observed_at",
        "expires_at",
        "value",
    }


def test_whitelists_invalid_numbers_and_ttft_are_scrubbed(tmp_path, monkeypatch):
    metrics, _ = make_metric_store(tmp_path, monkeypatch)
    invalid_samples = [
        MetricSample("arbitraryLabel", 1.0),
        MetricSample("submitCount", 1.0, mode="dynamic"),
        MetricSample("submitCount", 1.0, model="unapproved/model"),
        MetricSample("submitCount", 1.0, outcome="detail"),
        MetricSample("submitCount", 1.0, source="production"),
        MetricSample("submitCount", 1.0, reason="supplier message"),
        MetricSample("submitCount", True),
        MetricSample("submitCount", nan),
        MetricSample("submitCount", inf),
        MetricSample("submitCount", -0.1),
        MetricSample("ttftSeconds", 0.0),
        MetricSample("ttftSeconds", None, reason="not_observed"),
    ]
    for sample in invalid_samples:
        with pytest.raises(ValueError) as error:
            metrics.record([sample])
        assert str(error.value) == VALIDATION_ERROR

    with pytest.raises(ValueError) as error:
        metrics.snapshot(days=0)
    assert str(error.value) == VALIDATION_ERROR
    with pytest.raises(ValueError) as error:
        metrics.snapshot(source="all")
    assert str(error.value) == VALIDATION_ERROR


def test_concurrent_batches_are_atomic_and_source_filters_do_not_mix(tmp_path, monkeypatch):
    metrics, _ = make_metric_store(tmp_path, monkeypatch)

    def record_batch(index):
        metrics.record(
            [
                MetricSample("submitCount", 1.0),
                MetricSample("acceptedCount", 1.0, outcome="ready"),
                MetricSample("submitCount", 1.0, source="mock") if index == 0 else MetricSample("terminalCount", 1.0),
            ]
        )

    with ThreadPoolExecutor(max_workers=8) as executor:
        list(executor.map(record_batch, range(16)))

    live = metrics.snapshot(source="live")
    mock = metrics.snapshot(source="mock")
    assert group_for(live, "submitCount")["sampleCount"] == 16
    assert group_for(live, "acceptedCount")["sampleCount"] == 16
    assert group_for(live, "terminalCount")["sampleCount"] == 15
    assert group_for(mock, "submitCount")["sampleCount"] == 1
    assert all(group["source"] == "live" for group in live["groups"])
    assert all(group["source"] == "mock" for group in mock["groups"])
