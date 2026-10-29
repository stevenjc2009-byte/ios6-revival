"""/stream/<id> relays googlevideo bytes as they arrive: Range in, 206 out, no file."""
import httpx
import pytest

from ytserver import config, streams
from ytserver.app import create_app
from ytserver.streams import StreamManager

from test_app import FakeIT, FakeThumbs
from test_streams import BODY, VID, info, upstream


def make_client(tmp_path, monkeypatch, transport):
    monkeypatch.setenv("YTS_CACHE_DIR", str(tmp_path))
    cfg = config.load()
    m = StreamManager(cfg, resolve=lambda vid: streams.source_from_info(info()), transport=transport)
    app = create_app(cfg, innertube=FakeIT(), streams=m, thumb_proxy=FakeThumbs())
    app.testing = True
    return app.test_client()


@pytest.fixture
def client(tmp_path, monkeypatch):
    return make_client(tmp_path, monkeypatch, upstream([]))


def test_range_request_is_relayed_as_206(client):
    r = client.get(f"/stream/{VID}.mp4", headers={"Range": "bytes=100-199"})
    assert r.status_code == 206 and r.mimetype == "video/mp4"
    assert r.headers["Content-Range"] == f"bytes 100-199/{len(BODY)}"
    assert r.headers["Content-Length"] == "100" and r.headers["Accept-Ranges"] == "bytes"
    assert r.data == BODY[100:200]


def test_whole_file_without_range(client):
    r = client.get(f"/getvideo/{VID}")
    assert r.status_code == 200 and r.data == BODY and r.headers["Content-Length"] == str(len(BODY))


def test_head_gives_length_and_no_body(client):
    r = client.head(f"/stream/{VID}.mp4")
    assert r.status_code == 200 and r.headers["Accept-Ranges"] == "bytes" and r.data == b""


def test_nothing_is_written_to_disk(client, tmp_path):
    client.get(f"/stream/{VID}.mp4", headers={"Range": "bytes=0-"})
    assert [p for p in tmp_path.rglob("*") if p.is_file()] == []


def test_upstream_error_is_502(tmp_path, monkeypatch):
    c = make_client(tmp_path, monkeypatch, upstream([], status=404))
    assert c.get(f"/stream/{VID}.mp4").status_code == 502


def test_upstream_connection_failure_is_502(tmp_path, monkeypatch):
    def refuse(req):
        raise httpx.ConnectError("refused")
    c = make_client(tmp_path, monkeypatch, httpx.MockTransport(refuse))
    assert c.get(f"/stream/{VID}.mp4").status_code == 502
