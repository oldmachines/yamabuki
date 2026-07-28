//! The interactive SDL session: window, video (software blit or GL shader
//! chain), audio stream, input, pacing, and the frame loop — everything that
//! happens between "the console is built" and "the window closed".
//!
//! `main.zig` owns the CLI and building the `AnyConsole`; this file owns the
//! session. The split is the seam M14 grows through: the overlay menu, the
//! gamepad layer, and persistence all land here without `main.zig`'s argument
//! handling ever being in the diff.

const std = @import("std");
const core = @import("snes_core");
const sdl3 = @import("sdl3.zig");
const gl = @import("gl.zig");
const preset = @import("preset.zig");
const shader = @import("shader.zig");
const util = @import("util");
const osd = @import("osd.zig");
const input = @import("input.zig");
const menu = @import("menu.zig");
const ui = @import("ui.zig");
const config = @import("config.zig");
const saves = @import("saves.zig");
const png = @import("png.zig");
const rewind = @import("rewind.zig");
const library = @import("library.zig");

/// `--region ntsc|pal|auto`: override the header-detected region. `auto`
/// (the default) uses the cart header's region byte.
pub const RegionArg = enum { auto, ntsc, pal };

/// Everything the session needs, already merged from defaults ← config ← CLI
/// by `main.zig`. Fields mirror the CLI flags they came from.
pub const Options = struct {
    rom: []const u8,
    scale: u32,
    frames: u32, // 0 = run until quit
    audio: bool,
    region: RegionArg,
    shader: ?[]const u8,
    shader_dir: []const u8,
    shot: ?[]const u8,
    shot_frames: []const u32,
    wide: u32,
    /// The resolved input bindings (config's `input` section, or the
    /// defaults — which reproduce the frontend's historical layout).
    bindings: input.Resolved,
    /// The live config, edited in place by the overlay menu.
    cfg: *config.Config,
    /// Where to persist it, when there is a data directory to persist to.
    config_path: ?[]const u8,
    /// `<sha16>-<title>` identity for save files; see `saves.gameId`.
    game_id: []const u8,
    /// Per-user data directories; null (no pref path, or a `--frames` CI
    /// run) means that kind of persistence is off for the session.
    saves_dir: ?[]const u8,
    states_dir: ?[]const u8,
    shots_dir: ?[]const u8,
    /// Rewind ring, resolved from the config; off in `--frames` CI runs.
    rewind_enabled: bool,
    rewind_budget_mib: u32,
};

/// Persist the config after a menu edit. Failure warns and plays on — a
/// read-only disk must not cost the session.
fn persistConfig(io: std.Io, gpa: std.mem.Allocator, opts: *const Options, err: *std.Io.Writer) void {
    const path = opts.config_path orelse return;
    config.save(io, gpa, opts.cfg.*, path) catch |e| {
        err.print("warning: cannot write {s}: {s}\n", .{ path, @errorName(e) }) catch {};
        err.flush() catch {};
    };
}

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
    /// The shader-name toast. Null means it failed to compile — never fatal,
    /// by the same rule a shader itself follows: a nice-to-have UI element
    /// must not cost the user the emulator, or the shader chain it is
    /// supposed to be announcing.
    osd: ?osd.Osd,

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
    /// Which GLSL dialect the OSD's own tiny program should be compiled in —
    /// this ladder and the shader chain's both land on the same rung.
    dialect: osd.Dialect,
};

const profiles = [_]Profile{
    .{ .dir = "essl300", .profile_mask = sdl3.gl_profile_es, .major = 3, .minor = 0, .dialect = .essl300 },
    .{ .dir = "glsl330", .profile_mask = sdl3.gl_profile_core, .major = 3, .minor = 3, .dialect = .glsl330 },
    .{ .dir = "essl100", .profile_mask = sdl3.gl_profile_es, .major = 2, .minor = 0, .dialect = .essl100 },
};

/// Frame duration for the loaded cart's region: 262 lines at 21.477 MHz
/// (NTSC, ~60.0988 Hz) or 312 lines at 21.281 MHz (PAL, 50 Hz).
fn frameNs(region: core.timing.Region) u64 {
    return switch (region) {
        .ntsc => core.timing.cycles_per_line * core.timing.ntsc_lines_per_frame *
            1_000_000_000 / core.timing.ntsc_master_hz,
        .pal => core.timing.cycles_per_line * core.timing.pal_lines_per_frame *
            1_000_000_000 / core.timing.pal_master_hz,
    };
}

/// Fast-forward keeps at most this much audio queued (~1/4 s) and drops the
/// rest — the point is to skip ahead, not to build a backlog.
const ff_max_queued_bytes: c_int = 32 * 1024;

/// The `drainAudio` sink for the main run loop: forward each chunk to the SDL
/// audio stream, dropping it under fast-forward once the device already has
/// `ff_max_queued_bytes` queued (the point is to skip ahead, not to queue up
/// a backlog).
const AudioSink = struct {
    sdl: sdl3.Api,
    stream: ?*sdl3.AudioStream,
    fast_forward: bool,

    fn push(self: AudioSink, chunk: []const i16) !void {
        const stream = self.stream orelse return;
        if (!self.fast_forward or self.sdl.SDL_GetAudioStreamQueued(stream) < ff_max_queued_bytes)
            _ = self.sdl.SDL_PutAudioStreamData(stream, chunk.ptr, @intCast(chunk.len * 2));
    }
};

pub const RunResult = struct {
    reason: enum { quit, to_library },
    /// Emulated frames this session, for the library's playtime metadata.
    frames: u32,
};

/// Run the whole SDL session to completion. Fatal SDL failures print and
/// exit, matching what the code did when it lived in `main`.
pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    sdl: sdl3.Api,
    con: *core.AnyConsole,
    opts: Options,
    err: *std.Io.Writer,
    out: *std.Io.Writer,
) !RunResult {
    const state_buf = try gpa.alloc(u8, core.AnyConsole.state_size);
    // Slot files live under states/<gameid>/; without a data dir the legacy
    // `<rom>.state` stands in for every slot, exactly as F5 always worked.
    const legacy_state_path = try std.fmt.allocPrint(gpa, "{s}.state", .{opts.rom});
    var slot: u32 = 1;
    var slot_paths: [9]?[]const u8 = @splat(null); // 1..8 used
    if (opts.states_dir) |dir| {
        for (1..9) |n| slot_paths[n] = try saves.slotPath(gpa, dir, opts.game_id, @intCast(n));
        if (saves.migrateLegacyState(io, legacy_state_path, slot_paths[1].?, state_buf)) {
            try err.print("state migrated: {s} -> {s}\n", .{ legacy_state_path, slot_paths[1].? });
            try err.flush();
        }
    }

    // --- SDL ----------------------------------------------------------------
    if (!sdl.SDL_Init(sdl3.init_video | sdl3.init_audio)) {
        try err.print("error: SDL_Init: {s}\n", .{sdl.SDL_GetError()});
        try err.flush();
        std.process.exit(1);
    }
    defer sdl.SDL_Quit();

    // Gamepads are best-effort on the shader model: a missing symbol or a
    // failed subsystem costs pads (the keyboard still plays), never the
    // emulator.
    var pad_api: ?sdl3.PadApi = null;
    if (sdl3.loadPad()) |papi| {
        if (papi.SDL_InitSubSystem(sdl3.init_gamepad)) {
            pad_api = papi;
        } else {
            try err.print("warning: gamepad subsystem unavailable ({s}) — keyboard only\n", .{sdl.SDL_GetError()});
            try err.flush();
        }
    } else |_| {
        try err.print("warning: gamepad symbols missing from this SDL — keyboard only\n", .{});
        try err.flush();
    }

    const window = sdl.SDL_CreateWindow(
        "Yamabuki",
        @intCast((256 + 2 * opts.wide) * opts.scale),
        @intCast(224 * opts.scale),
        sdl3.window_resizable | if (opts.shader != null) sdl3.window_opengl else 0,
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
    if (opts.shader) |name| {
        glv = initGl(io, gpa, window, opts.shader_dir, name, err) catch |e| blk: {
            try err.print("shader '{s}' unavailable ({s}); falling back to the software renderer\n", .{ name, @errorName(e) });
            try err.flush();
            break :blk null;
        };
    }
    defer if (glv) |g| {
        if (g.osd) |*o| o.deinit();
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
    if (opts.audio) {
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

    // Region is fixed for the life of a loaded cart (repower re-detects the
    // same header, or the CLI override above), so the frame duration is
    // computed once here rather than re-derived every frame.
    const frame_ns = frameNs(con.region());
    // If we fall further behind than this (state load, window drag), resync
    // the pacing clock instead of sprinting to catch up.
    const max_lag_ns: u64 = 4 * frame_ns;

    var inp: input.State = .{};
    var pads: [2]?*sdl3.Gamepad = .{ null, null };
    defer if (pad_api) |papi| {
        for (pads) |maybe| {
            if (maybe) |p| papi.SDL_CloseGamepad(p);
        }
    };
    // Battery save: restored before the first frame, autosaved on a
    // debounced dirty check, flushed at menu-open/state-load/quit.
    var sram: ?saves.Sram = null;
    if (opts.saves_dir) |dir| {
        if (con.cartridge().hasSram()) {
            sram = saves.Sram.init(gpa, dir, opts.game_id) catch null;
            if (sram) |*s| s.load(io, con, err);
        }
    }

    // Rewind history. The one number the whole design leans on — the real
    // state size — is printed rather than assumed.
    var rw: ?rewind.Rewind = null;
    if (opts.rewind_enabled) {
        rw = rewind.Rewind.init(gpa, @as(usize, opts.rewind_budget_mib) * 1024 * 1024) catch null;
        if (rw != null) {
            try err.print("rewind: {d} KiB per state, {d} MiB budget\n", .{
                core.AnyConsole.state_size / 1024, opts.rewind_budget_mib,
            });
            try err.flush();
        }
    }

    // Live bindings: a copy, because a remap in the menu re-resolves them.
    var binds = opts.bindings;
    var mnu: ?menu.Menu = null;
    // The overlay composes into this and the normal video path presents it —
    // so the CRT shader shades the menu too. Sized for the largest frame the
    // PPU produces (512-wide hi-res, 239-line overscan).
    const compose = try gpa.alloc(u16, core.ppu.fb_width_max * 240);
    var audio_on = true;
    var fast_forward = false;
    var paused = false;
    var shot_requested = false;
    var running = true;
    var exit_to_library = false;
    var frames_run: u32 = 0;
    var audio_hash = core.console.audio_hash_init;
    var next_deadline = sdl.SDL_GetTicksNS() + frame_ns;

    while (running) {
        if (mnu) |*m| m.tick();
        var ev: sdl3.Event = undefined;
        while (sdl.SDL_PollEvent(&ev)) {
            if (ev.type == sdl3.event_quit) {
                running = false;
                continue;
            }
            // Normalize once; the menu and the game share the same shape.
            const nev: input.Ev = switch (ev.type) {
                sdl3.event_key_down, sdl3.event_key_up => .{ .key = .{
                    .scancode = ev.key.scancode,
                    .down = ev.key.down,
                    .repeat = ev.key.repeat,
                } },
                sdl3.event_gamepad_button_down, sdl3.event_gamepad_button_up => .{ .pad_button = .{
                    .pad = ev.gbutton.which,
                    .button = ev.gbutton.button,
                    .down = ev.gbutton.down,
                } },
                sdl3.event_gamepad_axis_motion => .{ .pad_axis = .{
                    .pad = ev.gaxis.which,
                    .axis = ev.gaxis.axis,
                    .value = ev.gaxis.value,
                } },
                // ADDED fires for already-connected pads too, so startup
                // enumeration and hotplug are one code path.
                sdl3.event_gamepad_added => .{ .pad_added = .{ .pad = ev.gdevice.which } },
                sdl3.event_gamepad_removed => .{ .pad_removed = .{ .pad = ev.gdevice.which } },
                else => continue,
            };

            // Hotplug is screen-independent: pads connect and disconnect
            // whether the menu is up or not.
            if (nev == .pad_added or nev == .pad_removed) {
                switch (inp.handle(&binds, nev)) {
                    .pad_opened => |o| if (pad_api) |papi| {
                        pads[o.slot] = papi.SDL_OpenGamepad(o.pad);
                        if (pads[o.slot]) |p| {
                            const name = if (papi.SDL_GetGamepadName(p)) |n| std.mem.span(n) else "gamepad";
                            try err.print("gamepad: {s} is player {d}\n", .{ name, @as(u32, o.slot) + 1 });
                        } else {
                            try err.print("warning: SDL_OpenGamepad: {s}\n", .{sdl.SDL_GetError()});
                        }
                        try err.flush();
                    },
                    .pad_closed => |c| if (pad_api) |papi| {
                        if (pads[c.slot]) |p| papi.SDL_CloseGamepad(p);
                        pads[c.slot] = null;
                        try err.print("gamepad: player {d} disconnected\n", .{@as(u32, c.slot) + 1});
                        try err.flush();
                    },
                    else => {},
                }
                continue;
            }

            if (mnu) |*m| {
                // Menu path: raw events feed a pending capture; otherwise
                // the fixed navigation map steers.
                const mctx: menu.Ctx = .{
                    .gpa = gpa,
                    .game_id = opts.game_id,
                    .shader_name = if (glv) |g| g.names[g.index] else null,
                };
                const req: menu.Request = if (m.capturing())
                    m.feedCapture(gpa, opts.cfg, nev)
                else if (menu.navFromEvent(nev)) |nav|
                    m.handleNav(opts.cfg, nav, mctx)
                else
                    .none;
                switch (req) {
                    .none => {},
                    .resume_game => mnu = null,
                    .quit => running = false,
                    .close_game => {
                        exit_to_library = true;
                        running = false;
                    },
                    .reset => {
                        con.repower();
                        switch (opts.region) {
                            .auto => {},
                            .ntsc => con.setRegion(.ntsc),
                            .pal => con.setRegion(.pal),
                        }
                        if (rw) |*r| r.clear();
                        mnu = null;
                    },
                    .save_state => {
                        saveStateTo(io, con, slot_paths[slot] orelse legacy_state_path, slot, state_buf, err);
                        mnu = null;
                    },
                    .load_state => {
                        if (loadStateFrom(io, con, slot_paths[slot] orelse legacy_state_path, slot, state_buf, err)) {
                            // The state carried its own SRAM; make the .srm
                            // agree with what the machine now holds.
                            if (sram) |*s| s.flush(io, con, err);
                            // History no longer leads to this present.
                            if (rw) |*r| r.clear();
                        }
                        mnu = null;
                    },
                    .slot_next => slot = if (slot == 8) 1 else slot + 1,
                    .slot_prev => slot = if (slot == 1) 8 else slot - 1,
                    .config_dirty => {
                        persistConfig(io, gpa, &opts, err);
                        binds = input.resolve(&opts.cfg.input, err);
                        audio_on = opts.cfg.audio.enabled;
                        // Toggling rewind off drops its history at once.
                        if (!opts.cfg.rewind.enabled) {
                            if (rw) |*r| r.clear();
                        }
                    },
                    .shader_next, .shader_prev => if (glv) |g| {
                        cycleShader(io, gpa, g, if (req == .shader_next) 1 else -1, err);
                        opts.cfg.video.shader = g.names[g.index];
                        persistConfig(io, gpa, &opts, err);
                    },
                }
                continue;
            }

            // Game path. Shader cycling stays on fixed keys, outside the
            // remappable model: it is a dev affordance, and the keys must
            // survive any config. A no-op on the software path.
            if (nev == .key and nev.key.down and !nev.key.repeat) {
                if (nev.key.scancode == sdl3.scancode.comma) {
                    if (glv) |g| cycleShader(io, gpa, g, -1, err);
                } else if (nev.key.scancode == sdl3.scancode.period) {
                    if (glv) |g| cycleShader(io, gpa, g, 1, err);
                }
            }
            switch (inp.handle(&binds, nev)) {
                .none => {},
                .menu => {
                    mnu = menu.Menu.init();
                    // The menu eats the release events, so drop anything
                    // held right now — nothing may stay pressed forever.
                    inp.clearTransient();
                    // A natural save point: the player just stepped away.
                    if (sram) |*s| s.flush(io, con, err);
                },
                .pause => paused = !paused,
                .reset => {
                    con.repower();
                    // repower() re-detects region from the header; reapply
                    // an explicit CLI override.
                    switch (opts.region) {
                        .auto => {},
                        .ntsc => con.setRegion(.ntsc),
                        .pal => con.setRegion(.pal),
                    }
                    if (rw) |*r| r.clear();
                },
                .save_state => saveStateTo(io, con, slot_paths[slot] orelse legacy_state_path, slot, state_buf, err),
                .load_state => {
                    if (loadStateFrom(io, con, slot_paths[slot] orelse legacy_state_path, slot, state_buf, err)) {
                        if (sram) |*s| s.flush(io, con, err);
                        if (rw) |*r| r.clear();
                    }
                },
                .slot_next => {
                    slot = if (slot == 8) 1 else slot + 1;
                    try err.print("state slot {d}\n", .{slot});
                    try err.flush();
                },
                .slot_prev => {
                    slot = if (slot == 1) 8 else slot - 1;
                    try err.print("state slot {d}\n", .{slot});
                    try err.flush();
                },
                .screenshot => {
                    if (opts.shots_dir != null) {
                        shot_requested = true;
                    } else {
                        try err.print("screenshot unavailable: no per-user data directory\n", .{});
                        try err.flush();
                    }
                },
                // Hotplug actions can only come from pad_added/removed,
                // which the branch above consumed.
                .pad_opened, .pad_closed => unreachable,
            }
        }

        // Holding rewind freezes forward time and steps history back one
        // capture per displayed frame (~real-time backwards); at the end
        // of history it just holds the oldest frame.
        const rewinding = mnu == null and inp.rewindHeld() and rw != null and opts.cfg.rewind.enabled;
        const halted = paused or mnu != null or rewinding;
        fast_forward = inp.ffHeld() and !halted;
        con.setButtons(0, inp.masks[0]);
        con.setButtons(1, inp.masks[1]);
        if (rewinding) {
            _ = rw.?.rewindStep(con);
        } else if (!halted) {
            con.runFrame();
            frames_run += 1;
            if (sram) |*s| s.tick(io, con, err);
            if (opts.cfg.rewind.enabled) {
                if (rw) |*r| r.onFrame(con);
            }
        }

        // Video: native RGB565, either through the shader chain or straight
        // into a streaming texture. With the menu up, the frame is copied
        // into the compose buffer, dimmed, and drawn over — then presented
        // through the very same path, so shaders and letterboxing never
        // know the difference.
        const fb = con.framebuffer();
        const width = con.frameWidth();
        const height: u32 = @intCast(fb.len / width);
        const src_px: []const u16 = if (mnu) |*m| blk: {
            @memcpy(compose[0..fb.len], fb);
            const surf = ui.Surface.init(compose[0..fb.len], width, height);
            ui.dimAll(&surf);
            m.draw(&surf, opts.cfg, .{
                .gpa = gpa,
                .game_id = opts.game_id,
                .shader_name = if (glv) |g| g.names[g.index] else null,
            }, slot);
            break :blk compose[0..fb.len];
        } else if (rewinding) blk: {
            @memcpy(compose[0..fb.len], fb);
            const surf = ui.Surface.init(compose[0..fb.len], width, height);
            ui.drawText(&surf, 4, 4, "<< REWIND", ui.color.accent);
            break :blk compose[0..fb.len];
        } else fb;

        if (glv) |g| gl_path: {
            g.chain().upload(src_px, width, height);
            var win_w: c_int = 0;
            var win_h: c_int = 0;
            _ = g.sdl_gl.SDL_GetWindowSizeInPixels(window, &win_w, &win_h);
            g.chain().render(.{ .w = @intCast(@max(1, win_w)), .h = @intCast(@max(1, win_h)) }) catch |e| {
                // The rule this file states at initGl applies mid-game too: a
                // shader must never cost the user the emulator. Print once,
                // tear the GL path down, and hand the rest of the session to
                // the software blit — the same fallback initGl takes, later.
                // This frame's video is lost; emulation and audio are not.
                try err.print("shader render failed ({s}); falling back to the software renderer\n", .{@errorName(e)});
                try err.flush();
                if (g.osd) |*o| o.deinit();
                g.chain().deinit();
                _ = g.sdl_gl.SDL_GL_DestroyContext(g.ctx);
                glv = null;
                renderer = sdl.SDL_CreateRenderer(window, null) orelse {
                    // No GL and no renderer: nothing left can put pixels on
                    // screen, so exiting is the honest move.
                    try err.print("error: SDL_CreateRenderer after shader failure: {s}\n", .{sdl.SDL_GetError()});
                    try err.flush();
                    std.process.exit(1);
                };
                _ = sdl.SDL_SetRenderVSync(renderer.?, 0);
                // `g` is gone; skip the rest of the GL branch. The audio
                // drain and pacing below still run for this frame.
                break :gl_path;
            };
            // Grab the rendered frame *before* the swap, while the back buffer
            // still holds it.
            if (opts.shot) |prefix| {
                // `!halted`: a paused loop re-presents the same frame number
                // every iteration and must not re-capture it.
                if (!halted and wantsShot(opts.shot_frames, frames_run, opts.frames)) {
                    const win: preset.Size = .{ .w = @intCast(@max(1, win_w)), .h = @intCast(@max(1, win_h)) };
                    if (g.chain().capture(gpa, win)) |img| {
                        try util.maybeShot(io, gpa, err, prefix, frames_run, img.w, img.h, img.rgb);
                    } else |e| {
                        try err.print("capture failed: {s}\n", .{@errorName(e)});
                        try err.flush();
                    }
                }
            }
            if (shot_requested) shot_gl: {
                shot_requested = false;
                const dir = opts.shots_dir orelse break :shot_gl;
                const win: preset.Size = .{ .w = @intCast(@max(1, win_w)), .h = @intCast(@max(1, win_h)) };
                const img = g.chain().capture(gpa, win) catch |e| {
                    try err.print("screenshot capture failed: {s}\n", .{@errorName(e)});
                    try err.flush();
                    break :shot_gl;
                };
                writeScreenshot(io, gpa, dir, opts.game_id, img.rgb, img.w, img.h, err);
            }
            if (g.osd) |*o| {
                const window_size: preset.Size = .{ .w = @intCast(@max(1, win_w)), .h = @intCast(@max(1, win_h)) };
                const lb = shader.Chain.letterbox(window_size, g.chain().source_size);
                o.draw(window_size, .{ .x = lb.x, .y = lb.y, .w = lb.w, .h = lb.h });
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
                // 256-wide (or `--wide`-widened) frames scale 2x onto the
                // canvas — a wider frame gets a proportionally wider canvas,
                // showing more picture rather than stretching it; genuine
                // hi-res (exactly core.ppu.fb_width_max, a width `--wide`
                // can never reach — see `core.ppu.wide_margin_max`) maps 1:1
                // instead. The canvas keeps the resulting shape and
                // letterboxes into the window.
                const canvas_w: u32 = if (width == core.ppu.fb_width_max) core.ppu.fb_width_max else width * 2;
                _ = sdl.SDL_SetRenderLogicalPresentation(
                    r,
                    @intCast(canvas_w),
                    @intCast(height * 2),
                    sdl3.logical_presentation_letterbox,
                );
                tex_w = width;
                tex_h = height;
            }
            _ = sdl.SDL_UpdateTexture(texture.?, null, src_px.ptr, @intCast(width * 2));
            _ = sdl.SDL_RenderClear(r);
            _ = sdl.SDL_RenderTexture(r, texture.?, null, null);
            _ = sdl.SDL_RenderPresent(r);

            // No shader: the console's framebuffer *is* the picture.
            if (opts.shot) |prefix| {
                if (!halted and wantsShot(opts.shot_frames, frames_run, opts.frames)) {
                    const rgb = try util.expandFramebuffer(gpa, fb, width, height);
                    try util.maybeShot(io, gpa, err, prefix, frames_run, width, height, rgb);
                }
            }
            if (shot_requested) shot_sw: {
                shot_requested = false;
                const dir = opts.shots_dir orelse break :shot_sw;
                const rgb = util.expandFramebuffer(gpa, fb, width, height) catch break :shot_sw;
                defer gpa.free(rgb);
                writeScreenshot(io, gpa, dir, opts.game_id, rgb, width, height, err);
            }
        }

        // Audio: drain the console ring into the SDL stream. A menu toggle
        // of `audio_on` mutes by dropping the chunks; the ring still drains
        // so nothing backs up. During rewind the ring's contents belong to
        // whichever restored state holds it — leave it alone entirely.
        if (!rewinding) try util.drainAudio(con, &audio_hash, AudioSink{
            .sdl = sdl,
            .stream = if (audio_on) audio else null,
            .fast_forward = fast_forward,
        }, AudioSink.push);

        if (opts.frames != 0 and frames_run >= opts.frames) running = false;

        // Pacing: sleep up to the next NTSC frame boundary.
        if (fast_forward or opts.frames != 0) {
            next_deadline = sdl.SDL_GetTicksNS() + frame_ns;
        } else {
            const now = sdl.SDL_GetTicksNS();
            if (now < next_deadline) sdl.SDL_DelayNS(next_deadline - now);
            next_deadline += frame_ns;
            if (now > next_deadline + max_lag_ns) next_deadline = now + frame_ns;
        }
    }

    // The battery save's last chance before the process ends.
    if (sram) |*s| s.flush(io, con, err);

    // Same report format as the headless runner so smoke tests can assert
    // the golden hashes through the SDL path.
    const fb = con.framebuffer();
    const width = con.frameWidth();
    try out.print("{s}: {} frames, {}x{}, hash={x:0>16}, audio={x:0>16}\n", .{
        opts.rom, frames_run, width, fb.len / width, core.console.hashFrame(fb), audio_hash,
    });
    try out.flush();
    return .{
        .reason = if (exit_to_library) .to_library else .quit,
        .frames = frames_run,
    };
}

/// The library picker: its own small SDL session (window, software blit,
/// fixed navigation) that scans incrementally while the list is browsed.
/// Returns the selected entry's path (duped into `gpa`), or null to quit.
pub fn runLibrary(
    io: std.Io,
    gpa: std.mem.Allocator,
    sdl: sdl3.Api,
    scale: u32,
    lib: *library.Library,
    rom_dirs: []const []const u8,
    cache_path: ?[]const u8,
    err: *std.Io.Writer,
) !?[]const u8 {
    if (!sdl.SDL_Init(sdl3.init_video | sdl3.init_audio)) {
        try err.print("error: SDL_Init: {s}\n", .{sdl.SDL_GetError()});
        try err.flush();
        std.process.exit(1);
    }
    defer sdl.SDL_Quit();

    var pad_api: ?sdl3.PadApi = null;
    if (sdl3.loadPad()) |papi| {
        if (papi.SDL_InitSubSystem(sdl3.init_gamepad)) pad_api = papi;
    } else |_| {}

    const window = sdl.SDL_CreateWindow(
        "Yamabuki",
        @intCast(256 * scale),
        @intCast(224 * scale),
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
    _ = sdl.SDL_SetRenderVSync(renderer, 0);
    const texture = sdl.SDL_CreateTexture(
        renderer,
        sdl3.pixel_format_rgb565,
        sdl3.texture_access_streaming,
        256,
        224,
    ) orelse {
        try err.print("error: SDL_CreateTexture: {s}\n", .{sdl.SDL_GetError()});
        try err.flush();
        std.process.exit(1);
    };
    defer sdl.SDL_DestroyTexture(texture);
    _ = sdl.SDL_SetTextureScaleMode(texture, sdl3.scale_mode_nearest);
    _ = sdl.SDL_SetRenderLogicalPresentation(renderer, 512, 448, sdl3.logical_presentation_letterbox);

    // Any connected pad can drive the picker — no player slots here.
    var open_pads: std.ArrayList(*sdl3.Gamepad) = .empty;
    defer if (pad_api) |papi| for (open_pads.items) |p| papi.SDL_CloseGamepad(p);

    var canvas: [256 * 224]u16 = undefined;
    var scanner = library.Scanner.begin(gpa, io, rom_dirs, err);
    var cursor: usize = 0;
    var scroll: usize = 0;
    const visible_rows = 17;

    while (true) {
        var ev: sdl3.Event = undefined;
        var picked: ?usize = null;
        while (sdl.SDL_PollEvent(&ev)) {
            if (ev.type == sdl3.event_quit) return null;
            const nev: input.Ev = switch (ev.type) {
                sdl3.event_key_down, sdl3.event_key_up => .{ .key = .{
                    .scancode = ev.key.scancode,
                    .down = ev.key.down,
                    .repeat = ev.key.repeat,
                } },
                sdl3.event_gamepad_button_down, sdl3.event_gamepad_button_up => .{ .pad_button = .{
                    .pad = ev.gbutton.which,
                    .button = ev.gbutton.button,
                    .down = ev.gbutton.down,
                } },
                sdl3.event_gamepad_added => blk: {
                    if (pad_api) |papi| {
                        if (papi.SDL_OpenGamepad(ev.gdevice.which)) |p|
                            open_pads.append(gpa, p) catch {};
                    }
                    break :blk .{ .pad_added = .{ .pad = ev.gdevice.which } };
                },
                else => continue,
            };
            const n = lib.entries.items.len;
            switch (menu.navFromEvent(nev) orelse continue) {
                .up => if (n != 0) {
                    cursor = if (cursor == 0) n - 1 else cursor - 1;
                },
                .down => if (n != 0) {
                    cursor = if (cursor + 1 >= n) 0 else cursor + 1;
                },
                .left => cursor -|= visible_rows,
                .right => if (n != 0) {
                    cursor = @min(cursor + visible_rows, n - 1);
                },
                .confirm => if (cursor < n) {
                    picked = cursor;
                },
                .back, .close => return null,
            }
        }

        if (picked) |i| return try gpa.dupe(u8, lib.entries.items[i].path);

        // Scan under a per-frame time budget so the list fills while the
        // screen stays live; persist the cache the moment it completes.
        const deadline = sdl.SDL_GetTicksNS() + 6 * std.time.ns_per_ms;
        while (!scanner.done and sdl.SDL_GetTicksNS() < deadline) {
            if (scanner.stepOne(io, lib)) {
                if (cache_path) |p| lib.saveCache(io, gpa, p) catch {};
            }
        }
        if (cursor >= lib.entries.items.len and lib.entries.items.len != 0)
            cursor = lib.entries.items.len - 1;
        if (cursor < scroll) scroll = cursor;
        if (cursor >= scroll + visible_rows) scroll = cursor - visible_rows + 1;

        drawLibraryScreen(&canvas, lib, cursor, scroll, visible_rows, rom_dirs.len == 0, if (scanner.done) null else scanner.remaining());

        _ = sdl.SDL_UpdateTexture(texture, null, &canvas, 256 * 2);
        _ = sdl.SDL_RenderClear(renderer);
        _ = sdl.SDL_RenderTexture(renderer, texture, null, null);
        _ = sdl.SDL_RenderPresent(renderer);
        sdl.SDL_DelayNS(16 * std.time.ns_per_ms);
    }
}

/// The picker's whole frame, drawn into a 256x224 canvas — pure pixels, so
/// the layout is testable and eyeballable without SDL. `scanning_left` is
/// null once the scan has completed.
fn drawLibraryScreen(
    canvas: *[256 * 224]u16,
    lib: *const library.Library,
    cursor: usize,
    scroll: usize,
    visible_rows: usize,
    no_dirs: bool,
    scanning_left: ?usize,
) void {
    const surf = ui.Surface.init(canvas, 256, 224);
    ui.fillRect(&surf, 0, 0, 256, 224, ui.color.panel);
    ui.drawText(&surf, 8, 6, "YAMABUKI", ui.color.accent);
    var hdr: [40]u8 = undefined;
    const count_txt = std.fmt.bufPrint(&hdr, "{d} GAMES", .{lib.entries.items.len}) catch "";
    ui.drawText(&surf, 248 - @as(i32, @intCast(ui.textWidth(count_txt))), 6, count_txt, ui.color.text_dim);

    if (no_dirs) {
        ui.drawTextCentered(&surf, 90, "NO ROM FOLDERS CONFIGURED", ui.color.text);
        ui.drawTextCentered(&surf, 104, "ADD LIBRARY.ROM_DIRS TO CONFIG.ZON", ui.color.text_dim);
        ui.drawTextCentered(&surf, 114, "IN THE YAMABUKI DATA FOLDER", ui.color.text_dim);
    } else if (lib.entries.items.len == 0 and scanning_left == null) {
        ui.drawTextCentered(&surf, 100, "NO SNES ROMS FOUND", ui.color.text);
    }

    for (0..visible_rows) |row| {
        const i = scroll + row;
        if (i >= lib.entries.items.len) break;
        const e = lib.entries.items[i];
        const y: i32 = @intCast(20 + row * ui.line_h);
        const selected = i == cursor;
        if (selected) ui.drawText(&surf, 2, y, ">", ui.color.accent);
        const fg = if (selected) ui.color.text else ui.color.text_dim;
        const max_title = 32;
        ui.drawText(&surf, 10, y, e.title[0..@min(e.title.len, max_title)], fg);
        var tag: [16]u8 = undefined;
        const tag_txt = if (e.chip.len != 0)
            std.fmt.bufPrint(&tag, "{s} {s}", .{ e.chip, e.region }) catch e.region
        else
            e.region;
        ui.drawText(&surf, 248 - @as(i32, @intCast(ui.textWidth(tag_txt))), y, tag_txt, ui.color.text_dim);
    }

    if (scanning_left) |left| {
        var foot: [40]u8 = undefined;
        const t = std.fmt.bufPrint(&foot, "SCANNING... {d} LEFT", .{left}) catch "";
        ui.drawText(&surf, 8, 212, t, ui.color.accent);
    } else {
        ui.drawText(&surf, 8, 212, "ENTER/A PLAY  ESC/B QUIT", ui.color.text_dim);
    }
}

test "library screen: every state draws without out-of-bounds writes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const canvas = try a.create([256 * 224]u16);
    var lib: library.Library = .{ .gpa = a };
    // Onboarding, empty-result, and scanning states.
    drawLibraryScreen(canvas, &lib, 0, 0, 17, true, null);
    drawLibraryScreen(canvas, &lib, 0, 0, 17, false, null);
    drawLibraryScreen(canvas, &lib, 0, 0, 17, false, 42);
    // A list longer than the window, cursor at the end, scrolled.
    for (0..40) |i| {
        var name: [16]u8 = undefined;
        try lib.entries.append(a, .{
            .path = "x",
            .title = try a.dupe(u8, std.fmt.bufPrint(&name, "GAME {d}", .{i}) catch "G"),
            .region = "NTSC",
            .chip = if (i % 3 == 0) "SA-1" else "",
        });
    }
    drawLibraryScreen(canvas, &lib, 39, 23, 17, false, null);
}

/// Is `frame` one of the moments we were asked to capture? An empty list means
/// "the last frame only", which is what a bare `--shot` with `--frames N`
/// wants. (`total` is `--frames`; parseArgs rejects a bare `--shot` when it is
/// zero, i.e. run-until-quit, because "the last frame" does not exist then.)
fn wantsShot(frames: []const u32, frame: u32, total: u32) bool {
    if (frames.len == 0) return total != 0 and frame == total;
    for (frames) |f| {
        if (f == frame) return true;
    }
    return false;
}

test "wantsShot: an empty list means the last frame only" {
    // The doc comment above used to promise this while the code returned
    // false for every frame — a bare `--shot --frames N` captured nothing.
    try std.testing.expect(wantsShot(&.{}, 60, 60));
    try std.testing.expect(!wantsShot(&.{}, 59, 60));
    try std.testing.expect(!wantsShot(&.{}, 0, 60));
    // Run-until-quit has no last frame; parseArgs rejects the combination,
    // and the predicate stays false as the backstop.
    try std.testing.expect(!wantsShot(&.{}, 0, 0));
}

test "wantsShot: an explicit list is unchanged" {
    const list = [_]u32{ 10, 20 };
    try std.testing.expect(wantsShot(&list, 10, 60));
    try std.testing.expect(wantsShot(&list, 20, 60));
    try std.testing.expect(!wantsShot(&list, 60, 60)); // total is NOT implied
    try std.testing.expect(!wantsShot(&list, 15, 60));
}

fn saveStateTo(io: std.Io, con: *core.AnyConsole, path: []const u8, slot: u32, buf: []u8, err: *std.Io.Writer) void {
    _ = con.saveState(buf);
    if (std.fs.path.dirname(path)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch {};
    if (std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf })) {
        err.print("state saved: slot {d} ({s})\n", .{ slot, path }) catch {};
    } else |e| {
        err.print("state save failed: {s}\n", .{@errorName(e)}) catch {};
    }
    err.flush() catch {};
}

fn loadStateFrom(io: std.Io, con: *core.AnyConsole, path: []const u8, slot: u32, buf: []u8, err: *std.Io.Writer) bool {
    if (loadStateFile(io, con, path, buf)) {
        err.print("state loaded: slot {d} ({s})\n", .{ slot, path }) catch {};
        err.flush() catch {};
        return true;
    } else |e| {
        err.print("state load failed: {s}\n", .{@errorName(e)}) catch {};
        err.flush() catch {};
        return false;
    }
}

fn loadStateFile(io: std.Io, con: *core.AnyConsole, path: []const u8, buf: []u8) !void {
    const data = try std.Io.Dir.cwd().readFile(io, path, buf);
    try con.loadState(data);
}

/// Encode and write one screenshot, named by the first free index — no
/// wall-clock dependency, and the names sort in capture order.
fn writeScreenshot(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: []const u8,
    game_id: []const u8,
    rgb: []const u8,
    w: u32,
    h: u32,
    err: *std.Io.Writer,
) void {
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    var path_buf: [512]u8 = undefined;
    var n: u32 = 1;
    const path = while (n <= 9999) : (n += 1) {
        const p = std.fmt.bufPrint(&path_buf, "{s}/{s}-{d:0>4}.png", .{ dir, game_id, n }) catch return;
        std.Io.Dir.cwd().access(io, p, .{}) catch break p;
    } else return;
    const data = png.encode(gpa, rgb, w, h) catch |e| {
        err.print("screenshot failed: {s}\n", .{@errorName(e)}) catch {};
        err.flush() catch {};
        return;
    };
    defer gpa.free(data);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch |e| {
        err.print("screenshot failed: {s}\n", .{@errorName(e)}) catch {};
        err.flush() catch {};
        return;
    };
    err.print("screenshot: {s}\n", .{path}) catch {};
    err.flush() catch {};
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
            .osd = null,
        };
        buildChain(io, gpa, g, start, g.chain(), err) catch |e| {
            _ = sdl_gl.SDL_GL_DestroyContext(ctx);
            return e;
        };
        g.osd = osd.Osd.init(api, prof.dialect) catch |e| blk: {
            err.print("osd unavailable ({s}) — shader-switch messages disabled\n", .{@errorName(e)}) catch {};
            break :blk null;
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
    if (g.osd) |*o| o.show(g.names[next]);

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
