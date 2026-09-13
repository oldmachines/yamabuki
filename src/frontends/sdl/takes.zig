//! The takes screen (F11): every recording of the running game, newest
//! first, and for the chosen one the two ways to continue it — from its end
//! state (the machine the take ends on, saved beside it at every stop) or
//! from its beginning (replay the inputs at full speed, then keep going).
//! Either way the recording continues: the file saved at F10 is the whole
//! playthrough. The app owns the machine; this owns the list and the cursor.

const std = @import("std");
const ui = @import("ui.zig");
const menu = @import("menu.zig");
const util = @import("util");

pub const Take = struct {
    /// Full path of the .ymv.
    path: []u8,
    /// The take's number as recorded in its file name (`-NNNN`).
    number: []u8,
    frames: u32,
    anchored: bool,
    /// Format 3: one entry per controller poll — replays on any build.
    per_poll: bool,
    /// Recorded on another build of this game (same title, other image).
    other_build: bool,
    /// `<take>.end.state` exists beside it (whether it loads is decided later).
    has_end: bool,
};

pub const Request = enum { none, close, start_end_state, start_replay };

const visible_rows: usize = 11;

pub const Picker = struct {
    gpa: std.mem.Allocator,
    takes: std.ArrayList(Take) = .empty,
    cursor: usize = 0,
    scroll: usize = 0,
    stage: enum { list, how } = .list,
    /// 0 = from the end state, 1 = from the beginning.
    how: u8 = 0,
    err_msg: ?[]const u8 = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, movies_dir: []const u8, game_id: []const u8) Picker {
        var self: Picker = .{ .gpa = gpa };
        var dir = std.Io.Dir.cwd().openDir(io, movies_dir, .{ .iterate = true }) catch {
            self.err_msg = "NO TAKES FOLDER YET";
            return self;
        };
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            const n = entry.name;
            if (!std.mem.endsWith(u8, n, util.movie.file_ext)) continue;
            const stem = n[0 .. n.len - util.movie.file_ext.len];
            // `<game_id>-NNNN`, where game_id is `<image hash>-<title>`: a
            // take of the same title from another image is listed too —
            // a per-poll one replays here (the SA-1 conversion of a game
            // continues the stock game's takes), the rest are shown greyed.
            if (stem.len < 6 or stem[stem.len - 5] != '-') continue;
            const number = stem[stem.len - 4 ..];
            const id = stem[0 .. stem.len - 5];
            const other_build = !std.mem.eql(u8, id, game_id);
            if (other_build) {
                const dash = std.mem.indexOfScalar(u8, game_id, '-') orelse continue;
                const title = game_id[dash..];
                if (id.len <= title.len or !std.mem.endsWith(u8, id, title)) continue;
            }
            const path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ movies_dir, n }) catch continue;
            // Only the header is needed to list a take, and a long take is
            // megabytes of entries: read the first `header_len_v2` bytes,
            // never the file.
            const head = readHeader(io, dir, n) orelse {
                gpa.free(path);
                continue;
            };
            const bytes = head.buf[0..head.len];
            if (bytes.len < util.movie.header_len or !std.mem.eql(u8, bytes[0..4], util.movie.magic)) {
                gpa.free(path);
                continue;
            }
            const version = std.mem.readInt(u16, bytes[4..6], .little);
            const frames = std.mem.readInt(u32, bytes[12..16], .little);
            // Formats 3 and 4 are both per poll (4 adds the lap cell) —
            // the same rule `movie.parse` applies.
            const per_poll = version == util.movie.version_polls or version == util.movie.version_laps;
            const anchored = (version == util.movie.version or per_poll) and bytes.len >= util.movie.header_len_v2 and
                std.mem.readInt(u32, bytes[32..36], .little) != 0;
            const es_name = std.fmt.allocPrint(gpa, "{s}.end.state", .{stem}) catch {
                gpa.free(path);
                continue;
            };
            defer gpa.free(es_name);
            const has_end = if (dir.access(io, es_name, .{})) true else |_| false;
            const num = gpa.dupe(u8, number) catch {
                gpa.free(path);
                continue;
            };
            self.takes.append(gpa, .{ .path = path, .number = num, .frames = frames, .anchored = anchored, .per_poll = per_poll, .other_build = other_build, .has_end = has_end }) catch {
                gpa.free(path);
                gpa.free(num);
                continue;
            };
        }
        // Newest first: the numbers are zero-padded, so the string order is
        // the numeric order.
        std.mem.sort(Take, self.takes.items, {}, struct {
            fn lt(_: void, a: Take, b: Take) bool {
                if (a.other_build != b.other_build) return !a.other_build;
                return std.mem.order(u8, a.number, b.number) == .gt;
            }
        }.lt);
        if (self.takes.items.len == 0 and self.err_msg == null) self.err_msg = "NO TAKES OF THIS GAME YET";
        return self;
    }

    const Header = struct {
        buf: [util.movie.header_len_v2]u8,
        len: usize,
    };

    /// The first header's worth of `name` inside `dir`, or null when the
    /// file cannot be opened or read. Short files return what they have.
    fn readHeader(io: std.Io, dir: std.Io.Dir, name: []const u8) ?Header {
        var f = dir.openFile(io, name, .{}) catch return null;
        defer f.close(io);
        var h: Header = .{ .buf = undefined, .len = 0 };
        h.len = f.readPositionalAll(io, &h.buf, 0) catch return null;
        return h;
    }

    pub fn deinit(self: *Picker) void {
        for (self.takes.items) |t| {
            self.gpa.free(t.path);
            self.gpa.free(t.number);
        }
        self.takes.deinit(self.gpa);
    }

    /// Whether the take can be continued here at all: this build's takes
    /// always; another build's only per poll and from power-on.
    pub fn usable(t: Take) bool {
        return !t.other_build or (t.per_poll and !t.anchored);
    }

    pub fn selected(self: *const Picker) ?*const Take {
        if (self.cursor >= self.takes.items.len) return null;
        return &self.takes.items[self.cursor];
    }

    pub fn handleNav(self: *Picker, nav: menu.NavEvent) Request {
        const n = self.takes.items.len;
        switch (self.stage) {
            .list => switch (nav) {
                .up => if (self.cursor > 0) {
                    self.cursor -= 1;
                },
                .down => if (n != 0 and self.cursor + 1 < n) {
                    self.cursor += 1;
                },
                .confirm => if (self.selected()) |t| if (usable(t.*)) {
                    self.stage = .how;
                    self.how = if (t.has_end and !t.other_build) 0 else 1;
                },
                .back, .close => return .close,
                .left, .right => {},
            },
            .how => switch (nav) {
                .up, .down, .left, .right => if (self.selected()) |t| {
                    if (t.has_end and !t.other_build) self.how ^= 1;
                },
                .confirm => return if (self.how == 0) .start_end_state else .start_replay,
                .back => self.stage = .list,
                .close => return .close,
            },
        }
        if (self.cursor < self.scroll) self.scroll = self.cursor;
        if (self.cursor >= self.scroll + visible_rows) self.scroll = self.cursor + 1 - visible_rows;
        return .none;
    }

    pub fn draw(self: *const Picker, s: *const ui.Surface) void {
        const w: i32 = @intCast(s.w);
        ui.fillRect(s, 0, 0, s.w, s.h, ui.color.panel);
        ui.drawText(s, 8, 6, "TAKES", ui.color.accent);
        ui.drawText(s, 8, 18, "CONTINUE A RECORDING OF THIS GAME (ANY BUILD)", ui.color.text_dim);
        if (self.err_msg) |msg| {
            ui.drawText(s, 8, 40, msg, ui.color.text);
            ui.drawText(s, 8, 200, "ESC  BACK", ui.color.text_dim);
            return;
        }
        for (0..visible_rows) |row| {
            const i = self.scroll + row;
            if (i >= self.takes.items.len) break;
            const t = self.takes.items[i];
            const y: i32 = @intCast(32 + row * ui.line_h);
            const sel = i == self.cursor;
            if (sel and self.stage == .list) ui.drawText(s, 2, y, ">", ui.color.accent);
            const fg = if (sel and usable(t)) ui.color.text else ui.color.text_dim;
            var buf: [64]u8 = undefined;
            const secs = t.frames / 60;
            const label = std.fmt.bufPrint(&buf, "{s}  {d}:{d:0>2}:{d:0>2}", .{ t.number, secs / 3600, (secs / 60) % 60, secs % 60 }) catch "?";
            ui.drawText(s, 10, y, label, fg);
            const tag: []const u8 = if (t.other_build) (if (usable(t)) "OTHER BUILD" else "OTHER BUILD -") else if (t.has_end) "END STATE" else if (t.anchored) "ANCHORED" else "POWER-ON";
            ui.drawText(s, w - 8 - @as(i32, @intCast(ui.textWidth(tag))), y, tag, fg);
        }
        if (self.stage == .how) {
            const t = self.takes.items[self.cursor];
            const top: i32 = 150;
            ui.fillRect(s, 8, top, s.w - 16, 44, ui.color.panel_edge);
            ui.fillRect(s, 9, top + 1, s.w - 18, 42, ui.color.panel);
            var buf: [48]u8 = undefined;
            const title = std.fmt.bufPrint(&buf, "CONTINUE TAKE {s} FROM", .{t.number}) catch "CONTINUE FROM";
            ui.drawText(s, 14, top + 4, title, ui.color.accent);
            const y0: i32 = top + 4 + @as(i32, @intCast(ui.line_h));
            const y1: i32 = y0 + @as(i32, @intCast(ui.line_h));
            if (t.has_end and !t.other_build) {
                if (self.how == 0) ui.drawText(s, 14, y0, ">", ui.color.accent);
                ui.drawText(s, 22, y0, "ITS END STATE  (INSTANT)", if (self.how == 0) ui.color.text else ui.color.text_dim);
            } else {
                ui.drawText(s, 22, y0, if (t.other_build) "ITS END STATE  (ANOTHER BUILD)" else "ITS END STATE  (NONE SAVED)", ui.color.text_dim);
            }
            if (self.how == 1) ui.drawText(s, 14, y1, ">", ui.color.accent);
            ui.drawText(s, 22, y1, "THE BEGINNING  (REPLAY, THEN CONTINUE)", if (self.how == 1) ui.color.text else ui.color.text_dim);
        }
        ui.drawText(s, 8, 200, if (self.stage == .list) "ENTER  CHOOSE    ESC  BACK" else "ENTER  GO    ESC  BACK", ui.color.text_dim);
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

/// Write a minimal take of `version` named `<stem>.ymv` into `dir`,
/// optionally with a (dummy) end state beside it.
fn writeTestTake(io: std.Io, dir: std.Io.Dir, stem: []const u8, version: u16, anchor_len: u32, with_end: bool) !void {
    var buf: [util.movie.header_len_v4]u8 = @splat(0);
    @memcpy(buf[0..4], util.movie.magic);
    std.mem.writeInt(u16, buf[4..6], version, .little);
    std.mem.writeInt(u32, buf[12..16], 7, .little);
    if (version != util.movie.version_plain) std.mem.writeInt(u32, buf[32..36], anchor_len, .little);
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{s}{s}", .{ stem, util.movie.file_ext });
    try dir.writeFile(io, .{ .sub_path = name, .data = &buf });
    if (with_end) {
        const es = try std.fmt.bufPrint(&name_buf, "{s}.end.state", .{stem});
        try dir.writeFile(io, .{ .sub_path = es, .data = "x" });
    }
}

fn tmpPath(buf: []u8, tmp: *const testing.TmpDir) []const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;
}

test "takes: the picker lists this game's takes newest first, other builds last, and reads only headers" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const game = "abcd1234-SUPER GAME";
    try writeTestTake(io, tmp.dir, game ++ "-0002", util.movie.version_plain, 0, false);
    try writeTestTake(io, tmp.dir, game ++ "-0010", util.movie.version, 64, true);
    try writeTestTake(io, tmp.dir, game ++ "-0001", util.movie.version_laps, 0, false);
    // Same title, another image: listed after this build's takes.
    try writeTestTake(io, tmp.dir, "ffff0000-SUPER GAME-0005", util.movie.version_polls, 0, false);
    // Not takes at all: wrong extension, no number, a five-digit number,
    // another title entirely, a directory that happens to end in .ymv.
    try tmp.dir.writeFile(io, .{ .sub_path = game ++ "-0003.txt", .data = "no" });
    try tmp.dir.writeFile(io, .{ .sub_path = game ++ ".ymv", .data = "no" });
    try tmp.dir.writeFile(io, .{ .sub_path = game ++ "-12345.ymv", .data = "no" });
    try writeTestTake(io, tmp.dir, "abcd1234-OTHER-0001", util.movie.version_plain, 0, false);
    try tmp.dir.createDirPath(io, game ++ "-0004.ymv");

    var pbuf: [128]u8 = undefined;
    var picker = Picker.init(testing.allocator, io, tmpPath(&pbuf, &tmp), game);
    defer picker.deinit();
    try testing.expectEqual(@as(?[]const u8, null), picker.err_msg);
    try testing.expectEqual(@as(usize, 4), picker.takes.items.len);
    const t = picker.takes.items;
    try testing.expectEqualStrings("0010", t[0].number);
    try testing.expectEqualStrings("0002", t[1].number);
    try testing.expectEqualStrings("0001", t[2].number);
    try testing.expectEqualStrings("0005", t[3].number);
    try testing.expect(t[3].other_build);
    try testing.expectEqual(@as(u32, 7), t[0].frames);
    // Format 2 with an anchor: anchored, and it has an end state.
    try testing.expect(t[0].anchored and t[0].has_end and !t[0].per_poll);
    // Format 4 (per lap) is per poll too — it used to read as POWER-ON
    // and be refused cross-build.
    try testing.expect(t[2].per_poll and !t[2].anchored);
    // Another build's per-poll power-on take is usable; its anchored or
    // per-frame takes would not be.
    try testing.expect(Picker.usable(t[3]));
    try testing.expect(!Picker.usable(.{ .path = "", .number = "", .frames = 0, .anchored = true, .per_poll = true, .other_build = true, .has_end = false }));
}

test "takes: an empty or missing folder reports why" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    var empty = Picker.init(testing.allocator, io, tmpPath(&pbuf, &tmp), "x-Y");
    defer empty.deinit();
    try testing.expectEqualStrings("NO TAKES OF THIS GAME YET", empty.err_msg.?);
    var missing = Picker.init(testing.allocator, io, ".zig-cache/tmp/no-such-dir-yamabuki", "x-Y");
    defer missing.deinit();
    try testing.expectEqualStrings("NO TAKES FOLDER YET", missing.err_msg.?);
}

test "takes: navigation — confirm needs a usable take, the how-stage only flips with an end state" {
    var picker: Picker = .{ .gpa = testing.allocator };
    defer picker.takes.deinit(testing.allocator);
    const mk = struct {
        fn take(has_end: bool, other: bool) Take {
            return .{ .path = "", .number = "", .frames = 1, .anchored = false, .per_poll = true, .other_build = other, .has_end = has_end };
        }
    };
    try picker.takes.append(testing.allocator, mk.take(false, false)); // 0: no end state
    try picker.takes.append(testing.allocator, mk.take(true, false)); // 1: end state
    for (0..20) |_| try picker.takes.append(testing.allocator, mk.take(false, false));

    // Confirm on a take without an end state goes straight to replay.
    try testing.expectEqual(Request.none, picker.handleNav(.confirm));
    try testing.expect(picker.stage == .how);
    try testing.expectEqual(@as(u8, 1), picker.how);
    _ = picker.handleNav(.down); // must not flip: nothing to flip to
    try testing.expectEqual(@as(u8, 1), picker.how);
    try testing.expectEqual(Request.start_replay, picker.handleNav(.confirm));
    try testing.expectEqual(Request.none, picker.handleNav(.back));
    try testing.expect(picker.stage == .list);

    // With an end state the default is the end state, and up/down toggles.
    _ = picker.handleNav(.down);
    _ = picker.handleNav(.confirm);
    try testing.expectEqual(@as(u8, 0), picker.how);
    _ = picker.handleNav(.down);
    try testing.expectEqual(@as(u8, 1), picker.how);
    _ = picker.handleNav(.up);
    try testing.expectEqual(Request.start_end_state, picker.handleNav(.confirm));
    _ = picker.handleNav(.back);

    // Scrolling follows the cursor past the visible rows.
    for (0..20) |_| _ = picker.handleNav(.down);
    try testing.expectEqual(@as(usize, 21), picker.cursor);
    try testing.expectEqual(@as(usize, 21 + 1 - visible_rows), picker.scroll);
    try testing.expectEqual(Request.close, picker.handleNav(.close));
}
