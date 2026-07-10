//! Headless FPS benchmark: run a fixed ROM for a fixed number of frames and
//! report frames/second as JSON. The emulation is deterministic, so this is a
//! pure throughput measure of the core.
//!
//!   yamabuki-bench <rom.sfc> [--frames N]   (default N = 600)

const std = @import("std");
const core = @import("snes_core");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var it = init.minimal.args.iterate();
    _ = it.skip();
    var rom: ?[]const u8 = null;
    var frames: u32 = 600;
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--frames")) {
            frames = std.fmt.parseInt(u32, it.next() orelse "600", 10) catch 600;
        } else rom = a;
    }
    const rom_path = rom orelse {
        try out.print("usage: yamabuki-bench <rom.sfc> [--frames N]\n", .{});
        try out.flush();
        std.process.exit(2);
    };

    const image = std.Io.Dir.cwd().readFileAlloc(io, rom_path, gpa, .limited(16 * 1024 * 1024)) catch {
        try out.print("error: cannot read '{s}'\n", .{rom_path});
        try out.flush();
        std.process.exit(1);
    };
    const cart = try core.Cartridge.load(gpa, image);
    const con = try gpa.create(core.FastConsole);
    con.init(cart);

    const t0 = std.Io.Clock.Timestamp.now(io, .awake);
    var sink: u64 = 0;
    for (0..frames) |_| {
        con.runFrame();
        sink ^= con.framebuffer()[0]; // keep the frame from being optimized away
    }
    const elapsed = t0.untilNow(io);
    const ns: i64 = @intCast(elapsed.raw.nanoseconds);

    const secs = @as(f64, @floatFromInt(ns)) / 1e9;
    const fps = @as(f64, @floatFromInt(frames)) / secs;
    try out.print(
        "{{\"rom\":\"{s}\",\"frames\":{},\"ms\":{d:.2},\"fps\":{d:.1},\"sink\":{}}}\n",
        .{ rom_path, frames, secs * 1000.0, fps, sink & 1 },
    );
    try out.flush();
}
