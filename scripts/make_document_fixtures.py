"""Writes the small documents the app's tests open (Tests/Fixtures/Documents): PDFs written by hand, so no PDF library
decides what they contain, pictures with Pillow, and a locked PDF made by pypdf from one of them.

Usage: python scripts/make_document_fixtures.py [directory]
"""

import io
import os
import sys

from PIL import Image
from pypdf import PdfReader, PdfWriter

RED, GREEN, BLUE, YELLOW = (1, 0, 0), (0, 0.6, 0), (0, 0, 1), (1, 1, 0)


def fill(colour, x, y, width, height):
    return f"{colour[0]} {colour[1]} {colour[2]} rg {x} {y} {width} {height} re f\n"


def pdf(pages):
    """pages: [(width, height, rotate, content)]. Object 1 is the catalog, 2 the page tree, then a page and its content."""
    objects = []
    kids = " ".join(f"{3 + 2 * i} 0 R" for i in range(len(pages)))
    objects.append("<< /Type /Catalog /Pages 2 0 R >>")
    objects.append(f"<< /Type /Pages /Kids [{kids}] /Count {len(pages)} >>")
    for i, (width, height, rotate, content) in enumerate(pages):
        objects.append(
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {width} {height}] /Rotate {rotate} /Contents {4 + 2 * i} 0 R >>"
        )
        objects.append(f"<< /Length {len(content)} >>\nstream\n{content}endstream")
    out = io.BytesIO()
    out.write(b"%PDF-1.4\n")
    offsets = []
    for number, body in enumerate(objects, 1):
        offsets.append(out.tell())
        out.write(f"{number} 0 obj\n{body}\nendobj\n".encode("ascii"))
    xref = out.tell()
    out.write(f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode("ascii"))
    for offset in offsets:
        out.write(f"{offset:010d} 00000 n \n".encode("ascii"))
    out.write(f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode("ascii"))
    return out.getvalue()


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "Tests", "Fixtures", "Documents")
    os.makedirs(target, exist_ok=True)

    def write(name, data):
        with open(os.path.join(target, name), "wb") as f:
            f.write(data)

    write("red-letter.pdf", pdf([(612, 792, 0, fill(RED, 0, 0, 612, 792))]))
    # Stored upright with a yellow band along its top edge; /Rotate 90 shows the band on the right.
    banded = fill(GREEN, 0, 0, 612, 792) + fill(YELLOW, 0, 692, 612, 100)
    write("rotated.pdf", pdf([(612, 792, 90, banded)]))
    write("mixed.pdf", pdf([
        (612, 792, 0, fill(RED, 0, 0, 612, 792)),
        (612, 792, 90, banded),
        (595, 842, 0, fill(BLUE, 0, 0, 595, 842)),
    ]))
    write("locked.pdf", locked(pdf([(612, 792, 0, fill(RED, 0, 0, 612, 792))])))

    # Left half red, right half blue: 600 x 300 pixels at 300 dpi is 144 x 72 points.
    halves = Image.new("RGB", (600, 300), (255, 0, 0))
    halves.paste((0, 0, 255), (300, 0, 600, 300))
    halves.save(os.path.join(target, "halves-300dpi.png"), dpi=(300, 300))
    # A density too low to be real (36 dpi) is sized as if it were 300.
    halves.resize((300, 150)).save(os.path.join(target, "halves-36dpi.png"), dpi=(36, 36))
    # Stored 400 x 200 with red on the left; its orientation tag (6, a clockwise turn) shows it 200 x 400 with red on top.
    stored = Image.new("RGB", (400, 200), (255, 0, 0))
    stored.paste((0, 0, 255), (200, 0, 400, 200))
    exif = Image.Exif()
    exif[0x0112] = 6
    stored.save(os.path.join(target, "turned.jpg"), quality=95, dpi=(150, 150), exif=exif)

    with open(os.path.join(target, "notes.txt"), "w") as f:
        f.write("Not a document Lazy Print prints.\n")


def locked(data):
    writer = PdfWriter(clone_from=PdfReader(io.BytesIO(data)))
    writer.encrypt("secret", algorithm="RC4-128")
    out = io.BytesIO()
    writer.write(out)
    return out.getvalue()


main()
