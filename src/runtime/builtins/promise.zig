//! Promise natives (spec 27.2). The internal state, reaction records, and the
//! microtask queue live on the Vm (`interpreter.zig`); this file is the
//! JS-facing surface: the constructor, prototype methods, statics, and the
//! NewPromiseCapability machinery that makes them subclass/species-aware.

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
const isConstructorValue = support_mod.isConstructorValue;
const toBoolean = support_mod.toBoolean;

/// The receiver's promise object, or a TypeError for non-promises.
fn thisPromise(vm: *Vm, this: Value) Error!*gc.Object {
    if (!this.isObject() or this.asObject().promise == null) {
        return vm.throwTypeError("Promise.prototype method called on a non-promise");
    }
    return this.asObject();
}

// ---- NewPromiseCapability ----------------------------------------------------

/// A PromiseCapability record: the promise plus its resolve/reject functions.
///
/// All three fields are returned *unrooted*: a caller that allocates before
/// using them (calling `resolve`/`reject` builds a frame, which allocates) must
/// `protect` each one first. `protect_all` does that.
pub const Capability = struct {
    promise: Value,
    resolve: Value,
    reject: Value,

    /// Root all three; the caller must `unprotect` three times.
    fn protect_all(cap: Capability, vm: *Vm) Error!void {
        try vm.protect(cap.promise);
        try vm.protect(cap.resolve);
        try vm.protect(cap.reject);
    }
    fn unprotect_all(vm: *Vm) void {
        vm.unprotect();
        vm.unprotect();
        vm.unprotect();
    }
};

/// GetCapabilitiesExecutor: `this` is the capture holder; called by the
/// constructor with (resolve, reject). Calling it twice is a TypeError.
fn nativeCapabilityExecutor(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const holder = this.asObject();
    if (holder.properties.contains("\x00res")) return vm.throwTypeError("promise executor already called");
    try vm.defineData(holder, "\x00res", argAt(args, 0), false, false, false);
    try vm.defineData(holder, "\x00rej", argAt(args, 1), false, false, false);
    return Value.undefined_value;
}

/// NewPromiseCapability(C): construct a promise via `C` and capture the
/// resolve/reject pair its executor receives. The intrinsic %Promise% takes a
/// fast path (its executor behavior is not observable).
pub fn newPromiseCapability(vm: *Vm, ctor: Value) Error!Capability {
    if (!isConstructorValue(ctor)) return vm.throwTypeError("promise capability requires a constructor");
    if (ctor.isObject() and ctor.asObject() == vm.promise_ctor.?) {
        const p = try vm.newPromise();
        try vm.protect(Value.fromObject(p));
        defer vm.unprotect();
        const pair = try vm.makeResolvingPair(p);
        return .{ .promise = Value.fromObject(p), .resolve = Value.fromObject(pair.resolve), .reject = Value.fromObject(pair.reject) };
    }
    const holder = try vm.newObject(null);
    try vm.protect(Value.fromObject(holder));
    defer vm.unprotect();
    const executor = try vm.makeBoundNative("", nativeCapabilityExecutor, holder);
    try vm.protect(Value.fromObject(executor));
    defer vm.unprotect();
    const p = try vm.constructValue(ctor, &.{Value.fromObject(executor)});
    try vm.protect(p);
    defer vm.unprotect();
    const res = if (holder.properties.get("\x00res")) |d| d.value else Value.undefined_value;
    const rej = if (holder.properties.get("\x00rej")) |d| d.value else Value.undefined_value;
    if (!isCallable(res) or !isCallable(rej)) {
        return vm.throwTypeError("promise executor did not provide callable resolve/reject");
    }
    return .{ .promise = p, .resolve = res, .reject = rej };
}

/// Reject `cap` with the pending JS exception (rethrowing engine errors).
fn rejectWithPending(vm: *Vm, cap: Capability, e: Error) Error!Value {
    if (e != error.JsThrow) return e;
    const exc = vm.pending_exception.?;
    vm.pending_exception = null;
    _ = vm.callValue(cap.reject, Value.undefined_value, &.{exc}) catch |e2| {
        if (e2 != error.JsThrow) return e2;
        vm.pending_exception = null;
    };
    return cap.promise;
}

// ---- constructor & prototype -------------------------------------------------

/// `new Promise(executor)`: attach state to `this`, hand the executor a
/// resolve/reject pair, and reject on an executor throw.
pub fn nativePromise(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    // Called without `new` (no fresh object inheriting from %Promise.prototype%),
    // or on an already-initialized promise: TypeError. NewTarget isn't threaded,
    // so approximate with the prototype chain + [[PromiseState]] checks.
    if (!this.isObject() or this.asObject().promise != null or
        !protoChainContains(this.asObject(), vm.promise_proto.?))
    {
        return vm.throwTypeError("Promise constructor requires 'new'");
    }
    const executor = argAt(args, 0);
    if (!isCallable(executor)) return vm.throwTypeError("Promise executor is not a function");

    const p = this.asObject();
    const state = try vm.gpa.create(gc.PromiseState);
    state.* = .{};
    p.promise = state;

    const pair = try vm.makeResolvingPair(p);
    try vm.protect(Value.fromObject(pair.holder));
    defer vm.unprotect();
    try vm.protect(Value.fromObject(pair.resolve));
    defer vm.unprotect();
    try vm.protect(Value.fromObject(pair.reject));
    defer vm.unprotect();

    _ = vm.callValue(executor, Value.undefined_value, &.{ Value.fromObject(pair.resolve), Value.fromObject(pair.reject) }) catch |e| {
        if (e != error.JsThrow) return e;
        const exc = vm.pending_exception.?;
        vm.pending_exception = null;
        if (!try vm.resolvingPairUsed(pair.holder)) {
            try vm.settlePromise(p, exc, false);
        }
    };
    return this;
}

fn protoChainContains(obj: *gc.Object, target: *gc.Object) bool {
    var o: ?*gc.Object = obj.prototype;
    while (o) |cur| {
        if (cur == target) return true;
        o = cur.prototype;
    }
    return false;
}

/// SpeciesConstructor(promise, %Promise%) -> the constructor to derive with.
fn speciesConstructor(vm: *Vm, this: Value) Error!Value {
    const default_ctor = Value.fromObject(vm.promise_ctor.?);
    const c = try vm.getProperty(this, "constructor");
    if (c.isUndefined()) return default_ctor;
    if (!c.isObject()) return vm.throwTypeError("promise constructor is not an object");
    if (vm.symbol_species_key.len != 0) {
        const s = try vm.getProperty(c, vm.symbol_species_key);
        if (s.isNullish()) return default_ctor;
        if (!isConstructorValue(s)) return vm.throwTypeError("@@species is not a constructor");
        return s;
    }
    return c;
}

pub fn nativePromiseThen(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const p = try thisPromise(vm, this);
    const cap = try newPromiseCapability(vm, try speciesConstructor(vm, this));
    try cap.protect_all(vm);
    defer Capability.unprotect_all(vm);
    try vm.performPromiseThen(p, argAt(args, 0), argAt(args, 1), cap.resolve, cap.reject);
    return cap.promise;
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

// ---- statics -------------------------------------------------------------------

pub fn nativePromiseResolve(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    if (!this.isObject()) return vm.throwTypeError("Promise.resolve called on a non-object");
    const x = argAt(args, 0);
    // A promise whose `constructor` is this receiver passes through unchanged.
    if (x.isObject() and x.asObject().promise != null) {
        const xc = try vm.getProperty(x, "constructor");
        if (xc.isObject() and this.isObject() and xc.asObject() == this.asObject()) return x;
    }
    const cap = try newPromiseCapability(vm, this);
    try cap.protect_all(vm);
    defer Capability.unprotect_all(vm);
    _ = try vm.callValue(cap.resolve, Value.undefined_value, &.{x});
    return cap.promise;
}

pub fn nativePromiseReject(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    if (!this.isObject()) return vm.throwTypeError("Promise.reject called on a non-object");
    const cap = try newPromiseCapability(vm, this);
    try cap.protect_all(vm);
    defer Capability.unprotect_all(vm);
    _ = try vm.callValue(cap.reject, Value.undefined_value, &.{argAt(args, 0)});
    return cap.promise;
}

/// `Promise.withResolvers()` -> { promise, resolve, reject }.
pub fn nativePromiseWithResolvers(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    _ = args;
    const cap = try newPromiseCapability(vm, this);
    try cap.protect_all(vm);
    defer Capability.unprotect_all(vm);
    const result = try vm.newObject(vm.object_proto);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    try vm.defineData(result, "promise", cap.promise, true, true, true);
    try vm.defineData(result, "resolve", cap.resolve, true, true, true);
    try vm.defineData(result, "reject", cap.reject, true, true, true);
    return Value.fromObject(result);
}

/// `Promise.try(fn, ...args)`: call `fn` synchronously; the result (or throw)
/// settles a promise built from `this`.
pub fn nativePromiseTry(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    if (!this.isObject()) return vm.throwTypeError("Promise.try called on a non-object");
    const cap = try newPromiseCapability(vm, this);
    try cap.protect_all(vm);
    defer Capability.unprotect_all(vm);
    const f = argAt(args, 0);
    const rest = if (args.len > 1) args[1..] else &[_]Value{};
    const result = vm.callValue(f, Value.undefined_value, rest) catch |e| {
        return rejectWithPending(vm, cap, e);
    };
    _ = try vm.callValue(cap.resolve, Value.undefined_value, &.{result});
    return cap.promise;
}

pub fn nativeQueueMicrotask(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    _ = this;
    const f = argAt(args, 0);
    if (!isCallable(f)) return vm.throwTypeError("queueMicrotask argument is not a function");
    try vm.enqueueJob(.{ .callback = .{ .func = f } });
    return Value.undefined_value;
}

// ---- combinators (all / allSettled / any / race) ----------------------------
//
// Shared shape (spec 27.2.4.1.2 and friends): C = `this`; the result promise
// comes from NewPromiseCapability(C); each element goes through the observable
// `C.resolve` and the element promise's own `.then`. Per-element reaction
// natives reach their state through a holder object (`this` via the
// bound-native trick):
//   \x00arr  the results (or errors) array — also carries \x00rem, the count
//            of unsettled elements (+1 while iterating)
//   \x00res / \x00rej  the capability's resolve/reject
//   \x00i    this element's index
//   \x00done per-element once-latch

const Kind = enum { all, all_settled, any, race };

fn makeElementHolder(vm: *Vm, arr: *gc.Object, cap: Capability, index: u32) Error!*gc.Object {
    const holder = try vm.newObject(null);
    try vm.protect(Value.fromObject(holder));
    defer vm.unprotect();
    try vm.defineData(holder, "\x00arr", Value.fromObject(arr), false, false, false);
    try vm.defineData(holder, "\x00res", cap.resolve, false, false, false);
    try vm.defineData(holder, "\x00rej", cap.reject, false, false, false);
    try vm.defineData(holder, "\x00i", Value.fromNumber(@floatFromInt(index)), false, false, false);
    return holder;
}

const HolderParts = struct { arr: *gc.Object, res: Value, rej: Value, i: u32 };

/// Unpack an element holder; null when this element already settled (once).
fn holderParts(vm: *Vm, this: Value) Error!?HolderParts {
    const h = this.asObject();
    if (h.properties.contains("\x00done")) return null;
    try vm.defineData(h, "\x00done", Value.fromBool(true), false, false, false);
    return .{
        .arr = h.properties.get("\x00arr").?.value.asObject(),
        .res = h.properties.get("\x00res").?.value,
        .rej = h.properties.get("\x00rej").?.value,
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
    const h = (try holderParts(vm, this)) orelse return Value.undefined_value;
    try vm.setArrayElement(h.arr, h.i, argAt(args, 0));
    if (try countDown(vm, h.arr)) _ = try vm.callValue(h.res, Value.undefined_value, &.{Value.fromObject(h.arr)});
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
    const h = (try holderParts(vm, this)) orelse return Value.undefined_value;
    try vm.setArrayElement(h.arr, h.i, try settledOutcome(vm, true, argAt(args, 0)));
    if (try countDown(vm, h.arr)) _ = try vm.callValue(h.res, Value.undefined_value, &.{Value.fromObject(h.arr)});
    return Value.undefined_value;
}

fn nativeSettledRejected(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const h = (try holderParts(vm, this)) orelse return Value.undefined_value;
    try vm.setArrayElement(h.arr, h.i, try settledOutcome(vm, false, argAt(args, 0)));
    if (try countDown(vm, h.arr)) _ = try vm.callValue(h.res, Value.undefined_value, &.{Value.fromObject(h.arr)});
    return Value.undefined_value;
}

/// Reject with an AggregateError carrying `errors`.
fn rejectWithAggregate(vm: *Vm, reject_fn: Value, errors: *gc.Object) Error!void {
    const agg_ctor = try vm.getProperty(Value.fromObject(vm.global_object.?), "AggregateError");
    const proto_v = try vm.getProperty(agg_ctor, "prototype");
    const err = try vm.makeError(if (proto_v.isObject()) proto_v.asObject() else vm.error_proto, "all promises were rejected");
    try vm.protect(Value.fromObject(err));
    defer vm.unprotect();
    try vm.defineData(err, "errors", Value.fromObject(errors), true, false, true);
    _ = try vm.callValue(reject_fn, Value.undefined_value, &.{Value.fromObject(err)});
}

fn nativeAnyRejected(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const h = (try holderParts(vm, this)) orelse return Value.undefined_value;
    try vm.setArrayElement(h.arr, h.i, argAt(args, 0));
    if (try countDown(vm, h.arr)) try rejectWithAggregate(vm, h.rej, h.arr);
    return Value.undefined_value;
}

/// The iterate-and-register loop shared by every combinator. `C` is the
/// receiver (usually the Promise constructor, possibly a subclass).
fn runCombinator(vm: *Vm, ctor: Value, iterable: Value, kind: Kind) Error!Value {
    if (!ctor.isObject()) return vm.throwTypeError("promise combinator called on a non-object");
    const cap = try newPromiseCapability(vm, ctor);
    try cap.protect_all(vm);
    defer Capability.unprotect_all(vm);

    // The observable `C.resolve` used for every element.
    const promise_resolve = vm.getProperty(ctor, "resolve") catch |e| return rejectWithPending(vm, cap, e);
    try vm.protect(promise_resolve);
    defer vm.unprotect();
    if (!isCallable(promise_resolve)) {
        vm.pending_exception = Value.fromObject(try vm.makeError(vm.type_error_proto, "C.resolve is not callable"));
        return rejectWithPending(vm, cap, error.JsThrow);
    }

    const arr = try vm.newArray(0);
    try vm.protect(Value.fromObject(arr));
    defer vm.unprotect();
    // +1 while iterating, so a synchronously-settled element can't resolve the
    // combinator before every element is registered.
    try vm.defineData(arr, "\x00rem", Value.fromNumber(1), false, false, false);

    const iter = vm.getIterator(iterable) catch |e| return rejectWithPending(vm, cap, e);
    try vm.protect(iter);
    defer vm.unprotect();

    var index: u32 = 0;
    while (true) {
        const res = vm.iteratorNext(iter) catch |e| return rejectWithPending(vm, cap, e);
        if (toBoolean(vm.getProperty(res, "done") catch |e| return rejectWithPending(vm, cap, e))) break;
        const el = vm.getProperty(res, "value") catch |e| return rejectWithPending(vm, cap, e);
        try vm.protect(el);
        defer vm.unprotect();

        // nextPromise = C.resolve(el) — observable.
        const elp = vm.callValue(promise_resolve, ctor, &.{el}) catch |e| {
            vm.iteratorClose(iter, true) catch {};
            return rejectWithPending(vm, cap, e);
        };
        try vm.protect(elp);
        defer vm.unprotect();

        if (kind != .race) {
            const rem = arr.properties.get("\x00rem").?.value.asNumber() + 1;
            try vm.defineData(arr, "\x00rem", Value.fromNumber(rem), false, false, false);
            if (kind == .all) try vm.setArrayElement(arr, index, Value.undefined_value);
        }

        var on_f: Value = cap.resolve;
        var on_r: Value = cap.reject;
        switch (kind) {
            .race => {},
            .all => {
                const holder = try makeElementHolder(vm, arr, cap, index);
                try vm.protect(Value.fromObject(holder));
                defer vm.unprotect();
                on_f = Value.fromObject(try vm.makeBoundNative("", nativeAllFulfilled, holder));
            },
            .all_settled => {
                const holder = try makeElementHolder(vm, arr, cap, index);
                try vm.protect(Value.fromObject(holder));
                defer vm.unprotect();
                on_f = Value.fromObject(try vm.makeBoundNative("", nativeSettledFulfilled, holder));
                try vm.protect(on_f);
                defer vm.unprotect();
                on_r = Value.fromObject(try vm.makeBoundNative("", nativeSettledRejected, holder));
            },
            .any => {
                const holder = try makeElementHolder(vm, arr, cap, index);
                try vm.protect(Value.fromObject(holder));
                defer vm.unprotect();
                on_r = Value.fromObject(try vm.makeBoundNative("", nativeAnyRejected, holder));
            },
        }
        try vm.protect(on_f);
        defer vm.unprotect();
        try vm.protect(on_r);
        defer vm.unprotect();

        // Invoke(nextPromise, "then", (onF, onR)) — observable.
        const then = vm.getProperty(elp, "then") catch |e| {
            vm.iteratorClose(iter, true) catch {};
            return rejectWithPending(vm, cap, e);
        };
        _ = vm.callValue(then, elp, &.{ on_f, on_r }) catch |e| {
            vm.iteratorClose(iter, true) catch {};
            return rejectWithPending(vm, cap, e);
        };
        index += 1;
    }

    // Iteration done: release the +1 guard.
    if (kind != .race) {
        const rem = arr.properties.get("\x00rem").?.value.asNumber() - 1;
        try vm.defineData(arr, "\x00rem", Value.fromNumber(rem), false, false, false);
        if (rem == 0) {
            if (kind == .any) {
                try rejectWithAggregate(vm, cap.reject, arr);
            } else {
                _ = try vm.callValue(cap.resolve, Value.undefined_value, &.{Value.fromObject(arr)});
            }
        }
    }
    return cap.promise;
}

pub fn nativePromiseAll(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return runCombinator(castVm(ctx), this, argAt(args, 0), .all);
}
pub fn nativePromiseAllSettled(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return runCombinator(castVm(ctx), this, argAt(args, 0), .all_settled);
}
pub fn nativePromiseAny(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return runCombinator(castVm(ctx), this, argAt(args, 0), .any);
}
pub fn nativePromiseRace(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return runCombinator(castVm(ctx), this, argAt(args, 0), .race);
}
