//! ROM runner: boot each golden ROM headless for a fixed number of frames and
//! compare against the committed baseline in `golden_hashes.zon` — the
//! framebuffer hash (correctness) plus the deterministic `steps`/`cycles` work
//! counts (perf regression; gated only once baselined, 0 = unset). Requires the
//! PeterLemon ROMs under test-data/snes-roms (tools/fetch_test_data.sh).
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
            const ok = runOne(io, gpa, out, dir, entry, frames) catch |e| blk: {
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
    entry: anytype,
    frames: u32,
) !bool {
    // The arena frees everything at process exit; the console owns the cart
    // (its page table points into cart.rom), so we must not free it here.
    const image = try dir.readFileAlloc(io, entry.path, gpa, .limited(16 * 1024 * 1024));
    const cart = try core.Cartridge.load(gpa, image);
    const con = try gpa.create(core.FastConsole);
    con.init(cart);

    for (0..frames) |_| con.runFrame();

    const got_hash = core.console.hashFrame(con.framebuffer());
    const got_steps = con.steps;
    const got_cycles = con.bus.clock;

    // Deterministic perf counts are gated only once baselined (0 = unset).
    const steps_ok = entry.steps == 0 or entry.steps == got_steps;
    const cycles_ok = entry.cycles == 0 or entry.cycles == got_cycles;
    const ok = got_hash == entry.hash and steps_ok and cycles_ok;

    try out.print("{s} {s}\n    hash   got {x:0>16} want {x:0>16}\n    steps  got {d:<10} want {d}\n    cycles got {d:<10} want {d}\n", .{
        if (ok) "PASS" else "FAIL", entry.path,
        got_hash,                   entry.hash,
        got_steps,                  entry.steps,
        got_cycles,                 entry.cycles,
    });
    return ok;
}
