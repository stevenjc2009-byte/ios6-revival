import base64
import xml.etree.ElementTree as ET

import pytest

from ytserver import config, thumbs
from ytserver.app import create_app
from ytserver.models import Page, Video
from ytserver.streams import StreamError

A = "{http://www.w3.org/2005/Atom}"
JPEG = b"\xff\xd8\xff\xe0" + b"0" * 32


class FakeIT:
    def search(self, query, params, want):
        return Page(videos=[Video(id="jNQXAC9IVRw", title=query, author="a", duration=5)]), False

    def video(self, vid):
        return Video(id=vid, title="t", author="a", duration=5)


class FakeStreams:
    def __init__(self):
        self.prefetched = []

    def prefetch(self, vid):
        self.prefetched.append(vid)

    def get(self, vid, timeout):
        raise StreamError("nope")

    def hold(self, path, delta):
        pass


class FakeThumbs:
    def video_thumb(self, vid, name):
        return JPEG if vid == "jNQXAC9IVRw" else None

    def image(self, token):
        return JPEG if thumbs.decode_url(token) else None


@pytest.fixture
def client():
    app = create_app(config.load(), innertube=FakeIT(), streams=FakeStreams(), thumb_proxy=FakeThumbs())
    app.testing = True
    return app.test_client()


def test_healthz(client):
    r = client.get("/healthz")
    assert r.status_code == 200 and r.data.strip() == b"ok"


def test_search_returns_atom_and_escapes_query(client):
    r = client.get("/feeds/api/videos", query_string={"q": "<b>&x"})
    assert r.status_code == 200 and r.mimetype == "application/atom+xml"
    feed = ET.fromstring(r.data)
    assert feed.find(A + "entry/" + A + "title").text == "<b>&x"


def test_video_entry_triggers_prefetch(client):
    r = client.get("/feeds/api/videos/jNQXAC9IVRw")
    assert r.status_code == 200
    assert client.application.extensions["yts"].streams.prefetched == ["jNQXAC9IVRw"]


@pytest.mark.parametrize("path", [
    "/feeds/api/videos/bad", "/stream/bad", "/stream/jNQXAC9IVRw%0a",
    "/feeds/api/videos/jNQXAC9IVR;/related",
])
def test_bad_ids_rejected_before_any_upstream_call(client, path):
    assert client.get(path).status_code in (400, 404)
    assert client.application.extensions["yts"].streams.prefetched == []


def test_failed_build_is_502_not_500(client):
    assert client.get("/stream/jNQXAC9IVRw.mp4").status_code == 502


def test_thumbnail_ok_and_missing(client):
    r = client.get("/vi/jNQXAC9IVRw/mqdefault.jpg")
    assert r.status_code == 200 and r.mimetype == "image/jpeg"
    assert client.get("/vi/aaaaaaaaaaa/mqdefault.jpg").status_code == 404


def test_avatar_token_refuses_foreign_hosts(client):
    evil = base64.urlsafe_b64encode(b"https://evil.example/x.jpg").decode().rstrip("=")
    assert thumbs.decode_url(evil) == ""
    assert client.get(f"/img/{evil}.jpg").status_code == 404
    good = thumbs.encode_url("https://yt3.ggpht.com/abc=s88")
    assert good and thumbs.decode_url(good) == "https://yt3.ggpht.com/abc=s88"
    assert client.get(f"/img/{good}.jpg").status_code == 200
    assert thumbs.encode_url("http://yt3.ggpht.com/abc") == ""


def test_signed_out_feeds_are_empty_not_errors(client):
    for p in ("/feeds/api/users/default/subscriptions", "/feeds/api/videos/jNQXAC9IVRw/comments"):
        r = client.get(p)
        assert r.status_code == 200 and ET.fromstring(r.data).findall(A + "entry") == []


def test_fake_register_device(client):
    assert client.post("/youtube/accounts/registerDevice").status_code == 200
