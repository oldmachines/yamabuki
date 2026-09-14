//! Frame pacing: the region's frame period and the sleep-to-deadline step with its stall resync.
//!
//! Carved out of app.zig as pure code motion; every declaration
//! here is re-exported from app.zig, which stays the root.

const core = @import("snes_core");
const sdl3 = @import("../sdl3.zig");
const app_root = @import("../app.zig");

/// Frame duration for the loaded cart's region: 262 lines at 21.477 MHz
/// (NTSC, ~60.0988 Hz) or 312 lines at 21.281 MHz (PAL, 50 Hz).
pub fn frameNs(region: core.timing.Region) u64 {
    return switch (region) {
        .ntsc => core.timing.cycles_per_line * core.timing.ntsc_lines_per_frame *
            1_000_000_000 / core.timing.ntsc_master_hz,
        .pal => core.timing.cycles_per_line * core.timing.pal_lines_per_frame *
            1_000_000_000 / core.timing.pal_master_hz,
    };
}

/// Sleep to the next frame boundary and return the following one.
///
/// The clock is read again AFTER the sleep: the catch-up test has to see
/// where the frame actually ended, not where it began. The earlier form
/// compared the pre-sleep time against an already-advanced deadline, which
/// could never be more than a frame behind, so a real stall (a paused
/// window, a long disk write) was followed by a burst of frames run
/// back-to-back until the deadline caught up on its own.
pub fn paceFrame(now_before: u64, deadline: u64, frame_ns: u64, max_lag_ns: u64, sdl: *const sdl3.Api) u64 {
    if (now_before < deadline) sdl.SDL_DelayNS(deadline - now_before);
    const now = sdl.SDL_GetTicksNS();
    const next = deadline + frame_ns;
    // Fell more than `max_lag_ns` behind: resync rather than sprint.
    if (now > next + max_lag_ns) return now + frame_ns;
    return next;
}
