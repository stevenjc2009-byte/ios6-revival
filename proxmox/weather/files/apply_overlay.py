#!/usr/bin/env python3
"""Turn the pinned upstream YQL-X-Server-New tree into the ios6-revival server.

usage: apply_overlay.py <upstream_root> <overlay_dir>

Every patch is an exact-string replacement that must match exactly once, so a
changed upstream fails the install loudly instead of half-applying.  After
patching, nothing in the tree may reference the dead yzu.moe backend.
"""
import shutil
import sys
from pathlib import Path

# (file, old, new) - each old string must occur exactly once.
PATCHES = [
    ("args.py",
     'default="https://apis.yzu.moe/yzugeo/v1"',
     'default=""'),
    ("args.py",
     'default="https://apis.yzu.moe/weather/v1/forecast"',
     'default="https://api.open-meteo.com/v1/forecast"'),
    ("args.py",
     'default="https://yzu.moe"',
     'default="https://open-meteo.com"'),
    # WeatherX also sends: where query='NAME' limit 1  (single quotes, no lang)
    ("utils.py",
     """result['term'] = re.search(r'query="([^"]+)"', q).group(1)""",
     """_m = re.search(r'query=(?:"([^"]+)"|\\'([^\\']+)\\')', q)
        result['term'] = _m.group(1) or _m.group(2)"""),
    ("utils.py",
     """result = {'lang': re.search(r"lang='([^']+)'", q).group(1)}""",
     """_lm = re.search(r"lang='([^']+)'", q)
    result = {'lang': _lm.group(1) if _lm else 'en-US'}"""),
    ("utils.py",
     """    result['lang'] = re.search(r"lang='([^']+)'", q).group(1)
    print(f"Parsing query: {q}, result: {result}")
    return result

def gen_woeid_for_name""",
     """    print(f"Parsing query: {q}, result: {result}")
    return result

def gen_woeid_for_name"""),
    # chart baseline = previous close (what the Skyglow reference server sends)
    ("XMLFactory.py",
     '"market_open": info.open,',
     '"market_open": info.previous_close,'),
]

# Dead upstream code that talked to yzu.moe / GeoNames "electimon".
DELETE = [
    "modules/geocoder",
    "modules/yql/YzuGeo.py",
    "modules/yql/YzuGeoNew.py",
    "modules/yql/LocalSQLite.py",
    "generatedWoeids.json",
]


def main(root: Path, overlay: Path) -> None:
    pkg = root / "yql_x_server"
    if not pkg.is_dir() or not overlay.is_dir():
        sys.exit(f"apply_overlay: bad paths {root} {overlay}")

    for rel in DELETE:
        target = pkg / rel
        if target.is_dir():
            shutil.rmtree(target)
        elif target.exists():
            target.unlink()
        else:
            sys.exit(f"apply_overlay: expected upstream file missing: {rel}")

    for rel, old, new in PATCHES:
        path = pkg / rel
        text = path.read_text(encoding="utf-8")
        if text.count(old) != 1:
            sys.exit(f"apply_overlay: patch does not match exactly once in {rel}: {old[:60]!r}")
        path.write_text(text.replace(old, new), encoding="utf-8", newline="\n")

    for src in sorted(p for p in overlay.rglob("*") if p.is_file()):
        dest = pkg / src.relative_to(overlay)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dest)

    leftovers = [str(p.relative_to(root)) for p in pkg.rglob("*")
                 if p.is_file() and p.suffix in (".py", ".jinja2")
                 and "yzu.moe" in p.read_text(encoding="utf-8", errors="replace")]
    if leftovers:
        sys.exit(f"apply_overlay: yzu.moe still referenced in {leftovers}")
    print("apply_overlay: ok")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(Path(sys.argv[1]), Path(sys.argv[2]))
