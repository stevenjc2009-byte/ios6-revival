"""python -m ytserver"""
from __future__ import annotations

import logging
import shutil

from waitress import serve

from . import config
from .app import create_app, setup_logging


def main() -> None:
    setup_logging()
    cfg = config.load()
    log = logging.getLogger("ytserver")
    for tool in ("ffmpeg", "ffprobe", "deno"):
        if not shutil.which(tool):
            log.warning("%s not found on PATH", tool)
    cfg.video_dir.mkdir(parents=True, exist_ok=True)
    app = create_app(cfg)
    log.info("listening on http://%s:%d (cache %s, max %d MB, height <= %d)",
             cfg.bind, cfg.port, cfg.cache_dir, cfg.cache_max_mb, cfg.max_height)
    serve(app, host=cfg.bind, port=cfg.port, threads=cfg.threads, channel_timeout=300,
          ident="ytserver", clear_untrusted_proxy_headers=True)


if __name__ == "__main__":
    main()
