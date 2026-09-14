//! Reading a ROM out of a `.zip` archive, in memory, against `std` alone.
//!
//! The archive is already in a byte slice (a ROM archive is a few MiB;
//! `readRomFile` caps the read), so this walks the central directory
//! directly instead of driving `std.zip.Iterator` over a `File.Reader`:
//! find the end record, walk the central directory entries, pick the one
//! that looks like a SNES ROM, seek to its local header, and inflate (or
//! copy) exactly the declared number of bytes. The entry's CRC32 is checked
//! so a truncated or mis-declared member is an error, never a short ROM.
//!
//! Which member is the ROM: the first whose name ends in `.sfc`/`.smc`
//! (case-insensitive; directory prefixes are fine); failing that, an
//! archive holding exactly one file is taken to be that file (`game.zip`
//! around an extension-less dump). Anything else is refused by name, so a
//! zip of screenshots in a ROM folder says why it is not a game.
//!
//! Not handled, and refused with a distinct error rather than misread:
//! zip64 archives (a ROM never needs one), encrypted members, and
//! compression methods other than store and deflate.

const std = @import("std");
const zip = std.zip;
const flate = std.compress.flate;

pub const Error = error{
    NotAZip,
    Zip64Unsupported,
    Encrypted,
    UnsupportedCompression,
    NoRomInside,
    TooLarge,
    Corrupt,
    OutOfMemory,
};

/// `.zip` by extension, case-insensitive — the only signal the loaders
/// need, since a mis-named archive fails header detection the same way any
/// other non-ROM does.
pub fn isZipPath(path: []const u8) bool {
    return path.len > 4 and std.ascii.eqlIgnoreCase(path[path.len - 4 ..], ".zip");
}

/// A ROM-looking member name: the extensions the library scanner accepts.
pub fn isRomName(name: []const u8) bool {
    for ([_][]const u8{ ".sfc", ".smc" }) |ext| {
        if (name.len > ext.len and std.ascii.eqlIgnoreCase(name[name.len - ext.len ..], ext)) return true;
    }
    return false;
}

const Member = struct {
    name: []const u8,
    method: u16,
    encrypted: bool,
    crc32: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    local_header_offset: u32,
};

const method_store: u16 = 0;
const method_deflate: u16 = 8;

/// Record sizes, from the format: the fixed part of each record precedes
/// its variable-length name/extra/comment fields.
const end_record_len = 22;
const central_header_len = 46;
const local_header_len = 30;

/// Little-endian field reads; the records are laid out by the format, not
/// by a struct, so the offsets are spelled out where they are used.
fn u16At(bytes: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, bytes[off..][0..2], .little);
}
fn u32At(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}

/// Walk the central directory. Directory entries (a trailing `/`) are
/// skipped; everything else is returned in archive order.
fn members(gpa: std.mem.Allocator, bytes: []const u8) Error![]Member {
    // The end record is the last thing in the file, behind at most a
    // 64 KiB comment: the last signature that leaves room for the record.
    const end_pos = std.mem.lastIndexOf(u8, bytes, &zip.end_record_sig) orelse return error.NotAZip;
    if (end_pos + end_record_len > bytes.len) return error.NotAZip;
    const count = u16At(bytes, end_pos + 10);
    const cd_size = u32At(bytes, end_pos + 12);
    const cd_off = u32At(bytes, end_pos + 16);
    if (count == 0xFFFF or cd_size == 0xFFFF_FFFF or cd_off == 0xFFFF_FFFF) return error.Zip64Unsupported;

    var list: std.ArrayList(Member) = .empty;
    errdefer list.deinit(gpa);
    var off: usize = cd_off;
    const cd_end = @as(usize, cd_off) + cd_size;
    if (cd_end > bytes.len) return error.Corrupt;
    for (0..count) |_| {
        if (off + central_header_len > cd_end) return error.Corrupt;
        if (!std.mem.eql(u8, bytes[off..][0..4], &zip.central_file_header_sig)) return error.Corrupt;
        const flags = u16At(bytes, off + 8);
        const name_len = u16At(bytes, off + 28);
        const extra_len = u16At(bytes, off + 30);
        const comment_len = u16At(bytes, off + 32);
        const name_off = off + central_header_len;
        const next = name_off + name_len + extra_len + comment_len;
        if (next > cd_end) return error.Corrupt;
        const name = bytes[name_off..][0..name_len];
        const m: Member = .{
            .name = name,
            .method = u16At(bytes, off + 10),
            .encrypted = flags & 1 != 0,
            .crc32 = u32At(bytes, off + 16),
            .compressed_size = u32At(bytes, off + 20),
            .uncompressed_size = u32At(bytes, off + 24),
            .local_header_offset = u32At(bytes, off + 42),
        };
        off = next;
        if (name.len != 0 and name[name.len - 1] == '/') continue;
        try list.append(gpa, m);
    }
    return list.toOwnedSlice(gpa);
}

/// The member the ROM is: the first ROM-named file, else the only file.
fn pickRom(all: []const Member) ?Member {
    for (all) |m| if (isRomName(m.name)) return m;
    if (all.len == 1) return all[0];
    return null;
}

/// Extract the ROM member of the archive in `bytes` into a fresh buffer of
/// exactly its declared size, which must not exceed `limit`.
pub fn extractRom(gpa: std.mem.Allocator, bytes: []const u8, limit: usize) Error![]u8 {
    const all = try members(gpa, bytes);
    defer gpa.free(all);
    const m = pickRom(all) orelse return error.NoRomInside;
    if (m.encrypted) return error.Encrypted;
    if (m.uncompressed_size > limit) return error.TooLarge;
    if (m.method != method_store and m.method != method_deflate) return error.UnsupportedCompression;

    // The local header repeats the name and extra fields with its own
    // lengths; the data follows them. Sizes come from the central directory
    // (a member written with a data descriptor leaves the local ones 0).
    const lh_off: usize = m.local_header_offset;
    if (lh_off + local_header_len > bytes.len) return error.Corrupt;
    if (!std.mem.eql(u8, bytes[lh_off..][0..4], &zip.local_file_header_sig)) return error.Corrupt;
    const data_off = lh_off + local_header_len + u16At(bytes, lh_off + 26) + u16At(bytes, lh_off + 28);
    if (data_off + m.compressed_size > bytes.len) return error.Corrupt;
    const data = bytes[data_off..][0..m.compressed_size];

    const out = try gpa.alloc(u8, m.uncompressed_size);
    errdefer gpa.free(out);
    if (m.method == method_store) {
        if (data.len != out.len) return error.Corrupt;
        @memcpy(out, data);
    } else {
        var in: std.Io.Reader = .fixed(data);
        const window = try gpa.alloc(u8, flate.max_window_len);
        defer gpa.free(window);
        var dec: flate.Decompress = .init(&in, .raw, window);
        dec.reader.readSliceAll(out) catch return error.Corrupt;
    }
    if (std.hash.Crc32.hash(out) != m.crc32) return error.Corrupt;
    return out;
}

/// What a refusal means, in the words the loaders print.
pub fn describe(e: Error) []const u8 {
    return switch (e) {
        error.NotAZip => "not a zip archive",
        error.Zip64Unsupported => "zip64 archives are not supported",
        error.Encrypted => "the ROM inside is encrypted",
        error.UnsupportedCompression => "the ROM inside uses a compression method other than deflate",
        error.NoRomInside => "no .sfc/.smc inside, and more than one file",
        error.TooLarge => "the ROM inside is larger than a cartridge can be",
        error.Corrupt => "the archive is damaged",
        error.OutOfMemory => "out of memory",
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

/// A test-side zip writer: local headers, central directory, end record,
/// in the layout every zip tool produces. `deflate` picks the method per
/// member; a stored member is copied verbatim.
pub const TestZip = struct {
    pub const Item = struct { name: []const u8, data: []const u8, deflate: bool = true, encrypted: bool = false };

    pub fn build(gpa: std.mem.Allocator, items: []const Item) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        var offsets = try gpa.alloc(u32, items.len);
        defer gpa.free(offsets);
        var payloads = try gpa.alloc([]u8, items.len);
        defer {
            for (payloads) |p| gpa.free(p);
            gpa.free(payloads);
        }
        for (items, 0..) |it, i| {
            payloads[i] = if (it.deflate) try deflateRaw(gpa, it.data) else try gpa.dupe(u8, it.data);
            offsets[i] = @intCast(out.written().len);
            try w.writeAll(&zip.local_file_header_sig);
            try w.writeInt(u16, 20, .little); // version needed
            try w.writeInt(u16, if (it.encrypted) 1 else 0, .little); // flags
            try w.writeInt(u16, if (it.deflate) 8 else 0, .little);
            try w.writeInt(u16, 0, .little); // time
            try w.writeInt(u16, 0, .little); // date
            try w.writeInt(u32, std.hash.Crc32.hash(it.data), .little);
            try w.writeInt(u32, @intCast(payloads[i].len), .little);
            try w.writeInt(u32, @intCast(it.data.len), .little);
            try w.writeInt(u16, @intCast(it.name.len), .little);
            try w.writeInt(u16, 4, .little); // an extra field, to prove it is skipped
            try w.writeAll(it.name);
            try w.writeAll(&.{ 0x55, 0x55, 0, 0 });
            try w.writeAll(payloads[i]);
        }
        const cd_start: u32 = @intCast(out.written().len);
        for (items, 0..) |it, i| {
            try w.writeAll(&zip.central_file_header_sig);
            try w.writeInt(u16, 20, .little); // made by
            try w.writeInt(u16, 20, .little); // needed
            try w.writeInt(u16, if (it.encrypted) 1 else 0, .little);
            try w.writeInt(u16, if (it.deflate) 8 else 0, .little);
            try w.writeInt(u16, 0, .little);
            try w.writeInt(u16, 0, .little);
            try w.writeInt(u32, std.hash.Crc32.hash(it.data), .little);
            try w.writeInt(u32, @intCast(payloads[i].len), .little);
            try w.writeInt(u32, @intCast(it.data.len), .little);
            try w.writeInt(u16, @intCast(it.name.len), .little);
            try w.writeInt(u16, 0, .little); // extra
            try w.writeInt(u16, 3, .little); // comment
            try w.writeInt(u16, 0, .little); // disk
            try w.writeInt(u16, 0, .little); // internal attrs
            try w.writeInt(u32, 0, .little); // external attrs
            try w.writeInt(u32, offsets[i], .little);
            try w.writeAll(it.name);
            try w.writeAll("hi!");
        }
        const cd_size: u32 = @as(u32, @intCast(out.written().len)) - cd_start;
        try w.writeAll(&zip.end_record_sig);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, @intCast(items.len), .little);
        try w.writeInt(u16, @intCast(items.len), .little);
        try w.writeInt(u32, cd_size, .little);
        try w.writeInt(u32, cd_start, .little);
        try w.writeInt(u16, 0, .little);
        return out.toOwnedSlice();
    }

    fn deflateRaw(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
        // The compressor asserts a real output buffer up front.
        var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
        errdefer out.deinit();
        const window = try gpa.alloc(u8, flate.max_window_len);
        defer gpa.free(window);
        var comp = try flate.Compress.init(&out.writer, window, .raw, .default);
        try comp.writer.writeAll(data);
        try comp.finish();
        return out.toOwnedSlice();
    }
};

fn fakeRom(seed: u8) [4096]u8 {
    var rom: [4096]u8 = undefined;
    for (&rom, 0..) |*b, i| b.* = @intCast((i * 31 + seed) & 0xFF);
    return rom;
}

test "zipfile: extracts the ROM member, deflated or stored, past other files" {
    const a = testing.allocator;
    const rom = fakeRom(1);
    const other = fakeRom(2);
    const z = try TestZip.build(a, &.{
        .{ .name = "readme.txt", .data = "not a rom" },
        .{ .name = "sub/", .data = "" },
        .{ .name = "sub/Game (USA).SMC", .data = &rom },
        .{ .name = "sub/other.sfc", .data = &other },
    });
    defer a.free(z);
    const got = try extractRom(a, z, 16 << 20);
    defer a.free(got);
    try testing.expectEqualSlices(u8, &rom, got);

    const stored = try TestZip.build(a, &.{.{ .name = "game.sfc", .data = &rom, .deflate = false }});
    defer a.free(stored);
    const got2 = try extractRom(a, stored, 16 << 20);
    defer a.free(got2);
    try testing.expectEqualSlices(u8, &rom, got2);
}

test "zipfile: a lone extension-less member is the ROM; two unnamed ones are not" {
    const a = testing.allocator;
    const rom = fakeRom(3);
    const lone = try TestZip.build(a, &.{.{ .name = "dump", .data = &rom }});
    defer a.free(lone);
    const got = try extractRom(a, lone, 16 << 20);
    defer a.free(got);
    try testing.expectEqualSlices(u8, &rom, got);

    const two = try TestZip.build(a, &.{ .{ .name = "a.bin", .data = &rom }, .{ .name = "b.bin", .data = &rom } });
    defer a.free(two);
    try testing.expectError(error.NoRomInside, extractRom(a, two, 16 << 20));
}

test "zipfile: refusals name their cause" {
    const a = testing.allocator;
    const rom = fakeRom(4);
    try testing.expectError(error.NotAZip, extractRom(a, "PK\x03\x04 nope", 16 << 20));

    const enc = try TestZip.build(a, &.{.{ .name = "g.sfc", .data = &rom, .encrypted = true }});
    defer a.free(enc);
    try testing.expectError(error.Encrypted, extractRom(a, enc, 16 << 20));

    const ok = try TestZip.build(a, &.{.{ .name = "g.sfc", .data = &rom }});
    defer a.free(ok);
    try testing.expectError(error.TooLarge, extractRom(a, ok, rom.len - 1));

    // Flip a payload byte: the inflated bytes no longer match the CRC.
    const bad = try a.dupe(u8, ok);
    defer a.free(bad);
    bad[40] ^= 0xFF;
    try testing.expectError(error.Corrupt, extractRom(a, bad, 16 << 20));

    // A truncated archive has lost its end record: not a zip at all. One
    // whose end record points past the file is damaged.
    try testing.expectError(error.NotAZip, extractRom(a, ok[0 .. ok.len - 30], 16 << 20));
    const off_end = try a.dupe(u8, ok);
    defer a.free(off_end);
    const end_pos = std.mem.lastIndexOf(u8, off_end, &zip.end_record_sig).?;
    std.mem.writeInt(u32, off_end[end_pos + 16 ..][0..4], 0x00FF_0000, .little);
    try testing.expectError(error.Corrupt, extractRom(a, off_end, 16 << 20));
    try testing.expectEqualStrings("the archive is damaged", describe(error.Corrupt));
}

test "zipfile: path and member-name predicates" {
    try testing.expect(isZipPath("roms/Game.ZIP"));
    try testing.expect(!isZipPath(".zip"));
    try testing.expect(!isZipPath("Game.sfc"));
    try testing.expect(isRomName("x/y.Sfc"));
    try testing.expect(!isRomName("x/y.png"));
}
