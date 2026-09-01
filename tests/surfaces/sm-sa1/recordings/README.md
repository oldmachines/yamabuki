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

All four fed the v8 generation. They are **not** in `sm-sa1-v25.bps.cmd`,
which passes the scripted surfaces only — see the parent README.

## The images they need

A recording without its image is inert, and the images are patched commercial
ROMs, so they cannot live here. Two of the four can be rebuilt from a recipe
in the parent directory; two cannot:

| image | rebuildable |
|---|---|
| `sm-conv-hdmafix2.sfc` | yes — `../sm-conv-hdmafix2.bps.cmd` |
| `sm-conv-final.sfc` | yes — `../sm-conv-final.bps.cmd` |
| `cover39.sfc` | **no recipe exists** |
| `cover40.sfc` | **no recipe exists** |

`cover39`/`cover40` are the root of the whole chain — both rebuildable recipes
above consume them — and no `.bps.cmd` was ever written for either. Keep those
two `.sfc` files wherever you keep the stock ROM. If they are lost,
`user-play1`/`user-play2` become unusable and the other two recipes stop
running, even though every `.ymv` here survives.

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
