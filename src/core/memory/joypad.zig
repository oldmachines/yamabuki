//! Controller ports: two standard 12-button joypads.
//!
//! Frontends push button state via `Console.setButtons`; games read it two
//! ways. The manual path is the NES-style serial interface — write $4016
//! bit 0 to strobe the latch, then clock bits out one per $4016/$4017 read
//! (B first; 1s after all 16 bits). The common path is the auto-joypad read:
//! when NMITIMEN bit 0 is set, the scheduler latches both pads at the start
//! of vblank into $4218-$421B ($421C-$421F stay 0 — no multitap). The fast
//! core performs the auto-read instantly, so HVBJOY's busy bit never reads 1.
//!
//! Button bit layout (matches the $4219/$4218 register pair as one u16):
//! bit15 B, 14 Y, 13 Select, 12 Start, 11 Up, 10 Down, 9 Left, 8 Right,
//! 7 A, 6 X, 5 L, 4 R; bits 3-0 are the pad signature (0000 = standard).

pub const Button = struct {
    pub const b: u16 = 0x8000;
    pub const y: u16 = 0x4000;
    pub const select: u16 = 0x2000;
    pub const start: u16 = 0x1000;
    pub const up: u16 = 0x0800;
    pub const down: u16 = 0x0400;
    pub const left: u16 = 0x0200;
    pub const right: u16 = 0x0100;
    pub const a: u16 = 0x0080;
    pub const x: u16 = 0x0040;
    pub const l: u16 = 0x0020;
    pub const r: u16 = 0x0010;
};

pub const Joypad = struct {
    /// Live button state per port, pushed by the frontend.
    buttons: [2]u16,
    /// Serial shift registers ($4016/$4017 reads consume from these).
    shift: [2]u16,
    /// Bits remaining in each shift register (reads past 16 return 1).
    remaining: [2]u8,
    /// $4016 bit 0: while high, the latches follow the live buttons.
    strobe: bool,
    /// Auto-joypad results, $4218-$421F as four u16s (JOY1-JOY4).
    auto: [4]u16,

    pub const init: Joypad = .{
        .buttons = @splat(0),
        .shift = @splat(0),
        .remaining = @splat(0),
        .strobe = false,
        .auto = @splat(0),
    };

    /// $4016 write: strobe. The falling edge latches both pads for serial
    /// reads; while high, reads keep returning the live B button.
    pub fn writeStrobe(self: *Joypad, value: u8) void {
        const high = value & 1 != 0;
        if (self.strobe and !high) {
            for (0..2) |p| {
                self.shift[p] = self.buttons[p];
                self.remaining[p] = 16;
            }
        }
        self.strobe = high;
    }

    /// $4016/$4017 read, bit 0 = next serial bit of pad `port`.
    /// Open-bus bits are blended in by the bus (via `mdr`).
    pub fn readSerial(self: *Joypad, port: u1, mdr: u8) u8 {
        const bit: u8 = blk: {
            if (self.strobe) break :blk @truncate(self.buttons[port] >> 15);
            if (self.remaining[port] == 0) break :blk 1; // exhausted: 1s
            const b: u8 = @truncate(self.shift[port] >> 15);
            self.shift[port] <<= 1;
            self.remaining[port] -= 1;
            break :blk b;
        };
        // $4016: bits 7-2 open bus, bit 1 = port 1 data line 2 (unconnected).
        // $4017: bits 7-5 open bus, bits 4-2 read 1 on hardware.
        const base: u8 = if (port == 0) mdr & 0xFC else (mdr & 0xE0) | 0x1C;
        return base | bit;
    }

    /// Auto-joypad read: latch both pads (vblank start, NMITIMEN bit 0).
    /// Also consumes the serial state exactly as the hardware's 16 clocks do.
    pub fn autoRead(self: *Joypad) void {
        for (0..2) |p| {
            self.auto[p] = self.buttons[p];
            self.shift[p] = 0;
            self.remaining[p] = 0; // serial reads now return 1s
        }
        self.auto[2] = 0;
        self.auto[3] = 0;
    }

    /// $4218-$421F: auto-read result bytes (JOY1L..JOY4H).
    pub fn readAuto(self: *const Joypad, offset: u3) u8 {
        const word = self.auto[offset >> 1];
        return if (offset & 1 == 0) @truncate(word) else @truncate(word >> 8);
    }
};

// --- tests -------------------------------------------------------------------

const std = @import("std");

test "strobe latches and serial reads clock out B first" {
    var joy: Joypad = .init;
    joy.buttons[0] = Button.b | Button.start | Button.r;

    joy.writeStrobe(1);
    // While strobed, reads return the live B bit without consuming.
    try std.testing.expectEqual(@as(u8, 1), joy.readSerial(0, 0) & 1);
    try std.testing.expectEqual(@as(u8, 1), joy.readSerial(0, 0) & 1);
    joy.writeStrobe(0);

    // Serial order: B, Y, Select, Start, Up, Down, Left, Right, A, X, L, R.
    const expected = [_]u1{ 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0 };
    for (expected) |bit| {
        try std.testing.expectEqual(@as(u8, bit), joy.readSerial(0, 0) & 1);
    }
    // Exhausted: 1s forever.
    try std.testing.expectEqual(@as(u8, 1), joy.readSerial(0, 0) & 1);
    try std.testing.expectEqual(@as(u8, 1), joy.readSerial(0, 0) & 1);
}

test "second port shifts independently and blends open bus" {
    var joy: Joypad = .init;
    joy.buttons[1] = Button.y;
    joy.writeStrobe(1);
    joy.writeStrobe(0);
    // Pad 2, first bit (B) = 0; $4017 forces bits 4-2 high.
    try std.testing.expectEqual(@as(u8, 0x1C), joy.readSerial(1, 0x00));
    // Second bit (Y) = 1, with open-bus high bits from mdr.
    try std.testing.expectEqual(@as(u8, 0xFD), joy.readSerial(1, 0xFF) & 0xFD);
    // Pad 1 still un-latched buttons = 0 -> first bit 0.
    try std.testing.expectEqual(@as(u8, 0), joy.readSerial(0, 0) & 1);
}

test "auto-read snapshots both pads into the JOYx registers" {
    var joy: Joypad = .init;
    joy.buttons[0] = Button.a | Button.up;
    joy.buttons[1] = Button.select;
    joy.autoRead();
    try std.testing.expectEqual(@as(u8, 0x80), joy.readAuto(0)); // JOY1L: A
    try std.testing.expectEqual(@as(u8, 0x08), joy.readAuto(1)); // JOY1H: Up
    try std.testing.expectEqual(@as(u8, 0x00), joy.readAuto(2)); // JOY2L
    try std.testing.expectEqual(@as(u8, 0x20), joy.readAuto(3)); // JOY2H: Select
    try std.testing.expectEqual(@as(u8, 0x00), joy.readAuto(4)); // JOY3 empty
    // Post-auto-read, the serial line reads 1s (hardware clocked them out).
    try std.testing.expectEqual(@as(u8, 1), joy.readSerial(0, 0) & 1);
}
