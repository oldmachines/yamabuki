# Super Metroid SA-1 Conversion — Findings

Campaign log for converting Super Metroid (3 MiB LoROM) with the v17 window
architecture (`--gen-sa1-patch --window --wg-static`). Every finding below was
measured on the real game; commits are on `claude/sa1-async-offload`.

Status at time of writing: **both verify surfaces pass** (boot 3600f
pixel-identical; in-game 15000f behaviorally equivalent modulo one genuine RNG
gameplay fork at wall frame 13,901 — prefix of 13,394 ticks verified,
off-episode divergence 8 ticks, every run ≤ 30). Two player-reported freezes
were fixed via coverage surfaces; a third (new-game cutscene → black room) is
root-caused to a provenance gap with a candidate fix in test.

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

### In test (rev6, console.zig — not yet committed)

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

## 5. Instruments and technique notes

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
  homes (`cov`/`cov80`, `ev`/`ev80`) after profiling. `--dump-ppu` is a text
  summary (layers, brightness, HDMA); `--dump-vram` is raw VRAM+OAM.
- Save states: payload WRAM at `0x2001A`; a conversion's *live* WRAM is the
  BW-RAM image at `len − 0x40004`. ARAM was pinned at `0x45C42` in this
  build's states by matching engine bytes to ROM — offsets do **not**
  transfer across builds.
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

## 7. Chronology of generations (this campaign)

gen31-38: the six-fix chain to first verification · gen39: mash evidence
surface (intro-skip fix) · gen40: player-recording cover harvest
(cutscene-end fix) · gen41-45: `$099C` descent iterations (parse traps,
capped-list bug) · gen46-49: descent landed, all four split sites shifted,
`$099C` exonerated · gen50-51: the rev6 provenance-copy fix **landed** —
the tileset table's three pointer banks prove and fold
(`$0F:E73D/E740/E743`, file-offset-verified), palette staging and CGRAM
come out byte-identical to stock, and the new-game room renders. The
black-room freeze is fixed (committed as the `src_any` propagation fix).

**Open residual**: the rendered room carries a steady bright-orange tint
(lum 76 vs stock's 33) with byte-identical CGRAM/VRAM/registers — the one
axis the dumps don't capture is color math (CGWSEL/CGADSUB/COLDATA, the
Ceres alarm's fixed-color add, HDMA channels 2/3). The alarm's pulse
driver appears stuck at full addition on the conversion — a cosmetic
divergence, next on the list.
