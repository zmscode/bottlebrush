//! CLI entry point for bottlebrush.
//!
//! Phase 2: the engine executes. This runs a demo program through the full
//! pipeline (parse → compile → interpret) and prints the result, proving the
//! bytecode VM works end to end. File/REPL input awaits the settling of the
//! Zig 0.16 args/IO APIs.

const std = @import("std");
const bb = @import("bottlebrush");

const demo =
    \\function fib(n) { if (n < 2) return n; return fib(n - 1) + fib(n - 2); }
    \\var total = 0;
    \\for (var i = 0; i < 10; i++) total += fib(i);
    \\return total;
;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    std.debug.print("bottlebrush {s} — bytecode VM\n\ndemo program:\n{s}\n\n", .{ bb.version, demo });

    var pr = try bb.parser.parse(alloc, demo, .script);
    switch (pr) {
        .syntax_error => |d| {
            std.debug.print("syntax error: {s}\n", .{d.message});
            return;
        },
        .ok => |*a| {
            defer a.deinit();
            var cr = try bb.compiler.compile(alloc, a.root, demo);
            switch (cr) {
                .compile_error => |d| {
                    std.debug.print("compile error: {s}\n", .{d.message});
                    return;
                },
                .ok => |*program| {
                    defer program.deinit();
                    var vm = bb.Vm.init(alloc);
                    defer vm.deinit();
                    const result = vm.run(program) catch {
                        std.debug.print("uncaught exception\n", .{});
                        return;
                    };
                    if (result.isNumber()) {
                        std.debug.print("=> {d}\n", .{result.asNumber()});
                    } else {
                        std.debug.print("=> (result is {s})\n", .{@tagName(result)});
                    }
                },
            }
        },
    }
}
