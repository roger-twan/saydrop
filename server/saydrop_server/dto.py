from enum import StrEnum
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class OutputMode(StrEnum):
    RAW = "raw"
    LIGHT_POLISH = "light_polish"


class TaskStatus(StrEnum):
    PROCESSING = "processing"
    READY = "ready"
    FAILED = "failed"
    CANCELLED = "cancelled"
    UNKNOWN = "unknown"
    RESULT_EXPIRED = "result_expired"


class PolishStatus(StrEnum):
    NOT_REQUESTED = "not_requested"
    PENDING = "pending"
    SUCCEEDED = "succeeded"
    FAILED_FALLBACK_RAW = "failed_fallback_raw"


class InstallRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    clientVersion: str = Field(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9.+_-]+$")
    platform: Literal["macos-arm64"]


class Quota(BaseModel):
    model_config = ConfigDict(extra="forbid")
    limit: int = Field(ge=0)
    used: int = Field(ge=0)
    reserved: int = Field(ge=0)
    remaining: int = Field(ge=0)
    resetAt: str


class TaskResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")
    requestId: str
    status: TaskStatus
    outputMode: OutputMode
    polishStatus: PolishStatus
    quota: Quota
    rawText: str | None = None
    outputText: str | None = None
    resultExpiresAt: str | None = None
    error: dict | None = None
