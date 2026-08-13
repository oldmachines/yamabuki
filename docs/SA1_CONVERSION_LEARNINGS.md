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
DISPLACED the attract-demo phases (game-over reaches the continue
screen; attract never returns inside the budget), so sites covered only
by the demo — including the title-exit countdown driver `INC $1C00` at
`$00:A2DE`, behind a mode dispatch the static walk cannot pierce — fell
back to stock bytes and broke the title path at f833. Adding a surface
subtracts another; the covered-surface law needs ADDITIVE tooling:
evidence and coverage union over MULTIPLE input movies (profile and
verify each surface, rewrite from the union). That is the next
mechanism, and it subsumes every displacement failure this arc hit.
Until then, offloads and the full-game relocation stay blocked on this
game; the attract-cycle relocation remains the widest verified build.

A phase-dependence note from the same run: the sound pump measures
MAINLINE context in attract and INTERRUPT context in gameplay — the
single-context rule fired for the first time (and kept the interrupt
class, which under gameplay carries the larger slow work). Context is a
property of a surface, not of a routine.

After the split-site mechanism: the bubble-stage measurement over a
recorded playthrough (F10) reaching stage 2.

**Known hard limits** (dynamic evidence forever): pointer *values* in data;
WMDATA-port traffic (real WRAM always — GIII has exactly one port site);
per-site evidence that is genuinely mixed (same instruction, both worlds);
emulation-mode S pinning to page 1; and the coverage boundary itself.

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
