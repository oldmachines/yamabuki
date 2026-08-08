//! SDL3 desktop frontend: the development-and-play UI.
//!
//!   yamabuki-sdl <rom.sfc> [--scale N] [--frames N] [--no-audio] [--accurate] [--wide N]
//!
//! Controls — all remappable via the config's `input` section (see
//! `input.zig` for the token grammar); the defaults are:
//!   arrows = d-pad   Z = B   X = A   A = Y   S = X   Q = L   W = R
//!   Enter = Start    RShift = Select
//!   gamepads: positional SNES map (south=B east=A west=Y north=X), d-pad +
//!   left stick, both players, hotplugged in connection order
//! Hotkeys (also remappable):
//!   F5 save state (<rom>.state)   F9 load state   F1 reset   P pause
//!   Tab or right trigger (hold) fast-forward      Esc quit
//!   , / .  cycle shaders (fixed keys; only presets baked for this GPU)
//!
//! Settings persist in `config.zon` under the OS's per-user data directory
//! (`SDL_GetPrefPath`: `%APPDATA%\yamabuki\yamabuki\` on Windows,
//! `~/.local/share/yamabuki/yamabuki/` on Linux). Precedence is defaults ←
//! config ← CLI, so every dev flag still wins for its run; `--frames N` runs
//! skip the config entirely so CI hashes never depend on local settings.
//!
//! This file owns the CLI and building the console; the SDL session itself —
//! window, video, audio, input, pacing, the frame loop — lives in `app.zig`.
//! Video is the console's native RGB565 framebuffer streamed into a texture
//! (recreated when the machine switches to hi-res/overscan/`--wide`
//! dimensions) and letterboxed onto a (2*width)x(2*height) logical canvas.
//! Audio goes to an SDL audio stream at the DSP's native 32 kHz. Pacing is a
//! nanosecond accumulator locked to the loaded cart's region frame rate
//! (~60.0988 Hz NTSC, 50 Hz PAL — `--region` overrides the header's
//! auto-detected default) rather than display vsync. `--frames N` runs
//! unattended and prints the same video/audio hashes as the headless runner,
//! which is how CI smoke-tests this frontend under SDL's dummy drivers.

const std = @import("std");
const core = @import("snes_core");
const sdl3 = @import("sdl3.zig");
const util = @import("util");
const app = @import("app.zig");
const config = @import("config.zig");
const input = @import("input.zig");
const paths = @import("paths.zig");
const saves = @import("saves.zig");
const patchfind = @import("patchfind.zig");
const library = @import("library.zig");

const Args = struct {
    /// Null = no ROM argument: launch into the library picker.
    rom: ?[]const u8 = null,
    /// Null means "not given on the CLI" — the config's video.scale (default
    /// 3) applies. Same 1..8 validation either way.
    scale: ?u32 = null,
    frames: u32 = 0, // 0 = run until quit
    audio: bool = true,
    accuracy: core.Accuracy = .fast,
    region: app.RegionArg = .auto,
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
    /// `--auto-fastrom`: pin MEMSEL to 1 (FastROM cartridge timing for a
    /// SlowROM game), gated by patches/fastrom-compat.zon — `broken` refuses,
    /// unknown warns loudly.
    auto_fastrom: bool = false,
    /// `--wide N` (M12): extra columns rendered on each side of the standard
    /// 256, for a widescreen game patch (e.g. wide-snes) that draws into the
    /// margin. Fast core only — refused together with `--accurate`.
    wide: u32 = 0,
    /// `--movie <file>`: replay a recorded playthrough (.ymv) from power-on;
    /// live input takes over when it ends. Needs an explicit ROM argument.
    movie: ?[]const u8 = null,
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

    const args = parseArgs(init, gpa) catch |e| {
        if (e == error.ShotNeedsFrames) {
            try err.print("error: --shot without --shot-frames captures the last frame, which needs --frames N\n", .{});
        } else if (e == error.NeedsRom) {
            try err.print("error: --frames/--shot/--patch/--auto-fastrom/--movie need an explicit ROM argument\n", .{});
        } else if (e == error.WideNeedsFast) {
            try err.print("error: --wide needs the fast core (--accurate's dot renderer doesn't support it)\n", .{});
        } else if (e == error.WideTooBig) {
            try err.print("error: --wide margin exceeds {d}\n", .{core.ppu.wide_margin_max});
        }
        try err.print(
            "usage: yamabuki-sdl [rom.sfc] [--scale N] [--frames N] [--no-audio] [--accurate]\n" ++
                "  (no ROM argument opens the library: config.zon's library.rom_dirs, scanned)\n" ++
                "                    [--region ntsc|pal|auto] [--shader NAME] [--shader-dir DIR]\n" ++
                "                    [--patch p.bps|p.ips] [--auto-fastrom] [--wide N]\n" ++
                "                    [--movie f.ymv] [--shot PREFIX [--shot-frames a,b,c]]\n" ++
                "  --region r  ntsc|pal|auto (default auto: detect from the cart header)\n" ++
                "  --wide N    widen the framebuffer by N columns on each side, e.g. 32 -> 320x224\n" ++
                "              (fast core only; for widescreen game patches such as wide-snes)\n" ++
                "  --movie f   replay a recorded playthrough (.ymv) from power-on; live input\n" ++
                "              takes over when it ends (record in-game with the F10 hotkey)\n" ++
                "  --shot writes PREFIX-<frame>.ppm at each frame in --shot-frames,\n" ++
                "  or at the final frame when --shot-frames is omitted.\n",
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

    // --- config -------------------------------------------------------------
    // Interactive runs only: an unattended `--frames N` run is CI's smoke
    // mode, and its golden hashes must not depend on this machine's settings.
    var cfg: config.Config = .{};
    var config_path: ?[]const u8 = null;
    var user_paths: ?paths.Paths = null;
    if (args.frames == 0) {
        user_paths = paths.Paths.init(gpa);
        if (user_paths) |p| {
            config_path = p.config;
            switch (config.load(io, gpa, p.config)) {
                .loaded => |c| cfg = c,
                // First run: write the defaults — seeded with a shader, so
                // the file exists to be discovered and edited, and the
                // in-game menu/`,`/`.` shortcuts work immediately rather
                // than silently sitting on the software blit.
                .missing => {
                    cfg.video.shader = config.Config.default_shader;
                    config.save(io, gpa, cfg, p.config) catch |e| {
                        try err.print("warning: cannot write {s}: {s}\n", .{ p.config, @errorName(e) });
                        try err.flush();
                    };
                },
                .invalid => {
                    try err.print("warning: {s} is not valid ZON — using defaults (file left untouched)\n", .{p.config});
                    try err.flush();
                },
            }
        } else {
            try err.print("warning: no per-user data directory — settings will not persist\n", .{});
            try err.flush();
        }
    }

    // --- sessions -----------------------------------------------------------
    const bindings = input.resolve(&cfg.input, err);
    if (args.rom) |rom_path| {
        // Classic direct launch: boot failures are fatal, CLOSE GAME quits.
        const b = bootConsole(io, gpa, rom_path, args, &cfg, if (user_paths) |p| p.patches else null, err) catch std.process.exit(1);
        const mov: ?util.movie.Movie = if (args.movie) |mp|
            loadMovieFor(io, gpa, mp, b, err) catch std.process.exit(1)
        else
            null;
        _ = try app.run(io, gpa, sdl, b.con, makeOptions(rom_path, b, args, &cfg, config_path, user_paths, bindings, mov, err), err, out);
        return;
    }

    // Library mode: browse → play → back to browsing, until the picker or
    // the in-game menu quits. A broken pick prints its reason and returns
    // to the list rather than killing the app.
    var lib = if (user_paths) |p|
        library.Library.loadCache(io, gpa, p.library)
    else
        library.Library{ .gpa = gpa };
    while (true) {
        const picked = try app.runLibrary(
            io,
            gpa,
            sdl,
            args.scale orelse cfg.effectiveScale(err),
            &lib,
            &cfg,
            config_path,
            if (user_paths) |p| p.library else null,
            if (user_paths) |p| p.patches else null,
            err,
        ) orelse break;
        const b = bootConsole(io, gpa, picked, args, &cfg, if (user_paths) |p| p.patches else null, err) catch continue;
        const result = try app.run(io, gpa, sdl, b.con, makeOptions(picked, b, args, &cfg, config_path, user_paths, bindings, null, err), err, out);
        lib.touch(picked, result.frames / 60);
        if (user_paths) |p| lib.saveCache(io, gpa, p.library) catch {};
        if (result.reason == .quit) break;
    }
}

fn makeOptions(
    rom_path: []const u8,
    booted: Booted,
    args: Args,
    cfg: *config.Config,
    config_path: ?[]const u8,
    user_paths: ?paths.Paths,
    bindings: input.Resolved,
    mov: ?util.movie.Movie,
    err: *std.Io.Writer,
) app.Options {
    // Defaults ← config ← per-game ← CLI, resolved here once; app.zig never
    // sees where a setting came from. `booted` carries the per-game merges
    // that had to happen at console-build time (region/accuracy/wide) plus
    // the session-level ones (shader, rewind).
    return .{
        .rom = rom_path,
        .scale = args.scale orelse cfg.effectiveScale(err),
        .frames = args.frames,
        .audio = args.audio and cfg.audio.enabled,
        .region = booted.region,
        .shader = args.shader orelse booted.shader orelse cfg.video.shader,
        .shader_dir = args.shader_dir,
        .shot = args.shot,
        .shot_frames = args.shot_frames,
        .wide = booted.wide,
        .bindings = bindings,
        .cfg = cfg,
        .config_path = config_path,
        .game_id = booted.game_id,
        .saves_dir = if (user_paths) |p| p.saves else null,
        .states_dir = if (user_paths) |p| p.states else null,
        .shots_dir = if (user_paths) |p| p.screenshots else null,
        .rewind_enabled = args.frames == 0 and (booted.rewind orelse cfg.rewind.enabled),
        .rewind_budget_mib = cfg.effectiveRewindBudgetMib(),
        .movies_dir = if (user_paths) |p| p.movies else null,
        .rom_crc = booted.rom_crc,
        .accuracy = booted.accuracy,
        .movie = mov,
    };
}

/// Load and validate a `--movie` against the console it will drive: the
/// image CRC (as played, post soft-patch), the core accuracy, and the
/// region the console actually resolved to. Any mismatch is fatal — a
/// replay that cannot reproduce must not silently run.
fn loadMovieFor(io: std.Io, gpa: std.mem.Allocator, path: []const u8, b: Booted, err: *std.Io.Writer) !util.movie.Movie {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024)) catch {
        try err.print("error: cannot read movie '{s}'\n", .{path});
        try err.flush();
        return error.BootFailed;
    };
    const m = util.movie.parse(gpa, bytes) catch |e| {
        try err.print("error: '{s}' is not a valid movie: {s}\n", .{ path, @errorName(e) });
        try err.flush();
        return error.BootFailed;
    };
    if (m.rom_crc != b.rom_crc) {
        try err.print(
            "error: movie '{s}' was recorded on image crc32 {x:0>8}; this session plays {x:0>8}\n" ++
                "       (the movie identifies the image as played — a soft-patched game needs the same patch choice)\n",
            .{ path, m.rom_crc, b.rom_crc },
        );
        try err.flush();
        return error.BootFailed;
    }
    if ((m.accuracy == 1) != (b.accuracy == .accurate)) {
        try err.print("error: movie '{s}' was recorded on the {s} core; this session uses the other\n", .{
            path, if (m.accuracy == 1) "accurate" else "fast",
        });
        try err.flush();
        return error.BootFailed;
    }
    if ((m.region == 1) != (b.con.region() == .pal)) {
        try err.print("error: movie '{s}' was recorded in {s}; this session resolved the other region\n", .{
            path, if (m.region == 1) "PAL" else "NTSC",
        });
        try err.flush();
        return error.BootFailed;
    }
    try err.print("movie: {s} — {} frames, replaying from power-on\n", .{ path, m.frames.len });
    try err.flush();
    return m;
}

const MergedBoot = struct { accuracy: core.Accuracy, region: app.RegionArg, wide: u32 };

/// The console-build precedence: an explicit CLI flag wins its field, a
/// per-game override beats the global default. Pure, so the whole matrix
/// is unit-tested.
fn mergeBootSettings(args: Args, pg: ?*const config.Config.PerGame) error{ WideNeedsFast, WideTooBig }!MergedBoot {
    const accuracy: core.Accuracy = blk: {
        if (args.accuracy == .accurate) break :blk .accurate;
        if (pg) |p| if (p.accuracy) |a| break :blk switch (a) {
            .fast => .fast,
            .accurate => .accurate,
        };
        break :blk .fast;
    };
    const wide: u32 = if (args.wide != 0) args.wide else if (pg) |p| p.wide orelse 0 else 0;
    if (wide != 0) {
        if (accuracy == .accurate) return error.WideNeedsFast;
        if (wide > core.ppu.wide_margin_max) return error.WideTooBig;
    }
    const region: app.RegionArg = blk: {
        if (args.region != .auto) break :blk args.region;
        if (pg) |p| if (p.region) |r| break :blk switch (r) {
            .ntsc => .ntsc,
            .pal => .pal,
        };
        break :blk .auto;
    };
    return .{ .accuracy = accuracy, .region = region, .wide = wide };
}

test "boot-settings merge: CLI beats per-game beats default, conflicts refused" {
    const pg: config.Config.PerGame = .{
        .game_id = "x",
        .region = .pal,
        .accuracy = .accurate,
        .wide = 16,
    };

    // Defaults alone.
    const plain = try mergeBootSettings(.{}, null);
    try std.testing.expectEqual(core.Accuracy.fast, plain.accuracy);
    try std.testing.expectEqual(app.RegionArg.auto, plain.region);
    try std.testing.expectEqual(@as(u32, 0), plain.wide);

    // Per-game wins over defaults — but its accurate+wide combination is
    // the same conflict the flags would be.
    try std.testing.expectError(error.WideNeedsFast, mergeBootSettings(.{}, &pg));
    var pg_fast = pg;
    pg_fast.accuracy = .fast;
    const merged = try mergeBootSettings(.{}, &pg_fast);
    try std.testing.expectEqual(app.RegionArg.pal, merged.region);
    try std.testing.expectEqual(@as(u32, 16), merged.wide);

    // CLI wins over per-game.
    const cli = try mergeBootSettings(.{ .region = .ntsc, .wide = 32 }, &pg_fast);
    try std.testing.expectEqual(app.RegionArg.ntsc, cli.region);
    try std.testing.expectEqual(@as(u32, 32), cli.wide);

    // An absurd hand-edited margin is refused.
    var pg_huge = pg_fast;
    pg_huge.wide = 9999;
    try std.testing.expectError(error.WideTooBig, mergeBootSettings(.{}, &pg_huge));
}

const Booted = struct {
    con: *core.AnyConsole,
    game_id: []const u8,
    /// Merged (CLI ← per-game ← default) session settings the console was
    /// built with, echoed so `makeOptions` and F1's region reapply agree.
    region: app.RegionArg,
    wide: u32,
    /// Per-game values for settings the session applies itself; null
    /// inherits the global config.
    shader: ?[]const u8,
    rewind: ?bool,
    /// CRC32 of the copier-stripped image as booted (post soft-patch) —
    /// what recorded movies identify themselves by.
    rom_crc: u32,
    /// The core the console was built on (movies replay only on their own).
    accuracy: core.Accuracy,
};

/// ROM file → running console: read, soft-patch, auto-FastROM gate, cart
/// load, per-game merge, region/wide setup, save-file identity. Every
/// failure prints its reason and returns an error — the direct-launch path
/// exits on it, the library path goes back to the list.
/// Read and apply one patch file to `image`, with the same refusals and
/// warnings whichever way the patch was chosen (a `--patch` flag or launch
/// discovery).
fn applySoftPatch(io: std.Io, gpa: std.mem.Allocator, image: []const u8, patch_path: []const u8, err: *std.Io.Writer) ![]u8 {
    const pbytes = std.Io.Dir.cwd().readFileAlloc(io, patch_path, gpa, .limited(16 * 1024 * 1024)) catch {
        try err.print("error: cannot read patch '{s}'\n", .{patch_path});
        try err.flush();
        return error.BootFailed;
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
        return error.BootFailed;
    };
    if (!res.verified) {
        try err.print("warning: '{s}' is an IPS patch — no checksums, the result is unverified\n", .{patch_path});
        try err.flush();
    }
    return res.image;
}

fn bootConsole(io: std.Io, gpa: std.mem.Allocator, rom_path: []const u8, args: Args, cfg: *const config.Config, patches_dir: ?[]const u8, err: *std.Io.Writer) !Booted {
    var image = std.Io.Dir.cwd().readFileAlloc(io, rom_path, gpa, .limited(16 * 1024 * 1024)) catch {
        try err.print("error: cannot read ROM '{s}'\n", .{rom_path});
        try err.flush();
        return error.BootFailed;
    };
    if (args.patch) |patch_path| {
        image = try applySoftPatch(io, gpa, image, patch_path, err);
    } else if (args.frames == 0) {
        // Launch discovery: a same-basename softpatch, a patch-folder match,
        // or a registry entry. Whether it is used is the per-game choice the
        // library's prompt records — keyed by the ORIGINAL image's game_id,
        // since the patched game gets its own id (and saves) once booted.
        const stripped = core.header.stripCopierHeader(image);
        if (core.header.detect(stripped)) |h| {
            const sha = core.registry.sha256Hex(stripped);
            const orig_id = try saves.gameId(gpa, &sha, &h.title);
            if (patchfind.findForRom(io, gpa, rom_path, stripped, patches_dir)) |found| {
                const pref = if (cfg.perGame(orig_id)) |p| p.patch else null;
                if (pref) |choice| switch (choice) {
                    .patched => {
                        image = try applySoftPatch(io, gpa, image, found.path, err);
                        try err.print("patch applied: {s}\n", .{found.path});
                        try err.flush();
                    },
                    .original => {},
                } else {
                    try err.print("note: a patch is available for this game ({s}) — pick it in the library to choose PLAY PATCHED\n", .{found.path});
                    try err.flush();
                }
            }
        } else |_| {} // not a SNES ROM: the loader below prints the real error
    }
    if (args.auto_fastrom) {
        const hex = core.registry.sha256Hex(core.header.stripCopierHeader(image));
        if (core.fastrom_compat.find(&hex)) |e| switch (e.status) {
            .ok => try err.print("auto-fastrom: {s} is verified compatible\n", .{e.title}),
            .broken => {
                try err.print("error: auto-fastrom: {s} is known BROKEN with FastROM timing: {s}\n", .{ e.title, e.note });
                try err.flush();
                return error.BootFailed;
            },
            .untested => try err.print("auto-fastrom: WARNING: {s} is untested with FastROM timing ({s})\n", .{ e.title, e.note }),
        } else {
            try err.print("auto-fastrom: WARNING: this ROM is not in patches/fastrom-compat.zon — untested with FastROM timing\n", .{});
        }
        try err.flush();
    }
    const cart = core.Cartridge.load(gpa, image) catch |e| {
        try err.print("error: cannot load ROM: {s}\n", .{@errorName(e)});
        try err.flush();
        return error.BootFailed;
    };
    // Save files are keyed by content hash + title. Computed after
    // patching on purpose: a patched game is a different game, and its
    // states won't load into the original anyway.
    const sha_hex = core.registry.sha256Hex(core.header.stripCopierHeader(image));
    const game_id = try saves.gameId(gpa, &sha_hex, &cart.header.title);

    const pg = cfg.perGame(game_id);
    const merged = mergeBootSettings(args, pg) catch |e| {
        // The same refusals parseArgs makes for the flags, because a
        // hand-edited override can produce the same conflicts.
        switch (e) {
            error.WideNeedsFast => try err.print("error: per-game wide needs the fast core (accuracy override conflicts)\n", .{}),
            error.WideTooBig => try err.print("error: per-game wide margin exceeds {d}\n", .{core.ppu.wide_margin_max}),
        }
        try err.flush();
        return error.BootFailed;
    };
    if (pg != null) {
        try err.print("per-game overrides active for {s}\n", .{game_id});
        try err.flush();
    }
    const accuracy = merged.accuracy;
    const wide = merged.wide;
    const region = merged.region;

    const con = try gpa.create(core.AnyConsole);
    con.init(accuracy, cart);
    switch (region) {
        .auto => {},
        .ntsc => con.setRegion(.ntsc),
        .pal => con.setRegion(.pal),
    }
    if (args.auto_fastrom) con.enableAutoFastrom();
    if (wide != 0) con.setWideMargin(wide);
    return .{
        .con = con,
        .game_id = game_id,
        .region = region,
        .wide = wide,
        .shader = if (pg) |p| p.shader else null,
        .rewind = if (pg) |p| p.rewind else null,
        .rom_crc = util.movie.imageCrc(core.header.stripCopierHeader(image)),
        .accuracy = accuracy,
    };
}

fn parseArgs(init: std.process.Init, gpa: std.mem.Allocator) !Args {
    // Deliberately not deinit'd: on Windows the iterator owns the decoded
    // strings, and `Args.rom` / `Args.shader` are slices into them. `gpa` is the
    // process arena, so they live exactly as long as they need to.
    var it = try util.argIterator(init, gpa);
    var args: Args = .{};
    var rom: ?[]const u8 = null;
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--scale")) {
            const v = it.next() orelse return error.MissingValue;
            const scale = try std.fmt.parseInt(u32, v, 10);
            if (scale == 0 or scale > 8) return error.BadScale;
            args.scale = scale;
        } else if (std.mem.eql(u8, a, "--frames")) {
            const v = it.next() orelse return error.MissingValue;
            args.frames = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, a, "--no-audio")) {
            args.audio = false;
        } else if (std.mem.eql(u8, a, "--accurate")) {
            args.accuracy = .accurate;
        } else if (std.mem.eql(u8, a, "--region")) {
            const v = it.next() orelse return error.MissingValue;
            args.region = std.meta.stringToEnum(app.RegionArg, v) orelse return error.BadRegion;
        } else if (std.mem.eql(u8, a, "--shader")) {
            args.shader = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--patch")) {
            args.patch = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--auto-fastrom")) {
            args.auto_fastrom = true;
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
        } else if (std.mem.eql(u8, a, "--wide")) {
            const v = it.next() orelse return error.MissingValue;
            args.wide = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, a, "--movie")) {
            args.movie = it.next() orelse return error.MissingValue;
        } else if (rom == null) {
            rom = a;
        } else return error.TooManyArgs;
    }
    args.rom = rom;
    // These flags act on one specific ROM; the library picker has none.
    if (rom == null and (args.frames != 0 or args.shot != null or args.patch != null or args.auto_fastrom or args.movie != null))
        return error.NeedsRom;
    // A bare `--shot` captures the final frame — which only exists when the
    // run has one. Refuse the run-until-quit combination up front instead of
    // silently writing nothing.
    if (args.shot != null and args.shot_frames.len == 0 and args.frames == 0)
        return error.ShotNeedsFrames;
    if (args.wide != 0) {
        if (args.accuracy == .accurate) return error.WideNeedsFast;
        if (args.wide > core.ppu.wide_margin_max) return error.WideTooBig;
    }
    return args;
}

test {
    // Every UI module carries its own tests; reference each one explicitly
    // so the `sdl_main_tests` build collects them from this root — an
    // import alone does not analyze a file's test declarations.
    _ = app;
    _ = config;
    _ = input;
    _ = paths;
    _ = saves;
    _ = @import("menu.zig");
    _ = @import("ui.zig");
    _ = @import("font.zig");
    _ = @import("png.zig");
    _ = @import("rewind.zig");
    _ = @import("library.zig");
}
