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
// Modes 2-5 share a two-BG priority order (mode 1's, without the BG3 entries).
const order_2bg = [_]Entry{
    obj(3), bg(0, 1), bg(1, 1),
    obj(2), bg(0, 0), bg(1, 0),
    obj(1), obj(0),
};

/// Whether a mode's BG layers are planar (modes 0-6) or an affine Mode 7 map.
/// Only `.planar` is rendered today; `.affine` is reserved for M4's Mode 7.
const Kind = enum { planar, affine };

/// Offset-per-tile behavior for a mode's BG1/BG2 layers. `.hv` (modes 2/6) reads
/// separate horizontal and vertical offset entries from BG3's tilemap; `.single`
/// (mode 4) reads one entry whose bit 15 selects H vs V.
const OptMode = enum { none, hv, single };

/// One BG layer's fixed configuration within a mode: which BG index it is, its
/// bit depth (kept comptime so the plane decode unrolls), and the palette base
/// that the mode's layout assigns to it.
const LayerDesc = struct { bg: u2, bpp: u4, cgram_base: u16 };

/// A background mode as data: the layers to decode, the front-to-back priority
/// order, and (for mode 1) the alternate order selected by the BG3-priority bit.
/// Modes with no layers render the backdrop. New modes are added here as data
/// rather than as new code arms.
const ModeDesc = struct {
    layers: []const LayerDesc = &.{},
    order: []const Entry = &.{},
    order_bg3_front: ?[]const Entry = null,
    kind: Kind = .planar,
    opt: OptMode = .none,
};

const backdrop_mode: ModeDesc = .{};

/// Modes 0-7, indexed by `$2105` BGMODE. Modes 5/6 (hi-res) and 7 (affine) are
/// backdrop-only until later M4 slices fill in their descriptors. Modes 2 and 4
/// are rendered here as plain planar layers; their offset-per-tile behavior
/// (which needs BG3's map) arrives in the offset-per-tile slice.
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
    .{ // mode 2: BG1/BG2 4bpp with offset-per-tile (BG3 supplies H+V offsets).
        .layers = &.{
            .{ .bg = 0, .bpp = 4, .cgram_base = 0 },
            .{ .bg = 1, .bpp = 4, .cgram_base = 0 },
        },
        .order = &order_2bg,
        .opt = .hv,
    },
    .{ // mode 3: BG1 8bpp, BG2 4bpp.
        .layers = &.{
            .{ .bg = 0, .bpp = 8, .cgram_base = 0 },
            .{ .bg = 1, .bpp = 4, .cgram_base = 0 },
        },
        .order = &order_2bg,
    },
    .{ // mode 4: BG1 8bpp, BG2 2bpp with single-value offset-per-tile.
        .layers = &.{
            .{ .bg = 0, .bpp = 8, .cgram_base = 0 },
            .{ .bg = 1, .bpp = 2, .cgram_base = 0 },
        },
        .order = &order_2bg,
        .opt = .single,
    },
    backdrop_mode, // mode 5: hi-res (later slice)
    backdrop_mode, // mode 6: hi-res + offset-per-tile (later slice)
    backdrop_mode, // mode 7: affine (later slice)
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
        fillBg(ppu, ld.bg, ld.bpp, ld.cgram_base, md.opt, line, &bgbuf[ld.bg]);
    }
    fillObj(ppu, line, objbuf);

    const order = if (md.order_bg3_front) |alt|
        (if (ppu.bg3_priority) alt else md.order)
    else
        md.order;

    // Windows only matter when a layer is masked on the main screen ($212E TMW).
    // When TMW is zero the compositor short-circuits and the mask is never read.
    var winmask: [5][fb_width]bool = undefined;
    if (ppu.tmw != 0) computeWindows(ppu, &winmask);
    composite(order, bgbuf, objbuf, lpal, row, &winmask, ppu.tmw);
}

/// Compute, per layer (0-3 = BG1-4, 4 = OBJ), whether each screen pixel lies in
/// that layer's combined window region. Window 1 is [WH0,WH1], window 2 is
/// [WH2,WH3]; each can be enabled and inverted, and the two combine by the
/// layer's logic op (OR/AND/XOR/XNOR). A layer with no enabled window is never
/// masked. Recomputed per line, so HDMA'd window edges take effect per scanline.
fn computeWindows(ppu: *const Ppu, mask: *[5][fb_width]bool) void {
    for (0..5) |layer| {
        const sel: u8 = switch (layer) {
            0 => ppu.w12sel & 0x0F,
            1 => ppu.w12sel >> 4,
            2 => ppu.w34sel & 0x0F,
            3 => ppu.w34sel >> 4,
            else => ppu.wobjsel & 0x0F,
        };
        const w1_inv = sel & 0x01 != 0;
        const w1_en = sel & 0x02 != 0;
        const w2_inv = sel & 0x04 != 0;
        const w2_en = sel & 0x08 != 0;
        const logic: u2 = switch (layer) {
            0...3 => @truncate(ppu.wbglog >> @intCast(layer * 2)),
            else => @truncate(ppu.wobjlog),
        };

        for (0..fb_width) |x| {
            const xi: u8 = @intCast(x);
            var a = xi >= ppu.wh0 and xi <= ppu.wh1;
            if (w1_inv) a = !a;
            var b = xi >= ppu.wh2 and xi <= ppu.wh3;
            if (w2_inv) b = !b;
            mask[layer][x] = if (w1_en and w2_en)
                switch (logic) {
                    0 => a or b,
                    1 => a and b,
                    2 => a != b, // XOR
                    3 => a == b, // XNOR
                }
            else if (w1_en)
                a
            else if (w2_en)
                b
            else
                false;
        }
    }
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
    winmask: *const [5][fb_width]bool,
    tmw: u8,
) void {
    for (0..fb_width) |x| {
        var abs: u8 = 0; // backdrop
        for (order) |e| {
            // A layer masked by its main-screen window is skipped here, so a
            // lower-priority layer or the backdrop shows through. `tmw`
            // short-circuits, so `winmask` is untouched when windows are off.
            const layer: usize = if (e.src == .bg) e.idx else 4;
            if (tmw & (@as(u8, 1) << @intCast(layer)) != 0 and winmask[layer][x]) continue;
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
fn fillBg(ppu: *Ppu, bg_index: usize, comptime bpp: u4, cgram_base: u16, comptime opt: OptMode, line: u32, buf: *[fb_width]Cell) void {
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
    const pal_size: u16 = @as(u16, 1) << bpp;

    // Mosaic ($2106): each block shows the color at its top-left *screen* pixel,
    // so quantize the screen coordinates (grid is screen-aligned, not scrolled).
    // Size (block = size+1) is shared; the enable bit is per BG (bit 4+index).
    const msize: u32 = (@as(u32, ppu.mosaic) & 0x0F) + 1;
    const mosaic_on = msize > 1 and (ppu.mosaic >> @intCast(4 + bg_index)) & 1 != 0;

    const my: u32 = if (mosaic_on) line - line % msize else line;
    // Without offset-per-tile the vertical scroll (and tile row) is constant.
    const base_sy: u16 = @intCast((my + layer.vofs) & (bg_h - 1));
    const base_tile_row = base_sy / tile_px;

    for (0..fb_width) |x| {
        const xi: u32 = @intCast(x);
        const mx: u32 = if (mosaic_on) xi - xi % msize else xi;

        // Offset-per-tile (modes 2/4/6): BG3's map replaces this column's scroll.
        const scroll = if (opt == .none)
            .{ .h = layer.hofs, .sy = base_sy, .tile_row = base_tile_row }
        else blk: {
            var eff_hofs = layer.hofs;
            var eff_vofs = layer.vofs;
            offsetPerTile(ppu, bg_index, opt, layer.hofs, @intCast(mx), &eff_hofs, &eff_vofs);
            const oy: u16 = @intCast((my + eff_vofs) & (bg_h - 1));
            break :blk .{ .h = eff_hofs, .sy = oy, .tile_row = oy / tile_px };
        };
        const sy = scroll.sy;
        const tile_row = scroll.tile_row;

        const sx: u16 = @intCast((mx + scroll.h) & (bg_w - 1));
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
        // 8bpp backgrounds index all 256 CGRAM entries directly; the tilemap's
        // palette-group bits are ignored. Lower depths select a sub-palette.
        const abs: u16 = if (bpp == 8) cgram_base + color else cgram_base + pal_group * pal_size + color;
        buf[x] = if (color == 0)
            .{}
        else
            .{ .abs = @intCast(abs), .prio = prio, .solid = true };
    }
}

/// Look up the offset-per-tile scroll for the column containing screen pixel
/// `screen_x`, replacing `eff_h`/`eff_v` in place. BG3's tilemap is the offset
/// source: a horizontal entry (row = BG3VOFS/8, column steps from BG3HOFS/8) and,
/// for `.hv` modes, a vertical entry one row below. Entry bit 13 enables the
/// override for BG1, bit 14 for BG2; bits 0-9 are the offset value. The leftmost
/// visible tile keeps the base scroll (offset-map entry 0 targets the 2nd column).
/// Offset maps are 32 tiles wide by convention; wider BG3 maps aren't modeled.
fn offsetPerTile(
    ppu: *Ppu,
    bg_index: usize,
    comptime opt: OptMode,
    base_h: u16,
    screen_x: u16,
    eff_h: *u16,
    eff_v: *u16,
) void {
    const offset_x: u16 = screen_x + (base_h & 7);
    if (offset_x < 8) return; // leftmost tile: no offset
    const col_index: u16 = (offset_x >> 3) - 1; // entry 0 -> second column

    const bg3 = ppu.bg[2];
    const valid: u16 = if (bg_index == 0) 0x2000 else 0x4000; // bit13 BG1 / bit14 BG2

    const h_col: u16 = ((bg3.hofs >> 3) + col_index) & 0x1F;
    const h_row: u16 = (bg3.vofs >> 3) & 0x1F;
    const h_addr: u16 = (bg3.map_base + h_row * 32 + h_col) & 0x7FFF;
    const h_entry = ppu.vram[h_addr];

    switch (opt) {
        .single => { // mode 4: one entry, bit 15 selects vertical vs horizontal
            if (h_entry & valid != 0) {
                if (h_entry & 0x8000 != 0)
                    eff_v.* = h_entry & 0x3FF
                else
                    eff_h.* = (h_entry & 0x3F8) | (base_h & 7);
            }
        },
        .hv => { // modes 2/6: separate H entry and a V entry one row below
            if (h_entry & valid != 0) eff_h.* = (h_entry & 0x3F8) | (base_h & 7);
            const v_entry = ppu.vram[(h_addr + 32) & 0x7FFF];
            if (v_entry & valid != 0) eff_v.* = v_entry & 0x3FF;
        },
        .none => comptime unreachable,
    }
}

/// Hardware per-scanline sprite limits: at most 32 sprites in range and 34
/// sprite tiles (8-pixel columns) fetched; exceeding either sets an overflow flag.
const obj_per_line_max = 32;
const obj_tiles_per_line_max = 34;

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
        if (in_range > obj_per_line_max) {
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
            if (tiles > obj_tiles_per_line_max) {
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

/// Decode one planar pixel (2bpp, 4bpp, or 8bpp) at bit position `px`
/// (0 = leftmost) from the tile row word(s) starting at `char_addr`.
inline fn decodePlanar(ppu: *Ppu, comptime bpp: u4, char_addr: u16, px: u3) u8 {
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

test "mode 3 renders an 8bpp BG1 pixel and ignores the tilemap palette group" {
    var ppu: Ppu = .init;
    ppu.bg_mode = 3;
    ppu.main_screen = 0x01; // BG1 only
    ppu.force_blank = false;
    ppu.brightness = 15;
    ppu.bg[0] = .{ .map_base = 0x400, .char_base = 0, .map_size = 0 };
    // Tilemap entry with a non-zero palette group (0x1C00 = group 7): an 8bpp BG
    // must ignore it, so the color index is the raw 8-bit pixel value. If it were
    // wrongly applied, abs = 7*256+1 would overflow the u8 index and panic.
    ppu.vram[0x400] = 0x1C00;
    ppu.vram[0] = 0x0080; // plane 0 leftmost bit -> pixel value 1
    ppu.cgram[1] = 0x7C00; // blue
    ppu.postLoad();

    ppu.renderScanline(0);
    try std.testing.expectEqual(@as(u16, 0x001F), ppu.fb[0]); // cgram[1], not cgram[1793]
    try std.testing.expectEqual(@as(u16, 0x0000), ppu.fb[1]);
}

test "mosaic quantizes BG pixels into blocks" {
    var ppu: Ppu = .init;
    ppu.bg_mode = 0;
    ppu.main_screen = 0x01; // BG1
    ppu.force_blank = false;
    ppu.brightness = 15;
    ppu.bg[0] = .{ .map_base = 0x400, .char_base = 0, .map_size = 0 };
    ppu.vram[0x400] = 0x0000; // tile 0
    ppu.vram[0] = 0x4080; // 2bpp row: px0 -> color 1, px1 -> color 2
    ppu.cgram[1] = 0x001F; // color 1
    ppu.cgram[2] = 0x03E0; // color 2 (distinct)
    ppu.writeReg(0x2106, 0x11); // MOSAIC: size 2 (block=2), BG1 enabled
    ppu.postLoad();

    ppu.renderScanline(0);
    // Each 2-pixel block shows its top-left sample, so pixel 1 takes pixel 0's
    // color — the color-2 pixel at x=1 is dropped.
    try std.testing.expectEqual(ppu.fb[0], ppu.fb[1]);
    try std.testing.expectEqual(ppu.fb[2], ppu.fb[3]);
    try std.testing.expect(ppu.fb[0] != ppu.fb[2]); // adjacent blocks still differ

    // With mosaic off, pixel 1 shows its own (color-2) value again.
    ppu.writeReg(0x2106, 0x00);
    ppu.renderScanline(0);
    try std.testing.expect(ppu.fb[1] != ppu.fb[0]);
}

test "offset-per-tile shifts a BG1 column from BG3's offset map" {
    var ppu: Ppu = .init;
    ppu.bg_mode = 2; // BG1/BG2 4bpp with H+V offset-per-tile
    ppu.main_screen = 0x01; // BG1 only
    ppu.force_blank = false;
    ppu.brightness = 15;
    ppu.bg[0] = .{ .map_base = 0x400, .char_base = 0 }; // BG1 4bpp
    ppu.bg[2] = .{ .map_base = 0x1000 }; // BG3 = offset source (scroll 0)

    // Two solid 4bpp tiles: tile 0 = color 1, tile 1 = color 2.
    ppu.vram[0] = 0x00FF; // tile 0 row 0: plane0 all set -> color 1
    ppu.vram[16] = 0xFF00; // tile 1 row 0: plane1 all set -> color 2
    // BG1 map row 0: columns 0,1 -> tile 0; column 2 -> tile 1.
    ppu.vram[0x402] = 0x0001;
    ppu.cgram[1] = 0x001F;
    ppu.cgram[2] = 0x7C00;

    // Offset-map entry 0 targets the *second* visible column (col 1). Value 8 (one
    // tile) with the BG1 valid bit (0x2000) shifts col 1's sample to tile 1.
    ppu.vram[0x1000] = 0x2008;
    ppu.postLoad();

    ppu.renderScanline(0);
    try std.testing.expectEqual(ppu.fb[16], ppu.fb[8]); // col 1 now shows tile 1 (color 2)
    try std.testing.expect(ppu.fb[8] != ppu.fb[0]); // ...and differs from the un-offset col 0

    // Clearing the offset entry restores col 1 to its native tile 0 (color 1).
    ppu.vram[0x1000] = 0x0000;
    ppu.renderScanline(0);
    try std.testing.expectEqual(ppu.fb[0], ppu.fb[8]);
}

test "window masks a BG layer inside its region (and inverts)" {
    var ppu: Ppu = .init;
    ppu.bg_mode = 0;
    ppu.main_screen = 0x01; // BG1
    ppu.force_blank = false;
    ppu.brightness = 15;
    ppu.bg[0] = .{ .map_base = 0x400, .char_base = 0 };
    ppu.vram[0] = 0x00FF; // tile 0 solid color 1 across the row
    ppu.cgram[0] = 0x0000; // backdrop black
    ppu.cgram[1] = 0x001F;

    // Window 1 = [40,200], enabled for BG1, masking BG1 on the main screen.
    ppu.writeReg(0x2123, 0x02); // W12SEL: BG1 W1 enable
    ppu.writeReg(0x2126, 40); // WH0
    ppu.writeReg(0x2127, 200); // WH1
    ppu.writeReg(0x212E, 0x01); // TMW: BG1
    ppu.postLoad();

    ppu.renderScanline(0);
    try std.testing.expect(ppu.fb[0] != 0); // outside window: BG1 shows
    try std.testing.expectEqual(@as(u16, 0), ppu.fb[100]); // inside: masked -> backdrop
    try std.testing.expect(ppu.fb[220] != 0); // outside: BG1 shows

    // Inverting window 1 flips the masked region.
    ppu.writeReg(0x2123, 0x03); // W12SEL: BG1 W1 enable + invert
    ppu.renderScanline(0);
    try std.testing.expectEqual(@as(u16, 0), ppu.fb[0]); // now outside is masked
    try std.testing.expect(ppu.fb[100] != 0); // now inside shows BG1
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

test "more than 32 sprites on a line sets range-over and drops the extras" {
    var ppu: Ppu = .init;
    ppu.bg_mode = 1;
    ppu.main_screen = 0x10; // OBJ only
    ppu.force_blank = false;
    ppu.brightness = 15;
    ppu.obj_size = 0; // 8x8 small -> 1 tile each (stays under the 34-tile limit)
    ppu.obj_char_base = 0;

    // 32 sprites stacked at x=0 (all in range), then a 33rd at x=100.
    for (0..33) |i| {
        ppu.oam[i * 4 + 0] = if (i == 32) 100 else 0; // X
        ppu.oam[i * 4 + 1] = 0; // Y
        ppu.oam[i * 4 + 2] = 0; // tile
        ppu.oam[i * 4 + 3] = 0x20; // pal 0, prio 2
    }
    // High table (size/x-sign) stays zero: all small, x < 256.
    ppu.vram[0] = 0x0080; // tile 0: color 1 at the leftmost pixel
    ppu.cgram[128 + 1] = 0x03E0; // OBJ pal 0 color 1 = green
    ppu.postLoad();

    ppu.renderScanline(0);
    try std.testing.expect(ppu.obj_range_over); // >32 in range
    try std.testing.expect(!ppu.obj_time_over); // 32 tiles, under the tile cap
    try std.testing.expectEqual(@as(u16, 0x07E0), ppu.fb[0]); // the first 32 rendered
    try std.testing.expectEqual(@as(u16, 0x0000), ppu.fb[100]); // the 33rd was dropped
}

test "more than 34 sprite tiles on a line sets time-over" {
    var ppu: Ppu = .init;
    ppu.bg_mode = 1;
    ppu.main_screen = 0x10;
    ppu.force_blank = false;
    ppu.brightness = 15;
    ppu.obj_size = 2; // {8x8, 64x64}; large sprites are 8 tile columns wide
    ppu.obj_char_base = 0;

    // Five 64-wide sprites = 40 tile columns on the line: over the 34-tile cap
    // but only 5 sprites, so range-over must stay clear.
    for (0..5) |i| {
        ppu.oam[i * 4 + 0] = 0; // X
        ppu.oam[i * 4 + 1] = 0; // Y
        ppu.oam[i * 4 + 2] = 0; // tile
        ppu.oam[i * 4 + 3] = 0x20; // pal 0, prio 2
        // High table: set this sprite's size bit (bit 1 of its 2-bit field) -> large.
        ppu.oam[0x200 + (i >> 2)] |= @as(u8, 0b10) << @intCast((i & 3) * 2);
    }
    ppu.vram[0] = 0x0080;
    ppu.cgram[128 + 1] = 0x03E0;
    ppu.postLoad();

    ppu.renderScanline(0);
    try std.testing.expect(ppu.obj_time_over); // >34 tiles
    try std.testing.expect(!ppu.obj_range_over); // only 5 sprites
}
