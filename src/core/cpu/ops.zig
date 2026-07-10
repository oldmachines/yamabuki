//! 65C816 instruction implementations and addressing modes.
//!
//! Everything here is generic over the CPU (and therefore bus) type and
//! comptime-specialized on the M/X width flags: `dispatch` is instantiated
//! four times, and inside each instantiation every width decision, index
//! mask, and flag computation is resolved at compile time.

const std = @import("std");
const wdc = @import("wdc65816.zig");
const Flags = wdc.Flags;

pub const Mode = enum {
    imm,
    abs, // a
    abs_x, // a,x
    abs_y, // a,y
    abs_long, // al
    abs_long_x, // al,x
    dp, // d
    dp_x, // d,x
    dp_y, // d,y
    dp_ind, // (d)
    dp_ind_x, // (d,x)
    dp_ind_y, // (d),y
    dp_ind_long, // [d]
    dp_ind_long_y, // [d],y
    sr, // d,s
    sr_ind_y, // (d,s),y
};

const AccessKind = enum { read, write, rmw };

/// 16-bit operands in these modes wrap within bank 0 (direct page / stack).
fn wrapsBank0(comptime mode: Mode) bool {
    return switch (mode) {
        .dp, .dp_x, .dp_y, .sr => true,
        else => false,
    };
}

/// Emulation-mode quirk: with DL == 0, direct-page pointer fetches of the
/// 6502-era addressing modes wrap within the direct page.
inline fn dpWraps(cpu: anytype) bool {
    return cpu.regs.e and (cpu.regs.d & 0xFF) == 0;
}

fn dpAddr(cpu: anytype, offset: u8, index: u16) u16 {
    if (dpWraps(cpu)) {
        const lo: u8 = @truncate(@as(u16, offset) +% index);
        return (cpu.regs.d & 0xFF00) | lo;
    }
    return cpu.regs.d +% offset +% index;
}

/// Successor byte address of a 16-bit direct-page pointer fetch. Per the
/// SST hardware vectors this is a straight 16-bit increment even in the
/// emulation-mode DL==0 case (the page-wrap quirk affects only the base
/// offset computation, not the pointer's high byte).
fn dpSucc(cpu: anytype, addr: u16) u16 {
    _ = cpu;
    return addr +% 1;
}

inline fn dpIdle(cpu: anytype) void {
    if ((cpu.regs.d & 0xFF) != 0) cpu.idle();
}

/// Index registers masked to the comptime-known width.
inline fn indexX(cpu: anytype, comptime x8: bool) u16 {
    return if (x8) cpu.regs.x & 0xFF else cpu.regs.x;
}

inline fn indexY(cpu: anytype, comptime x8: bool) u16 {
    return if (x8) cpu.regs.y & 0xFF else cpu.regs.y;
}

fn effAddr(cpu: anytype, comptime mode: Mode, comptime x8: bool, comptime kind: AccessKind) u24 {
    switch (mode) {
        .imm => unreachable,
        .abs => {
            return @as(u24, cpu.regs.dbr) << 16 | cpu.fetch16();
        },
        .abs_x, .abs_y => {
            const base = @as(u24, cpu.regs.dbr) << 16 | cpu.fetch16();
            const index = if (mode == .abs_x) indexX(cpu, x8) else indexY(cpu, x8);
            const addr = base +% index;
            const crossed = (base >> 8) != (addr >> 8);
            if (kind != .read or !x8 or crossed) cpu.idle();
            return addr;
        },
        .abs_long => return cpu.fetch24(),
        .abs_long_x => return cpu.fetch24() +% indexX(cpu, x8),
        .dp => {
            const off = cpu.fetch8();
            dpIdle(cpu);
            return dpAddr(cpu, off, 0);
        },
        .dp_x, .dp_y => {
            const off = cpu.fetch8();
            dpIdle(cpu);
            cpu.idle();
            return dpAddr(cpu, off, if (mode == .dp_x) indexX(cpu, x8) else indexY(cpu, x8));
        },
        .dp_ind => {
            const off = cpu.fetch8();
            dpIdle(cpu);
            const p = dpAddr(cpu, off, 0);
            const lo: u16 = cpu.read8(p);
            const hi: u16 = cpu.read8(dpSucc(cpu, p));
            return @as(u24, cpu.regs.dbr) << 16 | (lo | hi << 8);
        },
        .dp_ind_x => {
            const off = cpu.fetch8();
            dpIdle(cpu);
            cpu.idle();
            const p = dpAddr(cpu, off, indexX(cpu, x8));
            const lo: u16 = cpu.read8(p);
            const hi: u16 = cpu.read8(dpSucc(cpu, p));
            return @as(u24, cpu.regs.dbr) << 16 | (lo | hi << 8);
        },
        .dp_ind_y => {
            const off = cpu.fetch8();
            dpIdle(cpu);
            const p = dpAddr(cpu, off, 0);
            const lo: u16 = cpu.read8(p);
            const hi: u16 = cpu.read8(dpSucc(cpu, p));
            const base = @as(u24, cpu.regs.dbr) << 16 | (lo | hi << 8);
            const addr = base +% indexY(cpu, x8);
            const crossed = (base >> 8) != (addr >> 8);
            if (kind != .read or !x8 or crossed) cpu.idle();
            return addr;
        },
        .dp_ind_long, .dp_ind_long_y => {
            const off = cpu.fetch8();
            dpIdle(cpu);
            const p = cpu.regs.d +% off;
            const lo: u24 = cpu.read8(p);
            const mid: u24 = cpu.read8(p +% 1);
            const hi: u24 = cpu.read8(p +% 2);
            const base = lo | mid << 8 | hi << 16;
            return if (mode == .dp_ind_long_y) base +% indexY(cpu, x8) else base;
        },
        .sr => {
            const off = cpu.fetch8();
            cpu.idle();
            return cpu.regs.s +% off;
        },
        .sr_ind_y => {
            const off = cpu.fetch8();
            cpu.idle();
            const p = cpu.regs.s +% off;
            const lo: u16 = cpu.read8(p);
            const hi: u16 = cpu.read8(p +% 1);
            cpu.idle();
            return (@as(u24, cpu.regs.dbr) << 16 | (lo | hi << 8)) +% indexY(cpu, x8);
        },
    }
}

fn readVal(cpu: anytype, addr: u24, comptime w8: bool, comptime mode: Mode) if (w8) u8 else u16 {
    if (w8) return cpu.read8(addr);
    if (wrapsBank0(mode)) return cpu.read16b0(@truncate(addr));
    return cpu.read16(addr);
}

fn writeVal(cpu: anytype, addr: u24, value: anytype, comptime w8: bool, comptime mode: Mode) void {
    if (w8) {
        cpu.write8(addr, @truncate(value));
    } else if (wrapsBank0(mode)) {
        cpu.write16b0(@truncate(addr), value);
    } else {
        cpu.write16(addr, value);
    }
}

/// RMW writes go high byte first.
fn writeValRev(cpu: anytype, addr: u24, value: u16, comptime w8: bool, comptime mode: Mode) void {
    if (w8) {
        cpu.write8(addr, @truncate(value));
    } else {
        const hi_addr = if (wrapsBank0(mode)) @as(u24, @as(u16, @truncate(addr)) +% 1) else addr +% 1;
        cpu.write8(hi_addr, @truncate(value >> 8));
        cpu.write8(addr, @truncate(value));
    }
}

// --- ALU -------------------------------------------------------------------

const Alu = enum { ora, and_, eor, adc, sbc, cmp, cpx, cpy, lda, ldx, ldy, bit };

fn Word(comptime w8: bool) type {
    return if (w8) u8 else u16;
}

fn adcVal(cpu: anytype, comptime w8: bool, data: Word(w8)) void {
    const W = Word(w8);
    const bits = @bitSizeOf(W);
    const a: i32 = if (w8) cpu.al() else cpu.regs.c;
    const dv: i32 = data;
    const msb: i32 = 1 << (bits - 1);
    var result: i32 = undefined;
    var carry: i32 = @intFromBool(cpu.getFlag(Flags.c));

    if (!cpu.getFlag(Flags.d)) {
        result = a + dv + carry;
    } else {
        // BCD nibble-serial addition (matches hardware flag behavior).
        result = (a & 0xF) + (dv & 0xF) + carry;
        if (result > 0x9) result += 0x6;
        carry = @intFromBool(result > 0xF);
        result = (a & 0xF0) + (dv & 0xF0) + (carry << 4) + (result & 0xF);
        if (!w8) {
            if (result > 0x9F) result += 0x60;
            carry = @intFromBool(result > 0xFF);
            result = (a & 0xF00) + (dv & 0xF00) + (carry << 8) + (result & 0xFF);
            if (result > 0x9FF) result += 0x600;
            carry = @intFromBool(result > 0xFFF);
            result = (a & 0xF000) + (dv & 0xF000) + (carry << 12) + (result & 0xFFF);
        }
    }

    cpu.putFlag(Flags.v, (~(a ^ dv) & (a ^ result) & msb) != 0);
    if (cpu.getFlag(Flags.d)) {
        const limit: i32 = if (w8) 0x9F else 0x9FFF;
        if (result > limit) result += if (w8) 0x60 else 0x6000;
    }
    cpu.putFlag(Flags.c, result > (if (w8) @as(i32, 0xFF) else 0xFFFF));
    const r: W = @truncate(@as(u32, @bitCast(result)));
    if (w8) {
        cpu.setAl(r);
        cpu.setNZ8(r);
    } else {
        cpu.regs.c = r;
        cpu.setNZ16(r);
    }
}

fn sbcVal(cpu: anytype, comptime w8: bool, data_in: Word(w8)) void {
    const W = Word(w8);
    const bits = @bitSizeOf(W);
    const data: W = ~data_in;
    const a: i32 = if (w8) cpu.al() else cpu.regs.c;
    const dv: i32 = data;
    const msb: i32 = 1 << (bits - 1);
    var result: i32 = undefined;
    var carry: i32 = @intFromBool(cpu.getFlag(Flags.c));

    if (!cpu.getFlag(Flags.d)) {
        result = a + dv + carry;
    } else {
        result = (a & 0xF) + (dv & 0xF) + carry;
        if (result <= 0xF) result -= 0x6;
        carry = @intFromBool(result > 0xF);
        result = (a & 0xF0) + (dv & 0xF0) + (carry << 4) + (result & 0xF);
        if (!w8) {
            if (result <= 0xFF) result -= 0x60;
            carry = @intFromBool(result > 0xFF);
            result = (a & 0xF00) + (dv & 0xF00) + (carry << 8) + (result & 0xFF);
            if (result <= 0xFFF) result -= 0x600;
            carry = @intFromBool(result > 0xFFF);
            result = (a & 0xF000) + (dv & 0xF000) + (carry << 12) + (result & 0xFFF);
        }
    }

    cpu.putFlag(Flags.v, (~(a ^ dv) & (a ^ result) & msb) != 0);
    if (cpu.getFlag(Flags.d)) {
        const limit: i32 = if (w8) 0xFF else 0xFFFF;
        if (result <= limit) result -= if (w8) 0x60 else 0x6000;
    }
    cpu.putFlag(Flags.c, result > (if (w8) @as(i32, 0xFF) else 0xFFFF));
    const r: W = @truncate(@as(u32, @bitCast(result)));
    if (w8) {
        cpu.setAl(r);
        cpu.setNZ8(r);
    } else {
        cpu.regs.c = r;
        cpu.setNZ16(r);
    }
}

fn compare(cpu: anytype, comptime w8: bool, reg: u16, data: Word(w8)) void {
    const W = Word(w8);
    const r: W = if (w8) @as(u8, @truncate(reg)) else reg;
    const diff = r -% data;
    cpu.putFlag(Flags.c, r >= data);
    if (w8) cpu.setNZ8(diff) else cpu.setNZ16(diff);
}

fn applyAlu(cpu: anytype, comptime alu: Alu, comptime w8: bool, comptime is_imm: bool, data: Word(w8)) void {
    switch (alu) {
        .ora, .and_, .eor => {
            if (w8) {
                const r = switch (alu) {
                    .ora => cpu.al() | data,
                    .and_ => cpu.al() & data,
                    .eor => cpu.al() ^ data,
                    else => unreachable,
                };
                cpu.setAl(r);
                cpu.setNZ8(r);
            } else {
                const r = switch (alu) {
                    .ora => cpu.regs.c | data,
                    .and_ => cpu.regs.c & data,
                    .eor => cpu.regs.c ^ data,
                    else => unreachable,
                };
                cpu.regs.c = r;
                cpu.setNZ16(r);
            }
        },
        .adc => adcVal(cpu, w8, data),
        .sbc => sbcVal(cpu, w8, data),
        .cmp => compare(cpu, w8, cpu.regs.c, data),
        .cpx => compare(cpu, w8, cpu.regs.x, data),
        .cpy => compare(cpu, w8, cpu.regs.y, data),
        .lda => {
            if (w8) {
                cpu.setAl(data);
                cpu.setNZ8(data);
            } else {
                cpu.regs.c = data;
                cpu.setNZ16(data);
            }
        },
        .ldx => {
            cpu.regs.x = data;
            if (w8) cpu.setNZ8(@truncate(data)) else cpu.setNZ16(data);
        },
        .ldy => {
            cpu.regs.y = data;
            if (w8) cpu.setNZ8(@truncate(data)) else cpu.setNZ16(data);
        },
        .bit => {
            const masked = if (w8) (cpu.al() & data) else (cpu.regs.c & data);
            cpu.putFlag(Flags.z, masked == 0);
            if (!is_imm) {
                const top: Word(w8) = @as(Word(w8), 1) << (@bitSizeOf(Word(w8)) - 1);
                cpu.putFlag(Flags.n, (data & top) != 0);
                cpu.putFlag(Flags.v, (data & (top >> 1)) != 0);
            }
        },
    }
}

fn readOp(cpu: anytype, comptime alu: Alu, comptime w8: bool, comptime x8: bool, comptime mode: Mode) void {
    const data = if (mode == .imm)
        (if (w8) cpu.fetch8() else cpu.fetch16())
    else blk: {
        const addr = effAddr(cpu, mode, x8, .read);
        break :blk readVal(cpu, addr, w8, mode);
    };
    applyAlu(cpu, alu, w8, mode == .imm, data);
}

// --- stores ------------------------------------------------------------------

const StoreSrc = enum { a, x, y, zero };

fn storeOp(cpu: anytype, comptime src: StoreSrc, comptime w8: bool, comptime x8: bool, comptime mode: Mode) void {
    const addr = effAddr(cpu, mode, x8, .write);
    const value: u16 = switch (src) {
        .a => cpu.regs.c,
        .x => cpu.regs.x,
        .y => cpu.regs.y,
        .zero => 0,
    };
    writeVal(cpu, addr, value, w8, mode);
}

// --- read-modify-write --------------------------------------------------------

const RmwOp = enum { asl, lsr, rol, ror, inc, dec, tsb, trb };

fn rmwApply(cpu: anytype, comptime op: RmwOp, comptime w8: bool, value: Word(w8)) Word(w8) {
    const W = Word(w8);
    const top: W = @as(W, 1) << (@bitSizeOf(W) - 1);
    var v = value;
    switch (op) {
        .asl => {
            cpu.putFlag(Flags.c, (v & top) != 0);
            v <<= 1;
        },
        .lsr => {
            cpu.putFlag(Flags.c, (v & 1) != 0);
            v >>= 1;
        },
        .rol => {
            const cin: W = @intFromBool(cpu.getFlag(Flags.c));
            cpu.putFlag(Flags.c, (v & top) != 0);
            v = (v << 1) | cin;
        },
        .ror => {
            const cin: W = @intFromBool(cpu.getFlag(Flags.c));
            cpu.putFlag(Flags.c, (v & 1) != 0);
            v = (v >> 1) | (cin << (@bitSizeOf(W) - 1));
        },
        .inc => v +%= 1,
        .dec => v -%= 1,
        .tsb => {
            const a: W = if (w8) cpu.al() else cpu.regs.c;
            cpu.putFlag(Flags.z, (a & v) == 0);
            v |= a;
        },
        .trb => {
            const a: W = if (w8) cpu.al() else cpu.regs.c;
            cpu.putFlag(Flags.z, (a & v) == 0);
            v &= ~a;
        },
    }
    switch (op) {
        .tsb, .trb => {},
        else => if (w8) cpu.setNZ8(v) else cpu.setNZ16(v),
    }
    return v;
}

fn rmwOp(cpu: anytype, comptime op: RmwOp, comptime w8: bool, comptime x8: bool, comptime mode: Mode) void {
    const addr = effAddr(cpu, mode, x8, .rmw);
    const value = readVal(cpu, addr, w8, mode);
    cpu.idle();
    const result = rmwApply(cpu, op, w8, value);
    writeValRev(cpu, addr, result, w8, mode);
}

fn rmwAcc(cpu: anytype, comptime op: RmwOp, comptime w8: bool) void {
    cpu.idle();
    if (w8) {
        cpu.setAl(rmwApply(cpu, op, true, cpu.al()));
    } else {
        cpu.regs.c = rmwApply(cpu, op, false, cpu.regs.c);
    }
}

// --- branches / jumps ----------------------------------------------------------

fn branch(cpu: anytype, taken: bool) void {
    const disp: u16 = @bitCast(@as(i16, @as(i8, @bitCast(cpu.fetch8()))));
    if (taken) {
        cpu.idle();
        const old = cpu.regs.pc;
        const target = old +% disp;
        if (cpu.regs.e and (old & 0xFF00) != (target & 0xFF00)) cpu.idle();
        cpu.regs.pc = target;
    }
}

fn swi(cpu: anytype, comptime native_vector: u16, comptime e_vector: u16) void {
    _ = cpu.fetch8(); // signature byte
    if (!cpu.regs.e) cpu.push8(cpu.regs.pbr);
    cpu.push16(cpu.regs.pc);
    cpu.push8(cpu.regs.p);
    cpu.regs.p = (cpu.regs.p | Flags.i) & ~Flags.d;
    cpu.regs.pbr = 0;
    cpu.regs.pc = cpu.read16(if (cpu.regs.e) e_vector else native_vector);
}

fn blockMove(cpu: anytype, comptime x8: bool, comptime forward: bool) void {
    const dst_bank = cpu.fetch8();
    const src_bank = cpu.fetch8();
    cpu.regs.dbr = dst_bank;
    const v = cpu.read8(@as(u24, src_bank) << 16 | indexX(cpu, x8));
    cpu.write8(@as(u24, dst_bank) << 16 | indexY(cpu, x8), v);
    cpu.idle();
    cpu.idle();
    if (x8) {
        const delta: u8 = if (forward) 1 else 0xFF;
        cpu.regs.x = @as(u8, @truncate(cpu.regs.x)) +% delta;
        cpu.regs.y = @as(u8, @truncate(cpu.regs.y)) +% delta;
    } else {
        const delta: u16 = if (forward) 1 else 0xFFFF;
        cpu.regs.x +%= delta;
        cpu.regs.y +%= delta;
    }
    cpu.regs.c -%= 1;
    if (cpu.regs.c != 0xFFFF) cpu.regs.pc -%= 3;
}

// --- dispatch --------------------------------------------------------------

pub fn dispatch(cpu: anytype, comptime m8: bool, comptime x8: bool) void {
    const op = cpu.fetch8();
    switch (op) {
        // BRK / COP / interrupts-as-instructions
        0x00 => swi(cpu, 0xFFE6, 0xFFFE),
        0x02 => swi(cpu, 0xFFE4, 0xFFF4),

        // ORA
        0x01 => readOp(cpu, .ora, m8, x8, .dp_ind_x),
        0x03 => readOp(cpu, .ora, m8, x8, .sr),
        0x05 => readOp(cpu, .ora, m8, x8, .dp),
        0x07 => readOp(cpu, .ora, m8, x8, .dp_ind_long),
        0x09 => readOp(cpu, .ora, m8, x8, .imm),
        0x0D => readOp(cpu, .ora, m8, x8, .abs),
        0x0F => readOp(cpu, .ora, m8, x8, .abs_long),
        0x11 => readOp(cpu, .ora, m8, x8, .dp_ind_y),
        0x12 => readOp(cpu, .ora, m8, x8, .dp_ind),
        0x13 => readOp(cpu, .ora, m8, x8, .sr_ind_y),
        0x15 => readOp(cpu, .ora, m8, x8, .dp_x),
        0x17 => readOp(cpu, .ora, m8, x8, .dp_ind_long_y),
        0x19 => readOp(cpu, .ora, m8, x8, .abs_y),
        0x1D => readOp(cpu, .ora, m8, x8, .abs_x),
        0x1F => readOp(cpu, .ora, m8, x8, .abs_long_x),

        // AND
        0x21 => readOp(cpu, .and_, m8, x8, .dp_ind_x),
        0x23 => readOp(cpu, .and_, m8, x8, .sr),
        0x25 => readOp(cpu, .and_, m8, x8, .dp),
        0x27 => readOp(cpu, .and_, m8, x8, .dp_ind_long),
        0x29 => readOp(cpu, .and_, m8, x8, .imm),
        0x2D => readOp(cpu, .and_, m8, x8, .abs),
        0x2F => readOp(cpu, .and_, m8, x8, .abs_long),
        0x31 => readOp(cpu, .and_, m8, x8, .dp_ind_y),
        0x32 => readOp(cpu, .and_, m8, x8, .dp_ind),
        0x33 => readOp(cpu, .and_, m8, x8, .sr_ind_y),
        0x35 => readOp(cpu, .and_, m8, x8, .dp_x),
        0x37 => readOp(cpu, .and_, m8, x8, .dp_ind_long_y),
        0x39 => readOp(cpu, .and_, m8, x8, .abs_y),
        0x3D => readOp(cpu, .and_, m8, x8, .abs_x),
        0x3F => readOp(cpu, .and_, m8, x8, .abs_long_x),

        // EOR
        0x41 => readOp(cpu, .eor, m8, x8, .dp_ind_x),
        0x43 => readOp(cpu, .eor, m8, x8, .sr),
        0x45 => readOp(cpu, .eor, m8, x8, .dp),
        0x47 => readOp(cpu, .eor, m8, x8, .dp_ind_long),
        0x49 => readOp(cpu, .eor, m8, x8, .imm),
        0x4D => readOp(cpu, .eor, m8, x8, .abs),
        0x4F => readOp(cpu, .eor, m8, x8, .abs_long),
        0x51 => readOp(cpu, .eor, m8, x8, .dp_ind_y),
        0x52 => readOp(cpu, .eor, m8, x8, .dp_ind),
        0x53 => readOp(cpu, .eor, m8, x8, .sr_ind_y),
        0x55 => readOp(cpu, .eor, m8, x8, .dp_x),
        0x57 => readOp(cpu, .eor, m8, x8, .dp_ind_long_y),
        0x59 => readOp(cpu, .eor, m8, x8, .abs_y),
        0x5D => readOp(cpu, .eor, m8, x8, .abs_x),
        0x5F => readOp(cpu, .eor, m8, x8, .abs_long_x),

        // ADC
        0x61 => readOp(cpu, .adc, m8, x8, .dp_ind_x),
        0x63 => readOp(cpu, .adc, m8, x8, .sr),
        0x65 => readOp(cpu, .adc, m8, x8, .dp),
        0x67 => readOp(cpu, .adc, m8, x8, .dp_ind_long),
        0x69 => readOp(cpu, .adc, m8, x8, .imm),
        0x6D => readOp(cpu, .adc, m8, x8, .abs),
        0x6F => readOp(cpu, .adc, m8, x8, .abs_long),
        0x71 => readOp(cpu, .adc, m8, x8, .dp_ind_y),
        0x72 => readOp(cpu, .adc, m8, x8, .dp_ind),
        0x73 => readOp(cpu, .adc, m8, x8, .sr_ind_y),
        0x75 => readOp(cpu, .adc, m8, x8, .dp_x),
        0x77 => readOp(cpu, .adc, m8, x8, .dp_ind_long_y),
        0x79 => readOp(cpu, .adc, m8, x8, .abs_y),
        0x7D => readOp(cpu, .adc, m8, x8, .abs_x),
        0x7F => readOp(cpu, .adc, m8, x8, .abs_long_x),

        // SBC
        0xE1 => readOp(cpu, .sbc, m8, x8, .dp_ind_x),
        0xE3 => readOp(cpu, .sbc, m8, x8, .sr),
        0xE5 => readOp(cpu, .sbc, m8, x8, .dp),
        0xE7 => readOp(cpu, .sbc, m8, x8, .dp_ind_long),
        0xE9 => readOp(cpu, .sbc, m8, x8, .imm),
        0xED => readOp(cpu, .sbc, m8, x8, .abs),
        0xEF => readOp(cpu, .sbc, m8, x8, .abs_long),
        0xF1 => readOp(cpu, .sbc, m8, x8, .dp_ind_y),
        0xF2 => readOp(cpu, .sbc, m8, x8, .dp_ind),
        0xF3 => readOp(cpu, .sbc, m8, x8, .sr_ind_y),
        0xF5 => readOp(cpu, .sbc, m8, x8, .dp_x),
        0xF7 => readOp(cpu, .sbc, m8, x8, .dp_ind_long_y),
        0xF9 => readOp(cpu, .sbc, m8, x8, .abs_y),
        0xFD => readOp(cpu, .sbc, m8, x8, .abs_x),
        0xFF => readOp(cpu, .sbc, m8, x8, .abs_long_x),

        // CMP
        0xC1 => readOp(cpu, .cmp, m8, x8, .dp_ind_x),
        0xC3 => readOp(cpu, .cmp, m8, x8, .sr),
        0xC5 => readOp(cpu, .cmp, m8, x8, .dp),
        0xC7 => readOp(cpu, .cmp, m8, x8, .dp_ind_long),
        0xC9 => readOp(cpu, .cmp, m8, x8, .imm),
        0xCD => readOp(cpu, .cmp, m8, x8, .abs),
        0xCF => readOp(cpu, .cmp, m8, x8, .abs_long),
        0xD1 => readOp(cpu, .cmp, m8, x8, .dp_ind_y),
        0xD2 => readOp(cpu, .cmp, m8, x8, .dp_ind),
        0xD3 => readOp(cpu, .cmp, m8, x8, .sr_ind_y),
        0xD5 => readOp(cpu, .cmp, m8, x8, .dp_x),
        0xD7 => readOp(cpu, .cmp, m8, x8, .dp_ind_long_y),
        0xD9 => readOp(cpu, .cmp, m8, x8, .abs_y),
        0xDD => readOp(cpu, .cmp, m8, x8, .abs_x),
        0xDF => readOp(cpu, .cmp, m8, x8, .abs_long_x),

        // CPX / CPY
        0xE0 => readOp(cpu, .cpx, x8, x8, .imm),
        0xE4 => readOp(cpu, .cpx, x8, x8, .dp),
        0xEC => readOp(cpu, .cpx, x8, x8, .abs),
        0xC0 => readOp(cpu, .cpy, x8, x8, .imm),
        0xC4 => readOp(cpu, .cpy, x8, x8, .dp),
        0xCC => readOp(cpu, .cpy, x8, x8, .abs),

        // BIT
        0x24 => readOp(cpu, .bit, m8, x8, .dp),
        0x2C => readOp(cpu, .bit, m8, x8, .abs),
        0x34 => readOp(cpu, .bit, m8, x8, .dp_x),
        0x3C => readOp(cpu, .bit, m8, x8, .abs_x),
        0x89 => readOp(cpu, .bit, m8, x8, .imm),

        // LDA
        0xA1 => readOp(cpu, .lda, m8, x8, .dp_ind_x),
        0xA3 => readOp(cpu, .lda, m8, x8, .sr),
        0xA5 => readOp(cpu, .lda, m8, x8, .dp),
        0xA7 => readOp(cpu, .lda, m8, x8, .dp_ind_long),
        0xA9 => readOp(cpu, .lda, m8, x8, .imm),
        0xAD => readOp(cpu, .lda, m8, x8, .abs),
        0xAF => readOp(cpu, .lda, m8, x8, .abs_long),
        0xB1 => readOp(cpu, .lda, m8, x8, .dp_ind_y),
        0xB2 => readOp(cpu, .lda, m8, x8, .dp_ind),
        0xB3 => readOp(cpu, .lda, m8, x8, .sr_ind_y),
        0xB5 => readOp(cpu, .lda, m8, x8, .dp_x),
        0xB7 => readOp(cpu, .lda, m8, x8, .dp_ind_long_y),
        0xB9 => readOp(cpu, .lda, m8, x8, .abs_y),
        0xBD => readOp(cpu, .lda, m8, x8, .abs_x),
        0xBF => readOp(cpu, .lda, m8, x8, .abs_long_x),

        // LDX / LDY
        0xA2 => readOp(cpu, .ldx, x8, x8, .imm),
        0xA6 => readOp(cpu, .ldx, x8, x8, .dp),
        0xAE => readOp(cpu, .ldx, x8, x8, .abs),
        0xB6 => readOp(cpu, .ldx, x8, x8, .dp_y),
        0xBE => readOp(cpu, .ldx, x8, x8, .abs_y),
        0xA0 => readOp(cpu, .ldy, x8, x8, .imm),
        0xA4 => readOp(cpu, .ldy, x8, x8, .dp),
        0xAC => readOp(cpu, .ldy, x8, x8, .abs),
        0xB4 => readOp(cpu, .ldy, x8, x8, .dp_x),
        0xBC => readOp(cpu, .ldy, x8, x8, .abs_x),

        // STA
        0x81 => storeOp(cpu, .a, m8, x8, .dp_ind_x),
        0x83 => storeOp(cpu, .a, m8, x8, .sr),
        0x85 => storeOp(cpu, .a, m8, x8, .dp),
        0x87 => storeOp(cpu, .a, m8, x8, .dp_ind_long),
        0x8D => storeOp(cpu, .a, m8, x8, .abs),
        0x8F => storeOp(cpu, .a, m8, x8, .abs_long),
        0x91 => storeOp(cpu, .a, m8, x8, .dp_ind_y),
        0x92 => storeOp(cpu, .a, m8, x8, .dp_ind),
        0x93 => storeOp(cpu, .a, m8, x8, .sr_ind_y),
        0x95 => storeOp(cpu, .a, m8, x8, .dp_x),
        0x97 => storeOp(cpu, .a, m8, x8, .dp_ind_long_y),
        0x99 => storeOp(cpu, .a, m8, x8, .abs_y),
        0x9D => storeOp(cpu, .a, m8, x8, .abs_x),
        0x9F => storeOp(cpu, .a, m8, x8, .abs_long_x),

        // STX / STY / STZ
        0x86 => storeOp(cpu, .x, x8, x8, .dp),
        0x8E => storeOp(cpu, .x, x8, x8, .abs),
        0x96 => storeOp(cpu, .x, x8, x8, .dp_y),
        0x84 => storeOp(cpu, .y, x8, x8, .dp),
        0x8C => storeOp(cpu, .y, x8, x8, .abs),
        0x94 => storeOp(cpu, .y, x8, x8, .dp_x),
        0x64 => storeOp(cpu, .zero, m8, x8, .dp),
        0x74 => storeOp(cpu, .zero, m8, x8, .dp_x),
        0x9C => storeOp(cpu, .zero, m8, x8, .abs),
        0x9E => storeOp(cpu, .zero, m8, x8, .abs_x),

        // RMW memory
        0x06 => rmwOp(cpu, .asl, m8, x8, .dp),
        0x0E => rmwOp(cpu, .asl, m8, x8, .abs),
        0x16 => rmwOp(cpu, .asl, m8, x8, .dp_x),
        0x1E => rmwOp(cpu, .asl, m8, x8, .abs_x),
        0x46 => rmwOp(cpu, .lsr, m8, x8, .dp),
        0x4E => rmwOp(cpu, .lsr, m8, x8, .abs),
        0x56 => rmwOp(cpu, .lsr, m8, x8, .dp_x),
        0x5E => rmwOp(cpu, .lsr, m8, x8, .abs_x),
        0x26 => rmwOp(cpu, .rol, m8, x8, .dp),
        0x2E => rmwOp(cpu, .rol, m8, x8, .abs),
        0x36 => rmwOp(cpu, .rol, m8, x8, .dp_x),
        0x3E => rmwOp(cpu, .rol, m8, x8, .abs_x),
        0x66 => rmwOp(cpu, .ror, m8, x8, .dp),
        0x6E => rmwOp(cpu, .ror, m8, x8, .abs),
        0x76 => rmwOp(cpu, .ror, m8, x8, .dp_x),
        0x7E => rmwOp(cpu, .ror, m8, x8, .abs_x),
        0xC6 => rmwOp(cpu, .dec, m8, x8, .dp),
        0xCE => rmwOp(cpu, .dec, m8, x8, .abs),
        0xD6 => rmwOp(cpu, .dec, m8, x8, .dp_x),
        0xDE => rmwOp(cpu, .dec, m8, x8, .abs_x),
        0xE6 => rmwOp(cpu, .inc, m8, x8, .dp),
        0xEE => rmwOp(cpu, .inc, m8, x8, .abs),
        0xF6 => rmwOp(cpu, .inc, m8, x8, .dp_x),
        0xFE => rmwOp(cpu, .inc, m8, x8, .abs_x),
        0x04 => rmwOp(cpu, .tsb, m8, x8, .dp),
        0x0C => rmwOp(cpu, .tsb, m8, x8, .abs),
        0x14 => rmwOp(cpu, .trb, m8, x8, .dp),
        0x1C => rmwOp(cpu, .trb, m8, x8, .abs),

        // RMW accumulator
        0x0A => rmwAcc(cpu, .asl, m8),
        0x4A => rmwAcc(cpu, .lsr, m8),
        0x2A => rmwAcc(cpu, .rol, m8),
        0x6A => rmwAcc(cpu, .ror, m8),
        0x1A => rmwAcc(cpu, .inc, m8),
        0x3A => rmwAcc(cpu, .dec, m8),

        // INC/DEC index registers
        0xE8 => {
            cpu.idle();
            cpu.regs.x = if (x8) @as(u8, @truncate(cpu.regs.x)) +% 1 else cpu.regs.x +% 1;
            if (x8) cpu.setNZ8(@truncate(cpu.regs.x)) else cpu.setNZ16(cpu.regs.x);
        },
        0xC8 => {
            cpu.idle();
            cpu.regs.y = if (x8) @as(u8, @truncate(cpu.regs.y)) +% 1 else cpu.regs.y +% 1;
            if (x8) cpu.setNZ8(@truncate(cpu.regs.y)) else cpu.setNZ16(cpu.regs.y);
        },
        0xCA => {
            cpu.idle();
            cpu.regs.x = if (x8) @as(u8, @truncate(cpu.regs.x)) -% 1 else cpu.regs.x -% 1;
            if (x8) cpu.setNZ8(@truncate(cpu.regs.x)) else cpu.setNZ16(cpu.regs.x);
        },
        0x88 => {
            cpu.idle();
            cpu.regs.y = if (x8) @as(u8, @truncate(cpu.regs.y)) -% 1 else cpu.regs.y -% 1;
            if (x8) cpu.setNZ8(@truncate(cpu.regs.y)) else cpu.setNZ16(cpu.regs.y);
        },

        // Branches
        0x10 => branch(cpu, !cpu.getFlag(Flags.n)),
        0x30 => branch(cpu, cpu.getFlag(Flags.n)),
        0x50 => branch(cpu, !cpu.getFlag(Flags.v)),
        0x70 => branch(cpu, cpu.getFlag(Flags.v)),
        0x90 => branch(cpu, !cpu.getFlag(Flags.c)),
        0xB0 => branch(cpu, cpu.getFlag(Flags.c)),
        0xD0 => branch(cpu, !cpu.getFlag(Flags.z)),
        0xF0 => branch(cpu, cpu.getFlag(Flags.z)),
        0x80 => branch(cpu, true),
        0x82 => { // BRL
            const disp = cpu.fetch16();
            cpu.idle();
            cpu.regs.pc +%= disp;
        },

        // Jumps and calls
        0x4C => cpu.regs.pc = cpu.fetch16(),
        0x5C => { // JMP long
            const target = cpu.fetch24();
            cpu.regs.pc = @truncate(target);
            cpu.regs.pbr = @truncate(target >> 16);
        },
        0x6C => { // JMP (a)
            const ptr = cpu.fetch16();
            cpu.regs.pc = cpu.read16b0(ptr);
        },
        0x7C => { // JMP (a,x)
            const ptr = cpu.fetch16() +% indexX(cpu, x8);
            cpu.idle();
            const bank = @as(u24, cpu.regs.pbr) << 16;
            const lo: u16 = cpu.read8(bank | ptr);
            const hi: u16 = cpu.read8(bank | (ptr +% 1));
            cpu.regs.pc = lo | hi << 8;
        },
        0xDC => { // JML [a]
            const ptr = cpu.fetch16();
            cpu.regs.pc = cpu.read16b0(ptr);
            cpu.regs.pbr = cpu.read8(ptr +% 2);
        },
        0x20 => { // JSR a
            const target = cpu.fetch16();
            cpu.idle();
            cpu.push16(cpu.regs.pc -% 1);
            cpu.regs.pc = target;
        },
        0xFC => { // JSR (a,x)
            const lo8: u16 = cpu.fetch8();
            cpu.push16(cpu.regs.pc);
            const hi8: u16 = cpu.fetch8();
            cpu.idle();
            const ptr = (lo8 | hi8 << 8) +% indexX(cpu, x8);
            const bank = @as(u24, cpu.regs.pbr) << 16;
            const lo: u16 = cpu.read8(bank | ptr);
            const hi: u16 = cpu.read8(bank | (ptr +% 1));
            cpu.regs.pc = lo | hi << 8;
        },
        0x22 => { // JSL
            const lo8: u16 = cpu.fetch8();
            const hi8: u16 = cpu.fetch8();
            cpu.push8n(cpu.regs.pbr);
            cpu.idle();
            const bank = cpu.fetch8();
            cpu.push16n(cpu.regs.pc -% 1);
            cpu.fixStackE();
            cpu.regs.pc = lo8 | hi8 << 8;
            cpu.regs.pbr = bank;
        },
        0x60 => { // RTS
            cpu.idle();
            cpu.idle();
            cpu.regs.pc = cpu.pull16() +% 1;
            cpu.idle();
        },
        0x6B => { // RTL
            cpu.idle();
            cpu.idle();
            cpu.regs.pc = cpu.pull16n() +% 1;
            cpu.regs.pbr = cpu.pull8n();
            cpu.fixStackE();
        },
        0x40 => { // RTI
            cpu.idle();
            cpu.idle();
            cpu.setP(cpu.pull8());
            cpu.regs.pc = cpu.pull16();
            if (!cpu.regs.e) cpu.regs.pbr = cpu.pull8();
        },

        // Stack ops
        0x48 => { // PHA
            cpu.idle();
            if (m8) cpu.push8(cpu.al()) else cpu.push16(cpu.regs.c);
        },
        0xDA => { // PHX
            cpu.idle();
            if (x8) cpu.push8n(@truncate(cpu.regs.x)) else cpu.push16n(cpu.regs.x);
            cpu.fixStackE();
        },
        0x5A => { // PHY
            cpu.idle();
            if (x8) cpu.push8n(@truncate(cpu.regs.y)) else cpu.push16n(cpu.regs.y);
            cpu.fixStackE();
        },
        0x08 => { // PHP
            cpu.idle();
            cpu.push8(cpu.regs.p);
        },
        0x8B => { // PHB
            cpu.idle();
            cpu.push8n(cpu.regs.dbr);
            cpu.fixStackE();
        },
        0x4B => { // PHK
            cpu.idle();
            cpu.push8n(cpu.regs.pbr);
            cpu.fixStackE();
        },
        0x0B => { // PHD
            cpu.idle();
            cpu.push16n(cpu.regs.d);
            cpu.fixStackE();
        },
        0x68 => { // PLA
            cpu.idle();
            cpu.idle();
            if (m8) {
                const v = cpu.pull8();
                cpu.setAl(v);
                cpu.setNZ8(v);
            } else {
                cpu.regs.c = cpu.pull16();
                cpu.setNZ16(cpu.regs.c);
            }
        },
        0xFA => { // PLX (old-style: wraps within page 1 in emulation mode)
            cpu.idle();
            cpu.idle();
            if (x8) {
                cpu.regs.x = cpu.pull8();
                cpu.setNZ8(@truncate(cpu.regs.x));
            } else {
                cpu.regs.x = cpu.pull16();
                cpu.setNZ16(cpu.regs.x);
            }
        },
        0x7A => { // PLY (old-style: wraps within page 1 in emulation mode)
            cpu.idle();
            cpu.idle();
            if (x8) {
                cpu.regs.y = cpu.pull8();
                cpu.setNZ8(@truncate(cpu.regs.y));
            } else {
                cpu.regs.y = cpu.pull16();
                cpu.setNZ16(cpu.regs.y);
            }
        },
        0x28 => { // PLP
            cpu.idle();
            cpu.idle();
            cpu.setP(cpu.pull8());
        },
        0xAB => { // PLB
            cpu.idle();
            cpu.idle();
            cpu.regs.dbr = cpu.pull8n();
            cpu.setNZ8(cpu.regs.dbr);
            cpu.fixStackE();
        },
        0x2B => { // PLD
            cpu.idle();
            cpu.idle();
            cpu.regs.d = cpu.pull16n();
            cpu.setNZ16(cpu.regs.d);
            cpu.fixStackE();
        },
        0xF4 => { // PEA
            const v = cpu.fetch16();
            cpu.push16n(v);
            cpu.fixStackE();
        },
        0xD4 => { // PEI
            const off = cpu.fetch8();
            dpIdle(cpu);
            const p = dpAddr(cpu, off, 0);
            const lo: u16 = cpu.read8(p);
            const hi: u16 = cpu.read8(dpSucc(cpu, p));
            cpu.push16n(lo | hi << 8);
            cpu.fixStackE();
        },
        0x62 => { // PER
            const disp = cpu.fetch16();
            cpu.idle();
            cpu.push16n(cpu.regs.pc +% disp);
            cpu.fixStackE();
        },

        // Flag ops
        0x18 => {
            cpu.idle();
            cpu.putFlag(Flags.c, false);
        },
        0x38 => {
            cpu.idle();
            cpu.putFlag(Flags.c, true);
        },
        0x58 => {
            cpu.idle();
            cpu.putFlag(Flags.i, false);
        },
        0x78 => {
            cpu.idle();
            cpu.putFlag(Flags.i, true);
        },
        0xB8 => {
            cpu.idle();
            cpu.putFlag(Flags.v, false);
        },
        0xD8 => {
            cpu.idle();
            cpu.putFlag(Flags.d, false);
        },
        0xF8 => {
            cpu.idle();
            cpu.putFlag(Flags.d, true);
        },
        0xC2 => { // REP
            const v = cpu.fetch8();
            cpu.idle();
            cpu.setP(cpu.regs.p & ~v);
        },
        0xE2 => { // SEP
            const v = cpu.fetch8();
            cpu.idle();
            cpu.setP(cpu.regs.p | v);
        },
        0xFB => { // XCE
            cpu.idle();
            const old_carry = cpu.getFlag(Flags.c);
            cpu.putFlag(Flags.c, cpu.regs.e);
            cpu.regs.e = old_carry;
            if (cpu.regs.e) {
                cpu.setP(cpu.regs.p); // forces M/X, clears XH/YH
                cpu.regs.s = 0x0100 | (cpu.regs.s & 0xFF);
            }
        },

        // Transfers
        0xAA => { // TAX
            cpu.idle();
            cpu.regs.x = if (x8) cpu.al() else cpu.regs.c;
            if (x8) cpu.setNZ8(@truncate(cpu.regs.x)) else cpu.setNZ16(cpu.regs.x);
        },
        0xA8 => { // TAY
            cpu.idle();
            cpu.regs.y = if (x8) cpu.al() else cpu.regs.c;
            if (x8) cpu.setNZ8(@truncate(cpu.regs.y)) else cpu.setNZ16(cpu.regs.y);
        },
        0x8A => { // TXA
            cpu.idle();
            if (m8) {
                cpu.setAl(@truncate(cpu.regs.x));
                cpu.setNZ8(@truncate(cpu.regs.x));
            } else {
                cpu.regs.c = cpu.regs.x;
                cpu.setNZ16(cpu.regs.c);
            }
        },
        0x98 => { // TYA
            cpu.idle();
            if (m8) {
                cpu.setAl(@truncate(cpu.regs.y));
                cpu.setNZ8(@truncate(cpu.regs.y));
            } else {
                cpu.regs.c = cpu.regs.y;
                cpu.setNZ16(cpu.regs.c);
            }
        },
        0xBA => { // TSX
            cpu.idle();
            cpu.regs.x = if (x8) (cpu.regs.s & 0xFF) else cpu.regs.s;
            if (x8) cpu.setNZ8(@truncate(cpu.regs.x)) else cpu.setNZ16(cpu.regs.x);
        },
        0x9A => { // TXS (no flags)
            cpu.idle();
            cpu.regs.s = if (cpu.regs.e) 0x0100 | (cpu.regs.x & 0xFF) else cpu.regs.x;
        },
        0x5B => { // TCD
            cpu.idle();
            cpu.regs.d = cpu.regs.c;
            cpu.setNZ16(cpu.regs.d);
        },
        0x7B => { // TDC
            cpu.idle();
            cpu.regs.c = cpu.regs.d;
            cpu.setNZ16(cpu.regs.c);
        },
        0x1B => { // TCS (no flags)
            cpu.idle();
            cpu.regs.s = if (cpu.regs.e) 0x0100 | (cpu.regs.c & 0xFF) else cpu.regs.c;
        },
        0x3B => { // TSC
            cpu.idle();
            cpu.regs.c = cpu.regs.s;
            cpu.setNZ16(cpu.regs.c);
        },
        0x9B => { // TXY
            cpu.idle();
            cpu.regs.y = cpu.regs.x;
            if (x8) cpu.setNZ8(@truncate(cpu.regs.y)) else cpu.setNZ16(cpu.regs.y);
        },
        0xBB => { // TYX
            cpu.idle();
            cpu.regs.x = cpu.regs.y;
            if (x8) cpu.setNZ8(@truncate(cpu.regs.x)) else cpu.setNZ16(cpu.regs.x);
        },
        0xEB => { // XBA
            cpu.idle();
            cpu.idle();
            cpu.regs.c = (cpu.regs.c >> 8) | (cpu.regs.c << 8);
            cpu.setNZ8(cpu.al());
        },

        // Block moves
        0x54 => blockMove(cpu, x8, true), // MVN
        0x44 => blockMove(cpu, x8, false), // MVP

        // Misc
        0xEA => cpu.idle(), // NOP
        0x42 => _ = cpu.fetch8(), // WDM
        0xCB => { // WAI
            cpu.idle();
            cpu.idle();
            cpu.state = .waiting;
        },
        0xDB => { // STP
            cpu.idle();
            cpu.idle();
            cpu.state = .stopped;
        },
    }
}
