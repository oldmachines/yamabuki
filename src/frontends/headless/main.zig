//! Headless runner: load a ROM, run N frames, print the framebuffer and audio
//! hashes, and optionally dump the final frame as a binary PPM (P6) and the
//! whole audio stream as a WAV, both for eyeballing.
//!
//!   yamabuki-headless <rom.sfc> [--frames N] [--ppm out.ppm] [--wav out.wav]
//!                     [--accurate]
//!
//! This is the primary in-development verification tool: `--ppm`/`--wav` give
//! output to inspect, and the printed hashes are what `zig build test-roms`
//! locks against.

const std = @import("std");
const core = @import("snes_core");

const Args = struct {
    rom: []const u8,
    frames: u32 = 1,
    ppm: ?[]const u8 = null,
    wav: ?[]const u8 = null,
    accuracy: core.Accuracy = .fast,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const args = parseArgs(init) catch {
        try out.print("usage: yamabuki-headless <rom.sfc> [--frames N] [--ppm out.ppm] [--wav out.wav] [--accurate]\n", .{});
        try out.flush();
        std.process.exit(2);
    };

    const image = std.Io.Dir.cwd().readFileAlloc(io, args.rom, gpa, .limited(16 * 1024 * 1024)) catch {
        try out.print("error: cannot read ROM '{s}'\n", .{args.rom});
        try out.flush();
        std.process.exit(1);
    };

    const cart = core.Cartridge.load(gpa, image) catch |e| {
        try out.print("error: cannot load ROM: {s}\n", .{@errorName(e)});
        try out.flush();
        std.process.exit(1);
    };

    const con = try gpa.create(core.AnyConsole);
    con.init(args.accuracy, cart);

    // Drain audio every frame (the ring holds ~15 frames); hash the stream
    // and keep it if a WAV dump was requested.
    var audio_hash = core.console.audio_hash_init;
    var audio_peak: u16 = 0;
    var audio_all: std.array_list.Managed(i16) = .init(gpa);
    var drain: [4096]i16 = undefined;
    for (0..args.frames) |_| {
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
        args.rom, args.frames, width, fb.len / width, hash, audio_hash, audio_peak,
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

fn parseArgs(init: std.process.Init) !Args {
    var it = init.minimal.args.iterate();
    _ = it.skip(); // program name
    var rom: ?[]const u8 = null;
    var frames: u32 = 1;
    var ppm: ?[]const u8 = null;
    var wav: ?[]const u8 = null;
    var accuracy: core.Accuracy = .fast;
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--frames")) {
            const v = it.next() orelse return error.MissingValue;
            frames = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, a, "--ppm")) {
            ppm = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--wav")) {
            wav = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--accurate")) {
            accuracy = .accurate;
        } else if (rom == null) {
            rom = a;
        } else return error.TooManyArgs;
    }
    return .{ .rom = rom orelse return error.NoRom, .frames = frames, .ppm = ppm, .wav = wav, .accuracy = accuracy };
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
