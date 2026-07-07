//! Number and Boolean constructors, prototypes, and wrapper unboxing.

const std = @import("std");
const gc = @import("../../gc.zig");
const bc = @import("../../bytecode.zig");
const bilby = @import("bilby");
const Value = @import("../../value.zig").Value;
const interpreter = @import("../../interpreter.zig");
const Vm = interpreter.Vm;
const Error = interpreter.Error;

const support_mod = @import("../support.zig");
const argAt = support_mod.argAt;
const castVm = support_mod.castVm;
const formatRadix = support_mod.formatRadix;
const numberToString = support_mod.numberToString;
const prim_key = support_mod.prim_key;
const thisBoolean = support_mod.thisBoolean;
const thisNumber = support_mod.thisNumber;
const toBoolean = support_mod.toBoolean;

pub fn nativeNumber(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const n: f64 = if (args.len == 0) 0 else try vm.toNumber(args[0]);
    if (this.isObject() and this.asObject().prototype == vm.number_proto) {
        try vm.defineData(this.asObject(), prim_key, Value.fromNumber(n), false, false, false);
    }
    return Value.fromNumber(n);
}

pub fn nativeBoolean(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const b = toBoolean(argAt(args, 0));
    if (this.isObject() and this.asObject().prototype == vm.boolean_proto) {
        try vm.defineData(this.asObject(), prim_key, Value.fromBool(b), false, false, false);
    }
    return Value.fromBool(b);
}

pub fn nativeBooleanToString(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const vm = castVm(ctx);
    return vm.makeString(if (try thisBoolean(vm, this)) "true" else "false");
}

pub fn nativeBooleanValueOf(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    return Value.fromBool(try thisBoolean(castVm(ctx), this));
}

pub fn nativeNumberToExponential(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const x = try thisNumber(vm, this);
    var buf: [64]u8 = undefined;
    if (std.math.isNan(x) or std.math.isInf(x)) return vm.makeString(numberToString(x, &buf));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.gpa);
    if (argAt(args, 0).isUndefined()) {
        try out.print(vm.gpa, "{e}", .{x});
    } else {
        const d = try vm.toNumber(args[0]);
        if (std.math.isNan(d) or d < 0 or d > 100) return vm.throwRangeError("toExponential() argument must be between 0 and 100");
        const digits: usize = @intFromFloat(d);
        try out.print(vm.gpa, "{e:.[1]}", .{ x, digits });
    }
    // Zig prints "1.5e2"; JS wants "1.5e+2".
    if (std.mem.indexOfScalar(u8, out.items, 'e')) |epos| {
        if (epos + 1 < out.items.len and out.items[epos + 1] != '-') {
            try out.insert(vm.gpa, epos + 1, '+');
        }
    }
    return vm.makeString(out.items);
}

pub fn nativeNumberToPrecision(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const x = try thisNumber(vm, this);
    var buf: [64]u8 = undefined;
    if (argAt(args, 0).isUndefined()) return vm.makeString(numberToString(x, &buf));
    const p_f = try vm.toNumber(args[0]);
    if (std.math.isNan(p_f) or p_f < 1 or p_f > 100) return vm.throwRangeError("toPrecision() argument must be between 1 and 100");
    const p: i32 = @intFromFloat(p_f);
    if (std.math.isNan(x) or std.math.isInf(x)) return vm.makeString(numberToString(x, &buf));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.gpa);
    if (x == 0) {
        try out.append(vm.gpa, '0');
        if (p > 1) {
            try out.append(vm.gpa, '.');
            var i: i32 = 1;
            while (i < p) : (i += 1) try out.append(vm.gpa, '0');
        }
        return vm.makeString(out.items);
    }
    const e10: i32 = @intFromFloat(@floor(std.math.log10(@abs(x))));
    if (e10 < -6 or e10 >= p) {
        // Exponential with p-1 fractional digits.
        try out.print(vm.gpa, "{e:.[1]}", .{ x, @as(usize, @intCast(p - 1)) });
        if (std.mem.indexOfScalar(u8, out.items, 'e')) |epos| {
            if (epos + 1 < out.items.len and out.items[epos + 1] != '-') try out.insert(vm.gpa, epos + 1, '+');
        }
    } else {
        const frac: usize = @intCast(@max(p - 1 - e10, 0));
        try out.print(vm.gpa, "{d:.[1]}", .{ x, frac });
    }
    return vm.makeString(out.items);
}

pub fn nativeNumberValueOf(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    return Value.fromNumber(try thisNumber(castVm(ctx), this));
}

pub fn nativeNumberToString(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const x = try thisNumber(vm, this);
    const radix_v = argAt(args, 0);
    const radix: u8 = if (radix_v.isUndefined()) 10 else @intFromFloat(try vm.toNumber(radix_v));
    if (radix == 10) {
        var buf: [64]u8 = undefined;
        return vm.makeString(numberToString(x, &buf));
    }
    if (radix < 2 or radix > 36) return vm.throwRangeError("toString() radix must be between 2 and 36");
    var buf: [72]u8 = undefined;
    // Fall back to decimal formatting for non-finite or out-of-i64-range values.
    if (std.math.isNan(x) or std.math.isInf(x) or @abs(x) >= 9.0e18) {
        return vm.makeString(numberToString(x, &buf));
    }
    // Integer radix conversion (fractional part not supported for non-decimal).
    const i: i64 = @intFromFloat(std.math.trunc(x));
    return vm.makeString(formatRadix(i, radix, &buf));
}

pub fn nativeNumberToFixed(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const x = try thisNumber(vm, this);
    const d = try vm.toNumber(argAt(args, 0));
    const digits: usize = if (std.math.isNan(d) or d < 0) 0 else if (d > 100) 100 else @intFromFloat(d);
    if (std.math.isNan(x)) return vm.makeString("NaN");
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{[v]d:.[p]}", .{ .v = x, .p = digits }) catch return vm.makeString("0");
    return vm.makeString(s);
}

pub fn nativeNumberIsInteger(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    _ = this;
    const v = argAt(args, 0);
    if (!v.isNumber()) return Value.fromBool(false);
    const n = v.asNumber();
    return Value.fromBool(!std.math.isNan(n) and !std.math.isInf(n) and n == std.math.trunc(n));
}

pub fn nativeNumberIsFinite(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    _ = this;
    const v = argAt(args, 0);
    return Value.fromBool(v.isNumber() and !std.math.isNan(v.asNumber()) and !std.math.isInf(v.asNumber()));
}

pub fn nativeNumberIsNaN(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    _ = this;
    const v = argAt(args, 0);
    return Value.fromBool(v.isNumber() and std.math.isNan(v.asNumber()));
}
