//! Inspection dumps: VRAM/OAM, the PPU display state, battery SRAM, the RAM snapshot, the S-CPU instruction set, the coverage and code-map files.
//!
//! Carved out of main.zig as pure code motion; every declaration
//! here is re-exported from main.zig, which stays the root.

const core = @import("snes_core");
const std = @import("std");
const root_mod = @import("../main.zig");

const Args = root_mod.Args;
/// `--dump-vram`: raw VRAM (64 KiB) + OAM (544 B), so cross-image VRAM/OAM
/// diffs are byte-exact.
pub fn dumpVram(io: std.Io, con: *core.AnyConsole, path: []const u8) void {
    const p = &con.fast.bus.ppu;
    var blob: [0x10000 + 0x220]u8 = undefined;
    @memcpy(blob[0..0x10000], std.mem.sliceAsBytes(p.vram[0..]));
    @memcpy(blob[0x10000..], &p.oam);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = &blob }) catch {};
}

/// `--dump-ppu`: the display state as text — what a layer is doing is a
/// property of the PPU registers and of what actually reached VRAM, and
/// neither shows up in a RAM dump. Per BG: is it on the main screen at all,
/// where is its tilemap and character data, and — the question that separates
/// "never uploaded" from "not displayed" — how much of that tilemap in VRAM
/// is actually non-empty.
pub fn dumpPpu(io: std.Io, out: *std.Io.Writer, con: *core.AnyConsole, path: []const u8) void {
    const p = &con.fast.bus.ppu;
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("bg_mode={d} force_blank={} brightness={d} main_screen(TM)=0x{x:0>2} sub_screen(TS)=0x{x:0>2}\n", .{
        p.bg_mode, p.force_blank, p.brightness, p.main_screen, p.sub_screen,
    }) catch {};
    for (p.bg, 0..) |b, i| {
        // A tilemap of all-zero entries renders as nothing even with the
        // layer enabled, so count what is actually there.
        const words: usize = switch (b.map_size) {
            0 => 0x400,
            1 => 0x800,
            2 => 0x800,
            3 => 0x1000,
        };
        var nonzero: usize = 0;
        var k: usize = 0;
        while (k < words) : (k += 1) {
            const idx = (@as(usize, b.map_base) + k) & 0x7FFF;
            if (p.vram[idx] != 0) nonzero += 1;
        }
        w.print("bg{d}: on_main={} map_base=0x{x:0>4} map_size={d} char_base=0x{x:0>4} tile16={} hofs={d} vofs={d} tilemap_nonzero={d}/{d}\n", .{
            i + 1,       (p.main_screen >> @intCast(i)) & 1 != 0,
            b.map_base,  b.map_size,
            b.char_base, b.tile16,
            b.hofs,      b.vofs,
            nonzero,     words,
        }) catch {};
    }
    // HDMA: per-scanline effects read their table straight out of memory
    // without the CPU issuing a single load, so a table left pointing at
    // abandoned WRAM is invisible to the stale detector and shows up only
    // as a missing effect. Top/bottom bands are exactly this shape.
    const dma = &con.fast.bus.dma;
    w.print("hdmaen=0x{x:0>2}\n", .{dma.hdmaen}) catch {};
    for (dma.channels, 0..) |ch, i| {
        if (dma.hdmaen & (@as(u8, 1) << @intCast(i)) == 0) continue;
        const src: u24 = (@as(u24, ch.a_bank) << 16) | ch.a_addr;
        const dead = ch.a_bank == 0x7E or ch.a_bank == 0x7F or
            ((ch.a_bank & 0x7F) < 0x40 and ch.a_addr < 0x2000);
        w.print("  hdma{d}: src={x:0>6} bank={x:0>2}{s}\n", .{
            i, src, ch.a_bank, if (dead) "  <-- ABANDONED MEMORY" else "",
        }) catch {};
        // Indirect tables fetch their DATA through a second bank the
        // CPU never touches after arming: a $7E there reads the
        // abandoned WRAM and no CPU-side instrument can see it.
        w.print("    control=0x{x:0>2} b_addr=0x{x:0>2} indirect_bank={x:0>2} indirect_addr={x:0>4} line_counter={d}\n", .{
            ch.control, ch.b_addr, ch.indirect_bank, ch.count, ch.line_counter,
        }) catch {};
    }
    // Color math: the one axis two byte-identical CGRAM/VRAM images can
    // still render differently through (measured: Super Metroid's Ceres
    // alarm tint, an indirect HDMA on $2132 reading abandoned $7E WRAM).
    w.print("cgwsel=0x{x:0>2} cgadsub=0x{x:0>2} fixed_color=0x{x:0>4} setini=0x{x:0>2}\n", .{
        p.cgwsel, p.cgadsub, p.fixed_color, p.setini,
    }) catch {};
    var vnz: usize = 0;
    for (p.vram) |word| {
        if (word != 0) vnz += 1;
    }
    w.print("vram_nonzero={d}/{d}\n", .{ vnz, p.vram.len }) catch {};
    // CGRAM digest: same tiles + same tilemap rendering differently can
    // only be the palette (measured: SM's Ceres room corrupts to stripes
    // when CGRAM diverges while VRAM stays identical).
    w.print("cgram_full=", .{}) catch {};
    for (p.cgram) |cw| w.print("{x:0>4}", .{cw}) catch {};
    w.print("\n", .{}) catch {};
    var cgsum: u32 = 0;
    for (p.cgram) |c| cgsum +%= c;
    w.print("cgram_sum={x:0>8} bg1pal={x:0>4},{x:0>4},{x:0>4},{x:0>4} bg2pal={x:0>4},{x:0>4}\n", .{
        cgsum, p.cgram[0], p.cgram[1], p.cgram[2], p.cgram[3], p.cgram[0x20], p.cgram[0x21],
    }) catch {};
    // Window + mosaic: vertical banding that VRAM/CGRAM cannot explain
    // lives here (the window carves columns; mosaic blocks them).
    w.print("mosaic=0x{x:0>2} w12sel=0x{x:0>2} w34sel=0x{x:0>2} wobjsel=0x{x:0>2} wh0={d} wh1={d} wh2={d} wh3={d} wbglog=0x{x:0>2} tmw=0x{x:0>2} tsw=0x{x:0>2}\n", .{
        p.mosaic, p.w12sel, p.w34sel, p.wobjsel, p.wh0, p.wh1, p.wh2, p.wh3, p.wbglog, p.tmw, p.tsw,
    }) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = w.buffered() }) catch {};
    out.print("wrote {s}\n", .{path}) catch {};
    out.flush() catch {};
}

/// `--dump-ram`: WRAM (128K), BW-RAM's first 64K, VRAM and I-RAM after the
/// run, plus the CPU's resting place. The tool that found every window-mode
/// blocker so far.
/// The bytes that stand for the game's battery save: the cart's mapped
/// SRAM, or — on a window conversion, whose header declares no battery —
/// the lifted save region at the front of the upper BW-RAM half (the
/// generator moves the game's save chip there; see the SDL's saves.zig).
pub fn saveRegion(cart: anytype) ?[]u8 {
    if (cart.chip == .sa1 and !cart.hasBattery() and cart.sram_hi_mask >= 0x7FFF) return cart.sram_hi[0..0x8000];
    if (cart.sram_mask == 0) return null;
    return cart.sram[0 .. cart.sram_mask + 1];
}

/// `--cov-out`: the coverage maps the generator kept (see sa1gen.dbg_keep_cov).
pub fn writeCovOut(io: std.Io, gpa: std.mem.Allocator, out: *std.Io.Writer, args: Args) !void {
    const prefix = args.cov_out orelse return;
    const pairs = [_]struct { suffix: []const u8, data: ?[]u8 }{
        .{ .suffix = ".usage", .data = core.sa1gen.dbg_usage_kept },
        .{ .suffix = ".cov", .data = core.sa1gen.dbg_cov_kept },
    };
    for (pairs) |pr| {
        const data = pr.data orelse continue;
        const path = try std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, pr.suffix });
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch {
            try out.print("error: cannot write '{s}'\n", .{path});
            continue;
        };
        try out.print("wrote {s} ({} bytes)\n", .{ path, data.len });
    }
}

/// `--code-map`: the disassembly's per-byte verdict into the generator
/// (see sa1gen.dbg_code_map). Loaded once, by whichever path runs.
pub fn loadCodeMap(io: std.Io, gpa: std.mem.Allocator, out: *std.Io.Writer, args: Args) !void {
    if (core.sa1gen.dbg_code_map != null) return;
    if (args.code_map) |cmp| {
        const data = std.Io.Dir.cwd().readFileAlloc(io, cmp, gpa, .limited(32 * 1024 * 1024)) catch {
            try out.print("error: cannot read the code map '{s}'\n", .{cmp});
            try out.flush();
            std.process.exit(1);
        };
        if (data.len != 0x100_0000) {
            try out.print("error: the code map '{s}' is {} bytes, expected a 16 MiB flag map\n", .{ cmp, data.len });
            try out.flush();
            std.process.exit(1);
        }
        core.sa1gen.dbg_code_map = data;
    }
}

/// `--dump-srm`: the game's battery save as a plain .srm (see saveRegion).
pub fn dumpSrm(io: std.Io, con: *core.AnyConsole, path: []const u8) void {
    const cart = con.cartridge();
    const sram = saveRegion(cart) orelse return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = sram }) catch return;
    std.debug.print("wrote {s} ({d} bytes of battery SRAM)\n", .{ path, sram.len });
}

/// The split's S-CPU set file: little-endian u24 CPU addresses, sorted.
pub fn readScpuSet(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]const u24 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024));
    const n = bytes.len / 3;
    const list = try gpa.alloc(u24, n);
    for (0..n) |k| list[k] = @as(u24, bytes[k * 3]) | (@as(u24, bytes[k * 3 + 1]) << 8) | (@as(u24, bytes[k * 3 + 2]) << 16);
    std.mem.sort(u24, list, {}, std.sort.asc(u24));
    return list;
}

/// Merge the run's marks into the set file (a union across runs: one
/// file gathers every surface's census).
pub fn writeScpuSet(io: std.Io, gpa: std.mem.Allocator, path: []const u8) void {
    const m = core.wdc65816.dbg_scpu_set orelse return;
    if (readScpuSet(io, gpa, path)) |old| {
        for (old) |ac| {
            if ((ac & 0xFFFF) >= 0x8000 and ((ac >> 16) & 0x7F) < 0x40) m[(@as(usize, (ac >> 16) & 0x3F) << 15) | (ac & 0x7FFF)] = 1;
        }
    } else |_| {}
    var list: std.array_list.Managed(u8) = .init(gpa);
    var n: usize = 0;
    for (m, 0..) |b, off| {
        if (b == 0) continue;
        const ac: u24 = (@as(u24, @intCast(off >> 15)) << 16) | 0x8000 | @as(u24, @intCast(off & 0x7FFF));
        list.appendSlice(&.{ @truncate(ac), @truncate(ac >> 8), @truncate(ac >> 16) }) catch return;
        n += 1;
    }
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = list.items }) catch {};
    std.debug.print("[scpu-set] {} instruction address(es) in the SA-1's copy -> {s}\n", .{ n, path });
}

pub fn dumpRam(io: std.Io, gpa: std.mem.Allocator, con: *core.AnyConsole, path: []const u8) void {
    const fc = &con.fast;
    // Layout of the dump (offsets): WRAM $0000, BW-RAM $20000, VRAM $40000,
    // I-RAM $50000, ARAM $50800, CGRAM $60800, OAM $60A00.
    const buf = gpa.alloc(u8, 0x20000 + 0x20000 + 0x10000 + 0x800 + 0x10000 + 0x200 + 0x220) catch {
        std.debug.print("[dump] out of memory, {s} not written\n", .{path});
        return;
    };
    defer gpa.free(buf);
    @memset(buf, 0);
    @memcpy(buf[0..0x20000], &fc.bus.wram.data);
    if (fc.bus.cart.chip == .sa1) @memcpy(buf[0x20000..][0..0x20000], fc.bus.sa1.bwram[0..0x20000]);
    @memcpy(buf[0x40000..][0..0x10000], std.mem.sliceAsBytes(fc.bus.ppu.vram[0..0x8000]));
    if (fc.bus.cart.chip == .sa1) @memcpy(buf[0x50000..][0..0x800], &fc.bus.sa1.iram);
    @memcpy(buf[0x50800..][0..0x10000], &fc.bus.apu.aram);
    @memcpy(buf[0x60800..][0..0x200], std.mem.sliceAsBytes(fc.bus.ppu.cgram[0..256]));
    @memcpy(buf[0x60A00..][0..0x220], &fc.bus.ppu.oam);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf }) catch {};
    std.debug.print("[dump] pc={x:0>2}:{x:0>4} a={x:0>4} x={x:0>4} y={x:0>4} d={x:0>4} s={x:0>4} dbr={x:0>2} p={x:0>2} clk={}\n", .{ fc.cpu.regs.pbr, fc.cpu.regs.pc, fc.cpu.regs.c, fc.cpu.regs.x, fc.cpu.regs.y, fc.cpu.regs.d, fc.cpu.regs.s, fc.cpu.regs.dbr, fc.cpu.regs.p, fc.bus.clock });
    if (fc.bus.cart.chip == .sa1)
        std.debug.print("[dump] sa1 pc={x:0>2}:{x:0>4} smeg={x} cmeg={x} id={x:0>2} busy={x:0>2}\n", .{ fc.bus.sa1.cpu.regs.pbr, fc.bus.sa1.cpu.regs.pc, fc.bus.sa1.smeg, fc.bus.sa1.cmeg, fc.bus.sa1.iram[0x387], fc.bus.sa1.iram[0x38A] });
    std.debug.print("[dump] apu pc={x:0>4} control={x:0>2} in={x:0>2} {x:0>2} {x:0>2} {x:0>2} out={x:0>2} {x:0>2} {x:0>2} {x:0>2}\n", .{ fc.bus.apu.smp.regs.pc, fc.bus.apu.control, fc.bus.apu.cpu_in[0], fc.bus.apu.cpu_in[1], fc.bus.apu.cpu_in[2], fc.bus.apu.cpu_in[3], fc.bus.apu.cpu_out[0], fc.bus.apu.cpu_out[1], fc.bus.apu.cpu_out[2], fc.bus.apu.cpu_out[3] });
}
