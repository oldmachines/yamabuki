//! The patch generators' drivers: the FastROM session and the SA-1 session (surfaces, baselines, coverage pad, harvest, plan, the greedy ladder, verification, the BPS).
//!
//! Carved out of main.zig as pure code motion; every declaration
//! here is re-exported from main.zig, which stays the root.

const core = @import("snes_core");
const profile = core.profile;
const std = @import("std");
const util = @import("util");
const root_mod = @import("../main.zig");

const Args = root_mod.Args;
const BaselineSnap = root_mod.BaselineSnap;
const EnergySink = root_mod.EnergySink;
const SaTier = root_mod.SaTier;
const applyBaselineSnapshot = root_mod.applyBaselineSnapshot;
const applySidecar = root_mod.applySidecar;
const baselineCachePath = root_mod.baselineCachePath;
const baselineKey = root_mod.baselineKey;
const debug_stack_size = root_mod.debug_stack_size;
const diagnoseCulprit = root_mod.diagnoseCulprit;
const firstDiff = root_mod.firstDiff;
const gen_frames_default = root_mod.gen_frames_default;
const harvestCachePath = root_mod.harvestCachePath;
const loadBaselineSnapshot = root_mod.loadBaselineSnapshot;
const loadCodeMap = root_mod.loadCodeMap;
const loadHarvestCache = root_mod.loadHarvestCache;
const loadSaveBytes = root_mod.loadSaveBytes;
const max_cover_pairs = root_mod.max_cover_pairs;
const max_movies = root_mod.max_movies;
const mmioGate = root_mod.mmioGate;
const movAt = root_mod.movAt;
const phaseMark = root_mod.phaseMark;
const printAudit = root_mod.printAudit;
const printCoverage = root_mod.printCoverage;
const printEnvelopeDiag = root_mod.printEnvelopeDiag;
const reportSa1 = root_mod.reportSa1;
const run = root_mod.run;
const runBehavioralTier = root_mod.runBehavioralTier;
const saveBaselineSnapshot = root_mod.saveBaselineSnapshot;
const saveHarvestCache = root_mod.saveHarvestCache;
const seedConverted = root_mod.seedConverted;
const writeCovOut = root_mod.writeCovOut;
const writeMmioRef = root_mod.writeMmioRef;
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
/// The stock and conversion file offsets a covered CPU address reads from,
/// for the cover harvest's byte-identity guard. Stock is plain LoROM. A dual
/// conversion image (>= 4 MiB, larger than any plain Super Metroid LoROM)
/// follows the shim's Super-MMC map, where $A0-$BF is MB2 at file $200000 —
/// NOT the LoROM mirror of $20-$3F the plain formula would read. Using the
/// plain formula for both silently compared MB1 bytes against the cover's
/// MB2 code and mis-credited (in practice, rejected) every $A0-$BF harvest.
/// Returns null for an address with no ROM code home in either image.
pub fn harvestFiles(image_len: usize, ci_len: usize, pc: u24) ?struct { s: usize, c: usize } {
    const bank: u32 = (pc >> 16) & 0x7F;
    const a16: u32 = pc & 0xFFFF;
    if (bank > 0x3F or a16 < 0x8000) return null;
    const sfile: usize = bank * 0x8000 + (a16 - 0x8000);
    const cfile: usize = if (ci_len >= 0x40_0000)
        (core.sa1gen.loromFileOffset(ci_len, pc) orelse return null)
    else
        sfile;
    if (sfile >= image_len or cfile >= ci_len) return null;
    return .{ .s = sfile, .c = cfile };
}

pub fn foldConvEvidence(site_ev: []u8, conv: []const u8, out: *std.Io.Writer) []u8 {
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

/// The default output path for a generated patch: `<rom>.bps` next to the
/// ROM file — the softpatch naming every frontend discovers by basename.
pub fn defaultBpsPath(gpa: std.mem.Allocator, rom_path: []const u8) ![]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, rom_path, '.') orelse rom_path.len;
    const slash = std.mem.lastIndexOfScalar(u8, rom_path, '/') orelse 0;
    const stem = if (dot > slash) rom_path[0..dot] else rom_path;
    return std.fmt.allocPrint(gpa, "{s}.bps", .{stem});
}

/// `--gen-fastrom-patch`: derive the FastROM conversion, verify it
/// in-emulator, and only then write the BPS. `image` is copier-stripped.
pub fn runGenerate(
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
    try loadCodeMap(io, gpa, out, args);
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
    {
        var mbuf: [512]u8 = undefined;
        const mpath = std.fmt.bufPrint(&mbuf, "{s}.mmio", .{path}) catch path;
        writeMmioRef(io, mpath, image, root_mod.mmio_base_g[0..root_mod.mmio_n_g], root_mod.mmio_conv_g[0..root_mod.mmio_n_g]) catch {};
        try out.print("wrote {s} (the MMIO writer sets: stock's and the conversion's, for --mmio-ref)\n", .{mpath});
    }
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
pub fn runSa1Gen(
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
        pub fn f(ms: []const util.movie.Movie, s: usize, fallback: ?[]const u8) ?[]const u8 {
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
    var sum: profile.Summary = undefined;
    var sum_s: [max_movies]profile.Summary = undefined;
    // The baseline snapshot: a hit here skips the evidence pass, every
    // baseline and the coverage pad, and fills their outputs below once the
    // surface-0 console exists (its profiler state is part of the snapshot).
    var base_key: u64 = 0;
    var base_path: []const u8 = "";
    var base_data: ?[]const u8 = null;
    if (args.baseline_cache) |dir| {
        base_key = baselineKey(image, movs, n_surf, totals[0..n_surf], evidence_state, verify_state, args.skip, args.whole_game, args.window);
        base_path = try baselineCachePath(gpa, dir, base_key);
        base_data = loadBaselineSnapshot(io, gpa, base_path, base_key);
        try out.print("  baseline cache: {s} ({s})\n", .{ if (base_data != null) @as([]const u8, "HIT — stock phase skipped") else "miss — will be written", base_path });
        try out.flush();
    }
    const base_restored = base_data != null;
    if (!base_restored) if (evidence_state) |sb| {
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
    };
    try phaseMark(io, out, "baselines: start (harvest + evidence pass done)");
    const cart = try core.Cartridge.load(gpa, image);
    const con = try gpa.create(core.ProfilingConsole);
    con.init(cart);
    con.usage = &umap;
    applySidecar(con, movAt(movs, 0));
    // The MMIO gate's reference: stock's writer set per surface.
    for (0..n_surf) |ms| root_mod.mmio_base_g[ms] = try core.bus.Bus.MmioWriters.create(gpa);
    for (0..n_surf) |ms| root_mod.mmio_conv_g[ms] = try core.bus.Bus.MmioWriters.create(gpa);
    root_mod.mmio_n_g = n_surf;
    con.bus.mmio_writers = root_mod.mmio_base_g[0];
    const base_snap: BaselineSnap = .{
        .n_surf = n_surf,
        .totals = totals[0..n_surf],
        .hashes = hashes_s[0..n_surf],
        .env = env_base_s[0..n_surf],
        .audio = base_audio_s[0..n_surf],
        .sums = sum_s[0..n_surf],
        .mmio = root_mod.mmio_base_g[0..n_surf],
        .cov_early = &cov_early,
        .prof = &con.prof,
        .evidence = &evidence_conv,
        .ub = ub,
        .site_ev = site_ev,
        .ptr_ev = ptr_ev,
    };
    if (base_data) |bd| {
        applyBaselineSnapshot(bd, base_snap) catch |e| {
            try out.print("error: baseline snapshot {s} does not apply: {s} (delete it)\n", .{ base_path, @errorName(e) });
            try out.flush();
            std.process.exit(1);
        };
        sum = sum_s[0];
    }
    if (!base_restored) if (surfaceAnchor(movs, 0, verify_state)) |sb| con.loadState(sb) catch |e| {
        try out.print("error: the state does not load into this console: {s}\n", .{@errorName(e)});
        try out.flush();
        std.process.exit(1);
    };
    var base_audio = core.console.audio_hash_init;
    var feed0: util.movie.Feed = .init(movAt(movs, 0));
    if (!base_restored) for (0..total) |i| {
        if (i == cov_mark) cov_early = core.usage_map.countOpcodes(ub);
        feed0.step(con, i);
        con.runFrame();
        try util.drainAudio(con, &base_audio, EnergySink{ .cell = &env_base[i] }, EnergySink.add);
        hashes[i] = core.console.hashFrame(con.framebuffer());
        if (con.takeProfile()) |smp| {
            if (i >= args.skip) samples.appendAssumeCapacity(smp);
        }
    };
    if (!base_restored) {
        base_audio_s[0] = base_audio;
        const scratch = try gpa.alloc(f64, samples.items.len);
        sum = profile.summarise(samples.items, scratch);
    }
    // Surfaces beyond the first: fresh consoles into the SAME coverage
    // and evidence union, their own hashes/audio and their own profile
    // summary (the lag comparison is per surface).
    if (!base_restored) sum_s[0] = sum;
    if (!base_restored) for (1..n_surf) |s| {
        const cart_s = try core.Cartridge.load(gpa, image);
        const con_s = try gpa.create(core.ProfilingConsole);
        con_s.init(cart_s);
        con_s.usage = &umap;
        applySidecar(con_s, movAt(movs, s));
        con_s.bus.mmio_writers = root_mod.mmio_base_g[s];
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
    };
    try phaseMark(io, out, "baselines: done");
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
    if (!base_restored and args.whole_game and args.window and movs.len != 0) {
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
    if (args.baseline_cache) |dir| if (!base_restored) {
        saveBaselineSnapshot(io, gpa, dir, base_path, base_key, base_snap) catch |e| {
            try out.print("  baseline cache: NOT written ({s})\n", .{@errorName(e)});
        };
        try out.print("  baseline cache: written {s}\n", .{base_path});
        try out.flush();
    };
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

        pub fn replay(job: *@This()) void {
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
    try phaseMark(io, out, "harvest: start");
    var jobs: [max_cover_pairs]HarvestJob = @splat(.{});
    const jobs_max: usize = if (args.harvest_jobs != 0) args.harvest_jobs else @min(12, std.Thread.getCpuCount() catch 4);
    // Phase 1: load every pair, decide cache hit or replay, and prepare the
    // replay's console on this thread (allocation stays off the workers).
    for (0..args.n_cover) |ci_i| {
        if (args.cover_image[ci_i] == null or args.cover_movie[ci_i] == null) continue;
        const job = &jobs[ci_i];
        job.ci_raw = util.readRomFile(io, gpa, args.cover_image[ci_i].?, out) orelse std.process.exit(1);
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
            const hf = harvestFiles(image.len, ci.len, @intCast(pc)) orelse continue;
            if (image[hf.s] != ci[hf.c]) continue; // scaffolding / rewritten opcode
            // A cover's opcode inside an instruction the stock profile
            // proved (executed, not a start) is a harvest from an image
            // whose code lay elsewhere, not coverage. Measured: three such
            // flags from two old conversion covers sat inside
            // `JSR NormalEnemyTouchAI` and `ORA #$2000`.
            const ubm = ub[pc] | ub[pc ^ 0x80_0000];
            if (ubm & core.usage_map.flag_exec != 0 and ubm & core.usage_map.flag_opcode == 0) continue;
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
            const hf = harvestFiles(image.len, ci.len, @intCast(ca)) orelse continue;
            if (image[hf.s] != ci[hf.c]) continue;
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
    for (root_mod.dbg_site_ev[0..root_mod.dbg_n_site_ev]) |p| {
        try out.print("  [site-ev] ${x:0>6}: cov={x:0>2} cov80={x:0>2} ev={x:0>2} ev80={x:0>2}\n", .{
            p, ub[p], ub[0x80_0000 | p], site_ev[p], site_ev[0x80_0000 | p],
        });
    }
    if (root_mod.dbg_n_site_ev != 0) try out.flush();
    // --ev-only: the coverage/evidence answer is all that was wanted. Stop
    // before the (much longer) plan-and-verify machinery.
    if (root_mod.dbg_ev_only) return;
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
        if (root_mod.dbg_audit) {
            // Honour --save-attempt here too: the audit path is the SIX
            // MINUTE way to get a converted image (profile + one
            // conversion) instead of the forty-minute ladder, which makes
            // it the right tool for diffing one rewrite rule against
            // another.
            if (args.save_attempt) |ap|
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ap, .data = res.image });
            try printAudit(out, image, ub, &res);
            try writeCovOut(io, gpa, out, args);
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
        // The surfaces verify IN PARALLEL, one thread each (capped at the
        // core count): each has its own consoles, arena and output buffer,
        // and touches nothing shared but its own per-surface slots. The
        // results fold in surface order, so the verdict, the first failure
        // reported and the printed order are exactly the serial loop's.
        // MEASURED before this: eight surfaces, ~275k frames, replayed
        // serially on one thread were the bulk of a 17-minute build.
        const SurfaceJob = struct {
            s: usize = 0,
            n_surf: usize = 0,
            total: u32 = 0,
            hashes: []u64 = &.{},
            conv_hashes: []u64 = &.{},
            env_base: []u64 = &.{},
            env_conv: []u64 = &.{},
            base_audio: u64 = 0,
            base_sum: profile.Summary = undefined,
            mmio_base: []const *core.bus.Bus.MmioWriters = &.{},
            mmio_conv: *core.bus.Bus.MmioWriters = undefined,
            mov: ?util.movie.Movie = null,
            anchor: ?[]const u8 = null,
            plan: *const profile.Plan = undefined,
            res: *const core.sa1gen.Result = undefined,
            image: []const u8 = &.{},
            skip: u32 = 0,
            verify_behavioral: bool = false,
            behavioral_ok: bool = false,
            window: bool = false,
            arena: std.heap.ArenaAllocator = undefined,
            out: std.Io.Writer.Allocating = undefined,
            // results
            tier: ?SaTier = null,
            equiv: util.Equivalence = .identical,
            fail_why: []const u8 = "",
            fail_frame: u32 = 0,
            conv_sum: profile.Summary = undefined,
            err: ?anyerror = null,
            thread: ?std.Thread = null,

            pub fn run(job: *@This()) void {
                job.runInner() catch |e| {
                    job.err = e;
                };
            }

            pub fn runInner(job: *@This()) !void {
                const a = job.arena.allocator();
                const w = &job.out.writer;
                const s = job.s;
                @memset(job.env_conv, 0);
                var fast_audio = core.console.audio_hash_init;
                var job_samples: std.array_list.Managed(profile.FrameSample) = .init(a);
                try job_samples.ensureTotalCapacity(job.total);
                {
                    const cart2 = try core.Cartridge.load(a, job.res.image);
                    const con2 = try a.create(core.ProfilingConsole);
                    con2.init(cart2);
                    applySidecar(con2, job.mov);
                    job.mmio_conv.set.clearRetainingCapacity();
                    con2.bus.mmio_writers = job.mmio_conv;
                    if (job.anchor) |sb| try seedConverted(con2, sb, job.plan, job.res);
                    var feed2: util.movie.Feed = .init(job.mov);
                    for (0..job.total) |i| {
                        feed2.step(con2, i);
                        con2.runFrame();
                        try util.drainAudio(con2, &fast_audio, EnergySink{ .cell = &job.env_conv[i] }, EnergySink.add);
                        job.conv_hashes[i] = core.console.hashFrame(con2.framebuffer());
                        if (con2.takeProfile()) |smp| {
                            if (i >= job.skip) job_samples.appendAssumeCapacity(smp);
                        }
                    }
                    con2.cart.deinit(a);
                }
                const job_scratch = try a.alloc(f64, job_samples.items.len);
                job.conv_sum = profile.summarise(job_samples.items, job_scratch);

                // Stage-S4 gate, three tiers: strict identity; frames
                // identical with envelope-equivalent audio; equivalent modulo
                // timing with a non-negative lag improvement.
                job.equiv = util.framesEquivalent(job.hashes, job.conv_hashes);
                var why: []const u8 = "";
                var at: u32 = 0;
                var s_tier: ?SaTier = switch (job.equiv) {
                    .identical => blk: {
                        if (fast_audio == job.base_audio) break :blk .strict;
                        if (util.audioEnvelopeMismatch(job.env_base, job.env_conv)) |bad| {
                            why = "audio envelope diverged (a sound moved, silenced, or invented)";
                            at = bad;
                            break :blk null;
                        }
                        break :blk .envelope;
                    },
                    .equivalent => blk: {
                        if (job.conv_sum.lag_frames > job.base_sum.lag_frames) {
                            why = "same pictures but MORE dropped frames — a regression";
                            break :blk null;
                        }
                        break :blk .equivalent;
                    },
                    .divergent => blk: {
                        why = "renders pictures the original never showed";
                        at = firstDiff(job.hashes, job.conv_hashes);
                        break :blk null;
                    },
                };

                // The behavioral tier: a slowdown-removing conversion cannot
                // be frame-identical to a slowed-down baseline, so
                // `divergent` from the pixel gate is where working offloads
                // go to die. Opt-in. Whole-game (SA-1-execution) images stay
                // excluded — their state relocation is not modelled — but
                // WINDOW images are in.
                if (s_tier == null and job.equiv == .divergent and job.verify_behavioral and job.behavioral_ok) {
                    if (job.n_surf > 1) try w.print("  surface {} of {}:\n", .{ s + 1, job.n_surf });
                    s_tier = try runBehavioralTier(a, w, job.image, job.res.image, job.plan, job.res, job.mov, job.anchor, job.window, job.total, &why, &at);
                }
                // The MMIO gate, on top of whatever tier the pictures and the
                // logic earned: a hardware register written from a site stock
                // never wrote it from is a relocation that landed on hardware,
                // whatever the pictures say (the sound driver's death was
                // invisible to the pixels for 2,400 frames).
                if (s_tier != null) {
                    const n_mmio = try mmioGate(w, job.image, job.res.image, job.mmio_base, job.mmio_conv);
                    if (n_mmio != 0) {
                        why = "a hardware register is written from a site stock never writes it from (the MMIO gate)";
                        s_tier = null;
                    }
                }
                job.tier = s_tier;
                job.fail_why = why;
                job.fail_frame = at;
            }
        };
        try phaseMark(io, out, "verify: start (rewrite done)");
        var sjobs: [max_movies]SurfaceJob = @splat(.{});
        for (0..n_surf) |s| {
            if (!args.movie_verify[s]) continue;
            const j = &sjobs[s];
            j.s = s;
            j.n_surf = n_surf;
            j.total = totals[s];
            j.hashes = hashes_s[s];
            j.conv_hashes = conv_hashes_s[s];
            j.env_base = env_base_s[s];
            j.env_conv = env_conv_s[s];
            j.base_audio = base_audio_s[s];
            j.base_sum = sum_s[s];
            j.mmio_base = root_mod.mmio_base_g[0..n_surf];
            j.mmio_conv = root_mod.mmio_conv_g[s];
            j.mov = movAt(movs, s);
            j.anchor = surfaceAnchor(movs, s, verify_state);
            j.plan = &plan;
            j.res = &res;
            j.image = image;
            j.skip = args.skip;
            j.verify_behavioral = args.verify_behavioral;
            j.behavioral_ok = !args.whole_game or args.window;
            j.window = args.window;
            j.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            j.out = std.Io.Writer.Allocating.init(j.arena.allocator());
        }
        const surf_jobs_max: usize = @max(1, @min(if (args.verify_jobs != 0) args.verify_jobs else (std.Thread.getCpuCount() catch 4), n_surf));
        try out.print("  verify: {} surface(s) at a time\n", .{surf_jobs_max});
        var surf_next: usize = 0;
        var surf_inflight: usize = 0;
        for (0..n_surf) |s| {
            // Evidence-only movie: it profiled into the union above; its
            // gameplay forks at the first RNG-divergent event, so a
            // tick-locked verdict over it compares two different games.
            if (!args.movie_verify[s]) continue;
            while (surf_next < n_surf and surf_inflight < surf_jobs_max) : (surf_next += 1) {
                if (!args.movie_verify[surf_next]) continue;
                sjobs[surf_next].thread = try std.Thread.spawn(.{ .stack_size = debug_stack_size }, SurfaceJob.run, .{&sjobs[surf_next]});
                surf_inflight += 1;
            }
            const job = &sjobs[s];
            if (job.thread) |t| {
                t.join();
                job.thread = null;
                surf_inflight -= 1;
            }
            try out.writeAll(job.out.written());
            try out.flush();
            if (job.err) |e| return e;
            if (s == 0) conv_sum = job.conv_sum;
            if (job.tier) |t| {
                if (@intFromEnum(t) > @intFromEnum(passed.?)) passed = t;
            } else {
                passed = null;
                equiv = job.equiv;
                fail_why = job.fail_why;
                fail_frame = job.fail_frame;
                fail_mov = movAt(movs, s);
                fail_s = s;
                if (n_surf > 1) try out.print("  surface {} of {} FAILED: {s}\n", .{ s + 1, n_surf, fail_why });
                break;
            }
        }
        for (0..n_surf) |s| if (sjobs[s].thread) |t| {
            t.join();
            sjobs[s].thread = null;
        };
        for (0..n_surf) |s| if (args.movie_verify[s]) sjobs[s].arena.deinit();
        try phaseMark(io, out, "verify: done");
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
