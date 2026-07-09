//! Symbol, Reflect, and Proxy natives.

const std = @import("std");
const gc = @import("../../gc.zig");
const bc = @import("../../bytecode.zig");
const bilby = @import("bilby");
const Value = @import("../../value.zig").Value;
const interpreter = @import("../../interpreter.zig");
const Vm = interpreter.Vm;
const Error = interpreter.Error;

const support_mod = @import("../support.zig");
const object_mod = @import("object.zig");
const argAt = support_mod.argAt;
const castVm = support_mod.castVm;
const isConstructorValue = support_mod.isConstructorValue;
const utf16ToUtf8Alloc = support_mod.utf16ToUtf8Alloc;

pub fn nativeSymbol(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    // Symbol is not a constructor.
    if (this.isObject() and this.asObject().prototype == vm.symbol_proto) {
        return vm.throwTypeError("Symbol is not a constructor");
    }
    const desc_v = argAt(args, 0);
    if (desc_v.isUndefined()) return vm.makeSymbol(null);
    const s = try vm.toStringVal(desc_v);
    try vm.protect(s);
    defer vm.unprotect();
    const utf8 = try utf16ToUtf8Alloc(vm.gpa, s.asString().units);
    defer vm.gpa.free(utf8);
    return vm.makeSymbol(utf8);
}

pub fn nativeSymbolToString(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const vm = castVm(ctx);
    if (!this.isSymbol()) return vm.throwTypeError("Symbol.prototype.toString called on non-symbol");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(vm.gpa);
    try buf.appendSlice(vm.gpa, "Symbol(");
    if (this.asSymbol().description) |d| {
        const utf8 = try utf16ToUtf8Alloc(vm.gpa, d);
        defer vm.gpa.free(utf8);
        try buf.appendSlice(vm.gpa, utf8);
    }
    try buf.append(vm.gpa, ')');
    return vm.makeString(buf.items);
}

pub fn nativeSymbolValueOf(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const vm = castVm(ctx);
    if (!this.isSymbol()) return vm.throwTypeError("Symbol.prototype.valueOf called on non-symbol");
    return this;
}

pub fn nativeSymbolDescription(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const vm = castVm(ctx);
    if (!this.isSymbol()) return vm.throwTypeError("Symbol.prototype.description called on non-symbol");
    if (this.asSymbol().description) |d| return vm.makeStringFromUtf16(d);
    return Value.undefined_value;
}

pub fn nativeSymbolFor(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const s = try vm.toStringVal(argAt(args, 0));
    try vm.protect(s);
    defer vm.unprotect();
    const key = try utf16ToUtf8Alloc(vm.gpa, s.asString().units);
    defer vm.gpa.free(key);
    for (vm.symbol_registry.items) |r| {
        if (std.mem.eql(u8, r.key, key)) return Value.fromSymbol(r.sym);
    }
    const sym_val = try vm.makeSymbol(key);
    try vm.symbol_registry.append(vm.gpa, .{ .key = try vm.gpa.dupe(u8, key), .sym = sym_val.asSymbol() });
    return sym_val;
}

pub fn nativeSymbolKeyFor(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const s = argAt(args, 0);
    if (!s.isSymbol()) return vm.throwTypeError("Symbol.keyFor requires a symbol argument");
    for (vm.symbol_registry.items) |r| {
        if (r.sym == s.asSymbol()) return vm.makeString(r.key);
    }
    return Value.undefined_value;
}

pub fn nativeProxy(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    if (!this.isObject()) return vm.throwTypeError("Constructor Proxy requires 'new'");
    const target = argAt(args, 0);
    const handler = argAt(args, 1);
    if (!target.isObject() or !handler.isObject()) {
        return vm.throwTypeError("Cannot create proxy with a non-object as target or handler");
    }
    const obj = this.asObject();
    obj.proxy_target = target.asObject();
    obj.proxy_handler = handler.asObject();
    // Inherit callability so `typeof` and call/construct dispatch behave.
    obj.callable = target.asObject().callable;
    return this;
}

/// Proxy.revocable(target, handler) -> { proxy, revoke }. The revoke function
/// reaches its proxy through the bound-function machinery (bound_this).
pub fn nativeProxyRevocable(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const target = argAt(args, 0);
    const handler = argAt(args, 1);
    if (!target.isObject() or !handler.isObject()) {
        return vm.throwTypeError("Cannot create proxy with a non-object as target or handler");
    }
    const proxy = try vm.newObject(vm.object_proto);
    try vm.protect(Value.fromObject(proxy));
    defer vm.unprotect();
    proxy.proxy_target = target.asObject();
    proxy.proxy_handler = handler.asObject();
    proxy.callable = target.asObject().callable;

    const inner = try vm.makeNative("revoke", nativeProxyRevoke, 0);
    try vm.protect(Value.fromObject(inner));
    defer vm.unprotect();
    const revoke = try vm.makeNative("revoke", nativeProxyRevoke, 0);
    try vm.protect(Value.fromObject(revoke));
    defer vm.unprotect();
    revoke.bound_target = Value.fromObject(inner);
    revoke.bound_this = Value.fromObject(proxy);

    const result = try vm.newObject(vm.object_proto);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    try vm.defineData(result, "proxy", Value.fromObject(proxy), true, true, true);
    try vm.defineData(result, "revoke", Value.fromObject(revoke), true, true, true);
    return Value.fromObject(result);
}

/// `@@species` getter shared by species-aware constructors: `return this`.
pub fn nativeReturnThis(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    _ = args;
    return this;
}

pub fn nativeProxyRevoke(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    _ = args;
    if (this.isObject() and this.asObject().proxy_target != null) {
        this.asObject().proxy_revoked = true;
    }
    return Value.undefined_value;
}

pub fn nativeReflectGet(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const target = argAt(args, 0);
    if (!target.isObject()) return vm.throwTypeError("Reflect.get called on non-object");
    const key = try vm.toPropertyKey(argAt(args, 1));
    defer vm.gpa.free(key);
    return vm.getProperty(target, key);
}

pub fn nativeReflectSet(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const target = argAt(args, 0);
    if (!target.isObject()) return vm.throwTypeError("Reflect.set called on non-object");
    const key = try vm.toPropertyKey(argAt(args, 1));
    defer vm.gpa.free(key);
    try vm.setProperty(target, key, argAt(args, 2));
    return Value.fromBool(true);
}

pub fn nativeReflectHas(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const target = argAt(args, 0);
    if (!target.isObject()) return vm.throwTypeError("Reflect.has called on non-object");
    return Value.fromBool(try vm.inOperator(argAt(args, 1), target));
}

pub fn nativeReflectDelete(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const target = argAt(args, 0);
    if (!target.isObject()) return vm.throwTypeError("Reflect.deleteProperty called on non-object");
    const key = try vm.toPropertyKey(argAt(args, 1));
    defer vm.gpa.free(key);
    // Honors non-configurable + proxy traps, reports [[Delete]]'s boolean.
    return Value.fromBool(try vm.deleteProperty(target, key));
}

pub fn nativeReflectGetProto(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const target = argAt(args, 0);
    if (!target.isObject()) return vm.throwTypeError("Reflect.getPrototypeOf called on non-object");
    return if (target.asObject().prototype) |p| Value.fromObject(p) else Value.null_value;
}

pub fn nativeReflectOwnKeys(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const target = argAt(args, 0);
    if (!target.isObject()) return vm.throwTypeError("Reflect.ownKeys called on non-object");
    const o = target.asObject();
    const result = try vm.newArray(0);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    if (o.is_array) {
        var idxs: std.ArrayList(u32) = .empty;
        defer idxs.deinit(vm.gpa);
        try vm.arrayPresentIndices(o, &idxs);
        for (idxs.items) |i| {
            var b: [16]u8 = undefined;
            try vm.arrayAppend(result, try vm.makeString(std.fmt.bufPrint(&b, "{d}", .{i}) catch unreachable));
        }
    }
    var it = o.properties.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        if (k.len > 0 and k[0] == 0) continue; // skip internal/symbol keys
        try vm.arrayAppend(result, try vm.makeString(k));
    }
    return Value.fromObject(result);
}

pub fn nativeReflectApply(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const target = argAt(args, 0);
    const this_arg = argAt(args, 1);
    const args_arr = argAt(args, 2);
    const list = try vm.argListFromArray(args_arr);
    defer vm.gpa.free(list);
    return vm.callValue(target, this_arg, list);
}

pub fn nativeReflectConstruct(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const target = argAt(args, 0);
    if (!isConstructorValue(target)) return vm.throwTypeError("Reflect.construct target is not a constructor");
    // newTarget defaults to target; when supplied it must also be a constructor.
    if (args.len >= 3 and !isConstructorValue(args[2])) {
        return vm.throwTypeError("Reflect.construct newTarget is not a constructor");
    }
    const args_arr = argAt(args, 1);
    const list = try vm.argListFromArray(args_arr);
    defer vm.gpa.free(list);
    return vm.constructValue(target, list);
}

/// Reflect.defineProperty(target, key, desc) -> boolean. Unlike
/// Object.defineProperty (which throws on a rejected define), Reflect reports
/// the [[DefineOwnProperty]] failure as `false`; a malformed descriptor or
/// non-object target still throws.
pub fn nativeReflectDefineProperty(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const target = argAt(args, 0);
    if (!target.isObject()) return vm.throwTypeError("Reflect.defineProperty called on non-object");
    const desc = argAt(args, 2);
    if (!desc.isObject()) return vm.throwTypeError("property descriptor must be an object");
    const key = try vm.toPropertyKey(argAt(args, 1));
    defer vm.gpa.free(key);
    object_mod.applyDescriptor(vm, target.asObject(), key, desc) catch |e| switch (e) {
        error.JsThrow => {
            // A rejected define surfaces as `false`, not a throw.
            vm.pending_exception = null;
            return Value.fromBool(false);
        },
        else => return e,
    };
    return Value.fromBool(true);
}

pub fn nativeReflectGetOwnPropertyDescriptor(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const target = argAt(args, 0);
    if (!target.isObject()) return vm.throwTypeError("Reflect.getOwnPropertyDescriptor called on non-object");
    return object_mod.nativeObjectGetOwnPropertyDescriptor(ctx, this, args);
}

pub fn nativeReflectSetProto(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const target = argAt(args, 0);
    if (!target.isObject()) return vm.throwTypeError("Reflect.setPrototypeOf called on non-object");
    const proto = argAt(args, 1);
    if (!proto.isObject() and !proto.isNull()) return vm.throwTypeError("prototype must be an object or null");
    object_mod.setPrototypeChecked(vm, target.asObject(), proto) catch |e| switch (e) {
        error.JsThrow => {
            vm.pending_exception = null;
            return Value.fromBool(false);
        },
        else => return e,
    };
    return Value.fromBool(true);
}

pub fn nativeReflectIsExtensible(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const target = argAt(args, 0);
    if (!target.isObject()) return vm.throwTypeError("Reflect.isExtensible called on non-object");
    return object_mod.nativeObjectIsExtensible(ctx, this, args);
}

pub fn nativeReflectPreventExtensions(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const target = argAt(args, 0);
    if (!target.isObject()) return vm.throwTypeError("Reflect.preventExtensions called on non-object");
    _ = object_mod.nativeObjectPreventExtensions(ctx, this, args) catch |e| switch (e) {
        error.JsThrow => {
            vm.pending_exception = null;
            return Value.fromBool(false);
        },
        else => return e,
    };
    return Value.fromBool(true);
}
