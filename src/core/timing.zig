//! Master-clock timing constants. All component clocks divide the master
//! clock, and all scheduling is expressed in master cycles (u64).

const std = @import("std");

pub const Region = enum { ntsc, pal };

/// NTSC master clock: 315/88 MHz * 6 = 21.477272... MHz.
pub const ntsc_master_hz: u64 = 21_477_272;
/// PAL master clock.
pub const pal_master_hz: u64 = 21_281_370;

/// Master cycles per scanline (both regions).
pub const cycles_per_line: u64 = 1364;
/// Dots per scanline; one dot = 4 master cycles (except two 6-cycle dots).
pub const dots_per_line: u32 = 341;
/// Master cycles per dot (the accurate core's beam arithmetic treats every
/// dot as 4 cycles; the two long dots are a sub-pixel refinement it skips).
pub const cycles_per_dot: u64 = 4;
/// The dot at which output pixel 0 leaves the PPU (dots 0-21 are setup /
/// left border).
pub const render_start_dot: u64 = 22;

pub const ntsc_lines_per_frame: u32 = 262;
pub const pal_lines_per_frame: u32 = 312;

/// Header region-byte codes ($xxD9) that run at 60 Hz; every other code is a
/// PAL territory (50 Hz). Per the SNES dev manual's region table: Japan, the
/// US, Korea, Canada, and Brazil are NTSC — the rest (Europe and other PAL
/// territories) are PAL.
const ntsc_region_bytes = [_]u8{ 0x00, 0x01, 0x0D, 0x0F, 0x10 };

/// Map a cart header's region byte to NTSC/PAL timing.
pub fn regionFromHeaderByte(byte: u8) Region {
    for (ntsc_region_bytes) |b| {
        if (b == byte) return .ntsc;
    }
    return .pal;
}

/// Visible scanlines with overscan off / on.
pub const visible_lines_224: u32 = 224;
pub const visible_lines_239: u32 = 239;

/// First scanline of vblank when overscan is off (224-line display).
pub const vblank_line_224: u32 = visible_lines_224 + 1;
/// First scanline of vblank when overscan is on (239-line display).
pub const vblank_line_239: u32 = visible_lines_239 + 1;

/// CPU clock divider relative to master clock for internal operations.
pub const cpu_internal_divider: u32 = 6;

/// Memory access speeds in master cycles per bus access.
pub const speed_fast: u8 = 6; // internal, most MMIO, FastROM
pub const speed_slow: u8 = 8; // WRAM, SlowROM, most cart space
pub const speed_xslow: u8 = 12; // $4000-$41FF (controller ports)

/// SPC700 nominal clock (runs off its own 24.576 MHz-derived clock).
pub const spc700_hz: u64 = 1_024_000;
/// S-DSP output sample rate.
pub const dsp_sample_hz: u32 = 32_000;

test "regionFromHeaderByte: NTSC codes" {
    for ([_]u8{ 0x00, 0x01, 0x0D, 0x0F, 0x10 }) |b| {
        try std.testing.expectEqual(Region.ntsc, regionFromHeaderByte(b));
    }
}

test "regionFromHeaderByte: PAL codes" {
    // 0x02 Europe (DKC2/Secret of Mana (E)), plus a scattering of the other
    // PAL-territory codes and the unassigned tail.
    for ([_]u8{ 0x02, 0x03, 0x09, 0x0A, 0x11, 0xFF }) |b| {
        try std.testing.expectEqual(Region.pal, regionFromHeaderByte(b));
    }
}
