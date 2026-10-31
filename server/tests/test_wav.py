"""WAV validation tests using synthesized fake PCM bytes only; no microphone or real audio."""

import asyncio
import struct
import time
from collections.abc import AsyncIterator

import pytest

from saydrop_server.config import Settings
from saydrop_server.errors import ApiError, ErrorCode
from saydrop_server.wav_validation import WavMetadata, read_wav, validate_wav


# These fixtures are deliberately fake audio: synthesized PCM bytes, not recordings.
def fake_settings(**overrides: object) -> Settings:
    return Settings(
        token_pepper="t" * 32,
        fingerprint_key="f" * 32,
        **overrides,
    )


def fake_pcm_wav(
    samples: list[int],
    *,
    audio_format: int = 1,
    channels: int = 1,
    sample_rate: int = 16_000,
    bits_per_sample: int = 16,
    fmt_size: int = 16,
    extra_chunks: list[tuple[bytes, bytes]] | None = None,
) -> bytes:
    """Build a canonical RIFF/WAVE byte sequence for fake-audio tests."""
    block_align = channels * (bits_per_sample // 8)
    byte_rate = sample_rate * block_align
    fmt_payload = struct.pack(
        "<HHIIHH",
        audio_format,
        channels,
        sample_rate,
        byte_rate,
        block_align,
        bits_per_sample,
    )
    if fmt_size < len(fmt_payload):
        raise ValueError("fmt_size cannot truncate required PCM fields")
    fmt_payload += b"\x00" * (fmt_size - len(fmt_payload))
    pcm = struct.pack(f"<{len(samples)}h", *samples)
    chunks = [(b"fmt ", fmt_payload), *(extra_chunks or []), (b"data", pcm)]
    encoded_chunks = bytearray()
    for chunk_id, payload in chunks:
        encoded_chunks.extend(chunk_id)
        encoded_chunks.extend(struct.pack("<I", len(payload)))
        encoded_chunks.extend(payload)
        if len(payload) % 2:
            encoded_chunks.append(0)
    return b"RIFF" + struct.pack("<I", 4 + len(encoded_chunks)) + b"WAVE" + bytes(encoded_chunks)


def fake_error_code(error: ApiError) -> str:
    return error.code


class FakeRequest:
    """Minimal fake request stream; it never performs network I/O."""

    def __init__(
        self,
        chunks: list[bytes],
        *,
        content_length: str | None = None,
        chunk_delay: float = 0,
        disconnected: bool = False,
    ) -> None:
        self._chunks = chunks
        self._chunk_delay = chunk_delay
        self._disconnected = disconnected
        self.headers: dict[str, str] = {}
        if content_length is not None:
            self.headers["content-length"] = content_length

    async def stream(self) -> AsyncIterator[bytes]:
        for chunk in self._chunks:
            if self._chunk_delay:
                await asyncio.sleep(self._chunk_delay)
            yield chunk

    async def is_disconnected(self) -> bool:
        return self._disconnected


def test_fake_wav_accepts_16khz_mono_pcm16_and_reports_metadata() -> None:
    metadata = validate_wav(fake_pcm_wav([1_000, -1_000] * 80), fake_settings())

    assert metadata == WavMetadata(duration_seconds=0.01, frames=160)


@pytest.mark.parametrize(
    ("mutate", "expected"),
    [
        (lambda wav: b"NOPE" + wav[4:], ErrorCode.INVALID_WAV),
        (lambda wav: wav[:8] + struct.pack("<I", 4) + wav[12:], ErrorCode.INVALID_WAV),
        (lambda wav: wav[:-1], ErrorCode.INVALID_WAV),
    ],
    ids=["not-riff", "incorrect-riff-length", "truncated-chunk"],
)
def test_fake_wav_rejects_invalid_riff_container(
    mutate: object, expected: ErrorCode
) -> None:
    wav = fake_pcm_wav([1_000, -1_000])

    with pytest.raises(ApiError) as caught:
        validate_wav(mutate(wav), fake_settings())  # type: ignore[operator]

    assert fake_error_code(caught.value) == expected.value


def test_fake_wav_rejects_duplicate_fmt_or_data_chunks() -> None:
    fmt_payload = struct.pack("<HHIIHH", 1, 1, 16_000, 32_000, 2, 16)
    duplicate_fmt = fake_pcm_wav([1_000], extra_chunks=[(b"fmt ", fmt_payload)])
    duplicate_data = fake_pcm_wav([1_000], extra_chunks=[(b"data", b"\x01\x00")])

    for wav in (duplicate_fmt, duplicate_data):
        with pytest.raises(ApiError) as caught:
            validate_wav(wav, fake_settings())
        assert fake_error_code(caught.value) == ErrorCode.INVALID_WAV.value


@pytest.mark.parametrize(
    "wav",
    [
        fake_pcm_wav([1_000], channels=2),
        fake_pcm_wav([1_000], sample_rate=44_100),
        fake_pcm_wav([1_000], bits_per_sample=8),
        fake_pcm_wav([1_000], audio_format=3),
        fake_pcm_wav([1_000], fmt_size=18),
    ],
    ids=["stereo", "wrong-rate", "wrong-bits", "float-format", "extended-fmt"],
)
def test_fake_wav_rejects_noncanonical_pcm_format(wav: bytes) -> None:
    with pytest.raises(ApiError) as caught:
        validate_wav(wav, fake_settings())

    assert fake_error_code(caught.value) == ErrorCode.INVALID_WAV.value


def test_fake_wav_rejects_empty_data_and_silence_at_threshold() -> None:
    for wav in (fake_pcm_wav([]), fake_pcm_wav([32, -32])):
        with pytest.raises(ApiError) as caught:
            validate_wav(wav, fake_settings())
        assert fake_error_code(caught.value) == ErrorCode.EMPTY_AUDIO.value


def test_fake_wav_rejects_too_large_before_container_parsing() -> None:
    settings = fake_settings(max_audio_bytes=32)

    with pytest.raises(ApiError) as caught:
        validate_wav(b"x" * 33, settings)

    assert fake_error_code(caught.value) == ErrorCode.AUDIO_TOO_LARGE.value


def test_fake_wav_rejects_duration_over_limit() -> None:
    settings = fake_settings(max_audio_seconds=0.01)

    with pytest.raises(ApiError) as caught:
        validate_wav(fake_pcm_wav([1_000] * 161), settings)

    assert fake_error_code(caught.value) == ErrorCode.AUDIO_TOO_LONG.value


@pytest.mark.asyncio
async def test_read_wav_collects_fake_request_stream_in_memory() -> None:
    wav = fake_pcm_wav([1_000, -1_000])
    request = FakeRequest([wav[:10], wav[10:]], content_length=str(len(wav)))

    received = await read_wav(request, fake_settings(), time.monotonic() + 1)

    assert received == wav


@pytest.mark.asyncio
async def test_read_wav_prechecks_content_length_and_each_streamed_chunk() -> None:
    settings = fake_settings(max_audio_bytes=10)

    with pytest.raises(ApiError) as header_error:
        await read_wav(FakeRequest([], content_length="11"), settings, time.monotonic() + 1)
    assert fake_error_code(header_error.value) == ErrorCode.AUDIO_TOO_LARGE.value

    with pytest.raises(ApiError) as chunk_error:
        await read_wav(FakeRequest([b"12345", b"678901"]), settings, time.monotonic() + 1)
    assert fake_error_code(chunk_error.value) == ErrorCode.AUDIO_TOO_LARGE.value


@pytest.mark.asyncio
async def test_read_wav_times_out_for_elapsed_task_or_upload_deadline() -> None:
    with pytest.raises(ApiError) as elapsed_error:
        await read_wav(FakeRequest([b"data"]), fake_settings(), time.monotonic() - 0.001)
    assert fake_error_code(elapsed_error.value) == ErrorCode.REQUEST_TIMEOUT.value
    assert elapsed_error.value.status_code == 408
    assert elapsed_error.value.retryable is True

    with pytest.raises(ApiError) as upload_error:
        await read_wav(
            FakeRequest([b"data"], chunk_delay=0.03),
            fake_settings(upload_timeout=0.01),
            time.monotonic() + 1,
        )
    assert fake_error_code(upload_error.value) == ErrorCode.REQUEST_TIMEOUT.value
    assert upload_error.value.status_code == 408
    assert upload_error.value.retryable is True


@pytest.mark.asyncio
async def test_read_wav_stops_safely_when_fake_client_is_disconnected() -> None:
    with pytest.raises(ApiError) as caught:
        await read_wav(FakeRequest([b"audio"], disconnected=True), fake_settings(), time.monotonic() + 1)

    assert fake_error_code(caught.value) == ErrorCode.REQUEST_CANCELLED.value
