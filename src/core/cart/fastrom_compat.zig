//! The auto-FastROM compatibility list: which games are known to survive
//! MEMSEL being pinned to 1 (`patches/fastrom-compat.zon`).
//!
//! Auto-FastROM is opt-in twice over — the flag, then this list. `ok` entries
//! were verified (identical framebuffer hash over a long run, flag on vs
//! off); `broken` entries refuse with their reason; anything else is
//! `untested` and runs behind a loud warning. The default for an unknown
//! game is a warning rather than a refusal because the option is already an
//! explicit flag — but it is a warning the user is meant to read.

const std = @import("std");

pub const Status = enum { ok, broken, untested };

pub const Entry = struct {
    /// Lowercase hex sha256 of the copier-stripped ROM.
    sha256: []const u8,
    title: []const u8,
    status: Status,
    note: []const u8,
};

const List = struct {
    roms: []const Entry,
};

pub const list: List = @import("fastrom_compat.zon");

/// Look the loaded ROM up; null means "not listed" (treat as untested).
pub fn find(sha256_hex: []const u8) ?*const Entry {
    for (list.roms) |*e| {
        if (std.ascii.eqlIgnoreCase(e.sha256, sha256_hex)) return e;
    }
    return null;
}

// --- tests -------------------------------------------------------------------

test "every committed entry is well-formed" {
    try std.testing.expect(list.roms.len >= 3);
    for (list.roms) |e| {
        try std.testing.expectEqual(@as(usize, 64), e.sha256.len);
        for (e.sha256) |c| try std.testing.expect(std.ascii.isHex(c));
        try std.testing.expect(e.title.len > 0);
        try std.testing.expect(e.note.len > 0);
    }
    for (list.roms, 0..) |a, i| {
        for (list.roms[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.sha256, b.sha256));
        }
    }
}

test "find hits case-insensitively and misses to untested" {
    const e = list.roms[0];
    var upper: [64]u8 = undefined;
    for (e.sha256, 0..) |c, i| upper[i] = std.ascii.toUpper(c);
    try std.testing.expectEqual(@as(?*const Entry, &list.roms[0]), find(&upper));
    try std.testing.expectEqual(
        @as(?*const Entry, null),
        find("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"),
    );
}
