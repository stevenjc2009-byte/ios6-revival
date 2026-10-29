"""Playback, thumbnail, health and fake-login routes."""
from __future__ import annotations

import logging
import secrets

from flask import Blueprint, Response, current_app, request, send_file

from .feeds import fail, svc
from .ids import is_video_id
from .streams import StreamError, StreamPending

log = logging.getLogger("ytserver.media")
bp = Blueprint("media", __name__)
_DEVICE_KEY = secrets.token_hex(16)


def sniff_image(data: bytes) -> str | None:
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if data[:4] == b"GIF8":
        return "image/gif"
    return None  # WebP etc. cannot be shown by iOS 6


@bp.get("/healthz")
def healthz():
    return Response("ok", mimetype="text/plain")


@bp.get("/")
def index():
    return Response("ytserver: YouTube GData v2 translation server\n", mimetype="text/plain")


@bp.route("/stream/<name>", methods=["GET", "HEAD"])
@bp.route("/getvideo/<name>", methods=["GET", "HEAD"])
def stream(name: str):
    vid = name[:-4] if name.endswith(".mp4") else name
    if not is_video_id(vid):
        return fail(400, "bad video id")
    manager = svc().streams
    try:
        path = manager.get(vid, svc().cfg.stream_wait)
    except StreamPending:
        resp = fail(503, "still preparing this video, retry shortly")
        resp.headers["Retry-After"] = "5"
        return resp
    except StreamError as exc:
        log.warning("stream %s unavailable: %s", vid, exc)
        return fail(502, "video unavailable")
    manager.hold(path, 1)
    # conditional=True: werkzeug answers Range / If-Range with 206 + Content-Range.
    resp = send_file(path, mimetype="video/mp4", conditional=True, etag=True, max_age=0)
    resp.headers["Accept-Ranges"] = "bytes"
    resp.call_on_close(lambda: manager.hold(path, -1))
    return resp


def _image_response(data: bytes | None) -> Response:
    mime = sniff_image(data) if data else None
    if not data or not mime:
        return fail(404, "image unavailable")
    return Response(data, mimetype=mime, headers={"Cache-Control": "public, max-age=86400"})


@bp.get("/vi/<vid>/<name>.jpg")
def video_thumb(vid: str, name: str):
    return _image_response(svc().thumbs.video_thumb(vid, name))


@bp.get("/img/<token>.jpg")
def avatar(token: str):
    return _image_response(svc().thumbs.image(token))


# ---- fake sign-in: the app insists on a device registration before it works
@bp.post("/youtube/accounts/registerDevice")
def register_device():
    return Response(f"DeviceId={_DEVICE_KEY}\nDeviceKey={_DEVICE_KEY}\n", mimetype="text/plain")


@bp.post("/youtube/accounts/applelogin1")
def apple_login1():
    return Response(f"r2={_DEVICE_KEY}\nhmackr2={_DEVICE_KEY}\n", mimetype="text/plain")


@bp.post("/youtube/accounts/applelogin2")
def apple_login2():
    return Response(f"Auth={_DEVICE_KEY}\n", mimetype="text/plain")


@bp.post("/accounts/ClientLogin")
def client_login():
    return Response(f"SID={_DEVICE_KEY}\nLSID={_DEVICE_KEY}\nAuth={_DEVICE_KEY}\n", mimetype="text/plain")
