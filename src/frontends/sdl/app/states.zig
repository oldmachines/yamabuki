//! Save-state slots: writing, reading and listing the eight slot files.
//!
//! Carved out of app.zig as pure code motion; every declaration
//! here is re-exported from app.zig, which stays the root.

const core = @import("snes_core");
const infopanel = @import("../infopanel.zig");
const std = @import("std");
const app_root = @import("../app.zig");

pub fn saveStateTo(io: std.Io, con: *core.AnyConsole, path: []const u8, slot: u32, buf: []u8, err: *std.Io.Writer) void {
    _ = con.saveState(buf);
    if (std.fs.path.dirname(path)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch {};
    if (std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf })) {
        err.print("state saved: slot {d} ({s})\n", .{ slot, path }) catch {};
        // The info palette's screenshot sidecar, from the frame on screen
        // right now. Best-effort on purpose: a thumbnail must never fail
        // (or slow) the save it decorates, and states saved before this
        // existed simply have none.
        var tp_buf: [512]u8 = undefined;
        if (std.fmt.bufPrint(&tp_buf, "{s}.thumb", .{path})) |tp| {
            var tf: [infopanel.Thumb.file_len]u8 = undefined;
            infopanel.Thumb.encode(con.framebuffer(), con.frameWidth(), &tf);
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tp, .data = &tf }) catch {};
        } else |_| {}
    } else |e| {
        err.print("state save failed: {s}\n", .{@errorName(e)}) catch {};
    }
    err.flush() catch {};
}

/// Re-gather what the info palette shows about the slots: which exist, and
/// their thumbnails. Eight stats and at most eight 7-KiB reads — palette-open
/// cost, never frame cost.
pub fn refreshSlots(
    io: std.Io,
    slot_paths: *const [9]?[]const u8,
    legacy_state_path: []const u8,
    infos: *[9]infopanel.SlotInfo,
) void {
    for (1..9) |n| {
        const path = slot_paths[n] orelse legacy_state_path;
        var inf: infopanel.SlotInfo = .{};
        inf.exists = if (std.Io.Dir.cwd().statFile(io, path, .{})) |_| true else |_| false;
        if (inf.exists) {
            var tp_buf: [512]u8 = undefined;
            if (std.fmt.bufPrint(&tp_buf, "{s}.thumb", .{path})) |tp| {
                var tf: [infopanel.Thumb.file_len]u8 = undefined;
                if (std.Io.Dir.cwd().readFile(io, tp, &tf)) |data| {
                    inf.thumb = infopanel.Thumb.decode(data);
                } else |_| {}
            } else |_| {}
        }
        infos[n] = inf;
    }
}

pub fn loadStateFrom(io: std.Io, con: *core.AnyConsole, path: []const u8, slot: u32, buf: []u8, err: *std.Io.Writer) bool {
    if (loadStateFile(io, con, path, buf)) {
        err.print("state loaded: slot {d} ({s})\n", .{ slot, path }) catch {};
        err.flush() catch {};
        return true;
    } else |e| {
        if (e == error.WrongRom)
            err.print("state load refused: slot {d} was saved on a different ROM or patch build (loading it would garble the whole machine)\n", .{slot}) catch {}
        else
            err.print("state load failed: {s}\n", .{@errorName(e)}) catch {};
        err.flush() catch {};
        return false;
    }
}

pub fn loadStateFile(io: std.Io, con: *core.AnyConsole, path: []const u8, buf: []u8) !void {
    const data = try std.Io.Dir.cwd().readFile(io, path, buf);
    try con.loadState(data);
}
