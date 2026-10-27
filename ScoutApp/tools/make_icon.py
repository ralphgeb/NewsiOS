"""Draws Scout's app icon: the ScoutAI icon (a bold white headline with the red dot, then three
grey lines on navy), redrawn at full size so it stays sharp. Measurements are from ScoutAI's
icons/icon-512.png, doubled.

    python3 tools/make_icon.py   # writes Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
"""
from pathlib import Path
from PIL import Image, ImageDraw

SIZE = 1024
SCALE = 4                      # draw large, then shrink, for smooth edges
NAVY = (19, 27, 44)
WHITE = (255, 255, 255)
GREY = (149, 154, 162)
RED = (211, 84, 84)

# On the 512 grid: (left, top, right, bottom), bars have fully round ends.
HEADLINE = (111, 150, 334, 196)
LINES = [(111, 234, 402, 265), (111, 294, 402, 325), (111, 354, 300, 385)]
DOT = (383.5, 172.5, 32)       # centre x, centre y, radius


def main():
    k = SIZE / 512 * SCALE
    img = Image.new("RGB", (SIZE * SCALE, SIZE * SCALE), NAVY)
    d = ImageDraw.Draw(img)

    def bar(box, colour):
        l, t, r, b = (v * k for v in box)
        d.rounded_rectangle([l, t, r, b], radius=(b - t) / 2, fill=colour)

    bar(HEADLINE, WHITE)
    for line in LINES:
        bar(line, GREY)
    x, y, r = (v * k for v in DOT)
    d.ellipse([x - r, y - r, x + r, y + r], fill=RED)

    out = Path(__file__).resolve().parent.parent / "Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
    img.resize((SIZE, SIZE), Image.LANCZOS).save(out, optimize=True)
    print("wrote", out)


if __name__ == "__main__":
    main()
