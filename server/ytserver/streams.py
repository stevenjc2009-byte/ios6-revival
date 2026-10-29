"""Pass-through playback: nothing is downloaded or stored.

yt-dlp only *resolves* a video to the direct googlevideo URL of its
progressive H.264 + AAC MP4 (one file, itag 18, <= max_height), which the
iPhone 4 plays as-is. The stream route then relays bytes from that URL to the
phone as they arrive, forwarding Range requests, exactly like a normal
YouTube player streams. The server holds only the URL (in memory, until
googlevideo's own expiry) and the chunk currently in flight.

Videos with no progressive format (live streams) are reported unavailable:
playing them would need a merged or transcoded copy.
"""
from __future__ import annotations

import logging
import shutil
import threading
import time
from concurrent.futures import Future, ThreadPoolExecutor
from concurrent.futures import TimeoutError as FutureTimeout
from dataclasses import dataclass
from typing import Callable
from urllib.parse import parse_qs, urlparse

import httpx

from .cache import TTLCache
from .config import Config
from .ids import is_video_id

log = logging.getLogger("ytserver.streams")

NEG_TTL = 60.0  # seconds a failed lookup is remembered before retrying
MAX_TTL = 5 * 3600.0  # googlevideo URLs live 6 h; re-resolve well before
DEFAULT_TTL = 3600.0  # when the URL carries no expire= parameter
EXPIRY_MARGIN = 600.0


class StreamError(RuntimeError):
    """The video has no playable stream, or YouTube refused it."""


class StreamPending(RuntimeError):
    """The URL lookup is still running; the client should retry."""


@dataclass(frozen=True)
class Source:
    url: str
    headers: dict[str, str]
    available_at: float  # wall clock; googlevideo answers 403 before this
    ttl: float  # seconds this URL may be reused


def progressive_format(max_h: int) -> str:
    return f"b[vcodec^=avc1][acodec^=mp4a][height<={max_h}][protocol^=http]"


def source_from_info(info: dict) -> Source:
    """Turn yt-dlp's extract_info(download=False) result into a Source."""
    url = info.get("url")
    if not url or not str(info.get("protocol", "")).startswith("http"):
        raise StreamError("no progressive H.264 stream")
    ttl = DEFAULT_TTL
    try:
        expire = float(parse_qs(urlparse(url).query)["expire"][0])
        ttl = max(60.0, min(MAX_TTL, expire - time.time() - EXPIRY_MARGIN))
    except (KeyError, ValueError):
        pass
    return Source(url, dict(info.get("http_headers") or {}),
                  float(info.get("available_at") or 0), ttl)


class StreamManager:
    def __init__(self, cfg: Config, *, resolve: Callable[[str], Source] | None = None,
                 transport: httpx.BaseTransport | None = None) -> None:
        self.cfg = cfg
        self._resolve = resolve or self._resolve_ytdlp
        self._pool = ThreadPoolExecutor(max_workers=cfg.workers, thread_name_prefix="resolve")
        self._jobs: dict[str, Future] = {}
        self._sources = TTLCache(DEFAULT_TTL, max_items=256)
        self._failed: dict[str, tuple[float, str]] = {}
        self._lock = threading.Lock()
        # IPv4 for both the lookup and the relay: googlevideo URLs are bound to
        # the address that resolved them (ip=...), and the container is IPv4-only.
        self._http = httpx.Client(
            transport=transport or httpx.HTTPTransport(local_address="0.0.0.0", retries=1),
            timeout=httpx.Timeout(10.0, read=30.0), follow_redirects=True,
            limits=httpx.Limits(max_connections=64, max_keepalive_connections=8))
        self._remove_old_video_cache()

    # ---- public ----------------------------------------------------------
    def prefetch(self, vid: str) -> None:
        if is_video_id(vid) and self._sources.get(vid) is None:
            self._job(vid)

    def get(self, vid: str, timeout: float) -> Source:
        if not is_video_id(vid):
            raise StreamError("bad video id")
        src = self._sources.get(vid)
        if src is not None:
            return src
        try:
            return self._job(vid).result(timeout=timeout)
        except FutureTimeout:
            raise StreamPending(vid) from None

    def open(self, vid: str, method: str, rng: str | None, timeout: float) -> httpx.Response:
        """Start relaying vid from googlevideo; the caller must close() the response."""
        for attempt in (1, 2):
            src = self.get(vid, timeout)
            time.sleep(max(0.0, src.available_at - time.time()))
            headers = {**src.headers, "Accept-Encoding": "identity"}
            if rng:
                headers["Range"] = rng
            try:
                resp = self._http.send(self._http.build_request(method, src.url, headers=headers), stream=True)
            except httpx.HTTPError as exc:
                raise StreamError(f"upstream: {type(exc).__name__}") from exc
            if resp.status_code in (403, 410) and attempt == 1:
                resp.close()  # URL expired or refused: look it up again, once
                log.info("googlevideo %d for %s, resolving again", resp.status_code, vid)
                self._sources.pop(vid)
                continue
            return resp
        raise AssertionError("unreachable")

    # ---- internals -------------------------------------------------------
    def _job(self, vid: str) -> Future:
        with self._lock:
            failed = self._failed.get(vid)
            if failed and failed[0] > time.monotonic():
                done: Future = Future()
                done.set_exception(StreamError(failed[1]))
                return done
            fut = self._jobs.get(vid)
            if fut is None:
                fut = self._pool.submit(self._run, vid)
                self._jobs[vid] = fut
            return fut

    def _run(self, vid: str) -> Source:
        t0 = time.monotonic()
        try:
            src = self._resolve(vid)
            self._sources.set(vid, src, ttl=src.ttl)
            log.info("resolved %s in %.1fs", vid, time.monotonic() - t0)
            return src
        except Exception as exc:  # recorded, then re-raised to every waiter
            log.warning("lookup failed for %s: %s", vid, exc)
            with self._lock:
                self._failed[vid] = (time.monotonic() + NEG_TTL, str(exc)[:200])
            raise StreamError(str(exc)[:200]) from exc
        finally:
            with self._lock:
                self._jobs.pop(vid, None)

    def _remove_old_video_cache(self) -> None:
        """Earlier versions kept built MP4s here; nothing is stored any more."""
        old = self.cfg.cache_dir / "videos"
        if old.is_dir():
            shutil.rmtree(old, ignore_errors=True)
            log.info("removed old video cache %s", old)

    def _resolve_ytdlp(self, vid: str) -> Source:
        import yt_dlp  # imported lazily: heavy, and tests do not need it

        opts = {
            "format": progressive_format(self.cfg.max_height), "noplaylist": True,
            "quiet": True, "no_warnings": True, "skip_download": True, "socket_timeout": 20,
            "source_address": "0.0.0.0", "cachedir": str(self.cfg.cache_dir / "ytdlp"),
        }
        if shutil.which("deno"):
            opts["js_runtimes"] = {"deno": {}}
        try:
            with yt_dlp.YoutubeDL(opts) as ydl:
                info = ydl.extract_info(f"https://www.youtube.com/watch?v={vid}", download=False)
        except Exception as exc:  # yt_dlp raises several unrelated types
            raise StreamError(str(exc).splitlines()[-1][:150]) from exc
        return source_from_info(info or {})
