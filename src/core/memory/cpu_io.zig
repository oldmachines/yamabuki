//! CPU-side I/O registers: interrupt enables, H/V-IRQ timer targets, and the
//! NMI / IRQ / H-V-blank status registers. A bus-attached leaf like Wram and
//! MathUnit — it only holds register state and the read-side-effect logic; the
//! scheduler (Console) decides *when* to set the flags and drive the CPU lines.

// $4200 NMITIMEN bit layout: bit 7 NMI enable, bits 5-4 IRQ mode (0 off,
// 1 H-IRQ, 2 V-IRQ, 3 H+V-IRQ — decoded by `irqMode`), bit 0 auto-joypad.
pub const nmi_enable: u8 = 0x80;
pub const auto_joypad_enable: u8 = 0x01;

pub const CpuIo = struct {
    /// $4200 interrupt-enable / auto-joypad.
    nmitimen: u8,
    /// $4201 programmable I/O port (WRIO) — stored, otherwise inert for now.
    wrio: u8,
    /// $4207/$4208 H-IRQ target (dot), 9 bits.
    htime: u16,
    /// $4209/$420A V-IRQ target (scanline), 9 bits.
    vtime: u16,
    /// $4210 RDNMI bit 7: vblank NMI flag, set at vblank, cleared on read.
    nmi_flag: bool,
    /// $4211 TIMEUP bit 7: IRQ flag, set on timer match, cleared on read.
    irq_flag: bool,
    /// $4212 HVBJOY bit 7: currently in vertical blank.
    in_vblank: bool,
    /// $4212 HVBJOY bit 6: currently in horizontal blank (best-effort).
    in_hblank: bool,
    /// $4212 HVBJOY bit 0: auto-joypad read in progress.
    auto_joypad_busy: bool,

    /// 5A22 revision reported in RDNMI's low nibble; commercially always 2.
    const cpu_version: u8 = 2;

    pub const init: CpuIo = .{
        .nmitimen = 0,
        .wrio = 0xFF,
        .htime = 0x1FF,
        .vtime = 0x1FF,
        .nmi_flag = false,
        .irq_flag = false,
        .in_vblank = false,
        .in_hblank = false,
        .auto_joypad_busy = false,
    };

    pub fn nmiEnabled(self: *const CpuIo) bool {
        return self.nmitimen & nmi_enable != 0;
    }

    /// IRQ mode: 0 = disabled, 1 = H, 2 = V, 3 = H+V.
    pub fn irqMode(self: *const CpuIo) u2 {
        return @truncate(self.nmitimen >> 4);
    }

    // --- register writes ($42xx) -------------------------------------------

    pub fn setHtimeLow(self: *CpuIo, v: u8) void {
        self.htime = (self.htime & 0x100) | v;
    }
    pub fn setHtimeHigh(self: *CpuIo, v: u8) void {
        self.htime = (self.htime & 0x0FF) | (@as(u16, v & 1) << 8);
    }
    pub fn setVtimeLow(self: *CpuIo, v: u8) void {
        self.vtime = (self.vtime & 0x100) | v;
    }
    pub fn setVtimeHigh(self: *CpuIo, v: u8) void {
        self.vtime = (self.vtime & 0x0FF) | (@as(u16, v & 1) << 8);
    }

    // --- status reads (open-bus bits blended from the current MDR) ----------

    /// $4210 RDNMI: bit7 = NMI flag (cleared by this read), bits 6-4 open bus,
    /// bits 3-0 = CPU version.
    pub fn readRdnmi(self: *CpuIo, mdr: u8) u8 {
        const v: u8 = (if (self.nmi_flag) @as(u8, 0x80) else 0) | (mdr & 0x70) | cpu_version;
        self.nmi_flag = false;
        return v;
    }

    /// $4211 TIMEUP: bit7 = IRQ flag (cleared by this read), bits 6-0 open bus.
    pub fn readTimeup(self: *CpuIo, mdr: u8) u8 {
        const v: u8 = (if (self.irq_flag) @as(u8, 0x80) else 0) | (mdr & 0x7F);
        self.irq_flag = false;
        return v;
    }

    /// $4212 HVBJOY: bit7 vblank, bit6 hblank, bit0 auto-joypad busy, rest open bus.
    pub fn readHvbjoy(self: *const CpuIo, mdr: u8) u8 {
        return (if (self.in_vblank) @as(u8, 0x80) else 0) |
            (if (self.in_hblank) @as(u8, 0x40) else 0) |
            (mdr & 0x3E) |
            (if (self.auto_joypad_busy) @as(u8, 0x01) else 0);
    }
};

test {
    var io: CpuIo = .init;
    // htime/vtime are 9-bit split across two ports.
    io.setHtimeLow(0x34);
    io.setHtimeHigh(0x01);
    try std.testing.expectEqual(@as(u16, 0x134), io.htime);
    io.setVtimeLow(0xE0);
    io.setVtimeHigh(0x00);
    try std.testing.expectEqual(@as(u16, 0x0E0), io.vtime);

    // RDNMI reports and then clears the NMI flag.
    io.nmi_flag = true;
    const r = io.readRdnmi(0x00);
    try std.testing.expectEqual(@as(u8, 0x82), r); // bit7 set + version 2
    try std.testing.expect(!io.nmi_flag);
    try std.testing.expectEqual(@as(u8, 0x02), io.readRdnmi(0x00)); // cleared now

    // TIMEUP reports and clears the IRQ flag.
    io.irq_flag = true;
    try std.testing.expectEqual(@as(u8, 0x80), io.readTimeup(0x00));
    try std.testing.expect(!io.irq_flag);

    io.nmitimen = nmi_enable | 0x20; // NMI on, V-IRQ
    try std.testing.expect(io.nmiEnabled());
    try std.testing.expectEqual(@as(u2, 2), io.irqMode());
}

// --- tests ---------------------------------------------------------------

const std = @import("std");

test "HVBJOY drives bits 7, 6 and 0 and passes bits 5-1 through from open bus" {
    var io: CpuIo = .init;
    // Nothing asserted: the driven bits read 0 whatever the MDR holds.
    try std.testing.expectEqual(@as(u8, 0x3E), io.readHvbjoy(0xFF));
    try std.testing.expectEqual(@as(u8, 0x00), io.readHvbjoy(0x00));
    // Everything asserted: the driven bits read 1 and open bus fills the rest.
    io.in_vblank = true;
    io.in_hblank = true;
    io.auto_joypad_busy = true;
    try std.testing.expectEqual(@as(u8, 0xC1), io.readHvbjoy(0x00));
    try std.testing.expectEqual(@as(u8, 0xFF), io.readHvbjoy(0xFF));
    try std.testing.expectEqual(@as(u8, 0xC1 | 0x2A), io.readHvbjoy(0x2A));
}

test "RDNMI blends the version nibble with open-bus bits 6-4 only" {
    var io: CpuIo = .init;
    try std.testing.expectEqual(@as(u8, 0x72), io.readRdnmi(0xFF)); // bits 6-4 + version 2
    try std.testing.expectEqual(@as(u8, 0x02), io.readRdnmi(0x0F)); // bits 3-0 never leak
    try std.testing.expectEqual(@as(u8, 0x02), io.readRdnmi(0x80)); // nor bit 7
    io.nmi_flag = true;
    try std.testing.expectEqual(@as(u8, 0xF2), io.readRdnmi(0xFF));
}

test "HTIME/VTIME high bytes keep only bit 0" {
    var io: CpuIo = .init;
    io.setHtimeLow(0x34);
    io.setHtimeHigh(0xFE);
    try std.testing.expectEqual(@as(u16, 0x034), io.htime);
    io.setHtimeHigh(0xFF);
    try std.testing.expectEqual(@as(u16, 0x134), io.htime);

    io.setVtimeLow(0xE0);
    io.setVtimeHigh(0xFE);
    try std.testing.expectEqual(@as(u16, 0x0E0), io.vtime);
    io.setVtimeHigh(0x01);
    try std.testing.expectEqual(@as(u16, 0x1E0), io.vtime);
    // The high write leaves the low byte alone and vice versa.
    io.setVtimeLow(0x00);
    try std.testing.expectEqual(@as(u16, 0x100), io.vtime);
}

test "irqMode decodes NMITIMEN bits 5-4 and ignores the rest" {
    var io: CpuIo = .init;
    const modes = [_]struct { reg: u8, mode: u2 }{
        .{ .reg = 0x00, .mode = 0 },
        .{ .reg = 0x10, .mode = 1 },
        .{ .reg = 0x20, .mode = 2 },
        .{ .reg = 0x30, .mode = 3 },
        .{ .reg = 0x81, .mode = 0 }, // NMI + auto-joypad, no IRQ
        .{ .reg = 0xB1, .mode = 3 },
        .{ .reg = 0x4F, .mode = 0 }, // bit 6 and the low nibble do not count
        .{ .reg = 0xDF, .mode = 1 },
    };
    for (modes) |m| {
        io.nmitimen = m.reg;
        try std.testing.expectEqual(m.mode, io.irqMode());
    }
}
