"""Draws the Microsoft Store package's tiles and logos, and the images the listing asks for, from the
same drawing as the app icon (make_ios_icon.py, which writes ios/.../AppIcon-1024.png). Only the
standard library is used.

Square files are drawn at their own size. A wide tile or a poster is the square drawing, as tall as
the tile, on a field of the icon's own blue, which the drawing fills edge to edge.

Usage: python scripts/make_store_assets.py [<store/windows folder>]
Writes Assets/ (named for the package manifest) and Listing/ (for Partner Center).
"""

import struct
import sys
import zlib
from pathlib import Path

import make_ios_icon

SCALES = (100, 125, 150, 200, 400)
TARGETS = (16, 24, 32, 48, 256)

# Manifest name, size at 100 percent.
LOGOS = (
    ("Square44x44Logo", (44, 44)),
    ("Square71x71Logo", (71, 71)),
    ("Square150x150Logo", (150, 150)),
    ("Wide310x150Logo", (310, 150)),
    ("Square310x310Logo", (310, 310)),
    ("StoreLogo", (50, 50)),
)

LISTING = (
    ("Logo-300x300", (300, 300)),
    ("Box-1080x1080", (1080, 1080)),
    ("Poster-720x1080", (720, 1080)),
)

_squares = {}
BACKGROUND = "#1769AA"


def square(size, rounded=False):
    key = (size, rounded)
    if key not in _squares:
        _squares[key] = make_ios_icon.draw(size, corner=0.22 * make_ios_icon.DESIGN if rounded else 0.0)
    return _squares[key]


def read_png(data):
    """Rows of RGBA bytes from a PNG this module's drawing wrote: 8-bit RGB or RGBA, filter 0 on every row."""
    pos, parts = 8, []
    width = height = kind = 0
    while pos < len(data):
        length, tag = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if tag == b"IHDR":
            width, height = struct.unpack(">II", body[:8])
            kind = body[9]
        elif tag == b"IDAT":
            parts.append(body)
        pos += 12 + length
    raw = zlib.decompress(b"".join(parts))
    step = 4 if kind == 6 else 3
    stride = width * step + 1
    rows = []
    for y in range(height):
        row = raw[y * stride + 1:(y + 1) * stride]
        if step == 3:
            out = bytearray(b"\xff" * (width * 4))
            for c in range(3):
                out[c::4] = row[c::3]
            row = bytes(out)
        rows.append(row)
    return width, height, rows


def write_png(width, height, rows):
    def chunk(kind, body):
        block = kind + body
        return struct.pack(">I", len(body)) + block + struct.pack(">I", zlib.crc32(block) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + row for row in rows)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def on_field(width, height, edge):
    """The square drawing of side `edge`, centred on a field of the icon's blue."""
    _, _, icon = read_png(square(edge))
    field = bytes(int(BACKGROUND[i:i + 2], 16) for i in (1, 3, 5)) + b"\xff"
    left = (width - edge) // 2
    top = (height - edge) // 2
    rows = []
    for y in range(height):
        if top <= y < top + edge:
            rows.append(field * left + icon[y - top] + field * (width - left - edge))
        else:
            rows.append(field * width)
    return write_png(width, height, rows)


def tile(width, height):
    if width == height:
        return square(width)
    return on_field(width, height, min(width, height))


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "store" / "windows")
    assets = root / "Assets"
    listing = root / "Listing"
    assets.mkdir(parents=True, exist_ok=True)
    listing.mkdir(parents=True, exist_ok=True)
    written = 0
    for name, (width, height) in LOGOS:
        for scale in SCALES:
            w, h = -(-width * scale // 100), -(-height * scale // 100)
            (assets / f"{name}.scale-{scale}.png").write_bytes(tile(w, h))
            written += 1
    for size in TARGETS:
        # Plated on the tile colour, and unplated for the taskbar and Start list, where the icon keeps its rounded corners.
        (assets / f"Square44x44Logo.targetsize-{size}.png").write_bytes(square(size))
        (assets / f"Square44x44Logo.targetsize-{size}_altform-unplated.png").write_bytes(square(size, rounded=True))
        written += 2
    for name, (width, height) in LISTING:
        (listing / f"{name}.png").write_bytes(tile(width, height))
        written += 1
    print("wrote %d files under %s" % (written, root))


if __name__ == "__main__":
    main()
