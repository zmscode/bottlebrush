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
const sameValue = support_mod.sameValue;
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
    const d = desc_v.asObject();

    // Which fields the descriptor actually mentions (partial descriptors merge).
    const has_value = vm.hasProperty(d, "value");
    const has_writable = vm.hasProperty(d, "writable");
    const has_get = vm.hasProperty(d, "get");
    const has_set = vm.hasProperty(d, "set");
    const has_enumerable = vm.hasProperty(d, "enumerable");
    const has_configurable = vm.hasProperty(d, "configurable");
    if ((has_value or has_writable) and (has_get or has_set)) {
        return vm.throwTypeError("property descriptor cannot be both a data and an accessor descriptor");
    }

    const v_value = if (has_value) try vm.getProperty(desc_v, "value") else Value.undefined_value;
    const v_writable = if (has_writable) toBoolean(try vm.getProperty(desc_v, "writable")) else false;
    const v_get = if (has_get) try vm.getProperty(desc_v, "get") else Value.undefined_value;
    const v_set = if (has_set) try vm.getProperty(desc_v, "set") else Value.undefined_value;
    if (has_get and !v_get.isUndefined() and !isCallable(v_get)) return vm.throwTypeError("getter must be a function");
    if (has_set and !v_set.isUndefined() and !isCallable(v_set)) return vm.throwTypeError("setter must be a function");
    const v_enumerable = if (has_enumerable) toBoolean(try vm.getProperty(desc_v, "enumerable")) else false;
    const v_configurable = if (has_configurable) toBoolean(try vm.getProperty(desc_v, "configurable")) else false;
    const accessor_req = has_get or has_set;

    if (obj.properties.getPtr(key)) |ex| {
        // ValidateAndApplyPropertyDescriptor over an existing property.
        if (!ex.configurable) {
            if (has_configurable and v_configurable)
                return vm.throwTypeError("cannot redefine non-configurable property");
            if (has_enumerable and v_enumerable != ex.enumerable)
                return vm.throwTypeError("cannot change enumerability of non-configurable property");
            if ((accessor_req and !ex.is_accessor) or ((has_value or has_writable) and ex.is_accessor))
                return vm.throwTypeError("cannot change the kind of a non-configurable property");
            if (ex.is_accessor) {
                const ex_get = ex.get orelse Value.undefined_value;
                const ex_set = ex.set orelse Value.undefined_value;
                if (has_get and !sameValue(v_get, ex_get))
                    return vm.throwTypeError("cannot redefine getter of non-configurable property");
                if (has_set and !sameValue(v_set, ex_set))
                    return vm.throwTypeError("cannot redefine setter of non-configurable property");
            } else if (!ex.writable) {
                if (has_writable and v_writable)
                    return vm.throwTypeError("cannot make non-configurable read-only property writable");
                if (has_value and !sameValue(v_value, ex.value))
                    return vm.throwTypeError("cannot change value of non-configurable read-only property");
            }
        }
        // Apply: convert kinds first, then merge only the present fields.
        if (accessor_req and !ex.is_accessor) {
            ex.is_accessor = true;
            ex.get = null;
            ex.set = null;
            ex.value = Value.undefined_value;
            ex.writable = false;
        } else if ((has_value or has_writable) and ex.is_accessor) {
            ex.is_accessor = false;
            ex.get = null;
            ex.set = null;
            ex.value = Value.undefined_value;
            ex.writable = false;
        }
        if (has_value) ex.value = v_value;
        if (has_writable) ex.writable = v_writable;
        if (has_get) ex.get = if (v_get.isUndefined()) null else v_get;
        if (has_set) ex.set = if (v_set.isUndefined()) null else v_set;
        if (has_enumerable) ex.enumerable = v_enumerable;
        if (has_configurable) ex.configurable = v_configurable;
        return;
    }

    // New property: absent fields default to false/undefined.
    if (!obj.extensible) return vm.throwTypeError("cannot define property on non-extensible object");
    var desc = gc.PropertyDescriptor{
        .enumerable = v_enumerable,
        .writable = v_writable,
        .configurable = v_configurable,
    };
    if (accessor_req) {
        desc.is_accessor = true;
        desc.get = if (has_get and !v_get.isUndefined()) v_get else null;
        desc.set = if (has_set and !v_set.isUndefined()) v_set else null;
    } else {
        desc.value = v_value;
    }
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
