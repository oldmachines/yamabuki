//! Battery-save (.srm) persistence, save-state slot paths, and the game
//! identity both are filed under.
//!
//! A game is identified by the first 16 hex digits of its (copier-stripped)
//! image's sha256 plus its sanitized header title — hash first so two dumps
//! never collide, title second so a human can read the directory.
//!
//! SRAM writes to disk are debounced: games write battery RAM in bursts
//! (an in-progress save-file update is a torn state worth not persisting),
//! so a change only hits disk once the *same* dirty hash has been observed
//! twice in a row at the check cadence — plus an unconditional flush at
//! the moments that matter (menu open, state load, quit).

const std = @import("std");
const core = @import("snes_core");

/// How often (in emulated frames) the SRAM dirty check runs. Two ticks
/// (~2 s) of identical dirty content trigger the write.
pub const check_interval: u32 = 60;

/// `<sha16>-<sanitized-title>`, e.g. `6ed6c4e3889ba17e-star-ocean`.
pub fn gameId(gpa: std.mem.Allocator, sha_hex: []const u8, title: []const u8) ![]const u8 {
    var buf: [24]u8 = undefined;
    var n: usize = 0;
    var pending_dash = false;
    for (title) |c| {
        if (n == buf.len) break;
        if (std.ascii.isAlphanumeric(c)) {
            if (pending_dash and n != 0) {
                buf[n] = '-';
                n += 1;
                if (n == buf.len) break;
            }
            pending_dash = false;
            buf[n] = std.ascii.toLower(c);
            n += 1;
        } else {
            pending_dash = true;
        }
    }
    const prefix = sha_hex[0..@min(sha_hex.len, 16)];
    if (n == 0) return std.fmt.allocPrint(gpa, "{s}", .{prefix});
    return std.fmt.allocPrint(gpa, "{s}-{s}", .{ prefix, buf[0..n] });
}

/// The write-now decision, kept pure for the tests. `observe` is called
/// with the current content hash at every check tick.
pub const Debounce = struct {
    last_persisted: u64,
    pending: ?u64 = null,

    /// True when the caller should persist this content now: it differs
    /// from what is on disk and has held still for one full interval.
    pub fn observe(self: *Debounce, hash: u64) bool {
        if (hash == self.last_persisted) {
            self.pending = null;
            return false;
        }
        if (self.pending == hash) {
            self.pending = null;
            self.last_persisted = hash;
            return true;
        }
        self.pending = hash;
        return false;
    }

    /// True when the content differs from disk at all — the unconditional
    /// flush used at menu-open/state-load/quit.
    pub fn dirty(self: *const Debounce, hash: u64) bool {
        return hash != self.last_persisted;
    }

    pub fn persisted(self: *Debounce, hash: u64) void {
        self.last_persisted = hash;
        self.pending = null;
    }
};

/// Load a battery save from an arbitrary file into the live SRAM without
/// wiring persistence to it — the `--record --srm` start: the take begins
/// from this save and its anchor carries it, so the file is never written
/// back. Size must match the cart's SRAM exactly.
pub fn loadSramFile(io: std.Io, con: *core.AnyConsole, path: []const u8, err: *std.Io.Writer) bool {
    const sram = sramSlice(con);
    const data = std.Io.Dir.cwd().readFile(io, path, sram) catch |e| {
        err.print("error: cannot read {s}: {s}\n", .{ path, @errorName(e) }) catch {};
        err.flush() catch {};
        return false;
    };
    if (data.len != sram.len) {
        err.print("error: {s} is {d} bytes, cart wants {d}\n", .{ path, data.len, sram.len }) catch {};
        err.flush() catch {};
        @memset(sram, 0);
        return false;
    }
    return true;
}

/// The console's live battery SRAM (the cart's mapped span).
pub fn liveSram(con: *core.AnyConsole) []u8 {
    return sramSlice(con);
}

fn sramSlice(con: *core.AnyConsole) []u8 {
    const cart = con.cartridge();
    return cart.sram[0 .. cart.sram_mask + 1];
}

/// The .srm file for one game, wired to the console's live SRAM.
pub const Sram = struct {
    dir: []const u8,
    path: []const u8,
    debounce: Debounce = .{ .last_persisted = 0 },
    frames: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, saves_dir: []const u8, game_id: []const u8) !Sram {
        return .{
            .dir = saves_dir,
            .path = try std.fmt.allocPrint(gpa, "{s}/{s}.srm", .{ saves_dir, game_id }),
        };
    }

    /// Restore the battery save before the first frame. A size mismatch
    /// (different revision, corrupted file) warns and boots blank rather
    /// than corrupting: exactly what a real cart with a dead battery does.
    pub fn load(self: *Sram, io: std.Io, con: *core.AnyConsole, err: *std.Io.Writer) void {
        const sram = sramSlice(con);
        const data = std.Io.Dir.cwd().readFile(io, self.path, sram) catch |e| {
            if (e != error.FileNotFound) {
                err.print("warning: cannot read {s}: {s}\n", .{ self.path, @errorName(e) }) catch {};
                err.flush() catch {};
            }
            self.debounce.persisted(std.hash.Fnv1a_64.hash(sram));
            return;
        };
        if (data.len != sram.len) {
            err.print("warning: {s} is {d} bytes, cart wants {d} — ignoring it\n", .{ self.path, data.len, sram.len }) catch {};
            err.flush() catch {};
            @memset(sram, 0);
        } else {
            err.print("battery save loaded: {s}\n", .{self.path}) catch {};
            err.flush() catch {};
        }
        self.debounce.persisted(std.hash.Fnv1a_64.hash(sram));
    }

    /// Once per emulated frame; hashes and possibly writes every
    /// `check_interval` frames. Hashing ≤128 KiB (usually 2-32 KiB) twice
    /// a second is microseconds — no core dirty-bit needed.
    pub fn tick(self: *Sram, io: std.Io, con: *core.AnyConsole, err: *std.Io.Writer) void {
        self.frames += 1;
        if (self.frames < check_interval) return;
        self.frames = 0;
        const sram = sramSlice(con);
        if (self.debounce.observe(std.hash.Fnv1a_64.hash(sram)))
            self.write(io, sram, err);
    }

    /// Unconditional write-if-dirty, for menu open / state load / quit.
    pub fn flush(self: *Sram, io: std.Io, con: *core.AnyConsole, err: *std.Io.Writer) void {
        const sram = sramSlice(con);
        const h = std.hash.Fnv1a_64.hash(sram);
        if (!self.debounce.dirty(h)) return;
        self.write(io, sram, err);
        self.debounce.persisted(h);
    }

    fn write(self: *Sram, io: std.Io, sram: []const u8, err: *std.Io.Writer) void {
        std.Io.Dir.cwd().createDirPath(io, self.dir) catch {};
        // Temp + rename: a crash mid-write must never tear the only copy
        // of someone's save file.
        var tmp_buf: [512]u8 = undefined;
        const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{self.path}) catch return;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = sram }) catch |e| {
            err.print("warning: cannot write {s}: {s}\n", .{ self.path, @errorName(e) }) catch {};
            err.flush() catch {};
            return;
        };
        std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), self.path, io) catch |e| {
            err.print("warning: cannot write {s}: {s}\n", .{ self.path, @errorName(e) }) catch {};
            err.flush() catch {};
        };
    }
};

/// `states/<gameid>/<slot>.state`.
pub fn slotPath(gpa: std.mem.Allocator, states_dir: []const u8, game_id: []const u8, slot: u32) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}/{s}/{d}.state", .{ states_dir, game_id, slot });
}

/// One-time migration: F5 used to write `<rom>.state` next to the ROM. If
/// that file exists and slot 1 is empty, copy it in (the original stays —
/// dev workflows may still point at it). Returns true when migrated.
pub fn migrateLegacyState(io: std.Io, legacy_path: []const u8, slot1_path: []const u8, scratch: []u8) bool {
    std.Io.Dir.cwd().access(io, slot1_path, .{}) catch {
        const data = std.Io.Dir.cwd().readFile(io, legacy_path, scratch) catch return false;
        if (std.fs.path.dirname(slot1_path)) |d|
            std.Io.Dir.cwd().createDirPath(io, d) catch return false;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = slot1_path, .data = data }) catch return false;
        return true;
    };
    return false;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "gameId: hash prefix plus sanitized lowercased title" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings(
        "0123456789abcdef-star-ocean",
        try gameId(a, "0123456789abcdef" ++ "deadbeef", "STAR OCEAN           "),
    );
    // Punctuation collapses to single dashes, never leading or trailing.
    try testing.expectEqualStrings(
        "0123456789abcdef-mega-man-x2",
        try gameId(a, "0123456789abcdefdeadbeef", "  MEGA MAN X2!! "),
    );
    // A title with nothing usable falls back to the hash alone.
    try testing.expectEqualStrings(
        "0123456789abcdef",
        try gameId(a, "0123456789abcdefdeadbeef", "     "),
    );
}

test "debounce: writes once per settled change, never mid-burst" {
    var d: Debounce = .{ .last_persisted = 1 };

    // Steady state: nothing to do.
    try testing.expect(!d.observe(1));
    // A burst that keeps changing: never written while moving.
    try testing.expect(!d.observe(2));
    try testing.expect(!d.observe(3));
    // It settles: exactly one write.
    try testing.expect(d.observe(3));
    try testing.expect(!d.observe(3));
    // Reverting to the persisted value cancels a pending write.
    try testing.expect(!d.observe(4));
    try testing.expect(!d.observe(3));
    try testing.expect(!d.observe(3));
}

test "debounce: flush sees dirt immediately" {
    var d: Debounce = .{ .last_persisted = 1 };
    try testing.expect(!d.dirty(1));
    try testing.expect(d.dirty(2));
    d.persisted(2);
    try testing.expect(!d.dirty(2));
}
