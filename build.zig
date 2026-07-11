const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The emulator core: pure Zig, no libc, no external dependencies.
    const core_mod = b.addModule("snes_core", .{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
    });

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

    // SDL3 desktop frontend (M7). Lazy: absence of the dependency never
    // breaks `zig build`.
    const enable_sdl = b.option(bool, "sdl", "Build the SDL3 desktop frontend") orelse false;
    if (enable_sdl) {
        std.debug.print("error: the SDL frontend is not implemented yet (milestone M7)\n", .{});
        std.process.exit(1);
    }

    // Unit tests live inline in core modules.
    const core_tests = b.addTest(.{ .root_module = core_mod });
    const run_core_tests = b.addRunArtifact(core_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_core_tests.step);

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
    const rom_opts = b.addOptions();
    rom_opts.addOption(?[]const u8, "filter", rom_filter);
    rom_opts.addOption(u32, "frames", rom_frames);

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

    // Headless FPS benchmark.
    const bench = b.addExecutable(.{
        .name = "yamabuki-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "snes_core", .module = core_mod },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    run_bench.setCwd(b.path("."));
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run the headless FPS benchmark (pass -- <rom> [--frames N])");
    bench_step.dependOn(&run_bench.step);
}
