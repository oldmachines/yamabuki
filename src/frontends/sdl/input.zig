//! The input model: bindings, gamepad slots, and event resolution.
//!
//! Everything here is pure logic. The SDL loop converts each SDL event into
//! an `Ev` and feeds it through `State.handle`, which updates the two
//! players' SNES button masks and reports any hotkey `Action` — so the whole
//! model (two players, keyboard + pad per player, axis hysteresis, hotplug
//! slot assignment) is unit-tested with synthesized events, no SDL required.
//!
//! Bindings live in the config as space-separated token lists, human-editable
//! and human-diffable:
//!
//!   keyboard maps  scancode names          `up`, `z`, `rshift`, `#41`
//!   pad maps       buttons and half-axes   `south`, `dpad_up`, `-lefty`, `+rt`
//!   hotkeys        device-prefixed         `key:escape`, `pad:guide`, `axis:+rt`
//!
//! The defaults reproduce the layout the frontend has always had (RetroArch
//! keyboard defaults, Tab fast-forward, F1/F5/F9) plus the positional SNES
//! pad map every controller era agrees on: south=B, east=A, west=Y, north=X.

const std = @import("std");
const core = @import("snes_core");

const Button = core.joypad.Button;

/// The 12 SNES pad buttons, in the order the binding maps store them.
pub const SnesButton = enum(u4) {
    up,
    down,
    left,
    right,
    a,
    b,
    x,
    y,
    l,
    r,
    start,
    select,

    pub fn mask(self: SnesButton) u16 {
        return switch (self) {
            .up => Button.up,
            .down => Button.down,
            .left => Button.left,
            .right => Button.right,
            .a => Button.a,
            .b => Button.b,
            .x => Button.x,
            .y => Button.y,
            .l => Button.l,
            .r => Button.r,
            .start => Button.start,
            .select => Button.select,
        };
    }
};

pub const n_snes_buttons = @typeInfo(SnesButton).@"enum".fields.len;

/// One way to trigger something: a key, a pad button, or a pushed half-axis.
pub const Binding = union(enum) {
    key: u32, // SDL scancode
    pad_button: u8, // SDL_GamepadButton
    pad_axis: HalfAxis,

    pub const HalfAxis = struct { axis: u8, positive: bool };
};

/// An axis engages past this and releases below `axis_release` — the gap is
/// the hysteresis that stops a stick resting near the threshold from
/// machine-gunning the d-pad.
pub const axis_engage: i16 = 8000;
pub const axis_release: i16 = 6000;

// ---------------------------------------------------------------------------
// Token parsing / formatting

/// SDL scancode names (SDL_scancode.h, USB HID usage values; stable). The
/// table covers every key a SNES layout plausibly binds; anything else still
/// binds via the numeric `#N` form, which `formatKey` emits for unnamed
/// codes so a remap capture can never produce an unparseable config.
const key_names = [_]struct { name: []const u8, code: u32 }{
    .{ .name = "a", .code = 4 },             .{ .name = "b", .code = 5 },
    .{ .name = "c", .code = 6 },             .{ .name = "d", .code = 7 },
    .{ .name = "e", .code = 8 },             .{ .name = "f", .code = 9 },
    .{ .name = "g", .code = 10 },            .{ .name = "h", .code = 11 },
    .{ .name = "i", .code = 12 },            .{ .name = "j", .code = 13 },
    .{ .name = "k", .code = 14 },            .{ .name = "l", .code = 15 },
    .{ .name = "m", .code = 16 },            .{ .name = "n", .code = 17 },
    .{ .name = "o", .code = 18 },            .{ .name = "p", .code = 19 },
    .{ .name = "q", .code = 20 },            .{ .name = "r", .code = 21 },
    .{ .name = "s", .code = 22 },            .{ .name = "t", .code = 23 },
    .{ .name = "u", .code = 24 },            .{ .name = "v", .code = 25 },
    .{ .name = "w", .code = 26 },            .{ .name = "x", .code = 27 },
    .{ .name = "y", .code = 28 },            .{ .name = "z", .code = 29 },
    .{ .name = "1", .code = 30 },            .{ .name = "2", .code = 31 },
    .{ .name = "3", .code = 32 },            .{ .name = "4", .code = 33 },
    .{ .name = "5", .code = 34 },            .{ .name = "6", .code = 35 },
    .{ .name = "7", .code = 36 },            .{ .name = "8", .code = 37 },
    .{ .name = "9", .code = 38 },            .{ .name = "0", .code = 39 },
    .{ .name = "return", .code = 40 },       .{ .name = "escape", .code = 41 },
    .{ .name = "backspace", .code = 42 },    .{ .name = "tab", .code = 43 },
    .{ .name = "space", .code = 44 },        .{ .name = "minus", .code = 45 },
    .{ .name = "equals", .code = 46 },       .{ .name = "leftbracket", .code = 47 },
    .{ .name = "rightbracket", .code = 48 }, .{ .name = "backslash", .code = 49 },
    .{ .name = "semicolon", .code = 51 },    .{ .name = "apostrophe", .code = 52 },
    .{ .name = "grave", .code = 53 },        .{ .name = "comma", .code = 54 },
    .{ .name = "period", .code = 55 },       .{ .name = "slash", .code = 56 },
    .{ .name = "f1", .code = 58 },           .{ .name = "f2", .code = 59 },
    .{ .name = "f3", .code = 60 },           .{ .name = "f4", .code = 61 },
    .{ .name = "f5", .code = 62 },           .{ .name = "f6", .code = 63 },
    .{ .name = "f7", .code = 64 },           .{ .name = "f8", .code = 65 },
    .{ .name = "f9", .code = 66 },           .{ .name = "f10", .code = 67 },
    .{ .name = "f11", .code = 68 },          .{ .name = "f12", .code = 69 },
    .{ .name = "insert", .code = 73 },       .{ .name = "home", .code = 74 },
    .{ .name = "pageup", .code = 75 },       .{ .name = "delete", .code = 76 },
    .{ .name = "end", .code = 77 },          .{ .name = "pagedown", .code = 78 },
    .{ .name = "right", .code = 79 },        .{ .name = "left", .code = 80 },
    .{ .name = "down", .code = 81 },         .{ .name = "up", .code = 82 },
    .{ .name = "lctrl", .code = 224 },       .{ .name = "lshift", .code = 225 },
    .{ .name = "lalt", .code = 226 },        .{ .name = "rctrl", .code = 228 },
    .{ .name = "rshift", .code = 229 },      .{ .name = "ralt", .code = 230 },
};

/// SDL_GamepadButton names (SDL_gamepad.h). Positional, not lettered — a
/// SNES pad, an Xbox pad, and a DualShock disagree about letters but agree
/// about where the buttons are.
const pad_button_names = [_]struct { name: []const u8, code: u8 }{
    .{ .name = "south", .code = 0 },
    .{ .name = "east", .code = 1 },
    .{ .name = "west", .code = 2 },
    .{ .name = "north", .code = 3 },
    .{ .name = "back", .code = 4 },
    .{ .name = "guide", .code = 5 },
    .{ .name = "start", .code = 6 },
    .{ .name = "lstick", .code = 7 },
    .{ .name = "rstick", .code = 8 },
    .{ .name = "lb", .code = 9 },
    .{ .name = "rb", .code = 10 },
    .{ .name = "dpad_up", .code = 11 },
    .{ .name = "dpad_down", .code = 12 },
    .{ .name = "dpad_left", .code = 13 },
    .{ .name = "dpad_right", .code = 14 },
};

/// SDL_GamepadAxis names, bindable per half: `-lefty` is stick-up, `+rt` is
/// a pulled right trigger.
const axis_names = [_]struct { name: []const u8, code: u8 }{
    .{ .name = "leftx", .code = 0 },
    .{ .name = "lefty", .code = 1 },
    .{ .name = "rightx", .code = 2 },
    .{ .name = "righty", .code = 3 },
    .{ .name = "lt", .code = 4 },
    .{ .name = "rt", .code = 5 },
};

pub fn parseKeyName(name: []const u8) ?u32 {
    if (name.len >= 2 and name[0] == '#')
        return std.fmt.parseInt(u32, name[1..], 10) catch null;
    for (key_names) |k| {
        if (std.mem.eql(u8, k.name, name)) return k.code;
    }
    return null;
}

pub fn keyName(code: u32) ?[]const u8 {
    for (key_names) |k| {
        if (k.code == code) return k.name;
    }
    return null;
}

/// A pad-map token: a button name or a signed half-axis.
pub fn parsePadToken(tok: []const u8) ?Binding {
    if (tok.len >= 2 and (tok[0] == '+' or tok[0] == '-')) {
        for (axis_names) |a| {
            if (std.mem.eql(u8, a.name, tok[1..]))
                return .{ .pad_axis = .{ .axis = a.code, .positive = tok[0] == '+' } };
        }
        return null;
    }
    for (pad_button_names) |b| {
        if (std.mem.eql(u8, b.name, tok)) return .{ .pad_button = b.code };
    }
    return null;
}

fn padButtonName(code: u8) ?[]const u8 {
    for (pad_button_names) |b| {
        if (b.code == code) return b.name;
    }
    return null;
}

fn axisName(code: u8) ?[]const u8 {
    for (axis_names) |a| {
        if (a.code == code) return a.name;
    }
    return null;
}

/// The reverse of the map-token grammar, for the remap capture: a key by
/// name (or `#N` when unnamed — capture must never produce an unparseable
/// config), a pad button by name, a half-axis with its sign.
pub fn formatMapToken(gpa: std.mem.Allocator, b: Binding) ![]const u8 {
    return switch (b) {
        .key => |code| if (keyName(code)) |n| n else std.fmt.allocPrint(gpa, "#{d}", .{code}),
        .pad_button => |code| padButtonName(code) orelse std.fmt.allocPrint(gpa, "#{d}", .{code}),
        .pad_axis => |ax| std.fmt.allocPrint(gpa, "{c}{s}", .{
            @as(u8, if (ax.positive) '+' else '-'),
            axisName(ax.axis) orelse "leftx",
        }),
    };
}

/// The reverse of the hotkey-token grammar.
pub fn formatHotkeyToken(gpa: std.mem.Allocator, b: Binding) ![]const u8 {
    return switch (b) {
        .key => std.fmt.allocPrint(gpa, "key:{s}", .{try formatMapToken(gpa, b)}),
        .pad_button => std.fmt.allocPrint(gpa, "pad:{s}", .{try formatMapToken(gpa, b)}),
        .pad_axis => std.fmt.allocPrint(gpa, "axis:{s}", .{try formatMapToken(gpa, b)}),
    };
}

/// A hotkey token carries its device: `key:f5`, `pad:guide`, `axis:+rt`.
pub fn parseHotkeyToken(tok: []const u8) ?Binding {
    if (std.mem.startsWith(u8, tok, "key:")) {
        const code = parseKeyName(tok[4..]) orelse return null;
        return .{ .key = code };
    }
    if (std.mem.startsWith(u8, tok, "pad:")) {
        const b = parsePadToken(tok[4..]) orelse return null;
        if (b == .pad_axis) return null; // axes spell it `axis:`
        return b;
    }
    if (std.mem.startsWith(u8, tok, "axis:")) {
        const b = parsePadToken(tok[5..]) orelse return null;
        if (b != .pad_axis) return null;
        return b;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Resolved bindings

/// Everything a hotkey can do. `fast_forward` is a held state, not an edge —
/// the payload is "is it held now", already combined across every bound
/// trigger (Tab *or* a pulled trigger).
pub const Hotkey = enum(u4) {
    menu,
    fast_forward,
    rewind,
    pause,
    save_state,
    load_state,
    slot_next,
    slot_prev,
    screenshot,
    reset,
    record_movie,
    info,
};

pub const n_hotkeys = @typeInfo(Hotkey).@"enum".fields.len;

/// At most this many bindings per SNES button or hotkey. Overflow warns at
/// resolve time and drops the extras — a config problem, never a crash.
pub const max_binds = 4;

const BindList = struct {
    items: [max_binds]Binding = undefined,
    len: usize = 0,

    fn append(self: *BindList, b: Binding) bool {
        if (self.len == max_binds) return false;
        self.items[self.len] = b;
        self.len += 1;
        return true;
    }

    fn slice(self: *const BindList) []const Binding {
        return self.items[0..self.len];
    }
};

pub const PlayerBinds = struct {
    /// Keyboard bindings per SNES button.
    keys: [n_snes_buttons]BindList = @splat(.{}),
    /// Pad bindings (buttons and half-axes) per SNES button.
    pad: [n_snes_buttons]BindList = @splat(.{}),
};

/// The runtime form of the config's string maps, parsed once at startup.
pub const Resolved = struct {
    players: [2]PlayerBinds = .{ .{}, .{} },
    hotkeys: [n_hotkeys]BindList = @splat(.{}),
    /// Physical pad 1 drives player 2 and vice versa.
    swap_pads: bool = false,
};

/// The string maps as they appear in the config. Each field is a
/// space-separated token list; empty means unbound.
pub const MapStrings = struct {
    up: []const u8 = "",
    down: []const u8 = "",
    left: []const u8 = "",
    right: []const u8 = "",
    a: []const u8 = "",
    b: []const u8 = "",
    x: []const u8 = "",
    y: []const u8 = "",
    l: []const u8 = "",
    r: []const u8 = "",
    start: []const u8 = "",
    select: []const u8 = "",

    pub fn get(self: *const MapStrings, btn: SnesButton) []const u8 {
        return switch (btn) {
            inline else => |t| @field(self, @tagName(t)),
        };
    }
};

pub const HotkeyStrings = struct {
    /// Opens the overlay menu (which is where quitting lives now). The
    /// guide button is safe to bind by default because no SNES game can
    /// see it; start+select stays unbound so games that ask for it keep it.
    menu: []const u8 = "key:escape pad:guide",
    fast_forward: []const u8 = "key:tab axis:+rt",
    rewind: []const u8 = "key:backspace",
    pause: []const u8 = "key:p",
    save_state: []const u8 = "key:f5",
    load_state: []const u8 = "key:f9",
    slot_next: []const u8 = "key:f7",
    slot_prev: []const u8 = "key:f6",
    screenshot: []const u8 = "key:f12",
    reset: []const u8 = "key:f1",
    /// Toggle input-movie recording: starts with a repower (movies replay
    /// from power-on), stops by writing the .ymv into the movies directory.
    record_movie: []const u8 = "key:f10",
    /// Toggle the session info palette: game, patch, volume, save states.
    /// `i` is free in the historical keyboard layout (the SNES buttons sit
    /// on z/x/a/s/q/w and the hotkeys on F-keys, Tab, and P).
    info: []const u8 = "key:i",

    pub fn get(self: *const HotkeyStrings, hk: Hotkey) []const u8 {
        return switch (hk) {
            inline else => |t| @field(self, @tagName(t)),
        };
    }
};

/// The config's input section. Defaults reproduce the frontend's historical
/// layout on the keyboard and add the positional pad map for both players.
pub const InputConfig = struct {
    p1_keys: MapStrings = .{
        .up = "up",
        .down = "down",
        .left = "left",
        .right = "right",
        .b = "z",
        .a = "x",
        .y = "a",
        .x = "s",
        .l = "q",
        .r = "w",
        .start = "return",
        .select = "rshift",
    },
    p2_keys: MapStrings = .{},
    p1_pad: MapStrings = default_pad_map,
    p2_pad: MapStrings = default_pad_map,
    hotkeys: HotkeyStrings = .{},
    swap_pads: bool = false,

    pub const default_pad_map: MapStrings = .{
        .up = "dpad_up -lefty",
        .down = "dpad_down +lefty",
        .left = "dpad_left -leftx",
        .right = "dpad_right +leftx",
        .b = "south",
        .a = "east",
        .y = "west",
        .x = "north",
        .l = "lb",
        .r = "rb",
        .start = "start",
        .select = "back",
    };
};

/// Parse the config's string maps into `Resolved`. Unknown or surplus
/// tokens warn on `err` (once each) and are skipped: a typo in a hand-edited
/// config costs that one binding, never the session.
pub fn resolve(cfg: *const InputConfig, err: *std.Io.Writer) Resolved {
    var r: Resolved = .{ .swap_pads = cfg.swap_pads };
    const key_maps = [2]*const MapStrings{ &cfg.p1_keys, &cfg.p2_keys };
    const pad_maps = [2]*const MapStrings{ &cfg.p1_pad, &cfg.p2_pad };
    for (0..2) |p| {
        inline for (@typeInfo(SnesButton).@"enum".fields) |f| {
            const btn: SnesButton = @enumFromInt(f.value);
            resolveList(key_maps[p].get(btn), .key, &r.players[p].keys[f.value], f.name, err);
            resolveList(pad_maps[p].get(btn), .pad, &r.players[p].pad[f.value], f.name, err);
        }
    }
    inline for (@typeInfo(Hotkey).@"enum".fields) |f| {
        const hk: Hotkey = @enumFromInt(f.value);
        resolveList(cfg.hotkeys.get(hk), .hotkey, &r.hotkeys[f.value], f.name, err);
    }
    return r;
}

const TokenKind = enum { key, pad, hotkey };

fn resolveList(tokens: []const u8, kind: TokenKind, out: *BindList, what: []const u8, err: *std.Io.Writer) void {
    var it = std.mem.tokenizeScalar(u8, tokens, ' ');
    while (it.next()) |tok| {
        const b: ?Binding = switch (kind) {
            .key => if (parseKeyName(tok)) |c| .{ .key = c } else null,
            .pad => parsePadToken(tok),
            .hotkey => parseHotkeyToken(tok),
        };
        if (b) |binding| {
            if (!out.append(binding)) {
                err.print("warning: input: too many bindings for '{s}' (max {d}), '{s}' dropped\n", .{ what, max_binds, tok }) catch {};
                err.flush() catch {};
            }
        } else {
            err.print("warning: input: unknown binding '{s}' for '{s}' — skipped\n", .{ tok, what }) catch {};
            err.flush() catch {};
        }
    }
}

// ---------------------------------------------------------------------------
// Event resolution

/// A normalized input event. The SDL loop builds these from SDL events; the
/// tests build them directly.
pub const Ev = union(enum) {
    key: struct { scancode: u32, down: bool, repeat: bool },
    pad_button: struct { pad: u32, button: u8, down: bool },
    pad_axis: struct { pad: u32, axis: u8, value: i16 },
    pad_added: struct { pad: u32 },
    pad_removed: struct { pad: u32 },
};

/// What the frame loop should do about an event, beyond the button masks
/// and the fast-forward hold it polls from `State` every frame.
pub const Action = union(enum) {
    none,
    menu,
    pause,
    save_state,
    load_state,
    slot_next,
    slot_prev,
    screenshot,
    reset,
    record_movie,
    info,
    /// A pad was assigned to a player slot — open it and keep the handle.
    pad_opened: struct { pad: u32, slot: u1 },
    /// A pad left its slot — close the handle.
    pad_closed: struct { pad: u32, slot: u1 },
};

pub const State = struct {
    /// Live SNES button masks, one per port; the loop pushes these into
    /// `setButtons` every frame.
    masks: [2]u16 = .{ 0, 0 },
    /// Which joystick instance occupies each player slot.
    slots: [2]?u32 = .{ null, null },
    /// Half-axis engagement, for hysteresis: [player][axis][positive].
    axis_on: [2][6][2]bool = @splat(@splat(@splat(false))),
    /// Per-source holds for the held hotkeys, OR-combined per hotkey.
    ff_key: bool = false,
    ff_pad: bool = false,
    ff_axis: bool = false,
    rw_key: bool = false,
    rw_pad: bool = false,

    pub fn ffHeld(self: *const State) bool {
        return self.ff_key or self.ff_pad or self.ff_axis;
    }

    pub fn rewindHeld(self: *const State) bool {
        return self.rw_key or self.rw_pad;
    }

    /// Drop everything held but keep the pad slots: the overlay menu eats
    /// the release events while it is open, so anything still "down" when
    /// it opened would stay down forever without this.
    pub fn clearTransient(self: *State) void {
        self.masks = .{ 0, 0 };
        self.axis_on = @splat(@splat(@splat(false)));
        self.ff_key = false;
        self.ff_pad = false;
        self.ff_axis = false;
        self.rw_key = false;
        self.rw_pad = false;
    }

    /// Feed one event through the bindings. Returns at most one action —
    /// SNES button changes land in `masks` and return `.none`.
    pub fn handle(self: *State, r: *const Resolved, ev: Ev) Action {
        switch (ev) {
            .key => |k| {
                for (0..2) |p| {
                    inline for (0..n_snes_buttons) |bi| {
                        for (r.players[p].keys[bi].slice()) |b| {
                            if (b.key == k.scancode)
                                self.setMask(@intCast(p), @enumFromInt(bi), k.down);
                        }
                    }
                }
                // The held hotkeys track both edges; the rest fire on down.
                if (!k.repeat and bound(r, .fast_forward, .{ .key = k.scancode }))
                    self.ff_key = k.down;
                if (!k.repeat and bound(r, .rewind, .{ .key = k.scancode }))
                    self.rw_key = k.down;
                if (k.down and !k.repeat) {
                    if (matchHotkey(r, .{ .key = k.scancode })) |a| return a;
                }
                return .none;
            },
            .pad_button => |pb| {
                const p = self.slotOf(pb.pad) orelse return .none;
                inline for (0..n_snes_buttons) |bi| {
                    for (r.players[p].pad[bi].slice()) |b| {
                        switch (b) {
                            .pad_button => |code| if (code == pb.button)
                                self.setMask(p, @enumFromInt(bi), pb.down),
                            else => {},
                        }
                    }
                }
                if (bound(r, .fast_forward, .{ .pad_button = pb.button }))
                    self.ff_pad = pb.down;
                if (bound(r, .rewind, .{ .pad_button = pb.button }))
                    self.rw_pad = pb.down;
                if (pb.down) {
                    if (matchHotkey(r, .{ .pad_button = pb.button })) |a| return a;
                }
                return .none;
            },
            .pad_axis => |pa| {
                const p = self.slotOf(pa.pad) orelse return .none;
                // SDL only reports axes 0..5 for a gamepad, but that is
                // SDL's promise, not ours — an out-of-range axis must not
                // index out of `axis_on`.
                if (pa.axis >= 6) return .none;
                // Each half of the axis engages and releases independently.
                inline for ([2]bool{ false, true }) |positive| {
                    const v: i32 = if (positive) pa.value else -@as(i32, pa.value);
                    const was = self.axis_on[p][pa.axis][@intFromBool(positive)];
                    const now = if (was) v >= axis_release else v >= axis_engage;
                    if (now != was) {
                        self.axis_on[p][pa.axis][@intFromBool(positive)] = now;
                        const half: Binding.HalfAxis = .{ .axis = pa.axis, .positive = positive };
                        inline for (0..n_snes_buttons) |bi| {
                            for (r.players[p].pad[bi].slice()) |b| {
                                switch (b) {
                                    .pad_axis => |ax| if (ax.axis == half.axis and ax.positive == half.positive)
                                        self.setMask(p, @enumFromInt(bi), now),
                                    else => {},
                                }
                            }
                        }
                        if (bound(r, .fast_forward, .{ .pad_axis = half }))
                            self.ff_axis = self.anyFfAxisEngaged(r);
                    }
                }
                return .none;
            },
            .pad_added => |pa| {
                // Already assigned (SDL can re-announce) — nothing to do.
                if (self.slotOf(pa.pad) != null) return .none;
                const order: [2]u1 = if (r.swap_pads) .{ 1, 0 } else .{ 0, 1 };
                for (order) |slot| {
                    if (self.slots[slot] == null) {
                        self.slots[slot] = pa.pad;
                        return .{ .pad_opened = .{ .pad = pa.pad, .slot = slot } };
                    }
                }
                return .none; // both slots taken; a third pad idles
            },
            .pad_removed => |pr| {
                const p = self.slotOf(pr.pad) orelse return .none;
                self.slots[p] = null;
                // Whatever it held goes with it — a mid-jump unplug must not
                // leave the character running forever.
                self.masks[p] = 0;
                self.axis_on[p] = @splat(@splat(false));
                self.ff_axis = self.anyFfAxisEngaged(r);
                // Single flags cover both pads; releasing on any unplug is
                // the safe direction for a held hotkey.
                self.ff_pad = false;
                self.rw_pad = false;
                return .{ .pad_closed = .{ .pad = pr.pad, .slot = p } };
            },
        }
    }

    /// Is any ff-bound half-axis still engaged on any pad? Recomputed from
    /// scratch so an unplugged pad or a second trigger can never wedge
    /// fast-forward on or drop it while a source still holds it.
    fn anyFfAxisEngaged(self: *const State, r: *const Resolved) bool {
        for (r.hotkeys[@intFromEnum(Hotkey.fast_forward)].slice()) |b| {
            switch (b) {
                .pad_axis => |ax| {
                    for (0..2) |p| {
                        if (self.axis_on[p][ax.axis][@intFromBool(ax.positive)]) return true;
                    }
                },
                else => {},
            }
        }
        return false;
    }

    fn setMask(self: *State, player: u1, btn: SnesButton, down: bool) void {
        if (down) self.masks[player] |= btn.mask() else self.masks[player] &= ~btn.mask();
    }

    fn slotOf(self: *const State, pad: u32) ?u1 {
        for (self.slots, 0..) |s, i| {
            if (s == pad) return @intCast(i);
        }
        return null;
    }
};

/// Edge-triggered hotkeys only; fast_forward is a hold, tracked in `State`.
fn matchHotkey(r: *const Resolved, b: Binding) ?Action {
    inline for (@typeInfo(Hotkey).@"enum".fields) |f| {
        const hk: Hotkey = @enumFromInt(f.value);
        if (hk != .fast_forward and hk != .rewind and bound(r, hk, b)) {
            return switch (hk) {
                .menu => .menu,
                .pause => .pause,
                .save_state => .save_state,
                .load_state => .load_state,
                .slot_next => .slot_next,
                .slot_prev => .slot_prev,
                .screenshot => .screenshot,
                .reset => .reset,
                .record_movie => .record_movie,
                .info => .info,
                .fast_forward, .rewind => unreachable,
            };
        }
    }
    return null;
}

fn bound(r: *const Resolved, hk: Hotkey, b: Binding) bool {
    for (r.hotkeys[@intFromEnum(hk)].slice()) |candidate| {
        if (std.meta.eql(candidate, b)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn discardWriter(buf: []u8) std.Io.Writer.Discarding {
    return .init(buf);
}

fn defaultResolved() Resolved {
    var buf: [256]u8 = undefined;
    var sink = discardWriter(&buf);
    const cfg: InputConfig = .{};
    return resolve(&cfg, &sink.writer);
}

test "input: token parsing covers names, numeric fallback, and rejects typos" {
    try testing.expectEqual(@as(?u32, 41), parseKeyName("escape"));
    try testing.expectEqual(@as(?u32, 229), parseKeyName("rshift"));
    try testing.expectEqual(@as(?u32, 123), parseKeyName("#123"));
    try testing.expectEqual(@as(?u32, null), parseKeyName("escap"));

    try testing.expectEqual(Binding{ .pad_button = 0 }, parsePadToken("south").?);
    try testing.expectEqual(
        Binding{ .pad_axis = .{ .axis = 1, .positive = false } },
        parsePadToken("-lefty").?,
    );
    try testing.expectEqual(@as(?Binding, null), parsePadToken("norf"));

    try testing.expectEqual(Binding{ .key = 62 }, parseHotkeyToken("key:f5").?);
    try testing.expectEqual(Binding{ .pad_button = 5 }, parseHotkeyToken("pad:guide").?);
    try testing.expectEqual(
        Binding{ .pad_axis = .{ .axis = 5, .positive = true } },
        parseHotkeyToken("axis:+rt").?,
    );
    // Wrong prefix for the device: axes are not `pad:`, buttons not `axis:`.
    try testing.expectEqual(@as(?Binding, null), parseHotkeyToken("pad:+rt"));
    try testing.expectEqual(@as(?Binding, null), parseHotkeyToken("axis:south"));
    try testing.expectEqual(@as(?Binding, null), parseHotkeyToken("f5"));
}

test "input: default keyboard map reproduces the historical layout" {
    const r = defaultResolved();
    var st: State = .{};

    // Z is B, held; releasing clears it. (RetroArch keyboard defaults.)
    _ = st.handle(&r, .{ .key = .{ .scancode = 29, .down = true, .repeat = false } });
    try testing.expectEqual(Button.b, st.masks[0]);
    _ = st.handle(&r, .{ .key = .{ .scancode = 29, .down = false, .repeat = false } });
    try testing.expectEqual(@as(u16, 0), st.masks[0]);

    // Arrows + Enter + RShift.
    _ = st.handle(&r, .{ .key = .{ .scancode = 82, .down = true, .repeat = false } });
    _ = st.handle(&r, .{ .key = .{ .scancode = 40, .down = true, .repeat = false } });
    _ = st.handle(&r, .{ .key = .{ .scancode = 229, .down = true, .repeat = false } });
    try testing.expectEqual(Button.up | Button.start | Button.select, st.masks[0]);
    // The keyboard is player 1's: player 2 saw none of it.
    try testing.expectEqual(@as(u16, 0), st.masks[1]);
}

test "input: hotkeys fire on the down edge and ignore repeats" {
    const r = defaultResolved();
    var st: State = .{};

    try testing.expectEqual(Action.save_state, st.handle(&r, .{ .key = .{ .scancode = 62, .down = true, .repeat = false } }));
    try testing.expectEqual(Action.none, st.handle(&r, .{ .key = .{ .scancode = 62, .down = true, .repeat = true } }));
    try testing.expectEqual(Action.none, st.handle(&r, .{ .key = .{ .scancode = 62, .down = false, .repeat = false } }));
    try testing.expectEqual(Action.menu, st.handle(&r, .{ .key = .{ .scancode = 41, .down = true, .repeat = false } }));
}

test "input: fast-forward is a hold combined across key and trigger" {
    const r = defaultResolved();
    var st: State = .{};
    _ = st.handle(&r, .{ .pad_added = .{ .pad = 7 } });

    // Tab down: on.
    _ = st.handle(&r, .{ .key = .{ .scancode = 43, .down = true, .repeat = false } });
    try testing.expect(st.ffHeld());
    // Trigger pulled while Tab held, then Tab released: the trigger still
    // holds it.
    _ = st.handle(&r, .{ .pad_axis = .{ .pad = 7, .axis = 5, .value = 20000 } });
    _ = st.handle(&r, .{ .key = .{ .scancode = 43, .down = false, .repeat = false } });
    try testing.expect(st.ffHeld());
    // Trigger released: off.
    _ = st.handle(&r, .{ .pad_axis = .{ .pad = 7, .axis = 5, .value = 0 } });
    try testing.expect(!st.ffHeld());
}

test "input: an out-of-range axis is ignored, not a crash" {
    const r = defaultResolved();
    var st: State = .{};
    _ = st.handle(&r, .{ .pad_added = .{ .pad = 7 } });
    try testing.expectEqual(Action.none, st.handle(&r, .{ .pad_axis = .{ .pad = 7, .axis = 200, .value = 30000 } }));
    try testing.expectEqual(@as(u16, 0), st.masks[0]);
}

test "input: unplugging the pad that holds fast-forward releases it" {
    const r = defaultResolved();
    var st: State = .{};
    _ = st.handle(&r, .{ .pad_added = .{ .pad = 7 } });
    _ = st.handle(&r, .{ .pad_axis = .{ .pad = 7, .axis = 5, .value = 20000 } });
    try testing.expect(st.ffHeld());
    _ = st.handle(&r, .{ .pad_removed = .{ .pad = 7 } });
    try testing.expect(!st.ffHeld());
}

test "input: pad buttons drive the positional SNES map per slot" {
    const r = defaultResolved();
    var st: State = .{};
    _ = st.handle(&r, .{ .pad_added = .{ .pad = 10 } });
    _ = st.handle(&r, .{ .pad_added = .{ .pad = 20 } });

    // south = B on pad 1; east = A on pad 2. Independent masks.
    _ = st.handle(&r, .{ .pad_button = .{ .pad = 10, .button = 0, .down = true } });
    _ = st.handle(&r, .{ .pad_button = .{ .pad = 20, .button = 1, .down = true } });
    try testing.expectEqual(Button.b, st.masks[0]);
    try testing.expectEqual(Button.a, st.masks[1]);

    // An unassigned third pad is inert.
    _ = st.handle(&r, .{ .pad_button = .{ .pad = 99, .button = 0, .down = true } });
    try testing.expectEqual(Button.b, st.masks[0]);
}

test "input: left stick drives the d-pad with hysteresis" {
    const r = defaultResolved();
    var st: State = .{};
    _ = st.handle(&r, .{ .pad_added = .{ .pad = 3 } });

    // Push up past the engage threshold.
    _ = st.handle(&r, .{ .pad_axis = .{ .pad = 3, .axis = 1, .value = -9000 } });
    try testing.expectEqual(Button.up, st.masks[0]);
    // Drift back inside the hysteresis band: still held.
    _ = st.handle(&r, .{ .pad_axis = .{ .pad = 3, .axis = 1, .value = -6500 } });
    try testing.expectEqual(Button.up, st.masks[0]);
    // Below the release threshold: released.
    _ = st.handle(&r, .{ .pad_axis = .{ .pad = 3, .axis = 1, .value = -5000 } });
    try testing.expectEqual(@as(u16, 0), st.masks[0]);
    // Snapping across to hard down engages the other half.
    _ = st.handle(&r, .{ .pad_axis = .{ .pad = 3, .axis = 1, .value = 30000 } });
    try testing.expectEqual(Button.down, st.masks[0]);
}

test "input: hotplug fills slots in order, frees on unplug, refills" {
    const r = defaultResolved();
    var st: State = .{};

    try testing.expectEqual(Action{ .pad_opened = .{ .pad = 5, .slot = 0 } }, st.handle(&r, .{ .pad_added = .{ .pad = 5 } }));
    try testing.expectEqual(Action{ .pad_opened = .{ .pad = 6, .slot = 1 } }, st.handle(&r, .{ .pad_added = .{ .pad = 6 } }));
    // Third pad: both slots taken, idles.
    try testing.expectEqual(Action.none, st.handle(&r, .{ .pad_added = .{ .pad = 7 } }));

    // Player 1 is mid-press when the pad dies: its mask must clear.
    _ = st.handle(&r, .{ .pad_button = .{ .pad = 5, .button = 0, .down = true } });
    try testing.expectEqual(Action{ .pad_closed = .{ .pad = 5, .slot = 0 } }, st.handle(&r, .{ .pad_removed = .{ .pad = 5 } }));
    try testing.expectEqual(@as(u16, 0), st.masks[0]);

    // The next pad lands in the freed slot 0, not slot 2-of-2.
    try testing.expectEqual(Action{ .pad_opened = .{ .pad = 8, .slot = 0 } }, st.handle(&r, .{ .pad_added = .{ .pad = 8 } }));
}

test "input: swap_pads reverses slot assignment order" {
    var buf: [256]u8 = undefined;
    var sink = discardWriter(&buf);
    const cfg: InputConfig = .{ .swap_pads = true };
    const r = resolve(&cfg, &sink.writer);
    var st: State = .{};

    try testing.expectEqual(Action{ .pad_opened = .{ .pad = 1, .slot = 1 } }, st.handle(&r, .{ .pad_added = .{ .pad = 1 } }));
    try testing.expectEqual(Action{ .pad_opened = .{ .pad = 2, .slot = 0 } }, st.handle(&r, .{ .pad_added = .{ .pad = 2 } }));
}

test "input: capture tokens roundtrip through the parser" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Named key, unnamed key, pad button, both axis signs.
    try testing.expectEqualStrings("z", try formatMapToken(a, .{ .key = 29 }));
    try testing.expectEqualStrings("#105", try formatMapToken(a, .{ .key = 105 }));
    try testing.expectEqual(@as(?u32, 105), parseKeyName("#105"));
    try testing.expectEqualStrings("south", try formatMapToken(a, .{ .pad_button = 0 }));
    try testing.expectEqualStrings("+rt", try formatMapToken(a, .{ .pad_axis = .{ .axis = 5, .positive = true } }));
    try testing.expectEqualStrings("-lefty", try formatMapToken(a, .{ .pad_axis = .{ .axis = 1, .positive = false } }));

    // Every hotkey form parses back to the binding it came from.
    const samples = [_]Binding{
        .{ .key = 62 },
        .{ .pad_button = 5 },
        .{ .pad_axis = .{ .axis = 4, .positive = true } },
    };
    for (samples) |b| {
        const tok = try formatHotkeyToken(a, b);
        try testing.expectEqual(b, parseHotkeyToken(tok).?);
    }
}

test "input: unknown tokens are skipped with the rest of the list intact" {
    var buf: [1024]u8 = undefined;
    var sink = discardWriter(&buf);
    var cfg: InputConfig = .{};
    cfg.p1_keys.b = "zz z"; // one typo, one valid
    const r = resolve(&cfg, &sink.writer);

    var st: State = .{};
    _ = st.handle(&r, .{ .key = .{ .scancode = 29, .down = true, .repeat = false } });
    try testing.expectEqual(Button.b, st.masks[0]);
}
