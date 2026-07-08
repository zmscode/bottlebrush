//! Shared helpers for the end-to-end VM test suites: compile + run JS
//! snippets through the full pipeline (parser -> compiler -> interpreter).
//!
//! e2e suites run on `smp_allocator`: the leak-tracking testing allocator
//! made a fresh-realm-per-snippet suite take minutes (same lesson as the
//! test262 runner). Leak detection is still exercised by `zig build
//! test-unit` and the GC-stress suite.

const std = @import("std");
const testing = std.testing;

/// Allocator for e2e VM runs (fast; not leak-tracked).
pub const gpa = std.heap.smp_allocator;

const bottlebrush = @import("bottlebrush");
pub const Value = bottlebrush.Value;
pub const interpreter = bottlebrush.interpreter;
pub const Vm = bottlebrush.Vm;
pub const toBoolean = bottlebrush.support.toBoolean;
pub const utf16ToUtf8Alloc = bottlebrush.support.utf16ToUtf8Alloc;

/// Compile and run `source`; return the script's completion value.
pub fn eval(vm: *Vm, source: []const u8) !Value {
    const parser = bottlebrush.parser;
    const compiler = bottlebrush.compiler;
    var pr = try parser.parse(gpa, source, .script);
    switch (pr) {
        .syntax_error => return error.ParseFailed,
        .ok => |*a| {
            defer a.deinit();
            var cr = try compiler.compile(gpa, a.root, source);
            switch (cr) {
                .compile_error => return error.CompileFailed,
                .ok => |*program| {
                    defer program.deinit();
                    return vm.run(program);
                },
            }
        },
    }
}

pub fn evalNumber(source: []const u8) !f64 {
    var vm = Vm.init(gpa);
    defer vm.deinit();
    const v = try eval(&vm, source);
    try testing.expect(v.isNumber());
    return v.asNumber();
}
