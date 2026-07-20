//! SA-1 (Super Accelerator 1): a second 65816 at 10.74 MHz plus an MMC,
//! DMA, and math glue (Super Mario RPG, Kirby Super Star, Kirby's Dream
//! Land 3, ...). The CPU core is the same generic `Cpu(BusT)` the console
//! uses — the SA-1 struct *is* its bus, exposing the chip's private memory
//! map: 2 KiB IRAM, BW-RAM (the cartridge's battery RAM) in linear and
//! 2/4-bit "bitmap" projections, and game-pak ROM through the Super MMC's
//! four switchable 1 MiB regions. Interrupt vectors come from registers
//! (CRV/CNV/CIV), which this bus serves by intercepting vector-window reads
//! in bank $00 — the same trick lets the SNES-side NMI/IRQ vectors be
//! swapped to SNV/SIV when the vector-switch bits are on.
//!
//! Register-level behavior follows the SA-1 documentation as mirrored in
//! ares/bsnes research: message ports and IRQs both directions, H/V and
//! linear timers, normal DMA between ROM/BW-RAM/IRAM, both character
//! conversion DMA types, the multiply/divide/cumulative arithmetic unit,
//! and the variable-length bit reader.
//!
//! Scheduling is catch-up driven like the GSU and APU: the SA-1 banks
//! master-clock cycles (it runs at exactly half the 21.477 MHz master
//! clock) and consumes two per internal cycle. Fast-core simplifications,
//! documented on purpose:
//!  - No bus-conflict arbitration: SNES and SA-1 accesses to shared ROM,
//!    BW-RAM, and IRAM never stall each other. The SA-1 is caught up
//!    before the SNES touches any shared resource, which is the ordering
//!    well-behaved software enforces anyway.
//!  - Timer IRQs fire on the instruction boundary that crosses the target
//!    count, not the exact cycle.
//!  - SA-1-side data reads of $00:FFEA-$00:FFFF return the vector
//!    registers instead of ROM (hardware only substitutes them during
//!    vector pulls).

const std = @import("std");
const wdc65816 = @import("../cpu/wdc65816.zig");

pub const Sa1 = struct {
    pub const serialize_skip = .{ "rom", "rom_mask", "bwram", "bwram_mask", "mmc_base", "mmc_flat" };

    const CpuT = wdc65816.Cpu(Sa1);

    // Memory wiring into the cartridge, re-attached on init and postLoad
    // (BW-RAM is the cartridge's sram array, so it serializes with it).
    rom: [*]const u8,
    rom_mask: u32,
    bwram: [*]u8,
    bwram_mask: u32,

    cpu: CpuT,
    iram: [0x800]u8,
    mdr: u8,

    // Catch-up scheduling (master cycles banked, 2 per SA-1 cycle).
    last_sync: u64,
    budget: i64,

    // $2200 CCNT (SNES → SA-1 control)
    sa1_irq: bool,
    sa1_rdyb: bool,
    sa1_resb: bool,
    sa1_nmi: bool,
    smeg: u4,
    // $2201/$2202 SIE/SIC (SNES-side interrupt enable/clear)
    cpu_irqen: bool,
    chdma_irqen: bool,
    cpu_irqcl: bool,
    chdma_irqcl: bool,
    // $2203-$2208 SA-1 vectors
    crv: u16,
    cnv: u16,
    civ: u16,
    // $2209 SCNT (SA-1 → SNES control)
    cpu_irq: bool,
    cpu_ivsw: bool,
    cpu_nvsw: bool,
    cmeg: u4,
    // $220A/$220B CIE/CIC (SA-1-side interrupt enable/clear)
    sa1_irqen: bool,
    timer_irqen: bool,
    dma_irqen: bool,
    sa1_nmien: bool,
    sa1_irqcl: bool,
    timer_irqcl: bool,
    dma_irqcl: bool,
    sa1_nmicl: bool,
    // $220C-$220F SNES vectors (used when nvsw/ivsw set)
    snv: u16,
    siv: u16,
    // $2210-$2215 timer
    hvselb: bool,
    ven: bool,
    hen: bool,
    hcnt: u16,
    vcnt: u16,
    // $2220-$2223 Super MMC banks (block index + "banked low half" mode bit)
    cb: u3,
    db: u3,
    eb: u3,
    fb: u3,
    cbmode: bool,
    dbmode: bool,
    ebmode: bool,
    fbmode: bool,
    /// Set when an MMC register changes; the bus rebuilds its page table.
    mmc_dirty: bool,
    /// Derived from the four MMC bank registers, refreshed on every change
    /// (`refreshMmc`) so the per-read `mmcTranslate` is two array loads instead
    /// of a 4-way register switch. `mmc_base[r]` is the mapped ROM base for
    /// 1 MiB region `r`; `mmc_flat[r]` marks the lo-half direct-projection mode.
    mmc_base: [4]u32,
    mmc_flat: [4]bool,
    // $2224-$222A BW-RAM / IRAM mapping and protection
    sbm: u5,
    cbm: u7,
    sw46: bool,
    swen: bool,
    cwen: bool,
    bwp: u4,
    siwp: u8,
    ciwp: u8,
    // $2230/$2231 DMA control
    dmaen: bool,
    dprio: bool,
    cden: bool,
    cdsel: bool,
    dd: u1,
    sd: u2,
    chdend: bool,
    dmasize: u3,
    dmacb: u2,
    // $2232-$2239 DMA addresses and count
    dsa: u24,
    dda: u24,
    dtc: u16,
    // $223F/$2240-$224F bitmap format + register file (CC2)
    bbf: bool,
    brf: [16]u8,
    cc1_active: bool,
    dma_line: u4,
    // $2250-$2254 arithmetic
    acm: bool,
    md: bool,
    ma: u16,
    mb: u16,
    mr: u64,
    overflow: bool,
    // $2258-$225B variable-length bit reader
    vbd_hl: bool,
    vbd_len: u5,
    va: u24,
    vbit: u3,
    // $2300/$2301 interrupt flags
    cpu_irqfl: bool,
    chdma_irqfl: bool,
    sa1_irqfl: bool,
    timer_irqfl: bool,
    dma_irqfl: bool,
    sa1_nmifl: bool,
    // $2302-$2305 latched counter reads + live counters (master clocks)
    hcr: u16,
    vcr: u16,
    hcounter: u32,
    vcounter: u32,
    /// IRQ line into the main CPU (ORed with the console's own sources).
    snes_irq_line: bool,

    pub fn init(self: *Sa1) void {
        // Zero everything bytewise (the struct holds pointers, which
        // std.mem.zeroes refuses); attach() wires the pointers before use.
        @memset(std.mem.asBytes(self), 0);
        self.cpu = CpuT.init(self);
        self.sa1_resb = true; // held in reset until the SNES releases it
        self.db = 1;
        self.eb = 2;
        self.fb = 3;
        self.bwp = 0x0f;
        self.vbd_len = 16;
        self.refreshMmc();
    }

    /// Wire to the cartridge ROM and BW-RAM (after init or state load).
    pub fn attach(self: *Sa1, rom: []const u8, rom_mask: u32, bwram: [*]u8, bwram_mask: u32) void {
        self.rom = rom.ptr;
        self.rom_mask = rom_mask;
        self.bwram = bwram;
        self.bwram_mask = bwram_mask;
        self.cpu.bus = self;
        self.refreshMmc(); // derived table isn't serialized; rebuild after load
    }

    /// Recompute the per-region ROM mapping from the MMC bank registers. Cheap
    /// and rare (register writes, reset, load), so `mmcTranslate` stays branchy-
    /// free on the hot read path.
    fn refreshMmc(self: *Sa1) void {
        const blocks = [4]u3{ self.cb, self.db, self.eb, self.fb };
        const modes = [4]bool{ self.cbmode, self.dbmode, self.ebmode, self.fbmode };
        for (0..4) |r| {
            self.mmc_base[r] = @as(u32, blocks[r]) << 20;
            self.mmc_flat[r] = !modes[r];
        }
    }

    fn running(self: *const Sa1) bool {
        return !self.sa1_resb and !self.sa1_rdyb;
    }

    /// Run the SA-1 until it has consumed the master cycles elapsed since
    /// the last sync. Must be called before the SNES touches anything the
    /// SA-1 shares (MMIO, IRAM, BW-RAM) and once per scanline.
    pub fn catchUp(self: *Sa1, master_clock: u64) void {
        if (master_clock <= self.last_sync) {
            // Clock rewound (state load) or no time passed: just resync.
            self.last_sync = master_clock;
            return;
        }
        self.budget += @intCast(master_clock - self.last_sync);
        self.last_sync = master_clock;
        if (!self.running()) {
            self.budget = 0;
            return;
        }
        while (self.budget > 0) {
            if (self.cpu.state == .stopped) {
                self.budget = 0;
                break;
            }
            self.pollInterrupts();
            const before = self.budget;
            self.cpu.step();
            self.advanceTimer(@intCast(before - self.budget));
        }
    }

    /// Level-based interrupt delivery: NMI auto-masks itself when taken
    /// (like the hardware's clear bit), IRQ is a plain line into the core.
    fn pollInterrupts(self: *Sa1) void {
        if (self.sa1_nmi and !self.sa1_nmicl) {
            self.sa1_nmicl = true;
            self.sa1_nmifl = true;
            self.cpu.setNmi();
        }
        const irq = (self.timer_irqen and !self.timer_irqcl) or
            (self.dma_irqen and !self.dma_irqcl) or
            (self.sa1_irq and !self.sa1_irqcl);
        if (irq != self.cpu.irq_line) self.cpu.setIrqLine(irq);
    }

    // --- timer --------------------------------------------------------------

    /// Advance the H/V (or linear) counters by consumed master clocks and
    /// fire the timer IRQ when a target is crossed inside the window.
    fn advanceTimer(self: *Sa1, mcycles: u32) void {
        if (!self.hvselb) {
            // HV mode: 1364 master clocks per line, 262 lines (NTSC frame).
            var left = mcycles;
            while (left > 0) {
                const to_wrap = 1364 - self.hcounter;
                const chunk = @min(left, to_wrap);
                const old = self.hcounter;
                self.hcounter += chunk;
                left -= chunk;
                const htarget = @as(u32, self.hcnt) << 2;
                if (self.hen and old < htarget and self.hcounter >= htarget) {
                    if (!self.ven or self.vcounter == self.vcnt) self.triggerTimer();
                }
                if (self.hcounter >= 1364) {
                    self.hcounter = 0;
                    self.vcounter += 1;
                    if (self.vcounter >= 262) self.vcounter = 0;
                    if (self.ven and !self.hen and self.vcounter == self.vcnt) self.triggerTimer();
                }
            }
        } else {
            // Linear mode: free-running 11-bit H / 9-bit V chain.
            var left = mcycles;
            while (left > 0) {
                const to_wrap = 0x800 - self.hcounter;
                const chunk = @min(left, to_wrap);
                const old = self.hcounter;
                self.hcounter += chunk;
                left -= chunk;
                const htarget = @as(u32, self.hcnt) << 2;
                if (self.hen and old < htarget and self.hcounter >= htarget) {
                    if (!self.ven or self.vcounter == self.vcnt) self.triggerTimer();
                }
                if (self.hcounter >= 0x800) {
                    self.hcounter = 0;
                    self.vcounter = (self.vcounter + 1) & 0x1ff;
                    if (self.ven and !self.hen and self.vcounter == self.vcnt) self.triggerTimer();
                }
            }
        }
    }

    fn triggerTimer(self: *Sa1) void {
        self.timer_irqfl = true;
        if (self.timer_irqen) self.timer_irqcl = false;
    }

    // --- ROM through the Super MMC -------------------------------------------

    /// Squash a LoROM-view address ($00-$3F/$80-$BF:$8000-$FFFF) into the
    /// 22-bit MMC space: regions C/D/E/F are 1 MiB each.
    pub fn squashLo(addr: u24) u22 {
        return @intCast(((addr & 0x80_0000) >> 2) | ((addr & 0x3F_0000) >> 1) | (addr & 0x7FFF));
    }

    /// MMC translation: 22-bit region address → ROM byte offset. `lo` is
    /// true for the bank $00-$BF window, where a cleared mode bit maps the
    /// region straight to the matching image quarter instead of the block.
    pub fn mmcTranslate(self: *const Sa1, a: u22, lo: bool) u32 {
        const region: u2 = @intCast(a >> 20);
        if (lo and self.mmc_flat[region]) return a & self.rom_mask;
        return (self.mmc_base[region] | (a & 0xF_FFFF)) & self.rom_mask;
    }

    /// Full-address ROM read on the SA-1/SNES shared map ($00-$3F/$80-$BF
    /// upper halves and $C0-$FF).
    pub fn romRead(self: *const Sa1, addr: u24) u8 {
        if (addr & 0x40_8000 == 0x00_8000)
            return self.rom[self.mmcTranslate(squashLo(addr), true)];
        return self.rom[self.mmcTranslate(@intCast(addr & 0x3F_FFFF), false)];
    }

    /// SNES-side read of the vector page (bank $00/$80, $E000-$FFFF, kept
    /// off the fast path): NMI/IRQ vectors swap to SNV/SIV when enabled.
    pub fn snesVectorRead(self: *Sa1, addr: u24) u8 {
        const a16: u16 = @truncate(addr);
        switch (a16) {
            0xFFEA => if (self.cpu_nvsw) return @truncate(self.snv),
            0xFFEB => if (self.cpu_nvsw) return @truncate(self.snv >> 8),
            0xFFEE => if (self.cpu_ivsw) return @truncate(self.siv),
            0xFFEF => if (self.cpu_ivsw) return @truncate(self.siv >> 8),
            else => {},
        }
        return self.romRead(addr);
    }

    // --- BW-RAM projections ---------------------------------------------------

    fn bwLinearRead(self: *const Sa1, offset: u32) u8 {
        return self.bwram[offset & self.bwram_mask];
    }

    fn bwLinearWrite(self: *Sa1, offset: u32, value: u8) void {
        // Write protection applies only while both enables are off.
        if (!self.swen and !self.cwen and (offset & 0x3_FFFF) < @as(u32, 0x100) << self.bwp) return;
        self.bwram[offset & self.bwram_mask] = value;
    }

    /// 2/4-bit virtual bitmap space (SA-1 banks $60-$6F): each byte of the
    /// window is one pixel, packed into shared BW-RAM.
    fn bwBitmapRead(self: *const Sa1, addr20: u32) u8 {
        if (!self.bbf) {
            const b = self.bwram[(addr20 >> 1) & self.bwram_mask];
            return if (addr20 & 1 == 0) b & 0x0F else b >> 4;
        }
        const b = self.bwram[(addr20 >> 2) & self.bwram_mask];
        return (b >> @intCast((addr20 & 3) * 2)) & 3;
    }

    fn bwBitmapWrite(self: *Sa1, addr20: u32, value: u8) void {
        if (!self.bbf) {
            const p = &self.bwram[(addr20 >> 1) & self.bwram_mask];
            if (addr20 & 1 == 0)
                p.* = (p.* & 0xF0) | (value & 0x0F)
            else
                p.* = (p.* & 0x0F) | ((value & 0x0F) << 4);
        } else {
            const p = &self.bwram[(addr20 >> 2) & self.bwram_mask];
            const sh: u3 = @intCast((addr20 & 3) * 2);
            p.* = (p.* & ~(@as(u8, 3) << sh)) | ((value & 3) << sh);
        }
    }

    // --- SNES-side shared memory (bus routes here after catchUp) --------------

    /// SNES read of IRAM at $3000-$37FF.
    pub fn iramReadSnes(self: *Sa1, clock: u64, a16: u16) u8 {
        self.catchUp(clock);
        return self.iram[a16 & 0x7FF];
    }

    pub fn iramWriteSnes(self: *Sa1, clock: u64, a16: u16, value: u8) void {
        self.catchUp(clock);
        // SIWP protects per 256-byte block.
        if (self.siwp & (@as(u8, 1) << @intCast((a16 >> 8) & 7)) == 0) return;
        self.iram[a16 & 0x7FF] = value;
    }

    /// SNES BW-RAM read: `offset` is the linear BW-RAM byte offset (window
    /// reads pass sbm*8K+page offset, banks $40-$4F pass addr&$FFFFF).
    pub fn bwramReadSnes(self: *Sa1, clock: u64, offset: u32) u8 {
        self.catchUp(clock);
        if (self.cc1_active) return self.cc1Read(offset);
        return self.bwLinearRead(offset);
    }

    pub fn bwramWriteSnes(self: *Sa1, clock: u64, offset: u32, value: u8) void {
        self.catchUp(clock);
        self.bwLinearWrite(offset, value);
    }

    pub fn snesWindowOffset(self: *const Sa1, a16: u16) u32 {
        return @as(u32, self.sbm) * 0x2000 + (a16 & 0x1FFF);
    }

    // --- SA-1-side bus (the Cpu's BusT interface) ------------------------------

    pub fn idle(self: *Sa1) void {
        self.budget -= 2;
    }

    pub fn read8(self: *Sa1, addr: u24) u8 {
        // ROM $00-$3F/$80-$BF:8000-FFFF — the dominant case (SA-1 code and
        // operand fetch), tested first so the common path is one branch.
        if (addr & 0x40_8000 == 0x00_8000) {
            self.budget -= 2;
            // CRV/CNV/CIV vectors overlay $00:FFEA-FFFF (bank $00 only).
            if (addr <= 0x00_FFFF and addr >= 0x00_FFEA) {
                const vec: ?u16 = switch (@as(u16, @truncate(addr))) {
                    0xFFEA, 0xFFEB, 0xFFFA, 0xFFFB => self.cnv,
                    0xFFEE, 0xFFEF, 0xFFFE, 0xFFFF => self.civ,
                    0xFFFC, 0xFFFD => self.crv,
                    else => null, // reserved slots fall through to ROM
                };
                if (vec) |v| {
                    self.mdr = if (addr & 1 == 0) @truncate(v) else @truncate(v >> 8);
                    return self.mdr;
                }
            }
            self.mdr = self.rom[self.mmcTranslate(squashLo(addr), true)];
            return self.mdr;
        }
        if (addr & 0xC0_0000 == 0xC0_0000) { // ROM $C0-$FF
            self.budget -= 2;
            self.mdr = self.rom[self.mmcTranslate(@intCast(addr & 0x3F_FFFF), false)];
            return self.mdr;
        }
        if (addr & 0x40_FE00 == 0x00_2200) {
            self.budget -= 2;
            self.mdr = self.readIoSa1(@truncate(addr), self.mdr);
            return self.mdr;
        }
        if (addr & 0x40_E000 == 0x00_6000 or addr & 0xE0_0000 == 0x40_0000 or addr & 0xF0_0000 == 0x60_0000) {
            self.budget -= 4;
            if (addr & 0x40_0000 != 0 and addr & 0x20_0000 != 0) {
                self.mdr = self.bwBitmapRead(addr & 0xF_FFFF);
            } else if (addr & 0x40_0000 != 0) {
                self.mdr = self.bwLinearRead(addr & 0x1F_FFFF);
            } else {
                // $6000-$7FFF window through BMAP: linear or bitmap space.
                self.mdr = if (!self.sw46)
                    self.bwLinearRead(@as(u32, self.cbm & 0x1F) * 0x2000 + (addr & 0x1FFF))
                else
                    self.bwBitmapRead((@as(u32, self.cbm) * 0x2000 + (addr & 0x1FFF)) & 0xF_FFFF);
            }
            return self.mdr;
        }
        if (addr & 0x40_F800 == 0x00_0000 or addr & 0x40_F800 == 0x00_3000) {
            self.budget -= 2;
            self.mdr = self.iram[addr & 0x7FF];
            return self.mdr;
        }
        self.budget -= 2;
        return self.mdr; // open bus
    }

    pub fn write8(self: *Sa1, addr: u24, value: u8) void {
        self.mdr = value;
        if (addr & 0x40_FE00 == 0x00_2200) {
            self.budget -= 2;
            return self.writeIoSa1(@truncate(addr), value);
        }
        if (addr & 0x40_8000 == 0x00_8000 or addr & 0xC0_0000 == 0xC0_0000) {
            self.budget -= 2;
            return; // ROM
        }
        if (addr & 0x40_E000 == 0x00_6000 or addr & 0xE0_0000 == 0x40_0000 or addr & 0xF0_0000 == 0x60_0000) {
            self.budget -= 4;
            if (addr & 0x40_0000 != 0 and addr & 0x20_0000 != 0) {
                return self.bwBitmapWrite(addr & 0xF_FFFF, value);
            } else if (addr & 0x40_0000 != 0) {
                return self.bwLinearWrite(addr & 0x1F_FFFF, value);
            } else if (!self.sw46) {
                return self.bwLinearWrite(@as(u32, self.cbm & 0x1F) * 0x2000 + (addr & 0x1FFF), value);
            } else {
                return self.bwBitmapWrite((@as(u32, self.cbm) * 0x2000 + (addr & 0x1FFF)) & 0xF_FFFF, value);
            }
        }
        if (addr & 0x40_F800 == 0x00_0000 or addr & 0x40_F800 == 0x00_3000) {
            self.budget -= 2;
            // CIWP protects per 256-byte block.
            if (self.ciwp & (@as(u8, 1) << @intCast((addr >> 8) & 7)) == 0) return;
            self.iram[addr & 0x7FF] = value;
            return;
        }
        self.budget -= 2;
    }

    // --- MMIO: SNES side ($2200-$23FF) -----------------------------------------

    pub fn mmioRead(self: *Sa1, clock: u64, a16: u16, mdr: u8) u8 {
        self.catchUp(clock);
        return self.readIoCpu(a16, mdr);
    }

    pub fn mmioWrite(self: *Sa1, clock: u64, a16: u16, value: u8) void {
        self.catchUp(clock);
        self.writeIoCpu(a16, value);
    }

    fn readIoCpu(self: *Sa1, a16: u16, mdr: u8) u8 {
        return switch (a16) {
            // SFR: message from the SA-1 plus SNES-side IRQ flags.
            0x2300 => @as(u8, self.cmeg) |
                (@as(u8, @intFromBool(self.cpu_nvsw)) << 4) |
                (@as(u8, @intFromBool(self.chdma_irqfl)) << 5) |
                (@as(u8, @intFromBool(self.cpu_ivsw)) << 6) |
                (@as(u8, @intFromBool(self.cpu_irqfl)) << 7),
            else => mdr, // open bus (incl. $230E "version code")
        };
    }

    fn writeIoCpu(self: *Sa1, a16: u16, value: u8) void {
        switch (a16) {
            0x2200 => { // CCNT: SA-1 control
                if (self.sa1_resb and value & 0x20 == 0) {
                    // Release from reset: boot from CRV (the vector window
                    // serves it to the core's reset sequence). CIWP is a
                    // power-on-only default (already zero from init()'s
                    // memset) — RESB only resets the 65816 core, not the
                    // MMC-side write-protect latch. Re-clearing it here on
                    // every release would blow away a program's own CIWP
                    // unlock across a *second* reset-release (some SA-1
                    // bootstraps toggle RESB more than once), dropping the
                    // very next IRAM stack push and derailing the SA-1
                    // silently while the SNES side spins forever.
                    self.cpu.reset();
                }
                self.smeg = @truncate(value);
                self.sa1_nmi = value & 0x10 != 0;
                self.sa1_resb = value & 0x20 != 0;
                self.sa1_rdyb = value & 0x40 != 0;
                self.sa1_irq = value & 0x80 != 0;
                if (self.sa1_irq) {
                    self.sa1_irqfl = true;
                    if (self.sa1_irqen) self.sa1_irqcl = false;
                }
                if (self.sa1_nmi) {
                    self.sa1_nmifl = true;
                    if (self.sa1_nmien) self.sa1_nmicl = false;
                }
            },
            0x2201 => { // SIE: enabling a pending flag raises the line
                if (!self.chdma_irqen and value & 0x20 != 0 and self.chdma_irqfl)
                    self.chdma_irqcl = false;
                if (!self.cpu_irqen and value & 0x80 != 0 and self.cpu_irqfl)
                    self.cpu_irqcl = false;
                self.chdma_irqen = value & 0x20 != 0;
                self.cpu_irqen = value & 0x80 != 0;
                self.updateSnesIrq();
            },
            0x2202 => { // SIC
                self.chdma_irqcl = value & 0x20 != 0;
                self.cpu_irqcl = value & 0x80 != 0;
                if (self.chdma_irqcl) self.chdma_irqfl = false;
                if (self.cpu_irqcl) self.cpu_irqfl = false;
                self.updateSnesIrq();
            },
            0x2203 => self.crv = (self.crv & 0xFF00) | value,
            0x2204 => self.crv = (self.crv & 0x00FF) | (@as(u16, value) << 8),
            0x2205 => self.cnv = (self.cnv & 0xFF00) | value,
            0x2206 => self.cnv = (self.cnv & 0x00FF) | (@as(u16, value) << 8),
            0x2207 => self.civ = (self.civ & 0xFF00) | value,
            0x2208 => self.civ = (self.civ & 0x00FF) | (@as(u16, value) << 8),
            0x2220 => {
                self.cb = @truncate(value);
                self.cbmode = value & 0x80 != 0;
                self.mmc_dirty = true;
                self.refreshMmc();
            },
            0x2221 => {
                self.db = @truncate(value);
                self.dbmode = value & 0x80 != 0;
                self.mmc_dirty = true;
                self.refreshMmc();
            },
            0x2222 => {
                self.eb = @truncate(value);
                self.ebmode = value & 0x80 != 0;
                self.mmc_dirty = true;
                self.refreshMmc();
            },
            0x2223 => {
                self.fb = @truncate(value);
                self.fbmode = value & 0x80 != 0;
                self.mmc_dirty = true;
                self.refreshMmc();
            },
            0x2224 => self.sbm = @truncate(value),
            0x2226 => self.swen = value & 0x80 != 0,
            0x2228 => self.bwp = @truncate(value),
            0x2229 => self.siwp = value,
            0x2231...0x2237 => self.writeIoShared(a16, value),
            else => {},
        }
    }

    // --- MMIO: SA-1 side --------------------------------------------------------

    fn readIoSa1(self: *Sa1, a16: u16, mdr: u8) u8 {
        switch (a16) {
            // CFR: message from the SNES plus SA-1-side IRQ flags.
            0x2301 => return @as(u8, self.smeg) |
                (@as(u8, @intFromBool(self.sa1_nmifl)) << 4) |
                (@as(u8, @intFromBool(self.dma_irqfl)) << 5) |
                (@as(u8, @intFromBool(self.timer_irqfl)) << 6) |
                (@as(u8, @intFromBool(self.sa1_irqfl)) << 7),
            0x2302 => { // HCR low: latches both counters (dots for H)
                self.hcr = @intCast((self.hcounter >> 2) & 0xFFFF);
                self.vcr = @intCast(self.vcounter & 0xFFFF);
                return @truncate(self.hcr);
            },
            0x2303 => return @truncate(self.hcr >> 8),
            0x2304 => return @truncate(self.vcr),
            0x2305 => return @truncate(self.vcr >> 8),
            0x2306 => return @truncate(self.mr),
            0x2307 => return @truncate(self.mr >> 8),
            0x2308 => return @truncate(self.mr >> 16),
            0x2309 => return @truncate(self.mr >> 24),
            0x230A => return @truncate(self.mr >> 32),
            0x230B => return @as(u8, @intFromBool(self.overflow)) << 7,
            0x230C => return @truncate(self.vbrWindow()),
            0x230D => {
                const w = self.vbrWindow();
                if (self.vbd_hl) self.vbrAdvance(self.vbd_len);
                return @truncate(w >> 8);
            },
            else => return mdr,
        }
    }

    fn writeIoSa1(self: *Sa1, a16: u16, value: u8) void {
        switch (a16) {
            0x2209 => { // SCNT: message + IRQ to the SNES, vector switches
                self.cmeg = @truncate(value);
                self.cpu_nvsw = value & 0x10 != 0;
                self.cpu_ivsw = value & 0x40 != 0;
                self.cpu_irq = value & 0x80 != 0;
                if (self.cpu_irq) {
                    self.cpu_irqfl = true;
                    if (self.cpu_irqen) self.cpu_irqcl = false;
                }
                self.updateSnesIrq();
            },
            0x220A => { // CIE
                if (!self.sa1_nmien and value & 0x10 != 0 and self.sa1_nmifl) self.sa1_nmicl = false;
                if (!self.dma_irqen and value & 0x20 != 0 and self.dma_irqfl) self.dma_irqcl = false;
                if (!self.timer_irqen and value & 0x40 != 0 and self.timer_irqfl) self.timer_irqcl = false;
                if (!self.sa1_irqen and value & 0x80 != 0 and self.sa1_irqfl) self.sa1_irqcl = false;
                self.sa1_nmien = value & 0x10 != 0;
                self.dma_irqen = value & 0x20 != 0;
                self.timer_irqen = value & 0x40 != 0;
                self.sa1_irqen = value & 0x80 != 0;
            },
            0x220B => { // CIC
                self.sa1_nmicl = value & 0x10 != 0;
                self.dma_irqcl = value & 0x20 != 0;
                self.timer_irqcl = value & 0x40 != 0;
                self.sa1_irqcl = value & 0x80 != 0;
                if (self.sa1_nmicl) self.sa1_nmifl = false;
                if (self.dma_irqcl) self.dma_irqfl = false;
                if (self.timer_irqcl) self.timer_irqfl = false;
                if (self.sa1_irqcl) self.sa1_irqfl = false;
            },
            0x220C => self.snv = (self.snv & 0xFF00) | value,
            0x220D => self.snv = (self.snv & 0x00FF) | (@as(u16, value) << 8),
            0x220E => self.siv = (self.siv & 0xFF00) | value,
            0x220F => self.siv = (self.siv & 0x00FF) | (@as(u16, value) << 8),
            0x2210 => {
                self.hen = value & 0x01 != 0;
                self.ven = value & 0x02 != 0;
                self.hvselb = value & 0x80 != 0;
            },
            0x2211 => {
                self.hcounter = 0;
                self.vcounter = 0;
            },
            0x2212 => self.hcnt = (self.hcnt & 0xFF00) | value,
            0x2213 => self.hcnt = (self.hcnt & 0x00FF) | (@as(u16, value) << 8),
            0x2214 => self.vcnt = (self.vcnt & 0xFF00) | value,
            0x2215 => self.vcnt = (self.vcnt & 0x00FF) | (@as(u16, value) << 8),
            0x2225 => {
                self.cbm = @truncate(value);
                self.sw46 = value & 0x80 != 0;
            },
            0x2227 => self.cwen = value & 0x80 != 0,
            0x222A => self.ciwp = value,
            0x2230 => { // DCNT
                self.sd = @truncate(value);
                self.dd = @intCast((value >> 2) & 1);
                self.cdsel = value & 0x10 != 0;
                self.cden = value & 0x20 != 0;
                self.dprio = value & 0x40 != 0;
                self.dmaen = value & 0x80 != 0;
                if (!self.dmaen) self.dma_line = 0;
            },
            0x2231...0x2237 => self.writeIoShared(a16, value),
            0x2238 => self.dtc = (self.dtc & 0xFF00) | value,
            0x2239 => self.dtc = (self.dtc & 0x00FF) | (@as(u16, value) << 8),
            0x223F => self.bbf = value & 0x80 != 0,
            0x2240...0x224F => {
                self.brf[a16 & 0xF] = value;
                // Filling half the register file feeds one CC2 line.
                if ((a16 == 0x2247 or a16 == 0x224F) and
                    self.dmaen and self.cden and !self.cdsel)
                {
                    self.dmaCC2();
                }
            },
            0x2250 => { // MCNT
                self.md = value & 0x01 != 0;
                self.acm = value & 0x02 != 0;
                if (self.acm) self.mr = 0;
            },
            0x2251 => self.ma = (self.ma & 0xFF00) | value,
            0x2252 => self.ma = (self.ma & 0x00FF) | (@as(u16, value) << 8),
            0x2253 => self.mb = (self.mb & 0xFF00) | value,
            0x2254 => { // MBH starts the operation
                self.mb = (self.mb & 0x00FF) | (@as(u16, value) << 8);
                self.arithmetic();
            },
            0x2258 => { // VBD
                self.vbd_len = @truncate(value & 0x0F);
                self.vbd_hl = value & 0x80 != 0;
                if (self.vbd_len == 0) self.vbd_len = 16;
                if (!self.vbd_hl) self.vbrAdvance(self.vbd_len);
            },
            0x2259 => self.va = (self.va & 0xFFFF00) | value,
            0x225A => self.va = (self.va & 0xFF00FF) | (@as(u24, value) << 8),
            0x225B => {
                self.va = (self.va & 0x00FFFF) | (@as(u24, value) << 16);
                self.vbit = 0;
            },
            else => {},
        }
    }

    /// DMA parameter registers are writable from both processors.
    fn writeIoShared(self: *Sa1, a16: u16, value: u8) void {
        switch (a16) {
            0x2231 => { // CDMA
                self.dmacb = @intCast(@min(value & 0x03, 2));
                self.dmasize = @intCast(@min((value >> 2) & 0x07, 5));
                self.chdend = value & 0x80 != 0;
                if (self.chdend) self.cc1_active = false;
            },
            0x2232 => self.dsa = (self.dsa & 0xFFFF00) | value,
            0x2233 => self.dsa = (self.dsa & 0xFF00FF) | (@as(u24, value) << 8),
            0x2234 => self.dsa = (self.dsa & 0x00FFFF) | (@as(u24, value) << 16),
            0x2235 => self.dda = (self.dda & 0xFFFF00) | value,
            0x2236 => {
                self.dda = (self.dda & 0xFF00FF) | (@as(u24, value) << 8);
                if (self.dmaen) {
                    if (!self.cden and self.dd == 0) self.dmaNormal();
                    if (self.cden and self.cdsel) self.dmaCC1();
                }
            },
            0x2237 => {
                self.dda = (self.dda & 0x00FFFF) | (@as(u24, value) << 16);
                if (self.dmaen and !self.cden and self.dd == 1) self.dmaNormal();
            },
            else => unreachable,
        }
    }

    fn updateSnesIrq(self: *Sa1) void {
        self.snes_irq_line = (self.cpu_irqfl and self.cpu_irqen) or
            (self.chdma_irqfl and self.chdma_irqen);
    }

    // --- arithmetic unit ---------------------------------------------------------

    fn arithmetic(self: *Sa1) void {
        if (!self.acm) {
            if (!self.md) {
                // Signed 16x16 multiply; MB is consumed.
                const p: i32 = @as(i32, @as(i16, @bitCast(self.ma))) * @as(i16, @bitCast(self.mb));
                self.mr = @as(u32, @bitCast(p));
                self.mb = 0;
            } else {
                // Signed / unsigned divide; both operands are consumed.
                if (self.mb == 0) {
                    self.mr = 0;
                } else {
                    const dividend: i32 = @as(i16, @bitCast(self.ma));
                    const divisor: i32 = self.mb;
                    var remainder = @rem(dividend, divisor);
                    if (remainder < 0) remainder += divisor;
                    const quotient = @divTrunc(dividend - remainder, divisor);
                    self.mr = (@as(u64, @intCast(remainder)) << 16) |
                        @as(u16, @truncate(@as(u32, @bitCast(quotient))));
                }
                self.ma = 0;
                self.mb = 0;
            }
        } else {
            // Cumulative multiply: 40-bit sum with a sticky-free overflow bit.
            const p: i64 = @as(i64, @as(i16, @bitCast(self.ma))) * @as(i16, @bitCast(self.mb));
            const sum = self.mr +% @as(u64, @bitCast(p));
            self.overflow = (sum >> 40) & 1 != 0;
            self.mr = sum & 0xFF_FFFF_FFFF;
            self.mb = 0;
        }
    }

    // --- variable-length bit reader -----------------------------------------------

    /// The 24-bit window at the current bit position (ROM/BW-RAM/IRAM via a
    /// simplified bus that skips MMIO).
    fn vbrWindow(self: *const Sa1) u24 {
        const b0: u24 = self.vbrRead(self.va +% 0);
        const b1: u24 = self.vbrRead(self.va +% 1);
        const b2: u24 = self.vbrRead(self.va +% 2);
        return (b0 | b1 << 8 | b2 << 16) >> self.vbit;
    }

    fn vbrRead(self: *const Sa1, addr: u24) u8 {
        if (addr & 0x40_8000 == 0x00_8000 or addr & 0xC0_0000 == 0xC0_0000)
            return self.romRead(addr);
        if (addr & 0x40_E000 == 0x00_6000 or addr & 0xF0_0000 == 0x40_0000)
            return self.bwram[addr & self.bwram_mask];
        if (addr & 0x40_F800 == 0x00_0000 or addr & 0x40_F800 == 0x00_3000)
            return self.iram[addr & 0x7FF];
        return 0xFF;
    }

    fn vbrAdvance(self: *Sa1, bits: u5) void {
        const total = @as(u24, self.vbit) + bits;
        self.va +%= total >> 3;
        self.vbit = @truncate(total);
    }

    // --- DMA -------------------------------------------------------------------------

    /// Normal DMA: ROM/BW-RAM/IRAM source into IRAM or BW-RAM.
    fn dmaNormal(self: *Sa1) void {
        var count = self.dtc;
        while (count != 0) : (count -= 1) {
            const source = self.dsa;
            const target = self.dda;
            self.dsa +%= 1;
            self.dda +%= 1;
            const data: u8 = switch (self.sd) {
                0 => self.romRead(source),
                1 => self.bwram[source & self.bwram_mask],
                else => self.iram[source & 0x7FF],
            };
            if (self.dd == 0) {
                self.iram[target & 0x7FF] = data;
                self.budget -= 2;
            } else {
                self.bwram[target & self.bwram_mask] = data;
                self.budget -= 4;
            }
        }
        self.dtc = 0xFFFF; // the counter underflows past zero, as on hardware
        self.dma_irqfl = true;
        if (self.dma_irqen) self.dma_irqcl = false;
    }

    /// Type-1 character conversion: arms the BW-RAM read hook; the SNES
    /// then GP-DMAs the window and characters convert on the fly.
    fn dmaCC1(self: *Sa1) void {
        self.cc1_active = true;
        self.chdma_irqfl = true;
        if (self.chdma_irqen) self.chdma_irqcl = false;
        self.updateSnesIrq();
    }

    /// CC1 read: at each character boundary, convert one bitmap tile from
    /// BW-RAM into planar form in the IRAM buffer at DDA, then serve bytes.
    fn cc1Read(self: *Sa1, offset: u32) u8 {
        const charmask: u32 = (@as(u32, 1) << @intCast(6 - @as(u5, self.dmacb))) - 1;
        if (offset & charmask == 0) {
            const bpp: u32 = @as(u32, 2) << @intCast(2 - @as(u5, self.dmacb));
            const bpl: u32 = (@as(u32, 8) << self.dmasize) >> @as(u5, self.dmacb);
            const tile = ((offset -% self.dsa) & self.bwram_mask) >> @intCast(6 - @as(u5, self.dmacb));
            const ty = tile >> self.dmasize;
            const tx = tile & ((@as(u32, 1) << self.dmasize) - 1);
            var bwaddr: u32 = @as(u32, self.dsa) +% ty * 8 * bpl +% tx * bpp;

            for (0..8) |y| {
                var data: u64 = 0;
                for (0..bpp) |byte| {
                    const b = self.bwram[(bwaddr +% @as(u32, @intCast(byte))) & self.bwram_mask];
                    data |= @as(u64, b) << @intCast(byte * 8);
                }
                bwaddr +%= bpl;

                var out: [8]u8 = @splat(0);
                for (0..8) |x| {
                    const planes: usize = bpp;
                    for (0..planes) |p| {
                        out[p] |= @as(u8, @truncate(data & 1)) << @intCast(7 - x);
                        data >>= 1;
                    }
                }
                for (0..bpp) |byte| {
                    const p = (self.dda +% @as(u24, @intCast((y << 1) + ((byte & 6) << 3) + (byte & 1)))) & 0x7FF;
                    self.iram[p] = out[byte];
                }
            }
        }
        return self.iram[(self.dda +% @as(u24, @intCast(offset & charmask))) & 0x7FF];
    }

    /// Type-2 character conversion: the SA-1 writes pixels into the BRF
    /// register file; each filled half emits one planar line into IRAM.
    fn dmaCC2(self: *Sa1) void {
        const brf = self.brf[(@as(usize, self.dma_line & 1)) << 3 ..][0..8];
        const bpp: u32 = @as(u32, 2) << @intCast(2 - @as(u5, self.dmacb));
        var address: u32 = self.dda & 0x7FF;
        address &= ~((@as(u32, 1) << @intCast(7 - @as(u5, self.dmacb))) - 1);
        address += (self.dma_line & 8) * bpp;
        address += (self.dma_line & 7) * 2;

        for (0..bpp) |byte| {
            var out: u8 = 0;
            for (0..8) |bit| {
                out |= ((brf[bit] >> @intCast(byte)) & 1) << @intCast(7 - bit);
            }
            self.iram[(address + ((byte & 6) << 3) + (byte & 1)) & 0x7FF] = out;
        }
        self.dma_line +%= 1;
    }
};

// --- tests ---------------------------------------------------------------------------

const testing = std.testing;

/// A 2 MiB test cartridge whose ROM the tests can scribble programs into.
const TestChip = struct {
    rom: [2 * 1024 * 1024]u8,
    bwram: [0x8000]u8,
    sa1: Sa1,

    fn create() !*TestChip {
        const tc = try testing.allocator.create(TestChip);
        tc.rom = @splat(0xEA); // NOP sled
        tc.bwram = @splat(0);
        tc.sa1.init();
        tc.sa1.attach(&tc.rom, tc.rom.len - 1, &tc.bwram, tc.bwram.len - 1);
        return tc;
    }

    fn destroy(self: *TestChip) void {
        testing.allocator.destroy(self);
    }

    /// Boot the SA-1 at $00:8000 (ROM offset 0) and run `cycles` master cycles.
    fn boot(self: *TestChip, cycles: u64) void {
        self.sa1.mmioWrite(0, 0x2203, 0x00); // CRV = $8000
        self.sa1.mmioWrite(0, 0x2204, 0x80);
        self.sa1.mmioWrite(0, 0x2200, 0x00); // release reset
        self.sa1.catchUp(cycles);
    }
};

test "sa1 boots from crv and runs code from rom" {
    var tc = try TestChip.create();
    defer tc.destroy();
    // LDA #$42; STA $0000; STP  — IRAM writes need CIWP, set it first:
    // LDA #$FF; STA $222A; LDA #$42; STA $0000; STP
    const prog = [_]u8{ 0xA9, 0xFF, 0x8D, 0x2A, 0x22, 0xA9, 0x42, 0x8D, 0x00, 0x00, 0xDB };
    @memcpy(tc.rom[0..prog.len], &prog);
    tc.boot(500);
    try testing.expectEqual(@as(u8, 0x42), tc.sa1.iram[0]);
    try testing.expectEqual(wdc65816.ExecState.stopped, tc.sa1.cpu.state);
}

test "sa1 ciwp survives a second reset-release" {
    var tc = try TestChip.create();
    defer tc.destroy();
    const s = &tc.sa1;
    // Boot once, unlock all IRAM blocks (as any SA-1 bootstrap must before
    // it can push to a stack living in IRAM).
    tc.boot(200);
    s.writeIoSa1(0x222A, 0xFF);
    try testing.expectEqual(@as(u8, 0xFF), s.ciwp);
    // A second RESB assert/de-assert (CCNT bit 5 high then low again) must
    // not silently re-block IRAM writes: only the 65816 core resets, not
    // this MMC-side latch.
    s.mmioWrite(300, 0x2200, 0x20); // assert RESB
    s.mmioWrite(300, 0x2200, 0x00); // release again
    try testing.expectEqual(@as(u8, 0xFF), s.ciwp);
    // IRAM is indeed still writable — the failure mode this guards against
    // is a dropped stack push on the very next JSR/PHA after such a reset.
    s.write8(0x00_0002, 0x77);
    try testing.expectEqual(@as(u8, 0x77), s.iram[2]);
}

test "sa1 message ports and irq to snes" {
    var tc = try TestChip.create();
    defer tc.destroy();
    // SA-1 sends message 5 + IRQ to the SNES: LDA #$85; STA $2209; STP
    const prog = [_]u8{ 0xA9, 0x85, 0x8D, 0x09, 0x22, 0xDB };
    @memcpy(tc.rom[0..prog.len], &prog);
    tc.sa1.mmioWrite(0, 0x2201, 0x80); // SIE: enable SA-1→SNES IRQ
    tc.boot(500);
    try testing.expect(tc.sa1.snes_irq_line);
    // SFR shows the flag and message.
    const sfr = tc.sa1.mmioRead(500, 0x2300, 0);
    try testing.expectEqual(@as(u8, 0x85), sfr & 0x8F);
    // SIC clears the flag and drops the line.
    tc.sa1.mmioWrite(500, 0x2202, 0x80);
    try testing.expect(!tc.sa1.snes_irq_line);
    // Message the other way: CCNT low nibble shows up in CFR.
    tc.sa1.mmioWrite(500, 0x2200, 0x07);
    const cfr = tc.sa1.readIoSa1(0x2301, 0);
    try testing.expectEqual(@as(u8, 0x07), cfr & 0x0F);
}

test "sa1 irq delivery via civ vector" {
    var tc = try TestChip.create();
    defer tc.destroy();
    // Main: CLI; loop: BRA loop.  IRQ handler at $9000: STA $2209 variant —
    // write $01 to IRAM $0001 then STP.
    const main_prog = [_]u8{ 0xA9, 0xFF, 0x8D, 0x2A, 0x22, 0x58, 0x80, 0xFE }; // LDA/STA CIWP, CLI, BRA *
    @memcpy(tc.rom[0..main_prog.len], &main_prog);
    const handler = [_]u8{ 0xA9, 0x01, 0x8D, 0x01, 0x00, 0xDB }; // LDA #1; STA $0001; STP
    @memcpy(tc.rom[0x1000 .. 0x1000 + handler.len], &handler); // $00:9000
    tc.sa1.mmioWrite(0, 0x2207, 0x00); // CIV = $9000
    tc.sa1.mmioWrite(0, 0x2208, 0x90);
    tc.boot(200); // spins in BRA loop with I clear
    // SNES raises the SA-1 IRQ (CCNT bit 7); needs CIE bit 7 first.
    tc.sa1.writeIoSa1(0x220A, 0x80);
    tc.sa1.mmioWrite(300, 0x2200, 0x80);
    tc.sa1.catchUp(800);
    try testing.expectEqual(@as(u8, 0x01), tc.sa1.iram[1]);
}

test "sa1 mmc translation and remap flag" {
    var tc = try TestChip.create();
    defer tc.destroy();
    tc.rom[0x0_1234] = 0xAA; // block 0
    // Region C default (mode 0): direct projection of the image.
    try testing.expectEqual(@as(u8, 0xAA), tc.sa1.romRead(0x00_9234));
    // Bank the region: CXB block 1 with mode set → offset 0x10_1234.
    tc.rom[0x10_1234] = 0xBB;
    tc.sa1.mmioWrite(0, 0x2220, 0x81);
    try testing.expect(tc.sa1.mmc_dirty);
    try testing.expectEqual(@as(u8, 0xBB), tc.sa1.romRead(0x00_9234));
    // Hi banks ($C0+) always follow the block registers (defaults D=1).
    try testing.expectEqual(@as(u8, 0xBB), tc.sa1.romRead(0xC0_1234));
    try testing.expectEqual(tc.rom[0x10_5678], tc.sa1.romRead(0xD0_5678));
}

test "sa1 snes vector substitution" {
    var tc = try TestChip.create();
    defer tc.destroy();
    tc.rom[Sa1.squashLo(0x00_FFEA) & (tc.rom.len - 1)] = 0x11;
    // Without NVSW the ROM byte shows through.
    try testing.expectEqual(@as(u8, 0x11), tc.sa1.snesVectorRead(0x00_FFEA));
    // SA-1 sets SNV and flips the switch.
    tc.sa1.writeIoSa1(0x220C, 0x34);
    tc.sa1.writeIoSa1(0x220D, 0x12);
    tc.sa1.writeIoSa1(0x2209, 0x10); // NVSW
    try testing.expectEqual(@as(u8, 0x34), tc.sa1.snesVectorRead(0x00_FFEA));
    try testing.expectEqual(@as(u8, 0x12), tc.sa1.snesVectorRead(0x00_FFEB));
}

test "sa1 arithmetic unit" {
    var tc = try TestChip.create();
    defer tc.destroy();
    const s = &tc.sa1;
    // Signed multiply: -3 * 100 = -300.
    s.writeIoSa1(0x2250, 0x00);
    s.writeIoSa1(0x2251, 0xFD);
    s.writeIoSa1(0x2252, 0xFF);
    s.writeIoSa1(0x2253, 100);
    s.writeIoSa1(0x2254, 0);
    try testing.expectEqual(@as(u32, @bitCast(@as(i32, -300))), @as(u32, @truncate(s.mr)));
    try testing.expectEqual(@as(u16, 0), s.mb); // consumed
    // Divide: -100 / 7 → quotient -15, remainder 5 (euclidean).
    s.writeIoSa1(0x2250, 0x01);
    s.writeIoSa1(0x2251, 0x9C); // -100
    s.writeIoSa1(0x2252, 0xFF);
    s.writeIoSa1(0x2253, 7);
    s.writeIoSa1(0x2254, 0);
    try testing.expectEqual(@as(u16, @bitCast(@as(i16, -15))), @as(u16, @truncate(s.mr)));
    try testing.expectEqual(@as(u16, 5), @as(u16, @truncate(s.mr >> 16)));
    // Divide by zero yields zero.
    s.writeIoSa1(0x2251, 10);
    s.writeIoSa1(0x2253, 0);
    s.writeIoSa1(0x2254, 0);
    try testing.expectEqual(@as(u64, 0), s.mr);
    // Cumulative: 2*3 + 4*5 = 26; MCNT write clears the sum.
    s.writeIoSa1(0x2250, 0x02);
    s.writeIoSa1(0x2251, 2);
    s.writeIoSa1(0x2252, 0);
    s.writeIoSa1(0x2253, 3);
    s.writeIoSa1(0x2254, 0);
    s.writeIoSa1(0x2251, 4);
    s.writeIoSa1(0x2253, 5);
    s.writeIoSa1(0x2254, 0);
    try testing.expectEqual(@as(u64, 26), s.mr);
}

test "sa1 normal dma rom to iram and bwram" {
    var tc = try TestChip.create();
    defer tc.destroy();
    const s = &tc.sa1;
    for (0..16) |i| tc.rom[0x100 + i] = @intCast(0xC0 + i);
    // ROM $00:8100 → IRAM $0010, 16 bytes. DDA byte-2 order: the mid byte
    // write triggers the IRAM-destination transfer.
    s.writeIoSa1(0x2230, 0x80); // DMAEN, source ROM, dest IRAM
    s.writeIoSa1(0x2238, 16);
    s.writeIoSa1(0x2239, 0);
    s.writeIoSa1(0x2232, 0x00);
    s.writeIoSa1(0x2233, 0x81);
    s.writeIoSa1(0x2234, 0x00);
    s.writeIoSa1(0x2235, 0x10);
    s.writeIoSa1(0x2236, 0x00); // triggers
    for (0..16) |i| try testing.expectEqual(@as(u8, @intCast(0xC0 + i)), s.iram[0x10 + i]);
    try testing.expect(s.dma_irqfl);
    // IRAM → BW-RAM: dest bit set, triggered by the DDA high byte.
    s.writeIoSa1(0x2230, 0x86); // DMAEN, source IRAM, dest BW-RAM
    s.writeIoSa1(0x2238, 4);
    s.writeIoSa1(0x2239, 0);
    s.writeIoSa1(0x2232, 0x10);
    s.writeIoSa1(0x2233, 0x00);
    s.writeIoSa1(0x2234, 0x00);
    s.writeIoSa1(0x2235, 0x00);
    s.writeIoSa1(0x2236, 0x02);
    s.writeIoSa1(0x2237, 0x40); // triggers (dest $40:0200 = BW-RAM $0200)
    for (0..4) |i| try testing.expectEqual(@as(u8, @intCast(0xC0 + i)), tc.bwram[0x200 + i]);
}

test "sa1 bwram windows, bitmap projection, and protection" {
    var tc = try TestChip.create();
    defer tc.destroy();
    const s = &tc.sa1;
    // SNES window: SBM selects the 8K block.
    s.mmioWrite(0, 0x2224, 0x02); // block 2 → offset $4000
    s.mmioWrite(0, 0x2226, 0x80); // SWEN
    s.bwramWriteSnes(0, s.snesWindowOffset(0x6123), 0x77);
    try testing.expectEqual(@as(u8, 0x77), tc.bwram[0x4123]);
    // Write protection: with SWEN and CWEN both off, low area is read-only.
    s.mmioWrite(0, 0x2226, 0x00);
    s.mmioWrite(0, 0x2228, 0x00); // protect first $100
    s.bwramWriteSnes(0, 0x0040, 0x99);
    try testing.expectEqual(@as(u8, 0x00), tc.bwram[0x0040]);
    s.bwramWriteSnes(0, 0x0140, 0x99); // outside the protected area
    try testing.expectEqual(@as(u8, 0x99), tc.bwram[0x0140]);
    // SA-1 4bpp bitmap projection: two pixels per byte.
    s.writeIoSa1(0x223F, 0x00);
    tc.bwram[0x10] = 0;
    s.writeIoSa1(0x2227, 0x80); // CWEN so writes pass
    s.bwBitmapWrite(0x20, 0x0A);
    s.bwBitmapWrite(0x21, 0x05);
    try testing.expectEqual(@as(u8, 0x5A), tc.bwram[0x10]);
    try testing.expectEqual(@as(u8, 0x0A), s.bwBitmapRead(0x20));
    try testing.expectEqual(@as(u8, 0x05), s.bwBitmapRead(0x21));
    // 2bpp packs four pixels per byte.
    s.writeIoSa1(0x223F, 0x80);
    s.bwBitmapWrite(0x40, 1);
    s.bwBitmapWrite(0x41, 2);
    s.bwBitmapWrite(0x42, 3);
    s.bwBitmapWrite(0x43, 0);
    try testing.expectEqual(@as(u8, 0b00_11_10_01), tc.bwram[0x10]);
}

test "sa1 character conversion type 2" {
    var tc = try TestChip.create();
    defer tc.destroy();
    const s = &tc.sa1;
    s.writeIoSa1(0x2231, 0x00); // CDMA: 8bpp?? no — dmacb=0 → 8bpp
    s.writeIoSa1(0x2231, 0x02); // dmacb=2 → 2bpp
    s.writeIoSa1(0x2235, 0x00); // DDA = 0
    s.writeIoSa1(0x2236, 0x00);
    s.writeIoSa1(0x2230, 0xA0); // DMAEN + CDEN, CDSEL=0 (type 2)
    // One line of 8 pixels: values 0..3 repeating → plane0 = 0b01010101,
    // plane1 = 0b00110011.
    const pixels = [8]u8{ 0, 1, 2, 3, 0, 1, 2, 3 };
    for (pixels, 0..) |p, i| s.writeIoSa1(@intCast(0x2240 + i), p);
    try testing.expectEqual(@as(u8, 0b01010101), s.iram[0]);
    try testing.expectEqual(@as(u8, 0b00110011), s.iram[1]);
}

test "sa1 character conversion type 1" {
    var tc = try TestChip.create();
    defer tc.destroy();
    const s = &tc.sa1;
    // 4bpp bitmap, one tile row wide (dmasize=0 → 1 tile/row). Fill tile 0
    // with pixel value = x (0..7) on every row: plane0 = 0b01010101, etc.
    for (0..8) |y| {
        for (0..4) |bpair| {
            // two 4-bit pixels per byte: x = bpair*2 (low), bpair*2+1 (high)
            const lo: u8 = @intCast(bpair * 2);
            const hi: u8 = @intCast(bpair * 2 + 1);
            tc.bwram[y * 4 + bpair] = lo | hi << 4;
        }
    }
    s.writeIoSa1(0x2231, 0x01); // dmacb=1 (4bpp), dmasize=0 (1 tile per row)
    s.writeIoSa1(0x2232, 0x00); // DSA = 0
    s.writeIoSa1(0x2233, 0x00);
    s.writeIoSa1(0x2234, 0x00);
    s.writeIoSa1(0x2230, 0xB0); // DMAEN + CDEN + CDSEL (type 1)
    s.writeIoSa1(0x2235, 0x00);
    s.writeIoSa1(0x2236, 0x00); // triggers arm
    try testing.expect(s.cc1_active);
    try testing.expect(s.chdma_irqfl);
    // First read converts the tile: row 0 planes 0/1 at IRAM 0/1.
    const b0 = s.bwramReadSnes(0, 0);
    try testing.expectEqual(@as(u8, 0b01010101), b0);
    try testing.expectEqual(@as(u8, 0b00110011), s.iram[1]);
    try testing.expectEqual(@as(u8, 0b00001111), s.iram[16]); // plane 2 (row 0)
    // CHDEND stops the hook.
    s.writeIoSa1(0x2231, 0x80);
    try testing.expect(!s.cc1_active);
}

test "sa1 variable length bit reader" {
    var tc = try TestChip.create();
    defer tc.destroy();
    const s = &tc.sa1;
    tc.rom[0] = 0b1010_1100;
    tc.rom[1] = 0b0101_0011;
    tc.rom[2] = 0xFF;
    // VDA = $00:8000 (ROM offset 0).
    s.writeIoSa1(0x2259, 0x00);
    s.writeIoSa1(0x225A, 0x80);
    s.writeIoSa1(0x225B, 0x00);
    // Auto-increment mode, 4-bit steps.
    s.writeIoSa1(0x2258, 0x84);
    var lo = s.readIoSa1(0x230C, 0);
    _ = s.readIoSa1(0x230D, 0); // consume 4 bits
    try testing.expectEqual(@as(u8, 0b1010_1100), lo);
    lo = s.readIoSa1(0x230C, 0);
    try testing.expectEqual(@as(u8, 0b0011_1010), lo); // shifted by 4
    _ = s.readIoSa1(0x230D, 0);
    lo = s.readIoSa1(0x230C, 0);
    try testing.expectEqual(@as(u8, 0b0101_0011), lo); // next byte
}

test "sa1 timers fire on crossing" {
    var tc = try TestChip.create();
    defer tc.destroy();
    const s = &tc.sa1;
    // Idle SA-1 in a BRA loop so catchUp advances the timer.
    const prog = [_]u8{ 0x80, 0xFE };
    @memcpy(tc.rom[0..prog.len], &prog);
    s.writeIoSa1(0x2212, 100); // H target = dot 100 → clock 400
    s.writeIoSa1(0x2213, 0);
    s.writeIoSa1(0x2210, 0x01); // H enable, HV mode
    tc.boot(300);
    try testing.expect(!s.timer_irqfl);
    s.catchUp(600);
    try testing.expect(s.timer_irqfl);
    // V-only mode: fires when the line wraps to the target count.
    s.writeIoSa1(0x220B, 0x40); // clear timer flag
    try testing.expect(!s.timer_irqfl);
    s.writeIoSa1(0x2211, 0); // restart counters
    s.writeIoSa1(0x2214, 2);
    s.writeIoSa1(0x2215, 0);
    s.writeIoSa1(0x2210, 0x02); // V enable
    s.catchUp(600 + 1 * 1364); // one full line: vcounter = 1
    try testing.expect(!s.timer_irqfl);
    // Second wrap reaches vcounter = 2 = target (+ slack: the catch-up loop
    // banks a few cycles across calls, so consumption trails wall clock).
    s.catchUp(600 + 2 * 1364 + 32);
    try testing.expect(s.timer_irqfl);
}

test "sa1 state roundtrip via serialize" {
    const serialize = @import("../serialize.zig");
    var tc = try TestChip.create();
    defer tc.destroy();
    const prog = [_]u8{ 0xA9, 0xFF, 0x8D, 0x2A, 0x22, 0xA9, 0x42, 0x8D, 0x00, 0x00, 0xDB };
    @memcpy(tc.rom[0..prog.len], &prog);
    tc.boot(500);

    const size = comptime serialize.byteSize(Sa1);
    const buf = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(buf);
    _ = serialize.write(Sa1, &tc.sa1, buf);

    var tc2 = try TestChip.create();
    defer tc2.destroy();
    _ = try serialize.read(Sa1, &tc2.sa1, buf);
    tc2.sa1.attach(&tc2.rom, tc2.rom.len - 1, &tc2.bwram, tc2.bwram.len - 1);
    try testing.expectEqual(@as(u8, 0x42), tc2.sa1.iram[0]);
    try testing.expectEqual(tc.sa1.cpu.regs.pc, tc2.sa1.cpu.regs.pc);
}
