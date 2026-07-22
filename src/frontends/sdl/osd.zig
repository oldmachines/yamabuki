//! On-screen toast: shows the active shader's name for a few seconds after a
//! `,`/`.` cycle, then disappears on its own.
//!
//! Text is a single texture (the whole message rasterized off a hand-drawn 5x7
//! font baked in as source, not a vendored asset) drawn as one quad with
//! `discard` cutting out the "off" pixels — that needs no blend state, so the
//! chain's `glDisable(BLEND)` at init is left alone. A second, untextured quad
//! behind it is the message's background bar. Both draw through one tiny GLSL
//! program compiled at runtime, exactly like the shader chain's own passes,
//! just with source this frontend writes instead of ones the baker emits.
//!
//! Independent of the shader chain: cycling presets never touches this, and a
//! preset that fails to compile still gets to show the toast for the one that
//! replaced it.

const std = @import("std");
const gl = @import("gl.zig");
const preset = @import("preset.zig");

const Size = preset.Size;

/// Which GLSL dialect the current GL context speaks — the same ladder
/// `main.zig` walks to pick a shader profile, reused here so the OSD compiles
/// on whichever rung the driver accepted.
pub const Dialect = enum { essl100, essl300, glsl330 };

pub const Box = struct { x: i32, y: i32, w: u32, h: u32 };

pub const Error = error{ ShaderCompile, ProgramLink };

const glyph_w = 5;
const glyph_h = 7;

/// How long a message stays up, in emulated frames (~60/s), before `draw`
/// stops drawing it on its own.
const show_frames: u32 = 150;

/// Longest message this OSD will rasterize. `preset.max_name` is already the
/// authoritative cap on a shader's name in this codebase.
const max_chars = preset.max_name;

// --- 5x7 font ----------------------------------------------------------
// Uppercase only (input is folded on lookup): a lowercase alphabet at this
// size needs ascenders and descenders to stay unambiguous, which a blocky
// dot-matrix face does not have room for, while capitals fit the box cleanly.
// Digits, a hyphen (shader names are kebab-case) and a blank space round out
// everything a preset name can contain.
//
// Each glyph is drawn here as art, not bits, so a mistake is visible on
// sight instead of hiding in a hand-packed byte.

fn parseGlyph(comptime art: []const u8) [glyph_h]u8 {
    var rows: [glyph_h]u8 = @splat(0);
    var row: usize = 0;
    var col: usize = 0;
    for (art) |c| {
        if (c == '\n') {
            row += 1;
            col = 0;
            continue;
        }
        if (row < glyph_h and col < glyph_w) {
            if (c == '#') rows[row] |= @as(u8, 1) << @intCast(glyph_w - 1 - col);
            col += 1;
        }
    }
    return rows;
}

fn glyphRows(c: u8) [glyph_h]u8 {
    return switch (std.ascii.toUpper(c)) {
        'A' => parseGlyph(
            \\.###.
            \\#...#
            \\#...#
            \\#####
            \\#...#
            \\#...#
            \\#...#
        ),
        'B' => parseGlyph(
            \\####.
            \\#...#
            \\#...#
            \\####.
            \\#...#
            \\#...#
            \\####.
        ),
        'C' => parseGlyph(
            \\.####
            \\#....
            \\#....
            \\#....
            \\#....
            \\#....
            \\.####
        ),
        'D' => parseGlyph(
            \\####.
            \\#...#
            \\#...#
            \\#...#
            \\#...#
            \\#...#
            \\####.
        ),
        'E' => parseGlyph(
            \\#####
            \\#....
            \\#....
            \\####.
            \\#....
            \\#....
            \\#####
        ),
        'F' => parseGlyph(
            \\#####
            \\#....
            \\#....
            \\####.
            \\#....
            \\#....
            \\#....
        ),
        'G' => parseGlyph(
            \\.####
            \\#....
            \\#....
            \\#.###
            \\#...#
            \\#...#
            \\.####
        ),
        'H' => parseGlyph(
            \\#...#
            \\#...#
            \\#...#
            \\#####
            \\#...#
            \\#...#
            \\#...#
        ),
        'I' => parseGlyph(
            \\#####
            \\..#..
            \\..#..
            \\..#..
            \\..#..
            \\..#..
            \\#####
        ),
        'J' => parseGlyph(
            \\..###
            \\...#.
            \\...#.
            \\...#.
            \\...#.
            \\#..#.
            \\.##..
        ),
        'K' => parseGlyph(
            \\#...#
            \\#..#.
            \\#.#..
            \\##...
            \\#.#..
            \\#..#.
            \\#...#
        ),
        'L' => parseGlyph(
            \\#....
            \\#....
            \\#....
            \\#....
            \\#....
            \\#....
            \\#####
        ),
        'M' => parseGlyph(
            \\#...#
            \\##.##
            \\#.#.#
            \\#.#.#
            \\#...#
            \\#...#
            \\#...#
        ),
        'N' => parseGlyph(
            \\#...#
            \\##..#
            \\#.#.#
            \\#.#.#
            \\#..##
            \\#...#
            \\#...#
        ),
        'O' => parseGlyph(
            \\.###.
            \\#...#
            \\#...#
            \\#...#
            \\#...#
            \\#...#
            \\.###.
        ),
        'P' => parseGlyph(
            \\####.
            \\#...#
            \\#...#
            \\####.
            \\#....
            \\#....
            \\#....
        ),
        'Q' => parseGlyph(
            \\.###.
            \\#...#
            \\#...#
            \\#...#
            \\#.#.#
            \\#..#.
            \\.##.#
        ),
        'R' => parseGlyph(
            \\####.
            \\#...#
            \\#...#
            \\####.
            \\#.#..
            \\#..#.
            \\#...#
        ),
        'S' => parseGlyph(
            \\.####
            \\#....
            \\#....
            \\.###.
            \\....#
            \\....#
            \\####.
        ),
        'T' => parseGlyph(
            \\#####
            \\..#..
            \\..#..
            \\..#..
            \\..#..
            \\..#..
            \\..#..
        ),
        'U' => parseGlyph(
            \\#...#
            \\#...#
            \\#...#
            \\#...#
            \\#...#
            \\#...#
            \\.###.
        ),
        'V' => parseGlyph(
            \\#...#
            \\#...#
            \\#...#
            \\#...#
            \\#...#
            \\.#.#.
            \\..#..
        ),
        'W' => parseGlyph(
            \\#...#
            \\#...#
            \\#...#
            \\#.#.#
            \\#.#.#
            \\##.##
            \\#...#
        ),
        'X' => parseGlyph(
            \\#...#
            \\#...#
            \\.#.#.
            \\..#..
            \\.#.#.
            \\#...#
            \\#...#
        ),
        'Y' => parseGlyph(
            \\#...#
            \\#...#
            \\.#.#.
            \\..#..
            \\..#..
            \\..#..
            \\..#..
        ),
        'Z' => parseGlyph(
            \\#####
            \\....#
            \\...#.
            \\..#..
            \\.#...
            \\#....
            \\#####
        ),
        '0' => parseGlyph(
            \\.###.
            \\#...#
            \\#...#
            \\#...#
            \\#...#
            \\#...#
            \\.###.
        ),
        '1' => parseGlyph(
            \\..#..
            \\.##..
            \\..#..
            \\..#..
            \\..#..
            \\..#..
            \\.###.
        ),
        '2' => parseGlyph(
            \\.###.
            \\#...#
            \\....#
            \\...#.
            \\..#..
            \\.#...
            \\#####
        ),
        '3' => parseGlyph(
            \\.###.
            \\#...#
            \\....#
            \\..##.
            \\....#
            \\#...#
            \\.###.
        ),
        '4' => parseGlyph(
            \\...#.
            \\..##.
            \\.#.#.
            \\#..#.
            \\#####
            \\...#.
            \\...#.
        ),
        '5' => parseGlyph(
            \\#####
            \\#....
            \\####.
            \\....#
            \\....#
            \\#...#
            \\.###.
        ),
        '6' => parseGlyph(
            \\..##.
            \\.#...
            \\#....
            \\####.
            \\#...#
            \\#...#
            \\.###.
        ),
        '7' => parseGlyph(
            \\#####
            \\....#
            \\...#.
            \\..#..
            \\.#...
            \\.#...
            \\.#...
        ),
        '8' => parseGlyph(
            \\.###.
            \\#...#
            \\#...#
            \\.###.
            \\#...#
            \\#...#
            \\.###.
        ),
        '9' => parseGlyph(
            \\.###.
            \\#...#
            \\#...#
            \\.####
            \\....#
            \\...#.
            \\.##..
        ),
        '-' => parseGlyph(
            \\.....
            \\.....
            \\.....
            \\#####
            \\.....
            \\.....
            \\.....
        ),
        else => parseGlyph( // unknown / space: blank
            \\.....
            \\.....
            \\.....
            \\.....
            \\.....
            \\.....
            \\.....
        ),
    };
}

/// Fill `buf` (RGBA8, `chars*(glyph_w+1)` wide, `glyph_h` tall, already
/// zeroed) with `text`. Alpha is the only channel that matters: 255 where a
/// pixel is lit, 0 everywhere else — including the one-pixel gap between
/// glyphs, which is what keeps letters from running together.
fn rasterize(buf: []u8, w: usize, text: []const u8) void {
    for (text, 0..) |c, i| {
        const rows = glyphRows(c);
        const x0 = i * (glyph_w + 1);
        for (0..glyph_h) |row| {
            const bits = rows[row];
            for (0..glyph_w) |col| {
                if ((bits >> @intCast(glyph_w - 1 - col)) & 1 == 0) continue;
                const idx = (row * w + x0 + col) * 4;
                buf[idx + 0] = 255;
                buf[idx + 1] = 255;
                buf[idx + 2] = 255;
                buf[idx + 3] = 255;
            }
        }
    }
}

// --- GL program ----------------------------------------------------------

const attribs = struct {
    const glsl330 =
        \\#version 330
        \\in vec2 aPos;
        \\in vec2 aUV;
        \\out vec2 vUV;
        \\void main() {
        \\    vUV = aUV;
        \\    gl_Position = vec4(aPos, 0.0, 1.0);
        \\}
    ;
    const essl300 =
        \\#version 300 es
        \\in vec2 aPos;
        \\in vec2 aUV;
        \\out vec2 vUV;
        \\void main() {
        \\    vUV = aUV;
        \\    gl_Position = vec4(aPos, 0.0, 1.0);
        \\}
    ;
    const essl100 =
        \\attribute vec2 aPos;
        \\attribute vec2 aUV;
        \\varying vec2 vUV;
        \\void main() {
        \\    vUV = aUV;
        \\    gl_Position = vec4(aPos, 0.0, 1.0);
        \\}
    ;
};

const frags = struct {
    const glsl330 =
        \\#version 330
        \\in vec2 vUV;
        \\out vec4 FragColor;
        \\uniform sampler2D tex;
        \\uniform vec4 color;
        \\uniform int useTex;
        \\void main() {
        \\    if (useTex != 0) {
        \\        if (texture(tex, vUV).a < 0.5) discard;
        \\    }
        \\    FragColor = color;
        \\}
    ;
    const essl300 =
        \\#version 300 es
        \\precision mediump float;
        \\in vec2 vUV;
        \\out vec4 FragColor;
        \\uniform sampler2D tex;
        \\uniform vec4 color;
        \\uniform int useTex;
        \\void main() {
        \\    if (useTex != 0) {
        \\        if (texture(tex, vUV).a < 0.5) discard;
        \\    }
        \\    FragColor = color;
        \\}
    ;
    const essl100 =
        \\precision mediump float;
        \\varying vec2 vUV;
        \\uniform sampler2D tex;
        \\uniform vec4 color;
        \\uniform int useTex;
        \\void main() {
        \\    if (useTex != 0) {
        \\        if (texture2D(tex, vUV).a < 0.5) discard;
        \\    }
        \\    gl_FragColor = color;
        \\}
    ;
};

fn source(dialect: Dialect, comptime which: enum { vert, frag }) []const u8 {
    const table = if (which == .vert) attribs else frags;
    return switch (dialect) {
        .glsl330 => table.glsl330,
        .essl300 => table.essl300,
        .essl100 => table.essl100,
    };
}

pub const Osd = struct {
    api: gl.Api,
    program: gl.Uint = 0,
    vbo: gl.Uint = 0,
    tex: gl.Uint = 0,
    a_pos: gl.Int = -1,
    a_uv: gl.Int = -1,
    u_tex: gl.Int = -1,
    u_color: gl.Int = -1,
    u_use_tex: gl.Int = -1,

    /// The message's rasterized size in texels, and how many frames of
    /// `draw` are left before it goes quiet again.
    text_w: u32 = 0,
    ttl: u32 = 0,

    pub fn init(api: gl.Api, dialect: Dialect) !Osd {
        var self: Osd = .{ .api = api };

        const vsh = try compile(api, gl.VERTEX_SHADER, source(dialect, .vert));
        defer api.glDeleteShader(vsh);
        const fsh = try compile(api, gl.FRAGMENT_SHADER, source(dialect, .frag));
        defer api.glDeleteShader(fsh);

        const prog = api.glCreateProgram();
        api.glAttachShader(prog, vsh);
        api.glAttachShader(prog, fsh);
        api.glLinkProgram(prog);
        var ok: gl.Int = 0;
        api.glGetProgramiv(prog, gl.LINK_STATUS, &ok);
        if (ok == gl.FALSE) {
            api.glDeleteProgram(prog);
            return Error.ProgramLink;
        }
        self.program = prog;
        self.a_pos = api.glGetAttribLocation(prog, "aPos");
        self.a_uv = api.glGetAttribLocation(prog, "aUV");
        self.u_tex = api.glGetUniformLocation(prog, "tex");
        self.u_color = api.glGetUniformLocation(prog, "color");
        self.u_use_tex = api.glGetUniformLocation(prog, "useTex");

        api.glGenBuffers(1, @ptrCast(&self.vbo));
        api.glGenTextures(1, @ptrCast(&self.tex));
        api.glBindTexture(gl.TEXTURE_2D, self.tex);
        api.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        api.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        api.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        api.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

        return self;
    }

    pub fn deinit(self: *Osd) void {
        const api = self.api;
        if (self.program != 0) api.glDeleteProgram(self.program);
        if (self.vbo != 0) api.glDeleteBuffers(1, @ptrCast(&self.vbo));
        if (self.tex != 0) api.glDeleteTextures(1, @ptrCast(&self.tex));
    }

    /// Rasterize `text` and start (or restart) the countdown. Truncates past
    /// `max_chars`, which no real preset name reaches.
    pub fn show(self: *Osd, text: []const u8) void {
        // Both bounds are cast to usize explicitly before this arithmetic:
        // @min narrows its result to the smallest type that fits a
        // comptime-known bound (max_chars needs 7 bits), and n * (glyph_w+1)
        // then overflows that narrow type well before it overflows usize.
        const n: usize = @min(text.len, @as(usize, max_chars));
        if (n == 0) return;
        const w: usize = n * @as(usize, glyph_w + 1);

        var buf: [max_chars * (glyph_w + 1) * glyph_h * 4]u8 = @splat(0);
        rasterize(buf[0 .. w * glyph_h * 4], w, text[0..n]);

        const api = self.api;
        api.glBindTexture(gl.TEXTURE_2D, self.tex);
        api.glPixelStorei(gl.UNPACK_ALIGNMENT, 4);
        api.glTexImage2D(gl.TEXTURE_2D, 0, gl.RGBA, @intCast(w), glyph_h, 0, gl.RGBA, gl.UNSIGNED_BYTE, buf[0..].ptr);

        self.text_w = @intCast(w);
        self.ttl = show_frames;
    }

    /// Draw the toast if one is live, and count it one frame closer to gone.
    /// Called after the shader chain's own `render`, before the swap — the
    /// caller must reset the viewport to the *whole* window first (the chain
    /// leaves it letterboxed to the picture).
    pub fn draw(self: *Osd, window: Size, box: Box) void {
        if (self.ttl == 0) return;
        self.ttl -= 1;
        if (self.text_w == 0) return;

        const api = self.api;
        // The same density as the console's own pixels, so the toast reads
        // like part of the picture rather than a UI layer at a different
        // scale — e.g. a 3x window scale means each font pixel is a 3x3 block.
        const scale: f32 = @floatFromInt(@max(1, box.h / 224));
        const pad = 2 * scale;
        const margin = 3 * scale;

        const text_w_px = @as(f32, @floatFromInt(self.text_w)) * scale;
        const text_h_px = @as(f32, glyph_h) * scale;
        const bar_w = text_w_px + 2 * pad;
        const bar_h = text_h_px + 2 * pad;

        const bar_left = @as(f32, @floatFromInt(box.x)) + (@as(f32, @floatFromInt(box.w)) - bar_w) / 2;
        const bar_bottom = @as(f32, @floatFromInt(box.y)) + margin;

        api.glViewport(0, 0, @intCast(window.w), @intCast(window.h));
        api.glUseProgram(self.program);
        api.glBindBuffer(gl.ARRAY_BUFFER, self.vbo);
        if (self.a_pos >= 0) api.glEnableVertexAttribArray(@intCast(self.a_pos));
        if (self.a_uv >= 0) api.glEnableVertexAttribArray(@intCast(self.a_uv));

        // Background bar: opaque, no texture.
        api.glUniform1i(self.u_use_tex, 0);
        api.glUniform4fv(self.u_color, 1, &[4]f32{ 0, 0, 0, 1 });
        self.drawQuad(
            window,
            bar_left,
            bar_bottom,
            bar_w,
            bar_h,
            .{ 0, 0, 1, 1 },
        );

        // Text: same quad shape, one texel bigger inset on every side than
        // the bar, sampling the message texture with the "off" pixels cut.
        api.glActiveTexture(gl.TEXTURE0);
        api.glBindTexture(gl.TEXTURE_2D, self.tex);
        api.glUniform1i(self.u_tex, 0);
        api.glUniform1i(self.u_use_tex, 1);
        api.glUniform4fv(self.u_color, 1, &[4]f32{ 1, 1, 1, 1 });
        self.drawQuad(
            window,
            bar_left + pad,
            bar_bottom + pad,
            text_w_px,
            text_h_px,
            .{ 0, 0, 1, 1 },
        );
    }

    /// One quad, `(x, y, w, h)` in window pixels with GL's own bottom-left
    /// origin — the same convention `Chain.letterbox` already uses, so a box
    /// straight from it lines up with no conversion.
    fn drawQuad(self: *Osd, window: Size, x: f32, y: f32, w: f32, h: f32, uv: [4]f32) void {
        const api = self.api;
        const ww: f32 = @floatFromInt(@max(1, window.w));
        const wh: f32 = @floatFromInt(@max(1, window.h));
        const x0 = x / ww * 2 - 1;
        const x1 = (x + w) / ww * 2 - 1;
        const y0 = y / wh * 2 - 1;
        const y1 = (y + h) / wh * 2 - 1;

        // GL treats the texture's first uploaded row as v=0 — which
        // `rasterize` filled with the *top* row of each glyph's art — so v=0
        // has to land at the screen's top (y1, GL's bottom-left origin means
        // bigger y is up) or every glyph draws upside down. Hence uv[1] (v0)
        // pairs with y1 and uv[3] (v1) pairs with y0, the opposite of the
        // "obvious" pairing.
        const verts = [_]f32{
            // x,  y,  u,       v
            x0, y0, uv[0], uv[3],
            x1, y0, uv[2], uv[3],
            x0, y1, uv[0], uv[1],
            x1, y1, uv[2], uv[1],
        };
        api.glBufferData(gl.ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, gl.DYNAMIC_DRAW);
        if (self.a_pos >= 0) {
            api.glVertexAttribPointer(@intCast(self.a_pos), 2, gl.FLOAT, 0, 4 * @sizeOf(f32), null);
        }
        if (self.a_uv >= 0) {
            api.glVertexAttribPointer(@intCast(self.a_uv), 2, gl.FLOAT, 0, 4 * @sizeOf(f32), @ptrFromInt(2 * @sizeOf(f32)));
        }
        api.glDrawArrays(gl.TRIANGLE_STRIP, 0, 4);
    }
};

fn compile(api: gl.Api, kind: gl.Enum, src: []const u8) !gl.Uint {
    const sh = api.glCreateShader(kind);
    const ptr: [*]const u8 = src.ptr;
    const len: gl.Int = @intCast(src.len);
    api.glShaderSource(sh, 1, @ptrCast(&ptr), @ptrCast(&len));
    api.glCompileShader(sh);

    var ok: gl.Int = 0;
    api.glGetShaderiv(sh, gl.COMPILE_STATUS, &ok);
    if (ok == gl.FALSE) {
        api.glDeleteShader(sh);
        return Error.ShaderCompile;
    }
    return sh;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "parseGlyph: reads '#' as lit, everything else as unlit" {
    const rows = parseGlyph(
        \\#.#.#
        \\.....
        \\#####
        \\.....
        \\#...#
        \\.....
        \\.....
    );
    try testing.expectEqual(@as(u8, 0b10101), rows[0]);
    try testing.expectEqual(@as(u8, 0b00000), rows[1]);
    try testing.expectEqual(@as(u8, 0b11111), rows[2]);
    try testing.expectEqual(@as(u8, 0b10001), rows[4]);
}

test "glyphRows: an unknown character is blank, not a crash or a garbage glyph" {
    const rows = glyphRows('!');
    for (rows) |r| try testing.expectEqual(@as(u8, 0), r);
}

test "glyphRows: case folds — 'a' and 'A' render identically" {
    try testing.expectEqualSlices(u8, &glyphRows('a'), &glyphRows('A'));
}

test "rasterize: glyphs land at 6-pixel intervals with a blank gap column" {
    const w = 2 * (glyph_w + 1);
    var buf: [12 * glyph_h * 4]u8 = @splat(0);
    rasterize(&buf, w, "1-");

    // Column 5 (the gap after glyph 0) must be fully transparent even though
    // '1' and '-' both light up interior columns.
    for (0..glyph_h) |row| {
        const idx = (row * w + 5) * 4 + 3;
        try testing.expectEqual(@as(u8, 0), buf[idx]);
    }
    // '-' is a single lit row (row 3) in its glyph; check it landed in the
    // second glyph's cell (columns 6..10), not smeared into the first.
    const dash_row_start = (3 * w + 6) * 4 + 3;
    try testing.expectEqual(@as(u8, 255), buf[dash_row_start]);
}
