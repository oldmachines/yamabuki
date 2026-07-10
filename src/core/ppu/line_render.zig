//! Fast scanline compositor for BG modes 0 and 1, with sprites.
//!
//! Each enabled background layer and the sprite (OBJ) layer are decoded into
//! per-pixel line buffers (palette index + priority), then composited
//! front-to-back by the mode's priority order and written out as RGB565. Tile
//! decoding is comptime-specialized on bit depth so the 2bpp/4bpp planes fold to
//! straight-line shifts with no per-pixel branching on depth.
//!
//! Sprites are evaluated per line with the real 32-sprites and 34-tiles limits;
//! lower OAM index wins on overlap, and each sprite's OBJ priority (0-3) places
//! it in the composite order relative to the BG layers.
//!
//! Modes 2-7 (offset-per-tile, mode 7, hi-res) arrive in later milestones;
//! unsupported modes fall back to the backdrop.

const std = @import("std");
const ppu_mod = @import("ppu.zig");
const Ppu = ppu_mod.Ppu;
const fb_width = ppu_mod.fb_width;

/// One decoded pixel on the current scanline.
const Cell = struct {
    abs: u8 = 0, // absolute CGRAM index
    prio: u2 = 0, // BG tile priority (0/1) or OBJ priority (0-3)
    solid: bool = false,
};

const Src = enum { bg, obj };
/// A layer at a given priority in the composite order. For `bg`, `idx` is the
/// background index and `prio` is the tile-priority bit; for `obj`, `prio` is
/// the OBJ priority level and `idx` is unused.
const Entry = struct { src: Src, idx: u2 = 0, prio: u2 };

fn bg(i: u2, p: u2) Entry {
    return .{ .src = .bg, .idx = i, .prio = p };
}
fn obj(p: u2) Entry {
    return .{ .src = .obj, .prio = p };
}

// Priority orders, front (index 0) to back.
const order_mode0 = [_]Entry{
    obj(3), bg(0, 1), bg(1, 1),
    obj(2), bg(0, 0), bg(1, 0),
    obj(1), bg(2, 1), bg(3, 1),
    obj(0), bg(2, 0), bg(3, 0),
};
const order_mode1 = [_]Entry{
    obj(3),   bg(0, 1), bg(1, 1),
    obj(2),   bg(0, 0), bg(1, 0),
    obj(1),   bg(2, 1), obj(0),
    bg(2, 0),
};
const order_mode1_bg3_front = [_]Entry{
    bg(2, 1),
    obj(3),
    bg(0, 1),
    bg(1, 1),
    obj(2),
    bg(0, 0),
    bg(1, 0),
    obj(1),
    obj(0),
    bg(2, 0),
};

/// Whether a mode's BG layers are planar (modes 0-6) or an affine Mode 7 map.
/// Only `.planar` is rendered today; `.affine` is reserved for M4's Mode 7.
const Kind = enum { planar, affine };

/// One BG layer's fixed configuration within a mode: which BG index it is, its
/// bit depth (kept comptime so the plane decode unrolls), and the palette base
/// that the mode's layout assigns to it.
const LayerDesc = struct { bg: u2, bpp: u3, cgram_base: u16 };

/// A background mode as data: the layers to decode, the front-to-back priority
/// order, and (for mode 1) the alternate order selected by the BG3-priority bit.
/// Modes with no layers render the backdrop. New modes are added here as data
/// rather than as new code arms.
const ModeDesc = struct {
    layers: []const LayerDesc = &.{},
    order: []const Entry = &.{},
    order_bg3_front: ?[]const Entry = null,
    kind: Kind = .planar,
};

const backdrop_mode: ModeDesc = .{};

/// Modes 0-7, indexed by `$2105` BGMODE. Modes 2-7 are backdrop-only until M4
/// fills in their layer descriptors (offset-per-tile, hi-res, Mode 7).
const mode_table = [8]ModeDesc{
    .{ // mode 0: four 2bpp layers, each in its own 32-color palette quadrant.
        .layers = &.{
            .{ .bg = 0, .bpp = 2, .cgram_base = 0 },
            .{ .bg = 1, .bpp = 2, .cgram_base = 32 },
            .{ .bg = 2, .bpp = 2, .cgram_base = 64 },
            .{ .bg = 3, .bpp = 2, .cgram_base = 96 },
        },
        .order = &order_mode0,
    },
    .{ // mode 1: BG1/BG2 4bpp, BG3 2bpp; BG3 can be pulled to the front.
        .layers = &.{
            .{ .bg = 0, .bpp = 4, .cgram_base = 0 },
            .{ .bg = 1, .bpp = 4, .cgram_base = 0 },
            .{ .bg = 2, .bpp = 2, .cgram_base = 0 },
        },
        .order = &order_mode1,
        .order_bg3_front = &order_mode1_bg3_front,
    },
    backdrop_mode,
    backdrop_mode,
    backdrop_mode,
    backdrop_mode,
    backdrop_mode,
    backdrop_mode,
};

pub fn renderLine(ppu: *Ppu, line: u32) void {
    const row = ppu.fb[line * fb_width ..][0..fb_width];

    if (ppu.force_blank) {
        @memset(row, 0);
        return;
    }

    // Brightness-scaled palette (index 0 is the backdrop). Rebuilt only when
    // CGRAM or master brightness changed since the last render; HDMA per-line
    // INIDISP writes re-dirty it, so mid-frame brightness splits stay correct.
    if (ppu.lpal_dirty) {
        for (0..256) |i| ppu.lpal[i] = ppu_mod.scaleBrightness(ppu.cgram[i], ppu.brightness);
        ppu.lpal_dirty = false;
    }

    var bgbuf: [4][fb_width]Cell = undefined;
    var objbuf: [fb_width]Cell = undefined;

    // Runtime-select the mode, then run a body comptime-specialized on its
    // descriptor so each layer's bit depth stays comptime.
    inline for (mode_table, 0..) |md, m| {
        if (ppu.bg_mode == m) {
            renderMode(ppu, line, md, &bgbuf, &objbuf, &ppu.lpal, row);
            return;
        }
    }
}

/// Decode a mode's layers into the line buffers and composite them. `md` is
/// comptime, so `fillBg` monomorphizes per layer bit depth and modes with no
/// layers fold to a plain backdrop fill.
fn renderMode(
    ppu: *Ppu,
    line: u32,
    comptime md: ModeDesc,
    bgbuf: *[4][fb_width]Cell,
    objbuf: *[fb_width]Cell,
    lpal: *const [256]u16,
    row: []u16,
) void {
    if (md.order.len == 0) {
        @memset(row, lpal[0]);
        return;
    }
    inline for (md.layers) |ld| {
        fillBg(ppu, ld.bg, ld.bpp, ld.cgram_base, line, &bgbuf[ld.bg]);
    }
    fillObj(ppu, line, objbuf);

    const order = if (md.order_bg3_front) |alt|
        (if (ppu.bg3_priority) alt else md.order)
    else
        md.order;
    composite(order, bgbuf, objbuf, lpal, row);
}

/// Resolve each pixel by walking the priority order front-to-back, taking the
/// first solid layer at its matching priority (else the backdrop). This is the
/// single seam M4 extends for the sub-screen, windows, mosaic, and color math.
fn composite(
    order: []const Entry,
    bgbuf: *const [4][fb_width]Cell,
    objbuf: *const [fb_width]Cell,
    lpal: *const [256]u16,
    row: []u16,
) void {
    for (0..fb_width) |x| {
        var abs: u8 = 0; // backdrop
        for (order) |e| {
            const cell = if (e.src == .bg) bgbuf[e.idx][x] else objbuf[x];
            if (cell.solid and cell.prio == e.prio) {
                abs = cell.abs;
                break;
            }
        }
        row[x] = lpal[abs];
    }
}

fn clearLine(buf: *[fb_width]Cell) void {
    for (buf) |*c| c.* = .{};
}

/// Decode one BG layer's contribution to the scanline. `comptime bpp` folds the
/// bitplane math; `cgram_base` is the mode-dependent palette offset for this BG.
fn fillBg(ppu: *Ppu, bg_index: usize, comptime bpp: u3, cgram_base: u16, line: u32, buf: *[fb_width]Cell) void {
    if (ppu.main_screen & (@as(u8, 1) << @intCast(bg_index)) == 0) {
        clearLine(buf);
        return;
    }

    const layer = ppu.bg[bg_index];
    const tile_px: u16 = if (layer.tile16) 16 else 8;
    const width_tiles: u16 = if (layer.map_size & 1 != 0) 64 else 32;
    const height_tiles: u16 = if (layer.map_size & 2 != 0) 64 else 32;
    const bg_w: u16 = width_tiles * tile_px;
    const bg_h: u16 = height_tiles * tile_px;
    const words_per_tile: u16 = @as(u16, bpp) * 4;
    const pal_size: u8 = 1 << bpp;

    const sy: u16 = @intCast((line + layer.vofs) & (bg_h - 1));
    const tile_row = sy / tile_px;

    for (0..fb_width) |x| {
        const sx: u16 = @intCast((@as(u32, @intCast(x)) + layer.hofs) & (bg_w - 1));
        const tile_col = sx / tile_px;

        var screen: u16 = 0;
        if (tile_col & 0x20 != 0) screen += 1;
        if (tile_row & 0x20 != 0) screen += if (width_tiles == 64) 2 else 1;
        const map_addr = (layer.map_base + screen * 0x400 +
            ((tile_row & 0x1F) << 5) + (tile_col & 0x1F)) & 0x7FFF;
        const entry = ppu.vram[map_addr];

        var tile_num: u16 = entry & 0x3FF;
        const pal_group: u16 = (entry >> 10) & 7;
        const prio: u2 = @truncate(entry >> 13);
        const xflip = entry & 0x4000 != 0;
        const yflip = entry & 0x8000 != 0;

        var px: u16 = sx % tile_px;
        var py: u16 = sy % tile_px;
        if (xflip) px = tile_px - 1 - px;
        if (yflip) py = tile_px - 1 - py;
        if (layer.tile16) {
            if (px >= 8) tile_num += 1;
            if (py >= 8) tile_num += 16;
            px &= 7;
            py &= 7;
        }

        const color = decodePlanar(ppu, bpp, layer.char_base +% tile_num *% words_per_tile +% py, @intCast(px));
        buf[x] = if (color == 0)
            .{}
        else
            .{ .abs = @intCast(cgram_base + pal_group * pal_size + color), .prio = prio, .solid = true };
    }
}

/// OBJ size table: {small_w, small_h, large_w, large_h} per OBSEL size (0-7).
const obj_sizes = [8][4]u8{
    .{ 8, 8, 16, 16 },
    .{ 8, 8, 32, 32 },
    .{ 8, 8, 64, 64 },
    .{ 16, 16, 32, 32 },
    .{ 16, 16, 64, 64 },
    .{ 32, 32, 64, 64 },
    .{ 16, 32, 32, 64 },
    .{ 16, 32, 32, 32 },
};

/// Evaluate the 128 sprites against this scanline into the OBJ line buffer,
/// honoring the 32-sprite and 34-tile-per-line hardware limits.
fn fillObj(ppu: *Ppu, line: u32, buf: *[fb_width]Cell) void {
    clearLine(buf);
    if (ppu.main_screen & 0x10 == 0) return; // OBJ layer disabled on main screen

    const sz = obj_sizes[ppu.obj_size];
    var in_range: u32 = 0;
    var tiles: u32 = 0;

    for (0..128) |i| {
        const base = i * 4;
        const attr = ppu.oam[base + 3];
        const high = ppu.oam[0x200 + (i >> 2)];
        const hb: u2 = @truncate(high >> @intCast((i & 3) * 2));
        const large = hb & 2 != 0;
        const w: u16 = if (large) sz[2] else sz[0];
        const h: u16 = if (large) sz[3] else sz[1];

        const y: u16 = ppu.oam[base + 1];
        const dy: u16 = (@as(u16, @truncate(line)) -% y) & 0xFF;
        if (dy >= h) continue; // sprite not on this scanline

        in_range += 1;
        if (in_range > 32) {
            ppu.obj_range_over = true;
            break;
        }

        // 9-bit signed X position.
        var xpos: i32 = @as(i32, ppu.oam[base + 0]) | (if (hb & 1 != 0) @as(i32, 0x100) else 0);
        if (xpos >= 256) xpos -= 512;

        const tile_lo: u16 = ppu.oam[base + 2];
        const name_hi: u16 = attr & 1;
        const pal: u16 = (attr >> 1) & 7;
        const oprio: u2 = @truncate(attr >> 4);
        const xflip = attr & 0x40 != 0;
        const yflip = attr & 0x80 != 0;

        var sy: u16 = dy;
        if (yflip) sy = h - 1 - dy;
        const trow = sy >> 3;
        const fine_y = sy & 7;

        const cols: u16 = w >> 3;
        const tbase: u16 = ppu.obj_char_base + (if (name_hi != 0) ppu.obj_char_gap else 0);

        var col: u16 = 0;
        var overflow = false;
        while (col < cols) : (col += 1) {
            tiles += 1;
            if (tiles > 34) {
                ppu.obj_time_over = true;
                overflow = true;
                break;
            }
            const scr_col = if (xflip) cols - 1 - col else col;
            // Tile number walks the 16-wide OBJ name grid with byte wrap.
            var chr = (tile_lo +% trow *% 0x10) & 0xFF;
            chr = (chr & 0xF0) | ((chr +% scr_col) & 0x0F);
            const char_word = tbase +% chr *% 16;

            const px0 = xpos + @as(i32, @intCast(col * 8));
            for (0..8) |p| {
                const sx = px0 + @as(i32, @intCast(p));
                if (sx < 0 or sx >= fb_width) continue;
                const fx: u3 = @intCast(if (xflip) 7 - p else p);
                const color = decodePlanar(ppu, 4, char_word +% fine_y, fx);
                if (color == 0) continue;
                const ux: usize = @intCast(sx);
                if (buf[ux].solid) continue; // lower OAM index already claimed this pixel
                buf[ux] = .{ .abs = @intCast(128 + pal * 16 + color), .prio = oprio, .solid = true };
            }
        }
        if (overflow) break;
    }
}

/// Decode one planar pixel (2bpp or 4bpp) at bit position `px` (0 = leftmost)
/// from the tile row word(s) starting at `char_addr`.
inline fn decodePlanar(ppu: *Ppu, comptime bpp: u3, char_addr: u16, px: u3) u8 {
    const bit: u4 = @intCast(7 - @as(u4, px));
    var color: u8 = 0;
    inline for (0..bpp / 2) |pair| {
        const w = ppu.vram[(char_addr +% pair * 8) & 0x7FFF];
        const lo: u8 = @intCast((w >> bit) & 1);
        const hi: u8 = @intCast((w >> (@as(u4, 8) + bit)) & 1);
        color |= lo << @intCast(pair * 2);
        color |= hi << @intCast(pair * 2 + 1);
    }
    return color;
}

// --- tests ---------------------------------------------------------------

test {
    std.testing.refAllDecls(@This());
}

test "mode 0 renders a single BG1 tile pixel" {
    var ppu: Ppu = .init;
    ppu.bg_mode = 0;
    ppu.main_screen = 0x01;
    ppu.force_blank = false;
    ppu.brightness = 15;
    ppu.bg[0] = .{ .map_base = 0x400, .char_base = 0, .map_size = 0 };
    ppu.vram[0x400] = 0x0000;
    ppu.vram[0] = 0x0080; // pixel x=0 -> color 1
    ppu.cgram[0] = 0x0000;
    ppu.cgram[1] = 0x7C00; // blue
    ppu.postLoad();

    ppu.renderScanline(0);
    try std.testing.expectEqual(@as(u16, 0x001F), ppu.fb[0]);
    try std.testing.expectEqual(@as(u16, 0x0000), ppu.fb[1]);
}

test "higher priority tile wins the composite" {
    var ppu: Ppu = .init;
    ppu.bg_mode = 1;
    ppu.main_screen = 0x03;
    ppu.force_blank = false;
    ppu.brightness = 15;
    ppu.bg[0] = .{ .map_base = 0x400, .char_base = 0x0000 };
    ppu.bg[1] = .{ .map_base = 0x500, .char_base = 0x0100 };
    ppu.vram[0x400] = 0x0000; // BG1 prio 0
    ppu.vram[0x500] = 0x2000; // BG2 prio 1
    ppu.vram[0x0000] = 0x0080;
    ppu.vram[0x0100] = 0x0080;
    ppu.cgram[0] = 0;
    ppu.cgram[1] = 0x001F;
    ppu.postLoad();

    ppu.renderScanline(0);
    try std.testing.expect(ppu.fb[0] != 0);
}

test "sprite renders over the backdrop with transparency" {
    var ppu: Ppu = .init;
    ppu.bg_mode = 1;
    ppu.main_screen = 0x10; // OBJ only
    ppu.force_blank = false;
    ppu.brightness = 15;
    ppu.obj_size = 0; // 8x8 small
    ppu.obj_char_base = 0;

    // Sprite 0 at (10, 0), tile 0, palette 0, priority 2, no flip.
    ppu.oam[0] = 10; // X low
    ppu.oam[1] = 0; // Y
    ppu.oam[2] = 0; // tile
    ppu.oam[3] = 0x20; // priority 2
    ppu.oam[0x200] = 0; // high table: X sign 0, small size

    ppu.vram[0] = 0x0080; // tile 0 row 0: leftmost pixel color 1
    ppu.cgram[0] = 0; // backdrop black
    ppu.cgram[128 + 1] = 0x03E0; // OBJ palette color 1 = green
    ppu.postLoad();

    ppu.renderScanline(0);
    try std.testing.expectEqual(@as(u16, 0x07E0), ppu.fb[10]); // green sprite pixel
    try std.testing.expectEqual(@as(u16, 0x0000), ppu.fb[9]); // backdrop
    try std.testing.expectEqual(@as(u16, 0x0000), ppu.fb[11]); // transparent sprite pixel
}

test "lower OAM index wins on sprite overlap" {
    var ppu: Ppu = .init;
    ppu.bg_mode = 1;
    ppu.main_screen = 0x10;
    ppu.force_blank = false;
    ppu.brightness = 15;
    ppu.obj_size = 0;
    ppu.obj_char_base = 0;

    // Two 8x8 sprites at the same spot; sprite 0 (green) must beat sprite 1 (red).
    ppu.oam[0] = 20;
    ppu.oam[1] = 0;
    ppu.oam[2] = 0;
    ppu.oam[3] = 0x20; // pal 0, prio 2
    ppu.oam[4] = 20;
    ppu.oam[5] = 0;
    ppu.oam[6] = 0;
    ppu.oam[7] = 0x22; // pal 1, prio 2
    ppu.oam[0x200] = 0;

    ppu.vram[0] = 0x0080; // color 1 leftmost
    ppu.cgram[128 + 1] = 0x03E0; // pal0 color1 green
    ppu.cgram[128 + 16 + 1] = 0x001F; // pal1 color1 red
    ppu.postLoad();

    ppu.renderScanline(0);
    try std.testing.expectEqual(@as(u16, 0x07E0), ppu.fb[20]); // green (sprite 0)
}
