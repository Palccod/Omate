#!/usr/bin/env python3
"""Omate sound generator: tiny synthesized WAV blips, stdlib only.

Every sound is a few cents of sine waves with envelopes — designed to be
soft enough for a desktop companion, and to be replaced wholesale by
dropping better files into sounds/ (the QML only knows the file names).

Usage:  tools/gen-sounds.py
"""

import math
import struct
import wave
from pathlib import Path

RATE = 22050


def env(t, dur, attack=0.008, release=0.6):
    """Attack/decay envelope: quick fade-in, exponential-ish fade-out."""
    if t < attack:
        return t / attack
    progress = (t - attack) / max(0.001, dur - attack)
    return math.exp(-4 * progress * release)


def tone(dur, freq, amp=0.4, wobble=0.0, wobble_hz=0.0, slide=0.0, release=0.6):
    """One sine (plus a quiet octave) with optional pitch slide and AM wobble."""
    n = int(RATE * dur)
    out = []
    phase = 0.0
    for i in range(n):
        t = i / RATE
        f = freq * (2 ** (slide * t / dur))
        phase += 2 * math.pi * f / RATE
        am = 1 + wobble * math.sin(2 * math.pi * wobble_hz * t)
        s = math.sin(phase) + 0.25 * math.sin(2 * phase)
        out.append(amp * am * env(t, dur, release=release) * s / 1.25)
    return out


def mix(*layers):
    n = max(len(l) for l in layers)
    out = [0.0] * n
    for layer in layers:
        for i, v in enumerate(layer):
            out[i] += v
    return out


def concat(*layers):
    out = []
    for layer in layers:
        out += layer
    return out


def clip(samples, limit=0.85):
    return [max(-limit, min(limit, s)) for s in samples]


def write(path, samples):
    with wave.open(str(path), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        frames = b"".join(struct.pack("<h", int(s * 32767)) for s in samples)
        f.writeframes(frames)


SOUNDS = {
    # Picked up: a quick soft chirp going up.
    "grab.wav": tone(0.14, 340, amp=0.30, slide=0.9, release=0.9),
    # Purring: a low rumble with the classic ~24 Hz purr rhythm.
    "pet.wav": clip(tone(0.55, 62, amp=0.42, wobble=0.55, wobble_hz=24, release=0.35)
                    + [0.0] * int(RATE * 0.1)),
    # Poked: two bright little notes, a startled "mew".
    "poke.wav": concat(tone(0.09, 660, amp=0.22, release=1.2),
                       tone(0.11, 880, amp=0.24, release=1.0)),
    # Landing: a low thud.
    "land.wav": tone(0.13, 96, amp=0.45, slide=-0.35, release=1.4),
    # Dozing off: two soft descending notes.
    "zzz.wav": concat(tone(0.28, 330, amp=0.16, release=0.5),
                      tone(0.32, 262, amp=0.14, release=0.4)),
    # Waking: two rising notes, a question.
    "wake.wav": concat(tone(0.14, 392, amp=0.2, release=1.0),
                       tone(0.18, 523, amp=0.22, release=0.7)),
}


def main():
    sounds_dir = Path(__file__).resolve().parent.parent / "sounds"
    sounds_dir.mkdir(parents=True, exist_ok=True)
    for name, samples in SOUNDS.items():
        write(sounds_dir / name, clip(samples))
    print(f"wrote {len(SOUNDS)} sounds to {sounds_dir}")


if __name__ == "__main__":
    main()
