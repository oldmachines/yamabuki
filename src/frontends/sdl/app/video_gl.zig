//! The GL shader path of the player: the GL video state, the profile ladder (GL ES 3 / GL 3.3 / GL ES 2), preset listing, chain building, cycling and the rebuild after a lost context.
//!
//! Carved out of app.zig as pure code motion; every declaration
//! here is re-exported from app.zig, which stays the root.

const gl = @import("../gl.zig");
const osd = @import("../osd.zig");
const preset = @import("../preset.zig");
const sdl3 = @import("../sdl3.zig");
const shader = @import("../shader.zig");
const std = @import("std");
const app_root = @import("../app.zig");

const InitGlError = app_root.InitGlError;
/// A GL context plus the loaded shader chain. Absent means the software blit.
///
/// The chain is swappable at runtime: `,` and `.` walk every preset baked for
/// the profile we actually got, so the cycle can only ever land on a shader
/// this GPU can compile.
pub const GlVideo = struct {
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
    /// The GLSL dialect of the rung that won — what the OSD is compiled in,
    /// kept so a chain rebuild can recompile it.
    dialect: osd.Dialect,
    /// Every preset in that directory, sorted — the cycle order.
    names: [][]const u8,
    index: usize,
    /// The shader-name toast. Null means it failed to compile — never fatal,
    /// by the same rule a shader itself follows: a nice-to-have UI element
    /// must not cost the user the emulator, or the shader chain it is
    /// supposed to be announcing.
    osd: ?osd.Osd,

    pub fn chain(self: *GlVideo) *shader.Chain {
        return &self.chains[self.active];
    }
};

/// Context attempts, best first. Each maps to a directory of baked GLSL: a
/// preset only appears under a profile if it actually transpiled and compiled
/// for it at bake time, so "the shader is listed" and "the shader will run" are
/// the same statement.
pub const Profile = struct {
    dir: []const u8,
    profile_mask: c_int,
    major: c_int,
    minor: c_int,
    /// Which GLSL dialect the OSD's own tiny program should be compiled in —
    /// this ladder and the shader chain's both land on the same rung.
    dialect: osd.Dialect,
};

pub const profiles = [_]Profile{
    .{ .dir = "essl300", .profile_mask = sdl3.gl_profile_es, .major = 3, .minor = 0, .dialect = .essl300 },
    .{ .dir = "glsl330", .profile_mask = sdl3.gl_profile_core, .major = 3, .minor = 3, .dialect = .glsl330 },
    .{ .dir = "essl100", .profile_mask = sdl3.gl_profile_es, .major = 2, .minor = 0, .dialect = .essl100 },
};

/// Bring up a GL context and load `name` from the best profile the driver will
/// give us. Tries GLES 3, then desktop GL 3.3, then GLES 2 — and for each, only
/// accepts it if the preset actually has a baked variant for that profile.
///
/// A GLES2-only device therefore silently gets the GLES2 build of a shader that
/// has one, and a clear "not available for this GPU" for one that does not,
/// rather than a context it cannot compile the shader in.
pub fn initGl(
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
        const names = listPresets(io, gpa, profile_dir) catch {
            gpa.free(profile_dir);
            continue;
        };
        any_dir_listed = true;
        // Every rung that falls through frees what it listed: a machine
        // that fails all three used to leak three preset listings.
        const start = indexOfName(names, name) orelse {
            for (names) |n| gpa.free(n);
            gpa.free(names);
            gpa.free(profile_dir);
            continue;
        };
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
            for (names) |n| gpa.free(n);
            gpa.free(names);
            gpa.free(profile_dir);
            continue;
        };
        _ = sdl_gl.SDL_GL_MakeCurrent(window, ctx);
        // Pacing is ours, as in the software path: never vsync-throttle here or
        // the game clock follows the display refresh.
        _ = sdl_gl.SDL_GL_SetSwapInterval(0);

        const api = gl.load(sdl_gl.SDL_GL_GetProcAddress) catch {
            _ = sdl_gl.SDL_GL_DestroyContext(ctx);
            for (names) |n| gpa.free(n);
            gpa.free(names);
            gpa.free(profile_dir);
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
            .dialect = prof.dialect,
            .names = names,
            .index = start,
            .osd = null,
        };
        buildChain(io, gpa, g, start, g.chain(), err) catch |e| {
            _ = sdl_gl.SDL_GL_DestroyContext(ctx);
            destroyGlVideo(gpa, g); // frees names + profile_dir + g
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
pub fn listPresets(io: std.Io, gpa: std.mem.Allocator, profile_dir: []const u8) ![][]const u8 {
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
        pub fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return out;
}

pub fn indexOfName(names: []const []const u8, name: []const u8) ?usize {
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
pub fn buildChain(
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

/// Rebuild the current preset in place after the GL context may have
/// been lost or its objects reset (window restored, display changed, GPU
/// reset, a failed swap). Re-asserts the context, compiles the same preset
/// into the spare slot — the path `cycleShader` already takes — and swaps
/// it in; the OSD's objects are rebuilt the same way. On failure the
/// incumbent is left as it was and the caller decides what to do.
pub fn rebuildChain(
    io: std.Io,
    gpa: std.mem.Allocator,
    g: *GlVideo,
    window: *sdl3.Window,
    err: *std.Io.Writer,
) !void {
    if (!g.sdl_gl.SDL_GL_MakeCurrent(window, g.ctx)) return error.GlMakeCurrentFailed;
    // Drain any stale error so the post-swap check reads this frame's.
    while (g.api.glGetError() != gl.NO_ERROR) {}
    const spare: u1 = 1 - g.active;
    try buildChain(io, gpa, g, g.index, &g.chains[spare], err);
    g.chain().deinit();
    g.active = spare;
    if (g.osd) |*o| {
        o.deinit();
        g.osd = osd.Osd.init(g.api, g.dialect) catch null;
    }
    err.print("shader: chain rebuilt after a context change\n", .{}) catch {};
    err.flush() catch {};
}

/// Free everything `initGl` allocated for a `GlVideo` besides the GL
/// objects (those are the chain's and the context's to release).
pub fn destroyGlVideo(gpa: std.mem.Allocator, g: *GlVideo) void {
    for (g.names) |n| gpa.free(n);
    gpa.free(g.names);
    gpa.free(g.profile_dir);
    gpa.destroy(g);
}

/// Step `delta` presets and swap the chain in.
///
/// The replacement is built *before* the incumbent is torn down, so a preset
/// that fails to compile on this GPU costs a printed line and nothing else —
/// the picture never drops out from under the player.
pub fn cycleShader(
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
