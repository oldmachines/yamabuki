//! Verification: the MMIO writer gate, the behavioral tier (logic-state equality at every tick), the probe and the culprit diagnosis that names the first diverging site.
//!
//! Carved out of main.zig as pure code motion; every declaration
//! here is re-exported from main.zig, which stays the root.

const core = @import("snes_core");
const profile = core.profile;
const std = @import("std");
const util = @import("util");
const root_mod = @import("../main.zig");

const Args = root_mod.Args;
const anchorMovie = root_mod.anchorMovie;
const applySidecar = root_mod.applySidecar;
const applyStartSave = root_mod.applyStartSave;
const gen_frames_default = root_mod.gen_frames_default;
const loadStateInto = root_mod.loadStateInto;
const seedConverted = root_mod.seedConverted;
/// Is `pc` inside the stock image's padding — the $FF runs where the
/// generator plants its own code (stubs, thunks, the split's handlers)?
/// A hardware write from there is the conversion's own machinery, not a
/// relocated game instruction, and the MMIO gate lets it through.
pub fn pcInPadding(stock: []const u8, pc: u24) bool {
    const bank: u32 = (pc >> 16) & 0x7F;
    const a16: u32 = pc & 0xFFFF;
    if (bank >= 0x40 or a16 < 0x8000) return false;
    const file = bank * 0x8000 + (a16 - 0x8000);
    if (file >= stock.len) return false;
    return stock[file] == 0xFF;
}

/// Do the conversion's bytes at `pc` still read as stock's instruction?
/// Four bytes cover any absolute or long store. A dual image is checked
/// in both copies: the write may have come from either, and a site the
/// generator rewrote in one copy is not stock's instruction there.
pub fn stockBytesAt(stock: []const u8, conv: []const u8, pc: u24) bool {
    const bank: u32 = (pc >> 16) & 0x7F;
    const a16: u32 = pc & 0xFFFF;
    if (bank >= 0x40 or a16 < 0x8000) return false;
    const file = bank * 0x8000 + (a16 - 0x8000);
    if (file + 4 > stock.len or file + 4 > conv.len) return false;
    if (!std.mem.eql(u8, stock[file..][0..4], conv[file..][0..4])) return false;
    // The dual image's upper copy sits at the image's half (the lower copy
    // is padded to that), not at the stock ROM's length.
    if (conv.len >= stock.len * 2) {
        const up = conv.len / 2 + file;
        if (up + 4 <= conv.len and !std.mem.eql(u8, stock[file..][0..4], conv[up..][0..4])) return false;
    }
    return true;
}

/// The MMIO gate's verdict for one surface: every (register, pc) the
/// conversion wrote that stock never wrote on ANY surface, from a site
/// whose bytes the generator changed. Two filters, both needed: the
/// union across surfaces because a run that forked (a lag-changed take)
/// reaches stock code this surface's baseline did not; the byte check
/// because such code, unrewritten, is stock's own instruction and not
/// this gate's business. What remains is a rewritten instruction that
/// lands on hardware — the shape that killed the sound driver. Returns
/// the offenders' count and prints up to eight of them.
pub fn mmioGate(out: *std.Io.Writer, stock: []const u8, conv_image: []const u8, base: []const *core.bus.Bus.MmioWriters, conv: *const core.bus.Bus.MmioWriters) !u32 {
    var n: u32 = 0;
    var it = conv.set.keyIterator();
    while (it.next()) |k| {
        const reg: u16 = @intCast(k.* >> 24);
        const pc: u24 = @intCast(k.* & 0xFF_FFFF);
        var known = false;
        for (base) |b| if (b.has(reg, pc)) {
            known = true;
        };
        if (known) continue;
        if (pcInPadding(stock, pc)) continue;
        if (stockBytesAt(stock, conv_image, pc)) continue;
        n += 1;
        if (n <= 8) {
            try out.print("  mmio gate: ${X:0>4} written from ${X:0>2}:{X:0>4} — a rewritten site stock never writes it from", .{ reg, pc >> 16, pc & 0xFFFF });
            var shown: u32 = 0;
            for (base) |b| {
                var bit = b.set.keyIterator();
                while (bit.next()) |bk| {
                    if (@as(u16, @intCast(bk.* >> 24)) != reg) continue;
                    if (shown == 0) try out.print(" (stock:", .{});
                    if (shown < 6) try out.print(" ${X:0>2}:{X:0>4}", .{ (bk.* >> 16) & 0xFF, bk.* & 0xFFFF });
                    shown += 1;
                }
            }
            if (shown > 6) try out.print(" +{}", .{shown - 6});
            if (shown > 0) try out.print(")", .{});
            try out.print("\n", .{});
        }
    }
    if (n > 8) try out.print("  mmio gate: ... {} more\n", .{n - 8});
    return n;
}

/// The `.mmio` file beside a patch: `S reg pc` lines for stock's writer
/// set over every verified surface, `C reg pc` for the conversion's.
pub fn writeMmioRef(io: std.Io, path: []const u8, stock: []const u8, base: []const *core.bus.Bus.MmioWriters, conv: []const *core.bus.Bus.MmioWriters) !void {
    var buf: std.array_list.Managed(u8) = .init(std.heap.page_allocator);
    defer buf.deinit();
    try appendPaddingLines(&buf, stock);
    var line: [32]u8 = undefined;
    for (base) |b| {
        var it = b.set.keyIterator();
        while (it.next()) |k| try buf.appendSlice(try std.fmt.bufPrint(&line, "S {X:0>4} {X:0>6}\n", .{ k.* >> 24, k.* & 0xFF_FFFF }));
    }
    for (conv) |c| {
        var it = c.set.keyIterator();
        while (it.next()) |k| try buf.appendSlice(try std.fmt.bufPrint(&line, "C {X:0>4} {X:0>6}\n", .{ k.* >> 24, k.* & 0xFF_FFFF }));
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items });
}

/// `--mmio-ref`: the pairs a generation saw (stock's and the conversion's),
/// and the stock image's padding ranges (`P start end`, file offsets) —
/// a write from padding is the generator's own code.
pub const MmioRef = struct {
    set: *core.bus.Bus.MmioWriters,
    pad: std.array_list.Managed([2]u32),
    pub fn inPadding(self: *const MmioRef, pc: u24) bool {
        const bank: u32 = (pc >> 16) & 0x7F;
        const a16: u32 = pc & 0xFFFF;
        if (bank >= 0x40 or a16 < 0x8000) return false;
        const file = bank * 0x8000 + (a16 - 0x8000);
        for (self.pad.items) |r| if (file >= r[0] and file < r[1]) return true;
        return false;
    }
};

pub fn loadMmioRef(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !MmioRef {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024));
    var ref: MmioRef = .{ .set = try core.bus.Bus.MmioWriters.create(gpa), .pad = .init(gpa) };
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.splitScalar(u8, std.mem.trim(u8, line, "\r "), ' ');
        const kind = parts.next() orelse continue;
        if (kind.len != 1) continue;
        if (kind[0] == 'P') {
            const a = std.fmt.parseInt(u32, parts.next() orelse continue, 16) catch continue;
            const b = std.fmt.parseInt(u32, parts.next() orelse continue, 16) catch continue;
            try ref.pad.append(.{ a, b });
            continue;
        }
        const reg = std.fmt.parseInt(u16, parts.next() orelse continue, 16) catch continue;
        const pc = std.fmt.parseInt(u24, parts.next() orelse continue, 16) catch continue;
        ref.set.set.put(gpa, core.bus.Bus.MmioWriters.key(reg, pc), {}) catch {};
    }
    return ref;
}

/// The stock image's padding as `P start end` lines: runs of $FF at least
/// 16 bytes long, the places the generator plants code.
pub fn appendPaddingLines(buf: *std.array_list.Managed(u8), stock: []const u8) !void {
    var line: [32]u8 = undefined;
    var i: usize = 0;
    while (i < stock.len) {
        if (stock[i] != 0xFF) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < stock.len and stock[j] == 0xFF) j += 1;
        if (j - i >= 16) try buf.appendSlice(try std.fmt.bufPrint(&line, "P {X:0>6} {X:0>6}\n", .{ i, j }));
        i = j;
    }
}

/// The split's mode cell as this machine holds it: WRAM on stock, the
/// BW-RAM window (the relocated home) on a conversion with an SA-1.
pub fn modeCell(con: *core.FastConsole, cell: u16) u8 {
    if (con.bus.sa1.bwram_mask != 0) return con.bus.sa1.bwram[cell & con.bus.sa1.bwram_mask];
    return con.bus.wram.data[cell];
}

/// One frame of a behavioral replay: clear the poll flags, run, drain.
/// Returns true when the frame completed a logic tick (the snapshot is
/// filled and `snap.live` holds the interval's consumption since the
/// caller last cleared it).
pub fn stepBehavioralFrame(con: *core.FastConsole, snap: *core.bus.Bus.TickSnap, feed: *util.movie.Feed, frame: u32) bool {
    // The feed consumes the poll latch first: the harness's own clear below
    // is for the tick snapshot, and must not eat the feed's signal.
    feed.step(con, frame);
    con.bus.input_polled = false;
    snap.captured = false;
    con.runFrame();
    var drain: [4096]i16 = undefined;
    while (con.readAudio(&drain) != 0) {}
    return snap.captured;
}

/// Learn the wall-coupled byte mask from the baseline: bytes that change
/// across a LAG frame (a short no-poll blip amid live gameplay) were
/// written by the NMI side. Long no-poll runs are loads and transitions,
/// where the game legitimately rewrites great swaths of WRAM — learning
/// from them buries real corruption inside the mask (a 23%-of-WRAM blind
/// spot on Gradius III; short-run learning masks ~500 bytes).
pub fn learnWallMask(gpa: std.mem.Allocator, image: []const u8, mov: ?util.movie.Movie, state: ?[]const u8, total: u32) ![]u8 {
    const wram_len = core.bus.Bus.TickSnap.wram_len;
    const lag_run_max = 3;
    const cart = try core.Cartridge.load(gpa, image);
    const con = try gpa.create(core.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    applySidecar(con, mov);
    // Anchored runs learn the mask from the anchored scene — a mask
    // learned at the attract demo says nothing about a gameplay stage's
    // wall-coupled bytes.
    if (state) |sb| try con.loadState(sb);
    const snap = try gpa.create(core.bus.Bus.TickSnap);
    defer gpa.destroy(snap);
    snap.* = .{};
    @memset(&snap.live, 0);
    @memset(&snap.written, 0);
    @memset(&snap.multi, 0);
    con.bus.tick_snap = snap;

    const mask = try gpa.alloc(u8, wram_len);
    @memset(mask, 0);
    const prev = try gpa.alloc(u8, wram_len);
    defer gpa.free(prev);
    const lagbuf = try gpa.alloc(u8, wram_len * lag_run_max);
    defer gpa.free(lagbuf);
    @memcpy(prev, &con.bus.wram.data);

    var ticks: u32 = 0;
    var lag_run: u32 = 0;
    var feed: util.movie.Feed = .init(mov);
    for (0..total) |i| {
        if (root_mod.dbg_ref_overclock > 1 and i >= 300) {
            const v = modeCell(con, root_mod.dbg_ref_oc_cell);
            con.bus.overclock = if (root_mod.dbg_ref_oc_cell != 0 and v >= root_mod.dbg_ref_oc_lo and v <= root_mod.dbg_ref_oc_hi) root_mod.dbg_ref_overclock else 1;
            con.bus.sa1.overclock = con.bus.overclock;
        }
        if (stepBehavioralFrame(con, snap, &feed, @intCast(i))) {
            if (lag_run > 0 and lag_run <= lag_run_max and ticks > 0) {
                for (0..lag_run) |r| {
                    const before = if (r == 0) prev else lagbuf[(r - 1) * wram_len ..];
                    const after = lagbuf[r * wram_len ..];
                    for (0..wram_len) |x| {
                        if (before[x] != after[x]) mask[x] = 1;
                    }
                }
            }
            lag_run = 0;
            ticks += 1;
            @memcpy(prev, &con.bus.wram.data);
        } else {
            if (lag_run < lag_run_max)
                @memcpy(lagbuf[lag_run * wram_len ..][0..wram_len], &con.bus.wram.data);
            lag_run += 1;
        }
    }
    return mask;
}

/// Where a logical WRAM byte lives in the CONVERTED image: unmoved bytes in
/// WRAM, relocated regions wherever the plan put them — but only regions
/// that actually moved (`region_sites` > 0; a "clean" region with zero
/// re-pointed sites moved vacuously and WRAM stays canonical).
pub const ConvHome = union(enum) { wram, sram: u32, iram: u32 };

pub fn convHome(plan: *const profile.Plan, res: *const core.sa1gen.Result, i: u32) ConvHome {
    for (plan.regions[0..plan.n], 0..) |r, ri| {
        if (res.fate[ri] != .clean or res.region_sites[ri] == 0) continue;
        if (i < r.start or i >= r.start + r.len) continue;
        return switch (r.dest) {
            .iram => .{ .iram = r.dest_off + (i - r.start) },
            .bwram => .{ .sram = r.dest_off + (i - r.start) },
        };
    }
    return .wram;
}

/// Frames a side may go without polling input before the tier calls it
/// stopped rather than merely out of budget. Five seconds: long enough
/// that a load, a scene transition or a fade cannot trip it, short enough
/// that a real wedge cannot hide under it.
pub const hang_frames: u32 = 300;

pub const Behavioral = struct {
    verdict: util.Persistence.Verdict,
    stats: util.Persistence,
    ticks_base: u32,
    ticks_conv: u32,
    /// Baseline wall frame of the first diverging tick (forensics anchor).
    first_bad_frame: u32,
    /// Sample of diverging addresses for the report.
    sample: [24]u32,
    n_sample: usize,
    /// Set when a persistence failure carries the RNG-FORK signature: the
    /// killer run was still open at surface end, the conversion never
    /// stopped ticking, and the fork sits in the surface's second half.
    /// Holds the baseline wall frame where the run began — the horizon a
    /// retry can verify up to (beyond it, tick-locked replay compares two
    /// different healthy games and proves nothing either way).
    fork_wall: ?u32,
    /// HOW the tick-locked pairing ended. A `persistence` verdict has two
    /// completely different causes wearing one message — live state that
    /// diverged and never healed, and a run that simply stopped pairing —
    /// and telling them apart by eye is impossible: a surface with SEVEN
    /// diverging ticks out of 1259 and a worst run of 4 was reported as
    /// "live state diverges and never heals" for a whole day.
    exit: Exit = .compared_to_budget,

    pub const Exit = enum {
        /// The baseline ran out of budget first. Normal for a conversion
        /// that removed slowdown: it needs fewer wall frames per tick.
        compared_to_budget,
        /// Neither side ever produced a tick.
        no_ticks,
        /// The CONVERSION ran out of budget while the baseline still had
        /// ticks to give — after the epoch resync had advanced it alone.
        /// The end of the comparable region, not a failure.
        conversion_ran_out,
        /// The conversion went `hang_frames` without polling input while
        /// the baseline kept ticking. This one IS a failure.
        conversion_hung,
        /// The conversion ran out while being caught up to an input edge
        /// the baseline had already crossed. NOT a failure — see the
        /// comment at the break — but disclosed, because the surface's
        /// tail went uncompared.
        conversion_ran_out_at_edge,

        pub fn describe(self: Exit) []const u8 {
            return switch (self) {
                .compared_to_budget => "baseline exhausted its budget (normal)",
                .no_ticks => "neither side produced a logic tick",
                .conversion_ran_out => "comparable region ended (the conversion, pushed ahead by epoch resyncs, exhausted its budget)",
                .conversion_hung => "the CONVERSION STOPPED POLLING while the baseline kept ticking",
                .conversion_ran_out_at_edge => "comparable region ended at an input edge (the conversion, being ahead, ran out of budget catching up)",
            };
        }
    };
};

/// The behavioral tier (`--verify-behavioral`): a conversion that removes
/// slowdown CANNOT be frame-identical to a slowed-down baseline — different
/// lag means different pictures, and the pixel gate rightly calls that
/// divergent. What lag cannot legitimately change is the game's LOGIC
/// state at each logic tick. So: run both images tick-locked (a tick = the
/// frame's first controller poll, the one phase-aligned moment two runs
/// with different lag share), and at every tick compare the bytes the
/// baseline's NEXT tick actually consumes (read-before-write liveness —
/// dead residue and stack slime never qualify), each read from wherever
/// the conversion relocated it, excluding the lag-learned wall-coupled
/// mask. Wall-DERIVED values leak through all of that (one taint hop past
/// the mask), so the verdict keys on persistence: echoes self-heal within
/// ticks over a bounded address set; corruption persists, spreads, or
/// floods.
///
/// Movie input breaks pure tick-locking: a button edge lands at a WALL
/// frame, and a run with less lag has executed MORE logic passes by then —
/// each run consumes the edge at a different tick index, and from there a
/// global pairing compares two different moments of the same correct game
/// (measured on Gradius III's menu: 79 ticks of menu-vs-attract, then
/// menu timers phase-offset forever). So the pairing realigns per input
/// EPOCH: when one run's tick stream crosses an edge before the other's,
/// the laggard advances alone — its surplus ticks have no counterpart and
/// go uncompared — and the pairing re-anchors at both runs' first tick of
/// the new epoch. The state carried ACROSS an edge from wall-time origins
/// (pass counters, timers seeded from them) stays offset by exactly the
/// passes the speedup bought; the persistence verdict excuses precisely
/// that shape — a held constant offset — and nothing else.
pub fn verifyBehavioral(
    gpa: std.mem.Allocator,
    base_image: []const u8,
    conv_image: []const u8,
    plan: *const profile.Plan,
    res: *const core.sa1gen.Result,
    mov: ?util.movie.Movie,
    state: ?[]const u8,
    /// Uniform window image: every WRAM byte's home is BW-RAM at the
    /// identity offset (`plan`/`res` are not consulted — the whole-game
    /// pipeline never builds a plan).
    window: bool,
    total: u32,
) !Behavioral {
    const wram_len = core.bus.Bus.TickSnap.wram_len;
    const mask = try learnWallMask(gpa, base_image, mov, state, total);
    defer gpa.free(mask);

    // The movie's input edges: wall frames where a pad mask changes. Each
    // edge starts a new pairing epoch (see the doc comment above).
    const edges: []const u32 = blk: {
        var list: std.array_list.Managed(u32) = .init(gpa);
        if (mov) |m| {
            var prev_mask: [2]u16 = .{ 0, 0 };
            for (m.frames, 0..) |f, i| {
                if (f[0] != prev_mask[0] or f[1] != prev_mask[1]) {
                    try list.append(@intCast(i));
                    prev_mask = f;
                }
            }
        }
        break :blk try list.toOwnedSlice();
    };
    defer gpa.free(edges);

    const Side = struct {
        con: *core.FastConsole,
        snap: *core.bus.Bus.TickSnap,
        prev: *core.bus.Bus.TickSnap,
        /// The take's input feed; a per-poll take advances per tick.
        feed: util.movie.Feed = .{ .mov = null },
        frame: u32 = 0,
        /// Wall frame of the current (last returned) tick.
        tick_wall: u32 = 0,
        /// Boot-pad displacement: this side's game timeline runs this many
        /// wall frames behind the movie's recording, so its inputs (and
        /// its input-edge epochs) shift to follow.
        pad: u32 = 0,
        /// Frames the last `advance` call consumed. A failed call that
        /// burned only a handful of them ran out of BUDGET; one that
        /// burned hundreds without a poll actually stopped ticking. The
        /// return value alone cannot tell those apart, and conflating
        /// them is what made the tier reject faster builds.
        span: u32 = 0,
        /// The reference overclock, engaged once the boot is behind (an
        /// overclocked S-CPU breaks the APU upload's handshake timing).
        oc: u8 = 1,
        /// ... and only while the mode cell holds a value in the split's
        /// gate range: the eras the SA-1 runs. Elsewhere the reference keeps
        /// real timing (an overclocked intro wedges on its own delay loops).
        oc_cell: u16 = 0,
        oc_lo: u8 = 0,
        oc_hi: u8 = 0,

        pub fn init(al: std.mem.Allocator, image: []const u8, m: ?util.movie.Movie) !@This() {
            const cart = try core.Cartridge.load(al, image);
            const con = try al.create(core.FastConsole);
            con.init(cart);
            applySidecar(con, m);
            const snap = try al.create(core.bus.Bus.TickSnap);
            snap.* = .{};
            @memset(&snap.live, 0);
            @memset(&snap.written, 0);
            @memset(&snap.multi, 0);
            con.bus.tick_snap = snap;
            return .{ .con = con, .snap = snap, .prev = try al.create(core.bus.Bus.TickSnap) };
        }

        pub fn advance(self: *@This(), m: ?util.movie.Movie, budget: u32) bool {
            if (self.feed.mov == null) self.feed = .init(m);
            const from = self.frame;
            while (self.frame < budget) {
                if (self.oc > 1 and self.frame >= 300) {
                    const v = modeCell(self.con, self.oc_cell);
                    self.con.bus.overclock = if (self.oc_cell != 0 and v >= self.oc_lo and v <= self.oc_hi) self.oc else 1;
                    self.con.bus.sa1.overclock = self.con.bus.overclock;
                }
                const ticked = stepBehavioralFrame(self.con, self.snap, &self.feed, self.frame -| self.pad);
                self.frame += 1;
                if (ticked) {
                    self.tick_wall = self.frame - 1;
                    self.span = self.frame - from;
                    return true;
                }
            }
            self.span = self.frame - from;
            return false;
        }

        /// Which input epoch this side's current tick sits in: the number
        /// of edges its tick stream has sampled.
        pub fn epoch(self: *const @This(), es: []const u32) usize {
            var n: usize = 0;
            while (n < es.len and es[n] <= self.tick_wall -| self.pad) n += 1;
            return n;
        }
    };

    var base = try Side.init(gpa, base_image, mov);
    var conv = try Side.init(gpa, conv_image, mov);
    conv.pad = root_mod.dbg_conv_pad;
    base.oc = root_mod.dbg_ref_overclock;
    base.oc_cell = root_mod.dbg_ref_oc_cell;
    base.oc_lo = root_mod.dbg_ref_oc_lo;
    base.oc_hi = root_mod.dbg_ref_oc_hi;
    conv.oc = root_mod.dbg_conv_overclock;
    conv.oc_cell = root_mod.dbg_ref_oc_cell;
    conv.oc_lo = root_mod.dbg_ref_oc_lo;
    conv.oc_hi = root_mod.dbg_ref_oc_hi;
    if (state) |sb| {
        try base.con.loadState(sb);
        try seedConverted(conv.con, sb, plan, res);
    }

    var out: Behavioral = .{
        .verdict = .{ .pass = .clean },
        .stats = .{ .epoch_budget = @intCast(edges.len + 1) },
        .ticks_base = 0,
        .ticks_conv = 0,
        .first_bad_frame = 0,
        .sample = @splat(0),
        .n_sample = 0,
        .fork_wall = null,
    };
    // Baseline wall frame of each FED tick, indexed like the tick indices
    // handed to Persistence.feed — what maps a verdict's tick back to a
    // wall frame (the fork-horizon retry needs the killer run's start).
    var tick_walls = try gpa.alloc(u32, total + 1);
    defer gpa.free(tick_walls);
    var n_tick_walls: usize = 0;

    // Tick 0 on both sides.
    if (!base.advance(mov, total)) {
        out.exit = .no_ticks;
        return out; // vacuous
    }
    if (!conv.advance(mov, total)) {
        // The baseline reached gameplay and the conversion never did.
        out.verdict = .{ .fail = .persistence };
        out.exit = .conversion_hung;
        return out;
    }
    out.ticks_base = 1;
    out.ticks_conv = 1;
    base.prev.* = base.snap.*;
    conv.prev.* = conv.snap.*;
    @memset(&base.snap.live, 0);
    @memset(&base.snap.written, 0);
    @memset(&base.snap.multi, 0);
    var prev_frame: u32 = base.frame;

    // Intra-frame stream detection: a byte the BASELINE writes more than
    // once inside one tick interval is mid-stream at every snapshot
    // instant (an APU pump's cursor, its data buffers, a handshake cell)
    // — its value at the poll is phase, not logic, and a timing-shifted
    // conversion can never match it at the same tick. A cell that
    // streams in eight intervals joins the wall mask by CONSTRUCTION —
    // previously this class was absorbed only when a surface's
    // lag-learned mask happened to cover it, which is why one surface
    // passed and another failed on identical input.
    const stream_ticks = try gpa.alloc(u8, wram_len);
    defer gpa.free(stream_ticks);
    @memset(stream_ticks, 0);

    // Which home each WRAM cell actually lives in on the conversion,
    // learned from the ticks where it AGREED with the baseline (0 unknown,
    // 1 BW-RAM, 2 real WRAM). A window image splits homes by access idiom
    // — low 8K and $7E-long cells live in BW-RAM, abs-addressed high WRAM
    // stays put — and a divergence must be measured at the LIVE home: the
    // stale other home is dead boot residue, and a delta against dead
    // zeros drifts as the baseline moves, faking active divergence out of
    // a held offset.
    const home = try gpa.alloc(u8, wram_len);
    defer gpa.free(home);
    @memset(home, 0);

    var bad: [util.Persistence.max_addrs + 1]util.Persistence.Bad = undefined;
    var prev_n_bad: usize = 0;
    // The lag differential at the previous tick pair: how many more wall
    // frames the baseline has spent than the conversion to reach the same
    // logic tick. Wall-coupled state (NMI counters, anything seeded from
    // them) drifts by exactly this, so persistence accounting is only
    // meaningful on ticks where it HELD STILL — a slowdown-removing
    // conversion legitimately walks it up through every stretch whose
    // frames it stopped dropping (measured: 79 frames across a load).
    var ld_prev: i64 = @as(i64, base.tick_wall) - (@as(i64, conv.tick_wall) - @as(i64, conv.pad));
    outer: while (true) {
        const pair_ld: i64 = @as(i64, base.tick_wall) - (@as(i64, conv.tick_wall) - @as(i64, conv.pad));
        const wall_stable = pair_ld == ld_prev;
        ld_prev = pair_ld;
        if (!base.advance(mov, total)) break;
        out.ticks_base += 1;
        if (!conv.advance(mov, total)) {
            // Ran out of budget, or hung — and only the SPAN tells them
            // apart. The epoch resync below advances the conversion
            // alone, so a faster conversion's frame counter is routinely
            // pushed past the baseline's; it then exhausts the budget
            // here having polled input a frame ago. That is the end of
            // the comparable region. A conversion that truly stopped
            // burns `hang_frames` without a single poll.
            if (conv.span < hang_frames) {
                out.exit = .conversion_ran_out;
                break;
            }
            // A long no-poll SPAN is only a hang while input remains. A
            // conversion that has consumed every input edge is simply
            // AHEAD — it finished the movie's logic early (the removed
            // slowdown, i.e. the point of the patch) and now sits in
            // whatever no-poll state the story ends in (a load, a fade)
            // while the baseline still chews through its lag.
            if (conv.epoch(edges) >= edges.len) {
                out.exit = .conversion_ran_out;
                break;
            }
            out.verdict = .{ .fail = .persistence };
            out.exit = .conversion_hung;
            return out;
        }
        out.ticks_conv += 1;

        // Epoch resync: an input edge reaches each run at its own tick
        // index. When one side has crossed an edge the other hasn't, the
        // pairing is between different epochs — advance the laggard alone
        // (its surplus ticks have no counterpart) and re-anchor at both
        // sides' first tick of the new epoch, comparing from there.
        if (base.epoch(edges) != conv.epoch(edges)) {
            while (base.epoch(edges) != conv.epoch(edges)) {
                if (base.epoch(edges) > conv.epoch(edges)) {
                    if (!conv.advance(mov, total)) {
                        // NOT a hang, and calling it one was costing real
                        // builds. The conversion is AHEAD — it spends
                        // fewer wall frames per logic tick, which is the
                        // entire point — so it sits at an earlier wall
                        // frame than the baseline, and catching it up to
                        // the baseline's epoch burns whatever budget it
                        // has left. Near the end of a surface it runs out.
                        // That is the end of the COMPARABLE REGION, not a
                        // failure: everything paired so far was paired
                        // honestly, and the verdict belongs to those
                        // ticks. (The genuine hang is the other exit —
                        // the conversion stopping while the baseline
                        // still ticks, in the main pairing above.)
                        //
                        // Measured: a surface with SEVEN diverging ticks
                        // out of 1259 and a worst run of 4 was reported
                        // as "live state diverges and never heals", and
                        // whether a build hit this depended on where the
                        // last input edge fell relative to its own lag
                        // differential — so any timing change (FastROM, a
                        // tree, a thunk) could flip a verdict without
                        // touching correctness.
                        if (conv.span >= hang_frames and conv.epoch(edges) < edges.len) {
                            out.verdict = .{ .fail = .persistence };
                            out.exit = .conversion_hung;
                            return out;
                        }
                        out.exit = .conversion_ran_out_at_edge;
                        break :outer;
                    }
                    out.ticks_conv += 1;
                } else {
                    if (!base.advance(mov, total)) break :outer;
                    out.ticks_base += 1;
                }
            }
            base.prev.* = base.snap.*;
            conv.prev.* = conv.snap.*;
            @memset(&base.snap.live, 0);
            @memset(&base.snap.written, 0);
            @memset(&base.snap.multi, 0);
            prev_frame = base.frame;
            // Re-anchor the lag differential too: the laggard's surplus
            // ticks moved one side's wall alone.
            ld_prev = @as(i64, base.tick_wall) - (@as(i64, conv.tick_wall) - @as(i64, conv.pad));
            continue;
        }

        // Streams first: cells the baseline multi-wrote this interval.
        for (0..wram_len / 8) |bi| {
            var mm = base.snap.multi[bi];
            while (mm != 0) {
                const bit: u3 = @intCast(@ctz(mm));
                mm &= mm - 1;
                const i = bi * 8 + @as(usize, bit);
                if (stream_ticks[i] < 8) {
                    stream_ticks[i] += 1;
                    if (stream_ticks[i] == 8) mask[i] = 1;
                }
            }
        }

        // Compare the PREVIOUS tick pair on the bytes this baseline
        // interval consumed.
        var n_bad: usize = 0;
        const live = &base.snap.live;
        for (0..wram_len) |i| {
            if (live[i >> 3] & (@as(u8, 1) << @intCast(i & 7)) == 0) continue;
            if (mask[i] != 0) continue;
            const bb = base.prev.wram[i];
            const cb = if (window) blk: {
                // A window image moves every code-path WRAM reference to
                // BW-RAM at the identity offset — but WMDATA-port traffic
                // still lands in real WRAM, and nothing records which
                // path wrote a given byte last. A byte matching EITHER
                // home passes; matching neither is a real divergence.
                // One more equivalence: the relocation maps WRAM bank
                // VALUES, so data holding $7E/$7F (a pointer's bank byte)
                // legitimately holds $40/$41 in the image — permanently,
                // which the persistence verdict would otherwise read as
                // immortal corruption.
                const via_bw = conv.prev.sram[i];
                const via_wram = conv.prev.wram[i];
                // The home is learned ONCE, from a discriminating equality
                // (the homes disagree and the baseline matches exactly
                // one), and then sticks: a dead home's zero coincidentally
                // matching a transiting baseline value must not re-teach
                // the cell's address (measured: stock's $3A wrapping
                // through 00 matched the stale WRAM zero and every later
                // delta drifted again).
                if (bb == via_bw or (bb == 0x7E and via_bw == 0x40) or (bb == 0x7F and via_bw == 0x41)) {
                    if (home[i] == 0 and via_bw != via_wram) home[i] = 1;
                    break :blk bb;
                }
                if (bb == via_wram or (bb == 0x7E and via_wram == 0x40) or (bb == 0x7F and via_wram == 0x41)) {
                    if (home[i] == 0 and via_bw != via_wram) home[i] = 2;
                    break :blk bb;
                }
                // Diverged at both homes: report the live home's value so
                // the persistence delta tracks what the game computes.
                break :blk switch (home[i]) {
                    1 => via_bw,
                    2 => via_wram,
                    else => if (i < 0x2000) via_bw else via_wram,
                };
            } else switch (convHome(plan, res, @intCast(i))) {
                .wram => conv.prev.wram[i],
                .sram => |off| conv.prev.sram[off],
                .iram => |off| conv.prev.iram[off & 0x7FF],
            };
            if (bb == cb) continue;
            if (n_bad < bad.len) {
                bad[n_bad] = .{ .addr = @intCast(i), .delta = bb -% cb };
                n_bad += 1;
            }
        }
        if (n_bad > 0 and out.stats.first_bad == null) {
            out.first_bad_frame = prev_frame;
            out.n_sample = @min(out.sample.len, n_bad);
            for (out.sample[0..out.n_sample], bad[0..out.n_sample]) |*s, b| s.* = b.addr | (@as(u32, b.delta) << 16);
        }
        // Forensics on stderr: each bad-run START with both machines' wall
        // frames and cell values — the tick<->wall mapping is nonlinear
        // (loads stretch hundreds of wall frames per tick) and chasing a
        // tick-domain divergence with wall-domain probes wastes hours.
        if (n_bad > 0 and (prev_n_bad == 0 or out.ticks_base % 50 == 0)) {
            std.debug.print("[bfx] run start tick={} base_wall={} conv_wall={} n_bad={}:", .{ out.ticks_base, base.frame, conv.frame, n_bad });
            for (bad[0..@min(8, n_bad)]) |b| {
                const cv = b.addr; // conv value recomputed below for the print
                _ = cv;
                std.debug.print(" ${X:0>4}(d{X:0>2})", .{ b.addr, b.delta });
            }
            std.debug.print("\n", .{});
        }
        prev_n_bad = n_bad;
        if (out.ticks_base - 2 < tick_walls.len) {
            tick_walls[out.ticks_base - 2] = prev_frame;
            n_tick_walls = @max(n_tick_walls, out.ticks_base - 1);
        }
        out.stats.feed(out.ticks_base - 2, bad[0..n_bad], wall_stable);

        base.prev.* = base.snap.*;
        conv.prev.* = conv.snap.*;
        @memset(&base.snap.live, 0);
        @memset(&base.snap.written, 0);
        @memset(&base.snap.multi, 0);
        prev_frame = base.frame;
    }

    out.verdict = out.stats.verdict();
    // The RNG-fork signature: a persistence failure whose killer run was
    // still open at surface end, on a conversion that kept ticking, with
    // the fork in the surface's second half. Report the wall frame where
    // the run began so the caller can verify up to the horizon.
    // (A conversion that stopped ticking never reaches this analysis —
    // those verdicts return early from the advance failures above.)
    // The FORK-EPISODE shape: a timing-changed conversion forks the game
    // at each RNG-sensitive moment (a demo, a transition whose sound
    // phase shifted); each episode that HEALS was reconverged by a scene
    // reset — corruption does not reconverge to byte-equivalence. A small
    // number of bounded episodes qualifies for the prefix-retry excusal
    // when everything OUTSIDE them held: few episodes, a substantial
    // verified prefix before the first, the excused fraction small, and
    // the off-episode surface within the flood budget.
    if (out.verdict == .fail and out.verdict.fail == .persistence and
        out.stats.long_runs <= 4 and
        out.stats.long_total * 4 <= out.stats.stable_ticks and
        (@as(u64, out.stats.bad_ticks - out.stats.long_total - out.stats.burst_total) * 1000 <=
            @as(u64, out.stats.stable_ticks) * util.Persistence.max_bad_per_mille * 3) and
        out.stats.first_long_start != null and
        out.stats.first_long_start.? > 600 and
        out.stats.first_long_start.? < n_tick_walls)
    {
        out.fork_wall = tick_walls[out.stats.first_long_start.?];
    }
    return out;
}

/// `--tick-dump`: one record per logic tick — u32 wall frame (little-endian)
/// followed by the phase-aligned snapshot the bus captured at that tick's
/// controller poll: 128 KiB WRAM, 128 KiB cartridge RAM (BW-RAM), 2 KiB SA-1
/// I-RAM — the relocated homes too, because a conversion moves state and a
/// WRAM-only view is blind exactly where a broken offload does its damage. The offline analysis behind the behavioral
/// verifier's design; not part of any verification path itself.
pub fn runTickDump(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    args: Args,
    cart: core.Cartridge,
    mov: ?util.movie.Movie,
    path: []const u8,
) !void {
    const con = try gpa.create(core.FastConsole);
    con.init(cart);
    if (args.auto_fastrom) con.bus.enableAutoFastrom();
    if (args.state) |spath| try loadStateInto(io, gpa, out, con, spath);
    try applyStartSave(io, gpa, con, args, mov, out);
    try anchorMovie(con, mov, "movie", out);

    const snap = try gpa.create(core.bus.Bus.TickSnap);
    snap.* = .{};
    @memset(&snap.live, 0);
    @memset(&snap.written, 0);
    @memset(&snap.multi, 0);
    con.bus.tick_snap = snap;

    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch {
        try out.print("error: cannot create '{s}'\n", .{path});
        try out.flush();
        std.process.exit(1);
    };
    defer file.close(io);
    var fbuf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &fbuf);

    // Lag-frame mask: bytes that change across a LAG frame were written by
    // the NMI side (or by the main loop's stalled mid-computation) — the
    // candidate set for "legitimately wall-coupled". Lag means genuine
    // slowdown: a SHORT no-poll blip amid live gameplay. Long no-poll runs
    // are loads and transitions, where the game legitimately rewrites great
    // swaths of WRAM — learning from those buries real corruption inside
    // the mask (a 23% blind spot on Gradius III), so runs longer than
    // `lag_run_max` teach nothing.
    const lag_run_max = 3;
    const prev = try gpa.alloc(u8, core.bus.Bus.TickSnap.wram_len);
    const lagbuf = try gpa.alloc(u8, core.bus.Bus.TickSnap.wram_len * lag_run_max);
    const mask = try gpa.alloc(u8, core.bus.Bus.TickSnap.wram_len);
    @memset(mask, 0);
    @memcpy(prev, &con.bus.wram.data);

    const frames = args.frames orelse 600;
    var ticks: u32 = 0;
    var lag_run: u32 = 0;
    var drain: [4096]i16 = undefined;
    var feed: util.movie.Feed = .init(mov);
    for (0..frames) |i| {
        feed.step(con, i);
        con.bus.input_polled = false;
        snap.captured = false;
        con.runFrame();
        while (con.readAudio(&drain) != 0) {}
        if (snap.captured) {
            var hdr: [4]u8 = undefined;
            std.mem.writeInt(u32, &hdr, @intCast(i), .little);
            try fw.interface.writeAll(&hdr);
            // The liveness accumulated since the LAST poll: which bytes of
            // the previous tick's state this interval actually consumed.
            try fw.interface.writeAll(&snap.live);
            try fw.interface.writeAll(&snap.wram);
            try fw.interface.writeAll(&snap.sram);
            try fw.interface.writeAll(&snap.iram);
            @memset(&snap.live, 0);
            @memset(&snap.written, 0);
            @memset(&snap.multi, 0);
            ticks += 1;
            // The no-poll run just ended: it was lag (not a load) only if
            // it stayed short, and only then does it teach the mask.
            if (lag_run > 0 and lag_run <= lag_run_max and ticks > 1) {
                for (0..lag_run) |r| {
                    const before = if (r == 0) prev else lagbuf[(r - 1) * core.bus.Bus.TickSnap.wram_len ..];
                    const after = lagbuf[r * core.bus.Bus.TickSnap.wram_len ..];
                    for (0..core.bus.Bus.TickSnap.wram_len) |x| {
                        if (before[x] != after[x]) mask[x] = 1;
                    }
                }
            }
            lag_run = 0;
            @memcpy(prev, &con.bus.wram.data);
        } else {
            if (lag_run < lag_run_max)
                @memcpy(lagbuf[lag_run * core.bus.Bus.TickSnap.wram_len ..][0..core.bus.Bus.TickSnap.wram_len], &con.bus.wram.data);
            lag_run += 1;
        }
    }
    // The mask rides at the tail: 128 KiB of 0/1 after the tick records.
    try fw.interface.writeAll(mask);
    try fw.interface.flush();
    var masked: u32 = 0;
    for (mask) |m| masked += m;
    try out.print("{s}: {} ticks in {} frames, {} lag-touched bytes -> {s}\n", .{ args.rom, ticks, frames, masked, path });
    try out.flush();
}

/// Which S4 tier a successful SA-1 conversion verified under.
pub const SaTier = enum { strict, envelope, equivalent, behavioral };

/// Surface `s`'s movie — null for the legacy no-movie (attract) surface.
pub fn movAt(movs: []const util.movie.Movie, s: usize) ?util.movie.Movie {
    return if (movs.len == 0) null else movs[s];
}

/// `--behavioral-probe` (undocumented): the behavioral tier alone, stock
/// baseline vs a saved rung image, full verdict accounting printed —
/// iterating the tier's rules in minutes instead of ladder-hours.
pub fn runBehavioralProbe(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    args: Args,
    base_image: []const u8,
    conv_path: []const u8,
    movs: []const util.movie.Movie,
) !void {
    const conv_raw = std.Io.Dir.cwd().readFileAlloc(io, conv_path, gpa, .limited(16 * 1024 * 1024)) catch {
        try out.print("error: cannot read '{s}'\n", .{conv_path});
        try out.flush();
        std.process.exit(1);
    };
    const conv_image = core.header.stripCopierHeader(conv_raw);
    var plan: profile.Plan = .{};
    var res: core.sa1gen.Result = .{ .image = @constCast(conv_image), .stats = .{}, .fate = @splat(.not_attempted) };
    const n = @max(1, movs.len);
    for (0..n) |s| {
        const m = movAt(movs, s);
        const frames = args.frames orelse if (m) |mm|
            @max(1, @as(u32, @intCast(mm.frames.len)) -| args.skip)
        else
            gen_frames_default;
        const total = args.skip + frames;
        const bv = try verifyBehavioral(gpa, base_image, conv_image, &plan, &res, m, null, true, total);
        const verdict_name: []const u8 = switch (bv.verdict) {
            .pass => |k| if (k == .clean) "PASS clean" else "PASS echoes",
            .fail => |w| switch (w) {
                .persistence => "FAIL persistence",
                .spread => "FAIL spread",
                .flood => "FAIL flood",
            },
        };
        try out.print(
            "surface {}: {s} — ticks {} ({} wall-stable, {} skew-active), bad {}, addrs {} ({} stable-active), novelty {}, worst_run {} (from tick {}), held {}, overflow {}, epochs {}, first_bad_frame {}\n",
            .{
                s + 1,                  verdict_name,               bv.ticks_base,
                bv.stats.stable_ticks,  bv.stats.skew_active_ticks, bv.stats.bad_ticks,
                bv.stats.n_addrs,       bv.stats.stableAddrCount(), bv.stats.novelty_ticks,
                bv.stats.worst_run,     bv.stats.worst_start,       bv.stats.heldCount(),
                bv.stats.addr_overflow, bv.stats.epoch_budget,      bv.first_bad_frame,
            },
        );
        try out.print("  runs: worst {} [{}..{}], runner-up {}, last_tick {}, reaches_end {}, burst_ticks {} (runs <= {}), long {} ({} ticks)\n", .{
            bv.stats.worst_run, bv.stats.worst_start,     bv.stats.worst_end,   bv.stats.second_run,
            bv.stats.last_tick, bv.stats.runReachesEnd(), bv.stats.burst_total, util.Persistence.burst_len,
            bv.stats.long_runs, bv.stats.long_total,
        });
        if (bv.n_sample > 0) {
            try out.print("  first-bad sample:", .{});
            for (bv.sample[0..bv.n_sample]) |adr| try out.print(" ${X:0>4}(d{X:0>2})", .{ adr & 0xFFFF, (adr >> 16) & 0xFF });
            try out.print("\n", .{});
        }
        if (bv.fork_wall) |fw| if (fw > 600 and fw + 120 < total) {
            try out.print("  RNG-fork signature (open terminal run) — probing up to the horizon at wall {}...\n", .{fw});
            try out.flush();
            const bv2 = try verifyBehavioral(gpa, base_image, conv_image, &plan, &res, m, null, true, fw);
            try out.print("  pre-horizon: {s} — ticks {}, bad {}, worst_run {}\n", .{
                switch (bv2.verdict) {
                    .pass => |k| if (k == .clean) @as([]const u8, "PASS clean") else "PASS echoes",
                    .fail => "FAIL",
                },
                bv2.ticks_base,
                bv2.stats.bad_ticks,
                bv2.stats.worst_run,
            });
        };
        try out.flush();
    }
}

/// The behavioral tier for one surface: returns `.behavioral` on pass,
/// null on fail with `fail_why`/`fail_frame` filled for the bisect.
pub fn runBehavioralTier(
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    base_image: []const u8,
    conv_image: []const u8,
    plan: *const profile.Plan,
    res: *const core.sa1gen.Result,
    mov: ?util.movie.Movie,
    verify_state: ?[]const u8,
    window: bool,
    total: u32,
    fail_why: *[]const u8,
    fail_frame: *u32,
) !?SaTier {
    try out.print("  pixel gate: divergent; behavioral tier (tick-locked replays)...\n", .{});
    try out.flush();
    const bv = try verifyBehavioral(gpa, base_image, conv_image, plan, res, mov, verify_state, window, total);
    switch (bv.verdict) {
        .pass => |kind| {
            try out.print(
                "  behavioral: {s} — {} ticks compared ({} at stable lag differential), {} diverging ({} address(es), worst run {})\n",
                .{
                    if (kind == .clean) @as([]const u8, "logic state IDENTICAL at every tick") else "wall-time echoes only",
                    bv.ticks_base,
                    bv.stats.stable_ticks,
                    bv.stats.bad_ticks,
                    bv.stats.n_addrs,
                    bv.stats.worst_run,
                },
            );
            try out.print(
                "    inputs: {} frame(s), movie {} frame(s), {s}, {s}\n    pairing ended: {s}\n",
                .{
                    total,
                    if (mov) |m| @as(u32, @intCast(m.frames.len)) else 0,
                    if (verify_state != null) @as([]const u8, "seeded from a state") else "from power-on",
                    if (window) @as([]const u8, "window homes") else "plan homes",
                    bv.exit.describe(),
                },
            );
            if (bv.stats.skew_active_ticks > 0)
                try out.print(
                    "    {} tick(s) diverged only while the lag differential itself was moving (the removed slowdown, not corruption; excluded from the budgets)\n",
                    .{bv.stats.skew_active_ticks},
                );
            if (bv.stats.heldCount() > 0)
                try out.print(
                    "    {} cell(s) hold a constant offset (wall-time origins: pass counters and state seeded from them)\n",
                    .{bv.stats.heldCount()},
                );
            return .behavioral;
        },
        .fail => |why| {
            // A terminal open run in the second half is the RNG-fork
            // signature: the timing change moved the wall-origin counters
            // enemy RNG seeds from, the game forked at the first
            // RNG-sensitive event, and every later tick compares two
            // different healthy games. Verify up to the horizon: a pass
            // there is the honest maximum tick-locked replay can prove
            // (v17 has the same property; humans QA past it).
            if (bv.fork_wall) |fw| if (fw > 600 and fw + 120 < total) {
                try out.print(
                    "  behavioral: diverges from wall frame {} to surface end — RNG-fork signature; re-verifying up to the horizon...\n",
                    .{fw},
                );
                try out.flush();
                const bv2 = try verifyBehavioral(gpa, base_image, conv_image, plan, res, mov, verify_state, window, fw);
                if (bv2.verdict == .pass) {
                    try out.print(
                        "  behavioral: equivalent MODULO {} RNG-FORK EPISODE(S) — prefix of {} ticks verified to the first fork at wall frame {} of {}; {} tick(s) inside fork episodes excused ({s}); off-episode divergence {} tick(s) with every run <= {}\n",
                        .{
                            bv.stats.long_runs,
                            bv2.ticks_base,
                            fw,
                            total,
                            bv.stats.long_total,
                            if (bv.stats.runReachesEnd()) @as([]const u8, "the last runs to the surface end: a gameplay fork, unverifiable by replay — eyeball it") else "each healed by a scene reset, which corruption would not survive",
                            bv.stats.bad_ticks - bv.stats.long_total,
                            util.Persistence.max_run,
                        },
                    );
                    return .behavioral;
                }
                try out.print("  behavioral: pre-horizon verification also fails — treating as real divergence\n", .{});
            };
            fail_why.* = switch (why) {
                .persistence => "live state diverges and never heals (or the conversion stopped ticking)",
                .spread => "live-state divergence keeps reaching new addresses",
                .flood => "live state diverges on too many ticks",
            };
            fail_frame.* = bv.first_bad_frame;
            try out.print("  behavioral: FAIL — {s}\n", .{fail_why.*});
            // The SAME statistics a pass prints, and the tier's inputs
            // besides. A pass used to report "2517 ticks compared, worst
            // run 24" while a failure reported a sentence — so a passing
            // run and a failing one could not be diffed field by field,
            // and a day went into inferring what one line would have
            // said. A verdict that cannot be compared to another verdict
            // is not evidence.
            try out.print(
                "    inputs: {} frame(s), movie {} frame(s), {s}, {s}\n" ++
                    "    pairing ended: {s}\n" ++
                    "    stats: {} ticks compared ({} at stable lag differential), {} diverging\n" ++
                    "      ({} address(es), {} stable-active), novelty {}, held {}, epochs {}\n" ++
                    "      worst run {} [{}..{}], runner-up {}, reaches end {}, bursts {} (runs <= {}),\n" ++
                    "      long runs {} ({} ticks), last tick {}, addr overflow {}\n",
                .{
                    total,
                    if (mov) |m| @as(u32, @intCast(m.frames.len)) else 0,
                    if (verify_state != null) @as([]const u8, "seeded from a state") else "from power-on",
                    if (window) @as([]const u8, "window homes") else "plan homes",
                    bv.exit.describe(),
                    bv.ticks_base,
                    bv.stats.stable_ticks,
                    bv.stats.bad_ticks,
                    bv.stats.n_addrs,
                    bv.stats.stableAddrCount(),
                    bv.stats.novelty_ticks,
                    bv.stats.heldCount(),
                    bv.stats.epoch_budget,
                    bv.stats.worst_run,
                    bv.stats.worst_start,
                    bv.stats.worst_end,
                    bv.stats.second_run,
                    bv.stats.runReachesEnd(),
                    bv.stats.burst_total,
                    util.Persistence.burst_len,
                    bv.stats.long_runs,
                    bv.stats.long_total,
                    bv.stats.last_tick,
                    bv.stats.addr_overflow,
                },
            );
            if (bv.n_sample > 0) {
                try out.print("    first at baseline frame {}, e.g.:", .{bv.first_bad_frame});
                for (bv.sample[0..bv.n_sample]) |adr| {
                    try out.print(" ${X:0>2}:{X:0>4}", .{ @as(u32, 0x7E) + (adr >> 16), adr & 0xFFFF });
                }
                try out.print("\n", .{});
            }
            try out.flush();
            return null;
        },
    }
}

/// First index where the two per-frame hash streams differ (streams are
/// equal length by construction). Only meaningful for the divergent case,
/// where it anchors the forensics.
pub fn firstDiff(a: []const u64, b: []const u64) u32 {
    for (a, b, 0..) |x, y, i| {
        if (x != y) return @intCast(i);
    }
    return 0;
}

/// On a failed attempt with offloads active: replay BOTH images to the
/// first bad frame, diff WRAM, attribute the differing bytes against the
/// offloaded routines' profiled working sets, and pick the routine to
/// drop — the attributed one when the evidence names it, the last
/// offloaded one otherwise.
pub fn diagnoseCulprit(
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    base_image: []const u8,
    res: core.sa1gen.Result,
    cands: []const core.sa1gen.Candidate,
    mov: ?util.movie.Movie,
    equiv: util.Equivalence,
    fail_frame: u32,
    fail_why: []const u8,
    usage: []const u8,
) !u24 {
    const n_off = res.stats.offload_count;
    const entries = res.stats.offload_entries[0..n_off];
    try out.print("verification failed with {} offload(s) active: {s}\n", .{ n_off, fail_why });

    var culprit: u24 = entries[n_off - 1];
    if (equiv == .divergent) {
        // Replay both sides to the divergence and diff WRAM.
        const wram_a = try replayWram(gpa, base_image, fail_frame + 1, mov);
        const wram_b = try replayWram(gpa, res.image, fail_frame + 1, mov);
        var n_shown: u32 = 0;
        var attributed: ?u24 = null;
        for (wram_a, wram_b, 0..) |x, y, off| {
            if (x == y) continue;
            const page: u16 = @intCast(off >> 8);
            var owner: ?u24 = null;
            var shared = false;
            for (entries) |e| {
                for (cands) |c| {
                    if (c.entry == e and page < 512 and profile.getPage(c.pages, page)) {
                        if (owner != null) shared = true;
                        owner = e;
                    }
                }
            }
            if (n_shown < 4) {
                try out.print("  diverged by frame {}: WRAM $7E:{x:0>4} = {x:0>2} -> {x:0>2}{s}", .{
                    fail_frame, off, x, y,
                    if (owner != null) " — inside the working set of $00:" else " — outside every offloaded set",
                });
                if (owner) |o| try out.print("{x:0>4}{s}", .{ o, if (shared) " (shared)" else "" });
                try out.print("\n", .{});
            }
            if (attributed == null and owner != null and !shared) attributed = owner;
            n_shown += 1;
        }
        if (n_shown > 4) try out.print("  ({} differing WRAM byte(s) total)\n", .{n_shown});
        if (n_shown == 0) try out.print("  WRAM identical at the divergent frame — the difference is in PPU state\n  (timing-visible mid-flight rendering, not corrupted memory)\n", .{});
        if (attributed) |a| culprit = a;
    }

    // SA-1-side forensics for a pointer offload: replay the converted
    // image to the divergent frame with an execution trace over the
    // offloaded body's COPY, so the path the SA-1 actually took through
    // it is a direct read rather than an inference.
    for (entries, 0..) |e, i| {
        const copy = res.stats.offload_copy[i];
        if (copy == 0) continue; // leaf offload: no copy to watch
        const span = res.stats.offload_copy_len[i];
        const trace = try replayTrace(gpa, res.image, fail_frame + 1, mov, copy);
        defer gpa.destroy(trace);
        try out.print(
            "  sa1 trace of $00:{x:0>4}'s body copy at ${x:0>2}:{x:0>4} ({} bytes): {} instruction(s)\n" ++
                "  executed across {} distinct byte(s)",
            .{ e, copy >> 16, @as(u16, @truncate(copy)), span, trace.total, trace.distinct },
        );
        if (trace.total == 0) {
            try out.print(" — THE SA-1 NEVER ENTERED IT\n", .{});
            continue;
        }
        try out.print(", entered {} time(s)\n", .{trace.countAt(copy)});
        // How much of the body the SA-1 actually walked. Only OPCODE
        // starts count — operand bytes are never instruction addresses,
        // and the copy mirrors the original byte for byte, so the S1
        // coverage map supplies which offsets are opcodes.
        var n_ops: u32 = 0;
        var n_ran: u32 = 0;
        var first_skipped: ?u24 = null;
        for (0..span) |k| {
            if (usage[e + k] & core.usage_map.flag_opcode == 0) continue;
            n_ops += 1;
            if (trace.ran(copy + @as(u24, @intCast(k)))) {
                n_ran += 1;
            } else if (first_skipped == null) {
                first_skipped = @intCast(e + k);
            }
        }
        try out.print("  covered {}/{} of the body's instructions", .{ n_ran, n_ops });
        if (first_skipped) |f| try out.print(
            "; first one never reached is the original's $00:{x:0>4}\n",
            .{f},
        ) else try out.print(" (the whole body ran)\n", .{});
        // The last few instructions, with the state that decided them.
        var buf: [core.sa1_trace.ring_cap]core.sa1_trace.Rec = undefined;
        const recent = trace.recent(&buf);
        const show = @min(recent.len, 6);
        try out.print("  last {} instruction(s) inside it:\n", .{show});
        for (recent[recent.len - show ..]) |r| try out.print(
            "    ${x:0>2}:{x:0>4}  A={x:0>4} X={x:0>4} Y={x:0>4} D={x:0>4} DB={x:0>2} P={x:0>2}\n",
            .{ r.pc >> 16, @as(u16, @truncate(r.pc)), r.c, r.x, r.y, r.d, r.dbr, r.p },
        );
    }
    return culprit;
}

/// Replay `image` for `n` frames with an SA-1 execution trace windowed at
/// `lo`. Caller owns the returned trace.
pub fn replayTrace(
    gpa: std.mem.Allocator,
    image: []const u8,
    n: u32,
    mov: ?util.movie.Movie,
    lo: u24,
) !*core.sa1_trace.Trace {
    const trace = try gpa.create(core.sa1_trace.Trace);
    errdefer gpa.destroy(trace);
    trace.* = core.sa1_trace.Trace.init(lo);
    const cart = try core.Cartridge.load(gpa, image);
    const con = try gpa.create(core.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    con.bus.sa1.trace = trace;
    var feed: util.movie.Feed = .init(mov);
    for (0..n) |i| {
        feed.step(con, i);
        con.runFrame();
    }
    return trace;
}

/// Replay an image for `n` frames and return its WRAM (caller-owned copy).
pub fn replayWram(gpa: std.mem.Allocator, image: []const u8, n: u32, mov: ?util.movie.Movie) ![]u8 {
    const cart = try core.Cartridge.load(gpa, image);
    const con = try gpa.create(core.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    var feed: util.movie.Feed = .init(mov);
    for (0..n) |i| {
        feed.step(con, i);
        con.runFrame();
    }
    return gpa.dupe(u8, &con.bus.wram.data);
}

/// The envelope-failure neighbourhood diagnostic (terminal failures only).
pub fn printEnvelopeDiag(out: *std.Io.Writer, env_base: []const u64, env_conv: []const u64, bad: u32, total: u32) !void {
    const from = bad -| 5;
    const to = @min(total, bad + 6);
    try out.print("  frame:    ", .{});
    for (from..to) |i| try out.print("{d:>9}", .{i});
    try out.print("\n  original: ", .{});
    for (from..to) |i| try out.print("{d:>9}", .{env_base[i] / 1000});
    try out.print("\n  converted:", .{});
    for (from..to) |i| try out.print("{d:>9}", .{env_conv[i] / 1000});
    var n_bad: u32 = 0;
    for (0..total) |i| {
        var one = [1]u64{env_base[i]};
        var other = [1]u64{env_conv[i]};
        if (util.audioEnvelopeMismatch(one[0..], other[0..]) != null) n_bad += 1;
    }
    try out.print("\n  (energies in thousands; {} of {} frames outside the window point-wise)\n", .{ n_bad, total });
}
