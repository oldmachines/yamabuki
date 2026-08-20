//! Call graph and per-routine complexity over a profiled image.
//!
//! The generator ranks offload candidates by measured cost, but what decides
//! whether an offload does anything is the CALL GRAPH: a routine is only
//! worth moving if its callers can be re-pointed at the stub, and a call site
//! the profile never executed is never rewritten. Measured: `$00:9BCD` was
//! offered to the selector under a stage-2 profile, copied to the SA-1, and
//! executed ZERO instructions — the game kept calling the original, because
//! its call sites lived in a scene that profile never saw. That is a graph
//! question, and it cost a full generation run to answer.
//!
//! What this sees, and what it does NOT: edges come from direct `JSR abs` and
//! `JSL long` at instruction addresses the map marks as executed (optionally
//! extended by the static walk). Indirect dispatch — `JSR (abs,X)`, `JMP
//! [abs]`, a pointer table, or a bank byte copied out of a ROM record into a
//! DMA register — is COUNTED as unresolved and never drawn. A graph that
//! looked complete while silently omitting data-driven edges would be worse
//! than no graph at all, because it would be trusted: the missing-decor bug
//! this tool exists to help with was exactly such an edge.

const std = @import("std");
const usage_map = @import("usage_map.zig");

/// One routine: an entry address plus what the walk found inside it.
pub const Node = struct {
    entry: u24,
    /// Executed instructions attributed to this routine.
    instrs: u32 = 0,
    /// Bytes those instructions span.
    bytes: u32 = 0,
    /// Conditional branches — the cyclomatic complexity input.
    branches: u32 = 0,
    /// Direct call sites INSIDE this routine.
    calls_out: u32 = 0,
    /// Dispatch sites whose target this analysis cannot name.
    indirect: u32 = 0,
    /// Call sites elsewhere that name this routine.
    callers: u32 = 0,

    /// Branches plus one: the number of independent paths through the body.
    /// A leaf with no branches scores 1.
    pub fn complexity(self: Node) u32 {
        return self.branches + 1;
    }
};

/// A caller/callee pair, with how many sites make the call.
pub const Edge = struct {
    from: u24,
    to: u24,
    sites: u32 = 0,
};

pub const Graph = struct {
    nodes: []Node,
    edges: []Edge,
    /// Dispatch sites in covered code whose target is not statically knowable.
    /// Reported, never hidden: these are the edges the graph is missing.
    unresolved: u32,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Graph) void {
        self.gpa.free(self.nodes);
        self.gpa.free(self.edges);
    }

    pub fn find(self: *const Graph, entry: u24) ?*Node {
        for (self.nodes) |*n| {
            if (n.entry == entry) return n;
        }
        return null;
    }
};

/// Mirror-merged flags: the same ROM byte can only ever have been executed
/// through $80-$BF, which is how the rest of this codebase reads coverage.
fn flags(usage: []const u8, addr: u24) u8 {
    const lo: u32 = addr & 0x7F_FFFF;
    return usage[lo] | usage[0x80_0000 | lo];
}

fn isOpcode(usage: []const u8, addr: u24) bool {
    return flags(usage, addr) & usage_map.flag_opcode != 0;
}

/// A conditional branch — the complexity input. BRA/BRL are unconditional
/// transfers and add no path.
fn isConditionalBranch(op: u8) bool {
    return switch (op) {
        0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0 => true,
        else => false,
    };
}

/// Dispatch this analysis cannot follow: the target is computed, or read
/// from memory, at run time.
fn isIndirectDispatch(op: u8) bool {
    return switch (op) {
        0xFC, // JSR (abs,X)
        0x6C, // JMP (abs)
        0x7C, // JMP (abs,X)
        0xDC, // JMP [abs]
        => true,
        else => false,
    };
}

/// LoROM file offset of a CPU address, or null when it names something that
/// is not ROM in this mapping.
fn fileOff(addr: u24, len: usize) ?u32 {
    const bank: u32 = (addr >> 16) & 0x7F;
    const a16: u32 = addr & 0xFFFF;
    if (a16 < 0x8000) return null;
    const off = bank * 0x8000 + (a16 - 0x8000);
    return if (off < len) @intCast(off) else null;
}

/// Build the graph. `entries` seeds the node set (profile routine entries);
/// every direct call target found in covered code is added to it.
pub fn analyze(
    gpa: std.mem.Allocator,
    image: []const u8,
    usage: []const u8,
    entries: []const u24,
) !Graph {
    var set: std.AutoArrayHashMapUnmanaged(u24, Node) = .empty;
    errdefer set.deinit(gpa);
    for (entries) |e| {
        if (fileOff(e, image.len) == null) continue;
        _ = try set.getOrPutValue(gpa, e & 0x7F_FFFF, .{ .entry = e & 0x7F_FFFF });
    }

    // Pass 1: every direct call target is a routine, whether or not the
    // profile named it.
    var addr: u32 = 0;
    while (addr < 0x80_0000) : (addr += 1) {
        const a: u24 = @intCast(addr);
        if (!isOpcode(usage, a)) continue;
        const off = fileOff(a, image.len) orelse continue;
        const op = image[off];
        if (op == 0x20 and off + 2 < image.len) {
            const t: u24 = (@as(u24, @intCast((addr >> 16) & 0x7F)) << 16) |
                std.mem.readInt(u16, image[off + 1 ..][0..2], .little);
            if (fileOff(t, image.len) != null)
                _ = try set.getOrPutValue(gpa, t, .{ .entry = t });
        } else if (op == 0x22 and off + 3 < image.len) {
            const t: u24 = @intCast(std.mem.readInt(u24, image[off + 1 ..][0..3], .little) & 0x7F_FFFF);
            if (fileOff(t, image.len) != null)
                _ = try set.getOrPutValue(gpa, t, .{ .entry = t });
        }
    }

    var nodes = try gpa.alloc(Node, set.count());
    errdefer gpa.free(nodes);
    for (set.values(), 0..) |n, i| nodes[i] = n;
    std.mem.sort(Node, nodes, {}, struct {
        fn lt(_: void, a: Node, b: Node) bool {
            return a.entry < b.entry;
        }
    }.lt);

    // Pass 2: attribute each executed instruction to the routine it sits in
    // (the greatest entry at or below it, in the same bank) and record edges.
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    errdefer edges.deinit(gpa);
    var unresolved: u32 = 0;

    addr = 0;
    while (addr < 0x80_0000) : (addr += 1) {
        const a: u24 = @intCast(addr);
        if (!isOpcode(usage, a)) continue;
        const off = fileOff(a, image.len) orelse continue;
        const f = flags(usage, a);
        const op = image[off];
        const len = usage_map.instrLen(op, f & usage_map.flag_m != 0, f & usage_map.flag_x != 0);

        const owner = ownerOf(nodes, a) orelse continue;
        nodes[owner].instrs += 1;
        nodes[owner].bytes += len;
        if (isConditionalBranch(op)) nodes[owner].branches += 1;
        if (isIndirectDispatch(op)) {
            nodes[owner].indirect += 1;
            unresolved += 1;
            continue;
        }

        const target: ?u24 = if (op == 0x20 and off + 2 < image.len)
            (@as(u24, @intCast((addr >> 16) & 0x7F)) << 16) |
                std.mem.readInt(u16, image[off + 1 ..][0..2], .little)
        else if (op == 0x22 and off + 3 < image.len)
            @intCast(std.mem.readInt(u24, image[off + 1 ..][0..3], .little) & 0x7F_FFFF)
        else
            null;
        const t = target orelse continue;
        nodes[owner].calls_out += 1;
        if (indexOf(nodes, t)) |ti| nodes[ti].callers += 1;

        for (edges.items) |*e| {
            if (e.from == nodes[owner].entry and e.to == t) {
                e.sites += 1;
                break;
            }
        } else try edges.append(gpa, .{ .from = nodes[owner].entry, .to = t, .sites = 1 });
    }

    set.deinit(gpa);
    return .{
        .nodes = nodes,
        .edges = try edges.toOwnedSlice(gpa),
        .unresolved = unresolved,
        .gpa = gpa,
    };
}

fn indexOf(nodes: []const Node, entry: u24) ?usize {
    var lo: usize = 0;
    var hi: usize = nodes.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (nodes[mid].entry == entry) return mid;
        if (nodes[mid].entry < entry) lo = mid + 1 else hi = mid;
    }
    return null;
}

/// The routine an address belongs to: the greatest entry at or below it in
/// the same bank. Bank-local because a JSR cannot leave its bank, so a
/// routine's body never spans one.
fn ownerOf(nodes: []const Node, addr: u24) ?usize {
    var lo: usize = 0;
    var hi: usize = nodes.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (nodes[mid].entry <= addr) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return null;
    const i = lo - 1;
    return if (nodes[i].entry >> 16 == addr >> 16) i else null;
}


// --- tests -------------------------------------------------------------------

const testing = std.testing;

/// A tiny LoROM with a known shape: $8000 calls $8010 twice and $8020 once,
/// $8010 branches twice, $8020 dispatches indirectly.
fn fixture(gpa: std.mem.Allocator) !struct { rom: []u8, usage: []u8 } {
    const rom = try gpa.alloc(u8, 0x8000);
    @memset(rom, 0xEA); // NOP
    const usage = try gpa.alloc(u8, 0x100_0000);
    @memset(usage, 0);

    // $00:8000: JSR $8010 / JSR $8010 / JSR $8020 / RTS
    @memcpy(rom[0x0000..0x000A], &[_]u8{
        0x20, 0x10, 0x80,
        0x20, 0x10, 0x80,
        0x20, 0x20, 0x80,
        0x60,
    });
    // $00:8010: BNE +0 / BEQ +0 / RTS
    @memcpy(rom[0x0010..0x0015], &[_]u8{ 0xD0, 0x00, 0xF0, 0x00, 0x60 });
    // $00:8020: JSR ($1234,X) / RTS
    @memcpy(rom[0x0020..0x0024], &[_]u8{ 0xFC, 0x34, 0x12, 0x60 });

    for ([_]u32{ 0x8000, 0x8003, 0x8006, 0x8009, 0x8010, 0x8012, 0x8014, 0x8020, 0x8023 }) |a|
        usage[a] |= usage_map.flag_opcode | usage_map.flag_m | usage_map.flag_x;
    return .{ .rom = rom, .usage = usage };
}

test "callgraph: nodes, edges and complexity from covered code" {
    const gpa = testing.allocator;
    const f = try fixture(gpa);
    defer gpa.free(f.rom);
    defer gpa.free(f.usage);

    var g = try analyze(gpa, f.rom, f.usage, &.{0x008000});
    defer g.deinit();

    // Three routines: the seed plus the two call targets discovered.
    try testing.expectEqual(@as(usize, 3), g.nodes.len);
    const root = g.find(0x008000).?;
    const leaf = g.find(0x008010).?;
    const ind = g.find(0x008020).?;

    // Two sites name $8010, one names $8020 — and the callee knows.
    try testing.expectEqual(@as(u32, 3), root.calls_out);
    try testing.expectEqual(@as(u32, 2), leaf.callers);
    try testing.expectEqual(@as(u32, 1), ind.callers);

    // Complexity: two conditional branches means three paths.
    try testing.expectEqual(@as(u32, 3), leaf.complexity());
    try testing.expectEqual(@as(u32, 1), root.complexity());

    // The edge list collapses the repeated site into one edge of weight 2.
    var to_leaf: u32 = 0;
    for (g.edges) |e| {
        if (e.from == 0x008000 and e.to == 0x008010) to_leaf = e.sites;
    }
    try testing.expectEqual(@as(u32, 2), to_leaf);
}

test "callgraph: indirect dispatch is counted, never invented" {
    const gpa = testing.allocator;
    const f = try fixture(gpa);
    defer gpa.free(f.rom);
    defer gpa.free(f.usage);

    var g = try analyze(gpa, f.rom, f.usage, &.{0x008000});
    defer g.deinit();

    // The `JSR (abs,X)` is reported as an unresolved edge and draws nothing:
    // a graph that guessed here would hide exactly the data-driven calls
    // this tool exists to expose.
    try testing.expectEqual(@as(u32, 1), g.unresolved);
    try testing.expectEqual(@as(u32, 1), g.find(0x008020).?.indirect);
    for (g.edges) |e| try testing.expect(e.from != 0x008020);
}

test "callgraph: uncovered code contributes nothing" {
    const gpa = testing.allocator;
    const f = try fixture(gpa);
    defer gpa.free(f.rom);
    defer gpa.free(f.usage);
    // Same ROM, empty coverage: the walk has nothing to attribute, so the
    // only node is the seed and it is empty. An offload candidate whose body
    // shows 0 instructions here is one the profile never ran.
    @memset(f.usage, 0);

    var g = try analyze(gpa, f.rom, f.usage, &.{0x008000});
    defer g.deinit();
    try testing.expectEqual(@as(usize, 1), g.nodes.len);
    try testing.expectEqual(@as(u32, 0), g.nodes[0].instrs);
    try testing.expectEqual(@as(usize, 0), g.edges.len);
}
