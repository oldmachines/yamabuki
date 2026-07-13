#!/usr/bin/env python3
"""Capture the shader before/after figures used by the deck and the landing page.

Runs the SDL frontend once per (game, shader) pair and once more per game with no
shader at all, then writes a matched pair of images per pair:

    <game>-raw.png          the console's own output, no shader
    <game>-<shader>.jpg     the same frame, through that shader

**The two are pixel-aligned, and that is the whole point** -- the deck wipes between
them with a draggable divider, so any mismatch would show up as the picture jumping
as the divider moves. Alignment falls out of two facts:

  * The emulator is deterministic and nothing presses a button, so both runs reach an
    identical console frame. It is literally the same picture.
  * The shader is captured at `--scale N`, i.e. 256N x 224N, and the raw frame (which
    the frontend dumps at its native 256x224) is upscaled by exactly N with
    nearest-neighbour. An integer nearest upscale invents nothing; it is what "no
    shader" looks like on screen anyway, because the software path blits with
    SDL_SCALEMODE_NEAREST.

Formats differ on purpose. The raw side is pixel art -- hard edges, flat colour --
which JPEG would ring all over, so it goes to PNG (and compresses well). The shader
side is continuous tone with a phosphor mask, which PNG stores terribly and JPEG
stores well, and the deck inlines every image as a base64 data URI, so size is not
free.

Usage:
    python tools/capture_shaders.py [--roms DIR] [--out DIR] [--only GAME]

Needs: a built zig-out/bin/yamabuki-sdl(.exe), the shaders baked (`zig build shaders`),
Pillow, and a GPU that resolves to the glsl330 profile. It opens a window per run.
"""

from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("needs Pillow:  pip install pillow")

REPO = pathlib.Path(__file__).resolve().parent.parent

DEFAULT_ROMS = pathlib.Path(
    r"C:/Users/gille/Dropbox/Games/Emu/OpenEmu/Game Library/roms/Super Nintendo (SNES)"
)

# The frames were chosen by eye from a sweep (400..4400) for one property each: a
# bright saturated scene to show the mask, and three dark ones with gradients, which
# is where a CRT shader's glow and halation actually live.
GAMES = {
    "super-mario-world": {
        "rom": "Super Mario World (USA).sfc",
        "frame": 3200,
        "scale": 3,
        "title": "Super Mario World",
        # Handheld tier: cheap enough to be worth trying on a Cortex-A53.
        "shaders": ["zfast-crt", "crt-pi", "crt-lottes-fast", "crt-easymode"],
    },
    "super-castlevania-iv": {
        "rom": "Super Castlevania IV (U) [!].smc",
        "frame": 2400,
        "scale": 3,
        "title": "Super Castlevania IV",
        # Desktop tier: multi-pass, mask LUTs, a real GPU.
        "shaders": ["crt-lottes", "crt-easymode-halation", "gtu-v050", "crt-guest-advanced"],
    },
    "super-metroid": {
        "rom": "Super Metroid (JU) [!].smc",
        "frame": 2600,
        "scale": 3,
        "title": "Super Metroid",
        # The heavyweight -- and sharp-bilinear, which is not a CRT shader at all.
        #
        # crt-geom and crt-hyllian are deliberately NOT here: they bake, they compile,
        # they link, and they render a **pure black frame** on a real GPU. They are the
        # only two presets that were never run on one (the GPU session that found the
        # upside-down bug exercised crt-royale and crt-guest-advanced), and the only two
        # that need GL_ARB_arrays_of_arrays. The black is a geometry failure, not a mask
        # one: crt-geom's `corner()` returns 0 -- which zeroes the output -- whenever
        # `transform()` maps the coordinate off-screen. Uniform locations all resolve and
        # the parameters are being set, so it is not the push-constant path.
        #
        # Until that is fixed, shipping them breaks the promise the README and the deck
        # both make -- "a shader that cannot work is absent, not broken".
        "shaders": ["crt-royale", "sharp-bilinear"],
    },
    "chrono-trigger": {
        "rom": "Chrono Trigger (U) [!].smc",
        "frame": 3200,
        "scale": 4,  # the hero slider: big enough that the phosphor mask reads at ~1:1
        "title": "Chrono Trigger",
        "shaders": ["crt-royale"],
    },
}

NATIVE_W, NATIVE_H = 256, 224


def sdl_binary() -> pathlib.Path:
    for name in ("yamabuki-sdl.exe", "yamabuki-sdl"):
        p = REPO / "zig-out" / "bin" / name
        if p.exists():
            return p
    sys.exit("no zig-out/bin/yamabuki-sdl -- run `zig build` first")


def run(exe: pathlib.Path, rom: pathlib.Path, frame: int, prefix: pathlib.Path,
        scale: int, shader: str | None) -> pathlib.Path:
    """One capture. Returns the PPM the frontend wrote."""
    cmd = [
        str(exe), str(rom),
        "--frames", str(frame),
        "--shot-frames", str(frame),  # required: a bare --shot captures nothing
        "--shot", str(prefix),
        "--scale", str(scale),
        "--no-audio",
    ]
    if shader:
        cmd += ["--shader", shader]
    res = subprocess.run(cmd, capture_output=True, text=True, cwd=REPO)
    ppm = prefix.with_name(f"{prefix.name}-{frame:05d}.ppm")
    if not ppm.exists():
        sys.exit(f"capture failed for {prefix.name}\n{res.stdout}\n{res.stderr}")
    return ppm


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--roms", type=pathlib.Path, default=DEFAULT_ROMS)
    ap.add_argument("--out", type=pathlib.Path, default=REPO / "site" / "shots" / "shaders")
    ap.add_argument("--only", help="capture just one game (slug)")
    args = ap.parse_args()

    exe = sdl_binary()
    args.out.mkdir(parents=True, exist_ok=True)
    tmp = args.out / ".tmp"
    tmp.mkdir(exist_ok=True)

    for slug, g in GAMES.items():
        if args.only and args.only != slug:
            continue
        rom = args.roms / g["rom"]
        if not rom.exists():
            sys.exit(f"missing ROM: {rom}")
        frame, scale = g["frame"], g["scale"]

        # The raw side: the frontend dumps the console framebuffer at 256x224, so
        # upscale by exactly `scale` with nearest -- no invention, no resampling.
        raw_ppm = run(exe, rom, frame, tmp / f"{slug}-raw", scale, None)
        raw = Image.open(raw_ppm)
        if raw.size != (NATIVE_W, NATIVE_H):
            sys.exit(f"expected a {NATIVE_W}x{NATIVE_H} raw frame, got {raw.size}")
        want = (NATIVE_W * scale, NATIVE_H * scale)
        raw.resize(want, Image.NEAREST).save(args.out / f"{slug}-raw.png", optimize=True)
        print(f"{slug}-raw.png  {want[0]}x{want[1]}")

        for shader in g["shaders"]:
            ppm = run(exe, rom, frame, tmp / f"{slug}-{shader}", scale, shader)
            img = Image.open(ppm)
            if img.size != want:
                sys.exit(
                    f"{slug}/{shader}: shader output is {img.size}, raw upscales to {want}"
                    " -- they must match or the wipe will not line up"
                )
            img.save(args.out / f"{slug}-{shader}.jpg", quality=90, optimize=True,
                     progressive=True)
            print(f"{slug}-{shader}.jpg  {img.size[0]}x{img.size[1]}")

    print(f"\nwrote {args.out}")


if __name__ == "__main__":
    main()
