//! bilby CLI — `bilby <pattern> [flags] [subject]`.
//!
//! Matches `pattern` against `subject` (or, when `subject` is omitted, each line
//! read from stdin) and prints the match span plus capture groups. I/O goes
//! through the Zig 0.16 `std.Io` Reader/Writer that `main` is handed.

const std = @import("std");
const bilby = @import("bilby");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;
    defer w.flush() catch {};

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // argv[0]
    const pattern = args.next() orelse {
        try w.print("usage: bilby <pattern> [flags] [subject]\n", .{});
        return;
    };
    const flags = args.next() orelse "";
    const subject = args.next() orelse {
        try w.print("usage: bilby <pattern> [flags] <subject>\n", .{});
        return;
    };

    var re = bilby.Regex.compileUtf8(gpa, pattern, flags) catch |e| {
        try w.print("error: {s}\n", .{@errorName(e)});
        return;
    };
    defer re.deinit(gpa);

    try matchLine(gpa, w, &re, subject);
}

fn matchLine(gpa: std.mem.Allocator, w: *std.Io.Writer, re: *const bilby.Regex, line_utf8: []const u8) !void {
    const units = bilby.utf8ToUtf16(gpa, line_utf8) catch {
        try w.print("(invalid utf-8)\n", .{});
        return;
    };
    defer gpa.free(units);

    const m = re.find(gpa, units, 0) catch |e| {
        try w.print("error: {s}\n", .{@errorName(e)});
        return;
    } orelse {
        try w.print("no match: {s}\n", .{line_utf8});
        return;
    };
    defer m.deinit(gpa);

    const whole = m.groups[0].?;
    try w.print("match [{d}..{d}]: ", .{ whole.start, whole.end });
    try printSpan(gpa, w, units, whole);
    for (m.groups[1..], 1..) |g, i| {
        try w.print("  group {d} = ", .{i});
        if (g) |span| try printSpan(gpa, w, units, span) else try w.print("(unset)\n", .{});
    }
}

fn printSpan(gpa: std.mem.Allocator, w: *std.Io.Writer, units: []const u16, span: bilby.Span) !void {
    const slice = try bilby.utf16ToUtf8(gpa, units[span.start..span.end]);
    defer gpa.free(slice);
    try w.print("{s}\n", .{slice});
}
