//! SDL3 desktop frontend: the development-and-play UI.
//!
//!   yamabuki-sdl <rom.sfc> [--scale N] [--frames N] [--no-audio]
//!
//! Controls (RetroArch keyboard defaults):
//!   arrows = d-pad   Z = B   X = A   A = Y   S = X   Q = L   W = R
//!   Enter = Start    RShift = Select
//! Hotkeys:
//!   F5 save state (<rom>.state)   F9 load state   F1 reset
//!   Tab (hold) fast-forward       Esc quit
//!
//! Video is the console's native RGB565 framebuffer streamed into a texture
//! (recreated when the machine switches to hi-res/overscan dimensions) and
//! letterboxed onto a 512x(2*height) logical canvas — 256-wide frames scale
//! by an exact 2x, hi-res frames map 1:1. Audio goes to an SDL audio stream
//! at the DSP's native 32 kHz; the device side resamples. Pacing is a
//! nanosecond accumulator locked to the NTSC frame rate (~60.0988 Hz)
//! rather than display vsync, so a 144 Hz monitor doesn't fast-forward the
//! game. `--frames N` runs unattended and prints the same video/audio
//! hashes as the headless runner, which is how CI smoke-tests this frontend
//! under SDL's dummy drivers.

const std = @import("std");
const core = @import("snes_core");
const sdl3 = @import("sdl3.zig");

const Button = core.joypad.Button;

/// NTSC frame duration: 262 lines x 1364 master clocks at 21.477 MHz.
const frame_ns: u64 =
    core.timing.cycles_per_line * core.timing.ntsc_lines_per_frame *
    1_000_000_000 / core.timing.ntsc_master_hz;

/// If we fall further behind than this (state load, window drag), resync the
/// pacing clock instead of sprinting to catch up.
const max_lag_ns: u64 = 4 * frame_ns;

/// Fast-forward keeps at most this much audio queued (~1/4 s) and drops the
/// rest — the point is to skip ahead, not to build a backlog.
const ff_max_queued_bytes: c_int = 32 * 1024;

const Args = struct {
    rom: []const u8,
    scale: u32 = 3,
    frames: u32 = 0, // 0 = run until quit
    audio: bool = true,
};

const Keymap = struct { code: u32, mask: u16 };

/// RetroArch's default keyboard layout for a SNES pad.
const keymap = [_]Keymap{
    .{ .code = sdl3.scancode.up, .mask = Button.up },
    .{ .code = sdl3.scancode.down, .mask = Button.down },
    .{ .code = sdl3.scancode.left, .mask = Button.left },
    .{ .code = sdl3.scancode.right, .mask = Button.right },
    .{ .code = sdl3.scancode.z, .mask = Button.b },
    .{ .code = sdl3.scancode.x, .mask = Button.a },
    .{ .code = sdl3.scancode.a, .mask = Button.y },
    .{ .code = sdl3.scancode.s, .mask = Button.x },
    .{ .code = sdl3.scancode.q, .mask = Button.l },
    .{ .code = sdl3.scancode.w, .mask = Button.r },
    .{ .code = sdl3.scancode.ret, .mask = Button.start },
    .{ .code = sdl3.scancode.rshift, .mask = Button.select },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const err = &stderr_writer.interface;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const args = parseArgs(init) catch {
        try err.print("usage: yamabuki-sdl <rom.sfc> [--scale N] [--frames N] [--no-audio]\n", .{});
        try err.flush();
        std.process.exit(2);
    };

    const sdl = sdl3.load() catch |e| {
        try err.print("error: {s}\n", .{switch (e) {
            error.SdlNotFound => "SDL3 runtime not found — install SDL3 (libSDL3.so.0)",
            error.SdlTooOld => "found an SDL library, but it is not SDL3",
        }});
        try err.flush();
        std.process.exit(1);
    };

    // --- console ------------------------------------------------------------
    const image = std.Io.Dir.cwd().readFileAlloc(io, args.rom, gpa, .limited(16 * 1024 * 1024)) catch {
        try err.print("error: cannot read ROM '{s}'\n", .{args.rom});
        try err.flush();
        std.process.exit(1);
    };
    const cart = core.Cartridge.load(gpa, image) catch |e| {
        try err.print("error: cannot load ROM: {s}\n", .{@errorName(e)});
        try err.flush();
        std.process.exit(1);
    };
    const con = try gpa.create(core.FastConsole);
    con.init(cart);
    const state_buf = try gpa.alloc(u8, core.FastConsole.state_size);
    const state_path = try std.fmt.allocPrint(gpa, "{s}.state", .{args.rom});

    // --- SDL ----------------------------------------------------------------
    if (!sdl.SDL_Init(sdl3.init_video | sdl3.init_audio)) {
        try err.print("error: SDL_Init: {s}\n", .{sdl.SDL_GetError()});
        try err.flush();
        std.process.exit(1);
    }
    defer sdl.SDL_Quit();

    const window = sdl.SDL_CreateWindow(
        "Yamabuki",
        @intCast(256 * args.scale),
        @intCast(224 * args.scale),
        sdl3.window_resizable,
    ) orelse {
        try err.print("error: SDL_CreateWindow: {s}\n", .{sdl.SDL_GetError()});
        try err.flush();
        std.process.exit(1);
    };
    defer sdl.SDL_DestroyWindow(window);

    const renderer = sdl.SDL_CreateRenderer(window, null) orelse {
        try err.print("error: SDL_CreateRenderer: {s}\n", .{sdl.SDL_GetError()});
        try err.flush();
        std.process.exit(1);
    };
    defer sdl.SDL_DestroyRenderer(renderer);
    // Pacing is ours; a vsync'd present would re-pace the game to the display.
    _ = sdl.SDL_SetRenderVSync(renderer, 0);

    var audio: ?*sdl3.AudioStream = null;
    if (args.audio) {
        const spec: sdl3.AudioSpec = .{
            .format = sdl3.audio_s16le,
            .channels = 2,
            .freq = @intCast(core.timing.dsp_sample_hz),
        };
        if (sdl.SDL_OpenAudioDeviceStream(sdl3.audio_device_default_playback, &spec, null, null)) |stream| {
            audio = stream;
            _ = sdl.SDL_ResumeAudioStreamDevice(stream);
        } else {
            try err.print("warning: no audio device ({s}), running silent\n", .{sdl.SDL_GetError()});
            try err.flush();
        }
    }
    defer if (audio) |stream| sdl.SDL_DestroyAudioStream(stream);

    // --- main loop ----------------------------------------------------------
    var texture: ?*sdl3.Texture = null;
    defer if (texture) |t| sdl.SDL_DestroyTexture(t);
    var tex_w: u32 = 0;
    var tex_h: u32 = 0;

    var buttons: u16 = 0;
    var fast_forward = false;
    var running = true;
    var frames_run: u32 = 0;
    var audio_hash = core.console.audio_hash_init;
    var next_deadline = sdl.SDL_GetTicksNS() + frame_ns;

    while (running) {
        var ev: sdl3.Event = undefined;
        while (sdl.SDL_PollEvent(&ev)) {
            switch (ev.type) {
                sdl3.event_quit => running = false,
                sdl3.event_key_down, sdl3.event_key_up => {
                    const key = ev.key;
                    for (keymap) |k| {
                        if (k.code == key.scancode) {
                            if (key.down) buttons |= k.mask else buttons &= ~k.mask;
                        }
                    }
                    if (key.scancode == sdl3.scancode.tab) fast_forward = key.down;
                    if (key.down and !key.repeat) switch (key.scancode) {
                        sdl3.scancode.escape => running = false,
                        sdl3.scancode.f1 => con.init(con.cart),
                        sdl3.scancode.f5 => {
                            _ = con.saveState(state_buf);
                            if (std.Io.Dir.cwd().writeFile(io, .{ .sub_path = state_path, .data = state_buf })) {
                                try err.print("state saved: {s}\n", .{state_path});
                            } else |e| {
                                try err.print("state save failed: {s}\n", .{@errorName(e)});
                            }
                            try err.flush();
                        },
                        sdl3.scancode.f9 => {
                            if (loadStateFile(io, con, state_path, state_buf)) {
                                try err.print("state loaded: {s}\n", .{state_path});
                            } else |e| {
                                try err.print("state load failed: {s}\n", .{@errorName(e)});
                            }
                            try err.flush();
                        },
                        else => {},
                    };
                },
                else => {},
            }
        }

        con.setButtons(0, buttons);
        con.runFrame();
        frames_run += 1;

        // Video: native RGB565 straight into a streaming texture.
        const fb = con.framebuffer();
        const width = con.frameWidth();
        const height: u32 = @intCast(fb.len / width);
        if (texture == null or width != tex_w or height != tex_h) {
            if (texture) |t| sdl.SDL_DestroyTexture(t);
            texture = sdl.SDL_CreateTexture(
                renderer,
                sdl3.pixel_format_rgb565,
                sdl3.texture_access_streaming,
                @intCast(width),
                @intCast(height),
            ) orelse {
                try err.print("error: SDL_CreateTexture: {s}\n", .{sdl.SDL_GetError()});
                try err.flush();
                std.process.exit(1);
            };
            _ = sdl.SDL_SetTextureScaleMode(texture.?, sdl3.scale_mode_nearest);
            // 256-wide frames scale 2x onto the canvas, hi-res maps 1:1; the
            // canvas keeps the SNES 8:7 shape and letterboxes into the window.
            _ = sdl.SDL_SetRenderLogicalPresentation(
                renderer,
                512,
                @intCast(height * 2),
                sdl3.logical_presentation_letterbox,
            );
            tex_w = width;
            tex_h = height;
        }
        _ = sdl.SDL_UpdateTexture(texture.?, null, fb.ptr, @intCast(width * 2));
        _ = sdl.SDL_RenderClear(renderer);
        _ = sdl.SDL_RenderTexture(renderer, texture.?, null, null);
        _ = sdl.SDL_RenderPresent(renderer);

        // Audio: drain the console ring into the SDL stream.
        var drain: [4096]i16 = undefined;
        while (true) {
            const n = con.readAudio(&drain);
            if (n == 0) break;
            audio_hash = core.console.hashAudio(audio_hash, drain[0..n]);
            if (audio) |stream| {
                if (!fast_forward or sdl.SDL_GetAudioStreamQueued(stream) < ff_max_queued_bytes)
                    _ = sdl.SDL_PutAudioStreamData(stream, &drain, @intCast(n * 2));
            }
        }

        if (args.frames != 0 and frames_run >= args.frames) running = false;

        // Pacing: sleep up to the next NTSC frame boundary.
        if (fast_forward or args.frames != 0) {
            next_deadline = sdl.SDL_GetTicksNS() + frame_ns;
        } else {
            const now = sdl.SDL_GetTicksNS();
            if (now < next_deadline) sdl.SDL_DelayNS(next_deadline - now);
            next_deadline += frame_ns;
            if (now > next_deadline + max_lag_ns) next_deadline = now + frame_ns;
        }
    }

    // Same report format as the headless runner so smoke tests can assert
    // the golden hashes through the SDL path.
    const fb = con.framebuffer();
    const width = con.frameWidth();
    try out.print("{s}: {} frames, {}x{}, hash={x:0>16}, audio={x:0>16}\n", .{
        args.rom, frames_run, width, fb.len / width, core.console.hashFrame(fb), audio_hash,
    });
    try out.flush();
}

fn loadStateFile(io: std.Io, con: *core.FastConsole, path: []const u8, buf: []u8) !void {
    const data = try std.Io.Dir.cwd().readFile(io, path, buf);
    try con.loadState(data);
}

fn parseArgs(init: std.process.Init) !Args {
    var it = init.minimal.args.iterate();
    _ = it.skip(); // program name
    var args: Args = .{ .rom = undefined };
    var rom: ?[]const u8 = null;
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--scale")) {
            const v = it.next() orelse return error.MissingValue;
            args.scale = try std.fmt.parseInt(u32, v, 10);
            if (args.scale == 0 or args.scale > 8) return error.BadScale;
        } else if (std.mem.eql(u8, a, "--frames")) {
            const v = it.next() orelse return error.MissingValue;
            args.frames = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, a, "--no-audio")) {
            args.audio = false;
        } else if (rom == null) {
            rom = a;
        } else return error.TooManyArgs;
    }
    args.rom = rom orelse return error.NoRom;
    return args;
}
