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
//! A movie starts either at power-on or from an ANCHOR: a save state carried
//! inside the file itself. The anchor exists because demanding power-on makes
//! late-game recording impractical — reaching stage 4 to record stage 4 is not
//! a workflow. An anchored movie replays by loading its own state and feeding
//! its inputs from there, which is just as deterministic as booting: the state
//! IS the machine the inputs applied to. Carrying it inside the movie (rather
//! than referencing a slot file) is what keeps that promise — a referenced
//! state can be overwritten by the next F2 and silently invalidate every movie
//! anchored to it.
//!
//! Anchor validity rides on checks that already exist: the movie's `rom_crc`
//! proves the same image, and the state's own header carries version, layout
//! fingerprint and accuracy, so a state that cannot faithfully restore is
//! refused by `loadState` rather than deserialized into garbage.
//!
//! What is still NOT captured: battery saves (a .srm present at boot is
//! initial state and must match on replay — the headless player loads none)
//! and time travel DURING a recording — a load-state or rewind mid-take
//! breaks the input-stream model, and the SDL recorder discards a recording
//! rather than writing a movie that cannot replay.
//!
//! File format `.ymv`, little-endian throughout:
//!
//!   off  size  field
//!     0     4  magic "YMV1"
//!     4     2  version (1 = power-on, 2 = may carry an anchor)
//!     6     1  accuracy (0 fast, 1 accurate)
//!     7     1  region (0 ntsc, 1 pal)
//!     8     4  crc32 of the copier-stripped image as played
//!    12     4  frame count
//!    16     8  framebuffer hash after the last frame (0 = not recorded)
//!    24     8  audio-stream hash after the last frame (0 = not recorded)
//!  --- version 2 only ---
//!    32     4  anchor length in bytes (0 = starts at power-on)
//!    36     -  anchor: a save state as written by `Console.saveState`
//!  --- both ---
//!     -     -  frame count x { u16 port0 mask, u16 port1 mask }
//!
//! Version 1 is still read, and still WRITTEN for power-on recordings, so the
//! existing corpus stays valid in both directions: a v2 file appears only when
//! there is an anchor to justify it.

const std = @import("std");

pub const magic = "YMV1";
/// Written for anchored movies; power-on movies keep writing `version_plain`
/// so files stay readable by builds that predate anchoring.
pub const version: u16 = 2;
pub const version_plain: u16 = 1;
/// Header through the end hashes — the whole of a v1 header, and the fixed
/// part of a v2 one.
pub const header_len = 32;
/// v2 adds the anchor length immediately after.
pub const header_len_v2 = 36;
pub const file_ext = ".ymv";

/// Anchor ceiling: a save state is well under a megabyte; a header claiming
/// more is corrupt, and the check runs before any allocation.
pub const anchor_max = 8 * 1024 * 1024;

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
    /// The machine the first frame's input applied to, as a `saveState` blob;
    /// null means the movie starts at power-on. A replay that ignores this is
    /// not a replay — feed it to `loadState` before the first frame.
    anchor: ?[]u8 = null,

    pub fn deinit(self: *Movie, gpa: std.mem.Allocator) void {
        gpa.free(self.frames);
        if (self.anchor) |a| gpa.free(a);
        self.* = undefined;
    }
};

/// Serialize to caller-owned bytes. An anchored movie is written as version 2;
/// a power-on one stays version 1 so older builds keep reading it.
pub fn encode(gpa: std.mem.Allocator, m: Movie) ![]u8 {
    const head: usize = if (m.anchor != null) header_len_v2 else header_len;
    const alen: usize = if (m.anchor) |a| a.len else 0;
    const out = try gpa.alloc(u8, head + alen + m.frames.len * 4);
    @memcpy(out[0..4], magic);
    std.mem.writeInt(u16, out[4..6], if (m.anchor != null) version else version_plain, .little);
    out[6] = m.accuracy;
    out[7] = m.region;
    std.mem.writeInt(u32, out[8..12], m.rom_crc, .little);
    std.mem.writeInt(u32, out[12..16], @intCast(m.frames.len), .little);
    std.mem.writeInt(u64, out[16..24], m.end_frame_hash, .little);
    std.mem.writeInt(u64, out[24..32], m.end_audio_hash, .little);
    if (m.anchor) |a| {
        std.mem.writeInt(u32, out[32..36], @intCast(a.len), .little);
        @memcpy(out[header_len_v2..][0..a.len], a);
    }
    const body = out[head + alen ..];
    for (m.frames, 0..) |f, i| {
        std.mem.writeInt(u16, body[i * 4 ..][0..2], f[0], .little);
        std.mem.writeInt(u16, body[i * 4 + 2 ..][0..2], f[1], .little);
    }
    return out;
}

/// Parse from bytes; the returned movie owns a fresh `frames` allocation.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) ParseError!Movie {
    if (bytes.len < header_len) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;
    const ver = std.mem.readInt(u16, bytes[4..6], .little);
    if (ver != version and ver != version_plain) return error.BadVersion;
    const count = std.mem.readInt(u32, bytes[12..16], .little);
    if (count > frames_max) return error.TooLong;

    // v2 carries the anchor between the header and the frames; v1 has neither
    // the length field nor the blob.
    var head: usize = header_len;
    var alen: usize = 0;
    if (ver == version) {
        if (bytes.len < header_len_v2) return error.Truncated;
        alen = std.mem.readInt(u32, bytes[32..36], .little);
        if (alen > anchor_max) return error.TooLong;
        head = header_len_v2;
    }
    if (bytes.len < head + alen + @as(usize, count) * 4) return error.Truncated;

    const anchor: ?[]u8 = if (alen != 0) try gpa.dupe(u8, bytes[head..][0..alen]) else null;
    errdefer if (anchor) |a| gpa.free(a);
    const frames = try gpa.alloc([2]u16, count);
    errdefer gpa.free(frames);
    const body = bytes[head + alen ..];
    for (frames, 0..) |*f, i| {
        f[0] = std.mem.readInt(u16, body[i * 4 ..][0..2], .little);
        f[1] = std.mem.readInt(u16, body[i * 4 + 2 ..][0..2], .little);
    }
    return .{
        .accuracy = bytes[6],
        .region = bytes[7],
        .rom_crc = std.mem.readInt(u32, bytes[8..12], .little),
        .end_frame_hash = std.mem.readInt(u64, bytes[16..24], .little),
        .end_audio_hash = std.mem.readInt(u64, bytes[24..32], .little),
        .frames = frames,
        .anchor = anchor,
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

test "movie: a power-on recording still writes version 1" {
    const gpa = testing.allocator;
    const frames = try gpa.dupe([2]u16, &.{.{ 0x0100, 0 }});
    var m: Movie = .{
        .accuracy = 1,
        .region = 0,
        .rom_crc = 1,
        .end_frame_hash = 0,
        .end_audio_hash = 0,
        .frames = frames,
    };
    defer m.deinit(gpa);
    const bytes = try encode(gpa, m);
    defer gpa.free(bytes);
    // Unanchored movies must stay byte-compatible with builds that predate
    // anchoring: same version, same header length, no anchor field.
    try testing.expectEqual(version_plain, std.mem.readInt(u16, bytes[4..6], .little));
    try testing.expectEqual(header_len + 4, bytes.len);
}

test "movie: an anchor round-trips and the frames still land after it" {
    const gpa = testing.allocator;
    const frames = try gpa.dupe([2]u16, &.{ .{ 0xAAAA, 0x5555 }, .{ 0x1234, 0x8765 } });
    const anchor = try gpa.dupe(u8, &[_]u8{ 'Y', 'M', 'B', 'K', 9, 9, 9 });
    var m: Movie = .{
        .accuracy = 0,
        .region = 0,
        .rom_crc = 0xC0FFEE,
        .end_frame_hash = 7,
        .end_audio_hash = 8,
        .frames = frames,
        .anchor = anchor,
    };
    defer m.deinit(gpa);

    const bytes = try encode(gpa, m);
    defer gpa.free(bytes);
    try testing.expectEqual(version, std.mem.readInt(u16, bytes[4..6], .little));
    try testing.expectEqual(header_len_v2 + anchor.len + 2 * 4, bytes.len);

    var back = try parse(gpa, bytes);
    defer back.deinit(gpa);
    // The frames are the payload most at risk from a mis-sized anchor: an
    // off-by-one in the offset reads button masks out of the state blob.
    try testing.expectEqualSlices([2]u16, m.frames, back.frames);
    try testing.expectEqualSlices(u8, anchor, back.anchor.?);
    try testing.expectEqual(m.rom_crc, back.rom_crc);
}

test "movie: an anchored header truncated inside the blob is refused" {
    const gpa = testing.allocator;
    var buf: [header_len_v2 + 4]u8 = @splat(0);
    @memcpy(buf[0..4], magic);
    std.mem.writeInt(u16, buf[4..6], version, .little);
    std.mem.writeInt(u32, buf[12..16], 1, .little); // 1 frame
    std.mem.writeInt(u32, buf[32..36], 64, .little); // ...behind a 64-byte anchor that is not there
    try testing.expectError(error.Truncated, parse(gpa, &buf));
    std.mem.writeInt(u32, buf[32..36], anchor_max + 1, .little);
    try testing.expectError(error.TooLong, parse(gpa, &buf));
    // A v2 file whose header stops before the length field is truncated, not
    // silently treated as v1.
    try testing.expectError(error.Truncated, parse(gpa, buf[0..header_len]));
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
