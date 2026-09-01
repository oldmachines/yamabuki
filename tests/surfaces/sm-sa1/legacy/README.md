# Legacy surfaces

The five `.ymv` files the v8-era cover recipes consume. They are committed for
exactly one reason: without them `../sm-conv-hdmafix2.bps.cmd` and
`../sm-conv-final.bps.cmd` cannot run, and those two recipes are what rebuild
two of the four cover images the player recordings pair with.

They sit apart from `../scripted/` because they do **not** share its property:
`tools/sm_surfaces.py` does not emit these, and nothing else does either. No
code regenerates them. In replaceability they are closer to
`../recordings/` — losing one costs a recipe permanently.

As *verification* surfaces they are superseded. `../scripted/` covers strictly
more: `sm-attract36k` (36,000 frames) subsumes what `sm-start` and `sm-game`
reach, and `sm-play-death` and `sm-titleskip` go where none of these do. Use
these only to rebuild the cover chain.

| surface | frames | bound to | role |
|---|---|---|---|
| `sm-start.ymv` | 3,600 | stock | stock-side `--movie`; the v8 profile window |
| `sm-game.ymv` | 15,000 | stock | stock-side `--movie` |
| `mash-st.ymv` | 4,000 | stock | `--evidence-movie`; Start+A+B bursts every 20 frames |
| `newg2-st.ymv` | 13,000 | stock | `--evidence-movie`; new-game path |
| `newg2-cv.ymv` | 13,000 | `cover40.sfc` | `--cover-movie`, paired with `cover40` |

`sm-start.ymv`'s 3,600 frames are worth knowing about: that is the window v8's
`dropped frames 25 -> 25` was measured over, which is too short to reach the
demo gameplay where the conversion's lag appears. `sm-sa1-v25.bps.cmd`
profiles 36,000 and reports `2342 -> 28969` over the same game. The two
numbers are not comparable, and the difference between them is this file.
