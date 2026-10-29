#!/usr/bin/env python3
"""Send the requests WeatherX / the iOS 6 Weather and Stocks apps make and check the answers.

usage: probe.py [--base http://127.0.0.1:8000] [--city Coventry] [--symbol AAPL] [--only all|weather|stocks]

Query strings are the real Apple YQL templates found in the iPhone's dyld shared
cache.  Exit code 0 only if every check passes; stdlib only.
"""
import argparse
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail else ""))
    return ok


def http(base, path, data=None, timeout=60):
    req = urllib.request.Request(base + path, data=data.encode() if data else None)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:  # connection refused, timeout, ...
        return 0, f"{type(e).__name__}: {e}"


def yql(base, q):
    return http(base, "/yql/weather?q=" + urllib.parse.quote(q))


def parse(body):
    try:
        return ET.fromstring(body)
    except ET.ParseError:
        return None


def num(text):
    try:
        return float(str(text).replace("%", "").replace("+", ""))
    except (TypeError, ValueError):
        return None


def forecast_checks(label, root, woeid):
    loc = root.find(".//location[@woeid]") if root is not None else None
    check(f"{label}: location has woeid {woeid}", loc is not None and loc.get("woeid") == str(woeid))
    if loc is None:
        return None
    cur = loc.find("currently")
    temp = num(cur.get("temp")) if cur is not None else None
    check(f"{label}: current temp is a number in -60..60", temp is not None and -60 <= temp <= 60,
          f"temp={temp}")
    days = loc.findall("forecast/day")
    check(f"{label}: 6 forecast days, high >= low", len(days) == 6 and all(
        num(d.find("temp").get("high")) >= num(d.find("temp").get("low")) for d in days), f"days={len(days)}")
    check(f"{label}: condition codes are 0..47", all(
        c.get("code", "").isdigit() and 0 <= int(c.get("code")) <= 47 for c in loc.iter("condition")))
    return loc


def weather(base, city):
    search = ("select city, country, countryAbbr, state, stateAbbr, locationID, woeid "
              f"from partner.weather.locations where query=\"{city}\" and lang='en-US'")
    status, body = yql(base, search)
    root = parse(body)
    locs = root.findall(".//location") if root is not None else []
    check("weather search: HTTP 200 with locations", status == 200 and len(locs) > 0, f"status={status} n={len(locs)}")
    if not locs:
        return None
    first = locs[0]
    woeid = first.get("woeid", "")
    check("weather search: first hit is the city, with a numeric woeid",
          first.get("city", "").startswith(city) and woeid.isdigit(), f"{first.get('city')} / {woeid}")
    check("weather search: country fields present", bool(first.get("country")) and bool(first.get("countryAbbr")),
          f"{first.get('country')} / {first.get('countryAbbr')}")

    status, body = yql(base, f"select woeid from partner.weather.locations where query='{city}' limit 1")
    root = parse(body)
    first_woeid = root.find(".//location") if root is not None else None
    check("woeid-by-name (single-quote form): returns the same woeid",
          status == 200 and first_woeid is not None and first_woeid.get("woeid") == woeid, f"status={status}")

    multi = ("select * from yql.query.multi where queries=\"select * from partner.weather.forecasts "
             f"where (woeid={woeid}) and lang='en-US' and unit='c'; select woeid,hourlyforecast.hour.time24,"
             "hourlyforecast.hour.condition.code,hourlyforecast.hour.condition.poP,"
             "hourlyforecast.hour.condition.temp from partner.weather.forecasts.hourly "
             f"where (woeid={woeid}) and lang='en-US' and unit='c'\"")
    status, body = yql(base, multi)
    check("forecast by woeid: HTTP 200", status == 200, f"status={status}")
    loc = forecast_checks("forecast by woeid", parse(body), woeid)
    if loc is None or not loc.get("latitude"):
        return woeid
    lat, lon = float(loc.get("latitude")), float(loc.get("longitude"))
    status, body = yql(base, f"select woeid from partner.weather.forecasts where lat={lat:f} and lon={lon:f} and lang='en-US'")
    check("forecast by lat/lon: HTTP 200", status == 200, f"status={status}")
    root = parse(body)
    loc = root.find(".//location") if root is not None else None
    check("forecast by lat/lon: resolves to the same woeid",
          loc is not None and loc.get("woeid") == woeid, f"got={loc.get('woeid') if loc is not None else None}")

    dgw = "/yql/weather/dgw"
    status, body = http(base, dgw, '<?xml version="1.0" encoding="UTF-8"?><request api="weather">'
                        f'<query type="getlocationid"><phrase>{city}</phrase><lang>en-US</lang></query></request>')
    root = parse(body)
    ids = [i.text for i in root.iter("id")] if root is not None else []
    check("legacy search (POST /yql/weather/dgw)", status == 200 and woeid in ids, f"status={status} n={len(ids)}")
    status, body = http(base, dgw, '<?xml version="1.0" encoding="UTF-8"?><request api="weather">'
                        f'<query type="getforecastbylocationid"><list><id>{woeid}</id></list><lang>en-US</lang></query></request>')
    root = parse(body)
    cond = root.find(".//condition") if root is not None else None
    fc = root.findall(".//forecast") if root is not None else []
    check("legacy forecast: temp number + 6 days", status == 200 and cond is not None
          and num(cond.get("temp")) is not None and len(fc) == 6, f"status={status} days={len(fc)}")
    return woeid


def stocks(base, symbol):
    head = '<?xml version="1.0" encoding="UTF-8"?><request api="finance" devtype="Apple_iOS">'
    status, body = http(base, "/dgw", head + f'<query id="0" type="getquotes"><list><symbol>{symbol}</symbol></list></query></request>')
    root = parse(body)
    q = root.find(".//quote") if root is not None else None
    check("stocks getquotes: HTTP 200 with a quote", status == 200 and q is not None, f"status={status}")
    if q is not None:
        t = {c.tag: c.text for c in q}
        price, change, pct = num(t.get("price")), num(t.get("change")), num(t.get("changepercent"))
        check("quote: symbol, name and exchange present", t.get("symbol") == symbol and bool(t.get("name"))
              and bool(t.get("exchange")), f"{t.get('symbol')} / {t.get('name')} / {t.get('exchange')}")
        check("quote: price is a positive number", price is not None and price > 0, f"price={price}")
        check("quote: change and changepercent have the same sign, |pct| < 40",
              change is not None and pct is not None and (change * pct >= 0) and abs(pct) < 40,
              f"change={t.get('change')} pct={t.get('changepercent')}")
        check("quote: signed change text (+/-/0)", (t.get("change") or "")[:1] in "+-0", t.get("change"))
        check("quote: 52-week range 'low - high'", " - " in (t.get("yearrange") or ""), t.get("yearrange"))
        check("quote: day high >= day low", num(t.get("high")) is not None and num(t.get("high")) >= num(t.get("low")),
              f"{t.get('high')} / {t.get('low')}")
    status, body = http(base, "/dgw", head + f'<query id="1" type="getchart"><symbol>{symbol}</symbol><range>5d</range></query></request>')
    root = parse(body)
    pts = root.findall(".//point") if root is not None else []
    stamps = [num(p.get("timestamp")) for p in pts]
    closes = [num(p.get("close")) for p in pts]
    check("stocks getchart 5d: >= 10 points", status == 200 and len(pts) >= 10, f"status={status} n={len(pts)}")
    check("chart: timestamps ascending, closes are positive numbers",
          len(pts) > 1 and None not in stamps and None not in closes and stamps == sorted(stamps)
          and all(c > 0 for c in closes))
    meta = root.find(".//meta") if root is not None else None
    check("chart: meta has symbol and marketclose", meta is not None and meta.findtext("symbol") == symbol
          and num(meta.findtext("marketclose")) is not None)
    status, body = http(base, "/dgw", head + f'<query id="2" type="getnews"><list><symbol>{symbol}</symbol></list></query></request>')
    root = parse(body)
    check("stocks getnews: well-formed <feed> (items may be empty)", status == 200 and root is not None
          and root.tag == "feed" and root.find("list") is not None, f"status={status}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:8000")
    ap.add_argument("--city", default="Coventry")
    ap.add_argument("--symbol", default="AAPL")
    ap.add_argument("--only", choices=("all", "weather", "stocks"), default="all")
    a = ap.parse_args()
    base = a.base.rstrip("/")
    status, body = http(base, "/dgw", timeout=10)
    if not check("server reachable (GET /dgw -> ok)", status == 200 and body.strip() == "ok", f"status={status} {body[:80]}"):
        print("probe: server not reachable, nothing else to test")
        return 1
    if a.only in ("all", "weather"):
        weather(base, a.city)
    if a.only in ("all", "stocks"):
        stocks(base, a.symbol)
    bad = results.count(False)
    print(f"probe: {len(results) - bad}/{len(results)} checks passed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
