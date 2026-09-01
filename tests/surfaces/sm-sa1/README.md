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

Every `.cmd` here is a complete invocation. The current code-only build:

    zig build
    tools/sm_surfaces.py "$STOCK" tests/surfaces/sm-sa1/scripted
    $(cat tests/surfaces/sm-sa1/sm-sa1-v25.bps.cmd)

then apply it:

    zig-out/bin/yamabuki-headless "$STOCK" \
      --patch <out>.bps --save-patched <out>.sfc
