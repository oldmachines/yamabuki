# Super Metroid SA-1 — verification surfaces

A conversion produced by `--gen-sa1-patch` is a function of three inputs:
the stock ROM, the generator code, and **the surfaces**. The first two have
always been durable. This directory exists because the third was not: a whole
campaign's surfaces once lived in a session scratchpad, and when the
scratchpad was cleared four irreplaceable recordings went with it, taking six
fixed bugs' worth of coverage along (see `docs/SM_SA1_FINDINGS.md` §4f).

Coverage is the **union** of surfaces. Removing one from this directory does
not fail a build — it silently narrows what the generator can prove, and the
regression shows up later as a freeze in whatever path stopped being covered.
Treat deletion as a code change.

## What is here

| kind | origin | replaceable? |
|---|---|---|
| `*.bps` + `*.bps.cmd` | the generated patch and the exact invocation that made it | yes, by re-running the `.cmd` |
| `scripted/*.ymv` | `tools/sm_surfaces.py` | yes, bit-identically |
| `recordings/*.ymv` | a person playing in the SDL player | **no. Never.** |
| `legacy/*.ymv` | the v8-era working set | **no** — nothing emits them |

`patches/` keeps payloads out and commits only an index, because those are
third-party patches fetchable from their upstreams. These are ours and have
no upstream: the campaign already lost one build to a cleared scratchpad, so
the patch ships beside the recipe that made it. They are ~60 KB.

A `.bps` here is only as good as its `.cmd`. If you regenerate and the two
stop agreeing, the `.cmd` is the truth — it is the reproducible half.

### scripted/

Deterministic input schedules, so they are code and not artefacts.
`tools/sm_surfaces.py <stock.sfc> scripted/` re-emits all three byte-for-byte
and replays each one to embed its end hashes, which is what makes a later
replay print "sync verified" rather than "sync unverified". They are
committed anyway because a surface you have to remember to regenerate is a
surface that goes missing.

- `sm-attract36k.ymv` — 36,000 frames of no input at all: the attract/demo
  arc. The entire §4e set of bugs lives behind this one surface.
- `sm-titleskip.ymv` — Start pressed *during* the title fade, which takes
  SM's intro-SKIP path to the Zebes gunship landing (a different loader from
  both the file-select and the intro path), then a walk.
- `sm-play-death.ymv` — intro, Ceres, five rooms, the Ridley fight taken to
  a death, game over, CONTINUE, respawn.

### recordings/

Player recordings from the SDL player (`--record`). Each one exists because
it walked a path no script had, and each closed a bug that no amount of
generator work would have found. Nothing regenerates these.

To add one: record it, drop the `.ymv` here, and add a row to the table in
that directory's README saying what it covers and which failure it caught.
Pass it to a generation as a **cover pair**, against the image it was
recorded on:

    --cover-image <that-conversion>.sfc --cover-movie recordings/<name>.ymv

One caveat, learned expensively (§4f): a recording of a run that **crashed**
poisons coverage, because the harvest credits the crash's garbage execution
to the wrong file bytes on a >2 MiB shim-mapped image. A recording of a run
that merely *hung* is safe. Until the harvest bank translation is fixed, do
not pass a crashed recording as a cover surface.

## Regenerating a conversion

Every `.cmd` here is a complete invocation, written verbatim by the generator
beside its own patch. They come in two shapes, and the difference matters
because it decides what directory you run them from.

**Repo-relative** (`sm-sa1-v25.bps.cmd`) names its surfaces as paths under
this repo, and its stock ROM as `"$STOCK"`, so point that at your own dump and
run it from the repo root:

    export STOCK="/path/to/Super Metroid (JU) [!].smc"
    zig build -Doptimize=ReleaseFast
    eval zig-out/bin/yamabuki-headless $(cat tests/surfaces/sm-sa1/sm-sa1-v25.bps.cmd)

The `eval` is load-bearing: command substitution does not re-expand variables
in what it substitutes, so without it `$STOCK` reaches the binary as six
literal characters and the ROM will not open. The quotes inside the `.cmd`
survive `eval`, so a path with spaces is fine.

Note that the generator writes this file verbatim from its own argv, so a
regeneration will put an absolute path back. Re-apply `$STOCK` when that
happens.

**Flat working directory** (`sm-conv-*.bps.cmd`) names every input as a bare
filename, so stage one first:

    mkdir -p /tmp/smgen && cd /tmp/smgen
    cp "$STOCK" sm.sfc
    cp <repo>/tests/surfaces/sm-sa1/legacy/*.ymv .
    cp <repo>/tests/surfaces/sm-sa1/recordings/*.ymv .
    cp <the cover images> .          # see recordings/README.md
    <repo>/zig-out/bin/yamabuki-headless $(cat <repo>/tests/surfaces/sm-sa1/sm-conv-final.bps.cmd)

Applying any patch, from anywhere:

    zig-out/bin/yamabuki-headless "$STOCK"       --patch tests/surfaces/sm-sa1/sm-sa1-v25.bps --save-patched v25.sfc

### The recipes here

| `.cmd` | produces | needs |
|---|---|---|
| `sm-sa1-v25.bps.cmd` | `sm-sa1-v25.bps`, committed beside it | `scripted/` only |
| `sm-conv-final.bps.cmd` | `sm-conv-final.sfc`, a cover image | `legacy/`, `cover39`, `cover40`, `sm-conv-hdmafix2.sfc` |
| `sm-conv-hdmafix2.bps.cmd` | `sm-conv-hdmafix2.sfc`, likewise | `legacy/`, `cover39`, `cover40` |

Those two recipes read their surfaces from `legacy/` — five files no tool
regenerates, kept solely so the chain can run.

The chain bottoms out at `cover39.sfc`/`cover40.sfc`, which have no recipe —
see `recordings/README.md`. Everything else rebuilds from this directory.

### The split ship (v67)

`sm-sa1-v67.bps.cmd` is v66's recipe plus the mainloop split (`--wg-split`,
the 23 `--wg-split-io` routines, the `--wg-split-vbl` reader ranges, the
`--wg-split-mode 0998:08` gameplay gate, `--wg-expand 8m` for the dual
image) and one more input: `sm-sa1-v67.scpu.set`, the S-CPU's instruction
addresses seen while the SA-1 owned the loop. That set is recorded, not
written by hand: run the previous split image over every surface with
`--split-scpu-set <file>` (the file accumulates across runs) and hand the
result to `--wg-split-shared`. A math site outside the set is the SA-1's
alone and becomes a direct I-RAM cell access; one inside keeps its COP.
The patch applies to the stock ROM and produces an 8 MiB image: the lower
4 MiB is v66's conversion with the split's anchor, the upper the same with
the SA-1's shadows (`docs/SM_SA1_FINDINGS.md` §10).

### What v25 does not include

`sm-sa1-v25.bps.cmd` passes the three scripted surfaces and nothing else: no
`--evidence-movie`, and no `--cover-image`/`--cover-movie` pair. The four
recordings in `recordings/` were not harvested into it. That is the coverage
narrowing this directory exists to make visible, not a defect in the patch —
but a regeneration that adds the cover pairs sees more, and the two images
differ.

### A timing note, from a separate generation

A cover-harvesting generation made 2026-08-31 (all five surface kinds, zero
hand bytes, behaviorally equivalent) reported:

    dropped frames 2342 -> 28969, mean utilisation 41% -> 9%

Window mode is the *enabler* for resident offloads, not itself a speedup: the
SA-1 never leaves reset, greedy found no offload trees, so the run pays 449
thunk dispatches and collects nothing back. The v8-era figure of `25 -> 25`
is not a counterexample — it was measured over `legacy/sm-start.ymv`, which
is 3,600 frames, too short to reach the demo gameplay where the lag lives.
Whether the overhead is a regression or a property window mode always had is
still open; the test is to replay a v8 image over `scripted/sm-attract36k.ymv`
and compare like with like.
