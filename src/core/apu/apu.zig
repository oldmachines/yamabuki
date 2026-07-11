//! S-APU: 64 KiB ARAM, the SPC700 core, the three timers, the CPU mailbox
//! ports ($2140-$2143 ↔ $F4-$F7), and an HLE boot handshake.
//!
//! The APU runs on its own 1.024 MHz clock and is caught up to the main
//! bus's master clock lazily: on every CPU access to the mailbox ports and
//! once per scanline. The conversion is exact fixed-point (no drift, no
//! u64 overflow) via a delta accumulator.
//!
//! Boot is high-level-emulated: instead of shipping Nintendo's 64-byte IPL
//! ROM, the documented port protocol is implemented directly — the APU
//! signals ready ($AA/$BB), accepts indexed block uploads into ARAM, and
//! jumps the SPC700 to the entry point on the P1=0 command. From then on the
//! uploaded program executes natively. Approximations: $FFC0-$FFFF reads
//! return ARAM (the IPL image is not mapped), and re-entering the boot ROM
//! (CONTROL bit7 + jump to $FFC0) is not supported.

const std = @import("std");
const spc700 = @import("spc700.zig");
const timing = @import("../timing.zig");

/// Exact clock ratio: 1,024,000 SPC cycles per 21,477,272 master cycles,
/// reduced by 8.
const spc_num: u64 = 128_000;
const spc_den: u64 = 2_684_659;

const BootState = enum(u8) { ready, transfer, done };

pub const Apu = struct {
    aram: [0x10000]u8,
    smp: spc700.Smp(Apu),

    // Mailbox ports: `cpu_in` is written by the main CPU and read by the SMP
    // at $F4-$F7; `cpu_out` is the reverse direction.
    cpu_in: [4]u8,
    cpu_out: [4]u8,

    // $F0 TEST (stored), $F1 CONTROL (timer enables, port clears, IPL bit).
    test_reg: u8,
    control: u8,
    // $F8/$F9: two general-purpose I/O-page RAM bytes.
    aux: [2]u8,

    // Timers: T0/T1 tick every 128 SPC cycles (8 kHz), T2 every 16 (64 kHz).
    // A stage counter runs up to the $FA-$FC target (0 = 256) and clocks a
    // 4-bit read-to-clear counter at $FD-$FF.
    t_target: [3]u8,
    t_stage: [3]u8,
    t_counter: [3]u8,
    divider: u8,

    // $F2/$F3 DSP register file (inert storage until the S-DSP lands, M5b).
    dsp_addr: u8,
    dsp_regs: [128]u8,

    // Catch-up scheduling state.
    spc_clock: u64,
    spc_target: u64,
    master_last: u64,
    master_acc: u64,

    // HLE boot handshake.
    boot: BootState,
    boot_addr: u16,
    boot_index: u8,

    /// Initialize in place; `self` must be at its final address (the SMP
    /// holds a pointer back to this struct as its bus).
    pub fn init(self: *Apu) void {
        self.* = .{
            .aram = @splat(0),
            .smp = undefined,
            .cpu_in = @splat(0),
            .cpu_out = .{ 0xAA, 0xBB, 0, 0 }, // boot-ready handshake values
            .test_reg = 0,
            .control = 0x80,
            .aux = @splat(0),
            .t_target = @splat(0),
            .t_stage = @splat(0),
            .t_counter = @splat(0),
            .divider = 0,
            .dsp_addr = 0,
            .dsp_regs = @splat(0),
            .spc_clock = 0,
            .spc_target = 0,
            .master_last = 0,
            .master_acc = 0,
            .boot = .ready,
            .boot_addr = 0,
            .boot_index = 0,
        };
        self.smp = spc700.Smp(Apu).init(self);
    }

    /// Re-wire the SMP's bus pointer after deserialization.
    pub fn postLoad(self: *Apu) void {
        self.smp.bus = self;
    }

    // --- CPU-side mailbox ($2140-$2143, mirrored through $217F) -----------

    pub fn cpuRead(self: *Apu, master_clock: u64, port: u2) u8 {
        self.catchUp(master_clock);
        return self.cpu_out[port];
    }

    pub fn cpuWrite(self: *Apu, master_clock: u64, port: u2, value: u8) void {
        self.catchUp(master_clock);
        self.cpu_in[port] = value;
        if (self.boot != .done and port == 0) self.bootPort0(value);
    }

    /// The HLE boot protocol, driven by main-CPU writes to port 0.
    fn bootPort0(self: *Apu, value: u8) void {
        const dest = @as(u16, self.cpu_in[3]) << 8 | self.cpu_in[2];
        switch (self.boot) {
            .ready => {
                // $CC with a nonzero command in P1 begins the first upload;
                // anything else (e.g. the $AA ready-clear write) is ignored.
                if (value == 0xCC and self.cpu_in[1] != 0) {
                    self.boot_addr = dest;
                    self.boot_index = 0;
                    self.boot = .transfer;
                    self.cpu_out[0] = value; // acknowledge
                }
            },
            .transfer => {
                if (value == self.boot_index) {
                    // The next indexed data byte (payload in P1).
                    self.aram[self.boot_addr] = self.cpu_in[1];
                    self.boot_addr +%= 1;
                    self.boot_index = value +% 1;
                } else {
                    // An index jump is a command: P1 = 0 executes at the
                    // address in P2/P3, anything else starts a new block.
                    if (self.cpu_in[1] == 0) {
                        self.smp.regs.pc = dest;
                        self.smp.regs.sp = 0xEF;
                        self.smp.state = .running;
                        self.boot = .done;
                    } else {
                        self.boot_addr = dest;
                        self.boot_index = 0;
                    }
                }
                self.cpu_out[0] = value; // echo = acknowledge
            },
            .done => unreachable,
        }
    }

    // --- catch-up scheduling -------------------------------------------

    /// Convert the master-clock delta to SPC cycles (exact fixed point) and
    /// run the SPC700 until it reaches the new target. Until the HLE boot
    /// hands over control the SMP has no program, so time simply elapses.
    pub fn catchUp(self: *Apu, master_clock: u64) void {
        // Saturating: GDMA rolls the bus clock back when it swaps the
        // accessors' per-access charges for its fixed cost, and a DMA to the
        // mailbox ports has then already shown us the pre-rollback clock.
        // Treat that as speculative run-ahead — a zero delta here — and
        // resync once master time passes the rollback point again.
        const delta = master_clock -| self.master_last;
        self.master_last = master_clock;
        self.master_acc += delta * spc_num;
        self.spc_target += self.master_acc / spc_den;
        self.master_acc %= spc_den;

        if (self.boot != .done) {
            self.spc_clock = self.spc_target;
            return;
        }
        while (self.spc_clock < self.spc_target) self.smp.step();
    }

    // --- SMP bus (the SPC700's read8/write8/idle contract) ----------------

    pub fn read8(self: *Apu, addr: u16) u8 {
        self.tick();
        if (addr & 0xFFF0 == 0x00F0) return self.ioRead(@truncate(addr));
        return self.aram[addr];
    }

    pub fn write8(self: *Apu, addr: u16, value: u8) void {
        self.tick();
        if (addr & 0xFFF0 == 0x00F0) {
            self.ioWrite(@truncate(addr), value);
            return;
        }
        self.aram[addr] = value;
    }

    pub fn idle(self: *Apu) void {
        self.tick();
    }

    /// One SPC cycle: advance the clock and the timer prescalers.
    inline fn tick(self: *Apu) void {
        self.spc_clock += 1;
        self.divider +%= 1;
        if (self.divider & 15 == 0) {
            self.tickTimer(2);
            if (self.divider & 127 == 0) {
                self.tickTimer(0);
                self.tickTimer(1);
            }
        }
    }

    fn tickTimer(self: *Apu, comptime i: usize) void {
        if (self.control & (@as(u8, 1) << i) == 0) return;
        self.t_stage[i] +%= 1;
        if (self.t_stage[i] == self.t_target[i]) {
            self.t_stage[i] = 0;
            self.t_counter[i] = (self.t_counter[i] + 1) & 15;
        }
    }

    // --- $F0-$FF I/O page ---------------------------------------------

    fn ioRead(self: *Apu, low: u4) u8 {
        return switch (low) {
            0x2 => self.dsp_addr,
            0x3 => self.dsp_regs[self.dsp_addr & 0x7F],
            0x4, 0x5, 0x6, 0x7 => self.cpu_in[low - 4],
            0x8, 0x9 => self.aux[low - 8],
            0xD, 0xE, 0xF => blk: {
                const v = self.t_counter[low - 0xD];
                self.t_counter[low - 0xD] = 0;
                break :blk v;
            },
            else => 0, // $F0/$F1/$FA-$FC are write-only
        };
    }

    fn ioWrite(self: *Apu, low: u4, value: u8) void {
        switch (low) {
            0x0 => self.test_reg = value,
            0x1 => {
                // A rising timer-enable edge resets that timer; bits 4/5
                // clear the CPU-side input port pairs.
                inline for (0..3) |i| {
                    const bit = @as(u8, 1) << i;
                    if (value & bit != 0 and self.control & bit == 0) {
                        self.t_stage[i] = 0;
                        self.t_counter[i] = 0;
                    }
                }
                if (value & 0x10 != 0) {
                    self.cpu_in[0] = 0;
                    self.cpu_in[1] = 0;
                }
                if (value & 0x20 != 0) {
                    self.cpu_in[2] = 0;
                    self.cpu_in[3] = 0;
                }
                self.control = value;
            },
            0x2 => self.dsp_addr = value,
            0x3 => {
                // The upper half of the DSP map is read-only mirrors.
                if (self.dsp_addr < 0x80) self.dsp_regs[self.dsp_addr] = value;
            },
            0x4, 0x5, 0x6, 0x7 => self.cpu_out[low - 4] = value,
            0x8, 0x9 => self.aux[low - 8] = value,
            0xA, 0xB, 0xC => self.t_target[low - 0xA] = value,
            else => {}, // $FD-$FF counters are read-only
        }
    }
};

// --- tests -----------------------------------------------------------------

test {
    std.testing.refAllDecls(@This());
}

/// Drive the HLE upload protocol like the main CPU would (krom's macros:
/// begin = P0 + $22, indexed data bytes, execute with P1 = 0).
fn uploadAndRun(apu: *Apu, dest: u16, program: []const u8) void {
    // SPCWaitBoot: P0 == $AA, P1 == $BB.
    std.debug.assert(apu.cpuRead(0, 0) == 0xAA);
    std.debug.assert(apu.cpuRead(0, 1) == 0xBB);
    // Begin upload: P2/P3 = dest, P1 = nonzero command, P0 = $AA + $22 = $CC.
    apu.cpuWrite(0, 2, @truncate(dest));
    apu.cpuWrite(0, 3, @truncate(dest >> 8));
    apu.cpuWrite(0, 1, 0xCC);
    apu.cpuWrite(0, 0, 0xCC);
    std.debug.assert(apu.cpuRead(0, 0) == 0xCC);
    // Indexed data bytes.
    for (program, 0..) |byte, i| {
        apu.cpuWrite(0, 1, byte);
        apu.cpuWrite(0, 0, @truncate(i));
        std.debug.assert(apu.cpuRead(0, 0) == @as(u8, @truncate(i)));
    }
    // Execute: P2/P3 = entry, P1 = 0, P0 = index + 2.
    apu.cpuWrite(0, 2, @truncate(dest));
    apu.cpuWrite(0, 3, @truncate(dest >> 8));
    apu.cpuWrite(0, 1, 0);
    apu.cpuWrite(0, 0, @truncate(program.len + 2));
}

test "HLE boot uploads a program and the SMP executes it" {
    const gpa = std.testing.allocator;
    const apu = try gpa.create(Apu);
    defer gpa.destroy(apu);
    apu.init();

    // MOV A,#$42; MOV $F4,A; BRA -2 (spin) — writes $42 to CPU port 0.
    const program = [_]u8{ 0xE8, 0x42, 0xC4, 0xF4, 0x2F, 0xFE };
    uploadAndRun(apu, 0x0200, &program);
    try std.testing.expectEqual(BootState.done, apu.boot);
    try std.testing.expectEqual(@as(u16, 0x0200), apu.smp.regs.pc);
    try std.testing.expectEqualSlices(u8, &program, apu.aram[0x0200 .. 0x0200 + program.len]);

    // ~100 SPC cycles ≈ 2100 master cycles: the program has long since run.
    try std.testing.expectEqual(@as(u8, 0x42), apu.cpuRead(2100, 0));
}

test "timers divide the SPC clock and counters clear on read" {
    const gpa = std.testing.allocator;
    const apu = try gpa.create(Apu);
    defer gpa.destroy(apu);
    apu.init();

    apu.write8(0xFA, 4); // T0 target 4 -> one count per 512 SPC cycles
    apu.write8(0xF1, 0x01); // enable T0
    // The two writes above already ticked twice; run to 1100 total cycles.
    while (apu.spc_clock < 1100) apu.idle();
    try std.testing.expectEqual(@as(u8, 2), apu.read8(0xFD));
    try std.testing.expectEqual(@as(u8, 0), apu.read8(0xFD)); // cleared
}

test "mailbox ports carry both directions once booted" {
    const gpa = std.testing.allocator;
    const apu = try gpa.create(Apu);
    defer gpa.destroy(apu);
    apu.init();

    // MOV A,$F7; MOV $F5,A; BRA -2 — copy CPU port 3 to APU port 1.
    const program = [_]u8{ 0xE4, 0xF7, 0xC4, 0xF5, 0x2F, 0xFE };
    uploadAndRun(apu, 0x0300, &program);
    apu.cpuWrite(0, 3, 0x5A);
    try std.testing.expectEqual(@as(u8, 0x5A), apu.cpuRead(2100, 1));
}
