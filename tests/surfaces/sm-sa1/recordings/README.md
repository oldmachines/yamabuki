# Player recordings

Irreplaceable. Nothing regenerates a recording of a person playing.

Each is bound by CRC to the image it was recorded on, and is only meaningful
as a **cover pair** against that image:

    --cover-image <that-conversion>.sfc --cover-movie recordings/<name>.ymv

| recording | frames | recorded on | covers |
|---|---|---|---|
| `user-play1.ymv` | 9,112 | `cover39.sfc` | general play on the v8-era window conversion |
| `user-play2.ymv` | 6,992 | `cover40.sfc` | general play, second pass |
| `rec4.ymv` | 14,041 | `sm-conv-hdmafix2.sfc` | the longest run held — play after the HDMA-table fix |
| `rec5.ymv` | 1,718 | `sm-conv-final.sfc` | short confirmation run on the v8 candidate |
| `ridley-no-damage.ymv` | 11,268 | `sm-sa1-v26.sfc` | the Ridley fight: projectile/enemy tables on the abandoned home (bullets did no damage); 2,417 instructions newly covered |
| `escape-stuck.ymv` | 6,048 | `sm-sa1-v27.sfc` | the Ceres escape from Ridley's room: `$90:E200 LDA $0DD0` re-opened (§4f's v20) |
| `plm-halt.ymv` | 7,662 | `sm-sa1-v28.sfc` | through Ridley's room into the falling-tile room: the level-pointer class (§4g); a hung run, safe to harvest |
| `stock-escape-anchored.ymv` | 13,585 | `sm.sfc` (anchored) | STOCK, Ridley through the escape to the landing site; anchored to a menu state, so cover-pair only |
| `v34-play.ymv` | 12,305 | `sm-sa1-v34.sfc` | Ceres + into Zebes (the Parlor); its coverage relocated the Zebes room-load CODE that renders the foreground |
| `v36-play.ymv` | 12,305 | `sm-sa1-v36.sfc` | the same, further; confirmed the background is DATA (a BG-record bank) that coverage does NOT reach — closed by the structural BG net instead |
| `v38-poweron.ymv` | 25,120 | `sm-sa1-v38.sfc` (power-on) | the conversion from power-on through Ceres, the escape, the Parlor and into `$9A44`, the first room with a different tileset: found the decompressor inline-destination class (§4h). As a cover pair (v39) it relocated 22 code bytes and changed nothing visible — the proof the decor was DATA, closed by the inline-destination net in v40 |
| `v40-poweron.ymv` | 27,067 | `sm-sa1-v40.sfc` (power-on) | power-on through Ceres, the escape, the Parlor, `$9A44` (correct on v40) and down into the Climb (`$96BA`), where the vertical door transition hung. In the recipe TWICE: on v40 (the scroll code, 47 sites) and, as `v40-poweron-on-v41.ymv`, on v41 (the bank-`$88` layer code the finished transition reaches). Also exposed the raw tileset-table records (§4i) |
| `v40-poweron-on-v41.ymv` | 27,067 | `sm-sa1-v41.sfc` | DERIVED: the same take with the header crc32 (offset 8) rewritten to v41's, so it binds to v41 without the global CRC bypass. The inputs diverge from v41's game after the Climb door completes (the player was pressing at a black screen), which is harmless coverage of the Climb |
| `v43-poweron.ymv` | 31,174 | `sm-sa1-v43.sfc` (power-on) | power-on through Crateria to the Blue Brinstar elevator (`$97B5`): found the enemy-header bank class (faces' sprites) and the elevator AI stall (§4j). In the recipe on v43, and as `v43-poweron-on-elevhand.ymv` on the hand-relocated `v44-elev-hand.sfc` to cover the whole elevator routine |
| `v43-poweron-on-elevhand.ymv` | 31,174 | `v44-elev-hand.sfc` | DERIVED: header crc32 rebound to the hand-relocated image (v44 with the elevator routine's 29 low-WRAM operands moved into the window by hand, §4j) |
| `v47-poweron.ymv` | 35,254 | `sm-sa1-v47.sfc` (power-on) | power-on through Crateria, down the elevator into Brinstar (`$9E9F`), where the arrival transition never finished (black screen): a PLM routine in `$84:E04A` with five long `$7E` operands raw (§4k). In the recipe on v47, and as `v47-poweron-on-plmhand.ymv` on the hand-relocated image |
| `v47-poweron-on-plmhand.ymv` | 35,254 | `v47-plm-hand.sfc` | DERIVED: header crc32 rebound to v47 with the 7 PLM-routine operands hand-relocated, so the arrival completes and the take covers the elevator's arrival branch and the PLM code past it |
| `stock-poweron-brinstar.ymv` | 137,510 | `sm.sfc` (power-on) | STOCK, 38 minutes: power-on through Ceres, the escape, Crateria, the elevator and Brinstar. As a cover pair it covered 5,745 instructions and proved 12 bank bytes in one pass — more than every conversion take combined (§4l). The template for future coverage takes |
| `stock-from-save-brinstar.ymv` | 203,465 | `sm.sfc` (anchored: `--record --srm`) | STOCK, ~56 minutes, continuing from the battery save the previous take left (`stock-from-save-brinstar.start.srm`, lifted from its end state with `--dump-srm`). The first take made with `--record --srm`: the anchor carries the powered-on machine holding that save, so it replays from the file alone (verified: 203,465 frames, no desync). Cover-pair only, like every anchored take |
| `v53-poweron.ymv` | 29,137 | `sm-sa1-v53.sfc` (power-on) | power-on down the blue elevator into Brinstar (`$9E9F`): the ride never ended (black playfield, elevator status stuck) — the bank-`$A8` elevator species' AI, raw despite the stock take having ridden it (§4m). In the recipe on v53 and, as `v53-poweron-on-elev8hand.ymv`, on the hand-relocated image |
| `v53-poweron-on-elev8hand.ymv` | 29,137 | `v53-elev8-hand.sfc` | DERIVED: header crc32 rebound to v53 with the 27 elevator operands hand-relocated, so the ride completes and the take covers the whole routine |
| `stock-bombroom.ymv` | 11,698 | `sm.sfc` (anchored: `--record --srm`) | STOCK, continued from `stock-bombroom.start.srm`: Parlor to the Bomb Torizo room and the Bomb pickup (669 instructions) |
| `stock-torizo.ymv` | 23,772 | `sm.sfc` (anchored: `--record --srm`) | STOCK, continued from `stock-torizo.start.srm`: the Bomb Torizo fight, won — the first boss the stock takes cover (2,101 instructions, 2 bank bytes; 299 bytes moved in bank `$AA`) — then back to the Parlor save |
| `stock-green-brinstar.ymv` | 78,836 | `sm.sfc` (anchored: `--record --srm`, then `--continue`) | STOCK, continued from `stock-green-brinstar.start.srm`: down the green Brinstar elevator into the main shaft, the first missiles and energy tanks, the Charge Beam (1,054 instructions; 572 bytes moved, 480 in enemy banks). The first take grown with `--continue`: the player replayed the 44,007-frame session at full speed and kept recording, so one file holds the whole playthrough |
| `stock-take0001-polls.ymv` | 12,867 polls (13,798 frames on v62) | `sm-sa1-v62.sfc`, migrated to STOCK per poll | STOCK by migration: the player's first take on the v62 conversion from the stock save (`--record --srm`), re-recorded per poll with `--repoll --repoll-poweron --srm` and replayed on the stock image with its `.start.srm` sidecar. Bank $86 projectile routines, a bank $B2 enemy, the room setup ASM writing `$7E:CD22` — the 26 stale sites of the take's garbled map and stalled door. The first **format 3** recording: one entry per controller poll, so it replays on any build (the CRC in its header is v62's; stock replays it as a cross-build take) |
| `sm-escape-poweron.ymv` | 20,807 | `sm.sfc` (power-on) | STOCK from power-on: intro, Ceres, Ridley, the whole escape to the elevator. An `--evidence-movie` in v34, not a `--movie`: it profiles the escape (proving the level pointers the walk misses AND the palette-DMA banks that otherwise render the escape black) without being verified — the escape is an RNG-forked scene the tier cannot tick-lock (§4g) |

The first four fed the v8 generation; the ones before it feed `sm-sa1-v62.bps.cmd` as cover pairs (add `--harvest-cache <dir>` to any recipe to skip replaying pairs it has seen; the output is byte-identical) (`v38-poweron` is kept as the take that found §4h's class; it is not in the recipe).
Recorded with `--record` where noted as power-on: the player opens the take
before the first frame and starts with blank battery SRAM, which is the
machine headless replays it on. Every `--record` session also writes its
battery save next to the take as `<take>.srm`; `--record --srm <that file>`
continues from it as an anchored take (the anchor carries the save), which
is how a long game is played across sessions without starting over. The
`.start.srm` files here are those starting saves, kept for the record; the
take itself does not need them. Better still, `--movie <take> --continue`
replays a take at full speed and keeps recording from its end, so one
growing file holds the whole playthrough; the continued file replaces its
predecessor in the recipe.

## The images they need

A recording without its image is inert, and the images are patched commercial
ROMs, so they cannot live here. Two of the four can be rebuilt from a recipe
in the parent directory; two cannot:

| image | rebuildable |
|---|---|
| `sm-conv-hdmafix2.sfc` | yes — `../sm-conv-hdmafix2.bps.cmd` |
| `sm-conv-final.sfc` | yes — `../sm-conv-final.bps.cmd` |
| `sm-sa1-v26.sfc` | yes — regenerate v26's recipe (the v25 `.cmd` plus the four cover pairs) |
| `sm-sa1-v27.sfc` | yes — v26's recipe plus `ridley-no-damage` |
| `sm-sa1-v28.sfc` | yes — v27's recipe plus `escape-stuck` |
| `sm-sa1-v38.sfc` | yes — `../sm-sa1-v40.bps.cmd` on the generator before the inline-destination net (`06994e4`), or apply v38's `.bps` from that commit |
| `sm-sa1-v40.sfc` | yes — apply `../sm-sa1-v40.bps` from `03c4dc7`, or v43's recipe minus its last two cover pairs and the tileset net |
| `sm-sa1-v41.sfc` | yes — v40's recipe plus `v40-poweron` on `sm-sa1-v40.sfc`, sync-only (`--wg-sync`), on the generator at `03c4dc7` (before the tileset net) |
| `sm-sa1-v43.sfc` | yes — `../sm-sa1-v43.bps` from `37cb09e` |
| `sm-sa1-v47.sfc` | yes — `../sm-sa1-v47.bps` from `c73572c` |
| `v47-plm-hand.sfc` | **no recipe** — v47 with 7 operand bytes hand-relocated (§4k); keep the image |
| `sm-sa1-v53.sfc` | yes — `../sm-sa1-v53.bps` from `e4ec19d` |
| `v53-elev8-hand.sfc` | **no recipe** — v53 with 27 operand bytes hand-relocated (§4m); keep the image |
| `v44-elev-hand.sfc` | **no recipe** — v44 (v43's recipe + `v43-poweron`, sync-only, at `37cb09e`) with 29 operand bytes hand-relocated in `$A3:9579..$9611` (§4j lists them); keep the image |
| `cover39.sfc` | **no recipe exists** |
| `cover40.sfc` | **no recipe exists** |

`cover39`/`cover40` are the root of the whole chain — both rebuildable recipes
above consume them — and no `.bps.cmd` was ever written for either. All four
live in `../generated/`, untracked; see that directory's README for md5s and a
standing reminder to back the two irreplaceable ones up off this machine.

Those recipes also consume five older surfaces, kept in `../legacy/` for that
purpose alone. With them the chain rebuilds down to `cover39`/`cover40`, and
no further.

## Still missing

Four recordings from the §4f arc were lost with a session scratchpad
(2026-08-31) and are **not** recovered. For whoever re-records them
(`docs/SM_SA1_FINDINGS.md` §4f):

- **Ridley's grab attack** — `$26:DF59 JSL $A0:A497`, byte-identical to
  stock, BRK'd into the crash trap. Recorded on v19.
- **The escape countdown** — after it starts, Samus never regains control:
  `$90:E200 LDA $0DD0` read the abandoned home; the escape flag lives at
  `$6DD0`. Recorded on v20.
- **The backtrack loader** — `$26:E877 JSL $A0:C0AE`, the room behind
  Ridley's. Recorded on v21.
- **Dying during the escape** — a different handler from dying in a normal
  room, which `scripted/sm-play-death.ymv` already covers. Recorded on v23.

Three of those four are the same shape: an uncovered `JSL $A0-$BF:addr` that
lands in MB2. A census found 51 such targets across 628 call sites. Closing
the class in the generator (harvest bank translation, then the twin-evidence
net) would retire all of them at once and make these recordings unnecessary
rather than merely lost.

## Adding one

Record it, drop the `.ymv` here, add a row above saying what it covers and
which failure it caught, and keep its image findable. One caveat, learned
expensively (§4f): a recording of a run that **crashed** poisons coverage,
because the harvest credits the crash's garbage execution to the wrong file
bytes on a >2 MiB shim-mapped image. A recording of a run that merely *hung*
is safe. Until the harvest bank translation is fixed, do not pass a crashed
recording as a cover surface.

## Per-poll takes and start saves

A **format 3** take (`version_polls` in `src/frontends/movie.zig`) holds one
entry per controller poll instead of one per frame: the pad holds an entry
until the game reads it, so a lag frame consumes nothing and the same take
replays on any build whose logic is behaviorally the same — which is what
the verifier certifies. Every take the player records now is format 3;
`yamabuki-headless <image> --movie <v1 or v2 take> --repoll <out.ymv>`
migrates an old one (add `--repoll-poweron --srm <save>` for a take whose
anchor was a powered-on machine with that save loaded).

`<take>.start.srm` beside a take is the battery save it began from; every
replay path (the headless, the player's `--movie`, the takes screen, the
harvest) loads it before the first frame. A power-on take with a start
save carries no machine state, so unlike an anchored take it crosses
builds. The `.start.srm` files of the anchored stock takes above are
documentation copies; those takes replay by their anchors.
