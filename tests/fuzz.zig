//! Deterministic fuzz harness (`zig build fuzz`). Two stages, one seeded PRNG:
//!
//!   A. PPU: randomize VRAM/CGRAM/OAM, hammer the $2100-$213F register file,
//!      then render a full frame. Run in Debug, every index/overflow safety
//!      check in the renderer is armed — the stage's job is to prove no
//!      register/memory state can crash or trap the fast renderer.
//!   B. Console: boot a synthetic spin-loop cartridge and stream random
//!      writes/reads through the bus (PPU, APU ports, WRAM port, CPU I/O,
//!      DMA registers — including live $420B/$420C triggers) between frames.
//!      Every few iterations the whole machine is serialized, restored into a
//!      shadow console, and both are stepped one frame: any divergence means
//!      a state field was missed or restored wrong (the M6 save-state gate).
//!
//! The run is fully deterministic: a fixed default seed makes CI reproducible,
//! and any failure is reproduced by re-running with the printed seed
//! (`-Dfuzz-seed=<n>`, decimal). Crash-freedom and roundtrip equality are the
//! gates; the printed state hashes are informational.
//!
//! Options (see build.zig): -Dfuzz-iters=<n>  -Dfuzz-seed=<n>

const std = @import("std");
const core = @import("snes_core");
const options = @import("fuzz_options");

const Ppu = core.ppu.Ppu;
const serialize = core.serialize;

const default_iters: u32 = 96;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const iters: u32 = if (options.iters != 0) options.iters else default_iters;
    // Print the seed up front (and flush) so a safety-check panic further down
    // still leaves the reproduction recipe on screen.
    // Decimal, because that's the form -Dfuzz-seed accepts back.
    try out.print("fuzz: seed {}, {} iterations per stage\n", .{ options.seed, iters });
    try out.flush();

    const ppu_hash = try fuzzPpu(gpa, iters);
    try out.print("stage A (ppu):     {} frames rendered, state hash {x:0>16}\n", .{ iters, ppu_hash });
    try out.flush();

    const con_hash = try fuzzConsole(gpa, out, iters, 0x00);
    try out.print("stage B (console): {} frames run, state hash {x:0>16}\n", .{ iters, con_hash });
    try out.flush();

    // The same stage on an SA-1 cart: the chip is attached, caught up every
    // scanline, and its SNES-side MMIO window joins the write ranges — random
    // traffic can start/stop the second CPU, and the save/load roundtrip
    // invariant now covers coprocessor state. Before this, no fuzzing touched
    // any coprocessor at all.
    const sa1_hash = try fuzzConsole(gpa, out, iters, 0x34);
    try out.print("stage C (sa1):     {} frames run, state hash {x:0>16}\n", .{ iters, sa1_hash });
    try out.print("fuzz: ok\n", .{});
    try out.flush();
}

fn mix(h: u64, v: u64) u64 {
    return (h ^ v) *% 0x100000001b3;
}

// --- stage A: PPU register/memory fuzz --------------------------------------

fn fuzzPpu(gpa: std.mem.Allocator, iters: u32) !u64 {
    var prng = std.Random.DefaultPrng.init(options.seed);
    const rand = prng.random();

    const p = try gpa.create(Ppu);
    p.* = Ppu.init;

    var hash: u64 = 0xcbf29ce484222325;
    for (0..iters) |_| {
        // Fresh random video memories; postLoad rebuilds the derived palette.
        rand.bytes(std.mem.asBytes(&p.vram));
        rand.bytes(std.mem.asBytes(&p.cgram));
        rand.bytes(&p.oam);
        p.postLoad();

        // Hammer the whole register file, reads interleaved with writes (the
        // read ports have side effects: OAM/VRAM/CGRAM address advances).
        for (0..384) |_| {
            const reg = 0x2100 + rand.uintLessThan(u16, 0x40);
            if (rand.uintLessThan(u8, 8) == 0) {
                _ = p.readReg(reg, rand.int(u8));
            } else {
                p.writeReg(reg, rand.int(u8));
            }
        }
        // Bias toward actually rendering: most iterations force the display on
        // (random brightness); the rest keep whatever INIDISP the hammering left.
        if (rand.uintLessThan(u8, 4) != 0) p.writeReg(0x2100, rand.int(u4));

        const lines: u32 = if (p.overscan()) core.timing.visible_lines_239 else core.timing.visible_lines_224;
        for (0..lines) |line| p.renderScanline(@intCast(line));
        hash = mix(hash, core.console.hashFrame(p.frame(lines)));
    }
    return hash;
}

// --- stage B: whole-console fuzz + save/load roundtrip -----------------------

/// Weighted bus address ranges the fuzzer writes to. DMA registers and the
/// PPU file get the most attention; $4200-$420D includes live MDMAEN/HDMAEN
/// triggers, $2140-$2143 walks the APU mailbox (and its HLE boot protocol).
const write_ranges = [_]struct { base: u24, len: u16, weight: u8 }{
    .{ .base = 0x2100, .len = 0x40, .weight = 4 },
    // SA-1 SNES-side MMIO (CCNT and friends). Ignored by a chipless cart, so
    // the plain stage keeps its determinism while the SA-1 stage gets live
    // start/stop/IRQ traffic on the second CPU.
    .{ .base = 0x2200, .len = 0x40, .weight = 1 },
    .{ .base = 0x4300, .len = 0x80, .weight = 3 },
    .{ .base = 0x4200, .len = 0x0E, .weight = 2 },
    .{ .base = 0x2140, .len = 0x04, .weight = 2 },
    .{ .base = 0x2180, .len = 0x04, .weight = 1 },
};

/// Read ranges: PPU read ports (counter latches, data-port reads with address
/// side effects), APU mailbox, and CPU I/O status ($4210 RDNMI / $4211 TIMEUP
/// acks, math results, joypads).
const read_ranges = [_]struct { base: u24, len: u16 }{
    .{ .base = 0x2134, .len = 0x0C },
    .{ .base = 0x2140, .len = 0x04 },
    .{ .base = 0x4210, .len = 0x10 },
};

fn pickWrite(rand: std.Random) u24 {
    comptime var total: u32 = 0;
    inline for (write_ranges) |r| total += r.weight;
    var pick = rand.uintLessThan(u32, total);
    inline for (write_ranges) |r| {
        if (pick < r.weight) return r.base + rand.uintLessThan(u16, r.len);
        pick -= r.weight;
    }
    unreachable;
}

fn fuzzConsole(gpa: std.mem.Allocator, out: *std.Io.Writer, iters: u32, chipset: u8) !u64 {
    @setEvalBranchQuota(20000);
    var prng = std.Random.DefaultPrng.init(options.seed ^ 0xB5B5B5B5B5B5B5B5);
    const rand = prng.random();

    const rom = try buildSpinRom(gpa, chipset);
    const con = try gpa.create(core.FastConsole);
    con.init(try core.Cartridge.load(gpa, rom));
    const shadow = try gpa.create(core.FastConsole);
    shadow.init(try core.Cartridge.load(gpa, rom));

    const state_size = comptime serialize.byteSize(core.FastConsole);
    const buf_a = try gpa.alloc(u8, state_size);
    const buf_b = try gpa.alloc(u8, state_size);

    var hash: u64 = 0xcbf29ce484222325;
    for (0..iters) |iter| {
        // A burst of random register traffic, then one frame of real machine
        // time (CPU spin loop + NMI, HDMA, APU catch-up, renderer).
        const writes = 1 + rand.uintLessThan(u32, 24);
        for (0..writes) |_| con.bus.write8(pickWrite(rand), rand.int(u8));
        for (0..4) |_| {
            const r = read_ranges[rand.uintLessThan(u8, read_ranges.len)];
            _ = con.bus.read8(r.base + rand.uintLessThan(u16, r.len));
        }
        con.runFrame();
        hash = mix(hash, core.console.hashFrame(con.framebuffer()));

        // Save/load roundtrip invariant: restore into the shadow console and
        // step both one frame — divergence means unsaved or unrestored state.
        if (iter % 8 == 7) {
            _ = serialize.write(core.FastConsole, con, buf_a);
            _ = try serialize.read(core.FastConsole, shadow, buf_a);
            shadow.postLoad();

            con.runFrame();
            shadow.runFrame();
            hash = mix(hash, core.console.hashFrame(con.framebuffer()));

            _ = serialize.write(core.FastConsole, con, buf_a);
            _ = serialize.write(core.FastConsole, shadow, buf_b);
            const fb_ok = core.console.hashFrame(con.framebuffer()) ==
                core.console.hashFrame(shadow.framebuffer());
            if (!fb_ok or !std.mem.eql(u8, buf_a, buf_b)) {
                try out.print(
                    "FAIL save/load roundtrip diverged at iteration {} (seed {}): fb {s}, state {s}\n",
                    .{ iter, options.seed, if (fb_ok) "ok" else "DIFFERS", if (std.mem.eql(u8, buf_a, buf_b)) "ok" else "DIFFERS" },
                );
                try out.flush();
                std.process.exit(1);
            }
        }
    }
    return hash;
}

/// Minimal LoROM: reset code masks IRQs and spins; every interrupt vector
/// lands on an RTI so random NMITIMEN/IRQ traffic can't derail the CPU.
fn buildSpinRom(gpa: std.mem.Allocator, chipset: u8) ![]u8 {
    const rom = try gpa.alloc(u8, 0x8000);
    @memset(rom, 0);

    // $00:8000: SEI ; loop: BRA loop      $00:8010: RTI
    const reset_code = [_]u8{ 0x78, 0x80, 0xFE };
    @memcpy(rom[0..reset_code.len], &reset_code);
    rom[0x10] = 0x40; // RTI

    const h = rom[0x7FC0..][0..64];
    @memcpy(h[0..21], "FUZZ SPIN            ");
    h[0x15] = 0x20; // LoROM, SlowROM
    h[0x16] = chipset; // 0x00 = ROM only; 0x34 attaches an SA-1
    h[0x17] = 5; // 32 KiB
    h[0x18] = 5; // 32 KiB SRAM/BW-RAM, so an attached SA-1 has memory to see
    std.mem.writeInt(u16, h[0x1C..0x1E], 0x0F0F, .little); // complement
    std.mem.writeInt(u16, h[0x1E..0x20], 0xF0F0, .little); // checksum
    // Emulation-mode vectors: COP, BRK (unused slot), ABORT, NMI, RESET, IRQ/BRK.
    for ([_]usize{ 0x7FF4, 0x7FF6, 0x7FF8, 0x7FFA, 0x7FFE }) |v| {
        std.mem.writeInt(u16, rom[v..][0..2], 0x8010, .little);
    }
    std.mem.writeInt(u16, rom[0x7FFC..0x7FFE], 0x8000, .little);
    return rom;
}
