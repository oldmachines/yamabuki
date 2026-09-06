//! Headless runner: load a ROM, run N frames, print the framebuffer and audio
//! hashes, and optionally dump the final frame as a binary PPM (P6) and the
//! whole audio stream as a WAV, both for eyeballing.
//!
//!   yamabuki-headless <rom.sfc> [--frames N] [--ppm out.ppm] [--wav out.wav]
//!                     [--accurate] [--patch p.bps|p.ips] [--save-patched out.sfc] [--wide N]
//!   yamabuki-headless <rom.sfc> --sa1-report [--frames N] [--skip N] [--json] [--hot]
//!   yamabuki-headless <rom.sfc> --gen-fastrom-patch [--out p.bps] [--frames N]
//!
//! This is the primary in-development verification tool: `--ppm`/`--wav` give
//! output to inspect, and the printed hashes are what `zig build test-roms`
//! locks against.
//!
//! `--patch` applies a BPS or IPS patch to the ROM in memory at load — the file
//! on disk is never touched. BPS verifies the source CRC before applying (a
//! patch for the wrong ROM revision is an error naming both checksums) and the
//! target CRC after; IPS has no checksums, and says so. `--save-patched`
//! writes the patched image and exits without emulating.
//!
//! `--auto-patch` looks the loaded ROM up in the committed registry
//! (patches/registry.zon, keyed by content hash) and applies its registered
//! patch from `--patch-dir` — after verifying the patch file's own sha256
//! against the registry. A missing patch prints where to fetch it and runs
//! unpatched; the emulator never downloads anything.
//!
//! `--sa1-report` is the SA-1 candidacy analyser (M12): it runs the game with
//! the frame-budget profiler compiled in and answers the question that comes
//! before every other one — *is this game CPU-bound at all?* — then ties
//! everything into a graded `conversion:` verdict. `--routines` adds the
//! detail tables: which routines cost the frame, each hot routine's WRAM
//! working set, MMIO blockers, DMA/HDMA arms, and page-sharing with the rest.
//! See `core/profile.zig` for what is being measured and why.
//!
//! `--gen-fastrom-patch` makes the emulator *write* a patch: it derives the
//! FastROM transformation mechanically (see `core/cart/patchgen.zig`), runs
//! the game unpatched and patched, and only when every frame's framebuffer
//! and the whole audio stream are identical — and MEMSEL stayed enabled —
//! encodes the result as a BPS (default: `<rom>.bps` beside the ROM, the
//! softpatch convention the SDL player discovers by name). A patch that
//! cannot be verified is never written; every refusal names its reason.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("snes_core");
const profile = core.profile;
const util = @import("util");

/// `--region ntsc|pal|auto`: override the header-detected region. `auto`
/// (the default) uses the cart header's region byte.
const RegionArg = enum { auto, ntsc, pal };

const Args = struct {
    rom: []const u8,
    frames: ?u32 = null,
    ppm: ?[]const u8 = null,
    /// `--ppm-range start:count:prefix`: DIAGNOSTIC. Dump each frame in
    /// [start, start+count) as `<prefix>NNNNN.ppm` (5-digit, zero-padded) —
    /// a frame window to assemble into a recording of a moving effect the
    /// single final-frame `--ppm` cannot show.
    ppm_range_start: ?u32 = null,
    ppm_range_count: u32 = 0,
    ppm_range_prefix: []const u8 = "frame",
    wav: ?[]const u8 = null,
    accuracy: core.Accuracy = .fast,
    region: RegionArg = .auto,
    patch: ?[]const u8 = null,
    save_patched: ?[]const u8 = null,
    /// Look the loaded ROM up in patches/registry.zon by content hash and
    /// apply its registered patch from `patch_dir` (verified, never fetched).
    auto_patch: bool = false,
    patch_dir: []const u8 = "patches",
    /// Pin MEMSEL to 1 (FastROM cartridge timing for a SlowROM game), gated
    /// by patches/fastrom-compat.zon: `broken` refuses, unknown warns.
    auto_fastrom: bool = false,
    sa1_report: bool = false,
    /// Frames to run before the profiler starts counting. Boot is not gameplay:
    /// the game is decompressing, clearing RAM, and handshaking with the APU,
    /// and none of that is representative of the frame budget in play.
    skip: u32 = 300,
    json: bool = false,
    /// Dump the hottest loops and how each was classified.
    hot: bool = false,
    /// Steps two and three of the analyser: the per-routine cycle attribution
    /// table, and each hot routine's WRAM working set and blockers.
    routines: bool = false,
    /// Stage S1 of the SA-1 arc: export execution/access coverage from the
    /// profiled run as a bsnes-plus `-usage.bin` file (DiztinGUIsh imports
    /// it). A `--sa1-report` modifier, like `--hot`.
    usage_map_out: ?[]const u8 = null,
    /// --call-graph: where to write the routine graph (Graphviz DOT).
    call_graph_out: ?[]const u8 = null,
    /// Stage S2: print the relocation plan — the WRAM -> I-RAM/BW-RAM
    /// allocation map for the conversion verdict's hot set.
    plan: bool = false,
    /// `--wide N` (M12): extra columns rendered on each side of the standard
    /// 256, for a widescreen game patch (e.g. wide-snes) that draws into the
    /// margin. Fast core only — refused together with `--accurate`.
    wide: u32 = 0,
    /// Recorded playthroughs (.ymv) driving both pads from power-on. In a
    /// normal run one movie replays and verifies its end hashes; in the
    /// generator/report modes movies drive the profiled runs, so coverage
    /// and verification come from real gameplay instead of the attract
    /// mode. The generator accepts SEVERAL `--movie` flags: each is an
    /// input SURFACE, all of them feed one evidence/coverage union, and
    /// every one must verify — because each movie is a different world,
    /// and a surface one movie covers can be exactly the surface another
    /// displaces (measured: the movie that added stage-1 gameplay lost
    /// the attract demo, and demo-only code fell out of the rewrite).
    movies: [max_movies][]const u8 = undefined,
    n_movies: usize = 0,
    /// Per-movie: does this movie VERIFY (a surface every attempt must
    /// pass) or only contribute evidence/coverage? `--evidence-movie`
    /// adds the latter kind — a playthrough whose later stretch is
    /// UNVERIFIABLE by construction rather than broken: gameplay forks at
    /// the first RNG-divergent event (enemy RNG seeds from wall-origin
    /// counters the conversion legitimately offsets; measured: stock's
    /// ship exploded at wall 3100 while the byte-equivalent conversion's
    /// ship flew on — every later tick compares two different games). The
    /// code such a stretch covers (death sequence, continue screen) still
    /// runs in real play and still needs its rewrites.
    movie_verify: [max_movies]bool = @splat(true),
    /// TEMP window debugging (undocumented): write WRAM+BWRAM+VRAM to this
    /// file after the run.
    dump_ram: ?[]const u8 = null,
    /// --lap-cell <hex16>: tick per write of this low-WRAM cell (the game's
    /// lap counter) instead of per pad poll; a --repoll then writes a per-lap
    /// (version 4) take. A per-lap take sets it on load.
    lap_cell: u16 = 0,
    /// --ref-overclock <n>: the behavioral tier's BASELINE runs its S-CPU n
    /// times faster (a lag-free stock reference; see Bus.overclock).
    ref_overclock: u8 = 1,
    /// --conv-overclock <n>: the CONVERSION side too — both its S-CPU and
    /// its SA-1 run n times faster in the gate's eras. With
    /// --ref-overclock the tier compares two lag-free machines: logic
    /// equivalence with the lag differential taken out of the picture.
    /// On a plain run of a conversion image, `--ref-overclock` alone
    /// overclocks that image's CPUs the same way (a measurement).
    conv_overclock: u8 = 1,
    /// --split-scpu-set <file>: record (and merge into the file) every S-CPU
    /// instruction address run while a split's upper copy was mapped.
    split_scpu_set: ?[]const u8 = null,
    /// --wg-split-shared <file>: that set, for the generator.
    wg_split_shared: []const u24 = &.{},
    /// `--dump-srm <file>`: write the cart's battery SRAM at the end of the
    /// run — the way to lift a save out of a state (`--state x --frames 1
    /// --dump-srm x.srm`) for `yamabuki-sdl --record --srm`.
    dump_srm: ?[]const u8 = null,
    /// `--dump-ppu`: the display state as text after the run. For the
    /// question a RAM dump cannot answer — a layer that is missing from
    /// the picture is either disabled, pointed somewhere empty, or fed a
    /// tilemap that never arrived, and those look identical in WRAM.
    dump_ppu: ?[]const u8 = null,
    /// `--movie-ignore-crc`: DIAGNOSTIC. Replay a movie whose recorded
    /// image CRC differs from this run's — for re-playing a recording made
    /// on a previous conversion against a freshly regenerated one (window
    /// mode preserves the S-CPU's code and frame timing, so controller
    /// input usually stays in sync). The end-hash check becomes advisory.
    movie_ignore_crc: bool = false,
    /// `--repoll out.ymv`: while replaying `--movie`, record the take again
    /// as a PER-POLL movie (format 3): one entry per controller read the
    /// game made, so the result replays on any build of the game whose
    /// logic is behaviorally equivalent — a stock take migrated to the
    /// conversion, lag frames and all. Same anchor, same end hashes.
    repoll: ?[]const u8 = null,
    /// `--repoll-poweron`: write the re-recorded take without the source
    /// take's anchor. For a take whose anchor is a powered-on machine with
    /// a battery save loaded and nothing run (`--record --srm`): the
    /// result replays from power-on with the same save (`--srm`, or the
    /// `.start.srm` sidecar this writes beside it) — on ANY build.
    repoll_poweron: bool = false,
    /// `--srm <file>`: load a battery save into the cart's save chip (or a
    /// window conversion's lifted save region) before the first frame.
    srm: ?[]const u8 = null,
    /// `--dump-vram`: raw VRAM (64 KiB) then OAM (544 B) after the run.
    dump_vram: ?[]const u8 = null,
    /// --save-state-at: frame to stop at and the file to write the machine to.
    /// A recording that carries its own anchor cannot be a window-mode
    /// surface, but the machine it passes through CAN anchor a profile — this
    /// is how a late-game scene reaches the generator without a power-on take.
    save_state_at: ?u32 = null,
    save_state_path: []const u8 = "",
    /// `--poke ADDR=VAL`: cheat writes held after every frame. Repeatable,
    /// and each flag may carry a comma-separated list.
    pokes: [util.cheat.max_pokes]util.cheat.Poke = undefined,
    n_pokes: usize = 0,
    /// Verifier debugging (undocumented): run ONLY the behavioral tier —
    /// stock ROM as baseline, this converted image, the given movies —
    /// and print the verdict with its full accounting. Iterating the
    /// tier's rules against a preserved failing rung in minutes instead
    /// of re-running the whole generation ladder.
    behavioral_probe: ?[]const u8 = null,
    iram_dump: bool = false,
    /// Window debugging (undocumented): write each verification attempt's
    /// converted image to this path (last attempt wins).
    save_attempt: ?[]const u8 = null,
    /// Window offloads (undocumented --wg-sync): never try the async
    /// flavor. The async monopoly admits ONE tree; a passing async
    /// first attempt ships alone even when the sync ladder would carry
    /// more trees and more speedup.
    wg_sync: bool = false,
    /// Window mode (undocumented --wg-fastrom): layer the FastROM
    /// transform onto every converted attempt image — MEMSEL stub,
    /// interrupt trampolines into the $80 mirrors, observed MEMSEL
    /// stores NOPed. The SA-1 MMC serves the fast mirrors under MEMSEL
    /// like any FastROM cart, so this cuts ~25% off every remaining
    /// S-CPU ROM cycle, orthogonally to the offload trees.
    wg_fastrom: bool = false,
    /// Window offloads (undocumented --wg-drop <hex16>, repeatable):
    /// pre-seed the bisect's dropped list — exclude a tree the surfaces
    /// pass but live play proves unsafe (measured: the $8EF1 walker
    /// races NMI-side slot mutations into a ROM cycle at the continue
    /// screen; movie surfaces never exhibit that interleaving).
    wg_drop: [8]u32 = @splat(0),
    n_wg_drop: usize = 0,
    /// --wg-nmi-off <hex16> (repeatable): wrap these trees' sync stubs
    /// in NMI/IRQ-off across the dispatch (closes the concurrent-
    /// mutation hazard by construction; implies the tree never ships
    /// async).
    wg_nmi_off: [8]u32 = @splat(0),
    n_wg_nmi_off: usize = 0,
    /// --cover-image <patched.sfc> + --cover-movie <f.ymv>: harvest
    /// COVERAGE (opcode + width bits only, no site evidence) from a
    /// movie replayed on a PREVIOUS CONVERSION of this game, merged
    /// into the union wherever the instruction byte matches the stock
    /// image. This is how gameplay only reachable on the conversion
    /// (a recorded run whose inputs are conv-timed dies early when
    /// replayed on stock) still teaches the rewriter which code
    /// exists: which instructions execute is address-space-invariant
    /// even though their operands were rewritten.
    /// Repeatable: each `--cover-image` opens a new pair, and the
    /// `--cover-movie` after it fills the same slot. One recording covers
    /// one scenario, and the defects live in the scenarios nobody
    /// profiled — so the harvest has to take as many as there are.
    cover_image: [max_cover_pairs]?[]const u8 = @splat(null),
    cover_movie: [max_cover_pairs]?[]const u8 = @splat(null),
    n_cover: usize = 0,
    /// --harvest-cache <dir>: keep each cover pair's harvest — the replay's
    /// usage map, site evidence, proven bank bytes and armed HDMA tables —
    /// in a file keyed by the cover image's crc32, the movie file's hash and
    /// `harvest_cache_version`. A generation then replays only the pairs it
    /// has not seen; the merge into the union runs from the file exactly as
    /// it would from the replay. Measured before this existed: 25 recordings,
    /// 785k frames replayed per generation, 24 of them unchanged since the
    /// last. Bump the version whenever the profiler's semantics change.
    harvest_cache: ?[]const u8 = null,
    /// --harvest-jobs N: cover pairs that still need a replay run on N
    /// threads (default: the machine's core count, at most 12). Each replay
    /// owns its console and products; the merges stay on the main thread, in
    /// recipe order, so the union and the log are the same at any N.
    harvest_jobs: usize = 0,
    /// --harvest-render: paint frames during harvest replays (the default
    /// skips the pixel work; the harvest never looks at a frame).
    harvest_render: bool = false,
    /// TEMP S2 debugging (undocumented): with --gen-sa1-patch --state,
    /// comma-separated plan-region indices to KEEP as live relocations
    /// (offloads disabled for the run). Bisects the relocation plan.
    /// Undocumented --hash-stream: write one u64 frame hash per frame to
    /// this path. The picture stream is the comparison that survives a lag
    /// differential, so this is the cheap sound oracle for "did the build
    /// change what the game DOES, or only how fast it does it".
    hash_stream: ?[]const u8 = null,
    s2_keep: ?[]const u8 = null,
    /// Resume from an SDL-player save state instead of power-on (plain runs
    /// and --sa1-report). Same-image, same-core states only.
    state: ?[]const u8 = null,
    /// S4: when the pixel gate says divergent, also run the behavioral
    /// tier — logic-state equality at every logic tick — and accept a
    /// conversion whose divergence is only wall-time echoes.
    verify_behavioral: bool = false,
    /// Diagnostic for the behavioral verifier's design: write every logic
    /// tick's phase-aligned WRAM snapshot (u32 wall frame + 128 KiB raw,
    /// repeated) to this file. Fast core only.
    tick_dump: ?[]const u8 = null,
    /// Generate a FastROM patch for this ROM, verified in-emulator before
    /// anything is written (see `util.generateFastromVerified`).
    gen_fastrom: bool = false,
    /// Stage S3: generate an SA-1 conversion patch — the shell (SA-1 cart +
    /// parked SA-1) plus the plan's clean state relocations — verified
    /// frame- and audio-identical before anything is written.
    gen_sa1: bool = false,
    /// With --gen-sa1-patch: whole-game migration (SA-1 Root) — the entire
    /// game executes on the SA-1 and the S-CPU becomes an MMIO service
    /// loop — instead of the routine-offload ladder.
    whole_game: bool = false,
    /// Uniform window relocation: the game keeps running on the S-CPU and
    /// only its memory moves (WRAM low 8K -> the S-CPU BW-RAM window,
    /// $7E/$7F longs -> $40/$41). Implies the whole-game pipeline shape.
    window: bool = false,
    /// With --whole-game: also rewrite code the profiled run never reached,
    /// discovered by recursive-descent disassembly seeded from coverage.
    /// Unprovable shapes in that code are counted, not refused over.
    wg_static: bool = false,
    /// --wg-copy-reserve: bytes held at the tail of the biggest padding run
    /// for offload tree copies. The default matches the generator's own.
    wg_copy_reserve: u32 = core.sa1gen.copy_reserve,
    /// S5 mainline split: the engage anchor (24-bit, any code bank); zero
    /// = split off. `--wg-split-io <hex24>[:d][:l]`, `--wg-split-vbl
    /// <hex24>-<hex24>` and `--wg-split-mode <cell16>:<value>` (a low-WRAM
    /// address in the mainloop flavor, read at its window home) follow.
    wg_split_mainloop: u24 = 0,
    wg_split_tail: u16 = 0,
    wg_split_epi: u16 = 0,
    wg_split_dbr: u8 = 0,
    wg_split_mode_cell: u16 = 0,
    wg_split_mode_value: u8 = 0,
    wg_split_mode_hi: u8 = 0,
    wg_split_mode: bool = false,
    wg_split_io: [26]core.sa1gen.SplitIo = undefined,
    n_wg_split_io: usize = 0,
    wg_split_vbl: [8][2]u24 = undefined,
    n_wg_split_vbl: usize = 0,
    /// --wg-expand: grow the converted image to this many bytes (0 = keep the
    /// original size), handing the conversion room it does not otherwise have.
    wg_expand_to: u32 = 0,
    /// --wg-add: extra offload candidates (CPU addresses), for routines a
    /// single-scene profile ranks too low to offer.
    wg_add: [8]u24 = @splat(0),
    n_wg_add: usize = 0,
    /// Where to write the generated patch. Default: `<rom>.bps` next to the
    /// ROM — the softpatch convention every frontend picks up by name.
    gen_out: ?[]const u8 = null,
    /// This process's own argv, joined and quoted. Written beside every
    /// generated patch and echoed into the log, because a generation that
    /// cannot be re-issued exactly cannot be reproduced — and three
    /// separate days went into reconstructing one from prose notes, each
    /// time missing a different flag.
    cmdline: []const u8 = "",
};

/// Default frames to profile: 60 seconds at 60 Hz, on top of the skipped boot.
const report_frames_default: u32 = 3600;

/// Input surfaces one generator run accepts (each `--movie` or
/// `--evidence-movie` is one). Super Metroid's recipe reached six with the
/// soft-reset take, then the per-poll surfaces the wide gate verifies on.
const max_movies: usize = 12;
/// Cover pairs a recipe may carry. The Super Metroid campaign reached 24 —
/// the old cap, hit with a usage error — on its fourth stock take.
const max_cover_pairs: usize = 64;

/// Default frames for `--gen-fastrom-patch` verification: 30 seconds, the
/// same standard patches/fastrom-compat.zon entries are verified to.
const gen_frames_default: u32 = 1800;

/// Debug builds give every local its own stack slot and never merge them —
/// including a `defer` body's, which is re-emitted at every exit path of the
/// function that owns it — and this program's locals are cartridge and console
/// states measured in hundreds of KiB apiece. `run` reserves ~5 MiB of frame
/// in Debug and the SA-1 generator another ~3, which overruns the 8 MiB
/// main-thread stack before the first instruction executes. ReleaseFast merges
/// the slots away and needs none of this, so buy the room only where the cost
/// is real: a thread whose stack we get to size.
pub fn main(init: std.process.Init) !void {
    if (builtin.mode != .Debug) return run(init);
    var status: anyerror!void = {};
    const t = try std.Thread.spawn(.{ .stack_size = debug_stack_size }, runOnThread, .{ init, &status });
    t.join();
    return status;
}

/// Room for `run` plus the deepest callee chain under it, with the margin a
/// Debug frame's growth deserves — it is virtual address space, not memory.
const debug_stack_size = 64 * 1024 * 1024;

fn runOnThread(init: std.process.Init, status: *anyerror!void) void {
    status.* = run(init);
}

fn run(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const args = parseArgs(init, gpa) catch |e| {
        if (e == error.WideNeedsFast) {
            try out.print("error: --wide needs the fast core (--accurate's dot renderer doesn't support it)\n", .{});
        } else if (e == error.WideTooBig) {
            try out.print("error: --wide margin exceeds {d}\n", .{core.ppu.wide_margin_max});
        } else if (e == error.GenConflicts) {
            try out.print("error: --gen-fastrom-patch runs its own baseline and verify passes; it cannot be combined\n" ++
                "       with --patch/--auto-patch/--save-patched/--auto-fastrom/--accurate/--wide/--sa1-report\n", .{});
        } else if (e == error.UsageNeedsReport) {
            try out.print("error: --usage-map is a --sa1-report modifier (coverage comes from the profiled run)\n", .{});
        }
        try out.print(
            \\usage: yamabuki-headless <rom.sfc> [--frames N] [--ppm out.ppm] [--wav out.wav] [--accurate]
            \\                         [--region ntsc|pal|auto] [--patch p.bps|p.ips] [--auto-patch]
            \\                         [--patch-dir DIR] [--save-patched out.sfc] [--wide N]
            \\       yamabuki-headless <rom.sfc> --sa1-report [--frames N] [--skip N] [--json] [--hot]
            \\                         [--routines] [--plan] [--usage-map out.bin]
            \\       yamabuki-headless <rom.sfc> --gen-fastrom-patch [--out p.bps] [--frames N]
            \\       yamabuki-headless <rom.sfc> --gen-sa1-patch [--whole-game] [--out p.bps] [--frames N]
            \\
            \\  --region r    ntsc|pal|auto (default auto: detect from the cart header)
            \\  --patch p     apply a BPS/IPS patch to the ROM in memory at load (BPS verified, IPS not)
            \\  --auto-patch  look this ROM up in patches/registry.zon and apply its registered patch
            \\  --patch-dir d where --auto-patch looks for patch files (default: patches/)
            \\  --save-patched  write the patched image and exit without emulating (needs a patch)
            \\  --auto-fastrom  pin MEMSEL=1 (FastROM timing for SlowROM games; compat-list gated)
            \\  --movie f     replay a recorded playthrough (.ymv, recorded in the SDL player);
            \\                --gen-sa1-patch accepts SEVERAL --movie flags — each is a
            \\                verification SURFACE, evidence/coverage is their union, and
            \\                every surface must verify
            \\  --verify-behavioral  S4: on pixel divergence, accept a conversion whose logic
            \\                state matches at every tick (for timing-changing offloads)
            \\  --poke a=v    hold byte v at CPU address a (both hex) after every frame,
            \\                the way an Action Replay does; repeatable, comma-lists ok.
            \\                The address is a BUS address, so it lands where that byte
            \\                really lives in THIS image: a stock ROM takes the published
            \\                address (7E0086); a window conversion takes its window
            \\                address (006086) — the low 8 KiB moved into BW-RAM
            \\  --state f     resume from an SDL-player save state instead of power-on;
            \\                with --gen-sa1-patch, anchors the profile AND verify runs at
            \\                the state, so candidates come from a scene with real slowdown
            \\                (a state saved playing an earlier conversion of this game works)
            \\                (plain runs and --sa1-report; same image and core only)
            \\                from power-on, verifying its end hashes; with --sa1-report or a
            \\                --gen-* mode the movie drives the profiled runs instead, so
            \\                coverage and verification come from real gameplay
            \\  --wide N      widen the framebuffer by N columns on each side, e.g. 32 -> 320x224
            \\                (fast core only; for widescreen game patches such as wide-snes)
            \\  --gen-fastrom-patch  derive a FastROM conversion for this SlowROM game and verify it
            \\                in-emulator (every frame pixel- and audio-identical to the unpatched
            \\                run, MEMSEL held); only a verified patch is written, as BPS
            \\  --out p       where --gen-fastrom-patch writes the patch (default: <rom>.bps)
            \\  --gen-sa1-patch  stage S3: convert to an SA-1 cart (shell + the relocation plan's
            \\                clean state moves), verified pixel- and audio-identical; the game
            \\                still runs on the S-CPU — execution migration is stage S3b
            \\                (default output: <rom>-sa1.bps)
            \\  --wg-static   with --whole-game: also rewrite code the profiled run never reached
            \\                (recursive-descent disassembly seeded from coverage); unprovable
            \\                shapes there are counted, not refused over
            \\  --whole-game  with --gen-sa1-patch: whole-game migration (SA-1 Root) — the game
            \\                executes entirely on the SA-1, the S-CPU becomes an MMIO service
            \\                loop; needs the WRAM working set inside I-RAM's identity window
            \\                and refuses by name when it cannot prove the move
            \\  --window      with --gen-sa1-patch: uniform window relocation — the game KEEPS
            \\                RUNNING ON THE S-CPU; WRAM's low 8 KiB moves into the S-CPU's
            \\                BW-RAM window (+$6000, distances preserved so indexed bases
            \\                rewrite soundly) and $7E/$7F longs re-bank to $40/$41. MMIO stays
            \\                native; the SA-1 never leaves reset. The enabler for resident
            \\                offloads over the whole working set (composes with --wg-static)
            \\  --sa1-report  is this game CPU-bound? (step one of the SA-1 candidacy analyser)
            \\  --skip N      frames to run before profiling starts (default 300 — boot is not gameplay)
            \\  --hot         also list the loops the frame is spent in, and how each was classified
            \\  --routines    which routines cost the frame (self/inclusive cycles per call site), and
            \\                each one's WRAM working set, MMIO blockers, and page-sharing with the rest
            \\  --usage-map f export the profiled run's execution/access coverage as a bsnes-plus
            \\                -usage.bin (code vs data with M/X widths, plus the RAM access map;
            \\                DiztinGUIsh imports it directly)
            \\  --plan        print the relocation plan for the hot set: which WRAM state moves to
            \\                SA-1 I-RAM vs BW-RAM, with the dp window, DMA feeds, and sharing
            \\                called out per region
            \\
        , .{});
        try out.flush();
        std.process.exit(2);
    };

    var image = std.Io.Dir.cwd().readFileAlloc(io, args.rom, gpa, .limited(16 * 1024 * 1024)) catch {
        try out.print("error: cannot read ROM '{s}'\n", .{args.rom});
        try out.flush();
        std.process.exit(1);
    };

    var patched = false;
    if (args.patch) |patch_path| {
        if (args.auto_patch) try out.print("note: --patch overrides --auto-patch\n", .{});
        image = applyPatch(io, gpa, out, image, patch_path) catch std.process.exit(1);
        patched = true;
    } else if (args.auto_patch) {
        image = autoPatch(io, gpa, out, image, args.patch_dir, &patched) catch std.process.exit(1);
    }
    if (args.save_patched) |save_path| {
        if (!patched) {
            try out.print("error: --save-patched needs a patch that actually applied\n", .{});
            try out.flush();
            std.process.exit(2);
        }
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = save_path, .data = image }) catch {
            try out.print("error: cannot write '{s}'\n", .{save_path});
            try out.flush();
            std.process.exit(1);
        };
        try out.print("wrote {s} ({d} bytes)\n", .{ save_path, image.len });
        try out.flush();
        return;
    }

    // Movies identify themselves against the image AS PLAYED (post
    // soft-patching): loaded here, after the patch stage, and checked
    // against the same stripped image the run will use.
    var movs_buf: [max_movies]util.movie.Movie = undefined;
    for (args.movies[0..args.n_movies], 0..) |mpath, i|
        movs_buf[i] = loadMovie(io, gpa, out, args, mpath, core.header.stripCopierHeader(image));
    const movs: []const util.movie.Movie = movs_buf[0..args.n_movies];
    const mov: ?util.movie.Movie = if (movs.len != 0) movs[0] else null;

    // A verification surface is replayed on BOTH the stock image and the
    // conversion. An anchor only restores the machine it was taken on, so in
    // window mode — where the conversion's WRAM lives in BW-RAM and the shim's
    // D/S moves never ran for a saved state — one of those two replays is
    // guaranteed to be nonsense whichever image the anchor came from. Nonsense
    // that still produces frames and hashes is the worst failure this system
    // has, so it is refused here rather than measured.
    if (args.window) for (movs, 0..) |m, i| {
        if (m.anchor == null) continue;
        try out.print(
            "error: --movie '{s}' is anchored to a save state, which window mode cannot verify\n" ++
                "       (a window image cannot be seeded mid-game, and a stock replay of an anchored\n" ++
                "       recording starts from the wrong machine — one side would be measuring noise)\n" ++
                "       use it as --cover-movie instead: the harvest replays it on its own image and\n" ++
                "       donates the coverage and evidence, which is what a late-game recording is for.\n",
            .{args.movies[i]},
        );
        try out.flush();
        std.process.exit(2);
    };

    if (args.gen_fastrom) {
        try runGenerate(io, gpa, out, args, core.header.stripCopierHeader(image), mov);
        return;
    }
    if (args.behavioral_probe) |cpath| {
        dbg_ref_overclock = args.ref_overclock;
        dbg_conv_overclock = args.conv_overclock;
        dbg_ref_oc_cell = args.wg_split_mode_cell;
        dbg_ref_oc_lo = args.wg_split_mode_value;
        dbg_ref_oc_hi = if (args.wg_split_mode_hi != 0) args.wg_split_mode_hi else args.wg_split_mode_value;
        try runBehavioralProbe(io, gpa, out, args, core.header.stripCopierHeader(image), cpath, movs);
        return;
    }
    if (args.gen_sa1) {
        try runSa1Gen(io, gpa, out, args, core.header.stripCopierHeader(image), movs);
        return;
    }
    // Outside the generator, several surfaces have no meaning: one run
    // replays one movie.
    if (movs.len > 1) {
        try out.print("error: multiple --movie flags are a generator feature (each is a verification surface)\n", .{});
        try out.flush();
        std.process.exit(2);
    }

    if (args.auto_fastrom) checkFastromCompat(out, core.header.stripCopierHeader(image)) catch std.process.exit(1);

    const cart = core.Cartridge.load(gpa, image) catch |e| {
        try out.print("error: cannot load ROM: {s}\n", .{@errorName(e)});
        try out.flush();
        std.process.exit(1);
    };

    if (args.sa1_report) {
        try runReport(io, gpa, out, args, cart, mov);
        return;
    }
    if (args.tick_dump) |path| {
        try runTickDump(io, gpa, out, args, cart, mov, path);
        return;
    }

    const con = try gpa.create(core.AnyConsole);
    con.init(args.accuracy, cart);
    switch (args.region) {
        .auto => {},
        .ntsc => con.setRegion(.ntsc),
        .pal => con.setRegion(.pal),
    }
    // The movie dictates the region it was recorded under — a replay on the
    // wrong timing cannot reproduce (an explicit conflicting --region was
    // already refused in loadMovie).
    if (mov) |m| con.setRegion(if (m.region == 1) .pal else .ntsc);
    if (args.auto_fastrom) con.enableAutoFastrom();
    if (args.wide != 0) con.setWideMargin(args.wide);
    if (args.state) |spath| try loadStateInto(io, gpa, out, con, spath);
    // After --state on purpose: a movie's own anchor is the machine ITS
    // inputs were recorded against, so it wins over a session-wide one.
    try applyStartSave(io, gpa, con, args, mov, out);
    try anchorMovie(con, mov, "movie", out);

    // Window debugging: dump what the machine settled on, after the run.
    // Each body is a function and not an inline `defer` block on purpose —
    // a defer's locals are re-emitted at EVERY exit path of the function that
    // owns it, and Debug never merges the slots, so the 64 KiB buffer in one
    // of these costs 64 KiB per `try` in `run`. Inline, the three of them
    // reserved 98 MiB of `run`'s stack frame.
    defer if (args.dump_vram) |vpath| dumpVram(io, con, vpath);
    defer if (args.dump_ppu) |ppath| dumpPpu(io, out, con, ppath);
    defer if (args.dump_ram) |dpath| dumpRam(io, gpa, con, dpath);
    if (args.lap_cell != 0) core.wdc65816.lap_cell = args.lap_cell;
    dbg_ref_overclock = args.ref_overclock;
    dbg_conv_overclock = args.conv_overclock;
    dbg_ref_oc_cell = args.wg_split_mode_cell;
    dbg_ref_oc_lo = args.wg_split_mode_value;
    dbg_ref_oc_hi = if (args.wg_split_mode_hi != 0) args.wg_split_mode_hi else args.wg_split_mode_value;
    if (args.split_scpu_set != null) {
        const m = try gpa.alloc(u8, 0x40 * 0x8000);
        @memset(m, 0);
        core.wdc65816.dbg_scpu_set = m;
    }
    defer if (args.split_scpu_set) |sp| writeScpuSet(io, gpa, sp);
    defer if (args.dump_srm) |spath| dumpSrm(io, con, spath);

    // Drain audio every frame (the ring holds ~15 frames); hash the stream
    // and keep it if a WAV dump was requested.
    var audio_hash = core.console.audio_hash_init;
    var audio_peak: u16 = 0;
    var audio_all: std.array_list.Managed(i16) = .init(gpa);
    // --hash-stream: one u64 per frame, little-endian. The PICTURE STREAM
    // is the one comparison that survives a lag differential — collapse
    // consecutive equal hashes and two runs of the same game show the same
    // sequence however many times each lag repeat appears. Comparing two
    // CONVERSIONS this way (rather than a conversion against stock) is what
    // makes it usable on a build whose whole purpose is to be faster.
    var hash_stream: ?std.array_list.Managed(u64) = if (args.hash_stream != null)
        .init(gpa)
    else
        null;
    const frames = args.frames orelse if (mov != null) @as(u32, @intCast(util.movie.Feed.budget(mov))) else 1;
    var feed: util.movie.Feed = .init(mov);
    // A per-poll take ends `tail_frames` after the frame that consumed its
    // last entry — known only once that frame has run.
    var movie_end: ?usize = if (mov) |m| (if (m.per_poll) null else m.frames.len - 1) else null;
    // --repoll: the entries a per-poll take of this replay holds, and the
    // frames run after the last poll (the tail its end hashes describe).
    var repoll: std.array_list.Managed([2]u16) = .init(gpa);
    defer repoll.deinit();
    var repoll_tail: u32 = 0;
    for (0..frames) |i| {
        feed.step(con, i);
        // Recording per poll needs the latch cleared every frame; the feed
        // only does so for a per-poll source (and has already taken it).
        if (args.repoll != null) {
            _ = con.takeInputPolled();
            _ = con.takeLapPassed();
        }
        // --ref-overclock on a plain run: this image's CPUs, in the gate's
        // eras (a lag-free measurement of either side).
        if (dbg_ref_overclock > 1 and i >= 300 and con.* == .fast) {
            const v = modeCell(&con.fast, dbg_ref_oc_cell);
            con.fast.bus.overclock = if (dbg_ref_oc_cell != 0 and v >= dbg_ref_oc_lo and v <= dbg_ref_oc_hi) dbg_ref_overclock else 1;
            con.fast.bus.sa1.overclock = con.fast.bus.overclock;
        }
        con.runFrame();
        if (mov) |m| if (m.per_poll and movie_end == null and feed.cursor + 1 >= m.frames.len and (if (m.lap_cell != 0) con.lapPassed() else con.inputPolled())) {
            movie_end = i + m.tail_frames;
        };
        if (args.repoll != null) {
            if (args.lap_cell != 0) {
                // per lap: every edge of the frame, in order
                var recs: [16][2]u16 = undefined;
                const n = con.lapRecTake(&recs);
                if (n != 0) {
                    for (recs[0..n]) |r| try repoll.append(r);
                    repoll_tail = 0;
                } else repoll_tail += 1;
            } else if (con.inputPolled()) {
                try repoll.append(feed.last);
                repoll_tail = 0;
            } else repoll_tail += 1;
        }
        // AFTER the frame, so the value the next frame reads is the cheat's
        // and not whatever the game just stored over it. Applied before the
        // frame instead, the game wins every tie and the poke does nothing.
        if (args.n_pokes != 0) {
            const landed = util.cheat.apply(con, args.pokes[0..args.n_pokes]);
            // Reported once: a poke at an address the bus does not map as
            // plain memory silently does nothing, which reads exactly like a
            // cheat that "did not work" and wastes a session chasing it.
            if (i == 0) {
                try out.print("poke: {} of {} landed (refused = not writable memory at that address)\n", .{ landed, args.n_pokes });
                try out.flush();
            }
        }
        if (args.save_state_at) |at| if (i + 1 == at) {
            const buf = try gpa.alloc(u8, core.AnyConsole.state_size);
            defer gpa.free(buf);
            const n = con.saveState(buf);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args.save_state_path, .data = buf[0..n] });
            try out.print("wrote {s} ({d} bytes) — the machine after frame {d}\n", .{ args.save_state_path, n, at });
            try out.flush();
        };
        if (args.ppm_range_start) |start| if (i >= start and i < start + args.ppm_range_count) {
            const rfb = con.framebuffer();
            const rw = con.frameWidth();
            const path = try std.fmt.allocPrint(gpa, "{s}{d:0>5}.ppm", .{ args.ppm_range_prefix, i });
            defer gpa.free(path);
            try util.writeFramebufferPpm(gpa, io, path, rfb, rw, @intCast(rfb.len / rw));
        };
        if (hash_stream) |*hs| try hs.append(core.console.hashFrame(con.framebuffer()));
        try util.drainAudio(con, &audio_hash, AudioSink{
            .peak = &audio_peak,
            .wav = if (args.wav != null) &audio_all else null,
        }, AudioSink.collect);
        // The frame the movie ends on is the one its hashes describe.
        if (mov) |m| if (movie_end != null and i == movie_end.?) {
            if (m.end_frame_hash == 0) {
                try out.print("movie: {} frames replayed (no end hashes recorded — sync unverified)\n", .{i + 1});
            } else {
                const fh = core.console.hashFrame(con.framebuffer());
                const audio_ok = m.end_audio_hash == 0 or audio_hash == m.end_audio_hash;
                if (fh == m.end_frame_hash and audio_ok) {
                    try out.print("movie: sync verified — {} frames replayed, end hashes match\n", .{i + 1});
                } else {
                    try out.print(
                        "movie: DESYNC at end of replay — frame hash {x:0>16} (movie {x:0>16}), audio {s}\n",
                        .{ fh, m.end_frame_hash, if (audio_ok) "ok" else "diverged" },
                    );
                    try out.flush();
                    // A cross-build replay is EXPECTED to end differently (the
                    // point is a changed picture); keep the run so its dumps
                    // still write. A same-build desync is a real failure.
                    if (!args.movie_ignore_crc) std.process.exit(1);
                }
            }
            // A per-poll take's frame budget is a ceiling, not a length:
            // stop here unless a frame count was asked for.
            if (m.per_poll and args.frames == null) break;
        };
        if (mov) |m| if (m.per_poll and args.frames == null and i + 1 == frames) {
            try out.print("movie: {} of {} per-poll entries consumed in {} frames — the game stopped reading the pad\n", .{ feed.cursor, m.frames.len, frames });
        };
    }

    if (args.repoll) |path| if (mov) |m| {
        const pm: util.movie.Movie = .{
            .accuracy = m.accuracy,
            .region = m.region,
            .rom_crc = m.rom_crc,
            .end_frame_hash = core.console.hashFrame(con.framebuffer()),
            .end_audio_hash = audio_hash,
            .frames = repoll.items,
            .anchor = if (args.repoll_poweron) null else m.anchor,
            .per_poll = true,
            .tail_frames = repoll_tail,
            .lap_cell = args.lap_cell,
        };
        const bytes = try util.movie.encode(gpa, pm);
        defer gpa.free(bytes);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
        // The save the take began from rides beside it: --srm's file, or
        // the source take's own sidecar.
        var sp_buf: [1024]u8 = undefined;
        const start_save: ?[]const u8 = if (args.srm) |p| (std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(1024 * 1024)) catch null) else m.start_srm;
        if (start_save) |sb| if (util.movie.startSrmPath(&sp_buf, path)) |sp| {
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sp, .data = sb });
            try out.print("repoll: start save written beside it: {s}\n", .{sp});
        };
        try out.print("repoll: wrote {s} — {} poll(s) from {} frame(s), {} tail frame(s), anchor {s}\n", .{ path, repoll.items.len, frames, repoll_tail, if (pm.anchor != null) "kept" else if (m.anchor != null) "dropped (--repoll-poweron)" else "none" });
    };

    const fb = con.framebuffer();
    const width = con.frameWidth();
    const hash = core.console.hashFrame(fb);
    try out.print("{s}: {} frames, {}x{}, hash={x:0>16}, audio={x:0>16} (peak {})\n", .{
        args.rom, frames, width, fb.len / width, hash, audio_hash, audio_peak,
    });
    if (args.iram_dump and con.* == .fast and con.fast.bus.cart.chip == .sa1) {
        try out.print("sa1 pc={x:0>2}:{x:0>4} resb={} iram $3780-$37BF:", .{ con.fast.bus.sa1.cpu.regs.pbr, con.fast.bus.sa1.cpu.regs.pc, con.fast.bus.sa1.sa1_resb });
        var di: usize = 0x780;
        while (di < 0x7C0) : (di += 1) try out.print(" {x:0>2}", .{con.fast.bus.sa1.iram[di]});
        try out.print("\n", .{});
    }
    try out.flush();

    if (args.hash_stream) |path| {
        const hs = &hash_stream.?;
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = std.mem.sliceAsBytes(hs.items) });
        try out.print("wrote {s} ({} frame hashes)\n", .{ path, hs.items.len });
        try out.flush();
    }
    if (args.ppm) |path| {
        try util.writeFramebufferPpm(gpa, io, path, fb, width, @intCast(fb.len / width));
        try out.print("wrote {s}\n", .{path});
        try out.flush();
    }
    if (args.wav) |path| {
        try util.writeWav(io, path, audio_all.items);
        try out.print("wrote {s} ({} stereo frames)\n", .{ path, audio_all.items.len / 2 });
        try out.flush();
    }
}

/// `--dump-vram`: raw VRAM (64 KiB) + OAM (544 B), so cross-image VRAM/OAM
/// diffs are byte-exact.
fn dumpVram(io: std.Io, con: *core.AnyConsole, path: []const u8) void {
    const p = &con.fast.bus.ppu;
    var blob: [0x10000 + 0x220]u8 = undefined;
    @memcpy(blob[0..0x10000], std.mem.sliceAsBytes(p.vram[0..]));
    @memcpy(blob[0x10000..], &p.oam);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = &blob }) catch {};
}

/// `--dump-ppu`: the display state as text — what a layer is doing is a
/// property of the PPU registers and of what actually reached VRAM, and
/// neither shows up in a RAM dump. Per BG: is it on the main screen at all,
/// where is its tilemap and character data, and — the question that separates
/// "never uploaded" from "not displayed" — how much of that tilemap in VRAM
/// is actually non-empty.
fn dumpPpu(io: std.Io, out: *std.Io.Writer, con: *core.AnyConsole, path: []const u8) void {
    const p = &con.fast.bus.ppu;
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("bg_mode={d} force_blank={} brightness={d} main_screen(TM)=0x{x:0>2} sub_screen(TS)=0x{x:0>2}\n", .{
        p.bg_mode, p.force_blank, p.brightness, p.main_screen, p.sub_screen,
    }) catch {};
    for (p.bg, 0..) |b, i| {
        // A tilemap of all-zero entries renders as nothing even with the
        // layer enabled, so count what is actually there.
        const words: usize = switch (b.map_size) {
            0 => 0x400,
            1 => 0x800,
            2 => 0x800,
            3 => 0x1000,
        };
        var nonzero: usize = 0;
        var k: usize = 0;
        while (k < words) : (k += 1) {
            const idx = (@as(usize, b.map_base) + k) & 0x7FFF;
            if (p.vram[idx] != 0) nonzero += 1;
        }
        w.print("bg{d}: on_main={} map_base=0x{x:0>4} map_size={d} char_base=0x{x:0>4} tile16={} hofs={d} vofs={d} tilemap_nonzero={d}/{d}\n", .{
            i + 1,       (p.main_screen >> @intCast(i)) & 1 != 0,
            b.map_base,  b.map_size,
            b.char_base, b.tile16,
            b.hofs,      b.vofs,
            nonzero,     words,
        }) catch {};
    }
    // HDMA: per-scanline effects read their table straight out of memory
    // without the CPU issuing a single load, so a table left pointing at
    // abandoned WRAM is invisible to the stale detector and shows up only
    // as a missing effect. Top/bottom bands are exactly this shape.
    const dma = &con.fast.bus.dma;
    w.print("hdmaen=0x{x:0>2}\n", .{dma.hdmaen}) catch {};
    for (dma.channels, 0..) |ch, i| {
        if (dma.hdmaen & (@as(u8, 1) << @intCast(i)) == 0) continue;
        const src: u24 = (@as(u24, ch.a_bank) << 16) | ch.a_addr;
        const dead = ch.a_bank == 0x7E or ch.a_bank == 0x7F or
            ((ch.a_bank & 0x7F) < 0x40 and ch.a_addr < 0x2000);
        w.print("  hdma{d}: src={x:0>6} bank={x:0>2}{s}\n", .{
            i, src, ch.a_bank, if (dead) "  <-- ABANDONED MEMORY" else "",
        }) catch {};
        // Indirect tables fetch their DATA through a second bank the
        // CPU never touches after arming: a $7E there reads the
        // abandoned WRAM and no CPU-side instrument can see it.
        w.print("    control=0x{x:0>2} b_addr=0x{x:0>2} indirect_bank={x:0>2} indirect_addr={x:0>4} line_counter={d}\n", .{
            ch.control, ch.b_addr, ch.indirect_bank, ch.count, ch.line_counter,
        }) catch {};
    }
    // Color math: the one axis two byte-identical CGRAM/VRAM images can
    // still render differently through (measured: Super Metroid's Ceres
    // alarm tint, an indirect HDMA on $2132 reading abandoned $7E WRAM).
    w.print("cgwsel=0x{x:0>2} cgadsub=0x{x:0>2} fixed_color=0x{x:0>4} setini=0x{x:0>2}\n", .{
        p.cgwsel, p.cgadsub, p.fixed_color, p.setini,
    }) catch {};
    var vnz: usize = 0;
    for (p.vram) |word| {
        if (word != 0) vnz += 1;
    }
    w.print("vram_nonzero={d}/{d}\n", .{ vnz, p.vram.len }) catch {};
    // CGRAM digest: same tiles + same tilemap rendering differently can
    // only be the palette (measured: SM's Ceres room corrupts to stripes
    // when CGRAM diverges while VRAM stays identical).
    w.print("cgram_full=", .{}) catch {};
    for (p.cgram) |cw| w.print("{x:0>4}", .{cw}) catch {};
    w.print("\n", .{}) catch {};
    var cgsum: u32 = 0;
    for (p.cgram) |c| cgsum +%= c;
    w.print("cgram_sum={x:0>8} bg1pal={x:0>4},{x:0>4},{x:0>4},{x:0>4} bg2pal={x:0>4},{x:0>4}\n", .{
        cgsum, p.cgram[0], p.cgram[1], p.cgram[2], p.cgram[3], p.cgram[0x20], p.cgram[0x21],
    }) catch {};
    // Window + mosaic: vertical banding that VRAM/CGRAM cannot explain
    // lives here (the window carves columns; mosaic blocks them).
    w.print("mosaic=0x{x:0>2} w12sel=0x{x:0>2} w34sel=0x{x:0>2} wobjsel=0x{x:0>2} wh0={d} wh1={d} wh2={d} wh3={d} wbglog=0x{x:0>2} tmw=0x{x:0>2} tsw=0x{x:0>2}\n", .{
        p.mosaic, p.w12sel, p.w34sel, p.wobjsel, p.wh0, p.wh1, p.wh2, p.wh3, p.wbglog, p.tmw, p.tsw,
    }) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = w.buffered() }) catch {};
    out.print("wrote {s}\n", .{path}) catch {};
    out.flush() catch {};
}

/// `--dump-ram`: WRAM (128K), BW-RAM's first 64K, VRAM and I-RAM after the
/// run, plus the CPU's resting place. The tool that found every window-mode
/// blocker so far.
/// The bytes that stand for the game's battery save: the cart's mapped
/// SRAM, or — on a window conversion, whose header declares no battery —
/// the lifted save region at the front of the upper BW-RAM half (the
/// generator moves the game's save chip there; see the SDL's saves.zig).
fn saveRegion(cart: anytype) ?[]u8 {
    if (cart.chip == .sa1 and !cart.hasBattery() and cart.sram_hi_mask >= 0x7FFF) return cart.sram_hi[0..0x8000];
    if (cart.sram_mask == 0) return null;
    return cart.sram[0 .. cart.sram_mask + 1];
}

/// Drop a battery save into the save region: zero it, then the file's
/// bytes at the front (a smaller chip's save in a larger region reads back
/// through the game's own mirroring). False when nothing takes it.
/// A take's `.start.srm` sidecar into a fresh console, before any anchor
/// state: every surface replay the generator or the verifier makes must
/// start from the save the take was recorded on. MEASURED without this:
/// the save-anchored per-poll surfaces replayed from a save-less power-on
/// on BOTH machines (the title screen and the attract), their walls never
/// drifted, and the wide gate "passed" them — vacuously.
fn applySidecar(con: anytype, mov: ?util.movie.Movie) void {
    const m = mov orelse return;
    const data = m.start_srm orelse return;
    _ = loadSaveBytes(con.bus.cart, data);
}

fn loadSaveBytes(cart: anytype, data: []const u8) bool {
    const region = saveRegion(cart) orelse return false;
    if (data.len == 0 or data.len > region.len) return false;
    @memset(region, 0);
    @memcpy(region[0..data.len], data);
    return true;
}

/// `--srm`, then the movie's start-save sidecar: the save chip as the take
/// began. Runs before the anchor, which (when there is one) overrides it.
fn applyStartSave(io: std.Io, gpa: std.mem.Allocator, con: anytype, args: Args, mov: ?util.movie.Movie, out: *std.Io.Writer) !void {
    if (args.srm) |p| {
        const data = std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(1024 * 1024)) catch {
            try out.print("error: cannot read --srm '{s}'\n", .{p});
            try out.flush();
            std.process.exit(1);
        };
        defer gpa.free(data);
        const cart = if (@TypeOf(con) == *core.AnyConsole) con.cartridge() else con.bus.cart;
        if (!loadSaveBytes(cart, data)) {
            try out.print("error: --srm '{s}' ({d} bytes) does not fit this cart's save region\n", .{ p, data.len });
            try out.flush();
            std.process.exit(1);
        }
        try out.print("srm: {s} loaded ({d} bytes)\n", .{ p, data.len });
        return;
    }
    const m = mov orelse return;
    const data = m.start_srm orelse return;
    const cart = if (@TypeOf(con) == *core.AnyConsole) con.cartridge() else con.bus.cart;
    if (!loadSaveBytes(cart, data)) {
        try out.print("error: the movie's .start.srm sidecar ({d} bytes) does not fit this cart's save region\n", .{data.len});
        try out.flush();
        std.process.exit(1);
    }
    try out.print("movie: start save loaded from the .start.srm sidecar ({d} bytes)\n", .{data.len});
}

/// `--dump-srm`: the game's battery save as a plain .srm (see saveRegion).
fn dumpSrm(io: std.Io, con: *core.AnyConsole, path: []const u8) void {
    const cart = con.cartridge();
    const sram = saveRegion(cart) orelse return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = sram }) catch return;
    std.debug.print("wrote {s} ({d} bytes of battery SRAM)\n", .{ path, sram.len });
}

/// The split's S-CPU set file: little-endian u24 CPU addresses, sorted.
fn readScpuSet(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]const u24 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024));
    const n = bytes.len / 3;
    const list = try gpa.alloc(u24, n);
    for (0..n) |k| list[k] = @as(u24, bytes[k * 3]) | (@as(u24, bytes[k * 3 + 1]) << 8) | (@as(u24, bytes[k * 3 + 2]) << 16);
    std.mem.sort(u24, list, {}, std.sort.asc(u24));
    return list;
}

/// Merge the run's marks into the set file (a union across runs: one
/// file gathers every surface's census).
fn writeScpuSet(io: std.Io, gpa: std.mem.Allocator, path: []const u8) void {
    const m = core.wdc65816.dbg_scpu_set orelse return;
    if (readScpuSet(io, gpa, path)) |old| {
        for (old) |ac| {
            if ((ac & 0xFFFF) >= 0x8000 and ((ac >> 16) & 0x7F) < 0x40) m[(@as(usize, (ac >> 16) & 0x3F) << 15) | (ac & 0x7FFF)] = 1;
        }
    } else |_| {}
    var list: std.array_list.Managed(u8) = .init(gpa);
    var n: usize = 0;
    for (m, 0..) |b, off| {
        if (b == 0) continue;
        const ac: u24 = (@as(u24, @intCast(off >> 15)) << 16) | 0x8000 | @as(u24, @intCast(off & 0x7FFF));
        list.appendSlice(&.{ @truncate(ac), @truncate(ac >> 8), @truncate(ac >> 16) }) catch return;
        n += 1;
    }
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = list.items }) catch {};
    std.debug.print("[scpu-set] {} instruction address(es) in the SA-1's copy -> {s}\n", .{ n, path });
}

fn dumpRam(io: std.Io, gpa: std.mem.Allocator, con: *core.AnyConsole, path: []const u8) void {
    const fc = &con.fast;
    const buf = gpa.alloc(u8, 0x20000 + 0x20000 + 0x10000 + 0x800) catch unreachable;
    @memset(buf, 0);
    @memcpy(buf[0..0x20000], &fc.bus.wram.data);
    if (fc.bus.cart.chip == .sa1) @memcpy(buf[0x20000..][0..0x20000], fc.bus.sa1.bwram[0..0x20000]);
    @memcpy(buf[0x40000..][0..0x10000], std.mem.sliceAsBytes(fc.bus.ppu.vram[0..0x8000]));
    if (fc.bus.cart.chip == .sa1) @memcpy(buf[0x50000..][0..0x800], &fc.bus.sa1.iram);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf }) catch {};
    std.debug.print("[dump] pc={x:0>2}:{x:0>4} a={x:0>4} x={x:0>4} y={x:0>4} d={x:0>4} s={x:0>4} dbr={x:0>2} p={x:0>2} clk={}\n", .{ fc.cpu.regs.pbr, fc.cpu.regs.pc, fc.cpu.regs.c, fc.cpu.regs.x, fc.cpu.regs.y, fc.cpu.regs.d, fc.cpu.regs.s, fc.cpu.regs.dbr, fc.cpu.regs.p, fc.bus.clock });
    if (fc.bus.cart.chip == .sa1)
        std.debug.print("[dump] sa1 pc={x:0>2}:{x:0>4} smeg={x} cmeg={x} id={x:0>2} busy={x:0>2}\n", .{ fc.bus.sa1.cpu.regs.pbr, fc.bus.sa1.cpu.regs.pc, fc.bus.sa1.smeg, fc.bus.sa1.cmeg, fc.bus.sa1.iram[0x387], fc.bus.sa1.iram[0x38A] });
}

/// Load a .ymv and refuse every mismatch that would make the replay a lie:
/// wrong image (CRC of the stripped, post-patch image), wrong core accuracy,
/// or a conflicting explicit --region. Exits with a message rather than
/// returning an error — a bad movie is a usage problem, not a crash.
fn loadMovie(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    args: Args,
    path: []const u8,
    image: []const u8,
) util.movie.Movie {
    const fail = struct {
        fn f(o: *std.Io.Writer) noreturn {
            o.flush() catch {};
            std.process.exit(1);
        }
    }.f;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024)) catch {
        out.print("error: cannot read movie '{s}'\n", .{path}) catch {};
        fail(out);
    };
    var m = util.movie.parse(gpa, bytes) catch |e| {
        out.print("error: '{s}' is not a valid movie: {s}\n", .{ path, @errorName(e) }) catch {};
        fail(out);
    };
    m.start_srm = util.movie.loadStartSrm(io, gpa, path);
    if (m.lap_cell != 0) core.wdc65816.lap_cell = m.lap_cell; // a per-lap take: every console of this run ticks per lap
    const crc = util.movie.imageCrc(image);
    if (m.rom_crc != crc) {
        if (args.movie_ignore_crc) {
            out.print(
                "warning: movie '{s}' was recorded on image crc32 {x:0>8}; this run plays {x:0>8}\n" ++
                    "         (--movie-ignore-crc: replaying anyway; input may desync if timing changed)\n",
                .{ path, m.rom_crc, crc },
            ) catch {};
        } else {
            out.print(
                "error: movie '{s}' was recorded on image crc32 {x:0>8}; this run plays {x:0>8}\n" ++
                    "       (the movie identifies the image as played — a soft-patched game needs the same --patch)\n",
                .{ path, m.rom_crc, crc },
            ) catch {};
            fail(out);
        }
    }
    const acc: u8 = if (args.accuracy == .accurate) 1 else 0;
    if (m.accuracy != acc) {
        // `--movie-ignore-crc` waives this too: replaying a fast-core recording
        // on the accurate core is exactly how a renderer difference between the
        // two cores is isolated. Input may desync; the dumps still write.
        out.print("{s}: movie '{s}' was recorded on the {s} core; this run uses the {s} core\n", .{
            if (args.movie_ignore_crc) @as([]const u8, "warning") else "error",
            path,
            if (m.accuracy == 1) "accurate" else "fast",
            if (acc == 1) "accurate" else "fast",
        }) catch {};
        if (!args.movie_ignore_crc) fail(out);
    }
    const explicit_conflict = switch (args.region) {
        .auto => false,
        .ntsc => m.region != 0,
        .pal => m.region != 1,
    };
    if (explicit_conflict) {
        out.print("error: movie '{s}' was recorded in {s}; --region conflicts\n", .{
            path, if (m.region == 1) "PAL" else "NTSC",
        }) catch {};
        fail(out);
    }
    // The generator/report consoles run on the cart's auto-detected region
    // and take no override, so a movie recorded under one cannot reproduce
    // there. The normal run path applies the movie's region instead.
    if (args.gen_fastrom or args.gen_sa1 or args.sa1_report) {
        const auto_pal = core.header.detect(image) catch null;
        if (auto_pal) |h| {
            const auto_region: u8 = if (core.timing.regionFromHeaderByte(h.region) == .pal) 1 else 0;
            if (m.region != auto_region) {
                out.print(
                    "error: movie '{s}' was recorded under a region override ({s}); the profiled runs use the cart's own region\n",
                    .{ path, if (m.region == 1) "PAL" else "NTSC" },
                ) catch {};
                fail(out);
            }
        }
    }
    out.print("movie: {s} — {} frames, {s}, end hashes {s}\n", .{
        path,
        m.frames.len,
        if (m.region == 1) "PAL" else "NTSC",
        if (m.end_frame_hash != 0) "recorded" else "absent",
    }) catch {};
    return m;
}

/// Feed frame `i` of a movie into a console — both ports, released past the
/// movie's end. A no-op without a movie.
/// One frame of a behavioral replay: clear the poll flags, run, drain.
/// Returns true when the frame completed a logic tick (the snapshot is
/// filled and `snap.live` holds the interval's consumption since the
/// caller last cleared it).
/// TEMP experiment: delay the CONVERTED side's movie feed by this many
/// frames (a frame-aligned boot pad displaces the game's timeline; input
/// must follow it or every press lands early in game-time and forks the
/// run). Set by the undocumented --conv-pad flag.
pub var dbg_conv_pad: u32 = 0;
/// The split's mode cell as this machine holds it: WRAM on stock, the
/// BW-RAM window (the relocated home) on a conversion with an SA-1.
fn modeCell(con: *core.FastConsole, cell: u16) u8 {
    if (con.bus.sa1.bwram_mask != 0) return con.bus.sa1.bwram[cell & con.bus.sa1.bwram_mask];
    return con.bus.wram.data[cell];
}

/// --ref-overclock: the verifier's baseline S-CPU divisor.
pub var dbg_ref_overclock: u8 = 1;
/// --conv-overclock: the verifier's conversion-side divisor (S-CPU and SA-1).
pub var dbg_conv_overclock: u8 = 1;
pub var dbg_ref_oc_cell: u16 = 0;
pub var dbg_ref_oc_lo: u8 = 0;
pub var dbg_ref_oc_hi: u8 = 0;
/// Undocumented --site-ev <hex24>[,<hex24>...]: after profiling, print the
/// union evidence byte and coverage flags for each instruction address.
pub var dbg_site_ev: [16]u32 = @splat(0);
pub var dbg_n_site_ev: usize = 0;
/// Undocumented --ev-only: stop right after the --site-ev report, before any
/// plan, conversion, or verification work.
pub var dbg_ev_only: bool = false;
/// --audit: convert ONCE, print the per-site conversion audit, and stop
/// before verification — minutes instead of the whole ladder.
pub var dbg_audit: bool = false;

fn stepBehavioralFrame(con: *core.FastConsole, snap: *core.bus.Bus.TickSnap, feed: *util.movie.Feed, frame: u32) bool {
    // The feed consumes the poll latch first: the harness's own clear below
    // is for the tick snapshot, and must not eat the feed's signal.
    feed.step(con, frame);
    con.bus.input_polled = false;
    snap.captured = false;
    con.runFrame();
    var drain: [4096]i16 = undefined;
    while (con.readAudio(&drain) != 0) {}
    return snap.captured;
}

/// Learn the wall-coupled byte mask from the baseline: bytes that change
/// across a LAG frame (a short no-poll blip amid live gameplay) were
/// written by the NMI side. Long no-poll runs are loads and transitions,
/// where the game legitimately rewrites great swaths of WRAM — learning
/// from them buries real corruption inside the mask (a 23%-of-WRAM blind
/// spot on Gradius III; short-run learning masks ~500 bytes).
fn learnWallMask(gpa: std.mem.Allocator, image: []const u8, mov: ?util.movie.Movie, state: ?[]const u8, total: u32) ![]u8 {
    const wram_len = core.bus.Bus.TickSnap.wram_len;
    const lag_run_max = 3;
    const cart = try core.Cartridge.load(gpa, image);
    const con = try gpa.create(core.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    applySidecar(con, mov);
    // Anchored runs learn the mask from the anchored scene — a mask
    // learned at the attract demo says nothing about a gameplay stage's
    // wall-coupled bytes.
    if (state) |sb| try con.loadState(sb);
    const snap = try gpa.create(core.bus.Bus.TickSnap);
    defer gpa.destroy(snap);
    snap.* = .{};
    @memset(&snap.live, 0);
    @memset(&snap.written, 0);
    @memset(&snap.multi, 0);
    con.bus.tick_snap = snap;

    const mask = try gpa.alloc(u8, wram_len);
    @memset(mask, 0);
    const prev = try gpa.alloc(u8, wram_len);
    defer gpa.free(prev);
    const lagbuf = try gpa.alloc(u8, wram_len * lag_run_max);
    defer gpa.free(lagbuf);
    @memcpy(prev, &con.bus.wram.data);

    var ticks: u32 = 0;
    var lag_run: u32 = 0;
    var feed: util.movie.Feed = .init(mov);
    for (0..total) |i| {
        if (dbg_ref_overclock > 1 and i >= 300) {
            const v = modeCell(con, dbg_ref_oc_cell);
            con.bus.overclock = if (dbg_ref_oc_cell != 0 and v >= dbg_ref_oc_lo and v <= dbg_ref_oc_hi) dbg_ref_overclock else 1;
            con.bus.sa1.overclock = con.bus.overclock;
        }
        if (stepBehavioralFrame(con, snap, &feed, @intCast(i))) {
            if (lag_run > 0 and lag_run <= lag_run_max and ticks > 0) {
                for (0..lag_run) |r| {
                    const before = if (r == 0) prev else lagbuf[(r - 1) * wram_len ..];
                    const after = lagbuf[r * wram_len ..];
                    for (0..wram_len) |x| {
                        if (before[x] != after[x]) mask[x] = 1;
                    }
                }
            }
            lag_run = 0;
            ticks += 1;
            @memcpy(prev, &con.bus.wram.data);
        } else {
            if (lag_run < lag_run_max)
                @memcpy(lagbuf[lag_run * wram_len ..][0..wram_len], &con.bus.wram.data);
            lag_run += 1;
        }
    }
    return mask;
}

/// Where a logical WRAM byte lives in the CONVERTED image: unmoved bytes in
/// WRAM, relocated regions wherever the plan put them — but only regions
/// that actually moved (`region_sites` > 0; a "clean" region with zero
/// re-pointed sites moved vacuously and WRAM stays canonical).
const ConvHome = union(enum) { wram, sram: u32, iram: u32 };

fn convHome(plan: *const profile.Plan, res: *const core.sa1gen.Result, i: u32) ConvHome {
    for (plan.regions[0..plan.n], 0..) |r, ri| {
        if (res.fate[ri] != .clean or res.region_sites[ri] == 0) continue;
        if (i < r.start or i >= r.start + r.len) continue;
        return switch (r.dest) {
            .iram => .{ .iram = r.dest_off + (i - r.start) },
            .bwram => .{ .sram = r.dest_off + (i - r.start) },
        };
    }
    return .wram;
}

/// Frames a side may go without polling input before the tier calls it
/// stopped rather than merely out of budget. Five seconds: long enough
/// that a load, a scene transition or a fade cannot trip it, short enough
/// that a real wedge cannot hide under it.
const hang_frames: u32 = 300;

const Behavioral = struct {
    verdict: util.Persistence.Verdict,
    stats: util.Persistence,
    ticks_base: u32,
    ticks_conv: u32,
    /// Baseline wall frame of the first diverging tick (forensics anchor).
    first_bad_frame: u32,
    /// Sample of diverging addresses for the report.
    sample: [24]u32,
    n_sample: usize,
    /// Set when a persistence failure carries the RNG-FORK signature: the
    /// killer run was still open at surface end, the conversion never
    /// stopped ticking, and the fork sits in the surface's second half.
    /// Holds the baseline wall frame where the run began — the horizon a
    /// retry can verify up to (beyond it, tick-locked replay compares two
    /// different healthy games and proves nothing either way).
    fork_wall: ?u32,
    /// HOW the tick-locked pairing ended. A `persistence` verdict has two
    /// completely different causes wearing one message — live state that
    /// diverged and never healed, and a run that simply stopped pairing —
    /// and telling them apart by eye is impossible: a surface with SEVEN
    /// diverging ticks out of 1259 and a worst run of 4 was reported as
    /// "live state diverges and never heals" for a whole day.
    exit: Exit = .compared_to_budget,

    const Exit = enum {
        /// The baseline ran out of budget first. Normal for a conversion
        /// that removed slowdown: it needs fewer wall frames per tick.
        compared_to_budget,
        /// Neither side ever produced a tick.
        no_ticks,
        /// The CONVERSION ran out of budget while the baseline still had
        /// ticks to give — after the epoch resync had advanced it alone.
        /// The end of the comparable region, not a failure.
        conversion_ran_out,
        /// The conversion went `hang_frames` without polling input while
        /// the baseline kept ticking. This one IS a failure.
        conversion_hung,
        /// The conversion ran out while being caught up to an input edge
        /// the baseline had already crossed. NOT a failure — see the
        /// comment at the break — but disclosed, because the surface's
        /// tail went uncompared.
        conversion_ran_out_at_edge,

        fn describe(self: Exit) []const u8 {
            return switch (self) {
                .compared_to_budget => "baseline exhausted its budget (normal)",
                .no_ticks => "neither side produced a logic tick",
                .conversion_ran_out => "comparable region ended (the conversion, pushed ahead by epoch resyncs, exhausted its budget)",
                .conversion_hung => "the CONVERSION STOPPED POLLING while the baseline kept ticking",
                .conversion_ran_out_at_edge => "comparable region ended at an input edge (the conversion, being ahead, ran out of budget catching up)",
            };
        }
    };
};

/// The behavioral tier (`--verify-behavioral`): a conversion that removes
/// slowdown CANNOT be frame-identical to a slowed-down baseline — different
/// lag means different pictures, and the pixel gate rightly calls that
/// divergent. What lag cannot legitimately change is the game's LOGIC
/// state at each logic tick. So: run both images tick-locked (a tick = the
/// frame's first controller poll, the one phase-aligned moment two runs
/// with different lag share), and at every tick compare the bytes the
/// baseline's NEXT tick actually consumes (read-before-write liveness —
/// dead residue and stack slime never qualify), each read from wherever
/// the conversion relocated it, excluding the lag-learned wall-coupled
/// mask. Wall-DERIVED values leak through all of that (one taint hop past
/// the mask), so the verdict keys on persistence: echoes self-heal within
/// ticks over a bounded address set; corruption persists, spreads, or
/// floods.
///
/// Movie input breaks pure tick-locking: a button edge lands at a WALL
/// frame, and a run with less lag has executed MORE logic passes by then —
/// each run consumes the edge at a different tick index, and from there a
/// global pairing compares two different moments of the same correct game
/// (measured on Gradius III's menu: 79 ticks of menu-vs-attract, then
/// menu timers phase-offset forever). So the pairing realigns per input
/// EPOCH: when one run's tick stream crosses an edge before the other's,
/// the laggard advances alone — its surplus ticks have no counterpart and
/// go uncompared — and the pairing re-anchors at both runs' first tick of
/// the new epoch. The state carried ACROSS an edge from wall-time origins
/// (pass counters, timers seeded from them) stays offset by exactly the
/// passes the speedup bought; the persistence verdict excuses precisely
/// that shape — a held constant offset — and nothing else.
fn verifyBehavioral(
    gpa: std.mem.Allocator,
    base_image: []const u8,
    conv_image: []const u8,
    plan: *const profile.Plan,
    res: *const core.sa1gen.Result,
    mov: ?util.movie.Movie,
    state: ?[]const u8,
    /// Uniform window image: every WRAM byte's home is BW-RAM at the
    /// identity offset (`plan`/`res` are not consulted — the whole-game
    /// pipeline never builds a plan).
    window: bool,
    total: u32,
) !Behavioral {
    const wram_len = core.bus.Bus.TickSnap.wram_len;
    const mask = try learnWallMask(gpa, base_image, mov, state, total);
    defer gpa.free(mask);

    // The movie's input edges: wall frames where a pad mask changes. Each
    // edge starts a new pairing epoch (see the doc comment above).
    const edges: []const u32 = blk: {
        var list: std.array_list.Managed(u32) = .init(gpa);
        if (mov) |m| {
            var prev_mask: [2]u16 = .{ 0, 0 };
            for (m.frames, 0..) |f, i| {
                if (f[0] != prev_mask[0] or f[1] != prev_mask[1]) {
                    try list.append(@intCast(i));
                    prev_mask = f;
                }
            }
        }
        break :blk try list.toOwnedSlice();
    };
    defer gpa.free(edges);

    const Side = struct {
        con: *core.FastConsole,
        snap: *core.bus.Bus.TickSnap,
        prev: *core.bus.Bus.TickSnap,
        /// The take's input feed; a per-poll take advances per tick.
        feed: util.movie.Feed = .{ .mov = null },
        frame: u32 = 0,
        /// Wall frame of the current (last returned) tick.
        tick_wall: u32 = 0,
        /// Boot-pad displacement: this side's game timeline runs this many
        /// wall frames behind the movie's recording, so its inputs (and
        /// its input-edge epochs) shift to follow.
        pad: u32 = 0,
        /// Frames the last `advance` call consumed. A failed call that
        /// burned only a handful of them ran out of BUDGET; one that
        /// burned hundreds without a poll actually stopped ticking. The
        /// return value alone cannot tell those apart, and conflating
        /// them is what made the tier reject faster builds.
        span: u32 = 0,
        /// The reference overclock, engaged once the boot is behind (an
        /// overclocked S-CPU breaks the APU upload's handshake timing).
        oc: u8 = 1,
        /// ... and only while the mode cell holds a value in the split's
        /// gate range: the eras the SA-1 runs. Elsewhere the reference keeps
        /// real timing (an overclocked intro wedges on its own delay loops).
        oc_cell: u16 = 0,
        oc_lo: u8 = 0,
        oc_hi: u8 = 0,

        fn init(al: std.mem.Allocator, image: []const u8, m: ?util.movie.Movie) !@This() {
            const cart = try core.Cartridge.load(al, image);
            const con = try al.create(core.FastConsole);
            con.init(cart);
            applySidecar(con, m);
            const snap = try al.create(core.bus.Bus.TickSnap);
            snap.* = .{};
            @memset(&snap.live, 0);
            @memset(&snap.written, 0);
            @memset(&snap.multi, 0);
            con.bus.tick_snap = snap;
            return .{ .con = con, .snap = snap, .prev = try al.create(core.bus.Bus.TickSnap) };
        }

        fn advance(self: *@This(), m: ?util.movie.Movie, budget: u32) bool {
            if (self.feed.mov == null) self.feed = .init(m);
            const from = self.frame;
            while (self.frame < budget) {
                if (self.oc > 1 and self.frame >= 300) {
                    const v = modeCell(self.con, self.oc_cell);
                    self.con.bus.overclock = if (self.oc_cell != 0 and v >= self.oc_lo and v <= self.oc_hi) self.oc else 1;
                    self.con.bus.sa1.overclock = self.con.bus.overclock;
                }
                const ticked = stepBehavioralFrame(self.con, self.snap, &self.feed, self.frame -| self.pad);
                self.frame += 1;
                if (ticked) {
                    self.tick_wall = self.frame - 1;
                    self.span = self.frame - from;
                    return true;
                }
            }
            self.span = self.frame - from;
            return false;
        }

        /// Which input epoch this side's current tick sits in: the number
        /// of edges its tick stream has sampled.
        fn epoch(self: *const @This(), es: []const u32) usize {
            var n: usize = 0;
            while (n < es.len and es[n] <= self.tick_wall -| self.pad) n += 1;
            return n;
        }
    };

    var base = try Side.init(gpa, base_image, mov);
    var conv = try Side.init(gpa, conv_image, mov);
    conv.pad = dbg_conv_pad;
    base.oc = dbg_ref_overclock;
    base.oc_cell = dbg_ref_oc_cell;
    base.oc_lo = dbg_ref_oc_lo;
    base.oc_hi = dbg_ref_oc_hi;
    conv.oc = dbg_conv_overclock;
    conv.oc_cell = dbg_ref_oc_cell;
    conv.oc_lo = dbg_ref_oc_lo;
    conv.oc_hi = dbg_ref_oc_hi;
    if (state) |sb| {
        try base.con.loadState(sb);
        try seedConverted(conv.con, sb, plan, res);
    }

    var out: Behavioral = .{
        .verdict = .{ .pass = .clean },
        .stats = .{ .epoch_budget = @intCast(edges.len + 1) },
        .ticks_base = 0,
        .ticks_conv = 0,
        .first_bad_frame = 0,
        .sample = @splat(0),
        .n_sample = 0,
        .fork_wall = null,
    };
    // Baseline wall frame of each FED tick, indexed like the tick indices
    // handed to Persistence.feed — what maps a verdict's tick back to a
    // wall frame (the fork-horizon retry needs the killer run's start).
    var tick_walls = try gpa.alloc(u32, total + 1);
    defer gpa.free(tick_walls);
    var n_tick_walls: usize = 0;

    // Tick 0 on both sides.
    if (!base.advance(mov, total)) {
        out.exit = .no_ticks;
        return out; // vacuous
    }
    if (!conv.advance(mov, total)) {
        // The baseline reached gameplay and the conversion never did.
        out.verdict = .{ .fail = .persistence };
        out.exit = .conversion_hung;
        return out;
    }
    out.ticks_base = 1;
    out.ticks_conv = 1;
    base.prev.* = base.snap.*;
    conv.prev.* = conv.snap.*;
    @memset(&base.snap.live, 0);
    @memset(&base.snap.written, 0);
    @memset(&base.snap.multi, 0);
    var prev_frame: u32 = base.frame;

    // Intra-frame stream detection: a byte the BASELINE writes more than
    // once inside one tick interval is mid-stream at every snapshot
    // instant (an APU pump's cursor, its data buffers, a handshake cell)
    // — its value at the poll is phase, not logic, and a timing-shifted
    // conversion can never match it at the same tick. A cell that
    // streams in eight intervals joins the wall mask by CONSTRUCTION —
    // previously this class was absorbed only when a surface's
    // lag-learned mask happened to cover it, which is why one surface
    // passed and another failed on identical input.
    const stream_ticks = try gpa.alloc(u8, wram_len);
    defer gpa.free(stream_ticks);
    @memset(stream_ticks, 0);

    // Which home each WRAM cell actually lives in on the conversion,
    // learned from the ticks where it AGREED with the baseline (0 unknown,
    // 1 BW-RAM, 2 real WRAM). A window image splits homes by access idiom
    // — low 8K and $7E-long cells live in BW-RAM, abs-addressed high WRAM
    // stays put — and a divergence must be measured at the LIVE home: the
    // stale other home is dead boot residue, and a delta against dead
    // zeros drifts as the baseline moves, faking active divergence out of
    // a held offset.
    const home = try gpa.alloc(u8, wram_len);
    defer gpa.free(home);
    @memset(home, 0);

    var bad: [util.Persistence.max_addrs + 1]util.Persistence.Bad = undefined;
    var prev_n_bad: usize = 0;
    // The lag differential at the previous tick pair: how many more wall
    // frames the baseline has spent than the conversion to reach the same
    // logic tick. Wall-coupled state (NMI counters, anything seeded from
    // them) drifts by exactly this, so persistence accounting is only
    // meaningful on ticks where it HELD STILL — a slowdown-removing
    // conversion legitimately walks it up through every stretch whose
    // frames it stopped dropping (measured: 79 frames across a load).
    var ld_prev: i64 = @as(i64, base.tick_wall) - (@as(i64, conv.tick_wall) - @as(i64, conv.pad));
    outer: while (true) {
        const pair_ld: i64 = @as(i64, base.tick_wall) - (@as(i64, conv.tick_wall) - @as(i64, conv.pad));
        const wall_stable = pair_ld == ld_prev;
        ld_prev = pair_ld;
        if (!base.advance(mov, total)) break;
        out.ticks_base += 1;
        if (!conv.advance(mov, total)) {
            // Ran out of budget, or hung — and only the SPAN tells them
            // apart. The epoch resync below advances the conversion
            // alone, so a faster conversion's frame counter is routinely
            // pushed past the baseline's; it then exhausts the budget
            // here having polled input a frame ago. That is the end of
            // the comparable region. A conversion that truly stopped
            // burns `hang_frames` without a single poll.
            if (conv.span < hang_frames) {
                out.exit = .conversion_ran_out;
                break;
            }
            // A long no-poll SPAN is only a hang while input remains. A
            // conversion that has consumed every input edge is simply
            // AHEAD — it finished the movie's logic early (the removed
            // slowdown, i.e. the point of the patch) and now sits in
            // whatever no-poll state the story ends in (a load, a fade)
            // while the baseline still chews through its lag.
            if (conv.epoch(edges) >= edges.len) {
                out.exit = .conversion_ran_out;
                break;
            }
            out.verdict = .{ .fail = .persistence };
            out.exit = .conversion_hung;
            return out;
        }
        out.ticks_conv += 1;

        // Epoch resync: an input edge reaches each run at its own tick
        // index. When one side has crossed an edge the other hasn't, the
        // pairing is between different epochs — advance the laggard alone
        // (its surplus ticks have no counterpart) and re-anchor at both
        // sides' first tick of the new epoch, comparing from there.
        if (base.epoch(edges) != conv.epoch(edges)) {
            while (base.epoch(edges) != conv.epoch(edges)) {
                if (base.epoch(edges) > conv.epoch(edges)) {
                    if (!conv.advance(mov, total)) {
                        // NOT a hang, and calling it one was costing real
                        // builds. The conversion is AHEAD — it spends
                        // fewer wall frames per logic tick, which is the
                        // entire point — so it sits at an earlier wall
                        // frame than the baseline, and catching it up to
                        // the baseline's epoch burns whatever budget it
                        // has left. Near the end of a surface it runs out.
                        // That is the end of the COMPARABLE REGION, not a
                        // failure: everything paired so far was paired
                        // honestly, and the verdict belongs to those
                        // ticks. (The genuine hang is the other exit —
                        // the conversion stopping while the baseline
                        // still ticks, in the main pairing above.)
                        //
                        // Measured: a surface with SEVEN diverging ticks
                        // out of 1259 and a worst run of 4 was reported
                        // as "live state diverges and never heals", and
                        // whether a build hit this depended on where the
                        // last input edge fell relative to its own lag
                        // differential — so any timing change (FastROM, a
                        // tree, a thunk) could flip a verdict without
                        // touching correctness.
                        if (conv.span >= hang_frames and conv.epoch(edges) < edges.len) {
                            out.verdict = .{ .fail = .persistence };
                            out.exit = .conversion_hung;
                            return out;
                        }
                        out.exit = .conversion_ran_out_at_edge;
                        break :outer;
                    }
                    out.ticks_conv += 1;
                } else {
                    if (!base.advance(mov, total)) break :outer;
                    out.ticks_base += 1;
                }
            }
            base.prev.* = base.snap.*;
            conv.prev.* = conv.snap.*;
            @memset(&base.snap.live, 0);
            @memset(&base.snap.written, 0);
            @memset(&base.snap.multi, 0);
            prev_frame = base.frame;
            // Re-anchor the lag differential too: the laggard's surplus
            // ticks moved one side's wall alone.
            ld_prev = @as(i64, base.tick_wall) - (@as(i64, conv.tick_wall) - @as(i64, conv.pad));
            continue;
        }

        // Streams first: cells the baseline multi-wrote this interval.
        for (0..wram_len / 8) |bi| {
            var mm = base.snap.multi[bi];
            while (mm != 0) {
                const bit: u3 = @intCast(@ctz(mm));
                mm &= mm - 1;
                const i = bi * 8 + @as(usize, bit);
                if (stream_ticks[i] < 8) {
                    stream_ticks[i] += 1;
                    if (stream_ticks[i] == 8) mask[i] = 1;
                }
            }
        }

        // Compare the PREVIOUS tick pair on the bytes this baseline
        // interval consumed.
        var n_bad: usize = 0;
        const live = &base.snap.live;
        for (0..wram_len) |i| {
            if (live[i >> 3] & (@as(u8, 1) << @intCast(i & 7)) == 0) continue;
            if (mask[i] != 0) continue;
            const bb = base.prev.wram[i];
            const cb = if (window) blk: {
                // A window image moves every code-path WRAM reference to
                // BW-RAM at the identity offset — but WMDATA-port traffic
                // still lands in real WRAM, and nothing records which
                // path wrote a given byte last. A byte matching EITHER
                // home passes; matching neither is a real divergence.
                // One more equivalence: the relocation maps WRAM bank
                // VALUES, so data holding $7E/$7F (a pointer's bank byte)
                // legitimately holds $40/$41 in the image — permanently,
                // which the persistence verdict would otherwise read as
                // immortal corruption.
                const via_bw = conv.prev.sram[i];
                const via_wram = conv.prev.wram[i];
                // The home is learned ONCE, from a discriminating equality
                // (the homes disagree and the baseline matches exactly
                // one), and then sticks: a dead home's zero coincidentally
                // matching a transiting baseline value must not re-teach
                // the cell's address (measured: stock's $3A wrapping
                // through 00 matched the stale WRAM zero and every later
                // delta drifted again).
                if (bb == via_bw or (bb == 0x7E and via_bw == 0x40) or (bb == 0x7F and via_bw == 0x41)) {
                    if (home[i] == 0 and via_bw != via_wram) home[i] = 1;
                    break :blk bb;
                }
                if (bb == via_wram or (bb == 0x7E and via_wram == 0x40) or (bb == 0x7F and via_wram == 0x41)) {
                    if (home[i] == 0 and via_bw != via_wram) home[i] = 2;
                    break :blk bb;
                }
                // Diverged at both homes: report the live home's value so
                // the persistence delta tracks what the game computes.
                break :blk switch (home[i]) {
                    1 => via_bw,
                    2 => via_wram,
                    else => if (i < 0x2000) via_bw else via_wram,
                };
            } else switch (convHome(plan, res, @intCast(i))) {
                .wram => conv.prev.wram[i],
                .sram => |off| conv.prev.sram[off],
                .iram => |off| conv.prev.iram[off & 0x7FF],
            };
            if (bb == cb) continue;
            if (n_bad < bad.len) {
                bad[n_bad] = .{ .addr = @intCast(i), .delta = bb -% cb };
                n_bad += 1;
            }
        }
        if (n_bad > 0 and out.stats.first_bad == null) {
            out.first_bad_frame = prev_frame;
            out.n_sample = @min(out.sample.len, n_bad);
            for (out.sample[0..out.n_sample], bad[0..out.n_sample]) |*s, b| s.* = b.addr | (@as(u32, b.delta) << 16);
        }
        // Forensics on stderr: each bad-run START with both machines' wall
        // frames and cell values — the tick<->wall mapping is nonlinear
        // (loads stretch hundreds of wall frames per tick) and chasing a
        // tick-domain divergence with wall-domain probes wastes hours.
        if (n_bad > 0 and (prev_n_bad == 0 or out.ticks_base % 50 == 0)) {
            std.debug.print("[bfx] run start tick={} base_wall={} conv_wall={} n_bad={}:", .{ out.ticks_base, base.frame, conv.frame, n_bad });
            for (bad[0..@min(8, n_bad)]) |b| {
                const cv = b.addr; // conv value recomputed below for the print
                _ = cv;
                std.debug.print(" ${X:0>4}(d{X:0>2})", .{ b.addr, b.delta });
            }
            std.debug.print("\n", .{});
        }
        prev_n_bad = n_bad;
        if (out.ticks_base - 2 < tick_walls.len) {
            tick_walls[out.ticks_base - 2] = prev_frame;
            n_tick_walls = @max(n_tick_walls, out.ticks_base - 1);
        }
        out.stats.feed(out.ticks_base - 2, bad[0..n_bad], wall_stable);

        base.prev.* = base.snap.*;
        conv.prev.* = conv.snap.*;
        @memset(&base.snap.live, 0);
        @memset(&base.snap.written, 0);
        @memset(&base.snap.multi, 0);
        prev_frame = base.frame;
    }

    out.verdict = out.stats.verdict();
    // The RNG-fork signature: a persistence failure whose killer run was
    // still open at surface end, on a conversion that kept ticking, with
    // the fork in the surface's second half. Report the wall frame where
    // the run began so the caller can verify up to the horizon.
    // (A conversion that stopped ticking never reaches this analysis —
    // those verdicts return early from the advance failures above.)
    // The FORK-EPISODE shape: a timing-changed conversion forks the game
    // at each RNG-sensitive moment (a demo, a transition whose sound
    // phase shifted); each episode that HEALS was reconverged by a scene
    // reset — corruption does not reconverge to byte-equivalence. A small
    // number of bounded episodes qualifies for the prefix-retry excusal
    // when everything OUTSIDE them held: few episodes, a substantial
    // verified prefix before the first, the excused fraction small, and
    // the off-episode surface within the flood budget.
    if (out.verdict == .fail and out.verdict.fail == .persistence and
        out.stats.long_runs <= 4 and
        out.stats.long_total * 4 <= out.stats.stable_ticks and
        (@as(u64, out.stats.bad_ticks - out.stats.long_total - out.stats.burst_total) * 1000 <=
            @as(u64, out.stats.stable_ticks) * util.Persistence.max_bad_per_mille * 3) and
        out.stats.first_long_start != null and
        out.stats.first_long_start.? > 600 and
        out.stats.first_long_start.? < n_tick_walls)
    {
        out.fork_wall = tick_walls[out.stats.first_long_start.?];
    }
    return out;
}

/// `--tick-dump`: one record per logic tick — u32 wall frame (little-endian)
/// followed by the phase-aligned snapshot the bus captured at that tick's
/// controller poll: 128 KiB WRAM, 128 KiB cartridge RAM (BW-RAM), 2 KiB SA-1
/// I-RAM — the relocated homes too, because a conversion moves state and a
/// WRAM-only view is blind exactly where a broken offload does its damage. The offline analysis behind the behavioral
/// verifier's design; not part of any verification path itself.
fn runTickDump(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    args: Args,
    cart: core.Cartridge,
    mov: ?util.movie.Movie,
    path: []const u8,
) !void {
    const con = try gpa.create(core.FastConsole);
    con.init(cart);
    if (args.auto_fastrom) con.bus.enableAutoFastrom();
    if (args.state) |spath| try loadStateInto(io, gpa, out, con, spath);
    try applyStartSave(io, gpa, con, args, mov, out);
    try anchorMovie(con, mov, "movie", out);

    const snap = try gpa.create(core.bus.Bus.TickSnap);
    snap.* = .{};
    @memset(&snap.live, 0);
    @memset(&snap.written, 0);
    @memset(&snap.multi, 0);
    con.bus.tick_snap = snap;

    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch {
        try out.print("error: cannot create '{s}'\n", .{path});
        try out.flush();
        std.process.exit(1);
    };
    defer file.close(io);
    var fbuf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &fbuf);

    // Lag-frame mask: bytes that change across a LAG frame were written by
    // the NMI side (or by the main loop's stalled mid-computation) — the
    // candidate set for "legitimately wall-coupled". Lag means genuine
    // slowdown: a SHORT no-poll blip amid live gameplay. Long no-poll runs
    // are loads and transitions, where the game legitimately rewrites great
    // swaths of WRAM — learning from those buries real corruption inside
    // the mask (a 23% blind spot on Gradius III), so runs longer than
    // `lag_run_max` teach nothing.
    const lag_run_max = 3;
    const prev = try gpa.alloc(u8, core.bus.Bus.TickSnap.wram_len);
    const lagbuf = try gpa.alloc(u8, core.bus.Bus.TickSnap.wram_len * lag_run_max);
    const mask = try gpa.alloc(u8, core.bus.Bus.TickSnap.wram_len);
    @memset(mask, 0);
    @memcpy(prev, &con.bus.wram.data);

    const frames = args.frames orelse 600;
    var ticks: u32 = 0;
    var lag_run: u32 = 0;
    var drain: [4096]i16 = undefined;
    var feed: util.movie.Feed = .init(mov);
    for (0..frames) |i| {
        feed.step(con, i);
        con.bus.input_polled = false;
        snap.captured = false;
        con.runFrame();
        while (con.readAudio(&drain) != 0) {}
        if (snap.captured) {
            var hdr: [4]u8 = undefined;
            std.mem.writeInt(u32, &hdr, @intCast(i), .little);
            try fw.interface.writeAll(&hdr);
            // The liveness accumulated since the LAST poll: which bytes of
            // the previous tick's state this interval actually consumed.
            try fw.interface.writeAll(&snap.live);
            try fw.interface.writeAll(&snap.wram);
            try fw.interface.writeAll(&snap.sram);
            try fw.interface.writeAll(&snap.iram);
            @memset(&snap.live, 0);
            @memset(&snap.written, 0);
            @memset(&snap.multi, 0);
            ticks += 1;
            // The no-poll run just ended: it was lag (not a load) only if
            // it stayed short, and only then does it teach the mask.
            if (lag_run > 0 and lag_run <= lag_run_max and ticks > 1) {
                for (0..lag_run) |r| {
                    const before = if (r == 0) prev else lagbuf[(r - 1) * core.bus.Bus.TickSnap.wram_len ..];
                    const after = lagbuf[r * core.bus.Bus.TickSnap.wram_len ..];
                    for (0..core.bus.Bus.TickSnap.wram_len) |x| {
                        if (before[x] != after[x]) mask[x] = 1;
                    }
                }
            }
            lag_run = 0;
            @memcpy(prev, &con.bus.wram.data);
        } else {
            if (lag_run < lag_run_max)
                @memcpy(lagbuf[lag_run * core.bus.Bus.TickSnap.wram_len ..][0..core.bus.Bus.TickSnap.wram_len], &con.bus.wram.data);
            lag_run += 1;
        }
    }
    // The mask rides at the tail: 128 KiB of 0/1 after the tick records.
    try fw.interface.writeAll(mask);
    try fw.interface.flush();
    var masked: u32 = 0;
    for (mask) |m| masked += m;
    try out.print("{s}: {} ticks in {} frames, {} lag-touched bytes -> {s}\n", .{ args.rom, ticks, frames, masked, path });
    try out.flush();
}

/// `--state`: resume from an SDL-player save state instead of power-on —
/// which lets the profiler measure a scene the attract demo never reaches
/// (a slowdown-heavy stage the player save-stated, say) without replaying
/// a movie to get there. The state must be from the same image and core;
/// the serializer's own container checks refuse anything else.
fn loadStateInto(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    con: anytype,
    path: []const u8,
) !void {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024)) catch {
        try out.print("error: cannot read state '{s}'\n", .{path});
        try out.flush();
        std.process.exit(1);
    };
    con.loadState(data) catch |e| {
        try out.print("error: state '{s}' does not load into this console: {s}\n", .{ path, @errorName(e) });
        try out.flush();
        std.process.exit(1);
    };
    try out.print("state loaded: {s}\n", .{path});
    try out.flush();
}

/// Seed a CONVERTED image's console from a save state recorded on a
/// DIFFERENT image of the same game — the stock ROM, or an earlier
/// conversion (the S3 stage leaves the WRAM layout in place, so the
/// serialized machine loads wholesale). Two halves are stale afterwards
/// and get rebuilt here: the SA-1 (the saved PC pointed into whatever the
/// old image carved, so it is re-booted from THIS image's CRV, exactly
/// the writes the shim makes at reset) and the live relocated regions
/// (the plan moved those bytes out of WRAM, so the state's WRAM copy is
/// the truth and seeds their new homes).
fn seedConverted(
    con: anytype,
    state: []const u8,
    plan: *const profile.Plan,
    res: *const core.sa1gen.Result,
) !void {
    try con.loadState(state);
    const sa1 = &con.bus.sa1;
    const clk = con.bus.clock;
    sa1.mmioWrite(clk, 0x2200, 0x20); // hold RESB
    sa1.mmioWrite(clk, 0x2229, 0xFF); // SIWP: S-CPU may write I-RAM
    sa1.mmioWrite(clk, 0x2226, 0x80); // SWEN: S-CPU may write BW-RAM
    sa1.mmioWrite(clk, 0x2203, @truncate(res.stats.crv));
    sa1.mmioWrite(clk, 0x2204, @truncate(res.stats.crv >> 8));
    sa1.mmioWrite(clk, 0x2200, 0x00); // release: boot from CRV
    sa1.cmeg = 0; // drop a stale done echo from the old image's run
    sa1.iram[0x38A] = 0; // async busy flag idle
    for (plan.regions[0..plan.n], 0..) |r, ri| {
        if (res.fate[ri] != .clean) continue;
        if (res.region_sites[ri] == 0 and !(r.dp and res.stats.d_moved)) continue;
        const src = con.bus.wram.data[r.start .. r.start + r.len];
        switch (r.dest) {
            .iram => @memcpy(sa1.iram[r.dest_off..][0..r.len], src),
            .bwram => @memcpy(sa1.bwram[r.dest_off..][0..r.len], src),
        }
    }
}

/// Bump when the profiler's products change meaning (usage flags, site
/// evidence classes, what counts as a proven bank byte): every cached
/// harvest keyed on the old version is then ignored, never misread.
const harvest_cache_version: u32 = 1;
const harvest_cache_magic = "YHC1";

fn harvestCachePath(buf: []u8, dir: []const u8, img_crc: u32, movie_hash: u64) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/harvest-{x:0>8}-{x:0>16}-v{d}.bin", .{ dir, img_crc, movie_hash, harvest_cache_version });
}

fn hcRead32(d: []const u8, p: *usize) ?u32 {
    if (p.* + 4 > d.len) return null;
    const v = std.mem.readInt(u32, d[p.*..][0..4], .little);
    p.* += 4;
    return v;
}

fn hcRead64(d: []const u8, p: *usize) ?u64 {
    if (p.* + 8 > d.len) return null;
    const v = std.mem.readInt(u64, d[p.*..][0..8], .little);
    p.* += 8;
    return v;
}

/// Read one cached harvest into the pair's products. False (nothing to be
/// trusted in the outputs) on any mismatch: wrong magic, version, image or
/// movie, a truncated body, or an address outside the map.
fn loadHarvestCache(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    img_crc: u32,
    movie_hash: u64,
    usage: []u8,
    ev: []u8,
    pb: *core.usage_map.PtrBankEvidence,
) bool {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 * 1024 * 1024)) catch return false;
    defer gpa.free(data);
    if (data.len < 4 or !std.mem.eql(u8, data[0..4], harvest_cache_magic)) return false;
    var o: usize = 4;
    if ((hcRead32(data, &o) orelse return false) != harvest_cache_version) return false;
    if ((hcRead32(data, &o) orelse return false) != img_crc) return false;
    if ((hcRead64(data, &o) orelse return false) != movie_hash) return false;
    const n = hcRead32(data, &o) orelse return false;
    if (o + @as(usize, n) * 6 > data.len) return false;
    for (0..n) |_| {
        const pc = std.mem.readInt(u32, data[o..][0..4], .little);
        if (pc >= usage.len) return false;
        usage[pc] = data[o + 4];
        ev[pc] = data[o + 5];
        o += 6;
    }
    const np = hcRead32(data, &o) orelse return false;
    for (0..np) |_| pb.addProven(hcRead32(data, &o) orelse return false);
    const nt = hcRead32(data, &o) orelse return false;
    for (0..nt) |_| {
        const t = hcRead32(data, &o) orelse return false;
        pb.addHdmaTable(@intCast(t & 0xFF_FFFF));
    }
    return true;
}

/// Write the pair's products sparsely: only map cells that are non-zero.
/// Best-effort — a cache that cannot be written just means a replay next
/// time.
fn saveHarvestCache(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: []const u8,
    path: []const u8,
    img_crc: u32,
    movie_hash: u64,
    usage: []const u8,
    ev: []const u8,
    pb: *const core.usage_map.PtrBankEvidence,
) void {
    var n: usize = 0;
    for (usage, ev) |u, e| {
        if (u != 0 or e != 0) n += 1;
    }
    const size = 4 + 4 + 4 + 8 + 4 + n * 6 + 4 + pb.n_proven * 4 + 4 + pb.n_hdma_tables * 4;
    const buf = gpa.alloc(u8, size) catch return;
    defer gpa.free(buf);
    @memcpy(buf[0..4], harvest_cache_magic);
    var o: usize = 4;
    std.mem.writeInt(u32, buf[o..][0..4], harvest_cache_version, .little);
    o += 4;
    std.mem.writeInt(u32, buf[o..][0..4], img_crc, .little);
    o += 4;
    std.mem.writeInt(u64, buf[o..][0..8], movie_hash, .little);
    o += 8;
    std.mem.writeInt(u32, buf[o..][0..4], @intCast(n), .little);
    o += 4;
    for (usage, ev, 0..) |u, e, pc| {
        if (u == 0 and e == 0) continue;
        std.mem.writeInt(u32, buf[o..][0..4], @intCast(pc), .little);
        buf[o + 4] = u;
        buf[o + 5] = e;
        o += 6;
    }
    std.mem.writeInt(u32, buf[o..][0..4], @intCast(pb.n_proven), .little);
    o += 4;
    for (pb.proven[0..pb.n_proven]) |a| {
        std.mem.writeInt(u32, buf[o..][0..4], a, .little);
        o += 4;
    }
    std.mem.writeInt(u32, buf[o..][0..4], @intCast(pb.n_hdma_tables), .little);
    o += 4;
    for (pb.hdma_tables[0..pb.n_hdma_tables]) |t| {
        std.mem.writeInt(u32, buf[o..][0..4], @as(u32, t), .little);
        o += 4;
    }
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf[0..o] }) catch {};
}

/// Restore the machine a movie's inputs were recorded against, before its
/// first frame runs. A movie recorded from power-on carries no anchor and
/// this is a no-op; an anchored one is meaningless without it, so a state
/// this console refuses is fatal rather than skipped — replaying anchored
/// inputs from power-on produces a plausible-looking run of pure nonsense.
///
/// The console must be the image the anchor was taken on. That holds for
/// replay, the stale detector and the cover harvest (all replay a recording
/// on its own image); it does NOT hold for a stock-side verification surface
/// in window mode, which is refused at load time instead.
/// Conversion-side site evidence fills in only where stock evidence is
/// absent (see the maps' declaration). Returns the stock map, now complete.
fn foldConvEvidence(site_ev: []u8, conv: []const u8, out: *std.Io.Writer) []u8 {
    var folded: u32 = 0;
    var shadowed: u32 = 0;
    for (site_ev, conv) |*s, c| {
        if (c == 0) continue;
        if (s.* == 0) {
            s.* = c;
            folded += 1;
        } else if (s.* != c) shadowed += 1;
    }
    out.print("  site evidence: {} site(s) classified by conversion-side replays alone; {} with a differing conversion-side class deferred to stock\n", .{ folded, shadowed }) catch {};
    out.flush() catch {};
    return site_ev;
}

fn anchorMovie(con: anytype, mov: ?util.movie.Movie, what: []const u8, out: *std.Io.Writer) !void {
    const m = mov orelse return;
    const a = m.anchor orelse return;
    con.loadState(a) catch |e| {
        try out.print("error: the {s} carries a start state this console cannot restore: {s}\n" ++
            "       (a save state is tied to the core's layout and the image it was taken on)\n", .{ what, @errorName(e) });
        try out.flush();
        std.process.exit(1);
    };
    try out.print("movie anchor: {s} restored ({} frames replay from it)\n", .{ what, m.frames.len });
    try out.flush();
}

fn feedMovie(con: anytype, mov: ?util.movie.Movie, i: usize) void {
    const m = mov orelse return;
    const f: [2]u16 = if (i < m.frames.len) m.frames[i] else .{ 0, 0 };
    con.setButtons(0, f[0]);
    con.setButtons(1, f[1]);
}

/// The `drainAudio` sink for the SA-1 gate's runs: fold each chunk into the
/// current frame's energy cell, building the per-frame envelope the
/// audio-tolerant tier compares.
const EnergySink = struct {
    cell: *u64,

    fn add(self: EnergySink, chunk: []const i16) anyerror!void {
        var sum: u64 = 0;
        for (chunk) |s| sum += @abs(s);
        self.cell.* += sum;
    }
};

/// The `drainAudio` sink for the main run loop: track peak amplitude always,
/// and accumulate samples for a WAV dump when one was requested.
const AudioSink = struct {
    peak: *u16,
    wav: ?*std.array_list.Managed(i16),

    fn collect(self: AudioSink, chunk: []const i16) !void {
        for (chunk) |s| self.peak.* = @max(self.peak.*, @abs(s));
        if (self.wav) |w| try w.appendSlice(chunk);
    }
};

/// Apply `--patch`: reads the patch file, strips the ROM's copier header (the
/// community's patches are made against unheadered images), applies, and
/// reports what kind of guarantee the format could give. Errors are printed
/// here so every failure names its cause; the caller just exits.
fn applyPatch(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    image: []u8,
    patch_path: []const u8,
) ![]u8 {
    const pbytes = std.Io.Dir.cwd().readFileAlloc(io, patch_path, gpa, .limited(16 * 1024 * 1024)) catch {
        try out.print("error: cannot read patch '{s}'\n", .{patch_path});
        try out.flush();
        return error.PatchFailed;
    };
    return applyBytes(gpa, out, core.header.stripCopierHeader(image), pbytes, patch_path);
}

/// Apply already-read patch bytes to an already-stripped image, reporting what
/// kind of guarantee the format could give. Shared by `--patch` (which read
/// the file the user named) and `--auto-patch` (which read — and hash-verified
/// — the file the registry named).
fn applyBytes(
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    stripped: []const u8,
    pbytes: []const u8,
    patch_path: []const u8,
) ![]u8 {
    var mm: core.patch.CrcMismatch = .{};
    const res = core.patch.apply(gpa, stripped, pbytes, &mm) catch |e| {
        switch (e) {
            error.WrongSource => try out.print(
                "error: patch '{s}' is for a different ROM revision: it wants source crc32 {x:0>8}, this ROM is {x:0>8}\n",
                .{ patch_path, mm.expected, mm.actual },
            ),
            error.PatchChecksum => try out.print("error: patch '{s}' is damaged (its own checksum fails)\n", .{patch_path}),
            error.TargetChecksum => try out.print("error: patch '{s}' applied but the output failed its target checksum\n", .{patch_path}),
            error.UnknownFormat => try out.print("error: '{s}' is neither a BPS nor an IPS patch\n", .{patch_path}),
            error.Corrupt => try out.print("error: patch '{s}' is structurally broken\n", .{patch_path}),
            error.OutOfMemory => try out.print("error: out of memory applying '{s}'\n", .{patch_path}),
        }
        try out.flush();
        return error.PatchFailed;
    };
    if (res.verified) {
        try out.print("patch applied: {s} (source and target checksums verified)\n", .{patch_path});
    } else {
        try out.print("patch applied: {s} (IPS carries no checksums; the result is unverified)\n", .{patch_path});
    }
    try out.flush();
    return res.image;
}

/// The `--auto-fastrom` compat gate: `broken` refuses with its reason (an
/// error), `ok` proceeds, anything else — `untested` or absent — runs behind
/// a warning the user is meant to read. The option is already an explicit
/// flag, so the unknown case warns rather than refuses.
fn checkFastromCompat(out: *std.Io.Writer, stripped: []const u8) !void {
    defer out.flush() catch {};
    const hex = core.registry.sha256Hex(stripped);
    if (core.fastrom_compat.find(&hex)) |e| {
        switch (e.status) {
            .ok => try out.print("auto-fastrom: {s} is verified compatible\n", .{e.title}),
            .broken => {
                try out.print("error: auto-fastrom: {s} is known BROKEN with FastROM timing: {s}\n", .{ e.title, e.note });
                return error.FastromIncompatible;
            },
            .untested => try out.print(
                "auto-fastrom: WARNING: {s} is listed but untested ({s}) — expect anything from nothing to corrupted saves\n",
                .{ e.title, e.note },
            ),
        }
    } else {
        try out.print(
            "auto-fastrom: WARNING: this ROM (sha256 {s}) is not in patches/fastrom-compat.zon —\n" ++
                "  untested with FastROM timing; expect anything from nothing to corrupted saves\n",
            .{&hex},
        );
    }
}

/// What `--auto-patch` should do, decided from the registry lookup and the
/// bytes found (or not) at the registered patch's path. Pure — the I/O wrapper
/// below feeds it, and the unit tests drive all four flows synthetically.
const AutoPatchDecision = union(enum) {
    /// The loaded ROM's hash is not in the registry: run unpatched.
    unknown,
    /// Registered, but the patch file is absent: print where to fetch it
    /// (never fetch it ourselves), run unpatched.
    missing: *const core.registry.Entry,
    /// A file exists but is not byte-for-byte the registered patch: REFUSE.
    /// BPS would likely catch corruption at apply time, IPS never would — and
    /// either way, an unverified patch is unknown code for someone's ROM.
    tampered: struct { entry: *const core.registry.Entry, got: [64]u8 },
    /// Verified: apply it.
    apply: *const core.registry.Entry,
};

fn autoPatchDecision(entry: ?*const core.registry.Entry, patch_bytes: ?[]const u8) AutoPatchDecision {
    const e = entry orelse return .unknown;
    const pbytes = patch_bytes orelse return .{ .missing = e };
    const got = core.registry.sha256Hex(pbytes);
    if (!std.ascii.eqlIgnoreCase(&got, e.patch_sha256))
        return .{ .tampered = .{ .entry = e, .got = got } };
    return .{ .apply = e };
}

/// `--auto-patch`: identify the loaded ROM by content hash, find its
/// registered patch in `dir`, verify, apply. Only the `tampered` case is an
/// error; everything else runs, patched or not, with its reason printed.
fn autoPatch(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    image: []u8,
    dir: []const u8,
    patched: *bool,
) ![]u8 {
    const stripped = core.header.stripCopierHeader(image);
    const hex = core.registry.sha256Hex(stripped);
    const entry = core.registry.find(&hex);
    var pbytes: ?[]const u8 = null;
    var path: []const u8 = "";
    if (entry) |e| {
        path = try std.fs.path.join(gpa, &.{ dir, e.patch_name });
        pbytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024)) catch null;
    }
    defer out.flush() catch {};
    switch (autoPatchDecision(entry, pbytes)) {
        .unknown => {
            try out.print("auto-patch: this ROM is not in the registry (sha256 {s}); running unpatched\n", .{&hex});
            return image;
        },
        .missing => |e| {
            try out.print(
                "auto-patch: {s} has a registered patch '{s}', but it is not in {s}{c}\n" ++
                    "  fetch it yourself from {s}\n  ({s})\n  running unpatched\n",
                .{ e.title, e.patch_name, dir, std.fs.path.sep, e.url, e.license_note },
            );
            return image;
        },
        .tampered => |t| {
            try out.print(
                "error: auto-patch: '{s}' is not the registered patch for {s}\n" ++
                    "  file    sha256 {s}\n  registry pins  {s}\n  refusing to apply it\n",
                .{ path, t.entry.title, &t.got, t.entry.patch_sha256 },
            );
            return error.PatchFailed;
        },
        .apply => |e| {
            try out.print("auto-patch: {s} -> {s} (registry hash verified)\n", .{ e.title, e.patch_name });
            patched.* = true;
            return applyBytes(gpa, out, stripped, pbytes.?, path);
        },
    }
}

test "auto-patch decides all four flows" {
    // A fabricated registry entry whose pinned patch hash matches "GOODPATCH"
    // — the decision logic is what's under test, not the committed index.
    const good = "GOODPATCH";
    const good_hex = core.registry.sha256Hex(good);
    const entry: core.registry.Entry = .{
        .source_sha256 = "00" ** 32,
        .title = "Synthetic Game",
        .patch_name = "synthetic.bps",
        .patch_sha256 = &good_hex,
        .url = "https://example.invalid/",
        .license_note = "test",
    };
    try std.testing.expectEqual(AutoPatchDecision.unknown, autoPatchDecision(null, good));
    try std.testing.expectEqual(
        AutoPatchDecision{ .missing = &entry },
        autoPatchDecision(&entry, null),
    );
    switch (autoPatchDecision(&entry, "EVILPATCH")) {
        .tampered => |t| {
            try std.testing.expectEqual(&entry, t.entry);
            try std.testing.expect(!std.mem.eql(u8, &t.got, &good_hex));
        },
        else => return error.TestExpectedTampered,
    }
    try std.testing.expectEqual(
        AutoPatchDecision{ .apply = &entry },
        autoPatchDecision(&entry, good),
    );
    // Case must not matter: registries get hand-edited.
    var upper: [64]u8 = undefined;
    for (good_hex, 0..) |c, i| upper[i] = std.ascii.toUpper(c);
    const entry_upper: core.registry.Entry = .{
        .source_sha256 = "00" ** 32,
        .title = "Synthetic Game",
        .patch_name = "synthetic.bps",
        .patch_sha256 = &upper,
        .url = "https://example.invalid/",
        .license_note = "test",
    };
    try std.testing.expectEqual(
        AutoPatchDecision{ .apply = &entry_upper },
        autoPatchDecision(&entry_upper, good),
    );
}

/// The default output path for a generated patch: `<rom>.bps` next to the
/// ROM file — the softpatch naming every frontend discovers by basename.
fn defaultBpsPath(gpa: std.mem.Allocator, rom_path: []const u8) ![]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, rom_path, '.') orelse rom_path.len;
    const slash = std.mem.lastIndexOfScalar(u8, rom_path, '/') orelse 0;
    const stem = if (dot > slash) rom_path[0..dot] else rom_path;
    return std.fmt.allocPrint(gpa, "{s}.bps", .{stem});
}

/// `--gen-fastrom-patch`: derive the FastROM conversion, verify it
/// in-emulator, and only then write the BPS. `image` is copier-stripped.
fn runGenerate(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    args: Args,
    image: []const u8,
    mov: ?util.movie.Movie,
) !void {
    // A movie sets the capture length: cover the whole recorded playthrough.
    const frames = args.frames orelse if (mov) |m|
        @max(1, @as(u32, @intCast(m.frames.len)) -| args.skip)
    else
        gen_frames_default;
    const total = args.skip + frames;

    try out.print("baseline + verify runs, {} frames each ({d:.0}s)...\n", .{ total, @as(f64, @floatFromInt(total)) / 60.0 });
    try out.flush();

    var failure: ?util.GenFailure = null;
    const res = util.generateFastromVerified(gpa, image, frames, args.skip, if (mov) |m| m.frames else null, &failure) catch |e| switch (e) {
        error.GenFailed => {
            switch (failure.?) {
                .refused => |r| {
                    try out.print("refused: {s} (detail ${x:0>6})\n", .{ r.reason.describe(), r.detail });
                    switch (r.reason) {
                        .memsel_store_unpatchable => if (r.detail != 0) try out.print(
                            "  the store at ${x:0>2}:{x:0>4} is not a plain STZ/STA $420D\n",
                            .{ r.detail >> 16, r.detail & 0xFFFF },
                        ),
                        .no_free_space => try out.print(
                            "  needed {} bytes of $00/$FF padding in bank $00\n",
                            .{r.detail},
                        ),
                        else => {},
                    }
                },
                .frame_mismatch => |f| try out.print(
                    \\verification FAILED at frame {}: the patched run renders differently.
                    \\  FastROM timing changed something visible — this game has code timed
                    \\  against SlowROM latency and is not mechanically convertible.
                    \\
                , .{f}),
                .memsel_lost => |f| try out.print(
                    \\verification FAILED at frame {}: the game disabled MEMSEL from a code
                    \\  path the baseline run never exercised.
                    \\
                , .{f}),
                .audio_mismatch => try out.print(
                    \\verification FAILED: the audio streams diverge. FastROM timing moved an
                    \\  APU handshake — this game is not mechanically convertible.
                    \\
                , .{}),
            }
            try out.print("no patch written.\n", .{});
            try out.flush();
            std.process.exit(1);
        },
        else => return e,
    };

    const path = args.gen_out orelse try defaultBpsPath(gpa, args.rom);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = res.bps }) catch {
        try out.print("error: cannot write '{s}'\n", .{path});
        try out.flush();
        std.process.exit(1);
    };

    const header = try core.header.detect(image);
    const title = std.mem.trim(u8, &header.title, " \x00");
    const src_sha = core.registry.sha256Hex(image);
    const patch_sha = core.registry.sha256Hex(res.bps);
    const base_name = if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| path[s + 1 ..] else path;

    try out.print("wrote {s} ({} bytes)\n\n", .{ path, res.bps.len });
    try out.print("{s}\n", .{title});
    try out.print("  stub at $00:{x:0>4}, {} vector trampoline(s), {} MEMSEL store(s) neutralised\n", .{
        res.stub_addr, res.trampolines, res.memsel_stores_nopped,
    });
    try out.print("  verified: {} frames pixel- and audio-identical to the unpatched ROM\n", .{total});
    try out.print("  measured: mean CPU utilisation {d:.0}% -> {d:.0}%, slowdown {} -> {} frames\n", .{
        res.base.mean_util * 100, res.fast.mean_util * 100,
        res.base.slow_frames,     res.fast.slow_frames,
    });
    try out.print(
        \\  caveat: verified from power-on for {} frames; code paths beyond that window
        \\  (menus, later levels) ran at FastROM timing untested — pass --movie to widen it.
        \\
        \\ready to paste into patches/registry.zon for --auto-patch:
        \\    .{{
        \\        .source_sha256 = "{s}",
        \\        .title = "{s}",
        \\        .patch_name = "{s}",
        \\        .patch_sha256 = "{s}",
        \\        .url = "generated locally: yamabuki-headless --gen-fastrom-patch",
        \\        .license_note = "machine-generated FastROM conversion, verified {} frames from power-on",
        \\    }},
        \\
    , .{
        total,      &src_sha,
        title,      base_name,
        &patch_sha, total,
    });
    try out.flush();
}

/// `--gen-sa1-patch` (stage S3): profile, plan, convert (shell + clean state
/// relocations), verify frame- and audio-identical, and only then write the
/// BPS. `image` is copier-stripped.
fn runSa1Gen(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    args: Args,
    image: []const u8,
    movs: []const util.movie.Movie,
) !void {
    // Each movie is one verification SURFACE. Evidence and coverage are
    // the UNION over all of them — because each movie is a different
    // world, and the surface one covers can be exactly the surface
    // another displaces — while verification runs per surface and every
    // one must pass. Zero movies = the one legacy surface (attract).
    const n_surf: usize = @max(1, movs.len);
    // First line of every generator run, so a log is self-describing even
    // when the run fails and writes no patch. `--skip` is spelled out
    // because it defaults to 300 and silently changes how much of each
    // surface gets VERIFIED, which is exactly the kind of difference a
    // reconstructed command loses.
    try out.print("invocation: {s}\n", .{args.cmdline});
    try out.print("  (skip {} frame(s) before each surface's verification budget)\n", .{args.skip});
    try out.flush();
    var totals: [max_movies]u32 = undefined;
    for (0..n_surf) |s| {
        const frames = args.frames orelse if (movs.len != 0)
            @max(1, @as(u32, @intCast(movs[s].frames.len)) -| args.skip)
        else
            gen_frames_default;
        totals[s] = args.skip + frames;
    }
    const total = totals[0];
    // State-anchored generation: profile AND verify from a gameplay save
    // state instead of power-on, so the candidate set comes from a scene
    // with real slowdown — code the attract demo never executes has no
    // coverage and can never be offloaded. The state may be from an
    // earlier conversion of this same game: nothing binds a state to an
    // image, and the S3 stage leaves the WRAM layout in place.
    const state_bytes: ?[]const u8 = if (args.state) |spath| blk: {
        if (args.whole_game and !args.window) {
            try out.print("error: --state with --whole-game is not supported (the whole-game window shift is not applied to seeded states)\n", .{});
            try out.flush();
            std.process.exit(1);
        }
        const data = std.Io.Dir.cwd().readFileAlloc(io, spath, gpa, .limited(16 * 1024 * 1024)) catch {
            try out.print("error: cannot read state '{s}'\n", .{spath});
            try out.flush();
            std.process.exit(1);
        };
        try out.print("anchored at state: {s}\n", .{spath});
        break :blk data;
    } else null;
    // WINDOW + state: EVIDENCE and TRUTH split. A window image cannot be
    // seeded mid-game (the shim's D/S/window moves never ran for a saved
    // state, and the stack carries pre-move D saves as data), so the
    // state anchors an EVIDENCE pass only — profile, coverage, and the
    // candidate set come from the anchored scene — while verification
    // runs from power-on, where the shim makes everything consistent.
    // The offloads still get exercised: hot gameplay routines run in the
    // attract too.
    const evidence_state: ?[]const u8 = if (args.window) state_bytes else null;
    const verify_state: ?[]const u8 = if (args.window) null else state_bytes;
    // A surface's own anchor beats the session's --state: it IS the machine
    // that surface's inputs were recorded against. Window mode never gets
    // here with an anchored surface (refused at load, see checkSurfaceAnchors)
    // so this only ever seeds an image whose layout matches the anchor's.
    const surfaceAnchor = struct {
        fn f(ms: []const util.movie.Movie, s: usize, fallback: ?[]const u8) ?[]const u8 {
            if (s < ms.len) if (ms[s].anchor) |a| return a;
            return fallback;
        }
    }.f;
    if (n_surf > 1) {
        try out.print("baseline (profiled) + verify runs over {} surfaces:", .{n_surf});
        for (totals[0..n_surf]) |t| try out.print(" {}f", .{t});
        try out.print("...\n", .{});
    } else {
        try out.print("baseline (profiled) + verify runs, {} frames each...\n", .{total});
    }
    try out.flush();

    // Baselines, one per surface: per-frame hashes, audio (hash +
    // per-frame energy envelope), the profile, and the coverage map the
    // rewriter walks — coverage and site evidence accumulate into ONE
    // union across all surfaces. Every verification attempt below
    // replays against these.
    var env_base_s: [max_movies][]u64 = undefined;
    var env_conv_s: [max_movies][]u64 = undefined;
    var hashes_s: [max_movies][]u64 = undefined;
    var conv_hashes_s: [max_movies][]u64 = undefined;
    var base_audio_s: [max_movies]u64 = undefined;
    for (0..n_surf) |s| {
        env_base_s[s] = try gpa.alloc(u64, totals[s]);
        @memset(env_base_s[s], 0);
        env_conv_s[s] = try gpa.alloc(u64, totals[s]);
        hashes_s[s] = try gpa.alloc(u64, totals[s]);
        conv_hashes_s[s] = try gpa.alloc(u64, totals[s]);
    }
    const env_base = env_base_s[0];
    const hashes = hashes_s[0];
    const ub = try gpa.alloc(u8, core.usage_map.cpu_map_len);
    @memset(ub, 0);
    // Per-site effective-address evidence: the dynamic answer to the
    // statically undecidable idioms (is $0000,X a ROM table walk or a
    // low-WRAM walk? measure it). Both the evidence pass and the main
    // baseline accumulate into the same map.
    const site_ev = try gpa.alloc(u8, core.usage_map.cpu_map_len);
    @memset(site_ev, 0);
    // Site evidence from CONVERSION-side replays is kept apart and folded in
    // only where stock left nothing: a replay on an older build — a different
    // memory map — classifies the same instruction through that map, and one
    // such record turned a clean low-WRAM site (`LDX $0E54`, Brinstar's
    // elevator) into a split site the rewriter refused to shift. Stock
    // evidence describes the real machine; conversion evidence is the
    // fallback for code stock never reached, which is why it was merged.
    const site_ev_conv = try gpa.alloc(u8, core.usage_map.cpu_map_len);
    @memset(site_ev_conv, 0);
    // Pointer-bank provenance: which ROM bytes feed $7E/$7F into runtime
    // pointers ([dp] bank bytes, DMA bank registers). Accumulates across
    // every profiled surface like the rest of the evidence.
    const ptr_ev = try gpa.create(core.usage_map.PtrBankEvidence);
    ptr_ev.* = .init;
    const umap: core.usage_map.UsageMap = .{ .bytes = ub, .sites = site_ev, .ptr_banks = ptr_ev };
    var samples: std.array_list.Managed(profile.FrameSample) = .init(gpa);
    try samples.ensureTotalCapacity(total);
    // Coverage growth: how much code the profile was STILL discovering in
    // the last tenth of the capture. Every conversion failure measured so
    // far traces back to code the rewriter never saw, so this turns "the
    // capture might be too short" from a caveat into a number.
    var cov_early: u32 = 0;
    const cov_mark: usize = total - total / 10;
    // The anchored EVIDENCE pass (window + --state): profile and coverage
    // from the gameplay scene, into the same usage map the rewriter and
    // the walks consume. Candidates come from THIS profile.
    var evidence_conv: ?profile.Conversion = null;
    if (evidence_state) |sb| {
        const ecart = try core.Cartridge.load(gpa, image);
        const econ = try gpa.create(core.ProfilingConsole);
        econ.init(ecart);
        econ.usage = &umap;
        econ.loadState(sb) catch |e| {
            try out.print("error: the state does not load into this console: {s}\n", .{@errorName(e)});
            try out.flush();
            std.process.exit(1);
        };
        var esamples: std.array_list.Managed(profile.FrameSample) = .init(gpa);
        try esamples.ensureTotalCapacity(total);
        for (0..total) |i| {
            // NO input: a movie is a power-on script, and pressing its
            // buttons into a mid-game scene means something else entirely
            // (START pauses gameplay — one press froze an anchored
            // evidence pass for 3,200 frames and silently changed a
            // hundred rewrite decisions between two otherwise-identical
            // runs). The anchored scene plays itself; evidence becomes
            // independent of which surfaces drive verification.
            econ.runFrame();
            if (econ.takeProfile()) |smp| {
                if (i >= args.skip) esamples.appendAssumeCapacity(smp);
            }
        }
        const escratch = try gpa.alloc(f64, esamples.items.len);
        const esum = profile.summarise(esamples.items, escratch);
        evidence_conv = profile.assessConversion(&econ.prof, esum.verdict);
        econ.cart.deinit(gpa);
        gpa.destroy(econ);
        try out.print("  (evidence pass: profile + coverage anchored at the state; verification stays power-on)\n", .{});
        try out.flush();
    }
    const cart = try core.Cartridge.load(gpa, image);
    const con = try gpa.create(core.ProfilingConsole);
    con.init(cart);
    con.usage = &umap;
    applySidecar(con, movAt(movs, 0));
    if (surfaceAnchor(movs, 0, verify_state)) |sb| con.loadState(sb) catch |e| {
        try out.print("error: the state does not load into this console: {s}\n", .{@errorName(e)});
        try out.flush();
        std.process.exit(1);
    };
    var base_audio = core.console.audio_hash_init;
    var feed0: util.movie.Feed = .init(movAt(movs, 0));
    for (0..total) |i| {
        if (i == cov_mark) cov_early = core.usage_map.countOpcodes(ub);
        feed0.step(con, i);
        con.runFrame();
        try util.drainAudio(con, &base_audio, EnergySink{ .cell = &env_base[i] }, EnergySink.add);
        hashes[i] = core.console.hashFrame(con.framebuffer());
        if (con.takeProfile()) |smp| {
            if (i >= args.skip) samples.appendAssumeCapacity(smp);
        }
    }
    base_audio_s[0] = base_audio;
    const scratch = try gpa.alloc(f64, samples.items.len);
    const sum = profile.summarise(samples.items, scratch);
    // Surfaces beyond the first: fresh consoles into the SAME coverage
    // and evidence union, their own hashes/audio and their own profile
    // summary (the lag comparison is per surface).
    var sum_s: [max_movies]@TypeOf(sum) = undefined;
    sum_s[0] = sum;
    for (1..n_surf) |s| {
        const cart_s = try core.Cartridge.load(gpa, image);
        const con_s = try gpa.create(core.ProfilingConsole);
        con_s.init(cart_s);
        con_s.usage = &umap;
        applySidecar(con_s, movAt(movs, s));
        if (surfaceAnchor(movs, s, verify_state)) |sb| try con_s.loadState(sb);
        var audio_s = core.console.audio_hash_init;
        var samples_s: std.array_list.Managed(profile.FrameSample) = .init(gpa);
        try samples_s.ensureTotalCapacity(totals[s]);
        var feed_s: util.movie.Feed = .init(movAt(movs, s));
        for (0..totals[s]) |i| {
            feed_s.step(con_s, i);
            con_s.runFrame();
            try util.drainAudio(con_s, &audio_s, EnergySink{ .cell = &env_base_s[s][i] }, EnergySink.add);
            hashes_s[s][i] = core.console.hashFrame(con_s.framebuffer());
            if (con_s.takeProfile()) |smp| {
                if (i >= args.skip) samples_s.appendAssumeCapacity(smp);
            }
        }
        base_audio_s[s] = audio_s;
        const scratch_s = try gpa.alloc(f64, samples_s.items.len);
        sum_s[s] = profile.summarise(samples_s.items, scratch_s);
        con_s.cart.deinit(gpa);
        gpa.destroy(con_s);
    }
    // COVERAGE PAD: replay every surface PAST its movie end on throwaway
    // consoles, coverage/evidence union only — no samples, no baselines,
    // no verdict influence. The conversion runs AHEAD of stock by the
    // removed slowdown, so a path stock first executes shortly AFTER the
    // movie is reachable by the conversion WITHIN it — and an uncovered
    // instruction there is invisible to the rewriter (measured: stock
    // first ran the attract-cycle dispatch `JMP ($0000)` at ~f4850 of
    // the 4800f surface; the converted run reached it at ~f4640 with
    // the pointer operand unshifted — dead-WRAM pointer, BRK storm,
    // permanent park behind a blank screen; latent in EVERY shipped
    // window build, exposed only by post-movie soak probes).
    if (args.whole_game and args.window and movs.len != 0) {
        const cov_pad: u32 = 1500;
        for (0..n_surf) |s| {
            const cart_p = try core.Cartridge.load(gpa, image);
            const con_p = try gpa.create(core.ProfilingConsole);
            con_p.init(cart_p);
            con_p.usage = &umap;
            applySidecar(con_p, movAt(movs, s));
            if (surfaceAnchor(movs, s, verify_state)) |sb| try con_p.loadState(sb);
            var feed_p: util.movie.Feed = .init(movAt(movs, s));
            for (0..totals[s] + cov_pad) |i| {
                feed_p.step(con_p, i);
                con_p.runFrame();
            }
            con_p.cart.deinit(gpa);
            gpa.destroy(con_p);
        }
        try out.print("  coverage pad: each surface profiled {} frames past its movie (lag-led paths)\n", .{cov_pad});
        try out.flush();
    }
    // CONVERSION-SIDE COVERAGE HARVEST (--cover-image + --cover-movie):
    // stock replays of a conv-recorded run die early (the inputs are
    // conv-timed), so gameplay only the conversion reaches — measured:
    // the stage-1 boss arrival — never covers its handlers and their
    // low-WRAM reads stay unshifted, reading dead memory. WHICH
    // instructions execute is address-space-invariant, so a replay on
    // the PREVIOUS conversion donates opcode/width coverage wherever
    // the instruction byte matches stock (rewrites change operands, not
    // opcodes; the previous build's scaffolding differs byte-for-byte
    // and filters itself out). Site evidence is NOT harvested — conv
    // effective addresses describe the post-relocation world.
    // Every pair is an independent replay — its own image, console and
    // products — and only the merge into the union is shared. So: pairs are
    // loaded in recipe order; a pair whose harvest is cached is read back at
    // merge time; a pair that needs its replay is run on a worker thread, up
    // to `jobs` in flight, spawned ahead in recipe order; the main thread
    // merges pair i only after joining it, in recipe order, so the union
    // and the log come out the same at any thread count. Memory is bounded
    // by the in-flight window: two 16 MiB maps and a console per job.
    const HarvestJob = struct {
        ci_raw: []u8 = &.{},
        ci: []const u8 = &.{},
        mb: []u8 = &.{},
        movie: ?util.movie.Movie = null,
        ci_crc: u32 = 0,
        mov_hash: u64 = 0,
        cache_path: ?[]const u8 = null,
        cached: bool = false,
        tmp: []u8 = &.{},
        tmp_ev: []u8 = &.{},
        pb: ?*core.usage_map.PtrBankEvidence = null,
        map: core.usage_map.UsageMap = undefined,
        con: ?*core.ProfilingConsole = null,
        thread: ?std.Thread = null,
        anchor_failed: bool = false,

        fn replay(job: *@This()) void {
            const c = job.con.?;
            const m = job.movie.?;
            if (m.start_srm) |sb| _ = loadSaveBytes(c.bus.cart, sb);
            if (m.anchor) |anc| c.loadState(anc) catch {
                job.anchor_failed = true;
                return;
            };
            // The take plus a 600-frame tail; per poll, until every entry
            // is consumed plus the tail (see Feed.budget for the ceiling).
            var feed: util.movie.Feed = .init(m);
            var i: usize = 0;
            var tail: usize = 0;
            while (tail < 600 and i < util.movie.Feed.budget(m) + 600) : (i += 1) {
                feed.step(c, i);
                c.runFrame();
                if (feed.done()) tail += 1;
            }
        }
    };
    var jobs: [max_cover_pairs]HarvestJob = @splat(.{});
    const jobs_max: usize = if (args.harvest_jobs != 0) args.harvest_jobs else @min(12, std.Thread.getCpuCount() catch 4);
    // Phase 1: load every pair, decide cache hit or replay, and prepare the
    // replay's console on this thread (allocation stays off the workers).
    for (0..args.n_cover) |ci_i| {
        if (args.cover_image[ci_i] == null or args.cover_movie[ci_i] == null) continue;
        const job = &jobs[ci_i];
        job.ci_raw = std.Io.Dir.cwd().readFileAlloc(io, args.cover_image[ci_i].?, gpa, .limited(64 * 1024 * 1024)) catch {
            try out.print("error: cannot read cover image '{s}'\n", .{args.cover_image[ci_i].?});
            try out.flush();
            std.process.exit(1);
        };
        job.ci = core.header.stripCopierHeader(job.ci_raw);
        job.mb = std.Io.Dir.cwd().readFileAlloc(io, args.cover_movie[ci_i].?, gpa, .limited(64 * 1024 * 1024)) catch {
            try out.print("error: cannot read cover movie '{s}'\n", .{args.cover_movie[ci_i].?});
            try out.flush();
            std.process.exit(1);
        };
        job.movie = util.movie.parse(gpa, job.mb) catch {
            try out.print("error: '{s}' is not a valid movie\n", .{args.cover_movie[ci_i].?});
            try out.flush();
            std.process.exit(1);
        };
        job.movie.?.start_srm = util.movie.loadStartSrm(io, gpa, args.cover_movie[ci_i].?);
        job.ci_crc = util.movie.imageCrc(job.ci);
        job.mov_hash = std.hash.Fnv1a_64.hash(job.mb);
        if (args.harvest_cache) |dir| {
            var pbuf: [1024]u8 = undefined;
            if (harvestCachePath(&pbuf, dir, job.ci_crc, job.mov_hash)) |p| {
                job.cache_path = try gpa.dupe(u8, p);
                job.cached = if (std.Io.Dir.cwd().access(io, p, .{})) true else |_| false;
            } else |_| {}
        }
        if (!job.cached) {
            job.tmp = try gpa.alloc(u8, core.usage_map.cpu_map_len);
            @memset(job.tmp, 0);
            job.tmp_ev = try gpa.alloc(u8, core.usage_map.cpu_map_len);
            @memset(job.tmp_ev, 0);
            job.pb = try gpa.create(core.usage_map.PtrBankEvidence);
            job.pb.?.* = .init;
            job.map = .{ .bytes = job.tmp, .sites = job.tmp_ev, .conv_window_homes = true, .ptr_banks = job.pb.? };
            const ccart = try core.Cartridge.load(gpa, job.ci);
            const ccon = try gpa.create(core.ProfilingConsole);
            ccon.init(ccart);
            ccon.usage = &job.map;
            // SA-1-side coverage too: on a conversion image the tail's code
            // executes on the SA-1, and this harvest exists to see it.
            if (ccon.bus.cart.chip == .sa1) ccon.bus.sa1.usage = &job.map;
            ccon.skip_render = !args.harvest_render;
            job.con = ccon;
        }
    }
    // Phase 2: replays in flight ahead of the merge cursor; merge in order.
    var next_spawn: usize = 0;
    var inflight: usize = 0;
    for (0..args.n_cover) |ci_i| {
        if (args.cover_image[ci_i] == null or args.cover_movie[ci_i] == null) continue;
        while (next_spawn < args.n_cover and inflight < jobs_max) : (next_spawn += 1) {
            const j = &jobs[next_spawn];
            if (j.con == null) continue;
            j.thread = try std.Thread.spawn(.{}, HarvestJob.replay, .{j});
            inflight += 1;
        }
        const job = &jobs[ci_i];
        const cm = job.movie.?;
        var from_cache = false;
        if (job.cached) {
            job.tmp = try gpa.alloc(u8, core.usage_map.cpu_map_len);
            @memset(job.tmp, 0);
            job.tmp_ev = try gpa.alloc(u8, core.usage_map.cpu_map_len);
            @memset(job.tmp_ev, 0);
            job.pb = try gpa.create(core.usage_map.PtrBankEvidence);
            job.pb.?.* = .init;
            if (loadHarvestCache(io, gpa, job.cache_path.?, job.ci_crc, job.mov_hash, job.tmp, job.tmp_ev, job.pb.?)) {
                from_cache = true;
            } else {
                // A short or foreign file: replay here, on this thread, from
                // clean maps — the window ahead is not disturbed.
                @memset(job.tmp, 0);
                @memset(job.tmp_ev, 0);
                job.pb.?.* = .init;
                job.map = .{ .bytes = job.tmp, .sites = job.tmp_ev, .conv_window_homes = true, .ptr_banks = job.pb.? };
                const ccart = try core.Cartridge.load(gpa, job.ci);
                const ccon = try gpa.create(core.ProfilingConsole);
                ccon.init(ccart);
                ccon.usage = &job.map;
                if (ccon.bus.cart.chip == .sa1) ccon.bus.sa1.usage = &job.map;
                ccon.skip_render = !args.harvest_render;
                job.con = ccon;
                job.replay();
            }
        } else {
            job.thread.?.join();
            job.thread = null;
            inflight -= 1;
        }
        if (job.anchor_failed) {
            try out.print("error: the cover movie '{s}' carries a start state this console cannot restore\n" ++
                "       (a save state is tied to the core's layout and the image it was taken on)\n", .{args.cover_movie[ci_i].?});
            try out.flush();
            std.process.exit(1);
        }
        if (cm.anchor != null and !from_cache) {
            try out.print("movie anchor: cover movie restored ({} frames replay from it)\n", .{cm.frames.len});
            try out.flush();
        }
        if (job.con) |ccon| {
            ccon.cart.deinit(gpa);
            gpa.destroy(ccon);
            job.con = null;
            if (job.cache_path) |cp| saveHarvestCache(io, gpa, args.harvest_cache.?, cp, job.ci_crc, job.mov_hash, job.tmp, job.tmp_ev, job.pb.?);
        }
        const tmp = job.tmp;
        const tmp_ev = job.tmp_ev;
        const cover_pb = job.pb.?;
        const ci = job.ci;
        const ci_is_stock = std.mem.eql(u8, ci, image);
        var merged: u32 = 0;
        var merged_ev: u32 = 0;
        var pc: u32 = 0;
        while (pc < core.usage_map.cpu_map_len) : (pc += 1) {
            if (tmp[pc] & core.usage_map.flag_opcode == 0) continue;
            const bank = (pc >> 16) & 0x7F;
            const a16 = pc & 0xFFFF;
            if (bank > 0x3F or a16 < 0x8000) continue;
            const file = bank * 0x8000 + (a16 - 0x8000);
            if (file >= image.len or file >= ci.len) continue;
            if (image[file] != ci[file]) continue; // scaffolding / rewritten opcode
            if (ub[pc] & core.usage_map.flag_opcode == 0) merged += 1;
            ub[pc] |= tmp[pc];
            if (tmp_ev[pc] != 0) {
                if (ci_is_stock) {
                    if (site_ev[pc] == 0) merged_ev += 1;
                    site_ev[pc] |= tmp_ev[pc];
                } else {
                    if (site_ev_conv[pc] == 0) merged_ev += 1;
                    site_ev_conv[pc] |= tmp_ev[pc];
                }
            }
        }
        // Merge proven bank bytes under the same byte-identity guard the
        // coverage merge uses: a ROM byte that differs between the images is
        // this conversion's own scaffolding and proves nothing about stock.
        var merged_pb: u32 = 0;
        for (cover_pb.proven[0..cover_pb.n_proven]) |ca| {
            const bank = (ca >> 16) & 0x7F;
            const a16 = ca & 0xFFFF;
            if (bank > 0x3F or a16 < 0x8000) continue;
            const file = bank * 0x8000 + (a16 - 0x8000);
            if (file >= image.len or file >= ci.len) continue;
            if (image[file] != ci[file]) continue;
            const before = ptr_ev.n_proven;
            ptr_ev.addProven(ca);
            if (ptr_ev.n_proven != before) merged_pb += 1;
        }
        // Armed indirect-HDMA tables merge too: a table armed only on the
        // conversion's own post-fork timeline (a cutscene skip, a lag-only
        // path) is exactly the one whose low-WRAM pointers the stock-side
        // profile can never evidence — the Ceres ARRIVAL's per-scanline
        // $2105 table, where the escape's had already been caught by the
        // stock surfaces. Guarded on the table's first byte the way the
        // other merges are guarded: a home whose count byte differs
        // between the images is this conversion's own scaffolding.
        var merged_ht: u32 = 0;
        for (cover_pb.hdma_tables[0..cover_pb.n_hdma_tables]) |t| {
            const file = core.sa1gen.loromFileOffset(image.len, t) orelse continue;
            if (file >= ci.len or image[file] != ci[file]) continue;
            const before = ptr_ev.n_hdma_tables;
            ptr_ev.addHdmaTable(t);
            if (ptr_ev.n_hdma_tables != before) merged_ht += 1;
        }
        try out.print("  cover harvest {s}: {} instruction(s) newly covered, {} site(s) newly evidenced, {} bank byte(s) newly proven, {} armed HDMA table(s) from the conversion-side replay{s}\n", .{ args.cover_movie[ci_i].?, merged, merged_ev, merged_pb, merged_ht, @as([]const u8, if (from_cache) " [cached]" else "") });
        try out.flush();
        gpa.free(job.tmp);
        gpa.free(job.tmp_ev);
        gpa.destroy(job.pb.?);
        job.tmp = &.{};
        job.tmp_ev = &.{};
        job.pb = null;
    }
    for (dbg_site_ev[0..dbg_n_site_ev]) |p| {
        try out.print("  [site-ev] ${x:0>6}: cov={x:0>2} cov80={x:0>2} ev={x:0>2} ev80={x:0>2}\n", .{
            p, ub[p], ub[0x80_0000 | p], site_ev[p], site_ev[0x80_0000 | p],
        });
    }
    if (dbg_n_site_ev != 0) try out.flush();
    // --ev-only: the coverage/evidence answer is all that was wanted. Stop
    // before the (much longer) plan-and-verify machinery.
    if (dbg_ev_only) return;
    const cov_total = core.usage_map.countOpcodes(ub);
    const cov_late = cov_total - cov_early;

    // The verdict, plan, and candidate set are fixed by the baseline; only
    // the candidate FILTER changes across bisect attempts.
    var conv: profile.Conversion = undefined;
    var plan: profile.Plan = undefined;
    var cands: [profile.conversion_set_max + 12]core.sa1gen.Candidate = undefined;
    var n_cands: usize = 0;
    var neighbours: []const core.sa1gen.Candidate = &.{};
    var dma_pages: profile.WramPages = @splat(0);
    // WINDOW offload candidates: the profile's hot entries, no plan or
    // page machinery — a window image has no marshal to size, only trees
    // to walk. The bisect and mode ladder below drive them as usual.
    //
    // ONE CONTEXT ONLY: the offload mailbox is single-channel, so a stub
    // call from interrupt context landing inside a mainline handshake
    // deadlocks both CPUs (measured on Gradius III's attract demo — the
    // NMI-side sound pump stomped the physics tree's smeg mid-flight and
    // both ends waited forever). Candidates partition by measured
    // context and the class with less slow work is refused by name.
    if (args.window) {
        conv = evidence_conv orelse profile.assessConversion(&con.prof, sum.verdict);
        var int_slow: u64 = 0;
        var main_slow: u64 = 0;
        for (conv.entry_int[0..conv.n], conv.entry_slow[0..conv.n]) |is_int, slow| {
            if (is_int) int_slow += slow else main_slow += slow;
        }
        const keep_int = int_slow > main_slow;
        for (conv.entries[0..conv.n], 0..) |e, i| {
            if (conv.entry_int[i] != keep_int) {
                try out.print(
                    "  window: ${x:0>2}:{x:0>4} runs in {s} context — refused (offloads share one mailbox; keeping the {s} class, {d} vs {d} slow cycles)\n",
                    .{
                        e >> 16,                                                             e & 0xFFFF,
                        if (conv.entry_int[i]) @as([]const u8, "interrupt") else "mainline", if (keep_int) @as([]const u8, "interrupt") else "mainline",
                        if (keep_int) int_slow else main_slow,                               if (keep_int) main_slow else int_slow,
                    },
                );
                continue;
            }
            cands[n_cands] = .{ .entry = e };
            n_cands += 1;
        }
        for (args.wg_add[0..args.n_wg_add]) |e| {
            if (n_cands == cands.len) {
                try out.print("  --wg-add: ${x:0>6} DROPPED — candidate list full ({d} slots)\n", .{ e, cands.len });
                try out.flush();
                continue;
            }
            const dup = for (cands[0..n_cands]) |c| {
                if (c.entry == e) break true;
            } else false;
            if (dup) continue;
            cands[n_cands] = .{ .entry = e };
            n_cands += 1;
            try out.print("  --wg-add: offering offload ${x:0>6} to the selector\n", .{e});
            try out.flush();
        }
        if (!args.verify_behavioral) {
            for (cands[0..n_cands]) |*c| c.no_async = true;
        }
    }
    if (!args.whole_game) {
        conv = profile.assessConversion(&con.prof, sum.verdict);
        plan = profile.planRelocation(&con.prof, conv);
        // Anchored runs hunt OFFLOADS, not relocations. Two reasons, one
        // fundamental and one earned: the dp-window move happens in the
        // boot shim, which a state seeded mid-game never executes (its
        // live D and stacked D saves predate any move); and live-region
        // moves from a gameplay profile are exactly the aggressive plans
        // (34 KiB of shared WRAM on the first real cart tried) that no
        // verification has ever passed — the attract-demo plans only ever
        // moved dead regions. Offloads carry the plan's value anyway: the
        // S3 stage exists to put compute on the SA-1, and candidates from
        // a scene with real slowdown are the whole point of anchoring.
        if (state_bytes != null and plan.n > 0) {
            // TEMP S2 debugging: YAMABUKI_S2_KEEP="1,3" keeps only those
            // region indices (dp always dropped — unseedable); unset
            // keeps the production behavior (all relocation disabled).
            const keep_env: ?[]const u8 = args.s2_keep;
            if (keep_env) |ke| {
                var w: usize = 0;
                for (plan.regions[0..plan.n], 0..) |r, ri| {
                    if (r.dp) continue;
                    var it = std.mem.splitScalar(u8, ke, ',');
                    const keep = while (it.next()) |tok| {
                        const idx = std.fmt.parseInt(usize, std.mem.trim(u8, tok, " "), 10) catch continue;
                        if (idx == ri) break true;
                    } else false;
                    if (!keep) continue;
                    plan.regions[w] = r;
                    w += 1;
                }
                plan.n = w;
                plan.has_dp = false;
                try out.print("  (anchored: TEMP S2 debug — keeping {} region(s) of the plan: {s})\n", .{ w, ke });
                for (plan.regions[0..plan.n]) |r| try out.print("    keeping $7e:{x:0>4}+{} -> {s} ${x:0>4}\n", .{ r.start, r.len, @tagName(r.dest), r.dest_off });
            } else {
                plan.n = 0;
                plan.has_dp = false;
                try out.print("  (anchored: relocation disabled — offload candidates only; a seeded state predates the boot shim's moves)\n", .{});
            }
        }
        for (conv.entries[0..conv.n], 0..) |e, i| {
            cands[i] = .{ .entry = e };
            if (con.prof.routineInfo(e)) |r| {
                cands[i].pages = r.wram_pages;
                cands[i].self_cycles = r.self_cycles;
                cands[i].calls = r.calls;
                cands[i].entry_d = r.entry_d;
                cands[i].d_varies = r.d_varies;
            }
        }
        n_cands = conv.n;
        // TEMP S2 debugging: relocation-only attempts, no offloads.
        if (state_bytes != null and args.s2_keep != null) n_cands = 0;
        // Fire-and-forget offloads reorder execution by design: only the
        // behavioral tier can ever verify one, so without it every
        // candidate is demoted to synchronous up front.
        if (!args.verify_behavioral) {
            for (cands[0..n_cands]) |*c| c.no_async = true;
        }
        // Sibling evidence: every other profiled routine, so an alternate
        // entry point into an offloaded body folds its working set into
        // the marshal even though it is far too cold to be a candidate.
        var nb: std.array_list.Managed(core.sa1gen.Candidate) = .init(gpa);
        for (&con.prof.routines) |*r| {
            if (r.entry == profile.Routine.empty) continue;
            const in_set = for (conv.entries[0..conv.n]) |e| {
                if (e == r.entry) break true;
            } else false;
            if (in_set) continue;
            try nb.append(.{
                .entry = @intCast(r.entry & 0xFF_FFFF),
                .pages = r.wram_pages,
                .self_cycles = r.self_cycles,
                .calls = r.calls,
                .entry_d = r.entry_d,
                .d_varies = r.d_varies,
            });
        }
        neighbours = nb.items;
        // Every WRAM page a DMA/HDMA arm reads: those can never become
        // BW-RAM-resident, since the transfer's A-bus side names a WRAM
        // address and re-sourcing DMA is not part of this slice.
        for (&con.prof.routines) |*r| {
            if (r.entry == profile.Routine.empty) continue;
            for (r.dma[0..r.n_dma]) |use| {
                if (!use.src_wram and !use.indirect_wram) continue;
                const base: u32 = use.src & 0x1_FFFF;
                const span: u32 = @max(1, use.bytes_max);
                var off: u32 = base;
                while (off < base + span and off < 0x2_0000) : (off += 256) {
                    const pg: u16 = @intCast(off >> 8);
                    dma_pages[pg / 64] |= @as(u64, 1) << @intCast(pg % 64);
                }
            }
        }
    }

    // The auto-bisect loop: convert, verify, and on a failure that an
    // offloaded routine could explain, diagnose (first divergent frame +
    // a WRAM diff attributed against the offloads' working sets), drop
    // the culprit, and retry. The loop terminates: every retry removes
    // one offloaded routine, and a failure with none left is terminal.
    var dropped: [profile.conversion_set_max]u24 = undefined;
    var dropped_why: [profile.conversion_set_max][]const u8 = undefined;
    var n_dropped: usize = 0;
    // Pre-seeded drops (`--wg-drop`): trees live play proved unsafe.
    for (args.wg_drop[0..args.n_wg_drop]) |d| {
        dropped[n_dropped] = @intCast(d);
        dropped_why[n_dropped] = "excluded by --wg-drop (unsafe in live play)";
        n_dropped += 1;
        try out.print("  --wg-drop: excluding offload $00:{x:0>4}\n", .{d});
        try out.flush();
    }
    // Interrupt-masked dispatches (`--wg-nmi-off`): trees whose read-set
    // the S-CPU's own interrupt handlers mutate — the stub masks NMI/IRQ
    // across the handshake so the copy runs against quiescent state.
    for (args.wg_nmi_off[0..args.n_wg_nmi_off]) |e| {
        for (cands[0..n_cands]) |*c| {
            if ((c.entry & 0xFFFF) == e) {
                c.nmi_off = true;
                c.no_async = true;
            }
        }
        try out.print("  --wg-nmi-off: interrupt-masked dispatch for $00:{x:0>4}\n", .{e});
        try out.flush();
    }
    var total_max: u32 = 0;
    for (totals[0..n_surf]) |t| total_max = @max(total_max, t);
    var conv_samples: std.array_list.Managed(profile.FrameSample) = .init(gpa);
    try conv_samples.ensureTotalCapacity(total_max);

    // GREEDY MODE LADDER: the sync phase bisects to its MAXIMAL passing
    // configuration first; then one async attempt competes against it on
    // the measured result. Shipping the first passing attempt was wrong
    // both ways round — an async first-pass ships a single tree when the
    // sync ladder carries more (measured: async $9BCD alone cut dropped
    // frames 237 to 234; the sync three-tree config cut them to 106),
    // and a sync-only run never learns whether the async flavor was the
    // better patch. `--wg-sync` skips the async phase.
    const SyncPass = struct { res: core.sa1gen.Result, tier: SaTier, conv_sum: @TypeOf(sum) };
    var sync_pass: ?SyncPass = null;
    var phase_async = false;
    while (true) {
        // Candidates minus the dropped culprits. The async phase fields
        // the full list again: its monopoly ships one tree, and the sync
        // drops were sync verdicts.
        var act: [profile.conversion_set_max]core.sa1gen.Candidate = undefined;
        var n_act: usize = 0;
        for (cands[0..n_cands]) |c| {
            const is_dropped = !phase_async and for (dropped[0..n_dropped]) |d| {
                if (d == c.entry) break true;
            } else false;
            if (!is_dropped) {
                act[n_act] = c;
                n_act += 1;
            }
        }

        if (ptr_ev.n_proven != 0 or ptr_ev.unresolved != 0 or ptr_ev.n_idx != 0 or ptr_ev.idx_unresolved != 0 or ptr_ev.n_dma_addr != 0 or ptr_ev.n_hi != 0 or ptr_ev.n_a0 != 0) {
            try out.print("  value provenance: {} pointer-bank byte(s) ({} unresolved), {} dp,X word(s) ({} unresolved), {} dma-addr word(s)\n", .{ ptr_ev.n_proven, ptr_ev.unresolved, ptr_ev.n_idx, ptr_ev.idx_unresolved, ptr_ev.n_dma_addr });
            for (ptr_ev.proven[0..ptr_ev.n_proven]) |pa| {
                try out.print("    proven bank byte at ${x:0>2}:{x:0>4}\n", .{ pa >> 16, pa & 0xFFFF });
            }
            for (ptr_ev.xl_sites[0..ptr_ev.n_xl]) |pa| {
                try out.print("    misfit-bank pin site at ${x:0>2}:{x:0>4} (translate-in)\n", .{ pa >> 16, pa & 0xFFFF });
            }
            for (ptr_ev.a0_proven[0..ptr_ev.n_a0]) |pa| {
                try out.print("    proven $A0-$BF bank byte at ${x:0>2}:{x:0>4}\n", .{ pa >> 16, pa & 0xFFFF });
            }
            for (ptr_ev.hi_proven[0..ptr_ev.n_hi]) |pa| {
                try out.print("    proven $C0-$DF bank byte at ${x:0>2}:{x:0>4}\n", .{ pa >> 16, pa & 0xFFFF });
            }
            for (ptr_ev.dma_addr_proven[0..ptr_ev.n_dma_addr]) |pa| {
                try out.print("    proven dma-addr word at ${x:0>2}:{x:0>4}\n", .{ pa >> 16, pa & 0xFFFF });
            }
            for (ptr_ev.unres_sites[0..ptr_ev.n_unres]) |s_| {
                try out.print("    unresolved site ${x:0>2}:{x:0>4} bank cell ${x:0>4} (x{})\n", .{ s_.pc >> 16, s_.pc & 0xFFFF, s_.slot, s_.hits });
            }
            try out.flush();
        }
        var refusal: ?core.sa1gen.Refusal = null;
        const split_spec: ?core.sa1gen.SplitSpec = if (args.wg_split_mainloop != 0 or args.wg_split_tail != 0) .{
            .io_entries = args.wg_split_io[0..args.n_wg_split_io],
            .vbl_ranges = args.wg_split_vbl[0..args.n_wg_split_vbl],
            .mainloop = args.wg_split_mainloop,
            .tail = args.wg_split_tail,
            .tail_epilogue = args.wg_split_epi,
            .tail_dbr = args.wg_split_dbr,
            .mode_cell = args.wg_split_mode_cell,
            .mode_value = args.wg_split_mode_value,
            .mode_hi = args.wg_split_mode_hi,
            .mode_gate = args.wg_split_mode,
            .shared_sites = args.wg_split_shared,
        } else null;
        if (split_spec != null) {
            try out.print("  --wg-split: engaging the split (anchor ${x:0>6}) ({} IO routine(s), {} reader range(s))\n", .{ if (args.wg_split_tail != 0) @as(u24, args.wg_split_tail) else args.wg_split_mainloop, args.n_wg_split_io, args.n_wg_split_vbl });
            try out.flush();
        }
        const converted: core.sa1gen.Error!core.sa1gen.Result = if (args.whole_game)
            core.sa1gen.convertWholeGame(gpa, image, ub, foldConvEvidence(site_ev, site_ev_conv, out), ptr_ev, args.wg_static, args.window, if (split_spec != null) &.{} else act[0..n_act], phase_async, args.wg_expand_to, args.wg_copy_reserve, split_spec, &refusal)
        else
            core.sa1gen.convert(gpa, image, &plan, ub, act[0..n_act], neighbours, dma_pages, &refusal);
        if (converted) |cr| {
            if (cr.stats.split_engage_addr != 0) {
                try out.print("  split: engaged at $00:{x:0>4}; {} IO routine(s), {} math site(s) shadowed ({} direct cell accesses, {} JSL triggers, the rest COPs); {} inline-argument callee(s){s}\n", .{ cr.stats.split_engage_addr, cr.stats.split_io, cr.stats.split_math_sites, cr.stats.split_math_direct, cr.stats.split_trigger_jsl, cr.stats.split_inline_args, if (cr.stats.split_dual) @as([]const u8, "; dual image: the S-CPU's copy keeps stock math bytes") else "" });
                var hi: usize = 0;
                while (hi < cr.stats.n_split_hazards) : (hi += 1)
                    try out.print("  split HAZARD (open bus or dead wait on the SA-1): ${x:0>2}:{x:0>4}\n", .{ cr.stats.split_hazards[hi] >> 16, cr.stats.split_hazards[hi] & 0xFFFF });
                try out.flush();
            }
            if (cr.stats.offload_space_short != 0)
                try out.print(
                    "  offloads ABANDONED: the tree copies need {} contiguous byte(s) and no\n  padding run is that big — the thunk bodies are in the same padding\n",
                    .{cr.stats.offload_space_short},
                );
        } else |_| {}
        if (args.n_wg_nmi_off != 0 and !phase_async) {
            if (converted) |cr| {
                if (cr.stats.nmi_off_sites != 0)
                    try out.print("  wg-nmi-off: {} STA-$4200 site(s) thunked through the $378F mirror\n", .{cr.stats.nmi_off_sites})
                else
                    try out.print("  wg-nmi-off: NO usable $4200 writer sites — wrap NOT emitted\n", .{});
            } else |_| {}
        }
        var res = converted catch |e| switch (e) {
            error.Refused => {
                const r = refusal.?;
                try out.print("refused: {s} (detail ${x:0>6})\n", .{ r.reason.describe(), r.detail });
                // Most whole-game refusals name the instruction that caused
                // them; without the address the message is a dead end.
                switch (r.reason) {
                    .wg_wram_beyond_iram,
                    .wg_wram_beyond_bwram,
                    .wg_dp_dynamic,
                    .wg_stack_dynamic,
                    .wg_blockmove_source,
                    .wg_mmio_shape,
                    .wg_mmio_outside_bank0,
                    .wg_unsupported_op,
                    => if (r.detail != 0) try out.print(
                        "  at ${x:0>2}:{x:0>4}\n",
                        .{ r.detail >> 16, r.detail & 0xFFFF },
                    ),
                    .no_free_space => try out.print("  needs {} bytes\n", .{r.detail}),
                    .wg_thunk_space => try out.print("  bank ${x:0>2}\n", .{r.detail}),
                    else => {},
                }
                try out.flush();
                std.process.exit(1);
            },
            else => return e,
        };

        // --audit: the conversion is the answer; verification is not being
        // asked for. Reported on the FIRST attempt, which is the full
        // candidate set — the one whose decisions describe the whole image.
        if (dbg_audit) {
            // Honour --save-attempt here too: the audit path is the SIX
            // MINUTE way to get a converted image (profile + one
            // conversion) instead of the forty-minute ladder, which makes
            // it the right tool for diffing one rewrite rule against
            // another.
            if (args.save_attempt) |ap|
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ap, .data = res.image });
            try printAudit(out, image, ub, &res);
            try out.flush();
            return;
        }

        // The FastROM layer, applied to every attempt image BEFORE
        // verification so the verified artifact IS the shipped one. The
        // profiler's observed MEMSEL stores come from the surface-0
        // power-on baseline (the stock `STZ $420D` init idiom runs at
        // boot). Refusal is fatal: the flag is an explicit request.
        if (args.wg_fastrom and args.whole_game and args.window) {
            var fr_ref: ?core.patchgen.Refusal = null;
            const fr = core.patchgen.generate(gpa, res.image, .{
                .memsel_store_pcs = con.prof.memsel_pcs[0..con.prof.n_memsel_pcs],
                .allow_coprocessor = true,
                .keep_map_mode = true,
                .lift_usage = ub,
            }, &fr_ref) catch |e| {
                if (e == error.Refused) {
                    try out.print("wg-fastrom refused: {s}\n", .{fr_ref.?.reason.describe()});
                    try out.flush();
                    std.process.exit(1);
                }
                return e;
            };
            res.image = fr.image;
            try out.print(
                "  wg-fastrom: MEMSEL stub at $00:{x:0>4}, {} trampoline(s), {} MEMSEL store(s) neutralised, {} long bank(s) lifted to the fast mirrors\n",
                .{ fr.stub_addr, fr.trampolines, fr.memsel_stores_nopped, fr.banks_lifted },
            );
            try out.flush();
        }
        if (args.save_attempt) |ap| {
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ap, .data = res.image });
            // Every rung, numbered — the bisect overwrites the plain name,
            // and the failing rung is usually the interesting one.
            var nbuf: [256]u8 = undefined;
            const numbered = if (phase_async)
                std.fmt.bufPrint(&nbuf, "{s}.async", .{ap}) catch ap
            else
                std.fmt.bufPrint(&nbuf, "{s}.{d}", .{ ap, n_dropped }) catch ap;
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = numbered, .data = res.image });
        }
        // The verify runs for this attempt, one per surface. Every
        // surface must pass; the attempt's tier is the WEAKEST across
        // them, and the first failing surface drives the bisect.
        var passed: ?SaTier = .strict;
        var fail_why: []const u8 = "";
        var fail_frame: u32 = 0;
        var equiv: util.Equivalence = .identical;
        var fail_mov: ?util.movie.Movie = null;
        var fail_s: usize = 0;
        var conv_sum: @TypeOf(sum) = undefined;
        for (0..n_surf) |s| {
            // Evidence-only movie: it profiled into the union above; its
            // gameplay forks at the first RNG-divergent event, so a
            // tick-locked verdict over it compares two different games.
            if (!args.movie_verify[s]) continue;
            const s_total = totals[s];
            const s_hashes = hashes_s[s];
            const s_conv_hashes = conv_hashes_s[s];
            const s_env_base = env_base_s[s];
            const s_env_conv = env_conv_s[s];
            @memset(s_env_conv, 0);
            var fast_audio = core.console.audio_hash_init;
            conv_samples.clearRetainingCapacity();
            {
                const cart2 = try core.Cartridge.load(gpa, res.image);
                const con2 = try gpa.create(core.ProfilingConsole);
                con2.init(cart2);
                applySidecar(con2, movAt(movs, s));
                if (surfaceAnchor(movs, s, verify_state)) |sb| try seedConverted(con2, sb, &plan, &res);
                var feed2: util.movie.Feed = .init(movAt(movs, s));
                for (0..s_total) |i| {
                    feed2.step(con2, i);
                    con2.runFrame();
                    try util.drainAudio(con2, &fast_audio, EnergySink{ .cell = &s_env_conv[i] }, EnergySink.add);
                    s_conv_hashes[i] = core.console.hashFrame(con2.framebuffer());
                    if (con2.takeProfile()) |smp| {
                        if (i >= args.skip) conv_samples.appendAssumeCapacity(smp);
                    }
                }
                con2.cart.deinit(gpa);
                gpa.destroy(con2);
            }
            const conv_scratch = try gpa.alloc(f64, conv_samples.items.len);
            const s_conv_sum = profile.summarise(conv_samples.items, conv_scratch);
            if (s == 0) conv_sum = s_conv_sum;

            // Stage-S4 gate, three tiers: strict identity; frames
            // identical with envelope-equivalent audio; equivalent modulo
            // timing with a non-negative lag improvement.
            const s_equiv = util.framesEquivalent(s_hashes, s_conv_hashes);
            var s_tier: ?SaTier = switch (s_equiv) {
                .identical => blk: {
                    if (fast_audio == base_audio_s[s]) break :blk .strict;
                    if (util.audioEnvelopeMismatch(s_env_base, s_env_conv)) |bad| {
                        fail_why = "audio envelope diverged (a sound moved, silenced, or invented)";
                        fail_frame = bad;
                        break :blk null;
                    }
                    break :blk .envelope;
                },
                .equivalent => blk: {
                    if (s_conv_sum.lag_frames > sum_s[s].lag_frames) {
                        fail_why = "same pictures but MORE dropped frames — a regression";
                        break :blk null;
                    }
                    break :blk .equivalent;
                },
                .divergent => blk: {
                    fail_why = "renders pictures the original never showed";
                    fail_frame = firstDiff(s_hashes, s_conv_hashes);
                    break :blk null;
                },
            };

            // The behavioral tier: a slowdown-removing conversion cannot
            // be frame-identical to a slowed-down baseline, so
            // `divergent` from the pixel gate is where working offloads
            // go to die. Opt-in. Whole-game (SA-1-execution) images stay
            // excluded — their state relocation is not modelled — but
            // WINDOW images are in.
            if (s_tier == null and s_equiv == .divergent and args.verify_behavioral and
                (!args.whole_game or args.window))
            {
                if (n_surf > 1) try out.print("  surface {} of {}:\n", .{ s + 1, n_surf });
                s_tier = try runBehavioralTier(gpa, out, image, res.image, &plan, &res, movAt(movs, s), surfaceAnchor(movs, s, verify_state), args.window, s_total, &fail_why, &fail_frame);
            }
            if (s_tier) |t| {
                if (@intFromEnum(t) > @intFromEnum(passed.?)) passed = t;
            } else {
                passed = null;
                equiv = s_equiv;
                fail_mov = movAt(movs, s);
                fail_s = s;
                if (n_surf > 1) try out.print("  surface {} of {} FAILED: {s}\n", .{ s + 1, n_surf, fail_why });
                break;
            }
        }

        if (passed) |tier| {
            if (!phase_async) {
                // The sync ladder's maximal passing configuration. Try
                // the async flavor when it exists and would differ —
                // window mode, a first candidate never async-demoted,
                // and the caller didn't opt out.
                const async_worth = args.whole_game and args.window and !args.wg_sync and
                    args.verify_behavioral and n_cands > 0 and !cands[0].no_async;
                if (async_worth) {
                    sync_pass = .{ .res = res, .tier = tier, .conv_sum = conv_sum };
                    phase_async = true;
                    try out.print(
                        "  greedy: sync config PASSED ({} tree(s), {} dropped frame(s)); trying the async flavor...\n",
                        .{ res.stats.offload_count, conv_sum.lag_frames },
                    );
                    try out.flush();
                    continue;
                }
                try reportSa1(io, gpa, out, args, image, res, tier, total, sum, conv_sum, dropped[0..n_dropped], dropped_why[0..n_dropped], cov_total, cov_late);
                return;
            }
            // Async passed too: ship whichever measured better.
            const sp = sync_pass.?;
            if (conv_sum.lag_frames < sp.conv_sum.lag_frames) {
                try out.print(
                    "  greedy: async config wins — {} vs {} dropped frame(s); shipping async\n",
                    .{ conv_sum.lag_frames, sp.conv_sum.lag_frames },
                );
                try reportSa1(io, gpa, out, args, image, res, tier, total, sum, conv_sum, dropped[0..n_dropped], dropped_why[0..n_dropped], cov_total, cov_late);
            } else {
                try out.print(
                    "  greedy: sync config wins — {} vs {} dropped frame(s); shipping sync\n",
                    .{ sp.conv_sum.lag_frames, conv_sum.lag_frames },
                );
                try reportSa1(io, gpa, out, args, image, sp.res, sp.tier, total, sum, sp.conv_sum, dropped[0..n_dropped], dropped_why[0..n_dropped], cov_total, cov_late);
            }
            return;
        }

        // A failed async flavor loses the competition and nothing more:
        // the sync winner already exists and ships.
        if (phase_async) {
            const sp = sync_pass.?;
            try out.print("  greedy: async flavor failed ({s}) — keeping the sync config ({} dropped frame(s))\n", .{ fail_why, sp.conv_sum.lag_frames });
            try reportSa1(io, gpa, out, args, image, sp.res, sp.tier, total, sum, sp.conv_sum, dropped[0..n_dropped], dropped_why[0..n_dropped], cov_total, cov_late);
            return;
        }

        // Failure. Terminal when no offloaded routine could explain it —
        // window images bisect their offloads like the S3 path (a failed
        // window attempt with none left is what proves the RELOCATION
        // itself, which the seventh commit already did).
        if ((args.whole_game and !args.window) or res.stats.offload_count == 0) {
            try out.print("verification FAILED: {s}", .{fail_why});
            if (equiv != .equivalent) try out.print(" (first at frame {})", .{fail_frame});
            try out.print(".\n  No patch written.\n", .{});
            if (equiv == .identical) try printEnvelopeDiag(out, env_base_s[fail_s], env_conv_s[fail_s], fail_frame, totals[fail_s]);
            if (equiv == .divergent) {
                try out.print(
                    \\  Either uncovered code touches moved state, or the game animates through
                    \\  lag (an NMI-side frame counter), which this gate cannot tell apart from
                    \\  breakage.
                    \\
                , .{});
                try printCoverage(out, cov_total, cov_late, total);
            }
            try out.flush();
            std.process.exit(1);
        }

        // Diagnose and drop a culprit, then go around again — against the
        // surface that failed.
        const culprit = try diagnoseCulprit(gpa, out, image, res, cands[0..n_cands], fail_mov, equiv, fail_frame, fail_why, ub);
        // The mode ladder: an ASYNC culprit is demoted to synchronous
        // before it is dropped — a caller that needed the routine's
        // register results, or a read racing the in-flight window, is
        // cured by waiting. Only a sync culprit is dropped outright.
        if (res.stats.async_entry == culprit) {
            for (cands[0..n_cands]) |*c| {
                if (c.entry == culprit) c.no_async = true;
            }
            try out.print("  auto-bisect: offload $00:{x:0>4} was ASYNC — retrying it synchronously ({} attempt(s) so far)\n", .{ culprit, n_dropped + 1 });
            try out.flush();
            continue;
        }
        dropped[n_dropped] = culprit;
        dropped_why[n_dropped] = fail_why;
        n_dropped += 1;
        try out.print("  auto-bisect: dropping offload $00:{x:0>4} and retrying ({} attempt(s) so far)\n", .{ culprit, n_dropped });
        try out.flush();
    }
}

/// Which S4 tier a successful SA-1 conversion verified under.
const SaTier = enum { strict, envelope, equivalent, behavioral };

/// Surface `s`'s movie — null for the legacy no-movie (attract) surface.
fn movAt(movs: []const util.movie.Movie, s: usize) ?util.movie.Movie {
    return if (movs.len == 0) null else movs[s];
}

/// `--behavioral-probe` (undocumented): the behavioral tier alone, stock
/// baseline vs a saved rung image, full verdict accounting printed —
/// iterating the tier's rules in minutes instead of ladder-hours.
fn runBehavioralProbe(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    args: Args,
    base_image: []const u8,
    conv_path: []const u8,
    movs: []const util.movie.Movie,
) !void {
    const conv_raw = std.Io.Dir.cwd().readFileAlloc(io, conv_path, gpa, .limited(16 * 1024 * 1024)) catch {
        try out.print("error: cannot read '{s}'\n", .{conv_path});
        try out.flush();
        std.process.exit(1);
    };
    const conv_image = core.header.stripCopierHeader(conv_raw);
    var plan: profile.Plan = .{};
    var res: core.sa1gen.Result = .{ .image = @constCast(conv_image), .stats = .{}, .fate = @splat(.not_attempted) };
    const n = @max(1, movs.len);
    for (0..n) |s| {
        const m = movAt(movs, s);
        const frames = args.frames orelse if (m) |mm|
            @max(1, @as(u32, @intCast(mm.frames.len)) -| args.skip)
        else
            gen_frames_default;
        const total = args.skip + frames;
        const bv = try verifyBehavioral(gpa, base_image, conv_image, &plan, &res, m, null, true, total);
        const verdict_name: []const u8 = switch (bv.verdict) {
            .pass => |k| if (k == .clean) "PASS clean" else "PASS echoes",
            .fail => |w| switch (w) {
                .persistence => "FAIL persistence",
                .spread => "FAIL spread",
                .flood => "FAIL flood",
            },
        };
        try out.print(
            "surface {}: {s} — ticks {} ({} wall-stable, {} skew-active), bad {}, addrs {} ({} stable-active), novelty {}, worst_run {} (from tick {}), held {}, overflow {}, epochs {}, first_bad_frame {}\n",
            .{
                s + 1,                  verdict_name,               bv.ticks_base,
                bv.stats.stable_ticks,  bv.stats.skew_active_ticks, bv.stats.bad_ticks,
                bv.stats.n_addrs,       bv.stats.stableAddrCount(), bv.stats.novelty_ticks,
                bv.stats.worst_run,     bv.stats.worst_start,       bv.stats.heldCount(),
                bv.stats.addr_overflow, bv.stats.epoch_budget,      bv.first_bad_frame,
            },
        );
        try out.print("  runs: worst {} [{}..{}], runner-up {}, last_tick {}, reaches_end {}, burst_ticks {} (runs <= {}), long {} ({} ticks)\n", .{
            bv.stats.worst_run, bv.stats.worst_start,     bv.stats.worst_end,   bv.stats.second_run,
            bv.stats.last_tick, bv.stats.runReachesEnd(), bv.stats.burst_total, util.Persistence.burst_len,
            bv.stats.long_runs, bv.stats.long_total,
        });
        if (bv.n_sample > 0) {
            try out.print("  first-bad sample:", .{});
            for (bv.sample[0..bv.n_sample]) |adr| try out.print(" ${X:0>4}(d{X:0>2})", .{ adr & 0xFFFF, (adr >> 16) & 0xFF });
            try out.print("\n", .{});
        }
        if (bv.fork_wall) |fw| if (fw > 600 and fw + 120 < total) {
            try out.print("  RNG-fork signature (open terminal run) — probing up to the horizon at wall {}...\n", .{fw});
            try out.flush();
            const bv2 = try verifyBehavioral(gpa, base_image, conv_image, &plan, &res, m, null, true, fw);
            try out.print("  pre-horizon: {s} — ticks {}, bad {}, worst_run {}\n", .{
                switch (bv2.verdict) {
                    .pass => |k| if (k == .clean) @as([]const u8, "PASS clean") else "PASS echoes",
                    .fail => "FAIL",
                },
                bv2.ticks_base,
                bv2.stats.bad_ticks,
                bv2.stats.worst_run,
            });
        };
        try out.flush();
    }
}

/// The behavioral tier for one surface: returns `.behavioral` on pass,
/// null on fail with `fail_why`/`fail_frame` filled for the bisect.
fn runBehavioralTier(
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    base_image: []const u8,
    conv_image: []const u8,
    plan: *const profile.Plan,
    res: *const core.sa1gen.Result,
    mov: ?util.movie.Movie,
    verify_state: ?[]const u8,
    window: bool,
    total: u32,
    fail_why: *[]const u8,
    fail_frame: *u32,
) !?SaTier {
    try out.print("  pixel gate: divergent; behavioral tier (tick-locked replays)...\n", .{});
    try out.flush();
    const bv = try verifyBehavioral(gpa, base_image, conv_image, plan, res, mov, verify_state, window, total);
    switch (bv.verdict) {
        .pass => |kind| {
            try out.print(
                "  behavioral: {s} — {} ticks compared ({} at stable lag differential), {} diverging ({} address(es), worst run {})\n",
                .{
                    if (kind == .clean) @as([]const u8, "logic state IDENTICAL at every tick") else "wall-time echoes only",
                    bv.ticks_base,
                    bv.stats.stable_ticks,
                    bv.stats.bad_ticks,
                    bv.stats.n_addrs,
                    bv.stats.worst_run,
                },
            );
            try out.print(
                "    inputs: {} frame(s), movie {} frame(s), {s}, {s}\n    pairing ended: {s}\n",
                .{
                    total,
                    if (mov) |m| @as(u32, @intCast(m.frames.len)) else 0,
                    if (verify_state != null) @as([]const u8, "seeded from a state") else "from power-on",
                    if (window) @as([]const u8, "window homes") else "plan homes",
                    bv.exit.describe(),
                },
            );
            if (bv.stats.skew_active_ticks > 0)
                try out.print(
                    "    {} tick(s) diverged only while the lag differential itself was moving (the removed slowdown, not corruption; excluded from the budgets)\n",
                    .{bv.stats.skew_active_ticks},
                );
            if (bv.stats.heldCount() > 0)
                try out.print(
                    "    {} cell(s) hold a constant offset (wall-time origins: pass counters and state seeded from them)\n",
                    .{bv.stats.heldCount()},
                );
            return .behavioral;
        },
        .fail => |why| {
            // A terminal open run in the second half is the RNG-fork
            // signature: the timing change moved the wall-origin counters
            // enemy RNG seeds from, the game forked at the first
            // RNG-sensitive event, and every later tick compares two
            // different healthy games. Verify up to the horizon: a pass
            // there is the honest maximum tick-locked replay can prove
            // (v17 has the same property; humans QA past it).
            if (bv.fork_wall) |fw| if (fw > 600 and fw + 120 < total) {
                try out.print(
                    "  behavioral: diverges from wall frame {} to surface end — RNG-fork signature; re-verifying up to the horizon...\n",
                    .{fw},
                );
                try out.flush();
                const bv2 = try verifyBehavioral(gpa, base_image, conv_image, plan, res, mov, verify_state, window, fw);
                if (bv2.verdict == .pass) {
                    try out.print(
                        "  behavioral: equivalent MODULO {} RNG-FORK EPISODE(S) — prefix of {} ticks verified to the first fork at wall frame {} of {}; {} tick(s) inside fork episodes excused ({s}); off-episode divergence {} tick(s) with every run <= {}\n",
                        .{
                            bv.stats.long_runs,
                            bv2.ticks_base,
                            fw,
                            total,
                            bv.stats.long_total,
                            if (bv.stats.runReachesEnd()) @as([]const u8, "the last runs to the surface end: a gameplay fork, unverifiable by replay — eyeball it") else "each healed by a scene reset, which corruption would not survive",
                            bv.stats.bad_ticks - bv.stats.long_total,
                            util.Persistence.max_run,
                        },
                    );
                    return .behavioral;
                }
                try out.print("  behavioral: pre-horizon verification also fails — treating as real divergence\n", .{});
            };
            fail_why.* = switch (why) {
                .persistence => "live state diverges and never heals (or the conversion stopped ticking)",
                .spread => "live-state divergence keeps reaching new addresses",
                .flood => "live state diverges on too many ticks",
            };
            fail_frame.* = bv.first_bad_frame;
            try out.print("  behavioral: FAIL — {s}\n", .{fail_why.*});
            // The SAME statistics a pass prints, and the tier's inputs
            // besides. A pass used to report "2517 ticks compared, worst
            // run 24" while a failure reported a sentence — so a passing
            // run and a failing one could not be diffed field by field,
            // and a day went into inferring what one line would have
            // said. A verdict that cannot be compared to another verdict
            // is not evidence.
            try out.print(
                "    inputs: {} frame(s), movie {} frame(s), {s}, {s}\n" ++
                    "    pairing ended: {s}\n" ++
                    "    stats: {} ticks compared ({} at stable lag differential), {} diverging\n" ++
                    "      ({} address(es), {} stable-active), novelty {}, held {}, epochs {}\n" ++
                    "      worst run {} [{}..{}], runner-up {}, reaches end {}, bursts {} (runs <= {}),\n" ++
                    "      long runs {} ({} ticks), last tick {}, addr overflow {}\n",
                .{
                    total,
                    if (mov) |m| @as(u32, @intCast(m.frames.len)) else 0,
                    if (verify_state != null) @as([]const u8, "seeded from a state") else "from power-on",
                    if (window) @as([]const u8, "window homes") else "plan homes",
                    bv.exit.describe(),
                    bv.ticks_base,
                    bv.stats.stable_ticks,
                    bv.stats.bad_ticks,
                    bv.stats.n_addrs,
                    bv.stats.stableAddrCount(),
                    bv.stats.novelty_ticks,
                    bv.stats.heldCount(),
                    bv.stats.epoch_budget,
                    bv.stats.worst_run,
                    bv.stats.worst_start,
                    bv.stats.worst_end,
                    bv.stats.second_run,
                    bv.stats.runReachesEnd(),
                    bv.stats.burst_total,
                    util.Persistence.burst_len,
                    bv.stats.long_runs,
                    bv.stats.long_total,
                    bv.stats.last_tick,
                    bv.stats.addr_overflow,
                },
            );
            if (bv.n_sample > 0) {
                try out.print("    first at baseline frame {}, e.g.:", .{bv.first_bad_frame});
                for (bv.sample[0..bv.n_sample]) |adr| {
                    try out.print(" ${X:0>2}:{X:0>4}", .{ @as(u32, 0x7E) + (adr >> 16), adr & 0xFFFF });
                }
                try out.print("\n", .{});
            }
            try out.flush();
            return null;
        },
    }
}

/// First index where the two per-frame hash streams differ (streams are
/// equal length by construction). Only meaningful for the divergent case,
/// where it anchors the forensics.
fn firstDiff(a: []const u64, b: []const u64) u32 {
    for (a, b, 0..) |x, y, i| {
        if (x != y) return @intCast(i);
    }
    return 0;
}

/// On a failed attempt with offloads active: replay BOTH images to the
/// first bad frame, diff WRAM, attribute the differing bytes against the
/// offloaded routines' profiled working sets, and pick the routine to
/// drop — the attributed one when the evidence names it, the last
/// offloaded one otherwise.
fn diagnoseCulprit(
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    base_image: []const u8,
    res: core.sa1gen.Result,
    cands: []const core.sa1gen.Candidate,
    mov: ?util.movie.Movie,
    equiv: util.Equivalence,
    fail_frame: u32,
    fail_why: []const u8,
    usage: []const u8,
) !u24 {
    const n_off = res.stats.offload_count;
    const entries = res.stats.offload_entries[0..n_off];
    try out.print("verification failed with {} offload(s) active: {s}\n", .{ n_off, fail_why });

    var culprit: u24 = entries[n_off - 1];
    if (equiv == .divergent) {
        // Replay both sides to the divergence and diff WRAM.
        const wram_a = try replayWram(gpa, base_image, fail_frame + 1, mov);
        const wram_b = try replayWram(gpa, res.image, fail_frame + 1, mov);
        var n_shown: u32 = 0;
        var attributed: ?u24 = null;
        for (wram_a, wram_b, 0..) |x, y, off| {
            if (x == y) continue;
            const page: u16 = @intCast(off >> 8);
            var owner: ?u24 = null;
            var shared = false;
            for (entries) |e| {
                for (cands) |c| {
                    if (c.entry == e and page < 512 and profile.getPage(c.pages, page)) {
                        if (owner != null) shared = true;
                        owner = e;
                    }
                }
            }
            if (n_shown < 4) {
                try out.print("  diverged by frame {}: WRAM $7E:{x:0>4} = {x:0>2} -> {x:0>2}{s}", .{
                    fail_frame, off, x, y,
                    if (owner != null) " — inside the working set of $00:" else " — outside every offloaded set",
                });
                if (owner) |o| try out.print("{x:0>4}{s}", .{ o, if (shared) " (shared)" else "" });
                try out.print("\n", .{});
            }
            if (attributed == null and owner != null and !shared) attributed = owner;
            n_shown += 1;
        }
        if (n_shown > 4) try out.print("  ({} differing WRAM byte(s) total)\n", .{n_shown});
        if (n_shown == 0) try out.print("  WRAM identical at the divergent frame — the difference is in PPU state\n  (timing-visible mid-flight rendering, not corrupted memory)\n", .{});
        if (attributed) |a| culprit = a;
    }

    // SA-1-side forensics for a pointer offload: replay the converted
    // image to the divergent frame with an execution trace over the
    // offloaded body's COPY, so the path the SA-1 actually took through
    // it is a direct read rather than an inference.
    for (entries, 0..) |e, i| {
        const copy = res.stats.offload_copy[i];
        if (copy == 0) continue; // leaf offload: no copy to watch
        const span = res.stats.offload_copy_len[i];
        const trace = try replayTrace(gpa, res.image, fail_frame + 1, mov, copy);
        defer gpa.destroy(trace);
        try out.print(
            "  sa1 trace of $00:{x:0>4}'s body copy at ${x:0>2}:{x:0>4} ({} bytes): {} instruction(s)\n" ++
                "  executed across {} distinct byte(s)",
            .{ e, copy >> 16, @as(u16, @truncate(copy)), span, trace.total, trace.distinct },
        );
        if (trace.total == 0) {
            try out.print(" — THE SA-1 NEVER ENTERED IT\n", .{});
            continue;
        }
        try out.print(", entered {} time(s)\n", .{trace.countAt(copy)});
        // How much of the body the SA-1 actually walked. Only OPCODE
        // starts count — operand bytes are never instruction addresses,
        // and the copy mirrors the original byte for byte, so the S1
        // coverage map supplies which offsets are opcodes.
        var n_ops: u32 = 0;
        var n_ran: u32 = 0;
        var first_skipped: ?u24 = null;
        for (0..span) |k| {
            if (usage[e + k] & core.usage_map.flag_opcode == 0) continue;
            n_ops += 1;
            if (trace.ran(copy + @as(u24, @intCast(k)))) {
                n_ran += 1;
            } else if (first_skipped == null) {
                first_skipped = @intCast(e + k);
            }
        }
        try out.print("  covered {}/{} of the body's instructions", .{ n_ran, n_ops });
        if (first_skipped) |f| try out.print(
            "; first one never reached is the original's $00:{x:0>4}\n",
            .{f},
        ) else try out.print(" (the whole body ran)\n", .{});
        // The last few instructions, with the state that decided them.
        var buf: [core.sa1_trace.ring_cap]core.sa1_trace.Rec = undefined;
        const recent = trace.recent(&buf);
        const show = @min(recent.len, 6);
        try out.print("  last {} instruction(s) inside it:\n", .{show});
        for (recent[recent.len - show ..]) |r| try out.print(
            "    ${x:0>2}:{x:0>4}  A={x:0>4} X={x:0>4} Y={x:0>4} D={x:0>4} DB={x:0>2} P={x:0>2}\n",
            .{ r.pc >> 16, @as(u16, @truncate(r.pc)), r.c, r.x, r.y, r.d, r.dbr, r.p },
        );
    }
    return culprit;
}

/// Replay `image` for `n` frames with an SA-1 execution trace windowed at
/// `lo`. Caller owns the returned trace.
fn replayTrace(
    gpa: std.mem.Allocator,
    image: []const u8,
    n: u32,
    mov: ?util.movie.Movie,
    lo: u24,
) !*core.sa1_trace.Trace {
    const trace = try gpa.create(core.sa1_trace.Trace);
    errdefer gpa.destroy(trace);
    trace.* = core.sa1_trace.Trace.init(lo);
    const cart = try core.Cartridge.load(gpa, image);
    const con = try gpa.create(core.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    con.bus.sa1.trace = trace;
    var feed: util.movie.Feed = .init(mov);
    for (0..n) |i| {
        feed.step(con, i);
        con.runFrame();
    }
    return trace;
}

/// Replay an image for `n` frames and return its WRAM (caller-owned copy).
fn replayWram(gpa: std.mem.Allocator, image: []const u8, n: u32, mov: ?util.movie.Movie) ![]u8 {
    const cart = try core.Cartridge.load(gpa, image);
    const con = try gpa.create(core.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    var feed: util.movie.Feed = .init(mov);
    for (0..n) |i| {
        feed.step(con, i);
        con.runFrame();
    }
    return gpa.dupe(u8, &con.bus.wram.data);
}

/// The envelope-failure neighbourhood diagnostic (terminal failures only).
fn printEnvelopeDiag(out: *std.Io.Writer, env_base: []const u64, env_conv: []const u64, bad: u32, total: u32) !void {
    const from = bad -| 5;
    const to = @min(total, bad + 6);
    try out.print("  frame:    ", .{});
    for (from..to) |i| try out.print("{d:>9}", .{i});
    try out.print("\n  original: ", .{});
    for (from..to) |i| try out.print("{d:>9}", .{env_base[i] / 1000});
    try out.print("\n  converted:", .{});
    for (from..to) |i| try out.print("{d:>9}", .{env_conv[i] / 1000});
    var n_bad: u32 = 0;
    for (0..total) |i| {
        var one = [1]u64{env_base[i]};
        var other = [1]u64{env_conv[i]};
        if (util.audioEnvelopeMismatch(one[0..], other[0..]) != null) n_bad += 1;
    }
    try out.print("\n  (energies in thousands; {} of {} frames outside the window point-wise)\n", .{ n_bad, total });
}

/// The success report for an SA-1 conversion attempt, including what the
/// auto-bisect dropped along the way.
fn reportSa1(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    args: Args,
    image: []const u8,
    res: core.sa1gen.Result,
    tier: SaTier,
    total: u32,
    sum: profile.Summary,
    conv_sum: profile.Summary,
    dropped: []const u24,
    dropped_why: []const []const u8,
    cov_total: u32,
    cov_late: u32,
) !void {
    const bps = try core.patch.writeBps(gpa, image, res.image);
    const stem = args.rom[0 .. std.mem.lastIndexOfScalar(u8, args.rom, '.') orelse args.rom.len];
    const path = args.gen_out orelse try std.fmt.allocPrint(gpa, "{s}-sa1.bps", .{stem});
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bps }) catch {
        try out.print("error: cannot write '{s}'\n", .{path});
        try out.flush();
        std.process.exit(1);
    };
    // The invocation, beside its own artifact. A patch whose command has
    // to be remembered is a patch nobody can regenerate.
    const cmd_path = try std.fmt.allocPrint(gpa, "{s}.cmd", .{path});
    const cmd_data = try std.fmt.allocPrint(gpa, "{s}\n", .{args.cmdline});
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cmd_path, .data = cmd_data }) catch {};

    try out.print("wrote {s} ({} bytes)\n", .{ path, bps.len });
    try out.print("wrote {s}\n\n", .{cmd_path});
    if (args.window) {
        try out.print(
            \\uniform window relocation (v17's architecture):
            \\  boot shim at $00:{x:0>4}; the game KEEPS RUNNING ON THE S-CPU
            \\  its WRAM moved wholesale — low 8 KiB into the S-CPU's BW-RAM window
            \\  ($6000-$7FFF, every relative distance preserved, so indexed bases
            \\  rewrite soundly), $7E/$7F long references re-banked to $40/$41
            \\  {d} long site(s) and {d} absolute site(s) rewritten; {d} D/S/DBR move(s)
            \\  MMIO stays native; the SA-1 never leaves reset — the cart is carried
            \\  for its RAM. This is the enabler for resident offloads over the whole
            \\  working set.
            \\
        , .{
            res.stats.shim_addr,
            res.stats.rewritten_long,
            res.stats.rewritten_abs,
            res.stats.dp_sites,
        });
        if (res.stats.split_sites != 0)
            try out.print(
                "  {} split site(s) dispatch through a thunk instead of a fixed operand:\n  {} on the runtime data bank, {} on the index register's magnitude\n  (tiny-base indexed absolutes — no single operand serves a data base\n  and a ROM walk); {} of them behind a far stub for want of bank room\n",
                .{ res.stats.split_sites, res.stats.split_sites - res.stats.idx_split_sites, res.stats.idx_split_sites, res.stats.split_far },
            );
        if (res.stats.disp_sites != 0)
            try out.print(
                "  {} unmeasured site(s) in full banks share one stub per bank through\n  the cold dispatcher (return-address lookup; ~150 cycles, never-seen code)\n",
                .{res.stats.disp_sites},
            );
        if (res.stats.rewritten_ptr_banks != 0 or res.stats.rewritten_idx_words != 0 or res.stats.rewritten_dma_addrs != 0)
            try out.print(
                "  measured value rewrites: {} pointer-bank byte(s) re-banked, {} dp,X\n  pointer word(s) pre-shifted -$6000, {} dma-addr word(s) pre-shifted\n  +$6000 (addressing state travelling as data — the idioms operand\n  rewrites cannot reach)\n",
                .{ res.stats.rewritten_ptr_banks, res.stats.rewritten_idx_words, res.stats.rewritten_dma_addrs },
            );
        if (res.stats.rewritten_queue_imms != 0)
            try out.print(
                "  {} queue-bank immediate(s) re-banked BY SIGNATURE (LDA #imm16 staged\n  into a dispatch queue's bank column and PLB'd by later code — the\n  XBA/PHA/PLB/PLB consumer names the column; no coverage required)\n",
                .{res.stats.rewritten_queue_imms},
            );
        if (res.stats.rewritten_twin_jsls != 0)
            try out.print(
                "  {} mirror-bank JSL(s) re-banked on their DE-MIRRORED TWIN's\n  evidence — uncovered call sites whose target is already called in\n  its $20-$3F form by covered code (>=2 calls). The class that cost\n  three player-found freezes; no coverage required\n",
                .{res.stats.rewritten_twin_jsls},
            );
        if (res.stats.room_walk_states != 0)
            try out.print(
                "  {} room-state level-data bank(s) re-banked by the ROOM-GRAPH WALK\n  ({} rooms, {} states reached through doors from the landing site —\n  Super Metroid's structure, not coverage: a state no surface loaded\n  kept its stock MB2 bank and decompressed garbage geometry)\n",
                .{ res.stats.rewritten_room_level_banks, res.stats.room_walk_rooms, res.stats.room_walk_states },
            );
        if (res.stats.room_walk_refused_at != 0)
            try out.print("  room-graph walk REFUSED at $8F:{X:0>4} (a header failed validation);\n  level pointers left to evidence alone\n", .{res.stats.room_walk_refused_at});
        if (res.stats.bg_records != 0)
            try out.print(
                "  {} background DMA-list source bank(s) de-mirrored across {} record(s)\n  — the BG2 picture for rooms no surface loaded (else correct foreground\n  over garbage background)\n",
                .{ res.stats.rewritten_bg_banks, res.stats.bg_records },
            );
        if (res.stats.decomp_inline_sites != 0)
            try out.print(
                "  {} decompressor inline-destination bank(s) re-banked BY SIGNATURE\n  ({} `JSL $80:B0FF` sites naming WRAM) — the destination is data in the\n  code stream; a site no recording drove decompressed into real $7E\n  while the game read the stale copy at $40 (wrong tile table = right\n  geometry, wrong textures)\n",
                .{ res.stats.rewritten_decomp_inline_banks, res.stats.decomp_inline_sites },
            );
        if (res.stats.tileset_records != 0)
            try out.print(
                "  {} tileset-table bank(s) de-mirrored ({} records) — the picture\n  (tile table/GFX/palette) for tilesets no surface loaded; without it a\n  reachable room renders tile garbage over a wrong palette\n",
                .{ res.stats.rewritten_tileset_banks, res.stats.tileset_records },
            );
        if (res.stats.tileset_refused_at != 0)
            try out.print("  tileset-table pass REFUSED at $8F:{X:0>4} (a record failed validation)\n", .{res.stats.tileset_refused_at});
        if (res.stats.enemy_headers != 0)
            try out.print(
                "  {} enemy-header bank(s) de-mirrored ({} headers) — the species' AI,\n  palette and instruction-list bank for enemies no surface met; without\n  it a new enemy paints its palette from the wrong megabyte and runs its\n  AI from it\n",
                .{ res.stats.rewritten_enemy_banks, res.stats.enemy_headers },
            );
        if (res.stats.pointer_seed_sites != 0)
            try out.print(
                "  {} pointer-seed immediate(s) translated ({} sites) — long pointers the\n  game seeds from constants (the pause map's tilemap bank and its\n  explored-bits address); without it the map draws from the abandoned\n  WRAM homes\n",
                .{ res.stats.rewritten_pointer_seeds, res.stats.pointer_seed_sites },
            );
        if (res.stats.area_map_entries != 0)
            try out.print(
                "  {} area-map table bank(s) de-mirrored ({} entries) — the per-area map\n  tilemap pointers the HUD minimap and the pause map read through; without\n  it the minimap paints text glyphs for map cells\n",
                .{ res.stats.rewritten_area_map_banks, res.stats.area_map_entries },
            );
        if (res.stats.area_map_refused_at != 0)
            try out.print("  area-map table pass REFUSED at $82:{X:0>4} (an entry failed validation)\n", .{res.stats.area_map_refused_at});
        if (res.stats.rewritten_dasb != 0)
            try out.print(
                "  {} HDMA indirect-bank ($43x7 DASB) write(s) wrapped in a runtime\n  rebank thunk ($7E/$7F->$40/$41 as the write happens — an indirect\n  HDMA whose source is WRAM follows its data into BW-RAM)\n",
                .{res.stats.rewritten_dasb},
            );
        if (res.stats.rewritten_hdma_indirect != 0)
            try out.print(
                "  {} low-WRAM indirect address(es) relocated +$6000 in indirect-HDMA\n  table(s) (a per-scanline HDMA source in the moved low 8 KiB now reads\n  the window copy, not the abandoned mirror)\n",
                .{res.stats.rewritten_hdma_indirect},
            );
        if (res.stats.offload_count != 0) {
            try out.print("  {} routine tree(s) execute ON THE SA-1, verbatim against the shared\n  window (resident by construction, registers+D+DBR through the mailbox):\n", .{res.stats.offload_count});
            for (res.stats.offload_entries[0..res.stats.offload_count], 0..) |e, i| {
                try out.print("    $00:{x:0>4} ({} byte(s) of tree copied{s})\n", .{
                    e,
                    res.stats.offload_copy_len[i],
                    if (res.stats.async_entry == e) @as([]const u8, ", ASYNC — fire-and-forget") else "",
                });
            }
        }
    } else if (args.whole_game) {
        try out.print(
            \\whole-game migration (SA-1 Root):
            \\  boot shim at $00:{x:0>4}, S-CPU service loop at $00:{x:0>4}
            \\  the game executes ENTIRELY on the SA-1 — its WRAM working set lives in
            \\  identity-mapped I-RAM; {d} MMIO site(s) proxied through the I-RAM mailbox
            \\  (NMI masked per transaction), {d} long site(s) re-banked into the window;
            \\  NMI forwarded S-CPU -> SA-1 through CCNT/CNV
            \\
        , .{
            res.stats.shim_addr,     res.stats.park_addr,
            res.stats.offload_sites, res.stats.rewritten_long,
        });
    } else {
        try out.print(
            \\SA-1 conversion (stages S3 + S4):
            \\  shim at $00:{x:0>4}, SA-1 booted at $00:{x:0>4}
            \\  regions moved {d} / blocked {d}; rewrites: {d} long, {d} abs; {d} dp site(s){s}
            \\
        , .{
            res.stats.shim_addr,      res.stats.park_addr,
            res.stats.regions_moved,  res.stats.regions_blocked,
            res.stats.rewritten_long, res.stats.rewritten_abs,
            res.stats.dp_sites,       if (res.stats.d_moved) " (D=$3000)" else "",
        });
        if (res.stats.offload_count != 0) {
            try out.print(
                "  S3b: {} routine(s) execute ON THE SA-1 (first: $00:{x:0>4}; {} call site(s)\n" ++
                    "  re-pointed through message-port stubs, registers marshalled via the I-RAM\n" ++
                    "  mailbox)\n",
                .{ res.stats.offload_count, res.stats.offloaded, res.stats.offload_sites },
            );
            if (res.stats.pointer_offloads != 0) {
                try out.print(
                    "  of those, {} pointer routine(s) (JSL/RTL, runtime-pointer data) run against\n" ++
                        "  an identity-offset BW-RAM shadow of their profiled working set, marshalled\n" ++
                        "  per call; their bodies are COPIES — unseen S-CPU callers see original code\n" ++
                        "  marshal: {} bytes/call both ways, {} sibling entry point(s) folded into the\n" ++
                        "  working set, within the cost budget (marshal < half the measured compute)\n",
                    .{ res.stats.pointer_offloads, res.stats.marshal_bytes, res.stats.marshal_siblings },
                );
                if (res.stats.resident_offloads != 0) try out.print(
                    "  {} of them are BW-RAM RESIDENT: their data is not marshalled at all — the\n" ++
                        "  original body's data bank is rewritten too, so both CPUs address one copy\n" ++
                        "  in BW-RAM (only the direct page is still copied, per call)\n",
                    .{res.stats.resident_offloads},
                );
                if (res.stats.async_entry != 0) try out.print(
                    "  $00:{x:0>4} runs ASYNCHRONOUSLY: its stub fires the SA-1 and returns at\n" ++
                        "  once with the caller's own registers; a fence (at the next call and in\n" ++
                        "  an injected NMI prologue) completes the handshake. Nothing is copied\n" ++
                        "  back — only its BW-RAM-resident effects survive, by contract. The\n" ++
                        "  S-CPU and SA-1 genuinely overlap — this is where the conversion stops\n" ++
                        "  paying for its offloads and starts profiting from them\n",
                    .{res.stats.async_entry},
                );
            }
        } else {
            try out.print("  S3b: no hot routine passed the offload walks; execution stays on the\n  S-CPU (relocation-only patch)\n", .{});
        }
        for (dropped, dropped_why) |d, why| {
            try out.print("  auto-bisect: offload $00:{x:0>4} DROPPED — with it, verification {s}\n", .{ d, why });
        }
    }
    switch (tier) {
        .strict => try out.print(
            "  verified: IDENTICAL — {} frames pixel- and audio-identical (no timing shift)\n",
            .{total},
        ),
        .envelope => try out.print(
            \\  verified: FRAMES IDENTICAL — every one of {} frames pixel-identical; the
            \\  audio stream is phase-shifted (relocated access timing slides the APU
            \\  handshake by a sample) but its per-frame envelope matches: the same sounds
            \\  at the same frames. Sample-exactness is the one thing left UNVERIFIED.
            \\
        , .{total}),
        .equivalent => try out.print(
            \\  verified: EQUIVALENT MODULO TIMING — the same distinct pictures in the same
            \\  order, redistributed across {} frames (a speedup's exact signature); audio
            \\  equivalence is not checkable across a timing shift and goes UNVERIFIED
            \\
        , .{total}),
        .behavioral => try out.print(
            \\  verified: BEHAVIORALLY EQUIVALENT — the game's logic state matches at every
            \\  logic tick over {} frames (compared on the bytes the original actually
            \\  consumes, wherever the conversion relocated them; residual divergence was
            \\  wall-time echoes that self-heal). Pixels, audio, and wall timing change BY
            \\  DESIGN in a slowdown-removing conversion and go UNVERIFIED — eyeball a run.
            \\
        , .{total}),
    }
    try out.print(
        "  measured: dropped frames {} -> {}, mean utilisation {d:.0}% -> {d:.0}%\n",
        .{ sum.lag_frames, conv_sum.lag_frames, sum.mean_util * 100, conv_sum.mean_util * 100 },
    );
    try out.print(
        \\  caveat: code the profile never executed is invisible to the rewriter; a longer
        \\  or more varied capture widens coverage.
        \\
    , .{});
    try printCoverage(out, cov_total, cov_late, total);
    try out.flush();
}

/// Report the capture's coverage and, more usefully, whether it had
/// stopped growing. New instructions still appearing in the last tenth of
/// a run mean the profile had not settled — so whatever the rewriter did,
/// it did on partial evidence.
/// The conversion audit (`--audit`): what the rewriter did with every
/// memory-touching site it saw, and — the part that matters — what it left
/// alone and why.
///
/// The point is a DENOMINATOR. Until this existed, unconverted sites were
/// discovered by playing the game until something broke: twelve of them
/// turned up that way, and the laser bug lived among them for a week. A
/// census does not prove the conversion correct — it cannot, because the
/// hard question is which home an operand addresses at run time and that is
/// not a static property — but it turns "what else is broken?" from a QA
/// lottery into a list with a length.
fn printAudit(
    out: *std.Io.Writer,
    image: []const u8,
    ub: []const u8,
    res: *const core.sa1gen.Result,
) !void {
    const V = core.sa1gen.Verdict;
    const a = &res.audit;

    try out.print("\nCONVERSION AUDIT\n", .{});

    // --- reach: how much of the ROM the rewriter can even see ----------
    const dyn = core.usage_map.countOpcodes(ub);
    try out.print(
        "\n  reach: {} instruction(s) executed while profiling",
        .{dyn},
    );
    if (res.stats.cov_static_added != 0)
        try out.print(", + {} found by static\n  descent (--wg-static)", .{res.stats.cov_static_added})
    else
        try out.print("\n  (--wg-static NOT used: code the profile never ran was never rewritten)", .{});
    try out.print("\n", .{});

    // Per bank: instructions seen against bytes that are not blank fill.
    // A bank with content and no coverage is either graphics or code
    // nobody has played into — this cannot tell which, and says so.
    // A bank the descent never entered is a problem only if it holds CODE,
    // and "looks like code" is exactly the judgement a disassembler cannot
    // make on a ROM with no markers. So do not judge it — measure three
    // independent signals and print them side by side:
    //
    //   seen      instructions the rewriter has in hand
    //   calls     JSL/JML sites in seen code naming this bank as a TARGET
    //   data      long accesses and block moves in seen code naming it as
    //             a SOURCE or destination — positive evidence of data
    //   density   how often this bank's bytes are the opcodes that
    //             dominate real 65816 code, against the two banks known to
    //             be code as the yardstick
    //
    // A bank with no coverage, no calls, plenty of data references and a
    // density a third of the code banks' is data, and the report should
    // say so rather than raise an alarm it cannot substantiate.
    const codey = [_]u8{ 0x60, 0x6B, 0x20, 0x22, 0xA9, 0x85, 0xAD, 0x8D };
    try out.print("\n  per bank — ran / seen / calls-in / data-refs / density / non-blank:\n", .{});
    var bank: u32 = 0;
    var suspect: u32 = 0;
    while (bank * 0x8000 < image.len) : (bank += 1) {
        var ran: u32 = 0;
        var a16: u32 = 0x8000;
        while (a16 < 0x10000) : (a16 += 1) {
            const cpu = (bank << 16) | a16;
            if ((ub[cpu] | ub[0x80_0000 | cpu]) & core.usage_map.flag_opcode != 0) ran += 1;
        }
        const seen = res.audit.bank_ops[bank];
        const lo = bank * 0x8000;
        const hi = @min(lo + 0x8000, image.len);
        var content: u32 = 0;
        var hits: u32 = 0;
        for (image[lo..hi]) |b| {
            content += @intFromBool(b != 0xFF and b != 0x00);
            for (codey) |c| hits += @intFromBool(b == c);
        }
        const dens: u32 = if (hi > lo) hits * 1000 / @as(u32, @intCast(hi - lo)) else 0;
        // Code-like, never entered, and nothing references it as data: the
        // only combination this report is willing to call suspicious.
        const odd = seen == 0 and content > 0x1000 and dens >= 80 and
            res.audit.bank_data[bank] == 0;
        if (odd) suspect += 1;
        try out.print("    ${x:0>2}  {d:>5} {d:>5} {d:>5} {d:>6}   .{d:0>3}  {d:>6}{s}\n", .{
            bank,                      ran,  seen,    res.audit.bank_calls[bank],
            res.audit.bank_data[bank], dens, content, if (odd) @as([]const u8, "   <-- code-like, never entered") else "",
        });
    }
    try out.print("  indirect transfers in seen code: {} JMP (abs), {} JMP/JSR (abs,X), {} JMP [abs]\n", .{
        res.audit.n_ind_abs, res.audit.n_ind_absx, res.audit.n_ind_long,
    });
    if (suspect == 0)
        try out.print("  No bank is code-like, unentered AND unreferenced as data.\n", .{})
    else
        try out.print("  {} bank(s) look like code the descent never entered — start there.\n", .{suspect});

    // --- what happened to the sites it did see -------------------------
    const rows = [_]struct { v: V, label: []const u8 }{
        .{ .v = .shifted, .label = "moved into the window (+$6000)" },
        .{ .v = .rebanked, .label = "re-banked $7E/$7F -> $40/$41" },
        .{ .v = .thunk_dbr, .label = "thunked, dispatching on the data bank" },
        .{ .v = .thunk_index, .label = "thunked, dispatching on the index" },
        .{ .v = .left_high, .label = "left: operand >= $2000 (MMIO or ROM)" },
        .{ .v = .left_rom, .label = "left: measured traffic never touched low WRAM" },
        .{ .v = .left_pinned, .label = "left: data bank statically proved BW-RAM" },
        .{ .v = .left_mixed, .label = "LEFT: measured low WRAM, but not only" },
        .{ .v = .left_unproven, .label = "LEFT: no evidence, shape not provable" },
    };
    var total: u32 = 0;
    for (rows) |r| total += a.count(r.v);
    try out.print("\n  {} memory-touching site(s) decided:\n", .{total});
    for (rows) |r| {
        const n = a.count(r.v);
        if (n == 0) continue;
        try out.print("    {d:>6}  {s}\n", .{ n, r.label });
    }

    const hazards = a.count(.left_pinned) + a.count(.left_mixed) + a.count(.left_unproven);
    if (hazards == 0) {
        try out.print("\n  No site was left addressing the abandoned home on a guess.\n", .{});
        return;
    }
    try out.print(
        "\n  {} site(s) still address the pre-conversion home. Each is a bet that\n" ++
            "  the path reaching it does not want low WRAM; `--stale` is the way to\n" ++
            "  collect the ones that lose.\n\n",
        .{hazards},
    );
    for (a.sites[0..a.n_sites]) |s| {
        const b: u32 = s.file / 0x8000;
        const a16: u32 = 0x8000 + (s.file % 0x8000);
        var ev: [4]u8 = "----".*;
        if (s.ev & core.usage_map.site_wram_low != 0) ev[0] = 'L';
        if (s.ev & core.usage_map.site_rom != 0) ev[1] = 'R';
        if (s.ev & core.usage_map.site_wram_bank != 0) ev[2] = 'B';
        if (s.ev & core.usage_map.site_other != 0) ev[3] = 'O';
        try out.print("    ${x:0>2}:{x:0>4}  op ${x:0>2}  ${x:0>4}  ev {s}  {s}\n", .{
            b, a16, s.op, s.v, &ev, @tagName(s.verdict),
        });
    }
    if (a.truncated != 0)
        try out.print("    ... and {} more (list capped)\n", .{a.truncated});
}

fn printCoverage(out: *std.Io.Writer, total_ops: u32, late_ops: u32, frames: u32) !void {
    const late_pct = @as(f64, @floatFromInt(late_ops)) * 100 /
        @as(f64, @floatFromInt(@max(1, total_ops)));
    try out.print("  coverage: {} instruction(s) seen executing; {} of them ({d:.1}%) first\n" ++
        "  appeared in the last tenth of {} frames", .{ total_ops, late_ops, late_pct, frames });
    // A handful of stragglers is normal — a rare branch, a one-off path.
    // The signal worth acting on is a capture that was still finding code
    // at a real rate when it ended, because then whatever the rewriter
    // did, it did on evidence that had not settled.
    if (late_pct >= coverage_unsettled_pct) {
        try out.print(" — the profile had NOT settled, so\n" ++
            "  this rests on partial evidence. Extend --frames, or drive a real playthrough\n" ++
            "  with --movie.\n", .{});
    } else {
        try out.print(": effectively settled.\n", .{});
    }
}

/// Late-discovery share above which a capture counts as unsettled. Below
/// it, the stragglers are rare branches rather than unexplored game.
const coverage_unsettled_pct: f64 = 1.0;

/// `--sa1-report`: run the game with the frame-budget profiler and report
/// whether it is CPU-bound.
///
/// Without `--movie` nothing presses any buttons, so what gets profiled is
/// whatever the game does on its own — the attract/demo loop for most carts, a
/// title screen for the rest. That is a real limitation and the report says so,
/// because a title screen idling at 8% utilisation is not evidence of anything.
/// A recorded playthrough is the way out: it replays real input from power-on
/// and verifies it stayed in sync, so the profile describes gameplay.
/// The SA-1 game-loop offload census (profile.Census): how much of the
/// frame the main loop's own work is — the share an offload can take off
/// the S-CPU — against the interrupt handlers' share, and every hardware
/// register the main loop touches, which is what the S-CPU would have to
/// keep doing on the SA-1's behalf.
fn printOffloadCensus(out: *std.Io.Writer, samples: []const profile.FrameSample, census: *const profile.Census, prof: *const profile.Profiler) !void {
    if (samples.len == 0) return;
    var int_sum: f64 = 0;
    var main_sum: f64 = 0;
    var idle_sum: f64 = 0;
    var main_max: f64 = 0;
    var int_max: f64 = 0;
    var over_alone: usize = 0; // frames the main loop's work alone would overrun
    var over_lag: usize = 0; // lag frames where the main loop, not the handler, is the bulk
    var lag_frames: usize = 0;
    var budget: f64 = 0;
    for (samples) |smp| {
        const tot: f64 = @floatFromInt(smp.work + smp.idle);
        if (tot == 0) continue;
        if (budget == 0 or tot < budget) budget = tot; // one frame's cycles (a lag frame spans more)
        const iw: f64 = @floatFromInt(smp.int_work);
        const mw: f64 = @floatFromInt(smp.main_work);
        int_sum += iw / tot;
        main_sum += mw / tot;
        idle_sum += @as(f64, @floatFromInt(smp.idle)) / tot;
        if (mw / tot > main_max) main_max = mw / tot;
        if (iw / tot > int_max) int_max = iw / tot;
        if (smp.lag) {
            lag_frames += 1;
            if (mw > iw) over_lag += 1;
        }
    }
    for (samples) |smp| if (budget != 0 and @as(f64, @floatFromInt(smp.main_work)) > budget * 0.9) {
        over_alone += 1;
    };
    const n: f64 = @floatFromInt(samples.len);
    try out.print("\n  SA-1 offload census (main loop vs interrupt handlers)\n", .{});
    try out.print("    frame time        main-loop work {d:.0}% (max {d:.0}%)   NMI/IRQ work {d:.0}% (max {d:.0}%)   idle {d:.0}%\n", .{
        main_sum / n * 100, main_max * 100, int_sum / n * 100, int_max * 100, idle_sum / n * 100,
    });
    try out.print("    lag frames        {} — in {} of them the main loop, not the handler, is the larger share\n", .{ lag_frames, over_lag });
    try out.print("    main loop > 90% of a frame by itself: {} frame(s)\n", .{over_alone});
    // Register census, per context.
    const names = [_][]const u8{ "main loop", "interrupt handlers" };
    for (0..2) |c| {
        var total: u64 = 0;
        var by_class: [7]u64 = @splat(0);
        var distinct: usize = 0;
        for (census.count[c], 0..) |cnt, b| {
            if (cnt == 0) continue;
            total += cnt;
            distinct += 1;
            by_class[@intFromEnum(profile.Census.classOf(profile.Census.regOf(b)))] += cnt;
        }
        try out.print("    {s}: {d:.1} register touches per frame over {} distinct register(s) — ppu {d:.1}  apu {d:.1}  wram-port {d:.1}  dma {d:.1}  cpu {d:.1}  joypad {d:.1}  mul/div {d:.1}\n", .{
            names[c],
            @as(f64, @floatFromInt(total)) / n,
            distinct,
            @as(f64, @floatFromInt(by_class[0])) / n,
            @as(f64, @floatFromInt(by_class[1])) / n,
            @as(f64, @floatFromInt(by_class[2])) / n,
            @as(f64, @floatFromInt(by_class[3])) / n,
            @as(f64, @floatFromInt(by_class[4])) / n,
            @as(f64, @floatFromInt(by_class[5])) / n,
            @as(f64, @floatFromInt(by_class[6])) / n,
        });
        // The heaviest registers, with the sites that touch them.
        var shown: usize = 0;
        var used: [profile.Census.buckets]bool = @splat(false);
        while (shown < 20) : (shown += 1) {
            var best: ?usize = null;
            for (census.count[c], 0..) |cnt, b| {
                if (cnt == 0 or used[b]) continue;
                if (best == null or cnt > census.count[c][best.?]) best = b;
            }
            const b = best orelse break;
            used[b] = true;
            const reg = profile.Census.regOf(b);
            try out.print("      ${X:0>4} {s:<9} {d:>9.2}/frame  from", .{ reg, @tagName(profile.Census.classOf(reg)), @as(f64, @floatFromInt(census.count[c][b])) / n });
            for (census.pcs[c][b][0..census.n_pcs[c][b]]) |q| try out.print(" ${X:0>2}:{X:0>4}", .{ q >> 16, q & 0xFFFF });
            if (census.n_pcs[c][b] == profile.Census.pcs_cap) try out.print(" ...", .{});
            try out.print("\n", .{});
        }
    }

    // --- what the mainloop split would need, from the census -----------
    // IO routines: every main-loop routine that touches the APU, the
    // PPU, the WRAM port or the DMA unit. Deferred (`:d`) when any of
    // its touches are READS — a handshake spins forever on the SA-1's
    // open bus; RTL-shaped (`:l`) when it was JSL-called. Mirror ranges:
    // the main-loop sites reading $4212 or the joypad, a window each.
    var ents: [64]u24 = undefined;
    var ent_read: [64]bool = undefined;
    var n_ents: usize = 0;
    for (census.count[0], 0..) |cnt, b| {
        if (cnt == 0) continue;
        const cls = profile.Census.classOf(profile.Census.regOf(b));
        if (cls == .math or cls == .cpu or cls == .joypad) continue;
        const is_read = census.writes[0][b] < cnt;
        for (census.entries[0][b][0..census.n_pcs[0][b]]) |e| {
            if (e == 0) continue;
            var k: usize = 0;
            while (k < n_ents and ents[k] != e) : (k += 1) {}
            if (k == n_ents) {
                if (n_ents == ents.len) break;
                ents[n_ents] = e;
                ent_read[n_ents] = false;
                n_ents += 1;
            }
            if (is_read) ent_read[k] = true;
        }
    }
    if (n_ents != 0) {
        try out.print("    split IO routines (main-loop routines touching hardware; :d = has reads, :l = JSL-called):\n", .{});
        for (ents[0..n_ents], 0..) |e, k| {
            const rtl = if (prof.routineInfo(e)) |r| r.rtl_calls * 2 > r.calls else false;
            // Deferred when the routine READS hardware (a handshake) or WRITES
            // WRAM (a body run on both CPUs would advance that state twice).
            const wram_w = if (prof.routineInfo(e)) |r| r.writes_wram else false;
            try out.print("      --wg-split-io {X:0>6}{s}{s}", .{ e, if (ent_read[k] or wram_w) ":d" else "", if (rtl) ":l" else "" });
            if (prof.routineInfo(e)) |r| {
                try out.print("   ({} calls, regs", .{r.calls});
                for (r.mmio_regs[0..r.n_mmio_regs]) |reg| try out.print(" ${X:0>4}", .{reg});
                try out.print(")", .{});
            }
            try out.print("\n", .{});
        }
    }
    var n_vbl: usize = 0;
    var vbl_seen: [32]u24 = undefined;
    for (census.count[0], 0..) |cnt, b| {
        if (cnt == 0) continue;
        const reg = profile.Census.regOf(b);
        if (reg != 0x4212 and !(reg >= 0x4218 and reg <= 0x421F)) continue;
        for (census.pcs[0][b][0..census.n_pcs[0][b]]) |pc| {
            const win: u24 = pc & 0xFFFFC0;
            var dup = false;
            for (vbl_seen[0..n_vbl]) |v| if (v == win) {
                dup = true;
            };
            if (dup or n_vbl == vbl_seen.len) continue;
            vbl_seen[n_vbl] = win;
            n_vbl += 1;
            if (n_vbl == 1) try out.print("    split mirror ranges (main-loop $4212 / joypad readers, a 64-byte window each — widen to the routine):\n", .{});
            try out.print("      --wg-split-vbl {X:0>6}-{X:0>6}\n", .{ win, win + 0x40 });
        }
    }
}

fn runReport(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    args: Args,
    cart: core.Cartridge,
    mov: ?util.movie.Movie,
) !void {
    const want = args.frames orelse if (mov != null)
        @max(1, @as(u32, @intCast(util.movie.Feed.budget(mov))) -| args.skip)
    else
        report_frames_default;

    const con = try gpa.create(core.ProfilingConsole);
    con.init(cart);
    if (args.auto_fastrom) con.bus.enableAutoFastrom();
    if (args.state) |spath| try loadStateInto(io, gpa, out, con, spath);
    try applyStartSave(io, gpa, con, args, mov, out);
    try anchorMovie(con, mov, "movie", out);

    // Coverage wants the boot code too, so the map is attached before the
    // skipped frames run, not after.
    var umap: core.usage_map.UsageMap = undefined;
    if (args.usage_map_out != null or args.call_graph_out != null) {
        const bytes = try gpa.alloc(u8, core.usage_map.cpu_map_len);
        @memset(bytes, 0);
        umap = .{ .bytes = bytes };
        con.usage = &umap;
    }

    var samples: std.array_list.Managed(profile.FrameSample) = .init(gpa);
    try samples.ensureTotalCapacity(want);
    con.prof.census_on = true;

    var drain: [4096]i16 = undefined;
    var feed: util.movie.Feed = .init(mov);
    for (0..args.skip + want) |i| {
        feed.step(con, i);
        con.runFrame();
        while (con.readAudio(&drain) != 0) {} // keep the ring from backing up
        const s = con.takeProfile() orelse continue;
        if (i >= args.skip) samples.appendAssumeCapacity(s);
    }

    if (args.call_graph_out) |path| {
        var seeds: std.array_list.Managed(u24) = .init(gpa);
        defer seeds.deinit();
        for (&con.prof.routines) |*r| {
            if (r.entry == profile.Routine.empty) continue;
            try seeds.append(@intCast(r.entry & 0xFF_FFFF));
        }
        var g = try core.callgraph.analyze(gpa, cart.rom, umap.bytes, seeds.items);
        defer g.deinit();

        // Ranked by complexity: the routines whose bodies branch the most are
        // where the frame goes and where a verbatim copy is hardest to prove.
        const by_cx = try gpa.dupe(core.callgraph.Node, g.nodes);
        defer gpa.free(by_cx);
        std.mem.sort(core.callgraph.Node, by_cx, {}, struct {
            fn lt(_: void, x: core.callgraph.Node, y: core.callgraph.Node) bool {
                return x.complexity() > y.complexity();
            }
        }.lt);
        try out.print("\n  call graph: {d} routine(s), {d} edge(s), {d} unresolved dispatch site(s)\n", .{ g.nodes.len, g.edges.len, g.unresolved });
        try out.print("    entry     bytes  cx  callers  calls  indirect\n", .{});
        var shown: usize = 0;
        for (by_cx) |n| {
            if (n.instrs == 0) continue;
            if (shown == 16) break;
            shown += 1;
            try out.print("    ${x:0>6}  {d:>6}  {d:>3}  {d:>7}  {d:>5}  {d:>8}\n", .{ n.entry, n.bytes, n.complexity(), n.callers, n.calls_out, n.indirect });
        }
        // Every routine, tab-separated, for whatever wants to sort it.
        var tsv: std.array_list.Managed(u8) = .init(gpa);
        defer tsv.deinit();
        try tsv.appendSlice("entry\tbytes\tinstrs\tcomplexity\tcallers\tcalls_out\tindirect\n");
        for (g.nodes) |n| {
            if (n.instrs == 0) continue;
            const line = try std.fmt.allocPrint(gpa, "{x:0>6}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
                n.entry, n.bytes, n.instrs, n.complexity(), n.callers, n.calls_out, n.indirect,
            });
            defer gpa.free(line);
            try tsv.appendSlice(line);
        }
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = tsv.items }) catch {
            try out.print("error: cannot write '{s}'\n", .{path});
            try out.flush();
            std.process.exit(1);
        };
        try out.print("  wrote {s}\n", .{path});
        try out.flush();
    }

    if (args.usage_map_out) |path| {
        writeUsageMap(io, path, umap.bytes, con.cart.chip) catch {
            try out.print("error: cannot write '{s}'\n", .{path});
            try out.flush();
            std.process.exit(1);
        };
        const extra: usize = switch (con.cart.chip) {
            .sa1 => 1 << 24,
            .superfx => 1 << 23,
            else => 0,
        };
        try out.print(
            "wrote {s} ({d:.1} MiB — S-CPU block recorded, SMP{s} zero-filled; " ++
                "bsnes-plus -usage.bin layout, DiztinGUIsh-importable)\n",
            .{
                path,
                @as(f64, @floatFromInt(core.usage_map.cpu_map_len + core.usage_map.smp_map_len + extra)) / (1024 * 1024),
                switch (con.cart.chip) {
                    .sa1 => " and SA-1 blocks",
                    .superfx => " and Super FX blocks",
                    else => " block",
                },
            },
        );
    }

    const scratch = try gpa.alloc(f64, samples.items.len);
    const sum = profile.summarise(samples.items, scratch);

    const h = &con.cart.header;
    const chip = @tagName(con.cart.chip);
    const map = @tagName(h.mapping);
    const title = std.mem.trim(u8, &h.title, " \x00");

    if (args.json) {
        try out.print(
            // `std.json.fmt` emits the surrounding quotes itself.
            "{{\"rom\":{f},\"title\":{f},\"map\":\"{s}\",\"chip\":\"{s}\"," ++
                "\"fastrom\":{},\"frames\":{}," ++
                "\"slow_frames\":{},\"slow_ratio\":{d:.4}," ++
                "\"stall_frames\":{},\"stalls\":{}," ++
                "\"longest_stall\":{},\"longest_stall_at\":{}," ++
                "\"mean_util\":{d:.4},\"median_util\":{d:.4},\"p95_util\":{d:.4}," ++
                "\"max_util\":{d:.4},\"verdict\":\"{s}\"",
            .{
                std.json.fmt(args.rom, .{}), std.json.fmt(title, .{}),
                map,                         chip,
                h.fastRom(),                 sum.frames,
                sum.slow_frames,             sum.slowRatio(),
                sum.stall_frames,            sum.stalls,
                sum.longest_stall,           sum.longest_stall_at,
                sum.mean_util,               sum.median_util,
                sum.p95_util,                sum.max_util,
                @tagName(sum.verdict),
            },
        );
        {
            const c = profile.assessConversion(&con.prof, sum.verdict);
            try out.print(
                ",\"conversion\":{{\"warranted\":{},\"concentrated\":{},\"covered\":{d:.4}," ++
                    "\"slow_work\":{},\"main_share\":{d:.4},\"wram_min\":{},\"wram_max\":{}," ++
                    "\"wram_exact\":{},\"pages\":{},\"fits_iram\":{},\"fits_bwram\":{}," ++
                    "\"shared_pages\":{},\"mmio\":{},\"wram_dma\":{},\"entries\":[",
                .{
                    c.warranted,      c.concentrated, c.covered,
                    c.slow_work,      c.main_share,   c.wram.min_bytes,
                    c.wram.max_bytes, c.wram.exact,   c.pages,
                    c.fits_iram,      c.fits_bwram,   c.shared_pages,
                    c.mmio_regs,      c.wram_dma,
                },
            );
            for (c.entries[0..c.n], 0..) |e, i| {
                if (i != 0) try out.print(",", .{});
                try out.print("\"{x:0>2}:{x:0>4}\"", .{ e >> 16, e & 0xFFFF });
            }
            try out.print("]}}", .{});
            if (args.plan) {
                const plan = profile.planRelocation(&con.prof, c);
                try out.print(",\"plan\":{{\"viable\":{},\"iram_used\":{},\"bwram_used\":{}," ++
                    "\"has_dp\":{},\"overflow\":{},\"regions\":[", .{
                    plan.viable, plan.iram_used,       plan.bwram_used,
                    plan.has_dp, plan.region_overflow,
                });
                for (plan.regions[0..plan.n], 0..) |r, ri| {
                    if (ri != 0) try out.print(",", .{});
                    try out.print(
                        "{{\"start\":{},\"len\":{},\"exact\":{},\"heat\":{},\"dest\":\"{s}\"," ++
                            "\"dest_off\":{},\"dp\":{},\"shared\":{},\"dma_fed\":{}}}",
                        .{
                            r.start, r.len,            r.exact,
                            r.heat,  @tagName(r.dest), r.dest_off,
                            r.dp,    r.shared_outside, r.dma_fed,
                        },
                    );
                }
                try out.print("]}}", .{});
            }
        }
        if (args.routines) {
            const rows = try routineRows(gpa, &con.prof);
            const total = attributedTotal(rows);
            const verdict = wramVerdict(topCodeRows(rows));
            try out.print(",\"stack_resets\":{},\"routines_dropped\":{},\"wram_verdict\":" ++
                "{{\"bytes\":{},\"pages\":{},\"fits_iram\":{},\"fits_bwram\":{}}},\"main_dma\":[", .{
                con.prof.stack_resets, con.prof.routines_dropped,
                verdict.union_bytes,   verdict.union_pages,
                verdict.fits_iram,     verdict.fits_bwram,
            });
            for (con.prof.main_dma[0..con.prof.n_main_dma], 0..) |d, di| {
                if (di != 0) try out.print(",", .{});
                try printDmaUseJson(out, d);
            }
            try out.print("],\"routines\":[", .{});
            for (rows, 0..) |r, i| {
                if (i != 0) try out.print(",", .{});
                switch (r.what) {
                    .waiting => try out.print("{{\"entry\":\"(waiting)\"", .{}),
                    .main => try out.print("{{\"entry\":\"(main)\"", .{}),
                    .code => {
                        try out.print("{{\"entry\":\"{x:0>2}:{x:0>4}\",\"kind\":\"{s}\",\"calls\":{},\"incl\":{}", .{
                            r.entry >> 16, r.entry & 0xFFFF, @tagName(r.kind), r.calls, r.incl,
                        });
                        try out.print(
                            ",\"wram_min\":{},\"wram_max\":{},\"wram_exact\":{},\"touches_sram\":{},\"shared\":{},\"mmio\":[",
                            .{ r.wram.min_bytes, r.wram.max_bytes, r.wram.exact, r.touches_sram, wramShared(rows, i) },
                        );
                        for (r.mmio_regs, 0..) |reg, mi| {
                            if (mi != 0) try out.print(",", .{});
                            try out.print("\"${x:0>4}\"", .{reg});
                        }
                        try out.print("],\"dma\":[", .{});
                        for (r.dma, 0..) |d, di| {
                            if (di != 0) try out.print(",", .{});
                            try printDmaUseJson(out, d);
                        }
                        try out.print("]", .{});
                    },
                }
                try out.print(",\"self\":{},\"self_pct\":{d:.4},\"slow\":{}}}", .{
                    r.self, pct(r.self, total), r.slow,
                });
            }
            try out.print("]", .{});
        }
        try out.print("}}\n", .{});
        try out.flush();
        return;
    }

    const seconds = @as(f64, @floatFromInt(sum.frames)) / 60.0;
    try out.print("{s}\n", .{title});
    try out.print("  {s}, {s}, {s}\n", .{
        map,
        if (con.cart.chip == .none) "no coprocessor" else chip,
        if (h.fastRom()) "FastROM" else "SlowROM",
    });
    try out.print("  profiled {} frames ({d:.0}s) after {} boot frames\n\n", .{
        sum.frames, seconds, args.skip,
    });

    try out.print("  CPU utilisation   mean {d:.0}%   median {d:.0}%   p95 {d:.0}%   max {d:.0}%\n", .{
        sum.mean_util * 100, sum.median_util * 100, sum.p95_util * 100, sum.max_util * 100,
    });
    try out.print("  slowdown          {} of {} frames ({d:.1}%)\n", .{
        sum.slow_frames, sum.frames, sum.slowRatio() * 100,
    });
    if (sum.n_slow_runs > 0) {
        try out.print("    at frame(s):", .{});
        for (sum.slow_runs[0..sum.n_slow_runs]) |r| try out.print(" {}(x{})", .{ r.start, r.len });
        try out.print("\n", .{});
    }
    if (sum.stalls > 0) {
        try out.print("  stalls            {} ({} frames) — loads or transitions, not slowdown\n", .{
            sum.stalls, sum.stall_frames,
        });
        try out.print("  longest           {} frames, from frame {}\n", .{
            sum.longest_stall, sum.longest_stall_at,
        });
    }

    try printOffloadCensus(out, samples.items, &con.prof.census, &con.prof);

    try out.print("\n  verdict: {s}\n", .{sum.verdict.describe()});
    switch (sum.verdict) {
        .not_cpu_bound => try out.print(
            \\    The CPU idles through {d:.0}% of an average frame and never falls behind.
            \\    A faster CPU has nothing to do here.
            \\
        , .{(1 - sum.mean_util) * 100}),
        .at_the_limit => try out.print(
            \\    Never falls behind, but its 95th-percentile frame is {d:.0}% busy: there is
            \\    nothing left over. Not slow today; the first thing that would break if
            \\    anything were added to it.
            \\
        , .{sum.p95_util * 100}),
        .drops_frames => try out.print(
            \\    Loses {d:.1}% of its frames to slowdown — occasional, not constant.
            \\    Worth finding out where before drawing any conclusion.
            \\
        , .{sum.slowRatio() * 100}),
        .saturated => try out.print(
            \\    Its MEDIAN frame is {d:.0}% busy, yet it loses only {d:.1}% of its frames to
            \\    slowdown: this game is not trying to hit 60. It renders on its own slower
            \\    schedule, so it cannot miss a deadline it never set — which is why a
            \\    dropped-frame count understates it. A faster CPU would not remove
            \\    slowdown here; it would raise the frame rate.
            \\
        , .{ sum.median_util * 100, sum.slowRatio() * 100 }),
        .cpu_bound => try out.print(
            \\    Loses {d:.1}% of its frames to slowdown, spread through the capture rather
            \\    than bunched into loads. This is a game genuinely short of CPU, and the
            \\    kind a conversion exists for.
            \\
        , .{sum.slowRatio() * 100}),
        .no_signal => try out.print(
            \\    The game never read the controller — not in one of {} frames. It has not
            \\    finished booting, or it is sitting on something that does not poll, or it
            \\    has hung. Every frame looks dropped and none of them mean anything, so
            \\    there is no verdict to give. Try a longer --skip.
            \\
        , .{sum.frames}),
    }

    const conv = profile.assessConversion(&con.prof, sum.verdict);
    try printConversion(out, conv);
    if (args.plan) try printPlan(out, profile.planRelocation(&con.prof, conv));

    if (args.hot) {
        // Where every cycle went, loop or not.
        const Page = struct { pc: u32, cycles: u64 };
        var pages: std.array_list.Managed(Page) = .init(gpa);
        for (con.prof.pages, 0..) |c, i| {
            if (c != 0) try pages.append(.{ .pc = @intCast(i << 8), .cycles = c });
        }
        std.mem.sort(Page, pages.items, {}, struct {
            fn gt(_: void, a: Page, b: Page) bool {
                return a.cycles > b.cycles;
            }
        }.gt);
        var total: u64 = 0;
        for (pages.items) |e| total += e.cycles;
        try out.print("\n  hottest 256-byte pages ({} distinct, {} cycles total)\n", .{ pages.items.len, total });
        for (pages.items[0..@min(12, pages.items.len)]) |e| {
            try out.print("     ${x:0>6}   {d:>14}  {d:>5.1}%\n", .{
                e.pc, e.cycles, @as(f64, @floatFromInt(e.cycles)) * 100 / @as(f64, @floatFromInt(total)),
            });
        }

        var hot: [profile.hot_slots]profile.Hot = con.prof.hot;
        std.mem.sort(profile.Hot, &hot, {}, struct {
            fn gt(_: void, a: profile.Hot, b: profile.Hot) bool {
                return a.cycles > b.cycles;
            }
        }.gt);
        try out.print("\n  hottest loops (>= {} revisits)\n", .{profile.min_iters});
        try out.print("     {s:<10} {s:>14} {s:>13} {s:>10}  {s}\n", .{ "pc", "cycles", "instructions", "entries", "counted as" });
        for (hot[0..@min(12, hot.len)]) |e| {
            if (e.pc == profile.Hot.empty or e.cycles == 0) break;
            try out.print("     ${x:0>6}   {d:>14} {d:>13} {d:>10}  {s}\n", .{
                e.pc, e.cycles, e.iters, e.hits, if (e.idle) "idle" else "WORK",
            });
        }
    }

    if (args.routines) {
        // Step two: where the frame goes, routine by routine. "(waiting)" is
        // every cycle the wait classifier called idle — kept out of the code
        // rows so the ranking shows work, which is what a conversion moves.
        // "(main)" is code running under no call frame at all.
        const rows = try routineRows(gpa, &con.prof);
        const total = attributedTotal(rows);
        var shown: usize = 0;
        for (rows) |r| shown += @intFromBool(r.what == .code);
        try out.print("\n  routines ({} named; showing the top {} by self time)\n", .{
            shown, @min(rows.len, routine_rows_shown),
        });
        try out.print("     {s:<10} {s:>9} {s:>14} {s:>7} {s:>7} {s:>7}  {s}\n", .{
            "entry", "calls", "self cycles", "self%", "incl%", "slow%", "",
        });
        for (rows[0..@min(rows.len, routine_rows_shown)], 0..) |r, i| {
            switch (r.what) {
                .waiting => try out.print("     {s:<10} {s:>9} {d:>14} {d:>6.1}% {s:>7} {d:>6.1}%\n", .{
                    "(waiting)", "-", r.self, pct(r.self, total), "-", pct(r.slow, r.self),
                }),
                .main => {
                    try out.print("     {s:<10} {s:>9} {d:>14} {d:>6.1}% {s:>7} {d:>6.1}%\n", .{
                        "(main)", "-", r.self, pct(r.self, total), "-", pct(r.slow, r.self),
                    });
                    for (con.prof.main_dma[0..con.prof.n_main_dma]) |d| {
                        try out.print("                dma  ", .{});
                        try printDmaUse(out, d);
                        try out.print("\n", .{});
                    }
                },
                .code => {
                    try out.print("     ${x:0>2}:{x:0>4}   {d:>9} {d:>14} {d:>6.1}% {d:>6.1}% {d:>6.1}%  {s}\n", .{
                        r.entry >> 16,       r.entry & 0xFFFF,
                        r.calls,             r.self,
                        pct(r.self, total),  pct(r.incl, total),
                        pct(r.slow, r.self), if (r.kind == .code) "" else @tagName(r.kind),
                    });
                    // Step three: what it would cost to move — its WRAM
                    // footprint (must relocate), MMIO it cannot reach from
                    // the SA-1, and whether another top routine shares its
                    // WRAM (moving one would strand the other).
                    try out.print("                wram ", .{});
                    try printWramFootprint(out, r.wram);
                    if (r.touches_sram) try out.print("  bw-ram/sram", .{});
                    if (wramShared(rows, i)) try out.print("  SHARED", .{});
                    if (r.mmio_regs.len > 0) {
                        try out.print("  mmio", .{});
                        for (r.mmio_regs, 0..) |reg, mi| {
                            if (mi == 6) {
                                try out.print(" +{} more", .{r.mmio_regs.len - mi});
                                break;
                            }
                            try out.print(" ${x:0>4}", .{reg});
                        }
                    }
                    try out.print("\n", .{});
                    // The DMA it arms: a WRAM-sourced transfer is a blocker —
                    // relocate the state and the transfer ships garbage
                    // unless it is re-sourced or proxied.
                    for (r.dma) |d| {
                        try out.print("                dma  ", .{});
                        try printDmaUse(out, d);
                        try out.print("\n", .{});
                    }
                    if (r.dma_overflow)
                        try out.print("                dma  (more channel uses than the {} tracked)\n", .{profile.dma_use_cap});
                },
            }
        }
        if (con.prof.stack_resets != 0 or con.prof.routines_dropped != 0) {
            try out.print("     ({} stack resets; {} cycles in dropped routines)\n", .{
                con.prof.stack_resets, con.prof.routines_dropped,
            });
        }
        if (!con.prof.attributionBalanced()) {
            try out.print("     WARNING: attribution imbalance — the table does not sum to work+idle (bug)\n", .{});
        }

        const verdict = wramVerdict(topCodeRows(rows));
        try out.print("\n  WRAM working set of the top routines: ", .{});
        if (verdict.union_pages == 0) {
            try out.print("none recorded (no WRAM access seen in the top routines)\n", .{});
        } else {
            try printByteCount(out, verdict.union_bytes);
            try out.print(" across {} page(s) of {} — ", .{ verdict.union_pages, profile.wram_page_count });
            if (verdict.fits_iram) {
                try out.print("fits I-RAM (2 KiB): a conversion has somewhere to put it.\n", .{});
            } else if (verdict.fits_bwram) {
                try out.print("too big for I-RAM (2 KiB) but fits cartridge BW-RAM (256 KiB).\n", .{});
            } else {
                try out.print("exceeds even BW-RAM (256 KiB) — would not fit as a straight port.\n", .{});
            }
            try out.print(
                \\    (page-granularity upper bound: a touched 256-byte page counts as fully
                \\    used even if only one byte of it is. SHARED above names the blocker —
                \\    moving that routine strands whichever other one shares its page.)
                \\
            , .{});
        }
    }

    // Everything a reader could over-trust, said out loud. What drove the run
    // is the first thing a reader needs, because every number below is a
    // number *about that run* — a demo loop, a chosen moment, and a recorded
    // playthrough are three different games as far as the frame budget cares.
    if (args.n_movies != 0) {
        try out.print(
            \\
            \\  Replayed {s} — real recorded input, so this is gameplay rather than a demo.
            \\
        , .{args.movies[0]});
    } else {
        try out.print(
            \\
            \\  Measured from the game's own attract/demo loop — no buttons were pressed.
            \\
        , .{});
    }
    try out.print(
        \\  Idle is WAI plus loops that change nothing, so a wait this misses reads as
        \\  work: utilisation is an UPPER bound. A game that polls the pad in its NMI
        \\  handler never registers a dropped frame at all, so slowdown is a LOWER
        \\  bound. The two errors bracket the truth; they do not compound.
        \\
    , .{});
    try out.flush();
}

var routine_rows_shown: usize = 16;

/// Write a usage map in bsnes-plus's `-usage.bin` layout: the CPU block
/// verbatim, then a zero-filled SMP block, then a zero-filled coprocessor
/// block when the cart carries one (SA-1: 16 MiB, Super FX: 8 MiB) — so the
/// byte layout matches what bsnes-plus writes for the same cart and existing
/// importers need no special-casing.
fn writeUsageMap(io: std.Io, path: []const u8, cpu: []const u8, chip: core.cartridge.ChipKind) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    const wr = &fw.interface;

    try wr.writeAll(cpu);
    const zeros: [4096]u8 = @splat(0);
    var left: usize = core.usage_map.smp_map_len + @as(usize, switch (chip) {
        .sa1 => 1 << 24,
        .superfx => 1 << 23,
        else => 0,
    });
    while (left != 0) {
        const n = @min(left, zeros.len);
        try wr.writeAll(zeros[0..n]);
        left -= n;
    }
    try wr.flush();
}

test "usage-map file layout: block sizes per chip, CPU bytes verbatim" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const root = ".usage-map-test-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const cpu = try gpa.alloc(u8, core.usage_map.cpu_map_len);
    defer gpa.free(cpu);
    @memset(cpu, 0);
    cpu[0x00_8000] = core.usage_map.flag_opcode | core.usage_map.flag_exec;
    cpu[0xFF_FFFF] = core.usage_map.flag_read;

    // A plain cart: CPU + SMP blocks only.
    try writeUsageMap(io, root ++ "/plain-usage.bin", cpu, .none);
    const plain = try std.Io.Dir.cwd().readFileAlloc(io, root ++ "/plain-usage.bin", gpa, .limited(64 << 20));
    defer gpa.free(plain);
    try std.testing.expectEqual(core.usage_map.cpu_map_len + core.usage_map.smp_map_len, plain.len);
    try std.testing.expectEqual(cpu[0x00_8000], plain[0x00_8000]);
    try std.testing.expectEqual(cpu[0xFF_FFFF], plain[0xFF_FFFF]);
    try std.testing.expectEqual(@as(u8, 0), plain[core.usage_map.cpu_map_len]); // SMP zeros

    // A Super FX cart appends its (zero) 8 MiB block.
    try writeUsageMap(io, root ++ "/sfx-usage.bin", cpu, .superfx);
    const st = try std.Io.Dir.cwd().statFile(io, root ++ "/sfx-usage.bin", .{});
    try std.testing.expectEqual(
        @as(u64, core.usage_map.cpu_map_len + core.usage_map.smp_map_len + (1 << 23)),
        st.size,
    );
}

/// Stage S2: the relocation plan — where each region of the hot set's WRAM
/// state lands on the SA-1 side, and what each move costs.
fn printPlan(out: *std.Io.Writer, plan: core.profile.Plan) !void {
    if (!plan.viable) {
        try out.print("\n  relocation plan: none — the conversion verdict above gave the planner no hot set.\n", .{});
        return;
    }
    var total_heat: u64 = 0;
    for (plan.regions[0..plan.n]) |r| total_heat += r.heat;

    try out.print("\n  relocation plan (stage S2): {} region(s), I-RAM {}/{} bytes, BW-RAM ", .{
        plan.n, plan.iram_used, core.profile.iram_bytes,
    });
    try printByteCount(out, plan.bwram_used);
    if (plan.has_dp) try out.print("; SA-1 boots with D=$3000 (dp window in I-RAM)", .{});
    try out.print("\n", .{});
    try out.print("     {s:<16} {s:>6}  {s:<16} {s:>5}  {s}\n", .{ "wram", "size", "dest", "heat", "" });
    for (plan.regions[0..plan.n]) |r| {
        const bank: u32 = 0x7E + (r.start >> 16);
        const lo: u32 = r.start & 0xFFFF;
        var range_buf: [16]u8 = undefined;
        const range = if (r.len == 1)
            std.fmt.bufPrint(&range_buf, "${x:0>2}:{x:0>4}", .{ bank, lo }) catch ""
        else
            std.fmt.bufPrint(&range_buf, "${x:0>2}:{x:0>4}-{x:0>4}", .{ bank, lo, (r.start + r.len - 1) & 0xFFFF }) catch "";
        var dest_buf: [16]u8 = undefined;
        const dest = switch (r.dest) {
            .iram => std.fmt.bufPrint(&dest_buf, "I-RAM ${x:0>4}", .{0x3000 + r.dest_off}) catch "",
            .bwram => std.fmt.bufPrint(&dest_buf, "BW-RAM ${x:0>2}:{x:0>4}", .{ 0x40 + (r.dest_off >> 16), r.dest_off & 0xFFFF }) catch "",
        };
        try out.print("     {s:<16} {d:>6}  {s:<16} {d:>4.0}%  {s}{s}{s}{s}\n", .{
            range,
            r.len,
            dest,
            pct(r.heat, total_heat),
            if (r.dp) "dp " else "",
            if (r.dma_fed) "feeds-DMA " else "",
            if (r.shared_outside) "SHARED " else "",
            if (r.exact) "" else "page-bound",
        });
    }
    if (plan.region_overflow)
        try out.print("     (more regions than the {} tracked — this plan is a prefix)\n", .{core.profile.plan_region_cap});
    try out.print(
        \\    (heat is each region's share of the hot set's slow-frame work. A page-bound
        \\    row is an upper bound: the whole touched page moves. SHARED rows need the
        \\    resident side re-pointed too — I-RAM and BW-RAM are visible to both CPUs,
        \\    so sharing is rewrite work, not a refusal. feeds-DMA rows sit in BW-RAM
        \\    because a transfer's A-bus side needs a linear address.)
        \\
    , .{});
}

/// The unified `conversion:` paragraph — the report's bottom line, tying the
/// slow-frame concentration to the WRAM fit and the blockers. Graded: not
/// warranted / worth attempting (with any blockers each on their own line) /
/// warranted but diffuse.
fn printConversion(out: *std.Io.Writer, c: core.profile.Conversion) !void {
    if (!c.warranted) {
        try out.print("\n  conversion: not warranted — the game is not short of CPU (see the verdict above).\n", .{});
        return;
    }
    if (c.slow_work == 0 or c.n == 0) {
        try out.print(
            \\
            \\  conversion: warranted, but no slow-frame work was attributed to any routine
            \\  (all of it ran while waiting, or the capture was too short). Nothing to rank.
            \\
        , .{});
        return;
    }
    if (!c.concentrated) {
        try out.print(
            \\
            \\  conversion: warranted but diffuse — the top {} routine(s) cover only {d:.0}% of
            \\  the work in dropped frames
        , .{ c.n, c.covered * 100 });
        if (c.main_share >= 0.10) try out.print(
            \\, and {d:.0}% of it runs at the top level, under no
            \\  call frame
        , .{c.main_share * 100});
        try out.print(
            \\. There is no small set to move; this is a restructuring, not a
            \\  relocation.
            \\
        , .{});
        return;
    }

    try out.print("\n  conversion: {d:.0}% of the work in dropped frames lands in {} routine(s) (", .{
        c.covered * 100, c.n,
    });
    for (c.entries[0..c.n], 0..) |e, i| {
        if (i != 0) try out.print(", ", .{});
        try out.print("${x:0>2}:{x:0>4}", .{ e >> 16, e & 0xFFFF });
    }
    try out.print(")\n  whose combined WRAM working set is ", .{});
    if (c.pages == 0) {
        try out.print("empty (no WRAM access recorded)", .{});
    } else {
        try printWramFootprint(out, c.wram);
        try out.print(" across {} page(s)", .{c.pages});
    }
    if (c.fits_iram) {
        try out.print(" — fits I-RAM (2 KiB).\n", .{});
    } else if (c.fits_bwram) {
        try out.print(" — too big for I-RAM (2 KiB) but fits\n  cartridge BW-RAM (256 KiB).\n", .{});
    } else {
        try out.print(" — exceeds even BW-RAM (256 KiB); a straight\n  port cannot hold it.\n", .{});
    }

    var blockers = false;
    if (c.shared_pages != 0) {
        blockers = true;
        try out.print(
            "  BUT: {} WRAM page(s) of that set are shared with code that stays behind —\n" ++
                "  moving the set strands state both sides touch.\n",
            .{c.shared_pages},
        );
    }
    if (c.wram_dma) {
        blockers = true;
        try out.print(
            "  BUT: a DMA/HDMA the set arms is WRAM-sourced — relocate the state and the\n" ++
                "  transfer must be re-sourced or proxied.\n",
            .{},
        );
    }
    if (c.mmio_regs != 0) {
        try out.print("  It reaches {}{s} MMIO register(s) the SA-1 cannot touch — each access needs\n  an S-CPU stub.\n", .{
            c.mmio_regs, if (c.mmio_overflow) "+" else "",
        });
    }
    if (!c.fits_bwram) {
        try out.print("  Not worth attempting as a relocation at this size.\n", .{});
    } else if (blockers) {
        try out.print("  Worth attempting only with the blockers above priced in.\n", .{});
    } else {
        try out.print("  No page of it is shared with resident code and no DMA sources it. Worth\n  attempting.\n", .{});
    }
}

/// One DMA use as the routine table's detail line shows it, e.g.
/// `gdma ch1 $7E:2000 -> $2118 (4.0 KiB, 214 arms) WRAM` — the arrow shows
/// which side the A-bus address is; the WRAM tag is the blocker call-out.
fn printDmaUse(out: *std.Io.Writer, d: core.profile.DmaUse) !void {
    switch (d.kind) {
        .gdma => {
            try out.print("gdma ch{d} ${x:0>2}:{x:0>4} {s} $21{x:0>2} (", .{
                d.channel,                       d.src >> 16, d.src & 0xFFFF,
                if (d.a_is_dest) "<-" else "->", d.b_reg,
            });
            try printByteCount(out, d.bytes_max);
            try out.print(", {d} arm(s))", .{d.arms});
            if (d.src_wram) try out.print("  WRAM", .{});
        },
        .hdma => {
            try out.print("hdma ch{d} table ${x:0>2}:{x:0>4} -> $21{x:0>2} ({d} arm(s))", .{
                d.channel, d.src >> 16, d.src & 0xFFFF, d.b_reg, d.arms,
            });
            if (d.src_wram) try out.print("  WRAM TABLE", .{});
            if (d.indirect_wram) try out.print("  WRAM INDIRECT", .{});
        },
    }
}

/// The same use as a JSON object (no trailing separator).
fn printDmaUseJson(out: *std.Io.Writer, d: core.profile.DmaUse) !void {
    try out.print(
        "{{\"kind\":\"{s}\",\"ch\":{d},\"src\":\"{x:0>2}:{x:0>4}\",\"b_reg\":\"$21{x:0>2}\"," ++
            "\"bytes\":{d},\"a_is_dest\":{},\"arms\":{d},\"src_wram\":{},\"indirect_wram\":{}}}",
        .{
            @tagName(d.kind), d.channel, d.src >> 16,
            d.src & 0xFFFF,   d.b_reg,   d.bytes_max,
            d.a_is_dest,      d.arms,    d.src_wram,
            d.indirect_wram,
        },
    );
}

/// One row of the `--routines` table: a named routine, or one of the two
/// synthetic rows the attribution invariant needs — "(waiting)" (idle cycles,
/// wherever the wait lived) and "(main)" (code under no call frame).
const RoutineRow = struct {
    what: enum { code, waiting, main },
    entry: u24 = 0,
    kind: core.profile.RoutineKind = .code,
    calls: u64 = 0,
    self: u64,
    incl: u64 = 0,
    slow: u64,
    /// Step three, `.code` rows only: what its data accesses were made of.
    wram: core.profile.WramFootprint = .{ .min_bytes = 0, .max_bytes = 0, .exact = true },
    wram_pages: core.profile.WramPages = @splat(0),
    /// Slices into the profiler's own `Routine` — valid as long as `prof`
    /// (i.e. `con.prof`) outlives the report, which it does.
    mmio_regs: []const u16 = &.{},
    touches_sram: bool = false,
    /// DMA/HDMA channels this routine armed (same lifetime note).
    dma: []const core.profile.DmaUse = &.{},
    dma_overflow: bool = false,
};

/// Collect and rank every routine with self time, synthetics included.
fn routineRows(gpa: std.mem.Allocator, prof: *const core.profile.Profiler) ![]RoutineRow {
    var rows: std.array_list.Managed(RoutineRow) = .init(gpa);
    if (prof.waiting_self != 0)
        try rows.append(.{ .what = .waiting, .self = prof.waiting_self, .slow = prof.waiting_slow });
    if (prof.main_self != 0)
        try rows.append(.{ .what = .main, .self = prof.main_self, .slow = prof.main_slow });
    for (prof.routines, 0..) |r, i| {
        if (r.entry == core.profile.Routine.empty or r.self_cycles == 0) continue;
        try rows.append(.{
            .what = .code,
            .entry = @intCast(r.entry),
            .kind = r.kind,
            .calls = r.calls,
            .self = r.self_cycles,
            .incl = r.incl_cycles,
            .slow = r.slow_cycles,
            .wram = r.wramFootprint(),
            .wram_pages = r.wram_pages,
            .mmio_regs = prof.routines[i].mmio_regs[0..r.n_mmio_regs],
            .touches_sram = r.touches_sram,
            .dma = prof.routines[i].dma[0..r.n_dma],
            .dma_overflow = r.dma_overflow,
        });
    }
    std.mem.sort(RoutineRow, rows.items, {}, struct {
        fn gt(_: void, a: RoutineRow, b: RoutineRow) bool {
            return a.self > b.self;
        }
    }.gt);
    return rows.items;
}

test "routine rows carry the WRAM footprint and shared flag into the report" {
    var p: core.profile.Profiler = .init;
    const cyc: u64 = 6;
    // main -> A: touches $7E:1000.
    p.step(0x00_9000, cyc, false, null, null, .{ .kind = .call, .target = 0x00_A000, .sp_before = 0x1FF, .sp_after = 0x1FD });
    p.step(0x00_A000, cyc, false, 0x7E_1000, null, .{});
    p.step(0x00_A003, cyc, false, null, null, .{ .kind = .ret, .target = 0, .sp_before = 0x1FD, .sp_after = 0x1FF });
    // main -> B: touches $7E:1005 (same 256-byte page as A) and MMIO $4212,
    // and arms a WRAM-sourced GDMA while on top.
    p.step(0x00_9006, cyc, false, null, null, .{ .kind = .call, .target = 0x00_B000, .sp_before = 0x1FF, .sp_after = 0x1FD });
    p.step(0x00_B000, cyc, false, 0x7E_1005, null, .{});
    p.step(0x00_B003, cyc, false, 0x00_4212, null, .{});
    p.noteDmaArm(.gdma, 1, 0x7E_2000, 0x400, 0x18, false, null);
    p.step(0x00_B006, cyc, false, null, null, .{ .kind = .ret, .target = 0, .sp_before = 0x1FD, .sp_after = 0x1FF });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rows = try routineRows(arena_state.allocator(), &p);

    var a_idx: ?usize = null;
    var b_idx: ?usize = null;
    for (rows, 0..) |r, i| {
        if (r.what != .code) continue;
        if (r.entry == 0x00_A000) a_idx = i;
        if (r.entry == 0x00_B000) b_idx = i;
    }
    const a = rows[a_idx.?];
    const b = rows[b_idx.?];

    try std.testing.expect(a.wram.exact);
    try std.testing.expectEqual(@as(u32, 1), a.wram.min_bytes);
    try std.testing.expect(b.wram.exact);
    try std.testing.expectEqual(@as(u32, 1), b.wram.min_bytes);
    try std.testing.expectEqual(@as(usize, 1), b.mmio_regs.len);
    try std.testing.expectEqual(@as(u16, 0x4212), b.mmio_regs[0]);
    try std.testing.expect(!b.touches_sram);
    try std.testing.expectEqual(@as(usize, 1), b.dma.len);
    try std.testing.expect(b.dma[0].src_wram);
    try std.testing.expectEqual(@as(usize, 0), a.dma.len);

    // Same 256-byte page ($7E1000 and $7E1005): each names the other.
    try std.testing.expect(wramShared(rows, a_idx.?));
    try std.testing.expect(wramShared(rows, b_idx.?));

    const verdict = wramVerdict(topCodeRows(rows));
    try std.testing.expectEqual(@as(u32, 1), verdict.union_pages);
    try std.testing.expectEqual(@as(u32, 256), verdict.union_bytes);
    try std.testing.expect(verdict.fits_iram);
    try std.testing.expect(verdict.fits_bwram);
}

/// Sum of every row's self time == everything banked as work or idle: the
/// denominator every percentage in the table is against.
fn attributedTotal(rows: []const RoutineRow) u64 {
    var t: u64 = 0;
    for (rows) |r| t += r.self;
    return t;
}

fn pct(part: u64, whole: u64) f64 {
    if (whole == 0) return 0;
    return @as(f64, @floatFromInt(part)) * 100 / @as(f64, @floatFromInt(whole));
}

/// The `.code` rows the WRAM verdict and the report table agree on: the same
/// top `routine_rows_shown` by self time that the table prints.
fn topCodeRows(rows: []const RoutineRow) []const RoutineRow {
    return rows[0..@min(rows.len, routine_rows_shown)];
}

/// Does `rows[idx]` share a WRAM page with any *other* named routine in
/// `rows`? Moving one of them to the SA-1 would strand the other's state on
/// the wrong side of the bus. Checked against the full set, not just what is
/// displayed — a routine ranked outside the shown table can still be the
/// thing a displayed routine's WRAM is shared with.
fn wramShared(rows: []const RoutineRow, idx: usize) bool {
    if (rows[idx].what != .code) return false;
    for (rows, 0..) |other, j| {
        if (j == idx or other.what != .code) continue;
        if (core.profile.pagesOverlap(rows[idx].wram_pages, other.wram_pages)) return true;
    }
    return false;
}

/// The combined WRAM working set of a set of routines — the union of their
/// touched pages, which is what actually has to fit in I-RAM or BW-RAM once
/// they all move together. Page-granularity, so it is an upper bound: shared
/// pages are not double-counted, but a page only one byte of which is touched
/// still counts as a full 256 bytes.
const WramVerdict = struct {
    union_bytes: u32,
    union_pages: u32,
    fits_iram: bool,
    fits_bwram: bool,
};

const iram_bytes = core.profile.iram_bytes;
const bwram_bytes = core.profile.bwram_bytes;

fn wramVerdict(rows: []const RoutineRow) WramVerdict {
    var union_pages: core.profile.WramPages = @splat(0);
    for (rows) |r| {
        if (r.what != .code) continue;
        for (r.wram_pages, 0..) |w, i| union_pages[i] |= w;
    }
    const pages = core.profile.pageCount(union_pages);
    const bytes = pages * 256;
    return .{
        .union_bytes = bytes,
        .union_pages = pages,
        .fits_iram = bytes <= iram_bytes,
        .fits_bwram = bytes <= bwram_bytes,
    };
}

fn printByteCount(out: *std.Io.Writer, n: u32) !void {
    if (n >= 1024) {
        try out.print("{d:.1} KiB", .{@as(f64, @floatFromInt(n)) / 1024.0});
    } else {
        try out.print("{} B", .{n});
    }
}

fn printWramFootprint(out: *std.Io.Writer, fp: core.profile.WramFootprint) !void {
    if (fp.exact) {
        try printByteCount(out, fp.max_bytes);
    } else {
        try printByteCount(out, fp.min_bytes);
        try out.print("+ (up to ", .{});
        try printByteCount(out, fp.max_bytes);
        try out.print(")", .{});
    }
}

fn parseArgs(init: std.process.Init, gpa: std.mem.Allocator) !Args {
    // Not deinit'd — the returned Args slice into it, and `gpa` is the
    // process arena.
    // The invocation, verbatim, before anything consumes it.
    var cmd: std.array_list.Managed(u8) = .init(gpa);
    {
        var cit = try util.argIterator(init, gpa);
        var first = true;
        while (cit.next()) |a| {
            if (!first) try cmd.append(' ');
            first = false;
            const quote = std.mem.indexOfAny(u8, a, " \t\"") != null;
            if (quote) try cmd.append('"');
            try cmd.appendSlice(a);
            if (quote) try cmd.append('"');
        }
    }
    var it = try util.argIterator(init, gpa);
    var out: Args = .{ .rom = undefined, .cmdline = cmd.items };
    var rom: ?[]const u8 = null;
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--frames")) {
            const v = it.next() orelse return error.MissingValue;
            out.frames = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, a, "--skip")) {
            const v = it.next() orelse return error.MissingValue;
            out.skip = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, a, "--ppm")) {
            out.ppm = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--ppm-range")) {
            // "<start>:<count>:<prefix>"
            const v = it.next() orelse return error.MissingValue;
            var pit = std.mem.splitScalar(u8, v, ':');
            out.ppm_range_start = try std.fmt.parseInt(u32, pit.next().?, 10);
            out.ppm_range_count = try std.fmt.parseInt(u32, pit.next() orelse return error.MissingValue, 10);
            out.ppm_range_prefix = pit.next() orelse "frame";
        } else if (std.mem.eql(u8, a, "--wav")) {
            out.wav = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--accurate")) {
            out.accuracy = .accurate;
        } else if (std.mem.eql(u8, a, "--region")) {
            const v = it.next() orelse return error.MissingValue;
            out.region = std.meta.stringToEnum(RegionArg, v) orelse return error.BadRegion;
        } else if (std.mem.eql(u8, a, "--patch")) {
            out.patch = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--auto-patch")) {
            out.auto_patch = true;
        } else if (std.mem.eql(u8, a, "--auto-fastrom")) {
            out.auto_fastrom = true;
        } else if (std.mem.eql(u8, a, "--patch-dir")) {
            out.patch_dir = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--save-patched")) {
            out.save_patched = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--sa1-report")) {
            out.sa1_report = true;
        } else if (std.mem.eql(u8, a, "--json")) {
            out.json = true;
        } else if (std.mem.eql(u8, a, "--hot")) {
            out.hot = true;
        } else if (std.mem.eql(u8, a, "--routines")) {
            out.routines = true;
        } else if (std.mem.eql(u8, a, "--routines-all")) {
            // The full attribution table, for analyses that need every
            // MMIO-touching routine rather than the hot sixteen.
            out.routines = true;
            routine_rows_shown = 100000;
        } else if (std.mem.eql(u8, a, "--call-graph")) {
            out.call_graph_out = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--usage-map")) {
            out.usage_map_out = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--plan")) {
            out.plan = true;
        } else if (std.mem.eql(u8, a, "--wide")) {
            const v = it.next() orelse return error.MissingValue;
            out.wide = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, a, "--movie")) {
            const v = it.next() orelse return error.MissingValue;
            if (out.n_movies == max_movies) return error.TooManyMovies;
            out.movies[out.n_movies] = v;
            out.n_movies += 1;
        } else if (std.mem.eql(u8, a, "--evidence-movie")) {
            const v = it.next() orelse return error.MissingValue;
            if (out.n_movies == max_movies) return error.TooManyMovies;
            out.movies[out.n_movies] = v;
            out.movie_verify[out.n_movies] = false;
            out.n_movies += 1;
        } else if (std.mem.eql(u8, a, "--state")) {
            out.state = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--hash-stream")) {
            out.hash_stream = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--s2-keep")) {
            out.s2_keep = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--cheat")) {
            const v = it.next() orelse return error.MissingValue;
            out.n_pokes = util.cheat.parseCodes(v, &out.pokes, out.n_pokes) catch
                return error.BadPoke;
        } else if (std.mem.eql(u8, a, "--poke")) {
            const v = it.next() orelse return error.MissingValue;
            out.n_pokes = util.cheat.parseList(v, &out.pokes, out.n_pokes) catch
                return error.BadPoke;
        } else if (std.mem.eql(u8, a, "--dump-vram")) {
            out.dump_vram = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--dump-ppu")) {
            out.dump_ppu = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--ref-overclock")) {
            out.ref_overclock = try std.fmt.parseInt(u8, it.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, a, "--conv-overclock")) {
            out.conv_overclock = try std.fmt.parseInt(u8, it.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, a, "--lap-cell")) {
            out.lap_cell = try std.fmt.parseInt(u16, it.next() orelse return error.MissingValue, 16);
        } else if (std.mem.eql(u8, a, "--repoll")) {
            out.repoll = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--repoll-poweron")) {
            out.repoll_poweron = true;
        } else if (std.mem.eql(u8, a, "--srm")) {
            out.srm = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--movie-ignore-crc")) {
            out.movie_ignore_crc = true;
            core.console.dbg_ignore_state_rom_crc = true; // also let an anchored state cross builds

        } else if (std.mem.eql(u8, a, "--dump-ram")) {
            out.dump_ram = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--dump-srm")) {
            out.dump_srm = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--behavioral-probe")) {
            out.behavioral_probe = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--wg-sync")) {
            out.wg_sync = true;
        } else if (std.mem.eql(u8, a, "--wg-fastrom")) {
            out.wg_fastrom = true;
        } else if (std.mem.eql(u8, a, "--wg-drop")) {
            const v = it.next() orelse return error.MissingValue;
            if (out.n_wg_drop == out.wg_drop.len) return error.TooManyDrops;
            out.wg_drop[out.n_wg_drop] = try std.fmt.parseInt(u16, v, 16);
            out.n_wg_drop += 1;
        } else if (std.mem.eql(u8, a, "--wg-nmi-off")) {
            const v = it.next() orelse return error.MissingValue;
            if (out.n_wg_nmi_off == out.wg_nmi_off.len) return error.TooManyDrops;
            out.wg_nmi_off[out.n_wg_nmi_off] = try std.fmt.parseInt(u16, v, 16);
            out.n_wg_nmi_off += 1;
        } else if (std.mem.eql(u8, a, "--cover-image")) {
            if (out.n_cover == out.cover_image.len) return error.TooManyArgs;
            out.cover_image[out.n_cover] = it.next() orelse return error.MissingValue;
            out.n_cover += 1;
        } else if (std.mem.eql(u8, a, "--harvest-jobs")) {
            const v = it.next() orelse return error.MissingValue;
            out.harvest_jobs = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, a, "--harvest-render")) {
            out.harvest_render = true;
        } else if (std.mem.eql(u8, a, "--harvest-cache")) {
            out.harvest_cache = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--cover-movie")) {
            // Fills the pair the last --cover-image opened.
            if (out.n_cover == 0) return error.MissingValue;
            out.cover_movie[out.n_cover - 1] = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--clock-pc")) {
            const v = it.next() orelse return error.MissingValue;
            core.wdc65816.dbg_clock_pc = try std.fmt.parseInt(u24, v, 16);
        } else if (std.mem.eql(u8, a, "--conv-pad")) {
            const v = it.next() orelse return error.MissingValue;
            dbg_conv_pad = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, a, "--ev-only")) {
            dbg_ev_only = true;
        } else if (std.mem.eql(u8, a, "--audit")) {
            dbg_audit = true;
        } else if (std.mem.eql(u8, a, "--site-ev")) {
            const v = it.next() orelse return error.MissingValue;
            var pit = std.mem.splitScalar(u8, v, ',');
            while (pit.next()) |one| {
                if (dbg_n_site_ev == dbg_site_ev.len) break;
                dbg_site_ev[dbg_n_site_ev] = try std.fmt.parseInt(u24, one, 16);
                dbg_n_site_ev += 1;
            }
        } else if (std.mem.eql(u8, a, "--trace-clk")) {
            const v = it.next() orelse return error.MissingValue;
            var pit = std.mem.splitScalar(u8, v, '-');
            core.wdc65816.dbg_trace_from = try std.fmt.parseInt(u64, pit.next().?, 10);
            core.wdc65816.dbg_trace_to = try std.fmt.parseInt(u64, pit.next().?, 10);
        } else if (std.mem.eql(u8, a, "--trace-sa1")) {
            const v = it.next() orelse return error.MissingValue;
            core.wdc65816.dbg_trace_sa1 = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, a, "--save-state-at")) {
            // "<frame>=<path>": replay to that frame, then write the machine.
            const v = it.next() orelse return error.MissingValue;
            const eq = std.mem.indexOfScalar(u8, v, '=') orelse return error.MissingValue;
            out.save_state_at = try std.fmt.parseInt(u32, v[0..eq], 10);
            out.save_state_path = v[eq + 1 ..];
        } else if (std.mem.eql(u8, a, "--dma-bank-pc")) {
            const v = it.next() orelse return error.MissingValue;
            core.wdc65816.dbg_dmabank = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, a, "--dma-trace")) {
            const v = it.next() orelse return error.MissingValue;
            core.dma.dbg_dma = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, a, "--no-color-math")) {
            core.ppu.dbg_no_color_math = true;
        } else if (std.mem.eql(u8, a, "--bg-disable")) {
            const v = it.next() orelse return error.MissingValue;
            core.ppu.dbg_layer_disable = try std.fmt.parseInt(u8, v, 16);
        } else if (std.mem.eql(u8, a, "--hdma-disable")) {
            const v = it.next() orelse return error.MissingValue;
            core.dma.dbg_hdma_disable = try std.fmt.parseInt(u8, v, 16);
        } else if (std.mem.eql(u8, a, "--stale")) {
            // "<max-sites>" or "<max-sites>:<from-clock>"
            const v = it.next() orelse return error.MissingValue;
            var pit = std.mem.splitScalar(u8, v, ':');
            core.wdc65816.dbg_stale = try std.fmt.parseInt(usize, pit.next().?, 10);
            if (pit.next()) |f| core.wdc65816.dbg_stale_from = try std.fmt.parseInt(u64, f, 10);
        } else if (std.mem.eql(u8, a, "--iram-dump")) {
            out.iram_dump = true;
        } else if (std.mem.eql(u8, a, "--stale-ring")) {
            core.wdc65816.dbg_stale_ring = true;
        } else if (std.mem.eql(u8, a, "--watch-min")) {
            const v = it.next() orelse return error.MissingValue;
            core.wdc65816.dbg_watch_val_min = try std.fmt.parseInt(u8, v, 16);
        } else if (std.mem.eql(u8, a, "--watch-from")) {
            const v = it.next() orelse return error.MissingValue;
            core.wdc65816.dbg_watch_from = try std.fmt.parseInt(u64, v, 10);
        } else if (std.mem.eql(u8, a, "--watch")) {
            const v = it.next() orelse return error.MissingValue;
            var pit = std.mem.splitScalar(u8, v, '-');
            core.wdc65816.dbg_watch_lo = try std.fmt.parseInt(u16, pit.next().?, 16);
            core.wdc65816.dbg_watch_hi = if (pit.next()) |h| try std.fmt.parseInt(u16, h, 16) else core.wdc65816.dbg_watch_lo;
        } else if (std.mem.eql(u8, a, "--save-attempt")) {
            out.save_attempt = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--tick-dump")) {
            out.tick_dump = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--verify-behavioral")) {
            out.verify_behavioral = true;
        } else if (std.mem.eql(u8, a, "--gen-fastrom-patch")) {
            out.gen_fastrom = true;
        } else if (std.mem.eql(u8, a, "--gen-sa1-patch")) {
            out.gen_sa1 = true;
        } else if (std.mem.eql(u8, a, "--whole-game")) {
            out.whole_game = true;
        } else if (std.mem.eql(u8, a, "--window")) {
            // Window mode rides the whole-game pipeline (all-or-nothing,
            // no candidates, no plan) with execution left on the S-CPU.
            out.window = true;
            out.whole_game = true;
        } else if (std.mem.eql(u8, a, "--wg-add")) {
            const v = it.next() orelse return error.MissingValue;
            if (out.n_wg_add == out.wg_add.len) return error.TooManyAdds;
            out.wg_add[out.n_wg_add] = try std.fmt.parseInt(u24, v, 16);
            out.n_wg_add += 1;
        } else if (std.mem.eql(u8, a, "--wg-split")) {
            const v = it.next() orelse return error.MissingValue;
            out.wg_split_mainloop = try std.fmt.parseInt(u24, v, 16);
        } else if (std.mem.eql(u8, a, "--wg-split-tail")) {
            // "<tail>:<epilogue>:<dbr>" — the NMI-tail flavor.
            const v = it.next() orelse return error.MissingValue;
            var pit = std.mem.splitScalar(u8, v, ':');
            out.wg_split_tail = try std.fmt.parseInt(u16, pit.next().?, 16);
            out.wg_split_epi = try std.fmt.parseInt(u16, pit.next() orelse return error.MissingValue, 16);
            out.wg_split_dbr = try std.fmt.parseInt(u8, pit.next() orelse return error.MissingValue, 16);
        } else if (std.mem.eql(u8, a, "--split-scpu-set")) {
            out.split_scpu_set = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--wg-split-shared")) {
            const path = it.next() orelse return error.MissingValue;
            out.wg_split_shared = readScpuSet(init.io, gpa, path) catch return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--wg-split-mode")) {
            // "<cell>:<value>" (hex) — gameplay-mode gate: the tail goes
            // to the SA-1 only while dp <cell> holds <value>; menus and
            // transitions run nested-native (the stock shape).
            const v = it.next() orelse return error.MissingValue;
            var pit = std.mem.splitScalar(u8, v, ':');
            out.wg_split_mode_cell = try std.fmt.parseInt(u16, pit.next().?, 16);
            // "<cell>:<lo>[-<hi>]": a range takes the SA-1 through every mode in it
            const vals = pit.next() orelse return error.MissingValue;
            var rit = std.mem.splitScalar(u8, vals, '-');
            out.wg_split_mode_value = try std.fmt.parseInt(u8, rit.next().?, 16);
            if (rit.next()) |hi| out.wg_split_mode_hi = try std.fmt.parseInt(u8, hi, 16);
            out.wg_split_mode = true;
        } else if (std.mem.eql(u8, a, "--wg-split-io")) {
            // "<hex4>[:d][:l]" — d = deferred (handshake body, pump-only
            // post-engage), l = RTL-shaped (JSL-called).
            const v = it.next() orelse return error.MissingValue;
            if (out.n_wg_split_io == out.wg_split_io.len) return error.TooManyAdds;
            var pit = std.mem.splitScalar(u8, v, ':');
            var io: core.sa1gen.SplitIo = .{ .entry = try std.fmt.parseInt(u24, pit.next().?, 16) };
            while (pit.next()) |f| {
                if (std.mem.eql(u8, f, "d")) io.deferred = true;
                if (std.mem.eql(u8, f, "l")) io.rtl = true;
                if (std.mem.eql(u8, f, "f")) io.ff = true;
            }
            out.wg_split_io[out.n_wg_split_io] = io;
            out.n_wg_split_io += 1;
        } else if (std.mem.eql(u8, a, "--wg-split-vbl")) {
            const v = it.next() orelse return error.MissingValue;
            if (out.n_wg_split_vbl == out.wg_split_vbl.len) return error.TooManyAdds;
            var pit = std.mem.splitScalar(u8, v, '-');
            out.wg_split_vbl[out.n_wg_split_vbl] = .{
                try std.fmt.parseInt(u24, pit.next().?, 16),
                try std.fmt.parseInt(u24, pit.next() orelse return error.MissingValue, 16),
            };
            out.n_wg_split_vbl += 1;
        } else if (std.mem.eql(u8, a, "--wg-expand")) {
            // Accepts bytes, or "1m"/"2m" for whole megabytes.
            const v = it.next() orelse return error.MissingValue;
            const mb = v.len > 1 and (v[v.len - 1] == 'm' or v[v.len - 1] == 'M');
            const n = try std.fmt.parseInt(u32, if (mb) v[0 .. v.len - 1] else v, 10);
            out.wg_expand_to = if (mb) n * 1024 * 1024 else n;
            if (!std.math.isPowerOfTwo(out.wg_expand_to)) return error.BadExpandSize;
        } else if (std.mem.eql(u8, a, "--wg-copy-reserve")) {
            const v = it.next() orelse return error.MissingValue;
            out.wg_copy_reserve = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, a, "--wg-static")) {
            out.wg_static = true;
        } else if (std.mem.eql(u8, a, "--out")) {
            out.gen_out = it.next() orelse return error.MissingValue;
        } else if (rom == null) {
            rom = a;
        } else return error.TooManyArgs;
    }
    out.rom = rom orelse return error.NoRom;
    if (out.wide != 0) {
        if (out.accuracy == .accurate) return error.WideNeedsFast;
        if (out.wide > core.ppu.wide_margin_max) return error.WideTooBig;
    }
    if ((out.gen_fastrom or out.gen_sa1) and (out.patch != null or out.auto_patch or
        out.save_patched != null or out.auto_fastrom or
        out.accuracy == .accurate or out.wide != 0 or out.sa1_report))
        return error.GenConflicts;
    if (out.gen_fastrom and out.gen_sa1) return error.GenConflicts;
    if (out.whole_game and !out.gen_sa1) return error.GenConflicts;
    if (out.usage_map_out != null and !out.sa1_report) return error.UsageNeedsReport;
    if (out.call_graph_out != null and !out.sa1_report) return error.UsageNeedsReport;
    return out;
}
