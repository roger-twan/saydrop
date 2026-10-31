"""Offline, reference-based transcription quality evaluation for Saydrop.

This module performs no provider, model, or network work; only explicit CLI
--persist loads server configuration to save corpus numbers.
It emits only fixed method identifiers, reasons, and numeric aggregates: never the
input text, record identifiers, paths, or protected terms.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import unicodedata
from collections import Counter
from collections.abc import Iterable
from pathlib import Path
from typing import Any

QUALITY_METHOD_VERSION = "saydrop-quality-v1"
MAX_JSONL_LINE_BYTES = 256 * 1024
MAX_INPUT_BYTES = 32 * 1024 * 1024
MAX_RECORDS = 10_000
MAX_TEXT_CHARS = 32_000
MAX_ALIGNMENT_CELLS = 2_000_000
METRIC_VALUE_RETENTION_DAYS = 30

_ALLOWED_RECORD_KEYS = frozenset({"reference", "hypothesis", "protectedTerms"})
_METRIC_NAMES = ("cer", "strictCer", "wer", "mixedErrorRate", "omissionRate", "protectedRetention")
_ALIGNMENT_METRICS = frozenset({"cer", "strictCer", "wer", "mixedErrorRate", "omissionRate"})
_NUMBER_EXPRESSION = re.compile(r"[+-]?[0-9]+(?:[.,:/-][0-9]+)*")
_NUMBER_TOKEN = re.compile(r"(?<![0-9A-Za-z])([+-]?[0-9]+(?:[.,:/-][0-9]+)*)(?![0-9A-Za-z])")
_WER_TOKEN = re.compile(r"[A-Za-z0-9]+")


def _method() -> dict[str, Any]:
    """Return fixed, versioned method identifiers without any input-derived text."""
    return {
        "version": QUALITY_METHOD_VERSION,
        "scope": "offline_reference_comparison",
        "realModelConclusion": "not_measured",
        "normalizedCer": "nfc_remove_whitespace_unicode_punctuation_keep_case_digits",
        "strictCer": "nfc_all_codepoints",
        "wer": "ascii_english_numeric_tokens_case_sensitive",
        "mixedErrorRate": "han_char_english_numeric_token_exact_numeric_expression",
        "alignment": "bounded_levenshtein_rolling_rows",
        "tieBreak": "substitution_then_deletion_then_insertion",
        "corpusRate": "cumulative_s_d_i_n_not_sample_mean",
        "protectedRetention": "reference_numeric_and_optional_term_exact_multiplicity",
        "monitoring": {
            "metricValueRetentionDays": METRIC_VALUE_RETENTION_DAYS,
            "targetStore": "sqlite_aggregate_values_only",
            "persistence": "not_requested",
        },
    }


def _metric_unavailable(reason: str, counts: dict[str, int] | None = None) -> dict[str, Any]:
    result: dict[str, Any] = {"status": "unavailable", "reason": reason, "rate": None}
    if counts is not None:
        result["counts"] = counts
    return result


def _metric_measured(counts: dict[str, int], rate: float) -> dict[str, Any]:
    return {"status": "measured", "counts": counts, "rate": rate}


def _empty_metrics(reason: str) -> dict[str, dict[str, Any]]:
    return {name: _metric_unavailable(reason) for name in _METRIC_NAMES}


def _rejected(reason: str = "redacted_invalid_record") -> dict[str, Any]:
    return {"methodVersion": QUALITY_METHOD_VERSION, "status": "rejected", "reason": reason, "metrics": {}}


def _nfc(value: str) -> str:
    return unicodedata.normalize("NFC", value)


def _is_unicode_punctuation(character: str) -> bool:
    return unicodedata.category(character).startswith("P")


def _normalized_cer_units(value: str) -> list[str]:
    return [character for character in _nfc(value) if not character.isspace() and not _is_unicode_punctuation(character)]


def _strict_cer_units(value: str) -> list[str]:
    return list(_nfc(value))


def _ascii_wer_eligible(value: str) -> bool:
    return value.isascii()


def _wer_units(value: str) -> list[str]:
    return _WER_TOKEN.findall(_nfc(value))


def _is_han(character: str) -> bool:
    codepoint = ord(character)
    return (
        0x3400 <= codepoint <= 0x4DBF
        or 0x4E00 <= codepoint <= 0x9FFF
        or 0xF900 <= codepoint <= 0xFAFF
        or 0x20000 <= codepoint <= 0x2EBEF
        or 0x30000 <= codepoint <= 0x323AF
    )


def _mixed_units(value: str) -> list[str]:
    """Tokenize CJK Han by character and English/numeric material without conversion."""
    normalized = _nfc(value)
    units: list[str] = []
    index = 0
    length = len(normalized)
    while index < length:
        character = normalized[index]
        # A signed number/date expression is semantic data, not disposable punctuation.
        numeric_match = _NUMBER_EXPRESSION.match(normalized, index)
        if numeric_match is not None and (character.isascii() and (character.isdigit() or character in "+-")):
            units.append(numeric_match.group(0))
            index = numeric_match.end()
            continue
        if character.isspace() or _is_unicode_punctuation(character):
            index += 1
            continue
        if _is_han(character):
            units.append(character)
            index += 1
            continue
        if character.isascii() and character.isalpha():
            end = index + 1
            while end < length and normalized[end].isascii() and (normalized[end].isalnum() or normalized[end] == "_"):
                end += 1
            units.append(normalized[index:end])
            index = end
            continue
        if character.isascii() and character.isdigit():
            end = index + 1
            while end < length and normalized[end].isascii() and normalized[end].isdigit():
                end += 1
            units.append(normalized[index:end])
            index = end
            continue
        category = unicodedata.category(character)
        if category[0] in {"L", "M", "N"}:
            end = index + 1
            while end < length and unicodedata.category(normalized[end])[0] in {"L", "M", "N"} and not _is_han(normalized[end]):
                end += 1
            units.append(normalized[index:end])
            index = end
            continue
        units.append(character)
        index += 1
    return units


def _better_alignment_candidate(
    current: tuple[int, int, int, int] | None,
    candidate: tuple[int, int, int, int],
    priority: int,
    current_priority: int | None,
) -> tuple[tuple[int, int, int, int], int]:
    """Choose lower distance first, then the documented operation priority."""
    if current is None or current_priority is None:
        return candidate, priority
    if candidate[0] < current[0] or (candidate[0] == current[0] and priority < current_priority):
        return candidate, priority
    return current, current_priority


def _bounded_alignment(reference: list[str], hypothesis: list[str]) -> tuple[int, int, int, int] | None:
    """Return S/D/I/N using two DP rows, or None when the cell guard is exceeded."""
    reference_length = len(reference)
    hypothesis_length = len(hypothesis)
    if (reference_length + 1) * (hypothesis_length + 1) > MAX_ALIGNMENT_CELLS:
        return None

    # Each tuple is distance, substitutions, deletions, insertions.  The table is
    # deliberately rolling-row only; no text or full backtrace is retained.
    previous: list[tuple[int, int, int, int]] = [(column, 0, 0, column) for column in range(hypothesis_length + 1)]
    for row_index, reference_unit in enumerate(reference, start=1):
        current: list[tuple[int, int, int, int]] = [(row_index, 0, row_index, 0)]
        for column_index, hypothesis_unit in enumerate(hypothesis, start=1):
            diagonal = previous[column_index - 1]
            if reference_unit == hypothesis_unit:
                current.append(diagonal)
                continue
            substitution = (diagonal[0] + 1, diagonal[1] + 1, diagonal[2], diagonal[3])
            deletion_source = previous[column_index]
            deletion = (deletion_source[0] + 1, deletion_source[1], deletion_source[2] + 1, deletion_source[3])
            insertion_source = current[column_index - 1]
            insertion = (insertion_source[0] + 1, insertion_source[1], insertion_source[2], insertion_source[3] + 1)
            chosen: tuple[int, int, int, int] | None = None
            chosen_priority: int | None = None
            chosen, chosen_priority = _better_alignment_candidate(chosen, substitution, 0, chosen_priority)
            chosen, chosen_priority = _better_alignment_candidate(chosen, deletion, 1, chosen_priority)
            chosen, _ = _better_alignment_candidate(chosen, insertion, 2, chosen_priority)
            current.append(chosen)
        previous = current
    distance, substitutions, deletions, insertions = previous[-1]
    # The equation holds by construction and protects the report if this routine changes.
    assert distance == substitutions + deletions + insertions
    return substitutions, deletions, insertions, reference_length


def _alignment_metric(reference_units: list[str], hypothesis_units: list[str]) -> dict[str, Any]:
    alignment = _bounded_alignment(reference_units, hypothesis_units)
    if alignment is None:
        return _metric_unavailable("alignment_limit")
    substitutions, deletions, insertions, reference_count = alignment
    counts = {"S": substitutions, "D": deletions, "I": insertions, "N": reference_count}
    if reference_count == 0:
        return _metric_unavailable("empty_reference_units", counts)
    return _metric_measured(counts, (substitutions + deletions + insertions) / reference_count)


def _omission_metric(mixed_metric: dict[str, Any]) -> dict[str, Any]:
    counts = mixed_metric.get("counts")
    if not isinstance(counts, dict):
        return _metric_unavailable(str(mixed_metric.get("reason", "alignment_limit")))
    omission_counts = {"S": int(counts["S"]), "D": int(counts["D"]), "I": int(counts["I"]), "N": int(counts["N"])}
    denominator = omission_counts["N"]
    if mixed_metric["status"] != "measured" or denominator == 0:
        return _metric_unavailable(str(mixed_metric.get("reason", "empty_reference_units")), omission_counts)
    return _metric_measured(omission_counts, omission_counts["D"] / denominator)


def _is_ascii_word_character(character: str) -> bool:
    return character.isascii() and (character.isalnum() or character == "_")


def _term_has_ascii_word_material(term: str) -> bool:
    return any(_is_ascii_word_character(character) for character in term)


def _term_boundary_ok(value: str, start: int, end: int, term: str) -> bool:
    if term and term[0].isdigit():
        return (start == 0 or not value[start - 1].isdigit()) and (end == len(value) or not value[end].isdigit())
    if _term_has_ascii_word_material(term):
        return (start == 0 or not _is_ascii_word_character(value[start - 1])) and (
            end == len(value) or not _is_ascii_word_character(value[end])
        )
    return True


def _count_exact_term(value: str, term: str) -> int:
    if not term:
        return 0
    if _NUMBER_EXPRESSION.fullmatch(term):
        return sum(match.group(1) == term for match in _NUMBER_TOKEN.finditer(value))
    count = 0
    start = 0
    while True:
        found = value.find(term, start)
        if found < 0:
            return count
        end = found + len(term)
        if _term_boundary_ok(value, found, end, term):
            count += 1
        start = end


def _protected_retention(reference: str, hypothesis: str, protected_terms: list[str]) -> dict[str, Any]:
    normalized_reference = _nfc(reference)
    normalized_hypothesis = _nfc(hypothesis)
    candidates: list[str] = []
    seen: set[str] = set()
    for numeric_match in _NUMBER_TOKEN.finditer(normalized_reference):
        token = numeric_match.group(1)
        if token not in seen:
            seen.add(token)
            candidates.append(token)
    for supplied_term in protected_terms:
        term = _nfc(supplied_term)
        if term and term not in seen:
            seen.add(term)
            candidates.append(term)

    expected = 0
    retained = 0
    for term in candidates:
        reference_count = _count_exact_term(normalized_reference, term)
        if reference_count == 0:
            continue
        hypothesis_count = _count_exact_term(normalized_hypothesis, term)
        expected += reference_count
        retained += min(reference_count, hypothesis_count)
    if expected == 0:
        return _metric_unavailable("no_protected_tokens")
    counts = {"expected": expected, "retained": retained, "missing": expected - retained}
    return _metric_measured(counts, retained / expected)


def _record_values(record: dict[str, Any]) -> tuple[tuple[str, str, list[str]] | None, str | None]:
    """Validate only the allowed schema and never surface field values in errors."""
    try:
        if any(not isinstance(key, str) or key not in _ALLOWED_RECORD_KEYS for key in record):
            return None, "redacted_invalid_record"
        if "reference" not in record:
            return None, "missing_reference"
        if "hypothesis" not in record:
            return None, "missing_hypothesis"
        reference = record["reference"]
        hypothesis = record["hypothesis"]
        if not isinstance(reference, str) or not isinstance(hypothesis, str):
            return None, "redacted_invalid_record"
        protected_terms_value = record.get("protectedTerms", [])
        if not isinstance(protected_terms_value, list) or not all(isinstance(term, str) for term in protected_terms_value):
            return None, "redacted_invalid_record"
        protected_terms = list(protected_terms_value)
        if len(reference) > MAX_TEXT_CHARS or len(hypothesis) > MAX_TEXT_CHARS or any(len(term) > MAX_TEXT_CHARS for term in protected_terms):
            return None, "text_length_limit"
        # A JSON escape may create a lone surrogate even though the JSONL bytes were UTF-8.
        reference.encode("utf-8")
        hypothesis.encode("utf-8")
        for term in protected_terms:
            term.encode("utf-8")
        return (reference, hypothesis, protected_terms), None
    except Exception:
        return None, "redacted_invalid_record"


def _empty_reference_result(hypothesis: str) -> dict[str, Any]:
    """Preserve known hallucinated insertions without assigning an accuracy rate."""
    cer = _alignment_metric([], _normalized_cer_units(hypothesis))
    strict_cer = _alignment_metric([], _strict_cer_units(hypothesis))
    mixed = _alignment_metric([], _mixed_units(hypothesis))
    # The known empty reference overrides each metric's internal empty-unit reason.
    for metric in (cer, strict_cer, mixed):
        metric["status"] = "unavailable"
        metric["reason"] = "empty_reference"
        metric["rate"] = None
    if _ascii_wer_eligible(hypothesis):
        wer = _alignment_metric([], _wer_units(hypothesis))
        wer["status"] = "unavailable"
        wer["reason"] = "empty_reference"
        wer["rate"] = None
    else:
        wer = _metric_unavailable("empty_reference")
    return {
        "methodVersion": QUALITY_METHOD_VERSION,
        "status": "unavailable",
        "reason": "empty_reference",
        "metrics": {
            "cer": cer,
            "strictCer": strict_cer,
            "wer": wer,
            "mixedErrorRate": mixed,
            "omissionRate": _metric_unavailable("empty_reference", mixed.get("counts")),
            "protectedRetention": _metric_unavailable("empty_reference"),
        },
    }


def evaluate_record(record: dict[str, Any]) -> dict[str, Any]:
    """Evaluate one schema-limited record without returning any user-supplied content."""
    if not isinstance(record, dict):
        return _rejected()
    values, issue = _record_values(record)
    if issue is not None:
        if issue == "redacted_invalid_record":
            return _rejected(issue)
        return {
            "methodVersion": QUALITY_METHOD_VERSION,
            "status": "unavailable",
            "reason": issue,
            "metrics": _empty_metrics(issue),
        }
    assert values is not None
    reference, hypothesis, protected_terms = values
    try:
        if not reference.strip():
            return _empty_reference_result(hypothesis)
        cer = _alignment_metric(_normalized_cer_units(reference), _normalized_cer_units(hypothesis))
        strict_cer = _alignment_metric(_strict_cer_units(reference), _strict_cer_units(hypothesis))
        mixed = _alignment_metric(_mixed_units(reference), _mixed_units(hypothesis))
        if _ascii_wer_eligible(reference) and _ascii_wer_eligible(hypothesis):
            wer = _alignment_metric(_wer_units(reference), _wer_units(hypothesis))
        else:
            wer = _metric_unavailable("not_english")
        return {
            "methodVersion": QUALITY_METHOD_VERSION,
            "status": "measured",
            "metrics": {
                "cer": cer,
                "strictCer": strict_cer,
                "wer": wer,
                "mixedErrorRate": mixed,
                "omissionRate": _omission_metric(mixed),
                "protectedRetention": _protected_retention(reference, hypothesis, protected_terms),
            },
        }
    except Exception:
        # This deliberately does not expose an exception class, representation, or input text.
        return {
            "methodVersion": QUALITY_METHOD_VERSION,
            "status": "unavailable",
            "reason": "evaluation_error",
            "metrics": _empty_metrics("evaluation_error"),
        }


def _initial_alignment_corpus_metric() -> dict[str, Any]:
    return {
        "sampleCounts": {"aligned": 0, "rateEligible": 0, "unavailable": 0},
        "unavailableReasonCounts": Counter(),
        "counts": {"S": 0, "D": 0, "I": 0, "N": 0},
    }


def _initial_protected_corpus_metric() -> dict[str, Any]:
    return {
        "sampleCounts": {"aligned": 0, "rateEligible": 0, "unavailable": 0},
        "unavailableReasonCounts": Counter(),
        "counts": {"expected": 0, "retained": 0, "missing": 0},
    }


def _corpus_metrics(samples: list[dict[str, Any]]) -> dict[str, Any]:
    aggregations: dict[str, dict[str, Any]] = {
        name: (_initial_alignment_corpus_metric() if name in _ALIGNMENT_METRICS else _initial_protected_corpus_metric())
        for name in _METRIC_NAMES
    }
    for sample in samples:
        metrics = sample.get("metrics", {})
        if not isinstance(metrics, dict):
            continue
        for name in _METRIC_NAMES:
            metric = metrics.get(name)
            if not isinstance(metric, dict):
                continue
            aggregation = aggregations[name]
            counts = metric.get("counts")
            if isinstance(counts, dict):
                expected_keys = ("S", "D", "I", "N") if name in _ALIGNMENT_METRICS else ("expected", "retained", "missing")
                if all(isinstance(counts.get(key), int) and not isinstance(counts.get(key), bool) for key in expected_keys):
                    aggregation["sampleCounts"]["aligned"] += 1
                    for key in expected_keys:
                        aggregation["counts"][key] += counts[key]
            if metric.get("status") == "measured":
                aggregation["sampleCounts"]["rateEligible"] += 1
            elif metric.get("status") == "unavailable":
                aggregation["sampleCounts"]["unavailable"] += 1
                reason = metric.get("reason")
                if isinstance(reason, str):
                    aggregation["unavailableReasonCounts"][reason] += 1

    result: dict[str, Any] = {}
    for name, aggregation in aggregations.items():
        counts = aggregation["counts"]
        if name == "protectedRetention":
            denominator = counts["expected"]
            numerator = counts["retained"]
        elif name == "omissionRate":
            denominator = counts["N"]
            numerator = counts["D"]
        else:
            denominator = counts["N"]
            numerator = counts["S"] + counts["D"] + counts["I"]
        result[name] = {
            "sampleCounts": aggregation["sampleCounts"],
            "unavailableReasonCounts": dict(sorted(aggregation["unavailableReasonCounts"].items())),
            "counts": counts,
            "rate": (numerator / denominator) if denominator else None,
        }
    return result


def _report(samples: list[dict[str, Any]], input_status: str = "accepted", input_reason: str | None = None) -> dict[str, Any]:
    sample_statuses = Counter(str(sample.get("status", "unavailable")) for sample in samples)
    reason_counts: Counter[str] = Counter()
    for sample in samples:
        if sample.get("status") in {"unavailable", "rejected"}:
            reason = sample.get("reason")
            if isinstance(reason, str):
                reason_counts[reason] += 1
    input_value: dict[str, Any] = {"status": input_status}
    if input_reason is not None:
        input_value["reason"] = input_reason
    return {
        "method": _method(),
        "input": input_value,
        "samples": samples,
        "corpus": {
            "sampleCounts": {
                "total": len(samples),
                "measured": sample_statuses["measured"],
                "unavailable": sample_statuses["unavailable"],
                "rejected": sample_statuses["rejected"],
            },
            "unavailableReasonCounts": dict(sorted(reason_counts.items())),
            "metrics": _corpus_metrics(samples),
        },
    }


def evaluate_records(records: Iterable[dict[str, Any]]) -> dict[str, Any]:
    """Evaluate up to 10,000 records and calculate corpus rates from cumulative counts."""
    try:
        iterator = iter(records)
    except Exception:
        return _report([], "rejected", "redacted_invalid_records")
    samples: list[dict[str, Any]] = []
    try:
        for ordinal, record in enumerate(iterator, start=1):
            if ordinal > MAX_RECORDS:
                return _report([], "rejected", "record_limit_exceeded")
            result = evaluate_record(record)
            result["ordinal"] = ordinal
            samples.append(result)
    except Exception:
        return _report([], "rejected", "redacted_invalid_records")
    return _report(samples)


def _read_jsonl(input_path: Path) -> tuple[list[dict[str, Any]] | None, str | None]:
    """Read bounded UTF-8 JSONL in place, retaining no source lines after parsing."""
    try:
        if input_path.stat().st_size > MAX_INPUT_BYTES:
            return None, "input_byte_limit_exceeded"
        records: list[dict[str, Any]] = []
        total_bytes = 0
        with input_path.open("rb") as source:
            ordinal = 0
            while True:
                raw_line = source.readline(MAX_JSONL_LINE_BYTES + 1)
                if not raw_line:
                    break
                ordinal += 1
                total_bytes += len(raw_line)
                if len(raw_line) > MAX_JSONL_LINE_BYTES:
                    return None, "line_byte_limit_exceeded"
                if total_bytes > MAX_INPUT_BYTES:
                    return None, "input_byte_limit_exceeded"
                if ordinal > MAX_RECORDS:
                    return None, "record_limit_exceeded"
                try:
                    decoded_line = raw_line.decode("utf-8")
                    parsed = json.loads(decoded_line)
                except (UnicodeDecodeError, json.JSONDecodeError):
                    return None, "redacted_invalid_jsonl"
                if not isinstance(parsed, dict):
                    return None, "redacted_invalid_record"
                records.append(parsed)
        return records, None
    except OSError:
        return None, "input_unavailable"
    except Exception:
        return None, "redacted_invalid_jsonl"


def _write_new_report(output_path: Path, report: dict[str, Any]) -> str | None:
    """Write only a new report file; never replace an existing target."""
    try:
        descriptor = os.open(output_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        return "output_exists"
    except OSError:
        return "output_unavailable"
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as destination:
            json.dump(report, destination, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
            destination.write("\n")
        return None
    except Exception:
        try:
            output_path.unlink()
        except OSError:
            pass
        return "output_unavailable"


class _RedactedArgumentParser(argparse.ArgumentParser):
    """Avoid argparse's default behavior of reflecting an untrusted argument."""

    def error(self, message: str) -> None:
        raise ValueError("redacted")


def main(argv: list[str] | None = None) -> int:
    parser = _RedactedArgumentParser(add_help=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--persist", action="store_true")
    parser.add_argument("--mode", choices=("none", "raw", "light_polish"), default="none")
    parser.add_argument("--model", choices=("none", "elevenlabs/scribe-v2", "openai/whisper-large-v3-turbo"), default="none")
    try:
        arguments = parser.parse_args(argv)
        input_path = Path(arguments.input).resolve(strict=False)
        output_path = Path(arguments.output).resolve(strict=False)
    except SystemExit:
        return 2
    except Exception:
        sys.stderr.write("quality_cli_error\n")
        return 2

    try:
        if input_path == output_path:
            sys.stderr.write("input_output_conflict\n")
            return 2
        if output_path.exists():
            sys.stderr.write("output_exists\n")
            return 2
        if not input_path.is_file() or not output_path.parent.is_dir():
            sys.stderr.write("input_or_output_unavailable\n")
            return 2
        records, read_error = _read_jsonl(input_path)
        report = _report([], "rejected", read_error) if read_error is not None else evaluate_records(records or [])
        persist_failed = False
        if arguments.persist and read_error is None and report["input"]["status"] == "accepted":
            from saydrop_server.config import Settings
            from saydrop_server.quality_persistence import persist_report
            from saydrop_server.storage import Store

            store = None
            try:
                store = Store(Settings.load())
                persist_report(report, store, mode=arguments.mode, model=arguments.model)
                report["method"]["monitoring"]["persistence"] = "saved"
            except Exception:
                persist_failed = True
                report["method"]["monitoring"]["persistence"] = "failed"
                sys.stderr.write("quality_database_unavailable\n")
            finally:
                if store is not None:
                    store.engine.dispose()
        write_error = _write_new_report(output_path, report)
        if write_error is not None:
            suffix = "_metrics_may_be_saved" if report["method"]["monitoring"]["persistence"] == "saved" else ""
            sys.stderr.write(write_error + suffix + "\n")
            return 2
        return 0 if read_error is None and not persist_failed else 2
    except Exception:
        sys.stderr.write("quality_cli_error\n")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
