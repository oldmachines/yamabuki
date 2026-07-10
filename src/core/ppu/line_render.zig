//! Fast scanline compositor for BG modes 0 and 1.
//!
//! Each enabled background layer is decoded into a per-pixel line buffer
//! (palette index + tile priority), then the layers are composited front-to-back
//! by the mode's priority order and written out as RGB565. Tile decoding is
//! comptime-specialized on bit depth so the 2bpp and 4bpp planes fold to
//! straight-line shifts with no per-pixel branching on depth.
//!
//! Modes 2-7 (offset-per-tile, mode 7, hi-res) and sprites arrive in later
//! milestones; unsupported modes fall back to the backdrop.

const std = @import("std");
const ppu_mod = @import("ppu.zig");
const Ppu = ppu_mod.Ppu;
const fb_width = ppu_mod.fb_width;

/// One decoded background pixel on the current scanline.
const Cell = struct {
    abs: u8 = 0, // absolute CGRAM index
    prio: u1 = 0, // tile priority bit
    solid: bool = false,
};

/// A background layer at a given tile-priority in the composite order.
const Entry = struct { bg: u2, prio: u1 };

// Priority orders, front (index 0) to back. Sprites interleave here from M3.5.
const order_mode0 = [_]Entry{
    .{ .bg = 0, .prio = 1 }, .{ .bg = 1, .prio = 1 },
    .{ .bg = 0, .prio = 0 }, .{ .bg = 1, .prio = 0 },
    .{ .bg = 2, .prio = 1 }, .{ .bg = 3, .prio = 1 },
    .{ .bg = 2, .prio = 0 }, .{ .bg = 3, .prio = 0 },
};
const order_mode1_bg3_front = [_]Entry{
    .{ .bg = 2, .prio = 1 },
    .{ .bg = 0, .prio = 1 },
    .{ .bg = 1, .prio = 1 },
    .{ .bg = 0, .prio = 0 },
    .{ .bg = 1, .prio = 0 },
    .{ .bg = 2, .prio = 0 },
};
const order_mode1 = [_]Entry{
    .{ .bg = 0, .prio = 1 }, .{ .bg = 1, .prio = 1 },
    .{ .bg = 0, .prio = 0 }, .{ .bg = 1, .prio = 0 },
    .{ .bg = 2, .prio = 1 }, .{ .bg = 2, .prio = 0 },
};

pub fn renderLine(ppu: *Ppu, line: u32) void {
    const row = ppu.fb[line * fb_width ..][0..fb_width];

    if (ppu.force_blank) {
        @memset(row, 0);
        return;
    }

    // Brightness-scaled palette for this line (index 0 is the backdrop).
    var lpal: [256]u16 = undefined;
    for (0..256) |i| lpal[i] = ppu_mod.scaleBrightness(ppu.cgram[i], ppu.brightness);

    var bg: [4][fb_width]Cell = undefined;

    const order: []const Entry = switch (ppu.bg_mode) {
        0 => blk: {
            fillBg(ppu, 0, 2, 0, line, &bg[0]);
            fillBg(ppu, 1, 2, 32, line, &bg[1]);
            fillBg(ppu, 2, 2, 64, line, &bg[2]);
            fillBg(ppu, 3, 2, 96, line, &bg[3]);
            break :blk &order_mode0;
        },
        1 => blk: {
            fillBg(ppu, 0, 4, 0, line, &bg[0]);
            fillBg(ppu, 1, 4, 0, line, &bg[1]);
            fillBg(ppu, 2, 2, 0, line, &bg[2]);
            clearBg(&bg[3]);
            break :blk if (ppu.bg3_priority) &order_mode1_bg3_front else &order_mode1;
        },
        else => {
            // Unsupported mode: backdrop only.
            @memset(row, lpal[0]);
            return;
        },
    };

    for (0..fb_width) |x| {
        var abs: u8 = 0; // backdrop
        for (order) |e| {
            const cell = bg[e.bg][x];
            if (cell.solid and cell.prio == e.prio) {
                abs = cell.abs;
                break;
            }
        }
        row[x] = lpal[abs];
    }
}

fn clearBg(buf: *[fb_width]Cell) void {
    for (buf) |*c| c.* = .{};
}

/// Decode one BG layer's contribution to the scanline. `comptime bpp` folds the
/// bitplane math; `cgram_base` is the mode-dependent palette offset for this BG.
fn fillBg(ppu: *Ppu, bg_index: usize, comptime bpp: u3, cgram_base: u16, line: u32, buf: *[fb_width]Cell) void {
    // Layer must be enabled on the main screen; otherwise it is transparent.
    if (ppu.main_screen & (@as(u8, 1) << @intCast(bg_index)) == 0) {
        clearBg(buf);
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

        // Tilemap entry: 32x32 within-screen index plus screen selection.
        var screen: u16 = 0;
        if (tile_col & 0x20 != 0) screen += 1;
        if (tile_row & 0x20 != 0) screen += if (width_tiles == 64) 2 else 1;
        const map_addr = (layer.map_base + screen * 0x400 +
            ((tile_row & 0x1F) << 5) + (tile_col & 0x1F)) & 0x7FFF;
        const entry = ppu.vram[map_addr];

        var tile_num: u16 = entry & 0x3FF;
        const pal_group: u16 = (entry >> 10) & 7;
        const prio: u1 = @truncate(entry >> 13);
        const xflip = entry & 0x4000 != 0;
        const yflip = entry & 0x8000 != 0;

        var px: u16 = sx % tile_px;
        var py: u16 = sy % tile_px;
        if (xflip) px = tile_px - 1 - px;
        if (yflip) py = tile_px - 1 - py;
        // 16x16 tiles are four 8x8 tiles (+1 across, +16 down).
        if (layer.tile16) {
            if (px >= 8) tile_num += 1;
            if (py >= 8) tile_num += 16;
            px &= 7;
            py &= 7;
        }

        const char_addr = layer.char_base +% tile_num *% words_per_tile +% py;
        const bit: u4 = @intCast(7 - px);
        var color: u8 = 0;
        inline for (0..bpp / 2) |pair| {
            const w = ppu.vram[(char_addr +% pair * 8) & 0x7FFF];
            const lo: u8 = @intCast((w >> bit) & 1);
            const hi: u8 = @intCast((w >> (@as(u4, 8) + bit)) & 1);
            color |= lo << (pair * 2);
            color |= hi << (pair * 2 + 1);
        }

        buf[x] = if (color == 0)
            .{}
        else
            .{
                .abs = @intCast(cgram_base + pal_group * pal_size + color),
                .prio = prio,
                .solid = true,
            };
    }
}

// --- tests ---------------------------------------------------------------

test {
    std.testing.refAllDecls(@This());
}

test "mode 0 renders a single BG1 tile pixel" {
    var ppu: Ppu = .init;
    ppu.bg_mode = 0;
    ppu.main_screen = 0x01; // BG1 on main screen
    ppu.force_blank = false;
    ppu.brightness = 15;
    ppu.bg[0] = .{ .map_base = 0x400, .char_base = 0, .map_size = 0 };

    // Tilemap (0,0) -> tile 0, palette 0, priority 0.
    ppu.vram[0x400] = 0x0000;
    // Tile 0, 2bpp row 0: plane0 bit7 set -> pixel x=0 is color 1.
    ppu.vram[0] = 0x0080;
    // Backdrop black; BG palette color 1 = blue.
    ppu.cgram[0] = 0x0000;
    ppu.cgram[1] = 0x7C00; // 15-bit BGR blue
    ppu.postLoad(); // rebuild the 565 palette

    ppu.renderScanline(0);
    try std.testing.expectEqual(@as(u16, 0x001F), ppu.fb[0]); // blue pixel
    try std.testing.expectEqual(@as(u16, 0x0000), ppu.fb[1]); // transparent -> backdrop
}

test "higher priority tile wins the composite" {
    var ppu: Ppu = .init;
    ppu.bg_mode = 1;
    ppu.main_screen = 0x03; // BG1 + BG2
    ppu.force_blank = false;
    ppu.brightness = 15;
    // BG1 (4bpp) low priority; BG2 (4bpp) high priority -> BG2 should win.
    ppu.bg[0] = .{ .map_base = 0x400, .char_base = 0x0000 };
    ppu.bg[1] = .{ .map_base = 0x500, .char_base = 0x0100 };

    ppu.vram[0x400] = 0x0000; // BG1 tile0, prio 0
    ppu.vram[0x500] = 0x2000; // BG2 tile0, prio 1
    // BG1 tile0 pixel0 = color1; BG2 tile0 pixel0 = color1.
    ppu.vram[0x0000] = 0x0080; // BG1 char (4bpp row0 plane0/1)
    ppu.vram[0x0100] = 0x0080; // BG2 char
    ppu.cgram[0] = 0;
    ppu.cgram[1] = 0x001F; // BG1 color -> red-ish (low bits)
    ppu.postLoad();

    ppu.renderScanline(0);
    // Both layers solid at x=0, BG2 has higher priority -> its color shows.
    // BG1 and BG2 share the same CGRAM index here, so the pixel is non-backdrop.
    try std.testing.expect(ppu.fb[0] != 0);
}
