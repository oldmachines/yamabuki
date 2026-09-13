//! Stage S3 of the SA-1 generation arc: the mechanical rewrite, built as the
//! two pieces that can be verified TODAY, before any code migrates between
//! CPUs.
//!
//! **The shell.** Convert a plain LoROM cart into an SA-1 cart that behaves
//! identically: header to SA-1 (chipset $35, map mode $23, BW-RAM declared),
//! an S-CPU reset shim that opens the SNES-side write gates (SIWP/SWEN),
//! boots the SA-1 through the real protocol (CRV, then releasing RESB via
//! $2200) into a park stub (SEI/STP), and continues the original game on the
//! S-CPU unchanged. The Super MMC's power-on bank map already reproduces
//! LoROM addressing for banks $00-$3F, so code and data addresses survive
//! as-is. The shell proves the cart conversion and the boot protocol under
//! the differential harness — every frame must render identically — and is
//! the platform every later migration step stands on.
//!
//! **The state relocation.** Execute stage S2's plan: rewrite every executed
//! instruction whose operand statically names a byte of a relocated WRAM
//! region to the region's new home — I-RAM (S-CPU window $3000-$37FF) or
//! BW-RAM (banks $40+). Both memories are visible to BOTH CPUs, which is the
//! trick: state can move before execution does, the game still runs entirely
//! on the S-CPU, and the differential gate proves the rewrite preserved
//! behavior. When execution later migrates (stage S3b), the state is already
//! on the SA-1's side of the wall.
//!
//! What counts as statically nameable, and what refuses — fed by the S1
//! coverage map (opcode positions and M/X widths from real execution, so the
//! walk decodes exactly the instructions that ran):
//!
//! - **long / long,X operands** naming $7E/$7F (or a bank-$00-$3F low
//!   mirror): rewritten in place, exact.
//! - **absolute operands** under $2000: the WRAM low mirror, the same byte
//!   under every system-bank DB — rewritten to the I-RAM window (also
//!   present in every system bank). A site whose region went to BW-RAM
//!   cannot be re-pointed in two bytes: the region is blocked instead.
//! - **absolute above $2000**: reaches WRAM only through DB=$7E/7F, which is
//!   invisible statically; never attributed. If the game does this at a
//!   moved region, the desync is exactly what the differential gate exists
//!   to catch.
//! - **indexed absolute / long,X** with a base inside a region: refused, and
//!   the region is blocked — an index can carry the access across the
//!   region's edge, and a moved edge is a silent corruption.
//! - **direct page**: not rewritten per site. When the plan pinned a dp
//!   window, the WHOLE first page moves as a unit and the shim boots the
//!   S-CPU with D=$3000 — every dp operand stays byte-identical. An indexed
//!   dp site (dp,X can walk past $FF) or an abs/abs,X refusal inside the
//!   window blocks the window as a unit and D stays 0.
//!
//! A blocked region simply does not move — its sites are left alone, which
//! is always correct, and the report says why. Code the profile never
//! executed is invisible to the walk; if it touches moved state the
//! differential run diverges and no patch is written. That is the standing
//! contract of the whole ladder: the rewrite may be incomplete, but it may
//! not be silently wrong.

const std = @import("std");
const header_mod = @import("header.zig");
const cartridge = @import("cartridge.zig");
const patchgen = @import("patchgen.zig");
const profile = @import("../profile.zig");
const usage_map = @import("../usage_map.zig");

// The rewrite is split into modules under sa1gen/; each is re-exported
// here so this file remains the public root and every internal name keeps
// resolving. Pure code motion — see each module's header.
const split_mod = @import("sa1gen/split.zig");
const offload_mod = @import("sa1gen/offload.zig");
const window_mod = @import("sa1gen/window.zig");
const thunks_mod = @import("sa1gen/thunks.zig");
const demirror_mod = @import("sa1gen/demirror.zig");
const supermetroid_mod = @import("sa1gen/supermetroid.zig");
const coverage_mod = @import("sa1gen/coverage.zig");

pub const cm_data = coverage_mod.cm_data;
pub const cm_interior = coverage_mod.cm_interior;
pub const cm_m8 = coverage_mod.cm_m8;
pub const cm_m_known = coverage_mod.cm_m_known;
pub const cm_start = coverage_mod.cm_start;
pub const cm_wram_pointer = coverage_mod.cm_wram_pointer;
pub const cm_x8 = coverage_mod.cm_x8;
pub const cm_x_known = coverage_mod.cm_x_known;
pub const codeMapAt = coverage_mod.codeMapAt;
pub const codeMapForbids = coverage_mod.codeMapForbids;
pub const extendCoverage = coverage_mod.extendCoverage;
pub const demirrorQueueBankImms = demirror_mod.demirrorQueueBankImms;
pub const demirrorTwinJsls = demirror_mod.demirrorTwinJsls;
pub const loromFileOffset = demirror_mod.loromFileOffset;
pub const relocateHdmaIndirect = demirror_mod.relocateHdmaIndirect;
pub const relocateWmdataFills = demirror_mod.relocateWmdataFills;
pub const Chosen = offload_mod.Chosen;
pub const OffloadKind = offload_mod.OffloadKind;
pub const PtrSpec = offload_mod.PtrSpec;
pub const Runs = offload_mod.Runs;
pub const asyncStubLen = offload_mod.asyncStubLen;
pub const bwramLive = offload_mod.bwramLive;
pub const callSites = offload_mod.callSites;
pub const countCallSites = offload_mod.countCallSites;
pub const dbg_walk_root = offload_mod.dbg_walk_root;
pub const dpMoved = offload_mod.dpMoved;
pub const dropPtr = offload_mod.dropPtr;
pub const eligibleLeaf = offload_mod.eligibleLeaf;
pub const eligiblePointer = offload_mod.eligiblePointer;
pub const emitAsyncStub = offload_mod.emitAsyncStub;
pub const emitFence = offload_mod.emitFence;
pub const emitNbFence = offload_mod.emitNbFence;
pub const emitPtrStub = offload_mod.emitPtrStub;
pub const fenceLen = offload_mod.fenceLen;
pub const fixupJmps = offload_mod.fixupJmps;
pub const iramLive = offload_mod.iramLive;
pub const iram_offload_limit = offload_mod.iram_offload_limit;
pub const jslSitesInsideTree = offload_mod.jslSitesInsideTree;
pub const mailbox = offload_mod.mailbox;
pub const marshal_budget_den = offload_mod.marshal_budget_den;
pub const marshal_budget_num = offload_mod.marshal_budget_num;
pub const mvn_cycles_per_byte = offload_mod.mvn_cycles_per_byte;
pub const namedOutside = offload_mod.namedOutside;
pub const nb_fence_len = offload_mod.nb_fence_len;
pub const offload_max = offload_mod.offload_max;
pub const pageRuns = offload_mod.pageRuns;
pub const ptrStubLen = offload_mod.ptrStubLen;
pub const ptr_db_cap = offload_mod.ptr_db_cap;
pub const ptr_pages_cap = offload_mod.ptr_pages_cap;
pub const ptr_run_cap = offload_mod.ptr_run_cap;
pub const ptr_slot_cap = offload_mod.ptr_slot_cap;
pub const ptr_tree_cap = offload_mod.ptr_tree_cap;
pub const ptr_tree_span_max = offload_mod.ptr_tree_span_max;
pub const ptr_wram_long_cap = offload_mod.ptr_wram_long_cap;
pub const put = offload_mod.put;
pub const putJsr = offload_mod.putJsr;
pub const putMvnRun = offload_mod.putMvnRun;
pub const rebaseTreeJsls = offload_mod.rebaseTreeJsls;
pub const rewriteCallSites = offload_mod.rewriteCallSites;
pub const shadow_bank = offload_mod.shadow_bank;
pub const shadow_linear = offload_mod.shadow_linear;
pub const stub_id_cmp_off = offload_mod.stub_id_cmp_off;
pub const stub_id_send_off = offload_mod.stub_id_send_off;
pub const stub_template = offload_mod.stub_template;
pub const tryOffload = offload_mod.tryOffload;
pub const walkMember = offload_mod.walkMember;
pub const Displaced = split_mod.Displaced;
pub const MathSite = split_mod.MathSite;
pub const emitSplit = split_mod.emitSplit;
pub const emitSplitIo = split_mod.emitSplitIo;
pub const emitSplitIoBanked = split_mod.emitSplitIoBanked;
pub const emitSplitMath = split_mod.emitSplitMath;
pub const emitSplitReaders = split_mod.emitSplitReaders;
pub const inlineArgs = split_mod.inlineArgs;
pub const splitAddrInImage = split_mod.splitAddrInImage;
pub const splitFile = split_mod.splitFile;
pub const splitPrefixSpan = split_mod.splitPrefixSpan;
pub const splitTargeted = split_mod.splitTargeted;
pub const splitUsage = split_mod.splitUsage;
pub const split_args = split_mod.split_args;
pub const split_asc_a = split_mod.split_asc_a;
pub const split_asc_x = split_mod.split_asc_x;
pub const split_asc_y = split_mod.split_asc_y;
pub const split_cell_a = split_mod.split_cell_a;
pub const split_cell_d = split_mod.split_cell_d;
pub const split_cell_dbr = split_mod.split_cell_dbr;
pub const split_cell_p = split_mod.split_cell_p;
pub const split_cell_pret = split_mod.split_cell_pret;
pub const split_cell_pw = split_mod.split_cell_pw;
pub const split_cell_ret = split_mod.split_cell_ret;
pub const split_cell_s = split_mod.split_cell_s;
pub const split_cell_t = split_mod.split_cell_t;
pub const split_cell_tb = split_mod.split_cell_tb;
pub const split_cell_x = split_mod.split_cell_x;
pub const split_cell_y = split_mod.split_cell_y;
pub const split_cop_dp = split_mod.split_cop_dp;
pub const split_ctx_a = split_mod.split_ctx_a;
pub const split_ctx_x = split_mod.split_ctx_x;
pub const split_ctx_y = split_mod.split_ctx_y;
pub const split_done = split_mod.split_done;
pub const split_engaged = split_mod.split_engaged;
pub const split_in_replay = split_mod.split_in_replay;
pub const split_last = split_mod.split_last;
pub const split_m7_last = split_mod.split_m7_last;
pub const split_m7_latch = split_mod.split_m7_latch;
pub const split_m7_prod = split_mod.split_m7_prod;
pub const split_m7a = split_mod.split_m7a;
pub const split_m7b = split_mod.split_m7b;
pub const split_math_a = split_mod.split_math_a;
pub const split_math_div = split_mod.split_math_div;
pub const split_math_q = split_mod.split_math_q;
pub const split_math_r = split_mod.split_math_r;
pub const split_ml_pump_stack = split_mod.split_ml_pump_stack;
pub const split_ml_sa1_stack = split_mod.split_ml_sa1_stack;
pub const split_owner = split_mod.split_owner;
pub const split_pad_mirror = split_mod.split_pad_mirror;
pub const split_pump_stack = split_mod.split_pump_stack;
pub const split_ring = split_mod.split_ring;
pub const split_ring2 = split_mod.split_ring2;
pub const split_ring2_rd = split_mod.split_ring2_rd;
pub const split_ring2_wr = split_mod.split_ring2_wr;
pub const split_ring_rd = split_mod.split_ring_rd;
pub const split_ring_wr = split_mod.split_ring_wr;
pub const split_rpc_ack = split_mod.split_rpc_ack;
pub const split_sa1_stack = split_mod.split_sa1_stack;
pub const split_scr_a = split_mod.split_scr_a;
pub const split_scr_p = split_mod.split_scr_p;
pub const split_scr_pw = split_mod.split_scr_pw;
pub const split_token = split_mod.split_token;
pub const split_vbl_mirror = split_mod.split_vbl_mirror;
pub const SmInlineDests = supermetroid_mod.SmInlineDests;
pub const SmRoomWalk = supermetroid_mod.SmRoomWalk;
pub const rebankSmAreaMapTable = supermetroid_mod.rebankSmAreaMapTable;
pub const rebankSmBgRecord = supermetroid_mod.rebankSmBgRecord;
pub const rebankSmDecompInlineDests = supermetroid_mod.rebankSmDecompInlineDests;
pub const rebankSmEnemyHeaders = supermetroid_mod.rebankSmEnemyHeaders;
pub const rebankSmPointerSeeds = supermetroid_mod.rebankSmPointerSeeds;
pub const rebankSmRoomLevelPointers = supermetroid_mod.rebankSmRoomLevelPointers;
pub const rebankSmTilesetTable = supermetroid_mod.rebankSmTilesetTable;
pub const smConditionArgBytes = supermetroid_mod.smConditionArgBytes;
pub const smLongIndirectUse = supermetroid_mod.smLongIndirectUse;
pub const sm_area_map_entries = supermetroid_mod.sm_area_map_entries;
pub const sm_area_map_lo = supermetroid_mod.sm_area_map_lo;
pub const sm_enemy_hdr_hi = supermetroid_mod.sm_enemy_hdr_hi;
pub const sm_enemy_hdr_lo = supermetroid_mod.sm_enemy_hdr_lo;
pub const sm_tileset_hi = supermetroid_mod.sm_tileset_hi;
pub const sm_tileset_lo = supermetroid_mod.sm_tileset_lo;
pub const BigRun = thunks_mod.BigRun;
pub const FarPad = thunks_mod.FarPad;
pub const PadAlloc = thunks_mod.PadAlloc;
pub const a1bThunkBody = thunks_mod.a1bThunkBody;
pub const a1b_thunk_len = thunks_mod.a1b_thunk_len;
pub const biggestRun = thunks_mod.biggestRun;
pub const coldDispatcherBody = thunks_mod.coldDispatcherBody;
pub const cold_disp_len = thunks_mod.cold_disp_len;
pub const copy_reserve = thunks_mod.copy_reserve;
pub const dasbThunkBody = thunks_mod.dasbThunkBody;
pub const dasb_thunk_len = thunks_mod.dasb_thunk_len;
pub const dbg_thunk_pad = thunks_mod.dbg_thunk_pad;
pub const far_stub_len = thunks_mod.far_stub_len;
pub const idxThunkBody = thunks_mod.idxThunkBody;
pub const idxThunkBodyShort = thunks_mod.idxThunkBodyShort;
pub const idxThunkBodyV2 = thunks_mod.idxThunkBodyV2;
pub const idxThunkBodyWrap = thunks_mod.idxThunkBodyWrap;
pub const idx_thunk_len = thunks_mod.idx_thunk_len;
pub const idx_thunk_max = thunks_mod.idx_thunk_max;
pub const idx_thunk_short_len = thunks_mod.idx_thunk_short_len;
pub const idx_thunk_v2_len = thunks_mod.idx_thunk_v2_len;
pub const idx_thunk_wrap_len = thunks_mod.idx_thunk_wrap_len;
pub const longNegThunkBody = thunks_mod.longNegThunkBody;
pub const longThunkBody = thunks_mod.longThunkBody;
pub const longThunkBodyWrap = thunks_mod.longThunkBodyWrap;
pub const long_neg_thunk_len = thunks_mod.long_neg_thunk_len;
pub const long_thunk_len = thunks_mod.long_thunk_len;
pub const long_wrap_thunk_len = thunks_mod.long_wrap_thunk_len;
pub const padAllocFor = thunks_mod.padAllocFor;
pub const placeThunk = thunks_mod.placeThunk;
pub const rebankDasbWrites = thunks_mod.rebankDasbWrites;
pub const splitThunkBody = thunks_mod.splitThunkBody;
pub const split_disp_max = thunks_mod.split_disp_max;
pub const split_thunk_len = thunks_mod.split_thunk_len;
pub const split_thunk_max = thunks_mod.split_thunk_max;
pub const win_disp_max = thunks_mod.win_disp_max;
pub const NmiSites = window_mod.NmiSites;
pub const WgIndex = window_mod.WgIndex;
pub const WgSite = window_mod.WgSite;
pub const WgSiteKind = window_mod.WgSiteKind;
pub const WinChosen = window_mod.WinChosen;
pub const WinSpec = window_mod.WinSpec;
pub const dbg_win_root = window_mod.dbg_win_root;
pub const emitWinAbort = window_mod.emitWinAbort;
pub const emitWinAsyncStub = window_mod.emitWinAsyncStub;
pub const emitWinBlock = window_mod.emitWinBlock;
pub const emitWinBusyGuard = window_mod.emitWinBusyGuard;
pub const emitWinGuard = window_mod.emitWinGuard;
pub const emitWinStub = window_mod.emitWinStub;
pub const emitWinVblankGuard = window_mod.emitWinVblankGuard;
pub const emitWindowOffloads = window_mod.emitWindowOffloads;
pub const wg_bw_window = window_mod.wg_bw_window;
pub const wg_mailbox = window_mod.wg_mailbox;
pub const wg_moves_max = window_mod.wg_moves_max;
pub const wg_sites_max = window_mod.wg_sites_max;
pub const wg_uniq_max = window_mod.wg_uniq_max;
pub const winWalkMember = window_mod.winWalkMember;
pub const win_abort_len = window_mod.win_abort_len;
pub const win_async_stub_len = window_mod.win_async_stub_len;
pub const win_block_len = window_mod.win_block_len;
pub const win_busy_guard_len = window_mod.win_busy_guard_len;
pub const win_guard_len = window_mod.win_guard_len;
pub const win_nmi_off_extra = window_mod.win_nmi_off_extra;
pub const win_nmi_thunk_len = window_mod.win_nmi_thunk_len;
pub const win_stub_len = window_mod.win_stub_len;
pub const win_vblank_guard_len = window_mod.win_vblank_guard_len;
pub const win_vblank_margin_lines = window_mod.win_vblank_margin_lines;
pub const win_watchdog_vcnt = window_mod.win_watchdog_vcnt;
pub const windowEligible = window_mod.windowEligible;

test {
    _ = split_mod;
    _ = offload_mod;
    _ = window_mod;
    _ = thunks_mod;
    _ = demirror_mod;
    _ = supermetroid_mod;
    _ = coverage_mod;
}

pub const Error = error{ OutOfMemory, NoHeader, RomTooSmall, Refused };

/// S5 — the mainline/NMI split (measured on v17: the architecture that
/// takes the bubble stage from 12.1% lag to 0.0%). The S-CPU boots the
/// game STOCK — init IO and the APU handshake stay real — and at the
/// main loop's top a displaced JML engages the split: the SA-1 enters
/// the mainline IN PLACE (both CPUs see the same post-relocation
/// bytes; its writes to $21xx/$42xx/$43xx vanish harmlessly on its own
/// bus), while the S-CPU falls into a pump loop that feeds the
/// $4212/joypad mirror cells and replays enqueued IO routines for
/// real. IO routines get a 3-byte enqueue prefix; the pump calls a
/// per-id trampoline carrying the displaced bytes, so neither path
/// needs to know which CPU it is on. The game's own vblank wait,
/// reading the mirror, becomes the frame fence.
pub const SplitIo = struct {
    /// 24-bit CPU address; bank $00 for the tail flavor, any code bank
    /// for the mainloop flavor (the stub and trampoline are placed in the
    /// entry's own bank, so its RTS-shaped return and bank-local jumps
    /// stay sound).
    entry: u24,
    /// A pure-writer body runs on BOTH CPUs (its MMIO writes vanish on
    /// the SA-1); a handshake body — one that READ-WAITS on an MMIO
    /// echo — would spin forever on SA-1 open bus, so post-engage the
    /// stub skips it and only the pump runs it. Pre-engage (the boot,
    /// which must do its IO for real) the engaged cell routes every
    /// caller through the body regardless.
    deferred: bool = false,
    /// The routine's return shape — RTL bodies are JSL-called, and the
    /// deferred skip must pop the caller's frame with the matching op.
    rtl: bool = false,
    /// Fire-and-forget: enqueued on ring 2, replayed at the mini-tok
    /// (frame exit — stock's own phase for the trailing sound call);
    /// the SA-1 does not wait. For calls whose results nothing reads.
    ff: bool = false,
};

pub const SplitSpec = struct {
    /// Bank-$00 routines the pump replays (OAM/VRAM/CGRAM/APU writers).
    /// Each gets the enqueue prefix; its first 3 bytes must be whole
    /// instructions with no branch.
    io_entries: []const SplitIo,
    /// Address ranges (24-bit) whose absolute reads of $4212 and
    /// $4218-$421F swap to the I-RAM mirrors — the mainline's vblank
    /// wait and pad reads. Boot-path readers stay native.
    vbl_ranges: []const [2]u24,
    /// Where the split engages: the main loop's top (24-bit, any bank).
    /// Its first 4 to 8 bytes must be whole flow-free instructions (a
    /// JSL is fine — it returns into the displaced copy; a JSR, branch or
    /// jump is not); the site keeps a JML and NOP fill. Ignored when
    /// `tail` is set.
    mainloop: u24 = 0,
    /// Mainloop flavor, dual image: the S-CPU instruction addresses the
    /// split's census saw run while the upper copy was mapped (the NMI and
    /// IRQ handlers, the IO bodies the pump replays, their callees), sorted.
    /// A math site outside this set is the SA-1's alone in that copy and
    /// becomes a direct I-RAM cell access — the same opcode, the cell for
    /// the register — instead of a COP (measured: the COP handler was 65%
    /// of a gameplay lap, the game itself 25%). Trigger stores (the
    /// multiplier's B, the divisor, the mode-7 inputs) keep the COP: the
    /// shadow has to compute. Empty = every site is a COP.
    shared_sites: []const u24 = &.{},
    /// NMI-TAIL flavor (the shape Gradius III actually has: the whole
    /// engine runs inside the NMI handler). `tail` is the boundary in
    /// the handler — the vblank-timed upload cluster before it stays on
    /// the S-CPU; the logic chain from it to `tail_epilogue` (the
    /// handler's pull/RTI sequence) runs on the SA-1's generated frame
    /// loop, entered through a faked handler frame so the game's own
    /// RTI returns into the loop. The S-CPU's NMI, reaching the
    /// boundary, feeds the mirrors (stock's own auto-joy wait), bumps
    /// the frame token, drains the ring, and jumps to the epilogue.
    /// `tail` must begin with a 4-byte JSL, carried whole.
    tail: u16 = 0,
    tail_epilogue: u16 = 0,
    /// The DBR the handler establishes before the boundary.
    tail_dbr: u8 = 0,
    /// Mode gate (tail flavor): dispatch the tail to the SA-1 only while
    /// the game-mode dp cell `mode_cell` (read under the pinned window D,
    /// so both CPUs see the BW-RAM home) holds `mode_value`; any other
    /// mode runs the tail nested-native on the S-CPU — the stock shape.
    /// The split exists to remove GAMEPLAY slowdown; menus, option
    /// screens and mode transitions have none, and they are exactly the
    /// eras whose producer/consumer handshakes assume one CPU (measured:
    /// the menu-entry upload burst funneled through in-NMI ring replays,
    /// starved the mainline's staging sweep mid-list, and the unterminated
    /// list wedged the options screen black — while the verified stages
    /// never touch those paths).
    /// Tail flavor: a direct-page offset. Mainloop flavor: a 16-bit
    /// low-WRAM address (read at its window home, `+$6000`, through bank
    /// $00 — both CPUs see the same BW-RAM byte); the loop belongs to the
    /// SA-1 while the cell holds `mode_value` and to the S-CPU otherwise,
    /// ownership changing hands at the anchor, once per lap at most.
    mode_cell: u16 = 0,
    mode_value: u8 = 0,
    /// Mainloop flavor: the gate accepts the whole range `mode_value ..=
    /// mode_hi` when `mode_hi` is nonzero — gameplay plus the door
    /// transitions ($08-$0C on Super Metroid), where the visible slowdown
    /// lives. Zero = the single value.
    mode_hi: u8 = 0,
    mode_gate: bool = false,
};

pub const Reason = enum {
    coprocessor,
    not_lorom,
    has_sram,
    rom_too_big,
    bwram_too_big,
    reset_vector_not_rom,
    no_free_space,
    wg_wram_beyond_iram,
    wg_mmio_shape,
    wg_mmio_outside_bank0,
    wg_uses_irq,
    wg_nmi_ambiguous,
    wg_unsupported_op,
    wg_wram_beyond_bwram,
    wg_dp_dynamic,
    wg_stack_dynamic,
    wg_blockmove_source,
    wg_split_overflow,
    wg_thunk_space,
    wg_split_shape,

    pub fn describe(self: Reason) []const u8 {
        return switch (self) {
            .coprocessor => "the cartridge already carries a coprocessor",
            .not_lorom => "only LoROM carts convert (the Super MMC's power-on map reproduces LoROM addressing)",
            .has_sram => "the cartridge has its own save RAM; relocating it is not mechanical",
            .rom_too_big => "ROM exceeds 4 MiB, the Super MMC window this conversion maps",
            .bwram_too_big => "the plan needs more BW-RAM than a cart can carry",
            .reset_vector_not_rom => "the reset vector does not point into ROM",
            .no_free_space => "no padding run in bank $00 is large enough for the boot shim",
            .wg_wram_beyond_iram => "whole-game migration needs the WRAM working set inside $0000-$07FF (the SA-1's identity-mapped I-RAM)",
            .wg_wram_beyond_bwram => "the WRAM working set does not fit the BW-RAM window either: bank $7E/$7F beyond 128 KiB, or a low-bank address at or above $2000",
            .wg_dp_dynamic => "the game loads the direct page from something other than an immediate; the BW-RAM window move needs every D provable at build time",
            .wg_stack_dynamic => "the game loads the stack pointer from something other than an immediate; the BW-RAM window move needs every S provable at build time",
            .wg_blockmove_source => "a block move reads bank $00, where WRAM and ROM share the map, and X is not provably a WRAM address here — re-banking a move that turns out to walk ROM would read BW-RAM garbage",
            .wg_mmio_shape => "an MMIO access is not a plain LDA/STA/STZ absolute — not proxyable in place",
            .wg_mmio_outside_bank0 => "an MMIO site executes outside bank $00 code; its in-place JSR can only reach helpers carved in its own bank",
            .wg_uses_irq => "the game takes IRQs; whole-game migration forwards only NMI so far",
            .wg_nmi_ambiguous => "native and emulation NMI handlers both ran and differ; the SA-1's CNV can point at only one",
            .wg_unsupported_op => "an executed instruction (block move, BRK/COP, STP) cannot run on the SA-1 side",
            .wg_split_overflow => "more context-split sites (measured under both a system DBR and a WRAM pin) than the thunk table holds",
            .wg_thunk_space => "a bank's padding cannot hold even one JSR stub per MEASURED split-site thunk (the unmeasured ones already share the cold dispatcher's single stub)",
            .wg_split_shape => "a mainline-split anchor's displaced prefix is not whole flow-free instructions (or split was combined with offload candidates)",
        };
    }
};

pub const Refusal = struct {
    reason: Reason,
    detail: u32 = 0,
};

/// Why a plan region did not move. `clean` means it did.
pub const RegionFate = enum { clean, blocked_indexed, blocked_abs_to_bwram, not_attempted };

pub const Stats = struct {
    shim_addr: u16 = 0,
    park_addr: u16 = 0,
    rewritten_long: u32 = 0,
    /// Sites skipped because their operand bytes carry an opcode flag (two decodes overlapping).
    skipped_overlap: u32 = 0,
    /// Low-WRAM pointer immediates shifted on the code map's word.
    rewritten_map_pointers: u32 = 0,
    /// WMDATA-port fills (DMA into $2180 at a relocated WMADD) turned into
    /// MVN block moves into BW-RAM. See `relocateWmdataFills`.
    rewritten_wmdata_fills: u32 = 0,
    /// Mirror-intent bank bytes re-banked for a >2 MiB image (the $80 fold
    /// is not a mirror on the Super MMC's flat map).
    rewritten_demirror: u32 = 0,
    /// Mirror-bank `JSL`s re-banked on their de-mirrored twin's evidence,
    /// at sites no coverage reached — see `demirrorTwinJsls`.
    rewritten_twin_jsls: u32 = 0,
    /// Battery-SRAM sites re-banked into BW-RAM $20000+ (bank $42), offsets
    /// normalized by the chip's mirror mask.
    rewritten_sram: u32 = 0,
    rewritten_abs: u32 = 0,
    /// Instructions the profile never executed that `--wg-static`'s
    /// recursive descent found anyway — the reach the audit is measuring.
    cov_static_added: u32 = 0,
    /// Non-zero when `--wg-expand` grew the image: the new size in bytes.
    expanded_to: u32 = 0,
    /// Non-zero when EVERY offload was abandoned because the tree copies
    /// needed this many contiguous bytes and no padding run was that big.
    /// A silent zero-offload patch is indistinguishable from a game with
    /// nothing worth offloading; this tells them apart.
    offload_space_short: u32 = 0,
    /// Measured pointer-bank source bytes re-banked (window mode): ROM
    /// bytes proven to feed [dp] pointer bank bytes / DMA bank registers.
    rewritten_ptr_banks: u32 = 0,
    /// Measured dp,X pointer table words rewritten −$6000 (window mode).
    rewritten_idx_words: u32 = 0,
    /// Measured DMA A-bus address words rewritten +$6000 (window mode):
    /// staged transfer sources naming the moved low 8 KiB through a
    /// system bank.
    rewritten_dma_addrs: u32 = 0,
    /// HDMA indirect-bank ($43x7 DASB) writes wrapped in a runtime rebank
    /// thunk (window mode): the bank is a value loaded from an HDMA object,
    /// not an immediate/long operand, so the static rebankers cannot reach
    /// it — the thunk maps $7E/$7F->$40/$41 as the write happens, so an
    /// indirect HDMA fetching WRAM follows its data into BW-RAM.
    rewritten_dasb: u32 = 0,
    /// Low-WRAM indirect addresses relocated +$6000 inside profiled
    /// indirect-HDMA tables (window mode): a per-segment indirect address
    /// naming the moved low 8 KiB is shifted into the window so the DMA
    /// unit fetches the relocated buffer, not the abandoned physical mirror.
    rewritten_hdma_indirect: u32 = 0,
    /// Measured $C0-$DF bank values re-banked -$20 (>2 MiB window mode):
    /// the Super MMC cannot stride those banks LoROM-style; the de-mirror
    /// map parks the content $20 banks lower.
    rewritten_hi_banks: u32 = 0,
    /// Measured $A0-$BF bank values re-banked -$80 (>2 MiB window mode).
    rewritten_a0_banks: u32 = 0,
    /// Super Metroid room-state level-data pointer banks re-banked -$20 by
    /// the room-graph walk (`rebankSmRoomLevelPointers`) at states no
    /// surface loaded; the rooms/states counts are what the walk reached.
    rewritten_room_level_banks: u32 = 0,
    room_walk_rooms: u32 = 0,
    room_walk_states: u32 = 0,
    /// Non-zero when the walk refused: the $8F address that failed
    /// validation. Nothing was rewritten.
    room_walk_refused_at: u32 = 0,
    /// Super Metroid tileset-table pointer banks de-mirrored by
    /// `rebankSmTilesetTable` (the picture's tile table/GFX/palette) at
    /// tilesets no surface loaded; `tileset_records` is the table length.
    rewritten_tileset_banks: u32 = 0,
    tileset_records: u32 = 0,
    tileset_refused_at: u32 = 0,
    /// Super Metroid enemy-header bank bytes (+$0C) de-mirrored by
    /// `rebankSmEnemyHeaders` at species no surface met; `enemy_headers` is
    /// how many records validated as headers.
    rewritten_enemy_banks: u32 = 0,
    enemy_headers: u32 = 0,
    /// Pointer-seed immediates (see `rebankSmPointerSeeds`): sites whose
    /// `LDA #imm / STA dp` seeds a long pointer's bank or low-WRAM
    /// address, and the immediates rewritten (the rest were proven).
    pointer_seed_sites: u32 = 0,
    rewritten_pointer_seeds: u32 = 0,
    /// Area map tilemap table (see `rebankSmAreaMapTable`): entries
    /// validated, bank bytes de-mirrored, or the $82 address that refused.
    area_map_entries: u32 = 0,
    rewritten_area_map_banks: u32 = 0,
    area_map_refused_at: u32 = 0,
    /// Super Metroid background (library) DMA-list source banks de-mirrored
    /// (the BG2 picture) across the records the room walk reached.
    rewritten_bg_banks: u32 = 0,
    bg_records: u32 = 0,
    /// Super Metroid `JSL $80:B0FF` inline destination banks re-banked
    /// $7E/$7F -> $40/$41 (`rebankSmDecompInlineDests`); `decomp_inline_sites`
    /// is every such site whose destination is WRAM.
    rewritten_decomp_inline_banks: u32 = 0,
    decomp_inline_sites: u32 = 0,
    /// Queue-bank immediates re-banked BY SIGNATURE (window mode): a
    /// `LDA #imm16` staged into a dispatch queue's bank column and PLB'd
    /// by later code — see `demirrorQueueBankImms`.
    rewritten_queue_imms: u32 = 0,
    /// Misfit-bank DBR-pin sites patched with a translate-in thunk
    /// (window mode): the pinned bank maps -$20/-$80 at runtime, the
    /// table byte stays stock.
    xl_pins: u32 = 0,
    /// Context-split sites (window mode): absolutes below $2000 whose
    /// measured traffic is BOTH system-DBR (needs the +$6000 shift) and
    /// WRAM-pinned (pin re-banked to $40/$41 — needs the operand
    /// untouched). One operand byte cannot serve both, so each site
    /// becomes a JSR to a DBR-dispatching thunk that runs the original
    /// op with the right operand for the caller it actually has.
    split_sites: u16 = 0,
    /// S5 mainline split: IO routines wearing the enqueue prefix, and
    /// where the split engages (0 = split not requested).
    split_io: u8 = 0,
    split_engage_addr: u16 = 0,
    /// S5: multiply sites rewritten to the engaged-discriminated helper,
    /// and covered hazards the audit found (WAI/STP, or an MMIO read the
    /// split leaves unhandled) — each a 24-bit CPU address, capped.
    split_mul: u8 = 0,
    /// Mainloop flavor: math sites shadowed (uncapped).
    split_math_sites: u32 = 0,
    split_math_direct: u32 = 0,
    split_inline_args: u8 = 0,
    split_trigger_jsl: u32 = 0,
    /// Mainloop flavor: the dual image is in effect (see emitSplit).
    split_dual: bool = false,
    split_hazards: [8]u24 = @splat(0),
    n_split_hazards: u8 = 0,
    /// Of `split_sites`, how many dispatch on the INDEX register instead
    /// of the DBR (tiny-base indexed absolutes, whose home is decided by
    /// magnitude), and how many of the whole population needed a far stub
    /// because their own bank had no room left for a body.
    idx_split_sites: u16 = 0,
    split_far: u16 = 0,
    /// Of `split_sites`, how many are UNMEASURED sites in a bank too full
    /// for per-thunk stubs, routed through the shared cold-site
    /// dispatcher (one 5-byte stub per such bank, however many sites).
    disp_sites: u16 = 0,
    /// dp sites covered wholesale by the D=$3000 window move.
    dp_sites: u32 = 0,
    regions_moved: u8 = 0,
    regions_blocked: u8 = 0,
    /// The S-CPU boots with D=$3000 (the dp window moved).
    d_moved: bool = false,
    /// S3b: the entry of the routine now executing on the SA-1, when one
    /// passed the leaf-eligibility walk. 0 = none offloaded.
    offloaded: u24 = 0,
    /// JSR call sites re-pointed at the offload stubs.
    offload_sites: u32 = 0,
    /// How many routines were offloaded (message ids 1..count).
    offload_count: u8 = 0,
    /// How many of those went through the pointer-offload path (JSL/RTL
    /// routines running against the BW-RAM shadow).
    pointer_offloads: u8 = 0,
    /// The offloaded entries in message-id order, and which of them are
    /// pointer offloads (bit i = entry i) — the auto-bisect loop drops
    /// culprits by name when verification fails.
    offload_entries: [offload_max]u24 = @splat(0),
    offload_ptr_mask: u8 = 0,
    /// Bytes the pointer offloads marshal per call (both directions), and
    /// sibling entry points whose working sets were folded in.
    marshal_bytes: u32 = 0,
    marshal_siblings: u32 = 0,
    /// Pointer offloads whose data is BW-RAM-RESIDENT: not marshalled at
    /// all, addressed in place by both CPUs.
    resident_offloads: u8 = 0,
    /// The ASYNCHRONOUS offload's entry (0 = none): its stub returns
    /// without waiting and completion is collected by the fence. At most
    /// one per conversion — the fence hard-codes its slot set.
    async_entry: u24 = 0,
    /// 24-bit address of the shared fence routine (JSL target), for the
    /// NMI prologue convert() emits.
    async_fence: u24 = 0,
    /// The SA-1 reset vector the shim programs (the dispatcher, or the
    /// park stub when nothing offloaded) — what a state-seeded run needs
    /// to re-boot the SA-1 without executing the shim.
    crv: u16 = 0,
    /// `--wg-static` only: unprovable shapes found in statically
    /// discovered (never-executed) code and left as-is for S4 verification
    /// to arbitrate — D/S establishes, block moves, RMW MMIO.
    static_skipped: u32 = 0,
    /// Where each offload's SA-1-side body copy landed (full 24-bit
    /// address), in message-id order; 0 for leaf offloads, which run the
    /// original body in place. Lets a diagnosis point the SA-1 execution
    /// trace (sa1_trace.zig) straight at the code that ran.
    offload_copy: [offload_max]u24 = @splat(0),
    /// Each copy's length in bytes, same order.
    offload_copy_len: [offload_max]u32 = @splat(0),
    /// Covered `STA $4200` sites re-pointed at $378F-mirror thunks for
    /// the nmi-off wrap (0: none usable — a requested wrap was NOT
    /// emitted).
    nmi_off_sites: u8 = 0,
};

/// What the rewriter DID with one memory-touching site, and why.
///
/// Recorded as the decision is made, never re-derived afterwards: an audit
/// that reimplements the rules is an audit that can disagree with them,
/// and the whole value of this is being able to trust the count.
pub const Verdict = enum(u8) {
    /// The operand moved into the BW-RAM window (+$6000).
    shifted,
    /// A long's bank byte re-banked $7E/$7F -> $40/$41 (or the $7D wrap).
    rebanked,
    /// Replaced by a JSR to a thunk dispatching on the runtime data bank.
    thunk_dbr,
    /// Replaced by a JSR to a thunk dispatching on the index magnitude.
    thunk_index,
    /// Operand at or above $2000: MMIO or ROM, and native either way.
    left_high,
    /// A data bank STATICALLY proved to be BW-RAM here, so the operand is
    /// already this bank's own low page. Sound when the tracker is right;
    /// the tracker is the thing being trusted.
    left_pinned,
    /// Measured traffic never touched low WRAM (a ROM walk, MMIO, or
    /// bank-mediated). Leaving it is what the evidence asked for.
    left_rom,
    /// Measured traffic INCLUDES low WRAM but is not only low WRAM, and
    /// the site's shape fits no thunk. Left pointing at the abandoned
    /// home on the paths where the low-WRAM half is the live one — a
    /// hazard with evidence behind it, which makes it the worst kind.
    left_mixed,
    /// No evidence at all, and the shape is not one the static rules
    /// move. Left as written on a guess.
    left_unproven,
};

pub const AuditSite = struct { file: u32, op: u8, v: u16, ev: u8, verdict: Verdict };

/// How many hazard sites the audit will name before it starts counting
/// instead. A list nobody can read is not evidence.
const audit_list_max: usize = 768;

pub const Audit = struct {
    counts: [std.enums.values(Verdict).len]u32 = @splat(0),
    /// The hazard classes only (`left_pinned`, `left_mixed`,
    /// `left_unproven`); everything else is a decision, not a risk.
    sites: [audit_list_max]AuditSite = undefined,
    n_sites: usize = 0,
    /// Hazard sites past the list's end.
    truncated: u32 = 0,
    /// Instructions per bank in the map the REWRITER used — dynamic
    /// coverage plus whatever `--wg-static` reached. A bank at zero here
    /// is a bank the rewriter has never touched an instruction in.
    bank_ops: [0x40]u32 = @splat(0),
    /// Per bank, how many `JSL`/`JML` sites in code the rewriter has seen
    /// name it as a target. A dark bank that nothing ever calls is reached
    /// some other way — or is not code at all.
    bank_calls: [0x40]u32 = @splat(0),
    /// Per bank, how many long DATA accesses (and block-move endpoints) in
    /// seen code name it. Positive evidence that a bank the descent never
    /// entered is a bank of DATA, not unreached code.
    bank_data: [0x40]u32 = @splat(0),
    /// Indirect control transfers in seen code, by shape: `JMP (abs)`,
    /// `JMP (abs,X)` / `JSR (abs,X)`, `JMP [abs]`. Every one of these is a
    /// door the descent cannot open.
    n_ind_abs: u32 = 0,
    n_ind_absx: u32 = 0,
    n_ind_long: u32 = 0,

    pub fn count(self: *const Audit, v: Verdict) u32 {
        return self.counts[@intFromEnum(v)];
    }
};

fn auditNote(a: *Audit, file: u32, op: u8, v: u16, ev: u8, verdict: Verdict) void {
    a.counts[@intFromEnum(verdict)] += 1;
    switch (verdict) {
        .left_pinned, .left_mixed, .left_unproven => {},
        else => return,
    }
    if (a.n_sites == a.sites.len) {
        a.truncated += 1;
        return;
    }
    a.sites[a.n_sites] = .{ .file = file, .op = op, .v = v, .ev = ev, .verdict = verdict };
    a.n_sites += 1;
}

pub const Result = struct {
    image: []u8,
    stats: Stats,
    /// Per-site conversion verdicts (window/whole-game rewrites only).
    audit: Audit = .{},
    /// Per plan region (same order), what happened to it.
    fate: [profile.plan_region_cap]RegionFate,
    /// Per plan region, how many sites the rewriter actually re-pointed.
    /// A "clean" region with zero sites moved vacuously — nothing refers
    /// to its new home, so its I-RAM/BW-RAM bytes are dead storage the
    /// offload machinery may safely overlay.
    region_sites: [profile.plan_region_cap]u32 = @splat(0),
};

/// A hot routine considered for execution offload: the entry, plus its
/// profiled WRAM page bitmap — the dynamic evidence the pointer-offload
/// path marshals as a BW-RAM shadow. An empty bitmap limits the routine to
/// the static leaf walk.
pub const Candidate = struct {
    entry: u24,
    pages: profile.WramPages = @splat(0),
    /// Measured self cycles and calls, for the marshal-cost budget: an
    /// offload that spends more moving state than the routine spends
    /// computing is a regression however correct it is.
    self_cycles: u64 = 0,
    calls: u64 = 0,
    /// The direct page observed on entry, and whether it ever varied. A
    /// varying dp means no single page is "the" direct page, so the
    /// residency test cannot exclude one and residency is refused.
    entry_d: u16 = 0,
    d_varies: bool = false,
    /// The auto-bisect's mode ladder: an ASYNCHRONOUS offload that fails
    /// verification retries synchronously before being dropped. Also set
    /// up front for every candidate when the behavioral tier is off —
    /// async reorders execution by design, so only that tier can ever
    /// accept it.
    no_async: bool = false,
    /// Wrap this tree's sync stub in NMI/IRQ-off across the dispatch
    /// (--wg-nmi-off): the S-CPU spins through the whole copy anyway,
    /// and masking its interrupts makes CONCURRENT MUTATION of the
    /// tree's read-set impossible by construction — the hazard class
    /// that defeated both the vblank guard (timing) and the watchdog
    /// (whose abort re-ran the body inline over the same torn state).
    /// Implies no_async: an async tree runs concurrently by design.
    nmi_off: bool = false,
};

/// Convert a plain LoROM image into an SA-1 cart per `plan`. `usage` is the
/// S1 coverage map's CPU block (null: shell only, nothing relocates —
/// `plan` may also be empty/nonviable for the same effect). `refusal` is
/// written only on `error.Refused`.
pub fn convert(
    gpa: std.mem.Allocator,
    image: []const u8,
    plan: *const profile.Plan,
    usage: ?[]const u8,
    /// Hot routines (the conversion verdict's set) considered for
    /// execution offload; empty skips S3b entirely.
    candidates: []const Candidate,
    /// Every OTHER profiled routine, for sibling lookup: an alternate
    /// entry point into an offloaded routine's body shares its working
    /// set, and the marshal must cover the union even though the sibling
    /// itself is far too cold to be a candidate. Empty is safe (the union
    /// simply finds nothing) — it is evidence, not correctness.
    neighbours: []const Candidate,
    /// Every WRAM page a profiled DMA/HDMA arm reads or writes. Such a
    /// page can never become BW-RAM-resident: the transfer's A-bus side
    /// names a WRAM address, and re-sourcing DMA is not part of this
    /// slice. Empty is safe — it only costs residency, never correctness,
    /// because a page left non-resident is marshalled as before.
    dma_pages: profile.WramPages,
    refusal: *?Refusal,
) Error!Result {
    if (image.len < 0x8000) return error.RomTooSmall;
    const header = try header_mod.detect(image);

    if (cartridge.identifyChip(header) != .none) return refuse(refusal, .{ .reason = .coprocessor });
    if (header.mapping != .lorom) return refuse(refusal, .{ .reason = .not_lorom });
    if (header.sramBytes() != 0) return refuse(refusal, .{ .reason = .has_sram });
    if (image.len > 4 << 20) return refuse(refusal, .{ .reason = .rom_too_big });
    if (plan.viable and plan.bwram_used > cartridge.max_sram)
        return refuse(refusal, .{ .reason = .bwram_too_big, .detail = plan.bwram_used });
    const reset = header.reset_vector;
    if (reset < 0x8000) return refuse(refusal, .{ .reason = .reset_vector_not_rom });

    const carve = patchgen.findFreeSpace(image[0..header.offset], shim_len_max + park_len + nmi_prologue_len) orelse
        return refuse(refusal, .{ .reason = .no_free_space, .detail = shim_len_max + park_len + nmi_prologue_len });

    const out = try gpa.dupe(u8, image);
    errdefer gpa.free(out);

    var res: Result = .{
        .image = out,
        .stats = .{},
        .fate = @splat(.not_attempted),
    };

    // --- the relocation, first: whether D moves decides the shim ----------
    if (plan.viable and usage != null) rewrite(out, plan, usage.?, &res);

    // --- header -----------------------------------------------------------
    out[header.offset + 0x15] = 0x23; // SA-1 map mode
    out[header.offset + 0x16] = 0x34; // SA-1 + RAM, NO battery: BW-RAM is working memory
    // BW-RAM: at least the SA-1-standard 32 KiB, more if the plan spilled.
    out[header.offset + 0x18] = if (plan.viable and plan.bwram_used > 32 * 1024) 0x07 else 0x05;

    // Async needs the NMI vectors: the fence prologue takes them over, so
    // the native target must be real code, and the emulation vector must
    // agree (or be unused) — the prologue can only forward to one handler.
    const nmi_native = std.mem.readInt(u16, image[header.offset + 0x2A ..][0..2], .little);
    const nmi_emu = std.mem.readInt(u16, image[header.offset + 0x3A ..][0..2], .little);
    const nmi_ok = nmi_native >= 0x8000 and
        (nmi_emu == nmi_native or nmi_emu < 0x8000 or nmi_emu == 0xFFFF);

    // --- S3b: execution offload, before the shim (it decides CRV) ---------
    var crv: u16 = 0x8000 + @as(u16, @intCast(carve)) + @as(u16, @intCast(shim_len_max));
    if (usage != null and plan.viable) tryOffload(out, plan, usage.?, candidates, neighbours, dma_pages, carve, nmi_ok, &res, &crv);
    // The pointer-offload shadow lives at BW-RAM linear $10000+ (bank
    // $41): the cart must carry the full 128 KiB.
    if (res.stats.pointer_offloads > 0 and out[header.offset + 0x18] < 0x07)
        out[header.offset + 0x18] = 0x07;

    // The async fence's NMI prologue: every frame boundary collects a
    // still-in-flight call before the game's own handler (whose DMA may
    // read what the routine computes) runs.
    if (res.stats.async_entry != 0) {
        const nmi_file = carve + shim_len_max + park_len;
        const f = res.stats.async_fence;
        const wn = out[nmi_file..];
        var m: usize = 0;
        put(wn, &m, &.{ 0x08, 0xC2, 0x30, 0x48, 0xDA, 0x5A, 0x8B }); // save
        put(wn, &m, &.{ 0x22, @truncate(f), @truncate(f >> 8), @truncate(f >> 16) });
        put(wn, &m, &.{ 0xAB, 0xC2, 0x30, 0x7A, 0xFA, 0x68, 0x28 }); // restore
        put(wn, &m, &.{ 0x4C, @truncate(nmi_native), @truncate(nmi_native >> 8) });
        std.debug.assert(m == nmi_prologue_len);
        const nmi_addr: u16 = 0x8000 + @as(u16, @intCast(nmi_file));
        std.mem.writeInt(u16, out[header.offset + 0x2A ..][0..2], nmi_addr, .little);
        std.mem.writeInt(u16, out[header.offset + 0x3A ..][0..2], nmi_addr, .little);
    }

    // --- the S-CPU boot shim and the SA-1 park stub -----------------------
    const shim_addr: u16 = 0x8000 + @as(u16, @intCast(carve));
    var w = out[carve..];
    var n: usize = 0;
    w[n] = 0x78; // SEI
    n += 1;
    if (res.stats.d_moved) {
        // PEA $3000 / PLD: the whole dp window now lives in I-RAM.
        w[n] = 0xF4;
        w[n + 1] = 0x00;
        w[n + 2] = 0x30;
        w[n + 3] = 0x2B;
        n += 4;
    }
    n = emitStore(w, n, 0x2229, 0xFF); // SIWP: allow S-CPU I-RAM writes
    n = emitStore(w, n, 0x2226, 0x80); // SWEN: allow S-CPU BW-RAM writes
    // Async busy flag ($378A) starts idle: I-RAM is uninitialised at boot,
    // and the NMI fence deadlocks on garbage that reads as an in-flight id
    // — awaiting a handshake for a call that never happened.
    if (res.stats.async_entry != 0) n = emitStore(w, n, 0x378A, 0x00);
    const park_addr: u16 = shim_addr + @as(u16, @intCast(shim_len_max));
    res.stats.crv = crv;
    n = emitStore(w, n, 0x2203, @truncate(crv)); // CRV low
    n = emitStore(w, n, 0x2204, @truncate(crv >> 8)); // CRV high
    w[n] = 0x9C; // STZ $2200: release the SA-1 from reset -> boots from CRV
    w[n + 1] = 0x00;
    w[n + 2] = 0x22;
    n += 3;
    w[n] = 0x4C; // JMP <original reset>: the game continues on the S-CPU
    w[n + 1] = @truncate(reset);
    w[n + 2] = @truncate(reset >> 8);
    // Park stub at a fixed offset so CRV was knowable above.
    out[carve + shim_len_max] = 0x78; // SEI
    out[carve + shim_len_max + 1] = 0xDB; // STP: the SA-1 idles until offloaded work exists

    std.mem.writeInt(u16, out[header.offset + 0x3C ..][0..2], shim_addr, .little);
    patchgen.recomputeChecksum(out, header.offset);

    res.stats.shim_addr = shim_addr;
    res.stats.park_addr = park_addr;
    return res;
}

/// Worst-case shim size (with the D move): SEI + PEA/PLD + 4 stores + STZ +
/// JMP = 1 + 4 + 20 + 3 + 3 = 31; rounded up for slack.
pub const shim_len_max: u32 = 40;
pub const park_len: u32 = 2;
/// The async offload's NMI prologue: save context, JSL the fence, restore,
/// JMP the game's own handler. Carved after the park stub.
pub const nmi_prologue_len: u32 = 21;

fn emitStore(w: []u8, n: usize, reg: u16, value: u8) usize {
    w[n] = 0xA9; // LDA #value
    w[n + 1] = value;
    w[n + 2] = 0x8D; // STA reg
    w[n + 3] = @truncate(reg);
    w[n + 4] = @truncate(reg >> 8);
    return n + 5;
}

pub fn refuse(refusal: *?Refusal, r: Refusal) Error {
    refusal.* = r;
    return error.Refused;
}

/// One executed instruction site naming WRAM, as the walk classifies it.
const Site = struct {
    file_off: u32, // of the opcode byte
    mode: usage_map.Mode,
    wram_off: u32, // linear WRAM offset the operand names
    region: u8, // plan region index
};

/// Walk every executed instruction (S1's Opcode flags over the LoROM code
/// banks), attribute statically-nameable WRAM operands to plan regions,
/// block regions with unsound sites, then rewrite the sites of the clean
/// ones. Two passes over the same walk, so nothing is patched for a region
/// that a later site condemns.
fn rewrite(
    out: []u8,
    plan: *const profile.Plan,
    usage: []const u8,
    res: *Result,
) void {
    for (plan.regions[0..plan.n], 0..) |_, i| res.fate[i] = .clean;

    var pass: u2 = 0;
    while (pass < 2) : (pass += 1) {
        var bank: u32 = 0;
        while (bank < 0x40) : (bank += 1) {
            const bank_file = bank * 0x8000;
            if (bank_file >= out.len) break;
            var a16: u32 = 0x8000;
            while (a16 < 0x10000) : (a16 += 1) {
                const cpu_addr = (bank << 16) | a16;
                const flags = usage[cpu_addr];
                if (flags & usage_map.flag_opcode == 0) continue;
                const file_off = bank_file + (a16 - 0x8000);
                if (file_off >= out.len) break;
                const op = out[file_off];
                const m8 = flags & usage_map.flag_m != 0;
                const x8 = flags & usage_map.flag_x != 0;
                const len = usage_map.instrLen(op, m8, x8);
                if (file_off + len > out.len) continue;

                const md = usage_map.mode(op);
                const operand = out[file_off + 1 ..];
                const wram_off: u32 = switch (md) {
                    .none => continue,
                    .dp, .dp_idx => operand[0],
                    .abs, .abs_x, .abs_y => blk: {
                        const v = std.mem.readInt(u16, operand[0..2], .little);
                        if (v >= 0x2000) continue; // DB-dependent: unattributable
                        break :blk v;
                    },
                    .long, .long_x => blk: {
                        const b = operand[2];
                        const v = std.mem.readInt(u16, operand[0..2], .little);
                        if (b == 0x7E) break :blk v;
                        if (b == 0x7F) break :blk @as(u32, 0x10000) + v;
                        if ((b & 0x7F) <= 0x3F and v < 0x2000) break :blk v; // low mirror
                        continue;
                    },
                };

                // Indexed sites: the index carries the access anywhere
                // ABOVE the base — 255 bytes for an 8-bit index, the rest
                // of the bank for 16. Every region the reach touches is
                // compromised, not merely the one holding the base: the
                // site that sank the first live relocation ever verified
                // (`INC $10B9,X` on a real cart) had its base two pages
                // BELOW the region it scribbled into, so a base-only rule
                // rewrites the exact stores and leaves the indexed ones
                // splitting the structure between WRAM and the new home.
                if (md == .abs_x or md == .abs_y or md == .long_x or md == .dp_idx) {
                    if (pass == 0) {
                        const reach: u32 = if (x8) 255 else 0xFFFF;
                        for (plan.regions[0..plan.n], 0..) |rg, rgi| {
                            if (wram_off < rg.start + rg.len and wram_off + reach >= rg.start)
                                res.fate[rgi] = .blocked_indexed;
                        }
                    }
                    continue;
                }

                const region: u8 = for (plan.regions[0..plan.n], 0..) |r, ri| {
                    if (wram_off >= r.start and wram_off < r.start + r.len)
                        break @intCast(ri);
                } else continue;
                const r = &plan.regions[region];

                if (pass == 0) {
                    // Judgement pass: what would sink this region's move?
                    switch (md) {
                        .abs => if (r.dest == .bwram) {
                            res.fate[region] = .blocked_abs_to_bwram;
                        },
                        .dp => if (!r.dp) {
                            // A dp operand resolving into a non-dp region
                            // means D was nonzero at that site: the static
                            // model is wrong for it — block the region.
                            res.fate[region] = .blocked_indexed;
                        },
                        else => {},
                    }
                } else if (res.fate[region] == .clean) {
                    // Rewrite pass, clean regions only. Indexed sites never
                    // get here — pass 0 blocked their regions.
                    const within = wram_off - r.start;
                    res.region_sites[region] += 1;
                    switch (md) {
                        .dp => res.stats.dp_sites += 1, // covered by D=$3000
                        .abs => {
                            const dest16: u16 = @intCast(0x3000 + r.dest_off + within);
                            std.mem.writeInt(u16, operand[0..2], dest16, .little);
                            res.stats.rewritten_abs += 1;
                        },
                        .long => {
                            const dest: u32 = switch (r.dest) {
                                .iram => 0x3000 + r.dest_off + within,
                                .bwram => 0x40_0000 + r.dest_off + within,
                            };
                            operand[0] = @truncate(dest);
                            operand[1] = @truncate(dest >> 8);
                            operand[2] = @truncate(dest >> 16);
                            res.stats.rewritten_long += 1;
                        },
                        else => unreachable, // indexed sites blocked in pass 0
                    }
                }
            }
        }
        if (pass == 0) {
            // A blocked dp-window region pins D at 0, which unblocks nothing
            // else but must un-move every other dp region too: the window
            // moves as a unit or not at all.
            var dp_blocked = false;
            for (plan.regions[0..plan.n], 0..) |r, ri| {
                if (r.dp and res.fate[ri] != .clean) dp_blocked = true;
            }
            if (dp_blocked) {
                for (plan.regions[0..plan.n], 0..) |r, ri| {
                    if (r.dp and res.fate[ri] == .clean) res.fate[ri] = .blocked_indexed;
                }
            } else {
                for (plan.regions[0..plan.n], 0..) |r, ri| {
                    if (r.dp and res.fate[ri] == .clean) res.stats.d_moved = true;
                }
            }
        }
    }

    for (res.fate[0..plan.n]) |f| {
        switch (f) {
            .clean => res.stats.regions_moved += 1,
            .blocked_indexed, .blocked_abs_to_bwram => res.stats.regions_blocked += 1,
            .not_attempted => {},
        }
    }
}

comptime {
    std.debug.assert(stub_template[stub_id_send_off - 1] == 0xA9); // LDA #
    std.debug.assert(stub_template[stub_id_cmp_off - 1] == 0xC9); // CMP #
    std.debug.assert(stub_template.len == 68);
}

// --- whole-game migration ------------------------------------------------------
//
// The SA-1 Root architecture: the ENTIRE game executes on the SA-1 and the
// S-CPU becomes a service loop. The vertical slice built here leans on one
// mapping fact: the SA-1's I-RAM occupies $0000-$07FF of its bus — exactly
// where the S-CPU sees WRAM's low mirror — so a game whose WRAM working set
// (per the S1 coverage map's effective addresses: dp, stack, and indirect
// accesses included) fits under $07F0 needs NO WRAM rewriting at all: its
// dp and low-absolute accesses land in I-RAM natively, and ROM addressing
// is identical on both CPUs through the Super MMC. What must change: every
// executed MMIO site becomes a same-length JSR to an emitted helper that
// files a request through an I-RAM mailbox (reserved tail $37F0: status,
// reg, value) which the S-CPU service loop performs on the real bus.
//
// NMI crosses the wall in two hops with a mask making it safe: an S-CPU
// stub acks $4210 and sends the SA-1 an NMI message (CCNT bit 4); CNV
// lands on an emitted SA-1 shim that acks the message (CIC) and jumps to
// the game's own handler. Because that handler's MMIO sites file requests
// through the same mailbox, every helper masks the message NMI (CIE) for
// the span of its transaction — a message that arrives meanwhile latches
// and delivers on the unmask, so an in-flight request can never be
// corrupted by a nested one.
//
// Refusal-first, as always: WRAM touched beyond the window (or inside the
// reserved mailbox tail), IRQ use, ambiguous NMI handlers, MMIO in any
// shape but plain LDA/STA/STZ absolute in bank $00 code, block moves,
// BRK/COP, STP — each refuses by name. DMA the game programs is performed
// by the S-CPU verbatim; sources in the I-RAM window are NOT translated
// (the S-CPU's WRAM is a different memory), and WRAM-port ($2180-$2183)
// traffic lands in real WRAM, not I-RAM — either mismatch fails S4
// verification rather than shipping wrong.

const wg_prologue_len = 21;
/// Window mode's shim: SEI + 3 stores + XCE/REP + D + S + SEP + JMP =
/// 1 + 15 + 4 + 4 + 4 + 2 + 3 = 33; +23 when offloads boot the SA-1
/// (SIWP, CRV lo/hi, async busy init, reset release).
const wg_window_shim_len = 33;
pub const wg_window_shim_max = 33 + 72;
/// What the shim must program before releasing the SA-1 from reset:
/// its reset vector and — S-CPU-side registers both — its IRQ vector,
/// aimed at the watchdog's abort handler.
pub const WinBoot = struct { crv: u16, civ: u16 };
/// Extra prologue the BW-RAM window needs: select block 0, unprotect, and
/// reproduce the power-on D and S inside the window (native mode first).
const wg_prologue_bw_extra = 20;
const wg_sa1_nmi_len = 18;
const wg_scpu_nmi_len = 19;
const wg_shim_len = 37;

/// The S-CPU service loop: position-independent (relative branches only),
/// 8-bit M/X except the marked 16-bit windows. Performs each filed MMIO
/// request on the real bus through a dp pointer at $00-$02 (the S-CPU's
/// WRAM dp is free — the game left). Reads answer with the $FE "served"
/// marker and the SA-1 releases the mailbox after collecting the result,
/// so the mailbox stays owned end to end.
const wg_service = [_]u8{
    0x18, 0xFB, 0xE2, 0x30, // CLC / XCE / SEP #$30
    // loop (+4):
    0xAD, 0xF0, 0x37, 0xF0, 0xFB, // LDA status / BEQ loop
    0xC9, 0x05, 0xB0, 0xF7, // CMP #5 / BCS loop (busy markers, not requests)
    0xAD, 0xF1, 0x37, 0x85, 0x00, // reg -> dp pointer
    0xAD, 0xF2, 0x37, 0x85, 0x01,
    0x64, 0x02, // bank $00
    0xAD, 0xF0, 0x37, // reload the kind
    0xC9, 0x02, 0xF0, 0x12, // -> r8  (+18)
    0xC9, 0x03, 0xF0, 0x1A, // -> w16 (+26)
    0xC9, 0x04, 0xF0, 0x21, // -> r16 (+33)
    0xAD, 0xF3, 0x37, 0x87, 0x00, // w8: value -> [reg]
    // clr (+45):
    0x9C, 0xF0, 0x37, 0x80, 0xD2, // STZ status / BRA loop
    // r8 (+50):
    0xA7, 0x00, 0x8D, 0xF3, 0x37, // [reg] -> value
    0xA9, 0xFE, 0x8D, 0xF0, 0x37, 0x80, 0xC6, // status = served / BRA loop
    // w16 (+62):
    0xC2, 0x20, 0xAD, 0xF3, 0x37, 0x87, 0x00, 0xE2, 0x20, 0x80, 0xE4, // BRA clr
    // r16 (+73):
    0xC2, 0x20, 0xA7, 0x00, 0x8D, 0xF3, 0x37, 0xE2, 0x20,
    0xA9, 0xFE, 0x8D, 0xF0, 0x37, 0x80, 0xAB, // status = served / BRA loop
};

comptime {
    std.debug.assert(wg_service.len == 89);
}

/// Debug: addresses whose first static decode as an opcode is reported with the path that reached them.
pub var dbg_walk_watch: [8]u32 = @splat(0);

/// `--code-map`: a hand-made disassembly's verdict on every ROM byte, one
/// flag byte per CPU address in the bank-$80 form (see
/// tools/sm_disasm_oracle.py --export). An OPTIONAL input: the generator
/// works from coverage alone, and where a map exists it (1) refuses any
/// static decode, dispatcher mark, pointer seed or rewrite at a byte the
/// map places inside an instruction or in data, (2) takes an immediate's
/// operand width from the map instead of the walk's guess, and (3) seeds
/// the static walk with every instruction start it names. Measured on
/// Super Metroid without it: the static walk decoded bank $B3's enemy
/// spritemaps and instruction lists as code and the relocation corrupted
/// seven Gamet/Geega instructions and 273 data bytes nothing had ever
/// executed; with it, the walk cannot leave the code.
pub var dbg_code_map: ?[]const u8 = null;
/// Debug (`--cov-out`): after a generation, the coverage the relocation
/// walked — the profiled union (`dbg_usage_kept`) and its static
/// extension (`dbg_cov_kept`), one byte per CPU address (usage_map flags) —
/// so an external oracle (a hand-made disassembly) can audit every
/// instruction boundary the generator believed, not just the ones a
/// session happened to reach.
pub var dbg_keep_cov: bool = false;
pub var dbg_usage_kept: ?[]u8 = null;
pub var dbg_cov_kept: ?[]u8 = null;

pub fn convertWholeGame(
    gpa: std.mem.Allocator,
    image: []const u8,
    usage: []const u8,
    /// `--wg-static`: also rewrite code the profiled run never executed,
    /// discovered by `extendCoverage`. Statically discovered code gets the
    /// window rewrites and (supported-shape) MMIO proxies but contributes
    /// no proofs and no refusals — unprovable shapes there are counted in
    /// `stats.static_skipped` and left for S4 verification to arbitrate,
    /// because refusing a conversion over code that may never run would
    /// bring back the old "no game qualifies" regime by another road.
    /// Per-site effective-address evidence (`usage_map.site_*` bits per
    /// instruction address), when a profiled run recorded it. Decides the
    /// statically undecidable idioms by measurement: a base-$0000 indexed
    /// absolute whose observed traffic was all ROM stays put; one whose
    /// traffic was all low WRAM shifts into the window.
    site_evidence: ?[]const u8,
    /// Value provenance (window mode): ROM bytes a profiled run PROVED to
    /// feed addressing state that operand rewrites cannot reach. Two
    /// families: `proven` — [dp] pointer bank bytes / DMA A-bus bank
    /// registers carrying $7E/$7F (re-banked −$3E so value-mediated
    /// traffic lands in BW-RAM with everything else; measured: the stage
    /// loader's bank-$01 table, whose tear blanked every gameplay sprite);
    /// `idx_proven` — X-register table words carrying full dp,X pointers
    /// beyond the moved low 8 KiB (rewritten −$6000 so the relocated
    /// D=$6000 wraps back onto the original target; measured: the HDMA
    /// channel builder's $43x0 register words, whose +$6000 drift silently
    /// voided channel-7 setup and phase-shifted the APU pump into the
    /// gameplay RNG fork).
    ptr_ev: ?*const usage_map.PtrBankEvidence,
    static_walk: bool,
    /// UNIFORM WINDOW MODE (v17's actual architecture): the game KEEPS
    /// RUNNING ON THE S-CPU and only its memory moves — WRAM's low 8 KiB
    /// into the S-CPU's own BW-RAM window ($6000-$7FFF, SBM block 0) and
    /// $7E/$7F long references to banks $40/$41, every relative distance
    /// preserved so indexed bases rewrite soundly (the per-region S2
    /// rewriter cannot say that; see the indexed-reach rule). MMIO stays
    /// native — no proxies, no NMI forwarding, no SA-1 execution at all
    /// (the chip never leaves reset; the cart is carried for its RAM).
    /// This is the enabler for resident offloads over the whole working
    /// set: once state lives in BW-RAM, both CPUs address it in place.
    window: bool,
    /// Window offload candidates (profile entries; empty = relocation
    /// only). Ignored outside window mode.
    win_candidates: []const Candidate,
    /// Allow the fire-and-forget flavor (gated on the behavioral tier by
    /// the caller, as in the S3 path).
    win_allow_async: bool,
    /// `--wg-expand`: grow the output image to this many bytes, filling the
    /// new space with $FF. Zero keeps the image its original size.
    ///
    /// A conversion spends ROM it does not have: tree copies need one
    /// CONTIGUOUS block, thunk bodies need runs in the site's own bank, and
    /// the boot shim needs a few dozen bytes of bank $00. Gradius III ships
    /// 6704 bytes of padding in all of 512 KiB, so the three compete and the
    /// loser is silently dropped — measured: a 3410-byte tree set against a
    /// 3907-byte run left the far pool too thin for a 35-byte shim, and the
    /// conversion refused outright. SA-1 carts are routinely larger than
    /// their originals for exactly this reason. Doubling the image hands
    /// banks $10-$1F over as one unbroken run and the competition ends.
    ///
    /// The size must stay a LoROM-mappable power of two: the SA-1's MMC maps
    /// in 1 MiB regions and `rom_mask` is `padded_len - 1`, so anything else
    /// folds the new space back onto the old.
    win_expand_to: u32,
    /// How many bytes at the tail of the image's biggest padding run to keep
    /// back for the offload tree copies. `copy_reserve` is the default; a
    /// bigger candidate set needs a bigger reserve, and getting this wrong
    /// does not shrink the conversion — it abandons EVERY offload, because
    /// the copies need one contiguous block and the thunks have already
    /// eaten the run (measured: a 3410-byte set against a 3907-byte run
    /// reserved at 2560 shipped no offloads at all).
    win_copy_reserve: u32,
    /// S5: engage the mainline/NMI split (window mode only; excludes
    /// offload candidates — the SA-1 runs everything, so there is
    /// nothing to dispatch).
    ml_split: ?SplitSpec,
    refusal: *?Refusal,
) Error!Result {
    if (image.len < 0x8000) return error.RomTooSmall;
    const header = try header_mod.detect(image);
    if (cartridge.identifyChip(header) != .none) return refuse(refusal, .{ .reason = .coprocessor });
    if (header.mapping != .lorom) return refuse(refusal, .{ .reason = .not_lorom });
    // Battery SRAM: liftable in window mode. The 256 KiB BW-RAM holds the
    // relocated WRAM image in its first half; the game's save RAM relocates
    // to offset $20000 — bank $42 on both buses — and every executed
    // long-addressed $70-$7D site re-banks there with its offset NORMALIZED
    // by the original chip's mirror mask. Normalization is what preserves
    // aliasing: Super Metroid's boot probes the 8 KiB chip by writing a
    // pattern at $70:2000,X and reading it back at $70:0000,X — both
    // normalize to $42:0000, so the probe still sees the mirror. Non-window
    // (SA-1-execution) mode keeps refusing: bank $70 is open bus there.
    const game_sram: u32 = header.sramBytes();
    if (game_sram != 0 and !(window and game_sram <= 32 * 1024))
        return refuse(refusal, .{ .reason = .has_sram });
    if (image.len > 4 << 20) return refuse(refusal, .{ .reason = .rom_too_big });
    const reset = header.reset_vector;
    if (reset < 0x8000) return refuse(refusal, .{ .reason = .reset_vector_not_rom });

    // The map both walks consume: dynamic coverage, statically extended
    // when asked. `usage` stays the authority on what actually ran — the
    // refusal policy keys on it.
    const cov: []const u8 = if (static_walk) try extendCoverage(gpa, image, header, usage) else usage;
    if (dbg_keep_cov) {
        dbg_usage_kept = try gpa.dupe(u8, usage);
        dbg_cov_kept = try gpa.dupe(u8, cov);
    }
    defer if (static_walk) gpa.free(@constCast(cov));
    // Reach, for the audit: instructions the profile never ran that the
    // recursive descent found anyway.
    const cov_added: u32 = if (static_walk)
        usage_map.countOpcodes(cov) - usage_map.countOpcodes(usage)
    else
        0;
    // Executed flags are merged across the $80-$BF fast mirrors throughout:
    // the same ROM byte, the same file offset, possibly only ever executed
    // through the mirror.

    // IRQ vectors with executed targets = the game takes IRQs. Window mode
    // does not care: the S-CPU keeps its own vectors and handlers, and an
    // interrupt's stack traffic follows S into the window like any push.
    if (!window) for ([_]u32{ 0x2E, 0x3E }) |off| {
        const v: u32 = std.mem.readInt(u16, image[header.offset + off ..][0..2], .little);
        if (v >= 0x8000 and v != 0xFFFF and
            (usage[v] | usage[0x80_0000 | v]) & usage_map.flag_opcode != 0)
            return refuse(refusal, .{ .reason = .wg_uses_irq });
    };
    // The SA-1 serves CNV for both the native and the emulation NMI pull,
    // so only one game handler can survive the migration. Pick the one
    // that actually ran; if both ran and differ, refuse.
    const nmi_native = std.mem.readInt(u16, image[header.offset + 0x2A ..][0..2], .little);
    const nmi_emu = std.mem.readInt(u16, image[header.offset + 0x3A ..][0..2], .little);
    const nat_used = nmi_native >= 0x8000 and
        (usage[nmi_native] | usage[0x80_0000 | @as(u32, nmi_native)]) & usage_map.flag_opcode != 0;
    const emu_used = nmi_emu >= 0x8000 and
        (usage[nmi_emu] | usage[0x80_0000 | @as(u32, nmi_emu)]) & usage_map.flag_opcode != 0;
    if (!window and nat_used and emu_used and nmi_native != nmi_emu)
        return refuse(refusal, .{ .reason = .wg_nmi_ambiguous });
    const nmi_target: u16 = if (emu_used and !nat_used) nmi_emu else nmi_native;

    // Which identity window carries the game's WRAM?
    //
    // I-RAM first: the SA-1's 2 KiB sits at $0000-$07FF of its bus, exactly
    // where the S-CPU sees WRAM's low mirror, so a set that fits needs NO
    // WRAM rewriting at all — the cheapest and safest conversion, and the
    // only one this generator used to attempt.
    //
    // Otherwise BW-RAM, which is what every shipped SA-1 Root conversion
    // actually uses (checked against Vitor Vilela's Gradius III v17: it
    // re-banks $7E:xxxx to $40:xxxx and adds $6000 to low-bank absolute
    // addresses, nothing else). BW-RAM is 128 KiB+ against I-RAM's 2 KiB,
    // so the sets that fit are a different order of game. The price is that
    // every WRAM-naming operand must be rewritten, and D and S must move
    // with them — see the walk below.
    var wram_fits_iram = !window; // window mode IS the BW-RAM move
    if (!window) {
        const touched = usage_map.flag_read | usage_map.flag_write | usage_map.flag_exec;
        var b: u32 = 0;
        while (b < 0x100) : (b += 1) {
            const sys = b < 0x40 or (b >= 0x80 and b < 0xC0);
            const top: u32 = if (b == 0x7E or b == 0x7F) 0x10000 else if (sys) 0x2000 else 0;
            var a: u32 = 0;
            while (a < top) : (a += 1) {
                if (usage[(b << 16) | a] & touched == 0) continue;
                if (b == 0x7F or a >= 0x7F0) {
                    wram_fits_iram = false;
                    break;
                }
            }
            if (!wram_fits_iram) break;
        }
    }
    // The BW-RAM window is uniform: WRAM $7E/$7F:xxxx -> BW-RAM $40/$41:xxxx
    // and low-bank $0000-$1FFF -> $6000-$7FFF, the same byte reached either
    // way. A low-bank address at or above $2000 is not WRAM at all, so
    // nothing in that range can be carried by this move.
    const bwram = !wram_fits_iram;

    // Eligibility walk + MMIO site collection over every executed opcode.
    var sites: [wg_sites_max]WgSite = undefined;
    var n_sites: usize = 0;
    // File offsets of `LDA #imm` operands feeding a TCD/TCS (BW-RAM mode).
    var moves: [wg_moves_max]u32 = undefined;
    var n_moves: usize = 0;
    // File offsets of bank-$00 block moves proved to walk WRAM.
    var bm: [wg_moves_max]u32 = undefined;
    var n_bm: usize = 0;
    // File offsets of `LDA #$7E/$7F` immediates feeding a PLB.
    var dbrs: [wg_moves_max]u32 = undefined;
    var n_dbrs: usize = 0;
    // Unprovable shapes in statically discovered code, left for S4.
    var static_skipped: u32 = 0;
    var bank: u32 = 0;
    // The most recent `LDX #imm` this walk passed, for the block-move source
    // proof below. Reset at every bank and killed by anything that writes X
    // or transfers control, so it only ever survives straight-line code.
    var ldx_at: ?u32 = null;
    var ldx_imm: u16 = 0;
    var ldy_at: ?u32 = null;
    var ldy_imm: u16 = 0;
    var ldy_file: u32 = 0;
    // Does the data bank register point at BW-RAM here? Absolute operands
    // are DBR-relative, so the same instruction means different memory
    // depending on it: with DBR a system bank, `LDA $0900` is WRAM's low
    // mirror and must shift into the $6000 window; with DBR already $7E (or
    // $40 after re-banking), it is that bank's own $0900 and must NOT shift.
    // Gradius III relies on this — its `STZ $2000` at $00:8086 runs with DBR
    // left at $7E by the preceding `MVN $7E,$7E`, which is why Vilela
    // re-banks the move and leaves the store alone.
    //
    // DBR is $00 at reset and system-bank for the overwhelming majority of
    // code, so "not provably BW-RAM" is treated as a system bank; a game
    // that defeats that assumption fails S4 verification rather than
    // shipping.
    var dbr_bw = false;
    while (bank < 0x40) : (bank += 1) {
        const bank_file = bank * 0x8000;
        if (bank_file >= image.len) break;
        var a16: u32 = 0x8000;
        ldx_at = null;
        dbr_bw = false;
        while (a16 < 0x10000) : (a16 += 1) {
            const cpu_addr = (bank << 16) | a16;
            const fl_lo = cov[cpu_addr];
            const fl_hi = cov[0x80_0000 | cpu_addr];
            if ((fl_lo | fl_hi) & usage_map.flag_opcode == 0) continue;
            const file = bank_file + (a16 - 0x8000);
            const op = image[file];
            const fl = if (fl_lo & usage_map.flag_opcode != 0) fl_lo else fl_hi;
            const m8 = fl & usage_map.flag_m != 0;
            // Did this instruction actually run? Statically discovered code
            // is rewritten but never refused over (see `static_walk`).
            const covered = (usage[cpu_addr] | usage[0x80_0000 | cpu_addr]) & usage_map.flag_opcode != 0;
            // Executed in both mirrors with different M widths: the site
            // has two shapes and a single helper cannot serve both. Index-
            // register loads (LDY/LDX) size by the X flag instead.
            const m_mixed = fl_lo & usage_map.flag_opcode != 0 and
                fl_hi & usage_map.flag_opcode != 0 and
                (fl_lo ^ fl_hi) & usage_map.flag_m != 0;
            const x_mixed = fl_lo & usage_map.flag_opcode != 0 and
                fl_hi & usage_map.flag_opcode != 0 and
                (fl_lo ^ fl_hi) & usage_map.flag_x != 0;
            const x8 = fl & usage_map.flag_x != 0;
            if (!covered) {
                // Statically discovered code: collect MMIO sites whose shape
                // the proxy supports; count everything unprovable and leave
                // it alone. No proofs are carried out of here, so the
                // register/DBR knowledge dies conservatively.
                ldx_at = null;
                ldy_at = null;
                dbr_bw = false;
                switch (usage_map.mode(op)) {
                    .abs, .abs_x, .abs_y => {
                        const v = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
                        if (v >= 0x2100 and v < 0x4380 and !window) {
                            const kind: ?WgSiteKind = switch (op) {
                                0xAD, 0xBD, 0xB9 => if (m8) WgSiteKind.r8 else .r16,
                                0x8D, 0x9D, 0x99 => if (m8) WgSiteKind.w8 else .w16,
                                0x9C => if (m8) WgSiteKind.stz8 else .stz16,
                                0xCD => if (m8) WgSiteKind.c8 else .c16,
                                0xBC => if (x8) WgSiteKind.ry8 else .ry16,
                                0xBE => if (x8) WgSiteKind.rx8 else .rx16,
                                0x8E => if (x8) WgSiteKind.wx8 else .wx16,
                                0x8C => if (x8) WgSiteKind.wy8 else .wy16,
                                else => null,
                            };
                            const idx: WgIndex = switch (op) {
                                0xBD, 0x9D, 0xBC => .x,
                                0xB9, 0x99, 0xBE => .y,
                                else => .none,
                            };
                            if (kind != null and bank == 0 and !m_mixed and !x_mixed and n_sites < wg_sites_max) {
                                sites[n_sites] = .{ .file = file, .kind = kind.?, .reg = v, .idx = idx };
                                n_sites += 1;
                            } else static_skipped += 1;
                        }
                    },
                    else => switch (op) {
                        // Shapes the dynamic walk would have refused over:
                        // count them so `static_skipped` is an honest tally
                        // of what verification is being trusted with.
                        0x44, 0x54, 0x2B, 0x5B, 0x1B, 0x9A, 0x00, 0x02, 0xDB => static_skipped += 1,
                        else => {},
                    },
                }
                continue;
            }
            switch (op) {
                // MVN/MVP name their banks in the operand, so a move between
                // WRAM banks re-banks like any long access. A move naming
                // bank $00 does not: bank $00 is WRAM below $2000 and ROM
                // above $8000, and which one this move walks is in X/Y at
                // run time. The destination alone would be decidable (ROM is
                // not writable), but re-banking one side of a move and not
                // the other is worse than refusing, so both stay refused.
                0x44, 0x54 => blockmove: {
                    if (!bwram) return refuse(refusal, .{ .reason = .wg_unsupported_op, .detail = cpu_addr });
                    const dst = image[file + 1];
                    const src = image[file + 2];
                    // A move naming the SRAM banks would need the same
                    // normalize-and-rebank treatment with a provable index;
                    // no executed move does it (SM's save code is all
                    // long-addressed), so it refuses rather than guesses.
                    if (game_sram != 0 and
                        ((dst & 0x7F) >= 0x70 and (dst & 0x7F) <= 0x7D or
                            (src & 0x7F) >= 0x70 and (src & 0x7F) <= 0x7D))
                        return refuse(refusal, .{ .reason = .wg_blockmove_source, .detail = cpu_addr });
                    // Destination first, and it is the easy half: bank $00's
                    // only writable memory is WRAM below $2000, so a move
                    // that writes bank $00 is writing WRAM whatever X and Y
                    // hold. $7E/$7F are unambiguous either way.
                    if (!(dst == 0x7E or dst == 0x7F or dst == 0x00))
                        return refuse(refusal, .{ .reason = .wg_unsupported_op, .detail = cpu_addr });
                    if (dst != 0x00) {
                        // Destination $7E/$7F re-banks to $40/$41. The source
                        // needs nothing: another WRAM bank re-banks the same
                        // way, and any other bank is ROM whose mapping is
                        // identical on the SA-1's bus (Gradius III unpacks
                        // graphics with `MVN $7E,$04`, and v17 ships it as
                        // `MVN $40,$04`). Bank $00 as source is the one
                        // ambiguous case — accept it only when X provably
                        // points at ROM, where the byte passes through
                        // unchanged.
                        if (src == 0x00) {
                            const sx = ldx_at != null and cpu_addr - ldx_at.? <= 16;
                            if (!sx or ldx_imm < 0x8000)
                                return refuse(refusal, .{ .reason = .wg_blockmove_source, .detail = cpu_addr });
                        }
                        dbr_bw = true;
                        break :blockmove;
                    }
                    // Bank $00 both sides, so the banks say nothing: X and Y
                    // decide, and only an immediate that reaches here through
                    // straight-line code proves either. Two shapes occur, and
                    // v17 treats them differently because they ARE different:
                    //
                    //   WRAM <- WRAM   re-bank both to $40; the indices are
                    //                  already the right offsets. (The boot
                    //                  WRAM clear.)
                    //   WRAM <- ROM    leave the banks alone — bank $00 still
                    //                  holds the ROM — and shift the
                    //                  destination index into the $6000
                    //                  window instead.
                    if (src != 0x00) return refuse(refusal, .{ .reason = .wg_blockmove_source, .detail = cpu_addr });
                    const sx = ldx_at != null and cpu_addr - ldx_at.? <= 16;
                    if (!sx or n_bm == wg_moves_max or n_moves == wg_moves_max)
                        return refuse(refusal, .{ .reason = .wg_blockmove_source, .detail = cpu_addr });
                    if (ldx_imm < 0x2000) {
                        // WRAM <- WRAM. In window mode the banks STAY $00
                        // and the X immediate shifts into the $6000 window
                        // instead (Y derives from X in the clear idiom, so
                        // it follows): re-banking to $40,$40 would leave
                        // DBR=$40 where stock leaves $00 — and $00 is a
                        // SYSTEM bank, so any MMIO the game does under the
                        // inherited DBR (or any comparison of a saved copy)
                        // forks. Measured on the real cart: a $40 sat on
                        // the stack where stock saved $00, and the title
                        // transition read it back. The SA-1-execution mode
                        // keeps the re-bank (its MMIO is proxied anyway).
                        if (window) {
                            const at = bank_file + ((ldx_at.? & 0xFFFF) - 0x8000) + 1;
                            for (moves[0..n_moves]) |m| {
                                if (m == at) break;
                            } else {
                                moves[n_moves] = at;
                                n_moves += 1;
                            }
                            dbr_bw = false;
                        } else {
                            bm[n_bm] = file;
                            n_bm += 1;
                            dbr_bw = true;
                        }
                    } else if (ldx_imm >= 0x8000) {
                        // WRAM <- ROM. Here the destination index is the
                        // thing that moves, so it does have to be provable.
                        const dy = ldy_at != null and cpu_addr - ldy_at.? <= 16;
                        if (!dy or ldy_imm >= 0x2000)
                            return refuse(refusal, .{ .reason = .wg_blockmove_source, .detail = cpu_addr });
                        moves[n_moves] = ldy_file + 1;
                        n_moves += 1;
                        dbr_bw = false; // DBR stays bank $00
                    } else return refuse(refusal, .{ .reason = .wg_blockmove_source, .detail = cpu_addr });
                },
                0x00, 0x02, 0xDB => return refuse(refusal, .{ .reason = .wg_unsupported_op, .detail = cpu_addr }),
                else => {},
            }
            // Moving WRAM into the BW-RAM window moves the direct page and
            // the stack with it: both live in bank $00's low half, which is
            // exactly the range being displaced by $6000. Every D and S the
            // game installs must therefore be adjustable at build time, so
            // each executed TCD/TCS has to be fed by an adjacent 16-bit
            // `LDA #imm` we can add $6000 to. Anything else — a D or S
            // pulled from the stack or computed — cannot be proven and is
            // refused by name rather than silently left pointing at WRAM
            // that no longer exists on this bus.
            if (bwram) switch (op) {
                0x2B, 0x5B, 0x1B, 0x9A => dpmove: { // PLD, TCD, TCS, TXS
                    const dyn: Reason = if (op == 0x2B or op == 0x5B) .wg_dp_dynamic else .wg_stack_dynamic;
                    // A `PLD` that restores a D some `PHD` pushed — the tail
                    // of every interrupt epilogue — is transparent to the
                    // shift: whatever went on the stack was already shifted,
                    // and comes back the same. Only a `PLD` fed by a pushed
                    // *immediate* establishes a new D, and only that shape
                    // needs rewriting. A PEA does it in one instruction.
                    if (op == 0x2B) {
                        if (file >= 3 and image[file - 3] == 0xF4) {
                            const imm = std.mem.readInt(u16, image[file - 2 ..][0..2], .little);
                            if (imm >= 0x2000) return refuse(refusal, .{ .reason = dyn, .detail = cpu_addr });
                            if (n_moves == wg_moves_max) return refuse(refusal, .{ .reason = dyn, .detail = cpu_addr });
                            moves[n_moves] = file - 2;
                            n_moves += 1;
                            break :dpmove;
                        }
                        const pushed = file >= 1 and
                            (image[file - 1] == 0xDA or image[file - 1] == 0x5A or image[file - 1] == 0x48);
                        const from_imm = pushed and file >= 4 and
                            (image[file - 4] == 0xA2 or image[file - 4] == 0xA0 or image[file - 4] == 0xA9);
                        if (!from_imm) break :dpmove; // restore shape: nothing to do
                    }
                    // Three shapes reach D or S from an immediate, and each
                    // is fed by a register whose load carries its own width
                    // flag: TCD/TCS take A (M), TXS takes X (X), and
                    // `LDX/LDA #imm : PHX/PHA : PLD` — the idiom Gradius III
                    // uses, and the very byte Vilela's v17 patches — reaches
                    // D through the stack. Distance from the immediate's
                    // operand back to this opcode is all that differs.
                    var back: u32 = 3; // LD? #imm | this
                    var want_ld: u8 = 0xA9;
                    var want_w: u8 = usage_map.flag_m;
                    if (op == 0x9A) {
                        want_ld = 0xA2;
                        want_w = usage_map.flag_x;
                    } else if (op == 0x2B) {
                        if (file < 1) return refuse(refusal, .{ .reason = dyn, .detail = cpu_addr });
                        switch (image[file - 1]) { // the push feeding PLD
                            0xDA => { // PHX
                                want_ld = 0xA2;
                                want_w = usage_map.flag_x;
                            },
                            0x5A => { // PHY — Gradius III's main-loop shape
                                want_ld = 0xA0;
                                want_w = usage_map.flag_x;
                            },
                            0x48 => {}, // PHA: defaults
                            else => return refuse(refusal, .{ .reason = dyn, .detail = cpu_addr }),
                        }
                        back = 4; // LD? #imm | PH? | this
                    }
                    if (file < back) return refuse(refusal, .{ .reason = dyn, .detail = cpu_addr });
                    if (image[file - back] != want_ld)
                        return refuse(refusal, .{ .reason = dyn, .detail = cpu_addr });
                    const ld = cpu_addr - back;
                    const lf = cov[ld] | cov[0x80_0000 | ld];
                    // The load must have executed, and in 16-bit width — an
                    // 8-bit load leaves the high half of D/S carrying
                    // whatever was there, which no static shift can follow.
                    if (lf & usage_map.flag_opcode == 0 or lf & want_w != 0)
                        return refuse(refusal, .{ .reason = dyn, .detail = cpu_addr });
                    const imm = std.mem.readInt(u16, image[file - back + 1 ..][0..2], .little);
                    if (imm >= 0x2000 or n_moves == wg_moves_max)
                        return refuse(refusal, .{ .reason = dyn, .detail = cpu_addr });
                    // One immediate can feed two consumers (a TXS and a
                    // later PHX/PLD); shifting it twice would land at
                    // $C000. Record each operand once.
                    const at = file - back + 1;
                    for (moves[0..n_moves]) |m| {
                        if (m == at) break;
                    } else {
                        moves[n_moves] = at;
                        n_moves += 1;
                    }
                },
                else => {},
            };
            // Track X for the block-move source proof. Updated after this
            // instruction's own checks, and before the operand switch below,
            // whose branches `continue`.
            if (bwram) {
                const x16 = fl & usage_map.flag_x == 0;
                // A D argument passed through a call: `LDY/LDX #imm` still
                // live at a `JSR f` where f opens `PHY/PHX : PLD` — the
                // callee establishes D from the caller's immediate, which
                // Gradius III does at every main-loop iteration
                // (`LDY #$1F00 : ... : JSR $9857` / `$9857: PHY : PLD`).
                // The adjacency matcher above cannot see across the call,
                // but the carried immediate can, and v17 confirms the fix:
                // it shifts exactly these immediates.
                if (op == 0x20) jsr: {
                    const t = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
                    if (t < 0x8000) break :jsr;
                    const tf = bank_file + (t - 0x8000);
                    if (tf + 1 >= image.len or image[tf + 1] != 0x2B) break :jsr;
                    const imm_file: u32 = switch (image[tf]) {
                        0x5A => blk: { // PHY : PLD — needs the Y carry
                            const at = ldy_at orelse break :jsr;
                            if (cpu_addr - at > 16 or ldy_imm >= 0x2000) break :jsr;
                            break :blk ldy_file + 1;
                        },
                        0xDA => blk: { // PHX : PLD — the X carry
                            const at = ldx_at orelse break :jsr;
                            if (cpu_addr - at > 16 or ldx_imm >= 0x2000) break :jsr;
                            break :blk bank_file + ((at & 0xFFFF) - 0x8000) + 1;
                        },
                        else => break :jsr,
                    };
                    if (n_moves == wg_moves_max)
                        return refuse(refusal, .{ .reason = .wg_dp_dynamic, .detail = cpu_addr });
                    for (moves[0..n_moves]) |m| {
                        if (m == imm_file) break;
                    } else {
                        moves[n_moves] = imm_file;
                        n_moves += 1;
                    }
                }
                if (op == 0xA2) { // LDX #
                    if (x16) {
                        ldx_at = cpu_addr;
                        ldx_imm = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
                    } else ldx_at = null;
                } else if (writesXOrBranches(op)) ldx_at = null;
                if (op == 0xA0) { // LDY #
                    if (x16) {
                        ldy_at = cpu_addr;
                        ldy_file = file;
                        ldy_imm = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
                    } else ldy_at = null;
                } else if (writesYOrBranches(op)) ldy_at = null;

                // DBR: the `LDA #bank : PHA : PLB` idiom is the only shape
                // that names a bank statically. A WRAM bank there re-banks
                // like any other $7E/$7F reference; anything else leaves DBR
                // system-bank as far as this walk can tell. The knowledge
                // survives conditional branches and DBR-transparent calls
                // (the pin at a routine's head dominates its body); it dies
                // at unconditional transfers — join points another DBR may
                // reach.
                if (!dbrSurvives(image, cov, file, op)) dbr_bw = false;
                if (op == 0xAB) {
                    dbr_bw = false;
                    // Three shapes feed PLB a static bank, and all three
                    // carry the bank byte at file-2: LDA #$7E/PHA/PLB; PLB
                    // directly after PEA (pulls the LOW immediate); the
                    // SECOND PLB of a PEA/PLB/PLB pair (pulls the HIGH —
                    // Super Metroid's boot pins DBR=$7E with PEA $7E00/
                    // PLB/PLB before its eight-stride WRAM clear). The
                    // recorded position re-banks with the other pins.
                    const pinned = (file >= 3 and image[file - 3] == 0xA9 and image[file - 1] == 0x48) or
                        (file >= 4 and
                            (image[file - 3] == 0xF4 or (image[file - 1] == 0xAB and image[file - 4] == 0xF4)));
                    if (pinned) {
                        const b = image[file - 2];
                        if (b == 0x7E or b == 0x7F) {
                            if (n_dbrs == wg_moves_max)
                                return refuse(refusal, .{ .reason = .wg_wram_beyond_bwram, .detail = cpu_addr });
                            dbrs[n_dbrs] = file - 2;
                            n_dbrs += 1;
                            dbr_bw = true;
                        }
                    }
                }
            }

            switch (usage_map.mode(op)) {
                .none, .dp => {},
                .dp_idx => {},
                .abs, .abs_x, .abs_y => {
                    const v = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
                    // With DBR on BW-RAM the operand already names the right
                    // byte of it, whatever its value — no window, no MMIO,
                    // nothing to check.
                    if (bwram and dbr_bw) continue;
                    if (v >= 0x8000) continue; // ROM: identical on both buses
                    if (!bwram and v < 0x800) continue; // I-RAM window: fine as-is
                    if (bwram and v < 0x2000) continue; // rewritten to the window below
                    if (v >= 0x2100 and v < 0x4380) {
                        // Window mode: the game still runs on the S-CPU,
                        // which owns its MMIO — nothing to proxy.
                        if (window) continue;
                        if (bank != 0)
                            return refuse(refusal, .{ .reason = .wg_mmio_outside_bank0, .detail = cpu_addr });
                        const mixed = switch (op) {
                            0xBC, 0xBE, 0x8E, 0x8C => x_mixed,
                            else => m_mixed,
                        };
                        if (mixed)
                            return refuse(refusal, .{ .reason = .wg_mmio_shape, .detail = cpu_addr });
                        const kind: WgSiteKind = switch (op) {
                            0xAD, 0xBD, 0xB9 => if (m8) WgSiteKind.r8 else .r16,
                            0x8D, 0x9D, 0x99 => if (m8) WgSiteKind.w8 else .w16,
                            0x9C => if (m8) WgSiteKind.stz8 else .stz16,
                            // CMP against an MMIO register: an APU-port
                            // handshake spin, in every Konami boot.
                            0xCD => if (m8) WgSiteKind.c8 else .c16,
                            // Index-register loads size by the X flag: the
                            // auto-joypad read loop is LDY $4218,X.
                            0xBC => if (x8) WgSiteKind.ry8 else .ry16,
                            0xBE => if (x8) WgSiteKind.rx8 else .rx16,
                            // ...and index-register stores (STX $2116 sets
                            // the VRAM address in Gradius III's NMI path).
                            0x8E => if (x8) WgSiteKind.wx8 else .wx16,
                            0x8C => if (x8) WgSiteKind.wy8 else .wy16,
                            else => return refuse(refusal, .{ .reason = .wg_mmio_shape, .detail = cpu_addr }),
                        };
                        const idx: WgIndex = switch (op) {
                            0xBD, 0x9D, 0xBC => .x,
                            0xB9, 0x99, 0xBE => .y,
                            else => .none,
                        };
                        if (n_sites == wg_sites_max)
                            return refuse(refusal, .{ .reason = .wg_mmio_shape, .detail = cpu_addr });
                        sites[n_sites] = .{ .file = file, .kind = kind, .reg = v, .idx = idx };
                        n_sites += 1;
                    } else {
                        // Window mode: leave the site native rather than
                        // refuse. If DBR is really WRAM at runtime, the
                        // value re-bank to $40/$41 makes the native absolute
                        // read the moved byte anyway — linear BW-RAM carries
                        // the whole 64 KiB, not just the window's 8 —  and
                        // under any other DBR the read returns what stock's
                        // bus returned (open bus, cart space), except the
                        // window range itself, which verification arbitrates.
                        // Measured on Super Metroid: Ridley's AI does
                        // LDA $7820 under an unproven DBR (open bus on the
                        // stock cart) and refused the whole conversion over
                        // a read the game discards.
                        if (window) continue;
                        return refuse(refusal, .{
                            .reason = if (bwram) Reason.wg_wram_beyond_bwram else .wg_wram_beyond_iram,
                            .detail = cpu_addr,
                        });
                    }
                },
                .long, .long_x => {
                    const b = image[file + 3];
                    const v = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
                    if ((b & 0x7F) <= 0x3F and v >= 0x2100 and v < 0x4380) {
                        if (window) continue; // native MMIO, long-addressed
                        return refuse(refusal, .{ .reason = .wg_mmio_shape, .detail = cpu_addr });
                    }
                    const wram = b == 0x7E or b == 0x7F or ((b & 0x7F) <= 0x3F and v < 0x2000);
                    // BW-RAM carries all of WRAM: $7E/$7F re-bank to $40/$41
                    // and low-bank forms shift into the window, both below.
                    if (wram and !bwram and (b == 0x7F or v >= 0x800))
                        return refuse(refusal, .{ .reason = .wg_wram_beyond_iram, .detail = cpu_addr });
                    // $7E:0000-07FF long sites are re-banked to $00 below.
                },
            }
        }
    }

    var helper_len: u32 = 0;
    // Dedup: sites sharing (kind, reg, idx) share one emitted helper.
    var uniq: [wg_uniq_max]WgSite = undefined;
    var n_uniq: usize = 0;
    for (sites[0..n_sites]) |site| {
        const seen = for (uniq[0..n_uniq]) |u| {
            if (u.kind == site.kind and u.reg == site.reg and u.idx == site.idx) break true;
        } else false;
        if (seen) continue;
        if (n_uniq == wg_uniq_max)
            return refuse(refusal, .{ .reason = .wg_mmio_shape, .detail = site.file });
        uniq[n_uniq] = site;
        n_uniq += 1;
    }
    for (uniq[0..n_uniq]) |u| helper_len += wgHelperLen(u);
    // The scaffolding is bank-$00-only: the shim is the reset vector's
    // target, the service loop is `JMP`ed from it, and CRV/CNV are 16-bit
    // registers, so the SA-1 prologue and NMI shim must be reachable in
    // bank $00 too. The helpers are not: they run on the SA-1, and every
    // absolute they touch (the mailbox, CIE, CIC) mirrors across all system
    // banks, so they can live in ANY bank's padding — which matters, because
    // a real game's bank $00 is nearly full (Gradius III has 1.5 KiB of
    // padding against ~3.6 KiB of helpers). Each unique helper gets a
    // 4-byte `JML` trampoline in bank $00 for the sites' in-place `JSR` to
    // land on; the helper ends with `JML` back to a shared bank-$00 `RTS`.
    const scaffold: u32 = if (window)
        wg_window_shim_max + (if (ml_split != null) split_disp_max else if (win_candidates.len != 0) win_disp_max else 0)
    else
        wg_prologue_len + (if (bwram) @as(u32, wg_prologue_bw_extra) else 0) +
            wg_sa1_nmi_len + wg_scpu_nmi_len +
            @as(u32, wg_service.len) + wg_shim_len;
    var carve: u32 = undefined; // bank $00: scaffold (+ trampolines if split)
    var carve_len: u32 = 0; // what the carve reserves, for the thunk allocator
    var split = false;
    // Split mode: where each helper landed (file offset), first-fit across
    // every bank's largest padding run — helpers are self-contained and the
    // trampolines carry 24-bit targets, so they need not even share a bank.
    var helper_at: [wg_uniq_max]u32 = undefined;
    if (patchgen.findFreeSpace(image[0..header.offset], scaffold + helper_len)) |c| {
        carve = c;
        carve_len = scaffold + helper_len;
    } else {
        split = true;
        const b0_need = scaffold + 4 * @as(u32, @intCast(n_uniq)) + 1;
        carve = patchgen.findFreeSpace(image[0..header.offset], b0_need) orelse
            return refuse(refusal, .{ .reason = .no_free_space, .detail = b0_need });
        carve_len = b0_need;
        // The largest padding run in each bank beyond $00, cursor at its
        // start plus the same 8-byte margin findFreeSpace keeps.
        const Run = struct { cur: u32, end: u32 };
        var bank_runs: [0x40]Run = undefined;
        var n_runs: usize = 0;
        var hb: u32 = 1;
        while (hb * 0x8000 < image.len) : (hb += 1) {
            const base = hb * 0x8000;
            const win = image[base..@min(base + 0x8000, image.len)];
            var best_off: u32 = 0;
            var best_len: u32 = 0;
            var i: usize = 0;
            while (i < win.len) {
                const b = win[i];
                if (b == 0x00 or b == 0xFF) {
                    var j = i + 1;
                    while (j < win.len and win[j] == b) j += 1;
                    if (j - i >= best_len) {
                        best_len = @intCast(j - i);
                        best_off = @intCast(i);
                    }
                    i = j;
                } else i += 1;
            }
            if (best_len > 72) { // margin + at least one helper
                bank_runs[n_runs] = .{ .cur = base + best_off + 8, .end = base + best_off + best_len };
                n_runs += 1;
            }
        }
        // First-fit each helper (+3 for the JML that replaces its RTS).
        for (uniq[0..n_uniq], 0..) |u, ui| {
            const need_h = wgHelperLen(u) + 3;
            helper_at[ui] = for (bank_runs[0..n_runs]) |*r| {
                if (r.end - r.cur >= need_h) {
                    const at = r.cur;
                    r.cur += need_h;
                    break at;
                }
            } else return refuse(refusal, .{ .reason = .no_free_space, .detail = need_h });
        }
    }

    const out = blk: {
        if (win_expand_to <= image.len) break :blk try gpa.dupe(u8, image);
        const grown = try gpa.alloc(u8, win_expand_to);
        @memcpy(grown[0..image.len], image);
        // $FF, because that is the only byte `PadAlloc` and `biggestRun`
        // recognise as free.
        @memset(grown[image.len..], 0xFF);
        // The header must agree with the file, or the loader masks the new
        // banks straight back onto the old ones.
        grown[header.offset + 0x17] = @intCast(std.math.log2_int(u32, win_expand_to / 1024));
        break :blk grown;
    };
    errdefer gpa.free(out);
    var res: Result = .{ .image = out, .stats = .{}, .fate = @splat(.not_attempted) };
    res.stats.cov_static_added = cov_added;
    // DE-MIRROR (images past 2 MiB): on the Super MMC's power-on flat map,
    // the $80-$BF fold lands in image quarters 2/3 — a cyclic MIRROR for a
    // padded <=2 MiB image (why Gradius never noticed), REAL DATA for a
    // 3 MiB one. Super Metroid's own FastROM entry (`JML $80:8573`) fetched
    // quarter-2 bytes and BRK-stormed the boot. Every covered ROM-half
    // reference naming a bank whose content moved is re-banked to where it
    // lives on the SHIM-PROGRAMMED map (region 2 := MB0 restores the
    // $80-$9F mirror; region 3 := MB2): $A0-$BF (mirror-of-MB1 intent) ->
    // $20-$3F; $C0-$DF and $40-$5F (both MB2) -> $A0-$BF. addr16 never
    // changes; $80-$9F references stay native on the genuine mirror.
    var n_demirror: u32 = 0;
    if (image.len > 0x20_0000) {
        var db: u32 = 0;
        while (db < 0x40) : (db += 1) {
            const db_file = db * 0x8000;
            if (db_file >= image.len) break;
            var da: u32 = 0x8000;
            while (da < 0x1_0000) : (da += 1) {
                const dca = (db << 16) | da;
                if ((cov[dca] | cov[0x80_0000 | dca]) & usage_map.flag_opcode == 0) continue;
                const df = db_file + (da - 0x8000);
                const dop = image[df];
                // DBR immediates fold the same way the operands do: the
                // music library pins its data bank with `PEA $A000/PLB/PLB`
                // and reads everything through it — on the shim map $A0
                // carries MB2, so every one of those reads walked the wrong
                // megabyte (measured: the sample-queue builder read the
                // header field at $A0:E275 as $2700 instead of MB1's $BA00,
                // queued seven phantom records banked $C2, and the upload
                // copy never terminated — black screen, input dead). The
                // PLB right after the immediate is what makes the intent
                // unambiguous.
                const dmap = struct {
                    fn m(bk: u8) ?u8 {
                        return if (bk >= 0xA0 and bk <= 0xBF)
                            bk - 0x80
                        else if (bk >= 0xC0 and bk <= 0xDF)
                            bk - 0x20
                        else if (bk >= 0x40 and bk <= 0x5F)
                            bk + 0x60
                        else
                            null;
                    }
                }.m;
                if (dop == 0xF4 and df + 3 < image.len and image[df + 3] == 0xAB) {
                    if (dmap(image[df + 2])) |v| {
                        out[df + 2] = v;
                        n_demirror += 1;
                    }
                    continue;
                }
                if (dop == 0xA9 and (cov[dca] | cov[0x80_0000 | dca]) & usage_map.flag_m != 0 and
                    df + 3 < image.len and image[df + 2] == 0x48 and image[df + 3] == 0xAB)
                {
                    if (dmap(image[df + 1])) |v| {
                        out[df + 1] = v;
                        n_demirror += 1;
                    }
                    continue;
                }
                if (dop == 0xA9 and (cov[dca] | cov[0x80_0000 | dca]) & usage_map.flag_m == 0 and
                    df + 5 < image.len and image[df + 3] == 0x48 and image[df + 4] == 0xAB and
                    image[df + 5] == 0xAB)
                {
                    if (dmap(image[df + 2])) |v| {
                        out[df + 2] = v;
                        n_demirror += 1;
                    }
                    continue;
                }
                const is_long = usage_map.mode(dop) == .long or usage_map.mode(dop) == .long_x or
                    dop == 0x22 or dop == 0x5C;
                if (!is_long or df + 3 >= image.len) continue;
                const dv = std.mem.readInt(u16, image[df + 1 ..][0..2], .little);
                if (dv < 0x8000) continue; // ROM half only; WRAM mirrors keep their arms
                const dbk = image[df + 3];
                const nb: ?u8 = if (dbk >= 0xA0 and dbk <= 0xBF)
                    dbk - 0x80 // mirror-of-MB1 intent: region 3 holds MB2 now
                else if (dbk >= 0xC0 and dbk <= 0xDF)
                    dbk - 0x20 // stock's mirror of $40-$5F: MB2 lives at $A0-$BF
                else if (dbk >= 0x40 and dbk <= 0x5F)
                    dbk + 0x60 // MB2 direct: same relocation
                else
                    null;
                if (nb) |v| {
                    out[df + 3] = v;
                    n_demirror += 1;
                }
            }
        }
    }
    res.stats.rewritten_demirror = n_demirror;
    // The class the coverage-gated pass above structurally cannot see:
    // mirror JSLs at sites no surface and no walk ever reached.
    if (image.len > 0x20_0000)
        res.stats.rewritten_twin_jsls = try demirrorTwinJsls(gpa, image, out, cov);
    res.stats.expanded_to = if (win_expand_to > image.len) win_expand_to else 0;
    {
        var ab: u32 = 0;
        while (ab < 0x40 and ab * 0x8000 < out.len) : (ab += 1) {
            var aa: u32 = 0x8000;
            while (aa < 0x10000) : (aa += 1) {
                const ac = (ab << 16) | aa;
                if ((cov[ac] | cov[0x80_0000 | ac]) & usage_map.flag_opcode == 0) continue;
                res.audit.bank_ops[ab] += 1;
                const af = ab * 0x8000 + (aa - 0x8000);
                switch (out[af]) {
                    0x22, 0x5C => if (af + 3 < out.len) {
                        const tb: u32 = out[af + 3] & 0x7F;
                        if (tb < 0x40) res.audit.bank_calls[tb] += 1;
                    },
                    0x6C => res.audit.n_ind_abs += 1,
                    0x7C, 0xFC => res.audit.n_ind_absx += 1,
                    0xDC => res.audit.n_ind_long += 1,
                    0x44, 0x54 => if (af + 2 < out.len) { // MVN/MVP: dst, src
                        for ([2]u8{ out[af + 1], out[af + 2] }) |mb|
                            if ((mb & 0x7F) < 0x40) {
                                res.audit.bank_data[mb & 0x7F] += 1;
                            };
                    },
                    else => switch (usage_map.mode(out[af])) {
                        .long, .long_x => if (af + 3 < out.len) {
                            const db: u32 = out[af + 3] & 0x7F;
                            if (db < 0x40) res.audit.bank_data[db] += 1;
                        },
                        else => {},
                    },
                }
            }
        }
    }
    res.stats.static_skipped = static_skipped;

    // Re-bank $7E long sites into the identity window (bank $7E does not
    // exist on the SA-1 bus; bank $00's low $0800 is the same I-RAM).
    bank = 0;
    // Context-split sites collected for thunking (see Stats.split_sites);
    // patched after the pass, once the bank-0 carve is paintable.
    var thunks: [split_thunk_max]struct { file: u32, v: u16, op: u8 } = undefined;
    var n_thunks: usize = 0;
    // Index-split sites (tiny base, measured low|rom or NOT MEASURED AT
    // ALL): dispatched on the index register's magnitude instead of the DBR.
    // Index-split sites in LONG,X form. Separate because the site is four
    // bytes (a `JSL`, not a `JSR`) and the body's operand carries a bank.
    var lthunks: [idx_thunk_max]struct { file: u32, v: u16, op: u8, bank: u8 } = undefined;
    var n_lthunks: usize = 0;
    // `pin`: the site has NO evidence, so a caller pinned to $40/$41 is
    // still possible and the thunk must test the data bank. A site whose
    // measurement already excludes the pin takes the short body.
    var ithunks: [idx_thunk_max]struct { file: u32, v: u16, op: u8, pin: bool } = undefined;
    var n_ithunks: usize = 0;
    // CELL COHERENCE (window mode): per-site evidence decisions can split
    // one cell's accessor population — gameplay evidence shifted a sound
    // cell's readers while its pinned writers stayed, and the two homes
    // diverged at the title-music handoff. The invariant is per CELL, not
    // per site: collect, for every unindexed absolute operand below
    // $2000, the union of its sites' evidence classes plus whether any
    // site reaches it under a re-banked WRAM pin. A pinned accessor is
    // STUCK at the BW-RAM home (its unshifted operand under DBR $40/$41
    // is bwram[v]), so a {low, bank} cell's home is forced there and the
    // unpinned sites SHIFT to follow, whatever their own class mix.
    var cell_ev: [0x2000]u8 = @splat(0);
    var cell_pinned: [0x2000]bool = @splat(false);
    if (bwram and window) {
        var pbank: u32 = 0;
        while (pbank < 0x40) : (pbank += 1) {
            const pbf = pbank * 0x8000;
            if (pbf >= out.len) break;
            var pa: u32 = 0x8000;
            var p_dbr_bw = false;
            while (pa < 0x10000) : (pa += 1) {
                const pca = (pbank << 16) | pa;
                if ((cov[pca] | cov[0x80_0000 | pca]) & usage_map.flag_opcode == 0) continue;
                const pf = pbf + (pa - 0x8000);
                const pop = out[pf];
                if (usage_map.mode(pop) == .abs) {
                    const pv = std.mem.readInt(u16, out[pf + 1 ..][0..2], .little);
                    if (pv < 0x2000) {
                        if (p_dbr_bw) {
                            cell_pinned[pv] = true;
                        } else {
                            const pe: u8 = if (site_evidence) |s| s[pca] | s[0x80_0000 | pca] else 0;
                            cell_ev[pv] |= pe;
                        }
                    }
                }
                if (!dbrSurvives(out, cov, pf, pop)) p_dbr_bw = false;
                if (pop == 0xAB) {
                    p_dbr_bw = ((pf >= 3 and out[pf - 3] == 0xA9 and out[pf - 1] == 0x48) or
                        (pf >= 4 and
                            (out[pf - 3] == 0xF4 or (out[pf - 1] == 0xAB and out[pf - 4] == 0xF4)))) and
                        (out[pf - 2] == 0x7E or out[pf - 2] == 0x7F);
                } else if (pop == 0x44 or pop == 0x54) {
                    const d0 = out[pf + 1];
                    p_dbr_bw = d0 == 0x7E or d0 == 0x7F or (d0 == 0x00 and for (bm[0..n_bm]) |f| {
                        if (f == pf) break true;
                    } else false);
                }
            }
        }
    }
    while (bank < 0x40) : (bank += 1) {
        const bank_file = bank * 0x8000;
        if (bank_file >= out.len) break;
        var a16: u32 = 0x8000;
        // Same DBR reasoning as the eligibility walk, replayed here because
        // the shift an absolute site needs depends on it. Read before this
        // pass mutates the site; the DBR immediates themselves are rewritten
        // after the loop so the idiom is still recognisable while it runs.
        dbr_bw = false;
        while (a16 < 0x10000) : (a16 += 1) {
            const cpu_addr = (bank << 16) | a16;
            if ((cov[cpu_addr] | cov[0x80_0000 | cpu_addr]) & usage_map.flag_opcode == 0) continue;
            const file = bank_file + (a16 - 0x8000);
            const op = out[file];
            if (codeMapForbids(cpu_addr)) {
                res.stats.skipped_overlap += 1;
                continue;
            }
            if (bwram and codeMapAt(cpu_addr) & cm_wram_pointer != 0) {
                // A stored immediate the disassembly names with a WRAM label
                // (see `cm_wram_pointer`): the value moves with the window.
                const fl_p = if (cov[cpu_addr] & usage_map.flag_opcode != 0) cov[cpu_addr] else cov[0x80_0000 | cpu_addr];
                const wide = switch (op) {
                    0xA9 => fl_p & usage_map.flag_m == 0,
                    0xA2, 0xA0 => fl_p & usage_map.flag_x == 0,
                    0xF4 => true,
                    else => false,
                };
                if (wide and file + 2 < out.len) {
                    const pv = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                    if (pv < 0x2000) {
                        std.mem.writeInt(u16, out[file + 1 ..][0..2], pv + wg_bw_window, .little);
                        res.stats.rewritten_map_pointers += 1;
                    }
                }
            }
            // Two opcodes cannot overlap. A site whose operand bytes carry
            // an opcode flag of their own is a decode that started inside
            // another instruction — a stale flag from a cover harvested
            // on an image whose code lay elsewhere, or a static path that
            // arrived mid-instruction — and rewriting its "operand" would
            // corrupt the real instruction after it. MEASURED on Super
            // Metroid: `$FC $8D $17` (the immediate of `AND #$FC` and the
            // `STA $2117` after it) carried an opcode flag on the `$FC`,
            // decoded as `JSR ($178D,X)`, and the window shift turned the
            // store into `STA $2177` — the APU mailbox mirror. Four sites,
            // every patch from v66 to v68, the sound driver dead on the
            // first one a session reached. Skip the overlapping site; the
            // instruction it overlaps is the one the profile proved.
            {
                const fl_site = if (cov[cpu_addr] & usage_map.flag_opcode != 0) cov[cpu_addr] else cov[0x80_0000 | cpu_addr];
                const site_len = usage_map.instrLen(op, fl_site & usage_map.flag_m != 0, fl_site & usage_map.flag_x != 0);
                var overlap = false;
                var k: u32 = 1;
                while (k < site_len and a16 + k < 0x10000) : (k += 1) {
                    const ic = cpu_addr + k;
                    if ((cov[ic] | cov[0x80_0000 | ic]) & usage_map.flag_opcode != 0) overlap = true;
                }
                if (overlap) {
                    res.stats.skipped_overlap += 1;
                    continue;
                }
            }
            if (bwram) {
                // A WRAM bank byte materialized by an immediate and stored —
                // the bank slot of a long pointer the game will dereference
                // at run time (`LDA #$7E : STA $05` builds [$03] = $7E:xxxx
                // in Gradius III's decompressor). The pointer VALUE is
                // runtime data no static rewrite can reach, but its bank
                // byte comes from this immediate, and $40 names the same
                // bytes. The store opcode is checked against the coverage
                // map, so this never fires mid-instruction. v17 rewrites
                // exactly these immediates (and none of the arithmetic uses
                // of the constant $7E, which have no adjacent store).
                if (op == 0xA9 and (out[file + 1] == 0x7E or out[file + 1] == 0x7F)) {
                    const fl2 = if (cov[cpu_addr] & usage_map.flag_opcode != 0) cov[cpu_addr] else cov[0x80_0000 | cpu_addr];
                    const next = cpu_addr + 2;
                    const next_op = (cov[next] | cov[0x80_0000 | next]) & usage_map.flag_opcode != 0;
                    if (fl2 & usage_map.flag_m != 0 and next_op and file + 2 < out.len and
                        (out[file + 2] == 0x85 or out[file + 2] == 0x8D or
                            out[file + 2] == 0x8F or out[file + 2] == 0x9F))
                    {
                        out[file + 1] -= 0x3E;
                        res.stats.rewritten_long += 1;
                    }
                    // The 16-BIT form of the same idiom. Two shapes carry
                    // a bank in a 16-bit immediate: `LDA #$007E : STA
                    // $43x4` (a DMA source bank — the boot logo) and
                    // `LDA #$007E : STA $7E:xxxx,X` (the bank WORD of a
                    // far-pointer queue entry — the title's DMA queue
                    // builder at $00:8EBB). The store's shape names the
                    // semantics; a random 16-bit $007E is a coordinate
                    // and stays.
                    const fl16 = if (cov[cpu_addr] & usage_map.flag_opcode != 0) cov[cpu_addr] else cov[0x80_0000 | cpu_addr];
                    if (fl16 & usage_map.flag_m == 0 and out[file + 2] == 0x00 and
                        file + 6 < out.len)
                    {
                        const st = out[file + 3];
                        const bank_word = switch (st) {
                            0x8D => blk: {
                                const tgt = std.mem.readInt(u16, out[file + 4 ..][0..2], .little);
                                break :blk tgt >= 0x4304 and tgt <= 0x4374 and (tgt & 0xF) == 4;
                            },
                            // A long store into WRAM ($7E/$7F pre-rewrite):
                            // the immediate is the bank word of whatever
                            // entry is being built there.
                            0x8F, 0x9F => out[file + 6] == 0x7E or out[file + 6] == 0x7F,
                            else => false,
                        };
                        if (bank_word) {
                            out[file + 1] -= 0x3E;
                            res.stats.rewritten_long += 1;
                        }
                    }
                }
                if (!dbrSurvives(out, cov, file, op)) dbr_bw = false;
                if (op == 0xAB) {
                    // Three idioms feed PLB a WRAM bank: LDA #$7E/PHA/PLB;
                    // PLB directly after PEA (pulls the LOW immediate byte);
                    // and the SECOND PLB of a PEA/PLB/PLB pair (pulls the
                    // HIGH byte — Super Metroid's boot: PEA $7E00/PLB/PLB
                    // before its eight-stride WRAM clear). Both PEA shapes
                    // test the same operand index.
                    dbr_bw = (file >= 3 and out[file - 3] == 0xA9 and out[file - 1] == 0x48 and
                        (out[file - 2] == 0x7E or out[file - 2] == 0x7F)) or
                        (file >= 4 and
                            (out[file - 3] == 0xF4 or (out[file - 1] == 0xAB and out[file - 4] == 0xF4)) and
                            (out[file - 2] == 0x7E or out[file - 2] == 0x7F));
                } else if (op == 0x44 or op == 0x54) {
                    // Only a move whose destination becomes BW-RAM leaves
                    // DBR there; the ROM-source shape keeps bank $00.
                    const d0 = out[file + 1];
                    dbr_bw = d0 == 0x7E or d0 == 0x7F or (d0 == 0x00 and for (bm[0..n_bm]) |f| {
                        if (f == file) break true;
                    } else false);
                }
            }
            switch (usage_map.mode(op)) {
                .long, .long_x => {
                    const b = out[file + 3];
                    const v = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                    const le: u8 = if (site_evidence) |s| s[cpu_addr] | s[0x80_0000 | cpu_addr] else 0;
                    if (bwram) {
                        // $7E/$7F are not on the SA-1's bus; $40/$41 are the
                        // same bytes of BW-RAM, at the same offsets — and
                        // identity-offset, so an index carries over.
                        if (b == 0x7E or b == 0x7F) {
                            out[file + 3] = b - 0x3E;
                            res.stats.rewritten_long += 1;
                            auditNote(&res.audit, file, op, v, le, .rebanked);
                        } else if (b == 0x7D and v >= 0xFF00) {
                            // The NEGATIVE-OFFSET idiom: `SBC $7D:FFFB,X`
                            // wraps through the bank boundary into
                            // $7E:0000+X-5 — entry-relative backward reach
                            // into a WRAM queue (the title's DMA queue
                            // reads its previous entry this way). $3F
                            // wraps into $40 the same distance.
                            out[file + 3] = 0x3F;
                            res.stats.rewritten_long += 1;
                            auditNote(&res.audit, file, op, v, le, .rebanked);
                        } else if (game_sram != 0 and (b & 0x7F) >= 0x70 and
                            (b & 0x7F) <= 0x7D and v < 0x8000)
                        {
                            // Battery SRAM relocates above the WRAM image:
                            // BW-RAM offset $20000 = bank $42. The offset is
                            // normalized by the chip's own mirror mask, so
                            // the distinct-looking bases the game aims at
                            // one mirrored chip ($70:0000 vs $70:2000)
                            // still alias after the move. An indexed site's
                            // reach past the mirror is not reproduced —
                            // the observed idiom keeps its index inside one
                            // image (SM's probe loop counts $1FFE down) and
                            // S4 verification arbitrates the rest.
                            const off = ((@as(u32, b & 0x0F) << 15) | v) & (game_sram - 1);
                            std.mem.writeInt(u16, out[file + 1 ..][0..2], @intCast(off), .little);
                            out[file + 3] = 0x42;
                            res.stats.rewritten_sram += 1;
                            auditNote(&res.audit, file, op, v, le, .rebanked);
                        } else if ((b & 0x7F) <= 0x3F and v < 0x2000 and
                            (usage_map.mode(op) == .long or blk: {
                                // Indexed long through a system bank is
                                // undecidable statically (`LDA $01:0000,X`
                                // with a big X walks a ROM table; the same
                                // shape with a small X walks the mirror) —
                                // measured evidence decides: shift only a
                                // site whose observed traffic was all low
                                // WRAM. Unindexed is WRAM for certain.
                                const e: u8 = if (site_evidence) |s| s[cpu_addr] | s[0x80_0000 | cpu_addr] else 0;
                                break :blk e != 0 and e == usage_map.site_wram_low;
                            }))
                        {
                            std.mem.writeInt(u16, out[file + 1 ..][0..2], v + wg_bw_window, .little);
                            res.stats.rewritten_long += 1;
                            auditNote(&res.audit, file, op, v, le, .shifted);
                        } else if (window and usage_map.mode(op) == .long_x and
                            (b & 0x7F) <= 0x3F and (v < 0x100 or v >= 0xFF00))
                        {
                            // NO evidence test. Reaching here already means
                            // the site is not provably pure-low (that case
                            // shifted statically above), and every other
                            // reading of the evidence has now been wrong at
                            // least once. `$00:911D` and `$00:9155` measured
                            // ROM-ONLY across five surfaces and two cover
                            // harvests, were left alone on that authority,
                            // and read the mirror on the boss path — inside
                            // an offloaded copy, where the mirror is the
                            // SA-1's own I-RAM. Evidence that never saw the
                            // mirror is not proof there is no mirror, and
                            // the thunk is correct in BOTH worlds, so it is
                            // the answer whenever the shape is ambiguous.
                            // The index-split class in the addressing mode
                            // the absolute thunk cannot reach. Same idiom,
                            // same ambiguity — `LDA $03:0000,X` is the slot
                            // walker's chain-follow with a small X and a ROM
                            // table walk with a big one — but the site is
                            // FOUR bytes, so `JSL` fits where `JSR` did not,
                            // and a long call names its own bank: these
                            // thunks need no bank-local home at all.
                            //
                            // MEASURED low|rom SITES INCLUDED, and the
                            // history of that decision is worth keeping.
                            // These were excluded once, because thunking
                            // the walker's three reads at $00:90AE-C4 puts
                            // a JSL/RTL — some thirty cycles — in the
                            // hottest loop the game has, and doing so
                            // "broke" the behavioural verdict. It did not:
                            // that failure was the tier calling a faster
                            // conversion hung, and the evidence for the
                            // exclusion evaporated with the tier fix.
                            //
                            // Including them is what makes the PHYSICS TREE
                            // eligible. `$00:90AE` is the single line the
                            // eligibility walk refuses $8EF1 over — an
                            // unshifted low-mirror indexed long is the
                            // SA-1's own I-RAM — and the thunk removes the
                            // hazard by construction: its window arm is the
                            // identity window (same bytes on both buses)
                            // and its as-written arm only runs when the
                            // index has already carried the address past
                            // $2000. Thirty cycles at three sites against a
                            // tree worth 48% utilisation down to ~17% is
                            // not a close trade.
                            //
                            // Only the index is in question here. A long
                            // access carries its bank in the operand, so DBR
                            // is not consulted and the three worlds collapse
                            // to two: small index -> the window (mirrored in
                            // every system bank), huge index -> as written.
                            if (n_lthunks == idx_thunk_max)
                                return refuse(refusal, .{ .reason = .wg_split_overflow, .detail = cpu_addr });
                            lthunks[n_lthunks] = .{ .file = file, .v = v, .op = op, .bank = b };
                            n_lthunks += 1;
                            auditNote(&res.audit, file, op, v, le, .thunk_index);
                        } else if ((b & 0x7F) <= 0x3F and (v < 0x2000 or
                            (usage_map.mode(op) == .long_x and v >= 0xFF00)))
                        {
                            // An indexed long through a system bank whose
                            // evidence did not clear it, in a shape the
                            // thunk does not serve (a base too big to be the
                            // pointer idiom): the mirror and a ROM table
                            // share it, and nothing here decides between
                            // them.
                            auditNote(&res.audit, file, op, v, le, if (le == 0)
                                .left_unproven
                            else if (le & usage_map.site_wram_low != 0)
                                .left_mixed
                            else
                                .left_rom);
                        } else {
                            auditNote(&res.audit, file, op, v, le, .left_high);
                        }
                    } else if (b == 0x7E and v < 0x800) {
                        out[file + 3] = 0x00;
                        res.stats.rewritten_long += 1;
                    }
                },
                .abs, .abs_x, .abs_y => if (bwram and dbr_bw and
                    (if (site_evidence) |s| (s[cpu_addr] | s[0x80_0000 | cpu_addr]) & usage_map.site_wram_low == 0 else true))
                {
                    // Skipped because the data bank is provably BW-RAM
                    // here. Audited rather than silent: the pin comes from
                    // a static tracker, and a wrong pin leaves a live site
                    // addressing the abandoned home.
                    const v = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                    const pe: u8 = if (site_evidence) |s| s[cpu_addr] | s[0x80_0000 | cpu_addr] else 0;
                    auditNote(&res.audit, file, op, v, pe, if (v < 0x2000) .left_pinned else .left_high);
                } else if (bwram) {
                    const v = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                    // Measured evidence first: a site whose observed data
                    // traffic was ALL low-WRAM shifts; a site that ever
                    // reached ROM, MMIO, or bank $7E/$7F (DBR-mediated —
                    // it follows the re-banked idiom) stays. Only sites
                    // with no recorded traffic fall back to the static
                    // heuristic: a TINY base under an index is the "X is
                    // the pointer" idiom (the title's display-list walker
                    // reads $01:8000+X via `LDY $0000,X`) and stays; real
                    // table bases shift.
                    const e: u8 = if (site_evidence) |s| s[cpu_addr] | s[0x80_0000 | cpu_addr] else 0;
                    // A CONTEXT-SPLIT single site: THIS instruction was
                    // measured under both a system DBR and a WRAM pin, so
                    // no single operand serves its two callers and no
                    // per-cell home argument applies either — the site
                    // becomes a JSR to a DBR-dispatching thunk.
                    // NOTE, measured 2026-08-17: widening this to any
                    // evidence NAMING the bank (`bank` alone as well as
                    // `low|bank`) is the obvious generalisation and it
                    // breaks the offload trees. Sites measured only under a
                    // pin are exactly what a pinned tree is full of, and a
                    // JSR thunk is not portable into a tree COPY — the copy
                    // runs in another bank, where the bank-relative JSR
                    // lands on garbage, so the eligibility walk refuses the
                    // tree outright. The `long,X` flavor escapes this
                    // because JSL names its own bank; this one needs
                    // copy-local thunk emission first.
                    // ... and a site the static pin CLAIMS is BW-RAM-banked
                    // but whose measured traffic includes the system mirror is
                    // the same split, proven from the other side: the pin
                    // holds on one path, the mirror evidence on another, and
                    // only the runtime DBR can tell them apart (measured:
                    // Super Metroid's room loader reads its state cells via
                    // `LDA $0000,X` under a mirror DBR at the door
                    // transition; the pin left the sites stock and the room
                    // state loaded stale — black screen, input dead).
                    if (window and v < 0x2000 and
                        (e == usage_map.site_wram_low | usage_map.site_wram_bank or
                            (dbr_bw and e & usage_map.site_wram_low != 0)))
                    {
                        if (n_thunks == split_thunk_max)
                            return refuse(refusal, .{ .reason = .wg_split_overflow, .detail = cpu_addr });
                        thunks[n_thunks] = .{ .file = file, .v = v, .op = op };
                        n_thunks += 1;
                        auditNote(&res.audit, file, op, v, e, .thunk_dbr);
                        continue;
                    }
                    // A site SPLIT ON ITS INDEX: a tiny-base indexed abs
                    // measured reading BOTH the WRAM-low mirror (small
                    // index — the operand really is a data base) and ROM
                    // (huge index — "X is the pointer"). One operand
                    // cannot serve both (measured: Gradius III's level-
                    // script walker `LDA $0003,Y` reads spawn records at
                    // dp offsets AND walks ROM through the same bytes —
                    // left unshifted, every stage-1 enemy wave silently
                    // failed to spawn: transient content diverges in runs
                    // shorter than the persistence budget, so the tier
                    // never saw it). The site becomes a JSR to a thunk
                    // that dispatches on the index register's magnitude.
                    // LDA shapes only: the thunk scratches A, which the
                    // load overwrites anyway. The recorded x-width is NOT
                    // trusted (last-run only); the thunk dispatches on
                    // the caller's live X flag.
                    //
                    // UNMEASURED sites take the thunk too, and that is the
                    // point of it. A tiny-base indexed absolute the profile
                    // never reached used to be left in place on the "X is
                    // the pointer" hunch — which is right for a ROM walk and
                    // WRONG for a data base, and the wrong half writes into
                    // the WRAM the window abandoned, silently. Measured on
                    // the real cart: `STA $0030,Y` at $02:8C8B stored the
                    // laser's collision record to dead memory, so the beam
                    // passed through everything it hit. The thunk decides at
                    // run time and is right in both worlds; the price is a
                    // JSR/RTS per access. `--wg-static` is what puts those
                    // sites in coverage in the first place.
                    const im = usage_map.mode(op);
                    // A real table base whose index was measured both in
                    // the table and past it (see `idxThunkBodyWrap`): the
                    // pointer-idiom rule below never admits it (v >= $100)
                    // and the evidence rule would leave it as written.
                    const wrap_mixed = window and v >= 0x100 and v <= 0x1F00 and
                        (im == .abs_x or im == .abs_y) and
                        e & usage_map.site_wram_low != 0 and
                        e & usage_map.site_wram_bank == 0 and
                        e != usage_map.site_wram_low;
                    if (wrap_mixed or (window and v < 0x100 and (im == .abs_x or im == .abs_y) and
                        (e == 0 or e == usage_map.site_wram_low | usage_map.site_rom)))
                    {
                        if (n_ithunks == idx_thunk_max)
                            return refuse(refusal, .{ .reason = .wg_split_overflow, .detail = cpu_addr });
                        ithunks[n_ithunks] = .{ .file = file, .v = v, .op = op, .pin = e == 0 };
                        n_ithunks += 1;
                        auditNote(&res.audit, file, op, v, e, .thunk_index);
                        continue;
                    }
                    // Cell coherence (unindexed, single-context site): a
                    // {low, bank} CELL's home is BW-RAM — its pinned
                    // accessors are stuck there — so this unpinned site
                    // shifts to follow even when its own measured class
                    // says "stay" (distinct sites carried the two
                    // classes; the collection pass above unioned them).
                    // ... except a site whose OWN traffic is bank-mediated:
                    // its unshifted operand under the re-banked DBR ($40/$41)
                    // already resolves to the BW-RAM home — shifting it lands
                    // on window+$6000, a different byte entirely (measured:
                    // $01:811D `STA $078B` under a $7E-pulled bank, shifted to
                    // $678B by this pass, zeroed the projectile slot-list
                    // words every frame; the door transition then indexed its
                    // room table with garbage and the screen faded for good).
                    const cell_move = window and usage_map.mode(op) == .abs and v < 0x2000 and
                        e & usage_map.site_wram_bank == 0 and blk: {
                        const ce = cell_ev[v] | e;
                        const has_low = ce & usage_map.site_wram_low != 0;
                        const has_bank = ce & usage_map.site_wram_bank != 0 or cell_pinned[v];
                        const has_other = ce & (usage_map.site_rom | usage_map.site_other) != 0;
                        break :blk !has_other and has_low and has_bank;
                    };
                    const shift_it = cell_move or if (e != 0)
                        e == usage_map.site_wram_low
                    else
                        usage_map.mode(op) == .abs or v >= 0x100;
                    if (v >= 0x2000) {
                        auditNote(&res.audit, file, op, v, e, .left_high);
                    } else if (!shift_it) {
                        auditNote(&res.audit, file, op, v, e, if (e == 0)
                            .left_unproven
                        else if (e & usage_map.site_wram_low != 0)
                            .left_mixed
                        else
                            .left_rom);
                    } else {
                        std.mem.writeInt(u16, out[file + 1 ..][0..2], v + wg_bw_window, .little);
                        res.stats.rewritten_abs += 1;
                        auditNote(&res.audit, file, op, v, e, .shifted);
                    }
                },
                // Indirect control flow reads its *pointer* from bank $00:
                // `JMP ($0000)` names a WRAM word that just moved into the
                // window, and mode() files these as .none because the
                // operand is not a data address the offload rewriter cares
                // about. Here it is exactly a data address. JMP (abs) and
                // JMP/JSR (abs,X) pointers under $2000 shift with their
                // memory; [abs] (JML) reads 3 bytes but shifts the same way.
                .none => if (bwram) switch (op) {
                    0x6C, 0x7C, 0xFC, 0xDC => {
                        const v = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                        // The INDEXED forms carry the same disease as
                        // indexed data: `JSR ($0000,X)` with X holding a
                        // full ROM param pointer reads its vector from ROM
                        // (measured: Super Metroid's intro-script spawner,
                        // $8B:9517 — the blind shift sent every spawn
                        // through garbage and the intro never started).
                        // Evidence decides the indexed forms: a site whose
                        // measured pointer reads were ROM stays put;
                        // WRAM-low or unmeasured shifts (the measured
                        // unindexed idiom is a WRAM word for certain).
                        const e: u8 = if (op == 0x6C or op == 0xDC)
                            0
                        else if (site_evidence) |s|
                            s[cpu_addr] | s[0x80_0000 | cpu_addr]
                        else
                            0;
                        if (v < 0x2000 and (e == 0 or e & usage_map.site_rom == 0)) {
                            std.mem.writeInt(u16, out[file + 1 ..][0..2], v + wg_bw_window, .little);
                            res.stats.rewritten_abs += 1;
                        }
                    },
                    // MVN/MVP: $7E/$7F re-bank like any long access, and
                    // bank $00 re-banks only where the walk proved both
                    // halves (the sites it recorded in `bm`).
                    0x44, 0x54 => {
                        const proved = for (bm[0..n_bm]) |f| {
                            if (f == file) break true;
                        } else false;
                        for (1..3) |k| {
                            const b = out[file + k];
                            if (b == 0x7E or b == 0x7F) {
                                out[file + k] = b - 0x3E;
                                res.stats.rewritten_long += 1;
                            } else if (b == 0x00 and proved) {
                                out[file + k] = 0x40;
                                res.stats.rewritten_long += 1;
                            }
                        }
                    },
                    else => {},
                },
                else => {},
            }
        }
    }
    // Data bank loads follow their memory too: a game that sets DBR to $7E
    // is naming WRAM, which is now $40.
    for (dbrs[0..n_dbrs]) |off| {
        out[off] -= 0x3E;
        res.stats.rewritten_long += 1;
    }
    // The dispatch macro `STA $00 / JMP ($0000)` — BY SIGNATURE, coverage
    // or not. GIII stamps this five-byte idiom ~140 times across three
    // banks and the coverage-gated pointer-shift rule reaches only the
    // few dozen the profiled surfaces execute; every uncovered sibling is
    // a landmine (measured twice on the full-cycle tail: the first
    // uncovered site read its pointer from dead real WRAM and BRK-stormed
    // at f4640; with that one fixed by a coverage pad, the NEXT one
    // halted the S-CPU on an STP inside ROM data at ~f6500 — post-fork
    // trajectories visit sites no finite stock profile can lead). The
    // signature is specific enough that a data collision is negligible,
    // and a covered site is naturally skipped: its operand is already
    // $6000, which no longer matches.
    if (bwram) {
        var f: u32 = 0;
        while (f + 5 <= out.len) : (f += 1) {
            if (out[f] == 0x85 and out[f + 1] == 0x00 and out[f + 2] == 0x6C and
                out[f + 3] == 0x00 and out[f + 4] == 0x00)
            {
                std.mem.writeInt(u16, out[f + 3 ..][0..2], wg_bw_window, .little);
                res.stats.rewritten_abs += 1;
            }
        }
    }
    if (bwram) res.stats.rewritten_queue_imms += demirrorQueueBankImms(out, out.len > 0x20_0000);
    if (bwram) res.stats.rewritten_wmdata_fills += relocateWmdataFills(out, out.len > 0x20_0000);
    // Measured pointer-bank sources: table bytes (and immediate operands
    // the shape pass above didn't already reach) that carry $7E/$7F into
    // runtime pointers. The byte may sit anywhere in ROM; the proof it is
    // a bank byte is dynamic, so the only static check left is that it
    // still holds $7E/$7F (the shape pass may have re-banked it first).
    if (bwram) if (ptr_ev) |pe| {
        for (pe.proven[0..pe.n_proven]) |ca| {
            const src_bank: u32 = (ca >> 16) & 0x7F;
            const a16: u32 = ca & 0xFFFF;
            if (a16 < 0x8000) continue;
            const f = src_bank * 0x8000 + (a16 - 0x8000);
            if (f >= out.len) continue;
            if (out[f] == 0x7E or out[f] == 0x7F) {
                out[f] -= 0x3E;
                res.stats.rewritten_ptr_banks += 1;
            }
        }
        // dp,X pointer words: the recorded address names the word's LAST
        // byte. Only a word still naming something beyond the moved low
        // 8 KiB is rewritten — the window offset pre-subtracted, so the
        // relocated direct page wraps back onto the original target.
        for (pe.idx_proven[0..pe.n_idx]) |ca| {
            const src_bank: u32 = (ca >> 16) & 0x7F;
            const a16: u32 = ca & 0xFFFF;
            if (a16 < 0x8001) continue;
            const f = src_bank * 0x8000 + (a16 - 0x8000);
            if (f >= out.len or f == 0) continue;
            const word = std.mem.readInt(u16, out[f - 1 ..][0..2], .little);
            if (word >= 0x2000) {
                std.mem.writeInt(u16, out[f - 1 ..][0..2], word -% wg_bw_window, .little);
                res.stats.rewritten_idx_words += 1;
            }
        }
        // $C0-$DF bank values: the Super MMC misfit banks — content lives
        // $20 lower in the converted image (the de-mirror map's home).
        for (pe.hi_proven[0..pe.n_hi]) |ca| {
            const src_bank: u32 = (ca >> 16) & 0x7F;
            const a16: u32 = ca & 0xFFFF;
            if (a16 < 0x8000) continue;
            const f = src_bank * 0x8000 + (a16 - 0x8000);
            if (f >= out.len) continue;
            if (out[f] >= 0xC0 and out[f] <= 0xDF) {
                out[f] -= 0x20;
                res.stats.rewritten_hi_banks += 1;
            }
        }
        // $A0-$BF bank values: stock's MB1 mirror — content lives $80
        // lower in the converted image.
        for (pe.a0_proven[0..pe.n_a0]) |ca| {
            const src_bank: u32 = (ca >> 16) & 0x7F;
            const a16: u32 = ca & 0xFFFF;
            if (a16 < 0x8000) continue;
            const f = src_bank * 0x8000 + (a16 - 0x8000);
            if (f >= out.len) continue;
            if (out[f] >= 0xA0 and out[f] <= 0xBF) {
                out[f] -= 0x80;
                res.stats.rewritten_a0_banks += 1;
            }
        }
        // DMA A-bus address words: staged transfer sources naming the
        // moved low 8 KiB through a system bank. The recorded address
        // names the word's LAST byte; only a word still below $2000
        // moves — pre-shifted +$6000 so the fired channel follows its
        // buffer into the window.
        for (pe.dma_addr_proven[0..pe.n_dma_addr]) |ca| {
            const src_bank: u32 = (ca >> 16) & 0x7F;
            const a16: u32 = ca & 0xFFFF;
            if (a16 < 0x8001) continue;
            const f = src_bank * 0x8000 + (a16 - 0x8000);
            if (f >= out.len or f == 0) continue;
            const word = std.mem.readInt(u16, out[f - 1 ..][0..2], .little);
            if (word < 0x2000) {
                std.mem.writeInt(u16, out[f - 1 ..][0..2], word +% wg_bw_window, .little);
                res.stats.rewritten_dma_addrs += 1;
            }
        }
    };
    // Data no evidence can reach in full: Super Metroid's room-state level
    // pointers, one per state, each naming MB2. The profile proves the
    // states it loaded; the room graph names all of them.
    if (bwram and image.len > 0x20_0000) {
        const hdr = header_mod.detect(image) catch null;
        if (hdr != null and std.mem.startsWith(u8, &hdr.?.title, "Super Metroid")) {
            const walk = try rebankSmRoomLevelPointers(gpa, image, out);
            res.stats.rewritten_room_level_banks = walk.rebanked;
            res.stats.room_walk_rooms = walk.rooms;
            res.stats.room_walk_states = walk.states;
            res.stats.room_walk_refused_at = walk.refused_at;
            res.stats.rewritten_bg_banks = walk.bg_banks;
            res.stats.bg_records = walk.bg_records;
            const inl = rebankSmDecompInlineDests(image, out);
            res.stats.rewritten_decomp_inline_banks = inl.rebanked;
            res.stats.decomp_inline_sites = inl.sites;
            const ts = rebankSmTilesetTable(image, out);
            res.stats.rewritten_tileset_banks = ts.rebanked;
            res.stats.tileset_records = ts.states;
            res.stats.tileset_refused_at = ts.refused_at;
            const en = rebankSmEnemyHeaders(image, out);
            res.stats.rewritten_enemy_banks = en.rebanked;
            res.stats.enemy_headers = en.states;
            const ps = rebankSmPointerSeeds(image, out);
            res.stats.pointer_seed_sites = ps.sites;
            res.stats.rewritten_pointer_seeds = ps.rebanked;
            const am = rebankSmAreaMapTable(image, out);
            res.stats.area_map_entries = am.states;
            res.stats.rewritten_area_map_banks = am.rebanked;
            res.stats.area_map_refused_at = am.refused_at;
        }
    }
    // Misfit-bank pin sites: translate-in thunks. The map, in 8-bit A:
    // $A0-$BF -> -$80 (MB1's home), $C0-$DF -> -$20 (MB2's home), else
    // untouched. Both idioms span 4 bytes at the site.
    if (bwram) if (ptr_ev) |pe| {
        const map_body = [_]u8{
            // A bank below $A0 must pass through UNTOUCHED. The original
            // `BCC +8` here landed on the a0 arm and subtracted $80 from it
            // — harmless for the measured single-bank pins this map first
            // served (their runtime banks were always misfit), fatal once
            // the abs,X pin shape ran the map on every iteration of a loop
            // that pulls ordinary banks too (measured: Super Metroid's
            // escape builder derailed and the conversion stopped polling).
            0xC9, 0xA0, 0x90, 0x0A, // CMP #$A0 / BCC set
            0xC9, 0xC0, 0x90, 0x04, // CMP #$C0 / BCC a0
            0xE9, 0x20, 0x80, 0x02, // SBC #$20 / BRA set
            0xE9, 0x7F, // a0: SBC #$7F (carry clear: -$80)
        };
        for (pe.xl_sites[0..pe.n_xl]) |sa| {
            const sbank: u32 = (sa >> 16) & 0x7F;
            const sa16: u32 = sa & 0xFFFF;
            if (sa16 < 0x8003) continue;
            const plb = sbank * 0x8000 + (sa16 - 0x8000);
            if (plb + 1 > out.len) continue;
            var body: [40]u8 = undefined;
            var bl: usize = 0;
            var site: u32 = 0;
            if (out[plb] == 0xAB and out[plb - 1] == 0x48 and out[plb - 3] == 0xA5) {
                // LDA dp / PHA / PLB: body keeps the same +1/-1 stack use.
                site = plb - 3;
                body[0] = 0xA5;
                body[1] = out[plb - 2]; // LDA dp
                @memcpy(body[2..][0..map_body.len], &map_body);
                bl = 2 + map_body.len;
                body[bl] = 0x48; // set: PHA
                body[bl + 1] = 0xAB; // PLB
                bl += 2;
            } else if (out[plb] == 0xAB and out[plb - 1] == 0xAB and out[plb - 3] == 0xD4) {
                // PEI (dp) / PLB / PLB: same +2/-2 sequence; the pulled
                // HIGH byte maps through A (the measured consumers reload
                // A immediately; S4 arbitrates).
                site = plb - 3;
                body[0] = 0xD4;
                body[1] = out[plb - 2]; // PEI (dp)
                body[2] = 0xAB; // PLB — the transient low pull, as stock
                body[3] = 0x68; // PLA — the high byte, into A (m8)
                @memcpy(body[4..][0..map_body.len], &map_body);
                bl = 4 + map_body.len;
                body[bl] = 0x48; // PHA
                body[bl + 1] = 0xAB; // PLB
                bl += 2;
            } else if (out[plb] == 0xAB and out[plb - 1] == 0xAB and out[plb - 2] == 0x48 and
                out[plb - 5] == 0xBD)
            {
                // LDA $abs,X / PHA / PLB / PLB — the 16-bit HIGH-byte pin
                // whose table word is dual-role (low = addr half, high =
                // bank). The site runs M16 (a 16-bit table load), so the
                // 8-bit map runs under a SEP/REP bracket; A is left holding
                // the mapped high byte, which S4 arbitrates (the measured
                // consumer reloads A immediately — Super Metroid's escape
                // tile builder does TXA right after). Six site bytes: the
                // JML covers four, the trailing PLB pair is skipped by
                // returning to site+6.
                site = plb - 5;
                body[0] = 0xBD; // LDA $abs,X (m16)
                body[1] = out[plb - 4];
                body[2] = out[plb - 3];
                body[3] = 0x48; // PHA (16-bit)
                body[4] = 0xAB; // PLB — transient low pull, as stock
                body[5] = 0xE2;
                body[6] = 0x20; // SEP #$20 — the map compares are 8-bit
                body[7] = 0x68; // PLA — the high byte
                @memcpy(body[8..][0..map_body.len], &map_body);
                bl = 8 + map_body.len;
                body[bl] = 0x48; // PHA
                body[bl + 1] = 0xAB; // PLB = mapped bank
                body[bl + 2] = 0xC2;
                body[bl + 3] = 0x20; // REP #$20 — restore the caller's M
                bl += 4;
            } else continue;
            // All shapes return to the byte after the final PLB: site+4 for
            // the 4-byte idioms, site+6 for the 6-byte BD form — both are
            // plb+1, i.e. sa16+1.
            //
            // BANK BYTES RIDE THE SHIM MAP, not the stock mirror. `| $80`
            // was a mirror assumption: true on a <= 2 MiB image, and true
            // for file bank $00-$1F on the shim map (region 2 restores that
            // mirror) — which is why the bank-$00 music pins always worked.
            // A body or site in file bank $20-$3F must be addressed at its
            // IDENTITY bank: $A0-$BF is MB2 under the shim, and a JML there
            // executes the wrong megabyte (measured: the first bank-$20 xl
            // bodies — Super Metroid's escape builder pin — jumped into MB2
            // garbage and the conversion stopped polling).
            const idBank = struct {
                fn f(image_len: usize, fb: u32) u8 {
                    return if (image_len <= 0x20_0000 or fb < 0x20)
                        @intCast(fb | 0x80)
                    else
                        @intCast(fb);
                }
            }.f;
            const back16: u32 = sa16 + 1;
            body[bl] = 0x5C; // JML site+4/+6
            body[bl + 1] = @truncate(back16);
            body[bl + 2] = @truncate(back16 >> 8);
            body[bl + 3] = idBank(out.len, sbank);
            bl += 4;
            var xpad = padAllocFor(out, header.offset, sbank, 0, 0);
            const at = xpad.next(@intCast(bl)) orelse continue;
            @memcpy(out[at..][0..bl], body[0..bl]);
            out[site] = 0x5C; // JML body
            std.mem.writeInt(u16, out[site + 1 ..][0..2], @intCast(0x8000 + (at % 0x8000)), .little);
            out[site + 3] = idBank(out.len, at / 0x8000);
            res.stats.xl_pins += 1;
        }
    };
    // D and S follow their memory into the window.
    for (moves[0..n_moves]) |off| {
        const imm = std.mem.readInt(u16, out[off..][0..2], .little);
        std.mem.writeInt(u16, out[off..][0..2], imm + wg_bw_window, .little);
        res.stats.dp_sites += 1;
    }
    res.stats.d_moved = bwram;

    // Context-split thunks: each collected site becomes `JSR thunk`, and
    // the thunk dispatches on the RUNTIME data bank — the one fact the
    // static rewrite could not know. The template restores the caller's
    // exact flags immediately before the original op, so every op class
    // (loads, stores, RMW, carry-consuming ADC/SBC, flag-transparent
    // stores inside a CMP/branch pair) behaves byte-for-byte as in situ:
    //
    //   PHP / SEP #$20 / PHA / PHB / PLA   ; A.lo = DBR, entry flags saved
    //   BMI sys / BIT #$40 / BEQ sys       ; bit7 clear + bit6 set = $40/$41
    //   PLA / PLP / op v         / RTS     ; pinned caller: operand as-is
    //   sys: PLA / PLP / op v+$6000 / RTS  ; system caller: the window
    //
    // JSR is bank-relative, so a site's thunk is carved in the site's own
    // bank — from ANY of that bank's padding runs (see PadAlloc), with the
    // scaffold's carve reserved by address, and behind a 5-byte far stub
    // once that bank runs dry (see placeThunk).
    var pad: PadAlloc = undefined;
    const big: BigRun = if (window) biggestRun(out, header.offset) else .{};
    const keep: u32 = @min(win_copy_reserve, big.len -| PadAlloc.margin);
    var far: FarPad = .{
        .out = out,
        .header_off = header.offset,
        .keep_bank = big.bank,
        .keep_lo = big.end - keep,
        .keep_hi = big.end,
    };
    if (dbg_thunk_pad and window)
        std.debug.print("[farpad] biggest run: bank {x:0>2}, {} bytes, reserving {} for tree copies\n", .{ big.bank, big.len, keep });
    // Index-split thunks: dispatch on the index register's magnitude.
    // WIDTH-PROOF: the site's recorded width is only the LAST run's — a
    // caller can arrive in x8, where a 16-bit CPY immediate misparses
    // (the $20 of #$2000 executes as JSR — measured: the laser's shot
    // path derailed inside the v1 thunk and built a degenerate
    // full-screen beam that never collided). The caller's pushed X flag
    // is tested first: an 8-bit index over a tiny base can only reach
    // the low mirror, so x8 callers take the window path unconditionally
    // and only x16 callers run the compare.
    //
    // A is SAVED across the scratch load — the same PHA-under-SEP trick
    // the DBR thunk uses, which pushes one byte whatever the caller's M
    // was and pulls it back under the restored M. That is what lets
    // STORES be thunked: the v1 template scratched A and so could only
    // serve LDA shapes, and every `STA $00xx,Y` in unmeasured code was
    // left pointing at abandoned WRAM. The compare runs under saved
    // flags (CPY clobbers carry, which a load must leave untouched); the
    // op runs LAST so the exit flags are its own.
    //
    // The DBR is tested FIRST, because the operand only shifts for a
    // caller whose data bank is a system bank. Three worlds share one
    // site and the unshifted operand serves two of them: a caller pinned
    // to $40/$41 means the tiny base is that bank's own low page (the
    // in-tree hazard shape — an uncovered site the root's pin makes
    // safe), and a system-bank caller with a huge index is walking ROM.
    // Only system bank + small index is the abandoned-WRAM case, and
    // only that one moves into the window.
    //
    //   PHP / SEP #$20 / PHA / PHB / PLA
    //   BMI sys / BIT #$40 / BNE rom          ; $40-$7F: pinned, as-is
    //   sys: LDA $02,S / BIT #$10 / BNE low   ; x8 index cannot leave the page
    //   CPY #($2000-v) / BCS rom
    //   low: PLA / PLP / op v+$6000 / RTS
    //   rom: PLA / PLP / op v / RTS
    // BOTH families are placed in ONE pass, merged in file order, and
    // identical sites SHARE a body: `LDA $0000,Y` appears twenty-odd times
    // in a bank and one thunk serves them all. Sharing is what brings a
    // bank with 141 bytes of padding and 29 sites inside its budget — the
    // per-site cost drops from 35 bytes to 3 (the JSR is the site).
    const Th = struct {
        file: u32,
        v: u16,
        op: u8,
        idx: bool,
        pin: bool,
        /// Which of the four index bodies this site takes (see each one).
        fn wrap(self: @This()) bool {
            return self.idx and !self.pin and self.v >= 0x100;
        }
        fn v2(self: @This()) bool {
            return self.idx and !self.pin and !self.wrap() and (self.op == 0xB9 or self.op == 0xBD);
        }
        fn len(self: @This()) u32 {
            if (!self.idx) return split_thunk_len;
            if (self.pin) return idx_thunk_len;
            if (self.wrap()) return idx_thunk_wrap_len;
            return if (self.v2()) idx_thunk_v2_len else idx_thunk_short_len;
        }
    };
    var all: [split_thunk_max + idx_thunk_max]Th = undefined;
    var n_all: usize = 0;
    {
        var a: usize = 0;
        var b: usize = 0;
        while (a < n_thunks or b < n_ithunks) : (n_all += 1) {
            if (b == n_ithunks or (a < n_thunks and thunks[a].file < ithunks[b].file)) {
                all[n_all] = .{ .file = thunks[a].file, .v = thunks[a].v, .op = thunks[a].op, .idx = false, .pin = false };
                a += 1;
            } else {
                all[n_all] = .{ .file = ithunks[b].file, .v = ithunks[b].v, .op = ithunks[b].op, .idx = true, .pin = ithunks[b].pin };
                b += 1;
            }
        }
    }
    var seen: [split_thunk_max + idx_thunk_max]struct { v: u16, op: u8, idx: bool, pin: bool, addr: u16 } = undefined;
    // Cold-site dispatcher state (see coldDispatcherBody): sites routed
    // through a bank's shared stub, their far bodies (dedup'd ACROSS
    // banks — the dispatcher jumps long, so one RTL-tailed body serves
    // every bank), and each pressured bank's one stub to backpatch.
    var cold_sites: [idx_thunk_max]struct { site: u24, body: u24 } = undefined;
    var n_cold: usize = 0;
    var cold_bodies: [idx_thunk_max]struct { v: u16, op: u8, at: u24 } = undefined;
    var n_cold_bodies: usize = 0;
    var cold_stubs: [0x40]u32 = undefined;
    var n_cold_stubs: usize = 0;
    if (window and n_all != 0) {
        var i: usize = 0;
        while (i < n_all) {
            const tbank: u32 = all[i].file / 0x8000;
            var j = i;
            while (j < n_all and all[j].file / 0x8000 == tbank) j += 1;
            pad = padAllocFor(out, header.offset, tbank, carve, carve_len);
            // Bodies or stubs, decided per bank BEFORE anything is
            // written: a bank that cannot hold every DISTINCT body should
            // hold none, because filling it with the first arrivals
            // leaves the rest without even their 5-byte stub. That is how
            // bank $00 — 1.5 KiB of slack against a 2 KiB scaffold —
            // refused a conversion that fits comfortably.
            var need: u32 = 0;
            var n_dist: u32 = 0;
            var n_dist_hot: u32 = 0;
            var n_seen: usize = 0;
            for (all[i..j]) |t| {
                var dup = false;
                for (seen[0..n_seen]) |s| {
                    if (s.v == t.v and s.op == t.op and s.idx == t.idx and s.pin == t.pin) dup = true;
                }
                if (dup) continue;
                seen[n_seen] = .{ .v = t.v, .op = t.op, .idx = t.idx, .pin = t.pin, .addr = 0 };
                n_seen += 1;
                need += t.len() + PadAlloc.margin;
                n_dist += 1;
                if (!(t.idx and t.pin)) n_dist_hot += 1;
            }
            // Three tiers, decided per bank BEFORE anything is written:
            // bodies when they all fit; a far stub per thunk when at
            // least those do; and when even one stub per thunk exceeds
            // the bank, the MEASURED thunks keep their stubs and every
            // unmeasured one shares the cold dispatcher's single stub —
            // the population that grows with coverage is exactly the one
            // that stops costing bank bytes.
            const cap = pad.stubCapacity();
            const tier: enum { bodies, stubs, shared } =
                if (pad.freeBytes() >= need) .bodies else if (cap >= n_dist) .stubs else if (cap >= n_dist_hot + 1) .shared else return refuse(refusal, .{ .reason = .wg_thunk_space, .detail = tbank });
            const ff = tier != .bodies;
            if (dbg_thunk_pad)
                std.debug.print("[thunkpad] bank {x:0>2}: {} site(s), {} distinct ({} hot), need {} free {} cap {} tier {s}\n", .{ tbank, j - i, n_dist, n_dist_hot, need, pad.freeBytes(), cap, @tagName(tier) });
            var bank_stub: u32 = 0; // this bank's shared cold stub, once
            n_seen = 0;
            while (i < j) : (i += 1) {
                const t = all[i];
                if (tier == .shared and t.idx and t.pin) {
                    var body: u24 = 0;
                    for (cold_bodies[0..n_cold_bodies]) |cb| {
                        if (cb.v == t.v and cb.op == t.op) body = cb.at;
                    }
                    if (body == 0) {
                        const at = far.next(idx_thunk_len) orelse
                            return refuse(refusal, .{ .reason = .no_free_space, .detail = idx_thunk_len });
                        @memcpy(out[at..][0..idx_thunk_len], &idxThunkBody(t.op, t.v, 0x6B));
                        body = @intCast((at / 0x8000) << 16 | (0x8000 + (at % 0x8000)));
                        cold_bodies[n_cold_bodies] = .{ .v = t.v, .op = t.op, .at = body };
                        n_cold_bodies += 1;
                    }
                    if (bank_stub == 0) {
                        bank_stub = pad.next(far_stub_len) orelse
                            return refuse(refusal, .{ .reason = .wg_thunk_space, .detail = tbank });
                        out[bank_stub] = 0x22; // JSL — dispatcher patched in below
                        out[bank_stub + 4] = 0x60; // RTS
                        cold_stubs[n_cold_stubs] = bank_stub;
                        n_cold_stubs += 1;
                    }
                    if (n_cold == idx_thunk_max)
                        return refuse(refusal, .{ .reason = .wg_split_overflow, .detail = @intCast(t.file) });
                    cold_sites[n_cold] = .{
                        .site = @intCast((t.file / 0x8000) << 16 | (0x8000 + (t.file % 0x8000))),
                        .body = body,
                    };
                    n_cold += 1;
                    out[t.file] = 0x20; // JSR — same 3-byte footprint
                    std.mem.writeInt(u16, out[t.file + 1 ..][0..2], @intCast(0x8000 + (bank_stub % 0x8000)), .little);
                    res.stats.disp_sites += 1;
                    continue;
                }
                var taddr: u16 = 0;
                var found = false;
                for (seen[0..n_seen]) |s| {
                    if (s.v == t.v and s.op == t.op and s.idx == t.idx and s.pin == t.pin) {
                        taddr = s.addr;
                        found = true;
                    }
                }
                if (!found) {
                    const placed = if (!t.idx)
                        placeThunk(out, &pad, &far, &splitThunkBody(t.op, t.v, 0x60), &splitThunkBody(t.op, t.v, 0x6B), ff, &res.stats.split_far)
                    else if (t.pin)
                        placeThunk(out, &pad, &far, &idxThunkBody(t.op, t.v, 0x60), &idxThunkBody(t.op, t.v, 0x6B), ff, &res.stats.split_far)
                    else if (t.wrap())
                        placeThunk(out, &pad, &far, &idxThunkBodyWrap(t.op, t.v, 0x60), &idxThunkBodyWrap(t.op, t.v, 0x6B), ff, &res.stats.split_far)
                    else if (t.v2())
                        placeThunk(out, &pad, &far, &idxThunkBodyV2(t.op, t.v, 0x60), &idxThunkBodyV2(t.op, t.v, 0x6B), ff, &res.stats.split_far)
                    else
                        placeThunk(out, &pad, &far, &idxThunkBodyShort(t.op, t.v, 0x60), &idxThunkBodyShort(t.op, t.v, 0x6B), ff, &res.stats.split_far);
                    taddr = placed orelse return refuse(refusal, .{
                        .reason = .no_free_space,
                        .detail = t.len(),
                    });
                    seen[n_seen] = .{ .v = t.v, .op = t.op, .idx = t.idx, .pin = t.pin, .addr = taddr };
                    n_seen += 1;
                }
                out[t.file] = 0x20; // JSR — same 3-byte footprint
                std.mem.writeInt(u16, out[t.file + 1 ..][0..2], taddr, .little);
            }
        }
        if (n_cold != 0) {
            // The dispatcher's table, sorted the way its binary search
            // descends: 16-bit address first, bank on ties. Records are
            // 8 bytes — [addr16][bank][0][body-1 lo][body-1 hi][bank][0]
            // — so `mid` floors with a single AND, and the stored target
            // is body-1 because RTL lands one past what it pulls.
            const Cold = @TypeOf(cold_sites[0]);
            const S = struct {
                fn lt(_: void, a: Cold, b: Cold) bool {
                    const ka = (@as(u32, a.site) & 0xFFFF) << 8 | (a.site >> 16);
                    const kb = (@as(u32, b.site) & 0xFFFF) << 8 | (b.site >> 16);
                    return ka < kb;
                }
            };
            std.mem.sort(Cold, cold_sites[0..n_cold], {}, S.lt);
            const tbl = far.next(@intCast(8 * n_cold)) orelse
                return refuse(refusal, .{ .reason = .no_free_space, .detail = @intCast(8 * n_cold) });
            for (cold_sites[0..n_cold], 0..) |c, ci| {
                const r = out[tbl + 8 * ci ..][0..8];
                std.mem.writeInt(u16, r[0..2], @truncate(c.site), .little);
                r[2] = @intCast(c.site >> 16);
                r[3] = 0;
                const tgt: u24 = c.body - 1;
                std.mem.writeInt(u16, r[4..6], @truncate(tgt), .little);
                r[6] = @intCast(tgt >> 16);
                r[7] = 0;
            }
            const disp = far.next(cold_disp_len) orelse
                return refuse(refusal, .{ .reason = .no_free_space, .detail = cold_disp_len });
            const tbl_cpu: u24 = @intCast((tbl / 0x8000) << 16 | (0x8000 + (tbl % 0x8000)));
            @memcpy(out[disp..][0..cold_disp_len], &coldDispatcherBody(tbl_cpu, @intCast(n_cold)));
            const disp_cpu: u24 = @intCast((disp / 0x8000) << 16 | (0x8000 + (disp % 0x8000)));
            for (cold_stubs[0..n_cold_stubs]) |s| {
                std.mem.writeInt(u16, out[s + 1 ..][0..2], @truncate(disp_cpu), .little);
                out[s + 3] = @intCast(disp_cpu >> 16);
            }
        }
        res.stats.split_sites = @intCast(n_all);
        res.stats.idx_split_sites = @intCast(n_ithunks);
    }
    // The LONG,X flavor, placed entirely in the far pool: `JSL` names its
    // own bank, so these thunks are free of the bank-local constraint that
    // shapes everything above — and, unlike the `JSR` flavor, a copied
    // tree member carries one unchanged. Bodies are shared by (op,
    // operand, bank), and their addresses are handed to the offload
    // eligibility walk so it can tell a thunk call from a tree member.
    var lbodies: [64]u24 = undefined;
    var n_lbodies: usize = 0;
    if (window and n_lthunks != 0) {
        const LSeen = struct { v: u16, op: u8, bank: u8, at: u32 };
        var lseen: [idx_thunk_max]LSeen = undefined;
        var n_lseen: usize = 0;
        for (lthunks[0..n_lthunks]) |t| {
            var at: u32 = 0;
            var found = false;
            for (lseen[0..n_lseen]) |s| {
                if (s.v == t.v and s.op == t.op and s.bank == t.bank) {
                    at = s.at;
                    found = true;
                }
            }
            if (!found) {
                // The body's bank byte rides the SAME de-mirror map the
                // covered-code pass applies: the site's stock operand names
                // a mirror ($B4 = MB1's $34) that the shim-programmed map
                // no longer honors — region 3 carries MB2 — so a body that
                // keeps the stock byte reads the wrong megabyte (measured:
                // the music loader's terminator probe `LDA $B4:0000,X` at
                // X=$921C read far-pool bytes as $1231 instead of $FFFF,
                // walked a phantom chunk into mirror WRAM, and the door
                // faded to black). <= 2 MiB images keep the byte — the
                // fold really is a mirror there.
                const tbank: u8 = if (image.len <= 0x20_0000)
                    t.bank
                else if (t.bank >= 0xA0 and t.bank <= 0xBF)
                    t.bank - 0x80
                else if (t.bank >= 0xC0 and t.bank <= 0xDF)
                    t.bank - 0x20
                else if (t.bank >= 0x40 and t.bank <= 0x5F)
                    t.bank + 0x60
                else
                    t.bank;
                // A base at or above $FF00 wraps forward into the NEXT
                // bank's low page and needs the two-compare body; a tiny
                // base stays in its own bank and needs the ceiling one.
                const neg = t.v >= 0xFF00;
                // v == 0 is excluded: a 16-bit X cannot carry a zero base past
                // $FFFF, so no wrap window exists — and $10000-v truncates to
                // a CPX #$0000 whose BCC-rom is never taken, sending EVERY
                // large index down the low arm (measured: the $38:8204/$82D0/
                // $8336 bodies read bank+1's stale mirror instead of ROM).
                const wrap_ok = !neg and t.v != 0 and (tbank & 0x7F) < 0x3F;
                const want: u32 = if (neg) long_neg_thunk_len else if (wrap_ok) long_wrap_thunk_len else long_thunk_len;
                at = far.next(want) orelse
                    return refuse(refusal, .{ .reason = .no_free_space, .detail = want });
                if (neg)
                    @memcpy(out[at..][0..long_neg_thunk_len], &longNegThunkBody(t.op, t.v, tbank))
                else if (wrap_ok)
                    @memcpy(out[at..][0..long_wrap_thunk_len], &longThunkBodyWrap(t.op, t.v, tbank))
                else
                    @memcpy(out[at..][0..long_thunk_len], &longThunkBody(t.op, t.v, tbank));
                lseen[n_lseen] = .{ .v = t.v, .op = t.op, .bank = t.bank, .at = at };
                n_lseen += 1;
                if (n_lbodies < lbodies.len) {
                    lbodies[n_lbodies] = @intCast((at / 0x8000) << 16 | (0x8000 + (at % 0x8000)));
                    n_lbodies += 1;
                }
            }
            out[t.file] = 0x22; // JSL — the same 4-byte footprint
            std.mem.writeInt(u16, out[t.file + 1 ..][0..2], @as(u16, @intCast(0x8000 + (at % 0x8000))), .little);
            out[t.file + 3] = @intCast(at / 0x8000);
        }
        res.stats.split_sites += @intCast(n_lthunks);
        res.stats.idx_split_sites += @intCast(n_lthunks);
    }

    // HDMA indirect-bank ($43x7 DASB) rebank thunks (see rebankDasbWrites).
    // Placed after the split/long thunks so the same far pool and per-bank
    // padding serve it — a DASB store targets MMIO, never WRAM, so it was
    // never a split-thunk site and the two passes never touch a shared byte.
    if (window and bwram) try rebankDasbWrites(out, cov, header.offset, carve, carve_len, &far, refusal, &res);

    // Relocate low-WRAM indirect addresses in the profiled indirect-HDMA
    // tables into the window, so an HDMA whose per-scanline source is a
    // relocated WRAM buffer reads the live copy, not the abandoned mirror.
    if (window and bwram) if (ptr_ev) |pe| relocateHdmaIndirect(out, pe.hdma_tables[0..pe.n_hdma_tables], &res);

    // Emit. Window mode's scaffold is ONE S-CPU shim: open the S-CPU's
    // BW-RAM gates, select window block 0, reproduce the power-on direct
    // page and stack INSIDE the window (the game's own D/S establishes
    // were shifted with everything else, but the inherited power-on
    // D=$0000 / S=$01FF would land in WRAM while every rewritten access
    // went to BW-RAM), and enter the game's own reset. The SA-1 is never
    // released from reset — the cart is carried for its RAM.
    var cur: usize = 0;
    const base16: u16 = 0x8000 + @as(u16, @intCast(carve));
    const d = out[carve..];
    if (window) {
        // Offloads first: eligibility walks the REWRITTEN image, and the
        // dispatcher's CRV feeds the shim below. The dispatcher and NMI
        // prologue live in this same bank-0 carve, after the shim slot.
        const boot: ?WinBoot = if (ml_split == null and win_candidates.len != 0)
            emitWindowOffloads(out, cov, site_evidence, header.offset, win_candidates, win_allow_async, carve + wg_window_shim_max, lbodies[0..n_lbodies], &res)
        else
            null;

        var wn: usize = 0;
        d[wn] = 0x78; // SEI
        wn += 1;
        wn = emitStore(d, wn, 0x2224, 0x00); // SBM: S-CPU window = block 0
        if (image.len > 0x20_0000) {
            // Super MMC regions for a >2 MiB image: power-on FLAT maps the
            // $80-$BF fold onto image quarters 2/3 — real data, not the
            // mirror the game's FastROM code assumes. Region 2 (banks
            // $80-$9F, where a map-$30 game runs almost everything) banks
            // to megabyte 0: the mirror is genuine again and stock's own
            // MEMSEL write gives it stock's fast timing. Region 3 (banks
            // $A0-$BF) banks to megabyte 2, keeping the third megabyte
            // reachable at stable addresses — the de-mirror pass re-banks
            // stock's $40-$5F and $C0-$DF references there (addr16
            // preserved), and its $A0-$BF (mirror-of-MB1) references down
            // to $20-$3F.
            wn = emitStore(d, wn, 0x2222, 0x80); // EXB: $80-$9F = MB 0
            wn = emitStore(d, wn, 0x2223, 0x82); // FXB: $A0-$BF = MB 2
        }
        wn = emitStore(d, wn, 0x2226, 0x80); // SWEN: S-CPU BW-RAM writes
        wn = emitStore(d, wn, 0x2228, 0x00); // BWPA: nothing protected
        // The mainloop split's stubs and COP handler store into I-RAM from
        // the S-CPU from the first frame on (boot-time IO calls, boot-time
        // math), long before the engage stub's own SIWP open: open it here.
        if (ml_split != null) {
            wn = emitStore(d, wn, 0x2229, 0xFF);
            // The split's cells are power-on garbage until the first engage
            // resets them — and the NMI hook drains the ring from the first
            // frame (measured: boot-era NMIs replayed nonsense ids and the
            // intro gained four lag frames). Zero them here.
            wn = emitStore(d, wn, split_ring_wr, 0x00);
            wn = emitStore(d, wn, split_ring_rd, 0x00);
            wn = emitStore(d, wn, split_in_replay, 0x00);
            wn = emitStore(d, wn, split_owner, 0x00);
        }
        if (boot) |b| {
            // Boot the SA-1 into the window dispatcher; the async busy
            // flag starts idle (I-RAM is garbage at power-on, and SIWP
            // must open before the S-CPU can zero it). CIV is aimed at
            // the watchdog's abort handler from HERE — $2207/8 is an
            // S-CPU-side register the SA-1 itself cannot program.
            wn = emitStore(d, wn, 0x2229, 0xFF);
            wn = emitStore(d, wn, 0x2203, @truncate(b.crv));
            wn = emitStore(d, wn, 0x2204, @truncate(b.crv >> 8));
            wn = emitStore(d, wn, 0x2207, @truncate(b.civ));
            wn = emitStore(d, wn, 0x2208, @truncate(b.civ >> 8));
            wn = emitStore(d, wn, 0x378C, 0x00); // sync mailbox-busy guard cell
            wn = emitStore(d, wn, 0x378D, 0x00); // watchdog aborted flag
            wn = emitStore(d, wn, 0x378F, 0x00); // $4200 mirror (boot state)
            if (res.stats.async_entry != 0) wn = emitStore(d, wn, 0x378A, 0x00);
            put(d, &wn, &.{ 0x9C, 0x00, 0x22 }); // release reset
        }
        put(d, &wn, &.{ 0x18, 0xFB, 0xC2, 0x30 }); // CLC / XCE / REP #$30
        put(d, &wn, &.{ 0xA9, @truncate(wg_bw_window), @truncate(wg_bw_window >> 8), 0x5B }); // LDA #$6000 / TCD
        put(d, &wn, &.{ 0xA9, 0xFF, 0x61, 0x1B }); // LDA #$61FF / TCS
        put(d, &wn, &.{ 0xE2, 0x30 }); // SEP #$30
        put(d, &wn, &.{ 0x4C, @truncate(reset), @truncate(reset >> 8) });
        std.debug.assert(wn <= wg_window_shim_max);
        // Reset -> shim; the other vectors stay the game's own unless an
        // async offload injected its NMI prologue above.
        if (ml_split) |sp| try emitSplit(out, cov, sp, d, base16, &far, carve, carve_len, refusal, &res);
        std.mem.writeInt(u16, out[header.offset + 0x3C ..][0..2], base16, .little);
        out[header.offset + 0x15] = 0x23;
        out[header.offset + 0x16] = 0x34; // no battery: the relocated WRAM must not persist
        // 128 KiB BW-RAM holds all of WRAM; a relocated battery cart needs
        // the second 128 KiB for its save RAM at offset $20000 (bank $42).
        // (.srm persistence for the relocated region is a follow-up — in-
        // session saves and save states carry it meanwhile.)
        out[header.offset + 0x18] = if (game_sram != 0) 0x08 else 0x07;
        patchgen.recomputeChecksum(out, header.offset);
        res.stats.shim_addr = base16;
        res.stats.park_addr = if (boot) |b| b.crv else 0;
        res.stats.offloaded = if (boot == null) reset else res.stats.offloaded;
        return res;
    }
    // Where each unique helper's JSR target lives in bank $00: the helper
    // itself when everything fits, its trampoline when split.
    var uniq_addr: [wg_uniq_max]u16 = undefined;
    if (!split) {
        for (uniq[0..n_uniq], 0..) |u, ui| {
            uniq_addr[ui] = base16 + @as(u16, @intCast(cur));
            const before = cur;
            wgEmitHelper(d, &cur, u);
            std.debug.assert(cur - before == wgHelperLen(u));
        }
    } else {
        // Helpers wherever first-fit placed them, each ending in a JML back
        // to the shared bank-$00 RTS stub instead of its own RTS (a JSR
        // pushes 16 bits, so an RTS with PB stuck in the helper's bank would
        // return into it).
        const rts16: u16 = base16 + @as(u16, @intCast(scaffold)) + 4 * @as(u16, @intCast(n_uniq));
        for (uniq[0..n_uniq], 0..) |u, ui| {
            const hd = out[helper_at[ui]..];
            var hcur: usize = 0;
            wgEmitHelper(hd, &hcur, u);
            std.debug.assert(hcur == wgHelperLen(u));
            std.debug.assert(hd[hcur - 1] == 0x60); // every helper ends RTS
            hcur -= 1;
            put(hd, &hcur, &.{ 0x5C, @truncate(rts16), @truncate(rts16 >> 8), 0x00 });
        }
        // Bank $00: trampolines after the scaffold, then the RTS stub. The
        // scaffold is emitted below at `cur`; reserve its span now.
        var tcur: usize = scaffold;
        for (uniq[0..n_uniq], 0..) |_, ui| {
            uniq_addr[ui] = base16 + @as(u16, @intCast(tcur));
            const h16: u16 = 0x8000 + @as(u16, @intCast(helper_at[ui] % 0x8000));
            const hbank: u8 = @intCast(helper_at[ui] / 0x8000);
            put(d, &tcur, &.{ 0x5C, @truncate(h16), @truncate(h16 >> 8), hbank });
        }
        d[tcur] = 0x60; // the shared RTS
        std.debug.assert(base16 + @as(u16, @intCast(tcur)) == rts16);
    }
    for (sites[0..n_sites]) |site| {
        const haddr = for (uniq[0..n_uniq], 0..) |u, ui| {
            if (u.kind == site.kind and u.reg == site.reg and u.idx == site.idx) break uniq_addr[ui];
        } else unreachable;
        out[site.file] = 0x20; // JSR (same length as the LDA/STA/STZ it replaces)
        std.mem.writeInt(u16, out[site.file + 1 ..][0..2], haddr, .little);
        res.stats.offload_sites += 1;
    }
    // SA-1 boot: open its I-RAM write gate, prime the NMI clear latch
    // (delivery in the core needs the latch's set->clear edge; priming it
    // makes the very first masked window airtight too), enable the
    // SNES->SA-1 NMI, and enter the game's own reset code.
    const sa1_prologue: u16 = base16 + @as(u16, @intCast(cur));
    put(d, &cur, &.{
        0xA9, 0xFF, 0x8D, 0x2A, 0x22, // CIWP: all I-RAM blocks writable
        0xA9, 0x80, 0x8D, 0x27, 0x22, // CBWE
        0xA9, 0x10, 0x8D, 0x0B, 0x22, // CIC: NMI clear latch primed
        0x8D, 0x0A, 0x22, // CIE: NMI from the SNES enabled (A still $10)
    });
    if (bwram) {
        // Reproduce the power-on direct page and stack *inside the window*.
        // The game's own TCD/TCS/TXS were shifted by $6000 with everything
        // else, but a game that simply inherits D=$0000 / S=$01FF would
        // otherwise land in I-RAM while its absolute accesses to the same
        // variables went to BW-RAM — the two would silently disagree.
        // Native mode first: emulation pins S to page 1.
        put(d, &cur, &.{
            0x9C, 0x25, 0x22, // STZ $2225 (CBM: BW-RAM block 0)
            0x9C, 0x28, 0x22, // STZ $2228 (BWPA: unprotect)
            0x18, 0xFB, 0xC2, 0x30, // CLC / XCE / REP #$30
            0xA9, @truncate(wg_bw_window), @truncate(wg_bw_window >> 8), 0x5B, // LDA #$6000 / TCD
            0xA9, 0xFF, 0x61, 0x1B, // LDA #$61FF / TCS
            0xE2, 0x30, // SEP #$30
        });
    }
    put(d, &cur, &.{ 0x4C, @truncate(reset), @truncate(reset >> 8) });
    // SA-1 NMI entry (CNV, native and emulation pulls alike): ack the
    // message via CIC — the game's handler has never heard of it, and a
    // stale flag would re-fire on every helper unmask — preserving A and
    // P, then run the game's own handler; its RTI returns directly.
    const sa1_nmi: u16 = base16 + @as(u16, @intCast(cur));
    put(d, &cur, &.{
        0x08, 0xC2, 0x20, 0x48, 0xE2, 0x20, // PHP / REP #$20 / PHA / SEP #$20
        0xA9, 0x10, 0x8D, 0x0B, 0x22, // CIC: clear the NMI flag
        0xC2, 0x20,                  0x68,                       0x28, // REP #$20 / PLA / PLP
        0x4C, @truncate(nmi_target), @truncate(nmi_target >> 8),
    });
    // S-CPU NMI: ack the S-side latch, forward to the SA-1. Width-agnostic
    // on purpose — an NMI can land inside the service loop's 16-bit spans.
    const scpu_nmi: u16 = base16 + @as(u16, @intCast(cur));
    put(d, &cur, &.{
        0x08, 0xC2, 0x20, 0x48, 0xE2, 0x20, // PHP / REP #$20 / PHA / SEP #$20
        0xAD, 0x10, 0x42, // LDA $4210: ack
        0xA9, 0x10, 0x8D, 0x00, 0x22, // CCNT bit 4: NMI message to the SA-1
        0xC2, 0x20, 0x68, 0x28, 0x40, // REP #$20 / PLA / PLP / RTI
    });
    const svc: u16 = base16 + @as(u16, @intCast(cur));
    put(d, &cur, &wg_service);
    const shim: u16 = base16 + @as(u16, @intCast(cur));
    var w2 = out[carve + cur ..];
    var n2: usize = 0;
    w2[n2] = 0x78; // SEI
    n2 += 1;
    n2 = emitStore(w2, n2, 0x2229, 0xFF);
    n2 = emitStore(w2, n2, 0x2226, 0x80);
    n2 = emitStore(w2, n2, 0x2203, @truncate(sa1_prologue));
    n2 = emitStore(w2, n2, 0x2204, @truncate(sa1_prologue >> 8));
    n2 = emitStore(w2, n2, 0x2205, @truncate(sa1_nmi));
    n2 = emitStore(w2, n2, 0x2206, @truncate(sa1_nmi >> 8));
    w2[n2] = 0x9C; // STZ $2200: release
    w2[n2 + 1] = 0x00;
    w2[n2 + 2] = 0x22;
    n2 += 3;
    w2[n2] = 0x4C; // JMP service loop — the S-CPU never runs the game again
    w2[n2 + 1] = @truncate(svc);
    w2[n2 + 2] = @truncate(svc >> 8);
    n2 += 3;
    std.debug.assert(n2 == wg_shim_len);
    std.debug.assert(cur + n2 == scaffold + if (split) @as(usize, 0) else helper_len);

    // Vectors: reset -> shim; NMI (native + emulation) -> the forward stub.
    std.mem.writeInt(u16, out[header.offset + 0x3C ..][0..2], shim, .little);
    std.mem.writeInt(u16, out[header.offset + 0x2A ..][0..2], scpu_nmi, .little);
    std.mem.writeInt(u16, out[header.offset + 0x3A ..][0..2], scpu_nmi, .little);

    out[header.offset + 0x15] = 0x23;
    out[header.offset + 0x16] = 0x34; // no battery: BW-RAM is working memory
    // BW-RAM size: 32 KiB is plenty when the game's state stayed in I-RAM,
    // but the window mode maps all 128 KiB of WRAM into it.
    out[header.offset + 0x18] = if (bwram) 0x07 else 0x05;
    patchgen.recomputeChecksum(out, header.offset);

    res.stats.shim_addr = shim;
    res.stats.park_addr = svc;
    res.stats.offloaded = reset;
    res.stats.offload_count = 1;
    return res;
}

/// Does `op` put a new value in X, or hand control somewhere this linear
/// walk cannot follow? Either kills the `LDX #imm` the block-move source
/// proof is carrying — the walk only reasons about straight-line code, so
/// anything that could arrive with a different X invalidates it.
fn writesXOrBranches(op: u8) bool {
    return switch (op) {
        // Loads into X, transfers into X, pulls, inc/dec — and block moves,
        // which leave X at the end of the run.
        0xA2, 0xA6, 0xB6, 0xAE, 0xBE, 0xAA, 0xBA, 0xFA, 0xE8, 0xCA, 0x44, 0x54 => true,
        else => branches(op),
    };
}

/// The same, for Y — which the block-move destination proof rides on.
fn writesYOrBranches(op: u8) bool {
    return switch (op) {
        // Loads into Y, transfers into Y, pull, inc/dec — and block moves.
        0xA0, 0xA4, 0xB4, 0xAC, 0xBC, 0xA8, 0x7A, 0xC8, 0x88, 0x9B, 0x44, 0x54 => true,
        else => branches(op),
    };
}

/// Hands control somewhere a linear walk cannot follow, so nothing it was
/// carrying about register contents survives.
fn branches(op: u8) bool {
    return switch (op) {
        0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0, 0x80, 0x82 => true,
        0x4C, 0x5C, 0x6C, 0x7C, 0xDC, 0x20, 0x22, 0xFC => true,
        0x60, 0x6B, 0x40, 0x00, 0x02 => true,
        else => false,
    };
}

/// Does the DBR knowledge survive `op` at `file`? A CONDITIONAL branch
/// does not change DBR — the pin at a routine's head dominates its whole
/// straight-line body, branches included (killing it there is what made
/// the window rewriter shift `STA $0000,Y` sites that run under a pinned
/// $7E and corrupt BW-RAM $9C00 with the bubble tables). A JSR/JSL
/// survives when the callee provably never touches DBR. Everything else
/// unconditional (JMP/BRA/returns/interrupts) is a join point another
/// DBR may reach — the knowledge dies.
pub fn dbrSurvives(image: []const u8, cov: []const u8, file: u32, op: u8) bool {
    switch (op) {
        // Conditional branches and short unconditional skips (BRA/BRL):
        // neither touches DBR, and the next LINEAR instruction is the
        // same routine's alternate path, under the same pin.
        0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0, 0x80, 0x82 => return true,
        0x20, 0x22 => {
            if (op == 0x22 and image[file + 3] != 0x00) return false;
            const tgt = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
            if (tgt < 0x8000) return false;
            return dbrTransparent(image, cov, tgt, 2);
        },
        else => return !branches(op),
    }
}

/// Linear scan of a callee: true when every covered instruction to its
/// return leaves DBR alone (no PLB, no block move, no interrupt-adjacent
/// op), recursing through nested bank-$00 calls. Anything the scan cannot
/// follow — an uncovered byte, a jump, depth exhausted — is a no.
fn dbrTransparent(image: []const u8, cov: []const u8, entry: u16, depth: u8) bool {
    if (depth == 0) return false;
    var pc: u32 = entry;
    while (pc - entry < 768) {
        if (pc > 0xFFFF) return false;
        const fl = cov[pc] | cov[0x80_0000 | pc];
        if (fl & usage_map.flag_opcode == 0) return false;
        const file = pc - 0x8000;
        const op = image[file];
        switch (op) {
            0x60, 0x6B => return true, // RTS/RTL: clean exit
            0xAB, 0x44, 0x54, 0x40, 0x00, 0x02, 0xDB => return false,
            // An intra-span JMP/BRA/BRL changes nothing about DBR; the
            // scan keeps walking linearly (the return is still ahead of
            // it). A jump that leaves the span is a path it cannot judge.
            0x4C => {
                const dst = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
                if (dst < entry or dst - entry >= 768) return false;
            },
            0x80, 0x82 => {
                const dst = if (op == 0x80)
                    pc + 2 +% @as(u32, @bitCast(@as(i32, @as(i8, @bitCast(image[file + 1])))))
                else
                    pc + 3 +% @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(std.mem.readInt(u16, image[file + 1 ..][0..2], .little))))));
                if (dst < entry or dst - entry >= 768) return false;
            },
            0x5C, 0x6C, 0x7C, 0xDC, 0xFC => return false,
            0x20, 0x22 => {
                if (op == 0x22 and image[file + 3] != 0x00) return false;
                const tgt = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
                if (tgt < 0x8000 or !dbrTransparent(image, cov, tgt, depth - 1)) return false;
            },
            else => {},
        }
        const m8 = fl & usage_map.flag_m != 0;
        const x8 = fl & usage_map.flag_x != 0;
        pc += usage_map.instrLen(op, m8, x8);
    }
    return false;
}

fn wgHelperLen(site: WgSite) u32 {
    if (site.idx != .none) return switch (site.kind) {
        .w8 => 40,
        .w16 => 42,
        .r8 => 48,
        .r16 => 49,
        .ry8, .ry16, .rx8, .rx16 => 49,
        .stz8, .stz16, .c8, .c16, .wx8, .wx16, .wy8, .wy16 => unreachable,
    };
    return switch (site.kind) {
        .w8, .stz8 => 36,
        .w16 => 46,
        .r8 => 39,
        .r16 => 47,
        .stz16 => 43,
        .c8 => 49,
        .c16 => 55,
        .wx8, .wx16, .wy8, .wy16 => 38,
        .ry8, .ry16, .rx8, .rx16 => unreachable, // only collected indexed
    };
}

/// One SA-1-side MMIO helper. Every transaction runs with the SNES->SA-1
/// NMI masked (CIE) so the game's NMI handler — whose own MMIO sites file
/// requests through this same mailbox — can never corrupt one in flight;
/// a message that arrives meanwhile latches and delivers on the unmask.
/// Write helpers preserve A and P exactly (their originals did); read
/// helpers end with N/Z reflecting the loaded value and every other flag
/// preserved — again exactly like their originals. X and Y are untouched.
/// Mailbox/CIE absolutes tolerate any system-bank DB: the I-RAM window and
/// the SA-1 registers mirror across banks $00-$3F/$80-$BF.
fn wgEmitHelper(d: []u8, cur: *usize, site: WgSite) void {
    const lo: u8 = @truncate(site.reg);
    const hi: u8 = @truncate(site.reg >> 8);
    if (site.idx != .none) return wgEmitIndexedHelper(d, cur, site);
    switch (site.kind) {
        .w8 => put(d, cur, &.{
            0x9C, 0x0A, 0x22, // STZ CIE: mask (STZ leaves flags alone)
            0x08, 0x48, // PHP / PHA
            0x8D, 0xF3, 0x37, // value
            0xA9, lo,   0x8D,
            0xF1, 0x37, 0xA9,
            hi,   0x8D, 0xF2,
            0x37,
            0xA9, 0x01, 0x8D, 0xF0, 0x37, // filed
            0xAD, 0xF0, 0x37, 0xD0, 0xFB, // until served
            0xA9, 0x10, 0x8D, 0x0A, 0x22, // unmask (a latched NMI lands here)
            0x68, 0x28, 0x60, // PLA / PLP / RTS
        }),
        .stz8 => put(d, cur, &.{
            0x9C, 0x0A, 0x22,
            0x08, 0x48,
            0x9C, 0xF3, 0x37, // value = 0
            0xA9, lo,   0x8D,
            0xF1, 0x37, 0xA9,
            hi,   0x8D, 0xF2,
            0x37, 0xA9, 0x01,
            0x8D, 0xF0, 0x37,
            0xAD, 0xF0, 0x37,
            0xD0, 0xFB, 0xA9,
            0x10, 0x8D, 0x0A,
            0x22, 0x68, 0x28,
            0x60,
        }),
        .w16 => put(d, cur, &.{
            0x08, 0x48, // PHP / PHA (16-bit)
            0xE2, 0x20, 0x9C, 0x0A, 0x22, // 8-bit: mask
            0xC2, 0x20, 0x68, 0x48, // 16-bit: recover the value, keep it saved
            0x8D, 0xF3, 0x37, // 16-bit value -> $37F3/4
            0xE2, 0x20, 0xA9,
            lo,   0x8D, 0xF1,
            0x37, 0xA9, hi,
            0x8D, 0xF2, 0x37,
            0xA9, 0x03, 0x8D,
            0xF0, 0x37, 0xAD,
            0xF0, 0x37, 0xD0,
            0xFB, 0xA9, 0x10,
            0x8D, 0x0A, 0x22,
            0xC2, 0x20, 0x68,
            0x28, 0x60,
        }),
        .stz16 => put(d, cur, &.{
            0x08, 0x48,
            0xE2, 0x20,
            0x9C, 0x0A,
            0x22,
            0x9C, 0xF3, 0x37, 0x9C, 0xF4, 0x37, // value = 0 (both halves)
            0xA9, lo,   0x8D, 0xF1, 0x37, 0xA9,
            hi,   0x8D, 0xF2, 0x37, 0xA9, 0x03,
            0x8D, 0xF0, 0x37, 0xAD, 0xF0, 0x37,
            0xD0, 0xFB, 0xA9, 0x10, 0x8D, 0x0A,
            0x22, 0xC2, 0x20, 0x68, 0x28, 0x60,
        }),
        .r8 => put(d, cur, &.{
            0x9C, 0x0A, 0x22, // mask; flags still the caller's
            0xA9, lo,   0x8D,
            0xF1, 0x37, 0xA9,
            hi,   0x8D, 0xF2,
            0x37, 0xA9, 0x02,
            0x8D, 0xF0, 0x37,
            0xAD, 0xF0, 0x37, 0x10, 0xFB, // BPL: wait for the $FE served marker
            0xAD, 0xF3, 0x37, // result — N/Z now match the original LDA
            0x9C, 0xF0, 0x37, // release the mailbox (no flags)
            0x08, 0x48, // save result N/Z and value across the unmask
            0xA9, 0x10,
            0x8D, 0x0A,
            0x22, 0x68,
            0x28, 0x60,
        }),
        .r16 => put(d, cur, &.{
            0xE2, 0x20, 0x9C, 0x0A, 0x22, // 8-bit: mask
            0xA9, lo,   0x8D, 0xF1, 0x37,
            0xA9, hi,   0x8D, 0xF2, 0x37,
            0xA9, 0x04, 0x8D, 0xF0, 0x37,
            0xAD, 0xF0, 0x37, 0x10, 0xFB,
            0xC2, 0x20, // 16-bit again (the entry width)
            0xAD, 0xF3, 0x37, // 16-bit result
            0x9C, 0xF0, 0x37, // 16-bit release (also zeroes $37F1)
            0x08, 0x48, 0xE2,
            0x20, 0xA9, 0x10,
            0x8D, 0x0A, 0x22,
            0xC2, 0x20, 0x68,
            0x28, 0x60,
        }),
        // CMP against an MMIO register: an r8/r16 read whose result is then
        // compared against the caller's preserved A — N/Z/C land exactly as
        // the original CMP left them, and V (which CMP never touches)
        // survives inside the pushed P.
        .c8 => put(d, cur, &.{
            0x9C, 0x0A, 0x22, // mask
            0x08, // PHP
            0xC2, 0x20, 0x48, // REP / PHA: full C, the request loads clobber it
            0xE2, 0x20, 0xA9,
            lo,   0x8D, 0xF1,
            0x37, 0xA9, hi,
            0x8D, 0xF2, 0x37,
            0xA9, 0x02, 0x8D, 0xF0, 0x37, // filed: r8
            0xAD, 0xF0, 0x37, 0x10, 0xFB, // BPL: wait for the $FE marker
            0xC2, 0x20, 0x68, // A back
            0x28, // PLP: caller flags and widths (m8 by construction)
            0xCD, 0xF3, 0x37, // CMP result: N/Z/C as the original
            0x9C, 0xF0, 0x37, // release (no flags)
            0x08, 0x48, 0xA9, 0x10, 0x8D, 0x0A, 0x22, 0x68, 0x28, // unmask, flags kept
            0x60,
        }),
        .c16 => put(d, cur, &.{
            0x08, // PHP
            0xE2, 0x20, 0x9C, 0x0A, 0x22, // 8-bit: mask
            0xC2, 0x20, 0x48, // REP / PHA
            0xE2, 0x20, 0xA9,
            lo,   0x8D, 0xF1,
            0x37, 0xA9, hi,
            0x8D, 0xF2, 0x37,
            0xA9, 0x04, 0x8D, 0xF0, 0x37, // filed: r16
            0xAD, 0xF0, 0x37, 0x10, 0xFB,
            0xC2, 0x20, 0x68, // A back (16)
            0x28, // PLP (m=16 by construction)
            0xCD, 0xF3, 0x37, // 16-bit CMP
            0x9C, 0xF0, 0x37, // 16-bit release
            0x08, 0x48, 0xE2,
            0x20, 0xA9, 0x10,
            0x8D, 0x0A, 0x22,
            0xC2, 0x20, 0x68,
            0x28, 0x60,
        }),
        .ry8, .ry16, .rx8, .rx16 => unreachable, // only collected indexed
        // STX/STY to MMIO: flag-neutral stores whose width follows X. The
        // value store runs first, at the caller's own index width, before
        // any P munging; the PLP restores every flag exactly as the
        // original left them (STX/STY touch none).
        .wx8, .wx16, .wy8, .wy16 => {
            const st: u8 = if (site.kind == .wx8 or site.kind == .wx16) 0x8E else 0x8C;
            const rk: u8 = if (site.kind == .wx8 or site.kind == .wy8) 0x01 else 0x03;
            put(d, cur, &.{
                0x9C, 0x0A, 0x22, // mask
                0x08, // PHP
                st, 0xF3, 0x37, // value, caller's X width
                0xE2, 0x20, // m8 for the immediates below
                0x48, // PHA (AL; B untouched by anything after)
                0xA9,
                lo,
                0x8D,
                0xF1,
                0x37,
                0xA9,
                hi,
                0x8D,
                0xF2,
                0x37,
                0xA9, rk, 0x8D, 0xF0, 0x37, // filed
                0xAD, 0xF0, 0x37, 0xD0, 0xFB, // until served
                0xA9, 0x10, 0x8D, 0x0A, 0x22, // unmask
                0x68, 0x28, 0x60, // PLA / PLP / RTS
            });
        },
    }
}

/// An indexed MMIO helper: same mailbox, same mask protocol, but the
/// register field is computed at run time — TXA/TYA into a 16-bit A, add
/// the base, file the sum. TXA/TYA read the index in the *caller's* index
/// width (x=1 zero-extends), which is exactly the address arithmetic the
/// original `abs,X`/`abs,Y` performed, so no width case-split is needed.
/// What IS needed is more preservation than the plain helpers: the 16-bit
/// transfer clobbers B, and ADC clobbers C and V, all of which the original
/// store/load left alone — hence the 16-bit PHA and the PLP placed after
/// the arithmetic. An effective address that leaves the MMIO range would be
/// performed verbatim on the S-CPU bus (where low addresses are WRAM the
/// game no longer owns); no shipped game does that from a $21xx/$42xx base,
/// and one that did would fail S4 verification, not ship wrong.
fn wgEmitIndexedHelper(d: []u8, cur: *usize, site: WgSite) void {
    const lo: u8 = @truncate(site.reg);
    const hi: u8 = @truncate(site.reg >> 8);
    const txa: u8 = if (site.idx == .x) 0x8A else 0x98; // TXA / TYA
    switch (site.kind) {
        .w8 => put(d, cur, &.{
            0x9C, 0x0A, 0x22, // STZ CIE: mask
            0x08, // PHP
            0x8D, 0xF3, 0x37, // value (A is the caller's, 8-bit)
            0xC2, 0x20, // REP #$20
            0x48, // PHA: the full C=B:A, which the transfer clobbers
            txa, 0x18, 0x69, lo, hi, // index + base, caller's index width
            0x8D, 0xF1, 0x37, // effective reg
            0xE2, 0x20, // SEP #$20
            0xA9, 0x01, 0x8D, 0xF0, 0x37, // filed: w8
            0xAD, 0xF0, 0x37, 0xD0, 0xFB, // until served
            0xA9, 0x10, 0x8D, 0x0A, 0x22, // unmask
            0xC2, 0x20, 0x68, // REP / PLA: B:A back
            0x28, 0x60, // PLP / RTS
        }),
        .stz8, .stz16, .c8, .c16, .wx8, .wx16, .wy8, .wy16 => unreachable,
        // Loads into an index register (LDY abs,X / LDX abs,Y): the result
        // width is the caller's X width, which conveniently is also the
        // request width. The unmask tail is width-agnostic — PHP right after
        // the load captures its N/Z, SEP pins m for the immediate, and the
        // final PLP restores both the caller's widths and the load's flags.
        .ry8, .ry16, .rx8, .rx16 => {
            const req: u8 = if (site.kind == .ry8 or site.kind == .rx8) 0x02 else 0x04;
            const ld: u8 = if (site.kind == .ry8 or site.kind == .ry16) 0xAC else 0xAE; // LDY/LDX abs
            put(d, cur, &.{
                0x9C, 0x0A, 0x22, // mask
                0x08, // PHP
                0xC2, 0x20, 0x48, // REP / PHA: A survives (the original preserved it)
                txa,  0x18, 0x69, lo,   hi, // effective reg, caller's index width
                0x8D, 0xF1, 0x37, 0xE2, 0x20,
                0xA9, req, 0x8D, 0xF0, 0x37, // filed
                0xAD, 0xF0, 0x37, 0x10, 0xFB, // until the $FE marker
                0xC2, 0x20, 0x68, // A back
                0x28, // PLP: caller widths (X width sizes the load below)
                ld, 0xF3, 0x37, // result -> Y or X, N/Z as the original
                0x9C, 0xF0, 0x37, // release (no flags)
                0x08, 0xE2, 0x20, 0x48, 0xA9, 0x10, 0x8D, 0x0A, 0x22, 0x68, 0x28, // unmask
                0x60,
            });
        },
        .w16 => put(d, cur, &.{
            0x08, 0x48, // PHP / PHA (16-bit)
            0xE2, 0x20, 0x9C, 0x0A, 0x22, // 8-bit: mask
            0xC2, 0x20, // 16-bit again (A untouched by SEP/REP)
            0x8D, 0xF3, 0x37, // 16-bit value
            txa,  0x18, 0x69, lo,   hi, // effective reg
            0x8D, 0xF1, 0x37, 0xE2, 0x20,
            0xA9, 0x03, 0x8D, 0xF0, 0x37, // filed: w16
            0xAD, 0xF0, 0x37, 0xD0, 0xFB,
            0xA9, 0x10, 0x8D, 0x0A, 0x22,
            0xC2, 0x20, 0x68, 0x28, 0x60,
        }),
        .r8 => put(d, cur, &.{
            0x9C, 0x0A, 0x22, // mask
            0x08, // PHP: C and V survive the ADC below
            0xC2, 0x20, 0x48, // REP / PHA: B survives the transfer
            txa,  0x18, 0x69,
            lo,   hi,   0x8D,
            0xF1, 0x37, 0xE2,
            0x20,
            0xA9, 0x02, 0x8D, 0xF0, 0x37, // filed: r8
            0xAD, 0xF0, 0x37, 0x10, 0xFB, // BPL: wait for the $FE marker
            0xC2, 0x20, 0x68, 0xE2, 0x20, // B back (old AL too — about to be replaced)
            0x28, // PLP: caller's flags and widths
            0xAD, 0xF3, 0x37, // result — N/Z now match the original LDA
            0x9C, 0xF0, 0x37, // release the mailbox (no flags)
            0x08, 0x48, 0xA9, 0x10, 0x8D, 0x0A, 0x22, 0x68, 0x28, // unmask, flags kept
            0x60,
        }),
        .r16 => put(d, cur, &.{
            0x08, // PHP
            0xE2, 0x20, 0x9C, 0x0A, 0x22, // 8-bit: mask
            0xC2, 0x20, // A is dead (16-bit load overwrites all of it)
            txa,  0x18,
            0x69, lo,
            hi,   0x8D,
            0xF1, 0x37,
            0xE2, 0x20,
            0xA9, 0x04, 0x8D, 0xF0, 0x37, // filed: r16
            0xAD, 0xF0, 0x37, 0x10, 0xFB,
            0x28, // PLP: caller widths back (m=16 for r16 by construction)
            0xAD, 0xF3, 0x37, // 16-bit result
            0x9C, 0xF0, 0x37, // 16-bit release (also zeroes $37F1)
            0x08, 0x48, 0xE2,
            0x20, 0xA9, 0x10,
            0x8D, 0x0A, 0x22,
            0xC2, 0x20, 0x68,
            0x28, 0x60,
        }),
    }
}

// --- tests ---------------------------------------------------------------------

const testing = std.testing;

/// A minimal LoROM image: header, reset vector at $8000, filler that is not
/// mistakable for padding, and a real padding run for the shim.
fn makeRom(gpa: std.mem.Allocator) ![]u8 {
    const rom = try gpa.alloc(u8, 64 * 1024);
    for (rom, 0..) |*b, i| b.* = @truncate(0x11 + i *% 7);
    const h = rom[0x7FC0..][0..64];
    @memcpy(h[0..21], "SA1 SHELL TEST       ");
    h[0x15] = 0x20;
    h[0x16] = 0x00;
    h[0x17] = 8;
    h[0x18] = 0; // no SRAM (a cart with SRAM refuses)
    std.mem.writeInt(u16, h[0x1C..0x1E], 0xFFFF, .little);
    std.mem.writeInt(u16, h[0x1E..0x20], 0x0000, .little);
    @memset(h[0x20..0x40], 0);
    std.mem.writeInt(u16, h[0x3C..0x3E], 0x8000, .little);
    @memset(rom[0x7E00..0x7FC0], 0xFF); // shim + offload free space
    return rom;
}

test "shell: header, shim, park, and vector all land; refusals name reasons" {
    const gpa = testing.allocator;
    const rom = try makeRom(gpa);
    defer gpa.free(rom);

    var ref: ?Refusal = null;
    const empty: profile.Plan = .{};
    const res = try convert(gpa, rom, &empty, null, &.{}, &.{}, @splat(0), &ref);
    defer gpa.free(res.image);

    const h = try header_mod.detect(res.image);
    // $34 = SA-1 + RAM, NO battery: the BW-RAM is working memory, and a
    // frontend that persisted it would boot the next session into stale
    // mid-game state.
    try testing.expectEqual(@as(u8, 0x34), h.chipset);
    try testing.expectEqual(cartridge.ChipKind.sa1, cartridge.identifyChip(h));
    try testing.expectEqual(res.stats.shim_addr, h.reset_vector);
    try testing.expectEqual(@as(u16, 0xFFFF), h.checksum ^ h.checksum_complement);
    // The shim: SEI first, park stub is SEI/STP at the declared address.
    const shim_file = @as(u32, res.stats.shim_addr) - 0x8000;
    try testing.expectEqual(@as(u8, 0x78), res.image[shim_file]);
    const park_file = @as(u32, res.stats.park_addr) - 0x8000;
    try testing.expectEqualSlices(u8, &.{ 0x78, 0xDB }, res.image[park_file..][0..2]);
    try testing.expect(!res.stats.d_moved);

    // Refusals: SRAM carts and non-LoROM.
    rom[0x7FC0 + 0x18] = 3;
    try testing.expectError(error.Refused, convert(gpa, rom, &empty, null, &.{}, &.{}, @splat(0), &ref));
    try testing.expectEqual(Reason.has_sram, ref.?.reason);
}

/// Build a one-region plan by hand for rewriter tests.
fn onePlan(start: u32, len: u32, dest: profile.PlanDest, dest_off: u32, dp: bool) profile.Plan {
    var p: profile.Plan = .{};
    p.viable = true;
    p.has_dp = dp;
    p.n = 1;
    p.regions[0] = .{
        .start = start,
        .len = len,
        .exact = true,
        .heat = 1,
        .dest = dest,
        .dest_off = dest_off,
        .dp = dp,
        .shared_outside = false,
        .dma_fed = false,
    };
    return p;
}

/// Mark one instruction executed (8-bit widths) in a synthetic usage map.
fn markOp(usage: []u8, cpu_addr: u32) void {
    usage[cpu_addr] |= usage_map.flag_opcode | usage_map.flag_exec |
        usage_map.flag_m | usage_map.flag_x;
}

/// `markOp` for an instruction executed with 16-bit INDEX registers: the
/// immediate's length differs, so the coverage map has to say so or every
/// decode after it slides.
fn markOpX16(usage: []u8, cpu_addr: u32) void {
    usage[cpu_addr] |= usage_map.flag_opcode | usage_map.flag_exec | usage_map.flag_m;
    usage[cpu_addr] &= ~usage_map.flag_x;
}

test "rewriter: long and low-abs sites move; indexed sites block their region" {
    const gpa = testing.allocator;
    const rom = try makeRom(gpa);
    defer gpa.free(rom);
    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);

    // $00:8100: LDA $7E1F20 (long) -> region.
    @memcpy(rom[0x0100..0x0104], &[_]u8{ 0xAF, 0x20, 0x1F, 0x7E });
    markOp(usage, 0x00_8100);
    // $00:8104: STA $1F22 (abs, low mirror) -> region.
    @memcpy(rom[0x0104..0x0107], &[_]u8{ 0x8D, 0x22, 0x1F });
    markOp(usage, 0x00_8104);
    // $00:8107: LDA $0FFF (abs) -> outside every region: untouched.
    @memcpy(rom[0x0107..0x010A], &[_]u8{ 0xAD, 0xFF, 0x0F });
    markOp(usage, 0x00_8107);

    // Clean move to I-RAM offset $80.
    var plan = onePlan(0x1F00, 0x40, .iram, 0x80, false);
    var ref: ?Refusal = null;
    const res = try convert(gpa, rom, &plan, usage, &.{}, &.{}, @splat(0), &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(RegionFate.clean, res.fate[0]);
    try testing.expectEqual(@as(u32, 1), res.stats.rewritten_long);
    try testing.expectEqual(@as(u32, 1), res.stats.rewritten_abs);
    // long $7E:1F20 -> $00:3000+$80+$20 = $00:30A0.
    try testing.expectEqualSlices(u8, &.{ 0xAF, 0xA0, 0x30, 0x00 }, res.image[0x0100..0x0104]);
    // abs $1F22 -> $30A2.
    try testing.expectEqualSlices(u8, &.{ 0x8D, 0xA2, 0x30 }, res.image[0x0104..0x0107]);
    // The out-of-region site is untouched.
    try testing.expectEqualSlices(u8, &.{ 0xAD, 0xFF, 0x0F }, res.image[0x0107..0x010A]);

    // Now add an indexed site into the region: the region blocks, nothing
    // is rewritten, and the shell still converts.
    @memcpy(rom[0x010A..0x010D], &[_]u8{ 0xBD, 0x10, 0x1F }); // LDA $1F10,X
    markOp(usage, 0x00_810A);
    const res2 = try convert(gpa, rom, &plan, usage, &.{}, &.{}, @splat(0), &ref);
    defer gpa.free(res2.image);
    try testing.expectEqual(RegionFate.blocked_indexed, res2.fate[0]);
    try testing.expectEqual(@as(u32, 0), res2.stats.rewritten_long);
    try testing.expectEqualSlices(u8, &.{ 0xAF, 0x20, 0x1F, 0x7E }, res2.image[0x0100..0x0104]);
    try testing.expectEqual(@as(u8, 1), res2.stats.regions_blocked);
}

test "rewriter: the dp window moves as a unit with D=$3000, or not at all" {
    const gpa = testing.allocator;
    const rom = try makeRom(gpa);
    defer gpa.free(rom);
    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);

    // $00:8100: LDA $40 (dp) and $00:8102: STA $7E0041 (long into the window).
    @memcpy(rom[0x0100..0x0102], &[_]u8{ 0xA5, 0x40 });
    markOp(usage, 0x00_8100);
    @memcpy(rom[0x0102..0x0106], &[_]u8{ 0x8F, 0x41, 0x00, 0x7E });
    markOp(usage, 0x00_8102);

    var plan = onePlan(0x40, 0x10, .iram, 0x40, true);
    var ref: ?Refusal = null;
    const res = try convert(gpa, rom, &plan, usage, &.{}, &.{}, @splat(0), &ref);
    defer gpa.free(res.image);
    try testing.expect(res.stats.d_moved);
    try testing.expectEqual(@as(u32, 1), res.stats.dp_sites);
    // The long site into the pinned window rewrites to $00:3041.
    try testing.expectEqualSlices(u8, &.{ 0x8F, 0x41, 0x30, 0x00 }, res.image[0x0102..0x0106]);
    // The shim carries the PEA $3000 / PLD prologue.
    const shim_file = @as(u32, res.stats.shim_addr) - 0x8000;
    try testing.expectEqualSlices(u8, &.{ 0x78, 0xF4, 0x00, 0x30, 0x2B }, res.image[shim_file..][0..5]);

    // A dp,X site into the window blocks the whole window: D stays 0.
    @memcpy(rom[0x0106..0x0108], &[_]u8{ 0xB5, 0x40 }); // LDA $40,X
    markOp(usage, 0x00_8106);
    const res2 = try convert(gpa, rom, &plan, usage, &.{}, &.{}, @splat(0), &ref);
    defer gpa.free(res2.image);
    try testing.expect(!res2.stats.d_moved);
    try testing.expectEqual(RegionFate.blocked_indexed, res2.fate[0]);
    try testing.expectEqualSlices(u8, &.{ 0x8F, 0x41, 0x00, 0x7E }, res2.image[0x0102..0x0106]);
}

test "rewriter: an abs site whose region went to BW-RAM blocks it" {
    const gpa = testing.allocator;
    const rom = try makeRom(gpa);
    defer gpa.free(rom);
    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);

    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0xAD, 0x20, 0x1F }); // LDA $1F20 abs
    markOp(usage, 0x00_8100);
    // The same region reached by long, which alone would be fine in BW-RAM.
    @memcpy(rom[0x0103..0x0107], &[_]u8{ 0xAF, 0x21, 0x1F, 0x7E });
    markOp(usage, 0x00_8103);

    var plan = onePlan(0x1F00, 0x40, .bwram, 0x200, false);
    var ref: ?Refusal = null;
    const res = try convert(gpa, rom, &plan, usage, &.{}, &.{}, @splat(0), &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(RegionFate.blocked_abs_to_bwram, res.fate[0]);
    try testing.expectEqual(@as(u32, 0), res.stats.rewritten_long);

    // Long-only access to a BW-RAM region rewrites to $40:xxxx.
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0xEA, 0xEA, 0xEA }); // drop the abs site
    markOp(usage, 0x00_8100);
    const res2 = try convert(gpa, rom, &plan, usage, &.{}, &.{}, @splat(0), &ref);
    defer gpa.free(res2.image);
    try testing.expectEqual(RegionFate.clean, res2.fate[0]);
    try testing.expectEqualSlices(u8, &.{ 0xAF, 0x21, 0x02, 0x40 }, res2.image[0x0103..0x0107]);
}

test "semantic: a converted cart boots, parks the SA-1, and relocated state lands in I-RAM" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeRom(gpa);
    defer gpa.free(rom);
    // Reset code: LDA #$AB / STA $7E1F00 (long) / spin.
    @memcpy(rom[0x0000..0x0008], &[_]u8{ 0xA9, 0xAB, 0x8F, 0x00, 0x1F, 0x7E, 0x80, 0xFE });

    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);
    markOp(usage, 0x00_8000);
    markOp(usage, 0x00_8002);
    markOp(usage, 0x00_8006);

    // The original writes WRAM.
    {
        const cart = try cartridge.Cartridge.load(gpa, rom);
        const con = try gpa.create(console.FastConsole);
        defer {
            con.cart.deinit(gpa);
            gpa.destroy(con);
        }
        con.init(cart);
        con.runFrame();
        try testing.expectEqual(@as(u8, 0xAB), con.bus.wram.data[0x1F00]);
    }

    // The conversion relocates $7E:1F00 to I-RAM offset $40.
    var plan = onePlan(0x1F00, 0x10, .iram, 0x40, false);
    var ref: ?Refusal = null;
    const res = try convert(gpa, rom, &plan, usage, &.{}, &.{}, @splat(0), &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(RegionFate.clean, res.fate[0]);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    try testing.expectEqual(cartridge.ChipKind.sa1, cart.chip);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    con.runFrame();
    // The value went to I-RAM through the S-CPU window; WRAM stayed clean.
    try testing.expectEqual(@as(u8, 0xAB), con.bus.sa1.iram[0x40]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x1F00]);
}

test "S3b: an offloaded leaf routine runs on the SA-1 and its results marshal back" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeRom(gpa);
    defer gpa.free(rom);
    // Reset at $8000: LDA #$05 / JSR $8020 / STA $7E0100 (long, unmoved) / spin.
    @memcpy(rom[0x0000..0x000B], &[_]u8{
        0xA9, 0x05, // LDA #$05
        0x20, 0x20, 0x80, // JSR $8020
        0x8F, 0x00, 0x01, 0x7E, // STA $7E0100
        0x80, 0xFE, // BRA *
    });
    // Leaf at $8020: LDA $7E1F00 (long -> moved) / INC A / STA $7E1F00 / RTS.
    @memcpy(rom[0x0020..0x002A], &[_]u8{
        0xAF, 0x00, 0x1F, 0x7E,
        0x1A, 0x8F, 0x00, 0x1F,
        0x7E, 0x60,
    });

    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);
    markOp(usage, 0x00_8000);
    markOp(usage, 0x00_8002);
    markOp(usage, 0x00_8005);
    markOp(usage, 0x00_8009);
    markOp(usage, 0x00_8020);
    markOp(usage, 0x00_8024);
    markOp(usage, 0x00_8025);
    markOp(usage, 0x00_8029);

    var plan = onePlan(0x1F00, 0x10, .iram, 0x40, false);
    var ref: ?Refusal = null;
    const res = try convert(gpa, rom, &plan, usage, &.{.{ .entry = 0x00_8020 }}, &.{}, @splat(0), &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u24, 0x8020), res.stats.offloaded);
    try testing.expectEqual(@as(u32, 1), res.stats.offload_sites);

    // Boot it. The S-CPU calls the stub, the SA-1 runs the leaf, and the
    // incremented value comes back through the mailbox.
    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    con.runFrame();
    // The leaf's state lives in I-RAM, written BY THE SA-1; the S-CPU wrote
    // the marshalled return value to unmoved WRAM.
    try testing.expectEqual(@as(u8, 1), con.bus.sa1.iram[0x40]);
    try testing.expectEqual(@as(u8, 1), con.bus.wram.data[0x100]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x1F00]);

    // And the original, for the record: same visible results, no SA-1.
    const cart0 = try cartridge.Cartridge.load(gpa, rom);
    const con0 = try gpa.create(console.FastConsole);
    defer {
        con0.cart.deinit(gpa);
        gpa.destroy(con0);
    }
    con0.init(cart0);
    con0.runFrame();
    try testing.expectEqual(@as(u8, 1), con0.bus.wram.data[0x1F00]);
    try testing.expectEqual(@as(u8, 1), con0.bus.wram.data[0x100]);
}

test "S3b: two routines offload to distinct message ids and both round-trip" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeRom(gpa);
    defer gpa.free(rom);
    // Reset: LDA #$05 / JSR $8020 / JSR $8030 / STA $7E0100 / spin.
    @memcpy(rom[0x0000..0x000E], &[_]u8{
        0xA9, 0x05,
        0x20, 0x20,
        0x80, 0x20,
        0x30, 0x80,
        0x8F, 0x00,
        0x01, 0x7E,
        0x80, 0xFE,
    });
    // Leaf 1 at $8020: INC the moved byte at $7E:1F00 (via rewritten long).
    @memcpy(rom[0x0020..0x002A], &[_]u8{ 0xAF, 0x00, 0x1F, 0x7E, 0x1A, 0x8F, 0x00, 0x1F, 0x7E, 0x60 });
    // Leaf 2 at $8030: ASL the moved byte at $7E:1F08.
    @memcpy(rom[0x0030..0x003B], &[_]u8{ 0xAF, 0x08, 0x1F, 0x7E, 0x1A, 0x1A, 0x8F, 0x08, 0x1F, 0x7E, 0x60 });

    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);
    for ([_]u32{ 0x00_8000, 0x00_8002, 0x00_8005, 0x00_8008, 0x00_800C }) |a| markOp(usage, a);
    for ([_]u32{ 0x00_8020, 0x00_8024, 0x00_8025, 0x00_8029 }) |a| markOp(usage, a);
    for ([_]u32{ 0x00_8030, 0x00_8034, 0x00_8035, 0x00_8036, 0x00_803A }) |a| markOp(usage, a);

    var plan = onePlan(0x1F00, 0x10, .iram, 0x40, false);
    var ref: ?Refusal = null;
    const res = try convert(gpa, rom, &plan, usage, &.{ .{ .entry = 0x00_8020 }, .{ .entry = 0x00_8030 } }, &.{}, @splat(0), &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u8, 2), res.stats.offload_count);
    try testing.expectEqual(@as(u32, 2), res.stats.offload_sites);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    con.runFrame();
    // Both leaves ran on the SA-1: leaf 1 incremented $1F00 (0 -> 1), leaf 2
    // shifted $1F08 twice after INC (A came in as leaf 1's result 1 -> INC 2
    // -> ASL 4? No: leaf 2 loads $1F08 (0), INC 1, ASL 2, stores 2). The
    // marshalled A after leaf 2 (2) lands in unmoved WRAM.
    try testing.expectEqual(@as(u8, 1), con.bus.sa1.iram[0x40]);
    try testing.expectEqual(@as(u8, 2), con.bus.sa1.iram[0x48]);
    try testing.expectEqual(@as(u8, 2), con.bus.wram.data[0x100]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x1F00]);
}

test "S3b pointer offload: a JSL/RTL pointer routine runs on the SA-1 against the shadow" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeRom(gpa);
    defer gpa.free(rom);
    @memset(rom[0xE000..0x10000], 0xFF); // bank $01 tail: pointer-stub carve space

    // Caller at $8000: [$00] -> ROM data at $00:9000, ($03) -> $1F00 (the
    // DB idiom in the routine picks the bank), JSL the routine, publish a
    // copied byte to unmoved WRAM, spin.
    @memcpy(rom[0x0000..0x0024], &[_]u8{
        0x18, 0xFB, // CLC / XCE
        0xE2, 0x30, // SEP #$30
        0x64, 0x00, // STZ $00
        0xA9, 0x90, 0x85, 0x01, // src = $00:9000
        0x64, 0x02, // src bank $00
        0x64, 0x03, // dst = $1F00
        0xA9, 0x1F,
        0x85, 0x04,
        0xA9, 0x7E, 0x85, 0x05, // dst bank byte (realistic clutter; (dp),y ignores it)
        0x22, 0x40, 0x80, 0x00, // JSL $00:8040
        0xAF, 0x02, 0x1F, 0x7E, // LDA $7E:1F02
        0x8F, 0x00, 0x01, 0x7E, // STA $7E:0100 (marker)
        0x80, 0xFE, // BRA *
    });
    // The routine at $8040 — the Gradius-decompressor shape in miniature:
    // JSL/RTL, the LDA #$7E/PHA/PLB idiom, a long-indirect read through a
    // dp pointer ([$00],y — bank slot at $02), and a DB-relative indirect
    // write (($03),y). Copies 4 bytes of ROM into WRAM via pointers.
    @memcpy(rom[0x0040..0x0052], &[_]u8{
        0x8B, // PHB
        0xA9, 0x7E, 0x48, 0xAB, // LDA #$7E / PHA / PLB (-> shadow bank)
        0xA0, 0x00, // LDY #$00
        0xB7, 0x00, // loop: LDA [$00],y
        0x91, 0x03, // STA ($03),y
        0xC8, // INY
        0xC0, 0x04, // CPY #$04
        0xD0, 0xF7, // BNE loop
        0xAB, // PLB
        0x6B, // RTL
    });
    @memcpy(rom[0x1000..0x1004], &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF }); // $00:9000

    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8006, 0x8008, 0x800A, 0x800C, 0x800E, 0x8010, 0x8012, 0x8014, 0x8016, 0x801A, 0x801E, 0x8022 }) |a| markOp(usage, a);
    for ([_]u32{ 0x8040, 0x8041, 0x8043, 0x8044, 0x8045, 0x8047, 0x8049, 0x804B, 0x804C, 0x804E, 0x8050, 0x8051 }) |a| markOp(usage, a);

    // A viable plan with a vacuous region (nothing references it), and the
    // routine's profiled pages: page 0 (dp cells and pointers) + page $1F
    // (the destination buffer).
    var plan = onePlan(0x0F00, 0x10, .iram, 0x80, false);
    var pages: profile.WramPages = @splat(0);
    pages[0] |= 1 << 0;
    pages[0] |= 1 << 0x1F;
    var ref: ?Refusal = null;
    const res = try convert(gpa, rom, &plan, usage, &.{.{ .entry = 0x00_8040, .pages = pages }}, &.{}, @splat(0), &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u8, 1), res.stats.pointer_offloads);
    try testing.expectEqual(@as(u8, 1), res.stats.offload_count);
    try testing.expectEqual(@as(u32, 1), res.stats.offload_sites);
    // The shadow needs the full 128 KiB of BW-RAM declared.
    try testing.expectEqual(@as(u8, 0x07), res.image[0x7FC0 + 0x18]);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    con.runFrame();
    // The pointer walk copied ROM through the shadow and the marshal
    // brought it home: the caller sees its data in WRAM as always.
    try testing.expectEqualSlices(u8, &.{ 0xDE, 0xAD, 0xBE, 0xEF }, con.bus.wram.data[0x1F00..0x1F04]);
    try testing.expectEqual(@as(u8, 0xBE), con.bus.wram.data[0x0100]);
    // And the SA-1 really did the work, visible two ways: the shadow
    // (BW-RAM linear $11F00, bank $41's identity image of $7E:1F00)
    // carries the same bytes — no S-CPU game code path writes there —
    // and the mailbox holds the routine's marshalled exit state (A = the
    // last copied byte, Y = the loop's exit count), which only the SA-1
    // dispatcher writes after running the routine.
    try testing.expectEqualSlices(u8, &.{ 0xDE, 0xAD, 0xBE, 0xEF }, con.bus.sa1.bwram[0x11F00..0x11F04]);
    try testing.expectEqual(@as(u8, 0xEF), con.bus.sa1.iram[0x780]);
    try testing.expectEqual(@as(u8, 0x04), con.bus.sa1.iram[0x784]);
}

test "residency: private data lives in BW-RAM, is never marshalled, and both CPUs share it" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeRom(gpa);
    defer gpa.free(rom);
    @memset(rom[0xE000..0x10000], 0xFF);

    // Same shape as the marshalling test, with ONE difference that
    // decides residency: nothing outside the routine names the buffer.
    // The caller sets the pointers, calls, and publishes the routine's
    // returned A — it never reads $7E:1Fxx itself, so those pages are
    // private and can move to BW-RAM for good.
    @memcpy(rom[0x0000..0x0024], &[_]u8{
        0x18, 0xFB,
        0xE2, 0x30,
        0x64, 0x00,
        0xA9, 0x90,
        0x85, 0x01,
        0x64, 0x02,
        0x64, 0x03,
        0xA9, 0x1F,
        0x85, 0x04,
        0xA9, 0x7E,
        0x85, 0x05,
        0x22, 0x40, 0x80, 0x00, // JSL $00:8040
        0xEA, 0xEA, 0xEA, 0xEA, // (no read of the buffer)
        0x8F, 0x00, 0x01, 0x7E, // STA $7E:0100 — page $01, not the buffer
        0x80, 0xFE,
    });
    @memcpy(rom[0x0040..0x0052], &[_]u8{
        0x8B,
        0xA9,
        0x7E,
        0x48,
        0xAB,
        0xA0,
        0x00,
        0xB7,
        0x00,
        0x91,
        0x03,
        0xC8,
        0xC0,
        0x04,
        0xD0,
        0xF7,
        0xAB,
        0x6B,
    });
    @memcpy(rom[0x1000..0x1004], &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF });

    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8006, 0x8008, 0x800A, 0x800C, 0x800E, 0x8010, 0x8012, 0x8014, 0x8016, 0x801A, 0x801B, 0x801C, 0x801D, 0x801E, 0x8022 }) |a| markOp(usage, a);
    for ([_]u32{ 0x8040, 0x8041, 0x8043, 0x8044, 0x8045, 0x8047, 0x8049, 0x804B, 0x804C, 0x804E, 0x8050, 0x8051 }) |a| markOp(usage, a);

    var plan = onePlan(0x0F00, 0x10, .iram, 0x80, false);
    var pages: profile.WramPages = @splat(0);
    pages[0] |= 1 << 0; // dp page (stays marshalled — dp is always bank $00)
    pages[0] |= 1 << 0x1F; // the buffer: private, so it becomes resident
    var ref: ?Refusal = null;
    const res = try convert(gpa, rom, &plan, usage, &.{.{ .entry = 0x00_8040, .pages = pages }}, &.{}, @splat(0), &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u8, 1), res.stats.pointer_offloads);
    try testing.expectEqual(@as(u8, 1), res.stats.resident_offloads);
    // Residency rewrote the ORIGINAL body's data bank, not just the copy:
    // that is what makes the S-CPU's own calls address the same bytes.
    try testing.expectEqual(shadow_bank, res.image[0x0042]);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    con.runFrame();
    // One copy, in BW-RAM. WRAM never receives it — there is no marshal
    // to bring it back, and nothing left that would read it there.
    try testing.expectEqualSlices(u8, &.{ 0xDE, 0xAD, 0xBE, 0xEF }, con.bus.sa1.bwram[0x11F00..0x11F04]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, con.bus.wram.data[0x1F00..0x1F04]);
    // The routine still ran and returned: its last loaded byte reached
    // the caller through the register marshal.
    try testing.expectEqual(@as(u8, 0xEF), con.bus.wram.data[0x0100]);
}

test "async: a fire-and-forget resident offload runs, and the fence collects it" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeRom(gpa);
    defer gpa.free(rom);
    @memset(rom[0xE000..0x10000], 0xFF);

    // The residency test's shape, made async-VALID by removing the one
    // thing that broke it on Gradius III: the caller never consumes the
    // routine's result. It sets the pointers, JSLs the routine (whose only
    // effect is writing the resident buffer), and spins. So the SA-1 may
    // run it in the background — the buffer write is the whole point, and
    // nothing reads it back synchronously.
    @memcpy(rom[0x0000..0x0021], &[_]u8{
        0x18, 0xFB, // CLC / XCE
        0xE2, 0x30, // SEP #$30
        0xA9, 0x80, 0x8D, 0x00, 0x42, // LDA #$80 / STA $4200 (NMI on)
        0x64, 0x00, // STZ $00
        0xA9, 0x90, 0x85, 0x01, // ptr lo = $90
        0x64, 0x02, 0x64, 0x03, // ptr hi/bank = 0
        0xA9, 0x1F, 0x85, 0x04, // dest hi = $1F
        0xA9, 0x7E, 0x85, 0x05, // dest bank = $7E (rewritten resident)
        0x22, 0x40, 0x80, 0x00, // JSL $00:8040
        0x80, 0xFE, // BRA * (never reads the buffer)
    });
    @memcpy(rom[0x0040..0x0052], &[_]u8{
        0x8B, 0xA9, 0x7E, 0x48, 0xAB, // PHB / LDA #$7E / PHA / PLB
        0xA0, 0x00, // LDY #0
        0xB7, 0x00, // LDA [$00],Y
        0x91, 0x03, // STA ($03),Y
        0xC8, // INY
        0xC0, 0x04, // CPY #4
        0xD0, 0xF7, // BNE
        0xAB, 0x6B, // PLB / RTL
    });
    @memcpy(rom[0x1000..0x1004], &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF });
    // A real NMI handler (just RTI): the async conversion needs the vector
    // to point at code so its fence prologue can forward to it.
    rom[0x0060] = 0x40; // RTI at $00:8060
    std.mem.writeInt(u16, rom[0x7FEA..][0..2], 0x8060, .little); // native NMI

    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8006, 0x8009, 0x800B, 0x800D, 0x800F, 0x8011, 0x8013, 0x8015, 0x8017, 0x8019, 0x801B, 0x801F }) |a| markOp(usage, a);
    for ([_]u32{ 0x8040, 0x8041, 0x8043, 0x8044, 0x8045, 0x8047, 0x8049, 0x804B, 0x804C, 0x804E, 0x8050, 0x8051 }) |a| markOp(usage, a);
    markOp(usage, 0x8060);

    var plan = onePlan(0x0F00, 0x10, .iram, 0x80, false);
    var pages: profile.WramPages = @splat(0);
    pages[0] |= 1 << 0;
    pages[0] |= 1 << 0x1F;
    var ref: ?Refusal = null;
    // no_async defaults false: the gate must pick async when it qualifies.
    const res = try convert(gpa, rom, &plan, usage, &.{.{ .entry = 0x00_8040, .pages = pages }}, &.{}, @splat(0), &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u24, 0x00_8040), res.stats.async_entry);
    try testing.expect(res.stats.async_fence != 0);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    const sa1_trace = @import("../sa1_trace.zig");
    const trace = try gpa.create(sa1_trace.Trace);
    defer gpa.destroy(trace);
    trace.* = sa1_trace.Trace.init(0x01_F800);
    con.bus.sa1.trace = trace;
    // A few frames: the async stub fires the SA-1 and the S-CPU spins; the
    // NMI fence at each frame boundary drains any in-flight call, so the
    // resident buffer holds the copy — computed on the SA-1, collected by
    // the fence, never marshalled to WRAM.
    for (0..3) |_| con.runFrame();
    try testing.expectEqualSlices(u8, &.{ 0xDE, 0xAD, 0xBE, 0xEF }, con.bus.sa1.bwram[0x11F00..0x11F04]);
    // The SA-1 did the work (the trace watched the body copy execute),
    // and the handshake fully drained: busy idle, both message ports
    // clear — the fence collected the call, nothing is left in flight.
    try testing.expect(trace.total > 0);
    try testing.expectEqual(@as(u8, 0), con.bus.sa1.iram[0x38A]);
    try testing.expectEqual(@as(u4, 0), con.bus.sa1.smeg);
    try testing.expectEqual(@as(u4, 0), con.bus.sa1.cmeg);
}

test "tree offload: a root with a JSL helper, DB-pinned abs, and long-WRAM rewrites round-trips" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeRom(gpa);
    defer gpa.free(rom);
    @memset(rom[0xE000..0x10000], 0xFF);

    // Caller: seed WRAM $1234, JSL the root, spin. The caller's own
    // absolute store also makes page $12 "named outside", so the tree is
    // NOT resident — the marshalled path is what this test exercises.
    @memcpy(rom[0x0000..0x000F], &[_]u8{
        0x18, 0xFB, // CLC / XCE
        0xE2, 0x30, // SEP #$30
        0xA9, 0x77, // LDA #$77
        0x8D, 0x34, 0x12, // STA $1234 (WRAM low mirror, DB=0)
        0x22, 0x40, 0x80, 0x00, // JSL $00:8040
        0x80, 0xFE, // BRA *
    });
    // Root: pin DB=$7E by the idiom, write $1F00 through the pinned
    // bank (an ABSOLUTE store — refused before DB tracking), JSL the
    // helper, restore, RTL.
    @memcpy(rom[0x0040..0x0050], &[_]u8{
        0x8B, // PHB
        0xA9, 0x7E, 0x48, 0xAB, // LDA #$7E / PHA / PLB (pin + rewrite site)
        0xA9, 0x55, // LDA #$55
        0x8D, 0x00, 0x1F, // STA $1F00 (abs under the pin)
        0x22, 0x60, 0x80, 0x00, // JSL $00:8060 — a tree member
        0xAB, // PLB (unpin)
        0x6B, // RTL
    });
    // Helper: long-WRAM read-modify-write through the $00 low mirror —
    // both bank bytes become the shadow bank in the SA-1's copy.
    @memcpy(rom[0x0060..0x006C], &[_]u8{
        0xAF, 0x34, 0x12, 0x00, // LDA $00:1234
        0x18, 0x69, 0x01, // CLC / ADC #$01
        0x8F, 0x35, 0x12, 0x00, // STA $00:1235
        0x6B, // RTL
    });

    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8006, 0x8009, 0x800D }) |a| markOp(usage, a);
    for ([_]u32{ 0x8040, 0x8041, 0x8043, 0x8044, 0x8045, 0x8047, 0x804A, 0x804E, 0x804F }) |a| markOp(usage, a);
    for ([_]u32{ 0x8060, 0x8064, 0x8065, 0x8067, 0x806B }) |a| markOp(usage, a);

    var plan = onePlan(0x0F00, 0x10, .iram, 0x80, false);
    var pages: profile.WramPages = @splat(0);
    pages[0] |= 1 << 0; // dp page
    pages[0] |= 1 << 0x12; // the helper's long-WRAM cells
    pages[0] |= 1 << 0x1F; // the root's pinned-abs target
    var ref: ?Refusal = null;
    const res = try convert(gpa, rom, &plan, usage, &.{.{ .entry = 0x00_8040, .pages = pages }}, &.{}, @splat(0), &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u8, 1), res.stats.pointer_offloads);
    try testing.expectEqual(@as(u8, 0), res.stats.resident_offloads);
    // Both members copied: 16 (root) + 12 (helper).
    try testing.expectEqual(@as(u32, 28), res.stats.offload_copy_len[0]);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    con.runFrame();
    // The root's pinned-abs store and the helper's long RMW both ran on
    // the SA-1 against the shadow and marshalled home.
    try testing.expectEqual(@as(u8, 0x55), con.bus.wram.data[0x1F00]);
    try testing.expectEqual(@as(u8, 0x77), con.bus.wram.data[0x1234]);
    try testing.expectEqual(@as(u8, 0x78), con.bus.wram.data[0x1235]);
}

test "sa1 trace: the SA-1's path through an offloaded body is observable" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");
    const sa1_trace = @import("../sa1_trace.zig");

    // Same cart as the pointer-offload test, re-converted here so the
    // trace watches a body whose expected path is known exactly.
    const rom = try makeRom(gpa);
    defer gpa.free(rom);
    @memset(rom[0xE000..0x10000], 0xFF);
    @memcpy(rom[0x0000..0x0024], &[_]u8{
        0x18, 0xFB,
        0xE2, 0x30,
        0x64, 0x00,
        0xA9, 0x90,
        0x85, 0x01,
        0x64, 0x02,
        0x64, 0x03,
        0xA9, 0x1F,
        0x85, 0x04,
        0xA9, 0x7E,
        0x85, 0x05,
        0x22, 0x40,
        0x80, 0x00,
        0xAF, 0x02,
        0x1F, 0x7E,
        0x8F, 0x00,
        0x01, 0x7E,
        0x80, 0xFE,
    });
    // $8040: PHB / LDA #$7E / PHA / PLB / LDY #0 / loop: LDA [$00],y /
    // STA ($03),y / INY / CPY #4 / BNE loop / PLB / RTL. The BNE at
    // $804e is taken 3 times and falls through once.
    @memcpy(rom[0x0040..0x0052], &[_]u8{
        0x8B,
        0xA9,
        0x7E,
        0x48,
        0xAB,
        0xA0,
        0x00,
        0xB7,
        0x00,
        0x91,
        0x03,
        0xC8,
        0xC0,
        0x04,
        0xD0,
        0xF7,
        0xAB,
        0x6B,
    });
    @memcpy(rom[0x1000..0x1004], &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF });

    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8006, 0x8008, 0x800A, 0x800C, 0x800E, 0x8010, 0x8012, 0x8014, 0x8016, 0x801A, 0x801E, 0x8022 }) |a| markOp(usage, a);
    for ([_]u32{ 0x8040, 0x8041, 0x8043, 0x8044, 0x8045, 0x8047, 0x8049, 0x804B, 0x804C, 0x804E, 0x8050, 0x8051 }) |a| markOp(usage, a);

    var plan = onePlan(0x0F00, 0x10, .iram, 0x80, false);
    var pages: profile.WramPages = @splat(0);
    pages[0] |= 1 << 0;
    pages[0] |= 1 << 0x1F;
    var ref: ?Refusal = null;
    const res = try convert(gpa, rom, &plan, usage, &.{.{ .entry = 0x00_8040, .pages = pages }}, &.{}, @splat(0), &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u8, 1), res.stats.pointer_offloads);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    // Watch the tail of bank $01, where the pointer stub and the body
    // copy are carved (findFreeSpace takes the end of the longest run).
    const trace = try gpa.create(sa1_trace.Trace);
    defer gpa.destroy(trace);
    trace.* = sa1_trace.Trace.init(0x01_F800);
    con.bus.sa1.trace = trace;
    con.runFrame();

    // The SA-1 executed, and the trace saw it — not merely "something
    // ran": the marshalled result proves the same run the offload made.
    try testing.expect(trace.total > 0);
    try testing.expectEqualSlices(u8, &.{ 0xDE, 0xAD, 0xBE, 0xEF }, con.bus.wram.data[0x1F00..0x1F04]);

    // The body copy's own path, read straight out of the coverage: every
    // instruction of the copied routine ran, and the loop's branch ran
    // exactly as many times as the loop iterated.
    var body: ?u24 = null;
    var addr: u24 = 0x01_F800;
    while (addr < 0x01_F800 + sa1_trace.window_cap) : (addr += 1) {
        // The copy starts with the original's PHB opcode ($8B) and is the
        // only $8B in the carve that the SA-1 actually executed.
        const file: u32 = (@as(u32, addr >> 16) * 0x8000) + ((addr & 0xFFFF) - 0x8000);
        if (trace.ran(addr) and res.image[file] == 0x8B) {
            body = addr;
            break;
        }
    }
    const b = body orelse return error.BodyNeverRan;
    // PHB once per call, and the loop's BNE once per iteration (4).
    try testing.expectEqual(@as(u32, 1), trace.countAt(b));
    try testing.expectEqual(@as(u32, 4), trace.countAt(b + 14)); // BNE
    // The RTL closed the call.
    try testing.expect(trace.ran(b + 17));

    // And the register ring carries the state the branch decided on: the
    // last in-window record is a real instruction with plausible state.
    var buf: [sa1_trace.ring_cap]sa1_trace.Rec = undefined;
    const recent = trace.recent(&buf);
    try testing.expect(recent.len > 0);
    try testing.expect(recent[recent.len - 1].pc >= 0x01_F800);
}

test "S3b eligibility: calls, unseen code, indexed data, and unmoved WRAM all refuse" {
    const gpa = testing.allocator;
    const rom = try makeRom(gpa);
    defer gpa.free(rom);
    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);
    var plan = onePlan(0x1F00, 0x10, .iram, 0x40, false);
    var res: Result = .{ .image = rom, .stats = .{}, .fate = @splat(.clean) };

    // A JSR inside the span: not a leaf.
    @memcpy(rom[0x0020..0x0024], &[_]u8{ 0x20, 0x00, 0x90, 0x60 });
    markOp(usage, 0x00_8020);
    markOp(usage, 0x00_8023);
    try testing.expect(!eligibleLeaf(rom, usage, &plan, &res, 0x8020));

    // Unmoved WRAM via long: the SA-1 cannot see it.
    @memcpy(rom[0x0020..0x0025], &[_]u8{ 0xAF, 0x00, 0x50, 0x7E, 0x60 });
    markOp(usage, 0x00_8024);
    try testing.expect(!eligibleLeaf(rom, usage, &plan, &res, 0x8020));

    // Indexed data: refused.
    @memcpy(rom[0x0020..0x0024], &[_]u8{ 0xBD, 0x00, 0x30, 0x60 });
    try testing.expect(!eligibleLeaf(rom, usage, &plan, &res, 0x8020));

    // A clean I-RAM-window access is eligible.
    @memcpy(rom[0x0020..0x0024], &[_]u8{ 0xAD, 0x40, 0x30, 0x60 });
    try testing.expect(eligibleLeaf(rom, usage, &plan, &res, 0x8020));

    // Uncovered code (no opcode flag): refused.
    try testing.expect(!eligibleLeaf(rom, usage, &plan, &res, 0x8040));
}

/// A LoROM for whole-game tests: header, room for real code at the front of
/// the bank, and a wide padding run so the carve (helpers + four stubs +
/// the service loop) always fits.
fn makeWgRom(gpa: std.mem.Allocator) ![]u8 {
    const rom = try gpa.alloc(u8, 64 * 1024);
    for (rom, 0..) |*b, i| b.* = @truncate(0x11 + i *% 7);
    const h = rom[0x7FC0..][0..64];
    @memcpy(h[0..21], "WG MIGRATION TEST    ");
    h[0x15] = 0x20;
    h[0x16] = 0x00;
    h[0x17] = 8;
    h[0x18] = 0;
    std.mem.writeInt(u16, h[0x1C..0x1E], 0xFFFF, .little);
    std.mem.writeInt(u16, h[0x1E..0x20], 0x0000, .little);
    @memset(h[0x20..0x40], 0);
    std.mem.writeInt(u16, h[0x3C..0x3E], 0x8000, .little);
    @memset(rom[0x1000..0x7FC0], 0xFF); // carve space
    return rom;
}

test "window: the game keeps running on the S-CPU with its WRAM moved wholesale" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    // The game: dp store (rides the shim's D=$6000), absolute store,
    // INDEXED absolute store (the shape no per-region move can carry and
    // the uniform window's whole reason to exist), a $7E long store, MMIO
    // natively (NMITIMEN), then spin. The NMI handler counts frames
    // through a rewritten absolute — vectors untouched, S-CPU context,
    // pushes landing in the window stack.
    @memcpy(rom[0x0000..0x0021], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, // CLC / XCE / SEP #$30
        0xA9, 0x55, 0x85, 0x20, // STA $20 (dp -> D=$6000 -> BW-RAM $20)
        0xA9, 0x66, 0x8D, 0x00, 0x01, // STA $0100 (abs -> $6100)
        0xA2, 0x05, // LDX #$05
        0xA9, 0x77, 0x9D, 0x00, 0x01, // STA $0100,X (indexed -> $6100,X)
        0xA9, 0x88, 0x8F, 0x34, 0x12, 0x7E, // STA $7E:1234 (long -> $40:1234)
        0xA9, 0x80, 0x8D, 0x00, 0x42, // NMITIMEN: NMI on (native MMIO)
        0x80, 0xFE, // spin
    });
    // NMI handler at $8040: PHA / INC $0040 / PLA / RTI.
    @memcpy(rom[0x0040..0x0046], &[_]u8{ 0x48, 0xEE, 0x40, 0x00, 0x68, 0x40 });
    std.mem.writeInt(u16, rom[0x7FC0 + 0x2A ..][0..2], 0x8040, .little);

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    const map: usage_map.UsageMap = .{ .bytes = bytes };
    const frames = 10;
    {
        const cart = try cartridge.Cartridge.load(gpa, rom);
        const con = try gpa.create(console.ProfilingConsole);
        defer {
            con.cart.deinit(gpa);
            gpa.destroy(con);
        }
        con.init(cart);
        con.usage = &map;
        for (0..frames) |_| con.runFrame();
        try testing.expectEqual(@as(u8, 0x55), con.bus.wram.data[0x0020]);
        try testing.expectEqual(@as(u8, 0x66), con.bus.wram.data[0x0100]);
        try testing.expectEqual(@as(u8, 0x77), con.bus.wram.data[0x0105]);
        try testing.expectEqual(@as(u8, 0x88), con.bus.wram.data[0x1234]);
        try testing.expect(con.bus.wram.data[0x0040] >= frames - 2);
    }

    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, bytes, null, null, false, true, &.{}, false, 0, copy_reserve, null, &ref);
    defer gpa.free(res.image);
    // Two plain abs, one indexed abs, one INC in the NMI handler; one long.
    try testing.expect(res.stats.rewritten_abs >= 3);
    try testing.expect(res.stats.rewritten_long >= 1);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    try testing.expectEqual(cartridge.ChipKind.sa1, cart.chip);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    for (0..frames) |_| con.runFrame();
    // Everything landed in BW-RAM at identity offsets — dp through the
    // moved D, plain and INDEXED absolutes through the +$6000 window, the
    // long store through bank $40, and the NMI counter from S-CPU
    // interrupt context through its rewritten INC. WRAM saw none of it.
    try testing.expectEqual(@as(u8, 0x55), con.bus.sa1.bwram[0x0020]);
    try testing.expectEqual(@as(u8, 0x66), con.bus.sa1.bwram[0x0100]);
    try testing.expectEqual(@as(u8, 0x77), con.bus.sa1.bwram[0x0105]);
    try testing.expectEqual(@as(u8, 0x88), con.bus.sa1.bwram[0x1234]);
    try testing.expect(con.bus.sa1.bwram[0x0040] >= frames - 2);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0020]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0100]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0105]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x1234]);
    // The SA-1 never ran: no shim write ever released it, so its message
    // ports never moved — the cart is carried for its RAM.
    try testing.expectEqual(@as(u4, 0), con.bus.sa1.smeg);
    try testing.expectEqual(@as(u4, 0), con.bus.sa1.cmeg);
}

test "window: the BW-RAM window mirrors in banks $80-$BF like the hardware" {
    // The FastROM bank lift turns `LDA $03:0002,X` into `LDA $83:0002,X`.
    // GIII's slot walker serves ROM nodes AND relocated-WRAM nodes through
    // that one instruction (stock reads the WRAM mirror; the conversion
    // reads the window), so bank $83's $6000-$7FFF must reach the SAME
    // BW-RAM bytes as bank $03's — as it does on the real chip.
    const gpa = testing.allocator;
    const console = @import("../console.zig");
    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, bytes, null, null, false, true, &.{}, false, 0, copy_reserve, null, &ref);
    defer gpa.free(res.image);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    con.runFrame(); // boot: shim opens SBM/SWEN
    con.bus.write8(0x00_6012, 0xA7);
    try testing.expectEqual(@as(u8, 0xA7), con.bus.read8(0x00_6012));
    try testing.expectEqual(@as(u8, 0xA7), con.bus.read8(0x03_6012));
    try testing.expectEqual(@as(u8, 0xA7), con.bus.read8(0x83_6012));
    con.bus.write8(0xA1_6013, 0x5C); // write through a high mirror too
    try testing.expectEqual(@as(u8, 0x5C), con.bus.read8(0x21_6013));
}

test "window offload: a tree runs on the SA-1 against the shared window, sync and async" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");
    const sa1_trace = @import("../sa1_trace.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    @memset(rom[0x8000..0x10000], 0xFF); // bank 1: the any-bank carve
    // Caller: NMI on, then JSL the tree forever. Tree root stores a
    // marker and JSLs a helper that increments a counter — both through
    // absolute addresses the window rewrite moves to $65xx, which is
    // BW-RAM $05xx for BOTH CPUs.
    @memcpy(rom[0x0000..0x000F], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, // CLC / XCE / SEP #$30
        0xA9, 0x80, 0x8D, 0x00, 0x42, // NMITIMEN: NMI on
        0x22, 0x80, 0x80, 0x00, // JSL $00:8080
        0x80, 0xFA, // BRA back to the JSL
    });
    @memcpy(rom[0x0040..0x0046], &[_]u8{ 0x48, 0xEE, 0x40, 0x00, 0x68, 0x40 }); // NMI: INC $0040
    std.mem.writeInt(u16, rom[0x7FC0 + 0x2A ..][0..2], 0x8040, .little);
    @memcpy(rom[0x0080..0x008A], &[_]u8{
        0xA9, 0x11, 0x8D, 0x00, 0x05, // LDA #$11 / STA $0500
        0x22, 0xA0, 0x80, 0x00, // JSL $00:80A0
        0x6B, // RTL
    });
    @memcpy(rom[0x00A0..0x00A4], &[_]u8{ 0xEE, 0x01, 0x05, 0x6B }); // INC $0501 / RTL

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8006, 0x8009, 0x800D }) |a| markOp(bytes, a);
    for ([_]u32{ 0x8040, 0x8041, 0x8044, 0x8045 }) |a| markOp(bytes, a);
    for ([_]u32{ 0x8080, 0x8082, 0x8085, 0x8089 }) |a| markOp(bytes, a);
    for ([_]u32{ 0x80A0, 0x80A3 }) |a| markOp(bytes, a);

    const cand = [_]Candidate{.{ .entry = 0x00_8080 }};
    for ([_]bool{ false, true }) |go_async| {
        var ref: ?Refusal = null;
        const res = try convertWholeGame(gpa, rom, bytes, null, null, false, true, &cand, go_async, 0, copy_reserve, null, &ref);
        defer gpa.free(res.image);
        try testing.expectEqual(@as(u8, 1), res.stats.offload_count);
        try testing.expectEqual(@as(u8, 1), res.stats.resident_offloads);
        if (go_async) {
            try testing.expectEqual(@as(u24, 0x00_8080), res.stats.async_entry);
            try testing.expect(res.stats.async_fence != 0);
        } else {
            try testing.expectEqual(@as(u24, 0), res.stats.async_entry);
        }

        const cart = try cartridge.Cartridge.load(gpa, res.image);
        const con = try gpa.create(console.FastConsole);
        defer {
            con.cart.deinit(gpa);
            gpa.destroy(con);
        }
        con.init(cart);
        // Watch the copy execute on the SA-1.
        const trace = try gpa.create(sa1_trace.Trace);
        defer gpa.destroy(trace);
        const copy24 = res.stats.offload_copy[0];
        trace.* = sa1_trace.Trace.init(copy24);
        con.bus.sa1.trace = trace;
        for (0..5) |_| con.runFrame();
        // The tree's effects land in the shared BW-RAM, computed by the
        // SA-1 (the trace watched the copy), visible untranslated to the
        // S-CPU. Real WRAM saw none of it.
        try testing.expectEqual(@as(u8, 0x11), con.bus.sa1.bwram[0x0500]);
        try testing.expect(con.bus.sa1.bwram[0x0501] > 2); // called repeatedly (rate is timing-dependent)
        try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0500]);
        try testing.expect(con.bus.sa1.bwram[0x0040] >= 3); // NMI counter
        try testing.expect(trace.total > 0);
        // (No port-idle assert: the caller loops hot, so a sampled
        // instant is legitimately mid-handshake.)
    }
}

test "window offload: a BW-RAM-pinned caller's registers survive the dispatch" {
    // The async flavor's runaway, reduced. A caller pinned to $7E
    // (re-banked to $40) marshals DBR=$40 — and the dispatcher's
    // unmarshal used to run AFTER the game DBR was set, so its absolute
    // $37xx reads landed in BW-RAM game data instead of I-RAM: the tree
    // ran with whatever bytes the game kept there. The caller here
    // poisons exactly those BW-RAM shadows with $FF first ($7E:3780 and
    // $7E:3786 — the A and P cells), then calls with A=$55 and carry
    // set; the tree must see the REAL registers through both flavors.
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    @memset(rom[0x8000..0x10000], 0xFF);
    @memcpy(rom[0x0000..0x0024], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, // CLC / XCE / SEP #$30
        0xA9, 0x80, 0x8D, 0x00, 0x42, // NMITIMEN: NMI on
        0xA9, 0xFF, 0x8F, 0x86, 0x37, 0x7E, // poison the P cell's BW-RAM shadow
        0x8F, 0x80, 0x37, 0x7E, // and the A cell's
        0xA9, 0x7E, 0x48, 0xAB, // pin DBR = $7E (re-banked to $40)
        0xA9, 0x55, // the value the tree must see
        0x38, // SEC — and the carry it must see
        0x22, 0x80, 0x80, 0x00, // JSL $00:8080
        0xA9, 0x00, 0x48, 0xAB, // back to the system bank
        0x80, 0xEF, // BRA to the re-pin
    });
    @memcpy(rom[0x0040..0x0046], &[_]u8{ 0x48, 0xEE, 0x40, 0x00, 0x68, 0x40 }); // NMI: INC $0040
    std.mem.writeInt(u16, rom[0x7FC0 + 0x2A ..][0..2], 0x8040, .little);
    // Long stores only: the tree's observations must not depend on the
    // caller's DBR — the registers are what is under test here.
    @memcpy(rom[0x0080..0x008D], &[_]u8{
        0x8F, 0x00, 0x05, 0x7E, // STA $7E:0500 — the marshalled A, or the poison
        0x90, 0x06, // BCC +6 — the marshalled carry
        0xA9, 0xAA, 0x8F, 0x03, 0x05, 0x7E, // LDA #$AA / STA $7E:0503
        0x6B,
    });

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8006, 0x8009, 0x800B, 0x800F, 0x8013, 0x8015, 0x8016, 0x8017, 0x8019, 0x801A, 0x801E, 0x8020, 0x8021, 0x8022 }) |a| markOp(bytes, a);
    for ([_]u32{ 0x8040, 0x8041, 0x8044, 0x8045 }) |a| markOp(bytes, a);
    for ([_]u32{ 0x8080, 0x8084, 0x8086, 0x8088, 0x808C }) |a| markOp(bytes, a);

    const cand = [_]Candidate{.{ .entry = 0x00_8080 }};
    for ([_]bool{ false, true }) |go_async| {
        var ref: ?Refusal = null;
        const res = try convertWholeGame(gpa, rom, bytes, null, null, false, true, &cand, go_async, 0, copy_reserve, null, &ref);
        defer gpa.free(res.image);
        try testing.expectEqual(@as(u8, 1), res.stats.offload_count);

        const cart = try cartridge.Cartridge.load(gpa, res.image);
        const con = try gpa.create(console.FastConsole);
        defer {
            con.cart.deinit(gpa);
            gpa.destroy(con);
        }
        con.init(cart);
        for (0..5) |_| con.runFrame();
        // The poison is really there — and the tree never read it.
        try testing.expectEqual(@as(u8, 0xFF), con.bus.sa1.bwram[0x3786]);
        try testing.expectEqual(@as(u8, 0xFF), con.bus.sa1.bwram[0x3780]);
        try testing.expectEqual(@as(u8, 0x55), con.bus.sa1.bwram[0x0500]);
        try testing.expectEqual(@as(u8, 0xAA), con.bus.sa1.bwram[0x0503]);
        try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0500]);
    }
}

test "window offload: the root's DBR pin travels through in-tree JSLs and admits an uncovered site" {
    // The $8EF1 shape in miniature: the root pins the WRAM bank (the
    // window rewrite re-banks the idiom to $40), then JSLs a helper whose
    // never-executed branch holds an indexed absolute with MIXED evidence
    // — unshiftable, and the SA-1's own I-RAM if the copy ran it unpinned.
    // Every in-tree path to it carries the root's pin, under which it is
    // BW-RAM data on both buses whatever X holds — so the tree is
    // eligible. Without the pin idiom the same tree must refuse.
    //
    // (Mixed evidence, not zero: a ZERO-evidence tiny-base indexed site is
    // no longer left in place at all — it becomes an index-split thunk,
    // which is a different contract, tested separately.)
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    for ([_]bool{ true, false }) |pinned| {
        const rom = try makeWgRom(gpa);
        defer gpa.free(rom);
        @memset(rom[0x8000..0x10000], 0xFF); // bank 1: the any-bank carve
        @memcpy(rom[0x0000..0x000A], &[_]u8{
            0x18, 0xFB, 0xE2, 0x30, // CLC / XCE / SEP #$30
            0x22, 0x80, 0x80, 0x00, // JSL $00:8080
            0x80, 0xFA, // BRA back to the JSL
        });
        // Root: pin the WRAM bank (or NOPs for the control), store a
        // marker, call the helper.
        @memcpy(rom[0x0080..0x0090], if (pinned) &[_]u8{
            0x8B, // PHB — real trees save the caller's bank
            0xA9, 0x7E, 0x48, 0xAB, // LDA #$7E / PHA / PLB (re-banked to $40)
            0xA9, 0x11, 0x8D, 0x00, 0x05, // LDA #$11 / STA $0500
            0x22, 0xA0, 0x80, 0x00, // JSL $00:80A0
            0xAB, // PLB — and restore it (the vblank guard's inline bail
            // executes this body on the S-CPU; a root that leaked its pin
            // was a test-world artifact no real tree exhibits)
            0x6B, // RTL
        } else &[_]u8{
            0xEA, 0xEA, 0xEA, 0xEA, 0xEA,
            0xA9, 0x11, 0x8D, 0x00, 0x05,
            0x22, 0xA0, 0x80, 0x00, 0xEA,
            0x6B,
        });
        // Helper: a live counter, then a never-taken branch guarding the
        // hazard-shaped site (statically discovered code, zero evidence).
        @memcpy(rom[0x00A0..0x00AB], &[_]u8{
            0xEE, 0x01, 0x05, // INC $0501
            0xA9, 0x01, // LDA #$01
            0xD0, 0x03, // BNE +3 (always taken)
            0x1E, 0x00, 0x00, // ASL $0000,X — never executes
            0x6B, // RTL
        });

        const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
        defer gpa.free(bytes);
        @memset(bytes, 0);
        for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8008 }) |a| markOp(bytes, a);
        if (pinned) {
            for ([_]u32{ 0x8080, 0x8081, 0x8083, 0x8084 }) |a| markOp(bytes, a);
        } else {
            for ([_]u32{ 0x8080, 0x8081, 0x8082, 0x8083, 0x8084 }) |a| markOp(bytes, a);
        }
        for ([_]u32{ 0x8085, 0x8087, 0x808A, 0x808E, 0x808F }) |a| markOp(bytes, a);
        for ([_]u32{ 0x80A0, 0x80A3, 0x80A5, 0x80A7, 0x80AA }) |a| markOp(bytes, a);
        // The helper's live sites measured as $7E-mediated traffic (the
        // real trees' shape) so the rewriter leaves their operands to the
        // pin; the guarded ASL carries MIXED evidence — unshiftable by any
        // rule, and unthunkable too, which is the hazard shape.
        const sites = try gpa.alloc(u8, usage_map.cpu_map_len);
        defer gpa.free(sites);
        @memset(sites, 0);
        sites[0x80A0] = usage_map.site_wram_bank;
        sites[0x8087] = usage_map.site_wram_bank;
        sites[0x80A7] = usage_map.site_wram_low | usage_map.site_other;

        const cand = [_]Candidate{.{ .entry = 0x00_8080 }};
        var ref: ?Refusal = null;
        const res = try convertWholeGame(gpa, rom, bytes, sites, null, false, true, &cand, false, 0, copy_reserve, null, &ref);
        defer gpa.free(res.image);
        if (!pinned) {
            // Control: the uncovered site with no pin is the I-RAM hazard.
            try testing.expectEqual(@as(u8, 0), res.stats.offload_count);
            continue;
        }
        try testing.expectEqual(@as(u8, 1), res.stats.offload_count);
        try testing.expectEqual(@as(u8, 1), res.stats.resident_offloads);

        const cart = try cartridge.Cartridge.load(gpa, res.image);
        const con = try gpa.create(console.FastConsole);
        defer {
            con.cart.deinit(gpa);
            gpa.destroy(con);
        }
        con.init(cart);
        for (0..5) |_| con.runFrame();
        // The tree ran on the SA-1 against the shared window: marker and
        // counter in BW-RAM (the pinned bank IS the relocated home), real
        // WRAM untouched.
        try testing.expectEqual(@as(u8, 0x11), con.bus.sa1.bwram[0x0500]);
        try testing.expect(con.bus.sa1.bwram[0x0501] > 2);
        try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0500]);
        try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0501]);
    }
}

test "window: a context-split site serves both caller classes through its thunk" {
    // One shared helper, two callers: a system-DBR caller (needs the
    // +$6000 shift) and a $7E-pinned caller (pin re-banked to $40 —
    // needs the operand untouched). Site evidence measures both, the
    // rewriter emits the DBR-dispatch thunk, and at runtime BOTH callers
    // reach the same BW-RAM cell. The system caller also carries SEC
    // across the helper — the thunk must not eat the carry.
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    @memset(rom[0x8000..0x10000], 0xFF);
    @memcpy(rom[0x0000..0x000E], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, // CLC / XCE / SEP #$30
        0x22, 0x80, 0x80, 0x00, // JSL $00:8080 (system caller)
        0x22, 0xC0, 0x80, 0x00, // JSL $00:80C0 (pinned caller)
        0x80, 0xF6, // BRA back to the first JSL
    });
    @memcpy(rom[0x0080..0x008B], &[_]u8{
        0x38, // SEC
        0x22, 0x00, 0x81, 0x00, // JSL $00:8100
        0x90, 0x03, // BCC +3 (carry lost -> skip)
        0xEE, 0x42, 0x01, // INC $0142 (plain site, shifts to the window)
        0x6B, // RTL
    });
    @memcpy(rom[0x00C0..0x00CD], &[_]u8{
        0xA9, 0x7E, 0x48, 0xAB, // pin $7E (re-banked to $40)
        0x22, 0x00, 0x81, 0x00, // JSL $00:8100
        0xA9, 0x00, 0x48, 0xAB, // back to the system bank
        0x6B, // RTL
    });
    @memcpy(rom[0x0100..0x0107], &[_]u8{
        0xEE, 0x40, 0x01, // INC $0140 — the context-split site
        0x9C, 0x41, 0x01, // STZ $0141 — and another
        0x6B, // RTL
    });

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8008, 0x800C }) |a| markOp(bytes, a);
    for ([_]u32{ 0x8080, 0x8081, 0x8085, 0x8087, 0x808A }) |a| markOp(bytes, a);
    for ([_]u32{ 0x80C0, 0x80C2, 0x80C3, 0x80C4, 0x80C8, 0x80CA, 0x80CB, 0x80CC }) |a| markOp(bytes, a);
    for ([_]u32{ 0x8100, 0x8103, 0x8106 }) |a| markOp(bytes, a);
    const sites = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(sites);
    @memset(sites, 0);
    sites[0x8100] = usage_map.site_wram_low | usage_map.site_wram_bank;
    sites[0x8103] = usage_map.site_wram_low | usage_map.site_wram_bank;

    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, bytes, sites, null, false, true, &.{}, false, 0, copy_reserve, null, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u16, 2), res.stats.split_sites);
    try testing.expectEqual(@as(u8, 0x20), res.image[0x0100]); // JSR over the site

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    for (0..5) |_| con.runFrame();
    // Both caller classes reached the SAME relocated cell; real WRAM saw
    // nothing; the system caller's carry survived the thunk every lap.
    try testing.expect(con.bus.sa1.bwram[0x0140] > 4);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0140]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0141]);
    try testing.expect(con.bus.sa1.bwram[0x0142] > 2);
    // $0140 counts both callers per lap, $0142 the system caller alone —
    // 2:1 modulo the lap the frame boundary caught mid-flight (and modulo
    // u8 wrap, so compare through the same wrap).
    const both: u8 = con.bus.sa1.bwram[0x0140];
    const sys_only: u8 = con.bus.sa1.bwram[0x0142];
    const twice: u8 = sys_only *% 2;
    try testing.expect(both -% twice <= 2 or twice -% both <= 2);
}

test "window: an HDMA indirect-bank write loading $7E from data follows WRAM into BW-RAM" {
    // The Ceres-alarm shape, reduced. An indirect HDMA names its WRAM
    // source bank in DASB ($43x7), and the game sets it from a byte it
    // LOADS (here from a ROM table) — no immediate, no long operand, so no
    // static rebanker reaches it. Two writes: channel 2 gets $7E (WRAM,
    // must become $40 so the fetch follows the relocated buffer) and
    // channel 3 gets $80 (a ROM bank, must pass through untouched). The
    // rewriter wraps each store in a runtime rebank thunk.
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    // ROM data the loads read (abs, DBR=$00): $8F00=$7E (WRAM), $8F01=$80.
    rom[0x0F00] = 0x7E;
    rom[0x0F01] = 0x80;
    @memcpy(rom[0x0000..0x0012], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, // CLC / XCE / SEP #$30
        0xAD, 0x00, 0x8F, // LDA $8F00 — A = $7E (a data load, not an immediate)
        0x8D, 0x27, 0x43, // STA $4327 — channel 2 DASB
        0xAD, 0x01, 0x8F, // LDA $8F01 — A = $80
        0x8D, 0x37, 0x43, // STA $4337 — channel 3 DASB
        0x80, 0xFE, // spin
    });

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8007, 0x800A, 0x800D, 0x8010 }) |a| markOp(bytes, a);

    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, bytes, null, null, false, true, &.{}, false, 0, copy_reserve, null, &ref);
    defer gpa.free(res.image);
    // Both DASB stores were wrapped, and each site is now a 3-byte JSR.
    try testing.expectEqual(@as(u32, 2), res.stats.rewritten_dasb);
    try testing.expectEqual(@as(u8, 0x20), res.image[0x0007]);
    try testing.expectEqual(@as(u8, 0x20), res.image[0x000D]);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    for (0..3) |_| con.runFrame();
    // The WRAM bank followed its data into BW-RAM; the ROM bank did not.
    try testing.expectEqual(@as(u8, 0x40), con.bus.dma.channels[2].indirect_bank);
    try testing.expectEqual(@as(u8, 0x80), con.bus.dma.channels[3].indirect_bank);
}

test "window: a low-WRAM indirect-HDMA table address relocates into the window" {
    // The Ceres-escape shape, reduced. An indirect-HDMA table names a
    // per-scanline source in low WRAM ($07EB); the conversion moved that
    // buffer to the window, so the table entry must follow (+$6000). A
    // second entry names upper WRAM ($1234 — still < $2000, also moves); a
    // third names ROM ($9000 — untouched); a zero count ends the table.
    const gpa = testing.allocator;
    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    // Table at $00:8100 (file 0x100 — code-region data the rewriter never
    // walks, not the $FF carve): [count][addr-lo][addr-hi] entries.
    const tf = 0x100;
    @memcpy(rom[tf..][0..10], &[_]u8{
        0x10, 0xEB, 0x07, // $07EB -> $67EB
        0x20, 0x34, 0x12, // $1234 -> $7234
        0x40, 0x00, 0x90, // $9000 (ROM) — unchanged
        0x00, // end
    });

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    var pe: usage_map.PtrBankEvidence = .init;
    pe.addHdmaTable(0x00_8100);

    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, bytes, null, &pe, false, true, &.{}, false, 0, copy_reserve, null, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u32, 2), res.stats.rewritten_hdma_indirect);
    try testing.expectEqual(@as(u16, 0x67EB), std.mem.readInt(u16, res.image[tf + 1 ..][0..2], .little));
    try testing.expectEqual(@as(u16, 0x7234), std.mem.readInt(u16, res.image[tf + 4 ..][0..2], .little));
    try testing.expectEqual(@as(u16, 0x9000), std.mem.readInt(u16, res.image[tf + 7 ..][0..2], .little));
}

test "window: an unmeasured tiny-base indexed site serves all three of its worlds" {
    // The laser's defect, reduced. A tiny-base indexed absolute with NO
    // evidence used to be left exactly as written, on the reasoning that
    // "X is the pointer" — true for a ROM walk, catastrophic for a data
    // base, whose accesses then land in the WRAM the window abandoned.
    // The index-split thunk decides at run time, and there are THREE
    // worlds to get right, not two:
    //
    //   system DBR + small index -> the window (+$6000)
    //   pinned DBR ($40/$41)     -> as written (that bank's own low page)
    //   system DBR + huge index  -> as written (a ROM walk)
    //
    // A STORE is the shape that proves the A-preserving template: the v1
    // thunk scratched A and could only serve loads, which is why the
    // laser's `STA $0030,Y` was never covered by the mechanism at all.
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    @memset(rom[0x8000..0x10000], 0xFF);
    rom[0x0202] = 0x5A; // the ROM byte the huge-index walk must find
    @memcpy(rom[0x0000..0x0018], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, 0xC2, 0x10, // CLC / XCE / SEP #$30 / REP #$10
        0x22, 0x80, 0x80, 0x00, // system caller, small Y
        0x22, 0xA0, 0x80, 0x00, // $7E-pinned caller
        0x22, 0xC0, 0x80, 0x00, // system caller, huge X
        0x22, 0xE0, 0x80, 0x00, // system caller in x8
        0x80, 0xEE, // BRA back to the first JSL
    });
    @memcpy(rom[0x0080..0x0090], &[_]u8{
        0xA0, 0x10, 0x01, // LDY #$0110
        0xA9, 0x11, // LDA #$11
        0x38, // SEC — the thunk must not eat it
        0x22, 0x00, 0x81, 0x00, // JSL $00:8100
        0x90, 0x03, // BCC +3 (carry lost -> skip)
        0xEE, 0x60, 0x01, // INC $0160
        0x6B,
    });
    @memcpy(rom[0x00A0..0x00B2], &[_]u8{
        0xA9, 0x7E, 0x48, 0xAB, // pin $7E (re-banked to $40)
        0xA0, 0x10, 0x02, // LDY #$0210
        0xA9, 0x22, // LDA #$22
        0x22, 0x00, 0x81, 0x00, // JSL $00:8100
        0xA9, 0x00, 0x48, 0xAB, // back to the system bank
        0x6B,
    });
    @memcpy(rom[0x00C0..0x00C8], &[_]u8{
        0xA2, 0x00, 0x82, // LDX #$8200 — past the mirror: a ROM walk
        0x22, 0x10, 0x81, 0x00, // JSL $00:8110
        0x6B,
    });
    @memcpy(rom[0x00E0..0x00ED], &[_]u8{
        0xE2, 0x10, // SEP #$10 — 8-bit index
        0xA0, 0x50, // LDY #$50
        0xA9, 0x33, // LDA #$33
        0x22, 0x00, 0x81, 0x00, // JSL $00:8100
        0xC2, 0x10, // REP #$10
        0x6B,
    });
    @memcpy(rom[0x0100..0x0104], &[_]u8{ 0x99, 0x30, 0x00, 0x6B }); // STA $0030,Y / RTL
    @memcpy(rom[0x0110..0x0117], &[_]u8{
        0xBD, 0x02, 0x00, // LDA $0002,X — the same shape, a load
        0x8D, 0x70, 0x01, // STA $0170 (plain site: shifts to the window)
        0x6B,
    });

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004 }) |a| markOp(bytes, a);
    for ([_]u32{ 0x8006, 0x800A, 0x800E, 0x8012, 0x8016 }) |a| markOpX16(bytes, a);
    // The x16 stretch: everything from the first REP to the last caller's
    // SEP decodes with 16-bit indices.
    for ([_]u32{ 0x8080, 0x8083, 0x8085, 0x8086, 0x808A, 0x808C, 0x808F }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x80A0, 0x80A2, 0x80A3, 0x80A4, 0x80A7, 0x80A9, 0x80AD, 0x80AF, 0x80B0, 0x80B1 }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x80C0, 0x80C3, 0x80C7 }) |a| markOpX16(bytes, a);
    markOpX16(bytes, 0x80E0);
    for ([_]u32{ 0x80E2, 0x80E4, 0x80E6, 0x80EA }) |a| markOp(bytes, a);
    markOpX16(bytes, 0x80EC);
    for ([_]u32{ 0x8100, 0x8103, 0x8110, 0x8113, 0x8116 }) |a| markOpX16(bytes, a);

    // No evidence anywhere: that is the whole point.
    const sites = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(sites);
    @memset(sites, 0);

    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, bytes, sites, null, false, true, &.{}, false, 0, copy_reserve, null, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u16, 2), res.stats.split_sites);
    try testing.expectEqual(@as(u8, 0x20), res.image[0x0100]); // JSR over the store
    try testing.expectEqual(@as(u8, 0x20), res.image[0x0110]); // and over the load

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    for (0..5) |_| con.runFrame();

    // World 1: system bank, small index -> the window.
    try testing.expectEqual(@as(u8, 0x11), con.bus.sa1.bwram[0x0140]);
    // World 2: pinned to $40 -> that bank's own $0240, NOT $40:6240.
    try testing.expectEqual(@as(u8, 0x22), con.bus.sa1.bwram[0x0240]);
    try testing.expectEqual(@as(u8, 0), con.bus.sa1.bwram[0x6240]);
    // World 3: system bank, huge index -> ROM, read and parked in the window.
    try testing.expectEqual(@as(u8, 0x5A), con.bus.sa1.bwram[0x0170]);
    // An 8-bit index over a tiny base cannot leave the low page, whatever
    // the compare would have said about a byte it never fetched.
    try testing.expectEqual(@as(u8, 0x33), con.bus.sa1.bwram[0x0080]);
    // Carry survived the thunk every lap, and real WRAM saw none of it.
    try testing.expect(con.bus.sa1.bwram[0x0160] > 2);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0140]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0080]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0170]);
}

test "split: the SA-1 runs the mainline, the S-CPU pump replays the IO" {
    // S5's contract end to end. A game whose mainline waits on $4212,
    // advances a counter, and calls an IO routine that writes the
    // counter through WMDATA. After the split: the SA-1 executes that
    // loop in place (its WMDATA write vanishes on its own bus, its
    // $4212 read comes from the pump-fed mirror), enqueueing the IO id;
    // the S-CPU pump drains the ring and replays the routine with the
    // write REAL. The S-CPU never runs the mainline again, so counter
    // advancement in BW-RAM is the SA-1's own work.
    const gpa = testing.allocator;
    const console = @import("../console.zig");
    const sa1_trace = @import("../sa1_trace.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    @memset(rom[0x8000..0x10000], 0xFF);
    @memcpy(rom[0x0000..0x002E], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, // CLC / XCE / SEP #$30
        0x9C, 0x81, 0x21, // STZ $2181 — WMADD = $001000
        0xA9, 0x10, 0x8D,
        0x82, 0x21, 0x9C,
        0x83, 0x21,
        0xA9, 0x80, 0x8D, 0x00, 0x42, // NMI on
        0xEA, 0xEA, 0xEA, 0xEA, // mainloop ($8014): the displaced anchor
        0xAD, 0x12, 0x42, // LDA $4212 (mirror-swapped)
        0x10, 0xFB, // BPL — wait for vblank
        0xEE, 0x00, 0x01, // INC $0100 — the logic counter (shifts to $6100)
        0x20, 0x40, 0x80, // JSR $8040 — the replay-flavor IO routine
        0x22, 0x60, 0x80, 0x00, // JSL $00:8060 — the DEFERRED one
        0xAD, 0x12, 0x42, // LDA $4212 (mirror-swapped)
        0x30, 0xFB, // BMI — wait for vblank end
        0x80, 0xE6, // BRA mainloop
    });
    @memcpy(rom[0x0040..0x0047], &[_]u8{
        0xAD, 0x00, 0x01, // LDA $0100 — whole-instruction prefix (shifts)
        0x8D, 0x80, 0x21, // STA $2180 — WMDATA: real on the S-CPU only
        0x60,
    });
    @memcpy(rom[0x0060..0x0064], &[_]u8{
        0xEE, 0x02, 0x01, // INC $0102 — whole-instruction prefix (shifts)
        0x6B, // RTL — the JSL-called shape
    });
    @memcpy(rom[0x0050..0x0056], &[_]u8{ 0x48, 0xAD, 0x10, 0x42, 0x68, 0x40 }); // NMI ack
    std.mem.writeInt(u16, rom[0x7FC0 + 0x2A ..][0..2], 0x8050, .little);

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8007, 0x8009, 0x800C, 0x800F, 0x8011, 0x8014, 0x8015, 0x8016, 0x8017, 0x8018, 0x801B, 0x801D, 0x8020, 0x8023, 0x8027, 0x802A, 0x802C }) |a| markOp(bytes, a);
    for ([_]u32{ 0x8040, 0x8043, 0x8046, 0x8060, 0x8063 }) |a| markOp(bytes, a);
    for ([_]u32{ 0x8050, 0x8051, 0x8054, 0x8055 }) |a| markOp(bytes, a);

    const io = [_]SplitIo{ .{ .entry = 0x8040 }, .{ .entry = 0x8060, .deferred = true, .rtl = true } };
    const vr = [_][2]u24{.{ 0x8014, 0x8040 }};
    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, bytes, null, null, false, true, &.{}, false, 0, copy_reserve, .{
        .io_entries = &io,
        .vbl_ranges = &vr,
        .mainloop = 0x8014,
    }, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u8, 2), res.stats.split_io);
    try testing.expect(res.stats.split_engage_addr != 0);
    // The anchors wear their displacements.
    try testing.expectEqual(@as(u8, 0x5C), res.image[0x0014]); // JML engage
    try testing.expectEqual(@as(u8, 0x4C), res.image[0x0040]); // JMP enq
    // The mainloop's $4212 read goes through a reader helper now.
    try testing.expectEqual(@as(u8, 0x20), res.image[0x0018]);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    // Watch the SA-1 execute the game's own mainloop bytes in place.
    const trace = try gpa.create(sa1_trace.Trace);
    defer gpa.destroy(trace);
    trace.* = sa1_trace.Trace.init(0x00_8014);
    con.bus.sa1.trace = trace;
    for (0..8) |_| con.runFrame();

    // The SA-1 ran the mainline: the trace saw it, and the counter it
    // keeps lives in BW-RAM, advanced well past what the S-CPU's single
    // pre-engage pass could account for.
    try testing.expect(trace.total > 0);
    try testing.expect(con.bus.sa1.bwram[0x0100] >= 3);
    // The pump replayed the IO routine with the WMDATA write REAL: the
    // counter's values landed in true WRAM at the auto-incrementing
    // pointer. The SA-1-side execution of the same store put nothing
    // there beyond what the pump wrote.
    try testing.expect(con.bus.wram.data[0x1000] != 0);
    // The deferred routine's body ran ONLY via the pump: once per lap,
    // never on the SA-1 (a double-run would race past the lap counter).
    try testing.expect(con.bus.sa1.bwram[0x0102] >= 3);
    try testing.expect(con.bus.sa1.bwram[0x0102] <= con.bus.sa1.bwram[0x0100]);
    // And the low-WRAM home of the counter stayed abandoned.
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0100]);
}

test "split mainloop: a second bank, the mode-gate handoff and the math shadow" {
    // The bank-general mainloop flavor end to end. The loop lives in bank
    // $01 and alternates the mode cell every lap, so ownership ping-pongs
    // between the CPUs at the anchor; each lap multiplies 12x13 and
    // divides 1000/7 through the S-CPU's math registers and ACCUMULATES
    // the results — a lap the SA-1 computes wrong (its shadow) or a lap
    // lost in a handoff breaks the totals against the lap count. An
    // RTS-shaped IO routine in bank $01 writes WMDATA (real on the S-CPU
    // only, replayed by the pump for the SA-1's laps); a deferred RTL one
    // in bank $00 counts its own runs.
    const gpa = testing.allocator;
    const console = @import("../console.zig");
    const sa1_trace = @import("../sa1_trace.zig");

    const rom = try gpa.alloc(u8, 128 * 1024);
    defer gpa.free(rom);
    for (rom, 0..) |*b, i| b.* = @truncate(0x11 + i *% 7);
    {
        const h = rom[0x7FC0..][0..64];
        @memcpy(h[0..21], "WG MIGRATION TEST    ");
        h[0x15] = 0x20;
        h[0x16] = 0x00;
        h[0x17] = 7; // 128 KiB
        h[0x18] = 0;
        std.mem.writeInt(u16, h[0x1C..0x1E], 0xFFFF, .little);
        std.mem.writeInt(u16, h[0x1E..0x20], 0x0000, .little);
        @memset(h[0x20..0x40], 0);
        std.mem.writeInt(u16, h[0x3C..0x3E], 0x8000, .little);
        std.mem.writeInt(u16, h[0x2A..0x2C], 0x8050, .little); // NMI
    }
    @memset(rom[0x1000..0x7FC0], 0xFF); // bank $00 carve space
    @memset(rom[0x8000..0x10000], 0xFF); // bank $01: the loop, then padding
    // bank $00: boot, the deferred RTL routine, the NMI handler
    @memcpy(rom[0x0000..0x001C], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, // CLC / XCE / SEP #$30
        0x9C, 0x81, 0x21, // STZ $2181 — WMADD = $001000
        0xA9, 0x10, 0x8D, 0x82, 0x21, // LDA #$10 / STA $2182
        0x9C, 0x83, 0x21, // STZ $2183
        0xA9, 0x80, 0x8D, 0x00, 0x42, // NMI on
        0xF4, 0x00, 0x01, 0x2B, // PEA $0100 / PLD (the shift moves it to $6100) — a nonzero D the lap USES (below): a
        // handoff that hands the SA-1 a wrong D breaks the remainder total
        // (the cells once overlapped: P's store clobbered D's high byte)
        0x5C, 0x00, 0x80, 0x01, // JML $01:8000
    });
    @memcpy(rom[0x0060..0x0064], &[_]u8{ 0xEE, 0x02, 0x01, 0x6B }); // INC $0102 / RTL
    @memcpy(rom[0x0050..0x0056], &[_]u8{ 0x48, 0xAD, 0x10, 0x42, 0x68, 0x40 }); // NMI ack
    // bank $01: the loop
    const loop = [_]u8{
        0xC2, 0x20, 0xEA, 0xEA, 0xEA, // 8000 anchor: REP #$20 and NOPs (5 bytes: the site keeps a JML + fill)
        0xE2, 0x20, // 8005 SEP #$20
        0xAD, 0x12, 0x42, // 8007 LDA $4212 (mirror-swapped)
        0x10, 0xFB, // 800A BPL — wait for vblank
        0xA9, 0x0C, 0x8D, 0x02, 0x42, // 800C LDA #12 / STA $4202
        0xA9, 0x0D, 0x8D, 0x03, 0x42, // 8011 LDA #13 / STA $4203
        0xEA, 0xEA, 0xEA, 0xEA, // 8016 the multiplier's 8 cycles
        0xC2, 0x20, // 801A REP #$20
        0xAD, 0x16, 0x42, // 801C LDA $4216 — the product
        0x18, 0x6D, 0x04, 0x01, 0x8D, 0x04, 0x01, // 801F CLC / ADC $0104 / STA $0104
        0xA9, 0xE8, 0x03, 0x8D, 0x04, 0x42, // 8026 LDA #1000 / STA $4204 (16-bit dividend)
        0xE2, 0x20, // 802C SEP #$20
        0xA9, 0x07, 0x8D, 0x06, 0x42, // 802E LDA #7 / STA $4206
        0xEA, 0xEA, 0xEA, 0xEA, 0xEA, 0xEA, 0xEA, 0xEA, // 8033 the divider's 16 cycles
        0xC2, 0x20, // 803B REP #$20
        0xAD, 0x14, 0x42, // 803D LDA $4214 — the quotient
        0x18, 0x6D, 0x06, 0x01, 0x8D, 0x06, 0x01, // 8040 += into $0106
        0xA5, 0x08, 0xEA, // 8047 LDA $08 — the remainder total, direct-page ($6108: D=$6100)
        0x18, 0x6D, 0x16, 0x42, 0x85, 0x08, 0xEA, // 804A CLC / ADC $4216 — the remainder, through an ALU read of the register / STA $08
        0xE2, 0x20, // 8051 SEP #$20
        0x20, 0x80, 0x80, // 8053 JSR $8080 — the RTS-shaped IO routine (bank $01)
        0x22, 0x60, 0x80, 0x00, // 8056 JSL $00:8060 — the deferred RTL one
        0xC2, 0x20, 0xEE, 0x00, 0x01, 0xE2, 0x20, // 805A the lap counter (16-bit), at the lap's END
        0xAD, 0x00, 0x01, 0x29, 0x01, 0x8D, 0x10, 0x01, // 8061 LDA $0100 / AND #1 / STA $0110 — the mode cell
        0x4C, 0x90, 0x80, // 8069 JMP $8090 — the mode-7 multiply, then around
    };
    @memcpy(rom[0x8000 .. 0x8000 + loop.len], &loop);
    @memcpy(rom[0x8080..0x8087], &[_]u8{ 0xAD, 0x00, 0x01, 0x8D, 0x80, 0x21, 0x60 }); // LDA $0100 / STA $2180 / RTS
    // the PPU's mode-7 multiplier as a signed 16x8 unit: -2 x 3 = -6 into $010A
    @memcpy(rom[0x8090..0x80B2], &[_]u8{
        0xE2, 0x20, // 8090 SEP #$20
        0xA9, 0xFE, 0x8D, 0x1B, 0x21, // 8092 LDA #$FE / STA $211B (low)
        0xA9, 0xFF, 0x8F, 0x1B, 0x21, 0x00, // 8097 LDA #$FF / STA $00:211B (high, long form)
        0xA9, 0x03, 0x8D, 0x1C, 0x21, // 809D LDA #3 / STA $211C
        0xC2, 0x20, // 80A2 REP #$20
        0xAF, 0x34, 0x21, 0x00, // 80A4 LDA $00:2134 (long form) — the product's low word: $FFFA
        0x18, 0x6D, 0x0A, 0x01, 0x8D, 0x0A, 0x01, // 80A8 CLC / ADC $010A / STA $010A
        0x4C, 0x00, 0x80, // 80AF JMP $8000
    });

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    const mark = struct {
        fn f(u: []u8, a: u32, m8: bool) void {
            u[a] |= usage_map.flag_opcode | usage_map.flag_exec | usage_map.flag_x;
            if (m8) u[a] |= usage_map.flag_m;
        }
    }.f;
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8007, 0x8009, 0x800C, 0x800F, 0x8011, 0x8014, 0x8017, 0x8018 }) |a| mark(bytes, a, true);
    for ([_]u32{ 0x8060, 0x8063, 0x8050, 0x8051, 0x8054, 0x8055 }) |a| mark(bytes, a, true);
    // the loop: 8-bit until 801A, 16-bit to 802C, 8-bit to 803B, 16-bit to 8051, 8-bit after
    for ([_]u32{ 0x8000, 0x8002, 0x8003, 0x8004, 0x8005, 0x8007, 0x800A, 0x800C, 0x800E, 0x8011, 0x8013, 0x8016, 0x8017, 0x8018, 0x8019, 0x801A }) |a| mark(bytes, 0x01_0000 | a, true);
    for ([_]u32{ 0x801C, 0x801F, 0x8020, 0x8023, 0x8026, 0x8029, 0x802C }) |a| mark(bytes, 0x01_0000 | a, false);
    for ([_]u32{ 0x802E, 0x8030, 0x8033, 0x8034, 0x8035, 0x8036, 0x8037, 0x8038, 0x8039, 0x803A, 0x803B }) |a| mark(bytes, 0x01_0000 | a, true);
    for ([_]u32{ 0x803D, 0x8040, 0x8041, 0x8044, 0x8047, 0x8049, 0x804A, 0x804B, 0x804E, 0x8050, 0x8051 }) |a| mark(bytes, 0x01_0000 | a, false);
    for ([_]u32{ 0x8053, 0x8056, 0x805A, 0x805C, 0x805F, 0x8061, 0x8064, 0x8066, 0x8069, 0x8080, 0x8083, 0x8086 }) |a| mark(bytes, 0x01_0000 | a, true);
    for ([_]u32{ 0x8090, 0x8092, 0x8094, 0x8097, 0x8099, 0x809D, 0x809F, 0x80A2 }) |a| mark(bytes, 0x01_0000 | a, true);
    for ([_]u32{ 0x80A4, 0x80A8, 0x80A9, 0x80AC, 0x80AF }) |a| mark(bytes, 0x01_0000 | a, false);

    const io = [_]SplitIo{ .{ .entry = 0x01_8080 }, .{ .entry = 0x00_8060, .deferred = true, .rtl = true } };
    const vr = [_][2]u24{.{ 0x01_8005, 0x01_8069 }};
    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, bytes, null, null, false, true, &.{}, false, 0, copy_reserve, .{
        .io_entries = &io,
        .vbl_ranges = &vr,
        .mainloop = 0x01_8000,
        .mode_cell = 0x0110,
        .mode_value = 0,
        .mode_gate = true,
    }, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u8, 2), res.stats.split_io);
    try testing.expect(res.stats.split_engage_addr != 0);
    // Eleven math sites shadowed (seven on the S-CPU's unit, four on the
    // mode-7 one): the five trigger stores as JSLs to their own far
    // routines, the six others as COPs; the one hazard the audit lists is
    // the NMI handler's $4210 ack read, which only the S-CPU ever runs.
    try testing.expectEqual(@as(u8, 6), res.stats.split_mul);
    try testing.expectEqual(@as(u32, 5), res.stats.split_trigger_jsl);
    try testing.expectEqual(@as(u8, 1), res.stats.n_split_hazards);
    try testing.expectEqual(@as(u24, 0x00_8051), res.stats.split_hazards[0]);
    // The anchors wear their displacements, in their own banks.
    try testing.expectEqual(@as(u8, 0x5C), res.image[0x8000]); // JML engage at $01:8000
    try testing.expectEqual(@as(u8, 0xEA), res.image[0x8004]); // the 5th byte NOP-filled
    try testing.expectEqual(@as(u8, 0x4C), res.image[0x8080]); // JMP stub at $01:8080
    try testing.expect(std.mem.readInt(u16, res.image[0x8081..0x8083], .little) >= 0x8000); // a bank-$01 stub
    try testing.expectEqual(@as(u8, 0x4C), res.image[0x0060]); // JMP stub at $00:8060
    try testing.expectEqual(@as(u8, 0x02), res.image[0x800E]); // COP at STA $4202
    try testing.expectEqual(@as(u8, 0xEA), res.image[0x8010]);
    try testing.expectEqual(@as(u8, 0x20), res.image[0x8007]); // JSR reader helper at LDA $4212
    try testing.expectEqual(@as(u8, 0x02), res.image[0x804B]); // COP at ADC $4216: the operate kind
    try testing.expectEqual(@as(u8, 0x22), res.image[0x8099]); // JSL at STA $00:211B (a 4-byte site: no rider)
    try testing.expectEqual(@as(u8, 0x22), res.image[0x8013]); // JSL at STA $4203, carrying the NOP after it
    try testing.expectEqual(@as(u8, 0x02), res.image[0x80A4]); // COP at LDA $00:2134

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    const trace = try gpa.create(sa1_trace.Trace);
    defer gpa.destroy(trace);
    trace.* = sa1_trace.Trace.init(0x01_8000);
    con.bus.sa1.trace = trace;
    for (0..12) |_| con.runFrame();

    const laps = std.mem.readInt(u16, con.bus.sa1.bwram[0x0100..0x0102], .little);
    const acc_mul = std.mem.readInt(u16, con.bus.sa1.bwram[0x0104..0x0106], .little);
    const acc_q = std.mem.readInt(u16, con.bus.sa1.bwram[0x0106..0x0108], .little);
    const acc_r = std.mem.readInt(u16, con.bus.sa1.bwram[0x0108..0x010A], .little);
    const acc_m7 = std.mem.readInt(u16, con.bus.sa1.bwram[0x010A..0x010C], .little);
    // Laps ran on BOTH CPUs (the SA-1's trace saw the loop; the gate
    // alternates), and the math totals match the lap count exactly:
    // the shadow's product, quotient and remainder equal the S-CPU's.
    try testing.expect(trace.total > 0);
    try testing.expect(laps >= 6);
    // The run stops mid-lap: the lap in flight may have done its sums and
    // not yet counted itself, so the totals stand for `laps` or `laps + 1`
    // laps — the same number for all three.
    // (the lap in flight may also have stopped BETWEEN its three sums, so
    // each total is exact for its own count, the counts descending)
    const k_mul: u16 = acc_mul / 156;
    const k_q: u16 = acc_q / 142;
    const k_r: u16 = acc_r / 6;
    try testing.expect(k_mul == laps or k_mul == laps + 1);
    try testing.expect(k_q == laps or k_q == laps + 1);
    try testing.expect(k_r == laps or k_r == laps + 1);
    try testing.expect(k_mul >= k_q and k_q >= k_r);
    try testing.expectEqual(@as(u16, k_mul *% 156), acc_mul);
    try testing.expectEqual(@as(u16, k_q *% 142), acc_q);
    try testing.expectEqual(@as(u16, k_r *% 6), acc_r);
    // the mode-7 product: -6 per lap, on both units (it follows the lap
    // counter, so the total stands for `laps` or `laps - 1`)
    const neg6: u16 = 0xFFFA;
    try testing.expect(acc_m7 == laps *% neg6 or acc_m7 == (laps -% 1) *% neg6);
    // The IO routine's WMDATA writes landed in real WRAM — natively on the
    // S-CPU's laps, through the pump on the SA-1's.
    var wm_writes: usize = 0;
    for (con.bus.wram.data[0x1000..0x1100]) |b| {
        if (b != 0) wm_writes += 1;
    }
    try testing.expect(wm_writes >= 4);
    // The deferred routine ran once per lap, never twice.
    const deferred_runs = std.mem.readInt(u16, con.bus.sa1.bwram[0x0102..0x0104], .little);
    try testing.expect(deferred_runs >= 4);
    try testing.expect(deferred_runs <= laps);
    // The low-WRAM homes stayed abandoned.
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0100]);
}

test "split tail: the token round-trip drives the SA-1's frame loop" {
    // The NMI-tail flavor's protocol, isolated: a game whose engine
    // lives in its NMI handler (head work, a boundary JSL, a tail
    // routine, the pull/RTI epilogue) and whose mainline just spins.
    // After the split: the head still runs on the S-CPU every frame,
    // the tok stub bumps the token, and the SA-1's frame loop runs the
    // tail once per token through the faked handler frame.
    const gpa = testing.allocator;
    const console = @import("../console.zig");
    const sa1_trace = @import("../sa1_trace.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    @memset(rom[0x8000..0x10000], 0xFF);
    @memcpy(rom[0x0000..0x000C], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, // CLC / XCE / SEP #$30
        0xA9, 0x80, 0x8D, 0x00, 0x42, // NMI on
        0xEA, // mainline
        0x80, 0xFD, // BRA the NOP — idle forever
    });
    // The NMI engine, stock-shaped: save, D-establish, head work,
    // boundary JSL, post, epilogue pulls, RTI.
    @memcpy(rom[0x0100..0x0125], &[_]u8{
        0xC2, 0x20, 0xC2, 0x10, // REP
        0x48, 0xDA, 0x5A, 0x0B, 0x8B, // PHA PHX PHY PHD PHB
        0xA2, 0x00, 0x00, 0xDA, 0x2B, // LDX #0 / PHX / PLD — the D-establish the rewriter moves
        0xE2, 0x20, // SEP #$20
        0xEE, 0x00, 0x02, // INC $0200 — head work (shifts to the window)
        0xC2, 0x20, // REP #$20
        0x22, 0x40, 0x81, 0x00, // the BOUNDARY: JSL $00:8140
        0xE2, 0x20, // SEP #$20
        0x64, 0x50, // STZ $50 — tail-side post, still the tail's span
        0xC2, 0x30, // the epilogue: REP #$30
        0xAB, 0x2B, 0x7A, 0xFA, 0x68, // PLB PLD PLY PLX PLA
        0x40, // RTI
    });
    @memcpy(rom[0x0140..0x0144], &[_]u8{
        0xEE, 0x04, 0x01, // INC $0104 — the tail's logic counter
        0x6B, // RTL
    });
    std.mem.writeInt(u16, rom[0x7FC0 + 0x2A ..][0..2], 0x8100, .little);

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8009, 0x800A }) |a| markOp(bytes, a);
    for ([_]u32{ 0x8100, 0x8102 }) |a| markOp(bytes, a);
    for ([_]u32{ 0x8104, 0x8105, 0x8106, 0x8107, 0x8108, 0x8109, 0x810C, 0x810D }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x810E, 0x8110, 0x8113, 0x8115, 0x8119, 0x811B, 0x811D, 0x811F, 0x8120, 0x8121, 0x8122, 0x8123, 0x8124 }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x8140, 0x8143 }) |a| markOpX16(bytes, a);

    var ref: ?Refusal = null;
    const res = convertWholeGame(gpa, rom, bytes, null, null, false, true, &.{}, false, 0, copy_reserve, .{
        .io_entries = &.{},
        .vbl_ranges = &.{},
        .tail = 0x8115,
        .tail_epilogue = 0x811D,
        .tail_dbr = 0x00,
    }, &ref) catch |e| {
        if (ref) |r| std.debug.print("[tailtest] REFUSED: {s} detail={x}\n", .{ @tagName(r.reason), r.detail });
        return e;
    };
    defer gpa.free(res.image);
    try testing.expect(res.stats.split_engage_addr != 0);
    try testing.expectEqual(@as(u8, 0x4C), res.image[0x0115]); // JMP tok over the boundary

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    const trace = try gpa.create(sa1_trace.Trace);
    defer gpa.destroy(trace);
    // The displaced boundary JSL runs on the S-CPU now (it is the pad
    // poll); the SA-1 enters at tail+4, so THAT is what the trace
    // watches for proof the frame loop drove the tail.
    trace.* = sa1_trace.Trace.init(0x00_8119);
    con.bus.sa1.trace = trace;
    for (0..8) |_| con.runFrame();

    // The head ran every frame on the S-CPU; the tail ran every frame
    // on the SA-1 (the trace watched it); the token round-trip is the
    // only thing that could have driven it.
    try testing.expect(con.bus.sa1.bwram[0x0200] >= 6);
    try testing.expect(trace.total > 0);
    try testing.expect(con.bus.sa1.bwram[0x0104] >= 5);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0104]);
}

test "window: cold sites in a full bank share one stub through the dispatcher" {
    // The three-worlds scenario again, but the sites live in a bank
    // whose entire padding is one 14-byte run: room for a single 5-byte
    // stub and TWO distinct unmeasured thunks that want one. Per-thunk
    // stubs refuse; the cold dispatcher routes both sites through the
    // bank's one shared stub and finds each body by return address. The
    // assertions are the same as the per-thunk test's — the dispatcher
    // must be invisible: same cells, same carry, same flags.
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try gpa.alloc(u8, 128 * 1024);
    defer gpa.free(rom);
    for (rom, 0..) |*b, i| b.* = @truncate(0x11 + i *% 7);
    const h = rom[0x7FC0..][0..64];
    @memcpy(h[0..21], "COLD DISPATCH TEST   ");
    h[0x15] = 0x20;
    h[0x16] = 0x00;
    h[0x17] = 7; // 128 KiB
    h[0x18] = 0;
    std.mem.writeInt(u16, h[0x1C..0x1E], 0xFFFF, .little);
    std.mem.writeInt(u16, h[0x1E..0x20], 0x0000, .little);
    @memset(h[0x20..0x40], 0);
    std.mem.writeInt(u16, h[0x3C..0x3E], 0x8000, .little);
    @memset(rom[0x1000..0x7FC0], 0xFF); // bank $00: the carve's space
    @memset(rom[0xFF00..0xFF0E], 0xFF); // bank $01's ONLY padding: 14 bytes
    @memset(rom[0x10000..0x20000], 0xFF); // banks $02/$03: the far pool
    rom[0x0202] = 0x5A; // the ROM byte the huge-index walk must find

    @memcpy(rom[0x0000..0x0018], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, 0xC2, 0x10, // CLC / XCE / SEP #$30 / REP #$10
        0x22, 0x80, 0x80, 0x00, // system caller, small Y
        0x22, 0xA0, 0x80, 0x00, // $7E-pinned caller
        0x22, 0xC0, 0x80, 0x00, // system caller, huge X
        0x22, 0xE0, 0x80, 0x00, // system caller in x8
        0x80, 0xEE, // BRA back to the first JSL
    });
    @memcpy(rom[0x0080..0x0090], &[_]u8{
        0xA0, 0x10, 0x01, // LDY #$0110
        0xA9, 0x11, // LDA #$11
        0x38, // SEC — the dispatcher must not eat it either
        0x22, 0x00, 0x81, 0x01, // JSL $01:8100
        0x90, 0x03, // BCC +3 (carry lost -> skip)
        0xEE, 0x60, 0x01, // INC $0160
        0x6B,
    });
    @memcpy(rom[0x00A0..0x00B2], &[_]u8{
        0xA9, 0x7E, 0x48, 0xAB, // pin $7E (re-banked to $40)
        0xA0, 0x10, 0x02, // LDY #$0210
        0xA9, 0x22, // LDA #$22
        0x22, 0x00, 0x81, 0x01, // JSL $01:8100
        0xA9, 0x00, 0x48, 0xAB, // back to the system bank
        0x6B,
    });
    @memcpy(rom[0x00C0..0x00C8], &[_]u8{
        0xA2, 0x00, 0x82, // LDX #$8200 — past the mirror: a ROM walk
        0x22, 0x10, 0x81, 0x01, // JSL $01:8110
        0x6B,
    });
    @memcpy(rom[0x00E0..0x00ED], &[_]u8{
        0xE2, 0x10, // SEP #$10 — 8-bit index
        0xA0, 0x50, // LDY #$50
        0xA9, 0x33, // LDA #$33
        0x22, 0x00, 0x81, 0x01, // JSL $01:8100
        0xC2, 0x10, // REP #$10
        0x6B,
    });
    @memcpy(rom[0x8100..0x8104], &[_]u8{ 0x99, 0x30, 0x00, 0x6B }); // STA $0030,Y / RTL
    @memcpy(rom[0x8110..0x8117], &[_]u8{
        0xBD, 0x02, 0x00, // LDA $0002,X — the same shape, a load
        0x8D, 0x70, 0x01, // STA $0170 (plain site: shifts to the window)
        0x6B,
    });

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004 }) |a| markOp(bytes, a);
    for ([_]u32{ 0x8006, 0x800A, 0x800E, 0x8012, 0x8016 }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x8080, 0x8083, 0x8085, 0x8086, 0x808A, 0x808C, 0x808F }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x80A0, 0x80A2, 0x80A3, 0x80A4, 0x80A7, 0x80A9, 0x80AD, 0x80AF, 0x80B0, 0x80B1 }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x80C0, 0x80C3, 0x80C7 }) |a| markOpX16(bytes, a);
    markOpX16(bytes, 0x80E0);
    for ([_]u32{ 0x80E2, 0x80E4, 0x80E6, 0x80EA }) |a| markOp(bytes, a);
    markOpX16(bytes, 0x80EC);
    for ([_]u32{ 0x018100, 0x018103, 0x018110, 0x018113, 0x018116 }) |a| markOpX16(bytes, a);

    // No evidence anywhere: both thunks are COLD.
    const sites = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(sites);
    @memset(sites, 0);

    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, bytes, sites, null, false, true, &.{}, false, 0, copy_reserve, null, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u16, 2), res.stats.split_sites);
    try testing.expectEqual(@as(u16, 2), res.stats.disp_sites);
    try testing.expectEqual(@as(u16, 0), res.stats.split_far);
    try testing.expectEqual(@as(u8, 0x20), res.image[0x8100]); // JSR over the store
    try testing.expectEqual(@as(u8, 0x20), res.image[0x8110]); // and over the load
    // Both sites name the SAME stub — the bank paid five bytes total.
    try testing.expectEqual(
        std.mem.readInt(u16, res.image[0x8101..0x8103], .little),
        std.mem.readInt(u16, res.image[0x8111..0x8113], .little),
    );

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    for (0..5) |_| con.runFrame();

    // World 1: system bank, small index -> the window.
    try testing.expectEqual(@as(u8, 0x11), con.bus.sa1.bwram[0x0140]);
    // World 2: pinned to $40 -> that bank's own $0240, NOT $40:6240.
    try testing.expectEqual(@as(u8, 0x22), con.bus.sa1.bwram[0x0240]);
    try testing.expectEqual(@as(u8, 0), con.bus.sa1.bwram[0x6240]);
    // World 3: system bank, huge index -> ROM, read and parked in the window.
    try testing.expectEqual(@as(u8, 0x5A), con.bus.sa1.bwram[0x0170]);
    // An 8-bit index over a tiny base stays in the low page.
    try testing.expectEqual(@as(u8, 0x33), con.bus.sa1.bwram[0x0080]);
    // Carry survived the whole dispatch chain every lap; WRAM saw nothing.
    try testing.expect(con.bus.sa1.bwram[0x0160] > 2);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0140]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0080]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0170]);
}

test "window: measured evidence drops the thunk's data-bank arm" {
    // The same site as the three-worlds test, but MEASURED as low|rom —
    // which rules a BW-RAM pin out, so the thunk should not pay ~17 cycles
    // a call asking. It did, once, and the cost alone moved Gradius III's
    // timeline far enough to flip a behavioural verdict that had shipped.
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    @memset(rom[0x8000..0x10000], 0xFF);
    @memcpy(rom[0x0000..0x000C], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, 0xC2, 0x10, // CLC / XCE / SEP #$30 / REP #$10
        0x22, 0x80, 0x80, 0x00, // the caller
        0x80, 0xFA, // BRA back to it
    });
    @memcpy(rom[0x0080..0x008D], &[_]u8{
        0xA0, 0x10, 0x01, // LDY #$0110
        0xA9, 0x44, // LDA #$44
        0x22, 0x00, 0x81, 0x00, // JSL $00:8100
        0xEE, 0x60, 0x01, // INC $0160
        0x6B,
    });
    @memcpy(rom[0x0100..0x0104], &[_]u8{ 0x99, 0x30, 0x00, 0x6B }); // STA $0030,Y / RTL

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004 }) |a| markOp(bytes, a);
    for ([_]u32{ 0x8006, 0x800A }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x8080, 0x8083, 0x8085, 0x8089, 0x808C }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x8100, 0x8103 }) |a| markOpX16(bytes, a);

    const sites = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(sites);
    @memset(sites, 0);
    sites[0x8100] = usage_map.site_wram_low | usage_map.site_rom;

    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, bytes, sites, null, false, true, &.{}, false, 0, copy_reserve, null, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u16, 1), res.stats.idx_split_sites);
    try testing.expectEqual(@as(u8, 0x20), res.image[0x0100]);
    // The SHORT prologue: PHP / SEP #$20 / PHA / LDA $02,S — no PHB/PLA.
    const body = std.mem.readInt(u16, res.image[0x0101..0x0103], .little) - 0x8000;
    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0xE2, 0x20, 0x48, 0xA3, 0x02 }, res.image[body..][0..6]);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    for (0..5) |_| con.runFrame();
    try testing.expectEqual(@as(u8, 0x44), con.bus.sa1.bwram[0x0140]);
    try testing.expect(con.bus.sa1.bwram[0x0160] > 2);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0140]);
}

test "window: a NEGATIVE-base LONG,X site follows its wrap into the window" {
    // `LDA $01:FFFF,X` reads the byte before a bank boundary, so a small X
    // wraps FORWARD into the next bank's low page — the WRAM mirror, which
    // moved. Gradius III's slot walker uses the idiom on the boss's
    // node-insertion path, and inside an offloaded copy that page is the
    // SA-1's own I-RAM: the stage-1 boss rendered out of I-RAM garbage.
    // Every rule missed it by testing `v < $2000`.
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    @memset(rom[0x8000..0x10000], 0xFF);
    rom[0xFFFF] = 0x3C; // $01:FFFF — what an UNWRAPPED read must find
    @memcpy(rom[0x0000..0x0014], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, 0xC2, 0x10, // CLC / XCE / SEP #$30 / REP #$10
        0x22, 0x80, 0x80, 0x00, // X=7      -> wraps into the mirror
        0x22, 0xA0, 0x80, 0x00, // X=0      -> not wrapped, ROM
        0x22, 0xC0, 0x80, 0x00, // X=$8001  -> far past the mirror
        0x80, 0xF2, // BRA back to the first JSL
    });
    @memcpy(rom[0x0080..0x0090], &[_]u8{
        0xA9, 0x77, // LDA #$77
        0x8D, 0x06, 0x00, // STA $0006 (plain site: shifts into the window)
        0xA2, 0x07, 0x00, // LDX #$0007
        0x22, 0x00, 0x81, 0x00, // JSL $00:8100
        0x8D, 0x70, 0x01, // STA $0170
        0x6B,
    });
    @memcpy(rom[0x00A0..0x00AB], &[_]u8{
        0xA2, 0x00, 0x00, // LDX #$0000
        0x22, 0x00, 0x81,
        0x00,
        0x8D, 0x74, 0x01, // STA $0174
        0x6B,
    });
    @memcpy(rom[0x00C0..0x00CB], &[_]u8{
        0xA2, 0x01, 0x80, // LDX #$8001
        0x22, 0x00, 0x81,
        0x00,
        0x8D, 0x78, 0x01, // STA $0178
        0x6B,
    });
    @memcpy(rom[0x0100..0x0105], &[_]u8{ 0xBF, 0xFF, 0xFF, 0x01, 0x6B }); // LDA $01:FFFF,X / RTL

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004 }) |a| markOp(bytes, a);
    for ([_]u32{ 0x8006, 0x800A, 0x800E, 0x8012 }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x8080, 0x8082, 0x8085, 0x8088, 0x808C, 0x808F }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x80A0, 0x80A3, 0x80A7, 0x80AA }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x80C0, 0x80C3, 0x80C7, 0x80CA }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x8100, 0x8104 }) |a| markOpX16(bytes, a);

    const sites = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(sites);
    @memset(sites, 0);

    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, bytes, sites, null, false, true, &.{}, false, 0, copy_reserve, null, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u16, 1), res.stats.idx_split_sites);
    try testing.expectEqual(@as(u8, 0x22), res.image[0x0100]); // JSL over the site
    // The window arm keeps the DISTANCE by advancing the bank: $01:FFFF
    // + $6000 is $02:5FFF, so $02:5FFF + 7 is $02:6006 — the window cell
    // the shifted `STA $0006` wrote.
    const body = (@as(u32, res.image[0x0103] & 0x7F) * 0x8000) + (std.mem.readInt(u16, res.image[0x0101..0x0103], .little) - 0x8000);
    try testing.expectEqual(@as(u8, 0xFF), res.image[body + 15]); // $5FFF low
    try testing.expectEqual(@as(u8, 0x5F), res.image[body + 16]); // $5FFF high
    try testing.expectEqual(@as(u8, 0x02), res.image[body + 17]); // bank + 1

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    for (0..5) |_| con.runFrame();
    // Wrapped into the mirror: the read followed the store into the window.
    try testing.expectEqual(@as(u8, 0x77), con.bus.sa1.bwram[0x0170]);
    // Not wrapped: still this bank's own last ROM byte.
    try testing.expectEqual(@as(u8, 0x3C), con.bus.sa1.bwram[0x0174]);
    // Far past the mirror: whatever it reads, it is NOT the window cell.
    try testing.expect(con.bus.sa1.bwram[0x0178] != 0x77);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0006]);
}

test "window: a tiny-base LONG,X site splits on its index through a JSL thunk" {
    // The same idiom in the addressing mode the absolute thunk cannot
    // reach: `LDA $00:0002,X` is the slot walker's chain-follow with a
    // small X and a ROM table walk with a big one, and Gradius III has
    // three of them inside the walker at $00:90AE-$90C4. The site is FOUR
    // bytes, so `JSL` fits where `JSR` did not — and because a long call
    // names its own bank, the thunk needs no bank-local home. No DBR test
    // either: a long access carries its bank in the operand.
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    @memset(rom[0x8000..0x10000], 0xFF);
    rom[0x0202] = 0x5A; // the ROM byte the huge-index walk must find
    @memcpy(rom[0x0000..0x0010], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, 0xC2, 0x10, // CLC / XCE / SEP #$30 / REP #$10
        0x22, 0x80, 0x80, 0x00, // small-index caller
        0x22, 0xA0, 0x80, 0x00, // huge-index caller
        0x80, 0xF6, // BRA back to the first JSL
    });
    @memcpy(rom[0x0080..0x008D], &[_]u8{
        0xA9, 0x5C, // LDA #$5C
        0x8D, 0x12, 0x01, // STA $0112 (plain site: shifts to the window)
        0xA2, 0x10, 0x01, // LDX #$0110
        0x22, 0x00, 0x81, 0x00, // JSL $00:8100
        0x6B,
    });
    @memcpy(rom[0x00A0..0x00A8], &[_]u8{
        0xA2, 0x00, 0x82, // LDX #$8200 — past the mirror: a ROM walk
        0x22, 0x10, 0x81, 0x00, // JSL $00:8110
        0x6B,
    });
    // Two helpers with the SAME (op, operand, bank): they must share one
    // thunk body.
    @memcpy(rom[0x0100..0x0108], &[_]u8{
        0xBF, 0x02, 0x00, 0x00, // LDA $00:0002,X — the split site
        0x8D, 0x70, 0x01, // STA $0170
        0x6B,
    });
    @memcpy(rom[0x0110..0x0118], &[_]u8{
        0xBF, 0x02, 0x00, 0x00,
        0x8D, 0x74, 0x01, // STA $0174
        0x6B,
    });

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004 }) |a| markOp(bytes, a);
    for ([_]u32{ 0x8006, 0x800A, 0x800E }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x8080, 0x8082, 0x8085, 0x8088, 0x808C }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x80A0, 0x80A3, 0x80A7 }) |a| markOpX16(bytes, a);
    for ([_]u32{ 0x8100, 0x8104, 0x8107, 0x8110, 0x8114, 0x8117 }) |a| markOpX16(bytes, a);

    // No evidence: the shape alone decides.
    const sites = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(sites);
    @memset(sites, 0);

    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, bytes, sites, null, false, true, &.{}, false, 0, copy_reserve, null, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u16, 2), res.stats.idx_split_sites);
    try testing.expectEqual(@as(u8, 0x22), res.image[0x0100]); // JSL, same footprint
    try testing.expectEqual(@as(u8, 0x22), res.image[0x0110]);
    // One body, two callers.
    try testing.expectEqualSlices(u8, res.image[0x0101..0x0104], res.image[0x0111..0x0114]);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    for (0..5) |_| con.runFrame();
    // Small index: the read followed the store into the window.
    try testing.expectEqual(@as(u8, 0x5C), con.bus.sa1.bwram[0x0170]);
    // Huge index: the read still walked ROM.
    try testing.expectEqual(@as(u8, 0x5A), con.bus.sa1.bwram[0x0174]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0112]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0170]);
}

test "whole-game: the migrated game runs on the SA-1, MMIO crosses the mailbox, NMI round-trips" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    // The game: native mode, 8-bit; prove w8 by writing $77 into real WRAM
    // through the port ($2180 with WMADD=$001234), keep a marker in low
    // WRAM (I-RAM once migrated), prove r8 by reading the byte back through
    // the port and writing the round-trip to WRAM $2000, then enable NMI
    // and spin. The NMI handler counts frames in low WRAM and publishes the
    // count to WRAM $2100 through the port — MMIO from interrupt context,
    // which is exactly what the helpers' mask protocol exists for.
    @memcpy(rom[0x0000..0x004C], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, // CLC / XCE / SEP #$30
        0xA9, 0x34, 0x8D, 0x81, 0x21, // WMADD = $001234
        0xA9, 0x12, 0x8D, 0x82, 0x21,
        0xA9, 0x00, 0x8D, 0x83, 0x21,
        0xA9, 0x77, 0x8D, 0x80, 0x21, // WRAM[$1234] = $77
        0x8D, 0x10, 0x00, // marker in low WRAM
        0xA9, 0x34, 0x8D, 0x81, 0x21, // rewind WMADD
        0xA9, 0x12, 0x8D, 0x82, 0x21,
        0xA9, 0x00, 0x8D, 0x83, 0x21,
        0xAD, 0x80, 0x21, // read the byte back (r8)
        0x8D, 0x11, 0x00,
        0xA9, 0x00, 0x8D, 0x81, 0x21, // WMADD = $002000
        0xA9, 0x20, 0x8D, 0x82, 0x21,
        0xA9, 0x00, 0x8D, 0x83, 0x21,
        0xAD, 0x11, 0x00, 0x8D, 0x80, 0x21, // publish the round-trip
        0xA9, 0x80, 0x8D, 0x00, 0x42, // NMITIMEN: NMI on
        0x80, 0xFE, // spin
    });
    // NMI handler at $8050.
    @memcpy(rom[0x0050..0x006B], &[_]u8{
        0x48, // PHA
        0xEE, 0x20, 0x00, // INC the frame counter (low WRAM)
        0xA9, 0x00, 0x8D, 0x81, 0x21, // WMADD = $002100
        0xA9, 0x21, 0x8D, 0x82, 0x21,
        0xA9, 0x00, 0x8D, 0x83, 0x21,
        0xAD, 0x20, 0x00, 0x8D, 0x80, 0x21, // publish the count
        0x68, 0x40, // PLA / RTI
    });
    std.mem.writeInt(u16, rom[0x7FC0 + 0x2A ..][0..2], 0x8050, .little);

    // Collect real coverage from the original — the S1 half of the loop —
    // and take the baseline observations from the same run.
    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    const map: usage_map.UsageMap = .{ .bytes = bytes };
    const frames = 10;
    {
        const cart = try cartridge.Cartridge.load(gpa, rom);
        const con = try gpa.create(console.ProfilingConsole);
        defer {
            con.cart.deinit(gpa);
            gpa.destroy(con);
        }
        con.init(cart);
        con.usage = &map;
        for (0..frames) |_| con.runFrame();
        try testing.expectEqual(@as(u8, 0x77), con.bus.wram.data[0x1234]);
        try testing.expectEqual(@as(u8, 0x77), con.bus.wram.data[0x2000]);
        try testing.expectEqual(@as(u8, 0x77), con.bus.wram.data[0x0010]);
        try testing.expect(con.bus.wram.data[0x2100] >= frames - 2);
    }

    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, bytes, null, null, false, false, &.{}, false, 0, copy_reserve, null, &ref);
    defer gpa.free(res.image);
    try testing.expect(res.stats.offload_sites >= 14);

    // Boot the migrated cart: the game now runs on the SA-1.
    const cart = try cartridge.Cartridge.load(gpa, res.image);
    try testing.expectEqual(cartridge.ChipKind.sa1, cart.chip);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    for (0..frames) |_| con.runFrame();
    // The game's working state lives in I-RAM, written by the SA-1; the
    // S-CPU's WRAM low mirror never saw it.
    try testing.expectEqual(@as(u8, 0x77), con.bus.sa1.iram[0x10]);
    try testing.expectEqual(@as(u8, 0x77), con.bus.sa1.iram[0x11]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0010]);
    // The mailbox performed real MMIO on the real bus: the port writes
    // landed in real WRAM, and the r8 read round-tripped the value.
    try testing.expectEqual(@as(u8, 0x77), con.bus.wram.data[0x1234]);
    try testing.expectEqual(@as(u8, 0x77), con.bus.wram.data[0x2000]);
    // NMI crossed the wall every frame: S-CPU stub -> CCNT message -> CNV
    // shim -> the game's handler on the SA-1, whose own MMIO requests
    // published the count back into real WRAM.
    try testing.expect(con.bus.sa1.iram[0x20] >= frames - 2);
    try testing.expect(con.bus.wram.data[0x2100] >= frames - 2);
}

test "whole-game: --wg-expand grows the image and the new banks are usable padding" {
    const gpa = testing.allocator;
    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    const usage = try gpa.alloc(u8, 0x100_0000);
    defer gpa.free(usage);
    @memset(usage, 0);
    markOp(usage, 0x00_8000);

    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, usage, null, null, false, true, &.{}, false, 128 * 1024, copy_reserve, null, &ref);
    defer gpa.free(res.image);

    // The image doubled, and the header says so — without that the loader's
    // rom_mask folds the new banks straight back onto the old ones.
    try testing.expectEqual(@as(usize, 128 * 1024), res.image.len);
    try testing.expectEqual(@as(u32, 128 * 1024), res.stats.expanded_to);
    const hdr = try header_mod.detect(res.image);
    try testing.expectEqual(@as(u8, 7), res.image[hdr.offset + 0x17]); // log2(128 KiB / 1 KiB)

    // The new space is $FF — the only byte the pad allocator recognises as
    // free — so it shows up as one unbroken run, which is the whole point.
    for (res.image[rom.len..]) |b| try testing.expectEqual(@as(u8, 0xFF), b);
    const big = biggestRun(res.image, hdr.offset);
    try testing.expect(big.len >= 0x7FF0);
    try testing.expect(big.bank >= rom.len / 0x8000);

    // A grown image is still a valid cartridge.
    try testing.expectEqual(@as(u16, 0xFFFF), hdr.checksum ^ hdr.checksum_complement);
}

test "whole-game: --wg-expand of zero or less leaves the image alone" {
    const gpa = testing.allocator;
    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    const usage = try gpa.alloc(u8, 0x100_0000);
    defer gpa.free(usage);
    @memset(usage, 0);
    markOp(usage, 0x00_8000);

    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, usage, null, null, false, true, &.{}, false, 0, copy_reserve, null, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(rom.len, res.image.len);
    try testing.expectEqual(@as(u32, 0), res.stats.expanded_to);
}

test "whole-game: a set too big for I-RAM migrates through the BW-RAM window" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    // The same shape as the I-RAM test, but the game's state sits at $0900
    // and $7E:4000 — one beyond I-RAM's 2 KiB, one in a bank that is not on
    // the SA-1's bus at all. Both are ordinary BW-RAM once the window moves
    // them, and the two must land on the SAME byte from either form: $0900
    // absolute and $7E:0900 long are one variable to the game.
    @memcpy(rom[0x0000..0x001C], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, // CLC / XCE / SEP #$30
        0xA9, 0x5A, 0x8D, 0x00, 0x09, // LDA #$5A / STA $0900
        0xAF, 0x00, 0x40, 0x7E, // LDA $7E:4000  (reads the long form)
        0xA9, 0xC3, 0x8F, 0x00, 0x40, 0x7E, // LDA #$C3 / STA $7E:4000
        0xAD, 0x00, 0x09, 0x8F, 0x01, 0x40, 0x7E, // LDA $0900 / STA $7E:4001
        0x80, 0xFE, // spin
    });
    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8006, 0x8009, 0x800D, 0x800F, 0x8013, 0x8016, 0x801A }) |a| markOp(usage, a);
    usage[0x00_0900] = usage_map.flag_write; // beyond I-RAM: selects BW-RAM

    var ref: ?Refusal = null;
    const res = convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, null, &ref) catch |e| {
        std.debug.print("refused: {s}\n", .{ref.?.reason.describe()});
        return e;
    };
    defer gpa.free(res.image);
    try testing.expect(res.stats.d_moved);
    try testing.expect(res.stats.rewritten_abs >= 2);
    try testing.expect(res.stats.rewritten_long >= 3);
    // The operands really moved: $0900 -> $6900, and $7E -> $40.
    try testing.expectEqual(@as(u16, 0x6900), std.mem.readInt(u16, res.image[0x0007..0x0009], .little));
    try testing.expectEqual(@as(u8, 0x40), res.image[0x000C]);
    // BW-RAM, not 32 KiB of it: the window maps all of WRAM.
    try testing.expectEqual(@as(u8, 0x07), res.image[0x7FC0 + 0x18]);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    for (0..8) |_| con.runFrame();

    // State lives in BW-RAM at its own offsets, reached identically by the
    // absolute-window and long-rebanked forms.
    try testing.expectEqual(@as(u8, 0x5A), con.cart.sram[0x0900]);
    try testing.expectEqual(@as(u8, 0xC3), con.cart.sram[0x4000]);
    try testing.expectEqual(@as(u8, 0x5A), con.cart.sram[0x4001]);
    // ...and nothing was left behind in the WRAM the game no longer owns.
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x0900]);
    try testing.expectEqual(@as(u8, 0), con.bus.wram.data[0x4000]);
}

test "whole-game: --wg-static rewrites code the profiled run never reached" {
    const gpa = testing.allocator;
    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    // Covered code: go native 8-bit, load A (Z clear), take a BEQ that
    // dynamically never falls... never branches — the taken side is the
    // covered spin, the NOT-taken side is a block the profiler never saw.
    @memcpy(rom[0x0000..0x000D], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, // CLC / XCE / SEP #$30
        0xA9, 0x5A, // LDA #$5A (Z clear: BEQ never taken)
        0xF0, 0x05, // BEQ $800D — the statically-discovered side
        0x8D, 0x00, 0x09, // STA $0900 (covered; selects the BW-RAM window)
        0x80, 0xFE, // BRA * (covered spin)
    });
    // The uncovered block the static walk must find through the BEQ.
    @memcpy(rom[0x000D..0x0011], &[_]u8{ 0x8D, 0x02, 0x09, 0x60 }); // STA $0902 / RTS
    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    @memset(usage, 0);
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8006, 0x8008, 0x800B }) |a| markOp(usage, a);
    usage[0x00_0900] = usage_map.flag_write;

    var ref: ?Refusal = null;
    // Without the static walk the uncovered store keeps its WRAM operand...
    {
        const r = try convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, null, &ref);
        defer gpa.free(r.image);
        try testing.expectEqual(@as(u16, 0x0902), std.mem.readInt(u16, r.image[0x000E..0x0010], .little));
    }
    // ...with it, the operand moves into the window like the covered one.
    {
        const r = try convertWholeGame(gpa, rom, usage, null, null, true, false, &.{}, false, 0, copy_reserve, null, &ref);
        defer gpa.free(r.image);
        try testing.expectEqual(@as(u16, 0x6900), std.mem.readInt(u16, r.image[0x0009..0x000B], .little));
        try testing.expectEqual(@as(u16, 0x6902), std.mem.readInt(u16, r.image[0x000E..0x0010], .little));
    }
}

test "whole-game: refusals name their reasons" {
    const gpa = testing.allocator;
    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    const usage = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(usage);
    var ref: ?Refusal = null;

    // WRAM beyond the I-RAM window — and the reserved mailbox tail inside
    // it — no longer refuse: they select the BW-RAM window instead, which
    // carries all 128 KiB of WRAM. (`wg_wram_beyond_iram` now only reports
    // an operand no window can carry; the beyond-BW-RAM case is below.)
    for ([_]u32{ 0x00_0900, 0x7E_07F4, 0x7F_8000 }) |a| {
        @memset(usage, 0);
        usage[a] = usage_map.flag_write;
        const r = try convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, null, &ref);
        defer gpa.free(r.image);
        try testing.expect(r.stats.d_moved);
    }

    // An executed absolute operand that is neither WRAM, MMIO, nor ROM has
    // no home on the SA-1's bus in either window.
    @memset(usage, 0);
    usage[0x00_0900] = usage_map.flag_write; // select the BW-RAM window
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0xAD, 0x00, 0x44 }); // LDA $4400
    markOp(usage, 0x00_8100);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, null, &ref));
    try testing.expectEqual(Reason.wg_wram_beyond_bwram, ref.?.reason);
    try testing.expectEqual(@as(u32, 0x00_8100), ref.?.detail);

    // D and S must be provable at build time once the window moves them.
    // `PLD` fed by a push of an immediate is fine; fed by anything else is
    // not, and neither is a computed stack pointer.
    @memset(usage, 0);
    usage[0x00_0900] = usage_map.flag_write;
    @memcpy(rom[0x0100..0x0106], &[_]u8{ 0xA2, 0x00, 0x00, 0xDA, 0x2B, 0x60 }); // LDX #0 / PHX / PLD
    markOp(usage, 0x00_8100);
    markOp(usage, 0x00_8103);
    markOp(usage, 0x00_8104);
    usage[0x00_8100] &= ~usage_map.flag_x; // the LDX ran 16-bit
    {
        const r = try convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, null, &ref);
        defer gpa.free(r.image);
        // The immediate moved into the window with everything else.
        try testing.expectEqual(@as(u16, wg_bw_window), std.mem.readInt(u16, r.image[0x0101..0x0103], .little));
    }
    // A bare PLD is the tail of an interrupt epilogue restoring a D that
    // was already shifted when it was pushed: allowed, and left alone.
    rom[0x0103] = 0xEA; // NOP where the push was
    {
        const r = try convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, null, &ref);
        defer gpa.free(r.image);
        try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, r.image[0x0101..0x0103], .little));
    }
    // A TCD fed by something that is not an immediate is a genuine
    // establish this walk cannot follow.
    @memset(usage, 0);
    usage[0x00_0900] = usage_map.flag_write;
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0x7B, 0x5B, 0x60 }); // TDC / TCD
    markOp(usage, 0x00_8100);
    markOp(usage, 0x00_8101);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, null, &ref));
    try testing.expectEqual(Reason.wg_dp_dynamic, ref.?.reason);

    @memset(usage, 0);
    usage[0x00_0900] = usage_map.flag_write;
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0x3B, 0x1B, 0x60 }); // TSC / TCS
    markOp(usage, 0x00_8100);
    markOp(usage, 0x00_8101);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, null, &ref));
    try testing.expectEqual(Reason.wg_stack_dynamic, ref.?.reason);
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0xEA, 0xEA, 0xEA });

    // An executed IRQ handler.
    @memset(usage, 0);
    std.mem.writeInt(u16, rom[0x7FC0 + 0x2E ..][0..2], 0x8100, .little);
    markOp(usage, 0x00_8100);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, null, &ref));
    try testing.expectEqual(Reason.wg_uses_irq, ref.?.reason);
    std.mem.writeInt(u16, rom[0x7FC0 + 0x2E ..][0..2], 0, .little);

    // Native and emulation NMI handlers both ran and differ.
    @memset(usage, 0);
    std.mem.writeInt(u16, rom[0x7FC0 + 0x2A ..][0..2], 0x8050, .little);
    std.mem.writeInt(u16, rom[0x7FC0 + 0x3A ..][0..2], 0x8060, .little);
    @memcpy(rom[0x0050..0x0052], &[_]u8{ 0x68, 0x40 });
    @memcpy(rom[0x0060..0x0062], &[_]u8{ 0x68, 0x40 });
    markOp(usage, 0x00_8050);
    markOp(usage, 0x00_8060);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, null, &ref));
    try testing.expectEqual(Reason.wg_nmi_ambiguous, ref.?.reason);
    std.mem.writeInt(u16, rom[0x7FC0 + 0x2A ..][0..2], 0, .little);
    std.mem.writeInt(u16, rom[0x7FC0 + 0x3A ..][0..2], 0, .little);

    // A read-modify-write on MMIO: not proxyable in place. (Plain indexed
    // stores and loads ARE, since the helper computes the effective
    // register at run time — Gradius III's `STA $210D,Y`, `LDY $4218,X`.)
    @memset(usage, 0);
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0x1E, 0x00, 0x21 });
    markOp(usage, 0x00_8100);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, null, &ref));
    try testing.expectEqual(Reason.wg_mmio_shape, ref.?.reason);

    // A long MMIO store: no room for the in-place JSR either.
    @memset(usage, 0);
    @memcpy(rom[0x0100..0x0104], &[_]u8{ 0x8F, 0x00, 0x21, 0x00 });
    markOp(usage, 0x00_8100);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, null, &ref));
    try testing.expectEqual(Reason.wg_mmio_shape, ref.?.reason);

    // An MMIO site executing outside bank $00 (this 64K image's bank $01).
    @memset(usage, 0);
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0xEA, 0xEA, 0xEA });
    markOp(usage, 0x00_8100);
    @memcpy(rom[0xFF00..0xFF03], &[_]u8{ 0x8D, 0x00, 0x21 });
    markOp(usage, 0x01_FF00);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, null, &ref));
    try testing.expectEqual(Reason.wg_mmio_outside_bank0, ref.?.reason);
    @memset(usage, 0);

    // A block move.
    @memcpy(rom[0x0100..0x0103], &[_]u8{ 0x54, 0x00, 0x7E });
    markOp(usage, 0x00_8100);
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, usage, null, null, false, false, &.{}, false, 0, copy_reserve, null, &ref));
    try testing.expectEqual(Reason.wg_unsupported_op, ref.?.reason);
}

test "window: a battery cart's SRAM relocates above the WRAM image, mirrors normalized" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    rom[0x7FC0 + 0x16] = 0x02; // ROM + RAM + battery
    rom[0x7FC0 + 0x18] = 3; // 8 KiB SRAM, mirrored through $70:0000-$7FFF
    // Long store to $70:0000, then an INDEXED long store through the
    // MIRROR base $70:2000 — Super Metroid's boot probes its chip exactly
    // this way (pattern at $70:2000,X read back at $70:0000,X), so the
    // relocation must keep the two bases aliasing. Normalization by the
    // chip's own mask is what does it: both rewrite to $42:0000.
    @memcpy(rom[0x0000..0x0016], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, // CLC / XCE / SEP #$30
        0xA9, 0x5A, 0x8F, 0x00, 0x00, 0x70, // STA $70:0000
        0xA2, 0x05, // LDX #$05
        0xA9, 0xA5, 0x9F, 0x00, 0x20, 0x70, // STA $70:2000,X — the mirror
        0x80, 0xFE, 0xEA, 0xEA, // spin
    });

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    const map: usage_map.UsageMap = .{ .bytes = bytes };
    {
        const cart = try cartridge.Cartridge.load(gpa, rom);
        const con = try gpa.create(console.ProfilingConsole);
        defer {
            con.cart.deinit(gpa);
            gpa.destroy(con);
        }
        con.init(cart);
        con.usage = &map;
        for (0..3) |_| con.runFrame();
        // Stock semantics first: the 8 KiB chip mirrors, so the $70:2000
        // store lands at offset 5 of the same image the $70:0000 store hit.
        try testing.expectEqual(@as(u8, 0x5A), con.bus.cart.sram[0]);
        try testing.expectEqual(@as(u8, 0xA5), con.bus.cart.sram[5]);
    }

    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, bytes, null, null, false, true, &.{}, false, 0, copy_reserve, null, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u32, 2), res.stats.rewritten_sram);
    // Both operands normalized AND re-banked: $70:0000 -> $42:0000,
    // $70:2000 -> $42:0000. The aliasing survives as identity.
    try testing.expectEqualSlices(u8, &.{ 0x8F, 0x00, 0x00, 0x42 }, res.image[0x0006..0x000A]);
    try testing.expectEqualSlices(u8, &.{ 0x9F, 0x00, 0x00, 0x42 }, res.image[0x000E..0x0012]);
    // The header declares the second BW-RAM bank.
    try testing.expectEqual(@as(u8, 0x08), res.image[0x7FC0 + 0x18]);

    const cart = try cartridge.Cartridge.load(gpa, res.image);
    try testing.expectEqual(cartridge.ChipKind.sa1, cart.chip);
    const con = try gpa.create(console.FastConsole);
    defer {
        con.cart.deinit(gpa);
        gpa.destroy(con);
    }
    con.init(cart);
    for (0..3) |_| con.runFrame();
    // Both stores land in the second bank — still aliased — and the
    // relocated WRAM image below is untouched by them.
    try testing.expectEqual(@as(u8, 0x5A), con.bus.cart.sram_hi[0]);
    try testing.expectEqual(@as(u8, 0xA5), con.bus.cart.sram_hi[5]);
    try testing.expectEqual(@as(u8, 0), con.bus.cart.sram[0]);
    try testing.expectEqual(@as(u8, 0), con.bus.cart.sram[5]);

    // Non-window (SA-1-execution) mode still refuses: bank $70 would be
    // open bus on the SA-1.
    ref = null;
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, bytes, null, null, false, false, &.{}, false, 0, copy_reserve, null, &ref));
    try testing.expectEqual(Reason.has_sram, ref.?.reason);
}

test "window: a block move naming the SRAM banks refuses rather than guesses" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    rom[0x7FC0 + 0x16] = 0x02;
    rom[0x7FC0 + 0x18] = 3;
    // MVN with the SRAM bank as destination: normalize-and-rebank would
    // need a provable index; no executed move in the measured corpus does
    // this (SM's save code is all long-addressed), so it refuses.
    @memcpy(rom[0x0000..0x0014], &[_]u8{
        0x18, 0xFB, 0xC2, 0x30, // CLC / XCE / REP #$30
        0xA2, 0x00, 0x00, // LDX #$0000
        0xA0, 0x00, 0x00, // LDY #$0000
        0xA9, 0x00, 0x00, // LDA #$0000 (move 1 byte)
        0x54, 0x70, 0x7E, // MVN dst=$70, src=$7E
        0x80, 0xFE, 0xEA,
        0xEA,
    });
    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    const map: usage_map.UsageMap = .{ .bytes = bytes };
    {
        const cart = try cartridge.Cartridge.load(gpa, rom);
        const con = try gpa.create(console.ProfilingConsole);
        defer {
            con.cart.deinit(gpa);
            gpa.destroy(con);
        }
        con.init(cart);
        con.usage = &map;
        for (0..2) |_| con.runFrame();
    }
    var ref: ?Refusal = null;
    try testing.expectError(error.Refused, convertWholeGame(gpa, rom, bytes, null, null, false, true, &.{}, false, 0, copy_reserve, null, &ref));
    try testing.expectEqual(Reason.wg_blockmove_source, ref.?.reason);
}

test "window: a DMA bank byte riding X is proven and re-banked" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    // Super Metroid's palette uploader: the A-bus bank rides X, not A —
    // `LDX #$7E / STX $4314` (measured: 8,372 events from that one site,
    // and wrong colours from the first visible frame). The provenance
    // chain proves the X-load's immediate byte; the conversion re-banks
    // it so the DMA follows the relocated WRAM into BW-RAM.
    @memcpy(rom[0x0000..0x000C], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, // CLC / XCE / SEP #$30
        0xA2, 0x7E, // LDX #$7E — the byte to prove ($00:8005)
        0x8E, 0x14, 0x43, // STX $4314
        0x80, 0xFE, 0xEA, // spin
    });

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    const pe = try gpa.create(usage_map.PtrBankEvidence);
    defer gpa.destroy(pe);
    pe.* = .init;
    const map: usage_map.UsageMap = .{ .bytes = bytes, .ptr_banks = pe };
    {
        const cart = try cartridge.Cartridge.load(gpa, rom);
        const con = try gpa.create(console.ProfilingConsole);
        defer {
            con.cart.deinit(gpa);
            gpa.destroy(con);
        }
        con.init(cart);
        con.usage = &map;
        for (0..2) |_| con.runFrame();
    }
    try testing.expectEqual(@as(usize, 1), pe.n_proven);
    try testing.expectEqual(@as(u32, 0x8005), pe.proven[0]);
    try testing.expectEqual(@as(u32, 0), pe.unresolved);

    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, bytes, null, pe, false, true, &.{}, false, 0, copy_reserve, null, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u32, 1), res.stats.rewritten_ptr_banks);
    try testing.expectEqual(@as(u8, 0x40), res.image[0x0005]);
}

test "window: a $C0-$DF table bank byte proves through the dp-staged PLB pin" {
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    // Super Metroid's round-2 music upload: the pointer table's bank byte
    // ($D0) rides the HIGH half of a 16-bit dp store, gets pulled into DBR
    // via `LDA $02 / PHA / PLB`, and the next data access under that DBR
    // is the proof. The byte re-banks -$20 (the Super MMC misfit).
    @memcpy(rom[0x0000..0x001B], &[_]u8{
        0x18, 0xFB, 0xC2, 0x30, // CLC / XCE / REP #$30
        0xA2, 0x00, 0x00, // LDX #$0000
        0xBF, 0x21, 0x80, 0x00, // LDA $00:8021,X — table word (E2, D0)
        0x85, 0x01, // STA $01 -> dp $01/$02
        0xE2, 0x20, // SEP #$20
        0xA5, 0x02, // LDA $02 — the bank byte, staged
        0x48, 0xAB, // PHA / PLB -> DBR = $D0
        0xA0, 0x00, 0x90, // LDY #$9000
        0xB9, 0x00, 0x00, // LDA $0000,Y — access under the $D0 DBR
        0x80, 0xFE, // spin
    });
    rom[0x0020] = 0x11; // table entry: addr lo (unused here)
    rom[0x0021] = 0xE2; // addr hi
    rom[0x0022] = 0xD0; // the bank byte to prove

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    const pe = try gpa.create(usage_map.PtrBankEvidence);
    defer gpa.destroy(pe);
    pe.* = .init;
    const map: usage_map.UsageMap = .{ .bytes = bytes, .ptr_banks = pe };
    {
        const cart = try cartridge.Cartridge.load(gpa, rom);
        const con = try gpa.create(console.ProfilingConsole);
        defer {
            con.cart.deinit(gpa);
            gpa.destroy(con);
        }
        con.init(cart);
        con.usage = &map;
        for (0..2) |_| con.runFrame();
    }
    // The tight-dp pin records a TRANSLATE site — the table byte may be
    // dual-role (a bank for one consumer, an address for another), so it
    // stays stock and the pin itself maps at runtime.
    try testing.expectEqual(@as(usize, 0), pe.n_hi);
    try testing.expectEqual(@as(usize, 1), pe.n_xl);
    try testing.expectEqual(@as(u32, 0x8012), pe.xl_sites[0]);

    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, bytes, null, pe, false, true, &.{}, false, 0, copy_reserve, null, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u32, 1), res.stats.xl_pins);
    try testing.expectEqual(@as(u8, 0xD0), res.image[0x0022]); // byte stays stock
    try testing.expectEqual(@as(u8, 0x5C), res.image[0x000F]); // site is a JML thunk
}

test "static walk: a covered JSL whose callee never returned still falls through" {
    // Two shapes share "covered JSL, uncovered return": INLINE PARAMS (the
    // profile marked a real opcode a few bytes past the call — stop, or the
    // params decode as code) and a CALLEE THAT NEVER RETURNED during
    // profiling (the door-transition chain: the recording crashed inside
    // call #1, so calls #2 and #3 behind it kept stock banks and the next
    // playthrough crashed one call later). The discriminator is dynamic
    // coverage within a small window after the call.
    const gpa = testing.allocator;
    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    // site A @8100: JSL $008180, then two more JSLs — callee crashed, the
    // window after A is dyn-dead. All three must be statically walked.
    @memcpy(rom[0x0100..0x010C], &[_]u8{
        0x22, 0x80, 0x81, 0x00, // JSL $00:8180  (dyn-covered, crashed inside)
        0x22, 0x90, 0x81, 0x00, // JSL $00:8190  (never executed)
        0x22, 0xA0, 0x81, 0x00, // JSL $00:81A0  (never executed)
    });
    rom[0x010C] = 0x60; // RTS
    rom[0x0180] = 0x60;
    rom[0x0190] = 0x60;
    rom[0x01A0] = 0x60;
    // site B @8200: the inline-params shape — dyn coverage resumes at +12,
    // the 8 bytes after the JSL are DATA and must NOT be decoded.
    @memcpy(rom[0x0200..0x0204], &[_]u8{ 0x22, 0xB0, 0x81, 0x00 });
    @memset(rom[0x0204..0x020C], 0x42); // param block (WDM soup)
    rom[0x020C] = 0x60; // the real return point (dyn-covered below)
    rom[0x01B0] = 0x60;

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    markOp(bytes, 0x8100); // the crashed call — covered
    markOp(bytes, 0x8200); // the inline-params call — covered
    markOp(bytes, 0x820C); // ...and its skipped-params return point

    const header = try header_mod.detect(rom);
    const ext = try extendCoverage(gpa, rom, header, bytes);
    defer gpa.free(ext);
    // Crashed-callee chain: both sibling JSLs statically reached.
    try testing.expect(ext[0x8104] & usage_map.flag_opcode != 0);
    try testing.expect(ext[0x8108] & usage_map.flag_opcode != 0);
    // Inline params stay data.
    try testing.expect(ext[0x8204] & usage_map.flag_opcode == 0);
}

test "window: a misfit bank staged via 16-bit STA $4313 proves and re-banks" {
    // The Ceres door-tile upload: `LDA $tbl,X / STA $4313` stages A1T-hi in
    // the low byte and the BANK ($B0, mirror-intent MB1) in the high. The
    // $7E arm of this family existed; the misfit arm did not, so the $B0
    // went unproven and the DMA read the wrong megabyte. The high byte's
    // ROM source must prove and re-bank -$80.
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    @memcpy(rom[0x0000..0x0012], &[_]u8{
        0x18, 0xFB, 0xC2, 0x30, // CLC / XCE / REP #$30
        0xA2, 0x00, 0x00, // LDX #$0000
        0xBD, 0x20, 0x80, // LDA $8020,X — table word (C4, B0)
        0x8D, 0x13, 0x43, // STA $4313 — A1T-hi + A1B
        0xA9, 0x00, 0x04, // LDA #$0400
        0x80, 0xFE, // spin
    });
    rom[0x0020] = 0xC4; // A1T-hi
    rom[0x0021] = 0xB0; // the misfit bank byte

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    const pe = try gpa.create(usage_map.PtrBankEvidence);
    defer gpa.destroy(pe);
    pe.* = .init;
    const map: usage_map.UsageMap = .{ .bytes = bytes, .ptr_banks = pe };
    {
        const cart = try cartridge.Cartridge.load(gpa, rom);
        const con = try gpa.create(console.ProfilingConsole);
        defer {
            con.cart.deinit(gpa);
            gpa.destroy(con);
        }
        con.init(cart);
        con.usage = &map;
        for (0..2) |_| con.runFrame();
    }
    try testing.expectEqual(@as(usize, 1), pe.n_a0);
    try testing.expectEqual(@as(u32, 0x8021), pe.a0_proven[0]);
}

test "static walk: a raw $FC inside profile-read data is not a dispatcher" {
    // The Ceres confetti byte: compressed stream data happened to contain
    // `FC FC 0A` — a coincidental `JSR ($0AFC,X)` — while covered code
    // elsewhere stored a 16-bit literal into the same cell. The raw
    // dispatcher scan seeded the stream as code and window-shifted the fake
    // operand ($0A -> $6A) inside the data. Bytes the profile READ without
    // executing must never match as dispatchers.
    const gpa = testing.allocator;
    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    // Covered code: store a pointer literal into cell $0AFC, then a real
    // `JMP ($0AFC)` dispatcher so the cell ACTIVATES (both tiers).
    @memcpy(rom[0x0000..0x000B], &[_]u8{
        0x18, 0xFB, 0xC2, 0x30, // CLC / XCE / REP #$30
        0xA9, 0x00, 0x83, // LDA #$8300
        0x8D, 0xFC, 0x0A, // STA $0AFC
        0x6C, // JMP ($0AFC) -> covered dispatcher at 800A
    });
    rom[0x000B] = 0xFC;
    rom[0x000C] = 0x0A;
    rom[0x0300] = 0x60; // the pointer target: RTS
    // Profile-READ data containing the same coincidental shape.
    @memcpy(rom[0x0500..0x0503], &[_]u8{ 0xFC, 0xFC, 0x0A });

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    // The activation matcher demands the literal store run M16 — mark the
    // covered ops with 16-bit widths (flag_m/flag_x CLEAR), not markOp's m8.
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8007, 0x800A }) |a|
        bytes[a] |= usage_map.flag_opcode | usage_map.flag_exec;
    bytes[0x8500] |= usage_map.flag_read; // the stream byte: READ, never executed
    bytes[0x8501] |= usage_map.flag_read;
    bytes[0x8502] |= usage_map.flag_read;

    const header = try header_mod.detect(rom);
    const ext = try extendCoverage(gpa, rom, header, bytes);
    defer gpa.free(ext);
    // The data's fake dispatcher must NOT be decoded as code.
    try testing.expect(ext[0x8500] & usage_map.flag_opcode == 0);
    // The real dispatcher's pointer target IS reached (the feature works).
    try testing.expect(ext[0x8300] & usage_map.flag_opcode != 0);
}

test "window: the abs,X-loaded HIGH-byte PLB pin translates instead of value-proving" {
    // Super Metroid's Ceres escape tile builder, reduced: a 16-bit table
    // word holds an ADDRESS HALF in its low byte and the bank in its high
    // byte; `LDA $abs,X / PHA / PLB / PLB` pins the high byte as DBR. The
    // old value-proof credited the word's staged source and re-banked the
    // ADDRESS half -$80 (measured: ROM $20:E276, $BA -> $3A — the builder
    // then read $B0:3Axx zeros and the escape's beam/door sprites went
    // blank). The dual-role word must stay stock; the pin site translates.
    const gpa = testing.allocator;
    const console = @import("../console.zig");

    const rom = try makeWgRom(gpa);
    defer gpa.free(rom);
    @memcpy(rom[0x0000..0x001B], &[_]u8{
        0x18, 0xFB, 0xC2, 0x30, // CLC / XCE / REP #$30
        0xA9, 0xBA, 0xB0, // LDA #$B0BA — the dual-role table word
        0x8D, 0x40, 0x01, // STA $0140
        0xA2, 0x00, 0x00, // LDX #$0000
        0xBD, 0x40, 0x01, // LDA $0140,X — the abs,X pin load
        0x48, 0xAB, 0xAB, // PHA / PLB / PLB -> DBR = $B0 (misfit)
        0xA0, 0x00, 0x90, // LDY #$9000
        0xB9, 0x00, 0x00, // LDA $0000,Y — access under the $B0 DBR
        0x80, 0xFE, // spin
    });

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    const pe = try gpa.create(usage_map.PtrBankEvidence);
    defer gpa.destroy(pe);
    pe.* = .init;
    const map: usage_map.UsageMap = .{ .bytes = bytes, .ptr_banks = pe };
    {
        const cart = try cartridge.Cartridge.load(gpa, rom);
        const con = try gpa.create(console.ProfilingConsole);
        defer {
            con.cart.deinit(gpa);
            gpa.destroy(con);
        }
        con.init(cart);
        con.usage = &map;
        for (0..2) |_| con.runFrame();
    }
    // No value proof — the word is dual-role; the pin records a translate
    // site at the SECOND PLB.
    if (pe.n_a0 != 0 or pe.n_xl != 1) {
        for (pe.a0_proven[0..pe.n_a0]) |a| std.debug.print("[dbg] a0_proven ${x:0>6}\n", .{a});
        for (pe.xl_sites[0..pe.n_xl]) |a| std.debug.print("[dbg] xl_site   ${x:0>6}\n", .{a});
    }
    try testing.expectEqual(@as(usize, 0), pe.n_a0);
    try testing.expectEqual(@as(usize, 1), pe.n_xl);
    try testing.expectEqual(@as(u32, 0x8012), pe.xl_sites[0]);

    var ref: ?Refusal = null;
    const res = try convertWholeGame(gpa, rom, bytes, null, pe, false, true, &.{}, false, 0, copy_reserve, null, &ref);
    defer gpa.free(res.image);
    try testing.expectEqual(@as(u32, 1), res.stats.xl_pins);
    try testing.expectEqual(@as(u8, 0xBA), res.image[0x0005]); // addr half stays stock
    try testing.expectEqual(@as(u8, 0xB0), res.image[0x0006]); // bank byte stays stock
    try testing.expectEqual(@as(u8, 0x5C), res.image[0x000D]); // BD site is a JML thunk
}
