//! Baked-shader validation: parse every manifest in shaders/ and stat every
//! file it references, on the host, with no GPU.
//!
//! The shaders CI job used to assert only that each promised `preset.conf`
//! EXISTS — a bake that truncated a pass file, wrote a LUT of the wrong size,
//! or emitted a manifest the runtime cannot parse sailed through green, and
//! the failure surfaced on someone's actual graphics card. `preset.zig` is
//! deliberately GL-free and host-testable, so all of that is checkable right
//! here:
//!
//!   - every `preset.conf` parses through the same `preset.parse` the runtime
//!     uses (a manifest the emulator would refuse fails the build instead);
//!   - every `vert`/`frag` a pass names exists and is non-empty;
//!   - every LUT's `.bin` byte count equals the `w * h * 4` its manifest line
//!     claims — the exact inconsistency the runtime can only catch at load
//!     (`Error.BadLut`), on a device.
//!
//! Exit codes: 0 with every preset listed, 1 on any violation, and 0 with a
//! SKIP note when shaders/ holds no baked profiles at all (a fresh checkout —
//! the shaders CI job always runs this after `zig build shaders`, so absence
//! there cannot happen silently).

const std = @import("std");
const preset = @import("preset.zig");

const profiles = [_][]const u8{ "essl300", "glsl330", "essl100" };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var checked: u32 = 0;
    var failed: u32 = 0;

    for (profiles) |profile| {
        var path_buf: [512]u8 = undefined;
        const profile_path = try std.fmt.bufPrint(&path_buf, "shaders/{s}", .{profile});
        var dir = std.Io.Dir.cwd().openDir(io, profile_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        // Collect names first: entry.name is only valid between iterator
        // steps, and validation does its own file I/O.
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            try names.append(gpa, try gpa.dupe(u8, entry.name));
        }
        for (names.items) |name| {
            failed += try validatePreset(io, gpa, out, profile, name, &checked);
        }
    }

    if (checked == 0) {
        try out.print("shader-validate: SKIP — no baked profiles under shaders/ (run `zig build shaders` first)\n", .{});
        try out.flush();
        return;
    }
    try out.print("shader-validate: {d} presets checked, {d} failed\n", .{ checked, failed });
    try out.flush();
    if (failed != 0) std.process.exit(1);
}

fn validatePreset(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    profile: []const u8,
    name: []const u8,
    checked: *u32,
) !u32 {
    var path_buf: [512]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&path_buf, "shaders/{s}/{s}", .{ profile, name });
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return 0;
    defer dir.close(io);

    const manifest = dir.readFileAlloc(io, "preset.conf", gpa, .limited(1 << 20)) catch {
        // A preset directory without a manifest is not a preset; the runtime
        // would not list it either. Not an error.
        return 0;
    };
    checked.* += 1;

    // The same parser the runtime uses: if this refuses, the emulator would too.
    const p = preset.parse(manifest) catch |e| {
        try out.print("FAIL {s}/{s}: preset.conf does not parse: {s}\n", .{ profile, name, @errorName(e) });
        try out.flush();
        return 1;
    };

    var bad: u32 = 0;
    for (p.passes[0..p.pass_count], 0..) |*pass, i| {
        for ([_][]const u8{ pass.vert_str(), pass.frag_str() }) |file| {
            const bytes = dir.readFileAlloc(io, file, gpa, .limited(1 << 20)) catch {
                try out.print("FAIL {s}/{s}: pass {d} references missing file '{s}'\n", .{ profile, name, i, file });
                bad = 1;
                continue;
            };
            if (bytes.len == 0) {
                try out.print("FAIL {s}/{s}: pass {d} file '{s}' is empty\n", .{ profile, name, i, file });
                bad = 1;
            }
        }
    }

    for (p.luts[0..p.lut_count]) |*lut| {
        const want = @as(usize, lut.w) * @as(usize, lut.h) * 4;
        const bytes = dir.readFileAlloc(io, lut.file_str(), gpa, .limited(64 << 20)) catch {
            try out.print("FAIL {s}/{s}: missing LUT '{s}'\n", .{ profile, name, lut.file_str() });
            bad = 1;
            continue;
        };
        if (bytes.len != want) {
            try out.print(
                "FAIL {s}/{s}: LUT '{s}' is {d} bytes, manifest claims {d}x{d}x4 = {d}\n",
                .{ profile, name, lut.file_str(), bytes.len, lut.w, lut.h, want },
            );
            bad = 1;
        }
    }

    if (bad != 0) try out.flush();
    return bad;
}
