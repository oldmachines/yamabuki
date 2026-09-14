//! ROM space and thunk bodies: the padding allocators (`PadAlloc`, `FarPad`), thunk placement, and every thunk body the rewrite emits (cold dispatcher, split, long, DASB, A1B, indexed).
//!
//! Carved out of sa1gen.zig as pure code motion; every declaration here is
//! re-exported from sa1gen.zig, which stays the module's public root.

const std = @import("std");
const usage_map = @import("../../usage_map.zig");
const sa1gen = @import("../sa1gen.zig");
const testing = std.testing;

const Error = sa1gen.Error;
const Refusal = sa1gen.Refusal;
const Result = sa1gen.Result;
const nmi_prologue_len = sa1gen.nmi_prologue_len;
const offload_max = sa1gen.offload_max;
const refuse = sa1gen.refuse;
const wg_bw_window = sa1gen.wg_bw_window;
const win_abort_len = sa1gen.win_abort_len;
const win_block_len = sa1gen.win_block_len;
const win_nmi_thunk_len = sa1gen.win_nmi_thunk_len;
/// Bank-0 reservation for the window dispatcher: prologue + message loop
/// + JMP + sig + unm + mar + abort + blocks + NMI prologue + mirror thunks.
/// The split flavor's carve budget: tok + mini-tok + sloop + the mul
/// helper + up to 26 stub/trampoline pairs. Bank $00's whole padding
/// run must cover shim + this.
pub const split_disp_max: u32 = 1520;
pub const win_disp_max: u32 = 51 + 12 + 3 + 19 + 29 + 24 + offload_max * win_block_len + win_abort_len + nmi_prologue_len + 8 * win_nmi_thunk_len;

/// Context-split thunk: the DBR dispatch plus both flavors of the
/// original 3-byte op (see the emission comment in convertWholeGame).
pub const split_thunk_len: u32 = 24;
/// Index-split thunk: the DBR test, the X-width test, the magnitude
/// compare, and both flavors of the original 3-byte op — A-PRESERVING, so
/// every op class (stores included) can be thunked, not just LDA shapes.
pub const idx_thunk_len: u32 = 35;
/// The same thunk WITHOUT the data-bank test, for a site whose measured
/// evidence already rules a BW-RAM pin out. The test costs ~17 cycles on
/// every call and these sites are hot — Gradius III's five measured
/// split sites are its level-script walker, and paying for a question
/// their evidence has already answered moved the whole timeline far
/// enough to flip the behavioural verdict on a build that shipped.
pub const idx_thunk_short_len: u32 = 27;
/// Sites one conversion can thunk (Gradius III measures ~100).
pub const split_thunk_max: usize = 192;
/// Index-split sites one conversion can thunk. Far larger than the DBR
/// flavor: with `--wg-static` every tiny-base indexed absolute in code the
/// profile never reached is thunked on principle, because no evidence
/// exists to prove which home it walks.
pub const idx_thunk_max: usize = 2048;

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
pub const PadAlloc = struct {
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
    pub const margin = 8;

    /// Rewind the scan. Safe because everything already handed out has
    /// been WRITTEN by then, so a fresh pass reads it as occupied — which
    /// is what lets a caller that failed to fit a 35-byte body come back
    /// and ask for a 5-byte stub instead.
    pub fn rewind(self: *@This()) void {
        self.scan = 0;
        self.cur = 0;
        self.end = 0;
    }

    /// Padding still on offer, net of the per-run margin. Used to decide
    /// bodies-or-stubs BEFORE placing anything: a bank that cannot hold
    /// every body should hold no body at all, because a half-filled bank
    /// leaves the tail thunks without even their 5-byte stub.
    pub fn freeBytes(self: *const @This()) u32 {
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
    pub fn stubCapacity(self: *const @This()) u32 {
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

    pub fn next(self: *@This(), need: u32) ?u32 {
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
pub fn padAllocFor(out: []const u8, header_off: u32, bank: u32, res_at: u32, res_len: u32) PadAlloc {
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
pub const FarPad = struct {
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

    /// Padding in ONE named bank, for a stub that must share its site's
    /// bank (a bank-local JMP/JSR/RTS shape). A fresh scan each call:
    /// everything handed out before has been written, so it reads as
    /// occupied — callers must write exactly what they asked for. Bank
    /// $00 keeps the carve reserved.
    pub fn nextIn(self: *@This(), bank: u32, need: u32, res_at: u32, res_len: u32) ?u32 {
        var pa = padAllocFor(self.out, self.header_off, bank, res_at, res_len);
        return pa.next(need);
    }

    pub fn next(self: *@This(), need: u32) ?u32 {
        if (self.bank == 0) {
            // >2 MiB: file banks $40+ live at CPU $A0-$BF through the
            // Super MMC — a far body placed there and addressed by its
            // FILE bank fetches the wrong megabyte (measured: a context
            // thunk at $10:B6C8 called $5F:D777, marched the DXB fade
            // tables, and BRK'd into the crash trap). The far pool stays
            // in the identity banks.
            self.bank = @intCast(@min((self.out.len + 0x7FFF) / 0x8000, 0x40) - 1);
        }
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
pub const BigRun = struct { bank: u32 = 0, end: u32 = 0, len: u32 = 0 };
pub fn biggestRun(out: []const u8, header_off: u32) BigRun {
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
pub const far_stub_len: u32 = 5;

/// Place one thunk body for a site and return the address its `JSR` should
/// name. Prefers the site's own bank; falls back to the stub-plus-far-body
/// shape. `near` and `far_body` are the same template with RTS/RTL tails.
pub fn placeThunk(out: []u8, local: *PadAlloc, far: *FarPad, near: []const u8, far_body: []const u8, force_far: bool, n_far: *u16) ?u16 {
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
pub const cold_disp_len: u32 = 106;
pub fn coldDispatcherBody(table: u24, n_records: u16) [cold_disp_len]u8 {
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
pub fn splitThunkBody(op: u8, v: u16, ret: u8) [split_thunk_len]u8 {
    const sh: u16 = v + wg_bw_window;
    return .{
        0x08, 0xE2, 0x20, 0x48, 0x8B, 0x68, // PHP/SEP#$20/PHA/PHB/PLA
        0x30, 0x0A, 0x89, 0x40,          0xF0,               0x06, // BMI sys / BIT #$40 / BEQ sys
        0x68, 0x28, op,   @truncate(v),  @truncate(v >> 8),  ret,
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
pub const long_thunk_len: u32 = 29;
pub fn longThunkBody(op: u8, v: u16, bank: u8) [long_thunk_len]u8 {
    const sh: u16 = v + wg_bw_window;
    const lim: u16 = 0x2000 - v;
    return .{
        0x08, 0xE2, 0x20, 0x48, // PHP / SEP #$20 / PHA
        0xA3, 0x02, 0x89, 0x10, 0xD0, 0x05, // LDA $02,S / BIT #$10 / BNE low
        0xE0, @truncate(lim), @truncate(lim >> 8), 0xB0, 0x07, // CPX #lim / BCS rom
        0x68, 0x28, op, @truncate(sh), @truncate(sh >> 8), bank, 0x6B, // low
        0x68, 0x28, op, @truncate(v), @truncate(v >> 8), bank, 0x6B, // rom
    };
}

/// The tiny-base `long,X` thunk WITH the forward-wrap arm. The ceiling
/// body's guard asks only `X < $2000 - v` — but a huge X wraps the
/// 24-bit sum into the NEXT bank's low page, the same mirror the
/// negative-base body was built for (measured: the door-transition
/// loader called `LDA $A0:003E,X` with X=$FFCF — effective $A1:000D,
/// WRAM $0D — and the ceiling guard sent it down the ROM arm, so the
/// room state loaded stale and the screen faded to black for good).
/// No third read arm: `long,X` carries into bank+1 in hardware, so the
/// shifted operand serves both low windows — the guard just routes
/// X >= $10000 - v to it. Emitted only when bank+1 carries a window
/// ((bank & $7F) < $3F); a $3F/$BF/$7D base keeps the ceiling body.
///
///   PHP / SEP #$20 / PHA / LDA $02,S / BIT #$10 / BNE low
///   CPX #($2000-v)  / BCC low   ; small index: this bank's mirror
///   CPX #($10000-v) / BCC rom   ; big but unwrapped: ROM
///   low: PLA / PLP / op b:v+$6000,X / RTL   ; wrap carries to b+1
///   rom: PLA / PLP / op b:v,X       / RTL
pub const long_wrap_thunk_len: u32 = 34;
pub fn longThunkBodyWrap(op: u8, v: u16, bank: u8) [long_wrap_thunk_len]u8 {
    const sh: u16 = v + wg_bw_window;
    const lim: u16 = 0x2000 - v;
    const wl: u16 = @intCast(0x10000 - @as(u32, v));
    return .{
        0x08, 0xE2, 0x20, 0x48, // PHP / SEP #$20 / PHA
        0xA3, 0x02, 0x89, 0x10, 0xD0, 0x0A, // LDA $02,S / BIT #$10 / BNE low
        0xE0, @truncate(lim), @truncate(lim >> 8), 0x90, 0x05, // CPX #lim / BCC low
        0xE0, @truncate(wl), @truncate(wl >> 8), 0x90, 0x07, // CPX #wl / BCC rom
        0x68, 0x28, op, @truncate(sh), @truncate(sh >> 8), bank, 0x6B, // low
        0x68, 0x28, op, @truncate(v), @truncate(v >> 8), bank, 0x6B, // rom
    };
}

/// The HDMA indirect-bank ($43x7 DASB) rebank thunk. An indirect HDMA whose
/// per-scanline source is WRAM names that WRAM bank in DASB, and the value
/// is loaded from the channel's HDMA object (a ROM table) — not an
/// immediate or a long operand — so no static rebanker can reach it. The
/// register write itself is wrapped: on the way to `STA $43x7`, an 8-bit A
/// holding $7E/$7F becomes $40/$41, so DASB follows its data into BW-RAM;
/// any other bank passes through untouched, which makes the thunk sound on
/// every DASB write, whatever the value's origin. `store` is the site's own
/// three operand bytes (STA abs / abs,X / abs,Y — same 3-byte footprint the
/// JSR replaces), replayed here with the remapped value; the caller's exact
/// A and flags are restored, so a store that sat inside a CMP/branch pair or
/// left A live behaves byte-for-byte as in situ. `ret` is RTS in-bank, RTL
/// behind a far stub. SEP #$20 forces the byte width the register demands
/// regardless of the caller's M (the PHA/PLA then move exactly one byte).
pub const dasb_thunk_len: u32 = 21;
pub fn dasbThunkBody(store: [3]u8, ret: u8) [dasb_thunk_len]u8 {
    return .{
        0x08, // PHP
        0xE2, 0x20, // SEP #$20 — DASB is a byte register
        0x48, // PHA — save the caller's value
        0xC9, 0x7E, // CMP #$7E
        0x90, 0x07, // BCC store — A < $7E, no WRAM bank
        0xC9, 0x80, // CMP #$80
        0xB0, 0x03, // BCS store — A >= $80, not $7E/$7F
        0x38, 0xE9, 0x3E, // SEC / SBC #$3E — $7E->$40, $7F->$41
        store[0], store[1], store[2], // STA $43x7[,X/Y] (remapped or as-is)
        0x68, // PLA — restore the caller's value
        0x28, // PLP
        ret,
    };
}

/// The A-bus bank (A1B, $43x4) runtime rebank thunk body: the FULL misfit
/// map, because a staged DMA source bank can carry any mirror-intent value —
/// $7E/$7F (WRAM -> BW-RAM, -$3E), $A0-$BF (mirror-of-MB1 intent that the
/// shim parks at MB2, -$80), $C0-$DF (MB2 content homed $20 lower, -$20).
/// Measured: Super Metroid's escape arms `$B0:C400 -> vdest $7000` through a
/// staged bank byte the provenance never proved; the transfer read the MB2
/// home (file $284400) instead of MB1 ($184400) and the door's second OBJ
/// tile table arrived as confetti. Banks $00-$3F and $80-$9F pass through
/// (region 2 restores that mirror). Same calling convention as the DASB
/// body: the JSR replaces the 3-byte store; A and P are preserved.
pub const a1b_thunk_len: u32 = 37;
pub fn a1bThunkBody(store: [3]u8, ret: u8) [a1b_thunk_len]u8 {
    // Branch offsets audited by simulation; store at body index 31.
    return .{
        0x08, // PHP
        0xE2, 0x20, // SEP #$20
        0x48, // PHA
        0xC9, 0x7E, // CMP #$7E
        0x90, 0x17, // BCC store — plain banks $00-$7D
        0xC9, 0x80, // CMP #$80
        0xB0, 0x05, // BCS mirror-region checks
        0x38, 0xE9, 0x3E, // SEC / SBC #$3E — $7E/$7F -> $40/$41
        0x80, 0x0E, // BRA store
        0xC9, 0xA0, // CMP #$A0
        0x90, 0x0A, // BCC store — $80-$9F: genuine mirror
        0xC9, 0xC0, // CMP #$C0
        0xB0, 0x04, // BCS hi
        0xE9, 0x7F, // SBC #$7F (carry clear) — $A0-$BF -> -$80
        0x80, 0x02, // BRA store
        0xE9, 0x20, // hi: SBC #$20 (carry set) — $C0-$DF -> -$20
        store[0], store[1], store[2], // STA $43x4[,X/Y]
        0x68, // PLA
        0x28, // PLP
        ret,
    };
}

/// Wrap every covered `STA $43x7` (a channel's DASB — the indirect HDMA
/// source bank) in a runtime rebank thunk. When an indirect HDMA's source
/// is WRAM, the game names the WRAM bank in DASB, and that bank is a byte
/// loaded from the channel's HDMA object (a ROM table) — not an immediate
/// or a long operand, so no static rebanker can reach it. Super Metroid's
/// Ceres alarm is the witness: its color-math COLDATA HDMA reads a
/// per-scanline gradient the game builds into live BW-RAM ($40), but its
/// object still names bank $7E, so the hardware fetches the abandoned copy
/// and the escape room renders as stripes while its logic runs correctly.
/// The remap ($7E/$7F->$40/$41) is a no-op for a ROM or already-BW-RAM
/// bank, so wrapping is sound on every DASB write whatever the value's
/// origin — any DASB that named $7E/$7F on stock must name $40/$41 here.
///
/// A separate function from convertWholeGame on purpose: its own working
/// set (the per-bank PadAlloc) stays out of that already-deep frame.
pub fn rebankDasbWrites(
    out: []u8,
    cov: []const u8,
    header_off: u32,
    carve: u32,
    carve_len: u32,
    far: *FarPad,
    refusal: *?Refusal,
    res: *Result,
) Error!void {
    var dasb_pad: PadAlloc = undefined;
    var dasb_pad_bank: u32 = 0xFFFF;
    var dbank: u32 = 0;
    while (dbank < 0x40) : (dbank += 1) {
        const bank_file = dbank * 0x8000;
        if (bank_file >= out.len) break;
        var a16: u32 = 0x8000;
        while (a16 < 0x10000) : (a16 += 1) {
            const cpu_addr = (dbank << 16) | a16;
            const fl_lo = cov[cpu_addr];
            const fl_hi = cov[0x80_0000 | cpu_addr];
            if ((fl_lo | fl_hi) & usage_map.flag_opcode == 0) continue;
            const file = bank_file + (a16 - 0x8000);
            if (file + 3 > out.len) continue;
            const op = out[file];
            // STA abs / abs,X / abs,Y whose target is a $43x7 register:
            // column 7 is DASB. abs,X/abs,Y index by channel*$10, so the
            // base already names column 7; abs names the channel outright.
            switch (op) {
                0x8D, 0x9D, 0x99 => {},
                else => continue,
            }
            const tgt = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
            if (tgt < 0x4300 or tgt > 0x437F) continue;
            const col = tgt & 0xF;
            // Column 7 (DASB) always; column 4 (A1B) on >2 MiB images, where
            // an unmapped mirror-intent bank sources the wrong megabyte.
            if (col != 7 and !(col == 4 and out.len > 0x20_0000)) continue;
            // The register is a byte, and the thunk compares an 8-bit A; a
            // 16-bit store here would be writing DASB+A2A-low as a word, not
            // a plain bank set — leave that shape untouched.
            const fl = if (fl_lo & usage_map.flag_opcode != 0) fl_lo else fl_hi;
            if (fl & usage_map.flag_m == 0) continue;
            if (dbank != dasb_pad_bank) {
                dasb_pad = padAllocFor(out, header_off, dbank, carve, carve_len);
                dasb_pad_bank = dbank;
            }
            const store: [3]u8 = out[file..][0..3].*;
            const taddr = (if (col == 7)
                placeThunk(out, &dasb_pad, far, &dasbThunkBody(store, 0x60), &dasbThunkBody(store, 0x6B), false, &res.stats.split_far)
            else
                placeThunk(out, &dasb_pad, far, &a1bThunkBody(store, 0x60), &a1bThunkBody(store, 0x6B), false, &res.stats.split_far)) orelse
                return refuse(refusal, .{ .reason = .no_free_space, .detail = a1b_thunk_len });
            out[file] = 0x20; // JSR — same 3-byte footprint as the store
            std.mem.writeInt(u16, out[file + 1 ..][0..2], taddr, .little);
            res.stats.rewritten_dasb += 1;
        }
    }
}

/// The ORIGINAL index-split thunk, kept verbatim for exactly the sites it
/// already served: an LDA shape whose measured evidence is low|rom. Those
/// five sites in Gradius III are the level-script walker, they are hot,
/// and they are on a path that SHIPS — so they get the body that shipped,
/// to the cycle. A is scratch here, which is why only LDA qualifies: the
/// load overwrites it, and an 8-bit scratch leaves the B accumulator
/// alone. Generalising this template — even to something strictly more
/// correct — changed the timeline enough to fail a build that passed.
pub const idx_thunk_v2_len: u32 = 24;
pub fn idxThunkBodyV2(op: u8, v: u16, ret: u8) [idx_thunk_v2_len]u8 {
    const sh: u16 = v + wg_bw_window;
    const lim: u16 = 0x2000 - v;
    const cp: u8 = if (usage_map.mode(op) == .abs_y) 0xC0 else 0xE0;
    return .{
        0x08, 0xE2, 0x20, 0xA3, 0x01, 0x89, 0x10, 0xD0, 0x05, // PHP/SEP/LDA $01,S/BIT #$10/BNE low
        cp, @truncate(lim), @truncate(lim >> 8), 0xB0, 0x05, // CPY #lim / BCS rom
        0x28, op, @truncate(sh), @truncate(sh >> 8), ret, // low: PLP / op v+$6000
        0x28, op, @truncate(v), @truncate(v >> 8), ret, // rom: PLP / op v
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
pub const long_neg_thunk_len: u32 = 25;
pub fn longNegThunkBody(op: u8, v: u16, bank: u8) [long_neg_thunk_len]u8 {
    const lo: u16 = @intCast(0x10000 - @as(u32, v)); // wrap threshold
    const hi: u16 = lo +% 0x2000;
    // EA' = EA + $6000: the +$6000 always carries out of a base >= $FF00,
    // so the bank advances and the operand keeps the same distance.
    const sh: u16 = v +% wg_bw_window;
    const sb: u8 = bank +% 1;
    return .{
        0x08, 0xC2, 0x10, // PHP / REP #$10
        0xE0, @truncate(lo), @truncate(lo >> 8), 0x90, 0x0B, // CPX #lo / BCC rom
        0xE0, @truncate(hi), @truncate(hi >> 8), 0xB0, 0x06, // CPX #hi / BCS rom
        0x28, op, @truncate(sh), @truncate(sh >> 8), sb, 0x6B, // low: the window
        0x28, op, @truncate(v), @truncate(v >> 8), bank, 0x6B, // rom: as written
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
pub fn idxThunkBodyShort(op: u8, v: u16, ret: u8) [idx_thunk_short_len]u8 {
    const sh: u16 = v + wg_bw_window;
    const lim: u16 = 0x2000 - v;
    const cp: u8 = if (usage_map.mode(op) == .abs_y) 0xC0 else 0xE0;
    return .{
        0x08, 0xE2, 0x20, 0x48, // PHP / SEP #$20 / PHA
        0xA3, 0x02, 0x89, 0x10, 0xD0, 0x05, // LDA $02,S / BIT #$10 / BNE low
        cp, @truncate(lim), @truncate(lim >> 8), 0xB0, 0x06, // CPY #lim / BCS rom
        0x68, 0x28, op, @truncate(sh), @truncate(sh >> 8), ret, // low: the window
        0x68, 0x28, op, @truncate(v), @truncate(v >> 8), ret, // rom: as written
    };
}

/// The WRAPPING index thunk: a real table base ($100 <= v <= $1F00)
/// whose measured index runs from a valid slot to garbage. Super Metroid's
/// enemy-projectile spawn and enemy-death paths read `Enemy.palette,X` /
/// `Enemy.AI,X` with X the caller left behind (the disassembly says so of
/// both), so one site reads the enemy table and, a frame later, ROM or the
/// low mirror of the NEXT bank — `$0F96 + $F345` carries into `$87:02DB`.
/// A single operand cannot follow: shifted, the ROM case reads $6000 off;
/// as written, the in-table case reads the abandoned home (open bus on the
/// SA-1 — the site stayed on the stale list of every take that spawned
/// one). The thunk asks where BASE+INDEX lands, in 16 bits: below $2000
/// is the window, and so is a wrap past $10000-v, where the shifted
/// operand's own carry puts the read in the next bank's window. Between
/// them the operand runs as written. A is scratch only for the P check;
/// the caller's A comes back before the op (ORA sites need it).
///
///   PHP / SEP #$20 / PHA / LDA $02,S / BIT #$10 / BNE low  ; x8: base+idx < base+$100
///   CPY #($2000-v) / BCC low
///   CPY #($10000-v) / BCS low
///   rom: PLA / PLP / op v / ret
///   low: PLA / PLP / op v+$6000 / ret
pub const idx_thunk_wrap_len: u32 = 32;
pub fn idxThunkBodyWrap(op: u8, v: u16, ret: u8) [idx_thunk_wrap_len]u8 {
    const sh: u16 = v + wg_bw_window;
    const lim: u16 = 0x2000 - v;
    const wrap: u16 = @intCast(0x10000 - @as(u32, v));
    const cp: u8 = if (usage_map.mode(op) == .abs_y) 0xC0 else 0xE0;
    return .{
        0x08, 0xE2, 0x20, 0x48, // PHP / SEP #$20 / PHA
        0xA3, 0x02, 0x89, 0x10, 0xD0, 0x10, // LDA $02,S / BIT #$10 / BNE low
        cp, @truncate(lim), @truncate(lim >> 8), 0x90, 0x0B, // CPY #lim / BCC low
        cp, @truncate(wrap), @truncate(wrap >> 8), 0xB0, 0x06, // CPY #wrap / BCS low
        0x68, 0x28, op, @truncate(v), @truncate(v >> 8), ret, // rom: as written
        0x68, 0x28, op, @truncate(sh), @truncate(sh >> 8), ret, // low: the window
    };
}

test "idxThunkBodyWrap: branch targets land on the window arm, thresholds are base-relative" {
    const b = idxThunkBodyWrap(0xBD, 0x0F96, 0x60);
    // every branch reaches offset 26 (the window arm's PLA)
    try testing.expectEqual(@as(usize, 26), 10 + @as(usize, b[9]));
    try testing.expectEqual(@as(usize, 26), 15 + @as(usize, b[14]));
    try testing.expectEqual(@as(usize, 26), 20 + @as(usize, b[19]));
    try testing.expectEqual(@as(u8, 0x68), b[26]);
    try testing.expectEqual(@as(u8, 0xE0), b[10]); // CPX for abs,X
    try testing.expectEqual(@as(u16, 0x2000 - 0x0F96), @as(u16, b[11]) | @as(u16, b[12]) << 8);
    try testing.expectEqual(@as(u16, 0x10000 - 0x0F96), @as(u16, b[16]) | @as(u16, b[17]) << 8);
    try testing.expectEqual(@as(u16, 0x0F96), @as(u16, b[23]) | @as(u16, b[24]) << 8);
    try testing.expectEqual(@as(u16, 0x6F96), @as(u16, b[29]) | @as(u16, b[30]) << 8);
    const y = idxThunkBodyWrap(0xB9, 0x0F8A, 0x6B);
    try testing.expectEqual(@as(u8, 0xC0), y[10]); // CPY for abs,Y
    try testing.expectEqual(@as(u8, 0x6B), y[31]);
}

/// The index-dispatch thunk body (see the emission comment in
/// convertWholeGame). `ret` is RTS in-bank, RTL behind a far stub.
pub fn idxThunkBody(op: u8, v: u16, ret: u8) [idx_thunk_len]u8 {
    const sh: u16 = v + wg_bw_window;
    const lim: u16 = 0x2000 - v;
    const cp: u8 = if (usage_map.mode(op) == .abs_y) 0xC0 else 0xE0;
    return .{
        0x08, 0xE2, 0x20, 0x48, 0x8B, 0x68, // PHP/SEP#$20/PHA/PHB/PLA
        0x30, 0x04, 0x89, 0x40, 0xD0, 0x11, // BMI sys / BIT #$40 / BNE rom
        0xA3, 0x02, 0x89, 0x10, 0xD0, 0x05, // sys: LDA $02,S / BIT #$10 / BNE low
        cp, @truncate(lim), @truncate(lim >> 8), 0xB0, 0x06, // CPY #lim / BCS rom
        0x68, 0x28, op, @truncate(sh), @truncate(sh >> 8), ret, // low: the window
        0x68, 0x28, op, @truncate(v), @truncate(v >> 8), ret, // rom: as written
    };
}

/// Diagnostics: report each bank's thunk demand against its padding.
pub const dbg_thunk_pad = false;
