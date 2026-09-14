//! Super Metroid's data-pointer classes, re-banked by walking the game's own tables instead of waiting for a surface to load each state: room-state level pointers, BG records, decompressor inline destinations, the tileset table, enemy headers, the area-map table, pointer seeds. Evidence-gated; every pass has its own unit test.
//!
//! Carved out of sa1gen.zig as pure code motion; every declaration here is
//! re-exported from sa1gen.zig, which stays the module's public root.

const std = @import("std");
const sa1gen = @import("../sa1gen.zig");
const testing = std.testing;

const demirrorQueueBankImms = sa1gen.demirrorQueueBankImms;
const put = sa1gen.put;
/// Super Metroid's room-state level-data pointers, re-banked by walking the
/// room graph instead of waiting for a surface to load each state.
///
/// Every room state carries a 3-byte pointer to its compressed level data,
/// and every one of them names MB2 ($C2-$CE). Under the >2 MiB shim MB2
/// lives $20 lower, so the byte must become $A2-$AE — and the only pass
/// that does that is `hi_proven`, which needs the profile to have watched
/// the loader read that exact byte. A state no surface ever loaded keeps
/// its stock bank, the decompressor ($80:B0FF) reads the wrong megabyte,
/// and the room arrives with no geometry at all: Samus walks through walls
/// into a phantom special block and Super Metroid's own `BRA *` assertion
/// at $84:B3A6 (measured 2026-09-02 on the Ceres escape states). One build
/// had 40 such bytes proven against ~750 untouched — every room past the
/// first door off the landing site.
///
/// No shape identifies the byte on its own (a `$CD` after a word is common
/// in a bank of tables), but the structure that reaches it is exact and
/// finite: door headers ($83) name rooms ($8F); a room's condition list
/// names its states; a state's first three bytes are the pointer. The walk
/// starts at the landing site and follows doors until it runs out. It is
/// all-or-nothing on the rewrite side: any state that fails validation
/// refuses the whole pass, because a misparse here rewrites data. A door
/// whose destination does not look like a room header is skipped, not
/// fatal — elevators and one-way transitions name no room.
///
/// Reads STOCK bytes (`image`); a bank byte `hi_proven` already re-banked
/// in `out` is left as it is.
pub const SmRoomWalk = struct {
    rooms: u32 = 0,
    states: u32 = 0,
    rebanked: u32 = 0,
    /// Background (library) records processed, and their source banks
    /// de-mirrored (see the BG pass in `rebankSmRoomLevelPointers`).
    bg_records: u32 = 0,
    bg_banks: u32 = 0,
    /// Non-zero when the pass refused: the $8F address of the header that
    /// failed validation. Nothing was rewritten.
    refused_at: u32 = 0,
};

pub fn smConditionArgBytes(cond: u16) ?u8 {
    // Each condition routine's skip path is `INX` x (args + 2) / `RTS`; these
    // widths are read off those routines in bank $8F.
    return switch (cond) {
        0xE5EB => 2, // entered through door X
        0xE612, 0xE629 => 1, // boss bit / event bit in the current area
        0xE5FF, 0xE640, 0xE652, 0xE669, 0xE678 => 0,
        else => null,
    };
}

pub fn rebankSmRoomLevelPointers(gpa: std.mem.Allocator, image: []const u8, out: []u8) !SmRoomWalk {
    const f8f: usize = 0x0F * 0x8000; // bank $8F: room + state headers
    const f83: usize = 0x03 * 0x8000; // bank $83: door headers
    var walk: SmRoomWalk = .{};
    if (image.len < f8f + 0x8000) return walk;
    const R = struct {
        img: []const u8,
        pub fn b(self: @This(), base: usize, a16: u32) u8 {
            return self.img[base + (a16 - 0x8000)];
        }
        pub fn w(self: @This(), base: usize, a16: u32) u16 {
            return std.mem.readInt(u16, self.img[base + (a16 - 0x8000) ..][0..2], .little);
        }
        pub fn looksLikeRoom(self: @This(), a16: u32) bool {
            if (a16 < 0x8000 or a16 > 0xFFFF - 0x0B - 2) return false;
            const area = self.b(f8f, a16 + 1);
            const wd = self.b(f8f, a16 + 4);
            const ht = self.b(f8f, a16 + 5);
            return area < 8 and wd >= 1 and wd <= 16 and ht >= 1 and ht <= 16 and self.w(f8f, a16 + 9) >= 0x8000;
        }
    };
    const r: R = .{ .img = image };

    const visited = try gpa.alloc(bool, 0x8000);
    defer gpa.free(visited);
    @memset(visited, false);
    var queue: [1024]u16 = undefined;
    var qn: usize = 0;
    var states: [2048]u32 = undefined;
    var sn: usize = 0;

    // Two roots, because the door graph has two components: Zebes hangs
    // off the landing site, and Ceres is entered by the new-game warp and
    // left by the escape warp — no door crosses between them. A root that
    // does not parse as a room is skipped (a different revision), not fatal.
    for ([_]u16{ 0x91F8, 0xDF45 }) |root| {
        if (!r.looksLikeRoom(root) or visited[root - 0x8000]) continue;
        visited[root - 0x8000] = true;
        queue[qn] = root;
        qn += 1;
    }
    if (qn == 0) return walk;

    var qi: usize = 0;
    while (qi < qn) : (qi += 1) {
        const room: u32 = queue[qi];
        walk.rooms += 1;
        // Condition list -> states, then the inline default state.
        var p: u32 = room + 11;
        var guard: u8 = 0;
        while (true) : (guard += 1) {
            if (guard > 16 or p > 0xFFFF - 2) {
                walk.refused_at = room;
                return walk;
            }
            const cond = r.w(f8f, p);
            if (cond == 0xE5E6) {
                if (sn == states.len) {
                    walk.refused_at = room;
                    return walk;
                }
                states[sn] = p + 2;
                sn += 1;
                break;
            }
            const nargs = smConditionArgBytes(cond) orelse {
                walk.refused_at = room;
                return walk;
            };
            const st = r.w(f8f, p + 2 + nargs);
            if (st < 0x8000 or sn == states.len) {
                walk.refused_at = room;
                return walk;
            }
            states[sn] = st;
            sn += 1;
            p += 2 + @as(u32, nargs) + 2;
        }
        // Door list: words naming door headers in $83, ended by whatever
        // follows (the next room header's index/area word is < $8000).
        var d: u32 = r.w(f8f, room + 9);
        var di: u8 = 0;
        while (di < 32 and d <= 0xFFFF - 1) : ({
            di += 1;
            d += 2;
        }) {
            const dp = r.w(f8f, d);
            if (dp < 0x8000 or dp > 0xFFFF - 12) break;
            const dest = r.w(f83, dp);
            if (dest == 0) continue; // elevator / no room
            if (!r.looksLikeRoom(dest)) continue;
            if (visited[dest - 0x8000]) continue;
            visited[dest - 0x8000] = true;
            if (qn == queue.len) {
                walk.refused_at = room;
                return walk;
            }
            queue[qn] = dest;
            qn += 1;
        }
    }
    walk.states = @intCast(sn);

    // Validate every state before touching a byte: level pointer into
    // MB2's ROM half, tileset index in range.
    for (states[0..sn]) |st| {
        if (st > 0xFFFF - 26) {
            walk.refused_at = st;
            return walk;
        }
        const lo = r.w(f8f, st);
        const bk = r.b(f8f, st + 2);
        const tileset = r.b(f8f, st + 3);
        if (lo < 0x8000 or bk < 0xC2 or bk > 0xCE or tileset >= 0x1D) {
            walk.refused_at = st;
            return walk;
        }
    }
    for (states[0..sn]) |st| {
        const f = f8f + (st - 0x8000) + 2;
        if (out[f] != image[f]) continue; // hi_proven got here first
        out[f] -= 0x20;
        walk.rebanked += 1;
    }

    // Each state also names a BACKGROUND (library) record at +$16 — a DMA
    // list that paints BG2. Its source banks are the same evidence-gated
    // class as the level pointer: a record no surface loaded keeps its stock
    // banks and the DMA reads the wrong megabyte, so the room renders correct
    // foreground over garbage background (measured 2026-09-02 on the Parlor,
    // $92FD; a three-byte hand-patch of this record's banks made it clean).
    // Unlike the level pointer this pass is PER-RECORD graceful, not
    // all-or-nothing: a state's BG word legitimately points at code or
    // nothing, so a record that does not parse as a clean list is skipped,
    // never fatal — exactly the door-walk's "names no room" rule. The list's
    // command widths are read off Super Metroid's own BG interpreter.
    for (states[0..sn]) |st| {
        const bg = r.w(f8f, st + 0x16);
        if (bg < 0x8000 or bg > 0xFFF0) continue;
        const ok = rebankSmBgRecord(image, out, bg, &walk);
        if (ok) walk.bg_records += 1;
    }
    return walk;
}

/// Walk one Super Metroid background (library) record and de-mirror the
/// source bank of every copy command. Returns false — translating nothing —
/// the instant the bytes stop looking like a BG list (an unknown command, an
/// out-of-range source bank, or no terminator within the cap), so a state
/// whose +$16 points at code or data is left untouched. Widths are Super
/// Metroid's: $0002 src+dest+size (7), $0004 src+dest (5), $0008 (7), $000A
/// (2), $000C (2), $000E src+3 words (9), $0000 ends. Only $0002/$0004/$0008/
/// $000E carry a 3-byte source at payload +0; its bank is payload byte 2.
pub fn rebankSmBgRecord(image: []const u8, out: []u8, ptr: u16, walk: *SmRoomWalk) bool {
    const f8f: usize = 0x0F * 0x8000;
    var pending: [64]usize = undefined; // byte offsets staged for translation
    var np: usize = 0;
    var a: u32 = ptr;
    var steps: u8 = 0;
    while (steps < 64) : (steps += 1) {
        if (a + 2 > 0x1_0000) return false;
        const cmd = std.mem.readInt(u16, image[f8f + (a - 0x8000) ..][0..2], .little);
        if (cmd == 0x0000) {
            // A clean list. Commit the staged source banks now — nothing was
            // written while the parse could still fail.
            for (pending[0..np]) |f| {
                if (out[f] != image[f]) continue; // hi_proven got here first
                const bank = out[f];
                out[f] = if (bank >= 0xC0 and bank <= 0xDF)
                    bank - 0x20
                else if (bank >= 0xA0 and bank <= 0xBF)
                    bank - 0x80
                else
                    bank - 0x3E; // $7E/$7F -> $40/$41
                walk.bg_banks += 1;
            }
            return true;
        }
        const payload: u32 = switch (cmd) {
            0x0002, 0x0008 => 7,
            0x0004 => 5,
            0x000A, 0x000C => 2,
            0x000E => 9,
            else => return false,
        };
        if (cmd == 0x0002 or cmd == 0x0004 or cmd == 0x0008 or cmd == 0x000E) {
            const bf = a + 2 + 2; // command word, then source lo/hi, then bank
            if (bf >= 0x1_0000) return false;
            const bank = image[f8f + (bf - 0x8000)];
            // A real source bank is WRAM or ROM; anything else means a
            // misparse, and we must not translate the byte we mistook.
            if (!(bank == 0x7E or bank == 0x7F or (bank >= 0x80 and bank <= 0xDF))) return false;
            if ((bank == 0x7E or bank == 0x7F or (bank >= 0xA0 and bank <= 0xDF)) and np < pending.len) {
                pending[np] = f8f + (bf - 0x8000);
                np += 1;
            }
        }
        a += 2 + payload;
    }
    return false; // no terminator within the cap — not a list we understand
}

pub const SmInlineDests = struct {
    /// `JSL $80:B0FF` sites whose inline destination names WRAM ($7E/$7F).
    sites: u32 = 0,
    /// Of those, the bank bytes this pass re-banked ($7E/$7F -> $40/$41).
    rebanked: u32 = 0,
};

/// Super Metroid's decompressor, `JSL $80:B0FF`, takes its DESTINATION as a
/// 3-byte long pointer sitting INLINE in the code stream right after the
/// JSL: the routine pulls the return address, reads the pointer through it
/// and advances the return by 3. That pointer is data — nothing executes
/// it — so relocation-by-execution cannot see it; the profiler proves a
/// site only when a recording drives that exact call and traces the byte
/// into a $7E store. Measured 2026-09-03: v38 had the door-transition
/// tileset loader's sites proven and the load-game loader's raw
/// ($82:EAF5/$82:EB06 — the same loads, on the path the Ceres escape takes
/// to Zebes). The tileset's tile table then decompressed into REAL WRAM
/// $7E:A800 while the game read the stale table at $40:A800, so every room
/// whose tileset first loads through that path painted the previous
/// tileset's blocks ($9A44: correct geometry, wrong textures). Stock has 63
/// sites, v38 left 29 raw; a hand patch of those 29 bank bytes made the
/// room pixel-correct. Same class as the room-state level pointer and the
/// background record: a bank byte a structure carries.
///
/// Signature-validated: the four JSL bytes, then an inline bank of $7E/$7F.
/// Any other bank — a ROM destination, or data that merely spells the JSL
/// — is left untouched; a byte `hi_proven` already re-banked in `out` is
/// left alone.
pub fn rebankSmDecompInlineDests(image: []const u8, out: []u8) SmInlineDests {
    var r: SmInlineDests = .{};
    if (image.len < 7) return r;
    const sig = [_]u8{ 0x22, 0xFF, 0xB0, 0x80 }; // JSL $80:B0FF
    var i: usize = 0;
    while (i + 7 <= image.len) : (i += 1) {
        if (!std.mem.eql(u8, image[i..][0..4], &sig)) continue;
        const bank = image[i + 6];
        if (bank != 0x7E and bank != 0x7F) continue;
        r.sites += 1;
        if (out[i + 6] != bank) continue; // hi_proven got here first
        out[i + 6] = bank - 0x3E; // $7E/$7F -> $40/$41
        r.rebanked += 1;
    }
    return r;
}

test "rebankSmDecompInlineDests: inline WRAM destinations re-banked, proven and ROM ones left alone" {
    const gpa = testing.allocator;
    const img = try gpa.alloc(u8, 0x18_0000);
    defer gpa.free(img);
    @memset(img, 0);
    // $82:E845 `JSL $80:B0FF` ; dl $7E:A000   (the CRE tile table)
    // $82:E856 `JSL $80:B0FF` ; dl $7E:A800   (the tileset tile table)
    // $82:E7F4 `JSL $80:B0FF` ; dl $7F:0000   (level data)
    // $82:F000 `JSL $80:B0FF` ; dl $C2:1234   (not WRAM: untouched)
    const sites = [_]struct { a: u16, lo: u16, bank: u8 }{
        .{ .a = 0xE845, .lo = 0xA000, .bank = 0x7E },
        .{ .a = 0xE856, .lo = 0xA800, .bank = 0x7E },
        .{ .a = 0xE7F4, .lo = 0x0000, .bank = 0x7F },
        .{ .a = 0xF000, .lo = 0x1234, .bank = 0xC2 },
    };
    const f82: usize = 0x02 * 0x8000;
    for (sites) |s| {
        const o = f82 + (@as(usize, s.a) - 0x8000);
        img[o] = 0x22;
        img[o + 1] = 0xFF;
        img[o + 2] = 0xB0;
        img[o + 3] = 0x80;
        std.mem.writeInt(u16, img[o + 4 ..][0..2], s.lo, .little);
        img[o + 6] = s.bank;
    }
    const out = try gpa.alloc(u8, img.len);
    defer gpa.free(out);
    @memcpy(out, img);
    // hi_proven already re-banked the level-data site.
    out[f82 + (0xE7F4 - 0x8000) + 6] = 0x41;
    const r = rebankSmDecompInlineDests(img, out);
    try testing.expectEqual(@as(u32, 3), r.sites);
    try testing.expectEqual(@as(u32, 2), r.rebanked);
    try testing.expectEqual(@as(u8, 0x40), out[f82 + (0xE845 - 0x8000) + 6]);
    try testing.expectEqual(@as(u8, 0x40), out[f82 + (0xE856 - 0x8000) + 6]);
    try testing.expectEqual(@as(u8, 0x41), out[f82 + (0xE7F4 - 0x8000) + 6]); // untouched
    try testing.expectEqual(@as(u8, 0xC2), out[f82 + (0xF000 - 0x8000) + 6]); // untouched
    // The inline address bytes are never touched.
    try testing.expectEqual(@as(u8, 0x00), out[f82 + (0xE845 - 0x8000) + 4]);
    try testing.expectEqual(@as(u8, 0xA0), out[f82 + (0xE845 - 0x8000) + 5]);
}

test "rebankSmBgRecord: copy-command source banks de-mirrored, non-list skipped" {
    const gpa = testing.allocator;
    const img = try gpa.alloc(u8, 0x18_0000);
    defer gpa.free(img);
    @memset(img, 0);
    const f8f: usize = 0x0F * 0x8000;
    const wr = struct {
        pub fn b(buf: []u8, a16: u16, v: u8) void {
            buf[0x0F * 0x8000 + (@as(usize, a16) - 0x8000)] = v;
        }
    }.b;
    // A clean list at $B000: $0004 src $BA:8DE7 dest $4000 ; $0002 src $7E:4000
    // dest $4800 size $0800 ; $0000. Bank bytes at $B004 ($BA) and $B00B ($7E).
    const rec = [_]u8{ 0x04, 0x00, 0xE7, 0x8D, 0xBA, 0x00, 0x40, 0x02, 0x00, 0x00, 0x40, 0x7E, 0x00, 0x48, 0x00, 0x08, 0x00, 0x00 };
    for (rec, 0..) |v, i| wr(img, 0xB000 + @as(u16, @intCast(i)), v);
    const out = try gpa.alloc(u8, img.len);
    defer gpa.free(out);
    @memcpy(out, img);
    var walk: SmRoomWalk = .{};
    try testing.expect(rebankSmBgRecord(img, out, 0xB000, &walk));
    try testing.expectEqual(@as(u32, 2), walk.bg_banks);
    try testing.expectEqual(@as(u8, 0x3A), out[f8f + (0xB004 - 0x8000)]); // BA -> 3A
    try testing.expectEqual(@as(u8, 0x40), out[f8f + (0xB00B - 0x8000)]); // 7E -> 40
    // hi_proven already took the first bank: it is left alone.
    @memcpy(out, img);
    out[f8f + (0xB004 - 0x8000)] = 0x3A;
    var w2: SmRoomWalk = .{};
    try testing.expect(rebankSmBgRecord(img, out, 0xB000, &w2));
    try testing.expectEqual(@as(u32, 1), w2.bg_banks); // only the $7E one
    // A pointer into code ($000A then a non-command word) is not a list:
    // nothing is translated.
    for ([_]u8{ 0x0A, 0x00, 0x00, 0x00, 0xA0, 0x7B, 0x82, 0x22 }, 0..) |v, i|
        wr(img, 0xC000 + @as(u16, @intCast(i)), v);
    @memcpy(out, img);
    var w3: SmRoomWalk = .{};
    try testing.expect(!rebankSmBgRecord(img, out, 0xC000, &w3));
    try testing.expectEqual(@as(u32, 0), w3.bg_banks);
}

/// Super Metroid's tileset table: the room-graph walk fixes each room's
/// LEVEL data pointer, but the room also names a TILESET, and the tileset is
/// three more MB2 pointers — tile table, tile graphics, palette — that the
/// loader copies into $07C0 and decompresses the picture from. A tileset no
/// profiled surface loaded keeps its stock banks, all three decompress from
/// the wrong megabyte, and the room renders as tile garbage over a wrong
/// palette (measured 2026-09-03 on the Climb, $96BA, tileset 3: 15 of the 29
/// records — half the game's tilesets — were raw in v41; a hand patch of the
/// 45 bank bytes made the room pixel-correct). Same evidence-gated class as
/// the level pointer, one table over. (A first version of this pass, v35,
/// was written against the Parlor and changed nothing there — the Parlor's
/// tileset was already proven — and was reverted as a wrong theory. The
/// theory was wrong for that room, not wrong.)
///
/// The table is a fixed contiguous run of 9-byte records ($8F:E6A2..E7A7 on
/// this ROM — the pointer list at $E7A7 begins exactly where the records
/// end), each three 3-byte pointers into MB2. All-or-nothing, like the room
/// walk: every record's three banks must be real MB2 ($A0-$DF) or the whole
/// pass refuses, because a misparse rewrites graphics data. The de-mirror
/// map: $C0-$DF content lives $20 lower, $A0-$BF (the CRE's mirror-of-MB1
/// home) $80 lower. Reads stock bytes; leaves a byte `hi_proven` already
/// re-banked in `out` alone.
pub const sm_tileset_lo: u16 = 0xE6A2;
pub const sm_tileset_hi: u16 = 0xE7A7;

pub fn rebankSmTilesetTable(image: []const u8, out: []u8) SmRoomWalk {
    const f8f: usize = 0x0F * 0x8000;
    var walk: SmRoomWalk = .{};
    if (image.len < f8f + 0x8000) return walk;
    const b = struct {
        pub fn at(img: []const u8, a16: u16) u8 {
            return img[0x0F * 0x8000 + (@as(usize, a16) - 0x8000)];
        }
    }.at;

    // Validate the whole table before touching a byte.
    var a: u16 = sm_tileset_lo;
    var recs: u32 = 0;
    while (a + 9 <= sm_tileset_hi) : (a += 9) {
        inline for (.{ 2, 5, 8 }) |k| {
            const bank = b(image, a + k);
            if (bank < 0xA0 or bank > 0xDF) {
                walk.refused_at = a;
                return walk;
            }
        }
        recs += 1;
    }
    if (recs == 0) return walk;

    a = sm_tileset_lo;
    while (a + 9 <= sm_tileset_hi) : (a += 9) {
        inline for (.{ 2, 5, 8 }) |k| {
            const f = f8f + (@as(usize, a) + k - 0x8000);
            if (out[f] == image[f]) {
                const bank = out[f];
                out[f] = if (bank >= 0xC0) bank - 0x20 else bank - 0x80;
                walk.rebanked += 1;
            }
        }
    }
    walk.states = recs;
    return walk;
}

test "rebankSmTilesetTable: every record's banks de-mirrored, proven left alone, anomaly refuses" {
    const gpa = testing.allocator;
    const img = try gpa.alloc(u8, 0x18_0000);
    defer gpa.free(img);
    @memset(img, 0);
    const f8f: usize = 0x0F * 0x8000;
    const putrec = struct {
        pub fn f(buf: []u8, a16: u16, lo: u16, bank: u8) void {
            const o = 0x0F * 0x8000 + (@as(usize, a16) - 0x8000);
            std.mem.writeInt(u16, buf[o..][0..2], lo, .little);
            buf[o + 2] = bank;
        }
    }.f;
    // Fill $E6A2..E7A7 with 9-byte records (three MB2 pointers each).
    var a: u16 = sm_tileset_lo;
    while (a + 9 <= sm_tileset_hi) : (a += 9) {
        putrec(img, a + 0, 0xBEEE, 0xC1); // tile table -> A1
        putrec(img, a + 3, 0xF911, 0xBA); // tile GFX   -> 3A
        putrec(img, a + 6, 0xB015, 0xC2); // palette    -> A2
    }
    const out = try gpa.alloc(u8, img.len);
    defer gpa.free(out);
    @memcpy(out, img);
    // hi_proven already re-banked the first record's tile-table bank.
    out[f8f + (@as(usize, sm_tileset_lo) + 2 - 0x8000)] = 0xA1;

    const w = rebankSmTilesetTable(img, out);
    try testing.expectEqual(@as(u32, 0), w.refused_at);
    try testing.expectEqual(@as(u32, 29), w.states);
    try testing.expectEqual(@as(u32, 29 * 3 - 1), w.rebanked); // all but the proven one
    try testing.expectEqual(@as(u8, 0xA1), out[f8f + (@as(usize, sm_tileset_lo) + 2 - 0x8000)]); // untouched
    try testing.expectEqual(@as(u8, 0x3A), out[f8f + (@as(usize, sm_tileset_lo) + 5 - 0x8000)]); // BA -> 3A
    try testing.expectEqual(@as(u8, 0xA2), out[f8f + (@as(usize, sm_tileset_lo) + 8 - 0x8000)]); // C2 -> A2
    // A record with a non-MB2 bank refuses the whole pass, rewriting nothing.
    putrec(img, sm_tileset_lo + 9 + 2, 0xBEEE, 0x12);
    @memcpy(out, img);
    const w2 = rebankSmTilesetTable(img, out);
    try testing.expectEqual(sm_tileset_lo + @as(u16, 9), w2.refused_at);
    try testing.expectEqual(@as(u32, 0), w2.rebanked);
    try testing.expectEqual(@as(u8, 0xC1), out[f8f + (@as(usize, sm_tileset_lo) + 2 - 0x8000)]);
}

/// Super Metroid's enemy headers: 64-byte records at $A0:CEBF.. ($40 apart,
/// through $F7BF), one per enemy species. Byte +$0C is the enemy's BANK —
/// the bank its AI routines, its palette (+$02) and its instruction lists
/// live in, $A2-$B7 on this ROM, i.e. MB1 addressed through its $A0-$BF
/// mirror. The game reads it as data (into the enemy's RAM slot, then
/// through long pointers and the AI dispatch), so it is the same
/// evidence-gated class as the level pointer: an enemy no recording met
/// keeps its stock bank, and on the converted map $A0-$BF is MB2, so its
/// palette comes from the wrong megabyte and its AI runs from it. Measured
/// 2026-09-03 in $9A44: the six Chozo-face sprites ($EA7F, proven) share
/// palette slot 7 with $CEFF (raw); $CEFF's palette read from $A2:8912
/// returned MB2's $C2:8912 and painted the faces wrong. 164 headers carry
/// such a bank; v43 had 130 raw. A hand patch made the second load write
/// the stock palette.
///
/// Per-record validated, not all-or-nothing: the run of true headers ends
/// somewhere in $F1xx-$F7xx and is followed by 64-byte-aligned records of
/// another shape (they carry a plausible bank byte but AI pointers below
/// $8000), so each record must look like a header — bank in $A0-$BF and
/// both the init AI (+$12) and main AI (+$18) pointers in ROM ($8000+) —
/// or it is skipped untouched. Translation is -$80 ($A0-$BF -> $20-$3F).
/// Leaves a byte `hi_proven` already re-banked in `out` alone.
pub const sm_enemy_hdr_lo: u16 = 0xCEBF;
pub const sm_enemy_hdr_hi: u16 = 0xF800;

pub fn rebankSmEnemyHeaders(image: []const u8, out: []u8) SmRoomWalk {
    const fa0: usize = 0x20 * 0x8000; // bank $A0 (= $20) file offset
    var walk: SmRoomWalk = .{};
    if (image.len < fa0 + 0x8000) return walk;
    // The table is not one 64-byte grid: a second run of headers starts
    // at $F153, 20 bytes off the first grid's phase (the enemy whose raw
    // bank byte sent the CPU into the wrong megabyte lived at $F693). So
    // the walk is stride 2 over the whole range, and a record is a header
    // when it sits on the first grid and passes the original check, or
    // anywhere and passes a stricter one — the bank's pad byte zero, every
    // AI pointer (init, main, grapple, hurt, frozen) in ROM, a plausible
    // part count. Measured on the stock image: 139 on the grid, 26 off it,
    // no two within 64 bytes of each other.
    var h: u32 = sm_enemy_hdr_lo;
    while (h + 0x40 <= sm_enemy_hdr_hi) : (h += 2) {
        const o = fa0 + (h - 0x8000);
        const bank = image[o + 0x0C];
        const init_ai = std.mem.readInt(u16, image[o + 0x12 ..][0..2], .little);
        const main_ai = std.mem.readInt(u16, image[o + 0x18 ..][0..2], .little);
        if (bank < 0xA0 or bank > 0xBF or init_ai < 0x8000 or main_ai < 0x8000) continue;
        const on_grid = (h - sm_enemy_hdr_lo) % 0x40 == 0;
        if (!on_grid) {
            const grapple = std.mem.readInt(u16, image[o + 0x1A ..][0..2], .little);
            const hurt = std.mem.readInt(u16, image[o + 0x1C ..][0..2], .little);
            const frozen = std.mem.readInt(u16, image[o + 0x1E ..][0..2], .little);
            const parts = std.mem.readInt(u16, image[o + 0x14 ..][0..2], .little);
            if (image[o + 0x0D] != 0 or grapple < 0x8000 or hurt < 0x8000 or frozen < 0x8000 or parts > 0x10) continue;
        }
        walk.states += 1;
        if (out[o + 0x0C] != image[o + 0x0C]) continue; // hi_proven got here first
        out[o + 0x0C] = bank - 0x80;
        walk.rebanked += 1;
    }
    return walk;
}

/// Super Metroid's AREA MAP TABLE: seven 3-byte long pointers at $82:964A,
/// one per area, naming that area's map tilemap in bank $B5. The HUD
/// minimap ($90:AA7C) and the pause map ($82:953F) copy an entry into a
/// direct-page pointer and read the tilemap through it — a bank byte that
/// lives in a table, never in an operand, so no execution-driven rebanker
/// sees it, and on the conversion bank $B5 is not the megabyte the map
/// lives in: the minimap drew text glyphs instead of map cells. The bytes
/// are de-mirrored in place ($A0-$BF -> -$80), all or nothing, after every
/// entry validates (bank $B5, address in ROM); a byte a recording already
/// proved is left as the evidence wrote it. Title-gated like the others.
pub const sm_area_map_lo: u16 = 0x964A;
pub const sm_area_map_entries: u16 = 7;
pub fn rebankSmAreaMapTable(image: []const u8, out: []u8) SmRoomWalk {
    const f82: usize = 0x02 * 0x8000;
    var walk: SmRoomWalk = .{};
    if (image.len < f82 + 0x8000) return walk;
    var e: u16 = 0;
    while (e < sm_area_map_entries) : (e += 1) {
        const o = f82 + (sm_area_map_lo - 0x8000) + @as(usize, e) * 3;
        const addr = std.mem.readInt(u16, image[o..][0..2], .little);
        if (image[o + 2] != 0xB5 or addr < 0x8000) {
            walk.refused_at = sm_area_map_lo + e * 3;
            return walk;
        }
    }
    walk.states = sm_area_map_entries;
    e = 0;
    while (e < sm_area_map_entries) : (e += 1) {
        const o = f82 + (sm_area_map_lo - 0x8000) + @as(usize, e) * 3 + 2;
        if (out[o] != image[o]) continue; // proven first
        out[o] = image[o] - 0x80;
        walk.rebanked += 1;
    }
    return walk;
}

test "rebankSmAreaMapTable: seven entries de-mirrored, a proven one kept, a bad entry refuses the table" {
    const gpa = testing.allocator;
    const img = try gpa.alloc(u8, 0x18_0000);
    defer gpa.free(img);
    @memset(img, 0);
    const f82: usize = 0x02 * 0x8000;
    const t = f82 + (sm_area_map_lo - 0x8000);
    const table = [_]u8{ 0x00, 0x90, 0xB5, 0x00, 0x80, 0xB5, 0x00, 0xA0, 0xB5, 0x00, 0xB0, 0xB5, 0x00, 0xC0, 0xB5, 0x00, 0xD0, 0xB5, 0x00, 0xE0, 0xB5 };
    @memcpy(img[t..][0..table.len], &table);
    const out = try gpa.alloc(u8, img.len);
    defer gpa.free(out);
    @memcpy(out, img);
    out[t + 5] = 0x35; // entry 1 already proven
    const w = rebankSmAreaMapTable(img, out);
    try testing.expectEqual(@as(u32, 7), w.states);
    try testing.expectEqual(@as(u32, 6), w.rebanked);
    try testing.expectEqual(@as(u32, 0), w.refused_at);
    for (0..7) |i| try testing.expectEqual(@as(u8, 0x35), out[t + i * 3 + 2]);
    // A bad entry refuses the whole table, touching nothing.
    img[t + 3 * 3 + 2] = 0x7E;
    @memcpy(out, img);
    const w2 = rebankSmAreaMapTable(img, out);
    try testing.expectEqual(@as(u32, sm_area_map_lo + 9), w2.refused_at);
    try testing.expectEqual(@as(u32, 0), w2.rebanked);
    try testing.expectEqualSlices(u8, img, out);
}

/// Super Metroid seeds long pointers in the direct page from IMMEDIATES:
/// the map routine does `LDA #$007E / STA $05` for the tilemap buffer's
/// bank and `LDA #$0000 / STA $0B`, `LDA #$07F7 / STA $09` for the
/// explored-map bits it then reads through `LDA [$09]`. Nothing indexes
/// those constants, no bank register carries them, so neither the
/// de-mirror map nor the evidence-based rebankers reach them: the map
/// drew from the abandoned WRAM homes (the garbled pause map). This
/// pass finds the idiom by signature and translates the seed: a bank
/// word $007E/$007F becomes $0040/$0041 when a long-indirect access
/// through that slot's pointer follows within 256 bytes; a low-WRAM
/// address word (under $2000) gains $6000 — the window's home — when
/// its bank slot is seeded with $0000 within 64 bytes either way and
/// the same use follows. Measured on the stock image: 9 bank seeds and
/// 3 address seeds in banks $80-$B4, every one a pointer the game
/// dereferences; the 5 that recordings had already proven are left as
/// the evidence wrote them. Title-gated like the other nets.
pub fn rebankSmPointerSeeds(image: []const u8, out: []u8) SmInlineDests {
    var st: SmInlineDests = .{};
    var bank: u8 = 0x80;
    while (bank <= 0xB4) : (bank += 1) {
        const base: usize = @as(usize, bank & 0x7F) * 0x8000;
        if (image.len < base + 0x8000) break;
        const blk = image[base .. base + 0x8000];
        var i: usize = 0;
        while (i + 5 <= blk.len) : (i += 1) {
            if (blk[i] != 0xA9 or blk[i + 3] != 0x85) continue;
            const imm: u16 = @as(u16, blk[i + 1]) | @as(u16, blk[i + 2]) << 8;
            const slot = blk[i + 4];
            if (imm == 0x7E or imm == 0x7F) {
                if (slot < 2 or !smLongIndirectUse(blk, i + 5, slot - 2)) continue;
                st.sites += 1;
                if (out[base + i + 1] != image[base + i + 1]) continue; // proven first
                out[base + i + 1] = if (imm == 0x7E) 0x40 else 0x41;
                st.rebanked += 1;
            } else if (imm != 0 and imm < 0x2000) {
                if (slot > 0xFD or !smLongIndirectUse(blk, i + 5, slot)) continue;
                // The bank slot seeded with $0000 nearby: the pointer names
                // bank 0, whose low 8 KiB is the WRAM mirror.
                const lo: usize = i -| 64;
                const hi: usize = @min(blk.len - 5, i + 64);
                var k: usize = lo;
                var seeded = false;
                while (k < hi) : (k += 1) {
                    if (blk[k] == 0xA9 and blk[k + 1] == 0 and blk[k + 2] == 0 and blk[k + 3] == 0x85 and blk[k + 4] == slot + 2) {
                        seeded = true;
                        break;
                    }
                }
                if (!seeded) continue;
                st.sites += 1;
                if (out[base + i + 1] != image[base + i + 1] or out[base + i + 2] != image[base + i + 2]) continue;
                const moved = imm + 0x6000;
                out[base + i + 1] = @truncate(moved);
                out[base + i + 2] = @truncate(moved >> 8);
                st.rebanked += 1;
            }
        }
    }
    return st;
}

/// A `[dp]` or `[dp],Y` access (the eight ALU ops' long-indirect forms:
/// opcode low bits $07/$17) through `slot` within 256 bytes from `from`.
pub fn smLongIndirectUse(blk: []const u8, from: usize, slot: u8) bool {
    var j = from;
    const end = @min(blk.len - 1, from + 256);
    while (j < end) : (j += 1) {
        const lo5 = blk[j] & 0x1F;
        if ((lo5 == 0x07 or lo5 == 0x17) and blk[j + 1] == slot) return true;
    }
    return false;
}

test "rebankSmPointerSeeds: bank and low-WRAM address seeds of dereferenced pointers, proven ones left alone" {
    const gpa = testing.allocator;
    const img = try gpa.alloc(u8, 0x18_0000);
    defer gpa.free(img);
    @memset(img, 0xEA);
    const f82: usize = 0x02 * 0x8000;
    // The map idiom: bank seed for slot $03, address seed for slot $09 with
    // its bank slot $0B seeded $0000, both dereferenced later.
    const code = [_]u8{
        0xA9, 0x00, 0x30, 0x85, 0x03, // LDA #$3000 / STA $03
        0xA9, 0x7E, 0x00, 0x85, 0x05, // LDA #$007E / STA $05   -> $0040
        0xA9, 0x00, 0x00, 0x85, 0x0B, // LDA #$0000 / STA $0B
        0xA9, 0xF7, 0x07, 0x85, 0x09, // LDA #$07F7 / STA $09   -> $67F7
        0xA7, 0x09, //                   LDA [$09]
        0x97, 0x03, //                   STA [$03],Y
        0xA9, 0x7F, 0x00, 0x85, 0x40, // LDA #$007F / STA $40: never dereferenced -> untouched
        0xA9, 0x10, 0x00, 0x85, 0x20, // LDA #$0010 / STA $20: no bank seed -> untouched
        0xA7, 0x20, //                   LDA [$20]
    };
    @memcpy(img[f82 + 0x1000 ..][0..code.len], &code);
    // A seed a recording already proved: `out` differs from `image` there.
    @memcpy(img[f82 + 0x2000 ..][0..7], &[_]u8{ 0xA9, 0x7E, 0x00, 0x85, 0x05, 0xA7, 0x03 });
    const out = try gpa.alloc(u8, img.len);
    defer gpa.free(out);
    @memcpy(out, img);
    out[f82 + 0x2000 + 1] = 0x40;
    const st = rebankSmPointerSeeds(img, out);
    try testing.expectEqual(@as(u32, 3), st.sites);
    try testing.expectEqual(@as(u32, 2), st.rebanked);
    try testing.expectEqual(@as(u8, 0x40), out[f82 + 0x1000 + 6]);
    try testing.expectEqual(@as(u16, 0x67F7), std.mem.readInt(u16, out[f82 + 0x1000 + 16 ..][0..2], .little));
    try testing.expectEqual(@as(u8, 0x7F), out[f82 + 0x1000 + 25]);
    try testing.expectEqual(@as(u16, 0x0010), std.mem.readInt(u16, out[f82 + 0x1000 + 30 ..][0..2], .little));
    try testing.expectEqual(@as(u8, 0x40), out[f82 + 0x2000 + 1]);
}

test "rebankSmEnemyHeaders: header banks de-mirrored, proven and non-header records left alone" {
    const gpa = testing.allocator;
    const img = try gpa.alloc(u8, 0x18_0000);
    defer gpa.free(img);
    @memset(img, 0);
    const fa0: usize = 0x20 * 0x8000;
    const hdr = struct {
        pub fn put(buf: []u8, a16: u16, bank: u8, init_ai: u16, main_ai: u16) void {
            const o = 0x20 * 0x8000 + (@as(usize, a16) - 0x8000);
            buf[o + 0x0C] = bank;
            std.mem.writeInt(u16, buf[o + 0x12 ..][0..2], init_ai, .little);
            std.mem.writeInt(u16, buf[o + 0x18 ..][0..2], main_ai, .little);
        }
    }.put;
    hdr(img, 0xCEBF, 0xA2, 0x8DBA, 0x8E30); // a real header -> $22
    hdr(img, 0xCEFF, 0xA2, 0x8DBA, 0x8E30); // real, but already proven in `out`
    hdr(img, 0xEA7F, 0xA8, 0xE7BC, 0xE812); // real -> $28
    hdr(img, 0xF17F, 0xB7, 0x0000, 0x0009); // bank plausible, AI pointers not: skipped
    hdr(img, 0xF13F, 0x02, 0x8000, 0x8000); // bank not a mirror: skipped
    // Off the first grid (the second run's phase): needs the strict check.
    hdr(img, 0xF693, 0xB2, 0xFD02, 0xFD32); // -> $32 once its other AI pointers are in ROM
    for ([_]usize{ 0x1A, 0x1C, 0x1E }) |k| std.mem.writeInt(u16, img[fa0 + (0xF693 - 0x8000) + k ..][0..2], 0x800F, .little);
    std.mem.writeInt(u16, img[fa0 + (0xF693 - 0x8000) + 0x14 ..][0..2], 1, .little);
    hdr(img, 0xF6D5, 0xB2, 0xFD02, 0xFD32); // off both grids, grapple AI not in ROM: skipped
    const out = try gpa.alloc(u8, img.len);
    defer gpa.free(out);
    @memcpy(out, img);
    out[fa0 + (0xCEFF - 0x8000) + 0x0C] = 0x22;
    const w = rebankSmEnemyHeaders(img, out);
    try testing.expectEqual(@as(u32, 4), w.states);
    try testing.expectEqual(@as(u32, 3), w.rebanked);
    try testing.expectEqual(@as(u8, 0x32), out[fa0 + (0xF693 - 0x8000) + 0x0C]);
    try testing.expectEqual(@as(u8, 0xB2), out[fa0 + (0xF6D5 - 0x8000) + 0x0C]); // skipped
    try testing.expectEqual(@as(u8, 0x22), out[fa0 + (0xCEBF - 0x8000) + 0x0C]);
    try testing.expectEqual(@as(u8, 0x22), out[fa0 + (0xCEFF - 0x8000) + 0x0C]); // untouched
    try testing.expectEqual(@as(u8, 0x28), out[fa0 + (0xEA7F - 0x8000) + 0x0C]);
    try testing.expectEqual(@as(u8, 0xB7), out[fa0 + (0xF17F - 0x8000) + 0x0C]); // skipped
    try testing.expectEqual(@as(u8, 0x02), out[fa0 + (0xF13F - 0x8000) + 0x0C]); // skipped
}

test "rebankSmRoomLevelPointers: every state reached through doors, proven bytes left alone" {
    const gpa = testing.allocator;
    const img = try gpa.alloc(u8, 0x18_0000);
    defer gpa.free(img);
    @memset(img, 0);
    const f8f: usize = 0x0F * 0x8000;
    const f83: usize = 0x03 * 0x8000;
    const put16 = struct {
        pub fn f(buf: []u8, base: usize, a16: u32, v: u16) void {
            std.mem.writeInt(u16, buf[base + (a16 - 0x8000) ..][0..2], v, .little);
        }
    }.f;
    // Room A at $91F8: area 0, 1x1, door list at $9260; conditions:
    // E629 <event 1> -> state $9240 ; E5E6 -> default state inline.
    const a: u32 = 0x91F8;
    img[f8f + (a - 0x8000) + 1] = 0; // area
    img[f8f + (a - 0x8000) + 4] = 1; // width
    img[f8f + (a - 0x8000) + 5] = 1; // height
    put16(img, f8f, a + 9, 0x9260);
    put16(img, f8f, a + 11, 0xE629);
    img[f8f + (a + 13 - 0x8000)] = 1;
    put16(img, f8f, a + 14, 0x9240);
    put16(img, f8f, a + 16, 0xE5E6);
    const a_def: u32 = a + 18;
    put16(img, f8f, a_def, 0xC330);
    img[f8f + (a_def + 2 - 0x8000)] = 0xCD;
    img[f8f + (a_def + 3 - 0x8000)] = 0x0F;
    // A's event state at $9240: level $C2:9000, tileset 3
    put16(img, f8f, 0x9240, 0x9000);
    img[f8f + (0x9242 - 0x8000)] = 0xC2;
    img[f8f + (0x9243 - 0x8000)] = 0x03;
    // A's door list: a door to room B, an elevator door, then the next header word (< $8000)
    put16(img, f8f, 0x9260, 0x9000);
    put16(img, f8f, 0x9262, 0x9010);
    put16(img, f8f, 0x9264, 0x0102);
    put16(img, f83, 0x9000, 0x9300); // door -> room B
    put16(img, f83, 0x9010, 0x0000); // elevator
    // Room B at $9300: area 1, 2x1, default state only, one door back to A
    const b: u32 = 0x9300;
    img[f8f + (b - 0x8000) + 1] = 1;
    img[f8f + (b - 0x8000) + 4] = 2;
    img[f8f + (b - 0x8000) + 5] = 1;
    put16(img, f8f, b + 9, 0x9340);
    put16(img, f8f, b + 11, 0xE5E6);
    const b_def: u32 = b + 13;
    put16(img, f8f, b_def, 0xB846);
    img[f8f + (b_def + 2 - 0x8000)] = 0xC5;
    img[f8f + (b_def + 3 - 0x8000)] = 0x10;
    put16(img, f8f, 0x9340, 0x9020);
    put16(img, f8f, 0x9342, 0x0000);
    put16(img, f83, 0x9020, 0x91F8);

    // Room C at $DF45 (the Ceres root): no door reaches it from A or B.
    const c: u32 = 0xDF45;
    img[f8f + (c - 0x8000) + 1] = 6;
    img[f8f + (c - 0x8000) + 4] = 1;
    img[f8f + (c - 0x8000) + 5] = 1;
    put16(img, f8f, c + 9, 0xDF80);
    put16(img, f8f, c + 11, 0xE5E6);
    const c_def: u32 = c + 13;
    put16(img, f8f, c_def, 0xB000);
    img[f8f + (c_def + 2 - 0x8000)] = 0xCD;
    img[f8f + (c_def + 3 - 0x8000)] = 0x0F;
    put16(img, f8f, 0xDF80, 0x0000);

    const out = try gpa.alloc(u8, img.len);
    defer gpa.free(out);
    @memcpy(out, img);
    out[f8f + (a_def + 2 - 0x8000)] = 0xAD; // hi_proven already re-banked A's default

    const w = try rebankSmRoomLevelPointers(gpa, img, out);
    try testing.expectEqual(@as(u32, 0), w.refused_at);
    try testing.expectEqual(@as(u32, 3), w.rooms);
    try testing.expectEqual(@as(u32, 4), w.states);
    try testing.expectEqual(@as(u32, 3), w.rebanked);
    try testing.expectEqual(@as(u8, 0xAD), out[f8f + (c_def + 2 - 0x8000)]);
    try testing.expectEqual(@as(u8, 0xAD), out[f8f + (a_def + 2 - 0x8000)]);
    try testing.expectEqual(@as(u8, 0xA2), out[f8f + (0x9242 - 0x8000)]);
    try testing.expectEqual(@as(u8, 0xA5), out[f8f + (b_def + 2 - 0x8000)]);
    // A state whose level pointer is outside MB2 refuses the whole pass and rewrites nothing.
    img[f8f + (b_def + 2 - 0x8000)] = 0x8F;
    @memcpy(out, img);
    const w2 = try rebankSmRoomLevelPointers(gpa, img, out);
    try testing.expectEqual(b_def, w2.refused_at);
    try testing.expectEqual(@as(u32, 0), w2.rebanked);
    try testing.expectEqual(@as(u8, 0xC2), out[f8f + (0x9242 - 0x8000)]);
}

test "demirrorQueueBankImms: consumer names the column, producers re-bank" {
    var buf: [64]u8 = @splat(0x60); // RTS filler
    // consumer: LDA $6FA6,X / STA $7786 / XBA / PHA / PLB / PLB
    @memcpy(buf[4..14], &[_]u8{ 0xBD, 0xA6, 0x6F, 0x8D, 0x86, 0x77, 0xEB, 0x48, 0xAB, 0xAB });
    // producers against the same column: mirror, WRAM, misfit, and native
    @memcpy(buf[20..26], &[_]u8{ 0xA9, 0xA3, 0x00, 0x9D, 0xA6, 0x6F });
    @memcpy(buf[26..32], &[_]u8{ 0xA9, 0x7E, 0x00, 0x9D, 0xA6, 0x6F });
    @memcpy(buf[32..38], &[_]u8{ 0xA9, 0xC5, 0x00, 0x9D, 0xA6, 0x6F });
    @memcpy(buf[38..44], &[_]u8{ 0xA9, 0x33, 0x00, 0x9D, 0xA6, 0x6F }); // already native: untouched
    // a producer against a DIFFERENT column: untouched
    @memcpy(buf[44..50], &[_]u8{ 0xA9, 0xA3, 0x00, 0x9D, 0xB0, 0x6F });
    try testing.expectEqual(@as(u32, 3), demirrorQueueBankImms(&buf, true));
    try testing.expectEqual(@as(u8, 0x23), buf[21]);
    try testing.expectEqual(@as(u8, 0x40), buf[27]);
    try testing.expectEqual(@as(u8, 0xA5), buf[33]);
    try testing.expectEqual(@as(u8, 0x33), buf[39]);
    try testing.expectEqual(@as(u8, 0xA3), buf[45]);
    // narrow image: the de-mirror arms stay put, WRAM still re-banks
    var buf2: [64]u8 = buf;
    buf2[21] = 0xA3;
    buf2[27] = 0x7E;
    buf2[33] = 0xC5;
    try testing.expectEqual(@as(u32, 1), demirrorQueueBankImms(&buf2, false));
    try testing.expectEqual(@as(u8, 0xA3), buf2[21]);
    try testing.expectEqual(@as(u8, 0x40), buf2[27]);
    try testing.expectEqual(@as(u8, 0xC5), buf2[33]);
}
