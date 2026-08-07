//! Patch discovery: does the game being launched have a patch available, and
//! which file is it? Three sources, in precedence order:
//!
//! 1. **Same-basename softpatch** — `Game.bps`/`Game.ips` next to `Game.sfc`,
//!    the community convention and where `yamabuki-headless
//!    --gen-fastrom-patch` writes by default.
//! 2. **The patch folder** — `<pref path>/patches/*.bps`, matched to the ROM
//!    by the source CRC32 every BPS names in its footer. Drop a generated
//!    patch in one folder and it lights up for the matching game, whatever
//!    either file is called.
//! 3. **The curated registry** — patches/registry.zon entries (compiled in),
//!    looked up by content sha256 and pinned to an exact patch-file sha256,
//!    with the file itself expected in the same patch folder.
//!
//! A BPS that names a *different* source CRC is not offered — a patch that
//! cannot apply is noise, not a choice. IPS files carry no checksums, so an
//! IPS match is offered as unverified (the boot path already warns).
//!
//! Discovery never mutates anything and never downloads anything.

const std = @import("std");
const core = @import("snes_core");

pub const Kind = enum { bps, ips };
pub const Source = enum { basename, folder, registry };

pub const Found = struct {
    /// The patch file path, allocated with the caller's gpa.
    path: []const u8,
    kind: Kind,
    source: Source,
};

/// The source CRC32 a BPS patch demands, or null when `bytes` is not
/// plausibly BPS. This is what lets a folder of patches be matched to ROMs
/// without any naming convention.
pub fn bpsSourceCrc(bytes: []const u8) ?u32 {
    if (bytes.len < 4 + 12 or !std.mem.startsWith(u8, bytes, "BPS1")) return null;
    return std.mem.readInt(u32, bytes[bytes.len - 12 ..][0..4], .little);
}

/// `Game.sfc` -> `Game.bps` / `Game.ips` (same directory).
fn basenameCandidate(gpa: std.mem.Allocator, rom_path: []const u8, ext: []const u8) ![]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, rom_path, '.') orelse rom_path.len;
    const slash = std.mem.lastIndexOfScalar(u8, rom_path, '/') orelse 0;
    const stem = if (dot > slash) rom_path[0..dot] else rom_path;
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ stem, ext });
}

/// A one-shot index of the patch folder: every `.bps` file's source CRC32,
/// read from its footer (the whole file is read — patches are small). Built
/// once per library screen / boot, then matched per game for free.
pub const FolderIndex = struct {
    entries: std.ArrayList(IndexEntry) = .empty,

    pub const IndexEntry = struct { crc: u32, path: []const u8 };

    pub fn build(io: std.Io, gpa: std.mem.Allocator, dir_path: ?[]const u8) FolderIndex {
        var idx: FolderIndex = .{};
        const root = dir_path orelse return idx;
        var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return idx;
        defer dir.close(io);
        var walker = dir.walk(gpa) catch return idx;
        defer walker.deinit();
        while (walker.next(io) catch null) |item| {
            if (item.kind != .file) continue;
            if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(item.basename), ".bps")) continue;
            const full = std.fs.path.join(gpa, &.{ root, item.path }) catch continue;
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(16 << 20)) catch continue;
            defer gpa.free(bytes);
            const crc = bpsSourceCrc(bytes) orelse continue;
            idx.entries.append(gpa, .{ .crc = crc, .path = full }) catch continue;
        }
        return idx;
    }

    pub fn match(self: *const FolderIndex, crc: u32) ?[]const u8 {
        for (self.entries.items) |e| {
            if (e.crc == crc) return e.path;
        }
        return null;
    }
};

/// The cheap per-entry check behind the library's PATCH tag: a same-basename
/// softpatch (BPS verified against `rom_crc`; IPS taken on faith) or a folder
/// match. `rom_crc` comes from the library cache, so no ROM is re-read.
pub fn quickAvailable(
    io: std.Io,
    gpa: std.mem.Allocator,
    rom_path: []const u8,
    rom_crc: u32,
    folder: *const FolderIndex,
) bool {
    if (basenameFind(io, gpa, rom_path, rom_crc)) |f| {
        gpa.free(f.path);
        return true;
    }
    return folder.match(rom_crc) != null;
}

fn basenameFind(io: std.Io, gpa: std.mem.Allocator, rom_path: []const u8, rom_crc: u32) ?Found {
    if (basenameCandidate(gpa, rom_path, ".bps")) |p| {
        if (std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(16 << 20))) |bytes| {
            defer gpa.free(bytes);
            if (bpsSourceCrc(bytes)) |crc| {
                if (crc == rom_crc) return .{ .path = p, .kind = .bps, .source = .basename };
            }
            gpa.free(p);
        } else |_| gpa.free(p);
    } else |_| {}
    if (basenameCandidate(gpa, rom_path, ".ips")) |p| {
        if (std.Io.Dir.cwd().statFile(io, p, .{})) |_| {
            return .{ .path = p, .kind = .ips, .source = .basename };
        } else |_| gpa.free(p);
    } else |_| {}
    return null;
}

/// Full discovery at boot: basename > folder > registry. `image` is the
/// copier-stripped ROM (its CRC32 and sha256 are computed here — the boot
/// path has the bytes in hand anyway).
pub fn findForRom(
    io: std.Io,
    gpa: std.mem.Allocator,
    rom_path: []const u8,
    image: []const u8,
    patches_dir: ?[]const u8,
) ?Found {
    const rom_crc = core.patch.crc32(image);
    if (basenameFind(io, gpa, rom_path, rom_crc)) |f| return f;

    var folder = FolderIndex.build(io, gpa, patches_dir);
    if (folder.match(rom_crc)) |p| return .{ .path = p, .kind = .bps, .source = .folder };

    // The registry pins the patch file's own sha256: a file that does not
    // match is not offered, same refusal the headless --auto-patch makes.
    const sha = core.registry.sha256Hex(image);
    if (core.registry.find(&sha)) |entry| {
        const root = patches_dir orelse return null;
        const p = std.fs.path.join(gpa, &.{ root, entry.patch_name }) catch return null;
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(16 << 20)) catch {
            gpa.free(p);
            return null;
        };
        defer gpa.free(bytes);
        const file_sha = core.registry.sha256Hex(bytes);
        if (std.mem.eql(u8, &file_sha, entry.patch_sha256)) {
            return .{ .path = p, .kind = .bps, .source = .registry };
        }
        gpa.free(p);
    }
    return null;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "bpsSourceCrc reads the footer of a real encoded patch" {
    const gpa = testing.allocator;
    const source = "A SOURCE ROM IMAGE";
    const target = "A TARGET ROM IMAGE";
    const bps = try core.patch.writeBps(gpa, source, target);
    defer gpa.free(bps);
    try testing.expectEqual(core.patch.crc32(source), bpsSourceCrc(bps).?);

    try testing.expectEqual(@as(?u32, null), bpsSourceCrc("PATCHnotbps"));
    try testing.expectEqual(@as(?u32, null), bpsSourceCrc("BPS1"));
}

test "folder index matches by source CRC; basename beats folder" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const root = ".patchfind-test-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/patches");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const rom_a = "ROM IMAGE ALPHA!";
    const rom_b = "ROM IMAGE BRAVO!";
    const patched_a = "ROM PATCH ALPHA!";
    const bps_a = try core.patch.writeBps(a, rom_a, patched_a);
    const bps_b = try core.patch.writeBps(a, rom_b, rom_b);

    const pdir = root ++ "/patches";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = pdir ++ "/whatever-name.bps", .data = bps_a });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = pdir ++ "/other.bps", .data = bps_b });

    var idx = FolderIndex.build(io, a, pdir);
    try testing.expectEqual(@as(usize, 2), idx.entries.items.len);
    try testing.expect(idx.match(core.patch.crc32(rom_a)) != null);
    try testing.expect(idx.match(0xDEAD_BEEF) == null);

    // quickAvailable: folder hit for rom_a's CRC even with no basename file.
    const rom_path = root ++ "/AlphaGame.sfc";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = rom_path, .data = rom_a });
    try testing.expect(quickAvailable(io, a, rom_path, core.patch.crc32(rom_a), &idx));
    try testing.expect(!quickAvailable(io, a, rom_path, 0x1234_5678, &idx));

    // findForRom prefers the basename softpatch once one appears.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/AlphaGame.bps", .data = bps_a });
    const f = findForRom(io, a, rom_path, rom_a, pdir).?;
    try testing.expectEqual(Source.basename, f.source);
    try testing.expectEqual(Kind.bps, f.kind);

    // A basename BPS for the WRONG ROM is not offered; folder still matches.
    const f2 = findForRom(io, a, rom_path, rom_b, pdir).?;
    try testing.expectEqual(Source.folder, f2.source);
}
