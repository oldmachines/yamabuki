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
zig build                        # headless runner + libretro core
zig build test                   # unit tests
tools/fetch_test_data.sh         # fetch CPU test vectors + test ROMs (gitignored)
zig build test-sst               # run 65816 SingleStepTests vectors
zig build test-roms              # render PeterLemon ROMs, check golden hashes
zig build bench -- <rom.sfc>     # headless FPS benchmark (JSON)
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-musl  # handheld build
```

Run a ROM headless and dump a frame to inspect:

```sh
zig build && ./zig-out/bin/yamabuki-headless <rom.sfc> --frames 16 --ppm out.ppm
```

## Status

Early development. The console boots ROMs and renders: scheduler with NMI/IRQ,
DMA/HDMA, and a fast scanline renderer for BG modes 0/1 + sprites. PeterLemon
BG/text/sprite ROMs render and are locked against golden framebuffer hashes;
the 65816 core is validated against
[SingleStepTests](https://github.com/SingleStepTests/65816) vectors.

See [`docs/ROADMAP.md`](docs/ROADMAP.md) for the full architecture and roadmap.

| Milestone | Status |
|---|---|
| M0 skeleton, build system, CI | done |
| M1 cartridge/mappers/bus | done |
| M2 65816 CPU + test vectors | done |
| M3 scheduler, DMA/HDMA, first pixels (BG modes 0/1) | done |
| M4 full fast PPU | planned |
| M5 APU (SPC700 + S-DSP) | planned |
| M6 save states + libretro core | planned |
| M7 SDL3 desktop frontend | planned |
| M8 accurate mode (dot renderer, cycle timing) | planned |
| M9 enhancement chips (DSP-1, SA-1, Super FX, Cx4) | planned |
| M10 ARM performance tuning | planned |
