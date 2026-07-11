//! SPC700 instruction implementations and the 256-way dispatch.
//!
//! Layout mirrors the 65816 ops module: shared ALU/RMW helpers, addressing
//! wrappers, then one exhaustive switch. Cycle timing falls out of bus
//! traffic (one SPC cycle per read/write/idle); hardware's dummy reads on
//! store instructions are performed so read-sensitive I/O ($FD-$FF timer
//! counters) behaves correctly. Exact per-cycle bus ordering is validated
//! loosely (the SST runner treats cycle-count mismatches as non-fatal);
//! register/memory results are the pass gate.

const std = @import("std");
const spc700 = @import("spc700.zig");
const Flags = spc700.Flags;

// --- ALU ------------------------------------------------------------------

const Alu = enum { orr, andd, eor, adc, sbc, cmp };

fn adcOp(smp: anytype, a: u8, b: u8) u8 {
    const cin: u16 = if (smp.getFlag(Flags.c)) 1 else 0;
    const sum: u16 = @as(u16, a) + b + cin;
    const r: u8 = @truncate(sum);
    smp.putFlag(Flags.c, sum > 0xFF);
    smp.putFlag(Flags.h, (a & 0x0F) + (b & 0x0F) + @as(u8, @intCast(cin)) > 0x0F);
    smp.putFlag(Flags.v, (~(a ^ b) & (a ^ r) & 0x80) != 0);
    smp.setNZ8(r);
    return r;
}

fn cmpOp(smp: anytype, a: u8, b: u8) void {
    smp.putFlag(Flags.c, a >= b);
    smp.setNZ8(a -% b);
}

/// One 8-bit ALU step; `cmp` returns the left operand unchanged (no store).
fn alu(smp: anytype, comptime k: Alu, a: u8, b: u8) u8 {
    switch (k) {
        .orr => {
            const r = a | b;
            smp.setNZ8(r);
            return r;
        },
        .andd => {
            const r = a & b;
            smp.setNZ8(r);
            return r;
        },
        .eor => {
            const r = a ^ b;
            smp.setNZ8(r);
            return r;
        },
        .adc => return adcOp(smp, a, b),
        .sbc => return adcOp(smp, a, ~b),
        .cmp => {
            cmpOp(smp, a, b);
            return a;
        },
    }
}

// --- A-accumulator addressing wrappers -------------------------------------

fn aluAImm(smp: anytype, comptime k: Alu) void {
    smp.regs.a = alu(smp, k, smp.regs.a, smp.fetch8());
}

fn aluADp(smp: anytype, comptime k: Alu) void {
    smp.regs.a = alu(smp, k, smp.regs.a, smp.readDp(smp.fetch8()));
}

fn aluADpX(smp: anytype, comptime k: Alu) void {
    const d = smp.fetch8();
    smp.idle();
    smp.regs.a = alu(smp, k, smp.regs.a, smp.readDp(d +% smp.regs.x));
}

fn aluAAbs(smp: anytype, comptime k: Alu) void {
    smp.regs.a = alu(smp, k, smp.regs.a, smp.read8(smp.fetch16()));
}

fn aluAAbsIdx(smp: anytype, comptime k: Alu, index: u8) void {
    const base = smp.fetch16();
    smp.idle();
    smp.regs.a = alu(smp, k, smp.regs.a, smp.read8(base +% index));
}

/// (X): the direct-page byte X points at.
fn aluAIndX(smp: anytype, comptime k: Alu) void {
    smp.idle();
    smp.regs.a = alu(smp, k, smp.regs.a, smp.readDp(smp.regs.x));
}

/// [dp+X]: pointer in the direct page at dp+X (page-wrapped).
fn aluAPtrX(smp: anytype, comptime k: Alu) void {
    const d = smp.fetch8();
    smp.idle();
    const addr = smp.readDp16(d +% smp.regs.x);
    smp.regs.a = alu(smp, k, smp.regs.a, smp.read8(addr));
}

/// [dp]+Y: pointer in the direct page at dp, plus Y.
fn aluAPtrY(smp: anytype, comptime k: Alu) void {
    const d = smp.fetch8();
    smp.idle();
    const addr = smp.readDp16(d) +% smp.regs.y;
    smp.regs.a = alu(smp, k, smp.regs.a, smp.read8(addr));
}

// --- memory-to-memory ALU ---------------------------------------------------

/// dp ← dp op dp (CMP variant reads both and discards the result).
fn aluDpDp(smp: anytype, comptime k: Alu) void {
    const src = smp.readDp(smp.fetch8());
    const dst_off = smp.fetch8();
    const dst = smp.readDp(dst_off);
    const r = alu(smp, k, dst, src);
    if (k == .cmp) smp.idle() else smp.writeDp(dst_off, r);
}

/// dp ← dp op #imm.
fn aluDpImm(smp: anytype, comptime k: Alu) void {
    const imm = smp.fetch8();
    const d = smp.fetch8();
    const dst = smp.readDp(d);
    const r = alu(smp, k, dst, imm);
    if (k == .cmp) smp.idle() else smp.writeDp(d, r);
}

/// (X) ← (X) op (Y).
fn aluIndInd(smp: anytype, comptime k: Alu) void {
    smp.idle();
    const src = smp.readDp(smp.regs.y);
    const dst = smp.readDp(smp.regs.x);
    const r = alu(smp, k, dst, src);
    if (k == .cmp) smp.idle() else smp.writeDp(smp.regs.x, r);
}

// --- read-modify-write ------------------------------------------------------

const Rmw = enum { asl, rol, lsr, ror, inc, dec };

fn rmw(smp: anytype, comptime k: Rmw, v: u8) u8 {
    var r: u8 = undefined;
    switch (k) {
        .asl => {
            smp.putFlag(Flags.c, v & 0x80 != 0);
            r = v << 1;
        },
        .rol => {
            const cin: u8 = if (smp.getFlag(Flags.c)) 1 else 0;
            smp.putFlag(Flags.c, v & 0x80 != 0);
            r = v << 1 | cin;
        },
        .lsr => {
            smp.putFlag(Flags.c, v & 0x01 != 0);
            r = v >> 1;
        },
        .ror => {
            const cin: u8 = if (smp.getFlag(Flags.c)) 0x80 else 0;
            smp.putFlag(Flags.c, v & 0x01 != 0);
            r = v >> 1 | cin;
        },
        .inc => r = v +% 1,
        .dec => r = v -% 1,
    }
    smp.setNZ8(r);
    return r;
}

fn rmwDp(smp: anytype, comptime k: Rmw) void {
    const d = smp.fetch8();
    smp.writeDp(d, rmw(smp, k, smp.readDp(d)));
}

fn rmwDpX(smp: anytype, comptime k: Rmw) void {
    const d = smp.fetch8();
    smp.idle();
    const off = d +% smp.regs.x;
    smp.writeDp(off, rmw(smp, k, smp.readDp(off)));
}

fn rmwAbs(smp: anytype, comptime k: Rmw) void {
    const addr = smp.fetch16();
    smp.write8(addr, rmw(smp, k, smp.read8(addr)));
}

fn rmwReg(smp: anytype, comptime k: Rmw, reg: *u8) void {
    smp.idle();
    reg.* = rmw(smp, k, reg.*);
}

// --- branches ---------------------------------------------------------------

fn branch(smp: anytype, cond: bool) void {
    const rel = smp.fetch8();
    if (cond) {
        smp.idle();
        smp.idle();
        smp.regs.pc +%= @bitCast(@as(i16, @as(i8, @bitCast(rel))));
    }
}

// --- absolute-address bit operand ($aaab bbba: 13-bit addr + 3-bit bit) ------

const MemBit = struct { addr: u16, mask: u8 };

fn fetchMemBit(smp: anytype) MemBit {
    const w = smp.fetch16();
    return .{ .addr = w & 0x1FFF, .mask = @as(u8, 1) << @intCast(w >> 13) };
}

// --- register MOV loads/stores ------------------------------------------------

fn movLoadDp(smp: anytype, reg: *u8) void {
    reg.* = smp.readDp(smp.fetch8());
    smp.setNZ8(reg.*);
}

fn movLoadDpIdx(smp: anytype, reg: *u8, index: u8) void {
    const d = smp.fetch8();
    smp.idle();
    reg.* = smp.readDp(d +% index);
    smp.setNZ8(reg.*);
}

fn movLoadAbs(smp: anytype, reg: *u8) void {
    reg.* = smp.read8(smp.fetch16());
    smp.setNZ8(reg.*);
}

/// Stores perform a dummy read of the target address (hardware behavior;
/// matters for read-sensitive I/O like the timer counters).
fn movStoreDp(smp: anytype, value: u8) void {
    const d = smp.fetch8();
    _ = smp.readDp(d);
    smp.writeDp(d, value);
}

fn movStoreDpIdx(smp: anytype, value: u8, index: u8) void {
    const d = smp.fetch8();
    smp.idle();
    const off = d +% index;
    _ = smp.readDp(off);
    smp.writeDp(off, value);
}

fn movStoreAbs(smp: anytype, value: u8) void {
    const addr = smp.fetch16();
    _ = smp.read8(addr);
    smp.write8(addr, value);
}

fn movStoreAbsIdx(smp: anytype, value: u8, index: u8) void {
    const base = smp.fetch16();
    smp.idle();
    const addr = base +% index;
    _ = smp.read8(addr);
    smp.write8(addr, value);
}

// --- dispatch ---------------------------------------------------------------

pub fn dispatch(smp: anytype) void {
    const op = smp.fetch8();
    switch (op) {
        0x00 => smp.idle(), // NOP

        // TCALL 0-15: vector table at $FFDE downward.
        0x01, 0x11, 0x21, 0x31, 0x41, 0x51, 0x61, 0x71, 0x81, 0x91, 0xA1, 0xB1, 0xC1, 0xD1, 0xE1, 0xF1 => {
            smp.idle();
            smp.push16(smp.regs.pc);
            smp.idle();
            smp.idle();
            const vector: u16 = 0xFFDE - 2 * @as(u16, op >> 4);
            smp.regs.pc = smp.read16(vector);
        },

        // SET1/CLR1 dp.bit
        0x02, 0x22, 0x42, 0x62, 0x82, 0xA2, 0xC2, 0xE2 => {
            const d = smp.fetch8();
            const mask = @as(u8, 1) << @intCast(op >> 5);
            smp.writeDp(d, smp.readDp(d) | mask);
        },
        0x12, 0x32, 0x52, 0x72, 0x92, 0xB2, 0xD2, 0xF2 => {
            const d = smp.fetch8();
            const mask = @as(u8, 1) << @intCast(op >> 5);
            smp.writeDp(d, smp.readDp(d) & ~mask);
        },

        // BBS/BBC dp.bit, rel
        0x03, 0x23, 0x43, 0x63, 0x83, 0xA3, 0xC3, 0xE3 => {
            const v = smp.readDp(smp.fetch8());
            smp.idle();
            branch(smp, v & (@as(u8, 1) << @intCast(op >> 5)) != 0);
        },
        0x13, 0x33, 0x53, 0x73, 0x93, 0xB3, 0xD3, 0xF3 => {
            const v = smp.readDp(smp.fetch8());
            smp.idle();
            branch(smp, v & (@as(u8, 1) << @intCast(op >> 5)) == 0);
        },

        // --- OR ---
        0x04 => aluADp(smp, .orr),
        0x05 => aluAAbs(smp, .orr),
        0x06 => aluAIndX(smp, .orr),
        0x07 => aluAPtrX(smp, .orr),
        0x08 => aluAImm(smp, .orr),
        0x09 => aluDpDp(smp, .orr),
        0x14 => aluADpX(smp, .orr),
        0x15 => aluAAbsIdx(smp, .orr, smp.regs.x),
        0x16 => aluAAbsIdx(smp, .orr, smp.regs.y),
        0x17 => aluAPtrY(smp, .orr),
        0x18 => aluDpImm(smp, .orr),
        0x19 => aluIndInd(smp, .orr),

        // --- AND ---
        0x24 => aluADp(smp, .andd),
        0x25 => aluAAbs(smp, .andd),
        0x26 => aluAIndX(smp, .andd),
        0x27 => aluAPtrX(smp, .andd),
        0x28 => aluAImm(smp, .andd),
        0x29 => aluDpDp(smp, .andd),
        0x34 => aluADpX(smp, .andd),
        0x35 => aluAAbsIdx(smp, .andd, smp.regs.x),
        0x36 => aluAAbsIdx(smp, .andd, smp.regs.y),
        0x37 => aluAPtrY(smp, .andd),
        0x38 => aluDpImm(smp, .andd),
        0x39 => aluIndInd(smp, .andd),

        // --- EOR ---
        0x44 => aluADp(smp, .eor),
        0x45 => aluAAbs(smp, .eor),
        0x46 => aluAIndX(smp, .eor),
        0x47 => aluAPtrX(smp, .eor),
        0x48 => aluAImm(smp, .eor),
        0x49 => aluDpDp(smp, .eor),
        0x54 => aluADpX(smp, .eor),
        0x55 => aluAAbsIdx(smp, .eor, smp.regs.x),
        0x56 => aluAAbsIdx(smp, .eor, smp.regs.y),
        0x57 => aluAPtrY(smp, .eor),
        0x58 => aluDpImm(smp, .eor),
        0x59 => aluIndInd(smp, .eor),

        // --- CMP A ---
        0x64 => aluADp(smp, .cmp),
        0x65 => aluAAbs(smp, .cmp),
        0x66 => aluAIndX(smp, .cmp),
        0x67 => aluAPtrX(smp, .cmp),
        0x68 => aluAImm(smp, .cmp),
        0x69 => aluDpDp(smp, .cmp),
        0x74 => aluADpX(smp, .cmp),
        0x75 => aluAAbsIdx(smp, .cmp, smp.regs.x),
        0x76 => aluAAbsIdx(smp, .cmp, smp.regs.y),
        0x77 => aluAPtrY(smp, .cmp),
        0x78 => aluDpImm(smp, .cmp),
        0x79 => aluIndInd(smp, .cmp),

        // --- ADC ---
        0x84 => aluADp(smp, .adc),
        0x85 => aluAAbs(smp, .adc),
        0x86 => aluAIndX(smp, .adc),
        0x87 => aluAPtrX(smp, .adc),
        0x88 => aluAImm(smp, .adc),
        0x89 => aluDpDp(smp, .adc),
        0x94 => aluADpX(smp, .adc),
        0x95 => aluAAbsIdx(smp, .adc, smp.regs.x),
        0x96 => aluAAbsIdx(smp, .adc, smp.regs.y),
        0x97 => aluAPtrY(smp, .adc),
        0x98 => aluDpImm(smp, .adc),
        0x99 => aluIndInd(smp, .adc),

        // --- SBC ---
        0xA4 => aluADp(smp, .sbc),
        0xA5 => aluAAbs(smp, .sbc),
        0xA6 => aluAIndX(smp, .sbc),
        0xA7 => aluAPtrX(smp, .sbc),
        0xA8 => aluAImm(smp, .sbc),
        0xA9 => aluDpDp(smp, .sbc),
        0xB4 => aluADpX(smp, .sbc),
        0xB5 => aluAAbsIdx(smp, .sbc, smp.regs.x),
        0xB6 => aluAAbsIdx(smp, .sbc, smp.regs.y),
        0xB7 => aluAPtrY(smp, .sbc),
        0xB8 => aluDpImm(smp, .sbc),
        0xB9 => aluIndInd(smp, .sbc),

        // --- CMP X / CMP Y ---
        0xC8 => cmpOp(smp, smp.regs.x, smp.fetch8()),
        0x3E => cmpOp(smp, smp.regs.x, smp.readDp(smp.fetch8())),
        0x1E => cmpOp(smp, smp.regs.x, smp.read8(smp.fetch16())),
        0xAD => cmpOp(smp, smp.regs.y, smp.fetch8()),
        0x7E => cmpOp(smp, smp.regs.y, smp.readDp(smp.fetch8())),
        0x5E => cmpOp(smp, smp.regs.y, smp.read8(smp.fetch16())),

        // --- shifts / rotates ---
        0x0B => rmwDp(smp, .asl),
        0x1B => rmwDpX(smp, .asl),
        0x0C => rmwAbs(smp, .asl),
        0x1C => rmwReg(smp, .asl, &smp.regs.a),
        0x2B => rmwDp(smp, .rol),
        0x3B => rmwDpX(smp, .rol),
        0x2C => rmwAbs(smp, .rol),
        0x3C => rmwReg(smp, .rol, &smp.regs.a),
        0x4B => rmwDp(smp, .lsr),
        0x5B => rmwDpX(smp, .lsr),
        0x4C => rmwAbs(smp, .lsr),
        0x5C => rmwReg(smp, .lsr, &smp.regs.a),
        0x6B => rmwDp(smp, .ror),
        0x7B => rmwDpX(smp, .ror),
        0x6C => rmwAbs(smp, .ror),
        0x7C => rmwReg(smp, .ror, &smp.regs.a),

        // --- INC / DEC ---
        0xAB => rmwDp(smp, .inc),
        0xBB => rmwDpX(smp, .inc),
        0xAC => rmwAbs(smp, .inc),
        0xBC => rmwReg(smp, .inc, &smp.regs.a),
        0x3D => rmwReg(smp, .inc, &smp.regs.x),
        0xFC => rmwReg(smp, .inc, &smp.regs.y),
        0x8B => rmwDp(smp, .dec),
        0x9B => rmwDpX(smp, .dec),
        0x8C => rmwAbs(smp, .dec),
        0x9C => rmwReg(smp, .dec, &smp.regs.a),
        0x1D => rmwReg(smp, .dec, &smp.regs.x),
        0xDC => rmwReg(smp, .dec, &smp.regs.y),

        // --- MOV register loads ---
        0xE8 => {
            smp.regs.a = smp.fetch8();
            smp.setNZ8(smp.regs.a);
        },
        0xCD => {
            smp.regs.x = smp.fetch8();
            smp.setNZ8(smp.regs.x);
        },
        0x8D => {
            smp.regs.y = smp.fetch8();
            smp.setNZ8(smp.regs.y);
        },
        0xE4 => movLoadDp(smp, &smp.regs.a),
        0xF4 => movLoadDpIdx(smp, &smp.regs.a, smp.regs.x),
        0xE5 => movLoadAbs(smp, &smp.regs.a),
        0xF5 => {
            const base = smp.fetch16();
            smp.idle();
            smp.regs.a = smp.read8(base +% smp.regs.x);
            smp.setNZ8(smp.regs.a);
        },
        0xF6 => {
            const base = smp.fetch16();
            smp.idle();
            smp.regs.a = smp.read8(base +% smp.regs.y);
            smp.setNZ8(smp.regs.a);
        },
        0xE6 => { // MOV A,(X)
            smp.idle();
            smp.regs.a = smp.readDp(smp.regs.x);
            smp.setNZ8(smp.regs.a);
        },
        0xBF => { // MOV A,(X)+
            smp.idle();
            smp.regs.a = smp.readDp(smp.regs.x);
            smp.regs.x +%= 1;
            smp.idle();
            smp.setNZ8(smp.regs.a);
        },
        0xE7 => { // MOV A,[dp+X]
            const d = smp.fetch8();
            smp.idle();
            smp.regs.a = smp.read8(smp.readDp16(d +% smp.regs.x));
            smp.setNZ8(smp.regs.a);
        },
        0xF7 => { // MOV A,[dp]+Y
            const d = smp.fetch8();
            smp.idle();
            smp.regs.a = smp.read8(smp.readDp16(d) +% smp.regs.y);
            smp.setNZ8(smp.regs.a);
        },
        0xF8 => movLoadDp(smp, &smp.regs.x),
        0xF9 => movLoadDpIdx(smp, &smp.regs.x, smp.regs.y),
        0xE9 => movLoadAbs(smp, &smp.regs.x),
        0xEB => movLoadDp(smp, &smp.regs.y),
        0xFB => movLoadDpIdx(smp, &smp.regs.y, smp.regs.x),
        0xEC => movLoadAbs(smp, &smp.regs.y),

        // --- MOV register-to-register (NZ except MOV SP,X) ---
        0x7D => {
            smp.idle();
            smp.regs.a = smp.regs.x;
            smp.setNZ8(smp.regs.a);
        },
        0xDD => {
            smp.idle();
            smp.regs.a = smp.regs.y;
            smp.setNZ8(smp.regs.a);
        },
        0x5D => {
            smp.idle();
            smp.regs.x = smp.regs.a;
            smp.setNZ8(smp.regs.x);
        },
        0xFD => {
            smp.idle();
            smp.regs.y = smp.regs.a;
            smp.setNZ8(smp.regs.y);
        },
        0x9D => {
            smp.idle();
            smp.regs.x = smp.regs.sp;
            smp.setNZ8(smp.regs.x);
        },
        0xBD => {
            smp.idle();
            smp.regs.sp = smp.regs.x;
        },

        // --- MOV stores (no flags; dummy read of the target) ---
        0xC4 => movStoreDp(smp, smp.regs.a),
        0xD4 => movStoreDpIdx(smp, smp.regs.a, smp.regs.x),
        0xC5 => movStoreAbs(smp, smp.regs.a),
        0xD5 => movStoreAbsIdx(smp, smp.regs.a, smp.regs.x),
        0xD6 => movStoreAbsIdx(smp, smp.regs.a, smp.regs.y),
        0xC6 => { // MOV (X),A
            smp.idle();
            _ = smp.readDp(smp.regs.x);
            smp.writeDp(smp.regs.x, smp.regs.a);
        },
        0xAF => { // MOV (X)+,A (no dummy read)
            smp.idle();
            smp.idle();
            smp.writeDp(smp.regs.x, smp.regs.a);
            smp.regs.x +%= 1;
        },
        0xC7 => { // MOV [dp+X],A
            const d = smp.fetch8();
            smp.idle();
            const addr = smp.readDp16(d +% smp.regs.x);
            _ = smp.read8(addr);
            smp.write8(addr, smp.regs.a);
        },
        0xD7 => { // MOV [dp]+Y,A
            const d = smp.fetch8();
            smp.idle();
            const addr = smp.readDp16(d) +% smp.regs.y;
            _ = smp.read8(addr);
            smp.write8(addr, smp.regs.a);
        },
        0xD8 => movStoreDp(smp, smp.regs.x),
        0xD9 => movStoreDpIdx(smp, smp.regs.x, smp.regs.y),
        0xC9 => movStoreAbs(smp, smp.regs.x),
        0xCB => movStoreDp(smp, smp.regs.y),
        0xDB => movStoreDpIdx(smp, smp.regs.y, smp.regs.x),
        0xCC => movStoreAbs(smp, smp.regs.y),
        0x8F => { // MOV dp,#imm
            const imm = smp.fetch8();
            const d = smp.fetch8();
            _ = smp.readDp(d);
            smp.writeDp(d, imm);
        },
        0xFA => { // MOV dp,dp (no flags, no dummy read)
            const v = smp.readDp(smp.fetch8());
            const d = smp.fetch8();
            smp.writeDp(d, v);
        },

        // --- 16-bit YA ops ---
        0xBA => { // MOVW YA,dp
            const d = smp.fetch8();
            const lo: u16 = smp.readDp(d);
            smp.idle();
            const hi: u16 = smp.readDp(d +% 1);
            smp.setYa(lo | hi << 8);
            smp.setNZ16(smp.ya());
        },
        0xDA => { // MOVW dp,YA (dummy read of the low byte)
            const d = smp.fetch8();
            _ = smp.readDp(d);
            smp.writeDp(d, smp.regs.a);
            smp.writeDp(d +% 1, smp.regs.y);
        },
        0x7A => { // ADDW YA,dp (carry-in cleared; H/V/C from the high byte)
            const d = smp.fetch8();
            const lo = smp.readDp(d);
            smp.idle();
            const hi = smp.readDp(d +% 1);
            smp.putFlag(Flags.c, false);
            const rlo = adcOp(smp, smp.regs.a, lo);
            const rhi = adcOp(smp, smp.regs.y, hi);
            smp.setYa(@as(u16, rhi) << 8 | rlo);
            smp.setNZ16(smp.ya());
        },
        0x9A => { // SUBW YA,dp
            const d = smp.fetch8();
            const lo = smp.readDp(d);
            smp.idle();
            const hi = smp.readDp(d +% 1);
            smp.putFlag(Flags.c, true);
            const rlo = adcOp(smp, smp.regs.a, ~lo);
            const rhi = adcOp(smp, smp.regs.y, ~hi);
            smp.setYa(@as(u16, rhi) << 8 | rlo);
            smp.setNZ16(smp.ya());
        },
        0x5A => { // CMPW YA,dp (N/Z 16-bit, C only)
            const d = smp.fetch8();
            const w = smp.readDp16(d);
            const y_a = smp.ya();
            smp.putFlag(Flags.c, y_a >= w);
            smp.setNZ16(y_a -% w);
        },
        0x3A => { // INCW dp
            const d = smp.fetch8();
            const lo = smp.readDp(d) +% 1;
            smp.writeDp(d, lo);
            const carry: u8 = if (lo == 0) 1 else 0;
            const hi = smp.readDp(d +% 1) +% carry;
            smp.writeDp(d +% 1, hi);
            smp.setNZ16(@as(u16, hi) << 8 | lo);
        },
        0x1A => { // DECW dp
            const d = smp.fetch8();
            const old = smp.readDp(d);
            const lo = old -% 1;
            smp.writeDp(d, lo);
            const borrow: u8 = if (old == 0) 1 else 0;
            const hi = smp.readDp(d +% 1) -% borrow;
            smp.writeDp(d +% 1, hi);
            smp.setNZ16(@as(u16, hi) << 8 | lo);
        },

        // --- MUL / DIV / decimal / nibble swap ---
        0xCF => { // MUL YA: N/Z from the high byte (Y)
            for (0..7) |_| smp.idle();
            const prod = @as(u16, smp.regs.y) * smp.regs.a;
            smp.setYa(prod);
            smp.setNZ8(smp.regs.y);
        },
        0x9E => { // DIV YA,X (hardware overflow quirk per SST)
            for (0..10) |_| smp.idle();
            const y_a: u32 = smp.ya();
            const x: u32 = smp.regs.x;
            smp.putFlag(Flags.h, (smp.regs.y & 0x0F) >= (smp.regs.x & 0x0F));
            smp.putFlag(Flags.v, smp.regs.y >= smp.regs.x);
            if (@as(u32, smp.regs.y) < x << 1) {
                smp.regs.a = @truncate(y_a / x);
                smp.regs.y = @truncate(y_a % x);
            } else {
                smp.regs.a = @truncate(255 - (y_a - (x << 9)) / (256 - x));
                smp.regs.y = @truncate(x + (y_a - (x << 9)) % (256 - x));
            }
            smp.setNZ8(smp.regs.a);
        },
        0xDF => { // DAA
            smp.idle();
            smp.idle();
            if (smp.getFlag(Flags.c) or smp.regs.a > 0x99) {
                smp.regs.a +%= 0x60;
                smp.putFlag(Flags.c, true);
            }
            if (smp.getFlag(Flags.h) or (smp.regs.a & 0x0F) > 0x09) smp.regs.a +%= 0x06;
            smp.setNZ8(smp.regs.a);
        },
        0xBE => { // DAS
            smp.idle();
            smp.idle();
            if (!smp.getFlag(Flags.c) or smp.regs.a > 0x99) {
                smp.regs.a -%= 0x60;
                smp.putFlag(Flags.c, false);
            }
            if (!smp.getFlag(Flags.h) or (smp.regs.a & 0x0F) > 0x09) smp.regs.a -%= 0x06;
            smp.setNZ8(smp.regs.a);
        },
        0x9F => { // XCN A
            for (0..3) |_| smp.idle();
            smp.regs.a = smp.regs.a >> 4 | smp.regs.a << 4;
            smp.setNZ8(smp.regs.a);
        },

        // --- branches ---
        0x2F => branch(smp, true), // BRA
        0x10 => branch(smp, !smp.getFlag(Flags.n)), // BPL
        0x30 => branch(smp, smp.getFlag(Flags.n)), // BMI
        0x50 => branch(smp, !smp.getFlag(Flags.v)), // BVC
        0x70 => branch(smp, smp.getFlag(Flags.v)), // BVS
        0x90 => branch(smp, !smp.getFlag(Flags.c)), // BCC
        0xB0 => branch(smp, smp.getFlag(Flags.c)), // BCS
        0xD0 => branch(smp, !smp.getFlag(Flags.z)), // BNE
        0xF0 => branch(smp, smp.getFlag(Flags.z)), // BEQ
        0x2E => { // CBNE dp,rel
            const v = smp.readDp(smp.fetch8());
            smp.idle();
            branch(smp, smp.regs.a != v);
        },
        0xDE => { // CBNE dp+X,rel
            const d = smp.fetch8();
            smp.idle();
            const v = smp.readDp(d +% smp.regs.x);
            smp.idle();
            branch(smp, smp.regs.a != v);
        },
        0x6E => { // DBNZ dp,rel
            const d = smp.fetch8();
            const v = smp.readDp(d) -% 1;
            smp.writeDp(d, v);
            branch(smp, v != 0);
        },
        0xFE => { // DBNZ Y,rel
            smp.idle();
            smp.idle();
            smp.regs.y -%= 1;
            branch(smp, smp.regs.y != 0);
        },

        // --- jumps / calls / returns ---
        0x5F => smp.regs.pc = smp.fetch16(), // JMP !abs
        0x1F => { // JMP [!abs+X]
            const base = smp.fetch16();
            smp.idle();
            smp.regs.pc = smp.read16(base +% smp.regs.x);
        },
        0x3F => { // CALL !abs
            const target = smp.fetch16();
            smp.idle();
            smp.push16(smp.regs.pc);
            smp.idle();
            smp.idle();
            smp.regs.pc = target;
        },
        0x4F => { // PCALL up (page $FF00)
            const up = smp.fetch8();
            smp.idle();
            smp.push16(smp.regs.pc);
            smp.idle();
            smp.regs.pc = 0xFF00 | @as(u16, up);
        },
        0x6F => { // RET
            smp.idle();
            smp.idle();
            smp.regs.pc = smp.pop16();
        },
        0x7F => { // RETI
            smp.idle();
            smp.idle();
            smp.regs.psw = smp.pop8();
            smp.regs.pc = smp.pop16();
        },
        0x0F => { // BRK
            smp.idle();
            smp.push16(smp.regs.pc);
            smp.push8(smp.regs.psw);
            smp.idle();
            smp.regs.psw = (smp.regs.psw | Flags.b) & ~Flags.i;
            smp.regs.pc = smp.read16(0xFFDE);
        },

        // --- stack ---
        0x0D => {
            smp.idle();
            smp.push8(smp.regs.psw);
            smp.idle();
        },
        0x2D => {
            smp.idle();
            smp.push8(smp.regs.a);
            smp.idle();
        },
        0x4D => {
            smp.idle();
            smp.push8(smp.regs.x);
            smp.idle();
        },
        0x6D => {
            smp.idle();
            smp.push8(smp.regs.y);
            smp.idle();
        },
        0x8E => { // POP PSW
            smp.idle();
            smp.idle();
            smp.regs.psw = smp.pop8();
        },
        0xAE => {
            smp.idle();
            smp.idle();
            smp.regs.a = smp.pop8();
        },
        0xCE => {
            smp.idle();
            smp.idle();
            smp.regs.x = smp.pop8();
        },
        0xEE => {
            smp.idle();
            smp.idle();
            smp.regs.y = smp.pop8();
        },

        // --- carry-bit ops on absolute memory bits ---
        0x0A => { // OR1 C,m.b
            const mb = fetchMemBit(smp);
            const set = smp.read8(mb.addr) & mb.mask != 0;
            smp.idle();
            if (set) smp.putFlag(Flags.c, true);
        },
        0x2A => { // OR1 C,/m.b
            const mb = fetchMemBit(smp);
            const set = smp.read8(mb.addr) & mb.mask != 0;
            smp.idle();
            if (!set) smp.putFlag(Flags.c, true);
        },
        0x4A => { // AND1 C,m.b
            const mb = fetchMemBit(smp);
            if (smp.read8(mb.addr) & mb.mask == 0) smp.putFlag(Flags.c, false);
        },
        0x6A => { // AND1 C,/m.b
            const mb = fetchMemBit(smp);
            if (smp.read8(mb.addr) & mb.mask != 0) smp.putFlag(Flags.c, false);
        },
        0x8A => { // EOR1 C,m.b
            const mb = fetchMemBit(smp);
            const set = smp.read8(mb.addr) & mb.mask != 0;
            smp.idle();
            if (set) smp.putFlag(Flags.c, !smp.getFlag(Flags.c));
        },
        0xAA => { // MOV1 C,m.b
            const mb = fetchMemBit(smp);
            smp.putFlag(Flags.c, smp.read8(mb.addr) & mb.mask != 0);
        },
        0xCA => { // MOV1 m.b,C
            const mb = fetchMemBit(smp);
            const v = smp.read8(mb.addr);
            smp.idle();
            const r = if (smp.getFlag(Flags.c)) v | mb.mask else v & ~mb.mask;
            smp.write8(mb.addr, r);
        },
        0xEA => { // NOT1 m.b
            const mb = fetchMemBit(smp);
            const v = smp.read8(mb.addr);
            smp.write8(mb.addr, v ^ mb.mask);
        },
        0x0E => { // TSET1 !abs: mem |= A; N/Z from A - mem
            const addr = smp.fetch16();
            const v = smp.read8(addr);
            _ = smp.read8(addr);
            smp.setNZ8(smp.regs.a -% v);
            smp.write8(addr, v | smp.regs.a);
        },
        0x4E => { // TCLR1 !abs: mem &= ~A; N/Z from A - mem
            const addr = smp.fetch16();
            const v = smp.read8(addr);
            _ = smp.read8(addr);
            smp.setNZ8(smp.regs.a -% v);
            smp.write8(addr, v & ~smp.regs.a);
        },

        // --- flag instructions ---
        0x60 => {
            smp.idle();
            smp.putFlag(Flags.c, false);
        }, // CLRC
        0x80 => {
            smp.idle();
            smp.putFlag(Flags.c, true);
        }, // SETC
        0xED => { // NOTC
            smp.idle();
            smp.idle();
            smp.putFlag(Flags.c, !smp.getFlag(Flags.c));
        },
        0xE0 => { // CLRV (clears V and H)
            smp.idle();
            smp.regs.psw &= ~(Flags.v | Flags.h);
        },
        0x20 => {
            smp.idle();
            smp.putFlag(Flags.p, false);
        }, // CLRP
        0x40 => {
            smp.idle();
            smp.putFlag(Flags.p, true);
        }, // SETP
        0xA0 => { // EI
            smp.idle();
            smp.idle();
            smp.putFlag(Flags.i, true);
        },
        0xC0 => { // DI
            smp.idle();
            smp.idle();
            smp.putFlag(Flags.i, false);
        },

        // --- halt ---
        0xEF, 0xFF => { // SLEEP / STOP
            smp.idle();
            smp.idle();
            smp.state = .stopped;
        },
    }
}
