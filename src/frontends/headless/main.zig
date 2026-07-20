//! Headless runner: load a ROM, run N frames, print the framebuffer and audio
//! hashes, and optionally dump the final frame as a binary PPM (P6) and the
//! whole audio stream as a WAV, both for eyeballing.
//!
//!   yamabuki-headless <rom.sfc> [--frames N] [--ppm out.ppm] [--wav out.wav]
//!                     [--accurate] [--patch p.bps|p.ips] [--save-patched out.sfc]
//!   yamabuki-headless <rom.sfc> --sa1-report [--frames N] [--skip N] [--json] [--hot]
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
//! `--sa1-report` is step one of the SA-1 candidacy analyser (M12): it runs the
//! game with the frame-budget profiler compiled in and answers the question that
//! comes before every other one — *is this game CPU-bound at all?* `--routines`
//! adds steps two and three: which routines cost the frame, and each hot
//! routine's WRAM working set, MMIO blockers, and page-sharing with the rest —
//! the numbers that decide whether it is worth moving to the SA-1. See
//! `core/profile.zig` for what is being measured and why.

const std = @import("std");
const core = @import("snes_core");
const profile = core.profile;

const Args = struct {
    rom: []const u8,
    frames: ?u32 = null,
    ppm: ?[]const u8 = null,
    wav: ?[]const u8 = null,
    accuracy: core.Accuracy = .fast,
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
};

/// Default frames to profile: 60 seconds at 60 Hz, on top of the skipped boot.
const report_frames_default: u32 = 3600;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const args = parseArgs(init, gpa) catch {
        try out.print(
            \\usage: yamabuki-headless <rom.sfc> [--frames N] [--ppm out.ppm] [--wav out.wav] [--accurate]
            \\                         [--patch p.bps|p.ips] [--auto-patch] [--patch-dir DIR] [--save-patched out.sfc]
            \\       yamabuki-headless <rom.sfc> --sa1-report [--frames N] [--skip N] [--json] [--hot] [--routines]
            \\
            \\  --patch p     apply a BPS/IPS patch to the ROM in memory at load (BPS verified, IPS not)
            \\  --auto-patch  look this ROM up in patches/registry.zon and apply its registered patch
            \\  --patch-dir d where --auto-patch looks for patch files (default: patches/)
            \\  --save-patched  write the patched image and exit without emulating (needs a patch)
            \\  --auto-fastrom  pin MEMSEL=1 (FastROM timing for SlowROM games; compat-list gated)
            \\  --sa1-report  is this game CPU-bound? (step one of the SA-1 candidacy analyser)
            \\  --skip N      frames to run before profiling starts (default 300 — boot is not gameplay)
            \\  --hot         also list the loops the frame is spent in, and how each was classified
            \\  --routines    which routines cost the frame (self/inclusive cycles per call site), and
            \\                each one's WRAM working set, MMIO blockers, and page-sharing with the rest
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

    if (args.auto_fastrom) checkFastromCompat(out, core.header.stripCopierHeader(image)) catch std.process.exit(1);

    const cart = core.Cartridge.load(gpa, image) catch |e| {
        try out.print("error: cannot load ROM: {s}\n", .{@errorName(e)});
        try out.flush();
        std.process.exit(1);
    };

    if (args.sa1_report) {
        try runReport(io, gpa, out, args, cart);
        return;
    }

    const con = try gpa.create(core.AnyConsole);
    con.init(args.accuracy, cart);
    if (args.auto_fastrom) con.enableAutoFastrom();

    // Drain audio every frame (the ring holds ~15 frames); hash the stream
    // and keep it if a WAV dump was requested.
    var audio_hash = core.console.audio_hash_init;
    var audio_peak: u16 = 0;
    var audio_all: std.array_list.Managed(i16) = .init(gpa);
    var drain: [4096]i16 = undefined;
    const frames = args.frames orelse 1;
    for (0..frames) |_| {
        con.runFrame();
        while (true) {
            const n = con.readAudio(&drain);
            if (n == 0) break;
            audio_hash = core.console.hashAudio(audio_hash, drain[0..n]);
            for (drain[0..n]) |s| audio_peak = @max(audio_peak, @abs(s));
            if (args.wav != null) try audio_all.appendSlice(drain[0..n]);
        }
    }

    const fb = con.framebuffer();
    const width = con.frameWidth();
    const hash = core.console.hashFrame(fb);
    try out.print("{s}: {} frames, {}x{}, hash={x:0>16}, audio={x:0>16} (peak {})\n", .{
        args.rom, frames, width, fb.len / width, hash, audio_hash, audio_peak,
    });
    try out.flush();

    if (args.ppm) |path| {
        try writePpm(io, path, fb, width, @intCast(fb.len / width));
        try out.print("wrote {s}\n", .{path});
        try out.flush();
    }
    if (args.wav) |path| {
        try writeWav(io, path, audio_all.items);
        try out.print("wrote {s} ({} stereo frames)\n", .{ path, audio_all.items.len / 2 });
        try out.flush();
    }
}

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

/// `--sa1-report`: run the game with the frame-budget profiler and report
/// whether it is CPU-bound.
///
/// Nothing presses any buttons, so what gets profiled is whatever the game does
/// on its own — the attract/demo loop for most carts, a title screen for the
/// rest. That is a real limitation and the report says so, because a title
/// screen idling at 8% utilisation is not evidence of anything.
fn runReport(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    args: Args,
    cart: core.Cartridge,
) !void {
    _ = io;
    const want = args.frames orelse report_frames_default;

    const con = try gpa.create(core.ProfilingConsole);
    con.init(cart);
    if (args.auto_fastrom) con.bus.enableAutoFastrom();

    var samples: std.array_list.Managed(profile.FrameSample) = .init(gpa);
    try samples.ensureTotalCapacity(want);

    var drain: [4096]i16 = undefined;
    for (0..args.skip + want) |i| {
        con.runFrame();
        while (con.readAudio(&drain) != 0) {} // keep the ring from backing up
        const s = con.takeProfile() orelse continue;
        if (i >= args.skip) samples.appendAssumeCapacity(s);
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
        if (args.routines) {
            const rows = try routineRows(gpa, &con.prof);
            const total = attributedTotal(rows);
            const verdict = wramVerdict(topCodeRows(rows));
            try out.print(",\"stack_resets\":{},\"routines_dropped\":{},\"wram_verdict\":" ++
                "{{\"bytes\":{},\"pages\":{},\"fits_iram\":{},\"fits_bwram\":{}}},\"routines\":[", .{
                con.prof.stack_resets, con.prof.routines_dropped,
                verdict.union_bytes,   verdict.union_pages,
                verdict.fits_iram,     verdict.fits_bwram,
            });
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
    if (sum.stalls > 0) {
        try out.print("  stalls            {} ({} frames) — loads or transitions, not slowdown\n", .{
            sum.stalls, sum.stall_frames,
        });
        try out.print("  longest           {} frames, from frame {}\n", .{
            sum.longest_stall, sum.longest_stall_at,
        });
    }

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
                .main => try out.print("     {s:<10} {s:>9} {d:>14} {d:>6.1}% {s:>7} {d:>6.1}%\n", .{
                    "(main)", "-", r.self, pct(r.self, total), "-", pct(r.slow, r.self),
                }),
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

    // Everything a reader could over-trust, said out loud.
    try out.print(
        \\
        \\  Measured from the game's own attract/demo loop — no buttons were pressed.
        \\  Idle is WAI plus loops that change nothing, so a wait this misses reads as
        \\  work: utilisation is an UPPER bound. A game that polls the pad in its NMI
        \\  handler never registers a dropped frame at all, so slowdown is a LOWER
        \\  bound. The two errors bracket the truth; they do not compound.
        \\
    , .{});
    try out.flush();
}

const routine_rows_shown: usize = 16;

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
    // main -> B: touches $7E:1005 (same 256-byte page as A) and MMIO $4212.
    p.step(0x00_9006, cyc, false, null, null, .{ .kind = .call, .target = 0x00_B000, .sp_before = 0x1FF, .sp_after = 0x1FD });
    p.step(0x00_B000, cyc, false, 0x7E_1005, null, .{});
    p.step(0x00_B003, cyc, false, 0x00_4212, null, .{});
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

const iram_bytes: u32 = 2 * 1024;
const bwram_bytes: u32 = 256 * 1024;

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
    // POSIX-only otherwise; Windows decodes the command line from UTF-16 and
    // needs an allocator. Not deinit'd — the returned Args slice into it, and
    // `gpa` is the process arena.
    var it = try init.minimal.args.iterateAllocator(gpa);
    _ = it.skip(); // program name
    var out: Args = .{ .rom = undefined };
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
        } else if (std.mem.eql(u8, a, "--wav")) {
            out.wav = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--accurate")) {
            out.accuracy = .accurate;
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
        } else if (rom == null) {
            rom = a;
        } else return error.TooManyArgs;
    }
    out.rom = rom orelse return error.NoRom;
    return out;
}

/// Write interleaved stereo i16 samples as a 32 kHz PCM WAV.
fn writeWav(io: std.Io, path: []const u8, samples: []const i16) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    const wr = &fw.interface;

    const rate: u32 = @import("snes_core").timing.dsp_sample_hz;
    const data_len: u32 = @intCast(samples.len * 2);
    try wr.writeAll("RIFF");
    try wr.writeInt(u32, 36 + data_len, .little);
    try wr.writeAll("WAVEfmt ");
    try wr.writeInt(u32, 16, .little); // PCM chunk size
    try wr.writeInt(u16, 1, .little); // PCM
    try wr.writeInt(u16, 2, .little); // stereo
    try wr.writeInt(u32, rate, .little);
    try wr.writeInt(u32, rate * 4, .little); // byte rate
    try wr.writeInt(u16, 4, .little); // block align
    try wr.writeInt(u16, 16, .little); // bits per sample
    try wr.writeAll("data");
    try wr.writeInt(u32, data_len, .little);
    for (samples) |s| try wr.writeInt(i16, s, .little);
    try wr.flush();
}

/// Write an RGB565 framebuffer as a binary PPM (P6, 8-bit RGB).
fn writePpm(io: std.Io, path: []const u8, fb: []const u16, w: u32, h: u32) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    const wr = &fw.interface;

    try wr.print("P6\n{} {}\n255\n", .{ w, h });
    for (fb) |px| {
        const r5: u16 = (px >> 11) & 0x1F;
        const g6: u16 = (px >> 5) & 0x3F;
        const b5: u16 = px & 0x1F;
        const rgb = [3]u8{
            @intCast(r5 * 255 / 31),
            @intCast(g6 * 255 / 63),
            @intCast(b5 * 255 / 31),
        };
        try wr.writeAll(&rgb);
    }
    try wr.flush();
}
