//! Execution/access coverage in the bsnes-plus debugger's usage-map format —
//! stage S1 of the SA-1 generation arc, and the artefact Vilela's "SA-1
//! Collection" workflow was built from (DiztinGUIsh imports the exported file
//! directly as "BSNES Usage Map").
//!
//! One flag byte per 24-bit bus address, flags matching bsnes-plus
//! (`snes/cpu/debugger`) exactly:
//!
//!   Read $80 | Write $40 | Exec $20 | Opcode $10 | (E $04, declared but
//!   never set there — mirrored) | FlagM $02 | FlagX $01
//!
//! and the same recording semantics: the opcode byte gets Opcode|Exec with
//! the M/X widths at fetch time (cleared then set, so the *latest* widths
//! win — what a disassembler needs to decode the instruction); operand bytes
//! get Exec; data reads OR in Read; data writes OR in Write and clear Exec
//! (a self-modified byte is data until it executes again).
//!
//! Coverage from real play is the whole point: which addresses ran, and as
//! code or data, is undecidable statically (jump tables, self-modifying
//! code) and trivial dynamically. The map doubles as the RAM access map —
//! WRAM addresses carry the same Read/Write flags.
//!
//! Divergences from bsnes-plus, stated rather than hidden: only S-CPU
//! accesses are recorded (no SMP, no coprocessor cores); one data access per
//! instruction with the access width back-marked from its last byte, so an
//! instruction's *pointer* fetch (the dp/abs indirection it dereferenced) is
//! not marked, only its final data target; interrupt vector fetches are not
//! marked. The exported file zero-fills the blocks it does not record, so
//! the byte layout still matches what bsnes-plus writes for the same cart.
//!
//! The instruction-length and data-width tables below are the only
//! hand-derived opcode metadata in the tree (the CPU core itself never
//! tabulates lengths — widths fall out of its comptime dispatch); they are
//! built from the 65816 opcode matrix's column structure plus the known
//! exceptions, and spot-tested against the datasheet.

const std = @import("std");

/// How many distinct bytes the map has marked as instruction starts —
/// the size of "the code the profile actually saw run", and the number a
/// caller compares across two points in a capture to ask whether the
/// profile is still discovering code.
pub fn countOpcodes(bytes: []const u8) u32 {
    var n: u32 = 0;
    for (bytes) |b| n += @intFromBool(b & flag_opcode != 0);
    return n;
}

pub const flag_read: u8 = 0x80;
pub const flag_write: u8 = 0x40;
pub const flag_exec: u8 = 0x20;
pub const flag_opcode: u8 = 0x10;
pub const flag_e: u8 = 0x04; // declared for compatibility; never set
pub const flag_m: u8 = 0x02;
pub const flag_x: u8 = 0x01;

/// The CPU block's size: one byte per 24-bit bus address.
pub const cpu_map_len: usize = 1 << 24;
/// The (zero-filled here) SMP block that follows it in the exported file.
pub const smp_map_len: usize = 1 << 16;

/// Per-SITE effective-address evidence: what memory an instruction's data
/// accesses actually reached, recorded on the INSTRUCTION's address. This
/// is the dynamic answer to the statically undecidable idioms — the same
/// operand bytes mean "walk a ROM table" or "walk low WRAM" depending on
/// runtime register values, and a rewriter that measured them does not
/// have to guess.
pub const site_wram_low: u8 = 0x01; // system-bank access below $2000 (the WRAM mirror)
pub const site_rom: u8 = 0x02; // ROM, through any bank
pub const site_wram_bank: u8 = 0x04; // through bank $7E/$7F (DBR- or long-mediated)
pub const site_other: u8 = 0x08; // MMIO, cart space, open bus

/// Classify one effective 24-bit data address into a site-evidence bit.
pub fn siteClass(addr: u24) u8 {
    const bank: u8 = @truncate(addr >> 16);
    const a16: u16 = @truncate(addr);
    if (bank == 0x7E or bank == 0x7F) return site_wram_bank;
    if ((bank & 0x7F) <= 0x3F) {
        if (a16 < 0x2000) return site_wram_low;
        if (a16 >= 0x8000) return site_rom;
        return site_other;
    }
    return if (bank >= 0xC0 or (bank & 0x7F) >= 0x40) site_rom else site_other;
}

pub const UsageMap = struct {
    /// Caller-allocated, `cpu_map_len` bytes, zeroed before the run. Kept
    /// out of every core struct on purpose — 16 MiB belongs on the heap of
    /// whoever asked for coverage, not inside a Console or Profiler.
    bytes: []u8,
    /// Optional per-site evidence map, same length, indexed by the
    /// INSTRUCTION address (`site_*` bits). Null when nobody asked.
    sites: ?[]u8 = null,

    /// Record where an instruction's data access actually landed.
    pub fn noteSite(self: *const UsageMap, pc: u24, addr: u24) void {
        const s = self.sites orelse return;
        s[pc] |= siteClass(addr);
    }

    /// One executed instruction: opcode byte and its operand bytes.
    pub fn noteInstr(self: *const UsageMap, pc: u24, op: u8, m8: bool, x8: bool) void {
        const b = &self.bytes[pc];
        b.* &= ~(flag_m | flag_x);
        b.* |= flag_opcode | flag_exec |
            (if (m8) flag_m else 0) | (if (x8) flag_x else 0);
        var i: u24 = 1;
        while (i < instrLen(op, m8, x8)) : (i += 1) {
            self.bytes[pc +% i] |= flag_exec;
        }
    }

    /// A data read of `width` bytes ending at `addr` (the last byte the bus
    /// recorded — a 16-bit access marks `addr` and `addr-1`, matching the
    /// core's linear 24-bit increment).
    pub fn noteRead(self: *const UsageMap, addr: u24, width: u8) void {
        var i: u24 = 0;
        while (i < width) : (i += 1) {
            self.bytes[addr -% i] |= flag_read;
        }
    }

    /// A data write, same back-marking; a written byte stops being code.
    pub fn noteWrite(self: *const UsageMap, addr: u24, width: u8) void {
        var i: u24 = 0;
        while (i < width) : (i += 1) {
            const b = &self.bytes[addr -% i];
            b.* |= flag_write;
            b.* &= ~flag_exec;
        }
    }
};

/// Total instruction length in bytes, opcode included.
pub fn instrLen(op: u8, m8: bool, x8: bool) u3 {
    return switch (meta[op].len) {
        .l1 => 1,
        .l2 => 2,
        .l3 => 3,
        .l4 => 4,
        .imm_m => if (m8) 2 else 3,
        .imm_x => if (x8) 2 else 3,
    };
}

/// Bytes of the instruction's (final) data access — how far `noteRead`/
/// `noteWrite` back-mark from the recorded last byte. 0 for instructions
/// whose accesses the bus hooks never record (immediates, pure stack
/// traffic, implied).
pub fn dataWidth(op: u8, m8: bool, x8: bool) u8 {
    return switch (meta[op].width) {
        .none => 0,
        .one => 1,
        .m => if (m8) 1 else 2,
        .x => if (x8) 1 else 2,
        .two => 2,
        .three => 3,
    };
}

/// The operand shape stage S3's rewriter cares about: does this instruction
/// name a static data address, and in what form? Control transfers, stack
/// forms, immediates, and block moves are `.none` — their operands are never
/// a rewritable data address. Indirect-through-dp forms are `.dp`: their
/// operand IS a direct-page address (the pointer's home); where the pointer
/// points is runtime data, which is exactly why indirection is a coverage
/// caveat and not a rewrite.
pub const Mode = enum { none, dp, dp_idx, abs, abs_x, abs_y, long, long_x };

/// The addressing mode of `op`, for the static rewriter.
pub fn mode(op: u8) Mode {
    return meta[op].mode;
}

const LenClass = enum { l1, l2, l3, l4, imm_m, imm_x };
const WidthClass = enum { none, one, m, x, two, three };
const Meta = struct { len: LenClass, width: WidthClass, mode: Mode };

const meta: [256]Meta = blk: {
    var t: [256]Meta = undefined;
    for (0..256) |op| t[op] = classify(op);
    break :blk t;
};

fn classify(op: u8) Meta {
    const col = op & 0x0F;
    // Length, from the opcode matrix's column structure. Column exceptions
    // are the 65816's handful of oddballs.
    const len: LenClass = switch (col) {
        0x0 => switch (op) {
            0x40, 0x60 => .l1, // RTI, RTS
            0x20 => .l3, // JSR abs
            0xA0, 0xC0, 0xE0 => .imm_x, // LDY/CPY/CPX #
            else => .l2, // BRK+sig, branches, BRA
        },
        0x1, 0x3, 0x5, 0x6, 0x7 => .l2, // (dp,X) / sr,S / dp / dp / [dp]
        0x2 => switch (op) {
            0x22 => .l4, // JSL long
            0x62, 0x82 => .l3, // PER, BRL
            0xA2 => .imm_x, // LDX #
            else => .l2, // COP+sig, WDM, REP, SEP, ALU (dp)
        },
        0x4 => switch (op) {
            0x44, 0x54 => .l3, // MVP, MVN
            0xF4 => .l3, // PEA
            else => .l2, // dp ops, PEI
        },
        0x8, 0xA, 0xB => .l1, // implied / accumulator
        0x9 => if (op & 0x10 != 0) .l3 else .imm_m, // abs,Y / ALU #
        0xC => if (op == 0x5C) .l4 else .l3, // JML long / abs
        0xD, 0xE => .l3, // abs / abs,X
        0xF => .l4, // long / long,X
        else => unreachable,
    };

    const width: WidthClass = w: {
        switch (op) {
            0x44, 0x54 => break :w .one, // block moves: one byte per step
            0xD4 => break :w .two, // PEI reads a 16-bit pointer
            0x6C, 0x7C, 0xFC => break :w .two, // JMP (abs)/(abs,X), JSR (abs,X)
            0xDC => break :w .three, // JML [abs]
            // Index register traffic against memory: X width.
            0xA6,
            0xB6,
            0xAE,
            0xBE, // LDX
            0x86,
            0x96,
            0x8E, // STX
            0xA4,
            0xB4,
            0xAC,
            0xBC, // LDY
            0x84,
            0x94,
            0x8C, // STY
            0xC4,
            0xCC, // CPY
            0xE4,
            0xEC, // CPX
            => break :w .x,
            else => {},
        }
        // The ALU group's memory forms (M width): columns 1/3/5/7/D/F are
        // ALU throughout; column 9's odd rows are its abs,Y forms (the even
        // rows are immediates — operand fetches, never data); column 2's
        // odd rows are its (dp) forms.
        const alu = switch (col) {
            0x1, 0x3, 0x5, 0x7, 0xD, 0xF => true,
            0x9, 0x2 => (op & 0x10) != 0,
            else => false,
        };
        if (alu) break :w .m;
        // Memory RMW, BIT, and STZ — also M width.
        break :w switch (op) {
            0x04,
            0x0C,
            0x14,
            0x1C, // TSB, TRB
            0x24,
            0x2C,
            0x34,
            0x3C, // BIT
            0x06,
            0x0E,
            0x16,
            0x1E, // ASL
            0x26,
            0x2E,
            0x36,
            0x3E, // ROL
            0x46,
            0x4E,
            0x56,
            0x5E, // LSR
            0x66,
            0x6E,
            0x76,
            0x7E, // ROR
            0xC6,
            0xCE,
            0xD6,
            0xDE, // DEC
            0xE6,
            0xEE,
            0xF6,
            0xFE, // INC
            0x64,
            0x74,
            0x9C,
            0x9E, // STZ
            => .m,
            else => .none,
        };
    };
    // Operand shape, from the same column structure. `odd` selects the
    // indexed variant rows ($1x/$3x/.../$Fx).
    const odd = (op & 0x10) != 0;
    const m: Mode = switch (col) {
        0x0, 0x8, 0xA, 0xB => .none, // control / implied / stack
        0x1 => .dp, // (dp,X) / (dp),Y — the operand is a dp address
        0x2 => if (odd) .dp else .none, // ALU (dp) / control+imm specials
        0x3 => .none, // stack-relative
        0x4 => switch (op) {
            0x44, 0x54, 0xF4 => .none, // MVP, MVN, PEA
            0xD4 => .dp, // PEI (dp)
            else => if (odd) .dp_idx else .dp,
        },
        0x5, 0x6 => if (odd) .dp_idx else .dp, // dp,X and dp,Y rows included
        0x7 => .dp, // [dp] / [dp],Y
        0x9 => if (odd) .abs_y else .none, // abs,Y / immediate
        0xC => switch (op) {
            0x4C, 0x5C, 0x6C, 0x7C, 0xDC, 0xFC => .none, // jumps
            0x3C, 0xBC => .abs_x, // BIT/LDY abs,X
            else => .abs,
        },
        0xD => if (odd) .abs_x else .abs,
        0xE => if (op == 0xBE) .abs_y else if (odd) .abs_x else .abs,
        0xF => if (odd) .long_x else .long,
        else => unreachable,
    };
    return .{ .len = len, .width = width, .mode = m };
}

test "operand modes: the rewriter's view of the matrix" {
    try testing.expectEqual(Mode.long, mode(0xAF)); // LDA long
    try testing.expectEqual(Mode.long, mode(0x8F)); // STA long
    try testing.expectEqual(Mode.long_x, mode(0xBF)); // LDA long,X
    try testing.expectEqual(Mode.abs, mode(0xAD)); // LDA abs
    try testing.expectEqual(Mode.abs, mode(0x8D)); // STA abs
    try testing.expectEqual(Mode.abs, mode(0xEE)); // INC abs
    try testing.expectEqual(Mode.abs, mode(0x9C)); // STZ abs
    try testing.expectEqual(Mode.abs_x, mode(0x9D)); // STA abs,X
    try testing.expectEqual(Mode.abs_x, mode(0x3C)); // BIT abs,X
    try testing.expectEqual(Mode.abs_y, mode(0xB9)); // LDA abs,Y
    try testing.expectEqual(Mode.abs_y, mode(0xBE)); // LDX abs,Y
    try testing.expectEqual(Mode.dp, mode(0xA5)); // LDA dp
    try testing.expectEqual(Mode.dp, mode(0x64)); // STZ dp
    try testing.expectEqual(Mode.dp, mode(0xB2)); // LDA (dp)
    try testing.expectEqual(Mode.dp, mode(0xA7)); // LDA [dp]
    try testing.expectEqual(Mode.dp, mode(0xD4)); // PEI
    try testing.expectEqual(Mode.dp_idx, mode(0xB5)); // LDA dp,X
    try testing.expectEqual(Mode.dp_idx, mode(0xB6)); // LDX dp,Y
    try testing.expectEqual(Mode.none, mode(0x4C)); // JMP abs: code, not data
    try testing.expectEqual(Mode.none, mode(0x22)); // JSL
    try testing.expectEqual(Mode.none, mode(0xA9)); // LDA #
    try testing.expectEqual(Mode.none, mode(0x48)); // PHA
    try testing.expectEqual(Mode.none, mode(0x03)); // ORA sr,S
    try testing.expectEqual(Mode.none, mode(0x54)); // MVN
}

// --- tests ---------------------------------------------------------------------

const testing = std.testing;

test "instruction lengths: the matrix columns and every oddball" {
    // Immediates split on the width flags.
    try testing.expectEqual(@as(u3, 2), instrLen(0xA9, true, true)); // LDA # (m8)
    try testing.expectEqual(@as(u3, 3), instrLen(0xA9, false, true)); // LDA # (m16)
    try testing.expectEqual(@as(u3, 2), instrLen(0xA2, true, true)); // LDX # (x8)
    try testing.expectEqual(@as(u3, 3), instrLen(0xA2, true, false)); // LDX # (x16)
    try testing.expectEqual(@as(u3, 3), instrLen(0xC0, false, false)); // CPY # (x16)
    // Fixed lengths.
    try testing.expectEqual(@as(u3, 1), instrLen(0xEA, true, true)); // NOP
    try testing.expectEqual(@as(u3, 1), instrLen(0x60, true, true)); // RTS
    try testing.expectEqual(@as(u3, 2), instrLen(0x00, true, true)); // BRK + sig
    try testing.expectEqual(@as(u3, 2), instrLen(0x80, true, true)); // BRA
    try testing.expectEqual(@as(u3, 2), instrLen(0xC2, false, false)); // REP
    try testing.expectEqual(@as(u3, 3), instrLen(0x20, true, true)); // JSR abs
    try testing.expectEqual(@as(u3, 3), instrLen(0x82, true, true)); // BRL
    try testing.expectEqual(@as(u3, 3), instrLen(0x62, true, true)); // PER
    try testing.expectEqual(@as(u3, 3), instrLen(0x44, true, true)); // MVP
    try testing.expectEqual(@as(u3, 3), instrLen(0xF4, true, true)); // PEA
    try testing.expectEqual(@as(u3, 2), instrLen(0xD4, true, true)); // PEI
    try testing.expectEqual(@as(u3, 4), instrLen(0x22, true, true)); // JSL
    try testing.expectEqual(@as(u3, 4), instrLen(0x5C, true, true)); // JML long
    try testing.expectEqual(@as(u3, 4), instrLen(0xAF, true, true)); // LDA long
    try testing.expectEqual(@as(u3, 3), instrLen(0x99, true, true)); // STA abs,Y
    try testing.expectEqual(@as(u3, 2), instrLen(0xE6, true, true)); // INC dp
    try testing.expectEqual(@as(u3, 3), instrLen(0x9C, true, true)); // STZ abs
}

test "data widths: M, X, fixed, and the never-recorded classes" {
    try testing.expectEqual(@as(u8, 1), dataWidth(0xA5, true, true)); // LDA dp, m8
    try testing.expectEqual(@as(u8, 2), dataWidth(0xA5, false, true)); // LDA dp, m16
    try testing.expectEqual(@as(u8, 2), dataWidth(0x9D, false, true)); // STA abs,X m16
    try testing.expectEqual(@as(u8, 2), dataWidth(0x92, false, true)); // STA (dp) m16
    try testing.expectEqual(@as(u8, 2), dataWidth(0xAE, true, false)); // LDX abs, x16
    try testing.expectEqual(@as(u8, 1), dataWidth(0x8C, true, true)); // STY abs, x8
    try testing.expectEqual(@as(u8, 2), dataWidth(0xEE, false, true)); // INC abs, m16
    try testing.expectEqual(@as(u8, 2), dataWidth(0x9E, false, true)); // STZ abs,X m16
    try testing.expectEqual(@as(u8, 1), dataWidth(0x44, true, true)); // MVP: byte/step
    try testing.expectEqual(@as(u8, 2), dataWidth(0xD4, true, true)); // PEI pointer
    try testing.expectEqual(@as(u8, 2), dataWidth(0x6C, true, true)); // JMP (abs)
    try testing.expectEqual(@as(u8, 3), dataWidth(0xDC, true, true)); // JML [abs]
    try testing.expectEqual(@as(u8, 0), dataWidth(0xA9, false, true)); // LDA # (operand, not data)
    try testing.expectEqual(@as(u8, 0), dataWidth(0xEA, true, true)); // NOP
    try testing.expectEqual(@as(u8, 0), dataWidth(0x48, false, true)); // PHA (pushes unrecorded)
    try testing.expectEqual(@as(u8, 0), dataWidth(0xF4, true, true)); // PEA (push of an immediate)
}

test "flag semantics: latest M/X win, operands exec, writes demote code" {
    const gpa = testing.allocator;
    const bytes = try gpa.alloc(u8, cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    const map: UsageMap = .{ .bytes = bytes };

    // LDA # executed 16-bit first, then 8-bit: the opcode byte keeps only
    // the latest widths; the 16-bit run's extra operand byte keeps Exec.
    map.noteInstr(0x00_8000, 0xA9, false, false);
    try testing.expectEqual(flag_opcode | flag_exec, bytes[0x00_8000]);
    try testing.expectEqual(flag_exec, bytes[0x00_8001]);
    try testing.expectEqual(flag_exec, bytes[0x00_8002]);
    map.noteInstr(0x00_8000, 0xA9, true, true);
    try testing.expectEqual(flag_opcode | flag_exec | flag_m | flag_x, bytes[0x00_8000]);

    // A 16-bit read back-marks both bytes; a write clears Exec.
    map.noteRead(0x7E_1001, 2);
    try testing.expectEqual(flag_read, bytes[0x7E_1000]);
    try testing.expectEqual(flag_read, bytes[0x7E_1001]);
    map.noteWrite(0x00_8002, 1); // self-modified operand byte
    try testing.expectEqual(flag_write, bytes[0x00_8002]);

    // Operand marking wraps the 24-bit space rather than indexing out.
    map.noteInstr(0xFF_FFFF, 0x5C, true, true); // 4-byte JML at the very top
    try testing.expect(bytes[0xFF_FFFF] & flag_opcode != 0);
    try testing.expect(bytes[0x00_0000] & flag_exec != 0);
    try testing.expect(bytes[0x00_0002] & flag_exec != 0);
    // And a wrapped 16-bit read at the bottom back-marks to the top.
    map.noteRead(0x00_0000, 2);
    try testing.expect(bytes[0xFF_FFFF] & flag_read != 0);
}
