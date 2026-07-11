//! DSP-1: the NEC µPD7725 fixed-point math coprocessor (Super Mario Kart,
//! Pilotwings, ...), emulated at the command level (HLE).
//!
//! The SNES talks to the chip through two byte-wide ports: DR (data) streams
//! a command byte followed by little-endian 16-bit parameters and reads back
//! 16-bit results, and SR (status) reports readiness. Commands are the
//! documented fixed-point routines: 16-bit multiplies, 1/x with a table seed
//! plus two Newton steps, sin/cos with linear interpolation, 2D/3D rotations,
//! attitude matrices, and the mode 7 ground-plane projection family
//! (parameter → per-scanline raster → project/target). Register-level
//! behavior — coefficient/exponent normalization, table lookups, truncation
//! quirks, wrap-around — follows the µPD7725 program as documented by the
//! DSP-1 reverse-engineering techdoc and mirrored in the classic emulator
//! HLE implementations; the Zig here is written from that behavior, not
//! from the chip's microcode.
//!
//! The data ROM contents used by the algorithms are pure math and are
//! regenerated at comptime from closed forms (verified entry-for-entry
//! against the documented tables): powers of two for the exponent shifts,
//! reciprocal seeds round(2^29 / d), and sine trunc(32768·sin(2πi/256)).
//! Only the 49-entry square-root segment and a handful of polynomial
//! constants are carried as literals — their generator's rounding is
//! irregular (entries sit 0.7-1.9 below 4096·√i) — with derivations noted.
//!
//! HLE simplifications, documented on purpose:
//!  - Commands complete instantly; SR always reports ready (RQM set). Games
//!    poll SR or just trust the chip's speed, so no game notices.
//!  - The ROM-dump command ($1F) streams the synthesized data ROM: regions
//!    the algorithms never reference read back as zero.
//!  - DSP-2/3/4 carts (a handful of titles) carry different µPD7725 programs
//!    and are not implemented; their commands fall through as no-ops.

const std = @import("std");

// --- data ROM (comptime-generated where a closed form exists) -------------

/// Square-root segment rom[$E5..$115]: entry i-16 ≈ 4096·√i for i in 16..64
/// (so ≈ 32768·√(i/64), interpolated by the distance command). The chip's
/// generator rounds irregularly — exact squares land at 4096·√i − 1, other
/// entries 0.7-1.9 below exact — so the documented values are carried
/// verbatim rather than regenerated.
const sqrt_segment = [49]u16{
    0x3fff, 0x41f7, 0x43e1, 0x45bd, 0x478d, 0x4951, 0x4b0b, 0x4cbb,
    0x4e61, 0x4fff, 0x5194, 0x5322, 0x54a9, 0x5628, 0x57a2, 0x5914,
    0x5a81, 0x5be9, 0x5d4a, 0x5ea7, 0x5fff, 0x6152, 0x62a0, 0x63ea,
    0x6530, 0x6672, 0x67b0, 0x68ea, 0x6a20, 0x6b53, 0x6c83, 0x6daf,
    0x6ed9, 0x6fff, 0x7122, 0x7242, 0x735f, 0x747a, 0x7592, 0x76a7,
    0x77ba, 0x78cb, 0x79d9, 0x7ae5, 0x7bee, 0x7cf5, 0x7dfa, 0x7efe,
    0x7fff,
};

/// Zenith-clip polynomial constants rom[$324..$328] (the $326 slot is unused
/// by the algorithms). $327 = round(π·2^13) and $328 = round(π³/6 · 2^10)
/// (the sine series x³ coefficient); $324/$325 are the chip's minimax
/// correction pair with no recognized closed form.
const k_clip_sq = 0x0a26; // rom[$324]
const k_clip_lin = 0x277a; // rom[$325]
const k_pi_3_13 = 0x6488; // rom[$327] = round(π·2^13), also the sin interpolation step
const k_pi3_6 = 0x14ac; // rom[$328] = round(π³/6 · 2^10)

/// Maximum zenith angle per view-plane exponent, used by the parameter
/// command to clip the camera before the projection math degenerates
/// (documented microcode constants ≈ 79.8°..79.9° in 16-bit angle units).
const max_azs_exp = [16]i16{
    0x38b4, 0x38b7, 0x38ba, 0x38be, 0x38c0, 0x38c4, 0x38c7, 0x38ca,
    0x38ce, 0x38d0, 0x38d4, 0x38d7, 0x38da, 0x38dd, 0x38e0, 0x38e4,
};

/// The µPD7725 data ROM as the HLE algorithms see it. Layout (word indices):
///   $22+k  = 1<<k (k = 0..14), $31 = $7fff       — normalize/denormalize
///   $32+j  = $4000>>j, with the chip's one-word bug: [$3C] = 1 (not $10)
///   $65+i  = round(2^29 / ($4000 + 128·i))        — reciprocal seeds, i < 128
///   $E5..  = sqrt_segment                          — distance interpolation
///   $324.. = clip polynomial constants             — parameter command
/// Everything else is microcode-internal and reads back 0 (see module doc).
const data_rom = blk: {
    var rom: [1024]u16 = @splat(0);
    for (0..15) |k| rom[0x22 + k] = 1 << k;
    rom[0x31] = 0x7fff;
    for (0..15) |j| rom[0x32 + j] = @as(u16, 0x4000) >> j;
    rom[0x3c] = 0x0001; // hardware data-ROM bug, faithfully kept
    for (0..128) |i| {
        const d: u32 = 0x4000 + 128 * i;
        rom[0x65 + i] = @intCast(@min(0x7fff, ((1 << 29) + d / 2) / d));
    }
    for (sqrt_segment, 0..) |v, i| rom[0xE5 + i] = v;
    rom[0x324] = k_clip_sq;
    rom[0x325] = k_clip_lin;
    rom[0x327] = k_pi_3_13;
    rom[0x328] = k_pi3_6;
    break :blk rom;
};

/// Quarter-indexed sine table: trunc(32768·sin(2πi/256)) saturated to
/// ±32767 (entries 64 and 192 are the saturation points).
const sin_table = blk: {
    @setEvalBranchQuota(20000);
    var t: [256]i16 = undefined;
    for (&t, 0..) |*v, i| {
        const x = 32768.0 * @sin(2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / 256.0);
        v.* = @intFromFloat(std.math.clamp(@trunc(x), -32767.0, 32767.0));
    }
    break :blk t;
};

// --- fixed-point helpers ---------------------------------------------------

/// (a*b)>>15 in 32-bit like the chip's MAC, truncated to 16 bits on store.
inline fn mul15(a: i32, b: i32) i16 {
    return @truncate((a * b) >> 15);
}

/// Number of leading redundant sign/zero bits in a 15-bit scan (the chip's
/// normalize loop): 0 when bit 14 is significant, 15 for 0/-1.
fn scan15(m: i16) i16 {
    const n: u16 = @bitCast(if (m < 0) ~m else m);
    return if (n == 0) 15 else @as(i16, @clz(n)) - 1;
}

fn romFactor(index: i32) i32 {
    return if (index < 0 or index >= data_rom.len) 0 else data_rom[@intCast(index)];
}

pub const Dsp1 = struct {
    // Port state machine.
    command: u8,
    waiting_for_command: bool,
    first_parameter: bool,
    in_count: u16,
    in_index: u16,
    out_count: u16,
    out_index: u16,
    parameters: [16]u8,
    output: [16]u8,

    // Cross-command math state: the three attitude matrices and the
    // projection setup shared by parameter/raster/project/target.
    matrix_a: [3][3]i16,
    matrix_b: [3][3]i16,
    matrix_c: [3][3]i16,
    sin_aas: i16,
    cos_aas: i16,
    sin_azs: i16,
    cos_azs: i16,
    sin_azs_clip: i16,
    cos_azs_clip: i16,
    nx: i16,
    ny: i16,
    nz: i16,
    gx: i16,
    gy: i16,
    gz: i16,
    c_les: i16,
    e_les: i16,
    g_les: i16,
    centre_x: i16,
    centre_y: i16,
    v_offset: i16,
    vplane_c: i16,
    vplane_e: i16,
    sec_azs_c1: i16,
    sec_azs_e1: i16,
    sec_azs_c2: i16,
    sec_azs_e2: i16,
    /// Raster command scanline, auto-incremented per 8-byte read burst.
    raster_vs: i16,

    pub const init: Dsp1 = .{
        .command = 0,
        .waiting_for_command = true,
        .first_parameter = false,
        .in_count = 0,
        .in_index = 0,
        .out_count = 0,
        .out_index = 0,
        .parameters = @splat(0),
        .output = @splat(0),
        .matrix_a = @splat(@splat(0)),
        .matrix_b = @splat(@splat(0)),
        .matrix_c = @splat(@splat(0)),
        .sin_aas = 0,
        .cos_aas = 0,
        .sin_azs = 0,
        .cos_azs = 0,
        .sin_azs_clip = 0,
        .cos_azs_clip = 0,
        .nx = 0,
        .ny = 0,
        .nz = 0,
        .gx = 0,
        .gy = 0,
        .gz = 0,
        .c_les = 0,
        .e_les = 0,
        .g_les = 0,
        .centre_x = 0,
        .centre_y = 0,
        .v_offset = 0,
        .vplane_c = 0,
        .vplane_e = 0,
        .sec_azs_c1 = 0,
        .sec_azs_e1 = 0,
        .sec_azs_c2 = 0,
        .sec_azs_e2 = 0,
        .raster_vs = 0,
    };

    // --- scalar math (chip-exact fixed point) ------------------------------

    pub fn sin(angle: i16) i16 {
        if (angle < 0) {
            if (angle == -32768) return 0;
            return -%sin(-%angle);
        }
        const hi: usize = @intCast(angle >> 8);
        const frac: i32 = (@as(i32, angle & 0xff) * k_pi_3_13) >> 13;
        const s = @as(i32, sin_table[hi]) + ((frac * sin_table[0x40 + hi]) >> 15);
        return @intCast(@min(s, 32767));
    }

    pub fn cos(angle_in: i16) i16 {
        var angle = angle_in;
        if (angle < 0) {
            if (angle == -32768) return -32768;
            angle = -angle;
        }
        const hi: usize = @intCast(angle >> 8);
        const frac: i32 = (@as(i32, angle & 0xff) * k_pi_3_13) >> 13;
        const s = @as(i32, sin_table[0x40 + hi]) - ((frac * sin_table[hi]) >> 15);
        return @intCast(@max(s, -32767));
    }

    /// 1/x as coefficient·2^exponent: table seed plus two estimated Newton
    /// iterations, exactly as the microcode computes it.
    pub fn inverse(coeff_in: i16, exp_in: i16, icoeff: *i16, iexp: *i16) void {
        if (coeff_in == 0) {
            icoeff.* = 0x7fff;
            iexp.* = 0x002f;
            return;
        }
        var coeff: i32 = coeff_in;
        var exp = exp_in;
        var sign: i32 = 1;
        if (coeff < 0) {
            coeff = @max(coeff, -32767);
            coeff = -coeff;
            sign = -1;
        }
        while (coeff < 0x4000) {
            coeff <<= 1;
            exp -= 1;
        }
        if (coeff == 0x4000) {
            if (sign == 1) {
                icoeff.* = 0x7fff;
            } else {
                icoeff.* = -0x4000;
                exp -= 1;
            }
        } else {
            var i: i32 = data_rom[@intCast(((coeff - 0x4000) >> 7) + 0x65)];
            i = @as(i16, @truncate((i + ((-i * ((coeff * i) >> 15)) >> 15)) << 1));
            i = @as(i16, @truncate((i + ((-i * ((coeff * i) >> 15)) >> 15)) << 1));
            icoeff.* = @truncate(i * sign);
        }
        iexp.* = 1 - exp;
    }

    /// Shift a 16-bit value into coefficient·2^exponent form (exponent is
    /// *decremented* by the shift count, matching the chip's convention).
    fn normalize(m: i16, coeff: *i16, exp: *i16) void {
        const e = scan15(m);
        coeff.* = if (e > 0)
            @truncate((@as(i32, m) * romFactor(0x21 + e)) << 1)
        else
            m;
        exp.* -= e;
    }

    /// Normalize a 30-bit product; returns the shift count as the exponent.
    fn normalizeDouble(product: i32, coeff: *i16, exp: *i16) void {
        const n: i16 = @intCast(product & 0x7fff);
        const m: i16 = @truncate(product >> 15);
        var e = scan15(m);
        if (e > 0) {
            var c: i16 = @truncate((@as(i32, m) * romFactor(0x21 + e)) << 1);
            if (e < 15) {
                c +%= @truncate((@as(i32, n) * romFactor(0x40 - e)) >> 15);
            } else {
                e += scan15(if (m < 0) 0x7fff ^ n else n);
                if (e > 15) {
                    c = @truncate((@as(i32, n) * romFactor(0x12 + e)) << 1);
                } else {
                    c +%= n;
                }
            }
            coeff.* = c;
        } else {
            coeff.* = m;
        }
        exp.* = e;
    }

    /// Collapse coefficient·2^exponent back to 16 bits, saturating when the
    /// exponent is positive.
    fn truncate(c: i16, e: i16) i16 {
        if (e > 0) {
            if (c > 0) return 32767;
            if (c < 0) return -32767;
        } else if (e < 0) {
            return @truncate((@as(i32, c) * romFactor(0x31 + e)) >> 15);
        }
        return c;
    }

    fn shiftR(c: i16, e: i16) i16 {
        return @truncate((@as(i32, c) * romFactor(0x31 + e)) >> 15);
    }

    // --- commands -----------------------------------------------------------

    /// $02: projection parameters. Places the camera (raised Lfe above the
    /// point F along the view axis, screen Les further on), clips the zenith
    /// angle, and returns the raster offset/velocity and screen centre.
    fn cmdParameter(
        self: *Dsp1,
        fx: i16,
        fy: i16,
        fz: i16,
        lfe: i16,
        les: i16,
        aas: i16,
        azs_in: i16,
        vof: *i16,
        vva: *i16,
        cx: *i16,
        cy: *i16,
    ) void {
        var azs = azs_in;
        self.sin_aas = sin(aas);
        self.cos_aas = cos(aas);
        self.sin_azs = sin(azs);
        self.cos_azs = cos(azs);

        self.nx = mul15(self.sin_azs, -%@as(i32, self.sin_aas));
        self.ny = mul15(self.sin_azs, self.cos_aas);
        self.nz = mul15(self.cos_azs, 0x7fff);

        self.centre_x = @as(i16, fx) +% mul15(lfe, self.nx);
        self.centre_y = fy +% mul15(lfe, self.ny);
        const centre_z: i16 = fz +% mul15(lfe, self.nz);

        self.gx = self.centre_x -% mul15(les, self.nx);
        self.gy = self.centre_y -% mul15(les, self.ny);
        self.gz = centre_z -% mul15(les, self.nz);

        self.e_les = 0;
        normalize(les, &self.c_les, &self.e_les);
        self.g_les = les;

        var c: i16 = undefined;
        var e: i16 = 0;
        normalize(centre_z, &c, &e);
        self.vplane_c = c;
        self.vplane_e = e;

        // Clip the zenith angle to the exponent-dependent maximum.
        var max_azs = max_azs_exp[@intCast(-e)];
        if (azs < 0) {
            max_azs = -max_azs;
            if (azs < max_azs + 1) azs = max_azs + 1;
        } else {
            if (azs > max_azs) azs = max_azs;
        }
        self.sin_azs_clip = sin(azs);
        self.cos_azs_clip = cos(azs);

        inverse(self.cos_azs_clip, 0, &self.sec_azs_c1, &self.sec_azs_e1);
        normalize(mul15(c, self.sec_azs_c1), &c, &e);
        e += self.sec_azs_e1;

        c = mul15(truncate(c, e), self.sin_azs_clip);
        self.centre_x +%= mul15(c, self.sin_aas);
        self.centre_y -%= mul15(c, self.cos_aas);
        cx.* = self.centre_x;
        cy.* = self.centre_y;

        // Raster offset of the imaginary centre when the angle was clipped:
        // a small polynomial correction (see the k_clip/k_pi constants).
        vof.* = 0;
        if (azs_in != azs or azs_in == max_azs) {
            var azs_c = azs_in;
            if (azs_c == -32768) azs_c = -32767;
            c = azs_c -% max_azs;
            if (c >= 0) c -%= 1;
            const aux0: i16 = @truncate(~(@as(i32, c) << 2));
            c = mul15(aux0, k_pi3_6);
            c = mul15(c, aux0) +% k_pi_3_13;
            vof.* -%= mul15(mul15(c, aux0), les);

            c = mul15(aux0, aux0);
            const aux1 = mul15(c, k_clip_sq) +% k_clip_lin;
            self.cos_azs_clip +%= mul15(mul15(c, aux1), self.cos_azs_clip);
        }

        self.v_offset = mul15(les, self.cos_azs_clip);

        var csec: i16 = undefined;
        inverse(self.sin_azs_clip, 0, &csec, &e);
        normalize(self.v_offset, &c, &e);
        normalize(mul15(c, csec), &c, &e);
        if (c == -32768) {
            c >>= 1;
            e += 1;
        }
        vva.* = truncate(-%c, e);

        inverse(self.cos_azs_clip, 0, &self.sec_azs_c2, &self.sec_azs_e2);
    }

    /// $0A: mode 7 matrix for one screen line of the ground plane.
    fn cmdRaster(self: *Dsp1, vs: i16, an: *i16, bn: *i16, cn: *i16, dn: *i16) void {
        var c: i16 = undefined;
        var e: i16 = undefined;
        inverse(mul15(vs, self.sin_azs) +% self.v_offset, 7, &c, &e);
        e += self.vplane_e;

        const c1 = mul15(c, self.vplane_c);
        var e1 = e + self.sec_azs_e2;

        normalize(c1, &c, &e);
        c = truncate(c, e);
        an.* = mul15(c, self.cos_aas);
        cn.* = mul15(c, self.sin_aas);

        normalize(mul15(c1, self.sec_azs_c2), &c, &e1);
        c = truncate(c, e1);
        bn.* = mul15(c, -%@as(i32, self.sin_aas));
        dn.* = mul15(c, self.cos_aas);
    }

    /// $06: world point → screen H/V plus a 1/256-scaled magnification.
    fn cmdProject(self: *Dsp1, x: i16, y: i16, z: i16, h: *i16, v: *i16, m: *i16) void {
        var px: i16 = undefined;
        var py: i16 = undefined;
        var pz: i16 = undefined;
        var e: i16 = undefined;
        var e3: i16 = undefined;
        var e4: i16 = undefined;
        normalizeDouble(@as(i32, x) - self.gx, &px, &e4);
        normalizeDouble(@as(i32, y) - self.gy, &py, &e);
        normalizeDouble(@as(i32, z) - self.gz, &pz, &e3);
        // Halve to keep the scalar products from overflowing.
        px >>= 1;
        e4 -= 1;
        py >>= 1;
        e -= 1;
        pz >>= 1;
        e3 -= 1;

        var ref_e = @min(e, e3, e4);
        px = shiftR(px, e4 - ref_e);
        py = shiftR(py, e - ref_e);
        pz = shiftR(pz, e3 - ref_e);

        // Scalar product of P with the screen normal, denormalized in 32 bits.
        const c12: i16 = -%mul15(px, self.nx) -% mul15(py, self.ny) -% mul15(pz, self.nz);
        var aux4: i32 = c12;
        ref_e = 16 - ref_e;
        if (ref_e >= 0)
            aux4 = @truncate(@as(i64, aux4) << @intCast(ref_e))
        else
            aux4 >>= @intCast(-ref_e);
        if (aux4 == -1) aux4 = 0; // microcode quirk, kept
        aux4 >>= 1;

        const aux = @as(i32, @as(u16, @bitCast(self.g_les))) +% aux4;
        var c10: i16 = undefined;
        var e2: i16 = undefined;
        normalizeDouble(aux, &c10, &e2);
        e2 = 15 - e2;

        var c4: i16 = undefined;
        inverse(c10, 0, &c4, &e4);
        const c2 = mul15(c4, self.c_les); // scale factor

        var e7: i16 = 0;
        const c17: i16 = mul15(px, mul15(self.cos_aas, 0x7fff)) +%
            mul15(py, mul15(self.sin_aas, 0x7fff));
        var c19: i16 = undefined;
        normalize(mul15(c17, c2), &c19, &e7);
        h.* = truncate(c19, self.e_les - e2 + ref_e + e7);

        var e6: i16 = 0;
        const c24: i16 = mul15(px, mul15(self.cos_azs, -%@as(i32, self.sin_aas))) +%
            mul15(py, mul15(self.cos_azs, self.cos_aas)) +%
            mul15(pz, mul15(-%@as(i32, self.sin_azs), 0x7fff));
        var c25: i16 = undefined;
        normalize(mul15(c24, c2), &c25, &e6);
        v.* = truncate(c25, self.e_les - e2 + ref_e + e6);

        var c6: i16 = undefined;
        normalize(c2, &c6, &e4);
        m.* = truncate(c6, e4 + self.e_les - e2 - 7);
    }

    /// $0E: screen H/V → world X/Y on the ground plane (aim targeting).
    fn cmdTarget(self: *Dsp1, h_in: i16, v_in: i16, x: *i16, y: *i16) void {
        var c: i16 = undefined;
        var e: i16 = undefined;
        inverse(mul15(v_in, self.sin_azs) +% self.v_offset, 8, &c, &e);
        e += self.vplane_e;

        const c1 = mul15(c, self.vplane_c);
        var e1 = e + self.sec_azs_e1;

        const h = h_in *% 256;
        normalize(c1, &c, &e);
        c = mul15(truncate(c, e), h);
        x.* = self.centre_x +% mul15(c, self.cos_aas);
        y.* = self.centre_y -% mul15(c, self.sin_aas);

        const v = v_in *% 256;
        normalize(mul15(c1, self.sec_azs_c1), &c, &e1);
        c = mul15(truncate(c, e1), v);
        x.* +%= mul15(c, -%@as(i32, self.sin_aas));
        y.* +%= mul15(c, self.cos_aas);
    }

    /// $01/$11/$21: build a scaled ZYX Euler attitude matrix.
    fn cmdAttitude(m_in: i16, zr: i16, yr: i16, xr: i16, mat: *[3][3]i16) void {
        const sz: i32 = sin(zr);
        const cz: i32 = cos(zr);
        const sy: i32 = sin(yr);
        const cy: i32 = cos(yr);
        const sx: i32 = sin(xr);
        const cx: i32 = cos(xr);
        const m: i32 = m_in >> 1;

        mat[0][0] = mul15(mul15(m, cz), cy);
        mat[0][1] = -%mul15(mul15(m, sz), cy);
        mat[0][2] = mul15(m, sy);
        mat[1][0] = mul15(mul15(m, sz), cx) +% mul15(mul15(mul15(m, cz), sx), sy);
        mat[1][1] = mul15(mul15(m, cz), cx) -% mul15(mul15(mul15(m, sz), sx), sy);
        mat[1][2] = -%mul15(mul15(m, sx), cy);
        mat[2][0] = mul15(mul15(m, sz), sx) -% mul15(mul15(mul15(m, cz), cx), sy);
        mat[2][1] = mul15(mul15(m, cz), sx) +% mul15(mul15(mul15(m, sz), cx), sy);
        mat[2][2] = mul15(mul15(m, cx), cy);
    }

    /// $0D/$1D/$2D: global vector through the attitude matrix (objective →
    /// subjective; each product truncated before summing).
    fn cmdObjective(x: i16, y: i16, z: i16, mat: *const [3][3]i16, f: *i16, l: *i16, u: *i16) void {
        f.* = mul15(x, mat[0][0]) +% mul15(y, mat[0][1]) +% mul15(z, mat[0][2]);
        l.* = mul15(x, mat[1][0]) +% mul15(y, mat[1][1]) +% mul15(z, mat[1][2]);
        u.* = mul15(x, mat[2][0]) +% mul15(y, mat[2][1]) +% mul15(z, mat[2][2]);
    }

    /// $03/$13/$23: attitude-frame vector back to global coordinates.
    fn cmdSubjective(f: i16, l: i16, u: i16, mat: *const [3][3]i16, x: *i16, y: *i16, z: *i16) void {
        x.* = mul15(f, mat[0][0]) +% mul15(l, mat[1][0]) +% mul15(u, mat[2][0]);
        y.* = mul15(f, mat[0][1]) +% mul15(l, mat[1][1]) +% mul15(u, mat[2][1]);
        z.* = mul15(f, mat[0][2]) +% mul15(l, mat[1][2]) +% mul15(u, mat[2][2]);
    }

    /// $0B/$1B/$2B: forward-axis scalar product (the full 32-bit sum is
    /// shifted once, unlike the objective command).
    fn cmdScalar(x: i16, y: i16, z: i16, mat: *const [3][3]i16) i16 {
        const s = @as(i32, x) * mat[0][0] + @as(i32, y) * mat[0][1] + @as(i32, z) * mat[0][2];
        return @truncate(s >> 15);
    }

    /// $14: gyrate — integrate angular velocities (F/L/U) into Euler angles,
    /// with the secant/tangent cross-coupling of a ZYX gimbal.
    fn cmdGyrate(zr: i16, xr: i16, yr: i16, u: i16, f: i16, l: i16, zrr: *i16, xrr: *i16, yrr: *i16) void {
        var csec: i16 = undefined;
        var esec: i16 = undefined;
        inverse(cos(xr), 0, &csec, &esec);

        var c: i16 = undefined;
        var e: i16 = undefined;
        normalizeDouble(@as(i32, u) * cos(yr) - @as(i32, f) * sin(yr), &c, &e);
        e = esec - e;
        normalize(mul15(c, csec), &c, &e);
        zrr.* = zr +% truncate(c, e);

        xrr.* = xr +% mul15(u, sin(yr)) +% mul15(f, cos(yr));

        normalizeDouble(@as(i32, u) * cos(yr) + @as(i32, f) * sin(yr), &c, &e);
        e = esec - e;
        var csin: i16 = undefined;
        normalize(sin(xr), &csin, &e);
        const ctan = mul15(csec, csin);
        normalize(-%mul15(c, ctan), &c, &e);
        yrr.* = yr +% truncate(c, e) +% l;
    }

    /// $28: |(x,y,z)| via the sqrt segment with linear interpolation.
    fn cmdDistance(x: i16, y: i16, z: i16) i16 {
        const radius = @as(i32, x) * x +% @as(i32, y) * y +% @as(i32, z) * z;
        if (radius == 0) return 0;
        var c: i16 = undefined;
        var e: i16 = undefined;
        normalizeDouble(radius, &c, &e);
        if (e & 1 != 0) c = mul15(c, 0x4000);
        const pos: i32 = (@as(i32, c) * 0x40) >> 15;
        const node1: i32 = data_rom[@intCast(0xd5 + pos)];
        const node2: i32 = data_rom[@intCast(0xd6 + pos)];
        const r: i16 = @truncate((((node2 - node1) * (c & 0x1ff)) >> 9) + node1);
        return r >> @intCast(e >> 1);
    }

    // --- port protocol ------------------------------------------------------

    fn param16(self: *const Dsp1, word: usize) i16 {
        return @bitCast(std.mem.readInt(u16, self.parameters[word * 2 ..][0..2], .little));
    }

    fn emit16(self: *Dsp1, word: usize, value: i16) void {
        std.mem.writeInt(u16, self.output[word * 2 ..][0..2], @bitCast(value), .little);
    }

    /// SR read: the HLE is always ready (RQM set, no busy phases).
    pub fn readStatus(self: *const Dsp1) u8 {
        _ = self;
        return 0x80;
    }

    /// DR read: stream result bytes; the raster command auto-refills with the
    /// next scanline, and the dump command streams the synthesized data ROM.
    pub fn readData(self: *Dsp1) u8 {
        if (self.out_count == 0) return 0x80;
        var t: u8 = undefined;
        if (self.command == 0x1f) {
            const word = data_rom[self.out_index >> 1];
            t = if (self.out_index & 1 == 0) @truncate(word) else @truncate(word >> 8);
        } else {
            t = self.output[self.out_index & 0xf];
        }
        self.out_index += 1;
        self.out_count -= 1;
        if (self.out_count == 0 and (self.command == 0x0a or self.command == 0x1a)) {
            self.execRaster();
        }
        self.waiting_for_command = true;
        return t;
    }

    /// DR write: command byte, then little-endian parameter bytes; the
    /// command runs when its last parameter byte lands.
    pub fn writeData(self: *Dsp1, byte: u8) void {
        // Writes during a raster read burst skip output bytes (games use
        // this to discard the tail of a line).
        if ((self.command == 0x0a or self.command == 0x1a) and self.out_count != 0) {
            self.out_count -= 1;
            self.out_index += 1;
            return;
        }
        if (self.waiting_for_command) {
            self.command = byte;
            self.in_index = 0;
            self.waiting_for_command = false;
            self.first_parameter = true;
            self.in_count = 2 * @as(u16, switch (byte) {
                0x00, 0x20, 0x10, 0x30, 0x04, 0x24, 0x0e, 0x1e, 0x2e, 0x3e => 2,
                0x08, 0x28, 0x0c, 0x2c => 3,
                0x18, 0x38 => 4,
                0x1c, 0x3c, 0x14, 0x34 => 6,
                0x02, 0x12, 0x22, 0x32 => 7,
                0x0a, 0x1a, 0x2a, 0x3a => blk: {
                    self.command = 0x1a;
                    break :blk 1;
                },
                0x06, 0x16, 0x26, 0x36 => 3,
                0x01, 0x05, 0x11, 0x15, 0x21, 0x25, 0x31, 0x35 => 4,
                0x03, 0x0d, 0x13, 0x1d, 0x23, 0x2d, 0x09, 0x19, 0x29, 0x33, 0x39, 0x3d => 3,
                0x0b, 0x1b, 0x2b, 0x3b => 3,
                0x07, 0x0f, 0x27, 0x2f => 1,
                0x17, 0x37, 0x3f, 0x1f => blk: {
                    self.command = 0x1f;
                    break :blk 1;
                },
                else => blk: {
                    // Unknown command (or the $80 idle byte): stay waiting.
                    self.waiting_for_command = true;
                    break :blk 0;
                },
            });
        } else {
            self.parameters[self.in_index & 0xf] = byte;
            self.first_parameter = false;
            self.in_index += 1;
        }

        if (self.waiting_for_command or (self.first_parameter and byte == 0x80)) {
            self.waiting_for_command = true;
            self.first_parameter = false;
        } else if (self.first_parameter) {
            // The command byte itself consumes no parameter budget.
        } else if (self.in_count != 0) {
            self.in_count -= 1;
            if (self.in_count == 0) self.execute();
        }
    }

    fn execute(self: *Dsp1) void {
        self.waiting_for_command = true;
        self.out_index = 0;
        var a: i16 = undefined;
        var b: i16 = undefined;
        var c: i16 = undefined;
        var d: i16 = undefined;
        switch (self.command) {
            0x00 => { // multiply: (a*b)>>15
                self.emit16(0, mul15(self.param16(0), self.param16(1)));
                self.out_count = 2;
            },
            0x20 => { // multiply variant: (a*b)>>15 + 1
                self.emit16(0, mul15(self.param16(0), self.param16(1)) +% 1);
                self.out_count = 2;
            },
            0x10, 0x30 => { // inverse
                inverse(self.param16(0), self.param16(1), &a, &b);
                self.emit16(0, a);
                self.emit16(1, b);
                self.out_count = 4;
            },
            0x04, 0x24 => { // sin/cos scaled by radius
                const angle = self.param16(0);
                const radius = self.param16(1);
                self.emit16(0, mul15(sin(angle), radius));
                self.emit16(1, mul15(cos(angle), radius));
                self.out_count = 4;
            },
            0x08 => { // radius: 2*(x²+y²+z²) as a 32-bit value
                const x: i32 = self.param16(0);
                const y: i32 = self.param16(1);
                const z: i32 = self.param16(2);
                const size = (x * x +% y * y +% z * z) *% 2;
                self.emit16(0, @truncate(size));
                self.emit16(1, @truncate(size >> 16));
                self.out_count = 4;
            },
            0x18, 0x38 => { // range: (x²+y²+z²-r²)>>15 (+1 for $38)
                const x: i32 = self.param16(0);
                const y: i32 = self.param16(1);
                const z: i32 = self.param16(2);
                const r: i32 = self.param16(3);
                var v: i16 = @truncate((x * x +% y * y +% z * z -% r * r) >> 15);
                if (self.command == 0x38) v +%= 1;
                self.emit16(0, v);
                self.out_count = 2;
            },
            0x28 => { // distance |(x,y,z)|
                self.emit16(0, cmdDistance(self.param16(0), self.param16(1), self.param16(2)));
                self.out_count = 2;
            },
            0x0c, 0x2c => { // 2D rotate by angle a
                const angle = self.param16(0);
                const x = self.param16(1);
                const y = self.param16(2);
                self.emit16(0, mul15(y, sin(angle)) +% mul15(x, cos(angle)));
                self.emit16(1, mul15(y, cos(angle)) -% mul15(x, sin(angle)));
                self.out_count = 4;
            },
            0x1c, 0x3c => { // 3D rotate: Z, then Y, then X axis
                const az = self.param16(0);
                const ay = self.param16(1);
                const ax = self.param16(2);
                var xbr = self.param16(3);
                var ybr = self.param16(4);
                var zbr = self.param16(5);
                var t = mul15(ybr, sin(az)) +% mul15(xbr, cos(az));
                ybr = mul15(ybr, cos(az)) -% mul15(xbr, sin(az));
                xbr = t;
                t = mul15(xbr, sin(ay)) +% mul15(zbr, cos(ay));
                xbr = mul15(xbr, cos(ay)) -% mul15(zbr, sin(ay));
                zbr = t;
                t = mul15(zbr, sin(ax)) +% mul15(ybr, cos(ax));
                zbr = mul15(zbr, cos(ax)) -% mul15(ybr, sin(ax));
                ybr = t;
                self.emit16(0, xbr);
                self.emit16(1, ybr);
                self.emit16(2, zbr);
                self.out_count = 6;
            },
            0x02, 0x12, 0x22, 0x32 => { // projection parameters
                self.cmdParameter(
                    self.param16(0),
                    self.param16(1),
                    self.param16(2),
                    self.param16(3),
                    self.param16(4),
                    self.param16(5),
                    self.param16(6),
                    &a,
                    &b,
                    &c,
                    &d,
                );
                self.emit16(0, a);
                self.emit16(1, b);
                self.emit16(2, c);
                self.emit16(3, d);
                self.out_count = 8;
            },
            0x1a => { // raster: mode 7 matrix per scanline, streaming
                self.raster_vs = self.param16(0);
                self.execRaster();
                self.in_index = 0;
            },
            0x06, 0x16, 0x26, 0x36 => { // project world point to screen
                self.cmdProject(self.param16(0), self.param16(1), self.param16(2), &a, &b, &c);
                self.emit16(0, a);
                self.emit16(1, b);
                self.emit16(2, c);
                self.out_count = 6;
            },
            0x0e, 0x1e, 0x2e, 0x3e => { // target screen point to ground
                self.cmdTarget(self.param16(0), self.param16(1), &a, &b);
                self.emit16(0, a);
                self.emit16(1, b);
                self.out_count = 4;
            },
            0x01, 0x05, 0x31, 0x35 => cmdAttitude(
                self.param16(0),
                self.param16(1),
                self.param16(2),
                self.param16(3),
                &self.matrix_a,
            ),
            0x11, 0x15 => cmdAttitude(
                self.param16(0),
                self.param16(1),
                self.param16(2),
                self.param16(3),
                &self.matrix_b,
            ),
            0x21, 0x25 => cmdAttitude(
                self.param16(0),
                self.param16(1),
                self.param16(2),
                self.param16(3),
                &self.matrix_c,
            ),
            0x0d, 0x09, 0x39, 0x3d => {
                cmdObjective(self.param16(0), self.param16(1), self.param16(2), &self.matrix_a, &a, &b, &c);
                self.emit3(a, b, c);
            },
            0x1d, 0x19 => {
                cmdObjective(self.param16(0), self.param16(1), self.param16(2), &self.matrix_b, &a, &b, &c);
                self.emit3(a, b, c);
            },
            0x2d, 0x29 => {
                cmdObjective(self.param16(0), self.param16(1), self.param16(2), &self.matrix_c, &a, &b, &c);
                self.emit3(a, b, c);
            },
            0x03, 0x33 => {
                cmdSubjective(self.param16(0), self.param16(1), self.param16(2), &self.matrix_a, &a, &b, &c);
                self.emit3(a, b, c);
            },
            0x13 => {
                cmdSubjective(self.param16(0), self.param16(1), self.param16(2), &self.matrix_b, &a, &b, &c);
                self.emit3(a, b, c);
            },
            0x23 => {
                cmdSubjective(self.param16(0), self.param16(1), self.param16(2), &self.matrix_c, &a, &b, &c);
                self.emit3(a, b, c);
            },
            0x0b, 0x3b => {
                self.emit16(0, cmdScalar(self.param16(0), self.param16(1), self.param16(2), &self.matrix_a));
                self.out_count = 2;
            },
            0x1b => {
                self.emit16(0, cmdScalar(self.param16(0), self.param16(1), self.param16(2), &self.matrix_b));
                self.out_count = 2;
            },
            0x2b => {
                self.emit16(0, cmdScalar(self.param16(0), self.param16(1), self.param16(2), &self.matrix_c));
                self.out_count = 2;
            },
            0x14, 0x34 => { // gyrate
                cmdGyrate(
                    self.param16(0),
                    self.param16(1),
                    self.param16(2),
                    self.param16(3),
                    self.param16(4),
                    self.param16(5),
                    &a,
                    &b,
                    &c,
                );
                self.emit3(a, b, c);
            },
            0x0f, 0x07 => { // memory test: always passes
                self.emit16(0, 0x0000);
                self.out_count = 2;
            },
            0x2f, 0x27 => { // memory size: 1 KiB data ROM
                self.emit16(0, 0x0100);
                self.out_count = 2;
            },
            0x1f => self.out_count = 2048, // data ROM dump (see readData)
            else => {},
        }
    }

    fn emit3(self: *Dsp1, a: i16, b: i16, c: i16) void {
        self.emit16(0, a);
        self.emit16(1, b);
        self.emit16(2, c);
        self.out_count = 6;
    }

    fn execRaster(self: *Dsp1) void {
        var an: i16 = undefined;
        var bn: i16 = undefined;
        var cn: i16 = undefined;
        var dn: i16 = undefined;
        self.cmdRaster(self.raster_vs, &an, &bn, &cn, &dn);
        self.raster_vs +%= 1;
        self.emit16(0, an);
        self.emit16(1, bn);
        self.emit16(2, cn);
        self.emit16(3, dn);
        self.out_count = 8;
        self.out_index = 0;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

/// Run one command through the ports: write the command byte and parameter
/// words, read back `out` result words.
fn runCommand(d: *Dsp1, command: u8, params: []const i16, out: []i16) void {
    d.writeData(command);
    for (params) |p| {
        const u: u16 = @bitCast(p);
        d.writeData(@truncate(u));
        d.writeData(@truncate(u >> 8));
    }
    for (out) |*o| {
        const lo: u16 = d.readData();
        const hi: u16 = d.readData();
        o.* = @bitCast(lo | hi << 8);
    }
}

test "data rom regions" {
    // Powers, the $7fff pivot, and the hardware's $3C bug.
    try testing.expectEqual(@as(u16, 1), data_rom[0x22]);
    try testing.expectEqual(@as(u16, 0x4000), data_rom[0x30]);
    try testing.expectEqual(@as(u16, 0x7fff), data_rom[0x31]);
    try testing.expectEqual(@as(u16, 0x4000), data_rom[0x32]);
    try testing.expectEqual(@as(u16, 0x0001), data_rom[0x3c]);
    // Reciprocal seeds: round(2^29/d).
    try testing.expectEqual(@as(u16, 0x7fff), data_rom[0x65]);
    try testing.expectEqual(@as(u16, 0x7f02), data_rom[0x66]);
    try testing.expectEqual(@as(u16, 0x7e08), data_rom[0x67]);
    try testing.expectEqual(@as(u16, 0x4040), data_rom[0xe4]);
    // Sqrt segment endpoints.
    try testing.expectEqual(@as(u16, 0x3fff), data_rom[0xe5]);
    try testing.expectEqual(@as(u16, 0x5a81), data_rom[0xf5]);
    try testing.expectEqual(@as(u16, 0x7fff), data_rom[0x115]);
    // Sine table: quadrant landmarks and truncation direction.
    try testing.expectEqual(@as(i16, 0), sin_table[0]);
    try testing.expectEqual(@as(i16, 804), sin_table[1]);
    try testing.expectEqual(@as(i16, 32767), sin_table[0x40]);
    try testing.expectEqual(@as(i16, -32767), sin_table[0xc0]);
    try testing.expectEqual(@as(i16, -804), sin_table[0xff]);
}

test "multiply commands" {
    var d: Dsp1 = .init;
    var out: [1]i16 = undefined;
    runCommand(&d, 0x00, &.{ 0x4000, 0x2000 }, &out); // 0.5 * 0.25 = 0.125
    try testing.expectEqual(@as(i16, 0x1000), out[0]);
    runCommand(&d, 0x20, &.{ 0x4000, 0x2000 }, &out);
    try testing.expectEqual(@as(i16, 0x1001), out[0]);
    runCommand(&d, 0x00, &.{ -0x4000, 0x4000 }, &out); // -0.5 * 0.5 = -0.25
    try testing.expectEqual(@as(i16, -0x2000), out[0]);
}

test "inverse command" {
    var d: Dsp1 = .init;
    var out: [2]i16 = undefined;
    // 1/0 saturates with the documented sentinel exponent.
    runCommand(&d, 0x10, &.{ 0, 0 }, &out);
    try testing.expectEqual(@as(i16, 0x7fff), out[0]);
    try testing.expectEqual(@as(i16, 0x002f), out[1]);
    // 1/0.25 = 0.99997 * 2^2 (power-of-two special case).
    runCommand(&d, 0x10, &.{ 0x2000, 0 }, &out);
    try testing.expectEqual(@as(i16, 0x7fff), out[0]);
    try testing.expectEqual(@as(i16, 2), out[1]);
    // Newton path, checked against the reference implementation.
    runCommand(&d, 0x10, &.{ 12345, 2 }, &out);
    try testing.expectEqual(@as(i16, 21744), out[0]);
    try testing.expectEqual(@as(i16, 0), out[1]);
    runCommand(&d, 0x30, &.{ -12345, 0 }, &out); // $30 alias, negative input
    try testing.expectEqual(@as(i16, -21744), out[0]);
    try testing.expectEqual(@as(i16, 2), out[1]);
}

test "trig command and identities" {
    var d: Dsp1 = .init;
    var out: [2]i16 = undefined;
    // Reference vectors (radius $7fff ≈ raw table values).
    runCommand(&d, 0x04, &.{ 0x1234, 0x7fff }, &out);
    try testing.expectEqual(@as(i16, 14156), out[0]); // sin scaled by 0x7fff
    try testing.expectEqual(@as(i16, 29551), out[1]);
    try testing.expectEqual(@as(i16, 14157), Dsp1.sin(0x1234));
    try testing.expectEqual(@as(i16, 29552), Dsp1.cos(0x1234));
    try testing.expectEqual(@as(i16, -5918), Dsp1.sin(-0x789A));
    try testing.expectEqual(@as(i16, -32232), Dsp1.cos(-0x789A));
    // sin²+cos² ≈ 1 across the circle (interpolation keeps it within ~2^-10).
    var angle: i32 = -0x8000;
    while (angle < 0x8000) : (angle += 0x137) {
        const s: i64 = Dsp1.sin(@intCast(angle));
        const c: i64 = Dsp1.cos(@intCast(angle));
        const one = @divTrunc(s * s + c * c, 32768);
        try testing.expect(@abs(one - 32767) < 64);
    }
}

test "rotate 2d command" {
    var d: Dsp1 = .init;
    var out: [2]i16 = undefined;
    // 90° ($4000): (x,0) rotates to (0,-x) in the chip's screen-handed frame.
    runCommand(&d, 0x0c, &.{ 0x4000, 0x1000, 0 }, &out);
    try testing.expectEqual(@as(i16, 0), out[0]);
    try testing.expectEqual(@as(i16, -0xFFF), out[1]);
    // Rotating by a then -a returns near the start.
    runCommand(&d, 0x0c, &.{ 0x0AAA, 2000, 3000 }, &out);
    runCommand(&d, 0x0c, &.{ -0x0AAA, out[0], out[1] }, &out);
    try testing.expect(@abs(@as(i32, out[0]) - 2000) <= 2);
    try testing.expect(@abs(@as(i32, out[1]) - 3000) <= 2);
}

test "radius, range, distance commands" {
    var d: Dsp1 = .init;
    var out2: [2]i16 = undefined;
    var out1: [1]i16 = undefined;
    // $08: 2*(0x100² * 3) = 0x60000.
    runCommand(&d, 0x08, &.{ 0x100, 0x100, 0x100 }, &out2);
    try testing.expectEqual(@as(i16, 0), out2[0]);
    try testing.expectEqual(@as(i16, 6), out2[1]);
    // $18/$38: signed comparison against r².
    runCommand(&d, 0x18, &.{ 3000, 4000, 0, 5000 }, &out1);
    try testing.expectEqual(@as(i16, 0), out1[0]);
    runCommand(&d, 0x38, &.{ 3000, 4000, 0, 5000 }, &out1);
    try testing.expectEqual(@as(i16, 1), out1[0]);
    // $28: Euclidean length via the sqrt segment.
    runCommand(&d, 0x28, &.{ 3000, 4000, 0 }, &out1);
    try testing.expectEqual(@as(i16, 4999), out1[0]);
    runCommand(&d, 0x28, &.{ 1000, 2000, 3000 }, &out1);
    try testing.expectEqual(@as(i16, 3741), out1[0]);
    runCommand(&d, 0x28, &.{ 0, 0, 0 }, &out1);
    try testing.expectEqual(@as(i16, 0), out1[0]);
}

test "attitude, objective, subjective, scalar" {
    var d: Dsp1 = .init;
    var out: [3]i16 = undefined;
    // Identity attitude at half scale: objective(x,0,0).F ≈ x/2.
    runCommand(&d, 0x01, &.{ 0x7fff, 0, 0, 0 }, out[0..0]);
    runCommand(&d, 0x0d, &.{ 0x2000, 0, 0 }, &out);
    try testing.expect(@abs(@as(i32, out[0]) - 0x1000) <= 1);
    try testing.expectEqual(@as(i16, 0), out[1]);
    try testing.expectEqual(@as(i16, 0), out[2]);
    // Subjective is the transpose: round-tripping recovers ~x/4.
    runCommand(&d, 0x03, &.{ out[0], out[1], out[2] }, &out);
    try testing.expect(@abs(@as(i32, out[0]) - 0x0800) <= 2);
    // Matrix B holds its own state; scalar $1B = F row product.
    runCommand(&d, 0x11, &.{ 0x7fff, -0x8000, 0, 0 }, out[0..0]); // yaw 180°
    var s: [1]i16 = undefined;
    runCommand(&d, 0x1b, &.{ 0x2000, 0, 0 }, &s);
    try testing.expect(@abs(@as(i32, s[0]) + 0x1000) <= 2); // facing away: -x/2
}

test "gyrate command" {
    var d: Dsp1 = .init;
    var out: [3]i16 = undefined;
    runCommand(&d, 0x14, &.{ 100, 200, 300, 400, 500, 600 }, &out);
    try testing.expectEqual(@as(i16, 485), out[0]); // reference vectors
    try testing.expectEqual(@as(i16, 710), out[1]);
    try testing.expectEqual(@as(i16, 892), out[2]);
}

test "projection pipeline: parameter, raster, project, target" {
    var d: Dsp1 = .init;
    var out4: [4]i16 = undefined;
    var out3: [3]i16 = undefined;
    var out2: [2]i16 = undefined;
    // Pilotwings-like camera; all expected values from the reference.
    runCommand(&d, 0x02, &.{ 100, 200, 1000, 8192, 4096, 0, -0x2000 }, &out4);
    try testing.expectEqual(@as(i16, 0), out4[0]); // Vof
    try testing.expectEqual(@as(i16, 4095), out4[1]); // Vva
    try testing.expectEqual(@as(i16, 100), out4[2]); // Cx
    try testing.expectEqual(@as(i16, 1199), out4[3]); // Cy

    runCommand(&d, 0x0a, &.{10}, &out4);
    try testing.expectEqual([4]i16{ 601, 0, 0, 850 }, out4);
    // The raster stream auto-advances one scanline per 8-byte burst: drain
    // lines 11..99, then the next burst is line 100.
    for (0..89 * 8) |_| _ = d.readData();
    for (&out4) |*o| {
        const lo: u16 = d.readData();
        const hi: u16 = d.readData();
        o.* = @bitCast(lo | hi << 8);
    }
    try testing.expectEqual([4]i16{ 614, 0, 0, 869 }, out4); // line 100

    var d2: Dsp1 = .init;
    runCommand(&d2, 0x02, &.{ 100, 200, 1000, 8192, 4096, 0, -0x2000 }, &out4);
    runCommand(&d2, 0x06, &.{ 0, 0, 0 }, &out3);
    try testing.expectEqual([3]i16{ -47, -397, 119 }, out3);
    runCommand(&d2, 0x06, &.{ 500, -300, 20 }, &out3);
    try testing.expectEqual([3]i16{ 191, -503, 122 }, out3);
    runCommand(&d2, 0x0e, &.{ 16, 32 }, &out2);
    try testing.expectEqual([2]i16{ 136, 1304 }, out2);

    // Second camera: azimuth 45°, near-flat zenith (exercises the clip path).
    runCommand(&d2, 0x02, &.{ -500, 300, 2000, 700, 700, 0x2000, -0x0100 }, &out4);
    try testing.expectEqual([4]i16{ 0, 28490, -536, 335 }, out4);
    runCommand(&d2, 0x0a, &.{50}, &out4);
    try testing.expectEqual([4]i16{ 700, -701, 700, 700 }, out4);
    // The raster stream refills itself forever; writes skip the pending
    // line's bytes, so 8 dummy writes hand control back to commands.
    for (0..8) |_| d2.writeData(0x80);
    runCommand(&d2, 0x06, &.{ 100, 100, 0 }, &out3);
    try testing.expectEqual([3]i16{ 73, -161, 66 }, out3);
    runCommand(&d2, 0x0e, &.{ -20, 5 }, &out2);
    try testing.expectEqual([2]i16{ -606, 404 }, out2);
}

test "memory test and rom dump commands" {
    var d: Dsp1 = .init;
    var out: [1]i16 = undefined;
    runCommand(&d, 0x0f, &.{0}, &out);
    try testing.expectEqual(@as(i16, 0), out[0]);
    runCommand(&d, 0x2f, &.{0}, &out);
    try testing.expectEqual(@as(i16, 0x0100), out[0]);
    // $1F streams the 2 KiB synthesized data ROM, little-endian words.
    d.writeData(0x1f);
    d.writeData(0);
    d.writeData(0);
    var i: usize = 0;
    while (i < 2048) : (i += 2) {
        const lo: u16 = d.readData();
        const hi: u16 = d.readData();
        try testing.expectEqual(data_rom[i / 2], lo | hi << 8);
    }
    try testing.expectEqual(@as(u8, 0x80), d.readData()); // drained
}

test "port protocol edges" {
    var d: Dsp1 = .init;
    // SR always ready.
    try testing.expectEqual(@as(u8, 0x80), d.readStatus());
    // $80 as a would-be command byte is ignored (idle padding).
    d.writeData(0x80);
    try testing.expect(d.waiting_for_command);
    // Unknown command byte leaves the machine waiting.
    d.writeData(0x7d);
    try testing.expect(d.waiting_for_command);
    // Writes during a raster burst skip result bytes: skip the first word of
    // a line, then read the remaining three.
    var out4: [4]i16 = undefined;
    var d2: Dsp1 = .init;
    runCommand(&d2, 0x02, &.{ 100, 200, 1000, 8192, 4096, 0, -0x2000 }, &out4);
    d2.writeData(0x0a);
    d2.writeData(10);
    d2.writeData(0);
    d2.writeData(0x55); // skip A low byte
    d2.writeData(0x55); // skip A high byte
    var rest: [3]i16 = undefined;
    for (&rest) |*o| {
        const lo: u16 = d2.readData();
        const hi: u16 = d2.readData();
        o.* = @bitCast(lo | hi << 8);
    }
    try testing.expectEqual([3]i16{ 0, 0, 850 }, rest);
}
