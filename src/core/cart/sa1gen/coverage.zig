//! Static coverage extension: the hand-made code map's per-byte verdicts and `extendCoverage`, the recursive-descent walk that reaches code the profiled run never ran.
//!
//! Carved out of sa1gen.zig as pure code motion; every declaration here is
//! re-exported from sa1gen.zig, which stays the module's public root.

const header_mod = @import("../header.zig");
const std = @import("std");
const usage_map = @import("../../usage_map.zig");
const sa1gen = @import("../sa1gen.zig");

const dbg_code_map = sa1gen.dbg_code_map;
const dbg_walk_watch = sa1gen.dbg_walk_watch;
pub const cm_start: u8 = 0x10;
pub const cm_interior: u8 = 0x20;
pub const cm_data: u8 = 0x80;
pub const cm_m_known: u8 = 0x04;
pub const cm_x_known: u8 = 0x08;
pub const cm_m8: u8 = 0x02;
pub const cm_x8: u8 = 0x01;
/// A 16-bit immediate the disassembly names with a low-WRAM label and the
/// next instruction stores: a pointer into the window. The evidence-gated
/// pointer-seed rule only reaches the seeds a profiled dereference proved;
/// the label is proof for the rest. Measured: `LDA #CustomDrawInst_NumberOfBlocks`
/// stored into the PLM draw-instruction pointers ($84:8B3B) was never shifted,
/// the draw routine read its block word through the abandoned WRAM home, and
/// every destructible block Samus revealed drew as a flipped tile $3FF —
/// the crosses a session saw in green Brinstar.
pub const cm_wram_pointer: u8 = 0x40;

/// The map's flags for a CPU address (either mirror), 0 without a map.
pub fn codeMapAt(a: u32) u8 {
    const m = sa1gen.dbg_code_map orelse return 0;
    const hi = (a | 0x80_0000) & 0xFF_FFFF;
    return m[hi];
}

/// A byte the map places inside an instruction or in data: never a start.
pub fn codeMapForbids(a: u32) bool {
    const cm = codeMapAt(a);
    return cm != 0 and cm & cm_start == 0;
}

/// `--wg-static`: extend the S1 coverage map by recursive-descent
/// disassembly. Every dynamically covered opcode is a PROVEN instruction
/// start with proven M/X widths — the profiler recorded them — which
/// sidesteps the classic 65816 static-disassembly trap: immediates change
/// length with the width flags, so a cold disassembler cannot even take
/// instruction boundaries for granted. Seeded from every covered opcode
/// plus the reset vector, the walk decodes forward through code the
/// profiled run never reached, following static control flow (branches both
/// ways, JSR/JSL target and return, JMP/JML/BRA/BRL targets) and
/// propagating widths through SEP/REP. A path stops wherever the widths
/// stop being provable (PLP, XCE, RTI) or control goes somewhere static
/// analysis cannot follow — indirect jumps, whose targets are usually
/// covered seeds already, which is the point of seeding from coverage.
/// Bytes never reached stay data and are never rewritten.
pub fn extendCoverage(
    gpa: std.mem.Allocator,
    image: []const u8,
    header: header_mod.Header,
    usage: []const u8,
) ![]u8 {
    const ext = try gpa.dupe(u8, usage);
    errdefer gpa.free(ext);
    // File-offset-shaped visit marks; one decode per byte is enough because
    // dynamic flags are already trusted and a width conflict is grounds to
    // stop, not re-decode.
    const seen = try gpa.alloc(bool, image.len);
    defer gpa.free(seen);
    @memset(seen, false);

    const Item = struct { addr: u24, m8: bool, x8: bool, from: u32 = 0xFFFF_FFFF };
    var stack: std.array_list.Managed(Item) = .init(gpa);
    defer stack.deinit();

    if (header.reset_vector >= 0x8000)
        try stack.append(.{ .addr = header.reset_vector, .m8 = true, .x8 = true });
    if (sa1gen.dbg_code_map) |cm| {
        // Every instruction start the map names is a seed. Widths along
        // the path come from the map at each immediate, so the seed's own
        // guess only matters up to the first one.
        var mcpu: u32 = 0x80_8000;
        while (mcpu < 0xC0_0000) : (mcpu += 1) {
            if (mcpu & 0xFFFF < 0x8000) continue;
            if (cm[mcpu] & cm_start == 0) continue;
            const lo: u32 = mcpu - 0x80_0000;
            if (lo >> 16 >= 0x40) continue;
            try stack.append(.{ .addr = @intCast(lo), .m8 = true, .x8 = true, .from = 0xFFFF_FFFC });
        }
        std.debug.print("[code-map] {} seeds from the map\n", .{stack.items.len});
    }
    var sbank: u32 = 0;
    while (sbank < 0x40) : (sbank += 1) {
        if (sbank * 0x8000 >= image.len) break;
        var sa: u32 = 0x8000;
        while (sa < 0x10000) : (sa += 1) {
            const cpu = (sbank << 16) | sa;
            for ([2]u32{ cpu, 0x80_0000 | cpu }) |c| {
                const fl = usage[c];
                if (fl & usage_map.flag_opcode != 0) try stack.append(.{
                    .addr = @intCast(cpu),
                    .m8 = fl & usage_map.flag_m != 0,
                    .x8 = fl & usage_map.flag_x != 0,
                });
            }
        }
    }

    // POINTER-LITERAL DESCENT (fixpoint): the walk cannot follow
    // `JMP ($099C)`, but the pointers those cells hold are stored as
    // IMMEDIATES by covered code — `LDA #$E737 / STA $099C` — so the
    // targets are statically enumerable. Each round: walk; then scan the
    // covered instructions for a 16-bit immediate load whose value is
    // stored straight into a cell some covered indirect jump dispatches
    // through, and seed that value as a code entry in the DISPATCHER's
    // bank. Re-walk until nothing new appears (measured: Super Metroid's
    // cutscene script chains eleven handlers through $099C; the covered
    // seed store was rewritten to the window while the uncovered
    // dispatcher kept the stale home, the chain died at the first link,
    // the tileset-palette decompression never ran, and the new-game
    // cutscene faded into a black room with input alive).
    var round: u32 = 0;
    fixpoint: while (round < 6) : (round += 1) {
        while (stack.pop()) |item| {
            var addr: u32 = item.addr;
            var m8 = item.m8;
            var x8 = item.x8;
            var prev: u32 = item.from;
            walk: while (true) {
                const wbank = addr >> 16;
                const a16 = addr & 0xFFFF;
                const cpu0: u32 = addr;
                if (wbank >= 0x40 or a16 < 0x8000) break;
                const file = wbank * 0x8000 + (a16 - 0x8000);
                if (file >= image.len) break;
                if (seen[file]) break;
                const dyn = usage[cpu0] | usage[0x80_0000 | cpu0];
                if (dyn & (usage_map.flag_read | usage_map.flag_write) != 0 and
                    dyn & usage_map.flag_opcode == 0) break;
                // The INTERIOR of an executed instruction is not a place
                // to start decoding either: the profiler proved an opcode
                // before it and the bytes here are its operand. A path
                // that arrives mid-instruction (a misread width upstream,
                // a table walked as code) would otherwise decode the
                // operand as an opcode and REWRITE what follows. Measured
                // on Super Metroid: `AND #$FC / STA $2117` walked from its
                // immediate — `$FC $8D $17` read as `JSR ($178D,X)` — and
                // the window shift turned the store into `STA $2177`, the
                // APU mailbox mirror: every patch from v66 to v68 fed the
                // sound driver a stray byte at four VRAM-address sites, and
                // it died on the first one a session reached (a death, a
                // loud room), leaving the death jingle's engine upload
                // waiting forever.
                if (dyn & usage_map.flag_exec != 0 and dyn & usage_map.flag_opcode == 0) break;
                // The code map's veto and its widths (see `sa1gen.dbg_code_map`).
                const cmf = codeMapAt(cpu0);
                if (cmf != 0 and cmf & cm_start == 0) break;
                if (cmf & cm_m_known != 0) m8 = cmf & cm_m8 != 0;
                if (cmf & cm_x_known != 0) x8 = cmf & cm_x8 != 0;
                seen[file] = true;
                const op = image[file];
                const len: u32 = usage_map.instrLen(op, m8, x8);
                if (a16 + len > 0x10000) break;
                for (sa1gen.dbg_walk_watch) |w| if (w != 0 and (w & 0x3F_FFFF) == (addr & 0x3F_FFFF) and ext[addr] & usage_map.flag_opcode == 0)
                    std.debug.print("[walk] opcode at ${x:0>6} op={x:0>2} m8={} x8={} from=${x:0>6} (seed={}) dyn={x:0>2} round={}\n", .{ addr, op, m8, x8, prev & 0xFF_FFFF, @as(u32, @intCast(0xFFFF_FFFF - prev)), dyn, round });
                if (ext[addr] & usage_map.flag_opcode == 0) {
                    ext[addr] &= ~(usage_map.flag_m | usage_map.flag_x);
                    ext[addr] |= usage_map.flag_opcode | usage_map.flag_exec |
                        (if (m8) usage_map.flag_m else @as(u8, 0)) |
                        (if (x8) usage_map.flag_x else @as(u8, 0));
                    var i: u32 = 1;
                    while (i < len) : (i += 1) ext[addr + i] |= usage_map.flag_exec;
                }
                switch (op) {
                    // Path enders: returns, software interrupts, STP — and the
                    // two instructions after which the widths are anyone's
                    // guess.
                    0x60, 0x6B, 0x40, 0x00, 0x02, 0xDB, 0x28, 0xFB => break,
                    0xE2 => { // SEP #imm
                        const im = image[file + 1];
                        if (im & 0x20 != 0) m8 = true;
                        if (im & 0x10 != 0) x8 = true;
                    },
                    0xC2 => { // REP #imm
                        const im = image[file + 1];
                        if (im & 0x20 != 0) m8 = false;
                        if (im & 0x10 != 0) x8 = false;
                    },
                    0x4C => { // JMP abs: bank-confined
                        const t = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
                        try stack.append(.{ .addr = @intCast((wbank << 16) | t), .m8 = m8, .x8 = x8, .from = addr });
                        break;
                    },
                    0x5C, 0x22 => { // JML long / JSL long
                        const t = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
                        const tb: u32 = image[file + 3] & 0x7F;
                        try stack.append(.{ .addr = @intCast((tb << 16) | t), .m8 = m8, .x8 = x8, .from = addr });
                        if (op == 0x5C) break; // JSL falls through on return
                        // A JSL the profiled run EXECUTED whose return address
                        // it never marked as an opcode is a call with INLINE
                        // PARAMS — the callee walks the return address past
                        // them (SM's DMA launcher carries 8 bytes after every
                        // JSL). Decoding those as code plants rewrites inside
                        // data (measured: `19 00 00` in a param block became a
                        // context-split thunk and the armed transfer read
                        // $F768 — the thunk's own address). The profile
                        // outranks static reach: stop the fall-through.
                        if (a16 + 4 < 0x10000) {
                            const dyn_site = usage[addr] & usage_map.flag_opcode != 0 or
                                usage[0x80_0000 | addr] & usage_map.flag_opcode != 0;
                            if (dyn_site) {
                                // Two shapes leave a covered JSL with an
                                // uncovered fall-through, and they need opposite
                                // treatment. INLINE PARAMS: the callee returns
                                // PAST the params, so the profile marked a real
                                // opcode a few bytes further on — trust it and
                                // stop, or the params decode as code (measured:
                                // `19 00 00` in a param block became a
                                // context-split thunk). CALL NEVER RETURNED: the
                                // profiled run died or was cut inside the callee
                                // (measured: the door-transition JSL chain at
                                // $82:E1CA — the player's recording crashed in
                                // the first callee, so the two SIBLING JSLs
                                // behind it kept their stock $A0 banks and the
                                // next walk-through crashed one call later).
                                // There the window past the call is dyn-DEAD,
                                // and the static fall-through is both safe and
                                // the only way to make progress.
                                var probe: u32 = addr + 4;
                                var dyn_near = false;
                                const lim: u32 = @min(addr + 4 + 32, (wbank << 16) | 0xFFFF);
                                while (probe < lim) : (probe += 1) {
                                    if (usage[probe] & usage_map.flag_opcode != 0 or
                                        usage[0x80_0000 | probe] & usage_map.flag_opcode != 0)
                                    {
                                        dyn_near = true;
                                        break;
                                    }
                                }
                                if (dyn_near) break; // inline params: profile wins
                            }
                        }
                    },
                    0x20 => { // JSR abs: target plus fall-through
                        const t = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
                        try stack.append(.{ .addr = @intCast((wbank << 16) | t), .m8 = m8, .x8 = x8, .from = addr });
                    },
                    0x80, 0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0 => {
                        const rel: i8 = @bitCast(image[file + 1]);
                        const t = (a16 +% 2 +% @as(u32, @bitCast(@as(i32, rel)))) & 0xFFFF;
                        try stack.append(.{ .addr = @intCast((wbank << 16) | t), .m8 = m8, .x8 = x8, .from = addr });
                        if (op == 0x80) break; // BRA is unconditional
                    },
                    0x82 => { // BRL
                        const rel: i16 = @bitCast(std.mem.readInt(u16, image[file + 1 ..][0..2], .little));
                        const t = (a16 +% 3 +% @as(u32, @bitCast(@as(i32, rel)))) & 0xFFFF;
                        try stack.append(.{ .addr = @intCast((wbank << 16) | t), .m8 = m8, .x8 = x8, .from = addr });
                        break;
                    },
                    // Indirect control transfers: statically opaque. (JSR
                    // (abs,X) does fall through on return, so it continues.)
                    0x6C, 0x7C, 0xDC => break,
                    else => {},
                }
                prev = addr;
                addr += len;
                continue :walk;
            }
        }
        // Scan for new pointer-literal seeds. The dispatchers themselves are
        // usually part of the UNCOVERED cluster (that is the hole being
        // closed), so they are matched in the RAW image — any `JMP (cell)` /
        // `JSR (cell,X)` shape naming a low-WRAM cell — and the conjunction
        // with a COVERED immediate store to the same cell is what makes a
        // false positive unlikely: both sides must independently name the
        // same sub-$2000 pointer. A matched dispatcher is seeded as code too,
        // so its own pointer operand shifts with the cell.
        // Banks with ANY dynamically-executed opcode: dispatchers are CODE, and
        // real ones live amid covered code (the cutscene dispatchers sit in bank
        // $02's covered cluster). A pure DATA bank supplies raw $6C/$FC bytes by
        // the thousand — 3,526 of them matched across the 3 MiB image once the
        // site list was uncapped (22fd4a2), each planting a window-shifted fake
        // operand inside stream data (the Ceres door confetti was one such byte;
        // the rest garble tilesets of rooms the profiled surfaces never visit).
        var bank_has_exec = [_]bool{false} ** 0x40;
        {
            var eb: u32 = 0;
            while (eb < 0x40) : (eb += 1) {
                if (eb * 0x8000 >= image.len) break;
                var ea: u32 = 0x8000;
                while (ea < 0x10000) : (ea += 1) {
                    const ec = (eb << 16) | ea;
                    if ((usage[ec] | usage[0x80_0000 | ec]) & usage_map.flag_opcode != 0) {
                        bank_has_exec[eb] = true;
                        break;
                    }
                }
            }
        }
        var ptr_bank = [_]u8{0} ** 0x2000; // cell -> dispatcher bank + 1
        var cell_reached = [_]bool{false} ** 0x2000; // a dispatcher shape for the cell sits in reached code
        var pb2: u32 = 0;
        while (pb2 < 0x40) : (pb2 += 1) {
            if (pb2 * 0x8000 >= image.len) break;
            var pa2: u32 = 0x8000;
            while (pa2 < 0x10000) : (pa2 += 1) {
                const f2 = pb2 * 0x8000 + (pa2 - 0x8000);
                const o2 = image[f2];
                if (o2 == 0x6C or o2 == 0x7C or o2 == 0xFC or o2 == 0xDC) {
                    if (f2 + 2 < image.len) {
                        // DATA-GATE: a byte the profile READ without ever
                        // executing is stream/table data, and a raw `$FC` there
                        // is a coincidence, not a dispatcher. Seeding it as code
                        // window-shifts a fake operand INSIDE the data
                        // (measured: `FC FC 0A` in the Ceres door-tileset's
                        // compressed stream became `JSR ($0AFC,X)`, its "$0AFC"
                        // was shifted to $6AFC — one byte, $0A -> $6A — and the
                        // decompressor's back-references cascaded it across the
                        // whole door sprite band as confetti).
                        if (!bank_has_exec[pb2]) continue;
                        const cpu2 = (pb2 << 16) | pa2;
                        if (codeMapForbids(cpu2)) continue;
                        const dflags = usage[cpu2] | usage[0x80_0000 | cpu2];
                        const data_only = dflags & (usage_map.flag_read | usage_map.flag_write) != 0 and
                            dflags & usage_map.flag_opcode == 0;
                        // EXECUTED-INTERIOR gate, and a REACH requirement for
                        // activation: an opcode-shaped byte the profile fetched
                        // as an OPERAND is an immediate, not a dispatcher, and a
                        // cell whose only dispatcher shapes sit in bytes nothing
                        // ever executed or walked is not a dispatch cell at all.
                        // Measured on Super Metroid: `$178D` is a plain WRAM
                        // variable with one covered store; its four "dispatchers"
                        // were the immediates of `AND #$FC` / `LDA #$7C` before
                        // `STA $2117`, two inside executed code and two in code
                        // nothing reached. The cell activated, the four bytes were
                        // marked as starts, and the shift of their "operand" turned
                        // each store into `STA $2177` — the APU mailbox mirror.
                        const interior = dflags & usage_map.flag_exec != 0 and dflags & usage_map.flag_opcode == 0;
                        const eflags = ext[cpu2] | ext[0x80_0000 | cpu2];
                        const reached = (dflags | eflags) & usage_map.flag_exec != 0;
                        const cell = std.mem.readInt(u16, image[f2 + 1 ..][0..2], .little);
                        if (cell < 0x2000 and !data_only and !interior) {
                            ptr_bank[cell] = @intCast(pb2 + 1);
                            if (reached) cell_reached[cell] = true;
                        }
                    }
                }
            }
        }
        var grew = false;
        // TWO-TIER ACTIVATION: matching raw stores image-wide over-reaches
        // (measured: the raw scan activated cells across the whole image and
        // ballooned coverage by 16 KiB of speculation, and the dispatcher
        // marks were lost under overlapping walks). A cell ACTIVATES only
        // when a COVERED 16-bit literal store names it — the genuine
        // mixed-population signal — and only active cells accept the
        // raw-store expansion that reaches the chain's deeper links.
        var cell_active = [_]bool{false} ** 0x2000;
        var ab: u32 = 0;
        while (ab < 0x40) : (ab += 1) {
            if (ab * 0x8000 >= image.len) break;
            var aa: u32 = 0x8000;
            while (aa < 0x10000) : (aa += 1) {
                const ca = (ab << 16) | aa;
                const fla = ext[ca] | ext[0x80_0000 | ca];
                if (fla & usage_map.flag_opcode == 0) continue;
                if (fla & usage_map.flag_m != 0) continue;
                const fa = ab * 0x8000 + (aa - 0x8000);
                if (fa + 6 > image.len) continue;
                if (image[fa] != 0xA9 or image[fa + 3] != 0x8D) continue;
                const acell = std.mem.readInt(u16, image[fa + 4 ..][0..2], .little);
                if (acell < 0x2000 and ptr_bank[acell] != 0 and cell_reached[acell]) cell_active[acell] = true;
            }
        }
        var sb3: u32 = 0;
        while (sb3 < 0x40) : (sb3 += 1) {
            if (sb3 * 0x8000 >= image.len) break;
            var sa3: u32 = 0x8000;
            while (sa3 < 0x10000) : (sa3 += 1) {
                const c3 = (sb3 << 16) | sa3;
                const f3 = sb3 * 0x8000 + (sa3 - 0x8000);
                if (f3 + 6 > image.len) continue;
                if (image[f3] != 0xA9 or image[f3 + 3] != 0x8D) continue;
                const cell = std.mem.readInt(u16, image[f3 + 4 ..][0..2], .little);
                if (cell >= 0x2000 or !cell_active[cell]) continue;
                const tgt = std.mem.readInt(u16, image[f3 + 1 ..][0..2], .little);
                if (tgt < 0x8000) continue;
                const fl3 = ext[c3] | ext[0x80_0000 | c3];
                const covered3 = fl3 & usage_map.flag_opcode != 0;
                if (covered3 and fl3 & usage_map.flag_m != 0) continue;
                const db3: u32 = ptr_bank[cell] - 1;
                const taddr: u32 = (db3 << 16) | tgt;
                if (codeMapForbids(taddr)) continue;
                const tfile = db3 * 0x8000 + (tgt - 0x8000);
                if (tfile >= image.len) continue;
                const x8_3 = covered3 and fl3 & usage_map.flag_x != 0;
                if (!seen[tfile]) {
                    try stack.append(.{ .addr = @intCast(taddr), .m8 = false, .x8 = x8_3, .from = 0xFFFF_FFFE });
                    grew = true;
                }
                if (!covered3 and !seen[f3]) {
                    try stack.append(.{ .addr = @intCast(c3), .m8 = false, .x8 = x8_3, .from = 0xFFFF_FFFD });
                    grew = true;
                }
            }
        }
        // Dispatchers of ACTIVE cells: marked as instruction starts DIRECTLY —
        // a `JMP (cell)` is three bytes and the walk would only break on it
        // anyway, and walk-order overlaps were losing the mark. Re-scanned
        // raw and uncapped here: a fixed-size site list overflowed on the
        // coincidental `6C xx` bytes of three megabytes of data long before
        // it reached the real dispatchers (measured: 64 slots died in bank
        // $01 while the cutscene dispatchers live at $02:E16F/$02:E28F).
        var mb2: u32 = 0;
        while (mb2 < 0x40) : (mb2 += 1) {
            if (mb2 * 0x8000 >= image.len) break;
            var ma2: u32 = 0x8000;
            while (ma2 < 0x10000) : (ma2 += 1) {
                const mf = mb2 * 0x8000 + (ma2 - 0x8000);
                const mo = image[mf];
                if (mo != 0x6C and mo != 0x7C and mo != 0xFC and mo != 0xDC) continue;
                if (mf + 2 >= image.len) continue;
                if (!bank_has_exec[mb2]) continue;
                const mcell = std.mem.readInt(u16, image[mf + 1 ..][0..2], .little);
                if (mcell >= 0x2000 or !cell_active[mcell]) continue;
                const msite = (mb2 << 16) | ma2;
                if (codeMapForbids(msite)) continue;
                // Same DATA-GATE as the ptr_bank scan: a byte the profile READ
                // without executing is data, and marking it as a dispatcher
                // start window-shifts a fake operand inside it (the Ceres
                // door-stream `FC FC 0A` confetti byte).
                const mflags = usage[msite] | usage[0x80_0000 | msite];
                if (mflags & (usage_map.flag_read | usage_map.flag_write) != 0 and
                    mflags & usage_map.flag_opcode == 0) continue;
                // And the EXECUTED-INTERIOR gate: a byte the profile fetched
                // as an operand is not an instruction start either. This raw
                // scan matches opcode-shaped IMMEDIATES — measured on Super
                // Metroid: `AND #$FC` / `LDA #$7C` followed by `STA $2117`
                // read as `JSR ($178D,X)` / `JMP ($178D,X)` on an active
                // cell, got marked as dispatchers, and the window shift of
                // that "operand" turned the store into `STA $2177`, the APU
                // mailbox mirror: the sound driver took the VRAM address
                // byte as a request and died, and every patch from v66 to
                // v68 hung at the first death that reached one of the four
                // sites. The same for a start whose "operand" bytes carry an
                // opcode of their own (two decodes cannot overlap).
                if (mflags & usage_map.flag_exec != 0 and mflags & usage_map.flag_opcode == 0) continue;
                if ((ext[msite + 1] | ext[0x80_0000 | (msite + 1)] | ext[msite + 2] | ext[0x80_0000 | (msite + 2)]) & usage_map.flag_opcode != 0) continue;
                if (ext[msite] & usage_map.flag_opcode == 0) {
                    ext[msite] &= ~(usage_map.flag_m | usage_map.flag_x);
                    ext[msite] |= usage_map.flag_opcode | usage_map.flag_exec;
                    ext[msite + 1] |= usage_map.flag_exec;
                    ext[msite + 2] |= usage_map.flag_exec;
                    grew = true;
                }
            }
        }
        if (!grew) break :fixpoint;
    }
    return ext;
}
