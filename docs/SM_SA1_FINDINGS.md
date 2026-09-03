# Super Metroid SA-1 Conversion — Findings

Campaign log for converting Super Metroid (3 MiB LoROM) with the v17 window
architecture (`--gen-sa1-patch --window --wg-static`). Every finding below was
measured on the real game; commits are on `claude/sa1-async-offload`.

Status: the conversion boots, plays, and verifies BEHAVIORALLY EQUIVALENT on
its scripted surfaces (attract, title-skip, play-death) plus a power-on Ceres
escape evidence surface. The current build is **v40** (`tests/surfaces/sm-sa1/
sm-sa1-v40.bps`): the room-graph level-pointer net, the background-record net,
the decompressor inline-destination net, the Zebes foreground via cover
pairs, and the escape palette via an `--evidence-movie`. Ceres (including the
escape) and Crateria from the landing site through the Parlor to the first
new-tileset room render correctly. The open frontier is every room-type not
yet visited — its data pointers net structurally as they are found, its
uncovered code wants one comprehensive playthrough as coverage (§0.5, §0.10).
Work is on `claude/sa1gen-attract-nets` (PR #117); older fixes referenced by
commit below were on `claude/sa1-async-offload`.

---

## 0. Synthesis — everything learned about converting Super Metroid to SA-1

This section is the distilled, transferable picture: what makes the
conversion hard, the one architecture that works, the complete taxonomy of
what breaks and why, the two fix mechanisms and the line that divides them,
and the process that found it all. The sections after it are the chronological
evidence; this is the map. If you read only one section, read this one.

### 0.1 The target

Super Metroid is a 3 MiB LoROM with a battery save, heavy interrupt-time work
(room loads decompress inline for ~80 frames; the music engine streams across
many frames; the NMI does per-frame slot maintenance), and bank-in-data idioms
throughout (pointer tables with dual-role bytes, `PEA $xx00/PLB/PLB` bank
pins, `LDA table/XBA/PHA/PLB/PLB` dispatches, JSL calls with inline parameter
blocks, a decompressor whose source bank arrives via a WRAM-staged copy of a
ROM record). Any divergence stalls quietly rather than crashing, so bugs
present as freezes and black/garbage screens, never as clean error states.

### 0.2 The one architecture that works: window relocation (v17)

Whole-game migration — running the game's code ON the SA-1 — was tried and
does not fit Super Metroid. The architecture that works keeps the game
running on the **S-CPU** and uses the SA-1 cart purely for its RAM:

- A boot shim (at `$00:fc8f` on this build) installs the SA-1 map mode, then
  the game keeps executing on the S-CPU exactly as stock.
- The game's low 8 KiB of WRAM is moved wholesale into the S-CPU's BW-RAM
  window at `$6000-$7FFF`, every relative distance preserved so indexed
  bases rewrite soundly. `$7E/$7F` long references re-bank to `$40/$41`,
  where linear BW-RAM carries the whole 64 KiB.
- MMIO stays native. The SA-1 never leaves reset — the cart is *carried* for
  its RAM. This is what makes resident offloads over the whole working set
  possible in principle, though on Super Metroid greedy finds no offload
  trees worth taking, so the shipped conversion is the relocation alone.

The measured effect: dropped frames go from stock's ~2,342 to ~2,416 over a
36,000-frame profile (about +3%), utilisation 41% -> 43%. Window mode is not
itself a speedup; it is the *enabler* for offloads, and its own overhead is
the thunk-dispatch toll. (An early build showed `2342 -> 28969` — that was
NOT window overhead; it was unfixed mirror-JSL sites trapping the CPU. When a
timing number looks catastrophic, suspect a correctness bug, not the
architecture.)

### 0.3 The heart of it: the de-mirror (bank-translation) map

On a padded <= 2 MiB game the Super MMC's power-on map folds `$80-$FF` onto
the image quarters as a genuine mirror (which is why Gradius III never hit any
of this). On a 3 MiB image that fold is *real, different data*. The shim
programs region 2 := MB0 and region 3 := MB2, giving the map that governs
every bug below:

| stock bank | content | converted bank | rule |
|---|---|---|---|
| `$80-$9F` | MB0 | `$80-$9F` | native (region 2 restores the mirror) |
| `$A0-$BF` | MB1 | `$20-$3F` | `-$80` |
| `$C0-$DF` | MB2 | `$A0-$BF` | `-$20` |
| `$40-$5F` | MB2 | `$A0-$BF` | `+$60` |
| `$7E/$7F` | WRAM | `$40/$41` | into linear BW-RAM |

**Every carrier of a bank must ride this map.** Operands, immediates, thunk
bodies, and — the hard part — *data*: pointer table bank bytes, DMA source
banks, decompressor source banks, level/tileset/background pointers. Nearly
every bug in this document is one place a carrier was missed.

### 0.4 The failure taxonomy

Every failure reduces to a bank carrier that did not ride the map. Grouped by
how the carrier reaches the CPU:

1. **Static operands** — `LDA $C0:xxxx` and friends. Rewritten by the main
   relocation walk. The subtle ones: `long,X` wraps (`X >= $10000-v`),
   tiny-base indexed absolutes needing a thunk (no single operand serves both
   a data base and a ROM walk), and pin contradictions.
2. **Immediates staged as banks** — `PEA $xx00/PLB/PLB`, `LDA #imm/PHA/PLB`,
   and the XBA-carried variant where the bank rides the *low* half of a
   16-bit load. These need provenance tracking through the staging (the
   `a_lo_src`/`a_hi_src` machinery); XBA breaks a naive chain.
3. **Queue-bank immediates** — an `LDA #imm16` staged into a dispatch queue's
   bank column and PLB'd by later code. Rewritten BY SIGNATURE: the
   `XBA/PHA/PLB/PLB` consumer names the column, no coverage required.
4. **Mirror JSLs at uncovered sites** — `JSL $A0-$BF:addr` byte-identical to
   stock, landing in MB2 under the shim and BRK'ing. Closed by the
   **twin-JSL net**: in the converted image the same target is already called
   as `JSL $20-$3F` by covered code (the de-mirror pass mints the twin), so a
   mirror JSL whose de-mirrored twin is called twice or more is re-banked
   `-$80` with no coverage. 505 sites in one build.
5. **Value provenance** — bytes a profiled run PROVED feed addressing state
   the operand rewriters cannot reach: `[dp]` pointer bank bytes, DMA A-bus
   bank registers carrying `$7E/$7F`, dp,X pointer table words, HDMA indirect
   addresses. Re-banked from the profile's evidence.
6. **HDMA indirect banks** — the `$43x7` DASB carrying `$7E/$7F`, wrapped in a
   runtime rebank thunk that maps `$7E/$7F -> $40/$41` as the write happens,
   so an indirect HDMA whose source is WRAM follows its data into BW-RAM.
7. **Room data pointers (the deepest and most numerous)** — the level-data
   pointer, tileset records, and background (library) records each name MB2
   banks a room needs. Closed by **structural nets** (§0.6). This is the
   class that made most of the game unplayable and was invisible until the
   rooms became reachable.

### 0.5 The dividing line: coverage fixes code, nets fix data

The single most useful principle the campaign produced. A bug is fixed by one
of two mechanisms, and which one is decided by whether the un-relocated
carrier is **code or data**:

- **Uncovered CODE** (a mirror JSL, a room-load routine, a handler no surface
  reached) is fixed by **coverage**. Relocation follows execution: give the
  generator a surface or a cover pair that runs the code, and it walks and
  rewrites it. The Zebes foreground was this — a playthrough's coverage let
  the generator relocate the room-load path (new thunks in bank `$81`).
- **Uncovered DATA** (a bank byte a pointer table or DMA record *carries*) is
  fixed only by a **structural net that knows the layout**, because no
  execution moves a byte the code merely reads. The level pointers, the
  tileset banks, and the background records are all data. v37 proved the
  point: with the Parlor fully covered, it verified but left the BG record's
  banks raw — coverage cannot reach a byte the DMA reads as data.

**And the durability corollary:** a net survives a lost recording; coverage
does not. A structural fix is permanent and needs no artifacts; a
coverage-driven fix evaporates if its recording is lost (measured: the escape
flag regressed across a cleared scratchpad because it had only ever been
closed by a recording, while the twin-JSL class stayed fixed because the
generator closed it). Prefer a net wherever the class is structural.

### 0.6 The structural pointer-family nets

Super Metroid's room data is reachable by an exact, finite graph, which is
what makes structural nets possible. The pattern, once, so the next family is
mechanical:

- **The room graph.** Door headers (`$83`) name rooms (`$8F`); a room's
  condition list names its states; each state is a fixed header. The walk
  starts at TWO roots — the landing site (`$91F8`) for Zebes and `$DF45` for
  Ceres, because no door crosses between them (Ceres is entered by the
  new-game warp and left by the escape warp). It follows doors, skipping any
  that name no room (elevators, `$0000`). Reaches 261 rooms / 322 states.
- **Level pointer** (state `+$0`): 3 bytes naming MB2; translate the bank
  `$C2-$CE -> $A2-$AE`. All-or-nothing: validate every state (pointer in
  MB2's ROM half, tileset index in range) before writing a byte, refuse the
  whole pass on the first anomaly, because a misparse rewrites data.
- **Background record** (state `+$16`): a DMA list. Command widths, read off
  SM's own interpreter and validated against every reachable record:
  `$0002` src+dest+size = 7, `$0004` src+dest = 5, `$0008` = 7, `$000A`/
  `$000C` = 2, `$000E` = 9, `$0000` ends. `$0002/$0004/$0008/$000E` carry a
  3-byte source; its bank (payload byte 2) is de-mirrored. PER-RECORD
  graceful, not all-or-nothing: a state's `+$16` legitimately points at code
  or nothing, so a record that stops parsing as a list is skipped.
- **Decompressor inline destination** (`JSL $80:B0FF` + 3 bytes): the
  decompressor reads its destination long pointer from the code stream right
  after the JSL (it pulls the return address, reads through it, advances by
  3). The pointer is data in the middle of code, so relocation-by-execution
  walks straight past it. Signature net: the four JSL bytes then an inline
  bank of `$7E/$7F`, re-banked to `$40/$41`; any other bank is skipped. 63
  sites in stock; v38 had 29 raw, among them the load-game tileset loader's
  tile-table loads, which is why the first new-tileset room past the Parlor
  painted the previous tileset's blocks (§4h).

**The gate on every SM-specific net:** the ROM title starts with
`Super Metroid` and the image is a > 2 MiB window conversion. Reads STOCK
bytes; leaves any byte value-provenance already re-banked alone, so the
structural and evidence passes compose.

**Two rules learned expensively here.** (a) Read the structure from the
game's own code, never guess command widths — a tileset-table net built on
guessed lengths translated the wrong bytes and changed nothing; the working
BG net was built only after validating widths against all 67 records. (b)
Stage translations and commit only on a clean parse, so a mid-parse failure
never writes a byte.

### 0.7 Verification: the behavioral tier

A slowdown-removing conversion CANNOT be frame-identical to a slowed-down
baseline — different lag means different pictures, and the pixel gate rightly
calls that divergent. What lag cannot legitimately change is the game's LOGIC
state at each logic tick. So the behavioral tier (`--verify-behavioral`) runs
both images tick-locked (a tick = the frame's first controller poll, the one
phase-aligned instant two runs with different lag share) and compares the
bytes the baseline's NEXT tick actually consumes, each read from wherever the
conversion relocated it, excluding a lag-learned wall-coupled mask.

Load-bearing details:
- **Tick-locking, not frame-locking.** Inputs applied by wall-frame index
  would land on different logic ticks and desync; the tier realigns per input
  EPOCH so the same *game* drives both images.
- **The persistence verdict.** Wall-derived values (pass counters, timers)
  leak one hop past the mask; the verdict keys on persistence — echoes
  self-heal within ticks over a bounded set, corruption persists, spreads, or
  floods. A held constant offset (state carried across an input edge from
  wall-time origins) is excused; nothing else.
- **RNG-fork episodes.** A timing-changed conversion forks the game at each
  RNG-sensitive moment; an episode that HEALS was reconverged by a scene
  reset (corruption never reconverges to byte-equivalence). A few bounded,
  healed episodes are excused.

**The scene that cannot verify: the Ceres escape.** Its explosion/debris/
enemy chaos is RNG- and timer-driven and forks under lag — the same signature
the tier excuses on the attract surface — but it runs to the movie's end with
no mid-scene reset, so the fork never heals and the verdict fails it. This is
not a defect; it is a scene that is unverifiable by construction.

### 0.8 `--movie` vs `--evidence-movie`: profile without verifying

The escape must be PROFILED (to prove its palette-decompress banks) but cannot
be VERIFIED. The resolution is `--evidence-movie`, not a change to the tier: a
movie flagged evidence-only feeds the shared coverage/evidence/provenance
union that proves the banks, but `movie_verify[s]` skips its behavioral tier.
So a scene the tier cannot tick-lock still contributes its coverage. This is
why the escape renders correctly AND the conversion verifies — and why the
correctness gate that every other game depends on was left untouched.

### 0.9 The surface-and-recording discipline

A conversion is a function of three inputs — the stock ROM, the generator, and
**the surfaces**. The first two are durable; the surfaces must be made so.

- **Scripted surfaces are code.** `tools/sm_surfaces.py` re-emits the three
  deterministic ones (attract 36k, title-skip, play-death) bit-for-bit and
  replays each to embed its end hashes, so a later replay prints "sync
  verified". Kept in `tests/surfaces/sm-sa1/scripted/`.
- **Player recordings are irreplaceable.** Each exists because it walked a
  path no script had. They bind by CRC (offset `0x08`) to the image they were
  recorded on; a recording without its image is inert. Kept in `recordings/`,
  their images (patched commercial ROMs, so untracked) in `generated/`.
- **The recorder.** `--record` in the SDL player opens a take BEFORE the first
  frame (F10 alone cannot promise frame 0 — the "power-on" label keys on a
  state load, not on frames run), starts with blank battery SRAM (headless
  loads none, so a take made against a save file could never replay), and
  saves on exit. A stock power-on take is the only recording that verifies on
  any image, CRC-independent.
- **Harvesting rule.** A HUNG run is safe to harvest as a cover pair; a
  CRASHED run poisons coverage (the harvest mis-credits the crash's garbage
  execution to the wrong file bytes on a > 2 MiB shim map). Prefer a net over
  a recording for any structural class.

### 0.10 The process lessons

- **Hand-patch to prove a root cause before writing a net.** Three bytes in a
  copy of the image settled the background cause before a single generation.
  The cheapest proof there is.
- **Compare trajectory when every link checks out.** A halt where every code
  path is correct on correctly-relocated data is a *stalled state machine* or
  a *timing/RNG fork*, not a room-load bug. The discriminators: advance a save
  state ~900 frames and diff (48 bytes moving means stalled); and compare
  where the player IS on both images (a position stock never occupies at that
  X points upstream). Both cracked cases three probes had failed to.
- **A confident wrong theory costs the most.** Two of this campaign's longest
  dead-ends (the §4f "decor is wrong" misdiagnosis, the tileset-table net)
  were confident theories pursued without a discriminating measurement first.
  When every link checks out, get evidence, do not generate.
- **"Money-check" discipline.** Verify the fix touched the thing you think it
  did — diff the image, confirm the byte, render the frame — before believing
  a green verdict. A verified conversion can still render a room black if the
  bug is in a surface the tier never exercised.
- **The chain is finite but reaches as far as you play.** Making the game
  reachable exposes per-room pointer families no surface had hit. Each is
  real; the mechanism for closing it (net if data, coverage if code) is now
  known. The open frontier is every room-type still unvisited.

---

## 1. Why Super Metroid is a hard target

- **3 MiB image**: the Super MMC's power-on flat map folds `$80-$FF` onto the
  image quarters. For a padded ≤ 2 MiB game that fold is a genuine mirror
  (why Gradius III never hit any of this); for 3 MiB it is *real, different
  data*. The shim programs region 2 := MB0 and region 3 := MB2, so:
  - operands `$A0-$BF` (mirror-of-MB1 intent) must be rewritten `−$80`,
  - operands `$C0-$DF` and `$40-$5F` (both MB2) must become `$A0-$BF`
    (`−$20` / `+$60`),
  - `$80-$9F` stays native (region 2 restores that mirror).
  Anything that *names a bank* — operands, immediates, thunk bodies, data
  values — must ride this map. Most of the bugs below are places one of those
  carriers was missed.
- **Bank-in-data idioms everywhere**: pointer tables with overlapping
  dual-role bytes, `PEA $xx00/PLB/PLB` bank pins, `LDA table/XBA/PHA/PLB/PLB`
  dispatches, handler chains threaded through WRAM cells, JSL calls with
  inline parameter blocks, and a decompressor whose source bank arrives via
  `LDA dp/PHA/PLB` from a WRAM-staged copy of a ROM record.
- **Heavy interrupt-time work**: room loads decompress inline for ~80 frames;
  the music engine uploads across many frames; the NMI does per-frame slot
  maintenance. Any divergence stalls quietly rather than crashing.

## 2. Generator bugs found and fixed (committed)

| Commit | Fix | Measured failure it closed |
|---|---|---|
| `4577111` | **FarPad clamps to identity banks** (≤ `$3F`) on > 2 MiB images | Far thunk pool started at file bank `$5F`; `placeThunk` addressed bodies by file bank, the CPU fetched DXB fade tables instead, EOR-marched to a `$00` and BRK'd into SM's crash trap (`$80:8573`) at f5196 |
| `9f7e475` | **`long,X` wrap arm** (`longThunkBodyWrap`, 34 B) + pin-contradiction split | Tiny-base guard `CPX #($2000−v)` missed `X ≥ $10000−v`: `LDA $A0:003E,X` with `X=$FFCF` wraps to `$A1:000D` (mirror WRAM) and the ROM arm read it stale. `v == 0` is excluded — `$10000−0` truncates to `CPX #$0000`, which sent *every* large index down the low arm (82 diverging ticks, learned the hard way) |
| `10442ad` | **Cell coherence excludes bank-mediated sites** | `$01:811D STA $078B` runs under a `$7E`-pulled DBR; cell-move shifted it to `$678B`, which under `db=$40` is a *different byte* — the projectile slot-list words were zeroed every sweep and a door transition indexed its room table with the stale default |
| `213bb3a` | **Thunk-body banks ride the de-mirror map** | Bodies carried the site's stock bank verbatim; on the shim map `$B4` is MB2, so the music loader's terminator probe read far-pool bytes `$1231` instead of ROM's `$FFFF` and walked a phantom chunk into mirror WRAM |
| `f9fcb7e` | **DBR immediates de-mirror** (`PEA $xx00+PLB`, `LDA`-imm `PHA/PLB(/PLB)`) | The sound library pins `db=$A0` via `PEA $A000/PLB/PLB` and reads every header through it as plain absolutes — all walked MB2. The sample-queue builder read a header field as `$2700` instead of MB1's `$BA00` and queued seven phantom records banked `$C2`; the upload never terminated |
| `15f77a3` | **XBA-aware provenance** (`a_lo_src`/`a_hi_src` staging, console.zig) | The sound dispatch `LDA table,Y / XBA / PHA / PLB / PLB` carries the handler bank in the *low* half of a 16-bit load; XBA killed the chain, `$A6` entered PBR unproven, MB2 *code* was fetched, BRK → crash trap. With the fix the byte proves and folds to `$26` — this landed the first full two-surface verification |
| `22fd4a2` | **Pointer-literal descent** in `extendCoverage` | The static walk stops at `JMP (cell)`, but the pointers are stored as immediates: `LDA #$E737 / STA $099C`. Fixpoint: a low-WRAM cell *activates* when a covered 16-bit literal store names it **and** a raw `JMP (cell)` exists (two-sided conjunction gates false positives); active cells accept raw-store expansion so chain links only the chain itself reaches seed transitively; dispatchers of active cells are marked as instruction starts directly and **uncapped** (a 64-slot list died on coincidental `$6C` bytes in bank `$01` — three failed generations) |

### `38f0d7d` — 16-bit copy provenance (console.zig)

**16-bit WRAM→WRAM copies drop `src_any`.** The w==2 WRAM-load path stages
only `prev_load_hi_src` plus the `a_lo/a_hi` halves — `prev_load_end` stays
`none` — so the store arm's `attributed` check fails and the provenance chain
dies at every 16-bit copy hop. Measured: the room-header parser copies the
tileset pointer `$C2:C104` through `$07C6-$C8` into dp `$47-$49` with exactly
this shape; the decompressor's `PLB $49` then had nothing to prove, the
palette source stayed a folded `$C2`, the palette decompressed to nothing, and
the new-game room faded in black (full brightness, loaded VRAM, zero BG
palette — faint sprites only). Fix: the store staging falls back to
`a_hi_src`/`a_lo_src` per half when unattributed.

## 3. Coverage holes and the surface method

The behavioral gate's caveat — *"uncovered code touches moved state"* — was
the live failure mode twice:

1. **Intro-skip freeze** (player report #1): mashing buttons during the intro
   runs the skip handler at `$82:EE7F` (`PHK/PLB`), which writes the game-state
   variable `$0998` (and `$0723/25/27`, `$0DE2`) to the abandoned home. No
   recorded surface pressed buttons there. Fixed by a **mash evidence movie**
   (`--evidence-movie mash-st.ymv`, Start+A+B bursts every 20 frames).
2. **Cutscene-end freeze** (player report #2): the variant handler at
   `$94:98E2` writes the mainloop state words (`$0A6C`) stale. The player's own
   **anchored recording became the cure**: `--cover-image <their build>
   --cover-movie <their .ymv>` harvested 1,210 newly covered instructions and
   473 newly evidenced sites from the conversion-side replay. An identical
   twin handler 7 bytes later is still uncovered (different cutscene variant).

Standing practice adopted: every conversion should carry a menu-mash evidence
movie, and player recordings (anchored, end-hashed) are first-class fix
inputs. Movies and cover images bind per-build (CRC at offset `0x08`); keep
each generation's cover image — a lost one can be rebuilt deterministically by
re-running its exact flag set.

## 4. The new-game black-room investigation (chronicle)

The longest chase; each layer was real but not the cause:

1. Reproduced without any anchored movie: scripted Start+A bursts
   (`newg2-*.ymv`) — stock reaches gameplay by f8600, conv fades at f8400 with
   everyone and never comes back. Luminance-identical through f8000.
2. `$0998` state timelines are **identical** on both sides
   (`00→01→04→02→1E→1F→07→08`) — the machine *enters gameplay*; the room is
   just black. State 1F lasts 191 wall-frames on stock vs 135 on conv (the
   script counts logic frames; lag removal is working as designed).
3. PPU dump at the freeze: `force_blank=false`, `brightness=15`, VRAM and
   tilemaps loaded, `TM=$13` — but the palette staging buffer `$7E:C000` has a
   zeroed BG half (172/512 nonzero = sprite palettes only → the faint-sprite
   black).
4. The palette copy loop (`$82:8115`, `$C200→$C000`) runs in **lockstep**
   with stock (13,458 instructions sequence-aligned from each side's own
   state-07 entry; only 1-instruction IRQ skews) — it faithfully copies a
   buffer whose BG half was already zero.
5. The `$C200` filler is the decompressor's store (`$80:B193`); a full-run
   watch shows stock's single fill vs conv's **boot-clear only** — the
   tileset-palette decompression never runs on conv.
6. The `$099C` handler-chain detour (see descent, above): real split, fully
   repaired, byte-proven — and then **exonerated**: stock's palette decomp
   runs ~100 frames before that link fires.
7. The true caller is the `$02:E790` loader block (stack frames: JSR ret
   `$00:848F` inside the decompressor, JSL ret `$82:E7BE` = right after
   `JSL $80:B0FF : dw $C200,$40`). Both sides enter it in lockstep at
   `$E7A8`; the first inline decompression (tile gfx) runs ~80 frames — and
   on conv it runs with a **proven `db=$39`** source (the immediates family
   working). The *palette* call's source arrives via WRAM copies instead, and
   its `$C2` never proves — the rev6 gap.

## 4a. The Ceres escape display garble — FIXED (two HDMA legs)

The escape room rendered as a full-screen garbage tile-sheet. **Now fixed.** It
took TWO complementary generator fixes, because the escape drives the picture
through TWO indirect HDMA channels, each fetching per-scanline data from a
relocated WRAM buffer the DMA unit could not follow:

1. **hdma3 — `$2105` per-scanline data, from LOW WRAM `$07EB` — the tile-sheet.**
   The dominant bug. Disabling either channel proved it: the escape room draws
   correctly ONLY when hdma3 delivers its per-scanline values, and on stock it
   reads them from WRAM `$07EB`. On the conversion that buffer moved to the
   window (`$67EB`), but the address lived in the channel's ROM HDMA table,
   loaded by the DMA unit — reachable by no operand rewrite — so hdma3 read the
   abandoned physical mirror `$00:07EB` (all zeros) and the room became noise.
   Fixed by relocating the table's low-WRAM indirect addresses `+$6000`
   (`relocateHdmaIndirect`, below).
2. **hdma2 — `$2132` COLDATA gradient, from UPPER WRAM `$3522`, bank `$7E` — the
   colour.** A real but secondary bug: the alarm's colour-math gradient sits at
   `$7E:3522` on stock, `$40:3522` on the conversion, and the HDMA's DASB
   register named `$7E`. Fixed by the `$43x7` DASB rebank thunk (below).

Both were proven, and the fix verified, by a **same-moment stock comparison**:
conv and stock at `sm-game` frame 15000 are the IDENTICAL game moment (same room
`$079B=45DF`, Samus `$0AF6/0AFA=2D00/7B01`, clk within 4 ticks, relocated WRAM 39
bytes apart), so a side-by-side is apples-to-apples. Before the fix everything
the renderer consumes was byte-identical to stock — BG char+maps, CGRAM, scroll,
BGMODE, TM/TS, OAM — EXCEPT the VRAM regions the bad HDMAs drive; after, the
conversion renders the escape pixel-identical to stock (bar one blinking HUD
digit off by the lag skew). `--verify-behavioral` is blind to all of this — the
behavioral tier compares WRAM/logic, never VRAM — which is why the conversion
"passed" for the whole campaign while the picture was wrong. Wrong theories that
cost time and are recorded so they are not retried: a "VRAM tile-upload DMA with
a mis-rebanked source" (the tiles at word `0x6D00` are OBJ data, a red herring),
and a `$9D00`/builder-coverage split (the builder was always correct).

### The hdma3 fix — relocate low-WRAM indirect-HDMA addresses

An indirect HDMA's table is a run of `[line-count][addr-lo][addr-hi]` entries;
`$07EB` is one such indirect address, naming a WRAM buffer the game rebuilds each
frame. No operand rewrite reaches it — it is HDMA-table data the DMA unit loads,
not a CPU operand. So: the DMA-arm hook records every indirect-HDMA table address
into the SHARED provenance (`PtrBankEvidence.hdma_tables`) — shared, not the
per-surface profiler, because the escape lives on a late profiling surface — and
`convertWholeGame` walks each table and shifts any indirect address naming the
moved low 8 KiB (`< $2000`) by `+$6000` into the window. Sound by construction:
an address `< $2000` in an HDMA table is always low WRAM, and `+$6000` lands
exactly in the 8 KiB window. `loromFileOffset` maps the runtime table address to
its file home (plain LoROM, or the >2 MiB de-mirror MB layout). Verified: the
full conversion reports `2 low-WRAM indirect address(es) relocated`, still
verifies BEHAVIORALLY EQUIVALENT (dropped frames 25→25), and the room renders.

### The hdma2 fix — the `$43x7` DASB rebank thunk

- **It was display-only, proven.** A tick-locked `--verify-behavioral` over
  the escape returns BEHAVIORALLY EQUIVALENT — the game's WRAM/logic state
  matches. The behavioral tier never compares VRAM/CGRAM/framebuffer, so a
  display effect can diverge while logic passes. The escape always played
  correctly; only its picture was wrong.
- **Frame-locked stock comparison is invalid here.** The conversion removes
  lag, so at the same movie-frame number it has advanced further than stock —
  different game moments. Comparing VRAM/CGRAM at equal frame numbers showed
  them "identical yet rendering differently," the confound, not a paradox.

**The real mechanism (measured, not the first guess).** The alarm is an
indirect HDMA on `$2132` (COLDATA) whose per-scanline gradient it fetches from
the bank named in the channel's DASB register (`$4327`). On stock that bank is
`$7E` (WRAM); the escape's builder writes the gradient into WRAM and the HDMA
reads it back. `--dump-ppu` on the conversion showed exactly one bad channel:

```
hdma2: control=0x40 b_addr=0x32 indirect_bank=7e indirect_addr=3522  <-- ABANDONED
```

The gradient buffer is at `$3522`, **not** `$9D00`, and the builder was NOT the
problem: a `--watch 3520-3528` over the escape showed every gradient write
landing at `$40:3520-3528` — the LIVE BW-RAM home, from covered code. The
builder is correct. The *only* stale leg is the DASB byte: the HDMA reads
`$7E:3522` (abandoned) while the builder fills `$40:3522` (live). (The earlier
`$9D00`/`$08:DEA8`-builder-coverage theory was wrong — it never reproduced,
because the builder was never the split.)

Why the byte escapes every static rebanker: the DASB writer is the HDMA-object
processor at `$08:867A` — `LDA $0000,Y : STA $4307,X` — which loads the bank
from a **ROM HDMA-object table** (`$88:DED8`, value `$7E`) and stores it to the
register. The value flows through `A` as data; the immediate arm only rewrites
`LDA #$7E` literals, and the long arm only rewrites a `$7E` bank *operand*.
Neither can touch a byte the code fetches at run time. Binary-patching the
object byte or the writer did not converge — a single leg, and fragile.

**The fix — a runtime rebank thunk on the register write** (`rebankDasbWrites`
+ `dasbThunkBody` in `sa1gen.zig`). Every covered `STA $43x7` (DASB; abs or
`abs,X/,Y` — column 7 is DASB on every channel) is wrapped in a `JSR` thunk
that, on the way to the store, maps an 8-bit `A` of `$7E/$7F` to `$40/$41` and
leaves any other bank untouched. The JSR is the store's own 3-byte footprint;
the thunk restores the caller's exact `A` and flags, so a store inside a
CMP/branch pair behaves in situ. It is sound on *every* DASB write whatever the
value's origin: any DASB that named `$7E/$7F` on stock must name `$40/$41` on a
conversion whose WRAM moved to BW-RAM. This sidesteps the object table, the
writer's dataflow, and coverage entirely — it fixes the value at the hardware
boundary. Verified: the same `sm-game` movie now shows `hdma2 indirect_bank=40`
on the conversion, the writer routes through the thunk (`pc=88:a220`), the
stripes become the real gradient, and `--verify-behavioral` still returns
BEHAVIORALLY EQUIVALENT (`1 DASB write wrapped`, dropped frames 25→25).

Diagnostics kept from the chase: `--dump-ppu` prints color-math, window/mosaic,
per-HDMA-channel indirect banks, and a CGRAM digest; the DMA-bank write trap
(`--dma-bank-pc`) covers `$43x7`; and `--movie-ignore-crc` replays a recording
made on a previous conversion against a freshly regenerated one (window mode
preserves S-CPU timing, so power-on movies stay in sync — a save-state-anchored
movie still cannot cross builds).

### 4b. Epilogue — theresidual speckle was the BASE EMULATOR (VRAM read latch)

After both HDMA fixes the escape rendered structurally right but the Ceres
rooms still looked "busier" than bsnes (user screenshot comparison, raw, no
shader). That residual was NOT the conversion — stock and SA-1 rendered it
pixel-identically — and the hunt ended in the core: yamabuki's VRAM read
ports reloaded the prefetch latch on EVERY read, where hardware reloads (and
steps VMADD) only on the port VMAIN designates, and prefetches on $2116/17
writes. A 16-bit `LDA $2139` under VMAIN=$80 thus paired word W's low byte
with word W+1's HIGH byte — and Super Metroid's decompress-to-VRAM
back-references ($80:B3C8) are the one consumer, speckling the Ceres tile
sheet (the game's only decompress-to-VRAM scene) while everything
WRAM-decompressed stayed pixel-perfect. Fixed in `866e6d0`; the Ceres arrival
room now matches a raw bsnes capture. Method notes: the mode-7 discovery
(the room's BGMODE HDMA runs 31 lines mode 9 + 112 lines mode 7; the
end-of-frame `bg_mode=1` dump is the vblank restore, a trap), the trace-dedup
hiding re-uploads (fixed in `c5f33c8`), and `--watch` being blind to banks
$7F/$41 (an open instrument gap) are recorded in the memory.

### 4c. The invisible beam and the confetti door (player report #5)

One recording ("I try to fire the gun but it doesn't work, and the door on the
right is garbled") unwound into FOUR stacked generator defects - each masking
the next, each found by refusing intermediate signals and verifying against
the rendered game:

1. **A dual-role table word value-proved.** The escape's sprite-tile builder
   pins DBR via `LDA $abs,X / PHA / PLB / PLB`; the eager PLB-time prove had
   no arm for that idiom and re-banked the word's ADDRESS half -$80 (ROM
   `$20:E276`, `$BA -> $3A`), so the builder read zeros and the beam/door
   sprites went blank. The gun always fired - layer isolation showed the
   projectile in flight; only its tiles were empty.
2. **No translate-in shape for the idiom** - added (6-byte site, SEP/REP
   bracket around the 8-bit map, returns past the orphaned PLB pair).
3. **The shared map_body mangled banks below $A0** (BCC one arm short) -
   latent since Gradius, exposed the first time the map ran on a loop
   pulling ordinary banks.
4. **xl JML banks assumed the stock mirror** (`|$80`): on a 3 MiB image
   that is MB2, and the first bank-$20 xl bodies jumped into the wrong
   megabyte - two failed regenerations whose freeze (jam at a mid-body
   address, alien D/DBR) was decoded from the un-pulled stack frames.

Proof chain: builder buffer byte-identical to stock (0/4096; broken build
1132 wrong), muzzle flash renders (beam-motion 29 -> 140, stock 195),
residual VRAM delta uniform across the 16 door-flash animation slots (phase,
not corruption), BEHAVIORALLY EQUIVALENT with the player's recording
harvested. Method note: a save-state-anchored recording restores the OLD
build's VRAM - it can prove a bug but never a fix; power-on surfaces prove
fixes.

### 4d. The door: a freeze and a confetti column (player report #6)

The first playthrough ever to WALK THROUGH the Ceres door ("bullets are now
fired, door still garbled, game freezes when going through the door") surfaced
four more defects - the door path had never been covered by any surface:

1. **The freeze: an uncovered JSL chain.** The door transition at `$82:E1CA`
   is three literal `JSL $A0:xxxx` calls; none were covered, so none were
   de-mirrored, and the first jumped into MB2 garbage - straight to SM's
   crash trap (decoded from the frozen machine's un-pulled stack frames).
   Harvesting the crash recording fixed call #1 only: the recording died
   inside the callee, so the frontier froze one call further each time.
2. **The walker guard froze the coverage frontier.** The inline-params rule
   (stop a covered JSL's fall-through when the return is uncovered) is
   correct for calls that skip parameter blocks - the profile marks the
   real return a few bytes on - but it also stopped at calls the profiled
   run DIED inside. The guard now discriminates by dynamic coverage within
   32 bytes after the call: present = params (stop); dead = never returned
   (fall through). One regeneration then de-mirrored all three JSLs.
3. **The uncapped dispatcher scan was planting rewrites in data,
   image-wide.** The pointer-literal descent's raw scans match any
   `$6C/$7C/$FC/$DC` byte naming an active low-WRAM cell. Three megabytes
   of data supply those coincidences by the thousand: the census found
   **3,526 planted bytes** in the data half alone - each a fake dispatcher
   whose "operand" the window shift then rewrote (+$60 on the high byte).
   The uncap in `22fd4a2` unleashed this: the old 64-slot list was
   accidental protection. One plant sat in the door's own tile stream
   (`FC FC 0A` read as `JSR ($0AFC,X)`, `$0A -> $6A` at file `0x1C8D09`)
   and the decompressor's back-references would have cascaded it; the
   other plants garble tilesets of rooms the profiled surfaces never
   visit. Two-layer fix: bytes the profile READ without executing are
   never dispatcher candidates, and the raw scans run only in banks
   containing at least one dynamically-executed opcode - dispatchers are
   code, and real ones (the cutscene chain at `$02:E16F/$02:E28F`) live
   amid covered code; pure data banks supply only coincidences. Real,
   necessary - and NOT the confetti's cause: with every plant reverted
   the door band was still garbage. The money check exposed it.
4. **The confetti itself: an unproven bank staged through a 16-bit
   `STA $4313`.** The door tile-sheet upload is a DMA from `$B0:C400`.
   SM arms it from its DMA job queue: three overlapping 16-bit stores
   (`$4312`, then `$4313` = A1T-hi low half + A1B high half), each fed by
   `LDA $00D3,Y` from the low-WRAM queue cell - the bank byte never
   touches an 8-bit store or a direct ROM load, so no existing provenance
   family saw it. Unproven, `$B0` kept mirror-intent semantics and the
   conversion's DMA read the MB2 home (file `0x284400` - note the MB2
   file math is `0x200000 + (bank-0xA0)*0x8000 + off`, an early slip
   used `0x204400` and hid the match) instead of the MB1 identity home
   (`0x184400`) that stock reads. Band after the arming DMA: 24/1024
   bytes correct, every conversion since the beginning. The fix is a new
   provenance arm for 16-bit `$43x3`-family stores with mdr in
   `$A0-$DF`: prefer a direct ROM load's end, else the queue cell's high
   byte resolved through the `src_any` copy-chain (the resolution that
   survives RAM staging - the strict chain is already broken there),
   guarded by `peek8(src) == mdr`, misses logged as unresolved sites.
   One new proof (`$26:F74C`, the room record's bank byte), zero
   unresolved, and the band went **1024/1024**. A belt-and-braces
   runtime thunk (`$43x4` column, full misfit map, >2MiB images) now
   also rides `rebankDasbWrites` for 8-bit A1B stores the static proof
   may miss.

Diagnostic path worth keeping: paired port-write value streams with offset
alignment found a seed write; a clock bisect over paired short captures
bracketed it to one frame; the decompressor's dp `$47` pointer at that
moment named the stream's ROM home; a windowed diff found the byte - and a
whole-image census then revealed the byte was one of thousands. Fixing the
mechanism STILL left the band broken, which only a standing money check
caught: define the one decisive comparison up front (band bytes vs their
stock file home, the frame after the arming DMA) and re-run it after every
candidate fix. Two mechanisms can share one symptom; the census closes the
first, the money check refuses to let you stop there. Traps recorded:
aligned value tails can match while the machines sit at different stream
positions (the X register differed by $15 - compare state, not just
values); anchored recordings replay the OLD build's VRAM (they prove bugs,
never fixes); an anchored movie's clock starts at the anchor's saved
value, so frame-times computed as N x 357366 miss trace windows entirely;
and when a band matches NEITHER candidate home, re-derive the file math
before inventing a third mechanism.

**Known residual (open):** the HUD minimap's current-room cell. Stock
blinks it on an ~8-frame cadence (two tile patterns); v8 shows a third,
static pattern. The entire 64 KiB settled OBJ/map page differs from
stock in exactly 4 bytes - the cell's two tilemap words at `$7F:B078`
and `$7F:B0B8` - and the f14999 frames are otherwise pixel-identical.
Cosmetic, one cell, invisible to `--verify-behavioral`; the blink
routine's data source is the suspect for a future pass.

## 4e. The attract-demo arc: off-profile timelines and two new nets

A fresh regeneration campaign (2026-08-29, this time from the merged
generator on main) chased the OTHER surface nobody had verified: power-on
with no input. v8 froze black at f2779 forever; stock is pixel-identical
through f2935 (the title fade is stock behavior) and comes back with the
intro at f2936. Root cause was the familiar one — the intro/attract loaders
in banks $8F-$91 were byte-identical to stock, unrewritten, because every
campaign surface pressed Start — and the familiar fix (an idle 36,000-frame
attract surface; coverage is the union of surfaces) covered them. What the
arc then surfaced was new, and both holes shared one shape: **the
conversion's own lag differential forks its timeline onto paths no stock
profile can lead**, where evidence-gated rewrites can never fire.

1. **Queue-bank immediates** (`a9 a3 00 9d a6 6f` at file 0x102404): the
   sound library enqueues a handler bank as a 16-bit immediate into the
   queue column $0FA6/$6FA6,X; the `$20:9088` XBA dispatch PLBs it
   thousands of cycles later. The measured pointer-bank net had re-banked
   the SIX sibling enqueue sites the profiled runs executed; the seventh
   fired only on the conversion's laggy attract, jumped to `$A3:804C` (MB2
   garbage on the shim map), and BRK'd into the crash trap — and the
   evidence loop can NEVER close it, because every cover replay dies at
   that BRK before the PLB proves the byte. Now rewritten BY SIGNATURE
   (`demirrorQueueBankImms`): the consumer's XBA/PHA/PLB/PLB tail names
   the bank column statically, and every `LDA #imm16 / STA column,X`
   producer re-banks by the same de-mirror map. Same stance as the
   `STA $00 / JMP ($0000)` macro net, for the same reason.

2. **Indirect-HDMA table evidence starved by scroll-effect churn**
   ($88:D932, per-scanline $2105 pointers $07EB/$07EC): the Ceres ARRIVAL
   arms the same class of table the escape's fix (§4a) relocated, and the
   gameplay surface evidenced it 14,680 times — yet it never reached the
   relocation pass. `addHdmaTable` was a silent drop at capacity, and a
   scrolling HDMA effect re-arms with a SHIFTED table base every frame,
   so its distinct-address family is unbounded: the attract surface's
   scroll churn ($88:B6xx/$88:C0xx at 3-byte strides) fills ANY fixed
   list before a later surface's table arms — a cap bump to 128 changed
   nothing. Symptom: game logic byte-identical (state, every PPU register
   write, VRAM, OAM), picture a full-screen striped tile-sheet — the
   per-scanline BG-mode HDMA fetching the abandoned low-WRAM mirror. The
   list is a FIFO ring now: re-arms are dedup no-ops, so a table that
   still arms re-enters at worst one eviction later, and the relocation
   walk is idempotent, so a shifted base costs a slot but never a wrong
   byte. Cover harvests also MERGE armed HDMA tables from the
   conversion-side replay (guarded on the table's first byte), for a
   table only an off-profile timeline arms.

Diagnostics that earned their keep on #2, in order: `--hash-stream` tail
repeat-length (a "distinct pictures" count hides a freeze; the tail run
does not); set-intersection of picture streams against stock to find the
first permanently-divergent frame; `--bg-disable`/`--hdma-disable` layer
bisection (Samus rendered perfectly under the garbage — logic was never
suspect); a save-state reload to rule out stale renderer caches; and
`--dump-ppu`'s new full-CGRAM line. Two traps: identical POST-frame
register dumps prove nothing about per-scanline HDMA state, and a
hand-fixed cover image fails the byte-identity guard for exactly the bytes
it fixed — guard on the table's count byte, not its pointers.

Also landed on this arc: window mode leaves $2000-$7FFF absolutes under an
unproven DBR native instead of refusing the whole conversion
(`wg_wram_beyond_bwram`). Ridley's AI does `LDA $7820` under a low DBR —
open bus on the stock cart, a read the game discards. Leaving the site
native is sound: a runtime-WRAM DBR re-banks to $40/$41, where the linear
BW-RAM image carries the whole 64 KiB, so the native absolute reads the
moved byte anyway; any other DBR reads what stock's bus returned, except
the window range itself, which behavioral verification arbitrates.
Whole-game mode still refuses.

The surfaces this arc verifies with: `sm-attract36k.ymv` (36,000 zero-input
frames) and `sm-play-death.ymv` (38,000 frames: intro, Ceres arrival, five
rooms, the Ridley fight taken to a death, game over, CONTINUE, respawn —
scripted blind against position telemetry at `$0AF6/$0AFA/$079B/$09C2`,
end-hash verified), plus a Start-path cover pair on the previous
conversion to arm the arrival table.

## 4f. The player-driven arc: six bugs found by playing (v19-v24)

The attract arc (§4e) closed the no-input surface. What followed was the
opposite method: a person played the conversion in the SDL player, recorded
`.ymv` movies when it broke, and each recording became a coverage surface.
Six failures fell out, and every one was code no surface had executed. The
loop is cheap and it works — but §4f exists mostly to record where it
*stopped* working, because that is the part worth knowing next time.

| conv | failure | site | closed by |
|---|---|---|---|
| v18 | Start pressed DURING the title fade takes SM's intro-SKIP path (stock warps to Zebes's gunship landing, no Ceres); the conversion idled black forever at the `$80:8346` NMI wait | uncovered intro-skip loader | `sm-titleskip.ymv` surface |
| v19 | Ridley's grab attack BRK'd into the crash trap | `$26:DF59 JSL $A0:A497`, byte-identical to stock | player recording as a cover pair |
| v20 | after the escape countdown starts, Samus never regains control — game running, pad polled, input landing correctly in the moved home | `$90:E200 LDA $0DD0` read the ABANDONED home; the escape flag lives at `$6DD0`, so the `BEQ` was always taken | player recording as a cover pair |
| v22 | "the decor is wrong and Samus cannot progress" in the room behind Ridley's | NOT a room bug — see below | player recording as a cover pair |
| v22 | backtrack loader ran its countdown past zero in MB2 garbage | `$26:E877 JSL $A0:C0AE`, byte-identical to stock | hand byte (see the poisoning note) |

### The misdiagnosis worth remembering

"The decor is wrong and Samus cannot progress" reads as a room-load bug, and
three probes were spent there: the level-data buffer (healthy — 16.5k live
bytes, correct moved home, nothing in the abandoned mirror), the BG tilemaps
(healthy — 80 distinct tile indices, max `$219`, sane palette selectors,
structured fills), and the CGRAM upload DMA (correct — `$40:C000`, 512 bytes,
all three differing bytes vs stock are proper window rewrites).

It was none of those. The player had **died during the escape**, and the
death sequence was wedged:

```
$0998 = 0013   (death sequence, not $0008 gameplay)
$09C2 = 0      $0A1C = 0054 (death pose)
$0DD0 = 0000   (escape flag cleared by the death handler)
palette buffer $40:C000 = 182/512 bytes, FROZEN
```

The "garbled decor" was the death fade stopped part-way; "cannot progress"
was the death pose frozen. Dying to Ridley in a normal room — which
`sm-play-death.ymv` covers — is a DIFFERENT handler from dying during the
escape, which nothing covered. The discriminator that cracked it: advance a
save state 900 frames and diff. Palette, position, HP and state all
identical means a stalled state machine, which no room-load bug produces. A
healthy tilemap under a wrong-coloured screen says the same thing and says
it earlier — weight it.

### Harvesting a CRASHED run poisons coverage

The `$26:E877` crash could not be closed by coverage, because **the run that
covers the site is the run that crashes on it**. Feeding that recording to
`--cover-movie` made three consecutive generations refuse:

```
refused: an executed instruction (block move, BRK/COP, STP) cannot run on
the SA-1 side  at $20:c0b3
```

`$20:C0B3` is the OPERAND byte of `LDX #$0000`, not an instruction. The
crash's garbage execution ran at `$A0:C0Bx`, and the harvest's file mapping
is `(pc >> 16) & 0x7F` — a true mirror on a <=2 MiB LoROM, but on a >2 MiB
shim-mapped image `$A0-$BF` is **MB2**, a different megabyte. So garbage
executed in one bank was credited to another bank's file bytes, marking an
operand as an instruction start. Statically-walked code SKIPS these opcodes
(`sa1gen.zig`, the `static_skipped` arm); code the map calls *executed*
refuses on them.

The refusal reproduced identically with an experimental net applied, with
that net plus a partial mapping fix, and with **both reverted** — which is
what proved the recording itself was the cause. Fixing the guard is not
enough: coverage is merged at the raw CPU address, so conversion-side
coverage must be translated through the shim map back to stock CPU addresses
before merging, not masked. Until then, do not pass a crashed recording as a
cover surface.

Two happier notes from the same mechanism. A cover pair whose image already
contains a hand fix lets the generator *derive* that fix: v23 carried one
hand byte at file `0x13687A`, the site then executed correctly under
`--cover-movie`, and v24 emitted `22 ae c0 20` on its own — zero hand bytes,
the first fully machine-generated build since v18. And a HUNG recording is
safe to harvest; only a crashed one poisons.

### The mirror-JSL class, closed by its own twin

Three of the six failures were the same shape: an uncovered
`JSL $A0-$BF:addr` that lands in MB2 and BRKs. A census of v22 found **51
distinct mirror-bank targets across 628 call sites** whose de-mirrored twin
`JSL $20-$3F:addr` ALREADY appears in the converted image — including
`$A0:A497`, the Ridley routine proved by hand. The repetition (20-77 calls
per target) is what distinguishes them from data noise, and the bytes settle
it: `$20:C0AE` is a real prologue (`PHP / REP #$30 / PHX / LDX #$0000`),
while `$A0:C0AE` under the shim is garbage containing a `$44` block move.

A twin-evidence net (`demirrorTwinJsls`) now closes the class without any
coverage at all. In the CONVERTED image the same entry is already called as
`JSL $20-$3F:addr` by code that IS covered — stock never spells it that way,
so the twin is minted by the coverage-gated de-mirror pass, and this pass
spends what that one minted. A mirror JSL whose twin is called twice or more
is re-banked -$80.

The blocker recorded here earlier — "the walk descends into net-discovered
entries treating them as executed code" — was a misdiagnosis. Keying on the
twin means every body the net makes callable was ALREADY walked and
rewritten: a covered call to the twin is precisely what put it in coverage,
and the walk's LoROM fold (`$A0 & 0x7F` is `$20`) happens to equal the
de-mirror over this range. The net rewrites operands only and hands the walk
nothing new to arbitrate, which is why it lands where a blind 628-byte
rewrite could not.

Measured on v25: **505 sites across 31 targets**, led by `$A0:C786` (77
sites, twin called 17x). The image diff is exactly those 505 bank bytes plus
the 4 header checksum/complement bytes — nothing else moved.

The evidence that the direction is right, since no surface executes these
sites: decode both addresses. All 31 twins decode cleanly; 25 of the 31
mirrors hit a fatal opcode within a few instructions (`$A0:C0AE` at
instruction 1, `$A0:B067` at 0). The remaining 6 decode clean on both sides
— MB2 data that a 12-instruction linear decode cannot condemn, not a
counter-example.

What this does NOT establish: the three scripted surfaces cannot execute
these sites, that being the definition of the class, so a passing gauntlet
shows no REGRESSION rather than a fix. Confirming the fix wants the Ridley
grab, one of the lost recordings. And the harvest bank translation
(`(pc >> 16) & 0x7F` on a shim-mapped image) is still wrong and still blocks
harvesting a crashed run — the net removed the need for that on THIS class,
not the bug.

### The surface set these conversions verify with

Stock-side (`--movie`): `sm-attract36k.ymv` (36,000 zero-input frames),
`sm-play-death.ymv` (38,000f: intro, Ceres, five rooms, the Ridley fight
taken to a death, game over, CONTINUE, respawn), `sm-titleskip.ymv`
(15,000f: Start during the title fade, then the Zebes landing).
Conversion-side (`--cover-image` + `--cover-movie`), each pairing a previous
conversion with a recording made on it: v9/v10 idle runs, a v15 Start-path
run, and player recordings on v19, v20, v21 and v23. The exact invocation is
written beside every generated patch as `<out>.bps.cmd`.

The three stock-side surfaces are deterministic input schedules, so they are
CODE, not artefacts: `tools/sm_surfaces.py <stock.sfc> <outdir>` re-emits all
three bit-identically (verified — the input bodies compare equal, and
`sm-play-death.ymv` reproduces its recorded end hashes
`548d0d5ad43881bb`/`ada5280c6419c820` exactly). It also replays each one to
embed those hashes, so a later replay prints "sync verified" rather than
"sync unverified".

**The four player recordings cannot be regenerated by anything** — they are
hours of real play, and each one exists because it walked a path no script
had. Keep them somewhere durable alongside the `.bps` and its `.cmd`; a
scratchpad does not survive the session. Losing them does not corrupt a
build, it silently narrows coverage, and the bugs in section 4f come back.

## 4g. The level-pointer class: rooms no surface loaded (v25-v33)

Three stalls in one evening, each found by a player recording and each
closed by harvesting it — until the third one refused to close that way,
and turned out to be the largest class this campaign has found.

| conv | symptom | site | closed by |
|---|---|---|---|
| v26 | bullets do no damage to Ridley | projectile tables `$0B64/$0B78/$0BDC/$0BF0` and enemy cells `$0F7A/$0F7E/$0FAC` still on the abandoned home | `ridley-no-damage.ymv` as a cover pair: 2,417 instructions newly covered, 57 sites relocated (v27) |
| v27 | Samus never regains control in the Ceres escape | `$90:E200 LDA $0DD0`, byte-identical to stock — §4f's v20 bug, re-opened because the recording that covered it was lost | `escape-stuck.ymv` as a cover pair (v28) |
| v28 | "Samus is stuck" in the falling-tile room, no decor drawn | `$84:B3A6` `BRA *` — reached on **correct** logic over **garbage level data** | the room-graph walk (v32) |

The first two are the §4f shape and the §4f loop closed them in twenty-five
minutes each. The third is the one worth writing down.

### Every link was correct

`--dump-ram` 900 frames apart showed 3 bytes changing: a halt, not a
freeze. The PC sat on `80 FE` (`BRA *`), Super Metroid's own assertion in
the setup of PLM `$B6FF`: *find another PLM at my block, or hang*. Every
link in the chain that reaches it was traced and was stock logic on
correctly relocated data: the room state selected by `$80:81DC` (Ceres
Ridley's boss bit, read through `$40:D828,X`); the room's PLM list, empty
in stock too; the type-`$B` block reaction `$94:9139[$46] -> $B6FF`; the
enemy `$E23F`'s AI bank byte, re-banked `$A6 -> $26` and executing there.
Harvesting a stock recording of the same path (`stock-escape-anchored.ymv`
as `--cover-image sm.sfc`) covered 1,987 new instructions and changed
nothing about the halt (v30). The instinct after that — a timing race in
stock exposed by the conversion's lower lag — was wrong too.

What cracked it was comparing Samus's trajectory through the room on stock
against the conversion: stock enters at `Y=077` on the upper level, the
conversion at `Y=08B` on the lower — a position stock never occupies at
that X. Then the block table: the conversion's copy of room `$E06B` was
**0/512 words identical to stock** on the escape pass, and **512/512** on
the first pass through the same room before Ridley. Same level-data pointer
both times. The decompressor was producing garbage, from its first byte,
only when loading the escape state.

### The byte

Tracing both decompressions to their first divergence took one instruction:

```
$82:EA95  first pass:  a=ADC3     escape pass:  a=CDC3
```

That is the room loader reading the level-data pointer's bank out of the
state header. Every room state carries a 3-byte pointer at `+0`, and every
one of them names MB2 (`$C2-$CE`). Under the >2 MiB shim MB2 lives `$20`
lower, so the byte must become `$A2-$AE` — and the only pass that does that
is `hi_proven`, which needs the profile to have watched the loader read that
exact byte. The default state's byte at `$8F:E07F` was proven (every surface
visits that room before Ridley). The escape state's byte at `$8F:E099` was
not: no stock-side surface had ever loaded the escape state. `$CD:C330`
under the shim is not level data; the block table came out as tilemap-shaped
noise, nothing rendered, Samus walked through a wall into a phantom
special block, and the PLM it spawned hung looking for a partner.

Hand-patching the six Ceres escape-state bytes in v30 made `plm-halt.ymv`
run through the room and end in `$E021`. Root cause closed.

### Why it is a class, and why coverage cannot close it

In bank `$8F`, 40 pointer-shaped `$C2-$CE` bytes were translated and ~750
were not. All six Ceres escape states were raw in v28 *and* v30. Off the
landing site, Gauntlet Entrance, Parlor, Crateria PB and Terminator were
raw; the Landing Site and Brinstar Green Hall were fine only because the
attract demo visits them. **The conversion was unplayable past the first
door off the landing site**, and nobody had noticed because every surface
and every recording lives in Ceres. Coverage proves the states it loads;
nothing short of visiting every room state closes the class by evidence.

### The net: walk the room graph

`rebankSmRoomLevelPointers` (sa1gen) does what the twin-JSL net did for
mirror `JSL`s — closes the class with no coverage at all — but the proof it
spends is structure, not a twin. No shape identifies the byte on its own (a
`$CD` after a word is common in a bank of tables), but the structure that
reaches it is exact and finite: door headers (`$83`) name rooms (`$8F`); a
room's condition list names its states (arg widths read off the condition
routines: `$E5EB` 2, `$E612`/`$E629` 1, the rest 0); a state's first three
bytes are the pointer. The walk follows doors from the landing site, stops
where a door names no room (elevators, `$0000`), validates every state
(pointer in MB2's ROM half, tileset index in range) before touching a byte,
and refuses the whole pass on the first failure. It reads stock bytes and
leaves anything `hi_proven` already re-banked alone, so the two compose.

Gated on the ROM title and a >2 MiB window conversion. v31 reached 255
rooms / 310 states and re-banked 292; the image diff against v30 was
exactly those 292 bytes plus the checksum. Then a lesson: **Ceres is not on
the door graph.** The game warps into `$DF45` at new-game and warps out at
the end of the escape; no door crosses between Ceres and Zebes, so a walk
rooted at the landing site never reaches it. With `$DF45` as a second root
(v32): 261 rooms / 322 states / 298 re-banked, all six escape states at
`$AD`, and `plm-halt.ymv` replays through the room with no hand patch.
Behavioral verification unchanged, timing unchanged (2342 -> 2416 dropped).

### The learning, stated once

Two of the three stalls were the same lesson as §4f's twin-JSL close, and
the third is its sharpest form: **a net survives a lost recording; coverage
does not.** Ridley's grab stayed fixed across the lost scratchpad because
`da19a29` closed it in the generator; the escape flag regressed because it
had only ever been closed by a recording. The level-pointer class was ~750
sites wide and would have cost one freeze per new room, forever, on the
recording loop. It cost 265 lines and one unit test on the walk.

Two smaller ones from the same evening:

- **Trajectory comparison is a discriminator.** When every link at a halt
  checks out, compare where the player *is* on both images. A position stock
  never occupies at that X is the divergence, and it points upstream.
- **A hand patch is the cheapest proof there is.** Six bytes in a copy of
  the image settled the root cause before a single generator run.

### The recorder

Two stock takes were made before one usable: the first anchored to a menu
state (F9 had been pressed), the second discarded because the window was
closed without F10. `--record` in the SDL player now opens the take before
the first frame runs (F10 alone cannot promise frame 0 — `at_power_on` does
not notice frames slipping by), starts with **blank battery SRAM** (headless
loads none, so a take made against a save file could never replay), leaves
the real `.srm` untouched, and saves the take on exit. `sm-escape-poweron.ymv`
— power-on, 20,807 frames, sync verified, the whole Ceres arc — is the first
stock-side surface through the escape.

### The escape does not verify as a surface, for a principled reason

Adding the take as a fourth `--movie` (v33) made the generator REFUSE: the
behavioral tier fails the escape and never heals. The forensics say why, and
it is not the net. Divergence is near-zero until Samus enters the final Ceres
rooms, then saturates at the print cap (65 cells) the instant the collapse
starts, and every diverging cell is a sprite/projectile slot (`$0F78`+`$40`
stride) or a wall-derived counter (`$05B6`) — room, health, escape flag and
Samus's position through DFD7 all stay in sync. That is the escape's
explosion/debris/`$E1FF`-enemy chaos, seeded from RNG and timers, forking
under the lag differential: the SAME RNG-fork signature the tier EXCUSED on
the attract surface (surface 1). The attract healed at a scene reset; the
escape runs to the movie's end with no reset inside the window, so the fork
never heals and the persistence verdict fails it.

So the escape is coverage, not a verification surface. But it must not be
LOST as coverage: v32 (net in, all surfaces verified) shipped the escape
BLACK — correct geometry, CGRAM all zeros. Root, one layer up from the level
pointers: three `$7F` bank bytes at `$8B:C3E9/C6BD/C6CE`, in the escape's
graphics/palette decompress-output path (right after `JSL $80:B0FF`), stayed
raw because no surface PROFILED the escape, so the palette decompressed into
the abandoned bank. Same evidence-gated shape, the CGRAM-destination bank
instead of the level pointer. The v33 profile proved them and rendered the
escape identical to stock — but v33 was a `--movie` and REFUSED on the fork.

The resolution is `--evidence-movie`, not a verifier change. It feeds the
same profile — coverage, site evidence, value provenance — into the shared
union, but `movie_verify[s]` (main.zig) skips its behavioral tier. So the
escape take profiles the escape (proving the `$8B` palette banks AND the
three non-state FX pointers at `$8F:E734/E737/E73A` the door-walk cannot
reach) while never being tick-locked against a scene it cannot match.

**v34** is the ship: net in, escape take as `--evidence-movie`, all three
verification surfaces behaviorally equivalent, DFD7-escape palette
`cgram_sum=00230fa4` identical to stock, room renders, round-trip verified.
The verifier is untouched — weakening the gate every game depends on, to pass
one RNG-forked surface, was the wrong trade when a coverage-only surface does
the whole job.

### The chain keeps going: foreground code, then background data (v36-v38)

Making the game REACHABLE exposed a run of per-room pointers no surface had
ever hit, because you could not get to those rooms before. Playing v34 into
the Parlor ($92FD, the first Zebes room off the landing site) rendered it as
COMPLETE tile garbage. Three layers, each found by playing one room further:

- **Level geometry** — the room-graph walk (already shipped). Correct.
- **Foreground tiles** — uncovered CODE. v34's playthrough, harvested as a
  cover pair, let the generator relocate the Zebes room-load path (new
  thunks in bank $81); v36 rendered the foreground. This is coverage, not
  structure: a lost recording reopens it.
- **Background (BG2)** — DATA, and coverage does NOT reach it. v37 (with the
  Parlor now covered) verified but left the BG record's source banks raw,
  because the BG DMA reads its source bank straight from the record as data;
  no code relocation moves a data byte. A three-byte hand-patch of the
  Parlor's BG record ($8F:B8B4: $BA->$3A, $7E->$40) made the room clean,
  proving the whole cause.

The BG record is the same shape as the level pointer, one table deeper: each
state names it at +$16, and it is a DMA list whose copy commands carry source
banks. `rebankSmBgRecord` de-mirrors them structurally, per-record graceful
(a state's +$16 legitimately points at code or nothing, so a record that
stops parsing as a list is skipped). Command widths read off SM's interpreter
and validated against all 67 reachable records (66 clean, one code-pointer
correctly rejected). v38: 130 source banks across 196 records, escape and
Parlor both pixel-clean, verified.

**The standing lesson, sharpened.** A net survives a lost recording; coverage
does not — and the split runs along the code/data line. Uncovered CODE is
fixed by coverage (relocation follows execution). Uncovered DATA — a pointer
or bank byte a data structure carries — is fixed only by a structural net
that knows the structure, because no execution moves a byte the code merely
reads. The level pointer, the tileset banks, and the BG records are all the
data side; the Zebes foreground was the code side. What remains open is every
room-type still unvisited: its data pointers are structural (net them as
found), its uncovered code wants one comprehensive playthrough as coverage.

## 4h. The inline-destination class: a pointer hiding inside code (v39-v40)

The next room the v38 power-on take reached — `$9A44`, two doors past the
Parlor, the first Crateria room with a DIFFERENT tileset (index 2) — rendered
with correct geometry and wrong textures: the walls were the Parlor's blue
blocks, and the Chozo-face decor came out as green-and-red figures. The
player's report: "the decor textures are incorrect".

**The harvest test settled code vs data first.** v39 = v38's recipe + this
very take as a cover pair. It verified, changed 22 code bytes in bank `$84`,
and rendered `$9A44` PIXEL-IDENTICAL to v38. Coverage of the exact path that
shows the bug did nothing, so by §0.5 the byte was data. That one comparison
saved the investigation from another coverage round.

**The trace.** No stock reference existed for the room (the take desyncs on
stock: the conversion's lag differs), so the reference was the ROM itself —
a Python port of SM's decompressor (§5) decompressing the tileset's three
pointers and the CRE, compared against v38's VRAM, CGRAM and RAM dumps:

- Tile graphics (VRAM `$0000`), CRE graphics (`$2800`), palette (CGRAM):
  byte-identical to the ROM. Not the problem.
- The tile table — the 8-byte-per-block map from level block index to four
  tilemap words — at its re-banked home `$40:A800`: WRONG. It was a
  different tileset's table. The stock table for tileset 2 was found intact
  in REAL WRAM `$7E:A800`, where nothing reads it.
- `--watch BB00-BB03` (block `$360`'s entry, both homes): the decompressor's
  own `STA [$4C],Y` at `$80:B193` wrote `$40:BB00` on one call and
  `$7E:BB00` on the next two. Same instruction, different bank byte in `$4E`
  — so the bank is data the CALLER supplies.

**The byte.** `$80:B0FF` pulls its return address, reads the two bytes after
the JSL into `$4C/$4D` with a 16-bit load that spills the THIRD byte into
`$4E`, and advances the return by 3. Every `JSL $80:B0FF` is followed by an
inline `dl $bb:aaaa` destination — a long pointer sitting in the code stream.
SM has two copies of the tileset loader: the door-transition one
(`$82:E7D3`, sites `$E845/$E856/$E869`) and the load-game one (`$82:EA4x`,
sites `$EAF5/$EB06/$EB19`). The stock recordings drove the first; the Ceres
escape lands on Zebes through the second, whose CRE and tile-table sites
were raw. Every tileset first loaded through that path decompressed its
table into real `$7E:A800`, and the game kept reading the previous table at
`$40:A800`. 63 such sites in stock; 29 raw in v38 (the two loader sites, one
in the map/pause code at `$82:E41D`, and 26 across the bank-`$8B` intro and
cutscene code). Hand-patching those 29 bank bytes made `$9A44` render its
brick walls and Chozo faces correctly, with the take's audio hash unchanged.

**The net** (`rebankSmDecompInlineDests`): scan the image for the four JSL
bytes; if the inline bank is `$7E/$7F`, re-bank it `$40/$41`; skip anything
else (a ROM destination, or data that happens to spell the JSL); leave a
byte provenance already proved alone. Title-gated like the other two.
Unit-tested (proven site untouched, ROM destination untouched, address bytes
never touched). v40 = v38's recipe + the net.

**What this class teaches.** The room-state pointer and the BG record were
data in data tables; this one is data INSIDE CODE — an inline argument the
callee reads through the return address. Relocation-by-execution sees the
JSL, relocates its target, and steps over the argument as if it were the
next instruction's bytes. The profiler catches it only by value provenance
(a recording that drives the call and traces the byte into a `$7E` store),
which is exactly evidence-gating again. Any routine with inline arguments
is the same shape; in SM the decompressor is the one that matters, because
everything the picture is made of passes through it.

## 5. Instruments and technique notes

`--dump-ppu` grew several times this campaign; it now prints, per frame:
layers (map/char bases, tile-size, scroll, per-BG nonzero tilemap count),
brightness/force-blank, `TM`/`TS`, **color math** (`cgwsel`/`cgadsub`/
`fixed_color`/`setini`), **window + mosaic** (`w12sel`..`wh3`/`wbglog`/
`tmw`/`tsw`/`mosaic`), per-active-HDMA-channel `control`/`b_addr`/
`indirect_bank`/`indirect_addr`, a **CGRAM digest** (`cgram_sum` + sample
palette entries), and a `<-- ABANDONED MEMORY` flag on any HDMA channel whose
source is a `$7E`/`$7F` or low-mirror bank. Add the *specific* register class
before assuming a render bug is impossible — three "everything identical yet
different" dead-ends were just a register the dump didn't yet print.

- `--watch lo-hi` (WRAM offsets, hex; `lo=0` disarms) prints writers with
  home-normalized addresses — window (`$6xxx`) and raw forms mix; normalize
  offsets `$6000-$7FFF` by `−$6000` when aligning streams. Caps at 4096
  prints; `--watch-from <clk,decimal>` arms late to spend the budget where it
  matters. Watch/stale/trace print **post-fetch pcs** (site = pc − length).
- `--stale N` flags accesses to abandoned homes **below `$2000` only** —
  stale traffic to upper WRAM (e.g. `$C200`) is invisible to it. An empty
  census does not clear upper-WRAM splits.
- `--clock-pc` has a **one-shot latch**: it prints the *first* hit per run.
  Empty = true never; a single line is not a count.
- `--trace-clk FROM-TO` (dash, decimal) goes to stderr; records can be
  **concatenated on one line** — parse with `finditer`, never per-line
  regexes. Sequence-align pc streams with difflib (index-compare breaks at
  the first IRQ skew); filter far-pool banks (`$38-$3F`) first.
- `--site-ev a,b,... --ev-only` prints per-site coverage/evidence for both
  homes (`cov`/`cov80`, `ev`/`ev80`) after profiling. `--dump-vram` is raw
  VRAM (64 KiB) + OAM (544 B), so cross-image VRAM/OAM diffs are byte-exact.
- `--watch` **also covers MMIO** (`$2100-$4400`), not just WRAM — a range like
  `--watch 2131-2131` catches PPU/DMA register writes with their PC/value.
  Caveat: the printed address is the full 24-bit access, so a WRAM offset
  (`$40:4327`) and the port (`$00:4327`) both surface under one range —
  disambiguate by bank. `--watch-min HH` filters to values `≥ HH` (find the
  one nonzero write among a stream of zeros — that is how `cgadsub=$33` was
  caught after end-of-frame showed `0`).
- `--dma-bank-pc N` traps writes to the DMA/HDMA A-bus bank **and** indirect
  bank registers (`$43x4` *and* `$43x7`), printing PC/channel/value and an
  `<-- ABANDONED` flag on `$7E`/`$7F`. This is the only clean way to name who
  armed an HDMA reading a moved home — the CPU-side watch cannot, because the
  bank often arrives as runtime data, not an immediate.
- Save states: payload WRAM at `0x2001A`; a conversion's *live* WRAM is the
  BW-RAM image at `len − 0x40004`. **The conversion's state file has a
  different layout from stock's** (BW-RAM appended), so fixed PPU structures
  (CGRAM, OAM) sit at *different offsets* — always re-locate them by signature
  search *per state*, never by a shared offset (a wrong-offset read once
  "proved" a zeroed CGRAM that was actually identical). ARAM was pinned at
  `0x45C42` in one build's states by matching engine bytes to ROM — offsets do
  **not** transfer across builds either.
- **End-of-frame register dumps miss mid-frame changes.** HDMA rewrites
  registers every scanline and the CPU often sets-then-resets (`cgadsub` goes
  `$33` during the visible frame, `0` by vblank). To know a register's value
  *while a given scanline rendered*, watch its writes across the frame — do
  not trust the snapshot.
- Movies (`.ymv`): CRC binds to the image at `0x08`, frame count `0x0C`,
  4 B/frame at `0x20` (v2: anchor after the header). Buttons u16 LE:
  Start `$1000`, A `$0080`, B `$8000`, Right `$0100`. CRC-patch a copy to
  replay on a conversion.
- Build chains: gate generation on a *zero* error count —
  `[ $(build 2>&1 | grep -cE 'error:') -eq 0 ] && gen…` — a bare `grep -c`
  "succeeds" when it finds errors, and the stale-exe trap produced three
  phantom generations. Transient install-lock failures print 2 error lines;
  a clean rebuild right after usually passes.
- Verify patches landed by grepping a symbol that is **new and unique**
  (`disp_cells`, not `disp_sites` — which collided with an existing Stats
  field and hid a failed patch).

**ROM-side references when no stock run can reach the room.** A take
recorded on the conversion desyncs when replayed on stock (the lag differs),
so a room only the conversion has reached has no stock VRAM to diff against.
The reference is the ROM: `tools/sm_decomp.py` is a port of Super Metroid's
decompressor (`$80:B0FF` — direct/byte-fill/word-fill/increment/copy/XOR-copy
commands, `$FF` ends), so a tileset's graphics, tile table and palette, a
room's level data, or a BG record's picture can be decompressed and compared
byte-for-byte against `--dump-vram`/`--dump-ppu`/`--dump-ram`. That is how
§4h separated "graphics right, palette right, tile table stale" in one pass.
`tools/dis65816.py` is a small 65816 disassembler (`dis65816.py image bank
addr len [mx]`) for reading the call sites once the byte is found; mind that
inline arguments after a JSL show up as nonsense instructions, which is the
tell for the inline-argument class.

## 6. Known latent issues (not blocking the current surfaces)

- The `$94:98E9` twin cutscene handler and the `$00:840F` `$7F`-fill loop are
  still uncovered/stock (never executed by any surface).
- **51 mirror-bank `JSL` targets / 628 call sites remain unrewritten** (§4f):
  each is a latent BRK on the first play that reaches it. Three have been
  closed one at a time by coverage; the general net is blocked on the
  harvest bank translation.
- The cover harvest maps conversion-side coverage with `(pc >> 16) & 0x7F`,
  which is wrong for >2 MiB images where `$A0-$BF` is MB2 (§4f). This
  silently mis-credits any coverage harvested from those banks.
- Tiny-base `abs,X` reads under mirror DBRs in the door path
  (`$02:DE06`, `$02:DF44+`) are left stock with pure-ROM evidence; safe on the
  recorded paths, same split class if a path ever lands them in low WRAM.
- The behavioral gate's "held" set for the in-game surface is benign timing
  residue: NMI context pushes (`$1FE2/3`), an APU handshake spin counter
  (`$0641`), and stored-bank representational twins (`$7E/$7F → $40/$41`).
  A "translated-twin" gate excuse would make these formally clean.
- The RNG fork tail (f13,901 → end) is excused by design — eyeball it in play.

## 7. Chronology of generations (this campaign)

gen31-38: the six-fix chain to first verification · gen39: mash evidence
surface (intro-skip fix) · gen40: player-recording cover harvest
(cutscene-end fix) · gen41-45: `$099C` descent iterations (parse traps,
capped-list bug) · gen46-49: descent landed, all four split sites shifted,
`$099C` exonerated · gen50-51: the rev6 provenance-copy fix **landed** —
the tileset table's three pointer banks prove and fold
(`$0F:E73D/E740/E743`, file-offset-verified), palette staging and CGRAM
come out byte-identical to stock, and the new-game room renders. The
black-room freeze is fixed. The Ceres-escape garble is now fixed too (§4a):
low-WRAM HDMA-table indirect addresses relocate into the window (hdma3) and the
`$43x7` DASB thunk rebanks the colour HDMA (hdma2) — pixel-identical to stock.


v25-v33 (2026-09-01/02): v25 the branch's three-surface build · v26 the
union with the recovered cover pairs (505 twin-JSL + 20 coverage sites,
and the `2342 -> 28969` dropped-frame alarm resolved: the unfixed mirror
JSLs had been trapping the CPU) · v27 Ridley takes damage · v28 the escape
resumes · v29-v30 the falling-tile halt does not move under any coverage ·
v31 the room-graph walk (292 banks) · v32 the Ceres root (298; the halt is
gone) · v33 the power-on escape take as a fourth `--movie` — REFUSED, the
escape is an RNG-forked scene and cannot be a verification surface · v32 the
net image, verified but the escape rendered BLACK (an evidence-gated palette
bank the escape never profiled) · v34 the escape take as `--evidence-movie`:
palette proven, escape renders, all verification surfaces pass — the ship (§4g).

v35-v40 (2026-09-02/03): v35 a tileset-table net on guessed widths — no
effect, reverted · v36 the Parlor foreground via the v34 playthrough as a
cover pair (code) · v37 the Parlor background still raw under full coverage
(data) · v38 the BG-record net, Parlor pixel-clean — the ship · v39 the
power-on take that reached `$9A44` as a cover pair: verified, 22 code bytes,
render identical — the decor is data · v40 the decompressor inline-destination
net, `$9A44` renders its real tileset (§4h).

## 8. Cross-cutting learnings

Method traps that cost real time and are worth internalizing:

- **Frame-locked comparison is invalid for a lag-removing conversion.**
  Removing lag means the conversion advances the game *further* per wall
  frame, so stock and conversion at the same frame number are at *different
  game moments*. Comparing VRAM/CGRAM/registers there will show spurious
  differences (or spurious matches). Use the **tick-locked behavioral
  verifier**, which anchors on controller polls, for any state comparison.
- **The behavioral tier verifies logic, never the picture.** It compares
  WRAM/logic state tick-by-tick; it does not look at VRAM/CGRAM/OAM/the
  framebuffer. A display-only divergence (a mis-fed HDMA color effect) passes
  behavioral verification while looking broken. "BEHAVIORALLY EQUIVALENT"
  means the game plays correctly, not that every pixel matches.
- **A deterministic renderer with identical inputs produces identical output.**
  When it seemingly does not, an input differs and you have not found it yet —
  keep adding register classes to the dump (color math → window/mosaic →
  per-scanline HDMA) rather than concluding "impossible."
- **Player recordings are the best repro, but need a stock-comparable twin.**
  An anchored recording binds to the conversion image and cannot replay on
  stock. Reproduce the same scene with a from-power-on scripted movie so both
  sides run it; then the tick-locked verifier can compare them.
- **The stale-exe trap.** On Windows a running player holds
  `yamabuki-*.exe`, so a rebuild compiles (`N/M steps`) but fails the *install
  copy* with `AccessDenied` — the old binary stays in place and every
  subsequent run is stale. Gate build+gen chains on a *zero* `error:` count,
  close players before rebuilding, and verify the exe mtime.
- **Verify a patch landed by a *new, unique* symbol.** Grepping a name that
  collides with existing code (`disp_sites`) silently hid three failed
  patches; grep something the patch is the sole source of (`disp_cells`).

## 9. Player / packaging notes

- **`--shader-dir` defaults to `"shaders"` relative to the working directory.**
  Launching the exe from anywhere but the repo root finds no baked presets, and
  the old code mislabeled that as `NoVariantForThisGpu` (a GPU failure) —
  wasting a debugging cycle on a hardware problem that did not exist. Fixed in
  `fd2b825`: `initGl` now distinguishes `ShaderDirNotFound` (with a hint naming
  `--shader-dir`), `ShaderNotBaked`, and a genuine `NoVariantForThisGpu` (which
  now also prints the per-profile `SDL_GetError`). Shaders run fine on this
  NVIDIA card once pointed at `<repo>/shaders` (`crt-easymode-halation`,
  `essl300`); `,`/`.` cycle the ten baked presets in the player.

## 10. Commit index

- `4577111`,`9f7e475`,`10442ad`,`213bb3a`,`f9fcb7e`,`15f77a3`,`22fd4a2` —
  the generator/provenance fixes (§2).
- `38f0d7d` — 16-bit copy `src_any` propagation (the black-room fix).
- `fb30de3` — color-math/HDMA-indirect PPU dump + `$43x7` trap (diagnostics)
  and the first Ceres-tint root cause.
- `fd2b825` — honest SDL shader-init errors (§9).
- `a112bbe` — CGRAM/window/mosaic PPU dump and the corrected, display-only
  Ceres-escape diagnosis (§4a).
- `929a6a0` — `rebankDasbWrites`/`dasbThunkBody`: the `$43x7` DASB runtime
  rebank thunk (fixes the alarm's color-math HDMA leg, NOT the whole garble),
  its unit test, and (in `1ca8bbe`) the `--movie-ignore-crc` diagnostic + the
  `--ppm-range` frame dump + the anchored-state cross-build bypass (§4a).
- `23edcad` — `relocateHdmaIndirect`/`loromFileOffset` + the DMA-arm hook
  recording indirect-HDMA tables into shared provenance: relocates low-WRAM
  HDMA-table indirect addresses into the window (the hdma3 tile-sheet leg of
  the Ceres escape), its unit test, and the `--hdma-disable`/`--dma-trace`
  vdest diagnostics (§4a). The escape now renders correct.
- Docs live in this file; the working branch is `claude/sa1-async-offload`.
