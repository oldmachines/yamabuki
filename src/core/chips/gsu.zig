//! Super FX (GSU) coprocessor: the RISC CPU in Star Fox-class cartridges.
//!
//! The GSU shares the cartridge ROM and cart RAM with the SNES and exposes
//! sixteen 16-bit registers plus control MMIO at $3000-$33FF. Execution uses
//! a one-byte prefetch pipeline: while an opcode executes, the next byte is
//! already fetched, which is where the architecture's branch delay slots come
//! from. R15 is the program counter; the main loop increments it after each
//! instruction unless the instruction itself wrote R15 (a jump), so during
//! execution R15 reads as the address of the *next* byte. Register-level
//! behavior (flags, pipeline order, cache validity, plot addressing) follows
//! the hardware as documented by fullsnes and the ares/bsnes research notes;
//! it is validated end-to-end by the 60 krom GSU test ROMs.
//!
//! Scheduling is catch-up driven, like the APU: the chip banks master-clock
//! cycles (its nominal clock is the 21.477 MHz master clock) and consumes
//! them per memory access when the SNES touches its MMIO or at each scanline
//! end. Cycle costs are approximate (cache 1-2, ROM/RAM 5-6 per byte, matching
//! the documented wait states at 21/10.7 MHz) — deterministic, not cycle-exact.
//! Fast-core simplifications, documented here on purpose:
//!  - The ROM/RAM buffers complete synchronously (no overlapped prefetch), so
//!    the SFR "R" flag never reads 1.
//!  - SNES reads of cart ROM/RAM while the GSU owns them (RON/RAN during GO)
//!    return the real data instead of the open-bus/vector pattern.

const std = @import("std");

/// SCMR color depth (bits 0-1) to bits per pixel; md=2 behaves as 4bpp.
fn bppOf(md: u2) u4 {
    return switch (md) {
        0 => 2,
        1, 2 => 4,
        3 => 8,
    };
}

pub const Gsu = struct {
    // Memory wiring into the cartridge, re-attached on init and postLoad.
    pub const serialize_skip = .{ "rom", "rom_mask", "ram", "ram_mask" };

    rom: [*]const u8,
    rom_mask: u32,
    ram: [*]u8,
    ram_mask: u32,

    /// R0-R15. R14 fetches the ROM buffer when written, R15 is the PC.
    r: [16]u16,
    // SFR flags (il/ih are never observable at instruction granularity and
    // the ROM-buffer R flag is always 0 in the synchronous model).
    z: bool,
    cy: bool,
    s: bool,
    ov: bool,
    go: bool,
    alt1: bool,
    alt2: bool,
    b: bool,
    irq: bool,
    /// IRQ line into the CPU: irq flag gated by the CFGR mask bit.
    irq_line: bool,

    sreg: u8,
    dreg: u8,
    pipeline: u8,
    pbr: u8,
    rombr: u8,
    rambr: u8,
    cbr: u16,
    scbr: u8,
    scmr: u8,
    colr: u8,
    por: u8,
    bramr: u8,
    cfgr: u8,
    clsr: u8,
    rom_buffer: u8,
    /// Last RAM address accessed (SBK stores through it).
    ram_addr: u16,
    r14_modified: bool,
    r15_modified: bool,

    /// 512-byte code cache in 16-byte lines; a line becomes valid when its
    /// last byte is filled (by execution) or written (by the SNES).
    cache: [512]u8,
    cache_valid: [32]bool,

    // Pixel cache: one 8-pixel character row accumulated by PLOT and flushed
    // to the RAM bitplanes when the row changes, fills, or RPIX forces it.
    px_offset: u16,
    px_bitpend: u8,
    px_data: [8]u8,

    /// Master-clock timestamp of the last catch-up.
    last_sync: u64,
    /// Banked master cycles not yet consumed by execution.
    budget: i64,

    pub const init: Gsu = .{
        .rom = undefined,
        .rom_mask = 0,
        .ram = undefined,
        .ram_mask = 0,
        .r = @splat(0),
        .z = false,
        .cy = false,
        .s = false,
        .ov = false,
        .go = false,
        .alt1 = false,
        .alt2 = false,
        .b = false,
        .irq = false,
        .irq_line = false,
        .sreg = 0,
        .dreg = 0,
        .pipeline = 0x01, // NOP primes the pipe at power-on and after STOP
        .pbr = 0,
        .rombr = 0,
        .rambr = 0,
        .cbr = 0,
        .scbr = 0,
        .scmr = 0,
        .colr = 0,
        .por = 0,
        .bramr = 0,
        .cfgr = 0,
        .clsr = 0,
        .rom_buffer = 0,
        .ram_addr = 0,
        .r14_modified = false,
        .r15_modified = false,
        .cache = @splat(0),
        .cache_valid = @splat(false),
        .px_offset = 0xFFFF,
        .px_bitpend = 0,
        .px_data = @splat(0),
        .last_sync = 0,
        .budget = 0,
    };

    /// Wire the shared cartridge ROM and cart RAM. Must be called after init
    /// and after deserialization, before any execution.
    pub fn attach(self: *Gsu, rom: []const u8, rom_mask: u32, ram: [*]u8, ram_mask: u32) void {
        self.rom = rom.ptr;
        self.rom_mask = rom_mask;
        self.ram = ram;
        self.ram_mask = ram_mask;
    }

    // --- scheduling --------------------------------------------------------

    /// Run the GSU up to the given master-clock time. Called before every
    /// MMIO access and once per scanline.
    pub fn catchUp(self: *Gsu, master_clock: u64) void {
        if (master_clock <= self.last_sync) {
            self.last_sync = master_clock; // clock rewound (state load): resync
            return;
        }
        const delta = master_clock - self.last_sync;
        self.last_sync = master_clock;
        if (!self.go) return;
        self.budget += @intCast(delta);
        while (self.go and self.budget > 0) self.stepOnce();
    }

    fn chargeMem(self: *Gsu) void {
        self.budget -= if (self.clsr & 1 != 0) 5 else 6;
    }

    fn chargeCache(self: *Gsu) void {
        self.budget -= if (self.clsr & 1 != 0) 1 else 2;
    }

    // --- memory ------------------------------------------------------------

    /// Cartridge ROM as the GSU sees it: banks $00-$3F are the LoROM view
    /// (with $0000-$7FFF mirroring $8000-$FFFF), banks $40-$5F are linear.
    fn readRom(self: *const Gsu, bank: u8, addr: u16) u8 {
        const full = (@as(u32, bank & 0x7F) << 16) | addr;
        const off = if (bank & 0x60 == 0x40)
            full
        else
            ((full & 0x3F_0000) >> 1) | (full & 0x7FFF);
        return self.rom[off & self.rom_mask];
    }

    fn ramIndex(self: *const Gsu, addr17: u32) u32 {
        return addr17 & self.ram_mask;
    }

    /// Data RAM access through RAMBR (banks $70-$71).
    fn readRamData(self: *Gsu, addr: u16) u8 {
        self.chargeMem();
        return self.ram[self.ramIndex(@as(u32, self.rambr & 1) << 16 | addr)];
    }

    fn writeRamData(self: *Gsu, addr: u16, value: u8) void {
        self.chargeMem();
        self.ram[self.ramIndex(@as(u32, self.rambr & 1) << 16 | addr)] = value;
    }

    /// Program byte at PBR:addr (no cache, no cost).
    fn readProgByte(self: *const Gsu, addr: u16) u8 {
        const bank = self.pbr;
        if (bank <= 0x5F) return self.readRom(bank, addr);
        if (bank & 0x7E == 0x70) return self.ram[self.ramIndex(@as(u32, bank & 1) << 16 | addr)];
        return 0;
    }

    /// Opcode fetch: through the 512-byte cache window at [CBR, CBR+512),
    /// filling a whole 16-byte line on a miss, else straight from memory.
    fn readOpcode(self: *Gsu, addr: u16) u8 {
        const off = addr -% self.cbr;
        if (off < 512) {
            const line = off >> 4;
            if (!self.cache_valid[line]) {
                const dp: u16 = off & 0x1F0;
                const base: u16 = (self.cbr +% dp) & 0xFFF0;
                for (0..16) |i| {
                    self.chargeMem();
                    self.cache[dp + i] = self.readProgByte(base +% @as(u16, @intCast(i)));
                }
                self.cache_valid[line] = true;
            } else {
                self.chargeCache();
            }
            return self.cache[off];
        }
        self.chargeMem();
        return self.readProgByte(addr);
    }

    fn updateRomBuffer(self: *Gsu) void {
        self.chargeMem();
        self.rom_buffer = self.readRom(self.rombr, self.r[14]);
    }

    // --- pipeline ----------------------------------------------------------

    /// Consume the pipelined byte and refill from R15 without advancing it
    /// (the main loop's post-instruction increment covers the opcode byte).
    fn peekpipe(self: *Gsu) u8 {
        const result = self.pipeline;
        self.pipeline = self.readOpcode(self.r[15]);
        self.r15_modified = false;
        return result;
    }

    /// Consume the pipelined byte as an operand: advance R15 first, refill.
    fn pipe(self: *Gsu) u8 {
        const result = self.pipeline;
        self.r[15] +%= 1;
        self.pipeline = self.readOpcode(self.r[15]);
        self.r15_modified = false;
        return result;
    }

    fn stepOnce(self: *Gsu) void {
        const opcode = self.peekpipe();
        self.exec(opcode);
        if (self.r14_modified) {
            self.r14_modified = false;
            self.updateRomBuffer();
        }
        if (self.r15_modified) {
            self.r15_modified = false;
        } else {
            self.r[15] +%= 1;
        }
    }

    // --- register helpers --------------------------------------------------

    fn setReg(self: *Gsu, n: u4, v: u16) void {
        self.r[n] = v;
        if (n == 14) self.r14_modified = true;
        if (n == 15) self.r15_modified = true;
    }

    fn srcVal(self: *const Gsu) u16 {
        return self.r[self.sreg & 15];
    }

    fn setDest(self: *Gsu, v: u16) void {
        self.setReg(@intCast(self.dreg & 15), v);
    }

    fn destVal(self: *const Gsu) u16 {
        return self.r[self.dreg & 15];
    }

    /// End-of-instruction: prefix latches revert to R0 / plain mode.
    fn endPrefix(self: *Gsu) void {
        self.sreg = 0;
        self.dreg = 0;
        self.alt1 = false;
        self.alt2 = false;
        self.b = false;
    }

    fn setZS(self: *Gsu, v: u16) void {
        self.z = v == 0;
        self.s = v & 0x8000 != 0;
    }

    // --- color / plot ------------------------------------------------------

    fn colorSet(self: *const Gsu, source: u8) u8 {
        if (self.por & 0x04 != 0) return (self.colr & 0xF0) | (source >> 4); // high-nibble source
        if (self.por & 0x08 != 0) return (self.colr & 0xF0) | (source & 0x0F); // freeze high
        return source;
    }

    /// Character number for screen coordinates, per SCMR height (or OBJ mode):
    /// columns of 16/20/24 characters, or the OAM-style 16x16 quadrant grid.
    fn charNumber(self: *const Gsu, x: u8, y: u8) u32 {
        const xc = @as(u32, x & 0xF8);
        const yc = @as(u32, y & 0xF8);
        const ht: u2 = @intCast(((self.scmr >> 5) & 1) << 1 | ((self.scmr >> 2) & 1));
        const obj = self.por & 0x10 != 0 or ht == 3;
        if (obj) {
            return (@as(u32, y & 0x80) << 2) + (@as(u32, x & 0x80) << 1) +
                ((yc & 0x78) << 1) + ((xc & 0x78) >> 3);
        }
        return switch (ht) {
            0 => (xc << 1) + (yc >> 3), // 128 px: 16 chars per column
            1 => (xc << 1) + (xc >> 1) + (yc >> 3), // 160 px: 20 per column
            else => (xc << 1) + xc + (yc >> 3), // 192 px: 24 per column
        };
    }

    /// RAM byte offset of the first bitplane pair for pixel row (x,y).
    fn bitplaneBase(self: *const Gsu, x: u8, y: u8) u32 {
        const bpp = @as(u32, bppOf(@intCast(self.scmr & 3)));
        return self.charNumber(x, y) * (bpp << 3) + (@as(u32, self.scbr) << 10) + (@as(u32, y & 7) << 1);
    }

    fn plot(self: *Gsu, x: u8, y: u8) void {
        const md: u2 = @intCast(self.scmr & 3);
        if (self.por & 0x01 == 0) { // transparency enabled
            if (md == 3 and self.por & 0x08 == 0) {
                if (self.colr == 0) return;
            } else {
                if (self.colr & 0x0F == 0) return;
            }
        }

        var color = self.colr;
        if (self.por & 0x02 != 0 and md != 3) { // dither
            if ((x ^ y) & 1 != 0) color >>= 4;
            color &= 0x0F;
        }

        const offset = (@as(u16, y) << 5) + (x >> 3);
        if (offset != self.px_offset) {
            self.flushPixelCache();
            self.px_offset = offset;
        }
        const bit: u3 = @intCast((x & 7) ^ 7);
        self.px_data[bit] = color;
        self.px_bitpend |= @as(u8, 1) << bit;
        if (self.px_bitpend == 0xFF) self.flushPixelCache();
    }

    fn flushPixelCache(self: *Gsu) void {
        if (self.px_bitpend == 0) return;
        const x: u8 = @truncate(self.px_offset << 3);
        const y: u8 = @truncate(self.px_offset >> 5);
        const base = self.bitplaneBase(x, y);
        const bpp = bppOf(@intCast(self.scmr & 3));

        for (0..bpp) |n| {
            const byte_off = ((n >> 1) << 4) + (n & 1);
            var data: u8 = 0;
            for (0..8) |i| {
                data |= ((self.px_data[i] >> @intCast(n)) & 1) << @intCast(i);
            }
            const idx = self.ramIndex(base + @as(u32, @intCast(byte_off)));
            if (self.px_bitpend != 0xFF) {
                self.chargeMem();
                data = (data & self.px_bitpend) | (self.ram[idx] & ~self.px_bitpend);
            }
            self.chargeMem();
            self.ram[idx] = data;
        }
        self.px_bitpend = 0;
    }

    fn rpix(self: *Gsu, x: u8, y: u8) u8 {
        self.flushPixelCache();
        const base = self.bitplaneBase(x, y);
        const bpp = bppOf(@intCast(self.scmr & 3));
        const bit: u3 = @intCast((x & 7) ^ 7);
        var data: u8 = 0;
        for (0..bpp) |n| {
            const byte_off = ((n >> 1) << 4) + (n & 1);
            self.chargeMem();
            const plane = self.ram[self.ramIndex(base + @as(u32, @intCast(byte_off)))];
            data |= ((plane >> bit) & 1) << @intCast(n);
        }
        return data;
    }

    // --- instruction execution ---------------------------------------------

    fn exec(self: *Gsu, opcode: u8) void {
        const n: u4 = @intCast(opcode & 15);
        switch (opcode) {
            0x00 => { // STOP
                if (self.cfgr & 0x80 == 0) {
                    self.irq = true;
                    self.irq_line = true;
                }
                self.go = false;
                self.pipeline = 0x01;
                self.endPrefix();
            },
            0x01 => self.endPrefix(), // NOP
            0x02 => { // CACHE
                if (self.cbr != self.r[15] & 0xFFF0) {
                    self.cbr = self.r[15] & 0xFFF0;
                    self.cache_valid = @splat(false);
                }
                self.endPrefix();
            },
            0x03 => { // LSR
                const v = self.srcVal();
                self.cy = v & 1 != 0;
                self.setDest(v >> 1);
                self.setZS(self.destVal());
                self.endPrefix();
            },
            0x04 => { // ROL
                const v = self.srcVal();
                const carry = v & 0x8000 != 0;
                self.setDest((v << 1) | @intFromBool(self.cy));
                self.cy = carry;
                self.setZS(self.destVal());
                self.endPrefix();
            },
            0x05...0x0F => { // BRA/BLT/BGE/BNE/BEQ/BPL/BMI/BCC/BCS/BVC/BVS
                // Note the $06/$07 conditions: hardware "BGE e" assembles to
                // $06 (taken when S == OV) and "BLT e" to $07 (S != OV) —
                // verified against the bass-assembled krom PlotLine ROMs.
                const take = switch (opcode) {
                    0x05 => true,
                    0x06 => (self.s == self.ov),
                    0x07 => (self.s != self.ov),
                    0x08 => !self.z,
                    0x09 => self.z,
                    0x0A => !self.s,
                    0x0B => self.s,
                    0x0C => !self.cy,
                    0x0D => self.cy,
                    0x0E => !self.ov,
                    else => self.ov,
                };
                const disp: i8 = @bitCast(self.pipe());
                if (take) self.setReg(15, self.r[15] +% @as(u16, @bitCast(@as(i16, disp))));
                // Branches leave the prefix latches for the delay slot.
            },
            0x10...0x1F => { // TO Rn / MOVE Rn
                if (!self.b) {
                    self.dreg = n;
                } else {
                    self.setReg(n, self.srcVal());
                    self.endPrefix();
                }
            },
            0x20...0x2F => { // WITH Rn
                self.sreg = n;
                self.dreg = n;
                self.b = true;
            },
            0x30...0x3B => { // STW (Rn) / alt1: STB (Rn)
                self.ram_addr = self.r[n];
                const v = self.srcVal();
                self.writeRamData(self.ram_addr, @truncate(v));
                if (!self.alt1) self.writeRamData(self.ram_addr ^ 1, @truncate(v >> 8));
                self.endPrefix();
            },
            0x3C => { // LOOP
                self.setReg(12, self.r[12] -% 1);
                self.setZS(self.r[12]);
                if (!self.z) self.setReg(15, self.r[13]);
                self.endPrefix();
            },
            0x3D => { // ALT1
                self.b = false;
                self.alt1 = true;
            },
            0x3E => { // ALT2
                self.b = false;
                self.alt2 = true;
            },
            0x3F => { // ALT3
                self.b = false;
                self.alt1 = true;
                self.alt2 = true;
            },
            0x40...0x4B => { // LDW (Rn) / alt1: LDB (Rn)
                self.ram_addr = self.r[n];
                var v: u16 = self.readRamData(self.ram_addr);
                if (!self.alt1) v |= @as(u16, self.readRamData(self.ram_addr ^ 1)) << 8;
                self.setDest(v);
                self.endPrefix();
            },
            0x4C => { // PLOT / alt1: RPIX
                if (!self.alt1) {
                    self.plot(@truncate(self.r[1]), @truncate(self.r[2]));
                    self.setReg(1, self.r[1] +% 1);
                } else {
                    self.setDest(self.rpix(@truncate(self.r[1]), @truncate(self.r[2])));
                    self.setZS(self.destVal());
                }
                self.endPrefix();
            },
            0x4D => { // SWAP
                const v = self.srcVal();
                self.setDest((v >> 8) | (v << 8));
                self.setZS(self.destVal());
                self.endPrefix();
            },
            0x4E => { // COLOR / alt1: CMODE
                if (!self.alt1) {
                    self.colr = self.colorSet(@truncate(self.srcVal()));
                } else {
                    self.por = @truncate(self.srcVal() & 0x1F);
                }
                self.endPrefix();
            },
            0x4F => { // NOT
                self.setDest(~self.srcVal());
                self.setZS(self.destVal());
                self.endPrefix();
            },
            0x50...0x5F => { // ADD/ADC Rn or #n
                const operand: u16 = if (!self.alt2) self.r[n] else n;
                const a = self.srcVal();
                const carry: u32 = if (self.alt1) @intFromBool(self.cy) else 0;
                const r32 = @as(u32, a) + operand + carry;
                self.ov = (~(a ^ operand) & (operand ^ @as(u16, @truncate(r32))) & 0x8000) != 0;
                self.cy = r32 >= 0x1_0000;
                self.setDest(@truncate(r32));
                self.setZS(self.destVal());
                self.endPrefix();
            },
            0x60...0x6F => { // SUB/SBC Rn, SUB #n, CMP Rn
                const operand: u16 = if (!self.alt2 or self.alt1) self.r[n] else n;
                const a = self.srcVal();
                const borrow: i32 = if (!self.alt2 and self.alt1) @intFromBool(!self.cy) else 0;
                const r32 = @as(i32, a) - operand - borrow;
                const res: u16 = @truncate(@as(u32, @bitCast(r32)));
                self.ov = ((a ^ operand) & (a ^ res) & 0x8000) != 0;
                self.cy = r32 >= 0;
                self.setZS(res);
                self.s = res & 0x8000 != 0;
                if (!(self.alt2 and self.alt1)) self.setDest(res); // CMP writes no register
                self.endPrefix();
            },
            0x70 => { // MERGE (sprite-pair packing; the odd flag rules are hardware)
                const v = (self.r[7] & 0xFF00) | (self.r[8] >> 8);
                self.setDest(v);
                self.ov = v & 0xC0C0 != 0;
                self.s = v & 0x8080 != 0;
                self.cy = v & 0xE0E0 != 0;
                self.z = v & 0xF0F0 != 0;
                self.endPrefix();
            },
            0x71...0x7F => { // AND/BIC Rn or #n
                const operand: u16 = if (!self.alt2) self.r[n] else n;
                const v = self.srcVal() & (if (self.alt1) ~operand else operand);
                self.setDest(v);
                self.setZS(v);
                self.endPrefix();
            },
            0x80...0x8F => { // MULT/UMULT Rn or #n (signed/unsigned 8x8)
                const operand: u16 = if (!self.alt2) self.r[n] else n;
                const v: u16 = if (!self.alt1)
                    @bitCast(@as(i16, @as(i8, @bitCast(@as(u8, @truncate(self.srcVal()))))) *
                        @as(i16, @as(i8, @bitCast(@as(u8, @truncate(operand))))))
                else
                    @as(u16, @as(u8, @truncate(self.srcVal()))) * @as(u16, @as(u8, @truncate(operand)));
                self.setDest(v);
                self.setZS(v);
                self.endPrefix();
                if (self.cfgr & 0x20 == 0) self.chargeCache(); // standard-speed multiplier
            },
            0x90 => { // SBK: store to the last RAM address used
                const v = self.srcVal();
                self.writeRamData(self.ram_addr, @truncate(v));
                self.writeRamData(self.ram_addr ^ 1, @truncate(v >> 8));
                self.endPrefix();
            },
            0x91...0x94 => { // LINK #n
                self.setReg(11, self.r[15] +% n);
                self.endPrefix();
            },
            0x95 => { // SEX
                self.setDest(@bitCast(@as(i16, @as(i8, @bitCast(@as(u8, @truncate(self.srcVal())))))));
                self.setZS(self.destVal());
                self.endPrefix();
            },
            0x96 => { // ASR / alt1: DIV2 (rounds -1 to 0)
                const v = self.srcVal();
                self.cy = v & 1 != 0;
                const shifted: u16 = @bitCast(@as(i16, @bitCast(v)) >> 1);
                const adjust: u16 = if (self.alt1 and v == 0xFFFF) 1 else 0;
                self.setDest(shifted +% adjust);
                self.setZS(self.destVal());
                self.endPrefix();
            },
            0x97 => { // ROR
                const v = self.srcVal();
                const carry = v & 1 != 0;
                self.setDest((@as(u16, @intFromBool(self.cy)) << 15) | (v >> 1));
                self.cy = carry;
                self.setZS(self.destVal());
                self.endPrefix();
            },
            0x98...0x9D => { // JMP Rn / alt1: LJMP Rn
                if (!self.alt1) {
                    self.setReg(15, self.r[n]);
                } else {
                    self.pbr = @truncate(self.r[n] & 0x7F);
                    self.setReg(15, self.srcVal());
                    self.cbr = self.r[15] & 0xFFF0;
                    self.cache_valid = @splat(false);
                }
                self.endPrefix();
            },
            0x9E => { // LOB
                const v = self.srcVal() & 0xFF;
                self.setDest(v);
                self.z = v == 0;
                self.s = v & 0x80 != 0;
                self.endPrefix();
            },
            0x9F => { // FMULT / alt1: LMULT (16x16 signed, high word to dest)
                const product: u32 = @bitCast(@as(i32, @as(i16, @bitCast(self.srcVal()))) *
                    @as(i32, @as(i16, @bitCast(self.r[6]))));
                if (self.alt1) self.setReg(4, @truncate(product));
                self.setDest(@truncate(product >> 16));
                self.cy = product & 0x8000 != 0;
                self.setZS(self.destVal());
                self.endPrefix();
                // Long multiply cost: 3 (fast) / 7 (standard) internal cycles.
                const mults: i64 = if (self.cfgr & 0x20 != 0) 3 else 7;
                self.budget -= mults * (if (self.clsr & 1 != 0) @as(i64, 1) else 2);
            },
            0xA0...0xAF => { // IBT Rn,#s8 / alt1: LMS Rn,(y*2) / alt2: SMS (y*2),Rn
                if (self.alt1) {
                    self.ram_addr = @as(u16, self.pipe()) << 1;
                    var v: u16 = self.readRamData(self.ram_addr);
                    v |= @as(u16, self.readRamData(self.ram_addr ^ 1)) << 8;
                    self.setReg(n, v);
                } else if (self.alt2) {
                    self.ram_addr = @as(u16, self.pipe()) << 1;
                    self.writeRamData(self.ram_addr, @truncate(self.r[n]));
                    self.writeRamData(self.ram_addr ^ 1, @truncate(self.r[n] >> 8));
                } else {
                    const v: i8 = @bitCast(self.pipe());
                    self.setReg(n, @bitCast(@as(i16, v)));
                }
                self.endPrefix();
            },
            0xB0...0xBF => { // FROM Rn / MOVES Rn
                if (!self.b) {
                    self.sreg = n;
                } else {
                    const v = self.r[n];
                    self.setDest(v);
                    self.ov = v & 0x80 != 0;
                    self.setZS(v);
                    self.endPrefix();
                }
            },
            0xC0 => { // HIB
                const v = self.srcVal() >> 8;
                self.setDest(v);
                self.z = v == 0;
                self.s = v & 0x80 != 0;
                self.endPrefix();
            },
            0xC1...0xCF => { // OR/XOR Rn or #n
                const operand: u16 = if (!self.alt2) self.r[n] else n;
                const v = if (!self.alt1) self.srcVal() | operand else self.srcVal() ^ operand;
                self.setDest(v);
                self.setZS(v);
                self.endPrefix();
            },
            0xD0...0xDE => { // INC Rn
                self.setReg(n, self.r[n] +% 1);
                self.setZS(self.r[n]);
                self.endPrefix();
            },
            0xDF => { // GETC / alt2: RAMB / alt3: ROMB
                if (!self.alt2) {
                    self.colr = self.colorSet(self.rom_buffer);
                } else if (!self.alt1) {
                    self.rambr = @truncate(self.srcVal() & 1);
                } else {
                    self.rombr = @truncate(self.srcVal() & 0x7F);
                }
                self.endPrefix();
            },
            0xE0...0xEE => { // DEC Rn
                self.setReg(n, self.r[n] -% 1);
                self.setZS(self.r[n]);
                self.endPrefix();
            },
            0xEF => { // GETB / GETBH / GETBL / GETBS
                const byte = self.rom_buffer;
                const v: u16 = if (!self.alt1 and !self.alt2)
                    byte
                else if (self.alt1 and !self.alt2)
                    (@as(u16, byte) << 8) | (self.srcVal() & 0xFF)
                else if (!self.alt1)
                    (self.srcVal() & 0xFF00) | byte
                else
                    @bitCast(@as(i16, @as(i8, @bitCast(byte))));
                self.setDest(v);
                self.endPrefix();
            },
            0xF0...0xFF => { // IWT Rn,#u16 / alt1: LM Rn,(u16) / alt2: SM (u16),Rn
                if (self.alt1) {
                    self.ram_addr = self.pipe();
                    self.ram_addr |= @as(u16, self.pipe()) << 8;
                    var v: u16 = self.readRamData(self.ram_addr);
                    v |= @as(u16, self.readRamData(self.ram_addr ^ 1)) << 8;
                    self.setReg(n, v);
                } else if (self.alt2) {
                    self.ram_addr = self.pipe();
                    self.ram_addr |= @as(u16, self.pipe()) << 8;
                    self.writeRamData(self.ram_addr, @truncate(self.r[n]));
                    self.writeRamData(self.ram_addr ^ 1, @truncate(self.r[n] >> 8));
                } else {
                    var v: u16 = self.pipe();
                    v |= @as(u16, self.pipe()) << 8;
                    self.setReg(n, v);
                }
                self.endPrefix();
            },
        }
    }

    // --- SNES-side MMIO ($3000-$33FF in the system banks) --------------------

    /// SNES read; the bus catches the chip up to `master_clock` first.
    pub fn mmioRead(self: *Gsu, master_clock: u64, addr: u16, mdr: u8) u8 {
        self.catchUp(master_clock);
        const a = 0x3000 | (addr & 0x3FF);
        if (a >= 0x3100 and a <= 0x32FF) {
            return self.cache[(a - 0x3100 +% self.cbr) & 511];
        }
        if (a <= 0x301F) {
            const reg = self.r[(a >> 1) & 15];
            return if (a & 1 == 0) @truncate(reg) else @truncate(reg >> 8);
        }
        return switch (a) {
            0x3030 => @as(u8, @intFromBool(self.z)) << 1 |
                @as(u8, @intFromBool(self.cy)) << 2 |
                @as(u8, @intFromBool(self.s)) << 3 |
                @as(u8, @intFromBool(self.ov)) << 4 |
                @as(u8, @intFromBool(self.go)) << 5,
            0x3031 => blk: {
                const v = @as(u8, @intFromBool(self.alt1)) |
                    @as(u8, @intFromBool(self.alt2)) << 1 |
                    @as(u8, @intFromBool(self.b)) << 4 |
                    @as(u8, @intFromBool(self.irq)) << 7;
                self.irq = false;
                self.irq_line = false;
                break :blk v;
            },
            0x3034 => self.pbr,
            0x3036 => self.rombr,
            0x303B => 0x04, // VCR: GSU-2
            0x303C => self.rambr,
            0x303E => @truncate(self.cbr),
            0x303F => @truncate(self.cbr >> 8),
            else => mdr,
        };
    }

    /// SNES write; the bus catches the chip up to `master_clock` first.
    pub fn mmioWrite(self: *Gsu, master_clock: u64, addr: u16, value: u8) void {
        self.catchUp(master_clock);
        const a = 0x3000 | (addr & 0x3FF);
        if (a >= 0x3100 and a <= 0x32FF) {
            const idx = (a - 0x3100 +% self.cbr) & 511;
            self.cache[idx] = value;
            if (idx & 15 == 15) self.cache_valid[idx >> 4] = true;
            return;
        }
        if (a <= 0x301F) {
            const nreg: u4 = @intCast((a >> 1) & 15);
            if (a & 1 == 0) {
                self.r[nreg] = (self.r[nreg] & 0xFF00) | value;
            } else {
                self.r[nreg] = (@as(u16, value) << 8) | (self.r[nreg] & 0x00FF);
            }
            if (nreg == 14) self.updateRomBuffer();
            if (a == 0x301F) self.start();
            return;
        }
        switch (a) {
            0x3030 => {
                const was_go = self.go;
                self.z = value & 0x02 != 0;
                self.cy = value & 0x04 != 0;
                self.s = value & 0x08 != 0;
                self.ov = value & 0x10 != 0;
                const go = value & 0x20 != 0;
                if (was_go and !go) {
                    // Forced stop resets the cache window.
                    self.cbr = 0;
                    self.cache_valid = @splat(false);
                }
                if (!was_go and go) self.start() else self.go = go;
            },
            0x3031 => {
                self.alt1 = value & 0x01 != 0;
                self.alt2 = value & 0x02 != 0;
                self.b = value & 0x10 != 0;
                self.irq = value & 0x80 != 0;
            },
            0x3033 => self.bramr = value & 1,
            0x3034 => {
                self.pbr = value & 0x7F;
                self.cache_valid = @splat(false);
            },
            0x3037 => self.cfgr = value,
            0x3038 => self.scbr = value,
            0x3039 => self.clsr = value & 1,
            0x303A => self.scmr = value,
            else => {}, // ROMBR/RAMBR/CBR are set by GSU instructions only
        }
    }

    fn start(self: *Gsu) void {
        self.go = true;
        self.budget = 0;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

/// A Gsu wired to a scratch ROM+RAM pair, with the code placed at $8000 in
/// the LoROM view (GSU address $8000, bank 0) like the krom test ROMs.
const TestChip = struct {
    rom: [0x10000]u8,
    ram: [0x10000]u8,
    gsu: Gsu,

    fn create(code: []const u8) !*TestChip {
        const t = try testing.allocator.create(TestChip);
        t.rom = @splat(0);
        t.ram = @splat(0);
        @memcpy(t.rom[0..code.len], code);
        t.gsu = .init;
        t.gsu.attach(&t.rom, t.rom.len - 1, &t.ram, t.ram.len - 1);
        return t;
    }

    fn destroy(self: *TestChip) void {
        testing.allocator.destroy(self);
    }

    /// Start at the given GSU address and run until STOP (bounded).
    fn run(self: *TestChip, pc: u16) void {
        self.gsu.mmioWrite(0, 0x301E, @truncate(pc));
        self.gsu.mmioWrite(0, 0x301F, @truncate(pc >> 8));
        var clock: u64 = 0;
        while (self.gsu.go and clock < 1_000_000) {
            clock += 1000;
            self.gsu.catchUp(clock);
        }
    }
};

test "add sets carry, zero, and overflow like hardware" {
    // iwt r1,#$7FFF; iwt r0,#$8001; with r1; add r0; stop
    var t = try TestChip.create(&.{ 0xF1, 0xFF, 0x7F, 0xF0, 0x01, 0x80, 0x21, 0x50, 0x00, 0x01 });
    defer t.destroy();
    t.run(0x8000);
    try testing.expectEqual(@as(u16, 0), t.gsu.r[1]);
    try testing.expect(t.gsu.z);
    try testing.expect(t.gsu.cy);
    try testing.expect(!t.gsu.ov);
    try testing.expect(!t.gsu.go);

    // $7FFF + $7FFF overflows the signed range.
    var t2 = try TestChip.create(&.{ 0xF1, 0xFF, 0x7F, 0xF0, 0xFF, 0x7F, 0x21, 0x50, 0x00, 0x01 });
    defer t2.destroy();
    t2.run(0x8000);
    try testing.expectEqual(@as(u16, 0xFFFE), t2.gsu.r[1]);
    try testing.expect(t2.gsu.ov);
    try testing.expect(t2.gsu.s);
    try testing.expect(!t2.gsu.cy);
}

test "pipeline: move r13,r15 captures the next instruction address" {
    // The PlotPixel fill-loop idiom: with r15; to r13 lands R13 exactly on
    // the byte after the MOVE — the loop body start.
    // $8000: iwt r0,#0 (3) ; $8003: with r15 ; $8004: to r13 ; $8005: stop
    var t = try TestChip.create(&.{ 0xF0, 0x00, 0x00, 0x2F, 0x1D, 0x00, 0x01 });
    defer t.destroy();
    t.run(0x8000);
    try testing.expectEqual(@as(u16, 0x8005), t.gsu.r[13]);
}

test "branch: delay slot executes and target is A+2+d" {
    // $8000: bra +2 ; $8002: inc r1 (delay) ; $8003: inc r2 (skipped)
    // $8004: inc r3 ; $8005: stop ; $8006: nop (delay of stop... none)
    var t = try TestChip.create(&.{ 0x05, 0x02, 0xD1, 0xD2, 0xD3, 0x00, 0x01 });
    defer t.destroy();
    t.run(0x8000);
    try testing.expectEqual(@as(u16, 1), t.gsu.r[1]); // delay slot ran
    try testing.expectEqual(@as(u16, 0), t.gsu.r[2]); // branched over
    try testing.expectEqual(@as(u16, 1), t.gsu.r[3]); // target ran
}

test "loop with stw fills ram words" {
    // iwt r3,#0 ; iwt r12,#4 ; iwt r0,#$BEEF ; with r15 ; to r13
    // stw (r3) ; inc r3 ; loop ; inc r3 (delay) ; stop
    var t = try TestChip.create(&.{
        0xF3, 0x00, 0x00, 0xFC, 0x04, 0x00, 0xF0, 0xEF, 0xBE,
        0x2F, 0x1D, 0x33, 0xD3, 0x3C, 0xD3, 0x00, 0x01,
    });
    defer t.destroy();
    t.run(0x8000);
    try testing.expect(!t.gsu.go);
    for (0..4) |i| {
        try testing.expectEqual(@as(u8, 0xEF), t.ram[i * 2]);
        try testing.expectEqual(@as(u8, 0xBE), t.ram[i * 2 + 1]);
    }
    try testing.expectEqual(@as(u8, 0), t.ram[8]);
}

test "cache injection: snes writes code, gsu runs it from cache" {
    var t = try TestChip.create(&.{});
    defer t.destroy();
    // Inject "iwt r1,#$1234 ; stop" padded to one full 16-byte cache line.
    const code = [_]u8{ 0xF1, 0x34, 0x12, 0x00, 0x01 } ++ [_]u8{0} ** 11;
    for (code, 0..) |b, i| t.gsu.mmioWrite(0, @intCast(0x3100 + i), b);
    try testing.expect(t.gsu.cache_valid[0]);
    t.run(0x0000); // PC 0 sits inside the cache window (CBR=0)
    try testing.expectEqual(@as(u16, 0x1234), t.gsu.r[1]);
    try testing.expect(!t.gsu.go);
}

test "plot writes 2bpp bitplanes at the column-major char address" {
    // colr=1 via ibt r0,#1; color; plot at (127,95); rpix flushes.
    var t = try TestChip.create(&.{
        0xA0, 0x01, // ibt r0,#1
        0x4E, // color
        0xA1, 0x7F, // ibt r1,#127
        0xA2, 0x5F, // ibt r2,#95
        0x4C, // plot (increments R1)
        0xA1, 0x7F, // ibt r1,#127 again for the read-back
        0x3D, 0x4C, // rpix (alt1 plot)
        0x00, 0x01, // stop
    });
    defer t.destroy();
    t.gsu.mmioWrite(0, 0x303A, 0x38); // SCMR: RON|RAN|H192, 2bpp
    t.run(0x8000);
    // x=127,y=95: char = (127>>3)*24 + (95>>3) = 15*24+11 = 371;
    // byte = 371*16 + (95&7)*2 = 5950; bit 7-(127&7) = 0.
    try testing.expectEqual(@as(u8, 0x01), t.ram[5950]);
    try testing.expectEqual(@as(u8, 0x00), t.ram[5951]);
    // RPIX read the pixel back into R0 (dest defaults to R0).
    try testing.expectEqual(@as(u16, 1), t.gsu.r[0]);
}

test "getb reads the rom buffer through r14" {
    // iwt r14,#$9000 (triggers the ROM buffer fetch) ; getb ; stop
    var t = try TestChip.create(&.{ 0xFE, 0x00, 0x90, 0xEF, 0x00, 0x01 });
    defer t.destroy();
    t.rom[0x1000] = 0xA7; // GSU addr $9000 -> LoROM offset $1000
    t.run(0x8000);
    try testing.expectEqual(@as(u16, 0xA7), t.gsu.r[0]);
}

test "snes force-stop via sfr clears the cache window" {
    var t = try TestChip.create(&.{ 0xF1, 0xFF, 0x7F, 0x00, 0x01 });
    defer t.destroy();
    t.run(0x8000);
    t.gsu.cbr = 0x0120;
    t.gsu.cache_valid[3] = true;
    t.gsu.go = true;
    t.gsu.mmioWrite(0, 0x3030, 0x00); // GO 1->0
    try testing.expectEqual(@as(u16, 0), t.gsu.cbr);
    try testing.expect(!t.gsu.cache_valid[3]);
    try testing.expect(!t.gsu.go);
}

test "stop raises the irq line unless masked" {
    var t = try TestChip.create(&.{ 0x00, 0x01 });
    defer t.destroy();
    t.run(0x8000);
    try testing.expect(t.gsu.irq);
    try testing.expect(t.gsu.irq_line);
    // Reading SFR high byte acknowledges.
    _ = t.gsu.mmioRead(0, 0x3031, 0);
    try testing.expect(!t.gsu.irq_line);

    var t2 = try TestChip.create(&.{ 0x00, 0x01 });
    defer t2.destroy();
    t2.gsu.mmioWrite(0, 0x3037, 0x80); // CFGR IRQ mask
    t2.run(0x8000);
    try testing.expect(!t2.gsu.irq);
    try testing.expect(!t2.gsu.irq_line);
}
