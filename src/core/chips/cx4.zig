//! Cx4 (Capcom Cx4): a Hitachi HG51B169 DSP on the Mega Man X2 / X3 boards,
//! used for wireframe 3D (the intro/boss reveals), sprite scale/rotation, and
//! assorted 2D math. Emulated at the command level (HLE), like the DSP-1.
//!
//! The chip is a plain memory-mapped device: an 8 KiB static RAM window sits
//! at $6000-$7FFF of banks $00-$3F/$80-$BF. Games stage operands into the
//! register file at $7F40-$7FA4 (RAM offset $1F40-$1FA4), then poke a command
//! byte to $7F4F — that write runs the whole operation synchronously and
//! leaves the result back in RAM. A poke to $7F47 runs a ROM→RAM block copy.
//! There is no interrupt line and no busy flag the games rely on, so nothing
//! needs scheduling: the command completes inside the port write, and $7F5E
//! (a status byte) always reads back 0.
//!
//! The routines follow the behavior documented by the Cx4 reverse-engineering
//! work and mirrored in the classic emulator HLE (snes9x c4.cpp/c4emu.cpp):
//! the wireframe transform/line rasterizer, OAM builder, scale/rotate, line
//! transformer, bitplane wave, and sprite disintegrate, plus the scalar math
//! commands (multiply, square, Pythagoras, atan2, polar↔rectangular, sum,
//! trapezoid spans, coordinate transform). The Zig here is written from that
//! behavior, not from the chip's microcode, and its data ROM is never used
//! (that path is the LLE approach, which needs the copyrighted Cx4 program).
//!
//! Tables are pure math, generated at comptime: the 512-entry sine/cosine are
//! round(32767·sin/cos(2πi/512)). The chip's own table carries ±1 rounding
//! noise on some entries with no single closed form, but those are the low
//! bit of a Q15 value used for sub-pixel projection — they can never move an
//! integer screen coordinate — so the clean formula is used. Only the 48-byte
//! response of the $5C self-test command is an irregular hardware constant and
//! is carried verbatim (the S-DSP gaussian-table precedent).
//!
//! HLE simplifications, documented on purpose:
//!  - Commands complete instantly; the status byte $7F5E always reads 0.
//!  - Double-precision trig is used for the wireframe rotations (as the
//!    reference HLE does), so a rotated vertex can differ from the chip's
//!    fixed-point microcode by a sub-pixel amount before it is rounded to an
//!    integer pen position.
//!  - Degenerate projections (a vertex on the camera plane) are clamped the
//!    way an x86 double→int conversion would fold them, matching the HLE.

const std = @import("std");

// --- comptime trig tables (Q15) -------------------------------------------

const Trig = enum { sin, cos };
fn trigTable(comptime which: Trig) [512]i16 {
    @setEvalBranchQuota(40000);
    var t: [512]i16 = undefined;
    for (&t, 0..) |*v, i| {
        const rad = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / 512.0;
        const y = switch (which) {
            .sin => @sin(rad),
            .cos => @cos(rad),
        };
        v.* = @intFromFloat(std.math.clamp(@round(32767.0 * y), -32767.0, 32767.0));
    }
    return t;
}
const sin_table = trigTable(.sin);
const cos_table = trigTable(.cos);

/// Response of the $5C "immediate register" self-test command: 48 bytes the
/// chip writes to the head of RAM. A fixed hardware diagnostic pattern with no
/// closed form, carried verbatim (S-DSP gaussian-table precedent).
const test_pattern = [12 * 4]u8{
    0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0x00, 0xff,
    0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0x00, 0x00,
    0xff, 0xff, 0x00, 0x00, 0x80, 0xff, 0xff, 0x7f,
    0x00, 0x80, 0x00, 0xff, 0x7f, 0x00, 0xff, 0x7f,
    0xff, 0x7f, 0xff, 0xff, 0x00, 0x00, 0x01, 0xff,
    0xff, 0xfe, 0x00, 0x01, 0x00, 0xff, 0xfe, 0x00,
};

// --- scratch registers shared by the wireframe helpers --------------------

/// The reference keeps a handful of globals the wireframe routines pass among
/// themselves; grouping them keeps the ports faithful without persisting
/// transient state.
const Wf = struct {
    x: i16 = 0,
    y: i16 = 0,
    z: i16 = 0,
    x2: i16 = 0,
    y2: i16 = 0,
    dist: i16 = 0,
    scale: i16 = 0,
};

/// Fold a double to i16 the way snes9x's x86 build does: an out-of-range or
/// non-finite value converts to INT32_MIN, whose low 16 bits are zero. Games
/// avoid the degenerate projections that trigger it, but matching the fold
/// keeps our output bit-identical to the reference when they don't.
fn d2i16(x: f64) i16 {
    const i: i32 = if (std.math.isNan(x) or x >= 2147483648.0 or x < -2147483648.0)
        std.math.minInt(i32)
    else
        @intFromFloat(@trunc(x));
    return @bitCast(@as(u16, @truncate(@as(u32, @bitCast(i)))));
}

/// Truncate an i32 to i16 with C's wrap-on-store semantics.
fn tr16(x: i32) i16 {
    return @bitCast(@as(u16, @truncate(@as(u32, @bitCast(x)))));
}

pub const Cx4 = struct {
    pub const serialize_skip = .{ "rom", "rom_mask" };

    /// Cartridge ROM (LoROM), re-attached on init and postLoad.
    rom: [*]const u8,
    rom_mask: u32,
    /// The $6000-$7FFF window: 8 KiB of static RAM.
    ram: [0x2000]u8,

    pub fn init(self: *Cx4) void {
        @memset(&self.ram, 0);
        self.rom = undefined;
        self.rom_mask = 0;
    }

    pub fn attach(self: *Cx4, rom: []const u8, rom_mask: u32) void {
        self.rom = rom.ptr;
        self.rom_mask = rom_mask;
    }

    // --- RAM/ROM access helpers -------------------------------------------

    inline fn rb(self: *const Cx4, off: u32) u8 {
        return self.ram[off & 0x1FFF];
    }
    inline fn rw(self: *const Cx4, off: u32) u16 {
        return @as(u16, self.rb(off)) | (@as(u16, self.rb(off + 1)) << 8);
    }
    inline fn r3(self: *const Cx4, off: u32) u32 {
        return @as(u32, self.rb(off)) | (@as(u32, self.rb(off + 1)) << 8) |
            (@as(u32, self.rb(off + 2)) << 16);
    }
    inline fn wb(self: *Cx4, off: u32, v: u8) void {
        self.ram[off & 0x1FFF] = v;
    }
    inline fn ww(self: *Cx4, off: u32, v: u16) void {
        self.wb(off, @truncate(v));
        self.wb(off + 1, @truncate(v >> 8));
    }
    inline fn w3(self: *Cx4, off: u32, v: u32) void {
        self.wb(off, @truncate(v));
        self.wb(off + 1, @truncate(v >> 8));
        self.wb(off + 2, @truncate(v >> 16));
    }

    /// LoROM address → ROM byte offset (the chip's C4GetMemPointer base).
    inline fn romOff(addr: u32) u32 {
        return ((addr & 0xFF0000) >> 1) + (addr & 0x7FFF);
    }
    inline fn romb(self: *const Cx4, off: u32) u8 {
        return self.rom[off & self.rom_mask];
    }

    // --- SNES-facing port -------------------------------------------------

    pub fn read(self: *const Cx4, addr: u16) u8 {
        if (addr == 0x7F5E) return 0; // status byte
        return self.ram[(addr - 0x6000) & 0x1FFF];
    }

    pub fn write(self: *Cx4, addr: u16, value: u8) void {
        self.ram[(addr - 0x6000) & 0x1FFF] = value;
        switch (addr) {
            0x7F47 => self.memoryLoad(),
            0x7F4F => self.command(value),
            else => {},
        }
    }

    /// $7F47: copy `len` bytes from ROM (a 24-bit source) into RAM.
    fn memoryLoad(self: *Cx4) void {
        const src = self.r3(0x1F40);
        const len = self.rw(0x1F43);
        const dst = self.rw(0x1F45) & 0x1FFF;
        const base = romOff(src);
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            self.wb(dst + i, self.romb(base + i));
        }
    }

    /// $7F4F: run the command selected by `byte` (the value just written).
    fn command(self: *Cx4, byte: u8) void {
        const mode = self.ram[0x1F4D];
        // $0E test path: a sub-$40 aligned byte just stores its quarter.
        if (mode == 0x0E and byte < 0x40 and (byte & 3) == 0) {
            self.ram[0x1F80] = byte >> 2;
            return;
        }
        switch (byte) {
            0x00 => self.processSprites(),
            0x01 => { // draw wireframe
                @memset(self.ram[0x300..][0 .. 16 * 12 * 3 * 4], 0);
                self.drawWireFrame();
            },
            0x05 => { // propulsion
                var tmp: i32 = 0x10000;
                const d = self.rw(0x1F83);
                if (d != 0)
                    tmp = (@divTrunc(tmp, @as(i32, d)) * @as(i32, self.rw(0x1F81))) >> 8;
                self.ww(0x1F80, @bitCast(tr16(tmp)));
            },
            0x0D => self.cmdSetVectorLength(),
            0x10 => self.cmdPolar(0x1F80, true),
            0x13 => self.cmdPolar(0x1F80, false),
            0x15 => { // Pythagoras
                const x: f64 = @floatFromInt(@as(i16, @bitCast(self.rw(0x1F80))));
                const y: f64 = @floatFromInt(@as(i16, @bitCast(self.rw(0x1F83))));
                self.ww(0x1F80, @bitCast(@as(i16, @intFromFloat(@sqrt(x * x + y * y)))));
            },
            0x1F => self.cmdAtan(),
            0x22 => self.cmdTrapezoid(),
            0x25 => { // 24-bit multiply
                const a: i32 = @bitCast(self.r3(0x1F80) | signExt24(self.r3(0x1F80)));
                const b: i32 = @bitCast(self.r3(0x1F83) | signExt24(self.r3(0x1F83)));
                self.w3(0x1F80, @bitCast(a *% b));
            },
            0x2D => self.cmdTransformCoords(),
            0x40 => { // sum of the first 0x800 RAM bytes
                var sum: u16 = 0;
                for (self.ram[0..0x800]) |v| sum +%= v;
                self.ww(0x1F80, sum);
            },
            0x54 => self.cmdSquare(),
            0x5C => @memcpy(self.ram[0..test_pattern.len], &test_pattern),
            0x89 => { // immediate ROM signature
                self.ram[0x1F80] = 0x36;
                self.ram[0x1F81] = 0x43;
                self.ram[0x1F82] = 0x05;
            },
            else => {},
        }
    }

    // --- scalar math commands ---------------------------------------------

    fn cmdSetVectorLength(self: *Cx4) void { // $0D
        var x: i16 = @bitCast(self.rw(0x1F80));
        var y: i16 = @bitCast(self.rw(0x1F83));
        const dv: f64 = @floatFromInt(@as(i16, @bitCast(self.rw(0x1F86))));
        const len = @sqrt(@as(f64, @floatFromInt(@as(i32, x) * x + @as(i32, y) * y)));
        const t = if (len != 0) dv / len else 0;
        y = @intFromFloat(@as(f64, @floatFromInt(y)) * t * 0.99);
        x = @intFromFloat(@as(f64, @floatFromInt(x)) * t * 0.98);
        self.ww(0x1F89, @bitCast(x));
        self.ww(0x1F8C, @bitCast(y));
    }

    /// $10 / $13: polar (angle at $1F80, radius at $1F83) → rectangular.
    /// $10 clamps the radius to signed 15-bit and applies a small y bias.
    fn cmdPolar(self: *Cx4, base: u32, comptime is10: bool) void {
        const angle = self.rw(base) & 0x1FF;
        var r1: i32 = self.rw(0x1F83);
        if (is10) {
            r1 = if (r1 & 0x8000 != 0) (r1 | ~@as(i32, 0x7FFF)) else (r1 & 0x7FFF);
            var tmp = (r1 * cos_table[angle] * 2) >> 16;
            self.w3(0x1F86, @bitCast(tmp));
            tmp = (r1 * sin_table[angle] * 2) >> 16;
            self.w3(0x1F89, @bitCast(tmp - (tmp >> 6)));
        } else {
            r1 = @as(i16, @bitCast(@as(u16, @truncate(@as(u32, @bitCast(r1))))));
            var tmp = (r1 * cos_table[angle] * 2) >> 8;
            self.w3(0x1F86, @bitCast(tmp));
            tmp = (r1 * sin_table[angle] * 2) >> 8;
            self.w3(0x1F89, @bitCast(tmp));
        }
    }

    fn cmdAtan(self: *Cx4) void { // $1F
        const x: i16 = @bitCast(self.rw(0x1F80));
        const y: i16 = @bitCast(self.rw(0x1F83));
        var res: i16 = undefined;
        if (x == 0) {
            res = if (y > 0) 0x80 else 0x180;
        } else {
            const t = @as(f64, @floatFromInt(y)) / @as(f64, @floatFromInt(x));
            res = @intFromFloat(std.math.atan(t) / (std.math.pi * 2) * 512);
            if (x < 0) res +%= 0x100;
            res &= 0x1FF;
        }
        self.ww(0x1F86, @bitCast(res));
    }

    fn cmdTrapezoid(self: *Cx4) void { // $22
        const a1 = self.rw(0x1F8C) & 0x1FF;
        const a2 = self.rw(0x1F8F) & 0x1FF;
        const tan1: i32 = if (cos_table[a1] != 0)
            @divTrunc(@as(i32, sin_table[a1]) << 16, cos_table[a1])
        else
            @bitCast(@as(u32, 0x80000000));
        const tan2: i32 = if (cos_table[a2] != 0)
            @divTrunc(@as(i32, sin_table[a2]) << 16, cos_table[a2])
        else
            @bitCast(@as(u32, 0x80000000));

        var y: i16 = @bitCast(self.rw(0x1F83) -% self.rw(0x1F89));
        const off0: i32 = @as(i16, @bitCast(self.rw(0x1F80)));
        const off6: i32 = @as(i16, @bitCast(self.rw(0x1F86)));
        const off93: i32 = @as(i16, @bitCast(self.rw(0x1F93)));
        var j: u32 = 0;
        while (j < 225) : (j += 1) {
            var left: i32 = undefined;
            var right: i32 = undefined;
            if (y >= 0) {
                left = ((tan1 * y) >> 16) - off0 + off6;
                right = ((tan2 * y) >> 16) - off0 + off6 + off93;
                if (left < 0 and right < 0) {
                    left = 1;
                    right = 0;
                } else if (left < 0) {
                    left = 0;
                } else if (right < 0) {
                    right = 0;
                }
                if (left > 255 and right > 255) {
                    left = 255;
                    right = 254;
                } else if (left > 255) {
                    left = 255;
                } else if (right > 255) {
                    right = 255;
                }
            } else {
                left = 1;
                right = 0;
            }
            self.wb(0x800 + j, @truncate(@as(u32, @bitCast(left))));
            self.wb(0x900 + j, @truncate(@as(u32, @bitCast(right))));
            y +%= 1;
        }
    }

    fn cmdSquare(self: *Cx4) void { // $54
        var a: i64 = self.r3(0x1F80);
        if ((a >> 23) & 1 != 0) a |= @bitCast(@as(u64, 0xFFFFFFFFFF000000));
        a *%= a;
        self.w3(0x1F83, @truncate(@as(u64, @bitCast(a))));
        self.w3(0x1F86, @truncate(@as(u64, @bitCast(a >> 24))));
    }

    fn cmdTransformCoords(self: *Cx4) void { // $2D
        var wf = Wf{
            .x = @bitCast(self.rw(0x1F81)),
            .y = @bitCast(self.rw(0x1F84)),
            .z = @bitCast(self.rw(0x1F87)),
            .x2 = self.ram[0x1F89],
            .y2 = self.ram[0x1F8A],
            .dist = self.ram[0x1F8B],
            .scale = @bitCast(self.rw(0x1F90)),
        };
        transfWireFrame2(&wf);
        self.ww(0x1F80, @bitCast(wf.x));
        self.ww(0x1F83, @bitCast(wf.y));
    }

    // --- wireframe transforms ---------------------------------------------

    fn transfWireFrame(wf: *Wf) void {
        var c4x: f64 = @floatFromInt(wf.x);
        var c4y: f64 = @floatFromInt(wf.y);
        var c4z: f64 = @as(f64, @floatFromInt(wf.z)) - 0x95;

        var t = -@as(f64, @floatFromInt(wf.x2)) * std.math.pi * 2 / 128;
        const c4y2 = c4y * @cos(t) - c4z * @sin(t);
        var c4z2 = c4y * @sin(t) + c4z * @cos(t);

        t = -@as(f64, @floatFromInt(wf.y2)) * std.math.pi * 2 / 128;
        const c4x2 = c4x * @cos(t) + c4z2 * @sin(t);
        c4z = c4x * -@sin(t) + c4z2 * @cos(t);

        t = -@as(f64, @floatFromInt(wf.dist)) * std.math.pi * 2 / 128;
        c4x = c4x2 * @cos(t) - c4y2 * @sin(t);
        c4y = c4x2 * @sin(t) + c4y2 * @cos(t);
        _ = &c4z2;

        const s: f64 = @floatFromInt(wf.scale);
        wf.x = d2i16(c4x * s / (0x90 * (c4z + 0x95)) * 0x95);
        wf.y = d2i16(c4y * s / (0x90 * (c4z + 0x95)) * 0x95);
    }

    fn transfWireFrame2(wf: *Wf) void {
        var c4x: f64 = @floatFromInt(wf.x);
        var c4y: f64 = @floatFromInt(wf.y);
        var c4z: f64 = @floatFromInt(wf.z);

        var t = -@as(f64, @floatFromInt(wf.x2)) * std.math.pi * 2 / 128;
        const c4y2 = c4y * @cos(t) - c4z * @sin(t);
        const c4z2 = c4y * @sin(t) + c4z * @cos(t);

        t = -@as(f64, @floatFromInt(wf.y2)) * std.math.pi * 2 / 128;
        const c4x2 = c4x * @cos(t) + c4z2 * @sin(t);
        c4z = c4x * -@sin(t) + c4z2 * @cos(t);

        t = -@as(f64, @floatFromInt(wf.dist)) * std.math.pi * 2 / 128;
        c4x = c4x2 * @cos(t) - c4y2 * @sin(t);
        c4y = c4x2 * @sin(t) + c4y2 * @cos(t);

        const s: f64 = @floatFromInt(wf.scale);
        wf.x = d2i16(c4x * s / 0x100);
        wf.y = d2i16(c4y * s / 0x100);
    }

    fn calcWireFrame(wf: *Wf) void {
        wf.x = wf.x2 -% wf.x;
        wf.y = wf.y2 -% wf.y;
        const ax: i32 = @intCast(@abs(@as(i32, wf.x)));
        const ay: i32 = @intCast(@abs(@as(i32, wf.y)));
        if (ax > ay) {
            wf.dist = tr16(ax + 1);
            wf.y = tr16(@divTrunc(256 * @as(i32, wf.y), ax));
            wf.x = if (wf.x < 0) -256 else 256;
        } else if (wf.y != 0) {
            wf.dist = tr16(ay + 1);
            wf.x = tr16(@divTrunc(256 * @as(i32, wf.x), ay));
            wf.y = if (wf.y < 0) -256 else 256;
        } else {
            wf.dist = 0;
        }
    }

    // --- graphics routines ------------------------------------------------

    /// $00/$08: transform a list of 3D line endpoints and rasterize them.
    fn drawWireFrame(self: *Cx4) void {
        const line_bank: u32 = self.ram[0x1F82];
        var line = romOff(self.r3(0x1F80));
        const count = self.ram[0x0295];
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            var p1addr: u32 = undefined;
            if (self.romb(line) == 0xFF and self.romb(line + 1) == 0xFF) {
                var tmp = line -% 5;
                while (self.romb(tmp + 2) == 0xFF and self.romb(tmp + 3) == 0xFF) tmp -%= 5;
                p1addr = (line_bank << 16) | (@as(u32, self.romb(tmp + 2)) << 8) | self.romb(tmp + 3);
            } else {
                p1addr = (line_bank << 16) | (@as(u32, self.romb(line)) << 8) | self.romb(line + 1);
            }
            const p2addr = (line_bank << 16) | (@as(u32, self.romb(line + 2)) << 8) | self.romb(line + 3);
            const p1 = romOff(p1addr);
            const p2 = romOff(p2addr);

            const x1: i16 = @bitCast((@as(u16, self.romb(p1)) << 8) | self.romb(p1 + 1));
            const y1: i16 = @bitCast((@as(u16, self.romb(p1 + 2)) << 8) | self.romb(p1 + 3));
            const z1: i16 = @bitCast((@as(u16, self.romb(p1 + 4)) << 8) | self.romb(p1 + 5));
            const x2: i16 = @bitCast((@as(u16, self.romb(p2)) << 8) | self.romb(p2 + 1));
            const y2: i16 = @bitCast((@as(u16, self.romb(p2 + 2)) << 8) | self.romb(p2 + 3));
            const z2: i16 = @bitCast((@as(u16, self.romb(p2 + 4)) << 8) | self.romb(p2 + 5));
            self.drawLine(x1, y1, z1, x2, y2, z2, self.romb(line + 4));
            line +%= 5;
        }
    }

    fn drawLine(self: *Cx4, x1i: i16, y1i: i16, z1: i16, x2i: i16, y2i: i16, z2: i16, color: u8) void {
        var wf = Wf{
            .x = x1i,
            .y = y1i,
            .z = z1,
            .scale = self.ram[0x1F90],
            .x2 = self.ram[0x1F86],
            .y2 = self.ram[0x1F87],
            .dist = self.ram[0x1F88],
        };
        transfWireFrame2(&wf);
        var x1: i32 = (@as(i32, wf.x) + 48) << 8;
        var y1: i32 = (@as(i32, wf.y) + 48) << 8;

        wf.x = x2i;
        wf.y = y2i;
        wf.z = z2;
        transfWireFrame2(&wf);
        const x2p: i32 = (@as(i32, wf.x) + 48) << 8;
        const y2p: i32 = (@as(i32, wf.y) + 48) << 8;

        wf.x = tr16(x1 >> 8);
        wf.y = tr16(y1 >> 8);
        wf.x2 = tr16(x2p >> 8);
        wf.y2 = tr16(y2p >> 8);
        calcWireFrame(&wf);
        const dx: i32 = wf.x;
        const dy: i32 = wf.y;

        var n: i32 = if (wf.dist != 0) wf.dist else 1;
        while (n > 0) : (n -= 1) {
            if (x1 > 0xFF and y1 > 0xFF and x1 < 0x6000 and y1 < 0x6000) {
                const yv: u32 = @intCast(y1 >> 8);
                const xv: u32 = @intCast(x1 >> 8);
                const addr: u16 = @truncate(((yv >> 3) << 8) - ((yv >> 3) << 6) +
                    ((xv >> 3) << 4) + (yv & 7) * 2);
                const bit = @as(u8, 0x80) >> @intCast(xv & 7);
                self.ram[(addr + 0x300) & 0x1FFF] &= ~bit;
                self.ram[(addr + 0x301) & 0x1FFF] &= ~bit;
                if (color & 1 != 0) self.ram[(addr + 0x300) & 0x1FFF] |= bit;
                if (color & 2 != 0) self.ram[(addr + 0x301) & 0x1FFF] |= bit;
            }
            x1 += dx;
            y1 += dy;
        }
    }

    /// $05: transform vertices and build the line table for the wireframe.
    fn transformLines(self: *Cx4) void {
        const x2v = self.ram[0x1F83];
        const y2v = self.ram[0x1F86];
        const distv = self.ram[0x1F89];
        const scalev = self.ram[0x1F8C];

        var ptr: u32 = 0;
        var i: i32 = @bitCast(@as(u32, self.rw(0x1F80)));
        while (i > 0) : (i -= 1) {
            var wf = Wf{
                .x = @bitCast(self.rw(ptr + 1)),
                .y = @bitCast(self.rw(ptr + 5)),
                .z = @bitCast(self.rw(ptr + 9)),
                .x2 = x2v,
                .y2 = y2v,
                .dist = distv,
                .scale = scalev,
            };
            transfWireFrame(&wf);
            self.ww(ptr + 1, @bitCast(wf.x +% 0x80));
            self.ww(ptr + 5, @bitCast(wf.y +% 0x50));
            ptr += 0x10;
        }

        self.ww(0x600, 23);
        self.ww(0x602, 0x60);
        self.ww(0x605, 0x40);
        self.ww(0x608, 23);
        self.ww(0x60A, 0x60);
        self.ww(0x60D, 0x40);

        ptr = 0xB02;
        var ptr2: u32 = 0;
        i = @bitCast(@as(u32, self.rw(0xB00)));
        while (i > 0) : (i -= 1) {
            var wf = Wf{
                .x = @bitCast(self.rw((@as(u32, self.rb(ptr)) << 4) + 1)),
                .y = @bitCast(self.rw((@as(u32, self.rb(ptr)) << 4) + 5)),
                .x2 = @bitCast(self.rw((@as(u32, self.rb(ptr + 1)) << 4) + 1)),
                .y2 = @bitCast(self.rw((@as(u32, self.rb(ptr + 1)) << 4) + 5)),
            };
            calcWireFrame(&wf);
            self.ww(ptr2 + 0x600, @bitCast(if (wf.dist != 0) wf.dist else @as(i16, 1)));
            self.ww(ptr2 + 0x602, @bitCast(wf.x));
            self.ww(ptr2 + 0x605, @bitCast(wf.y));
            ptr += 2;
            ptr2 += 8;
        }
    }

    /// $03/$07: affine scale/rotate of the 4bpp source tile into RAM.
    fn doScaleRotate(self: *Cx4, row_padding: i32) void {
        var xs: i32 = self.rw(0x1F8F);
        if (xs & 0x8000 != 0) xs = 0x7FFF;
        var ys: i32 = self.rw(0x1F92);
        if (ys & 0x8000 != 0) ys = 0x7FFF;

        var a: i16 = undefined;
        var b: i16 = undefined;
        var c: i16 = undefined;
        var d: i16 = undefined;
        const angle = self.rw(0x1F80);
        switch (angle) {
            0 => {
                a = @intCast(xs);
                b = 0;
                c = 0;
                d = @intCast(ys);
            },
            128 => {
                a = 0;
                b = tr16(-ys);
                c = @intCast(xs);
                d = 0;
            },
            256 => {
                a = tr16(-xs);
                b = 0;
                c = 0;
                d = tr16(-ys);
            },
            384 => {
                a = 0;
                b = @intCast(ys);
                c = tr16(-xs);
                d = 0;
            },
            else => {
                const ai = angle & 0x1FF;
                a = tr16((@as(i32, cos_table[ai]) * xs) >> 15);
                b = tr16(-((@as(i32, sin_table[ai]) * ys) >> 15));
                c = tr16((@as(i32, sin_table[ai]) * xs) >> 15);
                d = tr16((@as(i32, cos_table[ai]) * ys) >> 15);
            },
        }

        const w: i32 = self.ram[0x1F89] & ~@as(u8, 7);
        const h: i32 = self.ram[0x1F8C] & ~@as(u8, 7);
        const clear: usize = @intCast(@divTrunc((w + @divTrunc(row_padding, 4)) * h, 2));
        @memset(self.ram[0..@min(clear, self.ram.len)], 0); // clamp: games stay in range

        const cx: i32 = @as(i16, @bitCast(self.rw(0x1F83)));
        const cy: i32 = @as(i16, @bitCast(self.rw(0x1F86)));
        var line_x: i32 = (cx << 12) - cx * a - cx * b;
        var line_y: i32 = (cy << 12) - cy * c - cy * d;

        var outidx: i32 = 0;
        var bit: u8 = 0x80;
        var yy: i32 = 0;
        while (yy < h) : (yy += 1) {
            var xg: i32 = line_x;
            var yg: i32 = line_y;
            var xx: i32 = 0;
            while (xx < w) : (xx += 1) {
                var byte: u8 = 0;
                if ((xg >> 12) < w and (yg >> 12) < h and (xg >> 12) >= 0 and (yg >> 12) >= 0) {
                    const addr: u32 = @intCast((yg >> 12) * w + (xg >> 12));
                    byte = self.rb(0x600 + (addr >> 1));
                    if (addr & 1 != 0) byte >>= 4;
                }
                const o: u32 = @intCast(outidx);
                if (byte & 1 != 0) self.ram[o & 0x1FFF] |= bit;
                if (byte & 2 != 0) self.ram[(o + 1) & 0x1FFF] |= bit;
                if (byte & 4 != 0) self.ram[(o + 16) & 0x1FFF] |= bit;
                if (byte & 8 != 0) self.ram[(o + 17) & 0x1FFF] |= bit;
                bit >>= 1;
                if (bit == 0) {
                    bit = 0x80;
                    outidx += 32;
                }
                xg += a;
                yg += c;
            }
            outidx += 2 + row_padding;
            if (outidx & 0x10 != 0) outidx &= ~@as(i32, 0x10) else outidx -= w * 4 + row_padding;
            line_x += b;
            line_y += d;
        }
    }

    /// $00 mode $00: build the sprite OAM table from the game's sprite list.
    fn convOam(self: *Cx4) void {
        var oamptr: u32 = @as(u32, self.ram[0x626]) << 2;
        {
            var i: i32 = 0x1FD;
            while (i > @as(i32, @intCast(oamptr))) : (i -= 4)
                self.ram[@as(u32, @intCast(i)) & 0x1FFF] = 0xE0;
        }

        const global_x = self.rw(0x621);
        const global_y = self.rw(0x623);
        var oamptr2: u32 = 0x200 + (@as(u32, self.ram[0x626]) >> 2);

        if (self.ram[0x620] == 0) return;

        var spr_count: i32 = 128 - @as(i32, self.ram[0x626]);
        var offset: u3 = @intCast((self.ram[0x626] & 3) * 2);
        var srcptr: u32 = 0x220;

        var i: i32 = self.ram[0x620];
        while (i > 0 and spr_count > 0) : ({
            i -= 1;
            srcptr += 16;
        }) {
            const spr_x: i16 = @bitCast(self.rw(srcptr) -% global_x);
            const spr_y: i16 = @bitCast(self.rw(srcptr + 2) -% global_y);
            const spr_name = self.rb(srcptr + 5);
            const spr_attr = self.rb(srcptr + 4) | self.rb(srcptr + 6);

            const sprbase = romOff(self.r3(srcptr + 7));
            if (self.romb(sprbase) != 0) {
                var sprptr = sprbase + 1;
                var cnt: i32 = self.romb(sprbase);
                while (cnt > 0 and spr_count > 0) : ({
                    cnt -= 1;
                    sprptr += 4;
                }) {
                    var x: i16 = @as(i8, @bitCast(self.romb(sprptr + 1)));
                    if (spr_attr & 0x40 != 0)
                        x = -x - (if (self.romb(sprptr) & 0x20 != 0) @as(i16, 16) else 8);
                    x +%= spr_x;
                    if (x >= -16 and x <= 272) {
                        var y: i16 = @as(i8, @bitCast(self.romb(sprptr + 2)));
                        if (spr_attr & 0x80 != 0)
                            y = -y - (if (self.romb(sprptr) & 0x20 != 0) @as(i16, 16) else 8);
                        y +%= spr_y;
                        if (y >= -16 and y <= 224) {
                            self.wb(oamptr, @truncate(@as(u16, @bitCast(x))));
                            self.wb(oamptr + 1, @truncate(@as(u16, @bitCast(y))));
                            self.wb(oamptr + 2, spr_name +% self.romb(sprptr + 3));
                            self.wb(oamptr + 3, spr_attr ^ (self.romb(sprptr) & 0xC0));
                            self.ram[oamptr2 & 0x1FFF] &= ~(@as(u8, 3) << offset);
                            if (x & 0x100 != 0) self.ram[oamptr2 & 0x1FFF] |= @as(u8, 1) << offset;
                            if (self.romb(sprptr) & 0x20 != 0) self.ram[oamptr2 & 0x1FFF] |= @as(u8, 2) << offset;
                            oamptr += 4;
                            spr_count -= 1;
                            offset = @intCast((@as(u8, offset) + 2) & 6);
                            if (offset == 0) oamptr2 += 1;
                        }
                    }
                }
            } else if (spr_count > 0) {
                self.wb(oamptr, @truncate(@as(u16, @bitCast(spr_x))));
                self.wb(oamptr + 1, @truncate(@as(u16, @bitCast(spr_y))));
                self.wb(oamptr + 2, spr_name);
                self.wb(oamptr + 3, spr_attr);
                self.ram[oamptr2 & 0x1FFF] &= ~(@as(u8, 3) << offset);
                if (spr_x & 0x100 != 0)
                    self.ram[oamptr2 & 0x1FFF] |= @as(u8, 3) << offset
                else
                    self.ram[oamptr2 & 0x1FFF] |= @as(u8, 2) << offset;
                oamptr += 4;
                spr_count -= 1;
                offset = @intCast((@as(u8, offset) + 2) & 6);
                if (offset == 0) oamptr2 += 1;
            }
        }
    }

    /// $0C: the bitplane "wave" effect (Mega Man X2 intro water).
    fn bitPlaneWave(self: *Cx4) void {
        const bmpdata = [40]u16{
            0x0000, 0x0002, 0x0004, 0x0006, 0x0008, 0x000A, 0x000C, 0x000E,
            0x0200, 0x0202, 0x0204, 0x0206, 0x0208, 0x020A, 0x020C, 0x020E,
            0x0400, 0x0402, 0x0404, 0x0406, 0x0408, 0x040A, 0x040C, 0x040E,
            0x0600, 0x0602, 0x0604, 0x0606, 0x0608, 0x060A, 0x060C, 0x060E,
            0x0800, 0x0802, 0x0804, 0x0806, 0x0808, 0x080A, 0x080C, 0x080E,
        };
        var dst: u32 = 0;
        var waveptr: u32 = self.ram[0x1F83];
        var mask1: u16 = 0xC0C0;
        var mask2: u16 = 0x3F3F;

        var j: u32 = 0;
        while (j < 0x10) : (j += 1) {
            inline for (.{ @as(u32, 0xA00), @as(u32, 0xA10) }) |wave_base| {
                while (true) {
                    var height: i16 = -@as(i16, @as(i8, @bitCast(self.rb(waveptr + 0xB00)))) - 16;
                    for (bmpdata) |bd| {
                        var tmp = self.rw(dst + bd) & mask2;
                        if (height >= 0) {
                            if (height < 8)
                                tmp |= mask1 & self.rw(wave_base + @as(u32, @intCast(height)) * 2)
                            else
                                tmp |= mask1 & 0xFF00;
                        }
                        self.ww(dst + bd, tmp);
                        height += 1;
                    }
                    waveptr = (waveptr + 1) & 0x7F;
                    mask1 = (mask1 >> 2) | (mask1 << 6);
                    mask2 = (mask2 >> 2) | (mask2 << 6);
                    if (mask1 == 0xC0C0) break;
                }
                dst += 16;
            }
        }
    }

    /// $0B: the sprite "disintegrate" scatter effect.
    fn sprDisintegrate(self: *Cx4) void {
        const width: u32 = self.ram[0x1F89];
        const height: u32 = self.ram[0x1F8C];
        const cx: i32 = @as(i16, @bitCast(self.rw(0x1F80)));
        const cy: i32 = @as(i16, @bitCast(self.rw(0x1F83)));
        const scale_x: i32 = @as(i16, @bitCast(self.rw(0x1F86)));
        const scale_y: i32 = @as(i16, @bitCast(self.rw(0x1F8F)));
        var start_x: i32 = -cx * scale_x + (cx << 8);
        var start_y: i32 = -cy * scale_y + (cy << 8);

        var src: u32 = 0x600;
        @memset(self.ram[0..@min(width * height / 2, self.ram.len)], 0); // clamp

        var iy: u32 = 0;
        var yv: i32 = start_y;
        while (iy < height) : ({
            iy += 1;
            yv += scale_y;
        }) {
            var xv: i32 = start_x;
            var jx: u32 = 0;
            while (jx < width) : ({
                jx += 1;
                xv += scale_x;
            }) {
                const sx: u32 = @bitCast(xv >> 8);
                const sy: u32 = @bitCast(yv >> 8);
                if (xv >= 0 and yv >= 0 and sx < width and sy < height and sy * width + sx < 0x2000) {
                    const pixel = if (jx & 1 != 0) self.rb(src) >> 4 else self.rb(src);
                    const idx: u32 = @intCast((yv >> 11) * @as(i32, @intCast(width)) * 4 +
                        (xv >> 11) * 32 + ((yv >> 8) & 7) * 2);
                    const mask = @as(u8, 0x80) >> @intCast(sx & 7);
                    if (pixel & 1 != 0) self.ram[idx & 0x1FFF] |= mask;
                    if (pixel & 2 != 0) self.ram[(idx + 1) & 0x1FFF] |= mask;
                    if (pixel & 4 != 0) self.ram[(idx + 16) & 0x1FFF] |= mask;
                    if (pixel & 8 != 0) self.ram[(idx + 17) & 0x1FFF] |= mask;
                }
                if (jx & 1 != 0) src += 1;
            }
        }
        _ = &start_x;
        _ = &start_y;
    }

    /// $00: dispatch a sprite command by the mode register at $1F4D.
    fn processSprites(self: *Cx4) void {
        switch (self.ram[0x1F4D]) {
            0x00 => self.convOam(),
            0x03 => self.doScaleRotate(0),
            0x05 => self.transformLines(),
            0x07 => self.doScaleRotate(64),
            0x08 => self.drawWireFrame(),
            0x0B => self.sprDisintegrate(),
            0x0C => self.bitPlaneWave(),
            else => {},
        }
    }
};

inline fn signExt24(v: u32) u32 {
    return if (v & 0x800000 != 0) 0xFF000000 else 0;
}

// --- tests ----------------------------------------------------------------

const testing = std.testing;

const TestChip = struct {
    rom: [0x20000]u8,
    cx4: Cx4,

    fn create() !*TestChip {
        const tc = try testing.allocator.create(TestChip);
        @memset(&tc.rom, 0);
        tc.cx4.init();
        tc.cx4.attach(&tc.rom, tc.rom.len - 1);
        return tc;
    }
    fn destroy(self: *TestChip) void {
        testing.allocator.destroy(self);
    }
    /// Set a register word (little-endian) at $7Fxx = ram offset $1Fxx.
    fn setw(self: *TestChip, off: u16, v: u16) void {
        self.cx4.ww(off, v);
    }
    fn getw(self: *TestChip, off: u16) u16 {
        return self.cx4.rw(off);
    }
    fn run(self: *TestChip, cmd: u8) void {
        self.cx4.write(0x7F4F, cmd);
    }
};

test "cx4 multiply ($25) does signed 24-bit product" {
    const tc = try TestChip.create();
    defer tc.destroy();
    tc.cx4.w3(0x1F80, 0x000010);
    tc.cx4.w3(0x1F83, 0x000020);
    tc.run(0x25);
    try testing.expectEqual(@as(u32, 0x200), tc.cx4.r3(0x1F80));

    tc.cx4.w3(0x1F80, 0xFFFFFF); // -1
    tc.cx4.w3(0x1F83, 0x000005);
    tc.run(0x25);
    try testing.expectEqual(@as(u32, 0xFFFFFB), tc.cx4.r3(0x1F80)); // -5
}

test "cx4 square ($54) sign-extends 24-bit and writes 48-bit result" {
    const tc = try TestChip.create();
    defer tc.destroy();
    tc.cx4.w3(0x1F80, 0x000100);
    tc.run(0x54);
    // 0x100^2 = 0x10000; low 24 at $1f83, high 24 at $1f86
    try testing.expectEqual(@as(u32, 0x010000), tc.cx4.r3(0x1F83));
    try testing.expectEqual(@as(u32, 0x000000), tc.cx4.r3(0x1F86));

    tc.cx4.w3(0x1F80, 0xFFFFFF); // -1
    tc.run(0x54);
    try testing.expectEqual(@as(u32, 0x000001), tc.cx4.r3(0x1F83));
    try testing.expectEqual(@as(u32, 0x000000), tc.cx4.r3(0x1F86));
}

test "cx4 pythagoras ($15) and atan ($1f)" {
    const tc = try TestChip.create();
    defer tc.destroy();
    tc.setw(0x1F80, 3);
    tc.setw(0x1F83, 4);
    tc.run(0x15);
    try testing.expectEqual(@as(u16, 5), tc.getw(0x1F80));

    // atan2(y=+, x=0) -> 0x80 (quarter turn in 512-unit angle)
    tc.setw(0x1F80, 0); // x
    tc.setw(0x1F83, 100); // y
    tc.run(0x1F);
    try testing.expectEqual(@as(u16, 0x80), tc.getw(0x1F86));
    // x<0 adds 0x100
    tc.setw(0x1F80, 0);
    tc.setw(0x1F83, @bitCast(@as(i16, -100)));
    tc.run(0x1F);
    try testing.expectEqual(@as(u16, 0x180), tc.getw(0x1F86));
}

test "cx4 atan ($1f) at 45 degrees, polar+bias ($10), transform coords ($2d)" {
    const tc = try TestChip.create();
    defer tc.destroy();
    // atan2(100,100) = 45° = 64 in 512-unit angle (values minted from the
    // reference algorithm with the formula-generated tables).
    tc.setw(0x1F80, 100);
    tc.setw(0x1F83, 100);
    tc.run(0x1F);
    try testing.expectEqual(@as(u16, 0x40), tc.getw(0x1F86));

    // $10 polar→rect with the radius clamp and the y bias (tmp − tmp>>6).
    tc.setw(0x1F80, 64); // angle
    tc.setw(0x1F83, 1000); // radius
    tc.run(0x10);
    try testing.expectEqual(@as(u32, 0x2C3), tc.cx4.r3(0x1F86));
    try testing.expectEqual(@as(u32, 0x2B8), tc.cx4.r3(0x1F89));

    // $2D coordinate transform through the double-precision rotator.
    tc.setw(0x1F81, 100);
    tc.setw(0x1F84, 50);
    tc.setw(0x1F87, 20);
    tc.cx4.ram[0x1F89] = 10;
    tc.cx4.ram[0x1F8A] = 20;
    tc.cx4.ram[0x1F8B] = 30;
    tc.setw(0x1F90, 256);
    tc.run(0x2D);
    try testing.expectEqual(@as(u16, 0x3B), tc.getw(0x1F80));
    try testing.expectEqual(@as(u16, 0xFFCA), tc.getw(0x1F83));
}

test "cx4 sum ($40) adds the first 0x800 RAM bytes" {
    const tc = try TestChip.create();
    defer tc.destroy();
    tc.cx4.ram[0x10] = 0xFF;
    tc.cx4.ram[0x20] = 0x02;
    tc.cx4.ram[0x1F4D] = 0x0E; // sum expects mode $0e
    tc.run(0x40);
    try testing.expectEqual(@as(u16, 0x101), tc.getw(0x1F80));
}

test "cx4 immediate signature ($89) and test pattern ($5c)" {
    const tc = try TestChip.create();
    defer tc.destroy();
    tc.cx4.ram[0x1F4D] = 0x0E;
    tc.run(0x89);
    try testing.expectEqual(@as(u8, 0x36), tc.cx4.ram[0x1F80]);
    try testing.expectEqual(@as(u8, 0x43), tc.cx4.ram[0x1F81]);
    try testing.expectEqual(@as(u8, 0x05), tc.cx4.ram[0x1F82]);

    tc.run(0x5C);
    try testing.expectEqual(@as(u8, 0xFF), tc.cx4.ram[3]);
    try testing.expectEqual(@as(u8, 0x80), tc.cx4.ram[20]);
}

test "cx4 polar->rect ($13) uses the sine/cosine tables" {
    const tc = try TestChip.create();
    defer tc.destroy();
    // angle 0: cos=32767, sin=0 -> x = r*32767*2>>8, y=0
    tc.setw(0x1F80, 0); // angle
    tc.setw(0x1F83, 1); // radius
    tc.run(0x13);
    // (1 * 32767 * 2) >> 8 = 255
    try testing.expectEqual(@as(u32, 255), tc.cx4.r3(0x1F86));
    try testing.expectEqual(@as(u32, 0), tc.cx4.r3(0x1F89));

    // angle 128 (quarter): cos=0, sin=32767
    tc.setw(0x1F80, 128);
    tc.setw(0x1F83, 1);
    tc.run(0x13);
    try testing.expectEqual(@as(u32, 0), tc.cx4.r3(0x1F86));
    try testing.expectEqual(@as(u32, 255), tc.cx4.r3(0x1F89));
}

test "cx4 test-command path stores quarter when mode is 0x0e" {
    const tc = try TestChip.create();
    defer tc.destroy();
    tc.cx4.ram[0x1F4D] = 0x0E;
    tc.cx4.write(0x7F4F, 0x0C); // <0x40, &3==0 -> stores 0x0c>>2 = 3
    try testing.expectEqual(@as(u8, 3), tc.cx4.ram[0x1F80]);
}

test "cx4 build-OAM ($00 mode $00) emits a sprite entry" {
    const tc = try TestChip.create();
    defer tc.destroy();
    tc.cx4.ram[0x1F4D] = 0x00; // Build OAM mode
    tc.cx4.ram[0x620] = 1; // one source sprite
    tc.cx4.ram[0x626] = 0; // OAM write starts at 0
    tc.setw(0x621, 0); // global X
    tc.setw(0x623, 0); // global Y
    // Source sprite at $220: X=50, Y=60, name=$42, attr=0.
    tc.setw(0x220, 50);
    tc.setw(0x222, 60);
    tc.cx4.ram[0x225] = 0x42; // name
    tc.cx4.ram[0x224] = 0x00; // attr low
    tc.cx4.ram[0x226] = 0x00; // attr high
    tc.cx4.w3(0x227, 0x008000); // shape pointer → ROM offset 0 (count byte 0)
    tc.run(0x00);
    // ROM shape count is 0, so the single-sprite path copies X/Y/name/attr.
    try testing.expectEqual(@as(u8, 50), tc.cx4.ram[0]);
    try testing.expectEqual(@as(u8, 60), tc.cx4.ram[1]);
    try testing.expectEqual(@as(u8, 0x42), tc.cx4.ram[2]);
    try testing.expectEqual(@as(u8, 0x00), tc.cx4.ram[3]);
}

test "cx4 memory load ($7f47) copies ROM into RAM" {
    const tc = try TestChip.create();
    defer tc.destroy();
    // LoROM addr $008000 -> rom offset 0. Put a known blob there.
    for (0..8) |k| tc.rom[k] = @intCast(0xA0 + k);
    tc.cx4.w3(0x1F40, 0x008000); // source
    tc.setw(0x1F43, 8); // length
    tc.setw(0x1F45, 0x6100); // dest (window $6100 -> ram $0100)
    tc.cx4.write(0x7F47, 0x00);
    for (0..8) |k| try testing.expectEqual(@as(u8, @intCast(0xA0 + k)), tc.cx4.ram[0x100 + k]);
}

test "cx4 status byte and RAM window read back" {
    const tc = try TestChip.create();
    defer tc.destroy();
    tc.cx4.ram[0x0000] = 0x11;
    tc.cx4.ram[0x1F5E] = 0x22;
    try testing.expectEqual(@as(u8, 0x11), tc.cx4.read(0x6000));
    try testing.expectEqual(@as(u8, 0x00), tc.cx4.read(0x7F5E)); // status always 0
}

test "cx4 serialize roundtrip preserves RAM" {
    const serialize = @import("../serialize.zig");
    const tc = try TestChip.create();
    defer tc.destroy();
    tc.cx4.ram[0x123] = 0x7E;
    tc.cx4.ram[0x1F80] = 0x9A;

    const size = comptime serialize.byteSize(Cx4);
    const buf = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(buf);
    _ = serialize.write(Cx4, &tc.cx4, buf);

    const other = try TestChip.create();
    defer other.destroy();
    _ = try serialize.read(Cx4, &other.cx4, buf);
    other.cx4.attach(&other.rom, other.rom.len - 1);
    try testing.expectEqual(@as(u8, 0x7E), other.cx4.ram[0x123]);
    try testing.expectEqual(@as(u8, 0x9A), other.cx4.ram[0x1F80]);
}
