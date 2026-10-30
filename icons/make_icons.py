"""Draws the iOS 6 style Settings icons for the ios6-revival panes (29 px and 58 px @2x).

Same shape as the stock Settings icons: rounded square, dark 1 px rim, vertical gradient with a gloss
band on the top half, white glyph with a soft shadow. Run: py -3 make_icons.py <out folder>
"""
import math
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 464  # drawing size: 8x the 58 px @2x icon, so every edge is anti-aliased when shrunk
U = S / 58  # one @2x pixel


def rounded(size, radius, inset=0):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle((inset, inset, size - 1 - inset, size - 1 - inset), radius, fill=255)
    return m


def base(top, bottom, rim):
    """Rounded square with gradient, gloss and rim, no glyph."""
    grad = Image.new("RGB", (S, S))
    d = ImageDraw.Draw(grad)
    for y in range(S):
        t = y / (S - 1)
        d.line((0, y, S, y), fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    gloss = Image.new("L", (S, S), 0)
    gd = ImageDraw.Draw(gloss)
    for y in range(int(S * 0.47)):
        gd.line((0, y, S, y), fill=round(105 - 55 * y / (S * 0.47)))
    gloss = ImageChops.multiply(gloss, rounded(S, 8 * U, int(1.5 * U)))
    icon = Image.composite(Image.new("RGB", (S, S), (255, 255, 255)), grad, gloss)
    out = Image.new("RGBA", (S, S), rim + (255,))
    out.paste(icon, (0, 0), rounded(S, 8.5 * U, int(1 * U)))
    out.putalpha(rounded(S, 9.5 * U))
    return out


def finish(icon, glyph):
    """Lays the white glyph (an L mask) on the icon with a dark shadow one pixel below it."""
    shadow = glyph.filter(ImageFilter.GaussianBlur(U * 0.8)).point(lambda v: v * 0.45)
    shadow = ImageChops.offset(shadow, 0, int(U))
    icon.paste(Image.new("RGB", (S, S), (0, 0, 0)), (0, 0), ImageChops.multiply(shadow, icon.getchannel("A")))
    icon.paste(Image.new("RGB", (S, S), (255, 255, 255)), (0, 0), glyph)
    return icon


def p(*xy):
    return [v * U for v in xy]


def trash():
    g = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(g)
    d.rounded_rectangle(p(23, 11, 35, 16), 2 * U, outline=255, width=int(2.4 * U))   # handle
    d.rounded_rectangle(p(13, 15, 45, 20), 1.5 * U, fill=255)                        # lid
    d.polygon(p(16, 22, 42, 22, 39.5, 48, 18.5, 48), fill=255)                        # can
    for x in (23.5, 29, 34.5):                                                         # ribs
        d.line(p(x, 26, x, 44), fill=0, width=int(2.2 * U))
    return g


def close_apps():
    g = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(g)
    for x, y in ((12, 12), (31, 12), (12, 31)):
        d.rounded_rectangle(p(x, y, x + 15, y + 15), 3.5 * U, fill=255)
    d.line(p(33, 33, 45, 45), fill=255, width=int(4 * U))
    d.line(p(45, 33, 33, 45), fill=255, width=int(4 * U))
    return g


def no_updates():
    g = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(g)
    d.rectangle(p(25.5, 9, 32.5, 28), fill=255)                                       # arrow shaft
    d.polygon(p(16, 26, 42, 26, 29, 40), fill=255)                                     # arrow head
    d.rounded_rectangle(p(12, 43, 46, 49), 2 * U, fill=255)                           # tray
    d.line(p(11, 11, 47, 47), fill=0, width=int(8 * U))                                # strike through, with a gap
    d.line(p(11, 11, 47, 47), fill=255, width=int(3.5 * U))
    return g


def log_page():
    g = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(g)
    d.polygon(p(15, 9, 35, 9, 44, 18, 44, 49, 15, 49), fill=255)                      # page
    d.polygon(p(35, 9, 35, 18, 44, 18), fill=150)                                      # folded corner
    for y in (24, 30, 36, 42):
        d.line(p(20, y, 39 if y != 42 else 31, y), fill=0, width=int(2.4 * U))
    return g


def tv_play():
    g = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(g)
    d.rounded_rectangle(p(8, 15, 50, 44), 6 * U, fill=255)
    d.polygon(p(24, 21.5, 24, 37.5, 37, 29.5), fill=0)
    return g


def gear():
    g = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(g)
    pts = []
    for i in range(32):   # 8 teeth: each tooth is 4 corners, outer radius 21, root radius 16
        a = (i // 4 + (0, 0.28, 0.5, 0.78)[i % 4]) * 2 * math.pi / 8
        r = 21 if i % 4 in (1, 2) else 16
        pts += p(29 + r * math.cos(a), 29 + r * math.sin(a))
    d.polygon(pts, fill=255)
    d.ellipse(p(22, 22, 36, 36), fill=0)                                               # hole
    return g


ICONS = {
    # file stem: (glyph, gradient top, gradient bottom, rim)
    "CacheCleaner": (trash, (166, 171, 178), (98, 104, 113), (66, 70, 77)),
    "AutoClose": (close_apps, (240, 92, 80), (186, 30, 26), (120, 20, 18)),
    "iOSUpdates": (no_updates, (110, 160, 230), (30, 86, 180), (20, 56, 120)),
    "PhoneLog": (log_page, (120, 210, 100), (40, 140, 40), (26, 92, 26)),
    "IOS6RevivalYT": (tv_play, (238, 70, 60), (172, 16, 16), (110, 12, 12)),
    "BackgroundServices": (gear, (150, 120, 200), (88, 56, 150), (58, 36, 100)),
}


def main(out):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    for stem, (glyph, top, bottom, rim) in ICONS.items():
        big = finish(base(top, bottom, rim), glyph())
        big.resize((58, 58), Image.LANCZOS).save(out / f"{stem}@2x.png")
        big.resize((29, 29), Image.LANCZOS).save(out / f"{stem}.png")
    print("wrote", len(ICONS) * 2, "icons to", out)


if __name__ == "__main__":
    main(sys.argv[1])
