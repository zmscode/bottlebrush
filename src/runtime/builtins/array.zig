//! Array constructor and Array.prototype natives.

const std = @import("std");
const gc = @import("../../gc.zig");
const bc = @import("../../bytecode.zig");
const bilby = @import("bilby");
const Value = @import("../../value.zig").Value;
const interpreter = @import("../../interpreter.zig");
const Vm = interpreter.Vm;
const Error = interpreter.Error;

const support_mod = @import("../support.zig");
const appendArrayElements = support_mod.appendArrayElements;
const argAt = support_mod.argAt;
const castVm = support_mod.castVm;
const hasPropertyGeneric = support_mod.hasPropertyGeneric;
const isCallable = support_mod.isCallable;
const lengthOfArrayLike = support_mod.lengthOfArrayLike;
const optNumber = support_mod.optNumber;
const relativeIndex = support_mod.relativeIndex;
const resolveFromIndex = support_mod.resolveFromIndex;
const sameTypeStrictEq = support_mod.sameTypeStrictEq;
const sameValueZero = support_mod.sameValueZero;
const thisArray = support_mod.thisArray;
const toBoolean = support_mod.toBoolean;

pub fn nativeArray(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    if (args.len == 1 and args[0].isNumber()) {
        const n = args[0].asNumber();
        const len: u32 = if (n < 0 or n != std.math.floor(n) or n > 4294967295) return vm.throwRangeError("invalid array length") else @intFromFloat(n);
        return Value.fromObject(try vm.newArray(len));
    }
    const arr = try vm.newArray(0);
    try vm.protect(Value.fromObject(arr));
    defer vm.unprotect();
    for (args, 0..) |a, i| try vm.setArrayElement(arr, @intCast(i), a);
    return Value.fromObject(arr);
}

pub fn nativeArrayIsArray(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    _ = this;
    const v = argAt(args, 0);
    return Value.fromBool(v.isObject() and v.asObject().is_array);
}

pub fn nativeArrayPush(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    for (args) |a| try vm.arrayAppend(arr, a);
    return Value.fromNumber(@floatFromInt(arr.array_length));
}

pub fn nativeArrayPop(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    if (arr.array_length == 0) return Value.undefined_value;
    const last = arr.array_length - 1;
    const v = Vm.arrayGetOwn(arr, last) orelse Value.undefined_value;
    try vm.setArrayLength(arr, last);
    return v;
}

pub fn nativeArrayIndexOf(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const target = argAt(args, 0);

    // Fast path: a real array — scan only present indices.
    if (this.isObject() and this.asObject().is_array) {
        const arr = this.asObject();
        if (arr.array_length == 0) return Value.fromNumber(-1);
        const start = (try resolveFromIndex(vm, args, arr.array_length)) orelse return Value.fromNumber(-1);
        var idxs: std.ArrayList(u32) = .empty;
        defer idxs.deinit(vm.gpa);
        try vm.arrayPresentIndices(arr, &idxs);
        for (idxs.items) |i| {
            if (i < start) continue;
            if (sameTypeStrictEq(Vm.arrayGetOwn(arr, i).?, target)) return Value.fromNumber(@floatFromInt(i));
        }
        return Value.fromNumber(-1);
    }

    // Generic array-like path (spec: ToLength + HasProperty + Get per index).
    const len = try lengthOfArrayLike(vm, this);
    if (len == 0) return Value.fromNumber(-1);
    var k = (try resolveFromIndex(vm, args, len)) orelse return Value.fromNumber(-1);
    while (k < len) : (k += 1) {
        try vm.checkBudget();
        var kb: [24]u8 = undefined;
        const key = std.fmt.bufPrint(&kb, "{d}", .{k}) catch unreachable;
        if (!hasPropertyGeneric(vm, this, key)) continue; // indexOf skips holes/absent indices
        if (sameTypeStrictEq(try vm.getProperty(this, key), target)) return Value.fromNumber(@floatFromInt(k));
    }
    return Value.fromNumber(-1);
}

pub fn nativeArrayIncludes(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const target = argAt(args, 0);

    if (this.isObject() and this.asObject().is_array) {
        const arr = this.asObject();
        if (arr.array_length == 0) return Value.fromBool(false);
        const start = (try resolveFromIndex(vm, args, arr.array_length)) orelse return Value.fromBool(false);
        var idxs: std.ArrayList(u32) = .empty;
        defer idxs.deinit(vm.gpa);
        try vm.arrayPresentIndices(arr, &idxs);
        var present_after_start: usize = 0;
        for (idxs.items) |i| {
            if (i < start) continue;
            present_after_start += 1;
            if (sameValueZero(Vm.arrayGetOwn(arr, i).?, target)) return Value.fromBool(true);
        }
        // Unlike indexOf, includes reads holes as `undefined`.
        const searched: u64 = arr.array_length - start;
        if (target.isUndefined() and present_after_start < searched) return Value.fromBool(true);
        return Value.fromBool(false);
    }

    // Generic array-like path: absent indices read as `undefined`.
    const len = try lengthOfArrayLike(vm, this);
    if (len == 0) return Value.fromBool(false);
    var k = (try resolveFromIndex(vm, args, len)) orelse return Value.fromBool(false);
    while (k < len) : (k += 1) {
        try vm.checkBudget();
        var kb: [24]u8 = undefined;
        const key = std.fmt.bufPrint(&kb, "{d}", .{k}) catch unreachable;
        if (sameValueZero(try vm.getProperty(this, key), target)) return Value.fromBool(true);
    }
    return Value.fromBool(false);
}

pub fn nativeArrayJoin(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const sep_v = argAt(args, 0);
    const sep = if (sep_v.isUndefined()) try vm.makeString(",") else try vm.toStringVal(sep_v);
    try vm.protect(sep);
    defer vm.unprotect();

    const is_real_array = this.isObject() and this.asObject().is_array;
    const len: u64 = if (is_real_array) this.asObject().array_length else try lengthOfArrayLike(vm, this);

    var buf: std.ArrayList(u16) = .empty;
    defer buf.deinit(vm.gpa);
    var i: u64 = 0;
    while (i < len) : (i += 1) {
        try vm.checkBudget();
        if (i > 0) try buf.appendSlice(vm.gpa, sep.asString().units);
        // Holes/absent and null/undefined join as empty.
        const el = if (is_real_array)
            Vm.arrayGetOwn(this.asObject(), @intCast(i)) orelse continue
        else blk: {
            var kb: [24]u8 = undefined;
            const key = std.fmt.bufPrint(&kb, "{d}", .{i}) catch unreachable;
            break :blk try vm.getProperty(this, key);
        };
        if (el.isNullish()) continue;
        const s = try vm.toStringVal(el);
        try vm.protect(s);
        defer vm.unprotect();
        try buf.appendSlice(vm.gpa, s.asString().units);
    }
    return vm.makeStringFromUtf16(buf.items);
}

pub fn nativeArrayToString(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return nativeArrayJoin(ctx, this, args);
}

pub fn nativeArraySlice(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    const len: i64 = @intCast(arr.array_length);
    const start = relativeIndex(try optNumber(vm, argAt(args, 0), 0), len);
    const end = relativeIndex(try optNumber(vm, argAt(args, 1), @floatFromInt(len)), len);
    const count: u32 = if (end > start) @intCast(end - start) else 0;
    const result = try vm.newArray(count);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    var i = start;
    var j: u32 = 0;
    while (i < end) : (i += 1) {
        try vm.checkBudget();
        if (Vm.arrayGetOwn(arr, @intCast(i))) |v| try vm.setArrayElement(result, j, v); // holes preserved
        j += 1;
    }
    return Value.fromObject(result);
}

pub fn nativeArrayConcat(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    const result = try vm.newArray(0);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    try appendArrayElements(vm, result, arr);
    for (args) |a| {
        if (a.isObject() and a.asObject().is_array) {
            try appendArrayElements(vm, result, a.asObject());
        } else {
            try vm.arrayAppend(result, a);
        }
    }
    return Value.fromObject(result);
}

pub fn nativeArrayForEach(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    const cb = argAt(args, 0);
    if (!isCallable(cb)) return vm.throwTypeError("callback is not a function");
    var idxs: std.ArrayList(u32) = .empty;
    defer idxs.deinit(vm.gpa);
    try vm.arrayPresentIndices(arr, &idxs);
    for (idxs.items) |i| {
        const el = Vm.arrayGetOwn(arr, i) orelse continue; // skip holes / deleted-by-callback
        _ = try vm.callValue(cb, Value.undefined_value, &.{ el, Value.fromNumber(@floatFromInt(i)), this });
    }
    return Value.undefined_value;
}

pub fn nativeArrayMap(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    const cb = argAt(args, 0);
    if (!isCallable(cb)) return vm.throwTypeError("callback is not a function");
    const result = try vm.newArray(arr.array_length); // same length; holes preserved
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    var idxs: std.ArrayList(u32) = .empty;
    defer idxs.deinit(vm.gpa);
    try vm.arrayPresentIndices(arr, &idxs);
    for (idxs.items) |i| {
        const el = Vm.arrayGetOwn(arr, i) orelse continue;
        const r = try vm.callValue(cb, Value.undefined_value, &.{ el, Value.fromNumber(@floatFromInt(i)), this });
        try vm.setArrayElement(result, i, r);
    }
    return Value.fromObject(result);
}

pub fn nativeArrayFilter(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    const cb = argAt(args, 0);
    if (!isCallable(cb)) return vm.throwTypeError("callback is not a function");
    const result = try vm.newArray(0);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    var idxs: std.ArrayList(u32) = .empty;
    defer idxs.deinit(vm.gpa);
    try vm.arrayPresentIndices(arr, &idxs);
    for (idxs.items) |i| {
        const el = Vm.arrayGetOwn(arr, i) orelse continue;
        const keep = try vm.callValue(cb, Value.undefined_value, &.{ el, Value.fromNumber(@floatFromInt(i)), this });
        if (toBoolean(keep)) try vm.arrayAppend(result, el);
    }
    return Value.fromObject(result);
}
