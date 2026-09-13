//! The two build-speed caches: the per-cover-pair harvest cache and the baseline snapshot of a generation's whole stock phase, both keyed on every input they consume.
//!
//! Carved out of main.zig as pure code motion; every declaration
//! here is re-exported from main.zig, which stays the root.

const core = @import("snes_core");
const profile = core.profile;
const std = @import("std");
const util = @import("util");
const root_mod = @import("../main.zig");

/// Bump when the profiler's products change meaning (usage flags, site
/// evidence classes, what counts as a proven bank byte): every cached
/// harvest keyed on the old version is then ignored, never misread.
pub const harvest_cache_version: u32 = 1;
pub const harvest_cache_magic = "YHC1";

pub fn harvestCachePath(buf: []u8, dir: []const u8, img_crc: u32, movie_hash: u64) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/harvest-{x:0>8}-{x:0>16}-v{d}.bin", .{ dir, img_crc, movie_hash, harvest_cache_version });
}

pub fn hcRead32(d: []const u8, p: *usize) ?u32 {
    if (p.* + 4 > d.len) return null;
    const v = std.mem.readInt(u32, d[p.*..][0..4], .little);
    p.* += 4;
    return v;
}

pub fn hcRead64(d: []const u8, p: *usize) ?u64 {
    if (p.* + 8 > d.len) return null;
    const v = std.mem.readInt(u64, d[p.*..][0..8], .little);
    p.* += 8;
    return v;
}

/// Read one cached harvest into the pair's products. False (nothing to be
/// trusted in the outputs) on any mismatch: wrong magic, version, image or
/// movie, a truncated body, or an address outside the map.
pub fn loadHarvestCache(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    img_crc: u32,
    movie_hash: u64,
    usage: []u8,
    ev: []u8,
    pb: *core.usage_map.PtrBankEvidence,
) bool {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 * 1024 * 1024)) catch return false;
    defer gpa.free(data);
    if (data.len < 4 or !std.mem.eql(u8, data[0..4], harvest_cache_magic)) return false;
    var o: usize = 4;
    if ((hcRead32(data, &o) orelse return false) != harvest_cache_version) return false;
    if ((hcRead32(data, &o) orelse return false) != img_crc) return false;
    if ((hcRead64(data, &o) orelse return false) != movie_hash) return false;
    const n = hcRead32(data, &o) orelse return false;
    if (o + @as(usize, n) * 6 > data.len) return false;
    for (0..n) |_| {
        const pc = std.mem.readInt(u32, data[o..][0..4], .little);
        if (pc >= usage.len) return false;
        usage[pc] = data[o + 4];
        ev[pc] = data[o + 5];
        o += 6;
    }
    const np = hcRead32(data, &o) orelse return false;
    for (0..np) |_| pb.addProven(hcRead32(data, &o) orelse return false);
    const nt = hcRead32(data, &o) orelse return false;
    for (0..nt) |_| {
        const t = hcRead32(data, &o) orelse return false;
        pb.addHdmaTable(@intCast(t & 0xFF_FFFF));
    }
    return true;
}

/// Write the pair's products sparsely: only map cells that are non-zero.
/// Best-effort — a cache that cannot be written just means a replay next
/// time.
/// The baseline snapshot: everything the stock side of a generation
/// produces before the harvest, so a repeat build with the same inputs
/// skips it. MEASURED (v78, idle machine): the evidence pass, the eight
/// baselines and the coverage pad are ~27 of a build's 36 minutes, and
/// none of their inputs change between versions of the same recipe — the
/// generator's own code and the split flags act after this point.
///
/// Exact by construction: the phase is replayed serially into ONE union in
/// a fixed order and the snapshot is that union's bytes, not a merge. The
/// profiler and evidence structs are plain data (fixed arrays, no
/// pointers) and are stored raw, guarded by a layout hash of their fields
/// (names, sizes, offsets) so a struct change invalidates every snapshot.
pub const baseline_cache_magic = "YBSC";
pub const baseline_cache_version: u32 = 1;

pub fn layoutHash(comptime T: type) u32 {
    comptime {
        @setEvalBranchQuota(200_000);
        var h: u32 = 2166136261;
        const info = @typeInfo(T).@"struct";
        for (info.fields) |f| {
            for (f.name) |c| h = (h ^ c) *% 16777619;
            h = (h ^ @as(u32, @intCast(@sizeOf(f.type) & 0xFFFF_FFFF))) *% 16777619;
            h = (h ^ @as(u32, @intCast(@offsetOf(T, f.name) & 0xFFFF_FFFF))) *% 16777619;
        }
        h = (h ^ @as(u32, @intCast(@sizeOf(T) & 0xFFFF_FFFF))) *% 16777619;
        return h;
    }
}

pub const baseline_layout: u32 = layoutHash(profile.Profiler) ^ (layoutHash(profile.Summary) *% 3) ^
    (layoutHash(profile.Conversion) *% 5) ^ (layoutHash(core.usage_map.PtrBankEvidence) *% 7);

/// Every input the stock phase consumes: the image, each surface's inputs
/// and mode, the anchored states, the skip, and the flags that steer the
/// phase (window/whole-game select the pad and the evidence pass).
pub fn baselineKey(
    image: []const u8,
    movs: []const util.movie.Movie,
    n_surf: usize,
    totals: []const u32,
    evidence_state: ?[]const u8,
    verify_state: ?[]const u8,
    skip: u32,
    whole_game: bool,
    window: bool,
) u64 {
    var h = std.hash.Fnv1a_64.init();
    h.update(std.mem.asBytes(&baseline_cache_version));
    h.update(std.mem.asBytes(&baseline_layout));
    const crc = util.movie.imageCrc(image);
    h.update(std.mem.asBytes(&crc));
    const ns: u32 = @intCast(n_surf);
    h.update(std.mem.asBytes(&ns));
    for (0..n_surf) |i| {
        h.update(std.mem.asBytes(&totals[i]));
        if (i < movs.len) {
            const m = movs[i];
            h.update(std.mem.sliceAsBytes(m.frames));
            if (m.anchor) |a| h.update(a);
            if (m.start_srm) |b| h.update(b);
            h.update(std.mem.asBytes(&m.per_poll));
            h.update(std.mem.asBytes(&m.tail_frames));
            h.update(std.mem.asBytes(&m.lap_cell));
        }
    }
    if (evidence_state) |b| h.update(b);
    if (verify_state) |b| h.update(b);
    h.update(std.mem.asBytes(&skip));
    h.update(std.mem.asBytes(&whole_game));
    h.update(std.mem.asBytes(&window));
    return h.final();
}

/// What the snapshot carries, as views into the generator's own storage.
pub const BaselineSnap = struct {
    n_surf: usize,
    totals: []const u32,
    hashes: []const []u64,
    env: []const []u64,
    audio: []u64,
    sums: []profile.Summary,
    mmio: []const *core.bus.Bus.MmioWriters,
    cov_early: *u32,
    prof: *profile.Profiler,
    evidence: *?profile.Conversion,
    ub: []u8,
    site_ev: []u8,
    ptr_ev: *core.usage_map.PtrBankEvidence,
};

pub fn baselineCachePath(gpa: std.mem.Allocator, dir: []const u8, key: u64) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}/base-{x:0>16}.ybs", .{ dir, key });
}

/// Read and validate a snapshot for `key`; the bytes past the header, or
/// null (missing, foreign, stale).
pub fn loadBaselineSnapshot(io: std.Io, gpa: std.mem.Allocator, path: []const u8, key: u64) ?[]const u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024 * 1024)) catch return null;
    if (data.len < 24 or !std.mem.eql(u8, data[0..4], baseline_cache_magic)) return null;
    if (std.mem.readInt(u32, data[4..8], .little) != baseline_cache_version) return null;
    if (std.mem.readInt(u32, data[8..12], .little) != baseline_layout) return null;
    if (std.mem.readInt(u64, data[12..20], .little) != key) return null;
    return data[20..];
}

pub const SnapReader = struct {
    d: []const u8,
    o: usize = 0,
    pub fn bytes(r: *SnapReader, n: usize) ![]const u8 {
        if (r.o + n > r.d.len) return error.Truncated;
        const b = r.d[r.o .. r.o + n];
        r.o += n;
        return b;
    }
    pub fn u32v(r: *SnapReader) !u32 {
        return std.mem.readInt(u32, (try r.bytes(4))[0..4], .little);
    }
    pub fn u64v(r: *SnapReader) !u64 {
        return std.mem.readInt(u64, (try r.bytes(8))[0..8], .little);
    }
};

pub fn applyBaselineSnapshot(data: []const u8, snap: BaselineSnap) !void {
    var r: SnapReader = .{ .d = data };
    if (try r.u32v() != snap.n_surf) return error.SurfaceCount;
    for (0..snap.n_surf) |s| {
        if (try r.u32v() != snap.totals[s]) return error.SurfaceLength;
        const n: usize = snap.totals[s];
        @memcpy(std.mem.sliceAsBytes(snap.hashes[s][0..n]), try r.bytes(n * 8));
        @memcpy(std.mem.sliceAsBytes(snap.env[s][0..n]), try r.bytes(n * 8));
        snap.audio[s] = try r.u64v();
        @memcpy(std.mem.asBytes(&snap.sums[s]), try r.bytes(@sizeOf(profile.Summary)));
        const nm = try r.u32v();
        const m = snap.mmio[s];
        m.set.clearRetainingCapacity();
        for (0..nm) |_| try m.set.put(m.alloc, try r.u64v(), {});
    }
    snap.cov_early.* = try r.u32v();
    @memcpy(std.mem.asBytes(snap.prof), try r.bytes(@sizeOf(profile.Profiler)));
    const has_ev = try r.u32v();
    if (has_ev != 0) {
        var c: profile.Conversion = undefined;
        @memcpy(std.mem.asBytes(&c), try r.bytes(@sizeOf(profile.Conversion)));
        snap.evidence.* = c;
    } else snap.evidence.* = null;
    @memcpy(snap.ub, try r.bytes(snap.ub.len));
    @memcpy(snap.site_ev, try r.bytes(snap.site_ev.len));
    @memcpy(std.mem.asBytes(snap.ptr_ev), try r.bytes(@sizeOf(core.usage_map.PtrBankEvidence)));
    if (r.o != data.len) return error.TrailingBytes;
}

pub fn saveBaselineSnapshot(io: std.Io, gpa: std.mem.Allocator, dir: []const u8, path: []const u8, key: u64, snap: BaselineSnap) !void {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(baseline_cache_magic);
    try w.writeInt(u32, baseline_cache_version, .little);
    try w.writeInt(u32, baseline_layout, .little);
    try w.writeInt(u64, key, .little);
    try w.writeInt(u32, @intCast(snap.n_surf), .little);
    for (0..snap.n_surf) |s| {
        const n: usize = snap.totals[s];
        try w.writeInt(u32, snap.totals[s], .little);
        try w.writeAll(std.mem.sliceAsBytes(snap.hashes[s][0..n]));
        try w.writeAll(std.mem.sliceAsBytes(snap.env[s][0..n]));
        try w.writeInt(u64, snap.audio[s], .little);
        try w.writeAll(std.mem.asBytes(&snap.sums[s]));
        const m = snap.mmio[s];
        // sorted, so the file is a function of the set and nothing else
        const keys = try gpa.alloc(u64, m.set.count());
        defer gpa.free(keys);
        var it = m.set.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) keys[i] = k.*;
        std.mem.sort(u64, keys, {}, std.sort.asc(u64));
        try w.writeInt(u32, @intCast(keys.len), .little);
        for (keys) |k| try w.writeInt(u64, k, .little);
    }
    try w.writeInt(u32, snap.cov_early.*, .little);
    try w.writeAll(std.mem.asBytes(snap.prof));
    if (snap.evidence.*) |c| {
        try w.writeInt(u32, 1, .little);
        try w.writeAll(std.mem.asBytes(&c));
    } else try w.writeInt(u32, 0, .little);
    try w.writeAll(snap.ub);
    try w.writeAll(snap.site_ev);
    try w.writeAll(std.mem.asBytes(snap.ptr_ev));
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() });
}

pub fn saveHarvestCache(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: []const u8,
    path: []const u8,
    img_crc: u32,
    movie_hash: u64,
    usage: []const u8,
    ev: []const u8,
    pb: *const core.usage_map.PtrBankEvidence,
) void {
    var n: usize = 0;
    for (usage, ev) |u, e| {
        if (u != 0 or e != 0) n += 1;
    }
    const size = 4 + 4 + 4 + 8 + 4 + n * 6 + 4 + pb.n_proven * 4 + 4 + pb.n_hdma_tables * 4;
    const buf = gpa.alloc(u8, size) catch return;
    defer gpa.free(buf);
    @memcpy(buf[0..4], harvest_cache_magic);
    var o: usize = 4;
    std.mem.writeInt(u32, buf[o..][0..4], harvest_cache_version, .little);
    o += 4;
    std.mem.writeInt(u32, buf[o..][0..4], img_crc, .little);
    o += 4;
    std.mem.writeInt(u64, buf[o..][0..8], movie_hash, .little);
    o += 8;
    std.mem.writeInt(u32, buf[o..][0..4], @intCast(n), .little);
    o += 4;
    for (usage, ev, 0..) |u, e, pc| {
        if (u == 0 and e == 0) continue;
        std.mem.writeInt(u32, buf[o..][0..4], @intCast(pc), .little);
        buf[o + 4] = u;
        buf[o + 5] = e;
        o += 6;
    }
    std.mem.writeInt(u32, buf[o..][0..4], @intCast(pb.n_proven), .little);
    o += 4;
    for (pb.proven[0..pb.n_proven]) |a| {
        std.mem.writeInt(u32, buf[o..][0..4], a, .little);
        o += 4;
    }
    std.mem.writeInt(u32, buf[o..][0..4], @intCast(pb.n_hdma_tables), .little);
    o += 4;
    for (pb.hdma_tables[0..pb.n_hdma_tables]) |t| {
        std.mem.writeInt(u32, buf[o..][0..4], @as(u32, t), .little);
        o += 4;
    }
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf[0..o] }) catch {};
}
