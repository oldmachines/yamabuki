//! System bus: 24-bit address space dispatched through a 2048-entry page
//! table (8 KiB pages). ROM/RAM/SRAM accesses take the two-load fast path;
//! MMIO pages have null pointers and fall through to a single switch.
//!
//! The bus owns the master-cycle clock: every access charges the page's
//! speed (6/8/12 master cycles), so instruction timing falls out of memory
//! traffic for free.

const std = @import("std");
const mappers = @import("mappers.zig");
const Wram = @import("wram.zig").Wram;
const MathUnit = @import("math_unit.zig").MathUnit;
const CpuIo = @import("cpu_io.zig").CpuIo;
const Joypad = @import("joypad.zig").Joypad;
const Dma = @import("dma.zig").Dma;
const Ppu = @import("../ppu/ppu.zig").Ppu;
const Apu = @import("../apu/apu.zig").Apu;
const Gsu = @import("../chips/gsu.zig").Gsu;
const Dsp1 = @import("../chips/dsp1.zig").Dsp1;
const Sa1 = @import("../chips/sa1.zig").Sa1;
const Cx4 = @import("../chips/cx4.zig").Cx4;
const Cartridge = @import("../cart/cartridge.zig").Cartridge;
const timing = @import("../timing.zig");

/// One page-table slot's fast-path pointers, as constructed by the mappers.
/// The bus stores these split into parallel arrays (`page_read`,
/// `page_write`, `page_speed` — see `Bus.setPage`) so the hot read8/write8
/// path touches less cache: 2048 pages of this struct padded to 24 bytes is
/// 48 KiB, larger than a Cortex-A53's 32 KiB L1D and enough to evict itself;
/// the read-only array alone is 16 KiB.
pub const Page = struct {
    read: ?[*]const u8,
    write: ?[*]u8,
    /// Master cycles per access on this page.
    speed: u8,

    pub const unmapped: Page = .{ .read = null, .write = null, .speed = timing.speed_slow };
};

pub const page_size = 0x2000;
pub const page_count = 0x100_0000 / page_size; // 2048

pub const Bus = struct {
    // The page tables hold raw pointers into wram/cart and are rebuilt by
    // remap() on load; the cart reference is re-supplied by the frontend.
    // `last_data_read`, `last_data_write` and `input_polled` are diagnostics,
    // not machine state; `coproc_irq_line` is derived from the chips' own
    // serialized lines and rebuilt in postLoad; `auto_fastrom` is frontend
    // configuration, set once at startup — it must survive a loadState
    // (skipped fields keep their in-memory value), so an old save does not
    // silently turn the option off.
    pub const serialize_skip = .{ "page_read", "page_write", "page_speed", "cart", "last_data_read", "last_data_write", "input_polled", "coproc_irq_line", "auto_fastrom" };

    /// `last_data_read`/`last_data_write` when there has been none since they
    /// were cleared. Out of u24 range, so it cannot collide with a real address.
    pub const no_data_access: u32 = 0x0100_0000;

    /// Read pointer per page, or null if the page has no fast-path read
    /// (MMIO, unmapped). 16 KiB — the array read8 and instruction fetch touch.
    page_read: [page_count]?[*]const u8,
    /// Write pointer per page, or null if the page has no fast-path write
    /// (ROM, MMIO, unmapped).
    page_write: [page_count]?[*]u8,
    /// Master cycles per access, per page.
    page_speed: [page_count]u8,
    cart: *Cartridge,
    /// Master clock in master cycles since power-on.
    clock: u64,
    /// Address of the most recent *data* read / write (`Cpu.read8`/`Cpu.write8`),
    /// or `no_data_access`. Set by the CPU — never by an instruction fetch, and
    /// never by a stack push or pull, both of which go straight to the bus.
    ///
    /// The profiler clears them before each instruction, so what it finds
    /// afterwards is the memory that instruction actually operated on. That is
    /// what lets it recognise a wait: a loop that reads one fixed address and
    /// changes nothing is waiting, however it is spelled. Diagnostics only;
    /// nothing in the core reads them.
    last_data_read: u32,
    last_data_write: u32,
    /// The game has read a controller register ($4016/$4017 serial, or the
    /// $4218-$421F auto-read results) since the profiler last cleared this. A
    /// frame in which it stays false is a frame the main loop never came around:
    /// a dropped frame. Diagnostic only; nothing in the core reads it.
    input_polled: bool,
    /// Memory data register: the value of the last bus transfer (open bus).
    mdr: u8,
    /// $420D MEMSEL bit 0: FastROM enabled.
    fastrom: bool,
    /// Opt-in auto-FastROM (M12): treat MEMSEL as permanently 1, giving a
    /// SlowROM game FastROM cartridge timing in the upper banks. Purely an
    /// emulation-level speed change — the header is untouched, and it is
    /// gated behind an explicit flag plus a compat list, because code timed
    /// against SlowROM latency genuinely breaks.
    auto_fastrom: bool,
    wram: Wram,
    math: MathUnit,
    cpuio: CpuIo,
    joy: Joypad,
    ppu: Ppu,
    /// Accurate-core beam state: when enabled, a $21xx write first renders
    /// the current scanline up to the beam's pixel so the write lands
    /// mid-line. The console updates line/line_start each scanline; a
    /// sentinel line (maxInt) disables catch-up during vblank.
    beam_enabled: bool,
    beam_line: u32,
    beam_line_start: u64,
    /// Beam position for the $2137 H/V counter latch, updated by the console
    /// every scanline in both cores (unlike beam_line, which is accurate-only
    /// and blanked between lines).
    hv_line: u32,
    hv_line_start: u64,
    dma: Dma,
    apu: Apu,
    /// Super FX coprocessor; inert (never caught up or addressed) unless the
    /// cartridge chip is `.superfx`.
    gsu: Gsu,
    /// DSP-1 math coprocessor (HLE); inert unless the cartridge chip is `.dsp`.
    dsp1: Dsp1,
    /// SA-1 coprocessor; inert unless the cartridge chip is `.sa1`.
    sa1: Sa1,
    /// Cx4 coprocessor (HLE); inert unless the cartridge chip is `.cx4`.
    cx4: Cx4,
    /// The coprocessor IRQ lines (GSU, SA-1), aggregated. The per-instruction
    /// scheduler loop reads this one bool instead of reaching into two large
    /// chip structs by name — those loads were pure overhead on a plain cart.
    /// Kept fresh by `syncCoprocIrq` on every path that can move a line: the
    /// bus's own slow path (every SNES-side chip access catches the chip up,
    /// and catching up can raise or ack an IRQ) and the console's per-line
    /// catch-up. Derived state: skipped by the serializer, rebuilt in
    /// postLoad from the chips' serialized lines.
    coproc_irq_line: bool,

    /// Initialize in place. `self` must be at its final address (the page
    /// table points into `self.wram`, and the APU's SPC700 points back at
    /// the APU), and `cart` must outlive the bus.
    pub fn init(self: *Bus, cart: *Cartridge) void {
        self.cart = cart;
        self.clock = 0;
        self.last_data_read = no_data_access;
        self.last_data_write = no_data_access;
        self.input_polled = false;
        self.mdr = 0;
        self.fastrom = false;
        self.auto_fastrom = false;
        self.wram = .init;
        self.math = .init;
        self.cpuio = .init;
        self.joy = .init;
        self.ppu = .init;
        self.beam_enabled = false;
        self.beam_line = std.math.maxInt(u32);
        self.beam_line_start = 0;
        self.hv_line = 0;
        self.hv_line_start = 0;
        self.dma = .init;
        self.apu.init();
        self.gsu = .init;
        self.dsp1 = .init;
        self.sa1.init();
        self.cx4.init();
        self.coproc_irq_line = false;
        self.attachGsu();
        self.attachSa1();
        self.attachCx4();
        self.remap();
    }

    /// Wire the GSU to the cartridge's ROM and work RAM (after init or load).
    fn attachGsu(self: *Bus) void {
        if (self.cart.chip != .superfx) return;
        self.gsu.attach(self.cart.rom, self.cart.rom_mask, &self.cart.sram, self.cart.sram_mask);
    }

    /// Wire the SA-1 to the cartridge's ROM and BW-RAM (after init or load).
    fn attachSa1(self: *Bus) void {
        if (self.cart.chip != .sa1) return;
        self.sa1.attach(self.cart.rom, self.cart.rom_mask, &self.cart.sram, self.cart.sram_mask);
    }

    /// Wire the Cx4 to the cartridge's ROM (after init or load).
    fn attachCx4(self: *Bus) void {
        if (self.cart.chip != .cx4) return;
        self.cx4.attach(self.cart.rom, self.cart.rom_mask);
    }

    /// Rebuild the page table (after init, deserialize, or MEMSEL change).
    pub fn remap(self: *Bus) void {
        mappers.buildPages(self);
    }

    /// Write one page-table slot across the three parallel arrays. Mappers
    /// build a `Page` value (read/write/speed together, the natural unit for
    /// a mapping decision); this splits it into the SoA layout read8/write8
    /// index.
    pub fn setPage(self: *Bus, idx: u32, p: Page) void {
        self.page_read[idx] = p.read;
        self.page_write[idx] = p.write;
        self.page_speed[idx] = p.speed;
    }

    /// Called after deserialization to rebuild derived state: the page table,
    /// then every component that declares its own postLoad hook (discovered
    /// at comptime, so new components can't be forgotten here).
    /// Turn auto-FastROM on (frontends call this once, after init and after
    /// the compat-list check): MEMSEL behaves as permanently 1 from now on.
    pub fn enableAutoFastrom(self: *Bus) void {
        self.auto_fastrom = true;
        self.fastrom = true;
        self.remap();
    }

    pub fn postLoad(self: *Bus) void {
        // A save made without auto-FastROM restores fastrom=false; the
        // in-memory option (skipped by the serializer) re-pins it.
        if (self.auto_fastrom) self.fastrom = true;
        self.attachSa1(); // before remap: the SA-1 page map reads MMC state
        self.remap();
        self.attachGsu();
        self.attachCx4();
        self.syncCoprocIrq(); // derived from the chips' serialized lines
        inline for (@typeInfo(Bus).@"struct".fields) |f| {
            if (comptime @typeInfo(f.type) == .@"struct" and @hasDecl(f.type, "postLoad")) {
                @field(self, f.name).postLoad();
            }
        }
    }

    /// DSP-1 port decode: null when `addr` is not a DSP port, else true for
    /// SR (status), false for DR (data). Follows the board wirings: LoROM
    /// carts up to 1 MiB decode banks $30-$3F/$B0-$BF upper half (DR below
    /// $C000, SR above), larger LoROM boards use banks $60-$6F/$E0-$EF lower
    /// half (DR below $4000, SR above), and HiROM uses $6000-$7FFF of banks
    /// $00-$1F/$80-$9F (DR below $7000, SR above).
    fn dsp1Port(self: *const Bus, bank: u8, a16: u16) ?bool {
        if (self.cart.chip != .dsp) return null;
        const b = bank & 0x7F;
        switch (self.cart.header.mapping) {
            .lorom => if (self.cart.rom.len <= 0x10_0000) {
                if (b >= 0x30 and b <= 0x3F and a16 >= 0x8000)
                    return a16 >= 0xC000;
            } else {
                if (b >= 0x60 and b <= 0x6F and a16 < 0x8000)
                    return a16 >= 0x4000;
            },
            .hirom, .exhirom => if (b <= 0x1F and a16 >= 0x6000 and a16 < 0x8000)
                return a16 >= 0x7000,
        }
        return null;
    }

    /// Accurate core: render the current scanline up to the pixel the beam
    /// has reached, so the $21xx write being dispatched splits the line.
    /// Output pixel x corresponds to dot 22+x; one dot is 4 master cycles.
    fn beamCatchUp(self: *Bus) void {
        const dot = (self.clock -% self.beam_line_start) / timing.cycles_per_dot;
        const x = dot -| timing.render_start_dot;
        self.ppu.renderUpTo(self.beam_line, @intCast(@min(x, 256)));
    }

    /// Where the beam is on the current scanline, in dots. Falls out of the
    /// master clock and the line start the console maintains every scanline —
    /// which is the only way to know it in the fast core, where the CPU runs a
    /// whole line in one batch.
    pub fn beamDot(self: *const Bus) u16 {
        return @intCast((self.clock -% self.hv_line_start) / timing.cycles_per_dot % timing.dots_per_line);
    }

    /// One CPU internal cycle (no bus access).
    pub inline fn idle(self: *Bus) void {
        self.clock += timing.speed_fast;
    }

    /// Side-effect-free read for diagnostics (the profiler's opcode peek):
    /// no clock charge, no MDR update, no MMIO dispatch. Returns null off the
    /// fast path — code executing from an MMIO page is not worth peeking.
    pub inline fn peek8(self: *const Bus, addr: u24) ?u8 {
        const idx = addr >> 13;
        if (self.page_read[idx]) |p| return p[addr & (page_size - 1)];
        return null;
    }

    pub inline fn read8(self: *Bus, addr: u24) u8 {
        const idx = addr >> 13;
        if (self.page_read[idx]) |p| {
            self.clock += self.page_speed[idx];
            const v = p[addr & (page_size - 1)];
            self.mdr = v;
            return v;
        }
        return self.slowRead(addr);
    }

    pub inline fn write8(self: *Bus, addr: u24, value: u8) void {
        self.mdr = value;
        const idx = addr >> 13;
        if (self.page_write[idx]) |p| {
            self.clock += self.page_speed[idx];
            p[addr & (page_size - 1)] = value;
            return;
        }
        self.slowWrite(addr, value);
    }

    /// Re-derive the aggregated coprocessor IRQ line. Cheap enough to call
    /// unconditionally wherever a chip might have moved its line; gated on
    /// the cart's chip at the call sites so plain carts never touch the
    /// coprocessor structs at all.
    pub fn syncCoprocIrq(self: *Bus) void {
        self.coproc_irq_line = self.gsu.irq_line or self.sa1.snes_irq_line;
    }

    /// Every SNES-side access to a coprocessor catches the chip up first, and
    /// catching up can raise or ack its IRQ — so the one place that covers
    /// every such path (MMIO, IRAM, BW-RAM, the vector page) is the slow
    /// path's exit. `defer` covers the early returns.
    inline fn coprocIrqGuard(self: *Bus) bool {
        return switch (self.cart.chip) {
            .superfx, .sa1 => true,
            else => false,
        };
    }

    fn slowRead(self: *Bus, addr: u24) u8 {
        @branchHint(.unlikely);
        defer if (self.coprocIrqGuard()) self.syncCoprocIrq();
        const bank: u8 = @intCast(addr >> 16);
        const a16: u16 = @truncate(addr);
        self.clock += speedOfParts(bank, a16, self.fastrom);

        // MMIO exists only in the system area (banks $00-$3F / $80-$BF),
        // except the large-LoROM DSP-1 ports in banks $60-$6F.
        if (!isSystemBank(bank)) {
            if (self.dsp1Port(bank, a16)) |sr| {
                self.mdr = if (sr) self.dsp1.readStatus() else self.dsp1.readData();
                return self.mdr;
            }
            if (self.cart.chip == .sa1 and bank >= 0x40 and bank <= 0x4F) {
                self.mdr = self.sa1.bwramReadSnes(self.clock, addr & 0xF_FFFF);
                return self.mdr;
            }
            if (mappers.smallSramPtr(self, addr)) |p| {
                self.mdr = p.*;
                return self.mdr;
            }
            return self.mdr; // open bus
        }

        const v: u8 = switch (a16) {
            // $2137 SLHV latches the beam counters; the dot position falls
            // out of the master clock and the console-maintained line start.
            0x2137 => blk: {
                self.ppu.latchCounters(self.beamDot(), @intCast(self.hv_line & 0x1FF));
                break :blk self.mdr;
            },
            0x213C, 0x213D => self.ppu.readCounterLatch(a16, self.mdr),
            0x213F => self.ppu.readStat78(self.mdr),
            0x2134...0x2136, 0x2138...0x213B, 0x213E => self.ppu.readReg(a16, self.mdr),
            0x2140...0x217F => self.apu.cpuRead(self.clock, @truncate(a16 & 3)),
            0x2200...0x23FF => if (self.cart.chip == .sa1)
                self.sa1.mmioRead(self.clock, a16, self.mdr)
            else
                self.mdr,
            0x3000...0x37FF => switch (self.cart.chip) {
                .superfx => if (a16 <= 0x33FF) self.gsu.mmioRead(self.clock, a16, self.mdr) else self.mdr,
                .sa1 => self.sa1.iramReadSnes(self.clock, a16),
                else => self.mdr,
            },
            0x2180 => self.wram.portRead(),
            0x4016 => blk: {
                self.input_polled = true;
                break :blk self.joy.readSerial(0, self.mdr);
            },
            0x4017 => blk: {
                self.input_polled = true;
                break :blk self.joy.readSerial(1, self.mdr);
            },
            0x4210 => self.cpuio.readRdnmi(self.mdr),
            0x4211 => self.cpuio.readTimeup(self.mdr),
            // HVBJOY. Bit 6 is the H-blank flag, and it has to be derived from
            // the beam here rather than latched by the scheduler: the fast core
            // runs a whole scanline of CPU in one batch, so nothing else knows
            // where in the line we are.
            //
            // It was previously never set at all, and `BIT $4212 / BVC` — which
            // is how you wait for H-blank, because BIT drops bit 6 into V — hung
            // forever. That is exactly what F-Zero does at $8616, and it is why a
            // launch title with no coprocessor never drew a frame.
            0x4212 => blk: {
                self.cpuio.in_hblank = isHblank(self.beamDot());
                break :blk self.cpuio.readHvbjoy(self.mdr);
            },
            0x4214 => @truncate(self.math.rddiv),
            0x4215 => @truncate(self.math.rddiv >> 8),
            0x4216 => @truncate(self.math.rdmpy),
            0x4217 => @truncate(self.math.rdmpy >> 8),
            0x4218...0x421F => blk: {
                self.input_polled = true;
                break :blk self.joy.readAuto(@truncate(a16 & 7));
            },
            0x4300...0x437F => self.dma.readReg(a16),
            else => {
                if (self.dsp1Port(bank, a16)) |sr| {
                    self.mdr = if (sr) self.dsp1.readStatus() else self.dsp1.readData();
                    return self.mdr;
                }
                if (self.cart.chip == .sa1) {
                    if (a16 >= 0x6000 and a16 < 0x8000) {
                        // BW-RAM window (block selected by BMAPS).
                        self.mdr = self.sa1.bwramReadSnes(self.clock, self.sa1.snesWindowOffset(a16));
                        return self.mdr;
                    }
                    if (a16 >= 0xE000 and bank & 0x7F == 0) {
                        // Vector page, kept off the fast path so the SA-1
                        // can substitute the SNES NMI/IRQ vectors.
                        self.sa1.catchUp(self.clock);
                        self.mdr = self.sa1.snesVectorRead(addr);
                        return self.mdr;
                    }
                }
                if (self.cart.chip == .cx4 and a16 >= 0x6000 and a16 < 0x8000) {
                    self.mdr = self.cx4.read(a16);
                    return self.mdr;
                }
                if (mappers.smallSramPtr(self, addr)) |p| {
                    self.mdr = p.*;
                    return self.mdr;
                }
                return self.mdr; // open bus (includes write-only registers)
            },
        };
        self.mdr = v;
        return v;
    }

    fn slowWrite(self: *Bus, addr: u24, value: u8) void {
        @branchHint(.unlikely);
        defer if (self.coprocIrqGuard()) self.syncCoprocIrq();
        const bank: u8 = @intCast(addr >> 16);
        const a16: u16 = @truncate(addr);
        self.clock += speedOfParts(bank, a16, self.fastrom);

        if (!isSystemBank(bank)) {
            if (self.dsp1Port(bank, a16)) |sr| {
                if (!sr) self.dsp1.writeData(value);
                return;
            }
            if (self.cart.chip == .sa1 and bank >= 0x40 and bank <= 0x4F) {
                self.sa1.bwramWriteSnes(self.clock, addr & 0xF_FFFF, value);
                return;
            }
            if (mappers.smallSramPtr(self, addr)) |p| p.* = value;
            return;
        }

        switch (a16) {
            0x2100...0x2133 => {
                if (self.beam_enabled) self.beamCatchUp();
                self.ppu.writeReg(a16, value);
            },
            0x2140...0x217F => self.apu.cpuWrite(self.clock, @truncate(a16 & 3), value),
            0x2200...0x23FF => if (self.cart.chip == .sa1) {
                self.sa1.mmioWrite(self.clock, a16, value);
                if (self.sa1.mmc_dirty) {
                    // Super MMC bank change: rebuild the ROM page mapping.
                    self.sa1.mmc_dirty = false;
                    self.remap();
                }
            },
            0x3000...0x37FF => switch (self.cart.chip) {
                .superfx => if (a16 <= 0x33FF) self.gsu.mmioWrite(self.clock, a16, value),
                .sa1 => self.sa1.iramWriteSnes(self.clock, a16, value),
                else => {},
            },
            0x2180 => self.wram.portWrite(value),
            0x2181 => self.wram.setPortAddrLow(value),
            0x2182 => self.wram.setPortAddrMid(value),
            0x2183 => self.wram.setPortAddrHigh(value),
            0x4016 => self.joy.writeStrobe(value),
            0x4200 => self.cpuio.nmitimen = value,
            0x4201 => self.cpuio.wrio = value,
            0x4202 => self.math.wrmpya = value,
            0x4203 => self.math.writeMultiplicand(value),
            0x4204 => self.math.dividend = (self.math.dividend & 0xFF00) | value,
            0x4205 => self.math.dividend = (self.math.dividend & 0x00FF) | (@as(u16, value) << 8),
            0x4206 => self.math.writeDivisor(value),
            0x4207 => self.cpuio.setHtimeLow(value),
            0x4208 => self.cpuio.setHtimeHigh(value),
            0x4209 => self.cpuio.setVtimeLow(value),
            0x420A => self.cpuio.setVtimeHigh(value),
            0x420B => self.dma.startGpDma(self, value),
            0x420C => self.dma.hdmaen = value,
            0x4300...0x437F => self.dma.writeReg(a16, value),
            0x420D => {
                // Auto-FastROM pins MEMSEL: a game clearing it (usually just
                // its own reset code writing 0) must not undo the option.
                const enable = (value & 1) != 0 or self.auto_fastrom;
                if (enable != self.fastrom) {
                    self.fastrom = enable;
                    self.remap();
                }
            },
            else => {
                if (self.dsp1Port(bank, a16)) |sr| {
                    if (!sr) self.dsp1.writeData(value);
                    return;
                }
                if (self.cart.chip == .sa1 and a16 >= 0x6000 and a16 < 0x8000) {
                    self.sa1.bwramWriteSnes(self.clock, self.sa1.snesWindowOffset(a16), value);
                    return;
                }
                if (self.cart.chip == .cx4 and a16 >= 0x6000 and a16 < 0x8000) {
                    self.cx4.write(a16, value);
                    return;
                }
                if (mappers.smallSramPtr(self, addr)) |p| p.* = value;
            },
        }
    }
};

/// Dots 274..341 and 0..1 are horizontal blanking. Used for HVBJOY's H-blank
/// flag ($4212 bit 6) — the thing `BIT $4212 / BVC` waits on, because BIT puts
/// bit 6 straight into the V flag.
pub fn isHblank(dot: u16) bool {
    return dot >= 274 or dot <= 1;
}

pub fn isSystemBank(bank: u8) bool {
    return (bank & 0x7F) <= 0x3F;
}

/// Master cycles for one access at `addr` (anomie's memory-speed map).
pub fn speedOf(addr: u24, fastrom: bool) u8 {
    return speedOfParts(@intCast(addr >> 16), @truncate(addr), fastrom);
}

/// `speedOf` for a caller that already split the address — the MMIO slow path
/// derives bank/a16 for its own dispatch, so deriving them again inside the
/// speed lookup was pure waste.
pub fn speedOfParts(bank: u8, a16: u16, fastrom: bool) u8 {
    if (bank >= 0xC0) return if (fastrom) timing.speed_fast else timing.speed_slow;
    if (bank >= 0x80) return systemAreaSpeed(a16, fastrom);
    if (bank >= 0x40) return timing.speed_slow;
    return systemAreaSpeed(a16, false);
}

fn systemAreaSpeed(a16: u16, fastrom_upper: bool) u8 {
    return switch (a16) {
        0x0000...0x1FFF => timing.speed_slow,
        0x2000...0x3FFF => timing.speed_fast,
        0x4000...0x41FF => timing.speed_xslow,
        0x4200...0x5FFF => timing.speed_fast,
        0x6000...0x7FFF => timing.speed_slow,
        else => if (fastrom_upper) timing.speed_fast else timing.speed_slow,
    };
}

test {
    std.testing.refAllDecls(@This());
}

// --- tests ---------------------------------------------------------------

const TestConsole = struct {
    cart: Cartridge,
    bus: Bus,

    fn create(mapping_mode: u8, sram_log2kb: u8) !*TestConsole {
        return createChip(mapping_mode, sram_log2kb, 0x02);
    }

    fn createChip(mapping_mode: u8, sram_log2kb: u8, chipset: u8) !*TestConsole {
        const alloc = std.testing.allocator;
        const raw = try alloc.alloc(u8, 512 * 1024);
        defer alloc.free(raw);
        for (raw, 0..) |*b, i| b.* = @truncate(i >> 8);
        const hoff: u32 = if (mapping_mode & 0x01 != 0) 0xFFC0 else 0x7FC0;
        const h = raw[hoff..][0..64];
        @memcpy(h[0..21], "BUS TEST             ");
        h[0x15] = mapping_mode;
        h[0x16] = chipset;
        h[0x17] = 9;
        h[0x18] = sram_log2kb;
        std.mem.writeInt(u16, h[0x1C..0x1E], 0x0F0F, .little);
        std.mem.writeInt(u16, h[0x1E..0x20], 0xF0F0, .little);
        std.mem.writeInt(u16, h[0x3C..0x3E], 0x8000, .little);

        const tc = try alloc.create(TestConsole);
        errdefer alloc.destroy(tc);
        tc.cart = try Cartridge.load(alloc, raw);
        tc.bus.init(&tc.cart);
        return tc;
    }

    fn destroy(self: *TestConsole) void {
        self.cart.deinit(std.testing.allocator);
        std.testing.allocator.destroy(self);
    }
};

test "lorom rom mapping and mirroring" {
    var tc = try TestConsole.create(0x20, 3);
    defer tc.destroy();
    // $00:8000 is ROM offset 0
    try std.testing.expectEqual(tc.cart.rom[0], tc.bus.read8(0x00_8000));
    // $01:8000 is ROM offset $8000
    try std.testing.expectEqual(tc.cart.rom[0x8000], tc.bus.read8(0x01_8000));
    // $80:8000 mirrors $00:8000
    try std.testing.expectEqual(tc.cart.rom[0], tc.bus.read8(0x80_8000));
    // ROM is read-only: write is ignored
    tc.bus.write8(0x00_8000, 0xEE);
    try std.testing.expectEqual(tc.cart.rom[0], tc.bus.read8(0x00_8000));
}

test "hirom rom mapping" {
    var tc = try TestConsole.create(0x21, 0);
    defer tc.destroy();
    // $C0:0000 is ROM offset 0
    try std.testing.expectEqual(tc.cart.rom[0], tc.bus.read8(0xC0_0000));
    // $C1:2345 is ROM offset $12345
    try std.testing.expectEqual(tc.cart.rom[0x1_2345], tc.bus.read8(0xC1_2345));
    // system bank upper half: $00:8000 == ROM offset $8000
    try std.testing.expectEqual(tc.cart.rom[0x8000], tc.bus.read8(0x00_8000));
    // $40:0000 mirrors $C0:0000
    try std.testing.expectEqual(tc.cart.rom[0], tc.bus.read8(0x40_0000));
}

test "wram mapping, mirror, and port" {
    var tc = try TestConsole.create(0x20, 3);
    defer tc.destroy();
    tc.bus.write8(0x7E_1234, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), tc.bus.read8(0x7E_1234));
    // low-bank mirror of the first 8 KiB
    tc.bus.write8(0x00_0042, 0x55);
    try std.testing.expectEqual(@as(u8, 0x55), tc.bus.read8(0x7E_0042));
    try std.testing.expectEqual(@as(u8, 0x55), tc.bus.read8(0xBF_0042));
    // WRAM port with autoincrement
    tc.bus.write8(0x00_2181, 0x00);
    tc.bus.write8(0x00_2182, 0x40);
    tc.bus.write8(0x00_2183, 0x01);
    tc.bus.write8(0x00_2180, 0x77); // writes $7F:4000
    try std.testing.expectEqual(@as(u8, 0x77), tc.bus.read8(0x7F_4000));
}

test "open bus returns last mdr" {
    var tc = try TestConsole.create(0x20, 3);
    defer tc.destroy();
    _ = tc.bus.read8(0x00_8000); // mdr = rom[0] = 0x00... use a distinctive one
    _ = tc.bus.read8(0x00_8123); // mdr = rom[0x123] = 0x01
    const mdr = tc.cart.rom[0x123];
    // $00:5000 is unmapped in LoROM
    try std.testing.expectEqual(mdr, tc.bus.read8(0x00_5000));
    // reading write-only register $4202 is also open bus
    try std.testing.expectEqual(mdr, tc.bus.read8(0x00_4202));
}

test "clock charges page speeds and fastrom" {
    var tc = try TestConsole.create(0x20, 3);
    defer tc.destroy();
    var before = tc.bus.clock;
    _ = tc.bus.read8(0x00_8000); // SlowROM: 8
    try std.testing.expectEqual(@as(u64, 8), tc.bus.clock - before);

    before = tc.bus.clock;
    _ = tc.bus.read8(0x00_4210); // MMIO $4200-$5FFF: 6
    try std.testing.expectEqual(@as(u64, 6), tc.bus.clock - before);

    before = tc.bus.clock;
    _ = tc.bus.read8(0x00_4016); // joypad: 12
    try std.testing.expectEqual(@as(u64, 12), tc.bus.clock - before);

    tc.bus.write8(0x00_420D, 1); // enable FastROM
    before = tc.bus.clock;
    _ = tc.bus.read8(0x80_8000); // upper-half ROM now fast: 6
    try std.testing.expectEqual(@as(u64, 6), tc.bus.clock - before);
    before = tc.bus.clock;
    _ = tc.bus.read8(0x00_8000); // lower half stays slow: 8
    try std.testing.expectEqual(@as(u64, 8), tc.bus.clock - before);
}

test "lorom sram direct-mapped rw" {
    var tc = try TestConsole.create(0x20, 5); // 32 KiB SRAM
    defer tc.destroy();
    tc.bus.write8(0x70_0000, 0x5A);
    tc.bus.write8(0x70_7FFF, 0xA5);
    try std.testing.expectEqual(@as(u8, 0x5A), tc.bus.read8(0x70_0000));
    try std.testing.expectEqual(@as(u8, 0xA5), tc.bus.read8(0x70_7FFF));
    try std.testing.expectEqual(@as(u8, 0x5A), tc.cart.sram[0]);
}

test "small sram mirrors through slow path" {
    var tc = try TestConsole.create(0x20, 1); // 2 KiB SRAM
    defer tc.destroy();
    tc.bus.write8(0x70_0000, 0x42);
    // 2 KiB SRAM mirrors every $800 in the window
    try std.testing.expectEqual(@as(u8, 0x42), tc.bus.read8(0x70_0800));
    try std.testing.expectEqual(@as(u8, 0x42), tc.bus.read8(0x70_1000));
}

test "math unit via bus" {
    var tc = try TestConsole.create(0x20, 3);
    defer tc.destroy();
    tc.bus.write8(0x00_4202, 12);
    tc.bus.write8(0x00_4203, 34);
    const lo = tc.bus.read8(0x00_4216);
    const hi = tc.bus.read8(0x00_4217);
    try std.testing.expectEqual(@as(u16, 12 * 34), @as(u16, lo) | (@as(u16, hi) << 8));

    tc.bus.write8(0x00_4204, 0xE8); // 1000
    tc.bus.write8(0x00_4205, 0x03);
    tc.bus.write8(0x00_4206, 10);
    const qlo = tc.bus.read8(0x00_4214);
    const qhi = tc.bus.read8(0x00_4215);
    try std.testing.expectEqual(@as(u16, 100), @as(u16, qlo) | (@as(u16, qhi) << 8));
}

test "dma a-bus cannot touch dma registers or retrigger itself" {
    var tc = try TestConsole.create(0x20, 3);
    defer tc.destroy();
    // Channel 0: B->A ($21FF open bus -> fixed A-bus address), 4 bytes,
    // with the A side aimed at $420B — the GDMA trigger itself. The A-bus
    // block must drop those writes or the transfer recurses without bound.
    tc.bus.write8(0x00_4300, 0x88); // DMAP: B->A, fixed A-bus
    tc.bus.write8(0x00_4301, 0xFF); // BBAD: $21FF
    tc.bus.write8(0x00_4302, 0x0B); // A1T = $420B
    tc.bus.write8(0x00_4303, 0x42);
    tc.bus.write8(0x00_4305, 4); // DAS = 4
    tc.bus.write8(0x00_420B, 0x01); // must terminate, not recurse
    try std.testing.expectEqual(@as(u16, 0), tc.bus.dma.channels[0].count);

    // Same, aimed at the channel's own DMAP register: the blocked write
    // must leave the live control byte untouched.
    tc.bus.write8(0x00_4302, 0x00); // A1T = $4300
    tc.bus.write8(0x00_4303, 0x43);
    tc.bus.write8(0x00_4305, 4);
    tc.bus.write8(0x00_420B, 0x01);
    try std.testing.expectEqual(@as(u8, 0x88), tc.bus.dma.channels[0].control);
}

test "dsp1 ports on a lorom dsp cart" {
    var tc = try TestConsole.createChip(0x20, 1, 0x03);
    defer tc.destroy();
    // SR is always ready; the DR with no pending output reads $80 too.
    try std.testing.expectEqual(@as(u8, 0x80), tc.bus.read8(0x30_C000));
    try std.testing.expectEqual(@as(u8, 0x80), tc.bus.read8(0x3F_FFFF));
    // Multiply command through the data port: 0.5 * 0.25 = $1000.
    tc.bus.write8(0x30_8000, 0x00);
    tc.bus.write8(0x30_8000, 0x00);
    tc.bus.write8(0x30_8000, 0x40);
    tc.bus.write8(0xB5_9123, 0x00); // mirror bank decodes the same port
    tc.bus.write8(0x30_8000, 0x20);
    try std.testing.expectEqual(@as(u8, 0x00), tc.bus.read8(0x30_8000));
    try std.testing.expectEqual(@as(u8, 0x10), tc.bus.read8(0x30_8000));
    // Non-DSP banks still read ROM.
    try std.testing.expectEqual(tc.cart.rom[0], tc.bus.read8(0x00_8000));
}

test "dsp1 ports on a hirom dsp cart" {
    var tc = try TestConsole.createChip(0x21, 0, 0x03);
    defer tc.destroy();
    try std.testing.expectEqual(@as(u8, 0x80), tc.bus.read8(0x00_7000));
    tc.bus.write8(0x00_6000, 0x00);
    tc.bus.write8(0x00_6000, 0x00);
    tc.bus.write8(0x00_6000, 0x40);
    tc.bus.write8(0x85_6ABC, 0x00); // mirror bank
    tc.bus.write8(0x00_6000, 0x20);
    try std.testing.expectEqual(@as(u8, 0x00), tc.bus.read8(0x00_6000));
    try std.testing.expectEqual(@as(u8, 0x10), tc.bus.read8(0x00_6000));
}

test "cx4 command runs through the $6000-$7fff window on a lorom cart" {
    var tc = try TestConsole.createChip(0x20, 0, 0xF3);
    defer tc.destroy();
    try std.testing.expectEqual(@import("../cart/cartridge.zig").ChipKind.cx4, tc.cart.chip);
    // Status byte $7f5e always reads 0.
    try std.testing.expectEqual(@as(u8, 0x00), tc.bus.read8(0x00_7F5E));
    // Stage a 3·4 multiply ($25): operands as little-endian 24-bit at
    // $7f80 and $7f83, then poke the command byte to $7f4f.
    tc.bus.write8(0x00_7F80, 0x03);
    tc.bus.write8(0x00_7F81, 0x00);
    tc.bus.write8(0x00_7F82, 0x00);
    tc.bus.write8(0x00_7F83, 0x04);
    tc.bus.write8(0x00_7F84, 0x00);
    tc.bus.write8(0x00_7F85, 0x00);
    tc.bus.write8(0x80_7F4F, 0x25); // mirror bank decodes the same window
    try std.testing.expectEqual(@as(u8, 0x0C), tc.bus.read8(0x00_7F80));
    try std.testing.expectEqual(@as(u8, 0x00), tc.bus.read8(0x00_7F81));
    // ROM outside the window still reads normally.
    try std.testing.expectEqual(tc.cart.rom[0], tc.bus.read8(0x00_8000));
}

test "sa1 cart boots the coprocessor through the bus" {
    var tc = try TestConsole.createChip(0x20, 5, 0x33);
    defer tc.destroy();
    // Poke an SA-1 program into the (const-loaded) test ROM at $00:8000:
    // LDA #$85; STA $2209; STP — message 5 + IRQ to the SNES.
    const rom = @constCast(tc.cart.rom);
    const prog = [_]u8{ 0xA9, 0x85, 0x8D, 0x09, 0x22, 0xDB };
    @memcpy(rom[0..prog.len], &prog);

    tc.bus.write8(0x00_2201, 0x80); // SIE: enable SA-1 → SNES IRQ
    tc.bus.write8(0x00_2203, 0x00); // CRV = $8000
    tc.bus.write8(0x00_2204, 0x80);
    tc.bus.write8(0x00_2200, 0x00); // release reset
    tc.bus.clock += 500; // let the SA-1 run; MMIO access catches it up
    try std.testing.expectEqual(@as(u8, 0x85), tc.bus.read8(0x00_2300)); // SFR
    try std.testing.expect(tc.bus.sa1.snes_irq_line);
    tc.bus.write8(0x00_2202, 0x80); // SIC clears
    try std.testing.expect(!tc.bus.sa1.snes_irq_line);

    // IRAM at $3000-$37FF (SIWP gates writes).
    tc.bus.write8(0x00_3123, 0x5A);
    try std.testing.expectEqual(@as(u8, 0x00), tc.bus.read8(0x00_3123));
    tc.bus.write8(0x00_2229, 0xFF);
    tc.bus.write8(0x00_3123, 0x5A);
    try std.testing.expectEqual(@as(u8, 0x5A), tc.bus.read8(0x80_3123));

    // BW-RAM: the $6000 window (SBM block 1) aliases bank $40 linear.
    tc.bus.write8(0x00_2224, 0x01);
    tc.bus.write8(0x00_2226, 0x80); // SWEN
    tc.bus.write8(0x00_6010, 0x77);
    try std.testing.expectEqual(@as(u8, 0x77), tc.bus.read8(0x40_2010));

    // MMC write triggers a page-table rebuild; ROM stays readable.
    const before = tc.bus.read8(0x00_8000);
    tc.bus.write8(0x00_2220, 0x81);
    try std.testing.expectEqual(before, tc.bus.read8(0x00_8000));

    // SNES NMI vector substitution when the SA-1 flips NVSW.
    const rom_vec = tc.bus.read8(0x00_FFEA);
    tc.bus.sa1.snv = 0x1234;
    tc.bus.sa1.cpu_nvsw = true;
    try std.testing.expectEqual(@as(u8, 0x34), tc.bus.read8(0x00_FFEA));
    try std.testing.expectEqual(@as(u8, 0x12), tc.bus.read8(0x00_FFEB));
    tc.bus.sa1.cpu_nvsw = false;
    try std.testing.expectEqual(rom_vec, tc.bus.read8(0x00_FFEA));
}

test "bus state serialize roundtrip rebuilds pages" {
    const serialize = @import("../serialize.zig");
    var tc = try TestConsole.create(0x20, 3);
    defer tc.destroy();
    tc.bus.write8(0x7E_0100, 0x99);
    tc.bus.write8(0x00_4202, 5);
    tc.bus.write8(0x00_4203, 5);
    const saved_clock = tc.bus.clock;

    const size = comptime serialize.byteSize(Bus);
    const buf = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(buf);
    _ = serialize.write(Bus, &tc.bus, buf);

    var tc2 = try TestConsole.create(0x20, 3);
    defer tc2.destroy();
    _ = try serialize.read(Bus, &tc2.bus, buf);
    tc2.bus.postLoad();

    try std.testing.expectEqual(saved_clock, tc2.bus.clock);
    try std.testing.expectEqual(@as(u8, 0x99), tc2.bus.read8(0x7E_0100));
    try std.testing.expectEqual(@as(u16, 25), tc2.bus.math.rdmpy);
}

test "auto-FastROM pins MEMSEL and remaps the upper-bank ROM pages" {
    var tc = try TestConsole.create(0x20, 3); // LoROM, SlowROM header
    defer tc.destroy();

    // A ROM page in the upper banks ($80:8000) charges SlowROM by default.
    try std.testing.expectEqual(timing.speed_slow, tc.bus.page_speed[0x80_8000 >> 13]);

    tc.bus.enableAutoFastrom();
    try std.testing.expect(tc.bus.fastrom);
    try std.testing.expectEqual(timing.speed_fast, tc.bus.page_speed[0x80_8000 >> 13]);
    // The mirror in the lower banks stays slow — FastROM only ever applies
    // to $80-$FF, exactly like a real MEMSEL=1.
    try std.testing.expectEqual(timing.speed_slow, tc.bus.page_speed[0x00_8000 >> 13]);

    // The game clearing MEMSEL (reset code writing 0) must not undo it.
    tc.bus.write8(0x00_420D, 0);
    try std.testing.expect(tc.bus.fastrom);
    try std.testing.expectEqual(timing.speed_fast, tc.bus.page_speed[0x80_8000 >> 13]);

    // And the option survives a save/load: fastrom is serialized as false in
    // an old save, but the skipped in-memory option re-pins it in postLoad.
    const serialize = @import("../serialize.zig");
    var plain = try TestConsole.create(0x20, 3);
    defer plain.destroy();
    const buf = try std.testing.allocator.alloc(u8, comptime serialize.byteSize(Bus));
    defer std.testing.allocator.free(buf);
    _ = serialize.write(Bus, &plain.bus, buf); // a save with fastrom OFF
    _ = try serialize.read(Bus, &tc.bus, buf);
    tc.bus.postLoad();
    try std.testing.expect(tc.bus.fastrom);
    try std.testing.expectEqual(timing.speed_fast, tc.bus.page_speed[0x80_8000 >> 13]);
}

test "aggregated coprocessor IRQ line follows the SA-1 and survives save/load" {
    const serialize = @import("../serialize.zig");
    var tc = try TestConsole.createChip(0x23, 5, 0x34); // SA-1
    defer tc.destroy();

    // SA-1 program at $00:8000: LDA #$85; STA $2209; STP — message 5 with the
    // IRQ bit, raised at the SNES.
    const rom = @constCast(tc.cart.rom);
    const prog = [_]u8{ 0xA9, 0x85, 0x8D, 0x09, 0x22, 0xDB };
    @memcpy(rom[0..prog.len], &prog);

    tc.bus.write8(0x00_2201, 0x80); // SIE: enable SA-1 -> SNES IRQ
    tc.bus.write8(0x00_2203, 0x00); // CRV = $8000
    tc.bus.write8(0x00_2204, 0x80);
    tc.bus.write8(0x00_2200, 0x00); // release reset
    tc.bus.clock += 500;
    _ = tc.bus.read8(0x00_2300); // SFR read catches the SA-1 up
    try std.testing.expect(tc.bus.sa1.snes_irq_line);
    // The aggregate the CPU loop actually reads tracked it through the bus.
    try std.testing.expect(tc.bus.coproc_irq_line);

    // Save with the IRQ pending, restore into a fresh console: the aggregate
    // is skipped by the serializer, so postLoad must rebuild it — a missed
    // rebuild would swallow a pending coprocessor IRQ across a save/load.
    const size = comptime serialize.byteSize(Bus);
    const buf = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(buf);
    _ = serialize.write(Bus, &tc.bus, buf);

    var tc2 = try TestConsole.createChip(0x23, 5, 0x34);
    defer tc2.destroy();
    try std.testing.expect(!tc2.bus.coproc_irq_line);
    _ = try serialize.read(Bus, &tc2.bus, buf);
    tc2.bus.postLoad();
    try std.testing.expect(tc2.bus.sa1.snes_irq_line);
    try std.testing.expect(tc2.bus.coproc_irq_line);

    // Acking through the restored bus drops the aggregate with the line.
    tc2.bus.write8(0x00_2202, 0x80); // SIC clears the message IRQ
    try std.testing.expect(!tc2.bus.sa1.snes_irq_line);
    try std.testing.expect(!tc2.bus.coproc_irq_line);
}

test "HVBJOY exposes the H-blank flag ($4212 bit 6)" {
    // `BIT $4212 / BVC` is how a game waits for H-blank: BIT drops bit 6 straight
    // into the V flag. The flag was never set — `in_hblank` was declared, read,
    // and assigned by nobody — so that wait never ended. F-Zero spins on it at
    // $8616, which is why a LoROM launch title with no coprocessor never drew a
    // frame, and why 100 passing golden ROMs never noticed.
    try std.testing.expect(isHblank(0)); // dots 0-1 and 274+ are blanking
    try std.testing.expect(isHblank(1));
    try std.testing.expect(!isHblank(2));
    try std.testing.expect(!isHblank(22)); // picture
    try std.testing.expect(!isHblank(273));
    try std.testing.expect(isHblank(274)); // H-blank begins
    try std.testing.expect(isHblank(340));

    const tc = try TestConsole.create(0x20, 0); // LoROM
    defer tc.destroy();

    // Mid-picture: the flag is clear.
    tc.bus.hv_line_start = tc.bus.clock;
    tc.bus.clock += 100 * timing.cycles_per_dot;
    try std.testing.expectEqual(@as(u8, 0), tc.bus.read8(0x00_4212) & 0x40);

    // Past dot 274: it must appear, or `BVC` loops forever.
    tc.bus.clock = tc.bus.hv_line_start + 280 * timing.cycles_per_dot;
    try std.testing.expect(tc.bus.read8(0x00_4212) & 0x40 != 0);
}
