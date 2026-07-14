//! Cartridge: ROM image, save RAM, and the enhancement-chip identity that
//! mappers and (later) chip emulation dispatch on.

const std = @import("std");
const header_mod = @import("header.zig");

pub const Header = header_mod.Header;
pub const Mapping = header_mod.Mapping;

/// Enhancement chip present in the cartridge. Identified at load time from
/// the header; each gets its own mapper hooks and emulation in milestone M9.
pub const ChipKind = enum(u8) {
    none,
    dsp, // DSP-1..4
    sa1,
    superfx,
    cx4,
    other, // recognized as present but not yet identified/supported
};

pub const max_sram = 0x2_0000; // 128 KiB covers all base-console carts

pub const Error = error{ NoHeader, RomTooSmall, OutOfMemory };

pub const Cartridge = struct {
    // Derived/immutable data is rebuilt or re-supplied at load; only SRAM is
    // console state worth saving.
    pub const serialize_skip = .{ "rom", "rom_mask", "header", "chip", "sram_mask" };

    /// Power-of-two padded ROM image, owned by the loading allocator.
    rom: []const u8,
    rom_mask: u32,
    sram: [max_sram]u8,
    /// sram_size - 1, or 0 when the cart has no SRAM.
    sram_mask: u32,
    header: Header,
    chip: ChipKind,

    /// Parse and load a raw ROM file image. The copier header is stripped
    /// and the ROM padded to a power of two (cyclic mirror) so mappers can
    /// mask addresses instead of bounds-checking.
    pub fn load(allocator: std.mem.Allocator, raw_image: []const u8) Error!Cartridge {
        const image = header_mod.stripCopierHeader(raw_image);
        if (image.len < 0x8000) return error.RomTooSmall;
        const header = try header_mod.detect(image);

        const padded_len = std.math.ceilPowerOfTwoAssert(usize, image.len);
        const rom = try allocator.alloc(u8, padded_len);
        // Cyclic mirror by doubling: each pass copies the (whole multiple of
        // the image already laid down) forward, so the result is identical to
        // `rom[i] = image[i % image.len]` in a handful of block copies instead
        // of a division per byte over up to 8 MiB.
        @memcpy(rom[0..image.len], image);
        var filled = image.len;
        while (filled < padded_len) {
            const n = @min(filled, padded_len - filled);
            @memcpy(rom[filled..][0..n], rom[0..n]);
            filled += n;
        }

        var cart: Cartridge = .{
            .rom = rom,
            .rom_mask = @intCast(padded_len - 1),
            .sram = @splat(0),
            .sram_mask = 0,
            .header = header,
            .chip = identifyChip(header),
        };
        var sram_bytes: u32 = @min(header.sramBytes(), max_sram);
        if (cart.chip == .superfx) {
            // Super FX carts declare their shared work RAM in the extended
            // header's expansion-RAM byte ($xxBD, log2 KiB); it lives in the
            // sram array (banks $70-$71) and is serialized with it.
            const exp = image[header.offset - 3];
            sram_bytes = if (exp >= 1 and exp <= 7) @as(u32, 1024) << @as(u5, @intCast(exp)) else 0x1_0000;
        }
        if (sram_bytes > 0) cart.sram_mask = sram_bytes - 1;
        return cart;
    }

    pub fn deinit(self: *Cartridge, allocator: std.mem.Allocator) void {
        allocator.free(self.rom);
        self.* = undefined;
    }

    pub fn hasSram(self: *const Cartridge) bool {
        return self.sram_mask != 0;
    }
};

fn identifyChip(h: Header) ChipKind {
    // $FFD6 chipset byte: high nibble selects the coprocessor family for
    // values >= 0x03 (in combination with the map mode for some).
    return switch (h.chipset) {
        0x00, 0x01, 0x02 => .none,
        0x03, 0x04, 0x05 => .dsp,
        0x13...0x1A => .superfx,
        0x33...0x35 => .sa1,
        0xF3 => .cx4,
        else => .other,
    };
}

test "load pads rom and sizes sram" {
    const alloc = std.testing.allocator;
    // 384 KiB (non-power-of-two, like several real carts)
    const raw = try alloc.alloc(u8, 384 * 1024);
    defer alloc.free(raw);
    @memset(raw, 0x11);
    const h = raw[0x7FC0..][0..64];
    @memcpy(h[0..21], "PADDING TEST         ");
    h[0x15] = 0x20;
    h[0x16] = 0x02; // ROM+RAM+battery, no coprocessor
    h[0x17] = 9;
    h[0x18] = 5; // 32 KiB SRAM
    std.mem.writeInt(u16, h[0x1C..0x1E], 0x0F0F, .little);
    std.mem.writeInt(u16, h[0x1E..0x20], 0xF0F0, .little);
    std.mem.writeInt(u16, h[0x3C..0x3E], 0x8000, .little);

    var cart = try Cartridge.load(alloc, raw);
    defer cart.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 512 * 1024), cart.rom.len);
    try std.testing.expectEqual(@as(u32, 512 * 1024 - 1), cart.rom_mask);
    try std.testing.expectEqual(@as(u32, 32 * 1024 - 1), cart.sram_mask);
    try std.testing.expectEqual(ChipKind.none, cart.chip);
    // cyclic padding mirrors the image
    try std.testing.expectEqual(raw[0], cart.rom[384 * 1024]);
}
