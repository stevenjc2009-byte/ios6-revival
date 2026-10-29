"""Video comments from InnerTube, for the app's Comments tab.

The watch page ("next") carries a token for the comments section; following
it returns pages of commentThreadRenderer items (the order to show) whose
text, author and counts live separately in frameworkUpdates mutations as
commentEntityPayload, keyed by commentId. Only top-level comments are
listed: GData v2 had no reply threads.
"""
from __future__ import annotations

from typing import Any

from .models import Comment, Page
from .parse import _command_token, continuation_token, parse_age, parse_count, walk


def comments_token(watch_doc: Any) -> str:
    """Token of the watch page's comments section ('' when comments are off)."""
    for key, val in walk(watch_doc):
        if key == "itemSectionRenderer" and isinstance(val, dict) \
                and "comment" in str(val.get("sectionIdentifier", "")):
            return continuation_token(val)
    return ""


def _order(doc: Any) -> list[str]:
    ids = []
    for key, val in walk(doc):
        if key == "commentThreadRenderer" and isinstance(val, dict):
            vm = val.get("commentViewModel", {}).get("commentViewModel", {})
            cid = vm.get("commentId")
            if isinstance(cid, str) and cid not in ids:
                ids.append(cid)
    return ids


def _next_token(doc: Any) -> str:
    """Token ending the list of comment threads ('' on the last page). Each thread's
    replies list ends in a token too; those fetch replies, not the next page."""
    for _, val in walk(doc):
        if isinstance(val, list) and val and isinstance(val[-1], dict)                 and "continuationItemRenderer" in val[-1]                 and any(isinstance(v, dict) and "commentThreadRenderer" in v for v in val):
            return _command_token(val[-1])
    return ""


def _comment(payload: dict) -> Comment | None:
    props = payload.get("properties") or {}
    cid = props.get("commentId")
    if not isinstance(cid, str) or props.get("replyLevel", 0):
        return None
    author = payload.get("author") or {}
    toolbar = payload.get("toolbar") or {}
    return Comment(
        id=cid,
        text=str((props.get("content") or {}).get("content", "")),
        author=str(author.get("displayName", "")),
        channel_id=str(author.get("channelId", "")),
        published=parse_age(str(props.get("publishedTime", ""))),
        likes=parse_count(str(toolbar.get("likeCountNotliked", ""))),
        replies=parse_count(str(toolbar.get("replyCount", ""))),
    )


def extract(doc: Any, default_author: str = "") -> Page:
    """One comments page; default_author is unused (same signature as parse.extract)."""
    by_id = {}
    for key, val in walk(doc):
        if key == "commentEntityPayload" and isinstance(val, dict):
            c = _comment(val)
            if c:
                by_id[c.id] = c
    order = _order(doc) or list(by_id)
    return Page(comments=[by_id[i] for i in order if i in by_id], token=_next_token(doc))
