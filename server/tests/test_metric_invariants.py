import pytest
from sqlalchemy.exc import IntegrityError
from test_storage import make_store

from saydrop_server.observability import MetricSample, MetricStore


def test_unavailable_reason_and_quality_source_enforced(tmp_path):
    store, _, _ = make_store(tmp_path)
    metrics = MetricStore(store)
    for sample in [MetricSample("sttSeconds", None), MetricSample("qualityCER", .5, source="live"), MetricSample("ttftSeconds", 0, reason="non_streaming")]:
        with pytest.raises(ValueError, match="invalid metric input"):
            metrics.record([sample])
    metrics.record([MetricSample("ttftSeconds", None, reason="non_streaming")])
    with pytest.raises(IntegrityError):
        with store.transaction() as conn:
            conn.exec_driver_sql("UPDATE metric_samples SET value=0 WHERE name='ttftSeconds'")
    store.engine.dispose()
