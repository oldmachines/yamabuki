//! ROM runner: boot each golden ROM headless for a fixed number of frames and
//! compare against the committed baseline in `golden_hashes.zon` — the
//! framebuffer hash (correctness) plus the deterministic `steps`/`cycles` work
//! counts (perf regression; gated only once baselined, 0 = unset). Requires the
//! PeterLemon ROMs under test-data/snes-roms (tools/fetch_test_data.sh).
//!
//! Options (see build.zig): -Drom-filter=<substr>  -Drom-frames=<n>
//! -Drom-accurate runs the suite on the accurate core: hashes must still
//! match (a line nothing races renders identically), but steps/cycles are
//! reported unGated — dot-placed IRQs legitimately reorder instruction
//! interleaving on IRQ-driven ROMs.

const std = @import("std");
const core = @import("snes_core");
const options = @import("rom_options");
const util = @import("util");

/// One golden ROM. Optional gates default to 0 = "not baselined, ungated";
/// `frames` 0 means the suite default applies. `audio` is the FNV-1a of the
/// whole 32 kHz stereo stream over the run (phase-sensitive by design).
const Entry = struct {
    path: []const u8,
    hash: u64,
    steps: u64 = 0,
    cycles: u64 = 0,
    frames: u32 = 0,
    audio: u64 = 0,
    /// Expected hash on the accurate core when it legitimately differs from
    /// the fast core (mid-scanline races, e.g. a VRAM refresh DMA overrunning
    /// into active display). 0 = same image on both cores.
    hash_accurate: u64 = 0,
    /// Pad-1 buttons held for the whole run (core.joypad.Button bits). The
    /// input-driven entries exist because a neutral pad exercises none of the
    /// input plumbing — RotZoom rotates under R, so its held-R golden fails if
    /// input ever stops reaching the machine.
    buttons: u16 = 0,
};

const Golden = struct {
    frames: u32,
    roms: []const Entry,
};

const golden: Golden = @import("golden_hashes.zon");
const rom_root = "test-data/snes-roms";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var dir = std.Io.Dir.cwd().openDir(io, rom_root, .{}) catch {
        try out.print("error: {s} missing; run tools/fetch_test_data.sh first\n", .{rom_root});
        try out.flush();
        std.process.exit(2);
    };
    defer dir.close(io);

    const frames: u32 = if (options.frames != 0) options.frames else golden.frames;
    var run: u32 = 0;
    var failed: u32 = 0;

    for (golden.roms) |entry| {
        const skip = if (options.filter) |f|
            std.mem.indexOf(u8, entry.path, f) == null
        else
            false;
        if (!skip) {
            run += 1;
            // A per-ROM `.frames` overrides the suite default (SPC700 test
            // ROMs need time to hand results back from the audio CPU).
            const entry_frames: u32 = if (entry.frames != 0) entry.frames else frames;
            const ok = runOne(io, gpa, out, dir, entry, entry_frames) catch |e| blk: {
                try out.print("ERROR {s}: {s}\n", .{ entry.path, @errorName(e) });
                break :blk false;
            };
            if (!ok) failed += 1;
        }
    }

    try out.print("\nrom-runner: {} ROMs, {} failed ({} frames default)\n", .{ run, failed, frames });
    try out.flush();
    if (failed > 0) std.process.exit(1);
}

fn runOne(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    dir: std.Io.Dir,
    entry: Entry,
    frames: u32,
) !bool {
    // The arena frees everything at process exit; the console owns the cart
    // (its page table points into cart.rom), so we must not free it here.
    const image = try dir.readFileAlloc(io, entry.path, gpa, .limited(16 * 1024 * 1024));
    const cart = try core.Cartridge.load(gpa, image);
    const con = try gpa.create(core.AnyConsole);
    con.init(if (options.accurate) .accurate else .fast, cart);

    // The audio ring holds ~15 video frames, so drain and hash every frame.
    // Halfway through, snapshot the whole machine: after the run finishes,
    // the state is restored and the second half replayed — the golden hash
    // must come out twice. A serialization bug in any component (PPU, APU,
    // DMA, a coprocessor) diverges the replay, so every golden ROM now gates
    // save/load, not just the fuzz harness's synthetic cart.
    const half = frames / 2;
    const state = try gpa.alloc(u8, core.AnyConsole.state_size);
    var got_audio = core.console.audio_hash_init;
    for (0..frames) |i| {
        if (i == half) _ = con.saveState(state);
        con.setButtons(0, entry.buttons);
        con.runFrame();
        try util.drainAudio(con, &got_audio, {}, null);
    }

    const got_hash = core.console.hashFrame(con.framebuffer());
    const got_steps = switch (con.*) {
        inline else => |*c| c.steps,
    };
    const got_cycles = switch (con.*) {
        inline else => |*c| c.bus.clock,
    };

    // Replay the second half from the snapshot; audio is drained (the ring is
    // finite) but not hashed — the golden audio hash covers the first pass.
    try con.loadState(state);
    for (half..frames) |_| {
        con.setButtons(0, entry.buttons);
        con.runFrame();
        util.drainAudioDiscard(con);
    }
    const replay_hash = core.console.hashFrame(con.framebuffer());
    const roundtrip_ok = replay_hash == got_hash;

    // Deterministic perf counts are gated only once baselined (0 = unset)
    // and only on the fast core (the accurate core's IRQ dot placement
    // shifts instruction interleaving on IRQ-driven ROMs).
    const steps_ok = options.accurate or entry.steps == 0 or entry.steps == got_steps;
    const cycles_ok = options.accurate or entry.cycles == 0 or entry.cycles == got_cycles;
    const audio_ok = entry.audio == 0 or entry.audio == got_audio;
    const want_hash = if (options.accurate and entry.hash_accurate != 0) entry.hash_accurate else entry.hash;
    const ok = got_hash == want_hash and steps_ok and cycles_ok and audio_ok and roundtrip_ok;

    try out.print("{s} {s}\n    hash   got {x:0>16} want {x:0>16}\n    steps  got {d:<10} want {d}\n    cycles got {d:<10} want {d}\n    audio  got {x:0>16} want {x:0>16}\n", .{
        if (ok) "PASS" else "FAIL", entry.path,
        got_hash,                   want_hash,
        got_steps,                  entry.steps,
        got_cycles,                 entry.cycles,
        got_audio,                  entry.audio,
    });
    if (!roundtrip_ok) {
        try out.print("    ROUNDTRIP DIVERGED: replay from the frame-{d} snapshot ended at {x:0>16}\n", .{ half, replay_hash });
    }
    return ok;
}
