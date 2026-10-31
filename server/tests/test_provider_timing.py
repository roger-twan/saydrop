import json
from types import SimpleNamespace

import httpx
import pytest

import saydrop_server.providers.openrouter as adapter
from saydrop_server.config import Settings
from saydrop_server.providers.base import ProviderError
from saydrop_server.providers.openrouter import OpenRouterProvider


@pytest.mark.parametrize("fail", [False, True])
async def test_ttfb_is_first_small_body_chunk_not_complete_json(monkeypatch, fail):
    now = [100.0]
    monkeypatch.setattr(adapter, "time", SimpleNamespace(monotonic=lambda: now[0]))

    class Chunks(httpx.AsyncByteStream):
        async def __aiter__(self):
            now[0] = 100.1
            yield b'{"te'
            now[0] = 100.9
            if fail:
                raise httpx.ReadTimeout("private-supplier-key-and-transcript")
            yield b'xt":"hello"}'

        async def aclose(self):
            pass

    def handler(request):
        payload = json.loads(request.content)
        assert "stream" not in payload
        assert request.url.host == "openrouter.ai"
        return httpx.Response(200, stream=Chunks())

    settings = Settings(token_pepper="p" * 64, fingerprint_key="f" * 64,
                        openrouter_api_key="private-supplier-key")
    provider = OpenRouterProvider(settings, transport=httpx.MockTransport(handler))
    try:
        if fail:
            with pytest.raises(ProviderError) as raised:
                await provider.transcribe(b"wav")
            assert raised.value.uncertain
            assert raised.value.ttfb_seconds == pytest.approx(0.1)
            assert "private" not in str(raised.value)
        else:
            result = await provider.transcribe(b"wav")
            assert result.text == "hello"
            assert result.ttfb_seconds == pytest.approx(0.1)
            assert result.ttfb_seconds < now[0] - 100
    finally:
        await provider.aclose()


async def test_error_body_is_never_consumed_for_timing():
    class ForbiddenBody(httpx.AsyncByteStream):
        async def __aiter__(self):
            raise AssertionError("must not read the private HTTP error body")
            yield b""

        async def aclose(self):
            pass

    settings = Settings(token_pepper="p" * 64, fingerprint_key="f" * 64)
    provider = OpenRouterProvider(settings, transport=httpx.MockTransport(
        lambda request: httpx.Response(503, stream=ForbiddenBody())))
    try:
        with pytest.raises(ProviderError) as raised:
            await provider.transcribe(b"wav")
        assert raised.value.kind == "http"
        assert raised.value.ttfb_seconds is None
    finally:
        await provider.aclose()
