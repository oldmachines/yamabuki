//! Picture Processing Unit: register file, video memories (VRAM/OAM/CGRAM),
//! and the fast scanline renderer.
//!
//! This module owns the PPU register state and the memory ports ($2100-$213F).
//! The pixel pipeline is split out into `line_render.zig`, which `renderScanline`
//! delegates to for the backdrop + BG/sprite compositor. Color is converted to
//! RGB565 at CGRAM-write time so the renderer and the handheld display path never
//! touch 15-bit BGR.

const std = @import("std");
const line_render = @import("line_render.zig");

/// Visible framebuffer dimensions. Width is 256 (hi-res 512 is M4); height is
/// the maximum (overscan) — 224-line output uses the first 224 rows.
pub const fb_width: u32 = 256;
pub const fb_height: u32 = 239;

/// Per-background-layer configuration latched from the register file.
pub const BgLayer = struct {
    /// Tilemap base, in VRAM words.
    map_base: u16 = 0,
    /// Screen size: 0=32x32, 1=64x32, 2=32x64, 3=64x64 tiles.
    map_size: u2 = 0,
    /// Character (tile) data base, in VRAM words.
    char_base: u16 = 0,
    /// Horizontal / vertical scroll (10-bit, stored wide).
    hofs: u16 = 0,
    vofs: u16 = 0,
    /// 16x16 tiles when set, else 8x8.
    tile16: bool = false,
};

pub const Ppu = struct {
    // Derived state: the RGB565 palette and the brightness-scaled line palette
    // are rebuilt from cgram, and the framebuffer is output, so none is part of
    // the saved state.
    pub const serialize_skip = .{ "palette", "lpal", "lpal_dirty", "fb" };

    // --- video memories ---------------------------------------------------
    /// 64 KiB VRAM as 32768 words.
    vram: [0x8000]u16,
    /// 256 palette entries, raw 15-bit BGR.
    cgram: [256]u16,
    /// Object attribute memory: 512-byte low table + 32-byte high table.
    oam: [0x220]u8,

    // --- derived outputs (rebuilt, not serialized) ------------------------
    /// cgram converted to RGB565 at write time.
    palette: [256]u16,
    /// Brightness-scaled RGB565 palette for the current line; rebuilt lazily
    /// only when CGRAM or master brightness changes (see `lpal_dirty`).
    lpal: [256]u16,
    /// Set when `lpal` must be recomputed (CGRAM or INIDISP brightness write).
    lpal_dirty: bool,
    /// RGB565 framebuffer, row-major, fb_width * fb_height.
    fb: [fb_width * fb_height]u16,

    // --- display control --------------------------------------------------
    force_blank: bool, // $2100 bit7
    brightness: u4, // $2100 bits 0-3
    bg_mode: u3, // $2105 bits 0-2
    bg3_priority: bool, // $2105 bit3
    mosaic: u8, // $2106

    bg: [4]BgLayer,

    // --- object / sprite config (used from M3.5) --------------------------
    obj_char_base: u16, // $2101 bits 0-2 -> base in words
    obj_char_gap: u16, // $2101 bits 3-4 -> second table offset
    obj_size: u3, // $2101 bits 5-7

    // --- layer enables ----------------------------------------------------
    main_screen: u8, // $212C TM
    sub_screen: u8, // $212D TS

    // --- windows ($2123-$212B, $212E/$212F) -------------------------------
    // Per-layer select nibble: bit0 W1 invert, bit1 W1 enable, bit2 W2 invert,
    // bit3 W2 enable. BG1/BG3/OBJ low nibble, BG2/BG4/color high nibble.
    w12sel: u8, // $2123 BG1/BG2
    w34sel: u8, // $2124 BG3/BG4
    wobjsel: u8, // $2125 OBJ/color-window
    wh0: u8, // $2126 window 1 left
    wh1: u8, // $2127 window 1 right
    wh2: u8, // $2128 window 2 left
    wh3: u8, // $2129 window 2 right
    wbglog: u8, // $212A 2 bits/BG: 0=OR 1=AND 2=XOR 3=XNOR
    wobjlog: u8, // $212B OBJ bits0-1, color bits2-3
    tmw: u8, // $212E main-screen window masking (bit0 BG1 .. bit4 OBJ)
    tsw: u8, // $212F sub-screen window masking (color math, M4.5)

    // --- VRAM access port -------------------------------------------------
    vram_addr: u16, // $2116/$2117 word address
    vram_inc_high: bool, // $2115 bit7: increment on high-byte write
    vram_inc_step: u16, // $2115 bits 0-1
    vram_remap: u2, // $2115 bits 2-3
    vram_read_latch: u16, // read prefetch buffer

    // --- CGRAM access port ------------------------------------------------
    cgram_addr: u8, // $2121
    cgram_flip: bool, // write-twice toggle
    cgram_latch: u8, // low byte held between the two writes

    // --- OAM access port --------------------------------------------------
    oam_reload: u9, // $2102/$2103 word address reload value
    oam_addr: u10, // running byte address
    oam_latch: u8, // even-byte write buffer (low table)

    // --- shared scroll write latch ($210D-$2114) --------------------------
    scroll_latch: u8,
    scroll_latch_h: u8,

    // --- sprite evaluation status ($213E) ---------------------------------
    obj_range_over: bool, // >32 sprites on a line
    obj_time_over: bool, // >34 sprite tiles on a line

    pub const init: Ppu = .{
        .vram = @splat(0),
        .cgram = @splat(0),
        .oam = @splat(0),
        .palette = @splat(0),
        .lpal = @splat(0),
        .lpal_dirty = true,
        .fb = @splat(0),
        .force_blank = true,
        .brightness = 0,
        .bg_mode = 0,
        .bg3_priority = false,
        .mosaic = 0,
        .bg = .{ .{}, .{}, .{}, .{} },
        .obj_char_base = 0,
        .obj_char_gap = 0,
        .obj_size = 0,
        .main_screen = 0,
        .sub_screen = 0,
        .w12sel = 0,
        .w34sel = 0,
        .wobjsel = 0,
        .wh0 = 0,
        .wh1 = 0,
        .wh2 = 0,
        .wh3 = 0,
        .wbglog = 0,
        .wobjlog = 0,
        .tmw = 0,
        .tsw = 0,
        .vram_addr = 0,
        .vram_inc_high = true,
        .vram_inc_step = 1,
        .vram_remap = 0,
        .vram_read_latch = 0,
        .cgram_addr = 0,
        .cgram_flip = false,
        .cgram_latch = 0,
        .oam_reload = 0,
        .oam_addr = 0,
        .oam_latch = 0,
        .scroll_latch = 0,
        .scroll_latch_h = 0,
        .obj_range_over = false,
        .obj_time_over = false,
    };

    /// Rebuild the RGB565 palette from CGRAM after deserialization. The
    /// brightness-scaled line palette is marked stale so the next render rebuilds it.
    pub fn postLoad(self: *Ppu) void {
        for (self.cgram, 0..) |c, i| self.palette[i] = bgr15to565(c);
        self.lpal_dirty = true;
    }

    // --- register writes ($2100-$213F) ------------------------------------

    pub fn writeReg(self: *Ppu, addr: u16, value: u8) void {
        switch (addr & 0xFF) {
            0x00 => { // INIDISP
                self.force_blank = value & 0x80 != 0;
                self.brightness = @truncate(value);
                self.lpal_dirty = true; // brightness feeds the line palette
            },
            0x01 => { // OBSEL
                self.obj_size = @truncate(value >> 5);
                // Second name table sits at base + (nameselect+1) * 0x1000 words.
                self.obj_char_gap = (@as(u16, (value >> 3) & 3) + 1) << 12;
                self.obj_char_base = @as(u16, value & 0x07) << 13; // (bits 0-2) * 0x2000 words
            },
            0x02 => self.oam_reload = (self.oam_reload & 0x100) | value, // OAMADDL
            0x03 => { // OAMADDH
                self.oam_reload = (@as(u9, value & 1) << 8) | (self.oam_reload & 0xFF);
                self.oam_addr = @as(u10, self.oam_reload) << 1;
            },
            0x04 => self.writeOam(value), // OAMDATA
            0x05 => { // BGMODE
                self.bg_mode = @truncate(value);
                self.bg3_priority = value & 0x08 != 0;
                self.bg[0].tile16 = value & 0x10 != 0;
                self.bg[1].tile16 = value & 0x20 != 0;
                self.bg[2].tile16 = value & 0x40 != 0;
                self.bg[3].tile16 = value & 0x80 != 0;
            },
            0x06 => self.mosaic = value, // MOSAIC
            0x07, 0x08, 0x09, 0x0A => { // BGxSC
                const i = (addr & 0xFF) - 0x07;
                self.bg[i].map_base = @as(u16, value & 0xFC) << 8; // (value>>2)<<10 words
                self.bg[i].map_size = @truncate(value);
            },
            0x0B => { // BG12NBA
                self.bg[0].char_base = @as(u16, value & 0x0F) << 12;
                self.bg[1].char_base = @as(u16, value >> 4) << 12;
            },
            0x0C => { // BG34NBA
                self.bg[2].char_base = @as(u16, value & 0x0F) << 12;
                self.bg[3].char_base = @as(u16, value >> 4) << 12;
            },
            0x0D => self.writeHofs(0, value), // BG1HOFS
            0x0E => self.writeVofs(0, value), // BG1VOFS
            0x0F => self.writeHofs(1, value),
            0x10 => self.writeVofs(1, value),
            0x11 => self.writeHofs(2, value),
            0x12 => self.writeVofs(2, value),
            0x13 => self.writeHofs(3, value),
            0x14 => self.writeVofs(3, value),
            0x15 => { // VMAIN
                self.vram_inc_high = value & 0x80 != 0;
                self.vram_remap = @truncate(value >> 2);
                self.vram_inc_step = switch (@as(u2, @truncate(value))) {
                    0 => 1,
                    1 => 32,
                    2, 3 => 128,
                };
            },
            0x16 => self.vram_addr = (self.vram_addr & 0xFF00) | value, // VMADDL
            0x17 => self.vram_addr = (self.vram_addr & 0x00FF) | (@as(u16, value) << 8), // VMADDH
            0x18 => self.writeVramLow(value), // VMDATAL
            0x19 => self.writeVramHigh(value), // VMDATAH
            0x21 => { // CGADD
                self.cgram_addr = value;
                self.cgram_flip = false;
            },
            0x22 => self.writeCgram(value), // CGDATA
            0x23 => self.w12sel = value, // W12SEL
            0x24 => self.w34sel = value, // W34SEL
            0x25 => self.wobjsel = value, // WOBJSEL
            0x26 => self.wh0 = value, // WH0 (window 1 left)
            0x27 => self.wh1 = value, // WH1 (window 1 right)
            0x28 => self.wh2 = value, // WH2 (window 2 left)
            0x29 => self.wh3 = value, // WH3 (window 2 right)
            0x2A => self.wbglog = value, // WBGLOG
            0x2B => self.wobjlog = value, // WOBJLOG
            0x2C => self.main_screen = value, // TM
            0x2D => self.sub_screen = value, // TS
            0x2E => self.tmw = value, // TMW (main-screen window mask)
            0x2F => self.tsw = value, // TSW (sub-screen window mask)
            // Mode 7, color math, SETINI: latched in later milestones.
            else => {},
        }
    }

    // --- register reads ($2100-$213F) -------------------------------------

    pub fn readReg(self: *Ppu, addr: u16, mdr: u8) u8 {
        return switch (addr & 0xFF) {
            0x38 => self.readOam(), // OAMDATAREAD
            0x39 => self.readVramLow(), // VMDATALREAD
            0x3A => self.readVramHigh(), // VMDATAHREAD
            0x3B => self.readCgram(mdr), // CGDATAREAD
            0x3E => (if (self.obj_time_over) @as(u8, 0x80) else 0) |
                (if (self.obj_range_over) @as(u8, 0x40) else 0) |
                (mdr & 0x30) | 0x01, // STAT77: overflow flags + PPU1 version 1
            else => mdr, // open bus (write-only / not-yet-modeled)
        };
    }

    // --- scroll ($210D-$2114): the shared write-twice latch ----------------

    fn writeHofs(self: *Ppu, i: usize, value: u8) void {
        self.bg[i].hofs = (@as(u16, value) << 8) |
            (self.scroll_latch & ~@as(u8, 7)) |
            (self.scroll_latch_h & 7);
        self.scroll_latch = value;
        self.scroll_latch_h = value;
    }

    fn writeVofs(self: *Ppu, i: usize, value: u8) void {
        self.bg[i].vofs = (@as(u16, value) << 8) | self.scroll_latch;
        self.scroll_latch = value;
    }

    // --- VRAM port --------------------------------------------------------

    /// Address remapping selected by VMAIN bits 3-2 (rotates the low address
    /// bits so linear tile writes land contiguously for a given bit depth).
    fn vramTranslate(self: *const Ppu) u16 {
        const a = self.vram_addr;
        return switch (self.vram_remap) {
            0 => a,
            1 => (a & 0xFF00) | ((a & 0x00E0) >> 5) | ((a & 0x001F) << 3),
            2 => (a & 0xFE00) | ((a & 0x01C0) >> 6) | ((a & 0x003F) << 3),
            3 => (a & 0xFC00) | ((a & 0x0380) >> 7) | ((a & 0x007F) << 3),
        };
    }

    fn vramStep(self: *Ppu, on_high: bool) void {
        if (on_high == self.vram_inc_high) self.vram_addr +%= self.vram_inc_step;
    }

    fn writeVramLow(self: *Ppu, value: u8) void {
        const a = self.vramTranslate() & 0x7FFF;
        self.vram[a] = (self.vram[a] & 0xFF00) | value;
        self.vramStep(false);
    }

    fn writeVramHigh(self: *Ppu, value: u8) void {
        const a = self.vramTranslate() & 0x7FFF;
        self.vram[a] = (self.vram[a] & 0x00FF) | (@as(u16, value) << 8);
        self.vramStep(true);
    }

    fn readVramLow(self: *Ppu) u8 {
        const v: u8 = @truncate(self.vram_read_latch);
        self.vram_read_latch = self.vram[self.vramTranslate() & 0x7FFF];
        self.vramStep(false);
        return v;
    }

    fn readVramHigh(self: *Ppu) u8 {
        const v: u8 = @truncate(self.vram_read_latch >> 8);
        self.vram_read_latch = self.vram[self.vramTranslate() & 0x7FFF];
        self.vramStep(true);
        return v;
    }

    // --- CGRAM port -------------------------------------------------------

    fn writeCgram(self: *Ppu, value: u8) void {
        if (!self.cgram_flip) {
            self.cgram_latch = value;
            self.cgram_flip = true;
        } else {
            const color = (@as(u16, value & 0x7F) << 8) | self.cgram_latch;
            self.cgram[self.cgram_addr] = color;
            self.palette[self.cgram_addr] = bgr15to565(color);
            self.lpal_dirty = true; // line palette derives from cgram
            self.cgram_addr +%= 1;
            self.cgram_flip = false;
        }
    }

    fn readCgram(self: *Ppu, mdr: u8) u8 {
        const c = self.cgram[self.cgram_addr];
        var v: u8 = undefined;
        if (!self.cgram_flip) {
            v = @truncate(c);
            self.cgram_flip = true;
        } else {
            v = (mdr & 0x80) | @as(u8, @truncate(c >> 8));
            self.cgram_addr +%= 1;
            self.cgram_flip = false;
        }
        return v;
    }

    // --- OAM port ---------------------------------------------------------

    fn writeOam(self: *Ppu, value: u8) void {
        const a = self.oam_addr;
        if (a < 0x200) {
            // Low table: even byte is buffered, odd byte commits the pair.
            if (a & 1 == 0) {
                self.oam_latch = value;
            } else {
                self.oam[a - 1] = self.oam_latch;
                self.oam[a] = value;
            }
        } else {
            // High table: written directly.
            self.oam[a & 0x21F] = value;
        }
        self.oam_addr = if (a >= 0x21F) 0 else a + 1;
    }

    fn readOam(self: *Ppu) u8 {
        const a = self.oam_addr;
        const v = self.oam[a & 0x21F];
        self.oam_addr = if (a >= 0x21F) 0 else a + 1;
        return v;
    }

    // --- rendering --------------------------------------------------------

    /// Render one visible scanline into the framebuffer: force-blank/backdrop
    /// handling plus the BG and sprite compositor.
    pub fn renderScanline(self: *Ppu, line: u32) void {
        if (line >= fb_height) return;
        line_render.renderLine(self, line);
    }

    /// Visible framebuffer for the current display height.
    pub fn frame(self: *const Ppu, height: u32) []const u16 {
        return self.fb[0 .. fb_width * height];
    }
};

/// Pack 5-bit R/G/B channels into RGB565, widening green to 6 bits. Shared by
/// every BGR→565 conversion so the pack layout lives in one place (color math
/// in M4 becomes a third caller).
fn pack565(r5: u16, g5: u16, b5: u16) u16 {
    const g6: u16 = (g5 << 1) | (g5 >> 4);
    return (r5 << 11) | (g6 << 5) | b5;
}

/// 15-bit BGR (SNES CGRAM) → RGB565.
fn bgr15to565(c: u16) u16 {
    return pack565(c & 0x1F, (c >> 5) & 0x1F, (c >> 10) & 0x1F);
}

/// Apply INIDISP master brightness (0-15) to a 15-bit BGR color and pack to 565.
pub fn scaleBrightness(c: u16, bright: u4) u16 {
    const num: u16 = bright;
    return pack565(
        ((c & 0x1F) * num) / 15,
        (((c >> 5) & 0x1F) * num) / 15,
        (((c >> 10) & 0x1F) * num) / 15,
    );
}

// --- tests ---------------------------------------------------------------

test {
    std.testing.refAllDecls(@This());
}

test "cgram write-twice builds a 565 palette entry" {
    var ppu: Ppu = .init;
    ppu.writeReg(0x2121, 1); // CGADD = 1
    ppu.writeReg(0x2122, 0x1F); // low byte: red = 31
    ppu.writeReg(0x2122, 0x00); // high byte: green/blue = 0
    try std.testing.expectEqual(@as(u16, 0x001F), ppu.cgram[1]);
    try std.testing.expectEqual(@as(u16, 0xF800), ppu.palette[1]); // pure red 565
    // address auto-incremented past entry 1
    try std.testing.expectEqual(@as(u8, 2), ppu.cgram_addr);
}

test "vram word port with autoincrement" {
    var ppu: Ppu = .init;
    ppu.writeReg(0x2115, 0x80); // VMAIN: inc after high, step 1, no remap
    ppu.writeReg(0x2116, 0x00); // addr low
    ppu.writeReg(0x2117, 0x00); // addr high
    ppu.writeReg(0x2118, 0x34); // data low
    ppu.writeReg(0x2119, 0x12); // data high -> increments
    try std.testing.expectEqual(@as(u16, 0x1234), ppu.vram[0]);
    try std.testing.expectEqual(@as(u16, 1), ppu.vram_addr);
}

test "oam sequential write via data port" {
    var ppu: Ppu = .init;
    ppu.writeReg(0x2102, 0x00); // OAMADDL word 0
    ppu.writeReg(0x2103, 0x00); // OAMADDH -> reload byte addr 0
    ppu.writeReg(0x2104, 0xAA); // even: buffered
    ppu.writeReg(0x2104, 0xBB); // odd: commits pair
    try std.testing.expectEqual(@as(u8, 0xAA), ppu.oam[0]);
    try std.testing.expectEqual(@as(u8, 0xBB), ppu.oam[1]);
    try std.testing.expectEqual(@as(u10, 2), ppu.oam_addr);
}

test "window registers latch" {
    var ppu: Ppu = .init;
    ppu.writeReg(0x2123, 0x03); // W12SEL: BG1 W1 enable+invert
    ppu.writeReg(0x2126, 40); // WH0 window 1 left
    ppu.writeReg(0x2127, 200); // WH1 window 1 right
    ppu.writeReg(0x212A, 0x02); // WBGLOG: BG1 = XOR
    ppu.writeReg(0x212E, 0x11); // TMW: BG1 + OBJ
    ppu.writeReg(0x212F, 0x01); // TSW: BG1
    try std.testing.expectEqual(@as(u8, 0x03), ppu.w12sel);
    try std.testing.expectEqual(@as(u8, 40), ppu.wh0);
    try std.testing.expectEqual(@as(u8, 200), ppu.wh1);
    try std.testing.expectEqual(@as(u8, 0x02), ppu.wbglog);
    try std.testing.expectEqual(@as(u8, 0x11), ppu.tmw);
    try std.testing.expectEqual(@as(u8, 0x01), ppu.tsw);
}

test "backdrop render fills the scanline" {
    var ppu: Ppu = .init;
    ppu.writeReg(0x2121, 0); // CGADD 0
    ppu.writeReg(0x2122, 0x00);
    ppu.writeReg(0x2122, 0x7C); // color 0 = blue (b=31)
    ppu.writeReg(0x2100, 0x0F); // full brightness, no force blank
    ppu.renderScanline(0);
    try std.testing.expectEqual(@as(u16, 0x001F), ppu.fb[0]); // pure blue 565
    try std.testing.expectEqual(ppu.fb[0], ppu.fb[fb_width - 1]);
    // force blank -> black
    ppu.writeReg(0x2100, 0x80);
    ppu.renderScanline(0);
    try std.testing.expectEqual(@as(u16, 0), ppu.fb[0]);
}

test "ppu serialize skips derived palette, postLoad rebuilds it" {
    const serialize = @import("../serialize.zig");
    var ppu: Ppu = .init;
    ppu.writeReg(0x2121, 5);
    ppu.writeReg(0x2122, 0xFF);
    ppu.writeReg(0x2122, 0x7F); // white

    const size = comptime serialize.byteSize(Ppu);
    const buf = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(buf);
    _ = serialize.write(Ppu, &ppu, buf);

    var ppu2: Ppu = .init;
    _ = try serialize.read(Ppu, &ppu2, buf);
    // palette is skipped, so it is still all-zero until postLoad rebuilds it.
    try std.testing.expectEqual(@as(u16, 0), ppu2.palette[5]);
    ppu2.postLoad();
    try std.testing.expectEqual(ppu.palette[5], ppu2.palette[5]);
}
