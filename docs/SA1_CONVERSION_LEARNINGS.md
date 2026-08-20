# SA-1 Conversion: What the Machine Learned

Everything below was earned on one real cartridge — Gradius III (USA) — by the
loop *generate → verify → fail → dump-diff → disassemble the failing site →
fix the rule → regenerate*. Each rule cites the failure that forced it. The
reference throughout is Vitor Vilela's hand-crafted SA-1 patch (v17), used as
an answer key by byte-diffing, never as a source.

The work lives on PR #115 (`claude/sa1-async-offload`). The entry point, in
the shape that actually ships a four-tree patch:

```
yamabuki-headless <rom> --gen-sa1-patch --window --wg-static --wg-fastrom \
    --verify-behavioral --state <gameplay.state> \
    --movie <surface1.ymv> ... --movie <surface5.ymv> \
    --cover-image <prev-build.sfc> --cover-movie <recorded-on-it.ymv> ...×11 \
    --wg-add 009bcd --wg-expand 1m --wg-copy-reserve 3600 \
    --conv-pad 1500 --wg-nmi-off 8ef1 --wg-drop 8c95 --out <patch.bps>
```

**Do not reconstruct this command from prose.** Three separate
reconstructions went wrong in one day — missing `--wg-fastrom`, then
`--verify-behavioral`, then something never identified — and each cost
hours of misattributed blame, because a build that silently drops a flag
still produces a plausible patch. Every generated patch now carries its
own invocation in `<patch>.bps.cmd`, and every run echoes it as line one.
Read that file; do not remember the command.

---

## 1. The architecture, and why it is the only one

Four architectures were built and measured. Three died for reasons worth
recording:

| Architecture | Result | Killed by |
|---|---|---|
| **S3 marshalled offloads** — copy a routine's working set to a BW-RAM shadow per call, run the copy on the SA-1, copy back | Verified, shipped, **zero speedup** | Marshal economics: 5,376 bytes × 2 per call vs ~49K cycles of compute. The S-CPU also spins during the call, so nothing overlaps. |
| **Per-region relocation (S2)** — move hot WRAM regions to I-RAM/BW-RAM at arbitrary offsets, rewrite the naming sites | First live attempt diverged at frame 11 | `INC $10B9,X`: an indexed base *below* a moved region reaches into it. With a 16-bit index every region is reachable from almost every base — per-region moves to arbitrary offsets are statically unsound on index-heavy games. |
| **Whole-game migration** — run the game ON the SA-1, proxy MMIO through a mailbox | Boots, then drowns | ~500 proxied MMIO transactions per frame; the APU IPL handshake never completes. Synchronous MMIO proxying breaks the machine's timing contract. |
| **Uniform window relocation + verbatim offloads** — game stays on the S-CPU; WRAM moves wholesale at identity offsets; routine trees run unmodified on the SA-1 | **Works.** FRAMES IDENTICAL through real input; 58%→17% utilisation at the bubble stage when offloads verify | — |

The survivor is exactly v17's architecture, reached independently by
elimination. Its two load-bearing properties:

1. **Identity offsets.** WRAM `$0000-$1FFF` maps to the `$6000-$7FFF` BW-RAM
   window (`+$6000`); `$7E/$7F` re-bank to `$40/$41` at the same 16-bit
   offsets. Every relative distance survives, so *indexed bases rewrite
   soundly* — the thing that killed per-region moves.
2. **Both CPUs see the same bytes at the same addresses.** SBM block 0
   (S-CPU, `$2224`) and CBM block 0 (SA-1, `$2225`) show identical windows, so
   a window-rewritten routine runs **verbatim** on the SA-1: no shadow, no
   marshalling, no slot translation, no D-swap. A stub passes registers, D,
   and DBR through the I-RAM mailbox and nothing else. Every offload is
   resident by construction — which is also what makes the async
   (fire-and-forget) contract free: there is no second copy to write back.

The whole scaffold for relocation-only is a 33-byte boot shim (SEI, SBM/SWEN/
BWPA, reproduce power-on D=`$6000` and S=`$61FF` inside the window, JMP
reset). The SA-1 never leaves reset unless offloads exist.

## 2. The rewrite rule catalog

Every rule exists because a specific byte sequence in a real game broke a
naive rewrite. The general lesson: **the same operand bytes mean different
things depending on runtime values**, and each rule is one resolution of that
ambiguity.

| # | Rule | The failure that earned it |
|---|---|---|
| 1 | `LDA #$7E/#$7F` + store (8-bit) re-banks to `$40/$41` — a pointer's bank byte materialized as an immediate | Decompressor pointers (`LDA #$7E : STA $05`) pointed the SA-1 at nonexistent bank `$7E` |
| 2 | The 16-bit form `LDA #$007E : STA $43x4` (DMA source bank) and `: STA $7E:xxxx,X` (queue bank word) re-bank too | Boot logo DMA'd from empty WRAM; the title's DMA queue carried `$7E` bank words |
| 3 | Long `$7E/$7F:xxxx` re-bank to `$40/$41`; low-mirror longs (`$00-$3F:<$2000`) shift `+$6000` — **unindexed only** | `LDA $01:0000,X` with X≥`$8000` walks a **ROM table**; shifting its base fed garbage IPL parameters to the APU |
| 4 | Bank `$7D` with offset ≥`$FF00` re-banks to `$3F` — the negative-offset wrap idiom | `SBC $7D:FFFB,X` reaches the *previous* queue entry by wrapping through the bank boundary into `$7E:0000+` |
| 5 | WRAM←WRAM block moves keep banks `$00,$00` and shift the X immediate instead (window mode) | Re-banking to `$40,$40` leaves DBR=`$40` where stock's `MVN $00,$00` leaves the *system* bank; a stack-saved copy of that DBR poisoned the title transition |
| 6 | DBR-pin tracking survives conditional branches, BRA/BRL, and calls to DBR-transparent callees | The bubble-table init (`STA $0000,Y` under a pin set before a `BCC`, two `JSL`s, and a `BRA`) was mis-shifted and wrote BW-RAM `$9C00` instead of `$3C00` |
| 7 | Tiny-base indexed absolutes (base <`$100`) stay unshifted absent evidence — the "X is the pointer" idiom | The title's display-list walker `LDY $0000,X` (DBR=`$01`, X≥`$8000`) walks ROM; the shifted base hung the mainline |
| 8 | Indirect-jump *pointer cells* (`JMP ($xxxx)` operands <`$2000`) shift; pointer *values* are data and cannot be carried | — (values remain dynamic evidence) |
| 9 | **Measured evidence overrides 3 and 7**: a site whose observed traffic is all low-WRAM shifts whatever its shape; any ROM/MMIO/`$7E`-mediated traffic keeps it in place | The menu's list walkers needed shifting while the sound-table walkers needed leaving — same instruction shape, opposite answers |
| 10 | **Anti-rule**, tried and reverted: shifting direct `JSR/JMP` targets <`$2000` for "WRAM-executed code" | Nothing executes at `$10EC` in stock either — the crash arrived there via corrupted control flow. Verify the premise before rewriting for it |

## 3. Structure vs. value knowledge — the profiler

The decisive insight of the arc: **disassembly gets structure; the battles
were all about values.** Whether `$0000,X` walks ROM or WRAM is a fact about
X, not about the bytes. Static value-set analysis approximates it badly;
the emulator knows it exactly.

`usage_map.sites` (16 MiB, optional) records per *instruction address* where
its data accesses actually landed, classified into four bits:

- `site_wram_low` — system-bank access below `$2000` (the mirror)
- `site_rom` — ROM through any bank
- `site_wram_bank` — through `$7E/$7F` (DBR- or long-mediated; such sites
  follow the re-banked idiom and must not shift)
- `site_other` — MMIO, cart space, open bus

Recording costs one classify per data access in profiling builds. The window
rewriter consults it first and falls back to the static heuristics only for
sites with no traffic. Evidence accumulates across *all* profile passes —
which is what makes coverage additive (below).

## 4. Coverage: evidence and truth

Two mechanisms feed coverage, and they answer different questions:

- **State anchoring** (`--state`): a gameplay save state — even one recorded
  on a *different conversion* of the same game, since nothing binds a state
  to an image and the S3/window stages leave WRAM layout in place — drives an
  **evidence pass** on the stock console: profile, coverage, candidates from
  the scene with real slowdown. A window image itself can never be seeded
  mid-game (the shim's D/S/window moves never ran; the stack carries pre-move
  D saves as data), so **verification always runs from power-on**: evidence
  and truth split.
- **Movies** (`--movie`): a `.ymv` is 32 bytes of header plus one `u16` pair
  per frame — trivially synthesizable. A programmatic START press gave the
  generator the menu, the one screen no power-on profile reaches, as both
  coverage *and* verification input. Real recorded playthroughs (F10 in the
  SDL player) are the scaling path.

Standing law, demonstrated three times: **the verified surface is exactly the
covered surface.** Two minutes of human play found two defects that 4,000
frames of automated verification could not, because nothing had ever pressed
START. And widening coverage *retroactively strengthens* old verdicts: the
bubble build's offloads were correct on their verified surface and hostile on
the menu path that surface never included.

A corollary that cost a shipped patch: **input coverage is not monotonic.**
The menu movie that ADDED the START path silently REMOVED the no-input path —
its f500 press skips the logo's auto-advance, so the `$9980` sound-status
routine (polled only in the exit phase, behind a mode dispatch the static
walk cannot pierce) fell out of coverage entirely, went un-rewritten, read
dead real-WRAM, and every menu-era build froze on the Konami logo for any
player who didn't press START. FRAMES IDENTICAL was truthfully reported —
over the movie's frames, where the press masks the breakage. A movie is not
"the old coverage plus a button": every path that only runs *un-pressed*
needs frames where nothing is pressed. The standing GIII movie now waits
through the auto-advance (~f750) and presses START at f1200.

## 5. The verification stack

Layered gates, strictest verdict that applies:

1. **Pixel gate** — strict / envelope / equivalent tiers. A window
   relocation can pass FRAMES IDENTICAL outright (it did: 900 frames of real
   input including the menu).
2. **Behavioral tier** — tick-locked replays compared at each frame's first
   controller poll, on the bytes the baseline actually consumed
   (read-before-write liveness), read from wherever the conversion homes
   them. For window images: BW-RAM identity offsets with an either-home
   compare (WMDATA-port traffic still lands in real WRAM). The equivalences
   this tier had to learn, each proved necessary by a false verdict:
   - **The relocation's bank-value map is a data equivalence**: baseline
     `$7E` vs conversion `$40` (and `$7F`/`$41`) in a pointer's bank byte is
     the same logical value — and it diverges *permanently*, which the
     persistence verdict otherwise reads as immortal corruption.
   - **Spread keys on sustained novelty, not cumulative count**: wandering
     corruption keeps finding fresh addresses across the run
     (`novelty_ticks` large); an offload's latency phase-shifting the poll
     instant through a busy transition sprays dozens of scratch cells for a
     handful of ticks and stops. Fail requires breadth (>64 addrs) *and*
     novelty across >30 ticks; a 512-entry dedup buffer keeps novelty
     detection alive through bursts.
   - **Input edges break global tick pairing — realign per epoch.** A movie
     delivers a button edge at a WALL frame, and a run with less lag has
     executed more logic passes by then: each run consumes the edge at a
     different tick index (Gradius III's menu: 79 ticks apart), and a global
     pairing goes on to compare two different moments of the same correct
     game. The tier re-anchors at each edge — the laggard's surplus ticks
     have no counterpart and go uncompared — and pairs tick-locked within
     each epoch.
   - **A held constant offset is a wall-time origin, not corruption.** No
     speedup can be tick-identical past its first input edge: any counter of
     logic passes (GIII's `$3A`) lands offset by exactly the passes the
     speedup bought, then evolves in lockstep with the baseline forever —
     v17 itself shows the same residue class, larger (offset `$71` vs our
     `$4F`, plus a zeroed sound-scratch block). Corruption cannot hold a
     constant offset against a moving baseline: a stuck cell's offset moves
     every time the baseline does, and every change counts as active
     divergence. The persistence feed carries values, not just addresses,
     and excuses exactly the held-offset shape.
   - **Divergence must be measured at the cell's LIVE home.** A window image
     splits homes by access idiom (low 8K and `$7E`-long cells live in
     BW-RAM; abs-addressed high WRAM stays put). The live home is learned
     once per cell from a *discriminating* equality — the homes disagree and
     the baseline matches exactly one — and then sticks: a delta computed
     against the dead home's stale zeros drifts as the baseline moves,
     faking active divergence out of a held offset; and a baseline value
     transiting 00 coincidentally matches the dead zero and would re-teach
     the home wrongly (measured, both).
3. **Persistence classifier** (`util.Persistence`) — pass{clean, echoes} /
   fail{persistence, spread, flood}. Echoes are real and benign: wall-derived
   values diverge transiently and self-heal.
4. **The auto-bisect ladder** — on failure, demote an async culprit to sync
   (the mode ladder), else drop a culprit and retry; a window attempt that
   fails with no offloads left ships the verified relocation-only patch.
   Every rung's image is preserved (`--save-attempt` writes numbered copies)
   because the failing rung is the interesting one.
5. **A human** — pixels, audio, and feel are unverified *by design* in a
   slowdown-removing conversion. The play session is part of the stack, not
   an afterthought.

## 6. Guards — containing what analysis cannot reach

- **Window-stub D guard** (24 bytes): a caller whose D is not window-shaped
  (`$6000-$7FFF`) comes from an uncovered path; handing it to the SA-1
  resolves dp into the chip's own I-RAM, smashes the mailbox, and rampages
  over shared BW-RAM (measured: a play session's save state showed BW-RAM
  88% zeroed at runtime). Such callers run the original body on the S-CPU —
  no worse than the uncovered path already is, and the chip stays sane.
- **I-RAM-hazard tree refusal**: an *unshifted* low-mirror site (mixed or
  absent evidence) is correct on the S-CPU but addresses the SA-1's own
  I-RAM in the copy. `windowEligible` refuses trees containing one unless
  the site's measured traffic was pure ROM — or the site is reached under
  a proven BW-RAM DBR pin (below), where the operand is data both CPUs
  read identically.
- **DBR pins travel through in-tree JSLs.** A copy's members are called
  only from other copies in the same tree (the member-to-member JSLs are
  re-pointed), so a pin proven at every in-tree call site genuinely holds
  for the copy at runtime. The eligibility walk runs in two phases:
  SURVEY passes collect members, spans, and per-member DBR-cleanliness
  (no PLB or block move in the span, transitively through in-tree
  callees; optimistic, iterated downward), then one JUDGE pass computes
  entry pins as the meet over call sites — and inside a DBR-clean member
  entered under a pin, the pin holds at *every* instruction, so the
  per-op survival approximation (which a mid-span RTL would needlessly
  kill) is not consulted. This is what earned Gradius III's physics tree:
  its one refusal was an uncovered `ASL $0000,X` on a rare branch of a
  shared helper — unshiftable, no evidence, the SA-1's own I-RAM if run
  unpinned — but every in-tree path to it runs under the root's `$40`
  pin, where a tiny-base indexed absolute is BW-RAM data on both buses
  whatever the index holds.
- **Async monopoly**: one fire-and-forget offload per conversion, first
  chosen; a sibling's un-fenced send mid-flight deadlocks the dispatcher.
- **One context only**: the mailbox is single-channel, so a stub call from
  interrupt context landing inside a mainline handshake would stomp `smeg`
  before the SA-1 consumes it and park both CPUs. The profiler now counts
  each routine's entries made under an interrupt frame, and window
  candidates partition by majority context — the class with less measured
  slow work is refused by name. Honest footnote: this guard was built for
  a Gradius III wedge that turned out to be something else (all three
  trees measured mainline; the wedge was a diverging copy spinning
  forever, below) — it stands as a cheap defensive contract for games
  whose sound engines really do run under NMI.
- **A diverging copy is a hung machine, not just a wrong answer.** The
  wedge signature — S-CPU parked in the stub bank, SA-1 mid-copy, `smeg`
  pending unconsumed — means the copy entered a loop its S-CPU original
  never does (Gradius III: the slot walker's cursor marching past `$A000`
  with a limit compare that can never catch it). The behavioral tier sees
  it as spreading divergence; the player sees a freeze. Bounds on scan
  loops in copies are not verifiable statically — coverage and the tier
  are the net.
- **The async contract**: no write-back at all — register results and dp
  writes dropped; only shared-BW-RAM effects survive. (Earned when a fence's
  dp-page copy-back reverted the APU upload counter mid-handshake.)

## 7. Debugging method — the loop that killed every blocker

1. Reproduce headlessly. Synthesize inputs if needed (`.ymv` is 32 bytes of
   header away).
2. `--dump-ram` both runs at increasing frame counts: WRAM + BW-RAM + VRAM +
   I-RAM + both CPUs' resting state. Find the **first** diverging frame; the
   first diverging *byte* usually names the subsystem.
3. Disassemble the implicated site — the site, not the game.
4. If ambiguous, check v17's bytes at the same offset. The answer key exists.
5. Fix the *rule*, never the site. Regenerate. The next blocker is usually a
   different rule.

Corollaries: frame-end dumps distinguish corruption (state stays wrong) from
phase (state re-converges); a save state taken at a glitch is a machine
snapshot of the crime scene; `--save-attempt` + per-rung numbering turns the
bisect ladder into a specimen collection.

Two humbling entries for balance: the "save states don't carry cart RAM"
theory was disproven by its own regression test (the console serializes its
cart by value — the wiped BW-RAM was the rampage's handiwork), and the
"WRAM-executed code" theory shipped a rewrite that broke boot before the
premise was checked. Verify the premise; keep the regression test either way.

## 8. Where it stands

**Current, 2026-08-20 — union68.** The shipping patch is the four-tree
window conversion: `$9BCD` (the stage-1 sequencer), `$8EF1` (the
1,324-byte physics tree), and `$9028`/`$9020` (the pair the two-scene
intersection promoted, section 19), all executing on the SA-1, plus
FastROM, a 1 MiB expansion (section 21), and 131 split-site thunks — 39
of them through the cold dispatcher (section 22). Five verification
surfaces, eleven cover harvests, state-anchored at a stage-2 scene.

    stage-2 scene (anchored)   stock mean 57%           ->  17%
    boss surface (11,243f)     stock mean 44% / p95 87% ->  17% / 41%
    dropped frames             237 -> 115
    (Vilela's hand-written v17, for scale: 12% mean)

The **p95** column is the one that answers "does it still feel slow" —
the heaviest five percent of frames no longer saturate the CPU. Gates:
all five surfaces behaviourally equivalent; the stale and DMA detectors
report **zero stale reads and zero abandoned accesses** over the boss and
full-game surfaces — union64's one residual defect (`$82:F97A`) is fixed
by the very recording that observed it (section 22). Live play: stage 1
and stage 2 both faster than stock, boss scroll-lock eyeballed clean.

Open: nothing on this line. The next distance to v17 is more coverage —
and the ceiling that used to price coverage in refusals is gone.

Everything below is how it got here, in the order the failures forced it,
and several of the walls named as permanent turned out not to be.

Two walls that fell along the way, for the record: the "menu-beep
semantic divergence" was three verifier artifacts (section 5's last
three equivalences) — no speedup, v17 included, can hold tick-identical
wall-time counters; and `$8EF1`'s I-RAM refusal was ONE uncovered
instruction, admitted by DBR-pin propagation with no byte rewritten.

**The wall the arc ends against — context-split sites.** The first
input surface that actually STARTS A GAME (menu → 1 player → weapon
select → stage 1 → death → continue, all scripted and validated) proved
that ~100 sites in the shared mode-handler region (`$A2E0-$A4xx`,
unindexed absolutes on `$02xx/$12xx/$1Cxx` cells) are executed by TWO
caller classes: system-DBR callers (title/attract paths) that need the
`+$6000` shift, and `$7E`-pinned callers (gameplay, pin re-banked to
`$40`) that need the operand untouched. The evidence honestly measures
them mixed; either single decision breaks one class — SHIFTED broke
stage-1 loading (black screen with music at 1-player start, found by
play), UNSHIFTED broke the title path at f833 (found by the tier). One
operand byte cannot serve both worlds. Diffing the two relocations
byte-for-byte is what named the cluster: 286 bytes, 222 runs, every one
a `$1x`↔`$7x` operand high byte.

The DBR-dispatch thunk mechanism is BUILT and unit-tested (a 3-byte
`JSR` over the site; the 24-byte thunk restores the caller's exact
flags immediately before the original op, so loads, stores, RMW, and
carry-consuming arithmetic all behave byte-for-byte in situ; sites in
offload trees auto-refuse because JSR is a flow refusal) — and then the
targeted probe showed Gradius III's flipped sites are NOT context-split
at all: every probed site is pure low-WRAM *where covered*. The real
disease is one level up:

**Each movie is a different world, and evidence does not accumulate
across worlds.** The full-game movie that added stage-1 coverage
DISPLACED the attract-demo phases, so demo-only sites fell out of the
rewrite. The additive tooling now exists: `--gen-sa1-patch` accepts
several `--movie` flags — each a verification surface, all feeding one
evidence/coverage union, every one required to pass. The proof campaign
for it then found and fixed three more systemic defects: the anchored
evidence pass was pressing the movie's buttons into the mid-game state
(START = pause — evidence silently varied by surface set; it now runs
input-free), the spread verdict's novelty budgets were per-run (now
scaled by input epochs, dedup buffer 4,096), and per-site evidence
decisions could split one cell's accessor population (now CELL
COHERENCE: per unindexed operand below $2000, the union of its sites'
evidence plus any pinned accessor decides ONE home — a pinned accessor
is stuck at BW-RAM, so a {low, bank} cell's unpinned sites shift to
follow; a single site measured under both contexts still takes the
thunk).

**And beneath all of it, the true floor, found by tick-level
replication: the window relocation itself does not yet survive real
gameplay.** Every window build — union-evidence and attract-evidence
alike — persistently diverges once actual play begins: the relocated
image's APU stream cursor runs one byte behind stock (the
long-disclosed "audio phase-shifted by a sample", now precisely
located: `$1F28`-class cells, cursor value one less, in-flight byte
from one position earlier), and the cursor-adjacent cells hold STREAM
DATA whose divergence delta changes every tick — permanently active,
invisible to the held-offset excusal, historically absorbed only by
each surface's lag-learned wall mask happening to cover them. The
candidate resolutions, in order of principle: declare the APU stream
mailbox wall-derived BY CONSTRUCTION (a class equivalence, not
lag-learning luck); union the wall masks across surfaces; or fix the
one-byte pump lag at its source in the relocation. Until one lands,
no window build is gameplay-verified, and the attract-cycle relocation
remains the widest honest patch.

A phase-dependence note from the same run: the sound pump measures
MAINLINE context in attract and INTERRUPT context in gameplay — the
single-context rule fired for the first time (and kept the interrupt
class, which under gameplay carries the larger slow work). Context is a
property of a surface, not of a routine.

**The stream mask landed (multi-write-per-tick cells wall-derived by
construction) and halved the damage — and the remainder was not stream
noise at all.** A `--behavioral-probe` CLI (behavioral tier alone
against a preserved failing rung — minutes, not 75-minute ladders) plus
`worst_start` in the persistence verdict (first_bad names the run's
first ACTIVE tick, which misled a whole night; the killer stretch
starts elsewhere) located the real failure: rendering the two sides at
the worst run showed the converted game playing stage 1 WITH NO
SPRITES. RAM dumps told the story exactly: object tables live and
correct in BW-RAM (down to the bank-value map in the entries), but the
VRAM upload buffers — `$7E:A000+`, `$7E:E000+`, most of `$7F` — TORN:
written to real WRAM, read as BW-RAM zeros. The writer is a `STA [$20]`
loader loop whose pointer bank bytes come from a bank-$01 ROM TABLE.

**Bank bytes travelling as DATA are the one $7E-naming idiom no operand
rewrite can reach — and provenance is measurable.** The profiler now
remembers, for every low-8K write, which ROM byte sourced the stored
value (the preceding plain A-load's read bytes or immediate operand,
widths agreeing); a `[dp]`/`[dp],Y` access resolving into $7E/$7F
proves its pointer's bank-byte cell's remembered source, and $7E/$7F
stored to a DMA A-bus bank register proves its source directly. The
conversion re-banks the proven ROM bytes like any long operand, so
value-mediated traffic lands in BW-RAM with the rest of the world and
the whole-bank invariant survives. On GIII the entire value-mediated
surface over the full game is ONE loader loop plus a small decompressor
cluster (whose pointer banks come from immediates the shape pass
already re-banked — which is why `$3000-$3800` was coherent all along
and the tear stayed invisible until a per-home comparison of the
`$A000` buffers). Unattributable accesses are counted and disclosed;
the behavioral tier arbitrates them.

**Differential-aware pairing and the fork-episode excusal — how the
first tree patch shipped.** Tick-locked comparison has a domain: it is
defined only while the two sides' LAG DIFFERENTIAL holds still, and
only until the first RNG-sensitive event after their wall-origin
counters diverge. The verifier now measures both boundaries instead of
tripping over them. Skew ticks (differential moving) record deltas but
feed no budgets and never reset a run; the spread verdict judges only
cells active at a stable differential. Long runs past the persistence
budget are counted as FORK EPISODES: with at most four of them, under a
quarter of the surface excused, off-episode divergence within twice the
flood budget, and a substantial prefix before the first, the tier
re-verifies the prefix and reports equivalence MODULO the episodes —
healed ones were reconverged by scene resets (which corruption does not
survive); a terminal open one is a gameplay fork, unverifiable by
replay and handed to the eyeball. Measured on Gradius III: the $9BCD
sequencer offload verifies 1,928 gameplay ticks to its fork and 3,417
attract ticks around three healed demo episodes, and the shipped patch
cuts dropped frames 237 → 143.

After the split-site mechanism: the bubble-stage measurement over a
recorded playthrough (F10) reaching stage 2.

**Known hard limits** (dynamic evidence forever): pointer *values* in
data beyond the tracked one-step load→store attribution (a bank byte
that transits arithmetic, XBA, or a WRAM staging cell is unresolved);
WMDATA-port traffic (real WRAM always — GIII has exactly one port
site); per-site evidence that is genuinely mixed (same instruction,
both worlds); emulation-mode S pinning to page 1; and the coverage
boundary itself.

## 9. The comparison that frames everything

v17 changes 8,612 bytes in 1,314 regions, woven through three banks, with a
bespoke SA-1 program (custom MMC banking, SA-1-side DMA, interrupt-driven
coordination) — expert-months on one game, correct everywhere, 12%.

This pipeline changes ~4,000 bytes in 250 regions from one command, verified
mechanically for exactly the surface it covers, 17% where its offloads hold.
Every difference between the two traces to the same asymmetry: **Vilela
substitutes game knowledge where the machine substitutes conservative rules,
measured evidence, and verification.** The profiler closed most of that gap
by harvesting the knowledge from execution instead of approximating it from
bytes; coverage closes most of the rest; the residue is what the behavioral
tier is for.

## 10. The concurrency arc — earning the third tree

The physics tree ($8EF1) was the difference between 48% and 17%
utilisation, and it kept freezing live play long after every surface
verified clean. Recovering it took four mechanisms and disproved two.

**The SA-1 timer watchdog — recovery, not prevention.** Every dispatch
block restarts the SA-1's linear timer and opens IRQs only across the
copy; a copy that outlives a generous V-budget takes the timer IRQ into
an abort handler that unwinds to the dispatcher, flags the S-CPU stub,
and lets it re-run the ORIGINAL body inline from the caller's entry
registers (the abort path skips the exit marshal precisely so the
mailbox still holds them). What the build taught:

- CIV is an S-CPU-side register. The SA-1's own stores to $2207/8 land
  on deaf ports; the boot shim must program it, like CRV.
- In a level-model IRQ line, the CLEAR bit is the mask. Writing CIE
  with CIC unset asserts the line instantly — and the unmarshal's PLP
  of a mainline caller's P (I=0) takes it into a zero vector.
- The unmarshal opens interrupts BEFORE any deliberate CLI, because
  game P arrives through it. Interrupt-class trees arrive with I set,
  so the block must CLI for the watchdog to cover them at all — and
  must repair the I bit in the marshaled exit P afterwards, because P
  round-trips to the S-CPU caller.
- Budgets must be sized to the largest LEGITIMATE run, not the typical
  one: the sequencer tree averages ~4.4ms/entry, and a 4.6ms budget
  aborted healthy runs wholesale. An abort is only safe when the
  alternative was a permanent wedge — every abort re-applies partial
  BW-RAM writes, so frequent aborts ARE the corruption.
- The watchdog is blind to the failure it was built for whenever the
  S-CPU, not the SA-1, is the one looping: an inline walk over torn
  state shows a clean mailbox, an idle SA-1, and a silent watchdog.

**Interrupt-masked dispatch — the fix that held.** Concurrent mutation
of a tree's read-set cannot be dodged by timing (the vblank guard) or
recovered from after the fact (the watchdog re-runs inline over the
same torn state). It has to be excluded: the tree's sync stub masks
NMITIMEN across the whole handshake — the S-CPU is spinning anyway, a
straddled NMI is one lag frame — and restores it before any exit path.
The restore source is the trap: the game's own shadow byte is not
phase-accurate (GIII's transitions write $4200=0 without touching it,
and restoring the stale value re-enables NMI inside the game's own
interrupts-off bracket). A write-only register is mirrored correctly
by REWRITING ITS WRITERS: every covered `STA $4200` becomes a JSR to
an eight-byte thunk that stores A to an I-RAM mirror first, then to
the register. Wrap only the trees that need it — the mask costs the
straddle probability times the dispatch time, which is negligible for
a 0.5ms tree called eight times a second and ruinous for a 4.4ms tree
called every frame.

**The coverage boundary moves with the lag differential.** The
conversion runs ahead of stock by the removed slowdown, so a path
stock first executes shortly AFTER a movie's end is reachable by the
conversion WITHIN it — and an uncovered instruction there is invisible
to every rewrite rule. Profiling each surface a thousand-plus frames
past its movie (coverage only, no verdict influence) closes that
margin. It cannot close the deeper one: after an RNG fork the two
sides visit scenes in different orders, and no finite stock profile
leads a forked trajectory. Idioms that gate control flow must not
depend on coverage at all — the dispatch macro `STA $00 / JMP ($0000)`
appears ~140 times in three banks, coverage had shifted 28, and any
uncovered one is a boot-to-BRK-storm landmine. A five-byte signature
is specific enough to rewrite statically; covered sites skip naturally
because their operand no longer matches.

**Open bus reads the instruction's own bytes.** The FastROM bank lift
changed `LDA $02:FFFF,X` to bank $82 — and the slot walker executes
that read with table-range X on purpose, landing in $4400-$5FFF where
the value returned is the MDR: the last-fetched operand byte, i.e. THE
BANK BYTE. Stock seeds its link scratch with $0202 (WRAM-domain when
consumed); the lifted site seeded $8282 (ROM-domain), and the walks
diverged into a data self-cycle ($03:FF02 holds $FF00 — a one-node
loop sitting in stock ROM, reachable by any walk that ingests a
garbage head). The law generalises: any rewrite that changes an
instruction's bytes changes what its open-bus reads return, so sites
whose effective address can leave mapped space must keep their bytes.
Negative-idiom bases (operand ≥ $FF00) are the systematic visitors and
are excluded from the lift outright.

**Reading soak verdicts.** The end-of-frame RAM dump samples a fixed
phase: the same pc on every probe is not a hang until a trace proves
it, and busy=1 with the SA-1 mid-copy is the per-frame NMI-phase
dispatch caught in flight whenever the screen still advances. The
converse tells too: a static screen with live audio is not "parked" —
it is forced-blank with an NMI-less wait (game dead), or a stopped
CPU (STP in ROM data — trace-clk returns zero lines, the definitive
tell). Judge soaks by animation plus trace, never by hash alone; on
post-fork surfaces the conversion legitimately parks on screens stock
never visits, and only responsiveness (a synthesized START press) or
a pc/trace check separates parked from dead.

**Process rules written in blood.** Generate against a scratch copy of
the ROM — the generator writes its BPS next to the input, and one
auto-bisected 0-tree run silently replaced the shipped patch (restored
only because the generator is deterministic: rebuild the old commit in
a worktree, re-run the exact command, byte-identical output). Soak the
rung that ships: the plain `--save-attempt` name is the LAST attempt —
the losing async flavor — and the winner is the numbered sync rung;
`--patch` + sha256 against the rungs before soaking, every time. And
save states carry corruption with them: a state saved during a poisoned
session dies on every build, fixed or not, because the poison is in the
saved chains — regression-test states must be taken BEFORE the damage,
or the fix verified at mechanism level (trace the same clock window on
both builds and compare the loaded values).

**Where the arc stands.** Relocation + three trees + FastROM with all
of the above: 237 → 115 dropped frames, 57% → 17% utilisation, both
soak surfaces alive and cycling for 120k combined frames, the watchdog
silent throughout. One live defect remains open: a rare sorts-to-front
slot insertion at the stage-1 boss still ingests a garbage link from
the sentinel's neighbour bytes and follows it into the $FF00 self-
cycle — on the S-CPU, inline, invisible to every guard. The chase is
paused at the game's algorithm semantics, where the next hop needs
stock ground truth at the same logical moment; the instrument that
resolves it is a recorded playthrough (F10) reaching the boss, replayed
on both stock and the conversion by the behavioral tier, which finds
the first divergent cell mechanically.

## 11. The QA loop — what live play teaches that no surface can

Six live reports in two days, each one a defect class no verification
surface had ever seen, each one converted into a deterministic
specimen and then a mechanism. The loop itself is the lesson: a
player's F10 recording replays bit-exactly on the build it was
recorded on, so every "it broke here" becomes a power-on-reproducible
laboratory — and once a recording joins the surface list, no future
patch can ship if it breaks that exact run.

**Recordings bind to their native build.** A movie is a script of
inputs against one build's timing. Replayed on stock, conv-timed
inputs die within seconds (the recorded boss run parks at the
continue screen with score 200); replayed on a LATER conversion,
restored content invalidates the dodges (waves that now exist kill a
route flown through empty space). Every deep-content recording is a
one-build instrument, and each new frontier needs a fresh one.

**The coverage-source asymmetry, and the harvest.** Coverage and
evidence come from STOCK replays — but stock's replay of a
conv-recorded movie never reaches what the player reached. Gameplay
only the conversion can reach (the boss arrival) therefore never
covers its handlers on ANY build, and their low-WRAM reads stay
unshifted: reading dead memory, missing the scroll lock, overshooting
into the game's own insertion landmine. The fix is two-stage
harvesting from a replay on the PREVIOUS conversion: coverage first
(which instructions execute is address-space-invariant; merge only
where the instruction byte matches stock, which self-filters the old
build's scaffolding), then EVIDENCE through a normalizing classifier
that maps relocated homes back to stock classes (window → wram_low,
$40/$41 → wram_bank). Coverage without evidence is a half-measure:
covered-but-evidence-free sites still fall to the heuristic
exemptions, which is precisely where the boss script died. And
harvested evidence carries a caveat coverage does not: a broken run
executes broken paths, so its measured classes can misrepresent stock
— hygiene (gating on stock co-coverage or plausible values) remains
open work.

**Transient content is invisible to run-budget verification.** An
enemy wave lives ~20 ticks; the persistence budget tolerates runs of
30. Entirely missing content — every early wave of stage 1 — verified
as "wall-time echoes" for days. The structural rule: divergence
BUDGETS measure persistence, and anything whose natural lifetime is
shorter than the budget can be wholesale absent without failing. The
eyeball and the VRAM-diff (one tile of arrow, one column of missing
spawn records) are the only instruments for this class. Corollary
found the same day in the other direction: WRAM logic state can match
stock perfectly while the SCREEN is wrong (the menu cursor moved in
memory, never on screen) — pixels are unverified by design, so
UI-reactive rendering needs either pixel-diff spot checks against
stock or a player.

**The index-split class — one instruction, two worlds, split by a
register's magnitude.** The level-script walker's `LDA $0003,Y`
serves spawn-record reads (small Y, the WRAM-low mirror) AND ROM
walks (huge Y) through the same three bytes; measured evidence says
wram_low|rom, and no static operand serves both. The mechanism: a
runtime thunk dispatching on the index register — the third dispatch
mechanism beside the DBR-split thunk (low|bank) and cell coherence
(unindexed). Two hard-won details of the thunk itself: the site's
recorded index width is only the LAST run's, so the thunk must be
WIDTH-PROOF at runtime — the v1 16-bit CPY immediate misparsed under
an x8 caller, whose third byte ($20 of #$2000) executes as JSR into
garbage; v2 tests the caller's pushed X flag first, and an 8-bit
index over a tiny base can only reach the low mirror, so x8 callers
take the window path unconditionally. And the thunk scratches A, so
only LDA-shaped sites qualify (the load overwrites A anyway; its high
byte survives an 8-bit scratch).

**Evidence growth shrinks the eligible forest — honestly.** Every
newly evidenced instruction inside an offload tree's span is a new
chance for the eligibility walk to find a genuine SA-1-bus hazard it
previously could not see. The physics tree that verified clean for
days was refused the moment the boss-path instructions inside it
became visible — correctly: those reads are I-RAM on the SA-1. The
utilization cost (17% → 48%) is the price of honesty, and the
recovery path is mechanical, not epistemic: make the split thunks
tree-portable (the thunk template already reads identically on both
buses; only the JSR's bank-relativity from a copied tree needs
copy-local thunk emission).

**Auto-bisect convicts a failure, not a cause.** The 25-byte sound
pump was "convicted" on the boss surface — but its failure was at
frame 831, the old title-transition wedge, nothing to do with the
boss; the movie's replay forked away from the real crime scene before
reaching it. A surface failure names the first thing that broke on
THAT replay, which is not necessarily the thing the player reported.
Dropping the pump still shipped (its f831 failure was real), but the
boss froze again — attribution requires the failure and the report to
be the same event.

**The engine map earns its keep.** Chasing six defects through one
game bought a reusable schema: object records at $0400-$0FFF, stride
$40, handler pointer at +0; the slot walker at $9082; the object
update loop at $EA7A (X = slot, dp $FC = cursor, scroll deltas first,
handler dispatch after); the allocator free-pointer in dp $FC; script
channels around $1A40 with the game's own NMITIMEN shadow discipline
at $1E82. Each chase that maps another organ makes the next chase
shorter — the two open defects (laser damage, the pre-boss phantom
collision — plausibly one collision-engine defect seen from both
sides) start from this map instead of from zero.

## 12. The abandoned home — what an unconverted site actually does

The laser passing through enemies, the missing enemy waves, the boss
that never arrived: three reports, one mechanism, and none of the
per-defect hunts found it. What found it was asking a question no
reference run is needed to answer.

**The stale-home law.** After the window relocation, the game's low
8 KiB lives at `$6000-$7FFF` and its `$7E/$7F` banks live at
`$40/$41`. Real WRAM — the system-bank mirror below `$2000` and banks
`$7E/$7F` — is then *dead*, deliberately and completely. So every
data access to it is a site the rewrite failed to move, and the
program counter names it. That check needs no baseline, no movie
pairing, no lag reasoning: it is a property of the converted image
alone. `--stale <max-sites>` reports each offending (PBR,PC) once.

Run against the laser recording, the shipped conversion produced
twelve sites. Eight were tiny-base indexed absolutes — four loads and,
critically, **four stores**, including `STA $0030,Y` at `$02:8C8B`
writing the beam's own collision record to memory nothing reads. Three
were plain absolutes (`CPY $020A`, `SBC $020A`, `LDY $0212`) under a
system data bank. All twelve measured `cov=00`: not merely unevidenced,
**never discovered at all**, so the rewrite loop — which is keyed on
coverage, not on the instruction being there — skipped them whole.

**Two rules had to change together.**

*Reach.* `--wg-static` extends coverage by recursive descent from
every executed instruction, and until now it had never been used on a
real conversion. Without it, code the profile never ran is not
rewritten, and "not rewritten" is not neutral: it is a live access to
abandoned memory. The flag is the difference between a conversion that
works on the recorded surfaces and one that works on the game.

*Decision.* Statically discovered code has no evidence by
construction, and the old rule left a tiny-base indexed absolute
alone whenever evidence was absent — on the reasoning that a tiny base
under an index is the "X is the pointer" idiom. That is right for a
ROM walk and *wrong for a data base*, and the wrong half writes into
the abandoned WRAM. Leaving it alone was never conservative; it was a
coin flip. So an unmeasured tiny-base indexed absolute now becomes an
index-split thunk on principle.

**The thunk grew a third world.** Two dispatch questions collapse into
one 35-byte body, and the unshifted operand serves two of the three
answers:

    system bank + small index  ->  the window (+$6000)
    pinned bank ($40/$41)      ->  as written (that bank's own low page)
    system bank + huge index   ->  as written (a ROM walk)

The DBR test comes first (`PHB/PLA`, `BMI`/`BIT #$40`), the caller's
pushed X flag second, the magnitude compare last. Testing the pin at
run time is what lets an *uncovered site inside a DBR-pinned tree* —
the shape the eligibility walk used to admit by proof — be thunked
without breaking it.

And the body is **A-preserving** (`PHA` under `SEP #$20`, one byte
whatever the caller's M, pulled back under the restored M). That one
change is why stores are covered at all: the v1 template scratched A,
so it could only serve LDA shapes, and every `STA $00xx,Y` in
unmeasured code stayed pointed at dead memory. The defect the
mechanism was invented for was in the half of the mechanism that did
not exist.

**Ninety-one thunks do not fit where five did.** Scaling a mechanism
from a handful of measured sites to a whole-image rule turned out to
be mostly an *allocation* problem, and each failure taught a rule:

- **One run is not the budget.** `findFreeSpace` hands out the tail of
  the single largest padding run — right for one scaffold, wrong for a
  population. Bank $00 holds 1476 bytes of slack against a 2 KiB
  scaffold; the thunks have to come from whatever is left, in as many
  pieces as it takes.
- **Reserve by address, not by paint.** The old trick painted the
  scaffold's carve with `$00` so the search would not claim it — which
  only works while the painted run stays shorter than its neighbours.
  The allocator now skips the carve by address.
- **$FF only.** A long run of `$00` is as often a real table of zeros
  as it is slack. A whole-image allocator meets the ambiguous ones,
  and 300 bytes written into a `$00` run in bank $0E rendered pictures
  the original never showed. `findFreeSpace` takes one obvious tail
  and gets away with it; this allocator cannot.
- **A far body behind a near stub.** `JSR` is bank-relative, so the
  body wants the site's own bank — but 35 bytes each will not fit, and
  5 will: `JSL far / RTS` in the site's bank, `RTL` tails in the body.
  The two pushes the body indexes off the stack sit at the same depth
  either way.
- **All or none, per bank.** Filling a bank with the first arrivals
  leaves the tail sites without even their stub. The bodies-or-stubs
  decision is made per bank, before anything is written, over the
  whole demand.
- **Fill far banks downward.** The low banks hold the code, so they
  hold the sites, so they are the banks that still need their own
  stubs. Filling upward from bank $01 spent bank $02's padding on bank
  $00's bodies and then had nowhere to put bank $02's own.
- **Share bodies.** `LDA $0000,Y` appears twenty-odd times in a bank
  and one thunk serves them all. 91 sites became 51 distinct bodies,
  and a bank with 141 bytes of padding and 29 sites came inside its
  budget only because of it.

**The result, stated honestly.** Zero stale sites across six
recordings and ~34 000 frames, and the conversion verified FRAMES
IDENTICAL — every one of 3000 frames pixel-identical to stock, which
no previous build achieved. But that build carries no offload tree and
no FastROM: the tree that shipped at 48% utilization now fails
verification in this configuration, and FastROM layered on top trips
the pixel gate outright. Correctness first, then speed; the two are
being paid for in that order.

## 13. The audit — a denominator at last

Every defect in section 12 was found by playing the game until something
broke. That works, and it is not a method: it has no denominator. You
cannot tell a game with three landmines left from one with three hundred,
and you cannot tell either from a game with none.

`--audit` converts once, prints what the rewriter decided about every
memory-touching site it saw, and stops before verification — minutes
instead of the whole ladder. The verdicts are **recorded as the decisions
are made**, never re-derived afterwards: an audit that reimplements the
rules is an audit that can disagree with them, and then it is worse than
nothing.

Nine verdicts, of which six are decisions and three are bets:

    shifted / rebanked / thunk_dbr / thunk_index    the site was converted
    left_high     operand >= $2000 — MMIO or ROM, native either way
    left_rom      measured traffic never touched low WRAM
    ---
    left_pinned   the data bank was STATICALLY proved BW-RAM here
    left_mixed    measured low WRAM, but not only, and no thunk shape fits
    left_unproven no evidence at all, and the shape is not one we move

The last three are the ones that address the abandoned home. Naming them
as a class is the whole point.

**What it said about Gradius III.** 1531 sites decided: 690 shifted, 115
re-banked, 88 thunked, 447 left high, 157 left on ROM evidence, and **34
still addressing the pre-conversion home** — of which 30 are `left_pinned`
whose *measured* evidence agrees with the static pin (low risk, and now
visible), and four are not:

    $00:90ae  LDA $000000,X   ev low|rom    the slot walker
    $00:90ba  LDA $000002,X   ev low|rom|other
    $00:90c4  LDA $000000,X   ev low|rom
    $00:f330  LDA $000000,X   ev (none)

All four are `long,X` with a tiny base — the *same* index-split class the
absolute thunk was built for, in the one addressing mode the thunk does
not cover. Three of them sit in the slot walker at `$00:9082-$90AA`: the
routine at the centre of the boss freeze and the collision defects. The
audit found in one run what six QA sessions had been circling.

**The reach number, and the alarm it did not justify.** The first cut of
this report said: instructions the rewriter has ever seen are 8338 in bank
$00, 2559 in bank $02, and **zero in the other fourteen** — which hold
~29 KB of content each. Read alone, that says the conversion has seen an
eighth of the game, and the obvious next move is a better disassembler.

It was the wrong reading, and what fixed it was not analysis but three
more measurements. Alongside coverage the audit now counts, per bank:
`JSL`/`JML` sites in seen code naming it as a TARGET; long accesses and
block moves naming it as a data SOURCE; and how often its bytes are the
eight opcodes that dominate real 65816 code, with the two known code banks
as the yardstick.

    bank     ran   seen  calls-in  data-refs  density
    $00     6607   8338       484         71    .139
    $02     2168   2559       205         14    .127
    $01        0      0         0         31    .032
    $03        0      0         0          6    .034
    $04..$0F   0      0         0        0-2    .025-.032

Every other bank sits at a quarter of the code banks' opcode density, is
never named by a far call, and several are read as data. Gradius III's
executable code lives entirely in banks $00 and $02, and the rewriter
holds all of it any recording reaches plus 3259 instructions of static
descent. There is nothing dark to light up.

**A false lead, retracted by the same evidence.** The menu chase had
recorded `$01:AAF7`, `$04:E884` and `$05:E2D9` as three unshifted
consumers of the redraw flag — all `AD 01 01` = `LDA $0101`, found by
searching the ROM for the byte pattern. They are not instructions. The
bytes around `$01:AAF7` are

    8e ab  c8 ab  fc ab  2a ac  5e ac  62 ac  96 ac  ca ac ...

an ascending 16-bit pointer table, in which that `AD` is a pointer's HIGH
BYTE and the `01 01` after it belongs to the next entry. Which is exactly
the rate the census predicted: a low-operand absolute decodes out of
arbitrary data roughly every 23 bytes, about thirty false sites for every
real one. **Searching a ROM for an instruction finds data that spells
it**, and the only defence is a signal that separates the two — which is
what the density column is for.

So reach is not the problem it briefly looked like. The one door static
descent still cannot open is the 39 `JMP (abs)` dispatch macros in seen
code: bank-confined, pointer built in RAM, and already handled by shifting
the five-byte signature rather than by following it. There are zero
`JMP/JSR (abs,X)` and zero `JMP [abs]` in the entire body of code we can
see, so there are no jump tables to recover either.

The audit's real service was not the landmine list. It was refusing to let
a number be read as a conclusion — and then killing a hypothesis of its
own making within the hour.

## 14. The audit's first bill

The audit named four hazards; three of them were `LDA $03:0000,X` in the
slot walker, and fixing all four broke a build that shipped. That sequence
is the lesson, not a footnote to it.

**Correct is not free, and the audit does not price its own findings.**
The `long,X` thunk is right: with a small X those three sites read the low
mirror, which moved, and leaving them reads memory nothing writes. But the
slot walker is the hottest loop Gradius III has, and a thunk there costs a
`JSL` and an `RTL` — some thirty cycles a call. Paying it moved the
timeline far enough that the behavioural tier stopped accepting the
configuration that had been shipping for days. Nothing was corrupted: the
conversion just ran differently enough that the verifier could no longer
tell removed slowdown from divergence.

So the rule now thunks `long,X` only where there is **no evidence at all**
— where nothing has been measured, nothing is known, and the site is
unlikely to be hot precisely because no profile ever ran it. Sites like the
walker's, measured `low|rom`, stay as they were and stay in the audit's
hazard list. Named, not silently forgiven, and not silently paid for
either. That is a worse conversion than the one that thunked them, and a
better one than the one that did not know they existed.

**A regression I introduced, and how it hid.** The v1→v3 index-thunk
rewrite also touched the five sites that were already thunked and already
shipping. It was strictly more correct — A-preserving, data-bank-aware —
and it was eight bytes and ~17 cycles more expensive on a hot path.
Changing a working path while generalising it is how a day disappears:
after the change, `--wg-static` looked like it broke the offload tree, then
FastROM looked like it wedged at frame 831, and neither was true. What
finally separated cause from coincidence was building the pre-session
commit in a worktree and running the SAME image through both binaries: the
verifier's numbers came back byte-identical, which cleared the verifier and
left only the image. The three lines of difference were the whole story.

**The general shape:** when generalising a mechanism, keep the exact
behaviour on the inputs it already served. The v2 template is still in the
tree, used for precisely the shape it always served (an `LDA` measured
`low|rom`), and the new templates take everything else.

**Two measurements worth keeping.** `--audit --save-attempt` produces a
converted image in about six minutes — profile plus one conversion, no
verification — which is the right granularity for asking "did this rule
change the image?" instead of "did this rule ship?". And `--hash-stream`
writes one frame hash per frame: collapse consecutive duplicates and two
runs of the same game show the same picture sequence however much lag
differs between them. It confirmed independently that the shipped
relocation is frame-identical to stock, and it showed that the tree build
renders 60 pictures stock never showed against the *shipping* build's 157
— which is how we know novelty is not the defect signal it looks like.

**What the tree investigation actually established.** `--wg-static` and the
ninety-odd thunks are behaviourally inert on the verification surface:
images built with and without them produce byte-identical tier statistics.
Delta-debugging FastROM's 673 bank lifts showed the culprits are among the
584 **call** lifts, not the 89 data-long lifts — reverting every data lift
changed nothing — so the divergence is execution speed, not a poisoned
read. The tree build soaks 40 000 frames with the mailbox idle, the S-CPU
in ROM and no aborted dispatch. And dropping the tree makes the verdict
*worse* (a 514-tick run against 157), which means the auto-bisect ladder
assumes something false: that removing an offload monotonically improves
the verdict. When the failure is a lag artifact, removing a tree moves the
fork instead of removing it, and the ladder walks downhill.

## 15. The verdict that punished the speedup

A day went into attributing a verification failure to `--wg-static`, then
to FastROM, then to my own thunk template. It was none of them. It was one
branch in the behavioural tier, and the instrumentation that found it took
twenty minutes to write.

**A failure that could not be compared to a pass.** The tier printed rich
statistics when a surface passed — ticks compared, stable-lag ticks,
diverging ticks, worst run — and a single sentence when it failed. So a
passing run and a failing run could not be diffed field by field, and every
hypothesis about the difference had to be inferred from the image instead.
Printing the same numbers on both paths ended the guessing immediately:

    behavioral: FAIL — live state diverges and never heals
      stats: 1259 ticks compared, 7 diverging, worst run 4, long runs 0

Seven diverging ticks out of 1259, worst run 4, no long runs — and a
verdict of "diverges and never heals". The verdict was never about
divergence.

**The bug.** `persistence` carried two unrelated causes under one message:
live state that diverged, and a pairing that simply stopped. The tier pairs
logic ticks, and at an input edge it advances whichever side is behind in
epoch. A conversion that removed slowdown spends FEWER wall frames per
logic tick, so it sits at an EARLIER wall frame than the baseline — and
catching it up to the baseline's epoch burns its remaining frame budget.
Near the end of a surface it runs out, and the tier called that "the
conversion stopped ticking".

So the tier punished a build for being faster, which is the one thing every
build is trying to be. Worse, it did so *conditionally*: whether the last
input edge fell inside or outside the budget depended on the exact lag
differential, so any timing change at all — FastROM, an offload tree, eight
bytes of thunk on a hot path — could flip a verdict without touching
correctness. That is the whole explanation for a day of unstable
attribution, and for the earlier observation that DROPPING a tree made the
verdict worse: it moved the differential, not the correctness.

**The fix** is to name what happened. Exhausting the budget while catching
up to an edge is the end of the COMPARABLE REGION, not a hang: every tick
paired so far was paired honestly and the verdict belongs to them. The
genuine hang — the conversion stopping while the baseline still ticks — is
a different exit and still fails. Both are now printed by name, on pass and
on fail, along with the tier's inputs, because a surface whose tail went
uncompared should say so rather than quietly counting as a clean pass.

**And the invocation goes with the artifact.** Three times in one day a
generation could not be reproduced because the command was reconstructed
from prose notes — missing `--wg-fastrom`, then `--verify-behavioral`, then
neither. The generator now echoes its own argv as the first line of every
run and writes it to `<patch>.bps.cmd`. Every hour lost to that would have
been one `cat`.

## 16. Recovering the physics tree — a leaf, and three allocators

`$8EF1` is the prize: the difference between 48% utilisation and 17%. It
had been parked for days behind an NMI-interleaving hazard, then behind
an eligibility refusal. The refusal turned out to be one line of
diagnostic output:

    [win $8ef1] member $9028: I-RAM hazard long_x $03:0000 at $90ae evidence 03

`LDA $03:0000,X` in the slot walker. An unshifted low-mirror indexed long
is the SA-1's OWN I-RAM, so a tree containing one computes different
results per CPU — a correct refusal of a real hazard.

**The thunk removes the hazard; the walk could not see that it had.** An
index-split thunk is SA-1-safe by construction: its window arm addresses
the identity window, the same bytes at the same addresses on both buses,
and its as-written arm only runs once the index has carried the address
past `$2000`. But a `JSL` into a thunk looked like a far call to another
bank and was refused on sight. So thunk bodies are now handed to the
eligibility walk, **a call into one is a LEAF rather than a member**, and
the caller's data-bank pin survives it (the thunk's only bank traffic is
a balanced `PHB`/`PLA` it reads and discards). Walking *into* one would
see the as-written arm out of context and refuse the tree over the very
hazard the thunk exists to remove.

The `long,X` flavour is uniquely suited to this, and it is worth knowing
why: **`JSL` names its own bank, so a copied tree member carries a thunk
call unchanged.** The `JSR` flavour does not — a copy runs in another
bank, where a bank-relative `JSR` lands on garbage. That asymmetry decides
which generalisations are available (see section 17's third round).

**Then three allocators, each hiding the next.** Making the tree eligible
raised the copies' demand and every offload vanished:

- **Silence.** `findFreeSpace` failing for the tree copies did `orelse
  return null` — every offload abandoned, `$9BCD` lost along with the new
  tree, 116 dropped frames becoming 186, and nothing in the log. A
  zero-offload patch is indistinguishable from a game with nothing worth
  offloading, which is exactly how it hid. It now says so.
- **The wrong unit.** Reserving the whole biggest BANK for copies was
  worse: the far pool then ate banks `$01`-`$04`, which need their padding
  for their own 5-byte stubs, and the thunks stopped fitting at all. The
  right unit is the **run's tail** — that is where `findFreeSpace`
  allocates from, so thunks filling the head cost the copies nothing.
- **A parameter accepted and ignored.** `padAllocFor` took a reservation
  and applied it only to bank `$00`. The tail was reserved in name only,
  thunks wrote 395 bytes into it, and the copies still did not fit —
  visible as a 2,165-byte run where 2,560 was supposed to be. This is the
  worst of the three: silently dropped arguments read as working code.

## 17. The boss — four ways to misread the same evidence

`$8EF1` landed and the stage-1 boss ARRIVED for the first time in the
project's history. It rendered as garbage. Chasing it took four rounds,
and the shape of the mistake is the same each time: **treating what the
evidence happened to show as proof of what it could show.**

A save state of the scene plus `--stale` made every round measurable —
and note the instrument, because it is the one that works when the bug is
inside an offload: the stale detector reported program counters *inside
bank `$0D`*, which is where tree copies live, so the tree was demonstrably
reading its own I-RAM.

**Round 1 — out of range.** `$00:90DF`, `LDA $02:FFFF,X`. A base at or
above `$FF00` wraps FORWARD into the next bank's low page: `$02:FFFF` + 7
is `$03:0006`. Three separate checks missed it for the same reason — they
test `v < $2000`, and `$FFFF` is not: the thunk rule, the window shift,
and the eligibility walk's hazard check, the last of which is why the tree
was admitted. The thunk for it differs in shape from the tiny-base one:
**two compares** (the mirror is a range here, not a ceiling — an index
below `$10000-v` has not wrapped and is still reading this bank's ROM
tail), **no A scratch** (the dispatch reads X alone), **`REP #$10`
instead of a width test** (setting the X flag zeroes XH, so an x8
caller's index has the same numeric value read as sixteen bits), and a
window arm that keeps the distance by **advancing the bank** —
`$01:FFFF` + `$6000` is `$02:5FFF`.

**Round 2 — measured ROM-only.** `$00:911D` and `$00:9155`, more
instances of the same walker read, left alone because their evidence was
ROM-only across five surfaces and two cover harvests. The boss path is
where they reach the mirror. So the evidence test came out entirely:
reaching that branch already means the site is not provably pure-low, and
the thunk is correct in BOTH worlds, so ambiguity gets the thunk and only
a proof of pure-low earns the cheaper static shift. **Priced before
shipping** on two images differing only in that rule: 93 → 121 thunks
costs one point of mean utilisation, identical dropped frames.

**Round 3 — the generalisation that costs both trees.** Widening the
DBR-split thunk the same way (fire on any evidence naming the bank, not
just `low|bank`) is the obvious next step and it must not be taken as
written. Sites measured only under a pin are exactly what a pinned tree
is full of; they become `JSR` thunks; a `JSR` is not portable into a
copy; the walk refuses the tree. Reverted, with the reason left at the
site. It needs copy-local thunk emission first — which section 16
explains the `long,X` flavour never needed.

**Round 4 — not an evidence problem at all.** `$02:9588`, `LDA $08D0`,
came back `cov=00 ev=00`. Nothing had ever reached it: no surface, no
harvest, not `--wg-static`'s descent. Anchoring the profiler at the boss
save state does not help either — a window-converted state loaded onto
the stock console does not run the boss path.

**And the reason the reach was missing is the lesson worth keeping.** The
cover harvest can only donate coverage for code a recording actually
EXECUTES. No recording in this project had ever reached a working stage-1
boss **because the boss had never worked** — `boss-conv.ymv` was captured
on a build where it never appeared. The defect hid behind itself, and the
only thing that could dislodge it was a player reaching the boss on a
build where it finally arrives. That recording donates 711 instructions
and 308 evidenced sites, and `$02:9588` comes back `wram_low` — pure low,
so it takes a plain static shift at no runtime cost at all.

**A recording is only written when it is STOPPED.** `F10` starts, `F10`
again stops and flushes. Two round trips were lost to a recording that
was never stopped and therefore never existed.

## 18. Value provenance — bank bytes that travel as data

The stage-1 décor rendered wrong on every window build (union57 and
before), and the defect was invisible to the entire rewrite catalog,
because the bytes at fault never sit in an instruction: the game builds
DMA queue records by copying a ROM **table** through WRAM staging cells
into `$43x4`. A `$7F` that lives in ROM as *data*, is loaded, parked,
and forwarded, passes through no rewritable shape at all — and DMA then
reads the abandoned bank. Six table bytes (`$7F`→`$41`) fixed the décor;
union58 differs from union57 by sixteen bytes total.

Proving those six took a provenance chain with three properties, each
earned by a miss:

- **The source map must cover all 128 KiB of WRAM** (it covered the low
  8 KiB): the staging cell can be anywhere.
- **Provenance must survive WRAM loads**: ROM byte → WRAM cell →
  `$43x4` is two hops, and the evidence walk originally dropped the
  chain at the first one. Reads go through the live bus (`peek8`), not
  the WRAM array — on a converted image that array is a dead copy.
- **On a conversion-side replay, BOTH homes are evidence.** The first
  version accepted only `$40/$41` under conversion and thereby dropped
  the `$00:92C3 LDA #$7E / PHA / PLB` proof. A *missed* reference on a
  converted image still lands in `$7E/$7F` — which is exactly the class
  being hunted. Filtering it out filtered out the bug.

That last property is what lets **cover replays donate bank-byte
provenance**: a recording played on a previous conversion now feeds the
same chain the stock profile feeds.

The companion blind spot, named while chasing this: **DMA bypasses the
CPU.** The stale detector observes data reads and writes; what a DMA
channel fetches never crosses it. `--dma-trace` (flags transfers whose
source is an abandoned home) and `--dma-bank-pc` (which instruction
handed the channel its bank byte) exist for that gap — and the latter's
dedup key must include the VALUE, not just the PC: a site that hands
over `$40` on one pass and `$7F` on another is exactly the bug being
hunted, and a PC-only key reports only whichever came first.

## 19. One state sees one scene — the intersection

The anchored evidence pass profiles the scene its `--state` holds, and
Gradius III's two slow scenes barely overlap: 98 routines executed only
in the stage-1 anchor, 362 only in the stage-2 (bubble) anchor, 129 in
both. A candidate set chosen from one scene optimizes that scene — the
stage-1 builds left stage 2 at 19.8% lag.

The fix was measurement, not guessing. A second state (extracted from a
player's take with `--save-state-at <frame>=<path>`), a profile of each
scene, and a per-routine complexity backend (`callgraph.zig`:
instructions, branch count, cyclomatic complexity, callers — built after
Vilela described using call-graph tooling for exactly this) joined into
one ranking by combined slowdown share:

    $8EF1  stage-1 heavy  AND  87% of stage-2 slow work
    $9028  hot in both    (70%)
    $9020  hot in both    (66%)
    $9BCD  99.7% stage-1-only

That table is why the shipping set is those four trees: the two-scene
pair was promoted on numbers, and `$9BCD` retained for the scene it
owns. Stage-2 lag fell 19.8% → 12.5% with stage 1 unharmed (114 → 115
dropped).

Two lessons from wiring `--wg-add` (offer a routine to the selector by
hand):

- The flag's code landed in the whole-game candidate block, not the
  window one — and union62 came out **byte-identical** to union61, with
  the flag's own log line never printing. A flag that lands in the wrong
  branch still produces a plausible build; the header's warning about
  reconstructed commands applies one level down, to the flags'
  implementations. The byte-diff and the missing log line are what
  caught it.
- Offering a candidate is not enough: its CALL SITES must be covered,
  or there is nothing to re-point at the stub.

## 20. The bank seam — the PC wraps inside a bank

A player's stage-1 recording froze or reset about a minute in, on
union63 only. The 65816's program counter wraps WITHIN a bank: after
`$xx:FFFF` comes `$xx:0000` — in LoROM's low half, the WRAM mirror. The
offload tree copies needed 5,638 contiguous bytes; `findFreeSpace`
guarantees only FILE contiguity; the span ran off the end of bank `$1E`,
and the copy's tail executed abandoned memory until the console reset.

The law: **anything that executes must be bank-contained.**
`findFreeSpaceInBank` (top-down through the banks, never bank `$00`, a
span never crosses a seam) now allocates every copy. Two footnotes worth
their lines:

- The 512 KiB image never showed the bug because its biggest padding run
  happened to end exactly on a bank boundary. Expansion (section 21)
  created the first run that didn't.
- The same seam explained a standing mystery: `$9BCD` traced **zero
  instructions** in unions 62–63. A copy past the seam cannot run, so
  the auto-bisect silently dropped the tree. A tree that contributes
  nothing is a symptom, not noise.

## 21. Expansion, and what it cannot buy

`--wg-expand 1m` grows the image to 1 MiB: new banks filled with `$FF`
(the only byte the padding allocators treat as free), and the header's
size byte (`0x17` = log2 of KiB) updated to agree with the file — or the
loader masks the new banks straight back onto the old ones. 523,816
bytes of padding, and the tree-copy space crisis ended permanently.

What expansion cannot buy is bytes **in the banks the code lives in**.
The scaffold needs bank `$00` (the reset vector, JSR reach); a split
site needs stub bytes in its OWN bank (a JSR cannot leave the executing
bank). Expansion adds empty banks at the top; the pressure is at the
bottom, in banks that ship 149 bytes of slack. That pressure is section
22's wall.

## 22. The per-bank ceiling, and the cold dispatcher that removed it

Unions 65, 66, and 67 — every attempt to add a twelfth cover pair or
swap in a richer one — refused with "no padding run in bank $00 is large
enough for the boot shim / needs 35 bytes". Both halves of that message
were wrong (it is the shared `no_free_space` string): the 35 bytes were
one PINNED index-split thunk, and the failing allocation was its 5-byte
far stub in the SITE's own bank. `dbg_thunk_pad` named the real wall:

    bank $02: 44 site(s), 31 distinct thunks
    bodies need 1,284 bytes; stubs need 155; the bank has ONE run of 149

The growth law behind it: an unmeasured tiny-base indexed site takes the
full thunk *on principle* (`pin = e==0` — the laser lesson, section 11),
and cover harvests grow coverage faster than evidence. So **five bytes
per site is a ceiling that coverage itself walks into** — three refusals
proved that adding evidence had begun to stop the patch existing.

The fix inverts the cost for exactly the population that grows. Per
bank, three tiers, decided before anything is written: bodies when they
all fit; a far stub per thunk when at least those do; and when even one
stub per thunk exceeds the bank, measured thunks keep their stubs and
every UNMEASURED one shares **one** stub through the cold dispatcher —
`JSR shared_stub` → `JSL dispatcher / RTS`. The dispatcher identifies
the caller by the return address the site's own JSR pushed: binary
search over a sorted (site → body−1) table of 8-byte records, then an
`RTL` into the same RTL-tailed body a per-thunk stub would have named.
The load-bearing tricks:

- **The stack hole.** Three bytes reserved BELOW the saved registers at
  entry; the body address is written into them mid-search with
  stack-relative stores; scratch is dropped with `TSC/ADC/TCS`; the
  registers are restored; `RTL` consumes the hole. No scratch memory
  anywhere — reentrant against any NMI, including one that dispatches
  through this same code.
- **Frame identity.** The body enters seeing [3-byte JSL frame][2-byte
  JSR return] — indistinguishable from the per-thunk far-stub path — so
  every existing thunk template is reused unchanged, and the flags the
  body's op sets survive (RTS/RTL do not touch P).
- **`AND #$7F` on the pushed PBR**: a site executing from a fast mirror
  (`$82`) must fold onto its file bank (`$02`) or the lookup misses.

The price is ~150 cycles per call, paid only by sites that never
executed once across ~100,000 profiled frames. The tier refusal now has
its own reason (`wg_thunk_space`) and names the bank.

union68 is the result: 39 sites through the dispatcher, boss-surface
performance identical to union64 to the frame (mean 17%, slowdown 0.3%),
and the ceiling gone — evidence is free to grow again.

And the loop closed on the standing defect. union64's one residual stale
read — `$82:F97A LDA $0010,Y`, DBR=`$01`, reading abandoned `$01:0250`
once in 7,671 frames — was observed during a player's stage-2 take. That
take, harvested as a cover pair, donated the site's evidence
(`wram_low`, pure), and the generator fixed it with a plain static shift
(`LDA $6010,Y`) at zero runtime cost. Same shape as the boss (section
17): **the witness of a defect is the evidence that repairs it — record
on the build where the defect shows.**

## 23. `--save-attempt` saves the attempt, not the verdict

Hours went into diagnosing a spectacular boot-time SA-1 runaway in
`ship68.sfc`: a dispatch with every mailbox cell reading `$FF`, the tree
entered in m8/x8 (whose real stream is m16/x16 — the width misparse
turns `A0 FC FF 29 10 00` from `LDY #$FFFC / AND #$0010` into `LDY #$FC
/ SBC $001029,X`), an open-bus walk through unmapped space, the watchdog
abort, the scene heal. All real, all reproducible — **and all in an
image the generator had already rejected.** The greedy pass tries the
async (fire-and-forget) flavor after the sync config passes; async
failed its own verification ("live state diverges and never heals") and
the sync config was kept — but `--save-attempt` writes the LAST image
generated, which was the async one. The BPS is the verdict; the attempt
file is a crash dump of whatever died last. **Evaluate the BPS-applied
image.** The generator's own gates had already caught everything the
manual hunt rediscovered.

The hunt paid its way in instruments, kept:

- `[stale]` prints the clock, and **clk=0 means the SA-1 core** (its bus
  has no clock) — one field answers "which CPU", the question that
  reframed the whole episode.
- `--stale-ring` keeps the SA-1's last 8,192 instructions and dumps them
  at the first stale hit — the history a forward trace can never afford
  to keep. 200,000 instructions of `--trace-sa1` ran out before the
  episode; the ring caught the entire story in one run: service loop →
  dispatch block → unmarshal reading `$FF`s → tree entry → misparse.
- The width-misparse **signature**, worth recognizing on sight: a run of
  stale reads at consecutive PCs with a constant stride and a constant
  effective address is one wrong-width stream misdecoding a correct one.
  (In the shipped sync flavor this cannot arise from a legitimate call —
  the dispatch marshals the caller's true P, and no real caller enters
  these trees narrow; stock itself would misparse.)
