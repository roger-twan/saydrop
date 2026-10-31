import asyncio
import io
import time
import wave
from uuid import uuid4

import httpx
import pytest

from saydrop_server.config import Settings
from saydrop_server.main import create_app
from saydrop_server.providers.base import PolishResult, ProviderError, STTResult
from saydrop_server.storage import migrate


class FakeProvider:
    """Explicit in-memory test double; does not connect to OpenRouter."""
    def __init__(self):
        self.stt_calls = 0
        self.polish_calls = 0
        self.gate = None
        self.error = None
        self.polish_error = None
        self.polished = "\u4ECA\u5929\u4E0B\u5348 three \u70B9\u8DDF Alice \u5F00\u4F1A。"

    async def transcribe(self, audio):
        self.stt_calls += 1
        if self.gate:
            await self.gate.wait()
        if self.error:
            raise self.error
        return STTResult(text="\u4ECA\u5929\u4E0B\u5348 three \u70B9\u8DDF Alice \u5F00\u4F1A")

    async def polish(self, text):
        self.polish_calls += 1
        if self.polish_error:
            raise self.polish_error
        return PolishResult(text=self.polished)

    async def aclose(self):
        pass


def wav():
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(16000)
        out.writeframes(b"\x00\x08\x00\xf8" * 800)
    return buffer.getvalue()


@pytest.fixture
async def env(tmp_path):
    settings = Settings(token_pepper="p" * 64, fingerprint_key="f" * 64,
                        database_path=tmp_path / "test.sqlite3", provider_mode="mock",
                        daily_budget_units=10000, raw_estimate_units=120,
                        polish_estimate_units=240, budget_config_version="mock-v1",
                        allow_loopback_http=True)
    migrate(settings.database_path)
    provider = FakeProvider()
    app = create_app(settings, provider=provider)
    async with app.router.lifespan_context(app):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://127.0.0.1") as client:
            response = await client.post("/v1/installations", json={"clientVersion": "0.1.0", "platform": "macos-arm64"})
            assert response.status_code == 201
            token = response.json()["accessToken"]
            client.headers["Authorization"] = "Bearer " + token
            yield client, app, provider, settings, token


async def submit(client, mode="raw", key=None, data=None):
    return await client.post("/v1/transcriptions", content=data if data is not None else wav(),
                             headers={"Content-Type": "audio/wav", "Idempotency-Key": key or str(uuid4()),
                                      "X-Output-Mode": mode})


async def terminal(client, key):
    for _ in range(100):
        response = await client.get("/v1/transcriptions/" + key)
        if response.json().get("status") != "processing":
            return response
        await asyncio.sleep(0.005)
    pytest.fail("mock task did not complete")


async def test_health_install_quota_and_dto(env):
    client, app, provider, settings, token = env
    assert (await client.get("/healthz")).json() == {"status": "ok"}
    assert set((await client.get("/v1/quota")).json()) == {"limit", "used", "reserved", "remaining", "resetAt"}
    invalid = await client.post("/v1/installations", json={"clientVersion": "0.1", "platform": "ios"})
    assert invalid.status_code == 422 and invalid.json()["error"]["code"] == "invalid_request"
    assert "ios" not in invalid.text
    unauth = await client.get("/v1/quota", headers={"Authorization": "Bearer nope"})
    assert unauth.status_code == 401 and "quota" not in unauth.json()
    assert (await client.get("/docs")).status_code == 404
    assert len([route for route in app.routes if route.path != "/internal/metrics"]) == 6
    assert len(app.routes) == 7


async def test_raw_no_polish_and_idempotency(env):
    client, app, provider, settings, token = env
    key = str(uuid4())
    first = await submit(client, key=key)
    assert first.status_code == 202 and first.json()["requestId"] == key
    done = (await terminal(client, key)).json()
    assert done["status"] == "ready" and done["polishStatus"] == "not_requested"
    assert done["rawText"] == done["outputText"]
    repeated = await submit(client, key=key)
    assert repeated.status_code == 202 and repeated.json()["status"] == "ready"
    assert provider.stt_calls == 1 and provider.polish_calls == 0
    assert repeated.json()["quota"]["used"] == 1
    conflict = await submit(client, key=key, mode="light_polish")
    assert conflict.status_code == 409 and conflict.json()["error"]["code"] == "idempotency_conflict"
    assert provider.stt_calls == 1


async def test_polish_and_fallback(env):
    client, app, provider, settings, token = env
    key = str(uuid4())
    await submit(client, mode="light_polish", key=key)
    done = (await terminal(client, key)).json()
    assert done["polishStatus"] == "succeeded" and done["status"] == "ready"
    provider.polished = "\u4ECA\u5929\u4E0B\u5348 four \u70B9\u8DDF Bob \u5F00\u4F1A。"
    second = str(uuid4())
    await submit(client, mode="light_polish", key=second)
    fallback = (await terminal(client, second)).json()
    assert fallback["polishStatus"] == "failed_fallback_raw"
    assert fallback["outputText"] == fallback["rawText"]
    assert provider.polish_calls == 2


async def test_polish_error_fallback_no_retry(env):
    client, app, provider, settings, token = env
    provider.polish_error = ProviderError()
    key = str(uuid4())
    await submit(client, mode="light_polish", key=key)
    fallback = (await terminal(client, key)).json()
    assert fallback["status"] == "ready" and fallback["polishStatus"] == "failed_fallback_raw"
    assert provider.polish_calls == 1


async def test_ttl_monotonic_and_get_does_not_extend(env):
    client, app, provider, settings, token = env
    now = [time.monotonic()]
    app.state.tasks.clock = lambda: now[0]
    key = str(uuid4())
    await submit(client, key=key)
    result = (await terminal(client, key)).json()
    expires = result["resultExpiresAt"]
    now[0] += 119
    assert (await client.get("/v1/transcriptions/" + key)).json()["resultExpiresAt"] == expires
    now[0] += 1.01
    expired = (await client.get("/v1/transcriptions/" + key)).json()
    assert expired["status"] == "result_expired" and "rawText" not in expired
    assert key not in [k[1] for k in app.state.tasks.results]
    assert provider.stt_calls == 1


async def test_cancel_after_dispatch_and_owner_acl(env):
    client, app, provider, settings, token = env
    provider.gate = asyncio.Event()
    key = str(uuid4())
    await submit(client, key=key)
    for _ in range(50):
        if provider.stt_calls:
            break
        await asyncio.sleep(0.005)
    assert provider.stt_calls == 1
    cancelled = await client.delete("/v1/transcriptions/" + key)
    assert cancelled.json()["cancellationRecorded"] and cancelled.json()["quota"]["used"] == 1
    provider.gate.set()
    await asyncio.sleep(0.01)
    assert (await client.get("/v1/transcriptions/" + key)).json()["status"] == "cancelled"
    again = await submit(client, key=key)
    assert again.json()["status"] == "cancelled" and provider.stt_calls == 1
    owner2, token2 = app.state.store.register("0.1", "macos-arm64")
    outsider = await client.get("/v1/transcriptions/" + key, headers={"Authorization": "Bearer " + token2})
    assert outsider.status_code == 404 and outsider.json()["error"]["code"] == "not_found"
    assert (await client.delete("/v1/transcriptions/" + key, headers={"Authorization": "Bearer " + token2})).status_code == 404


async def test_unknown_error_and_budget_fail_closed(env):
    client, app, provider, settings, token = env
    provider.error = ProviderError(uncertain=True)
    key = str(uuid4())
    await submit(client, key=key)
    unknown = (await terminal(client, key)).json()
    assert unknown["status"] == "unknown" and unknown["quota"]["used"] == 1
    await submit(client, key=key)
    assert provider.stt_calls == 1
    settings.daily_budget_units = 0
    refused = await submit(client)
    assert refused.status_code == 503 and refused.json()["error"]["code"] == "budget_unavailable"
    assert refused.json()["quota"]["reserved"] == 0
    assert provider.stt_calls == 1


async def test_headers_audio_validation_and_no_sensitive_persistence(env):
    client, app, provider, settings, token = env
    bad = await submit(client, data=b"not-wav")
    assert bad.status_code == 422 and bad.json()["error"]["code"] == "invalid_wav"
    invalid_id = await submit(client, key="bad")
    assert invalid_id.status_code == 422 and invalid_id.json()["error"]["code"] == "invalid_request"
    invalid_mode = await submit(client, mode="translate")
    assert invalid_mode.status_code == 422
    multipart = await client.post("/v1/transcriptions", files={"file": ("audio.wav", wav())},
                                  headers={"Idempotency-Key": str(uuid4()), "X-Output-Mode": "raw"})
    assert multipart.status_code == 422
    params = await client.post("/v1/transcriptions?model=attacker", content=wav(),
                               headers={"Content-Type": "audio/wav", "Idempotency-Key": str(uuid4()), "X-Output-Mode": "raw"})
    assert params.status_code == 422
    assert (await client.get("/v1/quota")).json()["used"] == 0
    key = str(uuid4())
    await submit(client, key=key)
    done = (await terminal(client, key)).json()
    with app.state.store.engine.connect() as conn:
        conn.exec_driver_sql("PRAGMA wal_checkpoint(TRUNCATE)")
    files = list(settings.database_path.parent.glob("test.sqlite3*"))
    for file in files:
        if not file.is_file():
            continue
        contents = file.read_bytes()
        assert token.encode() not in contents
        assert done["rawText"].encode() not in contents
        assert wav() not in contents


async def test_one_active_task_and_result_capacity(env):
    client, app, provider, settings, token = env
    provider.gate = asyncio.Event()
    first = await submit(client)
    assert first.status_code == 202
    second = await submit(client)
    assert second.status_code == 429 and second.json()["error"]["code"] == "rate_limited"
    provider.gate.set()
    await terminal(client, first.json()["requestId"])
    settings.max_results = 1
    full = await submit(client)
    assert full.status_code == 429 and provider.stt_calls == 1
