"""Draws Scout's app icon: a network of white nodes on Scout's navy, one hub with spokes out to
smaller circles, like an atom or a map of connected stories, with ScoutAI's red dot as one of
the nodes. Drawn large and shrunk, so it stays sharp.

    python3 tools/make_icon.py   # writes Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
"""
from pathlib import Path
from PIL import Image, ImageDraw

SIZE = 1024
SCALE = 4                      # draw large, then shrink, for smooth edges
NAVY = (19, 27, 44)
WHITE = (255, 255, 255)
GREY = (149, 154, 162)
RED = (226, 85, 85)

HUB = (530, 500, 92)           # centre x, centre y, radius, on the 1024 grid
SPOKE = 30                     # line width
# Each node: offset from the hub (x, y), radius, colour.
NODES = [
    ((-200, -214), 70, WHITE),
    ((176, -168), 76, RED),
    ((-232, 10), 44, GREY),
    ((-104, 262), 58, WHITE),
    ((176, 170), 54, WHITE),
]


def main():
    k = SCALE
    img = Image.new("RGB", (SIZE * k, SIZE * k), NAVY)
    d = ImageDraw.Draw(img)
    hx, hy, hr = HUB

    def circle(x, y, r, colour):
        d.ellipse([(x - r) * k, (y - r) * k, (x + r) * k, (y + r) * k], fill=colour)

    for (dx, dy), r, colour in NODES:
        d.line([hx * k, hy * k, (hx + dx) * k, (hy + dy) * k], fill=WHITE, width=SPOKE * k)
    for (dx, dy), r, colour in NODES:
        circle(hx + dx, hy + dy, r, colour)
    circle(hx, hy, hr, WHITE)

    out = Path(__file__).resolve().parent.parent / "Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
    img.resize((SIZE, SIZE), Image.LANCZOS).save(out, optimize=True)
    print("wrote", out)


if __name__ == "__main__":
    main()
