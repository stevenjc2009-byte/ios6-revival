"""Tolerant extraction of videos/channels/playlists from InnerTube JSON.

YouTube renames and reshuffles renderers constantly, so nothing here depends on
the position of an item in the tree: we walk the whole document and parse every
renderer we recognise.  All upstream data is untrusted; every value is coerced
to a plain str/int before it leaves this module.
"""
from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone
from typing import Any, Iterator

from .ids import is_channel_id, is_playlist_id, is_video_id
from .models import Channel, Page, Playlist, Video

_VIDEO_KEYS = ("videoRenderer", "gridVideoRenderer", "compactVideoRenderer", "playlistVideoRenderer")
_CHANNEL_KEYS = ("channelRenderer", "gridChannelRenderer")
_PLAYLIST_KEYS = ("playlistRenderer", "gridPlaylistRenderer", "compactPlaylistRenderer")


def walk(node: Any) -> Iterator[tuple[str, Any]]:
    """Yield every (key, value) pair in the tree, depth first."""
    stack = [node]
    while stack:
        cur = stack.pop()
        if isinstance(cur, dict):
            for key, val in cur.items():
                yield key, val
                if isinstance(val, (dict, list)):
                    stack.append(val)
        elif isinstance(cur, list):
            stack.extend(v for v in cur if isinstance(v, (dict, list)))


def text_of(node: Any) -> str:
    """Flatten simpleText / runs / content nodes to a str."""
    if isinstance(node, str):
        return node
    if isinstance(node, dict):
        if isinstance(node.get("simpleText"), str):
            return node["simpleText"]
        if isinstance(node.get("content"), str):
            return node["content"]
        runs = node.get("runs")
        if isinstance(runs, list):
            return "".join(r.get("text", "") for r in runs if isinstance(r, dict))
    return ""


def parse_duration(label: str) -> int:
    """'1:02:03' -> 3723, '19:53' -> 1193; anything else (LIVE) -> 0."""
    parts = label.strip().split(":")
    if not 1 < len(parts) <= 3 or not all(p.isdigit() for p in parts):
        return 0
    total = 0
    for part in parts:
        total = total * 60 + int(part)
    return total


_COUNT_RE = re.compile(r"([\d][\d,\.]*)\s*([KMB])?", re.I)
_MULT = {"K": 1_000, "M": 1_000_000, "B": 1_000_000_000}


def parse_count(label: str) -> int:
    """'7,156,996 views' -> 7156996, '1.2M subscribers' -> 1200000."""
    match = _COUNT_RE.search(label or "")
    if not match:
        return 0
    num = match.group(1).replace(",", "")
    try:
        value = float(num)
    except ValueError:
        return 0
    return int(value * _MULT.get((match.group(2) or "").upper(), 1))


_AGE_RE = re.compile(r"(\d+)\s+(second|minute|hour|day|week|month|year)s?\s+ago", re.I)
_AGE_SECONDS = {"second": 1, "minute": 60, "hour": 3600, "day": 86400,
                "week": 604800, "month": 2_592_000, "year": 31_536_000}


def parse_age(label: str, now: datetime | None = None) -> datetime | None:
    """'1 month ago' -> an approximate UTC timestamp (YouTube gives no exact date)."""
    match = _AGE_RE.search(label or "")
    if not match:
        return None
    now = now or datetime.now(timezone.utc)
    secs = int(match.group(1)) * _AGE_SECONDS[match.group(2).lower()]
    return now - timedelta(seconds=min(secs, 60 * 31_536_000))


def _first_browse_id(node: Any) -> str:
    for key, val in walk(node):
        if key == "browseId" and isinstance(val, str) and is_channel_id(val):
            return val
    return ""


def _url(raw: Any) -> str:
    raw = raw if isinstance(raw, str) else ""
    if raw.startswith("//"):
        raw = "https:" + raw
    return raw if raw.startswith("https://") else ""


def _thumb_url(node: Any) -> str:
    thumbs = (node or {}).get("thumbnails") if isinstance(node, dict) else None
    if isinstance(thumbs, list) and thumbs and isinstance(thumbs[0], dict):
        return _url(thumbs[0].get("url"))
    return ""


def _video_from_renderer(r: dict) -> Video | None:
    vid = r.get("videoId")
    if not is_video_id(vid):
        return None
    byline = r.get("ownerText") or r.get("longBylineText") or r.get("shortBylineText") or {}
    desc = ""
    snippets = r.get("detailedMetadataSnippets")
    if isinstance(snippets, list) and snippets and isinstance(snippets[0], dict):
        desc = text_of(snippets[0].get("snippetText"))
    desc = desc or text_of(r.get("descriptionSnippet"))
    views = text_of(r.get("viewCountText")) or text_of(r.get("shortViewCountText"))
    return Video(
        id=vid,
        title=text_of(r.get("title")),
        author=text_of(byline),
        channel_id=_first_browse_id(byline),
        duration=parse_duration(text_of(r.get("lengthText"))),
        views=parse_count(views) if "view" in views.lower() else 0,
        published=parse_age(text_of(r.get("publishedTimeText"))),
        description=desc,
    )


def _lockup_parts(lockup: dict) -> list[tuple[str, str]]:
    """(text, accessibilityLabel) of every metadata part of a lockupViewModel, in order."""
    out: list[tuple[str, str]] = []
    meta = (lockup.get("metadata") or {}).get("lockupMetadataViewModel") or {}
    rows = ((meta.get("metadata") or {}).get("contentMetadataViewModel") or {}).get("metadataRows")
    for row in rows if isinstance(rows, list) else []:
        for part in (row or {}).get("metadataParts") or []:
            if isinstance(part, dict):
                label = part.get("accessibilityLabel")
                out.append((text_of(part.get("text")), label if isinstance(label, str) else ""))
    return out


def _lockup_texts(lockup: dict) -> list[str]:
    return [text for text, _label in _lockup_parts(lockup)]


def _lockup_duration(lockup: dict) -> int:
    for key, val in walk(lockup.get("contentImage")):
        if key == "text" and isinstance(val, str) and parse_duration(val):
            return parse_duration(val)
    return 0


def _video_from_lockup(lockup: dict, default_author: str) -> Video | None:
    vid = lockup.get("contentId")
    if not is_video_id(vid):
        return None
    meta = (lockup.get("metadata") or {}).get("lockupMetadataViewModel") or {}
    parts = _lockup_parts(lockup)
    views = next((t for t, label in parts if re.search(r"\bviews?\b", t + " " + label, re.I)), "")
    age = next((label or t for t, label in parts if _AGE_RE.search(label or t)), "")
    author = ""
    if parts and parts[0][0] and not re.search(r"\bviews?\b|\bago\b", parts[0][0] + " " + parts[0][1], re.I):
        author = parts[0][0]
    return Video(
        id=vid,
        title=text_of(meta.get("title")),
        author=author or default_author,
        channel_id=_first_browse_id(meta.get("image")),
        duration=_lockup_duration(lockup),
        views=parse_count(views),
        published=parse_age(age),
    )


def _channel_from_renderer(r: dict) -> Channel | None:
    cid = r.get("channelId")
    if not is_channel_id(cid):
        return None
    subs = text_of(r.get("subscriberCountText")) or text_of(r.get("videoCountText"))
    handle = ""
    for label in (text_of(r.get("subscriberCountText")), text_of(r.get("longBylineText"))):
        if label.startswith("@"):
            handle = label
    return Channel(
        id=cid,
        title=text_of(r.get("title")),
        description=text_of(r.get("descriptionSnippet")),
        subscribers=parse_count(subs) if "subscriber" in subs.lower() else 0,
        avatar=_thumb_url(r.get("thumbnail")),
        handle=handle,
    )


def _playlist_from_renderer(r: dict) -> Playlist | None:
    pid = r.get("playlistId")
    if not is_playlist_id(pid):
        return None
    thumbs = r.get("thumbnails")
    thumb_vid = ""
    for _key, val in walk(thumbs if thumbs else r.get("thumbnail")):
        if isinstance(val, str):
            m = re.search(r"/vi/([A-Za-z0-9_-]{11})/", val)
            if m:
                thumb_vid = m.group(1)
                break
    count = r.get("videoCount") or text_of(r.get("videoCountText"))
    return Playlist(
        id=pid,
        title=text_of(r.get("title")),
        author=text_of(r.get("longBylineText") or r.get("shortBylineText")),
        count=parse_count(str(count)),
        thumb_video_id=thumb_vid,
    )


def _playlist_from_lockup(lockup: dict) -> Playlist | None:
    pid = lockup.get("contentId")
    if not is_playlist_id(pid):
        return None
    meta = (lockup.get("metadata") or {}).get("lockupMetadataViewModel") or {}
    thumb_vid = ""
    for _key, val in walk(lockup.get("contentImage")):
        if isinstance(val, str):
            m = re.search(r"/vi/([A-Za-z0-9_-]{11})/", val)
            if m:
                thumb_vid = m.group(1)
                break
    count = 0
    for _key, val in walk(lockup.get("contentImage")):
        if _key == "text" and isinstance(val, str) and re.search(r"video", val, re.I):
            count = parse_count(val)
            break
    texts = _lockup_texts(lockup)
    return Playlist(id=pid, title=text_of(meta.get("title")),
                    author=texts[0] if texts else "", count=count, thumb_video_id=thumb_vid)


def _channel_from_lockup(lockup: dict) -> Channel | None:
    cid = lockup.get("contentId")
    if not is_channel_id(cid):
        return None
    meta = (lockup.get("metadata") or {}).get("lockupMetadataViewModel") or {}
    texts = _lockup_texts(lockup)
    subs = next((t for t in texts if "subscriber" in t.lower()), "")
    avatar = ""
    for key, val in walk(meta.get("image")):
        if key == "url" and _url(val):
            avatar = _url(val)
            break
    return Channel(id=cid, title=text_of(meta.get("title")), subscribers=parse_count(subs),
                   avatar=avatar, handle=next((t for t in texts if t.startswith("@")), ""))


def continuation_token(doc: Any) -> str:
    """First continuation token in the document ('' when there is none)."""
    for key, val in walk(doc):
        if key == "continuationCommand" and isinstance(val, dict):
            token = val.get("token")
            if isinstance(token, str) and token:
                return token
    return ""


def extract(doc: Any, default_author: str = "") -> Page:
    """Pull every video, channel and playlist out of an InnerTube response."""
    page = Page(token=continuation_token(doc))
    seen: set[tuple[str, str]] = set()

    def add(kind: str, item: Any, bucket: list) -> None:
        if item is not None and (kind, item.id) not in seen:
            seen.add((kind, item.id))
            bucket.append(item)

    for key, val in walk(doc):
        if not isinstance(val, dict):
            continue
        if key in _VIDEO_KEYS:
            add("v", _video_from_renderer(val), page.videos)
        elif key in _CHANNEL_KEYS:
            add("c", _channel_from_renderer(val), page.channels)
        elif key in _PLAYLIST_KEYS:
            add("p", _playlist_from_renderer(val), page.playlists)
        elif key == "lockupViewModel":
            ctype = str(val.get("contentType", ""))
            if ctype.endswith("VIDEO"):
                add("v", _video_from_lockup(val, default_author), page.videos)
            elif ctype.endswith("PLAYLIST") or ctype.endswith("PODCAST"):
                add("p", _playlist_from_lockup(val), page.playlists)
            elif ctype.endswith("CHANNEL"):
                add("c", _channel_from_lockup(val), page.channels)
    # the walk is depth-first from a stack, so restore document order
    return page


def channel_header(doc: Any, channel_id: str = "") -> Channel | None:
    """Channel details from a /browse response."""
    meta = None
    for key, val in walk(doc):
        if key == "channelMetadataRenderer" and isinstance(val, dict):
            meta = val
            break
    if meta is None:
        return None
    cid = meta.get("externalId") if is_channel_id(meta.get("externalId")) else channel_id
    if not is_channel_id(cid):
        return None
    subs = 0
    for key, val in walk(doc):
        if key == "content" and isinstance(val, str) and re.search(r"subscribers?\b", val, re.I):
            subs = parse_count(val)
            break
    handle = ""
    url = meta.get("vanityChannelUrl") or ""
    if isinstance(url, str) and "/@" in url:
        handle = "@" + url.rsplit("/@", 1)[1]
    return Channel(id=cid, title=str(meta.get("title", "")), description=str(meta.get("description", "")),
                   subscribers=subs, avatar=_thumb_url(meta.get("avatar")), handle=handle)


def video_from_player(doc: Any) -> Video | None:
    """Video details from a /player response (present even when unplayable)."""
    det = doc.get("videoDetails") if isinstance(doc, dict) else None
    if not isinstance(det, dict) or not is_video_id(det.get("videoId")):
        return None

    def num(v: Any) -> int:
        return int(v) if isinstance(v, str) and v.isdigit() else 0

    published = None
    micro = ((doc.get("microformat") or {}).get("playerMicroformatRenderer") or {})
    raw_date = micro.get("publishDate") or micro.get("uploadDate")
    if isinstance(raw_date, str):
        try:
            published = datetime.fromisoformat(raw_date)
            if published.tzinfo is None:
                published = published.replace(tzinfo=timezone.utc)
        except ValueError:
            published = None

    return Video(
        id=det["videoId"],
        title=str(det.get("title", "")),
        author=str(det.get("author", "")),
        channel_id=det["channelId"] if is_channel_id(det.get("channelId")) else "",
        duration=num(det.get("lengthSeconds")),
        views=num(det.get("viewCount")),
        published=published,
        description=str(det.get("shortDescription", "")),
    )


def resolve_browse_id(doc: Any) -> str:
    """Channel id from a navigation/resolve_url response."""
    for key, val in walk(doc):
        if key == "browseId" and isinstance(val, str) and is_channel_id(val):
            return val
    return ""
