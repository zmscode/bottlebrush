//! Test262 conformance runner — the project's speedometer.
//!
//! Phase 0 behaviour (see ../phase/phase-0/plan.md §4): walk a test directory,
//! parse each file's frontmatter, and classify. Since the lexer/parser/evaluator
//! don't exist yet, every test is classified SKIP (not FAIL) with a reason — so
//! the runner reports 0% pass with everything skipped. That is the Phase 0 goal:
//! a trustworthy speedometer, wired up and reporting, before any JS runs.
//!
//! Later phases replace the `classify` stub with real execution, and the number
//! climbs. Directory selection via CLI args is deferred (the 0.16 args API is in
//! flux); Phase 0 defaults to the bundled fixtures.

const std = @import("std");
const frontmatter = @import("frontmatter.zig");
const report = @import("report.zig");

const default_path = "test262/fixtures";
const max_file_bytes = std.Io.Limit.limited(64 * 1024 * 1024);

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    const path = default_path;

    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        std.debug.print("test262: cannot open '{s}': {s}\n", .{ path, @errorName(err) });
        std.debug.print("  (run from the project root; fixtures live in {s})\n", .{default_path});
        std.process.exit(1);
    };
    defer dir.close(io);

    var board: report.Scoreboard = .{};

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".js")) continue;
        // _FIXTURE.js files are module dependencies, not tests themselves.
        if (std.mem.endsWith(u8, entry.basename, "_FIXTURE.js")) continue;

        board.files += 1;

        const source = entry.dir.readFileAlloc(io, entry.basename, gpa, max_file_bytes) catch |err| {
            std.debug.print("  read error {s}: {s}\n", .{ entry.basename, @errorName(err) });
            board.record(.skip);
            continue;
        };
        defer gpa.free(source);

        var meta = frontmatter.parse(gpa, source) catch {
            board.record(.skip);
            continue;
        };
        defer meta.deinit(gpa);

        const outcome = classify(meta);
        board.record(outcome);
    }

    printReport(path, board);
}

/// Phase 0 classification: nothing can run yet, so everything skips. The switch
/// documents exactly which future phase unblocks each case.
fn classify(meta: frontmatter.Meta) report.Outcome {
    if (meta.negative) |neg| {
        switch (neg.phase) {
            // Parse-phase negatives need the Phase 1 lexer/parser.
            .parse => return .skip, // TODO(phase-1): parse and expect SyntaxError
            // Resolution/runtime negatives need Phase 2+ execution.
            .resolution, .runtime => return .skip, // TODO(phase-2)
        }
    }
    // Positive tests need the Phase 2 evaluator.
    return .skip; // TODO(phase-2): execute and check for no exception
}

fn printReport(path: []const u8, board: report.Scoreboard) void {
    std.debug.print(
        \\
        \\bottlebrush · Test262 conformance
        \\  path:    {s}
        \\  files:   {d}
        \\  pass:    {d}
        \\  fail:    {d}
        \\  skip:    {d}
        \\  ran:     {d}
        \\  PASS:    {d:.2}%
        \\
        \\
    , .{
        path,
        board.files,
        board.pass,
        board.fail,
        board.skip,
        board.ran(),
        board.passRate(),
    });

    // Machine-readable summary line for CI to capture/track over time.
    std.debug.print(
        "{{\"pass\":{d},\"fail\":{d},\"skip\":{d},\"files\":{d},\"pass_rate\":{d:.4}}}\n",
        .{ board.pass, board.fail, board.skip, board.files, board.passRate() },
    );
}
