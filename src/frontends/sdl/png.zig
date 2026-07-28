//! A minimal PNG encoder: 8-bit truecolor, filter-0 scanlines, one IDAT
//! compressed with the standard library's deflate in a zlib container.
//! ~100 lines against `std` alone — exactly enough for screenshots, and
//! nothing the repo has to depend on.

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
