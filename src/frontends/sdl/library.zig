//! The ROM library: recursive directory scan, header metadata, and a ZON
//! cache so the second launch costs stats instead of reads.
//!
//! Scanning is *incremental on the main loop* rather than threaded: the
//! browse screen calls `Scanner.step` with a time budget every frame, so
//! the list fills live while staying responsive — same effect as a worker
//! thread with none of its failure modes. A cache hit (same path, size,
//! mtime) skips the read entirely; a 6000-file rescan is 6000 stats.
//!
//! `last_played` is a monotonic generation counter, not wall time — it
//! exists to sort "most recent first", which ordering gives for free
//! without depending on a clock.

const std = @import("std");
const core = @import("snes_core");
const saves = @import("saves.zig");

pub const Entry = struct {
    path: []const u8,
    size: u64 = 0,
    mtime_s: i64 = 0,
    game_id: []const u8 = "",
    title: []const u8 = "",
    region: []const u8 = "",
    chip: []const u8 = "",
    last_played: u64 = 0,
    playtime_s: u64 = 0,
    /// CRC32 of the copier-stripped image — what BPS patch footers name, so
    /// patch availability can be checked without re-reading the ROM. 0 in an
    /// entry from an older cache means "unknown" and forces a re-identify.
    crc32: u32 = 0,
    /// Raw $FFD5 map-mode byte (bit 4 = FastROM) — what tells the library a
    /// game is SlowROM and therefore worth offering FastROM generation for.
    /// 0 is not a real map mode, so it doubles as the "older cache,
    /// re-identify" marker the same way crc32 does.
    map_mode: u8 = 0,
    /// Session-only, refreshed by the library screen (never trusted from the
    /// cache): a patch for this game is available right now.
    has_patch: bool = false,
};

const CacheFile = struct {
    entries: []Entry = &.{},
};

pub const Library = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn loadCache(io: std.Io, gpa: std.mem.Allocator, path: []const u8) Library {
        var lib: Library = .{ .gpa = gpa };
        const src = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20)) catch return lib;
        const z = gpa.dupeZ(u8, src) catch return lib;
        const cache = std.zon.parse.fromSliceAlloc(CacheFile, gpa, z, null, .{ .ignore_unknown_fields = true }) catch return lib;
        lib.entries.appendSlice(gpa, cache.entries) catch {};
        return lib;
    }

    pub fn saveCache(self: *const Library, io: std.Io, gpa: std.mem.Allocator, path: []const u8) !void {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try std.zon.stringify.serialize(CacheFile{ .entries = self.entries.items }, .{}, &aw.writer);
        const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
        defer gpa.free(tmp);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = aw.written() });
        try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, io);
    }

    pub fn find(self: *Library, path: []const u8) ?*Entry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.path, path)) return e;
        }
        return null;
    }

    /// Record a play session: bump the recency generation, add play time.
    pub fn touch(self: *Library, path: []const u8, played_s: u64) void {
        var top: u64 = 0;
        for (self.entries.items) |e| top = @max(top, e.last_played);
        if (self.find(path)) |e| {
            e.last_played = top + 1;
            e.playtime_s += played_s;
        }
    }

    /// Most recently played first, then title, so a fresh library is
    /// alphabetical and a lived-in one leads with what you actually play.
    pub fn sort(self: *Library) void {
        std.mem.sort(Entry, self.entries.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                if (a.last_played != b.last_played) return a.last_played > b.last_played;
                return std.mem.lessThan(u8, a.title, b.title);
            }
        }.lessThan);
    }
};

fn hasRomExtension(name: []const u8) bool {
    for ([_][]const u8{ ".sfc", ".smc" }) |ext| {
        if (name.len > ext.len and std.ascii.eqlIgnoreCase(name[name.len - ext.len ..], ext)) return true;
    }
    return false;
}

/// The chipset byte's display name — mirrors the core's identifyChip
/// buckets, kept local because this is presentation, not emulation.
pub fn chipName(chipset: u8) []const u8 {
    return switch (chipset) {
        0x00, 0x01, 0x02 => "",
        0x03, 0x04, 0x05 => "DSP",
        0x13...0x1A => "SFX",
        0x33...0x35 => "SA-1",
        0x43, 0x45 => "S-DD1",
        0xF3 => "CX4",
        else => "CHIP?",
    };
}

/// $FFD9 region byte: 0 (Japan), 1 (NA), and 13+ are 60 Hz; 2..12 PAL.
pub fn regionName(region: u8) []const u8 {
    return if (region >= 2 and region <= 12) "PAL" else "NTSC";
}

/// Header title, display-ready: trailing padding trimmed, unprintable
/// bytes swapped for spaces; an unusable title falls back to the filename.
pub fn displayTitle(gpa: std.mem.Allocator, raw: []const u8, fallback_path: []const u8) ![]const u8 {
    var buf: [21]u8 = undefined;
    var n: usize = 0;
    for (raw[0..@min(raw.len, 21)]) |c| {
        buf[n] = if (c >= 0x20 and c < 0x7F) c else ' ';
        n += 1;
    }
    const trimmed = std.mem.trim(u8, buf[0..n], " ");
    if (trimmed.len != 0) return gpa.dupe(u8, trimmed);
    const base = std.fs.path.basename(fallback_path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
    return gpa.dupe(u8, base[0..dot]);
}

const Candidate = struct { path: []const u8, size: u64, mtime_s: i64 };

/// Incremental scan over the configured directories. `begin` walks the
/// trees (cheap — directory entries only); each `step` resolves candidates
/// against the cache until its time budget runs out.
pub const Scanner = struct {
    gpa: std.mem.Allocator,
    candidates: std.ArrayList(Candidate) = .empty,
    index: usize = 0,
    /// Entries carried over or created this scan, replacing lib.entries
    /// when the scan completes (which drops entries whose files vanished).
    fresh: std.ArrayList(Entry) = .empty,
    done: bool = false,

    pub fn begin(gpa: std.mem.Allocator, io: std.Io, dirs: []const []const u8, err: *std.Io.Writer) Scanner {
        var s: Scanner = .{ .gpa = gpa };
        for (dirs) |dir_path| {
            var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
                err.print("library: cannot open {s}\n", .{dir_path}) catch {};
                err.flush() catch {};
                continue;
            };
            defer dir.close(io);
            var walker = dir.walk(gpa) catch continue;
            defer walker.deinit();
            while (walker.next(io) catch null) |item| {
                if (item.kind != .file or !hasRomExtension(item.basename)) continue;
                const full = std.fs.path.join(gpa, &.{ dir_path, item.path }) catch continue;
                const stat = std.Io.Dir.cwd().statFile(io, full, .{}) catch continue;
                s.candidates.append(gpa, .{
                    .path = full,
                    .size = stat.size,
                    .mtime_s = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s)),
                }) catch continue;
            }
        }
        if (s.candidates.items.len == 0) s.done = true;
        return s;
    }

    pub fn remaining(self: *const Scanner) usize {
        return self.candidates.items.len - self.index;
    }

    /// Resolve one candidate against the cache (a hit is a stat-cheap
    /// carry-over; a miss reads, hashes, and parses). The caller loops this
    /// under its own time budget. Returns true the moment the whole scan
    /// completes — `lib` has been replaced (dropping vanished files),
    /// sorted, and is worth persisting.
    pub fn stepOne(self: *Scanner, io: std.Io, lib: *Library) bool {
        if (self.done) return false;
        if (self.index < self.candidates.items.len) {
            const c = self.candidates.items[self.index];
            self.index += 1;
            if (lib.find(c.path)) |hit| {
                // A 0 crc32 or map_mode is a cache entry from before those
                // fields existed: re-identify it once so patch matching and
                // the generation offer work, instead of carrying the gap
                // forever.
                if (hit.size == c.size and hit.mtime_s == c.mtime_s and
                    hit.crc32 != 0 and hit.map_mode != 0)
                {
                    self.fresh.append(self.gpa, hit.*) catch {};
                    return false;
                }
            }
            if (self.identify(io, c)) |entry| self.fresh.append(self.gpa, entry) catch {};
            if (self.index < self.candidates.items.len) return false;
        }
        lib.entries.clearRetainingCapacity();
        lib.entries.appendSlice(lib.gpa, self.fresh.items) catch {};
        lib.sort();
        self.done = true;
        return true;
    }

    fn identify(self: *Scanner, io: std.Io, c: Candidate) ?Entry {
        const gpa = self.gpa;
        const raw = std.Io.Dir.cwd().readFileAlloc(io, c.path, gpa, .limited(16 << 20)) catch return null;
        defer gpa.free(raw);
        const image = core.header.stripCopierHeader(raw);
        const header = core.header.detect(image) catch return null; // not a SNES ROM
        const sha = core.registry.sha256Hex(image);
        return .{
            .path = c.path,
            .size = c.size,
            .mtime_s = c.mtime_s,
            .game_id = saves.gameId(gpa, &sha, &header.title) catch return null,
            .title = displayTitle(gpa, &header.title, c.path) catch return null,
            .region = regionName(header.region),
            .chip = chipName(header.chipset),
            .crc32 = core.patch.crc32(image),
            .map_mode = header.map_mode,
        };
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "library: extension filter and display metadata helpers" {
    try testing.expect(hasRomExtension("Game.sfc"));
    try testing.expect(hasRomExtension("GAME.SMC"));
    try testing.expect(!hasRomExtension("game.zip"));
    try testing.expect(!hasRomExtension(".sfc")); // extension alone is no name

    try testing.expectEqualStrings("SFX", chipName(0x15));
    try testing.expectEqualStrings("S-DD1", chipName(0x43));
    try testing.expectEqualStrings("", chipName(0x02));
    try testing.expectEqualStrings("PAL", regionName(2));
    try testing.expectEqualStrings("NTSC", regionName(0));
    try testing.expectEqualStrings("NTSC", regionName(1));
    try testing.expectEqualStrings("NTSC", regionName(13));
}

test "library: displayTitle trims padding and falls back to the filename" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings(
        "STAR OCEAN",
        try displayTitle(a, "STAR OCEAN           ", "x.sfc"),
    );
    try testing.expectEqualStrings(
        "Chrono Trigger (U)",
        try displayTitle(a, "\x00\x01\x02                  ", "roms/Chrono Trigger (U).smc"),
    );
}

test "library: touch bumps recency and sort leads with it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lib: Library = .{ .gpa = a };
    try lib.entries.append(a, .{ .path = "a", .title = "AAA" });
    try lib.entries.append(a, .{ .path = "b", .title = "BBB" });
    try lib.entries.append(a, .{ .path = "c", .title = "CCC" });

    lib.sort();
    try testing.expectEqualStrings("AAA", lib.entries.items[0].title);

    lib.touch("c", 120);
    lib.touch("b", 60);
    lib.sort();
    try testing.expectEqualStrings("BBB", lib.entries.items[0].title); // newest generation
    try testing.expectEqualStrings("CCC", lib.entries.items[1].title);
    try testing.expectEqualStrings("AAA", lib.entries.items[2].title);
    try testing.expectEqual(@as(u64, 120), lib.entries.items[1].playtime_s);
}

test "library: scanner finds synthesized ROMs, caches, and drops vanished files" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A tree with one valid LoROM, one garbage .sfc, one non-ROM file.
    const root = ".library-test-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/sub");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var rom: [64 * 1024]u8 = @splat(0);
    const h = rom[0x7FC0..][0..64];
    @memcpy(h[0..21], "SCANNER TEST         ");
    h[0x15] = 0x20; // LoROM map mode
    h[0x16] = 0x00;
    h[0x17] = 6;
    h[0x19] = 1; // NA -> NTSC
    std.mem.writeInt(u16, h[0x1C..0x1E], 0x0F0F, .little);
    std.mem.writeInt(u16, h[0x1E..0x20], 0xF0F0, .little);
    std.mem.writeInt(u16, h[0x3C..0x3E], 0x8000, .little);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/sub/good.sfc", .data = &rom });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/garbage.sfc", .data = "way too short" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/readme.txt", .data = "not a rom" });

    var buf: [256]u8 = undefined;
    var sink: std.Io.Writer.Discarding = .init(&buf);
    var lib: Library = .{ .gpa = a };
    var sc = Scanner.begin(a, io, &.{root}, &sink.writer);
    // Both .sfc files are candidates; the .txt never is.
    try testing.expectEqual(@as(usize, 2), sc.candidates.items.len);
    while (!sc.done) _ = sc.stepOne(io, &lib);

    // Only the valid ROM survived identification.
    try testing.expectEqual(@as(usize, 1), lib.entries.items.len);
    const e = lib.entries.items[0];
    try testing.expectEqualStrings("SCANNER TEST", e.title);
    try testing.expectEqualStrings("NTSC", e.region);
    try testing.expectEqualStrings("", e.chip);
    try testing.expect(std.mem.endsWith(u8, e.path, "good.sfc"));
    try testing.expect(e.game_id.len > 16);

    // Second scan: pure cache hits keep the entry (same identity).
    var sc2 = Scanner.begin(a, io, &.{root}, &sink.writer);
    while (!sc2.done) _ = sc2.stepOne(io, &lib);
    try testing.expectEqual(@as(usize, 1), lib.entries.items.len);
    try testing.expectEqualStrings(e.game_id, lib.entries.items[0].game_id);

    // Delete the ROM; a rescan drops it.
    try std.Io.Dir.cwd().deleteFile(io, root ++ "/sub/good.sfc");
    var sc3 = Scanner.begin(a, io, &.{root}, &sink.writer);
    while (!sc3.done) _ = sc3.stepOne(io, &lib);
    try testing.expectEqual(@as(usize, 0), lib.entries.items.len);
}

test "library: cache roundtrips through ZON" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lib: Library = .{ .gpa = a };
    try lib.entries.append(a, .{
        .path = "roms/x.sfc",
        .size = 123,
        .mtime_s = 456,
        .game_id = "deadbeefdeadbeef-x",
        .title = "X",
        .region = "PAL",
        .chip = "SA-1",
        .last_played = 3,
        .playtime_s = 99,
    });
    const path = ".library-cache-test.zon";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try lib.saveCache(io, a, path);

    const back = Library.loadCache(io, a, path);
    try testing.expectEqual(@as(usize, 1), back.entries.items.len);
    try testing.expectEqualDeep(lib.entries.items[0], back.entries.items[0]);
}
