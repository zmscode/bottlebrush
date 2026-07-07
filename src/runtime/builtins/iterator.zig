//! Iterator/generator prototype natives and the built-in iterable
//! (values/keys/entries) implementations.

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
const readTypedElement = support_mod.readTypedElement;

pub fn nativeIterSelf(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    _ = args;
    return this;
}

pub fn nativeGeneratorNext(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return castVm(ctx).generatorResume(this, argAt(args, 0), 0);
}

pub fn nativeGeneratorReturn(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return castVm(ctx).generatorResume(this, argAt(args, 0), 1);
}

pub fn nativeGeneratorThrow(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return castVm(ctx).generatorResume(this, argAt(args, 0), 2);
}

pub fn nativeIterableValues(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    return castVm(ctx).makeIterator(this, 0);
}

pub fn nativeIterableKeys(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    return castVm(ctx).makeIterator(this, 1);
}

pub fn nativeIterableEntries(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    return castVm(ctx).makeIterator(this, 2);
}

pub fn nativeIteratorNext(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const vm = castVm(ctx);
    if (!this.isObject()) return vm.throwTypeError("not an iterator");
    const t = try vm.getProperty(this, "\x00itT");
    if (t.isUndefined()) return vm.makeIterResult(Value.undefined_value, true);
    const idx: usize = @intFromFloat((try vm.getProperty(this, "\x00itI")).asNumber());
    const kind: u8 = @intFromFloat((try vm.getProperty(this, "\x00itK")).asNumber());

    var value: Value = Value.undefined_value;
    var exhausted = false;
    const index_val = Value.fromNumber(@floatFromInt(idx));
    if (t.isString()) {
        const units = t.asString().units;
        if (idx >= units.len) exhausted = true else value = try vm.makeStringFromUtf16(units[idx .. idx + 1]);
    } else if (t.isObject()) {
        const o = t.asObject();
        if (o.is_array) {
            // Array iterator visits 0..length; holes yield `undefined`.
            if (idx >= @as(usize, o.array_length)) exhausted = true else {
                value = try vm.iterEntryValue(kind, index_val, Vm.arrayGetOwn(o, @intCast(idx)) orelse Value.undefined_value);
            }
        } else if (o.ta) |ta| {
            if (idx >= ta.length) exhausted = true else value = try vm.iterEntryValue(kind, index_val, readTypedElement(ta, @intCast(idx)));
        } else if (o.collection == .set) {
            if (idx >= o.elements.items.len) exhausted = true else {
                const v = o.elements.items[idx];
                value = if (kind == 2) try vm.iterPair(v, v) else v;
            }
        } else if (o.collection == .map) {
            const count = o.elements.items.len / 2;
            if (idx >= count) exhausted = true else {
                const k = o.elements.items[idx * 2];
                const v = o.elements.items[idx * 2 + 1];
                value = switch (kind) {
                    1 => k,
                    2 => try vm.iterPair(k, v),
                    else => v,
                };
            }
        } else exhausted = true;
    } else exhausted = true;

    if (exhausted) {
        try vm.setProperty(this, "\x00itT", Value.undefined_value);
        return vm.makeIterResult(Value.undefined_value, true);
    }
    try vm.setProperty(this, "\x00itI", Value.fromNumber(@floatFromInt(idx + 1)));
    return vm.makeIterResult(value, false);
}
