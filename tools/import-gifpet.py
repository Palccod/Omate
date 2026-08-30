#!/usr/bin/env python3
"""Convert animated-GIF desktop pets (vscode-pets media layout) into
Omate character packs.

Input: a directory of <anim>.gif files — multi-frame GIFs, one animation
each. Known animations and their Omate counterparts:

    idle -> idle      lie           -> sleep
    walk -> walk      swipe         -> poke
                      fall_from_grab-> fall
                      wallclimb     -> climb

Omitted animations simply stay out of pack.json, where PetSprite's
fallback chain picks something sensible (fall -> drag -> idle,
sleep/poke/climb -> idle/walk).

GIF canvas sizes may differ per animation, so every frame is unified onto
one bottom-center canvas — pets are drawn standing on the frame bottom,
which keeps that convention intact. --flip mirrors all frames for artists
who drew their pet facing left (Omate's base faces right).

Requires Pillow for GIF decoding.

usage:
  import-gifpet.py <gif-dir> <out-pack-dir> "Display Name"
      [--flip] [--author "..."]
"""

import argparse
import json
import statistics
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    raise SystemExit("Pillow is required: pip install pillow")

# <gif basename> -> <Omate animation name>
ANIMS = {
    "idle": "idle",
    "walk": "walk",
    "lie": "sleep",
    "swipe": "poke",
    "fall_from_grab": "fall",
    "wallclimb": "climb",
}


def decode_frames(path):
    """Return (frames as list of RGBA byte rows, size, median delay ms)."""
    im = Image.open(path)
    frames = []
    delays = []
    for i in range(getattr(im, "n_frames", 1)):
        im.seek(i)
        frames.append(im.convert("RGBA"))
        delays.append(im.info.get("duration", 100) or 100)
    delay = int(statistics.median(delays))
    return frames, im.size, delay


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("src", type=Path, help="directory of <anim>.gif files")
    ap.add_argument("out", type=Path, help="output pack directory")
    ap.add_argument("name", help='display name, e.g. "Totoro"')
    ap.add_argument("--flip", action="store_true",
                    help="mirror every frame (art faces left)")
    ap.add_argument("--author", default="vscode-pets project")
    args = ap.parse_args()

    anims = {}
    delays = {}
    for src, dst in ANIMS.items():
        gif = args.src / f"{src}.gif"
        if not gif.is_file():
            continue
        frames, size, delay = decode_frames(gif)
        anims[dst] = frames
        delays[dst] = delay
        print(f"  {src} -> {dst}: {len(frames)} frames {size[0]}x{size[1]} "
              f"@{delay}ms")
    if not anims:
        raise SystemExit(f"{args.src}: no known animation GIFs found")

    # One shared canvas, pets standing on the bottom edge.
    canvas_w = max(f.width for frames in anims.values() for f in frames)
    canvas_h = max(f.height for frames in anims.values() for f in frames)

    sprites_dir = args.out / "sprites"
    sprites_dir.mkdir(parents=True, exist_ok=True)
    pack_anims = {}
    summary = []
    content_h = 0
    for dst, frames in anims.items():
        names = []
        for i, frame in enumerate(frames):
            canvas = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))
            canvas.paste(frame, ((canvas_w - frame.width) // 2,
                                 canvas_h - frame.height))
            if args.flip:
                canvas = canvas.transpose(Image.FLIP_LEFT_RIGHT)
            # Content height (opaque rows) drives the default scale.
            bbox = canvas.getbbox()
            if bbox:
                content_h = max(content_h, bbox[3] - bbox[1])
            fname = f"{dst}_{i:02d}.png"
            canvas.save(sprites_dir / fname)
            names.append(fname)
        lo, hi = (100, 1200) if dst in ("idle", "sleep") else (80, 400)
        ms = max(lo, min(hi, delays[dst]))
        pack_anims[dst] = {"frames": names, "frameMs": ms}
        summary.append(f"{dst}={len(names)}f@{ms}ms")

    if content_h >= 140:
        default_scale = 1
    elif content_h >= 60:
        default_scale = 2
    else:
        default_scale = 3

    pack = {
        "name": args.name,
        "author": args.author,
        "width": canvas_w,
        "height": canvas_h,
        "defaultScale": default_scale,
        "anims": pack_anims,
    }
    (args.out / "pack.json").write_text(json.dumps(pack, indent=2) + "\n")

    n = args.name
    messages = {
        "greet": [f"{n} scurries in!"],
        "idle": [f"{n} looks around curiously.", "quite a nice desktop.",
                 f"psst — pet {n}?"],
        "drag": ["Whoa— put me down!", "Hey, I was walking here!"],
        "pet": ["happy noises.", "more of that, please."],
        "poke": ["!?", "boop."],
        "land": ["stuck the landing."],
        "dizzy": ["...everything is spinning."],
        "sleep": ["zzz..."],
        "wake": ["I'm up! I'm up."],
        "hop": ["wheee!"],
    }
    (args.out / "messages.json").write_text(
        json.dumps(messages, indent=2, ensure_ascii=False) + "\n")

    print(f"\n{args.name}: {args.out}")
    print(f"  canvas {canvas_w}x{canvas_h}, content ~{content_h}px tall, "
          f"scale {default_scale}x, " + ", ".join(summary))


if __name__ == "__main__":
    main()
