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

pub const Config = struct {
    /// For future semantic migrations; unknown *fields* are already tolerated.
    version: u32 = 1,
    video: Video = .{},
    audio: Audio = .{},

    pub const Video = struct {
        /// Window scale factor, same meaning and 1..8 range as `--scale`.
        scale: u32 = 3,
        /// Shader preset name, same meaning as `--shader`; null = software blit.
        shader: ?[]const u8 = null,
    };

    pub const Audio = struct {
        enabled: bool = true,
    };

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

    const cfg: Config = .{
        .video = .{ .scale = 5, .shader = "crt-royale" },
        .audio = .{ .enabled = false },
    };
    const back = try parseText(a, try serializeText(a, cfg));
    try std.testing.expectEqualDeep(cfg, back);
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
