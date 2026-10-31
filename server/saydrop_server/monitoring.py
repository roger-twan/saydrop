"""Business instrumentation. Never retain body/text/owner/request identifiers in samples."""

import math
import time
from dataclasses import dataclass, field

from saydrop_server.observability import MetricSample, MetricStore


class Monitor:
    def __init__(self, store):
        self.metrics = MetricStore(store)
        self.source = "mock" if store.settings.provider_mode == "mock" else "live"
        self.write_failures = 0

    def record(self, samples):
        try:
            self.metrics.record(samples)
        except Exception:
            # Diagnostics must never reverse a completed task or trigger replay. No
            # exception repr/logging: driver errors can contain bound parameters.
            self.write_failures += 1

    def event(self, name, *, mode="none", outcome="none", reason=None, value=1):
        self.record([MetricSample(name, value, mode=mode, outcome=outcome,
                                  source=self.source, reason=reason)])


@dataclass
class TaskTrace:
    mode: str
    model: str
    source: str
    started: float
    audio_seconds: float | None = None
    completed_at: float | None = None
    samples: list[MetricSample] = field(default_factory=list)

    def add(self, name, value, *, model=None, reason=None):
        # Only numeric metadata. A fixed task path emits far fewer than 64 entries.
        if len(self.samples) >= 64:
            return
        self.samples.append(MetricSample(name, value, mode=self.mode,
                                         model=model or self.model, source=self.source, reason=reason))

    def ttfb(self, name, value, *, model=None):
        if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0:
            self.add(name, value, model=model)
        else:
            self.add(name, None, model=model, reason="not_observed")

    def provider_error(self, exc, *, model=None):
        metric = {"invalid": "upstreamInvalidCount", "truncated": "upstreamTruncatedCount",
                  "http": "upstreamHttpFailedCount"}.get(getattr(exc, "kind", "none"))
        if metric:
            self.add(metric, 1, model=model)

    def stt_speed(self, elapsed, characters):
        self.add("rawCharacters", characters)
        self.add("outputValidCount", 1)
        if self.audio_seconds is not None and self.audio_seconds > 0 and elapsed > 0:
            self.add("rtf", elapsed / self.audio_seconds)
            self.add("audioThroughput", self.audio_seconds / elapsed)
            self.add("characterThroughput", characters / elapsed)

    def flush(self, monitor, task):
        outcome = task["status"]
        if outcome not in {"ready", "failed", "cancelled", "unknown"}:
            return
        elapsed = (self.completed_at if self.completed_at is not None else time.monotonic()) - self.started
        self.add("taskTotalSeconds", elapsed)
        if outcome == "ready":
            self.add("resultReadySeconds", elapsed)
        self.add("terminalCount", 1, reason=task.get("failure_code"))
        if outcome == "ready" and self.mode == "light_polish" and task["polish_status"] == "failed_fallback_raw":
            self.add("polishFallbackCount", 1)
        for name in ("qualityCER", "qualityStrictCER", "qualityWER", "qualityMixedErrorRate",
                     "qualityOmissionRate", "qualityProtectedRetention"):
            self.add(name, None, reason="missing_reference")
        # No linkage to the task exists in the persisted values.
        samples = [MetricSample(s.name, s.value, mode=s.mode, model=s.model,
                                outcome=outcome, source=s.source, reason=s.reason) for s in self.samples]
        monitor.record(samples)
        self.samples.clear()
