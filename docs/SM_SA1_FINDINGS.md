# Super Metroid SA-1 Conversion — Findings

Campaign log for converting Super Metroid (3 MiB LoROM) with the v17 window
architecture (`--gen-sa1-patch --window --wg-static`). Every finding below was
measured on the real game; commits are on `claude/sa1-async-offload`.

Status at time of writing: **both verify surfaces pass** (boot 3600f
pixel-identical; in-game 15000f behaviorally equivalent modulo one genuine RNG
gameplay fork at wall frame 13,901 — prefix of 13,394 ticks verified,
off-episode divergence 8 ticks, every run ≤ 30). Two player-reported freezes
were fixed via coverage surfaces; a third (new-game cutscene → black room) is
fixed by the `src_any` propagation fix (`38f0d7d`). The last display bug — the
Ceres escape rendering as a full-screen garbage tile-sheet — is now **fixed**
(§4a): two indirect HDMA channels fetched per-scanline data from relocated WRAM
buffers the DMA unit could not follow, closed by relocating low-WRAM HDMA-table
indirect addresses into the window (hdma3, the tile-sheet) and the `$43x7` DASB
rebank thunk (hdma2, the colour). The conversion now renders the escape
pixel-identical to stock and still verifies BEHAVIORALLY EQUIVALENT.

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

## 6. Known latent issues (not blocking the current surfaces)

- The `$94:98E9` twin cutscene handler and the `$00:840F` `$7F`-fill loop are
  still uncovered/stock (never executed by any surface).
- Tiny-base `abs,X` reads under mirror DBRs in the door path
  (`$02:DE06`, `$02:DF44+`) are left stock with pure-ROM evidence; safe on the
  recorded paths, same split class if a path ever lands them in low WRAM.
- The behavioral gate's "held" set for the in-game surface is benign timing
  residue: NMI context pushes (`$1FE2/3`), an APU handshake spin counter
  (`$0641`), and stored-bank representational twins (`$7E/$7F → $40/$41`).
  A "translated-twin" gate excuse would make these formally clean.
- The RNG fork tail (f13,901 → end) is excused by design — eyeball it in play.
- **The HUD minimap current-room cell is static on v8** (stock blinks it,
  ~8-frame cadence). Exactly 4 bytes of the settled 64K `$7F` page differ:
  the cell's two tilemap words `$7F:B078/$7F:B0B8` (stock `A810/3C23`,
  v8 `E91F/3EEE`). Cosmetic, invisible to `--verify-behavioral`; see §11.

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
gen52-55 (v2-v5): player report #5/#6 fix chain — the four stacked
invisible-beam pins, the walker fall-through guard, and both dispatcher-plant
gates; the door freeze dies · gen56-58 (v6-v8): the misfit-bank hunt — two
mis-wired provenance candidates (unresolved-site counter 2), then the
`a_hi_src` wiring lands and **v8 ships**: door band 24 → 1024/1024,
unresolved 0, behaviorally equivalent. The stack (#115/#114/#113) merged to
`main` 2026-08-28.

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

- **Two mechanisms can share one symptom — keep a money check.** The
  dispatcher-plant census closed a real, image-wide bug, and the door band
  was still garbage: a second, unrelated mechanism (the unproven queue-staged
  bank, §4d) hid behind the same confetti. Define the one decisive
  comparison up front (band bytes vs their stock file home, the frame after
  the arming DMA) and re-run it after every candidate fix; declare nothing
  fixed until it flips.
- **Wire a provenance arm to what the staging code actually leaves behind.**
  Two full generation cycles were spent on plausible-but-wrong candidate
  variables. The load-staging block is the ground truth: for a 16-bit WRAM
  load it leaves the `src_any`-resolved high byte in `a_hi_src` (the chain
  that survives RAM staging) and *none* in `prev_load_end`. Read the staging
  code and the stock disassembly at the armer pc first; don't guess
  candidates. The `noteUnresolved` counter (2 → 0) was the signal that told
  hit from miss.
- **Out-of-suite consumers rot silently when an API grows.** `zig build
  test` never compiles `tests/patchgen_runner.zig`; `convertWholeGame` grew
  three parameters across sessions and only CI (`test-patchgen`) caught the
  drift — after weeks. When widening a public generator signature, grep all
  call sites including `tests/` and `tools/`, or the breakage surfaces at
  merge time.
- **A blink can masquerade as corruption (and vice versa).** The minimap
  residual triage: single-frame pixel diff → suspicious cell; then compare
  the *sets* of the cell's patterns over a frame window on both builds.
  Overlapping sets = phase lag (benign); disjoint sets (our case) = real
  content divergence. Twenty frames each settled it.

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
- `866e6d0` — base-emulator VRAM read-latch fix (reload only on the
  VMAIN-designated port; Ceres speckle == bsnes after) (§4b).
- `4f6c09a` — the four stacked invisible-beam pin fixes (dual-role `abs,X`
  PLB value-proof, the new `abs,X` thunk shape, `map_body` sub-`$A0` branch,
  `idBank` on 3 MiB) (§4c).
- `feec2a4` — walker JSL fall-through guard (dyn-coverage-within-32-bytes
  discriminator); de-mirrors the door JSL chain (§4d.1-2).
- `2af4eb2` + `5c443ee` — dispatcher-plant gates: profile-read data never a
  candidate; raw scans only in banks with executed code (§4d.3).
- `e7a3005` — the misfit-bank provenance arm (16-bit `STA $4313`,
  `a_hi_src`/`src_any` resolution) + `a1bThunkBody` + test; the confetti
  root fix (§4d.4).
- `452903d` — the minimap-cell residual note; `5acd82e` — patchgen-runner
  signature mend + branch-wide `zig fmt` (the CI green-up).
- Landed in `main` 2026-08-28 via the #115 → #114 → #113 stack
  (`main @ 35d5dc8`); the working branch is `claude/sa1-async-offload`,
  rebased onto main after landing.

## 11. What next

In rough value order:

1. **The minimap-cell residual (§6).** Concrete entry point: the two
   tilemap words `$7F:B078/$7F:B0B8`. Blocker to remove first: `--watch`
   is blind to banks `$7F`/`$41`, so the write site can't be trapped yet —
   extend the watch to WRAM/BW-RAM addresses, then trap the stock writes,
   find the blink routine's data source, and check its provenance in the
   conversion (prediction: another value-mediated home the rewriter missed,
   small sibling of §4d.4).
2. **Broaden the play surface.** Every player report so far came from the
   first minutes of the game; the plants and misfit banks it flushed were
   generic mechanisms. A longer recorded playthrough (Zebes proper, item
   pickups, map/pause screens, a save station) would flush the remaining
   idiom families cheaply while the harvest machinery is warm.
3. **The mainline-split probe (Gradius III-style SA-1 offload).** First
   step is cheap: lag-profile the stock surfaces to see where SM actually
   lags. Then attempt `--wg-split-mode` with current evidence and read the
   refusals — that list is the campaign plan. Expected hard parts: the
   `$2139`-reading decompressor must stay S-CPU-side, the DMA-queue-arming
   mainline is MMIO-entangled, and every split thunk multiplies the 3 MiB
   mirror-provenance surface.
4. **Formalize the behavioral "held" excuses (§6)** — a translated-twin
   gate excuse for `$7E/$7F → $40/$41` representational twins would make
   the in-game surface formally clean instead of waiver-clean.
5. **Uncovered handlers (§6)** — `$94:98E9` and `$00:840F` remain stock;
   any surface that executes them (item cutscenes?) converts them for free
   via the existing harvest path.
