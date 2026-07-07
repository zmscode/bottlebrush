//! The Math namespace natives.

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
const jsPow = support_mod.jsPow;

pub fn mathUnary(ctx: *anyopaque, args: []const Value, comptime op: anytype) Error!Value {
    const vm = castVm(ctx);
    const x: f64 = try vm.toNumber(argAt(args, 0));
    return Value.fromNumber(op(x));
}

pub fn nativeMathAbs(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    return mathUnary(ctx, args, struct {
        fn f(x: f64) f64 {
            return @abs(x);
        }
    }.f);
}

pub fn nativeMathFloor(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    return mathUnary(ctx, args, std.math.floor);
}

pub fn nativeMathCeil(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    return mathUnary(ctx, args, std.math.ceil);
}

pub fn nativeMathRound(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    return mathUnary(ctx, args, struct {
        fn f(x: f64) f64 {
            if (std.math.isNan(x) or std.math.isInf(x) or x == 0) return x; // preserves -0
            // floor(x) + (fractional >= 0.5 ? 1 : 0); avoids the x+0.5
            // double-rounding pitfall. Ties round toward +Infinity.
            const fl = std.math.floor(x);
            const result = if (x - fl >= 0.5) fl + 1 else fl;
            // Values in [-0.5, 0) round to -0, not +0.
            if (result == 0 and x < 0) return -0.0;
            return result;
        }
    }.f);
}

pub fn nativeMathTrunc(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    return mathUnary(ctx, args, std.math.trunc);
}

pub fn nativeMathSqrt(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    return mathUnary(ctx, args, std.math.sqrt);
}

pub fn nativeMathSign(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    return mathUnary(ctx, args, struct {
        fn f(x: f64) f64 {
            if (std.math.isNan(x)) return x;
            if (x > 0) return 1;
            if (x < 0) return -1;
            return x; // +/-0
        }
    }.f);
}

pub fn nativeMathPow(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const base = try vm.toNumber(argAt(args, 0));
    const exp = try vm.toNumber(argAt(args, 1));
    return Value.fromNumber(jsPow(base, exp));
}

pub fn isNegZero(x: f64) bool {
    return x == 0 and std.math.signbit(x);
}

pub fn nativeMathMax(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    var result: f64 = -std.math.inf(f64);
    var saw_nan = false;
    // Spec: coerce every argument (side effects) before deciding.
    for (args) |a| {
        const n = try vm.toNumber(a);
        if (std.math.isNan(n)) {
            saw_nan = true;
        } else if (n > result or (n == 0 and result == 0 and isNegZero(result) and !isNegZero(n))) {
            result = n; // +0 is greater than -0
        }
    }
    return Value.fromNumber(if (saw_nan) std.math.nan(f64) else result);
}

pub fn nativeMathMin(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    var result: f64 = std.math.inf(f64);
    var saw_nan = false;
    for (args) |a| {
        const n = try vm.toNumber(a);
        if (std.math.isNan(n)) {
            saw_nan = true;
        } else if (n < result or (n == 0 and result == 0 and !isNegZero(result) and isNegZero(n))) {
            result = n; // -0 is less than +0
        }
    }
    return Value.fromNumber(if (saw_nan) std.math.nan(f64) else result);
}

/// Build a native for a unary Math function from a `fn(f64) f64`.
pub fn mathUnaryFn(comptime op: anytype) gc.NativeFn {
    return struct {
        fn call(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
            _ = this;
            return mathUnary(ctx, args, op);
        }
    }.call;
}

pub fn opSin(x: f64) f64 {
    return @sin(x);
}

pub fn opCos(x: f64) f64 {
    return @cos(x);
}

pub fn opTan(x: f64) f64 {
    return std.math.tan(x);
}

pub fn opAsin(x: f64) f64 {
    return std.math.asin(x);
}

pub fn opAcos(x: f64) f64 {
    return std.math.acos(x);
}

pub fn opAtan(x: f64) f64 {
    return std.math.atan(x);
}

pub fn opSinh(x: f64) f64 {
    return std.math.sinh(x);
}

pub fn opCosh(x: f64) f64 {
    return std.math.cosh(x);
}

pub fn opTanh(x: f64) f64 {
    return std.math.tanh(x);
}

pub fn opAsinh(x: f64) f64 {
    return std.math.asinh(x);
}

pub fn opAcosh(x: f64) f64 {
    return std.math.acosh(x);
}

pub fn opAtanh(x: f64) f64 {
    return std.math.atanh(x);
}

pub fn opExp(x: f64) f64 {
    return @exp(x);
}

pub fn opExpm1(x: f64) f64 {
    return std.math.expm1(x);
}

pub fn opLog(x: f64) f64 {
    return @log(x);
}

pub fn opLog2(x: f64) f64 {
    return @log2(x);
}

pub fn opLog10(x: f64) f64 {
    return @log10(x);
}

pub fn opLog1p(x: f64) f64 {
    return std.math.log1p(x);
}

pub fn opCbrt(x: f64) f64 {
    return std.math.cbrt(x);
}

pub fn opFround(x: f64) f64 {
    return @floatCast(@as(f32, @floatCast(x)));
}

pub fn nativeMathAtan2(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const y = try vm.toNumber(argAt(args, 0));
    const x = try vm.toNumber(argAt(args, 1));
    return Value.fromNumber(std.math.atan2(y, x));
}

pub fn nativeMathHypot(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    var sum: f64 = 0;
    var any_inf = false;
    for (args) |a| {
        const n = try vm.toNumber(a);
        if (std.math.isInf(n)) any_inf = true;
        sum += n * n;
    }
    // ±Infinity in any argument yields +Infinity, even alongside NaN.
    if (any_inf) return Value.fromNumber(std.math.inf(f64));
    return Value.fromNumber(@sqrt(sum));
}

pub fn nativeMathClz32(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const n = try vm.toUint32(argAt(args, 0));
    return Value.fromNumber(@floatFromInt(@as(u32, @clz(n))));
}

pub fn nativeMathImul(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const a = try vm.toInt32(argAt(args, 0));
    const b = try vm.toInt32(argAt(args, 1));
    return Value.fromNumber(@floatFromInt(a *% b));
}

pub var math_prng = std.Random.DefaultPrng.init(0x2545F4914F6CDD1D);

pub fn nativeMathRandom(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    _ = this;
    _ = args;
    return Value.fromNumber(math_prng.random().float(f64));
}
