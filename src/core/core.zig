//! Yamabuki SNES emulator core.
//!
//! Pure Zig, freestanding-friendly: no libc, no OS calls, no heap allocation
//! after construction. Frontends (headless, libretro, SDL) live outside this
//! module and drive it through `Console`.

pub const timing = @import("timing.zig");
pub const serialize = @import("serialize.zig");
pub const header = @import("cart/header.zig");
pub const cartridge = @import("cart/cartridge.zig");
pub const bus = @import("memory/bus.zig");
pub const wram = @import("memory/wram.zig");
pub const math_unit = @import("memory/math_unit.zig");
pub const joypad = @import("memory/joypad.zig");
pub const dma = @import("memory/dma.zig");
pub const mappers = @import("memory/mappers.zig");
pub const wdc65816 = @import("cpu/wdc65816.zig");
pub const cpu_ops = @import("cpu/ops.zig");
pub const spc700 = @import("apu/spc700.zig");
pub const spc700_ops = @import("apu/ops.zig");
pub const dsp = @import("apu/dsp.zig");
pub const apu = @import("apu/apu.zig");
pub const cpu_io = @import("memory/cpu_io.zig");
pub const ppu = @import("ppu/ppu.zig");
pub const line_render = @import("ppu/line_render.zig");
pub const gsu = @import("chips/gsu.zig");
pub const console = @import("console.zig");

pub const Cartridge = cartridge.Cartridge;
pub const Bus = bus.Bus;
pub const Console = console.Console;
pub const FastConsole = console.FastConsole;
pub const AccurateConsole = console.AccurateConsole;
pub const AnyConsole = console.AnyConsole;
pub const Accuracy = console.Accuracy;

pub const version = "0.1.0";

test {
    @import("std").testing.refAllDecls(@This());
}
