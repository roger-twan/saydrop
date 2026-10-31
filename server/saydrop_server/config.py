from pathlib import Path
from typing import Literal

from dotenv import dotenv_values
from pydantic import BaseModel, ConfigDict, Field, SecretStr, field_validator, model_validator

SERVER_ROOT = Path(__file__).resolve().parents[1]


class Settings(BaseModel):
    model_config = ConfigDict(extra="forbid", hide_input_in_errors=True)
    environment: str = "development"
    database_path: Path = SERVER_ROOT / "data" / "saydrop.sqlite3"
    token_pepper: SecretStr
    fingerprint_key: SecretStr
    token_key_version: str = "v1"
    openrouter_api_key: SecretStr = SecretStr("")
    groq_api_key: SecretStr = SecretStr("")
    groq_proxy_url: str = ""
    metrics_token: SecretStr = SecretStr("")
    metrics_retention_days: Literal[30] = 30
    provider_mode: str = "openrouter"
    stt_model: str = "elevenlabs/scribe-v2"
    polish_model: str = "openai/gpt-4.1-mini"
    daily_budget_units: int = Field(default=0, ge=0)
    raw_estimate_units: int = Field(default=0, ge=0)
    polish_estimate_units: int = Field(default=0, ge=0)
    budget_config_version: str = "unconfigured"
    daily_quota: Literal[50] = 50
    timezone: Literal["Asia/Shanghai"] = "Asia/Shanghai"
    max_audio_bytes: int = Field(default=8 * 1024 * 1024, gt=0, le=8 * 1024 * 1024)
    max_audio_seconds: float = Field(default=120, gt=0, le=120)
    silence_rms: float = Field(default=32, ge=0)
    upload_timeout: float = Field(default=30, gt=0, le=30)
    stt_timeout: float = Field(default=45, gt=0, le=45)
    polish_timeout: float = Field(default=8, gt=0, le=8)
    task_timeout: float = Field(default=60, gt=0, le=60)
    result_ttl: float = Field(default=120, gt=0, le=120)
    tombstone_days: Literal[7] = 7
    max_active_tasks: int = Field(default=4, ge=1, le=4)
    max_results: int = Field(default=32, ge=1, le=32)
    register_ip_hour: int = Field(default=5, ge=1)
    register_global_hour: int = Field(default=100, ge=1)
    installation_minute: int = Field(default=60, ge=1)
    ip_minute: int = Field(default=120, ge=1)
    polish_max_chars: int = Field(default=16000, gt=0, le=16000)
    polish_max_tokens: Literal[2048] = 2048
    # Set only by explicit loopback developer configuration; otherwise require HTTPS.
    allow_loopback_http: bool = False

    @field_validator("groq_proxy_url")
    @classmethod
    def validate_groq_proxy(cls, value: str) -> str:
        from urllib.parse import urlsplit
        if value:
            try:
                url = urlsplit(value)
                valid = (url.scheme in {"http", "https"} and url.hostname in {"127.0.0.1", "localhost", "::1"}
                         and url.port is not None and url.username is None and url.password is None
                         and url.path in {"", "/"} and not url.query and not url.fragment)
            except ValueError:
                valid = False
            if not valid:
                raise ValueError("Groq proxy must be an explicit loopback HTTP(S) proxy")
        return value

    @field_validator("token_pepper", "fingerprint_key")
    @classmethod
    def validate_secret(cls, value: SecretStr) -> SecretStr:
        if len(value.get_secret_value()) < 32:
            raise ValueError("server secret must contain at least 32 characters")
        return value

    @field_validator("metrics_token")
    @classmethod
    def validate_metrics_token(cls, value: SecretStr) -> SecretStr:
        text = value.get_secret_value()
        if text and (len(text) != 43 or any(c not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-" for c in text)):
            raise ValueError("monitoring token must be a 256-bit base64url token")
        return value

    @field_validator("stt_model")
    @classmethod
    def validate_stt(cls, value: str) -> str:
        if value not in {"elevenlabs/scribe-v2", "openai/whisper-large-v3-turbo", "whisper-large-v3", "whisper-large-v3-turbo"}:
            raise ValueError("STT model is not in the approved whitelist")
        return value

    @field_validator("polish_model")
    @classmethod
    def validate_polish(cls, value: str) -> str:
        if value != "openai/gpt-4.1-mini":
            raise ValueError("polish model is not in the approved whitelist")
        return value

    @field_validator("provider_mode")
    @classmethod
    def validate_provider(cls, value: str) -> str:
        if value not in {"openrouter", "groq", "mock"}:
            raise ValueError("unknown provider mode")
        return value

    @model_validator(mode="after")
    def validate_provider_model(self):
        if self.provider_mode == "groq" and "stt_model" not in self.model_fields_set:
            self.stt_model = "whisper-large-v3-turbo"
        groq_model = self.stt_model in {"whisper-large-v3", "whisper-large-v3-turbo"}
        if self.provider_mode != "mock" and groq_model != (self.provider_mode == "groq"):
            raise ValueError("STT model does not match provider")
        return self

    def budget_available(self) -> bool:
        return (
            self.daily_budget_units > 0
            and self.raw_estimate_units > 0
            and self.polish_estimate_units > 0
            and self.budget_config_version.strip() not in {"", "unconfigured"}
            and (self.provider_mode == "mock" or bool((self.groq_api_key if self.provider_mode == "groq" else self.openrouter_api_key).get_secret_value().strip()))
        )

    @classmethod
    def load(cls, path: Path | None = None) -> "Settings":
        import os

        values = {**dotenv_values(path or SERVER_ROOT / ".env"), **os.environ}
        data = {}
        for name, field in cls.model_fields.items():
            key = {"openrouter_api_key": "OPENROUTER_API_KEY", "groq_api_key": "GROQ_API_KEY"}.get(name, "SAYDROP_" + name.upper())
            if key in values and values[key] is not None:
                raw = values[key]
                # Invalid budget numbers must fail closed, not become inferred prices.
                if name in {"daily_budget_units", "raw_estimate_units", "polish_estimate_units"}:
                    try:
                        raw = max(0, int(raw))
                    except (ValueError, TypeError):
                        raw = 0
                if name == "metrics_retention_days":
                    # dotenv/env values are strings; Literal[30] requires an integer.
                    # Keep malformed values invalid instead of silently using a default.
                    try:
                        raw = int(raw)
                    except (ValueError, TypeError):
                        pass
                data[name] = raw
        settings = cls.model_validate(data)
        if settings.environment != "development" and (
            settings.provider_mode == "mock" or settings.allow_loopback_http
        ):
            raise ValueError("mock and HTTP exceptions are development-only")
        return settings
