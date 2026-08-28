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
const infopanel = @import("infopanel.zig");
const png = @import("png.zig");
const rewind = @import("rewind.zig");
const library = @import("library.zig");
const dirpicker = @import("dirpicker.zig");
const patchfind = @import("patchfind.zig");

/// `--region ntsc|pal|auto`: override the header-detected region. `auto`
/// (the default) uses the cart header's region byte.
pub const RegionArg = enum { auto, ntsc, pal };

/// A transient on-screen message (slot changes, state saves/loads,
/// recording start/stop): one line at the picture's bottom-left for a
/// couple of seconds, drawn into the compose buffer so both render paths
/// show it and the shader shades it like game pixels.
const Toast = struct {
    buf: [48]u8 = undefined,
    len: usize = 0,
    frames: u32 = 0,

    fn set(self: *Toast, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.buf, fmt, args) catch return;
        self.len = s.len;
        self.frames = 120; // ~2 s
    }
};

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
    /// `<pref>/movies`, where the record hotkey writes .ymv playthroughs;
    /// null means recording is off for the session.
    movies_dir: ?[]const u8,
    /// CRC32 of the copier-stripped image as booted (post soft-patch) — the
    /// identity a recorded movie carries.
    rom_crc: u32,
    /// The core the console was built on, echoed into recorded movies.
    accuracy: core.Accuracy,
    /// `--movie`: a validated recorded playthrough to replay from power-on.
    /// Live input takes over when it ends.
    movie: ?util.movie.Movie,
    /// Cheat pokes held after every executed frame; see cheat.zig.
    pokes: [util.cheat.max_pokes]util.cheat.Poke = undefined,
    n_pokes: usize = 0,
    /// Basename of the soft-patch applied at load; null = playing as dumped.
    patch_name: ?[]const u8,
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
            // Volume, best-effort: gain is a newer stream property, its own
            // symbol group so an SDL3 without it costs the setting and
            // nothing else. 100% skips the call entirely.
            const vol = opts.cfg.effectiveVolume();
            if (vol != 100) {
                if (sdl3.loadGain()) |g| {
                    _ = g.SDL_SetAudioStreamGain(stream, @as(f32, @floatFromInt(vol)) / 100.0);
                } else |_| {
                    try err.print("warning: this SDL3 has no SDL_SetAudioStreamGain — volume stays 100%\n", .{});
                    try err.flush();
                }
            }
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
    // debounced dirty check, flushed at menu-open/state-load/quit. Gated
    // on the BATTERY, not on RAM: a window-converted cart carries the
    // game's WRAM in BW-RAM, and persisting that would boot the next
    // session into stale mid-game state.
    var sram: ?saves.Sram = null;
    if (opts.saves_dir) |dir| {
        if (con.cartridge().hasBattery()) {
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
    // The info palette (I): an overlay HUD, not a pause — the game keeps
    // running under it. Slot facts are gathered when it opens and after
    // saves/loads while it is up, never per frame.
    var info_open = false;
    var slot_infos: [9]infopanel.SlotInfo = @splat(.{});
    // Hold-to-scroll for the menu's Up/Down; reset whenever the menu isn't
    // open so a key held from before it opened (or from gameplay) can never
    // carry a repeat in.
    var repeater: menu.Repeater = .{};
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
    // Input-movie state. Recording appends the masks actually fed to each
    // EXECUTED frame; anything that breaks the input-stream model DURING a
    // take (reset, load state, rewind) discards it rather than writing a
    // movie that cannot replay. Playback drives both pads from the movie's
    // start until it runs out, then live input takes over; its end hashes
    // are checked right after the final frame's audio drain.
    var rec: ?std.array_list.Managed([2]u16) = null;
    // Codes are loaded but NOT applied until asked for: a cheat held through
    // the title screen can wedge a game that the same cheat plays fine in.
    var cheats_on = false;
    // The machine the take started on, when that was not power-on: recording
    // captures it up front and the movie carries it, so a session can start a
    // recording deep into a game instead of replaying the road to get there.
    var rec_anchor: ?[]u8 = null;
    // Frame count at which each slot's state was saved DURING the take in
    // progress. Loading a marked slot rewinds the take to that frame instead
    // of throwing it away, which is what makes recording a long playthrough
    // survivable: die, reload, and the log rewinds with the machine.
    var rec_marks: [9]?u32 = @splat(null);
    // The audio hash is a running accumulator over every frame the take has
    // played. Rewinding the input log without rewinding this leaves the movie
    // claiming an audio stream that includes the frames it just deleted, and
    // a clean replay of the same inputs then reports a desync that is not
    // there. Snapshot it with the mark; restore it with the rewind.
    var rec_audio: [9]u64 = @splat(0);
    // Whether the console is still exactly as it powered on. A take started
    // here needs no anchor, which keeps "boot and record" writing the small
    // version-1 file it always did.
    var at_power_on = true;
    // Transient on-screen toast (state slots, saves/loads, recording):
    // drawn into the compose buffer like every overlay, so both render
    // paths show it and the shader shades it.
    var toast: Toast = .{};
    var play_movie: ?util.movie.Movie = opts.movie;
    var play_idx: usize = 0;
    var movie_end_check = false;
    var next_deadline = sdl.SDL_GetTicksNS() + frame_ns;

    while (running) {
        if (mnu) |*m| m.tick() else repeater = .{};
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
                // A joystick SDL enumerates but has no gamepad mapping for
                // raises this and never `gamepad_added`, so the pad silently
                // does nothing. Reporting it is the difference between "the
                // controller is broken" and "SDL does not know this device":
                // the same DualShock 4 can be a gamepad over Bluetooth and a
                // bare joystick over USB, because the two connections present
                // different VID/PID and report descriptors.
                sdl3.event_joystick_added => {
                    if (pad_api) |papi| {
                        const id = ev.gdevice.which;
                        const nm = if (papi.SDL_GetJoystickNameForID(id)) |n| std.mem.span(n) else "(unnamed)";
                        try err.print("joystick added: id={d} name='{s}' recognised_as_gamepad={}\n", .{
                            id, nm, papi.SDL_IsGamepad(id),
                        });
                        try err.flush();
                    }
                    continue;
                },
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
                            inp.releaseSlot(&binds, o.slot);
                        }
                        try err.flush();
                    },
                    .pad_closed => |c| if (pad_api) |papi| {
                        if (pads[c.slot]) |p| papi.SDL_CloseGamepad(p);
                        pads[c.slot] = null;
                        try err.print("gamepad: player {d} disconnected\n", .{@as(u32, c.slot) + 1});
                        if (inp.compact(&binds)) |mv| {
                            pads[mv.to] = pads[mv.from];
                            pads[mv.from] = null;
                            try err.print("gamepad: player {d} is now player {d}\n", .{
                                @as(u32, mv.from) + 1, @as(u32, mv.to) + 1,
                            });
                        }
                        try err.flush();
                    },
                    else => {},
                }
                continue;
            }

            if (mnu) |*m| {
                repeater.feed(nev);
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
                        at_power_on = true;
                        discardMovieModes(gpa, &rec, &rec_anchor, &play_movie, "reset", err);
                        mnu = null;
                    },
                    .save_state => {
                        saveStateTo(io, con, slot_paths[slot] orelse legacy_state_path, slot, state_buf, err);
                        if (info_open) refreshSlots(io, &slot_paths, legacy_state_path, &slot_infos);
                        if (rec) |r| {
                            rec_marks[slot] = @intCast(r.items.len);
                            rec_audio[slot] = audio_hash;
                        }
                        toast.set("STATE SAVED - SLOT {d}", .{slot});
                        mnu = null;
                    },
                    .load_state => {
                        if (loadStateFrom(io, con, slot_paths[slot] orelse legacy_state_path, slot, state_buf, err)) {
                            // The state carried its own SRAM; make the .srm
                            // agree with what the machine now holds.
                            if (sram) |*s| s.flush(io, con, err);
                            // History no longer leads to this present.
                            if (rw) |*r| r.clear();
                            at_power_on = false;
                            if (rewindRecToSlot(gpa, &rec, &rec_anchor, &play_movie, &rec_marks, &rec_audio, &audio_hash, slot, err)) |f|
                                toast.set("STATE LOADED - REC REWOUND TO {d}", .{f})
                            else
                                toast.set("STATE LOADED - SLOT {d}", .{slot});
                        } else toast.set("NO STATE IN SLOT {d}", .{slot});
                        mnu = null;
                    },
                    .slot_next => {
                        slot = if (slot == 8) 1 else slot + 1;
                        toast.set("SLOT {d}", .{slot});
                    },
                    .slot_prev => {
                        slot = if (slot == 1) 8 else slot - 1;
                        toast.set("SLOT {d}", .{slot});
                    },
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
                    at_power_on = true;
                    discardMovieModes(gpa, &rec, &rec_anchor, &play_movie, "reset", err);
                },
                .save_state => {
                    saveStateTo(io, con, slot_paths[slot] orelse legacy_state_path, slot, state_buf, err);
                    if (info_open) refreshSlots(io, &slot_paths, legacy_state_path, &slot_infos);
                    if (rec) |r| {
                        rec_marks[slot] = @intCast(r.items.len);
                        rec_audio[slot] = audio_hash;
                    }
                    toast.set("STATE SAVED - SLOT {d}", .{slot});
                },
                .load_state => {
                    if (loadStateFrom(io, con, slot_paths[slot] orelse legacy_state_path, slot, state_buf, err)) {
                        if (sram) |*s| s.flush(io, con, err);
                        if (rw) |*r| r.clear();
                        at_power_on = false;
                        if (rewindRecToSlot(gpa, &rec, &rec_anchor, &play_movie, &rec_marks, &rec_audio, &audio_hash, slot, err)) |f|
                            toast.set("STATE LOADED - REC REWOUND TO {d}", .{f})
                        else
                            toast.set("STATE LOADED - SLOT {d}", .{slot});
                    } else toast.set("NO STATE IN SLOT {d}", .{slot});
                },
                .record_movie => {
                    if (rec != null) {
                        // Stop: the movie's hashes describe the machine as it
                        // stands right now, after the last recorded frame.
                        writeMovie(io, gpa, &opts, con, rec.?.items, rec_anchor, audio_hash, err);
                        rec.?.deinit();
                        rec = null;
                        if (rec_anchor) |a| gpa.free(a);
                        rec_anchor = null;
                        rec_marks = @splat(null);
                        toast.set("RECORDING SAVED", .{});
                    } else if (play_movie != null and play_idx < play_movie.?.frames.len) {
                        try err.print("movie: cannot record during playback\n", .{});
                        try err.flush();
                        toast.set("CANNOT RECORD DURING PLAYBACK", .{});
                    } else if (opts.movies_dir == null) {
                        try err.print("movie: recording unavailable — no per-user data directory\n", .{});
                        try err.flush();
                    } else if (at_power_on) {
                        // Nothing has run yet, so the inputs alone reconstruct
                        // the session: no anchor, and the file stays version 1.
                        if (rw) |*r| r.clear();
                        audio_hash = core.console.audio_hash_init;
                        rec = .init(gpa);
                        rec_marks = @splat(null);
                        try err.print("movie: recording from power-on (press again to stop and save)\n", .{});
                        try err.flush();
                        toast.set("RECORDING FROM POWER-ON - F10 STOPS", .{});
                    } else {
                        // Mid-session: capture the machine as the anchor the
                        // movie will carry. Recording a late stage should not
                        // require replaying the road to it — but the take is
                        // only honest if the anchor is captured BEFORE the
                        // first recorded frame runs, which is here.
                        if (gpa.alloc(u8, core.AnyConsole.state_size)) |anchor| {
                            _ = con.saveState(anchor);
                            rec_anchor = anchor;
                            if (rw) |*r| r.clear();
                            audio_hash = core.console.audio_hash_init;
                            rec = .init(gpa);
                            rec_marks = @splat(null);
                            try err.print("movie: recording from here ({d} KiB start state carried; press again to stop and save)\n", .{anchor.len / 1024});
                            try err.flush();
                            toast.set("RECORDING FROM HERE - F10 STOPS", .{});
                        } else |_| {
                            try err.print("movie: cannot record — out of memory for the start state\n", .{});
                            try err.flush();
                            toast.set("RECORDING FAILED - OUT OF MEMORY", .{});
                        }
                    }
                },
                .slot_next => {
                    slot = if (slot == 8) 1 else slot + 1;
                    try err.print("state slot {d}\n", .{slot});
                    try err.flush();
                    toast.set("SLOT {d}", .{slot});
                },
                .slot_prev => {
                    slot = if (slot == 1) 8 else slot - 1;
                    try err.print("state slot {d}\n", .{slot});
                    try err.flush();
                    toast.set("SLOT {d}", .{slot});
                },
                .screenshot => {
                    if (opts.shots_dir != null) {
                        shot_requested = true;
                    } else {
                        try err.print("screenshot unavailable: no per-user data directory\n", .{});
                        try err.flush();
                    }
                },
                .cheats => {
                    if (opts.n_pokes == 0) {
                        toast.set("NO CHEAT CODES LOADED", .{});
                    } else {
                        cheats_on = !cheats_on;
                        if (cheats_on) toast.set("CHEATS ON", .{}) else toast.set("CHEATS OFF", .{});
                    }
                },
                .info => {
                    info_open = !info_open;
                    if (info_open) refreshSlots(io, &slot_paths, legacy_state_path, &slot_infos);
                },
                // Hotplug actions can only come from pad_added/removed,
                // which the branch above consumed.
                .pad_opened, .pad_closed => unreachable,
            }
        }

        // A held Up/Down keeps scrolling the menu without a fresh keypress
        // per row; never during a remap capture, where a raw held key is
        // being bound instead. Up/Down only ever move a cursor, so the
        // Request this produces is always .none — .up/.down never adjust a
        // value or toggle anything.
        if (mnu) |*m| if (!m.capturing()) if (repeater.tick()) |nav| {
            const mctx: menu.Ctx = .{
                .gpa = gpa,
                .game_id = opts.game_id,
                .shader_name = if (glv) |g| g.names[g.index] else null,
            };
            std.debug.assert(m.handleNav(opts.cfg, nav, mctx) == .none);
        };

        // Holding rewind freezes forward time and steps history back one
        // capture per displayed frame (~real-time backwards); at the end
        // of history it just holds the oldest frame.
        const rewinding = mnu == null and inp.rewindHeld() and rw != null and opts.cfg.rewind.enabled;
        const halted = paused or mnu != null or rewinding;
        fast_forward = inp.ffHeld() and !halted;
        // During playback the movie owns both pads; live input resumes the
        // frame after it ends.
        const feed: [2]u16 = if (play_movie) |m|
            (if (play_idx < m.frames.len) m.frames[play_idx] else .{ inp.masks[0], inp.masks[1] })
        else
            .{ inp.masks[0], inp.masks[1] };
        con.setButtons(0, feed[0]);
        con.setButtons(1, feed[1]);
        if (rewinding) {
            _ = rw.?.rewindStep(con);
            discardMovieModes(gpa, &rec, &rec_anchor, &play_movie, "rewind", err);
        } else if (!halted) {
            con.runFrame();
            frames_run += 1;
            at_power_on = false;
            // AFTER the frame: the value the next frame reads must be the
            // cheat's, not whatever the game just stored over it.
            if (cheats_on and opts.n_pokes != 0) _ = util.cheat.apply(con, opts.pokes[0..opts.n_pokes]);
            if (rec) |*r| r.append(feed) catch {};
            if (play_movie) |m| {
                if (play_idx < m.frames.len) {
                    play_idx += 1;
                    // The frame the movie ends on is the one its hashes
                    // describe — checked below, after its audio drains.
                    if (play_idx == m.frames.len) movie_end_check = true;
                }
            }
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
        } else if (info_open) blk: {
            @memcpy(compose[0..fb.len], fb);
            const surf = ui.Surface.init(compose[0..fb.len], width, height);
            // game_id is `<sha16>-<title-slug>`; the slug half is the human
            // name. A bare-hash id (blank title) shows as itself.
            const title = if (opts.game_id.len > 17) opts.game_id[17..] else opts.game_id;
            const inf: infopanel.Info = .{
                .title = title,
                .rom_name = std.fs.path.basename(opts.rom),
                .patch_name = opts.patch_name,
                .chip = switch (con.cartridge().chip) {
                    .none => null,
                    .dsp => "DSP",
                    .sa1 => "SA-1",
                    .superfx => "SUPER FX",
                    .cx4 => "CX4",
                    .sdd1 => "S-DD1",
                    .other => "COPROC",
                },
                .core = @tagName(opts.accuracy),
                .region = @tagName(con.region()),
                .shader = if (glv) |g| g.names[g.index] else null,
                .audio_on = audio_on and audio != null,
                .volume = opts.cfg.effectiveVolume(),
                .slot = slot,
                .slots = slot_infos,
            };
            infopanel.draw(&surf, &inf);
            break :blk compose[0..fb.len];
        } else if (rewinding) blk: {
            @memcpy(compose[0..fb.len], fb);
            const surf = ui.Surface.init(compose[0..fb.len], width, height);
            ui.drawText(&surf, 4, 4, "<< REWIND", ui.color.accent);
            break :blk compose[0..fb.len];
        } else if (rec != null or (play_movie != null and play_idx < play_movie.?.frames.len)) blk: {
            @memcpy(compose[0..fb.len], fb);
            const surf = ui.Surface.init(compose[0..fb.len], width, height);
            ui.drawText(&surf, 4, 4, if (rec != null) "* REC" else "> MOVIE", ui.color.accent);
            break :blk compose[0..fb.len];
        } else fb;
        // The toast rides ON TOP of whatever the ladder picked; when the
        // ladder picked the raw framebuffer it gets its own compose copy.
        const final_px: []const u16 = if (toast.frames == 0) src_px else blk: {
            toast.frames -= 1;
            if (src_px.ptr != compose.ptr) @memcpy(compose[0..fb.len], fb);
            const surf = ui.Surface.init(compose[0..fb.len], width, height);
            const ty: i32 = @as(i32, @intCast(height)) - @as(i32, @intCast(ui.line_h)) - 4;
            ui.fillRect(&surf, 2, ty - 2, ui.textWidth(toast.buf[0..toast.len]) + 4, ui.line_h + 2, ui.color.panel);
            ui.drawText(&surf, 4, ty, toast.buf[0..toast.len], ui.color.accent);
            break :blk compose[0..fb.len];
        };

        if (glv) |g| gl_path: {
            g.chain().upload(final_px, width, height);
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
            _ = sdl.SDL_UpdateTexture(texture.?, null, final_px.ptr, @intCast(width * 2));
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

        // End of a replay: the movie's hashes describe the machine right
        // after its final frame (and that frame's audio), which is now.
        if (movie_end_check) {
            movie_end_check = false;
            if (play_movie) |m| {
                if (m.end_frame_hash == 0) {
                    try err.print("movie: {} frames replayed (no end hashes recorded — sync unverified); input is live\n", .{m.frames.len});
                } else {
                    const fh = core.console.hashFrame(con.framebuffer());
                    const audio_ok = m.end_audio_hash == 0 or audio_hash == m.end_audio_hash;
                    if (fh == m.end_frame_hash and audio_ok) {
                        try err.print("movie: sync verified — {} frames replayed; input is live\n", .{m.frames.len});
                    } else {
                        try err.print("movie: DESYNC — end frame hash {x:0>16} (movie {x:0>16}), audio {s}\n", .{
                            fh, m.end_frame_hash, if (audio_ok) "ok" else "diverged",
                        });
                    }
                }
                try err.flush();
            }
        }

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
/// Row 0 is always "ADD ROM FOLDER", which opens an in-app folder browser
/// (`dirpicker.zig`) instead of requiring a hand-edit of config.zon; picking
/// a folder appends it to `cfg.library.rom_dirs`, persists `cfg` (when
/// `config_path` is set), and restarts the scan to pick it up immediately.
/// Returns the selected entry's path (duped into `gpa`), or null to quit.
pub fn runLibrary(
    io: std.Io,
    gpa: std.mem.Allocator,
    sdl: sdl3.Api,
    scale: u32,
    lib: *library.Library,
    cfg: *config.Config,
    config_path: ?[]const u8,
    cache_path: ?[]const u8,
    patches_dir: ?[]const u8,
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
    var scanner = library.Scanner.begin(gpa, io, cfg.library.rom_dirs, err);
    var cursor: usize = 0;
    var scroll: usize = 0;
    const visible_rows = 17;
    // Hold-to-scroll for both the game list and the folder browser.
    var repeater: menu.Repeater = .{};

    // Patch availability: the folder index is built once, and every entry's
    // PATCH tag is refreshed from it now (cached entries) and again when a
    // scan completes (fresh ones).
    var patch_index = patchfind.FolderIndex.build(io, gpa, patches_dir);
    refreshPatchTags(io, gpa, lib, &patch_index);

    // Row 0 of the list is always the ADD ROM FOLDER action, so the browser
    // never depends on a hand-edited config.zon. `.prompt` is the two-row
    // patched-or-original question for a game with a patch available;
    // `.offer` proposes generating a FastROM patch for a SlowROM game that
    // has none; `.generating` runs that session incrementally with a
    // progress screen (the scanner's budget pattern — no thread) and lands
    // in `.prompt` on success or `.genfail` on failure; `.picker` owns the
    // folder browser while it's open; `.list` is the game list.
    const Mode = enum { list, picker, prompt, offer, generating, genfail };
    var mode: Mode = .list;
    var picker: ?dirpicker.Picker = null;
    defer if (picker) |*pk| pk.deinit();
    // The entry the prompt/offer/generation is about, and where the list
    // cursor goes back to.
    var prompt_entry: usize = 0;
    var saved_cursor: usize = 0;
    // The generation session, the ROM bytes it borrows, the latest progress
    // for the screen, the failure for `.genfail`, and the measured-effect
    // note a successful generation adds to the patched-or-original prompt.
    var gen_session: ?util.GenSession = null;
    var gen_rom: ?[]u8 = null;
    var gen_progress: util.GenSession.Progress = .{ .phase = .baseline, .frame = 0, .total = 1 };
    var gen_failure: ?util.GenFailure = null;
    var gen_note: [48]u8 = undefined;
    var gen_note_len: usize = 0;
    defer if (gen_session) |*s| s.deinit();
    defer if (gen_rom) |r| gpa.free(r);

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
            repeater.feed(nev);
            const n = switch (mode) {
                .list => lib.entries.items.len + 1,
                .picker => picker.?.rowCount(),
                .prompt => 2,
                .offer => 3,
                .generating => 0,
                .genfail => 1,
            };
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
                .confirm => switch (mode) {
                    .list => if (cursor == 0) {
                        picker = dirpicker.Picker.init(gpa, io, cfg.library.show_hidden_folders);
                        mode = .picker;
                        cursor = 0;
                        scroll = 0;
                    } else if (cursor - 1 < lib.entries.items.len) {
                        const e = &lib.entries.items[cursor - 1];
                        if (e.has_patch) {
                            // Ask patched-or-original, preselecting the
                            // remembered choice (default: original — the
                            // saves the player already has stay in front).
                            mode = .prompt;
                            prompt_entry = cursor - 1;
                            saved_cursor = cursor;
                            gen_note_len = 0;
                            cursor = blk: {
                                if (cfg.perGame(e.game_id)) |p| if (p.patch) |c| {
                                    break :blk if (c == .patched) 0 else 1;
                                };
                                break :blk 1;
                            };
                        } else if (genCandidate(e, cfg, patches_dir)) {
                            // No patch, but this SlowROM game could have one
                            // made: offer it, defaulting to just playing.
                            mode = .offer;
                            prompt_entry = cursor - 1;
                            saved_cursor = cursor;
                            cursor = 0;
                        } else {
                            picked = cursor - 1;
                        }
                    },
                    .prompt => {
                        const e = &lib.entries.items[prompt_entry];
                        if (cfg.perGameMut(gpa, e.game_id)) |pg| {
                            pg.patch = if (cursor == 0) .patched else .original;
                            if (config_path) |p| config.save(io, gpa, cfg.*, p) catch |se| {
                                err.print("warning: cannot write {s}: {s}\n", .{ p, @errorName(se) }) catch {};
                                err.flush() catch {};
                            };
                        } else |_| {}
                        picked = prompt_entry;
                        cursor = saved_cursor;
                        mode = .list;
                    },
                    .offer => switch (cursor) {
                        0 => { // PLAY ORIGINAL (ask again next time)
                            picked = prompt_entry;
                            cursor = saved_cursor;
                            mode = .list;
                        },
                        1 => { // GENERATE FASTROM PATCH
                            const e = &lib.entries.items[prompt_entry];
                            if (startGeneration(io, gpa, e.path, &gen_rom, err)) |session| {
                                gen_session = session;
                                gen_progress = .{ .phase = .baseline, .frame = 0, .total = session.total };
                                mode = .generating;
                            } else {
                                // Could not even start (unreadable ROM, OOM):
                                // the reason is on stderr; just play.
                                picked = prompt_entry;
                                cursor = saved_cursor;
                                mode = .list;
                            }
                        },
                        else => { // PLAY, NEVER ASK FOR THIS GAME
                            const e = &lib.entries.items[prompt_entry];
                            if (cfg.perGameMut(gpa, e.game_id)) |pg| {
                                pg.offer_gen = false;
                                if (config_path) |p| config.save(io, gpa, cfg.*, p) catch |se| {
                                    err.print("warning: cannot write {s}: {s}\n", .{ p, @errorName(se) }) catch {};
                                    err.flush() catch {};
                                };
                            } else |_| {}
                            picked = prompt_entry;
                            cursor = saved_cursor;
                            mode = .list;
                        },
                    },
                    .generating => {}, // nothing to confirm; B cancels
                    .genfail => { // PLAY ORIGINAL
                        picked = prompt_entry;
                        cursor = saved_cursor;
                        mode = .list;
                    },
                    .picker => switch (picker.?.activate(io, cursor)) {
                        .use_folder => |path| {
                            cfg.addRomDir(gpa, path) catch {};
                            if (config_path) |p| config.save(io, gpa, cfg.*, p) catch |e| {
                                err.print("warning: cannot write {s}: {s}\n", .{ p, @errorName(e) }) catch {};
                                err.flush() catch {};
                            };
                            picker.?.deinit();
                            picker = null;
                            mode = .list;
                            scanner = library.Scanner.begin(gpa, io, cfg.library.rom_dirs, err);
                            cursor = 0;
                            scroll = 0;
                        },
                        .toggled_hidden => |show| {
                            cfg.library.show_hidden_folders = show;
                            if (config_path) |p| config.save(io, gpa, cfg.*, p) catch |e| {
                                err.print("warning: cannot write {s}: {s}\n", .{ p, @errorName(e) }) catch {};
                                err.flush() catch {};
                            };
                            // Cursor stays put (the toggle row you just
                            // pressed); the post-poll clamp below catches it
                            // if the re-filtered listing got shorter.
                        },
                        .none => {
                            cursor = 0;
                            scroll = 0;
                        },
                    },
                },
                .back, .close => switch (mode) {
                    .list => return null,
                    .picker => {
                        picker.?.deinit();
                        picker = null;
                        mode = .list;
                        cursor = 0;
                        scroll = 0;
                    },
                    .prompt, .offer, .genfail => {
                        cursor = saved_cursor;
                        mode = .list;
                    },
                    .generating => {
                        // Cancel: throw the half-done session away.
                        if (gen_session) |*s| s.deinit();
                        gen_session = null;
                        if (gen_rom) |r| gpa.free(r);
                        gen_rom = null;
                        cursor = saved_cursor;
                        mode = .list;
                    },
                },
            }
        }

        // A held Up/Down keeps scrolling without a fresh keypress per row —
        // .up/.down only ever move `cursor` here, same as a real press.
        if (repeater.tick()) |nav| {
            const n = switch (mode) {
                .list => lib.entries.items.len + 1,
                .picker => picker.?.rowCount(),
                .prompt => 2,
                .offer => 3,
                .generating => 0,
                .genfail => 1,
            };
            switch (nav) {
                .up => if (n != 0) {
                    cursor = if (cursor == 0) n - 1 else cursor - 1;
                },
                .down => if (n != 0) {
                    cursor = if (cursor + 1 >= n) 0 else cursor + 1;
                },
                else => {},
            }
        }

        if (picked) |i| return try gpa.dupe(u8, lib.entries.items[i].path);

        // Scan under a per-frame time budget so the list fills while the
        // screen stays live; persist the cache the moment it completes.
        const deadline = sdl.SDL_GetTicksNS() + 6 * std.time.ns_per_ms;
        while (!scanner.done and sdl.SDL_GetTicksNS() < deadline) {
            if (scanner.stepOne(io, lib)) {
                refreshPatchTags(io, gpa, lib, &patch_index);
                if (cache_path) |p| lib.saveCache(io, gpa, p) catch {};
            }
        }

        // The generation session gets the same treatment as the scanner: a
        // per-frame time budget on the main loop, one emulated frame per
        // step, screen still live in between.
        if (mode == .generating) {
            const gen_deadline = sdl.SDL_GetTicksNS() + 12 * std.time.ns_per_ms;
            step: while (sdl.SDL_GetTicksNS() < gen_deadline) {
                const status = gen_session.?.step(1) catch |e| {
                    err.print("generation failed: {s}\n", .{@errorName(e)}) catch {};
                    err.flush() catch {};
                    gen_session.?.deinit();
                    gen_session = null;
                    gpa.free(gen_rom.?);
                    gen_rom = null;
                    cursor = saved_cursor;
                    mode = .list;
                    break :step;
                };
                switch (status) {
                    .running => |p| gen_progress = p,
                    .done => |outcome| {
                        gen_failure = null; // a write failure below is its own story
                        finishGeneration(io, gpa, lib, patches_dir.?, prompt_entry, outcome, &gen_note, &gen_note_len, err);
                        gen_session.?.deinit();
                        gen_session = null;
                        gpa.free(gen_rom.?);
                        gen_rom = null;
                        // Rebuild the index so the new patch is discovered,
                        // then land in the patched-or-original prompt with
                        // PLAY PATCHED preselected.
                        patch_index = patchfind.FolderIndex.build(io, gpa, patches_dir);
                        refreshPatchTags(io, gpa, lib, &patch_index);
                        mode = if (lib.entries.items[prompt_entry].has_patch) .prompt else .genfail;
                        cursor = 0;
                        break :step;
                    },
                    .failed => |f| {
                        gen_failure = f;
                        // A game that cannot convert is not offered again.
                        const e = &lib.entries.items[prompt_entry];
                        if (cfg.perGameMut(gpa, e.game_id)) |pg| {
                            pg.offer_gen = false;
                            if (config_path) |p| config.save(io, gpa, cfg.*, p) catch {};
                        } else |_| {}
                        gen_session.?.deinit();
                        gen_session = null;
                        gpa.free(gen_rom.?);
                        gen_rom = null;
                        mode = .genfail;
                        cursor = 0;
                        break :step;
                    },
                }
            }
        }

        const total = switch (mode) {
            .list => lib.entries.items.len + 1,
            .picker => picker.?.rowCount(),
            .prompt => 2,
            .offer => 3,
            .generating => 1,
            .genfail => 1,
        };
        if (cursor >= total and total != 0) cursor = total - 1;
        if (cursor < scroll) scroll = cursor;
        if (cursor >= scroll + visible_rows) scroll = cursor - visible_rows + 1;

        switch (mode) {
            .list => drawLibraryScreen(&canvas, lib, cursor, scroll, visible_rows, cfg.library.rom_dirs.len == 0, if (scanner.done) null else scanner.remaining()),
            .picker => drawPickerScreen(&canvas, &picker.?, cursor, scroll, visible_rows),
            .prompt => drawPatchPromptScreen(&canvas, lib.entries.items[prompt_entry].title, cursor, if (gen_note_len != 0) gen_note[0..gen_note_len] else null),
            .offer => drawOfferScreen(&canvas, lib.entries.items[prompt_entry].title, cursor),
            .generating => drawGeneratingScreen(&canvas, lib.entries.items[prompt_entry].title, gen_progress),
            .genfail => drawGenFailScreen(&canvas, lib.entries.items[prompt_entry].title, gen_failure),
        }

        _ = sdl.SDL_UpdateTexture(texture, null, &canvas, 256 * 2);
        _ = sdl.SDL_RenderClear(renderer);
        _ = sdl.SDL_RenderTexture(renderer, texture, null, null);
        _ = sdl.SDL_RenderPresent(renderer);
        sdl.SDL_DelayNS(16 * std.time.ns_per_ms);
    }
}

/// The library's whole frame, drawn into a 256x224 canvas — pure pixels, so
/// the layout is testable and eyeballable without SDL. `scanning_left` is
/// null once the scan has completed. Row 0 is always the ADD ROM FOLDER
/// action; rows 1.. are `lib.entries` shifted by one.
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
        ui.drawTextCentered(&surf, 100, "NO ROM FOLDERS YET", ui.color.text);
        ui.drawTextCentered(&surf, 114, "SELECT ADD ROM FOLDER BELOW", ui.color.text_dim);
    } else if (lib.entries.items.len == 0 and scanning_left == null) {
        ui.drawTextCentered(&surf, 100, "NO SNES ROMS FOUND", ui.color.text);
    }

    const total = lib.entries.items.len + 1;
    for (0..visible_rows) |row| {
        const i = scroll + row;
        if (i >= total) break;
        const y: i32 = @intCast(20 + row * ui.line_h);
        const selected = i == cursor;
        if (selected) ui.drawText(&surf, 2, y, ">", ui.color.accent);
        const fg = if (selected) ui.color.text else ui.color.text_dim;
        if (i == 0) {
            ui.drawText(&surf, 10, y, "+ ADD ROM FOLDER", if (selected) ui.color.accent else ui.color.text_dim);
            continue;
        }
        const e = lib.entries.items[i - 1];
        const max_title = 32;
        ui.drawText(&surf, 10, y, e.title[0..@min(e.title.len, max_title)], fg);
        var tag: [24]u8 = undefined;
        const patch_txt = if (e.has_patch) "PATCH " else "";
        const tag_txt = if (e.chip.len != 0)
            std.fmt.bufPrint(&tag, "{s}{s} {s}", .{ patch_txt, e.chip, e.region }) catch e.region
        else if (e.has_patch)
            std.fmt.bufPrint(&tag, "{s}{s}", .{ patch_txt, e.region }) catch e.region
        else
            e.region;
        ui.drawText(&surf, 248 - @as(i32, @intCast(ui.textWidth(tag_txt))), y, tag_txt, ui.color.text_dim);
    }

    if (scanning_left) |left| {
        var foot: [40]u8 = undefined;
        const t = std.fmt.bufPrint(&foot, "SCANNING... {d} LEFT", .{left}) catch "";
        ui.drawText(&surf, 8, 212, t, ui.color.accent);
    } else {
        ui.drawText(&surf, 8, 212, "ENTER/A SELECT  ESC/B QUIT", ui.color.text_dim);
    }
}

/// Refresh every entry's PATCH tag from the current filesystem state: a
/// same-basename softpatch or a patch-folder match by cached CRC32. Cheap —
/// one stat-or-small-read per entry plus the prebuilt folder index.
fn refreshPatchTags(
    io: std.Io,
    gpa: std.mem.Allocator,
    lib: *library.Library,
    idx: *const patchfind.FolderIndex,
) void {
    for (lib.entries.items) |*e| {
        e.has_patch = e.crc32 != 0 and
            patchfind.quickAvailable(io, gpa, e.path, e.crc32, idx);
    }
}

/// The patched-or-original question for a game with a patch available — the
/// same pure-pixel shape as the other screens, so it rides the same tests.
/// Row 0 = PLAY PATCHED, row 1 = PLAY ORIGINAL. `note` is the measured-effect
/// line a just-finished generation adds.
fn drawPatchPromptScreen(canvas: *[256 * 224]u16, title: []const u8, cursor: usize, note: ?[]const u8) void {
    const surf = ui.Surface.init(canvas, 256, 224);
    ui.fillRect(&surf, 0, 0, 256, 224, ui.color.panel);
    ui.drawText(&surf, 8, 6, "PATCH FOUND", ui.color.accent);

    ui.drawTextCentered(&surf, 70, title[0..@min(title.len, 32)], ui.color.text);
    ui.drawTextCentered(&surf, 88, "A PATCH IS AVAILABLE FOR THIS GAME", ui.color.text_dim);
    if (note) |txt| ui.drawTextCentered(&surf, 100, txt, ui.color.accent);

    const rows = [_][]const u8{ "PLAY PATCHED", "PLAY ORIGINAL" };
    for (rows, 0..) |label, i| {
        const y: i32 = @intCast(116 + i * ui.line_h);
        const selected = i == cursor;
        if (selected) ui.drawText(&surf, 92, y, ">", ui.color.accent);
        ui.drawText(&surf, 102, y, label, if (selected) ui.color.text else ui.color.text_dim);
    }

    ui.drawTextCentered(&surf, 170, "PATCHED AND ORIGINAL KEEP SEPARATE SAVES", ui.color.text_dim);
    ui.drawText(&surf, 8, 212, "ENTER/A SELECT  ESC/B BACK  CHOICE IS REMEMBERED", ui.color.text_dim);
}

/// Is this library entry worth offering FastROM generation for? SlowROM, no
/// coprocessor (the generator would refuse those anyway), no patch already,
/// somewhere writable/discoverable to put the result, and the user has not
/// said never-ask. `map_mode == 0` means an entry the scanner has not
/// re-identified yet — unknown, so no offer.
fn genCandidate(e: *const library.Entry, cfg: *const config.Config, patches_dir: ?[]const u8) bool {
    if (patches_dir == null) return false;
    if (e.has_patch) return false;
    if (e.chip.len != 0) return false;
    if (e.map_mode == 0 or (e.map_mode & 0x10) != 0) return false;
    if (cfg.perGame(e.game_id)) |p| if (p.offer_gen) |v| if (!v) return false;
    return true;
}

/// Generation runs the same window the CLI defaults to — the standard the
/// fastrom-compat list is verified to.
const gen_frames: u32 = 1800;
const gen_skip: u32 = 300;

/// Read the ROM and open a generation session over it. On success the raw
/// file bytes are parked in `gen_rom` (the session borrows the stripped
/// view); on failure the reason is printed and null returned.
fn startGeneration(
    io: std.Io,
    gpa: std.mem.Allocator,
    rom_path: []const u8,
    gen_rom: *?[]u8,
    err: *std.Io.Writer,
) ?util.GenSession {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, rom_path, gpa, .limited(16 * 1024 * 1024)) catch {
        err.print("error: cannot read ROM '{s}'\n", .{rom_path}) catch {};
        err.flush() catch {};
        return null;
    };
    const image = core.header.stripCopierHeader(raw);
    const session = util.GenSession.start(gpa, image, gen_frames, gen_skip) catch |e| {
        err.print("error: cannot start generation: {s}\n", .{@errorName(e)}) catch {};
        err.flush() catch {};
        gpa.free(raw);
        return null;
    };
    gen_rom.* = raw;
    return session;
}

/// A successful generation: write the BPS into the patches folder (footer
/// CRC is what discovery matches, so the name is cosmetic) and format the
/// measured-effect note for the prompt. Failures print; the caller decides
/// what screen follows based on whether discovery then finds the patch.
fn finishGeneration(
    io: std.Io,
    gpa: std.mem.Allocator,
    lib: *library.Library,
    patches_dir: []const u8,
    entry_idx: usize,
    outcome: util.GenOutcome,
    note: *[48]u8,
    note_len: *usize,
    err: *std.Io.Writer,
) void {
    defer gpa.free(outcome.image);
    defer gpa.free(outcome.bps);

    const e = &lib.entries.items[entry_idx];
    const base = std.fs.path.basename(e.path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
    const path = std.fmt.allocPrint(gpa, "{s}/{s}.bps", .{ patches_dir, base[0..dot] }) catch return;
    defer gpa.free(path);

    std.Io.Dir.cwd().createDirPath(io, patches_dir) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = outcome.bps }) catch {
        err.print("error: cannot write '{s}'\n", .{path}) catch {};
        err.flush() catch {};
        return;
    };
    err.print("generated {s} ({} bytes; verified {} frames)\n", .{
        path, outcome.bps.len, gen_skip + gen_frames,
    }) catch {};
    err.flush() catch {};

    const txt = std.fmt.bufPrint(note, "GENERATED + VERIFIED  UTIL {d:.0}% > {d:.0}%", .{
        outcome.base.mean_util * 100, outcome.fast.mean_util * 100,
    }) catch return;
    note_len.* = txt.len;
}

/// The generation offer: play as-is, make a patch, or never ask again.
fn drawOfferScreen(canvas: *[256 * 224]u16, title: []const u8, cursor: usize) void {
    const surf = ui.Surface.init(canvas, 256, 224);
    ui.fillRect(&surf, 0, 0, 256, 224, ui.color.panel);
    ui.drawText(&surf, 8, 6, "FASTROM CANDIDATE", ui.color.accent);

    ui.drawTextCentered(&surf, 62, title[0..@min(title.len, 32)], ui.color.text);
    ui.drawTextCentered(&surf, 80, "THIS SLOWROM GAME MIGHT RUN FASTER WITH A", ui.color.text_dim);
    ui.drawTextCentered(&surf, 90, "GENERATED FASTROM PATCH, VERIFIED IN-EMULATOR", ui.color.text_dim);

    const rows = [_][]const u8{ "PLAY ORIGINAL", "GENERATE FASTROM PATCH", "PLAY, NEVER ASK FOR THIS GAME" };
    for (rows, 0..) |label, i| {
        const y: i32 = @intCast(116 + i * ui.line_h);
        const selected = i == cursor;
        if (selected) ui.drawText(&surf, 44, y, ">", ui.color.accent);
        ui.drawText(&surf, 54, y, label, if (selected) ui.color.text else ui.color.text_dim);
    }

    ui.drawTextCentered(&surf, 176, "GENERATION PLAYS THE GAME TWICE TO PROVE THE", ui.color.text_dim);
    ui.drawTextCentered(&surf, 186, "PATCH CHANGES NOTHING YOU SEE OR HEAR", ui.color.text_dim);
    ui.drawText(&surf, 8, 212, "ENTER/A SELECT  ESC/B BACK", ui.color.text_dim);
}

/// The progress screen while a generation session runs on the main loop.
fn drawGeneratingScreen(canvas: *[256 * 224]u16, title: []const u8, p: util.GenSession.Progress) void {
    const surf = ui.Surface.init(canvas, 256, 224);
    ui.fillRect(&surf, 0, 0, 256, 224, ui.color.panel);
    ui.drawText(&surf, 8, 6, "GENERATING FASTROM PATCH", ui.color.accent);

    ui.drawTextCentered(&surf, 70, title[0..@min(title.len, 32)], ui.color.text);
    ui.drawTextCentered(&surf, 96, switch (p.phase) {
        .baseline => "PASS 1/2: PROFILING THE ORIGINAL",
        .verify => "PASS 2/2: VERIFYING THE PATCHED RUN",
        .finished => "FINISHING",
    }, ui.color.text);

    var buf: [32]u8 = undefined;
    const count = std.fmt.bufPrint(&buf, "{d} / {d} FRAMES", .{ p.frame, p.total }) catch "";
    ui.drawTextCentered(&surf, 110, count, ui.color.text_dim);

    // A plain bar: outline plus fill proportional to this pass's progress.
    const bar_x: i32 = 48;
    const bar_w: u32 = 160;
    ui.fillRect(&surf, bar_x, 126, bar_w, 8, ui.color.text_dim);
    ui.fillRect(&surf, bar_x + 1, 127, bar_w - 2, 6, ui.color.panel);
    const frac: u64 = if (p.total == 0) 0 else @as(u64, p.frame) * (bar_w - 2) / p.total;
    if (frac != 0) ui.fillRect(&surf, bar_x + 1, 127, @intCast(frac), 6, ui.color.accent);

    ui.drawText(&surf, 8, 212, "ESC/B CANCEL", ui.color.text_dim);
}

/// Why no patch was produced, in library-screen shorthand; the full sentence
/// is on stderr for anyone at a terminal.
fn drawGenFailScreen(canvas: *[256 * 224]u16, title: []const u8, failure: ?util.GenFailure) void {
    const surf = ui.Surface.init(canvas, 256, 224);
    ui.fillRect(&surf, 0, 0, 256, 224, ui.color.panel);
    ui.drawText(&surf, 8, 6, "NO PATCH GENERATED", ui.color.accent);

    ui.drawTextCentered(&surf, 70, title[0..@min(title.len, 32)], ui.color.text);

    var buf: [48]u8 = undefined;
    const line1: []const u8, const line2: []const u8 = if (failure) |f| switch (f) {
        .refused => |r| .{ "THE GENERATOR REFUSED:", switch (r.reason) {
            .already_fastrom => "THE GAME IS ALREADY FASTROM",
            .coprocessor => "COPROCESSOR CARTRIDGE",
            .exhirom => "EXHIROM MAPPING UNSUPPORTED",
            .reset_vector_not_rom => "RESET VECTOR NOT IN ROM",
            .no_free_space => "NO FREE SPACE FOR THE STUB",
            .memsel_store_unpatchable => "UNPATCHABLE MEMSEL STORE",
        } },
        .frame_mismatch => |frame| .{
            std.fmt.bufPrint(&buf, "VERIFY FAILED AT FRAME {d}:", .{frame}) catch "VERIFY FAILED:",
            "FASTROM TIMING CHANGES WHAT YOU SEE",
        },
        .audio_mismatch => .{ "VERIFY FAILED:", "FASTROM TIMING CHANGES WHAT YOU HEAR" },
        .memsel_lost => |frame| .{
            std.fmt.bufPrint(&buf, "VERIFY FAILED AT FRAME {d}:", .{frame}) catch "VERIFY FAILED:",
            "THE GAME DISABLED FASTROM ITSELF",
        },
    } else .{ "THE PATCH COULD NOT BE WRITTEN", "SEE THE TERMINAL FOR THE REASON" };
    ui.drawTextCentered(&surf, 96, line1, ui.color.text);
    ui.drawTextCentered(&surf, 108, line2, ui.color.text_dim);

    ui.drawTextCentered(&surf, 150, "THIS GAME WILL NOT BE OFFERED AGAIN", ui.color.text_dim);
    ui.drawText(&surf, 8, 212, "ENTER/A PLAY ORIGINAL  ESC/B BACK", ui.color.text_dim);
}

/// The folder browser's whole frame — same pure-pixel shape as
/// `drawLibraryScreen`, so it rides the same test pattern.
fn drawPickerScreen(
    canvas: *[256 * 224]u16,
    pk: *const dirpicker.Picker,
    cursor: usize,
    scroll: usize,
    visible_rows: usize,
) void {
    const surf = ui.Surface.init(canvas, 256, 224);
    ui.fillRect(&surf, 0, 0, 256, 224, ui.color.panel);
    ui.drawText(&surf, 8, 6, "ADD ROM FOLDER", ui.color.accent);

    const path_txt = if (pk.at_root) "SELECT A DRIVE" else pk.path.items;
    ui.drawText(&surf, 8, 18, path_txt, ui.color.text_dim);

    const total = pk.rowCount();
    for (0..visible_rows) |row| {
        const i = scroll + row;
        if (i >= total) break;
        const y: i32 = @intCast(30 + row * ui.line_h);
        const selected = i == cursor;
        if (selected) ui.drawText(&surf, 2, y, ">", ui.color.accent);
        const fg = if (selected) ui.color.text else ui.color.text_dim;
        ui.drawText(&surf, 10, y, pk.rowLabel(i), fg);
        const value = pk.rowValue(i);
        if (value.len != 0) {
            const vx = 248 - @as(i32, @intCast(ui.textWidth(value)));
            ui.drawText(&surf, vx, y, value, fg);
        }
    }

    if (pk.err_msg) |msg| {
        ui.drawText(&surf, 8, 212, msg, ui.color.accent);
    } else {
        ui.drawText(&surf, 8, 212, "ENTER/A SELECT  ESC/B CANCEL", ui.color.text_dim);
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
    // A list longer than the window, cursor at the end, scrolled; every tag
    // combination including the PATCH prefix.
    for (0..40) |i| {
        var name: [16]u8 = undefined;
        try lib.entries.append(a, .{
            .path = "x",
            .title = try a.dupe(u8, std.fmt.bufPrint(&name, "GAME {d}", .{i}) catch "G"),
            .region = "NTSC",
            .chip = if (i % 3 == 0) "SA-1" else "",
            .has_patch = i % 2 == 0,
        });
    }
    drawLibraryScreen(canvas, &lib, 39, 23, 17, false, null);
}

test "patch prompt screen draws both cursor rows without out-of-bounds writes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const canvas = try arena.allocator().create([256 * 224]u16);
    drawPatchPromptScreen(canvas, "SOME VERY LONG GAME TITLE THAT IS TRUNCATED", 0, null);
    drawPatchPromptScreen(canvas, "GAME", 1, "GENERATED + VERIFIED  UTIL 44% > 31%");
}

test "offer, progress, and failure screens draw every state without OOB writes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const canvas = try arena.allocator().create([256 * 224]u16);

    for (0..3) |c| drawOfferScreen(canvas, "GAME", c);

    drawGeneratingScreen(canvas, "GAME", .{ .phase = .baseline, .frame = 0, .total = 2100 });
    drawGeneratingScreen(canvas, "GAME", .{ .phase = .verify, .frame = 2099, .total = 2100 });
    drawGeneratingScreen(canvas, "GAME", .{ .phase = .verify, .frame = 0, .total = 0 });

    drawGenFailScreen(canvas, "GAME", null);
    drawGenFailScreen(canvas, "GAME", .{ .refused = .{ .reason = .no_free_space } });
    drawGenFailScreen(canvas, "GAME", .{ .frame_mismatch = 123456 });
    drawGenFailScreen(canvas, "GAME", .{ .audio_mismatch = {} });
    drawGenFailScreen(canvas, "GAME", .{ .memsel_lost = 7 });
}

test "genCandidate: SlowROM no-chip games without a patch, unless declined" {
    var cfg: config.Config = .{};
    var e: library.Entry = .{ .path = "x", .game_id = "id-x", .map_mode = 0x20 };
    try std.testing.expect(genCandidate(&e, &cfg, "patches"));
    // No writable patches dir: never offer.
    try std.testing.expect(!genCandidate(&e, &cfg, null));
    // Already has a patch, has a chip, is FastROM, or unknown map mode.
    e.has_patch = true;
    try std.testing.expect(!genCandidate(&e, &cfg, "patches"));
    e.has_patch = false;
    e.chip = "SA-1";
    try std.testing.expect(!genCandidate(&e, &cfg, "patches"));
    e.chip = "";
    e.map_mode = 0x30;
    try std.testing.expect(!genCandidate(&e, &cfg, "patches"));
    e.map_mode = 0;
    try std.testing.expect(!genCandidate(&e, &cfg, "patches"));
    e.map_mode = 0x20;
    // The user said never-ask.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const pg = try cfg.perGameMut(arena.allocator(), "id-x");
    pg.offer_gen = false;
    try std.testing.expect(!genCandidate(&e, &cfg, "patches"));
}

test "picker screen: drive list, a real listing, and an error message all draw cleanly" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const canvas = try a.create([256 * 224]u16);

    const root = ".app-picker-screen-test";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/sub");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var pk = dirpicker.Picker.initAt(a, io, root);
    defer pk.deinit();
    drawPickerScreen(canvas, &pk, 0, 0, 17);
    drawPickerScreen(canvas, &pk, 2, 0, 17); // cursor on the "sub" row

    _ = pk.activate(io, 2); // descend, then fail to go somewhere bogus
    pk.err_msg = "CANNOT OPEN THAT FOLDER";
    drawPickerScreen(canvas, &pk, 0, 0, 17);
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
        // The info palette's screenshot sidecar, from the frame on screen
        // right now. Best-effort on purpose: a thumbnail must never fail
        // (or slow) the save it decorates, and states saved before this
        // existed simply have none.
        var tp_buf: [512]u8 = undefined;
        if (std.fmt.bufPrint(&tp_buf, "{s}.thumb", .{path})) |tp| {
            var tf: [infopanel.Thumb.file_len]u8 = undefined;
            infopanel.Thumb.encode(con.framebuffer(), con.frameWidth(), &tf);
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tp, .data = &tf }) catch {};
        } else |_| {}
    } else |e| {
        err.print("state save failed: {s}\n", .{@errorName(e)}) catch {};
    }
    err.flush() catch {};
}

/// Re-gather what the info palette shows about the slots: which exist, and
/// their thumbnails. Eight stats and at most eight 7-KiB reads — palette-open
/// cost, never frame cost.
fn refreshSlots(
    io: std.Io,
    slot_paths: *const [9]?[]const u8,
    legacy_state_path: []const u8,
    infos: *[9]infopanel.SlotInfo,
) void {
    for (1..9) |n| {
        const path = slot_paths[n] orelse legacy_state_path;
        var inf: infopanel.SlotInfo = .{};
        inf.exists = if (std.Io.Dir.cwd().statFile(io, path, .{})) |_| true else |_| false;
        if (inf.exists) {
            var tp_buf: [512]u8 = undefined;
            if (std.fmt.bufPrint(&tp_buf, "{s}.thumb", .{path})) |tp| {
                var tf: [infopanel.Thumb.file_len]u8 = undefined;
                if (std.Io.Dir.cwd().readFile(io, tp, &tf)) |data| {
                    inf.thumb = infopanel.Thumb.decode(data);
                } else |_| {}
            } else |_| {}
        }
        infos[n] = inf;
    }
}

fn loadStateFrom(io: std.Io, con: *core.AnyConsole, path: []const u8, slot: u32, buf: []u8, err: *std.Io.Writer) bool {
    if (loadStateFile(io, con, path, buf)) {
        err.print("state loaded: slot {d} ({s})\n", .{ slot, path }) catch {};
        err.flush() catch {};
        return true;
    } else |e| {
        if (e == error.WrongRom)
            err.print("state load refused: slot {d} was saved on a different ROM or patch build (loading it would garble the whole machine)\n", .{slot}) catch {}
        else
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
/// Reset, load-state, and rewind rewrite history MID-TAKE, which an input
/// stream cannot follow: a recording in progress is discarded (a movie that
/// cannot replay must not be written) and a replay in progress hands input
/// back. Note this is about time travel *during* a recording — starting one
/// from a loaded state is fine, and carries that state as the movie's anchor.
/// A state load landed on `slot` while a take is recording.
///
/// If that slot holds a state saved during THIS take, the log is truncated
/// back to the frame it was saved at: replaying the take from its start now
/// reaches exactly the machine the state restored, so the recording stays
/// valid and the player keeps their progress. Returns the frame rewound to.
///
/// Marks past the cut name a branch that no longer exists. Dropping them is
/// what stops a later load from restoring a machine the truncated log cannot
/// explain — the one way this feature could silently produce a desynced movie.
///
/// A slot with no mark cannot be rewound to (the take never passed through
/// that machine), so the take is discarded as before; null says so.
/// Forget every mark past `at`. Those states were saved on a branch the
/// truncation just deleted: loading one would restore a machine the shortened
/// input log cannot reach, and the movie would replay into a different game.
fn cutMarks(marks: *[9]?u32, at: u32) void {
    for (marks) |*m| {
        if (m.*) |f| {
            if (f > at) m.* = null;
        }
    }
}

fn rewindRecToSlot(
    gpa: std.mem.Allocator,
    rec: *?std.array_list.Managed([2]u16),
    rec_anchor: *?[]u8,
    play_movie: *?util.movie.Movie,
    marks: *[9]?u32,
    audio_marks: *const [9]u64,
    audio_hash: *u64,
    slot: u32,
    err: *std.Io.Writer,
) ?u32 {
    if (rec.* == null) return null;
    const at = marks[slot] orelse {
        discardMovieModes(gpa, rec, rec_anchor, play_movie, "load of a state not saved in this take", err);
        marks.* = @splat(null);
        return null;
    };
    rec.*.?.shrinkRetainingCapacity(at);
    audio_hash.* = audio_marks[slot];
    cutMarks(marks, at);
    err.print("recording rewound to frame {d} (slot {d})\n", .{ at, slot }) catch {};
    err.flush() catch {};
    return at;
}

fn discardMovieModes(
    gpa: std.mem.Allocator,
    rec: *?std.array_list.Managed([2]u16),
    rec_anchor: *?[]u8,
    play: *?util.movie.Movie,
    why: []const u8,
    err: *std.Io.Writer,
) void {
    if (rec.*) |*r| {
        r.deinit();
        rec.* = null;
        if (rec_anchor.*) |a| gpa.free(a);
        rec_anchor.* = null;
        err.print("movie: recording discarded ({s} breaks replay determinism)\n", .{why}) catch {};
        err.flush() catch {};
    }
    if (play.* != null) {
        play.* = null;
        err.print("movie: playback stopped ({s}); input is live\n", .{why}) catch {};
        err.flush() catch {};
    }
}

/// Write a finished recording as `<movies>/<game_id>-NNNN.ymv`. The end
/// hashes are taken from the machine as it stands — the frame after the
/// last recorded input, exactly what a replay reproduces.
fn writeMovie(
    io: std.Io,
    gpa: std.mem.Allocator,
    opts: *const Options,
    con: *core.AnyConsole,
    frames: []const [2]u16,
    anchor: ?[]u8,
    audio_hash: u64,
    err: *std.Io.Writer,
) void {
    const dir = opts.movies_dir orelse return;
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    var path_buf: [512]u8 = undefined;
    var n: u32 = 1;
    const path = while (n <= 9999) : (n += 1) {
        const p = std.fmt.bufPrint(&path_buf, "{s}/{s}-{d:0>4}{s}", .{ dir, opts.game_id, n, util.movie.file_ext }) catch return;
        std.Io.Dir.cwd().access(io, p, .{}) catch break p;
    } else return;
    const m: util.movie.Movie = .{
        .accuracy = if (opts.accuracy == .accurate) 1 else 0,
        .region = if (con.region() == .pal) 1 else 0,
        .rom_crc = opts.rom_crc,
        .end_frame_hash = core.console.hashFrame(con.framebuffer()),
        .end_audio_hash = audio_hash,
        .frames = @constCast(frames),
        .anchor = anchor,
    };
    const data = util.movie.encode(gpa, m) catch |e| {
        err.print("movie: save failed: {s}\n", .{@errorName(e)}) catch {};
        err.flush() catch {};
        return;
    };
    defer gpa.free(data);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch |e| {
        err.print("movie: save failed: {s}\n", .{@errorName(e)}) catch {};
        err.flush() catch {};
        return;
    };
    err.print("movie: {s} ({} frames{s}, end hashes recorded)\n", .{
        path, frames.len, if (anchor != null) ", anchored to a start state" else ", from power-on",
    }) catch {};
    err.flush() catch {};
}

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

const InitGlError = error{ NoGlSymbols, NoContext, NoVariantForThisGpu, ShaderDirNotFound, ShaderNotBaked };

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
    // Base handle only for SDL_GetError diagnostics on the failure paths — a
    // silent `continue` per profile hid WHY every GL context creation failed
    // (measured: a machine where all three rungs returned null and the user
    // could not tell a driver problem from a missing shader variant).
    const base = sdl3.load() catch return InitGlError.NoGlSymbols;

    // Distinguish the three ways this fails so the message is honest: the
    // shader DIRECTORY was not found (the common one — `--shader-dir` defaults
    // to "shaders" relative to the working directory, so launching the exe
    // from anywhere but the repo root finds nothing), the requested preset is
    // not among the baked ones, or every GL context genuinely failed. Blaming
    // the GPU for a missing directory cost a real debugging cycle.
    var any_dir_listed = false;
    var name_seen = false;

    for (profiles) |prof| {
        // Which presets exist for this profile is the gate: no point holding a
        // context we cannot use. The listing doubles as the `,`/`.` cycle order.
        const profile_dir = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ shader_root, prof.dir });
        const names = listPresets(io, gpa, profile_dir) catch continue;
        any_dir_listed = true;
        const start = indexOfName(names, name) orelse continue;
        name_seen = true;

        _ = sdl_gl.SDL_GL_SetAttribute(sdl3.gl_attr.context_profile_mask, prof.profile_mask);
        _ = sdl_gl.SDL_GL_SetAttribute(sdl3.gl_attr.context_major_version, prof.major);
        _ = sdl_gl.SDL_GL_SetAttribute(sdl3.gl_attr.context_minor_version, prof.minor);
        _ = sdl_gl.SDL_GL_SetAttribute(sdl3.gl_attr.doublebuffer, 1);
        _ = sdl_gl.SDL_GL_SetAttribute(sdl3.gl_attr.depth_size, 0);
        _ = sdl_gl.SDL_GL_SetAttribute(sdl3.gl_attr.stencil_size, 0);

        const ctx = sdl_gl.SDL_GL_CreateContext(window) orelse {
            err.print("  gl: {s} (GL {d}.{d}) context creation failed: {s}\n", .{
                prof.dir, prof.major, prof.minor, base.SDL_GetError(),
            }) catch {};
            err.flush() catch {};
            continue;
        };
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
    if (!any_dir_listed) {
        err.print("  gl: no baked shader presets under '{s}' (set --shader-dir to the yamabuki 'shaders' directory)\n", .{shader_root}) catch {};
        err.flush() catch {};
        return InitGlError.ShaderDirNotFound;
    }
    if (!name_seen) return InitGlError.ShaderNotBaked;
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
    // Parsed into the scratch arena, not a local: a Preset is ~280 KiB and
    // this function is on the shader-cycling path.
    const p = try a.create(preset.Preset);
    try preset.parse(p, manifest);
    try out.init(io, a, g.api, g.gles_major, p.*, dir, err);
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

test "rec marks: rewinding forgets the branch it deleted" {
    // Slot 1 at frame 100, slot 2 at 500. Rewinding to 100 keeps slot 1 and
    // drops slot 2 — after the cut the take never reaches frame 500, so a
    // load of slot 2 could only desync the recording.
    var marks: [9]?u32 = @splat(null);
    marks[1] = 100;
    marks[2] = 500;
    marks[3] = 100; // exactly at the cut survives: the log still reaches it
    cutMarks(&marks, 100);
    try std.testing.expectEqual(@as(?u32, 100), marks[1]);
    try std.testing.expectEqual(@as(?u32, null), marks[2]);
    try std.testing.expectEqual(@as(?u32, 100), marks[3]);
}
