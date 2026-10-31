import asyncio
import threading

from pydantic import SecretStr
from test_api import env as env


async def test_one_metrics_read_does_not_block_health(env, monkeypatch):
    client, app, provider, settings, token = env
    settings.metrics_token = SecretStr("m" * 43)
    started, release = threading.Event(), threading.Event()
    real_snapshot = app.state.monitor.metrics.snapshot
    def slow_snapshot(*, days, source):
        started.set()
        assert release.wait(5)
        return real_snapshot(days=days, source=source)
    monkeypatch.setattr(app.state.monitor.metrics, "snapshot", slow_snapshot)
    headers = {"Authorization": "Bearer " + "m" * 43}
    pending = asyncio.create_task(client.get("/internal/metrics", headers=headers))
    try:
        for _ in range(100):
            if started.is_set():
                break
            await asyncio.sleep(0.005)
        assert started.is_set()
        assert (await asyncio.wait_for(client.get("/healthz"), .5)).status_code == 200
        duplicate = await client.get("/internal/metrics", headers=headers)
        assert duplicate.status_code == 429
        assert duplicate.json()["error"]["code"] == "rate_limited"
    finally:
        release.set()
    assert (await pending).status_code == 200
