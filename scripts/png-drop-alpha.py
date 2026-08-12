#!/usr/bin/env python3
"""Rewrite an 8-bit RGBA PNG as RGB, in place, without an alpha channel.

App Store Connect rejects screenshots that carry an alpha channel. Screenshots
captured by `xcrun simctl io screenshot` and by iOS itself are fully opaque but
still encode a colour type 6 (RGBA) image, so dropping the channel is lossless.

`sips` cannot do this (it has no `hasAlpha` setter and re-adds alpha on every
round trip), and the repo has no image dependency, so this uses the standard
library only. Colour-critical chunks (iCCP, cICP, sRGB, gAMA, cHRM, pHYs) are
preserved; metadata chunks such as eXIf and iTXt are dropped.

    ./scripts/png-drop-alpha.py <file.png> [...]

Exits non-zero if a file is not an 8-bit non-interlaced RGBA PNG.
"""

import struct
import sys
import zlib

SIGNATURE = b"\x89PNG\r\n\x1a\n"
KEEP_CHUNKS = {b"iCCP", b"cICP", b"sRGB", b"gAMA", b"cHRM", b"pHYs"}


def read_chunks(data):
    if data[:8] != SIGNATURE:
        raise ValueError("not a PNG")
    offset = 8
    while offset < len(data):
        (length,) = struct.unpack(">I", data[offset : offset + 4])
        kind = data[offset + 4 : offset + 8]
        payload = data[offset + 8 : offset + 8 + length]
        yield kind, payload
        offset += 12 + length
        if kind == b"IEND":
            return


def chunk(kind, payload):
    body = kind + payload
    return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body))


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def unfilter(raw, width, height, bpp):
    """Reverse the per-scanline PNG filters into flat pixel rows."""
    stride = width * bpp
    rows = []
    previous = bytearray(stride)
    position = 0
    for _ in range(height):
        filter_type = raw[position]
        line = bytearray(raw[position + 1 : position + 1 + stride])
        position += 1 + stride
        if filter_type == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif filter_type == 2:
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 0xFF
        elif filter_type == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 0xFF
        elif filter_type == 4:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                upper_left = previous[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + paeth(left, previous[i], upper_left)) & 0xFF
        elif filter_type != 0:
            raise ValueError(f"unsupported filter type {filter_type}")
        rows.append(line)
        previous = line
    return rows


def refilter(rows, stride, bpp):
    """Re-encode rows with the Up filter, which suits screenshot gradients."""
    out = bytearray()
    previous = bytearray(stride)
    for row in rows:
        out.append(2)
        out.extend((row[i] - previous[i]) & 0xFF for i in range(stride))
        previous = row
    return bytes(out)


def drop_alpha(path):
    data = open(path, "rb").read()
    header = None
    keep = []
    idat = bytearray()

    for kind, payload in read_chunks(data):
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IDAT":
            idat.extend(payload)
        elif kind in KEEP_CHUNKS:
            keep.append((kind, payload))

    if header is None:
        raise ValueError("missing IHDR")
    width, height, depth, colour, compression, filter_method, interlace = header
    if colour == 2:
        return False
    if (colour, depth, interlace) != (6, 8, 0):
        raise ValueError(
            f"expected 8-bit non-interlaced RGBA, got colour={colour} depth={depth} interlace={interlace}"
        )

    rows = unfilter(zlib.decompress(bytes(idat)), width, height, 4)
    rgb_rows = [
        bytearray(b"".join(bytes(row[i : i + 3]) for i in range(0, len(row), 4)))
        for row in rows
    ]

    body = refilter(rgb_rows, width * 3, 3)
    rebuilt = bytearray(SIGNATURE)
    rebuilt += chunk(
        b"IHDR",
        struct.pack(">IIBBBBB", width, height, 8, 2, compression, filter_method, 0),
    )
    for kind, payload in keep:
        rebuilt += chunk(kind, payload)
    rebuilt += chunk(b"IDAT", zlib.compress(body, 9))
    rebuilt += chunk(b"IEND", b"")

    open(path, "wb").write(bytes(rebuilt))
    return True


def main(argv):
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    for path in argv:
        try:
            changed = drop_alpha(path)
        except ValueError as error:
            print(f"{path}: {error}", file=sys.stderr)
            return 1
        print(f"{path}: {'alpha removed' if changed else 'already RGB'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
