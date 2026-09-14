//! 128 KiB work RAM, plus the $2180-$2183 WRAM data port.

const std = @import("std");

pub const Wram = struct {
    data: [0x2_0000]u8,
    /// $2181-$2183: 17-bit address for the $2180 data port.
    port_addr: u17,

    pub const init: Wram = .{ .data = @splat(0), .port_addr = 0 };

    /// $2180 read: data at port address, post-incremented.
    pub fn portRead(self: *Wram) u8 {
        const v = self.data[self.port_addr];
        self.port_addr +%= 1;
        return v;
    }

    /// $2180 write: data at port address, post-incremented.
    pub fn portWrite(self: *Wram, value: u8) void {
        self.data[self.port_addr] = value;
        self.port_addr +%= 1;
    }

    pub fn setPortAddrLow(self: *Wram, value: u8) void {
        self.port_addr = (self.port_addr & 0x1_FF00) | value;
    }

    pub fn setPortAddrMid(self: *Wram, value: u8) void {
        self.port_addr = (self.port_addr & 0x1_00FF) | (@as(u17, value) << 8);
    }

    pub fn setPortAddrHigh(self: *Wram, value: u8) void {
        self.port_addr = (self.port_addr & 0x0_FFFF) | (@as(u17, value & 1) << 16);
    }
};

test "wram port autoincrement and wrap" {
    var wram: Wram = .init;
    wram.setPortAddrLow(0xFF);
    wram.setPortAddrMid(0xFF);
    wram.setPortAddrHigh(0x01);
    try std.testing.expectEqual(@as(u17, 0x1_FFFF), wram.port_addr);

    wram.portWrite(0xAA); // wraps to 0
    try std.testing.expectEqual(@as(u17, 0), wram.port_addr);
    try std.testing.expectEqual(@as(u8, 0xAA), wram.data[0x1_FFFF]);

    wram.portWrite(0xBB);
    wram.setPortAddrLow(0);
    wram.setPortAddrMid(0);
    wram.setPortAddrHigh(0);
    try std.testing.expectEqual(@as(u8, 0xBB), wram.portRead());
    try std.testing.expectEqual(@as(u17, 1), wram.port_addr);
}

// --- tests ---------------------------------------------------------------

test "WMADDH keeps only bit 0 of the written byte" {
    var wram: Wram = .init;
    wram.setPortAddrLow(0x34);
    wram.setPortAddrMid(0x12);
    wram.setPortAddrHigh(0xFE);
    try std.testing.expectEqual(@as(u17, 0x0_1234), wram.port_addr);
    wram.setPortAddrHigh(0xFF);
    try std.testing.expectEqual(@as(u17, 0x1_1234), wram.port_addr);
    wram.setPortAddrHigh(0x02);
    try std.testing.expectEqual(@as(u17, 0x0_1234), wram.port_addr);
}

test "a port read at $1FFFF returns that byte and wraps the pointer to 0" {
    var wram: Wram = .init;
    wram.data[0x1_FFFF] = 0x42;
    wram.data[0] = 0x24;
    wram.setPortAddrLow(0xFF);
    wram.setPortAddrMid(0xFF);
    wram.setPortAddrHigh(0x01);
    try std.testing.expectEqual(@as(u8, 0x42), wram.portRead());
    try std.testing.expectEqual(@as(u17, 0), wram.port_addr);
    try std.testing.expectEqual(@as(u8, 0x24), wram.portRead());
    try std.testing.expectEqual(@as(u17, 1), wram.port_addr);
}
