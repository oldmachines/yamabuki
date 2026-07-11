//! System bus: 24-bit address space dispatched through a 2048-entry page
//! table (8 KiB pages). ROM/RAM/SRAM accesses take the two-load fast path;
//! MMIO pages have null pointers and fall through to a single switch.
//!
//! The bus owns the master-cycle clock: every access charges the page's
//! speed (6/8/12 master cycles), so instruction timing falls out of memory
//! traffic for free.

const std = @import("std");
const mappers = @import("mappers.zig");
const Wram = @import("wram.zig").Wram;
const MathUnit = @import("math_unit.zig").MathUnit;
const CpuIo = @import("cpu_io.zig").CpuIo;
const Dma = @import("dma.zig").Dma;
const Ppu = @import("../ppu/ppu.zig").Ppu;
const Apu = @import("../apu/apu.zig").Apu;
const Cartridge = @import("../cart/cartridge.zig").Cartridge;
const timing = @import("../timing.zig");

pub const Page = struct {
    read: ?[*]const u8,
    write: ?[*]u8,
    /// Master cycles per access on this page.
    speed: u8,

    pub const unmapped: Page = .{ .read = null, .write = null, .speed = timing.speed_slow };
};

pub const page_size = 0x2000;
pub const page_count = 0x100_0000 / page_size; // 2048

pub const Bus = struct {
    // The page table holds raw pointers into wram/cart and is rebuilt by
    // remap() on load; the cart reference is re-supplied by the frontend.
    pub const serialize_skip = .{ "pages", "cart" };

    pages: [page_count]Page,
    cart: *Cartridge,
    /// Master clock in master cycles since power-on.
    clock: u64,
    /// Memory data register: the value of the last bus transfer (open bus).
    mdr: u8,
    /// $420D MEMSEL bit 0: FastROM enabled.
    fastrom: bool,
    wram: Wram,
    math: MathUnit,
    cpuio: CpuIo,
    ppu: Ppu,
    dma: Dma,
    apu: Apu,

    /// Initialize in place. `self` must be at its final address (the page
    /// table points into `self.wram`, and the APU's SPC700 points back at
    /// the APU), and `cart` must outlive the bus.
    pub fn init(self: *Bus, cart: *Cartridge) void {
        self.cart = cart;
        self.clock = 0;
        self.mdr = 0;
        self.fastrom = false;
        self.wram = .init;
        self.math = .init;
        self.cpuio = .init;
        self.ppu = .init;
        self.dma = .init;
        self.apu.init();
        self.remap();
    }

    /// Rebuild the page table (after init, deserialize, or MEMSEL change).
    pub fn remap(self: *Bus) void {
        mappers.buildPages(self);
    }

    /// Called after deserialization to rebuild derived state: the page table,
    /// then every component that declares its own postLoad hook (discovered
    /// at comptime, so new components can't be forgotten here).
    pub fn postLoad(self: *Bus) void {
        self.remap();
        inline for (@typeInfo(Bus).@"struct".fields) |f| {
            if (comptime @typeInfo(f.type) == .@"struct" and @hasDecl(f.type, "postLoad")) {
                @field(self, f.name).postLoad();
            }
        }
    }

    /// One CPU internal cycle (no bus access).
    pub inline fn idle(self: *Bus) void {
        self.clock += timing.speed_fast;
    }

    pub inline fn read8(self: *Bus, addr: u24) u8 {
        const page = &self.pages[addr >> 13];
        if (page.read) |p| {
            self.clock += page.speed;
            const v = p[addr & (page_size - 1)];
            self.mdr = v;
            return v;
        }
        return self.slowRead(addr);
    }

    pub inline fn write8(self: *Bus, addr: u24, value: u8) void {
        self.mdr = value;
        const page = &self.pages[addr >> 13];
        if (page.write) |p| {
            self.clock += page.speed;
            p[addr & (page_size - 1)] = value;
            return;
        }
        self.slowWrite(addr, value);
    }

    fn slowRead(self: *Bus, addr: u24) u8 {
        @branchHint(.unlikely);
        self.clock += speedOf(addr, self.fastrom);
        const bank: u8 = @intCast(addr >> 16);
        const a16: u16 = @truncate(addr);

        // MMIO exists only in the system area (banks $00-$3F / $80-$BF).
        if (!isSystemBank(bank)) {
            if (mappers.smallSramPtr(self, addr)) |p| {
                self.mdr = p.*;
                return self.mdr;
            }
            return self.mdr; // open bus
        }

        const v: u8 = switch (a16) {
            0x2134...0x213F => self.ppu.readReg(a16, self.mdr),
            0x2140...0x217F => self.apu.cpuRead(self.clock, @truncate(a16 & 3)),
            0x2180 => self.wram.portRead(),
            0x4210 => self.cpuio.readRdnmi(self.mdr),
            0x4211 => self.cpuio.readTimeup(self.mdr),
            0x4212 => self.cpuio.readHvbjoy(self.mdr),
            0x4214 => @truncate(self.math.rddiv),
            0x4215 => @truncate(self.math.rddiv >> 8),
            0x4216 => @truncate(self.math.rdmpy),
            0x4217 => @truncate(self.math.rdmpy >> 8),
            0x4300...0x437F => self.dma.readReg(a16),
            else => {
                if (mappers.smallSramPtr(self, addr)) |p| {
                    self.mdr = p.*;
                    return self.mdr;
                }
                return self.mdr; // open bus (includes write-only registers)
            },
        };
        self.mdr = v;
        return v;
    }

    fn slowWrite(self: *Bus, addr: u24, value: u8) void {
        @branchHint(.unlikely);
        self.clock += speedOf(addr, self.fastrom);
        const bank: u8 = @intCast(addr >> 16);
        const a16: u16 = @truncate(addr);

        if (!isSystemBank(bank)) {
            if (mappers.smallSramPtr(self, addr)) |p| p.* = value;
            return;
        }

        switch (a16) {
            0x2100...0x2133 => self.ppu.writeReg(a16, value),
            0x2140...0x217F => self.apu.cpuWrite(self.clock, @truncate(a16 & 3), value),
            0x2180 => self.wram.portWrite(value),
            0x2181 => self.wram.setPortAddrLow(value),
            0x2182 => self.wram.setPortAddrMid(value),
            0x2183 => self.wram.setPortAddrHigh(value),
            0x4200 => self.cpuio.nmitimen = value,
            0x4201 => self.cpuio.wrio = value,
            0x4202 => self.math.wrmpya = value,
            0x4203 => self.math.writeMultiplicand(value),
            0x4204 => self.math.dividend = (self.math.dividend & 0xFF00) | value,
            0x4205 => self.math.dividend = (self.math.dividend & 0x00FF) | (@as(u16, value) << 8),
            0x4206 => self.math.writeDivisor(value),
            0x4207 => self.cpuio.setHtimeLow(value),
            0x4208 => self.cpuio.setHtimeHigh(value),
            0x4209 => self.cpuio.setVtimeLow(value),
            0x420A => self.cpuio.setVtimeHigh(value),
            0x420B => self.dma.startGpDma(self, value),
            0x420C => self.dma.hdmaen = value,
            0x4300...0x437F => self.dma.writeReg(a16, value),
            0x420D => {
                const enable = (value & 1) != 0;
                if (enable != self.fastrom) {
                    self.fastrom = enable;
                    self.remap();
                }
            },
            else => {
                if (mappers.smallSramPtr(self, addr)) |p| p.* = value;
            },
        }
    }
};

pub fn isSystemBank(bank: u8) bool {
    return (bank & 0x7F) <= 0x3F;
}

/// Master cycles for one access at `addr` (anomie's memory-speed map).
pub fn speedOf(addr: u24, fastrom: bool) u8 {
    const bank: u8 = @intCast(addr >> 16);
    const a16: u16 = @truncate(addr);
    if (bank >= 0xC0) return if (fastrom) timing.speed_fast else timing.speed_slow;
    if (bank >= 0x80) return systemAreaSpeed(a16, fastrom);
    if (bank >= 0x40) return timing.speed_slow;
    return systemAreaSpeed(a16, false);
}

fn systemAreaSpeed(a16: u16, fastrom_upper: bool) u8 {
    return switch (a16) {
        0x0000...0x1FFF => timing.speed_slow,
        0x2000...0x3FFF => timing.speed_fast,
        0x4000...0x41FF => timing.speed_xslow,
        0x4200...0x5FFF => timing.speed_fast,
        0x6000...0x7FFF => timing.speed_slow,
        else => if (fastrom_upper) timing.speed_fast else timing.speed_slow,
    };
}

test {
    std.testing.refAllDecls(@This());
}

// --- tests ---------------------------------------------------------------

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
        @memcpy(h[0..21], "BUS TEST             ");
        h[0x15] = mapping_mode;
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

test "lorom rom mapping and mirroring" {
    var tc = try TestConsole.create(0x20, 3);
    defer tc.destroy();
    // $00:8000 is ROM offset 0
    try std.testing.expectEqual(tc.cart.rom[0], tc.bus.read8(0x00_8000));
    // $01:8000 is ROM offset $8000
    try std.testing.expectEqual(tc.cart.rom[0x8000], tc.bus.read8(0x01_8000));
    // $80:8000 mirrors $00:8000
    try std.testing.expectEqual(tc.cart.rom[0], tc.bus.read8(0x80_8000));
    // ROM is read-only: write is ignored
    tc.bus.write8(0x00_8000, 0xEE);
    try std.testing.expectEqual(tc.cart.rom[0], tc.bus.read8(0x00_8000));
}

test "hirom rom mapping" {
    var tc = try TestConsole.create(0x21, 0);
    defer tc.destroy();
    // $C0:0000 is ROM offset 0
    try std.testing.expectEqual(tc.cart.rom[0], tc.bus.read8(0xC0_0000));
    // $C1:2345 is ROM offset $12345
    try std.testing.expectEqual(tc.cart.rom[0x1_2345], tc.bus.read8(0xC1_2345));
    // system bank upper half: $00:8000 == ROM offset $8000
    try std.testing.expectEqual(tc.cart.rom[0x8000], tc.bus.read8(0x00_8000));
    // $40:0000 mirrors $C0:0000
    try std.testing.expectEqual(tc.cart.rom[0], tc.bus.read8(0x40_0000));
}

test "wram mapping, mirror, and port" {
    var tc = try TestConsole.create(0x20, 3);
    defer tc.destroy();
    tc.bus.write8(0x7E_1234, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), tc.bus.read8(0x7E_1234));
    // low-bank mirror of the first 8 KiB
    tc.bus.write8(0x00_0042, 0x55);
    try std.testing.expectEqual(@as(u8, 0x55), tc.bus.read8(0x7E_0042));
    try std.testing.expectEqual(@as(u8, 0x55), tc.bus.read8(0xBF_0042));
    // WRAM port with autoincrement
    tc.bus.write8(0x00_2181, 0x00);
    tc.bus.write8(0x00_2182, 0x40);
    tc.bus.write8(0x00_2183, 0x01);
    tc.bus.write8(0x00_2180, 0x77); // writes $7F:4000
    try std.testing.expectEqual(@as(u8, 0x77), tc.bus.read8(0x7F_4000));
}

test "open bus returns last mdr" {
    var tc = try TestConsole.create(0x20, 3);
    defer tc.destroy();
    _ = tc.bus.read8(0x00_8000); // mdr = rom[0] = 0x00... use a distinctive one
    _ = tc.bus.read8(0x00_8123); // mdr = rom[0x123] = 0x01
    const mdr = tc.cart.rom[0x123];
    // $00:5000 is unmapped in LoROM
    try std.testing.expectEqual(mdr, tc.bus.read8(0x00_5000));
    // reading write-only register $4202 is also open bus
    try std.testing.expectEqual(mdr, tc.bus.read8(0x00_4202));
}

test "clock charges page speeds and fastrom" {
    var tc = try TestConsole.create(0x20, 3);
    defer tc.destroy();
    var before = tc.bus.clock;
    _ = tc.bus.read8(0x00_8000); // SlowROM: 8
    try std.testing.expectEqual(@as(u64, 8), tc.bus.clock - before);

    before = tc.bus.clock;
    _ = tc.bus.read8(0x00_4210); // MMIO $4200-$5FFF: 6
    try std.testing.expectEqual(@as(u64, 6), tc.bus.clock - before);

    before = tc.bus.clock;
    _ = tc.bus.read8(0x00_4016); // joypad: 12
    try std.testing.expectEqual(@as(u64, 12), tc.bus.clock - before);

    tc.bus.write8(0x00_420D, 1); // enable FastROM
    before = tc.bus.clock;
    _ = tc.bus.read8(0x80_8000); // upper-half ROM now fast: 6
    try std.testing.expectEqual(@as(u64, 6), tc.bus.clock - before);
    before = tc.bus.clock;
    _ = tc.bus.read8(0x00_8000); // lower half stays slow: 8
    try std.testing.expectEqual(@as(u64, 8), tc.bus.clock - before);
}

test "lorom sram direct-mapped rw" {
    var tc = try TestConsole.create(0x20, 5); // 32 KiB SRAM
    defer tc.destroy();
    tc.bus.write8(0x70_0000, 0x5A);
    tc.bus.write8(0x70_7FFF, 0xA5);
    try std.testing.expectEqual(@as(u8, 0x5A), tc.bus.read8(0x70_0000));
    try std.testing.expectEqual(@as(u8, 0xA5), tc.bus.read8(0x70_7FFF));
    try std.testing.expectEqual(@as(u8, 0x5A), tc.cart.sram[0]);
}

test "small sram mirrors through slow path" {
    var tc = try TestConsole.create(0x20, 1); // 2 KiB SRAM
    defer tc.destroy();
    tc.bus.write8(0x70_0000, 0x42);
    // 2 KiB SRAM mirrors every $800 in the window
    try std.testing.expectEqual(@as(u8, 0x42), tc.bus.read8(0x70_0800));
    try std.testing.expectEqual(@as(u8, 0x42), tc.bus.read8(0x70_1000));
}

test "math unit via bus" {
    var tc = try TestConsole.create(0x20, 3);
    defer tc.destroy();
    tc.bus.write8(0x00_4202, 12);
    tc.bus.write8(0x00_4203, 34);
    const lo = tc.bus.read8(0x00_4216);
    const hi = tc.bus.read8(0x00_4217);
    try std.testing.expectEqual(@as(u16, 12 * 34), @as(u16, lo) | (@as(u16, hi) << 8));

    tc.bus.write8(0x00_4204, 0xE8); // 1000
    tc.bus.write8(0x00_4205, 0x03);
    tc.bus.write8(0x00_4206, 10);
    const qlo = tc.bus.read8(0x00_4214);
    const qhi = tc.bus.read8(0x00_4215);
    try std.testing.expectEqual(@as(u16, 100), @as(u16, qlo) | (@as(u16, qhi) << 8));
}

test "dma a-bus cannot touch dma registers or retrigger itself" {
    var tc = try TestConsole.create(0x20, 3);
    defer tc.destroy();
    // Channel 0: B->A ($21FF open bus -> fixed A-bus address), 4 bytes,
    // with the A side aimed at $420B — the GDMA trigger itself. The A-bus
    // block must drop those writes or the transfer recurses without bound.
    tc.bus.write8(0x00_4300, 0x88); // DMAP: B->A, fixed A-bus
    tc.bus.write8(0x00_4301, 0xFF); // BBAD: $21FF
    tc.bus.write8(0x00_4302, 0x0B); // A1T = $420B
    tc.bus.write8(0x00_4303, 0x42);
    tc.bus.write8(0x00_4305, 4); // DAS = 4
    tc.bus.write8(0x00_420B, 0x01); // must terminate, not recurse
    try std.testing.expectEqual(@as(u16, 0), tc.bus.dma.channels[0].count);

    // Same, aimed at the channel's own DMAP register: the blocked write
    // must leave the live control byte untouched.
    tc.bus.write8(0x00_4302, 0x00); // A1T = $4300
    tc.bus.write8(0x00_4303, 0x43);
    tc.bus.write8(0x00_4305, 4);
    tc.bus.write8(0x00_420B, 0x01);
    try std.testing.expectEqual(@as(u8, 0x88), tc.bus.dma.channels[0].control);
}

test "bus state serialize roundtrip rebuilds pages" {
    const serialize = @import("../serialize.zig");
    var tc = try TestConsole.create(0x20, 3);
    defer tc.destroy();
    tc.bus.write8(0x7E_0100, 0x99);
    tc.bus.write8(0x00_4202, 5);
    tc.bus.write8(0x00_4203, 5);
    const saved_clock = tc.bus.clock;

    const size = comptime serialize.byteSize(Bus);
    const buf = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(buf);
    _ = serialize.write(Bus, &tc.bus, buf);

    var tc2 = try TestConsole.create(0x20, 3);
    defer tc2.destroy();
    _ = try serialize.read(Bus, &tc2.bus, buf);
    tc2.bus.postLoad();

    try std.testing.expectEqual(saved_clock, tc2.bus.clock);
    try std.testing.expectEqual(@as(u8, 0x99), tc2.bus.read8(0x7E_0100));
    try std.testing.expectEqual(@as(u16, 25), tc2.bus.math.rdmpy);
}
