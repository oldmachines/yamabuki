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
    /// Stage S2: print the relocation plan — the WRAM -> I-RAM/BW-RAM
    /// allocation map for the conversion verdict's hot set.
    plan: bool = false,
    /// `--wide N` (M12): extra columns rendered on each side of the standard
    /// 256, for a widescreen game patch (e.g. wide-snes) that draws into the
    /// margin. Fast core only — refused together with `--accurate`.
    wide: u32 = 0,
    /// A recorded playthrough (.ymv) driving both pads from power-on. In a
    /// normal run it replays and verifies the movie's end hashes; in the
    /// generator/report modes it drives the profiled runs, so coverage and
    /// verification come from real gameplay instead of the attract mode.
    movie: ?[]const u8 = null,
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
    /// Where to write the generated patch. Default: `<rom>.bps` next to the
    /// ROM — the softpatch convention every frontend picks up by name.
    gen_out: ?[]const u8 = null,
};

/// Default frames to profile: 60 seconds at 60 Hz, on top of the skipped boot.
const report_frames_default: u32 = 3600;

/// Default frames for `--gen-fastrom-patch` verification: 30 seconds, the
/// same standard patches/fastrom-compat.zon entries are verified to.
const gen_frames_default: u32 = 1800;

pub fn main(init: std.process.Init) !void {
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
            \\  --movie f     replay a recorded playthrough (.ymv, recorded in the SDL player)
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
            \\  --whole-game  with --gen-sa1-patch: whole-game migration (SA-1 Root) — the game
            \\                executes entirely on the SA-1, the S-CPU becomes an MMIO service
            \\                loop; needs the WRAM working set inside I-RAM's identity window
            \\                and refuses by name when it cannot prove the move
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

    // The movie identifies itself against the image AS PLAYED (post
    // soft-patching): loaded here, after the patch stage, and checked
    // against the same stripped image the run will use.
    var mov: ?util.movie.Movie = null;
    if (args.movie) |mpath| mov = loadMovie(io, gpa, out, args, mpath, core.header.stripCopierHeader(image));

    if (args.gen_fastrom) {
        try runGenerate(io, gpa, out, args, core.header.stripCopierHeader(image), mov);
        return;
    }
    if (args.gen_sa1) {
        try runSa1Gen(io, gpa, out, args, core.header.stripCopierHeader(image), mov);
        return;
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

    // Drain audio every frame (the ring holds ~15 frames); hash the stream
    // and keep it if a WAV dump was requested.
    var audio_hash = core.console.audio_hash_init;
    var audio_peak: u16 = 0;
    var audio_all: std.array_list.Managed(i16) = .init(gpa);
    const frames = args.frames orelse if (mov) |m| @as(u32, @intCast(m.frames.len)) else 1;
    for (0..frames) |i| {
        if (mov) |m| {
            const f: [2]u16 = if (i < m.frames.len) m.frames[i] else .{ 0, 0 };
            con.setButtons(0, f[0]);
            con.setButtons(1, f[1]);
        }
        con.runFrame();
        try util.drainAudio(con, &audio_hash, AudioSink{
            .peak = &audio_peak,
            .wav = if (args.wav != null) &audio_all else null,
        }, AudioSink.collect);
        // The frame the movie ends on is the one its hashes describe.
        if (mov) |m| if (i + 1 == m.frames.len) {
            if (m.end_frame_hash == 0) {
                try out.print("movie: {} frames replayed (no end hashes recorded — sync unverified)\n", .{m.frames.len});
            } else {
                const fh = core.console.hashFrame(con.framebuffer());
                const audio_ok = m.end_audio_hash == 0 or audio_hash == m.end_audio_hash;
                if (fh == m.end_frame_hash and audio_ok) {
                    try out.print("movie: sync verified — {} frames replayed, end hashes match\n", .{m.frames.len});
                } else {
                    try out.print(
                        "movie: DESYNC at end of replay — frame hash {x:0>16} (movie {x:0>16}), audio {s}\n",
                        .{ fh, m.end_frame_hash, if (audio_ok) "ok" else "diverged" },
                    );
                    try out.flush();
                    std.process.exit(1);
                }
            }
        };
    }

    const fb = con.framebuffer();
    const width = con.frameWidth();
    const hash = core.console.hashFrame(fb);
    try out.print("{s}: {} frames, {}x{}, hash={x:0>16}, audio={x:0>16} (peak {})\n", .{
        args.rom, frames, width, fb.len / width, hash, audio_hash, audio_peak,
    });
    try out.flush();

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
    const m = util.movie.parse(gpa, bytes) catch |e| {
        out.print("error: '{s}' is not a valid movie: {s}\n", .{ path, @errorName(e) }) catch {};
        fail(out);
    };
    const crc = util.movie.imageCrc(image);
    if (m.rom_crc != crc) {
        out.print(
            "error: movie '{s}' was recorded on image crc32 {x:0>8}; this run plays {x:0>8}\n" ++
                "       (the movie identifies the image as played — a soft-patched game needs the same --patch)\n",
            .{ path, m.rom_crc, crc },
        ) catch {};
        fail(out);
    }
    const acc: u8 = if (args.accuracy == .accurate) 1 else 0;
    if (m.accuracy != acc) {
        out.print("error: movie '{s}' was recorded on the {s} core; this run uses the {s} core\n", .{
            path,
            if (m.accuracy == 1) "accurate" else "fast",
            if (acc == 1) "accurate" else "fast",
        }) catch {};
        fail(out);
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
                    try out.print("refused: {s}\n", .{r.reason.describe()});
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
    mov: ?util.movie.Movie,
) !void {
    const frames = args.frames orelse if (mov) |m|
        @max(1, @as(u32, @intCast(m.frames.len)) -| args.skip)
    else
        gen_frames_default;
    const total = args.skip + frames;
    try out.print("baseline (profiled) + verify runs, {} frames each...\n", .{total});
    try out.flush();

    // Baseline ONCE: per-frame hashes, audio (hash + per-frame energy
    // envelope), the profile, and the coverage map the rewriter walks.
    // Every verification attempt below replays against this.
    const env_base = try gpa.alloc(u64, total);
    @memset(env_base, 0);
    const env_conv = try gpa.alloc(u64, total);
    const hashes = try gpa.alloc(u64, total);
    const conv_hashes = try gpa.alloc(u64, total);
    const ub = try gpa.alloc(u8, core.usage_map.cpu_map_len);
    @memset(ub, 0);
    const umap: core.usage_map.UsageMap = .{ .bytes = ub };
    var samples: std.array_list.Managed(profile.FrameSample) = .init(gpa);
    try samples.ensureTotalCapacity(total);
    var base_audio = core.console.audio_hash_init;
    // Coverage growth: how much code the profile was STILL discovering in
    // the last tenth of the capture. Every conversion failure measured so
    // far traces back to code the rewriter never saw, so this turns "the
    // capture might be too short" from a caveat into a number.
    var cov_early: u32 = 0;
    const cov_mark: usize = total - total / 10;
    const cart = try core.Cartridge.load(gpa, image);
    const con = try gpa.create(core.ProfilingConsole);
    con.init(cart);
    con.usage = &umap;
    for (0..total) |i| {
        if (i == cov_mark) cov_early = core.usage_map.countOpcodes(ub);
        feedMovie(con, mov, i);
        con.runFrame();
        try util.drainAudio(con, &base_audio, EnergySink{ .cell = &env_base[i] }, EnergySink.add);
        hashes[i] = core.console.hashFrame(con.framebuffer());
        if (con.takeProfile()) |smp| {
            if (i >= args.skip) samples.appendAssumeCapacity(smp);
        }
    }
    const scratch = try gpa.alloc(f64, samples.items.len);
    const sum = profile.summarise(samples.items, scratch);
    const cov_total = core.usage_map.countOpcodes(ub);
    const cov_late = cov_total - cov_early;

    // The verdict, plan, and candidate set are fixed by the baseline; only
    // the candidate FILTER changes across bisect attempts.
    var conv: profile.Conversion = undefined;
    var plan: profile.Plan = undefined;
    var cands: [profile.conversion_set_max]core.sa1gen.Candidate = undefined;
    var n_cands: usize = 0;
    var neighbours: []const core.sa1gen.Candidate = &.{};
    if (!args.whole_game) {
        conv = profile.assessConversion(&con.prof, sum.verdict);
        plan = profile.planRelocation(&con.prof, conv);
        for (conv.entries[0..conv.n], 0..) |e, i| {
            cands[i] = .{ .entry = e };
            if (con.prof.routineInfo(e)) |r| {
                cands[i].pages = r.wram_pages;
                cands[i].self_cycles = r.self_cycles;
                cands[i].calls = r.calls;
            }
        }
        n_cands = conv.n;
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
            });
        }
        neighbours = nb.items;
    }

    // The auto-bisect loop: convert, verify, and on a failure that an
    // offloaded routine could explain, diagnose (first divergent frame +
    // a WRAM diff attributed against the offloads' working sets), drop
    // the culprit, and retry. The loop terminates: every retry removes
    // one offloaded routine, and a failure with none left is terminal.
    var dropped: [profile.conversion_set_max]u24 = undefined;
    var dropped_why: [profile.conversion_set_max][]const u8 = undefined;
    var n_dropped: usize = 0;
    var conv_samples: std.array_list.Managed(profile.FrameSample) = .init(gpa);
    try conv_samples.ensureTotalCapacity(total);

    while (true) {
        // Candidates minus the dropped culprits.
        var act: [profile.conversion_set_max]core.sa1gen.Candidate = undefined;
        var n_act: usize = 0;
        for (cands[0..n_cands]) |c| {
            const is_dropped = for (dropped[0..n_dropped]) |d| {
                if (d == c.entry) break true;
            } else false;
            if (!is_dropped) {
                act[n_act] = c;
                n_act += 1;
            }
        }

        var refusal: ?core.sa1gen.Refusal = null;
        const converted: core.sa1gen.Error!core.sa1gen.Result = if (args.whole_game)
            core.sa1gen.convertWholeGame(gpa, image, ub, &refusal)
        else
            core.sa1gen.convert(gpa, image, &plan, ub, act[0..n_act], neighbours, &refusal);
        const res = converted catch |e| switch (e) {
            error.Refused => {
                try out.print("refused: {s}\n", .{refusal.?.reason.describe()});
                try out.flush();
                std.process.exit(1);
            },
            else => return e,
        };

        // The verify run for this attempt.
        @memset(env_conv, 0);
        var fast_audio = core.console.audio_hash_init;
        conv_samples.clearRetainingCapacity();
        {
            const cart2 = try core.Cartridge.load(gpa, res.image);
            const con2 = try gpa.create(core.ProfilingConsole);
            con2.init(cart2);
            for (0..total) |i| {
                feedMovie(con2, mov, i);
                con2.runFrame();
                try util.drainAudio(con2, &fast_audio, EnergySink{ .cell = &env_conv[i] }, EnergySink.add);
                conv_hashes[i] = core.console.hashFrame(con2.framebuffer());
                if (con2.takeProfile()) |smp| {
                    if (i >= args.skip) conv_samples.appendAssumeCapacity(smp);
                }
            }
            con2.cart.deinit(gpa);
            gpa.destroy(con2);
        }
        const conv_scratch = try gpa.alloc(f64, conv_samples.items.len);
        const conv_sum = profile.summarise(conv_samples.items, conv_scratch);

        // Stage-S4 gate, three tiers: strict identity; frames identical
        // with envelope-equivalent audio; equivalent modulo timing with a
        // non-negative lag improvement.
        const equiv = util.framesEquivalent(hashes, conv_hashes);
        var fail_why: []const u8 = "";
        var fail_frame: u32 = 0;
        const passed: ?SaTier = switch (equiv) {
            .identical => blk: {
                if (fast_audio == base_audio) break :blk .strict;
                if (util.audioEnvelopeMismatch(env_base, env_conv)) |bad| {
                    fail_why = "audio envelope diverged (a sound moved, silenced, or invented)";
                    fail_frame = bad;
                    break :blk null;
                }
                break :blk .envelope;
            },
            .equivalent => blk: {
                if (conv_sum.lag_frames > sum.lag_frames) {
                    fail_why = "same pictures but MORE dropped frames — a regression";
                    break :blk null;
                }
                break :blk .equivalent;
            },
            .divergent => blk: {
                fail_why = "renders pictures the original never showed";
                fail_frame = firstDiff(hashes, conv_hashes);
                break :blk null;
            },
        };

        if (passed) |tier| {
            // Success: write the patch and the report.
            try reportSa1(io, gpa, out, args, image, res, tier, total, sum, conv_sum, dropped[0..n_dropped], dropped_why[0..n_dropped], cov_total, cov_late);
            return;
        }

        // Failure. Terminal when no offloaded routine could explain it.
        if (args.whole_game or res.stats.offload_count == 0) {
            try out.print("verification FAILED: {s}", .{fail_why});
            if (equiv != .equivalent) try out.print(" (first at frame {})", .{fail_frame});
            try out.print(".\n  No patch written.\n", .{});
            if (equiv == .identical) try printEnvelopeDiag(out, env_base, env_conv, fail_frame, total);
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

        // Diagnose and drop a culprit, then go around again.
        const culprit = try diagnoseCulprit(gpa, out, image, res, cands[0..n_cands], mov, equiv, fail_frame, fail_why, ub);
        dropped[n_dropped] = culprit;
        dropped_why[n_dropped] = fail_why;
        n_dropped += 1;
        try out.print("  auto-bisect: dropping offload $00:{x:0>4} and retrying ({} attempt(s) so far)\n", .{ culprit, n_dropped });
        try out.flush();
    }
}

/// Which S4 tier a successful SA-1 conversion verified under.
const SaTier = enum { strict, envelope, equivalent };

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
    for (0..n) |i| {
        feedMovie(con, mov, i);
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
    for (0..n) |i| {
        feedMovie(con, mov, i);
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

    try out.print("wrote {s} ({} bytes)\n\n", .{ path, bps.len });
    if (args.whole_game) {
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
fn runReport(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    args: Args,
    cart: core.Cartridge,
    mov: ?util.movie.Movie,
) !void {
    const want = args.frames orelse if (mov) |m|
        @max(1, @as(u32, @intCast(m.frames.len)) -| args.skip)
    else
        report_frames_default;

    const con = try gpa.create(core.ProfilingConsole);
    con.init(cart);
    if (args.auto_fastrom) con.bus.enableAutoFastrom();

    // Coverage wants the boot code too, so the map is attached before the
    // skipped frames run, not after.
    var umap: core.usage_map.UsageMap = undefined;
    if (args.usage_map_out != null) {
        const bytes = try gpa.alloc(u8, core.usage_map.cpu_map_len);
        @memset(bytes, 0);
        umap = .{ .bytes = bytes };
        con.usage = &umap;
    }

    var samples: std.array_list.Managed(profile.FrameSample) = .init(gpa);
    try samples.ensureTotalCapacity(want);

    var drain: [4096]i16 = undefined;
    for (0..args.skip + want) |i| {
        feedMovie(con, mov, i);
        con.runFrame();
        while (con.readAudio(&drain) != 0) {} // keep the ring from backing up
        const s = con.takeProfile() orelse continue;
        if (i >= args.skip) samples.appendAssumeCapacity(s);
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
    if (args.movie) |path| {
        try out.print(
            \\
            \\  Replayed {s} — real recorded input, so this is gameplay rather than a demo.
            \\
        , .{path});
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

const routine_rows_shown: usize = 16;

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
    var it = try util.argIterator(init, gpa);
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
        } else if (std.mem.eql(u8, a, "--usage-map")) {
            out.usage_map_out = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--plan")) {
            out.plan = true;
        } else if (std.mem.eql(u8, a, "--wide")) {
            const v = it.next() orelse return error.MissingValue;
            out.wide = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, a, "--movie")) {
            out.movie = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--gen-fastrom-patch")) {
            out.gen_fastrom = true;
        } else if (std.mem.eql(u8, a, "--gen-sa1-patch")) {
            out.gen_sa1 = true;
        } else if (std.mem.eql(u8, a, "--whole-game")) {
            out.whole_game = true;
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
    return out;
}
