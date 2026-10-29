"""In-memory TTL cache and an on-disk LRU for built video files."""
from __future__ import annotations

import os
import threading
import time
from collections import OrderedDict
from pathlib import Path
from typing import Any, Callable, Iterable


class TTLCache:
    """Small thread-safe TTL + size-bounded cache."""

    def __init__(self, ttl: float, max_items: int = 512) -> None:
        self.ttl = ttl
        self.max_items = max_items
        self._data: OrderedDict[Any, tuple[float, Any]] = OrderedDict()
        self._lock = threading.Lock()

    def get(self, key: Any) -> Any | None:
        with self._lock:
            hit = self._data.get(key)
            if hit is None:
                return None
            if hit[0] < time.monotonic():
                del self._data[key]
                return None
            self._data.move_to_end(key)
            return hit[1]

    def set(self, key: Any, value: Any, ttl: float | None = None) -> None:
        with self._lock:
            self._data[key] = (time.monotonic() + (self.ttl if ttl is None else ttl), value)
            self._data.move_to_end(key)
            while len(self._data) > self.max_items:
                self._data.popitem(last=False)


def evict_lru(directory: Path, max_bytes: int, keep: Iterable[Path] = (),
              is_busy: Callable[[Path], bool] | None = None) -> list[Path]:
    """Delete least-recently-used *.mp4 files until the directory fits max_bytes.

    "Recently used" is the file mtime; the stream route touches a file whenever
    it is served.  Files in `keep` or reported busy are never removed.
    """
    protected = {Path(p).resolve() for p in keep}
    files = []
    for entry in directory.glob("*.mp4"):
        try:
            st = entry.stat()
        except OSError:
            continue
        files.append((st.st_mtime, st.st_size, entry))
    total = sum(size for _, size, _ in files)
    removed: list[Path] = []
    for _mtime, size, path in sorted(files):
        if total <= max_bytes:
            break
        if path.resolve() in protected or (is_busy and is_busy(path)):
            continue
        try:
            path.unlink()
        except OSError:  # open for reading on Windows, or already gone
            continue
        total -= size
        removed.append(path)
    return removed


def touch(path: Path) -> None:
    try:
        os.utime(path, None)
    except OSError:
        pass
