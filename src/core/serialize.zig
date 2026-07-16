//! Save-state serialization: comptime reflection over plain state structs.
//!
//! Component state must be plain data — integers, bools, enums, fixed-size
//! arrays, nested structs of the same. Pointers are a compile error: derived
//! state (page tables, caches) is rebuilt after load via postLoad() hooks.
//!
//! A struct can exclude derived/rebuilt fields by declaring:
//!     pub const serialize_skip = .{ "pages", "cart" };
//!
//! The format is fixed-layout little-endian with no per-field framing, so
//! `byteSize(T)` is comptime-known — which keeps libretro's
//! retro_serialize_size stable for the whole session. A versioned header is
//! added by the console-level save-state code, not here.

const std = @import("std");
const builtin = @import("builtin");

fn isSkipped(comptime T: type, comptime field_name: []const u8) bool {
    if (!@hasDecl(T, "serialize_skip")) return false;
    inline for (T.serialize_skip) |skip| {
        if (comptime std.mem.eql(u8, skip, field_name)) return true;
    }
    return false;
}

/// Widest-alignment byte count needed to store T's bit size.
fn intByteSize(comptime T: type) usize {
    return comptime std.math.divCeil(usize, @bitSizeOf(T), 8) catch unreachable;
}

fn IntBacking(comptime T: type) type {
    return std.meta.Int(.unsigned, 8 * intByteSize(T));
}

/// Comptime structural fingerprint of T's serialized layout: FNV-1a folded
/// over the same reflection walk `byteSize` makes — field names, type kinds,
/// signedness, bit widths, array lengths, in serialization order. It is the
/// wire format's implicit schema made explicit: any layout change moves it,
/// including the ones a byte-count check waves through (two same-width fields
/// swapped, a u16 turned i16, a field renamed to mean something else). The
/// console stores it in the save-state header, so an old state meets
/// UnsupportedVersion instead of deserializing into the wrong fields.
///
/// Enum *variant sets* are deliberately not folded: the wire carries the tag
/// integer, renames don't move bytes, and an out-of-range tag is already
/// rejected at read time.
pub fn fingerprint(comptime T: type) u64 {
    @setEvalBranchQuota(1_000_000);
    return comptime fp(T, 0xcbf29ce484222325);
}

fn fpMix(comptime h: u64, comptime v: u64) u64 {
    return (h ^ v) *% 0x100000001b3;
}

fn fpStr(comptime h: u64, comptime s: []const u8) u64 {
    comptime var x = h;
    inline for (s) |c| x = fpMix(x, c);
    return fpMix(x, 0xFF); // terminator: "ab"+"c" must differ from "a"+"bc"
}

fn fp(comptime T: type, comptime h: u64) u64 {
    switch (@typeInfo(T)) {
        .int => |i| return fpMix(fpMix(h, if (i.signedness == .signed) 'i' else 'u'), i.bits),
        .bool => return fpMix(h, 'b'),
        .@"enum" => |e| return fp(e.tag_type, fpMix(h, 'e')),
        .array => |a| return fp(a.child, fpMix(fpMix(h, 'a'), a.len)),
        .@"struct" => |s| {
            comptime var x = fpMix(h, 's');
            inline for (s.fields) |f| {
                if (comptime isSkipped(T, f.name)) continue;
                x = fp(f.type, fpStr(x, f.name));
            }
            return fpMix(x, 'z'); // close the struct: nesting must matter
        },
        else => @compileError("cannot serialize " ++ @typeName(T)),
    }
}

/// An integer type whose wire encoding is exactly its in-memory bytes on a
/// little-endian host: bit size a multiple of 8 that fills its backing
/// integer (a u24 is stored in 4 bytes in memory but 3 on the wire, so it
/// stays on the element loop).
fn isMemcpyable(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => @bitSizeOf(T) % 8 == 0 and @sizeOf(T) * 8 == @bitSizeOf(T),
        else => false,
    };
}

const le_host = builtin.cpu.arch.endian() == .little;

pub fn byteSize(comptime T: type) usize {
    // The recursive walk over Console's whole field tree runs long at comptime;
    // raise the quota here once so every caller inherits it.
    @setEvalBranchQuota(100_000);
    comptime var total: usize = 0;
    switch (@typeInfo(T)) {
        .int => total = intByteSize(T),
        .bool => total = 1,
        .@"enum" => |e| total = intByteSize(e.tag_type),
        .array => |a| total = a.len * byteSize(a.child),
        .@"struct" => |s| {
            inline for (s.fields) |f| {
                if (comptime isSkipped(T, f.name)) continue;
                total += byteSize(f.type);
            }
        },
        else => @compileError("cannot serialize " ++ @typeName(T)),
    }
    return total;
}

/// Write `value` into `out`, returning the number of bytes written.
/// `out.len` must be at least `byteSize(T)`.
pub fn write(comptime T: type, value: *const T, out: []u8) usize {
    @setEvalBranchQuota(100_000);
    switch (@typeInfo(T)) {
        .int => {
            const n = comptime intByteSize(T);
            const Backing = IntBacking(T);
            const wide: Backing = @intCast(@as(std.meta.Int(.unsigned, @bitSizeOf(T)), @bitCast(value.*)));
            std.mem.writeInt(Backing, out[0..n], wide, .little);
            return n;
        },
        .bool => {
            out[0] = @intFromBool(value.*);
            return 1;
        },
        .@"enum" => |e| {
            const tag: e.tag_type = @intFromEnum(value.*);
            return write(e.tag_type, &tag, out);
        },
        .array => |a| {
            if (a.child == u8) {
                @memcpy(out[0..a.len], value);
                return a.len;
            }
            // The wire bytes ARE the memory bytes for full-width integers on
            // a little-endian host, so a [0x8000]u16 VRAM is one memcpy, not
            // 32k writeInt calls. Byte-identical to the element loop below —
            // a test compares the two encodings.
            if (comptime le_host and isMemcpyable(a.child)) {
                const n = a.len * @sizeOf(a.child);
                @memcpy(out[0..n], std.mem.sliceAsBytes(value[0..]));
                return n;
            }
            var off: usize = 0;
            for (value) |*elem| off += write(a.child, elem, out[off..]);
            return off;
        },
        .@"struct" => |s| {
            var off: usize = 0;
            inline for (s.fields) |f| {
                if (comptime isSkipped(T, f.name)) continue;
                off += write(f.type, &@field(value.*, f.name), out[off..]);
            }
            return off;
        },
        else => @compileError("cannot serialize " ++ @typeName(T)),
    }
}

pub const ReadError = error{ Corrupt, EndOfState };

/// Read into `value` from `in`, returning the number of bytes consumed.
/// Skipped fields are left untouched; callers rebuild them via postLoad().
pub fn read(comptime T: type, value: *T, in: []const u8) ReadError!usize {
    @setEvalBranchQuota(100_000);
    switch (@typeInfo(T)) {
        .int => {
            const n = comptime intByteSize(T);
            if (in.len < n) return error.EndOfState;
            const Backing = IntBacking(T);
            const wide = std.mem.readInt(Backing, in[0..n], .little);
            const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
            const bits = std.math.cast(Bits, wide) orelse return error.Corrupt;
            value.* = @bitCast(bits);
            return n;
        },
        .bool => {
            if (in.len < 1) return error.EndOfState;
            if (in[0] > 1) return error.Corrupt;
            value.* = in[0] != 0;
            return 1;
        },
        .@"enum" => |e| {
            var tag: e.tag_type = undefined;
            const n = try read(e.tag_type, &tag, in);
            value.* = std.enums.fromInt(T, tag) orelse return error.Corrupt;
            return n;
        },
        .array => |a| {
            if (a.child == u8) {
                if (in.len < a.len) return error.EndOfState;
                @memcpy(value, in[0..a.len]);
                return a.len;
            }
            // Mirror of write's fast path. Full-width integers have no
            // invalid encodings, so the element loop's range check has
            // nothing to reject here.
            if (comptime le_host and isMemcpyable(a.child)) {
                const n = a.len * @sizeOf(a.child);
                if (in.len < n) return error.EndOfState;
                @memcpy(std.mem.sliceAsBytes(value[0..]), in[0..n]);
                return n;
            }
            var off: usize = 0;
            for (value) |*elem| off += try read(a.child, elem, in[off..]);
            return off;
        },
        .@"struct" => |s| {
            var off: usize = 0;
            inline for (s.fields) |f| {
                if (comptime isSkipped(T, f.name)) continue;
                off += try read(f.type, &@field(value.*, f.name), in[off..]);
            }
            return off;
        },
        else => @compileError("cannot serialize " ++ @typeName(T)),
    }
}

test "roundtrip plain struct" {
    const Inner = struct { a: u17, b: bool, c: [3]u16 };
    const Mode = enum(u8) { fast, accurate };
    const State = struct {
        pub const serialize_skip = .{"scratch"};
        x: u8,
        y: i16,
        inner: Inner,
        mode: Mode,
        raw: [4]u8,
        scratch: u32,
    };

    const original: State = .{
        .x = 0xAB,
        .y = -1234,
        .inner = .{ .a = 0x1FFFF, .b = true, .c = .{ 1, 2, 0xFFFF } },
        .mode = .accurate,
        .raw = .{ 4, 3, 2, 1 },
        .scratch = 999,
    };

    var buf: [byteSize(State)]u8 = undefined;
    try std.testing.expectEqual(buf.len, write(State, &original, &buf));

    var loaded: State = std.mem.zeroes(State);
    try std.testing.expectEqual(buf.len, try read(State, &loaded, &buf));

    try std.testing.expectEqual(original.x, loaded.x);
    try std.testing.expectEqual(original.y, loaded.y);
    try std.testing.expectEqual(original.inner, loaded.inner);
    try std.testing.expectEqual(original.mode, loaded.mode);
    try std.testing.expectEqual(original.raw, loaded.raw);
    try std.testing.expectEqual(@as(u32, 0), loaded.scratch); // skipped

    // Byte-identical re-serialization (state must be deterministic).
    loaded.scratch = original.scratch;
    var buf2: [byteSize(State)]u8 = undefined;
    _ = write(State, &loaded, &buf2);
    try std.testing.expectEqualSlices(u8, &buf, &buf2);
}

test "corrupt enum tag rejected" {
    const Mode = enum(u8) { a, b };
    var v: Mode = .a;
    const bad = [_]u8{7};
    try std.testing.expectError(error.Corrupt, read(Mode, &v, &bad));
}

test "fingerprint catches what the size check cannot" {
    // The bug this exists for: swap two same-width fields and every existing
    // check (magic, version, byte count) still passes, while every load
    // scrambles the machine. The fingerprint must move; the size must not.
    const A = struct { x: u8, y: u8, v: [4]u16 };
    const B = struct { y: u8, x: u8, v: [4]u16 };
    try std.testing.expectEqual(comptime byteSize(A), comptime byteSize(B));
    try std.testing.expect(fingerprint(A) != fingerprint(B));

    // Same-size type change (u16 -> i16): same bytes on the wire, different
    // meaning. Caught.
    const C = struct { x: u8, y: u8, v: [4]i16 };
    try std.testing.expectEqual(comptime byteSize(A), comptime byteSize(C));
    try std.testing.expect(fingerprint(A) != fingerprint(C));

    // A rename alone is a layout change too (the name is the schema).
    const D = struct { x: u8, z: u8, v: [4]u16 };
    try std.testing.expect(fingerprint(A) != fingerprint(D));

    // Flattening a nested struct keeps the bytes and the field names in the
    // same order; nesting still must matter.
    const Nested = struct { p: struct { x: u8, y: u8 }, q: u8 };
    const Flat = struct { p: struct { x: u8 }, y: u8, q: u8 };
    try std.testing.expectEqual(comptime byteSize(Nested), comptime byteSize(Flat));
    try std.testing.expect(fingerprint(Nested) != fingerprint(Flat));

    // Skipped fields are not part of the wire format, so they must not be
    // part of the fingerprint either.
    const E = struct {
        pub const serialize_skip = .{"scratch"};
        x: u8,
        y: u8,
        v: [4]u16,
        scratch: u64,
    };
    try std.testing.expectEqual(fingerprint(A), fingerprint(E));

    // And it is a stable function of the layout, not of the run.
    try std.testing.expectEqual(fingerprint(A), fingerprint(A));
}

test "array fast path is byte-identical to the element loop" {
    // The fast path memcpys full-width integer arrays; this pins its output
    // to what the element loop (writeInt per element, little-endian) emits.
    const S = struct {
        a: [5]u16,
        b: [3]u32,
        c: [4]i16,
        d: [2]u24, // 24-bit: stored in 3 wire bytes, stays on the element loop
        e: [3]u8,
    };
    const v: S = .{
        .a = .{ 0x1234, 0xFFFF, 0, 0x8000, 0xABCD },
        .b = .{ 0xDEADBEEF, 1, 0x80000000 },
        .c = .{ -1, 32767, -32768, 0x1234 },
        .d = .{ 0xABCDEF, 0x000001 },
        .e = .{ 9, 8, 7 },
    };
    var got: [byteSize(S)]u8 = undefined;
    try std.testing.expectEqual(got.len, write(S, &v, &got));

    // Reference encoding, element by element.
    var want: [byteSize(S)]u8 = undefined;
    var off: usize = 0;
    for (v.a) |x| {
        std.mem.writeInt(u16, want[off..][0..2], x, .little);
        off += 2;
    }
    for (v.b) |x| {
        std.mem.writeInt(u32, want[off..][0..4], x, .little);
        off += 4;
    }
    for (v.c) |x| {
        std.mem.writeInt(u16, want[off..][0..2], @bitCast(x), .little);
        off += 2;
    }
    for (v.d) |x| {
        std.mem.writeInt(u24, want[off..][0..3], x, .little);
        off += 3;
    }
    @memcpy(want[off..][0..3], &v.e);
    off += 3;
    try std.testing.expectEqual(want.len, off);
    try std.testing.expectEqualSlices(u8, &want, &got);

    // And the read fast path roundtrips it.
    var back: S = std.mem.zeroes(S);
    try std.testing.expectEqual(got.len, try read(S, &back, &got));
    try std.testing.expectEqual(v, back);
}

test "array fast path respects short input" {
    const S = struct { a: [4]u32 };
    const v: S = .{ .a = .{ 1, 2, 3, 4 } };
    var buf: [byteSize(S)]u8 = undefined;
    _ = write(S, &v, &buf);
    var back: S = std.mem.zeroes(S);
    try std.testing.expectError(error.EndOfState, read(S, &back, buf[0 .. buf.len - 1]));
}
