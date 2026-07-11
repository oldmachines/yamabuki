//! SingleStepTests SPC700 harness.
//!
//! Runs the JSON test vectors from https://github.com/SingleStepTests/spc700
//! (fetched into test-data/sst-spc700 by tools/fetch_test_data.sh) against
//! the SPC700 core on a mock bus. Register/memory accuracy is the pass gate;
//! cycle-count parity is reported as a separate metric (cycle-position
//! comparison belongs to the accurate-core milestone). The vectors treat the
//! whole 64 KiB as flat RAM ($F0-$FF included), which matches the mock.
//!
//! Options (see build.zig): -Dsst-filter=<substr>  -Dsst-sample=<n>

const std = @import("std");
const core = @import("snes_core");
const options = @import("sst_options");
const Smp = core.spc700.Smp;

const MockBus = struct {
    mem: []u8, // 64 KiB ARAM-like flat space
    dirty: std.ArrayList(u32),
    cycles: u32,

    pub fn read8(self: *MockBus, addr: u16) u8 {
        self.cycles += 1;
        return self.mem[addr];
    }

    pub fn write8(self: *MockBus, addr: u16, value: u8) void {
        self.cycles += 1;
        self.mem[addr] = value;
        self.dirty.appendBounded(addr) catch unreachable;
    }

    pub fn idle(self: *MockBus) void {
        self.cycles += 1;
    }

    fn set(self: *MockBus, addr: u32, value: u8) void {
        self.mem[addr] = value;
        self.dirty.appendBounded(addr) catch unreachable;
    }

    fn resetDirty(self: *MockBus) void {
        for (self.dirty.items) |addr| self.mem[addr] = 0;
        self.dirty.clearRetainingCapacity();
        self.cycles = 0;
    }
};

const SstState = struct {
    pc: u16,
    a: u8,
    x: u8,
    y: u8,
    sp: u8,
    psw: u8,
    ram: [][2]u32,
};

const SstCase = struct {
    name: []const u8,
    initial: SstState,
    final: SstState,
    cycles: []std.json.Value,
};

const FileResult = struct {
    cases: u32 = 0,
    failed: u32 = 0,
    cycle_mismatch: u32 = 0,
};

fn loadRegs(smp: anytype, s: *const SstState) void {
    smp.regs = .{
        .a = s.a,
        .x = s.x,
        .y = s.y,
        .sp = s.sp,
        .pc = s.pc,
        .psw = s.psw,
    };
    smp.state = .running;
}

fn runFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    dir: std.Io.Dir,
    name: []const u8,
    bus: *MockBus,
    smp: *Smp(MockBus),
    max_failures_to_print: *u32,
) !FileResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try dir.readFileAlloc(io, name, arena, .limited(256 * 1024 * 1024));
    const parsed = try std.json.parseFromSliceLeaky([]SstCase, arena, text, .{
        .ignore_unknown_fields = true,
    });

    var result: FileResult = .{};
    const limit: usize = if (options.sample == 0) parsed.len else @min(options.sample, parsed.len);

    for (parsed[0..limit]) |*case| {
        bus.resetDirty();
        for (case.initial.ram) |entry| bus.set(entry[0], @intCast(entry[1]));
        loadRegs(smp, &case.initial);

        smp.step();

        var ok = smp.regs.pc == case.final.pc and
            smp.regs.sp == case.final.sp and
            smp.regs.psw == case.final.psw and
            smp.regs.a == case.final.a and
            smp.regs.x == case.final.x and
            smp.regs.y == case.final.y;
        var bad_ram: ?[2]u32 = null;
        for (case.final.ram) |entry| {
            if (bus.mem[entry[0]] != entry[1]) {
                ok = false;
                bad_ram = .{ entry[0], entry[1] };
                break;
            }
        }

        result.cases += 1;
        if (!ok) {
            result.failed += 1;
            if (max_failures_to_print.* > 0) {
                max_failures_to_print.* -= 1;
                try out.print("FAIL {s} \"{s}\"\n", .{ name, case.name });
                try out.print(
                    "  got  pc={x:0>4} sp={x:0>2} psw={x:0>2} a={x:0>2} x={x:0>2} y={x:0>2}\n",
                    .{ smp.regs.pc, smp.regs.sp, smp.regs.psw, smp.regs.a, smp.regs.x, smp.regs.y },
                );
                try out.print(
                    "  want pc={x:0>4} sp={x:0>2} psw={x:0>2} a={x:0>2} x={x:0>2} y={x:0>2}\n",
                    .{ case.final.pc, case.final.sp, case.final.psw, case.final.a, case.final.x, case.final.y },
                );
                if (bad_ram) |br| {
                    try out.print("  ram[{x:0>4}]: got {x:0>2} want {x:0>2}\n", .{ br[0], bus.mem[br[0]], br[1] });
                }
                try out.flush();
            }
        } else if (bus.cycles != case.cycles.len) {
            result.cycle_mismatch += 1;
        }
    }
    return result;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var bus: MockBus = .{
        .mem = try gpa.alloc(u8, 1 << 16),
        .dirty = try .initCapacity(gpa, 4096),
        .cycles = 0,
    };
    @memset(bus.mem, 0);
    var smp = Smp(MockBus).init(&bus);

    var dir = std.Io.Dir.cwd().openDir(io, "test-data/sst-spc700/v1", .{ .iterate = true }) catch {
        try out.print("error: test-data/sst-spc700 missing; run tools/fetch_test_data.sh first\n", .{});
        try out.flush();
        std.process.exit(2);
    };
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (options.filter) |f| {
            if (std.mem.indexOf(u8, entry.name, f) == null) continue;
        }
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    if (names.items.len == 0) {
        try out.print("error: no test files matched\n", .{});
        try out.flush();
        std.process.exit(2);
    }

    var total: FileResult = .{};
    var failing_files: std.ArrayList([]const u8) = .empty;
    var print_budget: u32 = 6;
    for (names.items) |name| {
        const r = try runFile(gpa, io, out, dir, name, &bus, &smp, &print_budget);
        total.cases += r.cases;
        total.failed += r.failed;
        total.cycle_mismatch += r.cycle_mismatch;
        if (r.failed > 0) try failing_files.append(gpa, name);
    }

    if (failing_files.items.len > 0) {
        try out.print("\nfailing files:", .{});
        for (failing_files.items) |name| try out.print(" {s}", .{name});
        try out.print("\n", .{});
    }
    const files_with_failures: u32 = @intCast(failing_files.items.len);

    try out.print(
        "\nsst-spc700: {} files, {} cases, {} failed ({} files), {} cycle-count mismatches\n",
        .{ names.items.len, total.cases, total.failed, files_with_failures, total.cycle_mismatch },
    );
    try out.flush();
    if (total.failed > 0) std.process.exit(1);
}
