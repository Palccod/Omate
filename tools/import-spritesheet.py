#!/usr/bin/env python3
"""Omate sprite-pack importer: MikuPet-style character dirs -> Omate packs.

Input: a directory containing character.json (MikuPet format: horizontal
sprite strips + LibreSprite/aseprite JSON metadata), like:

    character.json
    idle.png        idle.json      # strip + frame metadata
    walk_right.png  walk.json
    dragging.png    dragging.json

Output: an Omate pack (pack.json + sprites/*.png) with every frame sliced
out and padded to one shared canvas, bottom-aligned so feet stay on the
ground across animations of different frame sizes.

Pure stdlib: PNG decoding/encoding is zlib + struct, no ImageMagick/PIL.

Usage:
    tools/import-spritesheet.py <character-dir> <output-pack-dir> [name]
"""

import importlib.util
import json
import struct
import sys
import zlib
from pathlib import Path

# The shared PNG encoder lives in gen-sprites.py; the dash in its name means
# it needs a location-based import rather than a plain module import.
_spec = importlib.util.spec_from_file_location(
    "omate_gen_sprites", Path(__file__).resolve().parent / "gen-sprites.py")
_gs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_gs)
write_png = _gs.write_png


def read_png(path):
    """Decode a non-interlaced 8-bit PNG into (width, height, RGBA pixels)."""
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path}: not a PNG")
    pos = 8
    width = height = bit_depth = color_type = None
    idat = b""
    palette = None
    while pos < len(data):
        length, tag = struct.unpack(">I4s", data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if tag == b"IHDR":
            width, height, bit_depth, color_type = struct.unpack(">IIBB", chunk[:10])
        elif tag == b"PLTE":
            palette = [tuple(chunk[i:i + 3]) for i in range(0, len(chunk), 3)]
        elif tag == b"IDAT":
            idat += chunk
        elif tag == b"IEND":
            break
    if bit_depth != 8:
        raise SystemExit(f"{path}: unsupported bit depth {bit_depth} (need 8)")
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(color_type)
    if channels is None:
        raise SystemExit(f"{path}: unsupported color type {color_type}")

    raw = zlib.decompress(idat)
    stride = width * channels
    out = bytearray(width * height * 4)
    prev = bytearray(stride)
    pos = 0
    for y in range(height):
        filt = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        if filt == 1:  # Sub
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif filt == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif filt == 3:  # Average
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif filt == 4:  # Paeth
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        elif filt != 0:
            raise SystemExit(f"{path}: bad filter {filt}")
        prev = line
        for x in range(width):
            o = (y * width + x) * 4
            if color_type == 6:
                out[o:o + 4] = line[x * 4:x * 4 + 4]
            elif color_type == 2:
                out[o:o + 3] = line[x * 3:x * 3 + 3]
                out[o + 3] = 255
            elif color_type == 0:
                g = line[x]
                out[o:o + 3] = bytes((g, g, g))
                out[o + 3] = 255
            elif color_type == 4:
                g = line[x * 2]
                out[o:o + 3] = bytes((g, g, g))
                out[o + 3] = line[x * 2 + 1]
            elif color_type == 3:
                r, g, b = palette[line[x]]
                out[o:o + 4] = bytes((r, g, b, 255))
    return width, height, bytes(out)


def crop(pixels, width, x, y, w, h):
    out = bytearray(w * h * 4)
    for row in range(h):
        src = ((y + row) * width + x) * 4
        dst = row * w * 4
        out[dst:dst + w * 4] = pixels[src:src + w * 4]
    return bytes(out)


def bottom_pad(pixels, w, h, canvas_w, canvas_h):
    """Center horizontally, pin to the canvas floor: feet stay aligned."""
    out = bytearray(canvas_w * canvas_h * 4)
    x0 = (canvas_w - w) // 2
    y0 = canvas_h - h
    for row in range(h):
        src = row * w * 4
        dst = ((y0 + row) * canvas_w + x0) * 4
        out[dst:dst + w * 4] = pixels[src:src + w * 4]
    return bytes(out)


# Source anim names -> Omate anim names. walk_left is redundant: Omate
# mirrors the walk animation itself.
ANIM_MAP = {
    "idle": "idle",
    "walk_right": "walk",
    "walk": "walk",
    "dragging": "drag",
    "drag": "drag",
    "fall": "fall",
    "sleep": "sleep",
    "sit": "sit",
}


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    src_dir = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    name = sys.argv[3] if len(sys.argv) > 3 else None

    char = json.loads((src_dir / "character.json").read_text())
    name = name or char.get("name") or src_dir.name

    anims = {}       # target -> {"frames": [(pixels, w, h)], "fps": n}
    for anim, meta in char.get("animations", {}).items():
        target = ANIM_MAP.get(anim)
        if target is None or target in anims:
            continue
        metadata = json.loads((src_dir / meta["metadata"]).read_text())
        width, height, pixels = read_png(src_dir / meta["file"])
        frames = []
        for frame in metadata["frames"].values():
            f = frame["frame"]
            frames.append((crop(pixels, width, f["x"], f["y"], f["w"], f["h"]),
                           f["w"], f["h"]))
        anims[target] = {"frames": frames, "fps": meta.get("fps")}

    if "idle" not in anims:
        raise SystemExit("character.json has no idle animation")

    canvas_w = max(f[1] for a in anims.values() for f in a["frames"])
    canvas_h = max(f[2] for a in anims.values() for f in a["frames"])

    sprites_dir = out_dir / "sprites"
    sprites_dir.mkdir(parents=True, exist_ok=True)
    pack_anims = {}
    for target, anim in anims.items():
        files = []
        for i, (pixels, w, h) in enumerate(anim["frames"]):
            fname = f"{target}_{i:02d}.png"
            write_png(sprites_dir / fname,
                      bottom_pad(pixels, w, h, canvas_w, canvas_h),
                      canvas_w, canvas_h)
            files.append(fname)
        pack_anims[target] = {
            "frames": files,
            "frameMs": int(round(1000 / anim["fps"])) if anim.get("fps") else 120,
        }

    pack = {
        "name": name,
        "author": char.get("author", ""),
        "width": canvas_w,
        "height": canvas_h,
        "defaultScale": 2 if canvas_h > 64 else 3,
        "anims": pack_anims,
    }
    (out_dir / "pack.json").write_text(json.dumps(pack, indent=2) + "\n")
    summary = ", ".join("%s=%df" % (t, len(a["frames"])) for t, a in anims.items())
    print("wrote pack '%s' to %s (%dx%d, %d anims: %s)"
          % (name, out_dir, canvas_w, canvas_h, len(pack_anims), summary))


if __name__ == "__main__":
    main()
