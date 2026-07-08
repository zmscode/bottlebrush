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
    switch (this) {
        .undefined => return vm.makeString("[object Undefined]"),
        .null => return vm.makeString("[object Null]"),
        else => {},
    }
    // A string-valued @@toStringTag overrides the builtin tag.
    if (this.isObject() and vm.symbol_to_string_tag_key.len != 0) {
        const tag = try vm.getProperty(this, vm.symbol_to_string_tag_key);
        if (tag.isString()) {
            try vm.protect(tag);
            defer vm.unprotect();
            var out: std.ArrayList(u16) = .empty;
            defer out.deinit(vm.gpa);
            for ("[object ") |c| try out.append(vm.gpa, c);
            try out.appendSlice(vm.gpa, tag.asString().units);
            try out.append(vm.gpa, ']');
            return vm.makeStringFromUtf16(out.items);
        }
    }
    const builtin_tag: []const u8 = blk: {
        if (this.isString()) break :blk "String";
        if (this.isNumber()) break :blk "Number";
        if (this.isBoolean()) break :blk "Boolean";
        if (!this.isObject()) break :blk "Object";
        const o = this.asObject();
        if (o.is_array) break :blk "Array";
        if (o.callable != null) break :blk "Function";
        if (o.regex != null) break :blk "RegExp";
        if (o.properties.contains("\x00DateValue")) break :blk "Date";
        if (o.properties.contains(prim_key)) {
            const d = o.properties.get(prim_key).?;
            if (d.value.isString()) break :blk "String";
            if (d.value.isNumber()) break :blk "Number";
            if (d.value.isBoolean()) break :blk "Boolean";
        }
        if (o.prototype == vm.error_proto or (o.prototype != null and o.prototype.?.prototype == vm.error_proto)) break :blk "Error";
        break :blk "Object";
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.gpa);
    try out.appendSlice(vm.gpa, "[object ");
    try out.appendSlice(vm.gpa, builtin_tag);
    try out.append(vm.gpa, ']');
    return vm.makeString(out.items);
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

/// If `o` is a live proxy, returns its target+handler; throws when revoked.
pub fn proxyParts(vm: *Vm, o: *gc.Object) Error!?struct { target: *gc.Object, handler: *gc.Object } {
    const t = o.proxy_target orelse return null;
    if (o.proxy_revoked) return vm.throwTypeError("cannot perform operation on a revoked proxy");
    return .{ .target = t, .handler = o.proxy_handler.? };
}

/// Fetch a trap function from a proxy handler, or null to forward.
fn proxyTrap(vm: *Vm, handler: *gc.Object, name: []const u8) Error!?Value {
    const trap = try vm.getProperty(Value.fromObject(handler), name);
    if (isCallable(trap)) return trap;
    if (!trap.isUndefined() and !trap.isNull()) return vm.throwTypeError("proxy trap is not a function");
    return null;
}

pub fn nativeObjectGetPrototypeOf(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    _ = this;
    const v = argAt(args, 0);
    if (!v.isObject()) return vm.throwTypeError("Object.getPrototypeOf called on non-object");
    if (try proxyParts(vm, v.asObject())) |p| {
        if (try proxyTrap(vm, p.handler, "getPrototypeOf")) |trap| {
            const r = try vm.callValue(trap, Value.fromObject(p.handler), &.{Value.fromObject(p.target)});
            if (!r.isObject() and !r.isNull()) return vm.throwTypeError("proxy getPrototypeOf must return an object or null");
            return r;
        }
        return nativeObjectGetPrototypeOf(ctx, Value.undefined_value, &.{Value.fromObject(p.target)});
    }
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
    // Proxy: dispatch to the defineProperty trap (falsy result throws).
    if (try proxyParts(vm, obj)) |p| {
        if (try proxyTrap(vm, p.handler, "defineProperty")) |trap| {
            const ks = try vm.makeString(key);
            try vm.protect(ks);
            defer vm.unprotect();
            const r = try vm.callValue(trap, Value.fromObject(p.handler), &.{ Value.fromObject(p.target), ks, desc_v });
            if (!toBoolean(r)) return vm.throwTypeError("proxy defineProperty trap returned falsy");
            return;
        }
        return applyDescriptor(vm, p.target, key, desc_v);
    }
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

    // Mapped-arguments interaction (spec 10.4.4.2): an accessor or a
    // writable:false redefinition severs the parameter alias; a plain value
    // redefinition writes through it and stays mapped.
    if (obj.args_env != null) {
        if (support_mod.arrayIndex(key)) |i| {
            if (i < 64 and (obj.args_map >> @intCast(i)) & 1 == 1) {
                if (has_get or has_set or (has_writable and !v_writable)) {
                    if (has_value) obj.args_env.?.slots[i] = v_value;
                    obj.args_map &= ~(@as(u64, 1) << @intCast(i));
                } else if (has_value) {
                    obj.args_env.?.slots[i] = v_value;
                }
            }
        }
    }

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
    const vm = castVm(ctx);
    _ = this;
    const v = argAt(args, 0);
    if (v.isObject()) {
        if (try proxyParts(vm, v.asObject())) |p| {
            if (try proxyTrap(vm, p.handler, "preventExtensions")) |trap| {
                const r = try vm.callValue(trap, Value.fromObject(p.handler), &.{Value.fromObject(p.target)});
                if (!toBoolean(r)) return vm.throwTypeError("proxy preventExtensions trap returned falsy");
                return v;
            }
            p.target.extensible = false;
            return v;
        }
        v.asObject().extensible = false;
    }
    return v; // ES2015: non-objects pass through
}

pub fn nativeObjectIsExtensible(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    _ = this;
    const v = argAt(args, 0);
    if (v.isObject()) {
        if (try proxyParts(vm, v.asObject())) |p| {
            if (try proxyTrap(vm, p.handler, "isExtensible")) |trap| {
                const r = try vm.callValue(trap, Value.fromObject(p.handler), &.{Value.fromObject(p.target)});
                const answer = toBoolean(r);
                // Invariant: must agree with the target.
                if (answer != p.target.extensible) {
                    return vm.throwTypeError("proxy isExtensible must match the target's extensibility");
                }
                return Value.fromBool(answer);
            }
            return Value.fromBool(p.target.extensible);
        }
    }
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
    // Proxy: dispatch to the getOwnPropertyDescriptor trap.
    if (try proxyParts(vm, o)) |p| {
        if (try proxyTrap(vm, p.handler, "getOwnPropertyDescriptor")) |trap| {
            const ks = try vm.makeString(key);
            try vm.protect(ks);
            defer vm.unprotect();
            const r = try vm.callValue(trap, Value.fromObject(p.handler), &.{ Value.fromObject(p.target), ks });
            if (!r.isObject() and !r.isUndefined()) {
                return vm.throwTypeError("proxy getOwnPropertyDescriptor must return an object or undefined");
            }
            return r;
        }
        return nativeObjectGetOwnPropertyDescriptor(ctx, Value.undefined_value, &.{ Value.fromObject(p.target), argAt(args, 1) });
    }
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

/// OrdinarySetPrototypeOf with the spec's cycle check.
fn setPrototypeChecked(vm: *Vm, obj: *gc.Object, proto_v: Value) Error!void {
    const new_proto: ?*gc.Object = if (proto_v.isNull()) null else if (proto_v.isObject()) proto_v.asObject() else return vm.throwTypeError("prototype must be an object or null");
    // Proxy: dispatch to the setPrototypeOf trap (falsy result throws).
    if (try proxyParts(vm, obj)) |p| {
        if (try proxyTrap(vm, p.handler, "setPrototypeOf")) |trap| {
            const r = try vm.callValue(trap, Value.fromObject(p.handler), &.{ Value.fromObject(p.target), proto_v });
            if (!toBoolean(r)) return vm.throwTypeError("proxy setPrototypeOf trap returned falsy");
            return;
        }
        return setPrototypeChecked(vm, p.target, proto_v);
    }
    if (!obj.extensible) return vm.throwTypeError("cannot set prototype of a non-extensible object");
    // Reject prototype cycles.
    var p = new_proto;
    while (p) |cur| {
        if (cur == obj) return vm.throwTypeError("cyclic prototype chain");
        p = cur.prototype;
    }
    obj.prototype = new_proto;
}

pub fn nativeObjectSetPrototypeOf(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const target = argAt(args, 0);
    if (target.isNullish()) return vm.throwTypeError("Object.setPrototypeOf called on null or undefined");
    if (!target.isObject()) return target; // primitives pass through
    try setPrototypeChecked(vm, target.asObject(), argAt(args, 1));
    return target;
}

pub fn nativeProtoGetter(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const vm = castVm(ctx);
    if (this.isNullish()) return vm.throwTypeError("cannot read __proto__ of null or undefined");
    if (!this.isObject()) {
        // Primitives report their wrapper prototype.
        if (this.isString()) return if (vm.string_proto) |p| Value.fromObject(p) else Value.null_value;
        if (this.isNumber()) return if (vm.number_proto) |p| Value.fromObject(p) else Value.null_value;
        if (this.isBoolean()) return if (vm.boolean_proto) |p| Value.fromObject(p) else Value.null_value;
        return Value.null_value;
    }
    return if (this.asObject().prototype) |p| Value.fromObject(p) else Value.null_value;
}

pub fn nativeProtoSetter(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    if (!this.isObject()) return Value.undefined_value; // primitives: no-op
    const v = argAt(args, 0);
    if (!v.isNull() and !v.isObject()) return Value.undefined_value; // non-object values ignored
    try setPrototypeChecked(vm, this.asObject(), v);
    return Value.undefined_value;
}

pub fn nativeObjectAssign(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const target = argAt(args, 0);
    if (target.isNullish()) return vm.throwTypeError("Object.assign target must be an object");
    if (!target.isObject()) return target;
    for (args[1..]) |src| {
        if (src.isNullish()) continue;
        if (!src.isObject()) {
            // Strings contribute their indices; other primitives nothing.
            if (src.isString()) {
                const units = src.asString().units;
                var i: usize = 0;
                var kb: [16]u8 = undefined;
                while (i < units.len) : (i += 1) {
                    const key = std.fmt.bufPrint(&kb, "{d}", .{i}) catch unreachable;
                    const cv = try vm.makeStringFromUtf16(units[i .. i + 1]);
                    try vm.setProperty(target, key, cv);
                }
            }
            continue;
        }
        var keys: std.ArrayList([]const u8) = .empty;
        defer {
            for (keys.items) |k| vm.gpa.free(k);
            keys.deinit(vm.gpa);
        }
        try ownEnumerableKeys(vm, src.asObject(), &keys);
        for (keys.items) |k| {
            const v = try vm.getProperty(src, k);
            try vm.protect(v);
            defer vm.unprotect();
            try vm.setProperty(target, k, v);
        }
    }
    return target;
}

pub fn nativeObjectIs(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    _ = this;
    return Value.fromBool(sameValue(argAt(args, 0), argAt(args, 1)));
}

pub fn nativeObjectHasOwn(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const target = argAt(args, 0);
    if (target.isNullish()) return vm.throwTypeError("Object.hasOwn called on null or undefined");
    // Reuse hasOwnProperty's exotic-aware logic with `this` = target.
    return nativeHasOwnProperty(ctx, target, args[1..]);
}

pub fn nativeObjectFromEntries(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const result = try vm.newObject(vm.object_proto);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    const iter = try vm.getIterator(argAt(args, 0));
    try vm.protect(iter);
    defer vm.unprotect();
    while (true) {
        const r = try vm.iteratorNext(iter);
        if (toBoolean(try vm.getProperty(r, "done"))) break;
        const entry = try vm.getProperty(r, "value");
        if (!entry.isObject()) return vm.throwTypeError("Object.fromEntries entry is not an object");
        try vm.protect(entry);
        defer vm.unprotect();
        const k = try vm.toPropertyKey(try vm.getProperty(entry, "0"));
        defer vm.gpa.free(k);
        const v = try vm.getProperty(entry, "1");
        try vm.defineData(result, k, v, true, true, true);
    }
    return Value.fromObject(result);
}

pub fn nativeObjectGetOwnPropertyDescriptors(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const obj_v = argAt(args, 0);
    if (obj_v.isNullish()) return vm.throwTypeError("Object.getOwnPropertyDescriptors called on null or undefined");
    const result = try vm.newObject(vm.object_proto);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    if (!obj_v.isObject()) return Value.fromObject(result); // primitives: empty (strings elided)
    var keys: std.ArrayList([]const u8) = .empty;
    defer {
        for (keys.items) |k| vm.gpa.free(k);
        keys.deinit(vm.gpa);
    }
    try ownPropertyNames(vm, obj_v.asObject(), &keys);
    for (keys.items) |k| {
        const ks = try vm.makeString(k);
        try vm.protect(ks);
        defer vm.unprotect();
        const desc = try nativeObjectGetOwnPropertyDescriptor(ctx, this, &.{ obj_v, ks });
        if (desc.isUndefined()) continue;
        try vm.defineData(result, k, desc, true, true, true);
    }
    return Value.fromObject(result);
}
