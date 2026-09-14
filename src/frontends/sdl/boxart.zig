//! Box art for the library screen: where a game's picture is looked for,
//! and the thumbnail it becomes.
//!
//! Discovery, first hit wins:
//!
//! 1. `<stem>.png` next to the ROM — `Game.png` beside `Game.sfc` or
//!    `Game.zip`, the same rule as a same-basename softpatch.
//! 2. `<ROM's folder>/boxart/<stem>.png` — one folder of pictures per ROM
//!    folder, the layout scrapers produce.
//! 3. `<pref path>/boxart/<stem>.png` — pictures kept with the emulator's
//!    own data, away from read-only ROM folders.
//! 4. `<pref path>/boxart/<game_id>.png` — keyed by content, so one
//!    picture serves every dump of the game and survives a rename.
//!
//! PNG only, decoded by the repo's own decoder (png.zig): a picture in any
//! other format is simply not found, and the panel says so. The thumbnail
//! is scaled to fit the panel's box by area averaging (down) or nearest
//! (up), composited over the panel colour, and packed to RGB565 so the
//! screen blits it like any other pixels.

const std = @import("std");
const png = @import("png.zig");
const ui = @import("ui.zig");

/// The panel's box, in the library screen's 256x224 virtual pixels.
pub const max_w: u32 = 84;
pub const max_h: u32 = 104;

/// The largest picture file read, and the largest image decoded: a scan
/// at 2000x2000 is far more than the thumbnail can use.
pub const max_file_bytes: usize = 16 << 20;
pub const max_pixels: usize = 4 << 20;

pub const Thumb = struct {
    w: u32,
    h: u32,
    px: [max_w * max_h]u16,
};

/// `roms/Game (U).zip` -> `Game (U)`: the basename without its extension.
pub fn stem(rom_path: []const u8) []const u8 {
    const base = std.fs.path.basename(rom_path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    return if (dot == 0) base else base[0..dot];
}

/// Every place a picture is looked for, in order. Paths are owned by
/// `gpa`; `pref_dir` null (no per-user data directory) drops rules 3-4.
pub fn candidates(gpa: std.mem.Allocator, rom_path: []const u8, game_id: []const u8, pref_dir: ?[]const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |p| gpa.free(p);
        list.deinit(gpa);
    }
    const dir = std.fs.path.dirname(rom_path) orelse ".";
    const stem_png = try std.fmt.allocPrint(gpa, "{s}.png", .{stem(rom_path)});
    defer gpa.free(stem_png);
    try list.append(gpa, try std.fs.path.join(gpa, &.{ dir, stem_png }));
    try list.append(gpa, try std.fs.path.join(gpa, &.{ dir, "boxart", stem_png }));
    if (pref_dir) |pd| {
        try list.append(gpa, try std.fs.path.join(gpa, &.{ pd, stem_png }));
        if (game_id.len != 0) {
            const id_png = try std.fmt.allocPrint(gpa, "{s}.png", .{game_id});
            defer gpa.free(id_png);
            try list.append(gpa, try std.fs.path.join(gpa, &.{ pd, id_png }));
        }
    }
    return list.toOwnedSlice(gpa);
}

/// The first candidate that exists as a file, owned by `gpa`; null when
/// the game has no picture anywhere.
pub fn find(io: std.Io, gpa: std.mem.Allocator, rom_path: []const u8, game_id: []const u8, pref_dir: ?[]const u8) ?[]const u8 {
    const all = candidates(gpa, rom_path, game_id, pref_dir) catch return null;
    defer gpa.free(all);
    var hit: ?[]const u8 = null;
    for (all) |p| {
        if (hit == null) {
            if (std.Io.Dir.cwd().statFile(io, p, .{})) |st| {
                if (st.kind == .file) {
                    hit = p;
                    continue;
                }
            } else |_| {}
        }
        gpa.free(p);
    }
    return hit;
}

/// The thumbnail's size: the picture scaled to fit the box, aspect kept.
pub fn fit(w: u32, h: u32, box_w: u32, box_h: u32) [2]u32 {
    if (w == 0 or h == 0) return .{ 1, 1 };
    // Whichever axis is the tighter fit sets the scale.
    if (@as(u64, w) * box_h >= @as(u64, h) * box_w) {
        return .{ box_w, @max(1, @as(u32, @intCast(@as(u64, h) * box_w / w))) };
    }
    return .{ @max(1, @as(u32, @intCast(@as(u64, w) * box_h / h))), box_h };
}

/// Scale `img` to `dw`x`dh` into `out` (row-major, `dw*dh` entries) as
/// RGB565, every source pixel first composited over `bg`. A destination
/// pixel averages the block of source pixels that map onto it, so a
/// downscale is a box filter and an upscale is nearest.
pub fn scale(img: png.Image, dw: u32, dh: u32, bg: [3]u8, out: []u16) void {
    std.debug.assert(out.len >= @as(usize, dw) * dh);
    for (0..dh) |dy| {
        const y0: usize = dy * img.h / dh;
        const y1: usize = @max(y0 + 1, (dy + 1) * img.h / dh);
        for (0..dw) |dx| {
            const x0: usize = dx * img.w / dw;
            const x1: usize = @max(x0 + 1, (dx + 1) * img.w / dw);
            var sum: [3]u32 = .{ 0, 0, 0 };
            var n: u32 = 0;
            for (y0..y1) |sy| for (x0..x1) |sx| {
                const p = img.rgba[(sy * img.w + sx) * 4 ..][0..4];
                const a: u32 = p[3];
                for (0..3) |c| sum[c] += (@as(u32, p[c]) * a + @as(u32, bg[c]) * (255 - a)) / 255;
                n += 1;
            };
            const r = sum[0] / n;
            const g = sum[1] / n;
            const b = sum[2] / n;
            out[dy * dw + dx] = @intCast(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
        }
    }
}

/// The panel colour, unpacked, for compositing transparent art over.
pub fn panelRgb() [3]u8 {
    const c: u32 = ui.color.panel;
    const r5 = (c >> 11) & 0x1F;
    const g6 = (c >> 5) & 0x3F;
    const b5 = c & 0x1F;
    return .{ @intCast((r5 << 3) | (r5 >> 2)), @intCast((g6 << 2) | (g6 >> 4)), @intCast((b5 << 3) | (b5 >> 2)) };
}

/// Read, decode, and fit one picture. Null for anything that is not a
/// usable PNG — the panel treats it as no art.
pub fn load(io: std.Io, gpa: std.mem.Allocator, path: []const u8, thumb: *Thumb) bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch return false;
    defer gpa.free(bytes);
    var img = png.decode(gpa, bytes, max_pixels) catch return false;
    defer img.deinit(gpa);
    const d = fit(img.w, img.h, max_w, max_h);
    thumb.w = d[0];
    thumb.h = d[1];
    scale(img, d[0], d[1], panelRgb(), &thumb.px);
    return true;
}

/// Blit a thumbnail with its top-left at (x, y) on the surface.
pub fn draw(s: *const ui.Surface, x: i32, y: i32, t: *const Thumb) void {
    for (0..t.h) |dy| for (0..t.w) |dx| {
        s.plot(x + @as(i32, @intCast(dx)), y + @as(i32, @intCast(dy)), t.px[dy * t.w + dx]);
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "boxart: stem and the candidate list, in order" {
    try testing.expectEqualStrings("Game (U)", stem("roms/Game (U).zip"));
    // A backslash is a separator only where the OS says so.
    if (@import("builtin").os.tag == .windows) try testing.expectEqualStrings("Game", stem("C:\\roms\\Game.sfc"));
    try testing.expectEqualStrings("dump", stem("dump"));
    try testing.expectEqualStrings(".hidden", stem("x/.hidden"));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = try candidates(a, "roms/sub/Game.zip", "abcd-game", "pref/boxart");
    try testing.expectEqual(@as(usize, 4), all.len);
    try testing.expect(std.mem.endsWith(u8, all[0], "Game.png"));
    try testing.expect(std.mem.startsWith(u8, all[0], "roms"));
    try testing.expect(std.mem.indexOf(u8, all[1], "boxart") != null);
    try testing.expect(std.mem.endsWith(u8, all[1], "Game.png"));
    try testing.expect(std.mem.startsWith(u8, all[2], "pref"));
    try testing.expect(std.mem.endsWith(u8, all[3], "abcd-game.png"));
    // No per-user directory: the two ROM-side rules only.
    const two = try candidates(a, "Game.sfc", "id", null);
    try testing.expectEqual(@as(usize, 2), two.len);
}

test "boxart: fit keeps the aspect and never exceeds the box" {
    try testing.expectEqual([2]u32{ 74, 104 }, fit(500, 700, 84, 104)); // tall (JP box)
    try testing.expectEqual([2]u32{ 84, 60 }, fit(700, 500, 84, 104)); // wide (US box)
    try testing.expectEqual([2]u32{ 84, 84 }, fit(10, 10, 84, 104)); // small pictures scale up
    try testing.expectEqual([2]u32{ 84, 1 }, fit(4000, 1, 84, 104)); // a sliver still has a row
    try testing.expectEqual([2]u32{ 1, 1 }, fit(0, 0, 84, 104));
}

test "boxart: scale box-filters a downscale and composites alpha over the panel" {
    // 4x2 image: left half opaque red, right half half-transparent white.
    var rgba: [4 * 2 * 4]u8 = undefined;
    for (0..2) |y| for (0..4) |x| {
        const p = rgba[(y * 4 + x) * 4 ..][0..4];
        if (x < 2) p.* = .{ 255, 0, 0, 255 } else p.* = .{ 255, 255, 255, 128 };
    };
    const img: png.Image = .{ .w = 4, .h = 2, .rgba = &rgba };
    var out: [2]u16 = undefined;
    scale(img, 2, 1, .{ 0, 0, 0 }, &out);
    try testing.expectEqual(@as(u16, 0xF800), out[0]); // pure red
    // White at alpha 128 over black: 128/255*255 = 128 per channel -> 0x8410.
    try testing.expectEqual(@as(u16, 0x8410), out[1]);

    // A 2x2 block average: (255,0,0) and (0,0,255) in one column -> purple.
    var col: [2 * 2 * 4]u8 = .{ 255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255 };
    const img2: png.Image = .{ .w = 2, .h = 2, .rgba = &col };
    var one: [1]u16 = undefined;
    scale(img2, 1, 1, .{ 0, 0, 0 }, &one);
    try testing.expectEqual(@as(u16, 0x780F), one[0]); // r=127>>3=15, b=127>>3=15

    // Upscale is nearest: a 1x1 pixel fills the whole 3x2 output.
    var px: [4]u8 = .{ 0, 255, 0, 255 };
    const img3: png.Image = .{ .w = 1, .h = 1, .rgba = &px };
    var six: [6]u16 = undefined;
    scale(img3, 3, 2, .{ 0, 0, 0 }, &six);
    for (six) |v| try testing.expectEqual(@as(u16, 0x07E0), v);
}

test "boxart: find honours the discovery order; load fits a real PNG" {
    const a = testing.allocator;
    const io = testing.io;
    const root = ".cover-test-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/roms/boxart");
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/pref");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const rom = root ++ "/roms/Game.zip";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = rom, .data = "" });

    // A 30x20 picture: solid green.
    var rgb: [30 * 20 * 3]u8 = undefined;
    for (0..30 * 20) |i| rgb[i * 3 ..][0..3].* = .{ 0, 255, 0 };
    const file = try png.encode(a, &rgb, 30, 20);
    defer a.free(file);

    try testing.expect(find(io, a, rom, "id", root ++ "/pref") == null);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/pref/id.png", .data = file });
    const by_id = find(io, a, rom, "id", root ++ "/pref").?;
    defer a.free(by_id);
    try testing.expect(std.mem.endsWith(u8, by_id, "id.png"));

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/roms/boxart/Game.png", .data = file });
    const by_folder = find(io, a, rom, "id", root ++ "/pref").?;
    defer a.free(by_folder);
    try testing.expect(std.mem.indexOf(u8, by_folder, "boxart") != null);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/roms/Game.png", .data = file });
    const beside = find(io, a, rom, "id", root ++ "/pref").?;
    defer a.free(beside);
    try testing.expect(std.mem.indexOf(u8, beside, "boxart") == null);

    var t: Thumb = undefined;
    try testing.expect(load(io, a, beside, &t));
    try testing.expectEqual(@as(u32, 84), t.w);
    try testing.expectEqual(@as(u32, 56), t.h);
    try testing.expectEqual(@as(u16, 0x07E0), t.px[0]);
    try testing.expectEqual(@as(u16, 0x07E0), t.px[84 * 56 - 1]);

    // Not a PNG: no art, no crash.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/roms/Game.png", .data = "JFIF nope" });
    try testing.expect(!load(io, a, beside, &t));
}
