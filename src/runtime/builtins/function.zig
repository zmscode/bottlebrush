//! Function.prototype natives (call/apply/bind/toString), the dynamic
//! Function() constructor, and global eval.

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
const utf16ToUtf8Alloc = support_mod.utf16ToUtf8Alloc;

pub fn nativeFunctionToString(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const vm = castVm(ctx);
    if (!isCallable(this)) return vm.throwTypeError("Function.prototype.toString requires a function");
    const name_v = try vm.getProperty(this, "name");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(vm.gpa);
    try buf.appendSlice(vm.gpa, "function ");
    if (name_v.isString()) {
        const n8 = try utf16ToUtf8Alloc(vm.gpa, name_v.asString().units);
        defer vm.gpa.free(n8);
        try buf.appendSlice(vm.gpa, n8);
    }
    try buf.appendSlice(vm.gpa, "() { [native code] }");
    return vm.makeString(buf.items);
}

pub fn nativeFunctionCall(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    if (!isCallable(this)) return vm.throwTypeError("Function.prototype.call called on non-function");
    const this_arg = argAt(args, 0);
    const rest: []const Value = if (args.len > 1) args[1..] else &.{};
    return vm.callValue(this, this_arg, rest);
}

pub fn nativeFunctionApply(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    if (!isCallable(this)) return vm.throwTypeError("Function.prototype.apply called on non-function");
    const this_arg = argAt(args, 0);
    const args_arr = argAt(args, 1);
    const list = try vm.argListFromArray(args_arr);
    defer vm.gpa.free(list);
    return vm.callValue(this, this_arg, list);
}

pub fn nativeFunctionBind(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    if (!isCallable(this)) return vm.throwTypeError("Function.prototype.bind called on non-function");
    const bound = try vm.makeNative("bound", nativeBoundTrampoline, 0);
    try vm.protect(Value.fromObject(bound));
    defer vm.unprotect();
    bound.bound_target = this;
    bound.bound_this = argAt(args, 0);
    if (args.len > 1) for (args[1..]) |a| try bound.elements.append(vm.gpa, a);
    return Value.fromObject(bound);
}

/// A bound function's [[Call]]/[[Construct]] are intercepted in `callValue`/
/// `constructValue`; this native is never actually dispatched.
pub fn nativeBoundTrampoline(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    _ = args;
    return castVm(ctx).throwTypeError("bound function dispatched without interception");
}

/// `eval(x)`: non-strings pass through; strings run in the global scope.
pub fn nativeEval(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const a = argAt(args, 0);
    if (!a.isString()) return a;
    const src8 = try utf16ToUtf8Alloc(vm.gpa, a.asString().units);
    defer vm.gpa.free(src8);
    return vm.evalSource(src8);
}

/// The dynamic `Function(p1, …, body)` constructor: assemble a function
/// expression and evaluate it in the global scope.
pub fn nativeFunctionCtor(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(vm.gpa);
    try src.appendSlice(vm.gpa, "return (function anonymous(");
    const nparams = if (args.len == 0) 0 else args.len - 1;
    for (args[0..nparams], 0..) |p, i| {
        if (i > 0) try src.appendSlice(vm.gpa, ", ");
        const ps = try vm.toStringVal(p);
        try vm.protect(ps);
        defer vm.unprotect();
        const p8 = try utf16ToUtf8Alloc(vm.gpa, ps.asString().units);
        defer vm.gpa.free(p8);
        try src.appendSlice(vm.gpa, p8);
    }
    try src.appendSlice(vm.gpa, "\n) {\n");
    if (args.len > 0) {
        const bs = try vm.toStringVal(args[args.len - 1]);
        try vm.protect(bs);
        defer vm.unprotect();
        const b8 = try utf16ToUtf8Alloc(vm.gpa, bs.asString().units);
        defer vm.gpa.free(b8);
        try src.appendSlice(vm.gpa, b8);
    }
    try src.appendSlice(vm.gpa, "\n});");
    return vm.evalSource(src.items);
}
