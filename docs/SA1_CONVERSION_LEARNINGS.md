# SA-1 Conversion: What the Machine Learned

Everything below was earned on one real cartridge — Gradius III (USA) — by the
loop *generate → verify → fail → dump-diff → disassemble the failing site →
fix the rule → regenerate*. Each rule cites the failure that forced it. The
reference throughout is Vitor Vilela's hand-crafted SA-1 patch (v17), used as
an answer key by byte-diffing, never as a source.

The work lives on PR #115 (`claude/sa1-async-offload`). The one-command entry
point:

```
yamabuki-headless <rom> --gen-sa1-patch --window --wg-static \
    --verify-behavioral --state <gameplay.state> --movie <inputs.ymv> --skip 0
```

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

**The shipping patch is the full-cycle relocation.** Under the widest
surface yet — 4,800 frames covering the logo auto-advance, title with
music, menu, and the attract gameplay demo — the relocation-only patch is
BEHAVIORALLY EQUIVALENT (worst active run 3) and cycles the whole attract
sequence untouched. Speed-neutral, but correct everywhere a player can
reach without a controller.

**The offloaded builds are honest speedups on narrower surfaces, and the
widest surface caught them.** The three-tree build (`$9BCD` + the
1,324-byte `$8EF1` physics tree + `$8C95`) verified BEHAVIORALLY
EQUIVALENT over 1,800 frames including the menu — dropped frames
287→186, utilisation **53%→23%** — and its earning history is real: the
wall-time verdict work and the pin propagation (sections 5 and 6) were
both required and both stand. But the 4,800-frame surface added the
title-music phase, and there every offload build diverges at ~f830: the
copies enter states their S-CPU originals never do (the slot walker's
runaway cursor), the divergence spreads, and live play freezes — the
attract-demo wedge a play session found first. The auto-bisect dropped
all three and shipped the relocation, which is the system working as
designed: the widest coverage wins the argument.

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

**And the reach number is the real headline.** Per bank, instructions the
rewriter has ever seen — executed, plus everything `--wg-static`'s
recursive descent added:

    $00  8338      $01  0      $02  2559     $03..$0F  0

Fourteen of sixteen banks, ~29 KB of content each, and not one instruction
seen in any of them. Most of that is graphics — but not all of it, and the
audit cannot tell which, so it says so. The proof that it is not all
graphics was already in hand from the menu chase:

    $01:AAF7  LDA $0101   UNCHANGED
    $04:E884  LDA $0101   UNCHANGED
    $05:E2D9  LDA $0101   UNCHANGED

Three live instructions reading the menu's redraw flag out of low WRAM, in
three different dark banks, none of them rewritten, none of them
discovered by any recording or by static descent. The descent seeds from
executed code and follows control flow; the way into those banks is an
indirect mode dispatch, and indirect dispatch is exactly what static
analysis cannot follow. That is the same wall as the `JMP ($0000)` macro,
met from the other side.

So the honest statement of where the conversion stands is not "we fixed
the laser". It is: **the rewriter has seen two of sixteen banks, and every
instruction in the other fourteen that touches low WRAM is unconverted.**
The next lever is reach across bank boundaries — jump-table and
dispatch-table recovery seeded by measured coverage — not another
recording.
