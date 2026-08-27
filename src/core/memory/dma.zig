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

/// GDMA timing: a fixed per-DMA setup, a per-active-channel overhead, and a
/// per-byte transfer cost, all in master cycles. These replace the bus
/// accessors' per-access charge for the duration of the transfer.
const dma_setup_cycles: u64 = 8;
const dma_channel_overhead: u64 = 8;
const dma_cycles_per_byte: u64 = 8;

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

/// See `--dma-trace`. A general-purpose DMA reads its source straight out of
/// memory without the CPU issuing a load, so a transfer left pointing at
/// memory the window conversion abandoned is invisible to the stale-access
/// detector. It shows up only as graphics that never arrive.
pub var dbg_dma: usize = 0;
var dbg_dma_seen: [4096]u64 = @splat(0);
var dbg_dma_n: usize = 0;

/// DIAGNOSTIC bitmask (headless `--hdma-disable`): HDMA channels to skip
/// each scanline, to isolate which per-scanline effect a render depends on.
pub var dbg_hdma_disable: u8 = 0;

fn noteGpDma(i: usize, src: u24, b_reg: u8, bytes: u32, a_is_dest: bool, vdest: u16, control: u8, clk: u64) void {
    // Dedup within a ~370-frame bucket only: the same (src, reg) upload
    // recurring in a LATER scene (the Ceres re-upload after the intro) must
    // print again, or the trace claims a region was never written twice.
    const key: u64 = (clk / (357366 * 370)) << 40 | @as(u64, src) << 16 | @as(u64, b_reg) << 8 | @as(u64, i);
    for (dbg_dma_seen[0..dbg_dma_n]) |k| if (k == key) return;
    if (dbg_dma_n == dbg_dma_seen.len or dbg_dma_n == dbg_dma) return;
    dbg_dma_seen[dbg_dma_n] = key;
    dbg_dma_n += 1;
    const bank: u8 = @intCast(src >> 16);
    const off: u16 = @truncate(src);
    const dead = bank == 0x7E or bank == 0x7F or ((bank & 0x7F) < 0x40 and off < 0x2000);
    // For a VRAM transfer ($2118/$2119) the destination word matters as much
    // as the source — a tile upload landing at the wrong VMADD (or garbled at
    // the right one) shows up only against the destination.
    const is_vram = b_reg == 0x18 or b_reg == 0x19;
    std.debug.print("[dma] clk={d} ch{d} src={x:0>6} -> $21{x:0>2} {d} byte(s) ctl={x:0>2} mode={d}{s}{s}{s}", .{
        clk, i, src, b_reg, bytes, control, control & 0x07,
        if (a_is_dest) " (READ FROM B-BUS)" else "",
        if (dead) "  <-- ABANDONED MEMORY" else "",
        if (is_vram) " vdest=$" else "\n",
    });
    if (is_vram) std.debug.print("{x:0>4}\n", .{vdest});
}

pub const Dma = struct {
    channels: [8]Channel,
    hdmaen: u8, // $420C

    // Arm-time diagnostics for the SA-1 candidacy analyser (`--sa1-report`),
    // not machine state: GDMA destroys its own arm-time configuration as it
    // runs (`a_addr` advances, `count` counts down to zero inside the $420B
    // write), so what was ASKED FOR has to be captured before the transfer.
    // A handful of stores per (rare) $420B trigger, in the same acceptance
    // class as `bus.last_data_read`. Excluded from save states.
    /// Channel mask of the most recent $420B trigger (never cleared by the
    /// engine; the profiling console consumes and clears it).
    last_gdma_mask: u8,
    last_gdma_src: [8]u24,
    last_gdma_len: [8]u32,

    pub const serialize_skip = .{ "last_gdma_mask", "last_gdma_src", "last_gdma_len" };

    pub const init: Dma = .{
        .channels = [_]Channel{.{}} ** 8,
        .hdmaen = 0,
        .last_gdma_mask = 0,
        .last_gdma_src = @splat(0),
        .last_gdma_len = @splat(0),
    };

    /// One channel's arming, as the analyser reports it.
    pub const ArmInfo = struct {
        channel: u3,
        /// GDMA: the A-bus start address (source, or destination when
        /// `a_is_dest`) at trigger time. HDMA: the table address.
        src: u24,
        /// GDMA transfer size in bytes; 0 for HDMA (per-line, open-ended).
        bytes: u32,
        /// B-bus register low byte (the $21xx side).
        b_reg: u8,
        /// GDMA direction bit: B->A (the A-bus side is written).
        a_is_dest: bool,
        /// HDMA indirect mode: the bank indirect data is fetched from.
        indirect_bank: ?u8,
    };

    /// The channels the most recent $420B trigger ran, reassembled from the
    /// snapshot plus the live registers the transfer does not move
    /// (control, b_addr).
    pub fn gdmaArms(self: *const Dma, buf: *[8]ArmInfo) []ArmInfo {
        var n: usize = 0;
        for (0..8) |i| {
            if (self.last_gdma_mask & (@as(u8, 1) << @intCast(i)) == 0) continue;
            const ch = &self.channels[i];
            buf[n] = .{
                .channel = @intCast(i),
                .src = self.last_gdma_src[i],
                .bytes = self.last_gdma_len[i],
                .b_reg = ch.b_addr,
                .a_is_dest = ch.control & 0x80 != 0,
                .indirect_bank = null,
            };
            n += 1;
        }
        return buf[0..n];
    }

    /// The channels enabled at a $420C write. HDMA arming mutates nothing,
    /// so everything reads live; `src` is the table the channel will walk.
    pub fn hdmaArms(self: *const Dma, buf: *[8]ArmInfo) []ArmInfo {
        var n: usize = 0;
        for (0..8) |i| {
            if (self.hdmaen & (@as(u8, 1) << @intCast(i)) == 0) continue;
            const ch = &self.channels[i];
            buf[n] = .{
                .channel = @intCast(i),
                .src = (@as(u24, ch.a_bank) << 16) | ch.a_addr,
                .bytes = 0,
                .b_reg = ch.b_addr,
                .a_is_dest = false,
                .indirect_bank = if (ch.control & 0x40 != 0) ch.indirect_bank else null,
            };
            n += 1;
        }
        return buf[0..n];
    }

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
        // Snapshot what was asked for before the channel loop destroys it
        // (see the field comments above).
        self.last_gdma_mask = mask;
        for (0..8) |i| {
            if (mask & (@as(u8, 1) << @intCast(i)) == 0) continue;
            const ch = &self.channels[i];
            self.last_gdma_src[i] = (@as(u24, ch.a_bank) << 16) | ch.a_addr;
            self.last_gdma_len[i] = if (ch.count == 0) 0x10000 else ch.count;
            if (dbg_dma != 0)
                noteGpDma(i, self.last_gdma_src[i], ch.b_addr, self.last_gdma_len[i], ch.control & 0x80 != 0, if (@hasField(@TypeOf(bus.*), "ppu")) bus.ppu.vram_addr else 0, ch.control, if (@hasField(@TypeOf(bus.*), "clock")) bus.clock else 0);
        }
        const start = bus.clock;
        var cost: u64 = dma_setup_cycles;
        for (0..8) |i| {
            if (mask & (@as(u8, 1) << @intCast(i)) == 0) continue;
            cost += dma_channel_overhead;
            cost += dma_cycles_per_byte * @as(u64, self.transferGpChannel(bus, i));
        }
        // Replace the bus accessors' per-access charge with the fixed DMA cost.
        bus.clock = start + cost;
    }

    /// Hardware forbids the DMA unit's A-bus side from touching the B-bus
    /// window, the DMA register file, or the DMA trigger registers: such
    /// reads return open bus and such writes are dropped. Enforcing it also
    /// means a descriptor pointed at $420B cannot retrigger GDMA from inside
    /// the running transfer (which would recurse without bound).
    fn aBusValid(addr: u24) bool {
        const bank: u8 = @truncate(addr >> 16);
        if (bank & 0x7F >= 0x40) return true; // not a system bank
        return switch (@as(u16, @truncate(addr))) {
            0x2100...0x21FF, 0x420B, 0x420C, 0x4300...0x437F => false,
            else => true,
        };
    }

    fn aRead(bus: anytype, addr: u24) u8 {
        return if (aBusValid(addr)) bus.read8(addr) else bus.mdr;
    }

    fn aWrite(bus: anytype, addr: u24, value: u8) void {
        if (aBusValid(addr)) bus.write8(addr, value);
    }

    /// Transfer one channel; returns the number of bytes moved.
    fn transferGpChannel(self: *Dma, bus: anytype, i: usize) u32 {
        const ch = &self.channels[i];
        const pattern = unit_offsets[ch.control & 0x07];
        const b_to_a = ch.control & 0x80 != 0;
        const adjust: u2 = @truncate(ch.control >> 3);
        const total: u32 = if (ch.count == 0) 0x10000 else ch.count;

        // The A-bus bank is fixed for the whole transfer (only a_addr moves,
        // wrapping in 16 bits), so whether this channel can reach the guarded
        // window at all is loop-invariant — hoist it, and the common case
        // (a non-system bank) skips the per-byte aBusValid range check.
        const a_guarded = (ch.a_bank & 0x7F) < 0x40;

        // S-DD1: a channel armed through $4800/$4801 takes its A-side bytes
        // from the decompressor instead of ROM. Only A→B can decompress —
        // the chip has no path back into the cartridge.
        const decompress = bus.cart.chip == .sdd1 and !b_to_a and bus.sdd1.channelArmed(i);
        if (decompress) bus.sdd1.beginTransfer(i, (@as(u24, ch.a_bank) << 16) | ch.a_addr);

        var remaining = total;
        var p: usize = 0;
        while (remaining > 0) : (remaining -= 1) {
            // `pattern` is a runtime slice, so `p % pattern.len` compiles to a
            // real division on every transferred byte — 65,536 of them for a
            // full VRAM upload. A wrapping counter costs one compare.
            const off = pattern[p];
            p += 1;
            if (p == pattern.len) p = 0;
            const b: u24 = 0x2100 | @as(u24, ch.b_addr +% off);
            const a: u24 = (@as(u24, ch.a_bank) << 16) | ch.a_addr;
            if (b_to_a) {
                if (a_guarded) aWrite(bus, a, bus.read8(b)) else bus.write8(a, bus.read8(b));
            } else if (decompress) {
                bus.write8(b, bus.sdd1.nextByte());
            } else {
                bus.write8(b, if (a_guarded) aRead(bus, a) else bus.read8(a));
            }
            switch (adjust) {
                0 => ch.a_addr +%= 1, // increment
                2 => ch.a_addr -%= 1, // decrement
                else => {}, // 1, 3: fixed
            }
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
            if (dbg_hdma_disable & (@as(u8, 1) << @intCast(i)) != 0) continue;
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
                aWrite(bus, a, bus.read8(b));
            } else {
                bus.write8(b, aRead(bus, a));
            }
            if (indirect) ch.count +%= 1 else ch.table_addr +%= 1;
        }
    }

    /// Read one byte from the channel's table pointer and advance it.
    fn tableRead(self: *Dma, bus: anytype, ch: *Channel) u8 {
        _ = self;
        const a: u24 = (@as(u24, ch.a_bank) << 16) | ch.table_addr;
        ch.table_addr +%= 1;
        return aRead(bus, a);
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

/// A minimal bus for exercising startGpDma without a console: 64 KiB of
/// WRAM-ish memory behind read8/write8, plus the fields the engine touches.
const ArmTestBus = struct {
    mem: [0x10000]u8 = @splat(0),
    clock: u64 = 0,
    mdr: u8 = 0,
    // The chip enum needs an .sdd1 member (and the sdd1 stub its methods)
    // for transferGpChannel's decompress path to type-check; it never runs
    // here because the chip is .none.
    cart: struct { chip: enum { none, sdd1 } } = .{ .chip = .none },
    sdd1: struct {
        pub fn channelArmed(_: @This(), _: usize) bool {
            return false;
        }
        pub fn beginTransfer(_: @This(), _: usize, _: u24) void {}
        pub fn nextByte(_: @This()) u8 {
            return 0;
        }
    } = .{},

    fn read8(self: *ArmTestBus, addr: u24) u8 {
        return self.mem[@as(u16, @truncate(addr))];
    }
    fn write8(self: *ArmTestBus, addr: u24, value: u8) void {
        self.mem[@as(u16, @truncate(addr))] = value;
    }
};

test "gdma arming is snapshotted before the transfer destroys it" {
    var dma: Dma = .init;
    var bus: ArmTestBus = .{};

    // ch1: 0x40 bytes from $7E:2000 to $2118 (mode 1, increment).
    dma.writeReg(0x4310, 0x01);
    dma.writeReg(0x4311, 0x18);
    dma.writeReg(0x4312, 0x00);
    dma.writeReg(0x4313, 0x20);
    dma.writeReg(0x4314, 0x7E);
    dma.writeReg(0x4315, 0x40);
    dma.writeReg(0x4316, 0x00);
    dma.startGpDma(&bus, 0x02);

    // The transfer consumed the live registers...
    try std.testing.expectEqual(@as(u16, 0), dma.channels[1].count);
    try std.testing.expectEqual(@as(u16, 0x2040), dma.channels[1].a_addr);
    // ...but the snapshot holds what was asked for.
    var buf: [8]Dma.ArmInfo = undefined;
    const arms = dma.gdmaArms(&buf);
    try std.testing.expectEqual(@as(usize, 1), arms.len);
    try std.testing.expectEqual(@as(u3, 1), arms[0].channel);
    try std.testing.expectEqual(@as(u24, 0x7E_2000), arms[0].src);
    try std.testing.expectEqual(@as(u32, 0x40), arms[0].bytes);
    try std.testing.expectEqual(@as(u8, 0x18), arms[0].b_reg);
    try std.testing.expect(!arms[0].a_is_dest);
    try std.testing.expect(arms[0].indirect_bank == null);

    // count == 0 means the full 64 KiB, and the direction bit carries.
    dma.writeReg(0x4300, 0x81);
    dma.writeReg(0x4305, 0x00);
    dma.writeReg(0x4306, 0x00);
    dma.startGpDma(&bus, 0x01);
    const arms2 = dma.gdmaArms(&buf);
    try std.testing.expectEqual(@as(usize, 1), arms2.len);
    try std.testing.expectEqual(@as(u32, 0x10000), arms2[0].bytes);
    try std.testing.expect(arms2[0].a_is_dest);
}

test "hdma arming reads live registers, indirect bank only in indirect mode" {
    var dma: Dma = .init;
    // ch3: direct mode, table at $00:8D00.
    dma.writeReg(0x4330, 0x02);
    dma.writeReg(0x4331, 0x0D);
    dma.writeReg(0x4332, 0x00);
    dma.writeReg(0x4333, 0x8D);
    dma.writeReg(0x4334, 0x00);
    // ch4: indirect mode from bank $7E.
    dma.writeReg(0x4340, 0x42);
    dma.writeReg(0x4347, 0x7E);
    dma.hdmaen = 0x18;

    var buf: [8]Dma.ArmInfo = undefined;
    const arms = dma.hdmaArms(&buf);
    try std.testing.expectEqual(@as(usize, 2), arms.len);
    try std.testing.expectEqual(@as(u24, 0x00_8D00), arms[0].src);
    try std.testing.expect(arms[0].indirect_bank == null);
    try std.testing.expectEqual(@as(?u8, 0x7E), arms[1].indirect_bank);
}
