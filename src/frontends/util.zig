//! Shared helpers for the frontends and test runners: RGB565->RGB888
//! expansion, the PPM/WAV writers, the audio drain+hash loop, an
//! argv-iterator helper, and the SDL `--shot` write path.
//!
//! Imported by frontends and test runners ONLY — never by snes_core, which
//! must stay freestanding.

const std = @import("std");
const core = @import("snes_core");

/// Input movies (TAS-style record/replay); see movie.zig.
pub const movie = @import("movie.zig");

test {
    _ = movie;
}

/// Expand one RGB565 pixel to RGB888 by bit-replicating the 5/6-bit channels
/// into 8 bits, so white (0x1F/0x3F/0x1F) lands on 0xFF/0xFF/0xFF instead of
/// the 0xF8/0xFC/0xF8 a naive left-shift gives. This is the one expansion
/// used everywhere a framebuffer becomes 24-bit RGB — headless `--ppm` and
/// the SDL software `--shot` of the same frame are byte-identical because of
/// it.
pub fn expandPixel(px: u16) [3]u8 {
    const r5: u8 = @intCast((px >> 11) & 0x1F);
    const g6: u8 = @intCast((px >> 5) & 0x3F);
    const b5: u8 = @intCast(px & 0x1F);
    return .{
        (r5 << 3) | (r5 >> 2),
        (g6 << 2) | (g6 >> 4),
        (b5 << 3) | (b5 >> 2),
    };
}

test "expandPixel: 0 -> 0, max -> 255 per channel" {
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, expandPixel(0));
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, expandPixel(0xFFFF));
}

test "expandPixel: monotonic per channel" {
    var prev_r: u8 = 0;
    var r5: u16 = 0;
    while (r5 <= 0x1F) : (r5 += 1) {
        const r = expandPixel(r5 << 11)[0];
        try std.testing.expect(r >= prev_r);
        prev_r = r;
    }
    var prev_g: u8 = 0;
    var g6: u16 = 0;
    while (g6 <= 0x3F) : (g6 += 1) {
        const g = expandPixel(g6 << 5)[1];
        try std.testing.expect(g >= prev_g);
        prev_g = g;
    }
}

/// Expand a whole RGB565 framebuffer (w*h pixels) into a freshly allocated
/// RGB888 buffer.
pub fn expandFramebuffer(gpa: std.mem.Allocator, fb: []const u16, w: u32, h: u32) ![]u8 {
    const rgb = try gpa.alloc(u8, @as(usize, w) * @as(usize, h) * 3);
    for (fb[0 .. @as(usize, w) * @as(usize, h)], 0..) |px, i| {
        rgb[i * 3 ..][0..3].* = expandPixel(px);
    }
    return rgb;
}

/// Write already-expanded 24-bit RGB as a binary PPM (P6).
pub fn writePpm(io: std.Io, path: []const u8, w: u32, h: u32, rgb: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    const wr = &fw.interface;

    try wr.print("P6\n{d} {d}\n255\n", .{ w, h });
    try wr.writeAll(rgb);
    try wr.flush();
}

/// Expand an RGB565 framebuffer and write it as a PPM in one step — what
/// headless `--ppm` and the SDL software `--shot` path both want.
pub fn writeFramebufferPpm(gpa: std.mem.Allocator, io: std.Io, path: []const u8, fb: []const u16, w: u32, h: u32) !void {
    const rgb = try expandFramebuffer(gpa, fb, w, h);
    try writePpm(io, path, w, h, rgb);
}

/// Write interleaved stereo i16 samples as a 32 kHz PCM WAV.
pub fn writeWav(io: std.Io, path: []const u8, samples: []const i16) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    const wr = &fw.interface;

    const rate: u32 = core.timing.dsp_sample_hz;
    const data_len: u32 = @intCast(samples.len * 2);
    try wr.writeAll("RIFF");
    try wr.writeInt(u32, 36 + data_len, .little);
    try wr.writeAll("WAVEfmt ");
    try wr.writeInt(u32, 16, .little); // PCM chunk size
    try wr.writeInt(u16, 1, .little); // PCM
    try wr.writeInt(u16, 2, .little); // stereo
    try wr.writeInt(u32, rate, .little);
    try wr.writeInt(u32, rate * 4, .little); // byte rate
    try wr.writeInt(u16, 4, .little); // block align
    try wr.writeInt(u16, 16, .little); // bits per sample
    try wr.writeAll("data");
    try wr.writeInt(u32, data_len, .little);
    for (samples) |s| try wr.writeInt(i16, s, .little);
    try wr.flush();
}

/// Drain every frame's audio out of the console's ring (it holds ~15 frames,
/// so this must run every frame to avoid overrunning it) and fold it into a
/// running FNV-1a hash. `sink_ctx`/`sink`, if given, see each chunk before
/// it's overwritten — used to track peak amplitude, accumulate a WAV dump, or
/// forward samples to a live audio device. Pass `{}`/`null` to just drain and
/// hash.
pub fn drainAudio(
    con: anytype,
    hash: *u64,
    sink_ctx: anytype,
    comptime sink: ?fn (@TypeOf(sink_ctx), []const i16) anyerror!void,
) !void {
    var drain: [4096]i16 = undefined;
    while (true) {
        const n = con.readAudio(&drain);
        if (n == 0) break;
        hash.* = core.console.hashAudio(hash.*, drain[0..n]);
        if (sink) |f| try f(sink_ctx, drain[0..n]);
    }
}

/// Drain audio without hashing — for a replay pass whose hash is not
/// authoritative (rom_runner's post-snapshot half); the ring still has to be
/// kept from backing up.
pub fn drainAudioDiscard(con: anytype) void {
    var drain: [4096]i16 = undefined;
    while (con.readAudio(&drain) != 0) {}
}

// --- FastROM patch generation, verified in-emulator ---------------------------

/// Why a generation attempt produced no patch.
pub const GenFailure = union(enum) {
    /// The transform refused; see `core.patchgen.Reason.describe`.
    refused: core.patchgen.Refusal,
    /// First frame whose framebuffer hash diverged from the unpatched run —
    /// the faster bus changed something the player would see.
    frame_mismatch: u32,
    /// The 32 kHz audio streams diverged over the run.
    audio_mismatch,
    /// Frame at whose end MEMSEL read back disabled in the patched run: the
    /// game cleared it from a code path the baseline never exercised.
    memsel_lost: u32,
};

/// A generated, verified patch and its measured effect.
pub const GenOutcome = struct {
    /// The transformed image and the encoded BPS, both caller-owned.
    image: []u8,
    bps: []u8,
    stub_addr: u16,
    trampolines: u8,
    memsel_stores_nopped: u8,
    /// Profiled frames (after the skipped boot) in each run.
    frames: u32,
    /// The profiler's frame-budget summary, unpatched and patched. FastROM
    /// cuts ~2 master cycles from every ROM access, which shows up here as
    /// idle headroom — the proof the patch does something.
    base: core.profile.Summary,
    fast: core.profile.Summary,
};

/// The generation pipeline as a resumable session, so a UI can run it in
/// slices on its main loop — the same incremental-not-threaded stance as the
/// SDL library scanner — while the headless one-shot wrapper below just steps
/// it to completion. Phases: profile the unpatched ROM (which also observes
/// the MEMSEL stores the generator must neutralise) → transform → replay and
/// compare frame-for-frame → encode. A failure at any point carries its
/// reason; nothing is handed out unless every gate passed.
pub const GenSession = struct {
    gpa: std.mem.Allocator,
    /// Borrowed; must outlive the session (it is also the BPS source).
    image: []const u8,
    frames: u32,
    skip: u32,
    /// Optional recorded playthrough driving both pads, one entry per frame
    /// (borrowed; must outlive the session). Set after `start`. Without one
    /// the run is unattended from power-on; past the movie's end both pads
    /// read released — deterministic either way, which is all the pipeline
    /// requires.
    movie_frames: ?[]const [2]u16 = null,
    total: u32,

    /// Baseline per-frame framebuffer hashes — what the verify run replays
    /// against.
    hashes: []u64,
    samples: []core.profile.FrameSample,
    scratch: []f64,

    phase: Phase = .baseline,
    con: ?*core.ProfilingConsole = null,
    i: u32 = 0,
    n_samples: usize = 0,
    audio: u64 = core.console.audio_hash_init,

    base_audio: u64 = 0,
    base_summary: core.profile.Summary = undefined,

    /// The transformed image, owned by the session until `finish` hands it
    /// out in a `GenOutcome` (then null).
    gen_image: ?[]u8 = null,
    stub_addr: u16 = 0,
    trampolines: u8 = 0,
    nopped: u8 = 0,

    pub const Phase = enum { baseline, verify, finished };
    pub const Progress = struct { phase: Phase, frame: u32, total: u32 };
    pub const Status = union(enum) { running: Progress, done: GenOutcome, failed: GenFailure };

    pub fn start(
        gpa: std.mem.Allocator,
        image: []const u8,
        frames: u32,
        skip: u32,
    ) !GenSession {
        const total = skip + frames;
        var s: GenSession = .{
            .gpa = gpa,
            .image = image,
            .frames = frames,
            .skip = skip,
            .total = total,
            .hashes = try gpa.alloc(u64, total),
            .samples = undefined,
            .scratch = undefined,
        };
        errdefer gpa.free(s.hashes);
        s.samples = try gpa.alloc(core.profile.FrameSample, total);
        errdefer gpa.free(s.samples);
        s.scratch = try gpa.alloc(f64, total);
        errdefer gpa.free(s.scratch);
        try s.bootConsole(image);
        return s;
    }

    /// Safe on every path: cancel mid-run, after a failure, or after `done`
    /// (the handed-out image/bps are the caller's and are not touched).
    pub fn deinit(self: *GenSession) void {
        self.dropConsole();
        if (self.gen_image) |gi| self.gpa.free(gi);
        self.gpa.free(self.hashes);
        self.gpa.free(self.samples);
        self.gpa.free(self.scratch);
        self.* = undefined;
    }

    fn bootConsole(self: *GenSession, image: []const u8) !void {
        const cart = try core.Cartridge.load(self.gpa, image);
        const con = self.gpa.create(core.ProfilingConsole) catch |e| {
            self.gpa.free(cart.rom);
            return e;
        };
        con.init(cart);
        self.con = con;
        self.i = 0;
        self.n_samples = 0;
        self.audio = core.console.audio_hash_init;
    }

    fn dropConsole(self: *GenSession) void {
        if (self.con) |c| {
            self.gpa.free(c.cart.rom);
            self.gpa.destroy(c);
            self.con = null;
        }
    }

    /// Advance up to `max_frames` emulated frames. Phase transitions
    /// (transform, encode) happen inside a step and cost no frame budget.
    /// After `.done` or `.failed` the session must not be stepped again.
    pub fn step(self: *GenSession, max_frames: u32) !Status {
        std.debug.assert(self.phase != .finished);
        var budget = max_frames;
        while (budget > 0) : (budget -= 1) {
            switch (self.phase) {
                .baseline => {
                    const idx = self.i;
                    self.hashes[idx] = try self.runOneFrame();
                    if (self.i == self.total) if (try self.finishBaseline()) |f| {
                        self.phase = .finished;
                        return .{ .failed = f };
                    };
                },
                .verify => {
                    const idx = self.i;
                    const h = try self.runOneFrame();
                    if (h != self.hashes[idx]) {
                        self.phase = .finished;
                        return .{ .failed = .{ .frame_mismatch = idx } };
                    }
                    if (!self.con.?.bus.fastrom) {
                        self.phase = .finished;
                        return .{ .failed = .{ .memsel_lost = idx } };
                    }
                    if (self.i == self.total) {
                        const status = try self.finish();
                        self.phase = .finished;
                        return status;
                    }
                },
                .finished => unreachable,
            }
        }
        return .{ .running = .{ .phase = self.phase, .frame = self.i, .total = self.total } };
    }

    fn runOneFrame(self: *GenSession) !u64 {
        const con = self.con.?;
        if (self.movie_frames) |mf| {
            const f: [2]u16 = if (self.i < mf.len) mf[self.i] else .{ 0, 0 };
            con.setButtons(0, f[0]);
            con.setButtons(1, f[1]);
        }
        con.runFrame();
        try drainAudio(con, &self.audio, {}, null);
        if (con.takeProfile()) |smp| {
            if (self.i >= self.skip) {
                self.samples[self.n_samples] = smp;
                self.n_samples += 1;
            }
        }
        self.i += 1;
        return core.console.hashFrame(con.framebuffer());
    }

    /// Close the baseline run and transform. Returns a failure to report, or
    /// null when the session has moved on to the verify run.
    fn finishBaseline(self: *GenSession) !?GenFailure {
        const con = self.con.?;
        self.base_summary = core.profile.summarise(self.samples[0..self.n_samples], self.scratch);
        self.base_audio = self.audio;
        if (con.prof.memsel_overflow) {
            self.dropConsole();
            return .{ .refused = .{ .reason = .memsel_store_unpatchable } };
        }
        const memsel_pcs: [core.profile.memsel_pc_cap]u24 = con.prof.memsel_pcs;
        const n_memsel: usize = con.prof.n_memsel_pcs;
        self.dropConsole();

        var refusal: ?core.patchgen.Refusal = null;
        const res = core.patchgen.generate(self.gpa, self.image, .{
            .memsel_store_pcs = memsel_pcs[0..n_memsel],
        }, &refusal) catch |e| switch (e) {
            error.Refused => return .{ .refused = refusal.? },
            else => return e,
        };
        self.gen_image = res.image;
        self.stub_addr = res.stub_addr;
        self.trampolines = res.trampolines;
        self.nopped = res.memsel_stores_nopped;

        try self.bootConsole(res.image);
        self.phase = .verify;
        return null;
    }

    /// Close the verify run: the audio gate, then the encode and hand-off.
    fn finish(self: *GenSession) !Status {
        if (self.audio != self.base_audio) {
            return .{ .failed = .audio_mismatch };
        }
        const fast_summary = core.profile.summarise(self.samples[0..self.n_samples], self.scratch);
        self.dropConsole();
        const bps = try core.patch.writeBps(self.gpa, self.image, self.gen_image.?);
        const image = self.gen_image.?;
        self.gen_image = null; // ownership moves to the outcome
        return .{ .done = .{
            .image = image,
            .bps = bps,
            .stub_addr = self.stub_addr,
            .trampolines = self.trampolines,
            .memsel_stores_nopped = self.nopped,
            .frames = self.frames,
            .base = self.base_summary,
            .fast = fast_summary,
        } };
    }
};

/// Generate the FastROM transformation of a copier-stripped `image` and
/// verify it in-emulator before encoding anything: the patched ROM must
/// render every one of `skip + frames` frames pixel-identical to the
/// unpatched ROM (boot included) and produce an identical audio stream — the
/// faster bus may change nothing the player sees or hears — and MEMSEL must
/// read enabled at every frame boundary of the patched run. MEMSEL stores the
/// baseline run observes are handed to the generator for neutralisation, so
/// the stock `STZ $420D` init idiom does not silently undo the patch.
///
/// On failure, `failure` names what went wrong and nothing is returned; a
/// patch that cannot be verified is a patch that does not get written.
/// (This is `GenSession` stepped to completion — the SDL player runs the
/// same session incrementally with a progress screen.)
pub fn generateFastromVerified(
    gpa: std.mem.Allocator,
    image: []const u8,
    frames: u32,
    skip: u32,
    movie_frames: ?[]const [2]u16,
    failure: *?GenFailure,
) !GenOutcome {
    var s = try GenSession.start(gpa, image, frames, skip);
    s.movie_frames = movie_frames;
    defer s.deinit();
    while (true) {
        switch (try s.step(std.math.maxInt(u32))) {
            .running => {},
            .done => |o| return o,
            .failed => |f| {
                failure.* = f;
                return error.GenFailed;
            },
        }
    }
}

// --- stage S4: the timing-tolerant differential gate ---------------------------

/// How two runs' per-frame framebuffer hash sequences relate.
pub const Equivalence = enum {
    /// Every frame identical: nothing observable moved. The only acceptable
    /// verdict for a transformation that promises no timing change (FastROM
    /// verification, the SA-1 shell, pure state relocation on a headroom
    /// capture).
    identical,
    /// The runs show the SAME distinct pictures in the same order, but with
    /// different numbers of consecutive repeats — exactly the signature of a
    /// speedup: a lag frame re-shows the previous picture, and a faster run
    /// repeats it fewer times. This is the strongest mechanical equivalence
    /// a working offload can satisfy, and it is falsifiable: any new,
    /// missing, or reordered picture is a divergence.
    equivalent,
    /// The converted run rendered something the original never showed (or
    /// vice versa): the transformation changed behavior, not just timing.
    divergent,
};

/// Classify two hash sequences. The dedup view collapses consecutive equal
/// hashes; equality of the collapsed sequences is the "same pictures, fewer
/// repeats" test. Honest limits, for the caller to print: a game that
/// animates from an NMI-side frame counter does not re-show identical
/// pictures during lag, so its speedup can legitimately read `divergent` —
/// the gate refuses rather than guesses; and audio equivalence is not
/// checkable across a timing shift at all.
/// Frame-granular audio-envelope comparison, for a converted run whose
/// FRAMES are pixel-identical but whose sample stream is not hash-equal.
/// Why that happens: state relocation changes a handful of access timings
/// by a few master cycles, which slides the S-CPU→APU handshake; a voice
/// triggered one sample later makes every subsequent MIXED sample differ
/// numerically, so the stream hash is unrecoverable even though what the
/// player hears is unchanged. What can still be verified — and what this
/// checks — is that the same sounds happen at the same frames: each
/// frame's energy (sum of |sample|) must sit inside the other run's
/// neighbouring-frame min/max window widened by 10% plus a small
/// absolute floor (near-silence wobble), checked in BOTH directions so a
/// missing sound and an extra sound both fail. The ±1-frame window
/// forgives an effect landing across a frame boundary. Two voices whose
/// relative phase moved by a sample can also beat constructively for a
/// frame or two — a brief, bounded energy blip — so RARE excursions are
/// tolerated: at most one frame per thousand may exceed the 10% window,
/// and even those must stay inside a hard 35% bound. A sound silenced,
/// invented, or moved further than the window always exceeds the cap or
/// the count. Returns the first offending frame, or null when the
/// envelopes are equivalent.
pub fn audioEnvelopeMismatch(base: []const u64, conv: []const u64) ?u32 {
    std.debug.assert(base.len == conv.len);
    var excursions: usize = 0;
    var first: ?u32 = null;
    const allowed = @max(2, base.len / 1000);
    for (0..base.len) |i| {
        if (envelopeOutside(base[i], conv, i, 10) or envelopeOutside(conv[i], base, i, 10)) {
            if (envelopeOutside(base[i], conv, i, 35) or envelopeOutside(conv[i], base, i, 35))
                return @intCast(i); // beyond the hard bound: never acceptable
            excursions += 1;
            if (first == null) first = @intCast(i);
            if (excursions > allowed) return first;
        }
    }
    return null;
}

const envelope_floor: u64 = 50_000;

fn envelopeOutside(v: u64, other: []const u64, i: usize, pct: u64) bool {
    const lo_i = i -| 1;
    const hi_i = @min(other.len - 1, i + 1);
    var lo: u64 = std.math.maxInt(u64);
    var hi: u64 = 0;
    for (other[lo_i .. hi_i + 1]) |c| {
        lo = @min(lo, c);
        hi = @max(hi, c);
    }
    return v + envelope_floor < lo - lo * pct / 100 or v > hi + hi * pct / 100 + envelope_floor;
}

test "audioEnvelopeMismatch: sub-sample wobble passes, silenced and invented sounds fail" {
    // Identical envelopes.
    const a = [_]u64{ 0, 0, 4_000_000, 4_100_000, 3_900_000, 0 };
    try std.testing.expectEqual(@as(?u32, null), audioEnvelopeMismatch(&a, &a));
    // A sample-scale phase shift: energies wobble well under 10%.
    const wobble = [_]u64{ 0, 0, 4_010_000, 4_070_000, 3_930_000, 0 };
    try std.testing.expectEqual(@as(?u32, null), audioEnvelopeMismatch(&a, &wobble));
    // A sound landing one frame late crosses a boundary the window forgives.
    const late = [_]u64{ 0, 0, 0, 4_000_000, 4_100_000, 0 };
    const late_base = [_]u64{ 0, 0, 4_000_000, 4_100_000, 0, 0 };
    try std.testing.expectEqual(@as(?u32, null), audioEnvelopeMismatch(&late_base, &late));
    // A silenced sound fails — in either argument order.
    const silenced = [_]u64{ 0, 0, 0, 0, 0, 0 };
    try std.testing.expect(audioEnvelopeMismatch(&a, &silenced) != null);
    try std.testing.expect(audioEnvelopeMismatch(&silenced, &a) != null);
    // An invented sound (nothing near it in the original) fails.
    const invented = [_]u64{ 0, 0, 4_000_000, 4_100_000, 3_900_000, 9_000_000 };
    try std.testing.expect(audioEnvelopeMismatch(&a, &invented) != null);
    // A rare, bounded excursion — the constructive-overlap blip of two
    // voices whose phase moved a sample — is tolerated...
    const blip = [_]u64{ 0, 0, 4_000_000, 4_800_000, 3_900_000, 0 };
    try std.testing.expectEqual(@as(?u32, null), audioEnvelopeMismatch(&a, &blip));
    // ...but not one beyond the hard bound,
    const loud_blip = [_]u64{ 0, 0, 4_000_000, 6_000_000, 3_900_000, 0 };
    try std.testing.expect(audioEnvelopeMismatch(&a, &loud_blip) != null);
    // and not more of them than one per thousand frames (here: > 2 of 6).
    const many_blips = [_]u64{ 0, 4_800_000, 4_800_000, 4_900_000, 4_700_000, 0 };
    const quiet_base = [_]u64{ 0, 4_000_000, 4_000_000, 4_100_000, 3_900_000, 0 };
    try std.testing.expect(audioEnvelopeMismatch(&quiet_base, &many_blips) != null);
}

pub fn framesEquivalent(base: []const u64, conv: []const u64) Equivalence {
    if (std.mem.eql(u64, base, conv)) return .identical;
    var bi: usize = 0;
    var ci: usize = 0;
    while (bi < base.len and ci < conv.len) {
        if (base[bi] != conv[ci]) return .divergent;
        const h = base[bi];
        while (bi < base.len and base[bi] == h) bi += 1;
        while (ci < conv.len and conv[ci] == h) ci += 1;
    }
    // A tail of repeats on one side only is still the same picture stream;
    // any NEW picture in a tail is not.
    while (bi < base.len) : (bi += 1) {
        if (bi > 0 and base[bi] != base[bi - 1]) return .divergent;
    }
    while (ci < conv.len) : (ci += 1) {
        if (ci > 0 and conv[ci] != conv[ci - 1]) return .divergent;
    }
    return .equivalent;
}

test "framesEquivalent: identity, speedup-shaped repeats, and real divergence" {
    const a = [_]u64{ 1, 1, 2, 2, 2, 3 };
    try std.testing.expectEqual(Equivalence.identical, framesEquivalent(&a, &a));
    // The sped-up run shows the same pictures with fewer lag repeats.
    const fast = [_]u64{ 1, 2, 2, 3, 3, 3 };
    try std.testing.expectEqual(Equivalence.equivalent, framesEquivalent(&a, &fast));
    // Symmetric: a slower run is still the same picture stream (the caller
    // judges whether slower is acceptable — the gate only judges sameness).
    try std.testing.expectEqual(Equivalence.equivalent, framesEquivalent(&fast, &a));
    // A picture the original never showed: divergent.
    const wrong = [_]u64{ 1, 2, 9, 3 };
    try std.testing.expectEqual(Equivalence.divergent, framesEquivalent(&a, &wrong));
    // A missing picture: divergent.
    const skipped = [_]u64{ 1, 3, 3 };
    try std.testing.expectEqual(Equivalence.divergent, framesEquivalent(&a, &skipped));
    // Reordered pictures: divergent.
    const reordered = [_]u64{ 2, 1, 3 };
    try std.testing.expectEqual(Equivalence.divergent, framesEquivalent(&a, &reordered));
    // Tails: extra repeats of the last picture are fine, new pictures not.
    const tail_repeat = [_]u64{ 1, 2, 2, 3, 3, 3, 3, 3 };
    try std.testing.expectEqual(Equivalence.equivalent, framesEquivalent(&a, &tail_repeat));
    const tail_new = [_]u64{ 1, 1, 2, 2, 2, 3, 4 };
    try std.testing.expectEqual(Equivalence.divergent, framesEquivalent(&a, &tail_new));
}

/// argv with argv[0] already skipped: the boilerplate every frontend's arg
/// parser starts with. The allocator form (not `iterate()`) is used because
/// Windows decodes the command line from UTF-16 and needs one; `gpa` is
/// expected to be the process arena, so the caller need not free anything.
pub fn argIterator(init: std.process.Init, gpa: std.mem.Allocator) !std.process.Args.Iterator {
    var it = try init.minimal.args.iterateAllocator(gpa);
    _ = it.skip(); // program name
    return it;
}

/// Write a `--shot` capture as `<prefix>-<frame>.ppm`, already-expanded RGB.
/// Shared by the SDL GL and software paths so a write failure is reported —
/// and flushed — identically either way.
pub fn maybeShot(
    io: std.Io,
    gpa: std.mem.Allocator,
    err: *std.Io.Writer,
    prefix: []const u8,
    frame: u32,
    w: u32,
    h: u32,
    rgb: []const u8,
) !void {
    const path = try std.fmt.allocPrint(gpa, "{s}-{d:0>5}.ppm", .{ prefix, frame });
    writePpm(io, path, w, h, rgb) catch |e| {
        try err.print("shot failed: {s}\n", .{@errorName(e)});
    };
    try err.flush();
}

/// The behavioral tier's verdict machine: fed the diverging live-state
/// addresses of each compared tick, it decides whether the divergence
/// pattern is a wall-time echo or corruption.
///
/// The distinction, validated on Gradius III's own conversions: values the
/// main loop DERIVES from wall-coupled state (an animation phase computed
/// from an NMI frame counter, say) sit one taint hop past anything the
/// lag-learned mask can identify, so they leak through — but they echo the
/// lag delta and SELF-HEAL within a handful of ticks, over a small fixed
/// set of addresses. Corruption is the opposite in every axis: it persists
/// (the game trusts its state), spreads (wrong state begets wrong state),
/// or floods (a clobbered buffer diverges wholesale). Hence three limits,
/// each with real headroom over the measured echoes (worst observed: run
/// 17, 18 addresses, 1.4% of ticks).
pub const Persistence = struct {
    /// Distinct diverging addresses tolerated before spread is even a
    /// question.
    pub const max_addrs = 64;
    /// Dedup capacity past the threshold: novelty tracking needs to keep
    /// telling new addresses from seen ones after max_addrs, or a single
    /// busy burst would blind it. Exceeding THIS is spread outright.
    pub const addr_buf = 512;
    /// Ticks-with-new-addresses tolerated. This is what separates
    /// WANDERING corruption (novelty sustained across the run — each cell
    /// heals but the damage keeps finding fresh ones) from a PHASE BURST
    /// (an offload's latency shifts the poll instant through a busy
    /// transition: dozens of scratch cells differ at the sampled moment,
    /// re-converge by the next frame, and novelty stops when the
    /// transition does). Measured on the menu transition: the burst's
    /// novelty spans a handful of ticks; the classifier's own wandering
    /// test spans ninety.
    pub const max_novelty_ticks = 30;
    /// Consecutive diverging ticks tolerated before the verdict is
    /// corruption-by-persistence.
    pub const max_run = 30;
    /// Diverging ticks per thousand tolerated before the verdict is
    /// corruption-by-flood.
    pub const max_bad_per_mille = 50;

    addrs: [addr_buf]u32 = undefined,
    n_addrs: usize = 0,
    addr_overflow: bool = false,
    novelty_ticks: u32 = 0,
    ticks: u32 = 0,
    bad_ticks: u32 = 0,
    run: u32 = 0,
    worst_run: u32 = 0,
    first_bad: ?u32 = null,

    /// One compared tick: `bad` is the diverging live addresses (empty =
    /// clean). Order and duplicates don't matter.
    pub fn feed(self: *Persistence, tick: u32, bad: []const u32) void {
        self.ticks += 1;
        if (bad.len == 0) {
            self.run = 0;
            return;
        }
        self.bad_ticks += 1;
        self.run += 1;
        self.worst_run = @max(self.worst_run, self.run);
        if (self.first_bad == null) self.first_bad = tick;
        var any_new = false;
        for (bad) |a| {
            const seen = for (self.addrs[0..self.n_addrs]) |x| {
                if (x == a) break true;
            } else false;
            if (seen) continue;
            any_new = true;
            if (self.n_addrs == addr_buf) {
                self.addr_overflow = true;
                break;
            }
            self.addrs[self.n_addrs] = a;
            self.n_addrs += 1;
        }
        if (any_new) self.novelty_ticks += 1;
    }

    pub const Verdict = union(enum) {
        /// No divergence at all, or only transient bounded echoes.
        pass: enum { clean, echoes },
        /// Named so the gate's output explains itself.
        fail: enum { persistence, spread, flood },
    };

    pub fn verdict(self: *const Persistence) Verdict {
        if (self.addr_overflow) return .{ .fail = .spread };
        if (self.n_addrs > max_addrs and self.novelty_ticks > max_novelty_ticks)
            return .{ .fail = .spread };
        if (self.worst_run > max_run) return .{ .fail = .persistence };
        if (self.ticks > 0 and
            @as(u64, self.bad_ticks) * 1000 > @as(u64, self.ticks) * max_bad_per_mille)
            return .{ .fail = .flood };
        return .{ .pass = if (self.bad_ticks == 0) .clean else .echoes };
    }
};

test "persistence: clean and transient-echo runs pass" {
    var p: Persistence = .{};
    for (0..1000) |t| p.feed(@intCast(t), &.{});
    try std.testing.expectEqual(Persistence.Verdict{ .pass = .clean }, p.verdict());

    // Gradius III's measured shape: short scattered runs over 3 addresses,
    // ~1.2% of ticks (40 of 3202 in the 3600-frame capture).
    p = .{};
    for (0..1000) |t| {
        const in_echo = (t % 250) < 8;
        if (in_echo) p.feed(@intCast(t), &.{ 0x1F20, 0x1F28, 0x1F29 }) else p.feed(@intCast(t), &.{});
    }
    try std.testing.expectEqual(Persistence.Verdict{ .pass = .echoes }, p.verdict());
}

test "persistence: a divergence that never heals is corruption" {
    var p: Persistence = .{};
    for (0..100) |t| p.feed(@intCast(t), &.{});
    for (100..200) |t| p.feed(@intCast(t), &.{0x0042}); // sticks forever
    try std.testing.expectEqual(Persistence.Verdict{ .fail = .persistence }, p.verdict());
    try std.testing.expectEqual(@as(?u32, 100), p.first_bad);
}

test "persistence: spreading addresses are corruption even when transient" {
    var p: Persistence = .{};
    var t: u32 = 0;
    var a: u32 = 0x1000;
    while (t < 900) : (t += 1) {
        // A new address every bad tick, each healing immediately.
        if (t % 10 == 0) {
            p.feed(t, &.{a});
            a += 1;
        } else p.feed(t, &.{});
    }
    try std.testing.expectEqual(Persistence.Verdict{ .fail = .spread }, p.verdict());
}

test "persistence: a phase burst — many addresses, few novelty ticks — is an echo" {
    // The menu-transition shape: an offload's latency shifts the poll
    // instant through a busy transition, dozens of scratch cells differ
    // for a handful of ticks, everything re-converges, and novelty stops
    // when the transition does.
    var p: Persistence = .{};
    for (0..500) |t| p.feed(@intCast(t), &.{});
    var burst: [40]u32 = undefined;
    for (500..506) |t| {
        for (&burst, 0..) |*a, i| a.* = @intCast(0x0020 + (t - 500) * 40 + i);
        p.feed(@intCast(t), &burst);
    }
    for (506..1000) |t| p.feed(@intCast(t), &.{});
    try std.testing.expectEqual(Persistence.Verdict{ .pass = .echoes }, p.verdict());

    // The same breadth arriving as a sustained trickle stays corruption.
    p = .{};
    var a: u32 = 0x1000;
    for (0..1000) |t| {
        if (t % 10 == 0) {
            p.feed(@intCast(t), &.{a});
            a += 1;
        } else p.feed(@intCast(t), &.{});
    }
    try std.testing.expectEqual(Persistence.Verdict{ .fail = .spread }, p.verdict());
}

test "persistence: too many bad ticks are corruption even when bounded" {
    var p: Persistence = .{};
    for (0..1000) |t| {
        // 10% bad, always the same byte, runs of 5 — flood without spread.
        if (t % 50 < 5) p.feed(@intCast(t), &.{0x0042}) else p.feed(@intCast(t), &.{});
    }
    try std.testing.expectEqual(Persistence.Verdict{ .fail = .flood }, p.verdict());
}
