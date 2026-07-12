//! Hand-ported SDL3 ABI subset, loaded at runtime with dlopen.
//!
//! Like the libretro frontend's `api.zig`, this is a from-scratch port of the
//! stable C ABI (verified against the SDL 3.2 headers), not a binding
//! generated from them — the build needs no SDL headers or import library.
//! Because the library is dlopen'd, `zig build` produces a working
//! `yamabuki-sdl` on machines without SDL installed; it only needs
//! `libSDL3.so.0` (or `libSDL3.dylib`) at runtime, and reports a friendly
//! error when the library is missing. SDL3's ABI is stable across 3.x and
//! everything used here exists since 3.2.0.

const std = @import("std");
const builtin = @import("builtin");

pub const Window = opaque {};
pub const Renderer = opaque {};
pub const Texture = opaque {};
pub const AudioStream = opaque {};
pub const GlContext = opaque {};

pub const AudioSpec = extern struct {
    format: c_uint,
    channels: c_int,
    freq: c_int,
};

pub const Rect = extern struct { x: c_int, y: c_int, w: c_int, h: c_int };
pub const FRect = extern struct { x: f32, y: f32, w: f32, h: f32 };

/// SDL_KeyboardEvent (SDL_events.h); `down`/`repeat` are C bools (1 byte).
pub const KeyboardEvent = extern struct {
    type: u32,
    reserved: u32,
    timestamp: u64,
    window_id: u32,
    which: u32,
    scancode: u32,
    key: u32,
    mod: u16,
    raw: u16,
    down: bool,
    repeat: bool,
};

/// SDL_Event: a 128-byte union; only the members we read are typed.
pub const Event = extern union {
    type: u32,
    key: KeyboardEvent,
    padding: [128]u8 align(8),
};

// SDL_init.h
pub const init_audio: u32 = 0x10;
pub const init_video: u32 = 0x20;

// SDL_video.h
pub const window_opengl: u64 = 0x02;
pub const window_resizable: u64 = 0x20;

/// SDL_GLAttr (SDL_video.h) — only the attributes the GL path sets.
pub const gl_attr = struct {
    pub const doublebuffer: c_int = 5;
    pub const depth_size: c_int = 6;
    pub const stencil_size: c_int = 7;
    pub const context_major_version: c_int = 17;
    pub const context_minor_version: c_int = 18;
    pub const context_profile_mask: c_int = 20;
};

/// SDL_GLProfile.
pub const gl_profile_core: c_int = 0x0001;
pub const gl_profile_es: c_int = 0x0004;

// SDL_pixels.h
pub const pixel_format_rgb565: c_uint = 0x15151002;

// SDL_render.h / SDL_surface.h
pub const texture_access_streaming: c_uint = 1;
pub const scale_mode_nearest: c_int = 0;
pub const logical_presentation_letterbox: c_uint = 2;

// SDL_audio.h
pub const audio_s16le: c_uint = 0x8010;
pub const audio_device_default_playback: u32 = 0xFFFF_FFFF;

// SDL_events.h
pub const event_quit: u32 = 0x100;
pub const event_key_down: u32 = 0x300;
pub const event_key_up: u32 = 0x301;

/// SDL_scancode.h (USB HID usage values; stable).
pub const scancode = struct {
    pub const a: u32 = 4;
    pub const q: u32 = 20;
    pub const s: u32 = 22;
    pub const w: u32 = 26;
    pub const x: u32 = 27;
    pub const z: u32 = 29;
    pub const ret: u32 = 40;
    pub const comma: u32 = 54;
    pub const period: u32 = 55;
    pub const escape: u32 = 41;
    pub const tab: u32 = 43;
    pub const f1: u32 = 58;
    pub const f5: u32 = 62;
    pub const f9: u32 = 66;
    pub const right: u32 = 79;
    pub const left: u32 = 80;
    pub const down: u32 = 81;
    pub const up: u32 = 82;
    pub const rshift: u32 = 229;
};

/// Every SDL entry point the frontend calls, resolved by symbol name — the
/// field names ARE the dlsym lookup keys.
pub const Api = struct {
    SDL_Init: *const fn (flags: u32) callconv(.c) bool,
    SDL_Quit: *const fn () callconv(.c) void,
    SDL_GetError: *const fn () callconv(.c) [*:0]const u8,

    SDL_CreateWindow: *const fn (title: [*:0]const u8, w: c_int, h: c_int, flags: u64) callconv(.c) ?*Window,
    SDL_DestroyWindow: *const fn (win: *Window) callconv(.c) void,

    SDL_CreateRenderer: *const fn (win: *Window, name: ?[*:0]const u8) callconv(.c) ?*Renderer,
    SDL_DestroyRenderer: *const fn (r: *Renderer) callconv(.c) void,
    SDL_SetRenderVSync: *const fn (r: *Renderer, vsync: c_int) callconv(.c) bool,
    SDL_SetRenderLogicalPresentation: *const fn (r: *Renderer, w: c_int, h: c_int, mode: c_uint) callconv(.c) bool,
    SDL_RenderClear: *const fn (r: *Renderer) callconv(.c) bool,
    SDL_RenderTexture: *const fn (r: *Renderer, t: *Texture, src: ?*const FRect, dst: ?*const FRect) callconv(.c) bool,
    SDL_RenderPresent: *const fn (r: *Renderer) callconv(.c) bool,

    SDL_CreateTexture: *const fn (r: *Renderer, format: c_uint, access: c_uint, w: c_int, h: c_int) callconv(.c) ?*Texture,
    SDL_DestroyTexture: *const fn (t: *Texture) callconv(.c) void,
    SDL_UpdateTexture: *const fn (t: *Texture, rect: ?*const Rect, pixels: *const anyopaque, pitch: c_int) callconv(.c) bool,
    SDL_SetTextureScaleMode: *const fn (t: *Texture, mode: c_int) callconv(.c) bool,

    SDL_PollEvent: *const fn (ev: *Event) callconv(.c) bool,

    SDL_OpenAudioDeviceStream: *const fn (devid: u32, spec: ?*const AudioSpec, cb: ?*const anyopaque, userdata: ?*anyopaque) callconv(.c) ?*AudioStream,
    SDL_PutAudioStreamData: *const fn (s: *AudioStream, buf: *const anyopaque, len: c_int) callconv(.c) bool,
    SDL_GetAudioStreamQueued: *const fn (s: *AudioStream) callconv(.c) c_int,
    SDL_ResumeAudioStreamDevice: *const fn (s: *AudioStream) callconv(.c) bool,
    SDL_DestroyAudioStream: *const fn (s: *AudioStream) callconv(.c) void,

    SDL_GetTicksNS: *const fn () callconv(.c) u64,
    SDL_DelayNS: *const fn (ns: u64) callconv(.c) void,
};

/// The GL entry points, resolved separately from `Api` and on demand.
///
/// Keeping these out of the required table matters: a build of SDL3 without a
/// GL driver, or one where a symbol was renamed, must cost the user shaders —
/// not the emulator. `loadGl` failing is a fallback, `load` failing is fatal.
pub const GlApi = struct {
    SDL_GL_SetAttribute: *const fn (attr: c_int, value: c_int) callconv(.c) bool,
    SDL_GL_CreateContext: *const fn (win: *Window) callconv(.c) ?*GlContext,
    SDL_GL_DestroyContext: *const fn (ctx: *GlContext) callconv(.c) bool,
    SDL_GL_MakeCurrent: *const fn (win: *Window, ctx: *GlContext) callconv(.c) bool,
    SDL_GL_GetProcAddress: *const fn (name: [*:0]const u8) callconv(.c) ?*anyopaque,
    SDL_GL_SwapWindow: *const fn (win: *Window) callconv(.c) bool,
    SDL_GL_SetSwapInterval: *const fn (interval: c_int) callconv(.c) bool,
    SDL_GetWindowSizeInPixels: *const fn (win: *Window, w: *c_int, h: *c_int) callconv(.c) bool,
};

// The library is opened by name at runtime on every platform — POSIX through
// dlopen, Windows through LoadLibrary. Same stance either way: nothing is
// linked, so the build needs no SDL present and the binary reports a friendly
// error when the runtime is missing.
extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;

const rtld_now: c_int = 2;

const is_windows = builtin.os.tag == .windows;

pub const LoadError = error{ SdlNotFound, SdlTooOld };

fn open() LoadError!*anyopaque {
    const names: []const [:0]const u8 = switch (builtin.os.tag) {
        .windows => &.{"SDL3.dll"},
        .macos => &.{ "libSDL3.dylib", "libSDL3.0.dylib" },
        else => &.{ "libSDL3.so.0", "libSDL3.so" },
    };
    for (names) |name| {
        // Both loaders are refcounted and hand back the same handle for the
        // same library, so calling this again from loadGl is free.
        const h = if (is_windows) LoadLibraryA(name) else dlopen(name, rtld_now);
        if (h) |handle| return handle;
    }
    return error.SdlNotFound;
}

fn symbol(h: *anyopaque, name: [*:0]const u8) ?*anyopaque {
    return if (is_windows) GetProcAddress(h, name) else dlsym(h, name);
}

fn resolve(comptime T: type, h: *anyopaque) LoadError!T {
    var api: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const sym = symbol(h, f.name) orelse return error.SdlTooOld;
        @field(api, f.name) = @ptrCast(@alignCast(sym));
    }
    return api;
}

/// dlopen SDL3 and resolve the whole Api table. `SdlTooOld` means the
/// library was found but lacks a symbol (i.e. it is not SDL3).
pub fn load() LoadError!Api {
    return resolve(Api, try open());
}

/// Resolve the GL entry points. Callers treat any error as "no shader support".
pub fn loadGl() LoadError!GlApi {
    return resolve(GlApi, try open());
}
