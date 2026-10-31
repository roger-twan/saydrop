import httpx
import pytest
from pydantic import ValidationError

from saydrop_server.config import Settings
from saydrop_server.observability import MetricSample, MetricStore
from saydrop_server.providers.base import ProviderError
from saydrop_server.providers.groq import GroqProvider
from saydrop_server.storage import Store, migrate


def settings(**kwargs):
    return Settings(token_pepper="p" * 32, fingerprint_key="f" * 32,
                    provider_mode="groq", groq_api_key="test-secret", **kwargs)


def test_config_requires_matching_model_and_groq_key():
    s = settings(daily_budget_units=100, raw_estimate_units=1,
                 polish_estimate_units=2, budget_config_version="test")
    assert s.stt_model == "whisper-large-v3-turbo" and s.budget_available()
    assert not s.model_copy(update={"groq_api_key": Settings.model_fields['groq_api_key'].default}).budget_available()
    with pytest.raises(ValidationError):
        settings(stt_model="elevenlabs/scribe-v2")
    with pytest.raises(ValidationError):
        Settings(token_pepper="p" * 32, fingerprint_key="f" * 32, stt_model="whisper-large-v3")


@pytest.mark.asyncio
async def test_multipart_and_no_polish_network():
    calls = []
    async def handler(request):
        calls.append(request)
        assert str(request.url) == "https://api.groq.com/openai/v1/audio/transcriptions"
        assert request.headers['authorization'] == 'Bearer test-secret'
        assert request.headers['content-type'].startswith('multipart/form-data;')
        body = await request.aread()
        assert b'filename="recording.wav"' in body and b'RIFF-test' in body
        assert b'whisper-large-v3-turbo' in body
        return httpx.Response(200, json={"text": "\u4E2D\u6587 test"})
    p = GroqProvider(settings(), transport=httpx.MockTransport(handler))
    try:
        assert (await p.transcribe(b'RIFF-test')).text == '\u4E2D\u6587 test'
        with pytest.raises(ProviderError):
            await p.polish('private text')
        assert len(calls) == 1
    finally:
        await p.aclose()


@pytest.mark.asyncio
@pytest.mark.parametrize('status,payload,kind', [(402, {'error':'secret'}, 'http'),
                                               (429, {}, 'http'), (200, {'text':''}, 'invalid'),
                                               (200, [], 'invalid')])
async def test_sanitized_errors(status, payload, kind, caplog):
    p = GroqProvider(settings(), transport=httpx.MockTransport(lambda r: httpx.Response(status, json=payload)))
    try:
        with pytest.raises(ProviderError) as exc:
            await p.transcribe(b'audio')
        assert exc.value.kind == kind
        assert 'secret' not in caplog.text
        assert 'audio' not in caplog.text
    finally:
        await p.aclose()


def test_v2_upgrade_preserves_metrics_and_accepts_groq(tmp_path, monkeypatch):
    import saydrop_server.storage as storage
    path = tmp_path / 'data.sqlite3'
    monkeypatch.setattr(storage, 'REVISION', 2)
    migrate(path)
    s = settings(database_path=path)
    old = Store(s)
    MetricStore(old).record([MetricSample('sttSeconds', 1, model='elevenlabs/scribe-v2', source='live')])
    old.engine.dispose()
    monkeypatch.setattr(storage, 'REVISION', 3)
    migrate(path)
    new = Store(s)
    MetricStore(new).record([MetricSample('sttSeconds', 2, model='whisper-large-v3-turbo', source='live')])
    with new.engine.connect() as conn:
        assert conn.exec_driver_sql('SELECT COUNT(*) FROM metric_samples').scalar_one() == 2
    new.engine.dispose()


@pytest.mark.asyncio
async def test_full_task_pipeline_groq_and_raw_fallback(tmp_path):
    from uuid import uuid4

    from test_api import submit, terminal

    from saydrop_server.main import create_app
    calls = []
    def handler(request):
        calls.append(str(request.url))
        return httpx.Response(200, json={'text': 'Groq \u6D4B\u8BD5\u6587\u672C'})
    s = settings(database_path=tmp_path / 'api.sqlite3', daily_budget_units=100,
                 raw_estimate_units=1, polish_estimate_units=2, budget_config_version='test',
                 allow_loopback_http=True)
    migrate(s.database_path)
    p = GroqProvider(s, transport=httpx.MockTransport(handler))
    app = create_app(s, provider=p)
    async with app.router.lifespan_context(app):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app), base_url='http://127.0.0.1') as client:
            registration = await client.post('/v1/installations', json={'clientVersion':'0.1', 'platform':'macos-arm64'})
            client.headers['Authorization'] = 'Bearer ' + registration.json()['accessToken']
            for mode in ('raw', 'light_polish'):
                key = str(uuid4())
                assert (await submit(client, mode=mode, key=key)).status_code == 202
                result = (await terminal(client, key)).json()
                assert result['status'] == 'ready'
                assert result['outputText'] == 'Groq \u6D4B\u8BD5\u6587\u672C'
                assert result['polishStatus'] == ('not_requested' if mode == 'raw' else 'failed_fallback_raw')
            assert len(calls) == 2
            with app.state.store.engine.connect() as conn:
                assert conn.exec_driver_sql("SELECT COUNT(*) FROM metric_samples WHERE model='whisper-large-v3-turbo' AND name='terminalCount'").scalar_one() == 2


def test_explicit_proxy_rejects_remote_or_credential_urls():
    assert settings(groq_proxy_url='http://127.0.0.1:7890').groq_proxy_url.endswith(':7890')
    for value in ('http://example.com:7890', 'http://user:secret@localhost:7890',
                  'http://localhost:7890/path', 'http://localhost:bad', 'socks5://localhost:7890'):
        with pytest.raises(ValidationError):
            settings(groq_proxy_url=value)


@pytest.mark.asyncio
async def test_explicit_proxy_is_passed_to_transport(monkeypatch):
    seen = []
    class LocalTransport(httpx.AsyncBaseTransport):
        async def handle_async_request(self, request):
            return httpx.Response(200, json={'text': 'test'})
    def factory(**kwargs):
        seen.append(kwargs)
        return LocalTransport()
    monkeypatch.setattr(httpx, 'AsyncHTTPTransport', factory)
    p = GroqProvider(settings(groq_proxy_url='http://127.0.0.1:7890'))
    try:
        await p.transcribe(b'synthetic')
        assert seen == [{'retries': 0, 'proxy': 'http://127.0.0.1:7890'}]
    finally:
        await p.aclose()
