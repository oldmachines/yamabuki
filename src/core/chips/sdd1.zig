//! S-DD1 (Nintendo/Ricoh): the graphics decompressor on the Star Ocean and
//! Street Fighter Alpha 2 boards. Two independent jobs, both here:
//!
//!  1. **Memory map controller.** The cart is bigger than LoROM can reach, so
//!     banks $C0-$FF are a 4 MiB window built from four 1 MiB slices, each
//!     selected by one register ($4804-$4807). Plain reads go through it —
//!     Star Ocean's reset code ends in `JML $C0:8001` and essentially the
//!     whole game runs from this window, so the banking alone is what a cart
//!     needs before any decompression matters.
//!
//!  2. **Decompressor.** A DMA channel armed through $4800/$4801 does not
//!     read ROM bytes: the chip expands a compressed stream at the channel's
//!     source address and feeds the DMA the decompressed bytes. Games point
//!     these transfers straight at VRAM.
//!
//! The decompressor is the "ABS lossless entropy" coder: a binary arithmetic
//! -style coder built from a probability estimator driving Golomb run-length
//! codes, with a context model keyed on neighbouring pixels. One bit comes
//! out per step and the output logic reassembles bits into SNES bitplane
//! bytes. Written from the published algorithm description (the S-DD1 page on
//! the Super Famicom Development Wiki), not from another emulator's source.
//!
//! Both tables are derived rather than copied. The Golomb run lengths follow
//! a closed form the documented decode tables imply (see `runLengths`), and
//! the 33-state probability evolution table is the documented state machine
//! carried verbatim — it is an irreducible hardware constant, the same
//! precedent as the S-DSP gaussian table.
//!
//! Fast-core simplification, documented on purpose: a decompressing DMA is
//! expanded synchronously as the transfer runs, so the chip has no observable
//! busy period and nothing schedules against it. No game can see the
//! difference — the transfer is what consumes the data.

const std = @import("std");

// --- Golomb run lengths ---------------------------------------------------

/// For order k the run field arrives MSB-first after the leading 1 bit, and
/// the number of MPS symbols before the terminating LPS is the field's
/// *bit-reversed complement*:
///
///     run = ~bitreverse_k(field)   (mod 2^k)
///
/// which is exactly what the documented order-4 decode table says: codeword
/// `1 0000` expands to fifteen MPS then an LPS, `1 1111` to an immediate LPS,
/// and a lone `0` to a full run of 2^k MPS with no LPS at all (handled by the
/// caller, not this table).
fn runLengths() [8][128]u8 {
    @setEvalBranchQuota(20000);
    var t: [8][128]u8 = @splat(@splat(0));
    for (0..8) |k| {
        for (0..@as(usize, 1) << @intCast(k)) |field| {
            var rev: usize = 0;
            for (0..k) |b| {
                if (field & (@as(usize, 1) << @intCast(b)) != 0)
                    rev |= @as(usize, 1) << @intCast(k - 1 - b);
            }
            t[k][field] = @intCast(~rev & ((@as(usize, 1) << @intCast(k)) - 1));
        }
    }
    return t;
}

const run_lengths = runLengths();

// --- probability evolution ------------------------------------------------

const State = struct {
    /// Golomb order this state codes with.
    code: u3,
    next_mps: u8,
    next_lps: u8,
};

/// The documented 33-state estimator. States 0 and 1 are the only ones that
/// flip the context's MPS when a run ends in an LPS (`mpsFlips` below).
const evolution = [33]State{
    .{ .code = 0, .next_mps = 25, .next_lps = 25 },
    .{ .code = 0, .next_mps = 2, .next_lps = 1 },
    .{ .code = 0, .next_mps = 3, .next_lps = 1 },
    .{ .code = 0, .next_mps = 4, .next_lps = 2 },
    .{ .code = 0, .next_mps = 5, .next_lps = 3 },
    .{ .code = 1, .next_mps = 6, .next_lps = 4 },
    .{ .code = 1, .next_mps = 7, .next_lps = 5 },
    .{ .code = 1, .next_mps = 8, .next_lps = 6 },
    .{ .code = 1, .next_mps = 9, .next_lps = 7 },
    .{ .code = 2, .next_mps = 10, .next_lps = 8 },
    .{ .code = 2, .next_mps = 11, .next_lps = 9 },
    .{ .code = 2, .next_mps = 12, .next_lps = 10 },
    .{ .code = 2, .next_mps = 13, .next_lps = 11 },
    .{ .code = 3, .next_mps = 14, .next_lps = 12 },
    .{ .code = 3, .next_mps = 15, .next_lps = 13 },
    .{ .code = 3, .next_mps = 16, .next_lps = 14 },
    .{ .code = 3, .next_mps = 17, .next_lps = 15 },
    .{ .code = 4, .next_mps = 18, .next_lps = 16 },
    .{ .code = 4, .next_mps = 19, .next_lps = 17 },
    .{ .code = 5, .next_mps = 20, .next_lps = 18 },
    .{ .code = 5, .next_mps = 21, .next_lps = 19 },
    .{ .code = 6, .next_mps = 22, .next_lps = 20 },
    .{ .code = 6, .next_mps = 23, .next_lps = 21 },
    .{ .code = 7, .next_mps = 24, .next_lps = 22 },
    .{ .code = 7, .next_mps = 24, .next_lps = 23 },
    .{ .code = 0, .next_mps = 26, .next_lps = 1 },
    .{ .code = 1, .next_mps = 27, .next_lps = 2 },
    .{ .code = 2, .next_mps = 28, .next_lps = 4 },
    .{ .code = 3, .next_mps = 29, .next_lps = 8 },
    .{ .code = 4, .next_mps = 30, .next_lps = 12 },
    .{ .code = 5, .next_mps = 31, .next_lps = 16 },
    .{ .code = 6, .next_mps = 32, .next_lps = 18 },
    .{ .code = 7, .next_mps = 24, .next_lps = 22 },
};

/// Only states 0 and 1 flip the context's most-probable symbol on an LPS.
inline fn mpsFlips(status: u8) bool {
    return status & 0xFE == 0;
}

// --- the chip -------------------------------------------------------------

/// One 1 MiB slice of the $C0-$FF window.
const slice_size = 0x10_0000;

pub const Sdd1 = struct {
    /// The ROM is re-supplied by the cartridge on load; the decoder is
    /// transient state that only lives inside one DMA transfer.
    pub const serialize_skip = .{ "rom", "rom_mask" };

    rom: []const u8,
    rom_mask: u32,

    /// $4800: which DMA channels may take data from the decompressor.
    dma_enable: u8,
    /// $4801: which channels are armed for the *next* transfer. Consumed
    /// (per channel) when that transfer runs.
    xfer_enable: u8,
    /// $4802/$4803: writable, no documented effect; kept so reads return
    /// what was written (Star Ocean's reset code writes $4802).
    unknown: [2]u8,
    /// $4804-$4807: the 1 MiB ROM slice mapped into each quarter of
    /// $C0-$FF. Power-on order is the identity, which is what a cart relies
    /// on before it configures anything — Star Ocean jumps to $C0:8001
    /// (ROM offset $008001) straight out of reset.
    bank: [4]u8,

    dec: Decoder,

    pub const init: Sdd1 = .{
        .rom = &.{},
        .rom_mask = 0,
        .dma_enable = 0,
        .xfer_enable = 0,
        .unknown = @splat(0),
        .bank = .{ 0, 1, 2, 3 },
        .dec = .init,
    };

    pub fn attach(self: *Sdd1, rom: []const u8, rom_mask: u32) void {
        self.rom = rom;
        self.rom_mask = rom_mask;
    }

    // --- MMIO ($4800-$4807) ----------------------------------------------

    pub fn mmioRead(self: *const Sdd1, addr: u16, mdr: u8) u8 {
        return switch (addr) {
            0x4800 => self.dma_enable,
            0x4801 => self.xfer_enable,
            0x4802, 0x4803 => self.unknown[addr - 0x4802],
            0x4804...0x4807 => self.bank[addr - 0x4804],
            else => mdr,
        };
    }

    /// Returns true when the write changed the ROM window, so the caller
    /// rebuilds the affected page-table entries.
    pub fn mmioWrite(self: *Sdd1, addr: u16, value: u8) bool {
        switch (addr) {
            0x4800 => self.dma_enable = value,
            0x4801 => self.xfer_enable = value,
            0x4802, 0x4803 => self.unknown[addr - 0x4802] = value,
            0x4804...0x4807 => {
                const i = addr - 0x4804;
                const slice = value & 0x07;
                if (self.bank[i] == slice) return false;
                self.bank[i] = slice;
                return true;
            },
            else => {},
        }
        return false;
    }

    /// ROM offset behind a $C0-$FF address: the bank's quarter selects a
    /// 1 MiB slice and the low 20 bits index into it.
    pub fn windowOffset(self: *const Sdd1, addr: u24) u32 {
        const quarter: u2 = @truncate(addr >> 20);
        return (@as(u32, self.bank[quarter]) * slice_size) | (addr & (slice_size - 1));
    }

    // --- decompressing DMA ------------------------------------------------

    /// Is this channel's next transfer a compressed one?
    pub fn channelArmed(self: *const Sdd1, channel: usize) bool {
        const bit = @as(u8, 1) << @intCast(channel);
        return self.dma_enable & self.xfer_enable & bit != 0;
    }

    /// Begin a compressed transfer for `channel`, reading from `addr` (a
    /// CPU address, mapped through the window). The arm bit is one-shot.
    pub fn beginTransfer(self: *Sdd1, channel: usize, addr: u24) void {
        self.xfer_enable &= ~(@as(u8, 1) << @intCast(channel));
        const offset: u32 = if (addr >= 0xC0_0000)
            self.windowOffset(addr)
        else
            // A LoROM-window source is unusual but well defined.
            ((addr & 0x7F_0000) >> 1) | (addr & 0x7FFF);
        self.dec.start(self.romByte(offset), offset);
    }

    /// The next decompressed byte of the transfer in flight.
    pub fn nextByte(self: *Sdd1) u8 {
        return self.dec.nextByte(self.rom, self.rom_mask);
    }

    inline fn romByte(self: *const Sdd1, offset: u32) u8 {
        if (self.rom.len == 0) return 0;
        return self.rom[offset & self.rom_mask];
    }
};

// --- the decompressor ------------------------------------------------------

const Decoder = struct {
    // Input manager: a bit pointer into the compressed stream. `bit_count`
    // is how much of the byte at `offset` has been consumed; it starts at 4
    // because the stream begins in the low nibble of the header byte.
    offset: u32,
    bit_count: u8,

    // Bit generators, one per Golomb order: the MPS symbols still owed by
    // the current run, and whether that run ends in an LPS.
    mps_count: [8]u8,
    lps_ind: [8]bool,

    // Probability estimator: 32 contexts, each a state index plus its
    // most-probable symbol.
    ctx_state: [32]u8,
    ctx_mps: [32]u8,

    // Context model: the header's two mode fields, the running window of
    // previously emitted bits per bitplane, and the bit counter that paces
    // the bitplane rotation.
    bitplane_mode: u8,
    context_mode: u8,
    prev_bits: [8]u16,
    cur_plane: u8,
    bit_number: u32,

    // Output logic: modes other than mode 7 emit two bytes at a time.
    pending: u8,
    has_pending: bool,

    const init: Decoder = .{
        .offset = 0,
        .bit_count = 4,
        .mps_count = @splat(0),
        .lps_ind = @splat(false),
        .ctx_state = @splat(0),
        .ctx_mps = @splat(0),
        .bitplane_mode = 0,
        .context_mode = 0,
        .prev_bits = @splat(0),
        .cur_plane = 0,
        .bit_number = 0,
        .pending = 0,
        .has_pending = false,
    };

    /// Reset for a new stream. `header` is the first compressed byte: its
    /// top two bits pick the bitplane layout and the next two the context
    /// template; the entropy-coded bits start immediately below them.
    fn start(self: *Decoder, header: u8, offset: u32) void {
        self.* = .init;
        self.offset = offset;
        self.bitplane_mode = header & 0xC0;
        self.context_mode = header & 0x30;
        self.cur_plane = switch (self.bitplane_mode) {
            0x00 => 1, // 2bpp: planes 0,1
            0x40 => 7, // 8bpp: plane pairs 0-1, 2-3, 4-5, 6-7
            0x80 => 3, // 4bpp: plane pairs 0-1, 2-3
            else => 0, // mode 7: one bit from each of 8 planes per byte
        };
    }

    /// Read the next Golomb codeword: one flag bit, plus `code_len` run bits
    /// when the flag says the run ended early.
    fn codeword(self: *Decoder, rom: []const u8, mask: u32, code_len: u3) u8 {
        const b0: u16 = rom[self.offset & mask];
        var tmp: u8 = @truncate((b0 << @intCast(self.bit_count)) & 0xFF);
        self.bit_count += 1;
        if (tmp & 0x80 != 0) {
            const b1: u16 = rom[(self.offset +% 1) & mask];
            tmp |= @truncate(b1 >> @intCast(9 - self.bit_count));
            tmp &= @truncate((@as(u16, 0xFF) << @intCast(7 - @as(u8, code_len))) & 0xFF);
            self.bit_count += code_len;
        }
        if (self.bit_count & 8 != 0) {
            self.offset +%= 1;
            self.bit_count &= 7;
        }
        return tmp;
    }

    /// One symbol from the order-`code` bit generator: 0 for the most
    /// probable symbol, 1 for the least. `end_of_run` marks the symbol that
    /// exhausts the current run, which is when the estimator evolves.
    fn generatorBit(self: *Decoder, rom: []const u8, mask: u32, code: u3) struct { bit: u1, end_of_run: bool } {
        if (self.mps_count[code] == 0 and !self.lps_ind[code]) {
            const cw = self.codeword(rom, mask, code);
            if (cw & 0x80 != 0) {
                self.lps_ind[code] = true;
                self.mps_count[code] = run_lengths[code][(cw & 0x7F) >> @intCast(7 - @as(u8, code))];
            } else {
                self.lps_ind[code] = false;
                self.mps_count[code] = @as(u8, 1) << code;
            }
        }
        var bit: u1 = 0;
        if (self.mps_count[code] != 0) {
            self.mps_count[code] -= 1;
        } else {
            bit = 1;
            self.lps_ind[code] = false;
        }
        return .{
            .bit = bit,
            .end_of_run = self.mps_count[code] == 0 and !self.lps_ind[code],
        };
    }

    /// One decoded bit from `context`, evolving that context's estimate when
    /// the run it belongs to ends.
    fn estimatorBit(self: *Decoder, rom: []const u8, mask: u32, context: u5) u1 {
        const status = self.ctx_state[context];
        const st = evolution[status];
        const mps = self.ctx_mps[context];
        const r = self.generatorBit(rom, mask, st.code);
        if (r.end_of_run) {
            if (r.bit != 0) {
                if (mpsFlips(status)) self.ctx_mps[context] = mps ^ 1;
                self.ctx_state[context] = st.next_lps;
            } else {
                self.ctx_state[context] = st.next_mps;
            }
        }
        return r.bit ^ @as(u1, @truncate(mps));
    }

    /// One output bit: rotate to the bitplane this position belongs to, form
    /// its context from that plane's neighbouring bits, decode, and remember
    /// the bit for later contexts.
    fn modelBit(self: *Decoder, rom: []const u8, mask: u32) u1 {
        switch (self.bitplane_mode) {
            0x00 => self.cur_plane ^= 1,
            0x40 => {
                self.cur_plane ^= 1;
                if (self.bit_number & 0x7F == 0) self.cur_plane = (self.cur_plane + 2) & 7;
            },
            0x80 => {
                self.cur_plane ^= 1;
                if (self.bit_number & 0x7F == 0) self.cur_plane ^= 2;
            },
            else => self.cur_plane = @truncate(self.bit_number & 7),
        }

        // The window holds this plane's previously emitted bits, most recent
        // in bit 0. The template picks the neighbours of the pixel about to
        // be emitted: the one to its left (1st back), the one above it (8th
        // back on an 8-pixel row) and the two diagonals (7th and 9th).
        const w = self.prev_bits[self.cur_plane];
        const neighbours: u8 = switch (self.context_mode) {
            0x00 => @truncate(((w & 0x01C0) >> 5) | (w & 0x0001)), // 1st,7th,8th,9th
            0x10 => @truncate(((w & 0x0180) >> 5) | (w & 0x0001)), // 1st,8th,9th
            0x20 => @truncate(((w & 0x00C0) >> 5) | (w & 0x0001)), // 1st,7th,8th
            else => @truncate(((w & 0x0180) >> 5) | (w & 0x0003)), // 1st,2nd,8th,9th
        };
        const context: u5 = @truncate(((self.cur_plane & 1) << 4) | neighbours);

        const bit = self.estimatorBit(rom, mask, context);
        self.prev_bits[self.cur_plane] = (w << 1) | bit;
        self.bit_number +%= 1;
        return bit;
    }

    /// The next decompressed byte. Tile modes decode a bitplane pair at a
    /// time (the SNES stores those two bytes adjacently), so every other
    /// call is served from `pending`; mode 7 takes one bit from each of the
    /// eight planes and needs no buffering.
    fn nextByte(self: *Decoder, rom: []const u8, mask: u32) u8 {
        if (self.has_pending) {
            self.has_pending = false;
            return self.pending;
        }
        if (self.bitplane_mode == 0xC0) {
            var b: u8 = 0;
            for (0..8) |_| b = (b << 1) | self.modelBit(rom, mask);
            return b;
        }
        var plane0: u8 = 0;
        var plane1: u8 = 0;
        for (0..8) |_| {
            plane0 = (plane0 << 1) | self.modelBit(rom, mask);
            plane1 = (plane1 << 1) | self.modelBit(rom, mask);
        }
        self.pending = plane1;
        self.has_pending = true;
        return plane0;
    }
};

// --- tests ----------------------------------------------------------------

test "Golomb run lengths match the documented order-4 decode table" {
    // The published G4 table: `1 0000` is fifteen MPS then an LPS, stepping
    // down to `1 1111` for an immediate LPS. The field arrives MSB-first, so
    // index it the way the decoder does.
    const expect = [16]u8{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 };
    for (expect, 0..) |want, i| {
        // Codeword bits after the flag, MSB-first, are the reverse of i's
        // low four bits (the documented table lists them stream-order).
        var field: usize = 0;
        for (0..4) |b| {
            if (i & (@as(usize, 1) << @intCast(b)) != 0) field |= @as(usize, 1) << @intCast(3 - b);
        }
        try std.testing.expectEqual(want, run_lengths[4][field]);
    }
    // Order 0 has no run field at all: the flag alone means an immediate LPS.
    try std.testing.expectEqual(@as(u8, 0), run_lengths[0][0]);
}

test "bank registers window $C0-$FF in 1 MiB slices" {
    var chip: Sdd1 = .init;
    // Power-on identity mapping: $C0-$FF is the first 4 MiB, linear.
    try std.testing.expectEqual(@as(u32, 0x00_0000), chip.windowOffset(0xC0_0000));
    try std.testing.expectEqual(@as(u32, 0x00_8001), chip.windowOffset(0xC0_8001));
    try std.testing.expectEqual(@as(u32, 0x10_0000), chip.windowOffset(0xD0_0000));
    try std.testing.expectEqual(@as(u32, 0x2F_FFFF), chip.windowOffset(0xEF_FFFF));
    try std.testing.expectEqual(@as(u32, 0x30_1234), chip.windowOffset(0xF0_1234));

    // Point the third quarter at slice 5: only $E0-$EF moves.
    try std.testing.expect(chip.mmioWrite(0x4806, 5));
    try std.testing.expectEqual(@as(u32, 0x50_0000), chip.windowOffset(0xE0_0000));
    try std.testing.expectEqual(@as(u32, 0x00_8001), chip.windowOffset(0xC0_8001));
    // Only the low three bits select a slice, and a no-op write is not a
    // remap (the caller rebuilds pages on a true).
    try std.testing.expect(!chip.mmioWrite(0x4806, 0xFD));
    try std.testing.expectEqual(@as(u8, 5), chip.mmioRead(0x4806, 0));
    // The non-banking registers read back what was written.
    try std.testing.expect(!chip.mmioWrite(0x4800, 0x81));
    try std.testing.expect(!chip.mmioWrite(0x4802, 0x77));
    try std.testing.expectEqual(@as(u8, 0x81), chip.mmioRead(0x4800, 0));
    try std.testing.expectEqual(@as(u8, 0x77), chip.mmioRead(0x4802, 0));
}

test "an all-zero stream decodes to zeros (the pure most-probable-symbol path)" {
    // Every codeword is a bare 0 flag, which the documented coder reads as a
    // full run of 2^k most-probable symbols with no terminating LPS. Every
    // context powers on with MPS = 0, so the output is zeros however the
    // estimator evolves — an expectation that comes from the algorithm, not
    // from this implementation.
    const rom = [_]u8{0} ** 256;
    var chip: Sdd1 = .init;
    chip.attach(&rom, rom.len - 1);
    chip.beginTransfer(0, 0xC0_0000);
    for (0..64) |_| try std.testing.expectEqual(@as(u8, 0), chip.nextByte());
}

test "a leading 1 bit decodes as an immediate least-probable symbol" {
    // The other branch: a set flag with an order-0 run field is a run of zero
    // MPS ending in an LPS, so the very first output bit is the complement of
    // the context's MPS (which powers on at 0) — a 1. The $FF header selects
    // the mode-7 layout, where each output byte takes one bit from each of
    // the eight planes, MSB first, so that 1 lands in bit 7.
    const rom = [_]u8{0xFF} ** 256;
    var chip: Sdd1 = .init;
    chip.attach(&rom, rom.len - 1);
    chip.beginTransfer(0, 0xC0_0000);
    try std.testing.expect(chip.nextByte() & 0x80 != 0);
}

test "a channel decompresses only when both enable and arm are set, once" {
    var chip: Sdd1 = .init;
    _ = chip.mmioWrite(0x4800, 0b0000_0010); // channel 1 may decompress
    try std.testing.expect(!chip.channelArmed(1)); // ...but is not armed
    _ = chip.mmioWrite(0x4801, 0b0000_0011); // arm channels 0 and 1
    try std.testing.expect(chip.channelArmed(1));
    try std.testing.expect(!chip.channelArmed(0)); // never enabled

    const rom = [_]u8{0} ** 64;
    chip.attach(&rom, rom.len - 1);
    chip.beginTransfer(1, 0xC0_0000);
    // The arm is one-shot: the next transfer on the channel is a plain one.
    try std.testing.expect(!chip.channelArmed(1));
    try std.testing.expectEqual(@as(u8, 0b0000_0001), chip.xfer_enable);
}
