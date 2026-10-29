# ytserver - YouTube GData v2 translation server

Imitates the dead `gdata.youtube.com` API over plain HTTP so the iOS 6 YouTube
app can search, browse and play again. Python 3.11, Flask + waitress.

## Run

    cd server
    python -m venv .venv && .venv\Scripts\pip install -r requirements.txt
    .venv\Scripts\python -m ytserver            # needs ffmpeg, ffprobe and deno on PATH

Tests: `pip install -r requirements-dev.txt && python -m pytest -q tests`

| Env var | Default | Meaning |
|---|---|---|
| `YTS_BIND` / `YTS_PORT` | `0.0.0.0` / `8080` | listen address |
| `YTS_CACHE_DIR` | `./cache` | built MP4s live in `<dir>/videos` |
| `YTS_CACHE_MAX_MB` | `4096` | LRU eviction limit |
| `YTS_MAX_HEIGHT` | `360` | maximum output height |
| `YTS_PUBLIC_URL` | derived from `Host` | base URL written into feeds |
| `YTS_STREAM_WAIT` `YTS_WORKERS` `YTS_THREADS` `YTS_META_TTL` | 100 / 2 / 16 / 600 | extras: seconds a stream request blocks, parallel builds, HTTP threads, metadata cache seconds |

## Endpoints

- `GET /healthz` -> `200 ok`
- Search: `/feeds/api/videos?q=&start-index=&max-results=&orderby=&time=&duration=`, `/feeds/api/channels?q=`
- Video entry `/feeds/api/videos/<id>` (also starts building the file), `/related`; `/comments`, `/responses`, `/captions`, `/complaints` return valid empty feeds
- `/feeds/api/standardfeeds/[region/]<feed>` (`most_popular`, `most_viewed`, `top_rated`, `recently_featured`, `most_recent`, ... and `most_popular_<Category>`)
- `/feeds/api/users/<UC id | @handle | name>` (channel entry), `/uploads`, `/playlists`; `/feeds/api/channels/<id>`
- `/feeds/api/playlists/<id>`
- any other `/feeds/api/...` (subscriptions, favorites, events, `users/default/*`) -> valid empty feed (signed out)
- `/schemas/2007/categories.cat`
- `/stream/<id>[.mp4]` (alias `/getvideo/<id>`) - GET/HEAD, Range -> 206
- `/vi/<id>/<name>.jpg` thumbnails, `/img/<token>.jpg` channel avatars (host allowlist)
- Fake sign-in: `POST /youtube/accounts/registerDevice`, `applelogin1`, `applelogin2`, `/accounts/ClientLogin`

## Why InnerTube for metadata, yt-dlp only for media

Metadata comes straight from YouTube's InnerTube JSON API (the plain `WEB` client:
`search`, `next`, `browse`, `player`, `navigation/resolve_url`). yt-dlp is used only
to obtain the media file.

- Speed: one HTTP call (~0.3 s) per feed page. yt-dlp's extractor does a full
  watch-page/player round trip per video and does not offer search paging, channel
  uploads or related feeds in a form that maps onto GData offsets.
- Paging: GData pages by offset, InnerTube by continuation token. `InnerTube.collect`
  keeps the token chain per logical feed and merges pages until the requested
  window is covered (max 6 upstream pages).
- Robustness: parsing walks the JSON for renderer keys instead of fixed paths, so
  the move from `videoRenderer` to `lockupViewModel` (related videos) was a
  contained change. Garbage input yields empty pages, never a 500.
- Cost: InnerTube is unofficial and can change; yt-dlp has the same exposure but a
  faster fix cadence, which is why it still does the media step. Trending and home
  browse return nothing for signed-out clients, so standard feeds are synthesised
  from filtered searches (this-week / this-month, category -> query map).

## Playback: blocking build, not progressive streaming

`/stream/<id>` blocks until a finished, faststart H.264 (Main L3.0) + AAC MP4 of at
most `YTS_MAX_HEIGHT` exists, then serves it with `send_file`, which gives correct
Content-Length, ETag and `Range` -> `206`.

- The iOS 6 media player needs a seekable file with a known length and `moov` at the
  front. Serving a file that is still being written gives a wrong Content-Length and
  breaks seeking; remuxing on the fly cannot support Range at all.
- Fast path: when yt-dlp can fetch a progressive avc1+mp4a format (itag 18) the file
  is only checked with ffprobe and copied (`+faststart`), typically 3-25 s even for
  long videos. Otherwise the fallback chain is dash avc1+mp4a, then any format
  transcoded with libx264/aac. `plan_ffmpeg` copies each stream when it already
  complies and re-encodes only the part that does not.
- Latency is hidden by prefetch: the app fetches the video entry right before
  playing, and that request starts the build. Concurrent requests for one id share
  one build (Future per id); failures are negative-cached briefly.
- If the build outlasts `YTS_STREAM_WAIT` the route answers `503` + `Retry-After: 5`;
  an unavailable video gives `502`, never a 500.
- Cache: LRU by mtime, files being served are never evicted.

## Security notes

XML is produced with ElementTree builders (escaped, illegal control characters
removed). Request input is validated by strict regexes (`ids.py`; video id is
`^[A-Za-z0-9_-]{11}$`, full match), queries are capped at 200 characters, nothing
from a request reaches a shell (subprocess argument lists only). Image proxying only
contacts `i.ytimg.com`, `yt3.ggpht.com` and `yt3.googleusercontent.com`. Logs hold
method, path (no query string), status and milliseconds only.

## Limitations / assumptions

- No login, comments, ratings or subscriptions: signed-out empty feeds.
- Publication dates from related/search are approximate ("1 year ago"); the
  single-video entry has the exact date.
- The `yt:` namespace is assumed to be `http://gdata.youtube.com/schemas/2007`
  (constant in `atom.py`); published templates disagree. Unverified against the app.
- Entries advertise the flash slot (`yt:format=5`) plus 3GPP (1, 6) and MP4 (3, 8, 2, 9)
  slots; every non-flash slot points at `/stream/<id>.mp4`.
- Tested against YouTube on 2026-10-29. If extraction breaks, update `yt-dlp` first.
- Windows firewall must allow the port for the phone; this server does not touch it.
