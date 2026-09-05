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

/// TEMP calibration: print bus.clock at the first fetch of this PC
/// (24-bit; the bank folds through $7F so fast mirrors match).
pub var dbg_clock_pc: u24 = 0;
pub var dbg_clock_fired: bool = false;
/// TEMP diagnostics: log writes to this WRAM-offset range (banks $7E/$40).
/// See `--dma-bank-pc`. Which instruction hands a DMA channel its A-bus bank
/// byte ($43x4). A window conversion that missed one leaves the transfer
/// reading memory the game abandoned, and nothing in the CPU's own accesses
/// shows it — the DMA does the reading.
pub var dbg_dmabank: usize = 0;
var dbg_dmabank_seen: [128]u32 = @splat(0);
var dbg_dmabank_n: usize = 0;

pub var dbg_watch_lo: u16 = 0;
pub var dbg_watch_hi: u16 = 0;
pub var dbg_watch_from: u64 = 0;
/// Only log watched writes of values >= this (0 = all).
pub var dbg_watch_val_min: u8 = 0;
var dbg_watch_n: usize = 0;
var dbg_watch_armed: bool = false;
/// TEMP diagnostics: instruction trace over a clock window.
pub var dbg_trace_from: u64 = 0;
pub var dbg_trace_to: u64 = 0;
/// TEMP diagnostics: trace up to N SA-1 instructions once the watch arms.
pub var dbg_trace_sa1: usize = 0;
var dbg_trace_sa1_n: usize = 0;
/// The split's S-CPU census: while the SA-1 owns the loop (the dual
/// image's upper copy is mapped — the SA-1 MMC write keeps the flag),
/// every S-CPU instruction address in the ROM window is marked, one byte
/// per 32 KiB-bank offset. A math site the S-CPU never runs there can be
/// a direct I-RAM cell access in that copy instead of a COP.
pub var dbg_upper_mapped: bool = false;
pub var dbg_scpu_set: ?[]u8 = null;
/// TEMP diagnostics, BW-RAM window conversions: report data accesses to the
/// ABANDONED WRAM homes. Once the low 8 KiB moves to $6000-$7FFF and banks
/// $7E/$7F move to $40/$41, nothing the game runs should ever touch real
/// WRAM again — so every hit here is a site the rewrite failed to move, and
/// the PC names it. Reports each (PBR,PC) once; the value is the ceiling on
/// distinct sites, not on accesses.
pub var dbg_stale: usize = 0;
pub var dbg_stale_from: u64 = 0;
var dbg_stale_seen: [512]u32 = @splat(0);
var dbg_stale_n: usize = 0;
/// TEMP diagnostics: with `dbg_stale` armed, the clockless (SA-1) core
/// keeps a ring of its last instructions and dumps it on the FIRST stale
/// hit — the history that led into the bad path, which a forward trace
/// can never afford to keep.
pub var dbg_stale_ring: bool = false;
const StaleRingEntry = struct { pbr: u8, pc: u16, c: u16, x: u16, y: u16, d: u16, dbr: u8, p: u8 };
var dbg_ring: [8192]StaleRingEntry = undefined;
var dbg_ring_n: usize = 0;
var dbg_ring_dumped: bool = false;

pub fn Cpu(comptime BusT: type) type {
    return struct {
        const Self = @This();

        pub const serialize_skip = .{"bus"};

        bus: *BusT,
        regs: Regs,
        state: ExecState,
        nmi_pending: bool,
        /// One-instruction service grace for an NMI asserted at an
        /// instruction boundary (see setNmi).
        nmi_delay: bool,
        irq_line: bool,

        pub fn init(bus: *BusT) Self {
            return .{
                .bus = bus,
                .regs = .power,
                .state = .running,
                .nmi_pending = false,
                .nmi_delay = false,
                .irq_line = false,
            };
        }

        /// Load the emulation-mode reset vector and start execution.
        pub fn reset(self: *Self) void {
            self.regs = .power;
            self.state = .running;
            self.nmi_pending = false;
            self.nmi_delay = false;
            self.regs.pc = self.readVector16(0x00FFFC);
        }

        pub fn setNmi(self: *Self) void {
            self.nmi_pending = true;
            // Hardware samples interrupts in an instruction's second-to-last
            // cycle, so an edge that lands at an instruction boundary — which
            // is where the line-based scheduler always raises vblank — lets
            // one more instruction finish before the service sequence. That
            // instruction is the window in which a `LDA $4210` edge-wait can
            // win the race against the NMI handler's own $4210 ack; SFA2's
            // boot spins forever without it (issue #88). WAI is the opposite:
            // it exists to remove the sampling latency, so a waiting CPU
            // services the NMI immediately on wake.
            self.nmi_delay = self.state == .running;
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
                if (self.nmi_delay) {
                    // The one-instruction sampling grace (see setNmi): fall
                    // through and execute this instruction; service next.
                    self.nmi_delay = false;
                } else {
                    self.nmi_pending = false;
                    self.interrupt(if (self.regs.e) 0xFFFA else 0xFFEA);
                    return;
                }
            }
            if (self.irq_line and (self.regs.p & Flags.i) == 0) {
                self.interrupt(if (self.regs.e) 0xFFFE else 0xFFEE);
                return;
            }

            if (dbg_clock_pc != 0 and !dbg_clock_fired and
                (self.regs.pbr & 0x7F) == (dbg_clock_pc >> 16) and
                self.regs.pc == @as(u16, @truncate(dbg_clock_pc)) and
                @hasField(BusT, "clock"))
            {
                dbg_clock_fired = true;
                std.debug.print("[clk] pc={x:0>2}:{x:0>4} clock={}\n", .{ self.regs.pbr, self.regs.pc, self.bus.clock });
            }
            if (dbg_trace_to != 0 and @hasField(BusT, "clock")) {
                const clk = self.bus.clock;
                if (clk >= dbg_trace_from and clk < dbg_trace_to)
                    std.debug.print("[tr] {x:0>2}:{x:0>4} a={x:0>4} x={x:0>4} y={x:0>4} s={x:0>4} d={x:0>4} db={x:0>2} p={x:0>2} clk={}\n", .{ self.regs.pbr, self.regs.pc, self.regs.c, self.regs.x, self.regs.y, self.regs.s, self.regs.d, self.regs.dbr, self.regs.p, clk });
            }
            if (dbg_scpu_set) |m| if (@hasField(BusT, "clock") and dbg_upper_mapped and self.regs.pc >= 0x8000 and (self.regs.pbr & 0x7F) < 0x40) {
                m[(@as(usize, self.regs.pbr & 0x3F) << 15) | (self.regs.pc & 0x7FFF)] = 1;
            };
            if (dbg_stale_ring and !@hasField(BusT, "clock")) {
                dbg_ring[dbg_ring_n % dbg_ring.len] = .{ .pbr = self.regs.pbr, .pc = self.regs.pc, .c = self.regs.c, .x = self.regs.x, .y = self.regs.y, .d = self.regs.d, .dbr = self.regs.dbr, .p = self.regs.p };
                dbg_ring_n += 1;
            }
            // SA-1-side trace: fires once the S-CPU-side watch has armed.
            if (dbg_trace_sa1 != 0 and !@hasField(BusT, "clock") and dbg_watch_armed and dbg_trace_sa1_n < dbg_trace_sa1) {
                dbg_trace_sa1_n += 1;
                // The SA-1's own clock, in master cycles: what the catch-up has
                // handed it minus what it has not yet spent.
                const sclk: u64 = if (@hasField(BusT, "last_sync") and @hasField(BusT, "budget")) self.bus.last_sync -% @as(u64, @intCast(@max(self.bus.budget, 0))) else 0;
                std.debug.print("[trs] {x:0>2}:{x:0>4} a={x:0>4} x={x:0>4} y={x:0>4} d={x:0>4} db={x:0>2} p={x:0>2} clk={}\n", .{ self.regs.pbr, self.regs.pc, self.regs.c, self.regs.x, self.regs.y, self.regs.d, self.regs.dbr, self.regs.p, sclk });
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
            self.regs.pc = self.readVector16(vector);
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
        /// See `dbg_stale`. Off unless armed, and deliberately not inlined
        /// into the hot path's fast case.
        fn noteStale(self: *Self, addr: u24, comptime kind: u8) void {
            const bank: u8 = @intCast(addr >> 16);
            const a16: u16 = @truncate(addr);
            const abandoned = bank == 0x7E or bank == 0x7F or
                ((bank & 0x7F) < 0x40 and a16 < 0x2000);
            if (!abandoned) return;
            if (@hasField(BusT, "clock") and self.bus.clock < dbg_stale_from) return;
            const key: u32 = @as(u32, self.regs.pbr) << 16 | self.regs.pc;
            for (dbg_stale_seen[0..dbg_stale_n]) |k| if (k == key) return;
            if (dbg_stale_n == dbg_stale_seen.len or dbg_stale_n == dbg_stale) return;
            dbg_stale_seen[dbg_stale_n] = key;
            dbg_stale_n += 1;
            const clk: u64 = if (@hasField(BusT, "clock")) self.bus.clock else 0;
            std.debug.print("[stale] {c} pc={x:0>2}:{x:0>4} addr={x:0>6} d={x:0>4} db={x:0>2} x={x:0>4} y={x:0>4} clk={d}\n", .{ kind, self.regs.pbr, self.regs.pc, addr, self.regs.d, self.regs.dbr, self.regs.x, self.regs.y, clk });
            if (dbg_stale_ring and !@hasField(BusT, "clock") and !dbg_ring_dumped) {
                dbg_ring_dumped = true;
                const n = @min(dbg_ring_n, dbg_ring.len);
                var ri: usize = dbg_ring_n -| n;
                while (ri < dbg_ring_n) : (ri += 1) {
                    const e = dbg_ring[ri % dbg_ring.len];
                    std.debug.print("[ring] {x:0>2}:{x:0>4} a={x:0>4} x={x:0>4} y={x:0>4} d={x:0>4} db={x:0>2} p={x:0>2}\n", .{ e.pbr, e.pc, e.c, e.x, e.y, e.d, e.dbr, e.p });
                }
            }
        }

        pub inline fn read8(self: *Self, addr: u24) u8 {
            if (dbg_stale != 0) self.noteStale(addr, 'r');
            if (@hasField(BusT, "last_data_read")) self.bus.last_data_read = addr;
            if (@hasDecl(BusT, "noteTickRead")) self.bus.noteTickRead(addr);
            return self.bus.read8(addr);
        }

        /// A *data* write. Stack pushes deliberately do not come through here
        /// (see `push8`), so `last_data_write` records only writes that change
        /// the machine's state, never call/return bookkeeping.
        fn noteDmaBank(self: *Self, addr: u24, value: u8) void {
            const a16: u16 = @truncate(addr);
            if (a16 < 0x4300 or a16 > 0x437F or (a16 & 0xF != 4 and a16 & 0xF != 7)) return;
            // Keyed on the VALUE too: a site that hands over $40 on one pass
            // and $7F on another is exactly the bug being hunted, and a
            // PC-only key would report only whichever came first.
            const key: u32 = @as(u32, self.regs.pbr) << 24 | @as(u32, self.regs.pc) << 8 | value;
            for (dbg_dmabank_seen[0..dbg_dmabank_n]) |k| if (k == key) return;
            if (dbg_dmabank_n == dbg_dmabank_seen.len or dbg_dmabank_n == dbg_dmabank) return;
            dbg_dmabank_seen[dbg_dmabank_n] = key;
            dbg_dmabank_n += 1;
            const dead = value == 0x7E or value == 0x7F;
            std.debug.print("[dmabank] pc={x:0>2}:{x:0>4} ch{d} bank<={x:0>2} x={x:0>4} y={x:0>4} d={x:0>4} db={x:0>2}{s}\n", .{
                self.regs.pbr,                       self.regs.pc, (a16 >> 4) & 7, value, self.regs.x, self.regs.y, self.regs.d, self.regs.dbr,
                if (dead) "  <-- ABANDONED" else "",
            });
        }

        /// The --watch write hook, shared by data writes AND stack
        /// pushes (pushes bypass the data wrapper by design — they must
        /// not pollute last_data_write — but the WATCH must see them:
        /// a corrupted pushed byte was invisible for a whole campaign).
        fn dbgWatchWrite(self: *Self, addr: u24, value: u8) void {
            if (dbg_watch_lo != 0) {
                if (@hasField(BusT, "clock") and self.bus.clock >= dbg_watch_from) dbg_watch_armed = true;
                const bank: u8 = @intCast(addr >> 16);
                const a16: u16 = @truncate(addr);
                // Normalized low-WRAM offset across every addressing home:
                // banks $7E/$40 directly, the system-bank mirror below
                // $2000, and the relocated window $6000-$7FFF.
                const off: ?u16 = if (bank == 0x7E or bank == 0x40)
                    a16
                else if ((bank & 0x7F) < 0x40 and a16 < 0x2000)
                    a16
                else if ((bank & 0x7F) < 0x40 and a16 >= 0x6000 and a16 < 0x8000)
                    a16 - 0x6000
                        // MMIO passes through as itself: a --watch range above
                        // $2000 names PPU/DMA registers (the VRAM address, a
                        // DMA channel), which no WRAM home could alias.
                else if ((bank & 0x7F) < 0x40 and a16 >= 0x2100 and a16 < 0x4400)
                    a16
                else
                    null;
                if (off) |o| if (o >= dbg_watch_lo and o <= dbg_watch_hi and dbg_watch_n < 4096 and
                    value >= dbg_watch_val_min)
                {
                    const has_clk = @hasField(BusT, "clock");
                    const clk: u64 = if (has_clk) self.bus.clock else 0;
                    if (has_clk and clk >= dbg_watch_from) dbg_watch_armed = true;
                    if ((has_clk and clk >= dbg_watch_from) or (!has_clk and dbg_watch_armed)) {
                        dbg_watch_n += 1;
                        std.debug.print("[ww{s}] pc={x:0>2}:{x:0>4} {x:0>6} <= {x:0>2} clk={}\n", .{ if (has_clk) "" else "-sa1", self.regs.pbr, self.regs.pc, addr, value, clk });
                    }
                };
            }
        }

        pub inline fn write8(self: *Self, addr: u24, value: u8) void {
            if (dbg_stale != 0) self.noteStale(addr, 'w');
            if (dbg_dmabank != 0) self.noteDmaBank(addr, value);
            if (dbg_watch_lo != 0) self.dbgWatchWrite(addr, value);
            if (@hasField(BusT, "last_data_write")) self.bus.last_data_write = addr;
            if (@hasDecl(BusT, "noteTickWrite")) self.bus.noteTickWrite(addr);
            self.bus.write8(addr, value);
        }

        /// The two bytes of a reset/NMI/IRQ/BRK *vector pull*, as opposed to a
        /// data read that happens to land on the vector table. A bus that
        /// overlays registers onto the vector slots (the SA-1 serves its own
        /// CRV/CNV/CIV there) must distinguish the two: hardware substitutes
        /// only during the pull, and SA-1 bootstraps read the ROM's original
        /// vectors as plain data to re-publish them to the other processor.
        /// Buses without the hook are unaffected — the pull is a normal read.
        fn readVector16(self: *Self, addr: u24) u16 {
            if (!@hasDecl(BusT, "vectorRead8")) return self.read16(addr);
            const lo: u16 = self.bus.vectorRead8(addr);
            const hi: u16 = self.bus.vectorRead8(addr +% 1);
            return lo | hi << 8;
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
            if (dbg_watch_lo != 0) self.dbgWatchWrite(self.regs.s, value);
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

test "an NMI asserted while running is serviced after exactly one instruction" {
    // Hardware samples interrupts in an instruction's second-to-last cycle:
    // an edge at an instruction boundary lets one more instruction complete.
    // The line scheduler always asserts vblank at a boundary, so without this
    // grace the NMI handler's $4210 ack deterministically beats any main-loop
    // RDNMI edge-wait — SFA2 boots into a permanent black screen (issue #88).
    var bus: FlatBus = .{};
    bus.mem[0xFFFC] = 0x00;
    bus.mem[0xFFFD] = 0x80; // reset -> $8000
    bus.mem[0xFFFA] = 0x00;
    bus.mem[0xFFFB] = 0x90; // emulation NMI vector -> $9000
    bus.mem[0x8000] = 0xEA; // NOP
    bus.mem[0x8001] = 0xEA; // NOP
    var cpu = Cpu(FlatBus).init(&bus);
    cpu.reset();

    cpu.setNmi();
    cpu.step(); // the grace instruction: the first NOP runs...
    try std.testing.expectEqual(@as(u16, 0x8001), cpu.regs.pc);
    cpu.step(); // ...and only then the service sequence
    try std.testing.expectEqual(@as(u16, 0x9000), cpu.regs.pc);
    try std.testing.expect(!cpu.nmi_pending);
}

test "an NMI that wakes WAI is serviced with no grace instruction" {
    // WAI exists to remove the sampling latency: the woken CPU services the
    // interrupt immediately rather than executing the following instruction.
    var bus: FlatBus = .{};
    bus.mem[0xFFFC] = 0x00;
    bus.mem[0xFFFD] = 0x80;
    bus.mem[0xFFFA] = 0x00;
    bus.mem[0xFFFB] = 0x90;
    bus.mem[0x8000] = 0xCB; // WAI
    bus.mem[0x8001] = 0xEA; // NOP (must NOT run before the handler)
    var cpu = Cpu(FlatBus).init(&bus);
    cpu.reset();

    cpu.step(); // WAI
    try std.testing.expectEqual(ExecState.waiting, cpu.state);
    cpu.setNmi();
    cpu.step(); // straight into the service sequence
    try std.testing.expectEqual(@as(u16, 0x9000), cpu.regs.pc);
}
