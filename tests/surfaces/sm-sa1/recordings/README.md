# Player recordings

Irreplaceable. Nothing regenerates a recording of a person playing.

| recording | covers | failure it closed |
|---|---|---|
| _(empty — the originals were lost with a session scratchpad, 2026-08-31)_ | | |

The four that were lost, for whoever re-records them (`docs/SM_SA1_FINDINGS.md` §4f):

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
