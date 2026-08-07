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

    pub fn describe(self: Reason) []const u8 {
        return switch (self) {
            .coprocessor => "the cartridge already carries a coprocessor",
            .not_lorom => "only LoROM carts convert (the Super MMC's power-on map reproduces LoROM addressing)",
            .has_sram => "the cartridge has its own save RAM; relocating it is not mechanical",
            .rom_too_big => "ROM exceeds 4 MiB, the Super MMC window this conversion maps",
            .bwram_too_big => "the plan needs more BW-RAM than a cart can carry",
            .reset_vector_not_rom => "the reset vector does not point into ROM",
            .no_free_space => "no padding run in bank $00 is large enough for the boot shim",
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
    /// JSR call sites re-pointed at the offload stub.
    offload_sites: u32 = 0,
};

pub const Result = struct {
    image: []u8,
    stats: Stats,
    /// Per plan region (same order), what happened to it.
    fate: [profile.plan_region_cap]RegionFate,
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
    /// Hot-routine entries (the conversion verdict's set) considered for
    /// execution offload; empty skips S3b entirely.
    candidates: []const u24,
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
    if (usage != null and plan.viable) tryOffload(out, plan, usage.?, candidates, carve, &res, &crv);

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
fn tryOffload(
    out: []u8,
    plan: *const profile.Plan,
    usage: []const u8,
    candidates: []const u24,
    shim_carve: u32,
    res: *Result,
    crv: *u16,
) void {
    if (plan.iram_used > iram_offload_limit) return;
    const entry: u16 = for (candidates) |c| {
        if (c >> 16 != 0 or (c & 0xFFFF) < 0x8000) continue;
        if (eligibleLeaf(out, usage, plan, res, @truncate(c))) break @truncate(c);
    } else return;

    // Space for the stub + dispatcher, in front of the shim's reservation so
    // the two carves cannot overlap (the shim bytes are written later).
    const need: u32 = stub_template.len + disp_template.len;
    const carve = patchgen.findFreeSpace(out[0..shim_carve], need) orelse return;
    const stub_addr: u16 = 0x8000 + @as(u16, @intCast(carve));
    const disp_addr: u16 = stub_addr + @as(u16, @intCast(stub_template.len));

    var stub = stub_template;
    var disp = disp_template;
    // Dispatcher fixups: dp base and the routine entry.
    const dp_base: u16 = if (res.stats.d_moved) 0x3000 else 0;
    disp[disp_dp_off] = @truncate(dp_base);
    disp[disp_dp_off + 1] = @truncate(dp_base >> 8);
    disp[disp_entry_off] = @truncate(entry);
    disp[disp_entry_off + 1] = @truncate(entry >> 8);
    @memcpy(out[carve..][0..stub.len], &stub);
    @memcpy(out[carve + stub.len ..][0..disp.len], &disp);

    // Re-point every executed bank-$00 `JSR entry` at the stub.
    var a16: u32 = 0x8000;
    while (a16 < 0x10000) : (a16 += 1) {
        if (usage[a16] & usage_map.flag_opcode == 0) continue;
        const file = a16 - 0x8000;
        if (out[file] != 0x20) continue;
        if (std.mem.readInt(u16, out[file + 1 ..][0..2], .little) != entry) continue;
        // The stub itself JSRs nothing; call sites inside the routine span
        // cannot exist (the walk refused calls).
        std.mem.writeInt(u16, out[file + 1 ..][0..2], stub_addr, .little);
        res.stats.offload_sites += 1;
    }
    if (res.stats.offload_sites == 0) {
        // Nothing calls it where we can see: undo nothing, offload nothing.
        return;
    }
    res.stats.offloaded = entry;
    crv.* = disp_addr;
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

/// The SA-1 side: native mode, stack parked under the mailbox, D set to the
/// shared base, then an eternal serve loop — unmarshal with the caller's P,
/// run the routine, marshal back with its exit P, signal done, await the ack.
const disp_dp_off: usize = 20;
const disp_entry_off: usize = 55;
const disp_template = [_]u8{
    0x78, // 0  SEI
    // The write gates are SA-1-side registers: open them ourselves.
    0xA9, 0xFF, // 1  LDA #$FF
    0x8D, 0x2A, 0x22, // 3  STA $222A (CIWP: SA-1 may write all I-RAM)
    0xA9, 0x80, // 6  LDA #$80
    0x8D, 0x27, 0x22, // 8  STA $2227 (CBWE: SA-1 may write BW-RAM)
    0x18, // 11 CLC
    0xFB, // 12 XCE (native mode)
    0xC2, 0x10, // 13 REP #$10
    0xA2, 0x78, 0x37, // 15 LDX #$3778 (stack below the mailbox)
    0x9A, // 18 TXS
    0xF4, 0x00, 0x00, // 19 PEA <dp base> (fixup at +20)
    0x2B, // 22 PLD
    0xE2, 0x20, // 23 loop: SEP #$20
    0xAD, 0x01, 0x23, // 25 LDA $2301 (CFR)
    0x29, 0x0F, // 28 AND #$0F
    0xC9, 0x01, // 30 CMP #$01
    0xD0, 0xF5, // 32 BNE loop
    0xAD, 0x86, 0x37, // 34 LDA $3786 (caller P)
    0x48, // 37 PHA
    0xAD, 0x81, 0x37, // 38 LDA $3781 (B)
    0xEB, // 41 XBA
    0xAD, 0x80, 0x37, // 42 LDA $3780 (A low)
    0xC2, 0x10, // 45 REP #$10
    0xAE, 0x82, 0x37, // 47 LDX $3782
    0xAC, 0x84, 0x37, // 50 LDY $3784
    0x28, // 53 PLP (caller P: the routine's entry widths)
    0x20, 0x00, 0x00, // 54 JSR <entry> (fixup at +55)
    0x08, // 57 PHP (exit P)
    0xC2, 0x10, // 58 REP #$10
    0x8E, 0x82, 0x37, // 60 STX $3782
    0x8C, 0x84, 0x37, // 63 STY $3784
    0xE2, 0x20, // 66 SEP #$20
    0x8D, 0x80, 0x37, // 68 STA $3780
    0xEB, // 71 XBA
    0x8D, 0x81, 0x37, // 72 STA $3781
    0xEB, // 75 XBA
    0x68, // 76 PLA (exit P)
    0x8D, 0x86, 0x37, // 77 STA $3786
    0xA9, 0x01, // 80 LDA #$01
    0x8D, 0x09, 0x22, // 82 STA $2209 (done -> SFR)
    0xAD, 0x01, 0x23, // 85 wa: LDA $2301
    0x29, 0x0F, // 88 AND #$0F
    0xD0, 0xF9, // 90 BNE wa (S-CPU acked)
    0x9C, 0x09, 0x22, // 92 STZ $2209
    0x80, 0xB6, // 95 BRA loop (23 - 97 = -74 = $B6)
};

comptime {
    std.debug.assert(disp_template[disp_dp_off - 1] == 0xF4); // PEA
    std.debug.assert(disp_template[disp_entry_off - 1] == 0x20); // JSR
    std.debug.assert(stub_template.len == 68);
    std.debug.assert(disp_template.len == 97);
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
    const res = try convert(gpa, rom, &empty, null, &.{}, &ref);
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
    try testing.expectError(error.Refused, convert(gpa, rom, &empty, null, &.{}, &ref));
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
    const res = try convert(gpa, rom, &plan, usage, &.{}, &ref);
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
    const res2 = try convert(gpa, rom, &plan, usage, &.{}, &ref);
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
    const res = try convert(gpa, rom, &plan, usage, &.{}, &ref);
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
    const res2 = try convert(gpa, rom, &plan, usage, &.{}, &ref);
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
    const res = try convert(gpa, rom, &plan, usage, &.{}, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(RegionFate.blocked_abs_to_bwram, res.fate[0]);
    try testing.expectEqual(@as(u32, 0), res.stats.rewritten_long);

    // Long-only access to a BW-RAM region rewrites to $40:xxxx.
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0xEA, 0xEA, 0xEA }); // drop the abs site
    markOp(usage, 0x00_8100);
    const res2 = try convert(gpa, rom, &plan, usage, &.{}, &ref);
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
    const res = try convert(gpa, rom, &plan, usage, &.{}, &ref);
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
    const res = try convert(gpa, rom, &plan, usage, &.{0x00_8020}, &ref);
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
