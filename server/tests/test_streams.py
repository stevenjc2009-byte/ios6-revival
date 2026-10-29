import time

import httpx
import pytest

from ytserver import config, streams
from ytserver.streams import Source, StreamError, StreamManager

VID = "jNQXAC9IVRw"
BODY = bytes(range(256)) * 40  # 10240 bytes standing in for a video


def info(**over):
    base = {"url": f"https://rr1.googlevideo.com/videoplayback?expire={int(time.time()) + 21600}&itag=18",
            "protocol": "https", "http_headers": {"User-Agent": "UA"}, "format_id": "18"}
    return {**base, **over}


def upstream(seen, status=None):
    """Fake googlevideo: honours Range like the real one (206 + Content-Range)."""
    def handler(req: httpx.Request) -> httpx.Response:
        seen.append(req)
        if status:
            return httpx.Response(status)
        rng = req.headers.get("range")
        if not rng:
            return net(200, BODY, {})
        start, _, end = rng.removeprefix("bytes=").partition("-")
        start, end = int(start), int(end) if end else len(BODY) - 1
        return net(206, BODY[start:end + 1], {"Content-Range": f"bytes {start}-{end}/{len(BODY)}"})
    return httpx.MockTransport(handler)


def net(status, data, headers):
    # an iterator body is streamed like a real socket (bytes would be pre-read)
    chunks = iter([data[i:i + 4096] for i in range(0, len(data), 4096)])
    return httpx.Response(status, content=chunks, headers={
        "Content-Type": "video/mp4", "Content-Length": str(len(data)), **headers})


@pytest.fixture
def cfg(tmp_path, monkeypatch):
    monkeypatch.setenv("YTS_CACHE_DIR", str(tmp_path))
    return config.load()


def manager(cfg, resolve, transport):
    return StreamManager(cfg, resolve=resolve, transport=transport)


def test_selector_is_single_progressive_h264_file():
    sel = streams.progressive_format(360)
    assert "vcodec^=avc1" in sel and "acodec^=mp4a" in sel and "height<=360" in sel
    assert "protocol^=http" in sel and "+" not in sel  # no merge = nothing to store


def test_source_from_info_keeps_url_headers_and_expiry():
    src = streams.source_from_info(info(available_at=time.time() + 4))
    assert src.url.startswith("https://rr1.googlevideo.com/") and src.headers == {"User-Agent": "UA"}
    assert 3 <= src.available_at - time.time() <= 4.1
    assert 3 * 3600 < src.ttl <= streams.MAX_TTL  # cached until shortly before googlevideo's expire


@pytest.mark.parametrize("bad", [info(url=None), info(protocol="m3u8_native"), {}])
def test_source_from_info_rejects_unplayable(bad):
    with pytest.raises(StreamError):
        streams.source_from_info(bad)


def test_open_forwards_range_and_ytdlp_headers(cfg):
    seen = []
    m = manager(cfg, lambda vid: streams.source_from_info(info()), upstream(seen))
    up = m.open(VID, "GET", "bytes=0-1", 5)
    assert up.status_code == 206 and up.read() == BODY[:2]
    assert seen[0].headers["range"] == "bytes=0-1" and seen[0].headers["user-agent"] == "UA"
    assert seen[0].headers["accept-encoding"] == "identity"  # raw bytes must match Content-Length


def test_resolve_is_cached_across_requests(cfg):
    calls = []
    m = manager(cfg, lambda vid: calls.append(vid) or streams.source_from_info(info()), upstream([]))
    for _ in range(3):
        m.open(VID, "GET", "bytes=0-1", 5).close()
    assert calls == [VID]


def test_expired_url_is_resolved_again_once(cfg):
    calls, seen = [], []
    m = manager(cfg, lambda vid: calls.append(vid) or streams.source_from_info(info()), upstream(seen, 403))
    up = m.open(VID, "GET", None, 5)
    assert up.status_code == 403 and len(calls) == 2 and len(seen) == 2


def test_open_waits_for_available_at(cfg):
    m = manager(cfg, lambda vid: streams.source_from_info(info(available_at=time.time() + 0.4)), upstream([]))
    t0 = time.monotonic()
    m.open(VID, "GET", "bytes=0-1", 5).close()
    assert time.monotonic() - t0 >= 0.35  # googlevideo answers 403 before available_at


def test_failed_resolve_is_negative_cached(cfg):
    calls = []

    def boom(vid):
        calls.append(vid)
        raise StreamError("no progressive format")

    m = manager(cfg, boom, upstream([]))
    for _ in range(2):
        with pytest.raises(StreamError):
            m.open(VID, "GET", None, 5)
    assert calls == [VID]


def test_old_video_cache_is_removed_at_start(cfg):
    old = cfg.cache_dir / "videos"
    old.mkdir()
    (old / f"{VID}.mp4").write_bytes(b"x" * 100)
    manager(cfg, lambda vid: None, upstream([]))
    assert not old.exists()


def test_source_is_a_plain_record():
    src = Source("u", {}, 0.0, 60.0)
    assert (src.url, src.ttl) == ("u", 60.0)
