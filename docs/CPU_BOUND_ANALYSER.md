# Is this game CPU-bound? — the SA-1 candidacy analyser

`yamabuki-headless <rom> --sa1-report` answers the question that comes before every SA-1 conversion: does a faster CPU have anything to do here? This is how it measures that, and the bugs real games found in the measurement. Moved here from the README; the flags are in [`CLI.md`](CLI.md).

```
$ yamabuki-headless "Super Mario World.sfc" --sa1-report

SUPER MARIOWORLD
  lorom, no coprocessor, SlowROM
  profiled 1800 frames (30s) after 300 boot frames

  CPU utilisation   mean 44%   median 43%   p95 62%   max 100%
  slowdown          0 of 1800 frames (0.0%)
  stalls            1 (57 frames) — loads or transitions, not slowdown

  verdict: NOT CPU-BOUND
    The CPU idles through 56% of an average frame and never falls behind.
    A faster CPU has nothing to do here.
```

This is step one of the SA-1 candidacy analyser (M12). The community around
[Vitor Vilela](https://github.com/VitorVilela7) has spent years hand-converting
SNES games to run on the SA-1 — Gradius III, Contra III, Super R-Type, and the
SMW SA-1 Pack under a large share of modern hacks. Each one is weeks of reverse
engineering, and the first thing you want to know is whether a game is worth it
at all. **A game that always finishes its logic with time to spare gains nothing
from a faster CPU**, however attractive it looks from the outside.

**You cannot measure that the obvious way.** On a SNES the CPU burns *exactly*
the same number of master cycles every frame — the scheduler runs it to the
scanline's clock target, always. It never "overruns its budget"; it never gets the
chance. When a game is too slow, what happens is that its main loop fails to come
round before the next vblank and a frame is dropped.

So the budget is measured by its complement: not the time the CPU spent working,
but the time it spent **waiting**. Idle time is headroom, and headroom is exactly
what an SA-1 buys back.

## A loop is a wait if it goes nowhere

It touches a fixed handful of addresses over and over, instead of reading and
writing its way *through* memory. That distinction is the whole difficulty:

```
wait:  LDA $10        wait:  LDA $4212      sum:  LDA $2000,y
       BEQ wait              BPL wait             ADC $04
                                                  INY
$8166: JSL check                                  CPY #$1000
$816A: BRA $8166                                  BNE sum
```

The first three are waits. The fourth is a checksum — tight, repetitive, and it
writes nothing for four thousand iterations — and it is *working*. Its tell is
that it **walks**: a different address every pass. A wait watches the same one or
two forever, because watching one spot for something else to change it is what
waiting *is*.

Every one of the following was a bug, and a real game found each of them. None of
them were visible from reasoning about it.

- **A loop is found by return, not by proximity.** The commonest SNES main loop is
  a *call* in a loop — that `JSL check` / `BRA` above is Contra III's — and its
  seven addresses are spread over 6 KiB. Bounding the *span* of the program
  counter rejects it outright, along with every other subroutine-shaped wait ever
  written. **Contra III came out at 100% utilisation on every frame, title screen
  included**, which is what gave it away.
- **Stack traffic is not a side effect.** That `JSL` pushes three bytes every pass,
  so a naive "writes nothing" test throws the loop out again. A JSL/RTL pair leaves
  the machine exactly as it found it, so pushes and pulls bypass the profiler's
  data path entirely.
- **A wait is allowed to write.** The classic SNES idiom stirs a random seed while
  it spins — that is how a game seeds randomness from how long you took to press
  Start. Tetris & Dr. Mario's wait is exactly that, and it read **100% busy on
  every frame** until writes were allowed:

  ```
  $86ED:  JSR $8DAD      ; $9E = $9E * 5 + $7113   — advance the RNG
  $86F0:  LDA $0BA6      ; check the flag
  $86F3:  BPL $86ED
  ```

  Writing one fixed word changes nothing that matters; writing your way through a
  buffer does. The one thing a wait may never do is poke a **hardware register** —
  that is what stops a loop kicking off DMA (`STA $420B`, the same address every
  pass) from slipping through the same test.
- **The unit of judgement is one pass, not one window.** Judge a whole window of
  instructions at once and working code that merely *precedes* a wait — a memory
  clear, say — condemns the wait that follows it, because the window saw a write.
  Super Mario World's idle time vanished completely.

One rule is worth recording as a dead end, because it is plausible and wrong:
*"a wait cannot exit on its own, so a loop ended by an interrupt was waiting."*
Both halves fail. A loop polling `$4212` exits under its own power the moment the
hardware sets the bit — no interrupt needed — and *any* long-running loop is
eventually interrupted by the vblank NMI, checksums included. It did not even
exclude the case it existed to exclude.

## Slowdown is not a stall

The independent check on all of the above is the **lag frame**: a game polls the
controller once per main-loop iteration, so a frame in which it never read the pad
is a frame its logic did not come round. That is what a player actually sees, and
it comes from a completely different signal than the idle accounting, so agreement
between the two is real corroboration.

But dropped frames come in two kinds. Slowdown is a game failing to keep up *while
it is still playing* — it drops one frame in two or three, so its runs are short.
An unbroken fifth of a second with no input poll is a game doing something else:
decompressing a level, running a fade. Both pin the CPU; only one is a reason to
reach for an SA-1. Super Mario World's attract demo drops 66 frames in 1800 —
3.7%, comfortably over any "CPU-bound" threshold — but **57 of them are one
unbroken run**, which is a level transition. Conflating those is how you talk
yourself into a conversion nobody needs, so the report counts them apart.

## What it still gets wrong

A wait the profiler fails to recognise reads as work, so **utilisation is an upper
bound** — real idle is at least what is reported. And a game that polls the pad
inside its **NMI handler** polls every frame whatever its main loop is doing, so it
can never register a dropped frame at all: **slowdown is a lower bound.** The two
errors point in opposite directions, so they bracket the truth rather than
compounding — which is the main reason for keeping both signals.

The upper bound on utilisation is the direction that *flatters* a conversion,
which is exactly why the tool prints the caveat every run instead of rounding in
its own favour. And on its own the profiler presses no buttons: what gets
profiled is the attract loop, which for most carts is real gameplay and for some
is a title screen idling at 12%.

**`--movie` is the answer to that**, and deliberately the only one: a recorded
playthrough, replayed from power-on and verified against the hashes it carries,
so the profile is measured over real gameplay rather than whatever the demo
happened to exercise. Cruder substitutes were tried and removed. A held button
mask is not a player — it never taps, aims, or reacts, so on a game that
edge-detects presses it does nothing at all — and resuming a save state fixes
where a run begins without supplying anyone to play it, so the scene winds down
within seconds. Both invite a number that reads like gameplay and is not. The
report says which of the two modes drove it, so it is never mistaken for the
other.

The profiler is a third comptime instantiation of the core (`ProfilingConsole`),
so the shipped emulator carries no branch for it — the same trick as `accuracy`.
Emulation under it is bit-identical: 5,120,000 SingleStepTests cases, 100 golden
ROMs, and the deterministic bench baselines all unchanged.

## Seventy-six carts, ranked

Run across a whole library, 1,800 frames each. The interesting result is how few
games are candidates:

| | |
|---|---|
| **7** | **CPU-bound** — lose ≥2% of their frames to slowdown, spread through the capture rather than bunched into loads |
| **25** | drop frames occasionally |
| **13** | at the limit — never late, but nothing to spare |
| **14** | not CPU-bound — a faster CPU has nothing to do |
| **13** | **0% utilisation, never poll the pad** — not slow, *stuck* (see F-Zero, above) |

The top of the list:

```
game                    map    chip  FastROM  mean  med  p95  slowdown
JUNGLE STRIKE           lorom  -     yes       12%   2%  77%    50.1%
FINAL FANTASY VI        hirom  -     yes       17%  15% 100%     6.8%
PALADIN'S QUEST         lorom  -     -         12%   2% 100%     3.3%
KIRBY SUPER STAR        lorom  sa1   -         20%  12% 100%     2.3%
LIVE A LIVE             hirom  -     -         22%  17% 100%     2.1%
SUPER R-TYPE            lorom  -     -         53%  54%  82%     2.1%
TURTLES IN TIME         lorom  -     -         30%  22% 100%     2.0%
```

Two of those are corroboration rather than discovery, and that is the point:
**Super R-Type and Contra III are both games Vitor Vilela actually converted** —
he chose them by playing them, years ago, and the profiler independently ranks
them among the most CPU-starved carts in the library. Kirby Super Star is the
joke: it *already has* an SA-1 and still drops frames.

Jungle Strike loses **half its frames**, which is a scale of slowdown nobody
should have to discover by feel.
