//! De-mirroring and relocation passes over the image: LoROM file offsets, HDMA indirect tables, queue bank immediates, WMDATA port fills, twin JSLs.
//!
//! Carved out of sa1gen.zig as pure code motion; every declaration here is
//! re-exported from sa1gen.zig, which stays the module's public root.

const std = @import("std");
const usage_map = @import("../../usage_map.zig");
const sa1gen = @import("../sa1gen.zig");
const testing = std.testing;

const Result = sa1gen.Result;
const wg_bw_window = sa1gen.wg_bw_window;
/// The file offset a runtime CPU address reads from, under the window
/// conversion's map. A <=2 MiB image is plain LoROM; a >2 MiB image follows
/// the shim's Super-MMC programming ($00-$1F/$80-$9F -> MB0, $20-$3F -> MB1,
/// $A0-$BF -> MB2), which is where the de-mirror pass parks the content.
/// Only ROM homes are mapped; a bank with no fixed ROM home returns null.
pub fn loromFileOffset(image_len: usize, cpu: u24) ?usize {
    const bank: u32 = (cpu >> 16) & 0xFF;
    const a16: u32 = cpu & 0xFFFF;
    if (a16 < 0x8000) return null;
    const off: usize = a16 - 0x8000;
    const file: usize = if (image_len <= 0x20_0000)
        (bank & 0x7F) * 0x8000 + off
    else if (bank < 0x20 or (bank >= 0x80 and bank < 0xA0))
        (bank & 0x1F) * 0x8000 + off // MB0
    else if (bank >= 0x20 and bank < 0x40)
        (bank - 0x20) * 0x8000 + 0x10_0000 + off // MB1
    else if (bank >= 0xA0 and bank < 0xC0)
        (bank - 0xA0) * 0x8000 + 0x20_0000 + off // MB2
    else
        return null;
    return if (file < image_len) file else null;
}

/// Relocate low-WRAM indirect addresses inside the profiled indirect-HDMA
/// tables (window mode; see PtrBankEvidence.hdma_tables and the Ceres
/// escape). Each table is a run of `[line-count][addr-lo][addr-hi]` entries
/// terminated by a zero count; an entry whose 16-bit indirect address names
/// the moved low 8 KiB (< $2000) is shifted +$6000 so the DMA unit fetches
/// the relocated buffer through the window instead of the abandoned physical
/// mirror. The count byte's bit 7 (repeat vs. continuous) does not change the
/// three-byte stride. Bounded against a table whose terminator was itself a
/// relocated byte, and skips a table whose home is not statically mappable.
pub fn relocateHdmaIndirect(out: []u8, tables: []const u24, res: *Result) void {
    for (tables) |cpu| {
        var f = loromFileOffset(out.len, cpu) orelse continue;
        var guard: usize = 0;
        while (guard < 256) : (guard += 1) {
            if (f + 3 > out.len) break;
            if (out[f] == 0) break; // zero line-count ends the table
            const addr = std.mem.readInt(u16, out[f + 1 ..][0..2], .little);
            if (addr < 0x2000) {
                std.mem.writeInt(u16, out[f + 1 ..][0..2], addr + wg_bw_window, .little);
                res.stats.rewritten_hdma_indirect += 1;
            }
            f += 3;
        }
    }
}

/// Bank immediates bound for a dispatch queue, BY SIGNATURE, coverage or
/// not — the same stance as the `STA $00 / JMP ($0000)` macro net, and for
/// the same reason: post-fork trajectories pull queue entries no finite
/// stock profile can lead to. The shape is Super Metroid's sound-library
/// enqueue:
///
///     consumer:  LDA $6FA6,X ... XBA / PHA / PLB / PLB
///                (bank in the loaded word's LOW byte: the column it
///                loads from is a BANK COLUMN)
///     producer:  LDA #$00A3 ... STA $6FA6,X
///                (the bank travels as a 16-bit immediate, consumed
///                thousands of cycles later by different code)
///
/// The measured pointer-bank net re-banks the producers a profiled run
/// executed; a missed one BRKs into the game's crash trap on the first
/// off-profile timeline that pulls its entry (measured: Super Metroid's
/// attract, where the conversion's own lag differential queues a handler
/// stock timing never queues — and the evidence loop can never close it,
/// because every cover replay dies at that BRK before the PLB proves the
/// byte). The consumer's XBA/PHA/PLB/PLB tail names the column
/// statically; every producer keyed on that exact column then re-banks by
/// the same de-mirror map as the measured net. Columns are matched in
/// their POST-rewrite window form ($6000-$7FFF), so the pass runs after
/// the operand rewrites and never invents a column the walk did not
/// already move.
pub fn demirrorQueueBankImms(out: []u8, wide: bool) u32 {
    // Pass 1: bank columns, from the consumer signature. The XBA/PHA/
    // PLB/PLB tail is the key; the column is the last `LDA abs,X` with a
    // window operand in the handful of bytes before it.
    var cols: [16]u16 = undefined;
    var n_cols: usize = 0;
    var f: usize = 0;
    while (f + 4 <= out.len) : (f += 1) {
        if (!(out[f] == 0xEB and out[f + 1] == 0x48 and out[f + 2] == 0xAB and out[f + 3] == 0xAB)) continue;
        var col: ?u16 = null;
        var b: usize = f -| 12;
        while (b + 3 <= f) : (b += 1) {
            if (out[b] != 0xBD) continue;
            const v = std.mem.readInt(u16, out[b + 1 ..][0..2], .little);
            if (v >= wg_bw_window and v < wg_bw_window + 0x2000) col = v;
        }
        const c = col orelse continue;
        var known = false;
        for (cols[0..n_cols]) |e| {
            if (e == c) known = true;
        }
        if (!known and n_cols < cols.len) {
            cols[n_cols] = c;
            n_cols += 1;
        }
    }
    // Pass 2: producers keyed on those exact columns.
    var n: u32 = 0;
    for (cols[0..n_cols]) |c| {
        f = 0;
        while (f + 6 <= out.len) : (f += 1) {
            if (out[f] != 0xA9 or out[f + 2] != 0x00 or out[f + 3] != 0x9D) continue;
            if (std.mem.readInt(u16, out[f + 4 ..][0..2], .little) != c) continue;
            const bank = out[f + 1];
            if (bank == 0x7E or bank == 0x7F) {
                out[f + 1] = bank - 0x3E; // WRAM -> BW-RAM $40/$41
            } else if (wide and bank >= 0xA0 and bank <= 0xBF) {
                out[f + 1] = bank - 0x80; // MB1 mirror -> its de-mirror home
            } else if (wide and bank >= 0xC0 and bank <= 0xDF) {
                out[f + 1] = bank - 0x20; // misfit bank -> its parked home
            } else continue;
            n += 1;
        }
    }
    return n;
}

/// WRAM fills through the WMDATA port, re-aimed at the window BY SIGNATURE.
///
/// The S-CPU's WRAM data port ($2180, address in $2181-$2183) writes REAL
/// WRAM and nothing else: it cannot be pointed at BW-RAM. A window
/// conversion moves the game's WRAM into BW-RAM, so every fill the game
/// performs through the port lands in the abandoned home while every
/// reader — CPU and DMA alike, correctly relocated — looks in the window.
/// Nothing in the usual instruments sees it: the CPU's stores go to MMIO
/// ($2181-$2183, $2180), the DMA's B-bus target is $2180, and the write
/// into $7E happens inside the port, so neither the stale detector nor an
/// address watch ever names a $7E access.
///
/// Measured: Super Metroid's pause menu loads its map tilemap into
/// $7E:3400 and $7E:3800 this way — WMADD from three immediates, then
/// `JSL SetupHDMATransfer` with inline arguments (mode, B=$80, a `dl`
/// source, a `dw` length), then the $420B trigger. The graphics
/// decompressor later reuses $7E:3400 for its own output; stock restores
/// the map's legend rows by running the same port fill again before the
/// legend's own DMA re-uploads them. On the conversion the restore went
/// to the dead home, the legend DMA read the window, and the area map's
/// bottom rows drew as decompressed graphics — the garble a player saw
/// on v70-v72 (findings §4o). The bank-immediate net had even re-banked
/// the WMADD bank byte $7E to $40, which the port ignores ($2183 selects
/// $7E or $7F by its low bit alone): a rewrite that could never work.
///
/// The fix replaces the whole 32-byte site — WMADD setup, JSL with
/// arguments, trigger — with a block move that reaches BW-RAM directly:
///
///     PHB / PHP / REP #$30
///     LDX #src / LDY #dst / LDA #len-1
///     MVN dst_bank, src_bank
///     PLP / PLB / NOP x14
///
/// The MVN's source bank is the `dl` bank through the same de-mirror map
/// as every other bank byte (already folded when the walk reached the
/// site, raw when it did not); its destination is $40/$41 at the WMADD
/// offset. MVN sets DBR to the destination for its duration, hence the
/// PHB/PLB; PHP/PLP restores the caller's widths exactly. Five fixed
/// opcode groups over 32 bytes keep the signature off data.
pub fn relocateWmdataFills(out: []u8, wide: bool) u32 {
    var n: u32 = 0;
    var f: usize = 0;
    while (f + 32 <= out.len) : (f += 1) {
        const b = out[f..][0..32];
        // LDA #lo / STA $2181 / LDA #mid / STA $2182 / LDA #bank / STA $2183
        if (!(b[0] == 0xA9 and b[2] == 0x8D and b[3] == 0x81 and b[4] == 0x21 and
            b[5] == 0xA9 and b[7] == 0x8D and b[8] == 0x82 and b[9] == 0x21 and
            b[10] == 0xA9 and b[12] == 0x8D and b[13] == 0x83 and b[14] == 0x21)) continue;
        // JSL callee / db mode,$00,$80 (B-bus = WMDATA) / dl src / dw len / LDA #$02 / STA $420B
        if (!(b[15] == 0x22 and b[19] == 0x01 and b[20] == 0x00 and b[21] == 0x80 and
            b[27] == 0xA9 and b[28] == 0x02 and b[29] == 0x8D and b[30] == 0x0B and b[31] == 0x42)) continue;
        const dst_bank: u8 = switch (b[11]) {
            0x7E, 0x40 => 0x40,
            0x7F, 0x41 => 0x41,
            else => continue, // not a relocated home
        };
        const dst: u16 = @as(u16, b[6]) << 8 | b[1];
        const src: u16 = std.mem.readInt(u16, b[22..24], .little);
        const sb = b[24];
        const src_bank: u8 = if (sb == 0x7E or sb == 0x7F)
            sb - 0x3E
        else if (wide and sb >= 0xA0 and sb <= 0xBF)
            sb - 0x80
        else if (wide and sb >= 0xC0 and sb <= 0xDF)
            sb - 0x20
        else
            sb;
        const len: u16 = std.mem.readInt(u16, b[25..27], .little);
        if (len == 0) continue;
        const cnt: u16 = len - 1;
        const body = [_]u8{
            0x8B, 0x08, 0xC2, 0x30, // PHB / PHP / REP #$30
            0xA2, @truncate(src), @truncate(src >> 8), // LDX #src
            0xA0, @truncate(dst), @truncate(dst >> 8), // LDY #dst
            0xA9, @truncate(cnt), @truncate(cnt >> 8), // LDA #len-1
            0x54, dst_bank, src_bank, // MVN dst,src
            0x28, 0xAB, // PLP / PLB
        };
        @memcpy(b[0..body.len], &body);
        @memset(b[body.len..], 0xEA);
        n += 1;
        f += 31;
    }
    return n;
}

test "relocateWmdataFills: the pause-map port fill becomes an MVN into the window" {
    // Super Metroid $82:8EFD: WMADD = $7E:3400, DMA $B6:E400 -> $2180, $0400 bytes.
    var buf: [40]u8 = @splat(0xFF);
    const site = [_]u8{
        0xA9, 0x00, 0x8D, 0x81, 0x21, 0xA9, 0x34, 0x8D, 0x82, 0x21, 0xA9, 0x7E, 0x8D, 0x83, 0x21,
        0x22, 0xA9, 0x91, 0x80, 0x01, 0x00, 0x80, 0x00, 0xE4, 0xB6, 0x00, 0x04, 0xA9, 0x02, 0x8D,
        0x0B, 0x42,
    };
    @memcpy(buf[4..36], &site);
    try testing.expectEqual(@as(u32, 1), relocateWmdataFills(&buf, true));
    const want = [_]u8{ 0x8B, 0x08, 0xC2, 0x30, 0xA2, 0x00, 0xE4, 0xA0, 0x00, 0x34, 0xA9, 0xFF, 0x03, 0x54, 0x40, 0x36, 0x28, 0xAB };
    try testing.expectEqualSlices(u8, &want, buf[4..22]);
    for (buf[22..36]) |x| try testing.expectEqual(@as(u8, 0xEA), x);
    try testing.expectEqual(@as(u8, 0xFF), buf[36]); // nothing past the site
    // an already de-mirrored source ($36) and a re-banked WMADD ($40) give the same MVN
    @memcpy(buf[4..36], &site);
    buf[4 + 11] = 0x40;
    buf[4 + 24] = 0x36;
    try testing.expectEqual(@as(u32, 1), relocateWmdataFills(&buf, true));
    try testing.expectEqualSlices(u8, &want, buf[4..22]);
    // a port fill aimed at a bank the window does not move is left alone
    var site_b0 = site;
    site_b0[11] = 0x00;
    @memcpy(buf[4..36], &site_b0);
    try testing.expectEqual(@as(u32, 0), relocateWmdataFills(&buf, true));
    try testing.expectEqualSlices(u8, &site_b0, buf[4..36]);
}

/// Mirror-bank `JSL`s in code no surface reached, re-banked on the evidence
/// of their own de-mirrored twin.
///
/// Three of the six freezes Super Metroid's players found (findings §4f)
/// were one shape: a `JSL $A0-$BF:addr` at a site byte-identical to stock.
/// Nothing flags it — it is simply code no surface executed and the static
/// walk never reached, and the de-mirror pass above is coverage-gated.
/// Under the shim, region 3 carries MB2, so the call lands in a different
/// megabyte and BRKs. A census of one build found 51 distinct targets
/// across 628 call sites: one freeze per play session, indefinitely.
///
/// The proof that needs no coverage is the routine's OWN de-mirrored form.
/// In the CONVERTED image the same entry is already called as
/// `JSL $20-$3F:addr` by code that IS covered, and called repeatedly — the
/// observed counts run 20-77 per target. (Stock has no such call: Super
/// Metroid reaches everything through $80-$DF. The twin is minted by the
/// coverage-gated de-mirror pass, and this pass spends it.) So the mirror form names MB1 content, and re-banking it -$80 is
/// exactly the rewrite the de-mirror pass would have made had a surface
/// reached the site.
///
/// Two consequences of keying on the twin, both load-bearing:
///
///   * It stays off data. A byte triple in compressed graphics must be
///     preceded by `$22` AND match one of a few dozen specific 24-bit entry
///     addresses; over a 3 MiB image that is ~0.04 expected false hits.
///   * It introduces no new code for the walk to arbitrate. A covered call
///     to the twin is *why* the body is evidenced, so `extendCoverage` has
///     already walked and rewritten it (`$A0 & 0x7F` is `$20` — the walk's
///     LoROM fold happens to be the de-mirror for this range). This net
///     rewrites operands only, which is what makes it landable where a
///     blind 628-byte rewrite was not.
pub fn demirrorTwinJsls(gpa: std.mem.Allocator, image: []const u8, out: []u8, cov: []const u8) !u32 {
    // Covered calls per de-mirrored target, indexed by bank $20-$3F and
    // addr16 >= $8000 — the only shape a twin can have. Saturating u8.
    const calls = try gpa.alloc(u8, 0x20 * 0x8000);
    defer gpa.free(calls);
    @memset(calls, 0);

    var bank: u32 = 0;
    while (bank < 0x40) : (bank += 1) {
        const bank_file = bank * 0x8000;
        if (bank_file >= image.len) break;
        var a16: u32 = 0x8000;
        while (a16 < 0x1_0000) : (a16 += 1) {
            const cpu = (bank << 16) | a16;
            if ((cov[cpu] | cov[0x80_0000 | cpu]) & usage_map.flag_opcode == 0) continue;
            const file = bank_file + (a16 - 0x8000);
            // Read the CONVERTED image: stock never writes the $20-$3F form
            // (Super Metroid calls everything through $80-$DF), so the twin
            // exists only after the coverage-gated de-mirror pass above has
            // rewritten the covered sites. That pass is what mints the
            // evidence this one spends.
            if (file + 3 >= image.len or out[file] != 0x22) continue;
            const tb = out[file + 3];
            if (tb < 0x20 or tb > 0x3F) continue;
            const t = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
            if (t < 0x8000) continue;
            const idx = (@as(usize, tb - 0x20) << 15) | (t - 0x8000);
            if (calls[idx] != 0xFF) calls[idx] += 1;
        }
    }

    // Now the sites nothing reached. Scanned over the whole file, because
    // "the walk never got here" is the defining property of the class.
    var n: u32 = 0;
    var file: usize = 0;
    while (file + 3 < image.len) : (file += 1) {
        if (image[file] != 0x22) continue;
        const bk = image[file + 3];
        if (bk < 0xA0 or bk > 0xBF) continue;
        if (out[file + 3] != bk) continue; // already rewritten; not ours
        const t = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
        if (t < 0x8000) continue;
        const idx = (@as(usize, bk - 0xA0) << 15) | (t - 0x8000);
        if (calls[idx] < 2) continue; // one call is a coincidence
        out[file + 3] = bk - 0x80;
        n += 1;
    }
    return n;
}

test "demirrorTwinJsls: twin evidence re-banks the mirror form, once is not enough" {
    const gpa = testing.allocator;
    var img: [0x18_0000]u8 = @splat(0);
    // Two covered calls to $A0:C0AE, in bank $00 at $8000 and $8004. Stock
    // spells them the mirror way; the de-mirror pass has already re-banked
    // them in `out`, which is the only place the twin evidence exists.
    img[0] = 0x22;
    img[1] = 0xAE;
    img[2] = 0xC0;
    img[3] = 0xA0;
    img[4] = 0x22;
    img[5] = 0xAE;
    img[6] = 0xC0;
    img[7] = 0xA0;
    // One covered call to $21:9000 — evidenced only once.
    img[8] = 0x22;
    img[9] = 0x00;
    img[10] = 0x90;
    img[11] = 0x21;
    // Uncovered mirror forms of both, plus a mirror JSL to an unevidenced
    // target and one whose addr16 is not in the ROM half.
    const u = 0x10_0000;
    img[u + 0] = 0x22;
    img[u + 1] = 0xAE;
    img[u + 2] = 0xC0;
    img[u + 3] = 0xA0; // -> re-banked
    img[u + 4] = 0x22;
    img[u + 5] = 0x00;
    img[u + 6] = 0x90;
    img[u + 7] = 0xA1; // one twin call only -> left alone
    img[u + 8] = 0x22;
    img[u + 9] = 0x34;
    img[u + 10] = 0xD2;
    img[u + 11] = 0xB7; // no twin evidence -> left alone
    img[u + 12] = 0x22;
    img[u + 13] = 0x10;
    img[u + 14] = 0x00;
    img[u + 15] = 0xA0; // addr16 below $8000 -> left alone

    const cov = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(cov);
    @memset(cov, 0);
    for ([_]u32{ 0x008000, 0x008004, 0x008008 }) |c| cov[c] = usage_map.flag_opcode;

    var out: [0x18_0000]u8 = img;
    out[3] = 0x20; // what the coverage-gated de-mirror pass produced
    out[7] = 0x20;
    try testing.expectEqual(@as(u32, 1), try demirrorTwinJsls(gpa, &img, &out, cov));
    try testing.expectEqual(@as(u8, 0x20), out[u + 3]);
    try testing.expectEqual(@as(u8, 0xA1), out[u + 7]);
    try testing.expectEqual(@as(u8, 0xB7), out[u + 11]);
    try testing.expectEqual(@as(u8, 0xA0), out[u + 15]);
}
