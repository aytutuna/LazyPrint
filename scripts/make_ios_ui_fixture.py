"""Writes the document the iPhone app's UI tests bring in (ios/LazyPrintiOSUITests/Fixtures/report.pdf): four Letter
pages, each with a coloured band, a few grey lines like text and its number in large type, so a preview of one sheet
says which page it holds. Written by hand, no PDF library; the bytes are the same on every run.

Usage: python scripts/make_ios_ui_fixture.py [directory]
"""

import os
import sys

BANDS = [(0.20, 0.45, 0.75), (0.75, 0.35, 0.20), (0.25, 0.60, 0.35), (0.55, 0.30, 0.65)]


def page(number):
    r, g, b = BANDS[number - 1]
    out = f"{r} {g} {b} rg 54 636 504 100 re f\n0.85 0.85 0.85 rg\n"
    for line in range(9):
        width = 300 if line % 3 == 2 else 504
        out += f"54 {540 - line * 40} {width} 14 re f\n"
    out += f"0.2 0.2 0.2 rg BT /F1 72 Tf 54 120 Td (Page {number}) Tj ET\n"
    return out


def pdf(pages):
    objects = ["<< /Type /Catalog /Pages 2 0 R >>"]
    kids = " ".join(f"{4 + 2 * i} 0 R" for i in range(len(pages)))
    objects.append(f"<< /Type /Pages /Kids [{kids}] /Count {len(pages)} >>")
    objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>")
    for i, content in enumerate(pages):
        objects.append(
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
            f"/Resources << /Font << /F1 3 0 R >> >> /Contents {5 + 2 * i} 0 R >>"
        )
        objects.append(f"<< /Length {len(content)} >>\nstream\n{content}endstream")
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for number, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += f"{number} 0 obj\n{body}\nendobj\n".encode("ascii")
    xref = len(out)
    out += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode("ascii")
    for offset in offsets:
        out += f"{offset:010d} 00000 n \n".encode("ascii")
    out += f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode("ascii")
    return bytes(out)


def main():
    default = os.path.join(os.path.dirname(__file__), "..", "ios", "LazyPrintiOSUITests", "Fixtures")
    target = sys.argv[1] if len(sys.argv) > 1 else default
    os.makedirs(target, exist_ok=True)
    with open(os.path.join(target, "report.pdf"), "wb") as f:
        f.write(pdf([page(n) for n in range(1, 5)]))


main()
