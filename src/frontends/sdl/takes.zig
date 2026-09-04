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
            // `<game_id>-NNNN`
            if (stem.len < game_id.len + 2 or !std.mem.startsWith(u8, stem, game_id) or stem[game_id.len] != '-') continue;
            const number = stem[game_id.len + 1 ..];
            const path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ movies_dir, n }) catch continue;
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024)) catch {
                gpa.free(path);
                continue;
            };
            defer gpa.free(bytes);
            if (bytes.len < util.movie.header_len or !std.mem.eql(u8, bytes[0..4], util.movie.magic)) {
                gpa.free(path);
                continue;
            }
            const version = std.mem.readInt(u16, bytes[4..6], .little);
            const frames = std.mem.readInt(u32, bytes[12..16], .little);
            const anchored = version == util.movie.version and bytes.len >= util.movie.header_len_v2 and
                std.mem.readInt(u32, bytes[32..36], .little) != 0;
            var es_buf: [512]u8 = undefined;
            const es_name = std.fmt.bufPrint(&es_buf, "{s}.end.state", .{stem}) catch "";
            const has_end = if (es_name.len == 0) false else (if (dir.access(io, es_name, .{})) true else |_| false);
            const num = gpa.dupe(u8, number) catch {
                gpa.free(path);
                continue;
            };
            self.takes.append(gpa, .{ .path = path, .number = num, .frames = frames, .anchored = anchored, .has_end = has_end }) catch {
                gpa.free(path);
                gpa.free(num);
                continue;
            };
        }
        // Newest first: the numbers are zero-padded, so the string order is
        // the numeric order.
        std.mem.sort(Take, self.takes.items, {}, struct {
            fn lt(_: void, a: Take, b: Take) bool {
                return std.mem.order(u8, a.number, b.number) == .gt;
            }
        }.lt);
        if (self.takes.items.len == 0 and self.err_msg == null) self.err_msg = "NO TAKES OF THIS GAME YET";
        return self;
    }

    pub fn deinit(self: *Picker) void {
        for (self.takes.items) |t| {
            self.gpa.free(t.path);
            self.gpa.free(t.number);
        }
        self.takes.deinit(self.gpa);
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
                .confirm => if (self.selected()) |t| {
                    self.stage = .how;
                    self.how = if (t.has_end) 0 else 1;
                },
                .back, .close => return .close,
                .left, .right => {},
            },
            .how => switch (nav) {
                .up, .down, .left, .right => if (self.selected()) |t| {
                    if (t.has_end) self.how ^= 1;
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
        ui.drawText(s, 8, 18, "CONTINUE A RECORDING OF THIS GAME", ui.color.text_dim);
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
            const fg = if (sel) ui.color.text else ui.color.text_dim;
            var buf: [64]u8 = undefined;
            const secs = t.frames / 60;
            const label = std.fmt.bufPrint(&buf, "{s}  {d}:{d:0>2}:{d:0>2}", .{ t.number, secs / 3600, (secs / 60) % 60, secs % 60 }) catch "?";
            ui.drawText(s, 10, y, label, fg);
            const tag: []const u8 = if (t.has_end) "END STATE" else if (t.anchored) "ANCHORED" else "POWER-ON";
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
            if (t.has_end) {
                if (self.how == 0) ui.drawText(s, 14, y0, ">", ui.color.accent);
                ui.drawText(s, 22, y0, "ITS END STATE  (INSTANT)", if (self.how == 0) ui.color.text else ui.color.text_dim);
            } else {
                ui.drawText(s, 22, y0, "ITS END STATE  (NONE SAVED)", ui.color.text_dim);
            }
            if (self.how == 1) ui.drawText(s, 14, y1, ">", ui.color.accent);
            ui.drawText(s, 22, y1, "THE BEGINNING  (REPLAY, THEN CONTINUE)", if (self.how == 1) ui.color.text else ui.color.text_dim);
        }
        ui.drawText(s, 8, 200, if (self.stage == .list) "ENTER  CHOOSE    ESC  BACK" else "ENTER  GO    ESC  BACK", ui.color.text_dim);
    }
};
