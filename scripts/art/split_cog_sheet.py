#!/usr/bin/env python3
"""Key, split and pad the nano-banana unit sheet into per-army board sprites.

    python3 -m pip install --user pillow
    python3 scripts/art/split_cog_sheet.py

Input  : scripts/art/source/soldiers_sheet.png -- one nano-banana render of the
         two armies' infantry cog, side by side on a flat chroma backdrop
         (gemini-2.5-flash-image, prompt in scripts/art/README.md).
Output : data/unit_red.png, data/unit_blue.png -- 128 px squares with alpha.

Gemini does not return alpha, and the "pure green" you asked for comes back as
SOME green with a tinted edge. So: take the backdrop colour as the MEDIAN of the
border (corners sometimes carry a smudge), flood-fill from the border so a green
accent inside a character survives, split the row on empty columns, and pad each
part to a square before resizing.
"""

import os
import statistics
import sys

from PIL import Image

ROLES = ["red", "blue"]
SOURCE = "scripts/art/source/soldiers_sheet.png"
OUT_DIR = "data"
OUT_SIZE = 128
TOLERANCE = 60
PAD = 6


def border_colour(image):
    width, height = image.size
    pixels = image.load()
    samples = []
    for x in range(width):
        samples.append(pixels[x, 0][:3])
        samples.append(pixels[x, height - 1][:3])
    for y in range(height):
        samples.append(pixels[0, y][:3])
        samples.append(pixels[width - 1, y][:3])
    return tuple(
        int(statistics.median(channel[i] for channel in samples))
        for i in range(3))


def close_to(a, b, tolerance):
    return sum((int(a[i]) - int(b[i])) ** 2 for i in range(3)) <= tolerance ** 2


def key_backdrop(image):
    """Flood-fill the backdrop from the border and make it transparent."""
    image = image.convert("RGBA")
    width, height = image.size
    pixels = image.load()
    key = border_colour(image)
    stack = []
    for x in range(width):
        stack.append((x, 0))
        stack.append((x, height - 1))
    for y in range(height):
        stack.append((0, y))
        stack.append((width - 1, y))
    seen = bytearray(width * height)
    while stack:
        x, y = stack.pop()
        if x < 0 or y < 0 or x >= width or y >= height:
            continue
        index = y * width + x
        if seen[index]:
            continue
        seen[index] = 1
        if not close_to(pixels[x, y], key, TOLERANCE):
            continue
        pixels[x, y] = (0, 0, 0, 0)
        stack.extend([(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)])
    return image


def column_is_empty(pixels, x, height):
    for y in range(height):
        if pixels[x, y][3] > 8:
            return False
    return True


def split_row(image, parts):
    width, height = image.size
    pixels = image.load()
    spans = []
    x = 0
    while x < width:
        if column_is_empty(pixels, x, height):
            x += 1
            continue
        start = x
        while x < width and not column_is_empty(pixels, x, height):
            x += 1
        spans.append((start, x))
    spans.sort(key=lambda span: span[1] - span[0], reverse=True)
    spans = sorted(spans[:parts])
    if len(spans) != parts:
        raise SystemExit(
            f"expected {parts} figures in the sheet, found {len(spans)}")
    return [image.crop((start, 0, stop, height)) for start, stop in spans]


def trim_and_pad(part):
    box = part.getbbox()
    if box is None:
        raise SystemExit("a split figure is entirely transparent")
    part = part.crop(box)
    side = max(part.size) + PAD * 2
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(
        part, ((side - part.width) // 2, (side - part.height) // 2), part)
    return square.resize((OUT_SIZE, OUT_SIZE), Image.LANCZOS)


def main():
    if not os.path.exists(SOURCE):
        raise SystemExit(f"missing {SOURCE}")
    sheet = key_backdrop(Image.open(SOURCE))
    parts = split_row(sheet, len(ROLES))
    for role, part in zip(ROLES, parts):
        out = os.path.join(OUT_DIR, f"unit_{role}.png")
        trim_and_pad(part).save(out)
        print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
