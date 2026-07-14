//! Headless runner: load a ROM, run N frames, print the framebuffer and audio
//! hashes, and optionally dump the final frame as a binary PPM (P6) and the
//! whole audio stream as a WAV, both for eyeballing.
//!
//!   yamabuki-headless <rom.sfc> [--frames N] [--ppm out.ppm] [--wav out.wav]
//!                     [--accurate] [--patch p.bps|p.ips] [--save-patched out.sfc]
//!   yamabuki-headless <rom.sfc> --sa1-report [--frames N] [--skip N] [--json] [--hot]
//!
//! This is the primary in-development verification tool: `--ppm`/`--wav` give
//! output to inspect, and the printed hashes are what `zig build test-roms`
//! locks against.
//!
//! `--patch` applies a BPS or IPS patch to the ROM in memory at load — the file
//! on disk is never touched. BPS verifies the source CRC before applying (a
//! patch for the wrong ROM revision is an error naming both checksums) and the
//! target CRC after; IPS has no checksums, and says so. `--save-patched`
//! writes the patched image and exits without emulating.
//!
//! `--sa1-report` is step one of the SA-1 candidacy analyser (M12): it runs the
//! game with the frame-budget profiler compiled in and answers the question that
//! comes before every other one — *is this game CPU-bound at all?* See
//! `core/profile.zig` for what is being measured and why.

const std = @import("std");
const core = @import("snes_core");
const profile = core.profile;

const Args = struct {
    rom: []const u8,
    frames: ?u32 = null,
    ppm: ?[]const u8 = null,
    wav: ?[]const u8 = null,
    accuracy: core.Accuracy = .fast,
    patch: ?[]const u8 = null,
    save_patched: ?[]const u8 = null,
    sa1_report: bool = false,
    /// Frames to run before the profiler starts counting. Boot is not gameplay:
    /// the game is decompressing, clearing RAM, and handshaking with the APU,
    /// and none of that is representative of the frame budget in play.
    skip: u32 = 300,
    json: bool = false,
    /// Dump the hottest loops and how each was classified.
    hot: bool = false,
};

/// Default frames to profile: 60 seconds at 60 Hz, on top of the skipped boot.
const report_frames_default: u32 = 3600;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const args = parseArgs(init, gpa) catch {
        try out.print(
            \\usage: yamabuki-headless <rom.sfc> [--frames N] [--ppm out.ppm] [--wav out.wav] [--accurate]
            \\                         [--patch p.bps|p.ips] [--save-patched out.sfc]
            \\       yamabuki-headless <rom.sfc> --sa1-report [--frames N] [--skip N] [--json] [--hot]
            \\
            \\  --patch p     apply a BPS/IPS patch to the ROM in memory at load (BPS verified, IPS not)
            \\  --save-patched  write the patched image and exit without emulating (needs --patch)
            \\  --sa1-report  is this game CPU-bound? (step one of the SA-1 candidacy analyser)
            \\  --skip N      frames to run before profiling starts (default 300 — boot is not gameplay)
            \\  --hot         also list the loops the frame is spent in, and how each was classified
            \\
        , .{});
        try out.flush();
        std.process.exit(2);
    };

    var image = std.Io.Dir.cwd().readFileAlloc(io, args.rom, gpa, .limited(16 * 1024 * 1024)) catch {
        try out.print("error: cannot read ROM '{s}'\n", .{args.rom});
        try out.flush();
        std.process.exit(1);
    };

    if (args.patch) |patch_path| {
        image = applyPatch(io, gpa, out, image, patch_path) catch std.process.exit(1);
        if (args.save_patched) |save_path| {
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = save_path, .data = image }) catch {
                try out.print("error: cannot write '{s}'\n", .{save_path});
                try out.flush();
                std.process.exit(1);
            };
            try out.print("wrote {s} ({d} bytes)\n", .{ save_path, image.len });
            try out.flush();
            return;
        }
    } else if (args.save_patched != null) {
        try out.print("error: --save-patched needs --patch\n", .{});
        try out.flush();
        std.process.exit(2);
    }

    const cart = core.Cartridge.load(gpa, image) catch |e| {
        try out.print("error: cannot load ROM: {s}\n", .{@errorName(e)});
        try out.flush();
        std.process.exit(1);
    };

    if (args.sa1_report) {
        try runReport(io, gpa, out, args, cart);
        return;
    }

    const con = try gpa.create(core.AnyConsole);
    con.init(args.accuracy, cart);

    // Drain audio every frame (the ring holds ~15 frames); hash the stream
    // and keep it if a WAV dump was requested.
    var audio_hash = core.console.audio_hash_init;
    var audio_peak: u16 = 0;
    var audio_all: std.array_list.Managed(i16) = .init(gpa);
    var drain: [4096]i16 = undefined;
    const frames = args.frames orelse 1;
    for (0..frames) |_| {
        con.runFrame();
        while (true) {
            const n = con.readAudio(&drain);
            if (n == 0) break;
            audio_hash = core.console.hashAudio(audio_hash, drain[0..n]);
            for (drain[0..n]) |s| audio_peak = @max(audio_peak, @abs(s));
            if (args.wav != null) try audio_all.appendSlice(drain[0..n]);
        }
    }

    const fb = con.framebuffer();
    const width = con.frameWidth();
    const hash = core.console.hashFrame(fb);
    try out.print("{s}: {} frames, {}x{}, hash={x:0>16}, audio={x:0>16} (peak {})\n", .{
        args.rom, frames, width, fb.len / width, hash, audio_hash, audio_peak,
    });
    try out.flush();

    if (args.ppm) |path| {
        try writePpm(io, path, fb, width, @intCast(fb.len / width));
        try out.print("wrote {s}\n", .{path});
        try out.flush();
    }
    if (args.wav) |path| {
        try writeWav(io, path, audio_all.items);
        try out.print("wrote {s} ({} stereo frames)\n", .{ path, audio_all.items.len / 2 });
        try out.flush();
    }
}

/// Apply `--patch`: reads the patch file, strips the ROM's copier header (the
/// community's patches are made against unheadered images), applies, and
/// reports what kind of guarantee the format could give. Errors are printed
/// here so every failure names its cause; the caller just exits.
fn applyPatch(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    image: []u8,
    patch_path: []const u8,
) ![]u8 {
    const pbytes = std.Io.Dir.cwd().readFileAlloc(io, patch_path, gpa, .limited(16 * 1024 * 1024)) catch {
        try out.print("error: cannot read patch '{s}'\n", .{patch_path});
        try out.flush();
        return error.PatchFailed;
    };
    const stripped = core.header.stripCopierHeader(image);
    var mm: core.patch.CrcMismatch = .{};
    const res = core.patch.apply(gpa, stripped, pbytes, &mm) catch |e| {
        switch (e) {
            error.WrongSource => try out.print(
                "error: patch '{s}' is for a different ROM revision: it wants source crc32 {x:0>8}, this ROM is {x:0>8}\n",
                .{ patch_path, mm.expected, mm.actual },
            ),
            error.PatchChecksum => try out.print("error: patch '{s}' is damaged (its own checksum fails)\n", .{patch_path}),
            error.TargetChecksum => try out.print("error: patch '{s}' applied but the output failed its target checksum\n", .{patch_path}),
            error.UnknownFormat => try out.print("error: '{s}' is neither a BPS nor an IPS patch\n", .{patch_path}),
            error.Corrupt => try out.print("error: patch '{s}' is structurally broken\n", .{patch_path}),
            error.OutOfMemory => try out.print("error: out of memory applying '{s}'\n", .{patch_path}),
        }
        try out.flush();
        return error.PatchFailed;
    };
    if (res.verified) {
        try out.print("patch applied: {s} (source and target checksums verified)\n", .{patch_path});
    } else {
        try out.print("patch applied: {s} (IPS carries no checksums; the result is unverified)\n", .{patch_path});
    }
    try out.flush();
    return res.image;
}

/// `--sa1-report`: run the game with the frame-budget profiler and report
/// whether it is CPU-bound.
///
/// Nothing presses any buttons, so what gets profiled is whatever the game does
/// on its own — the attract/demo loop for most carts, a title screen for the
/// rest. That is a real limitation and the report says so, because a title
/// screen idling at 8% utilisation is not evidence of anything.
fn runReport(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    args: Args,
    cart: core.Cartridge,
) !void {
    _ = io;
    const want = args.frames orelse report_frames_default;

    const con = try gpa.create(core.ProfilingConsole);
    con.init(cart);

    var samples: std.array_list.Managed(profile.FrameSample) = .init(gpa);
    try samples.ensureTotalCapacity(want);

    var drain: [4096]i16 = undefined;
    for (0..args.skip + want) |i| {
        con.runFrame();
        while (con.readAudio(&drain) != 0) {} // keep the ring from backing up
        const s = con.takeProfile() orelse continue;
        if (i >= args.skip) samples.appendAssumeCapacity(s);
    }

    const scratch = try gpa.alloc(f64, samples.items.len);
    const sum = profile.summarise(samples.items, scratch);

    const h = &con.cart.header;
    const chip = @tagName(con.cart.chip);
    const map = @tagName(h.mapping);
    const title = std.mem.trim(u8, &h.title, " \x00");

    if (args.json) {
        try out.print(
            // `std.json.fmt` emits the surrounding quotes itself.
            "{{\"rom\":{f},\"title\":{f},\"map\":\"{s}\",\"chip\":\"{s}\"," ++
                "\"fastrom\":{},\"frames\":{}," ++
                "\"slow_frames\":{},\"slow_ratio\":{d:.4}," ++
                "\"stall_frames\":{},\"stalls\":{}," ++
                "\"longest_stall\":{},\"longest_stall_at\":{}," ++
                "\"mean_util\":{d:.4},\"median_util\":{d:.4},\"p95_util\":{d:.4}," ++
                "\"max_util\":{d:.4},\"verdict\":\"{s}\"}}\n",
            .{
                std.json.fmt(args.rom, .{}), std.json.fmt(title, .{}),
                map,                         chip,
                h.fastRom(),                 sum.frames,
                sum.slow_frames,             sum.slowRatio(),
                sum.stall_frames,            sum.stalls,
                sum.longest_stall,           sum.longest_stall_at,
                sum.mean_util,               sum.median_util,
                sum.p95_util,                sum.max_util,
                @tagName(sum.verdict),
            },
        );
        try out.flush();
        return;
    }

    const seconds = @as(f64, @floatFromInt(sum.frames)) / 60.0;
    try out.print("{s}\n", .{title});
    try out.print("  {s}, {s}, {s}\n", .{
        map,
        if (con.cart.chip == .none) "no coprocessor" else chip,
        if (h.fastRom()) "FastROM" else "SlowROM",
    });
    try out.print("  profiled {} frames ({d:.0}s) after {} boot frames\n\n", .{
        sum.frames, seconds, args.skip,
    });

    try out.print("  CPU utilisation   mean {d:.0}%   median {d:.0}%   p95 {d:.0}%   max {d:.0}%\n", .{
        sum.mean_util * 100, sum.median_util * 100, sum.p95_util * 100, sum.max_util * 100,
    });
    try out.print("  slowdown          {} of {} frames ({d:.1}%)\n", .{
        sum.slow_frames, sum.frames, sum.slowRatio() * 100,
    });
    if (sum.stalls > 0) {
        try out.print("  stalls            {} ({} frames) — loads or transitions, not slowdown\n", .{
            sum.stalls, sum.stall_frames,
        });
        try out.print("  longest           {} frames, from frame {}\n", .{
            sum.longest_stall, sum.longest_stall_at,
        });
    }

    try out.print("\n  verdict: {s}\n", .{sum.verdict.describe()});
    switch (sum.verdict) {
        .not_cpu_bound => try out.print(
            \\    The CPU idles through {d:.0}% of an average frame and never falls behind.
            \\    A faster CPU has nothing to do here.
            \\
        , .{(1 - sum.mean_util) * 100}),
        .at_the_limit => try out.print(
            \\    Never falls behind, but its 95th-percentile frame is {d:.0}% busy: there is
            \\    nothing left over. Not slow today; the first thing that would break if
            \\    anything were added to it.
            \\
        , .{sum.p95_util * 100}),
        .drops_frames => try out.print(
            \\    Loses {d:.1}% of its frames to slowdown — occasional, not constant.
            \\    Worth finding out where before drawing any conclusion.
            \\
        , .{sum.slowRatio() * 100}),
        .cpu_bound => try out.print(
            \\    Loses {d:.1}% of its frames to slowdown, spread through the capture rather
            \\    than bunched into loads. This is a game genuinely short of CPU, and the
            \\    kind a conversion exists for.
            \\
        , .{sum.slowRatio() * 100}),
        .no_signal => try out.print(
            \\    The game never read the controller — not in one of {} frames. It has not
            \\    finished booting, or it is sitting on something that does not poll, or it
            \\    has hung. Every frame looks dropped and none of them mean anything, so
            \\    there is no verdict to give. Try a longer --skip.
            \\
        , .{sum.frames}),
    }

    if (args.hot) {
        // Where every cycle went, loop or not.
        const Page = struct { pc: u32, cycles: u64 };
        var pages: std.array_list.Managed(Page) = .init(gpa);
        for (con.prof.pages, 0..) |c, i| {
            if (c != 0) try pages.append(.{ .pc = @intCast(i << 8), .cycles = c });
        }
        std.mem.sort(Page, pages.items, {}, struct {
            fn gt(_: void, a: Page, b: Page) bool {
                return a.cycles > b.cycles;
            }
        }.gt);
        var total: u64 = 0;
        for (pages.items) |e| total += e.cycles;
        try out.print("\n  hottest 256-byte pages ({} distinct, {} cycles total)\n", .{ pages.items.len, total });
        for (pages.items[0..@min(12, pages.items.len)]) |e| {
            try out.print("     ${x:0>6}   {d:>14}  {d:>5.1}%\n", .{
                e.pc, e.cycles, @as(f64, @floatFromInt(e.cycles)) * 100 / @as(f64, @floatFromInt(total)),
            });
        }

        var hot: [profile.hot_slots]profile.Hot = con.prof.hot;
        std.mem.sort(profile.Hot, &hot, {}, struct {
            fn gt(_: void, a: profile.Hot, b: profile.Hot) bool {
                return a.cycles > b.cycles;
            }
        }.gt);
        try out.print("\n  hottest loops (>= {} revisits)\n", .{profile.min_iters});
        try out.print("     {s:<10} {s:>14} {s:>13} {s:>10}  {s}\n", .{ "pc", "cycles", "instructions", "entries", "counted as" });
        for (hot[0..@min(12, hot.len)]) |e| {
            if (e.pc == profile.Hot.empty or e.cycles == 0) break;
            try out.print("     ${x:0>6}   {d:>14} {d:>13} {d:>10}  {s}\n", .{
                e.pc, e.cycles, e.iters, e.hits, if (e.idle) "idle" else "WORK",
            });
        }
    }

    // Everything a reader could over-trust, said out loud.
    try out.print(
        \\
        \\  Measured from the game's own attract/demo loop — no buttons were pressed.
        \\  Idle is WAI plus loops that change nothing, so a wait this misses reads as
        \\  work: utilisation is an UPPER bound. A game that polls the pad in its NMI
        \\  handler never registers a dropped frame at all, so slowdown is a LOWER
        \\  bound. The two errors bracket the truth; they do not compound.
        \\
    , .{});
    try out.flush();
}

fn parseArgs(init: std.process.Init, gpa: std.mem.Allocator) !Args {
    // POSIX-only otherwise; Windows decodes the command line from UTF-16 and
    // needs an allocator. Not deinit'd — the returned Args slice into it, and
    // `gpa` is the process arena.
    var it = try init.minimal.args.iterateAllocator(gpa);
    _ = it.skip(); // program name
    var out: Args = .{ .rom = undefined };
    var rom: ?[]const u8 = null;
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--frames")) {
            const v = it.next() orelse return error.MissingValue;
            out.frames = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, a, "--skip")) {
            const v = it.next() orelse return error.MissingValue;
            out.skip = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, a, "--ppm")) {
            out.ppm = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--wav")) {
            out.wav = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--accurate")) {
            out.accuracy = .accurate;
        } else if (std.mem.eql(u8, a, "--patch")) {
            out.patch = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--save-patched")) {
            out.save_patched = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--sa1-report")) {
            out.sa1_report = true;
        } else if (std.mem.eql(u8, a, "--json")) {
            out.json = true;
        } else if (std.mem.eql(u8, a, "--hot")) {
            out.hot = true;
        } else if (rom == null) {
            rom = a;
        } else return error.TooManyArgs;
    }
    out.rom = rom orelse return error.NoRom;
    return out;
}

/// Write interleaved stereo i16 samples as a 32 kHz PCM WAV.
fn writeWav(io: std.Io, path: []const u8, samples: []const i16) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    const wr = &fw.interface;

    const rate: u32 = @import("snes_core").timing.dsp_sample_hz;
    const data_len: u32 = @intCast(samples.len * 2);
    try wr.writeAll("RIFF");
    try wr.writeInt(u32, 36 + data_len, .little);
    try wr.writeAll("WAVEfmt ");
    try wr.writeInt(u32, 16, .little); // PCM chunk size
    try wr.writeInt(u16, 1, .little); // PCM
    try wr.writeInt(u16, 2, .little); // stereo
    try wr.writeInt(u32, rate, .little);
    try wr.writeInt(u32, rate * 4, .little); // byte rate
    try wr.writeInt(u16, 4, .little); // block align
    try wr.writeInt(u16, 16, .little); // bits per sample
    try wr.writeAll("data");
    try wr.writeInt(u32, data_len, .little);
    for (samples) |s| try wr.writeInt(i16, s, .little);
    try wr.flush();
}

/// Write an RGB565 framebuffer as a binary PPM (P6, 8-bit RGB).
fn writePpm(io: std.Io, path: []const u8, fb: []const u16, w: u32, h: u32) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    const wr = &fw.interface;

    try wr.print("P6\n{} {}\n255\n", .{ w, h });
    for (fb) |px| {
        const r5: u16 = (px >> 11) & 0x1F;
        const g6: u16 = (px >> 5) & 0x3F;
        const b5: u16 = px & 0x1F;
        const rgb = [3]u8{
            @intCast(r5 * 255 / 31),
            @intCast(g6 * 255 / 63),
            @intCast(b5 * 255 / 31),
        };
        try wr.writeAll(&rgb);
    }
    try wr.flush();
}
