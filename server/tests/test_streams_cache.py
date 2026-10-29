import time

from ytserver import cache


def test_ttl_cache_expires():
    c = cache.TTLCache(0.05)
    c.set("k", 1)
    assert c.get("k") == 1
    time.sleep(0.08)
    assert c.get("k") is None


def test_ttl_cache_pop_forgets_key():
    c = cache.TTLCache(60)
    c.set("k", 1)
    c.pop("k")
    c.pop("missing")
    assert c.get("k") is None
