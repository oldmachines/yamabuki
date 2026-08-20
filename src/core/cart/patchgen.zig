//! FastROM patch generation: the first rung of the auto-conversion ladder.
//!
//! Takes a SlowROM image and mechanically derives the transformation Project
//! FastROM applies by hand: turn the cartridge's 200ns banks into 120ns ones
//! and make the code actually execute there. Three edits, all derivable from
//! the image alone:
//!
//! 1. **The header speed bit** ($FFD5 bit 4), so hardware and emulators map
//!    the fast banks.
//! 2. **A reset stub**: MEMSEL ($420D) is 0 at power-on whatever the header
//!    says, so the reset vector is re-pointed at a 9-byte stub in free space
//!    that writes $420D bit 0 and jumps to the original entry point *in the
//!    $80 mirror* — from the first instruction onward, fetches run at fast
//!    timing.
//! 3. **Interrupt trampolines**: an interrupt forces PBR=$00, dropping the
//!    handler back into the slow mirror. Every ROM-targeting vector is
//!    re-pointed at a 4-byte `JML $80:handler` trampoline, so handlers run
//!    fast too. Vectors into RAM are left alone — RAM speed is fixed.
//!
//! A game that clears MEMSEL itself (the stock init idiom `STZ $420D`) would
//! silently undo edit 2, so the caller can pass the PCs it *observed* storing
//! to $420D during a profiled run; plain `STZ`/`STA $420D` stores are NOPed
//! out (pinning MEMSEL at 1 — exactly the semantics the emulator's own
//! `--auto-fastrom` verifies against), and anything cleverer (an indexed
//! store sweeping a register block) is a refusal, not a guess.
//!
//! What this module does NOT do is decide whether the result is *correct* for
//! this game: code cycle-timed against SlowROM latency genuinely breaks. That
//! judgement belongs to the caller's verification run (frame-hash equivalence
//! against the unpatched ROM), which gates every patch before it is written.
//! This module only refuses what it can prove wrong: FastROM already on,
//! coprocessor carts (their own bus timing, and SA-1/GSU games don't run
//! their hot code on the S-CPU bus anyway), ExHiROM (none are SlowROM
//! commercial carts worth converting; keeps the address math honest), no
//! free space, or vectors that don't parse.
//!
//! Pure functions over byte slices — no console, no OS. The only allocation
//! is the transformed image, through the caller's allocator.

const std = @import("std");
const header_mod = @import("header.zig");
const cartridge = @import("cartridge.zig");
const usage_map = @import("../usage_map.zig");

pub const Error = error{ OutOfMemory, NoHeader, RomTooSmall, Refused };

pub const Reason = enum {
    already_fastrom,
    coprocessor,
    exhirom,
    reset_vector_not_rom,
    no_free_space,
    memsel_store_unpatchable,

    pub fn describe(self: Reason) []const u8 {
        return switch (self) {
            .already_fastrom => "the cartridge is already FastROM",
            .coprocessor => "coprocessor cartridges have their own bus timing; a FastROM patch does not apply",
            .exhirom => "ExHiROM mapping is not supported by the generator",
            .reset_vector_not_rom => "the reset vector does not point into ROM",
            .no_free_space => "no padding run in bank $00 is large enough for the reset stub and trampolines",
            .memsel_store_unpatchable => "the game clears MEMSEL ($420D) with a store the generator cannot safely neutralise",
        };
    }
};

/// Filled in on `error.Refused` so the frontend can print the reason.
pub const Refusal = struct {
    reason: Reason,
    /// `memsel_store_unpatchable`: the PC of the store. `no_free_space`: the
    /// bytes that were needed.
    detail: u32 = 0,
};

pub const Result = struct {
    /// The transformed image, owned by the caller's allocator. Same length
    /// as the input — every edit is in place.
    image: []u8,
    /// Bank $00 address of the reset stub.
    stub_addr: u16,
    /// ROM-targeting vectors re-pointed through JML trampolines.
    trampolines: u8,
    /// Observed MEMSEL-clearing stores neutralised to NOPs.
    memsel_stores_nopped: u8,
    /// Covered long-bank operands lifted into the $80+ mirrors.
    banks_lifted: u32 = 0,
};

pub const Options = struct {
    /// PCs observed storing to $420D during a baseline run (the profiler
    /// records them; see `profile.Profiler`). Any value counts: a store of 1
    /// is redundant once the stub runs, a store of 0 is the bug being
    /// prevented — NOPing either pins MEMSEL at 1.
    memsel_store_pcs: []const u24 = &.{},
    /// COMPOSITION MODE (the SA-1 window conversion layers FastROM on
    /// top): the standing coprocessor refusal is wrong for an image OUR
    /// converter produced — the game demonstrably runs on the S-CPU, and
    /// the SA-1 MMC serves the $80+ mirrors at fast timing under MEMSEL
    /// like any FastROM cart.
    allow_coprocessor: bool = false,
    /// Skip the $FFD5 speed-bit edit: an SA-1 image's map byte ($23)
    /// identifies the cart, and MEMSEL — which the stub pins — is what
    /// actually selects the speed.
    keep_map_mode: bool = false,
    /// BANK LIFTING (a bsnes-format usage map, or null to skip): rewrite
    /// every covered long-bank operand — JSL/JML and the long data forms
    /// — whose bank is $00-$3F to the $80+ mirror. The stub-and-
    /// trampoline model assumes execution RIDES PBR into the fast
    /// mirrors, but a game that long-calls with explicit bank-$00
    /// operands (measured: Gradius III's frame loop does on every call)
    /// drops back to the slow mirror instructions after each interrupt
    /// and stays there — zero gain. The system area mirrors identically
    /// in $80-$BF (WRAM low, MMIO), ROM turns fast, and banks $40+ are
    /// never touched (SA-1 BW-RAM lives there). The SA-1's own decoder
    /// treats $80-$BF exactly like $00-$3F, so lifted operands stay
    /// consistent when a tree copy executes them.
    lift_usage: ?[]const u8 = null,
};

/// The reset stub: LDA #$01 / STA $420D / JML $80:<reset>. 9 bytes.
/// (No SEI — the I flag is already set at reset.)
const stub_len = 9;
/// One trampoline: JML $80:<handler>. 4 bytes.
const tramp_len = 4;

/// Offsets of the re-pointable vectors within the $xxC0 header block:
/// native COP/BRK/ABORT/NMI/IRQ, emulation COP/ABORT/NMI/IRQ-BRK.
/// The emulation RESET ($FFFC, +0x3C) is handled by the stub instead.
const tramp_vector_offsets = [_]u32{ 0x24, 0x26, 0x28, 0x2A, 0x2E, 0x34, 0x38, 0x3A, 0x3E };
const reset_vector_offset: u32 = 0x3C;

/// Generate the FastROM transformation of a de-headered (copier-stripped)
/// ROM image. `refusal` is written only on `error.Refused`.
pub fn generate(
    gpa: std.mem.Allocator,
    image: []const u8,
    opts: Options,
    refusal: *?Refusal,
) Error!Result {
    if (image.len < 0x8000) return error.RomTooSmall;
    const header = try header_mod.detect(image);

    if (header.fastRom()) return refuse(refusal, .{ .reason = .already_fastrom });
    if (!opts.allow_coprocessor and cartridge.identifyChip(header) != .none)
        return refuse(refusal, .{ .reason = .coprocessor });
    if (header.mapping == .exhirom) return refuse(refusal, .{ .reason = .exhirom });

    const reset = header.reset_vector;
    if (reset < 0x8000) return refuse(refusal, .{ .reason = .reset_vector_not_rom });

    // Vectors worth a trampoline: ROM targets, deduplicated ($0000/$FFFF are
    // unused-slot padding). Collected before free space so the space needed
    // is known exactly.
    var targets: [tramp_vector_offsets.len]u16 = undefined;
    var n_targets: usize = 0;
    for (tramp_vector_offsets) |off| {
        const v = std.mem.readInt(u16, image[header.offset + off ..][0..2], .little);
        if (v < 0x8000 or v == 0xFFFF) continue;
        const dup = for (targets[0..n_targets]) |t| {
            if (t == v) break true;
        } else false;
        if (!dup) {
            targets[n_targets] = v;
            n_targets += 1;
        }
    }

    const need: u32 = stub_len + tramp_len * @as(u32, @intCast(n_targets));

    // Bank $00's ROM window in the file: LoROM maps $00:8000-FFFF from file
    // offset 0, HiROM from file offset $8000. The window stops at the header
    // block — the classic place for padding is right in front of it.
    const window_start: u32 = switch (header.mapping) {
        .lorom => 0,
        .hirom => 0x8000,
        .exhirom => unreachable,
    };
    const window_end: u32 = header.offset; // $xxC0

    const carve = findFreeSpace(image[window_start..window_end], need) orelse
        return refuse(refusal, .{ .reason = .no_free_space, .detail = need });
    const carve_file: u32 = window_start + carve;
    // In both mappings the bank-$00 CPU address of a window byte is $8000
    // plus its offset into the window (LoROM: file 0 maps to $8000; HiROM:
    // file $8000 *is* $8000).
    const cpu_base: u16 = 0x8000;

    const out = try gpa.dupe(u8, image);
    errdefer gpa.free(out);

    // Neutralise observed MEMSEL stores first — a refusal here must not leak
    // a half-transformed image (errdefer frees it).
    var nopped: u8 = 0;
    for (opts.memsel_store_pcs) |pc| {
        const file_off = pcToFileOffset(header, image.len, pc) orelse
            return refuse(refusal, .{ .reason = .memsel_store_unpatchable, .detail = pc });
        const b = out[file_off..][0..3];
        // STZ $420D (9C 0D 42) or STA $420D (8D 0D 42) — the only shapes
        // whose removal provably just pins MEMSEL. Indexed sweeps and
        // anything else refuse.
        if ((b[0] != 0x9C and b[0] != 0x8D) or b[1] != 0x0D or b[2] != 0x42)
            return refuse(refusal, .{ .reason = .memsel_store_unpatchable, .detail = pc });
        @memset(b, 0xEA); // NOP NOP NOP
        nopped += 1;
    }

    // The stub, then the trampolines, packed at the carve.
    const stub_addr: u16 = cpu_base + @as(u16, @intCast(carve));
    var w = out[carve_file..];
    w[0] = 0xA9; // LDA #$01
    w[1] = 0x01;
    w[2] = 0x8D; // STA $420D
    w[3] = 0x0D;
    w[4] = 0x42;
    w[5] = 0x5C; // JML $80:<reset>
    w[6] = @truncate(reset);
    w[7] = @truncate(reset >> 8);
    w[8] = 0x80;
    std.mem.writeInt(u16, out[header.offset + reset_vector_offset ..][0..2], stub_addr, .little);

    for (targets[0..n_targets], 0..) |t, i| {
        const at = stub_len + i * tramp_len;
        w[at] = 0x5C; // JML $80:<handler>
        w[at + 1] = @truncate(t);
        w[at + 2] = @truncate(t >> 8);
        w[at + 3] = 0x80;
        const tramp_addr: u16 = stub_addr + @as(u16, @intCast(at));
        for (tramp_vector_offsets) |off| {
            const v = std.mem.readInt(u16, image[header.offset + off ..][0..2], .little);
            if (v == t) std.mem.writeInt(u16, out[header.offset + off ..][0..2], tramp_addr, .little);
        }
    }

    if (!opts.keep_map_mode) out[header.offset + 0x15] |= 0x10; // the FastROM speed bit

    // Bank lifting (see Options.lift_usage). LoROM only — the composed
    // window images are LoROM by construction, and the plain generator
    // path passes null.
    var lifted: u32 = 0;
    if (opts.lift_usage) |usage| {
        std.debug.assert(header.mapping == .lorom);
        const n_banks = out.len / 0x8000;
        for (0..n_banks) |bank| {
            var a16: u32 = 0x8000;
            while (a16 < 0x10000) {
                const pc: u32 = @intCast(bank << 16 | a16);
                const cov = usage[pc] | usage[0x80_0000 | pc];
                if (cov & usage_map.flag_opcode == 0) {
                    a16 += 1;
                    continue;
                }
                const file = bank * 0x8000 + (a16 - 0x8000);
                const op = out[file];
                const m8 = cov & usage_map.flag_m != 0;
                const x8 = cov & usage_map.flag_x != 0;
                const is_long = op == 0x22 or op == 0x5C or
                    usage_map.mode(op) == .long or usage_map.mode(op) == .long_x;
                // Lift only banks the ROM actually occupies (plus bank 0's
                // WRAM/MMIO longs, which mirror identically). This keeps
                // hands off the window conversion's $3F negative-offset
                // idiom — $3F:FFxx wraps into $40 BW-RAM, and $BF would
                // wrap into $C0 ROM instead.
                //
                // NEGATIVE-IDIOM BASES ($FFxx) are never lifted at all: the
                // wrapped walk can land in OPEN BUS, where the value read
                // is the MDR — the instruction's own last-fetched operand
                // byte, i.e. THE BANK BYTE. Lifting $02:FFFF,X to $82
                // changed Gradius III's slot-scan garbage reads from $0202
                // to $8282; the value seeds the walker's link cells, $02xx
                // is WRAM-domain where $82xx is ROM-domain, and the walks
                // diverged into a ROM self-cycle at the stage-1 boss
                // (frozen game, watchdog blind — the loop is on the S-CPU).
                // Keeping the stock bank keeps the garbage stock-equal.
                const a16_op: u16 = if (file + 3 < out.len)
                    std.mem.readInt(u16, out[file + 1 ..][0..2], .little)
                else
                    0;
                if (is_long and file + 3 < out.len and out[file + 3] < @min(n_banks, 0x40) and
                    a16_op < 0xFF00)
                {
                    out[file + 3] |= 0x80;
                    lifted += 1;
                }
                a16 += usage_map.instrLen(op, m8, x8);
            }
        }
    }
    recomputeChecksum(out, header.offset);

    return .{
        .image = out,
        .stub_addr = stub_addr,
        .trampolines = @intCast(n_targets),
        .memsel_stores_nopped = nopped,
        .banks_lifted = lifted,
    };
}

fn refuse(refusal: *?Refusal, r: Refusal) Error {
    refusal.* = r;
    return error.Refused;
}

/// Find `need` bytes of padding in `window`: the tail of the longest run of
/// identical $00 or $FF bytes, kept at least 8 bytes clear of the run's start
/// so an off-by-one in the neighbouring data's own length costs nothing.
/// Returns the offset within `window`, or null.
/// `findFreeSpace`, but the span returned never crosses a bank boundary.
///
/// File contiguity is NOT address contiguity in LoROM: each bank exposes
/// only 32 KiB at $8000-$FFFF, and the 65816's program counter wraps WITHIN
/// a bank — after $xx:FFFF comes $xx:0000, which is the WRAM mirror, not the
/// next bank's ROM. Code placed across the seam therefore runs off the end
/// of the bank and executes whatever the mirror holds; after a window
/// conversion that is abandoned memory.
///
/// Measured: with the image expanded to 1 MiB, the offload tree copies were
/// placed at file $F72B6 needing 5638 bytes while bank $1E had 3402 left.
/// Execution ran off $1E:FFFF, wrapped to $1E:0000, and the game died about
/// a minute into play — `$1E:0B9F`, deep in the mirror. The 512 KiB image
/// never showed it because its biggest run ended exactly on the boundary.
///
/// Banks are searched from the top down and the span is taken at the run's
/// tail, which keeps the copies out of the low banks whose padding the
/// bank-local thunks need. Bank $00 is never offered: the boot shim and the
/// scaffold's carve live there.
pub fn findFreeSpaceInBank(image: []const u8, need: u32) ?u32 {
    const margin = 8;
    if (need == 0) return null;
    var bank: u32 = @intCast(image.len / 0x8000);
    while (bank > 1) {
        bank -= 1;
        const lo: usize = bank * 0x8000;
        const hi: usize = @min(lo + 0x8000, image.len);
        var i: usize = lo;
        var best: ?u32 = null;
        while (i < hi) {
            const b = image[i];
            if (b != 0x00 and b != 0xFF) {
                i += 1;
                continue;
            }
            var j = i + 1;
            while (j < hi and image[j] == b) j += 1;
            if (j - i >= need + margin) best = @intCast(j - need);
            i = j;
        }
        if (best) |at| return at;
    }
    return null;
}

pub fn findFreeSpace(window: []const u8, need: u32) ?u32 {
    const margin = 8;
    var best_off: u32 = 0;
    var best_len: u32 = 0;
    var i: usize = 0;
    while (i < window.len) {
        const b = window[i];
        if (b == 0x00 or b == 0xFF) {
            var j = i + 1;
            while (j < window.len and window[j] == b) j += 1;
            const len: u32 = @intCast(j - i);
            // >= keeps the LAST equally-long run: padding lives at the end
            // of banks, data tables at their start.
            if (len >= best_len) {
                best_len = len;
                best_off = @intCast(i);
            }
            i = j;
        } else i += 1;
    }
    if (best_len < need + margin) return null;
    return best_off + best_len - need;
}

/// Map an executing PC to its file offset, or null when it cannot be located
/// exactly (a mirror beyond the image, or an address outside the ROM area).
fn pcToFileOffset(header: header_mod.Header, image_len: usize, pc: u24) ?u32 {
    const bank: u8 = @truncate(pc >> 16);
    const a16: u16 = @truncate(pc);
    const off: u32 = switch (header.mapping) {
        .lorom => blk: {
            if (a16 < 0x8000) return null;
            break :blk @as(u32, bank & 0x7F) * 0x8000 + (a16 - 0x8000);
        },
        .hirom => blk: {
            const b = bank & 0x7F;
            if (b < 0x40 and a16 < 0x8000) return null;
            break :blk @as(u32, b & 0x3F) * 0x1_0000 + a16;
        },
        .exhirom => return null,
    };
    if (off + 3 > image_len) return null;
    return off;
}

/// Recompute the header checksum/complement pair over the whole image, with
/// the four checksum bytes counted at their canonical $FF $FF $00 $00. For a
/// non-power-of-two image the trailing chunk is weighted the way hardware
/// mirroring repeats it (384 KiB = 256 + 2x128, and so on); if the size is
/// too irregular even for that, the plain sum stands — the pair is still
/// self-consistent, which is all the console ever checks.

pub fn recomputeChecksum(image: []u8, header_offset: u32) void {
    const cs = header_offset + 0x1C;
    var sum: u32 = 0x1FE; // FF + FF + 00 + 00
    const p = std.math.floorPowerOfTwo(usize, image.len);
    const rest = image.len - p;
    const mult: u32 = if (rest != 0 and p % rest == 0) @intCast(p / rest) else 1;
    for (image, 0..) |b, i| {
        if (i >= cs and i < cs + 4) continue;
        sum +%= if (i < p) b else @as(u32, b) * mult;
    }
    const checksum: u16 = @truncate(sum);
    std.mem.writeInt(u16, image[cs..][0..2], checksum ^ 0xFFFF, .little);
    std.mem.writeInt(u16, image[cs + 2 ..][0..2], checksum, .little);
}

// --- tests ---------------------------------------------------------------------

const testing = std.testing;

/// A minimal, detectable SlowROM image: header, reset vector, NMI vector,
/// code bytes at the entry points, and padding in front of the header block.
fn makeRom(gpa: std.mem.Allocator, mapping: header_mod.Mapping) ![]u8 {
    const size: usize = switch (mapping) {
        .lorom => 64 * 1024,
        else => 128 * 1024,
    };
    const rom = try gpa.alloc(u8, size);
    // Non-padding filler so the free-space search can't land just anywhere.
    for (rom, 0..) |*b, i| b.* = @truncate(0x11 + i *% 7);
    const hoff: u32 = switch (mapping) {
        .lorom => 0x7FC0,
        else => 0xFFC0,
    };
    const h = rom[hoff..][0..64];
    @memcpy(h[0..21], "FASTROM GEN TEST     ");
    h[0x15] = switch (mapping) {
        .lorom => 0x20,
        else => 0x21,
    };
    h[0x16] = 0x00; // no coprocessor
    h[0x17] = 8;
    h[0x18] = 0;
    std.mem.writeInt(u16, h[0x1C..0x1E], 0xFFFF, .little);
    std.mem.writeInt(u16, h[0x1E..0x20], 0x0000, .little);
    // Zero the vector table first — the filler pattern above would otherwise
    // read as plausible ROM vectors in the slots this test leaves unset.
    @memset(h[0x20..0x40], 0);
    // Vectors: NMI + IRQ share a handler (dedupe case), COP unused padding.
    std.mem.writeInt(u16, h[0x2A..0x2C], 0x9000, .little); // native NMI
    std.mem.writeInt(u16, h[0x2E..0x30], 0x9000, .little); // native IRQ
    std.mem.writeInt(u16, h[0x24..0x26], 0xFFFF, .little); // native COP: unused
    std.mem.writeInt(u16, h[0x3A..0x3C], 0x1FF0, .little); // emu NMI: RAM handler
    std.mem.writeInt(u16, h[0x3C..0x3E], 0x8123, .little); // reset
    // 96 bytes of $FF padding in front of the header block.
    const pad_end = hoff;
    @memset(rom[pad_end - 96 .. pad_end], 0xFF);
    return rom;
}

test "generate: lorom stub, trampolines, speed bit, checksum" {
    const gpa = testing.allocator;
    const rom = try makeRom(gpa, .lorom);
    defer gpa.free(rom);

    var ref: ?Refusal = null;
    const res = try generate(gpa, rom, .{}, &ref);
    defer gpa.free(res.image);

    // One trampoline: NMI and IRQ share the $9000 handler; COP is padding
    // and the emulation NMI points at RAM.
    try testing.expectEqual(@as(u8, 1), res.trampolines);

    const h = try header_mod.detect(res.image);
    try testing.expect(h.fastRom());
    try testing.expectEqual(header_mod.Mapping.lorom, h.mapping);
    // The checksum pair is valid again after the edits.
    try testing.expectEqual(@as(u16, 0xFFFF), h.checksum ^ h.checksum_complement);

    // Reset vector points at the stub; the stub is LDA/STA/JML $80:8123.
    try testing.expectEqual(res.stub_addr, h.reset_vector);
    const stub_file = @as(u32, res.stub_addr) - 0x8000;
    try testing.expectEqualSlices(
        u8,
        &.{ 0xA9, 0x01, 0x8D, 0x0D, 0x42, 0x5C, 0x23, 0x81, 0x80 },
        res.image[stub_file..][0..stub_len],
    );
    // The trampoline right behind it: JML $80:9000, and both vectors point at it.
    try testing.expectEqualSlices(
        u8,
        &.{ 0x5C, 0x00, 0x90, 0x80 },
        res.image[stub_file + stub_len ..][0..tramp_len],
    );
    const tramp_addr = res.stub_addr + stub_len;
    try testing.expectEqual(tramp_addr, std.mem.readInt(u16, res.image[0x7FC0 + 0x2A ..][0..2], .little));
    try testing.expectEqual(tramp_addr, std.mem.readInt(u16, res.image[0x7FC0 + 0x2E ..][0..2], .little));
    // The RAM-targeting emulation NMI vector is untouched.
    try testing.expectEqual(@as(u16, 0x1FF0), std.mem.readInt(u16, res.image[0x7FC0 + 0x3A ..][0..2], .little));
    // The stub landed inside the $FF padding run, clear of its start.
    try testing.expect(stub_file >= 0x7FC0 - 96 + 8);
}

test "generate: hirom address math" {
    const gpa = testing.allocator;
    const rom = try makeRom(gpa, .hirom);
    defer gpa.free(rom);

    var ref: ?Refusal = null;
    const res = try generate(gpa, rom, .{}, &ref);
    defer gpa.free(res.image);

    const h = try header_mod.detect(res.image);
    try testing.expect(h.fastRom());
    // HiROM bank $00:$8000+ *is* the file offset; the stub sits in the
    // padding just under $FFC0.
    try testing.expectEqual(res.stub_addr, h.reset_vector);
    try testing.expect(res.stub_addr >= 0xFFC0 - 96 and res.stub_addr < 0xFFC0);
    try testing.expectEqualSlices(
        u8,
        &.{ 0xA9, 0x01, 0x8D, 0x0D, 0x42, 0x5C, 0x23, 0x81, 0x80 },
        res.image[res.stub_addr..][0..stub_len],
    );
}

test "generate: memsel stores are NOPed when plain, refused when indexed" {
    const gpa = testing.allocator;
    const rom = try makeRom(gpa, .lorom);
    defer gpa.free(rom);
    // STZ $420D at $00:8200 (file $0200); STA $420D at $00:8210.
    @memcpy(rom[0x0200..0x0203], &[_]u8{ 0x9C, 0x0D, 0x42 });
    @memcpy(rom[0x0210..0x0213], &[_]u8{ 0x8D, 0x0D, 0x42 });

    var ref: ?Refusal = null;
    const res = try generate(gpa, rom, .{
        .memsel_store_pcs = &.{ 0x00_8200, 0x00_8210 },
    }, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u8, 2), res.memsel_stores_nopped);
    try testing.expectEqualSlices(u8, &.{ 0xEA, 0xEA, 0xEA }, res.image[0x0200..0x0203]);
    try testing.expectEqualSlices(u8, &.{ 0xEA, 0xEA, 0xEA }, res.image[0x0210..0x0213]);

    // An indexed sweep (STA $4200,X passing through $420D) must refuse.
    @memcpy(rom[0x0220..0x0223], &[_]u8{ 0x9D, 0x00, 0x42 });
    var ref2: ?Refusal = null;
    try testing.expectError(error.Refused, generate(gpa, rom, .{
        .memsel_store_pcs = &.{0x00_8220},
    }, &ref2));
    try testing.expectEqual(Reason.memsel_store_unpatchable, ref2.?.reason);
    try testing.expectEqual(@as(u32, 0x00_8220), ref2.?.detail);
}

test "generate: refusals name their reason" {
    const gpa = testing.allocator;

    // Already FastROM.
    {
        const rom = try makeRom(gpa, .lorom);
        defer gpa.free(rom);
        rom[0x7FC0 + 0x15] |= 0x10;
        var ref: ?Refusal = null;
        try testing.expectError(error.Refused, generate(gpa, rom, .{}, &ref));
        try testing.expectEqual(Reason.already_fastrom, ref.?.reason);
    }
    // Coprocessor cart.
    {
        const rom = try makeRom(gpa, .lorom);
        defer gpa.free(rom);
        rom[0x7FC0 + 0x16] = 0x33; // SA-1
        var ref: ?Refusal = null;
        try testing.expectError(error.Refused, generate(gpa, rom, .{}, &ref));
        try testing.expectEqual(Reason.coprocessor, ref.?.reason);
    }
    // No free space: overwrite the padding with data.
    {
        const rom = try makeRom(gpa, .lorom);
        defer gpa.free(rom);
        for (rom[0x7FC0 - 96 .. 0x7FC0], 0..) |*b, i| b.* = @truncate(0x23 + i *% 5);
        var ref: ?Refusal = null;
        try testing.expectError(error.Refused, generate(gpa, rom, .{}, &ref));
        try testing.expectEqual(Reason.no_free_space, ref.?.reason);
        try testing.expect(ref.?.detail >= stub_len);
    }
}

test "findFreeSpace prefers the last long run and keeps a start margin" {
    var buf: [256]u8 = @splat(0x11);
    @memset(buf[20..60], 0x00); // 40-byte run
    @memset(buf[200..248], 0xFF); // 48-byte run, later
    const off = findFreeSpace(&buf, 16).?;
    try testing.expectEqual(@as(u32, 248 - 16), off);
    // Too big for any run: null.
    try testing.expectEqual(@as(?u32, null), findFreeSpace(&buf, 48));
}

test "recomputeChecksum: non-power-of-two weighting stays self-consistent" {
    const gpa = testing.allocator;
    // 96 KiB = 64 + 2x32 mirrored.
    const rom = try gpa.alloc(u8, 96 * 1024);
    defer gpa.free(rom);
    for (rom, 0..) |*b, i| b.* = @truncate(i *% 13);
    recomputeChecksum(rom, 0x7FC0);
    const c = std.mem.readInt(u16, rom[0x7FC0 + 0x1E ..][0..2], .little);
    const k = std.mem.readInt(u16, rom[0x7FC0 + 0x1C ..][0..2], .little);
    try testing.expectEqual(@as(u16, 0xFFFF), c ^ k);
    // The checksum equals the byte sum with the pair counted as FF FF 00 00,
    // trailing 32 KiB counted twice.
    var want: u32 = 0x1FE;
    for (rom, 0..) |b, i| {
        if (i >= 0x7FC0 + 0x1C and i < 0x7FC0 + 0x20) continue;
        want +%= if (i < 64 * 1024) b else @as(u32, b) * 2;
    }
    try testing.expectEqual(@as(u16, @truncate(want)), c);
}

test "findFreeSpaceInBank: a span never crosses the bank seam" {
    const gpa = std.testing.allocator;
    const image = try gpa.alloc(u8, 4 * 0x8000); // banks $00-$03
    defer gpa.free(image);
    @memset(image, 0x11); // occupied

    // Free space straddling the $02/$03 seam: 3000 bytes before it, 3000
    // after. `findFreeSpace` would happily hand back a span across the
    // middle; this must not.
    const seam: usize = 3 * 0x8000;
    @memset(image[seam - 3000 .. seam + 3000], 0xFF);

    // 5000 bytes cannot be placed: neither side of the seam holds it.
    try std.testing.expectEqual(@as(?u32, null), findFreeSpaceInBank(image, 5000));

    // 2000 fits on one side — and whichever side it picks, the whole span
    // must live in one bank.
    const at = findFreeSpaceInBank(image, 2000).?;
    try std.testing.expectEqual(at / 0x8000, (at + 2000 - 1) / 0x8000);
    for (image[at..][0..2000]) |b| try std.testing.expectEqual(@as(u8, 0xFF), b);

    // Bank $00 is never offered: the boot shim's carve lives there.
    @memset(image[0..0x8000], 0xFF);
    @memset(image[0x8000..], 0x11);
    try std.testing.expectEqual(@as(?u32, null), findFreeSpaceInBank(image, 100));
}
