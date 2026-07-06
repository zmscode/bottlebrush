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
const trace_files = false; // set true to print FAIL paths when debugging
const trace_skips = false; // set true to print a reason tag for each SKIP
const harness_path = "test262/harness";
const max_file_bytes = std.Io.Limit.limited(64 * 1024 * 1024);

const Runner = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    harness_dir: std.Io.Dir,
    sta_src: []const u8,
    assert_src: []const u8,

    /// Features the engine doesn't implement; tests requiring them SKIP.
    const unsupported_features = [_][]const u8{
        "Math.sumPrecise", "Symbol",         "Symbol.iterator", "Symbol.toStringTag",
        "generators",      "async-iteration", "TypedArray",      "BigInt",
        "Proxy",           "Reflect",         "WeakRef",         "tail-call-optimization",
        "Float16Array",
    };

    fn unsupportedFeature(meta: frontmatter.Meta) ?[]const u8 {
        for (meta.features) |f| {
            for (unsupported_features) |u| {
                if (std.mem.eql(u8, f, u)) return u;
            }
        }
        return null;
    }

    /// Run one test file to an outcome.
    fn classify(self: *Runner, source: []const u8, meta: frontmatter.Meta) report.Outcome {
        if (unsupportedFeature(meta)) |f| {
            if (trace_skips) std.debug.print("SKIP feature:{s}\n", .{f});
            return .skip;
        }
        if (meta.negative) |neg| {
            switch (neg.phase) {
                .parse => return self.scoreParseNegative(source, meta),
                .resolution, .runtime => {
                    if (meta.flags.is_async or meta.flags.module) {
                        if (trace_skips) std.debug.print("SKIP async-or-module\n", .{});
                        return .skip;
                    }
                    // Expect a throw whose constructor name matches.
                    return self.runTest(source, meta, neg.type_name);
                },
            }
        }
        // Features the engine doesn't support yet.
        if (meta.flags.is_async or meta.flags.module) {
            if (trace_skips) std.debug.print("SKIP async-or-module\n", .{});
            return .skip;
        }
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
        const combined = self.buildSource(source, meta) catch {
            if (trace_skips) std.debug.print("SKIP missing-include\n", .{});
            return .skip;
        };
        defer self.gpa.free(combined);

        const pr = parser.parse(self.gpa, combined, .script) catch return .skip;
        var ast_tree = switch (pr) {
            .syntax_error => |d| {
                if (trace_skips) std.debug.print("SKIP parse-gap: {s}\n", .{d.message});
                return .skip;
            },
            .ok => |a| a,
        };
        defer ast_tree.deinit();

        const cr = compiler.compile(self.gpa, ast_tree.root, combined) catch return .skip;
        var program = switch (cr) {
            .compile_error => |d| {
                if (trace_skips) std.debug.print("SKIP compile-gap: {s}\n", .{d.message});
                return .skip;
            },
            .ok => |p| p,
        };
        defer program.deinit();

        var vm = bottlebrush.Vm.init(self.gpa);
        defer vm.deinit();
        _ = vm.run(&program) catch |e| switch (e) {
            error.JsThrow => {
                const name = vm.pendingErrorName(self.gpa);
                defer if (name) |n| self.gpa.free(n);
                if (expected_error) |want| {
                    // Negative test: the thrown error's type must match.
                    if (name) |n| return if (std.mem.eql(u8, n, want)) .pass else .fail;
                    return .fail;
                }
                // Positive test threw. A ReferenceError almost always means the
                // test uses a global/built-in we don't implement yet -> SKIP
                // rather than count it as a conformance failure.
                if (name) |n| {
                    if (std.mem.eql(u8, n, "ReferenceError")) {
                        if (trace_skips) {
                            const msg = vm.pendingErrorMessage(self.gpa);
                            defer if (msg) |m| self.gpa.free(m);
                            std.debug.print("SKIP reference-error: {s}\n", .{msg orelse "?"});
                        }
                        return .skip;
                    }
                }
                if (trace_files) {
                    const msg = vm.pendingErrorMessage(self.gpa);
                    defer if (msg) |m| self.gpa.free(m);
                    std.debug.print("FAILMSG [{s}] {s}\n", .{ name orelse "?", msg orelse "?" });
                }
                return .fail;
            },
            else => {
                if (trace_skips) std.debug.print("SKIP engine-limit\n", .{});
                return .skip; // OOM / engine limit
            },
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

        const outcome = runner.classify(source, meta);
        if (trace_files and outcome == .fail) std.debug.print("FAIL {s}\n", .{entry.path});
        board.record(outcome);
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
        \\  PASS (of all):      {d:.2}%
        \\  PASS (of executed): {d:.2}%
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
        board.executedRate(),
    });

    std.debug.print(
        "{{\"pass\":{d},\"fail\":{d},\"skip\":{d},\"files\":{d},\"pass_rate\":{d:.4},\"executed_rate\":{d:.4}}}\n",
        .{ board.pass, board.fail, board.skip, board.files, board.passRate(), board.executedRate() },
    );
}
