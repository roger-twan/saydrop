"""Bounded in-memory reading and validation for raw PCM WAV request bodies."""

from __future__ import annotations

import asyncio
import inspect
import struct
import time
from dataclasses import dataclass
from typing import Any

from starlette.requests import ClientDisconnect, Request

from .config import Settings
from .errors import ApiError, ErrorCode


@dataclass(frozen=True, slots=True)
class WavMetadata:
    duration_seconds: float
    frames: int


def _invalid_wav() -> None:
    raise ApiError(ErrorCode.INVALID_WAV)


def _audio_too_large() -> None:
    raise ApiError(ErrorCode.AUDIO_TOO_LARGE)


def _empty_audio() -> None:
    raise ApiError(ErrorCode.EMPTY_AUDIO)


def _request_timeout() -> None:
    raise ApiError(ErrorCode.REQUEST_TIMEOUT, status_code=408, retryable=True)


def _content_length(request: Any) -> int | None:
    """Read the optional header without relying on a concrete request implementation."""
    headers = getattr(request, "headers", {})
    raw_length = headers.get("content-length")
    if raw_length is None:
        raw_length = headers.get("Content-Length")
    if raw_length is None:
        return None
    if not isinstance(raw_length, str) or not raw_length.isascii() or not raw_length.isdecimal():
        raise ApiError(ErrorCode.INVALID_REQUEST)
    return int(raw_length)


async def _client_disconnected(request: Any) -> bool:
    """Check disconnection when the request implementation exposes that capability."""
    # Starlette's is_disconnected can consume an http.request event before stream().
    # Its stream reader already raises ClientDisconnect, so never pre-read that channel.
    if isinstance(request, Request):
        return False
    checker = getattr(request, "is_disconnected", None)
    if checker is None:
        return False
    disconnected = checker()
    if inspect.isawaitable(disconnected):
        disconnected = await disconnected
    return bool(disconnected)


async def read_wav(request: Any, settings: Settings, deadline: float) -> bytes:
    """Read a raw WAV body with bounded memory and the earlier task/upload deadline.

    ``deadline`` is an absolute ``time.monotonic()`` deadline for the surrounding
    task. This reader additionally limits receipt to ``settings.upload_timeout``.
    It intentionally neither uses a spool/file nor logs any request body bytes.
    """
    started_at = time.monotonic()
    upload_deadline = min(deadline, started_at + settings.upload_timeout)
    if upload_deadline <= started_at:
        _request_timeout()

    declared_length = _content_length(request)
    if declared_length is not None and declared_length > settings.max_audio_bytes:
        _audio_too_large()

    if await _client_disconnected(request):
        # The peer cannot receive a response, but this lets the route stop work
        # without retaining body bytes or treating the partial upload as audio.
        raise ApiError(ErrorCode.REQUEST_CANCELLED, status_code=499)

    buffer = bytearray()
    try:
        async with asyncio.timeout_at(upload_deadline):
            async for chunk in request.stream():
                if time.monotonic() >= upload_deadline:
                    _request_timeout()
                if await _client_disconnected(request):
                    raise ApiError(ErrorCode.REQUEST_CANCELLED, status_code=499)
                if not isinstance(chunk, bytes):
                    raise ApiError(ErrorCode.INVALID_REQUEST)
                if len(buffer) + len(chunk) > settings.max_audio_bytes:
                    _audio_too_large()
                buffer.extend(chunk)
            if time.monotonic() >= upload_deadline:
                _request_timeout()
            if await _client_disconnected(request):
                raise ApiError(ErrorCode.REQUEST_CANCELLED, status_code=499)
    except TimeoutError:
        _request_timeout()
    except ClientDisconnect:
        raise ApiError(ErrorCode.REQUEST_CANCELLED, status_code=499) from None

    return bytes(buffer)


def validate_wav(data: bytes, settings: Settings) -> WavMetadata:
    """Validate a canonical 16 kHz, mono, PCM16 RIFF/WAVE byte sequence.

    The supplied bytes are already bounded by ``read_wav`` in normal request
    handling, but the size check is repeated so direct callers receive the same
    protection and typed error. Parsing uses offsets and memoryviews only; it
    never copies a PCM chunk or writes audio to disk.
    """
    if not data:
        _empty_audio()
    if len(data) > settings.max_audio_bytes:
        _audio_too_large()
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        _invalid_wav()

    riff_size = struct.unpack_from("<I", data, 4)[0]
    if riff_size != len(data) - 8:
        _invalid_wav()

    container_end = len(data)
    cursor = 12
    fmt_seen = False
    data_seen = False
    audio_format = channels = sample_rate = byte_rate = block_align = bits_per_sample = 0
    pcm_offset = pcm_size = 0

    while cursor < container_end:
        if container_end - cursor < 8:
            _invalid_wav()
        chunk_id = data[cursor : cursor + 4]
        chunk_size = struct.unpack_from("<I", data, cursor + 4)[0]
        chunk_start = cursor + 8
        chunk_end = chunk_start + chunk_size
        padded_end = chunk_end + (chunk_size & 1)
        if chunk_end > container_end or padded_end > container_end:
            _invalid_wav()

        if chunk_id == b"fmt ":
            if fmt_seen or chunk_size != 16:
                _invalid_wav()
            fmt_seen = True
            (
                audio_format,
                channels,
                sample_rate,
                byte_rate,
                block_align,
                bits_per_sample,
            ) = struct.unpack_from("<HHIIHH", data, chunk_start)
        elif chunk_id == b"data":
            if data_seen:
                _invalid_wav()
            data_seen = True
            pcm_offset = chunk_start
            pcm_size = chunk_size

        cursor = padded_end

    if cursor != container_end or not fmt_seen or not data_seen:
        _invalid_wav()
    if (
        audio_format != 1
        or channels != 1
        or sample_rate != 16_000
        or bits_per_sample != 16
        or block_align != 2
        or byte_rate != 32_000
    ):
        _invalid_wav()
    if pcm_size % block_align:
        _invalid_wav()

    frames = pcm_size // block_align
    if frames == 0:
        _empty_audio()

    duration_seconds = frames / sample_rate
    if duration_seconds > settings.max_audio_seconds:
        raise ApiError(ErrorCode.AUDIO_TOO_LONG)

    pcm = memoryview(data)[pcm_offset : pcm_offset + pcm_size]
    sum_squares = 0
    for (sample,) in struct.iter_unpack("<h", pcm):
        sum_squares += sample * sample
    rms = (sum_squares / frames) ** 0.5
    if rms <= settings.silence_rms:
        _empty_audio()

    return WavMetadata(duration_seconds=duration_seconds, frames=frames)
