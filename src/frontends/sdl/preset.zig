//! Baked shader-preset manifest: parsing and pass geometry.
//!
//! This module is deliberately GL-free and allocation-free so the parts that
//! are easy to get quietly wrong — the scale math and the uniform layout — can
//! be unit-tested on any host, including one with no GPU.
//!
//! The manifest is *not* a libretro `.slangp`. It is the output of
//! `tools/transpile_shaders.py`, which runs the real slang preset through
//! glslang and SPIRV-Cross on the build host and emits, per pass, plain GLSL
//! plus the reflected uniform offsets. Everything ambiguous is resolved at bake
//! time, so the runtime parser never has to interpret a shader — it only has to
//! plumb bytes into offsets. A semantic this module does not know about is a
//! bake-time failure (see `transpile_shaders.py`), never a silently wrong frame.
//!
//! Format (leading whitespace ignored; `#` comments; one directive per line):
//!
//!     name crt-lottes
//!     tier handheld
//!     profile essl300
//!     param SCANLINE_WEIGHT 0.3 0 1 0.05
//!     pass 0
//!       vert pass0.vert
//!       frag pass0.frag
//!       scale_x source 1.0
//!       scale_y source 1.0
//!       filter linear
//!       wrap clamp_to_edge
//!       float_fb 0
//!       ubo 0 144 UBO block            # binding, byte size, block name, mode
//!       uniform ubo 0 global.MVP mat4 mvp
//!       uniform push 0 params.OutputSize vec4 output_size
//!       uniform ubo 128 global.SCANLINE_WEIGHT float param SCANLINE_WEIGHT
//!       texture 0 Source    source - linear clamp_to_edge
//!       texture 1 FirstPass pass   FirstPass linear clamp_to_edge
//!
//! A uniform carries both an `offset` (used when its block is a std140 buffer)
//! and a fully-qualified GLSL `name` (used when the block came out as plain
//! uniforms, which is what ESSL 100 gets). The baker fills in both and records
//! which mode it emitted, so the runtime never infers.

const std = @import("std");

pub const max_passes = 16;
pub const max_uniforms = 192;
pub const max_textures = 12;
// crt-guest-advanced alone declares 148 `#pragma parameter`s, and a pass can
// reference nearly all of them plus the size semantics. The baker asserts
// against these same numbers, so a shader that would overflow them fails on the
// build host rather than at load on someone's handheld.
//
// These bounds make a Preset ~280 KiB, which is why Chain is never a local: it
// lives in the heap-allocated GlVideo (see the frontend), and cycling
// double-buffers between two slots rather than building one on the stack.
pub const max_params = 192;
pub const max_luts = 8;
pub const max_name = 64;

/// How a pass's render-target size is derived. Mirrors the libretro spec.
pub const ScaleType = enum {
    /// Multiply the *input* size to this pass.
    source,
    /// Multiply the final on-screen viewport size.
    viewport,
    /// Ignore the scale factor; the value is a pixel count.
    absolute,
};

pub const Filter = enum { nearest, linear };

pub const Wrap = enum { clamp_to_edge, clamp_to_border, repeat, mirrored_repeat };

/// A value the runtime knows how to compute each frame. Anything outside this
/// set is rejected by the baker rather than shipped.
pub const Semantic = enum {
    mvp,
    source_size,
    original_size,
    output_size,
    final_viewport_size,
    frame_count,
    frame_direction,
    /// Size of an earlier pass's render target; `index` selects which.
    pass_output_size,
    /// A `#pragma parameter` float; `index` selects which.
    parameter,
};

/// Which of the two slang blocks a value lives in.
pub const Block = enum { ubo, push };

/// How a block reaches the shader.
///
/// SPIRV-Cross picks this for us, and it differs by profile: on ESSL 300 and
/// GLSL 330 the UBO comes out as a real `layout(std140) uniform UBO {...}`
/// block; on ESSL 100, which has no uniform blocks at all, it comes out as a
/// plain struct (`uniform UBO global;`) whose members are ordinary uniforms.
/// The push-constant block is always plain. The baker records what it actually
/// emitted, so the runtime never has to guess.
pub const BlockMode = enum {
    /// std140 buffer: write at `Uniform.offset`, upload once per pass.
    block,
    /// Ordinary uniforms: set each by `Uniform.name` with a typed glUniform*.
    plain,
};

/// The GLSL type of a uniform, which decides the glUniform* call in plain mode.
pub const UType = enum { mat4, vec4, vec2, float, int, uint };

pub const Uniform = struct {
    block: Block,
    /// Byte offset within the std140 block. Meaningful in `.block` mode only.
    offset: u32 = 0,
    /// Fully-qualified GLSL name (`global.SourceSize`, `params.OutputSize`).
    /// Meaningful in `.plain` mode only.
    name: [max_name]u8 = @splat(0),
    name_len: u8 = 0,
    utype: UType = .vec4,
    semantic: Semantic,
    /// Parameter index for `.parameter`; pass index for `.pass_output_size`.
    index: u16 = 0,

    pub fn name_str(self: *const Uniform) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// What a sampler in this pass should be bound to.
pub const TextureKind = enum {
    /// Output of the previous pass (the console frame, for pass 0).
    source,
    /// The console frame, whatever pass we are on.
    original,
    /// Output of an earlier pass, by alias.
    pass_alias,
    /// An aliased pass's output from the *previous* frame. Unlike `pass_alias`
    /// this may name a later pass, or the sampling pass itself — last frame's
    /// copy has already been written, which is exactly what makes afterglow and
    /// phosphor-persistence effects possible.
    pass_feedback,
    /// The console frame from N frames ago.
    original_history,
    /// A lookup table shipped with the preset (phosphor masks and the like).
    lut,
};

/// A lookup-table texture. The baker decodes the preset's PNG to raw RGBA8 and
/// records its dimensions here, so the runtime needs no image decoder at all —
/// it uploads bytes. Same principle as the shaders: anything that can be
/// resolved on the build host is.
pub const Lut = struct {
    name: [max_name]u8 = @splat(0),
    name_len: u8 = 0,
    file: [max_name]u8 = @splat(0),
    file_len: u8 = 0,
    w: u32 = 0,
    h: u32 = 0,
    filter: Filter = .linear,
    wrap: Wrap = .repeat,
    mipmap: bool = false,

    pub fn name_str(self: *const Lut) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn file_str(self: *const Lut) []const u8 {
        return self.file[0..self.file_len];
    }
};

pub const Texture = struct {
    /// GL texture unit.
    unit: u8,
    /// The sampler's name in the baked GLSL. ESSL 300 has no explicit binding
    /// qualifier, so the unit is assigned at link time by name — the manifest
    /// has to carry it.
    name: [max_name]u8 = @splat(0),
    name_len: u8 = 0,
    kind: TextureKind,
    /// Pass index for `.pass_alias`; frame depth for `.original_history`.
    index: u8 = 0,
    filter: Filter = .linear,
    wrap: Wrap = .clamp_to_edge,

    pub fn name_str(self: *const Texture) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Param = struct {
    name: [max_name]u8 = @splat(0),
    name_len: u8 = 0,
    value: f32 = 0,
    min: f32 = 0,
    max: f32 = 0,
    step: f32 = 0,

    pub fn name_str(self: *const Param) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Pass = struct {
    vert: [max_name]u8 = @splat(0),
    vert_len: u8 = 0,
    frag: [max_name]u8 = @splat(0),
    frag_len: u8 = 0,
    alias: [max_name]u8 = @splat(0),
    alias_len: u8 = 0,

    scale_type_x: ScaleType = .source,
    scale_x: f32 = 1.0,
    scale_type_y: ScaleType = .source,
    scale_y: f32 = 1.0,

    filter: Filter = .linear,
    wrap: Wrap = .clamp_to_edge,
    float_fb: bool = false,
    srgb_fb: bool = false,
    mipmap: bool = false,
    /// Some pass samples this one's previous-frame output, so its render target
    /// must be double-buffered.
    feedback: bool = false,

    /// How the UBO reaches this pass's shader — a real std140 block on GLES3
    /// and desktop, plain uniforms on GLES2. Set by the baker from what
    /// SPIRV-Cross actually emitted for the profile.
    ubo_mode: BlockMode = .plain,
    ubo_binding: u32 = 0,
    ubo_size: u32 = 0,
    /// The *block* name (`UBO`), for glGetUniformBlockIndex in `.block` mode.
    ubo_name: [max_name]u8 = @splat(0),
    ubo_name_len: u8 = 0,

    uniforms: [max_uniforms]Uniform = undefined,
    uniform_count: u8 = 0,
    textures: [max_textures]Texture = undefined,
    texture_count: u8 = 0,

    pub fn vert_str(self: *const Pass) []const u8 {
        return self.vert[0..self.vert_len];
    }
    pub fn frag_str(self: *const Pass) []const u8 {
        return self.frag[0..self.frag_len];
    }
    pub fn alias_str(self: *const Pass) []const u8 {
        return self.alias[0..self.alias_len];
    }
    pub fn ubo_name_str(self: *const Pass) []const u8 {
        return self.ubo_name[0..self.ubo_name_len];
    }
};

pub const Tier = enum { handheld, desktop };

pub const Preset = struct {
    name: [max_name]u8 = @splat(0),
    name_len: u8 = 0,
    tier: Tier = .desktop,

    passes: [max_passes]Pass = undefined,
    pass_count: u8 = 0,
    params: [max_params]Param = undefined,
    param_count: u8 = 0,
    luts: [max_luts]Lut = undefined,
    lut_count: u8 = 0,

    pub fn name_str(self: *const Preset) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn findLut(self: *const Preset, name: []const u8) ?u8 {
        for (self.luts[0..self.lut_count], 0..) |*l, i| {
            if (std.mem.eql(u8, l.name_str(), name)) return @intCast(i);
        }
        return null;
    }

    /// Index of a `#pragma parameter` by name, for the runtime tuning UI.
    pub fn findParam(self: *const Preset, name: []const u8) ?u8 {
        for (self.params[0..self.param_count], 0..) |*p, i| {
            if (std.mem.eql(u8, p.name_str(), name)) return @intCast(i);
        }
        return null;
    }

    /// Index of a pass by its declared alias.
    pub fn findAlias(self: *const Preset, alias: []const u8) ?u8 {
        if (alias.len == 0) return null;
        for (self.passes[0..self.pass_count], 0..) |*p, i| {
            if (std.mem.eql(u8, p.alias_str(), alias)) return @intCast(i);
        }
        return null;
    }
};

pub const Size = struct { w: u32, h: u32 };

/// Clamp: a zero-area target would make the whole chain undefined, and a
/// runaway scale on a handheld is a VRAM-exhaustion crash rather than a slow
/// frame. Both ends are bounded here rather than trusted from the manifest.
const min_dim: u32 = 1;
const max_dim: u32 = 8192;

fn scaleDim(kind: ScaleType, scale: f32, source: u32, viewport: u32) u32 {
    const base: f32 = switch (kind) {
        .source => @floatFromInt(source),
        .viewport => @floatFromInt(viewport),
        .absolute => 1.0,
    };
    const v = base * scale;
    if (!(v >= 1.0)) return min_dim; // also catches NaN
    const r: u32 = @intFromFloat(@floor(v));
    return std.math.clamp(r, min_dim, max_dim);
}

/// Render-target size for one pass.
///
/// `source` is the size of *this pass's input* (the previous pass's output, or
/// the console frame for pass 0) — not the console frame. Getting that wrong is
/// the classic multi-pass bug: it renders fine for single-pass shaders and goes
/// subtly wrong the moment a pass scales.
pub fn passSize(pass: *const Pass, source: Size, viewport: Size) Size {
    return .{
        .w = scaleDim(pass.scale_type_x, pass.scale_x, source.w, viewport.w),
        .h = scaleDim(pass.scale_type_y, pass.scale_y, source.h, viewport.h),
    };
}

/// Step `delta` places through a list of `len` presets, wrapping both ways.
///
/// Lives here rather than in the frontend so the wrap is actually testable:
/// stepping back from the first entry has to land on the last, and Zig's `@mod`
/// (euclidean, unlike `@rem`) is what makes that true for a negative delta.
pub fn cycle(index: usize, delta: isize, len: usize) usize {
    if (len == 0) return 0;
    const n: isize = @intCast(len);
    const i: isize = @intCast(index);
    return @intCast(@mod(i + delta, n));
}

pub const ParseError = error{
    BadDirective,
    BadValue,
    TooManyPasses,
    TooManyUniforms,
    TooManyTextures,
    TooManyParams,
    TooManyLuts,
    NameTooLong,
    UnknownAlias,
    UnknownLut,
    FeedbackNotBuffered,
    NoPasses,
    PassOutOfOrder,
};

fn copyName(dst: *[max_name]u8, len: *u8, s: []const u8) ParseError!void {
    if (s.len > max_name) return error.NameTooLong;
    @memcpy(dst[0..s.len], s);
    len.* = @intCast(s.len);
}

fn parseEnum(comptime T: type, s: []const u8) ParseError!T {
    return std.meta.stringToEnum(T, s) orelse error.BadValue;
}

/// Texture kinds are spelled with the short names the manifest uses (`pass`,
/// `history`) rather than the enum's, so the baked files read like the libretro
/// vocabulary they came from.
fn parseTextureKind(s: []const u8) ParseError!TextureKind {
    if (std.mem.eql(u8, s, "source")) return .source;
    if (std.mem.eql(u8, s, "original")) return .original;
    if (std.mem.eql(u8, s, "pass")) return .pass_alias;
    if (std.mem.eql(u8, s, "feedback")) return .pass_feedback;
    if (std.mem.eql(u8, s, "history")) return .original_history;
    if (std.mem.eql(u8, s, "lut")) return .lut;
    return error.BadValue;
}

/// Likewise `param` on a `uniform` line matches the `param` declaration above
/// it. Every other semantic is spelled exactly as the enum.
fn parseSemantic(s: []const u8) ParseError!Semantic {
    if (std.mem.eql(u8, s, "param")) return .parameter;
    return parseEnum(Semantic, s);
}

fn parseF32(s: []const u8) ParseError!f32 {
    return std.fmt.parseFloat(f32, s) catch error.BadValue;
}

fn parseU32(s: []const u8) ParseError!u32 {
    return std.fmt.parseInt(u32, s, 10) catch error.BadValue;
}

fn parseBool(s: []const u8) ParseError!bool {
    if (std.mem.eql(u8, s, "0")) return false;
    if (std.mem.eql(u8, s, "1")) return true;
    return error.BadValue;
}

/// Parse a baked manifest. Pass-alias texture references are resolved to pass
/// indices here, so an alias typo fails at load with `UnknownAlias` instead of
/// sampling a black texture for the rest of the session.
pub fn parse(text: []const u8) ParseError!Preset {
    var p: Preset = .{};
    var cur: ?*Pass = null;

    // Alias references are resolved in a second sweep: a pass may legally
    // sample an alias declared before it, but the alias line for pass N is read
    // after the texture lines of pass N-1, so one pass is not enough.
    var pending: [max_passes][max_textures][max_name]u8 = undefined;
    var pending_len: [max_passes][max_textures]u8 = @splat(@splat(0));

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        var it = std.mem.tokenizeAny(u8, line, " \t");
        const key = it.next() orelse continue;

        if (std.mem.eql(u8, key, "name")) {
            try copyName(&p.name, &p.name_len, it.next() orelse return error.BadValue);
        } else if (std.mem.eql(u8, key, "tier")) {
            p.tier = try parseEnum(Tier, it.next() orelse return error.BadValue);
        } else if (std.mem.eql(u8, key, "profile")) {
            _ = it.next(); // recorded for provenance; the loader picks the dir
        } else if (std.mem.eql(u8, key, "param")) {
            if (p.param_count >= max_params) return error.TooManyParams;
            var q: Param = .{};
            try copyName(&q.name, &q.name_len, it.next() orelse return error.BadValue);
            q.value = try parseF32(it.next() orelse return error.BadValue);
            q.min = try parseF32(it.next() orelse return error.BadValue);
            q.max = try parseF32(it.next() orelse return error.BadValue);
            q.step = try parseF32(it.next() orelse return error.BadValue);
            p.params[p.param_count] = q;
            p.param_count += 1;
        } else if (std.mem.eql(u8, key, "lut")) {
            // lut <name> <file> <w> <h> <filter> <wrap> <mipmap>
            if (p.lut_count >= max_luts) return error.TooManyLuts;
            var l: Lut = .{};
            try copyName(&l.name, &l.name_len, it.next() orelse return error.BadValue);
            try copyName(&l.file, &l.file_len, it.next() orelse return error.BadValue);
            l.w = try parseU32(it.next() orelse return error.BadValue);
            l.h = try parseU32(it.next() orelse return error.BadValue);
            l.filter = try parseEnum(Filter, it.next() orelse return error.BadValue);
            l.wrap = try parseEnum(Wrap, it.next() orelse return error.BadValue);
            l.mipmap = try parseBool(it.next() orelse return error.BadValue);
            p.luts[p.lut_count] = l;
            p.lut_count += 1;
        } else if (std.mem.eql(u8, key, "pass")) {
            const idx = try parseU32(it.next() orelse return error.BadValue);
            if (idx != p.pass_count) return error.PassOutOfOrder;
            if (p.pass_count >= max_passes) return error.TooManyPasses;
            p.passes[p.pass_count] = .{};
            cur = &p.passes[p.pass_count];
            p.pass_count += 1;
        } else {
            // Everything below is a pass-scoped directive.
            const pass = cur orelse return error.BadDirective;
            const pass_idx = p.pass_count - 1;

            if (std.mem.eql(u8, key, "vert")) {
                try copyName(&pass.vert, &pass.vert_len, it.next() orelse return error.BadValue);
            } else if (std.mem.eql(u8, key, "frag")) {
                try copyName(&pass.frag, &pass.frag_len, it.next() orelse return error.BadValue);
            } else if (std.mem.eql(u8, key, "alias")) {
                try copyName(&pass.alias, &pass.alias_len, it.next() orelse return error.BadValue);
            } else if (std.mem.eql(u8, key, "scale_x")) {
                pass.scale_type_x = try parseEnum(ScaleType, it.next() orelse return error.BadValue);
                pass.scale_x = try parseF32(it.next() orelse return error.BadValue);
            } else if (std.mem.eql(u8, key, "scale_y")) {
                pass.scale_type_y = try parseEnum(ScaleType, it.next() orelse return error.BadValue);
                pass.scale_y = try parseF32(it.next() orelse return error.BadValue);
            } else if (std.mem.eql(u8, key, "filter")) {
                pass.filter = try parseEnum(Filter, it.next() orelse return error.BadValue);
            } else if (std.mem.eql(u8, key, "wrap")) {
                pass.wrap = try parseEnum(Wrap, it.next() orelse return error.BadValue);
            } else if (std.mem.eql(u8, key, "float_fb")) {
                pass.float_fb = try parseBool(it.next() orelse return error.BadValue);
            } else if (std.mem.eql(u8, key, "srgb_fb")) {
                pass.srgb_fb = try parseBool(it.next() orelse return error.BadValue);
            } else if (std.mem.eql(u8, key, "mipmap")) {
                pass.mipmap = try parseBool(it.next() orelse return error.BadValue);
            } else if (std.mem.eql(u8, key, "feedback")) {
                pass.feedback = try parseBool(it.next() orelse return error.BadValue);
            } else if (std.mem.eql(u8, key, "ubo")) {
                // ubo <binding> <byte-size> <block-name> <block|plain>
                pass.ubo_binding = try parseU32(it.next() orelse return error.BadValue);
                pass.ubo_size = try parseU32(it.next() orelse return error.BadValue);
                try copyName(&pass.ubo_name, &pass.ubo_name_len, it.next() orelse return error.BadValue);
                pass.ubo_mode = try parseEnum(BlockMode, it.next() orelse return error.BadValue);
            } else if (std.mem.eql(u8, key, "uniform")) {
                // uniform <ubo|push> <offset> <glsl-name> <type> <semantic> [arg]
                if (pass.uniform_count >= max_uniforms) return error.TooManyUniforms;
                var u: Uniform = .{
                    .block = try parseEnum(Block, it.next() orelse return error.BadValue),
                    .offset = try parseU32(it.next() orelse return error.BadValue),
                    .semantic = undefined,
                };
                try copyName(&u.name, &u.name_len, it.next() orelse return error.BadValue);
                u.utype = try parseEnum(UType, it.next() orelse return error.BadValue);
                u.semantic = try parseSemantic(it.next() orelse return error.BadValue);
                switch (u.semantic) {
                    .parameter => {
                        const pname = it.next() orelse return error.BadValue;
                        u.index = p.findParam(pname) orelse return error.BadValue;
                    },
                    .pass_output_size => {
                        u.index = @intCast(try parseU32(it.next() orelse return error.BadValue));
                    },
                    else => {},
                }
                pass.uniforms[pass.uniform_count] = u;
                pass.uniform_count += 1;
            } else if (std.mem.eql(u8, key, "texture")) {
                // texture <unit> <sampler-name> <kind> <arg> <filter> <wrap>
                // `arg` is the alias for `pass`, the frame depth for `history`,
                // and `-` otherwise; it is always present so the line is
                // positionally unambiguous.
                if (pass.texture_count >= max_textures) return error.TooManyTextures;
                var t: Texture = .{
                    .unit = @intCast(try parseU32(it.next() orelse return error.BadValue)),
                    .kind = undefined,
                };
                try copyName(&t.name, &t.name_len, it.next() orelse return error.BadValue);
                t.kind = try parseTextureKind(it.next() orelse return error.BadValue);
                const arg = it.next() orelse return error.BadValue;
                switch (t.kind) {
                    // Both of these name a pass by alias, and an alias may be
                    // declared after the pass that references it — so they are
                    // resolved in the sweep below, not here.
                    .pass_alias, .pass_feedback => {
                        if (arg.len > max_name) return error.NameTooLong;
                        @memcpy(pending[pass_idx][pass.texture_count][0..arg.len], arg);
                        pending_len[pass_idx][pass.texture_count] = @intCast(arg.len);
                    },
                    .original_history => t.index = @intCast(try parseU32(arg)),
                    // LUTs are declared before any pass, so this resolves now
                    // rather than in the alias sweep below.
                    .lut => t.index = p.findLut(arg) orelse return error.UnknownLut,
                    else => {},
                }
                t.filter = try parseEnum(Filter, it.next() orelse return error.BadValue);
                t.wrap = try parseEnum(Wrap, it.next() orelse return error.BadValue);
                pass.textures[pass.texture_count] = t;
                pass.texture_count += 1;
            } else return error.BadDirective;
        }
    }

    if (p.pass_count == 0) return error.NoPasses;

    for (p.passes[0..p.pass_count], 0..) |*pass, pi| {
        for (pass.textures[0..pass.texture_count], 0..) |*t, ti| {
            if (t.kind != .pass_alias and t.kind != .pass_feedback) continue;
            const len = pending_len[pi][ti];
            const alias = pending[pi][ti][0..len];
            t.index = p.findAlias(alias) orelse return error.UnknownAlias;
            // A feedback reference is only meaningful if the target pass is
            // actually double-buffered. The baker sets this; disagreement means
            // the manifest is internally inconsistent.
            if (t.kind == .pass_feedback and !p.passes[t.index].feedback)
                return error.FeedbackNotBuffered;
        }
    }
    return p;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "passSize: source scaling multiplies this pass's input, not the frame" {
    var pass: Pass = .{ .scale_type_x = .source, .scale_x = 2.0, .scale_type_y = .source, .scale_y = 2.0 };
    // A pass whose input is already a 2x upscale must land on 4x, not 2x.
    const s = passSize(&pass, .{ .w = 512, .h = 448 }, .{ .w = 640, .h = 480 });
    try testing.expectEqual(@as(u32, 1024), s.w);
    try testing.expectEqual(@as(u32, 896), s.h);
}

test "passSize: viewport scaling ignores the source" {
    var pass: Pass = .{ .scale_type_x = .viewport, .scale_x = 1.0, .scale_type_y = .viewport, .scale_y = 0.5 };
    const s = passSize(&pass, .{ .w = 256, .h = 224 }, .{ .w = 640, .h = 480 });
    try testing.expectEqual(@as(u32, 640), s.w);
    try testing.expectEqual(@as(u32, 240), s.h);
}

test "passSize: absolute ignores both and takes the literal pixel count" {
    var pass: Pass = .{ .scale_type_x = .absolute, .scale_x = 1024, .scale_type_y = .absolute, .scale_y = 16 };
    const s = passSize(&pass, .{ .w = 256, .h = 224 }, .{ .w = 640, .h = 480 });
    try testing.expectEqual(@as(u32, 1024), s.w);
    try testing.expectEqual(@as(u32, 16), s.h);
}

test "passSize: degenerate scales clamp instead of producing a zero-area target" {
    var tiny: Pass = .{ .scale_type_x = .source, .scale_x = 0.001, .scale_type_y = .source, .scale_y = 0.0 };
    const s = passSize(&tiny, .{ .w = 256, .h = 224 }, .{ .w = 640, .h = 480 });
    try testing.expectEqual(@as(u32, 1), s.w);
    try testing.expectEqual(@as(u32, 1), s.h);

    var huge: Pass = .{ .scale_type_x = .source, .scale_x = 1000.0, .scale_type_y = .absolute, .scale_y = 99999 };
    const b = passSize(&huge, .{ .w = 256, .h = 224 }, .{ .w = 640, .h = 480 });
    try testing.expectEqual(@as(u32, 8192), b.w);
    try testing.expectEqual(@as(u32, 8192), b.h);
}

test "parse: a two-pass preset with params, uniforms, and an alias reference" {
    const src =
        \\# comment
        \\name crt-lottes
        \\tier handheld
        \\profile essl300
        \\param SCANLINE_WEIGHT 0.3 0 1 0.05
        \\pass 0
        \\  vert pass0.vert
        \\  frag pass0.frag
        \\  scale_x source 1.0
        \\  scale_y source 1.0
        \\  filter nearest
        \\  alias FirstPass
        \\  ubo 0 144 UBO block
        \\  uniform ubo 0 global.MVP mat4 mvp
        \\  uniform ubo 64 global.SourceSize vec4 source_size
        \\  uniform push 0 params.FrameCount uint frame_count
        \\  uniform ubo 128 global.SCANLINE_WEIGHT float param SCANLINE_WEIGHT
        \\  texture 0 Source source - nearest clamp_to_edge
        \\pass 1
        \\  vert pass1.vert
        \\  frag pass1.frag
        \\  scale_x viewport 1.0
        \\  scale_y viewport 1.0
        \\  filter linear
        \\  texture 0 Source source - linear clamp_to_edge
        \\  texture 1 Original original - nearest clamp_to_edge
        \\  texture 2 FirstPass pass FirstPass linear repeat
    ;
    const p = try parse(src);

    try testing.expectEqualStrings("crt-lottes", p.name_str());
    try testing.expectEqual(Tier.handheld, p.tier);
    try testing.expectEqual(@as(u8, 2), p.pass_count);

    try testing.expectEqual(@as(u8, 1), p.param_count);
    try testing.expectEqualStrings("SCANLINE_WEIGHT", p.params[0].name_str());
    try testing.expectEqual(@as(f32, 0.3), p.params[0].value);

    const p0 = &p.passes[0];
    try testing.expectEqualStrings("pass0.frag", p0.frag_str());
    try testing.expectEqual(Filter.nearest, p0.filter);
    try testing.expectEqual(@as(u32, 144), p0.ubo_size);
    try testing.expectEqualStrings("UBO", p0.ubo_name_str());
    try testing.expectEqual(BlockMode.block, p0.ubo_mode);
    try testing.expectEqual(@as(u8, 4), p0.uniform_count);
    try testing.expectEqual(Semantic.mvp, p0.uniforms[0].semantic);
    try testing.expectEqual(UType.mat4, p0.uniforms[0].utype);
    try testing.expectEqualStrings("global.MVP", p0.uniforms[0].name_str());
    try testing.expectEqual(Block.push, p0.uniforms[2].block);
    try testing.expectEqual(UType.uint, p0.uniforms[2].utype);
    try testing.expectEqual(Semantic.parameter, p0.uniforms[3].semantic);
    try testing.expectEqual(@as(u16, 0), p0.uniforms[3].index);

    // The alias in pass 1 must have resolved to pass 0's index.
    const p1 = &p.passes[1];
    try testing.expectEqual(@as(u8, 3), p1.texture_count);
    try testing.expectEqual(TextureKind.pass_alias, p1.textures[2].kind);
    try testing.expectEqual(@as(u8, 0), p1.textures[2].index);
    try testing.expectEqual(Wrap.repeat, p1.textures[2].wrap);
    try testing.expectEqualStrings("FirstPass", p1.textures[2].name_str());
    try testing.expectEqualStrings("Original", p1.textures[1].name_str());
}

test "parse: an unknown alias is a load-time error, not a black texture" {
    const src =
        \\name broken
        \\pass 0
        \\  vert a.vert
        \\  frag a.frag
        \\  texture 0 NoSuchPass pass NoSuchPass linear clamp_to_edge
    ;
    try testing.expectError(error.UnknownAlias, parse(src));
}

test "parse: an unknown semantic is rejected rather than ignored" {
    const src =
        \\name broken
        \\pass 0
        \\  vert a.vert
        \\  frag a.frag
        \\  uniform ubo 0 global.Feedback vec4 pass_feedback
    ;
    try testing.expectError(error.BadValue, parse(src));
}

test "parse: ESSL100's plain-uniform form round-trips" {
    // No `block` mode, no offsets that matter — every uniform is addressed by
    // its GLSL name. This is the shape the GLES2 fallback actually loads.
    const src =
        \\name crt-pi
        \\tier handheld
        \\pass 0
        \\  vert pass0.vert
        \\  frag pass0.frag
        \\  ubo 0 96 UBO plain
        \\  uniform ubo 0 global.MVP mat4 mvp
        \\  uniform ubo 64 global.OutputSize vec4 output_size
        \\  uniform push 0 params.SourceSize vec4 source_size
        \\  texture 0 Source source - linear clamp_to_edge
    ;
    const p = try parse(src);
    try testing.expectEqual(BlockMode.plain, p.passes[0].ubo_mode);
    try testing.expectEqualStrings("global.OutputSize", p.passes[0].uniforms[1].name_str());
    try testing.expectEqual(Semantic.source_size, p.passes[0].uniforms[2].semantic);
}

test "parse: passes must be declared in order" {
    const src =
        \\name broken
        \\pass 1
        \\  vert a.vert
    ;
    try testing.expectError(error.PassOutOfOrder, parse(src));
}

test "parse: a manifest with no passes is an error" {
    try testing.expectError(error.NoPasses, parse("name empty\ntier desktop\n"));
}

test "cycle: wraps both ways, and backwards from the first lands on the last" {
    // The bug this exists to prevent: `@rem(-1, 3)` is -1, which would index
    // out of bounds. `@mod` gives 2.
    try testing.expectEqual(@as(usize, 1), cycle(0, 1, 3));
    try testing.expectEqual(@as(usize, 2), cycle(1, 1, 3));
    try testing.expectEqual(@as(usize, 0), cycle(2, 1, 3)); // forward wrap
    try testing.expectEqual(@as(usize, 2), cycle(0, -1, 3)); // backward wrap
    try testing.expectEqual(@as(usize, 1), cycle(2, -1, 3));

    // A single preset always cycles back to itself, never off the end.
    try testing.expectEqual(@as(usize, 0), cycle(0, 1, 1));
    try testing.expectEqual(@as(usize, 0), cycle(0, -1, 1));

    // An empty list must not divide by zero.
    try testing.expectEqual(@as(usize, 0), cycle(0, -1, 0));
}
