"""GData v2 Atom builders.

Everything is built with xml.etree.ElementTree, never by string concatenation,
so untrusted upstream text can only ever become escaped text or attribute
values.  Characters that are illegal in XML 1.0 are stripped first because
ElementTree would happily emit them and the iOS parser would then reject the
whole feed.

The element set follows what the 2012-era YouTube app receives from the real
GData v2 API (and what TubeRepair's templates, which the app is known to
accept, contain): media:group with thumbnails and several media:content
formats, yt:statistics, gd:rating, yt:accessControl, openSearch totals.
"""
from __future__ import annotations

import io
import re
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from urllib.parse import urlencode

from .models import Channel, Comment, Playlist, Video

NS = {
    "atom": "http://www.w3.org/2005/Atom",
    "media": "http://search.yahoo.com/mrss/",
    "openSearch": "http://a9.com/-/spec/opensearch/1.1/",
    "gd": "http://schemas.google.com/g/2005",
    "yt": "http://gdata.youtube.com/schemas/2007",
    "app": "http://www.w3.org/2007/app",
}
YT = NS["yt"]
KIND = "http://schemas.google.com/g/2005#kind"
CATEGORY_SCHEME = YT + "/categories.cat"
for _p, _u in NS.items():
    # Atom is the default namespace; ElementTree's default_namespace option
    # rejects unqualified attributes (href=, rel=), so register it as prefix ''.
    ET.register_namespace("" if _p == "atom" else _p, _u)

_BAD_XML = re.compile("[^\u0009\u000a\u000d -퟿-�\U00010000-\U0010ffff]")
EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)

# yt:format ids the app may ask for; 5 is Flash and is pointed at youtube.com
# like the real API did, 1/6 are the 3GP slots, the rest are MP4 slots.
MP4_FORMATS = (3, 8, 2, 9)
THREEGP_FORMATS = (1, 6)


def clean(text: object) -> str:
    return _BAD_XML.sub("", str(text if text is not None else ""))


def _qn(name: str) -> str:
    prefix, _, local = name.rpartition(":")
    return "{%s}%s" % (NS[prefix or "atom"], local)


def el(parent: ET.Element | None, name: str, text: object = None, **attrs: object) -> ET.Element:
    """Create <name> (optionally under parent). Attribute 'yt_format' -> yt:format."""
    node = ET.Element(_qn(name)) if parent is None else ET.SubElement(parent, _qn(name))
    for key, val in attrs.items():
        pfx, sep, local = key.partition("_")
        attr = _qn(f"{pfx}:{local}") if sep and pfx in NS and pfx != "atom" else key
        node.set(attr, clean(val))
    if text is not None:
        node.text = clean(text)
    return node


def iso(dt: datetime | None) -> str:
    dt = dt or EPOCH
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def serialize(root: ET.Element) -> bytes:
    buf = io.BytesIO()
    ET.ElementTree(root).write(buf, encoding="utf-8", xml_declaration=True)
    return buf.getvalue()


def thumb_url(base: str, video_id: str, name: str) -> str:
    return f"{base}/vi/{video_id}/{name}.jpg"


def img_url(base: str, token: str) -> str:
    return f"{base}/img/{token}.jpg"


# ---------------------------------------------------------------- entries
def video_entry(parent: ET.Element | None, v: Video, base: str, position: int = 0) -> ET.Element:
    entry = el(parent, "atom:entry", gd_etag=f'W/"{v.id}"')
    when = iso(v.published)
    stream = f"{base}/stream/{v.id}.mp4"
    uploader = v.channel_id or "UC"
    el(entry, "atom:id", f"tag:youtube.com,2008:video:{v.id}")
    el(entry, "atom:published", when)
    el(entry, "atom:updated", when)
    el(entry, "atom:category", scheme=KIND, term=YT + "#video")
    el(entry, "atom:category", scheme=CATEGORY_SCHEME, term="Entertainment", label="Entertainment")
    el(entry, "atom:title", v.title, type="text")
    el(entry, "atom:content", type="video/mp4", src=stream)
    el(entry, "atom:link", rel="alternate", type="text/html",
       href=f"https://www.youtube.com/watch?v={v.id}&feature=youtube_gdata")
    el(entry, "atom:link", rel=YT + "#video.related", type="application/atom+xml",
       href=f"{base}/feeds/api/videos/{v.id}/related?v=2")
    el(entry, "atom:link", rel=YT + "#mobile", type="text/html", href=f"https://m.youtube.com/details?v={v.id}")
    el(entry, "atom:link", rel=YT + "#uploader", type="application/atom+xml",
       href=f"{base}/feeds/api/users/{uploader}?v=2")
    el(entry, "atom:link", rel="related", type="application/atom+xml", href=f"{base}/feeds/api/videos/{v.id}?v=2")
    el(entry, "atom:link", rel="self", type="application/atom+xml", href=f"{base}/feeds/api/videos/{v.id}?v=2")
    author = el(entry, "atom:author")
    el(author, "atom:name", v.author)
    el(author, "atom:uri", f"{base}/feeds/api/users/{uploader}")
    el(author, "yt:userId", uploader)
    for action, perm in (("comment", "allowed"), ("commentVote", "denied"), ("videoRespond", "denied"),
                         ("rate", "denied"), ("embed", "allowed"), ("list", "allowed"),
                         ("autoPlay", "allowed"), ("syndicate", "allowed")):
        el(entry, "yt:accessControl", action=action, permission=perm)
    comments = el(entry, "gd:comments")
    el(comments, "gd:feedLink", rel=YT + "#comments", href=f"{base}/feeds/api/videos/{v.id}/comments?v=2",
       countHint="0")
    group = el(entry, "media:group")
    el(group, "media:category", "Entertainment", label="Entertainment", scheme=CATEGORY_SCHEME)
    el(group, "media:content", url=f"https://www.youtube.com/v/{v.id}?version=3&f=playlists&app=youtube_gdata",
       type="application/x-shockwave-flash", medium="video", isDefault="true", expression="full",
       duration=v.duration, yt_format=5)
    for fmt in THREEGP_FORMATS:
        el(group, "media:content", url=stream, type="video/3gpp", medium="video", expression="full",
           duration=v.duration, yt_format=fmt)
    for fmt in MP4_FORMATS:
        extra = {"isDefault": "true"} if fmt == 3 else {}
        el(group, "media:content", url=stream, type="video/mp4", medium="video", expression="full",
           duration=v.duration, yt_format=fmt, **extra)
    el(group, "media:credit", v.author, role="uploader", scheme="urn:youtube", yt_display=v.author)
    el(group, "media:description", v.description, type="plain")
    el(group, "media:keywords")
    el(group, "media:license", "youtube", type="text/html", href="https://www.youtube.com/t/terms")
    el(group, "media:player", url=f"https://www.youtube.com/watch?v={v.id}&feature=youtube_gdata_player")
    for name, w, h in (("default", 120, 90), ("mqdefault", 320, 180), ("hqdefault", 480, 360)):
        el(group, "media:thumbnail", url=thumb_url(base, v.id, name), height=h, width=w, yt_name=name)
    for name in ("start", "middle", "end"):
        el(group, "media:thumbnail", url=thumb_url(base, v.id, "default"), height=90, width=120,
           time="00:00:00.000", yt_name=name)
    el(group, "media:title", v.title, type="plain")
    el(group, "yt:aspectRatio", "widescreen")
    el(group, "yt:duration", seconds=v.duration)
    el(group, "yt:uploaded", when)
    el(group, "yt:uploaderId", uploader)
    el(group, "yt:videoid", v.id)
    el(entry, "gd:rating", average="0", max="5", min="1", numRaters="0", rel="http://schemas.google.com/g/2005#overall")
    el(entry, "yt:statistics", favoriteCount="0", viewCount=v.views)
    el(entry, "yt:rating", numDislikes="0", numLikes="0")
    if position:
        el(entry, "yt:position", position)
    return entry


def channel_entry(parent: ET.Element | None, c: Channel, base: str, avatar_token: str = "") -> ET.Element:
    entry = el(parent, "atom:entry", gd_etag=f'W/"{c.id}"')
    el(entry, "atom:id", f"tag:youtube.com,2008:channel:{c.id}")
    el(entry, "atom:updated", iso(None))
    el(entry, "atom:category", scheme=KIND, term=YT + "#channel")
    el(entry, "atom:title", c.title, type="text")
    el(entry, "atom:summary", c.description, type="text")
    el(entry, "atom:link", rel="alternate", type="text/html", href=f"https://www.youtube.com/channel/{c.id}")
    el(entry, "atom:link", rel="self", type="application/atom+xml", href=f"{base}/feeds/api/channels/{c.id}?v=2")
    author = el(entry, "atom:author")
    el(author, "atom:name", c.title)
    el(author, "atom:uri", f"{base}/feeds/api/users/{c.id}")
    el(author, "yt:userId", c.id)
    el(entry, "yt:channelId", c.id)
    el(entry, "yt:username", c.handle.lstrip("@") or c.id)
    el(entry, "yt:channelStatistics", subscriberCount=c.subscribers, viewCount="0")
    el(entry, "gd:feedLink", rel=YT + "#user.uploads", href=f"{base}/feeds/api/users/{c.id}/uploads?v=2",
       countHint="0")
    if avatar_token:
        el(entry, "media:thumbnail", url=img_url(base, avatar_token))
    return entry


def playlist_entry(parent: ET.Element | None, p: Playlist, base: str) -> ET.Element:
    entry = el(parent, "atom:entry", gd_etag=f'W/"{p.id}"')
    el(entry, "atom:id", f"tag:youtube.com,2008:playlist:{p.id}")
    el(entry, "atom:published", iso(None))
    el(entry, "atom:updated", iso(None))
    el(entry, "atom:category", scheme=KIND, term=YT + "#playlistLink")
    el(entry, "atom:title", p.title, type="text")
    el(entry, "atom:summary", "")
    el(entry, "atom:content", type="application/atom+xml;type=feed",
       src=f"{base}/feeds/api/playlists/{p.id}?v=2")
    el(entry, "atom:link", rel="self", type="application/atom+xml", href=f"{base}/feeds/api/playlists/{p.id}?v=2")
    author = el(entry, "atom:author")
    el(author, "atom:name", p.author)
    el(author, "atom:uri", f"{base}/feeds/api/users/UC")
    el(entry, "yt:playlistId", p.id)
    el(entry, "yt:countHint", p.count)
    if p.thumb_video_id:
        el(entry, "media:group").append(_thumb(base, p.thumb_video_id))
    return entry


def comment_entry(parent: ET.Element | None, c: Comment, video_id: str, base: str) -> ET.Element:
    """One GData v2 comment (top level only; the app has no reply threads)."""
    entry = el(parent, "atom:entry", gd_etag=f'W/"{c.id}"')
    when = iso(c.published)
    author_id = c.channel_id or "UC"
    el(entry, "atom:id", f"tag:youtube.com,2008:video:{video_id}:comment:{c.id}")
    el(entry, "atom:published", when)
    el(entry, "atom:updated", when)
    el(entry, "atom:category", scheme=KIND, term=YT + "#comment")
    el(entry, "atom:title", " ".join(c.text.split())[:60], type="text")
    el(entry, "atom:content", c.text, type="text")
    el(entry, "atom:link", rel="related", type="application/atom+xml", href=f"{base}/feeds/api/videos/{video_id}?v=2")
    el(entry, "atom:link", rel="alternate", type="text/html",
       href=f"https://www.youtube.com/watch?v={video_id}&lc={c.id}")
    el(entry, "atom:link", rel="self", type="application/atom+xml",
       href=f"{base}/feeds/api/videos/{video_id}/comments/{c.id}?v=2")
    author = el(entry, "atom:author")
    el(author, "atom:name", c.author)
    el(author, "atom:uri", f"{base}/feeds/api/users/{author_id}")
    el(author, "yt:userId", author_id)
    el(entry, "yt:channelId", author_id)
    el(entry, "yt:replyCount", c.replies)
    el(entry, "yt:videoid", video_id)
    el(entry, "gd:rating", average=5, max=5, min=1, numRaters=c.likes, rel="http://schemas.google.com/g/2005#overall")
    return entry


def _thumb(base: str, video_id: str) -> ET.Element:
    return el(None, "media:thumbnail", url=thumb_url(base, video_id, "mqdefault"), height=180, width=320,
              yt_name="mqdefault")


# ---------------------------------------------------------------- feeds
def feed(title: str, self_href: str, base: str, total: int, start: int, per_page: int,
         next_href: str = "", feed_id: str = "tag:youtube.com,2008:feed") -> ET.Element:
    root = el(None, "atom:feed", gd_etag='W/"feed"')
    el(root, "atom:id", feed_id)
    el(root, "atom:updated", iso(datetime.now(timezone.utc)))
    el(root, "atom:category", scheme=KIND, term=YT + "#video")
    el(root, "atom:title", title, type="text")
    el(root, "atom:logo", "http://www.gstatic.com/youtube/img/logo.png")
    el(root, "atom:link", rel="self", type="application/atom+xml", href=self_href)
    if next_href:
        el(root, "atom:link", rel="next", type="application/atom+xml", href=next_href)
    author = el(root, "atom:author")
    el(author, "atom:name", "YouTube")
    el(author, "atom:uri", "http://www.youtube.com/")
    el(root, "atom:generator", "YouTube data API", version="2.1", uri=base + "/")
    el(root, "openSearch:totalResults", total)
    el(root, "openSearch:startIndex", start)
    el(root, "openSearch:itemsPerPage", per_page)
    return root


def query_href(base: str, path: str, **params: object) -> str:
    clean_params = {k: v for k, v in params.items() if v not in (None, "")}
    return f"{base}{path}?{urlencode(clean_params)}" if clean_params else f"{base}{path}"


def categories_doc() -> bytes:
    root = ET.Element("{%s}categories" % NS["app"], {"fixed": "yes", "scheme": CATEGORY_SCHEME})
    for term, label in (("Film", "Film & Animation"), ("Autos", "Autos & Vehicles"), ("Music", "Music"),
                        ("Animals", "Pets & Animals"), ("Sports", "Sports"), ("Travel", "Travel & Events"),
                        ("Games", "Gaming"), ("Comedy", "Comedy"), ("People", "People & Blogs"),
                        ("News", "News & Politics"), ("Entertainment", "Entertainment"),
                        ("Education", "Education"), ("Howto", "Howto & Style"),
                        ("Nonprofit", "Nonprofits & Activism"), ("Tech", "Science & Technology")):
        cat = ET.SubElement(root, _qn("atom:category"), {"term": term, "label": label})
        ET.SubElement(cat, _qn("yt:assignable"))
        ET.SubElement(cat, _qn("yt:browsable"), {"regions": "US GB CA AU"})
    return serialize(root)
