# SNES surround sound — collected insights

A running log of first-hand accounts and technical findings about surround
sound on the SNES, and what each one implies for Yamabuki's S-DSP (M5b) and
audio output path. Append new entries at the bottom of the log with a date
and source link.

## The short version

A handful of SNES games encode **Dolby Surround** (matrix surround, decoded
by Dolby Pro Logic) in their ordinary stereo output. The trick is entirely
in the S-DSP's **signed volume registers**: a voice played with equal and
*opposite* left/right volumes (L = −R) is out of phase between the channels,
and a Pro Logic decoder steers out-of-phase content to the rear/surround
speakers (in-phase content goes to the center). No extra hardware, no extra
channels — the surround field rides inside the normal stereo mix.

For an emulator this means surround support is not a feature to build; it is
a property to **not destroy**. If the DSP mixes with correct signed
arithmetic and the output path preserves inter-channel phase, every
surround-encoded game works through a real (or software) Pro Logic decoder
exactly as it did in 1992.

## Insight log

### 1. First-hand: King Arthur's World was (probably) first (Nov 1992)

Source: [@aerobatic on X](https://x.com/aerobatic/status/2027034407668748315)
(Argonaut; King Arthur's World team), 2026.

> We reverse engineered the audio chip in the SNES and figured out how to do
> realtime Dolby Surround by playing sound effects out of phase to encode
> the audio in a way that Dolby Prologic (Surround) decoders would be able
> to process it correctly into Left Center Right and Rear, and used the
> technique in the King Arthur's World game on SNES. Probably the first game
> on SNES to have surround sound — shipped in Nov 1992 as Royal Conquest in
> Japan, and King Arthur's World in the west.

Notes from the same account: playback requires a Dolby Pro Logic decoder
(standard in A/V amps of the era, absent from modern built-in TV audio,
superseded by AC-3 and later Atmos); Samurai Shodown, often cited for SNES
surround, shipped much later (1994).

Corroboration:
[Martin P. Simpson (KAW audio) on the Dolby work](https://www.martinpsimpson.com/2011/09/first-king-arthur-and-dolby-surround.html)
— Dolby asked Argonaut to fit Surround-encoded audio late in development;
by driving the sound chip's volume registers the engine positioned sounds
in 3-D (the weather effects and opening chords move around the room), and
the game shipped Dolby-branded.

### 2. The mechanism: signed S-DSP volumes are phase inversion

Sources:
[NESdev BBS — "SPC inverse Voice Phase with negative volume MSb set"](https://archive.nes.science/nesdev-forums/f12/t10422.xhtml),
[Anomie's S-DSP doc](http://www.gamepilgrimage.com/sites/default/files/SystemSpecs/SNES/anomie/apudsp.txt),
[Copetti, SNES architecture](https://www.copetti.org/writings/consoles/super-nintendo/).

The DSP's per-voice volumes (`VxVOLL`/`VxVOLR`), master volumes
(`MVOLL`/`MVOLR`), echo volumes (`EVOLL`/`EVOLR`), and the 8 echo FIR
coefficients are all **signed** (two's-complement i8). A negative volume
multiplies the sample stream by a negative value — i.e. inverts its phase in
that channel. "Volume $80–$FF sends the voice to the back speakers" is the
sound-driver-eye view of the same fact. This is exactly the Dolby Surround
matrix: rear channel = L−R (out of phase), center = L+R (in phase). Game
encoders are the "poor man's" version — plain inversion without the
band-limiting/noise-reduction of a studio Dolby encoder — but Pro Logic
decodes it fine.

### 3. Historically, emulators and SPC players got this wrong

Source: the NESdev threads above, and
[SNES9x forum — "SNES9X and Dolby"](https://www.snes9x.com/phpbb3/viewtopic.php?t=28999).

Multiple reports that older emulators, SPC players, and trackers bypassed or
clamped negative volumes (treating them as unsigned, or taking magnitudes),
which silently discards the surround matrix while sounding *almost* right in
plain stereo. This is the classic accuracy trap: the bug is inaudible on the
equipment most people test with.

### 4. Known surround-encoded games (regression candidates)

Sources:
[ConsoleMods wiki — SNES audio](https://consolemods.org/wiki/SNES:Audio_Information),
[shmups forum surround list](https://shmups.system11.org/viewtopic.php?f=6&t=51493),
[byuu's board — Dolby Surround games](http://helmet.kafuka.org/byuubackup/viewtopic.php@f=3&t=4714.html).

King Arthur's World, Vortex (also Argonaut), Jurassic Park and Jurassic
Park 2 (mastered in Pro Logic), Super Turrican 1/2, Fatal Fury Special,
Samurai Shodown, Art of Fighting, Super Castlevania IV, Secret of Mana,
Star Fox, Indiana Jones' Greatest Adventures, The Flintstones. Some games
(e.g. Final Fantasy VI) pass a matrixed signal through their ordinary
"stereo" setting without advertising it.

## What this means for Yamabuki

Requirements the M5b S-DSP must meet (and keep meeting):

- **Signed mixing everywhere.** `VxVOLL/R`, `MVOLL/R`, `EVOLL/R`, and the
  echo FIR coefficients are i8; every multiply is signed and never clamped
  to positive or replaced by a magnitude. This is the whole feature.
- **The echo path carries surround too.** Ambience (KAW's weather) is
  steered rear via signed echo volume/FIR — the echo unit can't be an
  unsigned approximation.
- **Preserve phase end-to-end.** Keep true stereo out of `audioSamples()`:
  no mono downmix, no per-channel-different filtering, no "stereo
  enhancement" post-effects in the default path. Any resampling must apply
  the identical filter to both channels so L−R content survives.
- **Regression idea.** The planned golden audio hash (FNV over raw i16
  frames) is inherently phase-sensitive, so it locks this for free once
  minted. A targeted check — L−R vs L+R energy over a King Arthur's World /
  Vortex capture should show significant anti-phase energy — would make a
  surround regression legible rather than just "hash changed".
- **User-facing note (frontends, M6/M7).** Surround needs a Pro Logic
  decoder downstream (A/V receiver, or a software matrix decoder); modern
  TVs won't decode it, and on headphones anti-phase content just sounds
  "wide". Worth a line in the libretro/SDL docs so the feature is
  discoverable.
