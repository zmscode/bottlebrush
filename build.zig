const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- shared bottlebrush engine module ------------------------------------
    const engine_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- `bottlebrush` executable: REPL / file runner ------------------------
    const exe = b.addExecutable(.{
        .name = "bottlebrush",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = "bottlebrush",
                .module = engine_mod,
            }},
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the engine (file arg or REPL)");
    run_step.dependOn(&run_cmd.step);

    // ---- `test`: unit tests (engine + harness) -------------------------------
    const unit_tests = b.addTest(.{ .root_module = engine_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const harness_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test262/harness_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_harness_tests = b.addRunArtifact(harness_tests);
    test_step.dependOn(&run_harness_tests.step);

    // ---- `test262`: conformance runner (the speedometer) ---------------------
    const test262 = b.addExecutable(.{
        .name = "test262",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test262/runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = "bottlebrush",
                .module = engine_mod,
            }},
        }),
    });

    b.installArtifact(test262);

    const run_test262 = b.addRunArtifact(test262);
    run_test262.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_test262.addArgs(args);
    }
    const test262_step = b.step("test262", "Run the Test262 conformance suite");
    test262_step.dependOn(&run_test262.step);
}
