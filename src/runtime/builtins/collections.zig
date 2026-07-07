//! Map and Set natives (SameValueZero keyed, insertion ordered).

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
const isCallable = support_mod.isCallable;
const sameValueZero = support_mod.sameValueZero;
const thisCollection = support_mod.thisCollection;

/// Index of `key` in a Map's interleaved entries (the key slot), or null.
pub fn mapFind(map: *gc.Object, key: Value) ?usize {
    var i: usize = 0;
    while (i < map.elements.items.len) : (i += 2) {
        if (sameValueZero(map.elements.items[i], key)) return i;
    }
    return null;
}

pub fn setFind(set: *gc.Object, value: Value) ?usize {
    for (set.elements.items, 0..) |v, i| {
        if (sameValueZero(v, value)) return i;
    }
    return null;
}

pub fn nativeMap(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const map = try vm.newMap();
    try vm.protect(Value.fromObject(map));
    defer vm.unprotect();
    // Optional iterable of [key, value] pairs (arrays only, for now).
    const init_v = argAt(args, 0);
    if (init_v.isObject() and init_v.asObject().is_array) {
        for (init_v.asObject().elements.items) |entry| {
            if (entry.isObject() and entry.asObject().is_array) {
                const e = entry.asObject().elements.items;
                const k = if (e.len > 0) e[0] else Value.undefined_value;
                const val = if (e.len > 1) e[1] else Value.undefined_value;
                if (mapFind(map, k)) |idx| {
                    map.elements.items[idx + 1] = val;
                } else {
                    try map.elements.append(vm.gpa, k);
                    try map.elements.append(vm.gpa, val);
                }
            }
        }
    }
    return Value.fromObject(map);
}

pub fn nativeMapGet(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const map = try thisCollection(vm, this, .map);
    if (mapFind(map, argAt(args, 0))) |i| return map.elements.items[i + 1];
    return Value.undefined_value;
}

pub fn nativeMapSet(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const map = try thisCollection(vm, this, .map);
    const key = argAt(args, 0);
    const val = argAt(args, 1);
    if (mapFind(map, key)) |i| {
        map.elements.items[i + 1] = val;
    } else {
        try map.elements.append(vm.gpa, key);
        try map.elements.append(vm.gpa, val);
    }
    return this;
}

pub fn nativeMapHas(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const map = try thisCollection(vm, this, .map);
    return Value.fromBool(mapFind(map, argAt(args, 0)) != null);
}

pub fn nativeMapDelete(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const map = try thisCollection(vm, this, .map);
    if (mapFind(map, argAt(args, 0))) |i| {
        _ = map.elements.orderedRemove(i); // key
        _ = map.elements.orderedRemove(i); // value (shifted into i)
        return Value.fromBool(true);
    }
    return Value.fromBool(false);
}

pub fn nativeMapSize(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const vm = castVm(ctx);
    const map = try thisCollection(vm, this, .map);
    return Value.fromNumber(@floatFromInt(map.elements.items.len / 2));
}

pub fn nativeMapForEach(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const map = try thisCollection(vm, this, .map);
    const cb = argAt(args, 0);
    if (!isCallable(cb)) return vm.throwTypeError("callback is not a function");
    var i: usize = 0;
    while (i + 1 < map.elements.items.len) : (i += 2) {
        const k = map.elements.items[i];
        const v = map.elements.items[i + 1];
        _ = try vm.callValue(cb, Value.undefined_value, &.{ v, k, this });
    }
    return Value.undefined_value;
}

pub fn nativeSet(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const set = try vm.newSet();
    try vm.protect(Value.fromObject(set));
    defer vm.unprotect();
    const init_v = argAt(args, 0);
    if (init_v.isObject() and init_v.asObject().is_array) {
        for (init_v.asObject().elements.items) |v| {
            if (setFind(set, v) == null) try set.elements.append(vm.gpa, v);
        }
    }
    return Value.fromObject(set);
}

pub fn nativeSetAdd(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const set = try thisCollection(vm, this, .set);
    const v = argAt(args, 0);
    if (setFind(set, v) == null) try set.elements.append(vm.gpa, v);
    return this;
}

pub fn nativeSetHas(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const set = try thisCollection(vm, this, .set);
    return Value.fromBool(setFind(set, argAt(args, 0)) != null);
}

pub fn nativeSetDelete(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const set = try thisCollection(vm, this, .set);
    if (setFind(set, argAt(args, 0))) |i| {
        _ = set.elements.orderedRemove(i);
        return Value.fromBool(true);
    }
    return Value.fromBool(false);
}

pub fn nativeSetSize(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const vm = castVm(ctx);
    const set = try thisCollection(vm, this, .set);
    return Value.fromNumber(@floatFromInt(set.elements.items.len));
}

pub fn nativeSetForEach(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const set = try thisCollection(vm, this, .set);
    const cb = argAt(args, 0);
    if (!isCallable(cb)) return vm.throwTypeError("callback is not a function");
    var i: usize = 0;
    while (i < set.elements.items.len) : (i += 1) {
        const v = set.elements.items[i];
        _ = try vm.callValue(cb, Value.undefined_value, &.{ v, v, this });
    }
    return Value.undefined_value;
}

pub fn nativeCollectionClear(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    _ = args;
    if (this.isObject()) this.asObject().elements.clearRetainingCapacity();
    return Value.undefined_value;
}
