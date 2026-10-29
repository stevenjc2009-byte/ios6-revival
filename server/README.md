# ytserver - YouTube GData v2 translation server

Imitates the dead `gdata.youtube.com` API over plain HTTP so the iOS 6 YouTube
app can search, browse and play again. Python 3.11, Flask + waitress.

## Run

    cd server
    python -m venv .venv && .venv\Scripts\pip install -r requirements.txt
    .venv\Scripts\python -m ytserver            # needs deno on PATH

Tests: `pip install -r requirements-dev.txt && python -m pytest -q tests`

| Env var | Default | Meaning |
|---|---|---|
| `YTS_BIND` / `YTS_PORT` | `0.0.0.0` / `8080` | listen address |
| `YTS_CACHE_DIR` | `./cache` | yt-dlp player-script cache; no video is stored (an old `<dir>/videos` is deleted at start) |
| `YTS_MAX_HEIGHT` | `360` | maximum stream height |
| `YTS_PUBLIC_URL` | derived from `Host` | base URL written into feeds |
| `YTS_STREAM_WAIT` `YTS_WORKERS` `YTS_THREADS` `YTS_META_TTL` | 45 / 3 / 16 / 600 | extras: seconds a stream request waits for the URL lookup, parallel lookups, HTTP threads, metadata cache seconds |

## Endpoints

- `GET /healthz` -> `200 ok`
- Search: `/feeds/api/videos?q=&start-index=&max-results=&orderby=&time=&duration=`, `/feeds/api/channels?q=`
- Video entry `/feeds/api/videos/<id>` (also starts looking up the stream URL), `/related`; `/comments`, `/responses`, `/captions`, `/complaints` return valid empty feeds
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

## Playback: pass-through streaming, nothing stored

`/stream/<id>` streams like the real YouTube player: no copy of the video is kept
on the server or the phone.

- yt-dlp only looks up the direct googlevideo URL of the progressive H.264 + AAC
  MP4 (itag 18, <= `YTS_MAX_HEIGHT`), which the iPhone 4 plays as-is and which has
  `moov` at the front. Nothing is downloaded by yt-dlp.
- The route relays that URL's bytes to the phone in 64 KB chunks as they arrive,
  forwarding the phone's `Range` header, so googlevideo's own `206` +
  `Content-Range` give seeking. HEAD is relayed too.
- The URL is kept in memory until shortly before googlevideo's `expire=` (max 5 h);
  a `403`/`410` drops it and looks it up again once. googlevideo refuses a fresh URL
  until its `available_at` time (~4 s), so the relay waits for that.
- Latency is hidden by prefetch: the app fetches the video entry right before
  playing, and that request starts the lookup. Concurrent requests share one
  lookup (Future per id); failures are negative-cached for 60 s.
- Measured 2026-10-29: cold start 7.4 s (lookup 4 s + available_at wait), prefetched
  start 0.13 s, relay 18 MB/s, mid-file seek 0.2 s. The old download-then-serve
  design took 83 s for a 436 MB video.
- Videos with no progressive format (live streams) answer `502` "video unavailable":
  playing them would need a merged or transcoded copy.
- Lookup slower than `YTS_STREAM_WAIT` -> `503` + `Retry-After: 5`; never a 500.
- Lookup and relay both use IPv4: googlevideo URLs are bound to the resolving address.

## Security notes

XML is produced with ElementTree builders (escaped, illegal control characters
removed). Request input is validated by strict regexes (`ids.py`; video id is
`^[A-Za-z0-9_-]{11}$`, full match), queries are capped at 200 characters, nothing
from a request reaches a shell (no subprocesses). Image proxying only
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
