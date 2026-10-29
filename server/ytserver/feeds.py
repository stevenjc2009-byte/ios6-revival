"""GData v2 feed routes (/feeds/api/...) backed by InnerTube."""
from __future__ import annotations

import logging
import xml.etree.ElementTree as ET
from typing import Callable

from flask import Blueprint, Response, current_app, request

from . import atom, thumbs
from .config import Config
from .ids import clean_query, is_channel_id, is_playlist_id, is_username, is_video_id, paging
from .innertube import (CHANNEL_PLAYLISTS_PARAMS, CHANNEL_VIDEOS_PARAMS, SP_CHANNEL, InnerTube,
                        UpstreamError, search_params)
from .models import Page
from .streams import StreamManager

log = logging.getLogger("ytserver.feeds")
bp = Blueprint("feeds", __name__)
ATOM_TYPE = "application/atom+xml; charset=UTF-8"

POPULAR_QUERY = "popular videos"
CATEGORY_QUERIES = {
    "Film": "official movie trailer", "Autos": "cars", "Music": "official music video",
    "Animals": "cute animals", "Sports": "sports highlights", "Travel": "travel vlog",
    "Games": "gameplay", "Comedy": "comedy", "People": "vlog", "News": "news",
    "Entertainment": "entertainment", "Education": "educational", "Howto": "how to",
    "Nonprofit": "charity", "Tech": "technology review",
}
STANDARD_FEEDS = {"most_popular", "most_viewed", "top_rated", "recently_featured", "most_recent",
                  "most_discussed", "top_favorites", "most_shared", "on_the_web", "watch_on_mobile"}


class Svc:
    """Per-app singletons, kept on app.extensions['yts']."""

    def __init__(self, cfg: Config, it: InnerTube, streams: StreamManager, thumb_proxy: thumbs.ThumbProxy):
        self.cfg, self.it, self.streams, self.thumbs = cfg, it, streams, thumb_proxy


def svc() -> Svc:
    return current_app.extensions["yts"]


def base_url() -> str:
    cfg = svc().cfg
    return cfg.public_url or request.host_url.rstrip("/")


def xml_response(root: ET.Element | bytes, status: int = 200) -> Response:
    body = root if isinstance(root, bytes) else atom.serialize(root)
    return Response(body, status=status, mimetype="application/atom+xml", headers={
        "Content-Type": ATOM_TYPE, "Cache-Control": "no-cache"})


def fail(status: int, message: str) -> Response:
    return Response(message + "\n", status=status, mimetype="text/plain")


def _make_feed(title: str, path: str, page: Page, more: bool, start: int, count: int,
               params: dict | None = None, kind: str = "video") -> Response:
    base = base_url()
    items = getattr(page, {"video": "videos", "channel": "channels", "playlist": "playlists",
                           "comment": "comments"}[kind])
    window = items[start - 1:start - 1 + count]
    total = start - 1 + len(items[start - 1:]) + (count if more else 0)
    nxt = ""
    if more or len(items) > start - 1 + count:
        nxt = atom.query_href(base, path, **{**(params or {}), "start-index": start + count,
                                              "max-results": count, "v": 2})
    root = atom.feed(title, atom.query_href(base, path, **{**(params or {}), "start-index": start,
                                                           "max-results": count, "v": 2}),
                     base, total, start, len(window), nxt)
    for i, item in enumerate(window):
        if kind == "video":
            atom.video_entry(root, item, base, start + i)
        elif kind == "comment":
            atom.comment_entry(root, item, path.split("/")[-2], base)
        elif kind == "channel":
            atom.channel_entry(root, item, base, thumbs.encode_url(item.avatar))
        else:
            atom.playlist_entry(root, item, base)
    return xml_response(root)


def empty_feed(title: str = "Feed") -> Response:
    start, count = paging(request.args.get("start-index"), request.args.get("max-results"))
    return _make_feed(title, request.path, Page(), False, start, count)


def upstream_guard(fn: Callable) -> Callable:
    def wrapper(*args, **kwargs):
        try:
            return fn(*args, **kwargs)
        except UpstreamError as exc:
            log.warning("upstream failure: %s", exc)
            return fail(502, "upstream unavailable")

    wrapper.__name__ = fn.__name__
    return wrapper


def _want(start: int, count: int) -> int:
    return start - 1 + count + 1  # one extra so "more available" is detectable


# ------------------------------------------------------------------ search
@bp.get("/feeds/api/videos")
@upstream_guard
def search_videos():
    query = clean_query(request.args.get("q"))
    start, count = paging(request.args.get("start-index"), request.args.get("max-results"))
    if not query:
        return empty_feed("Search")
    sp = search_params(request.args.get("orderby", ""), request.args.get("time", ""),
                       request.args.get("duration", ""))
    page, more = svc().it.search(query, sp, _want(start, count))
    params = {k: request.args[k] for k in ("q", "orderby", "time", "duration") if k in request.args}
    params["q"] = query
    return _make_feed(f"Search: {query}", "/feeds/api/videos", page, more, start, count, params)


@bp.get("/feeds/api/channels")
@upstream_guard
def search_channels():
    query = clean_query(request.args.get("q"))
    start, count = paging(request.args.get("start-index"), request.args.get("max-results"))
    if not query:
        return empty_feed("Channels")
    page, more = svc().it.search(query, SP_CHANNEL, _want(start, count))
    return _make_feed(f"Channels: {query}", "/feeds/api/channels", page, more, start, count,
                      {"q": query}, "channel")


# ------------------------------------------------------------------ one video
@bp.get("/feeds/api/videos/<vid>")
@bp.get("/feeds/player/videos/<vid>")  # asked for when a youtube:// link opens the app
@upstream_guard
def video_entry(vid: str):
    if not is_video_id(vid):
        return fail(400, "bad video id")
    video = svc().it.video(vid)
    if video is None:
        return fail(404, "video not found")
    svc().streams.prefetch(vid)  # the app fetches this right before playing
    return xml_response(atom.video_entry(None, video, base_url()))


@bp.get("/feeds/api/videos/<vid>/related")
@upstream_guard
def related(vid: str):
    if not is_video_id(vid):
        return fail(400, "bad video id")
    start, count = paging(request.args.get("start-index"), request.args.get("max-results"))
    page, more = svc().it.related(vid, _want(start, count) + 1)
    page.videos = [v for v in page.videos if v.id != vid]
    return _make_feed("Related videos", f"/feeds/api/videos/{vid}/related", page, more, start, count)


@bp.get("/feeds/api/videos/<vid>/comments")
@upstream_guard
def video_comments(vid: str):
    if not is_video_id(vid):
        return fail(400, "bad video id")
    start, count = paging(request.args.get("start-index"), request.args.get("max-results"))
    page, more = svc().it.comments(vid, _want(start, count))
    return _make_feed("Comments", f"/feeds/api/videos/{vid}/comments", page, more, start, count,
                      kind="comment")


@bp.get("/feeds/api/videos/<vid>/<what>")
def video_sub(vid: str, what: str):
    """responses / captions / complaints: valid but empty."""
    if not is_video_id(vid):
        return fail(400, "bad video id")
    return empty_feed(what.capitalize())


# ------------------------------------------------------------------ standard feeds
def _standard_query(feed_name: str) -> str | None:
    if feed_name in STANDARD_FEEDS:
        return POPULAR_QUERY
    if feed_name.startswith("most_popular_"):
        return CATEGORY_QUERIES.get(feed_name[len("most_popular_"):])
    return None


@bp.get("/feeds/api/standardfeeds/<path:rest>")
@upstream_guard
def standard_feed(rest: str):
    parts = [p for p in rest.split("/") if p]
    if not parts or len(parts) > 2:
        return empty_feed("Feed")
    feed_name = parts[-1]
    query = _standard_query(feed_name)
    start, count = paging(request.args.get("start-index"), request.args.get("max-results"))
    if query is None:
        return empty_feed("Feed")
    sp = search_params("", "this_week" if feed_name != "most_viewed" else "this_month")
    page, more = svc().it.search(query, sp, _want(start, count))
    return _make_feed(feed_name.replace("_", " ").title(), f"/feeds/api/standardfeeds/{rest}",
                      page, more, start, count)


# ------------------------------------------------------------------ users / channels
def _resolve(name: str) -> str:
    if name in ("default", "me") or not (is_channel_id(name) or is_username(name)):
        return ""
    return svc().it.resolve_channel(name)


@bp.get("/feeds/api/users/<name>/uploads")
@upstream_guard
def user_uploads(name: str):
    start, count = paging(request.args.get("start-index"), request.args.get("max-results"))
    cid = _resolve(name)
    if not cid:
        return empty_feed("Uploads")
    chan = svc().it.channel(cid)
    author = chan.title if chan else ""
    page, more = svc().it.browse("VLUU" + cid[2:], "", _want(start, count), author)
    if not page.videos:
        page, more = svc().it.browse(cid, CHANNEL_VIDEOS_PARAMS, _want(start, count), author)
    for v in page.videos:
        v.channel_id = v.channel_id or cid
    return _make_feed(f"Uploads by {author}", f"/feeds/api/users/{name}/uploads", page, more, start, count)


@bp.get("/feeds/api/users/<name>/playlists")
@upstream_guard
def user_playlists(name: str):
    start, count = paging(request.args.get("start-index"), request.args.get("max-results"))
    cid = _resolve(name)
    if not cid:
        return empty_feed("Playlists")
    page, more = svc().it.browse(cid, CHANNEL_PLAYLISTS_PARAMS, _want(start, count))
    return _make_feed("Playlists", f"/feeds/api/users/{name}/playlists", page, more, start, count,
                      kind="playlist")


@bp.get("/feeds/api/users/<name>")
@bp.get("/feeds/api/channels/<name>")
@upstream_guard
def channel_info(name: str):
    cid = _resolve(name)
    chan = svc().it.channel(cid) if cid else None
    if chan is None:
        return fail(404, "channel not found")
    return xml_response(atom.channel_entry(None, chan, base_url(), thumbs.encode_url(chan.avatar)))


@bp.get("/feeds/api/playlists/<pid>")
@upstream_guard
def playlist_videos(pid: str):
    start, count = paging(request.args.get("start-index"), request.args.get("max-results"))
    if not is_playlist_id(pid):
        return fail(400, "bad playlist id")
    page, more = svc().it.browse("VL" + pid, "", _want(start, count))
    return _make_feed("Playlist", f"/feeds/api/playlists/{pid}", page, more, start, count)


@bp.get("/feeds/api/<path:rest>")
def other_feeds(rest: str):
    """Anything else the app polls (subscriptions, favorites, events, ...): signed-out = empty."""
    return empty_feed("Feed")


@bp.get("/schemas/2007/categories.cat")
def categories():
    return xml_response(atom.categories_doc())
