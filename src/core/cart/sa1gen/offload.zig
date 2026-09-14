//! Stage S3b routine offload: the pointer-tree eligibility walk, the message-port stubs that marshal registers over the I-RAM mailbox, the fences, and the byte emitters (`put`, `putJsr`) every other emitter uses.
//!
//! Carved out of sa1gen.zig as pure code motion; every declaration here is
//! re-exported from sa1gen.zig, which stays the module's public root.

const patchgen = @import("../patchgen.zig");
const profile = @import("../../profile.zig");
const std = @import("std");
const usage_map = @import("../../usage_map.zig");
const sa1gen = @import("../sa1gen.zig");

const Candidate = sa1gen.Candidate;
const Result = sa1gen.Result;
const park_len = sa1gen.park_len;
const shim_len_max = sa1gen.shim_len_max;
/// The I-RAM mailbox the offload handshake marshals registers through
/// (window addresses $3780-$3786: A, X, Y 16-bit; P 8-bit at +6). The SA-1's
/// stack is parked just below it. Plans that filled I-RAM past $3700 skip
/// offload rather than collide.
pub const mailbox: u16 = 0x3780;
pub const iram_offload_limit: u32 = 0x700;

/// S3b: offload the first eligible hot routine to the SA-1. Eligibility is a
/// static walk of the routine's covered code (leaf, single RTS exit, every
/// data access SA-1-visible after the relocation); the machinery is an
/// S-CPU stub and an SA-1 dispatcher speaking the real CFR/SFR message
/// nibbles, registers marshalled through the I-RAM mailbox. Executed JSR
/// call sites are re-pointed at the stub; unseen call sites keep calling the
/// original routine on the S-CPU, which stays correct — the routine's code
/// is never modified.
pub const offload_max: usize = 7;

/// The pointer-offload's BW-RAM shadow: WRAM $7E:xxxx mirrors at bank $41
/// (linear $10000+xxxx) — identity offsets, so pointer VALUES survive and
/// only bank bytes translate. Bank $41 keeps the whole shadow inside the
/// cart's 128 KiB BW-RAM ceiling (`cartridge.max_sram`); routines whose
/// profiled pages touch $7F have no shadow home and stay on the S-CPU.
/// The SA-1 runs pointer routines with D=$6000 and its BW-RAM window
/// (CBM block 8) mapped over the shadow's first 8 KiB, so dp operands
/// stay byte-identical too.
pub const shadow_linear: u32 = 0x1_0000;
pub const shadow_bank: u8 = 0x41;
pub const ptr_slot_cap = 6;
pub const ptr_db_cap = 4;
pub const ptr_tree_cap = 8;
pub const ptr_wram_long_cap = 16;
/// Sum-of-spans budget for one tree's copies (overlapping members each
/// carry their own copy of any shared tail, so this bounds the carve).
pub const ptr_tree_span_max: u32 = 4096;
pub const ptr_run_cap = 8;
pub const ptr_pages_cap = 32;

/// Master cycles the S-CPU's MVN spends per byte, each way. The marshal
/// copies the working set in and out, so a page costs 2 * 256 * this.
pub const mvn_cycles_per_byte: u64 = 7;

/// The marshal must cost less than this fraction of what the routine
/// actually spends computing, per call — otherwise the "offload" is a
/// regression dressed as a conversion. Half is deliberately conservative:
/// the SA-1 runs the work at ~2.7x the S-CPU's clock with no bus
/// contention, so a marshal at half the routine's own cost still leaves a
/// real win, and anything dearer is refused rather than shipped and
/// measured later.
pub const marshal_budget_num: u64 = 1;
pub const marshal_budget_den: u64 = 2;

/// What the pointer-eligibility walk proves about a routine.
pub const PtrSpec = struct {
    /// dp offsets of the BANK bytes of long-indirect pointers ([dp] /
    /// [dp],y name a 24-bit pointer at dp..dp+2) — translated $7E/$7F ->
    /// $42/$43 in the shadow before the SA-1 runs, and back after.
    slots: [ptr_slot_cap]u8 = undefined,
    n_slots: usize = 0,
    /// File offsets of the $7E immediate in a LDA #$7E / PHA / PLB idiom —
    /// rewritten to the shadow bank IN THE SA-1'S COPY of the routine so
    /// (dp),y stores land in the shadow. The original body is never
    /// modified: unseen S-CPU callers keep calling unchanged code.
    db_sites: [ptr_db_cap]u32 = undefined,
    n_db: usize = 0,
    /// Bytes from entry to the closing RTL: the span copied for the SA-1.
    span: u32 = 0,
    /// The CALL TREE: members[0] is the root; the rest are bank-$00
    /// JSL/RTL helpers the tree JSLs, each walked by the same rules and
    /// copied alongside the root (JSL operands in the copies are rebased
    /// member-to-member). Only the ROOT's call sites are re-pointed at a
    /// stub — a helper's outside callers keep running the original, which
    /// is safe for a synchronous offload because the S-CPU spins in the
    /// stub for the whole SA-1 run. `pin` is the data bank the member
    /// INHERITS at entry — the caller's pin at every tree JSL that
    /// reaches it (the copy is only ever entered through those JSLs); a
    /// disagreement between call sites sets `conflict` and refuses the
    /// tree.
    members: [ptr_tree_cap]struct { entry: u16, span: u32, pin: ?u8, conflict: bool } = undefined,
    n_members: usize = 0,
    /// Sum of the members' spans: the carve the copies need.
    total_span: u32 = 0,
    /// File offsets of the BANK byte of long WRAM operands ($7E:xxxx, or
    /// the $00-$3F low mirror of it) — rewritten to the shadow bank in
    /// the copy (identity offsets make the 16 bits carry over; a $00-$3F
    /// mirror's low half IS $7E:0000-1FFF). On the SA-1 those addresses
    /// are I-RAM or nothing, so without the rewrite the body reads noise.
    wram_long_sites: [ptr_wram_long_cap]u32 = undefined,
    n_wram_long: usize = 0,
    /// Every helper's executed JSL sites lie inside the tree: nothing
    /// outside can run a helper WHILE the SA-1 does — the gate async
    /// needs (sync never overlaps, so it never cares).
    helpers_private: bool = true,
};

/// The routine's profiled WRAM pages coalesced into marshal runs (split at
/// the $7E/$7F boundary so each run has one MVN bank pair).
pub const Runs = struct {
    start: [ptr_run_cap]u16 = undefined, // first page index
    len: [ptr_run_cap]u16 = undefined, // pages
    n: usize = 0,
};

pub fn pageRuns(pages: profile.WramPages) ?Runs {
    var runs: Runs = .{};
    var total: u32 = 0;
    var p: u16 = 0;
    while (p < 512) : (p += 1) {
        if (!profile.getPage(pages, p)) continue;
        if (p >= 256) return null; // $7F has no shadow home
        total += 1;
        if (runs.n > 0 and runs.start[runs.n - 1] + runs.len[runs.n - 1] == p) {
            runs.len[runs.n - 1] += 1;
        } else {
            if (runs.n == ptr_run_cap) return null;
            runs.start[runs.n] = p;
            runs.len[runs.n] = 1;
            runs.n += 1;
        }
    }
    if (total > ptr_pages_cap) return null;
    return runs;
}

pub const OffloadKind = enum { leaf, ptr };

pub const Chosen = struct {
    entry: u16,
    kind: OffloadKind,
    spec: PtrSpec = .{},
    runs: Runs = .{},
    /// Sibling entry points inside this routine's span whose page sets
    /// were folded into the marshal set.
    siblings: u32 = 0,
    /// This routine's data lives in BW-RAM permanently instead of being
    /// marshalled: the original body's data-bank idiom is rewritten too,
    /// so the S-CPU's own calls address the same single copy.
    resident: bool = false,
    /// Fire-and-forget: the S-CPU stub sends the message and returns
    /// immediately with the caller's own registers; a fence (at the next
    /// call, and each NMI) completes the handshake. NOTHING is copied
    /// back — register results and dp writes are dropped; only effects on
    /// BW-RAM-resident state survive, so resident routines only.
    is_async: bool = false,
    /// Where the SA-1's rewritten copy of a pointer routine landed (the
    /// dispatcher JSLs it; the original body is never modified).
    copy_addr: u16 = 0,
    copy_bank: u8 = 0,
};

pub fn tryOffload(
    out: []u8,
    plan: *const profile.Plan,
    usage: []const u8,
    candidates: []const Candidate,
    neighbours: []const Candidate,
    dma_pages: profile.WramPages,
    shim_carve: u32,
    allow_async: bool,
    res: *Result,
    crv: *u16,
) void {
    // The offload machinery parks the SA-1 stack and mailbox in I-RAM
    // $700-$7FF, which must not carry LIVE relocated state. A region that
    // "moved" with zero rewritten sites is dead storage — nothing refers
    // to its new home — and may be overlaid.
    if (iramLive(plan, res) > iram_offload_limit) return;
    const shadow_ok = bwramLive(plan, res) <= shadow_linear;
    var chosen: [offload_max]Chosen = undefined;
    var n: usize = 0;
    for (candidates) |c| {
        if (n == offload_max) break;
        if (c.entry >> 16 != 0 or (c.entry & 0xFFFF) < 0x8000) continue;
        const e: u16 = @truncate(c.entry);
        const dup = for (chosen[0..n]) |x| {
            if (x.entry == e) break true;
        } else false;
        if (dup) continue;
        // An async offload monopolizes the mailbox: a sibling stub that
        // sends its message while the fire-and-forget call is still in
        // flight deadlocks the dispatcher (it holds the async done echo,
        // awaiting an ack; the sibling overwrites the message port and
        // spins on an echo the dispatcher will never send). Until sync
        // stubs learn to fence first, async rides alone.
        if (n > 0 and chosen[0].is_async) break;
        if (eligibleLeaf(out, usage, plan, res, e)) {
            if (countCallSites(out, usage, e, 0x20) == 0) continue;
            chosen[n] = .{ .entry = e, .kind = .leaf };
            n += 1;
            continue;
        }
        // Pointer path: dynamic evidence (the profiled page set) + the
        // static walk; requires the shadow banks free and D unmoved (the
        // dispatcher swaps D to $6000 per call and back to 0).
        if (!shadow_ok or res.stats.d_moved) continue;
        const spec = eligiblePointer(out, usage, e) orelse continue;
        // The marshal set is the union over every candidate whose entry
        // lies INSIDE this routine's span: alternate entry points into one
        // body (a resumable state machine's "start" and "continue") are
        // separately attributed by the profiler, but they are one routine
        // sharing one working set. Marshalling only the entry we offload
        // ships a partial view of that state — the exact failure the
        // auto-bisector caught on a real cart.
        // The direct page is MANDATORY, not evidence-driven: the SA-1
        // runs the body with D over the shadow window, so every dp
        // operand it executes resolves into the shadow. If the dp page
        // is not marshalled the routine runs on whatever the shadow
        // happened to hold — which is exactly how a resumable state
        // machine reads its own progress cursor as "already finished"
        // and returns having done nothing. The profiled page set does
        // not reliably carry it (a routine's dp traffic can be
        // attributed elsewhere, and coldness is not absence), so the
        // mechanism supplies it unconditionally.
        var marshal_pages = c.pages;
        var siblings: u32 = 0;
        for ([_][]const Candidate{ candidates, neighbours }) |list| {
            for (list) |o| {
                if (o.entry == c.entry) continue;
                // Inside ANY tree member: alternate entry points into the
                // root, and the helpers themselves — the SA-1 runs their
                // code, so their working sets ride along.
                const in_tree = for (spec.members[0..spec.n_members]) |m| {
                    if (o.entry >= m.entry and o.entry - m.entry < m.span) break true;
                } else false;
                if (!in_tree) continue;
                for (&marshal_pages, o.pages) |*p, op| p.* |= op;
                siblings += 1;
            }
        }
        // --- persistent BW-RAM residency -------------------------------
        // Marshalling is a copy of state that exists in two places; every
        // copy is a chance for the two to disagree, and the window
        // between them is exactly where an NMI can write WRAM that the
        // copy-back then overwrites. Residency removes the copy instead
        // of shrinking the race: the routine's data lives in BW-RAM
        // permanently, which BOTH CPUs address identically (bank $41 at
        // the same 16-bit offset), so there is one copy and nothing to
        // synchronise.
        //
        // It is earned, not assumed. The routine must reach its data
        // through the LDA #$7E / PHA / PLB data-bank idiom (so rewriting
        // that one immediate re-points every access it makes, on both
        // CPUs — the ORIGINAL body is rewritten too, which is what makes
        // the S-CPU's own calls agree), and every page it touches must
        // be PRIVATE to it: no other profiled routine reads or writes
        // them, and no DMA arm names them. It is all-or-nothing, because
        // one data bank serves every access the routine makes: a
        // half-resident routine would send some writes to BW-RAM and
        // leave the rest in WRAM.
        //
        // The direct page is never resident: the 65816's direct page is
        // always bank $00, so the S-CPU cannot see BW-RAM through it.
        // It stays marshalled — 256 bytes instead of kilobytes.
        const dp_page: u16 = @intCast((c.entry_d >> 8) & 0xFF);
        var resident = spec.n_db > 0 and !c.d_varies;
        if (resident) {
            var p: u16 = 0;
            while (p < 512) : (p += 1) {
                if (!profile.getPage(marshal_pages, p) or p == dp_page) continue;
                if (profile.getPage(dma_pages, p)) {
                    if (dbg_walk_root != 0 and e == dbg_walk_root)
                        std.debug.print("[walk] {x:0>4}: page {x:0>2} feeds DMA — not resident\n", .{ e, p });
                    resident = false;
                    break;
                }
                for ([_][]const Candidate{ neighbours, candidates }) |list| {
                    for (list) |o| {
                        if (o.entry == c.entry) continue;
                        // Tree members and the siblings inside them share
                        // the body and get the same rewrite, so their
                        // traffic is this routine's traffic.
                        const in_tree = for (spec.members[0..spec.n_members]) |m| {
                            if (o.entry >= m.entry and o.entry - m.entry < m.span) break true;
                        } else false;
                        if (in_tree) continue;
                        if (profile.getPage(o.pages, p)) {
                            if (dbg_walk_root != 0 and e == dbg_walk_root)
                                std.debug.print("[walk] {x:0>4}: page {x:0>2} shared with ${x:0>6} — not resident\n", .{ e, p, o.entry });
                            resident = false;
                            break;
                        }
                    }
                    if (!resident) break;
                }
                if (!resident) break;
            }
            // The profile says who TOUCHED these pages; the coverage map
            // says who NAMES them. Both matter: a routine the profile
            // never separated out, or one that reads the data once from
            // a long operand, still breaks if the bytes move. So refuse
            // residency when any executed instruction outside this
            // routine's own span statically names a page we would move.
            if (resident and namedOutside(out, usage, &spec, marshal_pages, dp_page))
                resident = false;
        }
        // Resident pages are not copied: only the direct page is, and
        // that one dynamically (the stub reads D at run time).
        var static_pages = marshal_pages;
        if (resident) static_pages = @splat(0);
        const runs = pageRuns(static_pages) orelse Runs{};
        // Economics: the marshal must be cheaper than the compute it
        // enables. Candidates with no measured calls skip the test (the
        // synthetic unit tests, which carry no profile).
        if (c.calls != 0) {
            var bytes: u64 = 0;
            for (0..runs.n) |r| bytes += @as(u64, runs.len[r]) * 256;
            const marshal_cost = bytes * 2 * mvn_cycles_per_byte;
            const per_call = c.self_cycles / c.calls;
            if (marshal_cost * marshal_budget_den > per_call * marshal_budget_num) {
                if (dbg_walk_root != 0 and e == dbg_walk_root)
                    std.debug.print("[walk] {x:0>4}: UNECONOMIC — marshal {} bytes ({} cycles) vs {} cycles/call\n", .{ e, bytes, marshal_cost, per_call });
                continue;
            }
        }
        if (countCallSites(out, usage, e, 0x22) == 0) {
            if (dbg_walk_root != 0 and e == dbg_walk_root)
                std.debug.print("[walk] {x:0>4}: no executed JSL call sites\n", .{e});
            continue;
        }
        // Fire-and-forget: RESIDENT routines only — an async call keeps no
        // write-back at all (register results and dp writes are both
        // dropped; see emitFence), so only effects on BW-RAM-resident
        // state can survive, and a routine without any has nothing async
        // could deliver. FIRST and therefore alone (the monopoly guard
        // above stops the choosing once an async is in — a sibling's
        // un-fenced send would deadlock the dispatcher), few slots, and
        // never when the ladder already demoted it. Whether any caller
        // needed the dropped effects is exactly what verification
        // arbitrates, and the mode ladder retries synchronously when it
        // says so.
        // A tree with a SHARED helper additionally rules out async: an
        // outside caller would run the helper's original on the S-CPU
        // while the SA-1 runs the copy — sync never overlaps, async is
        // nothing but overlap.
        const is_async = allow_async and resident and !c.no_async and spec.n_slots <= 2 and n == 0 and
            (spec.n_members == 1 or spec.helpers_private);
        chosen[n] = .{ .entry = e, .kind = .ptr, .spec = spec, .runs = runs, .siblings = siblings, .resident = resident, .is_async = is_async };
        n += 1;
    }
    if (n == 0) return;

    // Dispatcher layout (byte-exact; the emitters below mirror it):
    //   prologue 28 | loop body 12 | id blocks (leaf 16 / ptr 25) |
    //   JMP loop 3 | signal 19 | unmarshal 21 | marshal 24
    // Pointer stubs are fully long-addressed and JSL-reached, so they may
    // live in ANY bank — carved from padding past the shim region, which
    // keeps every carve disjoint by construction. No room for them keeps
    // the leaves and retries the sizing.
    const ptr_area_start: u32 = shim_carve + shim_len_max + park_len;
    var blocks_len: u32 = 0;
    var leaf_stubs: u32 = 0;
    var base: u32 = 0;
    var ptr_base: u32 = 0;
    while (true) {
        blocks_len = 0;
        leaf_stubs = 0;
        var ptr_stub_len: u32 = 0;
        for (chosen[0..n]) |c| switch (c.kind) {
            .leaf => {
                blocks_len += 16;
                leaf_stubs += 1;
            },
            .ptr => {
                blocks_len += 33;
                ptr_stub_len += if (c.is_async)
                    fenceLen(c.spec) + asyncStubLen(c.spec) + c.spec.total_span
                else
                    ptrStubLen(c.spec, c.runs) + c.spec.total_span;
            },
        };
        const dl: u32 = 28 + 12 + blocks_len + 3 + 19 + 21 + 24;
        base = patchgen.findFreeSpace(out[0..shim_carve], leaf_stubs * @as(u32, stub_template.len) + dl) orelse return;
        if (ptr_stub_len == 0) break;
        if (patchgen.findFreeSpace(out[ptr_area_start..], ptr_stub_len)) |off| {
            ptr_base = ptr_area_start + off;
            // Stubs and body copies execute in place: the allocation must
            // not straddle a 32 KiB bank boundary (PC wraps inside a bank).
            if ((ptr_base % 0x8000) + ptr_stub_len <= 0x8000) break;
        }
        dropPtr(&chosen, &n);
        if (n == 0) return;
    }
    const disp_len: u32 = 28 + 12 + blocks_len + 3 + 19 + 21 + 24;

    const disp_addr: u16 = 0x8000 + @as(u16, @intCast(base)) +
        @as(u16, @intCast(leaf_stubs * stub_template.len));
    const loop_addr: u16 = disp_addr + 28;
    const sig_addr: u16 = disp_addr + @as(u16, @intCast(28 + 12 + blocks_len + 3));
    const unm_addr: u16 = sig_addr + 19;
    const mar_addr: u16 = unm_addr + 21;
    const dp_base: u16 = if (res.stats.d_moved) 0x3000 else 0;

    // Stubs (and, for pointer routines, the SA-1's rewritten body copy)
    // plus their call-site rewrites.
    var leaf_i: u32 = 0;
    var ptr_cur: u32 = ptr_base;
    for (chosen[0..n], 0..) |*c, i| {
        const id: u8 = @intCast(i + 1);
        switch (c.kind) {
            .leaf => {
                var stub = stub_template;
                stub[stub_id_send_off] = id;
                stub[stub_id_cmp_off] = id;
                @memcpy(out[base + leaf_i * stub_template.len ..][0..stub_template.len], &stub);
                const stub_addr: u16 = 0x8000 + @as(u16, @intCast(base + leaf_i * stub_template.len));
                leaf_i += 1;
                res.stats.offload_sites += rewriteCallSites(out, usage, c.entry, 0x20, stub_addr, 0);
            },
            .ptr => {
                // The async variant carves its fence first, so the stub can
                // JSL it by the address just decided.
                if (c.is_async) {
                    const fence_file = ptr_cur;
                    const flen = emitFence(out[fence_file..], c.spec);
                    std.debug.assert(flen == fenceLen(c.spec));
                    ptr_cur += flen;
                    res.stats.async_entry = c.entry;
                    res.stats.async_fence = @as(u24, @intCast(fence_file / 0x8000)) << 16 |
                        @as(u24, @intCast(0x8000 + (fence_file % 0x8000)));
                }
                const stub_file = ptr_cur;
                const emitted = if (c.is_async)
                    emitAsyncStub(out[stub_file..], res.stats.async_fence, id, c.entry, c.spec)
                else
                    emitPtrStub(out[stub_file..], id, c.entry, c.spec, c.runs);
                std.debug.assert(emitted == if (c.is_async) asyncStubLen(c.spec) else ptrStubLen(c.spec, c.runs));
                ptr_cur += emitted;
                // The SA-1's copies of the TREE, immediately after the
                // stub — the root first, so the dispatcher's JSL lands on
                // it. In each copy the DB idiom's and the long-WRAM
                // operands' bank bytes become the shadow bank, intra-
                // member JMP targets are re-based, and member-to-member
                // JSLs are re-pointed at the copies. The ORIGINAL bodies
                // stay untouched for unseen S-CPU callers.
                const copy_file = ptr_cur;
                var member_copy: [ptr_tree_cap]u32 = undefined;
                for (c.spec.members[0..c.spec.n_members], 0..) |m, mi| {
                    member_copy[mi] = ptr_cur;
                    @memcpy(out[ptr_cur..][0..m.span], out[m.entry - 0x8000 ..][0..m.span]);
                    ptr_cur += m.span;
                }
                for (c.spec.members[0..c.spec.n_members], 0..) |m, mi| {
                    const m_file: u32 = m.entry - 0x8000;
                    for (c.spec.db_sites[0..c.spec.n_db]) |site| {
                        if (site < m_file or site - m_file >= m.span) continue;
                        std.debug.assert(out[member_copy[mi] + (site - m_file)] == 0x7E);
                        out[member_copy[mi] + (site - m_file)] = shadow_bank;
                        // Residency: the ORIGINAL body's data bank moves
                        // too, so the S-CPU's own calls — including the
                        // sibling entry points that were never re-pointed
                        // — address the one BW-RAM copy rather than a
                        // stale WRAM one. That is the whole difference
                        // between residency and marshalling: one copy,
                        // nothing to synchronise. (Idempotent: a site
                        // shared by overlapping members rewrites once.)
                        if (c.resident and out[site] == 0x7E) out[site] = shadow_bank;
                    }
                    for (c.spec.wram_long_sites[0..c.spec.n_wram_long]) |site| {
                        if (site < m_file or site - m_file >= m.span) continue;
                        out[member_copy[mi] + (site - m_file)] = shadow_bank;
                        if (c.resident and (out[site] == 0x7E or (out[site] & 0x7F) <= 0x3F))
                            out[site] = shadow_bank;
                    }
                    fixupJmps(out, usage, m.entry, m.span, member_copy[mi], @intCast(0x8000 + (member_copy[mi] % 0x8000)));
                    rebaseTreeJsls(out, usage, &c.spec, m.entry, m.span, member_copy[mi], &member_copy);
                }
                if (c.resident) res.stats.resident_offloads += 1;
                c.copy_bank = @intCast(copy_file / 0x8000);
                c.copy_addr = @intCast(0x8000 + (copy_file % 0x8000));
                res.stats.offload_copy[i] = @as(u24, c.copy_bank) << 16 | c.copy_addr;
                res.stats.offload_copy_len[i] = c.spec.total_span;
                const stub_bank: u8 = @intCast(stub_file / 0x8000);
                const stub_addr: u16 = @intCast(0x8000 + (stub_file % 0x8000));
                res.stats.offload_sites += rewriteCallSites(out, usage, c.entry, 0x22, stub_addr, stub_bank);
                res.stats.pointer_offloads += 1;
                res.stats.marshal_siblings += c.siblings;
                for (0..c.runs.n) |r| res.stats.marshal_bytes += @as(u32, c.runs.len[r]) * 256 * 2;
            },
        }
    }

    // The dispatcher, emitted around the computed addresses.
    const d = out[base + leaf_stubs * @as(u32, stub_template.len) ..];
    var cur: usize = 0;
    // Prologue: gates, the shadow window (CBM block 16 = linear $20000,
    // the $7E shadow's first 8 KiB, for pointer routines' dp), native
    // mode, stack under the mailbox, D.
    put(d, &cur, &.{ 0x78, 0xA9, 0xFF, 0x8D, 0x2A, 0x22, 0xA9, 0x80, 0x8D, 0x27, 0x22, 0xA9, 0x08, 0x8D, 0x25, 0x22, 0x18, 0xFB, 0xC2, 0x10, 0xA2, 0x78, 0x37, 0x9A, 0xF4, @truncate(dp_base), @truncate(dp_base >> 8), 0x2B });
    // loop: wait for a nonzero message, park its id at $3787.
    put(d, &cur, &.{ 0xE2, 0x20, 0xAD, 0x01, 0x23, 0x29, 0x0F, 0xF0, 0xF7, 0x8D, 0x87, 0x37 });
    for (chosen[0..n], 0..) |c, i| {
        const id: u8 = @intCast(i + 1);
        switch (c.kind) {
            // CMP #id / BNE +12 / JSR unm / JSR entry / JSR mar / JMP sig.
            .leaf => {
                put(d, &cur, &.{ 0xC9, id, 0xD0, 0x0C });
                putJsr(d, &cur, unm_addr);
                putJsr(d, &cur, c.entry);
                putJsr(d, &cur, mar_addr);
                put(d, &cur, &.{ 0x4C, @truncate(sig_addr), @truncate(sig_addr >> 8) });
            },
            // Pointer block: same shape with D swapped to $6000 around a
            // JSL of the SA-1's body copy (which returns RTL), then back
            // to the base D.
            .ptr => {
                put(d, &cur, &.{ 0xC9, id, 0xD0, 0x1D });
                // D = $6000 + the caller's own D, so every dp operand in
                // the body lands on that page's mirror in the shadow.
                // Set before the unmarshal, whose PLP restores the entry
                // widths last.
                // SEP #$20 again before the unmarshal: it assembles B:A
                // bytewise and pairs PHA with PLP, so it must run 8-bit.
                put(d, &cur, &.{ 0xC2, 0x20, 0xAD, 0x88, 0x37, 0x18, 0x69, 0x00, 0x60, 0x5B, 0xE2, 0x20 });
                putJsr(d, &cur, unm_addr);
                put(d, &cur, &.{ 0x22, @truncate(c.copy_addr), @truncate(c.copy_addr >> 8), c.copy_bank });
                put(d, &cur, &.{ 0xF4, @truncate(dp_base), @truncate(dp_base >> 8), 0x2B });
                putJsr(d, &cur, mar_addr);
                put(d, &cur, &.{ 0x4C, @truncate(sig_addr), @truncate(sig_addr >> 8) });
            },
        }
    }
    // Unknown id: back to the loop.
    put(d, &cur, &.{ 0x4C, @truncate(loop_addr), @truncate(loop_addr >> 8) });
    // sig: echo the id as the done message, await the ack, clear, loop.
    put(d, &cur, &.{ 0xAD, 0x87, 0x37, 0x8D, 0x09, 0x22, 0xAD, 0x01, 0x23, 0x29, 0x0F, 0xD0, 0xF9, 0x9C, 0x09, 0x22, 0x4C, @truncate(loop_addr), @truncate(loop_addr >> 8) });
    // unm: caller P staged, registers in, PLP last (sets the entry widths).
    put(d, &cur, &.{ 0xAD, 0x86, 0x37, 0x48, 0xAD, 0x81, 0x37, 0xEB, 0xAD, 0x80, 0x37, 0xC2, 0x10, 0xAE, 0x82, 0x37, 0xAC, 0x84, 0x37, 0x28, 0x60 });
    // mar: exit P captured first, registers out.
    put(d, &cur, &.{ 0x08, 0xC2, 0x10, 0x8E, 0x82, 0x37, 0x8C, 0x84, 0x37, 0xE2, 0x20, 0x8D, 0x80, 0x37, 0xEB, 0x8D, 0x81, 0x37, 0xEB, 0x68, 0x8D, 0x86, 0x37, 0x60 });
    std.debug.assert(cur == disp_len);

    res.stats.offloaded = chosen[0].entry;
    res.stats.offload_count = @intCast(n);
    for (chosen[0..n], 0..) |c, i| {
        res.stats.offload_entries[i] = c.entry;
        if (c.kind == .ptr) res.stats.offload_ptr_mask |= @as(u8, 1) << @intCast(i);
    }
    crv.* = disp_addr;
}

/// Highest I-RAM byte carrying LIVE relocated state (a clean region with at
/// least one rewritten site, or the moved dp window).
pub fn iramLive(plan: *const profile.Plan, res: *const Result) u32 {
    var live: u32 = 0;
    for (plan.regions[0..plan.n], 0..) |r, ri| {
        if (res.fate[ri] != .clean or r.dest != .iram) continue;
        if (res.region_sites[ri] == 0 and !(r.dp and res.stats.d_moved)) continue;
        live = @max(live, r.dest_off + r.len);
    }
    return live;
}

/// Highest BW-RAM byte carrying live relocated state, for the shadow guard.
pub fn bwramLive(plan: *const profile.Plan, res: *const Result) u32 {
    var live: u32 = 0;
    for (plan.regions[0..plan.n], 0..) |r, ri| {
        if (res.fate[ri] != .clean or r.dest != .bwram) continue;
        if (res.region_sites[ri] == 0) continue;
        live = @max(live, r.dest_off + r.len);
    }
    return live;
}

/// Does any executed instruction OUTSIDE [entry, entry+span) statically
/// name a byte of `pages` (excluding the direct page, which never becomes
/// resident)? Long and low-mirror-absolute operands are the forms that
/// name WRAM without depending on a runtime register, so they are exactly
/// the references that would break if the bytes moved to BW-RAM.
pub fn namedOutside(
    out: []const u8,
    usage: []const u8,
    spec: *const PtrSpec,
    pages: profile.WramPages,
    dp_page: u16,
) bool {
    var bank: u32 = 0;
    while (bank < 0x40) : (bank += 1) {
        const bank_file = bank * 0x8000;
        if (bank_file >= out.len) break;
        var a16: u32 = 0x8000;
        while (a16 < 0x10000) : (a16 += 1) {
            const cpu_addr = (bank << 16) | a16;
            const fl = usage[cpu_addr] | usage[0x80_0000 | cpu_addr];
            if (fl & usage_map.flag_opcode == 0) continue;
            // Inside the tree's own bodies: their accesses are the ones
            // the data-bank rewrite re-points.
            if (bank == 0) {
                const in_tree = for (spec.members[0..spec.n_members]) |m| {
                    if (a16 >= m.entry and a16 - m.entry < m.span) break true;
                } else false;
                if (in_tree) continue;
            }
            const file = bank_file + (a16 - 0x8000);
            if (file + 4 > out.len) continue;
            const op = out[file];
            const wram_off: u32 = switch (usage_map.mode(op)) {
                .abs, .abs_x, .abs_y => blk: {
                    const v = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                    if (v >= 0x2000) continue;
                    break :blk v;
                },
                .long, .long_x => blk: {
                    const b = out[file + 3];
                    const v = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                    if (b == 0x7E) break :blk v;
                    if (b == 0x7F) break :blk 0x10000 + @as(u32, v);
                    if ((b & 0x7F) <= 0x3F and v < 0x2000) break :blk v;
                    continue;
                },
                else => continue,
            };
            const pg: u16 = @intCast(wram_off >> 8);
            if (pg != dp_page and profile.getPage(pages, pg)) return true;
        }
    }
    return false;
}

/// Re-base intra-span JMP abs targets in a pointer routine's copy. All
/// other flow in the span is relative (branches, BRL) and relocates for
/// free; the eligibility walk refused everything else.
pub fn fixupJmps(out: []u8, usage: []const u8, entry: u16, span: u32, copy_file: u32, copy_addr: u16) void {
    var pc: u32 = entry;
    while (pc - entry < span) {
        if (usage[pc] & usage_map.flag_opcode == 0) {
            pc += 1;
            continue;
        }
        const file = pc - 0x8000;
        const op = out[file];
        const m8 = usage[pc] & usage_map.flag_m != 0;
        const x8 = usage[pc] & usage_map.flag_x != 0;
        if (op == 0x4C) {
            const t = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
            const rebased: u16 = copy_addr + (t - entry);
            std.mem.writeInt(u16, out[copy_file + (pc - entry) + 1 ..][0..2], rebased, .little);
        }
        pc += usage_map.instrLen(op, m8, x8);
    }
}

/// Re-point member-to-member JSLs inside one member's COPY at the other
/// members' copies. The eligibility walk proved every JSL in the span
/// targets a tree member, so this scan is exhaustive by construction.
pub fn rebaseTreeJsls(
    out: []u8,
    usage: []const u8,
    spec: *const PtrSpec,
    entry: u16,
    span: u32,
    copy_file: u32,
    member_copy: *const [ptr_tree_cap]u32,
) void {
    var pc: u32 = entry;
    while (pc - entry < span) {
        if (usage[pc] & usage_map.flag_opcode == 0) {
            pc += 1;
            continue;
        }
        const file = pc - 0x8000;
        const op = out[file];
        const m8 = usage[pc] & usage_map.flag_m != 0;
        const x8 = usage[pc] & usage_map.flag_x != 0;
        if (op == 0x22 and out[file + 3] == 0x00) {
            const tgt = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
            for (spec.members[0..spec.n_members], 0..) |m, mj| {
                if (m.entry != tgt) continue;
                const dst = copy_file + (pc - entry);
                std.mem.writeInt(u16, out[dst + 1 ..][0..2], @intCast(0x8000 + (member_copy[mj] % 0x8000)), .little);
                out[dst + 3] = @intCast(member_copy[mj] / 0x8000);
                break;
            }
        }
        pc += usage_map.instrLen(op, m8, x8);
    }
}

pub fn dropPtr(chosen: *[offload_max]Chosen, n: *usize) void {
    var w: usize = 0;
    for (chosen[0..n.*]) |c| {
        if (c.kind == .leaf) {
            chosen[w] = c;
            w += 1;
        }
    }
    n.* = w;
}

pub fn put(d: []u8, cur: *usize, bytes: []const u8) void {
    @memcpy(d[cur.*..][0..bytes.len], bytes);
    cur.* += bytes.len;
}

pub fn putJsr(d: []u8, cur: *usize, target: u16) void {
    put(d, cur, &.{ 0x20, @truncate(target), @truncate(target >> 8) });
}

/// Count executed call sites of `entry` (bank $00): `op` is 0x20 (JSR,
/// scanned in bank $00 — a JSR's target shares the caller's bank) or 0x22
/// (JSL with an explicit bank-$00 target, scanned across every bank,
/// executed flags merged over the $80+ fast mirrors).
pub fn countCallSites(out: []const u8, usage: []const u8, entry: u16, op: u8) u32 {
    return callSites(out, null, usage, entry, op, 0, 0);
}

/// Re-point every executed call site of `entry` at the stub. JSR sites take
/// a 16-bit target (stub in bank $00); JSL sites take the full 24-bit stub
/// address. Returns the number rewritten.
pub fn rewriteCallSites(out: []u8, usage: []const u8, entry: u16, op: u8, stub_addr: u16, stub_bank: u8) u32 {
    return callSites(out, out, usage, entry, op, stub_addr, stub_bank);
}

pub fn callSites(ro: []const u8, rw: ?[]u8, usage: []const u8, entry: u16, op: u8, stub_addr: u16, stub_bank: u8) u32 {
    var count: u32 = 0;
    const bank_top: u32 = if (op == 0x20) 1 else 0x40;
    var bank: u32 = 0;
    while (bank < bank_top) : (bank += 1) {
        const bank_file = bank * 0x8000;
        if (bank_file >= ro.len) break;
        var a16: u32 = 0x8000;
        while (a16 < 0x10000) : (a16 += 1) {
            const cpu_addr = (bank << 16) | a16;
            if ((usage[cpu_addr] | usage[0x80_0000 | cpu_addr]) & usage_map.flag_opcode == 0) continue;
            const file = bank_file + (a16 - 0x8000);
            if (ro[file] != op) continue;
            if (std.mem.readInt(u16, ro[file + 1 ..][0..2], .little) != entry) continue;
            if (op == 0x22 and ro[file + 3] != 0x00) continue;
            if (rw) |w| {
                std.mem.writeInt(u16, w[file + 1 ..][0..2], stub_addr, .little);
                if (op == 0x22) w[file + 3] = stub_bank;
            }
            count += 1;
        }
    }
    return count;
}

/// Static pointer-eligibility walk: a JSL/RTL routine whose data flows
/// through dp cells and runtime pointers, offloadable as COMPUTE against
/// the BW-RAM shadow of its profiled working set. The walk proves what it
/// can (return shape, span containment, no MMIO/stack-relative sites, the
/// DB idiom, the long-pointer bank slots); the pointer VALUES are dynamic
/// evidence — anything they reach outside the marshalled shadow diverges
/// in S4 verification and no patch ships. Refusal here is a skip, not an
/// error: the routine simply stays on the S-CPU.
///
/// The walk covers a CALL TREE: a JSL to a bank-$00 target makes that
/// target a member, walked by the same rules and copied alongside the
/// root. Absolute (DB-relative) operands are allowed while the data bank
/// is PINNED by an immediate LDA #bank / PHA / PLB — tracked linearly,
/// which matches the idiom's real use (pin once up front, restore at the
/// end); a backward branch across a re-pin is dynamic evidence like the
/// rest. Long WRAM operands are recorded as bank-byte rewrite sites: the
/// shadow is identity-offset, so only the bank byte changes in the copy.
pub fn eligiblePointer(out: []const u8, usage: []const u8, entry: u16) ?PtrSpec {
    var spec: PtrSpec = .{};
    var has_idp = false;
    spec.members[0] = .{ .entry = entry, .span = 0, .pin = null, .conflict = false };
    spec.n_members = 1;
    var walked: usize = 0;
    while (walked < spec.n_members) : (walked += 1) {
        if (!walkMember(out, usage, &spec, walked, &has_idp)) {
            if (dbg_walk_root != 0 and entry == dbg_walk_root)
                std.debug.print("[walk] root {x:0>4}: member {} (${x:0>4}) refused\n", .{ entry, walked, spec.members[walked].entry });
            return null;
        }
    }
    // A member validated under an inherited pin that a LATER call site
    // contradicts was validated on a false premise.
    for (spec.members[0..spec.n_members]) |m| if (m.conflict) return null;
    if (has_idp and spec.n_db == 0) return null;
    spec.span = spec.members[0].span;
    spec.total_span = 0;
    for (spec.members[0..spec.n_members]) |m| spec.total_span += m.span;
    if (spec.total_span > ptr_tree_span_max) return null;
    // Helper privacy (an ASYNC-only requirement, recorded for the gate):
    // every executed JSL site of every helper lies inside the tree.
    for (spec.members[1..spec.n_members]) |m| {
        if (!jslSitesInsideTree(out, usage, &spec, m.entry)) {
            spec.helpers_private = false;
            break;
        }
    }
    return spec;
}

/// Walk diagnostics: set to a root entry to print why the offload gates
/// skip it (walk refusal per member, residency's shared/DMA page, the
/// marshal economics). Zero compiles every print away.
pub const dbg_walk_root: u16 = 0;

pub fn walkMember(out: []const u8, usage: []const u8, spec: *PtrSpec, mi: usize, has_idp: *bool) bool {
    const span_max: u32 = 1024;
    const entry: u32 = spec.members[mi].entry;
    const dbg = dbg_walk_root != 0 and spec.members[0].entry == dbg_walk_root;
    var pc: u32 = entry;
    var limit: u32 = entry;
    // The pinned data bank, if an LDA #imm / PHA / PLB executed and no
    // later PLB unpinned it. Tracked linearly. A helper starts with the
    // pin it INHERITS from its tree call sites (see PtrSpec.members).
    var db_pin: ?u8 = spec.members[mi].pin;
    while (pc - entry < span_max) {
        if (pc > 0xFFFF) return false;
        if (usage[pc] & usage_map.flag_opcode == 0) {
            // A gap (data or never-taken padding) is fine while pending
            // flow still reaches past it; a gap at the frontier is not.
            if (pc >= limit) return false;
            pc += 1;
            continue;
        }
        const file = pc - 0x8000;
        const op = out[file];
        const m8 = usage[pc] & usage_map.flag_m != 0;
        const x8 = usage[pc] & usage_map.flag_x != 0;
        const len = usage_map.instrLen(op, m8, x8);
        if (dbg) std.debug.print("  [walk] {x:0>4}: {x:0>2} pin={?x}\n", .{ pc, op, db_pin });
        switch (op) {
            0x6B => { // RTL: done once every pending path has closed
                if (pc >= limit) {
                    spec.members[mi].span = pc + 1 - entry;
                    return true;
                }
            },
            0x22 => { // JSL: a bank-$00 target joins the tree
                if (out[file + 3] != 0x00) return false;
                const tgt = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                if (tgt < 0x8000) return false;
                const existing: ?usize = for (spec.members[0..spec.n_members], 0..) |m, j| {
                    if (m.entry == tgt) break j;
                } else null;
                if (existing) |j| {
                    // A second call site with a different pin invalidates
                    // whatever the member's walk assumed.
                    if (!std.meta.eql(spec.members[j].pin, db_pin)) spec.members[j].conflict = true;
                } else {
                    if (spec.n_members == ptr_tree_cap) return false;
                    spec.members[spec.n_members] = .{ .entry = tgt, .span = 0, .pin = db_pin, .conflict = false };
                    spec.n_members += 1;
                }
            },
            // Wrong return shape, near calls, far jumps, block moves,
            // interrupt-adjacent, D/S relocation: not this routine.
            0x60, 0x40, 0x20, 0xFC, 0x5C, 0x6C, 0x7C, 0xDC => return false,
            0x00, 0x02, 0xCB, 0xDB, 0x44, 0x54 => return false,
            0x2B, 0x5B, 0x1B, 0x9A, 0xFB, 0x58 => return false,
            0x4C, 0x82, 0x80 => { // JMP abs / BRL / BRA: intra-member only
                const dst: u32 = switch (op) {
                    0x4C => std.mem.readInt(u16, out[file + 1 ..][0..2], .little),
                    0x82 => pc + 3 +% @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(std.mem.readInt(u16, out[file + 1 ..][0..2], .little)))))),
                    else => pc + 2 +% @as(u32, @bitCast(@as(i32, @as(i8, @bitCast(out[file + 1]))))),
                };
                if (dst < entry or dst - entry >= span_max) return false;
                limit = @max(limit, dst);
                // An unconditional BACKWARD transfer at the frontier
                // closes the member like an RTL: no pending path reaches
                // past it, and the loop it forms stays inside the span.
                if (dst <= pc and pc >= limit) {
                    spec.members[mi].span = pc + len - entry;
                    return true;
                }
            },
            0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0 => {
                const dst = pc + 2 +% @as(u32, @bitCast(@as(i32, @as(i8, @bitCast(out[file + 1])))));
                if (dst < entry or dst - entry >= span_max) return false;
                limit = @max(limit, dst);
            },
            0xA9 => if (m8) {
                const imm = out[file + 1];
                if (file + 3 < out.len and out[file + 2] == 0x48 and out[file + 3] == 0xAB) {
                    // LDA #imm / PHA / PLB pins the data bank. #$7E is
                    // the shadow's rewrite point and gets recorded; any
                    // other immediate is a pin the walk merely tracks.
                    db_pin = imm;
                    if (imm == 0x7E) {
                        // Overlapping members walk shared tails twice;
                        // record each site once.
                        const dup = for (spec.db_sites[0..spec.n_db]) |s| {
                            if (s == file + 1) break true;
                        } else false;
                        if (!dup) {
                            if (spec.n_db == ptr_db_cap) return false;
                            spec.db_sites[spec.n_db] = file + 1;
                            spec.n_db += 1;
                        }
                    }
                } else if (imm == 0x7E) {
                    // A bare #$7E has an unknowable purpose — refuse.
                    return false;
                }
            },
            0xAB => {
                // A PLB outside the idiom restores a pushed bank the walk
                // cannot see: unpinned from here on.
                if (file < 3 or out[file - 3] != 0xA9 or out[file - 1] != 0x48) db_pin = null;
            },
            else => {},
        }
        // Long-indirect pointers ([dp] / [dp],y, the $x7 column): the bank
        // byte at dp+2 is a translation slot ($7E/$7F -> shadow).
        if (op & 0x0F == 0x07) {
            const slot: u16 = @as(u16, out[file + 1]) + 2;
            if (slot > 0xFF) return false; // bank byte past the dp window
            const dup = for (spec.slots[0..spec.n_slots]) |s| {
                if (s == slot) break true;
            } else false;
            if (!dup) {
                if (spec.n_slots == ptr_slot_cap) return false;
                spec.slots[spec.n_slots] = @intCast(slot);
                spec.n_slots += 1;
            }
        }
        // 16-bit-indirect pointers ((dp) / (dp),y) resolve with DB: only
        // sound once the DB idiom pins it to the shadow. (dp,x) hides the
        // pointer cell behind a runtime index; stack-relative reads the
        // S-CPU stack the SA-1 does not have.
        if (op & 0x1F == 0x11 or op & 0x1F == 0x12) has_idp.* = true;
        if (op & 0x1F == 0x01 or op & 0x0F == 0x03) return false;
        switch (usage_map.mode(op)) {
            .none, .dp => {},
            // dp,X/dp,Y: a runtime index that can leave the shadow's dp
            // window (8 KiB under D=$6000). Statically unprovable — but
            // the pointer path runs on dynamic evidence: an index that
            // actually left the marshalled shadow reads ROM instead of
            // state, diverges in S4 verification, and no patch ships.
            .dp_idx => {},
            // DB-relative: allowed exactly while the idiom pins the bank.
            // Pinned $7E is WRAM top to bottom — the rewritten idiom
            // re-points every one of these at the shadow. A pinned ROM
            // bank reads identically on both CPUs above $8000; below it
            // the banks diverge (S-CPU mirrors, SA-1 I-RAM), so refuse.
            .abs, .abs_x, .abs_y => {
                const b = db_pin orelse return false;
                if (b == 0x7E) {
                    // follows the rewritten DB into the shadow
                } else if ((b <= 0x3F or (b >= 0x80 and b != 0x7F)) and
                    std.mem.readInt(u16, out[file + 1 ..][0..2], .little) >= 0x8000)
                {
                    // ROM through a pinned bank: same bytes on both CPUs
                } else return false;
            },
            .long, .long_x => {
                const b = out[file + 3];
                const a16 = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                // ROM and BW-RAM read identically on the SA-1. Long WRAM
                // becomes a bank-byte rewrite to the identity-offset
                // shadow: $7E:xxxx directly, and a $00-$3F bank's low 8K
                // is the same bytes through the mirror. $7F and MMIO
                // cannot follow execution across.
                if (b == 0x7E or ((b & 0x7F) <= 0x3F and a16 < 0x2000 and usage_map.mode(op) == .long)) {
                    // The system-bank low-mirror form only counts when
                    // UNINDEXED: with an index the same base can walk a
                    // ROM table ($01:0000,X in Gradius III's sound code),
                    // and re-banking it would read the wrong ROM. $7E is
                    // unambiguous either way.
                    const dup = for (spec.wram_long_sites[0..spec.n_wram_long]) |s| {
                        if (s == file + 3) break true;
                    } else false;
                    if (!dup) {
                        if (spec.n_wram_long == ptr_wram_long_cap) return false;
                        spec.wram_long_sites[spec.n_wram_long] = file + 3;
                        spec.n_wram_long += 1;
                    }
                } else if ((b >= 0x40 and b <= 0x4F) or b >= 0xC0 or
                    ((b & 0x7F) <= 0x3F and a16 >= 0x8000))
                {
                    // ROM / BW-RAM: fine as-is
                } else return false;
            },
        }
        pc += len;
    }
    return false;
}

/// Are all executed JSL call sites of `entry` inside the tree's spans?
pub fn jslSitesInsideTree(out: []const u8, usage: []const u8, spec: *const PtrSpec, entry: u16) bool {
    var bank: u32 = 0;
    while (bank < 0x40) : (bank += 1) {
        const bank_file = bank * 0x8000;
        if (bank_file >= out.len) break;
        var a16: u32 = 0x8000;
        while (a16 < 0x10000) : (a16 += 1) {
            const cpu_addr = (bank << 16) | a16;
            if ((usage[cpu_addr] | usage[0x80_0000 | cpu_addr]) & usage_map.flag_opcode == 0) continue;
            const file = bank_file + (a16 - 0x8000);
            if (out[file] != 0x22) continue;
            if (std.mem.readInt(u16, out[file + 1 ..][0..2], .little) != entry) continue;
            if (out[file + 3] != 0x00) continue;
            const inside = bank == 0 and for (spec.members[0..spec.n_members]) |m| {
                if (a16 >= m.entry and a16 - m.entry < m.span) break true;
            } else false;
            if (!inside) return false;
        }
    }
    return true;
}

/// Byte-exact length of a pointer stub (the emitter asserts against it).
pub fn ptrStubLen(spec: PtrSpec, runs: Runs) u32 {
    return 151 + 24 * @as(u32, @intCast(runs.n)) + 54 * @as(u32, @intCast(spec.n_slots));
}

/// The S-CPU side of a pointer offload, emitted per routine. Everything is
/// long-addressed (mailbox, message ports, shadow) so the stub is correct
/// under ANY caller data bank and may itself live in any ROM bank — which
/// is also why JSL sites can reach it with a 24-bit rewrite. Sequence:
/// marshal registers -> copy the working set into the shadow (MVN) ->
/// translate the long-pointer bank slots ($7E/$7F -> $42/$43) -> send the
/// message id and spin the double handshake -> translate back -> copy the
/// shadow back -> restore DB -> unmarshal with the routine's exit state ->
/// RTL.
pub fn emitPtrStub(d: []u8, id: u8, entry: u16, spec: PtrSpec, runs: Runs) u32 {
    var cur: usize = 0;
    // Precondition, checked rather than assumed: the marshal mirrors the
    // caller's direct page at WRAM $0000-$00FF into the shadow, and the
    // SA-1 runs the body with D over that mirror. A caller whose D is
    // something else would have the SA-1 resolve dp operands to the wrong
    // shadow bytes, so this hands such a call straight back to the
    // ORIGINAL routine on the S-CPU — always correct, merely not
    // accelerated. (JML, not JSL: the original's own RTL returns to our
    // caller.)
    put(d, &cur, &.{
        0x08, // PHP
        0xC2, 0x20, // REP #$20
        0x48, // PHA
        0x0B, 0x68, // PHD / PLA  -> A = caller D
        0xC9, 0x01, 0x1F, // CMP #$1F01
        0x90, 0x06, // BCC ok  (a whole dp page fits the 8 KiB window)
        0x68, 0x28, // PLA / PLP  (restore exactly what we found)
        0x5C, @truncate(entry), @truncate(entry >> 8), 0x00, // JML original
        // ok:
        0x8F, 0x88, 0x37, 0x00, // STA $00:3788 — caller D into the mailbox
        0x68, 0x28, // PLA / PLP
    });
    // Register marshal in (33). PHB first so the caller P (pushed second)
    // is on top for the PLA below.
    put(d, &cur, &.{ 0x8B, 0x08, 0xE2, 0x20 }); // PHB / PHP / SEP #$20
    put(d, &cur, &.{ 0x8F, 0x80, 0x37, 0x00, 0xEB, 0x8F, 0x81, 0x37, 0x00, 0xEB }); // A low, B
    put(d, &cur, &.{ 0xC2, 0x30, 0x8A, 0x8F, 0x82, 0x37, 0x00, 0x98, 0x8F, 0x84, 0x37, 0x00 }); // X, Y via A
    put(d, &cur, &.{ 0xE2, 0x20, 0x68, 0x8F, 0x86, 0x37, 0x00 }); // caller P
    // Shadow copy-in (2 + 12/run). MVN encoding: opcode, DEST bank, SRC bank.
    put(d, &cur, &.{ 0xC2, 0x30 });
    // The caller's direct page, wherever it is: MVN takes its offsets
    // from X/Y, so one emitted copy serves every D the guard admits.
    put(d, &cur, &.{ 0xAF, 0x88, 0x37, 0x00, 0xAA, 0xA8, 0xA9, 0xFF, 0x00, 0x54, shadow_bank, 0x7E });
    for (0..runs.n) |r| putMvnRun(d, &cur, runs.start[r], runs.len[r], false);
    // Slot translate-in: $7E pointer bank bytes -> the shadow bank. The
    // slots are DIRECT-PAGE offsets, so each is indexed by the caller's
    // own D — the pointers live wherever its direct page is, not at
    // $0000. (A plain LoROM game has no $40+ pointers to collide with
    // the exact compare; $7F pointers stay untranslated and fail S4 if
    // followed.)
    for (spec.slots[0..spec.n_slots]) |s| {
        put(d, &cur, &.{
            0xAF, 0x88, 0x37, 0x00, // LDA $00:3788  (caller D)
            0x18, 0x69, s, 0x00, // CLC / ADC #slot
            0xAA, // TAX
            0xE2, 0x20, // SEP #$20
            0xBF, 0x00, 0x00, shadow_bank, // LDA $41:0000,x
            0xC9, 0x7E, // CMP #$7E
            0xD0, 0x06, // BNE skip
            0xA9, shadow_bank, // LDA #$41
            0x9F, 0x00, 0x00, shadow_bank, // STA $41:0000,x
            0xC2, 0x20, // skip: REP #$20
        });
    }
    put(d, &cur, &.{ 0xE2, 0x20 });
    // Send + double handshake (30), all long-addressed.
    put(d, &cur, &.{ 0xA9, id, 0x8F, 0x00, 0x22, 0x00 }); // message id -> CFR
    put(d, &cur, &.{ 0xAF, 0x00, 0x23, 0x00, 0x29, 0x0F, 0xC9, id, 0xD0, 0xF6 }); // await echo
    put(d, &cur, &.{ 0xA9, 0x00, 0x8F, 0x00, 0x22, 0x00 }); // ack
    put(d, &cur, &.{ 0xAF, 0x00, 0x23, 0x00, 0x29, 0x0F, 0xD0, 0xF8 }); // await clear
    // Slot translate-back, indexed the same way.
    put(d, &cur, &.{ 0xC2, 0x20 });
    for (spec.slots[0..spec.n_slots]) |s| {
        put(d, &cur, &.{
            0xAF,        0x88, 0x37,        0x00,
            0x18,        0x69, s,           0x00,
            0xAA,        0xE2, 0x20,        0xBF,
            0x00,        0x00, shadow_bank, 0xC9,
            shadow_bank, 0xD0, 0x06,        0xA9,
            0x7E,        0x9F, 0x00,        0x00,
            shadow_bank, 0xC2, 0x20,
        });
    }
    put(d, &cur, &.{ 0xE2, 0x20 });
    // Shadow copy-out (2 + 12/run).
    put(d, &cur, &.{ 0xC2, 0x30 });
    put(d, &cur, &.{ 0xAF, 0x88, 0x37, 0x00, 0xAA, 0xA8, 0xA9, 0xFF, 0x00, 0x54, 0x7E, shadow_bank });
    for (0..runs.n) |r| putMvnRun(d, &cur, runs.start[r], runs.len[r], true);
    // Restore caller DB, then unmarshal — long-addressed, so DB-proof (30).
    put(d, &cur, &.{0xAB}); // PLB
    put(d, &cur, &.{ 0xC2, 0x30, 0xAF, 0x82, 0x37, 0x00, 0xAA, 0xAF, 0x84, 0x37, 0x00, 0xA8 }); // X, Y
    put(d, &cur, &.{ 0xE2, 0x20, 0xAF, 0x86, 0x37, 0x00, 0x48 }); // exit P staged
    put(d, &cur, &.{ 0xAF, 0x81, 0x37, 0x00, 0xEB, 0xAF, 0x80, 0x37, 0x00 }); // B, A low
    put(d, &cur, &.{ 0x28, 0x6B }); // PLP (exit flags/widths) / RTL
    return @intCast(cur);
}

/// Byte-exact length of the shared async fence (the emitter asserts).
pub fn fenceLen(spec: PtrSpec) u32 {
    _ = spec;
    return 41;
}

/// The asynchronous offload's fence: complete the handshake of a
/// fire-and-forget call so the mailbox and message ports free up. Nothing
/// is copied back — that is the async CONTRACT, not a shortcut: the
/// routine's register results are dropped, and so are its direct-page
/// writes. A deferred whole-page copy-back is unsound against ANY S-CPU
/// dp write between send and fence (measured on a real cart: the NMI
/// fence reverting the APU upload counter mid-handshake wedged the boot).
/// Only effects on BW-RAM-RESIDENT state survive an async call, because
/// both CPUs address that state directly and no copy exists to disagree.
/// Whether any caller needed the dropped effects is exactly what
/// behavioral verification arbitrates.
///
/// JSL-reached and long-addressed, so it works from any bank; the caller
/// has already saved every register it cares about. Idempotent: an NMI
/// can interrupt a fence mid-handshake and run the fence again — the
/// inner call either sees busy already cleared or completes the same
/// handshake, and the outer's remaining reads find the ports quiet.
pub fn emitFence(d: []u8, spec: PtrSpec) u32 {
    _ = spec;
    var cur: usize = 0;
    const body: u32 = 32;
    put(d, &cur, &.{ 0xE2, 0x20 }); // SEP #$20
    put(d, &cur, &.{ 0xAF, 0x8A, 0x37, 0x00 }); // busy id, 0 = idle
    put(d, &cur, &.{ 0xF0, @intCast(body) }); // BEQ done
    // Await the SA-1's done echo of exactly the in-flight id, ack it, and
    // wait for the port to clear — the back half of the handshake the
    // async stub deliberately left unfinished.
    put(d, &cur, &.{ 0xAF, 0x00, 0x23, 0x00, 0x29, 0x0F, 0xCF, 0x8A, 0x37, 0x00, 0xD0, 0xF4 });
    put(d, &cur, &.{ 0xA9, 0x00, 0x8F, 0x00, 0x22, 0x00 });
    put(d, &cur, &.{ 0xAF, 0x00, 0x23, 0x00, 0x29, 0x0F, 0xD0, 0xF8 });
    put(d, &cur, &.{ 0xA9, 0x00, 0x8F, 0x8A, 0x37, 0x00 }); // busy = idle
    put(d, &cur, &.{0x6B}); // done: RTL
    return @intCast(cur);
}

/// The NON-BLOCKING fence, for the NMI prologue. The blocking fence in
/// the NMI moved every in-flight wait into vblank — the one place a
/// wait costs a frame deadline — and the async flavor measured 290
/// dropped frames against sync's 115 doing exactly that. This variant
/// acks a COMPLETED call (the SA-1 answers from its sig-hold loop
/// within microseconds) and SKIPS a still-running one; the next fence
/// point collects it. Only the async stub's own fence must block — it
/// is about to reuse the mailbox.
pub const nb_fence_len: u32 = 39;
pub fn emitNbFence(d: []u8) u32 {
    var cur: usize = 0;
    put(d, &cur, &.{ 0xE2, 0x20 }); // SEP #$20
    put(d, &cur, &.{ 0xAF, 0x8A, 0x37, 0x00 }); // busy id, 0 = idle
    put(d, &cur, &.{ 0xF0, 0x1E }); // BEQ done
    put(d, &cur, &.{ 0xAF, 0x00, 0x23, 0x00, 0x29, 0x0F }); // done echo?
    put(d, &cur, &.{ 0xCF, 0x8A, 0x37, 0x00 });
    put(d, &cur, &.{ 0xD0, 0x12 }); // BNE done — still running, skip
    put(d, &cur, &.{ 0xA9, 0x00, 0x8F, 0x00, 0x22, 0x00 }); // ack
    put(d, &cur, &.{ 0xAF, 0x00, 0x23, 0x00, 0x29, 0x0F, 0xD0, 0xF8 }); // echo clears (bounded: the SA-1 is in its hold loop)
    put(d, &cur, &.{ 0x8F, 0x8A, 0x37, 0x00 }); // busy = idle (A is 0)
    put(d, &cur, &.{0x6B}); // done: RTL
    return @intCast(cur);
}

/// Byte-exact length of an async stub (the emitter asserts).
pub fn asyncStubLen(spec: PtrSpec) u32 {
    return 122 + 27 * @as(u32, @intCast(spec.n_slots));
}

/// The fire-and-forget S-CPU stub for THE async offload: fence first (a
/// previous call may still be in flight — and the D-guard's bail path runs
/// the original body on the S-CPU, which must never race the SA-1 over the
/// resident data), then the synchronous stub's whole front half, then send
/// the message, mark busy, and return with the CALLER's registers — the
/// routine's register results are dropped, which is the async contract;
/// verification arbitrates whether any caller actually needed them.
pub fn emitAsyncStub(d: []u8, fence: u24, id: u8, entry: u16, spec: PtrSpec) u32 {
    var cur: usize = 0;
    // Save the caller's context across the fence, which clobbers freely.
    put(d, &cur, &.{ 0x08, 0xC2, 0x30, 0x48, 0xDA, 0x5A, 0x8B }); // PHP REP PHA PHX PHY PHB
    put(d, &cur, &.{ 0x22, @truncate(fence), @truncate(fence >> 8), @truncate(fence >> 16) });
    // REP #$30 before the pulls: the fence returns with M narrowed (its
    // final SEP #$20), and an 8-bit PLA against the 16-bit PHA above
    // leaves a stray byte that shears the stack — the RTL at the tail
    // would return into hyperspace.
    put(d, &cur, &.{ 0xAB, 0xC2, 0x30, 0x7A, 0xFA, 0x68, 0x28 }); // PLB REP PLY PLX PLA PLP
    // Re-save what the marshal below consumes (its own PHB balances the
    // tail's PLB).
    put(d, &cur, &.{ 0x08, 0xC2, 0x30, 0x48, 0xDA, 0x5A }); // PHP REP PHA PHX PHY
    // D guard, exactly as the sync stub: a caller whose direct page cannot
    // mirror into the shadow window is handed the original body — safe on
    // the S-CPU now, because the fence above drained the SA-1.
    put(d, &cur, &.{
        0x08, 0xC2, 0x20, 0x48, 0x0B, 0x68,
        0xC9, 0x01, 0x1F, // CMP #$1F01
        0x90, 0x0C, // BCC ok
        0x68, 0x28, // PLA / PLP
        0xC2, 0x30, 0x7A, 0xFA, 0x68, 0x28, // unwind the re-save
        0x5C, @truncate(entry), @truncate(entry >> 8), 0x00, // JML original
        // ok:
        0x8F, 0x88, 0x37, 0x00, // caller D -> mailbox
        0x68, 0x28, // PLA / PLP
    });
    // Register marshal into the mailbox (the SA-1's unmarshal input),
    // identical to the sync stub's.
    put(d, &cur, &.{ 0x8B, 0x08, 0xE2, 0x20 });
    put(d, &cur, &.{ 0x8F, 0x80, 0x37, 0x00, 0xEB, 0x8F, 0x81, 0x37, 0x00, 0xEB });
    put(d, &cur, &.{ 0xC2, 0x30, 0x8A, 0x8F, 0x82, 0x37, 0x00, 0x98, 0x8F, 0x84, 0x37, 0x00 });
    // Caller P: NOT the live P (the re-save REP'd it — the sync stub can
    // read its own PHP because nothing widened P before its marshal). The
    // true caller P is the re-save's PHP byte, at a fixed stack depth
    // once our own PHP is pulled: B(1) + Y(2) + X(2) + A(2) above it.
    // Marshalling the REP'd P hands the SA-1 16-bit index width for an
    // 8-bit caller — its immediates then swallow the following opcode.
    put(d, &cur, &.{ 0xE2, 0x20, 0x68, 0xA3, 0x08, 0x8F, 0x86, 0x37, 0x00 });
    // dp page into the shadow (resident routines marshal nothing else).
    put(d, &cur, &.{ 0xC2, 0x30 });
    put(d, &cur, &.{ 0xAF, 0x88, 0x37, 0x00, 0xAA, 0xA8, 0xA9, 0xFF, 0x00, 0x54, shadow_bank, 0x7E });
    // Slot translate-in, as sync.
    for (spec.slots[0..spec.n_slots]) |s| {
        put(d, &cur, &.{
            0xAF,        0x88, 0x37,        0x00,
            0x18,        0x69, s,           0x00,
            0xAA,        0xE2, 0x20,        0xBF,
            0x00,        0x00, shadow_bank, 0xC9,
            0x7E,        0xD0, 0x06,        0xA9,
            shadow_bank, 0x9F, 0x00,        0x00,
            shadow_bank, 0xC2, 0x20,
        });
    }
    put(d, &cur, &.{ 0xE2, 0x20 });
    // Send, mark busy, and DO NOT WAIT — the SA-1's signal loop holds the
    // done echo until the fence acks it. The busy flag lives at $378A,
    // OUTSIDE the caller-D slot ($3788-$3789, which the dispatcher reads
    // 16-bit): a busy byte at $3789 is a +$0100 bias on the SA-1's D.
    put(d, &cur, &.{ 0xA9, id, 0x8F, 0x00, 0x22, 0x00, 0x8F, 0x8A, 0x37, 0x00 });
    // Caller context back (mirrors the re-save; the marshal's PHB pairs
    // with this PLB), and out.
    put(d, &cur, &.{ 0xAB, 0xC2, 0x30, 0x7A, 0xFA, 0x68, 0x28, 0x6B });
    return @intCast(cur);
}

/// One MVN marshal run: pages [start, start+len) of $7E WRAM to/from the
/// identity-offset shadow at bank $41. `back` copies shadow -> WRAM.
pub fn putMvnRun(d: []u8, cur: *usize, start_page: u16, n_pages: u16, back: bool) void {
    const off: u16 = (start_page & 0xFF) << 8;
    const count: u16 = n_pages * 256 - 1;
    const dst: u8 = if (back) 0x7E else shadow_bank;
    const src: u8 = if (back) shadow_bank else 0x7E;
    put(d, cur, &.{ 0xA2, @truncate(off), @truncate(off >> 8) }); // LDX #off (source)
    put(d, cur, &.{ 0xA0, @truncate(off), @truncate(off >> 8) }); // LDY #off (dest, identity)
    put(d, cur, &.{ 0xA9, @truncate(count), @truncate(count >> 8) }); // LDA #count-1
    put(d, cur, &.{ 0x54, dst, src }); // MVN
}

/// Static leaf-eligibility walk from `entry` over covered code: ends at the
/// first RTS; refuses calls, jumps, block moves, interrupts-adjacent opcodes,
/// any data access the SA-1 could not see after the relocation, and branches
/// escaping the span. Returns true when the routine can run on the SA-1.
pub fn eligibleLeaf(out: []const u8, usage: []const u8, plan: *const profile.Plan, res: *const Result, entry: u16) bool {
    const span_max: u32 = 512;
    var pc: u32 = entry;
    var max_branch: u32 = 0;
    while (pc - entry < span_max) {
        if (pc < 0x8000 or pc > 0xFFFF) return false;
        if (usage[pc] & usage_map.flag_opcode == 0) return false; // uncovered
        const file = pc - 0x8000;
        const op = out[file];
        const m8 = usage[pc] & usage_map.flag_m != 0;
        const x8 = usage[pc] & usage_map.flag_x != 0;
        const len = usage_map.instrLen(op, m8, x8);
        switch (op) {
            0x60 => return max_branch <= pc, // RTS: every branch stayed inside
            // Calls, jumps, returns-of-other-kinds, block moves, BRK/COP,
            // WAI/STP, and RTI end the leaf dream.
            0x20, 0x22, 0xFC, 0x4C, 0x5C, 0x6C, 0x7C, 0xDC, 0x6B, 0x40, 0x00, 0x02, 0xCB, 0xDB, 0x44, 0x54 => return false,
            // Branches must land inside the span.
            0x10, 0x30, 0x50, 0x70, 0x80, 0x90, 0xB0, 0xD0, 0xF0 => {
                const dst = pc + 2 +% @as(u32, @bitCast(@as(i32, @as(i8, @bitCast(out[file + 1])))));
                if (dst < entry or dst - entry >= span_max) return false;
                max_branch = @max(max_branch, dst);
            },
            0x82 => return false, // BRL: cheap to allow later, refuse now
            else => {},
        }
        switch (usage_map.mode(op)) {
            .none => {},
            .dp => {
                // Allowed only inside a moved dp window (D=$3000 on both
                // CPUs); anything else is unmoved WRAM the SA-1 cannot see.
                const v: u32 = out[file + 1];
                if (!dpMoved(plan, res, v)) return false;
            },
            .dp_idx, .abs_x, .abs_y, .long_x => return false,
            .abs => {
                const v = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                if (v < 0x3000 or v > 0x37FF) return false; // only the I-RAM window is DB-proof
            },
            .long => {
                const b = out[file + 3];
                const v = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                const ok = (b >= 0x40 and b <= 0x4F) or // BW-RAM
                    (b <= 0x3F and v >= 0x8000) or (b >= 0xC0) or // ROM
                    (b <= 0x3F and v >= 0x3000 and v <= 0x37FF); // I-RAM
                if (!ok) return false;
            },
        }
        pc += len;
    }
    return false;
}

pub fn dpMoved(plan: *const profile.Plan, res: *const Result, off: u32) bool {
    for (plan.regions[0..plan.n], 0..) |r, ri| {
        if (r.dp and res.fate[ri] == .clean and off >= r.start and off < r.start + r.len)
            return true;
    }
    return false;
}

/// The S-CPU side of the handshake: marshal registers into the mailbox, send
/// message 1, spin on SFR until the SA-1 answers, ack, unmarshal, return
/// with the routine's exit flags. Mode-safe: A is saved bytewise via XBA (so
/// B survives), X/Y under REP #$10 (16-bit in native mode, benignly 8-bit in
/// emulation mode where the index high bytes are dead anyway, and the pushed
/// P carries M=X=1 so the SA-1 runs the routine 8-bit to match).
pub const stub_template = [_]u8{
    0x08, // 0  PHP (caller P)
    0xE2, 0x20, // 1  SEP #$20
    0x8D, 0x80, 0x37, // 3  STA $3780 (A low)
    0xEB, // 6  XBA
    0x8D, 0x81, 0x37, // 7  STA $3781 (B)
    0xEB, // 10 XBA
    0xC2, 0x10, // 11 REP #$10
    0x8E, 0x82, 0x37, // 13 STX $3782
    0x8C, 0x84, 0x37, // 16 STY $3784
    0x68, // 19 PLA (caller P; A is 8-bit)
    0x8D, 0x86, 0x37, // 20 STA $3786
    0xA9, 0x01, // 23 LDA #$01
    0x8D, 0x00, 0x22, // 25 STA $2200 (message 1 -> SA-1 CFR)
    0xAD, 0x00, 0x23, // 28 w1: LDA $2300 (SFR)
    0x29, 0x0F, // 31 AND #$0F
    0xC9, 0x01, // 33 CMP #$01
    0xD0, 0xF7, // 35 BNE w1
    0x9C, 0x00, 0x22, // 37 STZ $2200 (ack)
    0xAD, 0x00, 0x23, // 40 w2: LDA $2300
    0x29, 0x0F, // 43 AND #$0F
    0xD0, 0xF9, // 45 BNE w2 (SA-1 cleared done: safe to re-call)
    0xC2, 0x10, // 47 REP #$10
    0xAE, 0x82, 0x37, // 49 LDX $3782
    0xAC, 0x84, 0x37, // 52 LDY $3784
    0xAD, 0x86, 0x37, // 55 LDA $3786 (exit P; A still 8-bit)
    0x48, // 58 PHA
    0xAD, 0x81, 0x37, // 59 LDA $3781 (B)
    0xEB, // 62 XBA
    0xAD, 0x80, 0x37, // 63 LDA $3780 (A low)
    0x28, // 66 PLP (routine's exit flags and widths)
    0x60, // 67 RTS
};

/// Offsets of the message id inside `stub_template` (the LDA #id that sends
/// it and the CMP #id that awaits the echo).
pub const stub_id_send_off: usize = 24;
pub const stub_id_cmp_off: usize = 34;
