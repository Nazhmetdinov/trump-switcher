#!/usr/bin/env python3
"""Pack iconset PNGs into ICNS with native ARGB for the two small 1x icons.

Recent macOS versions render PNG data in icp4/icp5 as noise. Apple's own ICNS
files use ic04/ic05 with planar, run-length-encoded ARGB for these sizes.
"""
from pathlib import Path
import struct
import sys
import zlib


def rgba_pixels(path: Path, expected_size: int) -> bytes:
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError(f"Invalid PNG: {path}")
    chunks = []
    position = 8
    dimensions = None
    while position < len(data):
        length = struct.unpack_from(">I", data, position)[0]
        kind = data[position + 4:position + 8]
        payload = data[position + 8:position + 8 + length]
        position += length + 12
        if kind == b"IHDR":
            width, height, depth, colour, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            dimensions = (width, height)
            if (width, height) != (expected_size, expected_size) or (depth, colour, compression, filtering, interlace) != (8, 6, 0, 0, 0):
                raise ValueError(f"Unsupported PNG format: {path}")
        elif kind == b"IDAT":
            chunks.append(payload)
        elif kind == b"IEND":
            break
    if dimensions is None or not chunks:
        raise ValueError(f"Incomplete PNG: {path}")
    decoded = zlib.decompress(b"".join(chunks))
    stride = expected_size * 4
    if len(decoded) != expected_size * (stride + 1):
        raise ValueError(f"Unexpected PNG data size: {path}")
    result = bytearray()
    previous = bytearray(stride)
    offset = 0
    for _ in range(expected_size):
        filter_type = decoded[offset]
        row = bytearray(decoded[offset + 1:offset + 1 + stride])
        offset += stride + 1
        for column in range(stride):
            left = row[column - 4] if column >= 4 else 0
            above = previous[column]
            upper_left = previous[column - 4] if column >= 4 else 0
            if filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = above
            elif filter_type == 3:
                predictor = (left + above) // 2
            elif filter_type == 4:
                p = left + above - upper_left
                distances = (abs(p - left), abs(p - above), abs(p - upper_left))
                predictor = (left, above, upper_left)[distances.index(min(distances))]
            elif filter_type == 0:
                predictor = 0
            else:
                raise ValueError(f"Unsupported PNG row filter: {filter_type}")
            row[column] = (row[column] + predictor) & 0xFF
        result.extend(row)
        previous = row
    return bytes(result)


def compress_plane(plane: bytes) -> bytes:
    output = bytearray()
    position = 0
    while position < len(plane):
        run = 1
        while position + run < len(plane) and plane[position + run] == plane[position] and run < 130:
            run += 1
        if run >= 3:
            output.extend((run + 125, plane[position]))
            position += run
            continue
        start = position
        position += run
        while position < len(plane) and position - start < 128:
            next_run = 1
            while position + next_run < len(plane) and plane[position + next_run] == plane[position] and next_run < 130:
                next_run += 1
            if next_run >= 3 or position - start + next_run > 128:
                break
            position += next_run
        output.append(position - start - 1)
        output.extend(plane[start:position])
    return bytes(output)


def argb_icon(path: Path, size: int) -> bytes:
    rgba = rgba_pixels(path, size)
    # PNG stores straight RGBA. ICNS wants straight A, R, G, B planes.
    return b"ARGB" + b"".join(compress_plane(rgba[offset::4]) for offset in (3, 0, 1, 2))

iconset = Path(sys.argv[1])
output = Path(sys.argv[2])
entries = [
    (b"ic07", "icon_128x128.png"),
    (b"ic08", "icon_256x256.png"),
    (b"ic09", "icon_512x512.png"),
    (b"ic10", "icon_512x512@2x.png"),
    (b"ic11", "icon_16x16@2x.png"),
    (b"ic12", "icon_32x32@2x.png"),
    (b"ic13", "icon_128x128@2x.png"),
    (b"ic14", "icon_256x256@2x.png"),
]
chunks = []
for tag, size in ((b"ic04", 16), (b"ic05", 32)):
    payload = argb_icon(iconset / f"icon_{size}x{size}.png", size)
    chunks.append(tag + struct.pack(">I", len(payload) + 8) + payload)
for tag, filename in entries:
    data = (iconset / filename).read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError(f"Invalid PNG: {filename}")
    chunks.append(tag + struct.pack(">I", len(data) + 8) + data)
body = b"".join(chunks)
output.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
print(f"Packed {len(chunks)} ICNS representations: {output}")
