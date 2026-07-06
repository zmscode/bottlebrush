//! The JavaScript `Value` — a tagged union over the eight ECMAScript language
//! types the engine represents directly.
//!
//! IMPORTANT (see ../phase/phase-0/plan.md §2.1): all access goes through the
//! accessor API below — never touch the union payload directly from outside
//! this file. The representation is a Zig tagged union today; Phase 7 swaps it
//! for NaN-boxing behind this exact API, so keeping call sites on the accessors
//! makes that a localized change.

const std = @import("std");
const gc = @import("gc.zig");

pub const Value = union(enum) {
    // `undefined`/`null` are Zig primitive literals, so the field identifiers
    // are quoted. Callers should use the constructors/predicates below rather
    // than the raw tags.
    undefined,
    null,
    boolean: bool,
    number: f64,
    string: *gc.String,
    symbol: *gc.Symbol,
    bigint: *gc.BigInt,
    object: *gc.Object,

    // ---- Constructors ------------------------------------------------------
    pub const undefined_value: Value = .undefined;
    pub const null_value: Value = .null;

    pub fn fromBool(b: bool) Value {
        return .{ .boolean = b };
    }
    pub fn fromNumber(n: f64) Value {
        return .{ .number = n };
    }
    pub fn fromString(s: *gc.String) Value {
        return .{ .string = s };
    }
    pub fn fromSymbol(s: *gc.Symbol) Value {
        return .{ .symbol = s };
    }
    pub fn fromBigInt(b: *gc.BigInt) Value {
        return .{ .bigint = b };
    }
    pub fn fromObject(o: *gc.Object) Value {
        return .{ .object = o };
    }

    // ---- Predicates --------------------------------------------------------
    pub fn isUndefined(self: Value) bool {
        return std.meta.activeTag(self) == .undefined;
    }
    pub fn isNull(self: Value) bool {
        return std.meta.activeTag(self) == .null;
    }
    /// True for `undefined` or `null` (the values `== null` in JS).
    pub fn isNullish(self: Value) bool {
        return switch (self) {
            .undefined, .null => true,
            else => false,
        };
    }
    pub fn isBoolean(self: Value) bool {
        return std.meta.activeTag(self) == .boolean;
    }
    pub fn isNumber(self: Value) bool {
        return std.meta.activeTag(self) == .number;
    }
    pub fn isString(self: Value) bool {
        return std.meta.activeTag(self) == .string;
    }
    pub fn isSymbol(self: Value) bool {
        return std.meta.activeTag(self) == .symbol;
    }
    pub fn isBigInt(self: Value) bool {
        return std.meta.activeTag(self) == .bigint;
    }
    pub fn isObject(self: Value) bool {
        return std.meta.activeTag(self) == .object;
    }

    // ---- Extractors (assert the caller checked the tag) --------------------
    pub fn asBool(self: Value) bool {
        return self.boolean;
    }
    pub fn asNumber(self: Value) f64 {
        return self.number;
    }
    pub fn asString(self: Value) *gc.String {
        return self.string;
    }
    pub fn asSymbol(self: Value) *gc.Symbol {
        return self.symbol;
    }
    pub fn asBigInt(self: Value) *gc.BigInt {
        return self.bigint;
    }
    pub fn asObject(self: Value) *gc.Object {
        return self.object;
    }

    // ---- GC integration ----------------------------------------------------
    /// The GC header for heap-allocated values, else null for immediates.
    pub fn cellHeader(self: Value) ?*gc.GcHeader {
        return switch (self) {
            .string => |p| &p.gc,
            .symbol => |p| &p.gc,
            .bigint => |p| &p.gc,
            .object => |p| &p.gc,
            else => null,
        };
    }

    /// Mark this value's cell (if it has one) during a collection.
    pub fn mark(self: Value, tracer: *gc.Tracer) void {
        if (self.cellHeader()) |h| tracer.mark(h);
    }
};

// ---- Tests -----------------------------------------------------------------

test "immediate predicates and extractors" {
    try std.testing.expect(Value.undefined_value.isUndefined());
    try std.testing.expect(Value.null_value.isNull());
    try std.testing.expect(Value.undefined_value.isNullish());
    try std.testing.expect(Value.null_value.isNullish());

    const b = Value.fromBool(true);
    try std.testing.expect(b.isBoolean());
    try std.testing.expect(b.asBool());
    try std.testing.expect(!b.isNumber());

    const n = Value.fromNumber(42.5);
    try std.testing.expect(n.isNumber());
    try std.testing.expectEqual(@as(f64, 42.5), n.asNumber());
    try std.testing.expect(!n.isNullish());
}

test "immediates have no cell header" {
    try std.testing.expect(Value.undefined_value.cellHeader() == null);
    try std.testing.expect(Value.fromNumber(1).cellHeader() == null);
    try std.testing.expect(Value.fromBool(false).cellHeader() == null);
}

test "object value exposes its cell header" {
    var heap = gc.Heap.init(std.testing.allocator);
    defer heap.deinit();

    const obj = try heap.create(gc.Object);
    const v = Value.fromObject(obj);
    try std.testing.expect(v.isObject());
    try std.testing.expect(v.cellHeader() == &obj.gc);
    try std.testing.expect(v.asObject() == obj);
}
