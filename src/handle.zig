//! Rooting for native code (see ../phase/phase-0/plan.md §3).
//!
//! The rule, established here so every later phase inherits it:
//!   *Native/built-in code must not hold a raw cell pointer across an
//!    allocation. Root the value in a `HandleScope` first.*
//!
//! A `HandleScope` is a stack of `Value` roots. The heap's `collect` marks
//! through any object exposing `markRoots(*Tracer)`, which `HandleScope` does.
//! In Phase 2 the VM's value stack and call frames become additional root
//! providers; the collector composes them.

const std = @import("std");
const gc = @import("gc.zig");
const Value = @import("value.zig").Value;

pub const HandleScope = struct {
    gpa: std.mem.Allocator,
    roots: std.ArrayList(Value),

    pub fn init(gpa: std.mem.Allocator) HandleScope {
        return .{ .gpa = gpa, .roots = .empty };
    }

    pub fn deinit(self: *HandleScope) void {
        self.roots.deinit(self.gpa);
    }

    /// Root `v` for the lifetime of this scope and return it back for chaining.
    pub fn root(self: *HandleScope, v: Value) !Value {
        try self.roots.append(self.gpa, v);
        return v;
    }

    /// Number of live roots (for diagnostics/tests).
    pub fn len(self: *const HandleScope) usize {
        return self.roots.items.len;
    }

    /// Root provider hook consumed by `Heap.collect`.
    pub fn markRoots(self: *const HandleScope, tracer: *gc.Tracer) void {
        for (self.roots.items) |v| v.mark(tracer);
    }
};

// ---- Tests -----------------------------------------------------------------

test "handle scope keeps rooted objects alive" {
    var heap = gc.Heap.init(std.testing.allocator);
    defer heap.deinit();

    var scope = HandleScope.init(std.testing.allocator);
    defer scope.deinit();

    const kept = try heap.create(gc.Object);
    _ = try scope.root(Value.fromObject(kept));

    // Unrooted garbage.
    _ = try heap.create(gc.Object);

    try std.testing.expectEqual(@as(usize, 2), heap.live_count);
    const freed = heap.collect(&scope);
    try std.testing.expectEqual(@as(usize, 1), freed);
    try std.testing.expectEqual(@as(usize, 1), heap.live_count);
    try std.testing.expectEqual(@as(usize, 1), scope.len());
}

test "empty scope collects all" {
    var heap = gc.Heap.init(std.testing.allocator);
    defer heap.deinit();

    var scope = HandleScope.init(std.testing.allocator);
    defer scope.deinit();

    _ = try heap.create(gc.Object);
    const s = try heap.create(gc.String);
    s.units = try std.testing.allocator.dupe(u16, &.{'x'});

    const freed = heap.collect(&scope);
    try std.testing.expectEqual(@as(usize, 2), freed);
    try std.testing.expectEqual(@as(usize, 0), heap.live_count);
}
