import xml.etree.ElementTree as ET
from datetime import datetime, timezone

from ytserver import atom
from ytserver.models import Channel, Playlist, Video

A = "{http://www.w3.org/2005/Atom}"
M = "{http://search.yahoo.com/mrss/}"
Y = atom.NS_YT if hasattr(atom, "NS_YT") else "{http://gdata.youtube.com/schemas/2007}"
BASE = "http://192.168.1.10:8080"


def video(**kw):
    kw.setdefault("id", "jNQXAC9IVRw")
    kw.setdefault("title", "Me at the zoo")
    kw.setdefault("author", "jawed")
    kw.setdefault("duration", 19)
    kw.setdefault("views", 1234)
    kw.setdefault("published", datetime(2005, 4, 24, 3, 31, 52, tzinfo=timezone.utc))
    return Video(**kw)


def roundtrip(root):
    return ET.fromstring(atom.serialize(root))


def test_video_entry_core_fields_and_stream_urls():
    e = roundtrip(atom.video_entry(None, video(), BASE))
    assert e.tag == A + "entry"
    assert e.find(A + "title").text == "Me at the zoo"
    assert e.find(A + "author/" + A + "name").text == "jawed"
    assert e.find(A + "published").text == "2005-04-24T03:31:52.000Z"
    group = e.find(M + "group")
    assert group.find(Y + "duration").get("seconds") == "19"
    assert e.find(Y + "statistics").get("viewCount") == "1234"
    srcs = {c.get("url") for c in group.findall(M + "content") if "flash" not in c.get("type", "")}
    assert srcs == {f"{BASE}/stream/jNQXAC9IVRw.mp4"}
    assert e.find(A + "content").get("src") == f"{BASE}/stream/jNQXAC9IVRw.mp4"


def test_video_entry_covers_the_format_slots_the_app_asks_for():
    e = roundtrip(atom.video_entry(None, video(), BASE))
    formats = {c.get(Y + "format") for c in e.find(M + "group").findall(M + "content")}
    expected = {"5"} | {str(f) for f in atom.THREEGP_FORMATS} | {str(f) for f in atom.MP4_FORMATS}
    assert formats == expected


def test_thumbnails_are_plain_http_on_our_host():
    e = roundtrip(atom.video_entry(None, video(), BASE))
    urls = [t.get("url") for t in e.find(M + "group").findall(M + "thumbnail")]
    assert urls and all(u.startswith(BASE + "/vi/jNQXAC9IVRw/") and u.endswith(".jpg") for u in urls)


def test_markup_in_titles_is_escaped_not_injected():
    nasty = '</title><script>alert(1)</script> & "q" <b>'
    raw = atom.serialize(atom.video_entry(None, video(title=nasty, author=nasty), BASE))
    assert b"<script>" not in raw
    assert ET.fromstring(raw).find(A + "title").text == nasty


def test_illegal_xml_control_characters_are_dropped():
    raw = atom.serialize(atom.video_entry(None, video(title="a\x00b\x08c\x1fd"), BASE))
    assert ET.fromstring(raw).find(A + "title").text == "abcd"


def test_feed_paging_fields_and_next_link():
    root = atom.feed("Search", f"{BASE}/feeds/api/videos?q=x", BASE, 120, 26, 25,
                     atom.query_href(BASE, "/feeds/api/videos", q="x", **{"start-index": 51}))
    atom.video_entry(root, video(), BASE, 26)
    feed = roundtrip(root)
    ns = "{http://a9.com/-/spec/opensearch/1.1/}"
    assert feed.find(ns + "totalResults").text == "120"
    assert feed.find(ns + "startIndex").text == "26"
    assert feed.find(ns + "itemsPerPage").text == "25"
    rels = {link.get("rel"): link.get("href") for link in feed.findall(A + "link")}
    assert "next" in rels and "start-index=51" in rels["next"]
    assert len(feed.findall(A + "entry")) == 1


def test_query_href_encodes_values():
    href = atom.query_href(BASE, "/feeds/api/videos", q="a b&c=d")
    assert "a%20b%26c%3Dd" in href or "a+b%26c%3Dd" in href
    assert "&c=d" not in href


def test_channel_and_playlist_entries():
    c = roundtrip(atom.channel_entry(None, Channel(id="UCJZam2u1G0syq3kyqrCXrNw", title="PrestonPlayz",
                                                   subscribers=5), BASE, "tok"))
    assert c.find(A + "title").text == "PrestonPlayz"
    p = roundtrip(atom.playlist_entry(None, Playlist(id="PLabcdefghijk", title="Mix", count=3,
                                                     thumb_video_id="jNQXAC9IVRw"), BASE))
    assert p.find(A + "title").text == "Mix"


def test_categories_document_parses():
    assert ET.fromstring(atom.categories_doc()) is not None
