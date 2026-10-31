"""Privacy-preserving, bounded-label numeric metrics storage for Saydrop."""
import math
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from uuid import uuid4

from saydrop_server.errors import MESSAGES

VALIDATION_ERROR = "invalid metric input"

_MODE_VALUES = frozenset({"none", "raw", "light_polish"})
_MODEL_VALUES = frozenset(
    {
        "none",
        "elevenlabs/scribe-v2",
        "whisper-large-v3",
        "whisper-large-v3-turbo",
        "openai/whisper-large-v3-turbo",
        "openai/gpt-4.1-mini",
    }
)
_OUTCOME_VALUES = frozenset({"none", "ready", "failed", "cancelled", "unknown", "rejected"})
_SOURCE_VALUES = frozenset({"live", "mock", "offline"})
_REASON_VALUES = frozenset(
    {
        "non_streaming",
        "not_observed",
        "missing_reference",
        "empty_reference",
        "not_english",
        "no_protected_terms",
        "alignment_limit",
        "missing_hypothesis",
    }
) | frozenset(MESSAGES)

_UNIT_BY_NAME = {
    "submitCount": "count",
    "rejectedCount": "count",
    "idempotentReplayCount": "count",
    "acceptedCount": "count",
    "terminalCount": "count",
    "uploadSeconds": "seconds",
    "validationSeconds": "seconds",
    "submissionSeconds": "seconds",
    "taskTotalSeconds": "seconds",
    "resultReadySeconds": "seconds",
    "sttSeconds": "seconds",
    "polishSeconds": "seconds",
    "sttTtfbSeconds": "seconds",
    "polishTtfbSeconds": "seconds",
    "ttftSeconds": "seconds",
    "audioSeconds": "seconds",
    "rawCharacters": "characters",
    "outputCharacters": "characters",
    "rtf": "ratio",
    "audioThroughput": "audioSecondsPerSecond",
    "characterThroughput": "charactersPerSecond",
    "polishAttemptCount": "count",
    "polishFallbackCount": "count",
    "outputValidCount": "count",
    "upstreamInvalidCount": "count",
    "upstreamTruncatedCount": "count",
    "upstreamHttpFailedCount": "count",
    "resultExpiredCount": "count",
    "recoveryCount": "count",
    "qualityCER": "ratio",
    "qualityStrictCER": "ratio",
    "qualityWER": "ratio",
    "qualityMixedErrorRate": "ratio",
    "qualityOmissionRate": "ratio",
    "qualityProtectedRetention": "ratio",
    "qualityReferenceUnits": "count",
    "qualitySubstitutions": "count",
    "qualityDeletions": "count",
    "qualityInsertions": "count",
    "qualityProtectedExpected": "count",
    "qualityProtectedRetained": "count",
    "qualitySampleCount": "count",
    "polishTimeoutCount": "count",
}
for _prefix in ("qualityCER", "qualityStrictCER", "qualityWER", "qualityMixedErrorRate"):
    for _suffix in ("ReferenceUnits", "Substitutions", "Deletions", "Insertions"):
        _UNIT_BY_NAME[_prefix + _suffix] = "count"


@dataclass
class MetricSample:
    name: str
    value: float | None
    mode: str = "none"
    model: str = "none"
    outcome: str = "none"
    source: str = "live"
    reason: str | None = None


class MetricStore:
    """Persist only bounded numeric measurements; no per-request correlation is possible."""

    def __init__(self, store):
        self.store = store

    def record(self, samples: list[MetricSample]) -> None:
        """Validate a whole batch, then insert it atomically in one SQLite transaction."""
        if not isinstance(samples, list):
            self._invalid()

        validated = [self._validate_sample(sample) for sample in samples]
        if not validated:
            return

        observed_at = self._utc_now()
        expires_at = observed_at + timedelta(days=self._retention_days())
        observed_iso = observed_at.isoformat()
        expires_iso = expires_at.isoformat()
        rows = [
            (
                str(uuid4()),
                name,
                value,
                mode,
                model,
                outcome,
                source,
                reason,
                observed_iso,
                expires_iso,
            )
            for name, value, mode, model, outcome, source, reason in validated
        ]
        with self.store.transaction() as conn:
            conn.exec_driver_sql(
                "INSERT INTO metric_samples "
                "(id,name,value,mode,model,outcome,source,reason,observed_at,expires_at) "
                "VALUES (?,?,?,?,?,?,?,?,?,?)",
                rows,
            )

    def cleanup(self) -> int:
        """Delete expired measurements without extending the expiry of retained rows."""
        now_iso = self._utc_now().isoformat()
        with self.store.transaction() as conn:
            result = conn.exec_driver_sql("DELETE FROM metric_samples WHERE expires_at<=?", (now_iso,))
            return max(0, result.rowcount or 0)

    def snapshot(self, days: int = 1, source: str = "live") -> dict:
        """Return fixed-dimension aggregates without materializing raw measurements."""
        self._validate_snapshot_args(days, source)
        now = self._utc_now()
        cutoff = now - timedelta(days=days)
        window_params = (source, cutoff.isoformat(), now.isoformat(), now.isoformat())
        aggregate_sql = """
            SELECT
                name,
                mode,
                model,
                outcome,
                reason,
                COUNT(*) AS sample_count,
                SUM(CASE WHEN value IS NULL THEN 1 ELSE 0 END) AS unavailable_count,
                COUNT(value) AS numeric_count,
                AVG(value) AS mean_value,
                MIN(value) AS min_value,
                MAX(value) AS max_value,
                SUM(value) AS sum_value
            FROM metric_samples
            WHERE source=? AND observed_at>=? AND observed_at<=? AND expires_at>?
            GROUP BY name, mode, model, outcome, reason
            ORDER BY name, mode, model, outcome, reason
        """

        groups = []
        with self.store.engine.connect() as conn:
            # SQLite's legacy SELECT mode otherwise need not start a DB transaction.
            # Keep COUNT and percentile queries on one WAL snapshot during concurrent writes/cleanup.
            conn.exec_driver_sql("BEGIN")
            aggregate_rows = conn.exec_driver_sql(aggregate_sql, window_params).mappings()
            for row in aggregate_rows:
                numeric_count = int(row["numeric_count"])
                percentile_values = self._percentiles(
                    conn,
                    source,
                    cutoff.isoformat(),
                    now.isoformat(),
                    now.isoformat(),
                    row,
                    numeric_count,
                )
                groups.append(
                    {
                        "name": row["name"],
                        "mode": row["mode"],
                        "model": row["model"],
                        "outcome": row["outcome"],
                        "source": source,
                        "reason": row["reason"],
                        "unit": _UNIT_BY_NAME[row["name"]],
                        "sampleCount": int(row["sample_count"]),
                        "unavailableCount": int(row["unavailable_count"]),
                        "mean": self._number_or_none(row["mean_value"]),
                        "p50": percentile_values[0],
                        "p95": percentile_values[1],
                        "p99": percentile_values[2],
                        "min": self._number_or_none(row["min_value"]),
                        "max": self._number_or_none(row["max_value"]),
                        "sum": self._number_or_none(row["sum_value"]),
                    }
                )

        return {
            "days": days,
            "source": source,
            "retentionDays": self._retention_days(),
            "windowStart": cutoff.isoformat(),
            "windowEnd": now.isoformat(),
            "percentileMethod": "nearest_rank",
            "availability": {
                "ttft": "unavailable",
                "qualityRequiresReference": True,
            },
            "summary": summarize(groups, days),
            "groups": groups,
        }

    def _percentiles(self, conn, source, cutoff, now, expiry_cutoff, row, numeric_count: int):
        if numeric_count == 0:
            return (None, None, None)

        base_params = (source, cutoff, now, expiry_cutoff, row["name"], row["mode"], row["model"], row["outcome"])
        if row["reason"] is None:
            percentile_sql = """
                SELECT value FROM metric_samples
                WHERE source=? AND observed_at>=? AND observed_at<=? AND expires_at>?
                  AND name=? AND mode=? AND model=? AND outcome=? AND reason IS NULL
                  AND value IS NOT NULL
                ORDER BY value ASC
                LIMIT ? OFFSET ?
            """
            params_for_reason = base_params
        else:
            percentile_sql = """
                SELECT value FROM metric_samples
                WHERE source=? AND observed_at>=? AND observed_at<=? AND expires_at>?
                  AND name=? AND mode=? AND model=? AND outcome=? AND reason=?
                  AND value IS NOT NULL
                ORDER BY value ASC
                LIMIT ? OFFSET ?
            """
            params_for_reason = (*base_params, row["reason"])

        offsets = (
            self._nearest_rank_offset(numeric_count, 50),
            self._nearest_rank_offset(numeric_count, 95),
            self._nearest_rank_offset(numeric_count, 99),
        )
        values = []
        for offset in offsets:
            value = conn.exec_driver_sql(percentile_sql, (*params_for_reason, 1, offset)).scalar_one()
            values.append(float(value))
        return tuple(values)

    def _validate_sample(self, sample: MetricSample):
        if not isinstance(sample, MetricSample):
            self._invalid()
        if type(sample.name) is not str or sample.name not in _UNIT_BY_NAME:
            self._invalid()
        if type(sample.mode) is not str or sample.mode not in _MODE_VALUES:
            self._invalid()
        if type(sample.model) is not str or sample.model not in _MODEL_VALUES:
            self._invalid()
        if type(sample.outcome) is not str or sample.outcome not in _OUTCOME_VALUES:
            self._invalid()
        if type(sample.source) is not str or sample.source not in _SOURCE_VALUES:
            self._invalid()
        if sample.reason is not None and (type(sample.reason) is not str or sample.reason not in _REASON_VALUES):
            self._invalid()

        value = sample.value
        if value is not None:
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                self._invalid()
            try:
                value = float(value)
            except (OverflowError, ValueError):
                self._invalid()
            if not math.isfinite(value) or value < 0:
                self._invalid()
        elif sample.reason is None:
            self._invalid()

        if sample.name.startswith("quality") and value is not None and sample.source != "offline":
            self._invalid()

        # OpenRouter currently provides no true token stream. A TTFT measurement would be false precision.
        if sample.name == "ttftSeconds" and (value is not None or sample.reason != "non_streaming"):
            self._invalid()
        return (sample.name, value, sample.mode, sample.model, sample.outcome, sample.source, sample.reason)

    def _validate_snapshot_args(self, days, source) -> None:
        if isinstance(days, bool) or not isinstance(days, int) or not 1 <= days <= 30:
            self._invalid()
        if type(source) is not str or source not in _SOURCE_VALUES:
            self._invalid()

    def _retention_days(self) -> int:
        days = getattr(self.store.settings, "metrics_retention_days", 30)
        if isinstance(days, bool) or not isinstance(days, int) or not 1 <= days <= 30:
            self._invalid()
        return days

    def _utc_now(self) -> datetime:
        now = self.store.clock()
        if not isinstance(now, datetime) or now.tzinfo is None or now.utcoffset() is None:
            self._invalid()
        return now.astimezone(UTC)

    @staticmethod
    def _nearest_rank_offset(sample_count: int, percentile: int) -> int:
        return ((sample_count * percentile + 99) // 100) - 1

    @staticmethod
    def _number_or_none(value):
        return None if value is None else float(value)

    @staticmethod
    def _invalid() -> None:
        raise ValueError(VALIDATION_ERROR)


def summarize(groups: list[dict], days: int) -> dict:
    def count(name, *, outcome=None, mode=None, reason=None):
        return sum(row["sum"] or 0 for row in groups if row["name"] == name
                   and (outcome is None or row["outcome"] == outcome)
                   and (mode is None or row["mode"] == mode)
                   and (reason is None or row["reason"] == reason))

    def rate(numerator, denominator):
        return {"numerator": numerator, "denominator": denominator,
                "value": numerator / denominator if denominator else None}

    terminals = count("terminalCount")
    ready = count("terminalCount", outcome="ready")
    submissions = count("submitCount")
    ready_light = count("terminalCount", outcome="ready", mode="light_polish")
    weighted = []
    dimensions = sorted({(row["mode"], row["model"]) for row in groups if row["name"] == "qualitySampleCount"})
    for mode, model in dimensions:
        def quality_count(name):
            return sum(row["sum"] or 0 for row in groups if row["name"] == name and row["mode"] == mode and row["model"] == model)
        item = {"mode": mode, "model": model, "sampleCount": quality_count("qualitySampleCount")}
        for prefix in ("qualityCER", "qualityStrictCER", "qualityWER", "qualityMixedErrorRate"):
            n = quality_count(prefix + "ReferenceUnits")
            errors = sum(quality_count(prefix + suffix) for suffix in ("Substitutions", "Deletions", "Insertions"))
            item[prefix] = rate(errors, n)
        item["qualityOmissionRate"] = rate(quality_count("qualityMixedErrorRateDeletions"), quality_count("qualityMixedErrorRateReferenceUnits"))
        item["qualityProtectedRetention"] = rate(quality_count("qualityProtectedRetained"), quality_count("qualityProtectedExpected"))
        weighted.append(item)
    return {
        "terminalSampleCount": terminals,
        "successRate": rate(ready, terminals),
        "failureRate": rate(count("terminalCount", outcome="failed"), terminals),
        "unknownRate": rate(count("terminalCount", outcome="unknown"), terminals),
        "cancelledRate": rate(count("terminalCount", outcome="cancelled"), terminals),
        "timeoutRate": rate(count("terminalCount", reason="request_timeout"), terminals),
        "rejectionRate": rate(count("rejectedCount"), submissions),
        "polishFallbackRate": rate(count("polishFallbackCount", outcome="ready"), ready_light),
        "polishTimeoutRate": rate(count("polishTimeoutCount"), count("polishAttemptCount")),
        "submitRatePerSecond": rate(submissions, days * 86400),
        "completedRatePerSecond": rate(terminals, days * 86400),
        "readyAudioThroughput": rate(count("audioSeconds", outcome="ready"), count("sttSeconds", outcome="ready")),
        "weightedQuality": weighted,
    }
