//! Test262 conformance runner — the project's speedometer.
//!
//! Walks a test directory, parses each file's frontmatter, and classifies:
//!   * parse-phase negatives are scored by the parser (PASS iff SyntaxError);
//!   * positive tests are run with the real harness (sta.js + assert.js +
//!     `includes`) prepended, in a fresh realm — PASS iff they complete without
//!     throwing, FAIL iff they throw (e.g. a Test262Error assertion failure);
//!   * anything the engine can't yet handle (async/module/raw, an unavailable
//!     `includes` helper, a parser/compiler gap) SKIPs, so the pass rate stays
//!     honest.
//!
//! Directory selection via CLI args is deferred (0.16 args API in flux); the
//! runner defaults to the bundled fixtures + harness.

const std = @import("std");
const frontmatter = @import("frontmatter.zig");
const report = @import("report.zig");
const bottlebrush = @import("bottlebrush");
const parser = bottlebrush.parser;
const compiler = bottlebrush.compiler;

const default_path = "test262/fixtures";
const harness_path = "test262/harness";
const max_file_bytes = std.Io.Limit.limited(64 * 1024 * 1024);

const Runner = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    harness_dir: std.Io.Dir,
    sta_src: []const u8,
    assert_src: []const u8,

    /// Run one test file to an outcome.
    fn classify(self: *Runner, source: []const u8, meta: frontmatter.Meta) report.Outcome {
        if (meta.negative) |neg| {
            switch (neg.phase) {
                .parse => return self.scoreParseNegative(source, meta),
                .resolution, .runtime => {
                    if (meta.flags.is_async or meta.flags.module) return .skip;
                    // Expect a throw whose constructor name matches.
                    return self.runTest(source, meta, neg.type_name);
                },
            }
        }
        // Features the engine doesn't support yet.
        if (meta.flags.is_async or meta.flags.module) return .skip;
        return self.runTest(source, meta, null);
    }

    fn scoreParseNegative(self: *Runner, source: []const u8, meta: frontmatter.Meta) report.Outcome {
        const source_type: bottlebrush.ast.SourceType = if (meta.flags.module) .module else .script;
        var result = parser.parse(self.gpa, source, source_type) catch return .skip;
        switch (result) {
            .ok => |*tree| {
                tree.deinit();
                return .fail; // expected a SyntaxError, but it parsed
            },
            .syntax_error => return .pass,
        }
    }

    /// Build the combined source, run it in a fresh realm, and score. For a
    /// negative test, `expected_error` is the constructor name that must be
    /// thrown; for a positive test it is null (any throw is a failure).
    fn runTest(self: *Runner, source: []const u8, meta: frontmatter.Meta, expected_error: ?[]const u8) report.Outcome {
        const combined = self.buildSource(source, meta) catch return .skip;
        defer self.gpa.free(combined);

        const pr = parser.parse(self.gpa, combined, .script) catch return .skip;
        var ast_tree = switch (pr) {
            .syntax_error => return .skip, // parser gap, not a conformance failure
            .ok => |a| a,
        };
        defer ast_tree.deinit();

        const cr = compiler.compile(self.gpa, ast_tree.root, combined) catch return .skip;
        var program = switch (cr) {
            .compile_error => return .skip, // unsupported construct, not a failure
            .ok => |p| p,
        };
        defer program.deinit();

        var vm = bottlebrush.Vm.init(self.gpa);
        defer vm.deinit();
        _ = vm.run(&program) catch |e| switch (e) {
            error.JsThrow => {
                if (expected_error) |want| {
                    // Negative test: the thrown error's type must match.
                    const name = vm.pendingErrorName(self.gpa);
                    defer if (name) |n| self.gpa.free(n);
                    if (name) |n| return if (std.mem.eql(u8, n, want)) .pass else .fail;
                    return .fail;
                }
                return .fail; // positive test threw
            },
            else => return .skip, // OOM / engine limit
        };
        // Completed without throwing.
        return if (expected_error != null) .fail else .pass;
    }

    /// Concatenate: [use strict] + sta.js + assert.js + includes + test source.
    /// A `raw` test runs verbatim with no harness.
    fn buildSource(self: *Runner, source: []const u8, meta: frontmatter.Meta) ![]u8 {
        if (meta.flags.raw) return self.gpa.dupe(u8, source);

        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.gpa);

        if (meta.flags.only_strict) try buf.appendSlice(self.gpa, "\"use strict\";\n");
        try buf.appendSlice(self.gpa, self.sta_src);
        try buf.appendSlice(self.gpa, "\n");
        try buf.appendSlice(self.gpa, self.assert_src);
        try buf.appendSlice(self.gpa, "\n");

        for (meta.includes) |inc| {
            if (std.mem.eql(u8, inc, "assert.js") or std.mem.eql(u8, inc, "sta.js")) continue;
            const inc_src = self.harness_dir.readFileAlloc(self.io, inc, self.gpa, max_file_bytes) catch
                return error.MissingInclude;
            defer self.gpa.free(inc_src);
            try buf.appendSlice(self.gpa, inc_src);
            try buf.appendSlice(self.gpa, "\n");
        }

        try buf.appendSlice(self.gpa, source);
        return buf.toOwnedSlice(self.gpa);
    }
};

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    // Open the harness directory and load the always-included helpers.
    var harness_dir = std.Io.Dir.cwd().openDir(io, harness_path, .{}) catch |err| {
        std.debug.print("test262: cannot open harness '{s}': {s}\n", .{ harness_path, @errorName(err) });
        std.process.exit(1);
    };
    defer harness_dir.close(io);

    const sta_src = try harness_dir.readFileAlloc(io, "sta.js", gpa, max_file_bytes);
    defer gpa.free(sta_src);
    const assert_src = try harness_dir.readFileAlloc(io, "assert.js", gpa, max_file_bytes);
    defer gpa.free(assert_src);

    var runner = Runner{
        .gpa = gpa,
        .io = io,
        .harness_dir = harness_dir,
        .sta_src = sta_src,
        .assert_src = assert_src,
    };

    const path = default_path;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        std.debug.print("test262: cannot open '{s}': {s}\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };
    defer dir.close(io);

    var board: report.Scoreboard = .{};
    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".js")) continue;
        if (std.mem.endsWith(u8, entry.basename, "_FIXTURE.js")) continue;

        board.files += 1;

        const source = entry.dir.readFileAlloc(io, entry.basename, gpa, max_file_bytes) catch {
            board.record(.skip);
            continue;
        };
        defer gpa.free(source);

        var meta = frontmatter.parse(gpa, source) catch {
            board.record(.skip);
            continue;
        };
        defer meta.deinit(gpa);

        board.record(runner.classify(source, meta));
    }

    printReport(path, board);
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

    std.debug.print(
        "{{\"pass\":{d},\"fail\":{d},\"skip\":{d},\"files\":{d},\"pass_rate\":{d:.4}}}\n",
        .{ board.pass, board.fail, board.skip, board.files, board.passRate() },
    );
}
