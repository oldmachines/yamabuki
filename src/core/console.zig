//! Console: the object that wires the CPU, bus, PPU, and DMA into a running
//! system and drives them a frame at a time.
//!
//! `Console(cfg)` is instantiated per accuracy level (fast now; the accurate
//! dot-renderer path is M8). Everything is a plain value owned by one struct so
//! there is no per-frame allocation. **The struct is self-referential** — the
//! bus page table holds pointers into `self.cart`/`self.bus.wram`, and the CPU
//! holds `&self.bus` — so a Console must be heap-allocated and never moved after
//! `init`.
//!
//! The scheduler is deliberately flat: the CPU drives, and every component's
//! time is the bus master clock (`bus.clock`). Each scanline the CPU runs an
//! event-bounded budget of `cycles_per_line` master cycles; at vblank the NMI
//! flag is raised (and delivered if enabled), and the H/V-IRQ timer is compared
//! per line. In fast mode the PPU renders one whole scanline at line end.

const std = @import("std");
const timing = @import("timing.zig");
const serialize = @import("serialize.zig");
const Bus = @import("memory/bus.zig").Bus;
const cart_mod = @import("cart/cartridge.zig");
const Cartridge = cart_mod.Cartridge;
const Cpu = @import("cpu/wdc65816.zig").Cpu;
const CpuFlags = @import("cpu/wdc65816.zig").Flags;
const Dma = @import("memory/dma.zig").Dma;
const profile = @import("profile.zig");
const usage_map = @import("usage_map.zig");

/// Save-state container magic ("YMBK") and format version. The version bumps
/// whenever the serialized field layout changes (there is no migration —
/// states are tied to the core revision that wrote them, standard for
/// in-development emulators).
pub const state_magic: [4]u8 = .{ 'Y', 'M', 'B', 'K' };
/// Version 8 appends the cartridge RAM (SRAM/BW-RAM, `cartridge.max_sram`
/// bytes) after the serialized payload. It was never in the payload —
/// harmless while cart RAM meant battery saves, fatal for SA-1
/// conversions whose whole game state lives in BW-RAM: every state load
/// or rewind press wiped the game. Version-7 states still load (their
/// cart RAM is simply not restored — it was never saved).
// v7: the header's spare bytes carry a structural fingerprint of the layout.
// Version 10 grows the cart-RAM TAIL 128 KiB -> 256 KiB: SRAM-cart window
// conversions keep the game's save RAM in a second BW-RAM bank
// (cart.sram_hi) above the relocated WRAM image. The serialized PAYLOAD is
// untouched — sram_hi is a separate, serialize-skipped array precisely so
// old states and every movie anchor keep loading byte-for-byte.
pub const state_version: u32 = 10;
const state_version_128k_cart_ram: u32 = 9;
const state_version_no_rom_crc: u32 = 8;
const state_version_no_cart_ram: u32 = 7;
/// Cart-RAM section length for a given on-disk state version.
fn stateCartRamLen(ver: u32) usize {
    return switch (ver) {
        state_version_no_cart_ram => 0,
        state_version_no_rom_crc, state_version_128k_cart_ram => cart_mod.max_sram,
        else => cart_mod.max_sram + cart_mod.max_sram_hi,
    };
}
pub const state_header_size: usize = 16;

pub const StateError = error{ BadMagic, UnsupportedVersion, WrongSize, Corrupt, WrongRom };

/// DIAGNOSTIC (set by the headless `--movie-ignore-crc`): accept a state
/// whose stored ROM crc32 differs from the loaded image. The state
/// FINGERPRINT check still runs, so the field tree must match byte-for-byte
/// — this only waives the "same image" identity, for replaying a recording
/// made on a previous conversion against a freshly regenerated one whose
/// memory map is unchanged.
pub var dbg_ignore_state_rom_crc: bool = false;

pub const Accuracy = enum { fast, accurate };

pub const CoreConfig = struct {
    accuracy: Accuracy = .fast,
    /// Compile in the frame-budget profiler (M12's `--sa1-report`). A separate
    /// instantiation rather than a runtime flag, so the shipped core carries no
    /// branch for it at all — the same trick as `accuracy`.
    profile: bool = false,
};

pub fn Console(comptime cfg: CoreConfig) type {
    return struct {
        const Self = @This();
        pub const config = cfg;

        // The cart value is owned here so the whole system is one allocation;
        // the bus/cpu hold pointers into this struct and must not be moved.
        // `steps` and `prof` are diagnostics, not machine state.
        pub const serialize_skip = .{ "steps", "prof", "usage", "skip_render", "polled_latch", "polled_consumed", "lap_latch", "prev_load_end", "prev_load_w", "x_src", "x_w", "pushed_src", "dbr_src", "dma_a1t_src", "prev_load_hi_src", "pushed_hi_src", "plb_pc", "pei_stage", "pei_dp", "a_lo_src", "a_hi_src" };

        cart: Cartridge,
        bus: Bus,
        cpu: Cpu(Bus),

        /// Zero-sized (and every use of it compiled away) unless `cfg.profile`.
        prof: if (cfg.profile) profile.Profiler else void,
        /// Stage-S1 coverage: the bsnes-plus-format usage map the frontend
        /// attaches when exporting (`--usage-map`); null otherwise. A pointer
        /// on purpose — the 16 MiB map lives on the frontend's heap, never
        /// inside the console. Zero-sized unless `cfg.profile`.
        usage: if (cfg.profile) ?*const usage_map.UsageMap else void,
        /// Pointer-bank provenance scratch (see `usage_map.PtrBankEvidence`):
        /// the ROM address of the previous step's plain A-load source (its
        /// read's last byte, or its immediate's last operand byte) and that
        /// load's width — what a store on THIS step is presumed to be
        /// storing. Zero-sized unless `cfg.profile`.
        prev_load_end: if (cfg.profile) u32 else void,
        prev_load_w: if (cfg.profile) u8 else void,
        /// ROM source of the CURRENT X register value (last byte of the
        /// load that set it), or `none` once anything else touched X.
        x_src: if (cfg.profile) u32 else void,
        x_w: if (cfg.profile) u8 else void,
        /// Per-DMA-channel pending A-bus ADDRESS source: the ROM address
        /// of the 16-bit word most recently staged into $43x2 whose VALUE
        /// named the moved low 8 KiB (< $2000), waiting for the channel's
        /// bank write to say which bus it reads. A system bank ($00-$3F —
        /// the WRAM mirror the window moved) promotes it; $7E/$7F drops
        /// it (the bank-byte family re-banks those to $40, where the
        /// image's own layout already answers); anything else drops it.
        dma_a1t_src: if (cfg.profile) [8]u32 else void,
        /// Second push slot: PEI pushes a dp WORD (high byte below the
        /// low), so the second PLB of a `PEI ($dp)/PLB/PLB` pin pulls the
        /// HIGH byte — the bank, staged in memory, never in A.
        pushed_hi_src: if (cfg.profile) u32 else void,
        /// Byte-sources of A's two halves after a 16-bit WRAM load. They
        /// survive exactly one XBA — which swaps them — so the sound
        /// dispatch's `LDA table,Y / XBA / PHA / PLB / PLB` hands the
        /// second PLB the TABLE byte's address and the mirror-bank value
        /// proves like any other (measured: the handler bank $A6 rode
        /// this shape into PBR, fetched MB2 code, and BRK'd into the
        /// crash trap).
        a_lo_src: if (cfg.profile) u32 else void,
        a_hi_src: if (cfg.profile) u32 else void,
        /// The last PLB's own pc — where a misfit-bank pin would be
        /// patched with a translate-in thunk.
        plb_pc: if (cfg.profile) u32 else void,
        /// PEI/PLB/PLB pair tracking that does not depend on attribution:
        /// 1 after PEI, 2 after its first PLB, 0 otherwise. The first
        /// pull's DBR is the pushed word's LOW byte — never a pin.
        pei_stage: if (cfg.profile) u8 else void,
        pei_dp: if (cfg.profile) u8 else void,
        /// When the previous step was a 16-bit A-load out of TRACKED WRAM:
        /// the staged source (`PtrBankEvidence.src`) of the load's HIGH
        /// byte, else `none`. A DMA queue drain stores that word straight
        /// into $43x3, where the high byte is the A-bus bank — the one
        /// byte whose provenance matters and the one the byte-wide chains
        /// cannot see.
        prev_load_hi_src: if (cfg.profile) u32 else void,
        /// ROM source of the byte most recently PUSHED by PHA, when that
        /// push immediately followed a one-byte A-load, else `none`. The
        /// window is deliberately one instruction wide: anything else
        /// touching the stack in between makes the pairing a guess, and a
        /// wrong bank-byte rewrite corrupts silently.
        pushed_src: if (cfg.profile) u32 else void,
        /// ROM source of the byte PLB last pulled into DBR. A data access
        /// that lands in $7E/$7F under this DBR proves that byte is a bank
        /// byte naming WRAM — the `LDA #$7E / PHA / PLB` idiom, which the
        /// pointer-cell tracking cannot see because the bank never passes
        /// through a pointer in memory.
        dbr_src: if (cfg.profile) u32 else void,

        region: timing.Region,
        /// Current scanline within the frame (0-based).
        scanline: u32,
        /// bus.clock at the start of the current scanline.
        line_start: u64,
        /// Completed-frame counter.
        frame: u64,
        /// Skip the fast core's per-scanline pixel rendering. Nothing the
        /// game can observe lives in the framebuffer, so a run that never
        /// looks at frames — a coverage harvest — can leave it unpainted and
        /// keep every register, DMA, timing and audio step exactly as it was.
        /// Run configuration, not machine state: listed in `serialize_skip`,
        /// or it would shift the save-state layout by a byte and every
        /// anchored recording would load a machine one byte off.
        skip_render: bool,
        /// The game read the controller since a frontend last took this
        /// (`takeInputPolled`). Latched here because the profiler clears the
        /// bus's own flag at frame end; a per-poll input feed advances on it.
        /// Diagnostic, not machine state: in `serialize_skip`.
        polled_latch: bool,
        lap_latch: bool,
        /// A poll the frontend already took (`takeInputPolled`) since the
        /// profiler's last frame boundary — the boundary sits at vblank start,
        /// the game's own poll comes after it, and a per-poll feed takes the
        /// flag between frames; without this the profiler saw every frame as
        /// dropped. Diagnostic, in `serialize_skip`.
        polled_consumed: bool,
        /// CPU instructions/interrupts retired since reset. A deterministic
        /// work proxy for perf-regression baselines (paired with bus.clock).
        steps: u64,

        /// Initialize in place from an already-loaded cartridge. `self` must be
        /// at its final (heap) address before calling; it is pinned afterward.
        pub fn init(self: *Self, cart: Cartridge) void {
            self.cart = cart;
            self.bus.init(&self.cart);
            self.bus.beam_enabled = cfg.accuracy == .accurate;
            self.cpu = Cpu(Bus).init(&self.bus);
            self.region = timing.regionFromHeaderByte(self.cart.header.region);
            self.bus.ppu.pal = self.region == .pal;
            self.skip_render = false;
            self.polled_latch = false;
            self.lap_latch = false;
            self.polled_consumed = false;
            self.reset();
        }

        /// Explicit region override (frontend `--region ntsc|pal`), replacing
        /// the header-detected default `init` set. Must be called before the
        /// first `runFrame`.
        pub fn setRegion(self: *Self, r: timing.Region) void {
            self.region = r;
            self.bus.ppu.pal = r == .pal;
        }

        /// Power-on / reset: reload CPU vectors and restart the frame timeline.
        pub fn reset(self: *Self) void {
            self.cpu.reset();
            self.bus.cpuio = .init;
            self.scanline = 0;
            self.line_start = self.bus.clock;
            self.frame = 0;
            self.steps = 0;
            if (cfg.profile) {
                self.prof = .init;
                self.usage = null;
                self.prev_load_end = usage_map.PtrBankEvidence.none;
                self.pushed_src = usage_map.PtrBankEvidence.none;
                self.dbr_src = usage_map.PtrBankEvidence.none;
                self.prev_load_w = 0;
                self.x_src = usage_map.PtrBankEvidence.none;
                self.x_w = 0;
                self.dma_a1t_src = @splat(usage_map.PtrBankEvidence.none);
                self.prev_load_hi_src = usage_map.PtrBankEvidence.none;
                self.pushed_hi_src = usage_map.PtrBankEvidence.none;
                self.a_lo_src = usage_map.PtrBankEvidence.none;
                self.a_hi_src = usage_map.PtrBankEvidence.none;
                self.plb_pc = usage_map.PtrBankEvidence.none;
                self.pei_stage = 0;
                self.pei_dp = 0;
            }
        }

        /// Re-wire the internal self-pointers after deserialization. The ROM
        /// image itself must be re-supplied by the frontend (it is not saved).
        pub fn postLoad(self: *Self) void {
            self.bus.cart = &self.cart;
            self.cpu.bus = &self.bus;
            self.bus.postLoad();
        }

        pub fn linesPerFrame(self: *const Self) u32 {
            return switch (self.region) {
                .ntsc => timing.ntsc_lines_per_frame,
                .pal => timing.pal_lines_per_frame,
            };
        }

        /// First scanline of vertical blank (one past the last visible line).
        /// Overscan (SETINI bit2) extends the visible frame to 239 lines.
        pub fn vblankLine(self: *const Self) u32 {
            return if (self.bus.ppu.overscan()) timing.vblank_line_239 else timing.vblank_line_224;
        }

        /// Run the emulation for exactly one video frame.
        pub fn runFrame(self: *Self) void {
            const lines = self.linesPerFrame();
            while (self.scanline < lines) : (self.scanline += 1) {
                self.stepScanline();
            }
            self.scanline = 0;
            self.frame +%= 1;
            self.polled_latch = self.polled_latch or self.bus.input_polled;
            self.lap_latch = self.lap_latch or self.bus.lap_polled;
        }

        /// Whether the game has read the controller since the last `take`.
        pub fn inputPolled(self: *const Self) bool {
            return self.polled_latch or self.bus.input_polled;
        }

        /// Read-and-clear form, for a feed that advances one entry per poll.
        pub fn takeInputPolled(self: *Self) bool {
            const p = self.inputPolled();
            if (p) self.polled_consumed = true;
            self.polled_latch = false;
            self.bus.input_polled = false;
            return p;
        }

        /// Whether the game's lap counter (`bus.lap_cell`) was written since
        /// the last `takeLapPassed` — the lap tick of a per-lap take.
        pub fn lapPassed(self: *const Self) bool {
            return self.lap_latch or self.bus.lap_polled;
        }

        pub fn takeLapPassed(self: *Self) bool {
            const p = self.lapPassed();
            self.lap_latch = false;
            self.bus.lap_polled = false;
            return p;
        }

        /// Stage up to 16 per-lap entries for the coming frame's lap edges;
        /// returns how many the previous staging consumed.
        pub fn lapFeedStage(self: *Self, entries: []const [2]u16) u8 {
            const consumed = self.bus.lap_feed_i;
            const n: u8 = @intCast(@min(entries.len, self.bus.lap_feed.len));
            @memcpy(self.bus.lap_feed[0..n], entries[0..n]);
            self.bus.lap_feed_n = n;
            self.bus.lap_feed_i = 0;
            return consumed;
        }

        /// The pads recorded at the frame's lap edges; cleared.
        pub fn lapRecTake(self: *Self, buf: *[16][2]u16) u8 {
            const n = self.bus.lap_rec_n;
            @memcpy(buf[0..n], self.bus.lap_rec[0..n]);
            self.bus.lap_rec_n = 0;
            return n;
        }

        fn stepScanline(self: *Self) void {
            const line = self.scanline;
            const io = &self.bus.cpuio;

            // Beam position for the $2137 H/V counter latch (both cores).
            self.bus.hv_line = line;
            self.bus.hv_line_start = self.line_start;

            if (line == 0) {
                // New frame: leave vblank, clear the vblank NMI flag.
                io.in_vblank = false;
                io.nmi_flag = false;
                // STAT78 ($213F) bit7: hardware toggles the field flag once per
                // frame (a frame-parity signal, not just an interlace one). A
                // script waiting on it to change hangs forever if it never does.
                self.bus.ppu.field = !self.bus.ppu.field;
            }
            if (line == self.vblankLine()) {
                // The game's deadline: its main loop had until now to come
                // around. Close the profiler's frame here rather than at
                // scanline 0, so the window matches the NMI-to-NMI period the
                // game's logic actually runs in.
                if (cfg.profile) {
                    self.polled_latch = self.polled_latch or self.bus.input_polled;
                    self.prof.endFrame(self.frame, self.bus.input_polled or self.polled_consumed);
                    self.polled_consumed = false;
                    self.bus.input_polled = false;
                }
                // Entering vblank: latch the NMI flag and deliver if enabled.
                io.in_vblank = true;
                io.nmi_flag = true;
                if (io.nmiEnabled()) self.cpu.setNmi();
                // Auto-joypad read (instant in the fast core; the busy bit
                // in HVBJOY therefore never reads 1).
                if (io.nmitimen & 0x01 != 0) self.bus.joy.autoRead();
            }

            // Evaluate the H/V-IRQ timer for this scanline. The fast core
            // latches it at line granularity; the accurate core fires it at
            // the programmed dot inside runLineCpuAccurate.
            if (cfg.accuracy == .fast and self.irqMatchesLine(line)) {
                io.irq_flag = true;
            }

            // HDMA: reload the tables at the top of the frame, then inject one
            // transfer per visible line before the line is drawn so per-line
            // register effects (scroll, gradients) apply to this scanline.
            if (line == 0) self.bus.dma.hdmaInit(&self.bus);
            if (line < self.vblankLine()) self.bus.dma.hdmaRunLine(&self.bus);

            if (cfg.accuracy == .fast) self.runLineCpu() else self.runLineCpuAccurate(line);

            // Keep the APU within one scanline of the main CPU (port accesses
            // catch it up mid-line as needed). The Super FX follows the same
            // scheme: MMIO accesses catch it up mid-line, the line end here.
            self.bus.apu.catchUp(self.bus.clock);
            // Catching a coprocessor up can raise (or time out) its IRQ, so
            // re-derive the aggregated line the CPU loop reads.
            if (self.bus.cart.chip == .superfx) {
                self.bus.gsu.catchUp(self.bus.clock);
                self.bus.syncCoprocIrq();
            }
            if (self.bus.cart.chip == .sa1) {
                self.bus.sa1.catchUp(self.bus.clock);
                self.bus.syncCoprocIrq();
            }

            // Fast mode renders the whole visible scanline at line end; the
            // accurate core renders whatever the beam didn't already emit.
            if (line < self.vblankLine()) {
                if (cfg.accuracy == .fast) {
                    if (!self.skip_render) self.renderScanline(line);
                } else self.bus.ppu.finishScanline(line);
            }

            // Between lines the beam is in blanking: HDMA's per-line $21xx
            // writes (which run before the next line's CPU slice) must apply
            // for the *coming* line, not race the finished one.
            if (cfg.accuracy == .accurate) self.bus.beam_line = std.math.maxInt(u32);
        }

        /// Does the programmed IRQ timer fire on this scanline?
        fn irqMatchesLine(self: *const Self, line: u32) bool {
            const io = &self.bus.cpuio;
            return switch (io.irqMode()) {
                0 => false, // IRQ disabled
                1 => true, // H-IRQ: every scanline (at htime dot)
                2, 3 => line == io.vtime, // V- or H+V-IRQ: only on vtime's line
            };
        }

        fn runLineCpu(self: *Self) void {
            const line_end = self.line_start +% timing.cycles_per_line;
            const io = &self.bus.cpuio;
            while (self.bus.clock < line_end) {
                // Keep the CPU's level-sensitive IRQ input in sync with the
                // timer flag: reading $4211 (TIMEUP) clears irq_flag, which must
                // deassert the line before the handler's RTI re-checks it. The
                // coprocessor IRQs (GSU STOP, SA-1 message/timer/CC-DMA) OR in
                // through the bus's one aggregated line — the loop no longer
                // loads two large chip structs that are dead weight on a
                // plain cart.
                const irq = io.irq_flag or self.bus.coproc_irq_line;
                if (irq != self.cpu.irq_line) self.cpu.setIrqLine(irq);
                self.stepCpu();
                self.steps +%= 1;
            }
            self.line_start = line_end;
        }

        /// One CPU instruction, with the frame-budget profiler's accounting
        /// folded in. When `cfg.profile` is false the condition is comptime-known
        /// and the whole thing collapses to `self.cpu.step()`.
        inline fn stepCpu(self: *Self) void {
            if (!cfg.profile) {
                self.cpu.step();
                return;
            }
            const pc = (@as(u24, self.cpu.regs.pbr) << 16) | self.cpu.regs.pc;
            const t0 = self.bus.clock;
            const waiting = self.cpu.state != .running;
            // Classify the control transfer this step will make before it
            // runs. The interrupt test mirrors `Cpu.step`'s own dispatch; the
            // opcode peek is side-effect-free (no clock, no MDR, no MMIO), so
            // emulation stays bit-identical. All of it is the profiler's
            // business — the CPU core carries no instrumentation.
            const sp_before = self.cpu.regs.s;
            var kind: profile.Event.Kind = .none;
            // The opcode about to execute — null when this step is really an
            // interrupt dispatch (or a WAI), so the usage map marks nothing.
            var op: ?u8 = null;
            if (!waiting) {
                if (self.cpu.nmi_pending) {
                    kind = .nmi;
                } else if (self.cpu.irq_line and (self.cpu.regs.p & CpuFlags.i) == 0) {
                    kind = .irq;
                } else if (self.bus.peekCode8(pc)) |o| {
                    op = o;
                    kind = switch (o) {
                        0x20, 0x22, 0xFC => .call, // JSR abs / JSL / JSR (abs,X)
                        0x60, 0x6B, 0x40 => .ret, // RTS / RTL / RTI
                        0x00, 0x02 => .irq, // BRK / COP enter a handler too
                        else => .none,
                    };
                }
            }
            // The widths the instruction will decode with, for the usage
            // map's M/X record — the same derivation the CPU's own dispatch
            // makes (wdc65816.step).
            const m8 = self.cpu.regs.e or (self.cpu.regs.p & CpuFlags.m) != 0;
            const x8 = self.cpu.regs.e or (self.cpu.regs.p & CpuFlags.x) != 0;
            self.bus.last_data_read = Bus.no_data_access;
            self.bus.last_data_write = Bus.no_data_access;
            self.cpu.step();
            self.prof.step(
                pc,
                self.bus.clock -% t0,
                waiting,
                dataAddr(self.bus.last_data_read),
                dataAddr(self.bus.last_data_write),
                .{
                    .kind = kind,
                    .target = (@as(u24, self.cpu.regs.pbr) << 16) | self.cpu.regs.pc,
                    .sp_before = sp_before,
                    .sp_after = self.cpu.regs.s,
                    .d = self.cpu.regs.d,
                },
            );
            // DMA/HDMA arming, blamed on the routine the store ran under.
            // GDMA state is consumed (and the mask cleared) so a later $420B
            // write of zero cannot re-count the previous trigger; HDMA regs
            // survive arming, so its snapshot reads live.
            if (dataAddr(self.bus.last_data_write)) |w| {
                const a16: u16 = @truncate(w);
                if (((w >> 16) & 0x7F) <= 0x3F) {
                    var arms_buf: [8]Dma.ArmInfo = undefined;
                    if (a16 == 0x420B and self.bus.dma.last_gdma_mask != 0) {
                        for (self.bus.dma.gdmaArms(&arms_buf)) |a| {
                            self.prof.noteDmaArm(.gdma, a.channel, a.src, a.bytes, a.b_reg, a.a_is_dest, null);
                        }
                        self.bus.dma.last_gdma_mask = 0;
                    } else if (a16 == 0x420C and self.bus.dma.hdmaen != 0) {
                        for (self.bus.dma.hdmaArms(&arms_buf)) |a| {
                            self.prof.noteDmaArm(.hdma, a.channel, a.src, 0, a.b_reg, false, a.indirect_bank);
                            // An indirect HDMA's table carries per-segment
                            // addresses; if any name the moved low 8 KiB the
                            // window conversion relocates them. Record the
                            // table into the SHARED provenance (not the
                            // per-surface profiler) so every profiled surface
                            // contributes — the escape lives on a late one.
                            if (a.indirect_bank != null) {
                                if (self.usage) |u| if (u.ptr_banks) |pb| pb.addHdmaTable(a.src);
                            }
                        }
                    }
                }
            }
            // Stage-S1 coverage, when a map is attached. A recorded access
            // with no decoded width (an interrupt dispatch's vector read, an
            // opcode the table calls access-free) still factually touched
            // its last byte, so at least one byte is marked.
            if (self.usage) |u| {
                // A BRK/COP/STP/WDM execution is a wedge, not evidence: no
                // shippable image runs one, so reaching one means this core
                // walked off the rails — a cover take whose anchor carries
                // another image's machine state resumes at a pc that means
                // nothing here and marks a misaligned death rattle (operand
                // bytes at $847B and $A3C3 read back as covered BRKs and
                // refused good splits). Stop donating from the wedge onward;
                // a game that really uses BRK ships past the refusal scan
                // and fails S4 verification instead, which gates everything.
                if (op) |o| {
                    if (o == 0x00 or o == 0x02 or o == 0xDB or o == 0x42) {
                        self.usage = null;
                        return;
                    }
                    u.noteInstr(pc, o, m8, x8);
                }
                const width: u8 = if (op) |o| @max(1, usage_map.dataWidth(o, m8, x8)) else 1;
                if (dataAddr(self.bus.last_data_read)) |a| {
                    u.noteRead(a, width);
                    if (op != null) u.noteSite(pc, a);
                }
                if (dataAddr(self.bus.last_data_write)) |a| {
                    u.noteWrite(a, width);
                    if (op != null) u.noteSite(pc, a);
                }
                if (u.ptr_banks) |pb| self.trackPtrBanks(pb, pc, op, m8, x8, width, u.conv_window_homes);
            }
        }

        fn dataAddr(v: u32) ?u24 {
            return if (v == Bus.no_data_access) null else @intCast(v);
        }

        /// Pointer-bank provenance (see `usage_map.PtrBankEvidence`): runs
        /// once per profiled step, after the usage map has recorded the
        /// step's accesses.
        fn trackPtrBanks(self: *Self, pb: *usage_map.PtrBankEvidence, pc: u24, op_o: ?u8, m8: bool, x8: bool, width: u8, conv: bool) void {
            const none = usage_map.PtrBankEvidence.none;
            const op = op_o orelse {
                // Interrupt dispatch between the load and the store would
                // clobber A anyway only via the handler's own tracked
                // steps; the dispatch itself proves nothing — drop the
                // pending source.
                self.prev_load_end = none;
                self.prev_load_w = 0;
                return;
            };
            // 1. Every write refreshes the touched low-8K cells' source
            //    attribution: a $7E/$7F byte just stored there is presumed
            //    to be the previous step's load, byte for byte, when the
            //    widths agree; anything else clears the cell.
            if (dataAddr(self.bus.last_data_write)) |a| {
                var i: u8 = 0;
                while (i < width) : (i += 1) {
                    const ad = a -% i;
                    if (usage_map.wramAnyOffset(ad, conv)) |off| {
                        // Through the bus, not `wram.data`: on a cover replay
                        // this byte lives in BW-RAM, and reading the abandoned
                        // WRAM would attribute provenance from a dead copy.
                        const val = self.bus.peek8(ad) orelse continue;
                        const attributed = self.prev_load_end != none and self.prev_load_w == width;
                        pb.src[off] = if ((val == 0x7E or val == 0x7F) and attributed)
                            self.prev_load_end -% i
                        else
                            none;
                        // A 16-bit WRAM-to-WRAM copy has no prev_load_end —
                        // the load staged only per-half sources — so the
                        // copy propagates those instead of dropping the
                        // chain (measured: the room-header parser copies
                        // the tileset pointer $C2:C104 through $07C6-$C8
                        // into dp $47-$49 with exactly this shape, and the
                        // decompressor's PLB found nothing to prove — the
                        // palette source stayed a folded $C2 and the
                        // new-game room faded in black).
                        // Contiguous pairs only: a genuine copied WORD has
                        // hi == lo + 1 by construction; propagating loose
                        // halves let the word families (dma-addr, (dp)
                        // pointers) assemble false pairs and shift a ROM
                        // pointer word that was never a moved-WRAM address
                        // (measured: +18 bytes of collateral rewrites and a
                        // striped room).
                        const pair_ok = width == 2 and
                            self.a_lo_src != none and
                            self.a_hi_src == self.a_lo_src +% 1;
                        const half_src = if (pair_ok)
                            (if (i == 0) self.a_hi_src else self.a_lo_src)
                        else
                            none;
                        pb.src_any[off] = if (attributed)
                            self.prev_load_end -% i
                        else if (half_src != none)
                            half_src
                        else
                            none;
                    }
                }
                // DMA A-bus bank registers ($43x4): a $7E/$7F written there
                // is a bank VALUE naming WRAM for the hardware — same
                // provenance, proven directly.
                const a16: u16 = @truncate(a);
                // Third family: the A-bus ADDRESS. A 16-bit word staged
                // into $43x2 that names the moved low 8 KiB (< $2000)
                // becomes the channel's pending source; the bank write
                // below arbitrates it.
                if (((a >> 16) & 0x7F) <= 0x3F and a16 >= 0x4303 and a16 <= 0x4373 and
                    (a16 & 0xF) == 3)
                {
                    const ch: u3 = @truncate(a16 >> 4);
                    self.dma_a1t_src[ch] = blk: {
                        if (width != 2) break :blk none;
                        if (self.prev_load_end == none or self.prev_load_w != 2) break :blk none;
                        // The register itself is MMIO — off peek8's page
                        // table. The store's value is byte-for-byte the
                        // load's, and the load's source IS peekable.
                        const lo = self.bus.peek8(@intCast(self.prev_load_end -% 1)) orelse break :blk none;
                        const hi = self.bus.peek8(@intCast(self.prev_load_end)) orelse break :blk none;
                        const val = (@as(u16, hi) << 8) | lo;
                        break :blk if (val < 0x2000) self.prev_load_end else none;
                    };
                }
                // 16-bit store to $43x4: the BANK rides the LOW byte and
                // DAS-lo the high — Super Metroid's inline-param DMA
                // launcher (`JSL $80:91A9` + an 8-byte param block in the
                // caller's own bank; `LDA $0006,Y / STA $4304,X`). The
                // write's HIGH byte lands on $43x5, so this window keys on
                // &0xF == 5; the bank's source is the load's LOW byte.
                if (((a >> 16) & 0x7F) <= 0x3F and a16 >= 0x4305 and a16 <= 0x4375 and
                    (a16 & 0xF) == 5 and width == 2 and
                    self.prev_load_end != none and self.prev_load_w == 2)
                {
                    const ch5: u3 = @truncate(a16 >> 4);
                    const lo_src: u32 = self.prev_load_end -% 1;
                    if (self.bus.peek8(@intCast(lo_src))) |lv| {
                        if (lv == 0x7E or lv == 0x7F) {
                            pb.addProven(lo_src);
                            self.dma_a1t_src[ch5] = none;
                        } else if (lv >= 0xC0 and lv <= 0xDF) {
                            pb.addHiProven(lo_src);
                            self.dma_a1t_src[ch5] = none;
                        } else if (lv >= 0xA0 and lv <= 0xBF) {
                            pb.addA0Proven(lo_src);
                            self.dma_a1t_src[ch5] = none;
                        } else if (lv <= 0x3F) {
                            const pending = self.dma_a1t_src[ch5];
                            self.dma_a1t_src[ch5] = none;
                            if (pending != none) pb.addDmaAddrProven(pending);
                        }
                    }
                }
                if (((a >> 16) & 0x7F) <= 0x3F and a16 >= 0x4304 and a16 <= 0x4374 and
                    (a16 & 0xF) == 4 and width == 2 and
                    (self.bus.mdr == 0x7E or self.bus.mdr == 0x7F))
                {
                    // 16-bit store to $43x3: A1T-hi rides the low byte and
                    // the BANK rides the high — Super Metroid's DMA queue
                    // drain (`LDA $0345,X / STA $4313`, 16 KiB of boot
                    // tiles from $7F:5000). The high byte is mdr; its
                    // source is the load's high byte — an immediate/ROM
                    // read directly, a staged WRAM word through the queue
                    // cell it was built into.
                    const ch2: u3 = @truncate(a16 >> 4);
                    self.dma_a1t_src[ch2] = none;
                    if (self.prev_load_end != none and self.prev_load_w == 2)
                        pb.addProven(self.prev_load_end)
                    else if (self.prev_load_hi_src != none)
                        pb.addProven(self.prev_load_hi_src)
                    else
                        pb.noteUnresolved(pc, a16);
                }
                if (((a >> 16) & 0x7F) <= 0x3F and a16 >= 0x4304 and a16 <= 0x4374 and
                    (a16 & 0xF) == 4 and width == 2 and
                    self.bus.mdr >= 0xA0 and self.bus.mdr <= 0xDF)
                {
                    // The MISFIT arm of the same 16-bit $43x3 idiom: the
                    // staged bank is mirror-intent ($A0-$BF reads MB2 under
                    // the shim, $C0-$DF homes $20 lower). Measured: the
                    // escape's door-tile upload `$B0:C400 -> vdest $7000`
                    // stages its word via `STA $4313` ($80:8CAA); the $B0
                    // was never proven, the transfer read the MB2 home
                    // (file $284400) instead of MB1 ($184400), and the
                    // door's second OBJ tile table rendered as confetti.
                    // Proved ONLY when the source byte IS the stored value
                    // (the dual-role lesson: a byte that is addr-half for
                    // another consumer must stay stock).
                    const ch2b: u3 = @truncate(a16 >> 4);
                    self.dma_a1t_src[ch2b] = none;
                    // Candidate source of the bank (high) byte just stored:
                    // a direct ROM load proves itself; a load from a WRAM
                    // QUEUE CELL (the DMA job queue) proves through the
                    // cell's src_any copy-chain, which the 16-bit staging
                    // path leaves in a_hi_src — the strict chain in
                    // prev_load_hi_src is the fallback.
                    const rsrc: u32 = if (self.prev_load_end != none and self.prev_load_w == 2)
                        self.prev_load_end
                    else if (self.a_hi_src != none)
                        self.a_hi_src
                    else if (self.prev_load_hi_src != none)
                        self.prev_load_hi_src
                    else
                        none;
                    if (rsrc != none and (rsrc & 0xFFFF) >= 0x8000 and
                        self.bus.peek8(@intCast(rsrc)) == self.bus.mdr)
                    {
                        if (self.bus.mdr >= 0xC0) pb.addHiProven(rsrc) else pb.addA0Proven(rsrc);
                    } else pb.noteUnresolved(pc, a16);
                }
                if (((a >> 16) & 0x7F) <= 0x3F and a16 >= 0x4304 and a16 <= 0x4374 and
                    (a16 & 0xF) == 4 and width == 1)
                {
                    const ch: u3 = @truncate(a16 >> 4);
                    const pending = self.dma_a1t_src[ch];
                    self.dma_a1t_src[ch] = none;
                    if (self.bus.mdr <= 0x3F and pending != none) pb.addDmaAddrProven(pending);
                    if ((self.bus.mdr >= 0xA0 and self.bus.mdr <= 0xDF) and
                        self.prev_load_end != none and self.prev_load_w == 1 and
                        self.bus.peek8(@intCast(self.prev_load_end)) == self.bus.mdr)
                    {
                        // The misfit-mirror banks prove on the store too —
                        // but only when the source byte IS the stored value.
                        if (self.bus.mdr >= 0xC0) {
                            pb.addHiProven(self.prev_load_end);
                        } else pb.addA0Proven(self.prev_load_end);
                    }
                    if (self.bus.mdr == 0x7E or self.bus.mdr == 0x7F) {
                        // The bank can ride A or X: Super Metroid's palette
                        // uploader is `LDX #$7E / STX $4314` (measured:
                        // 8,372 events from that one site, and the wrong
                        // colours from the first visible frame).
                        const via_x = op == 0x86 or op == 0x8E; // STX dp/abs
                        if (via_x and self.x_src != none and self.x_w == 1)
                            pb.addProven(self.x_src)
                        else if (!via_x and self.prev_load_end != none and self.prev_load_w == 1)
                            pb.addProven(self.prev_load_end)
                        else
                            pb.noteUnresolved(pc, a16);
                    }
                }
            }
            // 2b. A dp,X data access resolving BEYOND the moved low 8 KiB
            //    (X carried a full pointer — MMIO registers, or anything
            //    else the D move would drag +$6000 away from): prove X's
            //    ROM source word so the conversion can pre-subtract the
            //    window offset from it.
            if (usage_map.isDpX(op)) {
                const tgt = dataAddr(self.bus.last_data_write) orelse dataAddr(self.bus.last_data_read);
                if (tgt) |t| {
                    const tb: u8 = @truncate(t >> 16);
                    const a16: u16 = @truncate(t);
                    if (tb == 0x00 and a16 >= 0x2000) {
                        if (self.x_src != none and self.x_w == 2)
                            pb.addIdxProven(self.x_src)
                        else
                            pb.idx_unresolved += 1;
                    }
                }
            }
            // 2. A [dp]/[dp],Y data access that resolved into bank $7E/$7F:
            //    prove the pointer's bank-byte cell's remembered source.
            if (op & 0x0F == 0x07) {
                const tgt = dataAddr(self.bus.last_data_write) orelse dataAddr(self.bus.last_data_read);
                if (tgt) |t| {
                    const tb: u8 = @truncate(t >> 16);
                    if (tb >= 0xC0 and tb <= 0xDF) {
                        const operand = self.bus.peek8(pc +% 1) orelse 0;
                        const slot = self.cpu.regs.d +% operand +% 2;
                        if (slot < 0x2000 and pb.src_any[slot] != none and
                            self.bus.peek8(@intCast(pb.src_any[slot])) == tb)
                        {
                            pb.addHiProven(pb.src_any[slot]);
                        }
                    }
                    if (usage_map.isWramBank(tb, conv)) {
                        const operand = self.bus.peek8(pc +% 1) orelse 0;
                        const slot = self.cpu.regs.d +% operand +% 2;
                        const src: u32 = if (slot < 0x2000) pb.src[slot] else none;
                        if (src != none) pb.addProven(src) else pb.noteUnresolved(pc, slot);
                    }
                }
            }
            // 2e. A (dp)/(dp),Y access whose TARGET is the moved low 8 KiB
            //    through a data-bank mirror: the two-byte pointer carries
            //    no bank, so there is no bank byte to re-bank — the
            //    pointer WORD itself must move +$6000. Prove the word's
            //    staged source when both bytes attribute contiguously
            //    (measured: the NMI OAM high-table walker, `STA ($1C)`
            //    under DB=$8C — four bytes of sprite size bits landing in
            //    the abandoned home while the DMA reads the window).
            if (op & 0x1F == 0x12 or op & 0x1F == 0x11) {
                const tgt = dataAddr(self.bus.last_data_write) orelse dataAddr(self.bus.last_data_read);
                if (tgt) |t| {
                    const tb: u8 = @truncate(t >> 16);
                    const ta: u16 = @truncate(t);
                    if ((tb & 0x7F) <= 0x3F and ta < 0x2000) {
                        const operand = self.bus.peek8(pc +% 1) orelse 0;
                        const slot = self.cpu.regs.d +% operand;
                        if (slot < 0x1FFF) {
                            const lo = pb.src_any[slot];
                            const hi = pb.src_any[slot + 1];
                            if (lo != none and hi == lo +% 1)
                                pb.addDmaAddrProven(hi)
                            else
                                pb.noteUnresolved(pc, slot);
                        }
                    }
                }
            }
            // 2c. DBR carrying $7E/$7F, put there by `LDA #$7E / PHA / PLB`.
            //    The bank never passes through a pointer in memory, so the
            //    cell tracking above cannot see it; what proves the byte is
            //    a data access under this DBR resolving into $7E/$7F. Long
            //    addressing names its own bank and [dp] forms are case 2, so
            //    both are excluded — otherwise an unrelated access would
            //    credit whatever DBR happened to hold.
            if (self.dbr_src != none and op & 0x0F != 0x07 and usage_map.mode(op) != .long and usage_map.mode(op) != .long_x) {
                const tgt = dataAddr(self.bus.last_data_write) orelse dataAddr(self.bus.last_data_read);
                if (tgt) |t| {
                    const tb: u8 = @truncate(t >> 16);
                    if (tb == self.cpu.regs.dbr and tb >= 0xA0 and tb <= 0xDF and
                        self.plb_pc != none)
                    {
                        const ppc = self.plb_pc;
                        const dp_op = self.bus.peek8(@intCast(ppc -% 2)) orelse 0xFF;
                        const shp = ((self.bus.peek8(@intCast(ppc -% 1)) orelse 0) == 0x48 and
                            (self.bus.peek8(@intCast(ppc -% 3)) orelse 0) == 0xA5) or
                            ((self.bus.peek8(@intCast(ppc -% 1)) orelse 0) == 0xAB and
                                (self.bus.peek8(@intCast(ppc -% 3)) orelse 0) == 0xD4);
                        // The `LDA $abs,X / PHA / PLB / PLB` HIGH-byte pin: a
                        // 16-bit table word whose LOW byte is an ADDRESS HALF
                        // and whose high byte is the bank. Value-proving the
                        // chain here credits whichever half the staging ended
                        // on — measured: Super Metroid's door tilesheet
                        // record at $20:E276, whose addr-hi $BA was re-banked
                        // -$80 as if it were a bank, so the Ceres escape's
                        // sprite-tile builder read $B0:3Axx (zeros) and the
                        // beam/door sprites rendered blank. A dual-role table
                        // word can never be value-rewritten; the pin site
                        // gets a translate-in thunk instead.
                        const shp_absx = (self.bus.peek8(@intCast(ppc -% 1)) orelse 0) == 0xAB and
                            (self.bus.peek8(@intCast(ppc -% 2)) orelse 0) == 0x48 and
                            (self.bus.peek8(@intCast(ppc -% 5)) orelse 0) == 0xBD and
                            (std.mem.readInt(u16, &[2]u8{
                                self.bus.peek8(@intCast(ppc -% 4)) orelse 0xFF,
                                self.bus.peek8(@intCast(ppc -% 3)) orelse 0xFF,
                            }, .little)) < 0x2000;
                        if ((shp and dp_op < 0x10) or shp_absx) {
                            pb.addXlSite(ppc);
                        } else if (self.dbr_src != none and
                            self.bus.peek8(@intCast(self.dbr_src)) == tb)
                        {
                            if (tb >= 0xC0) {
                                pb.addHiProven(self.dbr_src);
                            } else pb.addA0Proven(self.dbr_src);
                        }
                    }
                    if (usage_map.isWramBank(tb, conv) and tb == self.cpu.regs.dbr) {
                        pb.addProven(self.dbr_src);
                        // Proven once is enough; keep it for the rest of the
                        // routine so every access under the same DBR does not
                        // re-add the same byte.
                    }
                }
            }
            // 2d. The push/pull chain that feeds the above. PHA right after a
            //    one-byte A-load carries that load's source; PLB moves it into
            //    DBR. Anything else touching the stack or DBR clears the
            //    chain rather than guessing across it.
            sw: switch (op) {
                0x48 => { // PHA
                    if (self.prev_load_w == 1) {
                        self.pushed_src = self.prev_load_end;
                        self.pushed_hi_src = none;
                    } else if (self.a_lo_src != none or self.a_hi_src != none) {
                        // 16-bit push: PLB pulls the LOW half first.
                        self.pushed_src = self.a_lo_src;
                        self.pushed_hi_src = self.a_hi_src;
                    } else {
                        self.pushed_src = none;
                        self.pushed_hi_src = none;
                    }
                },
                0xD4 => { // PEI ($dp): pushes the dp WORD, low byte on top
                    const operand = self.bus.peek8(pc +% 1) orelse 0;
                    self.pei_stage = 1;
                    self.pei_dp = operand;
                    const slot = self.cpu.regs.d +% operand;
                    if (slot < 0x1FFF) {
                        self.pushed_src = pb.src_any[slot];
                        self.pushed_hi_src = pb.src_any[slot + 1];
                    } else {
                        self.pushed_src = none;
                        self.pushed_hi_src = none;
                    }
                },
                0xAB => { // PLB — a second PLB pulls PEI's high byte
                    const transient = self.pei_stage == 1;
                    self.plb_pc = pc;
                    self.dbr_src = if (transient) none else self.pushed_src;
                    self.pushed_src = self.pushed_hi_src;
                    self.pushed_hi_src = none;
                    if (transient) {
                        self.pei_stage = 2;
                        break :sw;
                    }
                    const pei_pin = self.pei_stage == 2;
                    self.pei_stage = 0;
                    // A $C0-$DF pull proves EAGERLY: pinning DBR to the
                    // Super MMC misfit banks has no purpose but reading
                    // them, and waiting for a confirming access loses the
                    // source to interrupt traffic (measured: SM's round-2
                    // music upload pins $D0, spins the handshake for ~1M
                    // clks, and the NMIs' RTIs wiped dbr_src before the
                    // first non-long access).
                    if (self.cpu.regs.dbr >= 0xA0 and self.cpu.regs.dbr <= 0xDF and !transient) {
                        // Tight-dp pins (the music walker) translate: their
                        // table bytes are dual-role. Wider-dp pins (the
                        // decompressor's 3-byte param blocks, single-role)
                        // value-prove instead — their fire rate makes a
                        // thunk cost ~a frame across a load.
                        const shape_lda = (self.bus.peek8(pc -% 1) orelse 0) == 0x48 and
                            (self.bus.peek8(pc -% 3) orelse 0) == 0xA5;
                        const dp_op: u8 = if (pei_pin)
                            self.pei_dp
                        else
                            self.bus.peek8(pc -% 2) orelse 0xFF;
                        // The `LDA $abs,X / PHA / PLB / PLB` HIGH-byte pin
                        // over a low-WRAM table: the 16-bit word is
                        // dual-role (low = an address half, high = the
                        // bank), so NEITHER half may value-prove — the
                        // eager prove here is what re-banked SM's door
                        // tilesheet addr-hi $BA at $20:E276 to $3A and
                        // blanked the Ceres escape's beam/door sprites. The
                        // SECOND pull records a translate site; the FIRST
                        // (the transient low byte in DBR) records nothing.
                        const absx_hi = (self.bus.peek8(pc -% 1) orelse 0) == 0xAB and
                            (self.bus.peek8(pc -% 2) orelse 0) == 0x48 and
                            (self.bus.peek8(pc -% 5) orelse 0) == 0xBD and
                            (@as(u16, self.bus.peek8(pc -% 3) orelse 0xFF) << 8 |
                                (self.bus.peek8(pc -% 4) orelse 0xFF)) < 0x2000;
                        const absx_lo = (self.bus.peek8(pc -% 1) orelse 0) == 0x48 and
                            (self.bus.peek8(pc -% 4) orelse 0) == 0xBD and
                            (@as(u16, self.bus.peek8(pc -% 2) orelse 0xFF) << 8 |
                                (self.bus.peek8(pc -% 3) orelse 0xFF)) < 0x2000;
                        if (absx_lo) {
                            // transient low pull — the next PLB decides
                        } else if ((shape_lda or pei_pin) and dp_op < 0x10 or absx_hi) {
                            pb.addXlSite(pc);
                        } else if (self.dbr_src != none and
                            self.bus.peek8(@intCast(self.dbr_src)) == self.cpu.regs.dbr)
                        {
                            if (self.cpu.regs.dbr >= 0xC0) {
                                pb.addHiProven(self.dbr_src);
                            } else pb.addA0Proven(self.dbr_src);
                        }
                    }
                },
                // Other stack traffic and the bank-setting instructions make
                // the two-slot model a guess: drop it.
                0x08, 0x0B, 0x4B, 0x5A, 0x8B, 0xDA, 0x28, 0x2B, 0x68, 0x7A, 0xFA, 0x20, 0x22, 0xFC, 0x60, 0x6B, 0x40, 0x62, 0xF4 => {
                    self.pushed_src = none;
                    self.pushed_hi_src = none;
                    self.pei_stage = 0;
                    if (op == 0x40) self.dbr_src = none; // RTI restores a bank we did not track
                },
                else => {},
            }
            // 3. Remember THIS step if it was a plain A-load from ROM (or
            //    an immediate — its operand bytes are ROM): the candidate
            //    source for the next step's store.
            self.prev_load_end = none;
            self.prev_load_w = 0;
            self.prev_load_hi_src = none;
            if (op == 0xEB) { // XBA: A's halves swap, sources ride along
                const t = self.a_lo_src;
                self.a_lo_src = self.a_hi_src;
                self.a_hi_src = t;
            } else {
                self.a_lo_src = none;
                self.a_hi_src = none;
            }
            if (usage_map.loadASource(op)) {
                const w: u8 = if (m8) 1 else 2;
                if (op == 0xA9) {
                    self.prev_load_end = (pc +% w) & 0x7F_FFFF;
                    self.prev_load_w = w;
                } else if (dataAddr(self.bus.last_data_read)) |r| {
                    if (usage_map.siteClassHomes(r, conv) == usage_map.site_rom) {
                        self.prev_load_end = r & 0x7F_FFFF;
                        self.prev_load_w = w;
                    } else if (w == 1) {
                        // A byte read back out of WRAM carries whatever ROM
                        // byte put it there. Without this the chain breaks at
                        // every value that reaches hardware through a RAM
                        // staging area, and a DMA job queue is exactly that:
                        // the bank byte is copied from a ROM record into the
                        // queue, and only the queue is read when the channel
                        // is armed.
                        if (usage_map.wramAnyOffset(r, conv)) |off| {
                            const staged = pb.src_any[off];
                            if (staged != usage_map.PtrBankEvidence.none) {
                                self.prev_load_end = staged;
                                self.prev_load_w = 1;
                            }
                        }
                    } else if (usage_map.wramAnyOffset(r, conv)) |off| {
                        // The 16-bit flavour of the same: remember only the
                        // HIGH byte's staged source — the half a $43x3
                        // queue drain turns into an A-bus bank.
                        self.prev_load_hi_src = pb.src[off];
                        // `r` is the END of the read: hi half. Both halves
                        // stage for the XBA/PHA/PLB chain.
                        if (off >= 1) self.a_lo_src = pb.src_any[off - 1];
                        self.a_hi_src = pb.src_any[off];
                    }
                }
            }
            // 4. X-register provenance: a plain X-load from ROM (or its
            //    immediate) sets it; anything else that writes X kills it.
            if (usage_map.loadXSource(op)) {
                self.x_src = none;
                self.x_w = 0;
                const w: u8 = if (x8) 1 else 2;
                if (op == 0xA2) {
                    self.x_src = (pc +% w) & 0x7F_FFFF;
                    self.x_w = w;
                } else if (dataAddr(self.bus.last_data_read)) |r| {
                    if (usage_map.siteClass(r) == usage_map.site_rom) {
                        self.x_src = r & 0x7F_FFFF;
                        self.x_w = w;
                    }
                }
            } else if (usage_map.clobbersX(op)) {
                self.x_src = none;
                self.x_w = 0;
            }
        }

        /// Collect the frame the profiler closed at the last vblank, if any.
        /// Always null on a non-profiling console.
        pub fn takeProfile(self: *Self) ?profile.FrameSample {
            if (!cfg.profile) return null;
            return self.prof.take();
        }

        /// Accurate-mode line loop: beam bookkeeping for the bus's mid-line
        /// $21xx catch-up rendering, and the H-IRQ latched when the beam
        /// reaches HTIME's dot rather than at the top of the line.
        fn runLineCpuAccurate(self: *Self, line: u32) void {
            const io = &self.bus.cpuio;
            self.bus.beam_line = if (line < self.vblankLine()) line else std.math.maxInt(u32);
            self.bus.beam_line_start = self.line_start;

            const fire_at = irqFireClock(io.irqMode(), io.htime, self.irqMatchesLine(line), self.line_start);

            const line_end = self.line_start +% timing.cycles_per_line;
            while (self.bus.clock < line_end) {
                if (fire_at) |t| {
                    if (self.bus.clock >= t) io.irq_flag = true;
                }
                const irq = io.irq_flag or self.bus.coproc_irq_line;
                if (irq != self.cpu.irq_line) self.cpu.setIrqLine(irq);
                self.stepCpu();
                self.steps +%= 1;
            }
            self.line_start = line_end;
        }

        /// Render one visible scanline via the PPU (backdrop + BG/sprite compositor).
        fn renderScanline(self: *Self, line: u32) void {
            self.bus.ppu.renderScanline(line);
        }

        /// The visible RGB565 framebuffer for the current display height.
        pub fn framebuffer(self: *const Self) []const u16 {
            const height: u32 = if (self.bus.ppu.overscan()) timing.visible_lines_239 else timing.visible_lines_224;
            return self.bus.ppu.frame(height);
        }

        /// Pixel width of the last rendered frame (256, or 512 for hi-res).
        pub fn frameWidth(self: *const Self) u32 {
            return self.bus.ppu.fb_line_width;
        }

        /// `--wide N` (M12): extend the fast core's framebuffer by `margin`
        /// columns on each side (`frameWidth()` reports `256 + 2*margin`
        /// after the next frame). Frontends refuse to combine this with
        /// `--accurate` before ever calling it — the dot renderer's
        /// piecewise render stays 256-fixed and never reads this field.
        pub fn setWideMargin(self: *Self, margin: u32) void {
            self.bus.ppu.wide_margin = @intCast(margin);
        }

        /// Drain buffered S-DSP output into `dst` as interleaved stereo i16
        /// at 32 kHz (`timing.dsp_sample_hz`); returns i16 values copied.
        /// One video frame produces ~532 stereo frames.
        pub fn readAudio(self: *Self, dst: []i16) usize {
            return self.bus.apu.readAudio(dst);
        }

        /// Push controller state for `port` (0/1); bit layout in
        /// `joypad.Button`. Latched by the auto-joypad read at each vblank
        /// and by manual $4016 strobes.
        pub fn setButtons(self: *Self, port: u1, buttons: u16) void {
            self.bus.joy.buttons[port] = buttons;
        }

        /// Apply one cheat write; see `Bus.poke8`. False means the address
        /// was not plain writable memory.
        pub fn poke8(self: *Self, addr: u24, value: u8) bool {
            return self.bus.poke8(addr, value);
        }

        // --- save states ---------------------------------------------------

        /// Exact byte size of a save state (header + payload + cart RAM).
        /// Comptime-known and stable for the whole session — what
        /// libretro's retro_serialize_size must report.
        pub const state_size: usize = blk: {
            @setEvalBranchQuota(100_000);
            break :blk state_header_size + serialize.byteSize(Self) + cart_mod.max_sram + cart_mod.max_sram_hi + 4;
        };
        const state_payload_size: usize = blk: {
            @setEvalBranchQuota(100_000);
            break :blk serialize.byteSize(Self);
        };

        /// Structural fingerprint of the serialized layout, carried in the
        /// header's spare bytes (truncated to 24 bits). The version number is
        /// hand-maintained and the size check only sees the byte count — a
        /// same-width field reorder passes both and deserializes garbage.
        /// This is the check nobody has to remember to bump.
        const state_fingerprint: u24 = @truncate(serialize.fingerprint(Self));

        /// Serialize the whole machine into `out` (>= `state_size` bytes)
        /// behind a versioned header. The ROM image is not saved; loading
        /// requires a console built from the same ROM.
        pub fn saveState(self: *const Self, out: []u8) usize {
            std.debug.assert(out.len >= state_size);
            @memcpy(out[0..4], &state_magic);
            std.mem.writeInt(u32, out[4..8], state_version, .little);
            std.mem.writeInt(u32, out[8..12], @intCast(state_payload_size), .little);
            out[12] = @intFromEnum(cfg.accuracy);
            std.mem.writeInt(u24, out[13..16], state_fingerprint, .little);
            _ = serialize.write(Self, self, out[state_header_size..]);
            // Cart RAM after the payload: battery SRAM on a plain cart,
            // the game's whole working state on an SA-1 conversion.
            @memcpy(out[state_header_size + state_payload_size ..][0..cart_mod.max_sram], &self.bus.cart.sram);
            @memcpy(out[state_header_size + state_payload_size + cart_mod.max_sram ..][0..cart_mod.max_sram_hi], &self.bus.cart.sram_hi);
            // The loaded image's identity rides at the tail (version 9): a
            // state restores the WHOLE machine, and on a conversion image
            // that machine is meaningful only on the exact build it was
            // saved from — a different union's relocation era and SA-1
            // state deserialize as total garbage. Measured: a five-day-old
            // pre-split state loaded onto the split image garbled the
            // entire game.
            std.mem.writeInt(u32, out[state_header_size + state_payload_size + cart_mod.max_sram + cart_mod.max_sram_hi ..][0..4], self.bus.cart.rom_crc, .little);
            return state_size;
        }

        /// Restore a state written by `saveState` (same core version and
        /// accuracy). Header validation happens before any machine state is
        /// touched; a payload that fails mid-read (Corrupt) leaves partial
        /// state, which frontends treat as fatal (reload the game).
        pub fn loadState(self: *Self, in: []const u8) StateError!void {
            if (in.len < state_header_size) return error.WrongSize;
            if (!std.mem.eql(u8, in[0..4], &state_magic)) return error.BadMagic;
            const ver = std.mem.readInt(u32, in[4..8], .little);
            if (ver != state_version and ver != state_version_128k_cart_ram and
                ver != state_version_no_rom_crc and ver != state_version_no_cart_ram)
                return error.UnsupportedVersion;
            const cart_ram_len = stateCartRamLen(ver);
            const with_rom_crc = ver >= state_version_128k_cart_ram;
            const expect: usize = state_header_size + state_payload_size +
                cart_ram_len + @as(usize, if (with_rom_crc) 4 else 0);
            const payload = in[state_header_size..@min(in.len, state_header_size + state_payload_size)];
            if (std.mem.readInt(u32, in[8..12], .little) != state_payload_size or
                in.len != expect)
                return error.WrongSize;
            if (in[12] != @intFromEnum(cfg.accuracy)) return error.Corrupt;
            // A state whose layout fingerprint disagrees was written by a
            // build whose field tree differs — even at the same version and
            // byte count. Refusing it here is what stops a same-size field
            // reorder from deserializing garbage into the wrong fields.
            if (std.mem.readInt(u24, in[13..16], .little) != state_fingerprint)
                return error.UnsupportedVersion;
            // Image identity (version 9+): refuse BEFORE touching the
            // machine — restoring another image's state is never partial
            // damage, it is a different machine entirely. Pre-9 states
            // carry no identity and load on trust, as they always did.
            if (with_rom_crc and !dbg_ignore_state_rom_crc and
                std.mem.readInt(u32, in[state_header_size + state_payload_size + cart_ram_len ..][0..4], .little) != self.bus.cart.rom_crc)
                return error.WrongRom;
            _ = serialize.read(Self, self, payload) catch return error.Corrupt;
            // Cart RAM rides after the payload since version 8; an older
            // state simply never saved it, and the machine keeps what it
            // has (battery SRAM semantics — the pre-8 status quo).
            if (cart_ram_len != 0) {
                @memcpy(&self.bus.cart.sram, in[state_header_size + state_payload_size ..][0..cart_mod.max_sram]);
                if (cart_ram_len > cart_mod.max_sram)
                    @memcpy(&self.bus.cart.sram_hi, in[state_header_size + state_payload_size + cart_mod.max_sram ..][0..cart_mod.max_sram_hi])
                else
                    // An older state's tail has no second bank; it was zero
                    // when that state was written (no cart used it).
                    @memset(&self.bus.cart.sram_hi, 0);
            }
            self.postLoad();
        }
    };
}

/// The master-clock time at which this line's IRQ latches, if any (accurate
/// core). H- and H+V-IRQ (modes 1/3) fire when the beam reaches HTIME's dot;
/// V-only IRQ (mode 2) fires at the start of the line. An HTIME beyond the
/// line's 341 dots never fires — its clock lies past the line end.
fn irqFireClock(mode: u2, htime: u16, matches_line: bool, line_start: u64) ?u64 {
    if (!matches_line) return null;
    return switch (mode) {
        1, 3 => line_start +% @as(u64, htime) * timing.cycles_per_dot,
        else => line_start,
    };
}

/// The default shipped core.
pub const FastConsole = Console(.{ .accuracy = .fast });

/// The opt-in accurate core: piecewise beam-position rendering (mid-scanline
/// $21xx writes split the line) and dot-placed H-IRQs.
pub const AccurateConsole = Console(.{ .accuracy = .accurate });

/// The fast core with the frame-budget profiler compiled in: what `--sa1-report`
/// runs. Emulation is bit-identical to `FastConsole` — the profiler only reads.
pub const ProfilingConsole = Console(.{ .accuracy = .fast, .profile = true });

/// Runtime accuracy selection: a tagged union over the two comptime
/// instantiations, dispatched at frame/API granularity so the hot paths stay
/// monomorphized. Same pinning rule as the consoles themselves: heap-allocate,
/// init in place, never move.
pub const AnyConsole = union(Accuracy) {
    fast: FastConsole,
    accurate: AccurateConsole,

    /// Both instantiations serialize the same field set, so their state sizes
    /// agree; the header's accuracy byte is what tells their states apart
    /// (loadState rejects a state from the other core).
    pub const state_size = FastConsole.state_size;
    comptime {
        std.debug.assert(FastConsole.state_size == AccurateConsole.state_size);
    }

    pub fn init(self: *AnyConsole, level: Accuracy, cart: Cartridge) void {
        switch (level) {
            .fast => {
                self.* = .{ .fast = undefined };
                self.fast.init(cart);
            },
            .accurate => {
                self.* = .{ .accurate = undefined };
                self.accurate.init(cart);
            },
        }
    }

    /// Re-power in place, preserving the cartridge (and its battery SRAM).
    pub fn repower(self: *AnyConsole) void {
        switch (self.*) {
            inline else => |*c| {
                const cart = c.cart;
                c.init(cart);
            },
        }
    }

    pub fn accuracy(self: *const AnyConsole) Accuracy {
        return std.meta.activeTag(self.*);
    }

    pub fn region(self: *const AnyConsole) timing.Region {
        switch (self.*) {
            inline else => |*c| return c.region,
        }
    }

    /// Explicit region override (frontend `--region ntsc|pal`); see
    /// `Console.setRegion`.
    pub fn setRegion(self: *AnyConsole, r: timing.Region) void {
        switch (self.*) {
            inline else => |*c| c.setRegion(r),
        }
    }

    pub fn cartridge(self: *AnyConsole) *Cartridge {
        switch (self.*) {
            inline else => |*c| return &c.cart,
        }
    }

    pub fn systemRam(self: *AnyConsole) []u8 {
        switch (self.*) {
            inline else => |*c| return &c.bus.wram.data,
        }
    }

    pub fn runFrame(self: *AnyConsole) void {
        switch (self.*) {
            inline else => |*c| c.runFrame(),
        }
    }

    pub fn inputPolled(self: *const AnyConsole) bool {
        switch (self.*) {
            inline else => |*c| return c.inputPolled(),
        }
    }

    pub fn takeInputPolled(self: *AnyConsole) bool {
        switch (self.*) {
            inline else => |*c| return c.takeInputPolled(),
        }
    }

    pub fn lapPassed(self: *const AnyConsole) bool {
        switch (self.*) {
            inline else => |*c| return c.lapPassed(),
        }
    }

    pub fn takeLapPassed(self: *AnyConsole) bool {
        switch (self.*) {
            inline else => |*c| return c.takeLapPassed(),
        }
    }

    pub fn lapFeedStage(self: *AnyConsole, entries: []const [2]u16) u8 {
        switch (self.*) {
            inline else => |*c| return c.lapFeedStage(entries),
        }
    }

    pub fn lapRecTake(self: *AnyConsole, buf: *[16][2]u16) u8 {
        switch (self.*) {
            inline else => |*c| return c.lapRecTake(buf),
        }
    }

    pub fn framebuffer(self: *const AnyConsole) []const u16 {
        switch (self.*) {
            inline else => |*c| return c.framebuffer(),
        }
    }

    pub fn frameWidth(self: *const AnyConsole) u32 {
        switch (self.*) {
            inline else => |*c| return c.frameWidth(),
        }
    }

    /// `--wide N` (M12, fast core only): see `Console.setWideMargin`.
    /// Frontends must not call this on an `.accurate` console — refuse the
    /// flag combination before `init` instead.
    pub fn setWideMargin(self: *AnyConsole, margin: u32) void {
        switch (self.*) {
            inline else => |*c| c.setWideMargin(margin),
        }
    }

    pub fn readAudio(self: *AnyConsole, dst: []i16) usize {
        switch (self.*) {
            inline else => |*c| return c.readAudio(dst),
        }
    }

    pub fn setButtons(self: *AnyConsole, port: u1, buttons: u16) void {
        switch (self.*) {
            inline else => |*c| c.setButtons(port, buttons),
        }
    }

    /// Opt-in auto-FastROM (M12): pin MEMSEL to 1. Frontends call this once
    /// after init, after they have consulted the compat list.
    pub fn enableAutoFastrom(self: *AnyConsole) void {
        switch (self.*) {
            inline else => |*c| c.bus.enableAutoFastrom(),
        }
    }

    pub fn poke8(self: *AnyConsole, addr: u24, value: u8) bool {
        switch (self.*) {
            inline else => |*c| return c.poke8(addr, value),
        }
    }

    pub fn saveState(self: *const AnyConsole, out: []u8) usize {
        switch (self.*) {
            inline else => |*c| return c.saveState(out),
        }
    }

    pub fn loadState(self: *AnyConsole, in: []const u8) StateError!void {
        switch (self.*) {
            inline else => |*c| return c.loadState(in),
        }
    }
};

/// FNV-1a hash of an RGB565 framebuffer, used by the ROM runner and benchmark
/// to compare output against committed golden values.
pub fn hashFrame(fb: []const u16) u64 {
    const prime: u64 = 0x100000001b3;
    var h: u64 = 0xcbf29ce484222325;
    for (fb) |px| {
        h = (h ^ @as(u64, px & 0xFF)) *% prime;
        h = (h ^ @as(u64, px >> 8)) *% prime;
    }
    return h;
}

/// Streaming FNV-1a over interleaved audio samples — chunk boundaries don't
/// affect the result, so per-frame drains hash identically to one big drain.
/// Byte-order-exact and phase-sensitive: a single inverted sample changes it.
pub fn hashAudio(h: u64, samples: []const i16) u64 {
    const prime: u64 = 0x100000001b3;
    var acc = h;
    for (samples) |s| {
        const u: u16 = @bitCast(s);
        acc = (acc ^ @as(u64, u & 0xFF)) *% prime;
        acc = (acc ^ @as(u64, u >> 8)) *% prime;
    }
    return acc;
}

/// Initial value for `hashAudio` accumulation.
pub const audio_hash_init: u64 = 0xcbf29ce484222325;

// --- tests ---------------------------------------------------------------

test {
    std.testing.refAllDecls(@This());
}

/// Build a minimal LoROM image whose reset code enables NMI and spins, with an
/// NMI handler that increments WRAM $00. Used to prove the scheduler delivers a
/// vblank NMI and that runFrame terminates.
fn buildNmiRom(alloc: std.mem.Allocator) ![]u8 {
    const rom = try alloc.alloc(u8, 0x8000);
    @memset(rom, 0);

    // Reset code at $00:8000 (ROM offset 0):
    //   LDA #$80 ; STA $4200 ; loop: BRA loop
    const reset_code = [_]u8{ 0xA9, 0x80, 0x8D, 0x00, 0x42, 0x80, 0xFE };
    @memcpy(rom[0..reset_code.len], &reset_code);

    // NMI handler at $00:8010 (ROM offset 0x10):
    //   INC $00 ; RTI
    const nmi_code = [_]u8{ 0xE6, 0x00, 0x40 };
    @memcpy(rom[0x10..][0..nmi_code.len], &nmi_code);

    // Header at $7FC0 (LoROM), scored as a valid candidate.
    const h = rom[0x7FC0..][0..64];
    @memcpy(h[0..21], "NMI SCHED TEST       ");
    h[0x15] = 0x20; // LoROM, SlowROM
    h[0x16] = 0x00; // ROM only
    h[0x17] = 5; // 32 KiB
    h[0x18] = 0; // no SRAM
    std.mem.writeInt(u16, h[0x1C..0x1E], 0x0F0F, .little); // complement
    std.mem.writeInt(u16, h[0x1E..0x20], 0xF0F0, .little); // checksum
    // Vectors: NMI ($FFFA) -> $8010, RESET ($FFFC) -> $8000.
    std.mem.writeInt(u16, rom[0x7FFA..0x7FFC], 0x8010, .little);
    std.mem.writeInt(u16, rom[0x7FFC..0x7FFE], 0x8000, .little);
    return rom;
}

test "scheduler delivers a vblank NMI and runFrame terminates" {
    const alloc = std.testing.allocator;
    const rom = try buildNmiRom(alloc);
    defer alloc.free(rom);

    const cart = try Cartridge.load(alloc, rom);
    const con = try alloc.create(FastConsole);
    defer {
        con.cart.deinit(alloc);
        alloc.destroy(con);
    }
    con.init(cart);

    try std.testing.expectEqual(@as(u8, 0), con.bus.wram.data[0]);
    con.runFrame(); // must return (no hang) and fire exactly one NMI
    try std.testing.expectEqual(@as(u64, 1), con.frame);
    try std.testing.expectEqual(@as(u8, 1), con.bus.wram.data[0]);

    con.runFrame();
    try std.testing.expectEqual(@as(u8, 2), con.bus.wram.data[0]);
}

test "region defaults from the header byte and setRegion overrides it" {
    const alloc = std.testing.allocator;
    const rom = try buildNmiRom(alloc);
    defer alloc.free(rom);

    const cart = try Cartridge.load(alloc, rom);
    const con = try alloc.create(FastConsole);
    defer {
        con.cart.deinit(alloc);
        alloc.destroy(con);
    }
    con.init(cart);

    // buildNmiRom's header region byte is 0 (Japan) -> NTSC by default.
    try std.testing.expectEqual(timing.Region.ntsc, con.region);
    try std.testing.expectEqual(timing.ntsc_lines_per_frame, con.linesPerFrame());
    try std.testing.expect(!con.bus.ppu.pal);

    con.setRegion(.pal);
    try std.testing.expectEqual(timing.Region.pal, con.region);
    try std.testing.expectEqual(timing.pal_lines_per_frame, con.linesPerFrame());
    try std.testing.expect(con.bus.ppu.pal);
}

test "ROM-programmed backdrop appears in the framebuffer" {
    const alloc = std.testing.allocator;
    const rom = try alloc.alloc(u8, 0x8000);
    @memset(rom, 0);
    // Reset code: CGADD=0; write color0 = blue ($7C00); INIDISP full; spin.
    const code = [_]u8{
        0xA9, 0x00, 0x8D, 0x21, 0x21, // LDA #$00 ; STA $2121 (CGADD=0)
        0xA9, 0x00, 0x8D, 0x22, 0x21, // LDA #$00 ; STA $2122 (color low)
        0xA9, 0x7C, 0x8D, 0x22, 0x21, // LDA #$7C ; STA $2122 (color high)
        0xA9, 0x0F, 0x8D, 0x00, 0x21, // LDA #$0F ; STA $2100 (brightness 15)
        0x80, 0xFE, // loop: BRA loop
    };
    @memcpy(rom[0..code.len], &code);
    const h = rom[0x7FC0..][0..64];
    @memcpy(h[0..21], "BACKDROP TEST        ");
    h[0x15] = 0x20;
    h[0x17] = 5;
    std.mem.writeInt(u16, h[0x1C..0x1E], 0x0F0F, .little);
    std.mem.writeInt(u16, h[0x1E..0x20], 0xF0F0, .little);
    std.mem.writeInt(u16, rom[0x7FFC..0x7FFE], 0x8000, .little);

    const cart = try Cartridge.load(alloc, rom);
    defer alloc.free(rom);
    const con = try alloc.create(FastConsole);
    defer {
        con.cart.deinit(alloc);
        alloc.destroy(con);
    }
    con.init(cart);
    con.runFrame();

    const fb = con.framebuffer();
    try std.testing.expectEqual(@as(usize, 256 * 224), fb.len);
    try std.testing.expectEqual(@as(u16, 0x001F), fb[0]); // pure blue 565
    try std.testing.expectEqual(@as(u16, 0x001F), fb[fb.len - 1]);
}

test "GDMA copies a palette from ROM into CGRAM" {
    const alloc = std.testing.allocator;
    const rom = try alloc.alloc(u8, 0x8000);
    @memset(rom, 0);
    // Reset code: point channel 0 at the palette table in ROM and GDMA it into
    // CGRAM ($2122, mode 0 = single register), 4 bytes (2 colors), then spin.
    //   LDA #$00 ; STA $2121            ; CGADD = 0
    //   LDA #$00 ; STA $4300            ; DMAP: A->B, increment, mode 0
    //   LDA #$22 ; STA $4301            ; BBAD -> $2122
    //   LDA #$40 ; STA $4302            ; A1T low  = $8040
    //   LDA #$80 ; STA $4303            ; A1T high
    //   LDA #$00 ; STA $4304            ; A1B  = bank 0
    //   LDA #$04 ; STA $4305            ; DAS low = 4
    //   LDA #$00 ; STA $4306            ; DAS high
    //   LDA #$01 ; STA $420B            ; trigger GDMA on channel 0
    //   LDA #$0F ; STA $2100            ; full brightness
    //   loop: BRA loop
    const code = [_]u8{
        0xA9, 0x00, 0x8D, 0x21, 0x21,
        0xA9, 0x00, 0x8D, 0x00, 0x43,
        0xA9, 0x22, 0x8D, 0x01, 0x43,
        0xA9, 0x40, 0x8D, 0x02, 0x43,
        0xA9, 0x80, 0x8D, 0x03, 0x43,
        0xA9, 0x00, 0x8D, 0x04, 0x43,
        0xA9, 0x04, 0x8D, 0x05, 0x43,
        0xA9, 0x00, 0x8D, 0x06, 0x43,
        0xA9, 0x01, 0x8D, 0x0B, 0x42,
        0xA9, 0x0F, 0x8D, 0x00, 0x21,
        0x80, 0xFE,
    };
    @memcpy(rom[0..code.len], &code);
    // Palette table at ROM $8040 (file 0x0040, clear of the code): color0 =
    // black, color1 = green. green 15-bit BGR = $03E0 -> low $E0, high $03.
    rom[0x40] = 0x00;
    rom[0x41] = 0x00;
    rom[0x42] = 0xE0;
    rom[0x43] = 0x03;
    const h = rom[0x7FC0..][0..64];
    @memcpy(h[0..21], "GDMA TEST            ");
    h[0x15] = 0x20;
    h[0x17] = 5;
    std.mem.writeInt(u16, h[0x1C..0x1E], 0x0F0F, .little);
    std.mem.writeInt(u16, h[0x1E..0x20], 0xF0F0, .little);
    std.mem.writeInt(u16, rom[0x7FFC..0x7FFE], 0x8000, .little);

    const cart = try Cartridge.load(alloc, rom);
    defer alloc.free(rom);
    const con = try alloc.create(FastConsole);
    defer {
        con.cart.deinit(alloc);
        alloc.destroy(con);
    }
    con.init(cart);
    con.runFrame();

    // CGRAM was filled by DMA: color 1 = green.
    try std.testing.expectEqual(@as(u16, 0x03E0), con.bus.ppu.cgram[1]);
    try std.testing.expectEqual(@as(u16, 0x07E0), con.bus.ppu.palette[1]); // green 565
}

test "HDMA drives INIDISP per scanline (brightness split mid-frame)" {
    const alloc = std.testing.allocator;
    const rom = try alloc.alloc(u8, 0x8000);
    @memset(rom, 0);
    // Set a white backdrop, program HDMA channel 0 to write INIDISP ($2100)
    // from a table, enable HDMA, then spin.
    const code = [_]u8{
        0xA9, 0x00, 0x8D, 0x21, 0x21, // CGADD = 0
        0xA9, 0xFF, 0x8D, 0x22, 0x21, // color0 low  = $FF
        0xA9, 0x7F, 0x8D, 0x22, 0x21, // color0 high = $7F  (white)
        0xA9, 0x00, 0x8D, 0x00, 0x43, // DMAP0 = mode 0, A->B, direct
        0xA9, 0x00, 0x8D, 0x01, 0x43, // BBAD0 = $00 -> $2100
        0xA9, 0x60, 0x8D, 0x02, 0x43, // A1T0 low  = $60
        0xA9, 0x80, 0x8D, 0x03, 0x43, // A1T0 high = $80  (table @ $8060)
        0xA9, 0x00, 0x8D, 0x04, 0x43, // A1B0 = bank 0
        0xA9, 0x01, 0x8D, 0x0C, 0x42, // HDMAEN = channel 0
        0x80, 0xFE, // loop: BRA loop
    };
    @memcpy(rom[0..code.len], &code);
    // HDMA table @ $8060 (non-repeat blocks): 100 lines at brightness $0F,
    // then 124 lines at $00, then terminator.
    const table = [_]u8{ 0x64, 0x0F, 0x7C, 0x00, 0x00 };
    @memcpy(rom[0x60..][0..table.len], &table);
    const h = rom[0x7FC0..][0..64];
    @memcpy(h[0..21], "HDMA TEST            ");
    h[0x15] = 0x20;
    h[0x17] = 5;
    std.mem.writeInt(u16, h[0x1C..0x1E], 0x0F0F, .little);
    std.mem.writeInt(u16, h[0x1E..0x20], 0xF0F0, .little);
    std.mem.writeInt(u16, rom[0x7FFC..0x7FFE], 0x8000, .little);

    const cart = try Cartridge.load(alloc, rom);
    defer alloc.free(rom);
    const con = try alloc.create(FastConsole);
    defer {
        con.cart.deinit(alloc);
        alloc.destroy(con);
    }
    con.init(cart);
    // Frame 1: the CPU configures and enables HDMA during active display, which
    // is past this frame's line-0 init — so it takes effect from frame 2 on,
    // exactly as on hardware.
    con.runFrame();
    con.runFrame();

    const fb = con.framebuffer();
    // Lines 0-99: full brightness white; lines 100+: black.
    try std.testing.expectEqual(@as(u16, 0xFFFF), fb[0 * fb_width]);
    try std.testing.expectEqual(@as(u16, 0xFFFF), fb[50 * fb_width]);
    try std.testing.expectEqual(@as(u16, 0x0000), fb[150 * fb_width]);
    try std.testing.expectEqual(@as(u16, 0x0000), fb[223 * fb_width]);
}

const fb_width = @import("ppu/ppu.zig").fb_width;

test "console save-state roundtrips and restores identical machine state" {
    // Serializing the whole machine unrolls (comptime) over every PPU/CPU/bus
    // field; the default 1000-branch budget is too small and grows each milestone.
    @setEvalBranchQuota(20000);
    const alloc = std.testing.allocator;

    // Run console A a few frames so the CPU, WRAM, and scheduler hold live state.
    const rom_a = try buildNmiRom(alloc);
    defer alloc.free(rom_a);
    const a = try alloc.create(FastConsole);
    defer {
        a.cart.deinit(alloc);
        alloc.destroy(a);
    }
    a.init(try Cartridge.load(alloc, rom_a));
    for (0..3) |_| a.runFrame();

    // Serialize A's whole machine state (ROM is skipped; frontend re-supplies it).
    const size = comptime serialize.byteSize(FastConsole);
    const buf = try alloc.alloc(u8, size);
    defer alloc.free(buf);
    try std.testing.expectEqual(size, serialize.write(FastConsole, a, buf));

    // Restore into a second console built from the same ROM, then re-wire pointers.
    const rom_b = try buildNmiRom(alloc);
    defer alloc.free(rom_b);
    const b = try alloc.create(FastConsole);
    defer {
        b.cart.deinit(alloc);
        alloc.destroy(b);
    }
    b.init(try Cartridge.load(alloc, rom_b));
    _ = try serialize.read(FastConsole, b, buf);
    b.postLoad();

    // Byte-identical restore: re-serializing B reproduces A's state exactly. This
    // is what catches a non-deterministic or unrestored field.
    const buf2 = try alloc.alloc(u8, size);
    defer alloc.free(buf2);
    _ = serialize.write(FastConsole, b, buf2);
    try std.testing.expectEqualSlices(u8, buf, buf2);

    // And the restored machine steps forward identically (proves postLoad rewired
    // every self-pointer: the CPU's &bus, the bus page table, bus.cart).
    a.runFrame();
    b.runFrame();
    try std.testing.expectEqual(hashFrame(a.framebuffer()), hashFrame(b.framebuffer()));
    try std.testing.expectEqualSlices(u8, a.bus.wram.data[0..], b.bus.wram.data[0..]);
    try std.testing.expectEqual(a.frame, b.frame);
}

test "versioned save state roundtrips and rejects bad headers" {
    const alloc = std.testing.allocator;
    const rom = try buildNmiRom(alloc);
    defer alloc.free(rom);
    const a = try alloc.create(FastConsole);
    defer {
        a.cart.deinit(alloc);
        alloc.destroy(a);
    }
    a.init(try Cartridge.load(alloc, rom));
    for (0..3) |_| a.runFrame();

    const buf = try alloc.alloc(u8, FastConsole.state_size);
    defer alloc.free(buf);
    try std.testing.expectEqual(FastConsole.state_size, a.saveState(buf));

    // Restore into a fresh console from the same ROM; both step identically.
    const rom_b = try buildNmiRom(alloc);
    defer alloc.free(rom_b);
    const b = try alloc.create(FastConsole);
    defer {
        b.cart.deinit(alloc);
        alloc.destroy(b);
    }
    b.init(try Cartridge.load(alloc, rom_b));
    try b.loadState(buf);
    a.runFrame();
    b.runFrame();
    try std.testing.expectEqual(hashFrame(a.framebuffer()), hashFrame(b.framebuffer()));
    try std.testing.expectEqual(a.frame, b.frame);

    // Header validation: magic, version, size, accuracy tag.
    buf[0] = 'X';
    try std.testing.expectError(error.BadMagic, b.loadState(buf));
    buf[0] = 'Y';
    buf[4] = 0xFF;
    try std.testing.expectError(error.UnsupportedVersion, b.loadState(buf));
    buf[4] = @truncate(state_version);
    try std.testing.expectError(error.WrongSize, b.loadState(buf[0 .. buf.len - 1]));
    // A wrong layout fingerprint — a state from a build whose field tree
    // differs, even at the same version and size — is unsupported, not fed
    // to the deserializer.
    buf[13] +%= 1;
    try std.testing.expectError(error.UnsupportedVersion, b.loadState(buf));
    buf[13] -%= 1;
    buf[12] = 0xEE;
    try std.testing.expectError(error.Corrupt, b.loadState(buf));
}

test "V-IRQ timer fires once per frame on its scanline and TIMEUP acks it" {
    const alloc = std.testing.allocator;
    const rom = try alloc.alloc(u8, 0x8000);
    @memset(rom, 0);
    // Reset: enable IRQs, program V-IRQ on line 50, then spin.
    //   CLI ; LDA #$32 ; STA $4209 (VTIMEL=50) ; LDA #$00 ; STA $420A (VTIMEH)
    //   LDA #$20 ; STA $4200 (NMITIMEN: V-IRQ, mode 2) ; loop: BRA loop
    const code = [_]u8{
        0x58,
        0xA9,
        0x32,
        0x8D,
        0x09,
        0x42,
        0xA9,
        0x00,
        0x8D,
        0x0A,
        0x42,
        0xA9,
        0x20,
        0x8D,
        0x00,
        0x42,
        0x80,
        0xFE,
    };
    @memcpy(rom[0..code.len], &code);
    // IRQ handler at $8020: ack TIMEUP (else the level re-triggers), bump $00, RTI.
    //   LDA $4211 ; INC $00 ; RTI
    @memcpy(rom[0x20..][0..6], &[_]u8{ 0xAD, 0x11, 0x42, 0xE6, 0x00, 0x40 });
    const h = rom[0x7FC0..][0..64];
    @memcpy(h[0..21], "VIRQ TEST            ");
    h[0x15] = 0x20;
    h[0x17] = 5;
    std.mem.writeInt(u16, h[0x1C..0x1E], 0x0F0F, .little);
    std.mem.writeInt(u16, h[0x1E..0x20], 0xF0F0, .little);
    std.mem.writeInt(u16, rom[0x7FFE..0x8000], 0x8020, .little); // emulation IRQ/BRK
    std.mem.writeInt(u16, rom[0x7FFC..0x7FFE], 0x8000, .little); // reset

    const cart = try Cartridge.load(alloc, rom);
    defer alloc.free(rom);
    const con = try alloc.create(FastConsole);
    defer {
        con.cart.deinit(alloc);
        alloc.destroy(con);
    }
    con.init(cart);

    // Exactly one IRQ per frame: if TIMEUP didn't deassert the level, the handler
    // would re-enter every instruction and $00 would blow past the frame count.
    con.runFrame();
    try std.testing.expectEqual(@as(u8, 1), con.bus.wram.data[0]);
    con.runFrame();
    con.runFrame();
    try std.testing.expectEqual(@as(u8, 3), con.bus.wram.data[0]);
}

test "STAT78 exposes the per-frame field flag ($213F bit 7)" {
    // Real hardware toggles STAT78's field flag once per frame — a frame-parity
    // signal, independent of interlace mode — and a script that waits for it to
    // change to advance (a common cutscene-timing idiom) hangs forever if it is
    // hardwired to zero. `field` was declared nowhere and $213F never read it;
    // the same bug class as HVBJOY's H-blank flag (`isHblank`).
    const alloc = std.testing.allocator;
    const rom = try alloc.alloc(u8, 0x8000);
    @memset(rom, 0);
    const code = [_]u8{ 0x80, 0xFE }; // loop: BRA loop
    @memcpy(rom[0..code.len], &code);
    const h = rom[0x7FC0..][0..64];
    @memcpy(h[0..21], "FIELD TEST           ");
    h[0x15] = 0x20;
    h[0x17] = 5;
    std.mem.writeInt(u16, h[0x1C..0x1E], 0x0F0F, .little);
    std.mem.writeInt(u16, h[0x1E..0x20], 0xF0F0, .little);
    std.mem.writeInt(u16, rom[0x7FFC..0x7FFE], 0x8000, .little);

    const cart = try Cartridge.load(alloc, rom);
    defer alloc.free(rom);
    const con = try alloc.create(FastConsole);
    defer {
        con.cart.deinit(alloc);
        alloc.destroy(con);
    }
    con.init(cart);

    const f0 = con.bus.read8(0x00_213F) & 0x80;
    con.runFrame();
    const f1 = con.bus.read8(0x00_213F) & 0x80;
    try std.testing.expect(f0 != f1); // toggled after one frame
    con.runFrame();
    try std.testing.expectEqual(f0, con.bus.read8(0x00_213F) & 0x80); // and back
}

test "HDMA indirect mode drives INIDISP per scanline" {
    const alloc = std.testing.allocator;
    const rom = try alloc.alloc(u8, 0x8000);
    @memset(rom, 0);
    // Same brightness split as the direct-mode HDMA test, but the table holds
    // indirect pointers (DMAP bit 6) to the INIDISP values instead of the values.
    const code = [_]u8{
        0xA9, 0x00, 0x8D, 0x21, 0x21, // CGADD = 0
        0xA9, 0xFF, 0x8D, 0x22, 0x21, // color0 low  = $FF
        0xA9, 0x7F, 0x8D, 0x22, 0x21, // color0 high = $7F (white)
        0xA9, 0x40, 0x8D, 0x00, 0x43, // DMAP0 = mode 0, A->B, INDIRECT
        0xA9, 0x00, 0x8D, 0x01, 0x43, // BBAD0 = $00 -> $2100
        0xA9, 0x60, 0x8D, 0x02, 0x43, // A1T0 low  = $60
        0xA9, 0x80, 0x8D, 0x03, 0x43, // A1T0 high = $80 (table @ $8060)
        0xA9, 0x00, 0x8D, 0x04, 0x43, // A1B0 = bank 0 (table bank)
        0xA9, 0x00, 0x8D, 0x07, 0x43, // DASB0 = bank 0 (indirect data bank)
        0xA9, 0x01, 0x8D, 0x0C, 0x42, // HDMAEN = channel 0
        0x80, 0xFE, // loop: BRA loop
    };
    @memcpy(rom[0..code.len], &code);
    // Indirect table @ $8060: {100 lines, ptr $8070}, {124 lines, ptr $8071}, end.
    const table = [_]u8{ 0x64, 0x70, 0x80, 0x7C, 0x71, 0x80, 0x00 };
    @memcpy(rom[0x60..][0..table.len], &table);
    rom[0x70] = 0x0F; // brightness value for the first block
    rom[0x71] = 0x00; // brightness value for the second block
    const h = rom[0x7FC0..][0..64];
    @memcpy(h[0..21], "HDMA IND TEST        ");
    h[0x15] = 0x20;
    h[0x17] = 5;
    std.mem.writeInt(u16, h[0x1C..0x1E], 0x0F0F, .little);
    std.mem.writeInt(u16, h[0x1E..0x20], 0xF0F0, .little);
    std.mem.writeInt(u16, rom[0x7FFC..0x7FFE], 0x8000, .little);

    const cart = try Cartridge.load(alloc, rom);
    defer alloc.free(rom);
    const con = try alloc.create(FastConsole);
    defer {
        con.cart.deinit(alloc);
        alloc.destroy(con);
    }
    con.init(cart);
    con.runFrame(); // frame 1 configures HDMA mid-frame; effect lands frame 2
    con.runFrame();

    const fb = con.framebuffer();
    try std.testing.expectEqual(@as(u16, 0xFFFF), fb[0 * fb_width]); // white
    try std.testing.expectEqual(@as(u16, 0xFFFF), fb[50 * fb_width]);
    try std.testing.expectEqual(@as(u16, 0x0000), fb[150 * fb_width]); // black
    try std.testing.expectEqual(@as(u16, 0x0000), fb[223 * fb_width]);
}

test "NMI is suppressed while NMITIMEN bit7 is clear" {
    const alloc = std.testing.allocator;
    const rom = try alloc.alloc(u8, 0x8000);
    @memset(rom, 0);
    // Reset: just spin (never enable NMI).  loop: BRA loop
    @memcpy(rom[0..2], &[_]u8{ 0x80, 0xFE });
    // NMI handler still increments $00 if it were ever taken.
    @memcpy(rom[0x10..][0..3], &[_]u8{ 0xE6, 0x00, 0x40 });
    const h = rom[0x7FC0..][0..64];
    @memcpy(h[0..21], "NO NMI TEST          ");
    h[0x15] = 0x20;
    h[0x17] = 5;
    std.mem.writeInt(u16, h[0x1C..0x1E], 0x0F0F, .little);
    std.mem.writeInt(u16, h[0x1E..0x20], 0xF0F0, .little);
    std.mem.writeInt(u16, rom[0x7FFA..0x7FFC], 0x8010, .little);
    std.mem.writeInt(u16, rom[0x7FFC..0x7FFE], 0x8000, .little);

    const cart = try Cartridge.load(alloc, rom);
    defer alloc.free(rom);
    const con = try alloc.create(FastConsole);
    defer {
        con.cart.deinit(alloc);
        alloc.destroy(con);
    }
    con.init(cart);
    con.runFrame();
    // NMI never enabled → handler never ran, but the flag still latched.
    try std.testing.expectEqual(@as(u8, 0), con.bus.wram.data[0]);
    try std.testing.expect(con.bus.cpuio.nmi_flag);
    // Reading RDNMI clears it.
    try std.testing.expectEqual(@as(u8, 0x82), con.bus.cpuio.readRdnmi(0));
}

test "irqFireClock places H-IRQ at HTIME's dot" {
    try std.testing.expectEqual(@as(?u64, null), irqFireClock(1, 100, false, 1000));
    try std.testing.expectEqual(@as(?u64, 1000 + 400), irqFireClock(1, 100, true, 1000));
    try std.testing.expectEqual(@as(?u64, 1000), irqFireClock(2, 100, true, 1000));
    try std.testing.expectEqual(@as(?u64, 1000 + 4 * 339), irqFireClock(3, 339, true, 1000));
}

/// Build the minimal spin-loop test ROM shared by the accuracy tests.
fn buildSpinRom(alloc: std.mem.Allocator) ![]u8 {
    const rom = try alloc.alloc(u8, 0x8000);
    @memset(rom, 0);
    // Reset code: backdrop = red, full brightness, spin.
    const code = [_]u8{
        0xA9, 0x00, 0x8D, 0x21, 0x21, // CGADD = 0
        0xA9, 0x1F, 0x8D, 0x22, 0x21, // color 0 low = $1F (red)
        0xA9, 0x00, 0x8D, 0x22, 0x21, // color 0 high = $00
        0xA9, 0x0F, 0x8D, 0x00, 0x21, // INIDISP: full brightness
        0x80, 0xFE, // loop: BRA loop
    };
    @memcpy(rom[0..code.len], &code);
    const h = rom[0x7FC0..][0..64];
    @memcpy(h[0..21], "ACCURACY TEST        ");
    h[0x15] = 0x20;
    h[0x17] = 5;
    std.mem.writeInt(u16, h[0x1C..0x1E], 0x0F0F, .little);
    std.mem.writeInt(u16, h[0x1E..0x20], 0xF0F0, .little);
    std.mem.writeInt(u16, rom[0x7FFC..0x7FFE], 0x8000, .little);
    return rom;
}

test "accurate core matches the fast core when nothing races the beam" {
    const alloc = std.testing.allocator;
    const rom = try buildSpinRom(alloc);
    defer alloc.free(rom);

    const fast = try alloc.create(FastConsole);
    defer {
        fast.cart.deinit(alloc);
        alloc.destroy(fast);
    }
    fast.init(try Cartridge.load(alloc, rom));

    const accurate = try alloc.create(AccurateConsole);
    defer {
        accurate.cart.deinit(alloc);
        alloc.destroy(accurate);
    }
    accurate.init(try Cartridge.load(alloc, rom));

    for (0..2) |_| {
        fast.runFrame();
        accurate.runFrame();
    }
    try std.testing.expectEqual(fast.steps, accurate.steps);
    try std.testing.expectEqual(fast.bus.clock, accurate.bus.clock);
    try std.testing.expectEqual(hashFrame(fast.framebuffer()), hashFrame(accurate.framebuffer()));
}

test "accurate core: a $21xx write mid-line lands at the beam position" {
    const alloc = std.testing.allocator;
    const rom = try buildSpinRom(alloc);
    defer alloc.free(rom);

    const con = try alloc.create(AccurateConsole);
    defer {
        con.cart.deinit(alloc);
        alloc.destroy(con);
    }
    con.init(try Cartridge.load(alloc, rom));
    con.runFrame(); // program has set the backdrop red

    // Simulate the beam being 100 pixels into line 50, then write the
    // backdrop color through the real bus path ($2121/$2122).
    con.bus.beam_line = 50;
    con.bus.beam_line_start = con.bus.clock;
    con.bus.clock += (timing.render_start_dot + 100) * timing.cycles_per_dot;
    con.bus.write8(0x002121, 0x00);
    con.bus.write8(0x002122, 0x00);
    con.bus.write8(0x002122, 0x7C); // color 0 = blue
    con.bus.ppu.finishScanline(50);

    const row = con.bus.ppu.fb[50 * 256 ..];
    try std.testing.expectEqual(@as(u16, 0xF800), row[0]); // red before the write
    try std.testing.expectEqual(@as(u16, 0xF800), row[99]);
    try std.testing.expectEqual(@as(u16, 0x001F), row[120]); // blue after it
    try std.testing.expectEqual(@as(u16, 0x001F), row[255]);
}

test "save states are tied to the accuracy that wrote them" {
    const alloc = std.testing.allocator;
    const rom = try buildSpinRom(alloc);
    defer alloc.free(rom);

    const a = try alloc.create(AnyConsole);
    defer {
        a.cartridge().deinit(alloc);
        alloc.destroy(a);
    }
    a.init(.fast, try Cartridge.load(alloc, rom));
    a.runFrame();

    const buf = try alloc.alloc(u8, AnyConsole.state_size);
    defer alloc.free(buf);
    _ = a.saveState(buf);

    const b = try alloc.create(AnyConsole);
    defer {
        b.cartridge().deinit(alloc);
        alloc.destroy(b);
    }
    b.init(.accurate, try Cartridge.load(alloc, rom));
    try std.testing.expectError(error.Corrupt, b.loadState(buf));
}

test "save states carry cart RAM (the payload serializes the console's cart)" {
    const alloc = std.testing.allocator;
    const rom = try buildSpinRom(alloc);
    defer alloc.free(rom);

    const a = try alloc.create(FastConsole);
    defer {
        a.cart.deinit(alloc);
        alloc.destroy(a);
    }
    a.init(try Cartridge.load(alloc, rom));
    a.runFrame();
    a.bus.cart.sram[0x1234] = 0xAB; // the state an SA-1 conversion lives in

    const buf = try alloc.alloc(u8, FastConsole.state_size);
    defer alloc.free(buf);
    _ = a.saveState(buf);

    // Clobber, load, restored — the payload carries the cart's RAM, which
    // is the whole game state on an SA-1 conversion.
    a.bus.cart.sram[0x1234] = 0;
    try a.loadState(buf);
    try std.testing.expectEqual(@as(u8, 0xAB), a.bus.cart.sram[0x1234]);
}

test "a $4210 edge-wait can win the race against the NMI handler's own ack" {
    // Street Fighter Alpha 2's boot (issue #88): the main thread spins in
    //   wait: LDA $4210 / BPL wait
    // with NMI enabled, while the NMI handler ALSO reads $4210 — clearing
    // the flag. On hardware the poll's read races the NMI delivery and wins
    // ~40% of frames (the interrupt-sampling grace); the game exits within a
    // few frames. Without the grace the handler acks first on every frame,
    // deterministically, and the wait never ends.
    const alloc = std.testing.allocator;
    const rom = try alloc.alloc(u8, 0x8000);
    defer alloc.free(rom);
    @memset(rom, 0);

    // Reset at $00:8000: enable NMI, drain the flag, then edge-wait; store
    // the winning read to WRAM $00 and spin.
    const reset_code = [_]u8{
        0xA9, 0x80, // LDA #$80
        0x8D, 0x00, 0x42, // STA $4200
        0xAD, 0x10, 0x42, // wait0: LDA $4210
        0x30, 0xFB, // BMI wait0 (drain while set)
        0xAD, 0x10, 0x42, // wait1: LDA $4210
        0x10, 0xFB, // BPL wait1 (spin until set)
        0x85, 0x00, // STA $00 (bit7 must be set here)
        0x80, 0xFE, // spin: BRA spin
    };
    @memcpy(rom[0..reset_code.len], &reset_code);
    // NMI handler at $00:8020: count it, burn a frame-varying number of
    // cycles, ack $4210 (the thieving read), RTI. The variable delay is what
    // real handlers do naturally; a fixed-length handler phase-locks the
    // poll loop against the exactly periodic frame and the race never moves.
    const nmi_code = [_]u8{
        0x48, // PHA (a real handler preserves registers; the win
        0xDA, // PHX  depends on A surviving the service sequence)
        0xE6, 0x01, // INC $01
        0xA5, 0x01, // LDA $01
        0x29, 0x07, // AND #$07
        0xAA, // TAX
        0xF0, 0x03, // BEQ +3 (skip delay when zero)
        0xCA, // delay: DEX
        0xD0, 0xFD, // BNE delay
        0xAD, 0x10, 0x42, // LDA $4210 (ack)
        0xFA, // PLX
        0x68, // PLA
        0x40, // RTI
    };
    @memcpy(rom[0x20..][0..nmi_code.len], &nmi_code);

    const h = rom[0x7FC0..][0..64];
    @memcpy(h[0..21], "NMI RACE TEST        ");
    h[0x15] = 0x20;
    h[0x16] = 0x00;
    h[0x17] = 5;
    h[0x18] = 0;
    std.mem.writeInt(u16, h[0x1C..0x1E], 0x0F0F, .little);
    std.mem.writeInt(u16, h[0x1E..0x20], 0xF0F0, .little);
    std.mem.writeInt(u16, rom[0x7FFA..0x7FFC], 0x8020, .little);
    std.mem.writeInt(u16, rom[0x7FFC..0x7FFE], 0x8000, .little);

    const cart = try Cartridge.load(alloc, rom);
    const con = try alloc.create(FastConsole);
    defer {
        con.cart.deinit(alloc);
        alloc.destroy(con);
    }
    con.init(cart);

    // The win is phase-dependent frame to frame, exactly like hardware; it
    // must land well within a second.
    var frames: u32 = 0;
    while (frames < 60 and con.bus.wram.data[0] == 0) : (frames += 1) {
        con.runFrame();
    }
    try std.testing.expect(con.bus.wram.data[0] & 0x80 != 0); // the wait exited
    try std.testing.expect(con.bus.wram.data[1] > 0); // and the handler kept running
}

test "usage map records opcode, operand, and data flags through a profiled run" {
    const alloc = std.testing.allocator;
    const rom = try buildNmiRom(alloc);
    defer alloc.free(rom);

    const bytes = try alloc.alloc(u8, usage_map.cpu_map_len);
    defer alloc.free(bytes);
    @memset(bytes, 0);
    const map: usage_map.UsageMap = .{ .bytes = bytes };

    const cart = try Cartridge.load(alloc, rom);
    const con = try alloc.create(ProfilingConsole);
    defer {
        con.cart.deinit(alloc);
        alloc.destroy(con);
    }
    con.init(cart);
    con.usage = &map;
    con.runFrame();
    con.runFrame(); // the NMI handler runs at least once

    const F = usage_map;
    // LDA #$80 at $00:8000 — emulation mode at reset, so M and X read 8-bit.
    try std.testing.expectEqual(F.flag_opcode | F.flag_exec | F.flag_m | F.flag_x, bytes[0x00_8000]);
    try std.testing.expectEqual(F.flag_exec, bytes[0x00_8001]);
    // STA $4200 at $00:8002: opcode, two operand bytes, and the MMIO write.
    try std.testing.expect(bytes[0x00_8002] & F.flag_opcode != 0);
    try std.testing.expect(bytes[0x00_8003] & F.flag_exec != 0);
    try std.testing.expect(bytes[0x00_8004] & F.flag_exec != 0);
    try std.testing.expect(bytes[0x00_4200] & F.flag_write != 0);
    // The spin: BRA at $00:8005 executes; its target byte is its own operand.
    try std.testing.expect(bytes[0x00_8005] & F.flag_opcode != 0);
    // The NMI handler: INC $00 reads AND writes WRAM through the low mirror,
    // and the RTI behind it is marked as an opcode.
    try std.testing.expect(bytes[0x00_8010] & F.flag_opcode != 0);
    try std.testing.expect(bytes[0x00_0000] & F.flag_read != 0);
    try std.testing.expect(bytes[0x00_0000] & F.flag_write != 0);
    try std.testing.expect(bytes[0x00_8012] & F.flag_opcode != 0);
    // Nothing marked the header or empty space as executed.
    try std.testing.expectEqual(@as(u8, 0), bytes[0x00_9000]);
}
