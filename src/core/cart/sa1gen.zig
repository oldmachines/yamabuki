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
    mode_gate: bool = false,
};

/// File offset of a 24-bit LoROM code address (banks $00-$3F and their
/// $80-$BF mirrors alias the same bytes).
fn splitFile(a: u24) usize {
    return @as(usize, (a >> 16) & 0x7F) * 0x8000 + (@as(usize, a & 0xFFFF) - 0x8000);
}

/// Coverage flags of a site, whichever mirror the game ran it in.
fn splitUsage(usage: []const u8, a: u24) u8 {
    return usage[a] | usage[a ^ 0x80_0000];
}

/// The split's I-RAM cells, clear of the offload mailbox ($3780-$378F).
const split_ring_wr: u16 = 0x3790; // SA-1 appends
const split_ring_rd: u16 = 0x3791; // S-CPU drains
const split_vbl_mirror: u16 = 0x3792; // live $4212 image
const split_pad_mirror: u16 = 0x3794; // $4218-$421F, 8 bytes
const split_cell_d: u16 = 0x379C; // game D at engage
const split_cell_p: u16 = 0x379D; // game P at engage
const split_cell_s: u16 = 0x379E; // game S at engage (16-bit)
const split_ring: u16 = 0x37A0; // 16 ids
const split_engaged: u16 = 0x37B0; // 0 until the S-CPU engages; the SA-1's laps through the anchor bounce off it
const split_scr_p: u16 = 0x37B1; // deferred-skip scratch (SA-1-exclusive: interrupt-free)
const split_scr_a: u16 = 0x37B2;
const split_token: u16 = 0x37B3; // the S-CPU NMI increments; the SA-1 frame loop edges on it
const split_last: u16 = 0x37B4; // the SA-1's copy of the last token it ran
const split_done: u16 = 0x37B5;
const split_cell_dbr: u16 = 0x37B6;
const split_rpc_ack: u16 = 0x37B7; // bumped AFTER a replayed body returns — the RPC release (rd consumes EARLY so nested drains cannot re-enter an in-service call) // the RPC caller's DBR (one call in flight, ever) // the last token whose tail COMPLETED — the head's gate
const split_cell_a: u16 = 0x37BC; // RPC caller A (16-bit)
const split_cell_x: u16 = 0x37BE; // RPC caller X — $9231 takes its VRAM fill target HERE
const split_cell_y: u16 = 0x37C0; // RPC caller Y — and its word count here
const split_cell_t: u16 = 0x37C2; // drain scratch: the dispatch pointer, so the caller's X can be restored before the call
const split_cell_pw: u16 = 0x37BA; // the RPC caller's P — replays must enter with the caller's M/X widths (a width-agnostic appender ran X8 and truncated its 16-bit cursor)
const split_in_replay: u16 = 0x37BB; // nonzero while a drain's replay is in flight: a nested NMI's mini-tok must not start another (a multi-frame sample stream nested 25 bytes deeper every frame)
const split_ring2_wr: u16 = 0x37B8; // fire-and-forget ring (sound family): slot index 0-11
const split_ring2_rd: u16 = 0x37B9;
const split_ring2: u16 = 0x3680; // 24 records of [id][D.lo][D.hi][pad] — bursts (a boss-area SFX barrage) lapped a 12-slot ring and the drain replayed a blank record
const split_sa1_stack: u16 = 0x3778; // the old dispatcher stack slot, free in split mode
const split_pump_stack: u16 = 0x37F0;
/// Mainloop flavor: the pump's stack lives in REAL WRAM (freed by the
/// relocation), not I-RAM — the stack page is the CPU discriminator, and
/// a pump on a $3xxx page would replay a body whose nested IO calls take
/// themselves for the SA-1 and enqueue to a drain that is busy with them.
const split_ml_pump_stack: u16 = 0x1EFF;
/// Mainloop flavor: the SA-1's stack top. The tail flavor's $3778 leaves
/// 120 bytes above the split's cells at $36E0; a game loop's call depth
/// wants more, and I-RAM below $3600 is free of every cell.
const split_ml_sa1_stack: u16 = 0x35FF;
/// The COP handler's direct page (16 bytes of I-RAM scratch).
const split_cop_dp: u16 = 0x3640;
/// Mainloop flavor: the loop's context at the anchor when ownership
/// changes hands (A/X/Y here; D, DBR, P, S in the engage cells), and
/// the owner cell: 1 = the SA-1 runs the laps, 0 = the S-CPU does.
const split_ctx_a: u16 = 0x36E0;
const split_ctx_x: u16 = 0x36E2;
const split_ctx_y: u16 = 0x36E4;
const split_owner: u16 = 0x36E6;
/// The dispatch pointer's bank byte, right after `split_cell_t`.
const split_cell_tb: u16 = 0x37C4;
/// The math shadow (mainloop flavor): the S-CPU's multiplier/divider
/// registers as I-RAM cells the SA-1 side computes into — $4202/$4203
/// (multiplicands), $4204-$4206 (dividend, divisor; the byte after the
/// divisor stays zero so a 16-bit subtract reads it as such), then
/// $4214/$4215 (quotient) and $4216/$4217 (remainder / product).
const split_math_a: u16 = 0x36F0;
const split_math_div: u16 = 0x36F2;
const split_math_q: u16 = 0x36F6;
const split_math_r: u16 = 0x36F8;

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
const shim_len_max: u32 = 40;
const park_len: u32 = 2;
/// The async offload's NMI prologue: save context, JSL the fence, restore,
/// JMP the game's own handler. Carved after the park stub.
const nmi_prologue_len: u32 = 21;

fn emitStore(w: []u8, n: usize, reg: u16, value: u8) usize {
    w[n] = 0xA9; // LDA #value
    w[n + 1] = value;
    w[n + 2] = 0x8D; // STA reg
    w[n + 3] = @truncate(reg);
    w[n + 4] = @truncate(reg >> 8);
    return n + 5;
}

fn refuse(refusal: *?Refusal, r: Refusal) Error {
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

/// The I-RAM mailbox the offload handshake marshals registers through
/// (window addresses $3780-$3786: A, X, Y 16-bit; P 8-bit at +6). The SA-1's
/// stack is parked just below it. Plans that filled I-RAM past $3700 skip
/// offload rather than collide.
const mailbox: u16 = 0x3780;
const iram_offload_limit: u32 = 0x700;

/// S3b: offload the first eligible hot routine to the SA-1. Eligibility is a
/// static walk of the routine's covered code (leaf, single RTS exit, every
/// data access SA-1-visible after the relocation); the machinery is an
/// S-CPU stub and an SA-1 dispatcher speaking the real CFR/SFR message
/// nibbles, registers marshalled through the I-RAM mailbox. Executed JSR
/// call sites are re-pointed at the stub; unseen call sites keep calling the
/// original routine on the S-CPU, which stays correct — the routine's code
/// is never modified.
pub const offload_max: usize = 7;

/// The pointer-offload's BW-RAM shadow: WRAM $7E:xxxx mirrors at bank $41
/// (linear $10000+xxxx) — identity offsets, so pointer VALUES survive and
/// only bank bytes translate. Bank $41 keeps the whole shadow inside the
/// cart's 128 KiB BW-RAM ceiling (`cartridge.max_sram`); routines whose
/// profiled pages touch $7F have no shadow home and stay on the S-CPU.
/// The SA-1 runs pointer routines with D=$6000 and its BW-RAM window
/// (CBM block 8) mapped over the shadow's first 8 KiB, so dp operands
/// stay byte-identical too.
const shadow_linear: u32 = 0x1_0000;
const shadow_bank: u8 = 0x41;
const ptr_slot_cap = 6;
const ptr_db_cap = 4;
const ptr_tree_cap = 8;
const ptr_wram_long_cap = 16;
/// Sum-of-spans budget for one tree's copies (overlapping members each
/// carry their own copy of any shared tail, so this bounds the carve).
const ptr_tree_span_max: u32 = 4096;
const ptr_run_cap = 8;
const ptr_pages_cap = 32;

/// Master cycles the S-CPU's MVN spends per byte, each way. The marshal
/// copies the working set in and out, so a page costs 2 * 256 * this.
const mvn_cycles_per_byte: u64 = 7;

/// The marshal must cost less than this fraction of what the routine
/// actually spends computing, per call — otherwise the "offload" is a
/// regression dressed as a conversion. Half is deliberately conservative:
/// the SA-1 runs the work at ~2.7x the S-CPU's clock with no bus
/// contention, so a marshal at half the routine's own cost still leaves a
/// real win, and anything dearer is refused rather than shipped and
/// measured later.
const marshal_budget_num: u64 = 1;
const marshal_budget_den: u64 = 2;

/// What the pointer-eligibility walk proves about a routine.
const PtrSpec = struct {
    /// dp offsets of the BANK bytes of long-indirect pointers ([dp] /
    /// [dp],y name a 24-bit pointer at dp..dp+2) — translated $7E/$7F ->
    /// $42/$43 in the shadow before the SA-1 runs, and back after.
    slots: [ptr_slot_cap]u8 = undefined,
    n_slots: usize = 0,
    /// File offsets of the $7E immediate in a LDA #$7E / PHA / PLB idiom —
    /// rewritten to the shadow bank IN THE SA-1'S COPY of the routine so
    /// (dp),y stores land in the shadow. The original body is never
    /// modified: unseen S-CPU callers keep calling unchanged code.
    db_sites: [ptr_db_cap]u32 = undefined,
    n_db: usize = 0,
    /// Bytes from entry to the closing RTL: the span copied for the SA-1.
    span: u32 = 0,
    /// The CALL TREE: members[0] is the root; the rest are bank-$00
    /// JSL/RTL helpers the tree JSLs, each walked by the same rules and
    /// copied alongside the root (JSL operands in the copies are rebased
    /// member-to-member). Only the ROOT's call sites are re-pointed at a
    /// stub — a helper's outside callers keep running the original, which
    /// is safe for a synchronous offload because the S-CPU spins in the
    /// stub for the whole SA-1 run. `pin` is the data bank the member
    /// INHERITS at entry — the caller's pin at every tree JSL that
    /// reaches it (the copy is only ever entered through those JSLs); a
    /// disagreement between call sites sets `conflict` and refuses the
    /// tree.
    members: [ptr_tree_cap]struct { entry: u16, span: u32, pin: ?u8, conflict: bool } = undefined,
    n_members: usize = 0,
    /// Sum of the members' spans: the carve the copies need.
    total_span: u32 = 0,
    /// File offsets of the BANK byte of long WRAM operands ($7E:xxxx, or
    /// the $00-$3F low mirror of it) — rewritten to the shadow bank in
    /// the copy (identity offsets make the 16 bits carry over; a $00-$3F
    /// mirror's low half IS $7E:0000-1FFF). On the SA-1 those addresses
    /// are I-RAM or nothing, so without the rewrite the body reads noise.
    wram_long_sites: [ptr_wram_long_cap]u32 = undefined,
    n_wram_long: usize = 0,
    /// Every helper's executed JSL sites lie inside the tree: nothing
    /// outside can run a helper WHILE the SA-1 does — the gate async
    /// needs (sync never overlaps, so it never cares).
    helpers_private: bool = true,
};

/// The routine's profiled WRAM pages coalesced into marshal runs (split at
/// the $7E/$7F boundary so each run has one MVN bank pair).
const Runs = struct {
    start: [ptr_run_cap]u16 = undefined, // first page index
    len: [ptr_run_cap]u16 = undefined, // pages
    n: usize = 0,
};

fn pageRuns(pages: profile.WramPages) ?Runs {
    var runs: Runs = .{};
    var total: u32 = 0;
    var p: u16 = 0;
    while (p < 512) : (p += 1) {
        if (!profile.getPage(pages, p)) continue;
        if (p >= 256) return null; // $7F has no shadow home
        total += 1;
        if (runs.n > 0 and runs.start[runs.n - 1] + runs.len[runs.n - 1] == p) {
            runs.len[runs.n - 1] += 1;
        } else {
            if (runs.n == ptr_run_cap) return null;
            runs.start[runs.n] = p;
            runs.len[runs.n] = 1;
            runs.n += 1;
        }
    }
    if (total > ptr_pages_cap) return null;
    return runs;
}

const OffloadKind = enum { leaf, ptr };

const Chosen = struct {
    entry: u16,
    kind: OffloadKind,
    spec: PtrSpec = .{},
    runs: Runs = .{},
    /// Sibling entry points inside this routine's span whose page sets
    /// were folded into the marshal set.
    siblings: u32 = 0,
    /// This routine's data lives in BW-RAM permanently instead of being
    /// marshalled: the original body's data-bank idiom is rewritten too,
    /// so the S-CPU's own calls address the same single copy.
    resident: bool = false,
    /// Fire-and-forget: the S-CPU stub sends the message and returns
    /// immediately with the caller's own registers; a fence (at the next
    /// call, and each NMI) completes the handshake. NOTHING is copied
    /// back — register results and dp writes are dropped; only effects on
    /// BW-RAM-resident state survive, so resident routines only.
    is_async: bool = false,
    /// Where the SA-1's rewritten copy of a pointer routine landed (the
    /// dispatcher JSLs it; the original body is never modified).
    copy_addr: u16 = 0,
    copy_bank: u8 = 0,
};

fn tryOffload(
    out: []u8,
    plan: *const profile.Plan,
    usage: []const u8,
    candidates: []const Candidate,
    neighbours: []const Candidate,
    dma_pages: profile.WramPages,
    shim_carve: u32,
    allow_async: bool,
    res: *Result,
    crv: *u16,
) void {
    // The offload machinery parks the SA-1 stack and mailbox in I-RAM
    // $700-$7FF, which must not carry LIVE relocated state. A region that
    // "moved" with zero rewritten sites is dead storage — nothing refers
    // to its new home — and may be overlaid.
    if (iramLive(plan, res) > iram_offload_limit) return;
    const shadow_ok = bwramLive(plan, res) <= shadow_linear;
    var chosen: [offload_max]Chosen = undefined;
    var n: usize = 0;
    for (candidates) |c| {
        if (n == offload_max) break;
        if (c.entry >> 16 != 0 or (c.entry & 0xFFFF) < 0x8000) continue;
        const e: u16 = @truncate(c.entry);
        const dup = for (chosen[0..n]) |x| {
            if (x.entry == e) break true;
        } else false;
        if (dup) continue;
        // An async offload monopolizes the mailbox: a sibling stub that
        // sends its message while the fire-and-forget call is still in
        // flight deadlocks the dispatcher (it holds the async done echo,
        // awaiting an ack; the sibling overwrites the message port and
        // spins on an echo the dispatcher will never send). Until sync
        // stubs learn to fence first, async rides alone.
        if (n > 0 and chosen[0].is_async) break;
        if (eligibleLeaf(out, usage, plan, res, e)) {
            if (countCallSites(out, usage, e, 0x20) == 0) continue;
            chosen[n] = .{ .entry = e, .kind = .leaf };
            n += 1;
            continue;
        }
        // Pointer path: dynamic evidence (the profiled page set) + the
        // static walk; requires the shadow banks free and D unmoved (the
        // dispatcher swaps D to $6000 per call and back to 0).
        if (!shadow_ok or res.stats.d_moved) continue;
        const spec = eligiblePointer(out, usage, e) orelse continue;
        // The marshal set is the union over every candidate whose entry
        // lies INSIDE this routine's span: alternate entry points into one
        // body (a resumable state machine's "start" and "continue") are
        // separately attributed by the profiler, but they are one routine
        // sharing one working set. Marshalling only the entry we offload
        // ships a partial view of that state — the exact failure the
        // auto-bisector caught on a real cart.
        // The direct page is MANDATORY, not evidence-driven: the SA-1
        // runs the body with D over the shadow window, so every dp
        // operand it executes resolves into the shadow. If the dp page
        // is not marshalled the routine runs on whatever the shadow
        // happened to hold — which is exactly how a resumable state
        // machine reads its own progress cursor as "already finished"
        // and returns having done nothing. The profiled page set does
        // not reliably carry it (a routine's dp traffic can be
        // attributed elsewhere, and coldness is not absence), so the
        // mechanism supplies it unconditionally.
        var marshal_pages = c.pages;
        var siblings: u32 = 0;
        for ([_][]const Candidate{ candidates, neighbours }) |list| {
            for (list) |o| {
                if (o.entry == c.entry) continue;
                // Inside ANY tree member: alternate entry points into the
                // root, and the helpers themselves — the SA-1 runs their
                // code, so their working sets ride along.
                const in_tree = for (spec.members[0..spec.n_members]) |m| {
                    if (o.entry >= m.entry and o.entry - m.entry < m.span) break true;
                } else false;
                if (!in_tree) continue;
                for (&marshal_pages, o.pages) |*p, op| p.* |= op;
                siblings += 1;
            }
        }
        // --- persistent BW-RAM residency -------------------------------
        // Marshalling is a copy of state that exists in two places; every
        // copy is a chance for the two to disagree, and the window
        // between them is exactly where an NMI can write WRAM that the
        // copy-back then overwrites. Residency removes the copy instead
        // of shrinking the race: the routine's data lives in BW-RAM
        // permanently, which BOTH CPUs address identically (bank $41 at
        // the same 16-bit offset), so there is one copy and nothing to
        // synchronise.
        //
        // It is earned, not assumed. The routine must reach its data
        // through the LDA #$7E / PHA / PLB data-bank idiom (so rewriting
        // that one immediate re-points every access it makes, on both
        // CPUs — the ORIGINAL body is rewritten too, which is what makes
        // the S-CPU's own calls agree), and every page it touches must
        // be PRIVATE to it: no other profiled routine reads or writes
        // them, and no DMA arm names them. It is all-or-nothing, because
        // one data bank serves every access the routine makes: a
        // half-resident routine would send some writes to BW-RAM and
        // leave the rest in WRAM.
        //
        // The direct page is never resident: the 65816's direct page is
        // always bank $00, so the S-CPU cannot see BW-RAM through it.
        // It stays marshalled — 256 bytes instead of kilobytes.
        const dp_page: u16 = @intCast((c.entry_d >> 8) & 0xFF);
        var resident = spec.n_db > 0 and !c.d_varies;
        if (resident) {
            var p: u16 = 0;
            while (p < 512) : (p += 1) {
                if (!profile.getPage(marshal_pages, p) or p == dp_page) continue;
                if (profile.getPage(dma_pages, p)) {
                    if (dbg_walk_root != 0 and e == dbg_walk_root)
                        std.debug.print("[walk] {x:0>4}: page {x:0>2} feeds DMA — not resident\n", .{ e, p });
                    resident = false;
                    break;
                }
                for ([_][]const Candidate{ neighbours, candidates }) |list| {
                    for (list) |o| {
                        if (o.entry == c.entry) continue;
                        // Tree members and the siblings inside them share
                        // the body and get the same rewrite, so their
                        // traffic is this routine's traffic.
                        const in_tree = for (spec.members[0..spec.n_members]) |m| {
                            if (o.entry >= m.entry and o.entry - m.entry < m.span) break true;
                        } else false;
                        if (in_tree) continue;
                        if (profile.getPage(o.pages, p)) {
                            if (dbg_walk_root != 0 and e == dbg_walk_root)
                                std.debug.print("[walk] {x:0>4}: page {x:0>2} shared with ${x:0>6} — not resident\n", .{ e, p, o.entry });
                            resident = false;
                            break;
                        }
                    }
                    if (!resident) break;
                }
                if (!resident) break;
            }
            // The profile says who TOUCHED these pages; the coverage map
            // says who NAMES them. Both matter: a routine the profile
            // never separated out, or one that reads the data once from
            // a long operand, still breaks if the bytes move. So refuse
            // residency when any executed instruction outside this
            // routine's own span statically names a page we would move.
            if (resident and namedOutside(out, usage, &spec, marshal_pages, dp_page))
                resident = false;
        }
        // Resident pages are not copied: only the direct page is, and
        // that one dynamically (the stub reads D at run time).
        var static_pages = marshal_pages;
        if (resident) static_pages = @splat(0);
        const runs = pageRuns(static_pages) orelse Runs{};
        // Economics: the marshal must be cheaper than the compute it
        // enables. Candidates with no measured calls skip the test (the
        // synthetic unit tests, which carry no profile).
        if (c.calls != 0) {
            var bytes: u64 = 0;
            for (0..runs.n) |r| bytes += @as(u64, runs.len[r]) * 256;
            const marshal_cost = bytes * 2 * mvn_cycles_per_byte;
            const per_call = c.self_cycles / c.calls;
            if (marshal_cost * marshal_budget_den > per_call * marshal_budget_num) {
                if (dbg_walk_root != 0 and e == dbg_walk_root)
                    std.debug.print("[walk] {x:0>4}: UNECONOMIC — marshal {} bytes ({} cycles) vs {} cycles/call\n", .{ e, bytes, marshal_cost, per_call });
                continue;
            }
        }
        if (countCallSites(out, usage, e, 0x22) == 0) {
            if (dbg_walk_root != 0 and e == dbg_walk_root)
                std.debug.print("[walk] {x:0>4}: no executed JSL call sites\n", .{e});
            continue;
        }
        // Fire-and-forget: RESIDENT routines only — an async call keeps no
        // write-back at all (register results and dp writes are both
        // dropped; see emitFence), so only effects on BW-RAM-resident
        // state can survive, and a routine without any has nothing async
        // could deliver. FIRST and therefore alone (the monopoly guard
        // above stops the choosing once an async is in — a sibling's
        // un-fenced send would deadlock the dispatcher), few slots, and
        // never when the ladder already demoted it. Whether any caller
        // needed the dropped effects is exactly what verification
        // arbitrates, and the mode ladder retries synchronously when it
        // says so.
        // A tree with a SHARED helper additionally rules out async: an
        // outside caller would run the helper's original on the S-CPU
        // while the SA-1 runs the copy — sync never overlaps, async is
        // nothing but overlap.
        const is_async = allow_async and resident and !c.no_async and spec.n_slots <= 2 and n == 0 and
            (spec.n_members == 1 or spec.helpers_private);
        chosen[n] = .{ .entry = e, .kind = .ptr, .spec = spec, .runs = runs, .siblings = siblings, .resident = resident, .is_async = is_async };
        n += 1;
    }
    if (n == 0) return;

    // Dispatcher layout (byte-exact; the emitters below mirror it):
    //   prologue 28 | loop body 12 | id blocks (leaf 16 / ptr 25) |
    //   JMP loop 3 | signal 19 | unmarshal 21 | marshal 24
    // Pointer stubs are fully long-addressed and JSL-reached, so they may
    // live in ANY bank — carved from padding past the shim region, which
    // keeps every carve disjoint by construction. No room for them keeps
    // the leaves and retries the sizing.
    const ptr_area_start: u32 = shim_carve + shim_len_max + park_len;
    var blocks_len: u32 = 0;
    var leaf_stubs: u32 = 0;
    var base: u32 = 0;
    var ptr_base: u32 = 0;
    while (true) {
        blocks_len = 0;
        leaf_stubs = 0;
        var ptr_stub_len: u32 = 0;
        for (chosen[0..n]) |c| switch (c.kind) {
            .leaf => {
                blocks_len += 16;
                leaf_stubs += 1;
            },
            .ptr => {
                blocks_len += 33;
                ptr_stub_len += if (c.is_async)
                    fenceLen(c.spec) + asyncStubLen(c.spec) + c.spec.total_span
                else
                    ptrStubLen(c.spec, c.runs) + c.spec.total_span;
            },
        };
        const dl: u32 = 28 + 12 + blocks_len + 3 + 19 + 21 + 24;
        base = patchgen.findFreeSpace(out[0..shim_carve], leaf_stubs * @as(u32, stub_template.len) + dl) orelse return;
        if (ptr_stub_len == 0) break;
        if (patchgen.findFreeSpace(out[ptr_area_start..], ptr_stub_len)) |off| {
            ptr_base = ptr_area_start + off;
            // Stubs and body copies execute in place: the allocation must
            // not straddle a 32 KiB bank boundary (PC wraps inside a bank).
            if ((ptr_base % 0x8000) + ptr_stub_len <= 0x8000) break;
        }
        dropPtr(&chosen, &n);
        if (n == 0) return;
    }
    const disp_len: u32 = 28 + 12 + blocks_len + 3 + 19 + 21 + 24;

    const disp_addr: u16 = 0x8000 + @as(u16, @intCast(base)) +
        @as(u16, @intCast(leaf_stubs * stub_template.len));
    const loop_addr: u16 = disp_addr + 28;
    const sig_addr: u16 = disp_addr + @as(u16, @intCast(28 + 12 + blocks_len + 3));
    const unm_addr: u16 = sig_addr + 19;
    const mar_addr: u16 = unm_addr + 21;
    const dp_base: u16 = if (res.stats.d_moved) 0x3000 else 0;

    // Stubs (and, for pointer routines, the SA-1's rewritten body copy)
    // plus their call-site rewrites.
    var leaf_i: u32 = 0;
    var ptr_cur: u32 = ptr_base;
    for (chosen[0..n], 0..) |*c, i| {
        const id: u8 = @intCast(i + 1);
        switch (c.kind) {
            .leaf => {
                var stub = stub_template;
                stub[stub_id_send_off] = id;
                stub[stub_id_cmp_off] = id;
                @memcpy(out[base + leaf_i * stub_template.len ..][0..stub_template.len], &stub);
                const stub_addr: u16 = 0x8000 + @as(u16, @intCast(base + leaf_i * stub_template.len));
                leaf_i += 1;
                res.stats.offload_sites += rewriteCallSites(out, usage, c.entry, 0x20, stub_addr, 0);
            },
            .ptr => {
                // The async variant carves its fence first, so the stub can
                // JSL it by the address just decided.
                if (c.is_async) {
                    const fence_file = ptr_cur;
                    const flen = emitFence(out[fence_file..], c.spec);
                    std.debug.assert(flen == fenceLen(c.spec));
                    ptr_cur += flen;
                    res.stats.async_entry = c.entry;
                    res.stats.async_fence = @as(u24, @intCast(fence_file / 0x8000)) << 16 |
                        @as(u24, @intCast(0x8000 + (fence_file % 0x8000)));
                }
                const stub_file = ptr_cur;
                const emitted = if (c.is_async)
                    emitAsyncStub(out[stub_file..], res.stats.async_fence, id, c.entry, c.spec)
                else
                    emitPtrStub(out[stub_file..], id, c.entry, c.spec, c.runs);
                std.debug.assert(emitted == if (c.is_async) asyncStubLen(c.spec) else ptrStubLen(c.spec, c.runs));
                ptr_cur += emitted;
                // The SA-1's copies of the TREE, immediately after the
                // stub — the root first, so the dispatcher's JSL lands on
                // it. In each copy the DB idiom's and the long-WRAM
                // operands' bank bytes become the shadow bank, intra-
                // member JMP targets are re-based, and member-to-member
                // JSLs are re-pointed at the copies. The ORIGINAL bodies
                // stay untouched for unseen S-CPU callers.
                const copy_file = ptr_cur;
                var member_copy: [ptr_tree_cap]u32 = undefined;
                for (c.spec.members[0..c.spec.n_members], 0..) |m, mi| {
                    member_copy[mi] = ptr_cur;
                    @memcpy(out[ptr_cur..][0..m.span], out[m.entry - 0x8000 ..][0..m.span]);
                    ptr_cur += m.span;
                }
                for (c.spec.members[0..c.spec.n_members], 0..) |m, mi| {
                    const m_file: u32 = m.entry - 0x8000;
                    for (c.spec.db_sites[0..c.spec.n_db]) |site| {
                        if (site < m_file or site - m_file >= m.span) continue;
                        std.debug.assert(out[member_copy[mi] + (site - m_file)] == 0x7E);
                        out[member_copy[mi] + (site - m_file)] = shadow_bank;
                        // Residency: the ORIGINAL body's data bank moves
                        // too, so the S-CPU's own calls — including the
                        // sibling entry points that were never re-pointed
                        // — address the one BW-RAM copy rather than a
                        // stale WRAM one. That is the whole difference
                        // between residency and marshalling: one copy,
                        // nothing to synchronise. (Idempotent: a site
                        // shared by overlapping members rewrites once.)
                        if (c.resident and out[site] == 0x7E) out[site] = shadow_bank;
                    }
                    for (c.spec.wram_long_sites[0..c.spec.n_wram_long]) |site| {
                        if (site < m_file or site - m_file >= m.span) continue;
                        out[member_copy[mi] + (site - m_file)] = shadow_bank;
                        if (c.resident and (out[site] == 0x7E or (out[site] & 0x7F) <= 0x3F))
                            out[site] = shadow_bank;
                    }
                    fixupJmps(out, usage, m.entry, m.span, member_copy[mi], @intCast(0x8000 + (member_copy[mi] % 0x8000)));
                    rebaseTreeJsls(out, usage, &c.spec, m.entry, m.span, member_copy[mi], &member_copy);
                }
                if (c.resident) res.stats.resident_offloads += 1;
                c.copy_bank = @intCast(copy_file / 0x8000);
                c.copy_addr = @intCast(0x8000 + (copy_file % 0x8000));
                res.stats.offload_copy[i] = @as(u24, c.copy_bank) << 16 | c.copy_addr;
                res.stats.offload_copy_len[i] = c.spec.total_span;
                const stub_bank: u8 = @intCast(stub_file / 0x8000);
                const stub_addr: u16 = @intCast(0x8000 + (stub_file % 0x8000));
                res.stats.offload_sites += rewriteCallSites(out, usage, c.entry, 0x22, stub_addr, stub_bank);
                res.stats.pointer_offloads += 1;
                res.stats.marshal_siblings += c.siblings;
                for (0..c.runs.n) |r| res.stats.marshal_bytes += @as(u32, c.runs.len[r]) * 256 * 2;
            },
        }
    }

    // The dispatcher, emitted around the computed addresses.
    const d = out[base + leaf_stubs * @as(u32, stub_template.len) ..];
    var cur: usize = 0;
    // Prologue: gates, the shadow window (CBM block 16 = linear $20000,
    // the $7E shadow's first 8 KiB, for pointer routines' dp), native
    // mode, stack under the mailbox, D.
    put(d, &cur, &.{ 0x78, 0xA9, 0xFF, 0x8D, 0x2A, 0x22, 0xA9, 0x80, 0x8D, 0x27, 0x22, 0xA9, 0x08, 0x8D, 0x25, 0x22, 0x18, 0xFB, 0xC2, 0x10, 0xA2, 0x78, 0x37, 0x9A, 0xF4, @truncate(dp_base), @truncate(dp_base >> 8), 0x2B });
    // loop: wait for a nonzero message, park its id at $3787.
    put(d, &cur, &.{ 0xE2, 0x20, 0xAD, 0x01, 0x23, 0x29, 0x0F, 0xF0, 0xF7, 0x8D, 0x87, 0x37 });
    for (chosen[0..n], 0..) |c, i| {
        const id: u8 = @intCast(i + 1);
        switch (c.kind) {
            // CMP #id / BNE +12 / JSR unm / JSR entry / JSR mar / JMP sig.
            .leaf => {
                put(d, &cur, &.{ 0xC9, id, 0xD0, 0x0C });
                putJsr(d, &cur, unm_addr);
                putJsr(d, &cur, c.entry);
                putJsr(d, &cur, mar_addr);
                put(d, &cur, &.{ 0x4C, @truncate(sig_addr), @truncate(sig_addr >> 8) });
            },
            // Pointer block: same shape with D swapped to $6000 around a
            // JSL of the SA-1's body copy (which returns RTL), then back
            // to the base D.
            .ptr => {
                put(d, &cur, &.{ 0xC9, id, 0xD0, 0x1D });
                // D = $6000 + the caller's own D, so every dp operand in
                // the body lands on that page's mirror in the shadow.
                // Set before the unmarshal, whose PLP restores the entry
                // widths last.
                // SEP #$20 again before the unmarshal: it assembles B:A
                // bytewise and pairs PHA with PLP, so it must run 8-bit.
                put(d, &cur, &.{ 0xC2, 0x20, 0xAD, 0x88, 0x37, 0x18, 0x69, 0x00, 0x60, 0x5B, 0xE2, 0x20 });
                putJsr(d, &cur, unm_addr);
                put(d, &cur, &.{ 0x22, @truncate(c.copy_addr), @truncate(c.copy_addr >> 8), c.copy_bank });
                put(d, &cur, &.{ 0xF4, @truncate(dp_base), @truncate(dp_base >> 8), 0x2B });
                putJsr(d, &cur, mar_addr);
                put(d, &cur, &.{ 0x4C, @truncate(sig_addr), @truncate(sig_addr >> 8) });
            },
        }
    }
    // Unknown id: back to the loop.
    put(d, &cur, &.{ 0x4C, @truncate(loop_addr), @truncate(loop_addr >> 8) });
    // sig: echo the id as the done message, await the ack, clear, loop.
    put(d, &cur, &.{ 0xAD, 0x87, 0x37, 0x8D, 0x09, 0x22, 0xAD, 0x01, 0x23, 0x29, 0x0F, 0xD0, 0xF9, 0x9C, 0x09, 0x22, 0x4C, @truncate(loop_addr), @truncate(loop_addr >> 8) });
    // unm: caller P staged, registers in, PLP last (sets the entry widths).
    put(d, &cur, &.{ 0xAD, 0x86, 0x37, 0x48, 0xAD, 0x81, 0x37, 0xEB, 0xAD, 0x80, 0x37, 0xC2, 0x10, 0xAE, 0x82, 0x37, 0xAC, 0x84, 0x37, 0x28, 0x60 });
    // mar: exit P captured first, registers out.
    put(d, &cur, &.{ 0x08, 0xC2, 0x10, 0x8E, 0x82, 0x37, 0x8C, 0x84, 0x37, 0xE2, 0x20, 0x8D, 0x80, 0x37, 0xEB, 0x8D, 0x81, 0x37, 0xEB, 0x68, 0x8D, 0x86, 0x37, 0x60 });
    std.debug.assert(cur == disp_len);

    res.stats.offloaded = chosen[0].entry;
    res.stats.offload_count = @intCast(n);
    for (chosen[0..n], 0..) |c, i| {
        res.stats.offload_entries[i] = c.entry;
        if (c.kind == .ptr) res.stats.offload_ptr_mask |= @as(u8, 1) << @intCast(i);
    }
    crv.* = disp_addr;
}

/// Highest I-RAM byte carrying LIVE relocated state (a clean region with at
/// least one rewritten site, or the moved dp window).
fn iramLive(plan: *const profile.Plan, res: *const Result) u32 {
    var live: u32 = 0;
    for (plan.regions[0..plan.n], 0..) |r, ri| {
        if (res.fate[ri] != .clean or r.dest != .iram) continue;
        if (res.region_sites[ri] == 0 and !(r.dp and res.stats.d_moved)) continue;
        live = @max(live, r.dest_off + r.len);
    }
    return live;
}

/// Highest BW-RAM byte carrying live relocated state, for the shadow guard.
fn bwramLive(plan: *const profile.Plan, res: *const Result) u32 {
    var live: u32 = 0;
    for (plan.regions[0..plan.n], 0..) |r, ri| {
        if (res.fate[ri] != .clean or r.dest != .bwram) continue;
        if (res.region_sites[ri] == 0) continue;
        live = @max(live, r.dest_off + r.len);
    }
    return live;
}

/// Does any executed instruction OUTSIDE [entry, entry+span) statically
/// name a byte of `pages` (excluding the direct page, which never becomes
/// resident)? Long and low-mirror-absolute operands are the forms that
/// name WRAM without depending on a runtime register, so they are exactly
/// the references that would break if the bytes moved to BW-RAM.
fn namedOutside(
    out: []const u8,
    usage: []const u8,
    spec: *const PtrSpec,
    pages: profile.WramPages,
    dp_page: u16,
) bool {
    var bank: u32 = 0;
    while (bank < 0x40) : (bank += 1) {
        const bank_file = bank * 0x8000;
        if (bank_file >= out.len) break;
        var a16: u32 = 0x8000;
        while (a16 < 0x10000) : (a16 += 1) {
            const cpu_addr = (bank << 16) | a16;
            const fl = usage[cpu_addr] | usage[0x80_0000 | cpu_addr];
            if (fl & usage_map.flag_opcode == 0) continue;
            // Inside the tree's own bodies: their accesses are the ones
            // the data-bank rewrite re-points.
            if (bank == 0) {
                const in_tree = for (spec.members[0..spec.n_members]) |m| {
                    if (a16 >= m.entry and a16 - m.entry < m.span) break true;
                } else false;
                if (in_tree) continue;
            }
            const file = bank_file + (a16 - 0x8000);
            if (file + 4 > out.len) continue;
            const op = out[file];
            const wram_off: u32 = switch (usage_map.mode(op)) {
                .abs, .abs_x, .abs_y => blk: {
                    const v = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                    if (v >= 0x2000) continue;
                    break :blk v;
                },
                .long, .long_x => blk: {
                    const b = out[file + 3];
                    const v = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                    if (b == 0x7E) break :blk v;
                    if (b == 0x7F) break :blk 0x10000 + @as(u32, v);
                    if ((b & 0x7F) <= 0x3F and v < 0x2000) break :blk v;
                    continue;
                },
                else => continue,
            };
            const pg: u16 = @intCast(wram_off >> 8);
            if (pg != dp_page and profile.getPage(pages, pg)) return true;
        }
    }
    return false;
}

/// Re-base intra-span JMP abs targets in a pointer routine's copy. All
/// other flow in the span is relative (branches, BRL) and relocates for
/// free; the eligibility walk refused everything else.
fn fixupJmps(out: []u8, usage: []const u8, entry: u16, span: u32, copy_file: u32, copy_addr: u16) void {
    var pc: u32 = entry;
    while (pc - entry < span) {
        if (usage[pc] & usage_map.flag_opcode == 0) {
            pc += 1;
            continue;
        }
        const file = pc - 0x8000;
        const op = out[file];
        const m8 = usage[pc] & usage_map.flag_m != 0;
        const x8 = usage[pc] & usage_map.flag_x != 0;
        if (op == 0x4C) {
            const t = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
            const rebased: u16 = copy_addr + (t - entry);
            std.mem.writeInt(u16, out[copy_file + (pc - entry) + 1 ..][0..2], rebased, .little);
        }
        pc += usage_map.instrLen(op, m8, x8);
    }
}

/// Re-point member-to-member JSLs inside one member's COPY at the other
/// members' copies. The eligibility walk proved every JSL in the span
/// targets a tree member, so this scan is exhaustive by construction.
fn rebaseTreeJsls(
    out: []u8,
    usage: []const u8,
    spec: *const PtrSpec,
    entry: u16,
    span: u32,
    copy_file: u32,
    member_copy: *const [ptr_tree_cap]u32,
) void {
    var pc: u32 = entry;
    while (pc - entry < span) {
        if (usage[pc] & usage_map.flag_opcode == 0) {
            pc += 1;
            continue;
        }
        const file = pc - 0x8000;
        const op = out[file];
        const m8 = usage[pc] & usage_map.flag_m != 0;
        const x8 = usage[pc] & usage_map.flag_x != 0;
        if (op == 0x22 and out[file + 3] == 0x00) {
            const tgt = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
            for (spec.members[0..spec.n_members], 0..) |m, mj| {
                if (m.entry != tgt) continue;
                const dst = copy_file + (pc - entry);
                std.mem.writeInt(u16, out[dst + 1 ..][0..2], @intCast(0x8000 + (member_copy[mj] % 0x8000)), .little);
                out[dst + 3] = @intCast(member_copy[mj] / 0x8000);
                break;
            }
        }
        pc += usage_map.instrLen(op, m8, x8);
    }
}

fn dropPtr(chosen: *[offload_max]Chosen, n: *usize) void {
    var w: usize = 0;
    for (chosen[0..n.*]) |c| {
        if (c.kind == .leaf) {
            chosen[w] = c;
            w += 1;
        }
    }
    n.* = w;
}

fn put(d: []u8, cur: *usize, bytes: []const u8) void {
    @memcpy(d[cur.*..][0..bytes.len], bytes);
    cur.* += bytes.len;
}

fn putJsr(d: []u8, cur: *usize, target: u16) void {
    put(d, cur, &.{ 0x20, @truncate(target), @truncate(target >> 8) });
}

/// Count executed call sites of `entry` (bank $00): `op` is 0x20 (JSR,
/// scanned in bank $00 — a JSR's target shares the caller's bank) or 0x22
/// (JSL with an explicit bank-$00 target, scanned across every bank,
/// executed flags merged over the $80+ fast mirrors).
fn countCallSites(out: []const u8, usage: []const u8, entry: u16, op: u8) u32 {
    return callSites(out, null, usage, entry, op, 0, 0);
}

/// Re-point every executed call site of `entry` at the stub. JSR sites take
/// a 16-bit target (stub in bank $00); JSL sites take the full 24-bit stub
/// address. Returns the number rewritten.
fn rewriteCallSites(out: []u8, usage: []const u8, entry: u16, op: u8, stub_addr: u16, stub_bank: u8) u32 {
    return callSites(out, out, usage, entry, op, stub_addr, stub_bank);
}

fn callSites(ro: []const u8, rw: ?[]u8, usage: []const u8, entry: u16, op: u8, stub_addr: u16, stub_bank: u8) u32 {
    var count: u32 = 0;
    const bank_top: u32 = if (op == 0x20) 1 else 0x40;
    var bank: u32 = 0;
    while (bank < bank_top) : (bank += 1) {
        const bank_file = bank * 0x8000;
        if (bank_file >= ro.len) break;
        var a16: u32 = 0x8000;
        while (a16 < 0x10000) : (a16 += 1) {
            const cpu_addr = (bank << 16) | a16;
            if ((usage[cpu_addr] | usage[0x80_0000 | cpu_addr]) & usage_map.flag_opcode == 0) continue;
            const file = bank_file + (a16 - 0x8000);
            if (ro[file] != op) continue;
            if (std.mem.readInt(u16, ro[file + 1 ..][0..2], .little) != entry) continue;
            if (op == 0x22 and ro[file + 3] != 0x00) continue;
            if (rw) |w| {
                std.mem.writeInt(u16, w[file + 1 ..][0..2], stub_addr, .little);
                if (op == 0x22) w[file + 3] = stub_bank;
            }
            count += 1;
        }
    }
    return count;
}

/// Static pointer-eligibility walk: a JSL/RTL routine whose data flows
/// through dp cells and runtime pointers, offloadable as COMPUTE against
/// the BW-RAM shadow of its profiled working set. The walk proves what it
/// can (return shape, span containment, no MMIO/stack-relative sites, the
/// DB idiom, the long-pointer bank slots); the pointer VALUES are dynamic
/// evidence — anything they reach outside the marshalled shadow diverges
/// in S4 verification and no patch ships. Refusal here is a skip, not an
/// error: the routine simply stays on the S-CPU.
///
/// The walk covers a CALL TREE: a JSL to a bank-$00 target makes that
/// target a member, walked by the same rules and copied alongside the
/// root. Absolute (DB-relative) operands are allowed while the data bank
/// is PINNED by an immediate LDA #bank / PHA / PLB — tracked linearly,
/// which matches the idiom's real use (pin once up front, restore at the
/// end); a backward branch across a re-pin is dynamic evidence like the
/// rest. Long WRAM operands are recorded as bank-byte rewrite sites: the
/// shadow is identity-offset, so only the bank byte changes in the copy.
fn eligiblePointer(out: []const u8, usage: []const u8, entry: u16) ?PtrSpec {
    var spec: PtrSpec = .{};
    var has_idp = false;
    spec.members[0] = .{ .entry = entry, .span = 0, .pin = null, .conflict = false };
    spec.n_members = 1;
    var walked: usize = 0;
    while (walked < spec.n_members) : (walked += 1) {
        if (!walkMember(out, usage, &spec, walked, &has_idp)) {
            if (dbg_walk_root != 0 and entry == dbg_walk_root)
                std.debug.print("[walk] root {x:0>4}: member {} (${x:0>4}) refused\n", .{ entry, walked, spec.members[walked].entry });
            return null;
        }
    }
    // A member validated under an inherited pin that a LATER call site
    // contradicts was validated on a false premise.
    for (spec.members[0..spec.n_members]) |m| if (m.conflict) return null;
    if (has_idp and spec.n_db == 0) return null;
    spec.span = spec.members[0].span;
    spec.total_span = 0;
    for (spec.members[0..spec.n_members]) |m| spec.total_span += m.span;
    if (spec.total_span > ptr_tree_span_max) return null;
    // Helper privacy (an ASYNC-only requirement, recorded for the gate):
    // every executed JSL site of every helper lies inside the tree.
    for (spec.members[1..spec.n_members]) |m| {
        if (!jslSitesInsideTree(out, usage, &spec, m.entry)) {
            spec.helpers_private = false;
            break;
        }
    }
    return spec;
}

/// Walk diagnostics: set to a root entry to print why the offload gates
/// skip it (walk refusal per member, residency's shared/DMA page, the
/// marshal economics). Zero compiles every print away.
const dbg_walk_root: u16 = 0;

fn walkMember(out: []const u8, usage: []const u8, spec: *PtrSpec, mi: usize, has_idp: *bool) bool {
    const span_max: u32 = 1024;
    const entry: u32 = spec.members[mi].entry;
    const dbg = dbg_walk_root != 0 and spec.members[0].entry == dbg_walk_root;
    var pc: u32 = entry;
    var limit: u32 = entry;
    // The pinned data bank, if an LDA #imm / PHA / PLB executed and no
    // later PLB unpinned it. Tracked linearly. A helper starts with the
    // pin it INHERITS from its tree call sites (see PtrSpec.members).
    var db_pin: ?u8 = spec.members[mi].pin;
    while (pc - entry < span_max) {
        if (pc > 0xFFFF) return false;
        if (usage[pc] & usage_map.flag_opcode == 0) {
            // A gap (data or never-taken padding) is fine while pending
            // flow still reaches past it; a gap at the frontier is not.
            if (pc >= limit) return false;
            pc += 1;
            continue;
        }
        const file = pc - 0x8000;
        const op = out[file];
        const m8 = usage[pc] & usage_map.flag_m != 0;
        const x8 = usage[pc] & usage_map.flag_x != 0;
        const len = usage_map.instrLen(op, m8, x8);
        if (dbg) std.debug.print("  [walk] {x:0>4}: {x:0>2} pin={?x}\n", .{ pc, op, db_pin });
        switch (op) {
            0x6B => { // RTL: done once every pending path has closed
                if (pc >= limit) {
                    spec.members[mi].span = pc + 1 - entry;
                    return true;
                }
            },
            0x22 => { // JSL: a bank-$00 target joins the tree
                if (out[file + 3] != 0x00) return false;
                const tgt = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                if (tgt < 0x8000) return false;
                const existing: ?usize = for (spec.members[0..spec.n_members], 0..) |m, j| {
                    if (m.entry == tgt) break j;
                } else null;
                if (existing) |j| {
                    // A second call site with a different pin invalidates
                    // whatever the member's walk assumed.
                    if (!std.meta.eql(spec.members[j].pin, db_pin)) spec.members[j].conflict = true;
                } else {
                    if (spec.n_members == ptr_tree_cap) return false;
                    spec.members[spec.n_members] = .{ .entry = tgt, .span = 0, .pin = db_pin, .conflict = false };
                    spec.n_members += 1;
                }
            },
            // Wrong return shape, near calls, far jumps, block moves,
            // interrupt-adjacent, D/S relocation: not this routine.
            0x60, 0x40, 0x20, 0xFC, 0x5C, 0x6C, 0x7C, 0xDC => return false,
            0x00, 0x02, 0xCB, 0xDB, 0x44, 0x54 => return false,
            0x2B, 0x5B, 0x1B, 0x9A, 0xFB, 0x58 => return false,
            0x4C, 0x82, 0x80 => { // JMP abs / BRL / BRA: intra-member only
                const dst: u32 = switch (op) {
                    0x4C => std.mem.readInt(u16, out[file + 1 ..][0..2], .little),
                    0x82 => pc + 3 +% @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(std.mem.readInt(u16, out[file + 1 ..][0..2], .little)))))),
                    else => pc + 2 +% @as(u32, @bitCast(@as(i32, @as(i8, @bitCast(out[file + 1]))))),
                };
                if (dst < entry or dst - entry >= span_max) return false;
                limit = @max(limit, dst);
                // An unconditional BACKWARD transfer at the frontier
                // closes the member like an RTL: no pending path reaches
                // past it, and the loop it forms stays inside the span.
                if (dst <= pc and pc >= limit) {
                    spec.members[mi].span = pc + len - entry;
                    return true;
                }
            },
            0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0 => {
                const dst = pc + 2 +% @as(u32, @bitCast(@as(i32, @as(i8, @bitCast(out[file + 1])))));
                if (dst < entry or dst - entry >= span_max) return false;
                limit = @max(limit, dst);
            },
            0xA9 => if (m8) {
                const imm = out[file + 1];
                if (file + 3 < out.len and out[file + 2] == 0x48 and out[file + 3] == 0xAB) {
                    // LDA #imm / PHA / PLB pins the data bank. #$7E is
                    // the shadow's rewrite point and gets recorded; any
                    // other immediate is a pin the walk merely tracks.
                    db_pin = imm;
                    if (imm == 0x7E) {
                        // Overlapping members walk shared tails twice;
                        // record each site once.
                        const dup = for (spec.db_sites[0..spec.n_db]) |s| {
                            if (s == file + 1) break true;
                        } else false;
                        if (!dup) {
                            if (spec.n_db == ptr_db_cap) return false;
                            spec.db_sites[spec.n_db] = file + 1;
                            spec.n_db += 1;
                        }
                    }
                } else if (imm == 0x7E) {
                    // A bare #$7E has an unknowable purpose — refuse.
                    return false;
                }
            },
            0xAB => {
                // A PLB outside the idiom restores a pushed bank the walk
                // cannot see: unpinned from here on.
                if (file < 3 or out[file - 3] != 0xA9 or out[file - 1] != 0x48) db_pin = null;
            },
            else => {},
        }
        // Long-indirect pointers ([dp] / [dp],y, the $x7 column): the bank
        // byte at dp+2 is a translation slot ($7E/$7F -> shadow).
        if (op & 0x0F == 0x07) {
            const slot: u16 = @as(u16, out[file + 1]) + 2;
            if (slot > 0xFF) return false; // bank byte past the dp window
            const dup = for (spec.slots[0..spec.n_slots]) |s| {
                if (s == slot) break true;
            } else false;
            if (!dup) {
                if (spec.n_slots == ptr_slot_cap) return false;
                spec.slots[spec.n_slots] = @intCast(slot);
                spec.n_slots += 1;
            }
        }
        // 16-bit-indirect pointers ((dp) / (dp),y) resolve with DB: only
        // sound once the DB idiom pins it to the shadow. (dp,x) hides the
        // pointer cell behind a runtime index; stack-relative reads the
        // S-CPU stack the SA-1 does not have.
        if (op & 0x1F == 0x11 or op & 0x1F == 0x12) has_idp.* = true;
        if (op & 0x1F == 0x01 or op & 0x0F == 0x03) return false;
        switch (usage_map.mode(op)) {
            .none, .dp => {},
            // dp,X/dp,Y: a runtime index that can leave the shadow's dp
            // window (8 KiB under D=$6000). Statically unprovable — but
            // the pointer path runs on dynamic evidence: an index that
            // actually left the marshalled shadow reads ROM instead of
            // state, diverges in S4 verification, and no patch ships.
            .dp_idx => {},
            // DB-relative: allowed exactly while the idiom pins the bank.
            // Pinned $7E is WRAM top to bottom — the rewritten idiom
            // re-points every one of these at the shadow. A pinned ROM
            // bank reads identically on both CPUs above $8000; below it
            // the banks diverge (S-CPU mirrors, SA-1 I-RAM), so refuse.
            .abs, .abs_x, .abs_y => {
                const b = db_pin orelse return false;
                if (b == 0x7E) {
                    // follows the rewritten DB into the shadow
                } else if ((b <= 0x3F or (b >= 0x80 and b != 0x7F)) and
                    std.mem.readInt(u16, out[file + 1 ..][0..2], .little) >= 0x8000)
                {
                    // ROM through a pinned bank: same bytes on both CPUs
                } else return false;
            },
            .long, .long_x => {
                const b = out[file + 3];
                const a16 = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                // ROM and BW-RAM read identically on the SA-1. Long WRAM
                // becomes a bank-byte rewrite to the identity-offset
                // shadow: $7E:xxxx directly, and a $00-$3F bank's low 8K
                // is the same bytes through the mirror. $7F and MMIO
                // cannot follow execution across.
                if (b == 0x7E or ((b & 0x7F) <= 0x3F and a16 < 0x2000 and usage_map.mode(op) == .long)) {
                    // The system-bank low-mirror form only counts when
                    // UNINDEXED: with an index the same base can walk a
                    // ROM table ($01:0000,X in Gradius III's sound code),
                    // and re-banking it would read the wrong ROM. $7E is
                    // unambiguous either way.
                    const dup = for (spec.wram_long_sites[0..spec.n_wram_long]) |s| {
                        if (s == file + 3) break true;
                    } else false;
                    if (!dup) {
                        if (spec.n_wram_long == ptr_wram_long_cap) return false;
                        spec.wram_long_sites[spec.n_wram_long] = file + 3;
                        spec.n_wram_long += 1;
                    }
                } else if ((b >= 0x40 and b <= 0x4F) or b >= 0xC0 or
                    ((b & 0x7F) <= 0x3F and a16 >= 0x8000))
                {
                    // ROM / BW-RAM: fine as-is
                } else return false;
            },
        }
        pc += len;
    }
    return false;
}

/// Are all executed JSL call sites of `entry` inside the tree's spans?
fn jslSitesInsideTree(out: []const u8, usage: []const u8, spec: *const PtrSpec, entry: u16) bool {
    var bank: u32 = 0;
    while (bank < 0x40) : (bank += 1) {
        const bank_file = bank * 0x8000;
        if (bank_file >= out.len) break;
        var a16: u32 = 0x8000;
        while (a16 < 0x10000) : (a16 += 1) {
            const cpu_addr = (bank << 16) | a16;
            if ((usage[cpu_addr] | usage[0x80_0000 | cpu_addr]) & usage_map.flag_opcode == 0) continue;
            const file = bank_file + (a16 - 0x8000);
            if (out[file] != 0x22) continue;
            if (std.mem.readInt(u16, out[file + 1 ..][0..2], .little) != entry) continue;
            if (out[file + 3] != 0x00) continue;
            const inside = bank == 0 and for (spec.members[0..spec.n_members]) |m| {
                if (a16 >= m.entry and a16 - m.entry < m.span) break true;
            } else false;
            if (!inside) return false;
        }
    }
    return true;
}

/// Byte-exact length of a pointer stub (the emitter asserts against it).
fn ptrStubLen(spec: PtrSpec, runs: Runs) u32 {
    return 151 + 24 * @as(u32, @intCast(runs.n)) + 54 * @as(u32, @intCast(spec.n_slots));
}

/// The S-CPU side of a pointer offload, emitted per routine. Everything is
/// long-addressed (mailbox, message ports, shadow) so the stub is correct
/// under ANY caller data bank and may itself live in any ROM bank — which
/// is also why JSL sites can reach it with a 24-bit rewrite. Sequence:
/// marshal registers -> copy the working set into the shadow (MVN) ->
/// translate the long-pointer bank slots ($7E/$7F -> $42/$43) -> send the
/// message id and spin the double handshake -> translate back -> copy the
/// shadow back -> restore DB -> unmarshal with the routine's exit state ->
/// RTL.
fn emitPtrStub(d: []u8, id: u8, entry: u16, spec: PtrSpec, runs: Runs) u32 {
    var cur: usize = 0;
    // Precondition, checked rather than assumed: the marshal mirrors the
    // caller's direct page at WRAM $0000-$00FF into the shadow, and the
    // SA-1 runs the body with D over that mirror. A caller whose D is
    // something else would have the SA-1 resolve dp operands to the wrong
    // shadow bytes, so this hands such a call straight back to the
    // ORIGINAL routine on the S-CPU — always correct, merely not
    // accelerated. (JML, not JSL: the original's own RTL returns to our
    // caller.)
    put(d, &cur, &.{
        0x08, // PHP
        0xC2, 0x20, // REP #$20
        0x48, // PHA
        0x0B, 0x68, // PHD / PLA  -> A = caller D
        0xC9, 0x01, 0x1F, // CMP #$1F01
        0x90, 0x06, // BCC ok  (a whole dp page fits the 8 KiB window)
        0x68, 0x28, // PLA / PLP  (restore exactly what we found)
        0x5C, @truncate(entry), @truncate(entry >> 8), 0x00, // JML original
        // ok:
        0x8F, 0x88, 0x37, 0x00, // STA $00:3788 — caller D into the mailbox
        0x68, 0x28, // PLA / PLP
    });
    // Register marshal in (33). PHB first so the caller P (pushed second)
    // is on top for the PLA below.
    put(d, &cur, &.{ 0x8B, 0x08, 0xE2, 0x20 }); // PHB / PHP / SEP #$20
    put(d, &cur, &.{ 0x8F, 0x80, 0x37, 0x00, 0xEB, 0x8F, 0x81, 0x37, 0x00, 0xEB }); // A low, B
    put(d, &cur, &.{ 0xC2, 0x30, 0x8A, 0x8F, 0x82, 0x37, 0x00, 0x98, 0x8F, 0x84, 0x37, 0x00 }); // X, Y via A
    put(d, &cur, &.{ 0xE2, 0x20, 0x68, 0x8F, 0x86, 0x37, 0x00 }); // caller P
    // Shadow copy-in (2 + 12/run). MVN encoding: opcode, DEST bank, SRC bank.
    put(d, &cur, &.{ 0xC2, 0x30 });
    // The caller's direct page, wherever it is: MVN takes its offsets
    // from X/Y, so one emitted copy serves every D the guard admits.
    put(d, &cur, &.{ 0xAF, 0x88, 0x37, 0x00, 0xAA, 0xA8, 0xA9, 0xFF, 0x00, 0x54, shadow_bank, 0x7E });
    for (0..runs.n) |r| putMvnRun(d, &cur, runs.start[r], runs.len[r], false);
    // Slot translate-in: $7E pointer bank bytes -> the shadow bank. The
    // slots are DIRECT-PAGE offsets, so each is indexed by the caller's
    // own D — the pointers live wherever its direct page is, not at
    // $0000. (A plain LoROM game has no $40+ pointers to collide with
    // the exact compare; $7F pointers stay untranslated and fail S4 if
    // followed.)
    for (spec.slots[0..spec.n_slots]) |s| {
        put(d, &cur, &.{
            0xAF, 0x88, 0x37, 0x00, // LDA $00:3788  (caller D)
            0x18, 0x69, s, 0x00, // CLC / ADC #slot
            0xAA, // TAX
            0xE2, 0x20, // SEP #$20
            0xBF, 0x00, 0x00, shadow_bank, // LDA $41:0000,x
            0xC9, 0x7E, // CMP #$7E
            0xD0, 0x06, // BNE skip
            0xA9, shadow_bank, // LDA #$41
            0x9F, 0x00, 0x00, shadow_bank, // STA $41:0000,x
            0xC2, 0x20, // skip: REP #$20
        });
    }
    put(d, &cur, &.{ 0xE2, 0x20 });
    // Send + double handshake (30), all long-addressed.
    put(d, &cur, &.{ 0xA9, id, 0x8F, 0x00, 0x22, 0x00 }); // message id -> CFR
    put(d, &cur, &.{ 0xAF, 0x00, 0x23, 0x00, 0x29, 0x0F, 0xC9, id, 0xD0, 0xF6 }); // await echo
    put(d, &cur, &.{ 0xA9, 0x00, 0x8F, 0x00, 0x22, 0x00 }); // ack
    put(d, &cur, &.{ 0xAF, 0x00, 0x23, 0x00, 0x29, 0x0F, 0xD0, 0xF8 }); // await clear
    // Slot translate-back, indexed the same way.
    put(d, &cur, &.{ 0xC2, 0x20 });
    for (spec.slots[0..spec.n_slots]) |s| {
        put(d, &cur, &.{
            0xAF,        0x88, 0x37,        0x00,
            0x18,        0x69, s,           0x00,
            0xAA,        0xE2, 0x20,        0xBF,
            0x00,        0x00, shadow_bank, 0xC9,
            shadow_bank, 0xD0, 0x06,        0xA9,
            0x7E,        0x9F, 0x00,        0x00,
            shadow_bank, 0xC2, 0x20,
        });
    }
    put(d, &cur, &.{ 0xE2, 0x20 });
    // Shadow copy-out (2 + 12/run).
    put(d, &cur, &.{ 0xC2, 0x30 });
    put(d, &cur, &.{ 0xAF, 0x88, 0x37, 0x00, 0xAA, 0xA8, 0xA9, 0xFF, 0x00, 0x54, 0x7E, shadow_bank });
    for (0..runs.n) |r| putMvnRun(d, &cur, runs.start[r], runs.len[r], true);
    // Restore caller DB, then unmarshal — long-addressed, so DB-proof (30).
    put(d, &cur, &.{0xAB}); // PLB
    put(d, &cur, &.{ 0xC2, 0x30, 0xAF, 0x82, 0x37, 0x00, 0xAA, 0xAF, 0x84, 0x37, 0x00, 0xA8 }); // X, Y
    put(d, &cur, &.{ 0xE2, 0x20, 0xAF, 0x86, 0x37, 0x00, 0x48 }); // exit P staged
    put(d, &cur, &.{ 0xAF, 0x81, 0x37, 0x00, 0xEB, 0xAF, 0x80, 0x37, 0x00 }); // B, A low
    put(d, &cur, &.{ 0x28, 0x6B }); // PLP (exit flags/widths) / RTL
    return @intCast(cur);
}

/// Byte-exact length of the shared async fence (the emitter asserts).
fn fenceLen(spec: PtrSpec) u32 {
    _ = spec;
    return 41;
}

/// The asynchronous offload's fence: complete the handshake of a
/// fire-and-forget call so the mailbox and message ports free up. Nothing
/// is copied back — that is the async CONTRACT, not a shortcut: the
/// routine's register results are dropped, and so are its direct-page
/// writes. A deferred whole-page copy-back is unsound against ANY S-CPU
/// dp write between send and fence (measured on a real cart: the NMI
/// fence reverting the APU upload counter mid-handshake wedged the boot).
/// Only effects on BW-RAM-RESIDENT state survive an async call, because
/// both CPUs address that state directly and no copy exists to disagree.
/// Whether any caller needed the dropped effects is exactly what
/// behavioral verification arbitrates.
///
/// JSL-reached and long-addressed, so it works from any bank; the caller
/// has already saved every register it cares about. Idempotent: an NMI
/// can interrupt a fence mid-handshake and run the fence again — the
/// inner call either sees busy already cleared or completes the same
/// handshake, and the outer's remaining reads find the ports quiet.
fn emitFence(d: []u8, spec: PtrSpec) u32 {
    _ = spec;
    var cur: usize = 0;
    const body: u32 = 32;
    put(d, &cur, &.{ 0xE2, 0x20 }); // SEP #$20
    put(d, &cur, &.{ 0xAF, 0x8A, 0x37, 0x00 }); // busy id, 0 = idle
    put(d, &cur, &.{ 0xF0, @intCast(body) }); // BEQ done
    // Await the SA-1's done echo of exactly the in-flight id, ack it, and
    // wait for the port to clear — the back half of the handshake the
    // async stub deliberately left unfinished.
    put(d, &cur, &.{ 0xAF, 0x00, 0x23, 0x00, 0x29, 0x0F, 0xCF, 0x8A, 0x37, 0x00, 0xD0, 0xF4 });
    put(d, &cur, &.{ 0xA9, 0x00, 0x8F, 0x00, 0x22, 0x00 });
    put(d, &cur, &.{ 0xAF, 0x00, 0x23, 0x00, 0x29, 0x0F, 0xD0, 0xF8 });
    put(d, &cur, &.{ 0xA9, 0x00, 0x8F, 0x8A, 0x37, 0x00 }); // busy = idle
    put(d, &cur, &.{0x6B}); // done: RTL
    return @intCast(cur);
}

/// The NON-BLOCKING fence, for the NMI prologue. The blocking fence in
/// the NMI moved every in-flight wait into vblank — the one place a
/// wait costs a frame deadline — and the async flavor measured 290
/// dropped frames against sync's 115 doing exactly that. This variant
/// acks a COMPLETED call (the SA-1 answers from its sig-hold loop
/// within microseconds) and SKIPS a still-running one; the next fence
/// point collects it. Only the async stub's own fence must block — it
/// is about to reuse the mailbox.
const nb_fence_len: u32 = 39;
fn emitNbFence(d: []u8) u32 {
    var cur: usize = 0;
    put(d, &cur, &.{ 0xE2, 0x20 }); // SEP #$20
    put(d, &cur, &.{ 0xAF, 0x8A, 0x37, 0x00 }); // busy id, 0 = idle
    put(d, &cur, &.{ 0xF0, 0x1E }); // BEQ done
    put(d, &cur, &.{ 0xAF, 0x00, 0x23, 0x00, 0x29, 0x0F }); // done echo?
    put(d, &cur, &.{ 0xCF, 0x8A, 0x37, 0x00 });
    put(d, &cur, &.{ 0xD0, 0x12 }); // BNE done — still running, skip
    put(d, &cur, &.{ 0xA9, 0x00, 0x8F, 0x00, 0x22, 0x00 }); // ack
    put(d, &cur, &.{ 0xAF, 0x00, 0x23, 0x00, 0x29, 0x0F, 0xD0, 0xF8 }); // echo clears (bounded: the SA-1 is in its hold loop)
    put(d, &cur, &.{ 0x8F, 0x8A, 0x37, 0x00 }); // busy = idle (A is 0)
    put(d, &cur, &.{0x6B}); // done: RTL
    return @intCast(cur);
}

/// Byte-exact length of an async stub (the emitter asserts).
fn asyncStubLen(spec: PtrSpec) u32 {
    return 122 + 27 * @as(u32, @intCast(spec.n_slots));
}

/// The fire-and-forget S-CPU stub for THE async offload: fence first (a
/// previous call may still be in flight — and the D-guard's bail path runs
/// the original body on the S-CPU, which must never race the SA-1 over the
/// resident data), then the synchronous stub's whole front half, then send
/// the message, mark busy, and return with the CALLER's registers — the
/// routine's register results are dropped, which is the async contract;
/// verification arbitrates whether any caller actually needed them.
fn emitAsyncStub(d: []u8, fence: u24, id: u8, entry: u16, spec: PtrSpec) u32 {
    var cur: usize = 0;
    // Save the caller's context across the fence, which clobbers freely.
    put(d, &cur, &.{ 0x08, 0xC2, 0x30, 0x48, 0xDA, 0x5A, 0x8B }); // PHP REP PHA PHX PHY PHB
    put(d, &cur, &.{ 0x22, @truncate(fence), @truncate(fence >> 8), @truncate(fence >> 16) });
    // REP #$30 before the pulls: the fence returns with M narrowed (its
    // final SEP #$20), and an 8-bit PLA against the 16-bit PHA above
    // leaves a stray byte that shears the stack — the RTL at the tail
    // would return into hyperspace.
    put(d, &cur, &.{ 0xAB, 0xC2, 0x30, 0x7A, 0xFA, 0x68, 0x28 }); // PLB REP PLY PLX PLA PLP
    // Re-save what the marshal below consumes (its own PHB balances the
    // tail's PLB).
    put(d, &cur, &.{ 0x08, 0xC2, 0x30, 0x48, 0xDA, 0x5A }); // PHP REP PHA PHX PHY
    // D guard, exactly as the sync stub: a caller whose direct page cannot
    // mirror into the shadow window is handed the original body — safe on
    // the S-CPU now, because the fence above drained the SA-1.
    put(d, &cur, &.{
        0x08, 0xC2, 0x20, 0x48, 0x0B, 0x68,
        0xC9, 0x01, 0x1F, // CMP #$1F01
        0x90, 0x0C, // BCC ok
        0x68, 0x28, // PLA / PLP
        0xC2, 0x30, 0x7A, 0xFA, 0x68, 0x28, // unwind the re-save
        0x5C, @truncate(entry), @truncate(entry >> 8), 0x00, // JML original
        // ok:
        0x8F, 0x88, 0x37, 0x00, // caller D -> mailbox
        0x68, 0x28, // PLA / PLP
    });
    // Register marshal into the mailbox (the SA-1's unmarshal input),
    // identical to the sync stub's.
    put(d, &cur, &.{ 0x8B, 0x08, 0xE2, 0x20 });
    put(d, &cur, &.{ 0x8F, 0x80, 0x37, 0x00, 0xEB, 0x8F, 0x81, 0x37, 0x00, 0xEB });
    put(d, &cur, &.{ 0xC2, 0x30, 0x8A, 0x8F, 0x82, 0x37, 0x00, 0x98, 0x8F, 0x84, 0x37, 0x00 });
    // Caller P: NOT the live P (the re-save REP'd it — the sync stub can
    // read its own PHP because nothing widened P before its marshal). The
    // true caller P is the re-save's PHP byte, at a fixed stack depth
    // once our own PHP is pulled: B(1) + Y(2) + X(2) + A(2) above it.
    // Marshalling the REP'd P hands the SA-1 16-bit index width for an
    // 8-bit caller — its immediates then swallow the following opcode.
    put(d, &cur, &.{ 0xE2, 0x20, 0x68, 0xA3, 0x08, 0x8F, 0x86, 0x37, 0x00 });
    // dp page into the shadow (resident routines marshal nothing else).
    put(d, &cur, &.{ 0xC2, 0x30 });
    put(d, &cur, &.{ 0xAF, 0x88, 0x37, 0x00, 0xAA, 0xA8, 0xA9, 0xFF, 0x00, 0x54, shadow_bank, 0x7E });
    // Slot translate-in, as sync.
    for (spec.slots[0..spec.n_slots]) |s| {
        put(d, &cur, &.{
            0xAF,        0x88, 0x37,        0x00,
            0x18,        0x69, s,           0x00,
            0xAA,        0xE2, 0x20,        0xBF,
            0x00,        0x00, shadow_bank, 0xC9,
            0x7E,        0xD0, 0x06,        0xA9,
            shadow_bank, 0x9F, 0x00,        0x00,
            shadow_bank, 0xC2, 0x20,
        });
    }
    put(d, &cur, &.{ 0xE2, 0x20 });
    // Send, mark busy, and DO NOT WAIT — the SA-1's signal loop holds the
    // done echo until the fence acks it. The busy flag lives at $378A,
    // OUTSIDE the caller-D slot ($3788-$3789, which the dispatcher reads
    // 16-bit): a busy byte at $3789 is a +$0100 bias on the SA-1's D.
    put(d, &cur, &.{ 0xA9, id, 0x8F, 0x00, 0x22, 0x00, 0x8F, 0x8A, 0x37, 0x00 });
    // Caller context back (mirrors the re-save; the marshal's PHB pairs
    // with this PLB), and out.
    put(d, &cur, &.{ 0xAB, 0xC2, 0x30, 0x7A, 0xFA, 0x68, 0x28, 0x6B });
    return @intCast(cur);
}

/// One MVN marshal run: pages [start, start+len) of $7E WRAM to/from the
/// identity-offset shadow at bank $41. `back` copies shadow -> WRAM.
fn putMvnRun(d: []u8, cur: *usize, start_page: u16, n_pages: u16, back: bool) void {
    const off: u16 = (start_page & 0xFF) << 8;
    const count: u16 = n_pages * 256 - 1;
    const dst: u8 = if (back) 0x7E else shadow_bank;
    const src: u8 = if (back) shadow_bank else 0x7E;
    put(d, cur, &.{ 0xA2, @truncate(off), @truncate(off >> 8) }); // LDX #off (source)
    put(d, cur, &.{ 0xA0, @truncate(off), @truncate(off >> 8) }); // LDY #off (dest, identity)
    put(d, cur, &.{ 0xA9, @truncate(count), @truncate(count >> 8) }); // LDA #count-1
    put(d, cur, &.{ 0x54, dst, src }); // MVN
}

/// Static leaf-eligibility walk from `entry` over covered code: ends at the
/// first RTS; refuses calls, jumps, block moves, interrupts-adjacent opcodes,
/// any data access the SA-1 could not see after the relocation, and branches
/// escaping the span. Returns true when the routine can run on the SA-1.
fn eligibleLeaf(out: []const u8, usage: []const u8, plan: *const profile.Plan, res: *const Result, entry: u16) bool {
    const span_max: u32 = 512;
    var pc: u32 = entry;
    var max_branch: u32 = 0;
    while (pc - entry < span_max) {
        if (pc < 0x8000 or pc > 0xFFFF) return false;
        if (usage[pc] & usage_map.flag_opcode == 0) return false; // uncovered
        const file = pc - 0x8000;
        const op = out[file];
        const m8 = usage[pc] & usage_map.flag_m != 0;
        const x8 = usage[pc] & usage_map.flag_x != 0;
        const len = usage_map.instrLen(op, m8, x8);
        switch (op) {
            0x60 => return max_branch <= pc, // RTS: every branch stayed inside
            // Calls, jumps, returns-of-other-kinds, block moves, BRK/COP,
            // WAI/STP, and RTI end the leaf dream.
            0x20, 0x22, 0xFC, 0x4C, 0x5C, 0x6C, 0x7C, 0xDC, 0x6B, 0x40, 0x00, 0x02, 0xCB, 0xDB, 0x44, 0x54 => return false,
            // Branches must land inside the span.
            0x10, 0x30, 0x50, 0x70, 0x80, 0x90, 0xB0, 0xD0, 0xF0 => {
                const dst = pc + 2 +% @as(u32, @bitCast(@as(i32, @as(i8, @bitCast(out[file + 1])))));
                if (dst < entry or dst - entry >= span_max) return false;
                max_branch = @max(max_branch, dst);
            },
            0x82 => return false, // BRL: cheap to allow later, refuse now
            else => {},
        }
        switch (usage_map.mode(op)) {
            .none => {},
            .dp => {
                // Allowed only inside a moved dp window (D=$3000 on both
                // CPUs); anything else is unmoved WRAM the SA-1 cannot see.
                const v: u32 = out[file + 1];
                if (!dpMoved(plan, res, v)) return false;
            },
            .dp_idx, .abs_x, .abs_y, .long_x => return false,
            .abs => {
                const v = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                if (v < 0x3000 or v > 0x37FF) return false; // only the I-RAM window is DB-proof
            },
            .long => {
                const b = out[file + 3];
                const v = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                const ok = (b >= 0x40 and b <= 0x4F) or // BW-RAM
                    (b <= 0x3F and v >= 0x8000) or (b >= 0xC0) or // ROM
                    (b <= 0x3F and v >= 0x3000 and v <= 0x37FF); // I-RAM
                if (!ok) return false;
            },
        }
        pc += len;
    }
    return false;
}

fn dpMoved(plan: *const profile.Plan, res: *const Result, off: u32) bool {
    for (plan.regions[0..plan.n], 0..) |r, ri| {
        if (r.dp and res.fate[ri] == .clean and off >= r.start and off < r.start + r.len)
            return true;
    }
    return false;
}

/// The S-CPU side of the handshake: marshal registers into the mailbox, send
/// message 1, spin on SFR until the SA-1 answers, ack, unmarshal, return
/// with the routine's exit flags. Mode-safe: A is saved bytewise via XBA (so
/// B survives), X/Y under REP #$10 (16-bit in native mode, benignly 8-bit in
/// emulation mode where the index high bytes are dead anyway, and the pushed
/// P carries M=X=1 so the SA-1 runs the routine 8-bit to match).
const stub_template = [_]u8{
    0x08, // 0  PHP (caller P)
    0xE2, 0x20, // 1  SEP #$20
    0x8D, 0x80, 0x37, // 3  STA $3780 (A low)
    0xEB, // 6  XBA
    0x8D, 0x81, 0x37, // 7  STA $3781 (B)
    0xEB, // 10 XBA
    0xC2, 0x10, // 11 REP #$10
    0x8E, 0x82, 0x37, // 13 STX $3782
    0x8C, 0x84, 0x37, // 16 STY $3784
    0x68, // 19 PLA (caller P; A is 8-bit)
    0x8D, 0x86, 0x37, // 20 STA $3786
    0xA9, 0x01, // 23 LDA #$01
    0x8D, 0x00, 0x22, // 25 STA $2200 (message 1 -> SA-1 CFR)
    0xAD, 0x00, 0x23, // 28 w1: LDA $2300 (SFR)
    0x29, 0x0F, // 31 AND #$0F
    0xC9, 0x01, // 33 CMP #$01
    0xD0, 0xF7, // 35 BNE w1
    0x9C, 0x00, 0x22, // 37 STZ $2200 (ack)
    0xAD, 0x00, 0x23, // 40 w2: LDA $2300
    0x29, 0x0F, // 43 AND #$0F
    0xD0, 0xF9, // 45 BNE w2 (SA-1 cleared done: safe to re-call)
    0xC2, 0x10, // 47 REP #$10
    0xAE, 0x82, 0x37, // 49 LDX $3782
    0xAC, 0x84, 0x37, // 52 LDY $3784
    0xAD, 0x86, 0x37, // 55 LDA $3786 (exit P; A still 8-bit)
    0x48, // 58 PHA
    0xAD, 0x81, 0x37, // 59 LDA $3781 (B)
    0xEB, // 62 XBA
    0xAD, 0x80, 0x37, // 63 LDA $3780 (A low)
    0x28, // 66 PLP (routine's exit flags and widths)
    0x60, // 67 RTS
};

/// Offsets of the message id inside `stub_template` (the LDA #id that sends
/// it and the CMP #id that awaits the echo).
const stub_id_send_off: usize = 24;
const stub_id_cmp_off: usize = 34;

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

/// I-RAM mailbox (S-CPU window addresses): +0 status, +1/2 reg, +3/4 value.
/// Status: 0 idle, 1 write8 filed, 2 read8 filed, 3 write16 filed,
/// 4 read16 filed, $FE read served — >= 5 means busy, not a request.
const wg_mailbox: u16 = 0x37F0;

const WgSiteKind = enum { w8, w16, r8, r16, stz8, stz16, c8, c16, ry8, ry16, rx8, rx16, wx8, wx16, wy8, wy16 };
/// Which index register the site's addressing mode adds, if any. An indexed
/// site's helper computes base+index at run time — in the caller's own index
/// width, since TXA/TYA zero-extend exactly when the hardware would — and
/// files the *effective* register; the mailbox protocol never sees the
/// difference.
const WgIndex = enum { none, x, y };
const WgSite = struct { file: u32, kind: WgSiteKind, reg: u16, idx: WgIndex = .none };
const wg_sites_max = 768;
/// A helper is a pure function of (kind, reg, idx), so sites sharing all
/// three share one helper — Gradius III alone has hundreds of MMIO sites
/// but only a few dozen distinct shapes, and the carve is sized by the
/// latter.
const wg_uniq_max = 160;
/// Executed TCD/TCS sites the BW-RAM window move can adjust.
const wg_moves_max = 64;
/// Where the BW-RAM window sits on both buses ($6000-$7FFF of every system
/// bank). WRAM's low mirror $0000-$1FFF shifts here; $7E/$7F re-bank to
/// $40/$41 instead, reaching the same bytes linearly.
const wg_bw_window: u16 = 0x6000;

// --- window offloads --------------------------------------------------
//
// On a WINDOW image the composition that took the S3 path a shadow, a
// marshal, slot translation, and a D-swap costs NOTHING: the game's whole
// working set already lives in BW-RAM at identity offsets, and the SA-1's
// own $6000-$7FFF window (CBM block 0) shows the same bytes at the same
// addresses as the S-CPU's (SBM block 0). A window-rewritten routine
// therefore runs VERBATIM on the SA-1 — the stub passes registers, D, and
// DBR through the mailbox and nothing else. Every offload is resident by
// construction, which is exactly the shape the async contract wants:
// there is nothing to write back, because there is no second copy.

/// A window-offload call tree: members[0] is the root.
const WinSpec = struct {
    /// entry_pin: the DBR pin every in-tree call site carries into this
    /// member (null = at least one call site is unpinned, or the root,
    /// whose callers come through the stub with arbitrary DBR). A copy's
    /// members are called ONLY from other copies in the same tree — the
    /// member-to-member JSLs are re-pointed — so a pin proven at every
    /// in-tree call site genuinely holds for the copy at runtime.
    /// dbr_clean: the member's walked span — and, transitively, every
    /// in-tree member it calls — contains no DBR-changing op (PLB, block
    /// move), so a caller's pin survives calling it. Optimistic default;
    /// the survey passes iterate it downward to the fixpoint.
    /// pin_seen: a call site contributed this member's pin during the
    /// current eligibility pass (the meet needs a first-write marker).
    members: [ptr_tree_cap]struct {
        entry: u16,
        span: u32,
        entry_pin: ?u8 = null,
        pin_seen: bool = false,
        dbr_clean: bool = true,
    } = undefined,
    n_members: usize = 0,
    total_span: u32 = 0,
};

/// Window-tree eligibility: JSL/RTL shape over covered code, members via
/// bank-$00 JSLs, closure at RTL or an unconditional backward transfer at
/// the frontier. The rules ask one question — does the instruction mean
/// the same thing on both CPUs' buses? Window/bank-$40 data, ROM, dp
/// under a window-shifted D, and the tree's own control flow all do.
/// MMIO and the stack-swap ops do not. Low-mirror absolutes ($0000-$1FFF,
/// which the window rewrite left only as pointer-walkers and DBR-followers)
/// are dynamic evidence: under a marshalled game DBR they read the same
/// BW-RAM or ROM on both CPUs; under a system DBR they differ (WRAM vs
/// I-RAM) and S4 verification is the judge.
fn windowEligible(out: []const u8, usage: []const u8, evidence: ?[]const u8, thunks: []const u24, entry: u16) ?WinSpec {
    var spec: WinSpec = .{};
    spec.members[0] = .{ .entry = entry, .span = 0, .entry_pin = null, .pin_seen = true };
    spec.n_members = 1;
    // Two phases. SURVEY walks flow only — members, spans, and each
    // member's DBR-cleanliness — repeating while new members appear
    // (bounded by the member cap), with the pin- and evidence-gated
    // refusals disarmed: they depend on entry pins, which depend on
    // cleanliness, which the survey exists to compute. JUDGE then runs
    // once with everything armed; entry pins computed in that pass are a
    // pure function of the surveyed facts, so one pass is the fixpoint.
    var pass: usize = 0;
    while (pass <= 2 * ptr_tree_cap + 1) : (pass += 1) {
        const n_before = spec.n_members;
        var clean_before: [ptr_tree_cap]bool = undefined;
        for (spec.members[0..n_before], 0..) |m, i| clean_before[i] = m.dbr_clean;
        for (spec.members[1..spec.n_members]) |*m| m.pin_seen = false;
        var walked: usize = 0;
        while (walked < spec.n_members) : (walked += 1) {
            if (!winWalkMember(out, usage, evidence, thunks, &spec, walked, false)) return null;
        }
        var stable = spec.n_members == n_before;
        if (stable) for (spec.members[0..n_before], 0..) |m, i| {
            if (m.dbr_clean != clean_before[i]) stable = false;
        };
        if (stable) break;
    }
    for (spec.members[1..spec.n_members]) |*m| m.pin_seen = false;
    var walked: usize = 0;
    while (walked < spec.n_members) : (walked += 1) {
        if (!winWalkMember(out, usage, evidence, thunks, &spec, walked, true)) return null;
    }
    spec.total_span = 0;
    for (spec.members[0..spec.n_members]) |m| spec.total_span += m.span;
    if (spec.total_span > ptr_tree_span_max) return null;
    return spec;
}

/// Walk diagnostics, window flavor: set to a tree root to print every
/// winWalkMember refusal for it (member, pc, opcode, operand, evidence
/// class) plus each in-tree JSL's pin. Zero compiles every print away.
const dbg_win_root: u16 = 0;

fn winWalkMember(out: []const u8, usage: []const u8, evidence: ?[]const u8, thunks: []const u24, spec: *WinSpec, mi: usize, judge: bool) bool {
    const dbg = dbg_win_root != 0 and spec.members[0].entry == dbg_win_root and judge;
    const span_max: u32 = 1024;
    const entry: u32 = spec.members[mi].entry;
    var pc: u32 = entry;
    var limit: u32 = entry;
    // The data-bank pin, post-window flavor: the rewritten idiom loads
    // $40/$41 now. Under a BW-RAM pin every absolute is data both CPUs
    // read identically — including operands that happen to fall in the
    // MMIO decode range ($8EF1 stores $3E00 under a pinned $40).
    // A member starts with the pin every in-tree call site proved
    // (entry_pin) — the pin the root's own PLB idiom establishes travels
    // through the tree's JSLs, which is what admits an UNCOVERED site in
    // a shared helper: $8EF1's walker branch `ASL $0000,X` never executed
    // under any coverage, but every path to it inside the tree runs under
    // the root's $40 pin, where a tiny-base indexed absolute is BW-RAM
    // data on both buses whatever the index holds.
    var db_pin: ?u8 = spec.members[mi].entry_pin;
    // No DBR-changing op seen in this member's span so far (see WinSpec).
    var dbr_clean = true;
    // A DBR-clean member entered under a pin holds it at EVERY
    // instruction: nothing in its span (or, transitively, its in-tree
    // callees) can change DBR, so the per-op survival approximation —
    // which a mid-span RTL would needlessly kill — is not consulted.
    const pin_locked = judge and spec.members[mi].dbr_clean and spec.members[mi].entry_pin != null;
    while (pc - entry < span_max) {
        if (pc > 0xFFFF) {
            if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: ran past $FFFF\n", .{entry});
            return false;
        }
        if (usage[pc] & usage_map.flag_opcode == 0) {
            if (pc >= limit) {
                if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: uncovered byte at ${x:0>4} past frontier\n", .{ entry, pc });
                return false;
            }
            pc += 1;
            continue;
        }
        const file = pc - 0x8000;
        const op = out[file];
        const m8 = usage[pc] & usage_map.flag_m != 0;
        const x8 = usage[pc] & usage_map.flag_x != 0;
        const len = usage_map.instrLen(op, m8, x8);
        switch (op) {
            0x6B => if (pc >= limit) {
                spec.members[mi].span = pc + 1 - entry;
                spec.members[mi].dbr_clean = dbr_clean;
                return true;
            },
            0x22 => {
                // A call into an index-split thunk is a LEAF, not a
                // member. The thunk is SA-1-safe by construction — its
                // window arm addresses the identity window (the same
                // bytes at the same addresses on both buses) and its
                // as-written arm only runs once the index has carried the
                // address past $2000, so neither arm can land on the low
                // mirror that is the SA-1's own I-RAM. Walking into it
                // would see the as-written arm out of context and refuse
                // the whole tree over the very hazard the thunk exists to
                // remove — which is what kept the physics tree out.
                const tfull: u24 = @as(u24, out[file + 3] & 0x7F) << 16 |
                    std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                var is_thunk = false;
                for (thunks) |t| {
                    if (t == tfull) is_thunk = true;
                }
                if (is_thunk) {
                    if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: thunk call ${x:0>6} at ${x:0>4} — leaf\n", .{ entry, tfull, pc });
                } else if (out[file + 3] != 0x00) {
                    if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: far JSL to bank {x:0>2} at ${x:0>4}\n", .{ entry, out[file + 3], pc });
                    return false;
                } else jsl: {
                    const tgt = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                    if (tgt < 0x8000) {
                        if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: JSL below ROM (${x:0>4}) at ${x:0>4}\n", .{ entry, tgt, pc });
                        return false;
                    }
                    const dup_at: ?usize = for (spec.members[0..spec.n_members], 0..) |m, di| {
                        if (m.entry == tgt) break di;
                    } else null;
                    const ci: usize = dup_at orelse blk: {
                        if (spec.n_members == ptr_tree_cap) {
                            if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: member cap at JSL ${x:0>4}\n", .{ entry, tgt });
                            return false;
                        }
                        spec.members[spec.n_members] = .{ .entry = tgt, .span = 0, .entry_pin = db_pin, .pin_seen = true };
                        spec.n_members += 1;
                        break :blk spec.n_members - 1;
                    };
                    if (dup_at != null) {
                        // Meet of the call sites' pins: the first site this
                        // pass contributes its pin, every further site must
                        // agree or the member weakens to unpinned.
                        if (!spec.members[ci].pin_seen) {
                            spec.members[ci].entry_pin = db_pin;
                            spec.members[ci].pin_seen = true;
                        } else if (!std.meta.eql(spec.members[ci].entry_pin, db_pin)) {
                            spec.members[ci].entry_pin = null;
                        }
                    }
                    // Transitive cleanliness: calling a dirty member dirties
                    // this one.
                    if (!spec.members[ci].dbr_clean) dbr_clean = false;
                    break :jsl;
                }
            },
            // Wrong return shape, near calls, far jumps, interrupt ops,
            // and the ops that would swap the SA-1's stack from under it.
            0x60, 0x40, 0x20, 0xFC, 0x5C, 0x6C, 0x7C, 0xDC => {
                if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: flow op {x:0>2} at ${x:0>4}\n", .{ entry, op, pc });
                return false;
            },
            0x00, 0x02, 0xCB, 0xDB => {
                if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: interrupt op {x:0>2} at ${x:0>4}\n", .{ entry, op, pc });
                return false;
            },
            0x1B, 0x9A => {
                if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: stack-swap op {x:0>2} at ${x:0>4}\n", .{ entry, op, pc });
                return false;
            }, // TCS / TXS
            0x44, 0x54 => {
                // Block moves only between the BW-RAM banks, where both
                // CPUs see the same bytes. (They also load DBR with the
                // destination bank: not DBR-clean.)
                const d0 = out[file + 1];
                const s0 = out[file + 2];
                if (!((d0 == 0x40 or d0 == 0x41) and (s0 == 0x40 or s0 == 0x41 or s0 >= 0x80 or (s0 >= 0x02 and s0 <= 0x3F))))
                    return false;
                dbr_clean = false;
            },
            0x4C, 0x82, 0x80 => {
                const dst: u32 = switch (op) {
                    0x4C => std.mem.readInt(u16, out[file + 1 ..][0..2], .little),
                    0x82 => pc + 3 +% @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(std.mem.readInt(u16, out[file + 1 ..][0..2], .little)))))),
                    else => pc + 2 +% @as(u32, @bitCast(@as(i32, @as(i8, @bitCast(out[file + 1]))))),
                };
                if (dst < entry or dst - entry >= span_max) return false;
                limit = @max(limit, dst);
                if (dst <= pc and pc >= limit) {
                    spec.members[mi].span = pc + len - entry;
                    spec.members[mi].dbr_clean = dbr_clean;
                    return true;
                }
            },
            0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0 => {
                const dst = pc + 2 +% @as(u32, @bitCast(@as(i32, @as(i8, @bitCast(out[file + 1])))));
                if (dst < entry or dst - entry >= span_max) return false;
                limit = @max(limit, dst);
            },
            0xA9 => if (m8 and file + 3 < out.len and out[file + 2] == 0x48 and out[file + 3] == 0xAB) {
                db_pin = out[file + 1];
            },
            0xAB => {
                if (file < 3 or out[file - 3] != 0xA9 or out[file - 1] != 0x48) db_pin = null;
                dbr_clean = false;
            },
            else => {},
        }
        // A pin survives a call to an in-tree member whose own walked
        // span is DBR-clean — the walk sees the callee's whole reachable
        // body, which is a proof dbrTransparent's bounded scan cannot
        // always deliver. (Cleanliness comes from the survey passes;
        // in-tree callees of callees are members too, so the meet over
        // every member's flag makes the property transitive.)
        // A thunk is DBR-transparent by construction: its only bank
        // traffic is a balanced PHB/PLA it reads and discards, and it
        // exits through PLP. So the caller's pin survives it — which
        // matters, because the pin is what admits the walker's uncovered
        // sites, and losing it at a thunk call would refuse the tree just
        // as surely as the hazard the thunk removed.
        const thunk_call = op == 0x22 and out[file + 3] != 0x00 and blk: {
            const tf: u24 = @as(u24, out[file + 3] & 0x7F) << 16 |
                std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
            for (thunks) |t| {
                if (t == tf) break :blk true;
            }
            break :blk false;
        };
        const in_tree_clean = thunk_call or op == 0x22 and out[file + 3] == 0x00 and blk: {
            const tgt = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
            for (spec.members[0..spec.n_members]) |m| {
                if (m.entry == tgt) break :blk m.dbr_clean;
            }
            break :blk false;
        };
        if (dbg and op == 0x22) std.debug.print("[win $8ef1] member ${x:0>4}: JSL ${x:0>4} at ${x:0>4} pin {?x} in_tree_clean {}\n", .{ entry, std.mem.readInt(u16, out[file + 1 ..][0..2], .little), pc, db_pin, in_tree_clean });
        if (!pin_locked and !in_tree_clean and !dbrSurvives(out, usage, file, op)) db_pin = null;
        switch (usage_map.mode(op)) {
            .none, .dp, .dp_idx => {},
            .abs, .abs_x, .abs_y => {
                const v = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                // MMIO through a system bank is S-CPU-only hardware — but
                // under a pinned BW-RAM bank the same operand is data both
                // CPUs read identically.
                const pinned_bw = db_pin != null and (db_pin.? == 0x40 or db_pin.? == 0x41);
                if (judge and !pinned_bw and v >= 0x2100 and v < 0x4380) {
                    if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: MMIO abs ${x:0>4} at ${x:0>4} (op {x:0>2}, pin {?x})\n", .{ entry, v, pc, op, db_pin });
                    return false;
                }
                // An UNSHIFTED low-mirror site (mixed or absent evidence
                // keeps the rewriter's hands off it) means WRAM on the
                // S-CPU but the SA-1's OWN I-RAM in the copy — a tree
                // containing one computes different results per CPU
                // (measured: the offloaded sound path took the wrong
                // branch at the START beep and the menu never reset its
                // frame counter). Pure-ROM evidence is fine: same bytes
                // on both buses.
                if (judge and !pinned_bw and v < 0x2000) {
                    const e: u8 = if (evidence) |s| s[pc] | s[0x80_0000 | pc] else 0;
                    const shifted = if (e != 0)
                        e == usage_map.site_wram_low
                    else
                        usage_map.mode(op) == .abs or v >= 0x100;
                    if (!shifted and (e == 0 or e & usage_map.site_wram_low != 0)) {
                        if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: I-RAM hazard abs op {x:0>2} ${x:0>4} at ${x:0>4} evidence {x:0>2} pin {?x}\n", .{ entry, op, v, pc, e, db_pin });
                        return false;
                    }
                }
            },
            .long, .long_x => {
                const b = out[file + 3];
                const v = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                if ((b & 0x7F) <= 0x3F and v >= 0x2100 and v < 0x4380) {
                    if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: MMIO long ${x:0>2}:{x:0>4} at ${x:0>4}\n", .{ entry, b, v, pc });
                    return false;
                }
                // $7E/$7F would be real WRAM — the window rewrite
                // re-banked every covered site, so seeing one here means
                // the walk wandered into unrewritten territory.
                if (b == 0x7E or b == 0x7F) {
                    if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: unrewritten WRAM long ${x:0>2}:{x:0>4} at ${x:0>4}\n", .{ entry, b, v, pc });
                    return false;
                }
                // Same I-RAM hazard as the absolute arm: an unshifted
                // indexed-long low-mirror site diverges on the SA-1
                // unless its measured traffic was pure ROM.
                // A base at or above $FF00 wraps forward into the NEXT
                // bank's low page, so it reaches the mirror just as surely
                // as a base below $2000 — and testing only `v < $2000`
                // is how `LDA $02:FFFF,X` was admitted into the physics
                // tree and rendered the stage-1 boss out of I-RAM.
                if (judge and usage_map.mode(op) == .long_x and (b & 0x7F) <= 0x3F and
                    (v < 0x2000 or v >= 0xFF00))
                {
                    const e: u8 = if (evidence) |s| s[pc] | s[0x80_0000 | pc] else 0;
                    const shifted = e != 0 and e == usage_map.site_wram_low;
                    if (!shifted and (e == 0 or e & usage_map.site_wram_low != 0)) {
                        if (dbg) std.debug.print("[win $8ef1] member ${x:0>4}: I-RAM hazard long_x ${x:0>2}:{x:0>4} at ${x:0>4} evidence {x:0>2}\n", .{ entry, b, v, pc, e });
                        return false;
                    }
                }
            },
        }
        pc += len;
    }
    return false;
}

/// The window stubs' D guard: a caller whose direct page is NOT
/// window-shaped (D outside $6000-$7FFF) comes from a code path the
/// rewriter never covered — its dp state lives in real WRAM, and handing
/// it to the SA-1 would resolve dp operands into the SA-1's own I-RAM,
/// smash the mailbox, and send the chip rampaging over shared BW-RAM
/// (measured: a garbled-and-wiped session traced to exactly this). Such
/// a call runs the ORIGINAL body on the S-CPU instead — no worse than
/// the uncovered path already is, and the SA-1 stays sane.
const win_guard_len: u32 = 24;
fn emitWinGuard(d: []u8, cur: *usize, entry: u16) void {
    put(d, cur, &.{ 0x08, 0xC2, 0x20, 0x48, 0x0B, 0x68 }); // PHP REP PHA PHD/PLA
    put(d, cur, &.{ 0xC9, 0x00, 0x60, 0x90, 0x05 }); // < $6000 -> bail
    put(d, cur, &.{ 0xC9, 0x00, 0x80, 0x90, 0x06 }); // < $8000 -> ok
    put(d, cur, &.{ 0x68, 0x28, 0x5C, @truncate(entry), @truncate(entry >> 8), 0x00 }); // bail
    put(d, cur, &.{ 0x68, 0x28 }); // ok
}

/// The VBLANK-PROXIMITY guard: the interleaving hazard, closed by
/// construction. A tree that reads NMI-shared state can only tear when
/// the NMI fires MID-TREE — stock's inline walk is interrupted BY the
/// handler and only ever sees interleavings the game was built for; the
/// concurrent SA-1 copy is not (measured: a torn chain head sent the
/// $8EF1 walker into a ROM cycle and parked the mainline forever). But
/// NMI timing is knowable at call time: latch the V counter, and a call
/// starting within `margin` scanlines of the NMI at line 225 runs the
/// ORIGINAL body inline instead — the stock path. Everywhere else the
/// tree (worst case well under the margin at ~10.74MHz) completes
/// before the NMI can touch anything it reads; inside vblank the NMI
/// has already fired and the runway is a whole frame. The two OPVCT
/// reads are toggle-balanced and $213F resets the toggle first; a game
/// that itself consumes the H/V latch could be disturbed — the
/// verification surfaces and the soak gate arbitrate that.
const win_vblank_margin_lines: u8 = 32;
const win_vblank_guard_len: u32 = 41;
fn emitWinVblankGuard(d: []u8, cur: *usize, entry: u16) void {
    put(d, cur, &.{ 0x08, 0xE2, 0x20, 0x48 }); // PHP SEP #$20 PHA
    // LONG-addressed PPU reads: the caller's DBR is live here (a pinned
    // caller arrives with $40), and an absolute $2137 under it would
    // read BW-RAM instead of the latch.
    put(d, cur, &.{ 0xAF, 0x37, 0x21, 0x00 }); // SLHV: latch H/V
    put(d, cur, &.{ 0xAF, 0x3F, 0x21, 0x00 }); // STAT78: reset the read toggle
    put(d, cur, &.{ 0xAF, 0x3D, 0x21, 0x00, 0xEB }); // OPVCT low -> B
    put(d, cur, &.{ 0xAF, 0x3D, 0x21, 0x00, 0x4A }); // OPVCT high; bit8 -> carry
    put(d, cur, &.{ 0xB0, 0x0F }); // V >= 256: deep vblank, safe
    put(d, cur, &.{ 0xEB, 0xC9, 225 - win_vblank_margin_lines }); // A = V low
    put(d, cur, &.{ 0x90, 0x0A }); // below the window: safe
    put(d, cur, &.{ 0xC9, 225, 0xB0, 0x06 }); // at/past NMI line: safe
    put(d, cur, &.{ 0x68, 0x28, 0x5C, @truncate(entry), @truncate(entry >> 8), 0x00 }); // danger: inline
    put(d, cur, &.{ 0x68, 0x28 }); // safe
}

/// The mailbox BUSY guard: the S-CPU's NMI keeps firing while a sync stub
/// waits out its handshake, and the handler may call ANOTHER offloaded
/// routine — the game's contexts shift by phase (measured: the sound
/// pump is mainline in attract but interrupt-side at the title-exit
/// transition), so a nested stub posts over the in-flight message,
/// deadlocks both handshakes, parks the S-CPU forever and leaves the
/// SA-1 mid-copy (the f830 freeze). A call that finds EITHER busy cell
/// set ($378C sync in-flight, $378A async in-flight) is NMI-nested — it
/// runs the original body inline on the S-CPU instead, which is exactly
/// what the un-offloaded game would have done.
const win_busy_guard_len: u32 = 30;
fn emitWinBusyGuard(d: []u8, cur: *usize, entry: u16) void {
    put(d, cur, &.{ 0x08, 0xC2, 0x20, 0x48, 0xE2, 0x20 }); // PHP REP PHA SEP #$20
    put(d, cur, &.{ 0xAF, 0x8C, 0x37, 0x00 }); // LDA sync busy
    put(d, cur, &.{ 0x0F, 0x8A, 0x37, 0x00 }); // ORA async busy
    put(d, cur, &.{ 0xD0, 0x06 }); // BNE bail
    put(d, cur, &.{ 0xC2, 0x20, 0x68, 0x28, 0x80, 0x08 }); // ok: restore, skip bail
    put(d, cur, &.{ 0xC2, 0x20, 0x68, 0x28 }); // bail: restore
    put(d, cur, &.{ 0x5C, @truncate(entry), @truncate(entry >> 8), 0x00 });
}

/// Window sync stub: D guard, then caller D ($3788), registers, caller P,
/// and caller DBR ($378B) into the mailbox; send; double handshake; exit
/// registers back out. No shadow, no slots, no page copies.
///
/// With `nmi_off` (--wg-nmi-off): SEI + NMITIMEN masked (keeping the
/// game's auto-joypad bit) across the send-and-wait, restored before
/// ANY exit path from the $378F MIRROR the thunked writers maintain —
/// the game's own shadow byte is not phase-accurate (its transition
/// code disables $4200 without updating it) — and the caller's P (and
/// its I bit) round-trips untouched because it was marshaled BEFORE the
/// SEI. While the S-CPU waits here, nothing on it can mutate the tree's
/// read-set: the concurrency hazard is closed by construction, not by
/// timing. A straddled NMI is delivered late (real HW: fires on
/// re-enable during vblank; this emulator: skipped like a lag frame).
const win_stub_len: u32 = 158 + win_guard_len + win_busy_guard_len + win_vblank_guard_len;
const win_nmi_off_extra: u32 = 27;
/// Covered `STA $4200` sites re-pointed at mirror thunks (bank $00).
const NmiSites = struct { at: [8]u32, n: usize };
const win_nmi_thunk_len: u32 = 8;
fn emitWinStub(d: []u8, id: u8, entry: u16, nmi_off: bool) u32 {
    var cur: usize = 0;
    emitWinGuard(d, &cur, entry);
    emitWinBusyGuard(d, &cur, entry);
    emitWinVblankGuard(d, &cur, entry);
    // The mailbox is NMI-ATOMIC: busy is raised BEFORE the first mailbox
    // write and dropped AFTER the last mailbox read. The S-CPU's NMI
    // keeps firing through a stub, and a nested offload call landing in
    // an unguarded window overwrites the marshal (the tree then runs
    // with the NESTED call's registers) or the exit registers (the outer
    // caller resumes with them) — measured live as rampaging indexed
    // writes, a smashed stack top, and a wild RTL into open bus while
    // the music played on. Fully transparent wrapper: PHP/SEP/PHA
    // around the store.
    put(d, &cur, &.{ 0x08, 0xE2, 0x20, 0x48, 0xA9, 0x01, 0x8F, 0x8C, 0x37, 0x00, 0x68, 0x28 });
    // Caller D, with A saved around the grab.
    put(d, &cur, &.{ 0x08, 0xC2, 0x20, 0x48, 0x0B, 0x68, 0x8F, 0x88, 0x37, 0x00, 0x68, 0x28 });
    // Register marshal (the sync-ptr stub's, verbatim).
    put(d, &cur, &.{ 0x8B, 0x08, 0xE2, 0x20 });
    put(d, &cur, &.{ 0x8F, 0x80, 0x37, 0x00, 0xEB, 0x8F, 0x81, 0x37, 0x00, 0xEB });
    put(d, &cur, &.{ 0xC2, 0x30, 0x8A, 0x8F, 0x82, 0x37, 0x00, 0x98, 0x8F, 0x84, 0x37, 0x00 });
    put(d, &cur, &.{ 0xE2, 0x20, 0x68, 0x8F, 0x86, 0x37, 0x00 });
    // Caller DBR: the PHB byte, at the stack top now the PHP is pulled.
    put(d, &cur, &.{ 0xA3, 0x01, 0x8F, 0x8B, 0x37, 0x00 });
    if (nmi_off) {
        // Interrupts off for the whole handshake: caller P is already in
        // the mailbox, so the SEI never leaks back. RDNMI ack first —
        // the game's own bracket idiom.
        put(d, &cur, &.{0x78}); // SEI
        put(d, &cur, &.{ 0xAF, 0x10, 0x42, 0x00 }); // RDNMI ack
        put(d, &cur, &.{ 0xAF, 0x8F, 0x37, 0x00 }); // the $4200 mirror
        put(d, &cur, &.{ 0x29, 0x01 }); // keep auto-joypad only
        put(d, &cur, &.{ 0x8F, 0x00, 0x42, 0x00 });
    }
    // Send + double handshake.
    put(d, &cur, &.{ 0xA9, id, 0x8F, 0x00, 0x22, 0x00 });
    put(d, &cur, &.{ 0xAF, 0x00, 0x23, 0x00, 0x29, 0x0F, 0xC9, id, 0xD0, 0xF6 });
    put(d, &cur, &.{ 0xA9, 0x00, 0x8F, 0x00, 0x22, 0x00 });
    put(d, &cur, &.{ 0xAF, 0x00, 0x23, 0x00, 0x29, 0x0F, 0xD0, 0xF8 });
    if (nmi_off) {
        // Restore the game's NMITIMEN before ANY exit path (the aborted
        // check below JMLs away); the exit PLP restores the caller's I.
        put(d, &cur, &.{ 0xAF, 0x10, 0x42, 0x00 }); // RDNMI ack
        put(d, &cur, &.{ 0xAF, 0x8F, 0x37, 0x00 }); // the $4200 mirror
        put(d, &cur, &.{ 0x8F, 0x00, 0x42, 0x00 });
    }
    // Exit registers from the mailbox; caller DBR back.
    put(d, &cur, &.{0xAB});
    put(d, &cur, &.{ 0xC2, 0x30, 0xAF, 0x82, 0x37, 0x00, 0xAA, 0xAF, 0x84, 0x37, 0x00, 0xA8 });
    put(d, &cur, &.{ 0xE2, 0x20, 0xAF, 0x86, 0x37, 0x00, 0x48 });
    put(d, &cur, &.{ 0xAF, 0x81, 0x37, 0x00, 0xEB, 0xAF, 0x80, 0x37, 0x00 });
    // WATCHDOG-ABORTED check, matching THIS stub's id: the dispatcher's
    // abort path skipped the exit marshal, so the registers just loaded
    // ARE the caller's entry registers — clear the flag and the busy
    // cell and run the ORIGINAL body inline, exactly the un-offloaded
    // game (the tree never ran to completion; worst case is an
    // interrupted copy's partial BW-RAM writes re-applied, a rare
    // single-frame double-step instead of a permanent freeze).
    put(d, &cur, &.{ 0x48, 0xAF, 0x8D, 0x37, 0x00, 0xC9, id, 0xD0, 0x10 }); // PHA; aborted us?
    put(d, &cur, &.{ 0xA9, 0x00, 0x8F, 0x8D, 0x37, 0x00, 0x8F, 0x8C, 0x37, 0x00 });
    put(d, &cur, &.{ 0x68, 0x28, 0x5C, @truncate(entry), @truncate(entry >> 8), 0x00 });
    put(d, &cur, &.{0x68}); // ok: PLA
    // Mailbox reads done — NOW release it (A preserved around the store).
    put(d, &cur, &.{ 0x48, 0xA9, 0x00, 0x8F, 0x8C, 0x37, 0x00, 0x68 });
    put(d, &cur, &.{ 0x28, 0x6B });
    return @intCast(cur);
}

/// Window async stub: fence first (drain any in-flight call), marshal
/// registers + D + DBR, send, mark busy, return AT ONCE with the
/// caller's own registers. Nothing to write back — the routine's effects
/// land in the shared BW-RAM both CPUs address.
const win_async_stub_len: u32 = 111 + win_guard_len + win_busy_guard_len;
fn emitWinAsyncStub(d: []u8, fence: u24, id: u8, entry: u16) u32 {
    var cur: usize = 0;
    emitWinGuard(d, &cur, entry);
    emitWinBusyGuard(d, &cur, entry);
    put(d, &cur, &.{ 0x08, 0xC2, 0x30, 0x48, 0xDA, 0x5A, 0x8B }); // save caller
    put(d, &cur, &.{ 0x22, @truncate(fence), @truncate(fence >> 8), @truncate(fence >> 16) });
    put(d, &cur, &.{ 0xAB, 0xC2, 0x30, 0x7A, 0xFA, 0x68, 0x28 }); // restore (REP first)
    // Raise busy BEFORE the marshal (see the sync stub: an NMI-nested
    // call in the marshal window would overwrite the mailbox and the
    // async tree would run with the nested call's registers).
    put(d, &cur, &.{ 0x08, 0xE2, 0x20, 0x48, 0xA9, 0x01, 0x8F, 0x8C, 0x37, 0x00, 0x68, 0x28 });
    put(d, &cur, &.{ 0x08, 0xC2, 0x30, 0x48, 0xDA, 0x5A }); // re-save P,A,X,Y
    put(d, &cur, &.{ 0x8B, 0x08, 0xE2, 0x20 });
    put(d, &cur, &.{ 0x8F, 0x80, 0x37, 0x00, 0xEB, 0x8F, 0x81, 0x37, 0x00, 0xEB });
    put(d, &cur, &.{ 0xC2, 0x30, 0x8A, 0x8F, 0x82, 0x37, 0x00, 0x98, 0x8F, 0x84, 0x37, 0x00 });
    // Caller P is the re-save's PHP byte: B(1)+Y(2)+X(2)+A(2) above it
    // once our own PHP is pulled.
    put(d, &cur, &.{ 0xE2, 0x20, 0x68, 0xA3, 0x08, 0x8F, 0x86, 0x37, 0x00 });
    put(d, &cur, &.{ 0xA3, 0x01, 0x8F, 0x8B, 0x37, 0x00 }); // DBR (PHB byte)
    // D last — the PLA clobbers A, which the mailbox already holds.
    put(d, &cur, &.{ 0xC2, 0x20, 0x0B, 0x68, 0x8F, 0x88, 0x37, 0x00 });
    put(d, &cur, &.{ 0xE2, 0x20, 0xA9, id, 0x8F, 0x00, 0x22, 0x00, 0x8F, 0x8A, 0x37, 0x00 });
    // $378A now covers the in-flight async; drop the marshal guard.
    put(d, &cur, &.{ 0xA9, 0x00, 0x8F, 0x8C, 0x37, 0x00 });
    put(d, &cur, &.{ 0xAB, 0xC2, 0x30, 0x7A, 0xFA, 0x68, 0x28, 0x6B });
    return @intCast(cur);
}

/// One dispatcher block for a window offload: game D as-is, WATCHDOG
/// armed (while DBR is still the dispatcher's — the arm is absolute
/// MMIO, and a game DBR would land it in BW-RAM), game DBR from the
/// mailbox, the shared unmarshal, CLI, the copy, SEI, dispatcher DBR
/// back, the shared marshal, exit-P I-bit repaired, dispatcher D back,
/// signal. The watchdog: the SA-1's own linear timer restarts before
/// each dispatch; a copy that overruns the budget takes the timer IRQ
/// into the abort handler, which unwinds and signals "aborted" instead
/// of wedging both CPUs forever (measured: the $8EF1 walker's torn
/// chain-head ROM cycles survived every cheaper guard).
///
/// The I-bit dance: these trees are the INTERRUPT class — their game P
/// arrives with I set, so without the CLI the watchdog would never
/// fire for exactly the calls it exists to protect (the unmarshal's
/// PLP hands game P to the copy). But P round-trips: the marshal
/// stores the live post-copy P and the S-CPU caller PLPs it, so the
/// forced CLI/SEI would leak a wrong I bit back into the GAME. Entry
/// P's I bit is stashed at $378E before dispatch and patched into the
/// stored exit P after the marshal. (PLB's N/Z clobber predates the
/// watchdog and is measured non-load-bearing; I is not a flag to
/// gamble on.)
const win_block_len: u32 = 65;
fn emitWinBlock(d: []u8, cur: *usize, id: u8, copy_addr: u16, copy_bank: u8, unm_addr: u16, mar_addr: u16, sig_addr: u16, dp_base: u16) void {
    put(d, cur, &.{ 0xC9, id, 0xD0, win_block_len - 4 });
    put(d, cur, &.{0x8B}); // dispatcher DBR
    put(d, cur, &.{ 0xC2, 0x20, 0xAD, 0x88, 0x37, 0x5B }); // game D
    put(d, cur, &.{ 0xE2, 0x20 });
    put(d, cur, &.{ 0xAD, 0x86, 0x37, 0x29, 0x04, 0x8D, 0x8E, 0x37 }); // entry P's I bit -> $378E
    put(d, cur, &.{ 0x9C, 0x11, 0x22 }); // CTR: counters to zero
    put(d, cur, &.{ 0xA9, 0x40, 0x8D, 0x0B, 0x22 }); // CIC: clear timer flag
    putJsr(d, cur, unm_addr); // loads X/Y, sets game DBR, loads A/P long
    put(d, cur, &.{0x58}); // CLI — the watchdog covers the copy whatever game P says
    put(d, cur, &.{ 0x22, @truncate(copy_addr), @truncate(copy_addr >> 8), copy_bank });
    put(d, cur, &.{0x78}); // SEI
    put(d, cur, &.{0xAB}); // dispatcher DBR back
    putJsr(d, cur, mar_addr);
    put(d, cur, &.{ 0xAD, 0x86, 0x37, 0x29, 0xFB, 0x0D, 0x8E, 0x37, 0x8D, 0x86, 0x37 }); // exit P I <- entry I
    put(d, cur, &.{ 0xA9, 0x40, 0x8D, 0x0B, 0x22 }); // drop a crossing that never fired
    put(d, cur, &.{ 0xF4, @truncate(dp_base), @truncate(dp_base >> 8), 0x2B });
    put(d, cur, &.{ 0x4C, @truncate(sig_addr), @truncate(sig_addr >> 8) });
}

/// The watchdog budget: linear-timer V target. V increments every 2048
/// master clocks, so 200 is ~19ms. Generous ON PURPOSE: the big worker
/// tree's LEGITIMATE runs average ~4.4ms (measured: a 48-line budget
/// aborted them wholesale, and every abort double-applies the partial
/// BW-RAM writes plus the inline re-run — 28 KiB of divergence by
/// frame 422). The watchdog exists to catch INFINITE loops, where the
/// alternative is a permanent freeze; cutting one off within ~1.2
/// frames is plenty.
const win_watchdog_vcnt: u8 = 200;

/// The abort handler the SA-1's timer IRQ vectors to (CIV). IRQs are
/// open ONLY between a dispatch block's CLI and SEI, so the sole
/// LEGITIMATE spurious crossing (the completed-call race: the flag trips
/// just as the copy returns) interrupts bank 0 inside the blocks region
/// — that exact shape is acked and resumed. EVERYTHING else is a
/// runaway: a walker spinning inside the copy AND a torn pointer that
/// flung it into wild ROM both fail the shape test (checking only the
/// copies' span would RESUME the wild-chain case forever). Unwind:
/// aborted flag for the S-CPU, stack reset to the dispatcher's base,
/// dispatcher DBR/D back, and straight to the signal WITHOUT the exit
/// marshal, so the mailbox still holds the caller's ENTRY registers and
/// the stub's inline re-run starts from exactly the original call state.
/// $378D carries the aborted ID (the $3787 latch), not a boolean: each
/// sync stub consumes only its OWN id, so an aborted ASYNC tree — whose
/// stub returned long ago and can never consume the flag — leaves a
/// stale value no sync stub matches (that run's effects are dropped, one
/// missed pump tick) instead of tricking the NEXT sync caller into
/// re-running a body whose tree already completed.
const win_abort_len: u32 = 58;
fn emitWinAbort(d: []u8, cur: *usize, blocks_lo: u16, blocks_hi1: u16, sig_addr: u16) void {
    put(d, cur, &.{ 0xC2, 0x20, 0x48 }); // REP #$20, PHA (preserve A for resume)
    put(d, cur, &.{ 0xA3, 0x04 }); // interrupted PC (above A + P)
    put(d, cur, &.{ 0xC9, @truncate(blocks_lo), @truncate(blocks_lo >> 8) });
    put(d, cur, &.{ 0x90, 0x0B }); // below the blocks: runaway
    put(d, cur, &.{ 0xC9, @truncate(blocks_hi1), @truncate(blocks_hi1 >> 8) });
    put(d, cur, &.{ 0xB0, 0x06 }); // past them: runaway
    put(d, cur, &.{ 0xE2, 0x20, 0xA3, 0x06 }); // interrupted PB
    put(d, cur, &.{ 0xF0, 0x1C }); // bank 0 in-blocks: resume8
    // Genuine runaway. The stack is about to be reset — nothing to unpush.
    put(d, cur, &.{ 0xE2, 0x20 }); // (16-bit arrivals from the PC checks)
    put(d, cur, &.{ 0x4B, 0xAB }); // PHK/PLB: dispatcher DBR
    put(d, cur, &.{ 0xA9, 0x40, 0x8D, 0x0B, 0x22 }); // ack the timer IRQ
    put(d, cur, &.{ 0xAD, 0x87, 0x37, 0x8D, 0x8D, 0x37 }); // $378D: aborted id
    put(d, cur, &.{ 0xC2, 0x10, 0xA2, 0x78, 0x37, 0x9A }); // stack to the dispatcher base
    put(d, cur, &.{ 0xF4, 0x00, 0x37, 0x2B }); // dispatcher D
    put(d, cur, &.{ 0x4C, @truncate(sig_addr), @truncate(sig_addr >> 8) });
    put(d, cur, &.{ 0xA9, 0x40, 0x8D, 0x0B, 0x22 }); // resume8: ack
    put(d, cur, &.{ 0xC2, 0x20, 0x68, 0x40 }); // restore A, RTI
}

const wg_prologue_len = 21;
/// Window mode's shim: SEI + 3 stores + XCE/REP + D + S + SEP + JMP =
/// 1 + 15 + 4 + 4 + 4 + 2 + 3 = 33; +23 when offloads boot the SA-1
/// (SIWP, CRV lo/hi, async busy init, reset release).
const wg_window_shim_len = 33;
const wg_window_shim_max = 33 + 48;
/// What the shim must program before releasing the SA-1 from reset:
/// its reset vector and — S-CPU-side registers both — its IRQ vector,
/// aimed at the watchdog's abort handler.
const WinBoot = struct { crv: u16, civ: u16 };
/// Bank-0 reservation for the window dispatcher: prologue + message loop
/// + JMP + sig + unm + mar + abort + blocks + NMI prologue + mirror thunks.
/// The split flavor's carve budget: tok + mini-tok + sloop + the mul
/// helper + up to 26 stub/trampoline pairs. Bank $00's whole padding
/// run must cover shim + this.
const split_disp_max: u32 = 1400;
const win_disp_max: u32 = 51 + 12 + 3 + 19 + 29 + 24 + offload_max * win_block_len + win_abort_len + nmi_prologue_len + 8 * win_nmi_thunk_len;

/// Context-split thunk: the DBR dispatch plus both flavors of the
/// original 3-byte op (see the emission comment in convertWholeGame).
const split_thunk_len: u32 = 24;
/// Index-split thunk: the DBR test, the X-width test, the magnitude
/// compare, and both flavors of the original 3-byte op — A-PRESERVING, so
/// every op class (stores included) can be thunked, not just LDA shapes.
const idx_thunk_len: u32 = 35;
/// The same thunk WITHOUT the data-bank test, for a site whose measured
/// evidence already rules a BW-RAM pin out. The test costs ~17 cycles on
/// every call and these sites are hot — Gradius III's five measured
/// split sites are its level-script walker, and paying for a question
/// their evidence has already answered moved the whole timeline far
/// enough to flip the behavioural verdict on a build that shipped.
const idx_thunk_short_len: u32 = 27;
/// Sites one conversion can thunk (Gradius III measures ~100).
const split_thunk_max: usize = 192;
/// Index-split sites one conversion can thunk. Far larger than the DBR
/// flavor: with `--wg-static` every tiny-base indexed absolute in code the
/// profile never reached is thunked on principle, because no evidence
/// exists to prove which home it walks.
const idx_thunk_max: usize = 2048;

/// A bank-local padding allocator for the thunk populations.
///
/// `findFreeSpace` hands out the tail of the ONE largest run, which is the
/// right shape for a single scaffold and the wrong one for a population:
/// Gradius III's bank $00 carries its slack in several runs, and demanding
/// 2 KiB in a single stretch for 62 thunks refused a conversion that fits
/// comfortably across four. This walks every run in turn, and it skips the
/// scaffold's carve by ADDRESS instead of by painting over it — the paint
/// trick relied on the carve's run staying shorter than its neighbours,
/// which is not a property anyone maintains.
///
/// $FF ONLY, unlike `findFreeSpace`: a long run of $00 is as often a real
/// table of zeros as it is slack, and this allocator takes MANY small runs
/// across MANY banks rather than one obvious tail, so it meets the
/// ambiguous ones. Measured: a run of $00 in bank $0E was graphics data,
/// and thunks written into it rendered pictures the original never showed.
const PadAlloc = struct {
    region: []const u8,
    /// File offset of `region[0]`.
    base: u32,
    /// Reserved span (file offsets); empty when lo == hi.
    lo: u32 = 0,
    hi: u32 = 0,
    scan: usize = 0,
    cur: u32 = 0,
    end: u32 = 0,

    /// The same 8-byte cushion `findFreeSpace` keeps between real bytes
    /// and whatever it hands out.
    const margin = 8;

    /// Rewind the scan. Safe because everything already handed out has
    /// been WRITTEN by then, so a fresh pass reads it as occupied — which
    /// is what lets a caller that failed to fit a 35-byte body come back
    /// and ask for a 5-byte stub instead.
    fn rewind(self: *@This()) void {
        self.scan = 0;
        self.cur = 0;
        self.end = 0;
    }

    /// Padding still on offer, net of the per-run margin. Used to decide
    /// bodies-or-stubs BEFORE placing anything: a bank that cannot hold
    /// every body should hold no body at all, because a half-filled bank
    /// leaves the tail thunks without even their 5-byte stub.
    fn freeBytes(self: *const @This()) u32 {
        var total: u32 = 0;
        var i: usize = 0;
        while (i < self.region.len) {
            if (self.region[i] != 0xFF) {
                i += 1;
                continue;
            }
            var j = i + 1;
            while (j < self.region.len and self.region[j] == 0xFF) j += 1;
            var s = self.base + @as(u32, @intCast(i));
            var e = self.base + @as(u32, @intCast(j));
            i = j;
            if (self.hi > self.lo and s < self.hi and e > self.lo) {
                const left = if (self.lo > s) self.lo - s else 0;
                const right = if (e > self.hi) e - self.hi else 0;
                if (left >= right) e = s + left else s = e - right;
            }
            if (e > s + margin) total += e - s - margin;
        }
        return total;
    }

    /// How many 5-byte far stubs the bank could hold if it held nothing
    /// else. `freeBytes` cannot answer this: it nets one margin per run,
    /// while `next` charges the margin only on OPENING a run and then
    /// packs to its end — for a population of uniform 5-byte stubs the
    /// per-run arithmetic here is exact.
    fn stubCapacity(self: *const @This()) u32 {
        var total: u32 = 0;
        var i: usize = 0;
        while (i < self.region.len) {
            if (self.region[i] != 0xFF) {
                i += 1;
                continue;
            }
            var j = i + 1;
            while (j < self.region.len and self.region[j] == 0xFF) j += 1;
            var s = self.base + @as(u32, @intCast(i));
            var e = self.base + @as(u32, @intCast(j));
            i = j;
            if (self.hi > self.lo and s < self.hi and e > self.lo) {
                const left = if (self.lo > s) self.lo - s else 0;
                const right = if (e > self.hi) e - self.hi else 0;
                if (left >= right) e = s + left else s = e - right;
            }
            if (e > s + margin) total += (e - s - margin) / far_stub_len;
        }
        return total;
    }

    fn next(self: *@This(), need: u32) ?u32 {
        if (self.cur + need <= self.end) {
            defer self.cur += need;
            return self.cur;
        }
        while (self.scan < self.region.len) {
            if (self.region[self.scan] != 0xFF) {
                self.scan += 1;
                continue;
            }
            var j = self.scan + 1;
            while (j < self.region.len and self.region[j] == 0xFF) j += 1;
            var s = self.base + @as(u32, @intCast(self.scan));
            var e = self.base + @as(u32, @intCast(j));
            self.scan = j;
            // Clipped against the reservation, keeping the larger half.
            if (self.hi > self.lo and s < self.hi and e > self.lo) {
                const left = if (self.lo > s) self.lo - s else 0;
                const right = if (e > self.hi) e - self.hi else 0;
                if (left >= right) e = s + left else s = e - right;
            }
            if (e >= s + need + margin) {
                self.cur = s + margin;
                self.end = e;
                defer self.cur += need;
                return self.cur;
            }
        }
        return null;
    }
};

/// A `PadAlloc` over one bank of `out`, honouring a reserved span given as
/// (offset, length) in FILE offsets. Bank $00 stops at the header, where
/// the scaffold's carve is the thing reserved; other banks are their whole
/// 32 KiB, where the reservation is the tail of the biggest run kept back
/// for offload tree copies. Passing the reservation and then ignoring it
/// for every bank but $00 is how the thunks quietly wrote 395 bytes into
/// that tail and lost the trees anyway.
fn padAllocFor(out: []const u8, header_off: u32, bank: u32, res_at: u32, res_len: u32) PadAlloc {
    if (bank == 0) return .{
        .region = out[0..header_off],
        .base = 0,
        .lo = res_at,
        .hi = res_at + res_len,
    };
    const lo = bank * 0x8000;
    return .{
        .region = out[lo..@min(lo + 0x8000, out.len)],
        .base = lo,
        .lo = res_at,
        .hi = res_at + res_len,
    };
}

/// A padding allocator for thunk BODIES that will not fit their own bank;
/// the site's bank keeps only the 5-byte stub.
///
/// It walks banks DOWNWARD from the top, and that direction is load-
/// bearing twice over. Bank $00 is excluded because it is the bank under
/// pressure and spending less of it is the whole point — but the low banks
/// generally are: they hold the code, so they hold the sites, so they are
/// the ones that still need their own stubs. Measured: filling upward from
/// bank $01 emptied bank $02's padding on bank $00's behalf and then had
/// nowhere to put bank $02's own stubs.
const FarPad = struct {
    out: []const u8,
    header_off: u32,
    /// 0 until the first call; the top bank thereafter.
    bank: u32 = 0,
    pad: ?PadAlloc = null,
    /// Reserved span (file offsets) inside `keep_bank`: the TAIL of the
    /// image's biggest padding run, kept for the offload tree copies.
    ///
    /// The copies need ONE contiguous block and cannot be split, while a
    /// thunk body fits anywhere — so when they compete, the thunks must
    /// yield. Measured: they did not, making the physics tree eligible
    /// pushed the copies' demand past what was left, EVERY offload was
    /// silently abandoned, and the patch shipped 186 dropped frames where
    /// it had been doing 116. Reserving the whole BANK was worse still:
    /// the far pool then ate banks $01-$04, which need their padding for
    /// their own 5-byte stubs. The tail is the right unit — it is where
    /// `findFreeSpace` allocates from, so thunks filling the head of the
    /// same run cost the copies nothing.
    keep_bank: u32 = 0,
    keep_lo: u32 = 0,
    keep_hi: u32 = 0,

    /// Padding in ONE named bank, for a stub that must share its site's
    /// bank (a bank-local JMP/JSR/RTS shape). A fresh scan each call:
    /// everything handed out before has been written, so it reads as
    /// occupied — callers must write exactly what they asked for. Bank
    /// $00 keeps the carve reserved.
    fn nextIn(self: *@This(), bank: u32, need: u32, res_at: u32, res_len: u32) ?u32 {
        var pa = padAllocFor(self.out, self.header_off, bank, res_at, res_len);
        return pa.next(need);
    }

    fn next(self: *@This(), need: u32) ?u32 {
        if (self.bank == 0) {
            // >2 MiB: file banks $40+ live at CPU $A0-$BF through the
            // Super MMC — a far body placed there and addressed by its
            // FILE bank fetches the wrong megabyte (measured: a context
            // thunk at $10:B6C8 called $5F:D777, marched the DXB fade
            // tables, and BRK'd into the crash trap). The far pool stays
            // in the identity banks.
            self.bank = @intCast(@min((self.out.len + 0x7FFF) / 0x8000, 0x40) - 1);
        }
        while (self.bank >= 1) {
            if (self.pad == null) self.pad = if (self.bank == self.keep_bank)
                padAllocFor(self.out, self.header_off, self.bank, self.keep_lo, self.keep_hi - self.keep_lo)
            else
                padAllocFor(self.out, self.header_off, self.bank, 0, 0);
            if (self.pad.?.next(need)) |at| return at;
            self.pad = null;
            self.bank -= 1;
        }
        if (dbg_thunk_pad)
            std.debug.print("[farpad] EXHAUSTED for {} bytes\n", .{need});
        return null;
    }
};

/// How much of the biggest padding run to keep back for offload tree
/// copies. Gradius III's two trees are 397 and 1324 bytes plus their
/// stubs and fence — a shade over 2 KB — and 2.5 KiB leaves headroom
/// without starving the thunk bodies, which have the rest of the image.
pub const copy_reserve: u32 = 2560;

/// The single biggest $FF run outside bank $00 — the one `findFreeSpace`
/// will hand the offload tree copies, and whose tail `FarPad` keeps back
/// for them. Returns its bank and its END file offset (exclusive).
const BigRun = struct { bank: u32 = 0, end: u32 = 0, len: u32 = 0 };
fn biggestRun(out: []const u8, header_off: u32) BigRun {
    var best: BigRun = .{};
    var bank: u32 = 1;
    while (bank * 0x8000 < out.len and bank < 0x40) : (bank += 1) {
        const lo = bank * 0x8000;
        const region = out[lo..@min(lo + 0x8000, out.len)];
        var i: usize = 0;
        while (i < region.len) {
            if (region[i] != 0xFF) {
                i += 1;
                continue;
            }
            var j = i + 1;
            while (j < region.len and region[j] == 0xFF) j += 1;
            const len: u32 = @intCast(j - i);
            if (len > best.len) best = .{ .bank = bank, .end = @intCast(lo + j), .len = len };
            i = j;
        }
        _ = header_off;
    }
    return best;
}

/// Bank-local stub for a thunk body that had to go to another bank:
/// `JSL far / RTS`. The body ends in RTL instead of RTS, so the pair
/// returns to the site exactly as an in-bank thunk would, and the two
/// pushes the body indexes off the stack ($02,S) sit at the same depth
/// either way. Five bytes of the pressured bank instead of thirty-five.
const far_stub_len: u32 = 5;

/// Place one thunk body for a site and return the address its `JSR` should
/// name. Prefers the site's own bank; falls back to the stub-plus-far-body
/// shape. `near` and `far_body` are the same template with RTS/RTL tails.
fn placeThunk(out: []u8, local: *PadAlloc, far: *FarPad, near: []const u8, far_body: []const u8, force_far: bool, n_far: *u16) ?u16 {
    if (!force_far) {
        if (local.next(@intCast(near.len))) |at| {
            @memcpy(out[at..][0..near.len], near);
            return @intCast(0x8000 + (at % 0x8000));
        }
        local.rewind();
    }
    n_far.* += 1;
    const stub = local.next(far_stub_len) orelse return null;
    const body = far.next(@intCast(far_body.len)) orelse return null;
    @memcpy(out[body..][0..far_body.len], far_body);
    out[stub] = 0x22; // JSL
    std.mem.writeInt(u16, out[stub + 1 ..][0..2], @as(u16, @intCast(0x8000 + (body % 0x8000))), .little);
    out[stub + 3] = @intCast(body / 0x8000);
    out[stub + 4] = 0x60; // RTS
    return @intCast(0x8000 + (stub % 0x8000));
}

/// The cold-site dispatcher: ONE shared far-stub per pressured bank,
/// however many unmeasured split sites the bank carries.
///
/// The per-thunk far stub already cut a body's bank cost from ~35 bytes
/// to 5, and Gradius III still refused: bank $02 keeps its entire slack
/// in one 149-byte run, and the population that needs stubs there is the
/// UNMEASURED one — tiny-base indexed sites the profile never reached —
/// which grows with every cover movie harvested. Five bytes per site is
/// a ceiling coverage itself walks into.
///
/// So the unmeasured sites of a bank that cannot afford per-thunk stubs
/// all `JSR` to one shared `JSL dispatcher / RTS` stub, and the
/// dispatcher works out which site called by the return address the JSR
/// itself pushed: binary search over a sorted (site -> body) table, then
/// a jump into the same RTL-tailed body a per-thunk far stub would have
/// named. The body cannot tell the difference — it sees the identical
/// [3-byte JSL frame][2-byte JSR return] stack — so every thunk template
/// is reused unchanged, flags set by the body's op included (RTS/RTL do
/// not touch P).
///
/// The search runs with interrupts live and no memory scratch: state
/// lives on the stack, the jump target is written into a 3-byte hole
/// reserved BELOW the saved registers, and an `RTL` consumes it after
/// the registers are restored — reentrant against any NMI, including one
/// that dispatches through this same code.
///
/// The price is ~150 cycles per call, paid only by sites that never
/// executed once across every profiled surface.
const cold_disp_len: u32 = 106;
fn coldDispatcherBody(table: u24, n_records: u16) [cold_disp_len]u8 {
    const t0 = table;
    const t2 = table + 2;
    const t4 = table + 4;
    const t6 = table + 6;
    const end: u16 = n_records * 8;
    // Stack during the search, from S: $01-$02 key (the site's address),
    // $03-$04 hi, $05-$06 saved Y, $07-$08 X, $09-$0A A, $0B P,
    // $0C-$0E the RTL hole, $0F-$11 the stub's JSL frame (PBR at $11 is
    // the SITE's bank), $12-$13 the site's JSR return address.
    return .{
        0x4B, 0x4B, 0x4B, // PHK x3 — the RTL target's hole
        0x08, // PHP
        0xC2, 0x30, // REP #$30
        0x48, 0xDA, 0x5A, // PHA / PHX / PHY
        0xF4, 0x00, 0x00, // PEA 0 — hi
        0xF4, 0x00, 0x00, // PEA 0 — key
        0xA3, 0x12, // LDA $12,S — the JSR pushed site+2
        0x3A, 0x3A, // DEC A x2 — the site itself
        0x83, 0x01, // STA $01,S
        0xA9, @truncate(end), @truncate(end >> 8), // LDA #records*8
        0x83, 0x03, // STA $03,S — hi (exclusive)
        0xA0, 0x00, 0x00, // LDY #0 — lo
        // loop (29): mid = ((lo + hi) / 2) floored to a record
        0x98, 0x18, 0x63, 0x03, // TYA / CLC / ADC $03,S
        0x4A, // LSR
        0x29, 0xF8, 0xFF, // AND #$FFF8
        0xAA, // TAX
        0xA3, 0x01, // LDA $01,S — key
        0xDF, @truncate(t0), @truncate(t0 >> 8), @truncate(t0 >> 16), // CMP table,X — record.addr16
        0xF0, 0x0F, // BEQ bank_cmp (61)
        0x90, 0x08, // BCC go_left (56)
        // right (48): lo = mid + 8
        0x8A, 0x18, 0x69, 0x08, 0x00, 0xA8, // TXA / CLC / ADC #8 / TAY
        0x80, 0xE5, // BRA loop
        // go_left (56): hi = mid
        0x8A, 0x83, 0x03, // TXA / STA $03,S
        0x80, 0xE0, // BRA loop
        // bank_cmp (61): addr16 matched; order by bank on ties
        0xE2, 0x20, // SEP #$20
        0xA3, 0x11, // LDA $11,S — the site's PBR
        0x29, 0x7F, // AND #$7F — fast mirrors fold onto the file bank
        0xDF, @truncate(t2), @truncate(t2 >> 8), @truncate(t2 >> 16), // CMP table+2,X — record.bank
        0xC2, 0x20, // REP #$20 — Z and C survive the width change
        0xF0, 0x04, // BEQ found (79)
        0x90, 0xEB, // BCC go_left
        0x80, 0xE1, // BRA right
        // found (79): body-1 into the hole, drop scratch, restore, RTL
        0xBF, @truncate(t4), @truncate(t4 >> 8), @truncate(t4 >> 16), // LDA table+4,X
        0x83, 0x0C, // STA $0C,S — hole PC
        0xE2, 0x20, // SEP #$20
        0xBF, @truncate(t6), @truncate(t6 >> 8), @truncate(t6 >> 16), // LDA table+6,X
        0x83, 0x0E, // STA $0E,S — hole PBR
        0xC2, 0x20, // REP #$20
        0x3B, 0x18, 0x69, 0x04, 0x00, 0x1B, // TSC / CLC / ADC #4 / TCS — drop hi+key
        0x7A, 0xFA, 0x68, 0x28, // PLY / PLX / PLA / PLP
        0x6B, // RTL — into the body; JSL frame and JSR return intact
    };
}

/// The DBR-dispatch thunk body (see the emission comment in
/// convertWholeGame). `ret` is RTS in-bank, RTL behind a far stub.
fn splitThunkBody(op: u8, v: u16, ret: u8) [split_thunk_len]u8 {
    const sh: u16 = v + wg_bw_window;
    return .{
        0x08, 0xE2, 0x20, 0x48, 0x8B, 0x68, // PHP/SEP#$20/PHA/PHB/PLA
        0x30, 0x0A, 0x89, 0x40,          0xF0,               0x06, // BMI sys / BIT #$40 / BEQ sys
        0x68, 0x28, op,   @truncate(v),  @truncate(v >> 8),  ret,
        0x68, 0x28, op,   @truncate(sh), @truncate(sh >> 8), ret,
    };
}

/// The LONG,X index-dispatch thunk: 29 bytes, always entered by `JSL` and
/// always leaving by `RTL`, so it needs no bank-local home.
///
/// No DBR test — a long access names its bank in the operand, so the only
/// question is the index, and the answer is the same two-way split the
/// absolute flavor makes: an index small enough to stay under $2000 is
/// addressing the low mirror (which moved), anything bigger is walking ROM
/// through the same bytes (which did not). The x8 arm short-circuits for
/// the same reason it does there: an 8-bit index over a tiny base cannot
/// leave the low page, and a 16-bit CPX immediate would misparse anyway.
///
///   PHP / SEP #$20 / PHA / LDA $02,S / BIT #$10 / BNE low
///   CPX #($2000-v) / BCS rom
///   low: PLA / PLP / op b:v+$6000,X / RTL
///   rom: PLA / PLP / op b:v,X       / RTL
const long_thunk_len: u32 = 29;
fn longThunkBody(op: u8, v: u16, bank: u8) [long_thunk_len]u8 {
    const sh: u16 = v + wg_bw_window;
    const lim: u16 = 0x2000 - v;
    return .{
        0x08, 0xE2, 0x20, 0x48, // PHP / SEP #$20 / PHA
        0xA3, 0x02, 0x89, 0x10, 0xD0, 0x05, // LDA $02,S / BIT #$10 / BNE low
        0xE0, @truncate(lim), @truncate(lim >> 8), 0xB0, 0x07, // CPX #lim / BCS rom
        0x68, 0x28, op, @truncate(sh), @truncate(sh >> 8), bank, 0x6B, // low
        0x68, 0x28, op, @truncate(v), @truncate(v >> 8), bank, 0x6B, // rom
    };
}

/// The tiny-base `long,X` thunk WITH the forward-wrap arm. The ceiling
/// body's guard asks only `X < $2000 - v` — but a huge X wraps the
/// 24-bit sum into the NEXT bank's low page, the same mirror the
/// negative-base body was built for (measured: the door-transition
/// loader called `LDA $A0:003E,X` with X=$FFCF — effective $A1:000D,
/// WRAM $0D — and the ceiling guard sent it down the ROM arm, so the
/// room state loaded stale and the screen faded to black for good).
/// No third read arm: `long,X` carries into bank+1 in hardware, so the
/// shifted operand serves both low windows — the guard just routes
/// X >= $10000 - v to it. Emitted only when bank+1 carries a window
/// ((bank & $7F) < $3F); a $3F/$BF/$7D base keeps the ceiling body.
///
///   PHP / SEP #$20 / PHA / LDA $02,S / BIT #$10 / BNE low
///   CPX #($2000-v)  / BCC low   ; small index: this bank's mirror
///   CPX #($10000-v) / BCC rom   ; big but unwrapped: ROM
///   low: PLA / PLP / op b:v+$6000,X / RTL   ; wrap carries to b+1
///   rom: PLA / PLP / op b:v,X       / RTL
const long_wrap_thunk_len: u32 = 34;
fn longThunkBodyWrap(op: u8, v: u16, bank: u8) [long_wrap_thunk_len]u8 {
    const sh: u16 = v + wg_bw_window;
    const lim: u16 = 0x2000 - v;
    const wl: u16 = @intCast(0x10000 - @as(u32, v));
    return .{
        0x08, 0xE2, 0x20, 0x48, // PHP / SEP #$20 / PHA
        0xA3, 0x02, 0x89, 0x10, 0xD0, 0x0A, // LDA $02,S / BIT #$10 / BNE low
        0xE0, @truncate(lim), @truncate(lim >> 8), 0x90, 0x05, // CPX #lim / BCC low
        0xE0, @truncate(wl), @truncate(wl >> 8), 0x90, 0x07, // CPX #wl / BCC rom
        0x68, 0x28, op, @truncate(sh), @truncate(sh >> 8), bank, 0x6B, // low
        0x68, 0x28, op, @truncate(v), @truncate(v >> 8), bank, 0x6B, // rom
    };
}

/// The HDMA indirect-bank ($43x7 DASB) rebank thunk. An indirect HDMA whose
/// per-scanline source is WRAM names that WRAM bank in DASB, and the value
/// is loaded from the channel's HDMA object (a ROM table) — not an
/// immediate or a long operand — so no static rebanker can reach it. The
/// register write itself is wrapped: on the way to `STA $43x7`, an 8-bit A
/// holding $7E/$7F becomes $40/$41, so DASB follows its data into BW-RAM;
/// any other bank passes through untouched, which makes the thunk sound on
/// every DASB write, whatever the value's origin. `store` is the site's own
/// three operand bytes (STA abs / abs,X / abs,Y — same 3-byte footprint the
/// JSR replaces), replayed here with the remapped value; the caller's exact
/// A and flags are restored, so a store that sat inside a CMP/branch pair or
/// left A live behaves byte-for-byte as in situ. `ret` is RTS in-bank, RTL
/// behind a far stub. SEP #$20 forces the byte width the register demands
/// regardless of the caller's M (the PHA/PLA then move exactly one byte).
const dasb_thunk_len: u32 = 21;
fn dasbThunkBody(store: [3]u8, ret: u8) [dasb_thunk_len]u8 {
    return .{
        0x08, // PHP
        0xE2, 0x20, // SEP #$20 — DASB is a byte register
        0x48, // PHA — save the caller's value
        0xC9, 0x7E, // CMP #$7E
        0x90, 0x07, // BCC store — A < $7E, no WRAM bank
        0xC9, 0x80, // CMP #$80
        0xB0, 0x03, // BCS store — A >= $80, not $7E/$7F
        0x38, 0xE9, 0x3E, // SEC / SBC #$3E — $7E->$40, $7F->$41
        store[0], store[1], store[2], // STA $43x7[,X/Y] (remapped or as-is)
        0x68, // PLA — restore the caller's value
        0x28, // PLP
        ret,
    };
}

/// The A-bus bank (A1B, $43x4) runtime rebank thunk body: the FULL misfit
/// map, because a staged DMA source bank can carry any mirror-intent value —
/// $7E/$7F (WRAM -> BW-RAM, -$3E), $A0-$BF (mirror-of-MB1 intent that the
/// shim parks at MB2, -$80), $C0-$DF (MB2 content homed $20 lower, -$20).
/// Measured: Super Metroid's escape arms `$B0:C400 -> vdest $7000` through a
/// staged bank byte the provenance never proved; the transfer read the MB2
/// home (file $284400) instead of MB1 ($184400) and the door's second OBJ
/// tile table arrived as confetti. Banks $00-$3F and $80-$9F pass through
/// (region 2 restores that mirror). Same calling convention as the DASB
/// body: the JSR replaces the 3-byte store; A and P are preserved.
const a1b_thunk_len: u32 = 37;
fn a1bThunkBody(store: [3]u8, ret: u8) [a1b_thunk_len]u8 {
    // Branch offsets audited by simulation; store at body index 31.
    return .{
        0x08, // PHP
        0xE2, 0x20, // SEP #$20
        0x48, // PHA
        0xC9, 0x7E, // CMP #$7E
        0x90, 0x17, // BCC store — plain banks $00-$7D
        0xC9, 0x80, // CMP #$80
        0xB0, 0x05, // BCS mirror-region checks
        0x38, 0xE9, 0x3E, // SEC / SBC #$3E — $7E/$7F -> $40/$41
        0x80, 0x0E, // BRA store
        0xC9, 0xA0, // CMP #$A0
        0x90, 0x0A, // BCC store — $80-$9F: genuine mirror
        0xC9, 0xC0, // CMP #$C0
        0xB0, 0x04, // BCS hi
        0xE9, 0x7F, // SBC #$7F (carry clear) — $A0-$BF -> -$80
        0x80, 0x02, // BRA store
        0xE9, 0x20, // hi: SBC #$20 (carry set) — $C0-$DF -> -$20
        store[0], store[1], store[2], // STA $43x4[,X/Y]
        0x68, // PLA
        0x28, // PLP
        ret,
    };
}

/// Wrap every covered `STA $43x7` (a channel's DASB — the indirect HDMA
/// source bank) in a runtime rebank thunk. When an indirect HDMA's source
/// is WRAM, the game names the WRAM bank in DASB, and that bank is a byte
/// loaded from the channel's HDMA object (a ROM table) — not an immediate
/// or a long operand, so no static rebanker can reach it. Super Metroid's
/// Ceres alarm is the witness: its color-math COLDATA HDMA reads a
/// per-scanline gradient the game builds into live BW-RAM ($40), but its
/// object still names bank $7E, so the hardware fetches the abandoned copy
/// and the escape room renders as stripes while its logic runs correctly.
/// The remap ($7E/$7F->$40/$41) is a no-op for a ROM or already-BW-RAM
/// bank, so wrapping is sound on every DASB write whatever the value's
/// origin — any DASB that named $7E/$7F on stock must name $40/$41 here.
///
/// A separate function from convertWholeGame on purpose: its own working
/// set (the per-bank PadAlloc) stays out of that already-deep frame.
fn rebankDasbWrites(
    out: []u8,
    cov: []const u8,
    header_off: u32,
    carve: u32,
    carve_len: u32,
    far: *FarPad,
    refusal: *?Refusal,
    res: *Result,
) Error!void {
    var dasb_pad: PadAlloc = undefined;
    var dasb_pad_bank: u32 = 0xFFFF;
    var dbank: u32 = 0;
    while (dbank < 0x40) : (dbank += 1) {
        const bank_file = dbank * 0x8000;
        if (bank_file >= out.len) break;
        var a16: u32 = 0x8000;
        while (a16 < 0x10000) : (a16 += 1) {
            const cpu_addr = (dbank << 16) | a16;
            const fl_lo = cov[cpu_addr];
            const fl_hi = cov[0x80_0000 | cpu_addr];
            if ((fl_lo | fl_hi) & usage_map.flag_opcode == 0) continue;
            const file = bank_file + (a16 - 0x8000);
            if (file + 3 > out.len) continue;
            const op = out[file];
            // STA abs / abs,X / abs,Y whose target is a $43x7 register:
            // column 7 is DASB. abs,X/abs,Y index by channel*$10, so the
            // base already names column 7; abs names the channel outright.
            switch (op) {
                0x8D, 0x9D, 0x99 => {},
                else => continue,
            }
            const tgt = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
            if (tgt < 0x4300 or tgt > 0x437F) continue;
            const col = tgt & 0xF;
            // Column 7 (DASB) always; column 4 (A1B) on >2 MiB images, where
            // an unmapped mirror-intent bank sources the wrong megabyte.
            if (col != 7 and !(col == 4 and out.len > 0x20_0000)) continue;
            // The register is a byte, and the thunk compares an 8-bit A; a
            // 16-bit store here would be writing DASB+A2A-low as a word, not
            // a plain bank set — leave that shape untouched.
            const fl = if (fl_lo & usage_map.flag_opcode != 0) fl_lo else fl_hi;
            if (fl & usage_map.flag_m == 0) continue;
            if (dbank != dasb_pad_bank) {
                dasb_pad = padAllocFor(out, header_off, dbank, carve, carve_len);
                dasb_pad_bank = dbank;
            }
            const store: [3]u8 = out[file..][0..3].*;
            const taddr = (if (col == 7)
                placeThunk(out, &dasb_pad, far, &dasbThunkBody(store, 0x60), &dasbThunkBody(store, 0x6B), false, &res.stats.split_far)
            else
                placeThunk(out, &dasb_pad, far, &a1bThunkBody(store, 0x60), &a1bThunkBody(store, 0x6B), false, &res.stats.split_far)) orelse
                return refuse(refusal, .{ .reason = .no_free_space, .detail = a1b_thunk_len });
            out[file] = 0x20; // JSR — same 3-byte footprint as the store
            std.mem.writeInt(u16, out[file + 1 ..][0..2], taddr, .little);
            res.stats.rewritten_dasb += 1;
        }
    }
}

/// The file offset a runtime CPU address reads from, under the window
/// conversion's map. A <=2 MiB image is plain LoROM; a >2 MiB image follows
/// the shim's Super-MMC programming ($00-$1F/$80-$9F -> MB0, $20-$3F -> MB1,
/// $A0-$BF -> MB2), which is where the de-mirror pass parks the content.
/// Only ROM homes are mapped; a bank with no fixed ROM home returns null.
pub fn loromFileOffset(image_len: usize, cpu: u24) ?usize {
    const bank: u32 = (cpu >> 16) & 0xFF;
    const a16: u32 = cpu & 0xFFFF;
    if (a16 < 0x8000) return null;
    const off: usize = a16 - 0x8000;
    const file: usize = if (image_len <= 0x20_0000)
        (bank & 0x7F) * 0x8000 + off
    else if (bank < 0x20 or (bank >= 0x80 and bank < 0xA0))
        (bank & 0x1F) * 0x8000 + off // MB0
    else if (bank >= 0x20 and bank < 0x40)
        (bank - 0x20) * 0x8000 + 0x10_0000 + off // MB1
    else if (bank >= 0xA0 and bank < 0xC0)
        (bank - 0xA0) * 0x8000 + 0x20_0000 + off // MB2
    else
        return null;
    return if (file < image_len) file else null;
}

/// Relocate low-WRAM indirect addresses inside the profiled indirect-HDMA
/// tables (window mode; see PtrBankEvidence.hdma_tables and the Ceres
/// escape). Each table is a run of `[line-count][addr-lo][addr-hi]` entries
/// terminated by a zero count; an entry whose 16-bit indirect address names
/// the moved low 8 KiB (< $2000) is shifted +$6000 so the DMA unit fetches
/// the relocated buffer through the window instead of the abandoned physical
/// mirror. The count byte's bit 7 (repeat vs. continuous) does not change the
/// three-byte stride. Bounded against a table whose terminator was itself a
/// relocated byte, and skips a table whose home is not statically mappable.
fn relocateHdmaIndirect(out: []u8, tables: []const u24, res: *Result) void {
    for (tables) |cpu| {
        var f = loromFileOffset(out.len, cpu) orelse continue;
        var guard: usize = 0;
        while (guard < 256) : (guard += 1) {
            if (f + 3 > out.len) break;
            if (out[f] == 0) break; // zero line-count ends the table
            const addr = std.mem.readInt(u16, out[f + 1 ..][0..2], .little);
            if (addr < 0x2000) {
                std.mem.writeInt(u16, out[f + 1 ..][0..2], addr + wg_bw_window, .little);
                res.stats.rewritten_hdma_indirect += 1;
            }
            f += 3;
        }
    }
}

/// Bank immediates bound for a dispatch queue, BY SIGNATURE, coverage or
/// not — the same stance as the `STA $00 / JMP ($0000)` macro net, and for
/// the same reason: post-fork trajectories pull queue entries no finite
/// stock profile can lead to. The shape is Super Metroid's sound-library
/// enqueue:
///
///     consumer:  LDA $6FA6,X ... XBA / PHA / PLB / PLB
///                (bank in the loaded word's LOW byte: the column it
///                loads from is a BANK COLUMN)
///     producer:  LDA #$00A3 ... STA $6FA6,X
///                (the bank travels as a 16-bit immediate, consumed
///                thousands of cycles later by different code)
///
/// The measured pointer-bank net re-banks the producers a profiled run
/// executed; a missed one BRKs into the game's crash trap on the first
/// off-profile timeline that pulls its entry (measured: Super Metroid's
/// attract, where the conversion's own lag differential queues a handler
/// stock timing never queues — and the evidence loop can never close it,
/// because every cover replay dies at that BRK before the PLB proves the
/// byte). The consumer's XBA/PHA/PLB/PLB tail names the column
/// statically; every producer keyed on that exact column then re-banks by
/// the same de-mirror map as the measured net. Columns are matched in
/// their POST-rewrite window form ($6000-$7FFF), so the pass runs after
/// the operand rewrites and never invents a column the walk did not
/// already move.
fn demirrorQueueBankImms(out: []u8, wide: bool) u32 {
    // Pass 1: bank columns, from the consumer signature. The XBA/PHA/
    // PLB/PLB tail is the key; the column is the last `LDA abs,X` with a
    // window operand in the handful of bytes before it.
    var cols: [16]u16 = undefined;
    var n_cols: usize = 0;
    var f: usize = 0;
    while (f + 4 <= out.len) : (f += 1) {
        if (!(out[f] == 0xEB and out[f + 1] == 0x48 and out[f + 2] == 0xAB and out[f + 3] == 0xAB)) continue;
        var col: ?u16 = null;
        var b: usize = f -| 12;
        while (b + 3 <= f) : (b += 1) {
            if (out[b] != 0xBD) continue;
            const v = std.mem.readInt(u16, out[b + 1 ..][0..2], .little);
            if (v >= wg_bw_window and v < wg_bw_window + 0x2000) col = v;
        }
        const c = col orelse continue;
        var known = false;
        for (cols[0..n_cols]) |e| {
            if (e == c) known = true;
        }
        if (!known and n_cols < cols.len) {
            cols[n_cols] = c;
            n_cols += 1;
        }
    }
    // Pass 2: producers keyed on those exact columns.
    var n: u32 = 0;
    for (cols[0..n_cols]) |c| {
        f = 0;
        while (f + 6 <= out.len) : (f += 1) {
            if (out[f] != 0xA9 or out[f + 2] != 0x00 or out[f + 3] != 0x9D) continue;
            if (std.mem.readInt(u16, out[f + 4 ..][0..2], .little) != c) continue;
            const bank = out[f + 1];
            if (bank == 0x7E or bank == 0x7F) {
                out[f + 1] = bank - 0x3E; // WRAM -> BW-RAM $40/$41
            } else if (wide and bank >= 0xA0 and bank <= 0xBF) {
                out[f + 1] = bank - 0x80; // MB1 mirror -> its de-mirror home
            } else if (wide and bank >= 0xC0 and bank <= 0xDF) {
                out[f + 1] = bank - 0x20; // misfit bank -> its parked home
            } else continue;
            n += 1;
        }
    }
    return n;
}

/// Mirror-bank `JSL`s in code no surface reached, re-banked on the evidence
/// of their own de-mirrored twin.
///
/// Three of the six freezes Super Metroid's players found (findings §4f)
/// were one shape: a `JSL $A0-$BF:addr` at a site byte-identical to stock.
/// Nothing flags it — it is simply code no surface executed and the static
/// walk never reached, and the de-mirror pass above is coverage-gated.
/// Under the shim, region 3 carries MB2, so the call lands in a different
/// megabyte and BRKs. A census of one build found 51 distinct targets
/// across 628 call sites: one freeze per play session, indefinitely.
///
/// The proof that needs no coverage is the routine's OWN de-mirrored form.
/// In the CONVERTED image the same entry is already called as
/// `JSL $20-$3F:addr` by code that IS covered, and called repeatedly — the
/// observed counts run 20-77 per target. (Stock has no such call: Super
/// Metroid reaches everything through $80-$DF. The twin is minted by the
/// coverage-gated de-mirror pass, and this pass spends it.) So the mirror form names MB1 content, and re-banking it -$80 is
/// exactly the rewrite the de-mirror pass would have made had a surface
/// reached the site.
///
/// Two consequences of keying on the twin, both load-bearing:
///
///   * It stays off data. A byte triple in compressed graphics must be
///     preceded by `$22` AND match one of a few dozen specific 24-bit entry
///     addresses; over a 3 MiB image that is ~0.04 expected false hits.
///   * It introduces no new code for the walk to arbitrate. A covered call
///     to the twin is *why* the body is evidenced, so `extendCoverage` has
///     already walked and rewritten it (`$A0 & 0x7F` is `$20` — the walk's
///     LoROM fold happens to be the de-mirror for this range). This net
///     rewrites operands only, which is what makes it landable where a
///     blind 628-byte rewrite was not.
fn demirrorTwinJsls(gpa: std.mem.Allocator, image: []const u8, out: []u8, cov: []const u8) !u32 {
    // Covered calls per de-mirrored target, indexed by bank $20-$3F and
    // addr16 >= $8000 — the only shape a twin can have. Saturating u8.
    const calls = try gpa.alloc(u8, 0x20 * 0x8000);
    defer gpa.free(calls);
    @memset(calls, 0);

    var bank: u32 = 0;
    while (bank < 0x40) : (bank += 1) {
        const bank_file = bank * 0x8000;
        if (bank_file >= image.len) break;
        var a16: u32 = 0x8000;
        while (a16 < 0x1_0000) : (a16 += 1) {
            const cpu = (bank << 16) | a16;
            if ((cov[cpu] | cov[0x80_0000 | cpu]) & usage_map.flag_opcode == 0) continue;
            const file = bank_file + (a16 - 0x8000);
            // Read the CONVERTED image: stock never writes the $20-$3F form
            // (Super Metroid calls everything through $80-$DF), so the twin
            // exists only after the coverage-gated de-mirror pass above has
            // rewritten the covered sites. That pass is what mints the
            // evidence this one spends.
            if (file + 3 >= image.len or out[file] != 0x22) continue;
            const tb = out[file + 3];
            if (tb < 0x20 or tb > 0x3F) continue;
            const t = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
            if (t < 0x8000) continue;
            const idx = (@as(usize, tb - 0x20) << 15) | (t - 0x8000);
            if (calls[idx] != 0xFF) calls[idx] += 1;
        }
    }

    // Now the sites nothing reached. Scanned over the whole file, because
    // "the walk never got here" is the defining property of the class.
    var n: u32 = 0;
    var file: usize = 0;
    while (file + 3 < image.len) : (file += 1) {
        if (image[file] != 0x22) continue;
        const bk = image[file + 3];
        if (bk < 0xA0 or bk > 0xBF) continue;
        if (out[file + 3] != bk) continue; // already rewritten; not ours
        const t = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
        if (t < 0x8000) continue;
        const idx = (@as(usize, bk - 0xA0) << 15) | (t - 0x8000);
        if (calls[idx] < 2) continue; // one call is a coincidence
        out[file + 3] = bk - 0x80;
        n += 1;
    }
    return n;
}

test "demirrorTwinJsls: twin evidence re-banks the mirror form, once is not enough" {
    const gpa = testing.allocator;
    var img: [0x18_0000]u8 = @splat(0);
    // Two covered calls to $A0:C0AE, in bank $00 at $8000 and $8004. Stock
    // spells them the mirror way; the de-mirror pass has already re-banked
    // them in `out`, which is the only place the twin evidence exists.
    img[0] = 0x22;
    img[1] = 0xAE;
    img[2] = 0xC0;
    img[3] = 0xA0;
    img[4] = 0x22;
    img[5] = 0xAE;
    img[6] = 0xC0;
    img[7] = 0xA0;
    // One covered call to $21:9000 — evidenced only once.
    img[8] = 0x22;
    img[9] = 0x00;
    img[10] = 0x90;
    img[11] = 0x21;
    // Uncovered mirror forms of both, plus a mirror JSL to an unevidenced
    // target and one whose addr16 is not in the ROM half.
    const u = 0x10_0000;
    img[u + 0] = 0x22;
    img[u + 1] = 0xAE;
    img[u + 2] = 0xC0;
    img[u + 3] = 0xA0; // -> re-banked
    img[u + 4] = 0x22;
    img[u + 5] = 0x00;
    img[u + 6] = 0x90;
    img[u + 7] = 0xA1; // one twin call only -> left alone
    img[u + 8] = 0x22;
    img[u + 9] = 0x34;
    img[u + 10] = 0xD2;
    img[u + 11] = 0xB7; // no twin evidence -> left alone
    img[u + 12] = 0x22;
    img[u + 13] = 0x10;
    img[u + 14] = 0x00;
    img[u + 15] = 0xA0; // addr16 below $8000 -> left alone

    const cov = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(cov);
    @memset(cov, 0);
    for ([_]u32{ 0x008000, 0x008004, 0x008008 }) |c| cov[c] = usage_map.flag_opcode;

    var out: [0x18_0000]u8 = img;
    out[3] = 0x20; // what the coverage-gated de-mirror pass produced
    out[7] = 0x20;
    try testing.expectEqual(@as(u32, 1), try demirrorTwinJsls(gpa, &img, &out, cov));
    try testing.expectEqual(@as(u8, 0x20), out[u + 3]);
    try testing.expectEqual(@as(u8, 0xA1), out[u + 7]);
    try testing.expectEqual(@as(u8, 0xB7), out[u + 11]);
    try testing.expectEqual(@as(u8, 0xA0), out[u + 15]);
}


/// Super Metroid's room-state level-data pointers, re-banked by walking the
/// room graph instead of waiting for a surface to load each state.
///
/// Every room state carries a 3-byte pointer to its compressed level data,
/// and every one of them names MB2 ($C2-$CE). Under the >2 MiB shim MB2
/// lives $20 lower, so the byte must become $A2-$AE — and the only pass
/// that does that is `hi_proven`, which needs the profile to have watched
/// the loader read that exact byte. A state no surface ever loaded keeps
/// its stock bank, the decompressor ($80:B0FF) reads the wrong megabyte,
/// and the room arrives with no geometry at all: Samus walks through walls
/// into a phantom special block and Super Metroid's own `BRA *` assertion
/// at $84:B3A6 (measured 2026-09-02 on the Ceres escape states). One build
/// had 40 such bytes proven against ~750 untouched — every room past the
/// first door off the landing site.
///
/// No shape identifies the byte on its own (a `$CD` after a word is common
/// in a bank of tables), but the structure that reaches it is exact and
/// finite: door headers ($83) name rooms ($8F); a room's condition list
/// names its states; a state's first three bytes are the pointer. The walk
/// starts at the landing site and follows doors until it runs out. It is
/// all-or-nothing on the rewrite side: any state that fails validation
/// refuses the whole pass, because a misparse here rewrites data. A door
/// whose destination does not look like a room header is skipped, not
/// fatal — elevators and one-way transitions name no room.
///
/// Reads STOCK bytes (`image`); a bank byte `hi_proven` already re-banked
/// in `out` is left as it is.
pub const SmRoomWalk = struct {
    rooms: u32 = 0,
    states: u32 = 0,
    rebanked: u32 = 0,
    /// Background (library) records processed, and their source banks
    /// de-mirrored (see the BG pass in `rebankSmRoomLevelPointers`).
    bg_records: u32 = 0,
    bg_banks: u32 = 0,
    /// Non-zero when the pass refused: the $8F address of the header that
    /// failed validation. Nothing was rewritten.
    refused_at: u32 = 0,
};

fn smConditionArgBytes(cond: u16) ?u8 {
    // Each condition routine's skip path is `INX` x (args + 2) / `RTS`; these
    // widths are read off those routines in bank $8F.
    return switch (cond) {
        0xE5EB => 2, // entered through door X
        0xE612, 0xE629 => 1, // boss bit / event bit in the current area
        0xE5FF, 0xE640, 0xE652, 0xE669, 0xE678 => 0,
        else => null,
    };
}

fn rebankSmRoomLevelPointers(gpa: std.mem.Allocator, image: []const u8, out: []u8) !SmRoomWalk {
    const f8f: usize = 0x0F * 0x8000; // bank $8F: room + state headers
    const f83: usize = 0x03 * 0x8000; // bank $83: door headers
    var walk: SmRoomWalk = .{};
    if (image.len < f8f + 0x8000) return walk;
    const R = struct {
        img: []const u8,
        fn b(self: @This(), base: usize, a16: u32) u8 {
            return self.img[base + (a16 - 0x8000)];
        }
        fn w(self: @This(), base: usize, a16: u32) u16 {
            return std.mem.readInt(u16, self.img[base + (a16 - 0x8000) ..][0..2], .little);
        }
        fn looksLikeRoom(self: @This(), a16: u32) bool {
            if (a16 < 0x8000 or a16 > 0xFFFF - 0x0B - 2) return false;
            const area = self.b(f8f, a16 + 1);
            const wd = self.b(f8f, a16 + 4);
            const ht = self.b(f8f, a16 + 5);
            return area < 8 and wd >= 1 and wd <= 16 and ht >= 1 and ht <= 16 and self.w(f8f, a16 + 9) >= 0x8000;
        }
    };
    const r: R = .{ .img = image };

    const visited = try gpa.alloc(bool, 0x8000);
    defer gpa.free(visited);
    @memset(visited, false);
    var queue: [1024]u16 = undefined;
    var qn: usize = 0;
    var states: [2048]u32 = undefined;
    var sn: usize = 0;

    // Two roots, because the door graph has two components: Zebes hangs
    // off the landing site, and Ceres is entered by the new-game warp and
    // left by the escape warp — no door crosses between them. A root that
    // does not parse as a room is skipped (a different revision), not fatal.
    for ([_]u16{ 0x91F8, 0xDF45 }) |root| {
        if (!r.looksLikeRoom(root) or visited[root - 0x8000]) continue;
        visited[root - 0x8000] = true;
        queue[qn] = root;
        qn += 1;
    }
    if (qn == 0) return walk;

    var qi: usize = 0;
    while (qi < qn) : (qi += 1) {
        const room: u32 = queue[qi];
        walk.rooms += 1;
        // Condition list -> states, then the inline default state.
        var p: u32 = room + 11;
        var guard: u8 = 0;
        while (true) : (guard += 1) {
            if (guard > 16 or p > 0xFFFF - 2) {
                walk.refused_at = room;
                return walk;
            }
            const cond = r.w(f8f, p);
            if (cond == 0xE5E6) {
                if (sn == states.len) {
                    walk.refused_at = room;
                    return walk;
                }
                states[sn] = p + 2;
                sn += 1;
                break;
            }
            const nargs = smConditionArgBytes(cond) orelse {
                walk.refused_at = room;
                return walk;
            };
            const st = r.w(f8f, p + 2 + nargs);
            if (st < 0x8000 or sn == states.len) {
                walk.refused_at = room;
                return walk;
            }
            states[sn] = st;
            sn += 1;
            p += 2 + @as(u32, nargs) + 2;
        }
        // Door list: words naming door headers in $83, ended by whatever
        // follows (the next room header's index/area word is < $8000).
        var d: u32 = r.w(f8f, room + 9);
        var di: u8 = 0;
        while (di < 32 and d <= 0xFFFF - 1) : ({
            di += 1;
            d += 2;
        }) {
            const dp = r.w(f8f, d);
            if (dp < 0x8000 or dp > 0xFFFF - 12) break;
            const dest = r.w(f83, dp);
            if (dest == 0) continue; // elevator / no room
            if (!r.looksLikeRoom(dest)) continue;
            if (visited[dest - 0x8000]) continue;
            visited[dest - 0x8000] = true;
            if (qn == queue.len) {
                walk.refused_at = room;
                return walk;
            }
            queue[qn] = dest;
            qn += 1;
        }
    }
    walk.states = @intCast(sn);

    // Validate every state before touching a byte: level pointer into
    // MB2's ROM half, tileset index in range.
    for (states[0..sn]) |st| {
        if (st > 0xFFFF - 26) {
            walk.refused_at = st;
            return walk;
        }
        const lo = r.w(f8f, st);
        const bk = r.b(f8f, st + 2);
        const tileset = r.b(f8f, st + 3);
        if (lo < 0x8000 or bk < 0xC2 or bk > 0xCE or tileset >= 0x1D) {
            walk.refused_at = st;
            return walk;
        }
    }
    for (states[0..sn]) |st| {
        const f = f8f + (st - 0x8000) + 2;
        if (out[f] != image[f]) continue; // hi_proven got here first
        out[f] -= 0x20;
        walk.rebanked += 1;
    }

    // Each state also names a BACKGROUND (library) record at +$16 — a DMA
    // list that paints BG2. Its source banks are the same evidence-gated
    // class as the level pointer: a record no surface loaded keeps its stock
    // banks and the DMA reads the wrong megabyte, so the room renders correct
    // foreground over garbage background (measured 2026-09-02 on the Parlor,
    // $92FD; a three-byte hand-patch of this record's banks made it clean).
    // Unlike the level pointer this pass is PER-RECORD graceful, not
    // all-or-nothing: a state's BG word legitimately points at code or
    // nothing, so a record that does not parse as a clean list is skipped,
    // never fatal — exactly the door-walk's "names no room" rule. The list's
    // command widths are read off Super Metroid's own BG interpreter.
    for (states[0..sn]) |st| {
        const bg = r.w(f8f, st + 0x16);
        if (bg < 0x8000 or bg > 0xFFF0) continue;
        const ok = rebankSmBgRecord(image, out, bg, &walk);
        if (ok) walk.bg_records += 1;
    }
    return walk;
}

/// Walk one Super Metroid background (library) record and de-mirror the
/// source bank of every copy command. Returns false — translating nothing —
/// the instant the bytes stop looking like a BG list (an unknown command, an
/// out-of-range source bank, or no terminator within the cap), so a state
/// whose +$16 points at code or data is left untouched. Widths are Super
/// Metroid's: $0002 src+dest+size (7), $0004 src+dest (5), $0008 (7), $000A
/// (2), $000C (2), $000E src+3 words (9), $0000 ends. Only $0002/$0004/$0008/
/// $000E carry a 3-byte source at payload +0; its bank is payload byte 2.
fn rebankSmBgRecord(image: []const u8, out: []u8, ptr: u16, walk: *SmRoomWalk) bool {
    const f8f: usize = 0x0F * 0x8000;
    var pending: [64]usize = undefined; // byte offsets staged for translation
    var np: usize = 0;
    var a: u32 = ptr;
    var steps: u8 = 0;
    while (steps < 64) : (steps += 1) {
        if (a + 2 > 0x1_0000) return false;
        const cmd = std.mem.readInt(u16, image[f8f + (a - 0x8000) ..][0..2], .little);
        if (cmd == 0x0000) {
            // A clean list. Commit the staged source banks now — nothing was
            // written while the parse could still fail.
            for (pending[0..np]) |f| {
                if (out[f] != image[f]) continue; // hi_proven got here first
                const bank = out[f];
                out[f] = if (bank >= 0xC0 and bank <= 0xDF)
                    bank - 0x20
                else if (bank >= 0xA0 and bank <= 0xBF)
                    bank - 0x80
                else
                    bank - 0x3E; // $7E/$7F -> $40/$41
                walk.bg_banks += 1;
            }
            return true;
        }
        const payload: u32 = switch (cmd) {
            0x0002, 0x0008 => 7,
            0x0004 => 5,
            0x000A, 0x000C => 2,
            0x000E => 9,
            else => return false,
        };
        if (cmd == 0x0002 or cmd == 0x0004 or cmd == 0x0008 or cmd == 0x000E) {
            const bf = a + 2 + 2; // command word, then source lo/hi, then bank
            if (bf >= 0x1_0000) return false;
            const bank = image[f8f + (bf - 0x8000)];
            // A real source bank is WRAM or ROM; anything else means a
            // misparse, and we must not translate the byte we mistook.
            if (!(bank == 0x7E or bank == 0x7F or (bank >= 0x80 and bank <= 0xDF))) return false;
            if ((bank == 0x7E or bank == 0x7F or (bank >= 0xA0 and bank <= 0xDF)) and np < pending.len) {
                pending[np] = f8f + (bf - 0x8000);
                np += 1;
            }
        }
        a += 2 + payload;
    }
    return false; // no terminator within the cap — not a list we understand
}

pub const SmInlineDests = struct {
    /// `JSL $80:B0FF` sites whose inline destination names WRAM ($7E/$7F).
    sites: u32 = 0,
    /// Of those, the bank bytes this pass re-banked ($7E/$7F -> $40/$41).
    rebanked: u32 = 0,
};

/// Super Metroid's decompressor, `JSL $80:B0FF`, takes its DESTINATION as a
/// 3-byte long pointer sitting INLINE in the code stream right after the
/// JSL: the routine pulls the return address, reads the pointer through it
/// and advances the return by 3. That pointer is data — nothing executes
/// it — so relocation-by-execution cannot see it; the profiler proves a
/// site only when a recording drives that exact call and traces the byte
/// into a $7E store. Measured 2026-09-03: v38 had the door-transition
/// tileset loader's sites proven and the load-game loader's raw
/// ($82:EAF5/$82:EB06 — the same loads, on the path the Ceres escape takes
/// to Zebes). The tileset's tile table then decompressed into REAL WRAM
/// $7E:A800 while the game read the stale table at $40:A800, so every room
/// whose tileset first loads through that path painted the previous
/// tileset's blocks ($9A44: correct geometry, wrong textures). Stock has 63
/// sites, v38 left 29 raw; a hand patch of those 29 bank bytes made the
/// room pixel-correct. Same class as the room-state level pointer and the
/// background record: a bank byte a structure carries.
///
/// Signature-validated: the four JSL bytes, then an inline bank of $7E/$7F.
/// Any other bank — a ROM destination, or data that merely spells the JSL
/// — is left untouched; a byte `hi_proven` already re-banked in `out` is
/// left alone.
fn rebankSmDecompInlineDests(image: []const u8, out: []u8) SmInlineDests {
    var r: SmInlineDests = .{};
    if (image.len < 7) return r;
    const sig = [_]u8{ 0x22, 0xFF, 0xB0, 0x80 }; // JSL $80:B0FF
    var i: usize = 0;
    while (i + 7 <= image.len) : (i += 1) {
        if (!std.mem.eql(u8, image[i..][0..4], &sig)) continue;
        const bank = image[i + 6];
        if (bank != 0x7E and bank != 0x7F) continue;
        r.sites += 1;
        if (out[i + 6] != bank) continue; // hi_proven got here first
        out[i + 6] = bank - 0x3E; // $7E/$7F -> $40/$41
        r.rebanked += 1;
    }
    return r;
}

test "rebankSmDecompInlineDests: inline WRAM destinations re-banked, proven and ROM ones left alone" {
    const gpa = testing.allocator;
    const img = try gpa.alloc(u8, 0x18_0000);
    defer gpa.free(img);
    @memset(img, 0);
    // $82:E845 `JSL $80:B0FF` ; dl $7E:A000   (the CRE tile table)
    // $82:E856 `JSL $80:B0FF` ; dl $7E:A800   (the tileset tile table)
    // $82:E7F4 `JSL $80:B0FF` ; dl $7F:0000   (level data)
    // $82:F000 `JSL $80:B0FF` ; dl $C2:1234   (not WRAM: untouched)
    const sites = [_]struct { a: u16, lo: u16, bank: u8 }{
        .{ .a = 0xE845, .lo = 0xA000, .bank = 0x7E },
        .{ .a = 0xE856, .lo = 0xA800, .bank = 0x7E },
        .{ .a = 0xE7F4, .lo = 0x0000, .bank = 0x7F },
        .{ .a = 0xF000, .lo = 0x1234, .bank = 0xC2 },
    };
    const f82: usize = 0x02 * 0x8000;
    for (sites) |s| {
        const o = f82 + (@as(usize, s.a) - 0x8000);
        img[o] = 0x22;
        img[o + 1] = 0xFF;
        img[o + 2] = 0xB0;
        img[o + 3] = 0x80;
        std.mem.writeInt(u16, img[o + 4 ..][0..2], s.lo, .little);
        img[o + 6] = s.bank;
    }
    const out = try gpa.alloc(u8, img.len);
    defer gpa.free(out);
    @memcpy(out, img);
    // hi_proven already re-banked the level-data site.
    out[f82 + (0xE7F4 - 0x8000) + 6] = 0x41;
    const r = rebankSmDecompInlineDests(img, out);
    try testing.expectEqual(@as(u32, 3), r.sites);
    try testing.expectEqual(@as(u32, 2), r.rebanked);
    try testing.expectEqual(@as(u8, 0x40), out[f82 + (0xE845 - 0x8000) + 6]);
    try testing.expectEqual(@as(u8, 0x40), out[f82 + (0xE856 - 0x8000) + 6]);
    try testing.expectEqual(@as(u8, 0x41), out[f82 + (0xE7F4 - 0x8000) + 6]); // untouched
    try testing.expectEqual(@as(u8, 0xC2), out[f82 + (0xF000 - 0x8000) + 6]); // untouched
    // The inline address bytes are never touched.
    try testing.expectEqual(@as(u8, 0x00), out[f82 + (0xE845 - 0x8000) + 4]);
    try testing.expectEqual(@as(u8, 0xA0), out[f82 + (0xE845 - 0x8000) + 5]);
}

test "rebankSmBgRecord: copy-command source banks de-mirrored, non-list skipped" {
    const gpa = testing.allocator;
    const img = try gpa.alloc(u8, 0x18_0000);
    defer gpa.free(img);
    @memset(img, 0);
    const f8f: usize = 0x0F * 0x8000;
    const wr = struct {
        fn b(buf: []u8, a16: u16, v: u8) void {
            buf[0x0F * 0x8000 + (@as(usize, a16) - 0x8000)] = v;
        }
    }.b;
    // A clean list at $B000: $0004 src $BA:8DE7 dest $4000 ; $0002 src $7E:4000
    // dest $4800 size $0800 ; $0000. Bank bytes at $B004 ($BA) and $B00B ($7E).
    const rec = [_]u8{ 0x04, 0x00, 0xE7, 0x8D, 0xBA, 0x00, 0x40, 0x02, 0x00, 0x00, 0x40, 0x7E, 0x00, 0x48, 0x00, 0x08, 0x00, 0x00 };
    for (rec, 0..) |v, i| wr(img, 0xB000 + @as(u16, @intCast(i)), v);
    const out = try gpa.alloc(u8, img.len);
    defer gpa.free(out);
    @memcpy(out, img);
    var walk: SmRoomWalk = .{};
    try testing.expect(rebankSmBgRecord(img, out, 0xB000, &walk));
    try testing.expectEqual(@as(u32, 2), walk.bg_banks);
    try testing.expectEqual(@as(u8, 0x3A), out[f8f + (0xB004 - 0x8000)]); // BA -> 3A
    try testing.expectEqual(@as(u8, 0x40), out[f8f + (0xB00B - 0x8000)]); // 7E -> 40
    // hi_proven already took the first bank: it is left alone.
    @memcpy(out, img);
    out[f8f + (0xB004 - 0x8000)] = 0x3A;
    var w2: SmRoomWalk = .{};
    try testing.expect(rebankSmBgRecord(img, out, 0xB000, &w2));
    try testing.expectEqual(@as(u32, 1), w2.bg_banks); // only the $7E one
    // A pointer into code ($000A then a non-command word) is not a list:
    // nothing is translated.
    for ([_]u8{ 0x0A, 0x00, 0x00, 0x00, 0xA0, 0x7B, 0x82, 0x22 }, 0..) |v, i|
        wr(img, 0xC000 + @as(u16, @intCast(i)), v);
    @memcpy(out, img);
    var w3: SmRoomWalk = .{};
    try testing.expect(!rebankSmBgRecord(img, out, 0xC000, &w3));
    try testing.expectEqual(@as(u32, 0), w3.bg_banks);
}

/// Super Metroid's tileset table: the room-graph walk fixes each room's
/// LEVEL data pointer, but the room also names a TILESET, and the tileset is
/// three more MB2 pointers — tile table, tile graphics, palette — that the
/// loader copies into $07C0 and decompresses the picture from. A tileset no
/// profiled surface loaded keeps its stock banks, all three decompress from
/// the wrong megabyte, and the room renders as tile garbage over a wrong
/// palette (measured 2026-09-03 on the Climb, $96BA, tileset 3: 15 of the 29
/// records — half the game's tilesets — were raw in v41; a hand patch of the
/// 45 bank bytes made the room pixel-correct). Same evidence-gated class as
/// the level pointer, one table over. (A first version of this pass, v35,
/// was written against the Parlor and changed nothing there — the Parlor's
/// tileset was already proven — and was reverted as a wrong theory. The
/// theory was wrong for that room, not wrong.)
///
/// The table is a fixed contiguous run of 9-byte records ($8F:E6A2..E7A7 on
/// this ROM — the pointer list at $E7A7 begins exactly where the records
/// end), each three 3-byte pointers into MB2. All-or-nothing, like the room
/// walk: every record's three banks must be real MB2 ($A0-$DF) or the whole
/// pass refuses, because a misparse rewrites graphics data. The de-mirror
/// map: $C0-$DF content lives $20 lower, $A0-$BF (the CRE's mirror-of-MB1
/// home) $80 lower. Reads stock bytes; leaves a byte `hi_proven` already
/// re-banked in `out` alone.
const sm_tileset_lo: u16 = 0xE6A2;
const sm_tileset_hi: u16 = 0xE7A7;

fn rebankSmTilesetTable(image: []const u8, out: []u8) SmRoomWalk {
    const f8f: usize = 0x0F * 0x8000;
    var walk: SmRoomWalk = .{};
    if (image.len < f8f + 0x8000) return walk;
    const b = struct {
        fn at(img: []const u8, a16: u16) u8 {
            return img[0x0F * 0x8000 + (@as(usize, a16) - 0x8000)];
        }
    }.at;

    // Validate the whole table before touching a byte.
    var a: u16 = sm_tileset_lo;
    var recs: u32 = 0;
    while (a + 9 <= sm_tileset_hi) : (a += 9) {
        inline for (.{ 2, 5, 8 }) |k| {
            const bank = b(image, a + k);
            if (bank < 0xA0 or bank > 0xDF) {
                walk.refused_at = a;
                return walk;
            }
        }
        recs += 1;
    }
    if (recs == 0) return walk;

    a = sm_tileset_lo;
    while (a + 9 <= sm_tileset_hi) : (a += 9) {
        inline for (.{ 2, 5, 8 }) |k| {
            const f = f8f + (@as(usize, a) + k - 0x8000);
            if (out[f] == image[f]) {
                const bank = out[f];
                out[f] = if (bank >= 0xC0) bank - 0x20 else bank - 0x80;
                walk.rebanked += 1;
            }
        }
    }
    walk.states = recs;
    return walk;
}

test "rebankSmTilesetTable: every record's banks de-mirrored, proven left alone, anomaly refuses" {
    const gpa = testing.allocator;
    const img = try gpa.alloc(u8, 0x18_0000);
    defer gpa.free(img);
    @memset(img, 0);
    const f8f: usize = 0x0F * 0x8000;
    const putrec = struct {
        fn f(buf: []u8, a16: u16, lo: u16, bank: u8) void {
            const o = 0x0F * 0x8000 + (@as(usize, a16) - 0x8000);
            std.mem.writeInt(u16, buf[o..][0..2], lo, .little);
            buf[o + 2] = bank;
        }
    }.f;
    // Fill $E6A2..E7A7 with 9-byte records (three MB2 pointers each).
    var a: u16 = sm_tileset_lo;
    while (a + 9 <= sm_tileset_hi) : (a += 9) {
        putrec(img, a + 0, 0xBEEE, 0xC1); // tile table -> A1
        putrec(img, a + 3, 0xF911, 0xBA); // tile GFX   -> 3A
        putrec(img, a + 6, 0xB015, 0xC2); // palette    -> A2
    }
    const out = try gpa.alloc(u8, img.len);
    defer gpa.free(out);
    @memcpy(out, img);
    // hi_proven already re-banked the first record's tile-table bank.
    out[f8f + (@as(usize, sm_tileset_lo) + 2 - 0x8000)] = 0xA1;

    const w = rebankSmTilesetTable(img, out);
    try testing.expectEqual(@as(u32, 0), w.refused_at);
    try testing.expectEqual(@as(u32, 29), w.states);
    try testing.expectEqual(@as(u32, 29 * 3 - 1), w.rebanked); // all but the proven one
    try testing.expectEqual(@as(u8, 0xA1), out[f8f + (@as(usize, sm_tileset_lo) + 2 - 0x8000)]); // untouched
    try testing.expectEqual(@as(u8, 0x3A), out[f8f + (@as(usize, sm_tileset_lo) + 5 - 0x8000)]); // BA -> 3A
    try testing.expectEqual(@as(u8, 0xA2), out[f8f + (@as(usize, sm_tileset_lo) + 8 - 0x8000)]); // C2 -> A2
    // A record with a non-MB2 bank refuses the whole pass, rewriting nothing.
    putrec(img, sm_tileset_lo + 9 + 2, 0xBEEE, 0x12);
    @memcpy(out, img);
    const w2 = rebankSmTilesetTable(img, out);
    try testing.expectEqual(sm_tileset_lo + @as(u16, 9), w2.refused_at);
    try testing.expectEqual(@as(u32, 0), w2.rebanked);
    try testing.expectEqual(@as(u8, 0xC1), out[f8f + (@as(usize, sm_tileset_lo) + 2 - 0x8000)]);
}

/// Super Metroid's enemy headers: 64-byte records at $A0:CEBF.. ($40 apart,
/// through $F7BF), one per enemy species. Byte +$0C is the enemy's BANK —
/// the bank its AI routines, its palette (+$02) and its instruction lists
/// live in, $A2-$B7 on this ROM, i.e. MB1 addressed through its $A0-$BF
/// mirror. The game reads it as data (into the enemy's RAM slot, then
/// through long pointers and the AI dispatch), so it is the same
/// evidence-gated class as the level pointer: an enemy no recording met
/// keeps its stock bank, and on the converted map $A0-$BF is MB2, so its
/// palette comes from the wrong megabyte and its AI runs from it. Measured
/// 2026-09-03 in $9A44: the six Chozo-face sprites ($EA7F, proven) share
/// palette slot 7 with $CEFF (raw); $CEFF's palette read from $A2:8912
/// returned MB2's $C2:8912 and painted the faces wrong. 164 headers carry
/// such a bank; v43 had 130 raw. A hand patch made the second load write
/// the stock palette.
///
/// Per-record validated, not all-or-nothing: the run of true headers ends
/// somewhere in $F1xx-$F7xx and is followed by 64-byte-aligned records of
/// another shape (they carry a plausible bank byte but AI pointers below
/// $8000), so each record must look like a header — bank in $A0-$BF and
/// both the init AI (+$12) and main AI (+$18) pointers in ROM ($8000+) —
/// or it is skipped untouched. Translation is -$80 ($A0-$BF -> $20-$3F).
/// Leaves a byte `hi_proven` already re-banked in `out` alone.
const sm_enemy_hdr_lo: u16 = 0xCEBF;
const sm_enemy_hdr_hi: u16 = 0xF800;

fn rebankSmEnemyHeaders(image: []const u8, out: []u8) SmRoomWalk {
    const fa0: usize = 0x20 * 0x8000; // bank $A0 (= $20) file offset
    var walk: SmRoomWalk = .{};
    if (image.len < fa0 + 0x8000) return walk;
    // The table is not one 64-byte grid: a second run of headers starts
    // at $F153, 20 bytes off the first grid's phase (the enemy whose raw
    // bank byte sent the CPU into the wrong megabyte lived at $F693). So
    // the walk is stride 2 over the whole range, and a record is a header
    // when it sits on the first grid and passes the original check, or
    // anywhere and passes a stricter one — the bank's pad byte zero, every
    // AI pointer (init, main, grapple, hurt, frozen) in ROM, a plausible
    // part count. Measured on the stock image: 139 on the grid, 26 off it,
    // no two within 64 bytes of each other.
    var h: u32 = sm_enemy_hdr_lo;
    while (h + 0x40 <= sm_enemy_hdr_hi) : (h += 2) {
        const o = fa0 + (h - 0x8000);
        const bank = image[o + 0x0C];
        const init_ai = std.mem.readInt(u16, image[o + 0x12 ..][0..2], .little);
        const main_ai = std.mem.readInt(u16, image[o + 0x18 ..][0..2], .little);
        if (bank < 0xA0 or bank > 0xBF or init_ai < 0x8000 or main_ai < 0x8000) continue;
        const on_grid = (h - sm_enemy_hdr_lo) % 0x40 == 0;
        if (!on_grid) {
            const grapple = std.mem.readInt(u16, image[o + 0x1A ..][0..2], .little);
            const hurt = std.mem.readInt(u16, image[o + 0x1C ..][0..2], .little);
            const frozen = std.mem.readInt(u16, image[o + 0x1E ..][0..2], .little);
            const parts = std.mem.readInt(u16, image[o + 0x14 ..][0..2], .little);
            if (image[o + 0x0D] != 0 or grapple < 0x8000 or hurt < 0x8000 or frozen < 0x8000 or parts > 0x10) continue;
        }
        walk.states += 1;
        if (out[o + 0x0C] != image[o + 0x0C]) continue; // hi_proven got here first
        out[o + 0x0C] = bank - 0x80;
        walk.rebanked += 1;
    }
    return walk;
}

/// Super Metroid's AREA MAP TABLE: seven 3-byte long pointers at $82:964A,
/// one per area, naming that area's map tilemap in bank $B5. The HUD
/// minimap ($90:AA7C) and the pause map ($82:953F) copy an entry into a
/// direct-page pointer and read the tilemap through it — a bank byte that
/// lives in a table, never in an operand, so no execution-driven rebanker
/// sees it, and on the conversion bank $B5 is not the megabyte the map
/// lives in: the minimap drew text glyphs instead of map cells. The bytes
/// are de-mirrored in place ($A0-$BF -> -$80), all or nothing, after every
/// entry validates (bank $B5, address in ROM); a byte a recording already
/// proved is left as the evidence wrote it. Title-gated like the others.
const sm_area_map_lo: u16 = 0x964A;
const sm_area_map_entries: u16 = 7;
fn rebankSmAreaMapTable(image: []const u8, out: []u8) SmRoomWalk {
    const f82: usize = 0x02 * 0x8000;
    var walk: SmRoomWalk = .{};
    if (image.len < f82 + 0x8000) return walk;
    var e: u16 = 0;
    while (e < sm_area_map_entries) : (e += 1) {
        const o = f82 + (sm_area_map_lo - 0x8000) + @as(usize, e) * 3;
        const addr = std.mem.readInt(u16, image[o..][0..2], .little);
        if (image[o + 2] != 0xB5 or addr < 0x8000) {
            walk.refused_at = sm_area_map_lo + e * 3;
            return walk;
        }
    }
    walk.states = sm_area_map_entries;
    e = 0;
    while (e < sm_area_map_entries) : (e += 1) {
        const o = f82 + (sm_area_map_lo - 0x8000) + @as(usize, e) * 3 + 2;
        if (out[o] != image[o]) continue; // proven first
        out[o] = image[o] - 0x80;
        walk.rebanked += 1;
    }
    return walk;
}

test "rebankSmAreaMapTable: seven entries de-mirrored, a proven one kept, a bad entry refuses the table" {
    const gpa = testing.allocator;
    const img = try gpa.alloc(u8, 0x18_0000);
    defer gpa.free(img);
    @memset(img, 0);
    const f82: usize = 0x02 * 0x8000;
    const t = f82 + (sm_area_map_lo - 0x8000);
    const table = [_]u8{ 0x00, 0x90, 0xB5, 0x00, 0x80, 0xB5, 0x00, 0xA0, 0xB5, 0x00, 0xB0, 0xB5, 0x00, 0xC0, 0xB5, 0x00, 0xD0, 0xB5, 0x00, 0xE0, 0xB5 };
    @memcpy(img[t..][0..table.len], &table);
    const out = try gpa.alloc(u8, img.len);
    defer gpa.free(out);
    @memcpy(out, img);
    out[t + 5] = 0x35; // entry 1 already proven
    const w = rebankSmAreaMapTable(img, out);
    try testing.expectEqual(@as(u32, 7), w.states);
    try testing.expectEqual(@as(u32, 6), w.rebanked);
    try testing.expectEqual(@as(u32, 0), w.refused_at);
    for (0..7) |i| try testing.expectEqual(@as(u8, 0x35), out[t + i * 3 + 2]);
    // A bad entry refuses the whole table, touching nothing.
    img[t + 3 * 3 + 2] = 0x7E;
    @memcpy(out, img);
    const w2 = rebankSmAreaMapTable(img, out);
    try testing.expectEqual(@as(u32, sm_area_map_lo + 9), w2.refused_at);
    try testing.expectEqual(@as(u32, 0), w2.rebanked);
    try testing.expectEqualSlices(u8, img, out);
}

/// Super Metroid seeds long pointers in the direct page from IMMEDIATES:
/// the map routine does `LDA #$007E / STA $05` for the tilemap buffer's
/// bank and `LDA #$0000 / STA $0B`, `LDA #$07F7 / STA $09` for the
/// explored-map bits it then reads through `LDA [$09]`. Nothing indexes
/// those constants, no bank register carries them, so neither the
/// de-mirror map nor the evidence-based rebankers reach them: the map
/// drew from the abandoned WRAM homes (the garbled pause map). This
/// pass finds the idiom by signature and translates the seed: a bank
/// word $007E/$007F becomes $0040/$0041 when a long-indirect access
/// through that slot's pointer follows within 256 bytes; a low-WRAM
/// address word (under $2000) gains $6000 — the window's home — when
/// its bank slot is seeded with $0000 within 64 bytes either way and
/// the same use follows. Measured on the stock image: 9 bank seeds and
/// 3 address seeds in banks $80-$B4, every one a pointer the game
/// dereferences; the 5 that recordings had already proven are left as
/// the evidence wrote them. Title-gated like the other nets.
fn rebankSmPointerSeeds(image: []const u8, out: []u8) SmInlineDests {
    var st: SmInlineDests = .{};
    var bank: u8 = 0x80;
    while (bank <= 0xB4) : (bank += 1) {
        const base: usize = @as(usize, bank & 0x7F) * 0x8000;
        if (image.len < base + 0x8000) break;
        const blk = image[base .. base + 0x8000];
        var i: usize = 0;
        while (i + 5 <= blk.len) : (i += 1) {
            if (blk[i] != 0xA9 or blk[i + 3] != 0x85) continue;
            const imm: u16 = @as(u16, blk[i + 1]) | @as(u16, blk[i + 2]) << 8;
            const slot = blk[i + 4];
            if (imm == 0x7E or imm == 0x7F) {
                if (slot < 2 or !smLongIndirectUse(blk, i + 5, slot - 2)) continue;
                st.sites += 1;
                if (out[base + i + 1] != image[base + i + 1]) continue; // proven first
                out[base + i + 1] = if (imm == 0x7E) 0x40 else 0x41;
                st.rebanked += 1;
            } else if (imm != 0 and imm < 0x2000) {
                if (slot > 0xFD or !smLongIndirectUse(blk, i + 5, slot)) continue;
                // The bank slot seeded with $0000 nearby: the pointer names
                // bank 0, whose low 8 KiB is the WRAM mirror.
                const lo: usize = i -| 64;
                const hi: usize = @min(blk.len - 5, i + 64);
                var k: usize = lo;
                var seeded = false;
                while (k < hi) : (k += 1) {
                    if (blk[k] == 0xA9 and blk[k + 1] == 0 and blk[k + 2] == 0 and blk[k + 3] == 0x85 and blk[k + 4] == slot + 2) {
                        seeded = true;
                        break;
                    }
                }
                if (!seeded) continue;
                st.sites += 1;
                if (out[base + i + 1] != image[base + i + 1] or out[base + i + 2] != image[base + i + 2]) continue;
                const moved = imm + 0x6000;
                out[base + i + 1] = @truncate(moved);
                out[base + i + 2] = @truncate(moved >> 8);
                st.rebanked += 1;
            }
        }
    }
    return st;
}

/// A `[dp]` or `[dp],Y` access (the eight ALU ops' long-indirect forms:
/// opcode low bits $07/$17) through `slot` within 256 bytes from `from`.
fn smLongIndirectUse(blk: []const u8, from: usize, slot: u8) bool {
    var j = from;
    const end = @min(blk.len - 1, from + 256);
    while (j < end) : (j += 1) {
        const lo5 = blk[j] & 0x1F;
        if ((lo5 == 0x07 or lo5 == 0x17) and blk[j + 1] == slot) return true;
    }
    return false;
}

test "rebankSmPointerSeeds: bank and low-WRAM address seeds of dereferenced pointers, proven ones left alone" {
    const gpa = testing.allocator;
    const img = try gpa.alloc(u8, 0x18_0000);
    defer gpa.free(img);
    @memset(img, 0xEA);
    const f82: usize = 0x02 * 0x8000;
    // The map idiom: bank seed for slot $03, address seed for slot $09 with
    // its bank slot $0B seeded $0000, both dereferenced later.
    const code = [_]u8{
        0xA9, 0x00, 0x30, 0x85, 0x03, // LDA #$3000 / STA $03
        0xA9, 0x7E, 0x00, 0x85, 0x05, // LDA #$007E / STA $05   -> $0040
        0xA9, 0x00, 0x00, 0x85, 0x0B, // LDA #$0000 / STA $0B
        0xA9, 0xF7, 0x07, 0x85, 0x09, // LDA #$07F7 / STA $09   -> $67F7
        0xA7, 0x09, //                   LDA [$09]
        0x97, 0x03, //                   STA [$03],Y
        0xA9, 0x7F, 0x00, 0x85, 0x40, // LDA #$007F / STA $40: never dereferenced -> untouched
        0xA9, 0x10, 0x00, 0x85, 0x20, // LDA #$0010 / STA $20: no bank seed -> untouched
        0xA7, 0x20, //                   LDA [$20]
    };
    @memcpy(img[f82 + 0x1000 ..][0..code.len], &code);
    // A seed a recording already proved: `out` differs from `image` there.
    @memcpy(img[f82 + 0x2000 ..][0..7], &[_]u8{ 0xA9, 0x7E, 0x00, 0x85, 0x05, 0xA7, 0x03 });
    const out = try gpa.alloc(u8, img.len);
    defer gpa.free(out);
    @memcpy(out, img);
    out[f82 + 0x2000 + 1] = 0x40;
    const st = rebankSmPointerSeeds(img, out);
    try testing.expectEqual(@as(u32, 3), st.sites);
    try testing.expectEqual(@as(u32, 2), st.rebanked);
    try testing.expectEqual(@as(u8, 0x40), out[f82 + 0x1000 + 6]);
    try testing.expectEqual(@as(u16, 0x67F7), std.mem.readInt(u16, out[f82 + 0x1000 + 16 ..][0..2], .little));
    try testing.expectEqual(@as(u8, 0x7F), out[f82 + 0x1000 + 25]);
    try testing.expectEqual(@as(u16, 0x0010), std.mem.readInt(u16, out[f82 + 0x1000 + 30 ..][0..2], .little));
    try testing.expectEqual(@as(u8, 0x40), out[f82 + 0x2000 + 1]);
}

test "rebankSmEnemyHeaders: header banks de-mirrored, proven and non-header records left alone" {
    const gpa = testing.allocator;
    const img = try gpa.alloc(u8, 0x18_0000);
    defer gpa.free(img);
    @memset(img, 0);
    const fa0: usize = 0x20 * 0x8000;
    const hdr = struct {
        fn put(buf: []u8, a16: u16, bank: u8, init_ai: u16, main_ai: u16) void {
            const o = 0x20 * 0x8000 + (@as(usize, a16) - 0x8000);
            buf[o + 0x0C] = bank;
            std.mem.writeInt(u16, buf[o + 0x12 ..][0..2], init_ai, .little);
            std.mem.writeInt(u16, buf[o + 0x18 ..][0..2], main_ai, .little);
        }
    }.put;
    hdr(img, 0xCEBF, 0xA2, 0x8DBA, 0x8E30); // a real header -> $22
    hdr(img, 0xCEFF, 0xA2, 0x8DBA, 0x8E30); // real, but already proven in `out`
    hdr(img, 0xEA7F, 0xA8, 0xE7BC, 0xE812); // real -> $28
    hdr(img, 0xF17F, 0xB7, 0x0000, 0x0009); // bank plausible, AI pointers not: skipped
    hdr(img, 0xF13F, 0x02, 0x8000, 0x8000); // bank not a mirror: skipped
    // Off the first grid (the second run's phase): needs the strict check.
    hdr(img, 0xF693, 0xB2, 0xFD02, 0xFD32); // -> $32 once its other AI pointers are in ROM
    for ([_]usize{ 0x1A, 0x1C, 0x1E }) |k| std.mem.writeInt(u16, img[fa0 + (0xF693 - 0x8000) + k ..][0..2], 0x800F, .little);
    std.mem.writeInt(u16, img[fa0 + (0xF693 - 0x8000) + 0x14 ..][0..2], 1, .little);
    hdr(img, 0xF6D5, 0xB2, 0xFD02, 0xFD32); // off both grids, grapple AI not in ROM: skipped
    const out = try gpa.alloc(u8, img.len);
    defer gpa.free(out);
    @memcpy(out, img);
    out[fa0 + (0xCEFF - 0x8000) + 0x0C] = 0x22;
    const w = rebankSmEnemyHeaders(img, out);
    try testing.expectEqual(@as(u32, 4), w.states);
    try testing.expectEqual(@as(u32, 3), w.rebanked);
    try testing.expectEqual(@as(u8, 0x32), out[fa0 + (0xF693 - 0x8000) + 0x0C]);
    try testing.expectEqual(@as(u8, 0xB2), out[fa0 + (0xF6D5 - 0x8000) + 0x0C]); // skipped
    try testing.expectEqual(@as(u8, 0x22), out[fa0 + (0xCEBF - 0x8000) + 0x0C]);
    try testing.expectEqual(@as(u8, 0x22), out[fa0 + (0xCEFF - 0x8000) + 0x0C]); // untouched
    try testing.expectEqual(@as(u8, 0x28), out[fa0 + (0xEA7F - 0x8000) + 0x0C]);
    try testing.expectEqual(@as(u8, 0xB7), out[fa0 + (0xF17F - 0x8000) + 0x0C]); // skipped
    try testing.expectEqual(@as(u8, 0x02), out[fa0 + (0xF13F - 0x8000) + 0x0C]); // skipped
}

test "rebankSmRoomLevelPointers: every state reached through doors, proven bytes left alone" {
    const gpa = testing.allocator;
    const img = try gpa.alloc(u8, 0x18_0000);
    defer gpa.free(img);
    @memset(img, 0);
    const f8f: usize = 0x0F * 0x8000;
    const f83: usize = 0x03 * 0x8000;
    const put16 = struct {
        fn f(buf: []u8, base: usize, a16: u32, v: u16) void {
            std.mem.writeInt(u16, buf[base + (a16 - 0x8000) ..][0..2], v, .little);
        }
    }.f;
    // Room A at $91F8: area 0, 1x1, door list at $9260; conditions:
    // E629 <event 1> -> state $9240 ; E5E6 -> default state inline.
    const a: u32 = 0x91F8;
    img[f8f + (a - 0x8000) + 1] = 0; // area
    img[f8f + (a - 0x8000) + 4] = 1; // width
    img[f8f + (a - 0x8000) + 5] = 1; // height
    put16(img, f8f, a + 9, 0x9260);
    put16(img, f8f, a + 11, 0xE629);
    img[f8f + (a + 13 - 0x8000)] = 1;
    put16(img, f8f, a + 14, 0x9240);
    put16(img, f8f, a + 16, 0xE5E6);
    const a_def: u32 = a + 18;
    put16(img, f8f, a_def, 0xC330);
    img[f8f + (a_def + 2 - 0x8000)] = 0xCD;
    img[f8f + (a_def + 3 - 0x8000)] = 0x0F;
    // A's event state at $9240: level $C2:9000, tileset 3
    put16(img, f8f, 0x9240, 0x9000);
    img[f8f + (0x9242 - 0x8000)] = 0xC2;
    img[f8f + (0x9243 - 0x8000)] = 0x03;
    // A's door list: a door to room B, an elevator door, then the next header word (< $8000)
    put16(img, f8f, 0x9260, 0x9000);
    put16(img, f8f, 0x9262, 0x9010);
    put16(img, f8f, 0x9264, 0x0102);
    put16(img, f83, 0x9000, 0x9300); // door -> room B
    put16(img, f83, 0x9010, 0x0000); // elevator
    // Room B at $9300: area 1, 2x1, default state only, one door back to A
    const b: u32 = 0x9300;
    img[f8f + (b - 0x8000) + 1] = 1;
    img[f8f + (b - 0x8000) + 4] = 2;
    img[f8f + (b - 0x8000) + 5] = 1;
    put16(img, f8f, b + 9, 0x9340);
    put16(img, f8f, b + 11, 0xE5E6);
    const b_def: u32 = b + 13;
    put16(img, f8f, b_def, 0xB846);
    img[f8f + (b_def + 2 - 0x8000)] = 0xC5;
    img[f8f + (b_def + 3 - 0x8000)] = 0x10;
    put16(img, f8f, 0x9340, 0x9020);
    put16(img, f8f, 0x9342, 0x0000);
    put16(img, f83, 0x9020, 0x91F8);

    // Room C at $DF45 (the Ceres root): no door reaches it from A or B.
    const c: u32 = 0xDF45;
    img[f8f + (c - 0x8000) + 1] = 6;
    img[f8f + (c - 0x8000) + 4] = 1;
    img[f8f + (c - 0x8000) + 5] = 1;
    put16(img, f8f, c + 9, 0xDF80);
    put16(img, f8f, c + 11, 0xE5E6);
    const c_def: u32 = c + 13;
    put16(img, f8f, c_def, 0xB000);
    img[f8f + (c_def + 2 - 0x8000)] = 0xCD;
    img[f8f + (c_def + 3 - 0x8000)] = 0x0F;
    put16(img, f8f, 0xDF80, 0x0000);

    const out = try gpa.alloc(u8, img.len);
    defer gpa.free(out);
    @memcpy(out, img);
    out[f8f + (a_def + 2 - 0x8000)] = 0xAD; // hi_proven already re-banked A's default

    const w = try rebankSmRoomLevelPointers(gpa, img, out);
    try testing.expectEqual(@as(u32, 0), w.refused_at);
    try testing.expectEqual(@as(u32, 3), w.rooms);
    try testing.expectEqual(@as(u32, 4), w.states);
    try testing.expectEqual(@as(u32, 3), w.rebanked);
    try testing.expectEqual(@as(u8, 0xAD), out[f8f + (c_def + 2 - 0x8000)]);
    try testing.expectEqual(@as(u8, 0xAD), out[f8f + (a_def + 2 - 0x8000)]);
    try testing.expectEqual(@as(u8, 0xA2), out[f8f + (0x9242 - 0x8000)]);
    try testing.expectEqual(@as(u8, 0xA5), out[f8f + (b_def + 2 - 0x8000)]);
    // A state whose level pointer is outside MB2 refuses the whole pass and rewrites nothing.
    img[f8f + (b_def + 2 - 0x8000)] = 0x8F;
    @memcpy(out, img);
    const w2 = try rebankSmRoomLevelPointers(gpa, img, out);
    try testing.expectEqual(b_def, w2.refused_at);
    try testing.expectEqual(@as(u32, 0), w2.rebanked);
    try testing.expectEqual(@as(u8, 0xC2), out[f8f + (0x9242 - 0x8000)]);
}

test "demirrorQueueBankImms: consumer names the column, producers re-bank" {
    var buf: [64]u8 = @splat(0x60); // RTS filler
    // consumer: LDA $6FA6,X / STA $7786 / XBA / PHA / PLB / PLB
    @memcpy(buf[4..14], &[_]u8{ 0xBD, 0xA6, 0x6F, 0x8D, 0x86, 0x77, 0xEB, 0x48, 0xAB, 0xAB });
    // producers against the same column: mirror, WRAM, misfit, and native
    @memcpy(buf[20..26], &[_]u8{ 0xA9, 0xA3, 0x00, 0x9D, 0xA6, 0x6F });
    @memcpy(buf[26..32], &[_]u8{ 0xA9, 0x7E, 0x00, 0x9D, 0xA6, 0x6F });
    @memcpy(buf[32..38], &[_]u8{ 0xA9, 0xC5, 0x00, 0x9D, 0xA6, 0x6F });
    @memcpy(buf[38..44], &[_]u8{ 0xA9, 0x33, 0x00, 0x9D, 0xA6, 0x6F }); // already native: untouched
    // a producer against a DIFFERENT column: untouched
    @memcpy(buf[44..50], &[_]u8{ 0xA9, 0xA3, 0x00, 0x9D, 0xB0, 0x6F });
    try testing.expectEqual(@as(u32, 3), demirrorQueueBankImms(&buf, true));
    try testing.expectEqual(@as(u8, 0x23), buf[21]);
    try testing.expectEqual(@as(u8, 0x40), buf[27]);
    try testing.expectEqual(@as(u8, 0xA5), buf[33]);
    try testing.expectEqual(@as(u8, 0x33), buf[39]);
    try testing.expectEqual(@as(u8, 0xA3), buf[45]);
    // narrow image: the de-mirror arms stay put, WRAM still re-banks
    var buf2: [64]u8 = buf;
    buf2[21] = 0xA3;
    buf2[27] = 0x7E;
    buf2[33] = 0xC5;
    try testing.expectEqual(@as(u32, 1), demirrorQueueBankImms(&buf2, false));
    try testing.expectEqual(@as(u8, 0xA3), buf2[21]);
    try testing.expectEqual(@as(u8, 0x40), buf2[27]);
    try testing.expectEqual(@as(u8, 0xC5), buf2[33]);
}

/// The ORIGINAL index-split thunk, kept verbatim for exactly the sites it
/// already served: an LDA shape whose measured evidence is low|rom. Those
/// five sites in Gradius III are the level-script walker, they are hot,
/// and they are on a path that SHIPS — so they get the body that shipped,
/// to the cycle. A is scratch here, which is why only LDA qualifies: the
/// load overwrites it, and an 8-bit scratch leaves the B accumulator
/// alone. Generalising this template — even to something strictly more
/// correct — changed the timeline enough to fail a build that passed.
const idx_thunk_v2_len: u32 = 24;
fn idxThunkBodyV2(op: u8, v: u16, ret: u8) [idx_thunk_v2_len]u8 {
    const sh: u16 = v + wg_bw_window;
    const lim: u16 = 0x2000 - v;
    const cp: u8 = if (usage_map.mode(op) == .abs_y) 0xC0 else 0xE0;
    return .{
        0x08, 0xE2, 0x20, 0xA3, 0x01, 0x89, 0x10, 0xD0, 0x05, // PHP/SEP/LDA $01,S/BIT #$10/BNE low
        cp, @truncate(lim), @truncate(lim >> 8), 0xB0, 0x05, // CPY #lim / BCS rom
        0x28, op, @truncate(sh), @truncate(sh >> 8), ret, // low: PLP / op v+$6000
        0x28, op, @truncate(v), @truncate(v >> 8), ret, // rom: PLP / op v
    };
}

/// The NEGATIVE-BASE `long,X` thunk. `LDA $02:FFFF,X` reaches the byte
/// BEFORE a bank boundary when X is small, wrapping forward into the next
/// bank's low page — `$02:FFFF` + 7 is `$03:0006`, which is relocated WRAM
/// on the S-CPU and the SA-1's OWN I-RAM inside an offloaded copy. The
/// slot walker uses the idiom on the boss's node-insertion path, which is
/// why the stage-1 boss rendered as garbage: the tree read I-RAM for its
/// chain links. Every net missed it, because all three tested `v < $2000`
/// and $FFFF is not — the thunk rule, the window shift, and the
/// eligibility walk's hazard check, which is how the tree was admitted.
///
/// Two compares, because the low mirror is a RANGE here rather than a
/// ceiling: X below `$10000 - v` has not wrapped yet and is still reading
/// this bank's ROM tail; X that far plus $2000 or more has passed the
/// mirror. Only between them is the address the one that moved.
///
/// No A scratch: the dispatch reads X only. `REP #$10` makes the
/// immediates parse and X read whole whatever width the caller had —
/// setting the X flag zeroes XH, so an x8 caller's index has the same
/// numeric value either way — and PLP puts the caller's width back before
/// the op, which runs last so the exit flags are its own.
///
///   PHP / REP #$10
///   CPX #($10000-v) / BCC rom      ; not wrapped: ROM tail
///   CPX #($10000-v+$2000) / BCS rom ; past the mirror
///   low: PLP / op (b+1):(v+$6000) / RTL
///   rom: PLP / op b:v              / RTL
const long_neg_thunk_len: u32 = 25;
fn longNegThunkBody(op: u8, v: u16, bank: u8) [long_neg_thunk_len]u8 {
    const lo: u16 = @intCast(0x10000 - @as(u32, v)); // wrap threshold
    const hi: u16 = lo +% 0x2000;
    // EA' = EA + $6000: the +$6000 always carries out of a base >= $FF00,
    // so the bank advances and the operand keeps the same distance.
    const sh: u16 = v +% wg_bw_window;
    const sb: u8 = bank +% 1;
    return .{
        0x08, 0xC2, 0x10, // PHP / REP #$10
        0xE0, @truncate(lo), @truncate(lo >> 8), 0x90, 0x0B, // CPX #lo / BCC rom
        0xE0, @truncate(hi), @truncate(hi >> 8), 0xB0, 0x06, // CPX #hi / BCS rom
        0x28, op, @truncate(sh), @truncate(sh >> 8), sb, 0x6B, // low: the window
        0x28, op, @truncate(v), @truncate(v >> 8), bank, 0x6B, // rom: as written
    };
}

/// The index-dispatch thunk for a site MEASURED never to run under a
/// BW-RAM pin: the data-bank arm is dropped and only the index is asked
/// about. Same A-preserving shape, eight bytes and ~17 cycles cheaper.
///
///   PHP / SEP #$20 / PHA / LDA $02,S / BIT #$10 / BNE low
///   CPY #($2000-v) / BCS rom
///   low: PLA / PLP / op v+$6000 / RTS
///   rom: PLA / PLP / op v / RTS
fn idxThunkBodyShort(op: u8, v: u16, ret: u8) [idx_thunk_short_len]u8 {
    const sh: u16 = v + wg_bw_window;
    const lim: u16 = 0x2000 - v;
    const cp: u8 = if (usage_map.mode(op) == .abs_y) 0xC0 else 0xE0;
    return .{
        0x08, 0xE2, 0x20, 0x48, // PHP / SEP #$20 / PHA
        0xA3, 0x02, 0x89, 0x10, 0xD0, 0x05, // LDA $02,S / BIT #$10 / BNE low
        cp, @truncate(lim), @truncate(lim >> 8), 0xB0, 0x06, // CPY #lim / BCS rom
        0x68, 0x28, op, @truncate(sh), @truncate(sh >> 8), ret, // low: the window
        0x68, 0x28, op, @truncate(v), @truncate(v >> 8), ret, // rom: as written
    };
}

/// The index-dispatch thunk body (see the emission comment in
/// convertWholeGame). `ret` is RTS in-bank, RTL behind a far stub.
fn idxThunkBody(op: u8, v: u16, ret: u8) [idx_thunk_len]u8 {
    const sh: u16 = v + wg_bw_window;
    const lim: u16 = 0x2000 - v;
    const cp: u8 = if (usage_map.mode(op) == .abs_y) 0xC0 else 0xE0;
    return .{
        0x08, 0xE2, 0x20, 0x48, 0x8B, 0x68, // PHP/SEP#$20/PHA/PHB/PLA
        0x30, 0x04, 0x89, 0x40, 0xD0, 0x11, // BMI sys / BIT #$40 / BNE rom
        0xA3, 0x02, 0x89, 0x10, 0xD0, 0x05, // sys: LDA $02,S / BIT #$10 / BNE low
        cp, @truncate(lim), @truncate(lim >> 8), 0xB0, 0x06, // CPY #lim / BCS rom
        0x68, 0x28, op, @truncate(sh), @truncate(sh >> 8), ret, // low: the window
        0x68, 0x28, op, @truncate(v), @truncate(v >> 8), ret, // rom: as written
    };
}

/// Diagnostics: report each bank's thunk demand against its padding.
const dbg_thunk_pad = false;

const WinChosen = struct { entry: u16, spec: WinSpec, is_async: bool, nmi_off: bool };

/// Choose and emit window offloads onto the REWRITTEN image. The
/// dispatcher (CRV is 16-bit) and the NMI prologue (a 16-bit vector)
/// live in the bank-0 carve after the shim; stubs, copies, and the fence
/// are long-addressed and carve from any bank's padding. Returns the CRV
/// and CIV for the shim to program, or null when nothing offloaded.
/// (CIV because $2207/8 is an S-CPU-SIDE register — the SA-1's own
/// stores to it fall on deaf ports, measured as a frame-0 wedge when the
/// prologue tried: the first timer IRQ vectored through CIV=0 into
/// I-RAM garbage.)
fn emitWindowOffloads(
    out: []u8,
    usage: []const u8,
    evidence: ?[]const u8,
    header_off: u32,
    candidates: []const Candidate,
    allow_async_in: bool,
    bank0_at: u32,
    /// Index-split thunk bodies (24-bit): a `JSL` into one is a leaf the
    /// eligibility walk must not mistake for a tree member.
    thunks: []const u24,
    res: *Result,
) ?WinBoot {
    const nmi_native = std.mem.readInt(u16, out[header_off + 0x2A ..][0..2], .little);
    const nmi_emu = std.mem.readInt(u16, out[header_off + 0x3A ..][0..2], .little);
    const nmi_ok = nmi_native >= 0x8000 and
        (nmi_emu == nmi_native or nmi_emu < 0x8000 or nmi_emu == 0xFFFF);
    const allow_async = allow_async_in and nmi_ok;

    var chosen: [offload_max]WinChosen = undefined;
    var n: usize = 0;
    for (candidates) |c| {
        if (n == offload_max) break;
        if (c.entry >> 16 != 0 or (c.entry & 0xFFFF) < 0x8000) continue;
        const e: u16 = @truncate(c.entry);
        const dup = for (chosen[0..n]) |x| {
            if (x.entry == e) break true;
        } else false;
        if (dup) continue;
        // The async monopoly, as in the S3 path: a sibling's un-fenced
        // send mid-flight deadlocks the dispatcher.
        if (n > 0 and chosen[0].is_async) break;
        const spec = windowEligible(out, usage, evidence, thunks, e) orelse continue;
        if (countCallSites(out, usage, e, 0x22) == 0) continue;
        chosen[n] = .{
            .entry = e,
            .spec = spec,
            .is_async = allow_async and !c.no_async and !c.nmi_off and n == 0,
            .nmi_off = c.nmi_off,
        };
        n += 1;
    }
    if (n == 0) return null;

    // --wg-nmi-off support: NMITIMEN is write-only, and the game's own
    // shadow byte is NOT phase-accurate — GIII's transition code writes
    // $4200=0 (screen off, interrupts off) WITHOUT touching its $1E82
    // shadow, so a stub that restored from the shadow RE-ENABLED the
    // NMI inside the game's own interrupts-off bracket (measured: a
    // mid-transition NMI walked a garbage handler pointer through $57
    // buffer data and the game parked forever in its frame-wait with
    // the screen blanked). The truth must be MIRRORED: every covered
    // `STA $4200` is re-pointed at an 8-byte thunk (JSR fits the 3-byte
    // site exactly) that stores A to I-RAM $378F first, then to $4200 —
    // mirror-first, so a caller nested between the two stores reads the
    // value the game was about to set. The stub masks and restores from
    // the mirror: exact, whatever phase the game is in. Sites must all
    // be bank $00 (JSR reach) and the plain-STA shape; anything else
    // (STZ form, other banks) forfeits the wrap, disclosed via stats.
    const nmi_sites: ?NmiSites = blk: {
        var want = false;
        for (chosen[0..n]) |c| {
            if (c.nmi_off and !c.is_async) want = true;
        }
        if (!want) break :blk null;
        var s: NmiSites = .{ .at = undefined, .n = 0 };
        var bank: u32 = 0;
        while (bank * 0x8000 < out.len and bank < 0x40) : (bank += 1) {
            var a16: u32 = 0x8000;
            while (a16 < 0x10000) : (a16 += 1) {
                const cpu = bank << 16 | a16;
                if ((usage[cpu] | usage[0x80_0000 | cpu]) & usage_map.flag_opcode == 0) continue;
                const f = bank * 0x8000 + (a16 - 0x8000);
                if (f + 2 >= out.len) continue;
                const op = out[f];
                if ((op == 0x8D or op == 0x9C) and out[f + 1] == 0x00 and out[f + 2] == 0x42) {
                    if (op == 0x9C or bank != 0 or s.n == s.at.len) break :blk null;
                    s.at[s.n] = f;
                    s.n += 1;
                }
            }
        }
        if (s.n == 0) break :blk null;
        break :blk s;
    };
    res.stats.nmi_off_sites = if (nmi_sites) |s| @intCast(s.n) else 0;

    // Any-bank sizes.
    var any_len: u32 = 0;
    var has_async = false;
    for (chosen[0..n]) |c| {
        any_len += c.spec.total_span;
        if (c.is_async) {
            has_async = true;
            any_len += fenceLen(.{}) + nb_fence_len + win_async_stub_len;
        } else any_len += win_stub_len + (if (c.nmi_off and nmi_sites != null) win_nmi_off_extra else 0);
    }
    // The copies need ONE contiguous run and cannot be split, which puts
    // them in direct competition with the thunk bodies already written
    // into the same padding. When the run is not there, EVERY offload is
    // silently abandoned and the patch ships with none — measured: making
    // the physics tree eligible raised the requirement past what was left
    // and cost the sequencer tree too, 116 dropped frames back to 186,
    // with nothing in the log to say why. Disclose it.
    // Bank-contained: a copy that crosses $xx:FFFF executes into the WRAM
    // mirror when the PC wraps, which after relocation is abandoned memory.
    const any_at = patchgen.findFreeSpaceInBank(out, any_len) orelse {
        res.stats.offload_space_short = any_len;
        return null;
    };
    var cur: u32 = any_at;

    // Copies first (their addresses feed the blocks and stubs).
    var copy_at: [offload_max]u32 = undefined;
    for (chosen[0..n], 0..) |c, i| {
        var member_copy: [ptr_tree_cap]u32 = undefined;
        copy_at[i] = cur;
        for (c.spec.members[0..c.spec.n_members], 0..) |m, mi| {
            member_copy[mi] = cur;
            @memcpy(out[cur..][0..m.span], out[m.entry - 0x8000 ..][0..m.span]);
            cur += m.span;
        }
        for (c.spec.members[0..c.spec.n_members], 0..) |m, mi| {
            fixupJmps(out, usage, m.entry, m.span, member_copy[mi], @intCast(0x8000 + (member_copy[mi] % 0x8000)));
            // Member-to-member JSLs re-point at the copies.
            var pc: u32 = m.entry;
            while (pc - m.entry < m.span) {
                if (usage[pc] & usage_map.flag_opcode == 0) {
                    pc += 1;
                    continue;
                }
                const mf = pc - 0x8000;
                const op = out[mf];
                if (op == 0x22 and out[mf + 3] == 0x00) {
                    const tgt = std.mem.readInt(u16, out[mf + 1 ..][0..2], .little);
                    for (c.spec.members[0..c.spec.n_members], 0..) |m2, mj| {
                        if (m2.entry != tgt) continue;
                        const dst = member_copy[mi] + (pc - m.entry);
                        std.mem.writeInt(u16, out[dst + 1 ..][0..2], @intCast(0x8000 + (member_copy[mj] % 0x8000)), .little);
                        out[dst + 3] = @intCast(member_copy[mj] / 0x8000);
                        break;
                    }
                }
                const m8 = usage[pc] & usage_map.flag_m != 0;
                const x8 = usage[pc] & usage_map.flag_x != 0;
                pc += usage_map.instrLen(op, m8, x8);
            }
        }
        res.stats.offload_copy[i] = @as(u24, @intCast(copy_at[i] / 0x8000)) << 16 |
            @as(u24, @intCast(0x8000 + (copy_at[i] % 0x8000)));
        res.stats.offload_copy_len[i] = c.spec.total_span;
    }

    // Fence for the async offload, then the stubs; re-point call sites.
    var fence24: u24 = 0;
    var nb_fence24: u24 = 0;
    for (chosen[0..n], 0..) |c, i| {
        const id: u8 = @intCast(i + 1);
        if (c.is_async) {
            const flen = emitFence(out[cur..], .{});
            std.debug.assert(flen == fenceLen(.{}));
            fence24 = @as(u24, @intCast(cur / 0x8000)) << 16 |
                @as(u24, @intCast(0x8000 + (cur % 0x8000)));
            res.stats.async_entry = c.entry;
            res.stats.async_fence = fence24;
            cur += flen;
            const nblen = emitNbFence(out[cur..]);
            std.debug.assert(nblen == nb_fence_len);
            nb_fence24 = @as(u24, @intCast(cur / 0x8000)) << 16 |
                @as(u24, @intCast(0x8000 + (cur % 0x8000)));
            cur += nblen;
        }
        const stub_file = cur;
        const stub_wrap = c.nmi_off and nmi_sites != null;
        const slen = if (c.is_async)
            emitWinAsyncStub(out[cur..], fence24, id, c.entry)
        else
            emitWinStub(out[cur..], id, c.entry, stub_wrap);
        std.debug.assert(slen == if (c.is_async)
            win_async_stub_len
        else
            win_stub_len + (if (stub_wrap) win_nmi_off_extra else 0));
        cur += slen;
        const stub_bank: u8 = @intCast(stub_file / 0x8000);
        const stub_addr: u16 = @intCast(0x8000 + (stub_file % 0x8000));
        res.stats.offload_sites += rewriteCallSites(out, usage, c.entry, 0x22, stub_addr, stub_bank);
        res.stats.offload_entries[i] = c.entry;
        res.stats.offload_ptr_mask |= @as(u8, 1) << @intCast(i);
    }
    std.debug.assert(cur - any_at == any_len);

    // The dispatcher, in the bank-0 carve after the shim.
    const d = out[bank0_at..];
    var dc: usize = 0;
    const dp_base: u16 = 0x3700;
    const base16: u16 = @intCast(0x8000 + (bank0_at % 0x8000));
    // Prologue: I-RAM/BW-RAM gates, CBM block 0 (the identity window!),
    // native mode, 16-bit X, stack under the mailbox, D — then the
    // watchdog: the linear timer with a V budget, CIC BEFORE CIE (the
    // clear bit is the line mask — enabling with it unset asserts the
    // IRQ line at once, and the first dispatch's PLP of a mainline
    // caller's P would take it instantly). CIV is programmed by the
    // S-CPU shim: $2207/8 is not writable from this side.
    const abort_addr: u16 = base16 + @as(u16, @intCast(51 + 12 + n * win_block_len + 3 + 19 + 29 + 24));
    put(d, &dc, &.{ 0x78, 0xA9, 0xFF, 0x8D, 0x2A, 0x22, 0xA9, 0x80, 0x8D, 0x27, 0x22, 0x9C, 0x25, 0x22, 0x18, 0xFB, 0xC2, 0x10, 0xA2, 0x78, 0x37, 0x9A, 0xF4, @truncate(dp_base), @truncate(dp_base >> 8), 0x2B });
    put(d, &dc, &.{ 0xA9, win_watchdog_vcnt, 0x8D, 0x14, 0x22 }); // VCNT lo
    put(d, &dc, &.{ 0xA9, 0x00, 0x8D, 0x15, 0x22 }); // VCNT hi
    put(d, &dc, &.{ 0xA9, 0x82, 0x8D, 0x10, 0x22 }); // TMC: linear, V compare
    put(d, &dc, &.{ 0xA9, 0x40, 0x8D, 0x0B, 0x22 }); // CIC: line masked...
    put(d, &dc, &.{ 0xA9, 0x40, 0x8D, 0x0A, 0x22 }); // ...THEN CIE: timer IRQ
    std.debug.assert(dc == 51);
    const loop_addr: u16 = base16 + @as(u16, @intCast(dc));
    put(d, &dc, &.{ 0xE2, 0x20, 0xAD, 0x01, 0x23, 0x29, 0x0F, 0xF0, 0xF7, 0x8D, 0x87, 0x37 });
    const blocks_at = dc;
    dc += n * win_block_len; // blocks emitted below, once sig/unm/mar addresses exist
    put(d, &dc, &.{ 0x4C, @truncate(loop_addr), @truncate(loop_addr >> 8) });
    const sig_addr: u16 = base16 + @as(u16, @intCast(dc));
    put(d, &dc, &.{ 0xAD, 0x87, 0x37, 0x8D, 0x09, 0x22, 0xAD, 0x01, 0x23, 0x29, 0x0F, 0xD0, 0xF9, 0x9C, 0x09, 0x22, 0x4C, @truncate(loop_addr), @truncate(loop_addr >> 8) });
    const unm_addr: u16 = base16 + @as(u16, @intCast(dc));
    // The unmarshal sets the GAME DBR itself, and the mailbox reads that
    // follow it go LONG. Ordering is load-bearing: a caller pinned to
    // BW-RAM marshals DBR=$40, and an absolute $37xx read under that
    // bank lands in BW-RAM game data, not I-RAM — the tree then runs
    // with garbage registers and a garbage P (measured: the async
    // flavor's pinned caller entered the copy in m8/x8, misparsed the
    // m16 stream, and ran away until the watchdog). X and Y load first,
    // under the dispatcher's DBR, because LDX/LDY have no long form.
    put(d, &dc, &.{ 0xC2, 0x10, 0xAE, 0x82, 0x37, 0xAC, 0x84, 0x37 }); // REP #$10; LDX; LDY
    put(d, &dc, &.{ 0xAD, 0x8B, 0x37, 0x48, 0xAB }); // game DBR
    put(d, &dc, &.{ 0xAF, 0x86, 0x37, 0x00, 0x48 }); // P (long), pushed
    put(d, &dc, &.{ 0xAF, 0x81, 0x37, 0x00, 0xEB, 0xAF, 0x80, 0x37, 0x00 }); // B, A (long)
    put(d, &dc, &.{ 0x28, 0x60 }); // PLP; RTS
    const mar_addr: u16 = base16 + @as(u16, @intCast(dc));
    put(d, &dc, &.{ 0x08, 0xC2, 0x10, 0x8E, 0x82, 0x37, 0x8C, 0x84, 0x37, 0xE2, 0x20, 0x8D, 0x80, 0x37, 0xEB, 0x8D, 0x81, 0x37, 0xEB, 0x68, 0x8D, 0x86, 0x37, 0x60 });
    // The watchdog's abort handler; the resume shape is bank 0 inside
    // the blocks region (the only place a dispatch opens IRQs).
    std.debug.assert(base16 + @as(u16, @intCast(dc)) == abort_addr);
    const blocks_lo: u16 = base16 + @as(u16, @intCast(blocks_at));
    emitWinAbort(d, &dc, blocks_lo, blocks_lo + @as(u16, @intCast(n * win_block_len)), sig_addr);
    const nmi_at = dc;
    var bc = blocks_at;
    for (chosen[0..n], 0..) |_, i| {
        const id: u8 = @intCast(i + 1);
        emitWinBlock(d, &bc, id, @intCast(0x8000 + (copy_at[i] % 0x8000)), @intCast(copy_at[i] / 0x8000), unm_addr, mar_addr, sig_addr, dp_base);
    }
    std.debug.assert(bc == blocks_at + n * win_block_len);

    // Async: the NMI prologue (bank 0 — the vector is 16-bit), vectors.
    if (has_async) {
        var nc = nmi_at;
        put(d, &nc, &.{ 0x08, 0xC2, 0x30, 0x48, 0xDA, 0x5A, 0x8B });
        put(d, &nc, &.{ 0x22, @truncate(nb_fence24), @truncate(nb_fence24 >> 8), @truncate(nb_fence24 >> 16) });
        put(d, &nc, &.{ 0xAB, 0xC2, 0x30, 0x7A, 0xFA, 0x68, 0x28 });
        put(d, &nc, &.{ 0x4C, @truncate(nmi_native), @truncate(nmi_native >> 8) });
        std.debug.assert(nc - nmi_at == nmi_prologue_len);
        const nmi_addr: u16 = base16 + @as(u16, @intCast(nmi_at));
        std.mem.writeInt(u16, out[header_off + 0x2A ..][0..2], nmi_addr, .little);
        std.mem.writeInt(u16, out[header_off + 0x3A ..][0..2], nmi_addr, .little);
    }

    // The $4200-mirror thunks (nmi-off wrap): each covered `STA $4200`
    // becomes `JSR thunk`; the thunk stores A to the mirror FIRST, then
    // to the register, so a caller nested between the two stores reads
    // the value the game was about to set.
    if (nmi_sites) |s| {
        var tc = nmi_at + @as(usize, if (has_async) nmi_prologue_len else 0);
        for (s.at[0..s.n]) |site| {
            const thunk_addr: u16 = base16 + @as(u16, @intCast(tc));
            put(d, &tc, &.{ 0x8F, 0x8F, 0x37, 0x00 }); // mirror first
            put(d, &tc, &.{ 0x8D, 0x00, 0x42 }); // then NMITIMEN
            put(d, &tc, &.{0x60});
            out[site] = 0x20;
            std.mem.writeInt(u16, out[site + 1 ..][0..2], thunk_addr, .little);
        }
    }

    res.stats.offload_count = @intCast(n);
    res.stats.offloaded = chosen[0].entry;
    res.stats.pointer_offloads = @intCast(n);
    res.stats.resident_offloads = @intCast(n); // by construction
    return .{ .crv = base16, .civ = abort_addr };
}
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
fn extendCoverage(
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

    const Item = struct { addr: u24, m8: bool, x8: bool };
    var stack: std.array_list.Managed(Item) = .init(gpa);
    defer stack.deinit();

    if (header.reset_vector >= 0x8000)
        try stack.append(.{ .addr = header.reset_vector, .m8 = true, .x8 = true });
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
                seen[file] = true;
                const op = image[file];
                const len: u32 = usage_map.instrLen(op, m8, x8);
                if (a16 + len > 0x10000) break;
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
                        try stack.append(.{ .addr = @intCast((wbank << 16) | t), .m8 = m8, .x8 = x8 });
                        break;
                    },
                    0x5C, 0x22 => { // JML long / JSL long
                        const t = std.mem.readInt(u16, image[file + 1 ..][0..2], .little);
                        const tb: u32 = image[file + 3] & 0x7F;
                        try stack.append(.{ .addr = @intCast((tb << 16) | t), .m8 = m8, .x8 = x8 });
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
                        try stack.append(.{ .addr = @intCast((wbank << 16) | t), .m8 = m8, .x8 = x8 });
                    },
                    0x80, 0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0 => {
                        const rel: i8 = @bitCast(image[file + 1]);
                        const t = (a16 +% 2 +% @as(u32, @bitCast(@as(i32, rel)))) & 0xFFFF;
                        try stack.append(.{ .addr = @intCast((wbank << 16) | t), .m8 = m8, .x8 = x8 });
                        if (op == 0x80) break; // BRA is unconditional
                    },
                    0x82 => { // BRL
                        const rel: i16 = @bitCast(std.mem.readInt(u16, image[file + 1 ..][0..2], .little));
                        const t = (a16 +% 3 +% @as(u32, @bitCast(@as(i32, rel)))) & 0xFFFF;
                        try stack.append(.{ .addr = @intCast((wbank << 16) | t), .m8 = m8, .x8 = x8 });
                        break;
                    },
                    // Indirect control transfers: statically opaque. (JSR
                    // (abs,X) does fall through on return, so it continues.)
                    0x6C, 0x7C, 0xDC => break,
                    else => {},
                }
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
                        const dflags = usage[cpu2] | usage[0x80_0000 | cpu2];
                        const data_only = dflags & (usage_map.flag_read | usage_map.flag_write) != 0 and
                            dflags & usage_map.flag_opcode == 0;
                        const cell = std.mem.readInt(u16, image[f2 + 1 ..][0..2], .little);
                        if (cell < 0x2000 and !data_only) ptr_bank[cell] = @intCast(pb2 + 1);
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
                if (acell < 0x2000 and ptr_bank[acell] != 0) cell_active[acell] = true;
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
                const tfile = db3 * 0x8000 + (tgt - 0x8000);
                if (tfile >= image.len) continue;
                const x8_3 = covered3 and fl3 & usage_map.flag_x != 0;
                if (!seen[tfile]) {
                    try stack.append(.{ .addr = @intCast(taddr), .m8 = false, .x8 = x8_3 });
                    grew = true;
                }
                if (!covered3 and !seen[f3]) {
                    try stack.append(.{ .addr = @intCast(c3), .m8 = false, .x8 = x8_3 });
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
                // Same DATA-GATE as the ptr_bank scan: a byte the profile READ
                // without executing is data, and marking it as a dispatcher
                // start window-shifts a fake operand inside it (the Ceres
                // door-stream `FC FC 0A` confetti byte).
                const mflags = usage[msite] | usage[0x80_0000 | msite];
                if (mflags & (usage_map.flag_read | usage_map.flag_write) != 0 and
                    mflags & usage_map.flag_opcode == 0) continue;
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

/// Convert for whole-game migration. Needs only the coverage map — no plan:
/// state stays at its own addresses inside the identity window.
/// A split anchor's displaced prefix must be whole instructions with no
/// flow op: both the enqueue stub and the pump trampoline re-execute
/// those bytes at a different address.
fn splitPrefixSpan(out: []const u8, usage: []const u8, entry: u24, need: u32) u32 {
    var pc: u32 = entry;
    while (pc - entry < need) {
        if ((pc & 0xFFFF) + 8 > 0x10000) return 0;
        const op = out[splitFile(@intCast(pc))];
        switch (op) {
            // Branches, jumps, bank-local calls, returns, PER/BRL: a copy
            // of these means something else. A JSL ($22) is position-
            // independent and returns into the copy, so it may ride.
            0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0, 0x80, 0x82, 0x62, 0x20, 0xFC, 0x4C, 0x5C, 0x6C, 0x7C, 0xDC, 0x60, 0x6B, 0x40, 0x00, 0x02, 0xCB, 0xDB => return 0,
            else => {},
        }
        const u = splitUsage(usage, @intCast(pc));
        const m8 = u & usage_map.flag_m != 0;
        const x8 = u & usage_map.flag_x != 0;
        pc += usage_map.instrLen(op, m8, x8);
    }
    // Anything past `need` is NOP-filled at the site, so the enqueue
    // stub's RTS (landing at entry+3) walks fill until the boundary.
    return if (pc - entry <= 8) pc - entry else 0;
}

/// S5: emit the mainline/NMI split scaffold into the bank-$00 carve
/// after the shim slot, swap the declared ranges' $4212/$421x reads to
/// the I-RAM mirrors, and displace the anchors. See `SplitSpec`.
fn emitSplit(
    out: []u8,
    usage: []const u8,
    spec: SplitSpec,
    d: []u8,
    base16: u16,
    far: *FarPad,
    carve: u32,
    carve_len: u32,
    refusal: *?Refusal,
    res: *Result,
) Error!void {
    // Anchor shapes first: nothing is written until every check holds.
    if (spec.tail == 0) {
        if (splitPrefixSpan(out, usage, spec.mainloop, 4) < 4)
            return refuse(refusal, .{ .reason = .wg_split_shape, .detail = spec.mainloop });
    } else if (out[spec.tail - 0x8000] != 0x22 or spec.tail_epilogue == 0) {
        return refuse(refusal, .{ .reason = .wg_split_shape, .detail = spec.tail });
    }
    for (spec.io_entries) |io| {
        if (splitPrefixSpan(out, usage, io.entry, 3) == 0)
            return refuse(refusal, .{ .reason = .wg_split_shape, .detail = io.entry });
    }
    if (spec.io_entries.len > 26)
        return refuse(refusal, .{ .reason = .wg_split_shape, .detail = 0 });

    // Mirror swaps: absolute reads of $4212 -> $3792 and $4218-$421F ->
    // $3794+, inside the declared ranges only. The pump feeds the cells
    // continuously post-engage; boot-path readers outside the ranges
    // keep the real registers.
    var displaced: [512]Displaced = undefined;
    var n_displaced: u32 = 0;
    if (spec.tail == 0) {
        try emitSplitReaders(out, usage, spec, far, carve, carve_len, &displaced, &n_displaced, refusal);
    } else for (spec.vbl_ranges) |r| {
        var pc: u32 = r[0];
        while (pc < r[1]) {
            const f = splitFile(@intCast(pc));
            const op = out[f];
            const u = splitUsage(usage, @intCast(pc));
            const m8 = u & usage_map.flag_m != 0;
            const x8 = u & usage_map.flag_x != 0;
            const len = usage_map.instrLen(op, m8, x8);
            const md = usage_map.mode(op);
            if (len == 3 and (md == .abs or md == .abs_x or md == .abs_y)) {
                const v = std.mem.readInt(u16, out[f + 1 ..][0..2], .little);
                const nv: u16 = if (v == 0x4212)
                    split_vbl_mirror
                else if (v >= 0x4218 and v <= 0x421F)
                    split_pad_mirror + (v - 0x4218)
                else
                    0;
                if (nv != 0)
                    std.mem.writeInt(u16, out[f + 1 ..][0..2], nv, .little);
            }
            pc += len;
        }
    }

    // The S-CPU-multiplier idiom: a 16-bit STA $4202 (both multiplicands,
    // the high write triggering), the 8-cycle NOP wait, LDA $4216 for the
    // product. On the SA-1 those registers are open bus, so the span is
    // displaced with a JSL to a helper the engaged cell splits: the
    // original sequence pre-engage and on the pump, the SA-1's own
    // arithmetic unit ($2251+, immediate) on the mainline. Strict shape
    // only — anything looser is a named refusal, not a guess.
    var mul_sites: [4]u32 = undefined;
    var n_mul: usize = 0;
    var math_sites: [1024]MathSite = undefined;
    var n_math_sites: u32 = 0;
    // The DUAL IMAGE (mainloop flavor, 8 MiB images): the lower 4 MiB is
    // the S-CPU's game, stock bytes at every math site; the upper 4 MiB a
    // copy that carries the COP sites, and the mapper registers switch the
    // whole cartridge between them at each ownership handoff. Measured on
    // Super Metroid: with COPs in the one image, the S-CPU's own eras ran
    // ~150 cycles slower per math access, the Ceres intro gained lag
    // frames, and the frame-counter-fed state forked for good.
    const dual = spec.tail == 0 and out.len >= 8 * 1024 * 1024;
    if (spec.tail == 0) {
        try emitSplitMath(out, usage, far, carve, carve_len, &math_sites, &n_math_sites, refusal, res);
    } else {
        var bank: u32 = 0;
        while (bank * 0x8000 < out.len and bank < 0x40) : (bank += 1) {
            var aa: u32 = 0x8000;
            while (aa < 0xFFF6) : (aa += 1) {
                const ac = (bank << 16) | aa;
                if ((usage[ac] | usage[0x80_0000 | ac]) & usage_map.flag_opcode == 0) continue;
                const file = bank * 0x8000 + (aa - 0x8000);
                if (!std.mem.eql(u8, out[file..][0..3], &.{ 0x8D, 0x02, 0x42 })) continue;
                // Only the FULL idiom is claimed. A bare STA $4202 (the
                // boot's register-clear sweep has eleven of them) is a
                // write that vanishes harmlessly on the SA-1; a product
                // READ without this shape shows up in the audit instead.
                if (!std.mem.eql(u8, out[file + 3 ..][0..4], &.{ 0xEA, 0xEA, 0xEA, 0xEA }) or
                    !std.mem.eql(u8, out[file + 7 ..][0..3], &.{ 0xAD, 0x16, 0x42 }))
                    continue;
                if (n_mul == mul_sites.len)
                    return refuse(refusal, .{ .reason = .wg_split_shape, .detail = ac });
                mul_sites[n_mul] = file;
                n_mul += 1;
            }
        }
    }

    var cur: usize = wg_window_shim_max;
    if (n_mul != 0) {
        // The helper, in the carve (JSL-reachable from every bank).
        const mul16: u16 = base16 + @as(u16, @intCast(cur));
        put(d, &cur, &.{ 0x48, 0xAF, @truncate(split_engaged), 0x37, 0x00 }); // PHA / LDA engaged (16-bit; the scratch neighbor masks off)
        put(d, &cur, &.{ 0x29, 0xFF, 0x00 }); // AND #$00FF
        put(d, &cur, &.{ 0xD0, 0x0C }); // BNE sa1 path
        put(d, &cur, &.{ 0x68, 0x8D, 0x02, 0x42 }); // PLA / STA $4202 — the original
        put(d, &cur, &.{ 0xEA, 0xEA, 0xEA, 0xEA }); // the hardware's 8 cycles
        put(d, &cur, &.{ 0xAD, 0x16, 0x42, 0x6B }); // LDA $4216 / RTL
        // sa1: the arithmetic unit — MA = low byte, MB = high byte.
        put(d, &cur, &.{ 0x68, 0x48, 0x29, 0xFF, 0x00 }); // PLA / PHA / AND #$00FF
        put(d, &cur, &.{ 0x8F, 0x51, 0x22, 0x00 }); // MA
        put(d, &cur, &.{ 0x68, 0xEB, 0x29, 0xFF, 0x00 }); // PLA / XBA / AND #$00FF
        put(d, &cur, &.{ 0x8F, 0x53, 0x22, 0x00 }); // MB — the $2254 write triggers
        put(d, &cur, &.{ 0xAF, 0x06, 0x23, 0x00, 0x6B }); // product / RTL
        for (mul_sites[0..n_mul]) |file| {
            out[file] = 0x22; // JSL helper
            std.mem.writeInt(u16, out[file + 1 ..][0..2], mul16, .little);
            out[file + 3] = 0x00;
            @memset(out[file + 4 ..][0..6], 0xEA);
        }
        res.stats.split_mul = @intCast(n_mul);
    }

    // The audit: covered WAI/STP (the SA-1 gets no interrupts, so a
    // mainline WAI never wakes), and any covered absolute MMIO read the
    // split leaves unhandled — open bus on the SA-1. Report, capped;
    // verification arbitrates what the operator accepts.
    {
        var bank: u32 = 0;
        while (bank * 0x8000 < out.len and bank < 0x40) : (bank += 1) {
            var aa: u32 = 0x8000;
            while (aa < 0x10000) : (aa += 1) {
                const ac = (bank << 16) | aa;
                if ((usage[ac] | usage[0x80_0000 | ac]) & usage_map.flag_opcode == 0) continue;
                const file = bank * 0x8000 + (aa - 0x8000);
                const op = out[file];
                var hazard = op == 0xCB or op == 0xDB;
                if (!hazard and (op == 0xAD or op == 0xAC or op == 0xAE or op == 0x2C or op == 0xCD)) {
                    const v = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                    hazard = (v >= 0x2100 and v <= 0x21FF) or (v >= 0x4200 and v <= 0x43FF);
                }
                if (hazard and res.stats.n_split_hazards < res.stats.split_hazards.len) {
                    res.stats.split_hazards[res.stats.n_split_hazards] = @intCast(ac);
                    res.stats.n_split_hazards += 1;
                }
            }
        }
    }

    if (spec.tail != 0) {
        // === NMI-TAIL FLAVOR (see SplitSpec.tail) =====================
        // --- tok stub: the S-CPU boundary, once per frame in vblank ---
        const tok16: u16 = base16 + @as(u16, @intCast(cur));
        // The boundary is reachable along MORE than the vectored head —
        // a transition path arrives with its own D (measured: D=0, three
        // frames into a stage banner) — and the drain's replayed bodies
        // are dp users. Pin the window D for the stub's whole span and
        // hand back whatever the caller had.
        put(d, &cur, &.{ 0x0B, 0xC2, 0x20, 0xA9, @truncate(wg_bw_window), @truncate(wg_bw_window >> 8), 0x5B }); // PHD; D = the window
        put(d, &cur, &.{0x8B}); // PHB
        put(d, &cur, &.{ 0xE2, 0x20 }); // SEP #$20 (M widths per the handler)
        // DBR = $00 EXPLICITLY — not PHK: under fastrom the boundary
        // executes from PBR=$80, and a PHK'd DBR sends every absolute
        // $37xx at a mirror whose I-RAM mapping is nobody's contract.
        // The offload stubs always went long for exactly this reason.
        put(d, &cur, &.{ 0xA9, 0x00, 0x48, 0xAB }); // LDA #$00 / PHA / PLB
        put(d, &cur, &.{ 0xAD, @truncate(split_engaged), 0x37 });
        const bne_at = cur;
        put(d, &cur, &.{ 0xD0, 0x00 }); // BNE engaged (patched)
        put(d, &cur, &.{ 0xA9, 0xFF, 0x8D, 0x29, 0x22 }); // SIWP open
        put(d, &cur, &.{ 0x9C, @truncate(split_ring_wr), 0x37, 0x9C, @truncate(split_ring_rd), 0x37 });
        put(d, &cur, &.{ 0x9C, @truncate(split_token), 0x37, 0x9C, @truncate(split_last), 0x37 });
        put(d, &cur, &.{ 0x9C, @truncate(split_in_replay), 0x37 });
        const crv_ref = cur;
        put(d, &cur, &.{ 0xA9, 0x00, 0x8D, 0x03, 0x22, 0xA9, 0x00, 0x8D, 0x04, 0x22 }); // CRV (patched)
        put(d, &cur, &.{ 0xA9, 0x01, 0x8D, @truncate(split_engaged), 0x37 }); // engaged = 1
        put(d, &cur, &.{ 0x9C, 0x00, 0x22 }); // release the SA-1
        d[bne_at + 1] = @intCast(cur - (bne_at + 2));
        // The boundary is ALSO reachable on the SA-1: the hazard audit
        // proves the tail re-enters the handler head ($8237's $4210 ack
        // is in its static reach), and that walk ends here. Without a
        // CPU test the SA-1 spins in the auto-joy wait on open bus — or
        // worse, bumps the token and wedges the gate arithmetic. The
        // SA-1 branch unwinds the pins and does exactly what the stock
        // boundary did: the displaced JSL, then the tail.
        put(d, &cur, &.{ 0xC2, 0x20, 0x3B, 0x29, 0x00, 0xF0, 0xC9, 0x00, 0x30 }); // TSC & $F000 == $3000?
        put(d, &cur, &.{ 0xD0, 0x03 }); // BNE over the BRL (not the SA-1)
        const tok_sa1_at = cur;
        put(d, &cur, &.{ 0x82, 0x00, 0x00 }); // BRL the SA-1 island (patched; past the pump's reach)
        put(d, &cur, &.{ 0xE2, 0x20 });
        // engaged: run the displaced boundary instruction — JSL $892B —
        // NATIVELY. The S-CPU polls the real pads at the game's own
        // cadence (the verifier pairs runs poll-for-poll, and a mirror
        // diet here left the baseline ~246 polls ahead through the
        // loader), and the results land in window dp cells the SA-1
        // tail reads directly. No pad mirrors at all.
        @memcpy(d[cur .. cur + 4], out[spec.tail - 0x8000 ..][0..4]);
        cur += 4;
        // M=8 FORCED after the replay: $892B returns wide, and a 16-bit
        // INC on the token treats token+last as one word — fine for 255
        // crossings, then the FF->00 carry clobbers `last` in the same
        // cycle and no edge ever reaches the SA-1 (measured: the wedge
        // at exactly the 256th crossing, frame 455).
        put(d, &cur, &.{ 0xE2, 0x20 });
        // MODE GATE: outside gameplay the tail runs nested-native (the
        // branch below unpins and runs the chain on this CPU). The dp
        // read goes through the pinned window D, the single home both
        // CPUs share. The token freezes across the era; the SA-1 idles
        // at its edge-gate and wakes when gameplay returns.
        // BEQ-over-BRL: the nested-native branch sits past the whole pump
        // loop (166 bytes measured), out of a short branch's reach — the
        // original BNE truncated to $A6 and jumped BACKWARD into the tok's
        // own bytes. It was never taken on a verified path; the mode gate
        // takes it every menu frame and wedged at engage (frame 232).
        var tok_mode_at: usize = 0;
        if (spec.mode_gate) {
            put(d, &cur, &.{ 0xA5, @truncate(spec.mode_cell), 0xC9, spec.mode_value });
            put(d, &cur, &.{ 0xF0, 0x03 }); // BEQ over the BRL
            tok_mode_at = cur;
            put(d, &cur, &.{ 0x82, 0x00, 0x00 }); // BRL the nested-native branch (patched)
        }
        // REENTRANT full path: the transition runs as a multi-frame NMI
        // ($3C is stock's own nesting guard and the transition handler
        // clears it mid-flight), so a real per-frame NMI can take the
        // full path while a tail — or a parked replay — is still in
        // flight beneath us. The SA-1 is busy then; dispatching a second
        // token deadlocks the nested gate on top of the very replay it
        // suspends (measured: tok=3/done=2, frame ~714). Stock ran the
        // nested tail on the S-CPU — so do exactly that: unpin and run
        // the chain natively; the stubs run bodies directly for S-CPU
        // callers, and the shared window makes the state evolution
        // identical.
        put(d, &cur, &.{ 0xAD, @truncate(split_done), 0x37, 0xCD, @truncate(split_token), 0x37 });
        put(d, &cur, &.{ 0xF0, 0x03 }); // BEQ over the BRL (done == token: dispatch)
        const tok_nest_at = cur;
        put(d, &cur, &.{ 0x82, 0x00, 0x00 }); // BRL the nested-native branch (patched)
        // Dispatch, then PUMP until the tail lands. A pure exit-wait
        // deadlocked (the SA-1's enqueued uploads starve without the
        // drain); pure non-blocking let the mainline overlap the tail
        // and the shared fade cells ($3A/$3E/$1280) diverged from tick
        // 3. The wait body IS the pump: each lap re-feeds the vbl
        // mirror live (stock's $892B reads $4212 live too) and replays
        // one ring entry, so the gate cannot starve what it waits on.
        put(d, &cur, &.{ 0xEE, @truncate(split_token), 0x37 }); // token++
        const drain16: u16 = base16 + @as(u16, @intCast(cur));
        // Widths are forced EVERY lap: a replayed body returns with
        // whatever REP it last executed (measured: $86E1 left m16, the
        // 8-bit ring compare read the vbl mirror as a high byte, and the
        // drain spun forever).
        put(d, &cur, &.{ 0xE2, 0x30 }); // SEP #$30
        put(d, &cur, &.{ 0xAD, @truncate(split_ring_rd), 0x37, 0xCD, @truncate(split_ring_wr), 0x37 });
        const beq2_at = cur;
        put(d, &cur, &.{ 0xF0, 0x00 }); // BEQ the done-check (patched)
        // rd consumes EARLY — a nested NMI's drain must see this entry
        // gone (re-entering an in-service call regressed forever); the
        // RPC release is the ACK bump after the body instead.
        put(d, &cur, &.{ 0xAA, 0xBD, @truncate(split_ring), 0x37, 0x48 });
        put(d, &cur, &.{ 0xE8, 0x8A, 0x29, 0x0F, 0x8D, @truncate(split_ring_rd), 0x37 });
        put(d, &cur, &.{ 0x68, 0x0A, 0xAA });
        // The pump's pinned DBR=$00 is the body's contract too: the
        // relocation shifts low-absolute operands into the $6000 window,
        // which every bank $00-$3F maps identically. The replay borrows
        // the CALLER's D (see the far stub's capture) — the body's dp
        // rewrites were made against it — then the pump's pins return.
        // The replay runs on a SCRATCH STACK (real WRAM — unused under
        // the relocation). RE-ENTRANT: a nested NMI's drain that arrives
        // already on the scratch page must NOT reset S to the top — that
        // trampled the outer replay's frames and the nested RTI popped
        // garbage (measured: P=$F5/PC=$02:8553, frame ~1131). Old S rides
        // on the stack either way, so the restore is uniform.
        // (original note follows)
        // the relocation, and a $1xxx page keeps the far stubs' CPU
        // discriminator honest). The game writes transition records into
        // its own FREED stack bytes; stock survives because its frames
        // sit below them, and our extra gate/trampoline depth moved a
        // return frame into the write zone (measured: an $A77B record
        // shredded the $7DE8 frame, frame ~714). Old S rides ON the
        // scratch stack, so nested drains unwind naturally.
        put(d, &cur, &.{ 0xC2, 0x30, 0x3B, 0xA8, 0x29, 0x00, 0xFF, 0xC9, 0x00, 0x1B, 0xF0, 0x04, 0xA9, 0xFF, 0x1B, 0x1B, 0x98, 0x48, 0xE2, 0x30 });
        put(d, &cur, &.{ 0xC2, 0x20, 0xAD, @truncate(split_cell_d), 0x37, 0x5B, 0xE2, 0x20 });
        // WIDTHS ONLY (AND #$30): the SA-1's P carries I=1 — it runs masked
        // by design — and PLPing it whole masked NMI on the S-CPU for the
        // replay's span; a multi-frame sample stream then lost every nested
        // frame its APU handshake depends on (measured: $9A68 spinning at
        // p=$04 with no NMI for 400K cycles, frame 745).
        // The dispatch pointer is fetched FIRST (it needs the drain's X),
        // then the caller's registers come back — A, X, Y from the stub's
        // capture, widths via P — and the call goes through the scratch
        // pointer, PEA giving it a JSR-shaped frame.
        put(d, &cur, &.{ 0xC2, 0x30 });
        const jsr2_at = cur;
        put(d, &cur, &.{ 0xBD, 0x00, 0x00 }); // LDA tbl,X — patched by emitSplitIo
        put(d, &cur, &.{ 0x8D, @truncate(split_cell_t), 0x37 });
        put(d, &cur, &.{ 0xAE, @truncate(split_cell_x), 0x37, 0xAC, @truncate(split_cell_y), 0x37 });
        put(d, &cur, &.{ 0xE2, 0x20 });
        put(d, &cur, &.{ 0xAD, @truncate(split_cell_pw), 0x37, 0x29, 0x30, 0x48 });
        put(d, &cur, &.{ 0xC2, 0x20, 0xAD, @truncate(split_cell_a), 0x37, 0x28 });
        const ret1: u16 = base16 + @as(u16, @intCast(cur)) + 6;
        put(d, &cur, &.{ 0xF4, @truncate(ret1 - 1), @truncate((ret1 - 1) >> 8) }); // PEA return-1
        put(d, &cur, &.{ 0x6C, @truncate(split_cell_t), 0x37 }); // JMP (cell_t)
        put(d, &cur, &.{ 0xE2, 0x30 }); // widths again — the body's REPs leak
        put(d, &cur, &.{ 0xA9, 0x00, 0x48, 0xAB });
        put(d, &cur, &.{ 0xC2, 0x20, 0xA9, @truncate(wg_bw_window), @truncate(wg_bw_window >> 8), 0x5B, 0xE2, 0x20 });
        put(d, &cur, &.{ 0xC2, 0x20, 0x68, 0x1B, 0xE2, 0x20 }); // old S back
        put(d, &cur, &.{ 0xEE, @truncate(split_rpc_ack), 0x37 }); // the RPC release
        put(d, &cur, &.{ 0x4C, @truncate(drain16), @truncate(drain16 >> 8) });
        d[beq2_at + 1] = @intCast(cur - (beq2_at + 2));
        // Ring-2 backpressure: at half-full, drain it here — the frame
        // exits that normally drain it don't happen while a multi-frame
        // transition keeps this gate closed.
        put(d, &cur, &.{ 0xAD, @truncate(split_ring2_wr), 0x37, 0x38, 0xED, @truncate(split_ring2_rd), 0x37 });
        put(d, &cur, &.{ 0xB0, 0x02, 0x69, 0x18 }); // mod-24 distance
        put(d, &cur, &.{ 0xC9, 0x0C });
        const r2bp_at = cur;
        put(d, &cur, &.{ 0x90, 0x03 }); // BCC past the call
        put(d, &cur, &.{ 0x20, 0x00, 0x00 }); // JSR r2 drain (patched)
        // Stock's overrun release, performed by the gate: $86CD parks a
        // waiter on $3C's bit7, and on stock the NEXT NMI's overrun path
        // rewrites $3C:=1 to release it. While the S-CPU is gated here
        // no such NMI can run — but the gate IS the NMI in progress, so
        // when the tail itself is the waiter (the SA-1 runs $86CD
        // natively), the gate makes stock's write for it.
        put(d, &cur, &.{ 0xA5, 0x3C, 0x10, 0x0A }); // dp via pinned D — BPL past the release
        put(d, &cur, &.{ 0xC2, 0x20, 0xA9, 0x01, 0x00, 0x85, 0x3C, 0xE2, 0x30, 0xEA });
        put(d, &cur, &.{ 0xAD, @truncate(split_done), 0x37, 0xCD, @truncate(split_token), 0x37 });
        // BEQ-over-BRL: the pump body outgrew a short branch's reach
        // (the Debug build panicked on the cast; ReleaseFast would have
        // emitted a silently wrong offset).
        put(d, &cur, &.{ 0xF0, 0x03 }); // BEQ done: fall out of the gate
        const back = @as(i32, @intCast(drain16)) - (@as(i32, @intCast(base16)) + @as(i32, @intCast(cur)) + 3);
        put(d, &cur, &.{ 0x82, @truncate(@as(u32, @bitCast(back))), @truncate(@as(u32, @bitCast(back)) >> 8) }); // BRL the pump head
        put(d, &cur, &.{ 0xC2, 0x10 }); // X wide again for the epilogue's pulls
        put(d, &cur, &.{ 0xAB, 0x2B }); // PLB, PLD — the caller's context back
        put(d, &cur, &.{ 0x4C, @truncate(spec.tail_epilogue), @truncate(spec.tail_epilogue >> 8) });
        // The nested-native branch: unpin, run the tail on THIS CPU (the
        // displaced boundary JSL above already made this frame's poll).
        std.mem.writeInt(u16, d[tok_nest_at + 1 ..][0..2], @intCast(cur - (tok_nest_at + 3)), .little);
        if (spec.mode_gate) std.mem.writeInt(u16, d[tok_mode_at + 1 ..][0..2], @intCast(cur - (tok_mode_at + 3)), .little);
        // The game's P first — the SA-1 path enters the tail with the P
        // captured at engage, and so must this CPU: the tok's own widths
        // (M8 for the token INC, X as the pins left it) leaked into the
        // chain, and $9231's 16-bit fill count in Y truncated to 8 bits
        // (measured: the option screen cleared 256 of each map's 1024
        // words and the menu logo stayed behind the text).
        put(d, &cur, &.{ 0xAD, @truncate(split_cell_p), 0x37, 0x48, 0x28 }); // LDA cell_p / PHA / PLP
        put(d, &cur, &.{ 0xAB, 0x2B }); // PLB, PLD — the head's context
        put(d, &cur, &.{ 0x4C, @truncate(spec.tail + 4), @truncate((spec.tail + 4) >> 8) });
        // The SA-1 island: unwind the pins (the head's own D/B come
        // back) and run the tail. The displaced JSL $892B is SKIPPED on
        // this CPU — the SA-1 cannot poll pads, and the S-CPU's poll
        // this frame already filled the window cells the routine feeds.
        std.mem.writeInt(u16, d[tok_sa1_at + 1 ..][0..2], @intCast(cur - (tok_sa1_at + 3)), .little);
        put(d, &cur, &.{ 0xE2, 0x20 }); // M=8, as stock's boundary had it
        put(d, &cur, &.{ 0xAB, 0x2B }); // PLB, PLD
        put(d, &cur, &.{ 0x5C, @truncate(spec.tail + 4), @truncate((spec.tail + 4) >> 8), 0x00 }); // JML the tail proper

        // --- SA-1 prologue: gates, own I-RAM stack ---------------------
        const prologue16: u16 = base16 + @as(u16, @intCast(cur));
        d[crv_ref + 1] = @truncate(prologue16);
        d[crv_ref + 6] = @truncate(prologue16 >> 8);
        put(d, &cur, &.{ 0x78, 0x18, 0xFB }); // SEI / native
        put(d, &cur, &.{ 0xA9, 0xFF, 0x8D, 0x2A, 0x22 }); // CIWP
        put(d, &cur, &.{ 0xA9, 0x80, 0x8D, 0x27, 0x22 }); // CBWE
        put(d, &cur, &.{ 0x9C, 0x25, 0x22 }); // CBM block 0
        put(d, &cur, &.{ 0x9C, 0x50, 0x22 }); // ACM: multiply, for the helper
        put(d, &cur, &.{ 0xC2, 0x30 }); // REP #$30
        put(d, &cur, &.{ 0xA9, @truncate(split_sa1_stack), @truncate(split_sa1_stack >> 8), 0x1B });

        // --- the SA-1 frame loop --------------------------------------
        const sloop16: u16 = base16 + @as(u16, @intCast(cur));
        put(d, &cur, &.{ 0xE2, 0x20 }); // SEP #$20
        // publish: the RTI lands here, so `last` is a COMPLETED tail now
        put(d, &cur, &.{ 0xAF, @truncate(split_last), 0x37, 0x00 });
        put(d, &cur, &.{ 0x8F, @truncate(split_done), 0x37, 0x00 });
        put(d, &cur, &.{ 0xAF, @truncate(split_token), 0x37, 0x00 }); // wait:
        put(d, &cur, &.{ 0xCF, @truncate(split_last), 0x37, 0x00 });
        put(d, &cur, &.{ 0xF0, 0xF6 }); // BEQ the wait (-10)
        put(d, &cur, &.{ 0x8F, @truncate(split_last), 0x37, 0x00 });
        // Fake the handler frame the epilogue unwinds: the RTI comes
        // back HERE. RTI pulls P, PC, PBR — push PBR, PCH, PCL, P.
        put(d, &cur, &.{ 0xA9, 0x00, 0x48 }); // PBR
        put(d, &cur, &.{ 0xA9, @truncate(sloop16 >> 8), 0x48, 0xA9, @truncate(sloop16), 0x48 }); // PC
        put(d, &cur, &.{ 0xA9, 0x34, 0x48 }); // P: M8/X8/I
        // the pulls' dummies: A, X, Y (16-bit each), then D — which is
        // NOT the stock handler's zero: the window relocation's dp
        // scheme exists because the CONVERTED handler establishes
        // D=$6000, and a zero here sends every tail dp access into the
        // SA-1's I-RAM instead of the window (measured: the first boot
        // probe wrote $00:005C where the game meant window $605C).
        put(d, &cur, &.{ 0xC2, 0x30, 0xA9, 0x00, 0x00, 0x48, 0x48, 0x48 });
        put(d, &cur, &.{ 0xA9, @truncate(wg_bw_window), @truncate(wg_bw_window >> 8), 0x48 }); // the PLD's word
        put(d, &cur, &.{ 0xE2, 0x20, 0xA9, spec.tail_dbr, 0x48 }); // the PLB's byte
        // live context, as the CONVERTED handler set it: DBR and D
        put(d, &cur, &.{ 0xA9, spec.tail_dbr, 0x48, 0xAB }); // DBR
        put(d, &cur, &.{ 0xC2, 0x20, 0xA9, @truncate(wg_bw_window), @truncate(wg_bw_window >> 8), 0x5B, 0xE2, 0x20 }); // D = the window
        // into the tail — the displaced JSL $892B is the S-CPU's now
        // (it polls the real pads in the tok; the results are already
        // in the window when the token arrives here)
        put(d, &cur, &.{ 0x5C, @truncate(spec.tail + 4), @truncate((spec.tail + 4) >> 8), 0x00 });

        // --- mini-tok: unconditional per-frame service ----------------
        // The load-skip path never reaches the boundary, yet the SA-1's
        // loader waits on replays only the drain provides. All paths
        // converge on the epilogue, so its head is displaced onto this:
        // pins, mirror feed, drain, the displaced bytes, onward.
        const epi_span = splitPrefixSpan(out, usage, spec.tail_epilogue, 3);
        if (epi_span == 0)
            return refuse(refusal, .{ .reason = .wg_split_shape, .detail = spec.tail_epilogue });
        const mini16: u16 = base16 + @as(u16, @intCast(cur));

        // Both CPUs arrive here: every S-CPU handler exit, and the SA-1's
        // faked-frame return through the same epilogue. Only the S-CPU
        // feeds mirrors and drains; the SA-1 skips straight to the
        // displaced bytes (a pair of REPs -- harmless to repeat).
        put(d, &cur, &.{ 0xC2, 0x20, 0x3B, 0x29, 0x00, 0xF0, 0xC9, 0x00, 0x30 }); // TSC & $F000 == $3000?
        // BNE-over-BRL: the ring-2 drain pushed the target past a short
        // branch's +127 reach, and the u8 cast wrapped it into a silent
        // BACKWARD branch (measured: the SA-1 flew into BW-RAM-as-code).
        put(d, &cur, &.{ 0xD0, 0x03 }); // BNE past the BRL — the S-CPU path
        const msa1_at = cur;
        put(d, &cur, &.{ 0x82, 0x00, 0x00 }); // BRL the displaced epilogue (patched)
        put(d, &cur, &.{ 0x0B, 0xC2, 0x20, 0xA9, @truncate(wg_bw_window), @truncate(wg_bw_window >> 8), 0x5B }); // PHD; D = the window
        put(d, &cur, &.{ 0x8B, 0xE2, 0x20, 0xA9, 0x00, 0x48, 0xAB }); // PHB; DBR = $00
        // A nested NMI over an in-flight replay must not start another:
        // a sample stream replay spans frames, and per-frame nested
        // drains stacked streams 25 bytes deeper each frame until a
        // frame was corrupt (measured: $00:FFBC once per frame, S
        // 1b45/1b2c/1b13/1afa). The outer drain loops take the backlog.
        const mdrain16: u16 = base16 + @as(u16, @intCast(cur));
        put(d, &cur, &.{ 0xE2, 0x30 });
        put(d, &cur, &.{ 0xAD, @truncate(split_ring_rd), 0x37, 0xCD, @truncate(split_ring_wr), 0x37 });
        const mbeq_at = cur;
        put(d, &cur, &.{ 0xF0, 0x00 }); // BEQ out (patched)
        put(d, &cur, &.{ 0xAA, 0xBD, @truncate(split_ring), 0x37, 0x48 });
        put(d, &cur, &.{ 0xE8, 0x8A, 0x29, 0x0F, 0x8D, @truncate(split_ring_rd), 0x37 }); // rd consumes EARLY (see the tok drain)
        put(d, &cur, &.{ 0x68, 0x0A, 0xAA });
        put(d, &cur, &.{ 0xC2, 0x30, 0x3B, 0xA8, 0x29, 0x00, 0xFF, 0xC9, 0x00, 0x1B, 0xF0, 0x04, 0xA9, 0xFF, 0x1B, 0x1B, 0x98, 0x48, 0xE2, 0x30 }); // scratch stack (see the tok drain)
        put(d, &cur, &.{ 0xC2, 0x20, 0xAD, @truncate(split_cell_d), 0x37, 0x5B, 0xE2, 0x20 }); // caller D (see the far stub's capture)
        put(d, &cur, &.{ 0xC2, 0x30 }); // registers + dispatch: see the tok drain
        const mjsr_at = cur;
        put(d, &cur, &.{ 0xBD, 0x00, 0x00 }); // LDA tbl,X — patched by emitSplitIo
        put(d, &cur, &.{ 0x8D, @truncate(split_cell_t), 0x37 });
        put(d, &cur, &.{ 0xAE, @truncate(split_cell_x), 0x37, 0xAC, @truncate(split_cell_y), 0x37 });
        put(d, &cur, &.{ 0xE2, 0x20 });
        put(d, &cur, &.{ 0xAD, @truncate(split_cell_pw), 0x37, 0x29, 0x30, 0x48 });
        put(d, &cur, &.{ 0xC2, 0x20, 0xAD, @truncate(split_cell_a), 0x37, 0x28 });
        const mret1: u16 = base16 + @as(u16, @intCast(cur)) + 6;
        put(d, &cur, &.{ 0xF4, @truncate(mret1 - 1), @truncate((mret1 - 1) >> 8) }); // PEA return-1
        put(d, &cur, &.{ 0x6C, @truncate(split_cell_t), 0x37 }); // JMP (cell_t)
        put(d, &cur, &.{ 0xE2, 0x30 });
        put(d, &cur, &.{ 0xA9, 0x00, 0x48, 0xAB }); // pump DBR back
        put(d, &cur, &.{ 0xC2, 0x20, 0xA9, @truncate(wg_bw_window), @truncate(wg_bw_window >> 8), 0x5B, 0xE2, 0x20 }); // pump D back
        put(d, &cur, &.{ 0xC2, 0x20, 0x68, 0x1B, 0xE2, 0x20 }); // old S back
        put(d, &cur, &.{ 0xEE, @truncate(split_rpc_ack), 0x37 }); // the RPC release
        put(d, &cur, &.{ 0x4C, @truncate(mdrain16), @truncate(mdrain16 >> 8) });
        d[mbeq_at + 1] = @intCast(cur - (mbeq_at + 2));
        // Ring 2 — the fire-and-forget sound calls — drains HERE and
        // only here: the frame exit is stock's own phase for the
        // trailing sound dispatch, and pacing it anywhere earlier
        // skewed the APU echo family for hundreds of ticks.
        // Emitted as a SUBROUTINE: the mini-tok calls it at every frame
        // exit, and the GATE calls it under backpressure — a multi-frame
        // gated transition has no frame exits, and 24 slots overwrote
        // (measured: dropped sound dispatches overfilled the command
        // queue and its cursor walked into the dp floor at $46).
        const r2skip_at = cur;
        put(d, &cur, &.{ 0x80, 0x00 }); // BRA past the sub (patched)
        const r2_16: u16 = base16 + @as(u16, @intCast(cur));
        put(d, &cur, &.{ 0xE2, 0x30 });
        // Nesting guard, RING 2 ONLY: a sound stream spans frames and a
        // nested NMI starting another stacked them 25 bytes/frame. Ring
        // 1 (uploads) must still drain from a nested frame — each is
        // short and the scratch frame is stack-safe — or the uploads
        // land a frame late (measured: 1,476 divergent ticks from the
        // one 2-frame stream at frame 1126 when both rings were gated).
        put(d, &cur, &.{ 0xAD, @truncate(split_in_replay), 0x37 });
        const r2nest_at = cur;
        put(d, &cur, &.{ 0xD0, 0x00 }); // BNE out (patched)
        put(d, &cur, &.{ 0xAD, @truncate(split_ring2_rd), 0x37, 0xCD, @truncate(split_ring2_wr), 0x37 });
        const r2beq_at = cur;
        put(d, &cur, &.{ 0xF0, 0x00 }); // BEQ out (patched)
        put(d, &cur, &.{ 0x0A, 0x0A, 0xAA }); // slot*4 -> X
        put(d, &cur, &.{ 0xBD, @truncate(split_ring2), @truncate(split_ring2 >> 8), 0x48 }); // id pushed
        put(d, &cur, &.{ 0xC2, 0x20, 0xBD, @truncate(split_ring2 + 1), @truncate((split_ring2 + 1) >> 8), 0x5B, 0xE2, 0x20 }); // D := record.D
        put(d, &cur, &.{ 0xBD, @truncate(split_ring2 + 3), @truncate((split_ring2 + 3) >> 8), 0x8D, @truncate(split_cell_pw), 0x37 }); // record.P parked in the cell
        put(d, &cur, &.{ 0xAD, @truncate(split_ring2_rd), 0x37, 0x1A, 0xC9, 0x18, 0xD0, 0x02, 0xA9, 0x00 });
        put(d, &cur, &.{ 0x8D, @truncate(split_ring2_rd), 0x37 }); // rd2 bumped EARLY (nested-safe)
        put(d, &cur, &.{ 0x68, 0x0A, 0xAA }); // id*2 -> X
        put(d, &cur, &.{ 0xC2, 0x30, 0x3B, 0xA8, 0x29, 0x00, 0xFF, 0xC9, 0x00, 0x1B, 0xF0, 0x04, 0xA9, 0xFF, 0x1B, 0x1B, 0x98, 0x48, 0xE2, 0x30 }); // scratch stack
        put(d, &cur, &.{ 0xEE, @truncate(split_in_replay), 0x37 }); // in flight
        put(d, &cur, &.{ 0xAD, @truncate(split_cell_pw), 0x37, 0x29, 0x30, 0x48, 0x28 }); // caller P
        const r2jsr_at = cur;
        put(d, &cur, &.{ 0xFC, 0x00, 0x00 }); // JSR (tbl,X) — patched below
        put(d, &cur, &.{ 0xE2, 0x30 });
        put(d, &cur, &.{ 0xCE, @truncate(split_in_replay), 0x37 }); // landed
        put(d, &cur, &.{ 0xA9, 0x00, 0x48, 0xAB });
        put(d, &cur, &.{ 0xC2, 0x20, 0x68, 0x1B, 0xE2, 0x20 }); // old S back
        put(d, &cur, &.{ 0x4C, @truncate(r2_16), @truncate(r2_16 >> 8) });
        d[r2beq_at + 1] = @intCast(cur - (r2beq_at + 2));
        d[r2nest_at + 1] = @intCast(cur - (r2nest_at + 2));
        put(d, &cur, &.{ 0xC2, 0x20, 0xA9, @truncate(wg_bw_window), @truncate(wg_bw_window >> 8), 0x5B, 0xE2, 0x20 }); // pump D back
        put(d, &cur, &.{0x60}); // RTS — the drain sub's exit
        d[r2skip_at + 1] = @intCast(cur - (r2skip_at + 2));
        put(d, &cur, &.{ 0x20, @truncate(r2_16), @truncate(r2_16 >> 8) }); // the mini-tok's own call
        std.mem.writeInt(u16, d[r2bp_at + 3 ..][0..2], r2_16, .little); // the gate's backpressure call
        put(d, &cur, &.{ 0xC2, 0x10, 0xAB, 0x2B }); // X wide, PLB, PLD
        std.mem.writeInt(u16, d[msa1_at + 1 ..][0..2], @intCast(cur - (msa1_at + 3)), .little);
        @memcpy(d[cur .. cur + epi_span], out[spec.tail_epilogue - 0x8000 ..][0..epi_span]);
        cur += epi_span;
        put(d, &cur, &.{ 0x4C, @truncate(spec.tail_epilogue + @as(u16, @intCast(epi_span))), @truncate((spec.tail_epilogue + @as(u16, @intCast(epi_span))) >> 8) });

        // --- displace the boundary on the S-CPU side ------------------
        out[spec.tail - 0x8000] = 0x4C; // JMP tok (the JSL's 4th byte is unreachable)
        std.mem.writeInt(u16, out[spec.tail - 0x8000 + 1 ..][0..2], tok16, .little);
        // ... and the epilogue onto the mini-tok.
        out[spec.tail_epilogue - 0x8000] = 0x4C;
        std.mem.writeInt(u16, out[spec.tail_epilogue - 0x8000 + 1 ..][0..2], mini16, .little);
        if (epi_span > 3) @memset(out[spec.tail_epilogue - 0x8000 + 3 ..][0 .. epi_span - 3], 0xEA);
        res.stats.split_engage_addr = tok16;

        // --- the DMA-queue bank-slot translator -----------------------
        // The game's upload records carry their source bank as DATA — ROM
        // templates copied whole into the queue (the stage-2 boss's
        // sprite strips live at $01:90CB/D6/E3 with src bank $7F). No
        // static rewrite reaches a template only late-game code copies,
        // and no S-CPU harvest ever executes the SA-1-side builder — so
        // the CONSUMER translates: $8E00's one bank-slot store becomes a
        // thunk mapping $7E->$40, $7F->$41 at run time, correct for
        // every template the game will ever build a record from. The
        // site is M8 (the walker SEPs first), stores leave flags dead
        // (the next op is an immediate load), and the caller's DBR=$01
        // reaches the same $4304 mirror the store always hit.
        {
            const pat = [_]u8{ 0xBF, 0x08, 0x00, 0x40, 0x8D, 0x04, 0x43 };
            var site: ?usize = null;
            var sp: usize = 0;
            while (sp + pat.len <= 0x8000) : (sp += 1) {
                if (std.mem.eql(u8, out[sp .. sp + pat.len], &pat)) {
                    site = sp + 4;
                    break;
                }
            }
            if (site) |st| {
                const th16: u16 = base16 + @as(u16, @intCast(cur));
                put(d, &cur, &.{ 0xC9, 0x7E }); // CMP #$7E
                put(d, &cur, &.{ 0x90, 0x08 }); // BCC store
                put(d, &cur, &.{ 0xC9, 0x80 }); // CMP #$80
                put(d, &cur, &.{ 0xB0, 0x04 }); // BCS store
                put(d, &cur, &.{ 0x38, 0xE9, 0x3E }); // SEC / SBC #$3E
                put(d, &cur, &.{0xEA}); // pad: both branches land on the store
                put(d, &cur, &.{ 0x8D, 0x04, 0x43, 0x60 }); // STA $4304 / RTS
                out[st] = 0x20; // JSR thunk over the 3-byte STA
                std.mem.writeInt(u16, out[st + 1 ..][0..2], th16, .little);
            }
        }

        try emitSplitIo(out, usage, spec, d, &cur, base16, jsr2_at, far, refusal, res);
        std.mem.writeInt(u16, d[mjsr_at + 1 ..][0..2], std.mem.readInt(u16, d[jsr2_at + 1 ..][0..2], .little), .little);
        std.mem.writeInt(u16, d[r2jsr_at + 1 ..][0..2], std.mem.readInt(u16, d[jsr2_at + 1 ..][0..2], .little), .little);
        // A real refusal, not an assert: ReleaseFast strips asserts, and
        // an overflowing emission wrote through the shim and vectors.
        if (cur > wg_window_shim_max + split_disp_max)
            return refuse(refusal, .{ .reason = .wg_split_shape, .detail = @intCast(cur) });
        return;
    }

    // === MAINLOOP FLAVOR ==============================================
    // Ownership of the loop changes hands at the anchor, once per lap at
    // most: the SA-1 runs the laps while the mode cell says gameplay,
    // the S-CPU runs them natively otherwise (loads, transitions, menus —
    // the eras whose producer/consumer handshakes assume one CPU). While
    // the SA-1 owns the loop the S-CPU sits in the pump: mirrors, ring,
    // and the owner cell. Context (A/X/Y/P/D/DBR, and S on the S-CPU
    // side) crosses through I-RAM cells; each CPU keeps its own stack.
    const ml24 = spec.mainloop;
    const mlspan = splitPrefixSpan(out, usage, ml24, 4);
    const mode_home: u16 = if (spec.mode_cell < 0x2000) spec.mode_cell + 0x6000 else spec.mode_cell;

    // --- pump loop (S-CPU): mirrors, ring, owner --------------------
    const pump16: u16 = base16 + @as(u16, @intCast(cur));
    put(d, &cur, &.{ 0xE2, 0x30 }); // SEP #$30
    put(d, &cur, &.{ 0xAD, 0x12, 0x42, 0x8D, @truncate(split_vbl_mirror), @truncate(split_vbl_mirror >> 8) });
    // The PAD mirrors are NOT fed here: a read of $4218-$421F is a poll,
    // and the verifier pairs the two runs poll-for-poll — a pump reading
    // the pads thousands of times a frame generated ticks on frames stock
    // never polled (measured: a 4-frame tick skew and a fork from it).
    // The game's own poll feeds them: the reader helper the NMI handler's
    // pad read wears stores what it read (see emitSplitReaders).
    // The check-and-consume is a critical section: the NMI hook drains too,
    // and one interrupting between the pump's check and its consume would
    // take the entry and leave the pump replaying a stale slot. The
    // in-replay cell marks the section; the hook stands down while set.
    put(d, &cur, &.{ 0xEE, @truncate(split_in_replay), 0x37 }); // in_replay := 1
    const drain_call_at = cur;
    put(d, &cur, &.{ 0x20, 0x00, 0x00 }); // JSR drain_one (patched; returns at once when empty)
    put(d, &cur, &.{ 0x9C, @truncate(split_in_replay), 0x37 }); // in_replay := 0
    // Does the loop still belong to the SA-1?
    put(d, &cur, &.{ 0xAD, @truncate(split_owner), @truncate(split_owner >> 8) });
    const beq_take_at = cur;
    put(d, &cur, &.{ 0xF0, 0x00 }); // BEQ takeover (patched)
    put(d, &cur, &.{ 0x4C, @truncate(pump16), @truncate(pump16 >> 8) });
    // drain_one (SEP #$30, DBR $00 on entry; RTS): one ring entry — the
    // caller's D/DBR/registers/widths come back from the stub's capture
    // (RPC serializes, so one cell set holds), the dispatch goes through a
    // 24-bit pointer with an RTL-shaped frame pushed by hand, and the
    // release is the ack bump after. Called by the pump, and by the NMI
    // hook: a deferred call made just before the S-CPU's NMI would else
    // wait the whole handler out, milliseconds per call.
    const drain16: u16 = base16 + @as(u16, @intCast(cur));
    std.mem.writeInt(u16, d[drain_call_at + 1 ..][0..2], drain16, .little);
    put(d, &cur, &.{ 0xAD, @truncate(split_ring_rd), 0x37, 0xCD, @truncate(split_ring_wr), 0x37 });
    const drain_empty_at = cur;
    put(d, &cur, &.{ 0xF0, 0x00 }); // BEQ the RTS (patched): nothing pending
    put(d, &cur, &.{ 0xAA, 0xBD, @truncate(split_ring), 0x37, 0x48 }); // TAX / LDA ring,X / PHA
    put(d, &cur, &.{ 0xE8, 0x8A, 0x29, 0x0F, 0x8D, @truncate(split_ring_rd), 0x37 }); // rd consumes early
    put(d, &cur, &.{ 0x68, 0x0A, 0x0A, 0xAA }); // PLA / ASL / ASL / TAX -- id*4
    put(d, &cur, &.{ 0xC2, 0x20 });
    const tbl_lo_at = cur;
    put(d, &cur, &.{ 0xBD, 0x00, 0x00 }); // LDA tbl,X (patched)
    put(d, &cur, &.{ 0x8D, @truncate(split_cell_t), 0x37 });
    put(d, &cur, &.{ 0xE2, 0x20 });
    const tbl_bank_at = cur;
    put(d, &cur, &.{ 0xBD, 0x00, 0x00 }); // LDA tbl+2,X (patched)
    put(d, &cur, &.{ 0x8D, @truncate(split_cell_tb), 0x37 });
    put(d, &cur, &.{ 0xC2, 0x20, 0xAD, @truncate(split_cell_d), 0x37, 0x5B }); // caller D
    put(d, &cur, &.{ 0xE2, 0x20, 0xAD, @truncate(split_cell_dbr), 0x37, 0x48, 0xAB }); // caller DBR
    put(d, &cur, &.{ 0xC2, 0x30, 0xAE, @truncate(split_cell_x), 0x37, 0xAC, @truncate(split_cell_y), 0x37 });
    put(d, &cur, &.{ 0xE2, 0x20, 0xAD, @truncate(split_cell_pw), 0x37, 0x29, 0x30, 0x48 }); // widths only
    put(d, &cur, &.{ 0xC2, 0x20, 0xAD, @truncate(split_cell_a), 0x37, 0x28 }); // A, then PLP
    const ret1: u16 = base16 + @as(u16, @intCast(cur)) + 7;
    put(d, &cur, &.{ 0x4B, 0xF4, @truncate(ret1 - 1), @truncate((ret1 - 1) >> 8) }); // PHK / PEA return-1
    put(d, &cur, &.{ 0xDC, @truncate(split_cell_t), 0x37 }); // JML [cell_t]
    std.debug.assert(base16 + @as(u16, @intCast(cur)) == ret1);
    put(d, &cur, &.{ 0xE2, 0x30, 0x4B, 0xAB }); // widths, DBR back
    put(d, &cur, &.{ 0xEE, @truncate(split_rpc_ack), 0x37 }); // the RPC release
    d[drain_empty_at + 1] = @intCast(cur - (drain_empty_at + 2));
    put(d, &cur, &.{0x60}); // RTS
    // --- the NMI hook: drain a pending entry before the game's handler ---
    // Everything the interrupted code had is put back before the JML, so
    // the handler's own RTI pops the original frame. Widths are unknown at
    // entry: PHP first, then REP #$30, so every push and pull is 16-bit.
    const nmi_vec = std.mem.readInt(u16, out[0x7FEA..0x7FEC], .little);
    const hook16: u16 = base16 + @as(u16, @intCast(cur));
    put(d, &cur, &.{ 0x08, 0xC2, 0x30, 0x48, 0xDA, 0x5A, 0x0B, 0x8B, 0x4B, 0xAB, 0xE2, 0x30 }); // PHP / REP / PHA PHX PHY PHD PHB / PHK PLB / SEP #$30
    put(d, &cur, &.{ 0xAD, @truncate(split_in_replay), 0x37 }); // the pump mid-drain? stand down
    put(d, &cur, &.{ 0xD0, 0x03 }); // BNE over the call
    put(d, &cur, &.{ 0x20, @truncate(drain16), @truncate(drain16 >> 8) });
    put(d, &cur, &.{ 0xC2, 0x30, 0xAB, 0x2B, 0x7A, 0xFA, 0x68, 0x28 }); // REP / PLB PLD PLY PLX PLA / PLP
    put(d, &cur, &.{ 0x5C, @truncate(nmi_vec), @truncate(nmi_vec >> 8), 0x00 }); // JML the game's handler
    std.mem.writeInt(u16, out[0x7FEA..0x7FEC], hook16, .little);
    // takeover (S-CPU): the SA-1 handed the loop back — its context is
    // in the cells; the game stack is where the S-CPU left it.
    d[beq_take_at + 1] = @intCast(cur - (beq_take_at + 2));
    if (dual) {
        // The S-CPU's copy back: megabytes 0/1/0/2 (SEP #$30 is live).
        put(d, &cur, &.{ 0xA9, 0x80, 0x8D, 0x20, 0x22, 0xA9, 0x81, 0x8D, 0x21, 0x22 });
        put(d, &cur, &.{ 0xA9, 0x80, 0x8D, 0x22, 0x22, 0xA9, 0x82, 0x8D, 0x23, 0x22 });
    }
    put(d, &cur, &.{ 0xC2, 0x30, 0xAD, @truncate(split_cell_s), 0x37, 0x1B }); // S
    put(d, &cur, &.{ 0xAD, @truncate(split_cell_d), 0x37, 0x5B }); // D
    put(d, &cur, &.{ 0xE2, 0x20, 0xAD, @truncate(split_cell_dbr), 0x37, 0x48, 0xAB }); // DBR
    put(d, &cur, &.{ 0xAD, @truncate(split_cell_p), 0x37, 0x48 }); // P, pushed for the PLP
    put(d, &cur, &.{ 0xC2, 0x30, 0xAE, @truncate(split_ctx_x), @truncate(split_ctx_x >> 8), 0xAC, @truncate(split_ctx_y), @truncate(split_ctx_y >> 8) });
    put(d, &cur, &.{ 0xAD, @truncate(split_ctx_a), @truncate(split_ctx_a >> 8), 0x28 }); // A / PLP
    const take_jml_at = cur;
    put(d, &cur, &.{ 0x5C, 0x00, 0x00, 0x00 }); // JML tramp (patched)

    // --- engage (both CPUs, every lap, via the anchor's JML) ----------
    const engage16: u16 = base16 + @as(u16, @intCast(cur));
    put(d, &cur, &.{ 0x08, 0xC2, 0x20, 0x48 }); // PHP / REP #$20 / PHA
    put(d, &cur, &.{ 0x3B, 0x29, 0x00, 0xF0, 0xC9, 0x00, 0x30 }); // TSC & $F000 == $3000?
    put(d, &cur, &.{ 0xD0, 0x03 }); // BNE the S-CPU path
    const eng_sa1_at = cur;
    put(d, &cur, &.{ 0x82, 0x00, 0x00 }); // BRL the SA-1 arrival (patched)
    // S-CPU: the gate (I-RAM was opened by the shim at reset).
    put(d, &cur, &.{ 0xE2, 0x20 });
    var eng_native_at: usize = 0;
    if (spec.mode_gate) {
        put(d, &cur, &.{ 0xC2, 0x20, 0xAF, @truncate(mode_home), @truncate(mode_home >> 8), 0x00 }); // LDA $00:home (16-bit)
        put(d, &cur, &.{ 0x29, 0xFF, 0x00, 0xC9, spec.mode_value, 0x00 }); // AND #$00FF / CMP #value
        put(d, &cur, &.{ 0xF0, 0x03 }); // BEQ hand over
        eng_native_at = cur;
        put(d, &cur, &.{ 0x82, 0x00, 0x00 }); // BRL native (patched)
    }
    // hand over: publish the context, first-engage the SA-1 once, own := SA-1
    put(d, &cur, &.{ 0xC2, 0x30, 0x68, 0x8F, @truncate(split_ctx_a), @truncate(split_ctx_a >> 8), 0x00 }); // A
    put(d, &cur, &.{ 0x8A, 0x8F, @truncate(split_ctx_x), @truncate(split_ctx_x >> 8), 0x00 }); // X
    put(d, &cur, &.{ 0x98, 0x8F, @truncate(split_ctx_y), @truncate(split_ctx_y >> 8), 0x00 }); // Y
    put(d, &cur, &.{ 0x0B, 0x68, 0x8F, @truncate(split_cell_d), 0x37, 0x00 }); // D
    put(d, &cur, &.{ 0xE2, 0x20, 0x8B, 0x68, 0x8F, @truncate(split_cell_dbr), 0x37, 0x00 }); // DBR
    put(d, &cur, &.{ 0x68, 0x8F, @truncate(split_cell_p), 0x37, 0x00 }); // P (pushed at entry)
    put(d, &cur, &.{ 0xC2, 0x20, 0x3B, 0x8F, @truncate(split_cell_s), 0x37, 0x00, 0xE2, 0x20 }); // S
    put(d, &cur, &.{ 0xAF, @truncate(split_engaged), 0x37, 0x00 });
    const eng_released_at = cur;
    put(d, &cur, &.{ 0xD0, 0x00 }); // BNE released (patched)
    put(d, &cur, &.{ 0x9C, @truncate(split_ring_wr), 0x37, 0x9C, @truncate(split_ring_rd), 0x37 }); // ring reset (DBR is the game's: I-RAM aliases in every bank < $40 / $80-$BF)
    put(d, &cur, &.{ 0x9C, @truncate(split_in_replay), 0x37 }); // no drain in flight
    put(d, &cur, &.{ 0xA9, 0x00, 0x8F, @truncate(split_owner), @truncate(split_owner >> 8), 0x00 }); // owner := S-CPU until the SA-1 waits
    const eng_crv_at = cur;
    put(d, &cur, &.{ 0xA9, 0x00, 0x8F, 0x03, 0x22, 0x00, 0xA9, 0x00, 0x8F, 0x04, 0x22, 0x00 }); // CRV (patched)
    put(d, &cur, &.{ 0xA9, 0x01, 0x8F, @truncate(split_engaged), 0x37, 0x00 }); // engaged := 1
    put(d, &cur, &.{ 0xA9, 0x00, 0x8F, 0x00, 0x22, 0x00 }); // release the SA-1
    d[eng_released_at + 1] = @intCast(cur - (eng_released_at + 2));
    if (dual) {
        // The SA-1's copy: regions C/D/E/F onto megabytes 4/5/4/6 (the
        // shim's own E/F choice, one copy up). Both CPUs sit in bank $00
        // code identical in both copies while this takes effect.
        put(d, &cur, &.{ 0xA9, 0x84, 0x8F, 0x20, 0x22, 0x00, 0xA9, 0x85, 0x8F, 0x21, 0x22, 0x00 });
        put(d, &cur, &.{ 0xA9, 0x84, 0x8F, 0x22, 0x22, 0x00, 0xA9, 0x86, 0x8F, 0x23, 0x22, 0x00 });
    }
    put(d, &cur, &.{ 0xA9, 0x01, 0x8F, @truncate(split_owner), @truncate(split_owner >> 8), 0x00 }); // owner := SA-1
    put(d, &cur, &.{ 0xC2, 0x20, 0xA9, @truncate(split_ml_pump_stack), @truncate(split_ml_pump_stack >> 8), 0x1B }); // the pump stack
    put(d, &cur, &.{ 0x4B, 0xAB, 0xE2, 0x30, 0x4C, @truncate(pump16), @truncate(pump16 >> 8) }); // DBR := $00, into the pump
    // native (S-CPU, mode gate says not gameplay): this CPU runs the lap.
    if (spec.mode_gate) std.mem.writeInt(u16, d[eng_native_at + 1 ..][0..2], @intCast(cur - (eng_native_at + 3)), .little);
    put(d, &cur, &.{ 0xC2, 0x20, 0x68, 0x28 }); // PLA / PLP
    const nat_jml_at = cur;
    put(d, &cur, &.{ 0x5C, 0x00, 0x00, 0x00 }); // JML tramp (patched)
    // the SA-1's arrival: gameplay -> the lap; else hand back and wait.
    std.mem.writeInt(u16, d[eng_sa1_at + 1 ..][0..2], @intCast(cur - (eng_sa1_at + 3)), .little);
    var sa1_back_at: usize = 0;
    if (spec.mode_gate) {
        put(d, &cur, &.{ 0xAF, @truncate(mode_home), @truncate(mode_home >> 8), 0x00 }); // 16-bit (REP #$20 is live)
        put(d, &cur, &.{ 0x29, 0xFF, 0x00, 0xC9, spec.mode_value, 0x00 });
        sa1_back_at = cur;
        put(d, &cur, &.{ 0xD0, 0x00 }); // BNE hand back (patched)
    }
    put(d, &cur, &.{ 0x68, 0x28 }); // PLA / PLP
    const sa1_lap_jml_at = cur;
    put(d, &cur, &.{ 0x5C, 0x00, 0x00, 0x00 }); // JML tramp (patched)
    var sa1_wait_jmp_at: usize = 0;
    if (spec.mode_gate) {
        d[sa1_back_at + 1] = @intCast(cur - (sa1_back_at + 2));
        put(d, &cur, &.{ 0xC2, 0x30, 0x68, 0x8F, @truncate(split_ctx_a), @truncate(split_ctx_a >> 8), 0x00 });
        put(d, &cur, &.{ 0x8A, 0x8F, @truncate(split_ctx_x), @truncate(split_ctx_x >> 8), 0x00 });
        put(d, &cur, &.{ 0x98, 0x8F, @truncate(split_ctx_y), @truncate(split_ctx_y >> 8), 0x00 });
        put(d, &cur, &.{ 0x0B, 0x68, 0x8F, @truncate(split_cell_d), 0x37, 0x00 });
        put(d, &cur, &.{ 0xE2, 0x20, 0x8B, 0x68, 0x8F, @truncate(split_cell_dbr), 0x37, 0x00 });
        put(d, &cur, &.{ 0x68, 0x8F, @truncate(split_cell_p), 0x37, 0x00 });
        put(d, &cur, &.{ 0xA9, 0x00, 0x8F, @truncate(split_owner), @truncate(split_owner >> 8), 0x00 }); // owner := S-CPU, last
        sa1_wait_jmp_at = cur;
        put(d, &cur, &.{ 0x4C, 0x00, 0x00 }); // JMP the SA-1 wait (patched)
    }

    // --- SA-1 prologue: gates, own I-RAM stack, then wait for the loop --
    const prologue16: u16 = base16 + @as(u16, @intCast(cur));
    d[eng_crv_at + 1] = @truncate(prologue16);
    d[eng_crv_at + 7] = @truncate(prologue16 >> 8);
    put(d, &cur, &.{ 0x78, 0x18, 0xFB }); // SEI / native
    put(d, &cur, &.{ 0xA9, 0xFF, 0x8D, 0x2A, 0x22 }); // CIWP: I-RAM writable
    put(d, &cur, &.{ 0xA9, 0x80, 0x8D, 0x27, 0x22 }); // CBWE: BW-RAM writes
    put(d, &cur, &.{ 0x9C, 0x25, 0x22 }); // CBM block 0 -- the identity window
    put(d, &cur, &.{ 0x9C, 0x50, 0x22 }); // ACM: multiply mode, for the shadow
    put(d, &cur, &.{ 0xC2, 0x20, 0xA9, @truncate(split_ml_sa1_stack), @truncate(split_ml_sa1_stack >> 8), 0x1B });
    const sa1_wait16: u16 = base16 + @as(u16, @intCast(cur));
    if (spec.mode_gate) std.mem.writeInt(u16, d[sa1_wait_jmp_at + 1 ..][0..2], sa1_wait16, .little);
    put(d, &cur, &.{ 0xE2, 0x20, 0xAF, @truncate(split_owner), @truncate(split_owner >> 8), 0x00 }); // wait: owner == SA-1?
    put(d, &cur, &.{ 0xF0, 0xF8 }); // BEQ the wait (-8)
    put(d, &cur, &.{ 0xC2, 0x30, 0xAD, @truncate(split_cell_d), 0x37, 0x5B }); // D
    put(d, &cur, &.{ 0xE2, 0x20, 0xAD, @truncate(split_cell_dbr), 0x37, 0x48, 0xAB }); // DBR
    put(d, &cur, &.{ 0xAD, @truncate(split_cell_p), 0x37, 0x48 }); // P for the PLP
    put(d, &cur, &.{ 0xC2, 0x30, 0xAE, @truncate(split_ctx_x), @truncate(split_ctx_x >> 8), 0xAC, @truncate(split_ctx_y), @truncate(split_ctx_y >> 8) });
    put(d, &cur, &.{ 0xAD, @truncate(split_ctx_a), @truncate(split_ctx_a >> 8), 0x28 }); // A / PLP
    const tramp16: u16 = base16 + @as(u16, @intCast(cur)) + 4;
    put(d, &cur, &.{ 0x5C, @truncate(tramp16), @truncate(tramp16 >> 8), 0x00 });
    // --- mainloop trampoline: the displaced bytes, then onward ---------
    std.debug.assert(base16 + @as(u16, @intCast(cur)) == tramp16);
    for ([_]usize{ take_jml_at, nat_jml_at, sa1_lap_jml_at }) |at| std.mem.writeInt(u16, d[at + 1 ..][0..2], tramp16, .little);
    @memcpy(d[cur .. cur + mlspan], out[splitFile(ml24)..][0..mlspan]);
    cur += mlspan;
    const onward: u24 = @intCast(@as(u32, ml24) + mlspan);
    put(d, &cur, &.{ 0x5C, @truncate(onward), @truncate(onward >> 8), @truncate(onward >> 16) });

    try emitSplitIoBanked(out, usage, spec, d, &cur, base16, tbl_lo_at, tbl_bank_at, far, carve, carve_len, &displaced, &n_displaced, refusal, res);

    if (cur > wg_window_shim_max + split_disp_max)
        return refuse(refusal, .{ .reason = .wg_split_shape, .detail = @intCast(cur) });

    // --- displace the mainloop anchor, last -----------------------------
    const mf = splitFile(ml24);
    out[mf] = 0x5C; // JML engage
    std.mem.writeInt(u16, out[mf + 1 ..][0..2], engage16, .little);
    out[mf + 3] = 0x00;
    if (mlspan > 4) @memset(out[mf + 4 ..][0 .. mlspan - 4], 0xEA);
    res.stats.split_engage_addr = engage16;

    if (dual) {
        // The SA-1's copy, COP sites and all; then the S-CPU's copy gets
        // its stock bytes back at every math site.
        const half: usize = 4 * 1024 * 1024;
        @memcpy(out[half .. 2 * half], out[0..half]);
        for (math_sites[0..n_math_sites]) |ms| {
            const f = splitFile(ms.addr);
            out[f..][0..3].* = ms.bytes;
        }
        // ... and its IO entries and readers too: the S-CPU's own eras run
        // stock bytes everywhere but the anchor. (When the SA-1 owns the
        // loop the mapper shows the S-CPU the upper copy, whose stubs and
        // readers still serve its NMI handler and the pump's replays.)
        for (displaced[0..n_displaced]) |ds| {
            const f = splitFile(ds.addr);
            @memcpy(out[f..][0..ds.len], ds.bytes[0..ds.len]);
        }
        res.stats.split_dual = true;
    }
}

/// The mainloop flavor's IO machinery, bank-general: for each routine a
/// drain trampoline and an enqueue stub in the ROUTINE'S OWN bank (its
/// RTS-shaped return and bank-local jumps stay sound), and a 24-bit
/// dispatch table in the carve the pump jumps through. Disciplines:
/// plain (the SA-1 runs the body too — its MMIO writes vanish — and the
/// pump replays it, no wait), `deferred` (the SA-1 skips the body and
/// waits for the replay: a handshake, or shared state that must land in
/// order). `ff` has no frame-exit phase to ride here and is treated as
/// deferred.
fn emitSplitIoBanked(
    out: []u8,
    usage: []const u8,
    spec: SplitSpec,
    d: []u8,
    curp: *usize,
    base16: u16,
    tbl_lo_at: usize,
    tbl_bank_at: usize,
    far: *FarPad,
    carve: u32,
    carve_len: u32,
    disp: *[512]Displaced,
    n_disp: *u32,
    refusal: *?Refusal,
    res: *Result,
) Error!void {
    var cur = curp.*;
    var tramp24: [26]u24 = undefined;
    var stub16: [26]u16 = undefined;
    for (spec.io_entries, 0..) |io, i| {
        const span = splitPrefixSpan(out, usage, io.entry, 3);
        if (span == 0) return refuse(refusal, .{ .reason = .wg_split_shape, .detail = io.entry });
        const bank: u32 = (io.entry >> 16) & 0x7F;
        const e16: u16 = @truncate(io.entry);
        const bank_byte: u8 = @intCast(io.entry >> 16);
        const deferred = io.deferred or io.ff;

        // The trampoline: [JSR/JSL helper][RTL][helper: prefix; JMP body+span]
        var tb: [40]u8 = undefined;
        var tc: usize = 0;
        const t_need: u32 = if (io.rtl) 5 + span + 3 else 4 + span + 3;
        const tat = far.nextIn(bank, t_need, if (bank == 0) carve else 0, if (bank == 0) carve_len else 0) orelse
            return refuse(refusal, .{ .reason = .no_free_space, .detail = t_need });
        const t16: u16 = @intCast(0x8000 + (tat % 0x8000));
        if (io.rtl) {
            const helper = t16 + 5;
            put(&tb, &tc, &.{ 0x22, @truncate(helper), @truncate(helper >> 8), bank_byte, 0x6B });
        } else {
            const helper = t16 + 4;
            put(&tb, &tc, &.{ 0x20, @truncate(helper), @truncate(helper >> 8), 0x6B });
        }
        @memcpy(tb[tc .. tc + span], out[splitFile(io.entry)..][0..span]);
        tc += span;
        put(&tb, &tc, &.{ 0x4C, @truncate(e16 + @as(u16, @intCast(span))), @truncate((e16 + @as(u16, @intCast(span))) >> 8) });
        std.debug.assert(tc == t_need);
        @memcpy(out[tat .. tat + tc], tb[0..tc]);
        tramp24[i] = (@as(u24, bank_byte) << 16) | t16;

        // The enqueue stub, in the same bank. The CPU test comes FIRST and
        // the S-CPU's path is an early exit (~35 cycles: measured, the full
        // capture on every native-era call cost a razor-edge transition lap
        // its vblank, one lag frame, and a permanent fork); only the SA-1
        // captures and enqueues.
        var fb: [200]u8 = undefined;
        var fc: usize = 0;
        put(&fb, &fc, &.{ 0x08, 0xC2, 0x20, 0x48, 0x3B, 0x29, 0x00, 0xF0, 0xC9, 0x00, 0x30 }); // PHP / REP #$20 / PHA / TSC & $F000 == $3000?
        const scpu_at = fc;
        put(&fb, &fc, &.{ 0xD0, 0x00 }); // BNE the S-CPU exit (patched)
        put(&fb, &fc, &.{ 0x68, 0x28 }); // PLA / PLP — the caller's A and P back
        // A comes back from the STACK, not from the cell: a cell store made
        // with SIWP closed bounces, and reading it back handed every
        // boot-time IO body a garbage A.
        put(&fb, &fc, &.{ 0x08, 0xC2, 0x30, 0x48 }); // PHP / REP #$30 / PHA
        put(&fb, &fc, &.{ 0x8F, @truncate(split_cell_a), 0x37, 0x00 });
        put(&fb, &fc, &.{ 0x98, 0x8F, @truncate(split_cell_y), 0x37, 0x00 }); // TYA
        put(&fb, &fc, &.{ 0x8A, 0x8F, @truncate(split_cell_x), 0x37, 0x00 }); // TXA
        put(&fb, &fc, &.{ 0x68, 0x28 }); // PLA / PLP — caller state fully intact
        put(&fb, &fc, &.{ 0x48, 0xDA, 0x5A, 0x08, 0xE2, 0x30 }); // PHA/PHX/PHY/PHP/SEP #$30
        // Caller D/DBR/P to the replay; enqueue; wait if deferred.
        put(&fb, &fc, &.{ 0xC2, 0x20, 0x0B, 0x68, 0x8F, @truncate(split_cell_d), 0x37, 0x00, 0xE2, 0x20 });
        put(&fb, &fc, &.{ 0x8B, 0x68, 0x8F, @truncate(split_cell_dbr), 0x37, 0x00 });
        put(&fb, &fc, &.{ 0xA3, 0x01, 0x8F, @truncate(split_cell_pw), 0x37, 0x00 }); // caller P
        put(&fb, &fc, &.{ 0xAF, @truncate(split_rpc_ack), 0x37, 0x00, 0x8F, @truncate(split_scr_a), 0x37, 0x00 }); // old ack
        put(&fb, &fc, &.{ 0xAF, @truncate(split_ring_wr), 0x37, 0x00, 0xAA }); // wr -> X
        put(&fb, &fc, &.{ 0xA9, @intCast(i), 0x9F, @truncate(split_ring), 0x37, 0x00 }); // id -> ring,X
        put(&fb, &fc, &.{ 0xE8, 0x8A, 0x29, 0x0F, 0x8F, @truncate(split_ring_wr), 0x37, 0x00 });
        if (deferred) {
            put(&fb, &fc, &.{ 0xAF, @truncate(split_rpc_ack), 0x37, 0x00 }); // spin: ack
            put(&fb, &fc, &.{ 0xCF, @truncate(split_scr_a), 0x37, 0x00 }); // still the old one?
            put(&fb, &fc, &.{ 0xF0, 0xF6 }); // BEQ spin
            put(&fb, &fc, &.{ 0x28, 0x7A, 0xFA, 0x68 }); // PLP/PLX/PLA
            put(&fb, &fc, &[_]u8{if (io.rtl) 0x6B else 0x60}); // pop the GAME frame, in the body's own bank
        } else {
            put(&fb, &fc, &.{ 0x28, 0x7A, 0xFA, 0x68 }); // PLP/PLX/PLA
            @memcpy(fb[fc .. fc + span], out[splitFile(io.entry)..][0..span]);
            fc += span;
            put(&fb, &fc, &.{ 0x4C, @truncate(e16 + @as(u16, @intCast(span))), @truncate((e16 + @as(u16, @intCast(span))) >> 8) }); // back into the body
        }
        // the S-CPU: A and P back, the prefix, the body
        fb[scpu_at + 1] = @intCast(fc - (scpu_at + 2));
        put(&fb, &fc, &.{ 0x68, 0x28 }); // PLA / PLP
        @memcpy(fb[fc .. fc + span], out[splitFile(io.entry)..][0..span]);
        fc += span;
        put(&fb, &fc, &.{ 0x4C, @truncate(e16 + @as(u16, @intCast(span))), @truncate((e16 + @as(u16, @intCast(span))) >> 8) }); // back into the body
        const sat = far.nextIn(bank, @intCast(fc), if (bank == 0) carve else 0, if (bank == 0) carve_len else 0) orelse
            return refuse(refusal, .{ .reason = .no_free_space, .detail = @intCast(fc) });
        @memcpy(out[sat .. sat + fc], fb[0..fc]);
        stub16[i] = @intCast(0x8000 + (sat % 0x8000));
    }
    // The dispatch table: 4-byte entries (lo, hi, bank, 0).
    const tbl16: u16 = base16 + @as(u16, @intCast(cur));
    for (spec.io_entries, 0..) |_, i| {
        put(d, &cur, &.{ @truncate(tramp24[i]), @truncate(tramp24[i] >> 8), @truncate(tramp24[i] >> 16), 0x00 });
    }
    std.mem.writeInt(u16, d[tbl_lo_at + 1 ..][0..2], tbl16, .little);
    std.mem.writeInt(u16, d[tbl_bank_at + 1 ..][0..2], tbl16 + 2, .little);

    // --- displacements, last: everything they jump into now exists ----
    for (spec.io_entries, 0..) |io, i| {
        const span = splitPrefixSpan(out, usage, io.entry, 3);
        const f = splitFile(io.entry);
        if (n_disp.* == disp.len) return refuse(refusal, .{ .reason = .wg_split_shape, .detail = io.entry });
        disp[n_disp.*] = .{ .addr = io.entry, .len = @intCast(span), .bytes = undefined };
        @memcpy(disp[n_disp.*].bytes[0..span], out[f..][0..span]);
        n_disp.* += 1;
        out[f] = 0x4C; // JMP stub — bank-local, frameless
        std.mem.writeInt(u16, out[f + 1 ..][0..2], stub16[i], .little);
        if (span > 3) @memset(out[f + 3 ..][0 .. span - 3], 0xEA);
    }
    res.stats.split_io = @intCast(spec.io_entries.len);
    curp.* = cur;
}

/// The mainloop flavor's `$4212` / joypad readers. A reader the game shares
/// between boot and gameplay (Super Metroid's four-vblank wait at
/// `$80:8436`, measured: the boot hung in it once the operand was swapped
/// to a mirror nobody fed yet) cannot simply read the mirror: on the
/// S-CPU the real register is right, always; only the SA-1 needs the
/// pump-fed cell. Each 3-byte absolute read of `$4212`/`$4218-$421F` in
/// the declared ranges becomes a bank-local JSR to a helper in the
/// site's bank that discriminates by stack page and performs the SAME
/// opcode against the register (S-CPU) or the mirror (SA-1, through a
/// long form when the opcode has one — the SA-1's DBR is whatever the
/// game left) after restoring the caller's P, so the flags the branch
/// after the read looks at are the load's own.
fn emitSplitReaders(out: []u8, usage: []const u8, spec: SplitSpec, far: *FarPad, carve: u32, carve_len: u32, disp: *[512]Displaced, n_disp: *u32, refusal: *?Refusal) Error!void {
    for (spec.vbl_ranges) |r| {
        // Keyed on the coverage map's instruction starts, not decoded from
        // the range's first byte: a range given by hand starts wherever it
        // starts (measured: a walk from mid-instruction missed $80:8525).
        var pc: u32 = r[0];
        while (pc < r[1]) : (pc += 1) {
            const f = splitFile(@intCast(pc));
            const op = out[f];
            const u = splitUsage(usage, @intCast(pc));
            const m8 = u & usage_map.flag_m != 0;
            const x8 = u & usage_map.flag_x != 0;
            const len = usage_map.instrLen(op, m8, x8);
            const is_read = switch (op) {
                0xAD, 0xAE, 0xAC, 0x2C, 0xCD, 0xEC, 0xCC, 0x0D, 0x2D, 0x4D, 0x6D, 0xED => true,
                else => false,
            };
            if (len == 3 and is_read and u & usage_map.flag_opcode != 0) {
                const v = std.mem.readInt(u16, out[f + 1 ..][0..2], .little);
                const mirror: u16 = if (v == 0x4212)
                    split_vbl_mirror
                else if (v >= 0x4218 and v <= 0x421F)
                    split_pad_mirror + (v - 0x4218)
                else
                    0;
                if (mirror != 0) {
                    // A-register ops have a long form (op | $02); the rest
                    // read the mirror through the DBR.
                    const long_op: ?u8 = switch (op) {
                        0xAD, 0xCD, 0x0D, 0x2D, 0x4D, 0x6D, 0xED => op | 0x02,
                        else => null,
                    };
                    var hb: [40]u8 = undefined;
                    var hc: usize = 0;
                    put(&hb, &hc, &.{ 0x08, 0xC2, 0x20, 0x3B, 0x29, 0x00, 0xF0, 0xC9, 0x00, 0x30 }); // PHP / REP #$20 / TSC / AND / CMP
                    // A pad LOAD on the S-CPU also feeds the mirror (STA/STX/STY
                    // leave the flags alone, so the branch after the read still
                    // sees the load's own): the game's poll is the feed.
                    const feed_op: ?u8 = if (v >= 0x4218) switch (op) {
                        0xAD => @as(u8, 0x8F), // STA long
                        0xAE => @as(u8, 0x8E), // STX abs (I-RAM aliases in every code bank)
                        0xAC => @as(u8, 0x8C), // STY abs
                        else => null,
                    } else null;
                    const scpu_len: u8 = if (feed_op) |fo| (if (fo == 0x8F) 9 else 8) else 5;
                    put(&hb, &hc, &.{ 0xF0, scpu_len }); // BEQ the SA-1 read
                    put(&hb, &hc, &.{ 0x28, op, @truncate(v), @truncate(v >> 8) }); // PLP / the read, real
                    if (feed_op) |fo| {
                        if (fo == 0x8F) {
                            put(&hb, &hc, &.{ 0x8F, @truncate(mirror), @truncate(mirror >> 8), 0x00 });
                        } else {
                            put(&hb, &hc, &.{ fo, @truncate(mirror), @truncate(mirror >> 8) });
                        }
                    }
                    put(&hb, &hc, &.{0x60}); // RTS
                    if (long_op) |lo| {
                        put(&hb, &hc, &.{ 0x28, lo, @truncate(mirror), @truncate(mirror >> 8), 0x00, 0x60 });
                    } else {
                        put(&hb, &hc, &.{ 0x28, op, @truncate(mirror), @truncate(mirror >> 8), 0x60 });
                    }
                    const bank: u32 = (pc >> 16) & 0x7F;
                    const at = far.nextIn(bank, @intCast(hc), if (bank == 0) carve else 0, if (bank == 0) carve_len else 0) orelse
                        return refuse(refusal, .{ .reason = .no_free_space, .detail = @intCast(hc) });
                    @memcpy(out[at .. at + hc], hb[0..hc]);
                    const h16: u16 = @intCast(0x8000 + (at % 0x8000));
                    if (n_disp.* == disp.len) return refuse(refusal, .{ .reason = .wg_split_shape, .detail = @intCast(pc) });
                    disp[n_disp.*] = .{ .addr = @intCast(pc), .len = 3, .bytes = undefined };
                    @memcpy(disp[n_disp.*].bytes[0..3], out[f..][0..3]);
                    n_disp.* += 1;
                    out[f] = 0x20; // JSR helper — bank-local, the same 3 bytes
                    std.mem.writeInt(u16, out[f + 1 ..][0..2], h16, .little);
                }
            }
        }
    }
}

/// The math shadow (mainloop flavor). The S-CPU's multiplier and divider
/// ($4202-$4206 in, $4214-$4217 out) are open bus on the SA-1, and the
/// game loop uses them from dozens of sites in no fixed idiom (measured
/// on Super Metroid: 46-70 touches per frame). Each covered absolute
/// store or load of those registers is displaced with a JSL to a helper
/// that runs the original instruction on the S-CPU and, on the SA-1
/// (stack page $3xxx), the same access against I-RAM cells — a write of
/// $4203 computing the 8x8 product through the SA-1's arithmetic unit,
/// a write of $4206 the unsigned 16/8 quotient and remainder in software
/// (exact, divide-by-zero included: quotient $FFFF, remainder the
/// dividend). Each site is displaced by a bank-local JSR (the same 3
/// bytes) to a helper in its own bank; no neighbouring instruction is
/// copied.
/// A site the split displaced, with the bytes it replaced — so the
/// S-CPU's copy of the game can have them back (see the dual image).
const MathSite = struct { addr: u24, bytes: [3]u8 };
const Displaced = struct { addr: u24, len: u8, bytes: [8]u8 };

fn emitSplitMath(out: []u8, usage: []const u8, far: *FarPad, carve: u32, carve_len: u32, sites: *[1024]MathSite, n_out: *u32, refusal: *?Refusal, res: *Result) Error!void {
    // The shared calculators, once.
    var calc: [160]u8 = undefined;
    var cc: usize = 0;
    // mulcalc: product := A-cell * B-cell (8x8 unsigned fits the signed 16x16 unit)
    put(&calc, &cc, &.{ 0x08, 0xC2, 0x20, 0x48, 0xE2, 0x20 }); // PHP / REP #$20 / PHA / SEP #$20
    put(&calc, &cc, &.{ 0xAF, @truncate(split_math_a), @truncate(split_math_a >> 8), 0x00, 0x8D, 0x51, 0x22, 0x9C, 0x52, 0x22 }); // MA
    put(&calc, &cc, &.{ 0xAF, @truncate(split_math_a + 1), @truncate((split_math_a + 1) >> 8), 0x00, 0x8D, 0x53, 0x22, 0x9C, 0x54, 0x22 }); // MB (triggers)
    put(&calc, &cc, &.{ 0xEA, 0xEA, 0xEA, 0xC2, 0x20, 0xAD, 0x06, 0x23 }); // the unit's 5 cycles; product low word
    put(&calc, &cc, &.{ 0x8F, @truncate(split_math_r), @truncate(split_math_r >> 8), 0x00, 0x68, 0x28, 0x6B }); // -> remainder/product cells; PLA/PLP/RTL
    const mul_len = cc;
    // divcalc: unsigned 16/8, restoring shift-subtract, 16 rounds
    put(&calc, &cc, &.{ 0x08, 0xC2, 0x30, 0x48, 0xDA, 0xE2, 0x20 }); // PHP / REP #$30 / PHA / PHX / SEP #$20
    put(&calc, &cc, &.{ 0xAF, @truncate(split_math_div + 2), @truncate((split_math_div + 2) >> 8), 0x00 }); // divisor
    put(&calc, &cc, &.{ 0xD0, 0x0F }); // BNE ok
    put(&calc, &cc, &.{ 0xC2, 0x20, 0xA9, 0xFF, 0xFF, 0x8F, @truncate(split_math_q), @truncate(split_math_q >> 8), 0x00 }); // q := $FFFF
    put(&calc, &cc, &.{ 0xAF, @truncate(split_math_div), @truncate(split_math_div >> 8), 0x00 }); // r := dividend
    put(&calc, &cc, &.{ 0x80, 0x24 }); // BRA store-r (patched below by construction)
    // ok:
    put(&calc, &cc, &.{ 0xC2, 0x20, 0xAF, @truncate(split_math_div), @truncate(split_math_div >> 8), 0x00 }); // dividend
    put(&calc, &cc, &.{ 0x8F, @truncate(split_math_q), @truncate(split_math_q >> 8), 0x00 }); // q := dividend (shift register)
    put(&calc, &cc, &.{ 0xA9, 0x00, 0x00, 0x8F, @truncate(split_math_r), @truncate(split_math_r >> 8), 0x00 }); // r := 0
    put(&calc, &cc, &.{ 0xA2, 0x10, 0x00 }); // LDX #16
    const loop_at = cc;
    put(&calc, &cc, &.{ 0x0E, @truncate(split_math_q), @truncate(split_math_q >> 8) }); // ASL q (DBR-relative: I-RAM aliases in every code bank)
    put(&calc, &cc, &.{ 0x2E, @truncate(split_math_r), @truncate(split_math_r >> 8) }); // ROL r
    put(&calc, &cc, &.{ 0xAD, @truncate(split_math_r), @truncate(split_math_r >> 8), 0x38, 0xED, @truncate(split_math_div + 2), @truncate((split_math_div + 2) >> 8) }); // r - divisor (the byte past it is zero)
    put(&calc, &cc, &.{ 0x90, 0x06 }); // BCC skip
    put(&calc, &cc, &.{ 0x8D, @truncate(split_math_r), @truncate(split_math_r >> 8), 0xEE, @truncate(split_math_q), @truncate(split_math_q >> 8) }); // r := diff; INC q
    put(&calc, &cc, &.{0xCA}); // DEX
    const back: i32 = @as(i32, @intCast(loop_at)) - (@as(i32, @intCast(cc)) + 2);
    put(&calc, &cc, &.{ 0xD0, @bitCast(@as(i8, @intCast(back))) }); // BNE loop
    put(&calc, &cc, &.{ 0xFA, 0x68, 0x28, 0x6B }); // PLX / PLA / PLP / RTL
    // the zero-divisor branch's store-r lands on a PLX: give it its own tail
    const zero_tail = cc;
    put(&calc, &cc, &.{ 0x8F, @truncate(split_math_r), @truncate(split_math_r >> 8), 0x00, 0xFA, 0x68, 0x28, 0x6B });
    // fix the BRA: from its own end to zero_tail
    {
        var i: usize = mul_len;
        while (i + 1 < cc) : (i += 1) {
            if (calc[i] == 0x80 and calc[i + 1] == 0x24) {
                calc[i + 1] = @intCast(zero_tail - (i + 2));
                break;
            }
        }
    }
    const cat = far.next(@intCast(cc)) orelse return refuse(refusal, .{ .reason = .no_free_space, .detail = @intCast(cc) });
    @memcpy(out[cat .. cat + cc], calc[0..cc]);
    const mul24: u24 = @intCast(((cat / 0x8000) << 16) | (0x8000 + (cat % 0x8000)));
    const div24: u24 = mul24 + @as(u24, @intCast(mul_len));

    // The sites. Each 3-byte absolute access becomes `COP nn / NOP`: a
    // software interrupt whose handler (bank $00, the native COP vector —
    // the SA-1 reads the same ROM vector) finds the site's descriptor by
    // its bank and signature byte and performs the one instruction on
    // the interrupted registers: the real register on the S-CPU, the
    // cell on the SA-1, loads landing in the saved register with the
    // saved P's N/Z set as the load would have. No bytes in the site's
    // bank, no neighbouring instruction copied — the previous shapes
    // (a JSL over a span, a bank-local JSR) each failed on Super
    // Metroid: a `PHA` in a span, a bank with 63 free bytes.
    const Desc = struct { addr: u24, off: u8, kind: u8 };
    var descs: [1024]Desc = undefined;
    var n_sites: u32 = 0;
    var per_bank: [0x40]u16 = @splat(0);
    {
        var bank: u32 = 0;
        while (bank * 0x8000 < out.len and bank < 0x40) : (bank += 1) {
            var aa: u32 = 0x8000;
            while (aa < 0xFFFD) : (aa += 1) {
                const ac: u24 = @intCast((bank << 16) | aa);
                const u = splitUsage(usage, ac);
                if (u & usage_map.flag_opcode == 0) continue;
                const file = splitFile(ac);
                const op = out[file];
                const kind: u8 = switch (op) {
                    0x8D => 0,
                    0x8E => 1,
                    0x8C => 2,
                    0x9C => 3,
                    0xAD => 4,
                    0xAE => 5,
                    0xAC => 6,
                    else => continue,
                };
                const reg = std.mem.readInt(u16, out[file + 1 ..][0..2], .little);
                const math_in = reg >= 0x4202 and reg <= 0x4206;
                const math_out = reg >= 0x4214 and reg <= 0x4217;
                if (!(kind <= 3 and math_in) and !(kind >= 4 and math_out)) continue;
                const idx_reg = kind == 1 or kind == 2 or kind == 5 or kind == 6;
                const wide = if (idx_reg) u & usage_map.flag_x == 0 else u & usage_map.flag_m == 0;
                if (n_sites == descs.len or per_bank[bank] == 256)
                    return refuse(refusal, .{ .reason = .wg_split_shape, .detail = ac });
                descs[n_sites] = .{ .addr = ac, .off = @intCast(reg - 0x4202), .kind = kind | (if (wide) @as(u8, 0x80) else 0) };
                n_sites += 1;
                per_bank[bank] += 1;
            }
        }
    }
    if (n_sites != 0) {
        // Block: [handler][bank table: 64 words][per-bank descriptors].
        var hb: [512]u8 = undefined;
        var hc: usize = 0;
        put(&hb, &hc, &.{ 0xC2, 0x30, 0x48, 0xDA, 0x5A, 0x0B, 0x8B, 0x4B, 0xAB }); // REP #$30 / PHA PHX PHY PHD PHB / PHK PLB
        put(&hb, &hc, &.{ 0x3B, 0x29, 0x00, 0xF0, 0xC9, 0x00, 0x30, 0xF0, 0x09 }); // the SA-1 skips the SIWP open
        put(&hb, &hc, &.{ 0xE2, 0x20, 0xA9, 0xFF, 0x8D, 0x29, 0x22, 0xC2, 0x20 }); // SIWP := $FF (boot-time COPs run before any engage)
        put(&hb, &hc, &.{ 0xF4, @truncate(split_cop_dp), @truncate(split_cop_dp >> 8), 0x2B }); // PEA / PLD: D = the scratch page
        put(&hb, &hc, &.{ 0xA3, 0x0B, 0x3A, 0x85, 0x00 }); // LDA $0B,S (PC) / DEC / STA $00 — the signature's address
        put(&hb, &hc, &.{ 0xE2, 0x20, 0xA3, 0x0D, 0x85, 0x02 }); // SEP #$20 / LDA $0D,S (PBR) / STA $02
        put(&hb, &hc, &.{ 0xA7, 0x00, 0x85, 0x03 }); // LDA [$00] / STA $03 — nn
        put(&hb, &hc, &.{ 0xC2, 0x20, 0xA5, 0x02, 0x29, 0x3F, 0x00, 0x0A, 0xAA }); // REP / LDA $02 / AND #$3F (the mirror bit off: the table is 64 banks) / ASL / TAX
        const bank_tbl_ref = hc;
        put(&hb, &hc, &.{ 0xBD, 0x00, 0x00, 0x85, 0x04 }); // LDA banktbl,X (patched) / STA $04
        put(&hb, &hc, &.{ 0xA5, 0x03, 0x29, 0xFF, 0x00, 0x0A, 0x18, 0x65, 0x04, 0xAA }); // nn*2 + base -> X
        put(&hb, &hc, &.{ 0xBD, 0x00, 0x00, 0x85, 0x06 }); // LDA $0000,X / STA $06: $06 = off, $07 = kind|wide
        // the target: the register (S-CPU) or the cell (SA-1), into [$08]
        put(&hb, &hc, &.{ 0x3B, 0x29, 0x00, 0xF0, 0xC9, 0x00, 0x30, 0xF0, 0x0D });
        put(&hb, &hc, &.{ 0xA5, 0x06, 0x29, 0xFF, 0x00, 0x18, 0x69, 0x02, 0x42, 0x85, 0x08, 0x80, 0x14 }); // reg = $4202 + off
        put(&hb, &hc, &.{ 0xA5, 0x06, 0x29, 0xFF, 0x00, 0xC9, 0x08, 0x00, 0xB0, 0x06 }); // off < 8 ?
        put(&hb, &hc, &.{ 0x18, 0x69, @truncate(split_math_a), @truncate(split_math_a >> 8), 0x80, 0x04 }); // cell = $36F0 + off
        put(&hb, &hc, &.{ 0x18, 0x69, @truncate(split_math_q - 0x12), @truncate((split_math_q - 0x12) >> 8) }); // cell = $36E4 + off
        put(&hb, &hc, &.{ 0x85, 0x08, 0x64, 0x0A }); // STA $08 / STZ $0A (pointer bank 0)
        // kind
        put(&hb, &hc, &.{ 0xA5, 0x07, 0x29, 0x07, 0x00, 0xC9, 0x04, 0x00 }); // LDA $07 / AND #7 / CMP #4
        const bcs_loads_at = hc;
        put(&hb, &hc, &.{ 0xB0, 0x00 }); // BCS loads (patched)
        // stores: the value from the saved register
        put(&hb, &hc, &.{ 0xC9, 0x00, 0x00, 0xD0, 0x04, 0xA3, 0x08, 0x80, 0x15 }); // A
        put(&hb, &hc, &.{ 0xC9, 0x01, 0x00, 0xD0, 0x04, 0xA3, 0x06, 0x80, 0x0C }); // X
        put(&hb, &hc, &.{ 0xC9, 0x02, 0x00, 0xD0, 0x04, 0xA3, 0x04, 0x80, 0x03 }); // Y
        put(&hb, &hc, &.{ 0xA9, 0x00, 0x00 }); // STZ: zero
        put(&hb, &hc, &.{ 0x24, 0x06, 0x10, 0x04, 0x87, 0x08, 0x80, 0x06 }); // BIT $06 (N = wide) / wide: STA [$08]
        put(&hb, &hc, &.{ 0xE2, 0x20, 0x87, 0x08, 0xC2, 0x20 }); // narrow: SEP / STA [$08] / REP
        // SA-1: the triggers
        put(&hb, &hc, &.{ 0x3B, 0x29, 0x00, 0xF0, 0xC9, 0x00, 0x30 });
        put(&hb, &hc, &.{ 0xF0, 0x03 }); // BEQ over the BRL: the SA-1 goes on to the triggers
        const bne_exit1_at = hc;
        put(&hb, &hc, &.{ 0x82, 0x00, 0x00 }); // BRL exit (patched; the exit is past a short branch's reach)
        put(&hb, &hc, &.{ 0xA5, 0x06, 0x29, 0xFF, 0x00 }); // off
        put(&hb, &hc, &.{ 0xC9, 0x01, 0x00, 0xF0, 0x17 }); // $4203 -> mul
        put(&hb, &hc, &.{ 0xC9, 0x04, 0x00, 0xF0, 0x18 }); // $4206 -> div
        put(&hb, &hc, &.{ 0x24, 0x06, 0x10, 0x0A }); // narrow: exit
        put(&hb, &hc, &.{ 0xC9, 0x00, 0x00, 0xF0, 0x09 }); // wide $4202 -> mul
        put(&hb, &hc, &.{ 0xC9, 0x03, 0x00, 0xF0, 0x0A }); // wide $4205 -> div
        const bra_exit2_at = hc;
        put(&hb, &hc, &.{ 0x80, 0x00 }); // BRA exit (patched)
        put(&hb, &hc, &.{ 0xEA, 0xEA }); // pad, keeps the branch arithmetic above exact
        const mul_call_at = hc;
        put(&hb, &hc, &.{ 0x22, @truncate(mul24), @truncate(mul24 >> 8), @truncate(mul24 >> 16) });
        const bra_exit3_at = hc;
        put(&hb, &hc, &.{ 0x80, 0x00 }); // BRA exit (patched)
        const div_call_at = hc;
        put(&hb, &hc, &.{ 0x22, @truncate(div24), @truncate(div24 >> 8), @truncate(div24 >> 16) });
        const bra_exit4_at = hc;
        put(&hb, &hc, &.{ 0x80, 0x00 }); // BRA exit (patched)
        // loads: A = kind (4/5/6); three copies, one per saved slot
        const loads_at = hc;
        hb[bcs_loads_at + 1] = @intCast(loads_at - (bcs_loads_at + 2));
        put(&hb, &hc, &.{ 0xC9, 0x05, 0x00, 0xF0, 0x20, 0xB0, 0x40 }); // 5 -> X copy, 6 -> Y copy, else A
        const slots = [_]u8{ 0x09, 0x07, 0x05 }; // A, X, Y saved slots, +1 for the PHP
        var exit_patches: [3]usize = undefined;
        for (slots, 0..) |sl, k| {
            put(&hb, &hc, &.{ 0x24, 0x06, 0x10, 0x04, 0xA7, 0x08, 0x80, 0x04 }); // wide: LDA [$08]
            put(&hb, &hc, &.{ 0xE2, 0x20, 0xA7, 0x08 }); // narrow: SEP / LDA [$08]
            put(&hb, &hc, &.{ 0x08, 0x83, sl, 0xE2, 0x20, 0x68, 0x29, 0x82, 0x85, 0x0C }); // PHP / STA slot,S / SEP / PLA / AND #$82 / STA $0C
            put(&hb, &hc, &.{ 0xA3, 0x0A, 0x29, 0x7D, 0x05, 0x0C, 0x83, 0x0A }); // saved P: keep all but N/Z, merge
            exit_patches[k] = hc;
            put(&hb, &hc, &.{ 0x80, 0x00 }); // BRA exit (patched)
        }
        std.debug.assert(hc - loads_at - 7 == 96); // three 32-byte copies
        const exit_at = hc;
        put(&hb, &hc, &.{ 0xC2, 0x30, 0xAB, 0x2B, 0x7A, 0xFA, 0x68, 0x40 }); // REP #$30 / PLB PLD PLY PLX PLA / RTI
        std.mem.writeInt(u16, hb[bne_exit1_at + 1 ..][0..2], @intCast(exit_at - (bne_exit1_at + 3)), .little);
        hb[bra_exit2_at + 1] = @intCast(exit_at - (bra_exit2_at + 2));
        hb[bra_exit3_at + 1] = @intCast(exit_at - (bra_exit3_at + 2));
        hb[bra_exit4_at + 1] = @intCast(exit_at - (bra_exit4_at + 2));
        for (exit_patches) |at| hb[at + 1] = @intCast(exit_at - (at + 2));
        std.debug.assert(mul_call_at == bne_exit1_at + 3 + 5 + 5 + 5 + 4 + 5 + 5 + 2 + 2); // the trigger branches land on the calls
        std.debug.assert(div_call_at == mul_call_at + 6);
        // the block
        const bank_tbl_at = hc;
        const desc_at = hc + 0x80;
        const total: u32 = @intCast(desc_at + @as(usize, n_sites) * 2);
        const at = far.nextIn(0, total, carve, carve_len) orelse
            return refuse(refusal, .{ .reason = .no_free_space, .detail = total });
        const base: u16 = @intCast(0x8000 + at);
        std.mem.writeInt(u16, hb[bank_tbl_ref + 1 ..][0..2], base + @as(u16, @intCast(bank_tbl_at)), .little);
        @memcpy(out[at .. at + hc], hb[0..hc]);
        // per-bank descriptor tables, sites numbered in address order
        var next: [0x40]u16 = undefined;
        var cursor: usize = desc_at;
        for (0..0x40) |bk| {
            next[bk] = 0;
            const t: u16 = base + @as(u16, @intCast(cursor));
            std.mem.writeInt(u16, out[at + bank_tbl_at + bk * 2 ..][0..2], t, .little);
            cursor += @as(usize, per_bank[bk]) * 2;
        }
        for (descs[0..n_sites]) |dsc| {
            const bk: usize = (dsc.addr >> 16) & 0x3F;
            const t = std.mem.readInt(u16, out[at + bank_tbl_at + bk * 2 ..][0..2], .little) - 0x8000;
            const nn = next[bk];
            next[bk] += 1;
            out[t + nn * 2] = dsc.off;
            out[t + nn * 2 + 1] = dsc.kind;
            const file = splitFile(dsc.addr);
            sites[n_out.*] = .{ .addr = dsc.addr, .bytes = out[file..][0..3].* };
            n_out.* += 1;
            out[file] = 0x02; // COP
            out[file + 1] = @intCast(nn);
            out[file + 2] = 0xEA;
        }
        // the native COP vector, both CPUs' (the SA-1 does not intercept it)
        std.mem.writeInt(u16, out[0x7FE4..0x7FE6], base, .little);
    }
    res.stats.split_mul = @intCast(@min(n_sites, 255));
    res.stats.split_math_sites = n_sites;
}

/// The shared IO machinery: per-routine drain trampolines, enqueue
/// stubs (span-generalized: sites whose whole-instruction prefix runs
/// past 3 bytes are NOP-filled so the stub's RTS lands in fill), the
/// dispatch table, and the site displacements. `jsr_patch_at` is the
/// draining `JSR (tbl,X)` whose operand this fills in.
fn emitSplitIo(
    out: []u8,
    usage: []const u8,
    spec: SplitSpec,
    d: []u8,
    curp: *usize,
    base16: u16,
    jsr_patch_at: usize,
    far: *FarPad,
    refusal: *?Refusal,
    res: *Result,
) Error!void {
    var cur = curp.*;
    // Drain trampolines stay in the carve: the drains' `JSR (tbl,X)`
    // fetches its pointer from PBR's bank, and they are small.
    //
    // The call frame is pushed BEFORE the displaced prefix runs: a
    // prefix may open with PHP (the screen family does), and the body's
    // closing PLP must find that P on top — with the old layout the
    // bridge's frame sat between them, the PLP ate the frame's PCL, and
    // the RTL flew into bank $34 padding (measured: an IRQ-storming
    // wild march at clk 70.37M).
    var tramp_addrs: [26]u16 = undefined;
    for (spec.io_entries, 0..) |io, i| {
        const span = splitPrefixSpan(out, usage, io.entry, 3);
        if (span == 0) return refuse(refusal, .{ .reason = .wg_split_shape, .detail = io.entry });
        const e16: u16 = @truncate(io.entry);
        tramp_addrs[i] = base16 + @as(u16, @intCast(cur));
        if (io.rtl) {
            const helper = tramp_addrs[i] + 5;
            put(d, &cur, &.{ 0x22, @truncate(helper), @truncate(helper >> 8), 0x00, 0x60 });
        } else {
            const helper = tramp_addrs[i] + 4;
            put(d, &cur, &.{ 0x20, @truncate(helper), @truncate(helper >> 8), 0x60 });
        }
        @memcpy(d[cur .. cur + span], out[splitFile(io.entry)..][0..span]);
        cur += span;
        put(d, &cur, &.{ 0x4C, @truncate(e16 + @as(u16, @intCast(span))), @truncate((e16 + @as(u16, @intCast(span))) >> 8) });
    }
    // Enqueue stubs live in the FAR pool — seventeen of them overran
    // the carve, and a stripped assert let the overflow eat the shim.
    // Bank $00 keeps a 4-byte JML hop per entry; an RTS-shaped deferred
    // return needs its pop to happen with PBR=$00, so its hop carries
    // one RTS byte the far stub JMLs back to.
    var enq_addrs: [26]u16 = undefined;
    for (spec.io_entries, 0..) |io, i| {
        enq_addrs[i] = base16 + @as(u16, @intCast(cur));
        const hop_jml_at = cur;
        put(d, &cur, &.{ 0x5C, 0x00, 0x00, 0x00 }); // JML far stub (patched)
        var rts_hop16: u16 = 0;
        if (io.deferred and !io.rtl) {
            rts_hop16 = base16 + @as(u16, @intCast(cur));
            put(d, &cur, &.{0x60});
        }
        const need: u32 = 200;
        const at = far.next(need) orelse
            return refuse(refusal, .{ .reason = .no_free_space, .detail = need });
        var fb = out[at .. at + need];
        var fc: usize = 0;
        const fbank: u8 = @intCast(at / 0x8000);
        const fbase: u16 = @intCast(0x8000 + (at % 0x8000));
        // Caller A/X/Y captured whole before anything is disturbed —
        // $9231 takes its VRAM fill target in X and its count in Y, and
        // a replay entering with the drain's registers zero-filled VRAM
        // at (dispatch index * 2) instead: the title menu's gridlines.
        put(fb, &fc, &.{ 0x08, 0xC2, 0x30 }); // PHP / REP #$30
        put(fb, &fc, &.{ 0x8F, @truncate(split_cell_a), 0x37, 0x00 });
        put(fb, &fc, &.{ 0x98, 0x8F, @truncate(split_cell_y), 0x37, 0x00 }); // TYA
        put(fb, &fc, &.{ 0x8A, 0x8F, @truncate(split_cell_x), 0x37, 0x00 }); // TXA
        put(fb, &fc, &.{ 0xAF, @truncate(split_cell_a), 0x37, 0x00 }); // A back
        put(fb, &fc, &.{0x28}); // PLP — caller state fully intact
        // PHY too: SEP #$30 ZEROES the high bytes of X and Y on the 65816.
        // X rode the stack; Y only rode the cell the replay restores from,
        // so every S-CPU-native call left with Y's high byte gone
        // (measured: the option screen's map clear entered with Y=$0FFF
        // and filled $00FF words — the menu logo stayed behind the text).
        put(fb, &fc, &.{ 0x48, 0xDA, 0x5A, 0x08, 0xE2, 0x30 }); // PHA/PHX/PHY/PHP/SEP #$30
        put(fb, &fc, &.{ 0xC2, 0x20, 0x3B, 0x29, 0x00, 0xF0, 0xC9, 0x00, 0x30, 0xE2, 0x20 }); // TSC & $F000 == $3000?
        const not_sa1_at = fc;
        put(fb, &fc, &.{ 0xD0, 0x00 }); // BNE the common tail (patched)
        if (io.ff) {
            // Fire-and-forget (ring 2): record [id][caller D], bump the
            // slot cursor mod 12, restore, return. No spin — the replay
            // happens at the mini-tok, the frame-exit phase where stock
            // ran its trailing sound call anyway.
            put(fb, &fc, &.{ 0xAF, @truncate(split_ring2_wr), 0x37, 0x00, 0x0A, 0x0A, 0xAA });
            put(fb, &fc, &.{ 0xA9, @intCast(i), 0x9F, @truncate(split_ring2), @truncate(split_ring2 >> 8), 0x00 });
            put(fb, &fc, &.{ 0xC2, 0x20, 0x0B, 0x68, 0x9F, @truncate(split_ring2 + 1), @truncate((split_ring2 + 1) >> 8), 0x00, 0xE2, 0x20 });
            put(fb, &fc, &.{ 0xA3, 0x01, 0x9F, @truncate(split_ring2 + 3), @truncate((split_ring2 + 3) >> 8), 0x00 }); // caller P -> record[3]
            put(fb, &fc, &.{ 0xAF, @truncate(split_ring2_wr), 0x37, 0x00, 0x1A, 0xC9, 0x18, 0xD0, 0x02, 0xA9, 0x00 });
            put(fb, &fc, &.{ 0x8F, @truncate(split_ring2_wr), 0x37, 0x00 });
            put(fb, &fc, &.{ 0x28, 0x7A, 0xFA, 0x68 });
            if (io.rtl) {
                put(fb, &fc, &.{0x6B});
            } else {
                put(fb, &fc, &.{ 0x5C, @truncate(rts_hop16), @truncate(rts_hop16 >> 8), 0x00 });
            }
        }
        // Carry the CALLER's D and DBR to the replay: the body's dp and
        // absolute rewrites were made against them (the APU-stream
        // feeder runs D=$7A00 — its count under the pump's $6000 pin
        // read a different page and the ring-copy scan ran unbounded).
        // RPC serializes — one call in flight — so one cell pair holds.
        put(fb, &fc, &.{ 0xC2, 0x20, 0x0B, 0x68, 0x8F, @truncate(split_cell_d), 0x37, 0x00, 0xE2, 0x20 });
        put(fb, &fc, &.{ 0x8B, 0x68, 0x8F, @truncate(split_cell_dbr), 0x37, 0x00 });
        put(fb, &fc, &.{ 0xA3, 0x01, 0x8F, @truncate(split_cell_pw), 0x37, 0x00 }); // caller P (pushed at stub entry)
        put(fb, &fc, &.{ 0xAF, @truncate(split_rpc_ack), 0x37, 0x00, 0x8F, @truncate(split_scr_a), 0x37, 0x00 }); // old ack
        put(fb, &fc, &.{ 0xAF, @truncate(split_ring_wr), 0x37, 0x00, 0xAA }); // wr -> X
        put(fb, &fc, &.{ 0xA9, @intCast(i), 0x9F, @truncate(split_ring), 0x37, 0x00 }); // id -> ring,X
        put(fb, &fc, &.{ 0xE8, 0x8A, 0x29, 0x0F, 0x8F, @truncate(split_ring_wr), 0x37, 0x00 });
        if (io.deferred) {
            // RPC, not fire-and-forget: the body's SHARED-STATE writes
            // must land in program order, so wait for the replay. The
            // release is the ACK bump (after the body), NOT the ring
            // cursor: rd consumes the entry BEFORE the body runs, so a
            // NESTED NMI's drain sees an empty ring and falls through to
            // the displaced epilogue — which is exactly the overrun
            // release a body parked on the $3C handshake is waiting for.
            // Spinning on rd==wr instead made every releasing NMI
            // re-enter the in-service call: infinite regress (measured
            // at the demo transition, frame ~714).
            put(fb, &fc, &.{ 0xAF, @truncate(split_rpc_ack), 0x37, 0x00 }); // spin: ack
            put(fb, &fc, &.{ 0xCF, @truncate(split_scr_a), 0x37, 0x00 }); // still the old one?
            put(fb, &fc, &.{ 0xF0, 0xF6 }); // BEQ spin
            put(fb, &fc, &.{ 0x28, 0x7A, 0xFA, 0x68 }); // PLP/PLX/PLA
            if (io.rtl) {
                put(fb, &fc, &.{0x6B}); // pop the GAME frame — RTL is bank-safe anywhere
            } else {
                put(fb, &fc, &.{ 0x5C, @truncate(rts_hop16), @truncate(rts_hop16 >> 8), 0x00 }); // the hop's RTS pops with PBR=$00
            }
        }
        fb[not_sa1_at + 1] = @intCast(fc - (not_sa1_at + 2));
        put(fb, &fc, &.{ 0x28, 0x7A, 0xFA, 0x68 }); // PLP/PLX/PLA
        {
            const span = splitPrefixSpan(out, usage, io.entry, 3);
            const e16: u16 = @truncate(io.entry);
            @memcpy(fb[fc .. fc + span], out[splitFile(io.entry)..][0..span]);
            fc += span;
            put(fb, &fc, &.{ 0x5C, @truncate(e16 + @as(u16, @intCast(span))), @truncate((e16 + @as(u16, @intCast(span))) >> 8), 0x00 }); // JML back into the body
        }
        if (fc > need) return refuse(refusal, .{ .reason = .wg_split_shape, .detail = io.entry });
        std.mem.writeInt(u16, d[hop_jml_at + 1 ..][0..2], fbase, .little);
        d[hop_jml_at + 3] = fbank;
    }
    const tbl16: u16 = base16 + @as(u16, @intCast(cur));
    for (spec.io_entries, 0..) |_, i| {
        put(d, &cur, &.{ @truncate(tramp_addrs[i]), @truncate(tramp_addrs[i] >> 8) });
    }
    std.mem.writeInt(u16, d[jsr_patch_at + 1 ..][0..2], tbl16, .little);

    // --- displacements, last: everything they jump into now exists ----
    for (spec.io_entries, 0..) |io, i| {
        const span = splitPrefixSpan(out, usage, io.entry, 3);
        const f = splitFile(io.entry);
        out[f] = 0x4C; // JMP enq — frameless, so pushes in the prefix are legal
        std.mem.writeInt(u16, out[f + 1 ..][0..2], enq_addrs[i], .little);
        if (span > 3) @memset(out[f + 3 ..][0 .. span - 3], 0xEA);
    }
    res.stats.split_io = @intCast(spec.io_entries.len);
    curp.* = cur;
}

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
                    if (window and v < 0x100 and (im == .abs_x or im == .abs_y) and
                        (e == 0 or e == usage_map.site_wram_low | usage_map.site_rom))
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
        /// Which of the three index bodies this site takes (see each one).
        fn v2(self: @This()) bool {
            return self.idx and !self.pin and (self.op == 0xB9 or self.op == 0xBD);
        }
        fn len(self: @This()) u32 {
            if (!self.idx) return split_thunk_len;
            if (self.pin) return idx_thunk_len;
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
        if (ml_split != null) wn = emitStore(d, wn, 0x2229, 0xFF);
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
fn dbrSurvives(image: []const u8, cov: []const u8, file: u32, op: u8) bool {
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
    @memcpy(rom[0x0000..0x0018], &[_]u8{
        0x18, 0xFB, 0xE2, 0x30, // CLC / XCE / SEP #$30
        0x9C, 0x81, 0x21, // STZ $2181 — WMADD = $001000
        0xA9, 0x10, 0x8D, 0x82, 0x21, // LDA #$10 / STA $2182
        0x9C, 0x83, 0x21, // STZ $2183
        0xA9, 0x80, 0x8D, 0x00, 0x42, // NMI on
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
        0xAD, 0x16, 0x42, // 8047 LDA $4216 — the remainder
        0x18, 0x6D, 0x08, 0x01, 0x8D, 0x08, 0x01, // 804A += into $0108
        0xE2, 0x20, // 8051 SEP #$20
        0x20, 0x80, 0x80, // 8053 JSR $8080 — the RTS-shaped IO routine (bank $01)
        0x22, 0x60, 0x80, 0x00, // 8056 JSL $00:8060 — the deferred RTL one
        0xC2, 0x20, 0xEE, 0x00, 0x01, 0xE2, 0x20, // 805A the lap counter (16-bit), at the lap's END
        0xAD, 0x00, 0x01, 0x29, 0x01, 0x8D, 0x10, 0x01, // 8061 LDA $0100 / AND #1 / STA $0110 — the mode cell
        0x4C, 0x00, 0x80, // 8069 JMP $8000
    };
    @memcpy(rom[0x8000 .. 0x8000 + loop.len], &loop);
    @memcpy(rom[0x8080..0x8087], &[_]u8{ 0xAD, 0x00, 0x01, 0x8D, 0x80, 0x21, 0x60 }); // LDA $0100 / STA $2180 / RTS

    const bytes = try gpa.alloc(u8, usage_map.cpu_map_len);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    const mark = struct {
        fn f(u: []u8, a: u32, m8: bool) void {
            u[a] |= usage_map.flag_opcode | usage_map.flag_exec | usage_map.flag_x;
            if (m8) u[a] |= usage_map.flag_m;
        }
    }.f;
    for ([_]u32{ 0x8000, 0x8001, 0x8002, 0x8004, 0x8007, 0x8009, 0x800C, 0x800F, 0x8011, 0x8014 }) |a| mark(bytes, a, true);
    for ([_]u32{ 0x8060, 0x8063, 0x8050, 0x8051, 0x8054, 0x8055 }) |a| mark(bytes, a, true);
    // the loop: 8-bit until 801A, 16-bit to 802C, 8-bit to 803B, 16-bit to 8051, 8-bit after
    for ([_]u32{ 0x8000, 0x8002, 0x8003, 0x8004, 0x8005, 0x8007, 0x800A, 0x800C, 0x800E, 0x8011, 0x8013, 0x8016, 0x8017, 0x8018, 0x8019, 0x801A }) |a| mark(bytes, 0x01_0000 | a, true);
    for ([_]u32{ 0x801C, 0x801F, 0x8020, 0x8023, 0x8026, 0x8029, 0x802C }) |a| mark(bytes, 0x01_0000 | a, false);
    for ([_]u32{ 0x802E, 0x8030, 0x8033, 0x8034, 0x8035, 0x8036, 0x8037, 0x8038, 0x8039, 0x803A, 0x803B }) |a| mark(bytes, 0x01_0000 | a, true);
    for ([_]u32{ 0x803D, 0x8040, 0x8041, 0x8044, 0x8047, 0x804A, 0x804B, 0x804E, 0x8051 }) |a| mark(bytes, 0x01_0000 | a, false);
    for ([_]u32{ 0x8053, 0x8056, 0x805A, 0x805C, 0x805F, 0x8061, 0x8064, 0x8066, 0x8069, 0x8080, 0x8083, 0x8086 }) |a| mark(bytes, 0x01_0000 | a, true);

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
    // Seven math sites shadowed; the one hazard the audit lists is the NMI
    // handler's $4210 ack read, which only the S-CPU ever runs.
    try testing.expectEqual(@as(u8, 7), res.stats.split_mul);
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
