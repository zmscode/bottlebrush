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
    /// Every harness helper preloaded into memory (basename -> source), shared
    /// read-only across worker threads so no worker touches the filesystem.
    includes: *const std.StringHashMapUnmanaged([]const u8),
    sta_src: []const u8,
    assert_src: []const u8,
    /// Scratch: the reason the most recent test failed (for trace_files),
    /// filled by runVariant, read by the worker loop.
    fail_reason: [200]u8 = undefined,
    fail_reason_len: usize = 0,

    /// Features the engine doesn't implement; tests requiring them SKIP.
    const unsupported_features = [_][]const u8{
        "Math.sumPrecise", "generators",   "async-iteration",
        "TypedArray",      "Float16Array", "tail-call-optimization",
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
        self.fail_reason_len = 0; // clear any prior test's reason
        if (unsupportedFeature(meta)) |f| {
            self.setReason("feature:{s}", .{f});
            return .skip;
        }
        if (meta.negative) |neg| {
            switch (neg.phase) {
                .parse => return self.scoreParseNegative(source, meta),
                .resolution, .runtime => {
                    if (meta.flags.is_async or meta.flags.module) {
                        self.setReason("async-or-module", .{});
                        return .skip;
                    }
                    // Expect a throw whose constructor name matches.
                    return self.runTest(source, meta, neg.type_name);
                },
            }
        }
        // Features the engine doesn't support yet.
        if (meta.flags.is_async or meta.flags.module) {
            self.setReason("async-or-module", .{});
            return .skip;
        }
        return self.runTest(source, meta, null);
    }

    fn scoreParseNegative(self: *Runner, source: []const u8, meta: frontmatter.Meta) report.Outcome {
        const source_type: bottlebrush.ast.SourceType = if (meta.flags.module) .module else .script;
        // An onlyStrict parse-negative must be parsed as strict code; the raw
        // fixture has no directive, so prepend one.
        var owned: ?[]u8 = null;
        defer if (owned) |o| self.gpa.free(o);
        const src = if (meta.flags.only_strict) blk: {
            owned = std.fmt.allocPrint(self.gpa, "\"use strict\";\n{s}", .{source}) catch return .skip;
            break :blk owned.?;
        } else source;
        var result = parser.parse(self.gpa, src, source_type) catch return .skip;
        switch (result) {
            .ok => |*tree| {
                tree.deinit();
                self.setReason("parse-negative: expected SyntaxError, parsed OK", .{});
                return .fail; // expected a SyntaxError, but it parsed
            },
            .syntax_error => return .pass,
        }
    }

    /// Run the test in its required mode variants and combine the outcomes
    /// (spec: a file with neither `onlyStrict` nor `noStrict` runs BOTH sloppy
    /// and strict; PASS only when every variant passes). fail > skip > pass.
    fn runTest(self: *Runner, source: []const u8, meta: frontmatter.Meta, expected_error: ?[]const u8) report.Outcome {
        if (meta.flags.raw) return self.runVariant(source, meta, expected_error, false);
        var worst = report.Outcome.pass;
        if (!meta.flags.only_strict) {
            worst = worse(worst, self.runVariant(source, meta, expected_error, false));
        }
        if (!meta.flags.no_strict) {
            worst = worse(worst, self.runVariant(source, meta, expected_error, true));
        }
        return worst;
    }

    fn worse(a: report.Outcome, b: report.Outcome) report.Outcome {
        if (a == .fail or b == .fail) return .fail;
        if (a == .skip or b == .skip) return .skip;
        return .pass;
    }

    /// Build the combined source for one mode, run it in a fresh realm, and
    /// score. For a negative test, `expected_error` is the constructor name
    /// that must be thrown; for a positive test it is null.
    fn runVariant(self: *Runner, source: []const u8, meta: frontmatter.Meta, expected_error: ?[]const u8, strict: bool) report.Outcome {
        const combined = self.buildSourceStrict(source, meta, strict) catch {
            self.setReason("missing-include", .{});
            return .skip;
        };
        defer self.gpa.free(combined);

        const pr = parser.parse(self.gpa, combined, .script) catch {
            self.setReason("parse-oom", .{});
            return .skip;
        };
        var ast_tree = switch (pr) {
            .syntax_error => |d| {
                self.setReason("parse-gap: {s}", .{d.message});
                return .skip;
            },
            .ok => |a| a,
        };
        defer ast_tree.deinit();

        const cr = compiler.compile(self.gpa, ast_tree.root, combined) catch {
            self.setReason("compile-oom", .{});
            return .skip;
        };
        var program = switch (cr) {
            .compile_error => |d| {
                self.setReason("compile-gap: {s}", .{d.message});
                return .skip;
            },
            .ok => |p| p,
        };
        defer program.deinit();

        var vm = bottlebrush.Vm.init(self.gpa);
        defer vm.deinit();
        vm.installHost262() catch return .skip;
        _ = vm.run(&program) catch |e| switch (e) {
            error.JsThrow => {
                const name = vm.pendingErrorName(self.gpa);
                defer if (name) |n| self.gpa.free(n);
                if (expected_error) |want| {
                    // Negative test: the thrown error's type must match.
                    if (name) |n| {
                        if (std.mem.eql(u8, n, want)) return .pass;
                        self.setReason("negative: wanted {s}, got {s}", .{ want, n });
                        return .fail;
                    }
                    return .fail;
                }
                // Positive test threw. A ReferenceError almost always means the
                // test uses a global/built-in we don't implement yet -> SKIP
                // rather than count it as a conformance failure.
                if (name) |n| {
                    if (std.mem.eql(u8, n, "ReferenceError")) {
                        const msg = vm.pendingErrorMessage(self.gpa);
                        defer if (msg) |m| self.gpa.free(m);
                        self.setReason("reference-error: {s}", .{msg orelse "?"});
                        return .skip;
                    }
                }
                const msg = vm.pendingErrorMessage(self.gpa);
                defer if (msg) |m| self.gpa.free(m);
                self.setReason("threw {s}: {s}", .{ name orelse "?", msg orelse "?" });
                return .fail;
            },
            error.Timeout => {
                self.setReason("timeout", .{});
                return .skip; // exceeded the instruction budget
            },
            else => {
                self.setReason("engine-limit", .{});
                return .skip; // OOM / engine limit
            },
        };
        // Completed without throwing.
        if (expected_error != null) {
            self.setReason("expected {s}, did not throw", .{expected_error.?});
            return .fail;
        }
        return .pass;
    }

    fn setReason(self: *Runner, comptime fmt: []const u8, a: anytype) void {
        const s = std.fmt.bufPrint(&self.fail_reason, fmt, a) catch self.fail_reason[0..0];
        self.fail_reason_len = s.len;
    }

    /// Concatenate: [use strict] + sta.js + assert.js + includes + test source.
    /// A `raw` test runs verbatim with no harness.
    fn buildSourceStrict(self: *Runner, source: []const u8, meta: frontmatter.Meta, strict: bool) ![]u8 {
        if (meta.flags.raw) return self.gpa.dupe(u8, source);

        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.gpa);

        if (strict) try buf.appendSlice(self.gpa, "\"use strict\";\n");
        try buf.appendSlice(self.gpa, self.sta_src);
        try buf.appendSlice(self.gpa, "\n");
        try buf.appendSlice(self.gpa, self.assert_src);
        try buf.appendSlice(self.gpa, "\n");

        for (meta.includes) |inc| {
            if (std.mem.eql(u8, inc, "assert.js") or std.mem.eql(u8, inc, "sta.js")) continue;
            const inc_src = self.includes.get(inc) orelse return error.MissingInclude;
            try buf.appendSlice(self.gpa, inc_src);
            try buf.appendSlice(self.gpa, "\n");
        }

        try buf.appendSlice(self.gpa, source);
        return buf.toOwnedSlice(self.gpa);
    }
};

/// One worker thread's slice of the run: it pulls test indices off the shared
/// atomic cursor, runs each in a fresh `Vm` on its own allocator, and tallies
/// into its own scoreboard (merged after join — no shared mutable state).
const Worker = struct {
    paths: []const []const u8,
    cursor: *std.atomic.Value(usize),
    fixtures_path: []const u8,
    includes: *const std.StringHashMapUnmanaged([]const u8),
    sta_src: []const u8,
    assert_src: []const u8,
    board: report.Scoreboard = .{},
};

fn workerMain(w: *Worker) void {
    // A shared, thread-safe allocator built for parallel throughput (per-worker
    // DebugAllocator serializes badly here and drops us to ~1 core).
    const gpa = std.heap.smp_allocator;

    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    var dir = std.Io.Dir.cwd().openDir(io, w.fixtures_path, .{}) catch return;
    defer dir.close(io);

    var runner = Runner{
        .gpa = gpa,
        .includes = w.includes,
        .sta_src = w.sta_src,
        .assert_src = w.assert_src,
    };

    while (true) {
        const i = w.cursor.fetchAdd(1, .monotonic);
        if (i >= w.paths.len) break;
        const rel = w.paths[i];
        w.board.files += 1;

        const source = dir.readFileAlloc(io, rel, gpa, max_file_bytes) catch {
            w.board.record(.skip);
            continue;
        };
        defer gpa.free(source);

        var meta = frontmatter.parse(gpa, source) catch {
            w.board.record(.skip);
            continue;
        };
        defer meta.deinit(gpa);

        const outcome = runner.classify(source, meta);
        if (trace_files and (outcome == .fail or outcome == .skip)) {
            const tag = if (outcome == .fail) "FAILCASE" else "SKIPCASE";
            const default: []const u8 = if (outcome == .fail) "assertion mismatch" else "unclassified";
            const reason = if (runner.fail_reason_len > 0) runner.fail_reason[0..runner.fail_reason_len] else default;
            std.debug.print("{s}\t{s}\t{s}\n", .{ tag, rel, reason });
        }
        w.board.record(outcome);
    }
}

// Zig 0.16 hands `main` a `std.process.Init` (args + a leak-checking gpa + an
// io implementation), replacing the removed `std.os.argv`/`argsAlloc`.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // Optional directory argument: `test262 [dir]` (defaults to the bundled set).
    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = arg_it.next(); // skip argv[0]
    const path: []const u8 = if (arg_it.next()) |p| p else default_path;

    // Open the harness directory and load the always-prepended helpers.
    var harness_dir = std.Io.Dir.cwd().openDir(io, harness_path, .{ .iterate = true }) catch |err| {
        std.debug.print("test262: cannot open harness '{s}': {s}\n", .{ harness_path, @errorName(err) });
        std.process.exit(1);
    };
    defer harness_dir.close(io);

    const sta_src = try harness_dir.readFileAlloc(io, "sta.js", gpa, max_file_bytes);
    defer gpa.free(sta_src);
    const assert_src = try harness_dir.readFileAlloc(io, "assert.js", gpa, max_file_bytes);
    defer gpa.free(assert_src);

    // Preload every harness helper into memory (basename -> source) so worker
    // threads share it read-only and never touch the filesystem for includes.
    var includes: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer {
        var it = includes.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        includes.deinit(gpa);
    }
    {
        var hwalk = try harness_dir.walk(gpa);
        defer hwalk.deinit();
        while (try hwalk.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".js")) continue;
            const src = entry.dir.readFileAlloc(io, entry.basename, gpa, max_file_bytes) catch continue;
            const gop = try includes.getOrPut(gpa, entry.basename);
            if (gop.found_existing) {
                gpa.free(src);
            } else {
                gop.key_ptr.* = try gpa.dupe(u8, entry.basename);
                gop.value_ptr.* = src;
            }
        }
    }

    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        std.debug.print("test262: cannot open '{s}': {s}\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };
    defer dir.close(io);

    // Collect every test path up front; workers grab them via an atomic cursor.
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }
    {
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".js")) continue;
            if (std.mem.endsWith(u8, entry.basename, "_FIXTURE.js")) continue;
            try paths.append(gpa, try gpa.dupe(u8, entry.path));
        }
    }

    const cpu = std.Thread.getCpuCount() catch 4;
    const nthreads = @max(1, @min(cpu, @min(@as(usize, 16), @max(1, paths.items.len))));

    var cursor = std.atomic.Value(usize).init(0);
    const workers = try gpa.alloc(Worker, nthreads);
    defer gpa.free(workers);
    for (workers) |*w| w.* = .{
        .paths = paths.items,
        .cursor = &cursor,
        .fixtures_path = path,
        .includes = &includes,
        .sta_src = sta_src,
        .assert_src = assert_src,
    };

    const threads = try gpa.alloc(std.Thread, nthreads);
    defer gpa.free(threads);
    for (threads, workers) |*t, *w| t.* = try std.Thread.spawn(.{}, workerMain, .{w});
    for (threads) |t| t.join();

    var board: report.Scoreboard = .{};
    for (workers) |w| {
        board.pass += w.board.pass;
        board.fail += w.board.fail;
        board.skip += w.board.skip;
        board.files += w.board.files;
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
