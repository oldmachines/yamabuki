//! Where per-user data lives: the config file today; saves, states,
//! screenshots, and the library index as M14 progresses.
//!
//! Everything is rooted at `SDL_GetPrefPath("yamabuki", "yamabuki")` —
//! `%APPDATA%\yamabuki\yamabuki\` on Windows,
//! `~/.local/share/yamabuki/yamabuki/` on Linux,
//! `~/Library/Application Support/yamabuki/yamabuki/` on macOS — so the data
//! follows the user, not the ROM directory or the working directory. SDL
//! creates the directory when it resolves the path.
//!
//! A machine where the path cannot be resolved (the optional symbols are
//! missing, or the OS refuses) loses persistence, not the emulator: callers
//! treat a null `Paths` as "run without".

const std = @import("std");
const sdl3 = @import("sdl3.zig");

pub const Paths = struct {
    /// The pref-path root. SDL guarantees a trailing path separator, so
    /// children are formed by plain concatenation.
    root: []const u8,
    /// `<root>config.zon`.
    config: []const u8,

    /// Resolve the per-user data directory. Requires the SDL3 runtime `load`
    /// already found — the extra symbols come from the same library.
    pub fn init(gpa: std.mem.Allocator) ?Paths {
        const ext = sdl3.loadExt() catch return null;
        const raw = ext.SDL_GetPrefPath("yamabuki", "yamabuki") orelse return null;
        defer ext.SDL_free(raw);
        const root = gpa.dupe(u8, std.mem.span(raw)) catch return null;
        const config = std.fmt.allocPrint(gpa, "{s}config.zon", .{root}) catch return null;
        return .{ .root = root, .config = config };
    }
};
