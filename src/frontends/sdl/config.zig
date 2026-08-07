//! Persistent user configuration: `config.zon` in the pref-path root.
//!
//! ZON in, ZON out through `std.zon` — the format the repo already speaks,
//! parsed and printed by the standard library alone. Unknown fields are
//! ignored on load so an older binary opens a newer config; a corrupt file
//! costs a warning and the defaults, never the emulator — and is left on
//! disk untouched for the user to fix rather than overwritten.
//!
//! Precedence is defaults ← config ← CLI: a dev flag always wins for that
//! run and is never written back. `--frames N` runs (CI's smoke mode) skip
//! the file entirely, so golden hashes cannot depend on machine-local
//! settings.

const std = @import("std");
const input = @import("input.zig");

pub const Config = struct {
    /// For future semantic migrations; unknown *fields* are already tolerated.
    version: u32 = 1,
    video: Video = .{},
    audio: Audio = .{},
    rewind: RewindCfg = .{},
    library: LibraryCfg = .{},
    input: input.InputConfig = .{},
    /// Per-game overrides, keyed by the save layer's game_id. A null field
    /// inherits the global setting; precedence overall is
    /// defaults ← global ← per-game ← CLI flag.
    per_game: []PerGame = &.{},

    pub const Video = struct {
        /// Window scale factor, same meaning and 1..8 range as `--scale`.
        scale: u32 = 3,
        /// Shader preset name, same meaning as `--shader`; null = software blit.
        /// The struct default stays null — an unattended `--frames N` run
        /// skips the config file entirely and must never pick up a shader
        /// (or the GL dependency) CI didn't ask for. Interactive first runs
        /// get `default_shader` instead; see main.zig's config-load switch.
        shader: ?[]const u8 = null,
    };

    /// Seeded into a brand-new `config.zon` so a fresh install has a shader
    /// (and working `,`/`.` cycling) out of the box instead of silently
    /// landing on the software blit. Handheld tier: cheap enough to run on
    /// weak GPUs too. An existing config's explicit choice (including an
    /// explicit `null`) always wins over this.
    pub const default_shader: []const u8 = "crt-easymode";

    pub const Audio = struct {
        enabled: bool = true,
    };

    pub const RewindCfg = struct {
        enabled: bool = true,
        /// History memory. 64 MiB holds minutes of typical play at ~450
        /// KiB/state and 30 captures/s of mostly-zero deltas.
        budget_mib: u32 = 64,
    };

    /// `rewind.budget_mib` with hand-edit protection.
    pub fn effectiveRewindBudgetMib(self: Config) u32 {
        return std.math.clamp(self.rewind.budget_mib, 8, 1024);
    }

    pub const LibraryCfg = struct {
        /// Directories scanned (recursively) for .sfc/.smc when the app
        /// launches with no ROM argument. Editable by hand, e.g.
        /// `.rom_dirs = .{ "D:\\Games\\Snes Games" }`, or from the library
        /// screen's in-app folder picker (`addRomDir`).
        rom_dirs: []const []const u8 = &.{},
        /// The in-app folder browser's "USE THIS FOLDER"/`..`/entries list
        /// hides dot-directories by default (a fresh profile is dozens of
        /// tool dotdirs deep before the first ROM folder); this shows them.
        show_hidden_folders: bool = false,
    };

    /// Append `dir` to `library.rom_dirs`, deduped by exact string match —
    /// the folder picker's alternative to hand-editing the array. A no-op if
    /// `dir` is already present.
    pub fn addRomDir(self: *Config, gpa: std.mem.Allocator, dir: []const u8) !void {
        for (self.library.rom_dirs) |d| {
            if (std.mem.eql(u8, d, dir)) return;
        }
        const grown = try gpa.alloc([]const u8, self.library.rom_dirs.len + 1);
        @memcpy(grown[0..self.library.rom_dirs.len], self.library.rom_dirs);
        grown[self.library.rom_dirs.len] = try gpa.dupe(u8, dir);
        self.library.rom_dirs = grown;
    }

    pub const PerGame = struct {
        game_id: []const u8,
        shader: ?[]const u8 = null,
        region: ?enum { ntsc, pal } = null,
        accuracy: ?enum { fast, accurate } = null,
        /// Widescreen margin (columns per side); non-null implies the fast
        /// core, and a conflicting accuracy override is refused at boot.
        wide: ?u32 = null,
        rewind: ?bool = null,
        /// When a patch is discovered for this game (patchfind.zig): play it
        /// patched or original. Keyed by the ORIGINAL image's game_id — a
        /// patched game gets its own id (and saves) once booted, so the
        /// choice has to hang off the entity the user picked in the library.
        /// Null = never chosen; the library asks at launch.
        patch: ?enum { patched, original } = null,
    };

    pub fn perGame(self: *const Config, game_id: []const u8) ?*const PerGame {
        for (self.per_game) |*e| {
            if (std.mem.eql(u8, e.game_id, game_id)) return e;
        }
        return null;
    }

    /// The override entry for `game_id`, created on first edit.
    pub fn perGameMut(self: *Config, gpa: std.mem.Allocator, game_id: []const u8) !*PerGame {
        for (self.per_game) |*e| {
            if (std.mem.eql(u8, e.game_id, game_id)) return e;
        }
        const grown = try gpa.alloc(PerGame, self.per_game.len + 1);
        @memcpy(grown[0..self.per_game.len], self.per_game);
        grown[self.per_game.len] = .{ .game_id = try gpa.dupe(u8, game_id) };
        self.per_game = grown;
        return &grown[self.per_game.len - 1];
    }

    /// `video.scale` with the same validation `--scale` gets at parse time —
    /// a hand-edited out-of-range value warns and falls back rather than
    /// creating a window 0 or 90 screens wide.
    pub fn effectiveScale(self: Config, err: *std.Io.Writer) u32 {
        if (self.video.scale >= 1 and self.video.scale <= 8) return self.video.scale;
        err.print("warning: config video.scale {d} is out of range (1..8), using 3\n", .{self.video.scale}) catch {};
        err.flush() catch {};
        return 3;
    }
};

const max_config_bytes = 1 << 20;

pub const LoadResult = union(enum) {
    loaded: Config,
    missing,
    invalid,
};

/// Read and parse `path`. `missing` and `invalid` are distinct so the caller
/// can seed a fresh file on first run without ever clobbering a broken one.
pub fn load(io: std.Io, gpa: std.mem.Allocator, path: []const u8) LoadResult {
    const src = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_config_bytes)) catch return .missing;
    const cfg = parseText(gpa, src) catch return .invalid;
    return .{ .loaded = cfg };
}

/// Write `cfg` to `path` through a sibling temp file + rename, so a crash
/// mid-write can never leave a truncated config behind.
pub fn save(io: std.Io, gpa: std.mem.Allocator, cfg: Config, path: []const u8) !void {
    const text = try serializeText(gpa, cfg);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = text });
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, io);
}

fn parseText(gpa: std.mem.Allocator, src: []const u8) !Config {
    const z = try gpa.dupeZ(u8, src);
    return std.zon.parse.fromSliceAlloc(Config, gpa, z, null, .{ .ignore_unknown_fields = true });
}

fn serializeText(gpa: std.mem.Allocator, cfg: Config) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    try std.zon.stringify.serialize(cfg, .{}, &aw.writer);
    try aw.writer.writeByte('\n');
    return aw.written();
}

test "config: defaults roundtrip through ZON byte-identically" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const text = try serializeText(a, .{});
    const back = try parseText(a, text);
    try std.testing.expectEqualDeep(Config{}, back);
}

test "config: a fully populated config survives the roundtrip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var cfg: Config = .{
        .video = .{ .scale = 5, .shader = "crt-royale" },
        .audio = .{ .enabled = false },
    };
    cfg.input.p1_keys.b = "space";
    cfg.input.hotkeys.fast_forward = "key:tab";
    cfg.input.swap_pads = true;
    const pg = try cfg.perGameMut(a, "0123456789abcdef-star-ocean");
    pg.region = .pal;
    pg.rewind = false;
    pg.shader = "crt-royale";
    const back = try parseText(a, try serializeText(a, cfg));
    try std.testing.expectEqualDeep(cfg, back);
}

test "config: per-game lookup and find-or-create semantics" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var cfg: Config = .{};
    try std.testing.expectEqual(@as(?*const Config.PerGame, null), cfg.perGame("nope"));

    const e1 = try cfg.perGameMut(a, "aaaa-game");
    e1.accuracy = .accurate;
    // A second edit finds the same entry rather than duplicating it.
    const e2 = try cfg.perGameMut(a, "aaaa-game");
    try std.testing.expectEqual(@as(usize, 1), cfg.per_game.len);
    try std.testing.expectEqual(@as(?@TypeOf(e2.accuracy.?), .accurate), e2.accuracy);
    try std.testing.expect(cfg.perGame("aaaa-game") != null);
}

test "config: unknown fields are ignored, known siblings still land" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cfg = try parseText(a,
        \\.{
        \\    .from_the_future = .{ .rewind = true },
        \\    .video = .{ .scale = 2, .frobnicate = 9 },
        \\}
    );
    try std.testing.expectEqual(@as(u32, 2), cfg.video.scale);
    try std.testing.expectEqual(true, cfg.audio.enabled);
}

test "config: addRomDir appends and dedupes exact matches" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var cfg: Config = .{};
    try cfg.addRomDir(a, "D:\\Games\\Snes Games");
    try std.testing.expectEqual(@as(usize, 1), cfg.library.rom_dirs.len);
    try cfg.addRomDir(a, "D:\\Games\\Snes Games");
    try std.testing.expectEqual(@as(usize, 1), cfg.library.rom_dirs.len);
    try cfg.addRomDir(a, "/home/user/roms");
    try std.testing.expectEqual(@as(usize, 2), cfg.library.rom_dirs.len);
    try std.testing.expectEqualStrings("D:\\Games\\Snes Games", cfg.library.rom_dirs[0]);
    try std.testing.expectEqualStrings("/home/user/roms", cfg.library.rom_dirs[1]);
}

test "config: garbage is an error, not a crash" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectError(error.ParseZon, parseText(a, "not zon at all {"));
}

test "config: effectiveScale clamps hand-edited nonsense" {
    var sink_buf: [256]u8 = undefined;
    var sink: std.Io.Writer.Discarding = .init(&sink_buf);

    const good: Config = .{ .video = .{ .scale = 4 } };
    try std.testing.expectEqual(@as(u32, 4), good.effectiveScale(&sink.writer));

    const zero: Config = .{ .video = .{ .scale = 0 } };
    try std.testing.expectEqual(@as(u32, 3), zero.effectiveScale(&sink.writer));

    const huge: Config = .{ .video = .{ .scale = 99 } };
    try std.testing.expectEqual(@as(u32, 3), huge.effectiveScale(&sink.writer));
}
