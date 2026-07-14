//! Headless FPS benchmark and deterministic perf-regression gate.
//!
//!   yamabuki-bench <rom.sfc> [--frames N]   run one ROM, print JSON (N = 600)
//!   yamabuki-bench --check                  run the committed baseline and
//!                                           fail on any deterministic drift
//!
//! `fps`/`ms` are wall-clock (machine-dependent, informational). `steps`,
//! `cycles`, and `vram_reads` are deterministic per-run work counts: the first
//! two are CPU/scheduler work, `vram_reads` is the renderer's VRAM word traffic
//! (only counted when the core is built with `-Dperf-counters`, which the bench
//! always is). `--check` gates all three against `bench/baseline.zon`, so a
//! memory-traffic regression — e.g. reverting the tile-row decode cache, which
//! shrinks `vram_reads` ~8x — turns CI red.

const std = @import("std");
const core = @import("snes_core");

const perf_enabled = @import("perf_options").enabled;

const RomBase = struct {
    path: []const u8,
    steps: u64,
    cycles: u64,
    vram_reads: u64,
};
const Baseline = struct {
    frames: u32,
    roms: []const RomBase,
};
const baseline: Baseline = @import("baseline.zon");

const rom_root = "test-data/snes-roms/";

/// One ROM run's deterministic work counts (plus informational wall-clock FPS).
const Counts = struct { steps: u64, cycles: u64, vram_reads: u64, fps: f64 };

fn runRom(io: std.Io, gpa: std.mem.Allocator, path: []const u8, frames: u32) !Counts {
    const image = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024));
    const cart = try core.Cartridge.load(gpa, image);
    const con = try gpa.create(core.FastConsole);
    con.init(cart);

    const t0 = std.Io.Clock.Timestamp.now(io, .awake);
    var sink: u64 = 0;
    for (0..frames) |_| {
        con.runFrame();
        sink ^= con.framebuffer()[0]; // keep the frame from being optimized away
    }
    const ns: i64 = @intCast(t0.untilNow(io).raw.nanoseconds);
    std.mem.doNotOptimizeAway(sink);

    return .{
        .steps = con.steps,
        .cycles = con.bus.clock,
        .vram_reads = con.bus.ppu.perf_vram_reads,
        .fps = @as(f64, @floatFromInt(frames)) / (@as(f64, @floatFromInt(ns)) / 1e9),
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    // The allocator form, not `iterate()`: Windows decodes the command line from
    // UTF-16 and needs one. (`gpa` is the process arena; the args outlive it.)
    var it = try init.minimal.args.iterateAllocator(gpa);
    _ = it.skip();
    var rom: ?[]const u8 = null;
    var frames: u32 = 600;
    var check = false;
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--frames")) {
            frames = std.fmt.parseInt(u32, it.next() orelse "600", 10) catch 600;
        } else if (std.mem.eql(u8, a, "--check")) {
            check = true;
        } else rom = a;
    }

    if (check) {
        try runCheck(io, gpa, out);
        return;
    }

    const rom_path = rom orelse {
        try out.print("usage: yamabuki-bench <rom.sfc> [--frames N] | --check\n", .{});
        try out.flush();
        std.process.exit(2);
    };

    const c = runRom(io, gpa, rom_path, frames) catch {
        try out.print("error: cannot run '{s}'\n", .{rom_path});
        try out.flush();
        std.process.exit(1);
    };
    try out.print(
        "{{\"rom\":\"{s}\",\"frames\":{},\"fps\":{d:.1}," ++
            "\"steps\":{},\"cycles\":{},\"vram_reads\":{}}}\n",
        .{ rom_path, frames, c.fps, c.steps, c.cycles, c.vram_reads },
    );
    try out.flush();
}

/// Run every ROM in the baseline and compare the deterministic counts. Prints a
/// row per ROM (with wall-clock FPS for information) and exits nonzero if any
/// count drifted from the committed value.
fn runCheck(io: std.Io, gpa: std.mem.Allocator, out: *std.Io.Writer) !void {
    if (!perf_enabled) {
        try out.print("error: --check needs -Dperf-counters (the `bench` step sets it)\n", .{});
        try out.flush();
        std.process.exit(2);
    }
    var failures: u32 = 0;
    try out.print("bench --check: {} ROMs, {} frames each\n", .{ baseline.roms.len, baseline.frames });
    for (baseline.roms) |b| {
        const path = try std.mem.concat(gpa, u8, &.{ rom_root, b.path });
        const c = runRom(io, gpa, path, baseline.frames) catch {
            try out.print("  MISS  {s}: cannot run (is test-data/snes-roms present?)\n", .{b.path});
            try out.flush();
            failures += 1;
            continue;
        };
        const ok = c.steps == b.steps and c.cycles == b.cycles and c.vram_reads == b.vram_reads;
        if (ok) {
            try out.print("  ok    {s}  ({d:.0} fps)\n", .{ b.path, c.fps });
        } else {
            failures += 1;
            try out.print("  DRIFT {s}\n", .{b.path});
            if (c.steps != b.steps) try out.print("          steps      {} != {}\n", .{ c.steps, b.steps });
            if (c.cycles != b.cycles) try out.print("          cycles     {} != {}\n", .{ c.cycles, b.cycles });
            if (c.vram_reads != b.vram_reads) try out.print("          vram_reads {} != {}\n", .{ c.vram_reads, b.vram_reads });
        }
        try out.flush();
    }
    if (failures != 0) {
        try out.print("bench --check: {} ROM(s) drifted\n", .{failures});
        try out.flush();
        std.process.exit(1);
    }
    try out.print("bench --check: all baselines match\n", .{});
    try out.flush();
}
