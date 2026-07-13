//! SDL3 desktop frontend: the development-and-play UI.
//!
//!   yamabuki-sdl <rom.sfc> [--scale N] [--frames N] [--no-audio] [--accurate]
//!
//! Controls (RetroArch keyboard defaults):
//!   arrows = d-pad   Z = B   X = A   A = Y   S = X   Q = L   W = R
//!   Enter = Start    RShift = Select
//! Hotkeys:
//!   F5 save state (<rom>.state)   F9 load state   F1 reset
//!   Tab (hold) fast-forward       Esc quit
//!   , / .  cycle shaders (only the presets baked for this GPU's profile)
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
const gl = @import("gl.zig");
const preset = @import("preset.zig");
const shader = @import("shader.zig");

const Button = core.joypad.Button;

/// A GL context plus the loaded shader chain. Absent means the software blit.
///
/// The chain is swappable at runtime: `,` and `.` walk every preset baked for
/// the profile we actually got, so the cycle can only ever land on a shader
/// this GPU can compile.
const GlVideo = struct {
    sdl_gl: sdl3.GlApi,
    ctx: *sdl3.GlContext,
    api: gl.Api,
    gles_major: u32,
    /// Two chain slots. A Preset is ~280 KiB (crt-guest-advanced declares 148
    /// parameters), so a Chain is far too big to sit on the stack — building the
    /// replacement in the spare slot means cycling costs no allocation and no
    /// 280 KiB stack frame, and the incumbent survives a preset that fails.
    chains: [2]shader.Chain,
    active: u1,
    /// The baked profile directory the ladder resolved to, e.g. `shaders/essl300`.
    profile_dir: []const u8,
    /// Every preset in that directory, sorted — the cycle order.
    names: [][]const u8,
    index: usize,

    fn chain(self: *GlVideo) *shader.Chain {
        return &self.chains[self.active];
    }
};

/// Context attempts, best first. Each maps to a directory of baked GLSL: a
/// preset only appears under a profile if it actually transpiled and compiled
/// for it at bake time, so "the shader is listed" and "the shader will run" are
/// the same statement.
const Profile = struct {
    dir: []const u8,
    profile_mask: c_int,
    major: c_int,
    minor: c_int,
};

const profiles = [_]Profile{
    .{ .dir = "essl300", .profile_mask = sdl3.gl_profile_es, .major = 3, .minor = 0 },
    .{ .dir = "glsl330", .profile_mask = sdl3.gl_profile_core, .major = 3, .minor = 3 },
    .{ .dir = "essl100", .profile_mask = sdl3.gl_profile_es, .major = 2, .minor = 0 },
};

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
    accuracy: core.Accuracy = .fast,
    shader: ?[]const u8 = null,
    shader_dir: []const u8 = "shaders",
    /// `--shot <prefix>`: write `<prefix>-<frame>.ppm` at each frame in
    /// `shot_frames`. With a shader loaded this captures the *rendered* picture
    /// off the GPU; without one it dumps the console's framebuffer.
    shot: ?[]const u8 = null,
    shot_frames: []const u32 = &.{},
    /// `--patch <file>`: apply a BPS/IPS patch to the ROM in memory at load.
    /// BPS is CRC-verified both ways; IPS is applied with a printed warning.
    patch: ?[]const u8 = null,
};

/// Write 24-bit RGB as a binary PPM — the same format the headless runner emits,
/// so one converter handles both.
fn writePpm(io: std.Io, path: []const u8, w: u32, h: u32, rgb: []const u8) !void {
    var header: [64]u8 = undefined;
    const head = try std.fmt.bufPrint(&header, "P6\n{d} {d}\n255\n", .{ w, h });

    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(head);
    try writer.interface.writeAll(rgb);
    try writer.interface.flush();
}

/// The console's own framebuffer, RGB565 expanded to RGB888 — what you get when
/// no shader is loaded. The 5/6-bit channels are bit-replicated into 8 so white
/// stays white instead of landing on 0xF8.
fn framebufferRgb(gpa: std.mem.Allocator, fb: []const u16, w: u32, h: u32) ![]u8 {
    const rgb = try gpa.alloc(u8, @as(usize, w) * @as(usize, h) * 3);
    for (fb[0 .. @as(usize, w) * @as(usize, h)], 0..) |px, i| {
        const r5: u8 = @intCast((px >> 11) & 0x1F);
        const g6: u8 = @intCast((px >> 5) & 0x3F);
        const b5: u8 = @intCast(px & 0x1F);
        rgb[i * 3 + 0] = (r5 << 3) | (r5 >> 2);
        rgb[i * 3 + 1] = (g6 << 2) | (g6 >> 4);
        rgb[i * 3 + 2] = (b5 << 3) | (b5 >> 2);
    }
    return rgb;
}

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

    const args = parseArgs(init, gpa) catch {
        try err.print(
            "usage: yamabuki-sdl <rom.sfc> [--scale N] [--frames N] [--no-audio] [--accurate]\n" ++
                "                    [--shader NAME] [--shader-dir DIR] [--patch p.bps|p.ips]\n",
            .{},
        );
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
    var image = std.Io.Dir.cwd().readFileAlloc(io, args.rom, gpa, .limited(16 * 1024 * 1024)) catch {
        try err.print("error: cannot read ROM '{s}'\n", .{args.rom});
        try err.flush();
        std.process.exit(1);
    };
    if (args.patch) |patch_path| {
        const pbytes = std.Io.Dir.cwd().readFileAlloc(io, patch_path, gpa, .limited(16 * 1024 * 1024)) catch {
            try err.print("error: cannot read patch '{s}'\n", .{patch_path});
            try err.flush();
            std.process.exit(1);
        };
        var mm: core.patch.CrcMismatch = .{};
        const res = core.patch.apply(gpa, core.header.stripCopierHeader(image), pbytes, &mm) catch |e| {
            switch (e) {
                error.WrongSource => try err.print(
                    "error: patch '{s}' is for a different ROM revision: it wants source crc32 {x:0>8}, this ROM is {x:0>8}\n",
                    .{ patch_path, mm.expected, mm.actual },
                ),
                else => try err.print("error: cannot apply patch '{s}': {s}\n", .{ patch_path, @errorName(e) }),
            }
            try err.flush();
            std.process.exit(1);
        };
        if (!res.verified) {
            try err.print("warning: '{s}' is an IPS patch — no checksums, the result is unverified\n", .{patch_path});
            try err.flush();
        }
        image = res.image;
    }
    const cart = core.Cartridge.load(gpa, image) catch |e| {
        try err.print("error: cannot load ROM: {s}\n", .{@errorName(e)});
        try err.flush();
        std.process.exit(1);
    };
    const con = try gpa.create(core.AnyConsole);
    con.init(args.accuracy, cart);
    const state_buf = try gpa.alloc(u8, core.AnyConsole.state_size);
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
        sdl3.window_resizable | if (args.shader != null) sdl3.window_opengl else 0,
    ) orelse {
        try err.print("error: SDL_CreateWindow: {s}\n", .{sdl.SDL_GetError()});
        try err.flush();
        std.process.exit(1);
    };
    defer sdl.SDL_DestroyWindow(window);

    // Shaders are best-effort by construction. Every way this can fail — no GL
    // driver, a GLES2-only chip, a preset with no variant for the profile we
    // got — degrades to the software blit with a printed reason. A missing
    // shader must never cost the user the emulator.
    var glv: ?*GlVideo = null;
    if (args.shader) |name| {
        glv = initGl(io, gpa, window, args.shader_dir, name, err) catch |e| blk: {
            try err.print("shader '{s}' unavailable ({s}); falling back to the software renderer\n", .{ name, @errorName(e) });
            try err.flush();
            break :blk null;
        };
    }
    defer if (glv) |g| {
        g.chain().deinit();
        _ = g.sdl_gl.SDL_GL_DestroyContext(g.ctx);
    };

    // The software path is what runs when there is no shader chain — including
    // under CI's dummy video driver, which is why --frames still prints hashes.
    var renderer: ?*sdl3.Renderer = null;
    if (glv == null) {
        renderer = sdl.SDL_CreateRenderer(window, null) orelse {
            try err.print("error: SDL_CreateRenderer: {s}\n", .{sdl.SDL_GetError()});
            try err.flush();
            std.process.exit(1);
        };
        // Pacing is ours; a vsync'd present would re-pace the game to the display.
        _ = sdl.SDL_SetRenderVSync(renderer.?, 0);
    }
    defer if (renderer) |r| sdl.SDL_DestroyRenderer(r);

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
                        sdl3.scancode.f1 => con.repower(),
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
                        // Walk the presets baked for this GPU's profile. A no-op
                        // on the software path — there is nothing to cycle.
                        sdl3.scancode.comma => if (glv) |g| cycleShader(io, gpa, g, -1, err),
                        sdl3.scancode.period => if (glv) |g| cycleShader(io, gpa, g, 1, err),
                        else => {},
                    };
                },
                else => {},
            }
        }

        con.setButtons(0, buttons);
        con.runFrame();
        frames_run += 1;

        // Video: native RGB565, either through the shader chain or straight
        // into a streaming texture.
        const fb = con.framebuffer();
        const width = con.frameWidth();
        const height: u32 = @intCast(fb.len / width);

        if (glv) |g| {
            g.chain().upload(fb, width, height);
            var win_w: c_int = 0;
            var win_h: c_int = 0;
            _ = g.sdl_gl.SDL_GetWindowSizeInPixels(window, &win_w, &win_h);
            g.chain().render(.{ .w = @intCast(@max(1, win_w)), .h = @intCast(@max(1, win_h)) }) catch |e| {
                try err.print("error: shader render failed: {s}\n", .{@errorName(e)});
                try err.flush();
                std.process.exit(1);
            };
            // Grab the rendered frame *before* the swap, while the back buffer
            // still holds it.
            if (args.shot) |prefix| {
                if (wantsShot(args.shot_frames, frames_run)) {
                    const win: preset.Size = .{ .w = @intCast(@max(1, win_w)), .h = @intCast(@max(1, win_h)) };
                    if (g.chain().capture(gpa, win)) |img| {
                        const path = try std.fmt.allocPrint(gpa, "{s}-{d:0>5}.ppm", .{ prefix, frames_run });
                        writePpm(io, path, img.w, img.h, img.rgb) catch |e| {
                            try err.print("shot failed: {s}\n", .{@errorName(e)});
                        };
                    } else |e| {
                        try err.print("capture failed: {s}\n", .{@errorName(e)});
                    }
                    try err.flush();
                }
            }
            _ = g.sdl_gl.SDL_GL_SwapWindow(window);
        } else {
            const r = renderer.?;
            if (texture == null or width != tex_w or height != tex_h) {
                if (texture) |t| sdl.SDL_DestroyTexture(t);
                texture = sdl.SDL_CreateTexture(
                    r,
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
                    r,
                    512,
                    @intCast(height * 2),
                    sdl3.logical_presentation_letterbox,
                );
                tex_w = width;
                tex_h = height;
            }
            _ = sdl.SDL_UpdateTexture(texture.?, null, fb.ptr, @intCast(width * 2));
            _ = sdl.SDL_RenderClear(r);
            _ = sdl.SDL_RenderTexture(r, texture.?, null, null);
            _ = sdl.SDL_RenderPresent(r);

            // No shader: the console's framebuffer *is* the picture.
            if (args.shot) |prefix| {
                if (wantsShot(args.shot_frames, frames_run)) {
                    const rgb = try framebufferRgb(gpa, fb, width, height);
                    const path = try std.fmt.allocPrint(gpa, "{s}-{d:0>5}.ppm", .{ prefix, frames_run });
                    writePpm(io, path, width, height, rgb) catch |e| {
                        try err.print("shot failed: {s}\n", .{@errorName(e)});
                        try err.flush();
                    };
                }
            }
        }

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

/// Is `frame` one of the moments we were asked to capture? An empty list means
/// "the last frame only", which is what a bare `--shot` with `--frames N` wants.
fn wantsShot(frames: []const u32, frame: u32) bool {
    if (frames.len == 0) return false;
    for (frames) |f| {
        if (f == frame) return true;
    }
    return false;
}

fn loadStateFile(io: std.Io, con: *core.AnyConsole, path: []const u8, buf: []u8) !void {
    const data = try std.Io.Dir.cwd().readFile(io, path, buf);
    try con.loadState(data);
}

const InitGlError = error{ NoGlSymbols, NoContext, NoVariantForThisGpu };

/// Bring up a GL context and load `name` from the best profile the driver will
/// give us. Tries GLES 3, then desktop GL 3.3, then GLES 2 — and for each, only
/// accepts it if the preset actually has a baked variant for that profile.
///
/// A GLES2-only device therefore silently gets the GLES2 build of a shader that
/// has one, and a clear "not available for this GPU" for one that does not,
/// rather than a context it cannot compile the shader in.
fn initGl(
    io: std.Io,
    gpa: std.mem.Allocator,
    window: *sdl3.Window,
    shader_root: []const u8,
    name: []const u8,
    err: *std.Io.Writer,
) !*GlVideo {
    const sdl_gl = sdl3.loadGl() catch return InitGlError.NoGlSymbols;

    for (profiles) |prof| {
        // Which presets exist for this profile is the gate: no point holding a
        // context we cannot use. The listing doubles as the `,`/`.` cycle order.
        const profile_dir = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ shader_root, prof.dir });
        const names = listPresets(io, gpa, profile_dir) catch continue;
        const start = indexOfName(names, name) orelse continue;

        _ = sdl_gl.SDL_GL_SetAttribute(sdl3.gl_attr.context_profile_mask, prof.profile_mask);
        _ = sdl_gl.SDL_GL_SetAttribute(sdl3.gl_attr.context_major_version, prof.major);
        _ = sdl_gl.SDL_GL_SetAttribute(sdl3.gl_attr.context_minor_version, prof.minor);
        _ = sdl_gl.SDL_GL_SetAttribute(sdl3.gl_attr.doublebuffer, 1);
        _ = sdl_gl.SDL_GL_SetAttribute(sdl3.gl_attr.depth_size, 0);
        _ = sdl_gl.SDL_GL_SetAttribute(sdl3.gl_attr.stencil_size, 0);

        const ctx = sdl_gl.SDL_GL_CreateContext(window) orelse continue;
        _ = sdl_gl.SDL_GL_MakeCurrent(window, ctx);
        // Pacing is ours, as in the software path: never vsync-throttle here or
        // the game clock follows the display refresh.
        _ = sdl_gl.SDL_GL_SetSwapInterval(0);

        const api = gl.load(sdl_gl.SDL_GL_GetProcAddress) catch {
            _ = sdl_gl.SDL_GL_DestroyContext(ctx);
            continue;
        };

        const version = api.glGetString(gl.VERSION) orelse "";
        const major = gl.majorVersion(std.mem.span(version));

        // Heap, not stack: two Chains is well over half a megabyte, and Windows
        // hands a thread 1 MiB by default.
        const g = try gpa.create(GlVideo);
        g.* = .{
            .sdl_gl = sdl_gl,
            .ctx = ctx,
            .api = api,
            .gles_major = major,
            .chains = undefined,
            .active = 0,
            .profile_dir = profile_dir,
            .names = names,
            .index = start,
        };
        buildChain(io, gpa, g, start, g.chain(), err) catch |e| {
            _ = sdl_gl.SDL_GL_DestroyContext(ctx);
            return e;
        };

        try err.print("shader: {s} ({s}, {s}) — {} of {} presets, ',' / '.' to cycle\n", .{
            g.chain().p.name_str(),
            prof.dir,
            std.mem.span(version),
            start + 1,
            names.len,
        });
        try err.flush();

        return g;
    }
    return InitGlError.NoVariantForThisGpu;
}

/// The presets baked for one profile, sorted so the cycle order is stable
/// across runs (and across machines — a directory's natural order is not).
fn listPresets(io: std.Io, gpa: std.mem.Allocator, profile_dir: []const u8) ![][]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, profile_dir, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    if (names.items.len == 0) return error.NoPresets;

    const out = try names.toOwnedSlice(gpa);
    std.mem.sort([]const u8, out, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return out;
}

fn indexOfName(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return i;
    }
    return null;
}

/// Compile the preset at `index` into `out`.
///
/// Everything read here — the manifest, the GLSL, the LUT bytes — is scratch:
/// the chain keeps only GL object names and a by-value `Preset`. So the arena
/// is released the moment `init` returns, and cycling through shaders all
/// evening does not grow the heap by one preset each time.
fn buildChain(
    io: std.Io,
    gpa: std.mem.Allocator,
    g: *GlVideo,
    index: usize,
    out: *shader.Chain,
    err: *std.Io.Writer,
) !void {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();

    const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ g.profile_dir, g.names[index] });
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);

    const manifest = try dir.readFileAlloc(io, "preset.conf", a, .limited(1 << 20));
    const p = try preset.parse(manifest);
    try out.init(io, a, g.api, g.gles_major, p, dir, err);
}

/// Step `delta` presets and swap the chain in.
///
/// The replacement is built *before* the incumbent is torn down, so a preset
/// that fails to compile on this GPU costs a printed line and nothing else —
/// the picture never drops out from under the player.
fn cycleShader(
    io: std.Io,
    gpa: std.mem.Allocator,
    g: *GlVideo,
    delta: isize,
    err: *std.Io.Writer,
) void {
    if (g.names.len < 2) return;
    const next = preset.cycle(g.index, delta, g.names.len);

    // Build into the spare slot; the incumbent keeps rendering until it works.
    const spare: u1 = 1 - g.active;
    buildChain(io, gpa, g, next, &g.chains[spare], err) catch |e| {
        err.print("shader '{s}' did not load ({s}) — staying on '{s}'\n", .{
            g.names[next], @errorName(e), g.names[g.index],
        }) catch {};
        err.flush() catch {};
        return;
    };

    g.chain().deinit();
    g.active = spare;
    g.index = next;

    err.print("shader: {s} ({} of {}, {} pass{s}, {s} tier)\n", .{
        g.chain().p.name_str(),
        next + 1,
        g.names.len,
        g.chain().p.pass_count,
        if (g.chain().p.pass_count == 1) "" else "es",
        @tagName(g.chain().p.tier),
    }) catch {};
    err.flush() catch {};
}

fn parseArgs(init: std.process.Init, gpa: std.mem.Allocator) !Args {
    // `iterate()` is POSIX-only — on Windows the command line has to be decoded
    // from UTF-16, which needs an allocator. The allocator form works on every
    // target, so the frontend builds and runs on a dev box as well as on the
    // handheld it is aimed at.
    // Deliberately not deinit'd: on Windows the iterator owns the decoded
    // strings, and `Args.rom` / `Args.shader` are slices into them. `gpa` is the
    // process arena, so they live exactly as long as they need to.
    var it = try init.minimal.args.iterateAllocator(gpa);
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
        } else if (std.mem.eql(u8, a, "--accurate")) {
            args.accuracy = .accurate;
        } else if (std.mem.eql(u8, a, "--shader")) {
            args.shader = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--patch")) {
            args.patch = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--shader-dir")) {
            args.shader_dir = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--shot")) {
            args.shot = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--shot-frames")) {
            // A comma list, so one run can grab several moments — a title screen
            // and a gameplay frame cost the same emulation either way.
            const v = it.next() orelse return error.MissingValue;
            var list: std.ArrayList(u32) = .empty;
            var parts = std.mem.splitScalar(u8, v, ',');
            while (parts.next()) |part| {
                const t = std.mem.trim(u8, part, " ");
                if (t.len == 0) continue;
                try list.append(gpa, try std.fmt.parseInt(u32, t, 10));
            }
            args.shot_frames = try list.toOwnedSlice(gpa);
        } else if (rom == null) {
            rom = a;
        } else return error.TooManyArgs;
    }
    args.rom = rom orelse return error.NoRom;
    return args;
}
