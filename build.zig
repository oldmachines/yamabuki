const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Renderer VRAM-traffic perf counter: off for every shipping build and
    // test (the increment folds away), on only for the bench so `bench --check`
    // has a deterministic memory-traffic metric to gate against.
    const perf_off = perfModule(b, false);
    const perf_on = perfModule(b, true);

    // The emulator core: pure Zig, no libc, no external dependencies.
    const core_mod = b.addModule("snes_core", .{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_mod.addImport("perf_options", perf_off);

    // Headless frontend: runs a ROM for N frames, dumps framebuffer as .ppm
    // and prints a hash. Primary development/verification tool.
    const headless = b.addExecutable(.{
        .name = "yamabuki-headless",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/frontends/headless/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "snes_core", .module = core_mod },
            },
        }),
    });
    b.installArtifact(headless);

    // libretro core: C-ABI shared library, zero external dependencies.
    const libretro = b.addLibrary(.{
        .name = "yamabuki_libretro",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/frontends/libretro/core.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "snes_core", .module = core_mod },
            },
        }),
    });
    b.installArtifact(libretro);

    // SDL3 desktop frontend. SDL is dlopen'd at runtime (the ABI subset is
    // hand-ported in src/frontends/sdl/sdl3.zig), so this builds everywhere
    // with no SDL headers or libraries present — it only needs libc for
    // dlopen/dlsym.
    const sdl_frontend = b.addExecutable(.{
        .name = "yamabuki-sdl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/frontends/sdl/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "snes_core", .module = core_mod },
            },
        }),
    });
    b.installArtifact(sdl_frontend);

    // Unit tests live inline in core modules.
    const core_tests = b.addTest(.{ .root_module = core_mod });
    const run_core_tests = b.addRunArtifact(core_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_core_tests.step);

    // The SDL frontend's shader pipeline: the preset parser, the pass geometry,
    // and the uniform encoding are pure logic and are tested on the host. They
    // are reached through preset.zig rather than main.zig, which needs a real
    // SDL and a real GPU.
    const shader_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/frontends/sdl/shader.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(shader_tests).step);

    // Bake the shader presets listed in shaders/presets.conf into GLSL.
    //
    // This runs glslang and SPIRV-Cross on the *build host* and emits plain
    // GLSL; nothing it produces is linked into the emulator. Needs
    // tools/fetch_shaders.sh and tools/build_shader_tools.sh to have run once.
    const bake = b.addSystemCommand(&.{ "python3", "tools/transpile_shaders.py" });
    bake.setCwd(b.path("."));
    if (b.args) |args| bake.addArgs(args);
    const shaders_step = b.step("shaders", "Bake slang shader presets into GLSL (needs shader-src/ and .shader-tools/)");
    shaders_step.dependOn(&bake.step);

    // SingleStepTests harness (65816 CPU vectors). Requires test-data/,
    // populated by tools/fetch_test_data.sh.
    const sst_filter = b.option([]const u8, "sst-filter", "Run only SST files whose name contains this substring (e.g. 'a9')");
    const sst_sample = b.option(u32, "sst-sample", "Max SST cases per opcode file (0 = all)") orelse 0;
    const sst_opts = b.addOptions();
    sst_opts.addOption(?[]const u8, "filter", sst_filter);
    sst_opts.addOption(u32, "sample", sst_sample);

    const sst_65816 = b.addExecutable(.{
        .name = "sst-65816",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sst_65816.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "snes_core", .module = core_mod },
                .{ .name = "sst_options", .module = sst_opts.createModule() },
            },
        }),
    });
    const run_sst = b.addRunArtifact(sst_65816);
    run_sst.setCwd(b.path("."));
    const sst_step = b.step("test-sst", "Run SingleStepTests 65816 vectors (needs test-data/)");
    sst_step.dependOn(&run_sst.step);

    // SingleStepTests harness for the SPC700 (APU CPU), same options.
    const sst_spc700 = b.addExecutable(.{
        .name = "sst-spc700",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sst_spc700.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "snes_core", .module = core_mod },
                .{ .name = "sst_options", .module = sst_opts.createModule() },
            },
        }),
    });
    const run_sst_spc = b.addRunArtifact(sst_spc700);
    run_sst_spc.setCwd(b.path("."));
    const sst_spc_step = b.step("test-sst-spc700", "Run SingleStepTests SPC700 vectors (needs test-data/)");
    sst_spc_step.dependOn(&run_sst_spc.step);

    // ROM runner: render PeterLemon ROMs and compare framebuffer hashes to the
    // committed golden values. Requires test-data/snes-roms.
    const rom_filter = b.option([]const u8, "rom-filter", "Run only ROMs whose path contains this substring");
    const rom_frames = b.option(u32, "rom-frames", "Frames per ROM (0 = use golden_hashes.zon default)") orelse 0;
    const rom_accurate = b.option(bool, "rom-accurate", "Run the golden ROMs on the accurate core") orelse false;
    const rom_opts = b.addOptions();
    rom_opts.addOption(?[]const u8, "filter", rom_filter);
    rom_opts.addOption(u32, "frames", rom_frames);
    rom_opts.addOption(bool, "accurate", rom_accurate);

    const rom_runner = b.addExecutable(.{
        .name = "rom-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/rom_runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "snes_core", .module = core_mod },
                .{ .name = "rom_options", .module = rom_opts.createModule() },
            },
        }),
    });
    const run_roms = b.addRunArtifact(rom_runner);
    run_roms.setCwd(b.path("."));
    const roms_step = b.step("test-roms", "Render PeterLemon ROMs and check golden hashes (needs test-data/)");
    roms_step.dependOn(&run_roms.step);

    // Deterministic fuzz harness: random register/memory streams rendered
    // under Debug safety checks, plus a save/load roundtrip invariant.
    const fuzz_iters = b.option(u32, "fuzz-iters", "Fuzz iterations per stage (0 = default)") orelse 0;
    const fuzz_seed = b.option(u64, "fuzz-seed", "Fuzz PRNG seed (fixed default keeps CI reproducible)") orelse 0x59414d41;
    const fuzz_opts = b.addOptions();
    fuzz_opts.addOption(u32, "iters", fuzz_iters);
    fuzz_opts.addOption(u64, "seed", fuzz_seed);

    const fuzz = b.addExecutable(.{
        .name = "yamabuki-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "snes_core", .module = core_mod },
                .{ .name = "fuzz_options", .module = fuzz_opts.createModule() },
            },
        }),
    });
    const run_fuzz = b.addRunArtifact(fuzz);
    const fuzz_step = b.step("fuzz", "Run the deterministic fuzz harness (PPU + console + save/load invariant)");
    fuzz_step.dependOn(&run_fuzz.step);

    // libretro harness: drives the core's exported retro_* entry points the
    // way a frontend would and checks them against the golden expectations.
    const libretro_runner = b.addExecutable(.{
        .name = "libretro-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/libretro_runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "snes_core", .module = core_mod },
                .{ .name = "libretro", .module = b.createModule(.{
                    .root_source_file = b.path("src/frontends/libretro/core.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "snes_core", .module = core_mod }},
                }) },
            },
        }),
    });
    const run_libretro = b.addRunArtifact(libretro_runner);
    run_libretro.setCwd(b.path("."));
    const libretro_step = b.step("test-libretro", "Drive the libretro core against golden ROMs (needs test-data/)");
    libretro_step.dependOn(&run_libretro.step);

    // Headless FPS benchmark. It gets its own core module built with the perf
    // counters enabled, so `bench --check` sees the VRAM-traffic counts while
    // shipping binaries (which share `core_mod`) stay free of the increment.
    const bench_core = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_core.addImport("perf_options", perf_on);
    const bench = b.addExecutable(.{
        .name = "yamabuki-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "snes_core", .module = bench_core },
                .{ .name = "perf_options", .module = perf_on },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    run_bench.setCwd(b.path("."));
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run the headless FPS benchmark (pass -- <rom> [--frames N])");
    bench_step.dependOn(&run_bench.step);

    // Deterministic perf-regression gate: run the committed baseline ROMs and
    // fail on any drift of steps/cycles/vram_reads (needs test-data/snes-roms).
    const run_bench_check = b.addRunArtifact(bench);
    run_bench_check.setCwd(b.path("."));
    run_bench_check.addArg("--check");
    const bench_check_step = b.step("bench-check", "Gate the deterministic bench baseline (needs test-data/)");
    bench_check_step.dependOn(&run_bench_check.step);
}

/// A one-field options module exposing `enabled: bool` as `@import("perf_options")`.
fn perfModule(b: *std.Build, enabled: bool) *std.Build.Module {
    const opts = b.addOptions();
    opts.addOption(bool, "enabled", enabled);
    return opts.createModule();
}
