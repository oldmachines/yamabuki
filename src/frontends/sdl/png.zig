//! PNG, against `std` alone — nothing the repo has to depend on.
//!
//! The encoder is minimal: 8-bit truecolor, filter-0 scanlines, one IDAT
//! compressed with the standard library's deflate in a zlib container —
//! exactly enough for screenshots.
//!
//! The decoder reads any PNG the spec allows (every colour type and bit
//! depth, palette transparency, colour-key transparency, Adam7 interlace)
//! into RGBA8, because it exists to show box art that other tools wrote:
//! whatever a scraper or a scanner produced has to display. 16-bit samples
//! keep their high byte; gamma, colour profiles and text are ignored.

const std = @import("std");
const flate = std.compress.flate;

const signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };

/// Encode `rgb` (tightly packed RGB8, `w*h*3` bytes) into a PNG file image.
pub fn encode(gpa: std.mem.Allocator, rgb: []const u8, w: u32, h: u32) ![]u8 {
    std.debug.assert(rgb.len == @as(usize, w) * h * 3);

    // Raw scanlines: a filter byte (0 = None) before each row.
    const stride = @as(usize, w) * 3;
    const raw = try gpa.alloc(u8, (stride + 1) * h);
    defer gpa.free(raw);
    for (0..h) |y| {
        raw[y * (stride + 1)] = 0;
        @memcpy(raw[y * (stride + 1) + 1 ..][0..stride], rgb[y * stride ..][0..stride]);
    }

    // Deflate into a zlib stream.
    var idat: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    defer idat.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var comp = try flate.Compress.init(&idat.writer, window, .zlib, .default);
    try comp.writer.writeAll(raw);
    try comp.finish();

    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, idat.written().len + 128);
    errdefer out.deinit();
    try out.writer.writeAll(&signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // color type: truecolor
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter method
    ihdr[12] = 0; // no interlace
    try writeChunk(&out.writer, "IHDR", &ihdr);
    try writeChunk(&out.writer, "IDAT", idat.written());
    try writeChunk(&out.writer, "IEND", "");
    return out.toOwnedSlice();
}

fn writeChunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try w.writeAll(&len);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
    try w.writeAll(&crc_bytes);
}

// --- decoding --------------------------------------------------------------

/// A decoded image: RGBA8, tightly packed, top-left first. Alpha is 255
/// wherever the file carried none.
pub const Image = struct {
    w: u32,
    h: u32,
    rgba: []u8,

    pub fn deinit(self: *Image, gpa: std.mem.Allocator) void {
        gpa.free(self.rgba);
        self.* = undefined;
    }
};

pub const DecodeError = error{ NotAPng, Unsupported, Corrupt, TooLarge, OutOfMemory };

const ColorType = enum(u8) { gray = 0, rgb = 2, palette = 3, gray_alpha = 4, rgba = 6 };

const Header = struct {
    w: u32,
    h: u32,
    depth: u8,
    ctype: ColorType,
    interlaced: bool,

    fn channels(self: Header) u32 {
        return switch (self.ctype) {
            .gray, .palette => 1,
            .gray_alpha => 2,
            .rgb => 3,
            .rgba => 4,
        };
    }
    fn bitsPerPixel(self: Header) u32 {
        return self.channels() * self.depth;
    }
    fn rowBytes(self: Header, w: u32) usize {
        return (@as(usize, w) * self.bitsPerPixel() + 7) / 8;
    }
    /// The filters' pixel stride in bytes, floored at 1 for sub-byte depths.
    fn filterBpp(self: Header) usize {
        return @max(1, self.bitsPerPixel() / 8);
    }
};

/// Adam7: each pass's first column, first row, column step, row step.
pub const adam7 = [7][4]u32{
    .{ 0, 0, 8, 8 }, .{ 4, 0, 8, 8 }, .{ 0, 4, 4, 8 }, .{ 2, 0, 4, 4 },
    .{ 0, 2, 2, 4 }, .{ 1, 0, 2, 2 }, .{ 0, 1, 1, 2 },
};

/// A pass's own width and height (either may be 0 on a small image).
pub fn passDims(w: u32, h: u32, p: [4]u32) [2]u32 {
    const pw = if (w > p[0]) (w - p[0] + p[2] - 1) / p[2] else 0;
    const ph = if (h > p[1]) (h - p[1] + p[3] - 1) / p[3] else 0;
    return .{ pw, ph };
}

/// Decode a PNG file image into RGBA8. `max_pixels` bounds the allocation
/// before the header is trusted. Every chunk's CRC is checked; unknown
/// chunks are skipped.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8, max_pixels: usize) DecodeError!Image {
    if (bytes.len < signature.len or !std.mem.eql(u8, bytes[0..signature.len], &signature)) return error.NotAPng;

    var hdr: ?Header = null;
    var palette: [256][4]u8 = undefined;
    var palette_len: usize = 0;
    var trns_gray: ?u16 = null;
    var trns_rgb: ?[3]u16 = null;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);

    var off: usize = signature.len;
    var ended = false;
    while (!ended) {
        if (off + 12 > bytes.len) return error.Corrupt;
        const len = std.mem.readInt(u32, bytes[off..][0..4], .big);
        const kind = bytes[off + 4 ..][0..4];
        if (len > bytes.len - off - 12) return error.Corrupt;
        const data = bytes[off + 8 ..][0..len];
        var crc = std.hash.Crc32.init();
        crc.update(kind);
        crc.update(data);
        if (crc.final() != std.mem.readInt(u32, bytes[off + 8 + len ..][0..4], .big)) return error.Corrupt;
        off += 12 + len;

        if (std.mem.eql(u8, kind, "IHDR")) {
            if (hdr != null or len != 13) return error.Corrupt;
            const w = std.mem.readInt(u32, data[0..4], .big);
            const h = std.mem.readInt(u32, data[4..8], .big);
            const depth = data[8];
            const ctype: ColorType = switch (data[9]) {
                0 => .gray,
                2 => .rgb,
                3 => .palette,
                4 => .gray_alpha,
                6 => .rgba,
                else => return error.Unsupported,
            };
            if (data[10] != 0 or data[11] != 0 or data[12] > 1) return error.Unsupported;
            const depth_ok = switch (ctype) {
                .gray => depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16,
                .palette => depth == 1 or depth == 2 or depth == 4 or depth == 8,
                .rgb, .gray_alpha, .rgba => depth == 8 or depth == 16,
            };
            if (!depth_ok) return error.Unsupported;
            if (w == 0 or h == 0) return error.Corrupt;
            if (w > 1 << 24 or h > 1 << 24 or @as(u64, w) * h > max_pixels) return error.TooLarge;
            hdr = .{ .w = w, .h = h, .depth = depth, .ctype = ctype, .interlaced = data[12] == 1 };
        } else if (hdr == null) {
            return error.Corrupt; // IHDR comes first
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            if (len == 0 or len % 3 != 0 or len / 3 > 256) return error.Corrupt;
            palette_len = len / 3;
            for (0..palette_len) |i| palette[i] = .{ data[i * 3], data[i * 3 + 1], data[i * 3 + 2], 255 };
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            switch (hdr.?.ctype) {
                .palette => {
                    if (len > palette_len) return error.Corrupt;
                    for (0..len) |i| palette[i][3] = data[i];
                },
                .gray => {
                    if (len != 2) return error.Corrupt;
                    trns_gray = std.mem.readInt(u16, data[0..2], .big);
                },
                .rgb => {
                    if (len != 6) return error.Corrupt;
                    trns_rgb = .{
                        std.mem.readInt(u16, data[0..2], .big),
                        std.mem.readInt(u16, data[2..4], .big),
                        std.mem.readInt(u16, data[4..6], .big),
                    };
                },
                else => return error.Corrupt,
            }
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            ended = true;
        }
    }
    const h = hdr orelse return error.Corrupt;
    if (h.ctype == .palette and palette_len == 0) return error.Corrupt;

    // The filtered scanlines of every pass, back to back, the way the
    // stream holds them: a filter byte, then the row.
    var raw_len: usize = 0;
    if (h.interlaced) {
        for (adam7) |p| {
            const d = passDims(h.w, h.h, p);
            if (d[0] == 0 or d[1] == 0) continue;
            raw_len += (h.rowBytes(d[0]) + 1) * d[1];
        }
    } else raw_len = (h.rowBytes(h.w) + 1) * h.h;
    const raw = try gpa.alloc(u8, raw_len);
    defer gpa.free(raw);
    {
        var in: std.Io.Reader = .fixed(idat.items);
        const window = try gpa.alloc(u8, flate.max_window_len);
        defer gpa.free(window);
        var dec: flate.Decompress = .init(&in, .zlib, window);
        dec.reader.readSliceAll(raw) catch return error.Corrupt;
    }

    const rgba = try gpa.alloc(u8, @as(usize, h.w) * h.h * 4);
    errdefer gpa.free(rgba);
    const ctx: Samples = .{ .hdr = h, .palette = &palette, .palette_len = palette_len, .trns_gray = trns_gray, .trns_rgb = trns_rgb };
    if (h.interlaced) {
        var pos: usize = 0;
        for (adam7) |p| {
            const d = passDims(h.w, h.h, p);
            if (d[0] == 0 or d[1] == 0) continue;
            const stride = h.rowBytes(d[0]) + 1;
            const pass = raw[pos..][0 .. stride * d[1]];
            pos += pass.len;
            try unfilter(pass, stride - 1, d[1], h.filterBpp());
            for (0..d[1]) |py| {
                const row = pass[py * stride + 1 ..][0 .. stride - 1];
                const y: usize = p[1] + py * p[3];
                for (0..d[0]) |px| {
                    const x: usize = p[0] + px * p[2];
                    const c = try ctx.pixel(row, px);
                    @memcpy(rgba[(y * h.w + x) * 4 ..][0..4], &c);
                }
            }
        }
    } else {
        const stride = h.rowBytes(h.w) + 1;
        try unfilter(raw, stride - 1, h.h, h.filterBpp());
        for (0..h.h) |y| {
            const row = raw[y * stride + 1 ..][0 .. stride - 1];
            for (0..h.w) |x| {
                const c = try ctx.pixel(row, x);
                @memcpy(rgba[(y * h.w + x) * 4 ..][0..4], &c);
            }
        }
    }
    return .{ .w = h.w, .h = h.h, .rgba = rgba };
}

/// Undo the per-row filters in place. `buf` is `rows` scanlines of
/// `rowbytes + 1` bytes; the first byte of each names its filter. Left
/// neighbours are read after their own reconstruction, as the spec has it.
fn unfilter(buf: []u8, rowbytes: usize, rows: usize, bpp: usize) DecodeError!void {
    const stride = rowbytes + 1;
    var prev: ?[]const u8 = null;
    for (0..rows) |r| {
        const line = buf[r * stride ..][0..stride];
        const cur = line[1..];
        switch (line[0]) {
            0 => {},
            1 => {
                var i: usize = bpp;
                while (i < rowbytes) : (i += 1) cur[i] +%= cur[i - bpp];
            },
            2 => if (prev) |p| {
                for (cur, p) |*c, b| c.* +%= b;
            },
            3 => for (0..rowbytes) |i| {
                const a: u16 = if (i >= bpp) cur[i - bpp] else 0;
                const b: u16 = if (prev) |p| p[i] else 0;
                cur[i] +%= @intCast((a + b) / 2);
            },
            4 => for (0..rowbytes) |i| {
                const a: i16 = if (i >= bpp) cur[i - bpp] else 0;
                const b: i16 = if (prev) |p| p[i] else 0;
                const c: i16 = if (prev != null and i >= bpp) prev.?[i - bpp] else 0;
                cur[i] +%= paeth(a, b, c);
            },
            else => return error.Corrupt,
        }
        prev = cur;
    }
}

fn paeth(a: i16, b: i16, c: i16) u8 {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return @intCast(a);
    if (pb <= pc) return @intCast(b);
    return @intCast(c);
}

/// Reading pixels out of an unfiltered row at the header's depth.
const Samples = struct {
    hdr: Header,
    palette: *const [256][4]u8,
    palette_len: usize,
    trns_gray: ?u16,
    trns_rgb: ?[3]u16,

    /// Sample `i` of the row, as stored (a 1/2/4-bit sample is not scaled).
    fn sample(self: *const Samples, row: []const u8, i: usize) u16 {
        return switch (self.hdr.depth) {
            8 => row[i],
            16 => std.mem.readInt(u16, row[i * 2 ..][0..2], .big),
            else => |d| blk: {
                const bit = i * d;
                const shift: u3 = @intCast(8 - @as(usize, d) - bit % 8);
                const mask: u8 = @intCast((@as(u16, 1) << @intCast(d)) - 1);
                break :blk (row[bit / 8] >> shift) & mask;
            },
        };
    }

    /// A stored sample as an 8-bit channel.
    fn to8(self: *const Samples, s: u16) u8 {
        return switch (self.hdr.depth) {
            8 => @intCast(s),
            16 => @intCast(s >> 8),
            else => |d| @intCast(@as(u32, s) * 255 / ((@as(u32, 1) << @intCast(d)) - 1)),
        };
    }

    fn pixel(self: *const Samples, row: []const u8, x: usize) DecodeError![4]u8 {
        switch (self.hdr.ctype) {
            .gray => {
                const g = self.sample(row, x);
                const a: u8 = if (self.trns_gray) |t| (if (t == g) 0 else 255) else 255;
                const v = self.to8(g);
                return .{ v, v, v, a };
            },
            .gray_alpha => {
                const v = self.to8(self.sample(row, x * 2));
                return .{ v, v, v, self.to8(self.sample(row, x * 2 + 1)) };
            },
            .rgb => {
                const r = self.sample(row, x * 3);
                const g = self.sample(row, x * 3 + 1);
                const b = self.sample(row, x * 3 + 2);
                const a: u8 = if (self.trns_rgb) |t| (if (t[0] == r and t[1] == g and t[2] == b) 0 else 255) else 255;
                return .{ self.to8(r), self.to8(g), self.to8(b), a };
            },
            .rgba => return .{
                self.to8(self.sample(row, x * 4)),
                self.to8(self.sample(row, x * 4 + 1)),
                self.to8(self.sample(row, x * 4 + 2)),
                self.to8(self.sample(row, x * 4 + 3)),
            },
            .palette => {
                const idx = self.sample(row, x);
                if (idx >= self.palette_len) return error.Corrupt;
                return self.palette[idx];
            },
        }
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "png: output decodes back to the input pixels, chunk by chunk" {
    const a = testing.allocator;
    const w = 5;
    const h = 3;
    var rgb: [w * h * 3]u8 = undefined;
    for (&rgb, 0..) |*p, i| p.* = @intCast((i * 37) & 0xFF);

    const png = try encode(a, &rgb, w, h);
    defer a.free(png);

    // Signature and chunk skeleton.
    try testing.expectEqualSlices(u8, &signature, png[0..8]);
    try testing.expectEqualSlices(u8, "IHDR", png[12..16]);
    try testing.expectEqual(@as(u32, w), std.mem.readInt(u32, png[16..20], .big));
    try testing.expectEqual(@as(u32, h), std.mem.readInt(u32, png[20..24], .big));
    try testing.expectEqualSlices(u8, "IEND", png[png.len - 8 ..][0..4]);

    // Every chunk's CRC holds.
    var off: usize = 8;
    var idat_data: []const u8 = "";
    while (off < png.len) {
        const len = std.mem.readInt(u32, png[off..][0..4], .big);
        const kind = png[off + 4 ..][0..4];
        const data = png[off + 8 ..][0..len];
        var crc = std.hash.Crc32.init();
        crc.update(kind);
        crc.update(data);
        try testing.expectEqual(crc.final(), std.mem.readInt(u32, png[off + 8 + len ..][0..4], .big));
        if (std.mem.eql(u8, kind, "IDAT")) idat_data = data;
        off += 12 + len;
    }
    try testing.expect(idat_data.len != 0);

    // Inflate the IDAT and compare pixel-for-pixel (filter byte 0 per row).
    var in: std.Io.Reader = .fixed(idat_data);
    var window: [flate.max_window_len]u8 = undefined;
    var dec: flate.Decompress = .init(&in, .zlib, &window);
    var raw: [(w * 3 + 1) * h]u8 = undefined;
    try dec.reader.readSliceAll(&raw);
    for (0..h) |y| {
        try testing.expectEqual(@as(u8, 0), raw[y * (w * 3 + 1)]);
        try testing.expectEqualSlices(
            u8,
            rgb[y * w * 3 ..][0 .. w * 3],
            raw[y * (w * 3 + 1) + 1 ..][0 .. w * 3],
        );
    }
}

/// Test-side PNG builder for any format: the scanlines come in already
/// filtered (filter byte + row, every pass back to back for an interlaced
/// image), so a test can exercise the decoder's filters against reference
/// arithmetic of its own. The IDAT is split in two to prove concatenation.
fn buildPng(gpa: std.mem.Allocator, w: u32, h: u32, depth: u8, ctype: u8, interlace: u8, scanlines: []const u8, plte: ?[]const u8, trns: ?[]const u8) ![]u8 {
    var idat: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    defer idat.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var comp = try flate.Compress.init(&idat.writer, window, .zlib, .default);
    try comp.writer.writeAll(scanlines);
    try comp.finish();

    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    errdefer out.deinit();
    try out.writer.writeAll(&signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = depth;
    ihdr[9] = ctype;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = interlace;
    try writeChunk(&out.writer, "IHDR", &ihdr);
    try writeChunk(&out.writer, "tEXt", "Comment\x00an ancillary chunk to skip");
    if (plte) |p| try writeChunk(&out.writer, "PLTE", p);
    if (trns) |t| try writeChunk(&out.writer, "tRNS", t);
    const z = idat.written();
    const cut = z.len / 2;
    try writeChunk(&out.writer, "IDAT", z[0..cut]);
    try writeChunk(&out.writer, "IDAT", z[cut..]);
    try writeChunk(&out.writer, "IEND", "");
    return out.toOwnedSlice();
}

/// The forward filter, from the spec's definitions over ORIGINAL bytes.
fn filterRow(ft: u8, cur: []const u8, prev: ?[]const u8, bpp: usize, out: []u8) void {
    for (cur, 0..) |v, i| {
        const a: i16 = if (i >= bpp) cur[i - bpp] else 0;
        const b: i16 = if (prev) |p| p[i] else 0;
        const c: i16 = if (prev != null and i >= bpp) prev.?[i - bpp] else 0;
        const pred: u8 = switch (ft) {
            0 => 0,
            1 => @intCast(a),
            2 => @intCast(b),
            3 => @intCast(@divFloor(a + b, 2)),
            4 => paeth(a, b, c),
            else => unreachable,
        };
        out[i] = v -% pred;
    }
}

test "png: decode inverts encode, alpha filled in" {
    const a = testing.allocator;
    const w = 7;
    const h = 5;
    var rgb: [w * h * 3]u8 = undefined;
    for (&rgb, 0..) |*p, i| p.* = @intCast((i * 53 + 7) & 0xFF);
    const file = try encode(a, &rgb, w, h);
    defer a.free(file);
    var img = try decode(a, file, 1 << 20);
    defer img.deinit(a);
    try testing.expectEqual(@as(u32, w), img.w);
    try testing.expectEqual(@as(u32, h), img.h);
    for (0..w * h) |i| {
        try testing.expectEqualSlices(u8, rgb[i * 3 ..][0..3], img.rgba[i * 4 ..][0..3]);
        try testing.expectEqual(@as(u8, 255), img.rgba[i * 4 + 3]);
    }
}

test "png: every filter type reconstructs, at 3 and 8 bytes per pixel" {
    const a = testing.allocator;
    const w = 8;
    const h = 6;
    inline for (.{ .{ 2, 8, 3 }, .{ 6, 16, 8 } }) |fmt| {
        const ctype = fmt[0];
        const depth = fmt[1];
        const bpp = fmt[2];
        const rowbytes = w * bpp;
        var pix: [rowbytes * h]u8 = undefined;
        for (&pix, 0..) |*p, i| p.* = @intCast((i * i * 7 + i * 13 + 5) & 0xFF);
        var lines: [(rowbytes + 1) * h]u8 = undefined;
        const types = [_]u8{ 1, 2, 3, 4, 4, 0 };
        for (0..h) |y| {
            lines[y * (rowbytes + 1)] = types[y];
            const prev: ?[]const u8 = if (y == 0) null else pix[(y - 1) * rowbytes ..][0..rowbytes];
            filterRow(types[y], pix[y * rowbytes ..][0..rowbytes], prev, bpp, lines[y * (rowbytes + 1) + 1 ..][0..rowbytes]);
        }
        const file = try buildPng(a, w, h, depth, ctype, 0, &lines, null, null);
        defer a.free(file);
        var img = try decode(a, file, 1 << 20);
        defer img.deinit(a);
        for (0..w * h) |i| {
            if (depth == 8) {
                try testing.expectEqualSlices(u8, pix[i * 3 ..][0..3], img.rgba[i * 4 ..][0..3]);
                try testing.expectEqual(@as(u8, 255), img.rgba[i * 4 + 3]);
            } else {
                // 16-bit samples keep their high byte.
                for (0..4) |ch| try testing.expectEqual(pix[i * 8 + ch * 2], img.rgba[i * 4 + ch]);
            }
        }
    }
}

test "png: palette, sub-byte gray, 16-bit gray, gray+alpha, and transparency" {
    const a = testing.allocator;

    // 4-bit palette, 5 wide (so the last byte is half used), tRNS on entry 1.
    {
        const plte = [_]u8{ 10, 20, 30, 40, 50, 60, 70, 80, 90 };
        const trns = [_]u8{ 255, 0 };
        // Rows: indices 0 1 2 1 0 / 2 2 2 2 2, packed two per byte.
        const lines = [_]u8{ 0, 0x01, 0x21, 0x00, 0, 0x22, 0x22, 0x20 };
        const file = try buildPng(a, 5, 2, 4, 3, 0, &lines, &plte, &trns);
        defer a.free(file);
        var img = try decode(a, file, 1 << 20);
        defer img.deinit(a);
        try testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255 }, img.rgba[0..4]);
        try testing.expectEqualSlices(u8, &.{ 40, 50, 60, 0 }, img.rgba[4..8]); // transparent entry
        try testing.expectEqualSlices(u8, &.{ 70, 80, 90, 255 }, img.rgba[8..12]);
        try testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255 }, img.rgba[16..20]);
        try testing.expectEqualSlices(u8, &.{ 70, 80, 90, 255 }, img.rgba[9 * 4 ..][0..4]);
    }
    // 1-bit gray, 10 wide: bits 1100110011 / 0000000001, tRNS = black.
    {
        const trns = [_]u8{ 0, 0 };
        const lines = [_]u8{ 0, 0b11001100, 0b11000000, 0, 0b00000000, 0b01000000 };
        const file = try buildPng(a, 10, 2, 1, 0, 0, &lines, null, &trns);
        defer a.free(file);
        var img = try decode(a, file, 1 << 20);
        defer img.deinit(a);
        try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, img.rgba[0..4]);
        try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, img.rgba[8..12]); // keyed out
        try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, img.rgba[9 * 4 ..][0..4]);
        try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, img.rgba[19 * 4 ..][0..4]);
        try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, img.rgba[18 * 4 ..][0..4]);
    }
    // 16-bit gray: the high byte survives; 2-bit gray scales 0..3 to 0..255.
    {
        const lines16 = [_]u8{ 0, 0x12, 0x34, 0xAB, 0xCD };
        const file = try buildPng(a, 2, 1, 16, 0, 0, &lines16, null, null);
        defer a.free(file);
        var img = try decode(a, file, 1 << 20);
        defer img.deinit(a);
        try testing.expectEqualSlices(u8, &.{ 0x12, 0x12, 0x12, 255, 0xAB, 0xAB, 0xAB, 255 }, img.rgba);
        const lines2 = [_]u8{ 0, 0b00_01_10_11 };
        const file2 = try buildPng(a, 4, 1, 2, 0, 0, &lines2, null, null);
        defer a.free(file2);
        var img2 = try decode(a, file2, 1 << 20);
        defer img2.deinit(a);
        try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255, 85, 85, 85, 255, 170, 170, 170, 255, 255, 255, 255, 255 }, img2.rgba);
    }
    // 8-bit gray+alpha and RGB with a colour key.
    {
        const ga = [_]u8{ 0, 100, 7, 200, 255 };
        const file = try buildPng(a, 2, 1, 8, 4, 0, &ga, null, null);
        defer a.free(file);
        var img = try decode(a, file, 1 << 20);
        defer img.deinit(a);
        try testing.expectEqualSlices(u8, &.{ 100, 100, 100, 7, 200, 200, 200, 255 }, img.rgba);
        const key = [_]u8{ 0, 1, 0, 2, 0, 3 };
        const rgb = [_]u8{ 0, 1, 2, 3, 9, 9, 9 };
        const file2 = try buildPng(a, 2, 1, 8, 2, 0, &rgb, null, &key);
        defer a.free(file2);
        var img2 = try decode(a, file2, 1 << 20);
        defer img2.deinit(a);
        try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 0, 9, 9, 9, 255 }, img2.rgba);
    }
}

test "png: Adam7 interlace lands every pixel where the plain image has it" {
    const a = testing.allocator;
    const w = 9;
    const h = 7;
    var pix: [w * h * 3]u8 = undefined;
    for (0..h) |y| for (0..w) |x| {
        pix[(y * w + x) * 3] = @intCast(x * 20);
        pix[(y * w + x) * 3 + 1] = @intCast(y * 30);
        pix[(y * w + x) * 3 + 2] = @intCast((x + y) * 9);
    };
    // Build the seven passes, filter 0 rows, from the spec's geometry.
    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(a);
    for (adam7) |p| {
        const d = passDims(w, h, p);
        if (d[0] == 0 or d[1] == 0) continue;
        for (0..d[1]) |py| {
            try lines.append(a, 0);
            for (0..d[0]) |px| {
                const x = p[0] + px * p[2];
                const y = p[1] + py * p[3];
                try lines.appendSlice(a, pix[(y * w + x) * 3 ..][0..3]);
            }
        }
    }
    const file = try buildPng(a, w, h, 8, 2, 1, lines.items, null, null);
    defer a.free(file);
    var img = try decode(a, file, 1 << 20);
    defer img.deinit(a);
    for (0..w * h) |i| {
        try testing.expectEqualSlices(u8, pix[i * 3 ..][0..3], img.rgba[i * 4 ..][0..3]);
        try testing.expectEqual(@as(u8, 255), img.rgba[i * 4 + 3]);
    }
    // A 1x1 interlaced image has six empty passes.
    const one = [_]u8{ 0, 1, 2, 3 };
    const tiny = try buildPng(a, 1, 1, 8, 2, 1, &one, null, null);
    defer a.free(tiny);
    var t = try decode(a, tiny, 1 << 20);
    defer t.deinit(a);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, t.rgba);
}

test "png: real files from the reference captures decode (needs test-data/)" {
    // krom's captures and the demos' source art cover the formats real
    // tools write: RGB8, palettes at 2/4/8 bits, RGBA8.
    const a = testing.allocator;
    const io = testing.io;
    const files = [_]struct { path: []const u8, w: u32, h: u32, max_colors: ?usize }{
        .{ .path = "test-data/snes-roms/PlotPixel/Mode7/PlotPixelMode7.png", .w = 256, .h = 224, .max_colors = null },
        .{ .path = "test-data/snes-roms/Translate/Soreyuke Ebisumaru Karakuri Meiro - Kieta Goemon no Nazo!!/CharTables/CharTable.png", .w = 128, .h = 128, .max_colors = 4 },
        .{ .path = "test-data/snes-roms/PPU/Blend/HiColor/HiColor3840/GFX/MaxColR16.png", .w = 256, .h = 224, .max_colors = 16 },
        .{ .path = "test-data/snes-roms/PPU/Blend/HiColor/HiColor3840/GFX/MaxColGB240.png", .w = 256, .h = 224, .max_colors = 256 },
        .{ .path = "test-data/snes-roms/HelloWorld/HelloWorld.png", .w = 256, .h = 224, .max_colors = null },
    };
    for (files) |f| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, f.path, a, .limited(4 << 20)) catch return error.SkipZigTest;
        defer a.free(bytes);
        var img = try decode(a, bytes, 1 << 22);
        defer img.deinit(a);
        try testing.expectEqual(f.w, img.w);
        try testing.expectEqual(f.h, img.h);
        // Count distinct colours (a palette image cannot exceed its palette)
        // and require more than one — a decoder that zeroed everything
        // would still have the right dimensions.
        var seen: std.AutoHashMap(u32, void) = .init(a);
        defer seen.deinit();
        for (0..@as(usize, img.w) * img.h) |i| {
            try seen.put(std.mem.readInt(u32, img.rgba[i * 4 ..][0..4], .little), {});
        }
        try testing.expect(seen.count() > 1);
        if (f.max_colors) |m| try testing.expect(seen.count() <= m);
    }
}

test "png: refusals" {
    const a = testing.allocator;
    const rgb = [_]u8{ 0, 1, 2, 3 };
    const good = try buildPng(a, 1, 1, 8, 2, 0, &rgb, null, null);
    defer a.free(good);

    try testing.expectError(error.NotAPng, decode(a, "GIF89a...", 1 << 20));
    try testing.expectError(error.TooLarge, decode(a, good, 0));

    // A flipped byte inside a chunk fails that chunk's CRC.
    const crc_bad = try a.dupe(u8, good);
    defer a.free(crc_bad);
    crc_bad[16] ^= 1; // IHDR width
    try testing.expectError(error.Corrupt, decode(a, crc_bad, 1 << 20));

    // Bit depth 3 is not a PNG depth; colour type 1 is not a colour type.
    const depth3 = try buildPng(a, 1, 1, 3, 2, 0, &rgb, null, null);
    defer a.free(depth3);
    try testing.expectError(error.Unsupported, decode(a, depth3, 1 << 20));
    const ctype1 = try buildPng(a, 1, 1, 8, 1, 0, &rgb, null, null);
    defer a.free(ctype1);
    try testing.expectError(error.Unsupported, decode(a, ctype1, 1 << 20));

    // A palette index past the palette; a filter type that does not exist;
    // an image whose stream is shorter than its header promises.
    const plte = [_]u8{ 1, 2, 3 };
    const idx = [_]u8{ 0, 5 };
    const oob = try buildPng(a, 1, 1, 8, 3, 0, &idx, &plte, null);
    defer a.free(oob);
    try testing.expectError(error.Corrupt, decode(a, oob, 1 << 20));
    const ft9 = [_]u8{ 9, 1, 2, 3 };
    const badft = try buildPng(a, 1, 1, 8, 2, 0, &ft9, null, null);
    defer a.free(badft);
    try testing.expectError(error.Corrupt, decode(a, badft, 1 << 20));
    const short = try buildPng(a, 4, 4, 8, 2, 0, &rgb, null, null);
    defer a.free(short);
    try testing.expectError(error.Corrupt, decode(a, short, 1 << 20));
    // No IEND: the file just stops.
    try testing.expectError(error.Corrupt, decode(a, good[0 .. good.len - 12], 1 << 20));
}
