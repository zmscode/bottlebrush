//! BigInt constructor and BigInt.prototype natives.

const std = @import("std");
const gc = @import("../../gc.zig");
const Value = @import("../../value.zig").Value;
const interpreter = @import("../../interpreter.zig");
const Vm = interpreter.Vm;
const Error = interpreter.Error;

const support_mod = @import("../support.zig");
const argAt = support_mod.argAt;
const castVm = support_mod.castVm;
const utf16ToUtf8Alloc = support_mod.utf16ToUtf8Alloc;

/// BigInt(value) — not new-able. Numbers must be integral; strings parse via
/// StringToBigInt (SyntaxError on garbage); booleans become 0n/1n.
pub fn nativeBigInt(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    if (this.isObject() and this.asObject().prototype == vm.bigint_proto) {
        return vm.throwTypeError("BigInt is not a constructor");
    }
    const v = try vm.toPrimitiveHint(argAt(args, 0), .number);
    if (v.isBigInt()) return v;
    if (v.isBoolean()) {
        var m = std.math.big.int.Managed.initSet(vm.gpa, @as(u8, if (v.asBool()) 1 else 0)) catch return error.OutOfMemory;
        defer m.deinit();
        return vm.makeBigIntConst(m.toConst());
    }
    if (v.isNumber()) {
        const n = v.asNumber();
        if (!std.math.isFinite(n) or n != std.math.trunc(n)) {
            return vm.throwRangeError("cannot convert a non-integral number to BigInt");
        }
        return bigintFromF64(vm, n);
    }
    if (v.isString()) {
        const utf8 = try utf16ToUtf8Alloc(vm.gpa, v.asString().units);
        defer vm.gpa.free(utf8);
        const trimmed = std.mem.trim(u8, utf8, " \t\n\r\x0b\x0c");
        if (trimmed.len == 0) {
            var m = std.math.big.int.Managed.init(vm.gpa) catch return error.OutOfMemory;
            defer m.deinit();
            return vm.makeBigIntConst(m.toConst());
        }
        return (try vm.parseBigIntDigits(trimmed)) orelse
            vm.throwSyntaxError("cannot convert string to BigInt");
    }
    return vm.throwTypeError("cannot convert value to BigInt");
}

/// Exact conversion of an integral f64 into a BigInt value.
fn bigintFromF64(vm: *Vm, n: f64) Error!Value {
    // i128 covers every practically-occurring integral double; beyond that,
    // build 2^exp * mantissa via shift.
    if (@abs(n) < 170141183460469231731687303715884105728.0) { // 2^127
        var m = std.math.big.int.Managed.initSet(vm.gpa, @as(i128, @intFromFloat(n))) catch return error.OutOfMemory;
        defer m.deinit();
        return vm.makeBigIntConst(m.toConst());
    }
    const bits: u64 = @bitCast(@abs(n));
    const exp: i32 = @as(i32, @intCast((bits >> 52) & 0x7ff)) - 1023 - 52;
    const mant: u64 = (bits & ((1 << 52) - 1)) | (1 << 52);
    var m = std.math.big.int.Managed.initSet(vm.gpa, mant) catch return error.OutOfMemory;
    defer m.deinit();
    var r = std.math.big.int.Managed.init(vm.gpa) catch return error.OutOfMemory;
    defer r.deinit();
    r.shiftLeft(&m, @intCast(exp)) catch return error.OutOfMemory;
    if (n < 0) r.negate();
    return vm.makeBigIntConst(r.toConst());
}

/// The receiver's BigInt primitive (primitive or wrapper), else TypeError.
fn thisBigInt(vm: *Vm, this: Value) Error!*gc.BigInt {
    if (this.isBigInt()) return this.asBigInt();
    if (this.isObject()) {
        if (this.asObject().properties.get(support_mod.prim_key)) |d| {
            if (d.value.isBigInt()) return d.value.asBigInt();
        }
    }
    return vm.throwTypeError("BigInt.prototype method called on non-BigInt");
}

pub fn nativeBigIntToString(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const b = try thisBigInt(vm, this);
    var radix: u8 = 10;
    if (!argAt(args, 0).isUndefined()) {
        const r = try vm.toNumber(args[0]);
        if (std.math.isNan(r) or r < 2 or r > 36) return vm.throwRangeError("toString() radix must be between 2 and 36");
        radix = @intFromFloat(r);
    }
    const s = try vm.bigintToStringAlloc(b, radix);
    defer vm.gpa.free(s);
    return vm.makeString(s);
}

pub fn nativeBigIntValueOf(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const vm = castVm(ctx);
    return Value.fromBigInt(try thisBigInt(vm, this));
}

/// Shared BigInt.asIntN / asUintN: wrap modulo 2^bits.
fn asN(ctx: *anyopaque, args: []const Value, signedness: std.builtin.Signedness) Error!Value {
    const vm = castVm(ctx);
    const bits_f = try vm.toNumber(argAt(args, 0));
    if (std.math.isNan(bits_f) or bits_f < 0 or bits_f > 4294967295) {
        return vm.throwRangeError("bits must be a non-negative integer");
    }
    const bits: usize = @intFromFloat(bits_f);
    const v = argAt(args, 1);
    if (!v.isBigInt()) return vm.throwTypeError("second argument must be a BigInt");
    if (bits == 0) {
        var z = std.math.big.int.Managed.init(vm.gpa) catch return error.OutOfMemory;
        defer z.deinit();
        return vm.makeBigIntConst(z.toConst());
    }
    var m = std.math.big.int.Managed.init(vm.gpa) catch return error.OutOfMemory;
    defer m.deinit();
    m.copy(v.asBigInt().toConst()) catch return error.OutOfMemory;
    var r = std.math.big.int.Managed.init(vm.gpa) catch return error.OutOfMemory;
    defer r.deinit();
    r.truncate(&m, signedness, bits) catch return error.OutOfMemory;
    return vm.makeBigIntConst(r.toConst());
}

pub fn nativeBigIntAsIntN(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    return asN(ctx, args, .signed);
}

pub fn nativeBigIntAsUintN(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    return asN(ctx, args, .unsigned);
}
