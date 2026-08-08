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
const wgdemo = @import("wgdemo");

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
    const res = util.generateFastromVerified(gpa, image, verify_frames, verify_skip, 0, null, &failure) catch |e| {
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

    // Stage S3 shell: the same ROM converted to an SA-1 cart (empty plan, so
    // shell only — the SA-1 boots and parks) must render and sound identical.
    {
        var refusal: ?core.sa1gen.Refusal = null;
        const empty: core.profile.Plan = .{};
        const sa1 = try core.sa1gen.convert(gpa, image, &empty, null, &.{}, &refusal);
        const cart2 = try core.Cartridge.load(gpa, sa1.image);
        if (cart2.chip != .sa1) {
            try out.print("FAIL: converted cart did not identify as SA-1\n", .{});
            try out.flush();
            std.process.exit(1);
        }
        const orig_cart = try core.Cartridge.load(gpa, image);
        const con_a = try gpa.create(core.FastConsole);
        con_a.init(orig_cart);
        const con_b = try gpa.create(core.FastConsole);
        con_b.init(cart2);
        var audio_a = core.console.audio_hash_init;
        var audio_b = core.console.audio_hash_init;
        for (0..verify_frames) |i| {
            con_a.runFrame();
            con_b.runFrame();
            try util.drainAudio(con_a, &audio_a, {}, null);
            try util.drainAudio(con_b, &audio_b, {}, null);
            const ha = core.console.hashFrame(con_a.framebuffer());
            const hb = core.console.hashFrame(con_b.framebuffer());
            if (ha != hb) {
                try out.print("FAIL: SA-1 shell diverged at frame {}\n", .{i});
                try out.flush();
                std.process.exit(1);
            }
        }
        if (audio_a != audio_b) {
            try out.print("FAIL: SA-1 shell audio diverged\n", .{});
            try out.flush();
            std.process.exit(1);
        }
    }

    // Whole-game migration end-to-end on the demo game `zig build wg-demo`
    // ships: profile the original for the S1 coverage map, migrate the
    // entire game onto the SA-1, and hold it to the strict S4 tier — the
    // demo animates (a distinct backdrop color every frame), yet every
    // frame and the audio stream must be identical, because all its PPU
    // writes are NMI-aligned and the mailbox costs microseconds against a
    // ~1.1 ms vblank. Then close the loop through the public applier.
    var wg_sites: u32 = 0;
    {
        const demo = try wgdemo.buildRom(gpa);
        const usage = try gpa.alloc(u8, core.usage_map.cpu_map_len);
        @memset(usage, 0);
        const umap: core.usage_map.UsageMap = .{ .bytes = usage };
        const wg_frames = 180;
        const base_hashes = try gpa.alloc(u64, wg_frames);
        var base_audio = core.console.audio_hash_init;
        {
            const cart = try core.Cartridge.load(gpa, demo);
            const con = try gpa.create(core.ProfilingConsole);
            con.init(cart);
            con.usage = &umap;
            for (0..wg_frames) |i| {
                con.runFrame();
                try util.drainAudio(con, &base_audio, {}, null);
                base_hashes[i] = core.console.hashFrame(con.framebuffer());
            }
        }
        var distinct: usize = 1;
        for (base_hashes[1..], base_hashes[0 .. wg_frames - 1]) |cur_h, prev_h| {
            if (cur_h != prev_h) distinct += 1;
        }
        if (distinct < wg_frames / 2) {
            try out.print("FAIL: the wg demo stopped animating ({} distinct frames of {}) — it no longer exercises the gate\n", .{ distinct, wg_frames });
            try out.flush();
            std.process.exit(1);
        }

        var refusal: ?core.sa1gen.Refusal = null;
        const wg_res = core.sa1gen.convertWholeGame(gpa, demo, usage, &refusal) catch |e| {
            if (e == error.Refused) {
                try out.print("FAIL: whole-game migration refused the demo: {s}\n", .{refusal.?.reason.describe()});
                try out.flush();
                std.process.exit(1);
            }
            return e;
        };
        wg_sites = wg_res.stats.offload_sites;

        var conv_audio = core.console.audio_hash_init;
        {
            const cart = try core.Cartridge.load(gpa, wg_res.image);
            if (cart.chip != .sa1) {
                try out.print("FAIL: whole-game cart did not identify as SA-1\n", .{});
                try out.flush();
                std.process.exit(1);
            }
            const con = try gpa.create(core.FastConsole);
            con.init(cart);
            for (0..wg_frames) |i| {
                con.runFrame();
                try util.drainAudio(con, &conv_audio, {}, null);
                if (core.console.hashFrame(con.framebuffer()) != base_hashes[i]) {
                    try out.print("FAIL: whole-game demo diverged at frame {}\n", .{i});
                    try out.flush();
                    std.process.exit(1);
                }
            }
        }
        if (conv_audio != base_audio) {
            try out.print("FAIL: whole-game demo audio diverged\n", .{});
            try out.flush();
            std.process.exit(1);
        }

        const wg_bps = try core.patch.writeBps(gpa, demo, wg_res.image);
        var wg_mm: core.patch.CrcMismatch = .{};
        const wg_applied = try core.patch.apply(gpa, demo, wg_bps, &wg_mm);
        if (!wg_applied.verified or !std.mem.eql(u8, wg_applied.image, wg_res.image)) {
            try out.print("FAIL: whole-game BPS did not reproduce the verified image\n", .{});
            try out.flush();
            std.process.exit(1);
        }
    }

    try out.print(
        "patchgen-runner: PASS — {} bytes of BPS, stub at $00:{x:0>4}, {} trampoline(s), " ++
            "{} MEMSEL store(s) neutralised, {} frames verified, util {d:.0}% -> {d:.0}%, " ++
            "incremental session byte-identical; SA-1 shell boots parked and identical; " ++
            "whole-game demo migrated onto the SA-1 ({} MMIO sites proxied) and held " ++
            "frame- and audio-identical while animating\n",
        .{
            res.bps.len,                 res.stub_addr,
            res.trampolines,             res.memsel_stores_nopped,
            verify_skip + verify_frames, res.base.mean_util * 100,
            res.fast.mean_util * 100,    wg_sites,
        },
    );
    try out.flush();
}
