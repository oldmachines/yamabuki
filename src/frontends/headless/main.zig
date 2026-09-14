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

// main.zig is split into modules under cli/; each is
// re-exported here so this file remains the root and every internal name
// keeps resolving. Pure code motion — see each module's header.
const args_mod = @import("cli/args.zig");
const dump_mod = @import("cli/dump.zig");
const replay_mod = @import("cli/replay.zig");
const cache_mod = @import("cli/cache.zig");
const verify_mod = @import("cli/verify.zig");
const generate_mod = @import("cli/generate.zig");
const report_mod = @import("cli/report.zig");

pub const Args = args_mod.Args;
pub const RegionArg = args_mod.RegionArg;
pub const gen_frames_default = args_mod.gen_frames_default;
pub const max_cover_pairs = args_mod.max_cover_pairs;
pub const max_movies = args_mod.max_movies;
pub const parseArgs = args_mod.parseArgs;
pub const report_frames_default = args_mod.report_frames_default;
pub const BaselineSnap = cache_mod.BaselineSnap;
pub const SnapReader = cache_mod.SnapReader;
pub const applyBaselineSnapshot = cache_mod.applyBaselineSnapshot;
pub const baselineCachePath = cache_mod.baselineCachePath;
pub const baselineKey = cache_mod.baselineKey;
pub const baseline_cache_magic = cache_mod.baseline_cache_magic;
pub const baseline_cache_version = cache_mod.baseline_cache_version;
pub const baseline_layout = cache_mod.baseline_layout;
pub const harvestCachePath = cache_mod.harvestCachePath;
pub const harvest_cache_magic = cache_mod.harvest_cache_magic;
pub const harvest_cache_version = cache_mod.harvest_cache_version;
pub const hcRead32 = cache_mod.hcRead32;
pub const hcRead64 = cache_mod.hcRead64;
pub const layoutHash = cache_mod.layoutHash;
pub const loadBaselineSnapshot = cache_mod.loadBaselineSnapshot;
pub const loadHarvestCache = cache_mod.loadHarvestCache;
pub const saveBaselineSnapshot = cache_mod.saveBaselineSnapshot;
pub const saveHarvestCache = cache_mod.saveHarvestCache;
pub const dumpPpu = dump_mod.dumpPpu;
pub const dumpRam = dump_mod.dumpRam;
pub const dumpSrm = dump_mod.dumpSrm;
pub const dumpVram = dump_mod.dumpVram;
pub const loadCodeMap = dump_mod.loadCodeMap;
pub const readScpuSet = dump_mod.readScpuSet;
pub const saveRegion = dump_mod.saveRegion;
pub const writeCovOut = dump_mod.writeCovOut;
pub const writeScpuSet = dump_mod.writeScpuSet;
pub const defaultBpsPath = generate_mod.defaultBpsPath;
pub const foldConvEvidence = generate_mod.foldConvEvidence;
pub const harvestFiles = generate_mod.harvestFiles;
pub const runGenerate = generate_mod.runGenerate;
pub const runSa1Gen = generate_mod.runSa1Gen;
pub const AudioSink = replay_mod.AudioSink;
pub const EnergySink = replay_mod.EnergySink;
pub const anchorMovie = replay_mod.anchorMovie;
pub const applySidecar = replay_mod.applySidecar;
pub const applyStartSave = replay_mod.applyStartSave;
pub const feedMovie = replay_mod.feedMovie;
pub const loadMovie = replay_mod.loadMovie;
pub const loadSaveBytes = replay_mod.loadSaveBytes;
pub const loadStateInto = replay_mod.loadStateInto;
pub const seedConverted = replay_mod.seedConverted;
pub const RoutineRow = report_mod.RoutineRow;
pub const WramVerdict = report_mod.WramVerdict;
pub const attributedTotal = report_mod.attributedTotal;
pub const bwram_bytes = report_mod.bwram_bytes;
pub const coverage_unsettled_pct = report_mod.coverage_unsettled_pct;
pub const iram_bytes = report_mod.iram_bytes;
pub const pct = report_mod.pct;
pub const printAudit = report_mod.printAudit;
pub const printByteCount = report_mod.printByteCount;
pub const printConversion = report_mod.printConversion;
pub const printCoverage = report_mod.printCoverage;
pub const printDmaUse = report_mod.printDmaUse;
pub const printDmaUseJson = report_mod.printDmaUseJson;
pub const printOffloadCensus = report_mod.printOffloadCensus;
pub const printPlan = report_mod.printPlan;
pub const printWramFootprint = report_mod.printWramFootprint;
pub const reportSa1 = report_mod.reportSa1;
pub const routineRows = report_mod.routineRows;
pub const runReport = report_mod.runReport;
pub const topCodeRows = report_mod.topCodeRows;
pub const wramShared = report_mod.wramShared;
pub const wramVerdict = report_mod.wramVerdict;
pub const writeUsageMap = report_mod.writeUsageMap;
pub const Behavioral = verify_mod.Behavioral;
pub const ConvHome = verify_mod.ConvHome;
pub const MmioRef = verify_mod.MmioRef;
pub const SaTier = verify_mod.SaTier;
pub const appendPaddingLines = verify_mod.appendPaddingLines;
pub const convHome = verify_mod.convHome;
pub const diagnoseCulprit = verify_mod.diagnoseCulprit;
pub const firstDiff = verify_mod.firstDiff;
pub const hang_frames = verify_mod.hang_frames;
pub const learnWallMask = verify_mod.learnWallMask;
pub const loadMmioRef = verify_mod.loadMmioRef;
pub const mmioGate = verify_mod.mmioGate;
pub const modeCell = verify_mod.modeCell;
pub const movAt = verify_mod.movAt;
pub const pcInPadding = verify_mod.pcInPadding;
pub const printEnvelopeDiag = verify_mod.printEnvelopeDiag;
pub const replayTrace = verify_mod.replayTrace;
pub const replayWram = verify_mod.replayWram;
pub const runBehavioralProbe = verify_mod.runBehavioralProbe;
pub const runBehavioralTier = verify_mod.runBehavioralTier;
pub const runTickDump = verify_mod.runTickDump;
pub const stepBehavioralFrame = verify_mod.stepBehavioralFrame;
pub const stockBytesAt = verify_mod.stockBytesAt;
pub const verifyBehavioral = verify_mod.verifyBehavioral;
pub const writeMmioRef = verify_mod.writeMmioRef;

test {
    _ = args_mod;
    _ = dump_mod;
    _ = replay_mod;
    _ = cache_mod;
    _ = verify_mod;
    _ = generate_mod;
    _ = report_mod;
}

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
pub const debug_stack_size = 64 * 1024 * 1024;

/// Phase clock for the generator's log: wall seconds since the first mark.
/// MEASUREMENT, not a caveat — every "why is a build 17 minutes" question
/// gets answered by these lines instead of guessed at.
pub var phase_t0: i96 = 0;
pub fn phaseMark(io: std.Io, out: *std.Io.Writer, name: []const u8) !void {
    const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
    if (phase_t0 == 0) phase_t0 = now;
    const dt: u64 = @intCast(@divTrunc(now - phase_t0, 1_000_000));
    try out.print("  [time] {s}: +{d}.{d:0>1}s\n", .{ name, dt / 1000, (dt % 1000) / 100 });
    try out.flush();
}

fn runOnThread(init: std.process.Init, status: *anyerror!void) void {
    status.* = run(init);
}

pub fn run(init: std.process.Init) !void {
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
    try loadCodeMap(io, gpa, out, args);

    var image = util.readRomFile(io, gpa, args.rom, out) orelse std.process.exit(1);

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
    if (args.apu_port_trace) core.apu.dbg_port_trace = true;
    try loadCodeMap(io, gpa, out, args);
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
    var mmio_seen: ?*core.bus.Bus.MmioWriters = null;
    if ((args.mmio_ref != null or args.mmio_out != null) and con.* == .fast) {
        mmio_seen = try core.bus.Bus.MmioWriters.create(gpa);
        con.fast.bus.mmio_writers = mmio_seen;
    }
    defer if (mmio_seen) |seen| {
        if (args.mmio_out) |op| {
            const one = [_]*core.bus.Bus.MmioWriters{seen};
            const none = [_]*core.bus.Bus.MmioWriters{};
            writeMmioRef(io, op, image, &one, &none) catch |e| std.debug.print("[mmio] cannot write '{s}': {s}\n", .{ op, @errorName(e) });
            std.debug.print("[mmio] wrote {s} ({} writer pair(s))\n", .{ op, seen.set.count() });
        }
        if (args.mmio_ref) |rp| {
            const ref = loadMmioRef(io, gpa, rp) catch null;
            if (ref) |r| {
                const stock_img: ?[]const u8 = if (args.mmio_stock) |sp| blk: {
                    const raw = util.readRomBytes(io, gpa, sp) catch break :blk null;
                    break :blk core.header.stripCopierHeader(raw);
                } else null;
                var n: u32 = 0;
                var n_stock: u32 = 0;
                var it = seen.set.keyIterator();
                while (it.next()) |k| {
                    const reg: u16 = @intCast(k.* >> 24);
                    const pc: u24 = @intCast(k.* & 0xFF_FFFF);
                    if (r.set.has(reg, pc) or r.inPadding(pc)) continue;
                    if (stock_img) |st| if (stockBytesAt(st, image, pc)) {
                        n_stock += 1;
                        continue;
                    };
                    n += 1;
                    if (n <= 40) std.debug.print("[mmio] ${X:0>4} written from ${X:0>2}:{X:0>4} — a rewritten site no run of the reference wrote it from\n", .{ reg, pc >> 16, pc & 0xFFFF });
                }
                std.debug.print("[mmio] {} rewritten writer(s) outside the reference; {} stock-identical writer(s) the reference never reached\n", .{ n, n_stock });
            } else std.debug.print("[mmio] cannot read the reference '{s}'\n", .{rp});
        }
    };
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

/// The MMIO gate's writer sets for the generation in flight (per surface:
/// stock's and the conversion's), kept at file scope so the report that
/// writes the patch can export them beside it.
pub var mmio_base_g: [max_movies]*core.bus.Bus.MmioWriters = undefined;
pub var mmio_conv_g: [max_movies]*core.bus.Bus.MmioWriters = undefined;
pub var mmio_n_g: usize = 0;

/// TEMP experiment: delay the CONVERTED side's movie feed by this many
/// frames (a frame-aligned boot pad displaces the game's timeline; input
/// must follow it or every press lands early in game-time and forks the
/// run). Set by the undocumented --conv-pad flag.
pub var dbg_conv_pad: u32 = 0;
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

/// `--patch`: one shared reader and applier for every frontend (`util`).
fn applyPatch(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    image: []u8,
    patch_path: []const u8,
) ![]u8 {
    return util.applyPatchFile(io, gpa, out, image, patch_path);
}

/// Apply already-read (and, for `--auto-patch`, hash-verified) patch bytes
/// to an already-stripped image; the messages are `util`'s.
fn applyBytes(
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    stripped: []const u8,
    pbytes: []const u8,
    patch_path: []const u8,
) ![]u8 {
    return util.applyPatchBytes(gpa, out, stripped, pbytes, patch_path);
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
