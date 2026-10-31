"""Groq STT only: no paid OpenRouter polish or automatic provider fallback."""
import logging
import time

import httpx

from saydrop_server.providers.base import ProviderError, STTResult
from saydrop_server.providers.openrouter import OpenRouterProvider, _ResponseTiming

logger = logging.getLogger(__name__)


class GroqProvider(OpenRouterProvider):
    def __init__(self, settings, *, transport=None):
        self._settings = settings
        self._client = httpx.AsyncClient(
            transport=transport or httpx.AsyncHTTPTransport(retries=0, proxy=settings.groq_proxy_url or None),
            trust_env=False, follow_redirects=False,
        )

    async def transcribe(self, audio: bytes) -> STTResult:
        timing = _ResponseTiming(time.monotonic())
        try:
            async with self._client.stream(
                "POST", "https://api.groq.com/openai/v1/audio/transcriptions",
                headers={"Authorization": f"Bearer {self._settings.groq_api_key.get_secret_value()}"},
                files={"file": ("recording.wav", audio, "audio/wav")},
                data={"model": self._settings.stt_model, "response_format": "json", "temperature": "0"},
                timeout=self._settings.stt_timeout,
            ) as response:
                if not response.is_success:
                    # Only bounded numeric diagnostics, never body, headers or audio.
                    logger.warning("Groq STT HTTP status=%d", response.status_code)
                    raise ProviderError(kind="http")
                decoded = await self._bounded_json(response, timing)
                text = decoded.get("text")
                if not isinstance(text, str) or not text.strip():
                    raise ProviderError(kind="invalid", ttfb_seconds=timing.ttfb)
                text.encode("utf-8", "strict")
                return STTResult(text=text, ttfb_seconds=timing.ttfb)
        except ProviderError:
            raise
        except httpx.TimeoutException:
            raise ProviderError("request_timeout", uncertain=True, ttfb_seconds=timing.ttfb) from None
        except httpx.RequestError:
            raise ProviderError(uncertain=True, ttfb_seconds=timing.ttfb) from None
        except (UnicodeError, ValueError, TypeError):
            raise ProviderError(kind="invalid", ttfb_seconds=timing.ttfb) from None

    async def polish(self, text: str):
        # The existing task contract visibly marks this as failed_fallback_raw.
        raise ProviderError()
