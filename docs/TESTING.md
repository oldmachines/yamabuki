# Testing

Every gate, what it proves, what it needs, and where its data comes from.
`zig build test` needs nothing but the tree; everything else fetches or
expects data that is never committed.

## The gates

| Step | What it proves | Needs | In CI |
|---|---|---|---|
| `zig build test` | Unit tests in every module (about 550 `test` blocks across core and frontends), collected from five roots: the core, the frontend helpers, the shader pipeline, the SDL frontend's pure code, and the headless frontend's pure code. | nothing | Debug and ReleaseFast |
| `zig build fuzz` | Deterministic fuzz: random PPU register/memory states rendered as full frames, random bus traffic against a running console (plain and SA-1), and a periodic serialize → restore → step round trip that must stay byte-identical. Runs in Debug so every safety check is armed. | nothing | Debug |
| `zig build test-sst` | The 65816 core against the SingleStepTests vectors: registers, memory, cycle count and per-cycle bus position over all 5.12 M cases. | `test-data/sst-65816` | sampled (`-Dsst-sample=500`) |
| `zig build test-sst-spc700` | The SPC700 core against its SingleStepTests vectors. | `test-data/sst-spc700` | sampled |
| `zig build test-roms` | 102 homebrew ROMs (PeterLemon/krom) rendered headless and hashed against `tests/golden_hashes.zon`: framebuffer, audio stream, `steps` and `cycles`. `-Drom-accurate` replays them on the accurate core. | `test-data/snes-roms` | both cores |
| `zig build test-libretro` | The libretro entry points reproduce the same golden hashes and replay save states deterministically. | `test-data/snes-roms` | yes |
| `zig build test-patchgen` | The FastROM generator end to end: generate, verify in-emulator, re-apply the emitted BPS through the public applier. Also builds the whole-game demo ROM in-process and runs it through the SA-1 whole-game path. | `test-data/snes-roms` | yes |
| `zig build bench-check` | The deterministic perf gate: `steps`, `cycles` and `vram_reads` per baseline ROM must match `bench/baseline.zon` exactly. | `test-data/snes-roms` | ReleaseFast |
| `zig build validate-shaders` | Every baked preset manifest parses through the runtime's own parser and every file it references exists. | a shader bake | yes |
| `zig build test-commercial -Dcommercial-roms=<dir>` | Boots your own commercial dumps, identified by content hash, against pinned boot hashes (`tests/commercial_goldens.zon`). Skips pinned games you do not have. | your ROMs | no, by design |
| `zig build bench -- <rom.sfc>` | Wall-clock FPS, JSON. Informational: machine-dependent. | a ROM | no |
| SA-1 conversion surfaces | Not a build step: `tests/surfaces/sm-sa1/` holds the shipped Super Metroid conversion patches, their exact command lines, and the recorded takes that verify them. See its README. | the Super Metroid ROM | no |

Build options the gates accept (`zig build --help` lists them all):

| Option | Meaning |
|---|---|
| `-Dsst-filter=<substr>`, `-Dsst-sample=<n>` | Run only matching SST files; cap cases per opcode file (0 = all). |
| `-Drom-filter=<substr>`, `-Drom-frames=<n>`, `-Drom-accurate`, `-Drom-mint` | Filter the golden ROMs, override the frame count, use the accurate core, or print ready-to-paste golden entries instead of gating. |
| `-Dcommercial-roms=<dir>`, `-Dcommercial-filter`, `-Dcommercial-frames`, `-Dcommercial-mint`, `-Dcommercial-patches` | The commercial gate's inputs; `-mint` prints manifest entries for every ROM in the directory. |
| `-Dfuzz-iters=<n>`, `-Dfuzz-seed=<n>` | Iterations per stage and the PRNG seed (the fixed default keeps CI reproducible; a failure prints the seed to replay). |
| `-Dperf-counters` | Compile the renderer's VRAM traffic counter in (the bench always does). |

## Where the data comes from

Nothing under `test-data/` is committed. `tools/fetch_test_data.sh` shallow
clones the three upstream repositories; CI resolves each one's `HEAD` with
`git ls-remote` and caches the checkout under that revision.

| Corpus | Source | Licence / status |
|---|---|---|
| 65816 vectors (`test-data/sst-65816`, about 3 GB) | github.com/SingleStepTests/65816 | upstream's; fetched, never vendored |
| SPC700 vectors (`test-data/sst-spc700`) | github.com/SingleStepTests/spc700 | upstream's; fetched, never vendored |
| Homebrew test ROMs (`test-data/snes-roms`) | github.com/PeterLemon/SNES (krom) | upstream's; fetched, never vendored |
| krom reference captures | in the same repository, next to the ROMs | used to diff the Super FX plot demos pixel for pixel |
| Commercial ROMs | yours | never fetched, never vendored, identified by hash only |
| Shader sources (`shader-src/`) | github.com/libretro/slang-shaders (pinned) | GPL, their authors'; fetched by `tools/fetch_shaders.sh` |
| Patches (`patches/*.bps`) | the URLs in `patches/registry.zon` | the registry is an index; payloads are never committed |
| Conversion surfaces (`tests/surfaces/sm-sa1/`) | recorded in this repository | committed: human recordings are irreplaceable (the README there explains why) |

## Minting and updating goldens

- **A new golden ROM:** add it to `tests/golden_hashes.zon` with `hash = 0`,
  run `zig build test-roms -Drom-mint -Drom-filter=<name>`, inspect the
  `.ppm` (and `.wav` for audio ROMs) by eye, then paste the printed entry.
  Keep only the fields you mean to gate: a `0` is "not baselined".
- **A renderer change that legitimately alters output** re-mints every
  affected entry the same way; the commit says why the picture changed.
- **A performance change** re-mints `bench/baseline.zon` with
  `zig build bench-check` on ReleaseFast after confirming the golden hashes
  are unchanged; `steps`/`cycles` drift means emulation changed, not speed.
- **A commercial game:** `zig build test-commercial -Dcommercial-roms=<dir> -Dcommercial-mint`
  prints entries for `tests/commercial_goldens.zon`.

## Unit-test conventions

- Tests live inline in the module they cover, after a
  `// --- tests ---` rule, and use `std.testing.allocator` so leaks fail
  the test.
- Modules that need a console build one in-process from a synthetic image
  (`TestConsole` in `memory/bus.zig` is the pattern: a 512 KiB ROM with a
  hand-written header). Chips are booted the same way; no chip test needs a
  ROM file.
- Filesystem tests use `std.testing.tmpDir` (under `.zig-cache/tmp`).
- A frontend module's tests are collected by the root that imports it: the
  SDL root lists every UI module explicitly in its `test {}` block (an
  import alone does not analyse a file's tests), so a new module has to be
  added there.
- Tests that document a bug say which one, in the test name or a comment,
  so the failure message explains itself.

## CI

`.github/workflows/ci.yml` runs on every pull request and every push to
`main`, all on `ubuntu-latest`: format check; unit tests and fuzz (Debug and
ReleaseFast); sampled SST for both CPUs; the golden ROMs on both cores plus
patchgen, libretro parity and the perf gate; an SDL smoke test under SDL's
dummy drivers (built from source and cached); a cross-compile matrix
(x86_64 and aarch64 glibc, aarch64 and armv7 musl with a static-linkage
assertion, x86_64 Windows); and the shader bake with its promised-preset
assertion. A `windows-latest` job builds and runs the unit tests natively,
because three frontends carry Windows-only code.
