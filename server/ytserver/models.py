"""Plain data records produced by the InnerTube parser."""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime


@dataclass
class Video:
    id: str
    title: str = ""
    author: str = ""
    channel_id: str = ""
    duration: int = 0  # seconds
    views: int = 0
    published: datetime | None = None
    description: str = ""


@dataclass
class Channel:
    id: str
    title: str = ""
    description: str = ""
    subscribers: int = 0
    avatar: str = ""  # upstream URL, rewritten to /img/ by the XML layer
    handle: str = ""


@dataclass
class Playlist:
    id: str
    title: str = ""
    author: str = ""
    count: int = 0
    thumb_video_id: str = ""


@dataclass
class Comment:
    id: str
    text: str = ""
    author: str = ""
    channel_id: str = ""
    published: datetime | None = None
    likes: int = 0
    replies: int = 0


@dataclass
class Page:
    """One page of results plus the token for the next upstream page."""

    videos: list[Video] = field(default_factory=list)
    channels: list[Channel] = field(default_factory=list)
    playlists: list[Playlist] = field(default_factory=list)
    comments: list[Comment] = field(default_factory=list)
    token: str = ""
