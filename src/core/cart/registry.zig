//! The `--auto-patch` registry: which published patch belongs to which ROM.
//!
//! The repo commits `patches/registry.zon` — an index of {source ROM sha256,
//! patch file name, patch sha256, upstream URL} — and never a patch payload,
//! never a ROM. This module is the lookup: the frontend hashes the loaded
//! image, asks `find`, and does all file I/O itself. Nothing here (or
//! anywhere in the emulator) touches the network; when the patch file is
//! absent the frontend prints the URL and moves on.
//!
//! The registry pins the patch file's own sha256 too, and the frontend must
//! refuse a mismatch: a patch that is not byte-for-byte the one that was
//! verified upstream is not "probably fine", it is unknown code for someone
//! else's ROM. (BPS's internal checksums would catch most corruption at apply
//! time, but IPS has none — the registry hash is the guarantee that covers
//! both formats.)

const std = @import("std");

pub const Entry = struct {
    /// Lowercase hex sha256 of the copier-stripped source ROM.
    source_sha256: []const u8,
    title: []const u8,
    /// File name expected in the patch directory.
    patch_name: []const u8,
    /// Lowercase hex sha256 of the patch file itself.
    patch_sha256: []const u8,
    /// Where a missing patch can be fetched from — by the user, never by us.
    url: []const u8,
    license_note: []const u8,
};

const Registry = struct {
    patches: []const Entry,
};

pub const registry: Registry = @import("patch_registry.zon");

/// Look up the loaded ROM by the hex sha256 of its stripped image.
pub fn find(source_sha256_hex: []const u8) ?*const Entry {
    for (registry.patches) |*e| {
        if (std.ascii.eqlIgnoreCase(e.source_sha256, source_sha256_hex)) return e;
    }
    return null;
}

/// sha256 as lowercase hex — the registry's key format.
pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var hex: [64]u8 = undefined;
    const digits = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        hex[i * 2] = digits[b >> 4];
        hex[i * 2 + 1] = digits[b & 0xF];
    }
    return hex;
}

// --- tests -------------------------------------------------------------------

test "every committed entry is well-formed" {
    // A malformed registry should fail here, in CI, not at a user's load.
    try std.testing.expect(registry.patches.len >= 3);
    for (registry.patches) |e| {
        try std.testing.expectEqual(@as(usize, 64), e.source_sha256.len);
        try std.testing.expectEqual(@as(usize, 64), e.patch_sha256.len);
        for (e.source_sha256) |c| try std.testing.expect(std.ascii.isHex(c));
        for (e.patch_sha256) |c| try std.testing.expect(std.ascii.isHex(c));
        try std.testing.expect(e.title.len > 0);
        try std.testing.expect(e.patch_name.len > 0);
        try std.testing.expect(std.mem.startsWith(u8, e.url, "https://"));
    }
    // Keys must be unique: two entries for one dump would make --auto-patch
    // order-dependent.
    for (registry.patches, 0..) |a, i| {
        for (registry.patches[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.source_sha256, b.source_sha256));
        }
    }
}

test "find matches case-insensitively and misses cleanly" {
    const e = registry.patches[0];
    var upper: [64]u8 = undefined;
    for (e.source_sha256, 0..) |c, i| upper[i] = std.ascii.toUpper(c);
    try std.testing.expectEqual(@as(?*const Entry, &registry.patches[0]), find(&upper));
    const nope = "0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expectEqual(@as(?*const Entry, null), find(nope));
}

test "sha256Hex matches a known vector" {
    // sha256("abc")
    const want = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    try std.testing.expectEqualStrings(want, &sha256Hex("abc"));
}
