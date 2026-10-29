"""Plain-HTTP proxy for ytimg thumbnails and channel avatars.

iOS 6 cannot negotiate modern TLS, so images are fetched here over HTTPS and
handed to the phone over HTTP.  Only fixed Google image hosts are ever
contacted, never a host taken from a request.
"""
from __future__ import annotations

import base64
import binascii
import logging
import threading
from collections import OrderedDict
from urllib.parse import urlsplit

import httpx

from .ids import THUMB_NAME_RE, is_video_id

log = logging.getLogger("ytserver.thumbs")

ALLOWED_HOSTS = {"i.ytimg.com", "yt3.ggpht.com", "yt3.googleusercontent.com"}
MAX_BYTES = 2_000_000
_FALLBACKS = {"maxresdefault": "hqdefault", "sddefault": "hqdefault"}


def encode_url(url: str) -> str:
    """Token for /img/<token>.jpg (empty if the URL is not an allowed https image)."""
    parts = urlsplit(url)
    if parts.scheme != "https" or parts.hostname not in ALLOWED_HOSTS:
        return ""
    return base64.urlsafe_b64encode(url.encode()).decode().rstrip("=")


def decode_url(token: str) -> str:
    try:
        url = base64.urlsafe_b64decode(token + "=" * (-len(token) % 4)).decode()
    except (binascii.Error, UnicodeDecodeError, ValueError):
        return ""
    return url if encode_url(url) else ""


class ThumbProxy:
    def __init__(self, client: httpx.Client | None = None, max_items: int = 400) -> None:
        self._http = client or httpx.Client(timeout=httpx.Timeout(10.0, connect=5.0), follow_redirects=False)
        self._cache: OrderedDict[str, bytes] = OrderedDict()
        self._max = max_items
        self._lock = threading.Lock()

    def _fetch(self, url: str) -> bytes | None:
        with self._lock:
            if url in self._cache:
                self._cache.move_to_end(url)
                return self._cache[url]
        try:
            resp = self._http.get(url)
        except httpx.HTTPError:
            return None
        ctype = resp.headers.get("content-type", "")
        if resp.status_code != 200 or not ctype.startswith("image/") or len(resp.content) > MAX_BYTES:
            return None
        with self._lock:
            self._cache[url] = resp.content
            while len(self._cache) > self._max:
                self._cache.popitem(last=False)
        return resp.content

    def video_thumb(self, video_id: str, name: str) -> bytes | None:
        if not is_video_id(video_id) or not THUMB_NAME_RE.fullmatch(name):
            return None
        tries = [name] + ([_FALLBACKS[name]] if name in _FALLBACKS else [])
        for candidate in tries:
            data = self._fetch(f"https://i.ytimg.com/vi/{video_id}/{candidate}.jpg")
            if data:
                return data
        return None

    def image(self, token: str) -> bytes | None:
        url = decode_url(token)
        return self._fetch(url) if url else None
