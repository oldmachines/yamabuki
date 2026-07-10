//! DMA and HDMA engine: eight channels moving bytes between the A-bus (CPU
//! address space) and the B-bus ($2100-$21FF PPU/APU registers).
//!
//! General-purpose DMA ($420B) stalls the CPU and blasts a byte block through
//! one B-bus register set following a transfer-unit pattern. HDMA ($420C) walks
//! a per-channel table and injects a small transfer at every visible scanline's
//! H-blank — the mechanism raster effects (per-line scroll, gradients, windows)
//! are built on.
//!
//! Transfers go through the owning `Bus` so every A-bus and B-bus access is a
//! real bus access (open bus, mirrors, MMIO side effects all apply). GDMA's
//! cost is charged as a fixed 8 master cycles/byte + per-channel overhead,
//! overriding the per-access charge the bus accessors would otherwise add.

const std = @import("std");

/// B-bus register offsets written per transfer unit, indexed by DMAP mode
/// (bits 2-0). The pattern repeats to cover the whole byte count.
const unit_offsets = [8][]const u8{
    &.{0}, // 0: 1 byte  (1 reg)
    &.{ 0, 1 }, // 1: 2 bytes (2 regs, e.g. VMDATAL/H)
    &.{ 0, 0 }, // 2: 2 bytes (1 reg twice)
    &.{ 0, 0, 1, 1 }, // 3: 4 bytes (2 regs twice)
    &.{ 0, 1, 2, 3 }, // 4: 4 bytes (4 regs)
    &.{ 0, 1, 0, 1 }, // 5: 4 bytes (2 regs alternating)
    &.{ 0, 0 }, // 6: mirror of 2
    &.{ 0, 0, 1, 1 }, // 7: mirror of 3
};

pub const Channel = struct {
    control: u8 = 0, // $43x0 DMAP
    b_addr: u8 = 0, // $43x1 BBAD (B-bus low byte, added to $2100)
    a_addr: u16 = 0, // $43x2/3 A1T (A-bus offset)
    a_bank: u8 = 0, // $43x4 A1B (A-bus bank)
    count: u16 = 0, // $43x5/6 DAS (GDMA byte count / HDMA indirect address)
    indirect_bank: u8 = 0, // $43x7 DASB (HDMA indirect bank)
    table_addr: u16 = 0, // $43x8/9 A2A (HDMA current table pointer)
    line_counter: u8 = 0, // $43xA NTRL (HDMA line/repeat counter)
    scratch: u8 = 0, // $43xB/F unused (readable/writable scratch)
    /// HDMA runtime: perform a transfer on the current line.
    hdma_do_transfer: bool = false,
};

pub const Dma = struct {
    channels: [8]Channel,
    hdmaen: u8, // $420C

    pub const init: Dma = .{ .channels = [_]Channel{.{}} ** 8, .hdmaen = 0 };

    // --- register file ($43xy) --------------------------------------------

    pub fn readReg(self: *const Dma, addr: u16) u8 {
        const ch = &self.channels[(addr >> 4) & 7];
        return switch (addr & 0x0F) {
            0x0 => ch.control,
            0x1 => ch.b_addr,
            0x2 => @truncate(ch.a_addr),
            0x3 => @truncate(ch.a_addr >> 8),
            0x4 => ch.a_bank,
            0x5 => @truncate(ch.count),
            0x6 => @truncate(ch.count >> 8),
            0x7 => ch.indirect_bank,
            0x8 => @truncate(ch.table_addr),
            0x9 => @truncate(ch.table_addr >> 8),
            0xA => ch.line_counter,
            else => ch.scratch,
        };
    }

    pub fn writeReg(self: *Dma, addr: u16, value: u8) void {
        const ch = &self.channels[(addr >> 4) & 7];
        switch (addr & 0x0F) {
            0x0 => ch.control = value,
            0x1 => ch.b_addr = value,
            0x2 => ch.a_addr = (ch.a_addr & 0xFF00) | value,
            0x3 => ch.a_addr = (ch.a_addr & 0x00FF) | (@as(u16, value) << 8),
            0x4 => ch.a_bank = value,
            0x5 => ch.count = (ch.count & 0xFF00) | value,
            0x6 => ch.count = (ch.count & 0x00FF) | (@as(u16, value) << 8),
            0x7 => ch.indirect_bank = value,
            0x8 => ch.table_addr = (ch.table_addr & 0xFF00) | value,
            0x9 => ch.table_addr = (ch.table_addr & 0x00FF) | (@as(u16, value) << 8),
            0xA => ch.line_counter = value,
            else => ch.scratch = value,
        }
    }

    // --- general-purpose DMA ($420B) --------------------------------------

    /// Run GDMA on every channel selected in `mask`, lowest channel first.
    /// `bus` is the owning Bus (aliased with `self` — Zig permits it).
    pub fn startGpDma(self: *Dma, bus: anytype, mask: u8) void {
        if (mask == 0) return;
        const start = bus.clock;
        var cost: u64 = 8; // whole-DMA setup
        for (0..8) |i| {
            if (mask & (@as(u8, 1) << @intCast(i)) == 0) continue;
            cost += 8; // per-channel overhead
            cost += 8 * @as(u64, self.transferGpChannel(bus, i));
        }
        // Replace the bus accessors' per-access charge with the fixed DMA cost.
        bus.clock = start + cost;
    }

    /// Transfer one channel; returns the number of bytes moved.
    fn transferGpChannel(self: *Dma, bus: anytype, i: usize) u32 {
        const ch = &self.channels[i];
        const pattern = unit_offsets[ch.control & 0x07];
        const b_to_a = ch.control & 0x80 != 0;
        const adjust: u2 = @truncate(ch.control >> 3);
        const total: u32 = if (ch.count == 0) 0x10000 else ch.count;

        var remaining = total;
        var p: usize = 0;
        while (remaining > 0) : (remaining -= 1) {
            const off = pattern[p % pattern.len];
            const b: u24 = 0x2100 | @as(u24, ch.b_addr +% off);
            const a: u24 = (@as(u24, ch.a_bank) << 16) | ch.a_addr;
            if (b_to_a) {
                bus.write8(a, bus.read8(b));
            } else {
                bus.write8(b, bus.read8(a));
            }
            switch (adjust) {
                0 => ch.a_addr +%= 1, // increment
                2 => ch.a_addr -%= 1, // decrement
                else => {}, // 1, 3: fixed
            }
            p += 1;
        }
        ch.count = 0; // GDMA leaves DAS counted down to zero
        return total;
    }

    // --- HDMA ($420C) -----------------------------------------------------

    /// Reload table pointers and line counters at the top of the frame.
    pub fn hdmaInit(self: *Dma, bus: anytype) void {
        for (0..8) |i| {
            const ch = &self.channels[i];
            if (self.hdmaen & (@as(u8, 1) << @intCast(i)) == 0) continue;
            ch.table_addr = ch.a_addr;
            ch.line_counter = self.tableRead(bus, ch);
            if (ch.control & 0x40 != 0) self.loadIndirect(bus, ch);
            ch.hdma_do_transfer = true;
        }
    }

    /// Perform one line of HDMA for every enabled, not-yet-finished channel.
    pub fn hdmaRunLine(self: *Dma, bus: anytype) void {
        for (0..8) |i| {
            const ch = &self.channels[i];
            if (self.hdmaen & (@as(u8, 1) << @intCast(i)) == 0) continue;
            if (ch.line_counter == 0) continue; // channel completed this frame

            if (ch.hdma_do_transfer) self.hdmaTransfer(bus, ch);

            ch.line_counter -%= 1;
            ch.hdma_do_transfer = ch.line_counter & 0x80 != 0; // repeat flag
            if (ch.line_counter & 0x7F == 0) {
                ch.line_counter = self.tableRead(bus, ch);
                if (ch.control & 0x40 != 0) self.loadIndirect(bus, ch);
                ch.hdma_do_transfer = true;
            }
        }
    }

    fn hdmaTransfer(self: *Dma, bus: anytype, ch: *Channel) void {
        _ = self;
        const pattern = unit_offsets[ch.control & 0x07];
        const b_to_a = ch.control & 0x80 != 0;
        const indirect = ch.control & 0x40 != 0;
        for (pattern) |off| {
            const b: u24 = 0x2100 | @as(u24, ch.b_addr +% off);
            const a: u24 = if (indirect)
                (@as(u24, ch.indirect_bank) << 16) | ch.count
            else
                (@as(u24, ch.a_bank) << 16) | ch.table_addr;
            if (b_to_a) {
                bus.write8(a, bus.read8(b));
            } else {
                bus.write8(b, bus.read8(a));
            }
            if (indirect) ch.count +%= 1 else ch.table_addr +%= 1;
        }
    }

    /// Read one byte from the channel's table pointer and advance it.
    fn tableRead(self: *Dma, bus: anytype, ch: *Channel) u8 {
        _ = self;
        const a: u24 = (@as(u24, ch.a_bank) << 16) | ch.table_addr;
        ch.table_addr +%= 1;
        return bus.read8(a);
    }

    /// Read the 2-byte indirect address that follows a line-counter byte.
    fn loadIndirect(self: *Dma, bus: anytype, ch: *Channel) void {
        const lo: u16 = self.tableRead(bus, ch);
        const hi: u16 = self.tableRead(bus, ch);
        ch.count = lo | (hi << 8);
    }
};

// --- tests ---------------------------------------------------------------

test {
    std.testing.refAllDecls(@This());
}

test "dma channel register file roundtrips" {
    var dma: Dma = .init;
    dma.writeReg(0x4300, 0x81); // ch0 control
    dma.writeReg(0x4301, 0x18); // BBAD
    dma.writeReg(0x4302, 0x34); // A1T low
    dma.writeReg(0x4303, 0x12); // A1T high
    dma.writeReg(0x4304, 0x7E); // A1B
    dma.writeReg(0x4305, 0x00); // DAS low
    dma.writeReg(0x4306, 0x02); // DAS high -> count 0x200
    try std.testing.expectEqual(@as(u8, 0x81), dma.readReg(0x4300));
    try std.testing.expectEqual(@as(u16, 0x1234), dma.channels[0].a_addr);
    try std.testing.expectEqual(@as(u16, 0x0200), dma.channels[0].count);
    try std.testing.expectEqual(@as(u8, 0x02), dma.readReg(0x4306));

    // different channel is independent
    dma.writeReg(0x4371, 0x22); // ch7 BBAD
    try std.testing.expectEqual(@as(u8, 0x22), dma.channels[7].b_addr);
    try std.testing.expectEqual(@as(u8, 0x18), dma.channels[0].b_addr);
}

test "transfer unit patterns cover the documented modes" {
    try std.testing.expectEqual(@as(usize, 1), unit_offsets[0].len);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1 }, unit_offsets[1]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3 }, unit_offsets[4]);
}
