//! Soft-patching: apply a BPS or IPS patch to a ROM image in memory.
//!
//! This is the gateway of the M12 patch layer — it is what makes the
//! community's SA-1 conversions, FastROM patches, translations, and bugfixes
//! loadable without ever mutating the file on disk. The two formats carry very
//! different guarantees and the API is honest about that:
//!
//! * **BPS** ships three CRC32s. The *source* CRC is verified BEFORE anything
//!   is applied — a patch silently landing on the wrong ROM revision is an
//!   error naming both checksums, not a corrupted cart. The *target* CRC is
//!   verified after, and the *patch* CRC guards the patch file itself.
//! * **IPS** has no checksums at all. It applies blindly, and the caller is
//!   told so (`Applied.verified == false`) so the frontend can warn.
//!
//! Formats are detected by magic ("BPS1" / "PATCH"), never by file name.
//! Pure Zig, no OS calls; the only allocation is the target image, through the
//! caller's allocator — the same contract as `Cartridge.load`.

const std = @import("std");

pub const Error = error{
    /// Neither a BPS nor an IPS magic.
    UnknownFormat,
    /// The patch file is structurally broken (truncated, bad varint, bad
    /// record, action past the end).
    Corrupt,
    /// BPS only: the patch's own CRC32 does not match its footer — the file
    /// was damaged in transit.
    PatchChecksum,
    /// BPS only: this patch was made for a different ROM revision. The caller
    /// gets the two CRCs via `crc_mismatch` to print.
    WrongSource,
    /// BPS only: the output failed the target CRC — the apply itself is
    /// broken (ours or the patch author's).
    TargetChecksum,
    OutOfMemory,
};

/// The outcome of a successful apply.
pub const Applied = struct {
    /// The patched image, owned by the caller's allocator.
    image: []u8,
    /// True when the format carried checksums and they all passed (BPS).
    /// False for IPS, which cannot promise anything — warn the user.
    verified: bool,
};

/// Filled in on `error.WrongSource` so the frontend can name both sides.
pub const CrcMismatch = struct {
    expected: u32 = 0,
    actual: u32 = 0,
};

/// Detect the patch format and apply it. `mismatch` is written only on
/// `error.WrongSource`.
pub fn apply(
    gpa: std.mem.Allocator,
    source: []const u8,
    patch: []const u8,
    mismatch: *CrcMismatch,
) Error!Applied {
    if (std.mem.startsWith(u8, patch, "BPS1"))
        return applyBps(gpa, source, patch, mismatch);
    if (std.mem.startsWith(u8, patch, "PATCH"))
        return applyIps(gpa, source, patch);
    return Error.UnknownFormat;
}

// --- CRC32 (IEEE, reflected — the one every patcher uses) ---------------------

const crc_table = blk: {
    @setEvalBranchQuota(10_000);
    var table: [256]u32 = undefined;
    for (&table, 0..) |*e, i| {
        var c: u32 = @intCast(i);
        for (0..8) |_| {
            c = if (c & 1 != 0) 0xEDB8_8320 ^ (c >> 1) else c >> 1;
        }
        e.* = c;
    }
    break :blk table;
};

pub fn crc32(bytes: []const u8) u32 {
    var c: u32 = 0xFFFF_FFFF;
    for (bytes) |b| c = crc_table[(c ^ b) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFF_FFFF;
}

// --- BPS -----------------------------------------------------------------------

const BpsAction = enum(u2) { source_read, target_read, source_copy, target_copy };

/// byuu's variable-width integer: 7 data bits per byte, terminator bit set on
/// the LAST byte, and each continuation implicitly adds the next power step so
/// no value has two encodings.
fn bpsVarint(patch: []const u8, pos: *usize) Error!u64 {
    var data: u64 = 0;
    var shift: u64 = 1;
    while (true) {
        if (pos.* >= patch.len) return Error.Corrupt;
        const x = patch[pos.*];
        pos.* += 1;
        data +%= @as(u64, x & 0x7F) *% shift;
        if (x & 0x80 != 0) return data;
        shift <<= 7;
        data +%= shift;
    }
}

fn applyBps(
    gpa: std.mem.Allocator,
    source: []const u8,
    patch: []const u8,
    mismatch: *CrcMismatch,
) Error!Applied {
    // Header (4) + three footer CRCs (12) is the minimum viable file.
    if (patch.len < 4 + 12) return Error.Corrupt;
    const footer = patch[patch.len - 12 ..];
    const src_crc_want = std.mem.readInt(u32, footer[0..4], .little);
    const tgt_crc_want = std.mem.readInt(u32, footer[4..8], .little);
    const patch_crc_want = std.mem.readInt(u32, footer[8..12], .little);

    // The patch guards itself first: its CRC covers everything before it.
    if (crc32(patch[0 .. patch.len - 4]) != patch_crc_want) return Error.PatchChecksum;

    // Then the source, BEFORE any work: wrong ROM revision is a refusal with
    // both numbers, not a corrupt cart.
    const src_crc = crc32(source);
    if (src_crc != src_crc_want) {
        mismatch.* = .{ .expected = src_crc_want, .actual = src_crc };
        return Error.WrongSource;
    }

    var pos: usize = 4;
    const source_size = try bpsVarint(patch, &pos);
    const target_size = try bpsVarint(patch, &pos);
    const metadata_size = try bpsVarint(patch, &pos);
    if (source_size != source.len) return Error.Corrupt;
    if (metadata_size > patch.len) return Error.Corrupt;
    pos += @intCast(metadata_size);

    const target = try gpa.alloc(u8, @intCast(target_size));
    errdefer gpa.free(target);

    const actions_end = patch.len - 12;
    var out: usize = 0;
    var src_rel: usize = 0; // SourceCopy read cursor
    var tgt_rel: usize = 0; // TargetCopy read cursor

    while (pos < actions_end) {
        const data = try bpsVarint(patch, &pos);
        const action: BpsAction = @enumFromInt(@as(u2, @truncate(data)));
        const length: usize = @intCast((data >> 2) + 1);
        if (out + length > target.len) return Error.Corrupt;

        switch (action) {
            .source_read => {
                // Reads the source at the OUTPUT offset.
                if (out + length > source.len) return Error.Corrupt;
                @memcpy(target[out..][0..length], source[out..][0..length]);
            },
            .target_read => {
                if (pos + length > actions_end) return Error.Corrupt;
                @memcpy(target[out..][0..length], patch[pos..][0..length]);
                pos += length;
            },
            .source_copy, .target_copy => {
                const raw = try bpsVarint(patch, &pos);
                const mag: usize = @intCast(raw >> 1);
                const neg = raw & 1 != 0;
                if (action == .source_copy) {
                    src_rel = if (neg) std.math.sub(usize, src_rel, mag) catch return Error.Corrupt else src_rel + mag;
                    if (src_rel + length > source.len) return Error.Corrupt;
                    @memcpy(target[out..][0..length], source[src_rel..][0..length]);
                    src_rel += length;
                } else {
                    tgt_rel = if (neg) std.math.sub(usize, tgt_rel, mag) catch return Error.Corrupt else tgt_rel + mag;
                    if (tgt_rel + length > out + length) return Error.Corrupt;
                    // Byte-by-byte on purpose: TargetCopy may overlap its own
                    // output (RLE-style runs read what they just wrote).
                    for (0..length) |i| target[out + i] = target[tgt_rel + i];
                    tgt_rel += length;
                }
            },
        }
        out += length;
    }
    if (out != target.len) return Error.Corrupt;

    if (crc32(target) != tgt_crc_want) return Error.TargetChecksum;
    return .{ .image = target, .verified = true };
}

// --- IPS -----------------------------------------------------------------------

fn applyIps(gpa: std.mem.Allocator, source: []const u8, patch: []const u8) Error!Applied {
    if (patch.len < 5 + 3) return Error.Corrupt;

    // First pass: find the output size (records can extend past the source)
    // and validate the record structure, so allocation happens exactly once.
    var end: usize = source.len;
    var pos: usize = 5;
    var truncate_to: ?usize = null;
    while (true) {
        if (pos + 3 > patch.len) return Error.Corrupt;
        if (std.mem.eql(u8, patch[pos..][0..3], "EOF")) {
            // Optional truncation extension: 3 more bytes after EOF.
            if (patch.len == pos + 6) {
                truncate_to = (@as(usize, patch[pos + 3]) << 16) |
                    (@as(usize, patch[pos + 4]) << 8) | patch[pos + 5];
            } else if (patch.len != pos + 3) {
                return Error.Corrupt;
            }
            break;
        }
        const off = (@as(usize, patch[pos]) << 16) | (@as(usize, patch[pos + 1]) << 8) | patch[pos + 2];
        pos += 3;
        if (pos + 2 > patch.len) return Error.Corrupt;
        const size = (@as(usize, patch[pos]) << 8) | patch[pos + 1];
        pos += 2;
        if (size == 0) {
            // RLE record: 2-byte run length + 1 fill byte.
            if (pos + 3 > patch.len) return Error.Corrupt;
            const run = (@as(usize, patch[pos]) << 8) | patch[pos + 1];
            pos += 3;
            end = @max(end, off + run);
        } else {
            if (pos + size > patch.len) return Error.Corrupt;
            pos += size;
            end = @max(end, off + size);
        }
    }

    const out_len = if (truncate_to) |t| t else end;
    const target = try gpa.alloc(u8, out_len);
    errdefer gpa.free(target);
    const copy = @min(source.len, out_len);
    @memcpy(target[0..copy], source[0..copy]);
    if (out_len > source.len) @memset(target[source.len..], 0);

    // Second pass: apply. Structure was validated above.
    pos = 5;
    while (!std.mem.eql(u8, patch[pos..][0..3], "EOF")) {
        const off = (@as(usize, patch[pos]) << 16) | (@as(usize, patch[pos + 1]) << 8) | patch[pos + 2];
        pos += 3;
        const size = (@as(usize, patch[pos]) << 8) | patch[pos + 1];
        pos += 2;
        if (size == 0) {
            const run = (@as(usize, patch[pos]) << 8) | patch[pos + 1];
            const fill = patch[pos + 2];
            pos += 3;
            if (off + run <= target.len) @memset(target[off..][0..run], fill);
        } else {
            const n = @min(size, target.len -| off);
            @memcpy(target[off..][0..n], patch[pos..][0..n]);
            pos += size;
        }
    }

    // IPS carries no checksums: applied, but unverifiable.
    return .{ .image = target, .verified = false };
}

// --- tests ---------------------------------------------------------------------

const testing = std.testing;

test "crc32 matches the reference vector" {
    // The IEEE check value everyone validates against.
    try testing.expectEqual(@as(u32, 0xCBF4_3926), crc32("123456789"));
}

/// Encode a value in BPS varint form, for building synthetic patches.
fn putVarint(list: *std.array_list.Managed(u8), value: u64) !void {
    var data = value;
    while (true) {
        const x: u8 = @truncate(data & 0x7F);
        data >>= 7;
        if (data == 0) {
            try list.append(0x80 | x);
            return;
        }
        try list.append(x);
        data -= 1;
    }
}

/// Build a whole BPS patch from actions, with correct CRCs.
fn buildBps(gpa: std.mem.Allocator, source: []const u8, target: []const u8, actions: []const u8) ![]u8 {
    var p: std.array_list.Managed(u8) = .init(gpa);
    try p.appendSlice("BPS1");
    try putVarint(&p, source.len);
    try putVarint(&p, target.len);
    try putVarint(&p, 0); // no metadata
    try p.appendSlice(actions);
    var crcs: [12]u8 = undefined;
    std.mem.writeInt(u32, crcs[0..4], crc32(source), .little);
    std.mem.writeInt(u32, crcs[4..8], crc32(target), .little);
    try p.appendSlice(crcs[0..8]);
    std.mem.writeInt(u32, crcs[8..12], crc32(p.items), .little);
    try p.appendSlice(crcs[8..12]);
    return p.toOwnedSlice();
}

test "bps: source-read + target-read round-trips" {
    const gpa = testing.allocator;
    const source = "HELLO WORLD ROM!";
    const target = "HELLO patch ROM!";

    // Actions: SourceRead 6 ("HELLO "), TargetRead 5 ("patch"), SourceRead 5 (" ROM!").
    var acts: std.array_list.Managed(u8) = .init(gpa);
    defer acts.deinit();
    try putVarint(&acts, ((6 - 1) << 2) | 0);
    try putVarint(&acts, ((5 - 1) << 2) | 1);
    try acts.appendSlice("patch");
    try putVarint(&acts, ((5 - 1) << 2) | 0);

    const patch = try buildBps(gpa, source, target, acts.items);
    defer gpa.free(patch);

    var mm: CrcMismatch = .{};
    const got = try apply(gpa, source, patch, &mm);
    defer gpa.free(got.image);
    try testing.expectEqualStrings(target, got.image);
    try testing.expect(got.verified);
}

test "bps: source-copy and overlapping target-copy" {
    const gpa = testing.allocator;
    const source = "ABCDEF";
    const target = "DEFXXXX"; // DEF from source offset 3, then X repeated by overlap

    var acts: std.array_list.Managed(u8) = .init(gpa);
    defer acts.deinit();
    // SourceCopy len 3, offset +3.
    try putVarint(&acts, ((3 - 1) << 2) | 2);
    try putVarint(&acts, 3 << 1);
    // TargetRead "X".
    try putVarint(&acts, ((1 - 1) << 2) | 1);
    try acts.appendSlice("X");
    // TargetCopy len 3 from offset 3 (one behind the cursor): classic RLE overlap.
    try putVarint(&acts, ((3 - 1) << 2) | 3);
    try putVarint(&acts, 3 << 1);

    const patch = try buildBps(gpa, source, target, acts.items);
    defer gpa.free(patch);

    var mm: CrcMismatch = .{};
    const got = try apply(gpa, source, patch, &mm);
    defer gpa.free(got.image);
    try testing.expectEqualStrings(target, got.image);
}

test "bps: the wrong ROM revision is refused before any work, with both CRCs" {
    const gpa = testing.allocator;
    const source = "CORRECT SOURCE!!";
    const target = "CORRECT TARGET!!";
    var acts: std.array_list.Managed(u8) = .init(gpa);
    defer acts.deinit();
    try putVarint(&acts, ((16 - 1) << 2) | 1);
    try acts.appendSlice(target);
    const patch = try buildBps(gpa, source, target, acts.items);
    defer gpa.free(patch);

    var mm: CrcMismatch = .{};
    const wrong = "DIFFERENT ROM!!!";
    try testing.expectError(Error.WrongSource, apply(gpa, wrong, patch, &mm));
    try testing.expectEqual(crc32(source), mm.expected);
    try testing.expectEqual(crc32(wrong), mm.actual);
}

test "bps: a damaged patch file is refused by its own checksum" {
    const gpa = testing.allocator;
    const source = "SRC0";
    var acts: std.array_list.Managed(u8) = .init(gpa);
    defer acts.deinit();
    try putVarint(&acts, ((4 - 1) << 2) | 0);
    const patch = try buildBps(gpa, source, source, acts.items);
    defer gpa.free(patch);
    patch[6] ^= 0xFF; // corrupt one byte of the body

    var mm: CrcMismatch = .{};
    try testing.expectError(Error.PatchChecksum, apply(gpa, source, patch, &mm));
}

test "ips: records, RLE, extension past the source, and truncation" {
    const gpa = testing.allocator;
    const source = "AAAABBBBCCCC";

    var p: std.array_list.Managed(u8) = .init(gpa);
    defer p.deinit();
    try p.appendSlice("PATCH");
    // Record: offset 4, size 2, "XY".
    try p.appendSlice(&.{ 0, 0, 4, 0, 2 });
    try p.appendSlice("XY");
    // RLE: offset 8, size 0, run 3, fill '!'.
    try p.appendSlice(&.{ 0, 0, 8, 0, 0, 0, 3, '!' });
    // Record past the end: offset 12, size 2 -> output grows to 14.
    try p.appendSlice(&.{ 0, 0, 12, 0, 2 });
    try p.appendSlice("ZZ");
    try p.appendSlice("EOF");

    var mm: CrcMismatch = .{};
    const got = try apply(gpa, source, p.items, &mm);
    defer gpa.free(got.image);
    try testing.expectEqualStrings("AAAAXYBB!!!CZZ", got.image);
    try testing.expect(!got.verified); // IPS cannot verify anything

    // Truncation extension: same patch with a truncate-to-13 tail.
    try p.resize(p.items.len);
    try p.appendSlice(&.{ 0, 0, 13 });
    const got2 = try apply(gpa, source, p.items, &mm);
    defer gpa.free(got2.image);
    try testing.expectEqual(@as(usize, 13), got2.image.len);
}

test "unknown magic is refused" {
    var mm: CrcMismatch = .{};
    try testing.expectError(Error.UnknownFormat, apply(testing.allocator, "ROM", "NOTAPATCH", &mm));
}

test "truncated bps fails its own checksum before anything else" {
    // A blindly-truncated file cannot have a valid footer CRC, so the patch
    // guards itself first — the structure is never even parsed.
    var mm: CrcMismatch = .{};
    try testing.expectError(Error.PatchChecksum, apply(testing.allocator, "ROM", "BPS1" ++ "\x80" ** 12, &mm));
}

test "structurally broken bps behind valid checksums is corrupt, not a crash" {
    const gpa = testing.allocator;
    const source = "ROM";
    // Body: magic + one UNTERMINATED varint byte (0x00 = continuation with no
    // successor). Give it a correct patch CRC and the real source CRC so the
    // parse gets past both gates and dies on the structure.
    var p: std.array_list.Managed(u8) = .init(gpa);
    defer p.deinit();
    try p.appendSlice("BPS1");
    try p.append(0x00);
    var crcs: [12]u8 = undefined;
    std.mem.writeInt(u32, crcs[0..4], crc32(source), .little);
    std.mem.writeInt(u32, crcs[4..8], 0xDEAD_BEEF, .little);
    try p.appendSlice(crcs[0..8]);
    std.mem.writeInt(u32, crcs[8..12], crc32(p.items), .little);
    try p.appendSlice(crcs[8..12]);

    var mm: CrcMismatch = .{};
    try testing.expectError(Error.Corrupt, apply(gpa, source, p.items, &mm));
}
