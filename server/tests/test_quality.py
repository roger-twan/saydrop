import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from saydrop_server.quality import (
    MAX_ALIGNMENT_CELLS,
    MAX_JSONL_LINE_BYTES,
    MAX_TEXT_CHARS,
    evaluate_record,
    evaluate_records,
)


def test_chinese_english_mixed_is_measured_without_claiming_wer():
    result = evaluate_record({"reference": "\u4ECA\u5929\u548C Alice \u5F00\u4F1A 3.14 \u6B21", "hypothesis": "\u4ECA\u5929\u548C Alice \u5F00\u4F1A 3.14 \u6B21"})

    assert result["status"] == "measured"
    assert result["metrics"]["cer"]["rate"] == 0
    assert result["metrics"]["mixedErrorRate"]["rate"] == 0
    assert result["metrics"]["wer"] == {"status": "unavailable", "reason": "not_english", "rate": None}


def test_repeated_words_use_word_alignment_counts():
    result = evaluate_record({"reference": "go go now", "hypothesis": "go now"})
    wer = result["metrics"]["wer"]

    assert wer["counts"] == {"S": 0, "D": 1, "I": 0, "N": 3}
    assert wer["rate"] == pytest.approx(1 / 3)


def test_insertion_rate_can_exceed_one():
    result = evaluate_record({"reference": "a", "hypothesis": "abc"})
    cer = result["metrics"]["cer"]

    assert cer["counts"] == {"S": 0, "D": 0, "I": 2, "N": 1}
    assert cer["rate"] == 2


def test_missing_or_empty_reference_is_unavailable_and_empty_keeps_hallucinations():
    missing = evaluate_record({"hypothesis": "unexpected"})
    empty = evaluate_record({"reference": "", "hypothesis": "unexpected"})
    corpus = evaluate_records([{"reference": "", "hypothesis": "unexpected"}])

    assert missing["status"] == "unavailable"
    assert missing["reason"] == "missing_reference"
    assert missing["metrics"]["cer"]["rate"] is None
    assert empty["status"] == "unavailable"
    assert empty["reason"] == "empty_reference"
    assert empty["metrics"]["cer"]["counts"] == {"S": 0, "D": 0, "I": 10, "N": 0}
    assert empty["metrics"]["cer"]["rate"] is None
    assert corpus["corpus"]["metrics"]["cer"]["counts"]["I"] == 10
    assert corpus["corpus"]["metrics"]["cer"]["rate"] is None


def test_non_ascii_wer_is_explicitly_not_english():
    result = evaluate_record({"reference": "hello \u4E16\u754C", "hypothesis": "hello \u4E16\u754C"})

    assert result["metrics"]["wer"] == {"status": "unavailable", "reason": "not_english", "rate": None}


def test_normalized_and_strict_cer_have_different_punctuation_and_whitespace_rules():
    result = evaluate_record({"reference": "A， B", "hypothesis": "AB"})

    assert result["metrics"]["cer"]["rate"] == 0
    assert result["metrics"]["strictCer"]["counts"] == {"S": 0, "D": 2, "I": 0, "N": 4}
    assert result["metrics"]["strictCer"]["rate"] == 0.5


def test_protected_numeric_token_uses_boundaries_and_multiplicity():
    result = evaluate_record({"reference": "\u7F16\u53F7 42，42", "hypothesis": "\u7F16\u53F7 142，42"})
    retention = result["metrics"]["protectedRetention"]

    assert retention["counts"] == {"expected": 2, "retained": 1, "missing": 1}
    assert retention["rate"] == 0.5


def test_protected_person_terms_are_exact_without_echoing_terms():
    result = evaluate_record(
        {"reference": "Alice met Bob", "hypothesis": "Alicia met Bob", "protectedTerms": ["Alice", "Bob"]}
    )
    serialized = json.dumps(result)

    assert result["metrics"]["protectedRetention"]["counts"] == {"expected": 2, "retained": 1, "missing": 1}
    assert result["metrics"]["protectedRetention"]["rate"] == 0.5
    assert "Alice" not in serialized
    assert "Bob" not in serialized
    assert "Alicia" not in serialized


def test_corpus_rate_is_weighted_from_cumulative_counts_not_sample_average():
    report = evaluate_records(
        [
            {"reference": "a", "hypothesis": "b"},
            {"reference": "a a a", "hypothesis": "a a a"},
        ]
    )
    cer = report["corpus"]["metrics"]["cer"]

    assert cer["counts"] == {"S": 1, "D": 0, "I": 0, "N": 4}
    assert cer["rate"] == 0.25
    assert report["corpus"]["sampleCounts"] == {"total": 2, "measured": 2, "unavailable": 0, "rejected": 0}


def test_alignment_and_text_limits_are_unavailable_without_text_leakage():
    alignment_input = "z " * 2_000
    assert (len(alignment_input.replace(" ", "")) + 1) ** 2 > MAX_ALIGNMENT_CELLS
    alignment_limited = evaluate_record({"reference": alignment_input, "hypothesis": alignment_input})
    too_long = "SENSITIVE_LENGTH_VALUE" + "x" * MAX_TEXT_CHARS
    length_limited = evaluate_record({"reference": too_long, "hypothesis": "x"})
    invalid = evaluate_record({"reference": "safe", "hypothesis": "safe", "id": "SENSITIVE_IDENTIFIER"})
    serialized = json.dumps({"a": alignment_limited, "b": length_limited, "c": invalid})

    assert alignment_limited["metrics"]["cer"] == {"status": "unavailable", "reason": "alignment_limit", "rate": None}
    assert length_limited["status"] == "unavailable"
    assert length_limited["reason"] == "text_length_limit"
    assert invalid == {
        "methodVersion": "saydrop-quality-v1",
        "status": "rejected",
        "reason": "redacted_invalid_record",
        "metrics": {},
    }
    assert "SENSITIVE_" not in serialized


def test_evaluate_records_rejects_more_than_maximum_records():
    report = evaluate_records({"reference": "a", "hypothesis": "a"} for _ in range(10_001))

    assert report["input"] == {"status": "rejected", "reason": "record_limit_exceeded"}
    assert report["corpus"]["sampleCounts"]["total"] == 0


def test_cli_reads_only_explicit_jsonl_and_does_not_read_dotenv(tmp_path):
    server_root = Path(__file__).resolve().parents[1]
    input_path = tmp_path / "input.jsonl"
    output_path = tmp_path / "report.json"
    input_path.write_text('{"reference":"hello 42","hypothesis":"hello 42"}\n', encoding="utf-8")
    (tmp_path / ".env").write_text("THIS_FILE_MUST_NOT_BE_READ=not-a-quality-setting\n", encoding="utf-8")
    environment = os.environ.copy()
    environment["PYTHONPATH"] = str(server_root)
    environment["THIS_FILE_MUST_NOT_BE_READ"] = "present-but-unused"

    completed = subprocess.run(
        [sys.executable, "-m", "saydrop_server.quality", "--input", str(input_path), "--output", str(output_path)],
        cwd=tmp_path,
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )

    assert completed.returncode == 0
    assert completed.stdout == ""
    assert completed.stderr == ""
    report = json.loads(output_path.read_text(encoding="utf-8"))
    assert report["method"]["version"] == "saydrop-quality-v1"
    assert report["corpus"]["metrics"]["cer"]["rate"] == 0
    assert "hello" not in output_path.read_text(encoding="utf-8")


def test_cli_never_overwrites_an_existing_output_or_input(tmp_path):
    server_root = Path(__file__).resolve().parents[1]
    input_path = tmp_path / "input.jsonl"
    output_path = tmp_path / "report.json"
    input_path.write_text('{"reference":"a","hypothesis":"a"}\n', encoding="utf-8")
    output_path.write_text("existing", encoding="utf-8")
    environment = os.environ.copy()
    environment["PYTHONPATH"] = str(server_root)

    completed = subprocess.run(
        [sys.executable, "-m", "saydrop_server.quality", "--input", str(input_path), "--output", str(output_path)],
        cwd=tmp_path,
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )

    assert completed.returncode == 2
    assert completed.stderr == "output_exists\n"
    assert output_path.read_text(encoding="utf-8") == "existing"

    same_path = subprocess.run(
        [sys.executable, "-m", "saydrop_server.quality", "--input", str(input_path), "--output", str(input_path)],
        cwd=tmp_path,
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )
    assert same_path.returncode == 2
    assert same_path.stderr == "input_output_conflict\n"


def test_cli_errors_and_line_limit_are_redacted(tmp_path):
    server_root = Path(__file__).resolve().parents[1]
    environment = os.environ.copy()
    environment["PYTHONPATH"] = str(server_root)
    secret_argument = "SENSITIVE_ARGUMENT_DO_NOT_ECHO"
    malformed = subprocess.run(
        [sys.executable, "-m", "saydrop_server.quality", "--input", secret_argument, "--unknown", secret_argument],
        cwd=tmp_path,
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )
    assert malformed.returncode == 2
    assert malformed.stderr == "quality_cli_error\n"
    assert secret_argument not in malformed.stderr

    input_path = tmp_path / "large-line.jsonl"
    output_path = tmp_path / "limited-report.json"
    input_path.write_bytes(b"SENSITIVE_LINE_VALUE" * ((MAX_JSONL_LINE_BYTES // 20) + 2))
    limited = subprocess.run(
        [sys.executable, "-m", "saydrop_server.quality", "--input", str(input_path), "--output", str(output_path)],
        cwd=tmp_path,
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )
    serialized = output_path.read_text(encoding="utf-8")
    assert limited.returncode == 2
    assert limited.stderr == ""
    assert json.loads(serialized)["input"] == {"status": "rejected", "reason": "line_byte_limit_exceeded"}
    assert "SENSITIVE_LINE_VALUE" not in serialized
