//! In-app folder picker: browse the filesystem with the same fixed nav as
//! the rest of the overlay UI (confirm activates a row, there is no partial
//! text entry), so adding a ROM directory no longer needs a hand-edit of
//! config.zon. Every row is one of four kinds — USE THIS FOLDER, `..`, a
//! subdirectory, or the SHOW HIDDEN FOLDERS toggle (always last) — which
//! keeps the picker an extension of the confirm-on-a-row idiom `menu.zig`
//! and the library list already use, instead of a new text-input widget.
//!
//! On Windows there is no single filesystem root, so browsing starts at a
//! virtual "drive list" (probed by trying to open each letter) and `..` from
//! a drive's top returns to it. On POSIX there is one root, "/", and `..`
//! disappears once you're there. All filesystem access is swallowed into
//! `err_msg` rather than propagated — a permission-denied folder costs a
//! message, never a crash, matching `library.zig`'s scanner.

const std = @import("std");
const builtin = @import("builtin");

const RowKind = union(enum) {
    use_folder,
    up,
    toggle_hidden,
    /// Windows drive-list rows carry the full drive path (e.g. "C:\\");
    /// regular listing rows carry just the child directory's name.
    entry: []const u8,
};

pub const Result = union(enum) {
    none,
    /// The path to add to `library.rom_dirs`. Borrowed from the picker's own
    /// `path` buffer — copy it out (e.g. via `Config.addRomDir`, which dupes)
    /// before the next call or `deinit`.
    use_folder: []const u8,
    /// SHOW HIDDEN FOLDERS was flipped to this value — the caller owns
    /// `Config`, so it persists it; the picker only re-filters its listing.
    toggled_hidden: bool,
};

pub const Picker = struct {
    gpa: std.mem.Allocator,
    /// Absolute path being browsed. Empty while `at_root`.
    path: std.ArrayList(u8) = .empty,
    /// Showing the virtual Windows drive list rather than a real directory.
    at_root: bool = false,
    /// Owned display names for the current listing (directory names when
    /// browsing, full drive paths when `at_root`).
    dirs: std.ArrayList([]u8) = .empty,
    err_msg: ?[]const u8 = null,
    /// List dot-directories too (the cross-platform "hidden" convention —
    /// there's no separate OS attribute on POSIX, so this is the one rule
    /// that means the same thing on every target). Off by default: a fresh
    /// user profile is dozens of tool dotdirs deep before the first ROM
    /// folder. Toggled from the SHOW HIDDEN FOLDERS row, the picker's own
    /// last row on every screen — flipping it re-filters the current
    /// listing in place, without changing `path`.
    show_hidden: bool = false,

    /// The real entry point: Windows starts at the drive list (there is no
    /// path that reaches every drive by going "up"); POSIX starts at "/".
    pub fn init(gpa: std.mem.Allocator, io: std.Io, show_hidden: bool) Picker {
        var p: Picker = .{ .gpa = gpa, .show_hidden = show_hidden };
        if (builtin.os.tag == .windows) {
            p.listDrives(io);
        } else {
            p.descend(io, "/");
        }
        return p;
    }

    /// Test-only entry point: skip platform root detection and list `path`
    /// directly, so tests stay hermetic (a temp directory, not the real /
    /// or C:\).
    pub fn initAt(gpa: std.mem.Allocator, io: std.Io, path: []const u8) Picker {
        return initAtShowing(gpa, io, path, false);
    }

    pub fn initAtShowing(gpa: std.mem.Allocator, io: std.Io, path: []const u8, show_hidden: bool) Picker {
        var p: Picker = .{ .gpa = gpa, .show_hidden = show_hidden };
        p.descend(io, path);
        return p;
    }

    pub fn deinit(self: *Picker) void {
        self.path.deinit(self.gpa);
        for (self.dirs.items) |d| self.gpa.free(d);
        self.dirs.deinit(self.gpa);
    }

    /// Whether `up` has anywhere to go: always true on Windows (worst case,
    /// back to the drive list); on POSIX, true until `path` is "/".
    fn canGoUp(self: *const Picker) bool {
        if (builtin.os.tag == .windows) return true;
        return std.fs.path.dirname(self.path.items) != null;
    }

    /// The SHOW HIDDEN FOLDERS row is always last, on every screen — the
    /// drive list included, so the setting is reachable before you've ever
    /// descended into a real directory.
    pub fn rowCount(self: *const Picker) usize {
        const base = if (self.at_root)
            self.dirs.items.len
        else
            1 + @as(usize, if (self.canGoUp()) 1 else 0) + self.dirs.items.len;
        return base + 1;
    }

    fn rowKind(self: *const Picker, i: usize) RowKind {
        if (i == self.rowCount() - 1) return .toggle_hidden;
        if (self.at_root) return .{ .entry = self.dirs.items[i] };
        var idx = i;
        if (idx == 0) return .use_folder;
        idx -= 1;
        if (self.canGoUp()) {
            if (idx == 0) return .up;
            idx -= 1;
        }
        return .{ .entry = self.dirs.items[idx] };
    }

    /// Row label for rendering.
    pub fn rowLabel(self: *const Picker, i: usize) []const u8 {
        return switch (self.rowKind(i)) {
            .use_folder => "USE THIS FOLDER",
            .up => "..",
            .toggle_hidden => "SHOW HIDDEN FOLDERS",
            .entry => |name| name,
        };
    }

    /// Right-aligned value for rendering; "" for rows that don't have one.
    pub fn rowValue(self: *const Picker, i: usize) []const u8 {
        return switch (self.rowKind(i)) {
            .toggle_hidden => if (self.show_hidden) "ON" else "OFF",
            else => "",
        };
    }

    /// Activate row `i`: descend into a directory, go up, flip SHOW HIDDEN
    /// FOLDERS, or report the current path to be added as a ROM directory.
    pub fn activate(self: *Picker, io: std.Io, i: usize) Result {
        if (i >= self.rowCount()) return .none;
        switch (self.rowKind(i)) {
            .use_folder => return .{ .use_folder = self.path.items },
            .up => self.up(io),
            .toggle_hidden => {
                self.show_hidden = !self.show_hidden;
                self.relist(io);
                return .{ .toggled_hidden = self.show_hidden };
            },
            .entry => |name| {
                if (self.at_root) {
                    self.descend(io, name);
                } else {
                    const child = std.fs.path.join(self.gpa, &.{ self.path.items, name }) catch return .none;
                    defer self.gpa.free(child);
                    self.descend(io, child);
                }
            },
        }
        return .none;
    }

    /// Re-apply the current listing (drive list or directory) without
    /// changing `path` — used after flipping SHOW HIDDEN FOLDERS. Safe to
    /// pass `self.path.items` straight to `descend`: it copies its `path`
    /// argument out before touching `self.path`, so re-listing the exact
    /// path it's already showing doesn't race itself.
    fn relist(self: *Picker, io: std.Io) void {
        if (self.at_root) {
            self.listDrives(io);
        } else {
            self.descend(io, self.path.items);
        }
    }

    fn up(self: *Picker, io: std.Io) void {
        if (self.at_root) return;
        // `parent` is a slice into `self.path`'s own storage; `descend`
        // copies its `path` argument out before touching `self.path`, so
        // passing the alias straight through is safe.
        if (std.fs.path.dirname(self.path.items)) |parent| {
            self.descend(io, parent);
        } else if (builtin.os.tag == .windows) {
            self.listDrives(io);
        }
    }

    /// List `path`'s subdirectories and make it current. Leaves the picker
    /// where it was on failure, with `err_msg` set.
    ///
    /// `path` may alias memory this function is about to free or overwrite —
    /// activating a drive-list row passes one of `self.dirs`' own entries,
    /// `up()` passes a slice of `self.path` itself, and `relist()` passes
    /// `self.path.items` verbatim. So `path` is copied into its own buffer
    /// *before* `self.dirs`/`self.path` are touched; reordering that used to
    /// free `path`'s backing memory while still reading from it, corrupting
    /// `self.path` into garbage that only surfaced as a failure one
    /// directory later.
    fn descend(self: *Picker, io: std.Io, path: []const u8) void {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch {
            self.err_msg = "CANNOT OPEN THAT FOLDER";
            return;
        };
        defer dir.close(io);

        var new_path: std.ArrayList(u8) = .empty;
        new_path.appendSlice(self.gpa, path) catch {
            new_path.deinit(self.gpa);
            self.err_msg = "OUT OF MEMORY";
            return;
        };

        var fresh: std.ArrayList([]u8) = .empty;
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            // A reparse point (Windows) is never `.directory` even when it
            // behaves like one — cloud-sync placeholders (Dropbox, iCloud,
            // OneDrive) and NTFS junctions both land here. Resolving them
            // costs one extra open, paid only for the entries that need it.
            const is_dir = switch (entry.kind) {
                .directory => true,
                .sym_link, .unknown => isDirReparsePoint(dir, io, entry.name),
                else => false,
            };
            if (!is_dir) continue;
            if (!self.show_hidden and entry.name.len != 0 and entry.name[0] == '.') continue;
            const name = self.gpa.dupe(u8, entry.name) catch continue;
            fresh.append(self.gpa, name) catch self.gpa.free(name);
        }
        std.mem.sort([]u8, fresh.items, {}, lessThanIgnoreCase);

        for (self.dirs.items) |d| self.gpa.free(d);
        self.dirs.deinit(self.gpa);
        self.dirs = fresh;

        self.path.deinit(self.gpa);
        self.path = new_path;
        self.at_root = false;
        self.err_msg = null;
    }

    /// Whether `name` (a `.sym_link`/`.unknown`-kind entry, i.e. some flavor
    /// of reparse point) actually behaves as a directory. `openDir` follows
    /// the reparse point the same way Explorer does — a broken junction or a
    /// file symlink simply fails and is treated as not-a-directory.
    fn isDirReparsePoint(dir: std.Io.Dir, io: std.Io, name: []const u8) bool {
        var sub = dir.openDir(io, name, .{}) catch return false;
        sub.close(io);
        return true;
    }

    fn listDrives(self: *Picker, io: std.Io) void {
        var fresh: std.ArrayList([]u8) = .empty;
        for ('A'..'Z' + 1) |c| {
            const letter: u8 = @intCast(c);
            const drive = std.fmt.allocPrint(self.gpa, "{c}:\\", .{letter}) catch continue;
            var dir = std.Io.Dir.cwd().openDir(io, drive, .{}) catch {
                self.gpa.free(drive);
                continue;
            };
            dir.close(io);
            fresh.append(self.gpa, drive) catch self.gpa.free(drive);
        }

        for (self.dirs.items) |d| self.gpa.free(d);
        self.dirs.deinit(self.gpa);
        self.dirs = fresh;

        self.path.clearRetainingCapacity();
        self.at_root = true;
        self.err_msg = if (self.dirs.items.len == 0) "NO DRIVES FOUND" else null;
    }

    fn lessThanIgnoreCase(_: void, a: []u8, b: []u8) bool {
        const n = @min(a.len, b.len);
        for (0..n) |i| {
            const ca = std.ascii.toUpper(a[i]);
            const cb = std.ascii.toUpper(b[i]);
            if (ca != cb) return ca < cb;
        }
        return a.len < b.len;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "dirpicker: dot-directories are hidden by default and shown with show_hidden" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = ".dirpicker-test-hidden";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/.git");
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/visible");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var hidden = Picker.initAt(a, io, root); // show_hidden defaults to false
    defer hidden.deinit();
    try testing.expectEqual(@as(usize, 1), hidden.dirs.items.len);
    try testing.expectEqualStrings("visible", hidden.dirs.items[0]);

    var shown = Picker.initAtShowing(a, io, root, true);
    defer shown.deinit();
    try testing.expectEqual(@as(usize, 2), shown.dirs.items.len);
    try testing.expectEqualStrings(".git", shown.dirs.items[0]); // '.' sorts before 'v'
    try testing.expectEqualStrings("visible", shown.dirs.items[1]);
}

test "dirpicker: lists subdirectories sorted, case-insensitively, dirs only" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = ".dirpicker-test-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/banana");
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/Apple");
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/cherry");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/not-a-dir.txt", .data = "x" });
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var p = Picker.initAt(a, io, root);
    defer p.deinit();

    try testing.expectEqual(@as(usize, 3), p.dirs.items.len); // the file is excluded
    try testing.expectEqualStrings("Apple", p.dirs.items[0]);
    try testing.expectEqualStrings("banana", p.dirs.items[1]);
    try testing.expectEqualStrings("cherry", p.dirs.items[2]);
}

test "dirpicker: rows are USE THIS FOLDER, .., then entries; activate descends and goes up" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = ".dirpicker-test-nav";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/sub");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var p = Picker.initAt(a, io, root);
    defer p.deinit();

    // USE THIS FOLDER, .., sub, SHOW HIDDEN FOLDERS -> 4 rows.
    try testing.expectEqual(@as(usize, 4), p.rowCount());
    try testing.expectEqualStrings("USE THIS FOLDER", p.rowLabel(0));
    try testing.expectEqualStrings("..", p.rowLabel(1));
    try testing.expectEqualStrings("sub", p.rowLabel(2));
    try testing.expectEqualStrings("SHOW HIDDEN FOLDERS", p.rowLabel(3));

    // Descending into "sub" relists (now empty: USE THIS FOLDER + .. + toggle).
    try testing.expectEqual(@as(Result, .none), p.activate(io, 2));
    try testing.expectEqual(@as(usize, 3), p.rowCount());
    try testing.expect(std.mem.endsWith(u8, p.path.items, "sub"));

    // ".." returns to the parent, which lists "sub" again.
    _ = p.activate(io, 1);
    try testing.expectEqual(@as(usize, 4), p.rowCount());
    try testing.expect(std.mem.endsWith(u8, p.path.items, root));
}

test "dirpicker: SHOW HIDDEN FOLDERS is always the last row and toggling re-filters in place" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = ".dirpicker-test-toggle";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/.git");
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/visible");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var p = Picker.initAt(a, io, root);
    defer p.deinit();

    // USE THIS FOLDER, .., visible, SHOW HIDDEN FOLDERS: .git stays hidden.
    try testing.expectEqual(@as(usize, 4), p.rowCount());
    try testing.expectEqualStrings("SHOW HIDDEN FOLDERS", p.rowLabel(3));
    try testing.expectEqualStrings("OFF", p.rowValue(3));

    switch (p.activate(io, 3)) {
        .toggled_hidden => |v| try testing.expect(v),
        else => try testing.expect(false),
    }
    try testing.expect(p.show_hidden);
    try testing.expectEqualStrings("ON", p.rowValue(4)); // one more row now (.git)
    // .., .git, visible, SHOW HIDDEN FOLDERS — path/at_root untouched.
    try testing.expectEqual(@as(usize, 5), p.rowCount());
    try testing.expectEqualStrings(".git", p.rowLabel(2));
    try testing.expectEqualStrings(root, p.path.items);

    // Flipping back drops .git again.
    _ = p.activate(io, 4);
    try testing.expectEqual(@as(usize, 4), p.rowCount());
    try testing.expect(!p.show_hidden);
}

test "dirpicker: activating an at_root entry survives descend() freeing that entry's own backing memory" {
    // Regression test for a real bug: activating a root-listed row (the
    // Windows drive list) passes a `[]u8` owned by `self.dirs`, and
    // `descend()` used to free every `self.dirs` entry before consuming
    // its `path` argument — silently reading freed memory into `self.path`
    // rather than crashing, so it only surfaced when the *next* descend
    // built a path from the corrupted `self.path`.
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = ".dirpicker-test-aliasing";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/child");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    // Simulate the drive-list state directly: `dirs` holds the same kind of
    // caller-facing path a real drive row would ("C:\" on Windows), and
    // `activate` on an `at_root` row hands that exact slice to `descend`.
    var p: Picker = .{ .gpa = a };
    try p.dirs.append(a, try a.dupe(u8, root));
    p.at_root = true;

    try testing.expectEqual(@as(Result, .none), p.activate(io, 0));
    try testing.expectEqualStrings(root, p.path.items); // not garbage
    try testing.expect(!p.at_root);

    // The corruption used to only manifest one level deeper, once a path
    // was built by joining the (by-then garbage) `self.path` with a child
    // name — so descending again is the real assertion.
    try testing.expectEqualStrings("child", p.rowLabel(2));
    _ = p.activate(io, 2);
    try testing.expectEqual(@as(?[]const u8, null), p.err_msg);
    try testing.expect(std.mem.endsWith(u8, p.path.items, "child"));
}

test "dirpicker: USE THIS FOLDER reports the current path without mutating state" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = ".dirpicker-test-use";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var p = Picker.initAt(a, io, root);
    defer p.deinit();

    switch (p.activate(io, 0)) {
        .use_folder => |path| try testing.expectEqualStrings(root, path),
        .none, .toggled_hidden => try testing.expect(false),
    }
    // Still on the same listing afterwards — activating USE THIS FOLDER
    // reports, it does not navigate.
    try testing.expectEqualStrings(root, p.path.items);
}

test "dirpicker: descending into a nonexistent path leaves the listing untouched and sets err_msg" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = ".dirpicker-test-missing";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var p = Picker.initAt(a, io, root);
    defer p.deinit();
    try testing.expectEqual(@as(?[]const u8, null), p.err_msg);

    p.descend(io, root ++ "/does-not-exist");
    try testing.expect(p.err_msg != null);
    try testing.expectEqualStrings(root, p.path.items); // unchanged
}
