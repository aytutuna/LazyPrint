"""Writes the Get-Printer-Attributes responses the IPP tests read (Tests/Fixtures/Ipp/printers/*.bin) from the
readable attribute lists beside them (*.json). The lists are modelled on what printers of four makers report; a response
captured from a real printer goes next to them as captured-*.bin and is not touched here. The encoder is written
separately from the C# and Swift codecs on purpose, so the tests do not only check a codec against itself.

A list is {"version", "status", "requestId", "operation": [attribute], "printer": [attribute]}, an attribute
{"name", "type", "values"}. Types: integer, boolean, enum, octets (text), resolution ([x, y, units]), range ([low, high]),
text, name, keyword, uri, uriScheme, charset, language, mimeType, textWithLanguage and nameWithLanguage ([language, text]),
collection (each value a list of member attributes), unsupported, unknown, noValue (no values).

Usage: python scripts/make_ipp_fixtures.py [directory]
"""

import json
import os
import struct
import sys

TAGS = {
    "unsupported": 0x10, "unknown": 0x12, "noValue": 0x13, "integer": 0x21, "boolean": 0x22, "enum": 0x23,
    "octets": 0x30, "resolution": 0x32, "range": 0x33, "textWithLanguage": 0x35, "nameWithLanguage": 0x36,
    "text": 0x41, "name": 0x42, "keyword": 0x44, "uri": 0x45, "uriScheme": 0x46, "charset": 0x47, "language": 0x48,
    "mimeType": 0x49,
}
STRINGS = ("octets", "text", "name", "keyword", "uri", "uriScheme", "charset", "language", "mimeType")


def value_bytes(type_, value):
    if type_ in ("integer", "enum"):
        return struct.pack(">i", value)
    if type_ == "boolean":
        return bytes([1 if value else 0])
    if type_ == "resolution":
        return struct.pack(">iiB", *value)
    if type_ == "range":
        return struct.pack(">ii", *value)
    if type_ in ("textWithLanguage", "nameWithLanguage"):
        language, text = (s.encode("utf-8") for s in value)
        return struct.pack(">H", len(language)) + language + struct.pack(">H", len(text)) + text
    if type_ in STRINGS:
        return value.encode("utf-8")
    return b""


def entry(tag, name, value):
    name = name.encode("utf-8")
    return bytes([tag]) + struct.pack(">H", len(name)) + name + struct.pack(">H", len(value)) + value


def attribute(attr):
    """The attribute as a list of entries, so a collection member can drop the name of its first."""
    type_ = attr["type"]
    values = attr["values"] or [None]
    chunks = []
    for n, value in enumerate(values):
        name = attr["name"] if n == 0 else ""
        if type_ == "collection":
            chunks.append(entry(0x34, name, b""))
            for member in value:
                chunks.append(entry(0x4A, "", member["name"].encode("utf-8")))
                member_chunks = attribute(member)
                chunks.extend(strip_name(c) if k == 0 else c for k, c in enumerate(member_chunks))
            chunks.append(entry(0x37, "", b""))
        else:
            chunks.append(entry(TAGS[type_], name, value_bytes(type_, value)))
    return chunks


def strip_name(chunk):
    """Rewrites an entry with an empty name: a member's first value follows its memberAttrName."""
    length = struct.unpack(">H", chunk[1:3])[0]
    return chunk[:1] + b"\x00\x00" + chunk[3 + length:]


def message(spec):
    major, minor = (int(n) for n in spec["version"].split("."))
    out = struct.pack(">BBHi", major, minor, spec["status"], spec["requestId"])
    for tag, key in ((0x01, "operation"), (0x04, "printer")):
        out += bytes([tag])
        for attr in spec[key]:
            out += b"".join(attribute(attr))
    return out + b"\x03"


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    directory = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "Tests", "Fixtures", "Ipp", "printers")
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(directory, name), encoding="utf-8") as f:
            data = message(json.load(f))
        target = os.path.join(directory, name[:-5] + ".bin")
        with open(target, "wb") as out:
            out.write(data)
        print("wrote %s (%d bytes)" % (target, len(data)))


if __name__ == "__main__":
    main()
