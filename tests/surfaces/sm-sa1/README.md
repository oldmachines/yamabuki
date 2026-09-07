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

### The split ship, second cut (v68) — hangs at a death, see v69

`sm-sa1-v68.bps.cmd` is v67's recipe with two more takes and one more input
file. The takes are `recordings/stock-gameover-quit.ymv` (with its
`.start.srm`: the Tourian save, Samus drained by the Metroids, NO to "TRY
AGAIN?") and `recordings/stock-timeup-softreset-polls.ymv` (the per-poll
twin of the 38-minute power-on take, which adds no coverage on stock but
replays on any build); both are evidence movies and stock cover pairs. The
quit take is the fix for a hang every earlier patch had: the boot's second
entry at `$80:8462`, which the game's own soft reset jumps to, had never
been executed by an evidence take, so the window relocation left its stack
and direct-page setup un-shifted. The input file is
`sm-sa1-v68.scpu.set`, re-recorded on the s19h image over nine takes (the
two Tourian takes among them). The generator now accepts eight movies.

Inside the image, against v67: the SA-1's divides use its hardware divider,
the multiplier trigger stores are `JSL` sites instead of `COP` ones, the two
inline-argument callees (`$88:8435`, `$80:91A9`) are handled, and the plasma
projectile handler is covered — so a late-game save plays. The gate is still
gameplay only (`--wg-split-mode 0998:08`): the wide gate that also offloads
door transitions is measured in `docs/SM_SA1_FINDINGS.md` §10 (s19i) but
cannot pass the per-poll tier, structurally, and does not ship.

Verified behaviorally equivalent over all eight surfaces, v67's verdict
profile. On the Tourian Metroid-room take (`recordings/tourian-metroids.ymv`):
slowdown 626 of 10,000 frames on stock, 310 on v68; lag frames 863 to 610;
S-CPU utilisation 67% to 21%. Door transitions keep stock's timing. The
per-poll quit take `recordings/stock-gameover-quit-polls.ymv` replays on
any build and walks the soft reset into a new game on v68.

### The split ship, third cut (v69) — supersedes v68; see v70

`sm-sa1-v69.bps.cmd` is v68's recipe plus one stock cover pair,
`recordings/v68-take0001-polls.ymv` (the first human session on v68), and a
generator fix that pair exposed. Every patch from v66 to v68 hangs at the
first death (or loud room) a session reaches: the static extension's
dispatcher scan had matched the immediates of `AND #$FC` / `LDA #$7C` before
four `STA $2117` stores as `JSR/JMP ($178D,X)`, and the window shift of that
fake operand turned each store into `STA $2177` — the APU mailbox mirror. The
sound driver took the VRAM address byte as a request and died; the death
jingle's engine upload then waited forever. The fix is four guards in the
static extension and the relocation walk (`docs/SM_SA1_FINDINGS.md` §10,
"v68 take 0001"). v69 is otherwise v68: the same gameplay gate, the same
S-CPU set (`sm-sa1-v69.scpu.set` is byte-identical to v68's), the same
numbers. Verified behaviorally equivalent over all eight surfaces; the
session's take replays through its death to game over.

### The MMIO gate and the `.mmio` file

Since v69's successor every generation also compares, per surface, the set of
(register, instruction) pairs that write hardware on the conversion against
stock's set over all surfaces; a rewritten site that writes a register stock
never wrote from there fails the surface. The gate exists because the
behavioral tier compares game logic and the v66-v68 sound-driver bug was not
game logic. The generator writes the sets beside the patch as
`<patch>.bps.mmio`; a human take on a conversion is checked against it with

    yamabuki-headless <conv.sfc> --movie <take.ymv> --mmio-ref <patch>.bps.mmio --mmio-stock "$STOCK"

which lists every rewritten writer no generation run produced (the hardware
counterpart of `--stale`). Without a generation, `--mmio-out <file>` on a
stock replay of the same take makes a reference.

### The split ship, fourth cut (v70) — the whole game's code, on proven boundaries; see v71

`sm-sa1-v70.bps.cmd` is v69's recipe plus one input, `--code-map "$CODEMAP"`:
the instruction-boundary map of the whole ROM, derived from the
InsaneFirebat/sm_disassembly sources (P.JBoy's bank logs, assemblable) by

    python tools/sm_disasm_oracle.py <sm_disassembly>/src --export "$CODEMAP"

The map is 16 MiB and is not committed; the disassembly is at
https://github.com/InsaneFirebat/sm_disassembly (commit 77633e2 was used).
With it the generator refuses any static decode, dispatcher mark, pointer
seed or rewrite at a byte the disassembly places inside an instruction or in
data, takes each immediate's width from the assembler suffix, and seeds its
static walk with every instruction start the disassembly names — so every
instruction of the game is relocated, played or not, on boundaries a human
wrote down. Without the map the generator's own heuristics apply, as for any
game (`docs/SM_SA1_FINDINGS.md` §10, "the disassembly oracle").

What that changed: the walk now reaches 132,315 instructions instead of
69,299; 38,309 instructions of the S-CPU's copy are rewritten instead of
20,334; 469 math sites are shadowed instead of 329 and 954 thunks dispatch
instead of 435. And the seven instructions of bank `$B3` (Norfair's Gamet
and Geega) that every patch from v66 to v69 corrupted are stock's again,
with the 273 data bytes the static walk had been rewriting around them.

Verified behaviorally equivalent over all eight surfaces with the MMIO gate
silent; `tools/sm_disasm_oracle.py` reports no opcode flag inside an
instruction or on data, and the byte-by-byte explainer finds every changed
instruction a known transform in both copies. The two human takes replay
clean against `sm-sa1-v70.bps.mmio`. The numbers are v69's (the same
gameplay gate): the Tourian Metroid room 310 slowdown frames against stock's
626, utilisation 21% against 67%, door transitions stock-timed.

### The split ship, fifth cut (v71) — a stored pointer moves with the window; see v72

`sm-sa1-v71.bps.cmd` is v70's recipe unchanged; the generator gained one
rule under the code map. The player's first session on v70
(`recordings/v70-take0001-polls.ymv`) shot the destructible blocks of green
Brinstar and every block it revealed drew as a crossed tile: the PLM draw
routine builds its instruction list in low WRAM and hands its address to the
draw code as an immediate, `LDA #CustomDrawInst_NumberOfBlocks` at
`$84:8B3B`, which the evidence-gated pointer-seed rule had never reached (a
profiled dereference proves a seed; this one's dereference runs through a
thunk that resolves the index at run time and never left a proof). With the
pointer un-shifted the draw code read the block word through the abandoned
WRAM home, and on the SA-1 that home is open bus.

The disassembly names such immediates with a WRAM label, and the oracle now
exports that as a code-map flag (0x40, `wram_pointer_sites`): a 16-bit
immediate the disassembly labels with a low-WRAM address and the next
instruction stores. The generator shifts every one of them by the window
offset, no evidence required. Three sites moved that v70 had left:
`$84:8B3B` (the draw list), `$82:9EE5` (`MapTilesExplored`, the pause map's
explored-tile table) and `$88:AE05` (`HUDBG2XPositionScrollingSky`, the
indirect address the Wrecked Ship's scrolling-sky HDMA table points at — a
DMA-side read of an abandoned home, the class no CPU hook sees). The patch
is v70's plus those six bytes and the checksum; the S-CPU set is v70's.

Verified behaviorally equivalent over all eight surfaces; the oracle and the
explainer are as clean as v70's; the patched stock ROM equals the generated
image byte for byte. The v70 take replays clean with the revealed blocks
drawn as stock draws them and zero MMIO offenders against
`sm-sa1-v71.bps.mmio`. `--stale` on that take still names three sites the
recipe leaves un-shifted on purpose of evidence — the enemy-projectile
palette loads at `$86:8030`/`$86:8033` and the enemy-death AI read at
`$A0:A3B9`, all three run with garbage in X by stock's own callers (the
disassembly's note) — see `docs/SM_SA1_FINDINGS.md` §10 (v71) for what
they read and why they are not this cut's.

### The split ship, sixth cut (v72) — the wrapping index thunk

`sm-sa1-v72.bps.cmd` is v71's recipe unchanged; the generator gained one
more thunk shape. v71 left three executed sites reading an abandoned home,
the ones `--stale` kept naming: `Enemy.palette,X` and `Enemy.GFXOffset,X`
at `$86:8030`/`$86:8033` (the enemy-projectile spawn) and `Enemy.AI,X` at
`$A0:A3B9` (`EnemyDeath`'s grapple check). All three read an enemy-table
field with whatever X the caller happened to leave — the disassembly notes
both callers pass values not meant as an index — so one frame the index
points into the table and the next it points past it, into ROM or the low
mirror of the next bank. No single operand serves both: shifted by the
window offset the in-ROM case reads `$6000` off, left as written the
in-table case reads the WRAM home, which on the SA-1 is open bus.

These are the only three sites in the whole game the conversion audit calls
`left_mixed` (measured low WRAM, but not only). The new thunk
(`idxThunkBodyWrap`) dispatches on where BASE+INDEX lands in 16 bits: below
`$2000` is the window, and so is a wrap past `$10000 - base`, where the
shifted operand's own carry lands the read in the next bank's window;
between them the operand runs as written. Patch 158,587 bytes = v71 plus the
three thunks and their `JSR` redirects; the S-CPU set is v71's.

Verified behaviorally equivalent over all eight surfaces; the oracle and the
explainer are clean; the patched stock ROM equals the generated image. The
v70 take's `--stale` list, which named these three on v71, is empty on v72;
the v69 take syncs with a silent MMIO gate. What a player now meets when an
enemy projectile spawns or an enemy dies is the enemy's own palette and
death animation, not open-bus garbage.

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
