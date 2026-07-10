//! libretro core entry points. Skeleton for now: exports the complete
//! required symbol set with stub behavior; real console wiring lands in M6.

const std = @import("std");
const core = @import("snes_core");
const api = @import("api.zig");

var cb_env: ?api.EnvironmentFn = null;
var cb_video: ?api.VideoRefreshFn = null;
var cb_audio_sample: ?api.AudioSampleFn = null;
var cb_audio_batch: ?api.AudioSampleBatchFn = null;
var cb_input_poll: ?api.InputPollFn = null;
var cb_input_state: ?api.InputStateFn = null;

export fn retro_api_version() c_uint {
    return api.api_version;
}

export fn retro_set_environment(cb: api.EnvironmentFn) void {
    cb_env = cb;
}

export fn retro_set_video_refresh(cb: api.VideoRefreshFn) void {
    cb_video = cb;
}

export fn retro_set_audio_sample(cb: api.AudioSampleFn) void {
    cb_audio_sample = cb;
}

export fn retro_set_audio_sample_batch(cb: api.AudioSampleBatchFn) void {
    cb_audio_batch = cb;
}

export fn retro_set_input_poll(cb: api.InputPollFn) void {
    cb_input_poll = cb;
}

export fn retro_set_input_state(cb: api.InputStateFn) void {
    cb_input_state = cb;
}

export fn retro_init() void {}

export fn retro_deinit() void {}

export fn retro_get_system_info(info: *api.SystemInfo) void {
    info.* = .{
        .library_name = "Yamabuki",
        .library_version = core.version,
        .valid_extensions = "sfc|smc",
        .need_fullpath = false,
        .block_extract = false,
    };
}

export fn retro_get_system_av_info(info: *api.SystemAvInfo) void {
    info.* = .{
        .geometry = .{
            .base_width = 256,
            .base_height = 224,
            .max_width = 512,
            .max_height = 478,
            .aspect_ratio = 4.0 / 3.0,
        },
        .timing = .{
            .fps = 60.0988,
            .sample_rate = @floatFromInt(core.timing.dsp_sample_hz),
        },
    };
}

export fn retro_set_controller_port_device(port: c_uint, device: c_uint) void {
    _ = port;
    _ = device;
}

export fn retro_reset() void {}

export fn retro_run() void {
    if (cb_input_poll) |poll| poll();
    // Console execution lands in M6.
}

export fn retro_serialize_size() usize {
    return 0;
}

export fn retro_serialize(data: ?*anyopaque, size: usize) bool {
    _ = data;
    _ = size;
    return false;
}

export fn retro_unserialize(data: ?*const anyopaque, size: usize) bool {
    _ = data;
    _ = size;
    return false;
}

export fn retro_cheat_reset() void {}

export fn retro_cheat_set(index: c_uint, enabled: bool, code: ?[*:0]const u8) void {
    _ = index;
    _ = enabled;
    _ = code;
}

export fn retro_load_game(game: ?*const api.GameInfo) bool {
    _ = game;
    return false; // no console yet
}

export fn retro_unload_game() void {}

export fn retro_get_region() c_uint {
    return api.region_ntsc;
}

export fn retro_load_game_special(game_type: c_uint, info: ?[*]const api.GameInfo, num_info: usize) bool {
    _ = game_type;
    _ = info;
    _ = num_info;
    return false;
}

export fn retro_get_memory_data(id: c_uint) ?*anyopaque {
    _ = id;
    return null;
}

export fn retro_get_memory_size(id: c_uint) usize {
    _ = id;
    return 0;
}
