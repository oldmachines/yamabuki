//! libretro core: the complete stable-ABI v1 entry-point set over
//! `core.FastConsole`. Pure Zig, no libc — allocation goes through the page
//! allocator, and the framebuffer is RGB565 exactly as libretro wants it, so
//! frames are handed over without conversion.
//!
//! Functions are `pub export`: exported for the shared library, `pub` so the
//! in-tree harness (`zig build test-libretro`) can drive the same code paths
//! that RetroArch does.

const std = @import("std");
const core = @import("snes_core");
pub const api = @import("api.zig");

const Button = core.joypad.Button;

var cb_env: ?api.EnvironmentFn = null;
var cb_video: ?api.VideoRefreshFn = null;
var cb_audio_sample: ?api.AudioSampleFn = null;
var cb_audio_batch: ?api.AudioSampleBatchFn = null;
var cb_input_poll: ?api.InputPollFn = null;
var cb_input_state: ?api.InputStateFn = null;

const gpa = std.heap.page_allocator;

/// Loaded-game state: the console is heap-pinned (it is self-referential and
/// must never move). Cartridge.load copies the ROM into its own padded
/// allocation, so libretro's transient data pointer is safe to load from.
var console: ?*core.FastConsole = null;

/// retro joypad id -> SNES button mask, indexed by RETRO_DEVICE_ID_JOYPAD_*.
const button_map = [12]u16{
    Button.b, // 0 B
    Button.y, // 1 Y
    Button.select, // 2 Select
    Button.start, // 3 Start
    Button.up, // 4 Up
    Button.down, // 5 Down
    Button.left, // 6 Left
    Button.right, // 7 Right
    Button.a, // 8 A
    Button.x, // 9 X
    Button.l, // 10 L
    Button.r, // 11 R
};

pub export fn retro_api_version() c_uint {
    return api.api_version;
}

pub export fn retro_set_environment(cb: api.EnvironmentFn) void {
    cb_env = cb;
}

pub export fn retro_set_video_refresh(cb: api.VideoRefreshFn) void {
    cb_video = cb;
}

pub export fn retro_set_audio_sample(cb: api.AudioSampleFn) void {
    cb_audio_sample = cb;
}

pub export fn retro_set_audio_sample_batch(cb: api.AudioSampleBatchFn) void {
    cb_audio_batch = cb;
}

pub export fn retro_set_input_poll(cb: api.InputPollFn) void {
    cb_input_poll = cb;
}

pub export fn retro_set_input_state(cb: api.InputStateFn) void {
    cb_input_state = cb;
}

pub export fn retro_init() void {}

pub export fn retro_deinit() void {}

pub export fn retro_get_system_info(info: *api.SystemInfo) void {
    info.* = .{
        .library_name = "Yamabuki",
        .library_version = core.version,
        .valid_extensions = "sfc|smc",
        .need_fullpath = false,
        .block_extract = false,
    };
}

pub export fn retro_get_system_av_info(info: *api.SystemAvInfo) void {
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

pub export fn retro_set_controller_port_device(port: c_uint, device: c_uint) void {
    _ = port;
    _ = device;
}

pub export fn retro_reset() void {
    // Re-power the machine in place; the cartridge (including battery SRAM)
    // is owned by the console and survives the re-init.
    const con = console orelse return;
    const cart = con.cart;
    con.init(cart);
}

pub export fn retro_run() void {
    const con = console orelse return;

    if (cb_input_poll) |poll| poll();
    if (cb_input_state) |input| {
        for (0..2) |port| {
            var mask: u16 = 0;
            for (button_map, 0..) |bit, id| {
                if (input(@intCast(port), api.device_joypad, 0, @intCast(id)) != 0)
                    mask |= bit;
            }
            con.setButtons(@intCast(port), mask);
        }
    }

    con.runFrame();

    if (cb_video) |video| {
        const fb = con.framebuffer();
        const width = con.frameWidth();
        video(fb.ptr, width, @intCast(fb.len / width), width * 2);
    }
    if (cb_audio_batch) |batch| {
        var buf: [4096]i16 = undefined;
        while (true) {
            const n = con.readAudio(&buf);
            if (n == 0) break;
            _ = batch(&buf, n / 2);
        }
    }
}

pub export fn retro_serialize_size() usize {
    return core.FastConsole.state_size;
}

pub export fn retro_serialize(data: ?*anyopaque, size: usize) bool {
    const con = console orelse return false;
    if (size < core.FastConsole.state_size) return false;
    const out: [*]u8 = @ptrCast(data orelse return false);
    _ = con.saveState(out[0..core.FastConsole.state_size]);
    return true;
}

pub export fn retro_unserialize(data: ?*const anyopaque, size: usize) bool {
    const con = console orelse return false;
    const in: [*]const u8 = @ptrCast(data orelse return false);
    con.loadState(in[0..size]) catch return false;
    return true;
}

pub export fn retro_cheat_reset() void {}

pub export fn retro_cheat_set(index: c_uint, enabled: bool, code: ?[*:0]const u8) void {
    _ = index;
    _ = enabled;
    _ = code;
}

pub export fn retro_load_game(game: ?*const api.GameInfo) bool {
    const info = game orelse return false;
    const data: [*]const u8 = @ptrCast(info.data orelse return false);
    if (info.size == 0) return false;

    // The frontend must accept RGB565 — it is the native framebuffer format.
    if (cb_env) |env| {
        var fmt: c_uint = api.pixel_format_rgb565;
        if (!env(api.env_set_pixel_format, &fmt)) return false;
    }

    unloadGame();
    var cart = core.Cartridge.load(gpa, data[0..info.size]) catch return false;
    const con = gpa.create(core.FastConsole) catch {
        cart.deinit(gpa);
        return false;
    };
    con.init(cart);
    console = con;
    return true;
}

fn unloadGame() void {
    if (console) |con| {
        con.cart.deinit(gpa);
        gpa.destroy(con);
        console = null;
    }
}

pub export fn retro_unload_game() void {
    unloadGame();
}

pub export fn retro_get_region() c_uint {
    return api.region_ntsc;
}

pub export fn retro_load_game_special(game_type: c_uint, info: ?[*]const api.GameInfo, num_info: usize) bool {
    _ = game_type;
    _ = info;
    _ = num_info;
    return false;
}

pub export fn retro_get_memory_data(id: c_uint) ?*anyopaque {
    const con = console orelse return null;
    return switch (id) {
        api.memory_save_ram => if (con.cart.hasSram()) @ptrCast(&con.cart.sram) else null,
        api.memory_system_ram => @ptrCast(&con.bus.wram.data),
        else => null,
    };
}

pub export fn retro_get_memory_size(id: c_uint) usize {
    const con = console orelse return 0;
    return switch (id) {
        api.memory_save_ram => if (con.cart.hasSram()) con.cart.sram_mask + 1 else 0,
        api.memory_system_ram => con.bus.wram.data.len,
        else => 0,
    };
}
