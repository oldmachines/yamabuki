//! Headless runner: load a ROM, run N frames, print the framebuffer hash, and
//! optionally dump the final frame as a binary PPM (P6) for eyeballing.
//!
//!   yamabuki-headless <rom.sfc> [--frames N] [--ppm out.ppm]
//!
//! This is the primary in-development verification tool: `--ppm` gives a picture
//! to inspect, and the printed hash is what `zig build test-roms` locks against.

const std = @import("std");
const core = @import("snes_core");

const Args = struct {
    rom: []const u8,
    frames: u32 = 1,
    ppm: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const args = parseArgs(init) catch {
        try out.print("usage: yamabuki-headless <rom.sfc> [--frames N] [--ppm out.ppm]\n", .{});
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

    const con = try gpa.create(core.FastConsole);
    con.init(cart);

    for (0..args.frames) |_| con.runFrame();

    const fb = con.framebuffer();
    const width = con.frameWidth();
    const hash = core.console.hashFrame(fb);
    try out.print("{s}: {} frames, {}x{}, hash={x:0>16}\n", .{
        args.rom, args.frames, width, fb.len / width, hash,
    });
    try out.flush();

    if (args.ppm) |path| {
        try writePpm(io, path, fb, width, @intCast(fb.len / width));
        try out.print("wrote {s}\n", .{path});
        try out.flush();
    }
}

fn parseArgs(init: std.process.Init) !Args {
    var it = init.minimal.args.iterate();
    _ = it.skip(); // program name
    var rom: ?[]const u8 = null;
    var frames: u32 = 1;
    var ppm: ?[]const u8 = null;
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--frames")) {
            const v = it.next() orelse return error.MissingValue;
            frames = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, a, "--ppm")) {
            ppm = it.next() orelse return error.MissingValue;
        } else if (rom == null) {
            rom = a;
        } else return error.TooManyArgs;
    }
    return .{ .rom = rom orelse return error.NoRom, .frames = frames, .ppm = ppm };
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
