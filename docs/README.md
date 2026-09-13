# Documentation index

Start with the top-level [README](../README.md) for what the project is and
how to build and play. Then:

| Read this | When you want |
|---|---|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | The module map, how the core is put together, the design decisions, how to add a chip. |
| [`TESTING.md`](TESTING.md) | Every gate (`zig build test-*`), what each proves, where the test data comes from, how to mint goldens. |
| [`CLI.md`](CLI.md) | The complete flag reference for `yamabuki-headless` and `yamabuki-sdl`, the hotkeys, the libretro core option, and copy-pasteable recipes. |
| [`SHADERS.md`](SHADERS.md) | The CRT shader pipeline: why presets are transpiled on the build host, the three GL profiles, what a skipped preset means. |
| [`COMPATIBILITY.md`](COMPATIBILITY.md) | The commercial-game survey: which of the canonical library boots, and the F-Zero bug that homebrew goldens could not see. |
| [`CPU_BOUND_ANALYSER.md`](CPU_BOUND_ANALYSER.md) | How `--sa1-report` decides whether a game is CPU-bound, and every wrong rule a real game corrected. |
| [`AUDIO_SURROUND.md`](AUDIO_SURROUND.md) | Why the S-DSP mixes signed and phase-exact, and what Dolby Surround games do with that. |
| [`ROADMAP.md`](ROADMAP.md) | Goals, the milestone table, the ROM-patch-layer plan (M12) and its refusal ladder, performance engineering, risks. |
| [`AUDIT_2026-09.md`](AUDIT_2026-09.md) | The September 2026 whole-repository audit: what was fixed, what was measured, and the ranked list of what is still worth doing. |

## The SA-1 conversion work

The conversion of Super Metroid to the SA-1 is the largest single effort in
the tree and has its own documents. They are long because they are the
record of the campaign; read them in this order.

| Read this | When you want |
|---|---|
| [`SA1_CONVERSION_LEARNINGS.md`](SA1_CONVERSION_LEARNINGS.md) | The methodology (sections 1 to 7): the architecture, the rewrite rules, the profiler, coverage, the verification stack, the guards, and how to debug a conversion. Sections 8 onward are the dated chronicle. |
| [`SM_SA1_FINDINGS.md`](SM_SA1_FINDINGS.md) | Super Metroid specifically: section 0 is the synthesis and the current status; sections 4a to 4r are the bug-hunt chronicle, one per shipped version. |
| [`../tests/surfaces/sm-sa1/README.md`](../tests/surfaces/sm-sa1/README.md) | The shipped patches, their exact command lines, and the recorded takes that verify them — and why those recordings are treated as code. |
| [`DEBUGGING_SFA2.md`](DEBUGGING_SFA2.md) | A worked debugging session on the S-DD1 (Street Fighter Alpha 2). |

Where two documents state the current status, `SM_SA1_FINDINGS.md`
section 0 wins for Super Metroid and the milestone table in `ROADMAP.md`
wins for everything else.

## Decks

`yamabuki-design-notes.deck.html` is the design-notes deck the landing page
publishes as `/deck.html`. The repository root's `deck.html` is a separate,
newer deck about the SA-1 conversion work.
