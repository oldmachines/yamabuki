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
const Cartridge = @import("cart/cartridge.zig").Cartridge;
const Cpu = @import("cpu/wdc65816.zig").Cpu;
const profile = @import("profile.zig");

/// Save-state container magic ("YMBK") and format version. The version bumps
/// whenever the serialized field layout changes (there is no migration —
/// states are tied to the core revision that wrote them, standard for
/// in-development emulators).
pub const state_magic: [4]u8 = .{ 'Y', 'M', 'B', 'K' };
pub const state_version: u32 = 6;
pub const state_header_size: usize = 16;

pub const StateError = error{ BadMagic, UnsupportedVersion, WrongSize, Corrupt };

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
        pub const serialize_skip = .{ "steps", "prof" };

        cart: Cartridge,
        bus: Bus,
        cpu: Cpu(Bus),

        /// Zero-sized (and every use of it compiled away) unless `cfg.profile`.
        prof: if (cfg.profile) profile.Profiler else void,

        region: timing.Region,
        /// Current scanline within the frame (0-based).
        scanline: u32,
        /// bus.clock at the start of the current scanline.
        line_start: u64,
        /// Completed-frame counter.
        frame: u64,
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
            self.region = .ntsc;
            self.reset();
        }

        /// Power-on / reset: reload CPU vectors and restart the frame timeline.
        pub fn reset(self: *Self) void {
            self.cpu.reset();
            self.bus.cpuio = .init;
            self.scanline = 0;
            self.line_start = self.bus.clock;
            self.frame = 0;
            self.steps = 0;
            if (cfg.profile) self.prof = .init;
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
            }
            if (line == self.vblankLine()) {
                // The game's deadline: its main loop had until now to come
                // around. Close the profiler's frame here rather than at
                // scanline 0, so the window matches the NMI-to-NMI period the
                // game's logic actually runs in.
                if (cfg.profile) {
                    self.prof.endFrame(self.frame, self.bus.input_polled);
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
            if (self.bus.cart.chip == .superfx) self.bus.gsu.catchUp(self.bus.clock);
            if (self.bus.cart.chip == .sa1) self.bus.sa1.catchUp(self.bus.clock);

            // Fast mode renders the whole visible scanline at line end; the
            // accurate core renders whatever the beam didn't already emit.
            if (line < self.vblankLine()) {
                if (cfg.accuracy == .fast) self.renderScanline(line) else self.bus.ppu.finishScanline(line);
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
                // Super FX's STOP interrupt (acked by reading SFR) ORs in.
                const irq = io.irq_flag or self.bus.gsu.irq_line or self.bus.sa1.snes_irq_line;
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
            self.bus.last_data_read = Bus.no_data_access;
            self.bus.last_data_write = Bus.no_data_access;
            self.cpu.step();
            self.prof.step(
                pc,
                self.bus.clock -% t0,
                waiting,
                dataAddr(self.bus.last_data_read),
                dataAddr(self.bus.last_data_write),
            );
        }

        fn dataAddr(v: u32) ?u24 {
            return if (v == Bus.no_data_access) null else @intCast(v);
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
                const irq = io.irq_flag or self.bus.gsu.irq_line or self.bus.sa1.snes_irq_line;
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

        // --- save states ---------------------------------------------------

        /// Exact byte size of a save state (header + payload). Comptime-known
        /// and stable for the whole session — what libretro's
        /// retro_serialize_size must report.
        pub const state_size: usize = blk: {
            @setEvalBranchQuota(100_000);
            break :blk state_header_size + serialize.byteSize(Self);
        };

        /// Serialize the whole machine into `out` (>= `state_size` bytes)
        /// behind a versioned header. The ROM image is not saved; loading
        /// requires a console built from the same ROM.
        pub fn saveState(self: *const Self, out: []u8) usize {
            std.debug.assert(out.len >= state_size);
            const payload_size: u32 = @intCast(state_size - state_header_size);
            @memcpy(out[0..4], &state_magic);
            std.mem.writeInt(u32, out[4..8], state_version, .little);
            std.mem.writeInt(u32, out[8..12], payload_size, .little);
            out[12] = @intFromEnum(cfg.accuracy);
            @memset(out[13..16], 0);
            _ = serialize.write(Self, self, out[state_header_size..]);
            return state_size;
        }

        /// Restore a state written by `saveState` (same core version and
        /// accuracy). Header validation happens before any machine state is
        /// touched; a payload that fails mid-read (Corrupt) leaves partial
        /// state, which frontends treat as fatal (reload the game).
        pub fn loadState(self: *Self, in: []const u8) StateError!void {
            if (in.len < state_header_size) return error.WrongSize;
            if (!std.mem.eql(u8, in[0..4], &state_magic)) return error.BadMagic;
            if (std.mem.readInt(u32, in[4..8], .little) != state_version)
                return error.UnsupportedVersion;
            const payload = in[state_header_size..];
            if (std.mem.readInt(u32, in[8..12], .little) != payload.len or
                payload.len != state_size - state_header_size)
                return error.WrongSize;
            if (in[12] != @intFromEnum(cfg.accuracy)) return error.Corrupt;
            _ = serialize.read(Self, self, payload) catch return error.Corrupt;
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
