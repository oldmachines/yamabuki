//! WDC 65C816 CPU core.
//!
//! Generic over the bus type so the same core drives the real SNES bus, the
//! SingleStepTests mock bus, and (in M9) the SA-1's private bus. The bus
//! contract is three functions; all timing lives behind them:
//!     read8(addr: u24) u8      one data/opcode fetch cycle
//!     write8(addr: u24, v: u8) one write cycle
//!     idle()                   one CPU internal cycle
//!
//! Dispatch: `step` selects one of four comptime-monomorphized interpreter
//! variants keyed on the M/X flag widths, so all operand-size decisions,
//! index masking, and flag math inside an instruction resolve at compile
//! time — no function pointers, one jump-table switch per instruction.

const std = @import("std");
const ops = @import("ops.zig");

pub const Flags = struct {
    pub const c: u8 = 0x01;
    pub const z: u8 = 0x02;
    pub const i: u8 = 0x04;
    pub const d: u8 = 0x08;
    pub const x: u8 = 0x10; // index width (break bit in emulation mode)
    pub const m: u8 = 0x20; // accumulator width
    pub const v: u8 = 0x40;
    pub const n: u8 = 0x80;
};

pub const Regs = struct {
    /// 16-bit accumulator (C = B:A). 8-bit ops touch the low byte only.
    c: u16,
    x: u16,
    y: u16,
    s: u16,
    d: u16,
    pc: u16,
    dbr: u8,
    pbr: u8,
    p: u8,
    /// 6502 emulation mode.
    e: bool,

    pub const power: Regs = .{
        .c = 0,
        .x = 0,
        .y = 0,
        .s = 0x01FF,
        .d = 0,
        .pc = 0,
        .dbr = 0,
        .pbr = 0,
        .p = Flags.m | Flags.x | Flags.i,
        .e = true,
    };
};

pub const ExecState = enum(u8) { running, waiting, stopped };

pub fn Cpu(comptime BusT: type) type {
    return struct {
        const Self = @This();

        pub const serialize_skip = .{"bus"};

        bus: *BusT,
        regs: Regs,
        state: ExecState,
        nmi_pending: bool,
        irq_line: bool,

        pub fn init(bus: *BusT) Self {
            return .{
                .bus = bus,
                .regs = .power,
                .state = .running,
                .nmi_pending = false,
                .irq_line = false,
            };
        }

        /// Load the emulation-mode reset vector and start execution.
        pub fn reset(self: *Self) void {
            self.regs = .power;
            self.state = .running;
            self.nmi_pending = false;
            self.regs.pc = self.read16(0x00FFFC);
        }

        pub fn setNmi(self: *Self) void {
            self.nmi_pending = true;
            if (self.state == .waiting) self.state = .running;
        }

        pub fn setIrqLine(self: *Self, level: bool) void {
            self.irq_line = level;
            if (level and self.state == .waiting) self.state = .running;
        }

        /// Execute one instruction (or service one interrupt).
        pub fn step(self: *Self) void {
            switch (self.state) {
                .stopped => {
                    self.idle();
                    return;
                },
                .waiting => {
                    // setNmi/setIrqLine release the wait; IRQ does so even
                    // when masked by I (execution continues, no service).
                    self.idle();
                    return;
                },
                .running => {},
            }

            // Emulation mode pins the stack to page 1: normalize before the
            // instruction uses S, and again after native-only instructions
            // that move S freely mid-instruction.
            self.fixStackE();

            if (self.nmi_pending) {
                self.nmi_pending = false;
                self.interrupt(if (self.regs.e) 0xFFFA else 0xFFEA);
                return;
            }
            if (self.irq_line and (self.regs.p & Flags.i) == 0) {
                self.interrupt(if (self.regs.e) 0xFFFE else 0xFFEE);
                return;
            }

            const m8 = self.regs.e or (self.regs.p & Flags.m) != 0;
            const x8 = self.regs.e or (self.regs.p & Flags.x) != 0;
            if (m8) {
                if (x8) ops.dispatch(self, true, true) else ops.dispatch(self, true, false);
            } else {
                if (x8) ops.dispatch(self, false, true) else ops.dispatch(self, false, false);
            }
            self.fixStackE();
        }

        /// Run until the bus clock reaches `target` master cycles.
        pub fn runUntil(self: *Self, target: u64) void {
            while (self.bus.clock < target) self.step();
        }

        fn interrupt(self: *Self, vector: u16) void {
            self.idle();
            self.idle();
            if (!self.regs.e) self.push8(self.regs.pbr);
            self.push16(self.regs.pc);
            // Hardware interrupts push B clear in emulation mode.
            const pushed = if (self.regs.e) self.regs.p & ~Flags.x else self.regs.p;
            self.push8(pushed);
            self.regs.p = (self.regs.p | Flags.i) & ~Flags.d;
            self.regs.pbr = 0;
            self.regs.pc = self.read16(vector);
            self.fixStackE();
        }

        // --- bus access helpers ------------------------------------------

        pub inline fn idle(self: *Self) void {
            self.bus.idle();
        }

        /// A *data* read. Code fetches deliberately do not come through here
        /// (see `fetch8`), so `last_data_read` records only the addresses an
        /// instruction actually operates on, never the instruction stream.
        ///
        /// That distinction is what lets the frame-budget profiler tell a wait
        /// loop from a working one: a wait polls the same address every time
        /// round, and a loop that is computing something walks memory.
        pub inline fn read8(self: *Self, addr: u24) u8 {
            if (@hasField(BusT, "last_data_read")) self.bus.last_data_read = addr;
            return self.bus.read8(addr);
        }

        /// A *data* write. Stack pushes deliberately do not come through here
        /// (see `push8`), so `last_data_write` records only writes that change
        /// the machine's state, never call/return bookkeeping.
        pub inline fn write8(self: *Self, addr: u24, value: u8) void {
            if (@hasField(BusT, "last_data_write")) self.bus.last_data_write = addr;
            self.bus.write8(addr, value);
        }

        /// 16-bit read, linear 24-bit address increment (crosses banks).
        pub fn read16(self: *Self, addr: u24) u16 {
            const lo: u16 = self.read8(addr);
            const hi: u16 = self.read8(addr +% 1);
            return lo | hi << 8;
        }

        /// 16-bit read in bank 0 with 16-bit wraparound (direct page, stack).
        pub fn read16b0(self: *Self, addr16: u16) u16 {
            const lo: u16 = self.read8(addr16);
            const hi: u16 = self.read8(addr16 +% 1);
            return lo | hi << 8;
        }

        pub fn write16(self: *Self, addr: u24, value: u16) void {
            self.write8(addr, @truncate(value));
            self.write8(addr +% 1, @truncate(value >> 8));
        }

        pub fn write16b0(self: *Self, addr16: u16, value: u16) void {
            self.write8(addr16, @truncate(value));
            self.write8(addr16 +% 1, @truncate(value >> 8));
        }

        /// An opcode/operand fetch: goes straight to the bus, so it does not
        /// register as a data read. Identical timing; see `read8`.
        pub inline fn fetch8(self: *Self) u8 {
            const v = self.bus.read8(@as(u24, self.regs.pbr) << 16 | self.regs.pc);
            self.regs.pc +%= 1;
            return v;
        }

        pub fn fetch16(self: *Self) u16 {
            const lo: u16 = self.fetch8();
            const hi: u16 = self.fetch8();
            return lo | hi << 8;
        }

        pub fn fetch24(self: *Self) u24 {
            const lo: u24 = self.fetch8();
            const mid: u24 = self.fetch8();
            const hi: u24 = self.fetch8();
            return lo | mid << 8 | hi << 16;
        }

        // --- stack helpers ------------------------------------------------
        // In emulation mode, "old" instructions wrap the stack within page 1
        // (push8/pull8); native-only instructions use full 16-bit arithmetic
        // (push8n/pull8n) and may leave page 1.

        /// Stack traffic goes straight to the bus, so it does not register as a
        /// data read or write. A JSL/RTL pair leaves the machine exactly as it
        /// found it, and a wait loop built around a subroutine call — which is
        /// how most SNES main loops are written — must not look like a loop with
        /// side effects just because it pushed a return address.
        pub fn push8(self: *Self, value: u8) void {
            self.bus.write8(self.regs.s, value);
            if (self.regs.e) {
                self.regs.s = 0x0100 | ((self.regs.s -% 1) & 0xFF);
            } else {
                self.regs.s -%= 1;
            }
        }

        pub fn pull8(self: *Self) u8 {
            if (self.regs.e) {
                self.regs.s = 0x0100 | ((self.regs.s +% 1) & 0xFF);
            } else {
                self.regs.s +%= 1;
            }
            return self.bus.read8(self.regs.s);
        }

        pub fn push8n(self: *Self, value: u8) void {
            self.bus.write8(self.regs.s, value);
            self.regs.s -%= 1;
        }

        pub fn pull8n(self: *Self) u8 {
            self.regs.s +%= 1;
            return self.bus.read8(self.regs.s);
        }

        pub fn push16(self: *Self, value: u16) void {
            self.push8(@truncate(value >> 8));
            self.push8(@truncate(value));
        }

        pub fn pull16(self: *Self) u16 {
            const lo: u16 = self.pull8();
            const hi: u16 = self.pull8();
            return lo | hi << 8;
        }

        pub fn push16n(self: *Self, value: u16) void {
            self.push8n(@truncate(value >> 8));
            self.push8n(@truncate(value));
        }

        pub fn pull16n(self: *Self) u16 {
            const lo: u16 = self.pull8n();
            const hi: u16 = self.pull8n();
            return lo | hi << 8;
        }

        /// In emulation mode the stack pointer high byte is forced back to
        /// $01 at the end of native-only instructions that move S freely.
        pub fn fixStackE(self: *Self) void {
            if (self.regs.e) self.regs.s = 0x0100 | (self.regs.s & 0xFF);
        }

        // --- flag helpers -------------------------------------------------

        pub inline fn getFlag(self: *Self, comptime flag: u8) bool {
            return (self.regs.p & flag) != 0;
        }

        pub inline fn putFlag(self: *Self, comptime flag: u8, set: bool) void {
            if (set) self.regs.p |= flag else self.regs.p &= ~flag;
        }

        pub fn setNZ8(self: *Self, value: u8) void {
            self.regs.p = (self.regs.p & ~(Flags.n | Flags.z)) |
                (value & Flags.n) | (if (value == 0) Flags.z else 0);
        }

        pub fn setNZ16(self: *Self, value: u16) void {
            self.regs.p = (self.regs.p & ~(Flags.n | Flags.z)) |
                (@as(u8, @truncate(value >> 8)) & Flags.n) |
                (if (value == 0) Flags.z else 0);
        }

        /// Set P with the side effects of X-width changes; used by PLP, REP,
        /// SEP, RTI, and mode switches. When x becomes 1, XH/YH are cleared.
        pub fn setP(self: *Self, value: u8) void {
            self.regs.p = value;
            if (self.regs.e) self.regs.p |= Flags.m | Flags.x;
            if ((self.regs.p & Flags.x) != 0) {
                self.regs.x &= 0x00FF;
                self.regs.y &= 0x00FF;
            }
        }

        // --- register byte views -------------------------------------------

        pub inline fn al(self: *Self) u8 {
            return @truncate(self.regs.c);
        }

        pub inline fn setAl(self: *Self, value: u8) void {
            self.regs.c = (self.regs.c & 0xFF00) | value;
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}

// A tiny flat-memory bus so the CPU can be unit-tested without the SST
// vectors (which are multi-GB and gitignored). The full opcode matrix is
// validated by `zig build test-sst`.
const FlatBus = struct {
    mem: [0x1_0000]u8 = @splat(0),
    clock: u64 = 0,

    pub fn read8(self: *FlatBus, addr: u24) u8 {
        self.clock += 1;
        return self.mem[@as(u16, @truncate(addr))];
    }
    pub fn write8(self: *FlatBus, addr: u24, value: u8) void {
        self.clock += 1;
        self.mem[@as(u16, @truncate(addr))] = value;
    }
    pub fn idle(self: *FlatBus) void {
        self.clock += 1;
    }
};

test "reset loads emulation vector" {
    var bus: FlatBus = .{};
    bus.mem[0xFFFC] = 0x00;
    bus.mem[0xFFFD] = 0x80;
    var cpu = Cpu(FlatBus).init(&bus);
    cpu.reset();
    try std.testing.expectEqual(@as(u16, 0x8000), cpu.regs.pc);
    try std.testing.expect(cpu.regs.e);
}

test "native 16-bit LDA/ADC and flags" {
    var bus: FlatBus = .{};
    // Program at $8000: enter native, 16-bit A, LDA #$0001, ADC #$7FFF
    const prog = [_]u8{
        0x18, // CLC
        0xFB, // XCE (native; leaves C = old E = 1)
        0xC2, 0x20, // REP #$20 (16-bit A)
        0xA9, 0x01, 0x00, // LDA #$0001
        0x18, // CLC (clear carry-in before the add)
        0x69, 0xFF, 0x7F, // ADC #$7FFF
    };
    @memcpy(bus.mem[0x8000 .. 0x8000 + prog.len], &prog);
    var cpu = Cpu(FlatBus).init(&bus);
    cpu.regs.pc = 0x8000;
    for (0..6) |_| cpu.step();
    try std.testing.expectEqual(@as(u16, 0x8000), cpu.regs.c);
    try std.testing.expect(cpu.getFlag(Flags.v)); // signed overflow
    try std.testing.expect(cpu.getFlag(Flags.n));
}

test "stack push/pull roundtrip in native mode" {
    var bus: FlatBus = .{};
    const prog = [_]u8{
        0x18, 0xFB, // native
        0xA9, 0x42, // LDA #$42 (8-bit)
        0x48, // PHA
        0xA9, 0x00, // LDA #$00
        0x68, // PLA
    };
    @memcpy(bus.mem[0x8000 .. 0x8000 + prog.len], &prog);
    var cpu = Cpu(FlatBus).init(&bus);
    cpu.regs.pc = 0x8000;
    for (0..6) |_| cpu.step();
    try std.testing.expectEqual(@as(u8, 0x42), cpu.al());
}
