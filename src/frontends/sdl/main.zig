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

const Args = struct {
    rom: []const u8,
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
        } else if (e == error.WideNeedsFast) {
            try err.print("error: --wide needs the fast core (--accurate's dot renderer doesn't support it)\n", .{});
        } else if (e == error.WideTooBig) {
            try err.print("error: --wide margin exceeds {d}\n", .{core.ppu.wide_margin_max});
        }
        try err.print(
            "usage: yamabuki-sdl <rom.sfc> [--scale N] [--frames N] [--no-audio] [--accurate]\n" ++
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
    if (args.frames == 0) {
        if (paths.Paths.init(gpa)) |p| {
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
    if (args.auto_fastrom) {
        const hex = core.registry.sha256Hex(core.header.stripCopierHeader(image));
        if (core.fastrom_compat.find(&hex)) |e| switch (e.status) {
            .ok => try err.print("auto-fastrom: {s} is verified compatible\n", .{e.title}),
            .broken => {
                try err.print("error: auto-fastrom: {s} is known BROKEN with FastROM timing: {s}\n", .{ e.title, e.note });
                try err.flush();
                std.process.exit(1);
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
        std.process.exit(1);
    };
    const con = try gpa.create(core.AnyConsole);
    con.init(args.accuracy, cart);
    switch (args.region) {
        .auto => {},
        .ntsc => con.setRegion(.ntsc),
        .pal => con.setRegion(.pal),
    }
    if (args.auto_fastrom) con.enableAutoFastrom();
    if (args.wide != 0) con.setWideMargin(args.wide);

    // --- session ------------------------------------------------------------
    // Defaults ← config ← CLI, resolved here once; app.zig never sees the
    // difference between a configured and a flagged setting.
    try app.run(io, gpa, sdl, con, .{
        .rom = args.rom,
        .scale = args.scale orelse cfg.effectiveScale(err),
        .frames = args.frames,
        .audio = args.audio and cfg.audio.enabled,
        .region = args.region,
        .shader = args.shader orelse cfg.video.shader,
        .shader_dir = args.shader_dir,
        .shot = args.shot,
        .shot_frames = args.shot_frames,
        .wide = args.wide,
        .bindings = input.resolve(&cfg.input, err),
        .cfg = &cfg,
        .config_path = config_path,
    }, err, out);
}

fn parseArgs(init: std.process.Init, gpa: std.mem.Allocator) !Args {
    // Deliberately not deinit'd: on Windows the iterator owns the decoded
    // strings, and `Args.rom` / `Args.shader` are slices into them. `gpa` is the
    // process arena, so they live exactly as long as they need to.
    var it = try util.argIterator(init, gpa);
    var args: Args = .{ .rom = undefined };
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
    args.rom = rom orelse return error.NoRom;
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
    _ = @import("menu.zig");
    _ = @import("ui.zig");
    _ = @import("font.zig");
}
