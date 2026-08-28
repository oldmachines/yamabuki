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

/// Parse a standard Action-Replay-style code: six hex digits of address
/// followed by two of value, e.g. `7E008604`. Codes are joined with `+` the
/// way published multi-part cheats are written (`7E021002+7E021201`).
///
/// A published code names WRAM directly, and on an SA-1 window conversion
/// that byte has MOVED — the low 8 KiB lives in BW-RAM now. So a code
/// pointing into the relocated range is stored TWICE, once at the published
/// address and once at its home in BW-RAM. Exactly one of the two is the
/// live copy; the other is inert (on a stock ROM the bus refuses the BW-RAM
/// write, and on a conversion the WRAM copy is abandoned memory nobody
/// reads). That is what lets a code copied off a cheat list work unmodified
/// on an image whose memory map we rearranged.
///
/// The caveat is narrow but real: on a genuine SA-1 cartridge — not one of
/// our conversions — BW-RAM below $2000 is the game's own data, and the
/// mirror would write into it. Use `--poke` for exact placement there.
pub fn parseCodes(text: []const u8, out: []Poke, already: usize) ParseError!usize {
    var n = already;
    var it = std.mem.splitScalar(u8, text, '+');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " ");
        if (t.len == 0) continue;
        if (t.len != 8) return error.BadAddress;
        const addr = std.fmt.parseInt(u24, t[0..6], 16) catch return error.BadAddress;
        const value = std.fmt.parseInt(u8, t[6..8], 16) catch return error.BadValue;
        if (n == out.len) return error.TooMany;
        out[n] = .{ .addr = addr, .value = value };
        n += 1;
        if (relocatedHome(addr)) |home| {
            if (n == out.len) return error.TooMany;
            out[n] = .{ .addr = home, .value = value };
            n += 1;
        }
    }
    return n;
}

/// Where a WRAM address ends up after window relocation, or null if the
/// address is not in the range that moves. Banks $7E/$7F re-bank to
/// $40/$41, and only the low 8 KiB moves — above that, WRAM stays put.
fn relocatedHome(addr: u24) ?u24 {
    const bank: u8 = @intCast(addr >> 16);
    const off: u16 = @truncate(addr);
    if (bank != 0x7E and bank != 0x7F) return null;
    if (bank == 0x7E and off >= 0x2000) return null;
    const home_bank: u24 = if (bank == 0x7E) 0x40 else 0x41;
    return (home_bank << 16) | off;
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

test "cheat: a published code is stored at its home as well as its address" {
    var buf: [4]Poke = undefined;
    const n = try parseCodes("7E008604", &buf, 0);
    // Two pokes: the published WRAM address, and where relocation moved it.
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u24, 0x7E0086), buf[0].addr);
    try testing.expectEqual(@as(u24, 0x400086), buf[1].addr);
    try testing.expectEqual(@as(u8, 4), buf[1].value);
}

test "cheat: multi-part codes split on +, and high WRAM is not mirrored" {
    var buf: [8]Poke = undefined;
    const n = try parseCodes("7E021002+7E021201", &buf, 0);
    try testing.expectEqual(@as(usize, 4), n); // two codes, each mirrored
    try testing.expectEqual(@as(u24, 0x400212), buf[3].addr);
    // Above the relocated 8 KiB, WRAM stays where it is: no mirror.
    var b2: [4]Poke = undefined;
    try testing.expectEqual(@as(usize, 1), try parseCodes("7E4000FF", &b2, 0));
    // $7F re-banks to $41, and all of it moves.
    try testing.expectEqual(@as(usize, 2), try parseCodes("7F000122", &b2, 0));
    try testing.expectEqual(@as(u24, 0x410001), b2[1].addr);
}

test "cheat: a malformed code is refused rather than half-read" {
    var buf: [4]Poke = undefined;
    try testing.expectError(error.BadAddress, parseCodes("7E00860", &buf, 0)); // 7 digits
    try testing.expectError(error.BadAddress, parseCodes("7E0086044", &buf, 0)); // 9 digits
    try testing.expectError(error.BadValue, parseCodes("7E0086zz", &buf, 0));
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
