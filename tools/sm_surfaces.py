#!/usr/bin/env python3
"""Regenerate Super Metroid's SCRIPTED verification surfaces (.ymv).

Three of the surfaces the SM SA-1 campaign verifies with are deterministic
input schedules rather than human play, so they belong in code and not in a
scratchpad (see docs/SM_SA1_FINDINGS.md section 4f):

  sm-attract36k.ymv   36,000 zero-input frames: the attract/demo path.
  sm-titleskip.ymv    Start pressed DURING the title fade, which takes SM's
                      intro-SKIP path to the Zebes gunship landing, then a
                      walk for loader coverage.
  sm-play-death.ymv   Intro, Ceres arrival, five rooms, the Ridley fight
                      taken to a death, game over, CONTINUE, respawn. Built
                      by scripted blind play steered on position telemetry
                      (room $079B, x/y $0AF6/$0AFA, health $09C2).

The remaining surfaces are PLAYER RECORDINGS made in the SDL player and
cannot be regenerated from anything. Keep those somewhere durable.

Usage:
    tools/sm_surfaces.py <stock-super-metroid.sfc> [outdir]

With zig-out/bin/yamabuki-headless built, each movie is replayed once so its
end hashes can be embedded, which is what lets a later replay print
"sync verified" instead of "sync unverified".
"""

import os
import re
import struct
import subprocess
import sys
import zlib

# $4218/$4219 as one u16 (see src/core/memory/joypad.zig).
B, Y, SELECT, START = 0x8000, 0x4000, 0x2000, 0x1000
UP, DOWN, LEFT, RIGHT = 0x0800, 0x0400, 0x0200, 0x0100
A, X, L, R = 0x0080, 0x0040, 0x0020, 0x0010

MAGIC, VERSION_PLAIN, HEADER_LEN = b"YMV1", 1, 32


def hold(frames, lo, hi, mask):
    for i in range(lo, min(hi, len(frames))):
        frames[i] |= mask


def attract(n=36000):
    """No input at all: the surface the whole attract arc turns on."""
    return [0] * n


def titleskip(n=15000):
    """Start DURING the title fade, then the Zebes landing and a walk."""
    f = [0] * n
    hold(f, 1550, 1580, START)
    hold(f, 4000, 6000, RIGHT)
    hold(f, 4200, 4230, A)
    hold(f, 6000, 8000, LEFT)
    hold(f, 6500, 6530, A)
    hold(f, 8000, 8010, X)
    return f


def play_death(n=38000):
    """Through the intro to Ceres, five rooms, Ridley, death, continue.

    The shapes here are not arbitrary: the title/intro/file-select chain
    needs a Start-then-A mash because each screen waits on a different
    button; the elevator room needs a step-back-left before the drop; and
    the wide corridors need a shot cadence so door caps open as they are
    reached rather than once at the start.
    """
    f = [0] * n
    for t in range(2000, 14000, 200):  # title -> intro -> file select
        hold(f, t, t + 8, START)
        hold(f, t + 100, t + 108, A)

    hold(f, 14600, 15400, RIGHT)  # off the arrival pad
    hold(f, 15400, 15410, X)
    hold(f, 15450, 15460, X)
    hold(f, 15500, 16200, RIGHT)
    hold(f, 16200, 16600, LEFT)  # step back, then drop the shaft
    hold(f, 16600, 17000, DOWN)
    hold(f, 17000, 18400, RIGHT)

    hold(f, 18600, 20800, LEFT)  # tank corridor
    for t in (18700, 19300, 19900):
        hold(f, t, t + 30, A)

    hold(f, 20900, 23800, RIGHT)  # jump right to the arrow door
    for t in (20920, 21400, 21900):
        hold(f, t, t + 35, A)
    for t in (21600, 22400, 23000):
        hold(f, t, t + 10, X)

    direction = LEFT  # switchback staircase: alternate and let walls route
    for seg in range(23900, 26300, 800):
        hold(f, seg, seg + 800, direction)
        hold(f, seg + 20, seg + 30, X)
        direction = RIGHT if direction == LEFT else LEFT

    hold(f, 26300, 31000, RIGHT)  # wide corridor, then onward to Ridley
    for t in range(26400, 30900, 300):
        hold(f, t, t + 10, X)
    for t in range(27200, 30800, 900):
        hold(f, t, t + 30, A)
    hold(f, 31000, 37000, RIGHT)
    for t in range(31200, 36900, 400):
        hold(f, t, t + 10, X)
    for t in range(31600, 36800, 1000):
        hold(f, t, t + 30, A)
    return f


SURFACES = {
    "sm-attract36k.ymv": attract,
    "sm-titleskip.ymv": titleskip,
    "sm-play-death.ymv": play_death,
}


def stripped(path):
    """The copier-stripped image, which is what a movie's CRC32 covers."""
    data = open(path, "rb").read()
    return data[512:] if len(data) % 1024 == 512 else data


def write_movie(path, crc, masks, fb_hash=0, audio_hash=0):
    header = MAGIC + struct.pack(
        "<HBBIIQQ", VERSION_PLAIN, 0, 0, crc, len(masks), fb_hash, audio_hash
    )
    body = b"".join(struct.pack("<HH", m, 0) for m in masks)
    open(path, "wb").write(header + body)


def end_hashes(headless, rom, movie):
    """Replay once so the movie can carry hashes a later replay verifies."""
    out = subprocess.run(
        [headless, rom, "--movie", movie], capture_output=True, text=True
    ).stdout
    m = re.search(r"hash=([0-9a-f]+), audio=([0-9a-f]+)", out)
    return (int(m.group(1), 16), int(m.group(2), 16)) if m else (0, 0)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    rom = sys.argv[1]
    outdir = sys.argv[2] if len(sys.argv) > 2 else "."
    os.makedirs(outdir, exist_ok=True)

    crc = zlib.crc32(stripped(rom)) & 0xFFFFFFFF
    headless = os.path.join("zig-out", "bin", "yamabuki-headless")
    have_headless = os.path.exists(headless)
    if not have_headless:
        print(f"note: {headless} not built — writing movies without end hashes")

    for name, build in SURFACES.items():
        path = os.path.join(outdir, name)
        masks = build()
        write_movie(path, crc, masks)
        note = ""
        if have_headless:
            fb, audio = end_hashes(headless, rom, path)
            write_movie(path, crc, masks, fb, audio)
            note = f", end hashes {fb:016x}/{audio:016x}"
        print(f"wrote {path} ({len(masks)} frames, crc {crc:08x}{note})")


if __name__ == "__main__":
    main()
