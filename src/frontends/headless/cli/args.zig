//! The command line: the `Args` record every mode reads, its defaults, and `parseArgs`. docs/CLI.md is the reference for every flag.
//!
//! Carved out of main.zig as pure code motion; every declaration
//! here is re-exported from main.zig, which stays the root.

const core = @import("snes_core");
const std = @import("std");
const util = @import("util");
const root_mod = @import("../main.zig");

const readScpuSet = root_mod.readScpuSet;
// A var, not an alias: an alias would copy its value at comptime.
const report_mod = @import("report.zig");
/// `--region ntsc|pal|auto`: override the header-detected region. `auto`
/// (the default) uses the cart header's region byte.
pub const RegionArg = enum { auto, ntsc, pal };

pub const Args = struct {
    rom: []const u8,
    frames: ?u32 = null,
    ppm: ?[]const u8 = null,
    /// `--ppm-range start:count:prefix`: DIAGNOSTIC. Dump each frame in
    /// [start, start+count) as `<prefix>NNNNN.ppm` (5-digit, zero-padded) —
    /// a frame window to assemble into a recording of a moving effect the
    /// single final-frame `--ppm` cannot show.
    ppm_range_start: ?u32 = null,
    ppm_range_count: u32 = 0,
    ppm_range_prefix: []const u8 = "frame",
    wav: ?[]const u8 = null,
    accuracy: core.Accuracy = .fast,
    region: RegionArg = .auto,
    patch: ?[]const u8 = null,
    save_patched: ?[]const u8 = null,
    /// Look the loaded ROM up in patches/registry.zon by content hash and
    /// apply its registered patch from `patch_dir` (verified, never fetched).
    auto_patch: bool = false,
    patch_dir: []const u8 = "patches",
    /// Pin MEMSEL to 1 (FastROM cartridge timing for a SlowROM game), gated
    /// by patches/fastrom-compat.zon: `broken` refuses, unknown warns.
    auto_fastrom: bool = false,
    sa1_report: bool = false,
    /// Frames to run before the profiler starts counting. Boot is not gameplay:
    /// the game is decompressing, clearing RAM, and handshaking with the APU,
    /// and none of that is representative of the frame budget in play.
    skip: u32 = 300,
    json: bool = false,
    /// Dump the hottest loops and how each was classified.
    hot: bool = false,
    /// Steps two and three of the analyser: the per-routine cycle attribution
    /// table, and each hot routine's WRAM working set and blockers.
    routines: bool = false,
    /// Stage S1 of the SA-1 arc: export execution/access coverage from the
    /// profiled run as a bsnes-plus `-usage.bin` file (DiztinGUIsh imports
    /// it). A `--sa1-report` modifier, like `--hot`.
    usage_map_out: ?[]const u8 = null,
    /// --call-graph: where to write the routine graph (Graphviz DOT).
    call_graph_out: ?[]const u8 = null,
    /// Stage S2: print the relocation plan — the WRAM -> I-RAM/BW-RAM
    /// allocation map for the conversion verdict's hot set.
    plan: bool = false,
    /// `--wide N` (M12): extra columns rendered on each side of the standard
    /// 256, for a widescreen game patch (e.g. wide-snes) that draws into the
    /// margin. Fast core only — refused together with `--accurate`.
    wide: u32 = 0,
    /// Recorded playthroughs (.ymv) driving both pads from power-on. In a
    /// normal run one movie replays and verifies its end hashes; in the
    /// generator/report modes movies drive the profiled runs, so coverage
    /// and verification come from real gameplay instead of the attract
    /// mode. The generator accepts SEVERAL `--movie` flags: each is an
    /// input SURFACE, all of them feed one evidence/coverage union, and
    /// every one must verify — because each movie is a different world,
    /// and a surface one movie covers can be exactly the surface another
    /// displaces (measured: the movie that added stage-1 gameplay lost
    /// the attract demo, and demo-only code fell out of the rewrite).
    movies: [max_movies][]const u8 = undefined,
    n_movies: usize = 0,
    /// Per-movie: does this movie VERIFY (a surface every attempt must
    /// pass) or only contribute evidence/coverage? `--evidence-movie`
    /// adds the latter kind — a playthrough whose later stretch is
    /// UNVERIFIABLE by construction rather than broken: gameplay forks at
    /// the first RNG-divergent event (enemy RNG seeds from wall-origin
    /// counters the conversion legitimately offsets; measured: stock's
    /// ship exploded at wall 3100 while the byte-equivalent conversion's
    /// ship flew on — every later tick compares two different games). The
    /// code such a stretch covers (death sequence, continue screen) still
    /// runs in real play and still needs its rewrites.
    movie_verify: [max_movies]bool = @splat(true),
    /// TEMP window debugging (undocumented): write WRAM+BWRAM+VRAM to this
    /// file after the run.
    dump_ram: ?[]const u8 = null,
    /// --lap-cell <hex16>: tick per write of this low-WRAM cell (the game's
    /// lap counter) instead of per pad poll; a --repoll then writes a per-lap
    /// (version 4) take. A per-lap take sets it on load.
    lap_cell: u16 = 0,
    /// --ref-overclock <n>: the behavioral tier's BASELINE runs its S-CPU n
    /// times faster (a lag-free stock reference; see Bus.overclock).
    ref_overclock: u8 = 1,
    /// --conv-overclock <n>: the CONVERSION side too — both its S-CPU and
    /// its SA-1 run n times faster in the gate's eras. With
    /// --ref-overclock the tier compares two lag-free machines: logic
    /// equivalence with the lag differential taken out of the picture.
    /// On a plain run of a conversion image, `--ref-overclock` alone
    /// overclocks that image's CPUs the same way (a measurement).
    conv_overclock: u8 = 1,
    /// --apu-port-trace: print every write to APU port 3 with its clock (debug).
    apu_port_trace: bool = false,
    /// --mmio-ref <file>: on a plain replay of a conversion, report every
    /// hardware-register write from a site the generation never saw write
    /// that register (the `.mmio` file written beside a patch: stock's
    /// writer set and the verified conversion's). The MMIO analogue of
    /// `--stale` for a human take.
    mmio_ref: ?[]const u8 = null,
    /// --mmio-out <file>: on a plain replay, write this run's writer set as
    /// a reference (`S` lines) plus the image's padding ranges (`P` lines) —
    /// run it on STOCK to make a reference for `--mmio-ref` without a
    /// generation.
    mmio_out: ?[]const u8 = null,
    /// --mmio-stock <stock.sfc>: with --mmio-ref, a writer whose bytes
    /// still read as stock's instruction is reported separately (stock
    /// code the reference never reached, not a relocation).
    mmio_stock: ?[]const u8 = null,
    /// --cov-out <prefix>: with --gen-sa1-patch, write the coverage the
    /// relocation walked as `<prefix>.usage` (the profiled union) and
    /// `<prefix>.cov` (its static extension), one usage_map flag byte per
    /// CPU address — for tools/sm_disasm_oracle.py.
    cov_out: ?[]const u8 = null,
    /// --code-map <file>: a hand-made disassembly's per-byte verdict (see
    /// tools/sm_disasm_oracle.py --export and sa1gen.dbg_code_map).
    code_map: ?[]const u8 = null,
    /// --split-scpu-set <file>: record (and merge into the file) every S-CPU
    /// instruction address run while a split's upper copy was mapped.
    split_scpu_set: ?[]const u8 = null,
    /// --wg-split-shared <file>: that set, for the generator.
    wg_split_shared: []const u24 = &.{},
    /// `--dump-srm <file>`: write the cart's battery SRAM at the end of the
    /// run — the way to lift a save out of a state (`--state x --frames 1
    /// --dump-srm x.srm`) for `yamabuki-sdl --record --srm`.
    dump_srm: ?[]const u8 = null,
    /// `--dump-ppu`: the display state as text after the run. For the
    /// question a RAM dump cannot answer — a layer that is missing from
    /// the picture is either disabled, pointed somewhere empty, or fed a
    /// tilemap that never arrived, and those look identical in WRAM.
    dump_ppu: ?[]const u8 = null,
    /// `--movie-ignore-crc`: DIAGNOSTIC. Replay a movie whose recorded
    /// image CRC differs from this run's — for re-playing a recording made
    /// on a previous conversion against a freshly regenerated one (window
    /// mode preserves the S-CPU's code and frame timing, so controller
    /// input usually stays in sync). The end-hash check becomes advisory.
    movie_ignore_crc: bool = false,
    /// `--repoll out.ymv`: while replaying `--movie`, record the take again
    /// as a PER-POLL movie (format 3): one entry per controller read the
    /// game made, so the result replays on any build of the game whose
    /// logic is behaviorally equivalent — a stock take migrated to the
    /// conversion, lag frames and all. Same anchor, same end hashes.
    repoll: ?[]const u8 = null,
    /// `--repoll-poweron`: write the re-recorded take without the source
    /// take's anchor. For a take whose anchor is a powered-on machine with
    /// a battery save loaded and nothing run (`--record --srm`): the
    /// result replays from power-on with the same save (`--srm`, or the
    /// `.start.srm` sidecar this writes beside it) — on ANY build.
    repoll_poweron: bool = false,
    /// `--srm <file>`: load a battery save into the cart's save chip (or a
    /// window conversion's lifted save region) before the first frame.
    srm: ?[]const u8 = null,
    /// `--dump-vram`: raw VRAM (64 KiB) then OAM (544 B) after the run.
    dump_vram: ?[]const u8 = null,
    /// --save-state-at: frame to stop at and the file to write the machine to.
    /// A recording that carries its own anchor cannot be a window-mode
    /// surface, but the machine it passes through CAN anchor a profile — this
    /// is how a late-game scene reaches the generator without a power-on take.
    save_state_at: ?u32 = null,
    save_state_path: []const u8 = "",
    /// `--poke ADDR=VAL`: cheat writes held after every frame. Repeatable,
    /// and each flag may carry a comma-separated list.
    pokes: [util.cheat.max_pokes]util.cheat.Poke = undefined,
    n_pokes: usize = 0,
    /// Verifier debugging (undocumented): run ONLY the behavioral tier —
    /// stock ROM as baseline, this converted image, the given movies —
    /// and print the verdict with its full accounting. Iterating the
    /// tier's rules against a preserved failing rung in minutes instead
    /// of re-running the whole generation ladder.
    behavioral_probe: ?[]const u8 = null,
    iram_dump: bool = false,
    /// Window debugging (undocumented): write each verification attempt's
    /// converted image to this path (last attempt wins).
    save_attempt: ?[]const u8 = null,
    /// Window offloads (undocumented --wg-sync): never try the async
    /// flavor. The async monopoly admits ONE tree; a passing async
    /// first attempt ships alone even when the sync ladder would carry
    /// more trees and more speedup.
    wg_sync: bool = false,
    /// Window mode (undocumented --wg-fastrom): layer the FastROM
    /// transform onto every converted attempt image — MEMSEL stub,
    /// interrupt trampolines into the $80 mirrors, observed MEMSEL
    /// stores NOPed. The SA-1 MMC serves the fast mirrors under MEMSEL
    /// like any FastROM cart, so this cuts ~25% off every remaining
    /// S-CPU ROM cycle, orthogonally to the offload trees.
    wg_fastrom: bool = false,
    /// Window offloads (undocumented --wg-drop <hex16>, repeatable):
    /// pre-seed the bisect's dropped list — exclude a tree the surfaces
    /// pass but live play proves unsafe (measured: the $8EF1 walker
    /// races NMI-side slot mutations into a ROM cycle at the continue
    /// screen; movie surfaces never exhibit that interleaving).
    wg_drop: [8]u32 = @splat(0),
    n_wg_drop: usize = 0,
    /// --wg-nmi-off <hex16> (repeatable): wrap these trees' sync stubs
    /// in NMI/IRQ-off across the dispatch (closes the concurrent-
    /// mutation hazard by construction; implies the tree never ships
    /// async).
    wg_nmi_off: [8]u32 = @splat(0),
    n_wg_nmi_off: usize = 0,
    /// --cover-image <patched.sfc> + --cover-movie <f.ymv>: harvest
    /// COVERAGE (opcode + width bits only, no site evidence) from a
    /// movie replayed on a PREVIOUS CONVERSION of this game, merged
    /// into the union wherever the instruction byte matches the stock
    /// image. This is how gameplay only reachable on the conversion
    /// (a recorded run whose inputs are conv-timed dies early when
    /// replayed on stock) still teaches the rewriter which code
    /// exists: which instructions execute is address-space-invariant
    /// even though their operands were rewritten.
    /// Repeatable: each `--cover-image` opens a new pair, and the
    /// `--cover-movie` after it fills the same slot. One recording covers
    /// one scenario, and the defects live in the scenarios nobody
    /// profiled — so the harvest has to take as many as there are.
    cover_image: [max_cover_pairs]?[]const u8 = @splat(null),
    cover_movie: [max_cover_pairs]?[]const u8 = @splat(null),
    n_cover: usize = 0,
    /// --harvest-cache <dir>: keep each cover pair's harvest — the replay's
    /// usage map, site evidence, proven bank bytes and armed HDMA tables —
    /// in a file keyed by the cover image's crc32, the movie file's hash and
    /// `harvest_cache_version`. A generation then replays only the pairs it
    /// has not seen; the merge into the union runs from the file exactly as
    /// it would from the replay. Measured before this existed: 25 recordings,
    /// 785k frames replayed per generation, 24 of them unchanged since the
    /// last. Bump the version whenever the profiler's semantics change.
    harvest_cache: ?[]const u8 = null,
    /// `--baseline-cache <dir>`: snapshot of the stock side of a generation
    /// (evidence pass, per-surface baselines, coverage pad) keyed on every
    /// input it has; a hit skips ~27 minutes of stock replays. See
    /// `saveBaselineSnapshot`.
    baseline_cache: ?[]const u8 = null,
    /// --harvest-jobs N: cover pairs that still need a replay run on N
    /// threads (default: the machine's core count, at most 12). Each replay
    /// owns its console and products; the merges stay on the main thread, in
    /// recipe order, so the union and the log are the same at any N.
    harvest_jobs: usize = 0,
    /// `--verify-jobs N`: surfaces verified concurrently (0 = one per core,
    /// capped at the surface count; 1 = the serial loop, for timing it).
    verify_jobs: usize = 0,
    /// --harvest-render: paint frames during harvest replays (the default
    /// skips the pixel work; the harvest never looks at a frame).
    harvest_render: bool = false,
    /// TEMP S2 debugging (undocumented): with --gen-sa1-patch --state,
    /// comma-separated plan-region indices to KEEP as live relocations
    /// (offloads disabled for the run). Bisects the relocation plan.
    /// Undocumented --hash-stream: write one u64 frame hash per frame to
    /// this path. The picture stream is the comparison that survives a lag
    /// differential, so this is the cheap sound oracle for "did the build
    /// change what the game DOES, or only how fast it does it".
    hash_stream: ?[]const u8 = null,
    s2_keep: ?[]const u8 = null,
    /// Resume from an SDL-player save state instead of power-on (plain runs
    /// and --sa1-report). Same-image, same-core states only.
    state: ?[]const u8 = null,
    /// S4: when the pixel gate says divergent, also run the behavioral
    /// tier — logic-state equality at every logic tick — and accept a
    /// conversion whose divergence is only wall-time echoes.
    verify_behavioral: bool = false,
    /// Diagnostic for the behavioral verifier's design: write every logic
    /// tick's phase-aligned WRAM snapshot (u32 wall frame + 128 KiB raw,
    /// repeated) to this file. Fast core only.
    tick_dump: ?[]const u8 = null,
    /// Generate a FastROM patch for this ROM, verified in-emulator before
    /// anything is written (see `util.generateFastromVerified`).
    gen_fastrom: bool = false,
    /// Stage S3: generate an SA-1 conversion patch — the shell (SA-1 cart +
    /// parked SA-1) plus the plan's clean state relocations — verified
    /// frame- and audio-identical before anything is written.
    gen_sa1: bool = false,
    /// With --gen-sa1-patch: whole-game migration (SA-1 Root) — the entire
    /// game executes on the SA-1 and the S-CPU becomes an MMIO service
    /// loop — instead of the routine-offload ladder.
    whole_game: bool = false,
    /// Uniform window relocation: the game keeps running on the S-CPU and
    /// only its memory moves (WRAM low 8K -> the S-CPU BW-RAM window,
    /// $7E/$7F longs -> $40/$41). Implies the whole-game pipeline shape.
    window: bool = false,
    /// With --whole-game: also rewrite code the profiled run never reached,
    /// discovered by recursive-descent disassembly seeded from coverage.
    /// Unprovable shapes in that code are counted, not refused over.
    wg_static: bool = false,
    /// --wg-copy-reserve: bytes held at the tail of the biggest padding run
    /// for offload tree copies. The default matches the generator's own.
    wg_copy_reserve: u32 = core.sa1gen.copy_reserve,
    /// S5 mainline split: the engage anchor (24-bit, any code bank); zero
    /// = split off. `--wg-split-io <hex24>[:d][:l]`, `--wg-split-vbl
    /// <hex24>-<hex24>` and `--wg-split-mode <cell16>:<value>` (a low-WRAM
    /// address in the mainloop flavor, read at its window home) follow.
    wg_split_mainloop: u24 = 0,
    wg_split_tail: u16 = 0,
    wg_split_epi: u16 = 0,
    wg_split_dbr: u8 = 0,
    wg_split_mode_cell: u16 = 0,
    wg_split_mode_value: u8 = 0,
    wg_split_mode_hi: u8 = 0,
    wg_split_mode: bool = false,
    wg_split_io: [40]core.sa1gen.SplitIo = undefined,
    n_wg_split_io: usize = 0,
    wg_split_vbl: [8][2]u24 = undefined,
    n_wg_split_vbl: usize = 0,
    /// --wg-expand: grow the converted image to this many bytes (0 = keep the
    /// original size), handing the conversion room it does not otherwise have.
    wg_expand_to: u32 = 0,
    /// --wg-add: extra offload candidates (CPU addresses), for routines a
    /// single-scene profile ranks too low to offer.
    wg_add: [8]u24 = @splat(0),
    n_wg_add: usize = 0,
    /// Where to write the generated patch. Default: `<rom>.bps` next to the
    /// ROM — the softpatch convention every frontend picks up by name.
    gen_out: ?[]const u8 = null,
    /// This process's own argv, joined and quoted. Written beside every
    /// generated patch and echoed into the log, because a generation that
    /// cannot be re-issued exactly cannot be reproduced — and three
    /// separate days went into reconstructing one from prose notes, each
    /// time missing a different flag.
    cmdline: []const u8 = "",
};

/// Default frames to profile: 60 seconds at 60 Hz, on top of the skipped boot.
pub const report_frames_default: u32 = 3600;

/// Input surfaces one generator run accepts (each `--movie` or
/// `--evidence-movie` is one). Super Metroid's recipe reached six with the
/// soft-reset take, then the per-poll surfaces the wide gate verifies on.
pub const max_movies: usize = 12;
/// Cover pairs a recipe may carry. The Super Metroid campaign reached 24 —
/// the old cap, hit with a usage error — on its fourth stock take.
pub const max_cover_pairs: usize = 64;

/// Default frames for `--gen-fastrom-patch` verification: 30 seconds, the
/// same standard patches/fastrom-compat.zon entries are verified to.
pub const gen_frames_default: u32 = 1800;

pub fn parseArgs(init: std.process.Init, gpa: std.mem.Allocator) !Args {
    // Not deinit'd — the returned Args slice into it, and `gpa` is the
    // process arena.
    // The invocation, verbatim, before anything consumes it.
    var cmd: std.array_list.Managed(u8) = .init(gpa);
    {
        var cit = try util.argIterator(init, gpa);
        var first = true;
        while (cit.next()) |a| {
            if (!first) try cmd.append(' ');
            first = false;
            const quote = std.mem.indexOfAny(u8, a, " \t\"") != null;
            if (quote) try cmd.append('"');
            try cmd.appendSlice(a);
            if (quote) try cmd.append('"');
        }
    }
    var it = try util.argIterator(init, gpa);
    var out: Args = .{ .rom = undefined, .cmdline = cmd.items };
    var rom: ?[]const u8 = null;
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--frames")) {
            const v = it.next() orelse return error.MissingValue;
            out.frames = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, a, "--skip")) {
            const v = it.next() orelse return error.MissingValue;
            out.skip = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, a, "--ppm")) {
            out.ppm = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--ppm-range")) {
            // "<start>:<count>:<prefix>"
            const v = it.next() orelse return error.MissingValue;
            var pit = std.mem.splitScalar(u8, v, ':');
            out.ppm_range_start = try std.fmt.parseInt(u32, pit.next().?, 10);
            out.ppm_range_count = try std.fmt.parseInt(u32, pit.next() orelse return error.MissingValue, 10);
            out.ppm_range_prefix = pit.next() orelse "frame";
        } else if (std.mem.eql(u8, a, "--wav")) {
            out.wav = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--accurate")) {
            out.accuracy = .accurate;
        } else if (std.mem.eql(u8, a, "--region")) {
            const v = it.next() orelse return error.MissingValue;
            out.region = std.meta.stringToEnum(RegionArg, v) orelse return error.BadRegion;
        } else if (std.mem.eql(u8, a, "--patch")) {
            out.patch = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--auto-patch")) {
            out.auto_patch = true;
        } else if (std.mem.eql(u8, a, "--auto-fastrom")) {
            out.auto_fastrom = true;
        } else if (std.mem.eql(u8, a, "--patch-dir")) {
            out.patch_dir = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--save-patched")) {
            out.save_patched = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--sa1-report")) {
            out.sa1_report = true;
        } else if (std.mem.eql(u8, a, "--json")) {
            out.json = true;
        } else if (std.mem.eql(u8, a, "--hot")) {
            out.hot = true;
        } else if (std.mem.eql(u8, a, "--routines")) {
            out.routines = true;
        } else if (std.mem.eql(u8, a, "--routines-all")) {
            // The full attribution table, for analyses that need every
            // MMIO-touching routine rather than the hot sixteen.
            out.routines = true;
            report_mod.routine_rows_shown = 100000;
        } else if (std.mem.eql(u8, a, "--call-graph")) {
            out.call_graph_out = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--usage-map")) {
            out.usage_map_out = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--plan")) {
            out.plan = true;
        } else if (std.mem.eql(u8, a, "--wide")) {
            const v = it.next() orelse return error.MissingValue;
            out.wide = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, a, "--movie")) {
            const v = it.next() orelse return error.MissingValue;
            if (out.n_movies == max_movies) return error.TooManyMovies;
            out.movies[out.n_movies] = v;
            out.n_movies += 1;
        } else if (std.mem.eql(u8, a, "--evidence-movie")) {
            const v = it.next() orelse return error.MissingValue;
            if (out.n_movies == max_movies) return error.TooManyMovies;
            out.movies[out.n_movies] = v;
            out.movie_verify[out.n_movies] = false;
            out.n_movies += 1;
        } else if (std.mem.eql(u8, a, "--state")) {
            out.state = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--hash-stream")) {
            out.hash_stream = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--s2-keep")) {
            out.s2_keep = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--cheat")) {
            const v = it.next() orelse return error.MissingValue;
            out.n_pokes = util.cheat.parseCodes(v, &out.pokes, out.n_pokes) catch
                return error.BadPoke;
        } else if (std.mem.eql(u8, a, "--poke")) {
            const v = it.next() orelse return error.MissingValue;
            out.n_pokes = util.cheat.parseList(v, &out.pokes, out.n_pokes) catch
                return error.BadPoke;
        } else if (std.mem.eql(u8, a, "--dump-vram")) {
            out.dump_vram = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--dump-ppu")) {
            out.dump_ppu = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--ref-overclock")) {
            out.ref_overclock = try std.fmt.parseInt(u8, it.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, a, "--walk-watch")) {
            const v = it.next() orelse return error.MissingValue;
            var wit = std.mem.splitScalar(u8, v, ',');
            var wi: usize = 0;
            while (wit.next()) |one| : (wi += 1) {
                if (wi == core.sa1gen.dbg_walk_watch.len) break;
                core.sa1gen.dbg_walk_watch[wi] = try std.fmt.parseInt(u24, one, 16);
            }
        } else if (std.mem.eql(u8, a, "--code-map")) {
            out.code_map = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--cov-out")) {
            out.cov_out = it.next() orelse return error.MissingValue;
            core.sa1gen.dbg_keep_cov = true;
        } else if (std.mem.eql(u8, a, "--mmio-stock")) {
            out.mmio_stock = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--mmio-out")) {
            out.mmio_out = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--mmio-ref")) {
            out.mmio_ref = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--apu-port-trace")) {
            out.apu_port_trace = true;
        } else if (std.mem.eql(u8, a, "--conv-overclock")) {
            out.conv_overclock = try std.fmt.parseInt(u8, it.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, a, "--lap-cell")) {
            out.lap_cell = try std.fmt.parseInt(u16, it.next() orelse return error.MissingValue, 16);
        } else if (std.mem.eql(u8, a, "--repoll")) {
            out.repoll = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--repoll-poweron")) {
            out.repoll_poweron = true;
        } else if (std.mem.eql(u8, a, "--srm")) {
            out.srm = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--movie-ignore-crc")) {
            out.movie_ignore_crc = true;
            core.console.dbg_ignore_state_rom_crc = true; // also let an anchored state cross builds

        } else if (std.mem.eql(u8, a, "--dump-ram")) {
            out.dump_ram = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--dump-srm")) {
            out.dump_srm = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--behavioral-probe")) {
            out.behavioral_probe = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--wg-sync")) {
            out.wg_sync = true;
        } else if (std.mem.eql(u8, a, "--wg-fastrom")) {
            out.wg_fastrom = true;
        } else if (std.mem.eql(u8, a, "--wg-drop")) {
            const v = it.next() orelse return error.MissingValue;
            if (out.n_wg_drop == out.wg_drop.len) return error.TooManyDrops;
            out.wg_drop[out.n_wg_drop] = try std.fmt.parseInt(u16, v, 16);
            out.n_wg_drop += 1;
        } else if (std.mem.eql(u8, a, "--wg-nmi-off")) {
            const v = it.next() orelse return error.MissingValue;
            if (out.n_wg_nmi_off == out.wg_nmi_off.len) return error.TooManyDrops;
            out.wg_nmi_off[out.n_wg_nmi_off] = try std.fmt.parseInt(u16, v, 16);
            out.n_wg_nmi_off += 1;
        } else if (std.mem.eql(u8, a, "--cover-image")) {
            if (out.n_cover == out.cover_image.len) return error.TooManyArgs;
            out.cover_image[out.n_cover] = it.next() orelse return error.MissingValue;
            out.n_cover += 1;
        } else if (std.mem.eql(u8, a, "--harvest-jobs")) {
            const v = it.next() orelse return error.MissingValue;
            out.harvest_jobs = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, a, "--verify-jobs")) {
            const v = it.next() orelse return error.MissingValue;
            out.verify_jobs = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, a, "--harvest-render")) {
            out.harvest_render = true;
        } else if (std.mem.eql(u8, a, "--harvest-cache")) {
            out.harvest_cache = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--baseline-cache")) {
            out.baseline_cache = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--cover-movie")) {
            // Fills the pair the last --cover-image opened.
            if (out.n_cover == 0) return error.MissingValue;
            out.cover_movie[out.n_cover - 1] = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--clock-pc")) {
            const v = it.next() orelse return error.MissingValue;
            core.wdc65816.dbg_clock_pc = try std.fmt.parseInt(u24, v, 16);
        } else if (std.mem.eql(u8, a, "--conv-pad")) {
            const v = it.next() orelse return error.MissingValue;
            root_mod.dbg_conv_pad = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, a, "--ev-only")) {
            root_mod.dbg_ev_only = true;
        } else if (std.mem.eql(u8, a, "--audit")) {
            root_mod.dbg_audit = true;
        } else if (std.mem.eql(u8, a, "--site-ev")) {
            const v = it.next() orelse return error.MissingValue;
            var pit = std.mem.splitScalar(u8, v, ',');
            while (pit.next()) |one| {
                if (root_mod.dbg_n_site_ev == root_mod.dbg_site_ev.len) break;
                root_mod.dbg_site_ev[root_mod.dbg_n_site_ev] = try std.fmt.parseInt(u24, one, 16);
                root_mod.dbg_n_site_ev += 1;
            }
        } else if (std.mem.eql(u8, a, "--trace-clk")) {
            const v = it.next() orelse return error.MissingValue;
            var pit = std.mem.splitScalar(u8, v, '-');
            core.wdc65816.dbg_trace_from = try std.fmt.parseInt(u64, pit.next().?, 10);
            core.wdc65816.dbg_trace_to = try std.fmt.parseInt(u64, pit.next().?, 10);
        } else if (std.mem.eql(u8, a, "--trace-sa1")) {
            const v = it.next() orelse return error.MissingValue;
            core.wdc65816.dbg_trace_sa1 = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, a, "--save-state-at")) {
            // "<frame>=<path>": replay to that frame, then write the machine.
            const v = it.next() orelse return error.MissingValue;
            const eq = std.mem.indexOfScalar(u8, v, '=') orelse return error.MissingValue;
            out.save_state_at = try std.fmt.parseInt(u32, v[0..eq], 10);
            out.save_state_path = v[eq + 1 ..];
        } else if (std.mem.eql(u8, a, "--dma-bank-pc")) {
            const v = it.next() orelse return error.MissingValue;
            core.wdc65816.dbg_dmabank = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, a, "--dma-trace")) {
            // "<max>" or "<max>:<from-clock>"
            const v = it.next() orelse return error.MissingValue;
            var pit = std.mem.splitScalar(u8, v, ':');
            core.dma.dbg_dma = try std.fmt.parseInt(usize, pit.next().?, 10);
            if (pit.next()) |fc| core.dma.dbg_dma_from = try std.fmt.parseInt(u64, fc, 10);
        } else if (std.mem.eql(u8, a, "--no-color-math")) {
            core.ppu.dbg_no_color_math = true;
        } else if (std.mem.eql(u8, a, "--bg-disable")) {
            const v = it.next() orelse return error.MissingValue;
            core.ppu.dbg_layer_disable = try std.fmt.parseInt(u8, v, 16);
        } else if (std.mem.eql(u8, a, "--hdma-disable")) {
            const v = it.next() orelse return error.MissingValue;
            core.dma.dbg_hdma_disable = try std.fmt.parseInt(u8, v, 16);
        } else if (std.mem.eql(u8, a, "--stale")) {
            // "<max-sites>" or "<max-sites>:<from-clock>"
            const v = it.next() orelse return error.MissingValue;
            var pit = std.mem.splitScalar(u8, v, ':');
            core.wdc65816.dbg_stale = try std.fmt.parseInt(usize, pit.next().?, 10);
            if (pit.next()) |f| core.wdc65816.dbg_stale_from = try std.fmt.parseInt(u64, f, 10);
        } else if (std.mem.eql(u8, a, "--iram-dump")) {
            out.iram_dump = true;
        } else if (std.mem.eql(u8, a, "--stale-ring")) {
            core.wdc65816.dbg_stale_ring = true;
        } else if (std.mem.eql(u8, a, "--watch-min")) {
            const v = it.next() orelse return error.MissingValue;
            core.wdc65816.dbg_watch_val_min = try std.fmt.parseInt(u8, v, 16);
        } else if (std.mem.eql(u8, a, "--watch-from")) {
            const v = it.next() orelse return error.MissingValue;
            core.wdc65816.dbg_watch_from = try std.fmt.parseInt(u64, v, 10);
        } else if (std.mem.eql(u8, a, "--watch")) {
            const v = it.next() orelse return error.MissingValue;
            var pit = std.mem.splitScalar(u8, v, '-');
            core.wdc65816.dbg_watch_lo = try std.fmt.parseInt(u16, pit.next().?, 16);
            core.wdc65816.dbg_watch_hi = if (pit.next()) |h| try std.fmt.parseInt(u16, h, 16) else core.wdc65816.dbg_watch_lo;
        } else if (std.mem.eql(u8, a, "--save-attempt")) {
            out.save_attempt = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--tick-dump")) {
            out.tick_dump = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--verify-behavioral")) {
            out.verify_behavioral = true;
        } else if (std.mem.eql(u8, a, "--gen-fastrom-patch")) {
            out.gen_fastrom = true;
        } else if (std.mem.eql(u8, a, "--gen-sa1-patch")) {
            out.gen_sa1 = true;
        } else if (std.mem.eql(u8, a, "--whole-game")) {
            out.whole_game = true;
        } else if (std.mem.eql(u8, a, "--window")) {
            // Window mode rides the whole-game pipeline (all-or-nothing,
            // no candidates, no plan) with execution left on the S-CPU.
            out.window = true;
            out.whole_game = true;
        } else if (std.mem.eql(u8, a, "--wg-add")) {
            const v = it.next() orelse return error.MissingValue;
            if (out.n_wg_add == out.wg_add.len) return error.TooManyAdds;
            out.wg_add[out.n_wg_add] = try std.fmt.parseInt(u24, v, 16);
            out.n_wg_add += 1;
        } else if (std.mem.eql(u8, a, "--wg-split")) {
            const v = it.next() orelse return error.MissingValue;
            out.wg_split_mainloop = try std.fmt.parseInt(u24, v, 16);
        } else if (std.mem.eql(u8, a, "--wg-split-tail")) {
            // "<tail>:<epilogue>:<dbr>" — the NMI-tail flavor.
            const v = it.next() orelse return error.MissingValue;
            var pit = std.mem.splitScalar(u8, v, ':');
            out.wg_split_tail = try std.fmt.parseInt(u16, pit.next().?, 16);
            out.wg_split_epi = try std.fmt.parseInt(u16, pit.next() orelse return error.MissingValue, 16);
            out.wg_split_dbr = try std.fmt.parseInt(u8, pit.next() orelse return error.MissingValue, 16);
        } else if (std.mem.eql(u8, a, "--split-scpu-set")) {
            out.split_scpu_set = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--wg-split-shared")) {
            const path = it.next() orelse return error.MissingValue;
            out.wg_split_shared = readScpuSet(init.io, gpa, path) catch return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--wg-split-mode")) {
            // "<cell>:<value>" (hex) — gameplay-mode gate: the tail goes
            // to the SA-1 only while dp <cell> holds <value>; menus and
            // transitions run nested-native (the stock shape).
            const v = it.next() orelse return error.MissingValue;
            var pit = std.mem.splitScalar(u8, v, ':');
            out.wg_split_mode_cell = try std.fmt.parseInt(u16, pit.next().?, 16);
            // "<cell>:<lo>[-<hi>]": a range takes the SA-1 through every mode in it
            const vals = pit.next() orelse return error.MissingValue;
            var rit = std.mem.splitScalar(u8, vals, '-');
            out.wg_split_mode_value = try std.fmt.parseInt(u8, rit.next().?, 16);
            if (rit.next()) |hi| out.wg_split_mode_hi = try std.fmt.parseInt(u8, hi, 16);
            out.wg_split_mode = true;
        } else if (std.mem.eql(u8, a, "--wg-split-io")) {
            // "<hex4>[:d][:l]" — d = deferred (handshake body, pump-only
            // post-engage), l = RTL-shaped (JSL-called).
            const v = it.next() orelse return error.MissingValue;
            if (out.n_wg_split_io == out.wg_split_io.len) return error.TooManyAdds;
            var pit = std.mem.splitScalar(u8, v, ':');
            var io: core.sa1gen.SplitIo = .{ .entry = try std.fmt.parseInt(u24, pit.next().?, 16) };
            while (pit.next()) |f| {
                if (std.mem.eql(u8, f, "d")) io.deferred = true;
                if (std.mem.eql(u8, f, "l")) io.rtl = true;
                if (std.mem.eql(u8, f, "f")) io.ff = true;
            }
            out.wg_split_io[out.n_wg_split_io] = io;
            out.n_wg_split_io += 1;
        } else if (std.mem.eql(u8, a, "--wg-split-vbl")) {
            const v = it.next() orelse return error.MissingValue;
            if (out.n_wg_split_vbl == out.wg_split_vbl.len) return error.TooManyAdds;
            var pit = std.mem.splitScalar(u8, v, '-');
            out.wg_split_vbl[out.n_wg_split_vbl] = .{
                try std.fmt.parseInt(u24, pit.next().?, 16),
                try std.fmt.parseInt(u24, pit.next() orelse return error.MissingValue, 16),
            };
            out.n_wg_split_vbl += 1;
        } else if (std.mem.eql(u8, a, "--wg-expand")) {
            // Accepts bytes, or "1m"/"2m" for whole megabytes.
            const v = it.next() orelse return error.MissingValue;
            const mb = v.len > 1 and (v[v.len - 1] == 'm' or v[v.len - 1] == 'M');
            const n = try std.fmt.parseInt(u32, if (mb) v[0 .. v.len - 1] else v, 10);
            out.wg_expand_to = if (mb) n * 1024 * 1024 else n;
            if (!std.math.isPowerOfTwo(out.wg_expand_to)) return error.BadExpandSize;
        } else if (std.mem.eql(u8, a, "--wg-copy-reserve")) {
            const v = it.next() orelse return error.MissingValue;
            out.wg_copy_reserve = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, a, "--wg-static")) {
            out.wg_static = true;
        } else if (std.mem.eql(u8, a, "--out")) {
            out.gen_out = it.next() orelse return error.MissingValue;
        } else if (rom == null) {
            rom = a;
        } else return error.TooManyArgs;
    }
    out.rom = rom orelse return error.NoRom;
    if (out.wide != 0) {
        if (out.accuracy == .accurate) return error.WideNeedsFast;
        if (out.wide > core.ppu.wide_margin_max) return error.WideTooBig;
    }
    if ((out.gen_fastrom or out.gen_sa1) and (out.patch != null or out.auto_patch or
        out.save_patched != null or out.auto_fastrom or
        out.accuracy == .accurate or out.wide != 0 or out.sa1_report))
        return error.GenConflicts;
    if (out.gen_fastrom and out.gen_sa1) return error.GenConflicts;
    if (out.whole_game and !out.gen_sa1) return error.GenConflicts;
    if (out.usage_map_out != null and !out.sa1_report) return error.UsageNeedsReport;
    if (out.call_graph_out != null and !out.sa1_report) return error.UsageNeedsReport;
    return out;
}
