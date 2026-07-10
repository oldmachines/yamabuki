//! Master-clock timing constants. All component clocks divide the master
//! clock, and all scheduling is expressed in master cycles (u64).

pub const Region = enum { ntsc, pal };

/// NTSC master clock: 315/88 MHz * 6 = 21.477272... MHz.
pub const ntsc_master_hz: u64 = 21_477_272;
/// PAL master clock.
pub const pal_master_hz: u64 = 21_281_370;

/// Master cycles per scanline (both regions).
pub const cycles_per_line: u64 = 1364;
/// Dots per scanline; one dot = 4 master cycles (except two 6-cycle dots).
pub const dots_per_line: u32 = 341;

pub const ntsc_lines_per_frame: u32 = 262;
pub const pal_lines_per_frame: u32 = 312;

/// First scanline of vblank when overscan is off (224-line display).
pub const vblank_line_224: u32 = 225;
/// First scanline of vblank when overscan is on (239-line display).
pub const vblank_line_239: u32 = 240;

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
