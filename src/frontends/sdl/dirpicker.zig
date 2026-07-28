//! In-app folder picker: browse the filesystem with the same fixed nav as
//! the rest of the overlay UI (confirm activates a row, there is no partial
//! text entry), so adding a ROM directory no longer needs a hand-edit of
//! config.zon. Every row is one of three kinds — USE THIS FOLDER, `..`, or a
//! subdirectory — which keeps the picker an extension of the confirm-on-a-
//! row idiom `menu.zig` and the library list already use, instead of a new
//! text-input widget.
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

    /// The real entry point: Windows starts at the drive list (there is no
    /// path that reaches every drive by going "up"); POSIX starts at "/".
    pub fn init(gpa: std.mem.Allocator, io: std.Io) Picker {
        var p: Picker = .{ .gpa = gpa };
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
        var p: Picker = .{ .gpa = gpa };
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

    pub fn rowCount(self: *const Picker) usize {
        if (self.at_root) return self.dirs.items.len;
        return 1 + @as(usize, if (self.canGoUp()) 1 else 0) + self.dirs.items.len;
    }

    fn rowKind(self: *const Picker, i: usize) RowKind {
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
            .entry => |name| name,
        };
    }

    /// Activate row `i`: descend into a directory, go up, or report the
    /// current path to be added as a ROM directory.
    pub fn activate(self: *Picker, io: std.Io, i: usize) Result {
        if (i >= self.rowCount()) return .none;
        switch (self.rowKind(i)) {
            .use_folder => return .{ .use_folder = self.path.items },
            .up => self.up(io),
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

    fn up(self: *Picker, io: std.Io) void {
        if (self.at_root) return;
        if (std.fs.path.dirname(self.path.items)) |parent| {
            // `parent` is a slice into `self.path`'s own storage — descend()
            // clears and rewrites that buffer, so it must work from a copy,
            // not a view into the thing it's about to overwrite.
            const dup = self.gpa.dupe(u8, parent) catch return;
            defer self.gpa.free(dup);
            self.descend(io, dup);
        } else if (builtin.os.tag == .windows) {
            self.listDrives(io);
        }
    }

    /// List `path`'s subdirectories and make it current. Leaves the picker
    /// where it was on failure, with `err_msg` set.
    fn descend(self: *Picker, io: std.Io, path: []const u8) void {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch {
            self.err_msg = "CANNOT OPEN THAT FOLDER";
            return;
        };
        defer dir.close(io);

        var fresh: std.ArrayList([]u8) = .empty;
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const name = self.gpa.dupe(u8, entry.name) catch continue;
            fresh.append(self.gpa, name) catch self.gpa.free(name);
        }
        std.mem.sort([]u8, fresh.items, {}, lessThanIgnoreCase);

        for (self.dirs.items) |d| self.gpa.free(d);
        self.dirs.deinit(self.gpa);
        self.dirs = fresh;

        self.path.clearRetainingCapacity();
        self.path.appendSlice(self.gpa, path) catch {};
        self.at_root = false;
        self.err_msg = null;
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

    // USE THIS FOLDER, .., sub -> 3 rows.
    try testing.expectEqual(@as(usize, 3), p.rowCount());
    try testing.expectEqualStrings("USE THIS FOLDER", p.rowLabel(0));
    try testing.expectEqualStrings("..", p.rowLabel(1));
    try testing.expectEqualStrings("sub", p.rowLabel(2));

    // Descending into "sub" relists (now empty: USE THIS FOLDER + .. only).
    try testing.expectEqual(@as(Result, .none), p.activate(io, 2));
    try testing.expectEqual(@as(usize, 2), p.rowCount());
    try testing.expect(std.mem.endsWith(u8, p.path.items, "sub"));

    // ".." returns to the parent, which lists "sub" again.
    _ = p.activate(io, 1);
    try testing.expectEqual(@as(usize, 3), p.rowCount());
    try testing.expect(std.mem.endsWith(u8, p.path.items, root));
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
        .none => try testing.expect(false),
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
