//! S-APU: 64 KiB ARAM, the SPC700 core, the S-DSP (one stereo sample per 32
//! SPC cycles into an output ring), the three timers, the CPU mailbox ports
//! ($2140-$2143 ↔ $F4-$F7), and an HLE boot handshake.
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
const dsp_mod = @import("dsp.zig");
const timing = @import("../timing.zig");

/// Exact clock ratio: 1,024,000 SPC cycles per 21,477,272 master cycles,
/// reduced by 8.
const spc_num: u64 = 128_000;
const spc_den: u64 = 2_684_659;

/// SPC cycles per S-DSP output sample (1.024 MHz / 32 kHz).
const cycles_per_sample: u64 = 32;

/// Ring capacity in stereo frames (power of two; ~15 video frames of slack
/// before the oldest unread audio is overwritten).
const audio_capacity: u32 = 8192;

const BootState = enum(u8) { ready, transfer, done };

pub const Apu = struct {
    // The audio ring is transient output (like the framebuffer), not
    // machine state: a loaded save state resumes with an empty ring.
    pub const serialize_skip = .{ "audio", "audio_head", "audio_tail" };

    aram: [0x10000]u8,
    smp: spc700.Smp(Apu),
    dsp: dsp_mod.Dsp,

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

    // $F2 DSP address latch ($F3 reads/writes go through `dsp`).
    dsp_addr: u8,

    // Interleaved stereo output ring; head/read and tail/write are monotonic
    // frame counters (index = counter % capacity).
    audio: [audio_capacity * 2]i16,
    audio_head: u32,
    audio_tail: u32,

    // Catch-up scheduling state.
    spc_clock: u64,
    spc_target: u64,
    master_last: u64,
    master_acc: u64,

    // HLE boot handshake.
    boot: BootState,
    boot_addr: u16,
    boot_index: u8,
    /// A boot port-0 write is waiting to be acted on. The real IPL reads the
    /// data port (P1) only after it has echoed the index and the main CPU has
    /// finished writing the byte, so a boot step is deferred to the next
    /// port-0 read (the main CPU always polls for the echo) — by then both P0
    /// and P1 are final regardless of the order the game wrote them. Reacting
    /// on the P0 write instead would latch a stale P1 for any uploader that
    /// writes the index before the data (e.g. Kirby Super Star, via a 16-bit
    /// store to $2140).
    boot_pending: bool,

    /// Initialize in place; `self` must be at its final address (the SMP
    /// holds a pointer back to this struct as its bus).
    pub fn init(self: *Apu) void {
        self.* = .{
            .aram = @splat(0),
            .smp = undefined,
            .dsp = .init,
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
            .audio = @splat(0),
            .audio_head = 0,
            .audio_tail = 0,
            .spc_clock = 0,
            .spc_target = 0,
            .master_last = 0,
            .master_acc = 0,
            .boot = .ready,
            .boot_addr = 0,
            .boot_index = 0,
            .boot_pending = false,
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
        // A deferred boot step runs here: the main CPU polls port 0 for the
        // echo after writing a byte, so both P0 and P1 are final by now.
        if (self.boot != .done and port == 0 and self.boot_pending) {
            self.boot_pending = false;
            self.bootPort0();
        }
        return self.cpu_out[port];
    }

    pub fn cpuWrite(self: *Apu, master_clock: u64, port: u2, value: u8) void {
        self.catchUp(master_clock);
        self.cpu_in[port] = value;
        if (self.boot != .done and port == 0) self.boot_pending = true;
    }

    /// The HLE boot protocol. Deferred from the port-0 write to the following
    /// read (see `boot_pending`); the index is P0 (`cpu_in[0]`) and the data
    /// byte is P1 (`cpu_in[1]`), both final at this point.
    fn bootPort0(self: *Apu) void {
        const value = self.cpu_in[0];
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
            // The SPC has no program yet, but the DSP samples from power-on:
            // emit one sample per 32-cycle grid point the jump skips over, so
            // the stream stays exactly spc_clock/32 samples long.
            var next = (self.spc_clock | (cycles_per_sample - 1)) + 1;
            while (next <= self.spc_target) : (next += cycles_per_sample) self.dspSample();
            self.spc_clock = self.spc_target;
            return;
        }
        while (self.spc_clock < self.spc_target) self.smp.step();
    }

    // --- audio output ------------------------------------------------------

    /// Run the DSP for one 32 kHz sample and push it into the output ring;
    /// when the ring is full the oldest unread frame is overwritten.
    fn dspSample(self: *Apu) void {
        const s = self.dsp.sample(&self.aram);
        const idx = (self.audio_tail % audio_capacity) * 2;
        self.audio[idx] = s[0];
        self.audio[idx + 1] = s[1];
        self.audio_tail +%= 1;
        if (self.audio_tail -% self.audio_head > audio_capacity)
            self.audio_head = self.audio_tail -% audio_capacity;
    }

    /// Drain buffered audio into `dst` as interleaved stereo i16 at 32 kHz.
    /// Returns the number of i16 values copied (always even).
    pub fn readAudio(self: *Apu, dst: []i16) usize {
        var n: usize = 0;
        while (self.audio_head != self.audio_tail and n + 2 <= dst.len) {
            const idx = (self.audio_head % audio_capacity) * 2;
            dst[n] = self.audio[idx];
            dst[n + 1] = self.audio[idx + 1];
            n += 2;
            self.audio_head +%= 1;
        }
        return n;
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

    /// One SPC cycle: advance the clock, the DSP sample grid, and the timer
    /// prescalers.
    inline fn tick(self: *Apu) void {
        self.spc_clock += 1;
        if (self.spc_clock % cycles_per_sample == 0) self.dspSample();
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
            0x3 => self.dsp.read(@truncate(self.dsp_addr & 0x7F)),
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
                if (self.dsp_addr < 0x80) self.dsp.write(@truncate(self.dsp_addr), value);
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
    _ = apu.cpuRead(0, 0); // poll the echo: this runs the deferred execute
}

/// Same handshake as uploadAndRun, but each byte writes the index (P0) BEFORE
/// the data (P1) — the order Kirby Super Star uses (a 16-bit store to $2140
/// hits P0 first). The deferred boot must still latch the correct P1.
fn uploadAndRunP0First(apu: *Apu, dest: u16, program: []const u8) void {
    std.debug.assert(apu.cpuRead(0, 0) == 0xAA);
    apu.cpuWrite(0, 2, @truncate(dest));
    apu.cpuWrite(0, 3, @truncate(dest >> 8));
    apu.cpuWrite(0, 0, 0xCC); // index/command first
    apu.cpuWrite(0, 1, 0xCC); // then the "nonzero" flag
    std.debug.assert(apu.cpuRead(0, 0) == 0xCC);
    for (program, 0..) |byte, i| {
        apu.cpuWrite(0, 0, @truncate(i)); // index first
        apu.cpuWrite(0, 1, byte); // then the data byte
        std.debug.assert(apu.cpuRead(0, 0) == @as(u8, @truncate(i)));
    }
    apu.cpuWrite(0, 2, @truncate(dest));
    apu.cpuWrite(0, 3, @truncate(dest >> 8));
    apu.cpuWrite(0, 0, @truncate(program.len + 2));
    apu.cpuWrite(0, 1, 0);
    _ = apu.cpuRead(0, 0); // poll the echo: this runs the deferred execute
}

test "HLE boot latches the right data byte when the index is written first" {
    const gpa = std.testing.allocator;
    const apu = try gpa.create(Apu);
    defer gpa.destroy(apu);
    apu.init();

    const program = [_]u8{ 0xE8, 0x42, 0xC4, 0xF4, 0x2F, 0xFE };
    uploadAndRunP0First(apu, 0x0200, &program);
    try std.testing.expectEqual(BootState.done, apu.boot);
    try std.testing.expectEqual(@as(u16, 0x0200), apu.smp.regs.pc);
    // The whole program must land byte-for-byte (the pre-fix bug shifted every
    // byte by one and stored the stale handshake flag as byte 0).
    try std.testing.expectEqualSlices(u8, &program, apu.aram[0x0200 .. 0x0200 + program.len]);
    try std.testing.expectEqual(@as(u8, 0x42), apu.cpuRead(2100, 0));
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

test "DSP samples on the 32-cycle grid before and after boot" {
    const gpa = std.testing.allocator;
    const apu = try gpa.create(Apu);
    defer gpa.destroy(apu);
    apu.init();

    // Pre-boot: one master-clock frame elapses with no SPC program; the DSP
    // still emits exactly spc_clock/32 (silent) stereo frames.
    apu.catchUp(357_368); // 262 lines * 1364 cycles
    const expected = apu.spc_clock / 32;
    var buf: [2048]i16 = undefined;
    var total: usize = 0;
    var nonzero = false;
    while (true) {
        const n = apu.readAudio(&buf);
        if (n == 0) break;
        total += n;
        for (buf[0..n]) |s| nonzero = nonzero or (s != 0);
    }
    try std.testing.expectEqual(expected, total / 2);
    try std.testing.expect(!nonzero); // FLG resets to mute

    // Boot a spin program; the grid continues seamlessly across handover.
    const program = [_]u8{ 0x2F, 0xFE }; // BRA -2
    uploadAndRun(apu, 0x0200, &program);
    apu.catchUp(2 * 357_368);
    const expected2 = apu.spc_clock / 32 - expected;
    total = 0;
    while (true) {
        const n = apu.readAudio(&buf);
        if (n == 0) break;
        total += n;
    }
    try std.testing.expectEqual(expected2, total / 2);
}

test "SPC $F2/$F3 traffic reaches the DSP and produces audio" {
    const gpa = std.testing.allocator;
    const apu = try gpa.create(Apu);
    defer gpa.destroy(apu);
    apu.init();

    // A looping constant BRR sample at $1000, directory page $03.
    const dir: u16 = 0x0300;
    std.mem.writeInt(u16, apu.aram[dir..][0..2], 0x1000, .little);
    std.mem.writeInt(u16, apu.aram[dir + 2 ..][0..2], 0x1000, .little);
    apu.aram[0x1000] = 0xC3; // shift 12, filter 0, end+loop
    @memset(apu.aram[0x1001..0x1009], 0x44);

    // Drive the DSP register file the way an SPC driver would ($F2 addr,
    // $F3 data), through the SMP-side bus interface.
    const writes = [_][2]u8{
        .{ 0x5D, 0x03 }, // DIR
        .{ 0x04, 0x00 }, // V0 SRCN
        .{ 0x02, 0x00 }, // V0 pitch 0x1000
        .{ 0x03, 0x10 },
        .{ 0x05, 0x00 }, // ADSR off -> GAIN
        .{ 0x07, 0x7F }, // GAIN direct max
        .{ 0x00, 0x50 }, // VOLL
        .{ 0x01, 0x50 }, // VOLR
        .{ 0x0C, 0x7F }, // MVOL
        .{ 0x1C, 0x7F },
        .{ 0x6C, 0x20 }, // FLG: unmute, echo writes off
        .{ 0x4C, 0x01 }, // KON voice 0
    };
    for (writes) |w| {
        apu.write8(0xF2, w[0]);
        apu.write8(0xF3, w[1]);
    }
    // Readback goes through the live register file.
    apu.write8(0xF2, 0x0C);
    try std.testing.expectEqual(@as(u8, 0x7F), apu.read8(0xF3));

    // Run ~1024 SPC cycles (32 samples) and expect audible output.
    for (0..1024) |_| apu.idle();
    var buf: [4096]i16 = undefined;
    const n = apu.readAudio(&buf);
    try std.testing.expect(n >= 32);
    var peak: i16 = 0;
    for (buf[0..n]) |s| peak = @max(peak, s);
    try std.testing.expect(peak > 1000);
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
