# Yamabuki — Architecture & Roadmap

A fast, cross-platform SNES emulator in Zig, built to run full speed on
underpowered ARM handhelds (Anbernic, Miyoo, Retroid) while remaining portable
across x86_64 and aarch64.

## Goals

- **Speed first.** A scanline-based fast core by default, engineered for weak
  ARM chips (Cortex-A53-class and below). Zero heap allocation per frame, zero
  function pointers on hot paths — Zig `comptime` specialization generates
  monomorphized interpreters and renderers.
- **Hybrid accuracy.** An opt-in accurate core (dot-level PPU, per-access
  timing) is built from the *same source* via `comptime`, selectable at runtime
  per game.
- **Portable.** A pure-Zig core with no external dependencies; cross-compiles to
  x86_64 and aarch64 (glibc and musl) and armv7 with `zig build` alone.
- **Deployable.** A libretro core for RetroArch-based handheld firmware, an SDL3
  desktop app for development, and a headless runner for CI/verification.

## Repository layout

```
src/core/
    core.zig             # public API root
    console.zig          # Console(comptime cfg): wires CPU/bus/PPU/APU/DMA, runFrame()
    scheduler.zig        # master clock, fixed event slots, run-until-event
    serialize.zig        # comptime-reflection save-state serializer
    timing.zig           # master-clock timing constants
    cpu/    wdc65816.zig ops.zig       # CPU core + instruction implementations
    memory/ bus.zig mappers.zig dma.zig wram.zig math_unit.zig
    cart/   cartridge.zig header.zig
    ppu/    ppu.zig line_render.zig dot_render.zig sprites.zig window.zig colormath.zig mode7.zig
    apu/    apu.zig spc700.zig sdsp.zig ipl.zig
    chips/  dsp1.zig sa1.zig superfx.zig cx4.zig    # enhancement chips (M9)
src/frontends/
    headless/main.zig    # run N frames, dump .ppm, print framebuffer hash
    libretro/api.zig core.zig    # hand-ported libretro ABI, callconv(.c) exports, zero deps
    sdl/main.zig         # SDL3 desktop app (lazy dependency)
tests/  sst_65816.zig sst_spc700.zig rom_runner.zig
bench/  bench.zig        # headless FPS benchmark
```

## Core architecture

### Hybrid accuracy via comptime specialization

`pub fn Console(comptime cfg: CoreConfig) type` is instantiated twice
(`FastConsole`, `AccurateConsole`); runtime selection is a tagged union
dispatched only at frame/API granularity. Inside each instantiation every
`if (cfg.accuracy == .fast)` resolves at compile time — ~90% of source is
shared, dead code is eliminated, and there is zero hot-path indirection.
Default is fast; per-game override via a libretro core option / CLI flag.

### 65C816 CPU — the speed core

Registers are plain integers; the P flags are a `u8` with branchless mask ops;
`e` (emulation mode) is a bool. Dispatch is **four comptime-monomorphized
interpreters** keyed on the M/X flag widths: one generic
`dispatch(comptime m8, comptime x8)` with a 256-arm switch (Zig emits a jump
table), instantiated for each width combination. All operand widths, index
masking, and NZ flag widths resolve at compile time; there are no function
pointers anywhere. Every bus access charges master cycles from the page's speed
field, so instruction timing falls out of memory traffic for free. The core is
generic over the bus type, so the same code drives the SNES bus, the test mock
bus, and (in M9) the SA-1's private bus.

### Memory bus

A 24-bit address space dispatched through a **2048-entry page table** (8 KiB
pages): `Page = { read: ?[*]const u8, write: ?[*]u8, speed: u8 }`. The fast path
is two loads for ~95% of accesses; the slow path is a single `slowRead`/
`slowWrite` switch over MMIO regions (`$21xx` PPU, `$2140–43` APU, `$42xx` CPU
I/O, `$43xx` DMA, `$2180–83` WRAM port). Open bus is modeled with an MDR
register. Mappers (LoROM/HiROM/ExHiROM) are pure page-table builders run once at
load; header detection scores candidates at `$7FC0`/`$FFC0`/`$40FFC0`. The
`Cartridge` interface (page mapping + claimed MMIO ranges + a `ChipKind` enum)
is the day-one extension point for the SA-1/Super FX/DSP-1/Cx4 chips.

### Scheduler / sync

A `u64` master clock at 21.477 MHz; NTSC line = 1364 cycles, frame = 262 lines
(PAL parameterized from day one, implemented later). The CPU drives; other
components own timestamps and catch up. Events live in fixed slots (end-of-line,
H/V-IRQ, NMI, auto-joypad) — no heap, no priority queue. In fast mode the CPU
runs event-bounded budgets, the PPU renders per scanline, and the APU catches up
lazily. Accurate mode uses the same skeleton but runs the PPU per-dot after each
instruction and adds detailed DMA timing.

### PPU

The fast scanline renderer is the performance heart: per line it evaluates OAM
(with the real 32-sprite/34-tile limits), renders each enabled BG into
`(color, priority)` line buffers via tile decoders comptime-specialized on bpp,
composites by priority, applies window spans (computed once per line), color
math, and mosaic, and outputs **RGB565 end-to-end** (palette converted at
CGRAM-write time — handheld-native, no post-pass). Mode 7 is a fixed-point
matrix walk; hi-res uses a 512-wide buffer only when active. The accurate dot
renderer (M8) reuses the same register state and decoders with a real per-dot
fetch pipeline so mid-scanline register writes render correctly.

### APU

An SPC700 interpreter (same comptime-switch style), 64 KiB ARAM, three timers,
four I/O ports, and the embedded 64-byte IPL boot ROM. The S-DSP does BRR
decoding, 8 voices, ADSR/gain envelopes, gaussian interpolation, echo, and
noise, emitting 32 kHz stereo into a preallocated ring buffer drained each
frame. Execution is **fully decoupled with lazy catch-up**: any CPU access to
`$2140–43` first steps the APU to "now" — exact for the port handshake, and the
biggest performance lever after CPU dispatch.

### DMA / HDMA

Eight channels. GDMA stalls the CPU at 8 cycles/byte plus fixed overheads, with
the transfer-unit patterns as a comptime table; HDMA initializes at line 0 and
transfers per line at H-blank in direct and indirect modes. Accurate mode adds
per-channel overhead detail.

### Save states

All component state lives in plain, pointer-free structs. A comptime-reflection
serializer walks the fields little-endian; a versioned header carries format and
core version; a `postLoad()` hook rebuilds derived state (the bus page table,
PPU caches). Fixed-size state structs keep libretro's `retro_serialize_size`
stable across a session. This is scaffolded early (M1) because libretro requires
serialize/unserialize.

### Frontends

- **libretro** — `api.zig` hand-ports the stable ABI subset (no C headers) and
  `core.zig` exports the `retro_*` functions with `callconv(.c)`: RGB565,
  audio-sample-batch, joypad, core options (`yamabuki_accuracy`, overscan). Zero
  external dependencies.
- **SDL3 desktop** — via the castholm/SDL Zig package (statically built by Zig
  for clean cross-compilation), wired as a *lazy* dependency so its absence never
  breaks `zig build`. Adds fast-forward, frame-advance, save-state hotkeys, and
  layer toggles.
- **headless** — runs N frames, dumps `.ppm`, and prints a framebuffer hash;
  the primary development and CI verification tool.

## Testing strategy

- **CPU/APU vectors.** The [SingleStepTests](https://github.com/SingleStepTests)
  65816 and SPC700 JSON vectors are run against the core on a mock recording bus:
  per case, set state → step → compare registers and memory. Parsing is
  streaming, with no large allocations. The vectors are large (the 65816 set is
  ~3 GB) and are **never committed** — `tools/fetch_test_data.sh` shallow-clones
  them into a gitignored dir, and CI caches them. `-Dsst-sample=N` runs a sample
  (CI); the full run is local/nightly. Cycle-*position* parity is a separate
  metric tied to the accurate-mode milestone (M8).
- **Integration ROMs.** `tests/rom_runner.zig` runs a homebrew test ROM
  (PeterLemon/krom) headless for N frames, FNV-1a hashes the RGB565 framebuffer,
  and compares against committed golden hashes minted after manual `.ppm`
  inspection. The same loop doubles as the benchmark.
- **Unit tests** live inline per module: header detection, mapper shapes, open
  bus, DMA readback, multiply/divide registers, BRR decode, envelopes, and
  serialize roundtrip byte-identity.
- **CI**: format check → unit tests + sampled SST (Debug *and* ReleaseFast, to
  catch UB) → cross-compile matrix (`x86_64-linux-gnu`, `aarch64-linux-gnu`,
  `aarch64-linux-musl`, `arm-linux-musleabihf`) → headless FPS benchmark vs a
  baseline (informational first, a hard gate after M10).

## Milestones

| # | Deliverable | Verification | Status |
|---|---|---|---|
| M0 | Skeleton: build system, `.zigversion`, toolchain + fetch scripts, CI, module stubs, timing constants | `zig build test` green; CI cross-compiles | **Done** |
| M1 | Cart loading, header detection, mappers, page-table bus + open bus, WRAM, CPU math regs, serialize scaffolding | Unit tests | **Done** |
| M2 | Full 65816 core (256 ops × 4 comptime variants, E-mode, interrupts, block moves) | SST 65816: 100% register/memory (5.12M cases) | **Done** |
| M3 | Scheduler, NMI/IRQ, GDMA/HDMA, PPU registers, fast renderer modes 0/1 + sprites | PeterLemon ROMs render; golden hashes; `.ppm` eyeballed | **Done** |
| M4 | Full fast PPU (modes 2–7, offset-per-tile, windows, color math, mosaic, hi-res) | PeterLemon PPU suite hashes | Next |
| M5 | APU: SPC700 + S-DSP + lazy sync | SST spc700 100%; commercial games boot (handshake gate) | Planned |
| M6 | Save states finalized + libretro core | RetroArch plays; serialize roundtrip mid-game | Planned |
| M7 | SDL3 desktop frontend | Plays on desktop; aarch64 binary cross-compiles | Planned |
| M8 | Accurate mode: dot renderer, per-access timing, SST cycle parity | Raster-effect games correct in accurate mode | Planned |
| M9 | Enhancement chips: DSP-1 (HLE) → SA-1 (reuses the 65816 core) → Super FX → Cx4 (HLE) | Mario Kart, Kirby 3, Star Fox, MMX2 boot/play | Planned |
| M10 | ARM performance tuning, tile-decode cache, musl static packaging, bench gate hardened | ≥60 FPS sustained on a Cortex-A53-class device | Planned |

## Performance engineering

- **Comptime devirtualization everywhere** — the four CPU variants, bpp-
  specialized tile decoders, and the accuracy-specialized console mean zero
  function pointers on hot paths; the only runtime indirection is the per-frame
  tagged-union dispatch.
- **ReleaseFast** is the shipped mode; Debug/ReleaseSafe and the SST suite run
  in both to catch UB early.
- **Zero per-frame allocation** — one large `Console` struct owns every buffer
  (framebuffer, line buffers, audio ring, ARAM, VRAM), allocated once, hot
  fields ordered first for cache locality; the core is single-threaded, no
  atomics.
- **Branchless flag math** via widened `u32` intermediates; wrapping ops to
  avoid checked-arithmetic codegen.
- **Two-load page-table bus**; **RGB565 end-to-end** (no post-pass on the
  handheld); `@branchHint` on fast/slow path splits.
- **Benchmark methodology** — a fixed ROM × fixed frame count headless, reporting
  frames/sec and per-component share as JSON, compared against a baseline in CI;
  real tuning uses on-device aarch64 numbers, since x86 timings don't predict
  A53 cache behavior.

## Risks

- **The APU port handshake gates commercial games** (M5) — homebrew ROMs keep
  M3/M4 testable, and the SPC700 SST vectors de-risk it before DSP work.
- **Old handheld glibc** — musl-static and glibc-version-pinned cross targets are
  in CI from M0; handhelds mostly use the libretro core anyway.
- **IPL boot ROM** — 64 bytes of Sony code, embedded per industry norm; noted in
  the README.
- **Zig API churn** — the toolchain version is pinned in `.zigversion`,
  `build.zig.zon`, and CI.
- **PAL support** is deferred; region constants are parameterized from M0 so it
  is purely additive.
