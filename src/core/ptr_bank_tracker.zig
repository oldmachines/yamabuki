//! Pointer-bank provenance tracking for the SA-1 conversion generator:
//! which ROM byte fed each bank value the game pushes, pulls and stores,
//! so a bank byte naming WRAM can be proven and re-banked. Runs once per
//! profiled step under `ProfilingConsole`; zero-sized everywhere else.
//! See `usage_map.PtrBankEvidence` for what the evidence means.
//!
//! Moved out of console.zig as pure code motion: the scratch fields and
//! `track` (formerly `Console.trackPtrBanks`) are exactly what was there.

const std = @import("std");
const usage_map = @import("usage_map.zig");
const Bus = @import("memory/bus.zig").Bus;
const Regs = @import("cpu/wdc65816.zig").Regs;

fn dataAddr(v: u32) ?u24 {
    return if (v == Bus.no_data_access) null else @intCast(v);
}

pub const PtrBankTracker = struct {
    /// Pointer-bank provenance scratch (see `usage_map.PtrBankEvidence`):
    /// the ROM address of the previous step's plain A-load source (its
    /// read's last byte, or its immediate's last operand byte) and that
    /// load's width — what a store on THIS step is presumed to be
    /// storing. Zero-sized unless `cfg.profile`.
    prev_load_end: u32 = usage_map.PtrBankEvidence.none,
    prev_load_w: u8 = 0,
    /// ROM source of the CURRENT X register value (last byte of the
    /// load that set it), or `none` once anything else touched X.
    x_src: u32 = usage_map.PtrBankEvidence.none,
    x_w: u8 = 0,
    /// Per-DMA-channel pending A-bus ADDRESS source: the ROM address
    /// of the 16-bit word most recently staged into $43x2 whose VALUE
    /// named the moved low 8 KiB (< $2000), waiting for the channel's
    /// bank write to say which bus it reads. A system bank ($00-$3F —
    /// the WRAM mirror the window moved) promotes it; $7E/$7F drops
    /// it (the bank-byte family re-banks those to $40, where the
    /// image's own layout already answers); anything else drops it.
    dma_a1t_src: [8]u32 = @splat(usage_map.PtrBankEvidence.none),
    /// Second push slot: PEI pushes a dp WORD (high byte below the
    /// low), so the second PLB of a `PEI ($dp)/PLB/PLB` pin pulls the
    /// HIGH byte — the bank, staged in memory, never in A.
    pushed_hi_src: u32 = usage_map.PtrBankEvidence.none,
    /// Byte-sources of A's two halves after a 16-bit WRAM load. They
    /// survive exactly one XBA — which swaps them — so the sound
    /// dispatch's `LDA table,Y / XBA / PHA / PLB / PLB` hands the
    /// second PLB the TABLE byte's address and the mirror-bank value
    /// proves like any other (measured: the handler bank $A6 rode
    /// this shape into PBR, fetched MB2 code, and BRK'd into the
    /// crash trap).
    a_lo_src: u32 = usage_map.PtrBankEvidence.none,
    a_hi_src: u32 = usage_map.PtrBankEvidence.none,
    /// The last PLB's own pc — where a misfit-bank pin would be
    /// patched with a translate-in thunk.
    plb_pc: u32 = usage_map.PtrBankEvidence.none,
    /// PEI/PLB/PLB pair tracking that does not depend on attribution:
    /// 1 after PEI, 2 after its first PLB, 0 otherwise. The first
    /// pull's DBR is the pushed word's LOW byte — never a pin.
    pei_stage: u8 = 0,
    pei_dp: u8 = 0,
    /// When the previous step was a 16-bit A-load out of TRACKED WRAM:
    /// the staged source (`PtrBankEvidence.src`) of the load's HIGH
    /// byte, else `none`. A DMA queue drain stores that word straight
    /// into $43x3, where the high byte is the A-bus bank — the one
    /// byte whose provenance matters and the one the byte-wide chains
    /// cannot see.
    prev_load_hi_src: u32 = usage_map.PtrBankEvidence.none,
    /// ROM source of the byte most recently PUSHED by PHA, when that
    /// push immediately followed a one-byte A-load, else `none`. The
    /// window is deliberately one instruction wide: anything else
    /// touching the stack in between makes the pairing a guess, and a
    /// wrong bank-byte rewrite corrupts silently.
    pushed_src: u32 = usage_map.PtrBankEvidence.none,
    /// ROM source of the byte PLB last pulled into DBR. A data access
    /// that lands in $7E/$7F under this DBR proves that byte is a bank
    /// byte naming WRAM — the `LDA #$7E / PHA / PLB` idiom, which the
    /// pointer-cell tracking cannot see because the bank never passes
    /// through a pointer in memory.
    dbr_src: u32 = usage_map.PtrBankEvidence.none,

    pub const init: PtrBankTracker = .{};

    /// Pointer-bank provenance (see `usage_map.PtrBankEvidence`): runs
    /// once per profiled step, after the usage map has recorded the
    /// step's accesses.
    pub fn track(self: *PtrBankTracker, bus: *const Bus, regs: *const Regs, pb: *usage_map.PtrBankEvidence, pc: u24, op_o: ?u8, m8: bool, x8: bool, width: u8, conv: bool) void {
        const none = usage_map.PtrBankEvidence.none;
        const op = op_o orelse {
            // Interrupt dispatch between the load and the store would
            // clobber A anyway only via the handler's own tracked
            // steps; the dispatch itself proves nothing — drop the
            // pending source.
            self.prev_load_end = none;
            self.prev_load_w = 0;
            return;
        };
        // 1. Every write refreshes the touched low-8K cells' source
        //    attribution: a $7E/$7F byte just stored there is presumed
        //    to be the previous step's load, byte for byte, when the
        //    widths agree; anything else clears the cell.
        if (dataAddr(bus.last_data_write)) |a| {
            var i: u8 = 0;
            while (i < width) : (i += 1) {
                const ad = a -% i;
                if (usage_map.wramAnyOffset(ad, conv)) |off| {
                    // Through the bus, not `wram.data`: on a cover replay
                    // this byte lives in BW-RAM, and reading the abandoned
                    // WRAM would attribute provenance from a dead copy.
                    const val = bus.peek8(ad) orelse continue;
                    const attributed = self.prev_load_end != none and self.prev_load_w == width;
                    pb.src[off] = if ((val == 0x7E or val == 0x7F) and attributed)
                        self.prev_load_end -% i
                    else
                        none;
                    // A 16-bit WRAM-to-WRAM copy has no prev_load_end —
                    // the load staged only per-half sources — so the
                    // copy propagates those instead of dropping the
                    // chain (measured: the room-header parser copies
                    // the tileset pointer $C2:C104 through $07C6-$C8
                    // into dp $47-$49 with exactly this shape, and the
                    // decompressor's PLB found nothing to prove — the
                    // palette source stayed a folded $C2 and the
                    // new-game room faded in black).
                    // Contiguous pairs only: a genuine copied WORD has
                    // hi == lo + 1 by construction; propagating loose
                    // halves let the word families (dma-addr, (dp)
                    // pointers) assemble false pairs and shift a ROM
                    // pointer word that was never a moved-WRAM address
                    // (measured: +18 bytes of collateral rewrites and a
                    // striped room).
                    const pair_ok = width == 2 and
                        self.a_lo_src != none and
                        self.a_hi_src == self.a_lo_src +% 1;
                    const half_src = if (pair_ok)
                        (if (i == 0) self.a_hi_src else self.a_lo_src)
                    else
                        none;
                    pb.src_any[off] = if (attributed)
                        self.prev_load_end -% i
                    else if (half_src != none)
                        half_src
                    else
                        none;
                }
            }
            // DMA A-bus bank registers ($43x4): a $7E/$7F written there
            // is a bank VALUE naming WRAM for the hardware — same
            // provenance, proven directly.
            const a16: u16 = @truncate(a);
            // Third family: the A-bus ADDRESS. A 16-bit word staged
            // into $43x2 that names the moved low 8 KiB (< $2000)
            // becomes the channel's pending source; the bank write
            // below arbitrates it.
            if (((a >> 16) & 0x7F) <= 0x3F and a16 >= 0x4303 and a16 <= 0x4373 and
                (a16 & 0xF) == 3)
            {
                const ch: u3 = @truncate(a16 >> 4);
                self.dma_a1t_src[ch] = blk: {
                    if (width != 2) break :blk none;
                    if (self.prev_load_end == none or self.prev_load_w != 2) break :blk none;
                    // The register itself is MMIO — off peek8's page
                    // table. The store's value is byte-for-byte the
                    // load's, and the load's source IS peekable.
                    const lo = bus.peek8(@intCast(self.prev_load_end -% 1)) orelse break :blk none;
                    const hi = bus.peek8(@intCast(self.prev_load_end)) orelse break :blk none;
                    const val = (@as(u16, hi) << 8) | lo;
                    break :blk if (val < 0x2000) self.prev_load_end else none;
                };
            }
            // 16-bit store to $43x4: the BANK rides the LOW byte and
            // DAS-lo the high — Super Metroid's inline-param DMA
            // launcher (`JSL $80:91A9` + an 8-byte param block in the
            // caller's own bank; `LDA $0006,Y / STA $4304,X`). The
            // write's HIGH byte lands on $43x5, so this window keys on
            // &0xF == 5; the bank's source is the load's LOW byte.
            if (((a >> 16) & 0x7F) <= 0x3F and a16 >= 0x4305 and a16 <= 0x4375 and
                (a16 & 0xF) == 5 and width == 2 and
                self.prev_load_end != none and self.prev_load_w == 2)
            {
                const ch5: u3 = @truncate(a16 >> 4);
                const lo_src: u32 = self.prev_load_end -% 1;
                if (bus.peek8(@intCast(lo_src))) |lv| {
                    if (lv == 0x7E or lv == 0x7F) {
                        pb.addProven(lo_src);
                        self.dma_a1t_src[ch5] = none;
                    } else if (lv >= 0xC0 and lv <= 0xDF) {
                        pb.addHiProven(lo_src);
                        self.dma_a1t_src[ch5] = none;
                    } else if (lv >= 0xA0 and lv <= 0xBF) {
                        pb.addA0Proven(lo_src);
                        self.dma_a1t_src[ch5] = none;
                    } else if (lv <= 0x3F) {
                        const pending = self.dma_a1t_src[ch5];
                        self.dma_a1t_src[ch5] = none;
                        if (pending != none) pb.addDmaAddrProven(pending);
                    }
                }
            }
            if (((a >> 16) & 0x7F) <= 0x3F and a16 >= 0x4304 and a16 <= 0x4374 and
                (a16 & 0xF) == 4 and width == 2 and
                (bus.mdr == 0x7E or bus.mdr == 0x7F))
            {
                // 16-bit store to $43x3: A1T-hi rides the low byte and
                // the BANK rides the high — Super Metroid's DMA queue
                // drain (`LDA $0345,X / STA $4313`, 16 KiB of boot
                // tiles from $7F:5000). The high byte is mdr; its
                // source is the load's high byte — an immediate/ROM
                // read directly, a staged WRAM word through the queue
                // cell it was built into.
                const ch2: u3 = @truncate(a16 >> 4);
                self.dma_a1t_src[ch2] = none;
                if (self.prev_load_end != none and self.prev_load_w == 2)
                    pb.addProven(self.prev_load_end)
                else if (self.prev_load_hi_src != none)
                    pb.addProven(self.prev_load_hi_src)
                else
                    pb.noteUnresolved(pc, a16);
            }
            if (((a >> 16) & 0x7F) <= 0x3F and a16 >= 0x4304 and a16 <= 0x4374 and
                (a16 & 0xF) == 4 and width == 2 and
                bus.mdr >= 0xA0 and bus.mdr <= 0xDF)
            {
                // The MISFIT arm of the same 16-bit $43x3 idiom: the
                // staged bank is mirror-intent ($A0-$BF reads MB2 under
                // the shim, $C0-$DF homes $20 lower). Measured: the
                // escape's door-tile upload `$B0:C400 -> vdest $7000`
                // stages its word via `STA $4313` ($80:8CAA); the $B0
                // was never proven, the transfer read the MB2 home
                // (file $284400) instead of MB1 ($184400), and the
                // door's second OBJ tile table rendered as confetti.
                // Proved ONLY when the source byte IS the stored value
                // (the dual-role lesson: a byte that is addr-half for
                // another consumer must stay stock).
                const ch2b: u3 = @truncate(a16 >> 4);
                self.dma_a1t_src[ch2b] = none;
                // Candidate source of the bank (high) byte just stored:
                // a direct ROM load proves itself; a load from a WRAM
                // QUEUE CELL (the DMA job queue) proves through the
                // cell's src_any copy-chain, which the 16-bit staging
                // path leaves in a_hi_src — the strict chain in
                // prev_load_hi_src is the fallback.
                const rsrc: u32 = if (self.prev_load_end != none and self.prev_load_w == 2)
                    self.prev_load_end
                else if (self.a_hi_src != none)
                    self.a_hi_src
                else if (self.prev_load_hi_src != none)
                    self.prev_load_hi_src
                else
                    none;
                if (rsrc != none and (rsrc & 0xFFFF) >= 0x8000 and
                    bus.peek8(@intCast(rsrc)) == bus.mdr)
                {
                    if (bus.mdr >= 0xC0) pb.addHiProven(rsrc) else pb.addA0Proven(rsrc);
                } else pb.noteUnresolved(pc, a16);
            }
            if (((a >> 16) & 0x7F) <= 0x3F and a16 >= 0x4304 and a16 <= 0x4374 and
                (a16 & 0xF) == 4 and width == 1)
            {
                const ch: u3 = @truncate(a16 >> 4);
                const pending = self.dma_a1t_src[ch];
                self.dma_a1t_src[ch] = none;
                if (bus.mdr <= 0x3F and pending != none) pb.addDmaAddrProven(pending);
                if ((bus.mdr >= 0xA0 and bus.mdr <= 0xDF) and
                    self.prev_load_end != none and self.prev_load_w == 1 and
                    bus.peek8(@intCast(self.prev_load_end)) == bus.mdr)
                {
                    // The misfit-mirror banks prove on the store too —
                    // but only when the source byte IS the stored value.
                    if (bus.mdr >= 0xC0) {
                        pb.addHiProven(self.prev_load_end);
                    } else pb.addA0Proven(self.prev_load_end);
                }
                if (bus.mdr == 0x7E or bus.mdr == 0x7F) {
                    // The bank can ride A or X: Super Metroid's palette
                    // uploader is `LDX #$7E / STX $4314` (measured:
                    // 8,372 events from that one site, and the wrong
                    // colours from the first visible frame).
                    const via_x = op == 0x86 or op == 0x8E; // STX dp/abs
                    if (via_x and self.x_src != none and self.x_w == 1)
                        pb.addProven(self.x_src)
                    else if (!via_x and self.prev_load_end != none and self.prev_load_w == 1)
                        pb.addProven(self.prev_load_end)
                    else
                        pb.noteUnresolved(pc, a16);
                }
            }
        }
        // 2b. A dp,X data access resolving BEYOND the moved low 8 KiB
        //    (X carried a full pointer — MMIO registers, or anything
        //    else the D move would drag +$6000 away from): prove X's
        //    ROM source word so the conversion can pre-subtract the
        //    window offset from it.
        if (usage_map.isDpX(op)) {
            const tgt = dataAddr(bus.last_data_write) orelse dataAddr(bus.last_data_read);
            if (tgt) |t| {
                const tb: u8 = @truncate(t >> 16);
                const a16: u16 = @truncate(t);
                if (tb == 0x00 and a16 >= 0x2000) {
                    if (self.x_src != none and self.x_w == 2)
                        pb.addIdxProven(self.x_src)
                    else
                        pb.idx_unresolved += 1;
                }
            }
        }
        // 2. A [dp]/[dp],Y data access that resolved into bank $7E/$7F:
        //    prove the pointer's bank-byte cell's remembered source.
        if (op & 0x0F == 0x07) {
            const tgt = dataAddr(bus.last_data_write) orelse dataAddr(bus.last_data_read);
            if (tgt) |t| {
                const tb: u8 = @truncate(t >> 16);
                if (tb >= 0xC0 and tb <= 0xDF) {
                    const operand = bus.peek8(pc +% 1) orelse 0;
                    const slot = regs.d +% operand +% 2;
                    if (slot < 0x2000 and pb.src_any[slot] != none and
                        bus.peek8(@intCast(pb.src_any[slot])) == tb)
                    {
                        pb.addHiProven(pb.src_any[slot]);
                    }
                }
                if (usage_map.isWramBank(tb, conv)) {
                    const operand = bus.peek8(pc +% 1) orelse 0;
                    const slot = regs.d +% operand +% 2;
                    const src: u32 = if (slot < 0x2000) pb.src[slot] else none;
                    if (src != none) pb.addProven(src) else pb.noteUnresolved(pc, slot);
                }
            }
        }
        // 2e. A (dp)/(dp),Y access whose TARGET is the moved low 8 KiB
        //    through a data-bank mirror: the two-byte pointer carries
        //    no bank, so there is no bank byte to re-bank — the
        //    pointer WORD itself must move +$6000. Prove the word's
        //    staged source when both bytes attribute contiguously
        //    (measured: the NMI OAM high-table walker, `STA ($1C)`
        //    under DB=$8C — four bytes of sprite size bits landing in
        //    the abandoned home while the DMA reads the window).
        if (op & 0x1F == 0x12 or op & 0x1F == 0x11) {
            const tgt = dataAddr(bus.last_data_write) orelse dataAddr(bus.last_data_read);
            if (tgt) |t| {
                const tb: u8 = @truncate(t >> 16);
                const ta: u16 = @truncate(t);
                if ((tb & 0x7F) <= 0x3F and ta < 0x2000) {
                    const operand = bus.peek8(pc +% 1) orelse 0;
                    const slot = regs.d +% operand;
                    if (slot < 0x1FFF) {
                        const lo = pb.src_any[slot];
                        const hi = pb.src_any[slot + 1];
                        if (lo != none and hi == lo +% 1)
                            pb.addDmaAddrProven(hi)
                        else
                            pb.noteUnresolved(pc, slot);
                    }
                }
            }
        }
        // 2c. DBR carrying $7E/$7F, put there by `LDA #$7E / PHA / PLB`.
        //    The bank never passes through a pointer in memory, so the
        //    cell tracking above cannot see it; what proves the byte is
        //    a data access under this DBR resolving into $7E/$7F. Long
        //    addressing names its own bank and [dp] forms are case 2, so
        //    both are excluded — otherwise an unrelated access would
        //    credit whatever DBR happened to hold.
        if (self.dbr_src != none and op & 0x0F != 0x07 and usage_map.mode(op) != .long and usage_map.mode(op) != .long_x) {
            const tgt = dataAddr(bus.last_data_write) orelse dataAddr(bus.last_data_read);
            if (tgt) |t| {
                const tb: u8 = @truncate(t >> 16);
                if (tb == regs.dbr and tb >= 0xA0 and tb <= 0xDF and
                    self.plb_pc != none)
                {
                    const ppc = self.plb_pc;
                    const dp_op = bus.peek8(@intCast(ppc -% 2)) orelse 0xFF;
                    const shp = ((bus.peek8(@intCast(ppc -% 1)) orelse 0) == 0x48 and
                        (bus.peek8(@intCast(ppc -% 3)) orelse 0) == 0xA5) or
                        ((bus.peek8(@intCast(ppc -% 1)) orelse 0) == 0xAB and
                            (bus.peek8(@intCast(ppc -% 3)) orelse 0) == 0xD4);
                    // The `LDA $abs,X / PHA / PLB / PLB` HIGH-byte pin: a
                    // 16-bit table word whose LOW byte is an ADDRESS HALF
                    // and whose high byte is the bank. Value-proving the
                    // chain here credits whichever half the staging ended
                    // on — measured: Super Metroid's door tilesheet
                    // record at $20:E276, whose addr-hi $BA was re-banked
                    // -$80 as if it were a bank, so the Ceres escape's
                    // sprite-tile builder read $B0:3Axx (zeros) and the
                    // beam/door sprites rendered blank. A dual-role table
                    // word can never be value-rewritten; the pin site
                    // gets a translate-in thunk instead.
                    const shp_absx = (bus.peek8(@intCast(ppc -% 1)) orelse 0) == 0xAB and
                        (bus.peek8(@intCast(ppc -% 2)) orelse 0) == 0x48 and
                        (bus.peek8(@intCast(ppc -% 5)) orelse 0) == 0xBD and
                        (std.mem.readInt(u16, &[2]u8{
                            bus.peek8(@intCast(ppc -% 4)) orelse 0xFF,
                            bus.peek8(@intCast(ppc -% 3)) orelse 0xFF,
                        }, .little)) < 0x2000;
                    if ((shp and dp_op < 0x10) or shp_absx) {
                        pb.addXlSite(ppc);
                    } else if (self.dbr_src != none and
                        bus.peek8(@intCast(self.dbr_src)) == tb)
                    {
                        if (tb >= 0xC0) {
                            pb.addHiProven(self.dbr_src);
                        } else pb.addA0Proven(self.dbr_src);
                    }
                }
                if (usage_map.isWramBank(tb, conv) and tb == regs.dbr) {
                    pb.addProven(self.dbr_src);
                    // Proven once is enough; keep it for the rest of the
                    // routine so every access under the same DBR does not
                    // re-add the same byte.
                }
            }
        }
        // 2d. The push/pull chain that feeds the above. PHA right after a
        //    one-byte A-load carries that load's source; PLB moves it into
        //    DBR. Anything else touching the stack or DBR clears the
        //    chain rather than guessing across it.
        sw: switch (op) {
            0x48 => { // PHA
                if (self.prev_load_w == 1) {
                    self.pushed_src = self.prev_load_end;
                    self.pushed_hi_src = none;
                } else if (self.a_lo_src != none or self.a_hi_src != none) {
                    // 16-bit push: PLB pulls the LOW half first.
                    self.pushed_src = self.a_lo_src;
                    self.pushed_hi_src = self.a_hi_src;
                } else {
                    self.pushed_src = none;
                    self.pushed_hi_src = none;
                }
            },
            0xD4 => { // PEI ($dp): pushes the dp WORD, low byte on top
                const operand = bus.peek8(pc +% 1) orelse 0;
                self.pei_stage = 1;
                self.pei_dp = operand;
                const slot = regs.d +% operand;
                if (slot < 0x1FFF) {
                    self.pushed_src = pb.src_any[slot];
                    self.pushed_hi_src = pb.src_any[slot + 1];
                } else {
                    self.pushed_src = none;
                    self.pushed_hi_src = none;
                }
            },
            0xAB => { // PLB — a second PLB pulls PEI's high byte
                const transient = self.pei_stage == 1;
                self.plb_pc = pc;
                self.dbr_src = if (transient) none else self.pushed_src;
                self.pushed_src = self.pushed_hi_src;
                self.pushed_hi_src = none;
                if (transient) {
                    self.pei_stage = 2;
                    break :sw;
                }
                const pei_pin = self.pei_stage == 2;
                self.pei_stage = 0;
                // A $C0-$DF pull proves EAGERLY: pinning DBR to the
                // Super MMC misfit banks has no purpose but reading
                // them, and waiting for a confirming access loses the
                // source to interrupt traffic (measured: SM's round-2
                // music upload pins $D0, spins the handshake for ~1M
                // clks, and the NMIs' RTIs wiped dbr_src before the
                // first non-long access).
                if (regs.dbr >= 0xA0 and regs.dbr <= 0xDF and !transient) {
                    // Tight-dp pins (the music walker) translate: their
                    // table bytes are dual-role. Wider-dp pins (the
                    // decompressor's 3-byte param blocks, single-role)
                    // value-prove instead — their fire rate makes a
                    // thunk cost ~a frame across a load.
                    const shape_lda = (bus.peek8(pc -% 1) orelse 0) == 0x48 and
                        (bus.peek8(pc -% 3) orelse 0) == 0xA5;
                    const dp_op: u8 = if (pei_pin)
                        self.pei_dp
                    else
                        bus.peek8(pc -% 2) orelse 0xFF;
                    // The `LDA $abs,X / PHA / PLB / PLB` HIGH-byte pin
                    // over a low-WRAM table: the 16-bit word is
                    // dual-role (low = an address half, high = the
                    // bank), so NEITHER half may value-prove — the
                    // eager prove here is what re-banked SM's door
                    // tilesheet addr-hi $BA at $20:E276 to $3A and
                    // blanked the Ceres escape's beam/door sprites. The
                    // SECOND pull records a translate site; the FIRST
                    // (the transient low byte in DBR) records nothing.
                    const absx_hi = (bus.peek8(pc -% 1) orelse 0) == 0xAB and
                        (bus.peek8(pc -% 2) orelse 0) == 0x48 and
                        (bus.peek8(pc -% 5) orelse 0) == 0xBD and
                        (@as(u16, bus.peek8(pc -% 3) orelse 0xFF) << 8 |
                            (bus.peek8(pc -% 4) orelse 0xFF)) < 0x2000;
                    const absx_lo = (bus.peek8(pc -% 1) orelse 0) == 0x48 and
                        (bus.peek8(pc -% 4) orelse 0) == 0xBD and
                        (@as(u16, bus.peek8(pc -% 2) orelse 0xFF) << 8 |
                            (bus.peek8(pc -% 3) orelse 0xFF)) < 0x2000;
                    if (absx_lo) {
                        // transient low pull — the next PLB decides
                    } else if ((shape_lda or pei_pin) and dp_op < 0x10 or absx_hi) {
                        pb.addXlSite(pc);
                    } else if (self.dbr_src != none and
                        bus.peek8(@intCast(self.dbr_src)) == regs.dbr)
                    {
                        if (regs.dbr >= 0xC0) {
                            pb.addHiProven(self.dbr_src);
                        } else pb.addA0Proven(self.dbr_src);
                    }
                }
            },
            // Other stack traffic and the bank-setting instructions make
            // the two-slot model a guess: drop it.
            0x08, 0x0B, 0x4B, 0x5A, 0x8B, 0xDA, 0x28, 0x2B, 0x68, 0x7A, 0xFA, 0x20, 0x22, 0xFC, 0x60, 0x6B, 0x40, 0x62, 0xF4 => {
                self.pushed_src = none;
                self.pushed_hi_src = none;
                self.pei_stage = 0;
                if (op == 0x40) self.dbr_src = none; // RTI restores a bank we did not track
            },
            else => {},
        }
        // 3. Remember THIS step if it was a plain A-load from ROM (or
        //    an immediate — its operand bytes are ROM): the candidate
        //    source for the next step's store.
        self.prev_load_end = none;
        self.prev_load_w = 0;
        self.prev_load_hi_src = none;
        if (op == 0xEB) { // XBA: A's halves swap, sources ride along
            const t = self.a_lo_src;
            self.a_lo_src = self.a_hi_src;
            self.a_hi_src = t;
        } else {
            self.a_lo_src = none;
            self.a_hi_src = none;
        }
        if (usage_map.loadASource(op)) {
            const w: u8 = if (m8) 1 else 2;
            if (op == 0xA9) {
                self.prev_load_end = (pc +% w) & 0x7F_FFFF;
                self.prev_load_w = w;
            } else if (dataAddr(bus.last_data_read)) |r| {
                if (usage_map.siteClassHomes(r, conv) == usage_map.site_rom) {
                    self.prev_load_end = r & 0x7F_FFFF;
                    self.prev_load_w = w;
                } else if (w == 1) {
                    // A byte read back out of WRAM carries whatever ROM
                    // byte put it there. Without this the chain breaks at
                    // every value that reaches hardware through a RAM
                    // staging area, and a DMA job queue is exactly that:
                    // the bank byte is copied from a ROM record into the
                    // queue, and only the queue is read when the channel
                    // is armed.
                    if (usage_map.wramAnyOffset(r, conv)) |off| {
                        const staged = pb.src_any[off];
                        if (staged != usage_map.PtrBankEvidence.none) {
                            self.prev_load_end = staged;
                            self.prev_load_w = 1;
                        }
                    }
                } else if (usage_map.wramAnyOffset(r, conv)) |off| {
                    // The 16-bit flavour of the same: remember only the
                    // HIGH byte's staged source — the half a $43x3
                    // queue drain turns into an A-bus bank.
                    self.prev_load_hi_src = pb.src[off];
                    // `r` is the END of the read: hi half. Both halves
                    // stage for the XBA/PHA/PLB chain.
                    if (off >= 1) self.a_lo_src = pb.src_any[off - 1];
                    self.a_hi_src = pb.src_any[off];
                }
            }
        }
        // 4. X-register provenance: a plain X-load from ROM (or its
        //    immediate) sets it; anything else that writes X kills it.
        if (usage_map.loadXSource(op)) {
            self.x_src = none;
            self.x_w = 0;
            const w: u8 = if (x8) 1 else 2;
            if (op == 0xA2) {
                self.x_src = (pc +% w) & 0x7F_FFFF;
                self.x_w = w;
            } else if (dataAddr(bus.last_data_read)) |r| {
                if (usage_map.siteClass(r) == usage_map.site_rom) {
                    self.x_src = r & 0x7F_FFFF;
                    self.x_w = w;
                }
            }
        } else if (usage_map.clobbersX(op)) {
            self.x_src = none;
            self.x_w = 0;
        }
    }
};
