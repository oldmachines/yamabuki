//! ROM runner: boot each golden ROM headless for a fixed number of frames and
//! compare the framebuffer hash against the committed value in
//! `golden_hashes.zon`. Requires the PeterLemon ROMs under
//! test-data/snes-roms (tools/fetch_test_data.sh).
//!
//! Options (see build.zig): -Drom-filter=<substr>  -Drom-frames=<n>

const std = @import("std");
const core = @import("snes_core");
const options = @import("rom_options");

const golden = @import("golden_hashes.zon");
const rom_root = "test-data/snes-roms";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var dir = std.Io.Dir.cwd().openDir(io, rom_root, .{}) catch {
        try out.print("error: {s} missing; run tools/fetch_test_data.sh first\n", .{rom_root});
        try out.flush();
        std.process.exit(2);
    };
    defer dir.close(io);

    const frames: u32 = if (options.frames != 0) options.frames else golden.frames;
    var run: u32 = 0;
    var failed: u32 = 0;

    inline for (golden.roms) |entry| {
        const skip = if (options.filter) |f|
            std.mem.indexOf(u8, entry.path, f) == null
        else
            false;
        if (!skip) {
            run += 1;
            const ok = runOne(io, gpa, out, dir, entry.path, entry.hash, frames) catch |e| blk: {
                try out.print("ERROR {s}: {s}\n", .{ entry.path, @errorName(e) });
                break :blk false;
            };
            if (!ok) failed += 1;
        }
    }

    try out.print("\nrom-runner: {} ROMs, {} failed ({} frames each)\n", .{ run, failed, frames });
    try out.flush();
    if (failed > 0) std.process.exit(1);
}

fn runOne(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    dir: std.Io.Dir,
    path: []const u8,
    want: u64,
    frames: u32,
) !bool {
    // The arena frees everything at process exit; the console owns the cart
    // (its page table points into cart.rom), so we must not free it here.
    const image = try dir.readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024));
    const cart = try core.Cartridge.load(gpa, image);
    const con = try gpa.create(core.FastConsole);
    con.init(cart);
    return runHashed(con, out, path, want, frames);
}

fn runHashed(con: *core.FastConsole, out: *std.Io.Writer, path: []const u8, want: u64, frames: u32) !bool {
    for (0..frames) |_| con.runFrame();
    const got = core.console.hashFrame(con.framebuffer());
    const ok = got == want;
    try out.print("{s} {s} (got {x:0>16}, want {x:0>16})\n", .{
        if (ok) "PASS" else "FAIL", path, got, want,
    });
    return ok;
}
