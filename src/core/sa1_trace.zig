//! SA-1-side execution instrumentation: the sibling of the S-CPU's
//! frame-budget profiler and coverage map, for the one question the
//! offload ladder could not answer from the S-CPU side —
//! **what does the SA-1 actually execute, and on what state?**
//!
//! The generator's pointer offload runs a rewritten COPY of a routine on
//! the SA-1. When verification diverges, the S-CPU side can prove the
//! routine ran (its marshalled exit registers land in the I-RAM mailbox)
//! but not which path it took through the body. This records exactly
//! that:
//!
//! - **Coverage**: a per-byte execution count over a window of the SA-1's
//!   address space, so "which instructions of the copy ever ran" is a
//!   direct read — the branch never taken has count 0. Bounded to
//!   `window_cap` bytes, which comfortably covers an offloaded body.
//! - **A register ring**: the most recent instructions inside the window
//!   with their entry register state, so the branch that WAS taken can be
//!   read back with the values that decided it.
//!
//! Attached the same way the coverage map is (an optional pointer the
//! profiling frontend sets), so a shipped build carries one predictable
//! null test per SA-1 instruction and nothing else — and the SA-1 only
//! steps at all on a cart that has one.

const std = @import("std");

/// Bytes of address space the coverage window spans. An offloaded body is
/// capped at 1 KiB by the eligibility walk, so this covers one whole
/// routine plus its stubs.
pub const window_cap = 2048;

/// Most recent in-window instructions kept with full register state.
pub const ring_cap = 64;

pub const Rec = struct {
    pc: u24,
    /// The 16-bit accumulator (B:A) as the instruction saw it.
    c: u16,
    x: u16,
    y: u16,
    d: u16,
    dbr: u8,
    p: u8,
};

pub const Trace = struct {
    /// Window base; instructions in [lo, lo + window_cap) are recorded.
    lo: u24 = 0,
    /// Per-byte execution counts across the window.
    counts: [window_cap]u32 = @splat(0),
    /// Ring of the most recent in-window instructions.
    ring: [ring_cap]Rec = undefined,
    /// Total in-window instructions seen (the ring holds the last
    /// `min(total, ring_cap)` of them).
    total: u64 = 0,
    /// In-window instructions executed outside the ring's reach, kept so
    /// a caller can say "N ran" without walking the counts.
    distinct: u32 = 0,

    pub fn init(lo: u24) Trace {
        return .{ .lo = lo };
    }

    /// Record one instruction about to execute. Hot path: one compare
    /// against the window before anything is written.
    pub fn note(self: *Trace, pc: u24, c: u16, x: u16, y: u16, d: u16, dbr: u8, p: u8) void {
        const off = pc -% self.lo;
        if (off >= window_cap) return;
        if (self.counts[off] == 0) self.distinct += 1;
        self.counts[off] +|= 1;
        self.ring[@intCast(self.total % ring_cap)] = .{
            .pc = pc,
            .c = c,
            .x = x,
            .y = y,
            .d = d,
            .dbr = dbr,
            .p = p,
        };
        self.total += 1;
    }

    /// Did the SA-1 ever execute the instruction at `pc`?
    pub fn ran(self: *const Trace, pc: u24) bool {
        const off = pc -% self.lo;
        return off < window_cap and self.counts[off] != 0;
    }

    pub fn countAt(self: *const Trace, pc: u24) u32 {
        const off = pc -% self.lo;
        return if (off < window_cap) self.counts[off] else 0;
    }

    /// The ring in execution order, oldest first — `buf` must hold
    /// `ring_cap` records; the returned slice borrows it.
    pub fn recent(self: *const Trace, buf: *[ring_cap]Rec) []const Rec {
        const n: usize = @intCast(@min(self.total, ring_cap));
        const start: usize = if (self.total <= ring_cap) 0 else @intCast(self.total % ring_cap);
        for (0..n) |i| buf[i] = self.ring[(start + i) % ring_cap];
        return buf[0..n];
    }
};

const testing = std.testing;

test "trace: window filtering, counts, and the ring's execution order" {
    var t = Trace.init(0x8000);
    // Outside the window: ignored entirely.
    t.note(0x7FFF, 0, 0, 0, 0, 0, 0);
    t.note(0x8000 + window_cap, 0, 0, 0, 0, 0, 0);
    try testing.expectEqual(@as(u64, 0), t.total);
    try testing.expectEqual(@as(u32, 0), t.distinct);

    // Inside: counted per byte, distinct counted once.
    t.note(0x8000, 1, 0, 0, 0, 0, 0);
    t.note(0x8000, 2, 0, 0, 0, 0, 0);
    t.note(0x8010, 3, 0, 0, 0, 0, 0);
    try testing.expectEqual(@as(u64, 3), t.total);
    try testing.expectEqual(@as(u32, 2), t.distinct);
    try testing.expectEqual(@as(u32, 2), t.countAt(0x8000));
    try testing.expect(t.ran(0x8010));
    try testing.expect(!t.ran(0x8020));

    var buf: [ring_cap]Rec = undefined;
    const recent = t.recent(&buf);
    try testing.expectEqual(@as(usize, 3), recent.len);
    try testing.expectEqual(@as(u16, 1), recent[0].c);
    try testing.expectEqual(@as(u16, 3), recent[2].c);
}

test "trace: the ring keeps the most recent records once it wraps" {
    var t = Trace.init(0);
    for (0..ring_cap + 5) |i| t.note(@intCast(i), @intCast(i), 0, 0, 0, 0, 0);
    var buf: [ring_cap]Rec = undefined;
    const recent = t.recent(&buf);
    try testing.expectEqual(@as(usize, ring_cap), recent.len);
    // Oldest kept is record #5; newest is the last written.
    try testing.expectEqual(@as(u16, 5), recent[0].c);
    try testing.expectEqual(@as(u16, ring_cap + 4), recent[ring_cap - 1].c);
}
