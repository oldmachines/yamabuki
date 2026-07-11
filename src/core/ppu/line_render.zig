//! Fast scanline compositor for BG modes 0-4 and 7, with sprites, windows,
//! and color math.
//!
//! Each enabled background layer and the sprite (OBJ) layer are decoded into
//! per-pixel line buffers (palette index + priority), then composited
//! front-to-back by the mode's priority order and written out as RGB565. Tile
//! decoding is comptime-specialized on bit depth so the 2bpp/4bpp/8bpp planes
//! fold to straight-line shifts with no per-pixel branching on depth.
//!
//! Sprites are evaluated per line with the real 32-sprites and 34-tiles limits;
//! lower OAM index wins on overlap, and each sprite's OBJ priority (0-3) places
//! it in the composite order relative to the BG layers.
//!
//! Modes 5/6 (hi-res) arrive in a later slice; unsupported modes fall back to
//! the backdrop.

const std = @import("std");
const ppu_mod = @import("ppu.zig");
const Ppu = ppu_mod.Ppu;
const fb_width = ppu_mod.fb_width;
const fb_width_max = ppu_mod.fb_width_max;

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
// Mode 6: BG1 only, interleaved with the OBJ priorities.
const order_mode6 = [_]Entry{ obj(3), bg(0, 1), obj(2), obj(1), bg(0, 0), obj(0) };
// Mode 7: a single BG1 plane below all sprites (no per-tile priority).
const order_mode7 = [_]Entry{ obj(3), obj(2), obj(1), obj(0), bg(0, 0) };
// Mode 7 with EXTBG: BG2 shows the same plane with the pixel's bit7 as its
// priority — high-priority BG2 pixels rise above OBJ2, the rest sink below BG1.
const order_mode7_extbg = [_]Entry{ obj(3), bg(1, 1), obj(2), obj(1), bg(0, 0), obj(0), bg(1, 0) };

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
    /// Mode 7's alternate order when EXTBG (SETINI bit6) adds the BG2 plane.
    order_extbg: ?[]const Entry = null,
    kind: Kind = .planar,
    opt: OptMode = .none,
    /// Modes 5/6: BG tiles are 16 pixels wide and the layer plane is 512 wide;
    /// the sub screen shows the even half-dots, the main screen the odd ones.
    hires: bool = false,
};

const backdrop_mode: ModeDesc = .{};

/// Modes 0-7, indexed by `$2105` BGMODE. Modes 5/6 render hi-res (512-wide
/// planes interleaving the sub and main screens); mode 7 is the affine plane.
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
    .{ // mode 5: hi-res BG1 4bpp, BG2 2bpp (16-wide tiles, 512-wide plane).
        .layers = &.{
            .{ .bg = 0, .bpp = 4, .cgram_base = 0 },
            .{ .bg = 1, .bpp = 2, .cgram_base = 0 },
        },
        .order = &order_2bg,
        .hires = true,
    },
    .{ // mode 6: hi-res BG1 4bpp with H+V offset-per-tile.
        .layers = &.{
            .{ .bg = 0, .bpp = 4, .cgram_base = 0 },
        },
        .order = &order_mode6,
        .opt = .hv,
        .hires = true,
    },
    .{ // mode 7: single affine BG1 (see fillMode7); EXTBG adds the BG2 plane.
        .order = &order_mode7,
        .order_extbg = &order_mode7_extbg,
        .kind = .affine,
    },
};

pub fn renderLine(ppu: *Ppu, line: u32) void {
    const width = ppu.fb_line_width;
    const row = ppu.fb[line * width ..][0..width];

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

    // Content composes at 256 pixels; on a 512-stride frame (a mixed-width
    // frame whose earlier lines were hi-res) it is pixel-doubled into the row.
    var tmp: [fb_width]u16 = undefined;
    const dest: []u16 = if (width == fb_width) row else &tmp;

    var bgbuf: [4][fb_width_max]Cell = undefined;
    var objbuf: [fb_width]Cell = undefined;

    // Runtime-select the mode, then run a body comptime-specialized on its
    // descriptor so each layer's bit depth stays comptime.
    inline for (mode_table, 0..) |md, m| {
        if (ppu.bg_mode == m) {
            if (width != fb_width and ppu.hiresActive()) {
                // A genuine hi-res line: sub/main interleave at 512.
                renderModeHires(ppu, line, md, &bgbuf, &objbuf, &ppu.lpal, row);
            } else {
                renderMode(ppu, line, md, &bgbuf, &objbuf, &ppu.lpal, dest);
                if (width != fb_width) {
                    // A 256-wide line on a promoted frame: pixel-double it.
                    for (0..fb_width) |x| {
                        row[2 * x] = tmp[x];
                        row[2 * x + 1] = tmp[x];
                    }
                }
            }
            return;
        }
    }
}

/// Decode a mode's BG layers and the OBJ layer into the line buffers.
fn fillLayers(ppu: *Ppu, line: u32, comptime md: ModeDesc, bgbuf: *[4][fb_width_max]Cell, objbuf: *[fb_width]Cell) void {
    if (md.kind == .affine) {
        fillMode7(ppu, line, bgbuf);
    } else {
        inline for (md.layers) |ld| {
            fillBg(ppu, ld.bg, ld.bpp, ld.cgram_base, md.opt, md.hires, line, &bgbuf[ld.bg]);
        }
    }
    fillObj(ppu, line, objbuf);
}

/// The mode's priority order, honoring the mode-1 BG3-priority alternate and
/// mode 7's EXTBG alternate.
inline fn selectOrder(ppu: *const Ppu, comptime md: ModeDesc) []const Entry {
    if (md.order_extbg) |ext| {
        if (ppu.setini & 0x40 != 0) return ext;
    }
    return if (md.order_bg3_front) |alt|
        (if (ppu.bg3_priority) alt else md.order)
    else
        md.order;
}

/// Color math runs when any layer has its CGADSUB enable bit set or CGWSEL
/// clips the main screen to black; otherwise the direct lpal path is taken
/// and none of the math state is read.
inline fn mathActive(ppu: *const Ppu) bool {
    return ppu.cgadsub & 0x3F != 0 or ppu.cgwsel & 0xC0 != 0;
}

/// Decode a mode's layers into the line buffers and composite them. `md` is
/// comptime, so `fillBg` monomorphizes per layer bit depth and modes with no
/// layers fold to a plain backdrop fill.
fn renderMode(
    ppu: *Ppu,
    line: u32,
    comptime md: ModeDesc,
    bgbuf: *[4][fb_width_max]Cell,
    objbuf: *[fb_width]Cell,
    lpal: *const [256]u16,
    row: []u16,
) void {
    if (md.order.len == 0) {
        @memset(row, lpal[0]);
        return;
    }
    fillLayers(ppu, line, md, bgbuf, objbuf);
    const order = selectOrder(ppu, md);
    const math = mathActive(ppu);

    // Windows matter when a layer is masked on the main screen ($212E TMW) or
    // color math is active (sub-screen masks + the color window). Otherwise the
    // compositor short-circuits and the mask is never read.
    var winmask: [6][fb_width]bool = undefined;
    if (ppu.tmw != 0 or math) computeWindows(ppu, &winmask);

    if (math) {
        compositeMath(ppu, order, bgbuf, objbuf, row, &winmask, .full, .full);
    } else {
        composite(order, bgbuf, objbuf, lpal, row, &winmask, ppu.tmw, ppu.main_screen, .full);
    }
}

/// Hi-res line: compose the sub and main screens separately at 256 pixels and
/// interleave them into the 512-wide row — even output pixels show the sub
/// screen, odd the main screen (the hardware's half-dot order). In pseudo-hires
/// (SETINI bit3, normal modes) both screens sample the 256-wide layer buffers;
/// in modes 5/6 the BG plane itself is 512 wide and the sub/main screens sample
/// its even/odd columns. The main screen keeps its color-math path; the sub
/// screen composes plainly with its own TS enables and TSW window masks.
fn renderModeHires(
    ppu: *Ppu,
    line: u32,
    comptime md: ModeDesc,
    bgbuf: *[4][fb_width_max]Cell,
    objbuf: *[fb_width]Cell,
    lpal: *const [256]u16,
    row: []u16,
) void {
    if (md.order.len == 0) {
        @memset(row, lpal[0]);
        return;
    }
    fillLayers(ppu, line, md, bgbuf, objbuf);
    const order = selectOrder(ppu, md);
    const math = mathActive(ppu);

    var winmask: [6][fb_width]bool = undefined;
    if ((ppu.tmw | ppu.tsw) != 0 or math) computeWindows(ppu, &winmask);

    const main_hd: HalfDot = comptime if (md.hires) .odd else .full;
    const sub_hd: HalfDot = comptime if (md.hires) .even else .full;

    var main_row: [fb_width]u16 = undefined;
    var sub_row: [fb_width]u16 = undefined;
    if (math) {
        compositeMath(ppu, order, bgbuf, objbuf, &main_row, &winmask, main_hd, sub_hd);
    } else {
        composite(order, bgbuf, objbuf, lpal, &main_row, &winmask, ppu.tmw, ppu.main_screen, main_hd);
    }
    composite(order, bgbuf, objbuf, lpal, &sub_row, &winmask, ppu.tsw, ppu.sub_screen, sub_hd);

    for (0..fb_width) |x| {
        row[2 * x] = sub_row[x];
        row[2 * x + 1] = main_row[x];
    }
}

/// Compute, per layer (0-3 = BG1-4, 4 = OBJ, 5 = color window), whether each
/// screen pixel lies in that layer's combined window region. Window 1 is
/// [WH0,WH1], window 2 is [WH2,WH3]; each can be enabled and inverted, and the
/// two combine by the layer's logic op (OR/AND/XOR/XNOR). A layer with no
/// enabled window is never masked. Recomputed per line, so HDMA'd window edges
/// take effect per scanline.
fn computeWindows(ppu: *const Ppu, mask: *[6][fb_width]bool) void {
    for (0..6) |layer| {
        const sel: u8 = switch (layer) {
            0 => ppu.w12sel & 0x0F,
            1 => ppu.w12sel >> 4,
            2 => ppu.w34sel & 0x0F,
            3 => ppu.w34sel >> 4,
            4 => ppu.wobjsel & 0x0F,
            else => ppu.wobjsel >> 4,
        };
        const w1_inv = sel & 0x01 != 0;
        const w1_en = sel & 0x02 != 0;
        const w2_inv = sel & 0x04 != 0;
        const w2_en = sel & 0x08 != 0;
        const logic: u2 = switch (layer) {
            0...3 => @truncate(ppu.wbglog >> @intCast(layer * 2)),
            4 => @truncate(ppu.wobjlog),
            else => @truncate(ppu.wobjlog >> 2),
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

/// A resolved screen pixel: its CGRAM index and the layer that produced it
/// (0-3 = BG1-4, 4 = OBJ, 5 = backdrop). The layer drives per-layer color math.
const Resolved = struct { abs: u8, layer: u3 };

/// Which half-dot of a hi-res BG plane a screen resolves: `.full` samples the
/// BG buffer at the screen pixel (normal modes), `.even`/`.odd` sample the
/// 512-wide plane of modes 5/6 (sub screen = even, main screen = odd).
const HalfDot = enum { full, even, odd };

inline fn bgX(comptime hd: HalfDot, x: usize) usize {
    return switch (hd) {
        .full => x,
        .even => 2 * x,
        .odd => 2 * x + 1,
    };
}

/// Walk the priority order front-to-back for one pixel, taking the first solid
/// layer at its matching priority (else the backdrop). `screens` is the TM or
/// TS enable mask, so the same walk resolves the main and the sub screen; `tw`
/// is the matching window mask register (TMW/TSW). `x` is the 256-basis screen
/// pixel (windows and sprites live there); `hd` picks the BG sample column.
inline fn resolvePixel(
    order: []const Entry,
    bgbuf: *const [4][fb_width_max]Cell,
    objbuf: *const [fb_width]Cell,
    comptime hd: HalfDot,
    x: usize,
    screens: u8,
    winmask: *const [6][fb_width]bool,
    tw: u8,
) Resolved {
    for (order) |e| {
        const layer: u3 = if (e.src == .bg) e.idx else 4;
        if (screens & (@as(u8, 1) << layer) == 0) continue;
        // A layer masked by its window is skipped here, so a lower-priority
        // layer or the backdrop shows through. `tw` short-circuits, so
        // `winmask` is untouched when windows are off.
        if (tw & (@as(u8, 1) << layer) != 0 and winmask[layer][x]) continue;
        const cell = if (e.src == .bg) bgbuf[e.idx][bgX(hd, x)] else objbuf[x];
        if (cell.solid and cell.prio == e.prio) return .{ .abs = cell.abs, .layer = layer };
    }
    return .{ .abs = 0, .layer = 5 };
}

/// Composite a screen without color math: resolve each pixel and write the
/// brightness-scaled palette entry. This is the hot path for the common
/// no-math case; `compositeMath` below is the slower blending variant.
fn composite(
    order: []const Entry,
    bgbuf: *const [4][fb_width_max]Cell,
    objbuf: *const [fb_width]Cell,
    lpal: *const [256]u16,
    row: []u16,
    winmask: *const [6][fb_width]bool,
    tmw: u8,
    screens: u8,
    comptime hd: HalfDot,
) void {
    for (0..fb_width) |x| {
        row[x] = lpal[resolvePixel(order, bgbuf, objbuf, hd, x, screens, winmask, tmw).abs];
    }
}

/// Whether a CGWSEL region field applies at a pixel: 0=never, 1=outside the
/// color window, 2=inside it, 3=always.
inline fn regionActive(region: u2, in_window: bool) bool {
    return switch (region) {
        0 => false,
        1 => !in_window,
        2 => in_window,
        3 => true,
    };
}

/// Add or subtract two 15-bit BGR colors per channel. Subtraction floors each
/// channel at 0 *before* halving; addition halves before the clamp to 31
/// (matching hardware order of operations).
fn colorMath(main: u16, addend: u16, subtract: bool, half: bool) u16 {
    var out: u16 = 0;
    inline for (.{ 0, 5, 10 }) |shift| {
        const m: i32 = (main >> shift) & 0x1F;
        const a: i32 = (addend >> shift) & 0x1F;
        var r: i32 = if (subtract) m - a else m + a;
        if (r < 0) r = 0;
        if (half) r >>= 1;
        if (r > 31) r = 31;
        out |= @as(u16, @intCast(r)) << shift;
    }
    return out;
}

/// Composite the main screen with color math ($2130-$2132): each main-screen
/// pixel whose source layer is enabled in CGADSUB is blended with the sub
/// screen's pixel (or the fixed color when the sub screen is disabled or
/// transparent). CGWSEL's color-window regions can clip the main pixel to
/// black (the spotlight effect) or prevent the math per pixel. Math operates
/// on raw 15-bit BGR, so master brightness is applied after blending.
fn compositeMath(
    ppu: *const Ppu,
    order: []const Entry,
    bgbuf: *const [4][fb_width_max]Cell,
    objbuf: *const [fb_width]Cell,
    row: []u16,
    winmask: *const [6][fb_width]bool,
    comptime main_hd: HalfDot,
    comptime sub_hd: HalfDot,
) void {
    const half_en = ppu.cgadsub & 0x40 != 0;
    const subtract = ppu.cgadsub & 0x80 != 0;
    const sub_addend = ppu.cgwsel & 0x02 != 0;
    const clip_region: u2 = @truncate(ppu.cgwsel >> 6);
    const prevent_region: u2 = @truncate(ppu.cgwsel >> 4);

    for (0..fb_width) |x| {
        const main = resolvePixel(order, bgbuf, objbuf, main_hd, x, ppu.main_screen, winmask, ppu.tmw);
        const in_cw = winmask[5][x];
        const clipped = regionActive(clip_region, in_cw);
        var color: u16 = if (clipped) 0 else ppu.cgram[main.abs];

        // The main pixel's layer selects participation (bit5 = backdrop); OBJ
        // pixels join only from palettes 4-7 (CGRAM 192-255).
        var do_math = ppu.cgadsub & (@as(u8, 1) << main.layer) != 0;
        if (main.layer == 4 and main.abs < 192) do_math = false;
        if (do_math and regionActive(prevent_region, in_cw)) do_math = false;

        if (do_math) {
            var addend: u16 = ppu.fixed_color;
            var half = half_en and !clipped;
            if (sub_addend) {
                const sub = resolvePixel(order, bgbuf, objbuf, sub_hd, x, ppu.sub_screen, winmask, ppu.tsw);
                if (sub.layer != 5) {
                    addend = ppu.cgram[sub.abs];
                } else {
                    half = false; // fixed-color fallback never halves
                }
            }
            color = colorMath(color, addend, subtract, half);
        }
        row[x] = ppu_mod.scaleBrightness(color, ppu.brightness);
    }
}

fn clearLine(buf: []Cell) void {
    for (buf) |*c| c.* = .{};
}

/// Decode one BG layer's contribution to the scanline. `comptime bpp` folds the
/// bitplane math; `cgram_base` is the mode-dependent palette offset for this BG.
fn fillBg(ppu: *Ppu, bg_index: usize, comptime bpp: u4, cgram_base: u16, comptime opt: OptMode, comptime hires: bool, line: u32, buf: *[fb_width_max]Cell) void {
    // Decode when the layer is on either screen; the compositor's TM/TS enable
    // mask decides which resolve pass actually sees it.
    if ((ppu.main_screen | ppu.sub_screen) & (@as(u8, 1) << @intCast(bg_index)) == 0) {
        clearLine(buf);
        return;
    }

    const layer = ppu.bg[bg_index];
    // Modes 5/6: tiles are always 16 wide (the plane spans 512 half-dots);
    // BGMODE's size bit still selects the tile height.
    const tile_ph: u16 = if (layer.tile16) 16 else 8;
    const tile_pw: u16 = if (hires) 16 else tile_ph;
    const width_tiles: u16 = if (layer.map_size & 1 != 0) 64 else 32;
    const height_tiles: u16 = if (layer.map_size & 2 != 0) 64 else 32;
    const bg_w: u16 = width_tiles * tile_pw;
    const bg_h: u16 = height_tiles * tile_ph;
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
    const base_tile_row = base_sy / tile_ph;

    const out_w = if (hires) fb_width_max else fb_width;
    for (0..out_w) |x| {
        const xi: u32 = @intCast(x);
        const mx: u32 = if (mosaic_on) xi - xi % msize else xi;

        // Offset-per-tile (modes 2/4/6): BG3's map replaces this column's scroll.
        const scroll = if (opt == .none)
            .{ .h = layer.hofs, .sy = base_sy, .tile_row = base_tile_row }
        else blk: {
            var eff_hofs = layer.hofs;
            var eff_vofs = layer.vofs;
            // In hi-res mode 6 the offset column granularity stays one map
            // tile, which is 8 output pixels on the 256 basis.
            const col_x: u16 = @intCast(if (hires) mx >> 1 else mx);
            offsetPerTile(ppu, bg_index, opt, layer.hofs, col_x, &eff_hofs, &eff_vofs);
            const oy: u16 = @intCast((my + eff_vofs) & (bg_h - 1));
            break :blk .{ .h = eff_hofs, .sy = oy, .tile_row = oy / tile_ph };
        };
        const sy = scroll.sy;
        const tile_row = scroll.tile_row;

        const sx: u16 = @intCast((mx + scroll.h) & (bg_w - 1));
        const tile_col = sx / tile_pw;

        var screen: u16 = 0;
        if (tile_col & 0x20 != 0) screen += 1;
        if (tile_row & 0x20 != 0) screen += if (width_tiles == 64) 2 else 1;
        // Wrapping: map_base tops out at $FC00 and the fourth screen adds
        // $C00 more; the & 0x7FFF wrap makes the u16 overflow congruent.
        const map_addr = (layer.map_base +% screen * 0x400 +%
            ((tile_row & 0x1F) << 5) +% (tile_col & 0x1F)) & 0x7FFF;
        const entry = ppu.vram[map_addr];

        var tile_num: u16 = entry & 0x3FF;
        const pal_group: u16 = (entry >> 10) & 7;
        const prio: u2 = @truncate(entry >> 13);
        const xflip = entry & 0x4000 != 0;
        const yflip = entry & 0x8000 != 0;

        var px: u16 = sx % tile_pw;
        var py: u16 = sy % tile_ph;
        if (xflip) px = tile_pw - 1 - px;
        if (yflip) py = tile_ph - 1 - py;
        if (tile_pw == 16) {
            if (px >= 8) tile_num += 1;
            px &= 7;
        }
        if (tile_ph == 16) {
            if (py >= 8) tile_num += 16;
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

/// Render one Mode 7 scanline: a single affine-transformed 8bpp plane. Each
/// screen pixel maps through the [A B; C D] matrix around center (M7X,M7Y) with
/// scroll (M7HOFS,M7VOFS) to a texel in the 1024x1024 (128-tile) field, whose
/// tilemap and 8bpp character data are byte-interleaved in VRAM (tilemap = low
/// bytes, char = high bytes). M7SEL selects screen flip and out-of-area handling.
/// With EXTBG (SETINI bit6) the same plane also feeds BG2: the pixel's low 7
/// bits are its color and bit7 its priority.
fn fillMode7(ppu: *Ppu, line: u32, bgbuf: *[4][fb_width_max]Cell) void {
    const buf = &bgbuf[0];
    const extbg = ppu.setini & 0x40 != 0;
    const enable_mask: u8 = if (extbg) 0x03 else 0x01;
    if ((ppu.main_screen | ppu.sub_screen) & enable_mask == 0) {
        clearLine(buf); // the mode-7 layers are disabled on both screens
        if (extbg) clearLine(&bgbuf[1]);
        return;
    }

    const a: i32 = ppu.m7a;
    const b: i32 = ppu.m7b;
    const c: i32 = ppu.m7c;
    const d: i32 = ppu.m7d;
    const cx: i32 = ppu.m7x;
    const cy: i32 = ppu.m7y;
    const hofs: i32 = ppu.m7hofs;
    const vofs: i32 = ppu.m7vofs;

    const hflip = ppu.m7sel & 0x01 != 0;
    const vflip = ppu.m7sel & 0x02 != 0;
    const over: u2 = @truncate(ppu.m7sel >> 6);

    const sy: i32 = if (vflip) 255 - @as(i32, @intCast(line)) else @intCast(line);
    // Row-constant terms; the per-pixel part adds A*Sx (Tx) and C*Sx (Ty).
    const hc = hofs - cx;
    const vc = sy + vofs - cy;
    const ox = a * hc + b * vc;
    const oy = c * hc + d * vc;

    for (0..fb_width) |x| {
        const sx: i32 = if (hflip) 255 - @as(i32, @intCast(x)) else @intCast(x);
        var tx = ((ox + a * sx) >> 8) + cx;
        var ty = ((oy + c * sx) >> 8) + cy;

        var force_tile0 = false;
        var transparent = false;
        if (tx < 0 or tx > 1023 or ty < 0 or ty > 1023) {
            switch (over) {
                0, 1 => { // wrap the field
                    tx &= 1023;
                    ty &= 1023;
                },
                2 => transparent = true, // outside is transparent
                3 => { // outside repeats character 0
                    tx &= 1023;
                    ty &= 1023;
                    force_tile0 = true;
                },
            }
        }

        var pixel: u8 = 0;
        if (!transparent) {
            const utx: u16 = @intCast(tx);
            const uty: u16 = @intCast(ty);
            const tile: u16 = if (force_tile0) 0 else ppu.vram[(uty >> 3) * 128 + (utx >> 3)] & 0xFF;
            pixel = @intCast(ppu.vram[tile * 64 + (uty & 7) * 8 + (utx & 7)] >> 8);
        }
        buf[x] = if (pixel == 0) .{} else .{ .abs = pixel, .prio = 0, .solid = true };
        if (extbg) {
            const color = pixel & 0x7F;
            bgbuf[1][x] = if (color == 0)
                .{}
            else
                .{ .abs = color, .prio = @intCast(pixel >> 7), .solid = true };
        }
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
    if ((ppu.main_screen | ppu.sub_screen) & 0x10 == 0) return; // OBJ off on both screens

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
        // Wrapping: base 7*$2000 + gap 4*$1000 exceeds u16; VRAM addressing
        // wraps anyway (decodePlanar masks to the 32K-word space).
        const tbase: u16 = ppu.obj_char_base +% (if (name_hi != 0) ppu.obj_char_gap else 0);

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

test "mode 7 samples the affine field with identity and out-of-area transparency" {
    var ppu: Ppu = .init;
    ppu.bg_mode = 7;
    ppu.main_screen = 0x01; // BG1
    ppu.force_blank = false;
    ppu.brightness = 15;
    ppu.m7a = 0x0100; // identity matrix (1.0, 0; 0, 1.0)
    ppu.m7d = 0x0100;

    // VRAM is byte-interleaved: low byte = tilemap entry, high byte = 8bpp pixel.
    ppu.vram[0] = 0x0500; // tilemap[0]=tile 0; tile 0 pixel (0,0) = color 5
    ppu.vram[2] = 0x0600; // tile 0 pixel (2,0) = color 6
    ppu.cgram[5] = 0x001F;
    ppu.cgram[6] = 0x03E0;
    ppu.postLoad();

    ppu.renderScanline(0);
    // Identity: screen (x,0) samples texel (x,0).
    try std.testing.expect(ppu.fb[0] != 0); // texel (0,0) = color 5
    try std.testing.expect(ppu.fb[2] != 0); // texel (2,0) = color 6
    try std.testing.expect(ppu.fb[0] != ppu.fb[2]); // distinct texels
    try std.testing.expectEqual(@as(u16, 0), ppu.fb[1]); // texel (1,0) = color 0 -> backdrop

    // Push the sample outside the 1024-texel field with M7SEL out-of-area = 2
    // (transparent): the whole line becomes backdrop.
    ppu.m7sel = 0x80; // bit7 set, bit6 clear -> over mode 2
    ppu.m7hofs = 2000;
    ppu.renderScanline(0);
    try std.testing.expectEqual(@as(u16, 0), ppu.fb[0]);
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

test "color math adds the fixed color (halved) and subtract floors at zero" {
    var ppu: Ppu = .init;
    ppu.bg_mode = 0;
    ppu.main_screen = 0x01; // BG1
    ppu.force_blank = false;
    ppu.brightness = 15;
    ppu.bg[0] = .{ .map_base = 0x400, .char_base = 0 };
    ppu.vram[0] = 0x00FF; // tile 0 row 0: solid color 1
    ppu.cgram[1] = 0x001F; // red 31
    ppu.writeReg(0x2132, 0x9E); // fixed color: blue 30
    ppu.writeReg(0x2131, 0x41); // CGADSUB: half + BG1 (addend = fixed color)
    ppu.postLoad();

    ppu.renderScanline(0);
    // (31,0,0) + (0,0,30), halved -> (15,0,15).
    try std.testing.expectEqual(@as(u16, 0x780F), ppu.fb[0]);

    // Subtract mode: red 31 minus blue 30 floors blue at 0 -> pure red.
    ppu.writeReg(0x2131, 0x81); // CGADSUB: subtract + BG1, no half
    ppu.renderScanline(0);
    try std.testing.expectEqual(@as(u16, 0xF800), ppu.fb[0]);
}

test "color math blends the sub screen, falling back unhalved to the fixed color" {
    var ppu: Ppu = .init;
    ppu.bg_mode = 0;
    ppu.main_screen = 0x01; // main: BG1
    ppu.sub_screen = 0x02; // sub: BG2
    ppu.force_blank = false;
    ppu.brightness = 15;
    ppu.bg[0] = .{ .map_base = 0x400, .char_base = 0 };
    ppu.bg[1] = .{ .map_base = 0x500, .char_base = 0x100 };
    ppu.vram[0] = 0x00FF; // BG1 tile: solid color 1 across the row
    ppu.vram[0x100] = 0x0080; // BG2 tile: color 1 at x=0 only, transparent after
    ppu.cgram[1] = 0x001F; // BG1 red 31
    ppu.cgram[33] = 0x03E0; // BG2 (mode-0 base 32) green 31
    ppu.writeReg(0x2130, 0x02); // CGWSEL: addend = sub screen
    ppu.writeReg(0x2131, 0x41); // CGADSUB: half + BG1
    ppu.postLoad();

    ppu.renderScanline(0);
    // x=0: (red + green)/2 -> (15,15,0).
    try std.testing.expectEqual(@as(u16, 0x7BC0), ppu.fb[0]);
    // x=1: sub screen transparent -> fixed color (0) addend, half skipped.
    try std.testing.expectEqual(@as(u16, 0xF800), ppu.fb[1]);
}

test "color window clips the main screen to black and prevents math" {
    var ppu: Ppu = .init;
    ppu.bg_mode = 0;
    ppu.main_screen = 0x01; // BG1
    ppu.force_blank = false;
    ppu.brightness = 15;
    ppu.bg[0] = .{ .map_base = 0x400, .char_base = 0 };
    ppu.vram[0] = 0x00FF; // solid color 1
    ppu.cgram[1] = 0x001F; // red 31
    ppu.writeReg(0x2125, 0x20); // WOBJSEL: color window = window 1
    ppu.writeReg(0x2126, 40); // WH0
    ppu.writeReg(0x2127, 200); // WH1
    ppu.postLoad();

    // Spotlight: clip to black outside the color window (region 1); no CGADSUB
    // enables, so the clip alone activates the math path.
    ppu.writeReg(0x2130, 0x40);
    ppu.renderScanline(0);
    try std.testing.expectEqual(@as(u16, 0x0000), ppu.fb[0]); // outside -> black
    try std.testing.expectEqual(@as(u16, 0xF800), ppu.fb[100]); // inside -> normal

    // Prevent math inside the color window (region 2): the fixed green is
    // added only outside it.
    ppu.writeReg(0x2130, 0x20);
    ppu.writeReg(0x2131, 0x01); // CGADSUB: add BG1
    ppu.writeReg(0x2132, 0x5F); // fixed color: green 31
    ppu.renderScanline(0);
    try std.testing.expectEqual(@as(u16, 0xFFE0), ppu.fb[0]); // outside: red+green
    try std.testing.expectEqual(@as(u16, 0xF800), ppu.fb[100]); // inside: unblended
}

test "OBJ color math applies only to sprite palettes 4-7" {
    var ppu: Ppu = .init;
    ppu.bg_mode = 1;
    ppu.main_screen = 0x10; // OBJ only
    ppu.force_blank = false;
    ppu.brightness = 15;
    ppu.obj_size = 0;
    ppu.obj_char_base = 0;

    // Sprite 0 (palette 0) at x=10, sprite 1 (palette 4) at x=30.
    ppu.oam[0] = 10;
    ppu.oam[1] = 0;
    ppu.oam[2] = 0;
    ppu.oam[3] = 0x20; // pal 0, prio 2
    ppu.oam[4] = 30;
    ppu.oam[5] = 0;
    ppu.oam[6] = 0;
    ppu.oam[7] = 0x28; // pal 4, prio 2
    ppu.oam[0x200] = 0;

    ppu.vram[0] = 0x0080; // tile 0: color 1 at its leftmost pixel
    ppu.cgram[128 + 1] = 0x03E0; // pal 0 color 1: green 31 (exempt, CGRAM < 192)
    ppu.cgram[128 + 64 + 1] = 0x03E0; // pal 4 color 1: green 31 (participates)
    ppu.writeReg(0x2131, 0x50); // CGADSUB: half + OBJ (fixed addend = 0)
    ppu.postLoad();

    ppu.renderScanline(0);
    try std.testing.expectEqual(@as(u16, 0x07E0), ppu.fb[10]); // pal 0: untouched
    try std.testing.expectEqual(@as(u16, 0x03C0), ppu.fb[30]); // pal 4: halved green
}

test "backdrop color math adds the fixed color to empty pixels" {
    var ppu: Ppu = .init;
    ppu.bg_mode = 0;
    ppu.main_screen = 0x01; // BG1 enabled but fully transparent (VRAM zeroed)
    ppu.force_blank = false;
    ppu.brightness = 15;
    ppu.writeReg(0x2131, 0x20); // CGADSUB: backdrop enable
    ppu.writeReg(0x2132, 0x5F); // fixed color: green 31
    ppu.postLoad();

    ppu.renderScanline(0);
    try std.testing.expectEqual(@as(u16, 0x07E0), ppu.fb[0]); // black + green
}

test "pseudo-hires interleaves the sub and main screens" {
    var ppu: Ppu = .init;
    ppu.bg_mode = 0;
    ppu.main_screen = 0x01; // main: BG1
    ppu.sub_screen = 0x02; // sub: BG2
    ppu.force_blank = false;
    ppu.brightness = 15;
    ppu.bg[0] = .{ .map_base = 0x400, .char_base = 0 };
    ppu.bg[1] = .{ .map_base = 0x500, .char_base = 0x100 };
    ppu.vram[0] = 0x00FF; // BG1 tile: solid color 1
    ppu.vram[0x100] = 0x00FF; // BG2 tile: solid color 1
    ppu.cgram[1] = 0x001F; // BG1 red
    ppu.cgram[33] = 0x03E0; // BG2 (mode-0 base 32) green
    ppu.writeReg(0x2133, 0x08); // SETINI: pseudo-hires
    ppu.postLoad();

    ppu.renderScanline(0);
    try std.testing.expectEqual(ppu_mod.fb_width_max, ppu.fb_line_width);
    try std.testing.expectEqual(@as(u16, 0x07E0), ppu.fb[0]); // even: sub (green)
    try std.testing.expectEqual(@as(u16, 0xF800), ppu.fb[1]); // odd: main (red)
    try std.testing.expectEqual(@as(u16, 0x07E0), ppu.fb[510]);
    try std.testing.expectEqual(@as(u16, 0xF800), ppu.fb[511]);
}

test "EXTBG shows mode 7 BG2 with the pixel high bit as priority" {
    var ppu: Ppu = .init;
    ppu.bg_mode = 7;
    ppu.main_screen = 0x02; // BG2 only (the EXTBG plane)
    ppu.force_blank = false;
    ppu.brightness = 15;
    ppu.m7a = 0x0100; // identity
    ppu.m7d = 0x0100;
    ppu.writeReg(0x2133, 0x40); // SETINI: EXTBG

    // Texel (0,0) = 0x85: BG2 color 5, priority 1. Texel (2,0) = 0x05: color 5,
    // priority 0 — still visible here (nothing else on the layer stack).
    ppu.vram[0] = 0x8500;
    ppu.vram[2] = 0x0500;
    ppu.cgram[5] = 0x001F; // red
    ppu.postLoad();

    ppu.renderScanline(0);
    try std.testing.expectEqual(@as(u16, 0xF800), ppu.fb[0]); // prio-1 pixel
    try std.testing.expectEqual(@as(u16, 0x0000), ppu.fb[1]); // empty texel
    try std.testing.expectEqual(@as(u16, 0xF800), ppu.fb[2]); // prio-0 pixel

    // Without EXTBG, BG2 doesn't exist in mode 7: the line is backdrop.
    ppu.writeReg(0x2133, 0x00);
    ppu.renderScanline(0);
    try std.testing.expectEqual(@as(u16, 0x0000), ppu.fb[0]);
}

test "mode 5 renders a 16-wide hi-res tile across sub/main half-dots" {
    var ppu: Ppu = .init;
    ppu.bg_mode = 5;
    ppu.main_screen = 0x01; // BG1 on both screens: output = the 512-wide plane
    ppu.sub_screen = 0x01;
    ppu.force_blank = false;
    ppu.brightness = 15;
    ppu.bg[0] = .{ .map_base = 0x400, .char_base = 0 }; // BG1 4bpp, map all tile 0
    // Tile 0 (left half of every 16-wide tile): color 1 at its first pixel.
    ppu.vram[0] = 0x0080;
    ppu.cgram[1] = 0x001F; // red
    ppu.postLoad();

    ppu.renderScanline(0);
    try std.testing.expectEqual(ppu_mod.fb_width_max, ppu.fb_line_width);
    // Plane x=0 (tile 0 px0) -> output half-dot 0 via the sub screen.
    try std.testing.expectEqual(@as(u16, 0xF800), ppu.fb[0]);
    try std.testing.expectEqual(@as(u16, 0x0000), ppu.fb[1]); // plane x=1 empty
    // Plane x=8..15 comes from tile 1 (zeroed VRAM) -> transparent.
    try std.testing.expectEqual(@as(u16, 0x0000), ppu.fb[8]);
    // The next 16-wide map column repeats tile 0: plane x=16 -> red again.
    try std.testing.expectEqual(@as(u16, 0xF800), ppu.fb[16]);
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
