//! Headless frontend: loads a ROM, runs N frames, dumps the framebuffer as
//! a .ppm image and prints an FNV-1a hash of it. Primary development and
//! CI verification tool — no display, no audio device, no dependencies.

const std = @import("std");
const core = @import("snes_core");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    try out.print("yamabuki {s} (core skeleton — ROM execution lands in M3)\n", .{core.version});
    try out.flush();
}
