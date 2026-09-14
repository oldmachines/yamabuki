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
const takes = @import("takes.zig");

// app.zig is split into modules under app/; each is
// re-exported here so this file remains the root and every internal name
// keeps resolving. Pure code motion — see each module's header.
const video_gl_mod = @import("app/video_gl.zig");
const pacing_mod = @import("app/pacing.zig");
const take_mod = @import("app/take.zig");
const states_mod = @import("app/states.zig");
const shot_mod = @import("app/shot.zig");
const library_screen_mod = @import("app/library_screen.zig");

pub const drawGenFailScreen = library_screen_mod.drawGenFailScreen;
pub const drawGeneratingScreen = library_screen_mod.drawGeneratingScreen;
pub const drawLibraryScreen = library_screen_mod.drawLibraryScreen;
pub const drawOfferScreen = library_screen_mod.drawOfferScreen;
pub const drawPatchPromptScreen = library_screen_mod.drawPatchPromptScreen;
pub const drawPickerScreen = library_screen_mod.drawPickerScreen;
pub const finishGeneration = library_screen_mod.finishGeneration;
pub const genCandidate = library_screen_mod.genCandidate;
pub const gen_frames = library_screen_mod.gen_frames;
pub const gen_skip = library_screen_mod.gen_skip;
pub const refreshPatchTags = library_screen_mod.refreshPatchTags;
pub const runLibrary = library_screen_mod.runLibrary;
pub const startGeneration = library_screen_mod.startGeneration;
pub const frameNs = pacing_mod.frameNs;
pub const paceFrame = pacing_mod.paceFrame;
pub const nextNumberedPath = shot_mod.nextNumberedPath;
pub const wantsShot = shot_mod.wantsShot;
pub const writeScreenshot = shot_mod.writeScreenshot;
pub const loadStateFile = states_mod.loadStateFile;
pub const loadStateFrom = states_mod.loadStateFrom;
pub const refreshSlots = states_mod.refreshSlots;
pub const saveStateTo = states_mod.saveStateTo;
pub const EndMarks = take_mod.EndMarks;
pub const TakeForm = take_mod.TakeForm;
pub const cutMarks = take_mod.cutMarks;
pub const discardMovieModes = take_mod.discardMovieModes;
pub const end_state_header_len = take_mod.end_state_header_len;
pub const end_state_magic = take_mod.end_state_magic;
pub const end_state_version = take_mod.end_state_version;
pub const loadEndState = take_mod.loadEndState;
pub const readEndMarks = take_mod.readEndMarks;
pub const replayActive = take_mod.replayActive;
pub const rewindRecToSlot = take_mod.rewindRecToSlot;
pub const writeMovie = take_mod.writeMovie;
pub const GlVideo = video_gl_mod.GlVideo;
pub const Profile = video_gl_mod.Profile;
pub const buildChain = video_gl_mod.buildChain;
pub const cycleShader = video_gl_mod.cycleShader;
pub const destroyGlVideo = video_gl_mod.destroyGlVideo;
pub const indexOfName = video_gl_mod.indexOfName;
pub const initGl = video_gl_mod.initGl;
pub const listPresets = video_gl_mod.listPresets;
pub const profiles = video_gl_mod.profiles;
pub const rebuildChain = video_gl_mod.rebuildChain;

test {
    _ = video_gl_mod;
    _ = pacing_mod;
    _ = take_mod;
    _ = states_mod;
    _ = shot_mod;
    _ = library_screen_mod;
}

/// `--region ntsc|pal|auto`: override the header-detected region. `auto`
/// (the default) uses the cart header's region byte.
pub const RegionArg = enum { auto, ntsc, pal };

/// A transient on-screen message (slot changes, state saves/loads,
/// recording start/stop): one line at the picture's bottom-left for a
/// couple of seconds, drawn into the compose buffer so both render paths
/// show it and the shader shades it like game pixels.
/// Frames between the last shader change and the config write (1.5 s).
const config_persist_delay: u32 = 90;

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
    /// `--record`: begin a power-on take before the first frame runs.
    record: bool = false,
    /// `--srm`: battery save to start a `--record` take from (anchored).
    srm: ?[]const u8 = null,
    /// `--continue`: when the `--movie` replay ends in sync, keep recording
    /// from there with the replayed inputs already in the take.
    continue_take: bool = false,
    /// The `--movie` file's path: `--continue` looks beside it for the
    /// take's end state (`<take>.end.state`) to skip the replay.
    movie_path: ?[]const u8 = null,
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
        destroyGlVideo(gpa, g);
    };
    // Set by a window/device event or by a failed swap: the shader chain
    // is rebuilt on the next present (see `rebuildChain`).
    var gl_rebuild = false;

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
        // A window conversion has no battery in its header; its lifted save
        // region (saves.liftedSram) is the game's save chip and persists like
        // one — as its own .srm, 8 KiB for the games lifted so far.
        if (con.cartridge().hasBattery() or saves.liftedSram(con) != null) {
            // A --record session starts from the machine headless will replay
            // the take on, and headless loads no battery save: blank SRAM in,
            // and the take's in-game saves never reach the real .srm.
            if (opts.record or opts.continue_take) {
                if (opts.srm == null and !opts.continue_take) {
                    try err.print("movie: --record starts with blank battery SRAM (the .srm is left untouched)\n", .{});
                    try err.flush();
                }
            } else sram = saves.Sram.init(gpa, dir, opts.game_id) catch null;
            if (sram) |*s| s.load(io, con, err);
        }
    }

    // Rewind history. The one number the whole design leans on — the real
    // state size — is printed rather than assumed.
    var rw: ?rewind.Rewind = null;
    defer if (rw) |*r| r.deinit();
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
    // The takes screen (F11); see takes.zig.
    var takes_ui: ?takes.Picker = null;
    // The take on the machine right now — the `--movie` file, or the one the
    // takes screen loaded. Its end-state sidecar lives beside it.
    var cur_movie_path: ?[]const u8 = opts.movie_path;
    // A replay that hands over to recording when it ends: `--continue`, or
    // "from the beginning" on the takes screen.
    var continue_pending: bool = opts.continue_take;
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
    // F toggles fullscreen (borderless, desktop resolution). A fixed key like
    // the shader keys below: a display affordance, not a game input.
    var fullscreen = false;
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
    // Identity of the state file each mark describes: a slot can be
    // overwritten by another session, and a mark must never rewind to a
    // frame the file on disk no longer matches.
    var rec_mark_hash: [9]u64 = @splat(0);
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
    // Per-poll replay: frames still to run after the last entry was
    // consumed before the take's end (and its hashes) is reached.
    var play_tail: ?u32 = null;
    var movie_end_check = false;
    // The open take records one entry per controller poll (format 3) —
    // every new take does; a per-frame take continued from its end state
    // keeps its own form so the prefix stays consistent.
    var rec_per_poll: bool = false;
    // Frames run since the last recorded poll (format 3's tail).
    var rec_tail: u32 = 0;
    // Per slot: `rec_tail` when the state was saved, restored on rewind.
    var rec_mark_tail: [9]u32 = @splat(0);
    // The battery save the open take began from (written beside it as
    // `.start.srm`), when it began from one.
    var rec_start_srm: ?[]u8 = null;
    var next_deadline = sdl.SDL_GetTicksNS() + frame_ns;
    // Shader cycling writes the chosen preset to config.zon, but not on
    // every tap: tapping through twenty presets used to rewrite the file
    // twenty times. The write lands `config_persist_delay` frames after
    // the last change, or at exit.
    var config_persist_at: ?u32 = null;
    defer if (config_persist_at != null) persistConfig(io, gpa, &opts, err);

    // --record: open the take here, before any frame has run, so the movie
    // is a true power-on take with the boot frames in it. The F10 path can
    // only start when the hand gets there, and `at_power_on` cannot tell how
    // many frames slipped by first; a take that starts late but claims frame
    // 0 replays its inputs early and desyncs at the first branch.
    if (opts.record) {
        if (opts.movies_dir == null) {
            try err.print("movie: --record unavailable — no per-user data directory\n", .{});
            try err.flush();
        } else if (play_movie != null) {
            try err.print("movie: --record cannot combine with --movie playback\n", .{});
            try err.flush();
        } else {
            rec = .init(gpa);
            rec_per_poll = true;
            rec_tail = 0;
            if (opts.srm) |srm_path| {
                // Continue from a battery save. The machine has not run a
                // frame, but its SRAM is no longer blank, so the take must
                // carry the powered-on machine as its anchor — captured here,
                // before the first recorded frame, exactly like the F10 path.
                if (saves.loadSramFile(io, con, srm_path, err)) {
                    // A power-on take plus the save it began from (written
                    // beside it as `.start.srm`): no machine state to seed,
                    // so it replays on any build of the game — which an
                    // anchored take, tied to one build's layout, cannot.
                    if (gpa.dupe(u8, saves.liveSram(con))) |copy| {
                        rec_start_srm = copy;
                        try err.print("movie: recording from battery save {s} (power-on take with a start save; F10 stops and saves)\n", .{srm_path});
                        try err.flush();
                        toast.set("RECORDING FROM SAVE - F10 STOPS", .{});
                    } else |_| {
                        try err.print("movie: cannot keep a copy of the save; recording from blank SRAM instead\n", .{});
                        try err.flush();
                        @memset(saves.liveSram(con), 0);
                    }
                } else {
                    try err.print("movie: --srm not loaded; recording from blank SRAM instead\n", .{});
                    try err.flush();
                }
            }
            if (rec_start_srm == null) {
                try err.print("movie: recording from power-on (--record; F10 stops and saves)\n", .{});
                try err.flush();
                toast.set("RECORDING FROM POWER-ON - F10 STOPS", .{});
            }
        }
    }

    // --continue from the take's END STATE: every stop writes the machine at
    // the take's last frame beside the file. If that state still loads on
    // this build (same image, same core layout) and belongs to this exact
    // file, recording resumes from it at once and the replay is skipped —
    // the replay exists to rebuild that machine, and here it already exists.
    // Anything off (no sidecar, another build, a different file) falls back
    // to the replay, which decides by the take's own end hashes.
    if (opts.continue_take) if (play_movie) |m| if (opts.movie_path) |mp| {
        var em: EndMarks = .{};
        if (loadEndState(io, gpa, con, mp, m, &em, err)) |restored| {
            audio_hash = restored;
            play_idx = m.frames.len;
            var r: std.array_list.Managed([2]u16) = .init(gpa);
            if (r.appendSlice(m.frames)) {
                rec = r;
                rec_per_poll = m.per_poll;
                rec_tail = m.tail_frames;
                rec_start_srm = if (m.start_srm) |sb| (gpa.dupe(u8, sb) catch null) else null;
                rec_anchor = if (m.anchor) |a| (gpa.dupe(u8, a) catch null) else null;
                rec_marks = em.frames;
                rec_audio = em.audio;
                rec_mark_hash = em.hash;
                rec_mark_tail = em.tail;
                if (rw) |*w| w.clear();
                at_power_on = false;
                try err.print("movie: continuing the take from its end state, frame {} (no replay; F10 stops and saves the whole take)\n", .{m.frames.len});
                try err.flush();
                toast.set("CONTINUING TAKE - F10 STOPS", .{});
            } else |_| r.deinit();
        }
    };
    // --continue by replay (no usable end state): the take is re-recorded
    // per poll AS IT REPLAYS, so the file saved at F10 is the whole
    // playthrough in the cross-build form whatever form the source had.
    if (continue_pending and rec == null) if (play_movie) |m| {
        rec = .init(gpa);
        rec_per_poll = true;
        rec_tail = 0;
        rec_anchor = if (m.anchor) |a| (gpa.dupe(u8, a) catch null) else null;
        rec_start_srm = if (m.start_srm) |sb| (gpa.dupe(u8, sb) catch null) else null;
        rec_marks = @splat(null);
    };

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
                // Anything that can leave the GL context or the chain's
                // objects stale (a minimize/restore round trip, a display
                // change, a driver reset): rebuild the chain before the
                // next frame rather than draw with dead names — the
                // "picture goes blank after a long pause" failure.
                sdl3.event_window_restored,
                sdl3.event_window_display_changed,
                sdl3.event_render_targets_reset,
                sdl3.event_render_device_reset,
                sdl3.event_render_device_lost,
                => {
                    gl_rebuild = true;
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

            if (takes_ui) |*tp| {
                repeater.feed(nev);
                const req: takes.Request = if (menu.navFromEvent(nev)) |nav| tp.handleNav(nav) else .none;
                switch (req) {
                    .none => {},
                    .close => {
                        tp.deinit();
                        takes_ui = null;
                        inp.clearTransient();
                    },
                    .start_end_state, .start_replay => |how| {
                        const chosen: ?[]u8 = if (tp.selected()) |sel| (gpa.dupe(u8, sel.path) catch null) else null;
                        tp.deinit();
                        takes_ui = null;
                        inp.clearTransient();
                        if (chosen) |p| {
                            // Load and validate the take against this session,
                            // exactly as --movie does at boot.
                            const bytes = std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(64 * 1024 * 1024)) catch null;
                            var parsed: ?util.movie.Movie = if (bytes) |b| (util.movie.parse(gpa, b) catch null) else null;
                            if (parsed) |*pm| pm.start_srm = util.movie.loadStartSrm(io, gpa, p);
                            if (parsed) |m| {
                                const acc: u8 = if (opts.accuracy == .accurate) 1 else 0;
                                const reg: u8 = if (con.region() == .pal) 1 else 0;
                                // Another build of the game is fine for a per-poll
                                // take that starts at power-on: nothing but inputs
                                // indexed by the game's own pad reads.
                                const cross_build = m.rom_crc != opts.rom_crc;
                                if ((cross_build and !(m.per_poll and m.anchor == null)) or m.accuracy != acc or m.region != reg) {
                                    toast.set("TAKE IS FROM ANOTHER IMAGE OR CORE", .{});
                                } else if (cross_build and how == .start_end_state) {
                                    toast.set("ANOTHER BUILD - REPLAY FROM THE BEGINNING", .{});
                                } else {
                                    // The take's machine replaces whatever ran here:
                                    // drop an open take, stop persisting the real
                                    // battery save (the take carries its own), and
                                    // forget the rewind history.
                                    discardMovieModes(gpa, &rec, &rec_anchor, &play_movie, "take picker", err);
                                    if (sram) |*s| s.flush(io, con, err);
                                    sram = null;
                                    if (rw) |*w| w.clear();
                                    cur_movie_path = p;
                                    play_movie = m;
                                    movie_end_check = false;
                                    play_tail = null;
                                    var from_end = false;
                                    var em: EndMarks = .{};
                                    if (how == .start_end_state) {
                                        if (loadEndState(io, gpa, con, p, m, &em, err)) |restored| {
                                            audio_hash = restored;
                                            play_idx = m.frames.len;
                                            from_end = true;
                                        } else toast.set("NO END STATE - REPLAYING INSTEAD", .{});
                                    }
                                    if (from_end) {
                                        var r: std.array_list.Managed([2]u16) = .init(gpa);
                                        if (r.appendSlice(m.frames)) {
                                            rec = r;
                                            rec_per_poll = m.per_poll;
                                            rec_tail = m.tail_frames;
                                            rec_start_srm = if (m.start_srm) |sb| (gpa.dupe(u8, sb) catch null) else null;
                                            rec_anchor = if (m.anchor) |a| (gpa.dupe(u8, a) catch null) else null;
                                            rec_marks = em.frames;
                                            rec_audio = em.audio;
                                            rec_mark_hash = em.hash;
                                            rec_mark_tail = em.tail;
                                            at_power_on = false;
                                            try err.print("movie: continuing take {s} from its end state, frame {d}\n", .{ p, m.frames.len });
                                            try err.flush();
                                            toast.set("CONTINUING TAKE - F10 STOPS", .{});
                                        } else |_| r.deinit();
                                    } else {
                                        // From the beginning: the machine the take
                                        // started on, then the replay at full speed;
                                        // the hand-over at its end is the same as
                                        // --continue's.
                                        var ok = true;
                                        if (m.anchor) |a| {
                                            con.loadState(a) catch {
                                                toast.set("TAKE START STATE WON'T LOAD HERE", .{});
                                                play_movie = null;
                                                ok = false;
                                            };
                                        } else {
                                            con.repower();
                                            switch (opts.region) {
                                                .auto => {},
                                                .ntsc => con.setRegion(.ntsc),
                                                .pal => con.setRegion(.pal),
                                            }
                                            if (m.start_srm) |sb| {
                                                if (!saves.loadSramBytes(con, sb)) {
                                                    toast.set("TAKE START SAVE WON'T FIT HERE", .{});
                                                    play_movie = null;
                                                    ok = false;
                                                }
                                            } else @memset(saves.liveSram(con), 0);
                                        }
                                        if (ok) {
                                            play_idx = 0;
                                            audio_hash = core.console.audio_hash_init;
                                            continue_pending = true;
                                            // Re-recorded per poll as it replays (see
                                            // the --continue path above the loop).
                                            rec = .init(gpa);
                                            rec_per_poll = true;
                                            rec_tail = 0;
                                            rec_anchor = if (m.anchor) |a| (gpa.dupe(u8, a) catch null) else null;
                                            rec_start_srm = if (m.start_srm) |sb| (gpa.dupe(u8, sb) catch null) else null;
                                            rec_marks = @splat(null);
                                            if (cross_build) {
                                                try err.print("movie: take {s} is from another build; its per-poll inputs replay here, the picture may differ\n", .{p});
                                                try err.flush();
                                            }
                                            at_power_on = m.anchor == null;
                                            try err.print("movie: replaying take {s} ({d} frames) to continue it\n", .{ p, m.frames.len });
                                            try err.flush();
                                            toast.set("REPLAYING TAKE - HANDS OFF", .{});
                                        }
                                    }
                                }
                            } else toast.set("CANNOT READ THAT TAKE", .{});
                        }
                    },
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
                            rec_mark_hash[slot] = std.hash.Fnv1a_64.hash(state_buf);
                            rec_mark_tail[slot] = rec_tail;
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
                            if (rec_marks[slot] != null and rec_mark_hash[slot] != std.hash.Fnv1a_64.hash(state_buf)) rec_marks[slot] = null;
                            if (rewindRecToSlot(gpa, &rec, &rec_anchor, &play_movie, &rec_marks, &rec_audio, &audio_hash, &rec_tail, &rec_mark_tail, slot, err)) |f|
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
                        config_persist_at = frames_run + config_persist_delay;
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
                } else if (nev.key.scancode == sdl3.scancode.f11) {
                    if (takes_ui == null) {
                        if (opts.movies_dir) |md| {
                            takes_ui = takes.Picker.init(gpa, io, md, opts.game_id);
                            inp.clearTransient();
                        } else toast.set("NO TAKES FOLDER", .{});
                    }
                    // Consumed: the key must not also reach the bindings
                    // (it used to toggle the cheat switch on the way past).
                    continue;
                } else if (false) {
                    // (the direct end-state load F11 used to do; the takes screen's
                    // END STATE option on the current take is the same action) — the machine the
                    // --movie file ends on. In a continued session this rewinds
                    // the recording to the continue point (everything after it
                    // is dropped, deterministically, like a slot rewind); during
                    // a replay it skips straight to the end.
                    if (play_movie) |m| {
                        if (cur_movie_path) |mp| {
                            var em_old: EndMarks = .{};
                            if (loadEndState(io, gpa, con, mp, m, &em_old, err)) |restored| {
                                audio_hash = restored;
                                play_idx = m.frames.len;
                                movie_end_check = false;
                                if (rw) |*w| w.clear();
                                at_power_on = false;
                                if (rec) |*r| {
                                    if (r.items.len >= m.frames.len) {
                                        r.shrinkRetainingCapacity(m.frames.len);
                                        cutMarks(&rec_marks, @intCast(m.frames.len));
                                        toast.set("TAKE END STATE - REC REWOUND TO {d}", .{m.frames.len});
                                    } else toast.set("TAKE END STATE LOADED", .{});
                                } else toast.set("TAKE END STATE LOADED", .{});
                                try err.print("movie: take end state loaded (frame {d})\n", .{m.frames.len});
                                try err.flush();
                            } else toast.set("NO END STATE FOR THIS TAKE", .{});
                        } else toast.set("NO END STATE FOR THIS TAKE", .{});
                    } else toast.set("NO TAKE LOADED", .{});
                } else if (nev.key.scancode == sdl3.scancode.f) {
                    fullscreen = !fullscreen;
                    if (sdl.SDL_SetWindowFullscreen(window, fullscreen)) {
                        if (fullscreen) toast.set("FULLSCREEN - F TO LEAVE", .{}) else toast.set("WINDOWED", .{});
                    } else {
                        fullscreen = !fullscreen;
                        toast.set("FULLSCREEN FAILED", .{});
                    }
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
                        rec_mark_hash[slot] = std.hash.Fnv1a_64.hash(state_buf);
                        rec_mark_tail[slot] = rec_tail;
                    }
                    toast.set("STATE SAVED - SLOT {d}", .{slot});
                },
                .load_state => {
                    if (loadStateFrom(io, con, slot_paths[slot] orelse legacy_state_path, slot, state_buf, err)) {
                        if (sram) |*s| s.flush(io, con, err);
                        if (rw) |*r| r.clear();
                        at_power_on = false;
                        if (rec_marks[slot] != null and rec_mark_hash[slot] != std.hash.Fnv1a_64.hash(state_buf)) rec_marks[slot] = null;
                        if (rewindRecToSlot(gpa, &rec, &rec_anchor, &play_movie, &rec_marks, &rec_audio, &audio_hash, &rec_tail, &rec_mark_tail, slot, err)) |f|
                            toast.set("STATE LOADED - REC REWOUND TO {d}", .{f})
                        else
                            toast.set("STATE LOADED - SLOT {d}", .{slot});
                    } else toast.set("NO STATE IN SLOT {d}", .{slot});
                },
                .record_movie => {
                    if (replayActive(play_movie, play_idx, play_tail)) {
                        try err.print("movie: cannot record during playback\n", .{});
                        try err.flush();
                        toast.set("CANNOT RECORD DURING PLAYBACK", .{});
                    } else if (rec != null) {
                        // Stop: the movie's hashes describe the machine as it
                        // stands right now, after the last recorded frame.
                        writeMovie(io, gpa, &opts, con, rec.?.items, rec_anchor, audio_hash, .{ .frames = rec_marks, .audio = rec_audio, .hash = rec_mark_hash, .tail = rec_mark_tail }, .{ .per_poll = rec_per_poll, .tail_frames = rec_tail, .start_srm = rec_start_srm }, err);
                        rec.?.deinit();
                        rec = null;
                        if (rec_anchor) |a| gpa.free(a);
                        rec_anchor = null;
                        if (rec_start_srm) |sb| gpa.free(sb);
                        rec_start_srm = null;
                        rec_marks = @splat(null);
                        toast.set("RECORDING SAVED", .{});
                    } else if (opts.movies_dir == null) {
                        try err.print("movie: recording unavailable — no per-user data directory\n", .{});
                        try err.flush();
                    } else if (at_power_on) {
                        // Nothing has run yet, so the inputs alone reconstruct
                        // the session: no anchor, and the file stays version 1.
                        if (rw) |*r| r.clear();
                        audio_hash = core.console.audio_hash_init;
                        rec = .init(gpa);
                        rec_per_poll = true;
                        rec_tail = 0;
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
                            rec_per_poll = true;
                            rec_tail = 0;
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
        if (takes_ui) |*tp| if (repeater.tick()) |nav| {
            _ = tp.handleNav(nav);
        };
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
        const halted = paused or mnu != null or rewinding or takes_ui != null;
        const replaying = replayActive(play_movie, play_idx, play_tail);
        fast_forward = (inp.ffHeld() or (continue_pending and replaying)) and !halted;
        // During playback the movie owns both pads; live input resumes the
        // frame after it ends. A per-poll take holds its current entry
        // until the game reads the pad (the cursor moves below, after the
        // frame), and reads idle through its tail.
        const feed: [2]u16 = if (play_movie) |m|
            (if (play_idx < m.frames.len) m.frames[play_idx] else if (play_tail != null) .{ 0, 0 } else .{ inp.masks[0], inp.masks[1] })
        else
            .{ inp.masks[0], inp.masks[1] };
        con.setButtons(0, feed[0]);
        con.setButtons(1, feed[1]);
        // The poll latch answers for THIS frame only.
        _ = con.takeInputPolled();
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
            const polled = con.inputPolled();
            if (rec) |*r| {
                if (!rec_per_poll) {
                    r.append(feed) catch {};
                } else if (polled) {
                    r.append(feed) catch {};
                    rec_tail = 0;
                } else rec_tail += 1;
            }
            if (play_movie) |m| {
                if (!m.per_poll) {
                    if (play_idx < m.frames.len) {
                        play_idx += 1;
                        // The frame the movie ends on is the one its hashes
                        // describe — checked below, after its audio drains.
                        if (play_idx == m.frames.len) movie_end_check = true;
                    }
                } else {
                    // The entry is consumed by the poll; the take ends its
                    // tail after the frame that consumed the last one.
                    if (play_idx < m.frames.len and polled) {
                        play_idx += 1;
                        if (play_idx == m.frames.len) play_tail = m.tail_frames;
                    }
                    if (play_idx == m.frames.len) if (play_tail) |t| {
                        if (t == 0) {
                            movie_end_check = true;
                            play_tail = null;
                        } else play_tail = t - 1;
                    };
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
        const src_px: []const u16 = if (takes_ui) |*tp| blk: {
            @memcpy(compose[0..fb.len], fb);
            const surf = ui.Surface.init(compose[0..fb.len], width, height);
            ui.dimAll(&surf);
            tp.draw(&surf);
            break :blk compose[0..fb.len];
        } else if (mnu) |*m| blk: {
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
        } else if (rec != null or replayActive(play_movie, play_idx, play_tail) or paused) blk: {
            // Status marks live in the top-right corner: the take indicator
            // ("* REC" / "> MOVIE") flush right, and the classic two-bar pause
            // icon just left of it (or in the corner itself when nothing is
            // being recorded or replayed).
            @memcpy(compose[0..fb.len], fb);
            const surf = ui.Surface.init(compose[0..fb.len], width, height);
            const right: i32 = @as(i32, @intCast(width)) - 4;
            var x_edge: i32 = right;
            if (rec != null or replayActive(play_movie, play_idx, play_tail)) {
                const label: []const u8 = if (rec != null and !replayActive(play_movie, play_idx, play_tail)) "* REC" else "> MOVIE";
                const tx = right - @as(i32, @intCast(ui.textWidth(label)));
                ui.drawText(&surf, tx, 4, label, ui.color.accent);
                x_edge = tx - 8;
            }
            if (paused) {
                const bar_w: u32 = 4;
                const bar_h: u32 = 12;
                const gap: i32 = 3;
                const x2 = x_edge - @as(i32, @intCast(bar_w));
                const x1 = x2 - gap - @as(i32, @intCast(bar_w));
                ui.fillRect(&surf, x1 - 2, 2, 2 * bar_w + @as(u32, @intCast(gap)) + 4, bar_h + 4, ui.color.panel);
                ui.fillRect(&surf, x1, 4, bar_w, bar_h, ui.color.accent);
                ui.fillRect(&surf, x2, 4, bar_w, bar_h, ui.color.accent);
            }
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
            if (gl_rebuild) {
                gl_rebuild = false;
                rebuildChain(io, gpa, g, window, err) catch |e| {
                    // Same fallback as a failed render below: the picture
                    // moves to the software blit, the game keeps running.
                    try err.print("shader chain could not be rebuilt ({s}); falling back to the software renderer\n", .{@errorName(e)});
                    try err.flush();
                    if (g.osd) |*o| o.deinit();
                    g.chain().deinit();
                    _ = g.sdl_gl.SDL_GL_DestroyContext(g.ctx);
                    destroyGlVideo(gpa, g);
                    glv = null;
                    renderer = sdl.SDL_CreateRenderer(window, null) orelse {
                        try err.print("error: SDL_CreateRenderer after shader failure: {s}\n", .{sdl.SDL_GetError()});
                        try err.flush();
                        std.process.exit(1);
                    };
                    _ = sdl.SDL_SetRenderVSync(renderer.?, 0);
                    break :gl_path;
                };
            }
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
                destroyGlVideo(gpa, g);
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
            // A failed swap, or a context-loss error left on the queue, is
            // the cheapest signal that every object the chain holds is
            // dead. Rebuild next frame instead of drawing black forever.
            if (!g.sdl_gl.SDL_GL_SwapWindow(window)) gl_rebuild = true;
            switch (g.api.glGetError()) {
                gl.NO_ERROR => {},
                gl.CONTEXT_LOST, gl.INVALID_FRAMEBUFFER_OPERATION, gl.OUT_OF_MEMORY => gl_rebuild = true,
                else => {},
            }
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
                // A per-poll take from another build lands its inputs on the
                // same polls but draws a different picture: its end hashes
                // cannot match and do not judge it.
                const cross_build = m.rom_crc != opts.rom_crc;
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
                        if (cross_build) {
                            try err.print("movie: (another build — the differing picture is expected; the inputs landed on the same polls)\n", .{});
                        } else if (continue_pending) {
                            try err.print("movie: --continue refused — the replay did not reproduce the take, so inputs appended now would describe a different machine\n", .{});
                            toast.set("CONTINUE REFUSED - DESYNC", .{});
                        }
                    }
                }
                try err.flush();
                // --continue: the machine is exactly where the take left it, so
                // recording resumes with the replayed inputs already in the take
                // and the same start (anchor or power-on). The file written at
                // F10 is the whole playthrough, and its hashes describe the end.
                const in_sync = cross_build or m.end_frame_hash == 0 or
                    (core.console.hashFrame(con.framebuffer()) == m.end_frame_hash and (m.end_audio_hash == 0 or audio_hash == m.end_audio_hash));
                // The continuation's take has been open since the replay's
                // first frame, re-recording the inputs per poll; it simply
                // keeps going — or is dropped when the replay did not
                // reproduce the take.
                if (continue_pending and rec != null) {
                    if (in_sync) {
                        if (rw) |*w| w.clear();
                        try err.print("movie: continuing the take — re-recorded per poll, {} entries so far (F10 stops and saves the whole take)\n", .{rec.?.items.len});
                        try err.flush();
                        toast.set("CONTINUING TAKE - F10 STOPS", .{});
                    } else {
                        rec.?.deinit();
                        rec = null;
                        if (rec_anchor) |a| gpa.free(a);
                        rec_anchor = null;
                        if (rec_start_srm) |sb| gpa.free(sb);
                        rec_start_srm = null;
                    }
                    continue_pending = false;
                }
            }
        }

        if (config_persist_at) |at| if (frames_run >= at) {
            persistConfig(io, gpa, &opts, err);
            config_persist_at = null;
        };
        if (opts.frames != 0 and frames_run >= opts.frames) running = false;

        // Pacing: sleep up to the next NTSC frame boundary.
        if (fast_forward or opts.frames != 0) {
            next_deadline = sdl.SDL_GetTicksNS() + frame_ns;
        } else {
            next_deadline = paceFrame(sdl.SDL_GetTicksNS(), next_deadline, frame_ns, max_lag_ns, &sdl);
        }
    }

    // A take still open when the window closes is saved, not dropped: with
    // --record the take IS the point of the session, and F10 is easy to
    // miss. Its hashes describe the machine as it stands now, which is
    // exactly what a stop would have recorded.
    if (rec) |*r| {
        writeMovie(io, gpa, &opts, con, r.items, rec_anchor, audio_hash, .{ .frames = rec_marks, .audio = rec_audio, .hash = rec_mark_hash, .tail = rec_mark_tail }, .{ .per_poll = rec_per_poll, .tail_frames = rec_tail, .start_srm = rec_start_srm }, err);
        r.deinit();
        rec = null;
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

pub const InitGlError = error{ NoGlSymbols, NoContext, NoVariantForThisGpu, ShaderDirNotFound, ShaderNotBaked };

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
