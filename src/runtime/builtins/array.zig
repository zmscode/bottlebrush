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
const toIntegerOrInfinity = support_mod.toIntegerOrInfinity;
const compareUtf16 = support_mod.compareUtf16;
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

pub fn nativeArrayAt(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    const len: f64 = @floatFromInt(arr.array_length);
    var k = try toIntegerOrInfinity(vm, argAt(args, 0));
    if (k < 0) k += len;
    if (k < 0 or k >= len) return Value.undefined_value;
    return Vm.arrayGetOwn(arr, @intFromFloat(k)) orelse Value.undefined_value;
}

pub fn nativeArrayShift(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    const len = arr.array_length;
    if (len == 0) return Value.undefined_value;
    const first = Vm.arrayGetOwn(arr, 0) orelse Value.undefined_value;
    var i: u32 = 1;
    while (i < len) : (i += 1) {
        try vm.checkBudget();
        if (Vm.arrayGetOwn(arr, i)) |v| {
            try vm.setArrayElement(arr, i - 1, v);
        } else {
            vm.deleteArrayElement(arr, i - 1);
        }
    }
    try vm.setArrayLength(arr, len - 1);
    return first;
}

pub fn nativeArrayUnshift(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    const len = arr.array_length;
    const n: u32 = @intCast(args.len);
    if (n > 0) {
        // Move existing elements up by n (from the top down).
        var i: u32 = len;
        while (i > 0) {
            i -= 1;
            try vm.checkBudget();
            if (Vm.arrayGetOwn(arr, i)) |v| {
                try vm.setArrayElement(arr, i + n, v);
            } else {
                vm.deleteArrayElement(arr, i + n);
            }
        }
        for (args, 0..) |a, j| try vm.setArrayElement(arr, @intCast(j), a);
    }
    try vm.setArrayLength(arr, len + n);
    return Value.fromNumber(@floatFromInt(arr.array_length));
}

pub fn nativeArrayReverse(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    const len = arr.array_length;
    var lo: u32 = 0;
    while (lo * 2 + 1 < len) : (lo += 1) {
        try vm.checkBudget();
        const hi = len - 1 - lo;
        const a = Vm.arrayGetOwn(arr, lo);
        const b = Vm.arrayGetOwn(arr, hi);
        if (b) |v| try vm.setArrayElement(arr, lo, v) else vm.deleteArrayElement(arr, lo);
        if (a) |v| try vm.setArrayElement(arr, hi, v) else vm.deleteArrayElement(arr, hi);
    }
    return this;
}

pub fn nativeArrayFill(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    const len: i64 = @intCast(arr.array_length);
    const value = argAt(args, 0);
    const start = relativeIndex(try optNumber(vm, argAt(args, 1), 0), len);
    const end = relativeIndex(try optNumber(vm, argAt(args, 2), @floatFromInt(len)), len);
    var i = start;
    while (i < end) : (i += 1) {
        try vm.checkBudget();
        try vm.setArrayElement(arr, @intCast(i), value);
    }
    return this;
}

pub fn nativeArrayLastIndexOf(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    const target = argAt(args, 0);
    const len = arr.array_length;
    if (len == 0) return Value.fromNumber(-1);
    var from: i64 = @intCast(len - 1);
    if (args.len >= 2) {
        const n = try toIntegerOrInfinity(vm, args[1]);
        if (n < 0) {
            from = @as(i64, @intCast(len)) + @as(i64, @intFromFloat(@max(n, -9.0e18)));
        } else if (n < @as(f64, @floatFromInt(len))) {
            from = @intFromFloat(n);
        }
    }
    var i = from;
    while (i >= 0) : (i -= 1) {
        try vm.checkBudget();
        if (Vm.arrayGetOwn(arr, @intCast(i))) |v| {
            if (sameTypeStrictEq(v, target)) return Value.fromNumber(@floatFromInt(i));
        }
    }
    return Value.fromNumber(-1);
}

/// Shared driver for the callback predicates. `mode`: 0=some, 1=every,
/// 2=find, 3=findIndex, 4=findLast, 5=findLastIndex.
fn arrayPredicate(vm: *Vm, this: Value, args: []const Value, mode: u8) Error!Value {
    const arr = try thisArray(vm, this);
    const cb = argAt(args, 0);
    if (!isCallable(cb)) return vm.throwTypeError("callback is not a function");
    const this_arg = argAt(args, 1);
    const len = arr.array_length;
    const backwards = mode == 4 or mode == 5;
    const skip_holes = mode == 0 or mode == 1; // some/every skip holes; find* don't
    var step: u32 = 0;
    while (step < len) : (step += 1) {
        try vm.checkBudget();
        const i = if (backwards) len - 1 - step else step;
        const own = Vm.arrayGetOwn(arr, i);
        if (own == null and skip_holes) continue;
        const el = own orelse Value.undefined_value;
        const r = try vm.callValue(cb, this_arg, &.{ el, Value.fromNumber(@floatFromInt(i)), this });
        const hit = toBoolean(r);
        switch (mode) {
            0 => if (hit) return Value.fromBool(true),
            1 => if (!hit) return Value.fromBool(false),
            2, 4 => if (hit) return el,
            3, 5 => if (hit) return Value.fromNumber(@floatFromInt(i)),
            else => unreachable,
        }
    }
    return switch (mode) {
        0 => Value.fromBool(false),
        1 => Value.fromBool(true),
        2, 4 => Value.undefined_value,
        3, 5 => Value.fromNumber(-1),
        else => unreachable,
    };
}

pub fn nativeArraySome(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return arrayPredicate(castVm(ctx), this, args, 0);
}
pub fn nativeArrayEvery(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return arrayPredicate(castVm(ctx), this, args, 1);
}
pub fn nativeArrayFind(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return arrayPredicate(castVm(ctx), this, args, 2);
}
pub fn nativeArrayFindIndex(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return arrayPredicate(castVm(ctx), this, args, 3);
}
pub fn nativeArrayFindLast(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return arrayPredicate(castVm(ctx), this, args, 4);
}
pub fn nativeArrayFindLastIndex(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return arrayPredicate(castVm(ctx), this, args, 5);
}

fn arrayReduceImpl(vm: *Vm, this: Value, args: []const Value, backwards: bool) Error!Value {
    const arr = try thisArray(vm, this);
    const cb = argAt(args, 0);
    if (!isCallable(cb)) return vm.throwTypeError("callback is not a function");
    const len = arr.array_length;
    var acc: Value = Value.undefined_value;
    var have_acc = args.len >= 2;
    if (have_acc) acc = args[1];
    var step: u32 = 0;
    while (step < len) : (step += 1) {
        try vm.checkBudget();
        const i = if (backwards) len - 1 - step else step;
        const own = Vm.arrayGetOwn(arr, i) orelse continue; // reduce skips holes
        if (!have_acc) {
            acc = own;
            have_acc = true;
            continue;
        }
        try vm.protect(acc);
        defer vm.unprotect();
        acc = try vm.callValue(cb, Value.undefined_value, &.{ acc, own, Value.fromNumber(@floatFromInt(i)), this });
    }
    if (!have_acc) return vm.throwTypeError("reduce of empty array with no initial value");
    return acc;
}

pub fn nativeArrayReduce(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return arrayReduceImpl(castVm(ctx), this, args, false);
}
pub fn nativeArrayReduceRight(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return arrayReduceImpl(castVm(ctx), this, args, true);
}

pub fn nativeArraySplice(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    const len: i64 = @intCast(arr.array_length);
    const start = relativeIndex(try optNumber(vm, argAt(args, 0), 0), len);
    const delete_count: i64 = if (args.len < 1)
        0
    else if (args.len < 2)
        len - start
    else blk: {
        const dc = try toIntegerOrInfinity(vm, args[1]);
        break :blk @max(0, @min(@as(i64, @intFromFloat(@min(dc, 4294967295.0))), len - start));
    };
    const items: []const Value = if (args.len > 2) args[2..] else &.{};

    // Removed elements become the result array.
    const removed = try vm.newArray(0);
    try vm.protect(Value.fromObject(removed));
    defer vm.unprotect();
    var i: i64 = 0;
    while (i < delete_count) : (i += 1) {
        try vm.checkBudget();
        if (Vm.arrayGetOwn(arr, @intCast(start + i))) |v| {
            try vm.setArrayElement(removed, @intCast(i), v);
        }
    }
    try vm.setArrayLength(removed, @intCast(delete_count));

    const shift: i64 = @as(i64, @intCast(items.len)) - delete_count;
    if (shift < 0) {
        // Close the gap left-to-right.
        var k = start + delete_count;
        while (k < len) : (k += 1) {
            try vm.checkBudget();
            if (Vm.arrayGetOwn(arr, @intCast(k))) |v| {
                try vm.setArrayElement(arr, @intCast(k + shift), v);
            } else {
                vm.deleteArrayElement(arr, @intCast(k + shift));
            }
        }
    } else if (shift > 0) {
        // Open a gap right-to-left.
        var k = len;
        while (k > start + delete_count) {
            k -= 1;
            try vm.checkBudget();
            if (Vm.arrayGetOwn(arr, @intCast(k))) |v| {
                try vm.setArrayElement(arr, @intCast(k + shift), v);
            } else {
                vm.deleteArrayElement(arr, @intCast(k + shift));
            }
        }
    }
    for (items, 0..) |item, j| {
        try vm.setArrayElement(arr, @intCast(start + @as(i64, @intCast(j))), item);
    }
    try vm.setArrayLength(arr, @intCast(len + shift));
    return Value.fromObject(removed);
}

pub fn nativeArraySort(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    const cmp = argAt(args, 0);
    if (!cmp.isUndefined() and !isCallable(cmp)) return vm.throwTypeError("comparator is not a function");
    const len = arr.array_length;

    // Gather present values into a protected scratch array (GC-visible).
    const tmp = try vm.newArray(0);
    try vm.protect(Value.fromObject(tmp));
    defer vm.unprotect();
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        if (Vm.arrayGetOwn(arr, i)) |v| try vm.arrayAppend(tmp, v);
    }
    const count = tmp.array_length;

    // Stable insertion sort with the JS comparator (undefined sorts last;
    // default order compares ToString).
    var a: u32 = 1;
    while (a < count) : (a += 1) {
        var b = a;
        while (b > 0) : (b -= 1) {
            try vm.checkBudget();
            const x = Vm.arrayGetOwn(tmp, b - 1).?;
            const y = Vm.arrayGetOwn(tmp, b).?;
            if (!(try sortGreater(vm, cmp, x, y))) break;
            try vm.setArrayElement(tmp, b - 1, y);
            try vm.setArrayElement(tmp, b, x);
        }
    }

    // Write back: sorted values first, holes (absent) trail.
    i = 0;
    while (i < count) : (i += 1) try vm.setArrayElement(arr, i, Vm.arrayGetOwn(tmp, i).?);
    while (i < len) : (i += 1) vm.deleteArrayElement(arr, i);
    return this;
}

/// True when `x` must sort after `y`.
fn sortGreater(vm: *Vm, cmp: Value, x: Value, y: Value) Error!bool {
    if (x.isUndefined()) return !y.isUndefined(); // undefined sorts last
    if (y.isUndefined()) return false;
    if (!cmp.isUndefined()) {
        const r = try vm.callValue(cmp, Value.undefined_value, &.{ x, y });
        const num = try vm.toNumber(r);
        return num > 0;
    }
    const xs = try vm.toStringVal(x);
    try vm.protect(xs);
    defer vm.unprotect();
    const ys = try vm.toStringVal(y);
    return compareUtf16(xs.asString().units, ys.asString().units) > 0;
}

pub fn nativeArrayCopyWithin(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    const len: i64 = @intCast(arr.array_length);
    var target = relativeIndex(try optNumber(vm, argAt(args, 0), 0), len);
    var start = relativeIndex(try optNumber(vm, argAt(args, 1), 0), len);
    const end = relativeIndex(try optNumber(vm, argAt(args, 2), @floatFromInt(len)), len);
    var count = @min(end - start, len - target);
    if (count <= 0) return this;
    if (start < target and target < start + count) {
        // Overlapping: copy backwards.
        start += count - 1;
        target += count - 1;
        while (count > 0) : (count -= 1) {
            try vm.checkBudget();
            if (Vm.arrayGetOwn(arr, @intCast(start))) |v| {
                try vm.setArrayElement(arr, @intCast(target), v);
            } else {
                vm.deleteArrayElement(arr, @intCast(target));
            }
            start -= 1;
            target -= 1;
        }
    } else {
        while (count > 0) : (count -= 1) {
            try vm.checkBudget();
            if (Vm.arrayGetOwn(arr, @intCast(start))) |v| {
                try vm.setArrayElement(arr, @intCast(target), v);
            } else {
                vm.deleteArrayElement(arr, @intCast(target));
            }
            start += 1;
            target += 1;
        }
    }
    return this;
}

fn flattenInto(vm: *Vm, dst: *gc.Object, src: *gc.Object, depth: f64) Error!void {
    const n = src.array_length;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        try vm.checkBudget();
        const v = Vm.arrayGetOwn(src, i) orelse continue; // flat skips holes
        if (depth > 0 and v.isObject() and v.asObject().is_array) {
            try flattenInto(vm, dst, v.asObject(), depth - 1);
        } else {
            try vm.arrayAppend(dst, v);
        }
    }
}

pub fn nativeArrayFlat(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    const depth: f64 = if (argAt(args, 0).isUndefined()) 1 else try toIntegerOrInfinity(vm, args[0]);
    const result = try vm.newArray(0);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    try flattenInto(vm, result, arr, depth);
    return Value.fromObject(result);
}

pub fn nativeArrayFlatMap(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    const cb = argAt(args, 0);
    if (!isCallable(cb)) return vm.throwTypeError("callback is not a function");
    const result = try vm.newArray(0);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    const n = arr.array_length;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        try vm.checkBudget();
        const v = Vm.arrayGetOwn(arr, i) orelse continue;
        const mapped = try vm.callValue(cb, Value.undefined_value, &.{ v, Value.fromNumber(@floatFromInt(i)), this });
        if (mapped.isObject() and mapped.asObject().is_array) {
            try vm.protect(mapped);
            defer vm.unprotect();
            try flattenInto(vm, result, mapped.asObject(), 0);
        } else {
            try vm.arrayAppend(result, mapped);
        }
    }
    return Value.fromObject(result);
}

pub fn nativeArrayOf(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const result = try vm.newArray(0);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    for (args) |a| try vm.arrayAppend(result, a);
    return Value.fromObject(result);
}

pub fn nativeArrayFrom(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const src = argAt(args, 0);
    const map_fn = argAt(args, 1);
    if (!map_fn.isUndefined() and !isCallable(map_fn)) return vm.throwTypeError("Array.from mapFn is not a function");
    const result = try vm.newArray(0);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();

    // Iterable path (arrays, strings, Maps, Sets, custom @@iterator).
    if (vm.getIterator(src)) |iter| {
        try vm.protect(iter);
        defer vm.unprotect();
        var i: u32 = 0;
        while (true) : (i += 1) {
            try vm.checkBudget();
            const r = try vm.iteratorNext(iter);
            if (toBoolean(try vm.getProperty(r, "done"))) break;
            var v = try vm.getProperty(r, "value");
            if (!map_fn.isUndefined()) {
                try vm.protect(v);
                defer vm.unprotect();
                v = try vm.callValue(map_fn, Value.undefined_value, &.{ v, Value.fromNumber(@floatFromInt(i)) });
            }
            try vm.arrayAppend(result, v);
        }
        return Value.fromObject(result);
    } else |_| {
        vm.pending_exception = null; // not iterable: fall through to array-like
    }

    // Array-like path (length + indexed gets).
    const len = try lengthOfArrayLike(vm, src);
    var k: u64 = 0;
    while (k < len) : (k += 1) {
        try vm.checkBudget();
        var kb: [24]u8 = undefined;
        const key = std.fmt.bufPrint(&kb, "{d}", .{k}) catch unreachable;
        var v = try vm.getProperty(src, key);
        if (!map_fn.isUndefined()) {
            try vm.protect(v);
            defer vm.unprotect();
            v = try vm.callValue(map_fn, Value.undefined_value, &.{ v, Value.fromNumber(@floatFromInt(k)) });
        }
        try vm.arrayAppend(result, v);
    }
    return Value.fromObject(result);
}
