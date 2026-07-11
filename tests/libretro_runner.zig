//! libretro harness (`zig build test-libretro`): drives the core's exported
//! retro_* entry points exactly the way RetroArch would — environment
//! negotiation, load, per-frame video/audio/input callbacks, serialization —
//! and checks the output against the same golden expectations the direct
//! console path is locked to:
//!
//!   1. Axel-F through retro_run must reproduce the golden framebuffer hash
//!      AND the golden audio-stream hash (proves the video/audio callback
//!      plumbing is lossless).
//!   2. RotZoom must reproduce its golden hash with a neutral pad, and a
//!      *different* hash with R held (proves input reaches the machine).
//!   3. retro_serialize at mid-run, run on, retro_unserialize, run again:
//!      the replayed segment must reproduce the same final frame (proves
//!      save states restore mid-game, the M6 gate).
//!   4. Reload with the yamabuki_accuracy core option set to "accurate":
//!      the accurate core must reproduce the same golden hashes through the
//!      whole retro_* surface (proves the option reaches the machine).
//!
//! Requires test-data/snes-roms (tools/fetch_test_data.sh).

const std = @import("std");
const core = @import("snes_core");
const lr = @import("libretro");
const api = lr.api;

const rom_root = "test-data/snes-roms";

// Golden expectations (mirrors tests/golden_hashes.zon).
const axelf_frames = 60;
const axelf_hash: u64 = 0x045b5aaabee52325;
const axelf_audio: u64 = 0xe2fbd615d2d54f15;
const rotzoom_frames = 16;
const rotzoom_hash: u64 = 0x8ba211f2fc899f95;

// --- frontend-side callback state --------------------------------------------

var last_frame_hash: u64 = 0;
var audio_hash: u64 = core.console.audio_hash_init;
var retro_buttons: u16 = 0; // bit N = RETRO_DEVICE_ID_JOYPAD_N held (port 0)
var announced_accuracy_option = false;
var want_accurate = false; // frontend-side value of yamabuki_accuracy

fn envCb(cmd: c_uint, data: ?*anyopaque) callconv(.c) bool {
    switch (cmd) {
        api.env_set_pixel_format => {
            const fmt: *c_uint = @ptrCast(@alignCast(data.?));
            return fmt.* == api.pixel_format_rgb565;
        },
        api.env_set_variables => {
            const vars: [*]const api.Variable = @ptrCast(@alignCast(data.?));
            var i: usize = 0;
            while (vars[i].key) |key| : (i += 1) {
                if (std.mem.eql(u8, std.mem.span(key), "yamabuki_accuracy"))
                    announced_accuracy_option = true;
            }
            return true;
        },
        api.env_get_variable => {
            const v: *api.Variable = @ptrCast(@alignCast(data.?));
            const key = v.key orelse return false;
            if (!std.mem.eql(u8, std.mem.span(key), "yamabuki_accuracy")) return false;
            v.value = if (want_accurate) "accurate" else "fast";
            return true;
        },
        else => return false,
    }
}

fn videoCb(data: ?*const anyopaque, width: c_uint, height: c_uint, pitch: usize) callconv(.c) void {
    const px: [*]const u16 = @ptrCast(@alignCast(data.?));
    std.debug.assert(pitch == width * 2); // core hands over its fb directly
    last_frame_hash = core.console.hashFrame(px[0 .. width * height]);
}

fn audioBatchCb(data: ?[*]const i16, frames: usize) callconv(.c) usize {
    audio_hash = core.console.hashAudio(audio_hash, data.?[0 .. frames * 2]);
    return frames;
}

fn audioSampleCb(left: i16, right: i16) callconv(.c) void {
    _ = left;
    _ = right;
}

fn inputPollCb() callconv(.c) void {}

fn inputStateCb(port: c_uint, device: c_uint, index: c_uint, id: c_uint) callconv(.c) i16 {
    _ = index;
    if (port != 0 or device != api.device_joypad or id > 11) return 0;
    return @intCast((retro_buttons >> @intCast(id)) & 1);
}

// --- harness ------------------------------------------------------------------

fn loadGame(image: []const u8) bool {
    const info: api.GameInfo = .{
        .path = null,
        .data = image.ptr,
        .size = image.len,
        .meta = null,
    };
    return lr.retro_load_game(&info);
}

fn check(out: *std.Io.Writer, ok: bool, what: []const u8, failed: *u32) !void {
    try out.print("{s} {s}\n", .{ if (ok) "PASS" else "FAIL", what });
    if (!ok) failed.* += 1;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;
    var failed: u32 = 0;

    var dir = std.Io.Dir.cwd().openDir(io, rom_root, .{}) catch {
        try out.print("error: {s} missing; run tools/fetch_test_data.sh first\n", .{rom_root});
        try out.flush();
        std.process.exit(2);
    };
    defer dir.close(io);

    lr.retro_set_environment(&envCb);
    lr.retro_set_video_refresh(&videoCb);
    lr.retro_set_audio_sample(&audioSampleCb);
    lr.retro_set_audio_sample_batch(&audioBatchCb);
    lr.retro_set_input_poll(&inputPollCb);
    lr.retro_set_input_state(&inputStateCb);
    lr.retro_init();

    try check(out, lr.retro_api_version() == 1, "api version 1", &failed);
    try check(out, announced_accuracy_option, "yamabuki_accuracy core option announced", &failed);

    // --- 1. Axel-F: video + audio through the callback plumbing ------------
    {
        const image = try dir.readFileAlloc(io, "SPC700/Axel-F/Axel-F.sfc", gpa, .limited(16 * 1024 * 1024));
        try check(out, loadGame(image), "load Axel-F", &failed);
        audio_hash = core.console.audio_hash_init;
        for (0..axelf_frames) |_| lr.retro_run();
        try check(out, last_frame_hash == axelf_hash, "Axel-F video hash matches golden", &failed);
        try check(out, audio_hash == axelf_audio, "Axel-F audio hash matches golden", &failed);

        // System RAM is exposed; this cart has no battery SRAM.
        try check(out, lr.retro_get_memory_size(api.memory_system_ram) == 0x2_0000, "system RAM size", &failed);
        try check(out, lr.retro_get_memory_data(api.memory_save_ram) == null, "no SRAM exposed for SRAM-less cart", &failed);
        lr.retro_unload_game();
    }

    // --- 2. RotZoom: input reaches the machine ------------------------------
    {
        const image = try dir.readFileAlloc(io, "PPU/Mode7/RotZoom/RotZoom.sfc", gpa, .limited(16 * 1024 * 1024));
        try check(out, loadGame(image), "load RotZoom", &failed);
        retro_buttons = 0;
        for (0..rotzoom_frames) |_| lr.retro_run();
        try check(out, last_frame_hash == rotzoom_hash, "RotZoom neutral-pad hash matches golden", &failed);

        lr.retro_reset();
        retro_buttons = 1 << 11; // hold R (zoom)
        for (0..rotzoom_frames) |_| lr.retro_run();
        try check(out, last_frame_hash != rotzoom_hash, "RotZoom diverges with R held", &failed);
        retro_buttons = 0;
        lr.retro_unload_game();
    }

    // --- 3. Mid-run save state restores deterministically -------------------
    {
        const image = try dir.readFileAlloc(io, "SPC700/Axel-F/Axel-F.sfc", gpa, .limited(16 * 1024 * 1024));
        try check(out, loadGame(image), "reload Axel-F for save states", &failed);

        const size = lr.retro_serialize_size();
        try check(out, size == core.FastConsole.state_size, "serialize size is the container size", &failed);
        const state = try gpa.alloc(u8, size);

        for (0..30) |_| lr.retro_run();
        try check(out, lr.retro_serialize(state.ptr, state.len), "serialize at frame 30", &failed);

        for (0..30) |_| lr.retro_run();
        const first_pass = last_frame_hash;

        try check(out, lr.retro_unserialize(state.ptr, state.len), "unserialize back to frame 30", &failed);
        for (0..30) |_| lr.retro_run();
        try check(out, last_frame_hash == first_pass, "replayed segment reproduces frame 60", &failed);

        // A corrupted header must be rejected without killing the session.
        state[0] ^= 0xFF;
        try check(out, !lr.retro_unserialize(state.ptr, state.len), "corrupt state rejected", &failed);
        lr.retro_unload_game();
    }

    // --- 4. The accuracy core option reaches the machine --------------------
    {
        const image = try dir.readFileAlloc(io, "SPC700/Axel-F/Axel-F.sfc", gpa, .limited(16 * 1024 * 1024));
        want_accurate = true;
        try check(out, loadGame(image), "load Axel-F with yamabuki_accuracy=accurate", &failed);
        audio_hash = core.console.audio_hash_init;
        for (0..axelf_frames) |_| lr.retro_run();
        try check(out, last_frame_hash == axelf_hash, "accurate-core video hash matches golden", &failed);
        try check(out, audio_hash == axelf_audio, "accurate-core audio hash matches golden", &failed);
        want_accurate = false;
        lr.retro_unload_game();
    }

    try out.print("\nlibretro-runner: {} failed\n", .{failed});
    try out.flush();
    if (failed > 0) std.process.exit(1);
}
