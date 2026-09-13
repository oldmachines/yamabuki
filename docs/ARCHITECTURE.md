# Architecture

How the emulator is put together, and where to look for each piece. The
decisions that shape everything else are collected at the end; the roadmap
and milestone history live in [`ROADMAP.md`](ROADMAP.md).

## Repository layout

```
build.zig            every build step (see TESTING.md for the gates)
build.zig.zon        package manifest; pins minimum_zig_version
.zigversion          the exact Zig release the tree is built with
src/core/            the emulator core: pure Zig, no libc, no OS calls
src/frontends/       headless runner, SDL3 desktop player, libretro core
tests/               the runners behind `zig build test-*` and the fixtures
bench/               headless FPS benchmark + the deterministic perf baseline
tools/               host-side scripts: fetch test data, bake shaders, package
patches/             the patch REGISTRY (an index, never a payload)
shaders/             presets.conf (what ships) + the baked GLSL (gitignored)
docs/                this directory; docs/README.md is the index
site/                the landing page and its screenshots
```

### `src/core/` — the emulator

| Module | What it is |
|---|---|
| `core.zig` | Public API root: re-exports every module below and the `Console` instantiations. |
| `console.zig` | `Console(comptime cfg)`: wires CPU, bus, PPU, APU and DMA; owns the scheduler (`runFrame`, scanline stepping, NMI/IRQ), save states (`saveState`/`loadState`), and the profiler hooks. `AnyConsole` is the runtime tagged union over the fast and accurate instantiations. |
| `timing.zig` | Master-clock constants: cycles per line, lines per frame (NTSC/PAL), memory speeds, beam positions. |
| `serialize.zig` | Comptime-reflection save-state serializer. Refuses pointers; derived state is rebuilt by `postLoad` hooks. |
| `cpu/wdc65816.zig` | The 65C816 core: registers, flags, interrupts, the bus wrappers (`read8`/`write8`), and the diagnostics the SA-1 tooling hooks into. |
| `cpu/ops.zig` | The 256-way instruction switch, comptime-specialized on the M/X widths, plus every addressing mode. |
| `memory/bus.zig` | The system bus: a 2048-entry page table (8 KiB pages) for the fast path, `slowRead`/`slowWrite` for MMIO, open bus, and the coprocessor windows. |
| `memory/mappers.zig` | LoROM/HiROM/ExHiROM page-table builders; the small-SRAM slow path. |
| `memory/dma.zig` | GDMA and HDMA: eight channels, transfer-unit patterns, the S-DD1 decompressing feed. |
| `memory/cpu_io.zig` | `$42xx`: interrupt enables, H/V timer targets, `$4210`-`$4212` status. |
| `memory/math_unit.zig` | The `$4202`-`$4206` multiply/divide unit. |
| `memory/wram.zig` | 128 KiB WRAM and the `$2180`-`$2183` data port. |
| `memory/joypad.zig` | Two standard pads: `$4016` serial reads and auto-joypad. |
| `ppu/ppu.zig` | PPU register file, VRAM/OAM/CGRAM, the palette cache, frame assembly. |
| `ppu/line_render.zig` | The fast scanline compositor: all BG modes, sprites, windows, colour math, mosaic, hi-res; the tile-row decode cache. The accurate core renders the same code per span at the beam position. |
| `apu/apu.zig` | S-APU: ARAM, timers, the four ports, the HLE boot handshake, lazy catch-up scheduling. |
| `apu/spc700.zig`, `apu/ops.zig` | The SPC700 core and its instruction set. |
| `apu/dsp.zig` | The S-DSP: eight BRR voices, gaussian interpolation, ADSR/GAIN, noise, pitch modulation, echo, signed phase-exact mixing. |
| `cart/cartridge.zig` | ROM image (padded to a power of two, cyclic-mirrored), SRAM, chip identification. |
| `cart/header.zig` | Internal-header detection and scoring (LoROM/HiROM/ExHiROM, copier header). |
| `cart/patch.zig` | BPS/IPS soft-patching and the BPS writer. |
| `cart/registry.zig`, `cart/fastrom_compat.zig` | The `--auto-patch` index and the auto-FastROM compatibility list, both loaded from `patches/*.zon` at compile time. |
| `cart/patchgen.zig` | The FastROM patch generator (verified in-emulator before a BPS is written). |
| `cart/sa1gen.zig` | The SA-1 conversion generator: relocation, window relocation, mainline split, the Super Metroid rebanks, thunk emission. The largest file in the tree; see `SA1_CONVERSION_LEARNINGS.md`. |
| `chips/gsu.zig` | Super FX: the full RISC instruction set with the real prefetch pipeline, code cache and PLOT pipeline. |
| `chips/sa1.zig` | SA-1: the 65816 core instantiated a second time on its own bus, the Super MMC, BW-RAM projections, DMA, the arithmetic unit. |
| `chips/dsp1.zig` | DSP-1 at the command level, lookup tables regenerated at comptime. |
| `chips/cx4.zig` | Cx4 at the command level (wireframe, sprite math, scalar commands). |
| `chips/sdd1.zig` | S-DD1: the bank-window MMC and the entropy decompressor. |
| `profile.zig` | The frame-budget profiler behind `--sa1-report`: wait detection, lag frames, per-routine attribution, WRAM working sets, the relocation plan. |
| `usage_map.zig` | The 65816 opcode metadata table (`instrLen`, `mode`, `dataWidth`) and the bsnes-plus usage-map format. The one place opcode lengths are defined. |
| `callgraph.zig` | Call graph and per-routine complexity over a profiled image. |
| `sa1_trace.zig` | SA-1-side execution instrumentation. |

### `src/frontends/`

| Module | What it is |
|---|---|
| `headless/main.zig` | The CLI: plain runs, movie replay, every inspection instrument, the analyser, the patch generators, the harvest and baseline caches, threaded verification. `docs/CLI.md` documents every flag. |
| `sdl/main.zig`, `sdl/app.zig` | The desktop player: argument parsing, the session loop (video, audio, input, overlay menu, saves, rewind, takes), the library screen. |
| `sdl/sdl3.zig`, `sdl/gl.zig` | Hand-ported SDL3 and GL ES ABI subsets, resolved at runtime (`dlopen`, `SDL_GL_GetProcAddress`). No headers, no link-time dependency. |
| `sdl/shader.zig`, `sdl/preset.zig` | The multi-pass shader chain and the baked-preset manifest parser. |
| `sdl/input.zig`, `sdl/menu.zig`, `sdl/ui.zig`, `sdl/font.zig`, `sdl/osd.zig`, `sdl/infopanel.zig` | Bindings model, the overlay menu, software UI primitives, the 5x7 font, the shader toast, the info palette. |
| `sdl/config.zig`, `sdl/paths.zig`, `sdl/saves.zig`, `sdl/rewind.zig`, `sdl/library.zig`, `sdl/dirpicker.zig`, `sdl/patchfind.zig`, `sdl/takes.zig`, `sdl/png.zig` | Persistence and the player's screens: `config.zon`, per-user paths, `.srm` and state slots, the rewind ring, the ROM library, the folder picker, patch discovery, the takes screen, the PNG encoder. |
| `libretro/api.zig`, `libretro/core.zig` | The stable libretro ABI subset and the `retro_*` exports. |
| `movie.zig` | The `.ymv` input-movie format (versions 1 to 4) and the replay feed. |
| `cheat.zig` | Action Replay style held writes. |
| `util.zig` | Shared helpers: PPM/WAV writers, audio draining, the verification envelope. |

## Core architecture

### Hybrid accuracy via comptime specialization

`pub fn Console(comptime cfg: CoreConfig) type` is instantiated twice, fast
and accurate; runtime selection is a tagged union (`AnyConsole`) dispatched
only at frame and API granularity. Inside each instantiation every
`if (cfg.accuracy == .fast)` resolves at compile time: most of the source is
shared, dead code is eliminated, and there is zero hot-path indirection.
A third instantiation, `ProfilingConsole`, carries the analyser's hooks, so
the shipped emulator has no branch for them either.

### 65C816 CPU

Registers are plain integers; the P flags are a `u8` with mask operations;
`e` (emulation mode) is a bool. Dispatch is four comptime-monomorphized
interpreters keyed on the M/X flag widths: one generic
`dispatch(comptime m8, comptime x8)` with a 256-arm switch, instantiated for
each width combination. Every bus access charges master cycles from the
page's speed field, so instruction timing falls out of memory traffic. The
core is generic over its bus type, which is what lets the SA-1 reuse it on a
private bus and the SingleStepTests harness drive it on a recording mock.

### Memory bus

A 24-bit address space dispatched through a 2048-entry page table (8 KiB
pages) split into parallel read-pointer, write-pointer and speed arrays. The
fast path is two loads; the slow path is one `slowRead`/`slowWrite` switch
over the MMIO regions (`$21xx` PPU, `$2140-$2143` APU, `$42xx` CPU I/O,
`$43xx` DMA, `$2180-$2183` WRAM port) and the coprocessor windows. Open bus
is modelled with an MDR register. Mappers are page-table builders run once
at load and again after a save-state load or an MMC bank write.

### Scheduler

A `u64` master clock at 21.477 MHz; an NTSC line is 1364 cycles and a frame
262 lines (PAL: 312). The CPU drives; every other component owns a timestamp
and catches up. Events live in fixed slots (end of line, H/V-IRQ, NMI,
auto-joypad), so there is no heap and no priority queue. The fast core runs
the CPU to the scanline's clock target and renders the line; the accurate
core renders per span after each register write that can split a line.

### PPU

The fast scanline renderer evaluates OAM per line (with the real 32-sprite
and 34-tile limits), renders each enabled background into colour/priority
line buffers through decoders comptime-specialized on bits per pixel,
composites by priority, applies window spans computed once per line, colour
math and mosaic, and emits RGB565 end to end (palette converted at CGRAM
write time). Each tile row is decoded once and memoized by character
address; the `vram_reads` perf counter pins that optimization in CI.

### APU

The SPC700 interpreter (same comptime-switch style), 64 KiB ARAM, three
timers, four ports and the embedded IPL boot ROM. Execution is fully
decoupled with lazy catch-up: any CPU access to `$2140-$2143` first steps
the APU to "now", which is exact for the port handshake and the biggest
performance lever after CPU dispatch. The S-DSP mixes every volume and FIR
coefficient as a signed value, which is what preserves the Dolby Surround
matrix some games encode ([`AUDIO_SURROUND.md`](AUDIO_SURROUND.md)).

### DMA / HDMA

Eight channels. GDMA stalls the CPU at 8 cycles per byte plus fixed
overheads, with the transfer-unit patterns as a comptime table; HDMA
initializes at line 0 and transfers per line at H-blank in direct and
indirect modes. An S-DD1 channel armed through `$4800`/`$4801` takes its
A-bus bytes from the decompressor instead of ROM.

### Save states

All component state lives in plain, pointer-free structs. The serializer
walks them by comptime reflection; a versioned header carries the format,
the core accuracy and a layout fingerprint, and `postLoad` hooks rebuild
derived state (page tables, palette caches, chip wiring). Fixed-size state
keeps libretro's `retro_serialize_size` stable for a session, and a comptime
assert keeps the fast and accurate cores at the same state size.

### Enhancement chips

Each chip is emulated at the level its games actually observe. Super FX is
low level (real prefetch pipeline, code cache, PLOT pipeline) because games
depend on its behaviour cycle by cycle; DSP-1 and Cx4 are command-level HLE
because they do not. The SA-1 is the 65816 core instantiated a second time
on its own bus. The S-DD1's data has to be exact to the bit while its timing
is unobservable, so a decompressing DMA simply expands as the transfer runs.
Adding a chip means: a `ChipKind` in `cart/cartridge.zig` and its header
identification, a module under `chips/` with `init`/`attach`/`postLoad` and
its own serialized state, page-table entries or slow-path windows in
`memory/bus.zig` and `memory/mappers.zig`, a catch-up call from the
scheduler if it runs asynchronously, and unit tests that boot it in-process
(no chip has a public test ROM except Super FX).

### Frontends

- **headless** runs N frames, dumps `.ppm`/`.wav`, prints the framebuffer
  and audio hashes, replays movies, and hosts every analysis and generation
  instrument. It is the CI verification tool and the SA-1 pipeline's driver.
- **libretro** exports the stable ABI subset with `callconv(.c)`: RGB565
  frames with zero conversion, 32 kHz audio batches, both pads, serialize
  and unserialize through the versioned state container, SRAM via
  `retro_get_memory_*`. `zig build test-libretro` locks it to the same
  golden hashes as the direct console path.
- **SDL3 desktop** dlopens `libSDL3` at runtime, so `zig build` needs no
  SDL headers or libraries and the binary cross-compiles everywhere. A
  software blit or a GL ES 3 / GL 3.3 / GL ES 2 shader chain (falling back
  rung by rung, never costing the user the emulator), an overlay menu drawn
  into the RGB565 frame so the shader shades it too, remappable gamepads,
  `.srm` saves with debounced autosave, eight state slots, hold-to-rewind
  on an XOR+RLE delta ring, PNG screenshots, a scanned ROM library, input
  movie recording, and per-game overrides, all persisted under
  `SDL_GetPrefPath`.

## Design notes

**Performance is gated deterministically, not by wall clock.** Timing a
frame in CI is flaky, so the perf baseline (`bench/baseline.zon`) pins three
counters per ROM instead: `steps` (instructions retired), `cycles` (master
clock), and `vram_reads` (renderer word fetches). All three are identical
across Debug/ReleaseFast and across targets, so `zig build bench-check`
fails on drift rather than on noise. Deleting the tile-row decode cache
multiplies `vram_reads` about eightfold and turns the gate red.

**Accuracy is a `comptime` parameter, spent at frame granularity.** Only a
handful of sites in the core branch on `cfg.accuracy`, all at scanline or
frame level. Choosing a core costs one switch per frame, not one per pixel.

**Save states are `comptime` reflection over plain data, and a pointer is a
compile error.** That forces derived state to be rebuilt by `postLoad`
instead of persisted, so it cannot silently rot, and it makes `byteSize(T)`
comptime-known.

**A `Console` is self-referential: heap-allocate it and never move it.** The
bus page table holds pointers into `self.cart` and `self.bus.wram`, and the
CPU holds `&self.bus`. Construct in place with `init` and never copy the
value afterwards.

**Test data is fetched and revision-pinned, never vendored.** CI resolves
the upstream SingleStepTests and PeterLemon repositories with `git ls-remote`
at run time; no ROMs or vectors are committed. See [`TESTING.md`](TESTING.md).

**Zero build-time dependencies is a hard constraint.** SDL3 is not linked;
the frontend hand-ports the ABI subset it needs. `tools/package_handheld.sh`
asserts the musl build is statically linked, because a handheld firmware
will not supply the shared objects a stray dynamic dependency would demand.

**Work that can happen on the build host does not happen on the device.**
The CRT shaders are compiled ahead of time by glslang and SPIRV-Cross on the
build host ([`SHADERS.md`](SHADERS.md)); the binary holds no shader
compiler, no SPIR-V and no image decoder.

**Process-global diagnostics are the one departure from "no globals".** The
SA-1 conversion tooling hooks the CPU, DMA and PPU through `dbg_*` globals
that are off in normal play. They cost a load and a predicted branch on the
hot path and they couple every `Console` in the process; moving them behind
a comptime core config is the next performance step (see the audit in
[`AUDIT_2026-09.md`](AUDIT_2026-09.md)).
