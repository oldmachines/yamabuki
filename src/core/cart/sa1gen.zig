//! Stage S3 of the SA-1 generation arc: the mechanical rewrite, built as the
//! two pieces that can be verified TODAY, before any code migrates between
//! CPUs.
//!
//! **The shell.** Convert a plain LoROM cart into an SA-1 cart that behaves
//! identically: header to SA-1 (chipset $35, map mode $23, BW-RAM declared),
//! an S-CPU reset shim that opens the SNES-side write gates (SIWP/SWEN),
//! boots the SA-1 through the real protocol (CRV, then releasing RESB via
//! $2200) into a park stub (SEI/STP), and continues the original game on the
//! S-CPU unchanged. The Super MMC's power-on bank map already reproduces
//! LoROM addressing for banks $00-$3F, so code and data addresses survive
//! as-is. The shell proves the cart conversion and the boot protocol under
//! the differential harness — every frame must render identically — and is
//! the platform every later migration step stands on.
//!
//! **The state relocation.** Execute stage S2's plan: rewrite every executed
//! instruction whose operand statically names a byte of a relocated WRAM
//! region to the region's new home — I-RAM (S-CPU window $3000-$37FF) or
//! BW-RAM (banks $40+). Both memories are visible to BOTH CPUs, which is the
//! trick: state can move before execution does, the game still runs entirely
//! on the S-CPU, and the differential gate proves the rewrite preserved
//! behavior. When execution later migrates (stage S3b), the state is already
//! on the SA-1's side of the wall.
//!
//! What counts as statically nameable, and what refuses — fed by the S1
//! coverage map (opcode positions and M/X widths from real execution, so the
//! walk decodes exactly the instructions that ran):
//!
//! - **long / long,X operands** naming $7E/$7F (or a bank-$00-$3F low
//!   mirror): rewritten in place, exact.
//! - **absolute operands** under $2000: the WRAM low mirror, the same byte
//!   under every system-bank DB — rewritten to the I-RAM window (also
//!   present in every system bank). A site whose region went to BW-RAM
//!   cannot be re-pointed in two bytes: the region is blocked instead.
//! - **absolute above $2000**: reaches WRAM only through DB=$7E/7F, which is
//!   invisible statically; never attributed. If the game does this at a
//!   moved region, the desync is exactly what the differential gate exists
//!   to catch.
//! - **indexed absolute / long,X** with a base inside a region: refused, and
//!   the region is blocked — an index can carry the access across the
//!   region's edge, and a moved edge is a silent corruption.
//! - **direct page**: not rewritten per site. When the plan pinned a dp
//!   window, the WHOLE first page moves as a unit and the shim boots the
//!   S-CPU with D=$3000 — every dp operand stays byte-identical. An indexed
//!   dp site (dp,X can walk past $FF) or an abs/abs,X refusal inside the
//!   window blocks the window as a unit and D stays 0.
//!
//! A blocked region simply does not move — its sites are left alone, which
//! is always correct, and the report says why. Code the profile never
//! executed is invisible to the walk; if it touches moved state the
//! differential run diverges and no patch is written. That is the standing
//! contract of the whole ladder: the rewrite may be incomplete, but it may
//! not be silently wrong.

const std = @import("std");
const header_mod = @import("header.zig");
const cartridge = @import("cartridge.zig");
const patchgen = @import("patchgen.zig");
const profile = @import("../profile.zig");
const usage_map = @import("../usage_map.zig");

pub const Error = error{ OutOfMemory, NoHeader, RomTooSmall, Refused };

pub const Reason = enum {
    coprocessor,
    not_lorom,
    has_sram,
    rom_too_big,
    bwram_too_big,
    reset_vector_not_rom,
    no_free_space,
    wg_wram_beyond_iram,
    wg_mmio_shape,
    wg_mmio_outside_bank0,
    wg_uses_irq,
    wg_nmi_ambiguous,
    wg_unsupported_op,

    pub fn describe(self: Reason) []const u8 {
        return switch (self) {
            .coprocessor => "the cartridge already carries a coprocessor",
            .not_lorom => "only LoROM carts convert (the Super MMC's power-on map reproduces LoROM addressing)",
            .has_sram => "the cartridge has its own save RAM; relocating it is not mechanical",
            .rom_too_big => "ROM exceeds 4 MiB, the Super MMC window this conversion maps",
            .bwram_too_big => "the plan needs more BW-RAM than a cart can carry",
            .reset_vector_not_rom => "the reset vector does not point into ROM",
            .no_free_space => "no padding run in bank $00 is large enough for the boot shim",
            .wg_wram_beyond_iram => "whole-game migration needs the WRAM working set inside $0000-$07FF (the SA-1's identity-mapped I-RAM)",
            .wg_mmio_shape => "an MMIO access is not a plain LDA/STA/STZ absolute — not proxyable in place",
            .wg_mmio_outside_bank0 => "an MMIO site executes outside bank $00 code; its in-place JSR can only reach helpers carved in its own bank",
            .wg_uses_irq => "the game takes IRQs; whole-game migration forwards only NMI so far",
            .wg_nmi_ambiguous => "native and emulation NMI handlers both ran and differ; the SA-1's CNV can point at only one",
            .wg_unsupported_op => "an executed instruction (block move, BRK/COP, STP) cannot run on the SA-1 side",
        };
    }
};

pub const Refusal = struct {
    reason: Reason,
    detail: u32 = 0,
};

/// Why a plan region did not move. `clean` means it did.
pub const RegionFate = enum { clean, blocked_indexed, blocked_abs_to_bwram, not_attempted };

pub const Stats = struct {
    shim_addr: u16 = 0,
    park_addr: u16 = 0,
    rewritten_long: u32 = 0,
    rewritten_abs: u32 = 0,
    /// dp sites covered wholesale by the D=$3000 window move.
    dp_sites: u32 = 0,
    regions_moved: u8 = 0,
    regions_blocked: u8 = 0,
    /// The S-CPU boots with D=$3000 (the dp window moved).
    d_moved: bool = false,
    /// S3b: the entry of the routine now executing on the SA-1, when one
    /// passed the leaf-eligibility walk. 0 = none offloaded.
    offloaded: u24 = 0,
    /// JSR call sites re-pointed at the offload stubs.
    offload_sites: u32 = 0,
    /// How many routines were offloaded (message ids 1..count).
    offload_count: u8 = 0,
    /// How many of those went through the pointer-offload path (JSL/RTL
    /// routines running against the BW-RAM shadow).
    pointer_offloads: u8 = 0,
    /// The offloaded entries in message-id order, and which of them are
    /// pointer offloads (bit i = entry i) — the auto-bisect loop drops
    /// culprits by name when verification fails.
    offload_entries: [offload_max]u24 = @splat(0),
    offload_ptr_mask: u8 = 0,
    /// Bytes the pointer offloads marshal per call (both directions), and
    /// sibling entry points whose working sets were folded in.
    marshal_bytes: u32 = 0,
    marshal_siblings: u32 = 0,
};

pub const Result = struct {
    image: []u8,
    stats: Stats,
    /// Per plan region (same order), what happened to it.
    fate: [profile.plan_region_cap]RegionFate,
    /// Per plan region, how many sites the rewriter actually re-pointed.
    /// A "clean" region with zero sites moved vacuously — nothing refers
    /// to its new home, so its I-RAM/BW-RAM bytes are dead storage the
    /// offload machinery may safely overlay.
    region_sites: [profile.plan_region_cap]u32 = @splat(0),
};

/// A hot routine considered for execution offload: the entry, plus its
/// profiled WRAM page bitmap — the dynamic evidence the pointer-offload
/// path marshals as a BW-RAM shadow. An empty bitmap limits the routine to
/// the static leaf walk.
pub const Candidate = struct {
    entry: u24,
    pages: profile.WramPages = @splat(0),
    /// Measured self cycles and calls, for the marshal-cost budget: an
    /// offload that spends more moving state than the routine spends
    /// computing is a regression however correct it is.
    self_cycles: u64 = 0,
    calls: u64 = 0,
};

/// Convert a plain LoROM image into an SA-1 cart per `plan`. `usage` is the
/// S1 coverage map's CPU block (null: shell only, nothing relocates —
/// `plan` may also be empty/nonviable for the same effect). `refusal` is
/// written only on `error.Refused`.
pub fn convert(
    gpa: std.mem.Allocator,
    image: []const u8,
    plan: *const profile.Plan,
    usage: ?[]const u8,
    /// Hot routines (the conversion verdict's set) considered for
    /// execution offload; empty skips S3b entirely.
    candidates: []const Candidate,
    /// Every OTHER profiled routine, for sibling lookup: an alternate
    /// entry point into an offloaded routine's body shares its working
    /// set, and the marshal must cover the union even though the sibling
    /// itself is far too cold to be a candidate. Empty is safe (the union
    /// simply finds nothing) — it is evidence, not correctness.
    neighbours: []const Candidate,
    refusal: *?Refusal,
) Error!Result {
    if (image.len < 0x8000) return error.RomTooSmall;
    const header = try header_mod.detect(image);

    if (cartridge.identifyChip(header) != .none) return refuse(refusal, .{ .reason = .coprocessor });
    if (header.mapping != .lorom) return refuse(refusal, .{ .reason = .not_lorom });
    if (header.sramBytes() != 0) return refuse(refusal, .{ .reason = .has_sram });
    if (image.len > 4 << 20) return refuse(refusal, .{ .reason = .rom_too_big });
    if (plan.viable and plan.bwram_used > cartridge.max_sram)
        return refuse(refusal, .{ .reason = .bwram_too_big, .detail = plan.bwram_used });
    const reset = header.reset_vector;
    if (reset < 0x8000) return refuse(refusal, .{ .reason = .reset_vector_not_rom });

    const carve = patchgen.findFreeSpace(image[0..header.offset], shim_len_max + park_len) orelse
        return refuse(refusal, .{ .reason = .no_free_space, .detail = shim_len_max + park_len });

    const out = try gpa.dupe(u8, image);
    errdefer gpa.free(out);

    var res: Result = .{
        .image = out,
        .stats = .{},
        .fate = @splat(.not_attempted),
    };

    // --- the relocation, first: whether D moves decides the shim ----------
    if (plan.viable and usage != null) rewrite(out, plan, usage.?, &res);

    // --- header -----------------------------------------------------------
    out[header.offset + 0x15] = 0x23; // SA-1 map mode
    out[header.offset + 0x16] = 0x35; // SA-1 + RAM + battery
    // BW-RAM: at least the SA-1-standard 32 KiB, more if the plan spilled.
    out[header.offset + 0x18] = if (plan.viable and plan.bwram_used > 32 * 1024) 0x07 else 0x05;

    // --- S3b: execution offload, before the shim (it decides CRV) ---------
    var crv: u16 = 0x8000 + @as(u16, @intCast(carve)) + @as(u16, @intCast(shim_len_max));
    if (usage != null and plan.viable) tryOffload(out, plan, usage.?, candidates, neighbours, carve, &res, &crv);
    // The pointer-offload shadow lives at BW-RAM linear $10000+ (bank
    // $41): the cart must carry the full 128 KiB.
    if (res.stats.pointer_offloads > 0 and out[header.offset + 0x18] < 0x07)
        out[header.offset + 0x18] = 0x07;

    // --- the S-CPU boot shim and the SA-1 park stub -----------------------
    const shim_addr: u16 = 0x8000 + @as(u16, @intCast(carve));
    var w = out[carve..];
    var n: usize = 0;
    w[n] = 0x78; // SEI
    n += 1;
    if (res.stats.d_moved) {
        // PEA $3000 / PLD: the whole dp window now lives in I-RAM.
        w[n] = 0xF4;
        w[n + 1] = 0x00;
        w[n + 2] = 0x30;
        w[n + 3] = 0x2B;
        n += 4;
    }
    n = emitStore(w, n, 0x2229, 0xFF); // SIWP: allow S-CPU I-RAM writes
    n = emitStore(w, n, 0x2226, 0x80); // SWEN: allow S-CPU BW-RAM writes
    const park_addr: u16 = shim_addr + @as(u16, @intCast(shim_len_max));
    n = emitStore(w, n, 0x2203, @truncate(crv)); // CRV low
    n = emitStore(w, n, 0x2204, @truncate(crv >> 8)); // CRV high
    w[n] = 0x9C; // STZ $2200: release the SA-1 from reset -> boots from CRV
    w[n + 1] = 0x00;
    w[n + 2] = 0x22;
    n += 3;
    w[n] = 0x4C; // JMP <original reset>: the game continues on the S-CPU
    w[n + 1] = @truncate(reset);
    w[n + 2] = @truncate(reset >> 8);
    // Park stub at a fixed offset so CRV was knowable above.
    out[carve + shim_len_max] = 0x78; // SEI
    out[carve + shim_len_max + 1] = 0xDB; // STP: the SA-1 idles until offloaded work exists

    std.mem.writeInt(u16, out[header.offset + 0x3C ..][0..2], shim_addr, .little);
    patchgen.recomputeChecksum(out, header.offset);

    res.stats.shim_addr = shim_addr;
    res.stats.park_addr = park_addr;
    return res;
}

/// Worst-case shim size (with the D move): SEI + PEA/PLD + 4 stores + STZ +
/// JMP = 1 + 4 + 20 + 3 + 3 = 31; rounded up for slack.
const shim_len_max: u32 = 32;
const park_len: u32 = 2;

fn emitStore(w: []u8, n: usize, reg: u16, value: u8) usize {
    w[n] = 0xA9; // LDA #value
    w[n + 1] = value;
    w[n + 2] = 0x8D; // STA reg
    w[n + 3] = @truncate(reg);
    w[n + 4] = @truncate(reg >> 8);
    return n + 5;
}

fn refuse(refusal: *?Refusal, r: Refusal) Error {
    refusal.* = r;
    return error.Refused;
}

/// One executed instruction site naming WRAM, as the walk classifies it.
const Site = struct {
    file_off: u32, // of the opcode byte
    mode: usage_map.Mode,
    wram_off: u32, // linear WRAM offset the operand names
    region: u8, // plan region index
};

/// Walk every executed instruction (S1's Opcode flags over the LoROM code
/// banks), attribute statically-nameable WRAM operands to plan regions,
/// block regions with unsound sites, then rewrite the sites of the clean
/// ones. Two passes over the same walk, so nothing is patched for a region
/// that a later site condemns.
fn rewrite(
    out: []u8,
    plan: *const profile.Plan,
    usage: []const u8,
    res: *Result,
) void {
    for (plan.regions[0..plan.n], 0..) |_, i| res.fate[i] = .clean;

    var pass: u2 = 0;
    while (pass < 2) : (pass += 1) {
        var bank: u32 = 0;
        while (bank < 0x40) : (bank += 1) {
            const bank_file = bank * 0x8000;
            if (bank_file >= out.len) break;
            var a16: u32 = 0x8000;
            while (a16 < 0x10000) : (a16 += 1) {
                const cpu_addr = (bank << 16) | a16;
                const flags = usage[cpu_addr];
                if (flags & usage_map.flag_opcode == 0) continue;
                const file_off = bank_file + (a16 - 0x8000);
                if (file_off >= out.len) break;
                const op = out[file_off];
                const m8 = flags & usage_map.flag_m != 0;
                const x8 = flags & usage_map.flag_x != 0;
                const len = usage_map.instrLen(op, m8, x8);
                if (file_off + len > out.len) continue;

                const md = usage_map.mode(op);
                const operand = out[file_off + 1 ..];
                const wram_off: u32 = switch (md) {
                    .none => continue,
                    .dp, .dp_idx => operand[0],
                    .abs, .abs_x, .abs_y => blk: {
                        const v = std.mem.readInt(u16, operand[0..2], .little);
                        if (v >= 0x2000) continue; // DB-dependent: unattributable
                        break :blk v;
                    },
                    .long, .long_x => blk: {
                        const b = operand[2];
                        const v = std.mem.readInt(u16, operand[0..2], .little);
                        if (b == 0x7E) break :blk v;
                        if (b == 0x7F) break :blk @as(u32, 0x10000) + v;
                        if ((b & 0x7F) <= 0x3F and v < 0x2000) break :blk v; // low mirror
                        continue;
                    },
                };

                const region: u8 = for (plan.regions[0..plan.n], 0..) |r, ri| {
                    if (wram_off >= r.start and wram_off < r.start + r.len)
                        break @intCast(ri);
                } else continue;
                const r = &plan.regions[region];

                if (pass == 0) {
                    // Judgement pass: what would sink this region's move?
                    switch (md) {
                        // An index can carry the access past the region
                        // edge; inside the dp window, dp,X is the same
                        // hazard. Refuse, per the ladder's contract.
                        .abs_x, .abs_y, .long_x, .dp_idx => res.fate[region] = .blocked_indexed,
                        .abs => if (r.dest == .bwram) {
                            res.fate[region] = .blocked_abs_to_bwram;
                        },
                        .dp => if (!r.dp) {
                            // A dp operand resolving into a non-dp region
                            // means D was nonzero at that site: the static
                            // model is wrong for it — block the region.
                            res.fate[region] = .blocked_indexed;
                        },
                        else => {},
                    }
                } else if (res.fate[region] == .clean) {
                    // Rewrite pass, clean regions only. Indexed sites never
                    // get here — pass 0 blocked their regions.
                    const within = wram_off - r.start;
                    res.region_sites[region] += 1;
                    switch (md) {
                        .dp => res.stats.dp_sites += 1, // covered by D=$3000
                        .abs => {
                            const dest16: u16 = @intCast(0x3000 + r.dest_off + within);
                            std.mem.writeInt(u16, operand[0..2], dest16, .little);
                            res.stats.rewritten_abs += 1;
                        },
                        .long => {
                            const dest: u32 = switch (r.dest) {
                                .iram => 0x3000 + r.dest_off + within,
                                .bwram => 0x40_0000 + r.dest_off + within,
                            };
                            operand[0] = @truncate(dest);
                            operand[1] = @truncate(dest >> 8);
                            operand[2] = @truncate(dest >> 16);
                            res.stats.rewritten_long += 1;
                        },
                        else => unreachable, // indexed sites blocked in pass 0
                    }
                }
            }
        }
        if (pass == 0) {
            // A blocked dp-window region pins D at 0, which unblocks nothing
            // else but must un-move every other dp region too: the window
            // moves as a unit or not at all.
            var dp_blocked = false;
            for (plan.regions[0..plan.n], 0..) |r, ri| {
                if (r.dp and res.fate[ri] != .clean) dp_blocked = true;
            }
            if (dp_blocked) {
                for (plan.regions[0..plan.n], 0..) |r, ri| {
                    if (r.dp and res.fate[ri] == .clean) res.fate[ri] = .blocked_indexed;
                }
            } else {
                for (plan.regions[0..plan.n], 0..) |r, ri| {
                    if (r.dp and res.fate[ri] == .clean) res.stats.d_moved = true;
                }
            }
        }
    }

    for (res.fate[0..plan.n]) |f| {
        switch (f) {
            .clean => res.stats.regions_moved += 1,
            .blocked_indexed, .blocked_abs_to_bwram => res.stats.regions_blocked += 1,
            .not_attempted => {},
        }
    }
}

/// The I-RAM mailbox the offload handshake marshals registers through
/// (window addresses $3780-$3786: A, X, Y 16-bit; P 8-bit at +6). The SA-1's
/// stack is parked just below it. Plans that filled I-RAM past $3700 skip
/// offload rather than collide.
const mailbox: u16 = 0x3780;
const iram_offload_limit: u32 = 0x700;

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
const shadow_linear: u32 = 0x1_0000;
const shadow_bank: u8 = 0x41;
const ptr_slot_cap = 6;
const ptr_db_cap = 4;
const ptr_run_cap = 8;
const ptr_pages_cap = 32;

/// Master cycles the S-CPU's MVN spends per byte, each way. The marshal
/// copies the working set in and out, so a page costs 2 * 256 * this.
const mvn_cycles_per_byte: u64 = 7;

/// The marshal must cost less than this fraction of what the routine
/// actually spends computing, per call — otherwise the "offload" is a
/// regression dressed as a conversion. Half is deliberately conservative:
/// the SA-1 runs the work at ~2.7x the S-CPU's clock with no bus
/// contention, so a marshal at half the routine's own cost still leaves a
/// real win, and anything dearer is refused rather than shipped and
/// measured later.
const marshal_budget_num: u64 = 1;
const marshal_budget_den: u64 = 2;

/// What the pointer-eligibility walk proves about a routine.
const PtrSpec = struct {
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
};

/// The routine's profiled WRAM pages coalesced into marshal runs (split at
/// the $7E/$7F boundary so each run has one MVN bank pair).
const Runs = struct {
    start: [ptr_run_cap]u16 = undefined, // first page index
    len: [ptr_run_cap]u16 = undefined, // pages
    n: usize = 0,
};

fn pageRuns(pages: profile.WramPages) ?Runs {
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
    if (total == 0 or total > ptr_pages_cap) return null;
    return runs;
}

const OffloadKind = enum { leaf, ptr };

const Chosen = struct {
    entry: u16,
    kind: OffloadKind,
    spec: PtrSpec = .{},
    runs: Runs = .{},
    /// Sibling entry points inside this routine's span whose page sets
    /// were folded into the marshal set.
    siblings: u32 = 0,
    /// Where the SA-1's rewritten copy of a pointer routine landed (the
    /// dispatcher JSLs it; the original body is never modified).
    copy_addr: u16 = 0,
    copy_bank: u8 = 0,
};

fn tryOffload(
    out: []u8,
    plan: *const profile.Plan,
    usage: []const u8,
    candidates: []const Candidate,
    neighbours: []const Candidate,
    shim_carve: u32,
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
        var marshal_pages = c.pages;
        var siblings: u32 = 0;
        for ([_][]const Candidate{ candidates, neighbours }) |list| {
            for (list) |o| {
                if (o.entry == c.entry) continue;
                if (o.entry < c.entry or o.entry - c.entry >= spec.span) continue;
                for (&marshal_pages, o.pages) |*p, op| p.* |= op;
                siblings += 1;
            }
        }
        const runs = pageRuns(marshal_pages) orelse continue;
        // Economics: the marshal must be cheaper than the compute it
        // enables. Candidates with no measured calls skip the test (the
        // synthetic unit tests, which carry no profile).
        if (c.calls != 0) {
            var bytes: u64 = 0;
            for (0..runs.n) |r| bytes += @as(u64, runs.len[r]) * 256;
            const marshal_cost = bytes * 2 * mvn_cycles_per_byte;
            const per_call = c.self_cycles / c.calls;
            if (marshal_cost * marshal_budget_den > per_call * marshal_budget_num) continue;
        }
        if (countCallSites(out, usage, e, 0x22) == 0) continue;
        chosen[n] = .{ .entry = e, .kind = .ptr, .spec = spec, .runs = runs, .siblings = siblings };
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
                blocks_len += 25;
                ptr_stub_len += ptrStubLen(c.spec, c.runs) + c.spec.span;
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
                const stub_file = ptr_cur;
                const emitted = emitPtrStub(out[stub_file..], id, c.spec, c.runs);
                std.debug.assert(emitted == ptrStubLen(c.spec, c.runs));
                ptr_cur += emitted;
                // The SA-1's copy of the body, immediately after the stub:
                // the DB idiom's bank immediates become the shadow bank,
                // and intra-span JMP targets are re-based. The ORIGINAL
                // body stays untouched for unseen S-CPU callers.
                const copy_file = ptr_cur;
                const entry_file: u32 = c.entry - 0x8000;
                @memcpy(out[copy_file..][0..c.spec.span], out[entry_file..][0..c.spec.span]);
                for (c.spec.db_sites[0..c.spec.n_db]) |site| {
                    std.debug.assert(out[copy_file + (site - entry_file)] == 0x7E);
                    out[copy_file + (site - entry_file)] = shadow_bank;
                }
                c.copy_bank = @intCast(copy_file / 0x8000);
                c.copy_addr = @intCast(0x8000 + (copy_file % 0x8000));
                fixupJmps(out, usage, c.entry, c.spec.span, copy_file, c.copy_addr);
                ptr_cur += c.spec.span;
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
                put(d, &cur, &.{ 0xC9, id, 0xD0, 0x15 });
                putJsr(d, &cur, unm_addr);
                put(d, &cur, &.{ 0xF4, 0x00, 0x60, 0x2B }); // PEA $6000 / PLD
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
fn iramLive(plan: *const profile.Plan, res: *const Result) u32 {
    var live: u32 = 0;
    for (plan.regions[0..plan.n], 0..) |r, ri| {
        if (res.fate[ri] != .clean or r.dest != .iram) continue;
        if (res.region_sites[ri] == 0 and !(r.dp and res.stats.d_moved)) continue;
        live = @max(live, r.dest_off + r.len);
    }
    return live;
}

/// Highest BW-RAM byte carrying live relocated state, for the shadow guard.
fn bwramLive(plan: *const profile.Plan, res: *const Result) u32 {
    var live: u32 = 0;
    for (plan.regions[0..plan.n], 0..) |r, ri| {
        if (res.fate[ri] != .clean or r.dest != .bwram) continue;
        if (res.region_sites[ri] == 0) continue;
        live = @max(live, r.dest_off + r.len);
    }
    return live;
}

/// Re-base intra-span JMP abs targets in a pointer routine's copy. All
/// other flow in the span is relative (branches, BRL) and relocates for
/// free; the eligibility walk refused everything else.
fn fixupJmps(out: []u8, usage: []const u8, entry: u16, span: u32, copy_file: u32, copy_addr: u16) void {
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

fn dropPtr(chosen: *[offload_max]Chosen, n: *usize) void {
    var w: usize = 0;
    for (chosen[0..n.*]) |c| {
        if (c.kind == .leaf) {
            chosen[w] = c;
            w += 1;
        }
    }
    n.* = w;
}

fn put(d: []u8, cur: *usize, bytes: []const u8) void {
    @memcpy(d[cur.*..][0..bytes.len], bytes);
    cur.* += bytes.len;
}

fn putJsr(d: []u8, cur: *usize, target: u16) void {
    put(d, cur, &.{ 0x20, @truncate(target), @truncate(target >> 8) });
}

/// Count executed call sites of `entry` (bank $00): `op` is 0x20 (JSR,
/// scanned in bank $00 — a JSR's target shares the caller's bank) or 0x22
/// (JSL with an explicit bank-$00 target, scanned across every bank,
/// executed flags merged over the $80+ fast mirrors).
fn countCallSites(out: []const u8, usage: []const u8, entry: u16, op: u8) u32 {
    return callSites(out, null, usage, entry, op, 0, 0);
}

/// Re-point every executed call site of `entry` at the stub. JSR sites take
/// a 16-bit target (stub in bank $00); JSL sites take the full 24-bit stub
/// address. Returns the number rewritten.
fn rewriteCallSites(out: []u8, usage: []const u8, entry: u16, op: u8, stub_addr: u16, stub_bank: u8) u32 {
    return callSites(out, out, usage, entry, op, stub_addr, stub_bank);
}

fn callSites(ro: []const u8, rw: ?[]u8, usage: []const u8, entry: u16, op: u8, stub_addr: u16, stub_bank: u8) u32 {
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
/// can (return shape, span containment, no MMIO/abs/stack-relative sites,
/// the DB idiom, the long-pointer bank slots); the pointer VALUES are
/// dynamic evidence — anything they reach outside the marshalled shadow
/// diverges in S4 verification and no patch ships. Refusal here is a skip,
/// not an error: the routine simply stays on the S-CPU.
fn eligiblePointer(out: []const u8, usage: []const u8, entry: u16) ?PtrSpec {
    const span_max: u32 = 1024;
    var spec: PtrSpec = .{};
    var has_idp = false;
    var pc: u32 = entry;
    var limit: u32 = entry;
    while (pc - entry < span_max) {
        if (pc > 0xFFFF) return null;
        if (usage[pc] & usage_map.flag_opcode == 0) {
            // A gap (data or never-taken padding) is fine while pending
            // flow still reaches past it; a gap at the frontier is not.
            if (pc >= limit) return null;
            pc += 1;
            continue;
        }
        const file = pc - 0x8000;
        const op = out[file];
        const m8 = usage[pc] & usage_map.flag_m != 0;
        const x8 = usage[pc] & usage_map.flag_x != 0;
        const len = usage_map.instrLen(op, m8, x8);
        switch (op) {
            0x6B => { // RTL: done once every pending path has closed
                if (pc >= limit) {
                    if (has_idp and spec.n_db == 0) return null;
                    spec.span = pc + 1 - entry;
                    return spec;
                }
            },
            // Wrong return shape, calls, far jumps, block moves,
            // interrupt-adjacent, D/S relocation: not this routine.
            0x60, 0x40, 0x20, 0x22, 0xFC, 0x5C, 0x6C, 0x7C, 0xDC => return null,
            0x00, 0x02, 0xCB, 0xDB, 0x44, 0x54 => return null,
            0x2B, 0x5B, 0x1B, 0x9A, 0xFB, 0x58 => return null,
            0x4C => { // JMP abs: intra-span only
                const dst: u32 = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                if (dst < entry or dst - entry >= span_max) return null;
                limit = @max(limit, dst);
            },
            0x82 => { // BRL
                const disp: i16 = @bitCast(std.mem.readInt(u16, out[file + 1 ..][0..2], .little));
                const dst = pc + 3 +% @as(u32, @bitCast(@as(i32, disp)));
                if (dst < entry or dst - entry >= span_max) return null;
                limit = @max(limit, dst);
            },
            0x10, 0x30, 0x50, 0x70, 0x80, 0x90, 0xB0, 0xD0, 0xF0 => {
                const dst = pc + 2 +% @as(u32, @bitCast(@as(i32, @as(i8, @bitCast(out[file + 1])))));
                if (dst < entry or dst - entry >= span_max) return null;
                limit = @max(limit, dst);
            },
            0xA9 => if (m8 and out[file + 1] == 0x7E) {
                // LDA #$7E / PHA / PLB is the shadow's rewrite point; a
                // bare #$7E has an unknowable purpose — refuse.
                if (file + 3 >= out.len or out[file + 2] != 0x48 or out[file + 3] != 0xAB) return null;
                if (spec.n_db == ptr_db_cap) return null;
                spec.db_sites[spec.n_db] = file + 1;
                spec.n_db += 1;
            },
            else => {},
        }
        // Long-indirect pointers ([dp] / [dp],y, the $x7 column): the bank
        // byte at dp+2 is a translation slot ($7E/$7F -> shadow).
        if (op & 0x0F == 0x07) {
            const slot: u16 = @as(u16, out[file + 1]) + 2;
            if (slot > 0xFF) return null; // bank byte past the dp window
            const dup = for (spec.slots[0..spec.n_slots]) |s| {
                if (s == slot) break true;
            } else false;
            if (!dup) {
                if (spec.n_slots == ptr_slot_cap) return null;
                spec.slots[spec.n_slots] = @intCast(slot);
                spec.n_slots += 1;
            }
        }
        // 16-bit-indirect pointers ((dp) / (dp),y) resolve with DB: only
        // sound once the DB idiom pins it to the shadow. (dp,x) hides the
        // pointer cell behind a runtime index; stack-relative reads the
        // S-CPU stack the SA-1 does not have.
        if (op & 0x1F == 0x11 or op & 0x1F == 0x12) has_idp = true;
        if (op & 0x1F == 0x01 or op & 0x0F == 0x03) return null;
        switch (usage_map.mode(op)) {
            .none, .dp => {},
            // dp,X/dp,Y: a runtime index that can leave the shadow's dp
            // window (8 KiB under D=$6000). Statically unprovable — but
            // the pointer path runs on dynamic evidence: an index that
            // actually left the marshalled shadow reads ROM instead of
            // state, diverges in S4 verification, and no patch ships.
            .dp_idx => {},
            .abs, .abs_x, .abs_y => return null, // DB-relative: unprovable under a rewritten DB
            .long, .long_x => {
                const b = out[file + 3];
                // ROM and BW-RAM read identically on the SA-1; long WRAM
                // or MMIO cannot follow execution across.
                const ok = (b >= 0x40 and b <= 0x4F) or b >= 0xC0 or (b & 0x7F) <= 0x3F;
                if (!ok) return null;
            },
        }
        pc += len;
    }
    return null;
}

/// Byte-exact length of a pointer stub (the emitter asserts against it).
fn ptrStubLen(spec: PtrSpec, runs: Runs) u32 {
    return 100 + 24 * @as(u32, @intCast(runs.n)) + 28 * @as(u32, @intCast(spec.n_slots));
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
fn emitPtrStub(d: []u8, id: u8, spec: PtrSpec, runs: Runs) u32 {
    var cur: usize = 0;
    // Register marshal in (33). PHB first so the caller P (pushed second)
    // is on top for the PLA below.
    put(d, &cur, &.{ 0x8B, 0x08, 0xE2, 0x20 }); // PHB / PHP / SEP #$20
    put(d, &cur, &.{ 0x8F, 0x80, 0x37, 0x00, 0xEB, 0x8F, 0x81, 0x37, 0x00, 0xEB }); // A low, B
    put(d, &cur, &.{ 0xC2, 0x30, 0x8A, 0x8F, 0x82, 0x37, 0x00, 0x98, 0x8F, 0x84, 0x37, 0x00 }); // X, Y via A
    put(d, &cur, &.{ 0xE2, 0x20, 0x68, 0x8F, 0x86, 0x37, 0x00 }); // caller P
    // Shadow copy-in (2 + 12/run). MVN encoding: opcode, DEST bank, SRC bank.
    put(d, &cur, &.{ 0xC2, 0x30 });
    for (0..runs.n) |r| putMvnRun(d, &cur, runs.start[r], runs.len[r], false);
    // Slot translate-in (2 + 14/slot): $7E bank bytes -> the shadow bank.
    // (A plain LoROM game has no $40+ pointers to collide with the exact
    // compare; $7F pointers stay untranslated and fail S4 if followed.)
    put(d, &cur, &.{ 0xE2, 0x20 });
    for (spec.slots[0..spec.n_slots]) |s| {
        put(d, &cur, &.{ 0xAF, s, 0x00, shadow_bank, 0xC9, 0x7E, 0xD0, 0x06, 0xA9, shadow_bank, 0x8F, s, 0x00, shadow_bank });
    }
    // Send + double handshake (30), all long-addressed.
    put(d, &cur, &.{ 0xA9, id, 0x8F, 0x00, 0x22, 0x00 }); // message id -> CFR
    put(d, &cur, &.{ 0xAF, 0x00, 0x23, 0x00, 0x29, 0x0F, 0xC9, id, 0xD0, 0xF6 }); // await echo
    put(d, &cur, &.{ 0xA9, 0x00, 0x8F, 0x00, 0x22, 0x00 }); // ack
    put(d, &cur, &.{ 0xAF, 0x00, 0x23, 0x00, 0x29, 0x0F, 0xD0, 0xF8 }); // await clear
    // Slot translate-back (14/slot).
    for (spec.slots[0..spec.n_slots]) |s| {
        put(d, &cur, &.{ 0xAF, s, 0x00, shadow_bank, 0xC9, shadow_bank, 0xD0, 0x06, 0xA9, 0x7E, 0x8F, s, 0x00, shadow_bank });
    }
    // Shadow copy-out (2 + 12/run).
    put(d, &cur, &.{ 0xC2, 0x30 });
    for (0..runs.n) |r| putMvnRun(d, &cur, runs.start[r], runs.len[r], true);
    // Restore caller DB, then unmarshal — long-addressed, so DB-proof (30).
    put(d, &cur, &.{0xAB}); // PLB
    put(d, &cur, &.{ 0xC2, 0x30, 0xAF, 0x82, 0x37, 0x00, 0xAA, 0xAF, 0x84, 0x37, 0x00, 0xA8 }); // X, Y
    put(d, &cur, &.{ 0xE2, 0x20, 0xAF, 0x86, 0x37, 0x00, 0x48 }); // exit P staged
    put(d, &cur, &.{ 0xAF, 0x81, 0x37, 0x00, 0xEB, 0xAF, 0x80, 0x37, 0x00 }); // B, A low
    put(d, &cur, &.{ 0x28, 0x6B }); // PLP (exit flags/widths) / RTL
    return @intCast(cur);
}

/// One MVN marshal run: pages [start, start+len) of $7E WRAM to/from the
/// identity-offset shadow at bank $41. `back` copies shadow -> WRAM.
fn putMvnRun(d: []u8, cur: *usize, start_page: u16, n_pages: u16, back: bool) void {
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
fn eligibleLeaf(out: []const u8, usage: []const u8, plan: *const profile.Plan, res: *const Result, entry: u16) bool {
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

fn dpMoved(plan: *const profile.Plan, res: *const Result, off: u32) bool {
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
const stub_template = [_]u8{
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
const stub_id_send_off: usize = 24;
const stub_id_cmp_off: usize = 34;

comptime {
    std.debug.assert(stub_template[stub_id_send_off - 1] == 0xA9); // LDA #
    std.debug.assert(stub_template[stub_id_cmp_off - 1] == 0xC9); // CMP #
    std.debug.assert(stub_template.len == 68);
}

// --- whole-game migration ------------------------------------------------------
//
// The SA-1 Root architecture: the ENTIRE game executes on the SA-1 and the
// S-CPU becomes a service loop. The vertical slice built here leans on one
// mapping fact: the SA-1's I-RAM occupies $0000-$07FF of its bus — exactly
// where the S-CPU sees WRAM's low mirror — so a game whose WRAM working set
// (per the S1 coverage map's effective addresses: dp, stack, and indirect
// accesses included) fits under $07F0 needs NO WRAM rewriting at all: its
// dp and low-absolute accesses land in I-RAM natively, and ROM addressing
// is identical on both CPUs through the Super MMC. What must change: every
// executed MMIO site becomes a same-length JSR to an emitted helper that
// files a request through an I-RAM mailbox (reserved tail $37F0: status,
// reg, value) which the S-CPU service loop performs on the real bus.
//
// NMI crosses the wall in two hops with a mask making it safe: an S-CPU
// stub acks $4210 and sends the SA-1 an NMI message (CCNT bit 4); CNV
// lands on an emitted SA-1 shim that acks the message (CIC) and jumps to
// the game's own handler. Because that handler's MMIO sites file requests
// through the same mailbox, every helper masks the message NMI (CIE) for
// the span of its transaction — a message that arrives meanwhile latches
// and delivers on the unmask, so an in-flight request can never be
// corrupted by a nested one.
//
// Refusal-first, as always: WRAM touched beyond the window (or inside the
// reserved mailbox tail), IRQ use, ambiguous NMI handlers, MMIO in any
// shape but plain LDA/STA/STZ absolute in bank $00 code, block moves,
// BRK/COP, STP — each refuses by name. DMA the game programs is performed
// by the S-CPU verbatim; sources in the I-RAM window are NOT translated
// (the S-CPU's WRAM is a different memory), and WRAM-port ($2180-$2183)
// traffic lands in real WRAM, not I-RAM — either mismatch fails S4
// verification rather than shipping wrong.

/// I-RAM mailbox (S-CPU window addresses): +0 status, +1/2 reg, +3/4 value.
/// Status: 0 idle, 1 write8 filed, 2 read8 filed, 3 write16 filed,
/// 4 read16 filed, $FE read served — >= 5 means busy, not a request.
const wg_mailbox: u16 = 0x37F0;

const WgSiteKind = enum { w8, w16, r8, r16, stz8, stz16 };
const WgSite = struct { file: u32, kind: WgSiteKind, reg: u16 };
const wg_sites_max = 96;

const wg_prologue_len = 21;
const wg_sa1_nmi_len = 18;
const wg_scpu_nmi_len = 19;
const wg_shim_len = 37;

/// The S-CPU service loop: position-independent (relative branches only),
/// 8-bit M/X except the marked 16-bit windows. Performs each filed MMIO
/// request on the real bus through a dp pointer at $00-$02 (the S-CPU's
/// WRAM dp is free — the game left). Reads answer with the $FE "served"
/// marker and the SA-1 releases the mailbox after collecting the result,
/// so the mailbox stays owned end to end.
const wg_service = [_]u8{
    0x18, 0xFB, 0xE2, 0x30, // CLC / XCE / SEP #$30
    // loop (+4):
    0xAD, 0xF0, 0x37, 0xF0, 0xFB, // LDA status / BEQ loop
    0xC9, 0x05, 0xB0, 0xF7, // CMP #5 / BCS loop (busy markers, not requests)
    0xAD, 0xF1, 0x37, 0x85, 0x00, // reg -> dp pointer
    0xAD, 0xF2, 0x37, 0x85, 0x01,
    0x64, 0x02, // bank $00
    0xAD, 0xF0, 0x37, // reload the kind
    0xC9, 0x02, 0xF0, 0x12, // -> r8  (+18)
    0xC9, 0x03, 0xF0, 0x1A, // -> w16 (+26)
    0xC9, 0x04, 0xF0, 0x21, // -> r16 (+33)
    0xAD, 0xF3, 0x37, 0x87, 0x00, // w8: value -> [reg]
    // clr (+45):
    0x9C, 0xF0, 0x37, 0x80, 0xD2, // STZ status / BRA loop
    // r8 (+50):
    0xA7, 0x00, 0x8D, 0xF3, 0x37, // [reg] -> value
    0xA9, 0xFE, 0x8D, 0xF0, 0x37, 0x80, 0xC6, // status = served / BRA loop
    // w16 (+62):
    0xC2, 0x20, 0xAD, 0xF3, 0x37, 0x87, 0x00, 0xE2, 0x20, 0x80, 0xE4, // BRA clr
    // r16 (+73):
    0xC2, 0x20, 0xA7, 0x00, 0x8D, 0xF3, 0x37, 0xE2, 0x20,
    0xA9, 0xFE, 0x8D, 0xF0, 0x37, 0x80, 0xAB, // status = served / BRA loop
};

comptime {
    std.debug.assert(wg_service.len == 89);
}

/// Convert for whole-game migration. Needs only the coverage map — no plan:
/// state stays at its own addresses inside the identity window.
pub fn convertWholeGame(
    gpa: std.mem.Allocator,
    image: []const u8,
    usage: []const u8,
    refusal: *?Refusal,
) Error!Result {
    if (image.len < 0x8000) return error.RomTooSmall;
    const header = try header_mod.detect(image);
    if (cartridge.identifyChip(header) != .none) return refuse(refusal, .{ .reason = .coprocessor });
    if (header.mapping != .lorom) return refuse(refusal, .{ .reason = .not_lorom });
    if (header.sramBytes() != 0) return refuse(refusal, .{ .reason = .has_sram });
    if (image.len > 4 << 20) return refuse(refusal, .{ .reason = .rom_too_big });
    const reset = header.reset_vector;
    if (reset < 0x8000) return refuse(refusal, .{ .reason = .reset_vector_not_rom });
    // Executed flags are merged across the $80-$BF fast mirrors throughout:
    // the same ROM byte, the same file offset, possibly only ever executed
    // through the mirror.
    // IRQ vectors with executed targets = the game takes IRQs.
    for ([_]u32{ 0x2E, 0x3E }) |off| {
        const v: u32 = std.mem.readInt(u16, image[header.offset + off ..][0..2], .little);
        if (v >= 0x8000 and v != 0xFFFF and
            (usage[v] | usage[0x80_0000 | v]) & usage_map.flag_opcode != 0)
            return refuse(refusal, .{ .reason = .wg_uses_irq });
    }
    // The SA-1 serves CNV for both the native and the emulation NMI pull,
    // so only one game handler can survive the migration. Pick the one
    // that actually ran; if both ran and differ, refuse.
    const nmi_native = std.mem.readInt(u16, image[header.offset + 0x2A ..][0..2], .little);
    const nmi_emu = std.mem.readInt(u16, image[header.offset + 0x3A ..][0..2], .little);
    const nat_used = nmi_native >= 0x8000 and
        (usage[nmi_native] | usage[0x80_0000 | @as(u32, nmi_native)]) & usage_map.flag_opcode != 0;
    const emu_used = nmi_emu >= 0x8000 and
        (usage[nmi_emu] | usage[0x80_0000 | @as(u32, nmi_emu)]) & usage_map.flag_opcode != 0;
    if (nat_used and emu_used and nmi_native != nmi_emu)
        return refuse(refusal, .{ .reason = .wg_nmi_ambiguous });
    const nmi_target: u16 = if (emu_used and !nat_used) nmi_emu else nmi_native;

    // Every WRAM byte the game touched — by effective address, so dp,
    // stack, and indirect accesses are all covered — must sit inside the
    // identity window, clear of the mailbox tail this conversion reserves.
    {
        const touched = usage_map.flag_read | usage_map.flag_write | usage_map.flag_exec;
        var b: u32 = 0;
        while (b < 0x100) : (b += 1) {
            const sys = b < 0x40 or (b >= 0x80 and b < 0xC0);
            const top: u32 = if (b == 0x7E or b == 0x7F) 0x10000 else if (sys) 0x2000 else 0;
            var a: u32 = 0;
            while (a < top) : (a += 1) {
                if (usage[(b << 16) | a] & touched == 0) continue;
                if (b == 0x7F or a >= 0x7F0)
                    return refuse(refusal, .{ .reason = .wg_wram_beyond_iram, .detail = (b << 16) | a });
            }
        }
    }

    // Eligibility walk + MMIO site collection over every executed opcode.
    var sites: [wg_sites_max]WgSite = undefined;
    var n_sites: usize = 0;
    var bank: u32 = 0;
    while (bank < 0x40) : (bank += 1) {
        const bank_file = bank * 0x8000;
        if (bank_file >= image.len) break;
        var a16: u32 = 0x8000;
        while (a16 < 0x10000) : (a16 += 1) {
            const cpu_addr = (bank << 16) | a16;
            const fl_lo = usage[cpu_addr];
            const fl_hi = usage[0x80_0000 | cpu_addr];
            if ((fl_lo | fl_hi) & usage_map.flag_opcode == 0) continue;
            const file = bank_file + (a16 - 0x8000);
            const op = image[file];
            const fl = if (fl_lo & usage_map.flag_opcode != 0) fl_lo else fl_hi;
            const m8 = fl & usage_map.flag_m != 0;
            // Executed in both mirrors with different M widths: the site
            // has two shapes and a single helper cannot serve both.
            const m_mixed = fl_lo & usage_map.flag_opcode != 0 and
                fl_hi & usage_map.flag_opcode != 0 and
                (fl_lo ^ fl_hi) & usage_map.flag_m != 0;
            switch (op) {
                0x44, 0x54, 0x00, 0x02, 0xDB => return refuse(refusal, .{ .reason = .wg_unsupported_op, .detail = cpu_addr }),
                else => {},
            }
            switch (usage_map.mode(op)) {
                .none, .dp => {},
                .dp_idx => {},
                .abs, .abs_x, .abs_y => {
                    const v = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
                    if (v < 0x800 or v >= 0x8000) continue; // I-RAM window / ROM: fine as-is
                    if (v >= 0x2100 and v < 0x4380) {
                        if (bank != 0)
                            return refuse(refusal, .{ .reason = .wg_mmio_outside_bank0, .detail = cpu_addr });
                        if (m_mixed)
                            return refuse(refusal, .{ .reason = .wg_mmio_shape, .detail = cpu_addr });
                        const kind: WgSiteKind = switch (op) {
                            0xAD => if (m8) WgSiteKind.r8 else .r16,
                            0x8D => if (m8) WgSiteKind.w8 else .w16,
                            0x9C => if (m8) WgSiteKind.stz8 else .stz16,
                            else => return refuse(refusal, .{ .reason = .wg_mmio_shape, .detail = cpu_addr }),
                        };
                        if (n_sites == wg_sites_max)
                            return refuse(refusal, .{ .reason = .wg_mmio_shape, .detail = cpu_addr });
                        sites[n_sites] = .{ .file = file, .kind = kind, .reg = v };
                        n_sites += 1;
                    } else return refuse(refusal, .{ .reason = .wg_wram_beyond_iram, .detail = cpu_addr });
                },
                .long, .long_x => {
                    const b = image[file + 3];
                    const v = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
                    if ((b & 0x7F) <= 0x3F and v >= 0x2100 and v < 0x4380)
                        return refuse(refusal, .{ .reason = .wg_mmio_shape, .detail = cpu_addr });
                    const wram = b == 0x7E or b == 0x7F or ((b & 0x7F) <= 0x3F and v < 0x2000);
                    if (wram and (b == 0x7F or v >= 0x800))
                        return refuse(refusal, .{ .reason = .wg_wram_beyond_iram, .detail = cpu_addr });
                    // $7E:0000-07FF long sites are re-banked to $00 below.
                },
            }
        }
    }

    var helper_len: u32 = 0;
    for (sites[0..n_sites]) |site| helper_len += wgHelperLen(site.kind);
    const need: u32 = wg_prologue_len + wg_sa1_nmi_len + wg_scpu_nmi_len +
        @as(u32, wg_service.len) + wg_shim_len + helper_len;
    const carve = patchgen.findFreeSpace(image[0..header.offset], need) orelse
        return refuse(refusal, .{ .reason = .no_free_space, .detail = need });

    const out = try gpa.dupe(u8, image);
    errdefer gpa.free(out);
    var res: Result = .{ .image = out, .stats = .{}, .fate = @splat(.not_attempted) };

    // Re-bank $7E long sites into the identity window (bank $7E does not
    // exist on the SA-1 bus; bank $00's low $0800 is the same I-RAM).
    bank = 0;
    while (bank < 0x40) : (bank += 1) {
        const bank_file = bank * 0x8000;
        if (bank_file >= out.len) break;
        var a16: u32 = 0x8000;
        while (a16 < 0x10000) : (a16 += 1) {
            const cpu_addr = (bank << 16) | a16;
            if ((usage[cpu_addr] | usage[0x80_0000 | cpu_addr]) & usage_map.flag_opcode == 0) continue;
            const file = bank_file + (a16 - 0x8000);
            const op = out[file];
            switch (usage_map.mode(op)) {
                .long, .long_x => {
                    if (out[file + 3] == 0x7E and std.mem.readInt(u16, out[file + 1 ..][0..2], .little) < 0x800) {
                        out[file + 3] = 0x00;
                        res.stats.rewritten_long += 1;
                    }
                },
                else => {},
            }
        }
    }

    // Emit: helpers first (their addresses feed the site rewrites).
    var cur: usize = 0;
    const base16: u16 = 0x8000 + @as(u16, @intCast(carve));
    const d = out[carve..];
    for (sites[0..n_sites]) |site| {
        const haddr = base16 + @as(u16, @intCast(cur));
        const before = cur;
        wgEmitHelper(d, &cur, site);
        std.debug.assert(cur - before == wgHelperLen(site.kind));
        out[site.file] = 0x20; // JSR (same length as the LDA/STA/STZ it replaces)
        std.mem.writeInt(u16, out[site.file + 1 ..][0..2], haddr, .little);
        res.stats.offload_sites += 1;
    }
    // SA-1 boot: open its I-RAM write gate, prime the NMI clear latch
    // (delivery in the core needs the latch's set->clear edge; priming it
    // makes the very first masked window airtight too), enable the
    // SNES->SA-1 NMI, and enter the game's own reset code.
    const sa1_prologue: u16 = base16 + @as(u16, @intCast(cur));
    put(d, &cur, &.{
        0xA9, 0xFF, 0x8D, 0x2A, 0x22, // CIWP: all I-RAM blocks writable
        0xA9, 0x80, 0x8D, 0x27, 0x22, // CBWE
        0xA9, 0x10, 0x8D, 0x0B, 0x22, // CIC: NMI clear latch primed
        0x8D, 0x0A,             0x22, // CIE: NMI from the SNES enabled (A still $10)
        0x4C, @truncate(reset), @truncate(reset >> 8),
    });
    // SA-1 NMI entry (CNV, native and emulation pulls alike): ack the
    // message via CIC — the game's handler has never heard of it, and a
    // stale flag would re-fire on every helper unmask — preserving A and
    // P, then run the game's own handler; its RTI returns directly.
    const sa1_nmi: u16 = base16 + @as(u16, @intCast(cur));
    put(d, &cur, &.{
        0x08, 0xC2, 0x20, 0x48, 0xE2, 0x20, // PHP / REP #$20 / PHA / SEP #$20
        0xA9, 0x10, 0x8D, 0x0B, 0x22, // CIC: clear the NMI flag
        0xC2, 0x20,                  0x68,                       0x28, // REP #$20 / PLA / PLP
        0x4C, @truncate(nmi_target), @truncate(nmi_target >> 8),
    });
    // S-CPU NMI: ack the S-side latch, forward to the SA-1. Width-agnostic
    // on purpose — an NMI can land inside the service loop's 16-bit spans.
    const scpu_nmi: u16 = base16 + @as(u16, @intCast(cur));
    put(d, &cur, &.{
        0x08, 0xC2, 0x20, 0x48, 0xE2, 0x20, // PHP / REP #$20 / PHA / SEP #$20
        0xAD, 0x10, 0x42, // LDA $4210: ack
        0xA9, 0x10, 0x8D, 0x00, 0x22, // CCNT bit 4: NMI message to the SA-1
        0xC2, 0x20, 0x68, 0x28, 0x40, // REP #$20 / PLA / PLP / RTI
    });
    const svc: u16 = base16 + @as(u16, @intCast(cur));
    put(d, &cur, &wg_service);
    const shim: u16 = base16 + @as(u16, @intCast(cur));
    var w2 = out[carve + cur ..];
    var n2: usize = 0;
    w2[n2] = 0x78; // SEI
    n2 += 1;
    n2 = emitStore(w2, n2, 0x2229, 0xFF);
    n2 = emitStore(w2, n2, 0x2226, 0x80);
    n2 = emitStore(w2, n2, 0x2203, @truncate(sa1_prologue));
    n2 = emitStore(w2, n2, 0x2204, @truncate(sa1_prologue >> 8));
    n2 = emitStore(w2, n2, 0x2205, @truncate(sa1_nmi));
    n2 = emitStore(w2, n2, 0x2206, @truncate(sa1_nmi >> 8));
    w2[n2] = 0x9C; // STZ $2200: release
    w2[n2 + 1] = 0x00;
    w2[n2 + 2] = 0x22;
    n2 += 3;
    w2[n2] = 0x4C; // JMP service loop — the S-CPU never runs the game again
    w2[n2 + 1] = @truncate(svc);
    w2[n2 + 2] = @truncate(svc >> 8);
    n2 += 3;
    std.debug.assert(n2 == wg_shim_len);
    std.debug.assert(cur + n2 == need);

    // Vectors: reset -> shim; NMI (native + emulation) -> the forward stub.
    std.mem.writeInt(u16, out[header.offset + 0x3C ..][0..2], shim, .little);
    std.mem.writeInt(u16, out[header.offset + 0x2A ..][0..2], scpu_nmi, .little);
    std.mem.writeInt(u16, out[header.offset + 0x3A ..][0..2], scpu_nmi, .little);

    out[header.offset + 0x15] = 0x23;
    out[header.offset + 0x16] = 0x35;
    out[header.offset + 0x18] = 0x05;
    patchgen.recomputeChecksum(out, header.offset);

    res.stats.shim_addr = shim;
    res.stats.park_addr = svc;
    res.stats.offloaded = reset;
    res.stats.offload_count = 1;
    return res;
}

fn wgHelperLen(kind: WgSiteKind) u32 {
    return switch (kind) {
        .w8, .stz8 => 36,
        .w16 => 46,
        .r8 => 39,
        .r16 => 47,
        .stz16 => 43,
    };
}

/// One SA-1-side MMIO helper. Every transaction runs with the SNES->SA-1
/// NMI masked (CIE) so the game's NMI handler — whose own MMIO sites file
/// requests through this same mailbox — can never corrupt one in flight;
/// a message that arrives meanwhile latches and delivers on the unmask.
/// Write helpers preserve A and P exactly (their originals did); read
/// helpers end with N/Z reflecting the loaded value and every other flag
/// preserved — again exactly like their originals. X and Y are untouched.
/// Mailbox/CIE absolutes tolerate any system-bank DB: the I-RAM window and
/// the SA-1 registers mirror across banks $00-$3F/$80-$BF.
fn wgEmitHelper(d: []u8, cur: *usize, site: WgSite) void {
    const lo: u8 = @truncate(site.reg);
    const hi: u8 = @truncate(site.reg >> 8);
    switch (site.kind) {
        .w8 => put(d, cur, &.{
            0x9C, 0x0A, 0x22, // STZ CIE: mask (STZ leaves flags alone)
            0x08, 0x48, // PHP / PHA
            0x8D, 0xF3, 0x37, // value
            0xA9, lo,   0x8D,
            0xF1, 0x37, 0xA9,
            hi,   0x8D, 0xF2,
            0x37,
            0xA9, 0x01, 0x8D, 0xF0, 0x37, // filed
            0xAD, 0xF0, 0x37, 0xD0, 0xFB, // until served
            0xA9, 0x10, 0x8D, 0x0A, 0x22, // unmask (a latched NMI lands here)
            0x68, 0x28, 0x60, // PLA / PLP / RTS
        }),
        .stz8 => put(d, cur, &.{
            0x9C, 0x0A, 0x22,
            0x08, 0x48,
            0x9C, 0xF3, 0x37, // value = 0
            0xA9, lo,   0x8D,
            0xF1, 0x37, 0xA9,
            hi,   0x8D, 0xF2,
            0x37, 0xA9, 0x01,
            0x8D, 0xF0, 0x37,
            0xAD, 0xF0, 0x37,
            0xD0, 0xFB, 0xA9,
            0x10, 0x8D, 0x0A,
            0x22, 0x68, 0x28,
            0x60,
        }),
        .w16 => put(d, cur, &.{
            0x08, 0x48, // PHP / PHA (16-bit)
            0xE2, 0x20, 0x9C, 0x0A, 0x22, // 8-bit: mask
            0xC2, 0x20, 0x68, 0x48, // 16-bit: recover the value, keep it saved
            0x8D, 0xF3, 0x37, // 16-bit value -> $37F3/4
            0xE2, 0x20, 0xA9,
            lo,   0x8D, 0xF1,
            0x37, 0xA9, hi,
            0x8D, 0xF2, 0x37,
            0xA9, 0x03, 0x8D,
            0xF0, 0x37, 0xAD,
            0xF0, 0x37, 0xD0,
            0xFB, 0xA9, 0x10,
            0x8D, 0x0A, 0x22,
            0xC2, 0x20, 0x68,
            0x28, 0x60,
        }),
        .stz16 => put(d, cur, &.{
            0x08, 0x48,
            0xE2, 0x20,
            0x9C, 0x0A,
            0x22,
            0x9C, 0xF3, 0x37, 0x9C, 0xF4, 0x37, // value = 0 (both halves)
            0xA9, lo,   0x8D, 0xF1, 0x37, 0xA9,
            hi,   0x8D, 0xF2, 0x37, 0xA9, 0x03,
            0x8D, 0xF0, 0x37, 0xAD, 0xF0, 0x37,
            0xD0, 0xFB, 0xA9, 0x10, 0x8D, 0x0A,
            0x22, 0xC2, 0x20, 0x68, 0x28, 0x60,
        }),
        .r8 => put(d, cur, &.{
            0x9C, 0x0A, 0x22, // mask; flags still the caller's
            0xA9, lo,   0x8D,
            0xF1, 0x37, 0xA9,
            hi,   0x8D, 0xF2,
            0x37, 0xA9, 0x02,
            0x8D, 0xF0, 0x37,
            0xAD, 0xF0, 0x37, 0x10, 0xFB, // BPL: wait for the $FE served marker
            0xAD, 0xF3, 0x37, // result — N/Z now match the original LDA
            0x9C, 0xF0, 0x37, // release the mailbox (no flags)
            0x08, 0x48, // save result N/Z and value across the unmask
            0xA9, 0x10,
            0x8D, 0x0A,
            0x22, 0x68,
            0x28, 0x60,
        }),
        .r16 => put(d, cur, &.{
            0xE2, 0x20, 0x9C, 0x0A, 0x22, // 8-bit: mask
            0xA9, lo,   0x8D, 0xF1, 0x37,
            0xA9, hi,   0x8D, 0xF2, 0x37,
            0xA9, 0x04, 0x8D, 0xF0, 0x37,
            0xAD, 0xF0, 0x37, 0x10, 0xFB,
            0xC2, 0x20, // 16-bit again (the entry width)
            0xAD, 0xF3, 0x37, // 16-bit result
            0x9C, 0xF0, 0x37, // 16-bit release (also zeroes $37F1)
            0x08, 0x48, 0xE2,
            0x20, 0xA9, 0x10,
            0x8D, 0x0A, 0x22,
            0xC2, 0x20, 0x68,
            0x28, 0x60,
        }),
    }
}

// --- tests ---------------------------------------------------------------------

const testing = std.testing;

/// A minimal LoROM image: header, reset vector at $8000, filler that is not
/// mistakable for padding, and a real padding run for the shim.
fn makeRom(gpa: std.mem.Allocator) ![]u8 {
    const rom = try gpa.alloc(u8, 64 * 1024);
    for (rom, 0..) |*b, i| b.* = @truncate(0x11 + i *% 7);
    const h = rom[0x7FC0..][0..64];
    @memcpy(h[0..21], "SA1 SHELL TEST       ");
    h[0x15] = 0x20;
    h[0x16] = 0x00;
    h[0x17] = 8;
    h[0x18] = 0; // no SRAM (a cart with SRAM refuses)
    std.mem.writeInt(u16, h[0x1C..0x1E], 0xFFFF, .little);
    std.mem.writeInt(u16, h[0x1E..0x20], 0x0000, .little);
    @memset(h[0x20..0x40], 0);
    std.mem.writeInt(u16, h[0x3C..0x3E], 0x8000, .little);
    @memset(rom[0x7E00..0x7FC0], 0xFF); // shim + offload free space
    return rom;
}

test "shell: header, shim, park, and vector all land; refusals name reasons" {
    const gpa = testing.allocator;
    const rom = try makeRom(gpa);
    defer gpa.free(rom);

    var ref: ?Refusal = null;
    const empty: profile.Plan = .{};
    const res = try convert(gpa, rom, &empty, null, &.{}, &.{}, &ref);
    defer gpa.free(res.image);

    const h = try header_mod.detect(res.image);
    try testing.expectEqual(@as(u8, 0x35), h.chipset);
    try testing.expectEqual(cartridge.ChipKind.sa1, cartridge.identifyChip(h));
    try testing.expectEqual(res.stats.shim_addr, h.reset_vector);
    try testing.expectEqual(@as(u16, 0xFFFF), h.checksum ^ h.checksum_complement);
    // The shim: SEI first, park stub is SEI/STP at the declared address.
    const shim_file = @as(u32, res.stats.shim_addr) - 0x8000;
    try testing.expectEqual(@as(u8, 0x78), res.image[shim_file]);
    const park_file = @as(u32, res.stats.park_addr) - 0x8000;
    try testing.expectEqualSlices(u8, &.{ 0x78, 0xDB }, res.image[park_file..][0..2]);
    try testing.expect(!res.stats.d_moved);

    // Refusals: SRAM carts and non-LoROM.
    rom[0x7FC0 + 0x18] = 3;
    try testing.expectError(error.Refused, convert(gpa, rom, &empty, null, &.{}, &.{}, &ref));
    try testing.expectEqual(Reason.has_sram, ref.?.reason);
}

/// Build a one-region plan by hand for rewriter tests.
fn onePlan(start: u32, len: u32, dest: profile.PlanDest, dest_off: u32, dp: bool) profile.Plan {
    var p: profile.Plan = .{};
    p.viable = true;
    p.has_dp = dp;
    p.n = 1;
    p.regions[0] = .{
        .start = start,
        .len = len,
        .exact = true,
        .heat = 1,
        .dest = dest,
        .dest_off = dest_off,
        .dp = dp,
        .shared_outside = false,
        .dma_fed = false,
    };
    return p;
}

/// Mark one instruction executed (8-bit widths) in a synthetic usage map.
fn markOp(usage: []u8, cpu_addr: u32) void {
    usage[cpu_addr] |= usage_map.flag_opcode | usage_map.flag_exec |
        usage_map.flag_m | usage_map.flag_x;
}

test "rewriter: long and low-abs sites move; indexed sites block their region" {
    const gpa = testing.allocator;
    const rom = try makeRom(gpa);
    defer gpa.free(rom);
    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);

    // $00:8100: LDA $7E1F20 (long) -> region.
    @memcpy(rom[0x0100..0x0104], &[_]u8{ 0xAF, 0x20, 0x1F, 0x7E });
    markOp(usage, 0x00_8100);
    // $00:8104: STA $1F22 (abs, low mirror) -> region.
    @memcpy(rom[0x0104..0x0107], &[_]u8{ 0x8D, 0x22, 0x1F });
    markOp(usage, 0x00_8104);
    // $00:8107: LDA $0FFF (abs) -> outside every region: untouched.
    @memcpy(rom[0x0107..0x010A], &[_]u8{ 0xAD, 0xFF, 0x0F });
    markOp(usage, 0x00_8107);

    // Clean move to I-RAM offset $80.
    var plan = onePlan(0x1F00, 0x40, .iram, 0x80, false);
    var ref: ?Refusal = null;
    const res = try convert(gpa, rom, &plan, usage, &.{}, &.{}, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(RegionFate.clean, res.fate[0]);
    try testing.expectEqual(@as(u32, 1), res.stats.rewritten_long);
    try testing.expectEqual(@as(u32, 1), res.stats.rewritten_abs);
    // long $7E:1F20 -> $00:3000+$80+$20 = $00:30A0.
    try testing.expectEqualSlices(u8, &.{ 0xAF, 0xA0, 0x30, 0x00 }, res.image[0x0100..0x0104]);
    // abs $1F22 -> $30A2.
    try testing.expectEqualSlices(u8, &.{ 0x8D, 0xA2, 0x30 }, res.image[0x0104..0x0107]);
    // The out-of-region site is untouched.
    try testing.expectEqualSlices(u8, &.{ 0xAD, 0xFF, 0x0F }, res.image[0x0107..0x010A]);

    // Now add an indexed site into the region: the region blocks, nothing
    // is rewritten, and the shell still converts.
    @memcpy(rom[0x010A..0x010D], &[_]u8{ 0xBD, 0x10, 0x1F }); // LDA $1F10,X
    markOp(usage, 0x00_810A);
    const res2 = try convert(gpa, rom, &plan, usage, &.{}, &.{}, &ref);
    defer gpa.free(res2.image);
    try testing.expectEqual(RegionFate.blocked_indexed, res2.fate[0]);
    try testing.expectEqual(@as(u32, 0), res2.stats.rewritten_long);
    try testing.expectEqualSlices(u8, &.{ 0xAF, 0x20, 0x1F, 0x7E }, res2.image[0x0100..0x0104]);
    try testing.expectEqual(@as(u8, 1), res2.stats.regions_blocked);
}

test "rewriter: the dp window moves as a unit with D=$3000, or not at all" {
    const gpa = testing.allocator;
    const rom = try makeRom(gpa);
    defer gpa.free(rom);
    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);

    // $00:8100: LDA $40 (dp) and $00:8102: STA $7E0041 (long into the window).
    @memcpy(rom[0x0100..0x0102], &[_]u8{ 0xA5, 0x40 });
    markOp(usage, 0x00_8100);
    @memcpy(rom[0x0102..0x0106], &[_]u8{ 0x8F, 0x41, 0x00, 0x7E });
    markOp(usage, 0x00_8102);

    var plan = onePlan(0x40, 0x10, .iram, 0x40, true);
    var ref: ?Refusal = null;
    const res = try convert(gpa, rom, &plan, usage, &.{}, &.{}, &ref);
    defer gpa.free(res.image);
    try testing.expect(res.stats.d_moved);
    try testing.expectEqual(@as(u32, 1), res.stats.dp_sites);
    // The long site into the pinned window rewrites to $00:3041.
    try testing.expectEqualSlices(u8, &.{ 0x8F, 0x41, 0x30, 0x00 }, res.image[0x0102..0x0106]);
    // The shim carries the PEA $3000 / PLD prologue.
    const shim_file = @as(u32, res.stats.shim_addr) - 0x8000;
    try testing.expectEqualSlices(u8, &.{ 0x78, 0xF4, 0x00, 0x30, 0x2B }, res.image[shim_file..][0..5]);

    // A dp,X site into the window blocks the whole window: D stays 0.
    @memcpy(rom[0x0106..0x0108], &[_]u8{ 0xB5, 0x40 }); // LDA $40,X
    markOp(usage, 0x00_8106);
    const res2 = try convert(gpa, rom, &plan, usage, &.{}, &.{}, &ref);
    defer gpa.free(res2.image);
    try testing.expect(!res2.stats.d_moved);
    try testing.expectEqual(RegionFate.blocked_indexed, res2.fate[0]);
    try testing.expectEqualSlices(u8, &.{ 0x8F, 0x41, 0x00, 0x7E }, res2.image[0x0102..0x0106]);
}

test "rewriter: an abs site whose region went to BW-RAM blocks it" {
    const gpa = testing.allocator;
    const rom = try makeRom(gpa);
    defer gpa.free(rom);
    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);

    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0xAD, 0x20, 0x1F }); // LDA $1F20 abs
    markOp(usage, 0x00_8100);
    // The same region reached by long, which alone would be fine in BW-RAM.
    @memcpy(rom[0x0103..0x0107], &[_]u8{ 0xAF, 0x21, 0x1F, 0x7E });
    markOp(usage, 0x00_8103);

    var plan = onePlan(0x1F00, 0x40, .bwram, 0x200, false);
    var ref: ?Refusal = null;
    const res = try convert(gpa, rom, &plan, usage, &.{}, &.{}, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(RegionFate.blocked_abs_to_bwram, res.fate[0]);
    try testing.expectEqual(@as(u32, 0), res.stats.rewritten_long);

    // Long-only access to a BW-RAM region rewrites to $40:xxxx.
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0xEA, 0xEA, 0xEA }); // drop the abs site
    markOp(usage, 0x00_8100);
    const res2 = try convert(gpa, rom, &plan, usage, &.{}, &.{}, &ref);
    defer gpa.free(res2.image);
    try testing.expectEqual(RegionFate.clean, res2.fate[0]);
    try testing.expectEqualSlices(u8, &.{ 0xAF, 0x21, 0x02, 0x40 }, res2.image[0x0103..0x0107]);
}

test "semantic: a converted cart boots, parks the SA-1, and relocated state lands in I-RAM" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeRom(gpa);
    defer gpa.free(rom);
    // Reset code: LDA #$AB / STA $7E1F00 (long) / spin.
    @memcpy(rom[0x0000..0x0008], &[_]u8{ 0xA9, 0xAB, 0x8F, 0x00, 0x1F, 0x7E, 0x80, 0xFE });

    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);
    markOp(usage, 0x00_8000);
    markOp(usage, 0x00_8002);
    markOp(usage, 0x00_8006);

    // The original writes WRAM.
    {
        const cart = try cartridge.Cartridge.load(gpa, rom);
        const con = try gpa.create(console.FastConsole);
        defer {
            con.cart.deinit(gpa);
            gpa.destroy(con);
        }
        con.init(cart);
        con.runFrame();
        try testing.expectEqual(@as(u8, 0xAB), con.bus.wram.data[0x1F00]);
    }

    // The conversion relocates $7E:1F00 to I-RAM offset $40.
    var plan = onePlan(0x1F00, 0x10, .iram, 0x40, false);
    var ref: ?Refusal = null;
    const res = try convert(gpa, rom, &plan, usage, &.{}, &.{}, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(RegionFate.clean, res.fate[0]);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    try testing.expectEqual(cartridge.ChipKind.sa1, cart.chip);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    con.runFrame();
    // The value went to I-RAM through the S-CPU window; WRAM stayed clean.
    try testing.expectEqual(@as(u8, 0xAB), con.bus.sa1.iram[0x40]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x1F00]);
}

test "S3b: an offloaded leaf routine runs on the SA-1 and its results marshal back" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeRom(gpa);
    defer gpa.free(rom);
    // Reset at $8000: LDA #$05 / JSR $8020 / STA $7E0100 (long, unmoved) / spin.
    @memcpy(rom[0x0000..0x000B], &[_]u8{
        0xA9, 0x05, // LDA #$05
        0x20, 0x20, 0x80, // JSR $8020
        0x8F, 0x00, 0x01, 0x7E, // STA $7E0100
        0x80, 0xFE, // BRA *
    });
    // Leaf at $8020: LDA $7E1F00 (long -> moved) / INC A / STA $7E1F00 / RTS.
    @memcpy(rom[0x0020..0x002A], &[_]u8{
        0xAF, 0x00, 0x1F, 0x7E,
        0x1A, 0x8F, 0x00, 0x1F,
        0x7E, 0x60,
    });

    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);
    markOp(usage, 0x00_8000);
    markOp(usage, 0x00_8002);
    markOp(usage, 0x00_8005);
    markOp(usage, 0x00_8009);
    markOp(usage, 0x00_8020);
    markOp(usage, 0x00_8024);
    markOp(usage, 0x00_8025);
    markOp(usage, 0x00_8029);

    var plan = onePlan(0x1F00, 0x10, .iram, 0x40, false);
    var ref: ?Refusal = null;
    const res = try convert(gpa, rom, &plan, usage, &.{.{ .entry = 0x00_8020 }}, &.{}, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u24, 0x8020), res.stats.offloaded);
    try testing.expectEqual(@as(u32, 1), res.stats.offload_sites);

    // Boot it. The S-CPU calls the stub, the SA-1 runs the leaf, and the
    // incremented value comes back through the mailbox.
    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    con.runFrame();
    // The leaf's state lives in I-RAM, written BY THE SA-1; the S-CPU wrote
    // the marshalled return value to unmoved WRAM.
    try testing.expectEqual(@as(u8, 1), con.bus.sa1.iram[0x40]);
    try testing.expectEqual(@as(u8, 1), con.bus.wram.data[0x100]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x1F00]);

    // And the original, for the record: same visible results, no SA-1.
    const cart0 = try cartridge.Cartridge.load(gpa, rom);
    const con0 = try gpa.create(console.FastConsole);
    defer {
        con0.cart.deinit(gpa);
        gpa.destroy(con0);
    }
    con0.init(cart0);
    con0.runFrame();
    try testing.expectEqual(@as(u8, 1), con0.bus.wram.data[0x1F00]);
    try testing.expectEqual(@as(u8, 1), con0.bus.wram.data[0x100]);
}

test "S3b: two routines offload to distinct message ids and both round-trip" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeRom(gpa);
    defer gpa.free(rom);
    // Reset: LDA #$05 / JSR $8020 / JSR $8030 / STA $7E0100 / spin.
    @memcpy(rom[0x0000..0x000E], &[_]u8{
        0xA9, 0x05,
        0x20, 0x20,
        0x80, 0x20,
        0x30, 0x80,
        0x8F, 0x00,
        0x01, 0x7E,
        0x80, 0xFE,
    });
    // Leaf 1 at $8020: INC the moved byte at $7E:1F00 (via rewritten long).
    @memcpy(rom[0x0020..0x002A], &[_]u8{ 0xAF, 0x00, 0x1F, 0x7E, 0x1A, 0x8F, 0x00, 0x1F, 0x7E, 0x60 });
    // Leaf 2 at $8030: ASL the moved byte at $7E:1F08.
    @memcpy(rom[0x0030..0x003B], &[_]u8{ 0xAF, 0x08, 0x1F, 0x7E, 0x1A, 0x1A, 0x8F, 0x08, 0x1F, 0x7E, 0x60 });

    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);
    for ([_]u32{ 0x00_8000, 0x00_8002, 0x00_8005, 0x00_8008, 0x00_800C }) |a| markOp(usage, a);
    for ([_]u32{ 0x00_8020, 0x00_8024, 0x00_8025, 0x00_8029 }) |a| markOp(usage, a);
    for ([_]u32{ 0x00_8030, 0x00_8034, 0x00_8035, 0x00_8036, 0x00_803A }) |a| markOp(usage, a);

    var plan = onePlan(0x1F00, 0x10, .iram, 0x40, false);
    var ref: ?Refusal = null;
    const res = try convert(gpa, rom, &plan, usage, &.{ .{ .entry = 0x00_8020 }, .{ .entry = 0x00_8030 } }, &.{}, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u8, 2), res.stats.offload_count);
    try testing.expectEqual(@as(u32, 2), res.stats.offload_sites);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    con.runFrame();
    // Both leaves ran on the SA-1: leaf 1 incremented $1F00 (0 -> 1), leaf 2
    // shifted $1F08 twice after INC (A came in as leaf 1's result 1 -> INC 2
    // -> ASL 4? No: leaf 2 loads $1F08 (0), INC 1, ASL 2, stores 2). The
    // marshalled A after leaf 2 (2) lands in unmoved WRAM.
    try testing.expectEqual(@as(u8, 1), con.bus.sa1.iram[0x40]);
    try testing.expectEqual(@as(u8, 2), con.bus.sa1.iram[0x48]);
    try testing.expectEqual(@as(u8, 2), con.bus.wram.data[0x100]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x1F00]);
}

test "S3b pointer offload: a JSL/RTL pointer routine runs on the SA-1 against the shadow" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeRom(gpa);
    defer gpa.free(rom);
    @memset(rom[0xE000..0x10000], 0xFF); // bank $01 tail: pointer-stub carve space

    // Caller at $8000: [$00] -> ROM data at $00:9000, ($03) -> $1F00 (the
    // DB idiom in the routine picks the bank), JSL the routine, publish a
    // copied byte to unmoved WRAM, spin.
    @memcpy(rom[0x0000..0x0024], &[_]u8{
        0x18, 0xFB, // CLC / XCE
        0xE2, 0x30, // SEP #$30
        0x64, 0x00, // STZ $00
        0xA9, 0x90, 0x85, 0x01, // src = $00:9000
        0x64, 0x02, // src bank $00
        0x64, 0x03, // dst = $1F00
        0xA9, 0x1F,
        0x85, 0x04,
        0xA9, 0x7E, 0x85, 0x05, // dst bank byte (realistic clutter; (dp),y ignores it)
        0x22, 0x40, 0x80, 0x00, // JSL $00:8040
        0xAF, 0x02, 0x1F, 0x7E, // LDA $7E:1F02
        0x8F, 0x00, 0x01, 0x7E, // STA $7E:0100 (marker)
        0x80, 0xFE, // BRA *
    });
    // The routine at $8040 — the Gradius-decompressor shape in miniature:
    // JSL/RTL, the LDA #$7E/PHA/PLB idiom, a long-indirect read through a
    // dp pointer ([$00],y — bank slot at $02), and a DB-relative indirect
    // write (($03),y). Copies 4 bytes of ROM into WRAM via pointers.
    @memcpy(rom[0x0040..0x0052], &[_]u8{
        0x8B, // PHB
        0xA9, 0x7E, 0x48, 0xAB, // LDA #$7E / PHA / PLB (-> shadow bank)
        0xA0, 0x00, // LDY #$00
        0xB7, 0x00, // loop: LDA [$00],y
        0x91, 0x03, // STA ($03),y
        0xC8, // INY
        0xC0, 0x04, // CPY #$04
        0xD0, 0xF7, // BNE loop
        0xAB, // PLB
        0x6B, // RTL
    });
    @memcpy(rom[0x1000..0x1004], &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF }); // $00:9000

    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8006, 0x8008, 0x800A, 0x800C, 0x800E, 0x8010, 0x8012, 0x8014, 0x8016, 0x801A, 0x801E, 0x8022 }) |a| markOp(usage, a);
    for ([_]u32{ 0x8040, 0x8041, 0x8043, 0x8044, 0x8045, 0x8047, 0x8049, 0x804B, 0x804C, 0x804E, 0x8050, 0x8051 }) |a| markOp(usage, a);

    // A viable plan with a vacuous region (nothing references it), and the
    // routine's profiled pages: page 0 (dp cells and pointers) + page $1F
    // (the destination buffer).
    var plan = onePlan(0x0F00, 0x10, .iram, 0x80, false);
    var pages: profile.WramPages = @splat(0);
    pages[0] |= 1 << 0;
    pages[0] |= 1 << 0x1F;
    var ref: ?Refusal = null;
    const res = try convert(gpa, rom, &plan, usage, &.{.{ .entry = 0x00_8040, .pages = pages }}, &.{}, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u8, 1), res.stats.pointer_offloads);
    try testing.expectEqual(@as(u8, 1), res.stats.offload_count);
    try testing.expectEqual(@as(u32, 1), res.stats.offload_sites);
    // The shadow needs the full 128 KiB of BW-RAM declared.
    try testing.expectEqual(@as(u8, 0x07), res.image[0x7FC0 + 0x18]);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    con.runFrame();
    // The pointer walk copied ROM through the shadow and the marshal
    // brought it home: the caller sees its data in WRAM as always.
    try testing.expectEqualSlices(u8, &.{ 0xDE, 0xAD, 0xBE, 0xEF }, con.bus.wram.data[0x1F00..0x1F04]);
    try testing.expectEqual(@as(u8, 0xBE), con.bus.wram.data[0x0100]);
    // And the SA-1 really did the work, visible two ways: the shadow
    // (BW-RAM linear $11F00, bank $41's identity image of $7E:1F00)
    // carries the same bytes — no S-CPU game code path writes there —
    // and the mailbox holds the routine's marshalled exit state (A = the
    // last copied byte, Y = the loop's exit count), which only the SA-1
    // dispatcher writes after running the routine.
    try testing.expectEqualSlices(u8, &.{ 0xDE, 0xAD, 0xBE, 0xEF }, con.bus.sa1.bwram[0x11F00..0x11F04]);
    try testing.expectEqual(@as(u8, 0xEF), con.bus.sa1.iram[0x780]);
    try testing.expectEqual(@as(u8, 0x04), con.bus.sa1.iram[0x784]);
}

test "S3b eligibility: calls, unseen code, indexed data, and unmoved WRAM all refuse" {
    const gpa = testing.allocator;
    const rom = try makeRom(gpa);
    defer gpa.free(rom);
    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);
    var plan = onePlan(0x1F00, 0x10, .iram, 0x40, false);
    var res: Result = .{ .image = rom, .stats = .{}, .fate = @splat(.clean) };

    // A JSR inside the span: not a leaf.
    @memcpy(rom[0x0020..0x0024], &[_]u8{ 0x20, 0x00, 0x90, 0x60 });
    markOp(usage, 0x00_8020);
    markOp(usage, 0x00_8023);
    try testing.expect(!eligibleLeaf(rom, usage, &plan, &res, 0x8020));

    // Unmoved WRAM via long: the SA-1 cannot see it.
    @memcpy(rom[0x0020..0x0025], &[_]u8{ 0xAF, 0x00, 0x50, 0x7E, 0x60 });
    markOp(usage, 0x00_8024);
    try testing.expect(!eligibleLeaf(rom, usage, &plan, &res, 0x8020));

    // Indexed data: refused.
    @memcpy(rom[0x0020..0x0024], &[_]u8{ 0xBD, 0x00, 0x30, 0x60 });
    try testing.expect(!eligibleLeaf(rom, usage, &plan, &res, 0x8020));

    // A clean I-RAM-window access is eligible.
    @memcpy(rom[0x0020..0x0024], &[_]u8{ 0xAD, 0x40, 0x30, 0x60 });
    try testing.expect(eligibleLeaf(rom, usage, &plan, &res, 0x8020));

    // Uncovered code (no opcode flag): refused.
    try testing.expect(!eligibleLeaf(rom, usage, &plan, &res, 0x8040));
}

/// A LoROM for whole-game tests: header, room for real code at the front of
/// the bank, and a wide padding run so the carve (helpers + four stubs +
/// the service loop) always fits.
fn makeWgRom(gpa: std.mem.Allocator) ![]u8 {
    const rom = try gpa.alloc(u8, 64 * 1024);
    for (rom, 0..) |*b, i| b.* = @truncate(0x11 + i *% 7);
    const h = rom[0x7FC0..][0..64];
    @memcpy(h[0..21], "WG MIGRATION TEST    ");
    h[0x15] = 0x20;
    h[0x16] = 0x00;
    h[0x17] = 8;
    h[0x18] = 0;
    std.mem.writeInt(u16, h[0x1C..0x1E], 0xFFFF, .little);
    std.mem.writeInt(u16, h[0x1E..0x20], 0x0000, .little);
    @memset(h[0x20..0x40], 0);
    std.mem.writeInt(u16, h[0x3C..0x3E], 0x8000, .little);
    @memset(rom[0x1000..0x7FC0], 0xFF); // carve space
    return rom;
}

test "whole-game: the migrated game runs on the SA-1, MMIO crosses the mailbox, NMI round-trips" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    // The game: native mode, 8-bit; prove w8 by writing $77 into real WRAM
    // through the port ($2180 with WMADD=$001234), keep a marker in low
    // WRAM (I-RAM once migrated), prove r8 by reading the byte back through
    // the port and writing the round-trip to WRAM $2000, then enable NMI
    // and spin. The NMI handler counts frames in low WRAM and publishes the
    // count to WRAM $2100 through the port — MMIO from interrupt context,
    // which is exactly what the helpers' mask protocol exists for.
    @memcpy(rom[0x0000..0x004C], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, // CLC / XCE / SEP #$30
        0xA9, 0x34, 0x8D, 0x81, 0x21, // WMADD = $001234
        0xA9, 0x12, 0x8D, 0x82, 0x21,
        0xA9, 0x00, 0x8D, 0x83, 0x21,
        0xA9, 0x77, 0x8D, 0x80, 0x21, // WRAM[$1234] = $77
        0x8D, 0x10, 0x00, // marker in low WRAM
        0xA9, 0x34, 0x8D, 0x81, 0x21, // rewind WMADD
        0xA9, 0x12, 0x8D, 0x82, 0x21,
        0xA9, 0x00, 0x8D, 0x83, 0x21,
        0xAD, 0x80, 0x21, // read the byte back (r8)
        0x8D, 0x11, 0x00,
        0xA9, 0x00, 0x8D, 0x81, 0x21, // WMADD = $002000
        0xA9, 0x20, 0x8D, 0x82, 0x21,
        0xA9, 0x00, 0x8D, 0x83, 0x21,
        0xAD, 0x11, 0x00, 0x8D, 0x80, 0x21, // publish the round-trip
        0xA9, 0x80, 0x8D, 0x00, 0x42, // NMITIMEN: NMI on
        0x80, 0xFE, // spin
    });
    // NMI handler at $8050.
    @memcpy(rom[0x0050..0x006B], &[_]u8{
        0x48, // PHA
        0xEE, 0x20, 0x00, // INC the frame counter (low WRAM)
        0xA9, 0x00, 0x8D, 0x81, 0x21, // WMADD = $002100
        0xA9, 0x21, 0x8D, 0x82, 0x21,
        0xA9, 0x00, 0x8D, 0x83, 0x21,
        0xAD, 0x20, 0x00, 0x8D, 0x80, 0x21, // publish the count
        0x68, 0x40, // PLA / RTI
    });
    std.mem.writeInt(u16, rom[0x7FC0 + 0x2A ..][0..2], 0x8050, .little);

    // Collect real coverage from the original — the S1 half of the loop —
    // and take the baseline observations from the same run.
    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    const map: usage_map.UsageMap = .{ .bytes = bytes };
    const frames = 10;
    {
        const cart = try cartridge.Cartridge.load(gpa, rom);
        const con = try gpa.create(console.ProfilingConsole);
        defer {
            con.cart.deinit(gpa);
            gpa.destroy(con);
        }
        con.init(cart);
        con.usage = &map;
        for (0..frames) |_| con.runFrame();
        try testing.expectEqual(@as(u8, 0x77), con.bus.wram.data[0x1234]);
        try testing.expectEqual(@as(u8, 0x77), con.bus.wram.data[0x2000]);
        try testing.expectEqual(@as(u8, 0x77), con.bus.wram.data[0x0010]);
        try testing.expect(con.bus.wram.data[0x2100] >= frames - 2);
    }

    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, bytes, &ref);
    defer gpa.free(res.image);
    try testing.expect(res.stats.offload_sites >= 14);

    // Boot the migrated cart: the game now runs on the SA-1.
    const cart = try cartridge.Cartridge.load(gpa, res.image);
    try testing.expectEqual(cartridge.ChipKind.sa1, cart.chip);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    for (0..frames) |_| con.runFrame();
    // The game's working state lives in I-RAM, written by the SA-1; the
    // S-CPU's WRAM low mirror never saw it.
    try testing.expectEqual(@as(u8, 0x77), con.bus.sa1.iram[0x10]);
    try testing.expectEqual(@as(u8, 0x77), con.bus.sa1.iram[0x11]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0010]);
    // The mailbox performed real MMIO on the real bus: the port writes
    // landed in real WRAM, and the r8 read round-tripped the value.
    try testing.expectEqual(@as(u8, 0x77), con.bus.wram.data[0x1234]);
    try testing.expectEqual(@as(u8, 0x77), con.bus.wram.data[0x2000]);
    // NMI crossed the wall every frame: S-CPU stub -> CCNT message -> CNV
    // shim -> the game's handler on the SA-1, whose own MMIO requests
    // published the count back into real WRAM.
    try testing.expect(con.bus.sa1.iram[0x20] >= frames - 2);
    try testing.expect(con.bus.wram.data[0x2100] >= frames - 2);
}

test "whole-game: refusals name their reasons" {
    const gpa = testing.allocator;
    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    var ref: ?Refusal = null;

    // WRAM touched beyond the identity window.
    @memset(usage, 0);
    usage[0x00_0900] = usage_map.flag_write;
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, &ref));
    try testing.expectEqual(Reason.wg_wram_beyond_iram, ref.?.reason);

    // The reserved mailbox tail, even inside the window.
    @memset(usage, 0);
    usage[0x7E_07F4] = usage_map.flag_read;
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, &ref));
    try testing.expectEqual(Reason.wg_wram_beyond_iram, ref.?.reason);

    // An executed IRQ handler.
    @memset(usage, 0);
    std.mem.writeInt(u16, rom[0x7FC0 + 0x2E ..][0..2], 0x8100, .little);
    markOp(usage, 0x00_8100);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, &ref));
    try testing.expectEqual(Reason.wg_uses_irq, ref.?.reason);
    std.mem.writeInt(u16, rom[0x7FC0 + 0x2E ..][0..2], 0, .little);

    // Native and emulation NMI handlers both ran and differ.
    @memset(usage, 0);
    std.mem.writeInt(u16, rom[0x7FC0 + 0x2A ..][0..2], 0x8050, .little);
    std.mem.writeInt(u16, rom[0x7FC0 + 0x3A ..][0..2], 0x8060, .little);
    @memcpy(rom[0x0050..0x0052], &[_]u8{ 0x68, 0x40 });
    @memcpy(rom[0x0060..0x0062], &[_]u8{ 0x68, 0x40 });
    markOp(usage, 0x00_8050);
    markOp(usage, 0x00_8060);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, &ref));
    try testing.expectEqual(Reason.wg_nmi_ambiguous, ref.?.reason);
    std.mem.writeInt(u16, rom[0x7FC0 + 0x2A ..][0..2], 0, .little);
    std.mem.writeInt(u16, rom[0x7FC0 + 0x3A ..][0..2], 0, .little);

    // An indexed MMIO store: not proxyable in place.
    @memset(usage, 0);
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0x9D, 0x00, 0x21 });
    markOp(usage, 0x00_8100);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, &ref));
    try testing.expectEqual(Reason.wg_mmio_shape, ref.?.reason);

    // A long MMIO store: no room for the in-place JSR either.
    @memset(usage, 0);
    @memcpy(rom[0x0100..0x0104], &[_]u8{ 0x8F, 0x00, 0x21, 0x00 });
    markOp(usage, 0x00_8100);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, &ref));
    try testing.expectEqual(Reason.wg_mmio_shape, ref.?.reason);

    // An MMIO site executing outside bank $00 (this 64K image's bank $01).
    @memset(usage, 0);
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0xEA, 0xEA, 0xEA });
    markOp(usage, 0x00_8100);
    @memcpy(rom[0xFF00..0xFF03], &[_]u8{ 0x8D, 0x00, 0x21 });
    markOp(usage, 0x01_FF00);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, &ref));
    try testing.expectEqual(Reason.wg_mmio_outside_bank0, ref.?.reason);
    @memset(usage, 0);

    // A block move.
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0x54, 0x00, 0x7E });
    markOp(usage, 0x00_8100);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, &ref));
    try testing.expectEqual(Reason.wg_unsupported_op, ref.?.reason);
}
