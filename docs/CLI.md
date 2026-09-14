# Command-line reference

yamabuki ships two executables. `yamabuki-headless` runs a ROM without a
window — it dumps frames and audio, replays recorded input, profiles a game
for SA-1 candidacy, and generates verified FastROM and SA-1 conversion
patches. `yamabuki-sdl` is the desktop player (SDL3, shaders, save states,
movie recording, a ROM library). A third artefact, `yamabuki_libretro`, is
the RetroArch core; it has one core option. This file is the complete
reference; each binary's `--help` (printed on any usage error) is the short
version. Every flag below was read out of `src/frontends/headless/main.zig`,
`src/frontends/sdl/main.zig`, `src/frontends/sdl/input.zig` and
`src/frontends/libretro/core.zig`; where a flag's purpose is only stated in
a code comment, the table says so.

Conventions: `hex16`/`hex24` are bare hexadecimal without a `$` or `0x`
prefix (`--watch 2131`, `--wg-split 828948`); frame counts and clocks are
decimal; repeatable flags say so in the Argument column. The ROM is the one
positional argument; a second positional is a usage error.

---

## 1. `yamabuki-headless`

```
yamabuki-headless <rom.sfc> [flags]
```

Modes are chosen by flag: a plain run (no mode flag), `--sa1-report`,
`--gen-fastrom-patch`, `--gen-sa1-patch`, `--behavioral-probe`. The two
`--gen-*` modes run their own baseline and verify passes and refuse to be
combined with `--patch`, `--auto-patch`, `--save-patched`, `--auto-fastrom`,
`--accurate`, `--wide`, `--sa1-report` or each other; `--whole-game`
(and therefore `--window`) needs `--gen-sa1-patch`; `--usage-map` and
`--call-graph` need `--sa1-report`.

### 1.1 Running a ROM

A plain run emulates N frames and prints one line: ROM, frame count,
resolution, the final frame's hash and the audio hash.

| Flag | Argument | Default | What it does |
|---|---|---|---|
| `--frames` | `N` | plain run: 1, or the movie's length when `--movie` is given; `--sa1-report`: 3600 (after `--skip`); `--behavioral-probe`/`--tick-dump`: 600 | How many frames to emulate. In the generator modes the movies set the length and `--frames` caps it. |
| `--ppm` | `out.ppm` | none | Write the final frame as a binary PPM (P6). |
| `--wav` | `out.wav` | none | Write the run's audio as a WAV. |
| `--region` | `ntsc\|pal\|auto` | `auto` | Video region; `auto` reads the cart header. |
| `--accurate` | — | fast core | Use the dot-accurate PPU/timing core instead of the fast core. Not compatible with `--wide` or `--tick-dump`. |
| `--state` | `f.state` | power-on | Resume from an SDL-player save state instead of power-on. Plain runs and `--sa1-report`: same image and same core only (`--movie-ignore-crc` lifts the image check). With `--gen-sa1-patch` it anchors both the profile and the verify runs at that scene, so candidates come from a stretch with real slowdown; a state saved on an earlier conversion of the same game works. |
| `--srm` | `f.srm` | blank SRAM | Load a battery save into the cart's save chip (or a window conversion's lifted save region) before the first frame. |

### 1.2 Patching

| Flag | Argument | Default | What it does |
|---|---|---|---|
| `--patch` | `p.bps\|p.ips` | none | Apply a BPS or IPS patch to the ROM in memory at load. BPS is CRC-verified both ways; IPS is applied unverified with a warning. Overrides `--auto-patch`. |
| `--auto-patch` | — | off | Look the ROM up by content hash in `patches/registry.zon` and apply its registered patch from `--patch-dir` (verified, never downloaded). |
| `--patch-dir` | `DIR` | `patches` | Where `--auto-patch` looks for the patch files. |
| `--save-patched` | `out.sfc` | none | Write the patched image and exit without emulating. Needs `--patch` or `--auto-patch`. |
| `--auto-fastrom` | — | off | Pin MEMSEL=1 (FastROM cartridge timing for a SlowROM game), gated by `patches/fastrom-compat.zon`: a game listed `broken` is refused, an unlisted game runs with a warning. |
| `--wide` | `N` | 0 | Render N extra columns on each side of the standard 256 (e.g. 32 gives 320x224), for widescreen game patches such as wide-snes. Fast core only; N is capped at `core.ppu.wide_margin_max`. |

### 1.3 Input and movies

Movies are `.ymv` files recorded in the SDL player. A plain run replays one
movie from power-on (or from the state it carries) and verifies its recorded
end hashes; the report and generator modes use movies to drive the profiled
runs instead of the attract mode.

| Flag | Argument | Default | What it does |
|---|---|---|---|
| `--movie` | `f.ymv` (repeatable, up to 12 with `--evidence-movie`) | none | Replay a recorded playthrough. `--gen-sa1-patch` accepts several: each is a verification SURFACE, their evidence and coverage are unioned, and every one must verify. |
| `--movie-ignore-crc` | — | off | Replay a movie (or load a `--state`) whose recorded image CRC differs from this image — for re-playing a take recorded on a previous conversion against a regenerated one. The end-hash check becomes advisory. |
| `--poke` | `ADDR=VAL[,ADDR=VAL...]` (hex; repeatable) | none | Hold byte VAL at BUS address ADDR after every frame, as an Action Replay does. The address is where the byte lives in THIS image: `7E0086` on stock, `006086` on a window conversion (low 8 KiB moved into BW-RAM). |
| `--cheat` | `CODE[+CODE...]` (repeatable) | none | Action-Replay-style codes (`ADDRVV`), same syntax as the SDL player's `--cheat`; parsed into the same held-write list as `--poke`. |
| `--repoll` | `out.ymv` | none | While replaying `--movie`, re-record it as a PER-POLL take (format 3): one entry per controller read the game made, so it replays on any build whose logic is behaviorally equivalent (stock take migrated to a conversion, lag frames and all). Same anchor, same end hashes. |
| `--repoll-poweron` | — | off | Write the re-polled take without the source take's anchor, for a take whose anchor is a powered-on machine with a battery save loaded and nothing run: the result replays from power-on with `--srm` (a `.start.srm` sidecar is written beside it). |
| `--lap-cell` | `hex16` | 0 (off) | Tick per write of this low-WRAM cell (the game's lap counter) instead of per pad poll; `--repoll` then writes a per-lap (format 4) take. A per-lap take sets this on load. |

### 1.4 Inspection and debugging

Most of these set a global in the core (`dbg_*` in `src/core/`) and print to
stdout or stderr as the run goes; several have print quotas that fill early
on a long take, which is what the `-from` companions are for. Watch, stale
and trace lines print post-fetch PCs (site = pc − instruction length).

| Flag | Argument | Default | What it does |
|---|---|---|---|
| `--dump-vram` | `file` | none | After the run, write raw VRAM (64 KiB) followed by OAM (544 B) — byte-exact for cross-image diffs. |
| `--dump-ppu` | `file` | none | After the run, write the PPU display state as text (layer enables, tilemap/chr bases, scroll, windows) — the question a RAM dump cannot answer. |
| `--dump-ram` | `file` | none | After the run, write WRAM + BW-RAM + VRAM to one file (window-conversion debugging; comment says TEMP). |
| `--dump-srm` | `file` | none | After the run, write the cart's battery SRAM — the way to lift a save out of a state (`--state x --frames 1 --dump-srm x.srm`) for `yamabuki-sdl --record --srm`. |
| `--watch` | `LO[-HI]` (hex16, ONE dashed argument) | off | Log every CPU write in this address range with PC and value: WRAM offsets (banks $7E/$7F and their $40/$41 homes) and MMIO `$2100-$4400` alike. Capped at 4096 prints. The printed address is the full 24-bit access, so disambiguate a port from a WRAM offset by bank. |
| `--watch-from` | `clock` (decimal) | 0 | Arm `--watch` only at or after this master clock, to spend the print budget late in a take. |
| `--watch-min` | `hex8` | 0 (all) | Only log watched writes whose value is >= this. |
| `--trace-clk` | `FROM-TO` (decimal clocks) | off | Instruction trace over a master-clock window, to stderr. Records may be concatenated on one line. |
| `--trace-sa1` | `N` | 0 | Trace up to N SA-1 instructions once the watch arms (prints the SA-1's clock). |
| `--hash-stream` | `file` | none | Write one u64 frame hash per frame. The cheap "did the build change what the game does, or only how fast" oracle, since the picture stream survives a lag differential. |
| `--ppm-range` | `START:COUNT[:PREFIX]` | prefix `frame` | Dump every frame in [START, START+COUNT) as `<PREFIX>NNNNN.ppm` (5-digit, zero-padded) — a frame window to assemble into a recording. |
| `--tick-dump` | `file` | none | Write every logic tick's phase-aligned WRAM snapshot (u32 wall frame + 128 KiB raw, repeated). Fast core only; runs 600 frames unless `--frames` says otherwise. A design diagnostic for the behavioral verifier. |
| `--dma-trace` | `MAX[:FROMCLK]` | off | Log up to MAX general-purpose DMA transfers (source, destination, size), optionally only from a master clock. Finds transfers left reading memory a window conversion abandoned — invisible to `--stale`, which only sees CPU accesses. |
| `--apu-port-trace` | — | off | Print every write to APU port 3 with its clock. |
| `--bg-disable` | `hexmask` | 0 | Mask layers OUT of TM/TS at render time: BG1=1, BG2=2, BG3=4, BG4=8, OBJ=10. Render-only. |
| `--hdma-disable` | `hexmask` | 0 | Skip these HDMA channels each scanline (bit per channel), to isolate which per-scanline effect a picture depends on. |
| `--no-color-math` | — | off | Skip the `$2130-$2132` blend entirely, to tell an emulator compositing difference from the game tinting the scene. |
| `--clock-pc` | `hex24` | off | Print the master clock at the FIRST fetch of this PC (one-shot latch; the bank folds through $7F so fast mirrors match). No line means it never ran. |
| `--dma-bank-pc` | `N` | 0 | Trap up to N writes to the DMA/HDMA A-bus bank and indirect bank registers (`$43x4`, `$43x7`), printing PC/channel/value and `<-- ABANDONED` on `$7E`/`$7F` — names who armed a transfer reading a moved home. |
| `--iram-dump` | — | off | After the run, on an SA-1 cart under the fast core, print the SA-1's PC, its RESB state and I-RAM `$3780-$37BF` (the offload mailbox and split cells). |
| `--stale` | `MAX[:FROMCLK]` | off | BW-RAM window conversions: report data accesses to the ABANDONED WRAM homes below `$2000` — each (PBR,PC) once, MAX distinct sites — every hit is a site the rewrite failed to move. Run it on every take first. |
| `--stale-ring` | — | off | With `--stale`: the SA-1 core keeps a ring of its last 8,192 instructions and dumps it on the first stale hit. |
| `--code-map` | `file` | none | Load a hand-made disassembly's per-byte code/data verdict (`tools/sm_disasm_oracle.py --export`) for the generator and the `--stale` classifier to consult. |
| `--call-graph` | `out.dot` | none | `--sa1-report` modifier: write the routine call graph (Graphviz DOT), seeded from the profiled routines and the usage map. |
| `--routines` | — | off | `--sa1-report` modifier: the per-routine cycle attribution table (self/inclusive cycles per call site, top 16), each routine's WRAM working set, MMIO blockers and page sharing. |
| `--routines-all` | — | off | `--routines` with every row instead of the hot sixteen (for analyses that need every MMIO-touching routine). |
| `--hot` | — | off | `--sa1-report` modifier: also list the loops the frame is spent in and how each was classified. |
| `--usage-map` | `out.bin` | none | `--sa1-report` modifier: export the profiled run's execution/access coverage as a bsnes-plus `-usage.bin` (code vs data with M/X widths plus the RAM access map; DiztinGUIsh imports it). |
| `--cov-out` | `prefix` | none | With `--gen-sa1-patch`: write the coverage the relocation walked as `<prefix>.usage` (profiled union) and `<prefix>.cov` (its static extension), one usage-map flag byte per CPU address, for `tools/sm_disasm_oracle.py`. |
| `--walk-watch` | `hex24[,hex24...]` (up to 8) | none | Report the first static decode of each address as an opcode, with the path that reached it (debugging the recursive-descent walk behind `--wg-static`). |

### 1.5 The SA-1 candidacy analyser

`--sa1-report` answers "is this game CPU-bound?": it skips the boot, profiles
the next N frames (a movie or a state supplies gameplay), and prints CPU
utilisation, slowdown, stalls and a verdict. The modifiers in 1.4
(`--hot`, `--routines`, `--usage-map`, `--call-graph`) extend it.

| Flag | Argument | Default | What it does |
|---|---|---|---|
| `--sa1-report` | — | off | Run the analyser instead of a plain run. |
| `--skip` | `N` | 300 | Frames to run before profiling starts (boot is not gameplay). |
| `--plan` | — | off | Print the relocation plan for the hot set: which WRAM state moves to SA-1 I-RAM vs BW-RAM, with the dp window, DMA feeds and sharing per region. |
| `--json` | — | off | Emit the report as JSON instead of text. |
| `--audit` | — | off | With `--gen-sa1-patch`: convert ONCE, print the per-site conversion audit (what the rewriter decided about every memory-touching site, recorded as the decisions are made) and stop before verification — minutes instead of the whole ladder. |
| `--evidence-movie` | `f.ymv` (repeatable; shares the 12-movie cap) | none | Like `--movie` but the take only contributes evidence and coverage — it is never a verification surface. For playthroughs whose later stretch forks from stock at the first RNG-divergent event. |
| `--ev-only` | — | off | Stop right after the `--site-ev` report, before any plan, conversion or verification work. |
| `--site-ev` | `hex24[,hex24...]` (up to 16) | none | After profiling, print each address's union evidence byte and coverage flags for both homes (`cov`/`cov80`, `ev`/`ev80`). |
| `--behavioral-probe` | `conv.sfc` | none | Run ONLY the behavioral verification tier: the positional ROM is the stock baseline, the argument is the converted image, the `--movie` takes are the surfaces; prints the verdict with its full accounting. Honours `--ref-overclock`, `--conv-overclock` and `--wg-split-mode`. |

### 1.6 FastROM patch generation

| Flag | Argument | Default | What it does |
|---|---|---|---|
| `--gen-fastrom-patch` | — | off | Derive a FastROM conversion for a SlowROM game and verify it in-emulator (every frame pixel- and audio-identical to the unpatched run, MEMSEL held). Only a verified patch is written, as BPS. |
| `--out` | `p.bps` | `<rom>.bps` (FastROM), `<rom>-sa1.bps` (SA-1) | Where the generated patch goes. The exact command line is written beside it as `<patch>.bps.cmd`. |

### 1.7 SA-1 patch generation

`--gen-sa1-patch` converts the game to an SA-1 cart and verifies the result
against the stock run on every surface before writing anything. Three
shapes exist: the default routine-offload ladder, `--whole-game` (SA-1
Root: the whole game on the SA-1) and `--window` (the game stays on the
S-CPU, its memory moves; the S5 `--wg-split*` flags then put the per-frame
logic on the SA-1 in place). See `docs/SA1_CONVERSION_LEARNINGS.md` for the
architecture and `docs/SM_SA1_FINDINGS.md` for the campaign log.

| Flag | Argument | Default | What it does |
|---|---|---|---|
| `--gen-sa1-patch` | — | off | Generate an SA-1 conversion patch (shell + the plan's clean state relocations), verified frame- and audio-identical before anything is written. |
| `--whole-game` | — | off | Whole-game migration (SA-1 Root): the game executes on the SA-1, the S-CPU becomes an MMIO service loop. Needs the WRAM working set inside I-RAM's identity window and refuses by name when it cannot prove the move. |
| `--window` | — | off | Uniform window relocation: WRAM's low 8 KiB moves into the S-CPU's BW-RAM window (+$6000) and $7E/$7F longs re-bank to $40/$41; the game keeps running on the S-CPU, MMIO stays native. Implies the whole-game pipeline shape (all-or-nothing, no candidates). |
| `--wg-static` | — | off | With `--whole-game`/`--window`: also rewrite code the profiled run never reached, found by recursive-descent disassembly seeded from coverage; unprovable shapes there are counted, not refused over. |
| `--wg-fastrom` | — | off | Window mode: layer the FastROM transform onto every attempt image (MEMSEL stub, interrupt trampolines into the $80 mirrors, observed MEMSEL stores NOPed) — about 25% off every remaining S-CPU ROM cycle. |
| `--wg-drop` | `hex16` (repeatable, up to 8) | none | Pre-seed the offload bisect's dropped list: exclude a tree the surfaces pass but live play proves unsafe. |
| `--wg-nmi-off` | `hex16` (repeatable, up to 8) | none | Wrap these trees' sync stubs in NMI/IRQ-off across the dispatch (closes the concurrent-mutation hazard; the tree never ships async). |
| `--wg-add` | `hex24` (repeatable, up to 8) | none | Extra offload candidates, for routines a single-scene profile ranks too low to offer. |
| `--wg-split` | `hex24` | 0 (off) | S5 mainloop split: the engage anchor at the main loop's top (any code bank). Its first 4-8 bytes must be whole, flow-free instructions (a JSL is fine). Ignored when `--wg-split-tail` is set. |
| `--wg-split-tail` | `TAIL:EPILOGUE:DBR` (hex16:hex16:hex8) | off | S5 NMI-tail split (the shape where the engine runs inside the NMI handler): the logic chain from TAIL (must begin with a 4-byte JSL) to the handler's EPILOGUE runs on the SA-1's frame loop; the S-CPU keeps the vblank upload cluster before it. DBR is the bank the handler establishes before the boundary. |
| `--wg-split-mode` | `CELL:VALUE[-HI]` (hex) | off | Gameplay-mode gate: the split runs on the SA-1 only while the game-mode cell holds VALUE (or any value in VALUE..HI); menus and transitions run native on the S-CPU. Tail flavor: CELL is a direct-page offset; mainloop flavor: a 16-bit low-WRAM address read at its window home. |
| `--wg-split-io` | `hex24[:d][:l][:f]` (repeatable, up to 40) | none | An IO routine the S-CPU pump replays (OAM/VRAM/CGRAM/APU writers; its first 3 bytes must be whole branch-free instructions). `:d` = deferred (a handshake body that read-waits on hardware; skipped on the SA-1 post-engage, pump-only), `:l` = RTL-shaped (JSL-called), `:f` = fire-and-forget (ring 2, replayed at frame exit, the SA-1 does not wait). `--sa1-report` prints the suggested lines. |
| `--wg-split-vbl` | `LO-HI` (hex24, repeatable, up to 8) | none | Address ranges whose absolute reads of `$4212` and `$4218-$421F` swap to the I-RAM mirrors — the mainline's vblank wait and pad reads. |
| `--wg-split-shared` | `file` | none | Hand the generator the S-CPU instruction set recorded by `--split-scpu-set`: math-register sites outside it become direct I-RAM cell accesses instead of COP dispatches (trigger stores keep the COP). |
| `--split-scpu-set` | `file` | none | On a replay of a split image, record (and merge into the file) every S-CPU instruction address run while the split's upper copy was mapped. |
| `--wg-expand` | `bytes` or `Nm` (power of two) | 0 (keep size) | Grow the converted image to this size, new banks filled with `$FF` (the byte the padding allocators treat as free) and the header size byte updated. `1m` = 1 MiB. |
| `--wg-copy-reserve` | `bytes` | 2560 | Bytes held back at the tail of the biggest padding run for offload tree copies. |
| `--conv-overclock` | `n` | 1 | Behavioral tier: the CONVERSION side's S-CPU and SA-1 run n times faster in the gate's eras; with `--ref-overclock` the tier compares two lag-free machines. |
| `--conv-pad` | `frames` | 0 | Delay the converted side's movie feed by this many frames (a frame-aligned boot pad displaces the game's timeline; input must follow it). Comment calls it a TEMP experiment. |
| `--ref-overclock` | `n` | 1 | Behavioral tier: the BASELINE's S-CPU runs n times faster (a lag-free stock reference). On a plain run of a conversion image it overclocks that image's CPUs instead (a measurement). |
| `--cover-image` | `patched.sfc` (repeatable, up to 64 pairs) | none | Opens a cover pair: harvest COVERAGE (opcode and width bits, no site evidence) from a movie replayed on a PREVIOUS conversion of this game, merged into the union wherever the instruction byte matches stock — how gameplay reachable only on the conversion still teaches the rewriter which code exists. |
| `--cover-movie` | `f.ymv` | none | The movie for the pair the preceding `--cover-image` opened. |
| `--mmio-ref` | `<patch>.mmio` | none | On a plain replay of a conversion: report every hardware-register write from a site the generation never saw write that register (the `.mmio` writer-set file written beside a patch). The MMIO analogue of `--stale` for a human take. |
| `--mmio-out` | `file` | none | On a plain replay: write this run's writer set (`S` lines) plus the image's padding ranges (`P` lines) — run on STOCK to make a `--mmio-ref` reference without a generation. |
| `--mmio-stock` | `stock.sfc` | none | With `--mmio-ref`: a writer whose bytes still read as stock's instruction is reported separately (stock code the reference never reached, not a relocation). |
| `--s2-keep` | `i,j,...` (plan-region indices) | none | With `--gen-sa1-patch --state`: keep only these plan regions as live relocations (dp always dropped; offload candidates disabled), to bisect the relocation plan. Comment calls it TEMP S2 debugging. |
| `--save-attempt` | `out.sfc` | none | Write each verification attempt's converted image to this path (last attempt wins) — the image that actually shipped. |
| `--save-state-at` | `FRAME=path` | none | Replay to FRAME, then write the machine as a save state. How a late-game scene reaches the generator (`--state`) without a power-on take. |
| `--verify-behavioral` | — | off | S4: when the pixel gate says divergent, also run the behavioral tier — logic-state equality at every logic tick — and accept a conversion whose divergence is only wall-time echoes (timing-changing offloads). |

### 1.8 Build-speed caches and parallelism

| Flag | Argument | Default | What it does |
|---|---|---|---|
| `--harvest-cache` | `dir` | none | Cache each cover pair's harvest (usage map, site evidence, proven bank bytes, armed HDMA tables) keyed by the cover image's CRC32, the movie's hash and a version; a generation replays only pairs it has not seen. |
| `--harvest-jobs` | `N` | min(12, CPU count) | Threads for cover-pair replays that still need running; merges stay on the main thread in recipe order, so the union is the same at any N. |
| `--harvest-render` | — | off | Paint frames during harvest replays (the default skips the pixel work). |
| `--baseline-cache` | `dir` | none | Snapshot of a generation's stock side (evidence pass, per-surface baselines, coverage pad) keyed on every input; a hit skips the stock replays (about 27 minutes on the Super Metroid recipe). |
| `--verify-jobs` | `N` | 0 (one per core, capped at the surface count) | Surfaces verified concurrently; 1 is the serial loop. |
| `--wg-sync` | — | off | Window offloads: never try the async flavor (the async monopoly admits one tree; a passing async first attempt would ship alone even when the sync ladder carries more trees). |

---

## 2. `yamabuki-sdl`

```
yamabuki-sdl [rom.sfc] [flags]
```

With no ROM argument the player opens the library scanned from
`config.zon`'s `library.rom_dirs`. `--frames`, `--shot`, `--patch`,
`--auto-fastrom` and `--movie` need an explicit ROM. Interactive runs read
`config.zon` from the per-user data directory; a `--frames N` run does not
(it is CI's smoke mode).

| Flag | Argument | Default | What it does |
|---|---|---|---|
| `--scale` | `N` (1..8) | config `video.scale` (3) | Window scale factor. |
| `--frames` | `N` | 0 (run until quit) | Emulate N frames then exit; unattended mode with no config. |
| `--no-audio` | — | audio on | Do not open an audio device. |
| `--accurate` | — | fast core | Use the dot-accurate core. Not compatible with `--wide`. |
| `--region` | `ntsc\|pal\|auto` | `auto` | Video region; `auto` reads the cart header. |
| `--shader` | `NAME` | none | Run the frame through this libretro CRT shader preset from `shaders/presets.conf`; `,` / `.` cycle the rest at runtime. |
| `--shader-dir` | `DIR` | `shaders` | Where shader presets are looked up. |
| `--shot` | `PREFIX` | none | Write `PREFIX-<frame>.ppm` at each frame in `--shot-frames`, or at the final frame (which then needs `--frames`). With a shader loaded this captures the rendered picture off the GPU; without one, the console framebuffer. |
| `--shot-frames` | `a,b,c` | none | Frame numbers `--shot` captures. |
| `--patch` | `p.bps\|p.ips` | none | Apply a BPS/IPS patch in memory at load (BPS CRC-verified, IPS with a warning). |
| `--auto-fastrom` | — | off | Pin MEMSEL=1, gated by `patches/fastrom-compat.zon` (`broken` refuses, unknown warns). |
| `--wide` | `N` | 0 | Extra columns rendered on each side of 256 (fast core only). |
| `--cheat` | `CODE[+CODE...]` (repeatable) | none | Action-Replay-style code (`ADDRVV`), held every frame; a WRAM code is also applied where relocation moved that byte, so cheat-list codes work on conversions. Codes start disabled; `F8` toggles them. |
| `--poke` | `ADDR=VAL[,...]` (hex; repeatable) | none | Same as `--cheat` but exact: no relocation mirror. |
| `--movie` | `f.ymv` | none | Replay a recorded playthrough from power-on; live input takes over when it ends. A per-poll take also replays on another build of the same game. |
| `--record` | — | off | Start recording a `.ymv` at power-on, before the first frame; `F10` stops and saves it. |
| `--continue` | — | off | With `--movie`: keep recording from the take's end; the saved file is the whole take. Starts from `<take>.end.state` when it still loads on this build, else replays the take at full speed. |
| `--srm` | `f.srm` | blank SRAM | With `--record`: start the take from this battery save; it rides beside the take as `<take>.start.srm` and every replay loads it first. Each `--record` session also writes its own `<take>.srm`. |

### Hotkeys and default bindings

Defaults from `src/frontends/sdl/input.zig` (`HotkeyStrings`, `InputConfig`);
all are rebindable in the overlay menu or in `config.zon`.

| Key | Action |
|---|---|
| `Esc` / pad guide button | Open the overlay menu (settings, remapping, state slots, per-game overrides, quit) |
| `Tab` (hold) / right trigger | Fast-forward |
| `Backspace` (hold) | Rewind |
| `P` | Pause |
| `F5` / `F9` | Save / load state |
| `F6` / `F7` | Previous / next state slot |
| `F1` | Reset |
| `F12` | PNG screenshot |
| `F10` | Toggle input-movie recording (starts with a repower; stops by writing the `.ymv`) |
| `F11` | The takes screen: continue any recording of this game from its end state or from its beginning |
| `F8` | Toggle `--cheat`/`--poke` codes (they start off) |
| `I` | Toggle the session info palette |
| `,` / `.` | Previous / next shader (README; handled in `app.zig`) |
| Arrows | D-pad |
| `Z` / `X` / `A` / `S` | B / A / Y / X |
| `Q` / `W` | L / R |
| `Enter` / `Right Shift` | Start / Select |
| Gamepad | south=B, east=A, west=Y, north=X, LB=L, RB=R, start=Start, back=Select, d-pad or left stick |

---

## 3. libretro core options

`yamabuki_libretro` announces one core option (`src/frontends/libretro/core.zig`):

| Option | Values | Default | What it does |
|---|---|---|---|
| `yamabuki_accuracy` | `fast` \| `accurate` | `fast` | Which console core is instantiated. Read once at load-game, so changing it takes effect on the next game load (restart the content). |

Cheats arrive through the frontend's cheat interface (`retro_cheat_set`): up to 32 slots, each an Action Replay `ADDRVV` code (several joined with `+`, the same syntax as `--cheat`), held after every frame while enabled; a code that does not parse is ignored.

---

## 4. Recipes

Dump the 60th frame and the audio of a ROM (README):

```sh
zig build && ./zig-out/bin/yamabuki-headless <rom.sfc> --frames 60 --ppm out.ppm --wav out.wav
```

Play in a window at 3x with a CRT shader, or open the library (README):

```sh
./zig-out/bin/yamabuki-sdl <rom.sfc> --scale 3 --shader crt-lottes
./zig-out/bin/yamabuki-sdl
```

Replay a recorded take headless and verify its end hashes; add `--stale 64`
on a window conversion to list every access the rewrite failed to move
(`docs/SM_SA1_FINDINGS.md`, "run `--stale` on every take first"):

```sh
yamabuki-headless <conv.sfc> --movie <take.ymv> --stale 64
```

Check a conversion's hardware writes against the writer set shipped beside
its patch (`docs/SM_SA1_FINDINGS.md`):

```sh
yamabuki-headless <conv.sfc> --movie <take.ymv> --mmio-ref <patch>.mmio --mmio-stock <stock.sfc>
```

Is this game CPU-bound? (README, `docs/ROADMAP.md`):

```sh
yamabuki-headless "Super Mario World.sfc" --sa1-report
yamabuki-headless "Super Mario World.sfc" --sa1-report --movie gameplay.ymv --hot --routines --plan
```

Generate a verified FastROM patch (default output `<rom>.bps`):

```sh
yamabuki-headless <rom.sfc> --gen-fastrom-patch --out <rom>.bps
```

Lift a battery save out of a save state, then record a new take from it:

```sh
yamabuki-headless <rom.sfc> --state scene.state --frames 1 --dump-srm scene.srm
yamabuki-sdl <rom.sfc> --record --srm scene.srm
```

The SA-1 window/split generation as documented in
`docs/SA1_CONVERSION_LEARNINGS.md`, with the two caches that turn a
36-minute build into a ~8-minute one on a warm cache. Do not reconstruct
this from prose: every generated patch carries its exact invocation in
`<patch>.bps.cmd` — reuse that.

```sh
yamabuki-headless <rom.sfc> --gen-sa1-patch --window --wg-static --wg-fastrom \
    --verify-behavioral --state <gameplay.state> \
    --movie <surface1.ymv> ... --movie <surface5.ymv> \
    --cover-image <prev-build.sfc> --cover-movie <recorded-on-it.ymv> ... \
    --wg-expand 1m --wg-copy-reserve 3600 --conv-pad 1500 \
    --wg-split-tail 8298:82bc:01 --wg-split-mode 94:01 \
    --wg-split-io 86e1:d:l --wg-split-io 9a68:d:l:f ... \
    --harvest-cache hcache --baseline-cache bcache --wg-sync \
    --out <patch.bps> --save-attempt <ship.sfc>
```
