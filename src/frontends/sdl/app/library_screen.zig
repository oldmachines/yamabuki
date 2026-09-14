//! The library screen: its own SDL session (window, software blit, fixed navigation), the patch prompt, the FastROM generation offer and progress screens, the folder picker.
//!
//! Carved out of app.zig as pure code motion; every declaration
//! here is re-exported from app.zig, which stays the root.

const boxart = @import("../boxart.zig");
const config = @import("../config.zig");
const core = @import("snes_core");
const dirpicker = @import("../dirpicker.zig");
const input = @import("../input.zig");
const library = @import("../library.zig");
const menu = @import("../menu.zig");
const patchfind = @import("../patchfind.zig");
const sdl3 = @import("../sdl3.zig");
const std = @import("std");
const ui = @import("../ui.zig");
const util = @import("util");
const app_root = @import("../app.zig");

/// The library picker: its own small SDL session (window, software blit,
/// fixed navigation) that scans incrementally while the list is browsed.
/// Row 0 is always "ADD ROM FOLDER", which opens an in-app folder browser
/// (`dirpicker.zig`) instead of requiring a hand-edit of config.zon; picking
/// a folder appends it to `cfg.library.rom_dirs`, persists `cfg` (when
/// `config_path` is set), and restarts the scan to pick it up immediately.
/// The highlighted game's box art (`boxart.zig`; `boxart_dir` is the
/// per-user picture folder) is shown in a panel beside the list.
/// Returns the selected entry's path (duped into `gpa`), or null to quit.
pub fn runLibrary(
    io: std.Io,
    gpa: std.mem.Allocator,
    sdl: sdl3.Api,
    scale: u32,
    lib: *library.Library,
    cfg: *config.Config,
    config_path: ?[]const u8,
    cache_path: ?[]const u8,
    patches_dir: ?[]const u8,
    boxart_dir: ?[]const u8,
    err: *std.Io.Writer,
) !?[]const u8 {
    if (!sdl.SDL_Init(sdl3.init_video | sdl3.init_audio)) {
        try err.print("error: SDL_Init: {s}\n", .{sdl.SDL_GetError()});
        try err.flush();
        std.process.exit(1);
    }
    defer sdl.SDL_Quit();

    var pad_api: ?sdl3.PadApi = null;
    if (sdl3.loadPad()) |papi| {
        if (papi.SDL_InitSubSystem(sdl3.init_gamepad)) pad_api = papi;
    } else |_| {}

    const window = sdl.SDL_CreateWindow(
        "Yamabuki",
        @intCast(256 * scale),
        @intCast(224 * scale),
        sdl3.window_resizable,
    ) orelse {
        try err.print("error: SDL_CreateWindow: {s}\n", .{sdl.SDL_GetError()});
        try err.flush();
        std.process.exit(1);
    };
    defer sdl.SDL_DestroyWindow(window);
    const renderer = sdl.SDL_CreateRenderer(window, null) orelse {
        try err.print("error: SDL_CreateRenderer: {s}\n", .{sdl.SDL_GetError()});
        try err.flush();
        std.process.exit(1);
    };
    defer sdl.SDL_DestroyRenderer(renderer);
    _ = sdl.SDL_SetRenderVSync(renderer, 0);
    const texture = sdl.SDL_CreateTexture(
        renderer,
        sdl3.pixel_format_rgb565,
        sdl3.texture_access_streaming,
        256,
        224,
    ) orelse {
        try err.print("error: SDL_CreateTexture: {s}\n", .{sdl.SDL_GetError()});
        try err.flush();
        std.process.exit(1);
    };
    defer sdl.SDL_DestroyTexture(texture);
    _ = sdl.SDL_SetTextureScaleMode(texture, sdl3.scale_mode_nearest);
    _ = sdl.SDL_SetRenderLogicalPresentation(renderer, 512, 448, sdl3.logical_presentation_letterbox);

    // Any connected pad can drive the picker — no player slots here.
    var open_pads: std.ArrayList(*sdl3.Gamepad) = .empty;
    defer if (pad_api) |papi| for (open_pads.items) |p| papi.SDL_CloseGamepad(p);

    var canvas: [256 * 224]u16 = undefined;
    var scanner = library.Scanner.begin(gpa, io, cfg.library.rom_dirs, err);
    var cursor: usize = 0;
    var scroll: usize = 0;
    const visible_rows = 17;
    // Hold-to-scroll for both the game list and the folder browser.
    var repeater: menu.Repeater = .{};

    // Patch availability: the folder index is built once, and every entry's
    // PATCH tag is refreshed from it now (cached entries) and again when a
    // scan completes (fresh ones).
    var patch_index = patchfind.FolderIndex.build(io, gpa, patches_dir);
    refreshPatchTags(io, gpa, lib, &patch_index);

    // Box art for the highlighted game: looked up and decoded once the
    // cursor has rested on an entry for a few frames (a held Down never
    // decodes), then kept until the cursor leaves it. The per-user folder
    // is created empty so there is somewhere obvious to put pictures.
    if (boxart_dir) |d| std.Io.Dir.cwd().createDirPath(io, d) catch {};
    const art = try gpa.create(boxart.Thumb);
    defer gpa.destroy(art);
    var art_ok = false;
    var art_for: ?[]const u8 = null; // the entry the art state is about
    var art_pending: ?[]const u8 = null; // the entry the cursor is settling on
    var art_rest: u32 = 0;

    // Row 0 of the list is always the ADD ROM FOLDER action, so the browser
    // never depends on a hand-edited config.zon. `.prompt` is the two-row
    // patched-or-original question for a game with a patch available;
    // `.offer` proposes generating a FastROM patch for a SlowROM game that
    // has none; `.generating` runs that session incrementally with a
    // progress screen (the scanner's budget pattern — no thread) and lands
    // in `.prompt` on success or `.genfail` on failure; `.picker` owns the
    // folder browser while it's open; `.list` is the game list.
    const Mode = enum { list, picker, prompt, offer, generating, genfail };
    var mode: Mode = .list;
    var picker: ?dirpicker.Picker = null;
    defer if (picker) |*pk| pk.deinit();
    // The entry the prompt/offer/generation is about, and where the list
    // cursor goes back to.
    var prompt_entry: usize = 0;
    var saved_cursor: usize = 0;
    // The generation session, the ROM bytes it borrows, the latest progress
    // for the screen, the failure for `.genfail`, and the measured-effect
    // note a successful generation adds to the patched-or-original prompt.
    var gen_session: ?util.GenSession = null;
    var gen_rom: ?[]u8 = null;
    var gen_progress: util.GenSession.Progress = .{ .phase = .baseline, .frame = 0, .total = 1 };
    var gen_failure: ?util.GenFailure = null;
    var gen_note: [48]u8 = undefined;
    var gen_note_len: usize = 0;
    defer if (gen_session) |*s| s.deinit();
    defer if (gen_rom) |r| gpa.free(r);

    while (true) {
        var ev: sdl3.Event = undefined;
        var picked: ?usize = null;
        while (sdl.SDL_PollEvent(&ev)) {
            if (ev.type == sdl3.event_quit) return null;
            const nev: input.Ev = switch (ev.type) {
                sdl3.event_key_down, sdl3.event_key_up => .{ .key = .{
                    .scancode = ev.key.scancode,
                    .down = ev.key.down,
                    .repeat = ev.key.repeat,
                } },
                sdl3.event_gamepad_button_down, sdl3.event_gamepad_button_up => .{ .pad_button = .{
                    .pad = ev.gbutton.which,
                    .button = ev.gbutton.button,
                    .down = ev.gbutton.down,
                } },
                sdl3.event_gamepad_added => blk: {
                    if (pad_api) |papi| {
                        if (papi.SDL_OpenGamepad(ev.gdevice.which)) |p|
                            open_pads.append(gpa, p) catch {};
                    }
                    break :blk .{ .pad_added = .{ .pad = ev.gdevice.which } };
                },
                else => continue,
            };
            repeater.feed(nev);
            const n = switch (mode) {
                .list => lib.entries.items.len + 1,
                .picker => picker.?.rowCount(),
                .prompt => 2,
                .offer => 3,
                .generating => 0,
                .genfail => 1,
            };
            switch (menu.navFromEvent(nev) orelse continue) {
                .up => if (n != 0) {
                    cursor = if (cursor == 0) n - 1 else cursor - 1;
                },
                .down => if (n != 0) {
                    cursor = if (cursor + 1 >= n) 0 else cursor + 1;
                },
                .left => cursor -|= visible_rows,
                .right => if (n != 0) {
                    cursor = @min(cursor + visible_rows, n - 1);
                },
                .confirm => switch (mode) {
                    .list => if (cursor == 0) {
                        picker = dirpicker.Picker.init(gpa, io, cfg.library.show_hidden_folders);
                        mode = .picker;
                        cursor = 0;
                        scroll = 0;
                    } else if (cursor - 1 < lib.entries.items.len) {
                        const e = &lib.entries.items[cursor - 1];
                        if (e.has_patch) {
                            // Ask patched-or-original, preselecting the
                            // remembered choice (default: original — the
                            // saves the player already has stay in front).
                            mode = .prompt;
                            prompt_entry = cursor - 1;
                            saved_cursor = cursor;
                            gen_note_len = 0;
                            cursor = blk: {
                                if (cfg.perGame(e.game_id)) |p| if (p.patch) |c| {
                                    break :blk if (c == .patched) 0 else 1;
                                };
                                break :blk 1;
                            };
                        } else if (genCandidate(e, cfg, patches_dir)) {
                            // No patch, but this SlowROM game could have one
                            // made: offer it, defaulting to just playing.
                            mode = .offer;
                            prompt_entry = cursor - 1;
                            saved_cursor = cursor;
                            cursor = 0;
                        } else {
                            picked = cursor - 1;
                        }
                    },
                    .prompt => {
                        const e = &lib.entries.items[prompt_entry];
                        if (cfg.perGameMut(gpa, e.game_id)) |pg| {
                            pg.patch = if (cursor == 0) .patched else .original;
                            if (config_path) |p| config.save(io, gpa, cfg.*, p) catch |se| {
                                err.print("warning: cannot write {s}: {s}\n", .{ p, @errorName(se) }) catch {};
                                err.flush() catch {};
                            };
                        } else |_| {}
                        picked = prompt_entry;
                        cursor = saved_cursor;
                        mode = .list;
                    },
                    .offer => switch (cursor) {
                        0 => { // PLAY ORIGINAL (ask again next time)
                            picked = prompt_entry;
                            cursor = saved_cursor;
                            mode = .list;
                        },
                        1 => { // GENERATE FASTROM PATCH
                            const e = &lib.entries.items[prompt_entry];
                            if (startGeneration(io, gpa, e.path, &gen_rom, err)) |session| {
                                gen_session = session;
                                gen_progress = .{ .phase = .baseline, .frame = 0, .total = session.total };
                                mode = .generating;
                            } else {
                                // Could not even start (unreadable ROM, OOM):
                                // the reason is on stderr; just play.
                                picked = prompt_entry;
                                cursor = saved_cursor;
                                mode = .list;
                            }
                        },
                        else => { // PLAY, NEVER ASK FOR THIS GAME
                            const e = &lib.entries.items[prompt_entry];
                            if (cfg.perGameMut(gpa, e.game_id)) |pg| {
                                pg.offer_gen = false;
                                if (config_path) |p| config.save(io, gpa, cfg.*, p) catch |se| {
                                    err.print("warning: cannot write {s}: {s}\n", .{ p, @errorName(se) }) catch {};
                                    err.flush() catch {};
                                };
                            } else |_| {}
                            picked = prompt_entry;
                            cursor = saved_cursor;
                            mode = .list;
                        },
                    },
                    .generating => {}, // nothing to confirm; B cancels
                    .genfail => { // PLAY ORIGINAL
                        picked = prompt_entry;
                        cursor = saved_cursor;
                        mode = .list;
                    },
                    .picker => switch (picker.?.activate(io, cursor)) {
                        .use_folder => |path| {
                            cfg.addRomDir(gpa, path) catch {};
                            if (config_path) |p| config.save(io, gpa, cfg.*, p) catch |e| {
                                err.print("warning: cannot write {s}: {s}\n", .{ p, @errorName(e) }) catch {};
                                err.flush() catch {};
                            };
                            picker.?.deinit();
                            picker = null;
                            mode = .list;
                            scanner = library.Scanner.begin(gpa, io, cfg.library.rom_dirs, err);
                            cursor = 0;
                            scroll = 0;
                        },
                        .toggled_hidden => |show| {
                            cfg.library.show_hidden_folders = show;
                            if (config_path) |p| config.save(io, gpa, cfg.*, p) catch |e| {
                                err.print("warning: cannot write {s}: {s}\n", .{ p, @errorName(e) }) catch {};
                                err.flush() catch {};
                            };
                            // Cursor stays put (the toggle row you just
                            // pressed); the post-poll clamp below catches it
                            // if the re-filtered listing got shorter.
                        },
                        .none => {
                            cursor = 0;
                            scroll = 0;
                        },
                    },
                },
                .back, .close => switch (mode) {
                    .list => return null,
                    .picker => {
                        picker.?.deinit();
                        picker = null;
                        mode = .list;
                        cursor = 0;
                        scroll = 0;
                    },
                    .prompt, .offer, .genfail => {
                        cursor = saved_cursor;
                        mode = .list;
                    },
                    .generating => {
                        // Cancel: throw the half-done session away.
                        if (gen_session) |*s| s.deinit();
                        gen_session = null;
                        if (gen_rom) |r| gpa.free(r);
                        gen_rom = null;
                        cursor = saved_cursor;
                        mode = .list;
                    },
                },
            }
        }

        // A held Up/Down keeps scrolling without a fresh keypress per row —
        // .up/.down only ever move `cursor` here, same as a real press.
        if (repeater.tick()) |nav| {
            const n = switch (mode) {
                .list => lib.entries.items.len + 1,
                .picker => picker.?.rowCount(),
                .prompt => 2,
                .offer => 3,
                .generating => 0,
                .genfail => 1,
            };
            switch (nav) {
                .up => if (n != 0) {
                    cursor = if (cursor == 0) n - 1 else cursor - 1;
                },
                .down => if (n != 0) {
                    cursor = if (cursor + 1 >= n) 0 else cursor + 1;
                },
                else => {},
            }
        }

        if (picked) |i| return try gpa.dupe(u8, lib.entries.items[i].path);

        // Scan under a per-frame time budget so the list fills while the
        // screen stays live; persist the cache the moment it completes.
        const deadline = sdl.SDL_GetTicksNS() + 6 * std.time.ns_per_ms;
        while (!scanner.done and sdl.SDL_GetTicksNS() < deadline) {
            if (scanner.stepOne(io, lib)) {
                refreshPatchTags(io, gpa, lib, &patch_index);
                if (cache_path) |p| lib.saveCache(io, gpa, p) catch {};
            }
        }

        // The generation session gets the same treatment as the scanner: a
        // per-frame time budget on the main loop, one emulated frame per
        // step, screen still live in between.
        if (mode == .generating) {
            const gen_deadline = sdl.SDL_GetTicksNS() + 12 * std.time.ns_per_ms;
            step: while (sdl.SDL_GetTicksNS() < gen_deadline) {
                const status = gen_session.?.step(1) catch |e| {
                    err.print("generation failed: {s}\n", .{@errorName(e)}) catch {};
                    err.flush() catch {};
                    gen_session.?.deinit();
                    gen_session = null;
                    gpa.free(gen_rom.?);
                    gen_rom = null;
                    cursor = saved_cursor;
                    mode = .list;
                    break :step;
                };
                switch (status) {
                    .running => |p| gen_progress = p,
                    .done => |outcome| {
                        gen_failure = null; // a write failure below is its own story
                        finishGeneration(io, gpa, lib, patches_dir.?, prompt_entry, outcome, &gen_note, &gen_note_len, err);
                        gen_session.?.deinit();
                        gen_session = null;
                        gpa.free(gen_rom.?);
                        gen_rom = null;
                        // Rebuild the index so the new patch is discovered,
                        // then land in the patched-or-original prompt with
                        // PLAY PATCHED preselected.
                        patch_index = patchfind.FolderIndex.build(io, gpa, patches_dir);
                        refreshPatchTags(io, gpa, lib, &patch_index);
                        mode = if (lib.entries.items[prompt_entry].has_patch) .prompt else .genfail;
                        cursor = 0;
                        break :step;
                    },
                    .failed => |f| {
                        gen_failure = f;
                        // A game that cannot convert is not offered again.
                        const e = &lib.entries.items[prompt_entry];
                        if (cfg.perGameMut(gpa, e.game_id)) |pg| {
                            pg.offer_gen = false;
                            if (config_path) |p| config.save(io, gpa, cfg.*, p) catch {};
                        } else |_| {}
                        gen_session.?.deinit();
                        gen_session = null;
                        gpa.free(gen_rom.?);
                        gen_rom = null;
                        mode = .genfail;
                        cursor = 0;
                        break :step;
                    },
                }
            }
        }

        const total = switch (mode) {
            .list => lib.entries.items.len + 1,
            .picker => picker.?.rowCount(),
            .prompt => 2,
            .offer => 3,
            .generating => 1,
            .genfail => 1,
        };
        if (cursor >= total and total != 0) cursor = total - 1;
        if (cursor < scroll) scroll = cursor;
        if (cursor >= scroll + visible_rows) scroll = cursor - visible_rows + 1;

        // Box art follows the cursor with a short settle.
        const want: ?[]const u8 = if (mode == .list and cursor >= 1 and cursor - 1 < lib.entries.items.len)
            lib.entries.items[cursor - 1].path
        else
            null;
        if (!samePath(want, art_for)) {
            art_ok = false;
            if (!samePath(want, art_pending)) {
                art_pending = want;
                art_rest = 0;
            }
            art_rest += 1;
            if (want == null) {
                art_for = null;
            } else if (art_rest >= art_settle_frames) {
                const e = lib.entries.items[cursor - 1];
                art_for = want;
                if (boxart.find(io, gpa, e.path, e.game_id, boxart_dir)) |p| {
                    defer gpa.free(p);
                    art_ok = boxart.load(io, gpa, p, art);
                }
            }
        }

        switch (mode) {
            .list => drawLibraryScreen(&canvas, lib, cursor, scroll, visible_rows, cfg.library.rom_dirs.len == 0, if (scanner.done) null else scanner.remaining(), if (art_ok) art else null),
            .picker => drawPickerScreen(&canvas, &picker.?, cursor, scroll, visible_rows),
            .prompt => drawPatchPromptScreen(&canvas, lib.entries.items[prompt_entry].title, cursor, if (gen_note_len != 0) gen_note[0..gen_note_len] else null),
            .offer => drawOfferScreen(&canvas, lib.entries.items[prompt_entry].title, cursor),
            .generating => drawGeneratingScreen(&canvas, lib.entries.items[prompt_entry].title, gen_progress),
            .genfail => drawGenFailScreen(&canvas, lib.entries.items[prompt_entry].title, gen_failure),
        }

        _ = sdl.SDL_UpdateTexture(texture, null, &canvas, 256 * 2);
        _ = sdl.SDL_RenderClear(renderer);
        _ = sdl.SDL_RenderTexture(renderer, texture, null, null);
        _ = sdl.SDL_RenderPresent(renderer);
        sdl.SDL_DelayNS(16 * std.time.ns_per_ms);
    }
}

/// Frames the cursor rests on an entry before its box art is looked up:
/// long enough that hold-to-scroll never decodes a picture per row, short
/// enough to feel immediate once the scrolling stops.
pub const art_settle_frames: u32 = 6;

fn samePath(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// The panel beside the list: where the box art box sits and how wide the
/// list column is because of it.
pub const panel_x: i32 = 166;
pub const panel_y: i32 = 20;
/// Titles in the list column are cut to this many characters; the
/// compact tag on a row (`PATCH`, a chip, or `PAL`) sits to its right.
pub const list_title_chars: usize = 20;
const list_tag_right: i32 = 160;

/// The library's whole frame, drawn into a 256x224 canvas — pure pixels, so
/// the layout is testable and eyeballable without SDL. `scanning_left` is
/// null once the scan has completed. Row 0 is always the ADD ROM FOLDER
/// action; rows 1.. are `lib.entries` shifted by one. `art` is the
/// highlighted entry's thumbnail when it has one; the panel names the
/// entry's region, chip, patch and play time either way.
pub fn drawLibraryScreen(
    canvas: *[256 * 224]u16,
    lib: *const library.Library,
    cursor: usize,
    scroll: usize,
    visible_rows: usize,
    no_dirs: bool,
    scanning_left: ?usize,
    art: ?*const boxart.Thumb,
) void {
    const surf = ui.Surface.init(canvas, 256, 224);
    ui.fillRect(&surf, 0, 0, 256, 224, ui.color.panel);
    ui.drawText(&surf, 8, 6, "YAMABUKI", ui.color.accent);
    var hdr: [40]u8 = undefined;
    const count_txt = std.fmt.bufPrint(&hdr, "{d} GAMES", .{lib.entries.items.len}) catch "";
    ui.drawText(&surf, 248 - @as(i32, @intCast(ui.textWidth(count_txt))), 6, count_txt, ui.color.text_dim);

    if (no_dirs) {
        ui.drawTextCentered(&surf, 100, "NO ROM FOLDERS YET", ui.color.text);
        ui.drawTextCentered(&surf, 114, "SELECT ADD ROM FOLDER BELOW", ui.color.text_dim);
    } else if (lib.entries.items.len == 0 and scanning_left == null) {
        ui.drawTextCentered(&surf, 100, "NO SNES ROMS FOUND", ui.color.text);
    }

    const total = lib.entries.items.len + 1;
    for (0..visible_rows) |row| {
        const i = scroll + row;
        if (i >= total) break;
        const y: i32 = @intCast(20 + row * ui.line_h);
        const selected = i == cursor;
        if (selected) ui.drawText(&surf, 2, y, ">", ui.color.accent);
        const fg = if (selected) ui.color.text else ui.color.text_dim;
        if (i == 0) {
            ui.drawText(&surf, 10, y, "+ ADD ROM FOLDER", if (selected) ui.color.accent else ui.color.text_dim);
            continue;
        }
        const e = lib.entries.items[i - 1];
        ui.drawText(&surf, 10, y, e.title[0..@min(e.title.len, list_title_chars)], fg);
        // One word per row; the panel has the rest.
        const tag_txt: []const u8 = if (e.has_patch) "PATCH" else if (e.chip.len != 0) e.chip else if (std.mem.eql(u8, e.region, "PAL")) "PAL" else "";
        if (tag_txt.len != 0)
            ui.drawText(&surf, list_tag_right - @as(i32, @intCast(ui.textWidth(tag_txt))), y, tag_txt, ui.color.text_dim);
    }

    // The panel: the highlighted game's picture (or where one would go)
    // and its details. Nothing for the ADD ROM FOLDER row.
    if (cursor >= 1 and cursor - 1 < lib.entries.items.len) {
        const e = lib.entries.items[cursor - 1];
        ui.frameRect(&surf, panel_x - 1, panel_y - 1, boxart.max_w + 2, boxart.max_h + 2, ui.color.panel_edge);
        if (art) |t| {
            const ax = panel_x + @as(i32, @intCast((boxart.max_w - t.w) / 2));
            const ay = panel_y + @as(i32, @intCast((boxart.max_h - t.h) / 2));
            boxart.draw(&surf, ax, ay, t);
        } else {
            const label = "NO BOX ART";
            ui.drawText(&surf, panel_x + @as(i32, @intCast((boxart.max_w - ui.textWidth(label)) / 2)), panel_y + @as(i32, @intCast(boxart.max_h / 2)) - 3, label, ui.color.text_dim);
        }
        var dy: i32 = panel_y + @as(i32, @intCast(boxart.max_h)) + 6;
        var line: [16]u8 = undefined;
        const kind = std.fmt.bufPrint(&line, "{s} {s}", .{ e.region, e.chip }) catch e.region;
        ui.drawText(&surf, panel_x, dy, std.mem.trimEnd(u8, kind, " "), ui.color.text_dim);
        dy += ui.line_h;
        if (e.has_patch) {
            ui.drawText(&surf, panel_x, dy, "PATCH FOUND", ui.color.accent);
            dy += ui.line_h;
        }
        if (util.zipfile.isZipPath(e.path)) {
            ui.drawText(&surf, panel_x, dy, "ZIPPED", ui.color.text_dim);
            dy += ui.line_h;
        }
        if (e.playtime_s != 0) {
            var pt: [16]u8 = undefined;
            const h = e.playtime_s / 3600;
            const m = (e.playtime_s % 3600) / 60;
            const played = if (h != 0)
                std.fmt.bufPrint(&pt, "PLAYED {d}H {d:0>2}M", .{ h, m }) catch ""
            else
                std.fmt.bufPrint(&pt, "PLAYED {d}M", .{@max(m, 1)}) catch "";
            ui.drawText(&surf, panel_x, dy, played, ui.color.text_dim);
        }
    }

    if (scanning_left) |left| {
        var foot: [40]u8 = undefined;
        const t = std.fmt.bufPrint(&foot, "SCANNING... {d} LEFT", .{left}) catch "";
        ui.drawText(&surf, 8, 212, t, ui.color.accent);
    } else {
        ui.drawText(&surf, 8, 212, "ENTER/A SELECT  ESC/B QUIT", ui.color.text_dim);
    }
}

/// Refresh every entry's PATCH tag from the current filesystem state: a
/// same-basename softpatch or a patch-folder match by cached CRC32. Cheap —
/// one stat-or-small-read per entry plus the prebuilt folder index.
pub fn refreshPatchTags(
    io: std.Io,
    gpa: std.mem.Allocator,
    lib: *library.Library,
    idx: *const patchfind.FolderIndex,
) void {
    for (lib.entries.items) |*e| {
        e.has_patch = e.crc32 != 0 and
            patchfind.quickAvailable(io, gpa, e.path, e.crc32, idx);
    }
}

/// The patched-or-original question for a game with a patch available — the
/// same pure-pixel shape as the other screens, so it rides the same tests.
/// Row 0 = PLAY PATCHED, row 1 = PLAY ORIGINAL. `note` is the measured-effect
/// line a just-finished generation adds.
pub fn drawPatchPromptScreen(canvas: *[256 * 224]u16, title: []const u8, cursor: usize, note: ?[]const u8) void {
    const surf = ui.Surface.init(canvas, 256, 224);
    ui.fillRect(&surf, 0, 0, 256, 224, ui.color.panel);
    ui.drawText(&surf, 8, 6, "PATCH FOUND", ui.color.accent);

    ui.drawTextCentered(&surf, 70, title[0..@min(title.len, 32)], ui.color.text);
    ui.drawTextCentered(&surf, 88, "A PATCH IS AVAILABLE FOR THIS GAME", ui.color.text_dim);
    if (note) |txt| ui.drawTextCentered(&surf, 100, txt, ui.color.accent);

    const rows = [_][]const u8{ "PLAY PATCHED", "PLAY ORIGINAL" };
    for (rows, 0..) |label, i| {
        const y: i32 = @intCast(116 + i * ui.line_h);
        const selected = i == cursor;
        if (selected) ui.drawText(&surf, 92, y, ">", ui.color.accent);
        ui.drawText(&surf, 102, y, label, if (selected) ui.color.text else ui.color.text_dim);
    }

    ui.drawTextCentered(&surf, 170, "PATCHED AND ORIGINAL KEEP SEPARATE SAVES", ui.color.text_dim);
    ui.drawText(&surf, 8, 212, "ENTER/A SELECT  ESC/B BACK  CHOICE IS REMEMBERED", ui.color.text_dim);
}

/// Is this library entry worth offering FastROM generation for? SlowROM, no
/// coprocessor (the generator would refuse those anyway), no patch already,
/// somewhere writable/discoverable to put the result, and the user has not
/// said never-ask. `map_mode == 0` means an entry the scanner has not
/// re-identified yet — unknown, so no offer.
pub fn genCandidate(e: *const library.Entry, cfg: *const config.Config, patches_dir: ?[]const u8) bool {
    if (patches_dir == null) return false;
    if (e.has_patch) return false;
    if (e.chip.len != 0) return false;
    if (e.map_mode == 0 or (e.map_mode & 0x10) != 0) return false;
    if (cfg.perGame(e.game_id)) |p| if (p.offer_gen) |v| if (!v) return false;
    return true;
}

/// Generation runs the same window the CLI defaults to — the standard the
/// fastrom-compat list is verified to.
pub const gen_frames: u32 = 1800;
pub const gen_skip: u32 = 300;

/// Read the ROM and open a generation session over it. On success the raw
/// file bytes are parked in `gen_rom` (the session borrows the stripped
/// view); on failure the reason is printed and null returned.
pub fn startGeneration(
    io: std.Io,
    gpa: std.mem.Allocator,
    rom_path: []const u8,
    gen_rom: *?[]u8,
    err: *std.Io.Writer,
) ?util.GenSession {
    const raw = util.readRomFile(io, gpa, rom_path, err) orelse return null;
    const image = core.header.stripCopierHeader(raw);
    const session = util.GenSession.start(gpa, image, gen_frames, gen_skip) catch |e| {
        err.print("error: cannot start generation: {s}\n", .{@errorName(e)}) catch {};
        err.flush() catch {};
        gpa.free(raw);
        return null;
    };
    gen_rom.* = raw;
    return session;
}

/// A successful generation: write the BPS into the patches folder (footer
/// CRC is what discovery matches, so the name is cosmetic) and format the
/// measured-effect note for the prompt. Failures print; the caller decides
/// what screen follows based on whether discovery then finds the patch.
pub fn finishGeneration(
    io: std.Io,
    gpa: std.mem.Allocator,
    lib: *library.Library,
    patches_dir: []const u8,
    entry_idx: usize,
    outcome: util.GenOutcome,
    note: *[48]u8,
    note_len: *usize,
    err: *std.Io.Writer,
) void {
    defer gpa.free(outcome.image);
    defer gpa.free(outcome.bps);

    const e = &lib.entries.items[entry_idx];
    const base = std.fs.path.basename(e.path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
    const path = std.fmt.allocPrint(gpa, "{s}/{s}.bps", .{ patches_dir, base[0..dot] }) catch return;
    defer gpa.free(path);

    std.Io.Dir.cwd().createDirPath(io, patches_dir) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = outcome.bps }) catch {
        err.print("error: cannot write '{s}'\n", .{path}) catch {};
        err.flush() catch {};
        return;
    };
    err.print("generated {s} ({} bytes; verified {} frames)\n", .{
        path, outcome.bps.len, gen_skip + gen_frames,
    }) catch {};
    err.flush() catch {};

    const txt = std.fmt.bufPrint(note, "GENERATED + VERIFIED  UTIL {d:.0}% > {d:.0}%", .{
        outcome.base.mean_util * 100, outcome.fast.mean_util * 100,
    }) catch return;
    note_len.* = txt.len;
}

/// The generation offer: play as-is, make a patch, or never ask again.
pub fn drawOfferScreen(canvas: *[256 * 224]u16, title: []const u8, cursor: usize) void {
    const surf = ui.Surface.init(canvas, 256, 224);
    ui.fillRect(&surf, 0, 0, 256, 224, ui.color.panel);
    ui.drawText(&surf, 8, 6, "FASTROM CANDIDATE", ui.color.accent);

    ui.drawTextCentered(&surf, 62, title[0..@min(title.len, 32)], ui.color.text);
    ui.drawTextCentered(&surf, 80, "THIS SLOWROM GAME MIGHT RUN FASTER WITH A", ui.color.text_dim);
    ui.drawTextCentered(&surf, 90, "GENERATED FASTROM PATCH, VERIFIED IN-EMULATOR", ui.color.text_dim);

    const rows = [_][]const u8{ "PLAY ORIGINAL", "GENERATE FASTROM PATCH", "PLAY, NEVER ASK FOR THIS GAME" };
    for (rows, 0..) |label, i| {
        const y: i32 = @intCast(116 + i * ui.line_h);
        const selected = i == cursor;
        if (selected) ui.drawText(&surf, 44, y, ">", ui.color.accent);
        ui.drawText(&surf, 54, y, label, if (selected) ui.color.text else ui.color.text_dim);
    }

    ui.drawTextCentered(&surf, 176, "GENERATION PLAYS THE GAME TWICE TO PROVE THE", ui.color.text_dim);
    ui.drawTextCentered(&surf, 186, "PATCH CHANGES NOTHING YOU SEE OR HEAR", ui.color.text_dim);
    ui.drawText(&surf, 8, 212, "ENTER/A SELECT  ESC/B BACK", ui.color.text_dim);
}

/// The progress screen while a generation session runs on the main loop.
pub fn drawGeneratingScreen(canvas: *[256 * 224]u16, title: []const u8, p: util.GenSession.Progress) void {
    const surf = ui.Surface.init(canvas, 256, 224);
    ui.fillRect(&surf, 0, 0, 256, 224, ui.color.panel);
    ui.drawText(&surf, 8, 6, "GENERATING FASTROM PATCH", ui.color.accent);

    ui.drawTextCentered(&surf, 70, title[0..@min(title.len, 32)], ui.color.text);
    ui.drawTextCentered(&surf, 96, switch (p.phase) {
        .baseline => "PASS 1/2: PROFILING THE ORIGINAL",
        .verify => "PASS 2/2: VERIFYING THE PATCHED RUN",
        .finished => "FINISHING",
    }, ui.color.text);

    var buf: [32]u8 = undefined;
    const count = std.fmt.bufPrint(&buf, "{d} / {d} FRAMES", .{ p.frame, p.total }) catch "";
    ui.drawTextCentered(&surf, 110, count, ui.color.text_dim);

    // A plain bar: outline plus fill proportional to this pass's progress.
    const bar_x: i32 = 48;
    const bar_w: u32 = 160;
    ui.fillRect(&surf, bar_x, 126, bar_w, 8, ui.color.text_dim);
    ui.fillRect(&surf, bar_x + 1, 127, bar_w - 2, 6, ui.color.panel);
    const frac: u64 = if (p.total == 0) 0 else @as(u64, p.frame) * (bar_w - 2) / p.total;
    if (frac != 0) ui.fillRect(&surf, bar_x + 1, 127, @intCast(frac), 6, ui.color.accent);

    ui.drawText(&surf, 8, 212, "ESC/B CANCEL", ui.color.text_dim);
}

/// Why no patch was produced, in library-screen shorthand; the full sentence
/// is on stderr for anyone at a terminal.
pub fn drawGenFailScreen(canvas: *[256 * 224]u16, title: []const u8, failure: ?util.GenFailure) void {
    const surf = ui.Surface.init(canvas, 256, 224);
    ui.fillRect(&surf, 0, 0, 256, 224, ui.color.panel);
    ui.drawText(&surf, 8, 6, "NO PATCH GENERATED", ui.color.accent);

    ui.drawTextCentered(&surf, 70, title[0..@min(title.len, 32)], ui.color.text);

    var buf: [48]u8 = undefined;
    const line1: []const u8, const line2: []const u8 = if (failure) |f| switch (f) {
        .refused => |r| .{ "THE GENERATOR REFUSED:", switch (r.reason) {
            .already_fastrom => "THE GAME IS ALREADY FASTROM",
            .coprocessor => "COPROCESSOR CARTRIDGE",
            .exhirom => "EXHIROM MAPPING UNSUPPORTED",
            .reset_vector_not_rom => "RESET VECTOR NOT IN ROM",
            .no_free_space => "NO FREE SPACE FOR THE STUB",
            .memsel_store_unpatchable => "UNPATCHABLE MEMSEL STORE",
        } },
        .frame_mismatch => |frame| .{
            std.fmt.bufPrint(&buf, "VERIFY FAILED AT FRAME {d}:", .{frame}) catch "VERIFY FAILED:",
            "FASTROM TIMING CHANGES WHAT YOU SEE",
        },
        .audio_mismatch => .{ "VERIFY FAILED:", "FASTROM TIMING CHANGES WHAT YOU HEAR" },
        .memsel_lost => |frame| .{
            std.fmt.bufPrint(&buf, "VERIFY FAILED AT FRAME {d}:", .{frame}) catch "VERIFY FAILED:",
            "THE GAME DISABLED FASTROM ITSELF",
        },
    } else .{ "THE PATCH COULD NOT BE WRITTEN", "SEE THE TERMINAL FOR THE REASON" };
    ui.drawTextCentered(&surf, 96, line1, ui.color.text);
    ui.drawTextCentered(&surf, 108, line2, ui.color.text_dim);

    ui.drawTextCentered(&surf, 150, "THIS GAME WILL NOT BE OFFERED AGAIN", ui.color.text_dim);
    ui.drawText(&surf, 8, 212, "ENTER/A PLAY ORIGINAL  ESC/B BACK", ui.color.text_dim);
}

/// The folder browser's whole frame — same pure-pixel shape as
/// `drawLibraryScreen`, so it rides the same test pattern.
pub fn drawPickerScreen(
    canvas: *[256 * 224]u16,
    pk: *const dirpicker.Picker,
    cursor: usize,
    scroll: usize,
    visible_rows: usize,
) void {
    const surf = ui.Surface.init(canvas, 256, 224);
    ui.fillRect(&surf, 0, 0, 256, 224, ui.color.panel);
    ui.drawText(&surf, 8, 6, "ADD ROM FOLDER", ui.color.accent);

    const path_txt = if (pk.at_root) "SELECT A DRIVE" else pk.path.items;
    ui.drawText(&surf, 8, 18, path_txt, ui.color.text_dim);

    const total = pk.rowCount();
    for (0..visible_rows) |row| {
        const i = scroll + row;
        if (i >= total) break;
        const y: i32 = @intCast(30 + row * ui.line_h);
        const selected = i == cursor;
        if (selected) ui.drawText(&surf, 2, y, ">", ui.color.accent);
        const fg = if (selected) ui.color.text else ui.color.text_dim;
        ui.drawText(&surf, 10, y, pk.rowLabel(i), fg);
        const value = pk.rowValue(i);
        if (value.len != 0) {
            const vx = 248 - @as(i32, @intCast(ui.textWidth(value)));
            ui.drawText(&surf, vx, y, value, fg);
        }
    }

    if (pk.err_msg) |msg| {
        ui.drawText(&surf, 8, 212, msg, ui.color.accent);
    } else {
        ui.drawText(&surf, 8, 212, "ENTER/A SELECT  ESC/B CANCEL", ui.color.text_dim);
    }
}
