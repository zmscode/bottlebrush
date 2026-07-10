//! Non-functional properties of the source itself, enforced as a test.
//!
//! Modelled on TigerBeetle's `src/tidy.zig`. The point is not the individual
//! rules — it is that every convention which *can* be checked mechanically is,
//! so that code review is free to discuss design instead of line length. A rule
//! that lives only in a reviewer's memory is a rule that is enforced sometimes.
//!
//!   zig build test-tidy
//!
//! Two kinds of check:
//!
//!   * **Bans** are hard. Each names a replacement, because a ban without one
//!     is a puzzle. Most encode Zig 0.16 std drift we have already tripped over
//!     once; the rest are project rules.
//!
//!   * **The long-line budget** is a ratchet. We have real debt here (849 lines
//!     over 100 columns), and reformatting it in one go would bury the history
//!     of every file. So the budget is per-file and exact: new code must fit,
//!     existing debt can only shrink, and paying some down forces you to update
//!     the table — which is how the number keeps going in one direction.

const std = @import("std");

/// Directories walked, relative to the project root.
const source_roots = [_][]const u8{ "src", "bilby/src", "test262" };

const Ban = struct {
    /// Matched as a plain substring, comments included: a banned construct
    /// named in a comment is usually a banned construct about to be written.
    pattern: []const u8,
    replacement: []const u8,
    /// Files that are allowed to contain it anyway.
    exempt: []const []const u8 = &.{},
};

const bans = [_]Ban{
    // Zig 0.16 std drift. Each of these compiled fine under 0.14/0.15 and each
    // cost us a debugging session, in one case a silently stale binary.
    .{ .pattern = "posix.getenv(", .replacement = "init.environ_map.get (removed in Zig 0.16)" },
    .{ .pattern = "GeneralPurposeAllocator", .replacement = "std.heap.DebugAllocator" },
    .{ .pattern = "refAllDeclsRecursive", .replacement = "explicit `_ = @import(\"x.zig\");`" },
    .{ .pattern = "ArrayListUnmanaged", .replacement = "std.ArrayList (already unmanaged in 0.16)" },
    .{ .pattern = "trimRight(", .replacement = "std.mem.trimEnd" },
    .{ .pattern = "trimLeft(", .replacement = "std.mem.trimStart" },
    .{ .pattern = "std.time.Timer", .replacement = "std.Io.Clock.now(.awake, io)" },
    .{ .pattern = "usingnamespace", .replacement = "explicit re-exports" },

    // Project rules.
    .{ .pattern = "Self = @This()", .replacement = "the type's real name" },
    // GC stress is a mode, reached through `GC_STRESS=1` or `--gc-stress`. A
    // hard-coded `= true` is a debug hack, and one shipped to main once.
    .{
        .pattern = "heap.stress = true",
        .replacement = "GC_STRESS=1 / --gc-stress",
        .exempt = &.{"src/tests/stress_tests.zig"},
    },
};

/// Allowed while iterating, never on main. A reminder is a promise to yourself
/// that this test collects on.
const reminders = [_][]const u8{ "FIXME", "TODO(now)", "// DEBUG" };

/// Lines over 100 columns, per file. Unlisted files must have none.
///
/// Exact: too many fails, and *too few* also fails, with the corrected table
/// printed. Paying debt down therefore has to be recorded, which is what keeps
/// this a ratchet rather than a rubber stamp.
const long_line_budget = [_]struct { []const u8, u32 }{
    .{ "bilby/src/main.zig", 2 },
    .{ "bilby/src/regex.zig", 27 },
    .{ "src/ast.zig", 1 },
    .{ "src/bytecode.zig", 5 },
    .{ "src/compiler.zig", 78 },
    .{ "src/interpreter.zig", 177 },
    .{ "src/lexer.zig", 2 },
    .{ "src/main.zig", 1 },
    .{ "src/parser.zig", 108 },
    .{ "src/runtime/builtins/array.zig", 18 },
    .{ "src/runtime/builtins/bigint.zig", 3 },
    .{ "src/runtime/builtins/collections.zig", 1 },
    .{ "src/runtime/builtins/date.zig", 10 },
    .{ "src/runtime/builtins/function.zig", 4 },
    .{ "src/runtime/builtins/global.zig", 4 },
    .{ "src/runtime/builtins/iterator.zig", 3 },
    .{ "src/runtime/builtins/json.zig", 9 },
    .{ "src/runtime/builtins/meta.zig", 10 },
    .{ "src/runtime/builtins/number.zig", 7 },
    .{ "src/runtime/builtins/object.zig", 65 },
    .{ "src/runtime/builtins/promise.zig", 12 },
    .{ "src/runtime/builtins/regexp.zig", 3 },
    .{ "src/runtime/builtins/string.zig", 25 },
    .{ "src/runtime/builtins/typedarray.zig", 20 },
    .{ "src/runtime/realm.zig", 39 },
    .{ "src/runtime/support.zig", 15 },
    .{ "src/tests/builtins_tests.zig", 137 },
    .{ "src/tests/core_tests.zig", 16 },
    .{ "src/tests/language_tests.zig", 33 },
    .{ "src/tests/stress_tests.zig", 1 },
    .{ "test262/frontmatter.zig", 1 },
    .{ "test262/runner.zig", 12 },
};

const max_columns = 100;
const max_file_bytes = std.Io.Limit.limited(4 * 1024 * 1024);

fn budgetFor(path: []const u8) u32 {
    for (long_line_budget) |entry| {
        if (std.mem.eql(u8, entry[0], path)) return entry[1];
    }
    return 0;
}

fn isExempt(ban: Ban, path: []const u8) bool {
    for (ban.exempt) |e| {
        if (std.mem.eql(u8, e, path)) return true;
    }
    return false;
}

/// A long line that is nothing but a URL cannot be wrapped. Anything else can.
fn isUnwrappableLink(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (std.mem.indexOf(u8, trimmed, "http://") == null and
        std.mem.indexOf(u8, trimmed, "https://") == null) return false;
    return std.mem.indexOfScalar(u8, trimmed, ' ') == null or
        std.mem.startsWith(u8, trimmed, "//") or std.mem.startsWith(u8, trimmed, "///");
}

const Finding = struct {
    path: []const u8,
    line: usize,
    message: []const u8,
};

test "tidy" {
    const gpa = std.testing.allocator;

    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    var failures: usize = 0;
    // Actual per-file long-line counts, so a shrunk budget can be reported.
    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    defer {
        var it = counts.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        counts.deinit(gpa);
    }

    for (source_roots) |root| {
        var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer dir.close(io);

        var walker = try dir.walk(gpa);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, entry.path });
            errdefer gpa.free(path);
            // `src/tidy.zig` names every banned construct; do not ban ourselves.
            if (std.mem.eql(u8, path, "src/tidy.zig")) {
                gpa.free(path);
                continue;
            }

            const text = try dir.readFileAlloc(io, entry.path, gpa, max_file_bytes);
            defer gpa.free(text);

            for (bans) |ban| {
                if (isExempt(ban, path)) continue;
                if (std.mem.indexOf(u8, text, ban.pattern) != null) {
                    std.debug.print("{s}: '{s}' is banned, use {s}\n", .{ path, ban.pattern, ban.replacement });
                    failures += 1;
                }
            }
            for (reminders) |reminder| {
                if (std.mem.indexOf(u8, text, reminder) != null) {
                    std.debug.print("{s}: '{s}' must be resolved before merging\n", .{ path, reminder });
                    failures += 1;
                }
            }

            var long: u32 = 0;
            var line_no: usize = 0;
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| {
                line_no += 1;
                if (std.mem.endsWith(u8, line, " ") or std.mem.endsWith(u8, line, "\t")) {
                    std.debug.print("{s}:{d}: trailing whitespace\n", .{ path, line_no });
                    failures += 1;
                }
                if (std.mem.indexOfScalar(u8, line, '\t') != null) {
                    std.debug.print("{s}:{d}: tab (indent with 4 spaces)\n", .{ path, line_no });
                    failures += 1;
                }
                if (std.mem.indexOfScalar(u8, line, '\r') != null) {
                    std.debug.print("{s}:{d}: carriage return\n", .{ path, line_no });
                    failures += 1;
                }
                if (line.len > max_columns and !isUnwrappableLink(line)) long += 1;
            }

            const budget = budgetFor(path);
            if (long > budget) {
                std.debug.print(
                    "{s}: {d} lines over {d} columns, budget is {d}. New code must fit.\n",
                    .{ path, long, max_columns, budget },
                );
                failures += 1;
            }
            try counts.put(gpa, path, long);
        }
    }

    // The budget must be exact, so that paying debt down is recorded.
    var stale = false;
    for (long_line_budget) |entry| {
        const actual = counts.get(entry[0]) orelse {
            std.debug.print("tidy: budget names '{s}', which no longer exists\n", .{entry[0]});
            stale = true;
            continue;
        };
        if (actual < entry[1]) {
            std.debug.print("tidy: '{s}' is down to {d} long lines (budget {d}) — tighten it\n", .{ entry[0], actual, entry[1] });
            stale = true;
        }
    }
    if (stale) {
        std.debug.print("\ntidy: the corrected budget is:\n", .{});
        var it = counts.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* > 0) std.debug.print("    .{{ \"{s}\", {d} }},\n", .{ e.key_ptr.*, e.value_ptr.* });
        }
        failures += 1;
    }

    if (failures > 0) {
        std.debug.print("\ntidy: {d} finding(s)\n", .{failures});
        return error.TidyFailed;
    }
}
