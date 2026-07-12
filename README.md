# Yamabuki

A fast, cross-platform SNES emulator written in Zig, built to run full speed
on underpowered ARM handhelds.

## Design goals

- **Speed first**: scanline-based fast core by default, engineered for weak
  ARM chips (Cortex-A53-class and below). Zero heap allocation per frame,
  zero function pointers on hot paths — Zig `comptime` specialization
  generates monomorphized interpreters and renderers.
- **Hybrid accuracy**: an opt-in accurate core (dot-level PPU, per-access
  timing) is built from the same source via `comptime`, selectable at runtime
  per game.
- **Portable**: pure-Zig core with no external dependencies; cross-compiles
  to x86_64 and aarch64 (glibc and musl) with `zig build` alone.
- **Deployable**: libretro core for RetroArch-based handheld firmware, plus
  an SDL3 desktop app for development, and a headless runner for CI.

## Building

Requires Zig 0.16.0 (pinned in `.zigversion`; `tools/install_zig.sh`
installs it from PyPI if ziglang.org is unreachable).

```sh
zig build                        # headless runner + libretro core + SDL3 desktop app
zig build test                   # unit tests
tools/fetch_test_data.sh         # fetch CPU test vectors + test ROMs (gitignored)
zig build test-sst               # run 65816 SingleStepTests vectors
zig build test-sst-spc700        # run SPC700 SingleStepTests vectors
zig build test-roms              # render PeterLemon ROMs, check golden hashes
zig build test-roms -Drom-accurate  # same goldens on the accurate core
zig build test-libretro          # drive the libretro core against the same goldens
zig build fuzz                   # deterministic fuzz: random PPU/bus traffic + save/load roundtrip
zig build bench -- <rom.sfc>     # headless FPS benchmark (JSON)
zig build bench-check            # gate the deterministic perf baseline (steps/cycles/vram_reads)
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-musl  # handheld build
tools/package_handheld.sh        # static musl handheld package (asserts no dynamic deps)
```

Run a ROM headless and dump a frame (and its audio) to inspect:

```sh
zig build && ./zig-out/bin/yamabuki-headless <rom.sfc> --frames 60 --ppm out.ppm --wav out.wav
```

Or play it in a window (needs the SDL3 runtime library, `libSDL3.so.0` —
the build has no SDL dependency, the library is dlopen'd):

```sh
./zig-out/bin/yamabuki-sdl <rom.sfc> [--scale N]
```

Keyboard follows the RetroArch defaults — arrows = d-pad, `Z`=B, `X`=A,
`A`=Y, `S`=X, `Q`=L, `W`=R, `Enter`=Start, `RShift`=Select — plus `F5`/`F9`
save/load state, `F1` reset, hold `Tab` to fast-forward, `Esc` to quit.

## Status

Early development. The console boots ROMs, renders, and plays sound: scheduler
with NMI/IRQ, DMA/HDMA, a fast scanline renderer covering all 8 BG modes
(2/4/8bpp planar, affine Mode 7 + EXTBG, hi-res 512-wide modes 5/6 and
pseudo-hires) with sprites, windows, and color math, and the full APU — SPC700
plus the S-DSP (8 BRR voices, gaussian interpolation, ADSR/GAIN envelopes,
noise, pitch modulation, echo) emitting 32 kHz stereo with signed, phase-exact
mixing, so Dolby Surround games decode correctly
([`docs/AUDIO_SURROUND.md`](docs/AUDIO_SURROUND.md)).
PeterLemon BG/text/sprite ROMs render and are locked against golden framebuffer
hashes, music demo ROMs against golden audio-stream hashes; the 65816 and
SPC700 cores are validated against
[SingleStepTests](https://github.com/SingleStepTests) vectors — the 65816 at
full cycle parity (count and per-cycle bus position over all 5.12M cases) —
and the SPC700 CPU-test ROMs run end-to-end on the audio CPU through an HLE
boot handshake. An opt-in accurate core (`--accurate`, or the
`yamabuki_accuracy` libretro option) renders piecewise at the beam position,
so mid-scanline register writes split the line the way hardware does.
Super FX (GSU) cartridges work: the full RISC instruction set with the
hardware's prefetch pipeline, code cache, and PLOT bitplane pipeline, locked
against all 31 krom GSUTest opcode screens and 27 plot demos (which match
krom's reference captures pixel-for-pixel). The DSP-1 math coprocessor
(Super Mario Kart, Pilotwings) is emulated at the command level, with its
lookup tables regenerated from closed-form math and every command family
locked by exact unit-test vectors. The SA-1 (Super Mario RPG, Kirby Super
Star) runs as a second instance of the same 65816 core on its own bus, with
the Super MMC, BW-RAM projections, DMA with character conversion, and the
arithmetic unit. The Cx4 (Mega Man X2/X3) is emulated at the command level:
the wireframe transform/rasterizer, sprite scale/rotate, OAM builder, and the
scalar math commands, driven synchronously through its $6000-$7FFF register
window — completing M9's enhancement-chip set. Performance work (M10) is
underway: the fast renderer now decodes each tile row in a single pass — a run
of same-tile background pixels reuses one decode (memoized by char-data
address) and each sprite tile column decodes once, instead of re-reading every
plane word per pixel — bit-identical output, with noticeably less VRAM traffic
on decode-bound backgrounds and sprites.

See [`docs/ROADMAP.md`](docs/ROADMAP.md) for the full architecture and roadmap.

| Milestone | Status |
|---|---|
| M0 skeleton, build system, CI | done |
| M1 cartridge/mappers/bus | done |
| M2 65816 CPU + test vectors | done |
| M3 scheduler, DMA/HDMA, first pixels (BG modes 0/1) | done |
| M4 full fast PPU | done (all BG modes, mosaic, offset-per-tile, windows, color math, Mode 7 + EXTBG, hi-res/pseudo-hires) |
| M5 APU (SPC700 + S-DSP) | done (BRR voices, gaussian, ADSR/GAIN, noise, pitch mod, echo; 32 kHz stereo + audio-hash goldens) |
| M6 save states + libretro core | done (joypad input, versioned save states, full libretro core + parity harness) |
| M7 SDL3 desktop frontend | done (dlopen'd SDL3, no build-time deps; keyboard input, save-state hotkeys, fast-forward, NTSC pacing; CI golden-hash smoke test) |
| M8 accurate mode (dot renderer, cycle timing) | done (beam-position piecewise rendering, dot-placed H-IRQs, full SST cycle parity — count and position; `--accurate` / `yamabuki_accuracy` selection) |
| M9 enhancement chips (Super FX, DSP-1, SA-1, Cx4) | done (Super FX: 58 golden ROMs; DSP-1 HLE; SA-1: second 65816 + MMC/DMA/math; Cx4 HLE wireframe/sprite math — all unit-test gated) |
| M10 ARM performance tuning | in progress (tile-row decode cache for BG + sprites: single-pass planar decode, bit-identical, ~+18–39% headless FPS on 8bpp BG-heavy ROMs and ~+13% on sprite-heavy Rings; deterministic VRAM-traffic bench gate + static-musl handheld packaging with a CI static-linkage assertion) |
