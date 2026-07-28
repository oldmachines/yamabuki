//! Software UI primitives for the overlay menu: rects, dimming, and text,
//! all drawn straight into the RGB565 compose buffer that then rides the
//! frontend's normal video path (streaming texture or GL shader chain — the
//! CRT shader shades the menu too, which is exactly the look).
//!
//! Layout happens in a virtual 256-wide space. `Surface` maps it onto the
//! real framebuffer: a 512-wide hi-res frame doubles x (the frame is
//! presented squeezed 2:1, so doubling keeps the menu square); a
//! `--wide`-widened frame centers the 256 columns in the extra picture.
//! Y maps 1:1 — every frame height the PPU produces (224 or 239) is its own
//! virtual height.

const std = @import("std");
const font = @import("font.zig");

/// RGB565 colors for the menu's dress. Kept here so every page agrees.
pub const color = struct {
    pub const text: u16 = 0xFFFF;
    pub const text_dim: u16 = 0x8410; // 50% gray
    pub const accent: u16 = 0xFEA0; // amber
    pub const panel: u16 = 0x10A2; // near-black blue
    pub const panel_edge: u16 = 0x39C7;
    pub const shadow: u16 = 0x0000;
};

pub const Surface = struct {
    px: []u16,
    /// Real framebuffer dimensions.
    w: u32,
    h: u32,
    /// Virtual-x multiplier: 2 on 512-wide hi-res frames, else 1.
    xscale: u32,
    /// Real-pixel offset centering the virtual 256 columns (`--wide` margins).
    xoff: u32,

    pub fn init(px: []u16, w: u32, h: u32) Surface {
        const xscale: u32 = if (w == 512) 2 else 1;
        const virtual_w = w / xscale;
        const xoff = if (virtual_w > 256) (virtual_w - 256) / 2 * xscale else 0;
        return .{ .px = px, .w = w, .h = h, .xscale = xscale, .xoff = xoff };
    }

    /// The virtual height — y is unscaled, so it is the frame height.
    pub fn vh(self: *const Surface) u32 {
        return self.h;
    }

    /// Plot one virtual pixel (an `xscale`-wide run of real pixels).
    /// Bounds-checked so layout arithmetic can never write outside the frame.
    pub fn plot(self: *const Surface, x: i32, y: i32, c: u16) void {
        if (x < 0 or y < 0) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (uy >= self.h) return;
        const rx = self.xoff + ux * self.xscale;
        if (rx + self.xscale > self.w) return;
        const base = uy * self.w + rx;
        for (0..self.xscale) |i| self.px[base + i] = c;
    }
};

/// Darken the whole frame to half brightness: the paused game stays visible
/// behind the menu. `(px >> 1) & 0x7BEF` halves each RGB565 channel without
/// unpacking (the mask clears the bits that shifted across field borders).
pub fn dimAll(s: *const Surface) void {
    for (s.px) |*p| p.* = (p.* >> 1) & 0x7BEF;
}

pub fn fillRect(s: *const Surface, x: i32, y: i32, w: u32, h: u32, c: u16) void {
    for (0..h) |dy| {
        for (0..w) |dx| {
            s.plot(x + @as(i32, @intCast(dx)), y + @as(i32, @intCast(dy)), c);
        }
    }
}

/// A 1-pixel border, inside the given rect.
pub fn frameRect(s: *const Surface, x: i32, y: i32, w: u32, h: u32, c: u16) void {
    if (w == 0 or h == 0) return;
    const wi: i32 = @intCast(w);
    const hi: i32 = @intCast(h);
    for (0..w) |dx| {
        s.plot(x + @as(i32, @intCast(dx)), y, c);
        s.plot(x + @as(i32, @intCast(dx)), y + hi - 1, c);
    }
    for (0..h) |dy| {
        s.plot(x, y + @as(i32, @intCast(dy)), c);
        s.plot(x + wi - 1, y + @as(i32, @intCast(dy)), c);
    }
}

/// Glyph advance: 5-pixel glyphs on a 6-pixel pitch.
pub const char_w = font.glyph_w + 1;
pub const line_h = font.glyph_h + 3;

pub fn textWidth(text: []const u8) u32 {
    return @intCast(text.len * char_w);
}

/// Draw `text` with its top-left at (x, y), with a 1-pixel drop shadow —
/// the trick that keeps white text readable over any paused frame.
pub fn drawText(s: *const Surface, x: i32, y: i32, text: []const u8, fg: u16) void {
    drawTextOpts(s, x, y, text, fg, true);
}

pub fn drawTextOpts(s: *const Surface, x: i32, y: i32, text: []const u8, fg: u16, shadow: bool) void {
    for (text, 0..) |c, i| {
        const rows = font.rows(c);
        const gx = x + @as(i32, @intCast(i * char_w));
        for (0..font.glyph_h) |row| {
            const bits = rows[row];
            for (0..font.glyph_w) |col| {
                if ((bits >> @intCast(font.glyph_w - 1 - col)) & 1 == 0) continue;
                const px = gx + @as(i32, @intCast(col));
                const py = y + @as(i32, @intCast(row));
                if (shadow) s.plot(px + 1, py + 1, color.shadow);
                s.plot(px, py, fg);
            }
        }
    }
}

/// Centered on the virtual 256 columns.
pub fn drawTextCentered(s: *const Surface, y: i32, text: []const u8, fg: u16) void {
    const tw = textWidth(text);
    const x: i32 = @intCast((256 -| tw) / 2);
    drawText(s, x, y, text, fg);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "surface: 512-wide frames double x and 320-wide frames center 256" {
    var buf: [512 * 4]u16 = @splat(0);

    const hires = Surface.init(buf[0 .. 512 * 4], 512, 4);
    try testing.expectEqual(@as(u32, 2), hires.xscale);
    hires.plot(0, 0, 0xFFFF);
    try testing.expectEqual(@as(u16, 0xFFFF), buf[0]);
    try testing.expectEqual(@as(u16, 0xFFFF), buf[1]); // the doubled column
    try testing.expectEqual(@as(u16, 0), buf[2]);

    buf = @splat(0);
    const wide = Surface.init(buf[0 .. 320 * 4], 320, 4);
    try testing.expectEqual(@as(u32, 1), wide.xscale);
    try testing.expectEqual(@as(u32, 32), wide.xoff); // (320-256)/2
    wide.plot(0, 0, 0xFFFF);
    try testing.expectEqual(@as(u16, 0xFFFF), buf[32]);
}

test "surface: plotting outside the frame is a no-op, not a wrap or a crash" {
    var buf: [256 * 2]u16 = @splat(0);
    const s = Surface.init(buf[0 .. 256 * 2], 256, 2);
    s.plot(-1, 0, 0xFFFF);
    s.plot(0, -1, 0xFFFF);
    s.plot(256, 0, 0xFFFF);
    s.plot(0, 2, 0xFFFF);
    for (buf) |p| try testing.expectEqual(@as(u16, 0), p);
}

test "dimAll halves every channel of every pixel" {
    var buf = [_]u16{ 0xFFFF, 0x0000, 0xF800, 0x07E0, 0x001F };
    const s = Surface.init(&buf, 5, 1);
    dimAll(&s);
    try testing.expectEqual(@as(u16, 0x7BEF), buf[0]); // white -> mid gray
    try testing.expectEqual(@as(u16, 0x0000), buf[1]);
    try testing.expectEqual(@as(u16, 0x7800), buf[2]); // red channel halved
    try testing.expectEqual(@as(u16, 0x03E0), buf[3]); // green halved
    try testing.expectEqual(@as(u16, 0x000F), buf[4]); // blue halved
}

test "drawText: lights the glyph's pixels with a drop shadow one down-right" {
    var buf: [64 * 16]u16 = @splat(0);
    const s = Surface.init(buf[0 .. 64 * 16], 64, 16);
    drawText(&s, 1, 1, "-", 0xFFFF);
    // '-' lights row 3 of the glyph, columns 0..4 -> real y=4, x=1..5.
    for (1..6) |x| try testing.expectEqual(@as(u16, 0xFFFF), buf[4 * 64 + x]);
    // Shadow: one right of the last lit pixel, one row down.
    try testing.expectEqual(@as(u16, color.shadow), buf[5 * 64 + 6]);
    // Text pixels win over their own shadow (drawn after it).
    try testing.expectEqual(@as(u16, 0xFFFF), buf[4 * 64 + 2]);
}

test "textWidth: 6 pixels per character" {
    try testing.expectEqual(@as(u32, 30), textWidth("SCALE"));
}
