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
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-musl  # handheld build
```

## Status

Early development. Current roadmap position: project skeleton, memory
system, and 65816 CPU core (validated against
[SingleStepTests](https://github.com/SingleStepTests/65816) vectors).

| Milestone | Status |
|---|---|
| M0 skeleton, build system, CI | in progress |
| M1 cartridge/mappers/bus | planned |
| M2 65816 CPU + test vectors | planned |
| M3 scheduler, DMA/HDMA, first pixels (BG modes 0/1) | planned |
| M4 full fast PPU | planned |
| M5 APU (SPC700 + S-DSP) | planned |
| M6 save states + libretro core | planned |
| M7 SDL3 desktop frontend | planned |
| M8 accurate mode (dot renderer, cycle timing) | planned |
| M9 enhancement chips (DSP-1, SA-1, Super FX, Cx4) | planned |
| M10 ARM performance tuning | planned |
