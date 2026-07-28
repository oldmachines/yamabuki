//! The frontend's shared 5x7 dot-matrix font: glyph data only, no GL, no
//! rendering. `osd.zig` rasterizes it into a texture for the shader-chain
//! toast; `ui.zig` blits it straight into the RGB565 compose buffer for the
//! overlay menu.
//!
//! Uppercase only (input is folded on lookup): a lowercase alphabet at this
//! size needs ascenders and descenders to stay unambiguous, which a blocky
//! dot-matrix face does not have room for, while capitals fit the box
//! cleanly � and read exactly like the era the menu is dressed as. Each
//! glyph is drawn as art, not bits, so a mistake is visible on sight
//! instead of hiding in a hand-packed byte.

const std = @import("std");

pub const glyph_w = 5;
pub const glyph_h = 7;

fn parseGlyph(comptime art: []const u8) [glyph_h]u8 {
    var out: [glyph_h]u8 = @splat(0);
    var row: usize = 0;
    var col: usize = 0;
    for (art) |c| {
        if (c == '\n') {
            row += 1;
            col = 0;
            continue;
        }
        if (row < glyph_h and col < glyph_w) {
            if (c == '#') out[row] |= @as(u8, 1) << @intCast(glyph_w - 1 - col);
            col += 1;
        }
    }
    return out;
}

pub fn rows(c: u8) [glyph_h]u8 {
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
        '.' => parseGlyph(
            \\.....
            \\.....
            \\.....
            \\.....
            \\.....
            \\.##..
            \\.##..
        ),
        ',' => parseGlyph(
            \\.....
            \\.....
            \\.....
            \\.....
            \\.##..
            \\..#..
            \\.#...
        ),
        ':' => parseGlyph(
            \\.....
            \\.##..
            \\.##..
            \\.....
            \\.##..
            \\.##..
            \\.....
        ),
        '/' => parseGlyph(
            \\....#
            \\....#
            \\...#.
            \\..#..
            \\.#...
            \\#....
            \\#....
        ),
        '!' => parseGlyph(
            \\..#..
            \\..#..
            \\..#..
            \\..#..
            \\..#..
            \\.....
            \\..#..
        ),
        '?' => parseGlyph(
            \\.###.
            \\#...#
            \\....#
            \\...#.
            \\..#..
            \\.....
            \\..#..
        ),
        '\'' => parseGlyph(
            \\..#..
            \\..#..
            \\.#...
            \\.....
            \\.....
            \\.....
            \\.....
        ),
        '(' => parseGlyph(
            \\...#.
            \\..#..
            \\.#...
            \\.#...
            \\.#...
            \\..#..
            \\...#.
        ),
        ')' => parseGlyph(
            \\.#...
            \\..#..
            \\...#.
            \\...#.
            \\...#.
            \\..#..
            \\.#...
        ),
        '[' => parseGlyph(
            \\..###
            \\..#..
            \\..#..
            \\..#..
            \\..#..
            \\..#..
            \\..###
        ),
        ']' => parseGlyph(
            \\###..
            \\..#..
            \\..#..
            \\..#..
            \\..#..
            \\..#..
            \\###..
        ),
        '<' => parseGlyph(
            \\...#.
            \\..#..
            \\.#...
            \\#....
            \\.#...
            \\..#..
            \\...#.
        ),
        '>' => parseGlyph(
            \\.#...
            \\..#..
            \\...#.
            \\....#
            \\...#.
            \\..#..
            \\.#...
        ),
        '+' => parseGlyph(
            \\.....
            \\..#..
            \\..#..
            \\#####
            \\..#..
            \\..#..
            \\.....
        ),
        '=' => parseGlyph(
            \\.....
            \\.....
            \\#####
            \\.....
            \\#####
            \\.....
            \\.....
        ),
        '_' => parseGlyph(
            \\.....
            \\.....
            \\.....
            \\.....
            \\.....
            \\.....
            \\#####
        ),
        '*' => parseGlyph(
            \\.....
            \\#.#.#
            \\.###.
            \\..#..
            \\.###.
            \\#.#.#
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

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "parseGlyph: reads '#' as lit, everything else as unlit" {
    const r = parseGlyph(
        \\#.#.#
        \\.....
        \\#####
        \\.....
        \\#...#
        \\.....
        \\.....
    );
    try testing.expectEqual(@as(u8, 0b10101), r[0]);
    try testing.expectEqual(@as(u8, 0b00000), r[1]);
    try testing.expectEqual(@as(u8, 0b11111), r[2]);
    try testing.expectEqual(@as(u8, 0b10001), r[4]);
}

test "rows: an unknown character is blank, not a crash or a garbage glyph" {
    const r = rows('~');
    for (r) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "rows: case folds — 'a' and 'A' render identically" {
    try testing.expectEqualSlices(u8, &rows('a'), &rows('A'));
}

test "rows: the menu's punctuation set is present" {
    // Every character the overlay menu's labels and values lean on must
    // produce at least one lit pixel — a silently blank ':' would turn
    // "SCALE: 3" into "SCALE 3" with no test noticing.
    for (".:,/!?'()[]<>+=_*") |c| {
        var lit = false;
        for (rows(c)) |b| lit = lit or b != 0;
        try testing.expect(lit);
    }
}
