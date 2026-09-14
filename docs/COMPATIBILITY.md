# Commercial-game compatibility

The first survey of the emulator against the canonical SNES library, and what it found that a hundred passing homebrew goldens could not. Moved here from the README.

![Twenty SNES games running in Yamabuki with the crt-royale shader](../site/shots/gallery.png)

*Super Metroid · Turtles in Time · Super Street Fighter II · Kirby Super Star ·
Donkey Kong Country · Super Mario World · EarthBound · Super Castlevania IV ·
Mega Man X · Contra III · Super Mario Kart · Final Fantasy VI — captured with
`--shot`, rendered through crt-royale on an RTX 2070.*

These are the first commercial games Yamabuki has ever run. Every golden test in
this repo is homebrew (PeterLemon, krom), and it turns out that proves less than
it looks like it does.

**Twenty of the canonical SNES library, run for 3,700 frames each:**

| | |
|---|---|
| **16 / 20** | boot and render |
| **2 / 20** | Donkey Kong Country 2 (E) and Secret of Mana (E) are PAL ROMs; on the NTSC-hardcoded core they used to correctly print *"THIS GAME PAK IS NOT DESIGNED FOR YOUR SUPER NES"*. PAL support (region auto-detected from the cart header, `--region` to override; 312 lines/frame, 50 Hz pacing, STAT78's PAL bit) now lets them play with `--region auto`. |
| **4 / 20** | **never render a frame** — Chrono Trigger, F-Zero, Super Mario RPG, Yoshi's Island. Three sit on a forced-blank screen with an identical static framebuffer hash from frame 300 to frame 6,000: the CPU is stuck before it ever enables the display. |

F-Zero was the one that stung. LoROM, no coprocessor, a launch title — if that
does not boot, this is not an exotic edge case.

**F-Zero now boots**, and the thing that found the bug was the frame-budget
profiler below, which was built for something else entirely. It reported F-Zero
sitting at **0% CPU utilisation** — the CPU was not crashed or lost, it was
*waiting*, in a loop, forever. `--hot` gave the address, and the two instructions
there gave the answer:

```
$8616:  BIT $4212      ; HVBJOY
$8619:  BVC $8616      ; loop until V is set
```

`BIT` drops bit 6 of the operand straight into the V flag, and **bit 6 of HVBJOY
is the H-blank flag**. Yamabuki's `in_hblank` was declared, initialised to false,
read by `readHvbjoy` — and *assigned by nobody*. The flag was permanently zero, so
`BVC` looped until the heat death of the universe. Deriving it from the beam is
four lines, and F-Zero renders its title screen, plays its music, and runs its
Mode 7 attract demo. All 100 goldens and the perf baselines are unchanged.

Twelve more carts still sit at 0% utilisation and never poll the pad — the same
signature, a different cause each. That is a much better place to start than "it
renders a black screen", and it is what M13 now has to work with. The same fix
also revived **Super Mario Kart's Mode 7 attract demo** — the "flat yellow
field" from the first survey was the game parked on `BIT $4212 / BEQ` at
`$80:8B19`, waiting for the same H-blank flag; with the bit real, the demo runs
its full split-screen Mode 7 race.

None of this was visible from 100 passing golden ROMs, because all 100 are
homebrew.
