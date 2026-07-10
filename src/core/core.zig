//! Yamabuki SNES emulator core.
//!
//! Pure Zig, freestanding-friendly: no libc, no OS calls, no heap allocation
//! after construction. Frontends (headless, libretro, SDL) live outside this
//! module and drive it through `Console`.

pub const timing = @import("timing.zig");

pub const version = "0.1.0";

test {
    @import("std").testing.refAllDecls(@This());
}
