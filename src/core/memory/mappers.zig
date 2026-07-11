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

fn romSpeed(bank: u8, fastrom: bool) u8 {
    return if (bank >= 0x80 and fastrom) timing.speed_fast else timing.speed_slow;
}

pub fn buildPages(bus: *Bus) void {
    for (&bus.pages) |*p| p.* = .unmapped;

    switch (bus.cart.header.mapping) {
        .lorom => if (bus.cart.chip == .sa1) mapSa1(bus) else mapLoRom(bus),
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
        bus.pages[pageIndex(0x7E, @intCast(i))] = .{
            .read = wram + i * page_size,
            .write = wram + i * page_size,
            .speed = timing.speed_slow,
        };
    }

    var bank: u32 = 0;
    while (bank < 0x100) : (bank += 1) {
        const b: u8 = @intCast(bank);
        if (!bus_mod.isSystemBank(b) or b == 0x7E or b == 0x7F) continue;
        // $0000-$1FFF: mirror of first 8 KiB of WRAM.
        bus.pages[pageIndex(b, 0)] = .{ .read = wram, .write = wram, .speed = timing.speed_slow };
        // $2000-$5FFF: MMIO — always slow path.
        bus.pages[pageIndex(b, 1)] = .unmapped;
        bus.pages[pageIndex(b, 2)] = .unmapped;
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
            bus.pages[pageIndex(b, @intCast(i))] = .{
                .read = cart.rom.ptr + offset,
                .write = null,
                .speed = romSpeed(b, bus.fastrom),
            };
        }

        // DSP-1 boards on carts up to 1 MiB decode the coprocessor's DR/SR
        // ports in banks $30-$3F/$B0-$BF instead of the ROM mirror; unmap so
        // accesses fall to the slow path (bus.dsp1Port). Larger boards put
        // the ports at $60-$6F/$0000-$7FFF, which is already unmapped.
        if (cart.chip == .dsp and cart.rom.len <= 0x10_0000 and
            (bank & 0x7F) >= 0x30 and (bank & 0x7F) <= 0x3F)
        {
            for (4..8) |i| bus.pages[pageIndex(b, @intCast(i))] = .unmapped;
        }

        // Banks $70-$7D / $F0-$FF, $0000-$7FFF: SRAM. Super FX carts map
        // their shared work RAM differently (below).
        if (cart.chip != .superfx and
            (bank & 0x7F) >= 0x70 and cart.hasSram() and cart.sram_mask >= page_size - 1)
        {
            for (0..4) |i| {
                const offset = ((bank & 0x0F) * 0x8000 + @as(u32, @intCast(i)) * page_size) & cart.sram_mask;
                bus.pages[pageIndex(b, @intCast(i))] = .{
                    .read = @as([*]u8, &cart.sram) + offset,
                    .write = @as([*]u8, &cart.sram) + offset,
                    .speed = timing.speed_slow,
                };
            }
        }
    }
    if (cart.chip == .superfx) mapGsuRam(bus);
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
                bus.pages[pageIndex(b, @intCast(i))] = .{
                    .read = ram + offset,
                    .write = ram + offset,
                    .speed = timing.speed_slow,
                };
            }
        }
        if (bus_mod.isSystemBank(b)) {
            bus.pages[pageIndex(b, 3)] = .{
                .read = ram,
                .write = ram,
                .speed = timing.speed_slow,
            };
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
                bus.pages[pageIndex(b, @intCast(i))] = .{
                    .read = cart.rom.ptr + offset,
                    .write = null,
                    .speed = romSpeed(b, bus.fastrom),
                };
            }
            // Vector page: slow path for SNV/SIV substitution.
            if (b & 0x7F == 0) bus.pages[pageIndex(b, 7)] = .unmapped;
        } else if (b >= 0xC0) {
            // $C0-$FF: full banks through the MMC's block registers.
            for (0..8) |i| {
                const addr: u24 = @intCast(bank << 16 | i * page_size);
                const offset = sa1.mmcTranslate(@intCast(addr & 0x3F_FFFF), false);
                bus.pages[pageIndex(b, @intCast(i))] = .{
                    .read = cart.rom.ptr + offset,
                    .write = null,
                    .speed = romSpeed(b, bus.fastrom),
                };
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
            bus.pages[pageIndex(b, @intCast(i))] = .{
                .read = cart.rom.ptr + offset,
                .write = null,
                .speed = romSpeed(b, bus.fastrom),
            };
        }

        // Banks $20-$3F / $A0-$BF, $6000-$7FFF: SRAM window (8 KiB chunks).
        if (system and (bank & 0x3F) >= 0x20 and cart.hasSram() and cart.sram_mask >= page_size - 1) {
            const offset = ((bank & 0x1F) * page_size) & cart.sram_mask;
            bus.pages[pageIndex(b, 3)] = .{
                .read = @as([*]u8, &cart.sram) + offset,
                .write = @as([*]u8, &cart.sram) + offset,
                .speed = timing.speed_slow,
            };
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
            if ((bank & 0x7F) >= 0x70 and (bank & 0x7F) <= 0x7D and a16 < 0x8000) {
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
