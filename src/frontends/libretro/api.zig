//! Hand-ported subset of the libretro API (stable ABI v1).
//! Ported from libretro.h so the core builds with zero C headers.

pub const api_version: c_uint = 1;

// retro_get_region
pub const region_ntsc: c_uint = 0;
pub const region_pal: c_uint = 1;

// retro_pixel_format (RETRO_ENVIRONMENT_SET_PIXEL_FORMAT)
pub const pixel_format_rgb565: c_uint = 2;

// Environment commands (subset we use)
pub const env_set_pixel_format: c_uint = 10;
pub const env_get_variable: c_uint = 15;
pub const env_set_variables: c_uint = 16;
pub const env_get_variable_update: c_uint = 17;

// Joypad device and button ids
pub const device_joypad: c_uint = 1;
pub const device_id_joypad_b: c_uint = 0;
pub const device_id_joypad_y: c_uint = 1;
pub const device_id_joypad_select: c_uint = 2;
pub const device_id_joypad_start: c_uint = 3;
pub const device_id_joypad_up: c_uint = 4;
pub const device_id_joypad_down: c_uint = 5;
pub const device_id_joypad_left: c_uint = 6;
pub const device_id_joypad_right: c_uint = 7;
pub const device_id_joypad_a: c_uint = 8;
pub const device_id_joypad_x: c_uint = 9;
pub const device_id_joypad_l: c_uint = 10;
pub const device_id_joypad_r: c_uint = 11;

// Memory types (retro_get_memory_data/size)
pub const memory_save_ram: c_uint = 0;
pub const memory_system_ram: c_uint = 2;

pub const SystemInfo = extern struct {
    library_name: ?[*:0]const u8,
    library_version: ?[*:0]const u8,
    valid_extensions: ?[*:0]const u8,
    need_fullpath: bool,
    block_extract: bool,
};

pub const GameGeometry = extern struct {
    base_width: c_uint,
    base_height: c_uint,
    max_width: c_uint,
    max_height: c_uint,
    aspect_ratio: f32,
};

pub const SystemTiming = extern struct {
    fps: f64,
    sample_rate: f64,
};

pub const SystemAvInfo = extern struct {
    geometry: GameGeometry,
    timing: SystemTiming,
};

pub const GameInfo = extern struct {
    path: ?[*:0]const u8,
    data: ?*const anyopaque,
    size: usize,
    meta: ?[*:0]const u8,
};

pub const Variable = extern struct {
    key: ?[*:0]const u8,
    value: ?[*:0]const u8,
};

pub const EnvironmentFn = *const fn (cmd: c_uint, data: ?*anyopaque) callconv(.c) bool;
pub const VideoRefreshFn = *const fn (data: ?*const anyopaque, width: c_uint, height: c_uint, pitch: usize) callconv(.c) void;
pub const AudioSampleFn = *const fn (left: i16, right: i16) callconv(.c) void;
pub const AudioSampleBatchFn = *const fn (data: ?[*]const i16, frames: usize) callconv(.c) usize;
pub const InputPollFn = *const fn () callconv(.c) void;
pub const InputStateFn = *const fn (port: c_uint, device: c_uint, index: c_uint, id: c_uint) callconv(.c) i16;
