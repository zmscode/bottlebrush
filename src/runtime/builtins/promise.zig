//! Promise natives (spec 27.2). The internal state, reaction records, and the
//! microtask queue live on the Vm (`interpreter.zig`); this file is the
//! JS-facing surface: the constructor, prototype methods, and statics.

const std = @import("std");
const gc = @import("../../gc.zig");
const Value = @import("../../value.zig").Value;
const interpreter = @import("../../interpreter.zig");
const Vm = interpreter.Vm;
const Error = interpreter.Error;

const support_mod = @import("../support.zig");
const argAt = support_mod.argAt;
const castVm = support_mod.castVm;
const isCallable = support_mod.isCallable;

/// The receiver's PromiseState, or a TypeError for non-promises.
fn thisPromise(vm: *Vm, this: Value) Error!*gc.Object {
    if (!this.isObject() or this.asObject().promise == null) {
        return vm.throwTypeError("Promise.prototype method called on a non-promise");
    }
    return this.asObject();
}

/// `new Promise(executor)`: attach state to `this`, hand the executor a
/// resolve/reject pair, and reject on an executor throw.
pub fn nativePromise(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    if (!this.isObject()) return vm.throwTypeError("Promise constructor requires 'new'");
    const executor = argAt(args, 0);
    if (!isCallable(executor)) return vm.throwTypeError("Promise executor is not a function");

    const p = this.asObject();
    const state = try vm.gpa.create(gc.PromiseState);
    state.* = .{};
    p.promise = state;

    const resolve_fn = try vm.makeBoundNative("resolve", Vm.nativePromiseResolveFn, p);
    try vm.protect(Value.fromObject(resolve_fn));
    defer vm.unprotect();
    const reject_fn = try vm.makeBoundNative("reject", Vm.nativePromiseRejectFn, p);
    try vm.protect(Value.fromObject(reject_fn));
    defer vm.unprotect();

    _ = vm.callValue(executor, Value.undefined_value, &.{ Value.fromObject(resolve_fn), Value.fromObject(reject_fn) }) catch |e| {
        if (e != error.JsThrow) return e;
        const exc = vm.pending_exception.?;
        vm.pending_exception = null;
        if (!state.already_resolved) {
            state.already_resolved = true;
            try vm.settlePromise(p, exc, false);
        }
    };
    return this;
}

pub fn nativePromiseThen(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const p = try thisPromise(vm, this);
    const derived = try vm.newPromise();
    try vm.protect(Value.fromObject(derived));
    defer vm.unprotect();
    try vm.performPromiseThen(p, argAt(args, 0), argAt(args, 1), derived);
    return Value.fromObject(derived);
}

pub fn nativePromiseCatch(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    // `catch(f)` = Invoke(this, "then", (undefined, f)) — honors an overridden then.
    const then = try vm.getProperty(this, "then");
    return vm.callValue(then, this, &.{ Value.undefined_value, argAt(args, 0) });
}

/// The `finally` pass-through wrappers reach their callback via `this`
/// (a holder object created by nativePromiseFinally).
fn nativeFinallyFulfill(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const cb = try vm.getProperty(this, "\x00cb");
    if (isCallable(cb)) _ = try vm.callValue(cb, Value.undefined_value, &.{});
    return argAt(args, 0); // pass the value through
}

fn nativeFinallyReject(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const cb = try vm.getProperty(this, "\x00cb");
    if (isCallable(cb)) _ = try vm.callValue(cb, Value.undefined_value, &.{});
    vm.pending_exception = argAt(args, 0); // rethrow the original reason
    return error.JsThrow;
}

pub fn nativePromiseFinally(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const cb = argAt(args, 0);
    // Holder carries the callback for both wrappers.
    const holder = try vm.newObject(vm.object_proto);
    try vm.protect(Value.fromObject(holder));
    defer vm.unprotect();
    try vm.defineData(holder, "\x00cb", cb, false, false, false);
    const on_f = try vm.makeBoundNative("", nativeFinallyFulfill, holder);
    try vm.protect(Value.fromObject(on_f));
    defer vm.unprotect();
    const on_r = try vm.makeBoundNative("", nativeFinallyReject, holder);
    try vm.protect(Value.fromObject(on_r));
    defer vm.unprotect();
    const then = try vm.getProperty(this, "then");
    return vm.callValue(then, this, &.{ Value.fromObject(on_f), Value.fromObject(on_r) });
}

pub fn nativePromiseResolve(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    _ = this;
    return Value.fromObject(try vm.promiseResolveValue(argAt(args, 0)));
}

pub fn nativePromiseReject(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    _ = this;
    const p = try vm.newPromise();
    try vm.protect(Value.fromObject(p));
    defer vm.unprotect();
    try vm.settlePromise(p, argAt(args, 0), false);
    return Value.fromObject(p);
}

/// `Promise.withResolvers()` -> { promise, resolve, reject }.
pub fn nativePromiseWithResolvers(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    _ = this;
    _ = args;
    const p = try vm.newPromise();
    try vm.protect(Value.fromObject(p));
    defer vm.unprotect();
    const resolve_fn = try vm.makeBoundNative("resolve", Vm.nativePromiseResolveFn, p);
    try vm.protect(Value.fromObject(resolve_fn));
    defer vm.unprotect();
    const reject_fn = try vm.makeBoundNative("reject", Vm.nativePromiseRejectFn, p);
    try vm.protect(Value.fromObject(reject_fn));
    defer vm.unprotect();
    const result = try vm.newObject(vm.object_proto);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    try vm.defineData(result, "promise", Value.fromObject(p), true, true, true);
    try vm.defineData(result, "resolve", Value.fromObject(resolve_fn), true, true, true);
    try vm.defineData(result, "reject", Value.fromObject(reject_fn), true, true, true);
    return Value.fromObject(result);
}

pub fn nativeQueueMicrotask(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    _ = this;
    const f = argAt(args, 0);
    if (!isCallable(f)) return vm.throwTypeError("queueMicrotask argument is not a function");
    try vm.enqueueJob(.{ .callback = .{ .func = f } });
    return Value.undefined_value;
}
