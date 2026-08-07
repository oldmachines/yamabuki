//! End-to-end gate for the FastROM patch generator: run the whole pipeline —
//! baseline profile, mechanical transform, in-emulator verification, BPS
//! encode — against a real (homebrew) ROM, then close the loop the way a
//! *user* would: apply the emitted BPS through the public patch applier and
//! check it reproduces the verified image byte for byte.
//!
//! Uses the same fetched test data as test-roms (tools/fetch_test_data.sh);
//! exits 2 when it is missing. The pinned ROM is krom's HelloWorld — LoROM-
//! era simple, SlowROM, with the stock `STZ $420D` init idiom, so the run
//! exercises free-space discovery, the reset stub, MEMSEL-store
//! neutralisation, and both verification passes.

const std = @import("std");
const core = @import("snes_core");
const util = @import("util");

const rom_path = "test-data/snes-roms/HelloWorld/HelloWorld.sfc";
/// Short on purpose: CI runs this in Debug too, and the generator's own
/// 1800-frame default is a release-binary verification standard, not a CI
/// budget. The pipeline is identical, just the window shorter.
const verify_frames = 240;
const verify_skip = 60;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const raw = std.Io.Dir.cwd().readFileAlloc(io, rom_path, gpa, .limited(16 * 1024 * 1024)) catch {
        try out.print("error: {s} missing; run tools/fetch_test_data.sh first\n", .{rom_path});
        try out.flush();
        std.process.exit(2);
    };
    const image = core.header.stripCopierHeader(raw);

    var failure: ?util.GenFailure = null;
    const res = util.generateFastromVerified(gpa, image, verify_frames, verify_skip, 0, &failure) catch |e| {
        if (e == error.GenFailed) {
            switch (failure.?) {
                .refused => |r| try out.print("FAIL: refused: {s}\n", .{r.reason.describe()}),
                .frame_mismatch => |f| try out.print("FAIL: frame {} diverged\n", .{f}),
                .memsel_lost => |f| try out.print("FAIL: MEMSEL lost at frame {}\n", .{f}),
                .audio_mismatch => try out.print("FAIL: audio diverged\n", .{}),
            }
            try out.flush();
            std.process.exit(1);
        }
        return e;
    };

    // The transform did what the generator promises.
    if (res.trampolines == 0 and res.memsel_stores_nopped == 0) {
        try out.print("FAIL: transform made no vector/MEMSEL edits — the pinned ROM no longer exercises the pipeline\n", .{});
        try out.flush();
        std.process.exit(1);
    }

    // Close the loop through the public applier, like a user would.
    var mm: core.patch.CrcMismatch = .{};
    const applied = try core.patch.apply(gpa, image, res.bps, &mm);
    if (!applied.verified) {
        try out.print("FAIL: applied patch not fully checksum-verified\n", .{});
        try out.flush();
        std.process.exit(1);
    }
    if (!std.mem.eql(u8, applied.image, res.image)) {
        try out.print("FAIL: applied image differs from the verified image\n", .{});
        try out.flush();
        std.process.exit(1);
    }
    const h = try core.header.detect(applied.image);
    if (!h.fastRom()) {
        try out.print("FAIL: patched header does not read FastROM\n", .{});
        try out.flush();
        std.process.exit(1);
    }

    // The SDL player runs the same pipeline as an incremental session on its
    // main loop; stepping it in ragged chunks must produce the identical
    // patch, or the two entry points have quietly diverged.
    {
        var session = try util.GenSession.start(gpa, image, verify_frames, verify_skip, 0);
        defer session.deinit();
        const inc: util.GenOutcome = loop: while (true) {
            switch (try session.step(7)) {
                .running => {},
                .done => |o| break :loop o,
                .failed => |f| {
                    try out.print("FAIL: incremental session failed where the one-shot passed ({s})\n", .{@tagName(f)});
                    try out.flush();
                    std.process.exit(1);
                },
            }
        };
        if (!std.mem.eql(u8, inc.bps, res.bps)) {
            try out.print("FAIL: incremental session produced a different BPS than the one-shot\n", .{});
            try out.flush();
            std.process.exit(1);
        }
    }

    try out.print(
        "patchgen-runner: PASS — {} bytes of BPS, stub at $00:{x:0>4}, {} trampoline(s), " ++
            "{} MEMSEL store(s) neutralised, {} frames verified, util {d:.0}% -> {d:.0}%, " ++
            "incremental session byte-identical\n",
        .{
            res.bps.len,                 res.stub_addr,
            res.trampolines,             res.memsel_stores_nopped,
            verify_skip + verify_frames, res.base.mean_util * 100,
            res.fast.mean_util * 100,
        },
    );
    try out.flush();
}
