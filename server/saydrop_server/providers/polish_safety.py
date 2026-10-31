from __future__ import annotations

import re
import unicodedata
from collections import Counter

from saydrop_server.config import Settings

_MAX_POLISH_CHARS = 16_000
_FILLERS = frozenset({"\u55ef", "\u5443"})
_TRAILING_URL_PUNCTUATION = frozenset(".,!?;:，。！？；：、)]}）】》〉」』…")
_URL_RE = re.compile(r"(?i)\b(?:https?://|www\.)[^\s<>\"'`]+")
_EMAIL_RE = re.compile(
    r"(?i)\b[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@"
    r"[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?)+\b"
)
_NUMBER_RE = re.compile(r"\d+(?:[.,:/-]\d+)*")
# This includes ordinary English terms, underscore identifiers, versions, and hyphenated code IDs.
_IDENTIFIER_RE = re.compile(r"(?<![A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*(?:[-./:+#][A-Za-z0-9_]+)*(?![A-Za-z0-9_])")
_BACKTICK_CODE_RE = re.compile(r"`[^`\n]*`")


def _is_valid_unicode(value: str) -> bool:
    try:
        value.encode("utf-8", "strict")
    except UnicodeEncodeError:
        return False
    return True


def _strip_url_terminal_punctuation(value: str) -> str:
    while value and value[-1] in _TRAILING_URL_PUNCTUATION:
        value = value[:-1]
    return value


def _protected_tokens(value: str) -> tuple[tuple[str, ...], ...]:
    """Return exact token sequences whose punctuation must not be normalized."""

    return (
        tuple(_strip_url_terminal_punctuation(match.group(0)) for match in _URL_RE.finditer(value)),
        tuple(match.group(0) for match in _EMAIL_RE.finditer(value)),
        tuple(match.group(0) for match in _NUMBER_RE.finditer(value)),
        tuple(match.group(0) for match in _IDENTIFIER_RE.finditer(value)),
        tuple(match.group(0) for match in _BACKTICK_CODE_RE.finditer(value)),
    )


def _non_editable_characters(value: str) -> str:
    """Drop only punctuation, whitespace, and the two permitted spoken fillers."""

    return "".join(
        character
        for character in value
        if not character.isspace()
        and character not in _FILLERS
        and not unicodedata.category(character).startswith("P")
    )


def safe_polish(raw: str, candidate: str, settings: Settings) -> bool:
    """Return whether ``candidate`` is a mechanically safe light polish of ``raw``.

    This intentionally cannot prove semantic equivalence. It accepts only punctuation or
    whitespace edits and removal (never insertion/replacement) of the explicit fillers
    The two configured Chinese filler characters; all other character sequences and protected tokens remain exact.
    """

    if not isinstance(raw, str) or not isinstance(candidate, str):
        return False
    if not candidate.strip() or not _is_valid_unicode(raw) or not _is_valid_unicode(candidate):
        return False

    max_chars = min(settings.polish_max_chars, _MAX_POLISH_CHARS)
    if len(raw) > max_chars or len(candidate) > max_chars:
        return False

    # Punctuation can at most double a character-dense transcript; the small fixed
    # allowance permits normal sentence and paragraph separators for short transcripts.
    max_candidate_length = min(max_chars, max(len(raw) * 2, len(raw) + 64))
    if len(candidate) > max_candidate_length:
        return False

    if _protected_tokens(raw) != _protected_tokens(candidate):
        return False
    if _non_editable_characters(raw) != _non_editable_characters(candidate):
        return False

    raw_fillers = Counter(character for character in raw if character in _FILLERS)
    candidate_fillers = Counter(character for character in candidate if character in _FILLERS)
    return all(candidate_fillers[filler] <= raw_fillers[filler] for filler in _FILLERS)
