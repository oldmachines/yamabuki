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
const Bus = @import("memory/bus.zig").Bus;
const Cartridge = @import("cart/cartridge.zig").Cartridge;
const Cpu = @import("cpu/wdc65816.zig").Cpu;

pub const Accuracy = enum { fast, accurate };

pub const CoreConfig = struct {
    accuracy: Accuracy = .fast,
};

pub fn Console(comptime cfg: CoreConfig) type {
    return struct {
        const Self = @This();
        pub const config = cfg;

        // The cart value is owned here so the whole system is one allocation;
        // the bus/cpu hold pointers into this struct and must not be moved.
        pub const serialize_skip = .{};

        cart: Cartridge,
        bus: Bus,
        cpu: Cpu(Bus),

        region: timing.Region,
        /// Overscan on → 239 visible lines, off → 224.
        overscan: bool,
        /// Current scanline within the frame (0-based).
        scanline: u32,
        /// bus.clock at the start of the current scanline.
        line_start: u64,
        /// Completed-frame counter.
        frame: u64,

        /// Initialize in place from an already-loaded cartridge. `self` must be
        /// at its final (heap) address before calling; it is pinned afterward.
        pub fn init(self: *Self, cart: Cartridge) void {
            self.cart = cart;
            self.bus.init(&self.cart);
            self.cpu = Cpu(Bus).init(&self.bus);
            self.region = .ntsc;
            self.overscan = false;
            self.reset();
        }

        /// Power-on / reset: reload CPU vectors and restart the frame timeline.
        pub fn reset(self: *Self) void {
            self.cpu.reset();
            self.bus.cpuio = .init;
            self.scanline = 0;
            self.line_start = self.bus.clock;
            self.frame = 0;
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
        pub fn vblankLine(self: *const Self) u32 {
            return if (self.overscan) timing.vblank_line_239 else timing.vblank_line_224;
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

            if (line == 0) {
                // New frame: leave vblank, clear the vblank NMI flag.
                io.in_vblank = false;
                io.nmi_flag = false;
            }
            if (line == self.vblankLine()) {
                // Entering vblank: latch the NMI flag and deliver if enabled.
                io.in_vblank = true;
                io.nmi_flag = true;
                if (io.nmiEnabled()) self.cpu.setNmi();
            }

            // Evaluate the H/V-IRQ timer for this scanline (line granularity;
            // exact dot placement is deferred to the accurate core, M8).
            if (self.irqMatchesLine(line)) {
                io.irq_flag = true;
            }

            // HDMA: reload the tables at the top of the frame, then inject one
            // transfer per visible line before the line is drawn so per-line
            // register effects (scroll, gradients) apply to this scanline.
            if (line == 0) self.bus.dma.hdmaInit(&self.bus);
            if (line < self.vblankLine()) self.bus.dma.hdmaRunLine(&self.bus);

            self.runLineCpu();

            // Fast mode renders the whole visible scanline at line end.
            if (cfg.accuracy == .fast) {
                if (line < self.vblankLine()) self.renderScanline(line);
            }
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
                // deassert the line before the handler's RTI re-checks it.
                if (io.irq_flag != self.cpu.irq_line) self.cpu.setIrqLine(io.irq_flag);
                self.cpu.step();
            }
            self.line_start = line_end;
        }

        /// Render one visible scanline via the PPU. The BG/sprite compositor is
        /// layered onto the backdrop in M3.4/M3.5.
        fn renderScanline(self: *Self, line: u32) void {
            self.bus.ppu.renderScanline(line);
        }

        /// The visible RGB565 framebuffer for the current display height.
        pub fn framebuffer(self: *const Self) []const u16 {
            const height: u32 = if (self.overscan) 239 else 224;
            return self.bus.ppu.frame(height);
        }
    };
}

/// The default shipped core.
pub const FastConsole = Console(.{ .accuracy = .fast });

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
