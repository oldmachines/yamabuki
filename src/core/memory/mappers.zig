//! Cartridge mappers: pure page-table builders. Run once at load and again
//! on MEMSEL (FastROM) changes — never on the hot path.

const std = @import("std");
const bus_mod = @import("bus.zig");
const Bus = bus_mod.Bus;
const Page = bus_mod.Page;
const Sa1 = @import("../chips/sa1.zig").Sa1;
const timing = @import("../timing.zig");

const page_size = bus_mod.page_size;
const pages_per_bank = 0x1_0000 / page_size; // 8

fn pageIndex(bank: u8, page_in_bank: u32) u32 {
    return @as(u32, bank) * pages_per_bank + page_in_bank;
}

/// Write one page's fields into the bus's parallel arrays. Builders stay
/// written in terms of the bundled `Page` view; only the storage is split.
fn setPage(bus: *Bus, idx: u32, p: Page) void {
    bus.page_read[idx] = p.read;
    bus.page_write[idx] = p.write;
    bus.page_speed[idx] = p.speed;
}

fn romSpeed(bank: u8, fastrom: bool) u8 {
    return if (bank >= 0x80 and fastrom) timing.speed_fast else timing.speed_slow;
}

pub fn buildPages(bus: *Bus) void {
    @memset(&bus.page_read, null);
    @memset(&bus.page_write, null);
    @memset(&bus.page_speed, timing.speed_slow);

    switch (bus.cart.header.mapping) {
        .lorom => switch (bus.cart.chip) {
            .sa1 => mapSa1(bus),
            .sdd1 => mapSdd1(bus),
            else => mapLoRom(bus),
        },
        .hirom => mapHiRom(bus, 0),
        .exhirom => mapHiRom(bus, 0x40_0000),
    }
    mapSystem(bus);
}

/// WRAM banks $7E-$7F plus the low-bank WRAM mirror and MMIO holes in the
/// system area. Runs last so it overrides whatever the ROM mapper placed.
fn mapSystem(bus: *Bus) void {
    const wram: [*]u8 = &bus.wram.data;

    // Banks $7E-$7F: all 128 KiB, linear.
    for (0..16) |i| {
        setPage(bus, pageIndex(0x7E, @intCast(i)), .{
            .read = wram + i * page_size,
            .write = wram + i * page_size,
            .speed = timing.speed_slow,
        });
    }

    var bank: u32 = 0;
    while (bank < 0x100) : (bank += 1) {
        const b: u8 = @intCast(bank);
        if (!bus_mod.isSystemBank(b) or b == 0x7E or b == 0x7F) continue;
        // $0000-$1FFF: mirror of first 8 KiB of WRAM.
        setPage(bus, pageIndex(b, 0), .{ .read = wram, .write = wram, .speed = timing.speed_slow });
        // $2000-$5FFF: MMIO — always slow path.
        setPage(bus, pageIndex(b, 1), .unmapped);
        setPage(bus, pageIndex(b, 2), .unmapped);
    }
}

fn mapLoRom(bus: *Bus) void {
    const cart = bus.cart;
    var bank: u32 = 0;
    while (bank < 0x100) : (bank += 1) {
        const b: u8 = @intCast(bank);
        if (b == 0x7E or b == 0x7F) continue;

        // $8000-$FFFF: 32 KiB ROM window.
        for (4..8) |i| {
            const offset = ((bank & 0x7F) * 0x8000 + (@as(u32, @intCast(i)) - 4) * page_size) & cart.rom_mask;
            setPage(bus, pageIndex(b, @intCast(i)), .{
                .read = cart.rom.ptr + offset,
                .write = null,
                .speed = romSpeed(b, bus.fastrom),
            });
        }

        // DSP-1 boards on carts up to 1 MiB decode the coprocessor's DR/SR
        // ports in banks $30-$3F/$B0-$BF instead of the ROM mirror; unmap so
        // accesses fall to the slow path (bus.dsp1Port). Larger boards put
        // the ports at $60-$6F/$0000-$7FFF, which is already unmapped.
        if (cart.chip == .dsp and cart.rom.len <= 0x10_0000 and
            (bank & 0x7F) >= 0x30 and (bank & 0x7F) <= 0x3F)
        {
            for (4..8) |i| setPage(bus, pageIndex(b, @intCast(i)), .unmapped);
        }

        // Banks $70-$7D / $F0-$FF, $0000-$7FFF: SRAM. Super FX carts map
        // their shared work RAM differently (below).
        if (cart.chip != .superfx and
            (bank & 0x7F) >= 0x70 and cart.hasSram() and cart.sram_mask >= page_size - 1)
        {
            for (0..4) |i| {
                const offset = ((bank & 0x0F) * 0x8000 + @as(u32, @intCast(i)) * page_size) & cart.sram_mask;
                setPage(bus, pageIndex(b, @intCast(i)), .{
                    .read = @as([*]u8, &cart.sram) + offset,
                    .write = @as([*]u8, &cart.sram) + offset,
                    .speed = timing.speed_slow,
                });
            }
        }
    }
    if (cart.chip == .superfx) {
        mapGsuLinearRom(bus);
        mapGsuRam(bus);
    }
}

/// Super FX boards decode banks $40-$5F (and $C0-$DF) as linear ROM: bank
/// $40+n covers ROM offset n*64K across the whole bank, $0000-$FFFF. The
/// LoROM windows the generic loop just installed for those banks are both
/// incomplete (no lower half) and wrongly offset (the board is linear here,
/// not mirrored-LoROM) — Yoshi's Island uploads its sound driver from
/// $50:0342 and hung forever on open bus without this.
fn mapGsuLinearRom(bus: *Bus) void {
    const cart = bus.cart;
    var bank: u32 = 0x40;
    while (bank <= 0x5F) : (bank += 1) {
        for ([2]u32{ bank, bank + 0x80 }) |b32| {
            const b: u8 = @intCast(b32);
            for (0..8) |i| {
                const offset = ((bank - 0x40) * 0x1_0000 + @as(u32, @intCast(i)) * page_size) & cart.rom_mask;
                setPage(bus, pageIndex(b, @intCast(i)), .{
                    .read = cart.rom.ptr + offset,
                    .write = null,
                    .speed = romSpeed(b, bus.fastrom),
                });
            }
        }
    }
}

/// Super FX work RAM (in cart.sram): banks $70-$71 (and $F0-$F1) map the
/// full 64 KiB each, and $6000-$7FFF of every system bank mirrors the first
/// 8 KiB. Reads and writes go straight to the array — the fast core does not
/// model the RON/RAN bus arbitration (the GSU is caught up before any of its
/// MMIO is touched, which is how well-behaved software orders its accesses).
fn mapGsuRam(bus: *Bus) void {
    const cart = bus.cart;
    if (!cart.hasSram()) return;
    const ram: [*]u8 = &cart.sram;

    var bank: u32 = 0;
    while (bank < 0x100) : (bank += 1) {
        const b: u8 = @intCast(bank);
        if ((bank & 0x7F) == 0x70 or (bank & 0x7F) == 0x71) {
            for (0..8) |i| {
                const offset = ((bank & 1) * 0x1_0000 + @as(u32, @intCast(i)) * page_size) & cart.sram_mask;
                setPage(bus, pageIndex(b, @intCast(i)), .{
                    .read = ram + offset,
                    .write = ram + offset,
                    .speed = timing.speed_slow,
                });
            }
        }
        if (bus_mod.isSystemBank(b)) {
            setPage(bus, pageIndex(b, 3), .{
                .read = ram,
                .write = ram,
                .speed = timing.speed_slow,
            });
        }
    }
}

/// S-DD1 carts: a LoROM base plus the chip's own 4 MiB window over banks
/// $C0-$FF, which is where these games actually live (Star Ocean's reset code
/// ends in `JML $C0:8001`). The window is four 1 MiB slices, each selected by
/// one of $4804-$4807, so a register write re-runs `mapSdd1Window` alone.
fn mapSdd1(bus: *Bus) void {
    mapLoRom(bus);
    mapSdd1Window(bus);
}

/// Rebuild banks $C0-$FF from the chip's current slice selection. Cheap
/// enough (512 pages) to run on every $4804-$4807 write.
pub fn mapSdd1Window(bus: *Bus) void {
    const cart = bus.cart;
    var bank: u32 = 0xC0;
    while (bank < 0x100) : (bank += 1) {
        const b: u8 = @intCast(bank);
        for (0..pages_per_bank) |i| {
            const addr: u24 = @intCast((bank << 16) | (i * page_size));
            const offset = bus.sdd1.windowOffset(addr) & cart.rom_mask;
            setPage(bus, pageIndex(b, @intCast(i)), .{
                .read = cart.rom.ptr + offset,
                .write = null,
                .speed = romSpeed(b, bus.fastrom),
            });
        }
    }
}

/// SA-1 carts: ROM pages go through the Super MMC's four switchable regions
/// (rebuilt whenever an MMC register changes). Everything the SA-1 shares or
/// substitutes stays off the fast path: IRAM ($3000, inside the MMIO hole),
/// the BW-RAM window at $6000-$7FFF and banks $40-$4F (write protection and
/// the CC1 conversion hook), and the vector page of banks $00/$80 (so the
/// SA-1 can swap the SNES NMI/IRQ vectors to SNV/SIV).
fn mapSa1(bus: *Bus) void {
    const cart = bus.cart;
    const sa1 = &bus.sa1;
    var bank: u32 = 0;
    while (bank < 0x100) : (bank += 1) {
        const b: u8 = @intCast(bank);
        if (b == 0x7E or b == 0x7F) continue;

        if (bus_mod.isSystemBank(b)) {
            // $8000-$FFFF through the MMC's LoROM-view regions.
            for (4..8) |i| {
                const addr: u24 = @intCast(bank << 16 | i * page_size);
                const offset = sa1.mmcTranslate(Sa1.squashLo(addr), true);
                setPage(bus, pageIndex(b, @intCast(i)), .{
                    .read = cart.rom.ptr + offset,
                    .write = null,
                    .speed = romSpeed(b, bus.fastrom),
                });
            }
            // Vector page: slow path for SNV/SIV substitution.
            if (b & 0x7F == 0) setPage(bus, pageIndex(b, 7), .unmapped);
        } else if (b >= 0xC0) {
            // $C0-$FF: full banks through the MMC's block registers.
            for (0..8) |i| {
                const addr: u24 = @intCast(bank << 16 | i * page_size);
                const offset = sa1.mmcTranslate(@intCast(addr & 0x3F_FFFF), false);
                setPage(bus, pageIndex(b, @intCast(i)), .{
                    .read = cart.rom.ptr + offset,
                    .write = null,
                    .speed = romSpeed(b, bus.fastrom),
                });
            }
        }
        // Banks $40-$4F (BW-RAM) stay unmapped: slow path handles them.
    }
}

/// HiROM and ExHiROM share a shape; ExHiROM adds 4 MiB to the ROM offset of
/// banks with bit 7 clear (so $C0.. maps the first 4 MiB, $00.. the second).
fn mapHiRom(bus: *Bus, low_half_extra: u32) void {
    const cart = bus.cart;
    var bank: u32 = 0;
    while (bank < 0x100) : (bank += 1) {
        const b: u8 = @intCast(bank);
        if (b == 0x7E or b == 0x7F) continue;
        const extra = if (b < 0x80) low_half_extra else 0;
        const system = bus_mod.isSystemBank(b);
        const first_page: u32 = if (system) 4 else 0;

        for (first_page..8) |i| {
            const offset = (((bank & 0x3F) << 16) + @as(u32, @intCast(i)) * page_size + extra) & cart.rom_mask;
            setPage(bus, pageIndex(b, @intCast(i)), .{
                .read = cart.rom.ptr + offset,
                .write = null,
                .speed = romSpeed(b, bus.fastrom),
            });
        }

        // Banks $20-$3F / $A0-$BF, $6000-$7FFF: SRAM window (8 KiB chunks).
        if (system and (bank & 0x3F) >= 0x20 and cart.hasSram() and cart.sram_mask >= page_size - 1) {
            const offset = ((bank & 0x1F) * page_size) & cart.sram_mask;
            setPage(bus, pageIndex(b, 3), .{
                .read = @as([*]u8, &cart.sram) + offset,
                .write = @as([*]u8, &cart.sram) + offset,
                .speed = timing.speed_slow,
            });
        }
    }
}

/// SRAM smaller than one page (2-4 KiB carts) can't be direct-mapped without
/// losing mirroring, so those accesses fall to the slow path and land here.
pub fn smallSramPtr(bus: *Bus, addr: u24) ?*u8 {
    const cart = bus.cart;
    if (!cart.hasSram() or cart.sram_mask >= page_size - 1) return null;
    const bank: u8 = @intCast(addr >> 16);
    const a16: u16 = @truncate(addr);
    switch (cart.header.mapping) {
        .lorom => {
            // The same banks `mapLoRom` gives a page-table SRAM window:
            // $70-$7D and their $F0-$FF mirrors — every one of $F0-$FF,
            // because only $7E/$7F are WRAM; $FE/$FF are SRAM on the board.
            const sram_bank = (bank >= 0x70 and bank <= 0x7D) or bank >= 0xF0;
            if (sram_bank and a16 < 0x8000) {
                const offset = ((@as(u32, bank & 0x0F) << 15) | a16) & cart.sram_mask;
                return &cart.sram[offset];
            }
        },
        .hirom, .exhirom => {
            if (bus_mod.isSystemBank(bank) and (bank & 0x3F) >= 0x20 and a16 >= 0x6000 and a16 < 0x8000) {
                const offset = ((@as(u32, bank & 0x1F) << 13) | (a16 - 0x6000)) & cart.sram_mask;
                return &cart.sram[offset];
            }
        },
    }
    return null;
}

// --- tests ---------------------------------------------------------------

const Cartridge = @import("../cart/cartridge.zig").Cartridge;

/// A synthetic console: a 512 KiB image whose every byte is its own bank
/// offset's high byte, with a header at $7FC0 (LoROM) or $FFC0 (HiROM).
/// Mirrors bus.zig's private TestConsole.
const TestConsole = struct {
    cart: Cartridge,
    bus: Bus,

    fn create(mapping_mode: u8, sram_log2kb: u8) !*TestConsole {
        const alloc = std.testing.allocator;
        const raw = try alloc.alloc(u8, 512 * 1024);
        defer alloc.free(raw);
        for (raw, 0..) |*b, i| b.* = @truncate(i >> 8);
        const hoff: u32 = if (mapping_mode & 0x01 != 0) 0xFFC0 else 0x7FC0;
        const h = raw[hoff..][0..64];
        @memcpy(h[0..21], "MAPPER TEST          ");
        h[0x15] = mapping_mode;
        h[0x16] = 0x02; // ROM + RAM + battery, no coprocessor
        h[0x17] = 9;
        h[0x18] = sram_log2kb;
        std.mem.writeInt(u16, h[0x1C..0x1E], 0x0F0F, .little);
        std.mem.writeInt(u16, h[0x1E..0x20], 0xF0F0, .little);
        std.mem.writeInt(u16, h[0x3C..0x3E], 0x8000, .little);

        const tc = try alloc.create(TestConsole);
        errdefer alloc.destroy(tc);
        tc.cart = try Cartridge.load(alloc, raw);
        tc.bus.init(&tc.cart);
        return tc;
    }

    fn destroy(self: *TestConsole) void {
        self.cart.deinit(std.testing.allocator);
        std.testing.allocator.destroy(self);
    }
};

test "hirom sram window: 8 KiB chunks from bank $20 up, nothing below it" {
    var tc = try TestConsole.create(0x21, 5); // HiROM, 32 KiB SRAM
    defer tc.destroy();
    const sram_base = @intFromPtr(&tc.cart.sram);

    // Page 3 ($6000-$7FFF) of banks $20/$21 points at SRAM offsets 0 / $2000.
    try std.testing.expectEqual(sram_base, @intFromPtr(tc.bus.page_read[pageIndex(0x20, 3)].?));
    try std.testing.expectEqual(sram_base + 0x2000, @intFromPtr(tc.bus.page_read[pageIndex(0x21, 3)].?));
    // The $A0-$BF mirror sees the same chunks.
    try std.testing.expectEqual(sram_base, @intFromPtr(tc.bus.page_read[pageIndex(0xA0, 3)].?));
    // Bank $1F has no SRAM page; it is left to the slow path.
    try std.testing.expect(tc.bus.page_read[pageIndex(0x1F, 3)] == null);
    try std.testing.expect(tc.bus.page_write[pageIndex(0x1F, 3)] == null);

    // And through the bus: writes land at the expected SRAM offsets...
    tc.bus.write8(0x20_6000, 0x5A);
    tc.bus.write8(0x21_6000, 0xA5);
    try std.testing.expectEqual(@as(u8, 0x5A), tc.cart.sram[0]);
    try std.testing.expectEqual(@as(u8, 0xA5), tc.cart.sram[0x2000]);
    try std.testing.expectEqual(@as(u8, 0x5A), tc.bus.read8(0x20_6000));
    try std.testing.expectEqual(@as(u8, 0xA5), tc.bus.read8(0x21_6000));
    // ...while $1F:6000 reaches nothing (open bus, SRAM untouched).
    tc.bus.write8(0x1F_6000, 0x77);
    try std.testing.expectEqual(@as(u8, 0x5A), tc.cart.sram[0]);
    _ = tc.bus.read8(0x20_6000); // mdr = $5A
    try std.testing.expectEqual(@as(u8, 0x5A), tc.bus.read8(0x1F_6000));
}

test "smallSramPtr: a 2 KiB hirom sram mirrors through the whole $6000-$7FFF window" {
    var tc = try TestConsole.create(0x21, 1); // HiROM, 2 KiB SRAM
    defer tc.destroy();
    // Too small for a page-table entry, so the slow path asks smallSramPtr.
    try std.testing.expect(tc.bus.page_read[pageIndex(0x20, 3)] == null);

    tc.bus.write8(0x20_6000, 0x5A);
    try std.testing.expectEqual(@as(u8, 0x5A), tc.cart.sram[0]);
    try std.testing.expectEqual(@as(u8, 0x5A), tc.bus.read8(0x20_6800));
    try std.testing.expectEqual(@as(u8, 0x5A), tc.bus.read8(0x20_7000));
    try std.testing.expectEqual(@as(u8, 0x5A), tc.bus.read8(0x21_6000)); // next bank wraps too
    try std.testing.expectEqual(@as(u8, 0x5A), tc.bus.read8(0xA0_6000)); // upper mirror

    try std.testing.expectEqual(@as(?*u8, &tc.cart.sram[0]), smallSramPtr(&tc.bus, 0x20_6000));
    try std.testing.expectEqual(@as(?*u8, &tc.cart.sram[0x7FF]), smallSramPtr(&tc.bus, 0x20_67FF));
    try std.testing.expectEqual(@as(?*u8, &tc.cart.sram[0]), smallSramPtr(&tc.bus, 0x20_6800));
    // Outside the window: not SRAM.
    try std.testing.expect(smallSramPtr(&tc.bus, 0x1F_6000) == null);
    try std.testing.expect(smallSramPtr(&tc.bus, 0x20_5FFF) == null);
    try std.testing.expect(smallSramPtr(&tc.bus, 0x20_8000) == null);
}

test "romSpeed: FastROM only speeds up the upper banks" {
    try std.testing.expectEqual(timing.speed_slow, romSpeed(0x00, false));
    try std.testing.expectEqual(timing.speed_slow, romSpeed(0x40, true));
    try std.testing.expectEqual(timing.speed_slow, romSpeed(0x7F, true));
    try std.testing.expectEqual(timing.speed_fast, romSpeed(0x80, true));
    try std.testing.expectEqual(timing.speed_fast, romSpeed(0xC0, true));
    try std.testing.expectEqual(timing.speed_slow, romSpeed(0xC0, false));

    // The page table records the same verdict per page.
    var tc = try TestConsole.create(0x21, 0); // HiROM: banks $40/$C0 are full ROM
    defer tc.destroy();
    tc.bus.fastrom = true;
    buildPages(&tc.bus);
    try std.testing.expectEqual(timing.speed_slow, tc.bus.page_speed[pageIndex(0x40, 0)]);
    try std.testing.expectEqual(timing.speed_fast, tc.bus.page_speed[pageIndex(0xC0, 0)]);
    try std.testing.expectEqual(timing.speed_slow, tc.bus.page_speed[pageIndex(0x00, 4)]);
    try std.testing.expectEqual(timing.speed_fast, tc.bus.page_speed[pageIndex(0x80, 4)]);
    // Both pages read the same ROM byte; only the charge differs.
    try std.testing.expectEqual(tc.bus.read8(0x40_0000), tc.bus.read8(0xC0_0000));
}
