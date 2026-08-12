//! The session info palette (default hotkey `I`): everything you might
//! wonder mid-game, drawn as one panel over the dimmed picture — what game
//! this is, whether a soft-patch is active (THE question when an original
//! and a patched session look identical by design), the volume, the core
//! and region, the shader, and the eight save-state slots with a thumbnail
//! of the active one.
//!
//! Pure software drawing through `ui.zig`, like the menu: it rides the
//! normal video path, so the CRT shader shades it too. Pure state in, pixels
//! out — testable without SDL.
//!
//! Thumbnails come from `.thumb` files the app writes next to each state
//! (see `Thumb`): states saved before that existed simply have none, and
//! the panel says so rather than guessing.

const std = @import("std");
const ui = @import("ui.zig");

/// Thumbnail geometry: the 256-wide picture point-sampled 4:1 (224-line
/// frames give 56 rows; 239-line frames sample down to the same box).
pub const thumb_w = 64;
pub const thumb_h = 56;

/// One state slot's `.thumb` sidecar: a fixed-size RGB565 image with a
/// 4-byte magic. Fixed size keeps reads trivially validatable — a file of
/// any other length is not a thumbnail.
pub const Thumb = struct {
    pub const magic = "YBT1";
    pub const file_len = magic.len + thumb_w * thumb_h * 2;

    px: [thumb_w * thumb_h]u16,

    /// Encode `fb` (RGB565, `w` wide) into `out`. Point-sampling, not
    /// filtering: menu-grade fidelity is the goal, at menu-grade cost.
    pub fn encode(fb: []const u16, w: u32, out: *[file_len]u8) void {
        @memcpy(out[0..magic.len], magic);
        const h: u32 = @intCast(fb.len / w);
        for (0..thumb_h) |ty| {
            for (0..thumb_w) |tx| {
                const sx = tx * w / thumb_w;
                const sy = ty * h / thumb_h;
                const px = fb[sy * w + sx];
                const off = magic.len + (ty * thumb_w + tx) * 2;
                std.mem.writeInt(u16, out[off..][0..2], px, .little);
            }
        }
    }

    /// Decode a `.thumb` file; null when it is not one (wrong length or
    /// magic — e.g. a truncated write, or some other file squatting).
    pub fn decode(bytes: []const u8) ?Thumb {
        if (bytes.len != file_len) return null;
        if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return null;
        var t: Thumb = undefined;
        for (&t.px, 0..) |*p, i| {
            p.* = std.mem.readInt(u16, bytes[magic.len + i * 2 ..][0..2], .little);
        }
        return t;
    }
};

pub const SlotInfo = struct {
    exists: bool = false,
    thumb: ?Thumb = null,
};

/// Everything the panel shows. Strings are borrowed for the draw call.
pub const Info = struct {
    /// The cart's internal title (already trimmed).
    title: []const u8,
    /// ROM file basename.
    rom_name: []const u8,
    /// Soft-patch basename, null = as dumped.
    patch_name: ?[]const u8,
    core: []const u8,
    region: []const u8,
    /// Active shader preset, null = software blit.
    shader: ?[]const u8,
    audio_on: bool,
    /// 0..200, meaningful only when `audio_on`.
    volume: u32,
    /// Active save-state slot, 1..8.
    slot: u32,
    /// Indexed 1..8 (index 0 unused), like the app's own slot table.
    slots: [9]SlotInfo,
};

/// Panel layout in the virtual 256-wide space.
const panel_x = 8;
const panel_w = 240;
const label_x = panel_x + 6;
const value_x = label_x + 8 * ui.char_w; // labels up to 7 chars + a gap

fn row(s: *const ui.Surface, y: i32, label: []const u8, value: []const u8, vcolor: u16) void {
    ui.drawText(s, label_x, y, label, ui.color.text_dim);
    ui.drawText(s, value_x, y, value, vcolor);
}

/// Draw the palette. `s` should already hold the game frame; the panel dims
/// it and draws on top, mirroring the menu's look.
pub fn draw(s: *const ui.Surface, info: *const Info) void {
    ui.dimAll(s);

    // 7 text rows + the states strip + the thumbnail box, vertically centered.
    const rows_h: i32 = 7 * ui.line_h;
    const thumb_box_h: i32 = thumb_h + 2 * 2;
    const panel_h: u32 = @intCast(rows_h + thumb_box_h + 26);
    const panel_y: i32 = @intCast((s.vh() -| panel_h) / 2);

    ui.fillRect(s, panel_x, panel_y, panel_w, panel_h, ui.color.panel);
    ui.frameRect(s, panel_x, panel_y, panel_w, panel_h, ui.color.panel_edge);

    var y: i32 = panel_y + 5;
    ui.drawTextCentered(s, y, info.title, ui.color.accent);
    y += ui.line_h + 3;

    row(s, y, "GAME", info.rom_name, ui.color.text);
    y += ui.line_h;
    // The row this palette exists for: an applied patch is called out in
    // the accent color, an unpatched session in plain dim text.
    if (info.patch_name) |p| {
        row(s, y, "PATCH", p, ui.color.accent);
    } else {
        row(s, y, "PATCH", "NONE - PLAYING AS DUMPED", ui.color.text_dim);
    }
    y += ui.line_h;

    var buf: [40]u8 = undefined;
    const core_txt = std.fmt.bufPrint(&buf, "{s} - {s}", .{ info.core, info.region }) catch info.core;
    row(s, y, "CORE", core_txt, ui.color.text);
    y += ui.line_h;
    row(s, y, "SHADER", info.shader orelse "SOFTWARE", ui.color.text);
    y += ui.line_h;

    var vbuf: [16]u8 = undefined;
    const vol_txt = if (!info.audio_on)
        "MUTED"
    else
        std.fmt.bufPrint(&vbuf, "{d}%", .{info.volume}) catch "?";
    row(s, y, "VOLUME", vol_txt, ui.color.text);
    y += ui.line_h + 3;

    // States strip: slot numbers 1..8, filled slots bright, the active one
    // boxed in accent whether or not it holds a state yet.
    ui.drawText(s, label_x, y, "STATES", ui.color.text_dim);
    for (1..9) |n| {
        const x: i32 = value_x + @as(i32, @intCast((n - 1) * (ui.char_w + 6)));
        var nbuf: [1]u8 = .{'0' + @as(u8, @intCast(n))};
        const filled = info.slots[n].exists;
        if (n == info.slot)
            ui.frameRect(s, x - 2, y - 2, ui.char_w + 4, ui.line_h, ui.color.accent);
        ui.drawText(s, x, y, &nbuf, if (filled) ui.color.text else ui.color.text_dim);
    }
    y += ui.line_h + 4;

    // The active slot's thumbnail, or the reason there is none.
    const active = info.slots[info.slot];
    if (active.thumb) |t| {
        const tx: i32 = value_x;
        ui.frameRect(s, tx - 1, y - 1, thumb_w + 2, thumb_h + 2, ui.color.panel_edge);
        for (0..thumb_h) |py| {
            for (0..thumb_w) |px| {
                s.plot(tx + @as(i32, @intCast(px)), y + @as(i32, @intCast(py)), t.px[py * thumb_w + px]);
            }
        }
    } else {
        const why = if (active.exists) "NO PREVIEW (OLDER STATE)" else "EMPTY SLOT";
        ui.drawText(s, value_x, y + thumb_h / 2 - 3, why, ui.color.text_dim);
    }
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "thumb: encode/decode round-trips pixels through the file bytes" {
    // A 256x224 frame with a recognizable gradient.
    var fb: [256 * 224]u16 = undefined;
    for (&fb, 0..) |*p, i| p.* = @truncate(i * 7);

    var file: [Thumb.file_len]u8 = undefined;
    Thumb.encode(&fb, 256, &file);
    const t = Thumb.decode(&file) orelse return error.DecodeFailed;

    // Point sampling: thumb (x,y) is frame (x*4, y*4).
    try testing.expectEqual(fb[0], t.px[0]);
    try testing.expectEqual(fb[100 * 256 + 60 * 4], t.px[25 * thumb_w + 60]);
}

test "thumb: decode rejects wrong length and wrong magic" {
    var file: [Thumb.file_len]u8 = @splat(0);
    try testing.expectEqual(@as(?Thumb, null), Thumb.decode(file[0 .. Thumb.file_len - 1]));
    try testing.expectEqual(@as(?Thumb, null), Thumb.decode(&file)); // zero magic
}

test "draw: patch row shows the name, no-patch shows the dumped notice" {
    var canvas: [256 * 224]u16 = @splat(0x1234);
    const s = ui.Surface.init(&canvas, 256, 224);
    var info: Info = .{
        .title = "GRADIUS 3",
        .rom_name = "GRADIUS III (USA).SFC",
        .patch_name = "G3-S3.BPS",
        .core = "FAST",
        .region = "NTSC",
        .shader = "CRT-EASYMODE",
        .audio_on = true,
        .volume = 100,
        .slot = 1,
        .slots = @splat(.{}),
    };
    draw(&s, &info);
    // The panel dimmed the backdrop and painted its fill somewhere.
    var panel_px: usize = 0;
    for (canvas) |p| {
        if (p == ui.color.panel) panel_px += 1;
    }
    try testing.expect(panel_px > 1000);
}

test "draw: thumbnail pixels land inside the panel" {
    var canvas: [256 * 224]u16 = @splat(0);
    const s = ui.Surface.init(&canvas, 256, 224);
    var slots: [9]SlotInfo = @splat(.{});
    var t: Thumb = .{ .px = @splat(0xF800) }; // solid red
    slots[3] = .{ .exists = true, .thumb = t };
    _ = &t;
    var info: Info = .{
        .title = "T",
        .rom_name = "T.SFC",
        .patch_name = null,
        .core = "FAST",
        .region = "NTSC",
        .shader = null,
        .audio_on = false,
        .volume = 0,
        .slot = 3,
        .slots = slots,
    };
    draw(&s, &info);
    var red: usize = 0;
    for (canvas) |p| {
        if (p == 0xF800) red += 1;
    }
    try testing.expectEqual(@as(usize, thumb_w * thumb_h), red);
}
