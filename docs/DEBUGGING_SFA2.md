# Debugging Street Fighter Alpha 2: a stuck-cart case study

How a black screen that looked like an S-DD1 bug turned out to be a missing
65816 interrupt behaviour, and the diagnostic path that got there. Written up
because this was the third pass through the same playbook (F-Zero's HVBJOY
flag, then the issue-28 batch, then this) and the method is now worth naming.
The fix itself is PR #89 / issue #88; this is the story of finding it.

## The setup

Street Fighter Alpha 2 (Europe) is one of exactly two S-DD1 titles. The chip
had just landed (PR #86) with Star Ocean as its empirical anchor and an
honest caveat in the PR: *SFA2 was never tested — no dump was available.*
When a dump appeared, the expectation was a quick confirmation run. Instead:

```
$ yamabuki-headless sfa2.sfc --frames 900 --ppm out.ppm
900 frames, 256x224, hash=045b5aaabee52325, audio=... (peak 0)
```

`045b5aaabee52325` is the all-black framebuffer hash. Black at 300, 600,
900, and 1800 frames. The obvious suspect was the brand-new chip. The
obvious suspect was wrong, and the interesting part is how cheaply that was
established.

## Step 1: eliminate the obvious axes (minutes)

Two loops, four runs: both cores (`--accurate`), both regions (`--region
ntsc|pal`). All four black. That rules out a fast-core-only shortcut and a
PAL/NTSC detection problem before any real digging — the failure is in
something both cores share.

## Step 2: what is the CPU doing? (the profiler)

`--sa1-report --skip 0 --frames 300 --hot` earns its keep on any stuck cart,
not just SA-1 candidates:

```
CPU utilisation   mean 1%   median 0%
hottest loops:
   $00f701 / $00f6fe / $00f703   ...  idle     <- a 3-instruction spin
   $c0002e, $c0003b, ...         ...  WORK     <- boot ran fine from $C0
verdict: the game never read the controller
```

Two facts fall out immediately. First, boot code executed from bank `$C0` —
**the S-DD1 window works** (without it, the reset path `JML $C0:0000` would
have died in open bus, which is exactly how Star Ocean used to fail).
Second, the main thread is parked in a tiny loop at `$00:F6FE`.

## Step 3: what is it waiting for? (the MMIO histogram)

A 20-line temporary histogram in `slowRead` — count reads of `$2100-$21FF`
and `$4200-$43FF`, dump periodically — answers "what register is the wait
loop polling" for any cart in one run:

```
--- MMIO reads at 1,000,000:
    $4210: 999,200        <- RDNMI, 99.9% of all MMIO traffic
    $4212, $4218-$421B: 16 each per frame   <- an NMI handler's housekeeping
```

And the write side: `INIDISP=$80` (force blank) rewritten every frame,
**zero** writes to `$4800-$4807`. The game never armed a single S-DD1
decompression — it hung long before graphics. Whatever this was, the
decompressor could not be the cause. (Compare the issue-28 carts: Top Gear
& co. showed `$2140/$2141` — APU; Super SWIV showed `$4210` as innocent
frame-pacing. The histogram's shape is the diagnosis.)

## Step 4: read the actual code (ROM-byte disassembly)

LoROM offset arithmetic plus a hex dump is all it takes. The spin:

```
$00:F6F7  LDA $4210 / AND #$80 / BNE   ; drain: wait for bit7 clear
$00:F6FE  LDA $4210 / AND #$80 / BEQ   ; edge-wait: spin until bit7 set  <- stuck
```

The NMI vector chain (`$00:FFE0 → JML $C0:01A4`) leads to a handler that
pushes registers, forces blank, increments a frame counter, **reads `$4210`
itself** (the ack), reloads NMITIMEN from a shadow, and dispatches per-mode
work — one branch of which writes INIDISP from direct-page `$B6`, the byte
that never leaves `$80`.

So: the main thread edge-waits on the RDNMI flag *while NMI is enabled and
the handler consumes that same flag*. On an emulator that delivers the NMI
at the vblank boundary, the handler's ack **always** wins; the poll reads 0
forever; the game never advances to the code that would set `$B6`, init
sound, or touch the S-DD1.

## Step 5: why does hardware survive this?

This is the step where "the game is buggy" becomes "the emulator is missing
a behaviour". The 65816 samples interrupts during an instruction's
second-to-last cycle. An NMI edge that lands at an instruction boundary —
or during an instruction's final cycle — is taken only after **one more
instruction** completes. So when vblank hits mid-spin, there is a window
(the early cycles of `LDA $4210`, plus the final cycle of the branch whose
*next* instruction is that `LDA`) in which the poll's read returns bit7=1 —
clearing the flag but not the already-latched NMI — before the handler
ever runs. Roughly a 40% win per frame; the game exits the wait within a
few frames on real hardware, every time, and nobody at Capcom ever saw the
race they shipped.

The fast core raises vblank at a scanline boundary, which is *always* an
instruction boundary, and delivered the NMI before the next instruction.
Deterministically zero-percent win rate. The accurate core shared the same
per-line arming, hence step 1's result.

## The fix (~10 lines)

`Cpu.setNmi` grants a one-instruction service grace when the CPU is running
(`nmi_delay`), consumed by the next `step()`. WAI is the deliberate
exception — it exists to remove the sampling latency, so a woken CPU
services immediately. See `src/core/cpu/wdc65816.zig`.

Result: SFA2 boots — CAPCOM logo, intro, and a full attract-mode fight, all
of it decompressed through the S-DD1, closing the last untested path of
PR #86.

## Blast radius, measured

The grace shifts NMI delivery by one instruction for *every* NMI-using game,
so the golden gates were the referee, not an afterthought:

- 102 homebrew goldens, both cores: **zero churn** — hashes, steps, cycles
  all identical. The krom ROMs wait via WAI or NMI-off flag polls, which the
  grace does not perturb. SST (5.4M cases), libretro, fuzz, bench: green.
- 8 of 12 commercial goldens unchanged — including Star Ocean, so the S-DD1
  path stayed byte-identical.
- 4 re-minted after eyeballing each still renders its exact pinned scene one
  interleaving step apart. Three of the four moved only in the **audio**
  hash; framebuffers identical. The narrowness of the drift is itself
  evidence of a minimal timing nudge.
- SFA2 pinned as the 13th commercial golden (chipset `$43`; both S-DD1
  board configurations now exercised).

## Two traps from writing the regression test

The console-level test boots a miniature of SFA2's race: an edge-wait main
thread against an acking NMI handler. It failed twice, both times teaching
something about the race itself:

1. **A fixed-length handler phase-locks.** The emulator is exactly
   deterministic and the frame is exactly periodic, so a constant-cycle
   handler pins the poll loop to one phase — possibly a losing one, forever.
   Real handlers vary in length frame to frame (SFA2's dispatches per-mode
   work), which is precisely why real games drift into the winning window.
   The test handler burns a frame-varying delay for the same reason.

2. **The handler must preserve registers.** A minimal `INC/LDA $4210/RTI`
   handler clobbers A between the poll's winning `LDA` and its branch —
   poisoning the very race under test. Real handlers push their registers;
   the miniature has to as well.

## The playbook, distilled

For the next cart that boots to black:

1. `--frames N --ppm` at several N, both cores, both regions. Eliminate the
   cheap axes first. (And know what `peak` measures: it's the *audio* peak —
   measure the framebuffer from the PPM.)
2. `--sa1-report --skip 0 --hot`: utilisation shape + wait-loop anchor.
3. Temporary MMIO read/write histogram in the bus slow paths: *what* is it
   polling, and what did it configure before hanging?
4. Disassemble the anchor and the interrupt vectors from ROM bytes. Name the
   exact wait.
5. Ask why hardware survives that wait. The answer is the missing behaviour
   — fix that, never the symptom.
6. Let the golden gates measure the blast radius, and eyeball anything that
   re-mints.

Every stuck cart so far — HVBJOY's H-blank flag, the APU deferred boot step,
IPL re-entry, the Super FX linear banks, and now the NMI sampling grace —
was one missing hardware behaviour wearing a black screen as a disguise.
