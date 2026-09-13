//! Movie replay plumbing: loading a take and its sidecars, anchoring and feeding it, seeding a converted image, the audio/energy sinks.
//!
//! Carved out of main.zig as pure code motion; every declaration
//! here is re-exported from main.zig, which stays the root.

const core = @import("snes_core");
const profile = core.profile;
const std = @import("std");
const util = @import("util");
const root_mod = @import("../main.zig");

const Args = root_mod.Args;
const saveRegion = root_mod.saveRegion;
/// A take's `.start.srm` sidecar into a fresh console, before any anchor
/// state: every surface replay the generator or the verifier makes must
/// start from the save the take was recorded on. MEASURED without this:
/// the save-anchored per-poll surfaces replayed from a save-less power-on
/// on BOTH machines (the title screen and the attract), their walls never
/// drifted, and the wide gate "passed" them — vacuously.
pub fn applySidecar(con: anytype, mov: ?util.movie.Movie) void {
    const m = mov orelse return;
    const data = m.start_srm orelse return;
    _ = loadSaveBytes(con.bus.cart, data);
}

/// Drop a battery save into the save region: zero it, then the file's
/// bytes at the front (a smaller chip's save in a larger region reads back
/// through the game's own mirroring). False when nothing takes it.
pub fn loadSaveBytes(cart: anytype, data: []const u8) bool {
    const region = saveRegion(cart) orelse return false;
    if (data.len == 0 or data.len > region.len) return false;
    @memset(region, 0);
    @memcpy(region[0..data.len], data);
    return true;
}

/// `--srm`, then the movie's start-save sidecar: the save chip as the take
/// began. Runs before the anchor, which (when there is one) overrides it.
pub fn applyStartSave(io: std.Io, gpa: std.mem.Allocator, con: anytype, args: Args, mov: ?util.movie.Movie, out: *std.Io.Writer) !void {
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

/// Load a .ymv and refuse every mismatch that would make the replay a lie:
/// wrong image (CRC of the stripped, post-patch image), wrong core accuracy,
/// or a conflicting explicit --region. Exits with a message rather than
/// returning an error — a bad movie is a usage problem, not a crash.
pub fn loadMovie(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    args: Args,
    path: []const u8,
    image: []const u8,
) util.movie.Movie {
    const fail = struct {
        pub fn f(o: *std.Io.Writer) noreturn {
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

/// `--state`: resume from an SDL-player save state instead of power-on —
/// which lets the profiler measure a scene the attract demo never reaches
/// (a slowdown-heavy stage the player save-stated, say) without replaying
/// a movie to get there. The state must be from the same image and core;
/// the serializer's own container checks refuse anything else.
pub fn loadStateInto(
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
pub fn seedConverted(
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

pub fn anchorMovie(con: anytype, mov: ?util.movie.Movie, what: []const u8, out: *std.Io.Writer) !void {
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

/// Feed frame `i` of a movie into a console — both ports, released past the
/// movie's end. A no-op without a movie.
pub fn feedMovie(con: anytype, mov: ?util.movie.Movie, i: usize) void {
    const m = mov orelse return;
    const f: [2]u16 = if (i < m.frames.len) m.frames[i] else .{ 0, 0 };
    con.setButtons(0, f[0]);
    con.setButtons(1, f[1]);
}

/// The `drainAudio` sink for the SA-1 gate's runs: fold each chunk into the
/// current frame's energy cell, building the per-frame envelope the
/// audio-tolerant tier compares.
pub const EnergySink = struct {
    cell: *u64,

    pub fn add(self: EnergySink, chunk: []const i16) anyerror!void {
        var sum: u64 = 0;
        for (chunk) |s| sum += @abs(s);
        self.cell.* += sum;
    }
};

/// The `drainAudio` sink for the main run loop: track peak amplitude always,
/// and accumulate samples for a WAV dump when one was requested.
pub const AudioSink = struct {
    peak: *u16,
    wav: ?*std.array_list.Managed(i16),

    pub fn collect(self: AudioSink, chunk: []const i16) !void {
        for (chunk) |s| self.peak.* = @max(self.peak.*, @abs(s));
        if (self.wav) |w| try w.appendSlice(chunk);
    }
};
