//! Shared runtime helpers: coercion utilities, spec abstract operations,
//! key ordering, and the internal property keys. Used by the VM core and
//! every builtin module.

const std = @import("std");
const gc = @import("../gc.zig");
const bc = @import("../bytecode.zig");
const bilby = @import("bilby");
const Value = @import("../value.zig").Value;
const interpreter = @import("../interpreter.zig");
const Vm = interpreter.Vm;
const Error = interpreter.Error;

/// Internal property key holding a wrapper object's boxed primitive
/// ([[StringData]]/[[NumberData]]/[[BooleanData]]). NUL-prefixed so it is
/// invisible to enumeration, like symbol keys.
pub const prim_key = "\x00prim";

/// Internal keys for a RegExp's [[OriginalSource]] / [[OriginalFlags]].
pub const regexp_source_key = "\x00resrc";

pub const regexp_flags_key = "\x00reflg";

pub fn sameTypeStrictEq(a: Value, b: Value) bool {
    return switch (a) {
        .undefined => b.isUndefined(),
        .null => b.isNull(),
        .boolean => |x| b.isBoolean() and x == b.asBool(),
        .number => |x| b.isNumber() and x == b.asNumber(), // NaN != NaN, +0 == -0
        .string => |x| b.isString() and std.mem.eql(u16, x.units, b.asString().units),
        .bigint => |x| b.isBigInt() and x.toConst().order(b.asBigInt().toConst()) == .eq,
        .symbol => |x| b.isSymbol() and x == b.asSymbol(),
        .object => |x| b.isObject() and x == b.asObject(),
        .hole => unreachable,
    };
}

pub fn toBoolean(v: Value) bool {
    return switch (v) {
        .undefined, .null => false,
        .boolean => |b| b,
        .number => |n| n != 0 and !std.math.isNan(n),
        .string => |s| s.units.len != 0,
        .bigint => |b| !b.toConst().eqlZero(),
        .symbol, .object => true,
        .hole => unreachable,
    };
}

pub fn jsMod(a: f64, b: f64) f64 {
    return @rem(a, b);
}

pub fn jsShl(a: i32, count: u32) i32 {
    const x: u32 = @bitCast(a);
    const sh: u5 = @intCast(count & 31);
    return @bitCast(@as(u32, @truncate(@as(u64, x) << sh)));
}

pub fn jsShr(a: i32, count: u32) i32 {
    const sh: u5 = @intCast(count & 31);
    return a >> sh;
}

pub fn jsUshr(a: i32, count: u32) u32 {
    const x: u32 = @bitCast(a);
    const sh: u5 = @intCast(count & 31);
    return x >> sh;
}

/// JS `Number::exponentiate` — differs from C `pow` on a few edge cases
/// (`x**±0` is 1 even for NaN x; `(±1)**±Infinity` is NaN).
pub fn jsPow(base: f64, exp: f64) f64 {
    if (std.math.isNan(exp)) return std.math.nan(f64);
    if (exp == 0) return 1;
    if (std.math.isNan(base)) return std.math.nan(f64);
    if (std.math.isInf(exp)) {
        const ab = @abs(base);
        if (ab == 1) return std.math.nan(f64);
        if (exp > 0) return if (ab > 1) std.math.inf(f64) else 0;
        return if (ab > 1) 0 else std.math.inf(f64);
    }
    return std.math.pow(f64, base, exp);
}

pub fn doubleToInt32(n: f64) i32 {
    if (std.math.isNan(n) or std.math.isInf(n)) return 0;
    const truncated = std.math.trunc(n);
    const modulo = @mod(truncated, 4294967296.0);
    const as_u32: u32 = @intFromFloat(if (modulo < 0) modulo + 4294967296.0 else modulo);
    return @bitCast(as_u32);
}

pub fn stringToNumber(units: []const u16) f64 {
    // Convert to ASCII, trim, parse. Non-ASCII or malformed -> NaN.
    var buf: [64]u8 = undefined;
    if (units.len == 0) return 0;
    if (units.len >= buf.len) return std.math.nan(f64);
    var n: usize = 0;
    for (units) |u| {
        if (u > 127) return std.math.nan(f64);
        buf[n] = @intCast(u);
        n += 1;
    }
    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n\x0b\x0c");
    if (trimmed.len == 0) return 0;
    if (std.mem.eql(u8, trimmed, "Infinity") or std.mem.eql(u8, trimmed, "+Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, trimmed, "-Infinity")) return -std.math.inf(f64);
    // A signed radix prefix is not a StringNumericLiteral ("-0x10" -> NaN).
    if (trimmed.len > 3 and (trimmed[0] == '+' or trimmed[0] == '-') and trimmed[1] == '0') {
        switch (trimmed[2]) {
            'x', 'X', 'o', 'O', 'b', 'B' => return std.math.nan(f64),
            else => {},
        }
    }
    // Non-decimal numeric strings: 0x/0o/0b (no sign allowed, per spec).
    if (trimmed.len > 2 and trimmed[0] == '0') {
        const radix: ?u8 = switch (trimmed[1]) {
            'x', 'X' => 16,
            'o', 'O' => 8,
            'b', 'B' => 2,
            else => null,
        };
        if (radix) |r| {
            var v: f64 = 0;
            for (trimmed[2..]) |c| {
                const d = hexLikeDigit(c) orelse return std.math.nan(f64);
                if (d >= r) return std.math.nan(f64);
                v = v * @as(f64, @floatFromInt(r)) + @as(f64, @floatFromInt(d));
            }
            return v;
        }
    }
    const compiler = @import("../compiler.zig");
    return compiler.parseNumber(trimmed) catch std.math.nan(f64);
}

pub fn numberToString(n: f64, buf: []u8) []const u8 {
    if (std.math.isNan(n)) return "NaN";
    if (std.math.isInf(n)) return if (n > 0) "Infinity" else "-Infinity";
    if (n == 0) return "0";
    // Integer fast path only when the value fits safely in i64.
    if (n == std.math.trunc(n) and @abs(n) < 9.0e18) {
        return std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(n))}) catch "0";
    }
    return std.fmt.bufPrint(buf, "{d}", .{n}) catch "0";
}

pub fn castVm(ctx: *anyopaque) *Vm {
    return @ptrCast(@alignCast(ctx));
}

pub fn argAt(args: []const Value, i: usize) Value {
    return if (i < args.len) args[i] else Value.undefined_value;
}

pub fn thisBoolean(vm: *Vm, this: Value) Error!bool {
    if (this.isBoolean()) return this.asBool();
    if (this.isObject()) {
        if (this.asObject().properties.get(prim_key)) |d| {
            if (d.value.isBoolean()) return d.value.asBool();
        }
    }
    return vm.throwTypeError("Boolean.prototype method called on non-boolean");
}

pub fn isCallable(v: Value) bool {
    return v.isObject() and v.asObject().callable != null;
}

/// IsConstructor: true iff `v` is a callable object that implements
/// [[Construct]]. A proxy is a constructor iff its target is; a bound function
/// iff its target is.
pub fn isConstructorValue(v: Value) bool {
    if (!v.isObject()) return false;
    const obj = v.asObject();
    if (obj.proxy_target) |t| return isConstructorValue(Value.fromObject(t));
    if (obj.bound_target) |bt| return isConstructorValue(bt);
    const clo = obj.callable orelse return false;
    return clo.constructor;
}

pub fn thisArray(vm: *Vm, this: Value) Error!*gc.Object {
    if (!this.isObject() or !this.asObject().is_array) {
        return vm.throwTypeError("Array.prototype method called on a non-array");
    }
    return this.asObject();
}

/// Append `src`'s elements (0..length, preserving holes) to `dst`.
pub fn appendArrayElements(vm: *Vm, dst: *gc.Object, src: *gc.Object) Error!void {
    const base = dst.array_length;
    const n = src.array_length;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        try vm.checkBudget();
        if (Vm.arrayGetOwn(src, i)) |v| try vm.setArrayElement(dst, @intCast(@as(u64, base) + i), v);
    }
    const total: u64 = @as(u64, base) + n; // account for trailing holes
    if (total > dst.array_length) dst.array_length = @intCast(total);
}

/// ToIntegerOrInfinity: NaN -> 0, else truncate toward zero.
pub fn toIntegerOrInfinity(vm: *Vm, v: Value) Error!f64 {
    const n = try vm.toNumber(v);
    if (std.math.isNan(n)) return 0;
    return std.math.trunc(n);
}

/// ToLength(Get(base, "length")) — the generic array-like length.
pub fn lengthOfArrayLike(vm: *Vm, base: Value) Error!u64 {
    const n = try vm.toNumber(try vm.getProperty(base, "length"));
    if (std.math.isNan(n) or n <= 0) return 0;
    return @intFromFloat(@min(n, 9007199254740991.0)); // 2^53 - 1
}

/// Resolve a `fromIndex` argument against `len` (negative counts from the
/// end). Returns null when the search can never succeed (fromIndex >= len).
pub fn resolveFromIndex(vm: *Vm, args: []const Value, len: u64) Error!?u64 {
    const flen: f64 = @floatFromInt(len);
    var from: f64 = if (args.len >= 2) try toIntegerOrInfinity(vm, args[1]) else 0;
    if (from >= flen) return null;
    if (from < 0) from = @max(flen + from, 0);
    return @intFromFloat(from);
}

/// HasProperty for any base value: objects walk their chain; primitives check
/// their exotic own keys and then their wrapper prototype's chain.
pub fn hasPropertyGeneric(vm: *Vm, base: Value, key: []const u8) bool {
    if (base.isObject()) return vm.hasProperty(base.asObject(), key);
    if (base.isString()) {
        if (arrayIndex(key)) |i| {
            if (i < base.asString().units.len) return true;
        }
        if (std.mem.eql(u8, key, "length")) return true;
        if (vm.string_proto) |p| return vm.hasProperty(p, key);
        return false;
    }
    const proto: ?*gc.Object = if (base.isNumber()) vm.number_proto else if (base.isBoolean()) vm.boolean_proto else null;
    if (proto) |p| return vm.hasProperty(p, key);
    return false;
}

pub fn optNumber(vm: *Vm, v: Value, default: f64) Error!f64 {
    if (v.isUndefined()) return default;
    return vm.toNumber(v);
}

/// Clamp a relative index (negative counts from the end) to [0, len].
pub fn relativeIndex(n: f64, len: i64) i64 {
    if (std.math.isNan(n)) return 0;
    var idx: i64 = if (n < -9.2e18) -len else if (n > 9.2e18) len else @intFromFloat(std.math.trunc(n));
    if (idx < 0) idx += len;
    if (idx < 0) idx = 0;
    if (idx > len) idx = len;
    return idx;
}

/// Collect `obj`'s own string keys in spec order: integer-like keys ascending
/// first (array elements and numeric property names together), then the rest
/// in insertion order. Internal (NUL-prefixed) keys are skipped. When
/// `enumerable_only`, non-enumerable properties are omitted. Keys are duped.
pub fn orderedOwnKeys(vm: *Vm, obj: *gc.Object, enumerable_only: bool, out: *std.ArrayList([]const u8)) Error!void {
    var ints: std.ArrayList(u32) = .empty;
    defer ints.deinit(vm.gpa);
    if (obj.is_array) try vm.arrayPresentIndices(obj, &ints);
    var it = obj.properties.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        if (k.len > 0 and k[0] == 0) continue; // internal slots + symbol keys
        if (enumerable_only and !entry.value_ptr.enumerable) continue;
        if (arrayIndex(k)) |i| try ints.append(vm.gpa, i);
    }
    std.mem.sort(u32, ints.items, {}, std.sort.asc(u32));
    for (ints.items) |i| {
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
        try out.append(vm.gpa, try vm.gpa.dupe(u8, s));
    }
    it = obj.properties.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        if (k.len > 0 and k[0] == 0) continue;
        if (enumerable_only and !entry.value_ptr.enumerable) continue;
        if (arrayIndex(k) != null) continue; // already emitted, sorted
        try out.append(vm.gpa, try vm.gpa.dupe(u8, k));
    }
}

/// A property-map key that encodes a Symbol (`\x00S<ptr>`), as opposed to an
/// internal slot (`\x00prim`, `\x00re…`, private `\x00P…`) or a string key.
fn isSymbolKey(k: []const u8) bool {
    return k.len >= 2 and k[0] == 0 and k[1] == 'S';
}

fn keyIndexIn(items: []const []const u8, used: []const bool, k: []const u8) ?usize {
    for (items, 0..) |it, i| {
        if (!used[i] and std.mem.eql(u8, it, k)) return i;
    }
    return null;
}

/// Collect `target`'s own keys (strings and symbols, encoded) split by
/// configurability — the raw material for the proxy `ownKeys` invariants.
fn targetOwnKeysSplit(vm: *Vm, target: *gc.Object, config: *std.ArrayList([]const u8), nonconfig: *std.ArrayList([]const u8)) Error!void {
    if (target.is_array) {
        var ints: std.ArrayList(u32) = .empty;
        defer ints.deinit(vm.gpa);
        try vm.arrayPresentIndices(target, &ints);
        for (ints.items) |i| {
            var b: [16]u8 = undefined;
            try config.append(vm.gpa, try vm.gpa.dupe(u8, std.fmt.bufPrint(&b, "{d}", .{i}) catch unreachable));
        }
        try nonconfig.append(vm.gpa, try vm.gpa.dupe(u8, "length"));
    }
    var it = target.properties.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        if (k.len > 0 and k[0] == 0 and !isSymbolKey(k)) continue; // internal slot
        const dst = if (entry.value_ptr.configurable) config else nonconfig;
        try dst.append(vm.gpa, try vm.gpa.dupe(u8, k));
    }
}

/// The proxy `ownKeys` trap result, or false when `obj` is not a proxy.
/// Runs CreateListFromArrayLike validation, duplicate detection, and the
/// non-configurable / non-extensible invariants (spec 10.5.11). Only string
/// keys are appended to `out` (symbol keys are validated but not yet emitted).
fn proxyOwnKeys(vm: *Vm, obj: *gc.Object, enumerable_only: bool, out: *std.ArrayList([]const u8)) Error!bool {
    const target = obj.proxy_target orelse return false;
    if (obj.proxy_revoked) return vm.throwTypeError("cannot perform operation on a revoked proxy");
    const handler = obj.proxy_handler.?;
    const trap = try vm.getProperty(Value.fromObject(handler), "ownKeys");
    if (trap.isNullish()) {
        // Forward [[OwnPropertyKeys]] to the target (may be a nested proxy).
        if (enumerable_only) try ownEnumerableKeys(vm, target, out) else try ownPropertyNames(vm, target, out);
        return true;
    }
    if (!isCallable(trap)) return vm.throwTypeError("proxy ownKeys trap is not callable");
    const r = try vm.callValue(trap, Value.fromObject(handler), &.{Value.fromObject(target)});
    if (!r.isObject()) return vm.throwTypeError("proxy ownKeys must return an object");

    // CreateListFromArrayLike(r, «String, Symbol»): reject other element types
    // and duplicate keys. `trap_keys` holds encoded keys.
    var trap_keys: std.ArrayList([]const u8) = .empty;
    defer {
        for (trap_keys.items) |k| vm.gpa.free(k);
        trap_keys.deinit(vm.gpa);
    }
    const len = try lengthOfArrayLike(vm, r);
    var i: u64 = 0;
    while (i < len) : (i += 1) {
        var b: [24]u8 = undefined;
        const el = try vm.getProperty(r, std.fmt.bufPrint(&b, "{d}", .{i}) catch unreachable);
        if (!el.isString() and !el.isSymbol()) return vm.throwTypeError("proxy ownKeys entries must be strings or symbols");
        const enc = try vm.toPropertyKey(el);
        for (trap_keys.items) |ex| {
            if (std.mem.eql(u8, ex, enc)) {
                vm.gpa.free(enc);
                return vm.throwTypeError("proxy ownKeys returned duplicate keys");
            }
        }
        try trap_keys.append(vm.gpa, enc);
    }

    // Invariants (spec 10.5.11 steps 16-27).
    var config: std.ArrayList([]const u8) = .empty;
    var nonconfig: std.ArrayList([]const u8) = .empty;
    defer {
        for (config.items) |k| vm.gpa.free(k);
        config.deinit(vm.gpa);
        for (nonconfig.items) |k| vm.gpa.free(k);
        nonconfig.deinit(vm.gpa);
    }
    try targetOwnKeysSplit(vm, target, &config, &nonconfig);
    const extensible = target.extensible;
    if (!(extensible and nonconfig.items.len == 0)) {
        const used = try vm.gpa.alloc(bool, trap_keys.items.len);
        defer vm.gpa.free(used);
        @memset(used, false);
        for (nonconfig.items) |k| {
            const idx = keyIndexIn(trap_keys.items, used, k) orelse
                return vm.throwTypeError("proxy ownKeys must include every non-configurable key of the target");
            used[idx] = true;
        }
        if (!extensible) {
            for (config.items) |k| {
                const idx = keyIndexIn(trap_keys.items, used, k) orelse
                    return vm.throwTypeError("proxy ownKeys must include every key of a non-extensible target");
                used[idx] = true;
            }
            for (used) |u| if (!u) return vm.throwTypeError("proxy ownKeys must not add keys to a non-extensible target");
        }
    }

    // Emit string keys only for now (symbol emission needs the wider ownKeys
    // rework that threads real Symbol values through enumeration).
    for (trap_keys.items) |k| {
        if (k.len > 0 and k[0] == 0) continue;
        try out.append(vm.gpa, try vm.gpa.dupe(u8, k));
    }
    return true;
}

/// Own enumerable string keys in spec order (Object.keys/values/entries).
pub fn ownEnumerableKeys(vm: *Vm, obj: *gc.Object, out: *std.ArrayList([]const u8)) Error!void {
    if (try proxyOwnKeys(vm, obj, true, out)) return;
    return orderedOwnKeys(vm, obj, true, out);
}

/// ES2015 ToObject coercion for Object.keys and friends: nullish throws, a
/// string exposes its indices as own keys, other primitives have none.
/// Returns null when `v` is a real object (caller proceeds normally).
pub fn primitiveOwnKeysResult(vm: *Vm, v: Value, include_length: bool) Error!?Value {
    if (v.isObject()) return null;
    if (v.isNullish()) return vm.throwTypeError("cannot convert null or undefined to object");
    const result = try vm.newArray(0);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    if (v.isString()) {
        const n = v.asString().units.len;
        var i: usize = 0;
        var buf: [16]u8 = undefined;
        while (i < n) : (i += 1) {
            const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
            try vm.arrayAppend(result, try vm.makeString(s));
        }
        if (include_length) try vm.arrayAppend(result, try vm.makeString("length"));
    }
    return Value.fromObject(result);
}

/// All own string-keyed property names (enumerable and not), skipping symbol
/// and internal-slot keys. Array indices and `length` are included for arrays.
pub fn ownPropertyNames(vm: *Vm, obj: *gc.Object, out: *std.ArrayList([]const u8)) Error!void {
    if (try proxyOwnKeys(vm, obj, false, out)) return;
    try orderedOwnKeys(vm, obj, false, out);
    if (obj.is_array) try out.append(vm.gpa, try vm.gpa.dupe(u8, "length"));
}

pub fn coerceToString(vm: *Vm, v: Value) Error!Value {
    if (v.isString()) return v;
    return vm.toStringVal(v);
}

pub fn indexOfUtf16(haystack: []const u16, needle: []const u16, from: usize) ?usize {
    if (needle.len == 0) return @min(from, haystack.len);
    if (needle.len > haystack.len) return null;
    var i = from;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u16, haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

pub fn hexLikeDigit(c: u16) ?u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'z' => c - 'a' + 10,
        'A'...'Z' => c - 'A' + 10,
        else => null,
    };
}

pub fn thisNumber(vm: *Vm, this: Value) Error!f64 {
    if (this.isNumber()) return this.asNumber();
    // Number wrapper: unbox [[NumberData]].
    if (this.isObject()) {
        if (this.asObject().properties.get(prim_key)) |d| {
            if (d.value.isNumber()) return d.value.asNumber();
        }
    }
    return vm.throwTypeError("Number.prototype method called on non-number");
}

/// SameValue: like strict equality, except NaN equals NaN and +0 and -0 are
/// distinct (used by property-descriptor validation).
pub fn sameValue(a: Value, b: Value) bool {
    if (a.isNumber() and b.isNumber()) {
        const x = a.asNumber();
        const y = b.asNumber();
        if (std.math.isNan(x) and std.math.isNan(y)) return true;
        if (x == 0 and y == 0) return std.math.signbit(x) == std.math.signbit(y);
        return x == y;
    }
    return sameTypeStrictEq(a, b);
}

pub fn sameValueZero(a: Value, b: Value) bool {
    if (a.isNumber() and b.isNumber()) {
        const x = a.asNumber();
        const y = b.asNumber();
        if (std.math.isNan(x) and std.math.isNan(y)) return true;
        return x == y; // +0 and -0 are equal under SameValueZero
    }
    return sameTypeStrictEq(a, b);
}

pub fn thisCollection(vm: *Vm, this: Value, kind: gc.Collection) Error!*gc.Object {
    if (!this.isObject() or this.asObject().collection != kind) {
        return vm.throwTypeError("method called on an incompatible receiver");
    }
    return this.asObject();
}

pub fn readTypedElement(ta: gc.TypedArrayView, i: u32) Value {
    // Detached buffer ($262.detachArrayBuffer): element reads see undefined.
    const bytes = ta.buffer.buffer_data orelse return Value.undefined_value;
    const off = ta.offset + i * gc.bytesPerElement(ta.kind);
    const n: f64 = switch (ta.kind) {
        .i8 => @floatFromInt(@as(i8, @bitCast(bytes[off]))),
        .u8, .u8c => @floatFromInt(bytes[off]),
        .i16 => @floatFromInt(std.mem.readInt(i16, bytes[off..][0..2], .little)),
        .u16 => @floatFromInt(std.mem.readInt(u16, bytes[off..][0..2], .little)),
        .i32 => @floatFromInt(std.mem.readInt(i32, bytes[off..][0..4], .little)),
        .u32 => @floatFromInt(std.mem.readInt(u32, bytes[off..][0..4], .little)),
        .f32 => @floatCast(@as(f32, @bitCast(std.mem.readInt(u32, bytes[off..][0..4], .little)))),
        .f64 => @bitCast(std.mem.readInt(u64, bytes[off..][0..8], .little)),
    };
    return Value.fromNumber(n);
}

pub fn clampToU8(n: f64) u8 {
    if (std.math.isNan(n) or n <= 0) return 0;
    if (n >= 255) return 255;
    return @intFromFloat(std.math.round(n));
}

pub fn writeTypedElement(ta: gc.TypedArrayView, i: u32, n: f64) void {
    // Detached buffer: writes are silently dropped.
    const bytes = ta.buffer.buffer_data orelse return;
    const off = ta.offset + i * gc.bytesPerElement(ta.kind);
    const bits: u32 = @bitCast(doubleToInt32(n)); // ToInt32/ToUint32 bit pattern
    switch (ta.kind) {
        .i8, .u8 => bytes[off] = @truncate(bits),
        .u8c => bytes[off] = clampToU8(n),
        .i16, .u16 => std.mem.writeInt(u16, bytes[off..][0..2], @truncate(bits), .little),
        .i32, .u32 => std.mem.writeInt(u32, bytes[off..][0..4], bits, .little),
        .f32 => std.mem.writeInt(u32, bytes[off..][0..4], @bitCast(@as(f32, @floatCast(n))), .little),
        .f64 => std.mem.writeInt(u64, bytes[off..][0..8], @bitCast(n), .little),
    }
}

pub fn clampIndex(n: f64, len: i64) i64 {
    if (std.math.isNan(n) or n < 0) return 0;
    if (n > @as(f64, @floatFromInt(len))) return len;
    return @intFromFloat(std.math.trunc(n));
}

pub fn isJsSpace(u: u16) bool {
    return u == ' ' or u == '\t' or u == '\n' or u == '\r' or u == 0x0b or u == 0x0c or u == 0xa0 or u == 0xfeff;
}

/// Format an integer in the given radix into `buf`, returning the slice.
pub fn formatRadix(value: i64, radix: u8, buf: []u8) []const u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    var n: u64 = if (value < 0) @intCast(-value) else @intCast(value);
    var i: usize = buf.len;
    while (n > 0) {
        i -= 1;
        buf[i] = digits[@intCast(n % radix)];
        n /= radix;
    }
    if (value < 0) {
        i -= 1;
        buf[i] = '-';
    }
    return buf[i..];
}

pub fn utf16ToUtf8Alloc(gpa: std.mem.Allocator, units: []const u16) Error![]u8 {
    return std.unicode.utf16LeToUtf8Alloc(gpa, units) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => try gpa.dupe(u8, ""),
    };
}

/// Parse a canonical array-index string (no leading zeros, < 2^32-1), else null.
pub fn arrayIndex(key: []const u8) ?u32 {
    if (key.len == 0 or key.len > 10) return null;
    if (key.len > 1 and key[0] == '0') return null;
    var n: u64 = 0;
    for (key) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
    }
    if (n >= 4294967295) return null;
    return @intCast(n);
}

pub fn compareUtf16(a: []const u16, b: []const u16) i32 {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return if (a[i] < b[i]) -1 else 1;
    }
    if (a.len == b.len) return 0;
    return if (a.len < b.len) -1 else 1;
}
