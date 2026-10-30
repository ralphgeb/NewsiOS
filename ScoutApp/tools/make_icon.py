"""Draws Scout's app icon: a network of white nodes on Scout's navy, one hub with spokes out to
smaller circles, like an atom or a map of connected stories, with ScoutAI's red dot as one of
the nodes. Drawn large and shrunk, so it stays sharp.

    python3 tools/make_icon.py   # writes AppIcon, the alternate icons (one per look) and their previews
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


# The looks from Settings (Appearance.swift): the icon's tile in the look's main colour, its accent
# for the red node. Each becomes an alternate app icon and a small preview for Settings.
LOOKS = {
    "Graphite": ((18, 18, 20), (255, 97, 41)),
    "Ocean": ((14, 42, 71), (31, 200, 180)),
    "Forest": ((28, 51, 36), (232, 176, 74)),
    "Mono": ((0, 0, 0), (229, 72, 77)),
    "Dusk": ((43, 37, 64), (255, 138, 101)),
    "Sand": ((58, 46, 39), (61, 139, 253)),
}


def draw(background=NAVY, accent=RED):
    k = SCALE
    img = Image.new("RGB", (SIZE * k, SIZE * k), background)
    d = ImageDraw.Draw(img)
    hx, hy, hr = HUB

    def circle(x, y, r, colour):
        d.ellipse([(x - r) * k, (y - r) * k, (x + r) * k, (y + r) * k], fill=colour)

    for (dx, dy), r, colour in NODES:
        d.line([hx * k, hy * k, (hx + dx) * k, (hy + dy) * k], fill=WHITE, width=SPOKE * k)
    for (dx, dy), r, colour in NODES:
        circle(hx + dx, hy + dy, r, accent if colour == RED else colour)
    circle(hx, hy, hr, WHITE)
    return img.resize((SIZE, SIZE), Image.LANCZOS)


def write_icon(folder, img):
    folder.mkdir(parents=True, exist_ok=True)
    img.save(folder / "icon-1024.png", optimize=True)
    (folder / "Contents.json").write_text(
        '{\n  "images" : [ { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],\n'
        '  "info" : { "author" : "xcode", "version" : 1 }\n}\n')


def write_preview(folder, img):
    folder.mkdir(parents=True, exist_ok=True)
    img.resize((180, 180), Image.LANCZOS).save(folder / "preview.png", optimize=True)
    (folder / "Contents.json").write_text(
        '{\n  "images" : [ { "filename" : "preview.png", "idiom" : "universal" } ],\n'
        '  "info" : { "author" : "xcode", "version" : 1 }\n}\n')


def main():
    assets = Path(__file__).resolve().parent.parent / "Sources/Assets.xcassets"
    scout = draw()
    write_icon(assets / "AppIcon.appiconset", scout)
    write_preview(assets / "IconPreview-Scout.imageset", scout)
    for name, (background, accent) in LOOKS.items():
        img = draw(background, accent)
        write_icon(assets / f"AppIcon-{name}.appiconset", img)
        write_preview(assets / f"IconPreview-{name}.imageset", img)
    print("wrote the app icon,", len(LOOKS), "alternates and their previews")


if __name__ == "__main__":
    main()
