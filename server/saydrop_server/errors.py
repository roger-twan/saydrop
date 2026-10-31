from enum import StrEnum


class ErrorCode(StrEnum):
    INVALID_REQUEST = "invalid_request"
    INVALID_TOKEN = "invalid_token"
    INSTALLATION_REVOKED = "installation_revoked"
    INVALID_WAV = "invalid_wav"
    AUDIO_TOO_LARGE = "audio_too_large"
    AUDIO_TOO_LONG = "audio_too_long"
    EMPTY_AUDIO = "empty_audio"
    QUOTA_EXHAUSTED = "quota_exhausted"
    BUDGET_UNAVAILABLE = "budget_unavailable"
    RATE_LIMITED = "rate_limited"
    IDEMPOTENCY_CONFLICT = "idempotency_conflict"
    NOT_FOUND = "not_found"
    FORBIDDEN = "forbidden"
    UPSTREAM_FAILED = "upstream_failed"
    REQUEST_TIMEOUT = "request_timeout"
    RESULT_EXPIRED = "result_expired"
    REQUEST_CANCELLED = "request_cancelled"
    INTERNAL_ERROR = "internal_error"


MESSAGES = {
    "invalid_request": "The request parameters are invalid.",
    "invalid_token": "The installation credential is invalid. Obtain a new credential.",
    "installation_revoked": "This installation credential has been revoked.",
    "invalid_wav": "Audio must be 16 kHz, mono, 16-bit PCM WAV.",
    "audio_too_large": "Audio exceeds the 8 MiB upload limit.",
    "audio_too_long": "Audio exceeds the 120-second limit.",
    "empty_audio": "Audio is empty or too quiet.",
    "quota_exhausted": "Today's transcription quota is exhausted. Try again after it resets.",
    "budget_unavailable": "Transcription is temporarily unavailable. Create a new request later.",
    "rate_limited": "Too many requests or the service is busy. Try again later.",
    "idempotency_conflict": "This request ID was already used with different audio or output mode.",
    "not_found": "The request was not found.",
    "forbidden": "This operation is unavailable.",
    "upstream_failed": "Cloud transcription failed and may have counted against your quota. Do not resend automatically.",
    "request_timeout": "The request timed out and may have counted against your quota. Check the original request.",
    "result_expired": "The result has expired and cannot be recovered.",
    "request_cancelled": "The request was cancelled. Dispatched requests do not restore quota.",
    "internal_error": "The service encountered a temporary error.",
}


class ApiError(Exception):
    def __init__(self, code: str | ErrorCode, status_code: int = 422, *, retryable: bool = False):
        self.code = ErrorCode(code).value
        self.status_code = status_code
        self.retryable = retryable
        super().__init__(self.code)

    def payload(self) -> dict:
        return {"code": self.code, "message": MESSAGES[self.code], "retryable": self.retryable}
