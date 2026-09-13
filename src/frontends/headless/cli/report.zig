//! The analyser's output: the SA-1 candidacy report, the audit and coverage printers, the offload census, the relocation plan, the conversion verdict, the routine tables.
//!
//! Carved out of main.zig as pure code motion; every declaration
//! here is re-exported from main.zig, which stays the root.

const core = @import("snes_core");
const profile = core.profile;
const std = @import("std");
const util = @import("util");
const root_mod = @import("../main.zig");
const testing = std.testing;

const Args = root_mod.Args;
const SaTier = root_mod.SaTier;
const anchorMovie = root_mod.anchorMovie;
const applyStartSave = root_mod.applyStartSave;
const loadStateInto = root_mod.loadStateInto;
const main = root_mod.main;
const report_frames_default = root_mod.report_frames_default;
const run = root_mod.run;
const writeCovOut = root_mod.writeCovOut;
const writeMmioRef = root_mod.writeMmioRef;
/// The success report for an SA-1 conversion attempt, including what the
/// auto-bisect dropped along the way.
pub fn reportSa1(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    args: Args,
    image: []const u8,
    res: core.sa1gen.Result,
    tier: SaTier,
    total: u32,
    sum: profile.Summary,
    conv_sum: profile.Summary,
    dropped: []const u24,
    dropped_why: []const []const u8,
    cov_total: u32,
    cov_late: u32,
) !void {
    const bps = try core.patch.writeBps(gpa, image, res.image);
    const stem = args.rom[0 .. std.mem.lastIndexOfScalar(u8, args.rom, '.') orelse args.rom.len];
    const path = args.gen_out orelse try std.fmt.allocPrint(gpa, "{s}-sa1.bps", .{stem});
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bps }) catch {
        try out.print("error: cannot write '{s}'\n", .{path});
        try out.flush();
        std.process.exit(1);
    };
    // The invocation, beside its own artifact. A patch whose command has
    // to be remembered is a patch nobody can regenerate.
    const cmd_path = try std.fmt.allocPrint(gpa, "{s}.cmd", .{path});
    const cmd_data = try std.fmt.allocPrint(gpa, "{s}\n", .{args.cmdline});
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cmd_path, .data = cmd_data }) catch {};

    try out.print("wrote {s} ({} bytes)\n", .{ path, bps.len });
    try out.print("wrote {s}\n\n", .{cmd_path});
    if (root_mod.mmio_n_g > 0) {
        // The MMIO writer sets beside the patch: stock's and the verified
        // conversion's, plus stock's padding — the reference `--mmio-ref`
        // checks a human take against.
        const mpath = try std.fmt.allocPrint(gpa, "{s}.mmio", .{path});
        writeMmioRef(io, mpath, image, root_mod.mmio_base_g[0..root_mod.mmio_n_g], root_mod.mmio_conv_g[0..root_mod.mmio_n_g]) catch {};
        try out.print("wrote {s} (the MMIO writer sets, for --mmio-ref)\n", .{mpath});
    }
    try writeCovOut(io, gpa, out, args);
    if (args.window) {
        try out.print(
            \\uniform window relocation (v17's architecture):
            \\  boot shim at $00:{x:0>4}; the game KEEPS RUNNING ON THE S-CPU
            \\  its WRAM moved wholesale — low 8 KiB into the S-CPU's BW-RAM window
            \\  ($6000-$7FFF, every relative distance preserved, so indexed bases
            \\  rewrite soundly), $7E/$7F long references re-banked to $40/$41
            \\  {d} long site(s) and {d} absolute site(s) rewritten; {d} D/S/DBR move(s)
            \\  MMIO stays native; the SA-1 never leaves reset — the cart is carried
            \\  for its RAM. This is the enabler for resident offloads over the whole
            \\  working set.
            \\
        , .{
            res.stats.shim_addr,
            res.stats.rewritten_long,
            res.stats.rewritten_abs,
            res.stats.dp_sites,
        });
        if (res.stats.split_sites != 0)
            try out.print(
                "  {} split site(s) dispatch through a thunk instead of a fixed operand:\n  {} on the runtime data bank, {} on the index register's magnitude\n  (tiny-base indexed absolutes — no single operand serves a data base\n  and a ROM walk); {} of them behind a far stub for want of bank room\n",
                .{ res.stats.split_sites, res.stats.split_sites - res.stats.idx_split_sites, res.stats.idx_split_sites, res.stats.split_far },
            );
        if (res.stats.disp_sites != 0)
            try out.print(
                "  {} unmeasured site(s) in full banks share one stub per bank through\n  the cold dispatcher (return-address lookup; ~150 cycles, never-seen code)\n",
                .{res.stats.disp_sites},
            );
        if (res.stats.rewritten_ptr_banks != 0 or res.stats.rewritten_idx_words != 0 or res.stats.rewritten_dma_addrs != 0)
            try out.print(
                "  measured value rewrites: {} pointer-bank byte(s) re-banked, {} dp,X\n  pointer word(s) pre-shifted -$6000, {} dma-addr word(s) pre-shifted\n  +$6000 (addressing state travelling as data — the idioms operand\n  rewrites cannot reach)\n",
                .{ res.stats.rewritten_ptr_banks, res.stats.rewritten_idx_words, res.stats.rewritten_dma_addrs },
            );
        if (res.stats.rewritten_queue_imms != 0)
            try out.print(
                "  {} queue-bank immediate(s) re-banked BY SIGNATURE (LDA #imm16 staged\n  into a dispatch queue's bank column and PLB'd by later code — the\n  XBA/PHA/PLB/PLB consumer names the column; no coverage required)\n",
                .{res.stats.rewritten_queue_imms},
            );
        if (res.stats.rewritten_wmdata_fills != 0)
            try out.print(
                "  {} WMDATA-port fill(s) turned into MVN block moves into BW-RAM BY\n  SIGNATURE (the port writes real WRAM only; the pause map's tilemap\n  loads went to the abandoned home — findings §4o)\n",
                .{res.stats.rewritten_wmdata_fills},
            );
        if (res.stats.rewritten_twin_jsls != 0)
            try out.print(
                "  {} mirror-bank JSL(s) re-banked on their DE-MIRRORED TWIN's\n  evidence — uncovered call sites whose target is already called in\n  its $20-$3F form by covered code (>=2 calls). The class that cost\n  three player-found freezes; no coverage required\n",
                .{res.stats.rewritten_twin_jsls},
            );
        if (res.stats.room_walk_states != 0)
            try out.print(
                "  {} room-state level-data bank(s) re-banked by the ROOM-GRAPH WALK\n  ({} rooms, {} states reached through doors from the landing site —\n  Super Metroid's structure, not coverage: a state no surface loaded\n  kept its stock MB2 bank and decompressed garbage geometry)\n",
                .{ res.stats.rewritten_room_level_banks, res.stats.room_walk_rooms, res.stats.room_walk_states },
            );
        if (res.stats.room_walk_refused_at != 0)
            try out.print("  room-graph walk REFUSED at $8F:{X:0>4} (a header failed validation);\n  level pointers left to evidence alone\n", .{res.stats.room_walk_refused_at});
        if (res.stats.bg_records != 0)
            try out.print(
                "  {} background DMA-list source bank(s) de-mirrored across {} record(s)\n  — the BG2 picture for rooms no surface loaded (else correct foreground\n  over garbage background)\n",
                .{ res.stats.rewritten_bg_banks, res.stats.bg_records },
            );
        if (res.stats.decomp_inline_sites != 0)
            try out.print(
                "  {} decompressor inline-destination bank(s) re-banked BY SIGNATURE\n  ({} `JSL $80:B0FF` sites naming WRAM) — the destination is data in the\n  code stream; a site no recording drove decompressed into real $7E\n  while the game read the stale copy at $40 (wrong tile table = right\n  geometry, wrong textures)\n",
                .{ res.stats.rewritten_decomp_inline_banks, res.stats.decomp_inline_sites },
            );
        if (res.stats.tileset_records != 0)
            try out.print(
                "  {} tileset-table bank(s) de-mirrored ({} records) — the picture\n  (tile table/GFX/palette) for tilesets no surface loaded; without it a\n  reachable room renders tile garbage over a wrong palette\n",
                .{ res.stats.rewritten_tileset_banks, res.stats.tileset_records },
            );
        if (res.stats.tileset_refused_at != 0)
            try out.print("  tileset-table pass REFUSED at $8F:{X:0>4} (a record failed validation)\n", .{res.stats.tileset_refused_at});
        if (res.stats.enemy_headers != 0)
            try out.print(
                "  {} enemy-header bank(s) de-mirrored ({} headers) — the species' AI,\n  palette and instruction-list bank for enemies no surface met; without\n  it a new enemy paints its palette from the wrong megabyte and runs its\n  AI from it\n",
                .{ res.stats.rewritten_enemy_banks, res.stats.enemy_headers },
            );
        if (res.stats.pointer_seed_sites != 0)
            try out.print(
                "  {} pointer-seed immediate(s) translated ({} sites) — long pointers the\n  game seeds from constants (the pause map's tilemap bank and its\n  explored-bits address); without it the map draws from the abandoned\n  WRAM homes\n",
                .{ res.stats.rewritten_pointer_seeds, res.stats.pointer_seed_sites },
            );
        if (res.stats.area_map_entries != 0)
            try out.print(
                "  {} area-map table bank(s) de-mirrored ({} entries) — the per-area map\n  tilemap pointers the HUD minimap and the pause map read through; without\n  it the minimap paints text glyphs for map cells\n",
                .{ res.stats.rewritten_area_map_banks, res.stats.area_map_entries },
            );
        if (res.stats.area_map_refused_at != 0)
            try out.print("  area-map table pass REFUSED at $82:{X:0>4} (an entry failed validation)\n", .{res.stats.area_map_refused_at});
        if (res.stats.rewritten_dasb != 0)
            try out.print(
                "  {} HDMA indirect-bank ($43x7 DASB) write(s) wrapped in a runtime\n  rebank thunk ($7E/$7F->$40/$41 as the write happens — an indirect\n  HDMA whose source is WRAM follows its data into BW-RAM)\n",
                .{res.stats.rewritten_dasb},
            );
        if (res.stats.rewritten_hdma_indirect != 0)
            try out.print(
                "  {} low-WRAM indirect address(es) relocated +$6000 in indirect-HDMA\n  table(s) (a per-scanline HDMA source in the moved low 8 KiB now reads\n  the window copy, not the abandoned mirror)\n",
                .{res.stats.rewritten_hdma_indirect},
            );
        if (res.stats.offload_count != 0) {
            try out.print("  {} routine tree(s) execute ON THE SA-1, verbatim against the shared\n  window (resident by construction, registers+D+DBR through the mailbox):\n", .{res.stats.offload_count});
            for (res.stats.offload_entries[0..res.stats.offload_count], 0..) |e, i| {
                try out.print("    $00:{x:0>4} ({} byte(s) of tree copied{s})\n", .{
                    e,
                    res.stats.offload_copy_len[i],
                    if (res.stats.async_entry == e) @as([]const u8, ", ASYNC — fire-and-forget") else "",
                });
            }
        }
    } else if (args.whole_game) {
        try out.print(
            \\whole-game migration (SA-1 Root):
            \\  boot shim at $00:{x:0>4}, S-CPU service loop at $00:{x:0>4}
            \\  the game executes ENTIRELY on the SA-1 — its WRAM working set lives in
            \\  identity-mapped I-RAM; {d} MMIO site(s) proxied through the I-RAM mailbox
            \\  (NMI masked per transaction), {d} long site(s) re-banked into the window;
            \\  NMI forwarded S-CPU -> SA-1 through CCNT/CNV
            \\
        , .{
            res.stats.shim_addr,     res.stats.park_addr,
            res.stats.offload_sites, res.stats.rewritten_long,
        });
    } else {
        try out.print(
            \\SA-1 conversion (stages S3 + S4):
            \\  shim at $00:{x:0>4}, SA-1 booted at $00:{x:0>4}
            \\  regions moved {d} / blocked {d}; rewrites: {d} long, {d} abs; {d} dp site(s){s}
            \\
        , .{
            res.stats.shim_addr,      res.stats.park_addr,
            res.stats.regions_moved,  res.stats.regions_blocked,
            res.stats.rewritten_long, res.stats.rewritten_abs,
            res.stats.dp_sites,       if (res.stats.d_moved) " (D=$3000)" else "",
        });
        if (res.stats.offload_count != 0) {
            try out.print(
                "  S3b: {} routine(s) execute ON THE SA-1 (first: $00:{x:0>4}; {} call site(s)\n" ++
                    "  re-pointed through message-port stubs, registers marshalled via the I-RAM\n" ++
                    "  mailbox)\n",
                .{ res.stats.offload_count, res.stats.offloaded, res.stats.offload_sites },
            );
            if (res.stats.pointer_offloads != 0) {
                try out.print(
                    "  of those, {} pointer routine(s) (JSL/RTL, runtime-pointer data) run against\n" ++
                        "  an identity-offset BW-RAM shadow of their profiled working set, marshalled\n" ++
                        "  per call; their bodies are COPIES — unseen S-CPU callers see original code\n" ++
                        "  marshal: {} bytes/call both ways, {} sibling entry point(s) folded into the\n" ++
                        "  working set, within the cost budget (marshal < half the measured compute)\n",
                    .{ res.stats.pointer_offloads, res.stats.marshal_bytes, res.stats.marshal_siblings },
                );
                if (res.stats.resident_offloads != 0) try out.print(
                    "  {} of them are BW-RAM RESIDENT: their data is not marshalled at all — the\n" ++
                        "  original body's data bank is rewritten too, so both CPUs address one copy\n" ++
                        "  in BW-RAM (only the direct page is still copied, per call)\n",
                    .{res.stats.resident_offloads},
                );
                if (res.stats.async_entry != 0) try out.print(
                    "  $00:{x:0>4} runs ASYNCHRONOUSLY: its stub fires the SA-1 and returns at\n" ++
                        "  once with the caller's own registers; a fence (at the next call and in\n" ++
                        "  an injected NMI prologue) completes the handshake. Nothing is copied\n" ++
                        "  back — only its BW-RAM-resident effects survive, by contract. The\n" ++
                        "  S-CPU and SA-1 genuinely overlap — this is where the conversion stops\n" ++
                        "  paying for its offloads and starts profiting from them\n",
                    .{res.stats.async_entry},
                );
            }
        } else {
            try out.print("  S3b: no hot routine passed the offload walks; execution stays on the\n  S-CPU (relocation-only patch)\n", .{});
        }
        for (dropped, dropped_why) |d, why| {
            try out.print("  auto-bisect: offload $00:{x:0>4} DROPPED — with it, verification {s}\n", .{ d, why });
        }
    }
    switch (tier) {
        .strict => try out.print(
            "  verified: IDENTICAL — {} frames pixel- and audio-identical (no timing shift)\n",
            .{total},
        ),
        .envelope => try out.print(
            \\  verified: FRAMES IDENTICAL — every one of {} frames pixel-identical; the
            \\  audio stream is phase-shifted (relocated access timing slides the APU
            \\  handshake by a sample) but its per-frame envelope matches: the same sounds
            \\  at the same frames. Sample-exactness is the one thing left UNVERIFIED.
            \\
        , .{total}),
        .equivalent => try out.print(
            \\  verified: EQUIVALENT MODULO TIMING — the same distinct pictures in the same
            \\  order, redistributed across {} frames (a speedup's exact signature); audio
            \\  equivalence is not checkable across a timing shift and goes UNVERIFIED
            \\
        , .{total}),
        .behavioral => try out.print(
            \\  verified: BEHAVIORALLY EQUIVALENT — the game's logic state matches at every
            \\  logic tick over {} frames (compared on the bytes the original actually
            \\  consumes, wherever the conversion relocated them; residual divergence was
            \\  wall-time echoes that self-heal). Pixels, audio, and wall timing change BY
            \\  DESIGN in a slowdown-removing conversion and go UNVERIFIED — eyeball a run.
            \\
        , .{total}),
    }
    try out.print(
        "  measured: dropped frames {} -> {}, mean utilisation {d:.0}% -> {d:.0}%\n",
        .{ sum.lag_frames, conv_sum.lag_frames, sum.mean_util * 100, conv_sum.mean_util * 100 },
    );
    try out.print(
        \\  caveat: code the profile never executed is invisible to the rewriter; a longer
        \\  or more varied capture widens coverage.
        \\
    , .{});
    try printCoverage(out, cov_total, cov_late, total);
    try out.flush();
}

/// Report the capture's coverage and, more usefully, whether it had
/// stopped growing. New instructions still appearing in the last tenth of
/// a run mean the profile had not settled — so whatever the rewriter did,
/// it did on partial evidence.
/// The conversion audit (`--audit`): what the rewriter did with every
/// memory-touching site it saw, and — the part that matters — what it left
/// alone and why.
///
/// The point is a DENOMINATOR. Until this existed, unconverted sites were
/// discovered by playing the game until something broke: twelve of them
/// turned up that way, and the laser bug lived among them for a week. A
/// census does not prove the conversion correct — it cannot, because the
/// hard question is which home an operand addresses at run time and that is
/// not a static property — but it turns "what else is broken?" from a QA
/// lottery into a list with a length.
pub fn printAudit(
    out: *std.Io.Writer,
    image: []const u8,
    ub: []const u8,
    res: *const core.sa1gen.Result,
) !void {
    const V = core.sa1gen.Verdict;
    const a = &res.audit;

    try out.print("\nCONVERSION AUDIT\n", .{});

    // --- reach: how much of the ROM the rewriter can even see ----------
    const dyn = core.usage_map.countOpcodes(ub);
    try out.print(
        "\n  reach: {} instruction(s) executed while profiling",
        .{dyn},
    );
    if (res.stats.cov_static_added != 0)
        try out.print(", + {} found by static\n  descent (--wg-static)", .{res.stats.cov_static_added})
    else
        try out.print("\n  (--wg-static NOT used: code the profile never ran was never rewritten)", .{});
    try out.print("\n", .{});

    // Per bank: instructions seen against bytes that are not blank fill.
    // A bank with content and no coverage is either graphics or code
    // nobody has played into — this cannot tell which, and says so.
    // A bank the descent never entered is a problem only if it holds CODE,
    // and "looks like code" is exactly the judgement a disassembler cannot
    // make on a ROM with no markers. So do not judge it — measure three
    // independent signals and print them side by side:
    //
    //   seen      instructions the rewriter has in hand
    //   calls     JSL/JML sites in seen code naming this bank as a TARGET
    //   data      long accesses and block moves in seen code naming it as
    //             a SOURCE or destination — positive evidence of data
    //   density   how often this bank's bytes are the opcodes that
    //             dominate real 65816 code, against the two banks known to
    //             be code as the yardstick
    //
    // A bank with no coverage, no calls, plenty of data references and a
    // density a third of the code banks' is data, and the report should
    // say so rather than raise an alarm it cannot substantiate.
    const codey = [_]u8{ 0x60, 0x6B, 0x20, 0x22, 0xA9, 0x85, 0xAD, 0x8D };
    try out.print("\n  per bank — ran / seen / calls-in / data-refs / density / non-blank:\n", .{});
    var bank: u32 = 0;
    var suspect: u32 = 0;
    while (bank * 0x8000 < image.len) : (bank += 1) {
        var ran: u32 = 0;
        var a16: u32 = 0x8000;
        while (a16 < 0x10000) : (a16 += 1) {
            const cpu = (bank << 16) | a16;
            if ((ub[cpu] | ub[0x80_0000 | cpu]) & core.usage_map.flag_opcode != 0) ran += 1;
        }
        const seen = res.audit.bank_ops[bank];
        const lo = bank * 0x8000;
        const hi = @min(lo + 0x8000, image.len);
        var content: u32 = 0;
        var hits: u32 = 0;
        for (image[lo..hi]) |b| {
            content += @intFromBool(b != 0xFF and b != 0x00);
            for (codey) |c| hits += @intFromBool(b == c);
        }
        const dens: u32 = if (hi > lo) hits * 1000 / @as(u32, @intCast(hi - lo)) else 0;
        // Code-like, never entered, and nothing references it as data: the
        // only combination this report is willing to call suspicious.
        const odd = seen == 0 and content > 0x1000 and dens >= 80 and
            res.audit.bank_data[bank] == 0;
        if (odd) suspect += 1;
        try out.print("    ${x:0>2}  {d:>5} {d:>5} {d:>5} {d:>6}   .{d:0>3}  {d:>6}{s}\n", .{
            bank,                      ran,  seen,    res.audit.bank_calls[bank],
            res.audit.bank_data[bank], dens, content, if (odd) @as([]const u8, "   <-- code-like, never entered") else "",
        });
    }
    try out.print("  indirect transfers in seen code: {} JMP (abs), {} JMP/JSR (abs,X), {} JMP [abs]\n", .{
        res.audit.n_ind_abs, res.audit.n_ind_absx, res.audit.n_ind_long,
    });
    if (suspect == 0)
        try out.print("  No bank is code-like, unentered AND unreferenced as data.\n", .{})
    else
        try out.print("  {} bank(s) look like code the descent never entered — start there.\n", .{suspect});

    // --- what happened to the sites it did see -------------------------
    const rows = [_]struct { v: V, label: []const u8 }{
        .{ .v = .shifted, .label = "moved into the window (+$6000)" },
        .{ .v = .rebanked, .label = "re-banked $7E/$7F -> $40/$41" },
        .{ .v = .thunk_dbr, .label = "thunked, dispatching on the data bank" },
        .{ .v = .thunk_index, .label = "thunked, dispatching on the index" },
        .{ .v = .left_high, .label = "left: operand >= $2000 (MMIO or ROM)" },
        .{ .v = .left_rom, .label = "left: measured traffic never touched low WRAM" },
        .{ .v = .left_pinned, .label = "left: data bank statically proved BW-RAM" },
        .{ .v = .left_mixed, .label = "LEFT: measured low WRAM, but not only" },
        .{ .v = .left_unproven, .label = "LEFT: no evidence, shape not provable" },
    };
    var total: u32 = 0;
    for (rows) |r| total += a.count(r.v);
    try out.print("\n  {} memory-touching site(s) decided:\n", .{total});
    for (rows) |r| {
        const n = a.count(r.v);
        if (n == 0) continue;
        try out.print("    {d:>6}  {s}\n", .{ n, r.label });
    }

    const hazards = a.count(.left_pinned) + a.count(.left_mixed) + a.count(.left_unproven);
    if (hazards == 0) {
        try out.print("\n  No site was left addressing the abandoned home on a guess.\n", .{});
        return;
    }
    try out.print(
        "\n  {} site(s) still address the pre-conversion home. Each is a bet that\n" ++
            "  the path reaching it does not want low WRAM; `--stale` is the way to\n" ++
            "  collect the ones that lose.\n\n",
        .{hazards},
    );
    for (a.sites[0..a.n_sites]) |s| {
        const b: u32 = s.file / 0x8000;
        const a16: u32 = 0x8000 + (s.file % 0x8000);
        var ev: [4]u8 = "----".*;
        if (s.ev & core.usage_map.site_wram_low != 0) ev[0] = 'L';
        if (s.ev & core.usage_map.site_rom != 0) ev[1] = 'R';
        if (s.ev & core.usage_map.site_wram_bank != 0) ev[2] = 'B';
        if (s.ev & core.usage_map.site_other != 0) ev[3] = 'O';
        try out.print("    ${x:0>2}:{x:0>4}  op ${x:0>2}  ${x:0>4}  ev {s}  {s}\n", .{
            b, a16, s.op, s.v, &ev, @tagName(s.verdict),
        });
    }
    if (a.truncated != 0)
        try out.print("    ... and {} more (list capped)\n", .{a.truncated});
}

pub fn printCoverage(out: *std.Io.Writer, total_ops: u32, late_ops: u32, frames: u32) !void {
    const late_pct = @as(f64, @floatFromInt(late_ops)) * 100 /
        @as(f64, @floatFromInt(@max(1, total_ops)));
    try out.print("  coverage: {} instruction(s) seen executing; {} of them ({d:.1}%) first\n" ++
        "  appeared in the last tenth of {} frames", .{ total_ops, late_ops, late_pct, frames });
    // A handful of stragglers is normal — a rare branch, a one-off path.
    // The signal worth acting on is a capture that was still finding code
    // at a real rate when it ended, because then whatever the rewriter
    // did, it did on evidence that had not settled.
    if (late_pct >= coverage_unsettled_pct) {
        try out.print(" — the profile had NOT settled, so\n" ++
            "  this rests on partial evidence. Extend --frames, or drive a real playthrough\n" ++
            "  with --movie.\n", .{});
    } else {
        try out.print(": effectively settled.\n", .{});
    }
}

/// Late-discovery share above which a capture counts as unsettled. Below
/// it, the stragglers are rare branches rather than unexplored game.
pub const coverage_unsettled_pct: f64 = 1.0;

/// `--sa1-report`: run the game with the frame-budget profiler and report
/// whether it is CPU-bound.
///
/// Without `--movie` nothing presses any buttons, so what gets profiled is
/// whatever the game does on its own — the attract/demo loop for most carts, a
/// title screen for the rest. That is a real limitation and the report says so,
/// because a title screen idling at 8% utilisation is not evidence of anything.
/// A recorded playthrough is the way out: it replays real input from power-on
/// and verifies it stayed in sync, so the profile describes gameplay.
/// The SA-1 game-loop offload census (profile.Census): how much of the
/// frame the main loop's own work is — the share an offload can take off
/// the S-CPU — against the interrupt handlers' share, and every hardware
/// register the main loop touches, which is what the S-CPU would have to
/// keep doing on the SA-1's behalf.
pub fn printOffloadCensus(out: *std.Io.Writer, samples: []const profile.FrameSample, census: *const profile.Census, prof: *const profile.Profiler) !void {
    if (samples.len == 0) return;
    var int_sum: f64 = 0;
    var main_sum: f64 = 0;
    var idle_sum: f64 = 0;
    var main_max: f64 = 0;
    var int_max: f64 = 0;
    var over_alone: usize = 0; // frames the main loop's work alone would overrun
    var over_lag: usize = 0; // lag frames where the main loop, not the handler, is the bulk
    var lag_frames: usize = 0;
    var budget: f64 = 0;
    for (samples) |smp| {
        const tot: f64 = @floatFromInt(smp.work + smp.idle);
        if (tot == 0) continue;
        if (budget == 0 or tot < budget) budget = tot; // one frame's cycles (a lag frame spans more)
        const iw: f64 = @floatFromInt(smp.int_work);
        const mw: f64 = @floatFromInt(smp.main_work);
        int_sum += iw / tot;
        main_sum += mw / tot;
        idle_sum += @as(f64, @floatFromInt(smp.idle)) / tot;
        if (mw / tot > main_max) main_max = mw / tot;
        if (iw / tot > int_max) int_max = iw / tot;
        if (smp.lag) {
            lag_frames += 1;
            if (mw > iw) over_lag += 1;
        }
    }
    for (samples) |smp| if (budget != 0 and @as(f64, @floatFromInt(smp.main_work)) > budget * 0.9) {
        over_alone += 1;
    };
    const n: f64 = @floatFromInt(samples.len);
    try out.print("\n  SA-1 offload census (main loop vs interrupt handlers)\n", .{});
    try out.print("    frame time        main-loop work {d:.0}% (max {d:.0}%)   NMI/IRQ work {d:.0}% (max {d:.0}%)   idle {d:.0}%\n", .{
        main_sum / n * 100, main_max * 100, int_sum / n * 100, int_max * 100, idle_sum / n * 100,
    });
    try out.print("    lag frames        {} — in {} of them the main loop, not the handler, is the larger share\n", .{ lag_frames, over_lag });
    try out.print("    main loop > 90% of a frame by itself: {} frame(s)\n", .{over_alone});
    // Register census, per context.
    const names = [_][]const u8{ "main loop", "interrupt handlers" };
    for (0..2) |c| {
        var total: u64 = 0;
        var by_class: [7]u64 = @splat(0);
        var distinct: usize = 0;
        for (census.count[c], 0..) |cnt, b| {
            if (cnt == 0) continue;
            total += cnt;
            distinct += 1;
            by_class[@intFromEnum(profile.Census.classOf(profile.Census.regOf(b)))] += cnt;
        }
        try out.print("    {s}: {d:.1} register touches per frame over {} distinct register(s) — ppu {d:.1}  apu {d:.1}  wram-port {d:.1}  dma {d:.1}  cpu {d:.1}  joypad {d:.1}  mul/div {d:.1}\n", .{
            names[c],
            @as(f64, @floatFromInt(total)) / n,
            distinct,
            @as(f64, @floatFromInt(by_class[0])) / n,
            @as(f64, @floatFromInt(by_class[1])) / n,
            @as(f64, @floatFromInt(by_class[2])) / n,
            @as(f64, @floatFromInt(by_class[3])) / n,
            @as(f64, @floatFromInt(by_class[4])) / n,
            @as(f64, @floatFromInt(by_class[5])) / n,
            @as(f64, @floatFromInt(by_class[6])) / n,
        });
        // The heaviest registers, with the sites that touch them.
        var shown: usize = 0;
        var used: [profile.Census.buckets]bool = @splat(false);
        while (shown < 20) : (shown += 1) {
            var best: ?usize = null;
            for (census.count[c], 0..) |cnt, b| {
                if (cnt == 0 or used[b]) continue;
                if (best == null or cnt > census.count[c][best.?]) best = b;
            }
            const b = best orelse break;
            used[b] = true;
            const reg = profile.Census.regOf(b);
            try out.print("      ${X:0>4} {s:<9} {d:>9.2}/frame  from", .{ reg, @tagName(profile.Census.classOf(reg)), @as(f64, @floatFromInt(census.count[c][b])) / n });
            for (census.pcs[c][b][0..census.n_pcs[c][b]]) |q| try out.print(" ${X:0>2}:{X:0>4}", .{ q >> 16, q & 0xFFFF });
            if (census.n_pcs[c][b] == profile.Census.pcs_cap) try out.print(" ...", .{});
            try out.print("\n", .{});
        }
    }

    // --- what the mainloop split would need, from the census -----------
    // IO routines: every main-loop routine that touches the APU, the
    // PPU, the WRAM port or the DMA unit. Deferred (`:d`) when any of
    // its touches are READS — a handshake spins forever on the SA-1's
    // open bus; RTL-shaped (`:l`) when it was JSL-called. Mirror ranges:
    // the main-loop sites reading $4212 or the joypad, a window each.
    var ents: [64]u24 = undefined;
    var ent_read: [64]bool = undefined;
    var n_ents: usize = 0;
    for (census.count[0], 0..) |cnt, b| {
        if (cnt == 0) continue;
        const cls = profile.Census.classOf(profile.Census.regOf(b));
        if (cls == .math or cls == .cpu or cls == .joypad) continue;
        const is_read = census.writes[0][b] < cnt;
        for (census.entries[0][b][0..census.n_pcs[0][b]]) |e| {
            if (e == 0) continue;
            var k: usize = 0;
            while (k < n_ents and ents[k] != e) : (k += 1) {}
            if (k == n_ents) {
                if (n_ents == ents.len) break;
                ents[n_ents] = e;
                ent_read[n_ents] = false;
                n_ents += 1;
            }
            if (is_read) ent_read[k] = true;
        }
    }
    if (n_ents != 0) {
        try out.print("    split IO routines (main-loop routines touching hardware; :d = has reads, :l = JSL-called):\n", .{});
        for (ents[0..n_ents], 0..) |e, k| {
            const rtl = if (prof.routineInfo(e)) |r| r.rtl_calls * 2 > r.calls else false;
            // Deferred when the routine READS hardware (a handshake) or WRITES
            // WRAM (a body run on both CPUs would advance that state twice).
            const wram_w = if (prof.routineInfo(e)) |r| r.writes_wram else false;
            try out.print("      --wg-split-io {X:0>6}{s}{s}", .{ e, if (ent_read[k] or wram_w) ":d" else "", if (rtl) ":l" else "" });
            if (prof.routineInfo(e)) |r| {
                try out.print("   ({} calls, regs", .{r.calls});
                for (r.mmio_regs[0..r.n_mmio_regs]) |reg| try out.print(" ${X:0>4}", .{reg});
                try out.print(")", .{});
            }
            try out.print("\n", .{});
        }
    }
    var n_vbl: usize = 0;
    var vbl_seen: [32]u24 = undefined;
    for (census.count[0], 0..) |cnt, b| {
        if (cnt == 0) continue;
        const reg = profile.Census.regOf(b);
        if (reg != 0x4212 and !(reg >= 0x4218 and reg <= 0x421F)) continue;
        for (census.pcs[0][b][0..census.n_pcs[0][b]]) |pc| {
            const win: u24 = pc & 0xFFFFC0;
            var dup = false;
            for (vbl_seen[0..n_vbl]) |v| if (v == win) {
                dup = true;
            };
            if (dup or n_vbl == vbl_seen.len) continue;
            vbl_seen[n_vbl] = win;
            n_vbl += 1;
            if (n_vbl == 1) try out.print("    split mirror ranges (main-loop $4212 / joypad readers, a 64-byte window each — widen to the routine):\n", .{});
            try out.print("      --wg-split-vbl {X:0>6}-{X:0>6}\n", .{ win, win + 0x40 });
        }
    }
}

pub fn runReport(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    args: Args,
    cart: core.Cartridge,
    mov: ?util.movie.Movie,
) !void {
    const want = args.frames orelse if (mov != null)
        @max(1, @as(u32, @intCast(util.movie.Feed.budget(mov))) -| args.skip)
    else
        report_frames_default;

    const con = try gpa.create(core.ProfilingConsole);
    con.init(cart);
    if (args.auto_fastrom) con.bus.enableAutoFastrom();
    if (args.state) |spath| try loadStateInto(io, gpa, out, con, spath);
    try applyStartSave(io, gpa, con, args, mov, out);
    try anchorMovie(con, mov, "movie", out);

    // Coverage wants the boot code too, so the map is attached before the
    // skipped frames run, not after.
    var umap: core.usage_map.UsageMap = undefined;
    if (args.usage_map_out != null or args.call_graph_out != null) {
        const bytes = try gpa.alloc(u8, core.usage_map.cpu_map_len);
        @memset(bytes, 0);
        umap = .{ .bytes = bytes };
        con.usage = &umap;
    }

    var samples: std.array_list.Managed(profile.FrameSample) = .init(gpa);
    try samples.ensureTotalCapacity(want);
    con.prof.census_on = true;

    var drain: [4096]i16 = undefined;
    var feed: util.movie.Feed = .init(mov);
    for (0..args.skip + want) |i| {
        feed.step(con, i);
        con.runFrame();
        while (con.readAudio(&drain) != 0) {} // keep the ring from backing up
        const s = con.takeProfile() orelse continue;
        if (i >= args.skip) samples.appendAssumeCapacity(s);
    }

    if (args.call_graph_out) |path| {
        var seeds: std.array_list.Managed(u24) = .init(gpa);
        defer seeds.deinit();
        for (&con.prof.routines) |*r| {
            if (r.entry == profile.Routine.empty) continue;
            try seeds.append(@intCast(r.entry & 0xFF_FFFF));
        }
        var g = try core.callgraph.analyze(gpa, cart.rom, umap.bytes, seeds.items);
        defer g.deinit();

        // Ranked by complexity: the routines whose bodies branch the most are
        // where the frame goes and where a verbatim copy is hardest to prove.
        const by_cx = try gpa.dupe(core.callgraph.Node, g.nodes);
        defer gpa.free(by_cx);
        std.mem.sort(core.callgraph.Node, by_cx, {}, struct {
            pub fn lt(_: void, x: core.callgraph.Node, y: core.callgraph.Node) bool {
                return x.complexity() > y.complexity();
            }
        }.lt);
        try out.print("\n  call graph: {d} routine(s), {d} edge(s), {d} unresolved dispatch site(s)\n", .{ g.nodes.len, g.edges.len, g.unresolved });
        try out.print("    entry     bytes  cx  callers  calls  indirect\n", .{});
        var shown: usize = 0;
        for (by_cx) |n| {
            if (n.instrs == 0) continue;
            if (shown == 16) break;
            shown += 1;
            try out.print("    ${x:0>6}  {d:>6}  {d:>3}  {d:>7}  {d:>5}  {d:>8}\n", .{ n.entry, n.bytes, n.complexity(), n.callers, n.calls_out, n.indirect });
        }
        // Every routine, tab-separated, for whatever wants to sort it.
        var tsv: std.array_list.Managed(u8) = .init(gpa);
        defer tsv.deinit();
        try tsv.appendSlice("entry\tbytes\tinstrs\tcomplexity\tcallers\tcalls_out\tindirect\n");
        for (g.nodes) |n| {
            if (n.instrs == 0) continue;
            const line = try std.fmt.allocPrint(gpa, "{x:0>6}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
                n.entry, n.bytes, n.instrs, n.complexity(), n.callers, n.calls_out, n.indirect,
            });
            defer gpa.free(line);
            try tsv.appendSlice(line);
        }
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = tsv.items }) catch {
            try out.print("error: cannot write '{s}'\n", .{path});
            try out.flush();
            std.process.exit(1);
        };
        try out.print("  wrote {s}\n", .{path});
        try out.flush();
    }

    if (args.usage_map_out) |path| {
        writeUsageMap(io, path, umap.bytes, con.cart.chip) catch {
            try out.print("error: cannot write '{s}'\n", .{path});
            try out.flush();
            std.process.exit(1);
        };
        const extra: usize = switch (con.cart.chip) {
            .sa1 => 1 << 24,
            .superfx => 1 << 23,
            else => 0,
        };
        try out.print(
            "wrote {s} ({d:.1} MiB — S-CPU block recorded, SMP{s} zero-filled; " ++
                "bsnes-plus -usage.bin layout, DiztinGUIsh-importable)\n",
            .{
                path,
                @as(f64, @floatFromInt(core.usage_map.cpu_map_len + core.usage_map.smp_map_len + extra)) / (1024 * 1024),
                switch (con.cart.chip) {
                    .sa1 => " and SA-1 blocks",
                    .superfx => " and Super FX blocks",
                    else => " block",
                },
            },
        );
    }

    const scratch = try gpa.alloc(f64, samples.items.len);
    const sum = profile.summarise(samples.items, scratch);

    const h = &con.cart.header;
    const chip = @tagName(con.cart.chip);
    const map = @tagName(h.mapping);
    const title = std.mem.trim(u8, &h.title, " \x00");

    if (args.json) {
        try out.print(
            // `std.json.fmt` emits the surrounding quotes itself.
            "{{\"rom\":{f},\"title\":{f},\"map\":\"{s}\",\"chip\":\"{s}\"," ++
                "\"fastrom\":{},\"frames\":{}," ++
                "\"slow_frames\":{},\"slow_ratio\":{d:.4}," ++
                "\"stall_frames\":{},\"stalls\":{}," ++
                "\"longest_stall\":{},\"longest_stall_at\":{}," ++
                "\"mean_util\":{d:.4},\"median_util\":{d:.4},\"p95_util\":{d:.4}," ++
                "\"max_util\":{d:.4},\"verdict\":\"{s}\"",
            .{
                std.json.fmt(args.rom, .{}), std.json.fmt(title, .{}),
                map,                         chip,
                h.fastRom(),                 sum.frames,
                sum.slow_frames,             sum.slowRatio(),
                sum.stall_frames,            sum.stalls,
                sum.longest_stall,           sum.longest_stall_at,
                sum.mean_util,               sum.median_util,
                sum.p95_util,                sum.max_util,
                @tagName(sum.verdict),
            },
        );
        {
            const c = profile.assessConversion(&con.prof, sum.verdict);
            try out.print(
                ",\"conversion\":{{\"warranted\":{},\"concentrated\":{},\"covered\":{d:.4}," ++
                    "\"slow_work\":{},\"main_share\":{d:.4},\"wram_min\":{},\"wram_max\":{}," ++
                    "\"wram_exact\":{},\"pages\":{},\"fits_iram\":{},\"fits_bwram\":{}," ++
                    "\"shared_pages\":{},\"mmio\":{},\"wram_dma\":{},\"entries\":[",
                .{
                    c.warranted,      c.concentrated, c.covered,
                    c.slow_work,      c.main_share,   c.wram.min_bytes,
                    c.wram.max_bytes, c.wram.exact,   c.pages,
                    c.fits_iram,      c.fits_bwram,   c.shared_pages,
                    c.mmio_regs,      c.wram_dma,
                },
            );
            for (c.entries[0..c.n], 0..) |e, i| {
                if (i != 0) try out.print(",", .{});
                try out.print("\"{x:0>2}:{x:0>4}\"", .{ e >> 16, e & 0xFFFF });
            }
            try out.print("]}}", .{});
            if (args.plan) {
                const plan = profile.planRelocation(&con.prof, c);
                try out.print(",\"plan\":{{\"viable\":{},\"iram_used\":{},\"bwram_used\":{}," ++
                    "\"has_dp\":{},\"overflow\":{},\"regions\":[", .{
                    plan.viable, plan.iram_used,       plan.bwram_used,
                    plan.has_dp, plan.region_overflow,
                });
                for (plan.regions[0..plan.n], 0..) |r, ri| {
                    if (ri != 0) try out.print(",", .{});
                    try out.print(
                        "{{\"start\":{},\"len\":{},\"exact\":{},\"heat\":{},\"dest\":\"{s}\"," ++
                            "\"dest_off\":{},\"dp\":{},\"shared\":{},\"dma_fed\":{}}}",
                        .{
                            r.start, r.len,            r.exact,
                            r.heat,  @tagName(r.dest), r.dest_off,
                            r.dp,    r.shared_outside, r.dma_fed,
                        },
                    );
                }
                try out.print("]}}", .{});
            }
        }
        if (args.routines) {
            const rows = try routineRows(gpa, &con.prof);
            const total = attributedTotal(rows);
            const verdict = wramVerdict(topCodeRows(rows));
            try out.print(",\"stack_resets\":{},\"routines_dropped\":{},\"wram_verdict\":" ++
                "{{\"bytes\":{},\"pages\":{},\"fits_iram\":{},\"fits_bwram\":{}}},\"main_dma\":[", .{
                con.prof.stack_resets, con.prof.routines_dropped,
                verdict.union_bytes,   verdict.union_pages,
                verdict.fits_iram,     verdict.fits_bwram,
            });
            for (con.prof.main_dma[0..con.prof.n_main_dma], 0..) |d, di| {
                if (di != 0) try out.print(",", .{});
                try printDmaUseJson(out, d);
            }
            try out.print("],\"routines\":[", .{});
            for (rows, 0..) |r, i| {
                if (i != 0) try out.print(",", .{});
                switch (r.what) {
                    .waiting => try out.print("{{\"entry\":\"(waiting)\"", .{}),
                    .main => try out.print("{{\"entry\":\"(main)\"", .{}),
                    .code => {
                        try out.print("{{\"entry\":\"{x:0>2}:{x:0>4}\",\"kind\":\"{s}\",\"calls\":{},\"incl\":{}", .{
                            r.entry >> 16, r.entry & 0xFFFF, @tagName(r.kind), r.calls, r.incl,
                        });
                        try out.print(
                            ",\"wram_min\":{},\"wram_max\":{},\"wram_exact\":{},\"touches_sram\":{},\"shared\":{},\"mmio\":[",
                            .{ r.wram.min_bytes, r.wram.max_bytes, r.wram.exact, r.touches_sram, wramShared(rows, i) },
                        );
                        for (r.mmio_regs, 0..) |reg, mi| {
                            if (mi != 0) try out.print(",", .{});
                            try out.print("\"${x:0>4}\"", .{reg});
                        }
                        try out.print("],\"dma\":[", .{});
                        for (r.dma, 0..) |d, di| {
                            if (di != 0) try out.print(",", .{});
                            try printDmaUseJson(out, d);
                        }
                        try out.print("]", .{});
                    },
                }
                try out.print(",\"self\":{},\"self_pct\":{d:.4},\"slow\":{}}}", .{
                    r.self, pct(r.self, total), r.slow,
                });
            }
            try out.print("]", .{});
        }
        try out.print("}}\n", .{});
        try out.flush();
        return;
    }

    const seconds = @as(f64, @floatFromInt(sum.frames)) / 60.0;
    try out.print("{s}\n", .{title});
    try out.print("  {s}, {s}, {s}\n", .{
        map,
        if (con.cart.chip == .none) "no coprocessor" else chip,
        if (h.fastRom()) "FastROM" else "SlowROM",
    });
    try out.print("  profiled {} frames ({d:.0}s) after {} boot frames\n\n", .{
        sum.frames, seconds, args.skip,
    });

    try out.print("  CPU utilisation   mean {d:.0}%   median {d:.0}%   p95 {d:.0}%   max {d:.0}%\n", .{
        sum.mean_util * 100, sum.median_util * 100, sum.p95_util * 100, sum.max_util * 100,
    });
    try out.print("  slowdown          {} of {} frames ({d:.1}%)\n", .{
        sum.slow_frames, sum.frames, sum.slowRatio() * 100,
    });
    if (sum.n_slow_runs > 0) {
        try out.print("    at frame(s):", .{});
        for (sum.slow_runs[0..sum.n_slow_runs]) |r| try out.print(" {}(x{})", .{ r.start, r.len });
        try out.print("\n", .{});
    }
    if (sum.stalls > 0) {
        try out.print("  stalls            {} ({} frames) — loads or transitions, not slowdown\n", .{
            sum.stalls, sum.stall_frames,
        });
        try out.print("  longest           {} frames, from frame {}\n", .{
            sum.longest_stall, sum.longest_stall_at,
        });
    }

    try printOffloadCensus(out, samples.items, &con.prof.census, &con.prof);

    try out.print("\n  verdict: {s}\n", .{sum.verdict.describe()});
    switch (sum.verdict) {
        .not_cpu_bound => try out.print(
            \\    The CPU idles through {d:.0}% of an average frame and never falls behind.
            \\    A faster CPU has nothing to do here.
            \\
        , .{(1 - sum.mean_util) * 100}),
        .at_the_limit => try out.print(
            \\    Never falls behind, but its 95th-percentile frame is {d:.0}% busy: there is
            \\    nothing left over. Not slow today; the first thing that would break if
            \\    anything were added to it.
            \\
        , .{sum.p95_util * 100}),
        .drops_frames => try out.print(
            \\    Loses {d:.1}% of its frames to slowdown — occasional, not constant.
            \\    Worth finding out where before drawing any conclusion.
            \\
        , .{sum.slowRatio() * 100}),
        .saturated => try out.print(
            \\    Its MEDIAN frame is {d:.0}% busy, yet it loses only {d:.1}% of its frames to
            \\    slowdown: this game is not trying to hit 60. It renders on its own slower
            \\    schedule, so it cannot miss a deadline it never set — which is why a
            \\    dropped-frame count understates it. A faster CPU would not remove
            \\    slowdown here; it would raise the frame rate.
            \\
        , .{ sum.median_util * 100, sum.slowRatio() * 100 }),
        .cpu_bound => try out.print(
            \\    Loses {d:.1}% of its frames to slowdown, spread through the capture rather
            \\    than bunched into loads. This is a game genuinely short of CPU, and the
            \\    kind a conversion exists for.
            \\
        , .{sum.slowRatio() * 100}),
        .no_signal => try out.print(
            \\    The game never read the controller — not in one of {} frames. It has not
            \\    finished booting, or it is sitting on something that does not poll, or it
            \\    has hung. Every frame looks dropped and none of them mean anything, so
            \\    there is no verdict to give. Try a longer --skip.
            \\
        , .{sum.frames}),
    }

    const conv = profile.assessConversion(&con.prof, sum.verdict);
    try printConversion(out, conv);
    if (args.plan) try printPlan(out, profile.planRelocation(&con.prof, conv));

    if (args.hot) {
        // Where every cycle went, loop or not.
        const Page = struct { pc: u32, cycles: u64 };
        var pages: std.array_list.Managed(Page) = .init(gpa);
        for (con.prof.pages, 0..) |c, i| {
            if (c != 0) try pages.append(.{ .pc = @intCast(i << 8), .cycles = c });
        }
        std.mem.sort(Page, pages.items, {}, struct {
            pub fn gt(_: void, a: Page, b: Page) bool {
                return a.cycles > b.cycles;
            }
        }.gt);
        var total: u64 = 0;
        for (pages.items) |e| total += e.cycles;
        try out.print("\n  hottest 256-byte pages ({} distinct, {} cycles total)\n", .{ pages.items.len, total });
        for (pages.items[0..@min(12, pages.items.len)]) |e| {
            try out.print("     ${x:0>6}   {d:>14}  {d:>5.1}%\n", .{
                e.pc, e.cycles, @as(f64, @floatFromInt(e.cycles)) * 100 / @as(f64, @floatFromInt(total)),
            });
        }

        var hot: [profile.hot_slots]profile.Hot = con.prof.hot;
        std.mem.sort(profile.Hot, &hot, {}, struct {
            pub fn gt(_: void, a: profile.Hot, b: profile.Hot) bool {
                return a.cycles > b.cycles;
            }
        }.gt);
        try out.print("\n  hottest loops (>= {} revisits)\n", .{profile.min_iters});
        try out.print("     {s:<10} {s:>14} {s:>13} {s:>10}  {s}\n", .{ "pc", "cycles", "instructions", "entries", "counted as" });
        for (hot[0..@min(12, hot.len)]) |e| {
            if (e.pc == profile.Hot.empty or e.cycles == 0) break;
            try out.print("     ${x:0>6}   {d:>14} {d:>13} {d:>10}  {s}\n", .{
                e.pc, e.cycles, e.iters, e.hits, if (e.idle) "idle" else "WORK",
            });
        }
    }

    if (args.routines) {
        // Step two: where the frame goes, routine by routine. "(waiting)" is
        // every cycle the wait classifier called idle — kept out of the code
        // rows so the ranking shows work, which is what a conversion moves.
        // "(main)" is code running under no call frame at all.
        const rows = try routineRows(gpa, &con.prof);
        const total = attributedTotal(rows);
        var shown: usize = 0;
        for (rows) |r| shown += @intFromBool(r.what == .code);
        try out.print("\n  routines ({} named; showing the top {} by self time)\n", .{
            shown, @min(rows.len, routine_rows_shown),
        });
        try out.print("     {s:<10} {s:>9} {s:>14} {s:>7} {s:>7} {s:>7}  {s}\n", .{
            "entry", "calls", "self cycles", "self%", "incl%", "slow%", "",
        });
        for (rows[0..@min(rows.len, routine_rows_shown)], 0..) |r, i| {
            switch (r.what) {
                .waiting => try out.print("     {s:<10} {s:>9} {d:>14} {d:>6.1}% {s:>7} {d:>6.1}%\n", .{
                    "(waiting)", "-", r.self, pct(r.self, total), "-", pct(r.slow, r.self),
                }),
                .main => {
                    try out.print("     {s:<10} {s:>9} {d:>14} {d:>6.1}% {s:>7} {d:>6.1}%\n", .{
                        "(main)", "-", r.self, pct(r.self, total), "-", pct(r.slow, r.self),
                    });
                    for (con.prof.main_dma[0..con.prof.n_main_dma]) |d| {
                        try out.print("                dma  ", .{});
                        try printDmaUse(out, d);
                        try out.print("\n", .{});
                    }
                },
                .code => {
                    try out.print("     ${x:0>2}:{x:0>4}   {d:>9} {d:>14} {d:>6.1}% {d:>6.1}% {d:>6.1}%  {s}\n", .{
                        r.entry >> 16,       r.entry & 0xFFFF,
                        r.calls,             r.self,
                        pct(r.self, total),  pct(r.incl, total),
                        pct(r.slow, r.self), if (r.kind == .code) "" else @tagName(r.kind),
                    });
                    // Step three: what it would cost to move — its WRAM
                    // footprint (must relocate), MMIO it cannot reach from
                    // the SA-1, and whether another top routine shares its
                    // WRAM (moving one would strand the other).
                    try out.print("                wram ", .{});
                    try printWramFootprint(out, r.wram);
                    if (r.touches_sram) try out.print("  bw-ram/sram", .{});
                    if (wramShared(rows, i)) try out.print("  SHARED", .{});
                    if (r.mmio_regs.len > 0) {
                        try out.print("  mmio", .{});
                        for (r.mmio_regs, 0..) |reg, mi| {
                            if (mi == 6) {
                                try out.print(" +{} more", .{r.mmio_regs.len - mi});
                                break;
                            }
                            try out.print(" ${x:0>4}", .{reg});
                        }
                    }
                    try out.print("\n", .{});
                    // The DMA it arms: a WRAM-sourced transfer is a blocker —
                    // relocate the state and the transfer ships garbage
                    // unless it is re-sourced or proxied.
                    for (r.dma) |d| {
                        try out.print("                dma  ", .{});
                        try printDmaUse(out, d);
                        try out.print("\n", .{});
                    }
                    if (r.dma_overflow)
                        try out.print("                dma  (more channel uses than the {} tracked)\n", .{profile.dma_use_cap});
                },
            }
        }
        if (con.prof.stack_resets != 0 or con.prof.routines_dropped != 0) {
            try out.print("     ({} stack resets; {} cycles in dropped routines)\n", .{
                con.prof.stack_resets, con.prof.routines_dropped,
            });
        }
        if (!con.prof.attributionBalanced()) {
            try out.print("     WARNING: attribution imbalance — the table does not sum to work+idle (bug)\n", .{});
        }

        const verdict = wramVerdict(topCodeRows(rows));
        try out.print("\n  WRAM working set of the top routines: ", .{});
        if (verdict.union_pages == 0) {
            try out.print("none recorded (no WRAM access seen in the top routines)\n", .{});
        } else {
            try printByteCount(out, verdict.union_bytes);
            try out.print(" across {} page(s) of {} — ", .{ verdict.union_pages, profile.wram_page_count });
            if (verdict.fits_iram) {
                try out.print("fits I-RAM (2 KiB): a conversion has somewhere to put it.\n", .{});
            } else if (verdict.fits_bwram) {
                try out.print("too big for I-RAM (2 KiB) but fits cartridge BW-RAM (256 KiB).\n", .{});
            } else {
                try out.print("exceeds even BW-RAM (256 KiB) — would not fit as a straight port.\n", .{});
            }
            try out.print(
                \\    (page-granularity upper bound: a touched 256-byte page counts as fully
                \\    used even if only one byte of it is. SHARED above names the blocker —
                \\    moving that routine strands whichever other one shares its page.)
                \\
            , .{});
        }
    }

    // Everything a reader could over-trust, said out loud. What drove the run
    // is the first thing a reader needs, because every number below is a
    // number *about that run* — a demo loop, a chosen moment, and a recorded
    // playthrough are three different games as far as the frame budget cares.
    if (args.n_movies != 0) {
        try out.print(
            \\
            \\  Replayed {s} — real recorded input, so this is gameplay rather than a demo.
            \\
        , .{args.movies[0]});
    } else {
        try out.print(
            \\
            \\  Measured from the game's own attract/demo loop — no buttons were pressed.
            \\
        , .{});
    }
    try out.print(
        \\  Idle is WAI plus loops that change nothing, so a wait this misses reads as
        \\  work: utilisation is an UPPER bound. A game that polls the pad in its NMI
        \\  handler never registers a dropped frame at all, so slowdown is a LOWER
        \\  bound. The two errors bracket the truth; they do not compound.
        \\
    , .{});
    try out.flush();
}

pub var routine_rows_shown: usize = 16;

/// Write a usage map in bsnes-plus's `-usage.bin` layout: the CPU block
/// verbatim, then a zero-filled SMP block, then a zero-filled coprocessor
/// block when the cart carries one (SA-1: 16 MiB, Super FX: 8 MiB) — so the
/// byte layout matches what bsnes-plus writes for the same cart and existing
/// importers need no special-casing.
pub fn writeUsageMap(io: std.Io, path: []const u8, cpu: []const u8, chip: core.cartridge.ChipKind) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    const wr = &fw.interface;

    try wr.writeAll(cpu);
    const zeros: [4096]u8 = @splat(0);
    var left: usize = core.usage_map.smp_map_len + @as(usize, switch (chip) {
        .sa1 => 1 << 24,
        .superfx => 1 << 23,
        else => 0,
    });
    while (left != 0) {
        const n = @min(left, zeros.len);
        try wr.writeAll(zeros[0..n]);
        left -= n;
    }
    try wr.flush();
}

test "usage-map file layout: block sizes per chip, CPU bytes verbatim" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const root = ".usage-map-test-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const cpu = try gpa.alloc(u8, core.usage_map.cpu_map_len);
    defer gpa.free(cpu);
    @memset(cpu, 0);
    cpu[0x00_8000] = core.usage_map.flag_opcode | core.usage_map.flag_exec;
    cpu[0xFF_FFFF] = core.usage_map.flag_read;

    // A plain cart: CPU + SMP blocks only.
    try writeUsageMap(io, root ++ "/plain-usage.bin", cpu, .none);
    const plain = try std.Io.Dir.cwd().readFileAlloc(io, root ++ "/plain-usage.bin", gpa, .limited(64 << 20));
    defer gpa.free(plain);
    try std.testing.expectEqual(core.usage_map.cpu_map_len + core.usage_map.smp_map_len, plain.len);
    try std.testing.expectEqual(cpu[0x00_8000], plain[0x00_8000]);
    try std.testing.expectEqual(cpu[0xFF_FFFF], plain[0xFF_FFFF]);
    try std.testing.expectEqual(@as(u8, 0), plain[core.usage_map.cpu_map_len]); // SMP zeros

    // A Super FX cart appends its (zero) 8 MiB block.
    try writeUsageMap(io, root ++ "/sfx-usage.bin", cpu, .superfx);
    const st = try std.Io.Dir.cwd().statFile(io, root ++ "/sfx-usage.bin", .{});
    try std.testing.expectEqual(
        @as(u64, core.usage_map.cpu_map_len + core.usage_map.smp_map_len + (1 << 23)),
        st.size,
    );
}

/// Stage S2: the relocation plan — where each region of the hot set's WRAM
/// state lands on the SA-1 side, and what each move costs.
pub fn printPlan(out: *std.Io.Writer, plan: core.profile.Plan) !void {
    if (!plan.viable) {
        try out.print("\n  relocation plan: none — the conversion verdict above gave the planner no hot set.\n", .{});
        return;
    }
    var total_heat: u64 = 0;
    for (plan.regions[0..plan.n]) |r| total_heat += r.heat;

    try out.print("\n  relocation plan (stage S2): {} region(s), I-RAM {}/{} bytes, BW-RAM ", .{
        plan.n, plan.iram_used, core.profile.iram_bytes,
    });
    try printByteCount(out, plan.bwram_used);
    if (plan.has_dp) try out.print("; SA-1 boots with D=$3000 (dp window in I-RAM)", .{});
    try out.print("\n", .{});
    try out.print("     {s:<16} {s:>6}  {s:<16} {s:>5}  {s}\n", .{ "wram", "size", "dest", "heat", "" });
    for (plan.regions[0..plan.n]) |r| {
        const bank: u32 = 0x7E + (r.start >> 16);
        const lo: u32 = r.start & 0xFFFF;
        var range_buf: [16]u8 = undefined;
        const range = if (r.len == 1)
            std.fmt.bufPrint(&range_buf, "${x:0>2}:{x:0>4}", .{ bank, lo }) catch ""
        else
            std.fmt.bufPrint(&range_buf, "${x:0>2}:{x:0>4}-{x:0>4}", .{ bank, lo, (r.start + r.len - 1) & 0xFFFF }) catch "";
        var dest_buf: [16]u8 = undefined;
        const dest = switch (r.dest) {
            .iram => std.fmt.bufPrint(&dest_buf, "I-RAM ${x:0>4}", .{0x3000 + r.dest_off}) catch "",
            .bwram => std.fmt.bufPrint(&dest_buf, "BW-RAM ${x:0>2}:{x:0>4}", .{ 0x40 + (r.dest_off >> 16), r.dest_off & 0xFFFF }) catch "",
        };
        try out.print("     {s:<16} {d:>6}  {s:<16} {d:>4.0}%  {s}{s}{s}{s}\n", .{
            range,
            r.len,
            dest,
            pct(r.heat, total_heat),
            if (r.dp) "dp " else "",
            if (r.dma_fed) "feeds-DMA " else "",
            if (r.shared_outside) "SHARED " else "",
            if (r.exact) "" else "page-bound",
        });
    }
    if (plan.region_overflow)
        try out.print("     (more regions than the {} tracked — this plan is a prefix)\n", .{core.profile.plan_region_cap});
    try out.print(
        \\    (heat is each region's share of the hot set's slow-frame work. A page-bound
        \\    row is an upper bound: the whole touched page moves. SHARED rows need the
        \\    resident side re-pointed too — I-RAM and BW-RAM are visible to both CPUs,
        \\    so sharing is rewrite work, not a refusal. feeds-DMA rows sit in BW-RAM
        \\    because a transfer's A-bus side needs a linear address.)
        \\
    , .{});
}

/// The unified `conversion:` paragraph — the report's bottom line, tying the
/// slow-frame concentration to the WRAM fit and the blockers. Graded: not
/// warranted / worth attempting (with any blockers each on their own line) /
/// warranted but diffuse.
pub fn printConversion(out: *std.Io.Writer, c: core.profile.Conversion) !void {
    if (!c.warranted) {
        try out.print("\n  conversion: not warranted — the game is not short of CPU (see the verdict above).\n", .{});
        return;
    }
    if (c.slow_work == 0 or c.n == 0) {
        try out.print(
            \\
            \\  conversion: warranted, but no slow-frame work was attributed to any routine
            \\  (all of it ran while waiting, or the capture was too short). Nothing to rank.
            \\
        , .{});
        return;
    }
    if (!c.concentrated) {
        try out.print(
            \\
            \\  conversion: warranted but diffuse — the top {} routine(s) cover only {d:.0}% of
            \\  the work in dropped frames
        , .{ c.n, c.covered * 100 });
        if (c.main_share >= 0.10) try out.print(
            \\, and {d:.0}% of it runs at the top level, under no
            \\  call frame
        , .{c.main_share * 100});
        try out.print(
            \\. There is no small set to move; this is a restructuring, not a
            \\  relocation.
            \\
        , .{});
        return;
    }

    try out.print("\n  conversion: {d:.0}% of the work in dropped frames lands in {} routine(s) (", .{
        c.covered * 100, c.n,
    });
    for (c.entries[0..c.n], 0..) |e, i| {
        if (i != 0) try out.print(", ", .{});
        try out.print("${x:0>2}:{x:0>4}", .{ e >> 16, e & 0xFFFF });
    }
    try out.print(")\n  whose combined WRAM working set is ", .{});
    if (c.pages == 0) {
        try out.print("empty (no WRAM access recorded)", .{});
    } else {
        try printWramFootprint(out, c.wram);
        try out.print(" across {} page(s)", .{c.pages});
    }
    if (c.fits_iram) {
        try out.print(" — fits I-RAM (2 KiB).\n", .{});
    } else if (c.fits_bwram) {
        try out.print(" — too big for I-RAM (2 KiB) but fits\n  cartridge BW-RAM (256 KiB).\n", .{});
    } else {
        try out.print(" — exceeds even BW-RAM (256 KiB); a straight\n  port cannot hold it.\n", .{});
    }

    var blockers = false;
    if (c.shared_pages != 0) {
        blockers = true;
        try out.print(
            "  BUT: {} WRAM page(s) of that set are shared with code that stays behind —\n" ++
                "  moving the set strands state both sides touch.\n",
            .{c.shared_pages},
        );
    }
    if (c.wram_dma) {
        blockers = true;
        try out.print(
            "  BUT: a DMA/HDMA the set arms is WRAM-sourced — relocate the state and the\n" ++
                "  transfer must be re-sourced or proxied.\n",
            .{},
        );
    }
    if (c.mmio_regs != 0) {
        try out.print("  It reaches {}{s} MMIO register(s) the SA-1 cannot touch — each access needs\n  an S-CPU stub.\n", .{
            c.mmio_regs, if (c.mmio_overflow) "+" else "",
        });
    }
    if (!c.fits_bwram) {
        try out.print("  Not worth attempting as a relocation at this size.\n", .{});
    } else if (blockers) {
        try out.print("  Worth attempting only with the blockers above priced in.\n", .{});
    } else {
        try out.print("  No page of it is shared with resident code and no DMA sources it. Worth\n  attempting.\n", .{});
    }
}

/// One DMA use as the routine table's detail line shows it, e.g.
/// `gdma ch1 $7E:2000 -> $2118 (4.0 KiB, 214 arms) WRAM` — the arrow shows
/// which side the A-bus address is; the WRAM tag is the blocker call-out.
pub fn printDmaUse(out: *std.Io.Writer, d: core.profile.DmaUse) !void {
    switch (d.kind) {
        .gdma => {
            try out.print("gdma ch{d} ${x:0>2}:{x:0>4} {s} $21{x:0>2} (", .{
                d.channel,                       d.src >> 16, d.src & 0xFFFF,
                if (d.a_is_dest) "<-" else "->", d.b_reg,
            });
            try printByteCount(out, d.bytes_max);
            try out.print(", {d} arm(s))", .{d.arms});
            if (d.src_wram) try out.print("  WRAM", .{});
        },
        .hdma => {
            try out.print("hdma ch{d} table ${x:0>2}:{x:0>4} -> $21{x:0>2} ({d} arm(s))", .{
                d.channel, d.src >> 16, d.src & 0xFFFF, d.b_reg, d.arms,
            });
            if (d.src_wram) try out.print("  WRAM TABLE", .{});
            if (d.indirect_wram) try out.print("  WRAM INDIRECT", .{});
        },
    }
}

/// The same use as a JSON object (no trailing separator).
pub fn printDmaUseJson(out: *std.Io.Writer, d: core.profile.DmaUse) !void {
    try out.print(
        "{{\"kind\":\"{s}\",\"ch\":{d},\"src\":\"{x:0>2}:{x:0>4}\",\"b_reg\":\"$21{x:0>2}\"," ++
            "\"bytes\":{d},\"a_is_dest\":{},\"arms\":{d},\"src_wram\":{},\"indirect_wram\":{}}}",
        .{
            @tagName(d.kind), d.channel, d.src >> 16,
            d.src & 0xFFFF,   d.b_reg,   d.bytes_max,
            d.a_is_dest,      d.arms,    d.src_wram,
            d.indirect_wram,
        },
    );
}

/// One row of the `--routines` table: a named routine, or one of the two
/// synthetic rows the attribution invariant needs — "(waiting)" (idle cycles,
/// wherever the wait lived) and "(main)" (code under no call frame).
pub const RoutineRow = struct {
    what: enum { code, waiting, main },
    entry: u24 = 0,
    kind: core.profile.RoutineKind = .code,
    calls: u64 = 0,
    self: u64,
    incl: u64 = 0,
    slow: u64,
    /// Step three, `.code` rows only: what its data accesses were made of.
    wram: core.profile.WramFootprint = .{ .min_bytes = 0, .max_bytes = 0, .exact = true },
    wram_pages: core.profile.WramPages = @splat(0),
    /// Slices into the profiler's own `Routine` — valid as long as `prof`
    /// (i.e. `con.prof`) outlives the report, which it does.
    mmio_regs: []const u16 = &.{},
    touches_sram: bool = false,
    /// DMA/HDMA channels this routine armed (same lifetime note).
    dma: []const core.profile.DmaUse = &.{},
    dma_overflow: bool = false,
};

/// Collect and rank every routine with self time, synthetics included.
pub fn routineRows(gpa: std.mem.Allocator, prof: *const core.profile.Profiler) ![]RoutineRow {
    var rows: std.array_list.Managed(RoutineRow) = .init(gpa);
    if (prof.waiting_self != 0)
        try rows.append(.{ .what = .waiting, .self = prof.waiting_self, .slow = prof.waiting_slow });
    if (prof.main_self != 0)
        try rows.append(.{ .what = .main, .self = prof.main_self, .slow = prof.main_slow });
    for (prof.routines, 0..) |r, i| {
        if (r.entry == core.profile.Routine.empty or r.self_cycles == 0) continue;
        try rows.append(.{
            .what = .code,
            .entry = @intCast(r.entry),
            .kind = r.kind,
            .calls = r.calls,
            .self = r.self_cycles,
            .incl = r.incl_cycles,
            .slow = r.slow_cycles,
            .wram = r.wramFootprint(),
            .wram_pages = r.wram_pages,
            .mmio_regs = prof.routines[i].mmio_regs[0..r.n_mmio_regs],
            .touches_sram = r.touches_sram,
            .dma = prof.routines[i].dma[0..r.n_dma],
            .dma_overflow = r.dma_overflow,
        });
    }
    std.mem.sort(RoutineRow, rows.items, {}, struct {
        pub fn gt(_: void, a: RoutineRow, b: RoutineRow) bool {
            return a.self > b.self;
        }
    }.gt);
    return rows.items;
}

test "routine rows carry the WRAM footprint and shared flag into the report" {
    var p: core.profile.Profiler = .init;
    const cyc: u64 = 6;
    // main -> A: touches $7E:1000.
    p.step(0x00_9000, cyc, false, null, null, .{ .kind = .call, .target = 0x00_A000, .sp_before = 0x1FF, .sp_after = 0x1FD });
    p.step(0x00_A000, cyc, false, 0x7E_1000, null, .{});
    p.step(0x00_A003, cyc, false, null, null, .{ .kind = .ret, .target = 0, .sp_before = 0x1FD, .sp_after = 0x1FF });
    // main -> B: touches $7E:1005 (same 256-byte page as A) and MMIO $4212,
    // and arms a WRAM-sourced GDMA while on top.
    p.step(0x00_9006, cyc, false, null, null, .{ .kind = .call, .target = 0x00_B000, .sp_before = 0x1FF, .sp_after = 0x1FD });
    p.step(0x00_B000, cyc, false, 0x7E_1005, null, .{});
    p.step(0x00_B003, cyc, false, 0x00_4212, null, .{});
    p.noteDmaArm(.gdma, 1, 0x7E_2000, 0x400, 0x18, false, null);
    p.step(0x00_B006, cyc, false, null, null, .{ .kind = .ret, .target = 0, .sp_before = 0x1FD, .sp_after = 0x1FF });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rows = try routineRows(arena_state.allocator(), &p);

    var a_idx: ?usize = null;
    var b_idx: ?usize = null;
    for (rows, 0..) |r, i| {
        if (r.what != .code) continue;
        if (r.entry == 0x00_A000) a_idx = i;
        if (r.entry == 0x00_B000) b_idx = i;
    }
    const a = rows[a_idx.?];
    const b = rows[b_idx.?];

    try std.testing.expect(a.wram.exact);
    try std.testing.expectEqual(@as(u32, 1), a.wram.min_bytes);
    try std.testing.expect(b.wram.exact);
    try std.testing.expectEqual(@as(u32, 1), b.wram.min_bytes);
    try std.testing.expectEqual(@as(usize, 1), b.mmio_regs.len);
    try std.testing.expectEqual(@as(u16, 0x4212), b.mmio_regs[0]);
    try std.testing.expect(!b.touches_sram);
    try std.testing.expectEqual(@as(usize, 1), b.dma.len);
    try std.testing.expect(b.dma[0].src_wram);
    try std.testing.expectEqual(@as(usize, 0), a.dma.len);

    // Same 256-byte page ($7E1000 and $7E1005): each names the other.
    try std.testing.expect(wramShared(rows, a_idx.?));
    try std.testing.expect(wramShared(rows, b_idx.?));

    const verdict = wramVerdict(topCodeRows(rows));
    try std.testing.expectEqual(@as(u32, 1), verdict.union_pages);
    try std.testing.expectEqual(@as(u32, 256), verdict.union_bytes);
    try std.testing.expect(verdict.fits_iram);
    try std.testing.expect(verdict.fits_bwram);
}

/// Sum of every row's self time == everything banked as work or idle: the
/// denominator every percentage in the table is against.
pub fn attributedTotal(rows: []const RoutineRow) u64 {
    var t: u64 = 0;
    for (rows) |r| t += r.self;
    return t;
}

pub fn pct(part: u64, whole: u64) f64 {
    if (whole == 0) return 0;
    return @as(f64, @floatFromInt(part)) * 100 / @as(f64, @floatFromInt(whole));
}

/// The `.code` rows the WRAM verdict and the report table agree on: the same
/// top `routine_rows_shown` by self time that the table prints.
pub fn topCodeRows(rows: []const RoutineRow) []const RoutineRow {
    return rows[0..@min(rows.len, routine_rows_shown)];
}

/// Does `rows[idx]` share a WRAM page with any *other* named routine in
/// `rows`? Moving one of them to the SA-1 would strand the other's state on
/// the wrong side of the bus. Checked against the full set, not just what is
/// displayed — a routine ranked outside the shown table can still be the
/// thing a displayed routine's WRAM is shared with.
pub fn wramShared(rows: []const RoutineRow, idx: usize) bool {
    if (rows[idx].what != .code) return false;
    for (rows, 0..) |other, j| {
        if (j == idx or other.what != .code) continue;
        if (core.profile.pagesOverlap(rows[idx].wram_pages, other.wram_pages)) return true;
    }
    return false;
}

/// The combined WRAM working set of a set of routines — the union of their
/// touched pages, which is what actually has to fit in I-RAM or BW-RAM once
/// they all move together. Page-granularity, so it is an upper bound: shared
/// pages are not double-counted, but a page only one byte of which is touched
/// still counts as a full 256 bytes.
pub const WramVerdict = struct {
    union_bytes: u32,
    union_pages: u32,
    fits_iram: bool,
    fits_bwram: bool,
};

pub const iram_bytes = core.profile.iram_bytes;
pub const bwram_bytes = core.profile.bwram_bytes;

pub fn wramVerdict(rows: []const RoutineRow) WramVerdict {
    var union_pages: core.profile.WramPages = @splat(0);
    for (rows) |r| {
        if (r.what != .code) continue;
        for (r.wram_pages, 0..) |w, i| union_pages[i] |= w;
    }
    const pages = core.profile.pageCount(union_pages);
    const bytes = pages * 256;
    return .{
        .union_bytes = bytes,
        .union_pages = pages,
        .fits_iram = bytes <= iram_bytes,
        .fits_bwram = bytes <= bwram_bytes,
    };
}

pub fn printByteCount(out: *std.Io.Writer, n: u32) !void {
    if (n >= 1024) {
        try out.print("{d:.1} KiB", .{@as(f64, @floatFromInt(n)) / 1024.0});
    } else {
        try out.print("{} B", .{n});
    }
}

pub fn printWramFootprint(out: *std.Io.Writer, fp: core.profile.WramFootprint) !void {
    if (fp.exact) {
        try printByteCount(out, fp.max_bytes);
    } else {
        try printByteCount(out, fp.min_bytes);
        try out.print("+ (up to ", .{});
        try printByteCount(out, fp.max_bytes);
        try out.print(")", .{});
    }
}
