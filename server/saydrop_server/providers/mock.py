from __future__ import annotations

from saydrop_server.config import Settings
from saydrop_server.providers.base import PolishResult, STTResult


class MockProvider:
    """Development-only in-memory provider injected explicitly by application wiring."""

    def __init__(self, settings: Settings) -> None:
        if settings.environment != "development":
            raise ValueError("MockProvider is available only in development")

    async def transcribe(self, audio: bytes) -> STTResult:
        # The mock deliberately does not inspect, persist, or send the supplied audio.
        return STTResult(text="[MOCK] transcription result; no audio was sent upstream")

    async def polish(self, text: str) -> PolishResult:
        # Never present a mocked value as a model-produced polish of user text.
        return PolishResult(text="[MOCK] polish result; no text was sent upstream")

    async def aclose(self) -> None:
        return None
