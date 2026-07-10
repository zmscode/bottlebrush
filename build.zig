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
    //   zig build test-tidy      source lint (bans, reminders, long-line budget)
    //   zig build test-fuzz      swarm fuzz the lexer/parser/compiler
    //   zig build test262         conformance suite
    //   zig build test262-stress  conformance under GC stress (root-tracing fuzzer)
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

    // ---- `test-fuzz`: swarm fuzzing of lexer/parser/compiler ----------------
    // The seed defaults to the current git commit, so every commit fuzzes with
    // a different, "random" seed, yet any failure reproduces from the seed the
    // test prints: `zig build test-fuzz -Dfuzz-seed=<n>`.
    const fuzz_runs = b.option(u32, "fuzz-runs", "Fuzz iterations per test (default 512)") orelse 512;
    const fuzz_seed = b.option(u64, "fuzz-seed", "Fuzz seed (default: current git commit)") orelse gitCommitSeed(b);

    const fuzz_options = b.addOptions();
    fuzz_options.addOption(u64, "seed", fuzz_seed);
    fuzz_options.addOption(u32, "runs", fuzz_runs);

    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/fuzz_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bottlebrush", .module = engine_mod },
                .{ .name = "fuzz_options", .module = fuzz_options.createModule() },
            },
        }),
    });
    const run_fuzz = b.addRunArtifact(fuzz_tests);
    const fuzz_step = b.step("test-fuzz", "Swarm-fuzz the lexer, parser and compiler");
    fuzz_step.dependOn(&run_fuzz.step);
    test_step.dependOn(&run_fuzz.step);

    // ---- `test-tidy`: non-functional properties of the source, as a test ----
    const tidy_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tidy.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tidy = b.addRunArtifact(tidy_tests);
    // `tidy` reads the source tree, so it must run from the project root.
    run_tidy.setCwd(b.path("."));
    run_tidy.has_side_effects = true; // re-run when sources change
    const tidy_step = b.step("test-tidy", "Lint the source: bans, reminders, long-line budget");
    tidy_step.dependOn(&run_tidy.step);
    test_step.dependOn(&run_tidy.step);

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

    // ---- `test262-stress`: the corpus as a root-tracing fuzzer ---------------
    // Collects at every allocation safe-point, so any value the VM holds across
    // an allocation without rooting it is swept immediately and the run dies at
    // the use. Dead cells are poisoned, making a stale reference deterministic
    // rather than dependent on what the allocator happens to recycle into the
    // slot. ~100x slower, so aim it at a slice:
    //   zig build test262-stress -- test262/fixtures/vendored/built-ins/Promise
    const run_stress262 = b.addRunArtifact(test262);
    run_stress262.step.dependOn(b.getInstallStep());
    run_stress262.setEnvironmentVariable("GC_STRESS", "1");
    if (b.args) |args| run_stress262.addArgs(args);
    const stress262_step = b.step("test262-stress", "Run Test262 under GC stress (slow; finds missed GC roots)");
    stress262_step.dependOn(&run_stress262.step);
}

/// The low 64 bits of the current commit hash, or 0 outside a git checkout.
/// Gives CI a fresh seed per commit while keeping every failure reproducible
/// from the commit alone.
fn gitCommitSeed(b: *std.Build) u64 {
    var code: u8 = undefined;
    const out = b.runAllowFail(&.{ "git", "rev-parse", "HEAD" }, &code, .ignore) catch return 0;
    const hash = std.mem.trim(u8, out, " \n\r");
    if (hash.len < 16) return 0;
    return std.fmt.parseInt(u64, hash[0..16], 16) catch 0;
}
