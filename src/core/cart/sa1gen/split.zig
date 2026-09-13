//! The S5 mainline split: the I-RAM cell map the split and its pump share, the anchor-shape checks, and the emitters for the split scaffold, the IO ring readers, the math shadow and the IO bodies. See `SplitSpec` in sa1gen.zig.
//!
//! Carved out of sa1gen.zig as pure code motion; every declaration here is
//! re-exported from sa1gen.zig, which stays the module's public root.

const std = @import("std");
const usage_map = @import("../../usage_map.zig");
const sa1gen = @import("../sa1gen.zig");

const Error = sa1gen.Error;
const FarPad = sa1gen.FarPad;
const Refusal = sa1gen.Refusal;
const Result = sa1gen.Result;
const SplitSpec = sa1gen.SplitSpec;
const put = sa1gen.put;
const refuse = sa1gen.refuse;
const split_disp_max = sa1gen.split_disp_max;
const wg_bw_window = sa1gen.wg_bw_window;
const wg_window_shim_max = sa1gen.wg_window_shim_max;
/// File offset of a 24-bit LoROM code address (banks $00-$3F and their
/// $80-$BF mirrors alias the same bytes).
pub fn splitFile(a: u24) usize {
    return @as(usize, (a >> 16) & 0x7F) * 0x8000 + (@as(usize, a & 0xFFFF) - 0x8000);
}

/// Whether `a` names `span` bytes the split can read as LoROM code: the
/// upper half of a bank that exists in the image. The split's addresses
/// come straight from the command line (`--wg-split*`), so a mistyped one
/// has to be a refusal — `splitFile` on a low-half address underflows, and
/// on a bank past the image it indexes past `out`.
pub fn splitAddrInImage(image_len: usize, a: u24, span: usize) bool {
    if ((a & 0xFFFF) < 0x8000) return false;
    return splitFile(a) + span <= image_len;
}

/// Coverage flags of a site, whichever mirror the game ran it in.
pub fn splitUsage(usage: []const u8, a: u24) u8 {
    return usage[a] | usage[a ^ 0x80_0000];
}

/// The split's I-RAM cells, clear of the offload mailbox ($3780-$378F).
pub const split_ring_wr: u16 = 0x3790; // SA-1 appends
pub const split_ring_rd: u16 = 0x3791; // S-CPU drains
pub const split_vbl_mirror: u16 = 0x3792; // live $4212 image
pub const split_pad_mirror: u16 = 0x3794; // $4218-$421F, 8 bytes
pub const split_cell_d: u16 = 0x379C; // game D at engage
pub const split_cell_p: u16 = 0x36E8; // game P at engage -- NOT $379D: that is cell_d's high byte, and the engage stub's P store turned the game's D=$6000 into P<<8 (measured: D=$8100 at the first gameplay hand-over, the IRQ handler's LDX $AB read ROM, and the S-CPU jumped into $80:0000)
pub const split_cell_s: u16 = 0x379E; // game S at engage (16-bit)
pub const split_ring: u16 = 0x37A0; // 16 ids
pub const split_engaged: u16 = 0x37B0; // 0 until the S-CPU engages; the SA-1's laps through the anchor bounce off it
pub const split_scr_p: u16 = 0x37B1; // deferred-skip scratch (SA-1-exclusive: interrupt-free)
pub const split_scr_a: u16 = 0x37B2;
pub const split_token: u16 = 0x37B3; // the S-CPU NMI increments; the SA-1 frame loop edges on it
pub const split_last: u16 = 0x37B4; // the SA-1's copy of the last token it ran
pub const split_done: u16 = 0x37B5;
pub const split_cell_dbr: u16 = 0x37B6;
pub const split_rpc_ack: u16 = 0x37B7; // bumped AFTER a replayed body returns — the RPC release (rd consumes EARLY so nested drains cannot re-enter an in-service call) // the RPC caller's DBR (one call in flight, ever) // the last token whose tail COMPLETED — the head's gate
pub const split_cell_a: u16 = 0x37BC; // RPC caller A (16-bit)
pub const split_cell_x: u16 = 0x37BE; // RPC caller X — $9231 takes its VRAM fill target HERE
pub const split_cell_y: u16 = 0x37C0; // RPC caller Y — and its word count here
pub const split_cell_t: u16 = 0x37C2; // drain scratch: the dispatch pointer, so the caller's X can be restored before the call
pub const split_cell_pw: u16 = 0x37BA; // the RPC caller's P — replays must enter with the caller's M/X widths (a width-agnostic appender ran X8 and truncated its 16-bit cursor)
pub const split_in_replay: u16 = 0x37BB; // nonzero while a drain's replay is in flight: a nested NMI's mini-tok must not start another (a multi-frame sample stream nested 25 bytes deeper every frame)
pub const split_ring2_wr: u16 = 0x37B8; // fire-and-forget ring (sound family): slot index 0-11
pub const split_ring2_rd: u16 = 0x37B9;
pub const split_ring2: u16 = 0x3680; // 24 records of [id][D.lo][D.hi][pad] — bursts (a boss-area SFX barrage) lapped a 12-slot ring and the drain replayed a blank record
pub const split_sa1_stack: u16 = 0x3778; // the old dispatcher stack slot, free in split mode
pub const split_pump_stack: u16 = 0x37F0;
/// Mainloop flavor: the pump's stack lives in REAL WRAM (freed by the
/// relocation), not I-RAM — the stack page is the CPU discriminator, and
/// a pump on a $3xxx page would replay a body whose nested IO calls take
/// themselves for the SA-1 and enqueue to a drain that is busy with them.
pub const split_ml_pump_stack: u16 = 0x1EFF;
/// Mainloop flavor: the SA-1's stack top. The tail flavor's $3778 leaves
/// 120 bytes above the split's cells at $36E0; a game loop's call depth
/// wants more, and I-RAM below $3600 is free of every cell.
pub const split_ml_sa1_stack: u16 = 0x35FF;
/// The COP handler's direct page (16 bytes of I-RAM scratch).
pub const split_cop_dp: u16 = 0x3640;
// Inline-argument calls (a JSL followed by n data bytes the callee reads
// through its return address and skips on return — Super Metroid's
// $88:8435 and $80:91A9): the SA-1's stub captures the caller's return
// frame, the S-CPU's replay copies the n bytes into I-RAM behind a fake
// frame, and an RTL after them pops the drain's own frame.
pub const split_cell_ret: u16 = 0x3720; // the caller's pushed PC (2) and bank (1, +1 junk)
pub const split_args: u16 = 0x3724; // up to 8 argument bytes, then the RTL
pub const split_asc_a: u16 = 0x3730; // the replay helper's register parking
pub const split_asc_x: u16 = 0x3732;
pub const split_asc_y: u16 = 0x3734;
pub const split_cell_pret: u16 = 0x3736; // the P a replayed body returned with
pub const split_scr_pw: u16 = 0x3737; // scratch: the caller's widths
/// Mainloop flavor: the loop's context at the anchor when ownership
/// changes hands (A/X/Y here; D, DBR, P, S in the engage cells), and
/// the owner cell: 1 = the SA-1 runs the laps, 0 = the S-CPU does.
pub const split_ctx_a: u16 = 0x36E0;
pub const split_ctx_x: u16 = 0x36E2;
pub const split_ctx_y: u16 = 0x36E4;
pub const split_owner: u16 = 0x36E6;
/// The dispatch pointer's bank byte, right after `split_cell_t`.
pub const split_cell_tb: u16 = 0x37C4;
/// The math shadow (mainloop flavor): the S-CPU's multiplier/divider
/// registers as I-RAM cells the SA-1 side computes into — $4202/$4203
/// (multiplicands), $4204-$4206 (dividend, divisor; the byte after the
/// divisor stays zero so a 16-bit subtract reads it as such), then
/// $4214/$4215 (quotient) and $4216/$4217 (remainder / product).
pub const split_math_a: u16 = 0x36F0;
pub const split_math_div: u16 = 0x36F2;
pub const split_math_q: u16 = 0x36F6;
pub const split_math_r: u16 = 0x36F8;
// The PPU's mode-7 multiplier ($211B x $211C -> $2134-$2136), which games
// use as a signed 16x8 multiplier (Super Metroid's trig helper at
// $A9:C460: Ridley's tail collapsed onto one point without it). Cells in
// register order so the handler's offset arithmetic stays linear: off =
// reg - $20DB ($211B -> $40, $211C -> $41, $2134-6 -> $59-$5B).
pub const split_m7_last: u16 = 0x36FA; // the byte last written to $211B
pub const split_m7b: u16 = 0x36FB; // $211C, signed 8-bit
pub const split_m7_prod: u16 = 0x36FC; // $2134-$2136: the 24-bit signed product
pub const split_m7a: u16 = 0x36EA; // the composed 16-bit M7A (hi = last byte, lo = the latch before it)
pub const split_m7_latch: u16 = 0x36EC; // the write-twice latch

/// Convert for whole-game migration. Needs only the coverage map — no plan:
/// state stays at its own addresses inside the identity window.
/// A split anchor's displaced prefix must be whole instructions with no
/// flow op: both the enqueue stub and the pump trampoline re-execute
/// those bytes at a different address.
pub fn splitPrefixSpan(out: []const u8, usage: []const u8, entry: u24, need: u32) u32 {
    var pc: u32 = entry;
    while (pc - entry < need) {
        if ((pc & 0xFFFF) + 8 > 0x10000) return 0;
        const op = out[splitFile(@intCast(pc))];
        switch (op) {
            // Branches, jumps, bank-local calls, returns, PER/BRL: a copy
            // of these means something else. A JSL ($22) is position-
            // independent and returns into the copy, so it may ride.
            0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0, 0x80, 0x82, 0x62, 0x20, 0xFC, 0x4C, 0x5C, 0x6C, 0x7C, 0xDC, 0x60, 0x6B, 0x40, 0x00, 0x02, 0xCB, 0xDB => return 0,
            else => {},
        }
        const u = splitUsage(usage, @intCast(pc));
        const m8 = u & usage_map.flag_m != 0;
        const x8 = u & usage_map.flag_x != 0;
        pc += usage_map.instrLen(op, m8, x8);
    }
    // Anything past `need` is NOP-filled at the site, so the enqueue
    // stub's RTS (landing at entry+3) walks fill until the boundary.
    return if (pc - entry <= 8) pc - entry else 0;
}

/// S5: emit the mainline/NMI split scaffold into the bank-$00 carve
/// after the shim slot, swap the declared ranges' $4212/$421x reads to
/// the I-RAM mirrors, and displace the anchors. See `SplitSpec`.
pub fn emitSplit(
    out: []u8,
    usage: []const u8,
    spec: SplitSpec,
    d: []u8,
    base16: u16,
    far: *FarPad,
    carve: u32,
    carve_len: u32,
    refusal: *?Refusal,
    res: *Result,
) Error!void {
    // Every declared address must lie inside the image before anything
    // reads through it. `spec.tail` is a bank-$00 address and is indexed
    // as `out[tail - 0x8000]` below, so it gets the same bound.
    if (spec.tail == 0) {
        if (!splitAddrInImage(out.len, spec.mainloop, 16))
            return refuse(refusal, .{ .reason = .wg_split_shape, .detail = spec.mainloop });
    } else if (!splitAddrInImage(out.len, spec.tail, 16) or !splitAddrInImage(out.len, spec.tail_epilogue, 1)) {
        return refuse(refusal, .{ .reason = .wg_split_shape, .detail = spec.tail });
    }
    for (spec.io_entries) |io| {
        if (!splitAddrInImage(out.len, io.entry, 16))
            return refuse(refusal, .{ .reason = .wg_split_shape, .detail = io.entry });
    }
    for (spec.vbl_ranges) |r| {
        // `r[1]` is exclusive, so the last byte the walk reads is `r[1]-1`.
        if (r[1] <= r[0] or !splitAddrInImage(out.len, r[0], 1) or !splitAddrInImage(out.len, r[1] - 1, 1))
            return refuse(refusal, .{ .reason = .wg_split_shape, .detail = r[0] });
    }

    // Anchor shapes first: nothing is written until every check holds.
    if (spec.tail == 0) {
        if (splitPrefixSpan(out, usage, spec.mainloop, 4) < 4)
            return refuse(refusal, .{ .reason = .wg_split_shape, .detail = spec.mainloop });
    } else if (out[spec.tail - 0x8000] != 0x22 or spec.tail_epilogue == 0) {
        return refuse(refusal, .{ .reason = .wg_split_shape, .detail = spec.tail });
    }
    for (spec.io_entries) |io| {
        if (splitPrefixSpan(out, usage, io.entry, 3) == 0)
            return refuse(refusal, .{ .reason = .wg_split_shape, .detail = io.entry });
    }
    if (spec.io_entries.len > 40)
        return refuse(refusal, .{ .reason = .wg_split_shape, .detail = 0 });

    // Mirror swaps: absolute reads of $4212 -> $3792 and $4218-$421F ->
    // $3794+, inside the declared ranges only. The pump feeds the cells
    // continuously post-engage; boot-path readers outside the ranges
    // keep the real registers.
    var displaced: [512]Displaced = undefined;
    var n_displaced: u32 = 0;
    if (spec.tail == 0) {
        try emitSplitReaders(out, usage, spec, far, carve, carve_len, &displaced, &n_displaced, refusal);
    } else for (spec.vbl_ranges) |r| {
        var pc: u32 = r[0];
        while (pc < r[1]) {
            const f = splitFile(@intCast(pc));
            const op = out[f];
            const u = splitUsage(usage, @intCast(pc));
            const m8 = u & usage_map.flag_m != 0;
            const x8 = u & usage_map.flag_x != 0;
            const len = usage_map.instrLen(op, m8, x8);
            const md = usage_map.mode(op);
            if (len == 3 and (md == .abs or md == .abs_x or md == .abs_y)) {
                const v = std.mem.readInt(u16, out[f + 1 ..][0..2], .little);
                const nv: u16 = if (v == 0x4212)
                    split_vbl_mirror
                else if (v >= 0x4218 and v <= 0x421F)
                    split_pad_mirror + (v - 0x4218)
                else
                    0;
                if (nv != 0)
                    std.mem.writeInt(u16, out[f + 1 ..][0..2], nv, .little);
            }
            pc += len;
        }
    }

    // The S-CPU-multiplier idiom: a 16-bit STA $4202 (both multiplicands,
    // the high write triggering), the 8-cycle NOP wait, LDA $4216 for the
    // product. On the SA-1 those registers are open bus, so the span is
    // displaced with a JSL to a helper the engaged cell splits: the
    // original sequence pre-engage and on the pump, the SA-1's own
    // arithmetic unit ($2251+, immediate) on the mainline. Strict shape
    // only — anything looser is a named refusal, not a guess.
    var mul_sites: [4]u32 = undefined;
    var n_mul: usize = 0;
    var math_sites: [1024]MathSite = undefined;
    var n_math_sites: u32 = 0;
    // The DUAL IMAGE (mainloop flavor, 8 MiB images): the lower 4 MiB is
    // the S-CPU's game, stock bytes at every math site; the upper 4 MiB a
    // copy that carries the COP sites, and the mapper registers switch the
    // whole cartridge between them at each ownership handoff. Measured on
    // Super Metroid: with COPs in the one image, the S-CPU's own eras ran
    // ~150 cycles slower per math access, the Ceres intro gained lag
    // frames, and the frame-counter-fed state forked for good.
    const dual = spec.tail == 0 and out.len >= 8 * 1024 * 1024;
    if (spec.tail == 0) {
        try emitSplitMath(out, usage, far, carve, carve_len, spec.shared_sites, &math_sites, &n_math_sites, refusal, res);
    } else {
        var bank: u32 = 0;
        while (bank * 0x8000 < out.len and bank < 0x40) : (bank += 1) {
            var aa: u32 = 0x8000;
            while (aa < 0xFFF6) : (aa += 1) {
                const ac = (bank << 16) | aa;
                if ((usage[ac] | usage[0x80_0000 | ac]) & usage_map.flag_opcode == 0) continue;
                const file = bank * 0x8000 + (aa - 0x8000);
                if (!std.mem.eql(u8, out[file..][0..3], &.{ 0x8D, 0x02, 0x42 })) continue;
                // Only the FULL idiom is claimed. A bare STA $4202 (the
                // boot's register-clear sweep has eleven of them) is a
                // write that vanishes harmlessly on the SA-1; a product
                // READ without this shape shows up in the audit instead.
                if (!std.mem.eql(u8, out[file + 3 ..][0..4], &.{ 0xEA, 0xEA, 0xEA, 0xEA }) or
                    !std.mem.eql(u8, out[file + 7 ..][0..3], &.{ 0xAD, 0x16, 0x42 }))
                    continue;
                if (n_mul == mul_sites.len)
                    return refuse(refusal, .{ .reason = .wg_split_shape, .detail = ac });
                mul_sites[n_mul] = file;
                n_mul += 1;
            }
        }
    }

    var cur: usize = wg_window_shim_max;
    if (n_mul != 0) {
        // The helper, in the carve (JSL-reachable from every bank).
        const mul16: u16 = base16 + @as(u16, @intCast(cur));
        put(d, &cur, &.{ 0x48, 0xAF, @truncate(split_engaged), 0x37, 0x00 }); // PHA / LDA engaged (16-bit; the scratch neighbor masks off)
        put(d, &cur, &.{ 0x29, 0xFF, 0x00 }); // AND #$00FF
        put(d, &cur, &.{ 0xD0, 0x0C }); // BNE sa1 path
        put(d, &cur, &.{ 0x68, 0x8D, 0x02, 0x42 }); // PLA / STA $4202 — the original
        put(d, &cur, &.{ 0xEA, 0xEA, 0xEA, 0xEA }); // the hardware's 8 cycles
        put(d, &cur, &.{ 0xAD, 0x16, 0x42, 0x6B }); // LDA $4216 / RTL
        // sa1: the arithmetic unit — MA = low byte, MB = high byte.
        put(d, &cur, &.{ 0x68, 0x48, 0x29, 0xFF, 0x00 }); // PLA / PHA / AND #$00FF
        put(d, &cur, &.{ 0x8F, 0x51, 0x22, 0x00 }); // MA
        put(d, &cur, &.{ 0x68, 0xEB, 0x29, 0xFF, 0x00 }); // PLA / XBA / AND #$00FF
        put(d, &cur, &.{ 0x8F, 0x53, 0x22, 0x00 }); // MB — the $2254 write triggers
        put(d, &cur, &.{ 0xAF, 0x06, 0x23, 0x00, 0x6B }); // product / RTL
        for (mul_sites[0..n_mul]) |file| {
            out[file] = 0x22; // JSL helper
            std.mem.writeInt(u16, out[file + 1 ..][0..2], mul16, .little);
            out[file + 3] = 0x00;
            @memset(out[file + 4 ..][0..6], 0xEA);
        }
        res.stats.split_mul = @intCast(n_mul);
    }

    // The audit: covered WAI/STP (the SA-1 gets no interrupts, so a
    // mainline WAI never wakes), and any covered absolute MMIO read the
    // split leaves unhandled — open bus on the SA-1. Report, capped;
    // verification arbitrates what the operator accepts.
    {
        var bank: u32 = 0;
        while (bank * 0x8000 < out.len and bank < 0x40) : (bank += 1) {
            var aa: u32 = 0x8000;
            while (aa < 0x10000) : (aa += 1) {
                const ac = (bank << 16) | aa;
                if ((usage[ac] | usage[0x80_0000 | ac]) & usage_map.flag_opcode == 0) continue;
                const file = bank * 0x8000 + (aa - 0x8000);
                const op = out[file];
                var hazard = op == 0xCB or op == 0xDB;
                // every absolute read/compare/RMW form, plus the indexed reads
                // whose base sits in the register file (X unknown: unshadowed)
                const abs_read = switch (op) {
                    0xAD, 0xAC, 0xAE, 0x2C, 0xCD, 0x6D, 0xED, 0x2D, 0x0D, 0x4D, 0xEC, 0xCC => true, // loads, compares, ALU
                    0xEE, 0xCE, 0x0E, 0x4E, 0x2E, 0x6E, 0x0C, 0x1C => true, // RMW
                    0xBD, 0xBC, 0xBE, 0xB9, 0x7D, 0x79, 0xFD, 0xF9, 0xDD, 0xD9, 0x3D, 0x39, 0x1D, 0x19, 0x5D, 0x59, 0x3C => true, // indexed
                    0xAF, 0xBF, 0x6F, 0x7F, 0xEF, 0xFF, 0xCF, 0xDF, 0x2F, 0x3F, 0x0F, 0x1F, 0x4F, 0x5F => true, // long forms (a $00-bank long read of the register file)
                    else => false,
                };
                const long_form = op & 0x0F == 0x0F;
                if (!hazard and abs_read and (!long_form or (out[file + 3] & 0x7F) < 0x40)) {
                    const v = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                    hazard = (v >= 0x2100 and v <= 0x21FF) or (v >= 0x4200 and v <= 0x43FF);
                }
                if (hazard and res.stats.n_split_hazards < res.stats.split_hazards.len) {
                    res.stats.split_hazards[res.stats.n_split_hazards] = @intCast(ac);
                    res.stats.n_split_hazards += 1;
                }
            }
        }
    }

    if (spec.tail != 0) {
        // === NMI-TAIL FLAVOR (see SplitSpec.tail) =====================
        // --- tok stub: the S-CPU boundary, once per frame in vblank ---
        const tok16: u16 = base16 + @as(u16, @intCast(cur));
        // The boundary is reachable along MORE than the vectored head —
        // a transition path arrives with its own D (measured: D=0, three
        // frames into a stage banner) — and the drain's replayed bodies
        // are dp users. Pin the window D for the stub's whole span and
        // hand back whatever the caller had.
        put(d, &cur, &.{ 0x0B, 0xC2, 0x20, 0xA9, @truncate(wg_bw_window), @truncate(wg_bw_window >> 8), 0x5B }); // PHD; D = the window
        put(d, &cur, &.{0x8B}); // PHB
        put(d, &cur, &.{ 0xE2, 0x20 }); // SEP #$20 (M widths per the handler)
        // DBR = $00 EXPLICITLY — not PHK: under fastrom the boundary
        // executes from PBR=$80, and a PHK'd DBR sends every absolute
        // $37xx at a mirror whose I-RAM mapping is nobody's contract.
        // The offload stubs always went long for exactly this reason.
        put(d, &cur, &.{ 0xA9, 0x00, 0x48, 0xAB }); // LDA #$00 / PHA / PLB
        put(d, &cur, &.{ 0xAD, @truncate(split_engaged), 0x37 });
        const bne_at = cur;
        put(d, &cur, &.{ 0xD0, 0x00 }); // BNE engaged (patched)
        put(d, &cur, &.{ 0xA9, 0xFF, 0x8D, 0x29, 0x22 }); // SIWP open
        put(d, &cur, &.{ 0x9C, @truncate(split_ring_wr), 0x37, 0x9C, @truncate(split_ring_rd), 0x37 });
        put(d, &cur, &.{ 0x9C, @truncate(split_token), 0x37, 0x9C, @truncate(split_last), 0x37 });
        put(d, &cur, &.{ 0x9C, @truncate(split_in_replay), 0x37 });
        const crv_ref = cur;
        put(d, &cur, &.{ 0xA9, 0x00, 0x8D, 0x03, 0x22, 0xA9, 0x00, 0x8D, 0x04, 0x22 }); // CRV (patched)
        put(d, &cur, &.{ 0xA9, 0x01, 0x8D, @truncate(split_engaged), 0x37 }); // engaged = 1
        put(d, &cur, &.{ 0x9C, 0x00, 0x22 }); // release the SA-1
        d[bne_at + 1] = @intCast(cur - (bne_at + 2));
        // The boundary is ALSO reachable on the SA-1: the hazard audit
        // proves the tail re-enters the handler head ($8237's $4210 ack
        // is in its static reach), and that walk ends here. Without a
        // CPU test the SA-1 spins in the auto-joy wait on open bus — or
        // worse, bumps the token and wedges the gate arithmetic. The
        // SA-1 branch unwinds the pins and does exactly what the stock
        // boundary did: the displaced JSL, then the tail.
        put(d, &cur, &.{ 0xC2, 0x20, 0x3B, 0x29, 0x00, 0xF0, 0xC9, 0x00, 0x30 }); // TSC & $F000 == $3000?
        put(d, &cur, &.{ 0xD0, 0x03 }); // BNE over the BRL (not the SA-1)
        const tok_sa1_at = cur;
        put(d, &cur, &.{ 0x82, 0x00, 0x00 }); // BRL the SA-1 island (patched; past the pump's reach)
        put(d, &cur, &.{ 0xE2, 0x20 });
        // engaged: run the displaced boundary instruction — JSL $892B —
        // NATIVELY. The S-CPU polls the real pads at the game's own
        // cadence (the verifier pairs runs poll-for-poll, and a mirror
        // diet here left the baseline ~246 polls ahead through the
        // loader), and the results land in window dp cells the SA-1
        // tail reads directly. No pad mirrors at all.
        @memcpy(d[cur .. cur + 4], out[spec.tail - 0x8000 ..][0..4]);
        cur += 4;
        // M=8 FORCED after the replay: $892B returns wide, and a 16-bit
        // INC on the token treats token+last as one word — fine for 255
        // crossings, then the FF->00 carry clobbers `last` in the same
        // cycle and no edge ever reaches the SA-1 (measured: the wedge
        // at exactly the 256th crossing, frame 455).
        put(d, &cur, &.{ 0xE2, 0x20 });
        // MODE GATE: outside gameplay the tail runs nested-native (the
        // branch below unpins and runs the chain on this CPU). The dp
        // read goes through the pinned window D, the single home both
        // CPUs share. The token freezes across the era; the SA-1 idles
        // at its edge-gate and wakes when gameplay returns.
        // BEQ-over-BRL: the nested-native branch sits past the whole pump
        // loop (166 bytes measured), out of a short branch's reach — the
        // original BNE truncated to $A6 and jumped BACKWARD into the tok's
        // own bytes. It was never taken on a verified path; the mode gate
        // takes it every menu frame and wedged at engage (frame 232).
        var tok_mode_at: usize = 0;
        if (spec.mode_gate) {
            put(d, &cur, &.{ 0xA5, @truncate(spec.mode_cell), 0xC9, spec.mode_value });
            put(d, &cur, &.{ 0xF0, 0x03 }); // BEQ over the BRL
            tok_mode_at = cur;
            put(d, &cur, &.{ 0x82, 0x00, 0x00 }); // BRL the nested-native branch (patched)
        }
        // REENTRANT full path: the transition runs as a multi-frame NMI
        // ($3C is stock's own nesting guard and the transition handler
        // clears it mid-flight), so a real per-frame NMI can take the
        // full path while a tail — or a parked replay — is still in
        // flight beneath us. The SA-1 is busy then; dispatching a second
        // token deadlocks the nested gate on top of the very replay it
        // suspends (measured: tok=3/done=2, frame ~714). Stock ran the
        // nested tail on the S-CPU — so do exactly that: unpin and run
        // the chain natively; the stubs run bodies directly for S-CPU
        // callers, and the shared window makes the state evolution
        // identical.
        put(d, &cur, &.{ 0xAD, @truncate(split_done), 0x37, 0xCD, @truncate(split_token), 0x37 });
        put(d, &cur, &.{ 0xF0, 0x03 }); // BEQ over the BRL (done == token: dispatch)
        const tok_nest_at = cur;
        put(d, &cur, &.{ 0x82, 0x00, 0x00 }); // BRL the nested-native branch (patched)
        // Dispatch, then PUMP until the tail lands. A pure exit-wait
        // deadlocked (the SA-1's enqueued uploads starve without the
        // drain); pure non-blocking let the mainline overlap the tail
        // and the shared fade cells ($3A/$3E/$1280) diverged from tick
        // 3. The wait body IS the pump: each lap re-feeds the vbl
        // mirror live (stock's $892B reads $4212 live too) and replays
        // one ring entry, so the gate cannot starve what it waits on.
        put(d, &cur, &.{ 0xEE, @truncate(split_token), 0x37 }); // token++
        const drain16: u16 = base16 + @as(u16, @intCast(cur));
        // Widths are forced EVERY lap: a replayed body returns with
        // whatever REP it last executed (measured: $86E1 left m16, the
        // 8-bit ring compare read the vbl mirror as a high byte, and the
        // drain spun forever).
        put(d, &cur, &.{ 0xE2, 0x30 }); // SEP #$30
        put(d, &cur, &.{ 0xAD, @truncate(split_ring_rd), 0x37, 0xCD, @truncate(split_ring_wr), 0x37 });
        const beq2_at = cur;
        put(d, &cur, &.{ 0xF0, 0x00 }); // BEQ the done-check (patched)
        // rd consumes EARLY — a nested NMI's drain must see this entry
        // gone (re-entering an in-service call regressed forever); the
        // RPC release is the ACK bump after the body instead.
        put(d, &cur, &.{ 0xAA, 0xBD, @truncate(split_ring), 0x37, 0x48 });
        put(d, &cur, &.{ 0xE8, 0x8A, 0x29, 0x0F, 0x8D, @truncate(split_ring_rd), 0x37 });
        put(d, &cur, &.{ 0x68, 0x0A, 0xAA });
        // The pump's pinned DBR=$00 is the body's contract too: the
        // relocation shifts low-absolute operands into the $6000 window,
        // which every bank $00-$3F maps identically. The replay borrows
        // the CALLER's D (see the far stub's capture) — the body's dp
        // rewrites were made against it — then the pump's pins return.
        // The replay runs on a SCRATCH STACK (real WRAM — unused under
        // the relocation). RE-ENTRANT: a nested NMI's drain that arrives
        // already on the scratch page must NOT reset S to the top — that
        // trampled the outer replay's frames and the nested RTI popped
        // garbage (measured: P=$F5/PC=$02:8553, frame ~1131). Old S rides
        // on the stack either way, so the restore is uniform.
        // (original note follows)
        // the relocation, and a $1xxx page keeps the far stubs' CPU
        // discriminator honest). The game writes transition records into
        // its own FREED stack bytes; stock survives because its frames
        // sit below them, and our extra gate/trampoline depth moved a
        // return frame into the write zone (measured: an $A77B record
        // shredded the $7DE8 frame, frame ~714). Old S rides ON the
        // scratch stack, so nested drains unwind naturally.
        put(d, &cur, &.{ 0xC2, 0x30, 0x3B, 0xA8, 0x29, 0x00, 0xFF, 0xC9, 0x00, 0x1B, 0xF0, 0x04, 0xA9, 0xFF, 0x1B, 0x1B, 0x98, 0x48, 0xE2, 0x30 });
        put(d, &cur, &.{ 0xC2, 0x20, 0xAD, @truncate(split_cell_d), 0x37, 0x5B, 0xE2, 0x20 });
        // WIDTHS ONLY (AND #$30): the SA-1's P carries I=1 — it runs masked
        // by design — and PLPing it whole masked NMI on the S-CPU for the
        // replay's span; a multi-frame sample stream then lost every nested
        // frame its APU handshake depends on (measured: $9A68 spinning at
        // p=$04 with no NMI for 400K cycles, frame 745).
        // The dispatch pointer is fetched FIRST (it needs the drain's X),
        // then the caller's registers come back — A, X, Y from the stub's
        // capture, widths via P — and the call goes through the scratch
        // pointer, PEA giving it a JSR-shaped frame.
        put(d, &cur, &.{ 0xC2, 0x30 });
        const jsr2_at = cur;
        put(d, &cur, &.{ 0xBD, 0x00, 0x00 }); // LDA tbl,X — patched by emitSplitIo
        put(d, &cur, &.{ 0x8D, @truncate(split_cell_t), 0x37 });
        put(d, &cur, &.{ 0xAE, @truncate(split_cell_x), 0x37, 0xAC, @truncate(split_cell_y), 0x37 });
        put(d, &cur, &.{ 0xE2, 0x20 });
        put(d, &cur, &.{ 0xAD, @truncate(split_cell_pw), 0x37, 0x29, 0x30, 0x48 });
        put(d, &cur, &.{ 0xC2, 0x20, 0xAD, @truncate(split_cell_a), 0x37, 0x28 });
        const ret1: u16 = base16 + @as(u16, @intCast(cur)) + 6;
        put(d, &cur, &.{ 0xF4, @truncate(ret1 - 1), @truncate((ret1 - 1) >> 8) }); // PEA return-1
        put(d, &cur, &.{ 0x6C, @truncate(split_cell_t), 0x37 }); // JMP (cell_t)
        put(d, &cur, &.{ 0xE2, 0x30 }); // widths again — the body's REPs leak
        put(d, &cur, &.{ 0xA9, 0x00, 0x48, 0xAB });
        put(d, &cur, &.{ 0xC2, 0x20, 0xA9, @truncate(wg_bw_window), @truncate(wg_bw_window >> 8), 0x5B, 0xE2, 0x20 });
        put(d, &cur, &.{ 0xC2, 0x20, 0x68, 0x1B, 0xE2, 0x20 }); // old S back
        put(d, &cur, &.{ 0xEE, @truncate(split_rpc_ack), 0x37 }); // the RPC release
        put(d, &cur, &.{ 0x4C, @truncate(drain16), @truncate(drain16 >> 8) });
        d[beq2_at + 1] = @intCast(cur - (beq2_at + 2));
        // Ring-2 backpressure: at half-full, drain it here — the frame
        // exits that normally drain it don't happen while a multi-frame
        // transition keeps this gate closed.
        put(d, &cur, &.{ 0xAD, @truncate(split_ring2_wr), 0x37, 0x38, 0xED, @truncate(split_ring2_rd), 0x37 });
        put(d, &cur, &.{ 0xB0, 0x02, 0x69, 0x18 }); // mod-24 distance
        put(d, &cur, &.{ 0xC9, 0x0C });
        const r2bp_at = cur;
        put(d, &cur, &.{ 0x90, 0x03 }); // BCC past the call
        put(d, &cur, &.{ 0x20, 0x00, 0x00 }); // JSR r2 drain (patched)
        // Stock's overrun release, performed by the gate: $86CD parks a
        // waiter on $3C's bit7, and on stock the NEXT NMI's overrun path
        // rewrites $3C:=1 to release it. While the S-CPU is gated here
        // no such NMI can run — but the gate IS the NMI in progress, so
        // when the tail itself is the waiter (the SA-1 runs $86CD
        // natively), the gate makes stock's write for it.
        put(d, &cur, &.{ 0xA5, 0x3C, 0x10, 0x0A }); // dp via pinned D — BPL past the release
        put(d, &cur, &.{ 0xC2, 0x20, 0xA9, 0x01, 0x00, 0x85, 0x3C, 0xE2, 0x30, 0xEA });
        put(d, &cur, &.{ 0xAD, @truncate(split_done), 0x37, 0xCD, @truncate(split_token), 0x37 });
        // BEQ-over-BRL: the pump body outgrew a short branch's reach
        // (the Debug build panicked on the cast; ReleaseFast would have
        // emitted a silently wrong offset).
        put(d, &cur, &.{ 0xF0, 0x03 }); // BEQ done: fall out of the gate
        const back = @as(i32, @intCast(drain16)) - (@as(i32, @intCast(base16)) + @as(i32, @intCast(cur)) + 3);
        put(d, &cur, &.{ 0x82, @truncate(@as(u32, @bitCast(back))), @truncate(@as(u32, @bitCast(back)) >> 8) }); // BRL the pump head
        put(d, &cur, &.{ 0xC2, 0x10 }); // X wide again for the epilogue's pulls
        put(d, &cur, &.{ 0xAB, 0x2B }); // PLB, PLD — the caller's context back
        put(d, &cur, &.{ 0x4C, @truncate(spec.tail_epilogue), @truncate(spec.tail_epilogue >> 8) });
        // The nested-native branch: unpin, run the tail on THIS CPU (the
        // displaced boundary JSL above already made this frame's poll).
        std.mem.writeInt(u16, d[tok_nest_at + 1 ..][0..2], @intCast(cur - (tok_nest_at + 3)), .little);
        if (spec.mode_gate) std.mem.writeInt(u16, d[tok_mode_at + 1 ..][0..2], @intCast(cur - (tok_mode_at + 3)), .little);
        // The game's P first — the SA-1 path enters the tail with the P
        // captured at engage, and so must this CPU: the tok's own widths
        // (M8 for the token INC, X as the pins left it) leaked into the
        // chain, and $9231's 16-bit fill count in Y truncated to 8 bits
        // (measured: the option screen cleared 256 of each map's 1024
        // words and the menu logo stayed behind the text).
        put(d, &cur, &.{ 0xAD, @truncate(split_cell_p), @truncate(split_cell_p >> 8), 0x48, 0x28 }); // LDA cell_p / PHA / PLP
        put(d, &cur, &.{ 0xAB, 0x2B }); // PLB, PLD — the head's context
        put(d, &cur, &.{ 0x4C, @truncate(spec.tail + 4), @truncate((spec.tail + 4) >> 8) });
        // The SA-1 island: unwind the pins (the head's own D/B come
        // back) and run the tail. The displaced JSL $892B is SKIPPED on
        // this CPU — the SA-1 cannot poll pads, and the S-CPU's poll
        // this frame already filled the window cells the routine feeds.
        std.mem.writeInt(u16, d[tok_sa1_at + 1 ..][0..2], @intCast(cur - (tok_sa1_at + 3)), .little);
        put(d, &cur, &.{ 0xE2, 0x20 }); // M=8, as stock's boundary had it
        put(d, &cur, &.{ 0xAB, 0x2B }); // PLB, PLD
        put(d, &cur, &.{ 0x5C, @truncate(spec.tail + 4), @truncate((spec.tail + 4) >> 8), 0x00 }); // JML the tail proper

        // --- SA-1 prologue: gates, own I-RAM stack ---------------------
        const prologue16: u16 = base16 + @as(u16, @intCast(cur));
        d[crv_ref + 1] = @truncate(prologue16);
        d[crv_ref + 6] = @truncate(prologue16 >> 8);
        put(d, &cur, &.{ 0x78, 0x18, 0xFB }); // SEI / native
        put(d, &cur, &.{ 0xA9, 0xFF, 0x8D, 0x2A, 0x22 }); // CIWP
        put(d, &cur, &.{ 0xA9, 0x80, 0x8D, 0x27, 0x22 }); // CBWE
        put(d, &cur, &.{ 0x9C, 0x25, 0x22 }); // CBM block 0
        put(d, &cur, &.{ 0x9C, 0x50, 0x22 }); // ACM: multiply, for the helper
        put(d, &cur, &.{ 0xC2, 0x30 }); // REP #$30
        put(d, &cur, &.{ 0xA9, @truncate(split_sa1_stack), @truncate(split_sa1_stack >> 8), 0x1B });

        // --- the SA-1 frame loop --------------------------------------
        const sloop16: u16 = base16 + @as(u16, @intCast(cur));
        put(d, &cur, &.{ 0xE2, 0x20 }); // SEP #$20
        // publish: the RTI lands here, so `last` is a COMPLETED tail now
        put(d, &cur, &.{ 0xAF, @truncate(split_last), 0x37, 0x00 });
        put(d, &cur, &.{ 0x8F, @truncate(split_done), 0x37, 0x00 });
        put(d, &cur, &.{ 0xAF, @truncate(split_token), 0x37, 0x00 }); // wait:
        put(d, &cur, &.{ 0xCF, @truncate(split_last), 0x37, 0x00 });
        put(d, &cur, &.{ 0xF0, 0xF6 }); // BEQ the wait (-10)
        put(d, &cur, &.{ 0x8F, @truncate(split_last), 0x37, 0x00 });
        // Fake the handler frame the epilogue unwinds: the RTI comes
        // back HERE. RTI pulls P, PC, PBR — push PBR, PCH, PCL, P.
        put(d, &cur, &.{ 0xA9, 0x00, 0x48 }); // PBR
        put(d, &cur, &.{ 0xA9, @truncate(sloop16 >> 8), 0x48, 0xA9, @truncate(sloop16), 0x48 }); // PC
        put(d, &cur, &.{ 0xA9, 0x34, 0x48 }); // P: M8/X8/I
        // the pulls' dummies: A, X, Y (16-bit each), then D — which is
        // NOT the stock handler's zero: the window relocation's dp
        // scheme exists because the CONVERTED handler establishes
        // D=$6000, and a zero here sends every tail dp access into the
        // SA-1's I-RAM instead of the window (measured: the first boot
        // probe wrote $00:005C where the game meant window $605C).
        put(d, &cur, &.{ 0xC2, 0x30, 0xA9, 0x00, 0x00, 0x48, 0x48, 0x48 });
        put(d, &cur, &.{ 0xA9, @truncate(wg_bw_window), @truncate(wg_bw_window >> 8), 0x48 }); // the PLD's word
        put(d, &cur, &.{ 0xE2, 0x20, 0xA9, spec.tail_dbr, 0x48 }); // the PLB's byte
        // live context, as the CONVERTED handler set it: DBR and D
        put(d, &cur, &.{ 0xA9, spec.tail_dbr, 0x48, 0xAB }); // DBR
        put(d, &cur, &.{ 0xC2, 0x20, 0xA9, @truncate(wg_bw_window), @truncate(wg_bw_window >> 8), 0x5B, 0xE2, 0x20 }); // D = the window
        // into the tail — the displaced JSL $892B is the S-CPU's now
        // (it polls the real pads in the tok; the results are already
        // in the window when the token arrives here)
        put(d, &cur, &.{ 0x5C, @truncate(spec.tail + 4), @truncate((spec.tail + 4) >> 8), 0x00 });

        // --- mini-tok: unconditional per-frame service ----------------
        // The load-skip path never reaches the boundary, yet the SA-1's
        // loader waits on replays only the drain provides. All paths
        // converge on the epilogue, so its head is displaced onto this:
        // pins, mirror feed, drain, the displaced bytes, onward.
        const epi_span = splitPrefixSpan(out, usage, spec.tail_epilogue, 3);
        if (epi_span == 0)
            return refuse(refusal, .{ .reason = .wg_split_shape, .detail = spec.tail_epilogue });
        const mini16: u16 = base16 + @as(u16, @intCast(cur));

        // Both CPUs arrive here: every S-CPU handler exit, and the SA-1's
        // faked-frame return through the same epilogue. Only the S-CPU
        // feeds mirrors and drains; the SA-1 skips straight to the
        // displaced bytes (a pair of REPs -- harmless to repeat).
        put(d, &cur, &.{ 0xC2, 0x20, 0x3B, 0x29, 0x00, 0xF0, 0xC9, 0x00, 0x30 }); // TSC & $F000 == $3000?
        // BNE-over-BRL: the ring-2 drain pushed the target past a short
        // branch's +127 reach, and the u8 cast wrapped it into a silent
        // BACKWARD branch (measured: the SA-1 flew into BW-RAM-as-code).
        put(d, &cur, &.{ 0xD0, 0x03 }); // BNE past the BRL — the S-CPU path
        const msa1_at = cur;
        put(d, &cur, &.{ 0x82, 0x00, 0x00 }); // BRL the displaced epilogue (patched)
        put(d, &cur, &.{ 0x0B, 0xC2, 0x20, 0xA9, @truncate(wg_bw_window), @truncate(wg_bw_window >> 8), 0x5B }); // PHD; D = the window
        put(d, &cur, &.{ 0x8B, 0xE2, 0x20, 0xA9, 0x00, 0x48, 0xAB }); // PHB; DBR = $00
        // A nested NMI over an in-flight replay must not start another:
        // a sample stream replay spans frames, and per-frame nested
        // drains stacked streams 25 bytes deeper each frame until a
        // frame was corrupt (measured: $00:FFBC once per frame, S
        // 1b45/1b2c/1b13/1afa). The outer drain loops take the backlog.
        const mdrain16: u16 = base16 + @as(u16, @intCast(cur));
        put(d, &cur, &.{ 0xE2, 0x30 });
        put(d, &cur, &.{ 0xAD, @truncate(split_ring_rd), 0x37, 0xCD, @truncate(split_ring_wr), 0x37 });
        const mbeq_at = cur;
        put(d, &cur, &.{ 0xF0, 0x00 }); // BEQ out (patched)
        put(d, &cur, &.{ 0xAA, 0xBD, @truncate(split_ring), 0x37, 0x48 });
        put(d, &cur, &.{ 0xE8, 0x8A, 0x29, 0x0F, 0x8D, @truncate(split_ring_rd), 0x37 }); // rd consumes EARLY (see the tok drain)
        put(d, &cur, &.{ 0x68, 0x0A, 0xAA });
        put(d, &cur, &.{ 0xC2, 0x30, 0x3B, 0xA8, 0x29, 0x00, 0xFF, 0xC9, 0x00, 0x1B, 0xF0, 0x04, 0xA9, 0xFF, 0x1B, 0x1B, 0x98, 0x48, 0xE2, 0x30 }); // scratch stack (see the tok drain)
        put(d, &cur, &.{ 0xC2, 0x20, 0xAD, @truncate(split_cell_d), 0x37, 0x5B, 0xE2, 0x20 }); // caller D (see the far stub's capture)
        put(d, &cur, &.{ 0xC2, 0x30 }); // registers + dispatch: see the tok drain
        const mjsr_at = cur;
        put(d, &cur, &.{ 0xBD, 0x00, 0x00 }); // LDA tbl,X — patched by emitSplitIo
        put(d, &cur, &.{ 0x8D, @truncate(split_cell_t), 0x37 });
        put(d, &cur, &.{ 0xAE, @truncate(split_cell_x), 0x37, 0xAC, @truncate(split_cell_y), 0x37 });
        put(d, &cur, &.{ 0xE2, 0x20 });
        put(d, &cur, &.{ 0xAD, @truncate(split_cell_pw), 0x37, 0x29, 0x30, 0x48 });
        put(d, &cur, &.{ 0xC2, 0x20, 0xAD, @truncate(split_cell_a), 0x37, 0x28 });
        const mret1: u16 = base16 + @as(u16, @intCast(cur)) + 6;
        put(d, &cur, &.{ 0xF4, @truncate(mret1 - 1), @truncate((mret1 - 1) >> 8) }); // PEA return-1
        put(d, &cur, &.{ 0x6C, @truncate(split_cell_t), 0x37 }); // JMP (cell_t)
        put(d, &cur, &.{ 0xE2, 0x30 });
        put(d, &cur, &.{ 0xA9, 0x00, 0x48, 0xAB }); // pump DBR back
        put(d, &cur, &.{ 0xC2, 0x20, 0xA9, @truncate(wg_bw_window), @truncate(wg_bw_window >> 8), 0x5B, 0xE2, 0x20 }); // pump D back
        put(d, &cur, &.{ 0xC2, 0x20, 0x68, 0x1B, 0xE2, 0x20 }); // old S back
        put(d, &cur, &.{ 0xEE, @truncate(split_rpc_ack), 0x37 }); // the RPC release
        put(d, &cur, &.{ 0x4C, @truncate(mdrain16), @truncate(mdrain16 >> 8) });
        d[mbeq_at + 1] = @intCast(cur - (mbeq_at + 2));
        // Ring 2 — the fire-and-forget sound calls — drains HERE and
        // only here: the frame exit is stock's own phase for the
        // trailing sound dispatch, and pacing it anywhere earlier
        // skewed the APU echo family for hundreds of ticks.
        // Emitted as a SUBROUTINE: the mini-tok calls it at every frame
        // exit, and the GATE calls it under backpressure — a multi-frame
        // gated transition has no frame exits, and 24 slots overwrote
        // (measured: dropped sound dispatches overfilled the command
        // queue and its cursor walked into the dp floor at $46).
        const r2skip_at = cur;
        put(d, &cur, &.{ 0x80, 0x00 }); // BRA past the sub (patched)
        const r2_16: u16 = base16 + @as(u16, @intCast(cur));
        put(d, &cur, &.{ 0xE2, 0x30 });
        // Nesting guard, RING 2 ONLY: a sound stream spans frames and a
        // nested NMI starting another stacked them 25 bytes/frame. Ring
        // 1 (uploads) must still drain from a nested frame — each is
        // short and the scratch frame is stack-safe — or the uploads
        // land a frame late (measured: 1,476 divergent ticks from the
        // one 2-frame stream at frame 1126 when both rings were gated).
        put(d, &cur, &.{ 0xAD, @truncate(split_in_replay), 0x37 });
        const r2nest_at = cur;
        put(d, &cur, &.{ 0xD0, 0x00 }); // BNE out (patched)
        put(d, &cur, &.{ 0xAD, @truncate(split_ring2_rd), 0x37, 0xCD, @truncate(split_ring2_wr), 0x37 });
        const r2beq_at = cur;
        put(d, &cur, &.{ 0xF0, 0x00 }); // BEQ out (patched)
        put(d, &cur, &.{ 0x0A, 0x0A, 0xAA }); // slot*4 -> X
        put(d, &cur, &.{ 0xBD, @truncate(split_ring2), @truncate(split_ring2 >> 8), 0x48 }); // id pushed
        put(d, &cur, &.{ 0xC2, 0x20, 0xBD, @truncate(split_ring2 + 1), @truncate((split_ring2 + 1) >> 8), 0x5B, 0xE2, 0x20 }); // D := record.D
        put(d, &cur, &.{ 0xBD, @truncate(split_ring2 + 3), @truncate((split_ring2 + 3) >> 8), 0x8D, @truncate(split_cell_pw), 0x37 }); // record.P parked in the cell
        put(d, &cur, &.{ 0xAD, @truncate(split_ring2_rd), 0x37, 0x1A, 0xC9, 0x18, 0xD0, 0x02, 0xA9, 0x00 });
        put(d, &cur, &.{ 0x8D, @truncate(split_ring2_rd), 0x37 }); // rd2 bumped EARLY (nested-safe)
        put(d, &cur, &.{ 0x68, 0x0A, 0xAA }); // id*2 -> X
        put(d, &cur, &.{ 0xC2, 0x30, 0x3B, 0xA8, 0x29, 0x00, 0xFF, 0xC9, 0x00, 0x1B, 0xF0, 0x04, 0xA9, 0xFF, 0x1B, 0x1B, 0x98, 0x48, 0xE2, 0x30 }); // scratch stack
        put(d, &cur, &.{ 0xEE, @truncate(split_in_replay), 0x37 }); // in flight
        put(d, &cur, &.{ 0xAD, @truncate(split_cell_pw), 0x37, 0x29, 0x30, 0x48, 0x28 }); // caller P
        const r2jsr_at = cur;
        put(d, &cur, &.{ 0xFC, 0x00, 0x00 }); // JSR (tbl,X) — patched below
        put(d, &cur, &.{ 0xE2, 0x30 });
        put(d, &cur, &.{ 0xCE, @truncate(split_in_replay), 0x37 }); // landed
        put(d, &cur, &.{ 0xA9, 0x00, 0x48, 0xAB });
        put(d, &cur, &.{ 0xC2, 0x20, 0x68, 0x1B, 0xE2, 0x20 }); // old S back
        put(d, &cur, &.{ 0x4C, @truncate(r2_16), @truncate(r2_16 >> 8) });
        d[r2beq_at + 1] = @intCast(cur - (r2beq_at + 2));
        d[r2nest_at + 1] = @intCast(cur - (r2nest_at + 2));
        put(d, &cur, &.{ 0xC2, 0x20, 0xA9, @truncate(wg_bw_window), @truncate(wg_bw_window >> 8), 0x5B, 0xE2, 0x20 }); // pump D back
        put(d, &cur, &.{0x60}); // RTS — the drain sub's exit
        d[r2skip_at + 1] = @intCast(cur - (r2skip_at + 2));
        put(d, &cur, &.{ 0x20, @truncate(r2_16), @truncate(r2_16 >> 8) }); // the mini-tok's own call
        std.mem.writeInt(u16, d[r2bp_at + 3 ..][0..2], r2_16, .little); // the gate's backpressure call
        put(d, &cur, &.{ 0xC2, 0x10, 0xAB, 0x2B }); // X wide, PLB, PLD
        std.mem.writeInt(u16, d[msa1_at + 1 ..][0..2], @intCast(cur - (msa1_at + 3)), .little);
        @memcpy(d[cur .. cur + epi_span], out[spec.tail_epilogue - 0x8000 ..][0..epi_span]);
        cur += epi_span;
        put(d, &cur, &.{ 0x4C, @truncate(spec.tail_epilogue + @as(u16, @intCast(epi_span))), @truncate((spec.tail_epilogue + @as(u16, @intCast(epi_span))) >> 8) });

        // --- displace the boundary on the S-CPU side ------------------
        out[spec.tail - 0x8000] = 0x4C; // JMP tok (the JSL's 4th byte is unreachable)
        std.mem.writeInt(u16, out[spec.tail - 0x8000 + 1 ..][0..2], tok16, .little);
        // ... and the epilogue onto the mini-tok.
        out[spec.tail_epilogue - 0x8000] = 0x4C;
        std.mem.writeInt(u16, out[spec.tail_epilogue - 0x8000 + 1 ..][0..2], mini16, .little);
        if (epi_span > 3) @memset(out[spec.tail_epilogue - 0x8000 + 3 ..][0 .. epi_span - 3], 0xEA);
        res.stats.split_engage_addr = tok16;

        // --- the DMA-queue bank-slot translator -----------------------
        // The game's upload records carry their source bank as DATA — ROM
        // templates copied whole into the queue (the stage-2 boss's
        // sprite strips live at $01:90CB/D6/E3 with src bank $7F). No
        // static rewrite reaches a template only late-game code copies,
        // and no S-CPU harvest ever executes the SA-1-side builder — so
        // the CONSUMER translates: $8E00's one bank-slot store becomes a
        // thunk mapping $7E->$40, $7F->$41 at run time, correct for
        // every template the game will ever build a record from. The
        // site is M8 (the walker SEPs first), stores leave flags dead
        // (the next op is an immediate load), and the caller's DBR=$01
        // reaches the same $4304 mirror the store always hit.
        {
            const pat = [_]u8{ 0xBF, 0x08, 0x00, 0x40, 0x8D, 0x04, 0x43 };
            var site: ?usize = null;
            var sp: usize = 0;
            while (sp + pat.len <= 0x8000) : (sp += 1) {
                if (std.mem.eql(u8, out[sp .. sp + pat.len], &pat)) {
                    site = sp + 4;
                    break;
                }
            }
            if (site) |st| {
                const th16: u16 = base16 + @as(u16, @intCast(cur));
                put(d, &cur, &.{ 0xC9, 0x7E }); // CMP #$7E
                put(d, &cur, &.{ 0x90, 0x08 }); // BCC store
                put(d, &cur, &.{ 0xC9, 0x80 }); // CMP #$80
                put(d, &cur, &.{ 0xB0, 0x04 }); // BCS store
                put(d, &cur, &.{ 0x38, 0xE9, 0x3E }); // SEC / SBC #$3E
                put(d, &cur, &.{0xEA}); // pad: both branches land on the store
                put(d, &cur, &.{ 0x8D, 0x04, 0x43, 0x60 }); // STA $4304 / RTS
                out[st] = 0x20; // JSR thunk over the 3-byte STA
                std.mem.writeInt(u16, out[st + 1 ..][0..2], th16, .little);
            }
        }

        try emitSplitIo(out, usage, spec, d, &cur, base16, jsr2_at, far, refusal, res);
        std.mem.writeInt(u16, d[mjsr_at + 1 ..][0..2], std.mem.readInt(u16, d[jsr2_at + 1 ..][0..2], .little), .little);
        std.mem.writeInt(u16, d[r2jsr_at + 1 ..][0..2], std.mem.readInt(u16, d[jsr2_at + 1 ..][0..2], .little), .little);
        // A real refusal, not an assert: ReleaseFast strips asserts, and
        // an overflowing emission wrote through the shim and vectors.
        if (cur > wg_window_shim_max + split_disp_max)
            return refuse(refusal, .{ .reason = .wg_split_shape, .detail = @intCast(cur) });
        return;
    }

    // === MAINLOOP FLAVOR ==============================================
    // Ownership of the loop changes hands at the anchor, once per lap at
    // most: the SA-1 runs the laps while the mode cell says gameplay,
    // the S-CPU runs them natively otherwise (loads, transitions, menus —
    // the eras whose producer/consumer handshakes assume one CPU). While
    // the SA-1 owns the loop the S-CPU sits in the pump: mirrors, ring,
    // and the owner cell. Context (A/X/Y/P/D/DBR, and S on the S-CPU
    // side) crosses through I-RAM cells; each CPU keeps its own stack.
    const ml24 = spec.mainloop;
    const mlspan = splitPrefixSpan(out, usage, ml24, 4);
    const mode_home: u16 = if (spec.mode_cell < 0x2000) spec.mode_cell + 0x6000 else spec.mode_cell;

    // --- pump loop (S-CPU): mirrors, ring, owner --------------------
    const pump16: u16 = base16 + @as(u16, @intCast(cur));
    put(d, &cur, &.{ 0xE2, 0x30 }); // SEP #$30
    put(d, &cur, &.{ 0xAD, 0x12, 0x42, 0x8D, @truncate(split_vbl_mirror), @truncate(split_vbl_mirror >> 8) });
    // The PAD mirrors are NOT fed here: a read of $4218-$421F is a poll,
    // and the verifier pairs the two runs poll-for-poll — a pump reading
    // the pads thousands of times a frame generated ticks on frames stock
    // never polled (measured: a 4-frame tick skew and a fork from it).
    // The game's own poll feeds them: the reader helper the NMI handler's
    // pad read wears stores what it read (see emitSplitReaders).
    // The check-and-consume is a critical section: the NMI hook drains too,
    // and one interrupting between the pump's check and its consume would
    // take the entry and leave the pump replaying a stale slot. The
    // in-replay cell marks the section; the hook stands down while set.
    put(d, &cur, &.{ 0xEE, @truncate(split_in_replay), 0x37 }); // in_replay := 1
    const drain_call_at = cur;
    put(d, &cur, &.{ 0x20, 0x00, 0x00 }); // JSR drain_one (patched; returns at once when empty)
    put(d, &cur, &.{ 0x9C, @truncate(split_in_replay), 0x37 }); // in_replay := 0
    // Does the loop still belong to the SA-1? BNE-over-BRL: the takeover
    // sits past the drain routine and the NMI hook, out of a short branch's
    // reach (measured: the truncated offset branched backward into the
    // boot, and the game re-ran its reset path every frame).
    put(d, &cur, &.{ 0xAD, @truncate(split_owner), @truncate(split_owner >> 8) });
    put(d, &cur, &.{ 0xD0, 0x03 }); // BNE over the BRL
    const brl_take_at = cur;
    put(d, &cur, &.{ 0x82, 0x00, 0x00 }); // BRL takeover (patched)
    put(d, &cur, &.{ 0x4C, @truncate(pump16), @truncate(pump16 >> 8) });
    // drain_one (SEP #$30, DBR $00 on entry; RTS): one ring entry — the
    // caller's D/DBR/registers/widths come back from the stub's capture
    // (RPC serializes, so one cell set holds), the dispatch goes through a
    // 24-bit pointer with an RTL-shaped frame pushed by hand, and the
    // release is the ack bump after. Called by the pump, and by the NMI
    // hook: a deferred call made just before the S-CPU's NMI would else
    // wait the whole handler out, milliseconds per call.
    const drain16: u16 = base16 + @as(u16, @intCast(cur));
    std.mem.writeInt(u16, d[drain_call_at + 1 ..][0..2], drain16, .little);
    put(d, &cur, &.{ 0xAD, @truncate(split_ring_rd), 0x37, 0xCD, @truncate(split_ring_wr), 0x37 });
    const drain_empty_at = cur;
    put(d, &cur, &.{ 0xF0, 0x00 }); // BEQ the RTS (patched): nothing pending
    put(d, &cur, &.{ 0xAA, 0xBD, @truncate(split_ring), 0x37, 0x48 }); // TAX / LDA ring,X / PHA
    put(d, &cur, &.{ 0xE8, 0x8A, 0x29, 0x0F, 0x8D, @truncate(split_ring_rd), 0x37 }); // rd consumes early
    put(d, &cur, &.{ 0x68, 0x0A, 0x0A, 0xAA }); // PLA / ASL / ASL / TAX -- id*4
    put(d, &cur, &.{ 0xC2, 0x20 });
    const tbl_lo_at = cur;
    put(d, &cur, &.{ 0xBD, 0x00, 0x00 }); // LDA tbl,X (patched)
    put(d, &cur, &.{ 0x8D, @truncate(split_cell_t), 0x37 });
    put(d, &cur, &.{ 0xE2, 0x20 });
    const tbl_bank_at = cur;
    put(d, &cur, &.{ 0xBD, 0x00, 0x00 }); // LDA tbl+2,X (patched)
    put(d, &cur, &.{ 0x8D, @truncate(split_cell_tb), 0x37 });
    put(d, &cur, &.{ 0xC2, 0x20, 0xAD, @truncate(split_cell_d), 0x37, 0x5B }); // caller D
    put(d, &cur, &.{ 0xE2, 0x20, 0xAD, @truncate(split_cell_dbr), 0x37, 0x48, 0xAB }); // caller DBR
    put(d, &cur, &.{ 0xC2, 0x30, 0xAE, @truncate(split_cell_x), 0x37, 0xAC, @truncate(split_cell_y), 0x37 });
    put(d, &cur, &.{ 0xE2, 0x20, 0xAD, @truncate(split_cell_pw), 0x37, 0x29, 0x30, 0x48 }); // widths only
    put(d, &cur, &.{ 0xC2, 0x20, 0xAD, @truncate(split_cell_a), 0x37, 0x28 }); // A, then PLP
    const ret1: u16 = base16 + @as(u16, @intCast(cur)) + 7;
    put(d, &cur, &.{ 0x4B, 0xF4, @truncate(ret1 - 1), @truncate((ret1 - 1) >> 8) }); // PHK / PEA return-1
    put(d, &cur, &.{ 0xDC, @truncate(split_cell_t), 0x37 }); // JML [cell_t]
    std.debug.assert(base16 + @as(u16, @intCast(cur)) == ret1);
    put(d, &cur, &.{ 0x08, 0xE2, 0x20, 0x68, 0x8F, @truncate(split_cell_pret), @truncate(split_cell_pret >> 8), 0x00 }); // the body's P, for the caller
    put(d, &cur, &.{ 0xE2, 0x30, 0x4B, 0xAB }); // widths, DBR back
    put(d, &cur, &.{ 0xEE, @truncate(split_rpc_ack), 0x37 }); // the RPC release
    d[drain_empty_at + 1] = @intCast(cur - (drain_empty_at + 2));
    put(d, &cur, &.{0x60}); // RTS
    // --- the NMI hook: drain a pending entry before the game's handler ---
    // Everything the interrupted code had is put back before the JML, so
    // the handler's own RTI pops the original frame. Widths are unknown at
    // entry: PHP first, then REP #$30, so every push and pull is 16-bit.
    const nmi_vec = std.mem.readInt(u16, out[0x7FEA..0x7FEC], .little);
    const hook16: u16 = base16 + @as(u16, @intCast(cur));
    put(d, &cur, &.{ 0x08, 0xC2, 0x30, 0x48, 0xDA, 0x5A, 0x0B, 0x8B, 0x4B, 0xAB, 0xE2, 0x30 }); // PHP / REP / PHA PHX PHY PHD PHB / PHK PLB / SEP #$30
    put(d, &cur, &.{ 0xAD, @truncate(split_owner), @truncate(split_owner >> 8) }); // the SA-1 owns the loop?
    put(d, &cur, &.{ 0xF0, 0x08 }); // BEQ over the call: nothing to drain in the S-CPU's own eras
    put(d, &cur, &.{ 0xAD, @truncate(split_in_replay), 0x37 }); // the pump mid-drain? stand down
    put(d, &cur, &.{ 0xD0, 0x03 }); // BNE over the call
    put(d, &cur, &.{ 0x20, @truncate(drain16), @truncate(drain16 >> 8) });
    put(d, &cur, &.{ 0xC2, 0x30, 0xAB, 0x2B, 0x7A, 0xFA, 0x68, 0x28 }); // REP / PLB PLD PLY PLX PLA / PLP
    put(d, &cur, &.{ 0x5C, @truncate(nmi_vec), @truncate(nmi_vec >> 8), 0x00 }); // JML the game's handler
    std.mem.writeInt(u16, out[0x7FEA..0x7FEC], hook16, .little);
    // (No NMI hook in the S-CPU's copy. A pure-stock lower copy with a
    // per-NMI mode check was tried — s19h — and forked the tier's intro at
    // frame 2386: a hook on every NMI pays its ~45 cycles on every frame
    // of a long lag streak, and the intro's 51-frame load became 52
    // ($05BB, the record of consecutive lag frames). The anchor pays per
    // LAP — once for that load — and passes.)
    // takeover (S-CPU): the SA-1 handed the loop back — its context is
    // in the cells; the game stack is where the S-CPU left it.
    std.mem.writeInt(u16, d[brl_take_at + 1 ..][0..2], @intCast(cur - (brl_take_at + 3)), .little);
    if (dual) {
        // The S-CPU's copy back: megabytes 0/1/0/2 (SEP #$30 is live).
        put(d, &cur, &.{ 0xA9, 0x80, 0x8D, 0x20, 0x22, 0xA9, 0x81, 0x8D, 0x21, 0x22 });
        put(d, &cur, &.{ 0xA9, 0x80, 0x8D, 0x22, 0x22, 0xA9, 0x82, 0x8D, 0x23, 0x22 });
    }
    put(d, &cur, &.{ 0xC2, 0x30, 0xAD, @truncate(split_cell_s), 0x37, 0x1B }); // S
    put(d, &cur, &.{ 0xAD, @truncate(split_cell_d), 0x37, 0x5B }); // D
    put(d, &cur, &.{ 0xE2, 0x20, 0xAD, @truncate(split_cell_dbr), 0x37, 0x48, 0xAB }); // DBR
    put(d, &cur, &.{ 0xAD, @truncate(split_cell_p), @truncate(split_cell_p >> 8), 0x48 }); // P, pushed for the PLP
    put(d, &cur, &.{ 0xC2, 0x30, 0xAE, @truncate(split_ctx_x), @truncate(split_ctx_x >> 8), 0xAC, @truncate(split_ctx_y), @truncate(split_ctx_y >> 8) });
    put(d, &cur, &.{ 0xAD, @truncate(split_ctx_a), @truncate(split_ctx_a >> 8), 0x28 }); // A / PLP
    const take_jml_at = cur;
    put(d, &cur, &.{ 0x5C, 0x00, 0x00, 0x00 }); // JML tramp (patched)

    // --- engage (both CPUs, every lap, via the anchor's JML) ----------
    const engage16: u16 = base16 + @as(u16, @intCast(cur));
    put(d, &cur, &.{ 0x08, 0xC2, 0x20, 0x48 }); // PHP / REP #$20 / PHA
    put(d, &cur, &.{ 0x3B, 0x29, 0x00, 0xF0, 0xC9, 0x00, 0x30 }); // TSC & $F000 == $3000?
    put(d, &cur, &.{ 0xD0, 0x03 }); // BNE the S-CPU path
    const eng_sa1_at = cur;
    put(d, &cur, &.{ 0x82, 0x00, 0x00 }); // BRL the SA-1 arrival (patched)
    // S-CPU: the gate (I-RAM was opened by the shim at reset).
    put(d, &cur, &.{ 0xE2, 0x20 });
    var eng_native_at: usize = 0;
    var eng_native2_at: usize = 0;
    if (spec.mode_gate) {
        put(d, &cur, &.{ 0xC2, 0x20, 0xAF, @truncate(mode_home), @truncate(mode_home >> 8), 0x00 }); // LDA $00:home (16-bit)
        put(d, &cur, &.{ 0x29, 0xFF, 0x00, 0xC9, spec.mode_value, 0x00 }); // AND #$00FF / CMP #lo
        if (spec.mode_hi == 0) {
            put(d, &cur, &.{ 0xF0, 0x03 }); // BEQ hand over
            eng_native_at = cur;
            put(d, &cur, &.{ 0x82, 0x00, 0x00 }); // BRL native (patched)
        } else {
            // lo <= mode <= hi: below lo or above hi is native
            put(d, &cur, &.{ 0xB0, 0x03 }); // BCS on
            eng_native_at = cur;
            put(d, &cur, &.{ 0x82, 0x00, 0x00 }); // BRL native (patched)
            put(d, &cur, &.{ 0xC9, spec.mode_hi +% 1, 0x00, 0x90, 0x03 }); // CMP #hi+1 / BCC hand over
            eng_native2_at = cur;
            put(d, &cur, &.{ 0x82, 0x00, 0x00 }); // BRL native (patched)
        }
    }
    // hand over: publish the context, first-engage the SA-1 once, own := SA-1
    put(d, &cur, &.{ 0xC2, 0x30, 0x68, 0x8F, @truncate(split_ctx_a), @truncate(split_ctx_a >> 8), 0x00 }); // A
    put(d, &cur, &.{ 0x8A, 0x8F, @truncate(split_ctx_x), @truncate(split_ctx_x >> 8), 0x00 }); // X
    put(d, &cur, &.{ 0x98, 0x8F, @truncate(split_ctx_y), @truncate(split_ctx_y >> 8), 0x00 }); // Y
    put(d, &cur, &.{ 0x0B, 0x68, 0x8F, @truncate(split_cell_d), 0x37, 0x00 }); // D
    put(d, &cur, &.{ 0xE2, 0x20, 0x8B, 0x68, 0x8F, @truncate(split_cell_dbr), 0x37, 0x00 }); // DBR
    put(d, &cur, &.{ 0x68, 0x8F, @truncate(split_cell_p), @truncate(split_cell_p >> 8), 0x00 }); // P (pushed at entry)
    put(d, &cur, &.{ 0xC2, 0x20, 0x3B, 0x8F, @truncate(split_cell_s), 0x37, 0x00, 0xE2, 0x20 }); // S
    put(d, &cur, &.{ 0xAF, @truncate(split_engaged), 0x37, 0x00 });
    const eng_released_at = cur;
    put(d, &cur, &.{ 0xD0, 0x00 }); // BNE released (patched)
    put(d, &cur, &.{ 0x9C, @truncate(split_ring_wr), 0x37, 0x9C, @truncate(split_ring_rd), 0x37 }); // ring reset (DBR is the game's: I-RAM aliases in every bank < $40 / $80-$BF)
    put(d, &cur, &.{ 0x9C, @truncate(split_in_replay), 0x37 }); // no drain in flight
    put(d, &cur, &.{ 0xA9, 0x00, 0x8F, @truncate(split_owner), @truncate(split_owner >> 8), 0x00 }); // owner := S-CPU until the SA-1 waits
    const eng_crv_at = cur;
    put(d, &cur, &.{ 0xA9, 0x00, 0x8F, 0x03, 0x22, 0x00, 0xA9, 0x00, 0x8F, 0x04, 0x22, 0x00 }); // CRV (patched)
    put(d, &cur, &.{ 0xA9, 0x01, 0x8F, @truncate(split_engaged), 0x37, 0x00 }); // engaged := 1
    put(d, &cur, &.{ 0xA9, 0x00, 0x8F, 0x00, 0x22, 0x00 }); // release the SA-1
    d[eng_released_at + 1] = @intCast(cur - (eng_released_at + 2));
    if (dual) {
        // The SA-1's copy: regions C/D/E/F onto megabytes 4/5/4/6 (the
        // shim's own E/F choice, one copy up). Both CPUs sit in bank $00
        // code identical in both copies while this takes effect.
        put(d, &cur, &.{ 0xA9, 0x84, 0x8F, 0x20, 0x22, 0x00, 0xA9, 0x85, 0x8F, 0x21, 0x22, 0x00 });
        put(d, &cur, &.{ 0xA9, 0x84, 0x8F, 0x22, 0x22, 0x00, 0xA9, 0x86, 0x8F, 0x23, 0x22, 0x00 });
    }
    put(d, &cur, &.{ 0xA9, 0x01, 0x8F, @truncate(split_owner), @truncate(split_owner >> 8), 0x00 }); // owner := SA-1
    put(d, &cur, &.{ 0xC2, 0x20, 0xA9, @truncate(split_ml_pump_stack), @truncate(split_ml_pump_stack >> 8), 0x1B }); // the pump stack
    put(d, &cur, &.{ 0x4B, 0xAB, 0xE2, 0x30, 0x4C, @truncate(pump16), @truncate(pump16 >> 8) }); // DBR := $00, into the pump
    // native (S-CPU, mode gate says not gameplay): this CPU runs the lap.
    if (spec.mode_gate) std.mem.writeInt(u16, d[eng_native_at + 1 ..][0..2], @intCast(cur - (eng_native_at + 3)), .little);
    if (spec.mode_gate and spec.mode_hi != 0) std.mem.writeInt(u16, d[eng_native2_at + 1 ..][0..2], @intCast(cur - (eng_native2_at + 3)), .little);
    put(d, &cur, &.{ 0xC2, 0x20, 0x68, 0x28 }); // PLA / PLP
    const nat_jml_at = cur;
    put(d, &cur, &.{ 0x5C, 0x00, 0x00, 0x00 }); // JML tramp (patched)
    // the SA-1's arrival: gameplay -> the lap; else hand back and wait.
    std.mem.writeInt(u16, d[eng_sa1_at + 1 ..][0..2], @intCast(cur - (eng_sa1_at + 3)), .little);
    var sa1_back_at: usize = 0;
    var sa1_back2_at: usize = 0;
    if (spec.mode_gate) {
        put(d, &cur, &.{ 0xAF, @truncate(mode_home), @truncate(mode_home >> 8), 0x00 }); // 16-bit (REP #$20 is live)
        put(d, &cur, &.{ 0x29, 0xFF, 0x00, 0xC9, spec.mode_value, 0x00 });
        if (spec.mode_hi == 0) {
            sa1_back_at = cur;
            put(d, &cur, &.{ 0xD0, 0x00 }); // BNE hand back (patched)
        } else {
            sa1_back_at = cur;
            put(d, &cur, &.{ 0x90, 0x00 }); // BCC hand back (patched): below lo
            put(d, &cur, &.{ 0xC9, spec.mode_hi +% 1, 0x00 }); // CMP #hi+1
            sa1_back2_at = cur;
            put(d, &cur, &.{ 0xB0, 0x00 }); // BCS hand back (patched): above hi
        }
    }
    put(d, &cur, &.{ 0x68, 0x28 }); // PLA / PLP
    const sa1_lap_jml_at = cur;
    put(d, &cur, &.{ 0x5C, 0x00, 0x00, 0x00 }); // JML tramp (patched)
    var sa1_wait_jmp_at: usize = 0;
    if (spec.mode_gate) {
        d[sa1_back_at + 1] = @intCast(cur - (sa1_back_at + 2));
        if (spec.mode_hi != 0) d[sa1_back2_at + 1] = @intCast(cur - (sa1_back2_at + 2));
        put(d, &cur, &.{ 0xC2, 0x30, 0x68, 0x8F, @truncate(split_ctx_a), @truncate(split_ctx_a >> 8), 0x00 });
        put(d, &cur, &.{ 0x8A, 0x8F, @truncate(split_ctx_x), @truncate(split_ctx_x >> 8), 0x00 });
        put(d, &cur, &.{ 0x98, 0x8F, @truncate(split_ctx_y), @truncate(split_ctx_y >> 8), 0x00 });
        put(d, &cur, &.{ 0x0B, 0x68, 0x8F, @truncate(split_cell_d), 0x37, 0x00 });
        put(d, &cur, &.{ 0xE2, 0x20, 0x8B, 0x68, 0x8F, @truncate(split_cell_dbr), 0x37, 0x00 });
        put(d, &cur, &.{ 0x68, 0x8F, @truncate(split_cell_p), @truncate(split_cell_p >> 8), 0x00 });
        put(d, &cur, &.{ 0xA9, 0x00, 0x8F, @truncate(split_owner), @truncate(split_owner >> 8), 0x00 }); // owner := S-CPU, last
        sa1_wait_jmp_at = cur;
        put(d, &cur, &.{ 0x4C, 0x00, 0x00 }); // JMP the SA-1 wait (patched)
    }

    // --- SA-1 prologue: gates, own I-RAM stack, then wait for the loop --
    const prologue16: u16 = base16 + @as(u16, @intCast(cur));
    d[eng_crv_at + 1] = @truncate(prologue16);
    d[eng_crv_at + 7] = @truncate(prologue16 >> 8);
    put(d, &cur, &.{ 0x78, 0x18, 0xFB }); // SEI / native
    put(d, &cur, &.{ 0xA9, 0xFF, 0x8D, 0x2A, 0x22 }); // CIWP: I-RAM writable
    put(d, &cur, &.{ 0xA9, 0x80, 0x8D, 0x27, 0x22 }); // CBWE: BW-RAM writes
    put(d, &cur, &.{ 0x9C, 0x25, 0x22 }); // CBM block 0 -- the identity window
    put(d, &cur, &.{ 0x9C, 0x50, 0x22 }); // ACM: multiply mode, for the shadow
    put(d, &cur, &.{ 0xC2, 0x20, 0xA9, @truncate(split_ml_sa1_stack), @truncate(split_ml_sa1_stack >> 8), 0x1B });
    const sa1_wait16: u16 = base16 + @as(u16, @intCast(cur));
    if (spec.mode_gate) std.mem.writeInt(u16, d[sa1_wait_jmp_at + 1 ..][0..2], sa1_wait16, .little);
    put(d, &cur, &.{ 0xE2, 0x20, 0xAF, @truncate(split_owner), @truncate(split_owner >> 8), 0x00 }); // wait: owner == SA-1?
    put(d, &cur, &.{ 0xF0, 0xF8 }); // BEQ the wait (-8)
    put(d, &cur, &.{ 0xC2, 0x30, 0xAD, @truncate(split_cell_d), 0x37, 0x5B }); // D
    put(d, &cur, &.{ 0xE2, 0x20, 0xAD, @truncate(split_cell_dbr), 0x37, 0x48, 0xAB }); // DBR
    put(d, &cur, &.{ 0xAD, @truncate(split_cell_p), @truncate(split_cell_p >> 8), 0x48 }); // P for the PLP
    put(d, &cur, &.{ 0xC2, 0x30, 0xAE, @truncate(split_ctx_x), @truncate(split_ctx_x >> 8), 0xAC, @truncate(split_ctx_y), @truncate(split_ctx_y >> 8) });
    put(d, &cur, &.{ 0xAD, @truncate(split_ctx_a), @truncate(split_ctx_a >> 8), 0x28 }); // A / PLP
    const tramp16: u16 = base16 + @as(u16, @intCast(cur)) + 4;
    put(d, &cur, &.{ 0x5C, @truncate(tramp16), @truncate(tramp16 >> 8), 0x00 });
    // --- mainloop trampoline: the displaced bytes, then onward ---------
    std.debug.assert(base16 + @as(u16, @intCast(cur)) == tramp16);
    for ([_]usize{ take_jml_at, nat_jml_at, sa1_lap_jml_at }) |at| std.mem.writeInt(u16, d[at + 1 ..][0..2], tramp16, .little);
    @memcpy(d[cur .. cur + mlspan], out[splitFile(ml24)..][0..mlspan]);
    cur += mlspan;
    const onward: u24 = @intCast(@as(u32, ml24) + mlspan);
    put(d, &cur, &.{ 0x5C, @truncate(onward), @truncate(onward >> 8), @truncate(onward >> 16) });

    try emitSplitIoBanked(out, usage, spec, d, &cur, base16, tbl_lo_at, tbl_bank_at, far, carve, carve_len, &displaced, &n_displaced, refusal, res);

    if (cur > wg_window_shim_max + split_disp_max)
        return refuse(refusal, .{ .reason = .wg_split_shape, .detail = @intCast(cur) });

    // --- displace the mainloop anchor, last -----------------------------
    const mf = splitFile(ml24);
    out[mf] = 0x5C; // JML engage
    std.mem.writeInt(u16, out[mf + 1 ..][0..2], engage16, .little);
    out[mf + 3] = 0x00;
    if (mlspan > 4) @memset(out[mf + 4 ..][0 .. mlspan - 4], 0xEA);
    res.stats.split_engage_addr = engage16;

    if (dual) {
        // The SA-1's copy, COP sites and all; then the S-CPU's copy gets
        // its stock bytes back at every math site.
        const half: usize = 4 * 1024 * 1024;
        @memcpy(out[half .. 2 * half], out[0..half]);
        for (math_sites[0..n_math_sites]) |ms| {
            const f = splitFile(ms.addr);
            @memcpy(out[f..][0..ms.len], ms.bytes[0..ms.len]);
        }
        // ... and its IO entries and readers too: the S-CPU's own eras run
        // stock bytes everywhere but the anchor. (When the SA-1 owns the
        // loop the mapper shows the S-CPU the upper copy, whose stubs and
        // readers still serve its NMI handler and the pump's replays.)
        for (displaced[0..n_displaced]) |ds| {
            const f = splitFile(ds.addr);
            @memcpy(out[f..][0..ds.len], ds.bytes[0..ds.len]);
        }
        // The NMI hook too: only the SA-1's copy vectors NMI through it (the
        // vector lives in each copy's bank $00). The S-CPU's own eras run
        // the game's handler untouched — measured: the hook's ~70 cycles on
        // every intro NMI were enough to fork the intro. The anchor stays
        // in both copies: its cost is per lap, which a lag streak pays once.
        std.mem.writeInt(u16, out[0x7FEA..0x7FEC], nmi_vec, .little);
        res.stats.split_dual = true;
    }
}

/// The mainloop flavor's IO machinery, bank-general: for each routine a
/// drain trampoline and an enqueue stub in the ROUTINE'S OWN bank (its
/// RTS-shaped return and bank-local jumps stay sound), and a 24-bit
/// dispatch table in the carve the pump jumps through. Disciplines:
/// plain (the SA-1 runs the body too — its MMIO writes vanish — and the
/// pump replays it, no wait), `deferred` (the SA-1 skips the body and
/// waits for the replay: a handshake, or shared state that must land in
/// order). `ff` has no frame-exit phase to ride here and is treated as
/// deferred.
/// An inline-argument callee: `LDA $03,S` (its return address) ...
/// `ADC #n` ... `STA $03,S` (skipping the n bytes after the JSL). Returns n.
pub fn inlineArgs(out: []const u8, entry: u24) u8 {
    const f = splitFile(entry);
    if (f + 64 > out.len) return 0;
    const b = out[f..][0..64];
    var seen_lda = false;
    var n: u8 = 0;
    var i: usize = 0;
    while (i + 2 < b.len) : (i += 1) {
        if (b[i] == 0xA3 and b[i + 1] == 0x03) seen_lda = true;
        if (seen_lda and b[i] == 0x69 and b[i + 2] == 0x00 and b[i + 1] != 0 and b[i + 1] <= 8) n = b[i + 1];
        if (seen_lda and n != 0 and b[i] == 0x83 and b[i + 1] == 0x03) return n;
    }
    return 0;
}

pub fn emitSplitIoBanked(
    out: []u8,
    usage: []const u8,
    spec: SplitSpec,
    d: []u8,
    curp: *usize,
    base16: u16,
    tbl_lo_at: usize,
    tbl_bank_at: usize,
    far: *FarPad,
    carve: u32,
    carve_len: u32,
    disp: *[512]Displaced,
    n_disp: *u32,
    refusal: *?Refusal,
    res: *Result,
) Error!void {
    var cur = curp.*;
    var tramp24: [40]u24 = undefined;
    var stub16: [40]u16 = undefined;
    for (spec.io_entries, 0..) |io, i| {
        const span = splitPrefixSpan(out, usage, io.entry, 3);
        if (span == 0) return refuse(refusal, .{ .reason = .wg_split_shape, .detail = io.entry });
        const bank: u32 = (io.entry >> 16) & 0x7F;
        const e16: u16 = @truncate(io.entry);
        const bank_byte: u8 = @intCast(io.entry >> 16);
        const deferred = io.deferred or io.ff;
        const args = inlineArgs(out, io.entry);
        if (args != 0 and !(io.rtl and deferred)) return refuse(refusal, .{ .reason = .wg_split_shape, .detail = io.entry });
        if (args != 0) res.stats.split_inline_args += 1;

        // The trampoline: [JSR/JSL helper][RTL][helper: prefix; JMP body+span]
        // — or, for an inline-argument callee, [JSL far helper][helper...]:
        // the far helper copies the argument bytes behind a fake frame and
        // jumps into the helper (see split_args).
        var tb: [40]u8 = undefined;
        var tc: usize = 0;
        const t_need: u32 = if (args != 0) 4 + span + 3 else if (io.rtl) 5 + span + 3 else 4 + span + 3;
        const tat = far.nextIn(bank, t_need, if (bank == 0) carve else 0, if (bank == 0) carve_len else 0) orelse
            return refuse(refusal, .{ .reason = .no_free_space, .detail = t_need });
        const t16: u16 = @intCast(0x8000 + (tat % 0x8000));
        if (args != 0) {
            const helper: u24 = (@as(u24, bank_byte) << 16) | (t16 + 4);
            var ab: [160]u8 = undefined;
            var ac: usize = 0;
            put(&ab, &ac, &.{ 0x08, 0xC2, 0x30 }); // PHP / REP #$30
            put(&ab, &ac, &.{ 0x8F, @truncate(split_asc_a), @truncate(split_asc_a >> 8), 0x00 });
            put(&ab, &ac, &.{ 0x8A, 0x8F, @truncate(split_asc_x), @truncate(split_asc_x >> 8), 0x00 });
            put(&ab, &ac, &.{ 0x98, 0x8F, @truncate(split_asc_y), @truncate(split_asc_y >> 8), 0x00 });
            put(&ab, &ac, &.{ 0x0B, 0xF4, @truncate(split_cop_dp), @truncate(split_cop_dp >> 8), 0x2B }); // PHD / D := scratch
            put(&ab, &ac, &.{ 0xAF, @truncate(split_cell_ret), @truncate(split_cell_ret >> 8), 0x00, 0x1A, 0x85, 0x00 }); // ptr := ret + 1
            put(&ab, &ac, &.{ 0xE2, 0x20, 0xAF, @truncate(split_cell_ret + 2), @truncate((split_cell_ret + 2) >> 8), 0x00, 0x85, 0x02, 0xC2, 0x20 }); // bank
            put(&ab, &ac, &.{ 0xA0, 0x00, 0x00, 0xA2, 0x00, 0x00 });
            var k: u8 = 0;
            while (k < args) : (k += 2) {
                put(&ab, &ac, &.{ 0xB7, 0x00, 0x9F, @truncate(split_args), @truncate(split_args >> 8), 0x00, 0xC8, 0xC8, 0xE8, 0xE8 }); // LDA [$00],Y / STA args,X
            }
            put(&ab, &ac, &.{ 0xE2, 0x20, 0xA9, 0x6B, 0x8F, @truncate(split_args + args), @truncate((split_args + args) >> 8), 0x00, 0xC2, 0x20 }); // the RTL after them
            // the JSL frame (at $04,S past PHP and PHD) becomes the fake one
            put(&ab, &ac, &.{ 0xA9, @truncate(split_args - 1), @truncate((split_args - 1) >> 8), 0x83, 0x04 });
            // the frame's bank is the CALLER'S: a callee may record it as a data
            // bank (Super Metroid's HDMA-object spawner stores it beside the list
            // pointer it took from the arguments — measured: bank $00 there sent
            // the object's interpreter into ROM); I-RAM aliases in every code
            // bank, so the argument bytes and the RTL after them read the same.
            put(&ab, &ac, &.{ 0xE2, 0x20, 0xAF, @truncate(split_cell_ret + 2), @truncate((split_cell_ret + 2) >> 8), 0x00, 0x83, 0x06, 0xC2, 0x30, 0x2B }); // bank / PLD
            put(&ab, &ac, &.{ 0xAF, @truncate(split_asc_x), @truncate(split_asc_x >> 8), 0x00, 0xAA });
            put(&ab, &ac, &.{ 0xAF, @truncate(split_asc_y), @truncate(split_asc_y >> 8), 0x00, 0xA8 });
            put(&ab, &ac, &.{ 0xAF, @truncate(split_asc_a), @truncate(split_asc_a >> 8), 0x00, 0x28 }); // A, then PLP
            put(&ab, &ac, &.{ 0x5C, @truncate(helper), @truncate(helper >> 8), @truncate(helper >> 16) }); // JML helper
            const fat = far.next(@intCast(ac)) orelse return refuse(refusal, .{ .reason = .no_free_space, .detail = @intCast(ac) });
            @memcpy(out[fat .. fat + ac], ab[0..ac]);
            const far24: u24 = @intCast(((fat / 0x8000) << 16) | (0x8000 + (fat % 0x8000)));
            put(&tb, &tc, &.{ 0x22, @truncate(far24), @truncate(far24 >> 8), @truncate(far24 >> 16) }); // JSL far helper
        } else if (io.rtl) {
            const helper = t16 + 5;
            put(&tb, &tc, &.{ 0x22, @truncate(helper), @truncate(helper >> 8), bank_byte, 0x6B });
        } else {
            const helper = t16 + 4;
            put(&tb, &tc, &.{ 0x20, @truncate(helper), @truncate(helper >> 8), 0x6B });
        }
        @memcpy(tb[tc .. tc + span], out[splitFile(io.entry)..][0..span]);
        tc += span;
        put(&tb, &tc, &.{ 0x4C, @truncate(e16 + @as(u16, @intCast(span))), @truncate((e16 + @as(u16, @intCast(span))) >> 8) });
        std.debug.assert(tc == t_need);
        @memcpy(out[tat .. tat + tc], tb[0..tc]);
        tramp24[i] = (@as(u24, bank_byte) << 16) | t16;

        // The enqueue stub, in the same bank. The CPU test comes FIRST and
        // the S-CPU's path is an early exit (~35 cycles: measured, the full
        // capture on every native-era call cost a razor-edge transition lap
        // its vblank, one lag frame, and a permanent fork); only the SA-1
        // captures and enqueues.
        var fb: [200]u8 = undefined;
        var fc: usize = 0;
        put(&fb, &fc, &.{ 0x08, 0xC2, 0x20, 0x48, 0x3B, 0x29, 0x00, 0xF0, 0xC9, 0x00, 0x30 }); // PHP / REP #$20 / PHA / TSC & $F000 == $3000?
        const scpu_at = fc;
        put(&fb, &fc, &.{ 0xD0, 0x00 }); // BNE the S-CPU exit (patched)
        put(&fb, &fc, &.{ 0x68, 0x28 }); // PLA / PLP — the caller's A and P back
        // A comes back from the STACK, not from the cell: a cell store made
        // with SIWP closed bounces, and reading it back handed every
        // boot-time IO body a garbage A.
        put(&fb, &fc, &.{ 0x08, 0xC2, 0x30, 0x48 }); // PHP / REP #$30 / PHA
        if (args != 0) {
            // the game's JSL frame sits at $04,S: PC, then the bank
            put(&fb, &fc, &.{ 0xA3, 0x04, 0x8F, @truncate(split_cell_ret), @truncate(split_cell_ret >> 8), 0x00 });
            put(&fb, &fc, &.{ 0xA3, 0x06, 0x8F, @truncate(split_cell_ret + 2), @truncate((split_cell_ret + 2) >> 8), 0x00 });
        }
        put(&fb, &fc, &.{ 0x8F, @truncate(split_cell_a), 0x37, 0x00 });
        put(&fb, &fc, &.{ 0x98, 0x8F, @truncate(split_cell_y), 0x37, 0x00 }); // TYA
        put(&fb, &fc, &.{ 0x8A, 0x8F, @truncate(split_cell_x), 0x37, 0x00 }); // TXA
        put(&fb, &fc, &.{ 0x68, 0x28 }); // PLA / PLP — caller state fully intact
        put(&fb, &fc, &.{ 0x48, 0xDA, 0x5A, 0x08, 0xE2, 0x30 }); // PHA/PHX/PHY/PHP/SEP #$30
        // Caller D/DBR/P to the replay; enqueue; wait if deferred.
        put(&fb, &fc, &.{ 0xC2, 0x20, 0x0B, 0x68, 0x8F, @truncate(split_cell_d), 0x37, 0x00, 0xE2, 0x20 });
        put(&fb, &fc, &.{ 0x8B, 0x68, 0x8F, @truncate(split_cell_dbr), 0x37, 0x00 });
        put(&fb, &fc, &.{ 0xA3, 0x01, 0x8F, @truncate(split_cell_pw), 0x37, 0x00 }); // caller P
        put(&fb, &fc, &.{ 0xAF, @truncate(split_rpc_ack), 0x37, 0x00, 0x8F, @truncate(split_scr_a), 0x37, 0x00 }); // old ack
        put(&fb, &fc, &.{ 0xAF, @truncate(split_ring_wr), 0x37, 0x00, 0xAA }); // wr -> X
        put(&fb, &fc, &.{ 0xA9, @intCast(i), 0x9F, @truncate(split_ring), 0x37, 0x00 }); // id -> ring,X
        put(&fb, &fc, &.{ 0xE8, 0x8A, 0x29, 0x0F, 0x8F, @truncate(split_ring_wr), 0x37, 0x00 });
        if (deferred) {
            put(&fb, &fc, &.{ 0xAF, @truncate(split_rpc_ack), 0x37, 0x00 }); // spin: ack
            put(&fb, &fc, &.{ 0xCF, @truncate(split_scr_a), 0x37, 0x00 }); // still the old one?
            put(&fb, &fc, &.{ 0xF0, 0xF6 }); // BEQ spin
            // The flags the body returned with (a `CLC; RTL` is a return
            // value), under the caller's own widths — the pushes below
            // were made in those.
            put(&fb, &fc, &.{ 0xA3, 0x01, 0x29, 0x30, 0x8F, @truncate(split_scr_pw), @truncate(split_scr_pw >> 8), 0x00 });
            put(&fb, &fc, &.{ 0xAF, @truncate(split_cell_pret), @truncate(split_cell_pret >> 8), 0x00, 0x29, 0xCF });
            put(&fb, &fc, &.{ 0x0F, @truncate(split_scr_pw), @truncate(split_scr_pw >> 8), 0x00, 0x83, 0x01 });
            put(&fb, &fc, &.{ 0x28, 0x7A, 0xFA, 0x68 }); // PLP/PLX/PLA
            // ...and now the body's WIDTHS too. A routine's exit M/X can be
            // part of its contract: Super Metroid's `Open_MessageBox` opens
            // with `REP #$30` and returns without a PLP, and its caller,
            // arriving in 8-bit from the lag-frame player, goes straight
            // into a 16-bit `LDA MessageBoxIndex / CMP #$001C`. With the
            // caller's widths kept, that CMP ate one operand byte and the
            // leftover $00 ran as BRK: the SA-1 sat in the crash handler on
            // every item pickup with a message box (v74; findings §4q).
            // The pops above had to happen under the caller's widths (the
            // pushes were made in them); only after them is P free to become
            // the body's, in full. PHP / SEP #$20 / PHA / LDA pret /
            // STA $02,S / PLA / PLP: B is kept across the 8-bit hop, X/Y
            // untouched, and the pulled P is exactly what the body left.
            put(&fb, &fc, &.{ 0x08, 0xE2, 0x20, 0x48, 0xAF, @truncate(split_cell_pret), @truncate(split_cell_pret >> 8), 0x00, 0x83, 0x02, 0x68, 0x28 });
            if (args != 0) {
                // skip the inline bytes, as the body would have
                put(&fb, &fc, &.{ 0x08, 0xC2, 0x20, 0x48, 0xA3, 0x04, 0x18, 0x69, args, 0x00, 0x83, 0x04, 0x68, 0x28 });
            }
            put(&fb, &fc, &[_]u8{if (io.rtl) 0x6B else 0x60}); // pop the GAME frame, in the body's own bank
        } else {
            put(&fb, &fc, &.{ 0x28, 0x7A, 0xFA, 0x68 }); // PLP/PLX/PLA
            @memcpy(fb[fc .. fc + span], out[splitFile(io.entry)..][0..span]);
            fc += span;
            put(&fb, &fc, &.{ 0x4C, @truncate(e16 + @as(u16, @intCast(span))), @truncate((e16 + @as(u16, @intCast(span))) >> 8) }); // back into the body
        }
        // the S-CPU: A and P back, the prefix, the body
        fb[scpu_at + 1] = @intCast(fc - (scpu_at + 2));
        put(&fb, &fc, &.{ 0x68, 0x28 }); // PLA / PLP
        @memcpy(fb[fc .. fc + span], out[splitFile(io.entry)..][0..span]);
        fc += span;
        put(&fb, &fc, &.{ 0x4C, @truncate(e16 + @as(u16, @intCast(span))), @truncate((e16 + @as(u16, @intCast(span))) >> 8) }); // back into the body
        const sat = far.nextIn(bank, @intCast(fc), if (bank == 0) carve else 0, if (bank == 0) carve_len else 0) orelse
            return refuse(refusal, .{ .reason = .no_free_space, .detail = @intCast(fc) });
        @memcpy(out[sat .. sat + fc], fb[0..fc]);
        stub16[i] = @intCast(0x8000 + (sat % 0x8000));
    }
    // The dispatch table: 4-byte entries (lo, hi, bank, 0).
    const tbl16: u16 = base16 + @as(u16, @intCast(cur));
    for (spec.io_entries, 0..) |_, i| {
        put(d, &cur, &.{ @truncate(tramp24[i]), @truncate(tramp24[i] >> 8), @truncate(tramp24[i] >> 16), 0x00 });
    }
    std.mem.writeInt(u16, d[tbl_lo_at + 1 ..][0..2], tbl16, .little);
    std.mem.writeInt(u16, d[tbl_bank_at + 1 ..][0..2], tbl16 + 2, .little);

    // --- displacements, last: everything they jump into now exists ----
    for (spec.io_entries, 0..) |io, i| {
        const span = splitPrefixSpan(out, usage, io.entry, 3);
        const f = splitFile(io.entry);
        if (n_disp.* == disp.len) return refuse(refusal, .{ .reason = .wg_split_shape, .detail = io.entry });
        disp[n_disp.*] = .{ .addr = io.entry, .len = @intCast(span), .bytes = undefined };
        @memcpy(disp[n_disp.*].bytes[0..span], out[f..][0..span]);
        n_disp.* += 1;
        out[f] = 0x4C; // JMP stub — bank-local, frameless
        std.mem.writeInt(u16, out[f + 1 ..][0..2], stub16[i], .little);
        if (span > 3) @memset(out[f + 3 ..][0 .. span - 3], 0xEA);
    }
    res.stats.split_io = @intCast(spec.io_entries.len);
    curp.* = cur;
}

/// The mainloop flavor's `$4212` / joypad readers. A reader the game shares
/// between boot and gameplay (Super Metroid's four-vblank wait at
/// `$80:8436`, measured: the boot hung in it once the operand was swapped
/// to a mirror nobody fed yet) cannot simply read the mirror: on the
/// S-CPU the real register is right, always; only the SA-1 needs the
/// pump-fed cell. Each 3-byte absolute read of `$4212`/`$4218-$421F` in
/// the declared ranges becomes a bank-local JSR to a helper in the
/// site's bank that discriminates by stack page and performs the SAME
/// opcode against the register (S-CPU) or the mirror (SA-1, through a
/// long form when the opcode has one — the SA-1's DBR is whatever the
/// game left) after restoring the caller's P, so the flags the branch
/// after the read looks at are the load's own.
pub fn emitSplitReaders(out: []u8, usage: []const u8, spec: SplitSpec, far: *FarPad, carve: u32, carve_len: u32, disp: *[512]Displaced, n_disp: *u32, refusal: *?Refusal) Error!void {
    for (spec.vbl_ranges) |r| {
        // Keyed on the coverage map's instruction starts, not decoded from
        // the range's first byte: a range given by hand starts wherever it
        // starts (measured: a walk from mid-instruction missed $80:8525).
        var pc: u32 = r[0];
        while (pc < r[1]) : (pc += 1) {
            const f = splitFile(@intCast(pc));
            const op = out[f];
            const u = splitUsage(usage, @intCast(pc));
            const m8 = u & usage_map.flag_m != 0;
            const x8 = u & usage_map.flag_x != 0;
            const len = usage_map.instrLen(op, m8, x8);
            const is_read = switch (op) {
                0xAD, 0xAE, 0xAC, 0x2C, 0xCD, 0xEC, 0xCC, 0x0D, 0x2D, 0x4D, 0x6D, 0xED => true,
                else => false,
            };
            if (len == 3 and is_read and u & usage_map.flag_opcode != 0) {
                const v = std.mem.readInt(u16, out[f + 1 ..][0..2], .little);
                const mirror: u16 = if (v == 0x4212)
                    split_vbl_mirror
                else if (v >= 0x4218 and v <= 0x421F)
                    split_pad_mirror + (v - 0x4218)
                else
                    0;
                if (mirror != 0) {
                    // A-register ops have a long form (op | $02); the rest
                    // read the mirror through the DBR.
                    const long_op: ?u8 = switch (op) {
                        0xAD, 0xCD, 0x0D, 0x2D, 0x4D, 0x6D, 0xED => op | 0x02,
                        else => null,
                    };
                    var hb: [40]u8 = undefined;
                    var hc: usize = 0;
                    put(&hb, &hc, &.{ 0x08, 0xC2, 0x20, 0x3B, 0x29, 0x00, 0xF0, 0xC9, 0x00, 0x30 }); // PHP / REP #$20 / TSC / AND / CMP
                    // A pad LOAD on the S-CPU also feeds the mirror (STA/STX/STY
                    // leave the flags alone, so the branch after the read still
                    // sees the load's own): the game's poll is the feed.
                    const feed_op: ?u8 = if (v >= 0x4218) switch (op) {
                        0xAD => @as(u8, 0x8F), // STA long
                        0xAE => @as(u8, 0x8E), // STX abs (I-RAM aliases in every code bank)
                        0xAC => @as(u8, 0x8C), // STY abs
                        else => null,
                    } else null;
                    const scpu_len: u8 = if (feed_op) |fo| (if (fo == 0x8F) 9 else 8) else 5;
                    put(&hb, &hc, &.{ 0xF0, scpu_len }); // BEQ the SA-1 read
                    put(&hb, &hc, &.{ 0x28, op, @truncate(v), @truncate(v >> 8) }); // PLP / the read, real
                    if (feed_op) |fo| {
                        if (fo == 0x8F) {
                            put(&hb, &hc, &.{ 0x8F, @truncate(mirror), @truncate(mirror >> 8), 0x00 });
                        } else {
                            put(&hb, &hc, &.{ fo, @truncate(mirror), @truncate(mirror >> 8) });
                        }
                    }
                    put(&hb, &hc, &.{0x60}); // RTS
                    if (long_op) |lo| {
                        put(&hb, &hc, &.{ 0x28, lo, @truncate(mirror), @truncate(mirror >> 8), 0x00, 0x60 });
                    } else {
                        put(&hb, &hc, &.{ 0x28, op, @truncate(mirror), @truncate(mirror >> 8), 0x60 });
                    }
                    const bank: u32 = (pc >> 16) & 0x7F;
                    const at = far.nextIn(bank, @intCast(hc), if (bank == 0) carve else 0, if (bank == 0) carve_len else 0) orelse
                        return refuse(refusal, .{ .reason = .no_free_space, .detail = @intCast(hc) });
                    @memcpy(out[at .. at + hc], hb[0..hc]);
                    const h16: u16 = @intCast(0x8000 + (at % 0x8000));
                    if (n_disp.* == disp.len) return refuse(refusal, .{ .reason = .wg_split_shape, .detail = @intCast(pc) });
                    disp[n_disp.*] = .{ .addr = @intCast(pc), .len = 3, .bytes = undefined };
                    @memcpy(disp[n_disp.*].bytes[0..3], out[f..][0..3]);
                    n_disp.* += 1;
                    out[f] = 0x20; // JSR helper — bank-local, the same 3 bytes
                    std.mem.writeInt(u16, out[f + 1 ..][0..2], h16, .little);
                }
            }
        }
    }
}

/// The math shadow (mainloop flavor). The S-CPU's multiplier and divider
/// ($4202-$4206 in, $4214-$4217 out) are open bus on the SA-1, and the
/// game loop uses them from dozens of sites in no fixed idiom (measured
/// on Super Metroid: 46-70 touches per frame). Each covered absolute
/// store or load of those registers is displaced with a JSL to a helper
/// that runs the original instruction on the S-CPU and, on the SA-1
/// (stack page $3xxx), the same access against I-RAM cells — a write of
/// $4203 computing the 8x8 product through the SA-1's arithmetic unit,
/// a write of $4206 the unsigned 16/8 quotient and remainder in software
/// (exact, divide-by-zero included: quotient $FFFF, remainder the
/// dividend). Each site is displaced by a bank-local JSR (the same 3
/// bytes) to a helper in its own bank; no neighbouring instruction is
/// copied.
/// A site the split displaced, with the bytes it replaced — so the
/// S-CPU's copy of the game can have them back (see the dual image).
pub const MathSite = struct { addr: u24, len: u8, bytes: [8]u8 };
pub const Displaced = struct { addr: u24, len: u8, bytes: [8]u8 };

/// Whether any covered branch, jump or call in `addr`'s bank lands on
/// `addr` — a displaced instruction there would be skipped by that path.
pub fn splitTargeted(out: []const u8, usage: []const u8, addr: u24) bool {
    const bank: u32 = (addr >> 16) & 0x7F;
    const a16: u16 = @truncate(addr);
    var pc: u32 = 0x8000;
    while (pc < 0x10000) : (pc += 1) {
        const ac: u24 = @intCast((bank << 16) | pc);
        const u = splitUsage(usage, ac);
        if (u & usage_map.flag_opcode == 0) continue;
        const f = splitFile(ac);
        const op = out[f];
        switch (op) {
            0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0, 0x80 => {
                const rel: i8 = @bitCast(out[f + 1]);
                const t: i32 = @as(i32, @intCast(pc)) + 2 + rel;
                if (t == a16) return true;
            },
            0x82, 0x62 => {
                const rel: i16 = @bitCast(std.mem.readInt(u16, out[f + 1 ..][0..2], .little));
                const t: i32 = @as(i32, @intCast(pc)) + 3 + rel;
                if (t == a16) return true;
            },
            0x4C, 0x20 => {
                if (std.mem.readInt(u16, out[f + 1 ..][0..2], .little) == a16) return true;
            },
            0x5C, 0x22 => {
                if (std.mem.readInt(u16, out[f + 1 ..][0..2], .little) == a16 and (out[f + 3] & 0x7F) == bank) return true;
            },
            else => {},
        }
    }
    return false;
}

pub fn emitSplitMath(out: []u8, usage: []const u8, far: *FarPad, carve: u32, carve_len: u32, shared: []const u24, sites: *[1024]MathSite, n_out: *u32, refusal: *?Refusal, res: *Result) Error!void {
    // The shared calculators, once.
    var calc: [224]u8 = undefined;
    var cc: usize = 0;
    // mulcalc: product := A-cell * B-cell (8x8 unsigned fits the signed 16x16 unit)
    put(&calc, &cc, &.{ 0x08, 0xC2, 0x20, 0x48, 0xE2, 0x20 }); // PHP / REP #$20 / PHA / SEP #$20
    put(&calc, &cc, &.{ 0xAF, @truncate(split_math_a), @truncate(split_math_a >> 8), 0x00, 0x8D, 0x51, 0x22, 0x9C, 0x52, 0x22 }); // MA
    put(&calc, &cc, &.{ 0xAF, @truncate(split_math_a + 1), @truncate((split_math_a + 1) >> 8), 0x00, 0x8D, 0x53, 0x22, 0x9C, 0x54, 0x22 }); // MB (triggers)
    put(&calc, &cc, &.{ 0xEA, 0xEA, 0xEA, 0xC2, 0x20, 0xAD, 0x06, 0x23 }); // the unit's 5 cycles; product low word
    put(&calc, &cc, &.{ 0x8F, @truncate(split_math_r), @truncate(split_math_r >> 8), 0x00, 0x68, 0x28, 0x6B }); // -> remainder/product cells; PLA/PLP/RTL
    const mul_len = cc;
    // divcalc: unsigned 16/8, restoring shift-subtract, 16 rounds
    put(&calc, &cc, &.{ 0x08, 0xC2, 0x30, 0x48, 0xDA, 0xE2, 0x20 }); // PHP / REP #$30 / PHA / PHX / SEP #$20
    put(&calc, &cc, &.{ 0xAF, @truncate(split_math_div + 2), @truncate((split_math_div + 2) >> 8), 0x00 }); // divisor
    put(&calc, &cc, &.{ 0xD0, 0x0F }); // BNE ok
    put(&calc, &cc, &.{ 0xC2, 0x20, 0xA9, 0xFF, 0xFF, 0x8F, @truncate(split_math_q), @truncate(split_math_q >> 8), 0x00 }); // q := $FFFF
    put(&calc, &cc, &.{ 0xAF, @truncate(split_math_div), @truncate(split_math_div >> 8), 0x00 }); // r := dividend
    put(&calc, &cc, &.{ 0x80, 0x24 }); // BRA store-r (patched below by construction)
    // ok:
    put(&calc, &cc, &.{ 0xC2, 0x20, 0xAF, @truncate(split_math_div), @truncate(split_math_div >> 8), 0x00 }); // dividend
    // The SA-1's own divider for a dividend below $8000 (its dividend is
    // signed): 5 cycles where the shift-subtract loop below cost ~400 —
    // measured: that loop was 45% of a door transition's SA-1 time, and the
    // transitions ran slower than stock's. Divisor's high byte is zero (the
    // cell past it). Divide mode on ($2250 bit 1), multiply mode back after.
    put(&calc, &cc, &.{ 0x30, 0x33 }); // BMI the software path
    put(&calc, &cc, &.{ 0xE2, 0x20, 0xA9, 0x01, 0x8D, 0x50, 0x22, 0xC2, 0x20 }); // MCNT := divide (bit 0; bit 1 is the accumulate mode)
    put(&calc, &cc, &.{ 0xAF, @truncate(split_math_div), @truncate((split_math_div) >> 8), 0x00, 0x8D, 0x51, 0x22 }); // MA := dividend (reloaded: the mode write went through A)
    put(&calc, &cc, &.{ 0xAF, @truncate(split_math_div + 2), @truncate((split_math_div + 2) >> 8), 0x00 }); // divisor (16-bit, high byte zero)
    put(&calc, &cc, &.{ 0x8D, 0x53, 0x22 }); // MB (the $2254 write triggers)
    put(&calc, &cc, &.{ 0xEA, 0xEA, 0xEA }); // the unit's 5 cycles
    put(&calc, &cc, &.{ 0xAD, 0x06, 0x23, 0x8F, @truncate(split_math_q), @truncate(split_math_q >> 8), 0x00 }); // quotient
    put(&calc, &cc, &.{ 0xAD, 0x08, 0x23, 0x8F, @truncate(split_math_r), @truncate(split_math_r >> 8), 0x00 }); // remainder
    put(&calc, &cc, &.{ 0xE2, 0x20, 0x9C, 0x50, 0x22, 0xC2, 0x20 }); // ACM := multiply
    put(&calc, &cc, &.{ 0xFA, 0x68, 0x28, 0x6B }); // PLX / PLA / PLP / RTL
    // software path (dividend >= $8000): restoring shift-subtract, 16 rounds
    put(&calc, &cc, &.{ 0x8F, @truncate(split_math_q), @truncate(split_math_q >> 8), 0x00 }); // q := dividend (shift register)
    put(&calc, &cc, &.{ 0xA9, 0x00, 0x00, 0x8F, @truncate(split_math_r), @truncate(split_math_r >> 8), 0x00 }); // r := 0
    put(&calc, &cc, &.{ 0xA2, 0x10, 0x00 }); // LDX #16
    const loop_at = cc;
    put(&calc, &cc, &.{ 0x0E, @truncate(split_math_q), @truncate(split_math_q >> 8) }); // ASL q (DBR-relative: I-RAM aliases in every code bank)
    put(&calc, &cc, &.{ 0x2E, @truncate(split_math_r), @truncate(split_math_r >> 8) }); // ROL r
    put(&calc, &cc, &.{ 0xAD, @truncate(split_math_r), @truncate(split_math_r >> 8), 0x38, 0xED, @truncate(split_math_div + 2), @truncate((split_math_div + 2) >> 8) }); // r - divisor (the byte past it is zero)
    put(&calc, &cc, &.{ 0x90, 0x06 }); // BCC skip
    put(&calc, &cc, &.{ 0x8D, @truncate(split_math_r), @truncate(split_math_r >> 8), 0xEE, @truncate(split_math_q), @truncate(split_math_q >> 8) }); // r := diff; INC q
    put(&calc, &cc, &.{0xCA}); // DEX
    const back: i32 = @as(i32, @intCast(loop_at)) - (@as(i32, @intCast(cc)) + 2);
    put(&calc, &cc, &.{ 0xD0, @bitCast(@as(i8, @intCast(back))) }); // BNE loop
    put(&calc, &cc, &.{ 0xFA, 0x68, 0x28, 0x6B }); // PLX / PLA / PLP / RTL
    // the zero-divisor branch's store-r lands on a PLX: give it its own tail
    const zero_tail = cc;
    put(&calc, &cc, &.{ 0x8F, @truncate(split_math_r), @truncate(split_math_r >> 8), 0x00, 0xFA, 0x68, 0x28, 0x6B });
    // fix the BRA: from its own end to zero_tail
    {
        var i: usize = mul_len;
        while (i + 1 < cc) : (i += 1) {
            if (calc[i] == 0x80 and calc[i + 1] == 0x24) {
                calc[i + 1] = @intCast(zero_tail - (i + 2));
                break;
            }
        }
    }
    const cat = far.next(@intCast(cc)) orelse return refuse(refusal, .{ .reason = .no_free_space, .detail = @intCast(cc) });
    @memcpy(out[cat .. cat + cc], calc[0..cc]);
    const mul24: u24 = @intCast(((cat / 0x8000) << 16) | (0x8000 + (cat % 0x8000)));
    const div24: u24 = mul24 + @as(u24, @intCast(mul_len));
    // The mode-7 calculators as far routines (for the JSL-shaped trigger
    // sites; the COP handler keeps its inline copy): m7a composes M7A from
    // the last-written byte and the latch, both recompute the product.
    // Long addressing throughout — the caller's DBR is anything.
    var m7c: [96]u8 = undefined;
    var mc: usize = 0;
    put(&m7c, &mc, &.{ 0x08, 0xE2, 0x20, 0x48 }); // PHP / SEP #$20 / PHA
    put(&m7c, &mc, &.{ 0xAF, @truncate(split_m7_last), @truncate(split_m7_last >> 8), 0x00, 0x8F, @truncate(split_m7a + 1), @truncate((split_m7a + 1) >> 8), 0x00 }); // hi := last
    put(&m7c, &mc, &.{ 0xAF, @truncate(split_m7_latch), @truncate(split_m7_latch >> 8), 0x00, 0x8F, @truncate(split_m7a), @truncate(split_m7a >> 8), 0x00 }); // lo := latch
    put(&m7c, &mc, &.{ 0xAF, @truncate(split_m7_last), @truncate(split_m7_last >> 8), 0x00, 0x8F, @truncate(split_m7_latch), @truncate(split_m7_latch >> 8), 0x00 }); // latch := last
    put(&m7c, &mc, &.{ 0x68, 0x28 }); // PLA / PLP -- falls into the product
    const m7b_off = mc;
    put(&m7c, &mc, &.{ 0x08, 0xC2, 0x20, 0x48 }); // PHP / REP #$20 / PHA
    put(&m7c, &mc, &.{ 0xAF, @truncate(split_m7a), @truncate(split_m7a >> 8), 0x00, 0x8F, 0x51, 0x22, 0x00 }); // MA := M7A
    put(&m7c, &mc, &.{ 0xE2, 0x20, 0xAF, @truncate(split_m7b), @truncate(split_m7b >> 8), 0x00, 0x8F, 0x53, 0x22, 0x00 }); // MB lo
    put(&m7c, &mc, &.{ 0xA9, 0x00, 0x2C, @truncate(split_m7b), @truncate(split_m7b >> 8), 0x10, 0x02, 0xA9, 0xFF }); // sign-extend (BIT abs: DBR is a code bank, I-RAM aliases there)
    put(&m7c, &mc, &.{ 0x8F, 0x54, 0x22, 0x00, 0xEA, 0xEA, 0xEA }); // MB hi (triggers) / 5 cycles
    put(&m7c, &mc, &.{ 0xC2, 0x20, 0xAF, 0x06, 0x23, 0x00, 0x8F, @truncate(split_m7_prod), @truncate(split_m7_prod >> 8), 0x00 }); // product low word
    put(&m7c, &mc, &.{ 0xE2, 0x20, 0xAF, 0x08, 0x23, 0x00, 0x8F, @truncate(split_m7_prod + 2), @truncate((split_m7_prod + 2) >> 8), 0x00 }); // byte 2
    put(&m7c, &mc, &.{ 0xC2, 0x20, 0x68, 0x28, 0x6B }); // REP / PLA / PLP / RTL
    const m7at = far.next(@intCast(mc)) orelse return refuse(refusal, .{ .reason = .no_free_space, .detail = @intCast(mc) });
    @memcpy(out[m7at .. m7at + mc], m7c[0..mc]);
    const m7a24: u24 = @intCast(((m7at / 0x8000) << 16) | (0x8000 + (m7at % 0x8000)));
    const m7b24: u24 = m7a24 + @as(u24, @intCast(m7b_off));

    // The sites. Each 3-byte absolute access becomes `COP nn / NOP`: a
    // software interrupt whose handler (bank $00, the native COP vector —
    // the SA-1 reads the same ROM vector) finds the site's descriptor by
    // its bank and signature byte and performs the one instruction on
    // the interrupted registers: the real register on the S-CPU, the
    // cell on the SA-1, loads landing in the saved register with the
    // saved P's N/Z set as the load would have. No bytes in the site's
    // bank, no neighbouring instruction copied — the previous shapes
    // (a JSL over a span, a bank-local JSR) each failed on Super
    // Metroid: a `PHA` in a span, a bank with 63 free bytes.
    const Desc = struct { addr: u24, off: u8, kind: u8, opi: u8, len: u8 };
    // kind 7, "operate": the site's own opcode re-run against the fetched
    // value (ADC $4216 was 70 of Super Metroid's 250 product reads — the
    // scroll code's `ADC $4216` read open bus on the SA-1 and the camera
    // walked off on the first gameplay lap). Index = position here.
    const operate_ops = [_]u8{ 0x6D, 0xED, 0xCD, 0x2D, 0x0D, 0x4D, 0x2C, 0xEC, 0xCC }; // ADC SBC CMP AND ORA EOR BIT CPX CPY
    const operate_dp = [_]u8{ 0x65, 0xE5, 0xC5, 0x25, 0x05, 0x45, 0x24, 0xE4, 0xC4 }; // their direct-page forms
    var descs: [1024]Desc = undefined;
    var n_sites: u32 = 0;
    var per_bank: [0x40]u16 = @splat(0);
    {
        var bank: u32 = 0;
        while (bank * 0x8000 < out.len and bank < 0x40) : (bank += 1) {
            var aa: u32 = 0x8000;
            while (aa < 0xFFFD) : (aa += 1) {
                const ac: u24 = @intCast((bank << 16) | aa);
                const u = splitUsage(usage, ac);
                if (u & usage_map.flag_opcode == 0) continue;
                const file = splitFile(ac);
                const op = out[file];
                var opi: u8 = 0;
                const kind: u8 = switch (op) {
                    0x8D, 0x8F => 0, // STA abs / long
                    0x8E => 1,
                    0x8C => 2,
                    0x9C => 3,
                    0xAD, 0xAF => 4, // LDA abs / long
                    0xAE => 5,
                    0xAC => 6,
                    else => blk: {
                        const i = std.mem.indexOfScalar(u8, &operate_ops, op) orelse continue;
                        opi = @intCast(i);
                        break :blk 7;
                    },
                };
                const long = op == 0x8F or op == 0xAF;
                if (long and (out[file + 3] & 0x7F) >= 0x40) continue; // a long form names a bank without the register file
                const reg = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                const math_in = reg >= 0x4202 and reg <= 0x4206;
                const math_out = reg >= 0x4214 and reg <= 0x4217;
                const m7_in = reg == 0x211B or reg == 0x211C;
                const m7_out = reg >= 0x2134 and reg <= 0x2136;
                if (!(kind <= 3 and (math_in or m7_in)) and !(kind >= 4 and (math_out or m7_out))) continue;
                const idx_reg = kind == 1 or kind == 2 or kind == 5 or kind == 6 or (kind == 7 and opi >= 7);
                const wide = if (idx_reg) u & usage_map.flag_x == 0 else u & usage_map.flag_m == 0;
                if (m7_in and wide) continue; // a 16-bit store straddles M7A and M7B: not a shape the shadow models (the audit does not list stores; none seen)
                if (n_sites == descs.len or per_bank[bank] == 256)
                    return refuse(refusal, .{ .reason = .wg_split_shape, .detail = ac });
                const off: u8 = if (m7_in or m7_out) @intCast(reg - 0x20DB) else @intCast(reg - 0x4202);
                const len: u8 = if (long) 4 else 3;
                // Direct cell access for the SA-1's own sites: no trigger to
                // run, no S-CPU ever here in this copy.
                const trigger = kind <= 3 and (off == 1 or (off == 0 and wide) or off == 4 or (off == 3 and wide) or off == 0x40 or off == 0x41);
                // A trigger store as a JSL to its own far routine (measured: the
                // COP dispatch was ~95 instructions per site, 0.18 frame of a
                // gameplay lap and a quarter of a door transition's SA-1 time).
                // The 3-byte site needs the instruction after it to ride along:
                // a whole, covered, relocatable one — no flow, no push/pull, no
                // stack move, no register-file access, and nothing branches to it.
                if (trigger and (long or blk: {
                    const nf = file + 3;
                    const nu = splitUsage(usage, ac + 3);
                    if (nu & usage_map.flag_opcode == 0) break :blk false;
                    const nop = out[nf];
                    switch (nop) {
                        0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0, 0x80, 0x82, 0x62, 0x20, 0xFC, 0x4C, 0x5C, 0x6C, 0x7C, 0xDC, 0x60, 0x6B, 0x40, 0x00, 0x02, 0xCB, 0xDB => break :blk false, // flow
                        0x48, 0xDA, 0x5A, 0x08, 0x8B, 0x0B, 0x4B, 0xF4, 0xD4, 0x68, 0xFA, 0x7A, 0x28, 0xAB, 0x2B, 0x3B, 0x1B, 0x9A, 0xBA, 0x22 => break :blk false, // push/pull/stack/JSL
                        else => if (nop & 0x0F == 0x03) break :blk false, // stack-relative: the frame is three deeper inside the routine
                    }
                    const nlen = usage_map.instrLen(nop, nu & usage_map.flag_m != 0, nu & usage_map.flag_x != 0);
                    if (nlen < 1 or 3 + @as(u32, nlen) > 8) break :blk false;
                    if (nlen >= 3) {
                        const nreg = std.mem.readInt(u16, out[nf + 1 ..][0..2], .little);
                        if ((nreg >= 0x2100 and nreg <= 0x21FF) or (nreg >= 0x4200 and nreg <= 0x43FF)) break :blk false;
                    }
                    if (splitTargeted(out, usage, ac + 3)) break :blk false;
                    break :blk true;
                })) {
                    const site_len: u32 = if (long) 4 else 3;
                    const span: u32 = if (long) 4 else 3 + @as(u32, usage_map.instrLen(out[file + 3], splitUsage(usage, ac + 3) & usage_map.flag_m != 0, splitUsage(usage, ac + 3) & usage_map.flag_x != 0));
                    var tb: [96]u8 = undefined;
                    var tcn: usize = 0;
                    // PHP / REP #$20 / PHA / TSC / AND / CMP / BEQ sa1 / PLA / PLP / the real store / displaced / RTL
                    put(&tb, &tcn, &.{ 0x08, 0xC2, 0x20, 0x48, 0x3B, 0x29, 0x00, 0xF0, 0xC9, 0x00, 0x30 });
                    const beq_at = tcn;
                    put(&tb, &tcn, &.{ 0xF0, 0x00 }); // (patched)
                    put(&tb, &tcn, &.{ 0x68, 0x28 }); // PLA / PLP
                    @memcpy(tb[tcn .. tcn + site_len], out[file..][0..site_len]); // the original store, real register
                    tcn += if (long) 4 else 3;
                    if (span > site_len) {
                        @memcpy(tb[tcn .. tcn + (span - site_len)], out[file + site_len ..][0 .. span - site_len]);
                        tcn += span - site_len;
                    }
                    put(&tb, &tcn, &.{0x6B}); // RTL
                    // SA-1: PLA / PLP, then registers and flags kept around the cell store + calc
                    tb[beq_at + 1] = @intCast(tcn - (beq_at + 2));
                    put(&tb, &tcn, &.{ 0x68, 0x28, 0x08, 0xC2, 0x30, 0x48, 0xDA, 0x5A }); // PLA PLP / PHP REP #$30 PHA PHX PHY
                    const reg_kind = kind & 3; // 0 A, 1 X, 2 Y, 3 zero
                    switch (reg_kind) {
                        1 => put(&tb, &tcn, &.{0x8A}), // TXA
                        2 => put(&tb, &tcn, &.{0x98}), // TYA
                        3 => put(&tb, &tcn, &.{ 0xA9, 0x00, 0x00 }), // LDA #0
                        else => {},
                    }
                    const cell: u16 = if (off < 8) split_math_a + off else split_m7_last + (off - 0x40);
                    if (wide) {
                        put(&tb, &tcn, &.{ 0x8F, @truncate(cell), @truncate(cell >> 8), 0x00 }); // 16-bit store
                    } else {
                        put(&tb, &tcn, &.{ 0xE2, 0x20, 0x8F, @truncate(cell), @truncate(cell >> 8), 0x00, 0xC2, 0x20 });
                    }
                    const calc24: u24 = switch (off) {
                        0, 1 => mul24,
                        3, 4 => div24,
                        0x40 => m7a24,
                        else => m7b24,
                    };
                    put(&tb, &tcn, &.{ 0x22, @truncate(calc24), @truncate(calc24 >> 8), @truncate(calc24 >> 16) });
                    put(&tb, &tcn, &.{ 0x7A, 0xFA, 0x68, 0x28 }); // PLY PLX PLA PLP
                    if (span > site_len) {
                        @memcpy(tb[tcn .. tcn + (span - site_len)], out[file + site_len ..][0 .. span - site_len]);
                        tcn += span - site_len;
                    }
                    put(&tb, &tcn, &.{0x6B}); // RTL
                    const tat = far.next(@intCast(tcn)) orelse return refuse(refusal, .{ .reason = .no_free_space, .detail = @intCast(tcn) });
                    @memcpy(out[tat .. tat + tcn], tb[0..tcn]);
                    const t24: u24 = @intCast(((tat / 0x8000) << 16) | (0x8000 + (tat % 0x8000)));
                    if (n_out.* == sites.len) return refuse(refusal, .{ .reason = .wg_split_shape, .detail = ac });
                    sites[n_out.*] = .{ .addr = ac, .len = @intCast(span), .bytes = undefined };
                    @memcpy(sites[n_out.*].bytes[0..span], out[file..][0..span]);
                    n_out.* += 1;
                    out[file] = 0x22;
                    std.mem.writeInt(u16, out[file + 1 ..][0..2], @truncate(t24), .little);
                    out[file + 3] = @truncate(t24 >> 16);
                    if (span > 4) @memset(out[file + 4 ..][0 .. span - 4], 0xEA);
                    res.stats.split_trigger_jsl += 1;
                    continue;
                }
                const is_shared = std.sort.binarySearch(u24, shared, ac, struct {
                    pub fn f(k: u24, v: u24) std.math.Order {
                        return std.math.order(k, v);
                    }
                }.f) != null;
                if (!trigger and !is_shared and shared.len != 0) {
                    const cell: u16 = if (off < 8) split_math_a + off else if (off < 0x40) split_math_q - 0x12 + off else if (off < 0x59) split_m7_last + (off - 0x40) else split_m7_prod + (off - 0x59);
                    if (n_out.* == sites.len) return refuse(refusal, .{ .reason = .wg_split_shape, .detail = ac });
                    sites[n_out.*] = .{ .addr = ac, .len = len, .bytes = undefined };
                    @memcpy(sites[n_out.*].bytes[0..len], out[file..][0..len]);
                    n_out.* += 1;
                    std.mem.writeInt(u16, out[file + 1 ..][0..2], cell, .little); // the opcode and (for a long form) the bank stay
                    res.stats.split_math_direct += 1;
                    continue;
                }
                descs[n_sites] = .{ .addr = ac, .off = off, .kind = kind | (if (wide) @as(u8, 0x80) else 0), .opi = opi, .len = len };
                n_sites += 1;
                per_bank[bank] += 1;
            }
        }
    }
    if (n_sites != 0) {
        // Block: [handler][bank table: 64 words][per-bank descriptors].
        var hb: [1024]u8 = undefined;
        var hc: usize = 0;
        put(&hb, &hc, &.{ 0xC2, 0x30, 0x48, 0xDA, 0x5A, 0x0B, 0x8B, 0x4B, 0xAB }); // REP #$30 / PHA PHX PHY PHD PHB / PHK PLB
        put(&hb, &hc, &.{ 0x3B, 0x29, 0x00, 0xF0, 0xC9, 0x00, 0x30, 0xF0, 0x09 }); // the SA-1 skips the SIWP open
        put(&hb, &hc, &.{ 0xE2, 0x20, 0xA9, 0xFF, 0x8D, 0x29, 0x22, 0xC2, 0x20 }); // SIWP := $FF (boot-time COPs run before any engage)
        put(&hb, &hc, &.{ 0xF4, @truncate(split_cop_dp), @truncate(split_cop_dp >> 8), 0x2B }); // PEA / PLD: D = the scratch page
        put(&hb, &hc, &.{ 0xA3, 0x0B, 0x3A, 0x85, 0x00 }); // LDA $0B,S (PC) / DEC / STA $00 — the signature's address
        put(&hb, &hc, &.{ 0xE2, 0x20, 0xA3, 0x0D, 0x85, 0x02 }); // SEP #$20 / LDA $0D,S (PBR) / STA $02
        put(&hb, &hc, &.{ 0xA7, 0x00, 0x85, 0x03 }); // LDA [$00] / STA $03 — nn
        put(&hb, &hc, &.{ 0xC2, 0x20, 0xA5, 0x02, 0x29, 0x3F, 0x00, 0x0A, 0xAA }); // REP / LDA $02 / AND #$3F (the mirror bit off: the table is 64 banks) / ASL / TAX
        const bank_tbl_ref = hc;
        put(&hb, &hc, &.{ 0xBD, 0x00, 0x00, 0x85, 0x04 }); // LDA banktbl,X (patched) / STA $04
        put(&hb, &hc, &.{ 0xA5, 0x03, 0x29, 0xFF, 0x00, 0x85, 0x0E, 0x0A, 0x18, 0x65, 0x0E, 0x18, 0x65, 0x04, 0xAA }); // nn*3 + base -> X
        put(&hb, &hc, &.{ 0xBD, 0x00, 0x00, 0x85, 0x06 }); // LDA $0000,X / STA $06: $06 = off, $07 = kind|wide
        put(&hb, &hc, &.{ 0xE2, 0x20, 0xBD, 0x02, 0x00, 0x85, 0x10, 0xC2, 0x20 }); // $10 = the operate opcode index
        // the target: the register (S-CPU) or the cell (SA-1), into [$08]
        put(&hb, &hc, &.{ 0x3B, 0x29, 0x00, 0xF0, 0xC9, 0x00, 0x30, 0xF0, 0x16 }); // BEQ the SA-1's cell (22 bytes on)
        // S-CPU: the register — $4202 + off, or $20DB + off for the mode-7 set
        put(&hb, &hc, &.{ 0xA5, 0x06, 0x29, 0xFF, 0x00, 0xC9, 0x40, 0x00, 0xB0, 0x06 }); // off >= $40 ?
        put(&hb, &hc, &.{ 0x18, 0x69, 0x02, 0x42, 0x80, 0x30 }); // reg = $4202 + off; BRA store (6 + 42 bytes on)
        put(&hb, &hc, &.{ 0x18, 0x69, 0xDB, 0x20, 0x80, 0x2A }); // reg = $20DB + off; BRA store (42 bytes of SA-1 path)
        // SA-1: the cell — three ranges, the mode-7 product's and inputs' apart
        put(&hb, &hc, &.{ 0xA5, 0x06, 0x29, 0xFF, 0x00 });
        put(&hb, &hc, &.{ 0xC9, 0x59, 0x00, 0x90, 0x06 }); // off < $59 ?
        put(&hb, &hc, &.{ 0x18, 0x69, @truncate(split_m7_prod - 0x59), @truncate((split_m7_prod - 0x59) >> 8), 0x80, 0x1A }); // cell = $36FC + (off - $59)
        put(&hb, &hc, &.{ 0xC9, 0x40, 0x00, 0x90, 0x06 }); // off < $40 ?
        put(&hb, &hc, &.{ 0x18, 0x69, @truncate(split_m7_last - 0x40), @truncate((split_m7_last - 0x40) >> 8), 0x80, 0x0F }); // cell = $36FA + (off - $40)
        put(&hb, &hc, &.{ 0xC9, 0x08, 0x00, 0xB0, 0x06 }); // off < 8 ?
        put(&hb, &hc, &.{ 0x18, 0x69, @truncate(split_math_a), @truncate(split_math_a >> 8), 0x80, 0x04 }); // cell = $36F0 + off
        put(&hb, &hc, &.{ 0x18, 0x69, @truncate(split_math_q - 0x12), @truncate((split_math_q - 0x12) >> 8) }); // cell = $36E4 + off
        put(&hb, &hc, &.{ 0x85, 0x08, 0x64, 0x0A }); // STA $08 / STZ $0A (pointer bank 0)
        // kind
        put(&hb, &hc, &.{ 0xA5, 0x07, 0x29, 0x07, 0x00, 0xC9, 0x04, 0x00 }); // LDA $07 / AND #7 / CMP #4
        put(&hb, &hc, &.{ 0x90, 0x03 }); // BCC stores, over the BRL
        const brl_loads_at = hc;
        put(&hb, &hc, &.{ 0x82, 0x00, 0x00 }); // BRL loads (patched; past a short branch's reach)
        // stores: the value from the saved register
        put(&hb, &hc, &.{ 0xC9, 0x00, 0x00, 0xD0, 0x04, 0xA3, 0x08, 0x80, 0x15 }); // A
        put(&hb, &hc, &.{ 0xC9, 0x01, 0x00, 0xD0, 0x04, 0xA3, 0x06, 0x80, 0x0C }); // X
        put(&hb, &hc, &.{ 0xC9, 0x02, 0x00, 0xD0, 0x04, 0xA3, 0x04, 0x80, 0x03 }); // Y
        put(&hb, &hc, &.{ 0xA9, 0x00, 0x00 }); // STZ: zero
        put(&hb, &hc, &.{ 0x24, 0x06, 0x10, 0x04, 0x87, 0x08, 0x80, 0x06 }); // BIT $06 (N = wide) / wide: STA [$08]
        put(&hb, &hc, &.{ 0xE2, 0x20, 0x87, 0x08, 0xC2, 0x20 }); // narrow: SEP / STA [$08] / REP
        // SA-1: the triggers
        put(&hb, &hc, &.{ 0x3B, 0x29, 0x00, 0xF0, 0xC9, 0x00, 0x30 });
        put(&hb, &hc, &.{ 0xF0, 0x03 }); // BEQ over the BRL: the SA-1 goes on to the triggers
        const bne_exit1_at = hc;
        put(&hb, &hc, &.{ 0x82, 0x00, 0x00 }); // BRL exit (patched; the exit is past a short branch's reach)
        put(&hb, &hc, &.{ 0xA5, 0x06, 0x29, 0xFF, 0x00 }); // off
        put(&hb, &hc, &.{ 0xC9, 0x40, 0x00, 0xD0, 0x03 }); // $211B -> the M7A compose + product (BNE over the BRL: the block sits past the exit)
        const brl_m7a_at = hc;
        put(&hb, &hc, &.{ 0x82, 0x00, 0x00 }); // (patched)
        put(&hb, &hc, &.{ 0xC9, 0x41, 0x00, 0xD0, 0x03 }); // $211C -> the product
        const brl_m7b_at = hc;
        put(&hb, &hc, &.{ 0x82, 0x00, 0x00 }); // (patched)
        put(&hb, &hc, &.{ 0xC9, 0x01, 0x00, 0xF0, 0x17 }); // $4203 -> mul
        put(&hb, &hc, &.{ 0xC9, 0x04, 0x00, 0xF0, 0x18 }); // $4206 -> div
        put(&hb, &hc, &.{ 0x24, 0x06, 0x10, 0x0A }); // narrow: exit
        put(&hb, &hc, &.{ 0xC9, 0x00, 0x00, 0xF0, 0x09 }); // wide $4202 -> mul
        put(&hb, &hc, &.{ 0xC9, 0x03, 0x00, 0xF0, 0x0A }); // wide $4205 -> div
        const bra_exit2_at = hc;
        put(&hb, &hc, &.{ 0x80, 0x00 }); // BRA exit (patched)
        put(&hb, &hc, &.{ 0xEA, 0xEA }); // pad, keeps the branch arithmetic above exact
        const mul_call_at = hc;
        put(&hb, &hc, &.{ 0x22, @truncate(mul24), @truncate(mul24 >> 8), @truncate(mul24 >> 16) });
        const bra_exit3_at = hc;
        put(&hb, &hc, &.{ 0x80, 0x00 }); // BRA exit (patched)
        const div_call_at = hc;
        put(&hb, &hc, &.{ 0x22, @truncate(div24), @truncate(div24 >> 8), @truncate(div24 >> 16) });
        const bra_exit4_at = hc;
        put(&hb, &hc, &.{ 0x80, 0x00 }); // BRA exit (patched)
        // loads: A = kind (4/5/6); three copies, one per saved slot
        const loads_at = hc;
        std.mem.writeInt(u16, hb[brl_loads_at + 1 ..][0..2], @intCast(loads_at - (brl_loads_at + 3)), .little);
        put(&hb, &hc, &.{ 0xC9, 0x07, 0x00 }); // kind 7: operate
        const beq_operate_at = hc;
        put(&hb, &hc, &.{ 0xF0, 0x00 }); // BEQ operate (patched)
        put(&hb, &hc, &.{ 0xC9, 0x05, 0x00, 0xF0, 0x20, 0xB0, 0x40 }); // 5 -> X copy, 6 -> Y copy, else A
        const slots = [_]u8{ 0x09, 0x07, 0x05 }; // A, X, Y saved slots, +1 for the PHP
        var exit_patches: [3]usize = undefined;
        for (slots, 0..) |sl, k| {
            put(&hb, &hc, &.{ 0x24, 0x06, 0x10, 0x04, 0xA7, 0x08, 0x80, 0x04 }); // wide: LDA [$08]
            put(&hb, &hc, &.{ 0xE2, 0x20, 0xA7, 0x08 }); // narrow: SEP / LDA [$08]
            put(&hb, &hc, &.{ 0x08, 0x83, sl, 0xE2, 0x20, 0x68, 0x29, 0x82, 0x85, 0x0C }); // PHP / STA slot,S / SEP / PLA / AND #$82 / STA $0C
            put(&hb, &hc, &.{ 0xA3, 0x0A, 0x29, 0x7D, 0x05, 0x0C, 0x83, 0x0A }); // saved P: keep all but N/Z, merge
            exit_patches[k] = hc;
            put(&hb, &hc, &.{ 0x80, 0x00 }); // BRA exit (patched)
        }
        std.debug.assert(hc - loads_at - 12 == 96); // three 32-byte copies
        const exit_at = hc;
        put(&hb, &hc, &.{ 0xC2, 0x30, 0xAB, 0x2B, 0x7A, 0xFA, 0x68, 0x40 }); // REP #$30 / PLB PLD PLY PLX PLA / RTI
        // operate: the value into $0E, then the caller's A/X/Y/P back and
        // the site's opcode run against $0E in its direct-page form — the
        // caller's widths and carry govern, the result P lands in the
        // saved P, A in the saved A (M-width: an 8-bit op leaves B alone).
        // Dispatch by RTS through a pushed stub address: X is free for the
        // lookup while the caller's X is still on the frame.
        const operate_at = hc;
        hb[beq_operate_at + 1] = @intCast(operate_at - (beq_operate_at + 2));
        put(&hb, &hc, &.{ 0x24, 0x06, 0x10, 0x06, 0xA7, 0x08, 0x85, 0x0E, 0x80, 0x08 }); // wide: LDA [$08] / STA $0E
        put(&hb, &hc, &.{ 0xE2, 0x20, 0xA7, 0x08, 0x85, 0x0E, 0xC2, 0x20 }); // narrow: SEP / LDA [$08] / STA $0E / REP
        put(&hb, &hc, &.{ 0xA5, 0x10, 0x29, 0xFF, 0x00, 0x0A, 0xAA }); // LDA $10 / AND #$FF / ASL / TAX
        const optbl_ref = hc;
        put(&hb, &hc, &.{ 0xBD, 0x00, 0x00, 0x3A, 0x48 }); // LDA optbl,X (patched) / DEC / PHA: the stub, for the RTS
        put(&hb, &hc, &.{ 0xE2, 0x20, 0xA3, 0x0C, 0x48 }); // SEP #$20 / LDA $0C,S (caller P) / PHA
        // the caller's X, Y, A from the frame (S-relative offsets after the
        // two pushes above: A at $0B, X at $09, Y at $07)
        put(&hb, &hc, &.{ 0xC2, 0x30, 0xA3, 0x09, 0xAA, 0xA3, 0x07, 0xA8, 0xA3, 0x0B }); // REP #$30 / LDA $09,S / TAX / LDA $07,S / TAY / LDA $0B,S
        put(&hb, &hc, &.{ 0x28, 0x60 }); // PLP / RTS -> the stub
        var stub_at: [operate_ops.len]usize = undefined;
        var join_patches: [operate_ops.len]usize = undefined;
        for (operate_dp, 0..) |dp, k| {
            stub_at[k] = hc;
            put(&hb, &hc, &.{ dp, 0x0E }); // op $0E
            join_patches[k] = hc;
            put(&hb, &hc, &.{ 0x80, 0x00 }); // BRA join (patched)
        }
        const join_at = hc;
        for (join_patches) |at| hb[at + 1] = @intCast(join_at - (at + 2));
        put(&hb, &hc, &.{ 0x08, 0x83, 0x09 }); // PHP / STA $09,S -- A back (M-width)
        put(&hb, &hc, &.{ 0xE2, 0x20, 0xA3, 0x01, 0x83, 0x0B, 0x68 }); // SEP / LDA $01,S (result P) / STA $0B,S (saved P) / PLA
        const bra_exit5_at = hc;
        put(&hb, &hc, &.{ 0x80, 0x00 }); // BRA exit (patched)
        // the mode-7 multiplier (SA-1 only; REP #$20 is live, DBR 0, D scratch):
        // a $211B write composes M7A = value<<8 | latch and latches the value
        // (the register's own write-twice shape); either input recomputes
        // the signed 16x8 product through MA/MB with M7B sign-extended.
        std.mem.writeInt(u16, hb[brl_m7a_at + 1 ..][0..2], @intCast(hc - (brl_m7a_at + 3)), .little);
        put(&hb, &hc, &.{ 0xE2, 0x20, 0xAD, @truncate(split_m7_last), @truncate(split_m7_last >> 8), 0x8D, @truncate(split_m7a + 1), @truncate((split_m7a + 1) >> 8) }); // SEP / hi := last
        put(&hb, &hc, &.{ 0xAD, @truncate(split_m7_latch), @truncate(split_m7_latch >> 8), 0x8D, @truncate(split_m7a), @truncate(split_m7a >> 8) }); // lo := latch
        put(&hb, &hc, &.{ 0xAD, @truncate(split_m7_last), @truncate(split_m7_last >> 8), 0x8D, @truncate(split_m7_latch), @truncate(split_m7_latch >> 8), 0xC2, 0x20 }); // latch := last / REP
        std.mem.writeInt(u16, hb[brl_m7b_at + 1 ..][0..2], @intCast(hc - (brl_m7b_at + 3)), .little);
        put(&hb, &hc, &.{ 0xAD, @truncate(split_m7a), @truncate(split_m7a >> 8), 0x8D, 0x51, 0x22 }); // MA := M7A (16-bit)
        put(&hb, &hc, &.{ 0xE2, 0x20, 0xAD, @truncate(split_m7b), @truncate(split_m7b >> 8), 0x8D, 0x53, 0x22 }); // MB lo
        put(&hb, &hc, &.{ 0xA9, 0x00, 0x2C, @truncate(split_m7b), @truncate(split_m7b >> 8), 0x10, 0x02, 0xA9, 0xFF }); // sign-extend
        put(&hb, &hc, &.{ 0x8D, 0x54, 0x22, 0xEA, 0xEA, 0xEA }); // MB hi (triggers) / the unit's 5 cycles
        put(&hb, &hc, &.{ 0xC2, 0x20, 0xAD, 0x06, 0x23, 0x8D, @truncate(split_m7_prod), @truncate(split_m7_prod >> 8) }); // product low word
        put(&hb, &hc, &.{ 0xE2, 0x20, 0xAD, 0x08, 0x23, 0x8D, @truncate(split_m7_prod + 2), @truncate((split_m7_prod + 2) >> 8), 0xC2, 0x20 }); // byte 2
        const brl_exit6_at = hc;
        put(&hb, &hc, &.{ 0x82, 0x00, 0x00 }); // BRL exit (patched)
        const optbl_at = hc;
        hc += operate_ops.len * 2;
        std.mem.writeInt(u16, hb[bne_exit1_at + 1 ..][0..2], @intCast(exit_at - (bne_exit1_at + 3)), .little);
        std.mem.writeInt(i16, hb[brl_exit6_at + 1 ..][0..2], @intCast(@as(isize, @intCast(exit_at)) - @as(isize, @intCast(brl_exit6_at + 3))), .little); // backward: the block sits past the exit
        hb[bra_exit2_at + 1] = @intCast(exit_at - (bra_exit2_at + 2));
        hb[bra_exit3_at + 1] = @intCast(exit_at - (bra_exit3_at + 2));
        hb[bra_exit4_at + 1] = @intCast(exit_at - (bra_exit4_at + 2));
        for (exit_patches) |at| hb[at + 1] = @intCast(exit_at - (at + 2));
        hb[bra_exit5_at + 1] = @bitCast(@as(i8, @intCast(@as(isize, @intCast(exit_at)) - @as(isize, @intCast(bra_exit5_at + 2)))));
        std.debug.assert(mul_call_at == bne_exit1_at + 3 + 5 + 16 + 5 + 5 + 4 + 5 + 5 + 2 + 2); // the trigger branches land on the calls
        std.debug.assert(div_call_at == mul_call_at + 6);
        // the block
        const bank_tbl_at = hc;
        const desc_at = hc + 0x80;
        const total: u32 = @intCast(desc_at + @as(usize, n_sites) * 3);
        const at = far.nextIn(0, total, carve, carve_len) orelse
            return refuse(refusal, .{ .reason = .no_free_space, .detail = total });
        const base: u16 = @intCast(0x8000 + at);
        std.mem.writeInt(u16, hb[bank_tbl_ref + 1 ..][0..2], base + @as(u16, @intCast(bank_tbl_at)), .little);
        std.mem.writeInt(u16, hb[optbl_ref + 1 ..][0..2], base + @as(u16, @intCast(optbl_at)), .little);
        for (stub_at, 0..) |sa, k| std.mem.writeInt(u16, hb[optbl_at + k * 2 ..][0..2], base + @as(u16, @intCast(sa)), .little);
        @memcpy(out[at .. at + hc], hb[0..hc]);
        // per-bank descriptor tables, sites numbered in address order
        var next: [0x40]u16 = undefined;
        var cursor: usize = desc_at;
        for (0..0x40) |bk| {
            next[bk] = 0;
            const t: u16 = base + @as(u16, @intCast(cursor));
            std.mem.writeInt(u16, out[at + bank_tbl_at + bk * 2 ..][0..2], t, .little);
            cursor += @as(usize, per_bank[bk]) * 3;
        }
        for (descs[0..n_sites]) |dsc| {
            const bk: usize = (dsc.addr >> 16) & 0x3F;
            const t = std.mem.readInt(u16, out[at + bank_tbl_at + bk * 2 ..][0..2], .little) - 0x8000;
            const nn = next[bk];
            next[bk] += 1;
            out[t + nn * 3] = dsc.off;
            out[t + nn * 3 + 1] = dsc.kind;
            out[t + nn * 3 + 2] = dsc.opi;
            const file = splitFile(dsc.addr);
            sites[n_out.*] = .{ .addr = dsc.addr, .len = dsc.len, .bytes = undefined };
            @memcpy(sites[n_out.*].bytes[0..dsc.len], out[file..][0..dsc.len]);
            n_out.* += 1;
            out[file] = 0x02; // COP
            out[file + 1] = @intCast(nn);
            @memset(out[file + 2 ..][0 .. dsc.len - 2], 0xEA);
        }
        // the native COP vector, both CPUs' (the SA-1 does not intercept it)
        std.mem.writeInt(u16, out[0x7FE4..0x7FE6], base, .little);
    }
    res.stats.split_mul = @intCast(@min(n_sites, 255));
    res.stats.split_math_sites = n_sites + res.stats.split_math_direct;
}

/// The shared IO machinery: per-routine drain trampolines, enqueue
/// stubs (span-generalized: sites whose whole-instruction prefix runs
/// past 3 bytes are NOP-filled so the stub's RTS lands in fill), the
/// dispatch table, and the site displacements. `jsr_patch_at` is the
/// draining `JSR (tbl,X)` whose operand this fills in.
pub fn emitSplitIo(
    out: []u8,
    usage: []const u8,
    spec: SplitSpec,
    d: []u8,
    curp: *usize,
    base16: u16,
    jsr_patch_at: usize,
    far: *FarPad,
    refusal: *?Refusal,
    res: *Result,
) Error!void {
    var cur = curp.*;
    // Drain trampolines stay in the carve: the drains' `JSR (tbl,X)`
    // fetches its pointer from PBR's bank, and they are small.
    //
    // The call frame is pushed BEFORE the displaced prefix runs: a
    // prefix may open with PHP (the screen family does), and the body's
    // closing PLP must find that P on top — with the old layout the
    // bridge's frame sat between them, the PLP ate the frame's PCL, and
    // the RTL flew into bank $34 padding (measured: an IRQ-storming
    // wild march at clk 70.37M).
    var tramp_addrs: [40]u16 = undefined;
    for (spec.io_entries, 0..) |io, i| {
        const span = splitPrefixSpan(out, usage, io.entry, 3);
        if (span == 0) return refuse(refusal, .{ .reason = .wg_split_shape, .detail = io.entry });
        const e16: u16 = @truncate(io.entry);
        tramp_addrs[i] = base16 + @as(u16, @intCast(cur));
        if (io.rtl) {
            const helper = tramp_addrs[i] + 5;
            put(d, &cur, &.{ 0x22, @truncate(helper), @truncate(helper >> 8), 0x00, 0x60 });
        } else {
            const helper = tramp_addrs[i] + 4;
            put(d, &cur, &.{ 0x20, @truncate(helper), @truncate(helper >> 8), 0x60 });
        }
        @memcpy(d[cur .. cur + span], out[splitFile(io.entry)..][0..span]);
        cur += span;
        put(d, &cur, &.{ 0x4C, @truncate(e16 + @as(u16, @intCast(span))), @truncate((e16 + @as(u16, @intCast(span))) >> 8) });
    }
    // Enqueue stubs live in the FAR pool — seventeen of them overran
    // the carve, and a stripped assert let the overflow eat the shim.
    // Bank $00 keeps a 4-byte JML hop per entry; an RTS-shaped deferred
    // return needs its pop to happen with PBR=$00, so its hop carries
    // one RTS byte the far stub JMLs back to.
    var enq_addrs: [40]u16 = undefined;
    for (spec.io_entries, 0..) |io, i| {
        enq_addrs[i] = base16 + @as(u16, @intCast(cur));
        const hop_jml_at = cur;
        put(d, &cur, &.{ 0x5C, 0x00, 0x00, 0x00 }); // JML far stub (patched)
        var rts_hop16: u16 = 0;
        if (io.deferred and !io.rtl) {
            rts_hop16 = base16 + @as(u16, @intCast(cur));
            put(d, &cur, &.{0x60});
        }
        const need: u32 = 200;
        const at = far.next(need) orelse
            return refuse(refusal, .{ .reason = .no_free_space, .detail = need });
        var fb = out[at .. at + need];
        var fc: usize = 0;
        const fbank: u8 = @intCast(at / 0x8000);
        const fbase: u16 = @intCast(0x8000 + (at % 0x8000));
        // Caller A/X/Y captured whole before anything is disturbed —
        // $9231 takes its VRAM fill target in X and its count in Y, and
        // a replay entering with the drain's registers zero-filled VRAM
        // at (dispatch index * 2) instead: the title menu's gridlines.
        put(fb, &fc, &.{ 0x08, 0xC2, 0x30 }); // PHP / REP #$30
        put(fb, &fc, &.{ 0x8F, @truncate(split_cell_a), 0x37, 0x00 });
        put(fb, &fc, &.{ 0x98, 0x8F, @truncate(split_cell_y), 0x37, 0x00 }); // TYA
        put(fb, &fc, &.{ 0x8A, 0x8F, @truncate(split_cell_x), 0x37, 0x00 }); // TXA
        put(fb, &fc, &.{ 0xAF, @truncate(split_cell_a), 0x37, 0x00 }); // A back
        put(fb, &fc, &.{0x28}); // PLP — caller state fully intact
        // PHY too: SEP #$30 ZEROES the high bytes of X and Y on the 65816.
        // X rode the stack; Y only rode the cell the replay restores from,
        // so every S-CPU-native call left with Y's high byte gone
        // (measured: the option screen's map clear entered with Y=$0FFF
        // and filled $00FF words — the menu logo stayed behind the text).
        put(fb, &fc, &.{ 0x48, 0xDA, 0x5A, 0x08, 0xE2, 0x30 }); // PHA/PHX/PHY/PHP/SEP #$30
        put(fb, &fc, &.{ 0xC2, 0x20, 0x3B, 0x29, 0x00, 0xF0, 0xC9, 0x00, 0x30, 0xE2, 0x20 }); // TSC & $F000 == $3000?
        const not_sa1_at = fc;
        put(fb, &fc, &.{ 0xD0, 0x00 }); // BNE the common tail (patched)
        if (io.ff) {
            // Fire-and-forget (ring 2): record [id][caller D], bump the
            // slot cursor mod 12, restore, return. No spin — the replay
            // happens at the mini-tok, the frame-exit phase where stock
            // ran its trailing sound call anyway.
            put(fb, &fc, &.{ 0xAF, @truncate(split_ring2_wr), 0x37, 0x00, 0x0A, 0x0A, 0xAA });
            put(fb, &fc, &.{ 0xA9, @intCast(i), 0x9F, @truncate(split_ring2), @truncate(split_ring2 >> 8), 0x00 });
            put(fb, &fc, &.{ 0xC2, 0x20, 0x0B, 0x68, 0x9F, @truncate(split_ring2 + 1), @truncate((split_ring2 + 1) >> 8), 0x00, 0xE2, 0x20 });
            put(fb, &fc, &.{ 0xA3, 0x01, 0x9F, @truncate(split_ring2 + 3), @truncate((split_ring2 + 3) >> 8), 0x00 }); // caller P -> record[3]
            put(fb, &fc, &.{ 0xAF, @truncate(split_ring2_wr), 0x37, 0x00, 0x1A, 0xC9, 0x18, 0xD0, 0x02, 0xA9, 0x00 });
            put(fb, &fc, &.{ 0x8F, @truncate(split_ring2_wr), 0x37, 0x00 });
            put(fb, &fc, &.{ 0x28, 0x7A, 0xFA, 0x68 });
            if (io.rtl) {
                put(fb, &fc, &.{0x6B});
            } else {
                put(fb, &fc, &.{ 0x5C, @truncate(rts_hop16), @truncate(rts_hop16 >> 8), 0x00 });
            }
        }
        // Carry the CALLER's D and DBR to the replay: the body's dp and
        // absolute rewrites were made against them (the APU-stream
        // feeder runs D=$7A00 — its count under the pump's $6000 pin
        // read a different page and the ring-copy scan ran unbounded).
        // RPC serializes — one call in flight — so one cell pair holds.
        put(fb, &fc, &.{ 0xC2, 0x20, 0x0B, 0x68, 0x8F, @truncate(split_cell_d), 0x37, 0x00, 0xE2, 0x20 });
        put(fb, &fc, &.{ 0x8B, 0x68, 0x8F, @truncate(split_cell_dbr), 0x37, 0x00 });
        put(fb, &fc, &.{ 0xA3, 0x01, 0x8F, @truncate(split_cell_pw), 0x37, 0x00 }); // caller P (pushed at stub entry)
        put(fb, &fc, &.{ 0xAF, @truncate(split_rpc_ack), 0x37, 0x00, 0x8F, @truncate(split_scr_a), 0x37, 0x00 }); // old ack
        put(fb, &fc, &.{ 0xAF, @truncate(split_ring_wr), 0x37, 0x00, 0xAA }); // wr -> X
        put(fb, &fc, &.{ 0xA9, @intCast(i), 0x9F, @truncate(split_ring), 0x37, 0x00 }); // id -> ring,X
        put(fb, &fc, &.{ 0xE8, 0x8A, 0x29, 0x0F, 0x8F, @truncate(split_ring_wr), 0x37, 0x00 });
        if (io.deferred) {
            // RPC, not fire-and-forget: the body's SHARED-STATE writes
            // must land in program order, so wait for the replay. The
            // release is the ACK bump (after the body), NOT the ring
            // cursor: rd consumes the entry BEFORE the body runs, so a
            // NESTED NMI's drain sees an empty ring and falls through to
            // the displaced epilogue — which is exactly the overrun
            // release a body parked on the $3C handshake is waiting for.
            // Spinning on rd==wr instead made every releasing NMI
            // re-enter the in-service call: infinite regress (measured
            // at the demo transition, frame ~714).
            put(fb, &fc, &.{ 0xAF, @truncate(split_rpc_ack), 0x37, 0x00 }); // spin: ack
            put(fb, &fc, &.{ 0xCF, @truncate(split_scr_a), 0x37, 0x00 }); // still the old one?
            put(fb, &fc, &.{ 0xF0, 0xF6 }); // BEQ spin
            put(fb, &fc, &.{ 0x28, 0x7A, 0xFA, 0x68 }); // PLP/PLX/PLA
            if (io.rtl) {
                put(fb, &fc, &.{0x6B}); // pop the GAME frame — RTL is bank-safe anywhere
            } else {
                put(fb, &fc, &.{ 0x5C, @truncate(rts_hop16), @truncate(rts_hop16 >> 8), 0x00 }); // the hop's RTS pops with PBR=$00
            }
        }
        fb[not_sa1_at + 1] = @intCast(fc - (not_sa1_at + 2));
        put(fb, &fc, &.{ 0x28, 0x7A, 0xFA, 0x68 }); // PLP/PLX/PLA
        {
            const span = splitPrefixSpan(out, usage, io.entry, 3);
            const e16: u16 = @truncate(io.entry);
            @memcpy(fb[fc .. fc + span], out[splitFile(io.entry)..][0..span]);
            fc += span;
            put(fb, &fc, &.{ 0x5C, @truncate(e16 + @as(u16, @intCast(span))), @truncate((e16 + @as(u16, @intCast(span))) >> 8), 0x00 }); // JML back into the body
        }
        if (fc > need) return refuse(refusal, .{ .reason = .wg_split_shape, .detail = io.entry });
        std.mem.writeInt(u16, d[hop_jml_at + 1 ..][0..2], fbase, .little);
        d[hop_jml_at + 3] = fbank;
    }
    const tbl16: u16 = base16 + @as(u16, @intCast(cur));
    for (spec.io_entries, 0..) |_, i| {
        put(d, &cur, &.{ @truncate(tramp_addrs[i]), @truncate(tramp_addrs[i] >> 8) });
    }
    std.mem.writeInt(u16, d[jsr_patch_at + 1 ..][0..2], tbl16, .little);

    // --- displacements, last: everything they jump into now exists ----
    for (spec.io_entries, 0..) |io, i| {
        const span = splitPrefixSpan(out, usage, io.entry, 3);
        const f = splitFile(io.entry);
        out[f] = 0x4C; // JMP enq — frameless, so pushes in the prefix are legal
        std.mem.writeInt(u16, out[f + 1 ..][0..2], enq_addrs[i], .little);
        if (span > 3) @memset(out[f + 3 ..][0 .. span - 3], 0xEA);
    }
    res.stats.split_io = @intCast(spec.io_entries.len);
    curp.* = cur;
}
