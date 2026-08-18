//! Cheat pokes: hold a byte at a chosen address, the way an Action Replay
//! does. One `--poke ADDR=VALUE` is applied after every executed frame, so
//! a value the game rewrites each frame is held rather than set once.
//!
//! Addresses are CPU-bus addresses, not RAM offsets, and that is the whole
//! design. A published cheat address like Gradius III's `7E0086` (the stage
//! index) names WRAM directly, but on an SA-1 window conversion that byte no
//! longer lives there — the low 8 KiB moved into BW-RAM behind the
//! `$6000-$7FFF` window, and writing `$7E:0086` would poke the abandoned
//! copy and do nothing at all. Going through the bus means the poke lands
//! wherever the address is actually mapped in THIS image, so the same
//! mechanism serves a stock ROM (`7E0086`) and a converted one (`006086`)
//! without either knowing about the other.
//!
//! Registers and unmapped addresses are refused rather than poked blind:
//! a cheat cannot model what an MMIO write does. `apply` reports how many
//! landed so a frontend can say so instead of failing silently.

const std = @import("std");

pub const max_pokes: usize = 32;

pub const Poke = struct {
    addr: u24,
    value: u8,
};

pub const ParseError = error{ MissingEquals, BadAddress, BadValue, TooMany };

/// Parse one `ADDR=VALUE` pair, both hexadecimal. `VALUE` is one byte; a
/// 16-bit quantity is two pokes, which keeps this honest about the fact
/// that the two halves are written independently.
pub fn parseOne(text: []const u8) ParseError!Poke {
    const eq = std.mem.indexOfScalar(u8, text, '=') orelse return error.MissingEquals;
    const addr = std.fmt.parseInt(u24, std.mem.trim(u8, text[0..eq], " "), 16) catch
        return error.BadAddress;
    const value = std.fmt.parseInt(u8, std.mem.trim(u8, text[eq + 1 ..], " "), 16) catch
        return error.BadValue;
    return .{ .addr = addr, .value = value };
}

/// Parse a comma-separated list into `out`, returning how many were stored.
pub fn parseList(text: []const u8, out: []Poke, already: usize) ParseError!usize {
    var n = already;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |one| {
        const t = std.mem.trim(u8, one, " ");
        if (t.len == 0) continue;
        if (n == out.len) return error.TooMany;
        out[n] = try parseOne(t);
        n += 1;
    }
    return n;
}

/// Hold every poke's value. Called after each executed frame; returns the
/// number that landed in writable memory.
pub fn apply(con: anytype, pokes: []const Poke) usize {
    var landed: usize = 0;
    for (pokes) |p| {
        if (con.poke8(p.addr, p.value)) landed += 1;
    }
    return landed;
}

// --- tests ---------------------------------------------------------------------

const testing = std.testing;

test "cheat: a poke pair parses as hex on both sides" {
    const p = try parseOne("7E0086=04");
    try testing.expectEqual(@as(u24, 0x7E0086), p.addr);
    try testing.expectEqual(@as(u8, 4), p.value);
    // A bare bank-0 address is as valid as a long one.
    const q = try parseOne("6086=ff");
    try testing.expectEqual(@as(u24, 0x6086), q.addr);
    try testing.expectEqual(@as(u8, 0xFF), q.value);
}

test "cheat: malformed pairs are refused, not guessed at" {
    try testing.expectError(error.MissingEquals, parseOne("7E0086"));
    try testing.expectError(error.BadAddress, parseOne("zz=01"));
    try testing.expectError(error.BadValue, parseOne("7E0086=100")); // >1 byte
    try testing.expectError(error.BadValue, parseOne("7E0086="));
}

test "cheat: a list fills in order and refuses to overflow" {
    var buf: [3]Poke = undefined;
    const n = try parseList("7E0086=01, 7E0087=02", &buf, 0);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u24, 0x7E0087), buf[1].addr);
    // Appending continues from `already` rather than restarting.
    const m = try parseList("1234=ab", &buf, n);
    try testing.expectEqual(@as(usize, 3), m);
    try testing.expectError(error.TooMany, parseList("5=1", &buf, m));
}

test "cheat: apply counts only the writes that landed" {
    // A stand-in console: the low half is writable memory, the high half is
    // "registers" that refuse the poke, exactly as the bus reports them.
    var mem: [4]u8 = @splat(0);
    const Fake = struct {
        m: *[4]u8,
        fn poke8(self: @This(), addr: u24, value: u8) bool {
            if (addr >= self.m.len) return false;
            self.m[addr] = value;
            return true;
        }
    };
    const fake: Fake = .{ .m = &mem };
    const pokes = [_]Poke{
        .{ .addr = 1, .value = 0xAA },
        .{ .addr = 9, .value = 0xBB }, // refused
        .{ .addr = 3, .value = 0xCC },
    };
    try testing.expectEqual(@as(usize, 2), apply(fake, &pokes));
    try testing.expectEqual(@as(u8, 0xAA), mem[1]);
    try testing.expectEqual(@as(u8, 0xCC), mem[3]);
}
