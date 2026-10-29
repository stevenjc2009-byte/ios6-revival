"""Build and cache iPhone-4-playable MP4 files with yt-dlp + ffmpeg.

Output contract for every file in the cache: H.264 (Baseline/Main) + AAC-LC,
height <= max_height, <= 30 fps, moov atom at the front (faststart).

Build chain (first that succeeds wins):
  1. progressive avc1+mp4a stream  (single file, cheapest)
  2. bestvideo avc1 + bestaudio mp4a, merged
  3. anything <= max_height, transcoded with libx264/aac
Whatever yt-dlp downloads is then probed with ffprobe: if the codecs already
fit it is remuxed with `-c copy -movflags +faststart`, otherwise only the
offending stream(s) are re-encoded.
"""
from __future__ import annotations

import json
import logging
import shutil
import subprocess
import threading
import time
from concurrent.futures import Future, ThreadPoolExecutor
from concurrent.futures import TimeoutError as FutureTimeout
from pathlib import Path

from .cache import evict_lru, touch
from .config import Config
from .ids import is_video_id

log = logging.getLogger("ytserver.streams")

OK_PROFILES = {"baseline", "constrained baseline", "main"}
NEG_TTL = 60.0  # seconds a failed build is remembered before retrying


class StreamError(RuntimeError):
    """No playable file could be produced."""


class StreamPending(RuntimeError):
    """The file is still being built; the client should retry."""


def format_chain(max_h: int) -> list[tuple[str, str]]:
    return [
        ("progressive-avc1", f"b[vcodec^=avc1][acodec^=mp4a][height<={max_h}]"),
        ("dash-avc1+mp4a", f"bv[vcodec^=avc1][height<={max_h}]+ba[acodec^=mp4a]"),
        ("any-transcode", f"bv[height<={max_h}]+ba/b[height<={max_h}]/w"),
    ]


def plan_ffmpeg(info: dict, max_h: int) -> tuple[list[str], str]:
    """ffmpeg codec args for a probed file + a label ('copy', 'audio', 'video', 'full')."""
    v = next((s for s in info.get("streams", []) if s.get("codec_type") == "video"), {})
    a = next((s for s in info.get("streams", []) if s.get("codec_type") == "audio"), {})
    fps = 0.0
    try:
        num, den = str(v.get("avg_frame_rate", "0/1")).split("/")
        fps = float(num) / float(den) if float(den) else 0.0
    except ValueError:
        pass
    v_ok = (v.get("codec_name") == "h264" and str(v.get("profile", "")).lower() in OK_PROFILES
            and int(v.get("height") or 9999) <= max_h and fps <= 30.5 and v.get("pix_fmt") == "yuv420p")
    a_ok = a.get("codec_name") == "aac" and str(a.get("profile", "LC")).upper() == "LC"
    vargs = ["-c:v", "copy"] if v_ok else [
        "-c:v", "libx264", "-profile:v", "main", "-level", "3.0", "-pix_fmt", "yuv420p",
        "-preset", "veryfast", "-crf", "23", "-r", "30",
        "-vf", f"scale=-2:'min(ih,{max_h})'"]
    aargs = ["-c:a", "copy"] if a_ok else ["-c:a", "aac", "-b:a", "128k", "-ac", "2"]
    if not a:
        aargs = ["-an"]
    label = "copy" if v_ok and a_ok else "audio" if v_ok else "video" if a_ok else "full"
    return vargs + aargs, label


class StreamManager:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        cfg.video_dir.mkdir(parents=True, exist_ok=True)
        self._pool = ThreadPoolExecutor(max_workers=cfg.workers, thread_name_prefix="build")
        self._jobs: dict[str, Future] = {}
        self._failed: dict[str, tuple[float, str]] = {}
        self._lock = threading.Lock()
        self._serving: dict[Path, int] = {}
        self._clean_stale()

    # ---- public ----------------------------------------------------------
    def path_for(self, vid: str) -> Path:
        return self.cfg.video_dir / f"{vid}.mp4"

    def ready(self, vid: str) -> Path | None:
        path = self.path_for(vid)
        try:
            if path.stat().st_size > 0:
                touch(path)
                return path
        except OSError:
            pass
        return None

    def prefetch(self, vid: str) -> None:
        if is_video_id(vid) and self.ready(vid) is None:
            self._job(vid)

    def get(self, vid: str, timeout: float) -> Path:
        """Return the finished file, building it if needed (blocks up to timeout)."""
        if not is_video_id(vid):
            raise StreamError("bad video id")
        path = self.ready(vid)
        if path:
            return path
        fut = self._job(vid)
        try:
            return fut.result(timeout=timeout)
        except FutureTimeout:
            raise StreamPending(vid) from None

    def hold(self, path: Path, delta: int) -> None:
        """Mark a file as being served so LRU eviction leaves it alone."""
        with self._lock:
            self._serving[path] = max(0, self._serving.get(path, 0) + delta)

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

    def _run(self, vid: str) -> Path:
        try:
            path = self._build(vid)
            self._evict(path)
            return path
        except Exception as exc:  # recorded, then re-raised to every waiter
            log.warning("build failed for %s: %s", vid, exc)
            with self._lock:
                self._failed[vid] = (time.monotonic() + NEG_TTL, str(exc)[:200])
            raise StreamError(str(exc)[:200]) from exc
        finally:
            with self._lock:
                self._jobs.pop(vid, None)

    def _clean_stale(self) -> None:
        for leftover in self.cfg.video_dir.glob("work-*"):
            shutil.rmtree(leftover, ignore_errors=True)

    def _evict(self, keep: Path) -> None:
        def busy(p: Path) -> bool:
            with self._lock:
                return self._serving.get(p, 0) > 0

        removed = evict_lru(self.cfg.video_dir, self.cfg.cache_max_mb * 1024 * 1024, [keep], busy)
        if removed:
            log.info("evicted %d cached video(s)", len(removed))

    def _build(self, vid: str) -> Path:
        work = self.cfg.video_dir / f"work-{vid}"
        shutil.rmtree(work, ignore_errors=True)
        work.mkdir(parents=True)
        t0 = time.monotonic()
        try:
            src, step = self._download(vid, work)
            final_tmp = work / "final.mp4"
            label = self._normalise(src, final_tmp)
            final = self.path_for(vid)
            final_tmp.replace(final)
            log.info("built %s via %s/%s in %.1fs (%d KB)", vid, step, label,
                     time.monotonic() - t0, final.stat().st_size // 1024)
            return final
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def _download(self, vid: str, work: Path) -> tuple[Path, str]:
        import yt_dlp  # imported lazily: heavy, and tests do not need it

        errors: list[str] = []
        for step, fmt in format_chain(self.cfg.max_height):
            for stale in work.glob("dl.*"):
                stale.unlink(missing_ok=True)
            opts = {
                "format": fmt, "outtmpl": str(work / "dl.%(ext)s"), "noplaylist": True,
                "quiet": True, "no_warnings": True, "noprogress": True, "retries": 3,
                "fragment_retries": 3, "socket_timeout": 20, "concurrent_fragment_downloads": 4,
                "merge_output_format": "mkv" if step == "any-transcode" else "mp4",
                "cachedir": str(self.cfg.cache_dir / "ytdlp"), "nocheckcertificate": False,
            }
            if shutil.which("deno"):
                opts["js_runtimes"] = {"deno": {}}
            try:
                with yt_dlp.YoutubeDL(opts) as ydl:
                    ydl.download([f"https://www.youtube.com/watch?v={vid}"])
            except Exception as exc:  # yt_dlp raises several unrelated types
                errors.append(f"{step}: {str(exc).splitlines()[-1][:120]}")
                continue
            files = [p for p in work.glob("dl.*") if p.suffix not in (".part", ".ytdl")]
            if files:
                return max(files, key=lambda p: p.stat().st_size), step
            errors.append(f"{step}: no output")
        raise StreamError("; ".join(errors) or "download failed")

    def _normalise(self, src: Path, dest: Path) -> str:
        probe = subprocess.run(
            ["ffprobe", "-v", "error", "-print_format", "json", "-show_streams", str(src)],
            capture_output=True, text=True, timeout=60, check=False)
        try:
            info = json.loads(probe.stdout or "{}")
        except ValueError:
            info = {}
        codec_args, label = plan_ffmpeg(info, self.cfg.max_height)
        cmd = ["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(src), "-map", "0:v:0", "-map", "0:a:0?",
               *codec_args, "-movflags", "+faststart", "-f", "mp4", str(dest)]
        run = subprocess.run(cmd, capture_output=True, text=True, timeout=1800, check=False)
        if run.returncode != 0 or not dest.exists():
            raise StreamError("ffmpeg: " + (run.stderr.strip().splitlines() or ["failed"])[-1][:150])
        return label
