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
            try err.print("error: --frames/--shot/--patch/--auto-fastrom need an explicit ROM argument\n", .{});
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
                "                    [--shot PREFIX [--shot-frames a,b,c]]\n" ++
                "  --region r  ntsc|pal|auto (default auto: detect from the cart header)\n" ++
                "  --wide N    widen the framebuffer by N columns on each side, e.g. 32 -> 320x224\n" ++
                "              (fast core only; for widescreen game patches such as wide-snes)\n" ++
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
                // First run: write the defaults so the file exists to be
                // discovered and edited.
                .missing => config.save(io, gpa, cfg, p.config) catch |e| {
                    try err.print("warning: cannot write {s}: {s}\n", .{ p.config, @errorName(e) });
                    try err.flush();
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
        const b = bootConsole(io, gpa, rom_path, args, &cfg, err) catch std.process.exit(1);
        _ = try app.run(io, gpa, sdl, b.con, makeOptions(rom_path, b, args, &cfg, config_path, user_paths, bindings, err), err, out);
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
            err,
        ) orelse break;
        const b = bootConsole(io, gpa, picked, args, &cfg, err) catch continue;
        const result = try app.run(io, gpa, sdl, b.con, makeOptions(picked, b, args, &cfg, config_path, user_paths, bindings, err), err, out);
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
    };
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
};

/// ROM file → running console: read, soft-patch, auto-FastROM gate, cart
/// load, per-game merge, region/wide setup, save-file identity. Every
/// failure prints its reason and returns an error — the direct-launch path
/// exits on it, the library path goes back to the list.
fn bootConsole(io: std.Io, gpa: std.mem.Allocator, rom_path: []const u8, args: Args, cfg: *const config.Config, err: *std.Io.Writer) !Booted {
    var image = std.Io.Dir.cwd().readFileAlloc(io, rom_path, gpa, .limited(16 * 1024 * 1024)) catch {
        try err.print("error: cannot read ROM '{s}'\n", .{rom_path});
        try err.flush();
        return error.BootFailed;
    };
    if (args.patch) |patch_path| {
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
        image = res.image;
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
        } else if (rom == null) {
            rom = a;
        } else return error.TooManyArgs;
    }
    args.rom = rom;
    // These flags act on one specific ROM; the library picker has none.
    if (rom == null and (args.frames != 0 or args.shot != null or args.patch != null or args.auto_fastrom))
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
