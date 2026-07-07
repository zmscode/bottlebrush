//! CLI entry point for bottlebrush.
//!
//! Phase 2: the engine executes. This runs a demo program through the full
//! pipeline (parse → compile → interpret) and prints the result, proving the
//! bytecode VM works end to end. File/REPL input awaits the settling of the
//! Zig 0.16 args/IO APIs.

const std = @import("std");
const bb = @import("bottlebrush");

const demo =
    \\var nums = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14];
    \\var cubedEvens = nums
    \\  .filter(function (n) { return n % 2 === 0; })
    \\  .map(function (n) { return n * n * n; });
    \\var total = 0;
    \\cubedEvens.forEach(function (n) { total += n; });
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
