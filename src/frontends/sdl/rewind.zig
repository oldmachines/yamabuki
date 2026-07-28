//! Hold-to-rewind: a ring of XOR+RLE save-state deltas.
//!
//! One full `latest` state is kept; every capture XORs the new state
//! against it and RLE-encodes the (overwhelmingly zero) difference into the
//! ring. Because XOR is its own inverse, the same delta steps either
//! direction — so there are no keyframes and no forward replay: rewinding
//! pops the newest delta, XORs it into `latest`, and loads that. Dropping
//! the *oldest* deltas when the budget fills is always safe because the
//! chain is anchored at the newest end.
//!
//! Costs, measured not guessed: a state is ~hundreds of KiB (printed at
//! session start), captures run at 30/s, and an idle frame's delta encodes
//! to a few hundred bytes — the default 64 MiB budget holds minutes of
//! typical play and ~2 min of worst-case constant full-state churn.

const std = @import("std");
const core = @import("snes_core");

/// Emulated frames between captures: 30 snapshots/s, and rewinding one
/// delta per displayed frame plays history backwards at ~real time.
pub const capture_interval: u32 = 2;

pub const Rewind = struct {
    gpa: std.mem.Allocator,
    /// The newest captured state; the ring's deltas hang off this anchor.
    latest: []u8,
    scratch: []u8,
    /// Newest at the end. Each entry is one RLE-encoded XOR delta.
    deltas: std.ArrayList([]u8) = .empty,
    /// Index of the oldest live entry (older slots already evicted).
    head: usize = 0,
    /// Total encoded bytes currently held.
    total: usize = 0,
    budget: usize,
    have_latest: bool = false,
    counter: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, budget_bytes: usize) !Rewind {
        return .{
            .gpa = gpa,
            .latest = try gpa.alloc(u8, core.AnyConsole.state_size),
            .scratch = try gpa.alloc(u8, core.AnyConsole.state_size),
            .budget = budget_bytes,
        };
    }

    /// Call once per emulated frame while running forward.
    pub fn onFrame(self: *Rewind, con: *core.AnyConsole) void {
        self.counter += 1;
        if (self.counter < capture_interval) return;
        self.counter = 0;
        _ = con.saveState(self.scratch);
        self.push(self.scratch) catch {};
    }

    /// One rewind step: restore the machine one capture back. False when
    /// history is exhausted.
    pub fn rewindStep(self: *Rewind, con: *core.AnyConsole) bool {
        if (!self.popLatest()) return false;
        con.loadState(self.latest) catch return false;
        return true;
    }

    /// History becomes garbage whenever the machine jumps to a state that
    /// did not evolve from `latest`: state load, reset, game close.
    pub fn clear(self: *Rewind) void {
        for (self.deltas.items[self.head..]) |d| self.gpa.free(d);
        self.deltas.clearRetainingCapacity();
        self.head = 0;
        self.total = 0;
        self.have_latest = false;
        self.counter = 0;
    }

    pub fn depth(self: *const Rewind) usize {
        return self.deltas.items.len - self.head;
    }

    /// Core of `onFrame`, on raw bytes so the tests need no console.
    pub fn push(self: *Rewind, state: []const u8) !void {
        std.debug.assert(state.len == self.latest.len);
        if (!self.have_latest) {
            @memcpy(self.latest, state);
            self.have_latest = true;
            return;
        }
        // Single pass: XOR into scratch-as-delta while latest becomes the
        // new state. (`state` may alias `scratch` — read before write.)
        // An identical state still pushes its (empty) delta: every capture
        // is one step of history, whatever happened during it.
        for (0..state.len) |i| {
            const x = state[i] ^ self.latest[i];
            self.latest[i] = state[i];
            self.scratch[i] = x;
        }
        const delta = try rleEncode(self.gpa, self.scratch);
        errdefer self.gpa.free(delta);
        try self.deltas.append(self.gpa, delta);
        self.total += delta.len;
        self.evict();
    }

    /// Pop the newest delta back into `latest`. False when empty.
    pub fn popLatest(self: *Rewind) bool {
        if (self.depth() == 0) return false;
        const delta = self.deltas.pop().?;
        rleApply(delta, self.latest);
        self.total -= delta.len;
        self.gpa.free(delta);
        return true;
    }

    fn evict(self: *Rewind) void {
        while (self.total > self.budget and self.depth() > 1) {
            const oldest = self.deltas.items[self.head];
            self.total -= oldest.len;
            self.gpa.free(oldest);
            self.head += 1;
        }
        // Compact the pointer array once the dead prefix dominates.
        if (self.head > 4096 and self.head > self.deltas.items.len / 2) {
            self.deltas.replaceRangeAssumeCapacity(0, self.head, &.{});
            self.head = 0;
        }
    }
};

// --- RLE codec -------------------------------------------------------------
// A delta is a sequence of (zero_run: u32 LE, literal_run: u32 LE,
// literal bytes) records covering the whole buffer. XOR deltas are almost
// all zeros, so this is compact without costing a real compressor's time.

fn rleEncode(gpa: std.mem.Allocator, xor: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 256);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < xor.len) {
        var zeros: usize = 0;
        while (i + zeros < xor.len and xor[i + zeros] == 0) zeros += 1;
        var lits: usize = 0;
        while (i + zeros + lits < xor.len and xor[i + zeros + lits] != 0) lits += 1;
        var hdr: [8]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], @intCast(zeros), .little);
        std.mem.writeInt(u32, hdr[4..8], @intCast(lits), .little);
        try out.writer.writeAll(&hdr);
        try out.writer.writeAll(xor[i + zeros ..][0..lits]);
        i += zeros + lits;
    }
    return out.toOwnedSlice();
}

/// XOR the delta into `buf` — one function for both directions, because
/// XOR is an involution.
fn rleApply(delta: []const u8, buf: []u8) void {
    var di: usize = 0;
    var bi: usize = 0;
    while (di < delta.len) {
        const zeros = std.mem.readInt(u32, delta[di..][0..4], .little);
        const lits = std.mem.readInt(u32, delta[di + 4 ..][0..4], .little);
        di += 8;
        bi += zeros;
        for (delta[di..][0..lits], 0..) |b, k| buf[bi + k] ^= b;
        di += lits;
        bi += lits;
    }
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "rle: roundtrip restores exactly, empty and dense alike" {
    const a = testing.allocator;
    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();

    const shapes = [_]usize{ 0, 1, 3, 100, 1000 };
    for (shapes) |n_changes| {
        var original: [4096]u8 = @splat(0);
        var xor: [4096]u8 = @splat(0);
        for (0..n_changes) |_| {
            xor[rand.uintLessThan(usize, xor.len)] = rand.int(u8);
        }
        const delta = try rleEncode(a, &xor);
        defer a.free(delta);

        // Applying once adds the delta; applying twice cancels it.
        var buf: [4096]u8 = @splat(0);
        rleApply(delta, &buf);
        try testing.expectEqualSlices(u8, &xor, &buf);
        rleApply(delta, &buf);
        try testing.expectEqualSlices(u8, &original, &buf);
    }
}

// A miniature "console" for history tests: push a sequence of states,
// rewind, and every intermediate must come back byte-identical.
test "rewind: history walks back through every pushed state" {
    const a = testing.allocator;
    var rw: Rewind = .{
        .gpa = a,
        .latest = try a.alloc(u8, 64),
        .scratch = try a.alloc(u8, 64),
        .budget = 1 << 20,
    };
    defer {
        rw.clear();
        rw.deltas.deinit(a);
        a.free(rw.latest);
        a.free(rw.scratch);
    }

    var prng = std.Random.DefaultPrng.init(99);
    const rand = prng.random();
    var states: [16][64]u8 = undefined;
    rand.bytes(&states[0]);
    for (1..16) |i| {
        states[i] = states[i - 1];
        // A handful of mutations per step, like a frame of emulation.
        for (0..4) |_| states[i][rand.uintLessThan(usize, 64)] = rand.int(u8);
    }
    for (&states) |*s| try rw.push(s);
    try testing.expectEqual(@as(usize, 15), rw.depth());

    var i: usize = 15;
    while (i > 0) : (i -= 1) {
        try testing.expectEqualSlices(u8, &states[i], rw.latest);
        try testing.expect(rw.popLatest());
    }
    try testing.expectEqualSlices(u8, &states[0], rw.latest);
    try testing.expect(!rw.popLatest()); // history exhausted, not a crash
}

test "rewind: the budget evicts oldest history but never the newest" {
    const a = testing.allocator;
    var rw: Rewind = .{
        .gpa = a,
        .latest = try a.alloc(u8, 256),
        .scratch = try a.alloc(u8, 256),
        // Small enough that a few dense deltas overflow it.
        .budget = 600,
    };
    defer {
        rw.clear();
        rw.deltas.deinit(a);
        a.free(rw.latest);
        a.free(rw.scratch);
    }

    var prng = std.Random.DefaultPrng.init(3);
    const rand = prng.random();
    var state: [256]u8 = @splat(0);
    try rw.push(&state); // anchor
    for (0..20) |_| {
        rand.bytes(&state); // dense delta every time
        try rw.push(&state);
    }
    // The budget held (evict keeps at least one delta), old history went,
    // and the newest state is exactly restorable from what remains.
    try testing.expect(rw.depth() >= 1);
    try testing.expect(rw.depth() < 20);
    try testing.expectEqualSlices(u8, &state, rw.latest);
    try testing.expect(rw.popLatest());
}

test "rewind: a rewound console is byte-identical to a straight run" {
    // The claim the whole feature rests on: popping k deltas leaves the
    // machine exactly where a fresh run of (30 - 2k) frames leaves it —
    // exact because emulation is deterministic. Uses a real ROM; skipped
    // when test-data is not fetched.
    const a = testing.allocator;
    const io = std.testing.io;
    const image = std.Io.Dir.cwd().readFileAlloc(
        io,
        "test-data/snes-roms/SPC700/Axel-F/Axel-F.sfc",
        a,
        .limited(4 << 20),
    ) catch return error.SkipZigTest;
    defer a.free(image);

    var cart = try core.Cartridge.load(a, image);
    defer cart.deinit(a);
    const con = try a.create(core.AnyConsole);
    defer a.destroy(con);
    con.init(.fast, cart);

    var rw = try Rewind.init(a, 8 << 20);
    defer {
        rw.clear();
        rw.deltas.deinit(a);
        a.free(rw.latest);
        a.free(rw.scratch);
    }
    for (0..30) |_| {
        con.runFrame();
        rw.onFrame(con);
    }

    const reference = try a.alloc(u8, core.AnyConsole.state_size);
    defer a.free(reference);
    var cart2 = try core.Cartridge.load(a, image);
    defer cart2.deinit(a);
    const con2 = try a.create(core.AnyConsole);
    defer a.destroy(con2);

    // Pop 2 deltas -> frame 26; pop 2 more -> frame 22. Each must equal a
    // straight run to that frame, byte for byte, and the console must
    // accept the restored state.
    for ([_]u32{ 26, 22 }) |target| {
        try testing.expect(rw.rewindStep(con));
        try testing.expect(rw.rewindStep(con));
        con2.init(.fast, cart2);
        for (0..target) |_| con2.runFrame();
        _ = con2.saveState(reference);
        try testing.expectEqualSlices(u8, reference, rw.latest);
        try testing.expectEqual(core.console.hashFrame(con2.framebuffer()), core.console.hashFrame(con.framebuffer()));
    }
}

test "rewind: clear forgets history and re-anchors" {
    const a = testing.allocator;
    var rw: Rewind = .{
        .gpa = a,
        .latest = try a.alloc(u8, 32),
        .scratch = try a.alloc(u8, 32),
        .budget = 1 << 16,
    };
    defer {
        rw.clear();
        rw.deltas.deinit(a);
        a.free(rw.latest);
        a.free(rw.scratch);
    }

    var s1: [32]u8 = @splat(1);
    var s2: [32]u8 = @splat(2);
    try rw.push(&s1);
    try rw.push(&s2);
    try testing.expectEqual(@as(usize, 1), rw.depth());
    rw.clear();
    try testing.expectEqual(@as(usize, 0), rw.depth());
    try testing.expect(!rw.popLatest());
    // The next push after clear is a fresh anchor, not a delta from stale
    // bytes.
    var s3: [32]u8 = @splat(3);
    try rw.push(&s3);
    try testing.expectEqual(@as(usize, 0), rw.depth());
    try testing.expectEqualSlices(u8, &s3, rw.latest);
}
