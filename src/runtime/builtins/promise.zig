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
const toBoolean = support_mod.toBoolean;

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

// ---- combinators (all / allSettled / any / race) ----------------------------
//
// Shared shape: iterate the argument with the iterator protocol; each element
// is Promise-resolved and given per-element reaction natives that reach their
// state through a holder object (`this` via the bound-native trick):
//   \x00arr  the results (or errors) array — also carries \x00rem, the count
//            of unsettled elements (+1 while iterating, spec 27.2.4.1.2 step 4)
//   \x00p    the combinator's result promise
//   \x00i    this element's index

const Kind = enum { all, all_settled, any, race };

fn makeElementHolder(vm: *Vm, arr: *gc.Object, p: *gc.Object, index: u32) Error!*gc.Object {
    const holder = try vm.newObject(null);
    try vm.protect(Value.fromObject(holder));
    defer vm.unprotect();
    try vm.defineData(holder, "\x00arr", Value.fromObject(arr), false, false, false);
    try vm.defineData(holder, "\x00p", Value.fromObject(p), false, false, false);
    try vm.defineData(holder, "\x00i", Value.fromNumber(@floatFromInt(index)), false, false, false);
    return holder;
}

fn holderParts(this: Value) struct { arr: *gc.Object, p: *gc.Object, i: u32 } {
    const h = this.asObject();
    return .{
        .arr = h.properties.get("\x00arr").?.value.asObject(),
        .p = h.properties.get("\x00p").?.value.asObject(),
        .i = @intFromFloat(h.properties.get("\x00i").?.value.asNumber()),
    };
}

/// Decrement the shared remaining-count; true when it reached zero.
fn countDown(vm: *Vm, arr: *gc.Object) Error!bool {
    const rem = arr.properties.get("\x00rem").?.value.asNumber() - 1;
    try vm.defineData(arr, "\x00rem", Value.fromNumber(rem), false, false, false);
    return rem == 0;
}

fn nativeAllFulfilled(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const h = holderParts(this);
    try vm.setArrayElement(h.arr, h.i, argAt(args, 0));
    if (try countDown(vm, h.arr)) try vm.resolvePromiseWith(h.p, Value.fromObject(h.arr));
    return Value.undefined_value;
}

/// allSettled: record a `{ status, value|reason }` outcome object.
fn settledOutcome(vm: *Vm, fulfilled: bool, v: Value) Error!Value {
    const o = try vm.newObject(vm.object_proto);
    try vm.protect(Value.fromObject(o));
    defer vm.unprotect();
    try vm.defineData(o, "status", try vm.makeString(if (fulfilled) "fulfilled" else "rejected"), true, true, true);
    try vm.defineData(o, if (fulfilled) "value" else "reason", v, true, true, true);
    return Value.fromObject(o);
}

fn nativeSettledFulfilled(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const h = holderParts(this);
    try vm.setArrayElement(h.arr, h.i, try settledOutcome(vm, true, argAt(args, 0)));
    if (try countDown(vm, h.arr)) try vm.resolvePromiseWith(h.p, Value.fromObject(h.arr));
    return Value.undefined_value;
}

fn nativeSettledRejected(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const h = holderParts(this);
    try vm.setArrayElement(h.arr, h.i, try settledOutcome(vm, false, argAt(args, 0)));
    if (try countDown(vm, h.arr)) try vm.resolvePromiseWith(h.p, Value.fromObject(h.arr));
    return Value.undefined_value;
}

fn nativeAnyRejected(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const h = holderParts(this);
    try vm.setArrayElement(h.arr, h.i, argAt(args, 0));
    if (try countDown(vm, h.arr)) {
        // Every element rejected: AggregateError carrying the reasons.
        const agg_ctor = try vm.getProperty(Value.fromObject(vm.global_object.?), "AggregateError");
        const proto_v = try vm.getProperty(agg_ctor, "prototype");
        const err = try vm.makeError(if (proto_v.isObject()) proto_v.asObject() else vm.error_proto, "all promises were rejected");
        try vm.protect(Value.fromObject(err));
        defer vm.unprotect();
        try vm.defineData(err, "errors", Value.fromObject(h.arr), true, false, true);
        try vm.settlePromise(h.p, Value.fromObject(err), false);
    }
    return Value.undefined_value;
}

/// The iterate-and-register loop shared by every combinator. Returns the
/// result promise (already settled for the empty/degenerate cases).
fn runCombinator(vm: *Vm, iterable: Value, kind: Kind) Error!Value {
    const p = try vm.newPromise();
    try vm.protect(Value.fromObject(p));
    defer vm.unprotect();
    const arr = try vm.newArray(0);
    try vm.protect(Value.fromObject(arr));
    defer vm.unprotect();
    // +1 while iterating, so a synchronously-settled element can't resolve the
    // combinator before every element is registered.
    try vm.defineData(arr, "\x00rem", Value.fromNumber(1), false, false, false);

    const iter = vm.getIterator(iterable) catch |e| return settleWithPending(vm, p, e);
    try vm.protect(iter);
    defer vm.unprotect();

    var index: u32 = 0;
    while (true) {
        const res = vm.iteratorNext(iter) catch |e| return settleWithPending(vm, p, e);
        if (toBoolean(vm.getProperty(res, "done") catch |e| return settleWithPending(vm, p, e))) break;
        const el = vm.getProperty(res, "value") catch |e| return settleWithPending(vm, p, e);
        try vm.protect(el);
        defer vm.unprotect();

        const elp = vm.promiseResolveValue(el) catch |e| return settleWithPending(vm, p, e);
        try vm.protect(Value.fromObject(elp));
        defer vm.unprotect();

        if (kind != .race) {
            const rem = arr.properties.get("\x00rem").?.value.asNumber() + 1;
            try vm.defineData(arr, "\x00rem", Value.fromNumber(rem), false, false, false);
            if (kind == .all) try vm.setArrayElement(arr, index, Value.undefined_value);
        }

        const reject_p = try vm.makeBoundNative("", Vm.nativePromiseRejectFn, p);
        try vm.protect(Value.fromObject(reject_p));
        defer vm.unprotect();
        const resolve_p = try vm.makeBoundNative("", Vm.nativePromiseResolveFn, p);
        try vm.protect(Value.fromObject(resolve_p));
        defer vm.unprotect();

        switch (kind) {
            .race => try vm.performPromiseThen(elp, Value.fromObject(resolve_p), Value.fromObject(reject_p), null),
            .all => {
                const holder = try makeElementHolder(vm, arr, p, index);
                try vm.protect(Value.fromObject(holder));
                defer vm.unprotect();
                const on_f = try vm.makeBoundNative("", nativeAllFulfilled, holder);
                try vm.protect(Value.fromObject(on_f));
                defer vm.unprotect();
                try vm.performPromiseThen(elp, Value.fromObject(on_f), Value.fromObject(reject_p), null);
            },
            .all_settled => {
                const holder = try makeElementHolder(vm, arr, p, index);
                try vm.protect(Value.fromObject(holder));
                defer vm.unprotect();
                const on_f = try vm.makeBoundNative("", nativeSettledFulfilled, holder);
                try vm.protect(Value.fromObject(on_f));
                defer vm.unprotect();
                const on_r = try vm.makeBoundNative("", nativeSettledRejected, holder);
                try vm.protect(Value.fromObject(on_r));
                defer vm.unprotect();
                try vm.performPromiseThen(elp, Value.fromObject(on_f), Value.fromObject(on_r), null);
            },
            .any => {
                const holder = try makeElementHolder(vm, arr, p, index);
                try vm.protect(Value.fromObject(holder));
                defer vm.unprotect();
                const on_r = try vm.makeBoundNative("", nativeAnyRejected, holder);
                try vm.protect(Value.fromObject(on_r));
                defer vm.unprotect();
                try vm.performPromiseThen(elp, Value.fromObject(resolve_p), Value.fromObject(on_r), null);
            },
        }
        index += 1;
    }

    // Iteration done: release the +1 guard.
    if (kind != .race) {
        const rem = arr.properties.get("\x00rem").?.value.asNumber() - 1;
        try vm.defineData(arr, "\x00rem", Value.fromNumber(rem), false, false, false);
        if (rem == 0) {
            if (kind == .any) {
                // Empty iterable: reject with an empty AggregateError.
                const agg_ctor = try vm.getProperty(Value.fromObject(vm.global_object.?), "AggregateError");
                const proto_v = try vm.getProperty(agg_ctor, "prototype");
                const err = try vm.makeError(if (proto_v.isObject()) proto_v.asObject() else vm.error_proto, "all promises were rejected");
                try vm.protect(Value.fromObject(err));
                defer vm.unprotect();
                try vm.defineData(err, "errors", Value.fromObject(arr), true, false, true);
                try vm.settlePromise(p, Value.fromObject(err), false);
            } else {
                try vm.resolvePromiseWith(p, Value.fromObject(arr));
            }
        }
    }
    return Value.fromObject(p);
}

/// Reject `p` with the pending JS exception (rethrowing engine errors).
fn settleWithPending(vm: *Vm, p: *gc.Object, e: Error) Error!Value {
    if (e != error.JsThrow) return e;
    const exc = vm.pending_exception.?;
    vm.pending_exception = null;
    try vm.settlePromise(p, exc, false);
    return Value.fromObject(p);
}

pub fn nativePromiseAll(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    return runCombinator(castVm(ctx), argAt(args, 0), .all);
}
pub fn nativePromiseAllSettled(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    return runCombinator(castVm(ctx), argAt(args, 0), .all_settled);
}
pub fn nativePromiseAny(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    return runCombinator(castVm(ctx), argAt(args, 0), .any);
}
pub fn nativePromiseRace(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    return runCombinator(castVm(ctx), argAt(args, 0), .race);
}

pub fn nativeQueueMicrotask(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    _ = this;
    const f = argAt(args, 0);
    if (!isCallable(f)) return vm.throwTypeError("queueMicrotask argument is not a function");
    try vm.enqueueJob(.{ .callback = .{ .func = f } });
    return Value.undefined_value;
}
