from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol


@dataclass(frozen=True, slots=True)
class STTResult:
    text: str
    actual_units: int | None = None
    ttfb_seconds: float | None = None


@dataclass(frozen=True, slots=True)
class PolishResult:
    text: str
    actual_units: int | None = None
    ttfb_seconds: float | None = None


class ProviderError(Exception):
    """A sanitized provider failure suitable for task-layer classification."""

    def __init__(self, code: str = "upstream_failed", uncertain: bool = False,
                 *, kind: str = "none", ttfb_seconds: float | None = None) -> None:
        self.code = code
        self.uncertain = uncertain
        self.kind = kind if kind in {"none", "invalid", "truncated", "http"} else "none"
        self.ttfb_seconds = ttfb_seconds
        super().__init__(code)


class Provider(Protocol):
    async def transcribe(self, audio: bytes) -> STTResult: ...

    async def polish(self, text: str) -> PolishResult: ...

    async def aclose(self) -> None: ...
