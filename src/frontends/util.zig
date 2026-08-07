//! Shared helpers for the frontends and test runners: RGB565->RGB888
//! expansion, the PPM/WAV writers, the audio drain+hash loop, an
//! argv-iterator helper, and the SDL `--shot` write path.
//!
//! Imported by frontends and test runners ONLY — never by snes_core, which
//! must stay freestanding.

const std = @import("std");
const core = @import("snes_core");

/// Expand one RGB565 pixel to RGB888 by bit-replicating the 5/6-bit channels
/// into 8 bits, so white (0x1F/0x3F/0x1F) lands on 0xFF/0xFF/0xFF instead of
/// the 0xF8/0xFC/0xF8 a naive left-shift gives. This is the one expansion
/// used everywhere a framebuffer becomes 24-bit RGB — headless `--ppm` and
/// the SDL software `--shot` of the same frame are byte-identical because of
/// it.
pub fn expandPixel(px: u16) [3]u8 {
    const r5: u8 = @intCast((px >> 11) & 0x1F);
    const g6: u8 = @intCast((px >> 5) & 0x3F);
    const b5: u8 = @intCast(px & 0x1F);
    return .{
        (r5 << 3) | (r5 >> 2),
        (g6 << 2) | (g6 >> 4),
        (b5 << 3) | (b5 >> 2),
    };
}

test "expandPixel: 0 -> 0, max -> 255 per channel" {
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, expandPixel(0));
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, expandPixel(0xFFFF));
}

test "expandPixel: monotonic per channel" {
    var prev_r: u8 = 0;
    var r5: u16 = 0;
    while (r5 <= 0x1F) : (r5 += 1) {
        const r = expandPixel(r5 << 11)[0];
        try std.testing.expect(r >= prev_r);
        prev_r = r;
    }
    var prev_g: u8 = 0;
    var g6: u16 = 0;
    while (g6 <= 0x3F) : (g6 += 1) {
        const g = expandPixel(g6 << 5)[1];
        try std.testing.expect(g >= prev_g);
        prev_g = g;
    }
}

/// Expand a whole RGB565 framebuffer (w*h pixels) into a freshly allocated
/// RGB888 buffer.
pub fn expandFramebuffer(gpa: std.mem.Allocator, fb: []const u16, w: u32, h: u32) ![]u8 {
    const rgb = try gpa.alloc(u8, @as(usize, w) * @as(usize, h) * 3);
    for (fb[0 .. @as(usize, w) * @as(usize, h)], 0..) |px, i| {
        rgb[i * 3 ..][0..3].* = expandPixel(px);
    }
    return rgb;
}

/// Write already-expanded 24-bit RGB as a binary PPM (P6).
pub fn writePpm(io: std.Io, path: []const u8, w: u32, h: u32, rgb: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    const wr = &fw.interface;

    try wr.print("P6\n{d} {d}\n255\n", .{ w, h });
    try wr.writeAll(rgb);
    try wr.flush();
}

/// Expand an RGB565 framebuffer and write it as a PPM in one step — what
/// headless `--ppm` and the SDL software `--shot` path both want.
pub fn writeFramebufferPpm(gpa: std.mem.Allocator, io: std.Io, path: []const u8, fb: []const u16, w: u32, h: u32) !void {
    const rgb = try expandFramebuffer(gpa, fb, w, h);
    try writePpm(io, path, w, h, rgb);
}

/// Write interleaved stereo i16 samples as a 32 kHz PCM WAV.
pub fn writeWav(io: std.Io, path: []const u8, samples: []const i16) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    const wr = &fw.interface;

    const rate: u32 = core.timing.dsp_sample_hz;
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

/// Drain every frame's audio out of the console's ring (it holds ~15 frames,
/// so this must run every frame to avoid overrunning it) and fold it into a
/// running FNV-1a hash. `sink_ctx`/`sink`, if given, see each chunk before
/// it's overwritten — used to track peak amplitude, accumulate a WAV dump, or
/// forward samples to a live audio device. Pass `{}`/`null` to just drain and
/// hash.
pub fn drainAudio(
    con: anytype,
    hash: *u64,
    sink_ctx: anytype,
    comptime sink: ?fn (@TypeOf(sink_ctx), []const i16) anyerror!void,
) !void {
    var drain: [4096]i16 = undefined;
    while (true) {
        const n = con.readAudio(&drain);
        if (n == 0) break;
        hash.* = core.console.hashAudio(hash.*, drain[0..n]);
        if (sink) |f| try f(sink_ctx, drain[0..n]);
    }
}

/// Drain audio without hashing — for a replay pass whose hash is not
/// authoritative (rom_runner's post-snapshot half); the ring still has to be
/// kept from backing up.
pub fn drainAudioDiscard(con: anytype) void {
    var drain: [4096]i16 = undefined;
    while (con.readAudio(&drain) != 0) {}
}

// --- FastROM patch generation, verified in-emulator ---------------------------

/// Why a generation attempt produced no patch.
pub const GenFailure = union(enum) {
    /// The transform refused; see `core.patchgen.Reason.describe`.
    refused: core.patchgen.Refusal,
    /// First frame whose framebuffer hash diverged from the unpatched run —
    /// the faster bus changed something the player would see.
    frame_mismatch: u32,
    /// The 32 kHz audio streams diverged over the run.
    audio_mismatch,
    /// Frame at whose end MEMSEL read back disabled in the patched run: the
    /// game cleared it from a code path the baseline never exercised.
    memsel_lost: u32,
};

/// A generated, verified patch and its measured effect.
pub const GenOutcome = struct {
    /// The transformed image and the encoded BPS, both caller-owned.
    image: []u8,
    bps: []u8,
    stub_addr: u16,
    trampolines: u8,
    memsel_stores_nopped: u8,
    /// Profiled frames (after the skipped boot) in each run.
    frames: u32,
    /// The profiler's frame-budget summary, unpatched and patched. FastROM
    /// cuts ~2 master cycles from every ROM access, which shows up here as
    /// idle headroom — the proof the patch does something.
    base: core.profile.Summary,
    fast: core.profile.Summary,
};

const GenRun = struct {
    audio: u64,
    summary: core.profile.Summary,
    memsel_pcs: [core.profile.memsel_pc_cap]u24,
    n_memsel_pcs: usize,
    memsel_overflow: bool,
    /// Frame at whose end `bus.fastrom` was false, if any.
    fastrom_lost_at: ?u32,
};

/// One profiled run of `total` frames over `image`. When `expect` is null the
/// per-frame framebuffer hashes are recorded into `hashes`; otherwise each
/// frame is compared against it and the first divergence is returned in
/// `mismatch`.
fn genRun(
    gpa: std.mem.Allocator,
    image: []const u8,
    hashes: []u64,
    expect: ?[]const u64,
    skip: u32,
    buttons: u16,
    mismatch: *?u32,
) !GenRun {
    const total: u32 = @intCast(hashes.len);
    const cart = try core.Cartridge.load(gpa, image);
    const con = try gpa.create(core.ProfilingConsole);
    defer gpa.destroy(con);
    con.init(cart);
    defer gpa.free(con.cart.rom);

    const samples = try gpa.alloc(core.profile.FrameSample, total);
    defer gpa.free(samples);
    var n_samples: usize = 0;

    var audio: u64 = core.console.audio_hash_init;
    var fastrom_lost_at: ?u32 = null;
    for (0..total) |i| {
        if (buttons != 0) con.setButtons(0, buttons);
        con.runFrame();
        try drainAudio(con, &audio, {}, null);
        const h = core.console.hashFrame(con.framebuffer());
        hashes[i] = h;
        if (expect) |want| {
            if (h != want[i] and mismatch.* == null) {
                mismatch.* = @intCast(i);
                break;
            }
            if (!con.bus.fastrom and fastrom_lost_at == null)
                fastrom_lost_at = @intCast(i);
        }
        if (con.takeProfile()) |s| {
            if (i >= skip) {
                samples[n_samples] = s;
                n_samples += 1;
            }
        }
    }

    const scratch = try gpa.alloc(f64, n_samples);
    defer gpa.free(scratch);
    return .{
        .audio = audio,
        .summary = core.profile.summarise(samples[0..n_samples], scratch),
        .memsel_pcs = con.prof.memsel_pcs,
        .n_memsel_pcs = con.prof.n_memsel_pcs,
        .memsel_overflow = con.prof.memsel_overflow,
        .fastrom_lost_at = fastrom_lost_at,
    };
}

/// Generate the FastROM transformation of a copier-stripped `image` and
/// verify it in-emulator before encoding anything: the patched ROM must
/// render every one of `skip + frames` frames pixel-identical to the
/// unpatched ROM (boot included) and produce an identical audio stream — the
/// faster bus may change nothing the player sees or hears — and MEMSEL must
/// read enabled at every frame boundary of the patched run. MEMSEL stores the
/// baseline run observes are handed to the generator for neutralisation, so
/// the stock `STZ $420D` init idiom does not silently undo the patch.
///
/// On failure, `failure` names what went wrong and nothing is returned; a
/// patch that cannot be verified is a patch that does not get written.
pub fn generateFastromVerified(
    gpa: std.mem.Allocator,
    image: []const u8,
    frames: u32,
    skip: u32,
    buttons: u16,
    failure: *?GenFailure,
) !GenOutcome {
    const total = skip + frames;
    const hashes = try gpa.alloc(u64, total);
    defer gpa.free(hashes);
    const fast_hashes = try gpa.alloc(u64, total);
    defer gpa.free(fast_hashes);

    var no_mismatch: ?u32 = null;
    const base = try genRun(gpa, image, hashes, null, skip, buttons, &no_mismatch);

    var refusal: ?core.patchgen.Refusal = null;
    if (base.memsel_overflow) {
        failure.* = .{ .refused = .{ .reason = .memsel_store_unpatchable } };
        return error.GenFailed;
    }
    const res = core.patchgen.generate(gpa, image, .{
        .memsel_store_pcs = base.memsel_pcs[0..base.n_memsel_pcs],
    }, &refusal) catch |e| switch (e) {
        error.Refused => {
            failure.* = .{ .refused = refusal.? };
            return error.GenFailed;
        },
        else => return e,
    };
    errdefer gpa.free(res.image);

    var mismatch: ?u32 = null;
    const fast = try genRun(gpa, res.image, fast_hashes, hashes, skip, buttons, &mismatch);
    if (mismatch) |frame| {
        failure.* = .{ .frame_mismatch = frame };
        return error.GenFailed;
    }
    if (fast.fastrom_lost_at) |frame| {
        failure.* = .{ .memsel_lost = frame };
        return error.GenFailed;
    }
    if (fast.audio != base.audio) {
        failure.* = .audio_mismatch;
        return error.GenFailed;
    }

    const bps = try core.patch.writeBps(gpa, image, res.image);
    return .{
        .image = res.image,
        .bps = bps,
        .stub_addr = res.stub_addr,
        .trampolines = res.trampolines,
        .memsel_stores_nopped = res.memsel_stores_nopped,
        .frames = frames,
        .base = base.summary,
        .fast = fast.summary,
    };
}

/// argv with argv[0] already skipped: the boilerplate every frontend's arg
/// parser starts with. The allocator form (not `iterate()`) is used because
/// Windows decodes the command line from UTF-16 and needs one; `gpa` is
/// expected to be the process arena, so the caller need not free anything.
pub fn argIterator(init: std.process.Init, gpa: std.mem.Allocator) !std.process.Args.Iterator {
    var it = try init.minimal.args.iterateAllocator(gpa);
    _ = it.skip(); // program name
    return it;
}

/// Write a `--shot` capture as `<prefix>-<frame>.ppm`, already-expanded RGB.
/// Shared by the SDL GL and software paths so a write failure is reported —
/// and flushed — identically either way.
pub fn maybeShot(
    io: std.Io,
    gpa: std.mem.Allocator,
    err: *std.Io.Writer,
    prefix: []const u8,
    frame: u32,
    w: u32,
    h: u32,
    rgb: []const u8,
) !void {
    const path = try std.fmt.allocPrint(gpa, "{s}-{d:0>5}.ppm", .{ prefix, frame });
    writePpm(io, path, w, h, rgb) catch |e| {
        try err.print("shot failed: {s}\n", .{@errorName(e)});
    };
    try err.flush();
}
