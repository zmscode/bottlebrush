//! ArrayBuffer, TypedArray flavors, and DataView natives.

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
const doubleToInt32 = support_mod.doubleToInt32;
const isCallable = support_mod.isCallable;
const optNumber = support_mod.optNumber;
const readTypedElement = support_mod.readTypedElement;
const relativeIndex = support_mod.relativeIndex;
const toBoolean = support_mod.toBoolean;
const writeTypedElement = support_mod.writeTypedElement;

pub fn nativeArrayBuffer(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    if (!this.isObject()) return vm.throwTypeError("Constructor ArrayBuffer requires 'new'");
    const len_f = try vm.toNumber(argAt(args, 0));
    if (std.math.isNan(len_f) or len_f < 0 or len_f > 0x7fffffff) return vm.throwRangeError("Invalid array buffer length");
    const len: u32 = @intFromFloat(len_f);
    const data = try vm.gpa.alloc(u8, len);
    @memset(data, 0);
    this.asObject().buffer_data = data;
    return this;
}

pub fn typedArrayConstructor(comptime kind: gc.TAKind) gc.NativeFn {
    return struct {
        fn call(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
            const vm = castVm(ctx);
            if (!this.isObject()) return vm.throwTypeError("Constructor requires 'new'");
            const obj = this.asObject();
            const bpe = gc.bytesPerElement(kind);
            const arg = argAt(args, 0);

            if (arg.isObject() and arg.asObject().buffer_data != null and arg.asObject().ta == null) {
                // View over an existing ArrayBuffer.
                const buffer = arg.asObject();
                const off_f = if (args.len > 1) try vm.toNumber(args[1]) else 0;
                const offset: u32 = @intFromFloat(@max(0, off_f));
                const avail = buffer.buffer_data.?.len - @min(offset, buffer.buffer_data.?.len);
                const length: u32 = if (args.len > 2 and !args[2].isUndefined())
                    @intFromFloat(@max(0, try vm.toNumber(args[2])))
                else
                    @intCast(avail / bpe);
                if (offset + length * bpe > buffer.buffer_data.?.len) return vm.throwRangeError("Invalid typed array length");
                obj.ta = .{ .buffer = buffer, .offset = offset, .length = length, .kind = kind };
            } else if (arg.isObject() and (arg.asObject().is_array or arg.asObject().ta != null)) {
                // Copy from an array or another typed array.
                const src = arg.asObject();
                const length: u32 = if (src.is_array) @intCast(src.elements.items.len) else src.ta.?.length;
                const buffer = try vm.newArrayBuffer(length * bpe);
                obj.ta = .{ .buffer = buffer, .offset = 0, .length = length, .kind = kind };
                var i: u32 = 0;
                while (i < length) : (i += 1) {
                    const el = if (src.is_array) src.elements.items[i] else readTypedElement(src.ta.?, i);
                    writeTypedElement(obj.ta.?, i, try vm.toNumber(el));
                }
            } else {
                // Length (or empty).
                const len_f = if (arg.isUndefined()) 0 else try vm.toNumber(arg);
                if (std.math.isNan(len_f) or len_f < 0 or len_f > 0x3fffffff) return vm.throwRangeError("Invalid typed array length");
                const length: u32 = @intFromFloat(len_f);
                const buffer = try vm.newArrayBuffer(length * bpe);
                obj.ta = .{ .buffer = buffer, .offset = 0, .length = length, .kind = kind };
            }
            return this;
        }
    }.call;
}

pub fn thisTypedArray(vm: *Vm, this: Value) Error!gc.TypedArrayView {
    if (!this.isObject() or this.asObject().ta == null) return vm.throwTypeError("not a TypedArray");
    return this.asObject().ta.?;
}

pub fn nativeTAFill(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const ta = try thisTypedArray(vm, this);
    const n = try vm.toNumber(argAt(args, 0));
    const len: i64 = @intCast(ta.length);
    const start = relativeIndex(try optNumber(vm, argAt(args, 1), 0), len);
    const end = relativeIndex(try optNumber(vm, argAt(args, 2), @floatFromInt(len)), len);
    var i = start;
    while (i < end) : (i += 1) writeTypedElement(ta, @intCast(i), n);
    return this;
}

pub fn nativeTASet(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const ta = try thisTypedArray(vm, this);
    const src = argAt(args, 0);
    const offset: u32 = @intFromFloat(@max(0, try optNumber(vm, argAt(args, 1), 0)));
    if (src.isObject() and src.asObject().is_array) {
        const a = src.asObject();
        const n = a.array_length;
        if (@as(u64, offset) + n > ta.length) return vm.throwRangeError("offset is out of bounds");
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            try vm.checkBudget();
            writeTypedElement(ta, offset + i, try vm.toNumber(Vm.arrayGetOwn(a, i) orelse Value.undefined_value));
        }
    } else if (src.isObject() and src.asObject().ta != null) {
        const s = src.asObject().ta.?;
        if (offset + s.length > ta.length) return vm.throwRangeError("offset is out of bounds");
        var i: u32 = 0;
        while (i < s.length) : (i += 1) writeTypedElement(ta, offset + i, readTypedElement(s, i).asNumber());
    } else {
        return vm.throwTypeError("argument is not array-like");
    }
    return Value.undefined_value;
}

pub fn nativeTASubarray(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const ta = try thisTypedArray(vm, this);
    const len: i64 = @intCast(ta.length);
    const start = relativeIndex(try optNumber(vm, argAt(args, 0), 0), len);
    const end = relativeIndex(try optNumber(vm, argAt(args, 1), @floatFromInt(len)), len);
    const new_len: u32 = if (end > start) @intCast(end - start) else 0;
    const bpe = gc.bytesPerElement(ta.kind);
    // Shares the same backing buffer (a view, not a copy).
    const view = try vm.newTypedArray(this.asObject().prototype, ta.buffer, ta.offset + @as(u32, @intCast(start)) * bpe, new_len, ta.kind);
    return Value.fromObject(view);
}

pub fn nativeTAJoin(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const ta = try thisTypedArray(vm, this);
    const sep = if (argAt(args, 0).isUndefined()) try vm.makeString(",") else try vm.toStringVal(argAt(args, 0));
    try vm.protect(sep);
    defer vm.unprotect();
    var buf: std.ArrayList(u16) = .empty;
    defer buf.deinit(vm.gpa);
    var i: u32 = 0;
    while (i < ta.length) : (i += 1) {
        if (i > 0) try buf.appendSlice(vm.gpa, sep.asString().units);
        const s = try vm.toStringVal(readTypedElement(ta, i));
        try buf.appendSlice(vm.gpa, s.asString().units);
    }
    return vm.makeStringFromUtf16(buf.items);
}

pub fn nativeTAForEach(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const ta = try thisTypedArray(vm, this);
    const cb = argAt(args, 0);
    if (!isCallable(cb)) return vm.throwTypeError("callback is not a function");
    var i: u32 = 0;
    while (i < ta.length) : (i += 1) {
        _ = try vm.callValue(cb, Value.undefined_value, &.{ readTypedElement(ta, i), Value.fromNumber(@floatFromInt(i)), this });
    }
    return Value.undefined_value;
}

pub fn nativeTAIndexOf(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const ta = try thisTypedArray(vm, this);
    const target = try vm.toNumber(argAt(args, 0));
    var i: u32 = 0;
    while (i < ta.length) : (i += 1) {
        if (readTypedElement(ta, i).asNumber() == target) return Value.fromNumber(@floatFromInt(i));
    }
    return Value.fromNumber(-1);
}

pub fn nativeDataView(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    if (!this.isObject()) return vm.throwTypeError("Constructor DataView requires 'new'");
    const buf_v = argAt(args, 0);
    if (!buf_v.isObject() or buf_v.asObject().buffer_data == null or buf_v.asObject().ta != null) {
        return vm.throwTypeError("First argument to DataView constructor must be an ArrayBuffer");
    }
    const buffer = buf_v.asObject();
    const total = buffer.buffer_data.?.len;
    const offset: u32 = @intFromFloat(@max(0, try optNumber(vm, argAt(args, 1), 0)));
    if (offset > total) return vm.throwRangeError("Start offset is outside the bounds of the buffer");
    const length: u32 = if (args.len > 2 and !args[2].isUndefined())
        @intFromFloat(@max(0, try vm.toNumber(args[2])))
    else
        @intCast(total - offset);
    if (offset + length > total) return vm.throwRangeError("Invalid DataView length");
    const obj = this.asObject();
    obj.ta = .{ .buffer = buffer, .offset = offset, .length = length, .kind = .u8 };
    obj.is_dataview = true;
    return this;
}

pub fn thisDataView(vm: *Vm, this: Value) Error!gc.TypedArrayView {
    if (!this.isObject() or !this.asObject().is_dataview) return vm.throwTypeError("not a DataView");
    return this.asObject().ta.?;
}

/// DataView.prototype.get<Type>(byteOffset, littleEndian?). `single_byte`
/// types ignore the endianness argument; DataView defaults to big-endian.
pub fn dataViewGet(comptime T: type, comptime is_float: bool, comptime single_byte: bool) gc.NativeFn {
    return struct {
        fn call(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
            const vm = castVm(ctx);
            const dv = try thisDataView(vm, this);
            const off: u32 = @intFromFloat(@max(0, try vm.toNumber(argAt(args, 0))));
            const size = @sizeOf(T);
            if (off + size > dv.length) return vm.throwRangeError("Offset is outside the bounds of the DataView");
            const endian: std.builtin.Endian = if (single_byte or toBoolean(argAt(args, 1))) .little else .big;
            const bytes = dv.buffer.buffer_data.?;
            const p = bytes[dv.offset + off ..][0..size];
            if (is_float) {
                const Bits = if (T == f32) u32 else u64;
                const raw = std.mem.readInt(Bits, p, endian);
                return Value.fromNumber(@as(T, @bitCast(raw)));
            }
            return Value.fromNumber(@floatFromInt(std.mem.readInt(T, p, endian)));
        }
    }.call;
}

pub fn dataViewSet(comptime T: type, comptime is_float: bool, comptime single_byte: bool) gc.NativeFn {
    return struct {
        fn call(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
            const vm = castVm(ctx);
            const dv = try thisDataView(vm, this);
            const off: u32 = @intFromFloat(@max(0, try vm.toNumber(argAt(args, 0))));
            const size = @sizeOf(T);
            if (off + size > dv.length) return vm.throwRangeError("Offset is outside the bounds of the DataView");
            const n = try vm.toNumber(argAt(args, 1));
            const endian: std.builtin.Endian = if (single_byte or toBoolean(argAt(args, 2))) .little else .big;
            const bytes = dv.buffer.buffer_data.?;
            const p = bytes[dv.offset + off ..][0..size];
            if (is_float) {
                const Bits = if (T == f32) u32 else u64;
                const casted: T = @floatCast(n);
                std.mem.writeInt(Bits, p, @bitCast(casted), endian);
            } else {
                const bits: u32 = @bitCast(doubleToInt32(n));
                const UT = std.meta.Int(.unsigned, @bitSizeOf(T));
                std.mem.writeInt(UT, p, @truncate(bits), endian);
            }
            return Value.undefined_value;
        }
    }.call;
}
