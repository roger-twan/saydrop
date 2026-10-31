import subprocess
import sys

import httpx
from test_api import FakeProvider, submit, terminal, wav

from saydrop_server.config import Settings
from saydrop_server.main import create_app
from saydrop_server.storage import migrate


def test_import_main_never_loads_dotenv():
    source = '''
import dotenv

def deny(*args, **kwargs):
    raise AssertionError("module import must not read .env")

dotenv.dotenv_values = deny
import saydrop_server.main
assert callable(saydrop_server.main.create_app)
assert not hasattr(saydrop_server.main, "app")
'''
    result = subprocess.run([sys.executable, "-c", source], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


async def test_https_required_and_only_explicit_loopback_exception(tmp_path):
    settings = Settings(token_pepper="p" * 64, fingerprint_key="f" * 64,
                        database_path=tmp_path / "test.sqlite3", provider_mode="mock")
    migrate(settings.database_path)
    app = create_app(settings, provider=FakeProvider())
    async with app.router.lifespan_context(app):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://127.0.0.1") as client:
            denied = await client.get("/healthz")
            assert denied.status_code == 403 and denied.json()["error"]["code"] == "forbidden"
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="https://saydrop.invalid") as client:
            assert (await client.get("/healthz")).status_code == 200
        settings.allow_loopback_http = True
        remote_transport = httpx.ASGITransport(app=app, client=("192.0.2.1", 1234))
        async with httpx.AsyncClient(transport=remote_transport, base_url="http://saydrop.invalid") as client:
            assert (await client.get("/healthz", headers={"X-Forwarded-Proto": "https"})).status_code == 403


async def test_http_51_parallel_one_active_and_lost_post_receipt(tmp_path):
    import asyncio
    from uuid import uuid4
    settings = Settings(token_pepper="p" * 64, fingerprint_key="f" * 64,
                        database_path=tmp_path / "test.sqlite3", provider_mode="mock",
                        daily_budget_units=10000, raw_estimate_units=120,
                        polish_estimate_units=240, budget_config_version="mock-v1", allow_loopback_http=True)
    migrate(settings.database_path)
    provider = FakeProvider()
    provider.gate = asyncio.Event()
    app = create_app(settings, provider=provider)
    async with app.router.lifespan_context(app):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://127.0.0.1") as client:
            registration = await client.post("/v1/installations", json={"clientVersion": "0.1", "platform": "macos-arm64"})
            client.headers["Authorization"] = "Bearer " + registration.json()["accessToken"]
            keys = [str(uuid4()) for _ in range(51)]
            responses = await asyncio.gather(*(submit(client, key=key) for key in keys))
            accepted = [i for i, response in enumerate(responses) if response.status_code == 202]
            assert len(accepted) == 1
            assert all(response.status_code in {202, 429} for response in responses)
            # UUID was generated before the POST; simulate discarding its 202 and recovering by GET.
            key = keys[accepted[0]]
            assert (await client.get("/v1/transcriptions/" + key)).json()["status"] == "processing"
            provider.gate.set()
            assert (await terminal(client, key)).json()["quota"]["used"] == 1
            assert provider.stt_calls == 1


async def test_quota_exhausted_typed_error_and_size_precheck(tmp_path):
    from uuid import uuid4
    settings = Settings(token_pepper="p" * 64, fingerprint_key="f" * 64,
                        database_path=tmp_path / "test.sqlite3", provider_mode="mock",
                        daily_budget_units=10000, raw_estimate_units=120,
                        polish_estimate_units=240, budget_config_version="mock-v1", allow_loopback_http=True)
    migrate(settings.database_path)
    provider = FakeProvider()
    app = create_app(settings, provider=provider)
    async with app.router.lifespan_context(app):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://127.0.0.1") as client:
            registration = await client.post("/v1/installations", json={"clientVersion": "0.1", "platform": "macos-arm64"})
            owner = registration.json()["installationId"]
            client.headers["Authorization"] = "Bearer " + registration.json()["accessToken"]
            oversized = await client.post("/v1/transcriptions", content=wav(),
                                           headers={"Content-Type": "audio/wav", "Content-Length": str(8 * 1024 * 1024 + 1),
                                                    "Idempotency-Key": str(uuid4()), "X-Output-Mode": "raw"})
            assert oversized.status_code == 422 and oversized.json()["error"]["code"] == "audio_too_large"
            with app.state.store.transaction() as conn:
                conn.exec_driver_sql("INSERT INTO daily_quotas VALUES (?,?,50,50,0,?,?)",
                                     (owner, app.state.store.clock().date().isoformat(), app.state.store.now_iso(), app.state.store.now_iso()))
            denied = await submit(client)
            assert denied.status_code == 429 and denied.json()["error"]["code"] == "quota_exhausted"
            assert denied.json()["quota"]["remaining"] == 0 and provider.stt_calls == 0
