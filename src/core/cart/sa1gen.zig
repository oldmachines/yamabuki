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
    wg_wram_beyond_bwram,
    wg_dp_dynamic,
    wg_stack_dynamic,
    wg_blockmove_source,

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
            .wg_wram_beyond_bwram => "the WRAM working set does not fit the BW-RAM window either: bank $7E/$7F beyond 128 KiB, or a low-bank address at or above $2000",
            .wg_dp_dynamic => "the game loads the direct page from something other than an immediate; the BW-RAM window move needs every D provable at build time",
            .wg_stack_dynamic => "the game loads the stack pointer from something other than an immediate; the BW-RAM window move needs every S provable at build time",
            .wg_blockmove_source => "a block move reads bank $00, where WRAM and ROM share the map, and X is not provably a WRAM address here — re-banking a move that turns out to walk ROM would read BW-RAM garbage",
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
    /// Pointer offloads whose data is BW-RAM-RESIDENT: not marshalled at
    /// all, addressed in place by both CPUs.
    resident_offloads: u8 = 0,
    /// The ASYNCHRONOUS offload's entry (0 = none): its stub returns
    /// without waiting and completion is collected by the fence. At most
    /// one per conversion — the fence hard-codes its slot set.
    async_entry: u24 = 0,
    /// 24-bit address of the shared fence routine (JSL target), for the
    /// NMI prologue convert() emits.
    async_fence: u24 = 0,
    /// The SA-1 reset vector the shim programs (the dispatcher, or the
    /// park stub when nothing offloaded) — what a state-seeded run needs
    /// to re-boot the SA-1 without executing the shim.
    crv: u16 = 0,
    /// `--wg-static` only: unprovable shapes found in statically
    /// discovered (never-executed) code and left as-is for S4 verification
    /// to arbitrate — D/S establishes, block moves, RMW MMIO.
    static_skipped: u32 = 0,
    /// Where each offload's SA-1-side body copy landed (full 24-bit
    /// address), in message-id order; 0 for leaf offloads, which run the
    /// original body in place. Lets a diagnosis point the SA-1 execution
    /// trace (sa1_trace.zig) straight at the code that ran.
    offload_copy: [offload_max]u24 = @splat(0),
    /// Each copy's length in bytes, same order.
    offload_copy_len: [offload_max]u32 = @splat(0),
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
    /// The direct page observed on entry, and whether it ever varied. A
    /// varying dp means no single page is "the" direct page, so the
    /// residency test cannot exclude one and residency is refused.
    entry_d: u16 = 0,
    d_varies: bool = false,
    /// The auto-bisect's mode ladder: an ASYNCHRONOUS offload that fails
    /// verification retries synchronously before being dropped. Also set
    /// up front for every candidate when the behavioral tier is off —
    /// async reorders execution by design, so only that tier can ever
    /// accept it.
    no_async: bool = false,
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
    /// Every WRAM page a profiled DMA/HDMA arm reads or writes. Such a
    /// page can never become BW-RAM-resident: the transfer's A-bus side
    /// names a WRAM address, and re-sourcing DMA is not part of this
    /// slice. Empty is safe — it only costs residency, never correctness,
    /// because a page left non-resident is marshalled as before.
    dma_pages: profile.WramPages,
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

    const carve = patchgen.findFreeSpace(image[0..header.offset], shim_len_max + park_len + nmi_prologue_len) orelse
        return refuse(refusal, .{ .reason = .no_free_space, .detail = shim_len_max + park_len + nmi_prologue_len });

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

    // Async needs the NMI vectors: the fence prologue takes them over, so
    // the native target must be real code, and the emulation vector must
    // agree (or be unused) — the prologue can only forward to one handler.
    const nmi_native = std.mem.readInt(u16, image[header.offset + 0x2A ..][0..2], .little);
    const nmi_emu = std.mem.readInt(u16, image[header.offset + 0x3A ..][0..2], .little);
    const nmi_ok = nmi_native >= 0x8000 and
        (nmi_emu == nmi_native or nmi_emu < 0x8000 or nmi_emu == 0xFFFF);

    // --- S3b: execution offload, before the shim (it decides CRV) ---------
    var crv: u16 = 0x8000 + @as(u16, @intCast(carve)) + @as(u16, @intCast(shim_len_max));
    if (usage != null and plan.viable) tryOffload(out, plan, usage.?, candidates, neighbours, dma_pages, carve, nmi_ok, &res, &crv);
    // The pointer-offload shadow lives at BW-RAM linear $10000+ (bank
    // $41): the cart must carry the full 128 KiB.
    if (res.stats.pointer_offloads > 0 and out[header.offset + 0x18] < 0x07)
        out[header.offset + 0x18] = 0x07;

    // The async fence's NMI prologue: every frame boundary collects a
    // still-in-flight call before the game's own handler (whose DMA may
    // read what the routine computes) runs.
    if (res.stats.async_entry != 0) {
        const nmi_file = carve + shim_len_max + park_len;
        const f = res.stats.async_fence;
        const wn = out[nmi_file..];
        var m: usize = 0;
        put(wn, &m, &.{ 0x08, 0xC2, 0x30, 0x48, 0xDA, 0x5A, 0x8B }); // save
        put(wn, &m, &.{ 0x22, @truncate(f), @truncate(f >> 8), @truncate(f >> 16) });
        put(wn, &m, &.{ 0xAB, 0xC2, 0x30, 0x7A, 0xFA, 0x68, 0x28 }); // restore
        put(wn, &m, &.{ 0x4C, @truncate(nmi_native), @truncate(nmi_native >> 8) });
        std.debug.assert(m == nmi_prologue_len);
        const nmi_addr: u16 = 0x8000 + @as(u16, @intCast(nmi_file));
        std.mem.writeInt(u16, out[header.offset + 0x2A ..][0..2], nmi_addr, .little);
        std.mem.writeInt(u16, out[header.offset + 0x3A ..][0..2], nmi_addr, .little);
    }

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
    // Async busy flag ($378A) starts idle: I-RAM is uninitialised at boot,
    // and the NMI fence deadlocks on garbage that reads as an in-flight id
    // — awaiting a handshake for a call that never happened.
    if (res.stats.async_entry != 0) n = emitStore(w, n, 0x378A, 0x00);
    const park_addr: u16 = shim_addr + @as(u16, @intCast(shim_len_max));
    res.stats.crv = crv;
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
const shim_len_max: u32 = 40;
const park_len: u32 = 2;
/// The async offload's NMI prologue: save context, JSL the fence, restore,
/// JMP the game's own handler. Carved after the park stub.
const nmi_prologue_len: u32 = 21;

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

                // Indexed sites: the index carries the access anywhere
                // ABOVE the base — 255 bytes for an 8-bit index, the rest
                // of the bank for 16. Every region the reach touches is
                // compromised, not merely the one holding the base: the
                // site that sank the first live relocation ever verified
                // (`INC $10B9,X` on a real cart) had its base two pages
                // BELOW the region it scribbled into, so a base-only rule
                // rewrites the exact stores and leaves the indexed ones
                // splitting the structure between WRAM and the new home.
                if (md == .abs_x or md == .abs_y or md == .long_x or md == .dp_idx) {
                    if (pass == 0) {
                        const reach: u32 = if (x8) 255 else 0xFFFF;
                        for (plan.regions[0..plan.n], 0..) |rg, rgi| {
                            if (wram_off < rg.start + rg.len and wram_off + reach >= rg.start)
                                res.fate[rgi] = .blocked_indexed;
                        }
                    }
                    continue;
                }

                const region: u8 = for (plan.regions[0..plan.n], 0..) |r, ri| {
                    if (wram_off >= r.start and wram_off < r.start + r.len)
                        break @intCast(ri);
                } else continue;
                const r = &plan.regions[region];

                if (pass == 0) {
                    // Judgement pass: what would sink this region's move?
                    switch (md) {
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
const ptr_tree_cap = 8;
const ptr_wram_long_cap = 16;
/// Sum-of-spans budget for one tree's copies (overlapping members each
/// carry their own copy of any shared tail, so this bounds the carve).
const ptr_tree_span_max: u32 = 4096;
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
    if (total > ptr_pages_cap) return null;
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

fn tryOffload(
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

/// Does any executed instruction OUTSIDE [entry, entry+span) statically
/// name a byte of `pages` (excluding the direct page, which never becomes
/// resident)? Long and low-mirror-absolute operands are the forms that
/// name WRAM without depending on a runtime register, so they are exactly
/// the references that would break if the bytes moved to BW-RAM.
fn namedOutside(
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

/// Re-point member-to-member JSLs inside one member's COPY at the other
/// members' copies. The eligibility walk proved every JSL in the span
/// targets a tree member, so this scan is exhaustive by construction.
fn rebaseTreeJsls(
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
fn eligiblePointer(out: []const u8, usage: []const u8, entry: u16) ?PtrSpec {
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
const dbg_walk_root: u16 = 0;

fn walkMember(out: []const u8, usage: []const u8, spec: *PtrSpec, mi: usize, has_idp: *bool) bool {
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
fn jslSitesInsideTree(out: []const u8, usage: []const u8, spec: *const PtrSpec, entry: u16) bool {
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
fn ptrStubLen(spec: PtrSpec, runs: Runs) u32 {
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
fn emitPtrStub(d: []u8, id: u8, entry: u16, spec: PtrSpec, runs: Runs) u32 {
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
fn fenceLen(spec: PtrSpec) u32 {
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
fn emitFence(d: []u8, spec: PtrSpec) u32 {
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

/// Byte-exact length of an async stub (the emitter asserts).
fn asyncStubLen(spec: PtrSpec) u32 {
    return 122 + 27 * @as(u32, @intCast(spec.n_slots));
}

/// The fire-and-forget S-CPU stub for THE async offload: fence first (a
/// previous call may still be in flight — and the D-guard's bail path runs
/// the original body on the S-CPU, which must never race the SA-1 over the
/// resident data), then the synchronous stub's whole front half, then send
/// the message, mark busy, and return with the CALLER's registers — the
/// routine's register results are dropped, which is the async contract;
/// verification arbitrates whether any caller actually needed them.
fn emitAsyncStub(d: []u8, fence: u24, id: u8, entry: u16, spec: PtrSpec) u32 {
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

const WgSiteKind = enum { w8, w16, r8, r16, stz8, stz16, c8, c16, ry8, ry16, rx8, rx16, wx8, wx16, wy8, wy16 };
/// Which index register the site's addressing mode adds, if any. An indexed
/// site's helper computes base+index at run time — in the caller's own index
/// width, since TXA/TYA zero-extend exactly when the hardware would — and
/// files the *effective* register; the mailbox protocol never sees the
/// difference.
const WgIndex = enum { none, x, y };
const WgSite = struct { file: u32, kind: WgSiteKind, reg: u16, idx: WgIndex = .none };
const wg_sites_max = 768;
/// A helper is a pure function of (kind, reg, idx), so sites sharing all
/// three share one helper — Gradius III alone has hundreds of MMIO sites
/// but only a few dozen distinct shapes, and the carve is sized by the
/// latter.
const wg_uniq_max = 160;
/// Executed TCD/TCS sites the BW-RAM window move can adjust.
const wg_moves_max = 64;
/// Where the BW-RAM window sits on both buses ($6000-$7FFF of every system
/// bank). WRAM's low mirror $0000-$1FFF shifts here; $7E/$7F re-bank to
/// $40/$41 instead, reaching the same bytes linearly.
const wg_bw_window: u16 = 0x6000;

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
const WinSpec = struct {
    members: [ptr_tree_cap]struct { entry: u16, span: u32 } = undefined,
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
fn windowEligible(out: []const u8, usage: []const u8, entry: u16) ?WinSpec {
    var spec: WinSpec = .{};
    spec.members[0] = .{ .entry = entry, .span = 0 };
    spec.n_members = 1;
    var walked: usize = 0;
    while (walked < spec.n_members) : (walked += 1) {
        if (!winWalkMember(out, usage, &spec, walked)) return null;
    }
    spec.total_span = 0;
    for (spec.members[0..spec.n_members]) |m| spec.total_span += m.span;
    if (spec.total_span > ptr_tree_span_max) return null;
    return spec;
}

fn winWalkMember(out: []const u8, usage: []const u8, spec: *WinSpec, mi: usize) bool {
    const span_max: u32 = 1024;
    const entry: u32 = spec.members[mi].entry;
    var pc: u32 = entry;
    var limit: u32 = entry;
    // The data-bank pin, post-window flavor: the rewritten idiom loads
    // $40/$41 now. Under a BW-RAM pin every absolute is data both CPUs
    // read identically — including operands that happen to fall in the
    // MMIO decode range ($8EF1 stores $3E00 under a pinned $40).
    var db_pin: ?u8 = null;
    while (pc - entry < span_max) {
        if (pc > 0xFFFF) return false;
        if (usage[pc] & usage_map.flag_opcode == 0) {
            if (pc >= limit) return false;
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
                return true;
            },
            0x22 => {
                if (out[file + 3] != 0x00) return false;
                const tgt = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                if (tgt < 0x8000) return false;
                const dup = for (spec.members[0..spec.n_members]) |m| {
                    if (m.entry == tgt) break true;
                } else false;
                if (!dup) {
                    if (spec.n_members == ptr_tree_cap) return false;
                    spec.members[spec.n_members] = .{ .entry = tgt, .span = 0 };
                    spec.n_members += 1;
                }
            },
            // Wrong return shape, near calls, far jumps, interrupt ops,
            // and the ops that would swap the SA-1's stack from under it.
            0x60, 0x40, 0x20, 0xFC, 0x5C, 0x6C, 0x7C, 0xDC => return false,
            0x00, 0x02, 0xCB, 0xDB => return false,
            0x1B, 0x9A => return false, // TCS / TXS
            0x44, 0x54 => {
                // Block moves only between the BW-RAM banks, where both
                // CPUs see the same bytes.
                const d0 = out[file + 1];
                const s0 = out[file + 2];
                if (!((d0 == 0x40 or d0 == 0x41) and (s0 == 0x40 or s0 == 0x41 or s0 >= 0x80 or (s0 >= 0x02 and s0 <= 0x3F))))
                    return false;
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
            },
            else => {},
        }
        if (!dbrSurvives(out, usage, file, op)) db_pin = null;
        switch (usage_map.mode(op)) {
            .none, .dp, .dp_idx => {},
            .abs, .abs_x, .abs_y => {
                const v = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                // MMIO through a system bank is S-CPU-only hardware — but
                // under a pinned BW-RAM bank the same operand is data both
                // CPUs read identically.
                const pinned_bw = db_pin != null and (db_pin.? == 0x40 or db_pin.? == 0x41);
                if (!pinned_bw and v >= 0x2100 and v < 0x4380) return false;
            },
            .long, .long_x => {
                const b = out[file + 3];
                const v = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                if ((b & 0x7F) <= 0x3F and v >= 0x2100 and v < 0x4380) return false;
                // $7E/$7F would be real WRAM — the window rewrite
                // re-banked every covered site, so seeing one here means
                // the walk wandered into unrewritten territory.
                if (b == 0x7E or b == 0x7F) return false;
            },
        }
        pc += len;
    }
    return false;
}

/// Window sync stub: caller D ($3788), registers, caller P, and caller
/// DBR ($378B) into the mailbox; send; double handshake; exit registers
/// back out. No guard (every D is valid — the SA-1 runs the same D over
/// its own identity window), no shadow, no slots, no page copies.
const win_stub_len: u32 = 112;
fn emitWinStub(d: []u8, id: u8) u32 {
    var cur: usize = 0;
    // Caller D, with A saved around the grab.
    put(d, &cur, &.{ 0x08, 0xC2, 0x20, 0x48, 0x0B, 0x68, 0x8F, 0x88, 0x37, 0x00, 0x68, 0x28 });
    // Register marshal (the sync-ptr stub's, verbatim).
    put(d, &cur, &.{ 0x8B, 0x08, 0xE2, 0x20 });
    put(d, &cur, &.{ 0x8F, 0x80, 0x37, 0x00, 0xEB, 0x8F, 0x81, 0x37, 0x00, 0xEB });
    put(d, &cur, &.{ 0xC2, 0x30, 0x8A, 0x8F, 0x82, 0x37, 0x00, 0x98, 0x8F, 0x84, 0x37, 0x00 });
    put(d, &cur, &.{ 0xE2, 0x20, 0x68, 0x8F, 0x86, 0x37, 0x00 });
    // Caller DBR: the PHB byte, at the stack top now the PHP is pulled.
    put(d, &cur, &.{ 0xA3, 0x01, 0x8F, 0x8B, 0x37, 0x00 });
    // Send + double handshake.
    put(d, &cur, &.{ 0xA9, id, 0x8F, 0x00, 0x22, 0x00 });
    put(d, &cur, &.{ 0xAF, 0x00, 0x23, 0x00, 0x29, 0x0F, 0xC9, id, 0xD0, 0xF6 });
    put(d, &cur, &.{ 0xA9, 0x00, 0x8F, 0x00, 0x22, 0x00 });
    put(d, &cur, &.{ 0xAF, 0x00, 0x23, 0x00, 0x29, 0x0F, 0xD0, 0xF8 });
    // Exit registers from the mailbox; caller DBR back.
    put(d, &cur, &.{0xAB});
    put(d, &cur, &.{ 0xC2, 0x30, 0xAF, 0x82, 0x37, 0x00, 0xAA, 0xAF, 0x84, 0x37, 0x00, 0xA8 });
    put(d, &cur, &.{ 0xE2, 0x20, 0xAF, 0x86, 0x37, 0x00, 0x48 });
    put(d, &cur, &.{ 0xAF, 0x81, 0x37, 0x00, 0xEB, 0xAF, 0x80, 0x37, 0x00 });
    put(d, &cur, &.{ 0x28, 0x6B });
    return @intCast(cur);
}

/// Window async stub: fence first (drain any in-flight call), marshal
/// registers + D + DBR, send, mark busy, return AT ONCE with the
/// caller's own registers. Nothing to write back — the routine's effects
/// land in the shared BW-RAM both CPUs address.
const win_async_stub_len: u32 = 93;
fn emitWinAsyncStub(d: []u8, fence: u24, id: u8) u32 {
    var cur: usize = 0;
    put(d, &cur, &.{ 0x08, 0xC2, 0x30, 0x48, 0xDA, 0x5A, 0x8B }); // save caller
    put(d, &cur, &.{ 0x22, @truncate(fence), @truncate(fence >> 8), @truncate(fence >> 16) });
    put(d, &cur, &.{ 0xAB, 0xC2, 0x30, 0x7A, 0xFA, 0x68, 0x28 }); // restore (REP first)
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
    put(d, &cur, &.{ 0xAB, 0xC2, 0x30, 0x7A, 0xFA, 0x68, 0x28, 0x6B });
    return @intCast(cur);
}

/// One dispatcher block for a window offload: game D as-is, game DBR
/// from the mailbox, the shared unmarshal, the copy, dispatcher DBR back
/// (mar's absolute mailbox stores need a system bank), the shared
/// marshal, dispatcher D back, signal.
const win_block_len: u32 = 36;
fn emitWinBlock(d: []u8, cur: *usize, id: u8, copy_addr: u16, copy_bank: u8, unm_addr: u16, mar_addr: u16, sig_addr: u16, dp_base: u16) void {
    put(d, cur, &.{ 0xC9, id, 0xD0, 0x20 });
    put(d, cur, &.{0x8B}); // dispatcher DBR
    put(d, cur, &.{ 0xC2, 0x20, 0xAD, 0x88, 0x37, 0x5B }); // game D
    put(d, cur, &.{ 0xE2, 0x20, 0xAD, 0x8B, 0x37, 0x48, 0xAB }); // game DBR
    putJsr(d, cur, unm_addr);
    put(d, cur, &.{ 0x22, @truncate(copy_addr), @truncate(copy_addr >> 8), copy_bank });
    put(d, cur, &.{0xAB}); // dispatcher DBR back
    putJsr(d, cur, mar_addr);
    put(d, cur, &.{ 0xF4, @truncate(dp_base), @truncate(dp_base >> 8), 0x2B });
    put(d, cur, &.{ 0x4C, @truncate(sig_addr), @truncate(sig_addr >> 8) });
}

const wg_prologue_len = 21;
/// Window mode's shim: SEI + 3 stores + XCE/REP + D + S + SEP + JMP =
/// 1 + 15 + 4 + 4 + 4 + 2 + 3 = 33; +23 when offloads boot the SA-1
/// (SIWP, CRV lo/hi, async busy init, reset release).
const wg_window_shim_len = 33;
const wg_window_shim_max = 33 + 23;
/// Bank-0 reservation for the window dispatcher: prologue + message loop
/// + JMP + sig + unm + mar + blocks + NMI prologue.
const win_disp_max: u32 = 26 + 12 + 3 + 19 + 21 + 24 + offload_max * win_block_len + nmi_prologue_len;

const WinChosen = struct { entry: u16, spec: WinSpec, is_async: bool };

/// Choose and emit window offloads onto the REWRITTEN image. The
/// dispatcher (CRV is 16-bit) and the NMI prologue (a 16-bit vector)
/// live in the bank-0 carve after the shim; stubs, copies, and the fence
/// are long-addressed and carve from any bank's padding. Returns the CRV
/// for the shim to program, or null when nothing offloaded.
fn emitWindowOffloads(
    out: []u8,
    usage: []const u8,
    header_off: u32,
    candidates: []const Candidate,
    allow_async_in: bool,
    bank0_at: u32,
    res: *Result,
) ?u16 {
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
        const spec = windowEligible(out, usage, e) orelse continue;
        if (countCallSites(out, usage, e, 0x22) == 0) continue;
        chosen[n] = .{ .entry = e, .spec = spec, .is_async = allow_async and !c.no_async and n == 0 };
        n += 1;
    }
    if (n == 0) return null;

    // Any-bank sizes.
    var any_len: u32 = 0;
    var has_async = false;
    for (chosen[0..n]) |c| {
        any_len += c.spec.total_span;
        if (c.is_async) {
            has_async = true;
            any_len += fenceLen(.{}) + win_async_stub_len;
        } else any_len += win_stub_len;
    }
    const any_at = 0x8000 + (patchgen.findFreeSpace(out[0x8000 .. out.len - 1], any_len) orelse return null);
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
        }
        const stub_file = cur;
        const slen = if (c.is_async)
            emitWinAsyncStub(out[cur..], fence24, id)
        else
            emitWinStub(out[cur..], id);
        std.debug.assert(slen == if (c.is_async) win_async_stub_len else win_stub_len);
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
    // native mode, 16-bit X, stack under the mailbox, D.
    put(d, &dc, &.{ 0x78, 0xA9, 0xFF, 0x8D, 0x2A, 0x22, 0xA9, 0x80, 0x8D, 0x27, 0x22, 0x9C, 0x25, 0x22, 0x18, 0xFB, 0xC2, 0x10, 0xA2, 0x78, 0x37, 0x9A, 0xF4, @truncate(dp_base), @truncate(dp_base >> 8), 0x2B });
    std.debug.assert(dc == 26);
    const loop_addr: u16 = base16 + @as(u16, @intCast(dc));
    put(d, &dc, &.{ 0xE2, 0x20, 0xAD, 0x01, 0x23, 0x29, 0x0F, 0xF0, 0xF7, 0x8D, 0x87, 0x37 });
    const blocks_at = dc;
    dc += n * win_block_len; // blocks emitted below, once sig/unm/mar addresses exist
    put(d, &dc, &.{ 0x4C, @truncate(loop_addr), @truncate(loop_addr >> 8) });
    const sig_addr: u16 = base16 + @as(u16, @intCast(dc));
    put(d, &dc, &.{ 0xAD, 0x87, 0x37, 0x8D, 0x09, 0x22, 0xAD, 0x01, 0x23, 0x29, 0x0F, 0xD0, 0xF9, 0x9C, 0x09, 0x22, 0x4C, @truncate(loop_addr), @truncate(loop_addr >> 8) });
    const unm_addr: u16 = base16 + @as(u16, @intCast(dc));
    put(d, &dc, &.{ 0xAD, 0x86, 0x37, 0x48, 0xAD, 0x81, 0x37, 0xEB, 0xAD, 0x80, 0x37, 0xC2, 0x10, 0xAE, 0x82, 0x37, 0xAC, 0x84, 0x37, 0x28, 0x60 });
    const mar_addr: u16 = base16 + @as(u16, @intCast(dc));
    put(d, &dc, &.{ 0x08, 0xC2, 0x10, 0x8E, 0x82, 0x37, 0x8C, 0x84, 0x37, 0xE2, 0x20, 0x8D, 0x80, 0x37, 0xEB, 0x8D, 0x81, 0x37, 0xEB, 0x68, 0x8D, 0x86, 0x37, 0x60 });
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
        put(d, &nc, &.{ 0x22, @truncate(fence24), @truncate(fence24 >> 8), @truncate(fence24 >> 16) });
        put(d, &nc, &.{ 0xAB, 0xC2, 0x30, 0x7A, 0xFA, 0x68, 0x28 });
        put(d, &nc, &.{ 0x4C, @truncate(nmi_native), @truncate(nmi_native >> 8) });
        std.debug.assert(nc - nmi_at == nmi_prologue_len);
        const nmi_addr: u16 = base16 + @as(u16, @intCast(nmi_at));
        std.mem.writeInt(u16, out[header_off + 0x2A ..][0..2], nmi_addr, .little);
        std.mem.writeInt(u16, out[header_off + 0x3A ..][0..2], nmi_addr, .little);
    }

    res.stats.offload_count = @intCast(n);
    res.stats.offloaded = chosen[0].entry;
    res.stats.pointer_offloads = @intCast(n);
    res.stats.resident_offloads = @intCast(n); // by construction
    return base16;
}
/// Extra prologue the BW-RAM window needs: select block 0, unprotect, and
/// reproduce the power-on D and S inside the window (native mode first).
const wg_prologue_bw_extra = 20;
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

/// `--wg-static`: extend the S1 coverage map by recursive-descent
/// disassembly. Every dynamically covered opcode is a PROVEN instruction
/// start with proven M/X widths — the profiler recorded them — which
/// sidesteps the classic 65816 static-disassembly trap: immediates change
/// length with the width flags, so a cold disassembler cannot even take
/// instruction boundaries for granted. Seeded from every covered opcode
/// plus the reset vector, the walk decodes forward through code the
/// profiled run never reached, following static control flow (branches both
/// ways, JSR/JSL target and return, JMP/JML/BRA/BRL targets) and
/// propagating widths through SEP/REP. A path stops wherever the widths
/// stop being provable (PLP, XCE, RTI) or control goes somewhere static
/// analysis cannot follow — indirect jumps, whose targets are usually
/// covered seeds already, which is the point of seeding from coverage.
/// Bytes never reached stay data and are never rewritten.
fn extendCoverage(
    gpa: std.mem.Allocator,
    image: []const u8,
    header: header_mod.Header,
    usage: []const u8,
) ![]u8 {
    const ext = try gpa.dupe(u8, usage);
    errdefer gpa.free(ext);
    // File-offset-shaped visit marks; one decode per byte is enough because
    // dynamic flags are already trusted and a width conflict is grounds to
    // stop, not re-decode.
    const seen = try gpa.alloc(bool, image.len);
    defer gpa.free(seen);
    @memset(seen, false);

    const Item = struct { addr: u24, m8: bool, x8: bool };
    var stack: std.array_list.Managed(Item) = .init(gpa);
    defer stack.deinit();

    if (header.reset_vector >= 0x8000)
        try stack.append(.{ .addr = header.reset_vector, .m8 = true, .x8 = true });
    var sbank: u32 = 0;
    while (sbank < 0x40) : (sbank += 1) {
        if (sbank * 0x8000 >= image.len) break;
        var sa: u32 = 0x8000;
        while (sa < 0x10000) : (sa += 1) {
            const cpu = (sbank << 16) | sa;
            for ([2]u32{ cpu, 0x80_0000 | cpu }) |c| {
                const fl = usage[c];
                if (fl & usage_map.flag_opcode != 0) try stack.append(.{
                    .addr = @intCast(cpu),
                    .m8 = fl & usage_map.flag_m != 0,
                    .x8 = fl & usage_map.flag_x != 0,
                });
            }
        }
    }

    while (stack.pop()) |item| {
        var addr: u32 = item.addr;
        var m8 = item.m8;
        var x8 = item.x8;
        walk: while (true) {
            const wbank = addr >> 16;
            const a16 = addr & 0xFFFF;
            if (wbank >= 0x40 or a16 < 0x8000) break;
            const file = wbank * 0x8000 + (a16 - 0x8000);
            if (file >= image.len) break;
            if (seen[file]) break;
            seen[file] = true;
            const op = image[file];
            const len: u32 = usage_map.instrLen(op, m8, x8);
            if (a16 + len > 0x10000) break;
            if (ext[addr] & usage_map.flag_opcode == 0) {
                ext[addr] &= ~(usage_map.flag_m | usage_map.flag_x);
                ext[addr] |= usage_map.flag_opcode | usage_map.flag_exec |
                    (if (m8) usage_map.flag_m else @as(u8, 0)) |
                    (if (x8) usage_map.flag_x else @as(u8, 0));
                var i: u32 = 1;
                while (i < len) : (i += 1) ext[addr + i] |= usage_map.flag_exec;
            }
            switch (op) {
                // Path enders: returns, software interrupts, STP — and the
                // two instructions after which the widths are anyone's
                // guess.
                0x60, 0x6B, 0x40, 0x00, 0x02, 0xDB, 0x28, 0xFB => break,
                0xE2 => { // SEP #imm
                    const im = image[file + 1];
                    if (im & 0x20 != 0) m8 = true;
                    if (im & 0x10 != 0) x8 = true;
                },
                0xC2 => { // REP #imm
                    const im = image[file + 1];
                    if (im & 0x20 != 0) m8 = false;
                    if (im & 0x10 != 0) x8 = false;
                },
                0x4C => { // JMP abs: bank-confined
                    const t = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
                    try stack.append(.{ .addr = @intCast((wbank << 16) | t), .m8 = m8, .x8 = x8 });
                    break;
                },
                0x5C, 0x22 => { // JML long / JSL long
                    const t = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
                    const tb: u32 = image[file + 3] & 0x7F;
                    try stack.append(.{ .addr = @intCast((tb << 16) | t), .m8 = m8, .x8 = x8 });
                    if (op == 0x5C) break; // JSL falls through on return
                },
                0x20 => { // JSR abs: target plus fall-through
                    const t = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
                    try stack.append(.{ .addr = @intCast((wbank << 16) | t), .m8 = m8, .x8 = x8 });
                },
                0x80, 0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0 => {
                    const rel: i8 = @bitCast(image[file + 1]);
                    const t = (a16 +% 2 +% @as(u32, @bitCast(@as(i32, rel)))) & 0xFFFF;
                    try stack.append(.{ .addr = @intCast((wbank << 16) | t), .m8 = m8, .x8 = x8 });
                    if (op == 0x80) break; // BRA is unconditional
                },
                0x82 => { // BRL
                    const rel: i16 = @bitCast(std.mem.readInt(u16, image[file + 1 ..][0..2], .little));
                    const t = (a16 +% 3 +% @as(u32, @bitCast(@as(i32, rel)))) & 0xFFFF;
                    try stack.append(.{ .addr = @intCast((wbank << 16) | t), .m8 = m8, .x8 = x8 });
                    break;
                },
                // Indirect control transfers: statically opaque. (JSR
                // (abs,X) does fall through on return, so it continues.)
                0x6C, 0x7C, 0xDC => break,
                else => {},
            }
            addr += len;
            continue :walk;
        }
    }
    return ext;
}

/// Convert for whole-game migration. Needs only the coverage map — no plan:
/// state stays at its own addresses inside the identity window.
pub fn convertWholeGame(
    gpa: std.mem.Allocator,
    image: []const u8,
    usage: []const u8,
    /// `--wg-static`: also rewrite code the profiled run never executed,
    /// discovered by `extendCoverage`. Statically discovered code gets the
    /// window rewrites and (supported-shape) MMIO proxies but contributes
    /// no proofs and no refusals — unprovable shapes there are counted in
    /// `stats.static_skipped` and left for S4 verification to arbitrate,
    /// because refusing a conversion over code that may never run would
    /// bring back the old "no game qualifies" regime by another road.
    static_walk: bool,
    /// UNIFORM WINDOW MODE (v17's actual architecture): the game KEEPS
    /// RUNNING ON THE S-CPU and only its memory moves — WRAM's low 8 KiB
    /// into the S-CPU's own BW-RAM window ($6000-$7FFF, SBM block 0) and
    /// $7E/$7F long references to banks $40/$41, every relative distance
    /// preserved so indexed bases rewrite soundly (the per-region S2
    /// rewriter cannot say that; see the indexed-reach rule). MMIO stays
    /// native — no proxies, no NMI forwarding, no SA-1 execution at all
    /// (the chip never leaves reset; the cart is carried for its RAM).
    /// This is the enabler for resident offloads over the whole working
    /// set: once state lives in BW-RAM, both CPUs address it in place.
    window: bool,
    /// Window offload candidates (profile entries; empty = relocation
    /// only). Ignored outside window mode.
    win_candidates: []const Candidate,
    /// Allow the fire-and-forget flavor (gated on the behavioral tier by
    /// the caller, as in the S3 path).
    win_allow_async: bool,
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

    // The map both walks consume: dynamic coverage, statically extended
    // when asked. `usage` stays the authority on what actually ran — the
    // refusal policy keys on it.
    const cov: []const u8 = if (static_walk) try extendCoverage(gpa, image, header, usage) else usage;
    defer if (static_walk) gpa.free(@constCast(cov));
    // Executed flags are merged across the $80-$BF fast mirrors throughout:
    // the same ROM byte, the same file offset, possibly only ever executed
    // through the mirror.
    // IRQ vectors with executed targets = the game takes IRQs. Window mode
    // does not care: the S-CPU keeps its own vectors and handlers, and an
    // interrupt's stack traffic follows S into the window like any push.
    if (!window) for ([_]u32{ 0x2E, 0x3E }) |off| {
        const v: u32 = std.mem.readInt(u16, image[header.offset + off ..][0..2], .little);
        if (v >= 0x8000 and v != 0xFFFF and
            (usage[v] | usage[0x80_0000 | v]) & usage_map.flag_opcode != 0)
            return refuse(refusal, .{ .reason = .wg_uses_irq });
    };
    // The SA-1 serves CNV for both the native and the emulation NMI pull,
    // so only one game handler can survive the migration. Pick the one
    // that actually ran; if both ran and differ, refuse.
    const nmi_native = std.mem.readInt(u16, image[header.offset + 0x2A ..][0..2], .little);
    const nmi_emu = std.mem.readInt(u16, image[header.offset + 0x3A ..][0..2], .little);
    const nat_used = nmi_native >= 0x8000 and
        (usage[nmi_native] | usage[0x80_0000 | @as(u32, nmi_native)]) & usage_map.flag_opcode != 0;
    const emu_used = nmi_emu >= 0x8000 and
        (usage[nmi_emu] | usage[0x80_0000 | @as(u32, nmi_emu)]) & usage_map.flag_opcode != 0;
    if (!window and nat_used and emu_used and nmi_native != nmi_emu)
        return refuse(refusal, .{ .reason = .wg_nmi_ambiguous });
    const nmi_target: u16 = if (emu_used and !nat_used) nmi_emu else nmi_native;

    // Which identity window carries the game's WRAM?
    //
    // I-RAM first: the SA-1's 2 KiB sits at $0000-$07FF of its bus, exactly
    // where the S-CPU sees WRAM's low mirror, so a set that fits needs NO
    // WRAM rewriting at all — the cheapest and safest conversion, and the
    // only one this generator used to attempt.
    //
    // Otherwise BW-RAM, which is what every shipped SA-1 Root conversion
    // actually uses (checked against Vitor Vilela's Gradius III v17: it
    // re-banks $7E:xxxx to $40:xxxx and adds $6000 to low-bank absolute
    // addresses, nothing else). BW-RAM is 128 KiB+ against I-RAM's 2 KiB,
    // so the sets that fit are a different order of game. The price is that
    // every WRAM-naming operand must be rewritten, and D and S must move
    // with them — see the walk below.
    var wram_fits_iram = !window; // window mode IS the BW-RAM move
    if (!window) {
        const touched = usage_map.flag_read | usage_map.flag_write | usage_map.flag_exec;
        var b: u32 = 0;
        while (b < 0x100) : (b += 1) {
            const sys = b < 0x40 or (b >= 0x80 and b < 0xC0);
            const top: u32 = if (b == 0x7E or b == 0x7F) 0x10000 else if (sys) 0x2000 else 0;
            var a: u32 = 0;
            while (a < top) : (a += 1) {
                if (usage[(b << 16) | a] & touched == 0) continue;
                if (b == 0x7F or a >= 0x7F0) {
                    wram_fits_iram = false;
                    break;
                }
            }
            if (!wram_fits_iram) break;
        }
    }
    // The BW-RAM window is uniform: WRAM $7E/$7F:xxxx -> BW-RAM $40/$41:xxxx
    // and low-bank $0000-$1FFF -> $6000-$7FFF, the same byte reached either
    // way. A low-bank address at or above $2000 is not WRAM at all, so
    // nothing in that range can be carried by this move.
    const bwram = !wram_fits_iram;

    // Eligibility walk + MMIO site collection over every executed opcode.
    var sites: [wg_sites_max]WgSite = undefined;
    var n_sites: usize = 0;
    // File offsets of `LDA #imm` operands feeding a TCD/TCS (BW-RAM mode).
    var moves: [wg_moves_max]u32 = undefined;
    var n_moves: usize = 0;
    // File offsets of bank-$00 block moves proved to walk WRAM.
    var bm: [wg_moves_max]u32 = undefined;
    var n_bm: usize = 0;
    // File offsets of `LDA #$7E/$7F` immediates feeding a PLB.
    var dbrs: [wg_moves_max]u32 = undefined;
    var n_dbrs: usize = 0;
    // Unprovable shapes in statically discovered code, left for S4.
    var static_skipped: u32 = 0;
    var bank: u32 = 0;
    // The most recent `LDX #imm` this walk passed, for the block-move source
    // proof below. Reset at every bank and killed by anything that writes X
    // or transfers control, so it only ever survives straight-line code.
    var ldx_at: ?u32 = null;
    var ldx_imm: u16 = 0;
    var ldy_at: ?u32 = null;
    var ldy_imm: u16 = 0;
    var ldy_file: u32 = 0;
    // Does the data bank register point at BW-RAM here? Absolute operands
    // are DBR-relative, so the same instruction means different memory
    // depending on it: with DBR a system bank, `LDA $0900` is WRAM's low
    // mirror and must shift into the $6000 window; with DBR already $7E (or
    // $40 after re-banking), it is that bank's own $0900 and must NOT shift.
    // Gradius III relies on this — its `STZ $2000` at $00:8086 runs with DBR
    // left at $7E by the preceding `MVN $7E,$7E`, which is why Vilela
    // re-banks the move and leaves the store alone.
    //
    // DBR is $00 at reset and system-bank for the overwhelming majority of
    // code, so "not provably BW-RAM" is treated as a system bank; a game
    // that defeats that assumption fails S4 verification rather than
    // shipping.
    var dbr_bw = false;
    while (bank < 0x40) : (bank += 1) {
        const bank_file = bank * 0x8000;
        if (bank_file >= image.len) break;
        var a16: u32 = 0x8000;
        ldx_at = null;
        dbr_bw = false;
        while (a16 < 0x10000) : (a16 += 1) {
            const cpu_addr = (bank << 16) | a16;
            const fl_lo = cov[cpu_addr];
            const fl_hi = cov[0x80_0000 | cpu_addr];
            if ((fl_lo | fl_hi) & usage_map.flag_opcode == 0) continue;
            const file = bank_file + (a16 - 0x8000);
            const op = image[file];
            const fl = if (fl_lo & usage_map.flag_opcode != 0) fl_lo else fl_hi;
            const m8 = fl & usage_map.flag_m != 0;
            // Did this instruction actually run? Statically discovered code
            // is rewritten but never refused over (see `static_walk`).
            const covered = (usage[cpu_addr] | usage[0x80_0000 | cpu_addr]) & usage_map.flag_opcode != 0;
            // Executed in both mirrors with different M widths: the site
            // has two shapes and a single helper cannot serve both. Index-
            // register loads (LDY/LDX) size by the X flag instead.
            const m_mixed = fl_lo & usage_map.flag_opcode != 0 and
                fl_hi & usage_map.flag_opcode != 0 and
                (fl_lo ^ fl_hi) & usage_map.flag_m != 0;
            const x_mixed = fl_lo & usage_map.flag_opcode != 0 and
                fl_hi & usage_map.flag_opcode != 0 and
                (fl_lo ^ fl_hi) & usage_map.flag_x != 0;
            const x8 = fl & usage_map.flag_x != 0;
            if (!covered) {
                // Statically discovered code: collect MMIO sites whose shape
                // the proxy supports; count everything unprovable and leave
                // it alone. No proofs are carried out of here, so the
                // register/DBR knowledge dies conservatively.
                ldx_at = null;
                ldy_at = null;
                dbr_bw = false;
                switch (usage_map.mode(op)) {
                    .abs, .abs_x, .abs_y => {
                        const v = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
                        if (v >= 0x2100 and v < 0x4380 and !window) {
                            const kind: ?WgSiteKind = switch (op) {
                                0xAD, 0xBD, 0xB9 => if (m8) WgSiteKind.r8 else .r16,
                                0x8D, 0x9D, 0x99 => if (m8) WgSiteKind.w8 else .w16,
                                0x9C => if (m8) WgSiteKind.stz8 else .stz16,
                                0xCD => if (m8) WgSiteKind.c8 else .c16,
                                0xBC => if (x8) WgSiteKind.ry8 else .ry16,
                                0xBE => if (x8) WgSiteKind.rx8 else .rx16,
                                0x8E => if (x8) WgSiteKind.wx8 else .wx16,
                                0x8C => if (x8) WgSiteKind.wy8 else .wy16,
                                else => null,
                            };
                            const idx: WgIndex = switch (op) {
                                0xBD, 0x9D, 0xBC => .x,
                                0xB9, 0x99, 0xBE => .y,
                                else => .none,
                            };
                            if (kind != null and bank == 0 and !m_mixed and !x_mixed and n_sites < wg_sites_max) {
                                sites[n_sites] = .{ .file = file, .kind = kind.?, .reg = v, .idx = idx };
                                n_sites += 1;
                            } else static_skipped += 1;
                        }
                    },
                    else => switch (op) {
                        // Shapes the dynamic walk would have refused over:
                        // count them so `static_skipped` is an honest tally
                        // of what verification is being trusted with.
                        0x44, 0x54, 0x2B, 0x5B, 0x1B, 0x9A, 0x00, 0x02, 0xDB => static_skipped += 1,
                        else => {},
                    },
                }
                continue;
            }
            switch (op) {
                // MVN/MVP name their banks in the operand, so a move between
                // WRAM banks re-banks like any long access. A move naming
                // bank $00 does not: bank $00 is WRAM below $2000 and ROM
                // above $8000, and which one this move walks is in X/Y at
                // run time. The destination alone would be decidable (ROM is
                // not writable), but re-banking one side of a move and not
                // the other is worse than refusing, so both stay refused.
                0x44, 0x54 => blockmove: {
                    if (!bwram) return refuse(refusal, .{ .reason = .wg_unsupported_op, .detail = cpu_addr });
                    const dst = image[file + 1];
                    const src = image[file + 2];
                    // Destination first, and it is the easy half: bank $00's
                    // only writable memory is WRAM below $2000, so a move
                    // that writes bank $00 is writing WRAM whatever X and Y
                    // hold. $7E/$7F are unambiguous either way.
                    if (!(dst == 0x7E or dst == 0x7F or dst == 0x00))
                        return refuse(refusal, .{ .reason = .wg_unsupported_op, .detail = cpu_addr });
                    if (dst != 0x00) {
                        // Destination $7E/$7F re-banks to $40/$41. The source
                        // needs nothing: another WRAM bank re-banks the same
                        // way, and any other bank is ROM whose mapping is
                        // identical on the SA-1's bus (Gradius III unpacks
                        // graphics with `MVN $7E,$04`, and v17 ships it as
                        // `MVN $40,$04`). Bank $00 as source is the one
                        // ambiguous case — accept it only when X provably
                        // points at ROM, where the byte passes through
                        // unchanged.
                        if (src == 0x00) {
                            const sx = ldx_at != null and cpu_addr - ldx_at.? <= 16;
                            if (!sx or ldx_imm < 0x8000)
                                return refuse(refusal, .{ .reason = .wg_blockmove_source, .detail = cpu_addr });
                        }
                        dbr_bw = true;
                        break :blockmove;
                    }
                    // Bank $00 both sides, so the banks say nothing: X and Y
                    // decide, and only an immediate that reaches here through
                    // straight-line code proves either. Two shapes occur, and
                    // v17 treats them differently because they ARE different:
                    //
                    //   WRAM <- WRAM   re-bank both to $40; the indices are
                    //                  already the right offsets. (The boot
                    //                  WRAM clear.)
                    //   WRAM <- ROM    leave the banks alone — bank $00 still
                    //                  holds the ROM — and shift the
                    //                  destination index into the $6000
                    //                  window instead.
                    if (src != 0x00) return refuse(refusal, .{ .reason = .wg_blockmove_source, .detail = cpu_addr });
                    const sx = ldx_at != null and cpu_addr - ldx_at.? <= 16;
                    if (!sx or n_bm == wg_moves_max or n_moves == wg_moves_max)
                        return refuse(refusal, .{ .reason = .wg_blockmove_source, .detail = cpu_addr });
                    if (ldx_imm < 0x2000) {
                        // WRAM <- WRAM. In window mode the banks STAY $00
                        // and the X immediate shifts into the $6000 window
                        // instead (Y derives from X in the clear idiom, so
                        // it follows): re-banking to $40,$40 would leave
                        // DBR=$40 where stock leaves $00 — and $00 is a
                        // SYSTEM bank, so any MMIO the game does under the
                        // inherited DBR (or any comparison of a saved copy)
                        // forks. Measured on the real cart: a $40 sat on
                        // the stack where stock saved $00, and the title
                        // transition read it back. The SA-1-execution mode
                        // keeps the re-bank (its MMIO is proxied anyway).
                        if (window) {
                            const at = bank_file + ((ldx_at.? & 0xFFFF) - 0x8000) + 1;
                            for (moves[0..n_moves]) |m| {
                                if (m == at) break;
                            } else {
                                moves[n_moves] = at;
                                n_moves += 1;
                            }
                            dbr_bw = false;
                        } else {
                            bm[n_bm] = file;
                            n_bm += 1;
                            dbr_bw = true;
                        }
                    } else if (ldx_imm >= 0x8000) {
                        // WRAM <- ROM. Here the destination index is the
                        // thing that moves, so it does have to be provable.
                        const dy = ldy_at != null and cpu_addr - ldy_at.? <= 16;
                        if (!dy or ldy_imm >= 0x2000)
                            return refuse(refusal, .{ .reason = .wg_blockmove_source, .detail = cpu_addr });
                        moves[n_moves] = ldy_file + 1;
                        n_moves += 1;
                        dbr_bw = false; // DBR stays bank $00
                    } else return refuse(refusal, .{ .reason = .wg_blockmove_source, .detail = cpu_addr });
                },
                0x00, 0x02, 0xDB => return refuse(refusal, .{ .reason = .wg_unsupported_op, .detail = cpu_addr }),
                else => {},
            }
            // Moving WRAM into the BW-RAM window moves the direct page and
            // the stack with it: both live in bank $00's low half, which is
            // exactly the range being displaced by $6000. Every D and S the
            // game installs must therefore be adjustable at build time, so
            // each executed TCD/TCS has to be fed by an adjacent 16-bit
            // `LDA #imm` we can add $6000 to. Anything else — a D or S
            // pulled from the stack or computed — cannot be proven and is
            // refused by name rather than silently left pointing at WRAM
            // that no longer exists on this bus.
            if (bwram) switch (op) {
                0x2B, 0x5B, 0x1B, 0x9A => dpmove: { // PLD, TCD, TCS, TXS
                    const dyn: Reason = if (op == 0x2B or op == 0x5B) .wg_dp_dynamic else .wg_stack_dynamic;
                    // A `PLD` that restores a D some `PHD` pushed — the tail
                    // of every interrupt epilogue — is transparent to the
                    // shift: whatever went on the stack was already shifted,
                    // and comes back the same. Only a `PLD` fed by a pushed
                    // *immediate* establishes a new D, and only that shape
                    // needs rewriting. A PEA does it in one instruction.
                    if (op == 0x2B) {
                        if (file >= 3 and image[file - 3] == 0xF4) {
                            const imm = std.mem.readInt(u16, image[file - 2 ..][0..2], .little);
                            if (imm >= 0x2000) return refuse(refusal, .{ .reason = dyn, .detail = cpu_addr });
                            if (n_moves == wg_moves_max) return refuse(refusal, .{ .reason = dyn, .detail = cpu_addr });
                            moves[n_moves] = file - 2;
                            n_moves += 1;
                            break :dpmove;
                        }
                        const pushed = file >= 1 and
                            (image[file - 1] == 0xDA or image[file - 1] == 0x5A or image[file - 1] == 0x48);
                        const from_imm = pushed and file >= 4 and
                            (image[file - 4] == 0xA2 or image[file - 4] == 0xA0 or image[file - 4] == 0xA9);
                        if (!from_imm) break :dpmove; // restore shape: nothing to do
                    }
                    // Three shapes reach D or S from an immediate, and each
                    // is fed by a register whose load carries its own width
                    // flag: TCD/TCS take A (M), TXS takes X (X), and
                    // `LDX/LDA #imm : PHX/PHA : PLD` — the idiom Gradius III
                    // uses, and the very byte Vilela's v17 patches — reaches
                    // D through the stack. Distance from the immediate's
                    // operand back to this opcode is all that differs.
                    var back: u32 = 3; // LD? #imm | this
                    var want_ld: u8 = 0xA9;
                    var want_w: u8 = usage_map.flag_m;
                    if (op == 0x9A) {
                        want_ld = 0xA2;
                        want_w = usage_map.flag_x;
                    } else if (op == 0x2B) {
                        if (file < 1) return refuse(refusal, .{ .reason = dyn, .detail = cpu_addr });
                        switch (image[file - 1]) { // the push feeding PLD
                            0xDA => { // PHX
                                want_ld = 0xA2;
                                want_w = usage_map.flag_x;
                            },
                            0x5A => { // PHY — Gradius III's main-loop shape
                                want_ld = 0xA0;
                                want_w = usage_map.flag_x;
                            },
                            0x48 => {}, // PHA: defaults
                            else => return refuse(refusal, .{ .reason = dyn, .detail = cpu_addr }),
                        }
                        back = 4; // LD? #imm | PH? | this
                    }
                    if (file < back) return refuse(refusal, .{ .reason = dyn, .detail = cpu_addr });
                    if (image[file - back] != want_ld)
                        return refuse(refusal, .{ .reason = dyn, .detail = cpu_addr });
                    const ld = cpu_addr - back;
                    const lf = cov[ld] | cov[0x80_0000 | ld];
                    // The load must have executed, and in 16-bit width — an
                    // 8-bit load leaves the high half of D/S carrying
                    // whatever was there, which no static shift can follow.
                    if (lf & usage_map.flag_opcode == 0 or lf & want_w != 0)
                        return refuse(refusal, .{ .reason = dyn, .detail = cpu_addr });
                    const imm = std.mem.readInt(u16, image[file - back + 1 ..][0..2], .little);
                    if (imm >= 0x2000 or n_moves == wg_moves_max)
                        return refuse(refusal, .{ .reason = dyn, .detail = cpu_addr });
                    // One immediate can feed two consumers (a TXS and a
                    // later PHX/PLD); shifting it twice would land at
                    // $C000. Record each operand once.
                    const at = file - back + 1;
                    for (moves[0..n_moves]) |m| {
                        if (m == at) break;
                    } else {
                        moves[n_moves] = at;
                        n_moves += 1;
                    }
                },
                else => {},
            };
            // Track X for the block-move source proof. Updated after this
            // instruction's own checks, and before the operand switch below,
            // whose branches `continue`.
            if (bwram) {
                const x16 = fl & usage_map.flag_x == 0;
                // A D argument passed through a call: `LDY/LDX #imm` still
                // live at a `JSR f` where f opens `PHY/PHX : PLD` — the
                // callee establishes D from the caller's immediate, which
                // Gradius III does at every main-loop iteration
                // (`LDY #$1F00 : ... : JSR $9857` / `$9857: PHY : PLD`).
                // The adjacency matcher above cannot see across the call,
                // but the carried immediate can, and v17 confirms the fix:
                // it shifts exactly these immediates.
                if (op == 0x20) jsr: {
                    const t = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
                    if (t < 0x8000) break :jsr;
                    const tf = bank_file + (t - 0x8000);
                    if (tf + 1 >= image.len or image[tf + 1] != 0x2B) break :jsr;
                    const imm_file: u32 = switch (image[tf]) {
                        0x5A => blk: { // PHY : PLD — needs the Y carry
                            const at = ldy_at orelse break :jsr;
                            if (cpu_addr - at > 16 or ldy_imm >= 0x2000) break :jsr;
                            break :blk ldy_file + 1;
                        },
                        0xDA => blk: { // PHX : PLD — the X carry
                            const at = ldx_at orelse break :jsr;
                            if (cpu_addr - at > 16 or ldx_imm >= 0x2000) break :jsr;
                            break :blk bank_file + ((at & 0xFFFF) - 0x8000) + 1;
                        },
                        else => break :jsr,
                    };
                    if (n_moves == wg_moves_max)
                        return refuse(refusal, .{ .reason = .wg_dp_dynamic, .detail = cpu_addr });
                    for (moves[0..n_moves]) |m| {
                        if (m == imm_file) break;
                    } else {
                        moves[n_moves] = imm_file;
                        n_moves += 1;
                    }
                }
                if (op == 0xA2) { // LDX #
                    if (x16) {
                        ldx_at = cpu_addr;
                        ldx_imm = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
                    } else ldx_at = null;
                } else if (writesXOrBranches(op)) ldx_at = null;
                if (op == 0xA0) { // LDY #
                    if (x16) {
                        ldy_at = cpu_addr;
                        ldy_file = file;
                        ldy_imm = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
                    } else ldy_at = null;
                } else if (writesYOrBranches(op)) ldy_at = null;

                // DBR: the `LDA #bank : PHA : PLB` idiom is the only shape
                // that names a bank statically. A WRAM bank there re-banks
                // like any other $7E/$7F reference; anything else leaves DBR
                // system-bank as far as this walk can tell. The knowledge
                // survives conditional branches and DBR-transparent calls
                // (the pin at a routine's head dominates its body); it dies
                // at unconditional transfers — join points another DBR may
                // reach.
                if (!dbrSurvives(image, cov, file, op)) dbr_bw = false;
                if (op == 0xAB) {
                    dbr_bw = false;
                    if (file >= 3 and image[file - 3] == 0xA9 and image[file - 1] == 0x48) {
                        const b = image[file - 2];
                        if (b == 0x7E or b == 0x7F) {
                            if (n_dbrs == wg_moves_max)
                                return refuse(refusal, .{ .reason = .wg_wram_beyond_bwram, .detail = cpu_addr });
                            dbrs[n_dbrs] = file - 2;
                            n_dbrs += 1;
                            dbr_bw = true;
                        }
                    }
                }
            }

            switch (usage_map.mode(op)) {
                .none, .dp => {},
                .dp_idx => {},
                .abs, .abs_x, .abs_y => {
                    const v = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
                    // With DBR on BW-RAM the operand already names the right
                    // byte of it, whatever its value — no window, no MMIO,
                    // nothing to check.
                    if (bwram and dbr_bw) continue;
                    if (v >= 0x8000) continue; // ROM: identical on both buses
                    if (!bwram and v < 0x800) continue; // I-RAM window: fine as-is
                    if (bwram and v < 0x2000) continue; // rewritten to the window below
                    if (v >= 0x2100 and v < 0x4380) {
                        // Window mode: the game still runs on the S-CPU,
                        // which owns its MMIO — nothing to proxy.
                        if (window) continue;
                        if (bank != 0)
                            return refuse(refusal, .{ .reason = .wg_mmio_outside_bank0, .detail = cpu_addr });
                        const mixed = switch (op) {
                            0xBC, 0xBE, 0x8E, 0x8C => x_mixed,
                            else => m_mixed,
                        };
                        if (mixed)
                            return refuse(refusal, .{ .reason = .wg_mmio_shape, .detail = cpu_addr });
                        const kind: WgSiteKind = switch (op) {
                            0xAD, 0xBD, 0xB9 => if (m8) WgSiteKind.r8 else .r16,
                            0x8D, 0x9D, 0x99 => if (m8) WgSiteKind.w8 else .w16,
                            0x9C => if (m8) WgSiteKind.stz8 else .stz16,
                            // CMP against an MMIO register: an APU-port
                            // handshake spin, in every Konami boot.
                            0xCD => if (m8) WgSiteKind.c8 else .c16,
                            // Index-register loads size by the X flag: the
                            // auto-joypad read loop is LDY $4218,X.
                            0xBC => if (x8) WgSiteKind.ry8 else .ry16,
                            0xBE => if (x8) WgSiteKind.rx8 else .rx16,
                            // ...and index-register stores (STX $2116 sets
                            // the VRAM address in Gradius III's NMI path).
                            0x8E => if (x8) WgSiteKind.wx8 else .wx16,
                            0x8C => if (x8) WgSiteKind.wy8 else .wy16,
                            else => return refuse(refusal, .{ .reason = .wg_mmio_shape, .detail = cpu_addr }),
                        };
                        const idx: WgIndex = switch (op) {
                            0xBD, 0x9D, 0xBC => .x,
                            0xB9, 0x99, 0xBE => .y,
                            else => .none,
                        };
                        if (n_sites == wg_sites_max)
                            return refuse(refusal, .{ .reason = .wg_mmio_shape, .detail = cpu_addr });
                        sites[n_sites] = .{ .file = file, .kind = kind, .reg = v, .idx = idx };
                        n_sites += 1;
                    } else return refuse(refusal, .{
                        .reason = if (bwram) Reason.wg_wram_beyond_bwram else .wg_wram_beyond_iram,
                        .detail = cpu_addr,
                    });
                },
                .long, .long_x => {
                    const b = image[file + 3];
                    const v = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
                    if ((b & 0x7F) <= 0x3F and v >= 0x2100 and v < 0x4380) {
                        if (window) continue; // native MMIO, long-addressed
                        return refuse(refusal, .{ .reason = .wg_mmio_shape, .detail = cpu_addr });
                    }
                    const wram = b == 0x7E or b == 0x7F or ((b & 0x7F) <= 0x3F and v < 0x2000);
                    // BW-RAM carries all of WRAM: $7E/$7F re-bank to $40/$41
                    // and low-bank forms shift into the window, both below.
                    if (wram and !bwram and (b == 0x7F or v >= 0x800))
                        return refuse(refusal, .{ .reason = .wg_wram_beyond_iram, .detail = cpu_addr });
                    // $7E:0000-07FF long sites are re-banked to $00 below.
                },
            }
        }
    }

    var helper_len: u32 = 0;
    // Dedup: sites sharing (kind, reg, idx) share one emitted helper.
    var uniq: [wg_uniq_max]WgSite = undefined;
    var n_uniq: usize = 0;
    for (sites[0..n_sites]) |site| {
        const seen = for (uniq[0..n_uniq]) |u| {
            if (u.kind == site.kind and u.reg == site.reg and u.idx == site.idx) break true;
        } else false;
        if (seen) continue;
        if (n_uniq == wg_uniq_max)
            return refuse(refusal, .{ .reason = .wg_mmio_shape, .detail = site.file });
        uniq[n_uniq] = site;
        n_uniq += 1;
    }
    for (uniq[0..n_uniq]) |u| helper_len += wgHelperLen(u);
    // The scaffolding is bank-$00-only: the shim is the reset vector's
    // target, the service loop is `JMP`ed from it, and CRV/CNV are 16-bit
    // registers, so the SA-1 prologue and NMI shim must be reachable in
    // bank $00 too. The helpers are not: they run on the SA-1, and every
    // absolute they touch (the mailbox, CIE, CIC) mirrors across all system
    // banks, so they can live in ANY bank's padding — which matters, because
    // a real game's bank $00 is nearly full (Gradius III has 1.5 KiB of
    // padding against ~3.6 KiB of helpers). Each unique helper gets a
    // 4-byte `JML` trampoline in bank $00 for the sites' in-place `JSR` to
    // land on; the helper ends with `JML` back to a shared bank-$00 `RTS`.
    const scaffold: u32 = if (window)
        wg_window_shim_max + (if (win_candidates.len != 0) win_disp_max else 0)
    else
        wg_prologue_len + (if (bwram) @as(u32, wg_prologue_bw_extra) else 0) +
            wg_sa1_nmi_len + wg_scpu_nmi_len +
            @as(u32, wg_service.len) + wg_shim_len;
    var carve: u32 = undefined; // bank $00: scaffold (+ trampolines if split)
    var split = false;
    // Split mode: where each helper landed (file offset), first-fit across
    // every bank's largest padding run — helpers are self-contained and the
    // trampolines carry 24-bit targets, so they need not even share a bank.
    var helper_at: [wg_uniq_max]u32 = undefined;
    if (patchgen.findFreeSpace(image[0..header.offset], scaffold + helper_len)) |c| {
        carve = c;
    } else {
        split = true;
        const b0_need = scaffold + 4 * @as(u32, @intCast(n_uniq)) + 1;
        carve = patchgen.findFreeSpace(image[0..header.offset], b0_need) orelse
            return refuse(refusal, .{ .reason = .no_free_space, .detail = b0_need });
        // The largest padding run in each bank beyond $00, cursor at its
        // start plus the same 8-byte margin findFreeSpace keeps.
        const Run = struct { cur: u32, end: u32 };
        var bank_runs: [0x40]Run = undefined;
        var n_runs: usize = 0;
        var hb: u32 = 1;
        while (hb * 0x8000 < image.len) : (hb += 1) {
            const base = hb * 0x8000;
            const win = image[base..@min(base + 0x8000, image.len)];
            var best_off: u32 = 0;
            var best_len: u32 = 0;
            var i: usize = 0;
            while (i < win.len) {
                const b = win[i];
                if (b == 0x00 or b == 0xFF) {
                    var j = i + 1;
                    while (j < win.len and win[j] == b) j += 1;
                    if (j - i >= best_len) {
                        best_len = @intCast(j - i);
                        best_off = @intCast(i);
                    }
                    i = j;
                } else i += 1;
            }
            if (best_len > 72) { // margin + at least one helper
                bank_runs[n_runs] = .{ .cur = base + best_off + 8, .end = base + best_off + best_len };
                n_runs += 1;
            }
        }
        // First-fit each helper (+3 for the JML that replaces its RTS).
        for (uniq[0..n_uniq], 0..) |u, ui| {
            const need_h = wgHelperLen(u) + 3;
            helper_at[ui] = for (bank_runs[0..n_runs]) |*r| {
                if (r.end - r.cur >= need_h) {
                    const at = r.cur;
                    r.cur += need_h;
                    break at;
                }
            } else return refuse(refusal, .{ .reason = .no_free_space, .detail = need_h });
        }
    }

    const out = try gpa.dupe(u8, image);
    errdefer gpa.free(out);
    var res: Result = .{ .image = out, .stats = .{}, .fate = @splat(.not_attempted) };
    res.stats.static_skipped = static_skipped;

    // Re-bank $7E long sites into the identity window (bank $7E does not
    // exist on the SA-1 bus; bank $00's low $0800 is the same I-RAM).
    bank = 0;
    while (bank < 0x40) : (bank += 1) {
        const bank_file = bank * 0x8000;
        if (bank_file >= out.len) break;
        var a16: u32 = 0x8000;
        // Same DBR reasoning as the eligibility walk, replayed here because
        // the shift an absolute site needs depends on it. Read before this
        // pass mutates the site; the DBR immediates themselves are rewritten
        // after the loop so the idiom is still recognisable while it runs.
        dbr_bw = false;
        while (a16 < 0x10000) : (a16 += 1) {
            const cpu_addr = (bank << 16) | a16;
            if ((cov[cpu_addr] | cov[0x80_0000 | cpu_addr]) & usage_map.flag_opcode == 0) continue;
            const file = bank_file + (a16 - 0x8000);
            const op = out[file];
            if (bwram) {
                // A WRAM bank byte materialized by an immediate and stored —
                // the bank slot of a long pointer the game will dereference
                // at run time (`LDA #$7E : STA $05` builds [$03] = $7E:xxxx
                // in Gradius III's decompressor). The pointer VALUE is
                // runtime data no static rewrite can reach, but its bank
                // byte comes from this immediate, and $40 names the same
                // bytes. The store opcode is checked against the coverage
                // map, so this never fires mid-instruction. v17 rewrites
                // exactly these immediates (and none of the arithmetic uses
                // of the constant $7E, which have no adjacent store).
                if (op == 0xA9 and (out[file + 1] == 0x7E or out[file + 1] == 0x7F)) {
                    const fl2 = if (cov[cpu_addr] & usage_map.flag_opcode != 0) cov[cpu_addr] else cov[0x80_0000 | cpu_addr];
                    const next = cpu_addr + 2;
                    const next_op = (cov[next] | cov[0x80_0000 | next]) & usage_map.flag_opcode != 0;
                    if (fl2 & usage_map.flag_m != 0 and next_op and file + 2 < out.len and
                        (out[file + 2] == 0x85 or out[file + 2] == 0x8D or
                            out[file + 2] == 0x8F or out[file + 2] == 0x9F))
                    {
                        out[file + 1] -= 0x3E;
                        res.stats.rewritten_long += 1;
                    }
                    // The 16-BIT form of the same idiom. Two shapes carry
                    // a bank in a 16-bit immediate: `LDA #$007E : STA
                    // $43x4` (a DMA source bank — the boot logo) and
                    // `LDA #$007E : STA $7E:xxxx,X` (the bank WORD of a
                    // far-pointer queue entry — the title's DMA queue
                    // builder at $00:8EBB). The store's shape names the
                    // semantics; a random 16-bit $007E is a coordinate
                    // and stays.
                    const fl16 = if (cov[cpu_addr] & usage_map.flag_opcode != 0) cov[cpu_addr] else cov[0x80_0000 | cpu_addr];
                    if (fl16 & usage_map.flag_m == 0 and out[file + 2] == 0x00 and
                        file + 6 < out.len)
                    {
                        const st = out[file + 3];
                        const bank_word = switch (st) {
                            0x8D => blk: {
                                const tgt = std.mem.readInt(u16, out[file + 4 ..][0..2], .little);
                                break :blk tgt >= 0x4304 and tgt <= 0x4374 and (tgt & 0xF) == 4;
                            },
                            // A long store into WRAM ($7E/$7F pre-rewrite):
                            // the immediate is the bank word of whatever
                            // entry is being built there.
                            0x8F, 0x9F => out[file + 6] == 0x7E or out[file + 6] == 0x7F,
                            else => false,
                        };
                        if (bank_word) {
                            out[file + 1] -= 0x3E;
                            res.stats.rewritten_long += 1;
                        }
                    }
                }
                if (!dbrSurvives(out, cov, file, op)) dbr_bw = false;
                if (op == 0xAB) {
                    dbr_bw = file >= 3 and out[file - 3] == 0xA9 and out[file - 1] == 0x48 and
                        (out[file - 2] == 0x7E or out[file - 2] == 0x7F);
                } else if (op == 0x44 or op == 0x54) {
                    // Only a move whose destination becomes BW-RAM leaves
                    // DBR there; the ROM-source shape keeps bank $00.
                    const d0 = out[file + 1];
                    dbr_bw = d0 == 0x7E or d0 == 0x7F or (d0 == 0x00 and for (bm[0..n_bm]) |f| {
                        if (f == file) break true;
                    } else false);
                }
            }
            switch (usage_map.mode(op)) {
                .long, .long_x => {
                    const b = out[file + 3];
                    const v = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                    if (bwram) {
                        // $7E/$7F are not on the SA-1's bus; $40/$41 are the
                        // same bytes of BW-RAM, at the same offsets — and
                        // identity-offset, so an index carries over.
                        if (b == 0x7E or b == 0x7F) {
                            out[file + 3] = b - 0x3E;
                            res.stats.rewritten_long += 1;
                        } else if (b == 0x7D and v >= 0xFF00) {
                            // The NEGATIVE-OFFSET idiom: `SBC $7D:FFFB,X`
                            // wraps through the bank boundary into
                            // $7E:0000+X-5 — entry-relative backward reach
                            // into a WRAM queue (the title's DMA queue
                            // reads its previous entry this way). $3F
                            // wraps into $40 the same distance.
                            out[file + 3] = 0x3F;
                            res.stats.rewritten_long += 1;
                        } else if ((b & 0x7F) <= 0x3F and v < 0x2000 and usage_map.mode(op) == .long) {
                            // The low mirror through a system bank — but
                            // only UNINDEXED: `LDA $01:0000,X` with a big X
                            // is how Gradius III walks a ROM table in bank
                            // $01, and shifting its base reads the wrong
                            // ROM (measured: the APU boot upload sent
                            // garbage IPL parameters). The same bytes
                            // reached without an index are WRAM for
                            // certain. An indexed instance that really
                            // does walk low WRAM reads the stale original
                            // and fails S4 — the honest outcome for an
                            // undecidable site.
                            std.mem.writeInt(u16, out[file + 1 ..][0..2], v + wg_bw_window, .little);
                            res.stats.rewritten_long += 1;
                        }
                    } else if (b == 0x7E and v < 0x800) {
                        out[file + 3] = 0x00;
                        res.stats.rewritten_long += 1;
                    }
                },
                .abs, .abs_x, .abs_y => if (bwram and !dbr_bw) {
                    const v = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                    // A TINY base under an index is the "X is the pointer"
                    // idiom — the register carries the real address, which
                    // can as legitimately be ROM through the ambient bank
                    // (the title's display-list walker reads $01:8000+X
                    // via `LDY $0000,X` with DBR=$01) as low WRAM.
                    // Shifting the base breaks the ROM walks; leaving it
                    // breaks a true low-WRAM walk softly (stale reads S4
                    // catches). Real table bases keep the shift.
                    if (usage_map.mode(op) != .abs and v < 0x100) continue;
                    if (v < 0x2000) {
                        std.mem.writeInt(u16, out[file + 1 ..][0..2], v + wg_bw_window, .little);
                        res.stats.rewritten_abs += 1;
                    }
                },
                // Indirect control flow reads its *pointer* from bank $00:
                // `JMP ($0000)` names a WRAM word that just moved into the
                // window, and mode() files these as .none because the
                // operand is not a data address the offload rewriter cares
                // about. Here it is exactly a data address. JMP (abs) and
                // JMP/JSR (abs,X) pointers under $2000 shift with their
                // memory; [abs] (JML) reads 3 bytes but shifts the same way.
                .none => if (bwram) switch (op) {
                    0x6C, 0x7C, 0xFC, 0xDC => {
                        const v = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                        if (v < 0x2000) {
                            std.mem.writeInt(u16, out[file + 1 ..][0..2], v + wg_bw_window, .little);
                            res.stats.rewritten_abs += 1;
                        }
                    },
                    // MVN/MVP: $7E/$7F re-bank like any long access, and
                    // bank $00 re-banks only where the walk proved both
                    // halves (the sites it recorded in `bm`).
                    0x44, 0x54 => {
                        const proved = for (bm[0..n_bm]) |f| {
                            if (f == file) break true;
                        } else false;
                        for (1..3) |k| {
                            const b = out[file + k];
                            if (b == 0x7E or b == 0x7F) {
                                out[file + k] = b - 0x3E;
                                res.stats.rewritten_long += 1;
                            } else if (b == 0x00 and proved) {
                                out[file + k] = 0x40;
                                res.stats.rewritten_long += 1;
                            }
                        }
                    },
                    else => {},
                },
                else => {},
            }
        }
    }
    // Data bank loads follow their memory too: a game that sets DBR to $7E
    // is naming WRAM, which is now $40.
    for (dbrs[0..n_dbrs]) |off| {
        out[off] -= 0x3E;
        res.stats.rewritten_long += 1;
    }
    // D and S follow their memory into the window.
    for (moves[0..n_moves]) |off| {
        const imm = std.mem.readInt(u16, out[off..][0..2], .little);
        std.mem.writeInt(u16, out[off..][0..2], imm + wg_bw_window, .little);
        res.stats.dp_sites += 1;
    }
    res.stats.d_moved = bwram;

    // Emit. Window mode's scaffold is ONE S-CPU shim: open the S-CPU's
    // BW-RAM gates, select window block 0, reproduce the power-on direct
    // page and stack INSIDE the window (the game's own D/S establishes
    // were shifted with everything else, but the inherited power-on
    // D=$0000 / S=$01FF would land in WRAM while every rewritten access
    // went to BW-RAM), and enter the game's own reset. The SA-1 is never
    // released from reset — the cart is carried for its RAM.
    var cur: usize = 0;
    const base16: u16 = 0x8000 + @as(u16, @intCast(carve));
    const d = out[carve..];
    if (window) {
        // Offloads first: eligibility walks the REWRITTEN image, and the
        // dispatcher's CRV feeds the shim below. The dispatcher and NMI
        // prologue live in this same bank-0 carve, after the shim slot.
        const crv: ?u16 = if (win_candidates.len != 0)
            emitWindowOffloads(out, cov, header.offset, win_candidates, win_allow_async, carve + wg_window_shim_max, &res)
        else
            null;

        var wn: usize = 0;
        d[wn] = 0x78; // SEI
        wn += 1;
        wn = emitStore(d, wn, 0x2224, 0x00); // SBM: S-CPU window = block 0
        wn = emitStore(d, wn, 0x2226, 0x80); // SWEN: S-CPU BW-RAM writes
        wn = emitStore(d, wn, 0x2228, 0x00); // BWPA: nothing protected
        if (crv) |v| {
            // Boot the SA-1 into the window dispatcher; the async busy
            // flag starts idle (I-RAM is garbage at power-on, and SIWP
            // must open before the S-CPU can zero it).
            wn = emitStore(d, wn, 0x2229, 0xFF);
            wn = emitStore(d, wn, 0x2203, @truncate(v));
            wn = emitStore(d, wn, 0x2204, @truncate(v >> 8));
            if (res.stats.async_entry != 0) wn = emitStore(d, wn, 0x378A, 0x00);
            put(d, &wn, &.{ 0x9C, 0x00, 0x22 }); // release reset
        }
        put(d, &wn, &.{ 0x18, 0xFB, 0xC2, 0x30 }); // CLC / XCE / REP #$30
        put(d, &wn, &.{ 0xA9, @truncate(wg_bw_window), @truncate(wg_bw_window >> 8), 0x5B }); // LDA #$6000 / TCD
        put(d, &wn, &.{ 0xA9, 0xFF, 0x61, 0x1B }); // LDA #$61FF / TCS
        put(d, &wn, &.{ 0xE2, 0x30 }); // SEP #$30
        put(d, &wn, &.{ 0x4C, @truncate(reset), @truncate(reset >> 8) });
        std.debug.assert(wn <= wg_window_shim_max);
        // Reset -> shim; the other vectors stay the game's own unless an
        // async offload injected its NMI prologue above.
        std.mem.writeInt(u16, out[header.offset + 0x3C ..][0..2], base16, .little);
        out[header.offset + 0x15] = 0x23;
        out[header.offset + 0x16] = 0x35;
        out[header.offset + 0x18] = 0x07; // 128 KiB BW-RAM: all of WRAM
        patchgen.recomputeChecksum(out, header.offset);
        res.stats.shim_addr = base16;
        res.stats.park_addr = crv orelse 0;
        res.stats.offloaded = if (crv == null) reset else res.stats.offloaded;
        return res;
    }
    // Where each unique helper's JSR target lives in bank $00: the helper
    // itself when everything fits, its trampoline when split.
    var uniq_addr: [wg_uniq_max]u16 = undefined;
    if (!split) {
        for (uniq[0..n_uniq], 0..) |u, ui| {
            uniq_addr[ui] = base16 + @as(u16, @intCast(cur));
            const before = cur;
            wgEmitHelper(d, &cur, u);
            std.debug.assert(cur - before == wgHelperLen(u));
        }
    } else {
        // Helpers wherever first-fit placed them, each ending in a JML back
        // to the shared bank-$00 RTS stub instead of its own RTS (a JSR
        // pushes 16 bits, so an RTS with PB stuck in the helper's bank would
        // return into it).
        const rts16: u16 = base16 + @as(u16, @intCast(scaffold)) + 4 * @as(u16, @intCast(n_uniq));
        for (uniq[0..n_uniq], 0..) |u, ui| {
            const hd = out[helper_at[ui]..];
            var hcur: usize = 0;
            wgEmitHelper(hd, &hcur, u);
            std.debug.assert(hcur == wgHelperLen(u));
            std.debug.assert(hd[hcur - 1] == 0x60); // every helper ends RTS
            hcur -= 1;
            put(hd, &hcur, &.{ 0x5C, @truncate(rts16), @truncate(rts16 >> 8), 0x00 });
        }
        // Bank $00: trampolines after the scaffold, then the RTS stub. The
        // scaffold is emitted below at `cur`; reserve its span now.
        var tcur: usize = scaffold;
        for (uniq[0..n_uniq], 0..) |_, ui| {
            uniq_addr[ui] = base16 + @as(u16, @intCast(tcur));
            const h16: u16 = 0x8000 + @as(u16, @intCast(helper_at[ui] % 0x8000));
            const hbank: u8 = @intCast(helper_at[ui] / 0x8000);
            put(d, &tcur, &.{ 0x5C, @truncate(h16), @truncate(h16 >> 8), hbank });
        }
        d[tcur] = 0x60; // the shared RTS
        std.debug.assert(base16 + @as(u16, @intCast(tcur)) == rts16);
    }
    for (sites[0..n_sites]) |site| {
        const haddr = for (uniq[0..n_uniq], 0..) |u, ui| {
            if (u.kind == site.kind and u.reg == site.reg and u.idx == site.idx) break uniq_addr[ui];
        } else unreachable;
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
        0x8D, 0x0A, 0x22, // CIE: NMI from the SNES enabled (A still $10)
    });
    if (bwram) {
        // Reproduce the power-on direct page and stack *inside the window*.
        // The game's own TCD/TCS/TXS were shifted by $6000 with everything
        // else, but a game that simply inherits D=$0000 / S=$01FF would
        // otherwise land in I-RAM while its absolute accesses to the same
        // variables went to BW-RAM — the two would silently disagree.
        // Native mode first: emulation pins S to page 1.
        put(d, &cur, &.{
            0x9C, 0x25, 0x22, // STZ $2225 (CBM: BW-RAM block 0)
            0x9C, 0x28, 0x22, // STZ $2228 (BWPA: unprotect)
            0x18, 0xFB, 0xC2, 0x30, // CLC / XCE / REP #$30
            0xA9, @truncate(wg_bw_window), @truncate(wg_bw_window >> 8), 0x5B, // LDA #$6000 / TCD
            0xA9, 0xFF, 0x61, 0x1B, // LDA #$61FF / TCS
            0xE2, 0x30, // SEP #$30
        });
    }
    put(d, &cur, &.{ 0x4C, @truncate(reset), @truncate(reset >> 8) });
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
    std.debug.assert(cur + n2 == scaffold + if (split) @as(usize, 0) else helper_len);

    // Vectors: reset -> shim; NMI (native + emulation) -> the forward stub.
    std.mem.writeInt(u16, out[header.offset + 0x3C ..][0..2], shim, .little);
    std.mem.writeInt(u16, out[header.offset + 0x2A ..][0..2], scpu_nmi, .little);
    std.mem.writeInt(u16, out[header.offset + 0x3A ..][0..2], scpu_nmi, .little);

    out[header.offset + 0x15] = 0x23;
    out[header.offset + 0x16] = 0x35;
    // BW-RAM size: 32 KiB is plenty when the game's state stayed in I-RAM,
    // but the window mode maps all 128 KiB of WRAM into it.
    out[header.offset + 0x18] = if (bwram) 0x07 else 0x05;
    patchgen.recomputeChecksum(out, header.offset);

    res.stats.shim_addr = shim;
    res.stats.park_addr = svc;
    res.stats.offloaded = reset;
    res.stats.offload_count = 1;
    return res;
}

/// Does `op` put a new value in X, or hand control somewhere this linear
/// walk cannot follow? Either kills the `LDX #imm` the block-move source
/// proof is carrying — the walk only reasons about straight-line code, so
/// anything that could arrive with a different X invalidates it.
fn writesXOrBranches(op: u8) bool {
    return switch (op) {
        // Loads into X, transfers into X, pulls, inc/dec — and block moves,
        // which leave X at the end of the run.
        0xA2, 0xA6, 0xB6, 0xAE, 0xBE, 0xAA, 0xBA, 0xFA, 0xE8, 0xCA, 0x44, 0x54 => true,
        else => branches(op),
    };
}

/// The same, for Y — which the block-move destination proof rides on.
fn writesYOrBranches(op: u8) bool {
    return switch (op) {
        // Loads into Y, transfers into Y, pull, inc/dec — and block moves.
        0xA0, 0xA4, 0xB4, 0xAC, 0xBC, 0xA8, 0x7A, 0xC8, 0x88, 0x9B, 0x44, 0x54 => true,
        else => branches(op),
    };
}

/// Hands control somewhere a linear walk cannot follow, so nothing it was
/// carrying about register contents survives.
fn branches(op: u8) bool {
    return switch (op) {
        0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0, 0x80, 0x82 => true,
        0x4C, 0x5C, 0x6C, 0x7C, 0xDC, 0x20, 0x22, 0xFC => true,
        0x60, 0x6B, 0x40, 0x00, 0x02 => true,
        else => false,
    };
}

/// Does the DBR knowledge survive `op` at `file`? A CONDITIONAL branch
/// does not change DBR — the pin at a routine's head dominates its whole
/// straight-line body, branches included (killing it there is what made
/// the window rewriter shift `STA $0000,Y` sites that run under a pinned
/// $7E and corrupt BW-RAM $9C00 with the bubble tables). A JSR/JSL
/// survives when the callee provably never touches DBR. Everything else
/// unconditional (JMP/BRA/returns/interrupts) is a join point another
/// DBR may reach — the knowledge dies.
fn dbrSurvives(image: []const u8, cov: []const u8, file: u32, op: u8) bool {
    switch (op) {
        // Conditional branches and short unconditional skips (BRA/BRL):
        // neither touches DBR, and the next LINEAR instruction is the
        // same routine's alternate path, under the same pin.
        0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0, 0x80, 0x82 => return true,
        0x20, 0x22 => {
            if (op == 0x22 and image[file + 3] != 0x00) return false;
            const tgt = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
            if (tgt < 0x8000) return false;
            return dbrTransparent(image, cov, tgt, 2);
        },
        else => return !branches(op),
    }
}

/// Linear scan of a callee: true when every covered instruction to its
/// return leaves DBR alone (no PLB, no block move, no interrupt-adjacent
/// op), recursing through nested bank-$00 calls. Anything the scan cannot
/// follow — an uncovered byte, a jump, depth exhausted — is a no.
fn dbrTransparent(image: []const u8, cov: []const u8, entry: u16, depth: u8) bool {
    if (depth == 0) return false;
    var pc: u32 = entry;
    while (pc - entry < 768) {
        if (pc > 0xFFFF) return false;
        const fl = cov[pc] | cov[0x80_0000 | pc];
        if (fl & usage_map.flag_opcode == 0) return false;
        const file = pc - 0x8000;
        const op = image[file];
        switch (op) {
            0x60, 0x6B => return true, // RTS/RTL: clean exit
            0xAB, 0x44, 0x54, 0x40, 0x00, 0x02, 0xDB => return false,
            // An intra-span JMP/BRA/BRL changes nothing about DBR; the
            // scan keeps walking linearly (the return is still ahead of
            // it). A jump that leaves the span is a path it cannot judge.
            0x4C => {
                const dst = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
                if (dst < entry or dst - entry >= 768) return false;
            },
            0x80, 0x82 => {
                const dst = if (op == 0x80)
                    pc + 2 +% @as(u32, @bitCast(@as(i32, @as(i8, @bitCast(image[file + 1])))))
                else
                    pc + 3 +% @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(std.mem.readInt(u16, image[file + 1 ..][0..2], .little))))));
                if (dst < entry or dst - entry >= 768) return false;
            },
            0x5C, 0x6C, 0x7C, 0xDC, 0xFC => return false,
            0x20, 0x22 => {
                if (op == 0x22 and image[file + 3] != 0x00) return false;
                const tgt = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
                if (tgt < 0x8000 or !dbrTransparent(image, cov, tgt, depth - 1)) return false;
            },
            else => {},
        }
        const m8 = fl & usage_map.flag_m != 0;
        const x8 = fl & usage_map.flag_x != 0;
        pc += usage_map.instrLen(op, m8, x8);
    }
    return false;
}

fn wgHelperLen(site: WgSite) u32 {
    if (site.idx != .none) return switch (site.kind) {
        .w8 => 40,
        .w16 => 42,
        .r8 => 48,
        .r16 => 49,
        .ry8, .ry16, .rx8, .rx16 => 49,
        .stz8, .stz16, .c8, .c16, .wx8, .wx16, .wy8, .wy16 => unreachable,
    };
    return switch (site.kind) {
        .w8, .stz8 => 36,
        .w16 => 46,
        .r8 => 39,
        .r16 => 47,
        .stz16 => 43,
        .c8 => 49,
        .c16 => 55,
        .wx8, .wx16, .wy8, .wy16 => 38,
        .ry8, .ry16, .rx8, .rx16 => unreachable, // only collected indexed
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
    if (site.idx != .none) return wgEmitIndexedHelper(d, cur, site);
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
        // CMP against an MMIO register: an r8/r16 read whose result is then
        // compared against the caller's preserved A — N/Z/C land exactly as
        // the original CMP left them, and V (which CMP never touches)
        // survives inside the pushed P.
        .c8 => put(d, cur, &.{
            0x9C, 0x0A, 0x22, // mask
            0x08, // PHP
            0xC2, 0x20, 0x48, // REP / PHA: full C, the request loads clobber it
            0xE2, 0x20, 0xA9,
            lo,   0x8D, 0xF1,
            0x37, 0xA9, hi,
            0x8D, 0xF2, 0x37,
            0xA9, 0x02, 0x8D, 0xF0, 0x37, // filed: r8
            0xAD, 0xF0, 0x37, 0x10, 0xFB, // BPL: wait for the $FE marker
            0xC2, 0x20, 0x68, // A back
            0x28, // PLP: caller flags and widths (m8 by construction)
            0xCD, 0xF3, 0x37, // CMP result: N/Z/C as the original
            0x9C, 0xF0, 0x37, // release (no flags)
            0x08, 0x48, 0xA9, 0x10, 0x8D, 0x0A, 0x22, 0x68, 0x28, // unmask, flags kept
            0x60,
        }),
        .c16 => put(d, cur, &.{
            0x08, // PHP
            0xE2, 0x20, 0x9C, 0x0A, 0x22, // 8-bit: mask
            0xC2, 0x20, 0x48, // REP / PHA
            0xE2, 0x20, 0xA9,
            lo,   0x8D, 0xF1,
            0x37, 0xA9, hi,
            0x8D, 0xF2, 0x37,
            0xA9, 0x04, 0x8D, 0xF0, 0x37, // filed: r16
            0xAD, 0xF0, 0x37, 0x10, 0xFB,
            0xC2, 0x20, 0x68, // A back (16)
            0x28, // PLP (m=16 by construction)
            0xCD, 0xF3, 0x37, // 16-bit CMP
            0x9C, 0xF0, 0x37, // 16-bit release
            0x08, 0x48, 0xE2,
            0x20, 0xA9, 0x10,
            0x8D, 0x0A, 0x22,
            0xC2, 0x20, 0x68,
            0x28, 0x60,
        }),
        .ry8, .ry16, .rx8, .rx16 => unreachable, // only collected indexed
        // STX/STY to MMIO: flag-neutral stores whose width follows X. The
        // value store runs first, at the caller's own index width, before
        // any P munging; the PLP restores every flag exactly as the
        // original left them (STX/STY touch none).
        .wx8, .wx16, .wy8, .wy16 => {
            const st: u8 = if (site.kind == .wx8 or site.kind == .wx16) 0x8E else 0x8C;
            const rk: u8 = if (site.kind == .wx8 or site.kind == .wy8) 0x01 else 0x03;
            put(d, cur, &.{
                0x9C, 0x0A, 0x22, // mask
                0x08, // PHP
                st, 0xF3, 0x37, // value, caller's X width
                0xE2, 0x20, // m8 for the immediates below
                0x48, // PHA (AL; B untouched by anything after)
                0xA9,
                lo,
                0x8D,
                0xF1,
                0x37,
                0xA9,
                hi,
                0x8D,
                0xF2,
                0x37,
                0xA9, rk, 0x8D, 0xF0, 0x37, // filed
                0xAD, 0xF0, 0x37, 0xD0, 0xFB, // until served
                0xA9, 0x10, 0x8D, 0x0A, 0x22, // unmask
                0x68, 0x28, 0x60, // PLA / PLP / RTS
            });
        },
    }
}

/// An indexed MMIO helper: same mailbox, same mask protocol, but the
/// register field is computed at run time — TXA/TYA into a 16-bit A, add
/// the base, file the sum. TXA/TYA read the index in the *caller's* index
/// width (x=1 zero-extends), which is exactly the address arithmetic the
/// original `abs,X`/`abs,Y` performed, so no width case-split is needed.
/// What IS needed is more preservation than the plain helpers: the 16-bit
/// transfer clobbers B, and ADC clobbers C and V, all of which the original
/// store/load left alone — hence the 16-bit PHA and the PLP placed after
/// the arithmetic. An effective address that leaves the MMIO range would be
/// performed verbatim on the S-CPU bus (where low addresses are WRAM the
/// game no longer owns); no shipped game does that from a $21xx/$42xx base,
/// and one that did would fail S4 verification, not ship wrong.
fn wgEmitIndexedHelper(d: []u8, cur: *usize, site: WgSite) void {
    const lo: u8 = @truncate(site.reg);
    const hi: u8 = @truncate(site.reg >> 8);
    const txa: u8 = if (site.idx == .x) 0x8A else 0x98; // TXA / TYA
    switch (site.kind) {
        .w8 => put(d, cur, &.{
            0x9C, 0x0A, 0x22, // STZ CIE: mask
            0x08, // PHP
            0x8D, 0xF3, 0x37, // value (A is the caller's, 8-bit)
            0xC2, 0x20, // REP #$20
            0x48, // PHA: the full C=B:A, which the transfer clobbers
            txa, 0x18, 0x69, lo, hi, // index + base, caller's index width
            0x8D, 0xF1, 0x37, // effective reg
            0xE2, 0x20, // SEP #$20
            0xA9, 0x01, 0x8D, 0xF0, 0x37, // filed: w8
            0xAD, 0xF0, 0x37, 0xD0, 0xFB, // until served
            0xA9, 0x10, 0x8D, 0x0A, 0x22, // unmask
            0xC2, 0x20, 0x68, // REP / PLA: B:A back
            0x28, 0x60, // PLP / RTS
        }),
        .stz8, .stz16, .c8, .c16, .wx8, .wx16, .wy8, .wy16 => unreachable,
        // Loads into an index register (LDY abs,X / LDX abs,Y): the result
        // width is the caller's X width, which conveniently is also the
        // request width. The unmask tail is width-agnostic — PHP right after
        // the load captures its N/Z, SEP pins m for the immediate, and the
        // final PLP restores both the caller's widths and the load's flags.
        .ry8, .ry16, .rx8, .rx16 => {
            const req: u8 = if (site.kind == .ry8 or site.kind == .rx8) 0x02 else 0x04;
            const ld: u8 = if (site.kind == .ry8 or site.kind == .ry16) 0xAC else 0xAE; // LDY/LDX abs
            put(d, cur, &.{
                0x9C, 0x0A, 0x22, // mask
                0x08, // PHP
                0xC2, 0x20, 0x48, // REP / PHA: A survives (the original preserved it)
                txa,  0x18, 0x69, lo,   hi, // effective reg, caller's index width
                0x8D, 0xF1, 0x37, 0xE2, 0x20,
                0xA9, req, 0x8D, 0xF0, 0x37, // filed
                0xAD, 0xF0, 0x37, 0x10, 0xFB, // until the $FE marker
                0xC2, 0x20, 0x68, // A back
                0x28, // PLP: caller widths (X width sizes the load below)
                ld, 0xF3, 0x37, // result -> Y or X, N/Z as the original
                0x9C, 0xF0, 0x37, // release (no flags)
                0x08, 0xE2, 0x20, 0x48, 0xA9, 0x10, 0x8D, 0x0A, 0x22, 0x68, 0x28, // unmask
                0x60,
            });
        },
        .w16 => put(d, cur, &.{
            0x08, 0x48, // PHP / PHA (16-bit)
            0xE2, 0x20, 0x9C, 0x0A, 0x22, // 8-bit: mask
            0xC2, 0x20, // 16-bit again (A untouched by SEP/REP)
            0x8D, 0xF3, 0x37, // 16-bit value
            txa,  0x18, 0x69, lo,   hi, // effective reg
            0x8D, 0xF1, 0x37, 0xE2, 0x20,
            0xA9, 0x03, 0x8D, 0xF0, 0x37, // filed: w16
            0xAD, 0xF0, 0x37, 0xD0, 0xFB,
            0xA9, 0x10, 0x8D, 0x0A, 0x22,
            0xC2, 0x20, 0x68, 0x28, 0x60,
        }),
        .r8 => put(d, cur, &.{
            0x9C, 0x0A, 0x22, // mask
            0x08, // PHP: C and V survive the ADC below
            0xC2, 0x20, 0x48, // REP / PHA: B survives the transfer
            txa,  0x18, 0x69,
            lo,   hi,   0x8D,
            0xF1, 0x37, 0xE2,
            0x20,
            0xA9, 0x02, 0x8D, 0xF0, 0x37, // filed: r8
            0xAD, 0xF0, 0x37, 0x10, 0xFB, // BPL: wait for the $FE marker
            0xC2, 0x20, 0x68, 0xE2, 0x20, // B back (old AL too — about to be replaced)
            0x28, // PLP: caller's flags and widths
            0xAD, 0xF3, 0x37, // result — N/Z now match the original LDA
            0x9C, 0xF0, 0x37, // release the mailbox (no flags)
            0x08, 0x48, 0xA9, 0x10, 0x8D, 0x0A, 0x22, 0x68, 0x28, // unmask, flags kept
            0x60,
        }),
        .r16 => put(d, cur, &.{
            0x08, // PHP
            0xE2, 0x20, 0x9C, 0x0A, 0x22, // 8-bit: mask
            0xC2, 0x20, // A is dead (16-bit load overwrites all of it)
            txa,  0x18,
            0x69, lo,
            hi,   0x8D,
            0xF1, 0x37,
            0xE2, 0x20,
            0xA9, 0x04, 0x8D, 0xF0, 0x37, // filed: r16
            0xAD, 0xF0, 0x37, 0x10, 0xFB,
            0x28, // PLP: caller widths back (m=16 for r16 by construction)
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
    const res = try convert(gpa, rom, &empty, null, &.{}, &.{}, @splat(0), &ref);
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
    try testing.expectError(error.Refused, convert(gpa, rom, &empty, null, &.{}, &.{}, @splat(0), &ref));
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
    const res = try convert(gpa, rom, &plan, usage, &.{}, &.{}, @splat(0), &ref);
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
    const res2 = try convert(gpa, rom, &plan, usage, &.{}, &.{}, @splat(0), &ref);
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
    const res = try convert(gpa, rom, &plan, usage, &.{}, &.{}, @splat(0), &ref);
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
    const res2 = try convert(gpa, rom, &plan, usage, &.{}, &.{}, @splat(0), &ref);
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
    const res = try convert(gpa, rom, &plan, usage, &.{}, &.{}, @splat(0), &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(RegionFate.blocked_abs_to_bwram, res.fate[0]);
    try testing.expectEqual(@as(u32, 0), res.stats.rewritten_long);

    // Long-only access to a BW-RAM region rewrites to $40:xxxx.
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0xEA, 0xEA, 0xEA }); // drop the abs site
    markOp(usage, 0x00_8100);
    const res2 = try convert(gpa, rom, &plan, usage, &.{}, &.{}, @splat(0), &ref);
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
    const res = try convert(gpa, rom, &plan, usage, &.{}, &.{}, @splat(0), &ref);
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
    const res = try convert(gpa, rom, &plan, usage, &.{.{ .entry = 0x00_8020 }}, &.{}, @splat(0), &ref);
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
    const res = try convert(gpa, rom, &plan, usage, &.{ .{ .entry = 0x00_8020 }, .{ .entry = 0x00_8030 } }, &.{}, @splat(0), &ref);
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
    const res = try convert(gpa, rom, &plan, usage, &.{.{ .entry = 0x00_8040, .pages = pages }}, &.{}, @splat(0), &ref);
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

test "residency: private data lives in BW-RAM, is never marshalled, and both CPUs share it" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeRom(gpa);
    defer gpa.free(rom);
    @memset(rom[0xE000..0x10000], 0xFF);

    // Same shape as the marshalling test, with ONE difference that
    // decides residency: nothing outside the routine names the buffer.
    // The caller sets the pointers, calls, and publishes the routine's
    // returned A — it never reads $7E:1Fxx itself, so those pages are
    // private and can move to BW-RAM for good.
    @memcpy(rom[0x0000..0x0024], &[_]u8{
        0x18, 0xFB,
        0xE2, 0x30,
        0x64, 0x00,
        0xA9, 0x90,
        0x85, 0x01,
        0x64, 0x02,
        0x64, 0x03,
        0xA9, 0x1F,
        0x85, 0x04,
        0xA9, 0x7E,
        0x85, 0x05,
        0x22, 0x40, 0x80, 0x00, // JSL $00:8040
        0xEA, 0xEA, 0xEA, 0xEA, // (no read of the buffer)
        0x8F, 0x00, 0x01, 0x7E, // STA $7E:0100 — page $01, not the buffer
        0x80, 0xFE,
    });
    @memcpy(rom[0x0040..0x0052], &[_]u8{
        0x8B,
        0xA9,
        0x7E,
        0x48,
        0xAB,
        0xA0,
        0x00,
        0xB7,
        0x00,
        0x91,
        0x03,
        0xC8,
        0xC0,
        0x04,
        0xD0,
        0xF7,
        0xAB,
        0x6B,
    });
    @memcpy(rom[0x1000..0x1004], &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF });

    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8006, 0x8008, 0x800A, 0x800C, 0x800E, 0x8010, 0x8012, 0x8014, 0x8016, 0x801A, 0x801B, 0x801C, 0x801D, 0x801E, 0x8022 }) |a| markOp(usage, a);
    for ([_]u32{ 0x8040, 0x8041, 0x8043, 0x8044, 0x8045, 0x8047, 0x8049, 0x804B, 0x804C, 0x804E, 0x8050, 0x8051 }) |a| markOp(usage, a);

    var plan = onePlan(0x0F00, 0x10, .iram, 0x80, false);
    var pages: profile.WramPages = @splat(0);
    pages[0] |= 1 << 0; // dp page (stays marshalled — dp is always bank $00)
    pages[0] |= 1 << 0x1F; // the buffer: private, so it becomes resident
    var ref: ?Refusal = null;
    const res = try convert(gpa, rom, &plan, usage, &.{.{ .entry = 0x00_8040, .pages = pages }}, &.{}, @splat(0), &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u8, 1), res.stats.pointer_offloads);
    try testing.expectEqual(@as(u8, 1), res.stats.resident_offloads);
    // Residency rewrote the ORIGINAL body's data bank, not just the copy:
    // that is what makes the S-CPU's own calls address the same bytes.
    try testing.expectEqual(shadow_bank, res.image[0x0042]);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    con.runFrame();
    // One copy, in BW-RAM. WRAM never receives it — there is no marshal
    // to bring it back, and nothing left that would read it there.
    try testing.expectEqualSlices(u8, &.{ 0xDE, 0xAD, 0xBE, 0xEF }, con.bus.sa1.bwram[0x11F00..0x11F04]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, con.bus.wram.data[0x1F00..0x1F04]);
    // The routine still ran and returned: its last loaded byte reached
    // the caller through the register marshal.
    try testing.expectEqual(@as(u8, 0xEF), con.bus.wram.data[0x0100]);
}

test "async: a fire-and-forget resident offload runs, and the fence collects it" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeRom(gpa);
    defer gpa.free(rom);
    @memset(rom[0xE000..0x10000], 0xFF);

    // The residency test's shape, made async-VALID by removing the one
    // thing that broke it on Gradius III: the caller never consumes the
    // routine's result. It sets the pointers, JSLs the routine (whose only
    // effect is writing the resident buffer), and spins. So the SA-1 may
    // run it in the background — the buffer write is the whole point, and
    // nothing reads it back synchronously.
    @memcpy(rom[0x0000..0x0021], &[_]u8{
        0x18, 0xFB, // CLC / XCE
        0xE2, 0x30, // SEP #$30
        0xA9, 0x80, 0x8D, 0x00, 0x42, // LDA #$80 / STA $4200 (NMI on)
        0x64, 0x00, // STZ $00
        0xA9, 0x90, 0x85, 0x01, // ptr lo = $90
        0x64, 0x02, 0x64, 0x03, // ptr hi/bank = 0
        0xA9, 0x1F, 0x85, 0x04, // dest hi = $1F
        0xA9, 0x7E, 0x85, 0x05, // dest bank = $7E (rewritten resident)
        0x22, 0x40, 0x80, 0x00, // JSL $00:8040
        0x80, 0xFE, // BRA * (never reads the buffer)
    });
    @memcpy(rom[0x0040..0x0052], &[_]u8{
        0x8B, 0xA9, 0x7E, 0x48, 0xAB, // PHB / LDA #$7E / PHA / PLB
        0xA0, 0x00, // LDY #0
        0xB7, 0x00, // LDA [$00],Y
        0x91, 0x03, // STA ($03),Y
        0xC8, // INY
        0xC0, 0x04, // CPY #4
        0xD0, 0xF7, // BNE
        0xAB, 0x6B, // PLB / RTL
    });
    @memcpy(rom[0x1000..0x1004], &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF });
    // A real NMI handler (just RTI): the async conversion needs the vector
    // to point at code so its fence prologue can forward to it.
    rom[0x0060] = 0x40; // RTI at $00:8060
    std.mem.writeInt(u16, rom[0x7FEA..][0..2], 0x8060, .little); // native NMI

    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8006, 0x8009, 0x800B, 0x800D, 0x800F, 0x8011, 0x8013, 0x8015, 0x8017, 0x8019, 0x801B, 0x801F }) |a| markOp(usage, a);
    for ([_]u32{ 0x8040, 0x8041, 0x8043, 0x8044, 0x8045, 0x8047, 0x8049, 0x804B, 0x804C, 0x804E, 0x8050, 0x8051 }) |a| markOp(usage, a);
    markOp(usage, 0x8060);

    var plan = onePlan(0x0F00, 0x10, .iram, 0x80, false);
    var pages: profile.WramPages = @splat(0);
    pages[0] |= 1 << 0;
    pages[0] |= 1 << 0x1F;
    var ref: ?Refusal = null;
    // no_async defaults false: the gate must pick async when it qualifies.
    const res = try convert(gpa, rom, &plan, usage, &.{.{ .entry = 0x00_8040, .pages = pages }}, &.{}, @splat(0), &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u24, 0x00_8040), res.stats.async_entry);
    try testing.expect(res.stats.async_fence != 0);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    const sa1_trace = @import("../sa1_trace.zig");
    const trace = try gpa.create(sa1_trace.Trace);
    defer gpa.destroy(trace);
    trace.* = sa1_trace.Trace.init(0x01_F800);
    con.bus.sa1.trace = trace;
    // A few frames: the async stub fires the SA-1 and the S-CPU spins; the
    // NMI fence at each frame boundary drains any in-flight call, so the
    // resident buffer holds the copy — computed on the SA-1, collected by
    // the fence, never marshalled to WRAM.
    for (0..3) |_| con.runFrame();
    try testing.expectEqualSlices(u8, &.{ 0xDE, 0xAD, 0xBE, 0xEF }, con.bus.sa1.bwram[0x11F00..0x11F04]);
    // The SA-1 did the work (the trace watched the body copy execute),
    // and the handshake fully drained: busy idle, both message ports
    // clear — the fence collected the call, nothing is left in flight.
    try testing.expect(trace.total > 0);
    try testing.expectEqual(@as(u8, 0), con.bus.sa1.iram[0x38A]);
    try testing.expectEqual(@as(u4, 0), con.bus.sa1.smeg);
    try testing.expectEqual(@as(u4, 0), con.bus.sa1.cmeg);
}

test "tree offload: a root with a JSL helper, DB-pinned abs, and long-WRAM rewrites round-trips" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeRom(gpa);
    defer gpa.free(rom);
    @memset(rom[0xE000..0x10000], 0xFF);

    // Caller: seed WRAM $1234, JSL the root, spin. The caller's own
    // absolute store also makes page $12 "named outside", so the tree is
    // NOT resident — the marshalled path is what this test exercises.
    @memcpy(rom[0x0000..0x000F], &[_]u8{
        0x18, 0xFB, // CLC / XCE
        0xE2, 0x30, // SEP #$30
        0xA9, 0x77, // LDA #$77
        0x8D, 0x34, 0x12, // STA $1234 (WRAM low mirror, DB=0)
        0x22, 0x40, 0x80, 0x00, // JSL $00:8040
        0x80, 0xFE, // BRA *
    });
    // Root: pin DB=$7E by the idiom, write $1F00 through the pinned
    // bank (an ABSOLUTE store — refused before DB tracking), JSL the
    // helper, restore, RTL.
    @memcpy(rom[0x0040..0x0050], &[_]u8{
        0x8B, // PHB
        0xA9, 0x7E, 0x48, 0xAB, // LDA #$7E / PHA / PLB (pin + rewrite site)
        0xA9, 0x55, // LDA #$55
        0x8D, 0x00, 0x1F, // STA $1F00 (abs under the pin)
        0x22, 0x60, 0x80, 0x00, // JSL $00:8060 — a tree member
        0xAB, // PLB (unpin)
        0x6B, // RTL
    });
    // Helper: long-WRAM read-modify-write through the $00 low mirror —
    // both bank bytes become the shadow bank in the SA-1's copy.
    @memcpy(rom[0x0060..0x006C], &[_]u8{
        0xAF, 0x34, 0x12, 0x00, // LDA $00:1234
        0x18, 0x69, 0x01, // CLC / ADC #$01
        0x8F, 0x35, 0x12, 0x00, // STA $00:1235
        0x6B, // RTL
    });

    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8006, 0x8009, 0x800D }) |a| markOp(usage, a);
    for ([_]u32{ 0x8040, 0x8041, 0x8043, 0x8044, 0x8045, 0x8047, 0x804A, 0x804E, 0x804F }) |a| markOp(usage, a);
    for ([_]u32{ 0x8060, 0x8064, 0x8065, 0x8067, 0x806B }) |a| markOp(usage, a);

    var plan = onePlan(0x0F00, 0x10, .iram, 0x80, false);
    var pages: profile.WramPages = @splat(0);
    pages[0] |= 1 << 0; // dp page
    pages[0] |= 1 << 0x12; // the helper's long-WRAM cells
    pages[0] |= 1 << 0x1F; // the root's pinned-abs target
    var ref: ?Refusal = null;
    const res = try convert(gpa, rom, &plan, usage, &.{.{ .entry = 0x00_8040, .pages = pages }}, &.{}, @splat(0), &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u8, 1), res.stats.pointer_offloads);
    try testing.expectEqual(@as(u8, 0), res.stats.resident_offloads);
    // Both members copied: 16 (root) + 12 (helper).
    try testing.expectEqual(@as(u32, 28), res.stats.offload_copy_len[0]);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    con.runFrame();
    // The root's pinned-abs store and the helper's long RMW both ran on
    // the SA-1 against the shadow and marshalled home.
    try testing.expectEqual(@as(u8, 0x55), con.bus.wram.data[0x1F00]);
    try testing.expectEqual(@as(u8, 0x77), con.bus.wram.data[0x1234]);
    try testing.expectEqual(@as(u8, 0x78), con.bus.wram.data[0x1235]);
}

test "sa1 trace: the SA-1's path through an offloaded body is observable" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");
    const sa1_trace = @import("../sa1_trace.zig");

    // Same cart as the pointer-offload test, re-converted here so the
    // trace watches a body whose expected path is known exactly.
    const rom = try makeRom(gpa);
    defer gpa.free(rom);
    @memset(rom[0xE000..0x10000], 0xFF);
    @memcpy(rom[0x0000..0x0024], &[_]u8{
        0x18, 0xFB,
        0xE2, 0x30,
        0x64, 0x00,
        0xA9, 0x90,
        0x85, 0x01,
        0x64, 0x02,
        0x64, 0x03,
        0xA9, 0x1F,
        0x85, 0x04,
        0xA9, 0x7E,
        0x85, 0x05,
        0x22, 0x40,
        0x80, 0x00,
        0xAF, 0x02,
        0x1F, 0x7E,
        0x8F, 0x00,
        0x01, 0x7E,
        0x80, 0xFE,
    });
    // $8040: PHB / LDA #$7E / PHA / PLB / LDY #0 / loop: LDA [$00],y /
    // STA ($03),y / INY / CPY #4 / BNE loop / PLB / RTL. The BNE at
    // $804e is taken 3 times and falls through once.
    @memcpy(rom[0x0040..0x0052], &[_]u8{
        0x8B,
        0xA9,
        0x7E,
        0x48,
        0xAB,
        0xA0,
        0x00,
        0xB7,
        0x00,
        0x91,
        0x03,
        0xC8,
        0xC0,
        0x04,
        0xD0,
        0xF7,
        0xAB,
        0x6B,
    });
    @memcpy(rom[0x1000..0x1004], &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF });

    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8006, 0x8008, 0x800A, 0x800C, 0x800E, 0x8010, 0x8012, 0x8014, 0x8016, 0x801A, 0x801E, 0x8022 }) |a| markOp(usage, a);
    for ([_]u32{ 0x8040, 0x8041, 0x8043, 0x8044, 0x8045, 0x8047, 0x8049, 0x804B, 0x804C, 0x804E, 0x8050, 0x8051 }) |a| markOp(usage, a);

    var plan = onePlan(0x0F00, 0x10, .iram, 0x80, false);
    var pages: profile.WramPages = @splat(0);
    pages[0] |= 1 << 0;
    pages[0] |= 1 << 0x1F;
    var ref: ?Refusal = null;
    const res = try convert(gpa, rom, &plan, usage, &.{.{ .entry = 0x00_8040, .pages = pages }}, &.{}, @splat(0), &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u8, 1), res.stats.pointer_offloads);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    // Watch the tail of bank $01, where the pointer stub and the body
    // copy are carved (findFreeSpace takes the end of the longest run).
    const trace = try gpa.create(sa1_trace.Trace);
    defer gpa.destroy(trace);
    trace.* = sa1_trace.Trace.init(0x01_F800);
    con.bus.sa1.trace = trace;
    con.runFrame();

    // The SA-1 executed, and the trace saw it — not merely "something
    // ran": the marshalled result proves the same run the offload made.
    try testing.expect(trace.total > 0);
    try testing.expectEqualSlices(u8, &.{ 0xDE, 0xAD, 0xBE, 0xEF }, con.bus.wram.data[0x1F00..0x1F04]);

    // The body copy's own path, read straight out of the coverage: every
    // instruction of the copied routine ran, and the loop's branch ran
    // exactly as many times as the loop iterated.
    var body: ?u24 = null;
    var addr: u24 = 0x01_F800;
    while (addr < 0x01_F800 + sa1_trace.window_cap) : (addr += 1) {
        // The copy starts with the original's PHB opcode ($8B) and is the
        // only $8B in the carve that the SA-1 actually executed.
        const file: u32 = (@as(u32, addr >> 16) * 0x8000) + ((addr & 0xFFFF) - 0x8000);
        if (trace.ran(addr) and res.image[file] == 0x8B) {
            body = addr;
            break;
        }
    }
    const b = body orelse return error.BodyNeverRan;
    // PHB once per call, and the loop's BNE once per iteration (4).
    try testing.expectEqual(@as(u32, 1), trace.countAt(b));
    try testing.expectEqual(@as(u32, 4), trace.countAt(b + 14)); // BNE
    // The RTL closed the call.
    try testing.expect(trace.ran(b + 17));

    // And the register ring carries the state the branch decided on: the
    // last in-window record is a real instruction with plausible state.
    var buf: [sa1_trace.ring_cap]sa1_trace.Rec = undefined;
    const recent = trace.recent(&buf);
    try testing.expect(recent.len > 0);
    try testing.expect(recent[recent.len - 1].pc >= 0x01_F800);
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

test "window: the game keeps running on the S-CPU with its WRAM moved wholesale" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    // The game: dp store (rides the shim's D=$6000), absolute store,
    // INDEXED absolute store (the shape no per-region move can carry and
    // the uniform window's whole reason to exist), a $7E long store, MMIO
    // natively (NMITIMEN), then spin. The NMI handler counts frames
    // through a rewritten absolute — vectors untouched, S-CPU context,
    // pushes landing in the window stack.
    @memcpy(rom[0x0000..0x0021], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, // CLC / XCE / SEP #$30
        0xA9, 0x55, 0x85, 0x20, // STA $20 (dp -> D=$6000 -> BW-RAM $20)
        0xA9, 0x66, 0x8D, 0x00, 0x01, // STA $0100 (abs -> $6100)
        0xA2, 0x05, // LDX #$05
        0xA9, 0x77, 0x9D, 0x00, 0x01, // STA $0100,X (indexed -> $6100,X)
        0xA9, 0x88, 0x8F, 0x34, 0x12, 0x7E, // STA $7E:1234 (long -> $40:1234)
        0xA9, 0x80, 0x8D, 0x00, 0x42, // NMITIMEN: NMI on (native MMIO)
        0x80, 0xFE, // spin
    });
    // NMI handler at $8040: PHA / INC $0040 / PLA / RTI.
    @memcpy(rom[0x0040..0x0046], &[_]u8{ 0x48, 0xEE, 0x40, 0x00, 0x68, 0x40 });
    std.mem.writeInt(u16, rom[0x7FC0 + 0x2A ..][0..2], 0x8040, .little);

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
        try testing.expectEqual(@as(u8, 0x55), con.bus.wram.data[0x0020]);
        try testing.expectEqual(@as(u8, 0x66), con.bus.wram.data[0x0100]);
        try testing.expectEqual(@as(u8, 0x77), con.bus.wram.data[0x0105]);
        try testing.expectEqual(@as(u8, 0x88), con.bus.wram.data[0x1234]);
        try testing.expect(con.bus.wram.data[0x0040] >= frames - 2);
    }

    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, bytes, false, true, &.{}, false, &ref);
    defer gpa.free(res.image);
    // Two plain abs, one indexed abs, one INC in the NMI handler; one long.
    try testing.expect(res.stats.rewritten_abs >= 3);
    try testing.expect(res.stats.rewritten_long >= 1);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    try testing.expectEqual(cartridge.ChipKind.sa1, cart.chip);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    for (0..frames) |_| con.runFrame();
    // Everything landed in BW-RAM at identity offsets — dp through the
    // moved D, plain and INDEXED absolutes through the +$6000 window, the
    // long store through bank $40, and the NMI counter from S-CPU
    // interrupt context through its rewritten INC. WRAM saw none of it.
    try testing.expectEqual(@as(u8, 0x55), con.bus.sa1.bwram[0x0020]);
    try testing.expectEqual(@as(u8, 0x66), con.bus.sa1.bwram[0x0100]);
    try testing.expectEqual(@as(u8, 0x77), con.bus.sa1.bwram[0x0105]);
    try testing.expectEqual(@as(u8, 0x88), con.bus.sa1.bwram[0x1234]);
    try testing.expect(con.bus.sa1.bwram[0x0040] >= frames - 2);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0020]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0100]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0105]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x1234]);
    // The SA-1 never ran: no shim write ever released it, so its message
    // ports never moved — the cart is carried for its RAM.
    try testing.expectEqual(@as(u4, 0), con.bus.sa1.smeg);
    try testing.expectEqual(@as(u4, 0), con.bus.sa1.cmeg);
}

test "window offload: a tree runs on the SA-1 against the shared window, sync and async" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");
    const sa1_trace = @import("../sa1_trace.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    @memset(rom[0x8000..0x10000], 0xFF); // bank 1: the any-bank carve
    // Caller: NMI on, then JSL the tree forever. Tree root stores a
    // marker and JSLs a helper that increments a counter — both through
    // absolute addresses the window rewrite moves to $65xx, which is
    // BW-RAM $05xx for BOTH CPUs.
    @memcpy(rom[0x0000..0x000F], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, // CLC / XCE / SEP #$30
        0xA9, 0x80, 0x8D, 0x00, 0x42, // NMITIMEN: NMI on
        0x22, 0x80, 0x80, 0x00, // JSL $00:8080
        0x80, 0xFA, // BRA back to the JSL
    });
    @memcpy(rom[0x0040..0x0046], &[_]u8{ 0x48, 0xEE, 0x40, 0x00, 0x68, 0x40 }); // NMI: INC $0040
    std.mem.writeInt(u16, rom[0x7FC0 + 0x2A ..][0..2], 0x8040, .little);
    @memcpy(rom[0x0080..0x008A], &[_]u8{
        0xA9, 0x11, 0x8D, 0x00, 0x05, // LDA #$11 / STA $0500
        0x22, 0xA0, 0x80, 0x00, // JSL $00:80A0
        0x6B, // RTL
    });
    @memcpy(rom[0x00A0..0x00A4], &[_]u8{ 0xEE, 0x01, 0x05, 0x6B }); // INC $0501 / RTL

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8006, 0x8009, 0x800D }) |a| markOp(bytes, a);
    for ([_]u32{ 0x8040, 0x8041, 0x8044, 0x8045 }) |a| markOp(bytes, a);
    for ([_]u32{ 0x8080, 0x8082, 0x8085, 0x8089 }) |a| markOp(bytes, a);
    for ([_]u32{ 0x80A0, 0x80A3 }) |a| markOp(bytes, a);

    const cand = [_]Candidate{.{ .entry = 0x00_8080 }};
    for ([_]bool{ false, true }) |go_async| {
        var ref: ?Refusal = null;
        const res = try convertWholeGame(gpa, rom, bytes, false, true, &cand, go_async, &ref);
        defer gpa.free(res.image);
        try testing.expectEqual(@as(u8, 1), res.stats.offload_count);
        try testing.expectEqual(@as(u8, 1), res.stats.resident_offloads);
        if (go_async) {
            try testing.expectEqual(@as(u24, 0x00_8080), res.stats.async_entry);
            try testing.expect(res.stats.async_fence != 0);
        } else {
            try testing.expectEqual(@as(u24, 0), res.stats.async_entry);
        }

        const cart = try cartridge.Cartridge.load(gpa, res.image);
        const con = try gpa.create(console.FastConsole);
        defer {
            con.cart.deinit(gpa);
            gpa.destroy(con);
        }
        con.init(cart);
        // Watch the copy execute on the SA-1.
        const trace = try gpa.create(sa1_trace.Trace);
        defer gpa.destroy(trace);
        const copy24 = res.stats.offload_copy[0];
        trace.* = sa1_trace.Trace.init(copy24);
        con.bus.sa1.trace = trace;
        for (0..5) |_| con.runFrame();
        // The tree's effects land in the shared BW-RAM, computed by the
        // SA-1 (the trace watched the copy), visible untranslated to the
        // S-CPU. Real WRAM saw none of it.
        try testing.expectEqual(@as(u8, 0x11), con.bus.sa1.bwram[0x0500]);
        try testing.expect(con.bus.sa1.bwram[0x0501] > 10);
        try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0500]);
        try testing.expect(con.bus.sa1.bwram[0x0040] >= 3); // NMI counter
        try testing.expect(trace.total > 0);
        // (No port-idle assert: the caller loops hot, so a sampled
        // instant is legitimately mid-handshake.)
    }
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
    const res = try convertWholeGame(gpa, rom, bytes, false, false, &.{}, false, &ref);
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

test "whole-game: a set too big for I-RAM migrates through the BW-RAM window" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    // The same shape as the I-RAM test, but the game's state sits at $0900
    // and $7E:4000 — one beyond I-RAM's 2 KiB, one in a bank that is not on
    // the SA-1's bus at all. Both are ordinary BW-RAM once the window moves
    // them, and the two must land on the SAME byte from either form: $0900
    // absolute and $7E:0900 long are one variable to the game.
    @memcpy(rom[0x0000..0x001C], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, // CLC / XCE / SEP #$30
        0xA9, 0x5A, 0x8D, 0x00, 0x09, // LDA #$5A / STA $0900
        0xAF, 0x00, 0x40, 0x7E, // LDA $7E:4000  (reads the long form)
        0xA9, 0xC3, 0x8F, 0x00, 0x40, 0x7E, // LDA #$C3 / STA $7E:4000
        0xAD, 0x00, 0x09, 0x8F, 0x01, 0x40, 0x7E, // LDA $0900 / STA $7E:4001
        0x80, 0xFE, // spin
    });
    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8006, 0x8009, 0x800D, 0x800F, 0x8013, 0x8016, 0x801A }) |a| markOp(usage, a);
    usage[0x00_0900] = usage_map.flag_write; // beyond I-RAM: selects BW-RAM

    var ref: ?Refusal = null;
    const res = convertWholeGame(gpa, rom, usage, false, false, &.{}, false, &ref) catch |e| {
        std.debug.print("refused: {s}\n", .{ref.?.reason.describe()});
        return e;
    };
    defer gpa.free(res.image);
    try testing.expect(res.stats.d_moved);
    try testing.expect(res.stats.rewritten_abs >= 2);
    try testing.expect(res.stats.rewritten_long >= 3);
    // The operands really moved: $0900 -> $6900, and $7E -> $40.
    try testing.expectEqual(@as(u16, 0x6900), std.mem.readInt(u16, res.image[0x0007..0x0009], .little));
    try testing.expectEqual(@as(u8, 0x40), res.image[0x000C]);
    // BW-RAM, not 32 KiB of it: the window maps all of WRAM.
    try testing.expectEqual(@as(u8, 0x07), res.image[0x7FC0 + 0x18]);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    for (0..8) |_| con.runFrame();

    // State lives in BW-RAM at its own offsets, reached identically by the
    // absolute-window and long-rebanked forms.
    try testing.expectEqual(@as(u8, 0x5A), con.cart.sram[0x0900]);
    try testing.expectEqual(@as(u8, 0xC3), con.cart.sram[0x4000]);
    try testing.expectEqual(@as(u8, 0x5A), con.cart.sram[0x4001]);
    // ...and nothing was left behind in the WRAM the game no longer owns.
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0900]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x4000]);
}

test "whole-game: --wg-static rewrites code the profiled run never reached" {
    const gpa = testing.allocator;
    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    // Covered code: go native 8-bit, load A (Z clear), take a BEQ that
    // dynamically never falls... never branches — the taken side is the
    // covered spin, the NOT-taken side is a block the profiler never saw.
    @memcpy(rom[0x0000..0x000D], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, // CLC / XCE / SEP #$30
        0xA9, 0x5A, // LDA #$5A (Z clear: BEQ never taken)
        0xF0, 0x05, // BEQ $800D — the statically-discovered side
        0x8D, 0x00, 0x09, // STA $0900 (covered; selects the BW-RAM window)
        0x80, 0xFE, // BRA * (covered spin)
    });
    // The uncovered block the static walk must find through the BEQ.
    @memcpy(rom[0x000D..0x0011], &[_]u8{ 0x8D, 0x02, 0x09, 0x60 }); // STA $0902 / RTS
    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8006, 0x8008, 0x800B }) |a| markOp(usage, a);
    usage[0x00_0900] = usage_map.flag_write;

    var ref: ?Refusal = null;
    // Without the static walk the uncovered store keeps its WRAM operand...
    {
        const r = try convertWholeGame(gpa, rom, usage, false, false, &.{}, false, &ref);
        defer gpa.free(r.image);
        try testing.expectEqual(@as(u16, 0x0902), std.mem.readInt(u16, r.image[0x000E..0x0010], .little));
    }
    // ...with it, the operand moves into the window like the covered one.
    {
        const r = try convertWholeGame(gpa, rom, usage, true, false, &.{}, false, &ref);
        defer gpa.free(r.image);
        try testing.expectEqual(@as(u16, 0x6900), std.mem.readInt(u16, r.image[0x0009..0x000B], .little));
        try testing.expectEqual(@as(u16, 0x6902), std.mem.readInt(u16, r.image[0x000E..0x0010], .little));
    }
}

test "whole-game: refusals name their reasons" {
    const gpa = testing.allocator;
    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    var ref: ?Refusal = null;

    // WRAM beyond the I-RAM window — and the reserved mailbox tail inside
    // it — no longer refuse: they select the BW-RAM window instead, which
    // carries all 128 KiB of WRAM. (`wg_wram_beyond_iram` now only reports
    // an operand no window can carry; the beyond-BW-RAM case is below.)
    for ([_]u32{ 0x00_0900, 0x7E_07F4, 0x7F_8000 }) |a| {
        @memset(usage, 0);
        usage[a] = usage_map.flag_write;
        const r = try convertWholeGame(gpa, rom, usage, false, false, &.{}, false, &ref);
        defer gpa.free(r.image);
        try testing.expect(r.stats.d_moved);
    }

    // An executed absolute operand that is neither WRAM, MMIO, nor ROM has
    // no home on the SA-1's bus in either window.
    @memset(usage, 0);
    usage[0x00_0900] = usage_map.flag_write; // select the BW-RAM window
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0xAD, 0x00, 0x44 }); // LDA $4400
    markOp(usage, 0x00_8100);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, false, false, &.{}, false, &ref));
    try testing.expectEqual(Reason.wg_wram_beyond_bwram, ref.?.reason);
    try testing.expectEqual(@as(u32, 0x00_8100), ref.?.detail);

    // D and S must be provable at build time once the window moves them.
    // `PLD` fed by a push of an immediate is fine; fed by anything else is
    // not, and neither is a computed stack pointer.
    @memset(usage, 0);
    usage[0x00_0900] = usage_map.flag_write;
    @memcpy(rom[0x0100..0x0106], &[_]u8{ 0xA2, 0x00, 0x00, 0xDA, 0x2B, 0x60 }); // LDX #0 / PHX / PLD
    markOp(usage, 0x00_8100);
    markOp(usage, 0x00_8103);
    markOp(usage, 0x00_8104);
    usage[0x00_8100] &= ~usage_map.flag_x; // the LDX ran 16-bit
    {
        const r = try convertWholeGame(gpa, rom, usage, false, false, &.{}, false, &ref);
        defer gpa.free(r.image);
        // The immediate moved into the window with everything else.
        try testing.expectEqual(@as(u16, wg_bw_window), std.mem.readInt(u16, r.image[0x0101..0x0103], .little));
    }
    // A bare PLD is the tail of an interrupt epilogue restoring a D that
    // was already shifted when it was pushed: allowed, and left alone.
    rom[0x0103] = 0xEA; // NOP where the push was
    {
        const r = try convertWholeGame(gpa, rom, usage, false, false, &.{}, false, &ref);
        defer gpa.free(r.image);
        try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, r.image[0x0101..0x0103], .little));
    }
    // A TCD fed by something that is not an immediate is a genuine
    // establish this walk cannot follow.
    @memset(usage, 0);
    usage[0x00_0900] = usage_map.flag_write;
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0x7B, 0x5B, 0x60 }); // TDC / TCD
    markOp(usage, 0x00_8100);
    markOp(usage, 0x00_8101);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, false, false, &.{}, false, &ref));
    try testing.expectEqual(Reason.wg_dp_dynamic, ref.?.reason);

    @memset(usage, 0);
    usage[0x00_0900] = usage_map.flag_write;
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0x3B, 0x1B, 0x60 }); // TSC / TCS
    markOp(usage, 0x00_8100);
    markOp(usage, 0x00_8101);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, false, false, &.{}, false, &ref));
    try testing.expectEqual(Reason.wg_stack_dynamic, ref.?.reason);
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0xEA, 0xEA, 0xEA });

    // An executed IRQ handler.
    @memset(usage, 0);
    std.mem.writeInt(u16, rom[0x7FC0 + 0x2E ..][0..2], 0x8100, .little);
    markOp(usage, 0x00_8100);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, false, false, &.{}, false, &ref));
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
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, false, false, &.{}, false, &ref));
    try testing.expectEqual(Reason.wg_nmi_ambiguous, ref.?.reason);
    std.mem.writeInt(u16, rom[0x7FC0 + 0x2A ..][0..2], 0, .little);
    std.mem.writeInt(u16, rom[0x7FC0 + 0x3A ..][0..2], 0, .little);

    // A read-modify-write on MMIO: not proxyable in place. (Plain indexed
    // stores and loads ARE, since the helper computes the effective
    // register at run time — Gradius III's `STA $210D,Y`, `LDY $4218,X`.)
    @memset(usage, 0);
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0x1E, 0x00, 0x21 });
    markOp(usage, 0x00_8100);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, false, false, &.{}, false, &ref));
    try testing.expectEqual(Reason.wg_mmio_shape, ref.?.reason);

    // A long MMIO store: no room for the in-place JSR either.
    @memset(usage, 0);
    @memcpy(rom[0x0100..0x0104], &[_]u8{ 0x8F, 0x00, 0x21, 0x00 });
    markOp(usage, 0x00_8100);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, false, false, &.{}, false, &ref));
    try testing.expectEqual(Reason.wg_mmio_shape, ref.?.reason);

    // An MMIO site executing outside bank $00 (this 64K image's bank $01).
    @memset(usage, 0);
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0xEA, 0xEA, 0xEA });
    markOp(usage, 0x00_8100);
    @memcpy(rom[0xFF00..0xFF03], &[_]u8{ 0x8D, 0x00, 0x21 });
    markOp(usage, 0x01_FF00);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, false, false, &.{}, false, &ref));
    try testing.expectEqual(Reason.wg_mmio_outside_bank0, ref.?.reason);
    @memset(usage, 0);

    // A block move.
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0x54, 0x00, 0x7E });
    markOp(usage, 0x00_8100);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, false, false, &.{}, false, &ref));
    try testing.expectEqual(Reason.wg_unsupported_op, ref.?.reason);
}
