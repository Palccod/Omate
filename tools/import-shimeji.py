#!/usr/bin/env python3
"""Convert a Shimeji-ee mascot into an Omate character pack.

Shimeji-ee packs ship a group-finity "Mascot" XML describing animations as
pose lists, next to loose shime*.png art. Both the English shimeji-ee
dialect (actions.xml) and the original Japanese one (動作.xml, element
names アクション/ポーズ/画像) are understood — the actions file is found
by structure, so mojibake or renamed conf files work too. The animations
Omate needs are mapped from either name table:

    Stand        -> idle      Pinched + Resisting -> drag
    Walk         -> walk      Falling/Fall        -> fall
    Sit          -> sit       LieDown             -> sleep + lie
    Jumping      -> jump      Bouncing            -> land
    Tripping     -> poke (click reaction)

Omitted animations simply stay out of pack.json, where PetSprite's fallback
chain (fall -> drag -> idle, sleep/sit/lie -> idle) picks something
sensible.

Two format quirks are handled here rather than at runtime:

- Shimeji art is anchor-aligned and variable-size (each pose carries an
  ImageAnchor marking its foot point). Frames are re-canonized onto one
  uniform canvas with the feet on the same spot, so walk bounce survives
  and PetSprite's aspect-fit rendering never jitters.
- Shimeji base art faces LEFT; Omate's base faces right. Every frame is
  mirrored horizontally at import.

For conf-less image dumps that follow the standard 46-slot template (bare
shime*.png with no XML), pass another pack's actions.xml via --conf: the
standard slots are shared across all template sets.

usage:
  import-shimeji.py <extracted-root> <out-pack-dir> "Display Name"
      [--conf actions.xml] [--author "..."]
"""

import argparse
import importlib.util
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

TOOLS = Path(__file__).parent


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, TOOLS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gs = _load("omate_gen_sprites", "gen-sprites.py")
imp = _load("omate_import_sheet", "import-spritesheet.py")
read_png = imp.read_png
write_png = gs.write_png

# Per-animation frame-timing clamps, in milliseconds. Shimeji Duration is
# in 40 ms engine ticks; the shortest pose drives the cycle speed.
TIMING = {
    "idle": (250, 800),
    "walk": (80, 250),
    "fall": (80, 300),
    "drag": (100, 300),
    "sleep": (500, 2000),
    "sit": (400, 1500),
    "lie": (400, 1500),
    "jump": (80, 200),
    "land": (200, 600),
    "poke": (100, 300),
}
# Pose caps keep odd packs with huge variant lists manageable.
CAPS = {"idle": 10, "walk": 12, "fall": 6, "drag": 16, "sleep": 4,
        "sit": 6, "lie": 4, "jump": 6, "land": 4, "poke": 5}

# English and Japanese names for the same actions, tried in order. The
# original group-finity format names actions in Japanese; shimeji-ee
# translated them to English (sometimes with extra variants). Sleeping
# prefers the lying pose and falls back to sitting; "land" is the
# landing-bounce action, used as the ground-impact pose.
ALIASES = {
    "idle": ["stand", "立つ"],
    "walk": ["walk", "歩く"],
    "fall": ["falling", "落下する", "fall", "落ちる"],
    "drag": ["pinched", "つままれる", "resisting", "抵抗する"],
    "sleep": ["sleep", "寝る", "liedown", "寝そべる", "sprawl", "sit", "座る"],
    "sit": ["sit", "座る", "sitdown", "座ってボーっとする"],
    "lie": ["liedown", "寝そべる", "sprawl", "寝そべってボーっとする"],
    "jump": ["jumping", "ジャンプ", "jump", "bouncing", "跳ねる"],
    "land": ["bouncing", "跳ねる"],
    # Click reaction: the stumble art, so poking the mate gets a response.
    "poke": ["tripping", "転ぶ"],
}


def localname(tag):
    return tag.rsplit("}", 1)[-1]


def attr(el, *names):
    for n in names:
        if n in el.attrib:
            return el.attrib[n]
    return None


def name_of(el):
    """Action name in either dialect (shimeji-ee Name, group-finity 名前)."""
    return attr(el, "Name", "名前")


def parse_actions(xml_path):
    """Read a Mascot actions file into {lowercase name: [animation, ...]}
    where each animation is a list of {img, ax, ay, dur} poses. Accepts the
    English shimeji-ee dialect and the original Japanese one."""
    tree = ET.parse(str(xml_path))
    actions = {}
    for el in tree.getroot().iter():
        if localname(el.tag) not in ("Action", "動作"):
            continue
        name = name_of(el)
        if not name:
            continue
        anims = actions.setdefault(name.lower(), [])
        for anim in el:
            if localname(anim.tag) not in ("Animation", "アニメーション"):
                continue
            poses = []
            for pose in anim:
                if localname(pose.tag) not in ("Pose", "ポーズ"):
                    continue
                img = attr(pose, "Image", "画像")
                if not img:
                    continue
                anchor = (attr(pose, "ImageAnchor", "基準座標")
                          or "0,0").split(",")[:2]
                try:
                    ax, ay = int(float(anchor[0])), int(float(anchor[1]))
                except ValueError:
                    ax = ay = 0
                try:
                    dur = int(float(attr(pose, "Duration", "長さ") or 1))
                except ValueError:
                    dur = 1
                poses.append({"img": img.lstrip("/"), "ax": max(0, ax),
                              "ay": max(0, ay), "dur": max(1, dur)})
            if poses:
                anims.append(poses)
    return actions


def take(actions, names, limit, first_only=False):
    """Flatten actions into at most `limit` poses. By default aliases are
    tried in order and fill the cap together (Pinched + Resisting); with
    first_only, the first alias that has any poses wins outright (sleep
    must not mix a lying pose with sitting ones)."""
    out = []
    for name in names:
        for poses in actions.get(name, []):
            out.extend(poses)
            if len(out) >= limit:
                return out[:limit]
        if first_only and out:
            return out[:limit]
    return out[:limit]


def build_anims(actions):
    anims = {key: take(actions, names, CAPS[key], first_only=key == "sleep")
             for key, names in ALIASES.items()}
    # Drop consecutive duplicates (Resisting lists the same pair repeatedly)
    # and empty animations.
    result = {}
    for key, poses in anims.items():
        deduped = [p for i, p in enumerate(poses)
                   if i == 0 or p["img"] != poses[i - 1]["img"]]
        if deduped:
            result[key] = deduped
    return result


def frame_ms(anim, poses):
    lo, hi = TIMING[anim]
    shortest = min(p["dur"] for p in poses) * 40
    return max(lo, min(hi, shortest))


def find_img_dir(root):
    img = root / "img"
    if img.is_dir():
        # The mascot's own subfolder wins (img/ itself often holds banners
        # and icons next to it); loose PNGs are the fallback layout.
        for sub in sorted(img.iterdir()):
            if sub.is_dir() and list(sub.glob("*.png")):
                return sub
        if list(img.glob("*.png")):
            return img
    if list(root.glob("*.png")):
        return root
    raise SystemExit(f"{root}: no mascot images found (looked in img/ and img/*/ and .)")


def looks_like_actions(path):
    """True when the XML defines actions with poses (rules out the sibling
    behaviors file, XSDs and logging configs whatever they are named)."""
    try:
        tree = ET.parse(str(path))
    except ET.ParseError:
        return False
    for el in tree.getroot().iter():
        if (localname(el.tag) in ("Action", "動作")
                and any(localname(p.tag) in ("Pose", "ポーズ")
                        for p in el.iter())):
            return True
    return False


def find_actions_xml(root, img_dir, explicit):
    if explicit:
        path = Path(explicit)
        if not path.is_file():
            raise SystemExit(f"{path}: --conf file not found")
        return path
    candidates = list(root.glob("*.xml")) + list(root.glob("conf/*.xml")) \
        + list(img_dir.glob("*.xml")) + list(img_dir.glob("conf/*.xml")) \
        + sorted(root.rglob("*.xml"))
    for candidate in candidates:
        if candidate.is_file() and looks_like_actions(candidate):
            return candidate
    return None


def compose_frame(canvas_w, canvas_h, art, ax, ay, left, up):
    """Paste one pose onto the shared canvas so its anchor lands on the
    common foot point, then mirror it (shimeji faces left, Omate right)."""
    buf = bytearray(canvas_w * canvas_h * 4)
    px, py = left - ax, up - ay
    aw, ah, apix = art
    for y in range(ah):
        ty = py + y
        if ty < 0 or ty >= canvas_h:
            continue
        row = apix[y * aw * 4:(y + 1) * aw * 4]
        for x in range(aw):
            tx = px + x
            if tx < 0 or tx >= canvas_w:
                continue
            o = (ty * canvas_w + tx) * 4
            s = x * 4
            if row[s + 3] > 0:
                buf[o:o + 4] = row[s:s + 4]
    # Mirror horizontally.
    out = bytearray(canvas_w * canvas_h * 4)
    for y in range(canvas_h):
        base = y * canvas_w * 4
        for x in range(canvas_w):
            so = base + x * 4
            to = base + (canvas_w - 1 - x) * 4
            out[to:to + 4] = buf[so:so + 4]
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("root", type=Path, help="extracted pack directory")
    ap.add_argument("out", type=Path, help="output pack directory")
    ap.add_argument("name", help='display name, e.g. "Hornet"')
    ap.add_argument("--conf", help="actions.xml to borrow (conf-less template sets)")
    ap.add_argument("--author", default="Shimeji-ee community")
    args = ap.parse_args()

    img_dir = find_img_dir(args.root)
    actions_path = find_actions_xml(args.root, img_dir, args.conf)
    if actions_path is None:
        raise SystemExit(f"{args.root}: no actions.xml found "
                         f"(pass one with --conf for template-only sets)")
    print(f"mascot images: {img_dir}")
    print(f"actions: {actions_path}")

    actions = parse_actions(actions_path)
    anims = build_anims(actions)
    if not anims:
        raise SystemExit("no usable animations found (need at least Stand)")

    # Load every referenced pose image once; missing files drop their pose.
    # Image names resolve case-insensitively: template sets mix shimeN.png
    # and ShimeN.png capitalizations.
    lower_map = {p.name.lower(): p for p in img_dir.glob("*.png")}
    art_cache = {}
    for key, poses in list(anims.items()):
        kept = []
        for pose in poses:
            path = lower_map.get(pose["img"].lower())
            if pose["img"] not in art_cache:
                if path is None or not path.is_file():
                    print(f"  skipping missing image {pose['img']}")
                    continue
                art_cache[pose["img"]] = read_png(path)
            pose["art"] = art_cache[pose["img"]]
            kept.append(pose)
        if kept:
            anims[key] = kept
        else:
            del anims[key]
    anims = {k: anims[k] for k in ("idle", "walk", "drag", "fall", "sleep",
                                   "sit", "lie", "jump", "land", "poke")
             if k in anims}

    # Shared canvas. The foot line (max anchor height) is recorded as
    # pack.json's footY so the runtime can draw the feet exactly on the
    # floor instead of on the canvas bottom: some poses carry content below
    # their anchor, and padding every frame with it would leave the mate
    # hovering. Horizontal padding is asymmetric (max content left/right of
    # the anchor) to keep wide drag poses from inflating the frame.
    left = 0
    right = 0
    up = 0
    down = 0
    for poses in anims.values():
        for pose in poses:
            w, h, _ = pose["art"]
            left = max(left, pose["ax"])
            right = max(right, w - pose["ax"])
            up = max(up, pose["ay"])
            down = max(down, h - pose["ay"])
    canvas_w = left + right
    canvas_h = up + down

    sprites_dir = args.out / "sprites"
    sprites_dir.mkdir(parents=True, exist_ok=True)
    pack_anims = {}
    summary = []
    for key, poses in anims.items():
        frames = []
        for i, pose in enumerate(poses):
            fname = f"{key}_{i:02d}.png"
            write_png(sprites_dir / fname,
                      compose_frame(canvas_w, canvas_h, pose["art"],
                                    pose["ax"], pose["ay"], left, up),
                      canvas_w, canvas_h)
            frames.append(fname)
        pack_anims[key] = {"frames": frames, "frameMs": frame_ms(key, poses)}
        summary.append(f"{key}={len(frames)}f@{pack_anims[key]['frameMs']}ms")

    # Anti-aliased shimeji art runs 100-160 px tall: at 1x it sits nicely
    # between the tiny cat and a 2x Miku. Smaller art gets magnified.
    default_scale = 1 if up >= 100 else (2 if up >= 48 else 3)

    pack = {
        "name": args.name,
        "author": args.author,
        "width": canvas_w,
        "height": canvas_h,
        "footY": up,
        "defaultScale": default_scale,
        "anims": pack_anims,
    }
    (args.out / "pack.json").write_text(json.dumps(pack, indent=2) + "\n")

    # Starter messages; per-character lines can be edited in place after.
    n = args.name
    messages = {
        "greet": [f"{n} reporting for duty!"],
        "idle": [f"{n} is watching your window count.",
                 "quite the desktop you have here.",
                 f"psst — pet {n}?"],
        "drag": ["Whoa— careful!", "Put me dooown!"],
        "pet": ["hey, that's nice.", "more of that, please."],
        "poke": ["hey!", "boop."],
        "land": ["stuck the landing."],
        "dizzy": ["...the floor attacked."],
        "sleep": ["nap time..."],
        "wake": ["I'm up, I'm up!"],
        "hop": ["warp!", "poof!"],
    }
    (args.out / "messages.json").write_text(
        json.dumps(messages, indent=2, ensure_ascii=False) + "\n")

    print(f"\n{args.name}: {args.out}")
    print(f"  canvas {canvas_w}x{canvas_h} (feet at y={up}), "
          f"scale {pack['defaultScale']}x, " + ", ".join(summary))


if __name__ == "__main__":
    main()
