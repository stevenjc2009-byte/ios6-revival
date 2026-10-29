"""Stock quotes, charts and news for the iOS 6 Stocks app, via yfinance.

Replaces upstream's Stocks.py.  Fixes: the cache key used the month name
instead of the hour; change/changepercent were computed from the open price
and the percent string was also sent as <change>; no name/exchange/52-week
range; random P/E and dividend values; NaN chart points.  Same public names
(get_ticker_info, get_ticker_chart_for_range, Symbol) so XMLFactory is
unchanged apart from one patched line.
"""
import math
import re
import time
from datetime import datetime, timezone
from urllib.parse import unquote
from xml.sax.saxutils import escape
import yfinance

QUOTE_TTL = 60
NEWS_TTL = 900
CHART_TTL = 60
MAX_CACHE = 500
_SYMBOL_OK = re.compile(r"^[A-Za-z0-9.^=\-]{1,15}$")

_quotes = {}
_charts = {}
_news = {}


def _put(cache, key, value):
    if len(cache) >= MAX_CACHE:
        cache.clear()
    cache[key] = (time.time(), value)


def _get(cache, key, ttl):
    hit = cache.get(key)
    if hit and time.time() - hit[0] < ttl:
        return hit[1]
    return None


def _num(value, default=0.0):
    try:
        value = float(value)
    except (TypeError, ValueError):
        return default
    return default if math.isnan(value) or math.isinf(value) else value


def sanitize_symbol(s):
    return escape(unquote(s or ""))


def valid_symbol(s):
    return bool(s) and bool(_SYMBOL_OK.match(unquote(s)))


def get_ticker_info(ticker_name):
    """Return a dict of quote fields, or None for an unknown/invalid symbol."""
    ticker_name = unquote(ticker_name or "")
    if not valid_symbol(ticker_name):
        return None
    cached = _get(_quotes, ticker_name, QUOTE_TTL)
    if cached is not None:
        return cached or None
    try:
        info = yfinance.Ticker(ticker_name).info
    except Exception as e:
        print(f"yfinance failed for {ticker_name}: {e}")
        return None
    price = info.get("currentPrice", info.get("regularMarketPrice")) if info else None
    if price is None:
        _put(_quotes, ticker_name, {})
        return None
    prev = _num(info.get("regularMarketPreviousClose", info.get("previousClose")))
    price = _num(price)
    change = _num(info.get("regularMarketChange"), price - prev if prev else 0.0)
    pct = _num(info.get("regularMarketChangePercent"), change / prev * 100.0 if prev else 0.0)
    name = info.get("longName") or info.get("shortName") or ticker_name
    low52, high52 = _num(info.get("fiftyTwoWeekLow")), _num(info.get("fiftyTwoWeekHigh"))
    out = {
        "sanitizedSymbol": sanitize_symbol(ticker_name),
        "name": name,
        "exchange": info.get("fullExchangeName") or info.get("exchange") or "",
        "open": _num(info.get("regularMarketOpen", info.get("open"))),
        "price": price,
        "previous_close": prev,
        "change": change,
        "changepercent": pct,
        "high": _num(info.get("regularMarketDayHigh")),
        "low": _num(info.get("regularMarketDayLow")),
        "volume": int(_num(info.get("regularMarketVolume", info.get("volume")))),
        "averageVolume": int(_num(info.get("averageVolume"))),
        "marketCap": _num(info.get("marketCap")),
        "peratio": _num(info.get("trailingPE")),
        "yearrange": f"{low52:.2f} - {high52:.2f}" if high52 else "",
        "dividendYield": _num(info.get("dividendYield")),
    }
    _put(_quotes, ticker_name, out)
    return out


def get_ticker_news(ticker_name):
    ticker_name = unquote(ticker_name or "")
    cached = _get(_news, ticker_name, NEWS_TTL)
    if cached is not None:
        return cached
    items = []
    try:
        for item in yfinance.Ticker(ticker_name).get_news() or []:
            content = item.get("content", item)
            link = (content.get("canonicalUrl") or {}).get("url") or content.get("link")
            title = content.get("title")
            pub = content.get("pubDate")
            if not (link and title):
                continue
            try:
                stamp = int(datetime.strptime(pub, "%Y-%m-%dT%H:%M:%SZ")
                            .replace(tzinfo=timezone.utc).timestamp())
            except (TypeError, ValueError):
                stamp = int(time.time())
            items.append({"title": escape(title), "link": escape(link), "published": stamp})
    except Exception as e:
        print(f"yfinance news failed for {ticker_name}: {e}")
    _put(_news, ticker_name, items)
    return items


_RANGES = {
    "1d": ("1d", "5m"), "5d": ("5d", "15m"), "1m": ("1mo", "1d"),
    "3m": ("3mo", "1d"), "6m": ("6mo", "1wk"), "1y": ("1y", "1wk"),
    "2y": ("2y", "1wk"), "5y": ("5y", "1wk"), "10y": ("10y", "1wk"),
}


def get_ticker_chart_for_range(ticker, _range):
    ticker = unquote(ticker or "")
    if _range not in _RANGES or not valid_symbol(ticker):
        print("Unknown range or symbol: " + str(_range))
        return None
    key = f"{ticker}_{_range}"
    cached = _get(_charts, key, CHART_TTL)
    if cached is not None:
        return cached
    period, interval = _RANGES[_range]
    try:
        data = yfinance.Ticker(ticker).history(period=period, interval=interval)
    except Exception as e:
        print(f"yfinance history failed for {ticker}: {e}")
        return None
    out = []
    for stamp, row in data.iterrows():
        close = _num(row["Close"], None)
        if close is None:
            continue
        out.append({"open": _num(row["Open"]), "high": _num(row["High"]),
                    "low": _num(row["Low"]), "close": round(close, 4),
                    "volume": int(_num(row["Volume"])), "timestamp": int(stamp.timestamp())})
    _put(_charts, key, out)
    return out


def _signed(value, fmt):
    return ("+" if value > 0 else "-" if value < 0 else "") + format(abs(value), fmt)


class Symbol:
    def __init__(self, symbol):
        self.name = symbol["sanitizedSymbol"]
        self.full_name = escape(symbol["name"])
        self.name_short = escape(symbol["name"][:12] + "..." if len(symbol["name"]) > 15 else symbol["name"])
        self.exchange = escape(symbol["exchange"])
        self.open = symbol["previous_close"]  # XMLFactory uses this for the chart baseline
        self.open_price = symbol["open"]
        self.previous_close = symbol["previous_close"]
        self.price = symbol["price"]
        self.change = _signed(symbol["change"], ".2f")
        self.real_time_change = self.change
        self.change_percent = _signed(symbol["changepercent"], ".2f") + "%"
        self.market_cap = symbol["marketCap"]
        self.volume = symbol["volume"]
        self.average_volume = symbol["averageVolume"]
        self.high = symbol["high"]
        self.low = symbol["low"]
        self.peratio = symbol["peratio"]
        self.yearrange = escape(symbol["yearrange"])
        self.dividend_yield = symbol["dividendYield"]
        self._news = None

    @property
    def news(self):
        if self._news is None:
            self._news = get_ticker_news(self.name)
        return self._news

    @property
    def news_count(self):
        return len(self.news)
