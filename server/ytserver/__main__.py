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
    if not shutil.which("deno"):
        log.warning("deno not found on PATH")
    cfg.cache_dir.mkdir(parents=True, exist_ok=True)
    app = create_app(cfg)
    log.info("listening on http://%s:%d (pass-through streaming, height <= %d)",
             cfg.bind, cfg.port, cfg.max_height)
    serve(app, host=cfg.bind, port=cfg.port, threads=cfg.threads, channel_timeout=300,
          ident="ytserver", clear_untrusted_proxy_headers=True)


if __name__ == "__main__":
    main()
