//! The overlay menu: a console-firmware-style pause screen drawn over the
//! dimmed game by `ui.zig`, navigated with a *fixed* key/pad map so it stays
//! reachable whatever the config says — the escape hatch that survives any
//! remap. Pure state machine: `app.zig` feeds it normalized nav events (or
//! raw input events during remap capture) and acts on the returned Request;
//! everything here is testable without SDL.
//!
//! Pages: main → settings / input → per-device remap pages → hotkeys.
//! Values edit the live `Config` in place; every edit returns
//! `.config_dirty` so the app persists it immediately — closing the window
//! mid-session never loses a remap.

const std = @import("std");
const ui = @import("ui.zig");
const input = @import("input.zig");
const config = @import("config.zig");

pub const Device = enum { keys, pad };

pub const Page = union(enum) {
    main,
    settings,
    input_menu,
    map: struct { player: u1, device: Device },
    hotkeys,
};

/// Remap capture waits this many frames (~10 s) before giving up on its own.
pub const capture_frames: u32 = 600;

pub const NavEvent = enum { up, down, left, right, confirm, back, close };

/// What the app should do about the last event it fed in.
pub const Request = enum {
    none,
    resume_game,
    quit,
    reset,
    save_state,
    load_state,
    /// The config changed; persist it and re-resolve the bindings.
    config_dirty,
    /// Step the shader chain (the app owns the GL side).
    shader_prev,
    shader_next,
};

const Entry = struct { page: Page, cursor: usize };

const Capture = struct {
    /// A map slot (player+device+button) or a hotkey (any device).
    target: union(enum) {
        map: struct { player: u1, device: Device, btn: input.SnesButton },
        hotkey: input.Hotkey,
    },
    frames_left: u32 = capture_frames,
};

pub const Menu = struct {
    stack: [4]Entry = undefined,
    depth: usize = 0,
    capture: ?Capture = null,

    pub fn init() Menu {
        var m: Menu = .{};
        m.stack[0] = .{ .page = .main, .cursor = 0 };
        m.depth = 1;
        return m;
    }

    fn top(self: *Menu) *Entry {
        return &self.stack[self.depth - 1];
    }

    fn push(self: *Menu, page: Page) void {
        if (self.depth == self.stack.len) return;
        self.stack[self.depth] = .{ .page = page, .cursor = 0 };
        self.depth += 1;
    }

    /// One frame passed while a capture is pending; times out to browsing.
    pub fn tick(self: *Menu) void {
        if (self.capture) |*c| {
            c.frames_left -= 1;
            if (c.frames_left == 0) self.capture = null;
        }
    }

    pub fn capturing(self: *const Menu) bool {
        return self.capture != null;
    }

    /// Feed a raw input event while capturing. Keyboard targets take keys,
    /// pad targets take buttons and pushed half-axes, hotkeys take any.
    /// Esc always cancels. Returns a Request (`config_dirty` on success).
    pub fn feedCapture(
        self: *Menu,
        gpa: std.mem.Allocator,
        cfg: *config.Config,
        ev: input.Ev,
    ) Request {
        const cap = self.capture orelse return .none;
        switch (ev) {
            .key => |k| {
                if (!k.down or k.repeat) return .none;
                if (k.scancode == 41) { // Esc cancels, never binds
                    self.capture = null;
                    return .none;
                }
                const accepted = switch (cap.target) {
                    .map => |t| t.device == .keys,
                    .hotkey => true,
                };
                if (!accepted) return .none;
                return self.applyCapture(gpa, cfg, .{ .key = k.scancode });
            },
            .pad_button => |pb| {
                if (!pb.down) return .none;
                const accepted = switch (cap.target) {
                    .map => |t| t.device == .pad,
                    .hotkey => true,
                };
                if (!accepted) return .none;
                return self.applyCapture(gpa, cfg, .{ .pad_button = pb.button });
            },
            .pad_axis => |pa| {
                if (pa.axis >= 6) return .none;
                const accepted = switch (cap.target) {
                    .map => |t| t.device == .pad,
                    .hotkey => true,
                };
                if (!accepted) return .none;
                const v: i32 = pa.value;
                if (v < input.axis_engage and v > -input.axis_engage) return .none;
                return self.applyCapture(gpa, cfg, .{
                    .pad_axis = .{ .axis = pa.axis, .positive = v > 0 },
                });
            },
            else => return .none,
        }
    }

    fn applyCapture(self: *Menu, gpa: std.mem.Allocator, cfg: *config.Config, b: input.Binding) Request {
        const cap = self.capture.?;
        self.capture = null;
        switch (cap.target) {
            .map => |t| {
                const token = input.formatMapToken(gpa, b) catch return .none;
                const map = mapOf(cfg, t.player, t.device);
                const previous = mapGet(map, t.btn);
                // Conflict auto-swap within the same device+player: the SNES
                // button that already owned this key/button inherits ours.
                inline for (@typeInfo(input.SnesButton).@"enum".fields) |f| {
                    const other: input.SnesButton = @enumFromInt(f.value);
                    if (other != t.btn and std.mem.eql(u8, mapGet(map, other), token))
                        mapSet(map, other, previous);
                }
                mapSet(map, t.btn, token);
            },
            .hotkey => |hk| {
                const token = input.formatHotkeyToken(gpa, b) catch return .none;
                hotkeySet(&cfg.input.hotkeys, hk, token);
            },
        }
        return .config_dirty;
    }

    /// Handle one navigation event while browsing (not capturing).
    /// `shader_active` gates whether the shader row reacts to left/right.
    pub fn handleNav(self: *Menu, cfg: *config.Config, ev: NavEvent, shader_active: bool) Request {
        if (self.capture != null) return .none; // captures eat raw events instead
        const e = self.top();
        const n = itemCount(e.page);
        switch (ev) {
            .close => return .resume_game,
            .up => e.cursor = if (e.cursor == 0) n - 1 else e.cursor - 1,
            .down => e.cursor = if (e.cursor + 1 == n) 0 else e.cursor + 1,
            .back => {
                if (self.depth > 1) self.depth -= 1 else return .resume_game;
            },
            .confirm => return self.activate(cfg),
            .left, .right => return self.adjust(cfg, ev == .right, shader_active),
        }
        return .none;
    }

    fn activate(self: *Menu, cfg: *config.Config) Request {
        const e = self.top();
        switch (e.page) {
            .main => switch (e.cursor) {
                0 => return .resume_game,
                1 => return .save_state,
                2 => return .load_state,
                3 => self.push(.settings),
                4 => self.push(.input_menu),
                5 => return .reset,
                6 => return .quit,
                else => {},
            },
            .settings => return self.adjust(cfg, true, true),
            .input_menu => switch (e.cursor) {
                0 => self.push(.{ .map = .{ .player = 0, .device = .keys } }),
                1 => self.push(.{ .map = .{ .player = 0, .device = .pad } }),
                2 => self.push(.{ .map = .{ .player = 1, .device = .keys } }),
                3 => self.push(.{ .map = .{ .player = 1, .device = .pad } }),
                4 => self.push(.hotkeys),
                5 => {
                    cfg.input.swap_pads = !cfg.input.swap_pads;
                    return .config_dirty;
                },
                else => {},
            },
            .map => |t| {
                self.capture = .{ .target = .{ .map = .{
                    .player = t.player,
                    .device = t.device,
                    .btn = @enumFromInt(e.cursor),
                } } };
            },
            .hotkeys => {
                self.capture = .{ .target = .{ .hotkey = @enumFromInt(e.cursor) } };
            },
        }
        return .none;
    }

    /// Left/right on a value row. `confirm` on toggles routes here too.
    fn adjust(self: *Menu, cfg: *config.Config, inc: bool, shader_active: bool) Request {
        const e = self.top();
        switch (e.page) {
            .settings => switch (e.cursor) {
                0 => { // scale 1..8, saturating
                    const s = cfg.video.scale;
                    cfg.video.scale = if (inc) @min(s + 1, 8) else @max(s -| 1, 1);
                    return .config_dirty;
                },
                1 => {
                    cfg.audio.enabled = !cfg.audio.enabled;
                    return .config_dirty;
                },
                2 => {
                    if (!shader_active) return .none;
                    return if (inc) .shader_next else .shader_prev;
                },
                else => {},
            },
            .input_menu => {
                if (e.cursor == 5) {
                    cfg.input.swap_pads = !cfg.input.swap_pads;
                    return .config_dirty;
                }
            },
            else => {},
        }
        return .none;
    }

    // --- rendering ---------------------------------------------------------

    /// Draw the whole menu over an already-dimmed frame. `shader_name` is
    /// the active preset (null = software blit).
    pub fn draw(self: *Menu, s: *const ui.Surface, cfg: *const config.Config, shader_name: ?[]const u8) void {
        const e = self.top();
        const n = itemCount(e.page);

        // Panel: centered, sized to the item count.
        const panel_w: u32 = 232;
        const panel_h: u32 = @intCast(30 + n * ui.line_h + 10);
        const px: i32 = @intCast((256 - panel_w) / 2);
        const py: i32 = @intCast((s.vh() -| panel_h) / 2);
        ui.fillRect(s, px, py, panel_w, panel_h, ui.color.panel);
        ui.frameRect(s, px, py, panel_w, panel_h, ui.color.panel_edge);

        ui.drawText(s, px + 8, py + 6, pageTitle(e.page), ui.color.accent);

        var buf: [64]u8 = undefined;
        for (0..n) |i| {
            const y = py + 22 + @as(i32, @intCast(i * ui.line_h));
            const selected = i == e.cursor;
            if (selected) ui.drawText(s, px + 4, y, ">", ui.color.accent);
            const fg = if (selected) ui.color.text else ui.color.text_dim;
            ui.drawText(s, px + 14, y, itemLabel(e.page, i), fg);
            const value = itemValue(e.page, i, cfg, shader_name, &buf);
            if (value.len != 0) {
                const vx = px + @as(i32, @intCast(panel_w)) - 8 - @as(i32, @intCast(ui.textWidth(value)));
                ui.drawText(s, vx, y, value, fg);
            }
        }

        if (self.capture) |cap| {
            const msg = switch (cap.target) {
                .map => |t| if (t.device == .keys) "PRESS A KEY (ESC CANCELS)" else "PRESS A PAD BUTTON OR DIRECTION",
                .hotkey => "PRESS A KEY OR PAD BUTTON (ESC CANCELS)",
            };
            const bar_y: i32 = @intCast(s.vh() -| 24);
            ui.fillRect(s, 8, bar_y, 240, 16, ui.color.panel);
            ui.frameRect(s, 8, bar_y, 240, 16, ui.color.accent);
            ui.drawTextCentered(s, bar_y + 4, msg, ui.color.text);
        } else {
            const hint = "ARROWS/DPAD MOVE  ENTER/A OK  ESC/B BACK";
            ui.drawTextCentered(s, @intCast(s.vh() -| 14), hint, ui.color.text_dim);
        }
    }

    fn pageTitle(page: Page) []const u8 {
        return switch (page) {
            .main => "YAMABUKI",
            .settings => "SETTINGS",
            .input_menu => "INPUT",
            .map => |t| switch (t.device) {
                .keys => if (t.player == 0) "PLAYER 1 KEYBOARD" else "PLAYER 2 KEYBOARD",
                .pad => if (t.player == 0) "PLAYER 1 PAD" else "PLAYER 2 PAD",
            },
            .hotkeys => "HOTKEYS",
        };
    }
};

/// The menu's own navigation map — deliberately FIXED, not the config's
/// bindings: whatever a remap does, arrows/Enter/Esc and dpad/south/east
/// still steer the menu, so a bad config can always be repaired from
/// inside it.
pub fn navFromEvent(ev: input.Ev) ?NavEvent {
    switch (ev) {
        .key => |k| {
            if (!k.down or k.repeat) return null;
            return switch (k.scancode) {
                82 => .up,
                81 => .down,
                80 => .left,
                79 => .right,
                40 => .confirm, // Enter
                41 => .back, // Esc
                else => null,
            };
        },
        .pad_button => |pb| {
            if (!pb.down) return null;
            return switch (pb.button) {
                11 => .up,
                12 => .down,
                13 => .left,
                14 => .right,
                0 => .confirm, // south
                1 => .back, // east
                6 => .close, // start
                else => null,
            };
        },
        else => return null,
    }
}

pub fn itemCount(page: Page) usize {
    return switch (page) {
        .main => 7,
        .settings => 3,
        .input_menu => 6,
        .map => input.n_snes_buttons,
        .hotkeys => input.n_hotkeys,
    };
}

fn itemLabel(page: Page, i: usize) []const u8 {
    return switch (page) {
        .main => ([_][]const u8{ "RESUME", "SAVE STATE", "LOAD STATE", "SETTINGS", "INPUT", "RESET", "QUIT" })[i],
        .settings => ([_][]const u8{ "SCALE", "AUDIO", "SHADER" })[i],
        .input_menu => ([_][]const u8{ "PLAYER 1 KEYBOARD", "PLAYER 1 PAD", "PLAYER 2 KEYBOARD", "PLAYER 2 PAD", "HOTKEYS", "SWAP PADS" })[i],
        .map => @tagName(@as(input.SnesButton, @enumFromInt(i))),
        .hotkeys => @tagName(@as(input.Hotkey, @enumFromInt(i))),
    };
}

fn itemValue(page: Page, i: usize, cfg: *const config.Config, shader_name: ?[]const u8, buf: []u8) []const u8 {
    switch (page) {
        .main => return "",
        .settings => switch (i) {
            0 => return std.fmt.bufPrint(buf, "{d}", .{cfg.video.scale}) catch "",
            1 => return if (cfg.audio.enabled) "ON" else "OFF",
            2 => return shader_name orelse "(NONE)",
            else => return "",
        },
        .input_menu => switch (i) {
            5 => return if (cfg.input.swap_pads) "ON" else "OFF",
            else => return ">",
        },
        .map => |t| {
            const map = mapOfConst(cfg, t.player, t.device);
            const tokens = mapGet(map, @enumFromInt(i));
            return if (tokens.len == 0) "-" else tokens;
        },
        .hotkeys => return cfg.input.hotkeys.get(@enumFromInt(i)),
    }
}

fn mapOf(cfg: *config.Config, player: u1, device: Device) *input.MapStrings {
    return switch (device) {
        .keys => if (player == 0) &cfg.input.p1_keys else &cfg.input.p2_keys,
        .pad => if (player == 0) &cfg.input.p1_pad else &cfg.input.p2_pad,
    };
}

fn mapOfConst(cfg: *const config.Config, player: u1, device: Device) *const input.MapStrings {
    return switch (device) {
        .keys => if (player == 0) &cfg.input.p1_keys else &cfg.input.p2_keys,
        .pad => if (player == 0) &cfg.input.p1_pad else &cfg.input.p2_pad,
    };
}

fn mapGet(map: *const input.MapStrings, btn: input.SnesButton) []const u8 {
    return map.get(btn);
}

fn mapSet(map: *input.MapStrings, btn: input.SnesButton, value: []const u8) void {
    switch (btn) {
        inline else => |t| @field(map, @tagName(t)) = value,
    }
}

fn hotkeySet(hks: *input.HotkeyStrings, hk: input.Hotkey, value: []const u8) void {
    switch (hk) {
        inline else => |t| @field(hks, @tagName(t)) = value,
    }
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "menu: navigation wraps, submenus push, back pops, top-level back resumes" {
    var cfg: config.Config = .{};
    var m = Menu.init();

    try testing.expectEqual(Request.none, m.handleNav(&cfg, .up, false));
    try testing.expectEqual(@as(usize, 6), m.top().cursor); // wrapped to QUIT

    m.top().cursor = 3; // SETTINGS
    try testing.expectEqual(Request.none, m.handleNav(&cfg, .confirm, false));
    try testing.expectEqual(Page.settings, m.top().page);

    try testing.expectEqual(Request.none, m.handleNav(&cfg, .back, false));
    try testing.expectEqual(Page.main, m.top().page);
    try testing.expectEqual(Request.resume_game, m.handleNav(&cfg, .back, false));
}

test "menu: main-page actions map to their requests" {
    var cfg: config.Config = .{};
    var m = Menu.init();
    m.top().cursor = 1;
    try testing.expectEqual(Request.save_state, m.handleNav(&cfg, .confirm, false));
    m.top().cursor = 6;
    try testing.expectEqual(Request.quit, m.handleNav(&cfg, .confirm, false));
}

test "menu: settings edit the config and report dirty" {
    var cfg: config.Config = .{};
    var m = Menu.init();
    m.top().cursor = 3;
    _ = m.handleNav(&cfg, .confirm, false); // into settings

    // Scale saturates at both ends.
    try testing.expectEqual(Request.config_dirty, m.handleNav(&cfg, .right, false));
    try testing.expectEqual(@as(u32, 4), cfg.video.scale);
    cfg.video.scale = 8;
    _ = m.handleNav(&cfg, .right, false);
    try testing.expectEqual(@as(u32, 8), cfg.video.scale);

    // Audio toggles on confirm.
    _ = m.handleNav(&cfg, .down, false);
    try testing.expectEqual(Request.config_dirty, m.handleNav(&cfg, .confirm, false));
    try testing.expectEqual(false, cfg.audio.enabled);

    // Shader row is inert on the software path, live with a chain.
    _ = m.handleNav(&cfg, .down, false);
    try testing.expectEqual(Request.none, m.handleNav(&cfg, .right, false));
    try testing.expectEqual(Request.shader_next, m.handleNav(&cfg, .right, true));
    try testing.expectEqual(Request.shader_prev, m.handleNav(&cfg, .left, true));
}

test "menu: remap capture rewrites the map and auto-swaps conflicts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var cfg: config.Config = .{};
    var m = Menu.init();
    m.top().cursor = 4;
    _ = m.handleNav(&cfg, .confirm, false); // input menu
    _ = m.handleNav(&cfg, .confirm, false); // P1 keyboard map
    try testing.expectEqual(Page{ .map = .{ .player = 0, .device = .keys } }, m.top().page);

    // Capture 'z' (scancode 29) for SNES A. 'z' was B's key: B inherits A's
    // old 'x' so no two SNES buttons share a key.
    m.top().cursor = @intFromEnum(input.SnesButton.a);
    _ = m.handleNav(&cfg, .confirm, false);
    try testing.expect(m.capturing());
    try testing.expectEqual(
        Request.config_dirty,
        m.feedCapture(a, &cfg, .{ .key = .{ .scancode = 29, .down = true, .repeat = false } }),
    );
    try testing.expectEqualStrings("z", cfg.input.p1_keys.a);
    try testing.expectEqualStrings("x", cfg.input.p1_keys.b);

    // A keyboard capture ignores pad events entirely.
    m.top().cursor = @intFromEnum(input.SnesButton.y);
    _ = m.handleNav(&cfg, .confirm, false);
    try testing.expectEqual(
        Request.none,
        m.feedCapture(a, &cfg, .{ .pad_button = .{ .pad = 1, .button = 0, .down = true } }),
    );
    try testing.expect(m.capturing());

    // Esc cancels without binding.
    _ = m.feedCapture(a, &cfg, .{ .key = .{ .scancode = 41, .down = true, .repeat = false } });
    try testing.expect(!m.capturing());
    try testing.expectEqualStrings("a", cfg.input.p1_keys.y);
}

test "menu: capture times out back to browsing" {
    var cfg: config.Config = .{};
    var m = Menu.init();
    m.top().cursor = 4;
    _ = m.handleNav(&cfg, .confirm, false);
    _ = m.handleNav(&cfg, .confirm, false);
    _ = m.handleNav(&cfg, .confirm, false); // start capture on UP
    try testing.expect(m.capturing());
    for (0..capture_frames) |_| m.tick();
    try testing.expect(!m.capturing());
}

test "menu: draw renders every page without touching out-of-bounds pixels" {
    var cfg: config.Config = .{};
    var buf: [256 * 224]u16 = @splat(0x1234);
    const s = ui.Surface.init(buf[0 .. 256 * 224], 256, 224);

    var m = Menu.init();
    m.draw(&s, &cfg, null);
    m.top().cursor = 4;
    _ = m.handleNav(&cfg, .confirm, false);
    m.draw(&s, &cfg, "crt-royale");
    _ = m.handleNav(&cfg, .confirm, false);
    m.draw(&s, &cfg, null); // remap page, with a capture bar
    _ = m.handleNav(&cfg, .confirm, false);
    m.draw(&s, &cfg, null);

    // A 239-line overscan frame and a hi-res frame lay out cleanly too.
    var big: [512 * 239]u16 = @splat(0);
    const hs = ui.Surface.init(big[0 .. 512 * 239], 512, 239);
    m.draw(&hs, &cfg, null);
}
