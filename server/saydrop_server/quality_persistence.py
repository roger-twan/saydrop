"""Explicit, local-only persistence of quality-v1 corpus numbers. No model calls."""

from saydrop_server.observability import MetricSample, MetricStore

_NAMES = {
    "cer": "qualityCER", "strictCer": "qualityStrictCER", "wer": "qualityWER",
    "mixedErrorRate": "qualityMixedErrorRate", "omissionRate": "qualityOmissionRate",
    "protectedRetention": "qualityProtectedRetention",
}
_REASONS = {
    "missing_reference": "missing_reference", "missing_hypothesis": "missing_hypothesis",
    "empty_reference": "empty_reference", "empty_reference_units": "empty_reference",
    "not_english": "not_english", "alignment_limit": "alignment_limit",
    "no_protected_tokens": "no_protected_terms",
}


def persist_report(report: dict, store, *, mode="none", model="none") -> None:
    if report.get("method", {}).get("version") != "saydrop-quality-v1" or report.get("input", {}).get("status") != "accepted":
        raise ValueError("invalid quality report")
    samples = []
    for field, name in _NAMES.items():
        metric = report["corpus"]["metrics"][field]
        value = metric["rate"]
        reason = None
        if value is None:
            observed_reasons = metric["unavailableReasonCounts"]
            reason = next((_REASONS[key] for key in _REASONS if observed_reasons.get(key)), "not_observed")
        samples.append(MetricSample(name, value, mode=mode, model=model, source="offline", reason=reason))
        counts = metric["counts"]
        if field in {"cer", "strictCer", "wer", "mixedErrorRate"}:
            for key, suffix in (("N", "ReferenceUnits"), ("S", "Substitutions"), ("D", "Deletions"), ("I", "Insertions")):
                samples.append(MetricSample(name + suffix, counts[key], mode=mode, model=model, source="offline"))
        if field == "protectedRetention":
            samples.extend([
                MetricSample("qualityProtectedExpected", counts["expected"], mode=mode, model=model, source="offline"),
                MetricSample("qualityProtectedRetained", counts["retained"], mode=mode, model=model, source="offline"),
            ])
    samples.append(MetricSample("qualitySampleCount", report["corpus"]["sampleCounts"]["total"], mode=mode, model=model, source="offline"))
    MetricStore(store).record(samples)
