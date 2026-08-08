//! Input movies: record a playthrough as the per-frame pad masks, replay it
//! deterministically, and verify the replay reproduced the recorded run.
//!
//! The design leans on two properties the emulator already proves elsewhere:
//! the core is deterministic (the whole patch-generation ladder compares
//! per-frame hashes across runs and CI would catch a violation instantly),
//! and input is frame-quantized — everything enters through
//! `Console.setButtons(port, mask)` once per frame before `runFrame()`. So a
//! movie is exactly a list of `(port0, port1)` mask pairs, one per executed
//! frame, plus enough identity to refuse a replay that could not possibly
//! reproduce: the CRC32 of the image as played (post soft-patching), the
//! core accuracy, and the resolved region. The framebuffer and audio hashes
//! after the last recorded frame ride along so a replay can PROVE it stayed
//! in sync rather than hope.
//!
//! Movies start at power-on. What is NOT captured: battery saves (a .srm
//! present at boot is initial state and must match on replay — the headless
//! player loads none) and save-state/rewind time travel, which breaks the
//! input-stream model — the SDL recorder discards a recording rather than
//! writing a movie that cannot replay.
//!
//! File format `.ymv`, little-endian throughout:
//!
//!   off  size  field
//!     0     4  magic "YMV1"
//!     4     2  version (1)
//!     6     1  accuracy (0 fast, 1 accurate)
//!     7     1  region (0 ntsc, 1 pal)
//!     8     4  crc32 of the copier-stripped image as played
//!    12     4  frame count
//!    16     8  framebuffer hash after the last frame (0 = not recorded)
//!    24     8  audio-stream hash after the last frame (0 = not recorded)
//!    32     -  frame count x { u16 port0 mask, u16 port1 mask }

const std = @import("std");

pub const magic = "YMV1";
pub const version: u16 = 1;
pub const header_len = 32;
pub const file_ext = ".ymv";

/// Frame-count ceiling: ~9 hours at 60 fps. A header past it is corrupt,
/// not ambitious.
pub const frames_max = 2_000_000;

pub const ParseError = error{ BadMagic, BadVersion, Truncated, TooLong, OutOfMemory };

pub const Movie = struct {
    /// 0 = fast core, 1 = accurate. Timing differs between the cores, so a
    /// movie only promises to reproduce on the one it was recorded on.
    accuracy: u8,
    /// 0 = NTSC, 1 = PAL — the region the console actually resolved to.
    region: u8,
    /// CRC32 of the copier-stripped image that was played. A soft-patched
    /// game records the patched image's CRC: the movie belongs to the game
    /// as it ran, not to the file on disk.
    rom_crc: u32,
    /// Framebuffer hash after the last recorded frame; 0 = not recorded.
    end_frame_hash: u64,
    /// Audio-stream hash after the last recorded frame; 0 = not recorded.
    end_audio_hash: u64,
    /// One entry per executed frame: the two ports' button masks.
    frames: [][2]u16,

    pub fn deinit(self: *Movie, gpa: std.mem.Allocator) void {
        gpa.free(self.frames);
        self.* = undefined;
    }
};

/// Serialize to caller-owned bytes.
pub fn encode(gpa: std.mem.Allocator, m: Movie) ![]u8 {
    const out = try gpa.alloc(u8, header_len + m.frames.len * 4);
    @memcpy(out[0..4], magic);
    std.mem.writeInt(u16, out[4..6], version, .little);
    out[6] = m.accuracy;
    out[7] = m.region;
    std.mem.writeInt(u32, out[8..12], m.rom_crc, .little);
    std.mem.writeInt(u32, out[12..16], @intCast(m.frames.len), .little);
    std.mem.writeInt(u64, out[16..24], m.end_frame_hash, .little);
    std.mem.writeInt(u64, out[24..32], m.end_audio_hash, .little);
    for (m.frames, 0..) |f, i| {
        std.mem.writeInt(u16, out[header_len + i * 4 ..][0..2], f[0], .little);
        std.mem.writeInt(u16, out[header_len + i * 4 + 2 ..][0..2], f[1], .little);
    }
    return out;
}

/// Parse from bytes; the returned movie owns a fresh `frames` allocation.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) ParseError!Movie {
    if (bytes.len < header_len) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;
    if (std.mem.readInt(u16, bytes[4..6], .little) != version) return error.BadVersion;
    const count = std.mem.readInt(u32, bytes[12..16], .little);
    if (count > frames_max) return error.TooLong;
    if (bytes.len < header_len + @as(usize, count) * 4) return error.Truncated;
    const frames = try gpa.alloc([2]u16, count);
    errdefer gpa.free(frames);
    for (frames, 0..) |*f, i| {
        f[0] = std.mem.readInt(u16, bytes[header_len + i * 4 ..][0..2], .little);
        f[1] = std.mem.readInt(u16, bytes[header_len + i * 4 + 2 ..][0..2], .little);
    }
    return .{
        .accuracy = bytes[6],
        .region = bytes[7],
        .rom_crc = std.mem.readInt(u32, bytes[8..12], .little),
        .end_frame_hash = std.mem.readInt(u64, bytes[16..24], .little),
        .end_audio_hash = std.mem.readInt(u64, bytes[24..32], .little),
        .frames = frames,
    };
}

/// CRC32 of an image, the same polynomial BPS uses — movie identity matches
/// patch identity on purpose.
pub fn imageCrc(image: []const u8) u32 {
    return std.hash.crc.Crc32.hash(image);
}

// --- tests ---------------------------------------------------------------------

const testing = std.testing;

test "movie: encode/parse round-trip preserves everything" {
    const gpa = testing.allocator;
    const frames = try gpa.dupe([2]u16, &.{
        .{ 0x0000, 0x0000 },
        .{ 0x8000, 0x0000 }, // B held
        .{ 0x8000, 0x1000 },
        .{ 0x0000, 0xFFFF },
    });
    var m: Movie = .{
        .accuracy = 0,
        .region = 1,
        .rom_crc = 0xDEADBEEF,
        .end_frame_hash = 0x0123456789ABCDEF,
        .end_audio_hash = 0xFEDCBA9876543210,
        .frames = frames,
    };
    defer m.deinit(gpa);

    const bytes = try encode(gpa, m);
    defer gpa.free(bytes);
    try testing.expectEqual(header_len + 4 * 4, bytes.len);

    var back = try parse(gpa, bytes);
    defer back.deinit(gpa);
    try testing.expectEqual(m.accuracy, back.accuracy);
    try testing.expectEqual(m.region, back.region);
    try testing.expectEqual(m.rom_crc, back.rom_crc);
    try testing.expectEqual(m.end_frame_hash, back.end_frame_hash);
    try testing.expectEqual(m.end_audio_hash, back.end_audio_hash);
    try testing.expectEqualSlices([2]u16, m.frames, back.frames);
}

test "movie: refusals — magic, version, truncation, absurd length" {
    const gpa = testing.allocator;
    var buf: [header_len]u8 = @splat(0);
    try testing.expectError(error.Truncated, parse(gpa, buf[0..8]));
    try testing.expectError(error.BadMagic, parse(gpa, &buf));
    @memcpy(buf[0..4], magic);
    std.mem.writeInt(u16, buf[4..6], 99, .little);
    try testing.expectError(error.BadVersion, parse(gpa, &buf));
    std.mem.writeInt(u16, buf[4..6], version, .little);
    std.mem.writeInt(u32, buf[12..16], 3, .little); // 3 frames, no payload
    try testing.expectError(error.Truncated, parse(gpa, &buf));
    std.mem.writeInt(u32, buf[12..16], frames_max + 1, .little);
    try testing.expectError(error.TooLong, parse(gpa, &buf));
}
