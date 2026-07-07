//! Object constructor, Object.prototype, and Object static natives.

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
const arrayIndex = support_mod.arrayIndex;
const castVm = support_mod.castVm;
const isCallable = support_mod.isCallable;
const ownEnumerableKeys = support_mod.ownEnumerableKeys;
const ownPropertyNames = support_mod.ownPropertyNames;
const prim_key = support_mod.prim_key;
const primitiveOwnKeysResult = support_mod.primitiveOwnKeysResult;
const toBoolean = support_mod.toBoolean;

pub fn nativeObject(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    _ = this;
    const v = argAt(args, 0);
    if (v.isObject()) return v;
    if (v.isNullish()) return Value.fromObject(try vm.newObject(vm.object_proto));
    // ToObject for primitives (wrapper objects) is not implemented; return a
    // fresh object so Object(x) at least yields an object.
    return Value.fromObject(try vm.newObject(vm.object_proto));
}

pub fn nativeObjectToString(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const vm = castVm(ctx);
    return switch (this) {
        .undefined => vm.makeString("[object Undefined]"),
        .null => vm.makeString("[object Null]"),
        else => vm.makeString("[object Object]"),
    };
}

pub fn nativeObjectValueOf(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    _ = args;
    return this;
}

pub fn nativeHasOwnProperty(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const key = try vm.toPropertyKey(argAt(args, 0));
    defer vm.gpa.free(key);
    if (this.isString()) {
        // String primitive: indices and `length` are own properties.
        if (std.mem.eql(u8, key, "length")) return Value.fromBool(true);
        if (arrayIndex(key)) |i| return Value.fromBool(i < this.asString().units.len);
        return Value.fromBool(false);
    }
    if (!this.isObject()) return Value.fromBool(false);
    const o = this.asObject();
    if (o.is_array) {
        if (std.mem.eql(u8, key, "length")) return Value.fromBool(true);
        if (arrayIndex(key)) |i| {
            if (Vm.arrayHasOwn(o, i)) return Value.fromBool(true);
        }
    }
    // String wrapper: the boxed string's indices are own properties.
    if (o.properties.get(prim_key)) |d| {
        if (d.value.isString()) {
            if (arrayIndex(key)) |i| return Value.fromBool(i < d.value.asString().units.len);
        }
    }
    return Value.fromBool(o.properties.contains(key));
}

pub fn nativeIsPrototypeOf(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    const v = argAt(args, 0);
    if (!this.isObject() or !v.isObject()) return Value.fromBool(false);
    const target = this.asObject();
    var o: ?*gc.Object = v.asObject().prototype;
    while (o) |cur| {
        if (cur == target) return Value.fromBool(true);
        o = cur.prototype;
    }
    return Value.fromBool(false);
}

pub fn nativeObjectGetPrototypeOf(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    _ = this;
    const v = argAt(args, 0);
    if (!v.isObject()) return vm.throwTypeError("Object.getPrototypeOf called on non-object");
    return if (v.asObject().prototype) |p| Value.fromObject(p) else Value.null_value;
}

pub fn nativeObjectCreate(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    _ = this;
    const proto_arg = argAt(args, 0);
    const proto: ?*gc.Object = if (proto_arg.isObject()) proto_arg.asObject() else if (proto_arg.isNull()) null else return vm.throwTypeError("Object prototype may only be an Object or null");
    return Value.fromObject(try vm.newObject(proto));
}

/// Parse a JS property-descriptor object and define `key` on `obj` with it
/// (shared by Object.defineProperty / Object.defineProperties).
pub fn applyDescriptor(vm: *Vm, obj: *gc.Object, key: []const u8, desc_v: Value) Error!void {
    if (!desc_v.isObject()) return vm.throwTypeError("property descriptor must be an object");
    var desc = gc.PropertyDescriptor{ .enumerable = false, .writable = false, .configurable = false };
    const get_v = try vm.getProperty(desc_v, "get");
    const set_v = try vm.getProperty(desc_v, "set");
    if (get_v.isObject() or set_v.isObject()) {
        desc.is_accessor = true;
        desc.get = if (get_v.isObject()) get_v else null;
        desc.set = if (set_v.isObject()) set_v else null;
    } else {
        desc.value = try vm.getProperty(desc_v, "value");
        desc.writable = toBoolean(try vm.getProperty(desc_v, "writable"));
    }
    desc.enumerable = toBoolean(try vm.getProperty(desc_v, "enumerable"));
    desc.configurable = toBoolean(try vm.getProperty(desc_v, "configurable"));

    const gop = try obj.properties.getOrPut(vm.gpa, key);
    if (!gop.found_existing) gop.key_ptr.* = try vm.gpa.dupe(u8, key);
    gop.value_ptr.* = desc;
}

pub fn nativeObjectDefineProperty(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    _ = this;
    const obj_v = argAt(args, 0);
    if (!obj_v.isObject()) return vm.throwTypeError("Object.defineProperty called on non-object");
    const key = try vm.toPropertyKey(argAt(args, 1));
    defer vm.gpa.free(key);
    try applyDescriptor(vm, obj_v.asObject(), key, argAt(args, 2));
    return obj_v;
}

pub fn nativeObjectDefineProperties(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    _ = this;
    const obj_v = argAt(args, 0);
    if (!obj_v.isObject()) return vm.throwTypeError("Object.defineProperties called on non-object");
    const props_v = argAt(args, 1);
    if (!props_v.isObject()) return vm.throwTypeError("properties argument must be an object");
    var keys: std.ArrayList([]const u8) = .empty;
    defer {
        for (keys.items) |k| vm.gpa.free(k);
        keys.deinit(vm.gpa);
    }
    try ownEnumerableKeys(vm, props_v.asObject(), &keys);
    for (keys.items) |k| {
        try applyDescriptor(vm, obj_v.asObject(), k, try vm.getProperty(props_v, k));
    }
    return obj_v;
}

pub fn nativeObjectPreventExtensions(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    _ = this;
    const v = argAt(args, 0);
    if (v.isObject()) v.asObject().extensible = false;
    return v; // ES2015: non-objects pass through
}

pub fn nativeObjectIsExtensible(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    _ = this;
    const v = argAt(args, 0);
    return Value.fromBool(v.isObject() and v.asObject().extensible);
}

pub fn nativeObjectSeal(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    _ = this;
    const v = argAt(args, 0);
    if (v.isObject()) {
        const o = v.asObject();
        o.extensible = false;
        var it = o.properties.iterator();
        while (it.next()) |entry| entry.value_ptr.configurable = false;
    }
    return v;
}

pub fn nativeObjectIsSealed(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    _ = this;
    const v = argAt(args, 0);
    if (!v.isObject()) return Value.fromBool(true);
    const o = v.asObject();
    if (o.extensible) return Value.fromBool(false);
    var it = o.properties.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.configurable) return Value.fromBool(false);
    }
    return Value.fromBool(true);
}

pub fn nativeObjectFreeze(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    _ = this;
    const v = argAt(args, 0);
    if (v.isObject()) {
        const o = v.asObject();
        o.extensible = false;
        var it = o.properties.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.configurable = false;
            if (!entry.value_ptr.is_accessor) entry.value_ptr.writable = false;
        }
    }
    return v;
}

pub fn nativeObjectIsFrozen(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    _ = this;
    const v = argAt(args, 0);
    if (!v.isObject()) return Value.fromBool(true);
    const o = v.asObject();
    if (o.extensible) return Value.fromBool(false);
    var it = o.properties.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.configurable) return Value.fromBool(false);
        if (!entry.value_ptr.is_accessor and entry.value_ptr.writable) return Value.fromBool(false);
    }
    return Value.fromBool(true);
}

pub fn nativeObjectGetOwnPropertyDescriptor(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    _ = this;
    const obj_v = argAt(args, 0);
    const key = try vm.toPropertyKey(argAt(args, 1));
    defer vm.gpa.free(key);
    if (!obj_v.isObject()) {
        // ES2015 ToObject semantics: null/undefined throw; a string primitive
        // exposes index/length own properties; other primitives have none.
        if (obj_v.isNullish()) return vm.throwTypeError("Object.getOwnPropertyDescriptor called on null or undefined");
        if (obj_v.isString()) {
            const su = obj_v.asString().units;
            if (std.mem.eql(u8, key, "length")) {
                return vm.makeDataDescriptor(Value.fromNumber(@floatFromInt(su.len)), false, false, false);
            }
            if (arrayIndex(key)) |i| {
                if (i < su.len) return vm.makeDataDescriptor(try vm.makeStringFromUtf16(su[i .. i + 1]), false, true, false);
            }
        }
        return Value.undefined_value;
    }
    // Array exotic own properties: indices and `length` don't live in the map.
    const o = obj_v.asObject();
    // String wrapper: indexed own properties read the boxed [[StringData]].
    if (o.properties.get(prim_key)) |d| {
        if (d.value.isString()) {
            if (arrayIndex(key)) |i| {
                const su = d.value.asString().units;
                if (i < su.len) return vm.makeDataDescriptor(try vm.makeStringFromUtf16(su[i .. i + 1]), false, true, false);
                return Value.undefined_value;
            }
        }
    }
    if (o.is_array) {
        if (std.mem.eql(u8, key, "length")) {
            return vm.makeDataDescriptor(Value.fromNumber(@floatFromInt(o.array_length)), true, false, false);
        }
        if (arrayIndex(key)) |i| {
            if (Vm.arrayGetOwn(o, i)) |v| return vm.makeDataDescriptor(v, true, true, true);
            return Value.undefined_value;
        }
    }
    const desc = o.properties.get(key) orelse return Value.undefined_value;
    const result = try vm.newObject(vm.object_proto);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    if (desc.is_accessor) {
        try vm.defineData(result, "get", desc.get orelse Value.undefined_value, true, true, true);
        try vm.defineData(result, "set", desc.set orelse Value.undefined_value, true, true, true);
    } else {
        try vm.defineData(result, "value", desc.value, true, true, true);
        try vm.defineData(result, "writable", Value.fromBool(desc.writable), true, true, true);
    }
    try vm.defineData(result, "enumerable", Value.fromBool(desc.enumerable), true, true, true);
    try vm.defineData(result, "configurable", Value.fromBool(desc.configurable), true, true, true);
    return Value.fromObject(result);
}

pub fn nativeObjectKeys(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const v = argAt(args, 0);
    if (try primitiveOwnKeysResult(vm, v, false)) |r| return r;
    var keys: std.ArrayList([]const u8) = .empty;
    defer {
        for (keys.items) |k| vm.gpa.free(k);
        keys.deinit(vm.gpa);
    }
    try ownEnumerableKeys(vm, v.asObject(), &keys);
    const result = try vm.newArray(0);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    for (keys.items) |k| {
        const s = try vm.makeString(k);
        try vm.arrayAppend(result, s);
    }
    return Value.fromObject(result);
}

pub fn nativeObjectValues(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const v = argAt(args, 0);
    if (v.isNullish()) return vm.throwTypeError("cannot convert null or undefined to object");
    if (!v.isObject()) return Value.fromObject(try vm.newArray(0));
    var keys: std.ArrayList([]const u8) = .empty;
    defer {
        for (keys.items) |k| vm.gpa.free(k);
        keys.deinit(vm.gpa);
    }
    try ownEnumerableKeys(vm, v.asObject(), &keys);
    const result = try vm.newArray(0);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    for (keys.items) |k| {
        const val = try vm.getProperty(v, k);
        try vm.arrayAppend(result, val);
    }
    return Value.fromObject(result);
}

pub fn nativeObjectGetOwnPropertyNames(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const v = argAt(args, 0);
    if (try primitiveOwnKeysResult(vm, v, true)) |r| return r;
    var keys: std.ArrayList([]const u8) = .empty;
    defer {
        for (keys.items) |k| vm.gpa.free(k);
        keys.deinit(vm.gpa);
    }
    try ownPropertyNames(vm, v.asObject(), &keys);
    const result = try vm.newArray(0);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    for (keys.items) |k| {
        const s = try vm.makeString(k);
        try vm.arrayAppend(result, s);
    }
    return Value.fromObject(result);
}

pub fn nativePropertyIsEnumerable(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    if (!this.isObject()) return Value.fromBool(false);
    const key = try vm.toPropertyKey(argAt(args, 0));
    defer vm.gpa.free(key);
    const o = this.asObject();
    if (o.properties.get(key)) |desc| return Value.fromBool(desc.enumerable);
    // A present array index is an enumerable own property.
    if (o.is_array) {
        if (std.fmt.parseInt(u32, key, 10)) |idx| {
            if (Vm.arrayHasOwn(o, idx)) return Value.fromBool(true);
        } else |_| {}
    }
    return Value.fromBool(false);
}

pub fn nativeObjectEntries(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const v = argAt(args, 0);
    if (v.isNullish()) return vm.throwTypeError("cannot convert null or undefined to object");
    if (!v.isObject()) return Value.fromObject(try vm.newArray(0));
    var keys: std.ArrayList([]const u8) = .empty;
    defer {
        for (keys.items) |k| vm.gpa.free(k);
        keys.deinit(vm.gpa);
    }
    try ownEnumerableKeys(vm, v.asObject(), &keys);
    const result = try vm.newArray(0);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    for (keys.items) |k| {
        const pair = try vm.newArray(0);
        try vm.protect(Value.fromObject(pair));
        defer vm.unprotect();
        try vm.arrayAppend(pair, try vm.makeString(k));
        try vm.arrayAppend(pair, try vm.getProperty(v, k));
        try vm.arrayAppend(result, Value.fromObject(pair));
    }
    return Value.fromObject(result);
}

pub fn nativeObjectToLocaleString(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const vm = castVm(ctx);
    const m = try vm.getProperty(this, "toString");
    if (!isCallable(m)) return vm.throwTypeError("toString is not callable");
    return vm.callValue(m, this, &.{});
}
