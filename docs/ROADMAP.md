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
    chips/  gsu.zig dsp1.zig sa1.zig cx4.zig # Super FX, DSP-1, SA-1, Cx4 (M9 complete)
src/frontends/
    headless/main.zig    # run N frames, dump .ppm, print framebuffer hash
    libretro/api.zig core.zig    # hand-ported libretro ABI, callconv(.c) exports, zero deps
    sdl/main.zig         # SDL3 desktop app (sdl3.zig: dlopen'd ABI port)
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

Known deviation (both cores): the renderer maps BG line N to screen row N,
while hardware starts the visible picture at V=1 — with VOFS=0 the real PPU
shows BG line y+1 on screen row y, so the whole picture sits one line higher
on hardware (spotted comparing the M9 GSU plot demos against krom's reference
captures, which match pixel-for-pixel once shifted). Fixing it is a deliberate
follow-up slice: it re-mints every golden hash at once and needs the OBJ Y+1
and HDMA application-line quirks decided together.

### APU

An SPC700 interpreter (same comptime-switch style), 64 KiB ARAM, three timers,
four I/O ports, and the embedded 64-byte IPL boot ROM. The S-DSP does BRR
decoding, 8 voices, ADSR/gain envelopes, gaussian interpolation, echo, and
noise, emitting 32 kHz stereo into a preallocated ring buffer drained each
frame. Execution is **fully decoupled with lazy catch-up**: any CPU access to
`$2140–43` first steps the APU to "now" — exact for the port handshake, and the
biggest performance lever after CPU dispatch. All DSP volumes and FIR
coefficients mix as signed values — that phase fidelity is what carries the
Dolby Surround matrix some games encode (see
[`AUDIO_SURROUND.md`](AUDIO_SURROUND.md)).

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
  `core.zig` exports the `retro_*` functions with `callconv(.c)`: RGB565 frames
  handed over with zero conversion, audio-sample-batch at 32 kHz, both joypads,
  serialize/unserialize via the versioned save-state container, SRAM/WRAM via
  `retro_get_memory_*`. Zero external dependencies. `zig build test-libretro`
  drives the exported surface like a frontend and locks it to the same golden
  hashes as the direct console path (core options like `yamabuki_accuracy`
  arrive with the accurate core, M8).
- **SDL3 desktop** — `sdl3.zig` hand-ports the needed SDL3 ABI subset (same
  pattern as libretro's `api.zig`) and dlopens `libSDL3.so.0` at runtime, so
  `zig build` needs no SDL headers, packages, or libraries and the binary
  cross-compiles everywhere; machines without SDL3 get a friendly error.
  Native RGB565 streamed into a texture (recreated on hi-res/overscan
  switches), 32 kHz audio through an SDL audio stream, RetroArch-default
  keyboard mapping, save/load-state hotkeys (F5/F9), reset (F1), hold-Tab
  fast-forward, and NTSC-rate pacing independent of display refresh.
  `--frames N` prints the same video/audio hashes as the headless runner —
  CI smoke-tests the whole frontend under SDL's dummy drivers against the
  golden hashes. Frame-advance and layer toggles are deferred (M10 polish).
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
  metric tied to the accurate-mode milestone (M8) — closed in M8: the 65816
  harness now compares the executed bus-event sequence per cycle (VDA/VPA
  deciding real access vs internal) and gates count and position at zero.
- **Integration ROMs.** `tests/rom_runner.zig` runs a homebrew test ROM
  (PeterLemon/krom) headless for N frames, FNV-1a hashes the RGB565 framebuffer
  — and, once M5b landed, the whole 32 kHz stereo stream (optional `.audio`
  gate; phase-sensitive, so a lost sign inversion fails it) — and compares
  against committed golden hashes minted after manual `.ppm`/`--wav`
  inspection. The same loop doubles as the benchmark.
- **Unit tests** live inline per module: header detection, mapper shapes, open
  bus, DMA readback, multiply/divide registers, BRR decode, envelopes, and
  serialize roundtrip byte-identity.
- **Deterministic fuzz** (`zig build fuzz`, `tests/fuzz.zig`): seeded random
  PPU register/memory states rendered as full frames, then random bus traffic
  (PPU/APU ports, CPU I/O, live DMA/HDMA triggers) against a running console,
  with a periodic serialize→restore→step roundtrip that must stay
  byte-identical. Runs in Debug so every index/overflow safety check is armed;
  a fixed default seed keeps CI reproducible and any failure replays with
  `-Dfuzz-seed`. Its first outing found two renderer overflow traps, a DMA
  self-retrigger stack overflow, and an APU catch-up hang.
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
| M4 | Full fast PPU (modes 2–7, offset-per-tile, windows, color math, mosaic, hi-res) | PeterLemon PPU suite hashes | Done — planar modes + 8bpp, mosaic, offset-per-tile, windows, color math, Mode 7 + EXTBG, hi-res modes 5/6 + pseudo-hires (512-wide frames). Deferred to M8 accurate core: direct color, interlaced 448-line fields, beam-racing CGRAM tricks |
| M5 | APU: SPC700 + S-DSP + lazy sync | SST spc700 100%; commercial games boot (handshake gate) | Done — SPC700 core (SST 256k vectors, 0 failed, 0 cycle mismatches), ARAM/timers/ports, HLE boot, lazy catch-up; S-DSP with BRR + gaussian, ADSR/GAIN, noise, pitch mod, echo, signed phase-exact mixing; 32 kHz stereo ring + `readAudio()`; 8 music-ROM audio-hash goldens |
| M6 | Save states finalized + libretro core | RetroArch plays; serialize roundtrip mid-game | Done — joypad input ($4016 serial + auto-read), versioned save-state container, full libretro implementation; `test-libretro` harness proves golden video/audio parity, live input, and mid-run state replay through the retro_* surface (live RetroArch smoke test pending on a desktop) |
| M7 | SDL3 desktop frontend | Plays on desktop; aarch64 binary cross-compiles | Done — dlopen'd hand-ported SDL3 ABI (no build-time deps), streamed RGB565 + 32 kHz audio, keyboard input, F5/F9 save states, Tab fast-forward, NTSC pacing; CI smoke test reproduces golden hashes under dummy drivers; all 4 targets cross-compile (live desktop play still worth a manual spin) |
| M8 | Accurate mode: dot renderer, per-access timing, SST cycle parity | Raster-effect games correct in accurate mode | Done — 65816 at full SST cycle parity (count + per-cycle bus position, 5.12M cases, hard-gated); AccurateConsole renders piecewise at the beam position ($21xx mid-scanline writes split the line; HDMA stays blanking-period), H-IRQs fire at HTIME's dot; runtime selection via AnyConsole, `--accurate` (headless/SDL), `yamabuki_accuracy` (libretro), accuracy-tagged save states; all 42 goldens pass on the accurate core in CI. Hardware fetch-pipeline modeling (sprite-eval timing, mid-line hi-res splits) deferred to demand |
| M9 | Enhancement chips: Super FX → DSP-1 (HLE) → SA-1 (reuses the 65816 core) → Cx4 (HLE) | krom CHIP suite golden-gated; Mario Kart, Kirby 3, Star Fox, MMX2 boot/play | Done — **Super FX (GSU) done**: full instruction set with the hardware's one-byte prefetch pipeline (delay slots and R15 semantics emerge from it), 512-byte code cache (16-byte line fills, SNES cache injection), ROM buffer, PLOT/RPIX pixel cache with column-major char addressing (2/4/8bpp × 128/160/192/OBJ heights, dither, transparency), catch-up scheduling off the master clock, STOP IRQ into the CPU line, save-stated. Gated by 58 golden ROMs: 31 GSUTest opcode screens (hardware-verified PASS/FAIL checks) + 27 plot demos matching krom's captures pixel-for-pixel modulo the global one-line display offset (see PPU notes). Ordered first because it is the only chip with test-ROM coverage. **DSP-1 (HLE) done**: the µPD7725 math coprocessor at the command level — the full documented command set (multiply, inverse with Newton refinement, interpolated sin/cos, 2D/3D rotate, attitude matrices with objective/subjective/scalar transforms, gyrate, radius/range/distance, and the mode 7 projection family: parameter → self-refilling raster stream → project/target), the DR/SR port state machine, and both board decodes (LoROM $30-$3F:$8000+ for carts up to 1 MiB, $60-$6F low half above that; HiROM $00-$1F:$6000-$7FFF). Data-ROM tables are regenerated at comptime from closed forms (reciprocal seeds round(2^29/d), sine trunc(32768·sin), power-of-two shift tables incl. the chip's $3C one-word bug); only the 49-word sqrt segment and a few polynomial constants are carried as documented literals. No DSP-1 test ROMs exist, so the gate is unit tests: exact vectors cross-checked against the reference HLE for every command family plus port-protocol edge cases (raster skip-writes, $80 idle bytes, ROM dump). Commands execute instantly (SR always ready) — documented HLE simplification. DSP-2/3/4 carry different µPD7725 programs and stay out of scope. **SA-1 done**: a second 65816 at 10.74 MHz reusing the same generic CPU core (the Sa1 struct is its bus), with 2 KiB IRAM, BW-RAM in linear and 2/4-bit bitmap projections, the Super MMC's four switchable 1 MiB ROM regions (page table rebuilt on bank writes), interrupt vectors served from registers by intercepting vector-window reads (the same trick swaps the SNES NMI/IRQ vectors to SNV/SIV — that page stays off the fast path), message ports and IRQs both directions, H/V and linear timers, normal DMA, both character-conversion DMA types, the multiply/divide/cumulative arithmetic unit, and the variable-length bit reader. Catch-up scheduled off the master clock (exactly half-rate) per scanline and before any shared access. No SA-1 test ROMs exist, so the gate is unit tests: the SA-1 boots from CRV and executes real 65816 code from MMC-mapped ROM in-process, IRQ/NMI delivery both ways, MMC remaps, DMA + CC1/CC2 conversions, arithmetic and bit-reader vectors, timers, protection bits, and a serialize roundtrip. Fast-core simplifications: no bus-conflict arbitration stalls, timer IRQs land on instruction boundaries, SA-1-side data reads of $00:FFEA-FFFF return the vector registers. **Cx4 (HLE) done**: the Hitachi HG51B169 on the Mega Man X2/X3 boards, at the command level. A plain memory-mapped device — an 8 KiB RAM window at $6000-$7FFF of banks $00-$3F/$80-$BF; games stage operands into the register file at $7F40-$7FA4 and poke a command byte to $7F4F, which runs the whole operation synchronously (no interrupt line, no busy flag the games poll, so nothing schedules — the command completes inside the port write and the $7F5E status reads 0). The full routine set: the wireframe transform + line rasterizer, OAM builder, affine scale/rotate, line transformer, bitplane wave, sprite disintegrate, and the scalar commands (24-bit multiply, 48-bit square, Pythagoras, atan2, polar↔rectangular with the radius clamp and y-bias, sum, trapezoid spans, coordinate transform, propulsion, set-vector-length). Sine/cosine are comptime round(32767·sin/cos(2πi/512)) — the chip's own table carries ±1 Q15 rounding noise with no single closed form, but that low bit can never move an integer screen coordinate, so the clean formula stands; only the 48-byte $5C self-test response is carried verbatim. No Cx4 test ROMs exist, so the gate is unit tests: every scalar command with vectors minted from the reference algorithm, the OAM builder, memory load, the status/window ports through the real bus, and a serialize roundtrip. HLE simplifications: commands complete instantly, double-precision trig drives the wireframe rotations (a rotated vertex can differ from the chip's fixed-point microcode by a sub-pixel amount before rounding), and degenerate projections fold the way an x86 double→int conversion would. The data ROM (needed only for the LLE approach, which requires the copyrighted Cx4 program) is unused. Fast-core simplifications for Super FX: synchronous ROM/RAM buffers (SFR "R" flag always reads 0), no RON/RAN arbitration stalls or SNES-side ROM lock during GO |
| M10 | ARM performance tuning, tile-decode cache, musl static packaging, bench gate hardened | ≥60 FPS sustained on a Cortex-A53-class device | In progress — tile-row decode cache (BG planar decode reads each plane word once per row and memoizes by char address; bit-identical, ~+18–39% headless FPS on 8bpp BG-heavy ROMs). musl static packaging + bench gate hardening still to come; the ≥60 FPS target is measured on-device |

## Performance engineering

- **Comptime devirtualization everywhere** — the four CPU variants, bpp-
  specialized tile decoders, and the accuracy-specialized console mean zero
  function pointers on hot paths; the only runtime indirection is the per-frame
  tagged-union dispatch.
- **Tile-row decode cache** (M10) — the fast renderer decodes a whole 8-pixel
  BG tile row in one pass (each planar word read once and scattered across the
  eight pixels) and memoizes it by char-data address for the pixel run that
  shares it, instead of re-reading every plane word per pixel. Output is
  bit-identical to the per-pixel decode (all goldens unchanged); it cuts VRAM
  fetch traffic ~8x for 8bpp rows — the win that compounds on cache-poor ARM.
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
