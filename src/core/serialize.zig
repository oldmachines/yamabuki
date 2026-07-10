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
