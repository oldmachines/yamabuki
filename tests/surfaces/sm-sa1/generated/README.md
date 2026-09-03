# Generated images

The conversion images the cover pairs are recorded against. **Not tracked** —
the repo-wide `*.sfc` rule in `.gitignore` keeps them out, and this repo is
public: these are patched commercial ROMs and cannot ship here. This directory
exists so they have one findable home in the tree instead of a scratchpad.

| image | rebuildable | paired recording |
|---|---|---|
| `cover39.sfc` | **no recipe exists** | `recordings/user-play1.ymv` |
| `cover40.sfc` | **no recipe exists** | `recordings/user-play2.ymv` |
| `sm-conv-hdmafix2.sfc` | yes — `../sm-conv-hdmafix2.bps.cmd` | `recordings/rec4.ymv` |
| `sm-conv-final.sfc` | yes — `../sm-conv-final.bps.cmd` | `recordings/rec5.ymv` |
| `sm-sa1-v40.sfc` | yes — `../sm-sa1-v40.bps` at `03c4dc7` | `recordings/v40-poweron.ymv` |
| `sm-sa1-v41.sfc` | yes — v40's recipe + `v40-poweron`, sync-only, at `03c4dc7` | `recordings/v40-poweron-on-v41.ymv` |
| `sm-sa1-v43.sfc` | yes — `../sm-sa1-v43.bps` at `37cb09e` | `recordings/v43-poweron.ymv` |
| `v44-elev-hand.sfc` | **no recipe** — v44 with 29 operand bytes hand-relocated (§4j) | `recordings/v43-poweron-on-elevhand.ymv` |

`cover39`/`cover40` are the root of the chain: both rebuildable recipes above
consume them, and no `.bps.cmd` was ever written for either. If they are lost,
`user-play1`/`user-play2` become inert and the other two recipes stop running,
even though every `.ymv` in this directory tree survives. **Back these two up
somewhere off this machine** (and `v44-elev-hand.sfc`, the third with no recipe). Their md5s, so a copy can be checked:

    9f20c143538d81c7f234caed06a76eb3  cover39.sfc
    8a6f708ba9ecb4f30e6476440886420e  cover40.sfc
    e93eda2a1a7b30ec7711a30c093d75f2  sm-conv-hdmafix2.sfc
    a884c94b18c9d5d069d8f62e9131f033  sm-conv-final.sfc
    655d4b3c1dae44110f410ef0d0eeee42  sm-sa1-v40.sfc
    8adb65813e5b632077f978d26442cc19  sm-sa1-v41.sfc
    2a525d63603e21e5f73a5f25a71b18a7  sm-sa1-v43.sfc
    d1b00ca4a1936e2c34e9d935bea1cbdb  v44-elev-hand.sfc

A recording is bound by CRC to its image at offset `0x08`; pair them wrongly
and the replay refuses. See `../recordings/README.md`.
