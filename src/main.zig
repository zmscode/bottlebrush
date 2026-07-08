//! CLI entry point for bottlebrush.
//!
//! `bottlebrush file.js` runs a script; with no arguments it starts a REPL
//! (one persistent realm, line-at-a-time eval-print, `.exit` or EOF quits).

const std = @import("std");
const bb = @import("bottlebrush");

const max_file_bytes = std.Io.Limit.limited(64 * 1024 * 1024);

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = arg_it.next(); // argv[0]
    if (arg_it.next()) |path| {
        return runFile(gpa, io, path);
    }
    return repl(gpa, io);
}

/// Run one script file to completion, with real parse/compile diagnostics.
fn runFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, max_file_bytes) catch |err| {
        std.debug.print("bottlebrush: cannot read '{s}': {s}\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };
    defer gpa.free(source);

    var pr = try bb.parser.parse(gpa, source, .script);
    switch (pr) {
        .syntax_error => |d| {
            std.debug.print("SyntaxError: {s}\n", .{d.message});
            std.process.exit(1);
        },
        .ok => |*tree| {
            defer tree.deinit();
            var cr = try bb.compiler.compile(gpa, tree.root, source);
            switch (cr) {
                .compile_error => |d| {
                    std.debug.print("SyntaxError: {s}\n", .{d.message});
                    std.process.exit(1);
                },
                .ok => |*program| {
                    defer program.deinit();
                    var vm = bb.Vm.init(gpa);
                    defer vm.deinit();
                    _ = vm.run(program) catch |e| {
                        reportRunError(&vm, gpa, e);
                        std.process.exit(1);
                    };
                },
            }
        },
    }
}

/// Interactive loop: one persistent realm, results printed after each line.
fn repl(gpa: std.mem.Allocator, io: std.Io) !void {
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buf);
    const w = &out.interface;

    var in_buf: [64 * 1024]u8 = undefined;
    var in = std.Io.File.stdin().reader(io, &in_buf);
    const r = &in.interface;

    var vm = bb.Vm.init(gpa);
    defer vm.deinit();

    try w.print("bottlebrush {s} — .exit or Ctrl-D to quit\n", .{bb.version});
    while (true) {
        try w.writeAll("bb> ");
        try w.flush();
        const line = (r.takeDelimiter('\n') catch |e| switch (e) {
            error.StreamTooLong => {
                std.debug.print("bottlebrush: input line too long\n", .{});
                break;
            },
            else => return e,
        }) orelse break; // EOF
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, ".exit")) break;

        // evalSource keeps each compiled program alive for the VM's lifetime,
        // so closures defined on earlier lines keep working.
        const result = vm.evalSource(trimmed) catch |e| {
            reportRunError(&vm, gpa, e);
            continue;
        };
        try printValue(&vm, gpa, w, result);
    }
    try w.writeAll("\n");
    try w.flush();
}

fn printValue(vm: *bb.Vm, gpa: std.mem.Allocator, w: anytype, v: bb.Value) !void {
    const sv = vm.toStringVal(v) catch {
        try w.writeAll("<uninspectable>\n");
        try w.flush();
        return;
    };
    const utf8 = try bb.support.utf16ToUtf8Alloc(gpa, sv.asString().units);
    defer gpa.free(utf8);
    if (v.isString()) {
        try w.print("'{s}'\n", .{utf8});
    } else {
        try w.print("{s}\n", .{utf8});
    }
    try w.flush();
}

fn reportRunError(vm: *bb.Vm, gpa: std.mem.Allocator, e: anyerror) void {
    switch (e) {
        error.JsThrow => {
            const name = vm.pendingErrorName(gpa);
            defer if (name) |n| gpa.free(n);
            const msg = vm.pendingErrorMessage(gpa);
            defer if (msg) |m| gpa.free(m);
            std.debug.print("Uncaught {s}: {s}\n", .{ name orelse "Error", msg orelse "" });
            vm.pending_exception = null;
        },
        error.StackOverflow => std.debug.print("Uncaught RangeError: maximum call stack size exceeded\n", .{}),
        error.Timeout => std.debug.print("Uncaught RangeError: execution budget exceeded\n", .{}),
        else => std.debug.print("bottlebrush: internal error: {s}\n", .{@errorName(e)}),
    }
}
