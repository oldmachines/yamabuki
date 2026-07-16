//! Commercial-boot golden gate (`zig build test-commercial`): boot real,
//! commercially released games headless and compare framebuffer + audio hashes
//! against `tests/commercial_goldens.zon`.
//!
//! The 100+ committed goldens are all homebrew — written by emulator people,
//! for emulator people — and that is exactly why a launch title that never
//! booted (F-Zero: HVBJOY's H-blank flag was never set) went unnoticed while
//! every gate stayed green. This gate is minted from the actual library.
//!
//! Commercial ROMs cannot be fetched or vendored, so the gate is OPT-IN: it
//! runs only against a local ROM directory (`-Dcommercial-roms=<dir>`), and a
//! manifest entry whose ROM is absent is a printed SKIP, never a failure — CI
//! has no ROMs and stays green without special-casing.
//!
//! ROMs are identified by the sha256 of the copier-stripped image, because
//! filenames vary wildly between dumps. A file whose hash matches nothing but
//! whose internal header (title + region + stored checksum) matches a manifest
//! entry is REPORTED AS A FAILURE: same declared identity, different content —
//! a corrupted or bad dump the user would want to know about. A title-only
//! match (different region or revision of a pinned game) is a printed skip.
//!
//! Re-mint with `-Dcommercial-mint`: runs every identifiable ROM in the
//! directory and prints ready-to-paste manifest entries.
//!
//! Options (see build.zig): -Dcommercial-roms=<dir>  -Dcommercial-mint
//! -Dcommercial-filter=<substr>

const std = @import("std");
const core = @import("snes_core");
const options = @import("commercial_options");

/// One pinned game. `sha256` is the lowercase hex digest of the
/// copier-stripped image; `title`/`region`/`checksum` come from the internal
/// header and exist for identification messages when the hash does not match.
const Entry = struct {
    sha256: []const u8,
    title: []const u8,
    region: u8,
    checksum: u16,
    frames: u32,
    fb: u64,
    audio: u64,
};

const Golden = struct {
    roms: []const Entry,
};

const golden: Golden = @import("commercial_goldens.zon");

/// Frames used when minting new entries.
const mint_frames_default: u32 = 600;

const Identified = struct {
    name: []const u8, // file name, for messages
    image: []const u8, // copier-stripped
    sha_hex: [64]u8,
    title: []const u8, // trimmed internal title (slice into image)
    region: u8,
    checksum: u16,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const dir_path = options.roms orelse {
        try out.print("commercial-runner: no ROM directory (-Dcommercial-roms=<dir>); {} pinned games skipped\n", .{golden.roms.len});
        try out.flush();
        return;
    };

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        try out.print("error: cannot open ROM directory '{s}'\n", .{dir_path});
        try out.flush();
        std.process.exit(2);
    };
    defer dir.close(io);

    // Collect file names first: iterator entry names are only valid between
    // steps, and reading files mid-iteration would invalidate them.
    var names: std.array_list.Managed([]const u8) = .init(gpa);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const lower = try std.ascii.allocLowerString(gpa, entry.name);
        if (!std.mem.endsWith(u8, lower, ".sfc") and !std.mem.endsWith(u8, lower, ".smc")) continue;
        try names.append(try gpa.dupe(u8, entry.name));
    }

    // Identify every plausible ROM in the directory by content.
    var found: std.array_list.Managed(Identified) = .init(gpa);
    for (names.items) |name| {
        const raw = dir.readFileAlloc(io, name, gpa, .limited(16 * 1024 * 1024)) catch continue;
        const image = core.header.stripCopierHeader(raw);
        if (image.len < 128 * 1024) continue; // no commercial cart is smaller
        const h = core.header.detect(image) catch continue;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(image, &digest, .{});
        var hex: [64]u8 = undefined;
        const hex_digits = "0123456789abcdef";
        for (digest, 0..) |b, i| {
            hex[i * 2] = hex_digits[b >> 4];
            hex[i * 2 + 1] = hex_digits[b & 0xF];
        }
        try found.append(.{
            .name = name,
            .image = image,
            .sha_hex = hex,
            .title = try gpa.dupe(u8, std.mem.trim(u8, &h.title, " \x00")),
            .region = h.region,
            .checksum = h.checksum,
        });
    }

    if (options.mint) {
        try mint(gpa, out, found.items);
        try out.flush();
        return;
    }

    var gated: u32 = 0;
    var failed: u32 = 0;
    var skipped: u32 = 0;

    for (golden.roms) |entry| {
        if (options.filter) |f| {
            if (std.ascii.indexOfIgnoreCase(entry.title, f) == null) continue;
        }
        // Exact content match first; identity-without-content match second.
        var exact: ?*const Identified = null;
        var imposter: ?*const Identified = null;
        for (found.items) |*id| {
            if (std.mem.eql(u8, &id.sha_hex, entry.sha256)) {
                exact = id;
                break;
            }
            if (std.mem.eql(u8, id.title, entry.title) and
                id.region == entry.region and id.checksum == entry.checksum)
                imposter = id;
        }

        if (exact) |id| {
            gated += 1;
            const ok = runOne(gpa, out, id, entry) catch |e| blk: {
                try out.print("ERROR {s}: {s}\n", .{ entry.title, @errorName(e) });
                break :blk false;
            };
            if (!ok) failed += 1;
        } else if (imposter) |id| {
            // Same internal identity, different bytes: a bit flip keeps the
            // header's title/region/stored checksum but moves the sha.
            failed += 1;
            try out.print("FAIL {s}\n    '{s}' declares this game but its content hash differs from the pinned dump\n    (corrupted copy, or a different dump of the same release)\n", .{ entry.title, id.name });
        } else {
            skipped += 1;
            try out.print("SKIP {s} (not in {s})\n", .{ entry.title, dir_path });
        }
    }

    try out.print("\ncommercial-runner: {} gated, {} failed, {} skipped (of {} pinned)\n", .{
        gated, failed, skipped, golden.roms.len,
    });
    try out.flush();
    if (failed > 0) std.process.exit(1);
}

fn runOne(
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    id: *const Identified,
    entry: Entry,
) !bool {
    const hashes = try bootAndHash(gpa, id.image, entry.frames);
    const ok = hashes.fb == entry.fb and hashes.audio == entry.audio;
    try out.print("{s} {s} ({} frames)\n    fb    got {x:0>16} want {x:0>16}\n    audio got {x:0>16} want {x:0>16}\n", .{
        if (ok) "PASS" else "FAIL", entry.title, entry.frames,
        hashes.fb,                  entry.fb,    hashes.audio,
        entry.audio,
    });
    return ok;
}

const Hashes = struct { fb: u64, audio: u64 };

/// Boot the image headless for `frames` frames with no input; hash the final
/// framebuffer and the whole audio stream. Deterministic: same image + frame
/// count -> same hashes, which is the entire premise of the gate.
fn bootAndHash(gpa: std.mem.Allocator, image: []const u8, frames: u32) !Hashes {
    const cart = try core.Cartridge.load(gpa, image);
    const con = try gpa.create(core.FastConsole);
    con.init(cart);

    var audio = core.console.audio_hash_init;
    var drain: [4096]i16 = undefined;
    for (0..frames) |_| {
        con.runFrame();
        while (true) {
            const n = con.readAudio(&drain);
            if (n == 0) break;
            audio = core.console.hashAudio(audio, drain[0..n]);
        }
    }
    return .{ .fb = core.console.hashFrame(con.framebuffer()), .audio = audio };
}

/// Print ready-to-paste manifest entries for every identified ROM.
fn mint(gpa: std.mem.Allocator, out: *std.Io.Writer, found: []const Identified) !void {
    const frames: u32 = if (options.frames != 0) options.frames else mint_frames_default;
    for (found) |*id| {
        if (options.filter) |f| {
            if (std.ascii.indexOfIgnoreCase(id.name, f) == null and
                std.ascii.indexOfIgnoreCase(id.title, f) == null) continue;
        }
        const hashes = bootAndHash(gpa, id.image, frames) catch |e| {
            try out.print("// {s}: {s}\n", .{ id.name, @errorName(e) });
            continue;
        };
        try out.print(
            \\// {s}
            \\.{{ .sha256 = "{s}", .title = "{s}", .region = {}, .checksum = 0x{x:0>4}, .frames = {}, .fb = 0x{x:0>16}, .audio = 0x{x:0>16} }},
            \\
        , .{ id.name, &id.sha_hex, id.title, id.region, id.checksum, frames, hashes.fb, hashes.audio });
        try out.flush();
    }
}
