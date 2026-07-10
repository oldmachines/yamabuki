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
}
