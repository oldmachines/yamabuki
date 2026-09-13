//! Window offloads: classifying routines that can run on the SA-1 under the BW-RAM window relocation, and emitting their guards, stubs and blocks; `emitWindowOffloads` is the driver `convertWholeGame` calls.
//!
//! Carved out of sa1gen.zig as pure code motion; every declaration here is
//! re-exported from sa1gen.zig, which stays the module's public root.

const patchgen = @import("../patchgen.zig");
const std = @import("std");
const usage_map = @import("../../usage_map.zig");
const sa1gen = @import("../sa1gen.zig");

const Candidate = sa1gen.Candidate;
const Result = sa1gen.Result;
const WinBoot = sa1gen.WinBoot;
const countCallSites = sa1gen.countCallSites;
const dbrSurvives = sa1gen.dbrSurvives;
const emitFence = sa1gen.emitFence;
const emitNbFence = sa1gen.emitNbFence;
const fenceLen = sa1gen.fenceLen;
const fixupJmps = sa1gen.fixupJmps;
const nb_fence_len = sa1gen.nb_fence_len;
const nmi_prologue_len = sa1gen.nmi_prologue_len;
const offload_max = sa1gen.offload_max;
const ptr_tree_cap = sa1gen.ptr_tree_cap;
const ptr_tree_span_max = sa1gen.ptr_tree_span_max;
const put = sa1gen.put;
const putJsr = sa1gen.putJsr;
const rewriteCallSites = sa1gen.rewriteCallSites;
/// I-RAM mailbox (S-CPU window addresses): +0 status, +1/2 reg, +3/4 value.
/// Status: 0 idle, 1 write8 filed, 2 read8 filed, 3 write16 filed,
/// 4 read16 filed, $FE read served — >= 5 means busy, not a request.
pub const wg_mailbox: u16 = 0x37F0;

pub const WgSiteKind = enum { w8, w16, r8, r16, stz8, stz16, c8, c16, ry8, ry16, rx8, rx16, wx8, wx16, wy8, wy16 };
/// Which index register the site's addressing mode adds, if any. An indexed
/// site's helper computes base+index at run time — in the caller's own index
/// width, since TXA/TYA zero-extend exactly when the hardware would — and
/// files the *effective* register; the mailbox protocol never sees the
/// difference.
pub const WgIndex = enum { none, x, y };
pub const WgSite = struct { file: u32, kind: WgSiteKind, reg: u16, idx: WgIndex = .none };
pub const wg_sites_max = 768;
/// A helper is a pure function of (kind, reg, idx), so sites sharing all
/// three share one helper — Gradius III alone has hundreds of MMIO sites
/// but only a few dozen distinct shapes, and the carve is sized by the
/// latter.
pub const wg_uniq_max = 160;
/// Executed TCD/TCS sites the BW-RAM window move can adjust.
pub const wg_moves_max = 64;
/// Where the BW-RAM window sits on both buses ($6000-$7FFF of every system
/// bank). WRAM's low mirror $0000-$1FFF shifts here; $7E/$7F re-bank to
/// $40/$41 instead, reaching the same bytes linearly.
pub const wg_bw_window: u16 = 0x6000;

// --- window offloads --------------------------------------------------
//
// On a WINDOW image the composition that took the S3 path a shadow, a
// marshal, slot translation, and a D-swap costs NOTHING: the game's whole
// working set already lives in BW-RAM at identity offsets, and the SA-1's
// own $6000-$7FFF window (CBM block 0) shows the same bytes at the same
// addresses as the S-CPU's (SBM block 0). A window-rewritten routine
// therefore runs VERBATIM on the SA-1 — the stub passes registers, D, and
// DBR through the mailbox and nothing else. Every offload is resident by
// construction, which is exactly the shape the async contract wants:
// there is nothing to write back, because there is no second copy.

/// A window-offload call tree: members[0] is the root.
pub const WinSpec = struct {
    /// entry_pin: the DBR pin every in-tree call site carries into this
    /// member (null = at least one call site is unpinned, or the root,
    /// whose callers come through the stub with arbitrary DBR). A copy's
    /// members are called ONLY from other copies in the same tree — the
    /// member-to-member JSLs are re-pointed — so a pin proven at every
    /// in-tree call site genuinely holds for the copy at runtime.
    /// dbr_clean: the member's walked span — and, transitively, every
    /// in-tree member it calls — contains no DBR-changing op (PLB, block
    /// move), so a caller's pin survives calling it. Optimistic default;
    /// the survey passes iterate it downward to the fixpoint.
    /// pin_seen: a call site contributed this member's pin during the
    /// current eligibility pass (the meet needs a first-write marker).
    members: [ptr_tree_cap]struct {
        entry: u16,
        span: u32,
        entry_pin: ?u8 = null,
        pin_seen: bool = false,
        dbr_clean: bool = true,
    } = undefined,
    n_members: usize = 0,
    total_span: u32 = 0,
};

/// Window-tree eligibility: JSL/RTL shape over covered code, members via
/// bank-$00 JSLs, closure at RTL or an unconditional backward transfer at
/// the frontier. The rules ask one question — does the instruction mean
/// the same thing on both CPUs' buses? Window/bank-$40 data, ROM, dp
/// under a window-shifted D, and the tree's own control flow all do.
/// MMIO and the stack-swap ops do not. Low-mirror absolutes ($0000-$1FFF,
/// which the window rewrite left only as pointer-walkers and DBR-followers)
/// are dynamic evidence: under a marshalled game DBR they read the same
/// BW-RAM or ROM on both CPUs; under a system DBR they differ (WRAM vs
/// I-RAM) and S4 verification is the judge.
pub fn windowEligible(out: []const u8, usage: []const u8, evidence: ?[]const u8, thunks: []const u24, entry: u16) ?WinSpec {
    var spec: WinSpec = .{};
    spec.members[0] = .{ .entry = entry, .span = 0, .entry_pin = null, .pin_seen = true };
    spec.n_members = 1;
    // Two phases. SURVEY walks flow only — members, spans, and each
    // member's DBR-cleanliness — repeating while new members appear
    // (bounded by the member cap), with the pin- and evidence-gated
    // refusals disarmed: they depend on entry pins, which depend on
    // cleanliness, which the survey exists to compute. JUDGE then runs
    // once with everything armed; entry pins computed in that pass are a
    // pure function of the surveyed facts, so one pass is the fixpoint.
    var pass: usize = 0;
    while (pass <= 2 * ptr_tree_cap + 1) : (pass += 1) {
        const n_before = spec.n_members;
        var clean_before: [ptr_tree_cap]bool = undefined;
        for (spec.members[0..n_before], 0..) |m, i| clean_before[i] = m.dbr_clean;
        for (spec.members[1..spec.n_members]) |*m| m.pin_seen = false;
        var walked: usize = 0;
        while (walked < spec.n_members) : (walked += 1) {
            if (!winWalkMember(out, usage, evidence, thunks, &spec, walked, false)) return null;
        }
        var stable = spec.n_members == n_before;
        if (stable) for (spec.members[0..n_before], 0..) |m, i| {
            if (m.dbr_clean != clean_before[i]) stable = false;
        };
        if (stable) break;
    }
    for (spec.members[1..spec.n_members]) |*m| m.pin_seen = false;
    var walked: usize = 0;
    while (walked < spec.n_members) : (walked += 1) {
        if (!winWalkMember(out, usage, evidence, thunks, &spec, walked, true)) return null;
    }
    spec.total_span = 0;
    for (spec.members[0..spec.n_members]) |m| spec.total_span += m.span;
    if (spec.total_span > ptr_tree_span_max) return null;
    return spec;
}

/// Walk diagnostics, window flavor: set to a tree root to print every
/// winWalkMember refusal for it (member, pc, opcode, operand, evidence
/// class) plus each in-tree JSL's pin. Zero compiles every print away.
pub const dbg_win_root: u16 = 0;

pub fn winWalkMember(out: []const u8, usage: []const u8, evidence: ?[]const u8, thunks: []const u24, spec: *WinSpec, mi: usize, judge: bool) bool {
    const dbg = dbg_win_root != 0 and spec.members[0].entry == dbg_win_root and judge;
    const span_max: u32 = 1024;
    const entry: u32 = spec.members[mi].entry;
    var pc: u32 = entry;
    var limit: u32 = entry;
    // The data-bank pin, post-window flavor: the rewritten idiom loads
    // $40/$41 now. Under a BW-RAM pin every absolute is data both CPUs
    // read identically — including operands that happen to fall in the
    // MMIO decode range ($8EF1 stores $3E00 under a pinned $40).
    // A member starts with the pin every in-tree call site proved
    // (entry_pin) — the pin the root's own PLB idiom establishes travels
    // through the tree's JSLs, which is what admits an UNCOVERED site in
    // a shared helper: $8EF1's walker branch `ASL $0000,X` never executed
    // under any coverage, but every path to it inside the tree runs under
    // the root's $40 pin, where a tiny-base indexed absolute is BW-RAM
    // data on both buses whatever the index holds.
    var db_pin: ?u8 = spec.members[mi].entry_pin;
    // No DBR-changing op seen in this member's span so far (see WinSpec).
    var dbr_clean = true;
    // A DBR-clean member entered under a pin holds it at EVERY
    // instruction: nothing in its span (or, transitively, its in-tree
    // callees) can change DBR, so the per-op survival approximation —
    // which a mid-span RTL would needlessly kill — is not consulted.
    const pin_locked = judge and spec.members[mi].dbr_clean and spec.members[mi].entry_pin != null;
    while (pc - entry < span_max) {
        if (pc > 0xFFFF) {
            if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: ran past $FFFF\n", .{entry});
            return false;
        }
        if (usage[pc] & usage_map.flag_opcode == 0) {
            if (pc >= limit) {
                if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: uncovered byte at ${x:0>4} past frontier\n", .{ entry, pc });
                return false;
            }
            pc += 1;
            continue;
        }
        const file = pc - 0x8000;
        const op = out[file];
        const m8 = usage[pc] & usage_map.flag_m != 0;
        const x8 = usage[pc] & usage_map.flag_x != 0;
        const len = usage_map.instrLen(op, m8, x8);
        switch (op) {
            0x6B => if (pc >= limit) {
                spec.members[mi].span = pc + 1 - entry;
                spec.members[mi].dbr_clean = dbr_clean;
                return true;
            },
            0x22 => {
                // A call into an index-split thunk is a LEAF, not a
                // member. The thunk is SA-1-safe by construction — its
                // window arm addresses the identity window (the same
                // bytes at the same addresses on both buses) and its
                // as-written arm only runs once the index has carried the
                // address past $2000, so neither arm can land on the low
                // mirror that is the SA-1's own I-RAM. Walking into it
                // would see the as-written arm out of context and refuse
                // the whole tree over the very hazard the thunk exists to
                // remove — which is what kept the physics tree out.
                const tfull: u24 = @as(u24, out[file + 3] & 0x7F) << 16 |
                    std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                var is_thunk = false;
                for (thunks) |t| {
                    if (t == tfull) is_thunk = true;
                }
                if (is_thunk) {
                    if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: thunk call ${x:0>6} at ${x:0>4} — leaf\n", .{ entry, tfull, pc });
                } else if (out[file + 3] != 0x00) {
                    if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: far JSL to bank {x:0>2} at ${x:0>4}\n", .{ entry, out[file + 3], pc });
                    return false;
                } else jsl: {
                    const tgt = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                    if (tgt < 0x8000) {
                        if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: JSL below ROM (${x:0>4}) at ${x:0>4}\n", .{ entry, tgt, pc });
                        return false;
                    }
                    const dup_at: ?usize = for (spec.members[0..spec.n_members], 0..) |m, di| {
                        if (m.entry == tgt) break di;
                    } else null;
                    const ci: usize = dup_at orelse blk: {
                        if (spec.n_members == ptr_tree_cap) {
                            if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: member cap at JSL ${x:0>4}\n", .{ entry, tgt });
                            return false;
                        }
                        spec.members[spec.n_members] = .{ .entry = tgt, .span = 0, .entry_pin = db_pin, .pin_seen = true };
                        spec.n_members += 1;
                        break :blk spec.n_members - 1;
                    };
                    if (dup_at != null) {
                        // Meet of the call sites' pins: the first site this
                        // pass contributes its pin, every further site must
                        // agree or the member weakens to unpinned.
                        if (!spec.members[ci].pin_seen) {
                            spec.members[ci].entry_pin = db_pin;
                            spec.members[ci].pin_seen = true;
                        } else if (!std.meta.eql(spec.members[ci].entry_pin, db_pin)) {
                            spec.members[ci].entry_pin = null;
                        }
                    }
                    // Transitive cleanliness: calling a dirty member dirties
                    // this one.
                    if (!spec.members[ci].dbr_clean) dbr_clean = false;
                    break :jsl;
                }
            },
            // Wrong return shape, near calls, far jumps, interrupt ops,
            // and the ops that would swap the SA-1's stack from under it.
            0x60, 0x40, 0x20, 0xFC, 0x5C, 0x6C, 0x7C, 0xDC => {
                if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: flow op {x:0>2} at ${x:0>4}\n", .{ entry, op, pc });
                return false;
            },
            0x00, 0x02, 0xCB, 0xDB => {
                if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: interrupt op {x:0>2} at ${x:0>4}\n", .{ entry, op, pc });
                return false;
            },
            0x1B, 0x9A => {
                if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: stack-swap op {x:0>2} at ${x:0>4}\n", .{ entry, op, pc });
                return false;
            }, // TCS / TXS
            0x44, 0x54 => {
                // Block moves only between the BW-RAM banks, where both
                // CPUs see the same bytes. (They also load DBR with the
                // destination bank: not DBR-clean.)
                const d0 = out[file + 1];
                const s0 = out[file + 2];
                if (!((d0 == 0x40 or d0 == 0x41) and (s0 == 0x40 or s0 == 0x41 or s0 >= 0x80 or (s0 >= 0x02 and s0 <= 0x3F))))
                    return false;
                dbr_clean = false;
            },
            0x4C, 0x82, 0x80 => {
                const dst: u32 = switch (op) {
                    0x4C => std.mem.readInt(u16, out[file + 1 ..][0..2], .little),
                    0x82 => pc + 3 +% @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(std.mem.readInt(u16, out[file + 1 ..][0..2], .little)))))),
                    else => pc + 2 +% @as(u32, @bitCast(@as(i32, @as(i8, @bitCast(out[file + 1]))))),
                };
                if (dst < entry or dst - entry >= span_max) return false;
                limit = @max(limit, dst);
                if (dst <= pc and pc >= limit) {
                    spec.members[mi].span = pc + len - entry;
                    spec.members[mi].dbr_clean = dbr_clean;
                    return true;
                }
            },
            0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0 => {
                const dst = pc + 2 +% @as(u32, @bitCast(@as(i32, @as(i8, @bitCast(out[file + 1])))));
                if (dst < entry or dst - entry >= span_max) return false;
                limit = @max(limit, dst);
            },
            0xA9 => if (m8 and file + 3 < out.len and out[file + 2] == 0x48 and out[file + 3] == 0xAB) {
                db_pin = out[file + 1];
            },
            0xAB => {
                if (file < 3 or out[file - 3] != 0xA9 or out[file - 1] != 0x48) db_pin = null;
                dbr_clean = false;
            },
            else => {},
        }
        // A pin survives a call to an in-tree member whose own walked
        // span is DBR-clean — the walk sees the callee's whole reachable
        // body, which is a proof dbrTransparent's bounded scan cannot
        // always deliver. (Cleanliness comes from the survey passes;
        // in-tree callees of callees are members too, so the meet over
        // every member's flag makes the property transitive.)
        // A thunk is DBR-transparent by construction: its only bank
        // traffic is a balanced PHB/PLA it reads and discards, and it
        // exits through PLP. So the caller's pin survives it — which
        // matters, because the pin is what admits the walker's uncovered
        // sites, and losing it at a thunk call would refuse the tree just
        // as surely as the hazard the thunk removed.
        const thunk_call = op == 0x22 and out[file + 3] != 0x00 and blk: {
            const tf: u24 = @as(u24, out[file + 3] & 0x7F) << 16 |
                std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
            for (thunks) |t| {
                if (t == tf) break :blk true;
            }
            break :blk false;
        };
        const in_tree_clean = thunk_call or op == 0x22 and out[file + 3] == 0x00 and blk: {
            const tgt = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
            for (spec.members[0..spec.n_members]) |m| {
                if (m.entry == tgt) break :blk m.dbr_clean;
            }
            break :blk false;
        };
        if (dbg and op == 0x22) std.debug.print("[win $8ef1] member ${x:0>4}: JSL ${x:0>4} at ${x:0>4} pin {?x} in_tree_clean {}\n", .{ entry, std.mem.readInt(u16, out[file + 1 ..][0..2], .little), pc, db_pin, in_tree_clean });
        if (!pin_locked and !in_tree_clean and !dbrSurvives(out, usage, file, op)) db_pin = null;
        switch (usage_map.mode(op)) {
            .none, .dp, .dp_idx => {},
            .abs, .abs_x, .abs_y => {
                const v = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                // MMIO through a system bank is S-CPU-only hardware — but
                // under a pinned BW-RAM bank the same operand is data both
                // CPUs read identically.
                const pinned_bw = db_pin != null and (db_pin.? == 0x40 or db_pin.? == 0x41);
                if (judge and !pinned_bw and v >= 0x2100 and v < 0x4380) {
                    if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: MMIO abs ${x:0>4} at ${x:0>4} (op {x:0>2}, pin {?x})\n", .{ entry, v, pc, op, db_pin });
                    return false;
                }
                // An UNSHIFTED low-mirror site (mixed or absent evidence
                // keeps the rewriter's hands off it) means WRAM on the
                // S-CPU but the SA-1's OWN I-RAM in the copy — a tree
                // containing one computes different results per CPU
                // (measured: the offloaded sound path took the wrong
                // branch at the START beep and the menu never reset its
                // frame counter). Pure-ROM evidence is fine: same bytes
                // on both buses.
                if (judge and !pinned_bw and v < 0x2000) {
                    const e: u8 = if (evidence) |s| s[pc] | s[0x80_0000 | pc] else 0;
                    const shifted = if (e != 0)
                        e == usage_map.site_wram_low
                    else
                        usage_map.mode(op) == .abs or v >= 0x100;
                    if (!shifted and (e == 0 or e & usage_map.site_wram_low != 0)) {
                        if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: I-RAM hazard abs op {x:0>2} ${x:0>4} at ${x:0>4} evidence {x:0>2} pin {?x}\n", .{ entry, op, v, pc, e, db_pin });
                        return false;
                    }
                }
            },
            .long, .long_x => {
                const b = out[file + 3];
                const v = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                if ((b & 0x7F) <= 0x3F and v >= 0x2100 and v < 0x4380) {
                    if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: MMIO long ${x:0>2}:{x:0>4} at ${x:0>4}\n", .{ entry, b, v, pc });
                    return false;
                }
                // $7E/$7F would be real WRAM — the window rewrite
                // re-banked every covered site, so seeing one here means
                // the walk wandered into unrewritten territory.
                if (b == 0x7E or b == 0x7F) {
                    if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: unrewritten WRAM long ${x:0>2}:{x:0>4} at ${x:0>4}\n", .{ entry, b, v, pc });
                    return false;
                }
                // Same I-RAM hazard as the absolute arm: an unshifted
                // indexed-long low-mirror site diverges on the SA-1
                // unless its measured traffic was pure ROM.
                // A base at or above $FF00 wraps forward into the NEXT
                // bank's low page, so it reaches the mirror just as surely
                // as a base below $2000 — and testing only `v < $2000`
                // is how `LDA $02:FFFF,X` was admitted into the physics
                // tree and rendered the stage-1 boss out of I-RAM.
                if (judge and usage_map.mode(op) == .long_x and (b & 0x7F) <= 0x3F and
                    (v < 0x2000 or v >= 0xFF00))
                {
                    const e: u8 = if (evidence) |s| s[pc] | s[0x80_0000 | pc] else 0;
                    const shifted = e != 0 and e == usage_map.site_wram_low;
                    if (!shifted and (e == 0 or e & usage_map.site_wram_low != 0)) {
                        if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: I-RAM hazard long_x ${x:0>2}:{x:0>4} at ${x:0>4} evidence {x:0>2}\n", .{ entry, b, v, pc, e });
                        return false;
                    }
                }
            },
        }
        pc += len;
    }
    return false;
}

/// The window stubs' D guard: a caller whose direct page is NOT
/// window-shaped (D outside $6000-$7FFF) comes from a code path the
/// rewriter never covered — its dp state lives in real WRAM, and handing
/// it to the SA-1 would resolve dp operands into the SA-1's own I-RAM,
/// smash the mailbox, and send the chip rampaging over shared BW-RAM
/// (measured: a garbled-and-wiped session traced to exactly this). Such
/// a call runs the ORIGINAL body on the S-CPU instead — no worse than
/// the uncovered path already is, and the SA-1 stays sane.
pub const win_guard_len: u32 = 24;
pub fn emitWinGuard(d: []u8, cur: *usize, entry: u16) void {
    put(d, cur, &.{ 0x08, 0xC2, 0x20, 0x48, 0x0B, 0x68 }); // PHP REP PHA PHD/PLA
    put(d, cur, &.{ 0xC9, 0x00, 0x60, 0x90, 0x05 }); // < $6000 -> bail
    put(d, cur, &.{ 0xC9, 0x00, 0x80, 0x90, 0x06 }); // < $8000 -> ok
    put(d, cur, &.{ 0x68, 0x28, 0x5C, @truncate(entry), @truncate(entry >> 8), 0x00 }); // bail
    put(d, cur, &.{ 0x68, 0x28 }); // ok
}

/// The VBLANK-PROXIMITY guard: the interleaving hazard, closed by
/// construction. A tree that reads NMI-shared state can only tear when
/// the NMI fires MID-TREE — stock's inline walk is interrupted BY the
/// handler and only ever sees interleavings the game was built for; the
/// concurrent SA-1 copy is not (measured: a torn chain head sent the
/// $8EF1 walker into a ROM cycle and parked the mainline forever). But
/// NMI timing is knowable at call time: latch the V counter, and a call
/// starting within `margin` scanlines of the NMI at line 225 runs the
/// ORIGINAL body inline instead — the stock path. Everywhere else the
/// tree (worst case well under the margin at ~10.74MHz) completes
/// before the NMI can touch anything it reads; inside vblank the NMI
/// has already fired and the runway is a whole frame. The two OPVCT
/// reads are toggle-balanced and $213F resets the toggle first; a game
/// that itself consumes the H/V latch could be disturbed — the
/// verification surfaces and the soak gate arbitrate that.
pub const win_vblank_margin_lines: u8 = 32;
pub const win_vblank_guard_len: u32 = 41;
pub fn emitWinVblankGuard(d: []u8, cur: *usize, entry: u16) void {
    put(d, cur, &.{ 0x08, 0xE2, 0x20, 0x48 }); // PHP SEP #$20 PHA
    // LONG-addressed PPU reads: the caller's DBR is live here (a pinned
    // caller arrives with $40), and an absolute $2137 under it would
    // read BW-RAM instead of the latch.
    put(d, cur, &.{ 0xAF, 0x37, 0x21, 0x00 }); // SLHV: latch H/V
    put(d, cur, &.{ 0xAF, 0x3F, 0x21, 0x00 }); // STAT78: reset the read toggle
    put(d, cur, &.{ 0xAF, 0x3D, 0x21, 0x00, 0xEB }); // OPVCT low -> B
    put(d, cur, &.{ 0xAF, 0x3D, 0x21, 0x00, 0x4A }); // OPVCT high; bit8 -> carry
    put(d, cur, &.{ 0xB0, 0x0F }); // V >= 256: deep vblank, safe
    put(d, cur, &.{ 0xEB, 0xC9, 225 - win_vblank_margin_lines }); // A = V low
    put(d, cur, &.{ 0x90, 0x0A }); // below the window: safe
    put(d, cur, &.{ 0xC9, 225, 0xB0, 0x06 }); // at/past NMI line: safe
    put(d, cur, &.{ 0x68, 0x28, 0x5C, @truncate(entry), @truncate(entry >> 8), 0x00 }); // danger: inline
    put(d, cur, &.{ 0x68, 0x28 }); // safe
}

/// The mailbox BUSY guard: the S-CPU's NMI keeps firing while a sync stub
/// waits out its handshake, and the handler may call ANOTHER offloaded
/// routine — the game's contexts shift by phase (measured: the sound
/// pump is mainline in attract but interrupt-side at the title-exit
/// transition), so a nested stub posts over the in-flight message,
/// deadlocks both handshakes, parks the S-CPU forever and leaves the
/// SA-1 mid-copy (the f830 freeze). A call that finds EITHER busy cell
/// set ($378C sync in-flight, $378A async in-flight) is NMI-nested — it
/// runs the original body inline on the S-CPU instead, which is exactly
/// what the un-offloaded game would have done.
pub const win_busy_guard_len: u32 = 30;
pub fn emitWinBusyGuard(d: []u8, cur: *usize, entry: u16) void {
    put(d, cur, &.{ 0x08, 0xC2, 0x20, 0x48, 0xE2, 0x20 }); // PHP REP PHA SEP #$20
    put(d, cur, &.{ 0xAF, 0x8C, 0x37, 0x00 }); // LDA sync busy
    put(d, cur, &.{ 0x0F, 0x8A, 0x37, 0x00 }); // ORA async busy
    put(d, cur, &.{ 0xD0, 0x06 }); // BNE bail
    put(d, cur, &.{ 0xC2, 0x20, 0x68, 0x28, 0x80, 0x08 }); // ok: restore, skip bail
    put(d, cur, &.{ 0xC2, 0x20, 0x68, 0x28 }); // bail: restore
    put(d, cur, &.{ 0x5C, @truncate(entry), @truncate(entry >> 8), 0x00 });
}

/// Window sync stub: D guard, then caller D ($3788), registers, caller P,
/// and caller DBR ($378B) into the mailbox; send; double handshake; exit
/// registers back out. No shadow, no slots, no page copies.
///
/// With `nmi_off` (--wg-nmi-off): SEI + NMITIMEN masked (keeping the
/// game's auto-joypad bit) across the send-and-wait, restored before
/// ANY exit path from the $378F MIRROR the thunked writers maintain —
/// the game's own shadow byte is not phase-accurate (its transition
/// code disables $4200 without updating it) — and the caller's P (and
/// its I bit) round-trips untouched because it was marshaled BEFORE the
/// SEI. While the S-CPU waits here, nothing on it can mutate the tree's
/// read-set: the concurrency hazard is closed by construction, not by
/// timing. A straddled NMI is delivered late (real HW: fires on
/// re-enable during vblank; this emulator: skipped like a lag frame).
pub const win_stub_len: u32 = 158 + win_guard_len + win_busy_guard_len + win_vblank_guard_len;
pub const win_nmi_off_extra: u32 = 27;
/// Covered `STA $4200` sites re-pointed at mirror thunks (bank $00).
pub const NmiSites = struct { at: [8]u32, n: usize };
pub const win_nmi_thunk_len: u32 = 8;
pub fn emitWinStub(d: []u8, id: u8, entry: u16, nmi_off: bool) u32 {
    var cur: usize = 0;
    emitWinGuard(d, &cur, entry);
    emitWinBusyGuard(d, &cur, entry);
    emitWinVblankGuard(d, &cur, entry);
    // The mailbox is NMI-ATOMIC: busy is raised BEFORE the first mailbox
    // write and dropped AFTER the last mailbox read. The S-CPU's NMI
    // keeps firing through a stub, and a nested offload call landing in
    // an unguarded window overwrites the marshal (the tree then runs
    // with the NESTED call's registers) or the exit registers (the outer
    // caller resumes with them) — measured live as rampaging indexed
    // writes, a smashed stack top, and a wild RTL into open bus while
    // the music played on. Fully transparent wrapper: PHP/SEP/PHA
    // around the store.
    put(d, &cur, &.{ 0x08, 0xE2, 0x20, 0x48, 0xA9, 0x01, 0x8F, 0x8C, 0x37, 0x00, 0x68, 0x28 });
    // Caller D, with A saved around the grab.
    put(d, &cur, &.{ 0x08, 0xC2, 0x20, 0x48, 0x0B, 0x68, 0x8F, 0x88, 0x37, 0x00, 0x68, 0x28 });
    // Register marshal (the sync-ptr stub's, verbatim).
    put(d, &cur, &.{ 0x8B, 0x08, 0xE2, 0x20 });
    put(d, &cur, &.{ 0x8F, 0x80, 0x37, 0x00, 0xEB, 0x8F, 0x81, 0x37, 0x00, 0xEB });
    put(d, &cur, &.{ 0xC2, 0x30, 0x8A, 0x8F, 0x82, 0x37, 0x00, 0x98, 0x8F, 0x84, 0x37, 0x00 });
    put(d, &cur, &.{ 0xE2, 0x20, 0x68, 0x8F, 0x86, 0x37, 0x00 });
    // Caller DBR: the PHB byte, at the stack top now the PHP is pulled.
    put(d, &cur, &.{ 0xA3, 0x01, 0x8F, 0x8B, 0x37, 0x00 });
    if (nmi_off) {
        // Interrupts off for the whole handshake: caller P is already in
        // the mailbox, so the SEI never leaks back. RDNMI ack first —
        // the game's own bracket idiom.
        put(d, &cur, &.{0x78}); // SEI
        put(d, &cur, &.{ 0xAF, 0x10, 0x42, 0x00 }); // RDNMI ack
        put(d, &cur, &.{ 0xAF, 0x8F, 0x37, 0x00 }); // the $4200 mirror
        put(d, &cur, &.{ 0x29, 0x01 }); // keep auto-joypad only
        put(d, &cur, &.{ 0x8F, 0x00, 0x42, 0x00 });
    }
    // Send + double handshake.
    put(d, &cur, &.{ 0xA9, id, 0x8F, 0x00, 0x22, 0x00 });
    put(d, &cur, &.{ 0xAF, 0x00, 0x23, 0x00, 0x29, 0x0F, 0xC9, id, 0xD0, 0xF6 });
    put(d, &cur, &.{ 0xA9, 0x00, 0x8F, 0x00, 0x22, 0x00 });
    put(d, &cur, &.{ 0xAF, 0x00, 0x23, 0x00, 0x29, 0x0F, 0xD0, 0xF8 });
    if (nmi_off) {
        // Restore the game's NMITIMEN before ANY exit path (the aborted
        // check below JMLs away); the exit PLP restores the caller's I.
        put(d, &cur, &.{ 0xAF, 0x10, 0x42, 0x00 }); // RDNMI ack
        put(d, &cur, &.{ 0xAF, 0x8F, 0x37, 0x00 }); // the $4200 mirror
        put(d, &cur, &.{ 0x8F, 0x00, 0x42, 0x00 });
    }
    // Exit registers from the mailbox; caller DBR back.
    put(d, &cur, &.{0xAB});
    put(d, &cur, &.{ 0xC2, 0x30, 0xAF, 0x82, 0x37, 0x00, 0xAA, 0xAF, 0x84, 0x37, 0x00, 0xA8 });
    put(d, &cur, &.{ 0xE2, 0x20, 0xAF, 0x86, 0x37, 0x00, 0x48 });
    put(d, &cur, &.{ 0xAF, 0x81, 0x37, 0x00, 0xEB, 0xAF, 0x80, 0x37, 0x00 });
    // WATCHDOG-ABORTED check, matching THIS stub's id: the dispatcher's
    // abort path skipped the exit marshal, so the registers just loaded
    // ARE the caller's entry registers — clear the flag and the busy
    // cell and run the ORIGINAL body inline, exactly the un-offloaded
    // game (the tree never ran to completion; worst case is an
    // interrupted copy's partial BW-RAM writes re-applied, a rare
    // single-frame double-step instead of a permanent freeze).
    put(d, &cur, &.{ 0x48, 0xAF, 0x8D, 0x37, 0x00, 0xC9, id, 0xD0, 0x10 }); // PHA; aborted us?
    put(d, &cur, &.{ 0xA9, 0x00, 0x8F, 0x8D, 0x37, 0x00, 0x8F, 0x8C, 0x37, 0x00 });
    put(d, &cur, &.{ 0x68, 0x28, 0x5C, @truncate(entry), @truncate(entry >> 8), 0x00 });
    put(d, &cur, &.{0x68}); // ok: PLA
    // Mailbox reads done — NOW release it (A preserved around the store).
    put(d, &cur, &.{ 0x48, 0xA9, 0x00, 0x8F, 0x8C, 0x37, 0x00, 0x68 });
    put(d, &cur, &.{ 0x28, 0x6B });
    return @intCast(cur);
}

/// Window async stub: fence first (drain any in-flight call), marshal
/// registers + D + DBR, send, mark busy, return AT ONCE with the
/// caller's own registers. Nothing to write back — the routine's effects
/// land in the shared BW-RAM both CPUs address.
pub const win_async_stub_len: u32 = 111 + win_guard_len + win_busy_guard_len;
pub fn emitWinAsyncStub(d: []u8, fence: u24, id: u8, entry: u16) u32 {
    var cur: usize = 0;
    emitWinGuard(d, &cur, entry);
    emitWinBusyGuard(d, &cur, entry);
    put(d, &cur, &.{ 0x08, 0xC2, 0x30, 0x48, 0xDA, 0x5A, 0x8B }); // save caller
    put(d, &cur, &.{ 0x22, @truncate(fence), @truncate(fence >> 8), @truncate(fence >> 16) });
    put(d, &cur, &.{ 0xAB, 0xC2, 0x30, 0x7A, 0xFA, 0x68, 0x28 }); // restore (REP first)
    // Raise busy BEFORE the marshal (see the sync stub: an NMI-nested
    // call in the marshal window would overwrite the mailbox and the
    // async tree would run with the nested call's registers).
    put(d, &cur, &.{ 0x08, 0xE2, 0x20, 0x48, 0xA9, 0x01, 0x8F, 0x8C, 0x37, 0x00, 0x68, 0x28 });
    put(d, &cur, &.{ 0x08, 0xC2, 0x30, 0x48, 0xDA, 0x5A }); // re-save P,A,X,Y
    put(d, &cur, &.{ 0x8B, 0x08, 0xE2, 0x20 });
    put(d, &cur, &.{ 0x8F, 0x80, 0x37, 0x00, 0xEB, 0x8F, 0x81, 0x37, 0x00, 0xEB });
    put(d, &cur, &.{ 0xC2, 0x30, 0x8A, 0x8F, 0x82, 0x37, 0x00, 0x98, 0x8F, 0x84, 0x37, 0x00 });
    // Caller P is the re-save's PHP byte: B(1)+Y(2)+X(2)+A(2) above it
    // once our own PHP is pulled.
    put(d, &cur, &.{ 0xE2, 0x20, 0x68, 0xA3, 0x08, 0x8F, 0x86, 0x37, 0x00 });
    put(d, &cur, &.{ 0xA3, 0x01, 0x8F, 0x8B, 0x37, 0x00 }); // DBR (PHB byte)
    // D last — the PLA clobbers A, which the mailbox already holds.
    put(d, &cur, &.{ 0xC2, 0x20, 0x0B, 0x68, 0x8F, 0x88, 0x37, 0x00 });
    put(d, &cur, &.{ 0xE2, 0x20, 0xA9, id, 0x8F, 0x00, 0x22, 0x00, 0x8F, 0x8A, 0x37, 0x00 });
    // $378A now covers the in-flight async; drop the marshal guard.
    put(d, &cur, &.{ 0xA9, 0x00, 0x8F, 0x8C, 0x37, 0x00 });
    put(d, &cur, &.{ 0xAB, 0xC2, 0x30, 0x7A, 0xFA, 0x68, 0x28, 0x6B });
    return @intCast(cur);
}

/// One dispatcher block for a window offload: game D as-is, WATCHDOG
/// armed (while DBR is still the dispatcher's — the arm is absolute
/// MMIO, and a game DBR would land it in BW-RAM), game DBR from the
/// mailbox, the shared unmarshal, CLI, the copy, SEI, dispatcher DBR
/// back, the shared marshal, exit-P I-bit repaired, dispatcher D back,
/// signal. The watchdog: the SA-1's own linear timer restarts before
/// each dispatch; a copy that overruns the budget takes the timer IRQ
/// into the abort handler, which unwinds and signals "aborted" instead
/// of wedging both CPUs forever (measured: the $8EF1 walker's torn
/// chain-head ROM cycles survived every cheaper guard).
///
/// The I-bit dance: these trees are the INTERRUPT class — their game P
/// arrives with I set, so without the CLI the watchdog would never
/// fire for exactly the calls it exists to protect (the unmarshal's
/// PLP hands game P to the copy). But P round-trips: the marshal
/// stores the live post-copy P and the S-CPU caller PLPs it, so the
/// forced CLI/SEI would leak a wrong I bit back into the GAME. Entry
/// P's I bit is stashed at $378E before dispatch and patched into the
/// stored exit P after the marshal. (PLB's N/Z clobber predates the
/// watchdog and is measured non-load-bearing; I is not a flag to
/// gamble on.)
pub const win_block_len: u32 = 65;
pub fn emitWinBlock(d: []u8, cur: *usize, id: u8, copy_addr: u16, copy_bank: u8, unm_addr: u16, mar_addr: u16, sig_addr: u16, dp_base: u16) void {
    put(d, cur, &.{ 0xC9, id, 0xD0, win_block_len - 4 });
    put(d, cur, &.{0x8B}); // dispatcher DBR
    put(d, cur, &.{ 0xC2, 0x20, 0xAD, 0x88, 0x37, 0x5B }); // game D
    put(d, cur, &.{ 0xE2, 0x20 });
    put(d, cur, &.{ 0xAD, 0x86, 0x37, 0x29, 0x04, 0x8D, 0x8E, 0x37 }); // entry P's I bit -> $378E
    put(d, cur, &.{ 0x9C, 0x11, 0x22 }); // CTR: counters to zero
    put(d, cur, &.{ 0xA9, 0x40, 0x8D, 0x0B, 0x22 }); // CIC: clear timer flag
    putJsr(d, cur, unm_addr); // loads X/Y, sets game DBR, loads A/P long
    put(d, cur, &.{0x58}); // CLI — the watchdog covers the copy whatever game P says
    put(d, cur, &.{ 0x22, @truncate(copy_addr), @truncate(copy_addr >> 8), copy_bank });
    put(d, cur, &.{0x78}); // SEI
    put(d, cur, &.{0xAB}); // dispatcher DBR back
    putJsr(d, cur, mar_addr);
    put(d, cur, &.{ 0xAD, 0x86, 0x37, 0x29, 0xFB, 0x0D, 0x8E, 0x37, 0x8D, 0x86, 0x37 }); // exit P I <- entry I
    put(d, cur, &.{ 0xA9, 0x40, 0x8D, 0x0B, 0x22 }); // drop a crossing that never fired
    put(d, cur, &.{ 0xF4, @truncate(dp_base), @truncate(dp_base >> 8), 0x2B });
    put(d, cur, &.{ 0x4C, @truncate(sig_addr), @truncate(sig_addr >> 8) });
}

/// The watchdog budget: linear-timer V target. V increments every 2048
/// master clocks, so 200 is ~19ms. Generous ON PURPOSE: the big worker
/// tree's LEGITIMATE runs average ~4.4ms (measured: a 48-line budget
/// aborted them wholesale, and every abort double-applies the partial
/// BW-RAM writes plus the inline re-run — 28 KiB of divergence by
/// frame 422). The watchdog exists to catch INFINITE loops, where the
/// alternative is a permanent freeze; cutting one off within ~1.2
/// frames is plenty.
pub const win_watchdog_vcnt: u8 = 200;

/// The abort handler the SA-1's timer IRQ vectors to (CIV). IRQs are
/// open ONLY between a dispatch block's CLI and SEI, so the sole
/// LEGITIMATE spurious crossing (the completed-call race: the flag trips
/// just as the copy returns) interrupts bank 0 inside the blocks region
/// — that exact shape is acked and resumed. EVERYTHING else is a
/// runaway: a walker spinning inside the copy AND a torn pointer that
/// flung it into wild ROM both fail the shape test (checking only the
/// copies' span would RESUME the wild-chain case forever). Unwind:
/// aborted flag for the S-CPU, stack reset to the dispatcher's base,
/// dispatcher DBR/D back, and straight to the signal WITHOUT the exit
/// marshal, so the mailbox still holds the caller's ENTRY registers and
/// the stub's inline re-run starts from exactly the original call state.
/// $378D carries the aborted ID (the $3787 latch), not a boolean: each
/// sync stub consumes only its OWN id, so an aborted ASYNC tree — whose
/// stub returned long ago and can never consume the flag — leaves a
/// stale value no sync stub matches (that run's effects are dropped, one
/// missed pump tick) instead of tricking the NEXT sync caller into
/// re-running a body whose tree already completed.
pub const win_abort_len: u32 = 58;
pub fn emitWinAbort(d: []u8, cur: *usize, blocks_lo: u16, blocks_hi1: u16, sig_addr: u16) void {
    put(d, cur, &.{ 0xC2, 0x20, 0x48 }); // REP #$20, PHA (preserve A for resume)
    put(d, cur, &.{ 0xA3, 0x04 }); // interrupted PC (above A + P)
    put(d, cur, &.{ 0xC9, @truncate(blocks_lo), @truncate(blocks_lo >> 8) });
    put(d, cur, &.{ 0x90, 0x0B }); // below the blocks: runaway
    put(d, cur, &.{ 0xC9, @truncate(blocks_hi1), @truncate(blocks_hi1 >> 8) });
    put(d, cur, &.{ 0xB0, 0x06 }); // past them: runaway
    put(d, cur, &.{ 0xE2, 0x20, 0xA3, 0x06 }); // interrupted PB
    put(d, cur, &.{ 0xF0, 0x1C }); // bank 0 in-blocks: resume8
    // Genuine runaway. The stack is about to be reset — nothing to unpush.
    put(d, cur, &.{ 0xE2, 0x20 }); // (16-bit arrivals from the PC checks)
    put(d, cur, &.{ 0x4B, 0xAB }); // PHK/PLB: dispatcher DBR
    put(d, cur, &.{ 0xA9, 0x40, 0x8D, 0x0B, 0x22 }); // ack the timer IRQ
    put(d, cur, &.{ 0xAD, 0x87, 0x37, 0x8D, 0x8D, 0x37 }); // $378D: aborted id
    put(d, cur, &.{ 0xC2, 0x10, 0xA2, 0x78, 0x37, 0x9A }); // stack to the dispatcher base
    put(d, cur, &.{ 0xF4, 0x00, 0x37, 0x2B }); // dispatcher D
    put(d, cur, &.{ 0x4C, @truncate(sig_addr), @truncate(sig_addr >> 8) });
    put(d, cur, &.{ 0xA9, 0x40, 0x8D, 0x0B, 0x22 }); // resume8: ack
    put(d, cur, &.{ 0xC2, 0x20, 0x68, 0x40 }); // restore A, RTI
}

pub const WinChosen = struct { entry: u16, spec: WinSpec, is_async: bool, nmi_off: bool };

/// Choose and emit window offloads onto the REWRITTEN image. The
/// dispatcher (CRV is 16-bit) and the NMI prologue (a 16-bit vector)
/// live in the bank-0 carve after the shim; stubs, copies, and the fence
/// are long-addressed and carve from any bank's padding. Returns the CRV
/// and CIV for the shim to program, or null when nothing offloaded.
/// (CIV because $2207/8 is an S-CPU-SIDE register — the SA-1's own
/// stores to it fall on deaf ports, measured as a frame-0 wedge when the
/// prologue tried: the first timer IRQ vectored through CIV=0 into
/// I-RAM garbage.)
pub fn emitWindowOffloads(
    out: []u8,
    usage: []const u8,
    evidence: ?[]const u8,
    header_off: u32,
    candidates: []const Candidate,
    allow_async_in: bool,
    bank0_at: u32,
    /// Index-split thunk bodies (24-bit): a `JSL` into one is a leaf the
    /// eligibility walk must not mistake for a tree member.
    thunks: []const u24,
    res: *Result,
) ?WinBoot {
    const nmi_native = std.mem.readInt(u16, out[header_off + 0x2A ..][0..2], .little);
    const nmi_emu = std.mem.readInt(u16, out[header_off + 0x3A ..][0..2], .little);
    const nmi_ok = nmi_native >= 0x8000 and
        (nmi_emu == nmi_native or nmi_emu < 0x8000 or nmi_emu == 0xFFFF);
    const allow_async = allow_async_in and nmi_ok;

    var chosen: [offload_max]WinChosen = undefined;
    var n: usize = 0;
    for (candidates) |c| {
        if (n == offload_max) break;
        if (c.entry >> 16 != 0 or (c.entry & 0xFFFF) < 0x8000) continue;
        const e: u16 = @truncate(c.entry);
        const dup = for (chosen[0..n]) |x| {
            if (x.entry == e) break true;
        } else false;
        if (dup) continue;
        // The async monopoly, as in the S3 path: a sibling's un-fenced
        // send mid-flight deadlocks the dispatcher.
        if (n > 0 and chosen[0].is_async) break;
        const spec = windowEligible(out, usage, evidence, thunks, e) orelse continue;
        if (countCallSites(out, usage, e, 0x22) == 0) continue;
        chosen[n] = .{
            .entry = e,
            .spec = spec,
            .is_async = allow_async and !c.no_async and !c.nmi_off and n == 0,
            .nmi_off = c.nmi_off,
        };
        n += 1;
    }
    if (n == 0) return null;

    // --wg-nmi-off support: NMITIMEN is write-only, and the game's own
    // shadow byte is NOT phase-accurate — GIII's transition code writes
    // $4200=0 (screen off, interrupts off) WITHOUT touching its $1E82
    // shadow, so a stub that restored from the shadow RE-ENABLED the
    // NMI inside the game's own interrupts-off bracket (measured: a
    // mid-transition NMI walked a garbage handler pointer through $57
    // buffer data and the game parked forever in its frame-wait with
    // the screen blanked). The truth must be MIRRORED: every covered
    // `STA $4200` is re-pointed at an 8-byte thunk (JSR fits the 3-byte
    // site exactly) that stores A to I-RAM $378F first, then to $4200 —
    // mirror-first, so a caller nested between the two stores reads the
    // value the game was about to set. The stub masks and restores from
    // the mirror: exact, whatever phase the game is in. Sites must all
    // be bank $00 (JSR reach) and the plain-STA shape; anything else
    // (STZ form, other banks) forfeits the wrap, disclosed via stats.
    const nmi_sites: ?NmiSites = blk: {
        var want = false;
        for (chosen[0..n]) |c| {
            if (c.nmi_off and !c.is_async) want = true;
        }
        if (!want) break :blk null;
        var s: NmiSites = .{ .at = undefined, .n = 0 };
        var bank: u32 = 0;
        while (bank * 0x8000 < out.len and bank < 0x40) : (bank += 1) {
            var a16: u32 = 0x8000;
            while (a16 < 0x10000) : (a16 += 1) {
                const cpu = bank << 16 | a16;
                if ((usage[cpu] | usage[0x80_0000 | cpu]) & usage_map.flag_opcode == 0) continue;
                const f = bank * 0x8000 + (a16 - 0x8000);
                if (f + 2 >= out.len) continue;
                const op = out[f];
                if ((op == 0x8D or op == 0x9C) and out[f + 1] == 0x00 and out[f + 2] == 0x42) {
                    if (op == 0x9C or bank != 0 or s.n == s.at.len) break :blk null;
                    s.at[s.n] = f;
                    s.n += 1;
                }
            }
        }
        if (s.n == 0) break :blk null;
        break :blk s;
    };
    res.stats.nmi_off_sites = if (nmi_sites) |s| @intCast(s.n) else 0;

    // Any-bank sizes.
    var any_len: u32 = 0;
    var has_async = false;
    for (chosen[0..n]) |c| {
        any_len += c.spec.total_span;
        if (c.is_async) {
            has_async = true;
            any_len += fenceLen(.{}) + nb_fence_len + win_async_stub_len;
        } else any_len += win_stub_len + (if (c.nmi_off and nmi_sites != null) win_nmi_off_extra else 0);
    }
    // The copies need ONE contiguous run and cannot be split, which puts
    // them in direct competition with the thunk bodies already written
    // into the same padding. When the run is not there, EVERY offload is
    // silently abandoned and the patch ships with none — measured: making
    // the physics tree eligible raised the requirement past what was left
    // and cost the sequencer tree too, 116 dropped frames back to 186,
    // with nothing in the log to say why. Disclose it.
    // Bank-contained: a copy that crosses $xx:FFFF executes into the WRAM
    // mirror when the PC wraps, which after relocation is abandoned memory.
    const any_at = patchgen.findFreeSpaceInBank(out, any_len) orelse {
        res.stats.offload_space_short = any_len;
        return null;
    };
    var cur: u32 = any_at;

    // Copies first (their addresses feed the blocks and stubs).
    var copy_at: [offload_max]u32 = undefined;
    for (chosen[0..n], 0..) |c, i| {
        var member_copy: [ptr_tree_cap]u32 = undefined;
        copy_at[i] = cur;
        for (c.spec.members[0..c.spec.n_members], 0..) |m, mi| {
            member_copy[mi] = cur;
            @memcpy(out[cur..][0..m.span], out[m.entry - 0x8000 ..][0..m.span]);
            cur += m.span;
        }
        for (c.spec.members[0..c.spec.n_members], 0..) |m, mi| {
            fixupJmps(out, usage, m.entry, m.span, member_copy[mi], @intCast(0x8000 + (member_copy[mi] % 0x8000)));
            // Member-to-member JSLs re-point at the copies.
            var pc: u32 = m.entry;
            while (pc - m.entry < m.span) {
                if (usage[pc] & usage_map.flag_opcode == 0) {
                    pc += 1;
                    continue;
                }
                const mf = pc - 0x8000;
                const op = out[mf];
                if (op == 0x22 and out[mf + 3] == 0x00) {
                    const tgt = std.mem.readInt(u16, out[mf + 1 ..][0..2], .little);
                    for (c.spec.members[0..c.spec.n_members], 0..) |m2, mj| {
                        if (m2.entry != tgt) continue;
                        const dst = member_copy[mi] + (pc - m.entry);
                        std.mem.writeInt(u16, out[dst + 1 ..][0..2], @intCast(0x8000 + (member_copy[mj] % 0x8000)), .little);
                        out[dst + 3] = @intCast(member_copy[mj] / 0x8000);
                        break;
                    }
                }
                const m8 = usage[pc] & usage_map.flag_m != 0;
                const x8 = usage[pc] & usage_map.flag_x != 0;
                pc += usage_map.instrLen(op, m8, x8);
            }
        }
        res.stats.offload_copy[i] = @as(u24, @intCast(copy_at[i] / 0x8000)) << 16 |
            @as(u24, @intCast(0x8000 + (copy_at[i] % 0x8000)));
        res.stats.offload_copy_len[i] = c.spec.total_span;
    }

    // Fence for the async offload, then the stubs; re-point call sites.
    var fence24: u24 = 0;
    var nb_fence24: u24 = 0;
    for (chosen[0..n], 0..) |c, i| {
        const id: u8 = @intCast(i + 1);
        if (c.is_async) {
            const flen = emitFence(out[cur..], .{});
            std.debug.assert(flen == fenceLen(.{}));
            fence24 = @as(u24, @intCast(cur / 0x8000)) << 16 |
                @as(u24, @intCast(0x8000 + (cur % 0x8000)));
            res.stats.async_entry = c.entry;
            res.stats.async_fence = fence24;
            cur += flen;
            const nblen = emitNbFence(out[cur..]);
            std.debug.assert(nblen == nb_fence_len);
            nb_fence24 = @as(u24, @intCast(cur / 0x8000)) << 16 |
                @as(u24, @intCast(0x8000 + (cur % 0x8000)));
            cur += nblen;
        }
        const stub_file = cur;
        const stub_wrap = c.nmi_off and nmi_sites != null;
        const slen = if (c.is_async)
            emitWinAsyncStub(out[cur..], fence24, id, c.entry)
        else
            emitWinStub(out[cur..], id, c.entry, stub_wrap);
        std.debug.assert(slen == if (c.is_async)
            win_async_stub_len
        else
            win_stub_len + (if (stub_wrap) win_nmi_off_extra else 0));
        cur += slen;
        const stub_bank: u8 = @intCast(stub_file / 0x8000);
        const stub_addr: u16 = @intCast(0x8000 + (stub_file % 0x8000));
        res.stats.offload_sites += rewriteCallSites(out, usage, c.entry, 0x22, stub_addr, stub_bank);
        res.stats.offload_entries[i] = c.entry;
        res.stats.offload_ptr_mask |= @as(u8, 1) << @intCast(i);
    }
    std.debug.assert(cur - any_at == any_len);

    // The dispatcher, in the bank-0 carve after the shim.
    const d = out[bank0_at..];
    var dc: usize = 0;
    const dp_base: u16 = 0x3700;
    const base16: u16 = @intCast(0x8000 + (bank0_at % 0x8000));
    // Prologue: I-RAM/BW-RAM gates, CBM block 0 (the identity window!),
    // native mode, 16-bit X, stack under the mailbox, D — then the
    // watchdog: the linear timer with a V budget, CIC BEFORE CIE (the
    // clear bit is the line mask — enabling with it unset asserts the
    // IRQ line at once, and the first dispatch's PLP of a mainline
    // caller's P would take it instantly). CIV is programmed by the
    // S-CPU shim: $2207/8 is not writable from this side.
    const abort_addr: u16 = base16 + @as(u16, @intCast(51 + 12 + n * win_block_len + 3 + 19 + 29 + 24));
    put(d, &dc, &.{ 0x78, 0xA9, 0xFF, 0x8D, 0x2A, 0x22, 0xA9, 0x80, 0x8D, 0x27, 0x22, 0x9C, 0x25, 0x22, 0x18, 0xFB, 0xC2, 0x10, 0xA2, 0x78, 0x37, 0x9A, 0xF4, @truncate(dp_base), @truncate(dp_base >> 8), 0x2B });
    put(d, &dc, &.{ 0xA9, win_watchdog_vcnt, 0x8D, 0x14, 0x22 }); // VCNT lo
    put(d, &dc, &.{ 0xA9, 0x00, 0x8D, 0x15, 0x22 }); // VCNT hi
    put(d, &dc, &.{ 0xA9, 0x82, 0x8D, 0x10, 0x22 }); // TMC: linear, V compare
    put(d, &dc, &.{ 0xA9, 0x40, 0x8D, 0x0B, 0x22 }); // CIC: line masked...
    put(d, &dc, &.{ 0xA9, 0x40, 0x8D, 0x0A, 0x22 }); // ...THEN CIE: timer IRQ
    std.debug.assert(dc == 51);
    const loop_addr: u16 = base16 + @as(u16, @intCast(dc));
    put(d, &dc, &.{ 0xE2, 0x20, 0xAD, 0x01, 0x23, 0x29, 0x0F, 0xF0, 0xF7, 0x8D, 0x87, 0x37 });
    const blocks_at = dc;
    dc += n * win_block_len; // blocks emitted below, once sig/unm/mar addresses exist
    put(d, &dc, &.{ 0x4C, @truncate(loop_addr), @truncate(loop_addr >> 8) });
    const sig_addr: u16 = base16 + @as(u16, @intCast(dc));
    put(d, &dc, &.{ 0xAD, 0x87, 0x37, 0x8D, 0x09, 0x22, 0xAD, 0x01, 0x23, 0x29, 0x0F, 0xD0, 0xF9, 0x9C, 0x09, 0x22, 0x4C, @truncate(loop_addr), @truncate(loop_addr >> 8) });
    const unm_addr: u16 = base16 + @as(u16, @intCast(dc));
    // The unmarshal sets the GAME DBR itself, and the mailbox reads that
    // follow it go LONG. Ordering is load-bearing: a caller pinned to
    // BW-RAM marshals DBR=$40, and an absolute $37xx read under that
    // bank lands in BW-RAM game data, not I-RAM — the tree then runs
    // with garbage registers and a garbage P (measured: the async
    // flavor's pinned caller entered the copy in m8/x8, misparsed the
    // m16 stream, and ran away until the watchdog). X and Y load first,
    // under the dispatcher's DBR, because LDX/LDY have no long form.
    put(d, &dc, &.{ 0xC2, 0x10, 0xAE, 0x82, 0x37, 0xAC, 0x84, 0x37 }); // REP #$10; LDX; LDY
    put(d, &dc, &.{ 0xAD, 0x8B, 0x37, 0x48, 0xAB }); // game DBR
    put(d, &dc, &.{ 0xAF, 0x86, 0x37, 0x00, 0x48 }); // P (long), pushed
    put(d, &dc, &.{ 0xAF, 0x81, 0x37, 0x00, 0xEB, 0xAF, 0x80, 0x37, 0x00 }); // B, A (long)
    put(d, &dc, &.{ 0x28, 0x60 }); // PLP; RTS
    const mar_addr: u16 = base16 + @as(u16, @intCast(dc));
    put(d, &dc, &.{ 0x08, 0xC2, 0x10, 0x8E, 0x82, 0x37, 0x8C, 0x84, 0x37, 0xE2, 0x20, 0x8D, 0x80, 0x37, 0xEB, 0x8D, 0x81, 0x37, 0xEB, 0x68, 0x8D, 0x86, 0x37, 0x60 });
    // The watchdog's abort handler; the resume shape is bank 0 inside
    // the blocks region (the only place a dispatch opens IRQs).
    std.debug.assert(base16 + @as(u16, @intCast(dc)) == abort_addr);
    const blocks_lo: u16 = base16 + @as(u16, @intCast(blocks_at));
    emitWinAbort(d, &dc, blocks_lo, blocks_lo + @as(u16, @intCast(n * win_block_len)), sig_addr);
    const nmi_at = dc;
    var bc = blocks_at;
    for (chosen[0..n], 0..) |_, i| {
        const id: u8 = @intCast(i + 1);
        emitWinBlock(d, &bc, id, @intCast(0x8000 + (copy_at[i] % 0x8000)), @intCast(copy_at[i] / 0x8000), unm_addr, mar_addr, sig_addr, dp_base);
    }
    std.debug.assert(bc == blocks_at + n * win_block_len);

    // Async: the NMI prologue (bank 0 — the vector is 16-bit), vectors.
    if (has_async) {
        var nc = nmi_at;
        put(d, &nc, &.{ 0x08, 0xC2, 0x30, 0x48, 0xDA, 0x5A, 0x8B });
        put(d, &nc, &.{ 0x22, @truncate(nb_fence24), @truncate(nb_fence24 >> 8), @truncate(nb_fence24 >> 16) });
        put(d, &nc, &.{ 0xAB, 0xC2, 0x30, 0x7A, 0xFA, 0x68, 0x28 });
        put(d, &nc, &.{ 0x4C, @truncate(nmi_native), @truncate(nmi_native >> 8) });
        std.debug.assert(nc - nmi_at == nmi_prologue_len);
        const nmi_addr: u16 = base16 + @as(u16, @intCast(nmi_at));
        std.mem.writeInt(u16, out[header_off + 0x2A ..][0..2], nmi_addr, .little);
        std.mem.writeInt(u16, out[header_off + 0x3A ..][0..2], nmi_addr, .little);
    }

    // The $4200-mirror thunks (nmi-off wrap): each covered `STA $4200`
    // becomes `JSR thunk`; the thunk stores A to the mirror FIRST, then
    // to the register, so a caller nested between the two stores reads
    // the value the game was about to set.
    if (nmi_sites) |s| {
        var tc = nmi_at + @as(usize, if (has_async) nmi_prologue_len else 0);
        for (s.at[0..s.n]) |site| {
            const thunk_addr: u16 = base16 + @as(u16, @intCast(tc));
            put(d, &tc, &.{ 0x8F, 0x8F, 0x37, 0x00 }); // mirror first
            put(d, &tc, &.{ 0x8D, 0x00, 0x42 }); // then NMITIMEN
            put(d, &tc, &.{0x60});
            out[site] = 0x20;
            std.mem.writeInt(u16, out[site + 1 ..][0..2], thunk_addr, .little);
        }
    }

    res.stats.offload_count = @intCast(n);
    res.stats.offloaded = chosen[0].entry;
    res.stats.pointer_offloads = @intCast(n);
    res.stats.resident_offloads = @intCast(n); // by construction
    return .{ .crv = base16, .civ = abort_addr };
}
