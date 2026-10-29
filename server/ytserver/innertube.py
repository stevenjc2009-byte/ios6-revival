"""Minimal InnerTube (youtube.com JSON API) client with TTL caching.

We use the plain WEB client: it works without login, returns search/browse/next
data and gives videoDetails from /player even for videos it cannot stream
(streams come from yt-dlp, see streams.py).
"""
from __future__ import annotations

import base64
import logging
import threading
from typing import Any

import httpx

from . import parse
from .cache import TTLCache
from .ids import is_channel_id
from .models import Channel, Page, Video

log = logging.getLogger("ytserver.innertube")

_BASE = "https://www.youtube.com/youtubei/v1/"
_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
       "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")
_CLIENT = {"clientName": "WEB", "clientVersion": "2.20260101.00.00", "hl": "en", "gl": "US"}

SP_CHANNEL = "EgIQAg%3D%3D"
SORT_CODES = {"rating": 1, "published": 2, "viewCount": 3}  # relevance = no sort field
DATE_CODES = {"today": 2, "this_week": 3, "this_month": 4}
DURATION_CODES = {"short": 1, "long": 2}


def search_params(sort: str = "", date: str = "", duration: str = "") -> str:
    """Hand-encoded search `sp` protobuf: [sort] + filters{date, type=video, duration}."""
    flt = b""
    if date in DATE_CODES:
        flt += bytes([0x08, DATE_CODES[date]])
    flt += bytes([0x10, 0x01])  # type = video
    if duration in DURATION_CODES:
        flt += bytes([0x18, DURATION_CODES[duration]])
    msg = b""
    if sort in SORT_CODES:
        msg += bytes([0x08, SORT_CODES[sort]])
    msg += bytes([0x12, len(flt)]) + flt
    return base64.b64encode(msg).decode()


CHANNEL_VIDEOS_PARAMS = "EgZ2aWRlb3PyBgQKAjoA"
CHANNEL_PLAYLISTS_PARAMS = "EglwbGF5bGlzdHPyBgQKAkIA"
MAX_PAGES = 6


class UpstreamError(RuntimeError):
    """InnerTube refused or returned something unusable."""


class InnerTube:
    def __init__(self, ttl: int = 600, client: httpx.Client | None = None) -> None:
        self._http = client or httpx.Client(
            timeout=httpx.Timeout(15.0, connect=8.0),
            headers={"User-Agent": _UA, "Accept-Language": "en-US,en;q=0.9",
                     "Origin": "https://www.youtube.com"},
            limits=httpx.Limits(max_connections=20),
        )
        self._cache = TTLCache(ttl, max_items=1024)
        self._pages_cache = TTLCache(ttl, max_items=256)
        self._lock = threading.Lock()

    # ---- raw calls -------------------------------------------------------
    def call(self, endpoint: str, body: dict) -> dict:
        key = (endpoint, repr(sorted(body.items())))
        hit = self._cache.get(key)
        if hit is not None:
            return hit
        payload = {"context": {"client": _CLIENT}, **body}
        try:
            resp = self._http.post(f"{_BASE}{endpoint}?prettyPrint=false", json=payload)
            resp.raise_for_status()
            data = resp.json()
        except (httpx.HTTPError, ValueError) as exc:
            raise UpstreamError(f"{endpoint}: {type(exc).__name__}") from exc
        if not isinstance(data, dict):
            raise UpstreamError(f"{endpoint}: unexpected payload")
        self._cache.set(key, data)
        return data

    # ---- paged lists -----------------------------------------------------
    def collect(self, key: Any, first: tuple[str, dict], want: int,
                default_author: str = "") -> tuple[Page, bool]:
        """Gather at least `want` items by following continuations.

        GData pages by offset, InnerTube by token, so we keep the token chain
        for each logical feed.  Returns (merged page, more_available).
        """
        with self._lock:
            state = self._pages_cache.get(key)
            if state is None:
                state = {"page": Page(), "token": None, "lock": threading.Lock(), "n": 0}
                self._pages_cache.set(key, state)
        with state["lock"]:
            merged: Page = state["page"]
            while state["n"] < MAX_PAGES and _count(merged) < want and state["token"] != "":
                if state["token"] is None:
                    doc = self.call(*first)
                else:
                    doc = self.call(first[0], {"continuation": state["token"]})
                page = parse.extract(doc, default_author)
                state["n"] += 1
                state["token"] = page.token if page.token != state["token"] else ""
                _merge(merged, page)
                if not _count(page):
                    state["token"] = ""
            return merged, state["token"] != ""

    # ---- high level ------------------------------------------------------
    def search(self, query: str, params: str, want: int) -> tuple[Page, bool]:
        return self.collect(("search", query, params), ("search", {"query": query, "params": params}), want)

    def related(self, video_id: str, want: int) -> tuple[Page, bool]:
        return self.collect(("next", video_id), ("next", {"videoId": video_id}), want)

    def browse(self, browse_id: str, params: str, want: int, author: str = "") -> tuple[Page, bool]:
        body = {"browseId": browse_id}
        if params:
            body["params"] = params
        return self.collect(("browse", browse_id, params), ("browse", body), want, author)

    def video(self, video_id: str) -> Video | None:
        return parse.video_from_player(self.call("player", {
            "videoId": video_id, "contentCheckOk": True, "racyCheckOk": True}))

    def channel(self, channel_id: str) -> Channel | None:
        return parse.channel_header(self.call("browse", {"browseId": channel_id}), channel_id)

    def resolve_channel(self, name: str) -> str:
        """UC id for a channel id, @handle or legacy username ('' if unknown)."""
        if is_channel_id(name):
            return name
        handle = name if name.startswith("@") else "@" + name
        try:
            data = self.call("navigation/resolve_url", {"url": f"https://www.youtube.com/{handle}"})
        except UpstreamError:
            return ""
        return parse.resolve_browse_id(data)


def _count(page: Page) -> int:
    return max(len(page.videos), len(page.channels), len(page.playlists))


def _merge(into: Page, new: Page) -> None:
    for attr in ("videos", "channels", "playlists"):
        have = {i.id for i in getattr(into, attr)}
        getattr(into, attr).extend(i for i in getattr(new, attr) if i.id not in have)
