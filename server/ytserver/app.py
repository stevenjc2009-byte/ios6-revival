"""Flask application factory, request logging."""
from __future__ import annotations

import logging
import sys
import time

from flask import Flask, Response, g, request

from . import config, feeds, media
from .config import Config
from .innertube import InnerTube
from .streams import StreamManager
from .thumbs import ThumbProxy

log = logging.getLogger("ytserver")


def create_app(cfg: Config | None = None, *, innertube: InnerTube | None = None,
               streams: StreamManager | None = None, thumb_proxy: ThumbProxy | None = None) -> Flask:
    cfg = cfg or config.load()
    app = Flask(__name__)
    app.url_map.strict_slashes = False
    app.extensions["yts"] = feeds.Svc(
        cfg,
        innertube or InnerTube(cfg.meta_ttl),
        streams or StreamManager(cfg),
        thumb_proxy or ThumbProxy(),
    )
    app.register_blueprint(media.bp)
    app.register_blueprint(feeds.bp)

    @app.before_request
    def _start() -> None:
        g.t0 = time.perf_counter()

    @app.after_request
    def _log(resp: Response) -> Response:
        ms = (time.perf_counter() - g.get("t0", time.perf_counter())) * 1000
        resp.headers.setdefault("X-Content-Type-Options", "nosniff")
        # path only: query strings carry search terms, never log upstream URLs
        log.info("%s %s %d %.0fms", request.method, request.path[:120], resp.status_code, ms)
        return resp

    @app.errorhandler(404)
    def _nf(_e):
        return Response("not found\n", status=404, mimetype="text/plain")

    @app.errorhandler(405)
    def _na(_e):
        return Response("method not allowed\n", status=405, mimetype="text/plain")

    @app.errorhandler(Exception)
    def _boom(exc: Exception):
        log.exception("unhandled %s", type(exc).__name__)
        return Response("internal error\n", status=500, mimetype="text/plain")

    return app


def setup_logging() -> None:
    logging.basicConfig(stream=sys.stdout, level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("waitress").setLevel(logging.WARNING)
