//! S-DSP: the SNES sound processor. Eight BRR-compressed voices with gaussian
//! interpolation, ADSR/GAIN envelopes, noise, pitch modulation, and an echo
//! unit with an 8-tap FIR filter, mixed to one 16-bit stereo sample every 32
//! SPC cycles (32 kHz).
//!
//! This is the fast core's per-sample model: hardware sequences each sample
//! across 32 internal phases (register changes can land mid-sample); here the
//! whole sample is computed at once from the register file as it stands, so
//! writes take effect at the next sample boundary. Everything audible is kept
//! exact: the BRR filters, the gaussian kernel and its truncation quirks, the
//! envelope state machine and global rate counter, the noise LFSR, the echo
//! FIR (which reads and writes ARAM), and — crucially — **signed mixing
//! everywhere**. Voice, master, and echo volumes and the FIR coefficients are
//! two's-complement; negative values invert phase, which is how games encode
//! Dolby Surround (see docs/AUDIO_SURROUND.md). Never "fix" that.
//!
//! Register map ($00-$7F, exposed at SPC $F2/$F3): per voice x0-x9
//! VOL(L/R), pitch, SRCN, ADSR1/2, GAIN, ENVX/OUTX(read); globals MVOL/EVOL,
//! KON/KOF, FLG, ENDX(read, write clears), EFB, PMON, NON, EON, DIR, ESA,
//! EDL, and FIR coefficients C0-C7 at $xF.

const std = @import("std");

/// The S-DSP's 512-entry gaussian interpolation kernel (chip ROM contents,
/// documented in fullsnes/anomie). The values are exactly reproduced by
/// byuu's closed-form reconstruction — for phase k = n + 0.5:
///   r(n) = sin(pi*k*1.280/1024) * ((cos(pi*k*2/1023)-1)*0.50
///          + (cos(pi*k*4/1023)-1)*0.08 + 1) / k
/// mirrored and normalized so each 4-tap group sums to 2048 — verified
/// entry-for-entry against the hardware dump before embedding.
pub const gauss = [512]i16{
    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,
    1,    1,    1,    1,    1,    1,    1,    1,    1,    1,    1,    2,    2,    2,    2,    2,
    2,    2,    3,    3,    3,    3,    3,    4,    4,    4,    4,    4,    5,    5,    5,    5,
    6,    6,    6,    6,    7,    7,    7,    8,    8,    8,    9,    9,    9,    10,   10,   10,
    11,   11,   11,   12,   12,   13,   13,   14,   14,   15,   15,   15,   16,   16,   17,   17,
    18,   19,   19,   20,   20,   21,   21,   22,   23,   23,   24,   24,   25,   26,   27,   27,
    28,   29,   29,   30,   31,   32,   32,   33,   34,   35,   36,   36,   37,   38,   39,   40,
    41,   42,   43,   44,   45,   46,   47,   48,   49,   50,   51,   52,   53,   54,   55,   56,
    58,   59,   60,   61,   62,   64,   65,   66,   67,   69,   70,   71,   73,   74,   76,   77,
    78,   80,   81,   83,   84,   86,   87,   89,   90,   92,   94,   95,   97,   99,   100,  102,
    104,  106,  107,  109,  111,  113,  115,  117,  118,  120,  122,  124,  126,  128,  130,  132,
    134,  137,  139,  141,  143,  145,  147,  150,  152,  154,  156,  159,  161,  163,  166,  168,
    171,  173,  175,  178,  180,  183,  186,  188,  191,  193,  196,  199,  201,  204,  207,  210,
    212,  215,  218,  221,  224,  227,  230,  233,  236,  239,  242,  245,  248,  251,  254,  257,
    260,  263,  267,  270,  273,  276,  280,  283,  286,  290,  293,  297,  300,  304,  307,  311,
    314,  318,  321,  325,  328,  332,  336,  339,  343,  347,  351,  354,  358,  362,  366,  370,
    374,  378,  381,  385,  389,  393,  397,  401,  405,  410,  414,  418,  422,  426,  430,  434,
    439,  443,  447,  451,  456,  460,  464,  469,  473,  477,  482,  486,  491,  495,  499,  504,
    508,  513,  517,  522,  527,  531,  536,  540,  545,  550,  554,  559,  563,  568,  573,  577,
    582,  587,  592,  596,  601,  606,  611,  615,  620,  625,  630,  635,  640,  644,  649,  654,
    659,  664,  669,  674,  678,  683,  688,  693,  698,  703,  708,  713,  718,  723,  728,  732,
    737,  742,  747,  752,  757,  762,  767,  772,  777,  782,  787,  792,  797,  802,  806,  811,
    816,  821,  826,  831,  836,  841,  846,  851,  855,  860,  865,  870,  875,  880,  884,  889,
    894,  899,  904,  908,  913,  918,  923,  927,  932,  937,  941,  946,  951,  955,  960,  965,
    969,  974,  978,  983,  988,  992,  997,  1001, 1005, 1010, 1014, 1019, 1023, 1027, 1032, 1036,
    1040, 1045, 1049, 1053, 1057, 1061, 1066, 1070, 1074, 1078, 1082, 1086, 1090, 1094, 1098, 1102,
    1106, 1109, 1113, 1117, 1121, 1125, 1128, 1132, 1136, 1139, 1143, 1146, 1150, 1153, 1157, 1160,
    1164, 1167, 1170, 1174, 1177, 1180, 1183, 1186, 1190, 1193, 1196, 1199, 1202, 1205, 1207, 1210,
    1213, 1216, 1219, 1221, 1224, 1227, 1229, 1232, 1234, 1237, 1239, 1241, 1244, 1246, 1248, 1251,
    1253, 1255, 1257, 1259, 1261, 1263, 1265, 1267, 1269, 1270, 1272, 1274, 1275, 1277, 1279, 1280,
    1282, 1283, 1284, 1286, 1287, 1288, 1290, 1291, 1292, 1293, 1294, 1295, 1296, 1297, 1297, 1298,
    1299, 1300, 1300, 1301, 1302, 1302, 1303, 1303, 1303, 1304, 1304, 1304, 1304, 1304, 1305, 1305,
};

/// Envelope/noise rate dividers in samples (index = 5-bit rate; 0 never
/// fires). The global counter cycles through 30720 = lcm(2048, 1536, 1280)
/// samples; a rate "fires" on the samples where the offset counter divides.
const counter_rates = [32]u16{
    0,  2048, 1536, 1280, 1024, 768, 640, 512, 384, 320, 256, 192, 160, 128, 96, 80,
    64, 48,   40,   32,   24,   20,  16,  12,  10,  8,   6,   5,   4,   3,   2,  1,
};

/// Per-rate phase offsets (hardware derives the three divider chains from
/// one counter; these reproduce its firing pattern exactly).
const counter_offsets = [32]u16{
    0, 0,    1040, 536, 0,    1040, 536, 0,    1040, 536, 0,    1040, 536, 0,    1040, 536,
    0, 1040, 536,  0,   1040, 536,  0,   1040, 536,  0,   1040, 536,  0,   1040, 0,    0,
};

const counter_range: u16 = 30720;

// Global register offsets within the 128-byte file.
const r_mvoll = 0x0C;
const r_mvolr = 0x1C;
const r_evoll = 0x2C;
const r_evolr = 0x3C;
const r_kon = 0x4C;
const r_koff = 0x5C;
const r_flg = 0x6C;
const r_endx = 0x7C;
const r_efb = 0x0D;
const r_pmon = 0x2D;
const r_non = 0x3D;
const r_eon = 0x4D;
const r_dir = 0x5D;
const r_esa = 0x6D;
const r_edl = 0x7D;

const EnvState = enum(u8) { release, attack, decay, sustain };

const brr_block_size: u8 = 9;

const Voice = struct {
    /// 12 decoded BRR samples, stored twice so 4-tap interpolation reads and
    /// the decoder's history taps never need wraparound handling.
    buf: [24]i16 = @splat(0),
    buf_pos: u8 = 0, // next 4-sample decode group: 0/4/8
    brr_addr: u16 = 0,
    brr_offset: u8 = 1, // byte offset within the block (0 is the header)
    interp_pos: u16 = 0, // 3.12 fixed-point position, capped at 0x7FFF
    env: u16 = 0, // current envelope, 0..0x7FF
    hidden_env: i16 = 0, // pre-clamp envelope (bent-increase slope memory)
    env_state: EnvState = .release,
    kon_delay: u8 = 0, // 5-sample key-on startup countdown
};

pub const Dsp = struct {
    regs: [128]u8,
    voices: [8]Voice,
    counter: u16, // global rate counter, decrements through 30720
    every_other: bool, // KON/KOF are latched every second sample
    kon: u8, // latched key-on bits being serviced
    new_kon: u8, // pending key-on writes
    t_koff: u8, // latched key-off bits
    noise: u16, // 15-bit LFSR
    echo_hist: [8][2]i16,
    echo_hist_pos: u8,
    echo_offset: u16, // byte offset into the echo region
    echo_length: u16, // latched EDL * 0x800 bytes

    pub const init: Dsp = blk: {
        var d: Dsp = .{
            .regs = @splat(0),
            .voices = @splat(Voice{}),
            .counter = 0,
            .every_other = true,
            .kon = 0,
            .new_kon = 0,
            .t_koff = 0,
            .noise = 0x4000,
            .echo_hist = @splat([2]i16{ 0, 0 }),
            .echo_hist_pos = 0,
            .echo_offset = 0,
            .echo_length = 0,
        };
        // Power-on FLG: soft reset + mute + echo writes disabled. Without
        // this a zeroed FLG would let the echo unit clobber ARAM at $0000.
        d.regs[r_flg] = 0xE0;
        break :blk d;
    };

    // --- register file ($F2/$F3 behind the SPC I/O page) -------------------

    pub fn read(self: *const Dsp, addr: u7) u8 {
        return self.regs[addr];
    }

    pub fn write(self: *Dsp, addr: u7, value: u8) void {
        switch (addr) {
            r_kon => {
                self.regs[r_kon] = value;
                self.new_kon = value;
            },
            // Any ENDX write clears all end flags.
            r_endx => self.regs[r_endx] = 0,
            else => self.regs[addr] = value,
        }
    }

    // --- helpers ------------------------------------------------------------

    inline fn clamp16(x: i32) i32 {
        return std.math.clamp(x, std.math.minInt(i16), std.math.maxInt(i16));
    }

    inline fn trunc16(x: i32) i32 {
        return @as(i16, @truncate(x));
    }

    inline fn vreg(self: *const Dsp, v: u3, off: u7) u8 {
        return self.regs[@as(u7, v) * 0x10 + off];
    }

    inline fn signed(x: u8) i32 {
        return @as(i8, @bitCast(x));
    }

    fn read16(aram: *const [0x10000]u8, addr: u16) i32 {
        const lo: u16 = aram[addr];
        const hi: u16 = aram[addr +% 1];
        return @as(i16, @bitCast(lo | hi << 8));
    }

    /// Does `rate` fire on the current sample?
    fn counterFires(self: *const Dsp, rate: u5) bool {
        if (rate == 0) return false;
        return (self.counter +% counter_offsets[rate]) % counter_rates[rate] == 0;
    }

    // --- BRR decode ---------------------------------------------------------

    /// Decode the next 4-sample group of the voice's current BRR block into
    /// its ring buffer. `header` is the block's header byte (shift/filter).
    fn decodeBrrGroup(v: *Voice, aram: *const [0x10000]u8, header: u8) void {
        // Two data bytes -> four nibbles, consumed high-first.
        var nybbles: u16 = @as(u16, aram[v.brr_addr +% v.brr_offset]) << 8 |
            aram[v.brr_addr +% v.brr_offset +% 1];

        const pos = v.buf_pos;
        v.buf_pos = if (pos + 4 >= 12) 0 else pos + 4;

        const shift: u4 = @truncate(header >> 4);
        const filter = header & 0x0C;
        for (0..4) |i| {
            var s: i32 = @as(i16, @bitCast(nybbles)) >> 12; // sign-extended nibble
            nybbles <<= 4;

            if (shift <= 12) s = (s << shift) >> 1 else s &= ~@as(i32, 0x7FF);

            // IIR filters use the previous two decoded samples (the doubled
            // buffer means pos+11/pos+10 always hold them contiguously).
            const p1: i32 = v.buf[pos + i + 11];
            const p2: i32 = v.buf[pos + i + 10] >> 1;
            switch (filter) {
                0x08 => { // s += p1*0.953125 - p2*0.46875
                    s += p1 - p2;
                    s += p2 >> 4;
                    s += (p1 * -3) >> 6;
                },
                0x0C => { // s += p1*0.8984375 - p2*0.40625
                    s += p1 - p2;
                    s += (p1 * -13) >> 7;
                    s += (p2 * 3) >> 4;
                },
                0x04 => { // s += p1*0.46875
                    s += p1 >> 1;
                    s += (-p1) >> 5;
                },
                else => {},
            }

            // Clamp, then wrap to 15 bits (the DSP stores samples doubled).
            const wrapped = trunc16(clamp16(s) * 2);
            v.buf[pos + i] = @intCast(wrapped);
            v.buf[pos + i + 12] = @intCast(wrapped);
        }
    }

    /// 4-tap gaussian interpolation at the voice's current fractional
    /// position, including the hardware's 16-bit truncation quirk.
    fn interpolate(v: *const Voice) i32 {
        const offset: usize = (v.interp_pos >> 4) & 0xFF;
        const base: usize = (v.interp_pos >> 12) + v.buf_pos;
        var out: i32 = (@as(i32, gauss[255 - offset]) * v.buf[base]) >> 11;
        out += (@as(i32, gauss[511 - offset]) * v.buf[base + 1]) >> 11;
        out += (@as(i32, gauss[256 + offset]) * v.buf[base + 2]) >> 11;
        out = trunc16(out);
        out += (@as(i32, gauss[offset]) * v.buf[base + 3]) >> 11;
        return clamp16(out) & ~@as(i32, 1);
    }

    // --- envelope -----------------------------------------------------------

    fn runEnvelope(self: *Dsp, v: *Voice, vi: u3) void {
        var env: i32 = v.env;
        if (v.env_state == .release) {
            // Release ignores the rate counter: -8 every sample to zero.
            env -= 8;
            v.env = @intCast(@max(env, 0));
            return;
        }

        var rate: u5 = undefined;
        const adsr0 = self.vreg(vi, 0x5);
        var env_data: u8 = self.vreg(vi, 0x6);
        if (adsr0 & 0x80 != 0) { // ADSR
            if (v.env_state != .attack) { // decay or sustain: exponential
                env -= 1;
                env -= env >> 8;
                rate = @truncate(env_data & 0x1F);
                if (v.env_state == .decay) rate = @truncate(((adsr0 >> 3) & 0x0E) + 0x10);
            } else {
                const ar: u8 = adsr0 & 0x0F;
                rate = @truncate(ar * 2 + 1);
                env += if (rate < 31) 0x20 else 0x400;
            }
        } else { // GAIN
            env_data = self.vreg(vi, 0x7);
            const mode = env_data >> 5;
            if (mode < 4) { // direct
                env = @as(i32, env_data) * 0x10;
                rate = 31;
            } else {
                rate = @truncate(env_data & 0x1F);
                switch (mode) {
                    4 => env -= 0x20, // linear decrease
                    5 => { // exponential decrease
                        env -= 1;
                        env -= env >> 8;
                    },
                    else => { // 6/7: linear increase (7 bends at 0x600)
                        env += 0x20;
                        if (mode > 6 and @as(u16, @bitCast(v.hidden_env)) >= 0x600)
                            env += 0x8 - 0x20;
                    },
                }
            }
        }

        // Sustain-level boundary (compares against ADSR2 in ADSR mode, GAIN
        // in gain mode — a hardware quirk worth keeping).
        if ((env >> 8) == (env_data >> 5) and v.env_state == .decay)
            v.env_state = .sustain;

        v.hidden_env = @truncate(env);

        if (env < 0 or env > 0x7FF) {
            env = if (env < 0) 0 else 0x7FF;
            if (v.env_state == .attack) v.env_state = .decay;
        }

        if (self.counterFires(rate)) v.env = @intCast(env);
    }

    // --- the per-sample pipeline ---------------------------------------------

    /// Produce one stereo output sample and run every voice, the envelopes,
    /// the noise LFSR, and the echo unit (which reads/writes `aram`).
    pub fn sample(self: *Dsp, aram: *[0x10000]u8) [2]i16 {
        const flg = self.regs[r_flg];

        // KON/KOF are honored every second sample; pending KON bits for
        // voices already being serviced are dropped (hardware latch order).
        self.every_other = !self.every_other;
        if (self.every_other) {
            self.new_kon &= ~self.kon;
            self.kon = self.new_kon;
            self.t_koff = self.regs[r_koff];
        }

        self.counter = if (self.counter == 0) counter_range - 1 else self.counter - 1;

        if (self.counterFires(@truncate(flg & 0x1F))) {
            const n: u32 = self.noise;
            const feedback = (n << 13) ^ (n << 14);
            self.noise = @intCast((feedback & 0x4000) ^ (n >> 1));
        }

        const dir = self.regs[r_dir];
        const pmon = self.regs[r_pmon] & 0xFE; // voice 0 has no previous voice
        const non = self.regs[r_non];
        const eon = self.regs[r_eon];

        var main_l: i32 = 0;
        var main_r: i32 = 0;
        var echo_l: i32 = 0;
        var echo_r: i32 = 0;
        var prev_out: i32 = 0; // previous voice's output, for pitch modulation

        for (0..8) |i| {
            const vi: u3 = @intCast(i);
            const vbit = @as(u8, 1) << vi;
            const v = &self.voices[vi];

            var pitch: i32 = @as(u16, self.vreg(vi, 0x2)) |
                (@as(u16, self.vreg(vi, 0x3) & 0x3F) << 8);
            if (pmon & vbit != 0) pitch += ((prev_out >> 5) * pitch) >> 10;

            // Sample-directory entry: start address while keying on, loop
            // address afterwards.
            const dir_addr = (@as(u16, dir) *% 0x100) +% (@as(u16, self.vreg(vi, 0x4)) *% 4);
            const brr_next: u16 = @bitCast(@as(i16, @intCast(read16(aram, if (v.kon_delay != 0) dir_addr else dir_addr +% 2))));

            var header = aram[v.brr_addr];
            if (v.kon_delay != 0) {
                if (v.kon_delay == 5) {
                    v.brr_addr = brr_next;
                    v.brr_offset = 1;
                    v.buf_pos = 0;
                    header = 0; // first-sample header is ignored
                    self.regs[r_endx] &= ~vbit;
                }
                // Envelope and pitch are held during the 5-sample startup;
                // three decode groups prime the ring buffer.
                v.env = 0;
                v.hidden_env = 0;
                v.kon_delay -= 1;
                v.interp_pos = if (v.kon_delay & 3 != 0) 0x4000 else 0;
                pitch = 0;
            }

            var out = interpolate(v);
            if (non & vbit != 0) out = trunc16(@as(i32, self.noise) * 2);

            const t_output = ((out * v.env) >> 11) & ~@as(i32, 1);
            self.regs[@as(u7, vi) * 0x10 + 0x8] = @intCast(v.env >> 4); // ENVX
            self.regs[@as(u7, vi) * 0x10 + 0x9] = @bitCast(@as(i8, @truncate(t_output >> 8))); // OUTX

            // Soft reset, or an end block without loop, silences immediately.
            if (flg & 0x80 != 0 or header & 3 == 1) {
                v.env_state = .release;
                v.env = 0;
            }

            if (self.every_other) {
                if (self.t_koff & vbit != 0) v.env_state = .release;
                if (self.kon & vbit != 0) {
                    v.kon_delay = 5;
                    v.env_state = .attack;
                }
            }

            if (v.kon_delay == 0) self.runEnvelope(v, vi);

            // Consume input samples: decode the next group once four have
            // been read, following the block's loop/end chain.
            if (v.interp_pos >= 0x4000) {
                decodeBrrGroup(v, aram, header);
                v.brr_offset += 2;
                if (v.brr_offset >= brr_block_size) {
                    v.brr_addr +%= brr_block_size;
                    if (header & 1 != 0) {
                        v.brr_addr = brr_next;
                        self.regs[r_endx] |= vbit;
                    }
                    v.brr_offset = 1;
                }
            }
            // Pitch modulation can drive the step slightly negative; the
            // position itself never goes below the current sample.
            v.interp_pos = @intCast(std.math.clamp((v.interp_pos & 0x3FFF) + pitch, 0, 0x7FFF));

            // Signed volume mix (negative = phase inversion; this carries
            // the Dolby Surround matrix).
            const amp_l = (t_output * signed(self.vreg(vi, 0x0))) >> 7;
            const amp_r = (t_output * signed(self.vreg(vi, 0x1))) >> 7;
            main_l = clamp16(main_l + amp_l);
            main_r = clamp16(main_r + amp_r);
            if (eon & vbit != 0) {
                echo_l = clamp16(echo_l + amp_l);
                echo_r = clamp16(echo_r + amp_r);
            }
            prev_out = t_output;
        }

        // --- echo unit -----------------------------------------------------
        const echo_ptr = (@as(u16, self.regs[r_esa]) *% 0x100) +% self.echo_offset;
        self.echo_hist_pos = (self.echo_hist_pos + 1) & 7;
        self.echo_hist[self.echo_hist_pos] = .{
            @intCast(read16(aram, echo_ptr) >> 1),
            @intCast(read16(aram, echo_ptr +% 2) >> 1),
        };

        var fir: [2]i32 = .{ 0, 0 };
        inline for (0..2) |ch| {
            // Taps 0-6 accumulate then truncate to 16 bits; tap 7 (the newest
            // sample) is truncated separately — hardware adder widths.
            var acc: i32 = 0;
            for (0..7) |t| {
                const h = self.echo_hist[(self.echo_hist_pos + t + 1) & 7][ch];
                acc += (@as(i32, h) * signed(self.regs[@intCast(t * 0x10 + 0x0F)])) >> 6;
            }
            acc = trunc16(acc);
            const h7 = self.echo_hist[self.echo_hist_pos][ch];
            acc += trunc16((@as(i32, h7) * signed(self.regs[0x7F])) >> 6);
            fir[ch] = clamp16(acc) & ~@as(i32, 1);
        }

        // Master out: signed master volume + signed echo volume.
        const out_l = clamp16(trunc16((main_l * signed(self.regs[r_mvoll])) >> 7) +
            trunc16((fir[0] * signed(self.regs[r_evoll])) >> 7));
        const out_r = clamp16(trunc16((main_r * signed(self.regs[r_mvolr])) >> 7) +
            trunc16((fir[1] * signed(self.regs[r_evolr])) >> 7));

        // Echo feedback written back into ARAM (games place the echo region
        // deliberately; FLG bit5 gates the write, not the read).
        const efb = signed(self.regs[r_efb]);
        const wb_l = clamp16(echo_l + trunc16((fir[0] * efb) >> 7)) & ~@as(i32, 1);
        const wb_r = clamp16(echo_r + trunc16((fir[1] * efb) >> 7)) & ~@as(i32, 1);
        if (flg & 0x20 == 0) {
            writeEcho(aram, echo_ptr, @intCast(wb_l));
            writeEcho(aram, echo_ptr +% 2, @intCast(wb_r));
        }

        if (self.echo_offset == 0)
            self.echo_length = @as(u16, self.regs[r_edl] & 0x0F) *% 0x800;
        self.echo_offset +%= 4;
        if (self.echo_offset >= self.echo_length) self.echo_offset = 0;

        if (flg & 0x40 != 0) return .{ 0, 0 }; // FLG mute
        return .{ @intCast(out_l), @intCast(out_r) };
    }

    fn writeEcho(aram: *[0x10000]u8, addr: u16, value: i16) void {
        const u: u16 = @bitCast(value);
        aram[addr] = @truncate(u);
        aram[addr +% 1] = @truncate(u >> 8);
    }
};

// --- tests -------------------------------------------------------------------

test {
    std.testing.refAllDecls(@This());
}

test "gaussian kernel matches hardware spot values" {
    // Endpoints, center, and a spread of interior entries from the dump.
    try std.testing.expectEqual(@as(i16, 0), gauss[0]);
    try std.testing.expectEqual(@as(i16, 1), gauss[16]);
    try std.testing.expectEqual(@as(i16, 41), gauss[112]);
    try std.testing.expectEqual(@as(i16, 132), gauss[175]);
    try std.testing.expectEqual(@as(i16, 366), gauss[254]);
    try std.testing.expectEqual(@as(i16, 374), gauss[256]);
    try std.testing.expectEqual(@as(i16, 649), gauss[318]);
    try std.testing.expectEqual(@as(i16, 1106), gauss[416]);
    try std.testing.expectEqual(@as(i16, 1305), gauss[511]);
    // Monotone non-decreasing across the whole kernel.
    for (1..512) |i| try std.testing.expect(gauss[i] >= gauss[i - 1]);
}

/// Write a one-block looping BRR sample (filter 0) at `addr` whose decoded
/// samples are a constant `nibble << shift >> 1` staircase, plus a directory
/// entry for SRCN 0 pointing at it.
fn setupTestSample(aram: *[0x10000]u8, dir_page: u8, addr: u16, nibble: u4) void {
    const dir = @as(u16, dir_page) * 0x100;
    std.mem.writeInt(u16, aram[dir..][0..2], addr, .little); // start
    std.mem.writeInt(u16, aram[dir + 2 ..][0..2], addr, .little); // loop
    aram[addr] = 0xC0 | 0x03; // shift 12, filter 0, end+loop
    const byte = (@as(u8, nibble) << 4) | nibble;
    for (1..9) |i| aram[addr + i] = byte;
}

fn keyOnVoice0(dsp: *Dsp, dir_page: u8) void {
    dsp.write(0x5D, dir_page); // DIR
    dsp.write(0x04, 0); // V0 SRCN
    dsp.write(0x02, 0x00); // V0 pitch = 0x1000 (1:1)
    dsp.write(0x03, 0x10);
    dsp.write(0x05, 0x00); // ADSR disabled -> GAIN
    dsp.write(0x07, 0x7F); // GAIN direct, max (env 0x7F0)
    dsp.write(0x6C, 0x20); // FLG: echo writes off, no mute, no reset
    dsp.write(0x0C, 0x7F); // MVOL max
    dsp.write(0x1C, 0x7F);
    dsp.write(0x4C, 0x01); // KON voice 0
}

test "keyed-on BRR voice reaches a steady nonzero output" {
    const gpa = std.testing.allocator;
    const aram = try gpa.create([0x10000]u8);
    defer gpa.destroy(aram);
    @memset(aram, 0);
    setupTestSample(aram, 0x02, 0x1000, 4); // +4 << 12 >> 1 = +8192, doubled

    var dsp: Dsp = .init;
    keyOnVoice0(&dsp, 0x02);
    dsp.write(0x00, 0x40); // V0 VOLL +64
    dsp.write(0x01, 0x40); // V0 VOLR +64

    var last: [2]i16 = .{ 0, 0 };
    for (0..64) |_| last = dsp.sample(aram);
    try std.testing.expect(last[0] > 0);
    try std.testing.expectEqual(last[0], last[1]);
    // ENVX for voice 0 reflects the direct gain.
    try std.testing.expectEqual(@as(u8, 0x7F), dsp.read(0x08));
}

test "negative volume inverts phase (the Dolby Surround invariant)" {
    const gpa = std.testing.allocator;
    const aram = try gpa.create([0x10000]u8);
    defer gpa.destroy(aram);
    @memset(aram, 0);
    setupTestSample(aram, 0x02, 0x1000, 4);

    var dsp: Dsp = .init;
    keyOnVoice0(&dsp, 0x02);
    dsp.write(0x00, 0x40); // VOLL +64
    dsp.write(0x01, 0xC0); // VOLR -64: same magnitude, inverted phase

    var peak: i16 = 0;
    for (0..64) |_| {
        const s = dsp.sample(aram);
        // Anti-phase to within the master-volume floor rounding (±1); a
        // magnitude-clamped or unsigned mix would be off by thousands.
        try std.testing.expect(@abs(@as(i32, s[0]) + s[1]) <= 1);
        peak = @max(peak, s[0]);
    }
    try std.testing.expect(peak > 1000);
}

test "ADSR walks attack, decay, sustain and KOF releases" {
    const gpa = std.testing.allocator;
    const aram = try gpa.create([0x10000]u8);
    defer gpa.destroy(aram);
    @memset(aram, 0);
    setupTestSample(aram, 0x02, 0x1000, 0);

    var dsp: Dsp = .init;
    keyOnVoice0(&dsp, 0x02);
    dsp.write(0x05, 0x8F); // ADSR on, AR 15 (instant), DR 1
    dsp.write(0x06, 0x40); // SL 2 (boundary env>>8 == 2), SR 0 (hold)

    const st = &dsp.voices[0];
    for (0..8) |_| _ = dsp.sample(aram);
    try std.testing.expect(st.env_state == .decay or st.env_state == .attack);
    // AR 15 jumps 0x400/sample: full scale, then the exponential decay
    // (rate 16 = one step per 64 samples) walks down to the SL boundary.
    for (0..16384) |_| _ = dsp.sample(aram);
    try std.testing.expectEqual(EnvState.sustain, st.env_state);
    const sustain_env = st.env;
    // The state machine transitions on the recomputed envelope while `env`
    // itself only latches on counter fires, so the latched value can sit one
    // decay step above the SL boundary (0x2FF for SL 2) — hardware-exact.
    try std.testing.expect(sustain_env <= 0x310);
    for (0..256) |_| _ = dsp.sample(aram);
    try std.testing.expectEqual(sustain_env, st.env); // SR 0 holds

    dsp.write(0x5C, 0x01); // KOF
    for (0..300) |_| _ = dsp.sample(aram); // release ramps -8/sample
    try std.testing.expectEqual(@as(u16, 0), st.env);
    try std.testing.expectEqual(EnvState.release, st.env_state);
}

test "looping block sets ENDX and a write clears it" {
    const gpa = std.testing.allocator;
    const aram = try gpa.create([0x10000]u8);
    defer gpa.destroy(aram);
    @memset(aram, 0);
    setupTestSample(aram, 0x02, 0x1000, 4);

    var dsp: Dsp = .init;
    keyOnVoice0(&dsp, 0x02);
    for (0..64) |_| _ = dsp.sample(aram); // 16-sample block loops several times
    try std.testing.expectEqual(@as(u8, 0x01), dsp.read(0x7C));
    dsp.write(0x7C, 0xFF); // any write clears
    try std.testing.expectEqual(@as(u8, 0x00), dsp.read(0x7C));
}

test "noise LFSR replaces the voice sample deterministically" {
    const gpa = std.testing.allocator;
    const aram = try gpa.create([0x10000]u8);
    defer gpa.destroy(aram);
    @memset(aram, 0);
    setupTestSample(aram, 0x02, 0x1000, 0); // silent sample data

    var dsp: Dsp = .init;
    keyOnVoice0(&dsp, 0x02);
    dsp.write(0x00, 0x7F);
    dsp.write(0x01, 0x7F);
    dsp.write(0x3D, 0x01); // NON: voice 0 is noise
    dsp.write(0x6C, 0x3F); // FLG: echo off, noise rate 31 (every sample)

    var changed = false;
    var prev: i16 = 0;
    var any: i16 = 0;
    for (0..32) |i| {
        const s = dsp.sample(aram);
        if (i > 8 and s[0] != prev) changed = true;
        prev = s[0];
        any |= s[0];
    }
    try std.testing.expect(any != 0); // noise is audible
    try std.testing.expect(changed); // and moving
}

test "echo unit writes feedback into ARAM only when FLG allows" {
    const gpa = std.testing.allocator;
    const aram = try gpa.create([0x10000]u8);
    defer gpa.destroy(aram);
    @memset(aram, 0);
    setupTestSample(aram, 0x02, 0x1000, 4);

    var dsp: Dsp = .init;
    keyOnVoice0(&dsp, 0x02);
    dsp.write(0x00, 0x40); // V0 volumes (the echo mix taps the voice output)
    dsp.write(0x01, 0x40);
    dsp.write(0x4D, 0x01); // EON voice 0
    dsp.write(0x6D, 0xC0); // ESA: echo region at $C000
    dsp.write(0x7D, 0x01); // EDL: 2 KiB
    dsp.write(0x6C, 0x20); // FLG: echo writes DISABLED
    for (0..64) |_| _ = dsp.sample(aram);
    for (aram[0xC000..0xC800]) |b| try std.testing.expectEqual(@as(u8, 0), b);

    dsp.write(0x6C, 0x00); // enable echo writes
    for (0..64) |_| _ = dsp.sample(aram);
    var any: u8 = 0;
    for (aram[0xC000..0xC800]) |b| any |= b;
    try std.testing.expect(any != 0);
}
