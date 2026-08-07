//! Builds the whole-game-migration demo ROM: the smallest honest *game* that
//! passes `--gen-sa1-patch --whole-game` end to end.
//!
//! It is shaped to the vertical slice's contract on purpose — and to prove
//! the contract is satisfiable by a real program, not just by refusals:
//!
//! - LoROM, no SRAM, no coprocessor; all code in bank $00.
//! - WRAM working set: two bytes of low WRAM plus the stack — comfortably
//!   inside the SA-1's identity-mapped I-RAM window.
//! - Every MMIO access is a plain 8-bit LDA/STA/STZ absolute: INIDISP,
//!   CGADD/CGDATA, NMITIMEN. Nothing indexed, nothing long, no DMA, no
//!   WRAM port.
//! - NMI only, one handler, and — the part that decides S4 — every PPU
//!   write happens inside the handler, i.e. inside vblank. The mailbox
//!   round-trips the migrated build adds cost microseconds against a
//!   ~1.1 ms vblank, so the writes land in the same vblank in both runs
//!   and every frame hashes identical: the strict tier of the gate.
//!
//! What it shows: the full-screen backdrop cycling through BGR555 — a new
//! color every frame, driven by a 16-bit counter in low WRAM. Every frame
//! is a distinct picture, so the differential gate is comparing a real
//! animation, not a static screen.
//!
//! `zig build wg-demo` writes zig-out/wg-demo.sfc; the CI patchgen runner
//! builds the same image in memory and drives the whole pipeline over it.

const std = @import("std");

pub const rom_size = 64 * 1024;

/// The game, hand-assembled. Reset at $8000, NMI handler at $8020.
const code = [_]u8{
    // --- reset ---
    0x78, // 8000  SEI
    0x18, 0xFB, // 8001  CLC / XCE          native mode
    0xE2, 0x30, // 8003  SEP #$30           8-bit A/X/Y
    0xA9, 0x8F, // 8005  LDA #$8F
    0x8D, 0x00, 0x21, // 8007  STA $2100    forced blank while we set up
    0x64, 0x20, // 800A  STZ $20            color counter low
    0x64, 0x21, // 800C  STZ $21            color counter high
    0xA9, 0x80, // 800E  LDA #$80
    0x8D, 0x00, 0x42, // 8010  STA $4200    NMI on
    0x80, 0xFE, // 8013  BRA *              everything else happens in vblank
    // --- padding to the handler ---
    0xFF, 0xFF,
    0xFF, 0xFF,
    0xFF, 0xFF,
    0xFF, 0xFF,
    0xFF, 0xFF,
    0xFF,
    // --- NMI handler ($8020): runs once per vblank ---
    0x48, // 8020  PHA
    0xA9, 0x0F, // 8021  LDA #$0F
    0x8D, 0x00, 0x21, // 8023  STA $2100    screen on, full brightness
    0x9C, 0x21, 0x21, // 8026  STZ $2121    CGADD = 0 (the backdrop entry)
    0xAD, 0x20, 0x00, // 8029  LDA $0020    counter low (absolute on purpose:
    0x8D, 0x22, 0x21, // 802C  STA $2122      exercises the low-abs pass-through)
    0xAD, 0x21, 0x00, // 802F  LDA $0021
    0x8D, 0x22, 0x21, // 8032  STA $2122    CGRAM[0] = counter (BGR555)
    0xE6, 0x20, // 8035  INC $20
    0xD0, 0x02, // 8037  BNE +2
    0xE6, 0x21, // 8039  INC $21
    0x68, // 803B  PLA
    0x40, // 803C  RTI
};

/// Build the ROM image in memory.
pub fn buildRom(gpa: std.mem.Allocator) ![]u8 {
    const rom = try gpa.alloc(u8, rom_size);
    @memset(rom, 0xFF); // one huge padding run = free space for the carve
    @memcpy(rom[0..code.len], &code);

    const h = rom[0x7FC0..][0..64];
    @memcpy(h[0..21], "WHOLE-GAME DEMO      ");
    h[0x15] = 0x20; // LoROM, SlowROM
    h[0x16] = 0x00; // no chip
    h[0x17] = 8; // 256 KiB class (matches the test-ROM convention)
    h[0x18] = 0; // no SRAM
    std.mem.writeInt(u16, h[0x1C..0x1E], 0xFFFF, .little); // complement
    std.mem.writeInt(u16, h[0x1E..0x20], 0x0000, .little); // checksum
    @memset(h[0x20..0x40], 0);
    std.mem.writeInt(u16, h[0x2A..0x2C], 0x8020, .little); // native NMI
    std.mem.writeInt(u16, h[0x3C..0x3E], 0x8000, .little); // reset
    return rom;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var it = try init.minimal.args.iterateAllocator(gpa);
    _ = it.skip(); // program name
    const path = it.next() orelse "wg-demo.sfc";

    const rom = try buildRom(gpa);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = rom });

    var buf: [256]u8 = undefined;
    var w: std.Io.File.Writer = .init(.stdout(), io, &buf);
    try w.interface.print("wrote {s} ({} bytes)\n", .{ path, rom.len });
    try w.interface.flush();
}
