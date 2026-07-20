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
