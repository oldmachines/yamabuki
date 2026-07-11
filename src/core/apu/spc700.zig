//! Sony SPC700 (S-SMP) CPU core.
//!
//! Generic over the bus type so the same core drives the real APU bus (ARAM +
//! $F0-$FF I/O) and the SingleStepTests mock bus. The bus contract mirrors the
//! 65816 core's; all timing lives behind it — every access is one SPC cycle:
//!     read8(addr: u16) u8      one data/opcode fetch cycle
//!     write8(addr: u16, v: u8) one write cycle
//!     idle()                   one CPU internal cycle
//!
//! Dispatch is a single exhaustive 256-way switch (`ops.dispatch`); the SPC700
//! has no register-width modes, so no comptime variants are needed.

const std = @import("std");
const ops = @import("ops.zig");

pub const Flags = struct {
    pub const c: u8 = 0x01;
    pub const z: u8 = 0x02;
    pub const i: u8 = 0x04; // interrupt enable (unused by SNES software)
    pub const h: u8 = 0x08; // half carry
    pub const b: u8 = 0x10; // break (set by BRK)
    pub const p: u8 = 0x20; // direct page select ($0000 or $0100)
    pub const v: u8 = 0x40;
    pub const n: u8 = 0x80;
};

pub const Regs = struct {
    a: u8,
    x: u8,
    y: u8,
    sp: u8,
    pc: u16,
    psw: u8,

    pub const power: Regs = .{
        .a = 0,
        .x = 0,
        .y = 0,
        .sp = 0xEF,
        .pc = 0,
        .psw = Flags.z,
    };
};

pub const ExecState = enum(u8) { running, stopped };

pub fn Smp(comptime BusT: type) type {
    return struct {
        const Self = @This();

        pub const serialize_skip = .{"bus"};

        bus: *BusT,
        regs: Regs,
        /// SLEEP and STOP both halt the core; the SNES never wires the SPC700
        /// interrupt line, so neither wakes up (matching hardware in practice).
        state: ExecState,

        pub fn init(bus: *BusT) Self {
            return .{ .bus = bus, .regs = .power, .state = .running };
        }

        /// Execute one instruction.
        pub fn step(self: *Self) void {
            if (self.state == .stopped) {
                self.idle();
                return;
            }
            ops.dispatch(self);
        }

        // --- bus access helpers ------------------------------------------

        pub inline fn idle(self: *Self) void {
            self.bus.idle();
        }

        pub inline fn read8(self: *Self, addr: u16) u8 {
            return self.bus.read8(addr);
        }

        pub inline fn write8(self: *Self, addr: u16, value: u8) void {
            self.bus.write8(addr, value);
        }

        pub fn read16(self: *Self, addr: u16) u16 {
            const lo: u16 = self.read8(addr);
            const hi: u16 = self.read8(addr +% 1);
            return lo | hi << 8;
        }

        pub inline fn fetch8(self: *Self) u8 {
            const v = self.read8(self.regs.pc);
            self.regs.pc +%= 1;
            return v;
        }

        pub fn fetch16(self: *Self) u16 {
            const lo: u16 = self.fetch8();
            const hi: u16 = self.fetch8();
            return lo | hi << 8;
        }

        // --- direct page -----------------------------------------------
        // The P flag selects page 0 or 1; offsets always wrap within the page
        // (including +X/+Y indexing and the second byte of word/pointer reads).

        pub inline fn dpBase(self: *Self) u16 {
            return if (self.regs.psw & Flags.p != 0) 0x0100 else 0x0000;
        }

        pub inline fn dpAddr(self: *Self, offset: u8) u16 {
            return self.dpBase() | offset;
        }

        pub inline fn readDp(self: *Self, offset: u8) u8 {
            return self.read8(self.dpAddr(offset));
        }

        pub inline fn writeDp(self: *Self, offset: u8, value: u8) void {
            self.write8(self.dpAddr(offset), value);
        }

        /// 16-bit direct-page read; the high byte wraps within the page.
        pub fn readDp16(self: *Self, offset: u8) u16 {
            const lo: u16 = self.readDp(offset);
            const hi: u16 = self.readDp(offset +% 1);
            return lo | hi << 8;
        }

        // --- stack (always page 1) ---------------------------------------

        pub fn push8(self: *Self, value: u8) void {
            self.write8(0x0100 | @as(u16, self.regs.sp), value);
            self.regs.sp -%= 1;
        }

        pub fn pop8(self: *Self) u8 {
            self.regs.sp +%= 1;
            return self.read8(0x0100 | @as(u16, self.regs.sp));
        }

        pub fn push16(self: *Self, value: u16) void {
            self.push8(@truncate(value >> 8));
            self.push8(@truncate(value));
        }

        pub fn pop16(self: *Self) u16 {
            const lo: u16 = self.pop8();
            const hi: u16 = self.pop8();
            return lo | hi << 8;
        }

        // --- flag helpers -------------------------------------------------

        pub inline fn getFlag(self: *Self, comptime flag: u8) bool {
            return (self.regs.psw & flag) != 0;
        }

        pub inline fn putFlag(self: *Self, comptime flag: u8, set: bool) void {
            if (set) self.regs.psw |= flag else self.regs.psw &= ~flag;
        }

        pub fn setNZ8(self: *Self, value: u8) void {
            self.regs.psw = (self.regs.psw & ~(Flags.n | Flags.z)) |
                (value & Flags.n) | (if (value == 0) Flags.z else 0);
        }

        pub fn setNZ16(self: *Self, value: u16) void {
            self.regs.psw = (self.regs.psw & ~(Flags.n | Flags.z)) |
                (@as(u8, @truncate(value >> 8)) & Flags.n) |
                (if (value == 0) Flags.z else 0);
        }

        // --- register pair view -------------------------------------------

        pub inline fn ya(self: *Self) u16 {
            return @as(u16, self.regs.y) << 8 | self.regs.a;
        }

        pub inline fn setYa(self: *Self, value: u16) void {
            self.regs.a = @truncate(value);
            self.regs.y = @truncate(value >> 8);
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}

// A tiny flat-memory bus so the core can be unit-tested without the SST
// vectors (which are gitignored). The full opcode matrix is validated by
// `zig build test-sst-spc700`.
const FlatBus = struct {
    mem: [0x1_0000]u8 = @splat(0),
    clock: u64 = 0,

    pub fn read8(self: *FlatBus, addr: u16) u8 {
        self.clock += 1;
        return self.mem[addr];
    }
    pub fn write8(self: *FlatBus, addr: u16, value: u8) void {
        self.clock += 1;
        self.mem[addr] = value;
    }
    pub fn idle(self: *FlatBus) void {
        self.clock += 1;
    }
};

test "MOV A,#imm sets flags and ADC carries into H" {
    var bus: FlatBus = .{};
    const prog = [_]u8{
        0xE8, 0x0F, // MOV A,#$0F
        0x88, 0x01, // ADC A,#$01 -> $10 with half carry
    };
    @memcpy(bus.mem[0x200 .. 0x200 + prog.len], &prog);
    var smp = Smp(FlatBus).init(&bus);
    smp.regs.pc = 0x200;
    smp.step();
    try std.testing.expectEqual(@as(u8, 0x0F), smp.regs.a);
    smp.step();
    try std.testing.expectEqual(@as(u8, 0x10), smp.regs.a);
    try std.testing.expect(smp.getFlag(Flags.h));
    try std.testing.expect(!smp.getFlag(Flags.c));
}

test "direct page select via P flag" {
    var bus: FlatBus = .{};
    bus.mem[0x0042] = 0x11;
    bus.mem[0x0142] = 0x22;
    const prog = [_]u8{
        0xE4, 0x42, // MOV A,$42 (page 0)
        0x40, // SETP
        0xE4, 0x42, // MOV A,$42 (page 1)
    };
    @memcpy(bus.mem[0x200 .. 0x200 + prog.len], &prog);
    var smp = Smp(FlatBus).init(&bus);
    smp.regs.pc = 0x200;
    smp.step();
    try std.testing.expectEqual(@as(u8, 0x11), smp.regs.a);
    smp.step();
    smp.step();
    try std.testing.expectEqual(@as(u8, 0x22), smp.regs.a);
}

test "MUL and DIV" {
    var bus: FlatBus = .{};
    const prog = [_]u8{
        0xCF, // MUL YA (Y*A)
        0x9E, // DIV YA,X
    };
    @memcpy(bus.mem[0x200 .. 0x200 + prog.len], &prog);
    var smp = Smp(FlatBus).init(&bus);
    smp.regs.pc = 0x200;
    smp.regs.y = 12;
    smp.regs.a = 20;
    smp.step(); // YA = 240
    try std.testing.expectEqual(@as(u16, 240), smp.ya());
    smp.regs.x = 7;
    smp.step(); // 240 / 7 = 34 rem 2
    try std.testing.expectEqual(@as(u8, 34), smp.regs.a);
    try std.testing.expectEqual(@as(u8, 2), smp.regs.y);
}

test "CALL pushes return address and RET restores it" {
    var bus: FlatBus = .{};
    const prog = [_]u8{ 0x3F, 0x00, 0x30 }; // CALL !$3000
    @memcpy(bus.mem[0x200 .. 0x200 + prog.len], &prog);
    bus.mem[0x3000] = 0x6F; // RET
    var smp = Smp(FlatBus).init(&bus);
    smp.regs.pc = 0x200;
    smp.step();
    try std.testing.expectEqual(@as(u16, 0x3000), smp.regs.pc);
    smp.step();
    try std.testing.expectEqual(@as(u16, 0x203), smp.regs.pc);
    try std.testing.expectEqual(@as(u8, 0xEF), smp.regs.sp);
}
