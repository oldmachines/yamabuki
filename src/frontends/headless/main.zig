//! Headless runner: load a ROM, run N frames, print the framebuffer and audio
//! hashes, and optionally dump the final frame as a binary PPM (P6) and the
//! whole audio stream as a WAV, both for eyeballing.
//!
//!   yamabuki-headless <rom.sfc> [--frames N] [--ppm out.ppm] [--wav out.wav]
//!                     [--accurate] [--patch p.bps|p.ips] [--save-patched out.sfc]
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

const std = @import("std");
const core = @import("snes_core");

const Args = struct {
    rom: []const u8,
    frames: u32 = 1,
    ppm: ?[]const u8 = null,
    wav: ?[]const u8 = null,
    accuracy: core.Accuracy = .fast,
    patch: ?[]const u8 = null,
    save_patched: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const args = parseArgs(init, gpa) catch {
        try out.print("usage: yamabuki-headless <rom.sfc> [--frames N] [--ppm out.ppm] [--wav out.wav] [--accurate]\n" ++
            "                          [--patch p.bps|p.ips] [--save-patched out.sfc]\n", .{});
        try out.flush();
        std.process.exit(2);
    };

    var image = std.Io.Dir.cwd().readFileAlloc(io, args.rom, gpa, .limited(16 * 1024 * 1024)) catch {
        try out.print("error: cannot read ROM '{s}'\n", .{args.rom});
        try out.flush();
        std.process.exit(1);
    };

    if (args.patch) |patch_path| {
        image = applyPatch(io, gpa, out, image, patch_path) catch std.process.exit(1);
        if (args.save_patched) |save_path| {
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = save_path, .data = image }) catch {
                try out.print("error: cannot write '{s}'\n", .{save_path});
                try out.flush();
                std.process.exit(1);
            };
            try out.print("wrote {s} ({d} bytes)\n", .{ save_path, image.len });
            try out.flush();
            return;
        }
    } else if (args.save_patched != null) {
        try out.print("error: --save-patched needs --patch\n", .{});
        try out.flush();
        std.process.exit(2);
    }

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
    const stripped = core.header.stripCopierHeader(image);
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

fn parseArgs(init: std.process.Init, gpa: std.mem.Allocator) !Args {
    // POSIX-only otherwise; Windows decodes the command line from UTF-16 and
    // needs an allocator. Not deinit'd — the returned Args slice into it, and
    // `gpa` is the process arena.
    var it = try init.minimal.args.iterateAllocator(gpa);
    _ = it.skip(); // program name
    var rom: ?[]const u8 = null;
    var frames: u32 = 1;
    var ppm: ?[]const u8 = null;
    var wav: ?[]const u8 = null;
    var accuracy: core.Accuracy = .fast;
    var patch: ?[]const u8 = null;
    var save_patched: ?[]const u8 = null;
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
        } else if (std.mem.eql(u8, a, "--patch")) {
            patch = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--save-patched")) {
            save_patched = it.next() orelse return error.MissingValue;
        } else if (rom == null) {
            rom = a;
        } else return error.TooManyArgs;
    }
    return .{
        .rom = rom orelse return error.NoRom,
        .frames = frames,
        .ppm = ppm,
        .wav = wav,
        .accuracy = accuracy,
        .patch = patch,
        .save_patched = save_patched,
    };
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
