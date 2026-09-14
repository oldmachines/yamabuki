//! Takes on the machine: the recording's slot marks, replay state, the end-state sidecar and its marks, rewinding a recording to a slot, and writing the `.ymv` with its sidecars.
//!
//! Carved out of app.zig as pure code motion; every declaration
//! here is re-exported from app.zig, which stays the root.

const core = @import("snes_core");
const saves = @import("../saves.zig");
const std = @import("std");
const util = @import("util");
const app_root = @import("../app.zig");

const Options = app_root.Options;
const nextNumberedPath = app_root.nextNumberedPath;
/// Encode and write one screenshot, named by the first free index — no
/// wall-clock dependency, and the names sort in capture order.
/// Reset, load-state, and rewind rewrite history MID-TAKE, which an input
/// stream cannot follow: a recording in progress is discarded (a movie that
/// cannot replay must not be written) and a replay in progress hands input
/// back. Note this is about time travel *during* a recording — starting one
/// from a loaded state is fine, and carries that state as the movie's anchor.
/// A state load landed on `slot` while a take is recording.
///
/// If that slot holds a state saved during THIS take, the log is truncated
/// back to the frame it was saved at: replaying the take from its start now
/// reaches exactly the machine the state restored, so the recording stays
/// valid and the player keeps their progress. Returns the frame rewound to.
///
/// Marks past the cut name a branch that no longer exists. Dropping them is
/// what stops a later load from restoring a machine the truncated log cannot
/// explain — the one way this feature could silently produce a desynced movie.
///
/// A slot with no mark cannot be rewound to (the take never passed through
/// that machine), so the take is discarded as before; null says so.
/// Forget every mark past `at`. Those states were saved on a branch the
/// truncation just deleted: loading one would restore a machine the shortened
/// input log cannot reach, and the movie would replay into a different game.
pub fn cutMarks(marks: *[9]?u32, at: u32) void {
    for (marks) |*m| {
        if (m.*) |f| {
            if (f > at) m.* = null;
        }
    }
}

/// The movie still owns the pads: entries left, or a per-poll tail running.
pub fn replayActive(pm: ?util.movie.Movie, idx: usize, tail: ?u32) bool {
    const m = pm orelse return false;
    return idx < m.frames.len or tail != null;
}

/// How a take is written: its entry form and what it began from.
pub const TakeForm = struct {
    per_poll: bool,
    tail_frames: u32,
    start_srm: ?[]const u8,
};

pub fn rewindRecToSlot(
    gpa: std.mem.Allocator,
    rec: *?std.array_list.Managed([2]u16),
    rec_anchor: *?[]u8,
    play_movie: *?util.movie.Movie,
    marks: *[9]?u32,
    audio_marks: *const [9]u64,
    audio_hash: *u64,
    rec_tail: *u32,
    tails: *const [9]u32,
    slot: u32,
    err: *std.Io.Writer,
) ?u32 {
    if (rec.* == null) return null;
    const at = marks[slot] orelse {
        discardMovieModes(gpa, rec, rec_anchor, play_movie, "load of a state not saved in this take", err);
        marks.* = @splat(null);
        return null;
    };
    rec.*.?.shrinkRetainingCapacity(at);
    audio_hash.* = audio_marks[slot];
    rec_tail.* = tails[slot];
    cutMarks(marks, at);
    err.print("recording rewound to frame {d} (slot {d})\n", .{ at, slot }) catch {};
    err.flush() catch {};
    return at;
}

pub fn discardMovieModes(
    gpa: std.mem.Allocator,
    rec: *?std.array_list.Managed([2]u16),
    rec_anchor: *?[]u8,
    play: *?util.movie.Movie,
    why: []const u8,
    err: *std.Io.Writer,
) void {
    if (rec.*) |*r| {
        r.deinit();
        rec.* = null;
        if (rec_anchor.*) |a| gpa.free(a);
        rec_anchor.* = null;
        err.print("movie: recording discarded ({s} breaks replay determinism)\n", .{why}) catch {};
        err.flush() catch {};
    }
    if (play.* != null) {
        play.* = null;
        err.print("movie: playback stopped ({s}); input is live\n", .{why}) catch {};
        err.flush() catch {};
    }
}

pub const end_state_magic = "YEND";
/// 1: header + state. 2: header + the slot marks + state — so a state saved
/// in an earlier session of the same playthrough still rewinds the take
/// instead of discarding it.
pub const end_state_version: u32 = 3;
/// magic, version, movie file hash, audio hash, frame count.
pub const end_state_header_len: usize = 4 + 4 + 8 + 8 + 4;

/// The state-slot marks of a take: for each slot, the frame the slot was
/// saved at (null = not in this take), the running audio hash then, and the
/// identity of the state file. Carried in the end state so a continued take
/// keeps them.
pub const EndMarks = struct {
    frames: [9]?u32 = @splat(null),
    audio: [9]u64 = @splat(0),
    hash: [9]u64 = @splat(0),
    /// Frames since the last recorded poll when the state was saved (a
    /// per-poll take's tail at that point); version 3 of the sidecar.
    tail: [9]u32 = @splat(0),

    pub const record_len_v2: usize = 4 + 8 + 8;
    pub const record_len: usize = 4 + 8 + 8 + 4;
    pub const encoded_len_v2: usize = 9 * record_len_v2;
    pub const encoded_len: usize = 9 * record_len;
    pub const none: u32 = 0xFFFF_FFFF;

    pub fn encode(self: EndMarks, out: []u8) void {
        var o: usize = 0;
        for (0..9) |i| {
            std.mem.writeInt(u32, out[o..][0..4], self.frames[i] orelse none, .little);
            std.mem.writeInt(u64, out[o + 4 ..][0..8], self.audio[i], .little);
            std.mem.writeInt(u64, out[o + 12 ..][0..8], self.hash[i], .little);
            std.mem.writeInt(u32, out[o + 20 ..][0..4], self.tail[i], .little);
            o += record_len;
        }
    }

    /// Marks past `limit` entries cannot belong to this take's prefix.
    /// `rlen` is the record length of the sidecar's version.
    pub fn decode(in: []const u8, limit: usize, rlen: usize) EndMarks {
        var m: EndMarks = .{};
        var o: usize = 0;
        for (0..9) |i| {
            const f = std.mem.readInt(u32, in[o..][0..4], .little);
            if (f != none and f <= limit) {
                m.frames[i] = f;
                m.audio[i] = std.mem.readInt(u64, in[o + 4 ..][0..8], .little);
                m.hash[i] = std.mem.readInt(u64, in[o + 12 ..][0..8], .little);
                if (rlen == record_len) m.tail[i] = std.mem.readInt(u32, in[o + 20 ..][0..4], .little);
            }
            o += rlen;
        }
        return m;
    }
};

/// Try the take's end-state sidecar for `--continue`. Restores the console
/// and returns the running audio hash at the take's end, or null (with the
/// reason printed) when the sidecar is absent, belongs to another file or
/// frame count, or is a state this build cannot load — every one of which
/// means "replay instead", never "trust it anyway".
/// The marks a take's end state carries (version 2), or none. Used by the
/// replay path, which rebuilds the machine itself but still wants the marks.
pub fn readEndMarks(io: std.Io, gpa: std.mem.Allocator, movie_path: []const u8, m: util.movie.Movie) EndMarks {
    if (movie_path.len <= util.movie.file_ext.len) return .{};
    var p_buf: [1024]u8 = undefined;
    const es_path = std.fmt.bufPrint(&p_buf, "{s}.end.state", .{movie_path[0 .. movie_path.len - util.movie.file_ext.len]}) catch return .{};
    const data = std.Io.Dir.cwd().readFileAlloc(io, es_path, gpa, .limited(64 * 1024 * 1024)) catch return .{};
    defer gpa.free(data);
    const head = end_state_header_len;
    if (data.len < head + 8 or !std.mem.eql(u8, data[0..4], end_state_magic)) return .{};
    const ver = std.mem.readInt(u32, data[4..8], .little);
    const mlen: usize = if (ver == 2) EndMarks.encoded_len_v2 else if (ver == 3) EndMarks.encoded_len else return .{};
    if (data.len < head + mlen) return .{};
    const movie_bytes = std.Io.Dir.cwd().readFileAlloc(io, movie_path, gpa, .limited(64 * 1024 * 1024)) catch return .{};
    defer gpa.free(movie_bytes);
    if (std.mem.readInt(u64, data[8..16], .little) != std.hash.Fnv1a_64.hash(movie_bytes)) return .{};
    return EndMarks.decode(data[head .. head + mlen], m.frames.len, mlen / 9);
}

pub fn loadEndState(io: std.Io, gpa: std.mem.Allocator, con: *core.AnyConsole, movie_path: []const u8, m: util.movie.Movie, marks_out: *EndMarks, err: *std.Io.Writer) ?u64 {
    marks_out.* = .{};
    if (movie_path.len <= util.movie.file_ext.len) return null;
    var p_buf: [1024]u8 = undefined;
    const es_path = std.fmt.bufPrint(&p_buf, "{s}.end.state", .{movie_path[0 .. movie_path.len - util.movie.file_ext.len]}) catch return null;
    const data = std.Io.Dir.cwd().readFileAlloc(io, es_path, gpa, .limited(64 * 1024 * 1024)) catch return null;
    defer gpa.free(data);
    const version: u32 = if (data.len >= 8 and std.mem.eql(u8, data[0..4], end_state_magic)) std.mem.readInt(u32, data[4..8], .little) else 0;
    const mlen: usize = if (version == 2) EndMarks.encoded_len_v2 else if (version == 3) EndMarks.encoded_len else 0;
    const head: usize = end_state_header_len + mlen;
    if (data.len < head or (version != 1 and version != 2 and version != 3)) {
        err.print("movie: {s} is not an end state this build understands; replaying the take instead\n", .{es_path}) catch {};
        err.flush() catch {};
        return null;
    }
    const movie_bytes = std.Io.Dir.cwd().readFileAlloc(io, movie_path, gpa, .limited(64 * 1024 * 1024)) catch return null;
    defer gpa.free(movie_bytes);
    if (std.mem.readInt(u64, data[8..16], .little) != std.hash.Fnv1a_64.hash(movie_bytes) or
        std.mem.readInt(u32, data[24..28], .little) != m.frames.len)
    {
        err.print("movie: {s} belongs to another take; replaying this one instead\n", .{es_path}) catch {};
        err.flush() catch {};
        return null;
    }
    con.loadState(data[head..]) catch |e| {
        err.print("movie: the take's end state cannot load on this build ({s}); replaying the take instead\n", .{@errorName(e)}) catch {};
        err.flush() catch {};
        return null;
    };
    if (mlen != 0) marks_out.* = EndMarks.decode(data[end_state_header_len..head], m.frames.len, mlen / 9);
    return std.mem.readInt(u64, data[16..24], .little);
}

/// Write a finished recording as `<movies>/<game_id>-NNNN.ymv`. The end
/// hashes are taken from the machine as it stands — the frame after the
/// last recorded input, exactly what a replay reproduces.
pub fn writeMovie(
    io: std.Io,
    gpa: std.mem.Allocator,
    opts: *const Options,
    con: *core.AnyConsole,
    frames: []const [2]u16,
    anchor: ?[]u8,
    audio_hash: u64,
    marks: EndMarks,
    form: TakeForm,
    err: *std.Io.Writer,
) void {
    const dir = opts.movies_dir orelse return;
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const path = nextNumberedPath(io, gpa, dir, opts.game_id, util.movie.file_ext) orelse {
        err.print("movie: no free take number under {s}; take not written\n", .{dir}) catch {};
        err.flush() catch {};
        return;
    };
    defer gpa.free(path);
    const m: util.movie.Movie = .{
        .accuracy = if (opts.accuracy == .accurate) 1 else 0,
        .region = if (con.region() == .pal) 1 else 0,
        .rom_crc = opts.rom_crc,
        .end_frame_hash = core.console.hashFrame(con.framebuffer()),
        .end_audio_hash = audio_hash,
        .frames = @constCast(frames),
        .anchor = anchor,
        .per_poll = form.per_poll,
        .tail_frames = form.tail_frames,
    };
    const data = util.movie.encode(gpa, m) catch |e| {
        err.print("movie: save failed: {s}\n", .{@errorName(e)}) catch {};
        err.flush() catch {};
        return;
    };
    defer gpa.free(data);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch |e| {
        err.print("movie: save failed: {s}\n", .{@errorName(e)}) catch {};
        err.flush() catch {};
        return;
    };
    // The take's battery save, next to the take: a --record session never
    // touches the real .srm, so without this the in-game saves made during
    // the take would be lost with the window. `--record --srm <this file>`
    // continues from it.
    if (con.cartridge().hasBattery() or saves.liftedSram(con) != null) {
        if (std.fmt.allocPrint(gpa, "{s}.srm", .{path[0 .. path.len - util.movie.file_ext.len]})) |srm_path| {
            defer gpa.free(srm_path);
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = srm_path, .data = saves.liveSram(con) }) catch |e| {
                err.print("movie: battery save of this take not written: {s}\n", .{@errorName(e)}) catch {};
                err.flush() catch {};
            };
            err.print("movie: battery save of this take: {s} (continue with --record --srm)\n", .{srm_path}) catch {};
            err.flush() catch {};
        } else |e| {
            err.print("movie: battery save of this take not written: {s}\n", .{@errorName(e)}) catch {};
            err.flush() catch {};
        }
    }
    // The save the take began from, beside it: with it, a power-on take
    // replays from the same save on any build (the takes screen and
    // --movie load it; so does the headless).
    if (form.start_srm) |sb| {
        var sp_buf: [1024]u8 = undefined;
        if (util.movie.startSrmPath(&sp_buf, path)) |sp| {
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sp, .data = sb }) catch |e| {
                err.print("movie: start save of this take not written: {s}\n", .{@errorName(e)}) catch {};
                err.flush() catch {};
            };
        }
    }
    // The machine at the take's last frame, so `--continue` can start here
    // instead of replaying. Bound to this exact file by the file's hash, and
    // to this build by the state's own header; the running audio hash rides
    // along because the take's end hashes include it.
    if (std.fmt.allocPrint(gpa, "{s}.end.state", .{path[0 .. path.len - util.movie.file_ext.len]})) |es_path| {
        defer gpa.free(es_path);
        const head = end_state_header_len + EndMarks.encoded_len;
        if (gpa.alloc(u8, head + core.AnyConsole.state_size)) |buf| {
            defer gpa.free(buf);
            @memcpy(buf[0..4], end_state_magic);
            std.mem.writeInt(u32, buf[4..8], end_state_version, .little);
            std.mem.writeInt(u64, buf[8..16], std.hash.Fnv1a_64.hash(data), .little);
            std.mem.writeInt(u64, buf[16..24], audio_hash, .little);
            std.mem.writeInt(u32, buf[24..28], @intCast(frames.len), .little);
            marks.encode(buf[end_state_header_len..head]);
            const written = con.saveState(buf[head..]);
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = es_path, .data = buf[0 .. head + written] }) catch |e| {
                err.print("movie: end state of this take not written: {s}\n", .{@errorName(e)}) catch {};
                err.flush() catch {};
            };
            err.print("movie: end state of this take: {s} (--continue starts here without replaying)\n", .{es_path}) catch {};
            err.flush() catch {};
        } else |_| {}
    } else |_| {}
    err.print("movie: {s} ({} {s}{s}{s}, end hashes recorded)\n", .{
        path,
        frames.len,
        if (form.per_poll) "polls" else "frames",
        if (anchor != null) ", anchored to a start state" else ", from power-on",
        if (form.start_srm != null) " with a start save" else "",
    }) catch {};
    err.flush() catch {};
}
