import os
import time

from ytserver import cache, streams

H264 = {"codec_type": "video", "codec_name": "h264", "profile": "Main", "height": 360,
        "avg_frame_rate": "30/1", "pix_fmt": "yuv420p"}
AAC = {"codec_type": "audio", "codec_name": "aac", "profile": "LC"}


def plan(video, audio, max_h=360):
    return streams.plan_ffmpeg({"streams": [s for s in (video, audio) if s]}, max_h)


def test_compliant_file_is_copied():
    args, label = plan(H264, AAC)
    assert label == "copy" and args == ["-c:v", "copy", "-c:a", "copy"]


def test_too_tall_video_is_reencoded_with_scale_cap():
    args, label = plan({**H264, "height": 720}, AAC)
    assert label == "video" and "libx264" in args
    assert any("min(ih,360)" in a for a in args)


def test_wrong_audio_is_reencoded_but_video_copied():
    args, label = plan(H264, {**AAC, "codec_name": "opus"})
    assert label == "audio" and args[:2] == ["-c:v", "copy"] and "aac" in args


def test_high_profile_or_60fps_is_reencoded():
    assert plan({**H264, "profile": "High"}, AAC)[1] in ("video", "full")
    assert plan({**H264, "avg_frame_rate": "60/1"}, AAC)[1] in ("video", "full")


def test_no_audio_track_drops_audio():
    args, _ = plan(H264, None)
    assert "-an" in args


def test_format_chain_respects_height():
    chain = streams.format_chain(360)
    assert chain[0][0] == "progressive-avc1"
    assert all("360" in sel for _, sel in chain[:2])


def _make(tmp_path, name, size, age):
    p = tmp_path / name
    p.write_bytes(b"x" * size)
    t = time.time() - age
    os.utime(p, (t, t))
    return p


def test_evict_lru_removes_oldest_first(tmp_path):
    old = _make(tmp_path, "old.mp4", 100, 300)
    mid = _make(tmp_path, "mid.mp4", 100, 200)
    new = _make(tmp_path, "new.mp4", 100, 100)
    removed = cache.evict_lru(tmp_path, 200)
    assert removed == [old] and not old.exists() and mid.exists() and new.exists()


def test_evict_lru_spares_keep_and_busy(tmp_path):
    old = _make(tmp_path, "old.mp4", 100, 300)
    mid = _make(tmp_path, "mid.mp4", 100, 200)
    new = _make(tmp_path, "new.mp4", 100, 100)
    removed = cache.evict_lru(tmp_path, 100, keep=[old], is_busy=lambda p: p == mid)
    assert removed == [new] and old.exists() and mid.exists()


def test_evict_lru_ignores_non_mp4(tmp_path):
    (tmp_path / "partial.tmp").write_bytes(b"x" * 1000)
    assert cache.evict_lru(tmp_path, 1) == []


def test_ttl_cache_expires():
    c = cache.TTLCache(0.05)
    c.set("k", 1)
    assert c.get("k") == 1
    time.sleep(0.08)
    assert c.get("k") is None
