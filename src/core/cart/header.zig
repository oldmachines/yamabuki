//! SNES internal ROM header detection.
//!
//! The 32-byte header sits at the end of the first ROM bank, so its file
//! offset reveals the mapping: $7FC0 → LoROM, $FFC0 → HiROM, $40FFC0 →
//! ExHiROM. Detection scores every candidate location and picks the best,
//! since plenty of commercial ROMs have wrong checksums or garbage fields.

const std = @import("std");

pub const Mapping = enum(u8) { lorom, hirom, exhirom };

pub const Header = struct {
    mapping: Mapping,
    /// Offset of the $xxC0 header block within the (de-headered) ROM image.
    offset: u32,
    title: [21]u8,
    /// $FFD5 raw map mode byte (speed bit 4: FastROM).
    map_mode: u8,
    /// $FFD6 cartridge type (coprocessor configuration).
    chipset: u8,
    rom_size_log2kb: u8,
    sram_size_log2kb: u8,
    region: u8,
    checksum: u16,
    checksum_complement: u16,
    /// Emulation-mode reset vector ($FFFC).
    reset_vector: u16,

    pub fn fastRom(self: *const Header) bool {
        return (self.map_mode & 0x10) != 0;
    }

    pub fn sramBytes(self: *const Header) u32 {
        if (self.sram_size_log2kb == 0) return 0;
        return @as(u32, 1024) << @intCast(@min(self.sram_size_log2kb, 12));
    }
};

const candidates = [_]struct { offset: u32, mapping: Mapping }{
    .{ .offset = 0x7FC0, .mapping = .lorom },
    .{ .offset = 0xFFC0, .mapping = .hirom },
    .{ .offset = 0x40FFC0, .mapping = .exhirom },
};

/// Size of a copier (SMC) header some ROM dumps carry in front of the image.
pub const copier_header_size = 512;

/// Strip a 512-byte copier header if present (file size ≡ 512 mod 1024).
pub fn stripCopierHeader(image: []const u8) []const u8 {
    if (image.len >= copier_header_size and image.len % 1024 == copier_header_size)
        return image[copier_header_size..];
    return image;
}

fn parseAt(rom: []const u8, offset: u32, mapping: Mapping) Header {
    const h = rom[offset..][0..64];
    var header: Header = .{
        .mapping = mapping,
        .offset = offset,
        .title = h[0..21].*,
        .map_mode = h[0x15],
        .chipset = h[0x16],
        .rom_size_log2kb = h[0x17],
        .sram_size_log2kb = h[0x18],
        .region = h[0x19],
        .checksum_complement = std.mem.readInt(u16, h[0x1C..0x1E], .little),
        .checksum = std.mem.readInt(u16, h[0x1E..0x20], .little),
        .reset_vector = std.mem.readInt(u16, h[0x3C..0x3E], .little),
    };
    _ = &header;
    return header;
}

fn score(rom: []const u8, offset: u32, mapping: Mapping) i32 {
    if (rom.len < @as(usize, offset) + 64) return std.math.minInt(i32);
    const h = parseAt(rom, offset, mapping);
    var s: i32 = 0;

    if (h.checksum ^ h.checksum_complement == 0xFFFF) s += 4;

    // Map mode low nibble should match the header's location.
    const expected_mode: u8 = switch (mapping) {
        .lorom => 0x0,
        .hirom => 0x1,
        .exhirom => 0x5,
    };
    if ((h.map_mode & 0xEF) == 0x20 | expected_mode) s += 3;

    // Reset vector must point into the upper half of bank $00 (ROM area).
    if (h.reset_vector >= 0x8000) s += 2 else s -= 4;

    // Title should be printable JIS X 0201/ASCII (space-padded).
    var printable = true;
    for (h.title) |c| {
        if (c != 0 and (c < 0x20 or c > 0xDF)) printable = false;
    }
    if (printable) s += 2;

    // Declared ROM size should be plausible (32 KiB .. 8 MiB).
    if (h.rom_size_log2kb >= 5 and h.rom_size_log2kb <= 13) s += 1;

    return s;
}

pub const Error = error{NoHeader};

/// Detect the internal header of a de-headered ROM image.
pub fn detect(rom: []const u8) Error!Header {
    var best: ?Header = null;
    var best_score: i32 = 0; // require a minimally plausible candidate
    for (candidates) |c| {
        const s = score(rom, c.offset, c.mapping);
        if (s > best_score) {
            best_score = s;
            best = parseAt(rom, c.offset, c.mapping);
        }
    }
    return best orelse error.NoHeader;
}

// --- tests ---------------------------------------------------------------

fn makeTestRom(allocator: std.mem.Allocator, size: usize, header_off: u32, map_mode: u8) ![]u8 {
    const rom = try allocator.alloc(u8, size);
    @memset(rom, 0);
    const h = rom[header_off..][0..64];
    @memcpy(h[0..21], "YAMABUKI TEST        ");
    h[0x15] = map_mode;
    h[0x17] = 8; // 256 KiB
    h[0x18] = 3; // 8 KiB SRAM
    std.mem.writeInt(u16, h[0x1C..0x1E], 0x5AA5, .little);
    std.mem.writeInt(u16, h[0x1E..0x20], 0xA55A, .little);
    std.mem.writeInt(u16, h[0x3C..0x3E], 0x8000, .little);
    return rom;
}

test "detect lorom" {
    const rom = try makeTestRom(std.testing.allocator, 256 * 1024, 0x7FC0, 0x20);
    defer std.testing.allocator.free(rom);
    const h = try detect(rom);
    try std.testing.expectEqual(Mapping.lorom, h.mapping);
    try std.testing.expect(!h.fastRom());
    try std.testing.expectEqual(@as(u32, 8192), h.sramBytes());
}

test "detect fastrom hirom" {
    const rom = try makeTestRom(std.testing.allocator, 1024 * 1024, 0xFFC0, 0x31);
    defer std.testing.allocator.free(rom);
    const h = try detect(rom);
    try std.testing.expectEqual(Mapping.hirom, h.mapping);
    try std.testing.expect(h.fastRom());
}

test "copier header stripped" {
    const raw = try std.testing.allocator.alloc(u8, 512 + 64 * 1024);
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqual(@as(usize, 64 * 1024), stripCopierHeader(raw).len);
    const exact = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(exact);
    try std.testing.expectEqual(@as(usize, 64 * 1024), stripCopierHeader(exact).len);
}

test "garbage rom rejected" {
    var junk: [0x12000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(42);
    prng.random().bytes(&junk);
    // Zero the vector areas so no candidate gets lucky with >= 0x8000.
    junk[0x7FFC] = 0;
    junk[0x7FFD] = 0;
    junk[0xFFFC] = 0;
    junk[0xFFFD] = 0;
    try std.testing.expectError(error.NoHeader, detect(&junk));
}
