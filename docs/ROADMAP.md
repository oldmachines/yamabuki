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

Line placement matches hardware: the visible picture starts at V=1, so screen
row y fetches BG picture line y+1 (with VOFS=0) in both cores — krom reference
captures diff pixel-identical with no shift (fixed in the issue-34 slice,
re-minting every golden hash at once). OBJ needed no change: covering rows
[Y, Y+h) already realizes the hardware Y+1 sprite quirk once row 0 is V=1, and
HDMA stays keyed to the render row (the transfer at the end of scanline V
affects V+1, which is exactly framebuffer row V).

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
| M9 | Enhancement chips: Super FX → DSP-1 (HLE) → SA-1 (reuses the 65816 core) → Cx4 (HLE) → S-DD1 | krom CHIP suite golden-gated; Mario Kart, Kirby 3, Star Fox, MMX2 boot/play | Done — **Super FX (GSU) done**: full instruction set with the hardware's one-byte prefetch pipeline (delay slots and R15 semantics emerge from it), 512-byte code cache (16-byte line fills, SNES cache injection), ROM buffer, PLOT/RPIX pixel cache with column-major char addressing (2/4/8bpp × 128/160/192/OBJ heights, dither, transparency), catch-up scheduling off the master clock, STOP IRQ into the CPU line, save-stated. Gated by 58 golden ROMs: 31 GSUTest opcode screens (hardware-verified PASS/FAIL checks) + 27 plot demos matching krom's captures pixel-for-pixel modulo the global one-line display offset (see PPU notes). Ordered first because it is the only chip with test-ROM coverage. **DSP-1 (HLE) done**: the µPD7725 math coprocessor at the command level — the full documented command set (multiply, inverse with Newton refinement, interpolated sin/cos, 2D/3D rotate, attitude matrices with objective/subjective/scalar transforms, gyrate, radius/range/distance, and the mode 7 projection family: parameter → self-refilling raster stream → project/target), the DR/SR port state machine, and both board decodes (LoROM $30-$3F:$8000+ for carts up to 1 MiB, $60-$6F low half above that; HiROM $00-$1F:$6000-$7FFF). Data-ROM tables are regenerated at comptime from closed forms (reciprocal seeds round(2^29/d), sine trunc(32768·sin), power-of-two shift tables incl. the chip's $3C one-word bug); only the 49-word sqrt segment and a few polynomial constants are carried as documented literals. No DSP-1 test ROMs exist, so the gate is unit tests: exact vectors cross-checked against the reference HLE for every command family plus port-protocol edge cases (raster skip-writes, $80 idle bytes, ROM dump). Commands execute instantly (SR always ready) — documented HLE simplification. DSP-2/3/4 carry different µPD7725 programs and stay out of scope. **SA-1 done**: a second 65816 at 10.74 MHz reusing the same generic CPU core (the Sa1 struct is its bus), with 2 KiB IRAM, BW-RAM in linear and 2/4-bit bitmap projections, the Super MMC's four switchable 1 MiB ROM regions (page table rebuilt on bank writes), interrupt vectors served from registers by intercepting vector-window reads (the same trick swaps the SNES NMI/IRQ vectors to SNV/SIV — that page stays off the fast path), message ports and IRQs both directions, H/V and linear timers, normal DMA, both character-conversion DMA types, the multiply/divide/cumulative arithmetic unit, and the variable-length bit reader. Catch-up scheduled off the master clock (exactly half-rate) per scanline and before any shared access. No SA-1 test ROMs exist, so the gate is unit tests: the SA-1 boots from CRV and executes real 65816 code from MMC-mapped ROM in-process, IRQ/NMI delivery both ways, MMC remaps, DMA + CC1/CC2 conversions, arithmetic and bit-reader vectors, timers, protection bits, and a serialize roundtrip. Fast-core simplifications: no bus-conflict arbitration stalls, timer IRQs land on instruction boundaries, SA-1-side data reads of $00:FFEA-FFFF return the vector registers. **Cx4 (HLE) done**: the Hitachi HG51B169 on the Mega Man X2/X3 boards, at the command level. A plain memory-mapped device — an 8 KiB RAM window at $6000-$7FFF of banks $00-$3F/$80-$BF; games stage operands into the register file at $7F40-$7FA4 and poke a command byte to $7F4F, which runs the whole operation synchronously (no interrupt line, no busy flag the games poll, so nothing schedules — the command completes inside the port write and the $7F5E status reads 0). The full routine set: the wireframe transform + line rasterizer, OAM builder, affine scale/rotate, line transformer, bitplane wave, sprite disintegrate, and the scalar commands (24-bit multiply, 48-bit square, Pythagoras, atan2, polar↔rectangular with the radius clamp and y-bias, sum, trapezoid spans, coordinate transform, propulsion, set-vector-length). Sine/cosine are comptime round(32767·sin/cos(2πi/512)) — the chip's own table carries ±1 Q15 rounding noise with no single closed form, but that low bit can never move an integer screen coordinate, so the clean formula stands; only the 48-byte $5C self-test response is carried verbatim. No Cx4 test ROMs exist, so the gate is unit tests: every scalar command with vectors minted from the reference algorithm, the OAM builder, memory load, the status/window ports through the real bus, and a serialize roundtrip. HLE simplifications: commands complete instantly, double-precision trig drives the wireframe rotations (a rotated vertex can differ from the chip's fixed-point microcode by a sub-pixel amount before rounding), and degenerate projections fold the way an x86 double→int conversion would. The data ROM (needed only for the LLE approach, which requires the copyrighted Cx4 program) is unused. **S-DD1 done**: the decompressor on the Star Ocean / Street Fighter Alpha 2 boards, and the memory-map controller it shares a package with. The MMC is what a cart needs first: banks $C0-$FF are a 4 MiB window of four 1 MiB slices selected by $4804-$4807, and Star Ocean's reset code ends in `JML $C0:8001`, so plain LoROM addressing put it into open bus and it never rendered a frame. The decompressor is the ABS lossless entropy coder — a probability estimator over 32 neighbour-keyed contexts driving Golomb run-length codes, one bit at a time, with output logic reassembling bits into SNES bitplane bytes for the 2/4/8bpp tile layouts and mode 7. A DMA channel armed through $4800/$4801 takes its A-side bytes from the decoder instead of ROM (one-shot per transfer), which is how these games get graphics into VRAM. Written from the published algorithm description, not another emulator's source: the Golomb run lengths are generated at comptime from the closed form the documented decode tables imply (run = ~bitreverse_k(field)), and only the 33-state probability evolution table is carried verbatim as an irreducible hardware constant. No S-DD1 test ROMs exist, so the gate is unit tests (bank windowing through the real page table, the arm-once DMA path, both coder branches, a serialize roundtrip) plus the anchor that actually matters: Star Ocean boots, and every byte of graphics on its title screen and menu came out of the decoder, pinned as a commercial-boot golden. Fast-core simplification: a decompressing DMA expands synchronously as the transfer runs, so the chip has no observable busy period. Fast-core simplifications for Super FX: synchronous ROM/RAM buffers (SFR "R" flag always reads 0), no RON/RAN arbitration stalls or SNES-side ROM lock during GO |
| M10 | ARM performance tuning, tile-decode cache, musl static packaging, bench gate hardened | ≥60 FPS sustained on a Cortex-A53-class device | In progress — tile-row decode cache for both BG (memoized by char address) and sprites (once per tile column); each plane word read once per row instead of per pixel; bit-identical, ~+18–39% headless FPS on 8bpp BG-heavy ROMs and ~+13% on the sprite-heavy Rings ROM. Bench gate hardened: a comptime-gated VRAM-word counter (`vram_reads`, compiled out of shipping builds) feeds `zig build bench-check`, a deterministic per-ROM baseline that fails CI on any steps/cycles/traffic drift — locking the decode cache in. Static-musl handheld packaging (`tools/package_handheld.sh`) with a CI assertion that every musl artifact has no dynamic libc / NEEDED shared object. The ≥60 FPS target is measured on-device |
| M11 | CRT shaders: GL ES pipeline in the SDL frontend, libretro presets transpiled ahead of time | Presets render on-device; the bake gate holds the promised set | In progress — the SDL frontend had no GPU path at all (an `SDL_Renderer` blit of the RGB565 frame). Now: a GL ES context with the entry points resolved through `SDL_GL_GetProcAddress` (the same hand-ported-ABI, no-link-time-dependency stance as `sdl3.zig`), a multi-pass FBO chain with pass aliases, double-buffered feedback targets, an input-frame history ring, and LUT textures, plus a fallback ladder — **GL ES 3 → GL 3.3 → GL ES 2 → the existing software blit** — where every rung prints why it fell through, so a missing shader never costs the user the emulator. **The binary contains no shader compiler.** The presets are libretro *slang* (Vulkan GLSL); `tools/transpile_shaders.py` drives glslang and SPIRV-Cross on the *build host* and emits plain GLSL plus a manifest of reflected uniform offsets, and the phosphor-mask PNGs are decoded to raw RGBA there too — so the runtime holds no SPIR-V, no C++, and no image decoder, and the pure-Zig core, the dependency-free `zig build`, and the static-musl package all survive. The tools are themselves built by `zig c++`, so the bake needs no toolchain the repo does not already pin. Two uniform paths, because SPIRV-Cross emits different forms per profile: a real std140 block on ES3/desktop, plain per-member uniforms on ES2 (which has no uniform blocks); `--flatten-ubo` is unusable because it demands one basic type per block and the slang UBO mixes `mat4 MVP` with `uint FrameCount`. A preset is written for a profile only if it transpiled **and** every uniform mapped to a semantic the runtime supplies, so a shader that cannot work is *absent* rather than broken: 31 of 36 (preset, profile) pairs bake — crt-royale on all three, crt-guest-advanced on ES3 + desktop — and the 5 skips are printed with their reason (crt-geom/crt-hyllian use multidimensional array constructors, absent below ESSL 310; crt-guest-advanced needs `textureSize`, absent in ESSL 100). CI asserts the promised set still bakes. Presets are tagged `handheld` or `desktop` and the tag prints at startup — a claim about a Cortex-A53, not a rating. **Gap: not yet run on a GPU.** The pipeline is compile-verified on all targets and the fallible logic (pass geometry, manifest parsing, uniform encoding, feedback flipping, letterboxing) is unit-tested, but no lit pixel has been observed; expect first-run bugs |
| M12 | ROM patch layer: soft-patching, a hash-keyed patch registry, auto-FastROM, and the SA-1 candidacy analyser | Patched ROMs boot and match the patch author's reference; `--save-patched` round-trips; auto-FastROM gated by a compat list | In progress — **step one of the analyser is done**: `--sa1-report` runs a game and answers the question that comes before every other one, *is it CPU-bound at all*. It cannot be measured directly (the SNES CPU burns the same cycles every frame whatever happens), so it is measured by its complement — the time the CPU spends **waiting** — and a loop counts as waiting if it *changes nothing*: writes nothing, and watches a fixed handful of addresses rather than walking memory (which is what tells a vblank spin from a checksum). Getting there took four corrections, every one of them a bug a *game* found rather than reasoning: a loop is found by **return**, not by proximity (Contra III's wait is a `JSL` inside a `BRA` loop spread over 6 KiB, and a program-counter *span* test called it 100% busy on every frame including its title screen); **stack traffic is not a side effect** (that same `JSL` pushes three bytes a pass, which a naive "writes nothing" test counts as a write); **a wait is allowed to write** (Tetris & Dr. Mario stirs an RNG seed while it spins — the classic way a game seeds randomness from how long you took to press Start — and read 100% busy until writes were permitted; what a wait may never do is poke a hardware register, which is what keeps a DMA-kicking loop out); and the unit of judgement is one **pass**, not one window (else a memory clear that merely precedes a wait condemns it, and Super Mario World's idle time disappears). Reports slowdown separately from **stalls** — an unbroken run of dropped frames is a level load, not a game failing to keep up, and conflating them recommends conversions nobody needs. Utilisation is honestly an *upper* bound (a wait it fails to spot reads as work) and dropped frames a *lower* one (a game polling the pad in its NMI handler can never register a lag frame); the two errors point opposite ways and bracket the truth, and the tool prints both caveats every run. Compiled in as a third comptime instantiation (`ProfilingConsole`), so the shipped core carries no branch for it; emulation under it is bit-identical (5.12M SST cases, 100 goldens, bench baselines all unchanged). Next: cycles per routine, then the WRAM working set of each hot routine — the number that actually decides a conversion |

## M12 — the ROM patch layer

The community around [Vitor Vilela](https://github.com/VitorVilela7) has spent
years recovering performance the SNES left on the table: **SA-1 Root** (Gradius
III, Contra III, Super R-Type, Race Drivin' — the last from ~4 fps to ~30), the
**SMW SA-1 Pack** (which relocates most of Super Mario World's logic memory into
SA-1-accessible space and is now foundational infrastructure under a large share
of modern hacks), **Project FastROM** (Super Castlevania IV, F-Zero, Axelay —
~30% faster cartridge access), and **wide-snes**, a true 16:9 Super Mario World
that renders extra playfield rather than stretching it.

Yamabuki should run all of it, and help make more of it. But the four are not
one feature, and it is worth being precise about which parts an emulator can
actually do.

**What is tractable.**

- **Soft-patching.** Apply BPS and IPS at load — `--patch <file>` — with the
  source ROM verified by hash first, so a patch silently landing on the wrong
  revision is an error rather than a corrupted cart. `--save-patched <out.sfc>`
  writes the result. Nothing is mutated on disk unless asked.
- **The SA-1 conversions already work.** Yamabuki emulates the SA-1 (M9), so a
  converted ROM is just a cart with an SA-1 in its header; it boots today. The
  patch layer is about *getting* the converted ROM, not about running it.
- **A patch registry.** A manifest keyed by source-ROM hash — fetched and
  revision-pinned, never vendored, exactly like the test data — so `--auto-patch`
  can find the right SA-1 or FastROM patch for the cart you actually loaded, and
  refuse when it does not recognise it. Patches are the authors' work and stay
  theirs; the repo carries the index, not the payload, and never a ROM.
- **Auto-FastROM (opt-in).** This one *is* mechanically derivable: set the speed
  bit in the header, make the code write `$420D` bit 0, and map the ROM into the
  fast banks. But it is not free — code timed against SlowROM access latency
  breaks — so it ships behind a flag and a compatibility list, never as a
  default. A heuristic that silently corrupts a save file is worse than no
  feature.
- **Widescreen, on the emulator side.** wide-snes needs a modified emulator
  because stock hardware cannot output the wider framebuffer; providing that
  wider framebuffer is squarely an emulator's job. The game-side patch stays
  per-game.

**What is not.** Automatically *generating* an SA-1 conversion for an arbitrary
ROM. Vilela's conversions are per-game reverse engineering — identifying which
routines can move, relocating the game's RAM into SA-1-visible regions, and
rewriting logic to run in parallel across two CPUs that share a bus. That is
authorship, not a transformation, and no emulator derives it from a binary. Any
roadmap entry promising otherwise would be fiction.

### The candidacy analyser — `--sa1-report`

The headline feature: a tool you trigger *from the emulator*, while the game
runs, that answers one question — **would this game convert well to the SA-1,
and what would it cost?** Play the game (or let a demo run); Yamabuki watches and
reports.

It works because of a hardware fact that decides the whole problem: **the SA-1
cannot see the SNES's WRAM.** `$7E0000-$7FFFFF` is invisible to it. The SA-1's
world is ROM, up to 256 KiB of BW-RAM on the cartridge, and **2 KiB of I-RAM**.
So a conversion is never "move this routine to the fast CPU" — it is *"move this
routine, and every byte of state it touches, out of WRAM."* That relocation is
the entire difficulty, and it is why the SMW SA-1 Pack's headline achievement is
relocating the game's logic memory rather than anything about the CPU. It is also
exactly the thing an emulator is in a perfect position to measure.

So the report is not a trace dump. It is an answer:

- **Is the game even CPU-bound?** — **done.** `yamabuki-headless <rom>
  --sa1-report` runs the game and answers it. See *The frame-budget profiler*
  below: this turned out to be much less obvious than it looks, and it is the
  question that kills most candidates outright.
- **Which routines cost the frame.** Cycles attributed per call site, so the code
  worth moving announces itself rather than being guessed at.
- **The working set of each hot routine, and where it lives.** For every address a
  hot routine reads or writes: WRAM, BW-RAM-able cartridge space, zero page, or
  MMIO. This is the number that decides the project — the volume of WRAM state a
  routine touches is precisely the volume that has to be relocated for the SA-1
  to run it.
- **The blockers.** WRAM the hot code shares with code that must stay on the
  S-CPU; DMA and HDMA sources that would have to move with it; MMIO the SA-1
  cannot reach. These are the reasons a promising-looking game turns out to be a
  nightmare, and they should surface in an afternoon rather than three weeks in.
- **A verdict, with its reasoning shown.** "78% of overrun frames are spent in
  three routines whose combined WRAM working set is 1.4 KiB — that fits I-RAM"
  is a conversion worth attempting. "Hot code touches 22 KiB of WRAM shared with
  the sprite engine" is a warning that saves someone a month. The tool's job is to
  make the second answer as cheap to obtain as the first.

The same instrumentation, dumped rather than summarised, gives the artefacts the
community already works with — execution coverage (which addresses ran, and as
code or data), hot-routine profiles, and RAM access maps — emitted in a format
the existing tooling eats, so the output joins that ecosystem rather than
starting a second one. Vilela's "SA-1 Collection" reconstructed disassemblies
from bsnes-plus trace logs and usage maps mailed in from playthroughs; Yamabuki
should be able to produce those as a by-product of someone simply *playing the
game*.

The analyser does not write the patch. It tells you whether the patch is worth
writing, and hands the author the map.

### The frame-budget profiler — step one, and what it cost

    $ yamabuki-headless "Super Mario World.sfc" --sa1-report

    SUPER MARIOWORLD
      lorom, no coprocessor, SlowROM
      profiled 1800 frames (30s) after 300 boot frames

      CPU utilisation   mean 44%   median 43%   p95 62%   max 100%
      slowdown          0 of 1800 frames (0.0%)
      stalls            1 (57 frames) — loads or transitions, not slowdown

      verdict: NOT CPU-BOUND
        The CPU idles through 56% of an average frame and never falls behind.
        A faster CPU has nothing to do here.

**You cannot measure this the obvious way.** On a SNES the CPU burns *exactly*
the same number of master cycles every frame — the scheduler runs it to the
scanline's clock target, always. It never "overruns its budget"; it never gets
the chance. When a game is too slow, what happens is that its main loop fails to
come round before the next vblank and a frame is dropped.

So the budget has to be measured by its complement: not the time the CPU spent
working, but the time it spent **waiting**. Idle time is headroom, and headroom is
precisely what an SA-1 buys back.

**A loop is a wait if it goes nowhere.** It touches a fixed handful of addresses
over and over, instead of reading and writing its way *through* memory. That is the
whole difficulty, because a checksum (`LDA $2000,y / ADC / INY / CPY / BNE`) is
tight, repetitive, and writes nothing for four thousand iterations — and it is
*working*. Its tell is that it **walks**: a different address every pass. A wait
watches the same one or two forever, because watching one spot for something else
to change it is what waiting *is*. (The address sets therefore have to be kept per
*loop*, not per pass: a checksum reads exactly one address per iteration, just like
a poll. They are only distinguishable across iterations.)

Four things had to be right before that rule could see anything at all, and every
one of them was a bug found by a game rather than by reasoning:

- **A loop is found by return, not by proximity.** The commonest SNES main loop is
  a *call* in a loop — `$8166: JSL check` / `$816A: BRA $8166`, which is Contra
  III's — and its seven addresses are spread over 6 KiB. Bounding the *span* of
  the program counter rejects that outright, and every other subroutine-shaped
  wait with it. Contra III came out at **100% utilisation on every frame, title
  screen included**, which is what gave it away.
- **Stack traffic is not a side effect.** That same `JSL` pushes three bytes every
  pass, so a naive "writes nothing" test throws the loop out again. A JSL/RTL pair
  leaves the machine exactly as it found it, so `Cpu.push8`/`pull8` go straight to
  the bus and never register as data accesses.
- **A wait is allowed to write.** The classic SNES idiom stirs a random seed while
  it spins — that is how a game seeds randomness from how long you took to press
  Start. Tetris & Dr. Mario's wait is `$86ED: JSR $8DAD` (an LCG on `$9E`) /
  `LDA $0BA6` / `BPL`, and it read **100% busy on every frame** until writes were
  allowed. Writing one fixed word changes nothing that matters; writing your way
  through a buffer does. The one thing a wait may never do is poke a **hardware
  register**, which is what stops a loop kicking off DMA (`STA $420B` — the same
  address every pass) from slipping through the same test.
- **The unit of judgement is one pass, not one window.** Judging a whole window of
  instructions at once lets working code that merely *precedes* a wait — a memory
  clear, say — condemn the wait that follows, because the window saw a write.
  Super Mario World's idle time vanished entirely.

One rule is worth recording as a dead end, because it is plausible and wrong:
*"a wait cannot exit on its own, so a loop ended by an interrupt was waiting."*
Both halves fail. A loop polling `$4212` exits under its own power the moment the
hardware sets the bit — no interrupt required — and *any* long-running loop is
eventually interrupted by the vblank NMI, checksums included, so the rule did not
even exclude the case it existed to exclude.

**Slowdown is not the same as a stall.** The independent check on all of the above
is the **lag frame**: a game polls the controller once per main-loop iteration, so
a frame in which it never read the pad is a frame its logic did not come round —
a dropped frame, which is what a player actually sees. (This is the definition TAS
tools use, and it comes from a completely different signal than the idle
accounting, so agreement between them is real corroboration.) But dropped frames
come in two kinds, and conflating them is how you talk yourself into a conversion
a game does not need: slowdown is a game failing to keep up *while it is still
playing*, so it drops one frame in two or three and its runs are short. An
unbroken fifth of a second with no input poll is a game doing something else
entirely — decompressing a level, running a fade. Both pin the CPU. Only one is a
reason to reach for an SA-1. Super Mario World's attract demo drops 66 frames in
1800 — 3.7%, comfortably "CPU-bound" — but **57 of them are one unbroken run**,
which is a level transition. The report separates them.

**What it still gets wrong**, said out loud rather than rounded in its own favour:
a wait the profiler fails to recognise reads as work, so utilisation is an **upper
bound** — real idle is at least what is reported. And a game that polls the pad in
its **NMI handler** polls every frame whatever its main loop is doing, so it can
never register a dropped frame: slowdown is a **lower bound**. The two errors point
in opposite directions and bracket the truth rather than compounding, which is the
main reason for keeping both signals. The upper bound on utilisation is the
direction that *flatters* a conversion, which is why the tool prints the caveat
every run. And nothing presses any buttons: what gets profiled is the attract loop,
which for most carts is real gameplay and for some is a title screen idling at 12%.

The profiler is a third comptime instantiation of the core (`ProfilingConsole`),
so the shipped emulator carries no branch for it — the same trick as `accuracy`.
Emulation under it is bit-identical: 5,120,000 SingleStepTests cases, 100 golden
ROMs, and the deterministic bench baselines are all unchanged.

The order matters: soft-patching first (it makes every existing patch usable),
then the analyser (it makes new ones possible), then auto-FastROM and widescreen
(they are narrower wins). Nothing here ships a ROM, and nothing here ships
someone else's patch — only the ability to apply one you have.

## Performance engineering

- **Comptime devirtualization everywhere** — the four CPU variants, bpp-
  specialized tile decoders, and the accuracy-specialized console mean zero
  function pointers on hot paths; the only runtime indirection is the per-frame
  tagged-union dispatch.
- **Tile-row decode cache** (M10) — the fast renderer decodes a whole 8-pixel
  tile row in one pass (each planar word read once and scattered across the
  eight pixels) instead of re-reading every plane word per pixel. Backgrounds
  memoize the decoded row by char-data address for the pixel run that shares
  it; sprites decode once per tile column. Output is bit-identical to the
  per-pixel decode (all goldens unchanged); it cuts VRAM fetch traffic ~8x for
  8bpp BG rows and for every 4bpp sprite tile — the win that compounds on
  cache-poor ARM.
- **SA-1 ROM-read fast path** (M10) — on a SA-1 cartridge the chip runs a
  second 65816 whose every fetch goes through `Sa1.read8`, which profiling put
  at ~38% of total work on Super Mario RPG. The Super-MMC bank map is now
  precomputed into a four-entry region table on register writes (rare) instead
  of a per-read switch, and `read8` tests the dominant ROM case first with the
  vector window folded in. Bit-identical (SMRPG and Kirby Super Star render and
  sound identical frame-for-frame); ~15% fewer total instructions and ~+15%
  headless FPS on SMRPG.
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
