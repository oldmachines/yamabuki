//! Screenshots and numbered output files: the `--shot` frame filter, the next free `<stem>-NNNN` name, and the PNG writer.
//!
//! Carved out of app.zig as pure code motion; every declaration
//! here is re-exported from app.zig, which stays the root.

const png = @import("../png.zig");
const std = @import("std");
const app_root = @import("../app.zig");

/// Is `frame` one of the moments we were asked to capture? An empty list means
/// "the last frame only", which is what a bare `--shot` with `--frames N`
/// wants. (`total` is `--frames`; parseArgs rejects a bare `--shot` when it is
/// zero, i.e. run-until-quit, because "the last frame" does not exist then.)
pub fn wantsShot(frames: []const u32, frame: u32, total: u32) bool {
    if (frames.len == 0) return total != 0 and frame == total;
    for (frames) |f| {
        if (f == frame) return true;
    }
    return false;
}

/// The first `<dir>/<stem>-NNNN<ext>` (NNNN from 0001) that does not exist
/// yet, allocated into `gpa`; null when every number up to 9999 is taken or
/// the name cannot be built. Shared by takes and screenshots so both
/// number the same way.
pub fn nextNumberedPath(io: std.Io, gpa: std.mem.Allocator, dir: []const u8, stem: []const u8, ext: []const u8) ?[]u8 {
    var n: u32 = 1;
    while (n <= 9999) : (n += 1) {
        const p = std.fmt.allocPrint(gpa, "{s}/{s}-{d:0>4}{s}", .{ dir, stem, n, ext }) catch return null;
        std.Io.Dir.cwd().access(io, p, .{}) catch return p;
        gpa.free(p);
    }
    return null;
}

pub fn writeScreenshot(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: []const u8,
    game_id: []const u8,
    rgb: []const u8,
    w: u32,
    h: u32,
    err: *std.Io.Writer,
) void {
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const path = nextNumberedPath(io, gpa, dir, game_id, ".png") orelse {
        err.print("screenshot: no free number under {s}; not written\n", .{dir}) catch {};
        err.flush() catch {};
        return;
    };
    defer gpa.free(path);
    const data = png.encode(gpa, rgb, w, h) catch |e| {
        err.print("screenshot failed: {s}\n", .{@errorName(e)}) catch {};
        err.flush() catch {};
        return;
    };
    defer gpa.free(data);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch |e| {
        err.print("screenshot failed: {s}\n", .{@errorName(e)}) catch {};
        err.flush() catch {};
        return;
    };
    err.print("screenshot: {s}\n", .{path}) catch {};
    err.flush() catch {};
}
