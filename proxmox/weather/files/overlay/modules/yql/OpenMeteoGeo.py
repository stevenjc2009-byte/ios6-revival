"""Place search and place lookup backed by the Open-Meteo geocoding API.

Replaces upstream's YzuGeo provider (the upstream default, which is offline).  The
"woeid" the phone sees is the GeoNames id Open-Meteo returns, so ids differ
from the old Yahoo WOEIDs.  No API key is needed.
"""
import requests
from iso3166 import countries
from ..ModuleClasses import YQL

_BASE = "https://geocoding-api.open-meteo.com/v1"
_HEADERS = {"User-Agent": "ios6-revival-weather"}
_meta_cache = {}


def _lang(lang):
    code = (lang or "en").split("-")[0].split("_")[0].lower()
    return code if code.isalpha() and 2 <= len(code) <= 3 else "en"


def _alpha3(cc):
    try:
        return countries.get(cc).alpha3
    except (KeyError, AttributeError):
        return "UNKN"


class OpenMeteoGeoYQL(YQL):
    def _to_metadata(self, item, with_admin):
        name = item.get("name", "")
        admin = item.get("admin1") or ""
        if with_admin and admin and admin != name:
            name = f"{name}, {admin}"
        return {
            "id": str(item["id"]),
            "woeid": str(item["id"]),
            "name": name,
            "iso": _alpha3(item.get("country_code", "")),
            "state": item.get("admin1") or "",
            "country": item.get("country") or "",
            "latitude": item["latitude"],
            "longitude": item["longitude"],
        }

    def get_similar_name(self, name, lang):
        name = (name or "").strip()
        if len(name) < 2:
            return []
        r = requests.get(_BASE + "/search", headers=_HEADERS, timeout=8, params={
            "name": name, "count": 15, "format": "json", "language": _lang(lang)})
        if r.status_code != 200:
            raise ValueError(f"open-meteo geocoding returned {r.status_code}")
        out = []
        for item in r.json().get("results", []):
            if "id" in item and "latitude" in item and "longitude" in item:
                out.append(self._to_metadata(item, with_admin=True))
        return out

    def get_woeid_from_name(self, name, lang):
        found = self.get_similar_name(name, lang)
        if not found:
            raise ValueError(f"no place found for {name!r}")
        return found[0]["woeid"]

    def get_metadata_for_woeid(self, woeid, lang=None):
        key = (str(woeid), _lang(lang))
        if key in _meta_cache:
            return dict(_meta_cache[key])
        if not str(woeid).isdigit():
            raise ValueError(f"bad place id {woeid!r}")
        r = requests.get(_BASE + "/get", headers=_HEADERS, timeout=8, params={
            "id": str(woeid), "language": key[1]})
        if r.status_code != 200:
            raise ValueError(f"place {woeid} not found (open-meteo {r.status_code})")
        meta = self._to_metadata(r.json(), with_admin=False)
        if len(_meta_cache) > 1000:
            _meta_cache.clear()
        _meta_cache[key] = meta
        return dict(meta)
