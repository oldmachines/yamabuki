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
    wg_split_overflow,
    wg_thunk_space,

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
            .wg_split_overflow => "more context-split sites (measured under both a system DBR and a WRAM pin) than the thunk table holds",
            .wg_thunk_space => "a bank's padding cannot hold even one JSR stub per MEASURED split-site thunk (the unmeasured ones already share the cold dispatcher's single stub)",
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
    /// Instructions the profile never executed that `--wg-static`'s
    /// recursive descent found anyway — the reach the audit is measuring.
    cov_static_added: u32 = 0,
    /// Non-zero when `--wg-expand` grew the image: the new size in bytes.
    expanded_to: u32 = 0,
    /// Non-zero when EVERY offload was abandoned because the tree copies
    /// needed this many contiguous bytes and no padding run was that big.
    /// A silent zero-offload patch is indistinguishable from a game with
    /// nothing worth offloading; this tells them apart.
    offload_space_short: u32 = 0,
    /// Measured pointer-bank source bytes re-banked (window mode): ROM
    /// bytes proven to feed [dp] pointer bank bytes / DMA bank registers.
    rewritten_ptr_banks: u32 = 0,
    /// Measured dp,X pointer table words rewritten −$6000 (window mode).
    rewritten_idx_words: u32 = 0,
    /// Context-split sites (window mode): absolutes below $2000 whose
    /// measured traffic is BOTH system-DBR (needs the +$6000 shift) and
    /// WRAM-pinned (pin re-banked to $40/$41 — needs the operand
    /// untouched). One operand byte cannot serve both, so each site
    /// becomes a JSR to a DBR-dispatching thunk that runs the original
    /// op with the right operand for the caller it actually has.
    split_sites: u16 = 0,
    /// Of `split_sites`, how many dispatch on the INDEX register instead
    /// of the DBR (tiny-base indexed absolutes, whose home is decided by
    /// magnitude), and how many of the whole population needed a far stub
    /// because their own bank had no room left for a body.
    idx_split_sites: u16 = 0,
    split_far: u16 = 0,
    /// Of `split_sites`, how many are UNMEASURED sites in a bank too full
    /// for per-thunk stubs, routed through the shared cold-site
    /// dispatcher (one 5-byte stub per such bank, however many sites).
    disp_sites: u16 = 0,
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
    /// Covered `STA $4200` sites re-pointed at $378F-mirror thunks for
    /// the nmi-off wrap (0: none usable — a requested wrap was NOT
    /// emitted).
    nmi_off_sites: u8 = 0,
};

/// What the rewriter DID with one memory-touching site, and why.
///
/// Recorded as the decision is made, never re-derived afterwards: an audit
/// that reimplements the rules is an audit that can disagree with them,
/// and the whole value of this is being able to trust the count.
pub const Verdict = enum(u8) {
    /// The operand moved into the BW-RAM window (+$6000).
    shifted,
    /// A long's bank byte re-banked $7E/$7F -> $40/$41 (or the $7D wrap).
    rebanked,
    /// Replaced by a JSR to a thunk dispatching on the runtime data bank.
    thunk_dbr,
    /// Replaced by a JSR to a thunk dispatching on the index magnitude.
    thunk_index,
    /// Operand at or above $2000: MMIO or ROM, and native either way.
    left_high,
    /// A data bank STATICALLY proved to be BW-RAM here, so the operand is
    /// already this bank's own low page. Sound when the tracker is right;
    /// the tracker is the thing being trusted.
    left_pinned,
    /// Measured traffic never touched low WRAM (a ROM walk, MMIO, or
    /// bank-mediated). Leaving it is what the evidence asked for.
    left_rom,
    /// Measured traffic INCLUDES low WRAM but is not only low WRAM, and
    /// the site's shape fits no thunk. Left pointing at the abandoned
    /// home on the paths where the low-WRAM half is the live one — a
    /// hazard with evidence behind it, which makes it the worst kind.
    left_mixed,
    /// No evidence at all, and the shape is not one the static rules
    /// move. Left as written on a guess.
    left_unproven,
};

pub const AuditSite = struct { file: u32, op: u8, v: u16, ev: u8, verdict: Verdict };

/// How many hazard sites the audit will name before it starts counting
/// instead. A list nobody can read is not evidence.
const audit_list_max: usize = 768;

pub const Audit = struct {
    counts: [std.enums.values(Verdict).len]u32 = @splat(0),
    /// The hazard classes only (`left_pinned`, `left_mixed`,
    /// `left_unproven`); everything else is a decision, not a risk.
    sites: [audit_list_max]AuditSite = undefined,
    n_sites: usize = 0,
    /// Hazard sites past the list's end.
    truncated: u32 = 0,
    /// Instructions per bank in the map the REWRITER used — dynamic
    /// coverage plus whatever `--wg-static` reached. A bank at zero here
    /// is a bank the rewriter has never touched an instruction in.
    bank_ops: [0x40]u32 = @splat(0),
    /// Per bank, how many `JSL`/`JML` sites in code the rewriter has seen
    /// name it as a target. A dark bank that nothing ever calls is reached
    /// some other way — or is not code at all.
    bank_calls: [0x40]u32 = @splat(0),
    /// Per bank, how many long DATA accesses (and block-move endpoints) in
    /// seen code name it. Positive evidence that a bank the descent never
    /// entered is a bank of DATA, not unreached code.
    bank_data: [0x40]u32 = @splat(0),
    /// Indirect control transfers in seen code, by shape: `JMP (abs)`,
    /// `JMP (abs,X)` / `JSR (abs,X)`, `JMP [abs]`. Every one of these is a
    /// door the descent cannot open.
    n_ind_abs: u32 = 0,
    n_ind_absx: u32 = 0,
    n_ind_long: u32 = 0,

    pub fn count(self: *const Audit, v: Verdict) u32 {
        return self.counts[@intFromEnum(v)];
    }
};

fn auditNote(a: *Audit, file: u32, op: u8, v: u16, ev: u8, verdict: Verdict) void {
    a.counts[@intFromEnum(verdict)] += 1;
    switch (verdict) {
        .left_pinned, .left_mixed, .left_unproven => {},
        else => return,
    }
    if (a.n_sites == a.sites.len) {
        a.truncated += 1;
        return;
    }
    a.sites[a.n_sites] = .{ .file = file, .op = op, .v = v, .ev = ev, .verdict = verdict };
    a.n_sites += 1;
}

pub const Result = struct {
    image: []u8,
    stats: Stats,
    /// Per-site conversion verdicts (window/whole-game rewrites only).
    audit: Audit = .{},
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
    /// Wrap this tree's sync stub in NMI/IRQ-off across the dispatch
    /// (--wg-nmi-off): the S-CPU spins through the whole copy anyway,
    /// and masking its interrupts makes CONCURRENT MUTATION of the
    /// tree's read-set impossible by construction — the hazard class
    /// that defeated both the vblank guard (timing) and the watchdog
    /// (whose abort re-ran the body inline over the same torn state).
    /// Implies no_async: an async tree runs concurrently by design.
    nmi_off: bool = false,
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
    out[header.offset + 0x16] = 0x34; // SA-1 + RAM, NO battery: BW-RAM is working memory
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

/// The NON-BLOCKING fence, for the NMI prologue. The blocking fence in
/// the NMI moved every in-flight wait into vblank — the one place a
/// wait costs a frame deadline — and the async flavor measured 290
/// dropped frames against sync's 115 doing exactly that. This variant
/// acks a COMPLETED call (the SA-1 answers from its sig-hold loop
/// within microseconds) and SKIPS a still-running one; the next fence
/// point collects it. Only the async stub's own fence must block — it
/// is about to reuse the mailbox.
const nb_fence_len: u32 = 39;
fn emitNbFence(d: []u8) u32 {
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
fn windowEligible(out: []const u8, usage: []const u8, evidence: ?[]const u8, thunks: []const u24, entry: u16) ?WinSpec {
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
const dbg_win_root: u16 = 0;

fn winWalkMember(out: []const u8, usage: []const u8, evidence: ?[]const u8, thunks: []const u24, spec: *WinSpec, mi: usize, judge: bool) bool {
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
const win_guard_len: u32 = 24;
fn emitWinGuard(d: []u8, cur: *usize, entry: u16) void {
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
const win_vblank_margin_lines: u8 = 32;
const win_vblank_guard_len: u32 = 41;
fn emitWinVblankGuard(d: []u8, cur: *usize, entry: u16) void {
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
const win_busy_guard_len: u32 = 30;
fn emitWinBusyGuard(d: []u8, cur: *usize, entry: u16) void {
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
const win_stub_len: u32 = 158 + win_guard_len + win_busy_guard_len + win_vblank_guard_len;
const win_nmi_off_extra: u32 = 27;
/// Covered `STA $4200` sites re-pointed at mirror thunks (bank $00).
const NmiSites = struct { at: [8]u32, n: usize };
const win_nmi_thunk_len: u32 = 8;
fn emitWinStub(d: []u8, id: u8, entry: u16, nmi_off: bool) u32 {
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
const win_async_stub_len: u32 = 111 + win_guard_len + win_busy_guard_len;
fn emitWinAsyncStub(d: []u8, fence: u24, id: u8, entry: u16) u32 {
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
const win_block_len: u32 = 65;
fn emitWinBlock(d: []u8, cur: *usize, id: u8, copy_addr: u16, copy_bank: u8, unm_addr: u16, mar_addr: u16, sig_addr: u16, dp_base: u16) void {
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
const win_watchdog_vcnt: u8 = 200;

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
const win_abort_len: u32 = 58;
fn emitWinAbort(d: []u8, cur: *usize, blocks_lo: u16, blocks_hi1: u16, sig_addr: u16) void {
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

const wg_prologue_len = 21;
/// Window mode's shim: SEI + 3 stores + XCE/REP + D + S + SEP + JMP =
/// 1 + 15 + 4 + 4 + 4 + 2 + 3 = 33; +23 when offloads boot the SA-1
/// (SIWP, CRV lo/hi, async busy init, reset release).
const wg_window_shim_len = 33;
const wg_window_shim_max = 33 + 48;
/// What the shim must program before releasing the SA-1 from reset:
/// its reset vector and — S-CPU-side registers both — its IRQ vector,
/// aimed at the watchdog's abort handler.
const WinBoot = struct { crv: u16, civ: u16 };
/// Bank-0 reservation for the window dispatcher: prologue + message loop
/// + JMP + sig + unm + mar + abort + blocks + NMI prologue + mirror thunks.
const win_disp_max: u32 = 51 + 12 + 3 + 19 + 29 + 24 + offload_max * win_block_len + win_abort_len + nmi_prologue_len + 8 * win_nmi_thunk_len;

/// Context-split thunk: the DBR dispatch plus both flavors of the
/// original 3-byte op (see the emission comment in convertWholeGame).
const split_thunk_len: u32 = 24;
/// Index-split thunk: the DBR test, the X-width test, the magnitude
/// compare, and both flavors of the original 3-byte op — A-PRESERVING, so
/// every op class (stores included) can be thunked, not just LDA shapes.
const idx_thunk_len: u32 = 35;
/// The same thunk WITHOUT the data-bank test, for a site whose measured
/// evidence already rules a BW-RAM pin out. The test costs ~17 cycles on
/// every call and these sites are hot — Gradius III's five measured
/// split sites are its level-script walker, and paying for a question
/// their evidence has already answered moved the whole timeline far
/// enough to flip the behavioural verdict on a build that shipped.
const idx_thunk_short_len: u32 = 27;
/// Sites one conversion can thunk (Gradius III measures ~100).
const split_thunk_max: usize = 192;
/// Index-split sites one conversion can thunk. Far larger than the DBR
/// flavor: with `--wg-static` every tiny-base indexed absolute in code the
/// profile never reached is thunked on principle, because no evidence
/// exists to prove which home it walks.
const idx_thunk_max: usize = 2048;

/// A bank-local padding allocator for the thunk populations.
///
/// `findFreeSpace` hands out the tail of the ONE largest run, which is the
/// right shape for a single scaffold and the wrong one for a population:
/// Gradius III's bank $00 carries its slack in several runs, and demanding
/// 2 KiB in a single stretch for 62 thunks refused a conversion that fits
/// comfortably across four. This walks every run in turn, and it skips the
/// scaffold's carve by ADDRESS instead of by painting over it — the paint
/// trick relied on the carve's run staying shorter than its neighbours,
/// which is not a property anyone maintains.
///
/// $FF ONLY, unlike `findFreeSpace`: a long run of $00 is as often a real
/// table of zeros as it is slack, and this allocator takes MANY small runs
/// across MANY banks rather than one obvious tail, so it meets the
/// ambiguous ones. Measured: a run of $00 in bank $0E was graphics data,
/// and thunks written into it rendered pictures the original never showed.
const PadAlloc = struct {
    region: []const u8,
    /// File offset of `region[0]`.
    base: u32,
    /// Reserved span (file offsets); empty when lo == hi.
    lo: u32 = 0,
    hi: u32 = 0,
    scan: usize = 0,
    cur: u32 = 0,
    end: u32 = 0,

    /// The same 8-byte cushion `findFreeSpace` keeps between real bytes
    /// and whatever it hands out.
    const margin = 8;

    /// Rewind the scan. Safe because everything already handed out has
    /// been WRITTEN by then, so a fresh pass reads it as occupied — which
    /// is what lets a caller that failed to fit a 35-byte body come back
    /// and ask for a 5-byte stub instead.
    fn rewind(self: *@This()) void {
        self.scan = 0;
        self.cur = 0;
        self.end = 0;
    }

    /// Padding still on offer, net of the per-run margin. Used to decide
    /// bodies-or-stubs BEFORE placing anything: a bank that cannot hold
    /// every body should hold no body at all, because a half-filled bank
    /// leaves the tail thunks without even their 5-byte stub.
    fn freeBytes(self: *const @This()) u32 {
        var total: u32 = 0;
        var i: usize = 0;
        while (i < self.region.len) {
            if (self.region[i] != 0xFF) {
                i += 1;
                continue;
            }
            var j = i + 1;
            while (j < self.region.len and self.region[j] == 0xFF) j += 1;
            var s = self.base + @as(u32, @intCast(i));
            var e = self.base + @as(u32, @intCast(j));
            i = j;
            if (self.hi > self.lo and s < self.hi and e > self.lo) {
                const left = if (self.lo > s) self.lo - s else 0;
                const right = if (e > self.hi) e - self.hi else 0;
                if (left >= right) e = s + left else s = e - right;
            }
            if (e > s + margin) total += e - s - margin;
        }
        return total;
    }

    /// How many 5-byte far stubs the bank could hold if it held nothing
    /// else. `freeBytes` cannot answer this: it nets one margin per run,
    /// while `next` charges the margin only on OPENING a run and then
    /// packs to its end — for a population of uniform 5-byte stubs the
    /// per-run arithmetic here is exact.
    fn stubCapacity(self: *const @This()) u32 {
        var total: u32 = 0;
        var i: usize = 0;
        while (i < self.region.len) {
            if (self.region[i] != 0xFF) {
                i += 1;
                continue;
            }
            var j = i + 1;
            while (j < self.region.len and self.region[j] == 0xFF) j += 1;
            var s = self.base + @as(u32, @intCast(i));
            var e = self.base + @as(u32, @intCast(j));
            i = j;
            if (self.hi > self.lo and s < self.hi and e > self.lo) {
                const left = if (self.lo > s) self.lo - s else 0;
                const right = if (e > self.hi) e - self.hi else 0;
                if (left >= right) e = s + left else s = e - right;
            }
            if (e > s + margin) total += (e - s - margin) / far_stub_len;
        }
        return total;
    }

    fn next(self: *@This(), need: u32) ?u32 {
        if (self.cur + need <= self.end) {
            defer self.cur += need;
            return self.cur;
        }
        while (self.scan < self.region.len) {
            if (self.region[self.scan] != 0xFF) {
                self.scan += 1;
                continue;
            }
            var j = self.scan + 1;
            while (j < self.region.len and self.region[j] == 0xFF) j += 1;
            var s = self.base + @as(u32, @intCast(self.scan));
            var e = self.base + @as(u32, @intCast(j));
            self.scan = j;
            // Clipped against the reservation, keeping the larger half.
            if (self.hi > self.lo and s < self.hi and e > self.lo) {
                const left = if (self.lo > s) self.lo - s else 0;
                const right = if (e > self.hi) e - self.hi else 0;
                if (left >= right) e = s + left else s = e - right;
            }
            if (e >= s + need + margin) {
                self.cur = s + margin;
                self.end = e;
                defer self.cur += need;
                return self.cur;
            }
        }
        return null;
    }
};

/// A `PadAlloc` over one bank of `out`, honouring a reserved span given as
/// (offset, length) in FILE offsets. Bank $00 stops at the header, where
/// the scaffold's carve is the thing reserved; other banks are their whole
/// 32 KiB, where the reservation is the tail of the biggest run kept back
/// for offload tree copies. Passing the reservation and then ignoring it
/// for every bank but $00 is how the thunks quietly wrote 395 bytes into
/// that tail and lost the trees anyway.
fn padAllocFor(out: []const u8, header_off: u32, bank: u32, res_at: u32, res_len: u32) PadAlloc {
    if (bank == 0) return .{
        .region = out[0..header_off],
        .base = 0,
        .lo = res_at,
        .hi = res_at + res_len,
    };
    const lo = bank * 0x8000;
    return .{
        .region = out[lo..@min(lo + 0x8000, out.len)],
        .base = lo,
        .lo = res_at,
        .hi = res_at + res_len,
    };
}

/// A padding allocator for thunk BODIES that will not fit their own bank;
/// the site's bank keeps only the 5-byte stub.
///
/// It walks banks DOWNWARD from the top, and that direction is load-
/// bearing twice over. Bank $00 is excluded because it is the bank under
/// pressure and spending less of it is the whole point — but the low banks
/// generally are: they hold the code, so they hold the sites, so they are
/// the ones that still need their own stubs. Measured: filling upward from
/// bank $01 emptied bank $02's padding on bank $00's behalf and then had
/// nowhere to put bank $02's own stubs.
const FarPad = struct {
    out: []const u8,
    header_off: u32,
    /// 0 until the first call; the top bank thereafter.
    bank: u32 = 0,
    pad: ?PadAlloc = null,
    /// Reserved span (file offsets) inside `keep_bank`: the TAIL of the
    /// image's biggest padding run, kept for the offload tree copies.
    ///
    /// The copies need ONE contiguous block and cannot be split, while a
    /// thunk body fits anywhere — so when they compete, the thunks must
    /// yield. Measured: they did not, making the physics tree eligible
    /// pushed the copies' demand past what was left, EVERY offload was
    /// silently abandoned, and the patch shipped 186 dropped frames where
    /// it had been doing 116. Reserving the whole BANK was worse still:
    /// the far pool then ate banks $01-$04, which need their padding for
    /// their own 5-byte stubs. The tail is the right unit — it is where
    /// `findFreeSpace` allocates from, so thunks filling the head of the
    /// same run cost the copies nothing.
    keep_bank: u32 = 0,
    keep_lo: u32 = 0,
    keep_hi: u32 = 0,

    fn next(self: *@This(), need: u32) ?u32 {
        if (self.bank == 0) self.bank = @intCast((self.out.len + 0x7FFF) / 0x8000 - 1);
        while (self.bank >= 1) {
            if (self.pad == null) self.pad = if (self.bank == self.keep_bank)
                padAllocFor(self.out, self.header_off, self.bank, self.keep_lo, self.keep_hi - self.keep_lo)
            else
                padAllocFor(self.out, self.header_off, self.bank, 0, 0);
            if (self.pad.?.next(need)) |at| return at;
            self.pad = null;
            self.bank -= 1;
        }
        if (dbg_thunk_pad)
            std.debug.print("[farpad] EXHAUSTED for {} bytes\n", .{need});
        return null;
    }
};

/// How much of the biggest padding run to keep back for offload tree
/// copies. Gradius III's two trees are 397 and 1324 bytes plus their
/// stubs and fence — a shade over 2 KB — and 2.5 KiB leaves headroom
/// without starving the thunk bodies, which have the rest of the image.
pub const copy_reserve: u32 = 2560;

/// The single biggest $FF run outside bank $00 — the one `findFreeSpace`
/// will hand the offload tree copies, and whose tail `FarPad` keeps back
/// for them. Returns its bank and its END file offset (exclusive).
const BigRun = struct { bank: u32 = 0, end: u32 = 0, len: u32 = 0 };
fn biggestRun(out: []const u8, header_off: u32) BigRun {
    var best: BigRun = .{};
    var bank: u32 = 1;
    while (bank * 0x8000 < out.len and bank < 0x40) : (bank += 1) {
        const lo = bank * 0x8000;
        const region = out[lo..@min(lo + 0x8000, out.len)];
        var i: usize = 0;
        while (i < region.len) {
            if (region[i] != 0xFF) {
                i += 1;
                continue;
            }
            var j = i + 1;
            while (j < region.len and region[j] == 0xFF) j += 1;
            const len: u32 = @intCast(j - i);
            if (len > best.len) best = .{ .bank = bank, .end = @intCast(lo + j), .len = len };
            i = j;
        }
        _ = header_off;
    }
    return best;
}

/// Bank-local stub for a thunk body that had to go to another bank:
/// `JSL far / RTS`. The body ends in RTL instead of RTS, so the pair
/// returns to the site exactly as an in-bank thunk would, and the two
/// pushes the body indexes off the stack ($02,S) sit at the same depth
/// either way. Five bytes of the pressured bank instead of thirty-five.
const far_stub_len: u32 = 5;

/// Place one thunk body for a site and return the address its `JSR` should
/// name. Prefers the site's own bank; falls back to the stub-plus-far-body
/// shape. `near` and `far_body` are the same template with RTS/RTL tails.
fn placeThunk(out: []u8, local: *PadAlloc, far: *FarPad, near: []const u8, far_body: []const u8, force_far: bool, n_far: *u16) ?u16 {
    if (!force_far) {
        if (local.next(@intCast(near.len))) |at| {
            @memcpy(out[at..][0..near.len], near);
            return @intCast(0x8000 + (at % 0x8000));
        }
        local.rewind();
    }
    n_far.* += 1;
    const stub = local.next(far_stub_len) orelse return null;
    const body = far.next(@intCast(far_body.len)) orelse return null;
    @memcpy(out[body..][0..far_body.len], far_body);
    out[stub] = 0x22; // JSL
    std.mem.writeInt(u16, out[stub + 1 ..][0..2], @as(u16, @intCast(0x8000 + (body % 0x8000))), .little);
    out[stub + 3] = @intCast(body / 0x8000);
    out[stub + 4] = 0x60; // RTS
    return @intCast(0x8000 + (stub % 0x8000));
}

/// The cold-site dispatcher: ONE shared far-stub per pressured bank,
/// however many unmeasured split sites the bank carries.
///
/// The per-thunk far stub already cut a body's bank cost from ~35 bytes
/// to 5, and Gradius III still refused: bank $02 keeps its entire slack
/// in one 149-byte run, and the population that needs stubs there is the
/// UNMEASURED one — tiny-base indexed sites the profile never reached —
/// which grows with every cover movie harvested. Five bytes per site is
/// a ceiling coverage itself walks into.
///
/// So the unmeasured sites of a bank that cannot afford per-thunk stubs
/// all `JSR` to one shared `JSL dispatcher / RTS` stub, and the
/// dispatcher works out which site called by the return address the JSR
/// itself pushed: binary search over a sorted (site -> body) table, then
/// a jump into the same RTL-tailed body a per-thunk far stub would have
/// named. The body cannot tell the difference — it sees the identical
/// [3-byte JSL frame][2-byte JSR return] stack — so every thunk template
/// is reused unchanged, flags set by the body's op included (RTS/RTL do
/// not touch P).
///
/// The search runs with interrupts live and no memory scratch: state
/// lives on the stack, the jump target is written into a 3-byte hole
/// reserved BELOW the saved registers, and an `RTL` consumes it after
/// the registers are restored — reentrant against any NMI, including one
/// that dispatches through this same code.
///
/// The price is ~150 cycles per call, paid only by sites that never
/// executed once across every profiled surface.
const cold_disp_len: u32 = 106;
fn coldDispatcherBody(table: u24, n_records: u16) [cold_disp_len]u8 {
    const t0 = table;
    const t2 = table + 2;
    const t4 = table + 4;
    const t6 = table + 6;
    const end: u16 = n_records * 8;
    // Stack during the search, from S: $01-$02 key (the site's address),
    // $03-$04 hi, $05-$06 saved Y, $07-$08 X, $09-$0A A, $0B P,
    // $0C-$0E the RTL hole, $0F-$11 the stub's JSL frame (PBR at $11 is
    // the SITE's bank), $12-$13 the site's JSR return address.
    return .{
        0x4B, 0x4B, 0x4B, // PHK x3 — the RTL target's hole
        0x08, // PHP
        0xC2, 0x30, // REP #$30
        0x48, 0xDA, 0x5A, // PHA / PHX / PHY
        0xF4, 0x00, 0x00, // PEA 0 — hi
        0xF4, 0x00, 0x00, // PEA 0 — key
        0xA3, 0x12, // LDA $12,S — the JSR pushed site+2
        0x3A, 0x3A, // DEC A x2 — the site itself
        0x83, 0x01, // STA $01,S
        0xA9, @truncate(end), @truncate(end >> 8), // LDA #records*8
        0x83, 0x03, // STA $03,S — hi (exclusive)
        0xA0, 0x00, 0x00, // LDY #0 — lo
        // loop (29): mid = ((lo + hi) / 2) floored to a record
        0x98, 0x18, 0x63, 0x03, // TYA / CLC / ADC $03,S
        0x4A, // LSR
        0x29, 0xF8, 0xFF, // AND #$FFF8
        0xAA, // TAX
        0xA3, 0x01, // LDA $01,S — key
        0xDF, @truncate(t0), @truncate(t0 >> 8), @truncate(t0 >> 16), // CMP table,X — record.addr16
        0xF0, 0x0F, // BEQ bank_cmp (61)
        0x90, 0x08, // BCC go_left (56)
        // right (48): lo = mid + 8
        0x8A, 0x18, 0x69, 0x08, 0x00, 0xA8, // TXA / CLC / ADC #8 / TAY
        0x80, 0xE5, // BRA loop
        // go_left (56): hi = mid
        0x8A, 0x83, 0x03, // TXA / STA $03,S
        0x80, 0xE0, // BRA loop
        // bank_cmp (61): addr16 matched; order by bank on ties
        0xE2, 0x20, // SEP #$20
        0xA3, 0x11, // LDA $11,S — the site's PBR
        0x29, 0x7F, // AND #$7F — fast mirrors fold onto the file bank
        0xDF, @truncate(t2), @truncate(t2 >> 8), @truncate(t2 >> 16), // CMP table+2,X — record.bank
        0xC2, 0x20, // REP #$20 — Z and C survive the width change
        0xF0, 0x04, // BEQ found (79)
        0x90, 0xEB, // BCC go_left
        0x80, 0xE1, // BRA right
        // found (79): body-1 into the hole, drop scratch, restore, RTL
        0xBF, @truncate(t4), @truncate(t4 >> 8), @truncate(t4 >> 16), // LDA table+4,X
        0x83, 0x0C, // STA $0C,S — hole PC
        0xE2, 0x20, // SEP #$20
        0xBF, @truncate(t6), @truncate(t6 >> 8), @truncate(t6 >> 16), // LDA table+6,X
        0x83, 0x0E, // STA $0E,S — hole PBR
        0xC2, 0x20, // REP #$20
        0x3B, 0x18, 0x69, 0x04, 0x00, 0x1B, // TSC / CLC / ADC #4 / TCS — drop hi+key
        0x7A, 0xFA, 0x68, 0x28, // PLY / PLX / PLA / PLP
        0x6B, // RTL — into the body; JSL frame and JSR return intact
    };
}

/// The DBR-dispatch thunk body (see the emission comment in
/// convertWholeGame). `ret` is RTS in-bank, RTL behind a far stub.
fn splitThunkBody(op: u8, v: u16, ret: u8) [split_thunk_len]u8 {
    const sh: u16 = v + wg_bw_window;
    return .{
        0x08, 0xE2, 0x20, 0x48, 0x8B, 0x68, // PHP/SEP#$20/PHA/PHB/PLA
        0x30, 0x0A, 0x89, 0x40,        0xF0,             0x06, // BMI sys / BIT #$40 / BEQ sys
        0x68, 0x28, op,   @truncate(v), @truncate(v >> 8), ret,
        0x68, 0x28, op,   @truncate(sh), @truncate(sh >> 8), ret,
    };
}

/// The LONG,X index-dispatch thunk: 29 bytes, always entered by `JSL` and
/// always leaving by `RTL`, so it needs no bank-local home.
///
/// No DBR test — a long access names its bank in the operand, so the only
/// question is the index, and the answer is the same two-way split the
/// absolute flavor makes: an index small enough to stay under $2000 is
/// addressing the low mirror (which moved), anything bigger is walking ROM
/// through the same bytes (which did not). The x8 arm short-circuits for
/// the same reason it does there: an 8-bit index over a tiny base cannot
/// leave the low page, and a 16-bit CPX immediate would misparse anyway.
///
///   PHP / SEP #$20 / PHA / LDA $02,S / BIT #$10 / BNE low
///   CPX #($2000-v) / BCS rom
///   low: PLA / PLP / op b:v+$6000,X / RTL
///   rom: PLA / PLP / op b:v,X       / RTL
const long_thunk_len: u32 = 29;
fn longThunkBody(op: u8, v: u16, bank: u8) [long_thunk_len]u8 {
    const sh: u16 = v + wg_bw_window;
    const lim: u16 = 0x2000 - v;
    return .{
        0x08, 0xE2, 0x20, 0x48, // PHP / SEP #$20 / PHA
        0xA3, 0x02, 0x89, 0x10, 0xD0, 0x05, // LDA $02,S / BIT #$10 / BNE low
        0xE0, @truncate(lim),      @truncate(lim >> 8), 0xB0, 0x07, // CPX #lim / BCS rom
        0x68, 0x28, op, @truncate(sh),  @truncate(sh >> 8),  bank, 0x6B, // low
        0x68, 0x28, op, @truncate(v),   @truncate(v >> 8),   bank, 0x6B, // rom
    };
}

/// The ORIGINAL index-split thunk, kept verbatim for exactly the sites it
/// already served: an LDA shape whose measured evidence is low|rom. Those
/// five sites in Gradius III are the level-script walker, they are hot,
/// and they are on a path that SHIPS — so they get the body that shipped,
/// to the cycle. A is scratch here, which is why only LDA qualifies: the
/// load overwrites it, and an 8-bit scratch leaves the B accumulator
/// alone. Generalising this template — even to something strictly more
/// correct — changed the timeline enough to fail a build that passed.
const idx_thunk_v2_len: u32 = 24;
fn idxThunkBodyV2(op: u8, v: u16, ret: u8) [idx_thunk_v2_len]u8 {
    const sh: u16 = v + wg_bw_window;
    const lim: u16 = 0x2000 - v;
    const cp: u8 = if (usage_map.mode(op) == .abs_y) 0xC0 else 0xE0;
    return .{
        0x08, 0xE2, 0x20, 0xA3, 0x01, 0x89, 0x10, 0xD0, 0x05, // PHP/SEP/LDA $01,S/BIT #$10/BNE low
        cp,   @truncate(lim),       @truncate(lim >> 8), 0xB0, 0x05, // CPY #lim / BCS rom
        0x28, op, @truncate(sh),  @truncate(sh >> 8),  ret, // low: PLP / op v+$6000
        0x28, op, @truncate(v),   @truncate(v >> 8),   ret, // rom: PLP / op v
    };
}

/// The NEGATIVE-BASE `long,X` thunk. `LDA $02:FFFF,X` reaches the byte
/// BEFORE a bank boundary when X is small, wrapping forward into the next
/// bank's low page — `$02:FFFF` + 7 is `$03:0006`, which is relocated WRAM
/// on the S-CPU and the SA-1's OWN I-RAM inside an offloaded copy. The
/// slot walker uses the idiom on the boss's node-insertion path, which is
/// why the stage-1 boss rendered as garbage: the tree read I-RAM for its
/// chain links. Every net missed it, because all three tested `v < $2000`
/// and $FFFF is not — the thunk rule, the window shift, and the
/// eligibility walk's hazard check, which is how the tree was admitted.
///
/// Two compares, because the low mirror is a RANGE here rather than a
/// ceiling: X below `$10000 - v` has not wrapped yet and is still reading
/// this bank's ROM tail; X that far plus $2000 or more has passed the
/// mirror. Only between them is the address the one that moved.
///
/// No A scratch: the dispatch reads X only. `REP #$10` makes the
/// immediates parse and X read whole whatever width the caller had —
/// setting the X flag zeroes XH, so an x8 caller's index has the same
/// numeric value either way — and PLP puts the caller's width back before
/// the op, which runs last so the exit flags are its own.
///
///   PHP / REP #$10
///   CPX #($10000-v) / BCC rom      ; not wrapped: ROM tail
///   CPX #($10000-v+$2000) / BCS rom ; past the mirror
///   low: PLP / op (b+1):(v+$6000) / RTL
///   rom: PLP / op b:v              / RTL
const long_neg_thunk_len: u32 = 25;
fn longNegThunkBody(op: u8, v: u16, bank: u8) [long_neg_thunk_len]u8 {
    const lo: u16 = @intCast(0x10000 - @as(u32, v)); // wrap threshold
    const hi: u16 = lo +% 0x2000;
    // EA' = EA + $6000: the +$6000 always carries out of a base >= $FF00,
    // so the bank advances and the operand keeps the same distance.
    const sh: u16 = v +% wg_bw_window;
    const sb: u8 = bank +% 1;
    return .{
        0x08, 0xC2, 0x10, // PHP / REP #$10
        0xE0, @truncate(lo),      @truncate(lo >> 8), 0x90, 0x0B, // CPX #lo / BCC rom
        0xE0, @truncate(hi),      @truncate(hi >> 8), 0xB0, 0x06, // CPX #hi / BCS rom
        0x28, op, @truncate(sh),  @truncate(sh >> 8), sb,   0x6B, // low: the window
        0x28, op, @truncate(v),   @truncate(v >> 8),  bank, 0x6B, // rom: as written
    };
}

/// The index-dispatch thunk for a site MEASURED never to run under a
/// BW-RAM pin: the data-bank arm is dropped and only the index is asked
/// about. Same A-preserving shape, eight bytes and ~17 cycles cheaper.
///
///   PHP / SEP #$20 / PHA / LDA $02,S / BIT #$10 / BNE low
///   CPY #($2000-v) / BCS rom
///   low: PLA / PLP / op v+$6000 / RTS
///   rom: PLA / PLP / op v / RTS
fn idxThunkBodyShort(op: u8, v: u16, ret: u8) [idx_thunk_short_len]u8 {
    const sh: u16 = v + wg_bw_window;
    const lim: u16 = 0x2000 - v;
    const cp: u8 = if (usage_map.mode(op) == .abs_y) 0xC0 else 0xE0;
    return .{
        0x08, 0xE2, 0x20, 0x48, // PHP / SEP #$20 / PHA
        0xA3, 0x02, 0x89, 0x10, 0xD0, 0x05, // LDA $02,S / BIT #$10 / BNE low
        cp,   @truncate(lim),       @truncate(lim >> 8), 0xB0, 0x06, // CPY #lim / BCS rom
        0x68, 0x28, op, @truncate(sh), @truncate(sh >> 8), ret, // low: the window
        0x68, 0x28, op, @truncate(v),  @truncate(v >> 8),  ret, // rom: as written
    };
}

/// The index-dispatch thunk body (see the emission comment in
/// convertWholeGame). `ret` is RTS in-bank, RTL behind a far stub.
fn idxThunkBody(op: u8, v: u16, ret: u8) [idx_thunk_len]u8 {
    const sh: u16 = v + wg_bw_window;
    const lim: u16 = 0x2000 - v;
    const cp: u8 = if (usage_map.mode(op) == .abs_y) 0xC0 else 0xE0;
    return .{
        0x08, 0xE2, 0x20, 0x48, 0x8B, 0x68, // PHP/SEP#$20/PHA/PHB/PLA
        0x30, 0x04, 0x89, 0x40, 0xD0, 0x11, // BMI sys / BIT #$40 / BNE rom
        0xA3, 0x02, 0x89, 0x10, 0xD0, 0x05, // sys: LDA $02,S / BIT #$10 / BNE low
        cp,   @truncate(lim),        @truncate(lim >> 8), 0xB0, 0x06, // CPY #lim / BCS rom
        0x68, 0x28, op, @truncate(sh), @truncate(sh >> 8), ret, // low: the window
        0x68, 0x28, op, @truncate(v),  @truncate(v >> 8),  ret, // rom: as written
    };
}

/// Diagnostics: report each bank's thunk demand against its padding.
const dbg_thunk_pad = false;

const WinChosen = struct { entry: u16, spec: WinSpec, is_async: bool, nmi_off: bool };

/// Choose and emit window offloads onto the REWRITTEN image. The
/// dispatcher (CRV is 16-bit) and the NMI prologue (a 16-bit vector)
/// live in the bank-0 carve after the shim; stubs, copies, and the fence
/// are long-addressed and carve from any bank's padding. Returns the CRV
/// and CIV for the shim to program, or null when nothing offloaded.
/// (CIV because $2207/8 is an S-CPU-SIDE register — the SA-1's own
/// stores to it fall on deaf ports, measured as a frame-0 wedge when the
/// prologue tried: the first timer IRQ vectored through CIV=0 into
/// I-RAM garbage.)
fn emitWindowOffloads(
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
    /// Per-site effective-address evidence (`usage_map.site_*` bits per
    /// instruction address), when a profiled run recorded it. Decides the
    /// statically undecidable idioms by measurement: a base-$0000 indexed
    /// absolute whose observed traffic was all ROM stays put; one whose
    /// traffic was all low WRAM shifts into the window.
    site_evidence: ?[]const u8,
    /// Value provenance (window mode): ROM bytes a profiled run PROVED to
    /// feed addressing state that operand rewrites cannot reach. Two
    /// families: `proven` — [dp] pointer bank bytes / DMA A-bus bank
    /// registers carrying $7E/$7F (re-banked −$3E so value-mediated
    /// traffic lands in BW-RAM with everything else; measured: the stage
    /// loader's bank-$01 table, whose tear blanked every gameplay sprite);
    /// `idx_proven` — X-register table words carrying full dp,X pointers
    /// beyond the moved low 8 KiB (rewritten −$6000 so the relocated
    /// D=$6000 wraps back onto the original target; measured: the HDMA
    /// channel builder's $43x0 register words, whose +$6000 drift silently
    /// voided channel-7 setup and phase-shifted the APU pump into the
    /// gameplay RNG fork).
    ptr_ev: ?*const usage_map.PtrBankEvidence,
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
    /// `--wg-expand`: grow the output image to this many bytes, filling the
    /// new space with $FF. Zero keeps the image its original size.
    ///
    /// A conversion spends ROM it does not have: tree copies need one
    /// CONTIGUOUS block, thunk bodies need runs in the site's own bank, and
    /// the boot shim needs a few dozen bytes of bank $00. Gradius III ships
    /// 6704 bytes of padding in all of 512 KiB, so the three compete and the
    /// loser is silently dropped — measured: a 3410-byte tree set against a
    /// 3907-byte run left the far pool too thin for a 35-byte shim, and the
    /// conversion refused outright. SA-1 carts are routinely larger than
    /// their originals for exactly this reason. Doubling the image hands
    /// banks $10-$1F over as one unbroken run and the competition ends.
    ///
    /// The size must stay a LoROM-mappable power of two: the SA-1's MMC maps
    /// in 1 MiB regions and `rom_mask` is `padded_len - 1`, so anything else
    /// folds the new space back onto the old.
    win_expand_to: u32,
    /// How many bytes at the tail of the image's biggest padding run to keep
    /// back for the offload tree copies. `copy_reserve` is the default; a
    /// bigger candidate set needs a bigger reserve, and getting this wrong
    /// does not shrink the conversion — it abandons EVERY offload, because
    /// the copies need one contiguous block and the thunks have already
    /// eaten the run (measured: a 3410-byte set against a 3907-byte run
    /// reserved at 2560 shipped no offloads at all).
    win_copy_reserve: u32,
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
    // Reach, for the audit: instructions the profile never ran that the
    // recursive descent found anyway.
    const cov_added: u32 = if (static_walk)
        usage_map.countOpcodes(cov) - usage_map.countOpcodes(usage)
    else
        0;
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
    var carve_len: u32 = 0; // what the carve reserves, for the thunk allocator
    var split = false;
    // Split mode: where each helper landed (file offset), first-fit across
    // every bank's largest padding run — helpers are self-contained and the
    // trampolines carry 24-bit targets, so they need not even share a bank.
    var helper_at: [wg_uniq_max]u32 = undefined;
    if (patchgen.findFreeSpace(image[0..header.offset], scaffold + helper_len)) |c| {
        carve = c;
        carve_len = scaffold + helper_len;
    } else {
        split = true;
        const b0_need = scaffold + 4 * @as(u32, @intCast(n_uniq)) + 1;
        carve = patchgen.findFreeSpace(image[0..header.offset], b0_need) orelse
            return refuse(refusal, .{ .reason = .no_free_space, .detail = b0_need });
        carve_len = b0_need;
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

    const out = blk: {
        if (win_expand_to <= image.len) break :blk try gpa.dupe(u8, image);
        const grown = try gpa.alloc(u8, win_expand_to);
        @memcpy(grown[0..image.len], image);
        // $FF, because that is the only byte `PadAlloc` and `biggestRun`
        // recognise as free.
        @memset(grown[image.len..], 0xFF);
        // The header must agree with the file, or the loader masks the new
        // banks straight back onto the old ones.
        grown[header.offset + 0x17] = @intCast(std.math.log2_int(u32, win_expand_to / 1024));
        break :blk grown;
    };
    errdefer gpa.free(out);
    var res: Result = .{ .image = out, .stats = .{}, .fate = @splat(.not_attempted) };
    res.stats.cov_static_added = cov_added;
    res.stats.expanded_to = if (win_expand_to > image.len) win_expand_to else 0;
    {
        var ab: u32 = 0;
        while (ab < 0x40 and ab * 0x8000 < out.len) : (ab += 1) {
            var aa: u32 = 0x8000;
            while (aa < 0x10000) : (aa += 1) {
                const ac = (ab << 16) | aa;
                if ((cov[ac] | cov[0x80_0000 | ac]) & usage_map.flag_opcode == 0) continue;
                res.audit.bank_ops[ab] += 1;
                const af = ab * 0x8000 + (aa - 0x8000);
                switch (out[af]) {
                    0x22, 0x5C => if (af + 3 < out.len) {
                        const tb: u32 = out[af + 3] & 0x7F;
                        if (tb < 0x40) res.audit.bank_calls[tb] += 1;
                    },
                    0x6C => res.audit.n_ind_abs += 1,
                    0x7C, 0xFC => res.audit.n_ind_absx += 1,
                    0xDC => res.audit.n_ind_long += 1,
                    0x44, 0x54 => if (af + 2 < out.len) { // MVN/MVP: dst, src
                        for ([2]u8{ out[af + 1], out[af + 2] }) |mb|
                            if ((mb & 0x7F) < 0x40) {
                                res.audit.bank_data[mb & 0x7F] += 1;
                            };
                    },
                    else => switch (usage_map.mode(out[af])) {
                        .long, .long_x => if (af + 3 < out.len) {
                            const db: u32 = out[af + 3] & 0x7F;
                            if (db < 0x40) res.audit.bank_data[db] += 1;
                        },
                        else => {},
                    },
                }
            }
        }
    }
    res.stats.static_skipped = static_skipped;

    // Re-bank $7E long sites into the identity window (bank $7E does not
    // exist on the SA-1 bus; bank $00's low $0800 is the same I-RAM).
    bank = 0;
    // Context-split sites collected for thunking (see Stats.split_sites);
    // patched after the pass, once the bank-0 carve is paintable.
    var thunks: [split_thunk_max]struct { file: u32, v: u16, op: u8 } = undefined;
    var n_thunks: usize = 0;
    // Index-split sites (tiny base, measured low|rom or NOT MEASURED AT
    // ALL): dispatched on the index register's magnitude instead of the DBR.
    // Index-split sites in LONG,X form. Separate because the site is four
    // bytes (a `JSL`, not a `JSR`) and the body's operand carries a bank.
    var lthunks: [idx_thunk_max]struct { file: u32, v: u16, op: u8, bank: u8 } = undefined;
    var n_lthunks: usize = 0;
    // `pin`: the site has NO evidence, so a caller pinned to $40/$41 is
    // still possible and the thunk must test the data bank. A site whose
    // measurement already excludes the pin takes the short body.
    var ithunks: [idx_thunk_max]struct { file: u32, v: u16, op: u8, pin: bool } = undefined;
    var n_ithunks: usize = 0;
    // CELL COHERENCE (window mode): per-site evidence decisions can split
    // one cell's accessor population — gameplay evidence shifted a sound
    // cell's readers while its pinned writers stayed, and the two homes
    // diverged at the title-music handoff. The invariant is per CELL, not
    // per site: collect, for every unindexed absolute operand below
    // $2000, the union of its sites' evidence classes plus whether any
    // site reaches it under a re-banked WRAM pin. A pinned accessor is
    // STUCK at the BW-RAM home (its unshifted operand under DBR $40/$41
    // is bwram[v]), so a {low, bank} cell's home is forced there and the
    // unpinned sites SHIFT to follow, whatever their own class mix.
    var cell_ev: [0x2000]u8 = @splat(0);
    var cell_pinned: [0x2000]bool = @splat(false);
    if (bwram and window) {
        var pbank: u32 = 0;
        while (pbank < 0x40) : (pbank += 1) {
            const pbf = pbank * 0x8000;
            if (pbf >= out.len) break;
            var pa: u32 = 0x8000;
            var p_dbr_bw = false;
            while (pa < 0x10000) : (pa += 1) {
                const pca = (pbank << 16) | pa;
                if ((cov[pca] | cov[0x80_0000 | pca]) & usage_map.flag_opcode == 0) continue;
                const pf = pbf + (pa - 0x8000);
                const pop = out[pf];
                if (usage_map.mode(pop) == .abs) {
                    const pv = std.mem.readInt(u16, out[pf + 1 ..][0..2], .little);
                    if (pv < 0x2000) {
                        if (p_dbr_bw) {
                            cell_pinned[pv] = true;
                        } else {
                            const pe: u8 = if (site_evidence) |s| s[pca] | s[0x80_0000 | pca] else 0;
                            cell_ev[pv] |= pe;
                        }
                    }
                }
                if (!dbrSurvives(out, cov, pf, pop)) p_dbr_bw = false;
                if (pop == 0xAB) {
                    p_dbr_bw = pf >= 3 and out[pf - 3] == 0xA9 and out[pf - 1] == 0x48 and
                        (out[pf - 2] == 0x7E or out[pf - 2] == 0x7F);
                } else if (pop == 0x44 or pop == 0x54) {
                    const d0 = out[pf + 1];
                    p_dbr_bw = d0 == 0x7E or d0 == 0x7F or (d0 == 0x00 and for (bm[0..n_bm]) |f| {
                        if (f == pf) break true;
                    } else false);
                }
            }
        }
    }
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
                    const le: u8 = if (site_evidence) |s| s[cpu_addr] | s[0x80_0000 | cpu_addr] else 0;
                    if (bwram) {
                        // $7E/$7F are not on the SA-1's bus; $40/$41 are the
                        // same bytes of BW-RAM, at the same offsets — and
                        // identity-offset, so an index carries over.
                        if (b == 0x7E or b == 0x7F) {
                            out[file + 3] = b - 0x3E;
                            res.stats.rewritten_long += 1;
                            auditNote(&res.audit, file, op, v, le, .rebanked);
                        } else if (b == 0x7D and v >= 0xFF00) {
                            // The NEGATIVE-OFFSET idiom: `SBC $7D:FFFB,X`
                            // wraps through the bank boundary into
                            // $7E:0000+X-5 — entry-relative backward reach
                            // into a WRAM queue (the title's DMA queue
                            // reads its previous entry this way). $3F
                            // wraps into $40 the same distance.
                            out[file + 3] = 0x3F;
                            res.stats.rewritten_long += 1;
                            auditNote(&res.audit, file, op, v, le, .rebanked);
                        } else if ((b & 0x7F) <= 0x3F and v < 0x2000 and
                            (usage_map.mode(op) == .long or blk: {
                                // Indexed long through a system bank is
                                // undecidable statically (`LDA $01:0000,X`
                                // with a big X walks a ROM table; the same
                                // shape with a small X walks the mirror) —
                                // measured evidence decides: shift only a
                                // site whose observed traffic was all low
                                // WRAM. Unindexed is WRAM for certain.
                                const e: u8 = if (site_evidence) |s| s[cpu_addr] | s[0x80_0000 | cpu_addr] else 0;
                                break :blk e != 0 and e == usage_map.site_wram_low;
                            }))
                        {
                            std.mem.writeInt(u16, out[file + 1 ..][0..2], v + wg_bw_window, .little);
                            res.stats.rewritten_long += 1;
                            auditNote(&res.audit, file, op, v, le, .shifted);
                        } else if (window and usage_map.mode(op) == .long_x and
                            (b & 0x7F) <= 0x3F and (v < 0x100 or v >= 0xFF00))
                        {
                            // NO evidence test. Reaching here already means
                            // the site is not provably pure-low (that case
                            // shifted statically above), and every other
                            // reading of the evidence has now been wrong at
                            // least once. `$00:911D` and `$00:9155` measured
                            // ROM-ONLY across five surfaces and two cover
                            // harvests, were left alone on that authority,
                            // and read the mirror on the boss path — inside
                            // an offloaded copy, where the mirror is the
                            // SA-1's own I-RAM. Evidence that never saw the
                            // mirror is not proof there is no mirror, and
                            // the thunk is correct in BOTH worlds, so it is
                            // the answer whenever the shape is ambiguous.
                            // The index-split class in the addressing mode
                            // the absolute thunk cannot reach. Same idiom,
                            // same ambiguity — `LDA $03:0000,X` is the slot
                            // walker's chain-follow with a small X and a ROM
                            // table walk with a big one — but the site is
                            // FOUR bytes, so `JSL` fits where `JSR` did not,
                            // and a long call names its own bank: these
                            // thunks need no bank-local home at all.
                            //
                            // MEASURED low|rom SITES INCLUDED, and the
                            // history of that decision is worth keeping.
                            // These were excluded once, because thunking
                            // the walker's three reads at $00:90AE-C4 puts
                            // a JSL/RTL — some thirty cycles — in the
                            // hottest loop the game has, and doing so
                            // "broke" the behavioural verdict. It did not:
                            // that failure was the tier calling a faster
                            // conversion hung, and the evidence for the
                            // exclusion evaporated with the tier fix.
                            //
                            // Including them is what makes the PHYSICS TREE
                            // eligible. `$00:90AE` is the single line the
                            // eligibility walk refuses $8EF1 over — an
                            // unshifted low-mirror indexed long is the
                            // SA-1's own I-RAM — and the thunk removes the
                            // hazard by construction: its window arm is the
                            // identity window (same bytes on both buses)
                            // and its as-written arm only runs when the
                            // index has already carried the address past
                            // $2000. Thirty cycles at three sites against a
                            // tree worth 48% utilisation down to ~17% is
                            // not a close trade.
                            //
                            // Only the index is in question here. A long
                            // access carries its bank in the operand, so DBR
                            // is not consulted and the three worlds collapse
                            // to two: small index -> the window (mirrored in
                            // every system bank), huge index -> as written.
                            if (n_lthunks == idx_thunk_max)
                                return refuse(refusal, .{ .reason = .wg_split_overflow, .detail = cpu_addr });
                            lthunks[n_lthunks] = .{ .file = file, .v = v, .op = op, .bank = b };
                            n_lthunks += 1;
                            auditNote(&res.audit, file, op, v, le, .thunk_index);
                        } else if ((b & 0x7F) <= 0x3F and (v < 0x2000 or
                            (usage_map.mode(op) == .long_x and v >= 0xFF00)))
                        {
                            // An indexed long through a system bank whose
                            // evidence did not clear it, in a shape the
                            // thunk does not serve (a base too big to be the
                            // pointer idiom): the mirror and a ROM table
                            // share it, and nothing here decides between
                            // them.
                            auditNote(&res.audit, file, op, v, le, if (le == 0)
                                .left_unproven
                            else if (le & usage_map.site_wram_low != 0)
                                .left_mixed
                            else
                                .left_rom);
                        } else {
                            auditNote(&res.audit, file, op, v, le, .left_high);
                        }
                    } else if (b == 0x7E and v < 0x800) {
                        out[file + 3] = 0x00;
                        res.stats.rewritten_long += 1;
                    }
                },
                .abs, .abs_x, .abs_y => if (bwram and dbr_bw) {
                    // Skipped because the data bank is provably BW-RAM
                    // here. Audited rather than silent: the pin comes from
                    // a static tracker, and a wrong pin leaves a live site
                    // addressing the abandoned home.
                    const v = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                    const pe: u8 = if (site_evidence) |s| s[cpu_addr] | s[0x80_0000 | cpu_addr] else 0;
                    auditNote(&res.audit, file, op, v, pe, if (v < 0x2000) .left_pinned else .left_high);
                } else if (bwram) {
                    const v = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                    // Measured evidence first: a site whose observed data
                    // traffic was ALL low-WRAM shifts; a site that ever
                    // reached ROM, MMIO, or bank $7E/$7F (DBR-mediated —
                    // it follows the re-banked idiom) stays. Only sites
                    // with no recorded traffic fall back to the static
                    // heuristic: a TINY base under an index is the "X is
                    // the pointer" idiom (the title's display-list walker
                    // reads $01:8000+X via `LDY $0000,X`) and stays; real
                    // table bases shift.
                    const e: u8 = if (site_evidence) |s| s[cpu_addr] | s[0x80_0000 | cpu_addr] else 0;
                    // A CONTEXT-SPLIT single site: THIS instruction was
                    // measured under both a system DBR and a WRAM pin, so
                    // no single operand serves its two callers and no
                    // per-cell home argument applies either — the site
                    // becomes a JSR to a DBR-dispatching thunk.
                    // NOTE, measured 2026-08-17: widening this to any
                    // evidence NAMING the bank (`bank` alone as well as
                    // `low|bank`) is the obvious generalisation and it
                    // breaks the offload trees. Sites measured only under a
                    // pin are exactly what a pinned tree is full of, and a
                    // JSR thunk is not portable into a tree COPY — the copy
                    // runs in another bank, where the bank-relative JSR
                    // lands on garbage, so the eligibility walk refuses the
                    // tree outright. The `long,X` flavor escapes this
                    // because JSL names its own bank; this one needs
                    // copy-local thunk emission first.
                    if (window and v < 0x2000 and
                        e == usage_map.site_wram_low | usage_map.site_wram_bank)
                    {
                        if (n_thunks == split_thunk_max)
                            return refuse(refusal, .{ .reason = .wg_split_overflow, .detail = cpu_addr });
                        thunks[n_thunks] = .{ .file = file, .v = v, .op = op };
                        n_thunks += 1;
                        auditNote(&res.audit, file, op, v, e, .thunk_dbr);
                        continue;
                    }
                    // A site SPLIT ON ITS INDEX: a tiny-base indexed abs
                    // measured reading BOTH the WRAM-low mirror (small
                    // index — the operand really is a data base) and ROM
                    // (huge index — "X is the pointer"). One operand
                    // cannot serve both (measured: Gradius III's level-
                    // script walker `LDA $0003,Y` reads spawn records at
                    // dp offsets AND walks ROM through the same bytes —
                    // left unshifted, every stage-1 enemy wave silently
                    // failed to spawn: transient content diverges in runs
                    // shorter than the persistence budget, so the tier
                    // never saw it). The site becomes a JSR to a thunk
                    // that dispatches on the index register's magnitude.
                    // LDA shapes only: the thunk scratches A, which the
                    // load overwrites anyway. The recorded x-width is NOT
                    // trusted (last-run only); the thunk dispatches on
                    // the caller's live X flag.
                    //
                    // UNMEASURED sites take the thunk too, and that is the
                    // point of it. A tiny-base indexed absolute the profile
                    // never reached used to be left in place on the "X is
                    // the pointer" hunch — which is right for a ROM walk and
                    // WRONG for a data base, and the wrong half writes into
                    // the WRAM the window abandoned, silently. Measured on
                    // the real cart: `STA $0030,Y` at $02:8C8B stored the
                    // laser's collision record to dead memory, so the beam
                    // passed through everything it hit. The thunk decides at
                    // run time and is right in both worlds; the price is a
                    // JSR/RTS per access. `--wg-static` is what puts those
                    // sites in coverage in the first place.
                    const im = usage_map.mode(op);
                    if (window and v < 0x100 and (im == .abs_x or im == .abs_y) and
                        (e == 0 or e == usage_map.site_wram_low | usage_map.site_rom))
                    {
                        if (n_ithunks == idx_thunk_max)
                            return refuse(refusal, .{ .reason = .wg_split_overflow, .detail = cpu_addr });
                        ithunks[n_ithunks] = .{ .file = file, .v = v, .op = op, .pin = e == 0 };
                        n_ithunks += 1;
                        auditNote(&res.audit, file, op, v, e, .thunk_index);
                        continue;
                    }
                    // Cell coherence (unindexed, single-context site): a
                    // {low, bank} CELL's home is BW-RAM — its pinned
                    // accessors are stuck there — so this unpinned site
                    // shifts to follow even when its own measured class
                    // says "stay" (distinct sites carried the two
                    // classes; the collection pass above unioned them).
                    const cell_move = window and usage_map.mode(op) == .abs and v < 0x2000 and blk: {
                        const ce = cell_ev[v] | e;
                        const has_low = ce & usage_map.site_wram_low != 0;
                        const has_bank = ce & usage_map.site_wram_bank != 0 or cell_pinned[v];
                        const has_other = ce & (usage_map.site_rom | usage_map.site_other) != 0;
                        break :blk !has_other and has_low and has_bank;
                    };
                    const shift_it = cell_move or if (e != 0)
                        e == usage_map.site_wram_low
                    else
                        usage_map.mode(op) == .abs or v >= 0x100;
                    if (v >= 0x2000) {
                        auditNote(&res.audit, file, op, v, e, .left_high);
                    } else if (!shift_it) {
                        auditNote(&res.audit, file, op, v, e, if (e == 0)
                            .left_unproven
                        else if (e & usage_map.site_wram_low != 0)
                            .left_mixed
                        else
                            .left_rom);
                    } else {
                        std.mem.writeInt(u16, out[file + 1 ..][0..2], v + wg_bw_window, .little);
                        res.stats.rewritten_abs += 1;
                        auditNote(&res.audit, file, op, v, e, .shifted);
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
    // The dispatch macro `STA $00 / JMP ($0000)` — BY SIGNATURE, coverage
    // or not. GIII stamps this five-byte idiom ~140 times across three
    // banks and the coverage-gated pointer-shift rule reaches only the
    // few dozen the profiled surfaces execute; every uncovered sibling is
    // a landmine (measured twice on the full-cycle tail: the first
    // uncovered site read its pointer from dead real WRAM and BRK-stormed
    // at f4640; with that one fixed by a coverage pad, the NEXT one
    // halted the S-CPU on an STP inside ROM data at ~f6500 — post-fork
    // trajectories visit sites no finite stock profile can lead). The
    // signature is specific enough that a data collision is negligible,
    // and a covered site is naturally skipped: its operand is already
    // $6000, which no longer matches.
    if (bwram) {
        var f: u32 = 0;
        while (f + 5 <= out.len) : (f += 1) {
            if (out[f] == 0x85 and out[f + 1] == 0x00 and out[f + 2] == 0x6C and
                out[f + 3] == 0x00 and out[f + 4] == 0x00)
            {
                std.mem.writeInt(u16, out[f + 3 ..][0..2], wg_bw_window, .little);
                res.stats.rewritten_abs += 1;
            }
        }
    }
    // Measured pointer-bank sources: table bytes (and immediate operands
    // the shape pass above didn't already reach) that carry $7E/$7F into
    // runtime pointers. The byte may sit anywhere in ROM; the proof it is
    // a bank byte is dynamic, so the only static check left is that it
    // still holds $7E/$7F (the shape pass may have re-banked it first).
    if (bwram) if (ptr_ev) |pe| {
        for (pe.proven[0..pe.n_proven]) |ca| {
            const src_bank: u32 = (ca >> 16) & 0x7F;
            const a16: u32 = ca & 0xFFFF;
            if (a16 < 0x8000) continue;
            const f = src_bank * 0x8000 + (a16 - 0x8000);
            if (f >= out.len) continue;
            if (out[f] == 0x7E or out[f] == 0x7F) {
                out[f] -= 0x3E;
                res.stats.rewritten_ptr_banks += 1;
            }
        }
        // dp,X pointer words: the recorded address names the word's LAST
        // byte. Only a word still naming something beyond the moved low
        // 8 KiB is rewritten — the window offset pre-subtracted, so the
        // relocated direct page wraps back onto the original target.
        for (pe.idx_proven[0..pe.n_idx]) |ca| {
            const src_bank: u32 = (ca >> 16) & 0x7F;
            const a16: u32 = ca & 0xFFFF;
            if (a16 < 0x8001) continue;
            const f = src_bank * 0x8000 + (a16 - 0x8000);
            if (f >= out.len or f == 0) continue;
            const word = std.mem.readInt(u16, out[f - 1 ..][0..2], .little);
            if (word >= 0x2000) {
                std.mem.writeInt(u16, out[f - 1 ..][0..2], word -% wg_bw_window, .little);
                res.stats.rewritten_idx_words += 1;
            }
        }
    };
    // D and S follow their memory into the window.
    for (moves[0..n_moves]) |off| {
        const imm = std.mem.readInt(u16, out[off..][0..2], .little);
        std.mem.writeInt(u16, out[off..][0..2], imm + wg_bw_window, .little);
        res.stats.dp_sites += 1;
    }
    res.stats.d_moved = bwram;

    // Context-split thunks: each collected site becomes `JSR thunk`, and
    // the thunk dispatches on the RUNTIME data bank — the one fact the
    // static rewrite could not know. The template restores the caller's
    // exact flags immediately before the original op, so every op class
    // (loads, stores, RMW, carry-consuming ADC/SBC, flag-transparent
    // stores inside a CMP/branch pair) behaves byte-for-byte as in situ:
    //
    //   PHP / SEP #$20 / PHA / PHB / PLA   ; A.lo = DBR, entry flags saved
    //   BMI sys / BIT #$40 / BEQ sys       ; bit7 clear + bit6 set = $40/$41
    //   PLA / PLP / op v         / RTS     ; pinned caller: operand as-is
    //   sys: PLA / PLP / op v+$6000 / RTS  ; system caller: the window
    //
    // JSR is bank-relative, so a site's thunk is carved in the site's own
    // bank — from ANY of that bank's padding runs (see PadAlloc), with the
    // scaffold's carve reserved by address, and behind a 5-byte far stub
    // once that bank runs dry (see placeThunk).
    var pad: PadAlloc = undefined;
    const big: BigRun = if (window) biggestRun(out, header.offset) else .{};
    const keep: u32 = @min(win_copy_reserve, big.len -| PadAlloc.margin);
    var far: FarPad = .{
        .out = out,
        .header_off = header.offset,
        .keep_bank = big.bank,
        .keep_lo = big.end - keep,
        .keep_hi = big.end,
    };
    if (dbg_thunk_pad and window)
        std.debug.print("[farpad] biggest run: bank {x:0>2}, {} bytes, reserving {} for tree copies\n", .{ big.bank, big.len, keep });
    // Index-split thunks: dispatch on the index register's magnitude.
    // WIDTH-PROOF: the site's recorded width is only the LAST run's — a
    // caller can arrive in x8, where a 16-bit CPY immediate misparses
    // (the $20 of #$2000 executes as JSR — measured: the laser's shot
    // path derailed inside the v1 thunk and built a degenerate
    // full-screen beam that never collided). The caller's pushed X flag
    // is tested first: an 8-bit index over a tiny base can only reach
    // the low mirror, so x8 callers take the window path unconditionally
    // and only x16 callers run the compare.
    //
    // A is SAVED across the scratch load — the same PHA-under-SEP trick
    // the DBR thunk uses, which pushes one byte whatever the caller's M
    // was and pulls it back under the restored M. That is what lets
    // STORES be thunked: the v1 template scratched A and so could only
    // serve LDA shapes, and every `STA $00xx,Y` in unmeasured code was
    // left pointing at abandoned WRAM. The compare runs under saved
    // flags (CPY clobbers carry, which a load must leave untouched); the
    // op runs LAST so the exit flags are its own.
    //
    // The DBR is tested FIRST, because the operand only shifts for a
    // caller whose data bank is a system bank. Three worlds share one
    // site and the unshifted operand serves two of them: a caller pinned
    // to $40/$41 means the tiny base is that bank's own low page (the
    // in-tree hazard shape — an uncovered site the root's pin makes
    // safe), and a system-bank caller with a huge index is walking ROM.
    // Only system bank + small index is the abandoned-WRAM case, and
    // only that one moves into the window.
    //
    //   PHP / SEP #$20 / PHA / PHB / PLA
    //   BMI sys / BIT #$40 / BNE rom          ; $40-$7F: pinned, as-is
    //   sys: LDA $02,S / BIT #$10 / BNE low   ; x8 index cannot leave the page
    //   CPY #($2000-v) / BCS rom
    //   low: PLA / PLP / op v+$6000 / RTS
    //   rom: PLA / PLP / op v / RTS
    // BOTH families are placed in ONE pass, merged in file order, and
    // identical sites SHARE a body: `LDA $0000,Y` appears twenty-odd times
    // in a bank and one thunk serves them all. Sharing is what brings a
    // bank with 141 bytes of padding and 29 sites inside its budget — the
    // per-site cost drops from 35 bytes to 3 (the JSR is the site).
    const Th = struct {
        file: u32,
        v: u16,
        op: u8,
        idx: bool,
        pin: bool,
        /// Which of the three index bodies this site takes (see each one).
        fn v2(self: @This()) bool {
            return self.idx and !self.pin and (self.op == 0xB9 or self.op == 0xBD);
        }
        fn len(self: @This()) u32 {
            if (!self.idx) return split_thunk_len;
            if (self.pin) return idx_thunk_len;
            return if (self.v2()) idx_thunk_v2_len else idx_thunk_short_len;
        }
    };
    var all: [split_thunk_max + idx_thunk_max]Th = undefined;
    var n_all: usize = 0;
    {
        var a: usize = 0;
        var b: usize = 0;
        while (a < n_thunks or b < n_ithunks) : (n_all += 1) {
            if (b == n_ithunks or (a < n_thunks and thunks[a].file < ithunks[b].file)) {
                all[n_all] = .{ .file = thunks[a].file, .v = thunks[a].v, .op = thunks[a].op, .idx = false, .pin = false };
                a += 1;
            } else {
                all[n_all] = .{ .file = ithunks[b].file, .v = ithunks[b].v, .op = ithunks[b].op, .idx = true, .pin = ithunks[b].pin };
                b += 1;
            }
        }
    }
    var seen: [split_thunk_max + idx_thunk_max]struct { v: u16, op: u8, idx: bool, pin: bool, addr: u16 } = undefined;
    // Cold-site dispatcher state (see coldDispatcherBody): sites routed
    // through a bank's shared stub, their far bodies (dedup'd ACROSS
    // banks — the dispatcher jumps long, so one RTL-tailed body serves
    // every bank), and each pressured bank's one stub to backpatch.
    var cold_sites: [idx_thunk_max]struct { site: u24, body: u24 } = undefined;
    var n_cold: usize = 0;
    var cold_bodies: [idx_thunk_max]struct { v: u16, op: u8, at: u24 } = undefined;
    var n_cold_bodies: usize = 0;
    var cold_stubs: [0x40]u32 = undefined;
    var n_cold_stubs: usize = 0;
    if (window and n_all != 0) {
        var i: usize = 0;
        while (i < n_all) {
            const tbank: u32 = all[i].file / 0x8000;
            var j = i;
            while (j < n_all and all[j].file / 0x8000 == tbank) j += 1;
            pad = padAllocFor(out, header.offset, tbank, carve, carve_len);
            // Bodies or stubs, decided per bank BEFORE anything is
            // written: a bank that cannot hold every DISTINCT body should
            // hold none, because filling it with the first arrivals
            // leaves the rest without even their 5-byte stub. That is how
            // bank $00 — 1.5 KiB of slack against a 2 KiB scaffold —
            // refused a conversion that fits comfortably.
            var need: u32 = 0;
            var n_dist: u32 = 0;
            var n_dist_hot: u32 = 0;
            var n_seen: usize = 0;
            for (all[i..j]) |t| {
                var dup = false;
                for (seen[0..n_seen]) |s| {
                    if (s.v == t.v and s.op == t.op and s.idx == t.idx and s.pin == t.pin) dup = true;
                }
                if (dup) continue;
                seen[n_seen] = .{ .v = t.v, .op = t.op, .idx = t.idx, .pin = t.pin, .addr = 0 };
                n_seen += 1;
                need += t.len() + PadAlloc.margin;
                n_dist += 1;
                if (!(t.idx and t.pin)) n_dist_hot += 1;
            }
            // Three tiers, decided per bank BEFORE anything is written:
            // bodies when they all fit; a far stub per thunk when at
            // least those do; and when even one stub per thunk exceeds
            // the bank, the MEASURED thunks keep their stubs and every
            // unmeasured one shares the cold dispatcher's single stub —
            // the population that grows with coverage is exactly the one
            // that stops costing bank bytes.
            const cap = pad.stubCapacity();
            const tier: enum { bodies, stubs, shared } =
                if (pad.freeBytes() >= need) .bodies
                else if (cap >= n_dist) .stubs
                else if (cap >= n_dist_hot + 1) .shared
                else return refuse(refusal, .{ .reason = .wg_thunk_space, .detail = tbank });
            const ff = tier != .bodies;
            if (dbg_thunk_pad)
                std.debug.print("[thunkpad] bank {x:0>2}: {} site(s), {} distinct ({} hot), need {} free {} cap {} tier {s}\n", .{ tbank, j - i, n_dist, n_dist_hot, need, pad.freeBytes(), cap, @tagName(tier) });
            var bank_stub: u32 = 0; // this bank's shared cold stub, once
            n_seen = 0;
            while (i < j) : (i += 1) {
                const t = all[i];
                if (tier == .shared and t.idx and t.pin) {
                    var body: u24 = 0;
                    for (cold_bodies[0..n_cold_bodies]) |cb| {
                        if (cb.v == t.v and cb.op == t.op) body = cb.at;
                    }
                    if (body == 0) {
                        const at = far.next(idx_thunk_len) orelse
                            return refuse(refusal, .{ .reason = .no_free_space, .detail = idx_thunk_len });
                        @memcpy(out[at..][0..idx_thunk_len], &idxThunkBody(t.op, t.v, 0x6B));
                        body = @intCast((at / 0x8000) << 16 | (0x8000 + (at % 0x8000)));
                        cold_bodies[n_cold_bodies] = .{ .v = t.v, .op = t.op, .at = body };
                        n_cold_bodies += 1;
                    }
                    if (bank_stub == 0) {
                        bank_stub = pad.next(far_stub_len) orelse
                            return refuse(refusal, .{ .reason = .wg_thunk_space, .detail = tbank });
                        out[bank_stub] = 0x22; // JSL — dispatcher patched in below
                        out[bank_stub + 4] = 0x60; // RTS
                        cold_stubs[n_cold_stubs] = bank_stub;
                        n_cold_stubs += 1;
                    }
                    if (n_cold == idx_thunk_max)
                        return refuse(refusal, .{ .reason = .wg_split_overflow, .detail = @intCast(t.file) });
                    cold_sites[n_cold] = .{
                        .site = @intCast((t.file / 0x8000) << 16 | (0x8000 + (t.file % 0x8000))),
                        .body = body,
                    };
                    n_cold += 1;
                    out[t.file] = 0x20; // JSR — same 3-byte footprint
                    std.mem.writeInt(u16, out[t.file + 1 ..][0..2], @intCast(0x8000 + (bank_stub % 0x8000)), .little);
                    res.stats.disp_sites += 1;
                    continue;
                }
                var taddr: u16 = 0;
                var found = false;
                for (seen[0..n_seen]) |s| {
                    if (s.v == t.v and s.op == t.op and s.idx == t.idx and s.pin == t.pin) {
                        taddr = s.addr;
                        found = true;
                    }
                }
                if (!found) {
                    const placed = if (!t.idx)
                        placeThunk(out, &pad, &far, &splitThunkBody(t.op, t.v, 0x60), &splitThunkBody(t.op, t.v, 0x6B), ff, &res.stats.split_far)
                    else if (t.pin)
                        placeThunk(out, &pad, &far, &idxThunkBody(t.op, t.v, 0x60), &idxThunkBody(t.op, t.v, 0x6B), ff, &res.stats.split_far)
                    else if (t.v2())
                        placeThunk(out, &pad, &far, &idxThunkBodyV2(t.op, t.v, 0x60), &idxThunkBodyV2(t.op, t.v, 0x6B), ff, &res.stats.split_far)
                    else
                        placeThunk(out, &pad, &far, &idxThunkBodyShort(t.op, t.v, 0x60), &idxThunkBodyShort(t.op, t.v, 0x6B), ff, &res.stats.split_far);
                    taddr = placed orelse return refuse(refusal, .{
                        .reason = .no_free_space,
                        .detail = t.len(),
                    });
                    seen[n_seen] = .{ .v = t.v, .op = t.op, .idx = t.idx, .pin = t.pin, .addr = taddr };
                    n_seen += 1;
                }
                out[t.file] = 0x20; // JSR — same 3-byte footprint
                std.mem.writeInt(u16, out[t.file + 1 ..][0..2], taddr, .little);
            }
        }
        if (n_cold != 0) {
            // The dispatcher's table, sorted the way its binary search
            // descends: 16-bit address first, bank on ties. Records are
            // 8 bytes — [addr16][bank][0][body-1 lo][body-1 hi][bank][0]
            // — so `mid` floors with a single AND, and the stored target
            // is body-1 because RTL lands one past what it pulls.
            const Cold = @TypeOf(cold_sites[0]);
            const S = struct {
                fn lt(_: void, a: Cold, b: Cold) bool {
                    const ka = (@as(u32, a.site) & 0xFFFF) << 8 | (a.site >> 16);
                    const kb = (@as(u32, b.site) & 0xFFFF) << 8 | (b.site >> 16);
                    return ka < kb;
                }
            };
            std.mem.sort(Cold, cold_sites[0..n_cold], {}, S.lt);
            const tbl = far.next(@intCast(8 * n_cold)) orelse
                return refuse(refusal, .{ .reason = .no_free_space, .detail = @intCast(8 * n_cold) });
            for (cold_sites[0..n_cold], 0..) |c, ci| {
                const r = out[tbl + 8 * ci ..][0..8];
                std.mem.writeInt(u16, r[0..2], @truncate(c.site), .little);
                r[2] = @intCast(c.site >> 16);
                r[3] = 0;
                const tgt: u24 = c.body - 1;
                std.mem.writeInt(u16, r[4..6], @truncate(tgt), .little);
                r[6] = @intCast(tgt >> 16);
                r[7] = 0;
            }
            const disp = far.next(cold_disp_len) orelse
                return refuse(refusal, .{ .reason = .no_free_space, .detail = cold_disp_len });
            const tbl_cpu: u24 = @intCast((tbl / 0x8000) << 16 | (0x8000 + (tbl % 0x8000)));
            @memcpy(out[disp..][0..cold_disp_len], &coldDispatcherBody(tbl_cpu, @intCast(n_cold)));
            const disp_cpu: u24 = @intCast((disp / 0x8000) << 16 | (0x8000 + (disp % 0x8000)));
            for (cold_stubs[0..n_cold_stubs]) |s| {
                std.mem.writeInt(u16, out[s + 1 ..][0..2], @truncate(disp_cpu), .little);
                out[s + 3] = @intCast(disp_cpu >> 16);
            }
        }
        res.stats.split_sites = @intCast(n_all);
        res.stats.idx_split_sites = @intCast(n_ithunks);
    }
    // The LONG,X flavor, placed entirely in the far pool: `JSL` names its
    // own bank, so these thunks are free of the bank-local constraint that
    // shapes everything above — and, unlike the `JSR` flavor, a copied
    // tree member carries one unchanged. Bodies are shared by (op,
    // operand, bank), and their addresses are handed to the offload
    // eligibility walk so it can tell a thunk call from a tree member.
    var lbodies: [64]u24 = undefined;
    var n_lbodies: usize = 0;
    if (window and n_lthunks != 0) {
        const LSeen = struct { v: u16, op: u8, bank: u8, at: u32 };
        var lseen: [idx_thunk_max]LSeen = undefined;
        var n_lseen: usize = 0;
        for (lthunks[0..n_lthunks]) |t| {
            var at: u32 = 0;
            var found = false;
            for (lseen[0..n_lseen]) |s| {
                if (s.v == t.v and s.op == t.op and s.bank == t.bank) {
                    at = s.at;
                    found = true;
                }
            }
            if (!found) {
                // A base at or above $FF00 wraps forward into the NEXT
                // bank's low page and needs the two-compare body; a tiny
                // base stays in its own bank and needs the ceiling one.
                const neg = t.v >= 0xFF00;
                const want: u32 = if (neg) long_neg_thunk_len else long_thunk_len;
                at = far.next(want) orelse
                    return refuse(refusal, .{ .reason = .no_free_space, .detail = want });
                if (neg)
                    @memcpy(out[at..][0..long_neg_thunk_len], &longNegThunkBody(t.op, t.v, t.bank))
                else
                    @memcpy(out[at..][0..long_thunk_len], &longThunkBody(t.op, t.v, t.bank));
                lseen[n_lseen] = .{ .v = t.v, .op = t.op, .bank = t.bank, .at = at };
                n_lseen += 1;
                if (n_lbodies < lbodies.len) {
                    lbodies[n_lbodies] = @intCast((at / 0x8000) << 16 | (0x8000 + (at % 0x8000)));
                    n_lbodies += 1;
                }
            }
            out[t.file] = 0x22; // JSL — the same 4-byte footprint
            std.mem.writeInt(u16, out[t.file + 1 ..][0..2], @as(u16, @intCast(0x8000 + (at % 0x8000))), .little);
            out[t.file + 3] = @intCast(at / 0x8000);
        }
        res.stats.split_sites += @intCast(n_lthunks);
        res.stats.idx_split_sites += @intCast(n_lthunks);
    }

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
        const boot: ?WinBoot = if (win_candidates.len != 0)
            emitWindowOffloads(out, cov, site_evidence, header.offset, win_candidates, win_allow_async, carve + wg_window_shim_max, lbodies[0..n_lbodies], &res)
        else
            null;

        var wn: usize = 0;
        d[wn] = 0x78; // SEI
        wn += 1;
        wn = emitStore(d, wn, 0x2224, 0x00); // SBM: S-CPU window = block 0
        wn = emitStore(d, wn, 0x2226, 0x80); // SWEN: S-CPU BW-RAM writes
        wn = emitStore(d, wn, 0x2228, 0x00); // BWPA: nothing protected
        if (boot) |b| {
            // Boot the SA-1 into the window dispatcher; the async busy
            // flag starts idle (I-RAM is garbage at power-on, and SIWP
            // must open before the S-CPU can zero it). CIV is aimed at
            // the watchdog's abort handler from HERE — $2207/8 is an
            // S-CPU-side register the SA-1 itself cannot program.
            wn = emitStore(d, wn, 0x2229, 0xFF);
            wn = emitStore(d, wn, 0x2203, @truncate(b.crv));
            wn = emitStore(d, wn, 0x2204, @truncate(b.crv >> 8));
            wn = emitStore(d, wn, 0x2207, @truncate(b.civ));
            wn = emitStore(d, wn, 0x2208, @truncate(b.civ >> 8));
            wn = emitStore(d, wn, 0x378C, 0x00); // sync mailbox-busy guard cell
            wn = emitStore(d, wn, 0x378D, 0x00); // watchdog aborted flag
            wn = emitStore(d, wn, 0x378F, 0x00); // $4200 mirror (boot state)
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
        out[header.offset + 0x16] = 0x34; // no battery: the relocated WRAM must not persist
        out[header.offset + 0x18] = 0x07; // 128 KiB BW-RAM: all of WRAM
        patchgen.recomputeChecksum(out, header.offset);
        res.stats.shim_addr = base16;
        res.stats.park_addr = if (boot) |b| b.crv else 0;
        res.stats.offloaded = if (boot == null) reset else res.stats.offloaded;
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
    out[header.offset + 0x16] = 0x34; // no battery: BW-RAM is working memory
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
    // $34 = SA-1 + RAM, NO battery: the BW-RAM is working memory, and a
    // frontend that persisted it would boot the next session into stale
    // mid-game state.
    try testing.expectEqual(@as(u8, 0x34), h.chipset);
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

/// `markOp` for an instruction executed with 16-bit INDEX registers: the
/// immediate's length differs, so the coverage map has to say so or every
/// decode after it slides.
fn markOpX16(usage: []u8, cpu_addr: u32) void {
    usage[cpu_addr] |= usage_map.flag_opcode | usage_map.flag_exec | usage_map.flag_m;
    usage[cpu_addr] &= ~usage_map.flag_x;
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
    const res = try convertWholeGame(gpa, rom, bytes, null, null, false, true, &.{}, false, 0, copy_reserve, &ref);
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

test "window: the BW-RAM window mirrors in banks $80-$BF like the hardware" {
    // The FastROM bank lift turns `LDA $03:0002,X` into `LDA $83:0002,X`.
    // GIII's slot walker serves ROM nodes AND relocated-WRAM nodes through
    // that one instruction (stock reads the WRAM mirror; the conversion
    // reads the window), so bank $83's $6000-$7FFF must reach the SAME
    // BW-RAM bytes as bank $03's — as it does on the real chip.
    const gpa = testing.allocator;
    const console = @import("../console.zig");
    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, bytes, null, null, false, true, &.{}, false, 0, copy_reserve, &ref);
    defer gpa.free(res.image);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    con.runFrame(); // boot: shim opens SBM/SWEN
    con.bus.write8(0x00_6012, 0xA7);
    try testing.expectEqual(@as(u8, 0xA7), con.bus.read8(0x00_6012));
    try testing.expectEqual(@as(u8, 0xA7), con.bus.read8(0x03_6012));
    try testing.expectEqual(@as(u8, 0xA7), con.bus.read8(0x83_6012));
    con.bus.write8(0xA1_6013, 0x5C); // write through a high mirror too
    try testing.expectEqual(@as(u8, 0x5C), con.bus.read8(0x21_6013));
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
        const res = try convertWholeGame(gpa, rom, bytes, null, null, false, true, &cand, go_async, 0, copy_reserve, &ref);
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
        try testing.expect(con.bus.sa1.bwram[0x0501] > 2); // called repeatedly (rate is timing-dependent)
        try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0500]);
        try testing.expect(con.bus.sa1.bwram[0x0040] >= 3); // NMI counter
        try testing.expect(trace.total > 0);
        // (No port-idle assert: the caller loops hot, so a sampled
        // instant is legitimately mid-handshake.)
    }
}

test "window offload: a BW-RAM-pinned caller's registers survive the dispatch" {
    // The async flavor's runaway, reduced. A caller pinned to $7E
    // (re-banked to $40) marshals DBR=$40 — and the dispatcher's
    // unmarshal used to run AFTER the game DBR was set, so its absolute
    // $37xx reads landed in BW-RAM game data instead of I-RAM: the tree
    // ran with whatever bytes the game kept there. The caller here
    // poisons exactly those BW-RAM shadows with $FF first ($7E:3780 and
    // $7E:3786 — the A and P cells), then calls with A=$55 and carry
    // set; the tree must see the REAL registers through both flavors.
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    @memset(rom[0x8000..0x10000], 0xFF);
    @memcpy(rom[0x0000..0x0024], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, // CLC / XCE / SEP #$30
        0xA9, 0x80, 0x8D, 0x00, 0x42, // NMITIMEN: NMI on
        0xA9, 0xFF, 0x8F, 0x86, 0x37, 0x7E, // poison the P cell's BW-RAM shadow
        0x8F, 0x80, 0x37, 0x7E, // and the A cell's
        0xA9, 0x7E, 0x48, 0xAB, // pin DBR = $7E (re-banked to $40)
        0xA9, 0x55, // the value the tree must see
        0x38, // SEC — and the carry it must see
        0x22, 0x80, 0x80, 0x00, // JSL $00:8080
        0xA9, 0x00, 0x48, 0xAB, // back to the system bank
        0x80, 0xEF, // BRA to the re-pin
    });
    @memcpy(rom[0x0040..0x0046], &[_]u8{ 0x48, 0xEE, 0x40, 0x00, 0x68, 0x40 }); // NMI: INC $0040
    std.mem.writeInt(u16, rom[0x7FC0 + 0x2A ..][0..2], 0x8040, .little);
    // Long stores only: the tree's observations must not depend on the
    // caller's DBR — the registers are what is under test here.
    @memcpy(rom[0x0080..0x008D], &[_]u8{
        0x8F, 0x00, 0x05, 0x7E, // STA $7E:0500 — the marshalled A, or the poison
        0x90, 0x06, // BCC +6 — the marshalled carry
        0xA9, 0xAA, 0x8F, 0x03, 0x05, 0x7E, // LDA #$AA / STA $7E:0503
        0x6B,
    });

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8006, 0x8009, 0x800B, 0x800F, 0x8013, 0x8015, 0x8016, 0x8017, 0x8019, 0x801A, 0x801E, 0x8020, 0x8021, 0x8022 }) |a| markOp(bytes, a);
    for ([_]u32{ 0x8040, 0x8041, 0x8044, 0x8045 }) |a| markOp(bytes, a);
    for ([_]u32{ 0x8080, 0x8084, 0x8086, 0x8088, 0x808C }) |a| markOp(bytes, a);

    const cand = [_]Candidate{.{ .entry = 0x00_8080 }};
    for ([_]bool{ false, true }) |go_async| {
        var ref: ?Refusal = null;
        const res = try convertWholeGame(gpa, rom, bytes, null, null, false, true, &cand, go_async, 0, copy_reserve, &ref);
        defer gpa.free(res.image);
        try testing.expectEqual(@as(u8, 1), res.stats.offload_count);

        const cart = try cartridge.Cartridge.load(gpa, res.image);
        const con = try gpa.create(console.FastConsole);
        defer {
            con.cart.deinit(gpa);
            gpa.destroy(con);
        }
        con.init(cart);
        for (0..5) |_| con.runFrame();
        // The poison is really there — and the tree never read it.
        try testing.expectEqual(@as(u8, 0xFF), con.bus.sa1.bwram[0x3786]);
        try testing.expectEqual(@as(u8, 0xFF), con.bus.sa1.bwram[0x3780]);
        try testing.expectEqual(@as(u8, 0x55), con.bus.sa1.bwram[0x0500]);
        try testing.expectEqual(@as(u8, 0xAA), con.bus.sa1.bwram[0x0503]);
        try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0500]);
    }
}

test "window offload: the root's DBR pin travels through in-tree JSLs and admits an uncovered site" {
    // The $8EF1 shape in miniature: the root pins the WRAM bank (the
    // window rewrite re-banks the idiom to $40), then JSLs a helper whose
    // never-executed branch holds an indexed absolute with MIXED evidence
    // — unshiftable, and the SA-1's own I-RAM if the copy ran it unpinned.
    // Every in-tree path to it carries the root's pin, under which it is
    // BW-RAM data on both buses whatever X holds — so the tree is
    // eligible. Without the pin idiom the same tree must refuse.
    //
    // (Mixed evidence, not zero: a ZERO-evidence tiny-base indexed site is
    // no longer left in place at all — it becomes an index-split thunk,
    // which is a different contract, tested separately.)
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    for ([_]bool{ true, false }) |pinned| {
        const rom = try makeWgRom(gpa);
        defer gpa.free(rom);
        @memset(rom[0x8000..0x10000], 0xFF); // bank 1: the any-bank carve
        @memcpy(rom[0x0000..0x000A], &[_]u8{
            0x18, 0xFB, 0xE2, 0x30, // CLC / XCE / SEP #$30
            0x22, 0x80, 0x80, 0x00, // JSL $00:8080
            0x80, 0xFA, // BRA back to the JSL
        });
        // Root: pin the WRAM bank (or NOPs for the control), store a
        // marker, call the helper.
        @memcpy(rom[0x0080..0x0090], if (pinned) &[_]u8{
            0x8B, // PHB — real trees save the caller's bank
            0xA9, 0x7E, 0x48, 0xAB, // LDA #$7E / PHA / PLB (re-banked to $40)
            0xA9, 0x11, 0x8D, 0x00, 0x05, // LDA #$11 / STA $0500
            0x22, 0xA0, 0x80, 0x00, // JSL $00:80A0
            0xAB, // PLB — and restore it (the vblank guard's inline bail
            // executes this body on the S-CPU; a root that leaked its pin
            // was a test-world artifact no real tree exhibits)
            0x6B, // RTL
        } else &[_]u8{
            0xEA, 0xEA, 0xEA, 0xEA, 0xEA,
            0xA9, 0x11, 0x8D, 0x00, 0x05,
            0x22, 0xA0, 0x80, 0x00,
            0xEA, 0x6B,
        });
        // Helper: a live counter, then a never-taken branch guarding the
        // hazard-shaped site (statically discovered code, zero evidence).
        @memcpy(rom[0x00A0..0x00AB], &[_]u8{
            0xEE, 0x01, 0x05, // INC $0501
            0xA9, 0x01, // LDA #$01
            0xD0, 0x03, // BNE +3 (always taken)
            0x1E, 0x00, 0x00, // ASL $0000,X — never executes
            0x6B, // RTL
        });

        const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
        defer gpa.free(bytes);
        @memset(bytes, 0);
        for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8008 }) |a| markOp(bytes, a);
        if (pinned) {
            for ([_]u32{ 0x8080, 0x8081, 0x8083, 0x8084 }) |a| markOp(bytes, a);
        } else {
            for ([_]u32{ 0x8080, 0x8081, 0x8082, 0x8083, 0x8084 }) |a| markOp(bytes, a);
        }
        for ([_]u32{ 0x8085, 0x8087, 0x808A, 0x808E, 0x808F }) |a| markOp(bytes, a);
        for ([_]u32{ 0x80A0, 0x80A3, 0x80A5, 0x80A7, 0x80AA }) |a| markOp(bytes, a);
        // The helper's live sites measured as $7E-mediated traffic (the
        // real trees' shape) so the rewriter leaves their operands to the
        // pin; the guarded ASL carries MIXED evidence — unshiftable by any
        // rule, and unthunkable too, which is the hazard shape.
        const sites = try gpa.alloc(u8, usage_map.cpu_map_len);
        defer gpa.free(sites);
        @memset(sites, 0);
        sites[0x80A0] = usage_map.site_wram_bank;
        sites[0x8087] = usage_map.site_wram_bank;
        sites[0x80A7] = usage_map.site_wram_low | usage_map.site_other;

        const cand = [_]Candidate{.{ .entry = 0x00_8080 }};
        var ref: ?Refusal = null;
        const res = try convertWholeGame(gpa, rom, bytes, sites, null, false, true, &cand, false, 0, copy_reserve, &ref);
        defer gpa.free(res.image);
        if (!pinned) {
            // Control: the uncovered site with no pin is the I-RAM hazard.
            try testing.expectEqual(@as(u8, 0), res.stats.offload_count);
            continue;
        }
        try testing.expectEqual(@as(u8, 1), res.stats.offload_count);
        try testing.expectEqual(@as(u8, 1), res.stats.resident_offloads);

        const cart = try cartridge.Cartridge.load(gpa, res.image);
        const con = try gpa.create(console.FastConsole);
        defer {
            con.cart.deinit(gpa);
            gpa.destroy(con);
        }
        con.init(cart);
        for (0..5) |_| con.runFrame();
        // The tree ran on the SA-1 against the shared window: marker and
        // counter in BW-RAM (the pinned bank IS the relocated home), real
        // WRAM untouched.
        try testing.expectEqual(@as(u8, 0x11), con.bus.sa1.bwram[0x0500]);
        try testing.expect(con.bus.sa1.bwram[0x0501] > 2);
        try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0500]);
        try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0501]);
    }
}

test "window: a context-split site serves both caller classes through its thunk" {
    // One shared helper, two callers: a system-DBR caller (needs the
    // +$6000 shift) and a $7E-pinned caller (pin re-banked to $40 —
    // needs the operand untouched). Site evidence measures both, the
    // rewriter emits the DBR-dispatch thunk, and at runtime BOTH callers
    // reach the same BW-RAM cell. The system caller also carries SEC
    // across the helper — the thunk must not eat the carry.
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    @memset(rom[0x8000..0x10000], 0xFF);
    @memcpy(rom[0x0000..0x000E], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, // CLC / XCE / SEP #$30
        0x22, 0x80, 0x80, 0x00, // JSL $00:8080 (system caller)
        0x22, 0xC0, 0x80, 0x00, // JSL $00:80C0 (pinned caller)
        0x80, 0xF6, // BRA back to the first JSL
    });
    @memcpy(rom[0x0080..0x008B], &[_]u8{
        0x38, // SEC
        0x22, 0x00, 0x81, 0x00, // JSL $00:8100
        0x90, 0x03, // BCC +3 (carry lost -> skip)
        0xEE, 0x42, 0x01, // INC $0142 (plain site, shifts to the window)
        0x6B, // RTL
    });
    @memcpy(rom[0x00C0..0x00CD], &[_]u8{
        0xA9, 0x7E, 0x48, 0xAB, // pin $7E (re-banked to $40)
        0x22, 0x00, 0x81, 0x00, // JSL $00:8100
        0xA9, 0x00, 0x48, 0xAB, // back to the system bank
        0x6B, // RTL
    });
    @memcpy(rom[0x0100..0x0107], &[_]u8{
        0xEE, 0x40, 0x01, // INC $0140 — the context-split site
        0x9C, 0x41, 0x01, // STZ $0141 — and another
        0x6B, // RTL
    });

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8008, 0x800C }) |a| markOp(bytes, a);
    for ([_]u32{ 0x8080, 0x8081, 0x8085, 0x8087, 0x808A }) |a| markOp(bytes, a);
    for ([_]u32{ 0x80C0, 0x80C2, 0x80C3, 0x80C4, 0x80C8, 0x80CA, 0x80CB, 0x80CC }) |a| markOp(bytes, a);
    for ([_]u32{ 0x8100, 0x8103, 0x8106 }) |a| markOp(bytes, a);
    const sites = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(sites);
    @memset(sites, 0);
    sites[0x8100] = usage_map.site_wram_low | usage_map.site_wram_bank;
    sites[0x8103] = usage_map.site_wram_low | usage_map.site_wram_bank;

    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, bytes, sites, null, false, true, &.{}, false, 0, copy_reserve, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u16, 2), res.stats.split_sites);
    try testing.expectEqual(@as(u8, 0x20), res.image[0x0100]); // JSR over the site

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    for (0..5) |_| con.runFrame();
    // Both caller classes reached the SAME relocated cell; real WRAM saw
    // nothing; the system caller's carry survived the thunk every lap.
    try testing.expect(con.bus.sa1.bwram[0x0140] > 4);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0140]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0141]);
    try testing.expect(con.bus.sa1.bwram[0x0142] > 2);
    // $0140 counts both callers per lap, $0142 the system caller alone —
    // 2:1 modulo the lap the frame boundary caught mid-flight (and modulo
    // u8 wrap, so compare through the same wrap).
    const both: u8 = con.bus.sa1.bwram[0x0140];
    const sys_only: u8 = con.bus.sa1.bwram[0x0142];
    const twice: u8 = sys_only *% 2;
    try testing.expect(both -% twice <= 2 or twice -% both <= 2);
}

test "window: an unmeasured tiny-base indexed site serves all three of its worlds" {
    // The laser's defect, reduced. A tiny-base indexed absolute with NO
    // evidence used to be left exactly as written, on the reasoning that
    // "X is the pointer" — true for a ROM walk, catastrophic for a data
    // base, whose accesses then land in the WRAM the window abandoned.
    // The index-split thunk decides at run time, and there are THREE
    // worlds to get right, not two:
    //
    //   system DBR + small index -> the window (+$6000)
    //   pinned DBR ($40/$41)     -> as written (that bank's own low page)
    //   system DBR + huge index  -> as written (a ROM walk)
    //
    // A STORE is the shape that proves the A-preserving template: the v1
    // thunk scratched A and could only serve loads, which is why the
    // laser's `STA $0030,Y` was never covered by the mechanism at all.
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    @memset(rom[0x8000..0x10000], 0xFF);
    rom[0x0202] = 0x5A; // the ROM byte the huge-index walk must find
    @memcpy(rom[0x0000..0x0018], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, 0xC2, 0x10, // CLC / XCE / SEP #$30 / REP #$10
        0x22, 0x80, 0x80, 0x00, // system caller, small Y
        0x22, 0xA0, 0x80, 0x00, // $7E-pinned caller
        0x22, 0xC0, 0x80, 0x00, // system caller, huge X
        0x22, 0xE0, 0x80, 0x00, // system caller in x8
        0x80, 0xEE, // BRA back to the first JSL
    });
    @memcpy(rom[0x0080..0x0090], &[_]u8{
        0xA0, 0x10, 0x01, // LDY #$0110
        0xA9, 0x11, // LDA #$11
        0x38, // SEC — the thunk must not eat it
        0x22, 0x00, 0x81, 0x00, // JSL $00:8100
        0x90, 0x03, // BCC +3 (carry lost -> skip)
        0xEE, 0x60, 0x01, // INC $0160
        0x6B,
    });
    @memcpy(rom[0x00A0..0x00B2], &[_]u8{
        0xA9, 0x7E, 0x48, 0xAB, // pin $7E (re-banked to $40)
        0xA0, 0x10, 0x02, // LDY #$0210
        0xA9, 0x22, // LDA #$22
        0x22, 0x00, 0x81, 0x00, // JSL $00:8100
        0xA9, 0x00, 0x48, 0xAB, // back to the system bank
        0x6B,
    });
    @memcpy(rom[0x00C0..0x00C8], &[_]u8{
        0xA2, 0x00, 0x82, // LDX #$8200 — past the mirror: a ROM walk
        0x22, 0x10, 0x81, 0x00, // JSL $00:8110
        0x6B,
    });
    @memcpy(rom[0x00E0..0x00ED], &[_]u8{
        0xE2, 0x10, // SEP #$10 — 8-bit index
        0xA0, 0x50, // LDY #$50
        0xA9, 0x33, // LDA #$33
        0x22, 0x00, 0x81, 0x00, // JSL $00:8100
        0xC2, 0x10, // REP #$10
        0x6B,
    });
    @memcpy(rom[0x0100..0x0104], &[_]u8{ 0x99, 0x30, 0x00, 0x6B }); // STA $0030,Y / RTL
    @memcpy(rom[0x0110..0x0117], &[_]u8{
        0xBD, 0x02, 0x00, // LDA $0002,X — the same shape, a load
        0x8D, 0x70, 0x01, // STA $0170 (plain site: shifts to the window)
        0x6B,
    });

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004 }) |a| markOp(bytes, a);
    for ([_]u32{ 0x8006, 0x800A, 0x800E, 0x8012, 0x8016 }) |a| markOpX16(bytes, a);
    // The x16 stretch: everything from the first REP to the last caller's
    // SEP decodes with 16-bit indices.
    for ([_]u32{ 0x8080, 0x8083, 0x8085, 0x8086, 0x808A, 0x808C, 0x808F }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x80A0, 0x80A2, 0x80A3, 0x80A4, 0x80A7, 0x80A9, 0x80AD, 0x80AF, 0x80B0, 0x80B1 }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x80C0, 0x80C3, 0x80C7 }) |a| markOpX16(bytes, a);
    markOpX16(bytes, 0x80E0);
    for ([_]u32{ 0x80E2, 0x80E4, 0x80E6, 0x80EA }) |a| markOp(bytes, a);
    markOpX16(bytes, 0x80EC);
    for ([_]u32{ 0x8100, 0x8103, 0x8110, 0x8113, 0x8116 }) |a| markOpX16(bytes, a);

    // No evidence anywhere: that is the whole point.
    const sites = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(sites);
    @memset(sites, 0);

    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, bytes, sites, null, false, true, &.{}, false, 0, copy_reserve, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u16, 2), res.stats.split_sites);
    try testing.expectEqual(@as(u8, 0x20), res.image[0x0100]); // JSR over the store
    try testing.expectEqual(@as(u8, 0x20), res.image[0x0110]); // and over the load

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    for (0..5) |_| con.runFrame();

    // World 1: system bank, small index -> the window.
    try testing.expectEqual(@as(u8, 0x11), con.bus.sa1.bwram[0x0140]);
    // World 2: pinned to $40 -> that bank's own $0240, NOT $40:6240.
    try testing.expectEqual(@as(u8, 0x22), con.bus.sa1.bwram[0x0240]);
    try testing.expectEqual(@as(u8, 0), con.bus.sa1.bwram[0x6240]);
    // World 3: system bank, huge index -> ROM, read and parked in the window.
    try testing.expectEqual(@as(u8, 0x5A), con.bus.sa1.bwram[0x0170]);
    // An 8-bit index over a tiny base cannot leave the low page, whatever
    // the compare would have said about a byte it never fetched.
    try testing.expectEqual(@as(u8, 0x33), con.bus.sa1.bwram[0x0080]);
    // Carry survived the thunk every lap, and real WRAM saw none of it.
    try testing.expect(con.bus.sa1.bwram[0x0160] > 2);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0140]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0080]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0170]);
}

test "window: cold sites in a full bank share one stub through the dispatcher" {
    // The three-worlds scenario again, but the sites live in a bank
    // whose entire padding is one 14-byte run: room for a single 5-byte
    // stub and TWO distinct unmeasured thunks that want one. Per-thunk
    // stubs refuse; the cold dispatcher routes both sites through the
    // bank's one shared stub and finds each body by return address. The
    // assertions are the same as the per-thunk test's — the dispatcher
    // must be invisible: same cells, same carry, same flags.
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try gpa.alloc(u8, 128 * 1024);
    defer gpa.free(rom);
    for (rom, 0..) |*b, i| b.* = @truncate(0x11 + i *% 7);
    const h = rom[0x7FC0..][0..64];
    @memcpy(h[0..21], "COLD DISPATCH TEST   ");
    h[0x15] = 0x20;
    h[0x16] = 0x00;
    h[0x17] = 7; // 128 KiB
    h[0x18] = 0;
    std.mem.writeInt(u16, h[0x1C..0x1E], 0xFFFF, .little);
    std.mem.writeInt(u16, h[0x1E..0x20], 0x0000, .little);
    @memset(h[0x20..0x40], 0);
    std.mem.writeInt(u16, h[0x3C..0x3E], 0x8000, .little);
    @memset(rom[0x1000..0x7FC0], 0xFF); // bank $00: the carve's space
    @memset(rom[0xFF00..0xFF0E], 0xFF); // bank $01's ONLY padding: 14 bytes
    @memset(rom[0x10000..0x20000], 0xFF); // banks $02/$03: the far pool
    rom[0x0202] = 0x5A; // the ROM byte the huge-index walk must find

    @memcpy(rom[0x0000..0x0018], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, 0xC2, 0x10, // CLC / XCE / SEP #$30 / REP #$10
        0x22, 0x80, 0x80, 0x00, // system caller, small Y
        0x22, 0xA0, 0x80, 0x00, // $7E-pinned caller
        0x22, 0xC0, 0x80, 0x00, // system caller, huge X
        0x22, 0xE0, 0x80, 0x00, // system caller in x8
        0x80, 0xEE, // BRA back to the first JSL
    });
    @memcpy(rom[0x0080..0x0090], &[_]u8{
        0xA0, 0x10, 0x01, // LDY #$0110
        0xA9, 0x11, // LDA #$11
        0x38, // SEC — the dispatcher must not eat it either
        0x22, 0x00, 0x81, 0x01, // JSL $01:8100
        0x90, 0x03, // BCC +3 (carry lost -> skip)
        0xEE, 0x60, 0x01, // INC $0160
        0x6B,
    });
    @memcpy(rom[0x00A0..0x00B2], &[_]u8{
        0xA9, 0x7E, 0x48, 0xAB, // pin $7E (re-banked to $40)
        0xA0, 0x10, 0x02, // LDY #$0210
        0xA9, 0x22, // LDA #$22
        0x22, 0x00, 0x81, 0x01, // JSL $01:8100
        0xA9, 0x00, 0x48, 0xAB, // back to the system bank
        0x6B,
    });
    @memcpy(rom[0x00C0..0x00C8], &[_]u8{
        0xA2, 0x00, 0x82, // LDX #$8200 — past the mirror: a ROM walk
        0x22, 0x10, 0x81, 0x01, // JSL $01:8110
        0x6B,
    });
    @memcpy(rom[0x00E0..0x00ED], &[_]u8{
        0xE2, 0x10, // SEP #$10 — 8-bit index
        0xA0, 0x50, // LDY #$50
        0xA9, 0x33, // LDA #$33
        0x22, 0x00, 0x81, 0x01, // JSL $01:8100
        0xC2, 0x10, // REP #$10
        0x6B,
    });
    @memcpy(rom[0x8100..0x8104], &[_]u8{ 0x99, 0x30, 0x00, 0x6B }); // STA $0030,Y / RTL
    @memcpy(rom[0x8110..0x8117], &[_]u8{
        0xBD, 0x02, 0x00, // LDA $0002,X — the same shape, a load
        0x8D, 0x70, 0x01, // STA $0170 (plain site: shifts to the window)
        0x6B,
    });

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004 }) |a| markOp(bytes, a);
    for ([_]u32{ 0x8006, 0x800A, 0x800E, 0x8012, 0x8016 }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x8080, 0x8083, 0x8085, 0x8086, 0x808A, 0x808C, 0x808F }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x80A0, 0x80A2, 0x80A3, 0x80A4, 0x80A7, 0x80A9, 0x80AD, 0x80AF, 0x80B0, 0x80B1 }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x80C0, 0x80C3, 0x80C7 }) |a| markOpX16(bytes, a);
    markOpX16(bytes, 0x80E0);
    for ([_]u32{ 0x80E2, 0x80E4, 0x80E6, 0x80EA }) |a| markOp(bytes, a);
    markOpX16(bytes, 0x80EC);
    for ([_]u32{ 0x018100, 0x018103, 0x018110, 0x018113, 0x018116 }) |a| markOpX16(bytes, a);

    // No evidence anywhere: both thunks are COLD.
    const sites = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(sites);
    @memset(sites, 0);

    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, bytes, sites, null, false, true, &.{}, false, 0, copy_reserve, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u16, 2), res.stats.split_sites);
    try testing.expectEqual(@as(u16, 2), res.stats.disp_sites);
    try testing.expectEqual(@as(u16, 0), res.stats.split_far);
    try testing.expectEqual(@as(u8, 0x20), res.image[0x8100]); // JSR over the store
    try testing.expectEqual(@as(u8, 0x20), res.image[0x8110]); // and over the load
    // Both sites name the SAME stub — the bank paid five bytes total.
    try testing.expectEqual(
        std.mem.readInt(u16, res.image[0x8101..0x8103], .little),
        std.mem.readInt(u16, res.image[0x8111..0x8113], .little),
    );

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    for (0..5) |_| con.runFrame();

    // World 1: system bank, small index -> the window.
    try testing.expectEqual(@as(u8, 0x11), con.bus.sa1.bwram[0x0140]);
    // World 2: pinned to $40 -> that bank's own $0240, NOT $40:6240.
    try testing.expectEqual(@as(u8, 0x22), con.bus.sa1.bwram[0x0240]);
    try testing.expectEqual(@as(u8, 0), con.bus.sa1.bwram[0x6240]);
    // World 3: system bank, huge index -> ROM, read and parked in the window.
    try testing.expectEqual(@as(u8, 0x5A), con.bus.sa1.bwram[0x0170]);
    // An 8-bit index over a tiny base stays in the low page.
    try testing.expectEqual(@as(u8, 0x33), con.bus.sa1.bwram[0x0080]);
    // Carry survived the whole dispatch chain every lap; WRAM saw nothing.
    try testing.expect(con.bus.sa1.bwram[0x0160] > 2);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0140]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0080]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0170]);
}

test "window: measured evidence drops the thunk's data-bank arm" {
    // The same site as the three-worlds test, but MEASURED as low|rom —
    // which rules a BW-RAM pin out, so the thunk should not pay ~17 cycles
    // a call asking. It did, once, and the cost alone moved Gradius III's
    // timeline far enough to flip a behavioural verdict that had shipped.
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    @memset(rom[0x8000..0x10000], 0xFF);
    @memcpy(rom[0x0000..0x000C], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, 0xC2, 0x10, // CLC / XCE / SEP #$30 / REP #$10
        0x22, 0x80, 0x80, 0x00, // the caller
        0x80, 0xFA, // BRA back to it
    });
    @memcpy(rom[0x0080..0x008D], &[_]u8{
        0xA0, 0x10, 0x01, // LDY #$0110
        0xA9, 0x44, // LDA #$44
        0x22, 0x00, 0x81, 0x00, // JSL $00:8100
        0xEE, 0x60, 0x01, // INC $0160
        0x6B,
    });
    @memcpy(rom[0x0100..0x0104], &[_]u8{ 0x99, 0x30, 0x00, 0x6B }); // STA $0030,Y / RTL

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004 }) |a| markOp(bytes, a);
    for ([_]u32{ 0x8006, 0x800A }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x8080, 0x8083, 0x8085, 0x8089, 0x808C }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x8100, 0x8103 }) |a| markOpX16(bytes, a);

    const sites = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(sites);
    @memset(sites, 0);
    sites[0x8100] = usage_map.site_wram_low | usage_map.site_rom;

    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, bytes, sites, null, false, true, &.{}, false, 0, copy_reserve, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u16, 1), res.stats.idx_split_sites);
    try testing.expectEqual(@as(u8, 0x20), res.image[0x0100]);
    // The SHORT prologue: PHP / SEP #$20 / PHA / LDA $02,S — no PHB/PLA.
    const body = std.mem.readInt(u16, res.image[0x0101..0x0103], .little) - 0x8000;
    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0xE2, 0x20, 0x48, 0xA3, 0x02 }, res.image[body..][0..6]);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    for (0..5) |_| con.runFrame();
    try testing.expectEqual(@as(u8, 0x44), con.bus.sa1.bwram[0x0140]);
    try testing.expect(con.bus.sa1.bwram[0x0160] > 2);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0140]);
}

test "window: a NEGATIVE-base LONG,X site follows its wrap into the window" {
    // `LDA $01:FFFF,X` reads the byte before a bank boundary, so a small X
    // wraps FORWARD into the next bank's low page — the WRAM mirror, which
    // moved. Gradius III's slot walker uses the idiom on the boss's
    // node-insertion path, and inside an offloaded copy that page is the
    // SA-1's own I-RAM: the stage-1 boss rendered out of I-RAM garbage.
    // Every rule missed it by testing `v < $2000`.
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    @memset(rom[0x8000..0x10000], 0xFF);
    rom[0xFFFF] = 0x3C; // $01:FFFF — what an UNWRAPPED read must find
    @memcpy(rom[0x0000..0x0014], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, 0xC2, 0x10, // CLC / XCE / SEP #$30 / REP #$10
        0x22, 0x80, 0x80, 0x00, // X=7      -> wraps into the mirror
        0x22, 0xA0, 0x80, 0x00, // X=0      -> not wrapped, ROM
        0x22, 0xC0, 0x80, 0x00, // X=$8001  -> far past the mirror
        0x80, 0xF2, // BRA back to the first JSL
    });
    @memcpy(rom[0x0080..0x0090], &[_]u8{
        0xA9, 0x77, // LDA #$77
        0x8D, 0x06, 0x00, // STA $0006 (plain site: shifts into the window)
        0xA2, 0x07, 0x00, // LDX #$0007
        0x22, 0x00, 0x81, 0x00, // JSL $00:8100
        0x8D, 0x70, 0x01, // STA $0170
        0x6B,
    });
    @memcpy(rom[0x00A0..0x00AB], &[_]u8{
        0xA2, 0x00, 0x00, // LDX #$0000
        0x22, 0x00, 0x81, 0x00,
        0x8D, 0x74, 0x01, // STA $0174
        0x6B,
    });
    @memcpy(rom[0x00C0..0x00CB], &[_]u8{
        0xA2, 0x01, 0x80, // LDX #$8001
        0x22, 0x00, 0x81, 0x00,
        0x8D, 0x78, 0x01, // STA $0178
        0x6B,
    });
    @memcpy(rom[0x0100..0x0105], &[_]u8{ 0xBF, 0xFF, 0xFF, 0x01, 0x6B }); // LDA $01:FFFF,X / RTL

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004 }) |a| markOp(bytes, a);
    for ([_]u32{ 0x8006, 0x800A, 0x800E, 0x8012 }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x8080, 0x8082, 0x8085, 0x8088, 0x808C, 0x808F }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x80A0, 0x80A3, 0x80A7, 0x80AA }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x80C0, 0x80C3, 0x80C7, 0x80CA }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x8100, 0x8104 }) |a| markOpX16(bytes, a);

    const sites = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(sites);
    @memset(sites, 0);

    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, bytes, sites, null, false, true, &.{}, false, 0, copy_reserve, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u16, 1), res.stats.idx_split_sites);
    try testing.expectEqual(@as(u8, 0x22), res.image[0x0100]); // JSL over the site
    // The window arm keeps the DISTANCE by advancing the bank: $01:FFFF
    // + $6000 is $02:5FFF, so $02:5FFF + 7 is $02:6006 — the window cell
    // the shifted `STA $0006` wrote.
    const body = (@as(u32, res.image[0x0103] & 0x7F) * 0x8000) + (std.mem.readInt(u16, res.image[0x0101..0x0103], .little) - 0x8000);
    try testing.expectEqual(@as(u8, 0xFF), res.image[body + 15]); // $5FFF low
    try testing.expectEqual(@as(u8, 0x5F), res.image[body + 16]); // $5FFF high
    try testing.expectEqual(@as(u8, 0x02), res.image[body + 17]); // bank + 1

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    for (0..5) |_| con.runFrame();
    // Wrapped into the mirror: the read followed the store into the window.
    try testing.expectEqual(@as(u8, 0x77), con.bus.sa1.bwram[0x0170]);
    // Not wrapped: still this bank's own last ROM byte.
    try testing.expectEqual(@as(u8, 0x3C), con.bus.sa1.bwram[0x0174]);
    // Far past the mirror: whatever it reads, it is NOT the window cell.
    try testing.expect(con.bus.sa1.bwram[0x0178] != 0x77);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0006]);
}

test "window: a tiny-base LONG,X site splits on its index through a JSL thunk" {
    // The same idiom in the addressing mode the absolute thunk cannot
    // reach: `LDA $00:0002,X` is the slot walker's chain-follow with a
    // small X and a ROM table walk with a big one, and Gradius III has
    // three of them inside the walker at $00:90AE-$90C4. The site is FOUR
    // bytes, so `JSL` fits where `JSR` did not — and because a long call
    // names its own bank, the thunk needs no bank-local home. No DBR test
    // either: a long access carries its bank in the operand.
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    @memset(rom[0x8000..0x10000], 0xFF);
    rom[0x0202] = 0x5A; // the ROM byte the huge-index walk must find
    @memcpy(rom[0x0000..0x0010], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, 0xC2, 0x10, // CLC / XCE / SEP #$30 / REP #$10
        0x22, 0x80, 0x80, 0x00, // small-index caller
        0x22, 0xA0, 0x80, 0x00, // huge-index caller
        0x80, 0xF6, // BRA back to the first JSL
    });
    @memcpy(rom[0x0080..0x008D], &[_]u8{
        0xA9, 0x5C, // LDA #$5C
        0x8D, 0x12, 0x01, // STA $0112 (plain site: shifts to the window)
        0xA2, 0x10, 0x01, // LDX #$0110
        0x22, 0x00, 0x81, 0x00, // JSL $00:8100
        0x6B,
    });
    @memcpy(rom[0x00A0..0x00A8], &[_]u8{
        0xA2, 0x00, 0x82, // LDX #$8200 — past the mirror: a ROM walk
        0x22, 0x10, 0x81, 0x00, // JSL $00:8110
        0x6B,
    });
    // Two helpers with the SAME (op, operand, bank): they must share one
    // thunk body.
    @memcpy(rom[0x0100..0x0108], &[_]u8{
        0xBF, 0x02, 0x00, 0x00, // LDA $00:0002,X — the split site
        0x8D, 0x70, 0x01, // STA $0170
        0x6B,
    });
    @memcpy(rom[0x0110..0x0118], &[_]u8{
        0xBF, 0x02, 0x00, 0x00,
        0x8D, 0x74, 0x01, // STA $0174
        0x6B,
    });

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004 }) |a| markOp(bytes, a);
    for ([_]u32{ 0x8006, 0x800A, 0x800E }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x8080, 0x8082, 0x8085, 0x8088, 0x808C }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x80A0, 0x80A3, 0x80A7 }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x8100, 0x8104, 0x8107, 0x8110, 0x8114, 0x8117 }) |a| markOpX16(bytes, a);

    // No evidence: the shape alone decides.
    const sites = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(sites);
    @memset(sites, 0);

    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, bytes, sites, null, false, true, &.{}, false, 0, copy_reserve, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u16, 2), res.stats.idx_split_sites);
    try testing.expectEqual(@as(u8, 0x22), res.image[0x0100]); // JSL, same footprint
    try testing.expectEqual(@as(u8, 0x22), res.image[0x0110]);
    // One body, two callers.
    try testing.expectEqualSlices(u8, res.image[0x0101..0x0104], res.image[0x0111..0x0114]);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    for (0..5) |_| con.runFrame();
    // Small index: the read followed the store into the window.
    try testing.expectEqual(@as(u8, 0x5C), con.bus.sa1.bwram[0x0170]);
    // Huge index: the read still walked ROM.
    try testing.expectEqual(@as(u8, 0x5A), con.bus.sa1.bwram[0x0174]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0112]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0170]);
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
    const res = try convertWholeGame(gpa, rom, bytes, null, null, false, false, &.{}, false, 0, copy_reserve, &ref);
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

test "whole-game: --wg-expand grows the image and the new banks are usable padding" {
    const gpa = testing.allocator;
    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    const usage = try gpa.alloc(u8, 0x100_0000);
    defer gpa.free(usage);
    @memset(usage, 0);
    markOp(usage, 0x00_8000);

    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, usage, null, null, false, true, &.{}, false, 128 * 1024, copy_reserve, &ref);
    defer gpa.free(res.image);

    // The image doubled, and the header says so — without that the loader's
    // rom_mask folds the new banks straight back onto the old ones.
    try testing.expectEqual(@as(usize, 128 * 1024), res.image.len);
    try testing.expectEqual(@as(u32, 128 * 1024), res.stats.expanded_to);
    const hdr = try header_mod.detect(res.image);
    try testing.expectEqual(@as(u8, 7), res.image[hdr.offset + 0x17]); // log2(128 KiB / 1 KiB)

    // The new space is $FF — the only byte the pad allocator recognises as
    // free — so it shows up as one unbroken run, which is the whole point.
    for (res.image[rom.len..]) |b| try testing.expectEqual(@as(u8, 0xFF), b);
    const big = biggestRun(res.image, hdr.offset);
    try testing.expect(big.len >= 0x7FF0);
    try testing.expect(big.bank >= rom.len / 0x8000);

    // A grown image is still a valid cartridge.
    try testing.expectEqual(@as(u16, 0xFFFF), hdr.checksum ^ hdr.checksum_complement);
}

test "whole-game: --wg-expand of zero or less leaves the image alone" {
    const gpa = testing.allocator;
    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    const usage = try gpa.alloc(u8, 0x100_0000);
    defer gpa.free(usage);
    @memset(usage, 0);
    markOp(usage, 0x00_8000);

    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, usage, null, null, false, true, &.{}, false, 0, copy_reserve, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(rom.len, res.image.len);
    try testing.expectEqual(@as(u32, 0), res.stats.expanded_to);
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
    const res = convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, &ref) catch |e| {
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
        const r = try convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, &ref);
        defer gpa.free(r.image);
        try testing.expectEqual(@as(u16, 0x0902), std.mem.readInt(u16, r.image[0x000E..0x0010], .little));
    }
    // ...with it, the operand moves into the window like the covered one.
    {
        const r = try convertWholeGame(gpa, rom, usage, null, null, true, false, &.{}, false, 0, copy_reserve, &ref);
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
        const r = try convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, &ref);
        defer gpa.free(r.image);
        try testing.expect(r.stats.d_moved);
    }

    // An executed absolute operand that is neither WRAM, MMIO, nor ROM has
    // no home on the SA-1's bus in either window.
    @memset(usage, 0);
    usage[0x00_0900] = usage_map.flag_write; // select the BW-RAM window
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0xAD, 0x00, 0x44 }); // LDA $4400
    markOp(usage, 0x00_8100);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, &ref));
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
        const r = try convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, &ref);
        defer gpa.free(r.image);
        // The immediate moved into the window with everything else.
        try testing.expectEqual(@as(u16, wg_bw_window), std.mem.readInt(u16, r.image[0x0101..0x0103], .little));
    }
    // A bare PLD is the tail of an interrupt epilogue restoring a D that
    // was already shifted when it was pushed: allowed, and left alone.
    rom[0x0103] = 0xEA; // NOP where the push was
    {
        const r = try convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, &ref);
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
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, &ref));
    try testing.expectEqual(Reason.wg_dp_dynamic, ref.?.reason);

    @memset(usage, 0);
    usage[0x00_0900] = usage_map.flag_write;
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0x3B, 0x1B, 0x60 }); // TSC / TCS
    markOp(usage, 0x00_8100);
    markOp(usage, 0x00_8101);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, &ref));
    try testing.expectEqual(Reason.wg_stack_dynamic, ref.?.reason);
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0xEA, 0xEA, 0xEA });

    // An executed IRQ handler.
    @memset(usage, 0);
    std.mem.writeInt(u16, rom[0x7FC0 + 0x2E ..][0..2], 0x8100, .little);
    markOp(usage, 0x00_8100);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, &ref));
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
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, &ref));
    try testing.expectEqual(Reason.wg_nmi_ambiguous, ref.?.reason);
    std.mem.writeInt(u16, rom[0x7FC0 + 0x2A ..][0..2], 0, .little);
    std.mem.writeInt(u16, rom[0x7FC0 + 0x3A ..][0..2], 0, .little);

    // A read-modify-write on MMIO: not proxyable in place. (Plain indexed
    // stores and loads ARE, since the helper computes the effective
    // register at run time — Gradius III's `STA $210D,Y`, `LDY $4218,X`.)
    @memset(usage, 0);
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0x1E, 0x00, 0x21 });
    markOp(usage, 0x00_8100);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, &ref));
    try testing.expectEqual(Reason.wg_mmio_shape, ref.?.reason);

    // A long MMIO store: no room for the in-place JSR either.
    @memset(usage, 0);
    @memcpy(rom[0x0100..0x0104], &[_]u8{ 0x8F, 0x00, 0x21, 0x00 });
    markOp(usage, 0x00_8100);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, &ref));
    try testing.expectEqual(Reason.wg_mmio_shape, ref.?.reason);

    // An MMIO site executing outside bank $00 (this 64K image's bank $01).
    @memset(usage, 0);
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0xEA, 0xEA, 0xEA });
    markOp(usage, 0x00_8100);
    @memcpy(rom[0xFF00..0xFF03], &[_]u8{ 0x8D, 0x00, 0x21 });
    markOp(usage, 0x01_FF00);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, &ref));
    try testing.expectEqual(Reason.wg_mmio_outside_bank0, ref.?.reason);
    @memset(usage, 0);

    // A block move.
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0x54, 0x00, 0x7E });
    markOp(usage, 0x00_8100);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, &ref));
    try testing.expectEqual(Reason.wg_unsupported_op, ref.?.reason);
}
