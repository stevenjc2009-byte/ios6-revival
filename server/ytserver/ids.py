"""Strict validation of everything that comes from a request."""
from __future__ import annotations

import re

VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")
CHANNEL_ID_RE = re.compile(r"^UC[A-Za-z0-9_-]{22}$")
PLAYLIST_ID_RE = re.compile(r"^(?:PL|UU|OL|FL|LL|RD|VL)?[A-Za-z0-9_-]{10,64}$")
USERNAME_RE = re.compile(r"^@?[A-Za-z0-9_.\-]{1,60}$")
THUMB_NAME_RE = re.compile(r"^[a-z0-9_]{1,16}$")

MAX_QUERY_LEN = 200
MAX_RESULTS_CAP = 50
DEFAULT_RESULTS = 25
MAX_START_INDEX = 500

_CTRL_RE = re.compile(r"[\x00-\x1f\x7f]")


def is_video_id(value: str | None) -> bool:
    return bool(value) and VIDEO_ID_RE.fullmatch(value) is not None


def is_channel_id(value: str | None) -> bool:
    return bool(value) and CHANNEL_ID_RE.fullmatch(value) is not None


def is_playlist_id(value: str | None) -> bool:
    return bool(value) and PLAYLIST_ID_RE.fullmatch(value) is not None


def is_username(value: str | None) -> bool:
    return bool(value) and USERNAME_RE.fullmatch(value) is not None


def clean_query(value: str | None) -> str:
    """Control characters removed, whitespace collapsed, length capped."""
    if not value:
        return ""
    value = _CTRL_RE.sub(" ", value)
    return " ".join(value.split())[:MAX_QUERY_LEN]


def _to_int(value: str | None, default: int) -> int:
    try:
        return int(value) if value is not None else default
    except ValueError:
        return default


def paging(start_index: str | None, max_results: str | None) -> tuple[int, int]:
    """(start-index, max-results) clamped to sane bounds (GData is 1-based)."""
    start = max(1, min(MAX_START_INDEX, _to_int(start_index, 1)))
    count = max(1, min(MAX_RESULTS_CAP, _to_int(max_results, DEFAULT_RESULTS)))
    return start, count
