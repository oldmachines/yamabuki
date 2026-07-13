//! Frame-budget profiler: how much of each frame the CPU actually spends
//! working, and how often the game misses its deadline.
//!
//! This is step one of the SA-1 candidacy analyser (M12). Before asking "which
//! routines would move to the SA-1", there is a cheaper question that kills most
//! candidates outright: **is the game CPU-bound at all?** A game that always
//! finishes its logic with time to spare gains nothing from a faster CPU, no
//! matter how attractive it looks from the outside.
//!
//! ## Why the obvious measurement does not work
//!
//! You cannot answer it by timing the CPU, because on a SNES the CPU burns
//! *exactly* the same number of master cycles every frame: the scheduler runs it
//! until the scanline's clock target, always (see `Console.runLineCpu`). There is
//! no such thing as the CPU "overrunning its budget" — it never gets to. When a
//! game is too slow, what actually happens is that its **main loop** fails to
//! come around before the next vblank, and a frame is dropped.
//!
//! So the budget has to be measured by its complement: not the time the CPU
//! spent working, but the time it spent **waiting**. Idle time is headroom, and
//! headroom is exactly what an SA-1 would be buying back.
//!
//! ## What waiting looks like
//!
//! Two forms. `WAI` halts the CPU until an interrupt and is unambiguous. The
//! other is a loop, and it is the whole difficulty, because a loop that is
//! *waiting* and a loop that is *working* look very much alike from outside:
//!
//!     wait:  LDA $10          wait:  LDA $4212        sum:  LDA $2000,y
//!            BEQ wait                BPL wait               ADC $04
//!                                                           INY
//!     $8166: JSL check                                      CPY #$1000
//!     $816A: BRA $8166                                      BNE sum
//!
//! The first three are waits. The fourth is a checksum, and it is tight,
//! repetitive, and writes nothing for four thousand iterations. The rule that
//! separates them has to be about *effect*, not shape:
//!
//! **A loop is a wait if it goes nowhere.** It touches a fixed handful of
//! addresses over and over, instead of reading and writing its way *through*
//! memory. The checksum's tell is that it **walks**: a different address every
//! pass, so the set of places it has touched grows without bound. A wait watches
//! the same one or two forever, because watching one spot for something else to
//! change it is what waiting *is*.
//!
//! Two refinements, each of which a game insisted on:
//!
//! - **The sets are kept per loop, not per pass.** A checksum reads exactly one
//!   address per iteration, precisely like a poll. The two are only
//!   distinguishable *across* iterations, where one address stays put and the
//!   other marches.
//!
//! - **A wait is allowed to write.** The classic SNES idiom stirs a random seed
//!   while it spins — that is how a game seeds randomness from how long you took
//!   to press Start — and Tetris & Dr. Mario's wait does exactly that (`JSR` to an
//!   LCG on `$9E`, then check the flag). A flat "a wait writes nothing" rule
//!   reported it as 100% busy on every frame. Writing one fixed word changes
//!   nothing that matters; writing your way through a buffer does. The one thing a
//!   wait may never do is poke a **hardware register** — that is what stops a loop
//!   kicking off DMA (`STA $420B`, the same address every pass) from slipping
//!   through the bounded-write test.
//!
//! Three more things had to be right before the rule could see anything at all:
//!
//! - **A loop is found by return, not by proximity.** The commonest SNES main
//!   loop is a *call* in a loop (`JSL check` / `BRA`, above — that is Contra
//!   III's), and its seven addresses are spread over 6 KiB. An earlier version
//!   bounded the *span* of the program counter, which rejects that outright along
//!   with every other subroutine-shaped wait; Contra III came out at 100%
//!   utilisation on every frame, title screen included.
//!
//! - **Stack traffic is not a side effect.** That same `JSL` pushes three bytes
//!   every pass, so a naive "writes nothing" test throws the loop out again. A
//!   JSL/RTL pair leaves the machine exactly as it found it. `Cpu.push8`/`pull8`
//!   therefore go straight to the bus and never register as data accesses.
//!
//! - **The unit of judgement is one pass, not one window.** A version that judged
//!   a whole window of instructions at once would let working code that happened
//!   to precede a wait — a memory clear, say — condemn the wait that followed it,
//!   because the window had seen a write. Super Mario World's idle time vanished
//!   entirely. A loop is judged on what *the loop* does.
//!
//! One rule is worth recording as a dead end, because it is plausible and wrong:
//! *"a wait cannot exit on its own, so a loop ended by an interrupt was waiting"*.
//! Both halves fail. A loop polling `$4212` exits under its own power the moment
//! the hardware sets the bit, no interrupt required — and *any* long-running loop
//! is eventually interrupted by the vblank NMI, checksums included, so the rule
//! did not even exclude the case it existed to exclude.
//!
//! ## What it still gets wrong
//!
//! A wait spread over more than `max_seen_pcs` addresses is counted as work, and
//! so is one that touches more than a handful of places. Both make the game look
//! *busier* than it is, so utilisation is an **upper bound**: real idle is at
//! least what is reported. That is the direction that flatters a conversion, which
//! is exactly why the report says so out loud instead of rounding in its own
//! favour.
//!
//! In the other direction, a *working* loop with a tiny memory footprint — a
//! multiply by repeated addition, say — reads as a wait. It cannot matter much:
//! such a loop is bounded by its own counter and runs a handful of times, where a
//! real wait spins for thousands of iterations, so the cycles at stake are orders
//! of magnitude apart.
//!
//! ## The independent check: lag frames
//!
//! Utilisation is a model, and models are worth exactly as much as their
//! assumptions. Lag is an observation, and it is what a player actually sees. A
//! game polls the controller once per main-loop iteration, so a frame in which
//! the game **never read the controller** is a frame in which its logic did not
//! come around — a dropped frame. (This is the definition TAS tools use.)
//!
//! It comes from a completely different signal than the idle accounting, so when
//! the two agree that is real corroboration, and when they disagree the report
//! shows both rather than quietly picking a winner.
//!
//! Its own blind spot: a game that reads the pad inside its **NMI handler** polls
//! every frame whatever its main loop is doing, so it can never register a lag
//! frame at all. Dropped frames are therefore a *lower* bound — the opposite bias
//! to utilisation, which is an upper bound. Between them the two errors bracket
//! the truth rather than compounding, which is the main reason for keeping both.

const std = @import("std");

/// How far back the profiler looks to notice that the CPU has come back to an
/// address it has already run — which is how a loop announces itself. The
/// address it returns to becomes the loop's *anchor*, and one pass from anchor
/// to anchor is one iteration.
///
/// A wait is not always a two-instruction spin. The commonest SNES main loop is
/// a *call* in a loop —
///
///     $8166:  JSL check      ; check: if (flag != $FF) return; ...do the frame
///     $816A:  BRA $8166
///
/// — which is Contra III's, and its seven addresses are spread over 6 KiB. An
/// earlier version of this profiler bounded the *span* of the program counter,
/// which rejects that outright and every other subroutine-shaped wait with it.
/// What characterises a loop is that it comes back, not that it stays put.
pub const max_seen_pcs: usize = 32;

/// A loop must complete this many consecutive iterations that change nothing
/// before its time counts as waiting. A loop the CPU passes through once or
/// twice on its way somewhere else is not waiting for anything.
pub const min_iters: u32 = 16;

/// The most distinct data addresses a loop may read — and, separately, write —
/// across all its passes, and still be a wait.
///
/// A poll watches one place (`$4212`, or a flag in WRAM — two addresses if it is
/// 16-bit, and some loops check a flag *and* a register). A loop that is
/// computing something reads and writes a different address every pass, so it
/// blows through any small bound at once. This is the test that tells a poll from
/// a walk, and it is applied to writes as well as reads because **a wait is
/// allowed to write**: the classic SNES idiom stirs a random seed while it spins,
/// which is how a game seeds randomness from how long you took to press Start.
/// Tetris & Dr. Mario's wait is exactly that —
///
///     $86ED:  JSR $8DAD      ; $9E = $9E * 5 + $7113   (advance the RNG)
///     $86F0:  LDA $0BA6      ; check the flag
///     $86F3:  BPL $86ED
///
/// — and a flat "a wait writes nothing" rule reported it as 100% busy on every
/// frame. Writing one fixed word is not doing anything; writing your way through
/// a buffer is.
pub const max_loop_reads: usize = 6;
pub const max_loop_writes: usize = 6;

/// Is `addr` a hardware register? *Reading* one in a loop is polling, which is
/// waiting. *Writing* one is not: a wait does not poke the hardware. This is what
/// keeps a loop that kicks off DMA (`STA $420B`) from slipping through the
/// bounded-write-set test — it writes the same address every pass, so nothing
/// else would catch it.
pub fn isMmio(addr: u24) bool {
    const bank: u8 = @truncate(addr >> 16);
    if ((bank & 0x7F) > 0x3F) return false; // not a system bank
    const a16: u16 = @truncate(addr);
    return (a16 >= 0x2100 and a16 <= 0x21FF) or (a16 >= 0x4200 and a16 <= 0x43FF);
}

/// An iteration longer than this is not the tight loop we are looking for: the
/// CPU has wandered off and the loop is over. Bounds how long it takes to notice
/// that a wait has ended, and so how much real work can be mistaken for one
/// (none: those instructions are banked as work — this only bounds the delay).
pub const max_iter_instrs: u32 = 128;

/// One frame's budget, sampled at the vblank boundary — the game's deadline.
pub const FrameSample = struct {
    frame: u64,
    /// Master cycles spent doing work: everything that is not waiting.
    work: u64,
    /// Master cycles spent waiting: `WAI`, or a loop that changed nothing.
    idle: u64,
    /// The game never read the controller this frame, so its main loop did not
    /// complete an iteration: a dropped frame, which the player sees as
    /// slowdown.
    lag: bool,

    /// Fraction of the frame spent working, 0..1. The headline number: a game
    /// that never approaches 1.0 is not a candidate for a faster CPU.
    pub fn utilisation(self: FrameSample) f64 {
        const total = self.work + self.idle;
        if (total == 0) return 0;
        return @as(f64, @floatFromInt(self.work)) / @as(f64, @floatFromInt(total));
    }
};

/// How many distinct loops the hot table can hold before it starts dropping.
pub const hot_slots: usize = 256;

/// One loop, identified by its anchor. A preview of step two of the analyser
/// ("which routines cost the frame") — but its first job was more basic than
/// that: when a game reports 100% utilisation, this is what tells you whether the
/// game is really pinned or whether the *classifier* is wrong. It is how the
/// Contra III bug above was found, so it has earned its keep.
pub const Hot = struct {
    pc: u32,
    cycles: u64,
    /// Passes it made, summed over every time it was entered.
    iters: u64,
    /// How many times the loop was entered and left.
    hits: u64,
    /// How it was classified the last time it ended.
    idle: bool,

    pub const empty: u32 = 0xFFFF_FFFF;
};

/// Accumulates the budget for the frame in progress.
///
/// The unit of judgement is **one loop iteration**, anchor to anchor — not a
/// window of instructions. That matters: an earlier version judged a whole window
/// at once, so a window that opened inside working code (and saw a write) and
/// then rolled on into the wait loop condemned the wait along with it, and Super
/// Mario World's idle time vanished. An iteration is the smallest thing that can
/// be said to have changed something or not.
///
/// Fixed-size and allocation-free: bounded state only, handing each finished
/// frame to the frontend, which owns the history.
pub const Profiler = struct {
    // --- finding the loop -----------------------------------------------------
    /// Addresses run since the last loop ended, for spotting a return.
    seen: [max_seen_pcs]u24,
    nseen: u8,
    /// The address the loop keeps coming back to. Null when not in a loop.
    anchor: ?u24,

    /// The addresses the loop itself runs at, learned over its first couple of
    /// passes and then fixed. Once they are known, an address outside them means
    /// the CPU has left the loop — which is how the end of a wait is spotted the
    /// instruction it happens, rather than 128 instructions later.
    loop_pcs: [max_seen_pcs]u24,
    n_loop_pcs: u8,
    iters_done: u32,

    // --- the iteration in progress --------------------------------------------
    iter_cycles: u64,
    iter_instrs: u32,
    /// Every cycle the loop has burned, pure or not — what `--hot` reports. Kept
    /// apart from `pure_cycles` so a loop that turns out to be *working* still
    /// shows up in the table. It has to: a loop the profiler has misjudged is
    /// exactly the one you need to see, and an earlier version recorded only the
    /// idle cycles, so a game stuck at 100% showed an empty table.
    loop_cycles: u64,

    // --- what the loop has done, over all its passes --------------------------
    /// The distinct addresses it has read and written, across every pass — *not*
    /// per pass. That distinction is the whole test. A checksum reads exactly one
    /// address per iteration, same as a poll; what gives it away is that the
    /// address is a different one every time, so the set grows and grows. A poll's
    /// set stays at one.
    loop_reads: [max_loop_reads]u24,
    n_loop_reads: u8,
    loop_read_overflow: bool,
    loop_writes: [max_loop_writes]u24,
    n_loop_writes: u8,
    loop_write_overflow: bool,
    /// It poked a hardware register: doing something, not waiting for something.
    loop_wrote_mmio: bool,

    // --- the run of unchanging iterations so far ------------------------------
    pure_iters: u32,
    pure_cycles: u64,

    // --- accumulators for the frame in progress -------------------------------
    work: u64,
    idle: u64,

    /// The frame just closed at a vblank boundary, waiting to be collected.
    pending: ?FrameSample,

    /// Cumulative per-loop totals for the whole run, for `--hot`.
    hot: [hot_slots]Hot,
    hot_dropped: u64,
    /// All cycles, bucketed by the 256-byte page of the PC that burned them.
    /// Unlike `hot`, this misses nothing — straight-line code included — so it is
    /// the backstop when the loop table does not add up to a whole frame.
    pages: [1 << 16]u64,

    pub const init: Profiler = .{
        .seen = @splat(0),
        .nseen = 0,
        .anchor = null,
        .loop_pcs = @splat(0),
        .n_loop_pcs = 0,
        .iters_done = 0,
        .iter_cycles = 0,
        .iter_instrs = 0,
        .loop_cycles = 0,
        .loop_reads = @splat(0),
        .n_loop_reads = 0,
        .loop_read_overflow = false,
        .loop_writes = @splat(0),
        .n_loop_writes = 0,
        .loop_write_overflow = false,
        .loop_wrote_mmio = false,
        .pure_iters = 0,
        .pure_cycles = 0,
        .work = 0,
        .idle = 0,
        .pending = null,
        .hot = @splat(.{ .pc = Hot.empty, .cycles = 0, .iters = 0, .hits = 0, .idle = false }),
        .hot_dropped = 0,
        .pages = @splat(0),
    };

    /// Account for one retired instruction.
    ///
    ///   pc      program counter (pbr:pc) at the instruction's first fetch
    ///   cycles  master cycles it consumed
    ///   waiting the CPU was halted in `WAI`/`STP` — no instruction really ran
    ///   read    the data address it read, if any (never a code fetch or a pull)
    ///   write   the data address it wrote, if any (never a push)
    pub fn step(
        self: *Profiler,
        pc: u24,
        cycles: u64,
        waiting: bool,
        read: ?u24,
        write: ?u24,
    ) void {
        self.pages[pc >> 8] += cycles;

        if (waiting) {
            // WAI: halted until an interrupt. Waiting, by construction.
            self.endLoop();
            self.idle += cycles;
            return;
        }

        if (self.anchor) |a| {
            if (pc == a) {
                self.retireIteration();
            } else if (!self.inLoop(pc)) {
                // An address the loop does not run at. While it is still being
                // learned (its first couple of passes), take this as part of it;
                // afterwards, it means the CPU has left, and the loop is over.
                if (self.iters_done >= 2 or self.n_loop_pcs == max_seen_pcs) {
                    self.endLoop();
                    self.work += cycles;
                    return;
                }
                self.loop_pcs[self.n_loop_pcs] = pc;
                self.n_loop_pcs += 1;
            } else if (self.iter_instrs >= max_iter_instrs) {
                // Backstop: a "loop" that never comes back to its anchor is not
                // one. (Rare — the address test above almost always fires first.)
                self.endLoop();
                self.work += cycles;
                return;
            }
        } else if (self.sawPc(pc)) {
            // It has come back. This is a loop, and `pc` is its anchor.
            self.startLoop(pc);
        } else {
            // Straight-line, as far as we can tell: work.
            self.notePc(pc);
            self.work += cycles;
            return;
        }

        self.iter_cycles += cycles;
        self.iter_instrs +|= 1;
        self.loop_cycles += cycles;
        if (read) |addr| self.noteRead(addr);
        if (write) |addr| self.noteWrite(addr);
    }

    fn startLoop(self: *Profiler, pc: u24) void {
        self.anchor = pc;
        self.loop_pcs[0] = pc;
        self.n_loop_pcs = 1;
        self.iters_done = 0;
        self.n_loop_reads = 0;
        self.loop_read_overflow = false;
        self.n_loop_writes = 0;
        self.loop_write_overflow = false;
        self.loop_wrote_mmio = false;
        self.pure_iters = 0;
        self.pure_cycles = 0;
        self.iter_cycles = 0;
        self.iter_instrs = 0;
        self.loop_cycles = 0;
    }

    /// One pass from anchor to anchor is over. Has the loop changed anything —
    /// in this pass or in any before it?
    fn retireIteration(self: *Profiler) void {
        self.iters_done +|= 1;
        if (self.loopIsPure()) {
            self.pure_iters +|= 1;
            self.pure_cycles += self.iter_cycles;
        } else {
            // The loop is doing something. Everything it has run is work —
            // including the earlier passes that happened to look innocent.
            self.work += self.pure_cycles + self.iter_cycles;
            self.pure_iters = 0;
            self.pure_cycles = 0;
        }
        self.iter_cycles = 0;
        self.iter_instrs = 0;
    }

    /// The loop (if there was one) has ended. Bank it.
    fn endLoop(self: *Profiler) void {
        if (self.anchor) |a| {
            const is_idle = self.pure_iters >= min_iters;
            if (is_idle) self.idle += self.pure_cycles else self.work += self.pure_cycles;
            self.recordHot(a, self.loop_cycles, is_idle);
        }
        // The partial pass that broke out of the loop is not part of it.
        self.work += self.iter_cycles;
        self.anchor = null;
        self.pure_iters = 0;
        self.pure_cycles = 0;
        self.iter_cycles = 0;
        self.iter_instrs = 0;
        self.loop_cycles = 0;
        self.nseen = 0;
    }

    fn inLoop(self: *const Profiler, pc: u24) bool {
        for (self.loop_pcs[0..self.n_loop_pcs]) |p| {
            if (p == pc) return true;
        }
        return false;
    }

    fn sawPc(self: *const Profiler, pc: u24) bool {
        for (self.seen[0..self.nseen]) |p| {
            if (p == pc) return true;
        }
        return false;
    }

    fn notePc(self: *Profiler, pc: u24) void {
        if (self.nseen == max_seen_pcs) {
            // Nothing has recurred in a long while; start looking again.
            self.nseen = 0;
        }
        self.seen[self.nseen] = pc;
        self.nseen += 1;
    }

    /// Has the loop, so far, changed nothing? It may watch a handful of places
    /// and stir a handful of its own, but it may not walk memory and it may not
    /// touch the hardware.
    fn loopIsPure(self: *const Profiler) bool {
        return !self.loop_read_overflow and !self.loop_write_overflow and !self.loop_wrote_mmio;
    }

    fn noteRead(self: *Profiler, addr: u24) void {
        for (self.loop_reads[0..self.n_loop_reads]) |r| {
            if (r == addr) return;
        }
        if (self.n_loop_reads == max_loop_reads) {
            self.loop_read_overflow = true;
            return;
        }
        self.loop_reads[self.n_loop_reads] = addr;
        self.n_loop_reads += 1;
    }

    fn noteWrite(self: *Profiler, addr: u24) void {
        if (isMmio(addr)) self.loop_wrote_mmio = true;
        for (self.loop_writes[0..self.n_loop_writes]) |w| {
            if (w == addr) return;
        }
        if (self.n_loop_writes == max_loop_writes) {
            self.loop_write_overflow = true;
            return;
        }
        self.loop_writes[self.n_loop_writes] = addr;
        self.n_loop_writes += 1;
    }

    /// Record a loop in the hot table (open addressing, drop when full).
    fn recordHot(self: *Profiler, pc: u24, cycles: u64, is_idle: bool) void {
        if (cycles == 0) return;
        var i: usize = (@as(usize, pc) *% 2654435761) % hot_slots;
        for (0..hot_slots) |_| {
            const e = &self.hot[i];
            if (e.pc == Hot.empty or e.pc == pc) {
                e.pc = pc;
                e.cycles += cycles;
                e.iters += self.pure_iters;
                e.hits += 1;
                e.idle = is_idle;
                return;
            }
            i = (i + 1) % hot_slots;
        }
        self.hot_dropped += cycles;
    }

    /// Close the frame at the start of vblank — the game's logic deadline, and
    /// the natural NMI-to-NMI window for its main loop.
    ///
    /// `polled`: the game read the controller during the frame just ending.
    pub fn endFrame(self: *Profiler, frame: u64, polled: bool) void {
        // A wait still running at the deadline is one the CPU is sitting in as
        // the frame runs out. Bank what it has accrued into the frame it accrued
        // it in, but leave the loop alone — it has not ended, and starting its
        // count again would throw away the fact that it is already a wait.
        if (self.pure_iters >= min_iters) {
            self.idle += self.pure_cycles;
            self.pure_cycles = 0;
        }
        self.pending = .{
            .frame = frame,
            .work = self.work,
            .idle = self.idle,
            .lag = !polled,
        };
        self.work = 0;
        self.idle = 0;
    }

    /// Collect the frame closed by the last `endFrame`, if any.
    pub fn take(self: *Profiler) ?FrameSample {
        defer self.pending = null;
        return self.pending;
    }
};
/// The answer to "is this game CPU-bound?", which is the only question step one
/// of the analyser is entitled to answer.
pub const Verdict = enum {
    /// Idles through most of every frame and never misses a deadline. A faster
    /// CPU has nothing to do here — whatever else is true, this is not a
    /// candidate.
    not_cpu_bound,
    /// Never misses a deadline, but has almost nothing left over. Not slow
    /// today; would be the first to break if anything were added to it.
    at_the_limit,
    /// Misses its deadline occasionally. Real, visible slowdown, in bursts.
    drops_frames,
    /// Misses its deadline routinely. This is what a conversion is *for*.
    cpu_bound,
    /// The game never read the controller — not once, in the whole capture. That
    /// is not slowdown, it is *no signal*: the game has not finished booting, or
    /// it is sitting on something that does not poll, or it has hung. Every frame
    /// looks like a dropped frame and none of them mean anything, so the honest
    /// answer is to refuse the question rather than report "CPU-BOUND" — which is
    /// what a naive lag count would say, and it would be a lie.
    no_signal,

    pub fn describe(self: Verdict) []const u8 {
        return switch (self) {
            .not_cpu_bound => "NOT CPU-BOUND",
            .at_the_limit => "AT THE LIMIT",
            .drops_frames => "DROPS FRAMES",
            .cpu_bound => "CPU-BOUND",
            .no_signal => "NO SIGNAL",
        };
    }
};

/// A run of frames, folded down. Nothing here is a guess: every field is either
/// counted or measured.
pub const Summary = struct {
    frames: u64,
    /// Every frame in which the game never polled the controller.
    lag_frames: u64,
    /// Lag in short runs: genuine frame-rate slowdown. This is the number the
    /// verdict is based on. See `stall_run_max`.
    slow_frames: u64,
    /// Lag in long unbroken runs: level loads, fades, cutscenes — the game
    /// deliberately not reading the pad while it does something else. The CPU is
    /// usually pinned during these, but they are not slowdown, and counting them
    /// as such is how you talk yourself into a conversion the game does not need.
    stall_frames: u64,
    /// How many such long runs there were.
    stalls: u32,
    /// The longest unbroken run of dropped frames, and where it started.
    longest_stall: u32,
    longest_stall_at: u64,
    mean_util: f64,
    median_util: f64,
    p95_util: f64,
    max_util: f64,
    verdict: Verdict,

    /// The fraction of frames lost to genuine slowdown — long stalls excluded.
    pub fn slowRatio(self: Summary) f64 {
        if (self.frames == 0) return 0;
        return @as(f64, @floatFromInt(self.slow_frames)) / @as(f64, @floatFromInt(self.frames));
    }

    pub fn lagRatio(self: Summary) f64 {
        if (self.frames == 0) return 0;
        return @as(f64, @floatFromInt(self.lag_frames)) / @as(f64, @floatFromInt(self.frames));
    }
};

/// Dropped frames in an unbroken run longer than this are a *stall*, not
/// slowdown. Slowdown is a game failing to keep up while it is still playing —
/// it drops one frame in two or one in three, so its runs are short. An unbroken
/// fifth of a second with no input poll is not a game running slowly, it is a
/// game doing something else: decompressing a level, running a fade, playing a
/// cutscene. Both pin the CPU. Only one of them is a reason to convert a game to
/// the SA-1, and telling them apart is the difference between a real finding and
/// a wild goose chase.
pub const stall_run_max: u32 = 12;

/// A game losing at least this fraction of its frames to slowdown is not merely
/// stuttering; it is running slowly, and that is what a conversion is for.
pub const cpu_bound_slow_ratio: f64 = 0.02;
/// A game whose 95th-percentile frame is this busy has no slack left, even if it
/// never actually misses.
pub const at_the_limit_util: f64 = 0.90;

/// Fold a run of frames into a verdict. `util_scratch` must be at least
/// `samples.len` long; it is used for the percentiles (the core does not
/// allocate, so the caller supplies the buffer).
pub fn summarise(samples: []const FrameSample, util_scratch: []f64) Summary {
    std.debug.assert(util_scratch.len >= samples.len);
    if (samples.len == 0) return .{
        .frames = 0,
        .lag_frames = 0,
        .slow_frames = 0,
        .stall_frames = 0,
        .stalls = 0,
        .longest_stall = 0,
        .longest_stall_at = 0,
        .mean_util = 0,
        .median_util = 0,
        .p95_util = 0,
        .max_util = 0,
        .verdict = .not_cpu_bound,
    };

    // Order-dependent statistics first, while the samples are still in frame
    // order: a run of dropped frames is a property of the sequence, not the set,
    // and its *length* is what says whether it was slowdown or a level load.
    var lag_frames: u64 = 0;
    var slow_frames: u64 = 0;
    var stall_frames: u64 = 0;
    var stalls: u32 = 0;
    var longest_stall: u32 = 0;
    var longest_stall_at: u64 = 0;
    var run: u32 = 0;
    var run_start: u64 = 0;
    var sum: f64 = 0;

    // Close a finished run of dropped frames, filing it as slowdown or a stall.
    const close = struct {
        fn f(
            r: u32,
            start: u64,
            slow: *u64,
            stall: *u64,
            n_stalls: *u32,
            longest: *u32,
            longest_at: *u64,
        ) void {
            if (r == 0) return;
            if (r > stall_run_max) {
                stall.* += r;
                n_stalls.* += 1;
            } else {
                slow.* += r;
            }
            if (r > longest.*) {
                longest.* = r;
                longest_at.* = start;
            }
        }
    }.f;

    for (samples, 0..) |s, i| {
        const u = s.utilisation();
        util_scratch[i] = u;
        sum += u;
        if (s.lag) {
            if (run == 0) run_start = s.frame;
            run += 1;
            lag_frames += 1;
        } else {
            close(run, run_start, &slow_frames, &stall_frames, &stalls, &longest_stall, &longest_stall_at);
            run = 0;
        }
    }
    // A run still open at the end of the capture is still a run.
    close(run, run_start, &slow_frames, &stall_frames, &stalls, &longest_stall, &longest_stall_at);

    const utils = util_scratch[0..samples.len];
    std.mem.sort(f64, utils, {}, std.sort.asc(f64));
    const n = utils.len;

    const slow_ratio = @as(f64, @floatFromInt(slow_frames)) / @as(f64, @floatFromInt(n));
    const p95 = percentile(utils, 95);

    return .{
        .frames = samples.len,
        .lag_frames = lag_frames,
        .slow_frames = slow_frames,
        .stall_frames = stall_frames,
        .stalls = stalls,
        .longest_stall = longest_stall,
        .longest_stall_at = longest_stall_at,
        .mean_util = sum / @as(f64, @floatFromInt(n)),
        .median_util = percentile(utils, 50),
        .p95_util = p95,
        .max_util = utils[n - 1],
        .verdict = if (lag_frames == samples.len)
            // It never polled the pad, so every frame counts as dropped and not
            // one of them means anything. Refuse the question.
            .no_signal
        else if (slow_ratio >= cpu_bound_slow_ratio)
            .cpu_bound
        else if (slow_frames > 0)
            .drops_frames
        else if (p95 >= at_the_limit_util)
            .at_the_limit
        else
            .not_cpu_bound,
    };
}

/// Nearest-rank percentile of an ascending-sorted slice.
fn percentile(sorted: []const f64, pct: u32) f64 {
    const rank = std.math.divCeil(usize, sorted.len * pct, 100) catch unreachable;
    return sorted[@min(sorted.len, @max(rank, 1)) - 1];
}

// --- tests -------------------------------------------------------------------

/// Drive a synthetic instruction trace through the profiler. Every instruction
/// is six master cycles, so the arithmetic in the assertions stays legible.
const Trace = struct {
    p: Profiler = .init,

    const cyc = 6;

    fn run(t: *Trace, pc: u24, read: ?u24, write: ?u24) void {
        t.p.step(pc, cyc, false, read, write);
    }

    /// `n` turns of a two-instruction loop polling one fixed address:
    ///     wait: LDA `addr` / BEQ wait
    fn poll(t: *Trace, base: u24, n: u32, addr: u24) void {
        for (0..n) |_| {
            t.run(base, addr, null);
            t.run(base + 3, null, null);
        }
    }

    /// `n` turns of a loop reading its way *through* memory from `from` — a
    /// checksum. Tight and repetitive and it writes nothing, exactly like a
    /// poll; the difference, and the only difference, is that it walks.
    fn walk(t: *Trace, base: u24, n: u32, from: u24) void {
        for (0..n) |i| {
            t.run(base, from + @as(u24, @intCast(i)), null);
            t.run(base + 3, null, null);
        }
    }

    /// `n` turns of a loop clearing memory from `to` onwards.
    fn clear(t: *Trace, base: u24, n: u32, to: u24) void {
        for (0..n) |i| {
            t.run(base, null, to + @as(u24, @intCast(i)));
            t.run(base + 3, null, null);
        }
    }

    /// Utilisation of the frame this trace produced — the number the tool
    /// actually reports, and what these tests assert on.
    ///
    /// They do not pin exact cycle counts, because two of them would be lies:
    /// a loop cannot be recognised until the CPU comes *back* to an address, so
    /// the first pass through it is always booked as work, and the pass that
    /// finally breaks out of it is booked as work too. Both are bounded and both
    /// are correct. What matters is the proportion.
    fn util(t: *Trace) f64 {
        return t.frame().utilisation();
    }

    /// Close the frame and collect it.
    fn frame(t: *Trace) FrameSample {
        t.p.endFrame(0, true);
        return t.p.take().?;
    }
};

/// Idle enough that no one would call the game CPU-bound.
fn expectIdle(u: f64) !void {
    try std.testing.expect(u < 0.05);
}

/// Busy enough that the CPU has nothing to spare.
fn expectBusy(u: f64) !void {
    try std.testing.expect(u > 0.95);
}

test "a spin on an NMI-set WRAM flag is idle" {
    var t: Trace = .{};
    t.poll(0x00_9000, 100, 0x00_0010);
    try expectIdle(t.util());
}

test "a spin polling HVBJOY is idle" {
    // Ended by the hardware setting a bit, not by an interrupt — nothing vectors
    // — and it is still unambiguously a wait.
    var t: Trace = .{};
    t.poll(0x00_9000, 100, 0x00_4212);
    try expectIdle(t.util());
}

test "a wait built around a subroutine call is idle" {
    // Contra III's actual main loop, and the case a program-counter *span* gets
    // wrong — these seven addresses are 6 KiB apart:
    //
    //     $8166: JSL $995a          $995a: REP #$20
    //     $816A: BRA $8166          $995c: LDA $52      <- watches one address
    //                               $995e: CMP #$00FF
    //                               $9961: BNE $9970
    //                               $9970: RTL
    //
    // The JSL/RTL stack traffic is invisible to the profiler by construction, so
    // what is left changes nothing at all.
    var t: Trace = .{};
    for (0..200) |_| {
        t.run(0x00_8166, null, null); // JSL
        t.run(0x00_995a, null, null); // REP
        t.run(0x00_995c, 0x00_0052, null); // LDA $52
        t.run(0x00_995e, null, null); // CMP
        t.run(0x00_9961, null, null); // BNE
        t.run(0x00_9970, null, null); // RTL
        t.run(0x00_816a, null, null); // BRA
    }
    try expectIdle(t.util());
}

test "WAI is idle" {
    var t: Trace = .{};
    t.p.step(0x00_9000, 600, true, null, null);
    const s = t.frame();
    try std.testing.expectEqual(@as(u64, 600), s.idle);
    try std.testing.expectEqual(@as(u64, 0), s.work);
}

test "a memory-clear loop is work, not idle" {
    // Tight and repetitive, and it writes its way *through* memory.
    var t: Trace = .{};
    t.clear(0x00_9000, 100, 0x7E_0000);
    try expectBusy(t.util());
}

test "a checksum loop is work, not idle" {
    // Writes nothing for a thousand iterations and never leaves two addresses of
    // code — indistinguishable from a wait, except that it walks memory instead
    // of watching one spot. That is the whole test.
    var t: Trace = .{};
    t.walk(0x00_9000, 1000, 0x7E_2000);
    try expectBusy(t.util());
}

test "a wait may stir a random seed while it spins" {
    // Tetris & Dr. Mario's wait, which a flat "a wait writes nothing" rule
    // reported as 100% busy on every frame:
    //
    //     $86ED: JSR $8DAD     $8DAD: LDA $9E / ASL / ASL / ADC $9E / ADC #$7113
    //     $86F0: LDA $0BA6            STA $9E / RTS
    //     $86F3: BPL $86ED
    //
    // It reads two places and writes one, all fixed. It is going nowhere.
    var t: Trace = .{};
    for (0..200) |_| {
        t.run(0x00_86ed, null, null); // JSR
        t.run(0x00_8daf, 0x00_009e, null); // LDA $9E
        t.run(0x00_8db4, 0x00_009e, null); // ADC $9E
        t.run(0x00_8dba, null, 0x00_009e); // STA $9E
        t.run(0x00_8dbe, null, null); // RTS
        t.run(0x00_86f0, 0x00_0ba6, null); // LDA $0BA6
        t.run(0x00_86f3, null, null); // BPL
    }
    try expectIdle(t.util());
}

test "a loop that pokes hardware is work, however fixed the address" {
    // A loop kicking off DMA writes $420B every pass — a one-element write set,
    // which the bounded-write test alone would wave through.
    var t: Trace = .{};
    for (0..200) |_| {
        t.run(0x00_9000, 0x00_0010, 0x00_420B);
        t.run(0x00_9003, null, null);
    }
    try expectBusy(t.util());
}

test "a wait may watch several places at once" {
    // A flag and a hardware register, far apart in the address space — how many
    // places it watches is what matters, not how far apart they are.
    var t: Trace = .{};
    for (0..100) |_| {
        t.run(0x00_9000, 0x00_0010, null); // LDA $10
        t.run(0x00_9002, 0x00_4212, null); // AND $4212
        t.run(0x00_9005, null, null); // BEQ
    }
    try expectIdle(t.util());
}

test "a loop watching a 16-bit flag is still a wait" {
    var t: Trace = .{};
    for (0..100) |i| {
        const a: u24 = if (i % 2 == 0) 0x00_0010 else 0x00_0011;
        t.run(0x00_9000, a, null);
        t.run(0x00_9003, null, null);
    }
    try expectIdle(t.util());
}

test "a long loop that changes nothing is still a wait" {
    // Length is not the test — effect is. Twenty-four instructions that write
    // nothing and read one register cannot be computing anything, whatever else
    // they are doing. (Beyond `max_seen_pcs` addresses the profiler stops calling
    // it a loop at all; a wait that big does not exist in practice.)
    var t: Trace = .{};
    for (0..100) |_| {
        for (0..24) |i| t.run(0x00_9000 + @as(u24, @intCast(i * 3)), 0x00_4212, null);
    }
    try expectIdle(t.util());
}

test "a loop reading more places than a wait ever needs is work" {
    var t: Trace = .{};
    for (0..200) |i| {
        // Cycles through max_loop_reads + 1 distinct addresses: too many to be
        // watching for something, few enough that an address-span test would let
        // it through.
        const a: u24 = 0x7E_2000 + @as(u24, @intCast(i % (max_loop_reads + 1)));
        t.run(0x00_9000, a, null);
        t.run(0x00_9003, null, null);
    }
    try expectBusy(t.util());
}

test "a loop too short to be a wait is work" {
    var t: Trace = .{};
    t.poll(0x00_9000, 4, 0x00_4212); // well under min_iters
    const s = t.frame();
    try std.testing.expectEqual(@as(u64, 0), s.idle);
}

test "straight-line code is work" {
    var t: Trace = .{};
    for (0..200) |i| t.run(0x00_9000 + @as(u24, @intCast(i * 3)), 0x00_4212, null);
    const s = t.frame();
    try std.testing.expectEqual(@as(u64, 0), s.idle);
}

test "work followed by a wait does not condemn the wait" {
    // The regression that killed the previous design. A window that opened inside
    // working code carried that code's writes forward into the wait loop that
    // followed, and Super Mario World's idle time went from 56% to nothing. An
    // iteration is the unit of judgement precisely so this cannot happen.
    var t: Trace = .{};
    t.clear(0x00_8000, 60, 0x7E_0000); // a memory clear: unambiguously work
    t.poll(0x00_9000, 300, 0x00_0010); // then park on a flag
    const s = t.frame();
    try std.testing.expect(s.idle > 0);
    try std.testing.expect(s.utilisation() < 0.25); // the clear is ~1/6 of it
}

test "a wait that straddles the frame boundary is idle on both sides" {
    var t: Trace = .{};
    t.poll(0x00_9000, 100, 0x00_0010);
    t.p.endFrame(7, true);
    const s = t.p.take().?;
    try std.testing.expectEqual(@as(u64, 7), s.frame);
    try expectIdle(s.utilisation());

    // The loop survives the boundary: the spin on the far side is still
    // recognised, rather than having to earn its `min_iters` all over again.
    t.poll(0x00_9000, 100, 0x00_0010);
    const s2 = t.frame();
    try std.testing.expect(s2.idle > 0);
    try expectIdle(s2.utilisation());
}

test "utilisation and lag" {
    var p: Profiler = .init;
    p.work = 300_000;
    p.idle = 57_368;
    p.endFrame(1, false);
    const s = p.take().?;
    try std.testing.expect(s.lag); // never polled the controller
    try std.testing.expectApproxEqAbs(@as(f64, 0.8395), s.utilisation(), 0.001);
    try std.testing.expect(p.take() == null); // collected exactly once
}

test "an idle frame is near-zero utilisation" {
    var t: Trace = .{};
    t.poll(0x00_9000, 1000, 0x00_4212);
    const s = t.frame();
    try std.testing.expect(s.utilisation() < 0.01);
}

/// `n` frames at a fixed utilisation, dropping every `lag_every`-th (0 = never).
fn frames(buf: []FrameSample, util: f64, lag_every: usize) []FrameSample {
    const total: u64 = 357_368; // one NTSC frame in master cycles
    for (buf, 0..) |*s, i| {
        const work: u64 = @intFromFloat(util * @as(f64, @floatFromInt(total)));
        s.* = .{
            .frame = i,
            .work = work,
            .idle = total - work,
            .lag = lag_every != 0 and i % lag_every == 0,
        };
    }
    return buf;
}

test "a game that idles half of every frame is not a candidate" {
    var buf: [600]FrameSample = undefined;
    var scratch: [600]f64 = undefined;
    const s = summarise(frames(&buf, 0.5, 0), &scratch);
    try std.testing.expectEqual(Verdict.not_cpu_bound, s.verdict);
    try std.testing.expectEqual(@as(u64, 0), s.lag_frames);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), s.mean_util, 0.01);
}

test "a game that never drops a frame but has no slack is at the limit" {
    // The case worth separating out: nothing is wrong with it *today*, and it
    // would still be the first thing to break.
    var buf: [600]FrameSample = undefined;
    var scratch: [600]f64 = undefined;
    const s = summarise(frames(&buf, 0.97, 0), &scratch);
    try std.testing.expectEqual(Verdict.at_the_limit, s.verdict);
    try std.testing.expectEqual(@as(u64, 0), s.lag_frames);
}

test "a game dropping frames routinely is cpu-bound" {
    // Every fourth frame: short runs, spread right through the capture. This is
    // what slowdown looks like.
    var buf: [600]FrameSample = undefined;
    var scratch: [600]f64 = undefined;
    const s = summarise(frames(&buf, 1.0, 4), &scratch);
    try std.testing.expectEqual(Verdict.cpu_bound, s.verdict);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), s.slowRatio(), 0.01);
    try std.testing.expectEqual(@as(u64, 0), s.stall_frames);
}

test "an occasional drop is not the same as being cpu-bound" {
    var buf: [1000]FrameSample = undefined;
    var scratch: [1000]f64 = undefined;
    const s = summarise(frames(&buf, 0.6, 500), &scratch); // 0.2% of frames
    try std.testing.expectEqual(Verdict.drops_frames, s.verdict);
}

test "a level load is a stall, not slowdown" {
    // The case that made this distinction necessary. Super Mario World's attract
    // demo drops 66 frames in 1800 — 3.7%, comfortably over the CPU-bound
    // threshold — but 57 of them are one unbroken run, which is a level
    // transition, not the game failing to keep up. Counting that as slowdown
    // recommends a conversion the game does not need.
    var buf: [1800]FrameSample = undefined;
    var scratch: [1800]f64 = undefined;
    _ = frames(&buf, 0.46, 0);
    for (buf[1562..1619]) |*s| s.lag = true; // one 57-frame run
    const s = summarise(&buf, &scratch);

    try std.testing.expectEqual(@as(u64, 57), s.lag_frames);
    try std.testing.expectEqual(@as(u64, 57), s.stall_frames);
    try std.testing.expectEqual(@as(u64, 0), s.slow_frames);
    try std.testing.expectEqual(@as(u32, 1), s.stalls);
    try std.testing.expectEqual(@as(u32, 57), s.longest_stall);
    // 3.2% of frames dropped, and still correctly not called CPU-bound.
    try std.testing.expect(s.lagRatio() > cpu_bound_slow_ratio);
    try std.testing.expectEqual(Verdict.not_cpu_bound, s.verdict);
}

test "slowdown and a stall in the same capture are counted apart" {
    var buf: [1000]FrameSample = undefined;
    var scratch: [1000]f64 = undefined;
    _ = frames(&buf, 0.8, 0);
    for (buf[100..140]) |*s| s.lag = true; // a 40-frame load
    var i: usize = 500;
    while (i < 600) : (i += 2) buf[i].lag = true; // and real slowdown, 1 in 2
    const s = summarise(&buf, &scratch);
    try std.testing.expectEqual(@as(u64, 40), s.stall_frames);
    try std.testing.expectEqual(@as(u32, 1), s.stalls);
    try std.testing.expectEqual(@as(u64, 50), s.slow_frames);
    try std.testing.expectEqual(Verdict.cpu_bound, s.verdict); // 5% > 2%
}

test "the worst stall is found in frame order, not in the sorted set" {
    var buf: [100]FrameSample = undefined;
    var scratch: [100]f64 = undefined;
    _ = frames(&buf, 0.5, 0);
    // A single seven-frame run: what the player actually notices, and what an
    // average over a hundred frames would completely hide.
    for (buf[40..47]) |*s| s.lag = true;
    const s = summarise(&buf, &scratch);
    try std.testing.expectEqual(@as(u32, 7), s.longest_stall);
    try std.testing.expectEqual(@as(u64, 40), s.longest_stall_at);
    try std.testing.expectEqual(@as(u64, 7), s.lag_frames);
    // Seven is short enough to be slowdown, not a load.
    try std.testing.expectEqual(@as(u64, 7), s.slow_frames);
}

test "a run still open at the end of the capture is still counted" {
    var buf: [100]FrameSample = undefined;
    var scratch: [100]f64 = undefined;
    _ = frames(&buf, 0.5, 0);
    for (buf[80..100]) |*s| s.lag = true; // runs off the end
    const s = summarise(&buf, &scratch);
    try std.testing.expectEqual(@as(u32, 20), s.longest_stall);
    try std.testing.expectEqual(@as(u64, 20), s.stall_frames);
}

test "a game that never polls the pad gets no verdict, not a wrong one" {
    // Every frame is a lag frame, which a naive count would call CPU-bound in the
    // strongest possible terms. It means the opposite: the game is not running.
    var buf: [600]FrameSample = undefined;
    var scratch: [600]f64 = undefined;
    _ = frames(&buf, 0.2, 1); // every frame dropped, and the CPU barely busy
    const s = summarise(&buf, &scratch);
    try std.testing.expectEqual(Verdict.no_signal, s.verdict);
    try std.testing.expectEqual(@as(u64, 600), s.lag_frames);
}

test "summarising nothing does not divide by zero" {
    var scratch: [1]f64 = undefined;
    const s = summarise(&.{}, &scratch);
    try std.testing.expectEqual(@as(u64, 0), s.frames);
    try std.testing.expectEqual(@as(f64, 0), s.lagRatio());
}

test "percentiles" {
    var v: [100]f64 = undefined;
    for (&v, 0..) |*x, i| x.* = @floatFromInt(i);
    try std.testing.expectEqual(@as(f64, 49), percentile(&v, 50));
    try std.testing.expectEqual(@as(f64, 94), percentile(&v, 95));
    try std.testing.expectEqual(@as(f64, 99), percentile(&v, 100));
    try std.testing.expectEqual(@as(f64, 0), percentile(v[0..1], 95));
}
