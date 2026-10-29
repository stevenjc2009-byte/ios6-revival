"""Environment-driven configuration (see ios6-revival/CONTRACT.md)."""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _int(name: str, default: int, lo: int, hi: int) -> int:
    try:
        value = int(os.environ.get(name, default))
    except ValueError:
        value = default
    return max(lo, min(hi, value))


@dataclass(frozen=True)
class Config:
    bind: str
    port: int
    cache_dir: Path
    cache_max_mb: int
    max_height: int
    public_url: str  # "" = derive from the request Host header
    stream_wait: int  # seconds /stream/<id> blocks while the file is built
    workers: int  # concurrent video builds
    threads: int  # waitress worker threads
    meta_ttl: int  # seconds metadata responses stay cached

    @property
    def video_dir(self) -> Path:
        return self.cache_dir / "videos"


def load() -> Config:
    public = os.environ.get("YTS_PUBLIC_URL", "").strip().rstrip("/")
    if public and not public.startswith(("http://", "https://")):
        public = "http://" + public
    return Config(
        bind=os.environ.get("YTS_BIND", "0.0.0.0"),
        port=_int("YTS_PORT", 8080, 1, 65535),
        cache_dir=Path(os.environ.get("YTS_CACHE_DIR", "./cache")).resolve(),
        cache_max_mb=_int("YTS_CACHE_MAX_MB", 4096, 64, 1_000_000),
        max_height=_int("YTS_MAX_HEIGHT", 360, 144, 480),
        public_url=public,
        stream_wait=_int("YTS_STREAM_WAIT", 100, 5, 240),
        workers=_int("YTS_WORKERS", 2, 1, 6),
        threads=_int("YTS_THREADS", 16, 4, 64),
        meta_ttl=_int("YTS_META_TTL", 600, 10, 86400),
    )
