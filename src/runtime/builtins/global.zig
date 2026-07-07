//! Global functions: parseInt/parseFloat, isNaN/isFinite, URI coding.

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
const coerceToString = support_mod.coerceToString;
const hexLikeDigit = support_mod.hexLikeDigit;
const isJsSpace = support_mod.isJsSpace;
const utf16ToUtf8Alloc = support_mod.utf16ToUtf8Alloc;

pub fn nativeIsNaN(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    return Value.fromBool(std.math.isNan(try vm.toNumber(argAt(args, 0))));
}

pub fn nativeIsFinite(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const n = try vm.toNumber(argAt(args, 0));
    return Value.fromBool(!std.math.isNan(n) and !std.math.isInf(n));
}

pub fn nativeParseInt(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, argAt(args, 0));
    try vm.protect(sv);
    defer vm.unprotect();
    var s = sv.asString().units;
    while (s.len > 0 and isJsSpace(s[0])) s = s[1..];
    var sign: f64 = 1;
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
        if (s[0] == '-') sign = -1;
        s = s[1..];
    }
    var radix: u32 = if (args.len >= 2) (try vm.toUint32(args[1])) & 0xffff_ffff else 0;
    if (radix != 0 and (radix < 2 or radix > 36)) return Value.fromNumber(std.math.nan(f64));
    if ((radix == 0 or radix == 16) and s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        s = s[2..];
        radix = 16;
    }
    if (radix == 0) radix = 10;
    var value: f64 = 0;
    var any = false;
    for (s) |c| {
        const d = hexLikeDigit(c) orelse break;
        if (d >= radix) break;
        value = value * @as(f64, @floatFromInt(radix)) + @as(f64, @floatFromInt(d));
        any = true;
    }
    if (!any) return Value.fromNumber(std.math.nan(f64));
    return Value.fromNumber(sign * value);
}

pub fn nativeParseFloat(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, argAt(args, 0));
    try vm.protect(sv);
    defer vm.unprotect();
    var s = sv.asString().units;
    while (s.len > 0 and isJsSpace(s[0])) s = s[1..];

    // Consume the longest prefix that forms a StrDecimalLiteral.
    var i: usize = 0;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(vm.gpa);
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        try buf.append(vm.gpa, @intCast(s[i]));
        i += 1;
    }
    if (i + 8 <= s.len and std.mem.eql(u16, s[i .. i + 8], &[_]u16{ 'I', 'n', 'f', 'i', 'n', 'i', 't', 'y' })) {
        const neg = buf.items.len > 0 and buf.items[0] == '-';
        return Value.fromNumber(if (neg) -std.math.inf(f64) else std.math.inf(f64));
    }
    var digits: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        try buf.append(vm.gpa, @intCast(s[i]));
        digits += 1;
    }
    if (i < s.len and s[i] == '.') {
        try buf.append(vm.gpa, '.');
        i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            try buf.append(vm.gpa, @intCast(s[i]));
            digits += 1;
        }
    }
    if (digits == 0) return Value.fromNumber(std.math.nan(f64));
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        const mark = buf.items.len;
        var j = i + 1;
        var ebuf: std.ArrayList(u8) = .empty;
        defer ebuf.deinit(vm.gpa);
        try ebuf.append(vm.gpa, 'e');
        if (j < s.len and (s[j] == '+' or s[j] == '-')) {
            try ebuf.append(vm.gpa, @intCast(s[j]));
            j += 1;
        }
        var edigits: usize = 0;
        while (j < s.len and s[j] >= '0' and s[j] <= '9') : (j += 1) {
            try ebuf.append(vm.gpa, @intCast(s[j]));
            edigits += 1;
        }
        if (edigits > 0) {
            try buf.appendSlice(vm.gpa, ebuf.items);
        } else {
            buf.shrinkRetainingCapacity(mark);
        }
    }
    const parsed = std.fmt.parseFloat(f64, buf.items) catch return Value.fromNumber(std.math.nan(f64));
    return Value.fromNumber(parsed);
}

pub fn uriUnreserved(c: u8, comptime component: bool) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '!', '~', '*', '\'', '(', ')' => true,
        // encodeURI additionally leaves the reserved set unescaped.
        ';', '/', '?', ':', '@', '&', '=', '+', '$', ',', '#' => !component,
        else => false,
    };
}

pub fn uriEncode(ctx: *anyopaque, this: Value, args: []const Value, comptime component: bool) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, argAt(args, 0));
    try vm.protect(sv);
    defer vm.unprotect();
    const utf8 = try utf16ToUtf8Alloc(vm.gpa, sv.asString().units);
    defer vm.gpa.free(utf8);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.gpa);
    const hex = "0123456789ABCDEF";
    for (utf8) |b| {
        if (uriUnreserved(b, component)) {
            try out.append(vm.gpa, b);
        } else {
            try out.append(vm.gpa, '%');
            try out.append(vm.gpa, hex[b >> 4]);
            try out.append(vm.gpa, hex[b & 15]);
        }
    }
    return vm.makeString(out.items);
}

pub fn nativeEncodeURIComponent(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return uriEncode(ctx, this, args, true);
}

pub fn nativeEncodeURI(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return uriEncode(ctx, this, args, false);
}

pub fn nativeDecodeURIComponent(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, argAt(args, 0));
    try vm.protect(sv);
    defer vm.unprotect();
    const utf8 = try utf16ToUtf8Alloc(vm.gpa, sv.asString().units);
    defer vm.gpa.free(utf8);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.gpa);
    var i: usize = 0;
    while (i < utf8.len) {
        if (utf8[i] == '%') {
            if (i + 2 >= utf8.len) return vm.throwTypeError("URI malformed");
            const hi = hexLikeDigit(utf8[i + 1]) orelse return vm.throwTypeError("URI malformed");
            const lo = hexLikeDigit(utf8[i + 2]) orelse return vm.throwTypeError("URI malformed");
            if (hi > 15 or lo > 15) return vm.throwTypeError("URI malformed");
            try out.append(vm.gpa, @intCast(hi * 16 + lo));
            i += 3;
        } else {
            try out.append(vm.gpa, utf8[i]);
            i += 1;
        }
    }
    return vm.makeString(out.items);
}
