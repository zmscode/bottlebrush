const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // bilby: the standalone regular-expression engine (sibling repo).
    const bilby_mod = b.dependency("bilby", .{ .target = target, .optimize = optimize }).module("bilby");

    // ---- shared bottlebrush engine module ------------------------------------
    const engine_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "bilby", .module = bilby_mod }},
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

    // ---- tests ----------------------------------------------------------------
    // Granular steps so a change can be verified without running everything:
    //   zig build test-unit      module inline unit tests (lexer/parser/compiler/vm)
    //   zig build test-core      e2e: core language
    //   zig build test-builtins  e2e: built-in library
    //   zig build test-lang      e2e: newer language features
    //   zig build test-stress    e2e under GC stress (the slow suite)
    //   zig build test-harness   test262 harness self-tests
    //   zig build test           everything above
    const test_step = b.step("test", "Run all test suites");

    const unit_tests = b.addTest(.{ .root_module = engine_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const unit_step = b.step("test-unit", "Run module inline unit tests");
    unit_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_unit_tests.step);

    const e2e_suites = [_]struct { file: []const u8, step: []const u8, desc: []const u8 }{
        .{ .file = "src/tests/core_tests.zig", .step = "test-core", .desc = "Run e2e core-language tests" },
        .{ .file = "src/tests/builtins_tests.zig", .step = "test-builtins", .desc = "Run e2e built-in library tests" },
        .{ .file = "src/tests/language_tests.zig", .step = "test-lang", .desc = "Run e2e language-feature tests" },
        .{ .file = "src/tests/stress_tests.zig", .step = "test-stress", .desc = "Run e2e GC-stress tests (slow)" },
    };
    for (e2e_suites) |suite| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(suite.file),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "bottlebrush", .module = engine_mod }},
            }),
        });
        const run_t = b.addRunArtifact(t);
        const step = b.step(suite.step, suite.desc);
        step.dependOn(&run_t.step);
        test_step.dependOn(&run_t.step);
    }

    const harness_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test262/harness_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_harness_tests = b.addRunArtifact(harness_tests);
    const harness_step = b.step("test-harness", "Run test262 harness self-tests");
    harness_step.dependOn(&run_harness_tests.step);
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
