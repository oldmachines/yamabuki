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
pub const window_resizable: u64 = 0x20;

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

extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;

const rtld_now: c_int = 2;

pub const LoadError = error{ SdlNotFound, SdlTooOld };

/// dlopen SDL3 and resolve the whole Api table. `SdlTooOld` means the
/// library was found but lacks a symbol (i.e. it is not SDL3).
pub fn load() LoadError!Api {
    const names: []const [:0]const u8 = switch (builtin.os.tag) {
        .macos => &.{ "libSDL3.dylib", "libSDL3.0.dylib" },
        else => &.{ "libSDL3.so.0", "libSDL3.so" },
    };
    var handle: ?*anyopaque = null;
    for (names) |name| {
        handle = dlopen(name, rtld_now);
        if (handle != null) break;
    }
    const h = handle orelse return error.SdlNotFound;

    var api: Api = undefined;
    inline for (@typeInfo(Api).@"struct".fields) |f| {
        const sym = dlsym(h, f.name) orelse return error.SdlTooOld;
        @field(api, f.name) = @ptrCast(@alignCast(sym));
    }
    return api;
}
