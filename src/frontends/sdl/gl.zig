//! Hand-ported OpenGL ES ABI subset, resolved through SDL_GL_GetProcAddress.
//!
//! Same stance as `sdl3.zig`: a from-scratch port of the C ABI rather than a
//! binding generated from headers, so the build needs no GL headers, no
//! `libGL`/`libGLESv2` at link time, and no new dependency in `build.zig`.
//! The driver is whatever SDL already opened for the GL context.
//!
//! The entry points below are the intersection of GL ES 2.0 and GL ES 3.0 —
//! every one of them exists on both. That is deliberate: the renderer has one
//! code path, and the GLES2 fallback is not a second implementation that only
//! runs on hardware nobody tests on. The two things GLES2 genuinely lacks
//! (vertex array objects, uniform blocks) are simply not used: geometry is a
//! single quad whose attributes are re-bound per draw, and uniform blocks are
//! flattened to `vec4` arrays at bake time (see `preset.zig`).

const std = @import("std");

pub const Enum = c_uint;
pub const Uint = c_uint;
pub const Int = c_int;
pub const Sizei = c_int;
pub const Bitfield = c_uint;
pub const Float = f32;
pub const Char = u8;
pub const Intptr = isize;
pub const Sizeiptr = isize;

// Types / errors
pub const FALSE: Int = 0;
pub const TRUE: Int = 1;
pub const NO_ERROR: Enum = 0;

// Buffers
pub const ARRAY_BUFFER: Enum = 0x8892;
pub const UNIFORM_BUFFER: Enum = 0x8A11; // GLES3 / GL3.1+
pub const STATIC_DRAW: Enum = 0x88E4;
pub const DYNAMIC_DRAW: Enum = 0x88E8;
pub const INVALID_INDEX: Uint = 0xFFFF_FFFF;

// Shaders
pub const FRAGMENT_SHADER: Enum = 0x8B30;
pub const VERTEX_SHADER: Enum = 0x8B31;
pub const COMPILE_STATUS: Enum = 0x8B81;
pub const LINK_STATUS: Enum = 0x8B82;
pub const INFO_LOG_LENGTH: Enum = 0x8B84;

// Textures
pub const TEXTURE_2D: Enum = 0x0DE1;
pub const TEXTURE0: Enum = 0x84C0;
pub const TEXTURE_MAG_FILTER: Enum = 0x2800;
pub const TEXTURE_MIN_FILTER: Enum = 0x2801;
pub const TEXTURE_WRAP_S: Enum = 0x2802;
pub const TEXTURE_WRAP_T: Enum = 0x2803;
pub const NEAREST: Int = 0x2600;
pub const LINEAR: Int = 0x2601;
pub const LINEAR_MIPMAP_LINEAR: Int = 0x2703;
pub const CLAMP_TO_EDGE: Int = 0x812F;
pub const CLAMP_TO_BORDER: Int = 0x812D; // GLES3.2/desktop only; see wrapMode
pub const REPEAT: Int = 0x2901;
pub const MIRRORED_REPEAT: Int = 0x8370;

// Pixel formats
pub const RGB: Enum = 0x1907;
pub const RGBA: Enum = 0x1908;
pub const RGBA8: Enum = 0x8058;
pub const RGBA16F: Enum = 0x881A;
pub const SRGB8_ALPHA8: Enum = 0x8C43;
pub const UNSIGNED_BYTE: Enum = 0x1401;
pub const UNSIGNED_SHORT_5_6_5: Enum = 0x8363;
pub const HALF_FLOAT: Enum = 0x140B;
pub const FLOAT: Enum = 0x1406;
pub const UNPACK_ALIGNMENT: Enum = 0x0CF5;
pub const PACK_ALIGNMENT: Enum = 0x0D05;

// Framebuffers
pub const FRAMEBUFFER: Enum = 0x8D40;
pub const COLOR_ATTACHMENT0: Enum = 0x8CE0;
pub const FRAMEBUFFER_COMPLETE: Enum = 0x8CD5;

// State
pub const COLOR_BUFFER_BIT: Bitfield = 0x4000;
pub const TRIANGLE_STRIP: Enum = 0x0005;
pub const BLEND: Enum = 0x0BE2;
pub const DEPTH_TEST: Enum = 0x0B71;
pub const CULL_FACE: Enum = 0x0B44;
pub const VERSION: Enum = 0x1F02;

/// Every GL entry point the shader pipeline calls. Field names are the symbol
/// names — the loader resolves them by reflection, exactly like `sdl3.Api`.
pub const Api = struct {
    glGetString: *const fn (name: Enum) callconv(.c) ?[*:0]const u8,
    glGetError: *const fn () callconv(.c) Enum,
    glViewport: *const fn (x: Int, y: Int, w: Sizei, h: Sizei) callconv(.c) void,
    glClearColor: *const fn (r: Float, g: Float, b: Float, a: Float) callconv(.c) void,
    glClear: *const fn (mask: Bitfield) callconv(.c) void,
    glDisable: *const fn (cap: Enum) callconv(.c) void,
    glDrawArrays: *const fn (mode: Enum, first: Int, count: Sizei) callconv(.c) void,
    glPixelStorei: *const fn (pname: Enum, param: Int) callconv(.c) void,
    glReadPixels: *const fn (x: Int, y: Int, w: Sizei, h: Sizei, format: Enum, kind: Enum, pixels: *anyopaque) callconv(.c) void,
    glFinish: *const fn () callconv(.c) void,

    glCreateShader: *const fn (kind: Enum) callconv(.c) Uint,
    glShaderSource: *const fn (s: Uint, count: Sizei, strings: [*]const [*]const Char, lengths: ?[*]const Int) callconv(.c) void,
    glCompileShader: *const fn (s: Uint) callconv(.c) void,
    glGetShaderiv: *const fn (s: Uint, pname: Enum, params: *Int) callconv(.c) void,
    glGetShaderInfoLog: *const fn (s: Uint, max: Sizei, len: ?*Sizei, log: [*]Char) callconv(.c) void,
    glDeleteShader: *const fn (s: Uint) callconv(.c) void,

    glCreateProgram: *const fn () callconv(.c) Uint,
    glAttachShader: *const fn (p: Uint, s: Uint) callconv(.c) void,
    glLinkProgram: *const fn (p: Uint) callconv(.c) void,
    glGetProgramiv: *const fn (p: Uint, pname: Enum, params: *Int) callconv(.c) void,
    glGetProgramInfoLog: *const fn (p: Uint, max: Sizei, len: ?*Sizei, log: [*]Char) callconv(.c) void,
    glUseProgram: *const fn (p: Uint) callconv(.c) void,
    glDeleteProgram: *const fn (p: Uint) callconv(.c) void,

    glGetAttribLocation: *const fn (p: Uint, name: [*:0]const Char) callconv(.c) Int,
    glGetUniformLocation: *const fn (p: Uint, name: [*:0]const Char) callconv(.c) Int,
    glUniform1i: *const fn (loc: Int, v: Int) callconv(.c) void,
    glUniform1f: *const fn (loc: Int, v: Float) callconv(.c) void,
    glUniform2fv: *const fn (loc: Int, count: Sizei, v: [*]const Float) callconv(.c) void,
    glUniform4fv: *const fn (loc: Int, count: Sizei, v: [*]const Float) callconv(.c) void,
    glUniformMatrix4fv: *const fn (loc: Int, count: Sizei, transpose: u8, v: [*]const Float) callconv(.c) void,

    // --- GLES3 / GL3.1+ only ------------------------------------------------
    // These do not exist on GLES2. They are optional so that resolving the
    // table on a Mali-400 still succeeds — the ESSL 100 shaders the baker emits
    // for such a device use plain uniforms and never touch a uniform buffer, so
    // a null here costs nothing.
    glBufferSubData: ?*const fn (target: Enum, offset: Intptr, size: Sizeiptr, data: ?*const anyopaque) callconv(.c) void,
    glBindBufferBase: ?*const fn (target: Enum, index: Uint, buf: Uint) callconv(.c) void,
    glGetUniformBlockIndex: ?*const fn (p: Uint, name: [*:0]const Char) callconv(.c) Uint,
    glUniformBlockBinding: ?*const fn (p: Uint, block: Uint, binding: Uint) callconv(.c) void,
    glUniform1ui: ?*const fn (loc: Int, v: Uint) callconv(.c) void,

    glGenBuffers: *const fn (n: Sizei, out: [*]Uint) callconv(.c) void,
    glBindBuffer: *const fn (target: Enum, buf: Uint) callconv(.c) void,
    glBufferData: *const fn (target: Enum, size: Sizeiptr, data: ?*const anyopaque, usage: Enum) callconv(.c) void,
    glDeleteBuffers: *const fn (n: Sizei, bufs: [*]const Uint) callconv(.c) void,
    glVertexAttribPointer: *const fn (idx: Uint, size: Int, kind: Enum, norm: u8, stride: Sizei, ptr: ?*const anyopaque) callconv(.c) void,
    glEnableVertexAttribArray: *const fn (idx: Uint) callconv(.c) void,

    glGenTextures: *const fn (n: Sizei, out: [*]Uint) callconv(.c) void,
    glBindTexture: *const fn (target: Enum, tex: Uint) callconv(.c) void,
    glActiveTexture: *const fn (unit: Enum) callconv(.c) void,
    glTexImage2D: *const fn (target: Enum, level: Int, internal: Int, w: Sizei, h: Sizei, border: Int, format: Enum, kind: Enum, pixels: ?*const anyopaque) callconv(.c) void,
    glTexSubImage2D: *const fn (target: Enum, level: Int, x: Int, y: Int, w: Sizei, h: Sizei, format: Enum, kind: Enum, pixels: ?*const anyopaque) callconv(.c) void,
    glTexParameteri: *const fn (target: Enum, pname: Enum, param: Int) callconv(.c) void,
    glGenerateMipmap: *const fn (target: Enum) callconv(.c) void,
    glDeleteTextures: *const fn (n: Sizei, tex: [*]const Uint) callconv(.c) void,

    glGenFramebuffers: *const fn (n: Sizei, out: [*]Uint) callconv(.c) void,
    glBindFramebuffer: *const fn (target: Enum, fb: Uint) callconv(.c) void,
    glFramebufferTexture2D: *const fn (target: Enum, attach: Enum, textarget: Enum, tex: Uint, level: Int) callconv(.c) void,
    glCheckFramebufferStatus: *const fn (target: Enum) callconv(.c) Enum,
    glDeleteFramebuffers: *const fn (n: Sizei, fbs: [*]const Uint) callconv(.c) void,
};

pub const LoadError = error{MissingSymbol};

/// Resolve the whole table through SDL's proc-address lookup. A missing symbol
/// means the context is not a usable GLES2-or-better context, which the caller
/// reports as "no shader support" and falls back to the software blit — it is
/// never a crash.
pub fn load(getProcAddress: *const fn (name: [*:0]const u8) callconv(.c) ?*anyopaque) LoadError!Api {
    var api: Api = undefined;
    inline for (@typeInfo(Api).@"struct".fields) |f| {
        const optional = @typeInfo(f.type) == .optional;
        if (getProcAddress(f.name ++ "")) |sym| {
            @field(api, f.name) = @ptrCast(@alignCast(sym));
        } else if (optional) {
            // GLES2: the uniform-buffer entry points are simply absent.
            @field(api, f.name) = null;
        } else {
            return error.MissingSymbol;
        }
    }
    return api;
}

/// The GL ES major version, parsed from GL_VERSION.
///
/// GLES reports "OpenGL ES 3.0 <driver>"; desktop GL reports "4.6.0 <driver>".
/// Desktop GL 3.3+ has everything GLES3 does for our purposes, so it maps to 3.
pub fn majorVersion(version_string: []const u8) u32 {
    const es_prefix = "OpenGL ES ";
    if (std.mem.startsWith(u8, version_string, es_prefix)) {
        const rest = version_string[es_prefix.len..];
        return firstInt(rest);
    }
    // Desktop GL: 3.3 and up covers the GLES3 feature set we need.
    const major = firstInt(version_string);
    return if (major >= 3) 3 else 2;
}

fn firstInt(s: []const u8) u32 {
    var n: u32 = 0;
    var seen = false;
    for (s) |c| {
        if (c >= '0' and c <= '9') {
            n = n * 10 + (c - '0');
            seen = true;
        } else if (seen) break;
    }
    return n;
}

/// GLES2 has no CLAMP_TO_BORDER. Shaders that ask for it get CLAMP_TO_EDGE,
/// which is the closest legal mode; the difference shows only in the outermost
/// texel of a pass that samples outside its own bounds.
pub fn wrapMode(wrap: @import("preset.zig").Wrap, gles_major: u32) Int {
    return switch (wrap) {
        .clamp_to_edge => CLAMP_TO_EDGE,
        .clamp_to_border => if (gles_major >= 3) CLAMP_TO_BORDER else CLAMP_TO_EDGE,
        .repeat => REPEAT,
        .mirrored_repeat => MIRRORED_REPEAT,
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "majorVersion: GLES strings" {
    try testing.expectEqual(@as(u32, 3), majorVersion("OpenGL ES 3.2 Mesa 23.0"));
    try testing.expectEqual(@as(u32, 3), majorVersion("OpenGL ES 3.0 Mali-G31"));
    try testing.expectEqual(@as(u32, 2), majorVersion("OpenGL ES 2.0 Mali-400 MP2"));
}

test "majorVersion: desktop GL maps 3.3+ onto the GLES3 feature set" {
    try testing.expectEqual(@as(u32, 3), majorVersion("4.6.0 NVIDIA 550.54"));
    try testing.expectEqual(@as(u32, 3), majorVersion("3.3.0 Core Profile"));
    try testing.expectEqual(@as(u32, 2), majorVersion("2.1 Metal - 89"));
}

test "wrapMode: clamp_to_border degrades on GLES2 rather than passing an illegal enum" {
    const P = @import("preset.zig");
    try testing.expectEqual(CLAMP_TO_BORDER, wrapMode(P.Wrap.clamp_to_border, 3));
    try testing.expectEqual(CLAMP_TO_EDGE, wrapMode(P.Wrap.clamp_to_border, 2));
    try testing.expectEqual(REPEAT, wrapMode(P.Wrap.repeat, 2));
}
