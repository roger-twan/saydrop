import json

import pytest
from test_storage import make_store

from saydrop_server.observability import MetricStore
from saydrop_server.quality import evaluate_record, evaluate_records, main
from saydrop_server.quality_persistence import persist_report
from saydrop_server.storage import Store


@pytest.mark.parametrize("hypothesis", ["142", "A42", "1.42", "-42"])
def test_critical_numbers_require_full_token_and_sign(hypothesis):
    report = evaluate_record({"reference": "42", "hypothesis": hypothesis})
    assert report["metrics"]["protectedRetention"]["rate"] == 0


def test_mixed_alignment_keeps_negative_sign():
    report = evaluate_record({"reference": "\u4F59\u989D -42", "hypothesis": "\u4F59\u989D 42"})
    assert report["metrics"]["mixedErrorRate"]["counts"]["S"] == 1
    assert report["metrics"]["protectedRetention"]["rate"] == 0


def test_quality_sqlite_is_corpus_numbers_only_and_weighted(tmp_path):
    store, _, _ = make_store(tmp_path)
    first = evaluate_records([{"reference": "privateword", "hypothesis": "privateword"}])
    second = evaluate_records([{"reference": "a", "hypothesis": "b c"}])
    persist_report(first, store)
    persist_report(second, store)
    snapshot = MetricStore(store).snapshot(source="offline")
    weighted = snapshot["summary"]["weightedQuality"][0]
    assert weighted["sampleCount"] == 2
    assert weighted["qualityWER"] == {"numerator": 2.0, "denominator": 2.0, "value": 1.0}
    with store.engine.connect() as conn:
        stored = [dict(row) for row in conn.exec_driver_sql("SELECT * FROM metric_samples").mappings()]
    assert "privateword" not in json.dumps(stored)
    assert MetricStore(store).snapshot(source="live")["groups"] == []


def test_missing_reference_stays_null_in_database(tmp_path):
    store, _, _ = make_store(tmp_path)
    persist_report(evaluate_records([{"hypothesis": "private text"}]), store)
    snapshot = MetricStore(store).snapshot(source="offline")
    row = next(row for row in snapshot["groups"] if row["name"] == "qualityCER")
    assert row["reason"] == "missing_reference" and row["mean"] is None
    assert snapshot["summary"]["weightedQuality"][0]["qualityCER"]["value"] is None


def test_cli_persist_is_explicit_and_no_text_saved(tmp_path, monkeypatch):
    from saydrop_server.config import Settings
    store, _, _ = make_store(tmp_path)
    monkeypatch.setattr(Settings, "load", classmethod(lambda cls: store.settings))
    source = tmp_path / "source.jsonl"
    source.write_text(json.dumps({"reference": "private-source", "hypothesis": "private-source"}) + "\n")
    target = tmp_path / "report.json"
    assert main(["--input", str(source), "--output", str(target), "--persist"]) == 0
    report = json.loads(target.read_text())
    assert report["method"]["monitoring"]["persistence"] == "saved"
    assert "private-source" not in target.read_text()
    # The CLI uses the real clock; the make_store fixture uses a fixed 2026-10-26 clock.
    live_clock_store = Store(store.settings)
    try:
        assert MetricStore(live_clock_store).snapshot(source="offline")["groups"]
    finally:
        live_clock_store.engine.dispose()
    assert main(["--input", str(source), "--output", str(target), "--persist"]) == 2


def test_quality_wrong_metadata_or_version_is_not_persisted(tmp_path):
    store, _, _ = make_store(tmp_path)
    report = evaluate_records([{"reference": "a", "hypothesis": "a"}])
    with pytest.raises(ValueError):
        persist_report(report, store, model="unapproved/model")
    report["method"]["version"] = "another-version"
    with pytest.raises(ValueError):
        persist_report(report, store)
    assert MetricStore(store).snapshot(source="offline")["groups"] == []
