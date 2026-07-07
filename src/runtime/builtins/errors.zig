//! Error constructor + Error.prototype natives.

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

pub fn nativeError(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const obj = if (this.isObject() and this.asObject() != vm.global_object)
        this.asObject()
    else
        try vm.newObject(vm.error_proto);
    try vm.protect(Value.fromObject(obj));
    defer vm.unprotect();
    const msg = argAt(args, 0);
    if (!msg.isUndefined()) {
        const s = try vm.toStringVal(msg);
        try vm.defineData(obj, "message", s, true, false, true);
    }
    return Value.fromObject(obj);
}

pub fn nativeErrorToString(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const vm = castVm(ctx);
    if (!this.isObject()) return vm.throwTypeError("Error.prototype.toString called on non-object");
    const name_v = try vm.getProperty(this, "name");
    const name = try vm.toStringVal(name_v);
    try vm.protect(name);
    defer vm.unprotect();
    const msg_v = try vm.getProperty(this, "message");
    const msg = try vm.toStringVal(msg_v);
    try vm.protect(msg);
    defer vm.unprotect();
    if (msg.asString().units.len == 0) return name;
    if (name.asString().units.len == 0) return msg;
    // name + ": " + message
    const sep = try vm.makeString(": ");
    try vm.protect(sep);
    defer vm.unprotect();
    const first = try vm.concat(name.asString().units, sep.asString().units);
    try vm.protect(first);
    defer vm.unprotect();
    return vm.concat(first.asString().units, msg.asString().units);
}
