import asyncio
import json
import time
from uuid import uuid4

import pytest
from pydantic import SecretStr
from test_api import env as env
from test_api import submit, terminal

from saydrop_server.monitoring import TaskTrace
from saydrop_server.providers.base import ProviderError


def groups(app, name):
    return [row for row in app.state.monitor.metrics.snapshot(source="mock")["groups"] if row["name"] == name]


def total(app, name):
    return sum(row["sum"] or 0 for row in groups(app, name))


async def test_metrics_independent_auth_source_filter_and_no_quota_charge(env):
    client, app, provider, settings, token = env
    assert (await client.get("/internal/metrics")).status_code == 403
    settings.metrics_token = SecretStr("m" * 43)
    assert (await client.get("/internal/metrics")).status_code == 403
    assert (await client.get("/internal/metrics", headers={"Authorization": "Bearer wrong"})).status_code == 403
    key = str(uuid4())
    await submit(client, key=key)
    done = (await terminal(client, key)).json()
    headers = {"Authorization": "Bearer " + "m" * 43}
    response = await client.get("/internal/metrics?source=mock", headers=headers)
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    assert response.json()["availability"]["ttft"] == "unavailable"
    assert response.json()["writeFailureCountSinceStart"] == 0
    for private in (token, "m" * 43, key, done["rawText"]):
        assert private not in response.text
    assert (await client.get("/internal/metrics", headers=headers)).json()["groups"] == []
    for query in ("days=31", "days=0", "days=-1", "source=all", "model=attacker", "days=1&days=2"):
        assert (await client.get("/internal/metrics?" + query, headers=headers)).status_code == 422
    assert (await client.get("/v1/quota")).json()["used"] == 1


async def test_numeric_task_measurements_and_replay_not_double_terminal(env):
    client, app, provider, settings, token = env
    key = str(uuid4())
    await submit(client, key=key)
    await terminal(client, key)
    await asyncio.sleep(0)
    await submit(client, key=key)
    assert (await submit(client, key=key, mode="light_polish")).status_code == 409
    assert total(app, "submitCount") == 3
    assert total(app, "acceptedCount") == total(app, "terminalCount") == 1
    assert total(app, "idempotentReplayCount") == 1
    assert total(app, "rejectedCount") == 1
    assert groups(app, "rejectedCount")[0]["reason"] == "idempotency_conflict"
    assert total(app, "audioSeconds") == pytest.approx(0.1)
    assert total(app, "sttSeconds") > 0
    assert total(app, "rtf") == pytest.approx(total(app, "sttSeconds") / 0.1)
    assert total(app, "audioThroughput") == pytest.approx(0.1 / total(app, "sttSeconds"))
    assert total(app, "characterThroughput") == pytest.approx(total(app, "rawCharacters") / total(app, "sttSeconds"))
    assert total(app, "resultReadySeconds") >= total(app, "sttSeconds")
    assert not groups(app, "polishSeconds")
    for name in ("ttftSeconds", "qualityCER", "qualityMixedErrorRate", "qualityOmissionRate"):
        row = groups(app, name)[0]
        assert row["unavailableCount"] == 1
        assert row["sum"] is row["mean"] is row["p50"] is row["p95"] is row["p99"] is None
    assert app.state.monitor.write_failures == 0
    with app.state.store.engine.connect() as conn:
        data = [dict(row) for row in conn.exec_driver_sql("SELECT * FROM metric_samples").mappings()]
    assert token not in json.dumps(data) and key not in json.dumps(data)


async def test_polish_fallback_and_failure_categories(env):
    client, app, provider, settings, token = env
    provider.polish_error = ProviderError(kind="truncated", ttfb_seconds=0.2)
    key = str(uuid4())
    await submit(client, key=key, mode="light_polish")
    assert (await terminal(client, key)).json()["polishStatus"] == "failed_fallback_raw"
    await asyncio.sleep(0)
    assert total(app, "polishAttemptCount") == total(app, "polishFallbackCount") == 1
    assert total(app, "upstreamTruncatedCount") == 1
    assert total(app, "polishTtfbSeconds") == pytest.approx(0.2)
    assert total(app, "terminalCount") == 1
    assert app.state.monitor.write_failures == 0


async def test_timeout_and_cancel_count_once(env):
    client, app, provider, settings, token = env
    provider.gate = asyncio.Event()
    settings.stt_timeout = 0.005
    key = str(uuid4())
    await submit(client, key=key)
    assert (await terminal(client, key)).json()["status"] == "unknown"
    await asyncio.sleep(0)
    assert groups(app, "terminalCount")[0]["reason"] == "request_timeout"
    settings.stt_timeout = 45
    key2 = str(uuid4())
    await submit(client, key=key2)
    await client.delete("/v1/transcriptions/" + key2)
    await asyncio.sleep(0.01)
    await client.delete("/v1/transcriptions/" + key2)
    assert total(app, "terminalCount") == 2
    assert {row["outcome"] for row in groups(app, "terminalCount")} == {"unknown", "cancelled"}
    assert app.state.monitor.write_failures == 0


async def test_cancel_before_coroutine_started_still_emits_one_terminal(env):
    client, app, provider, settings, token = env
    owner = app.state.store.authenticate(token)
    key = str(uuid4())
    app.state.store.reserve(owner, key, "fingerprint", "raw")
    trace = TaskTrace("raw", settings.stt_model, "mock", time.monotonic(), 0.1)
    app.state.tasks.start(owner, key, b"test-only", "raw", time.monotonic() + 60, trace=trace)
    app.state.store.cancel(owner, key)
    app.state.tasks.cancel(owner, key)
    await asyncio.sleep(0)
    await asyncio.sleep(0)
    assert total(app, "terminalCount") == 1
    assert groups(app, "terminalCount")[0]["outcome"] == "cancelled"
    assert not provider.stt_calls
    assert not trace.samples


async def test_monitor_write_failure_does_not_change_result_or_replay(env, monkeypatch):
    client, app, provider, settings, token = env
    def fail(samples):
        raise RuntimeError("private-key private-transcript")
    monkeypatch.setattr(app.state.monitor.metrics, "record", fail)
    key = str(uuid4())
    await submit(client, key=key)
    response = await terminal(client, key)
    assert response.json()["status"] == "ready"
    assert "private-key" not in response.text
    assert app.state.monitor.write_failures > 0
    await submit(client, key=key)
    assert provider.stt_calls == 1
    assert (await client.get("/v1/quota")).json()["used"] == 1
