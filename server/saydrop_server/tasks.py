import asyncio
import time
from dataclasses import dataclass
from datetime import timedelta

from saydrop_server.config import Settings
from saydrop_server.errors import ApiError
from saydrop_server.monitoring import TaskTrace
from saydrop_server.providers.base import ProviderError
from saydrop_server.providers.polish_safety import safe_polish
from saydrop_server.storage import Store


@dataclass
class MemoryResult:
    raw_text: str
    output_text: str
    expires_monotonic: float


class TaskManager:
    def __init__(self, store: Store, provider, settings: Settings, clock=time.monotonic, *, monitor=None):
        self.store, self.provider, self.settings, self.clock = store, provider, settings, clock
        self.monitor = monitor
        self.jobs: dict[tuple[str, str], asyncio.Task] = {}
        self.results: dict[tuple[str, str], MemoryResult] = {}
        self.uploads = 0

    def claim_upload(self):
        self.sweep()
        if self.uploads + len(self.jobs) >= self.settings.max_active_tasks:
            raise ApiError("rate_limited", 429, retryable=True)
        self.uploads += 1

    def has_result_capacity(self) -> bool:
        self.sweep()
        return len(self.results) + len(self.jobs) + self.uploads <= self.settings.max_results

    def start(self, owner: str, request_id: str, audio: bytes, mode: str, deadline: float, *, trace: TaskTrace | None = None):
        key = (owner, request_id)
        if key in self.jobs:
            return
        job = asyncio.create_task(self._process(owner, request_id, audio, mode, deadline, trace))
        self.jobs[key] = job

        def completed(_):
            self.jobs.pop(key, None)
            if trace is not None and self.monitor is not None:
                try:
                    trace.flush(self.monitor, self.store.status(owner, request_id))
                except Exception:
                    self.monitor.write_failures += 1
        job.add_done_callback(completed)

    def sweep(self):
        now = self.clock()
        for key, result in list(self.results.items()):
            if result.expires_monotonic <= now:
                del self.results[key]
                self.store.expire_result(*key)
                if self.monitor is not None:
                    self.monitor.event("resultExpiredCount")

    def result(self, owner: str, request_id: str):
        self.sweep()
        return self.results.get((owner, request_id))

    def cancel(self, owner: str, request_id: str):
        self.results.pop((owner, request_id), None)
        job = self.jobs.get((owner, request_id))
        if job:
            job.cancel()

    async def _process(self, owner: str, request_id: str, audio: bytes, mode: str, deadline: float, trace=None):
        polish_status = "pending" if mode == "light_polish" else "not_requested"
        key = (owner, request_id)
        try:
            await asyncio.sleep(0)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                self.store.finish(owner, request_id, "failed", polish_status, failure_code="request_timeout")
                return
            if not self.store.dispatch(owner, request_id):
                return
            stt_started = time.monotonic()
            try:
                stt = await asyncio.wait_for(self.provider.transcribe(audio),
                                             timeout=min(self.settings.stt_timeout, remaining))
                if trace is not None:
                    trace.ttfb("sttTtfbSeconds", getattr(stt, "ttfb_seconds", None))
            except ProviderError as exc:
                if trace is not None:
                    trace.ttfb("sttTtfbSeconds", exc.ttfb_seconds)
                    trace.provider_error(exc)
                raise
            except (TimeoutError, asyncio.CancelledError):
                if trace is not None:
                    trace.ttfb("sttTtfbSeconds", None)
                raise
            finally:
                stt_elapsed = time.monotonic() - stt_started
                if trace is not None:
                    trace.add("sttSeconds", stt_elapsed)
            audio = b""
            raw, output = stt.text, stt.text
            if not isinstance(raw, str) or not raw.strip():
                if trace is not None:
                    trace.add("upstreamInvalidCount", 1)
                raise ProviderError(kind="invalid")
            if trace is not None:
                trace.stt_speed(stt_elapsed, len(raw))
            actual_units = stt.actual_units
            if mode == "light_polish":
                polish_status = "failed_fallback_raw"
                actual_units = None
                remaining = deadline - time.monotonic()
                if self.settings.provider_mode != "groq" and len(raw) <= self.settings.polish_max_chars and remaining > 0:
                    polish_started = time.monotonic()
                    if trace is not None:
                        trace.add("polishAttemptCount", 1, model=self.settings.polish_model)
                    try:
                        polished = await asyncio.wait_for(self.provider.polish(raw),
                                                         timeout=min(self.settings.polish_timeout, remaining))
                        if trace is not None:
                            trace.ttfb("polishTtfbSeconds", getattr(polished, "ttfb_seconds", None), model=self.settings.polish_model)
                        if safe_polish(raw, polished.text, self.settings):
                            output, polish_status = polished.text, "succeeded"
                        elif trace is not None:
                            trace.add("upstreamInvalidCount", 1, model=self.settings.polish_model)
                        if stt.actual_units is not None and polished.actual_units is not None:
                            actual_units = stt.actual_units + polished.actual_units
                    except ProviderError as exc:
                        if trace is not None:
                            trace.ttfb("polishTtfbSeconds", exc.ttfb_seconds, model=self.settings.polish_model)
                            trace.provider_error(exc, model=self.settings.polish_model)
                            if exc.code == "request_timeout":
                                trace.add("polishTimeoutCount", 1, model=self.settings.polish_model)
                    except TimeoutError:
                        if trace is not None:
                            trace.ttfb("polishTtfbSeconds", None, model=self.settings.polish_model)
                            trace.add("polishTimeoutCount", 1, model=self.settings.polish_model)
                    except (ValueError, TypeError):
                        if trace is not None:
                            trace.ttfb("polishTtfbSeconds", None, model=self.settings.polish_model)
                    finally:
                        if trace is not None:
                            trace.add("polishSeconds", time.monotonic() - polish_started, model=self.settings.polish_model)
            expires_at = (self.store.clock() + timedelta(seconds=self.settings.result_ttl)).isoformat()
            result = MemoryResult(raw, output, self.clock() + self.settings.result_ttl)
            if self.store.finish(owner, request_id, "ready", polish_status,
                                 result_expires_at=expires_at, actual_units=actual_units):
                self.results[key] = result
                if trace is not None:
                    trace.add("outputCharacters", len(output))
        except asyncio.CancelledError:
            task = self.store.status(owner, request_id)
            if task["status"] == "processing":
                self.store.finish(owner, request_id,
                                  "unknown" if task["dispatch_marked_at"] else "failed",
                                  polish_status, failure_code="request_timeout")
            raise
        except TimeoutError:
            task = self.store.status(owner, request_id)
            self.store.finish(owner, request_id,
                              "unknown" if task["dispatch_marked_at"] else "failed",
                              polish_status, failure_code="request_timeout")
        except ProviderError as exc:
            self.store.finish(owner, request_id, "unknown" if exc.uncertain else "failed",
                              polish_status, failure_code="request_timeout" if exc.uncertain else "upstream_failed")
        except Exception:
            task = self.store.status(owner, request_id)
            self.store.finish(owner, request_id,
                              "unknown" if task["dispatch_marked_at"] else "failed",
                              polish_status, failure_code="internal_error")
        finally:
            audio = b""
            if trace is not None:
                trace.completed_at = time.monotonic()

    async def shutdown(self):
        jobs = list(self.jobs.values())
        for job in jobs:
            job.cancel()
        await asyncio.gather(*jobs, return_exceptions=True)
        self.jobs.clear()
        self.results.clear()
        await self.provider.aclose()
