"""Reverse geocoding only (lat/lon -> place name), via OpenStreetMap Nominatim.

Forward geocoding is done by the Open-Meteo provider in yql/OpenMeteoGeo.py.
Replaces upstream's Yzu / GeoNames("electimon") geocoders.
"""
import requests

_NOMINATIM = "https://nominatim.openstreetmap.org/reverse"
_HEADERS = {"User-Agent": "ios6-revival-weather (self-hosted)"}


class Geocoder:
    def reverse_geocode(self, lat, long):
        try:
            r = requests.get(_NOMINATIM, headers=_HEADERS, timeout=8, params={
                "format": "jsonv2", "lat": lat, "lon": long, "zoom": 10,
                "addressdetails": 1, "accept-language": "en"})
            if r.status_code == 200:
                data = r.json()
                if isinstance(data, dict) and "address" in data:
                    return data
            print(f"Reverse geocode {lat},{long}: nominatim returned {r.status_code}")
        except Exception as e:
            print(f"Failed to reverse geocode {lat}, {long}: {e}")
        return None


def get_city(location):
    if "toponymName" in location:
        return location['toponymName']
    if "address" in location:
        location = location['address']
    for key in ("town", "region", "city", "village", "county", "name"):
        if key in location:
            return location[key]
    return None
