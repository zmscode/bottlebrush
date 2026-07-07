//! RegExp constructor/prototype natives, backed by the bilby engine.

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
const regexp_flags_key = support_mod.regexp_flags_key;
const regexp_source_key = support_mod.regexp_source_key;
const utf16ToUtf8Alloc = support_mod.utf16ToUtf8Alloc;

pub fn hasFlag(flags: []const u8, f: u8) bool {
    return std.mem.indexOfScalar(u8, flags, f) != null;
}

pub fn nativeRegExp(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const pat_v = argAt(args, 0);
    // If the first argument is already a RegExp, copy its source.
    var src_owned: ?[]u8 = null;
    defer if (src_owned) |s| vm.gpa.free(s);
    var source: []const u8 = "";
    if (pat_v.isObject() and pat_v.asObject().prototype == vm.regexp_proto) {
        const s = try vm.getProperty(pat_v, "source");
        if (s.isString()) {
            src_owned = try utf16ToUtf8Alloc(vm.gpa, s.asString().units);
            source = src_owned.?;
        }
    } else if (!pat_v.isUndefined()) {
        const s = try vm.toStringVal(pat_v);
        try vm.protect(s);
        defer vm.unprotect();
        src_owned = try utf16ToUtf8Alloc(vm.gpa, s.asString().units);
        source = src_owned.?;
    }
    const flags_v = argAt(args, 1);
    var flags_owned: ?[]u8 = null;
    defer if (flags_owned) |f| vm.gpa.free(f);
    var flags: []const u8 = "";
    if (!flags_v.isUndefined()) {
        const f = try vm.toStringVal(flags_v);
        try vm.protect(f);
        defer vm.unprotect();
        flags_owned = try utf16ToUtf8Alloc(vm.gpa, f.asString().units);
        flags = flags_owned.?;
    }
    return Value.fromObject(try vm.makeRegExp(source, flags));
}

/// Getter backing for the RegExp.prototype flag accessors. Non-RegExp `this`
/// (including RegExp.prototype itself) yields undefined per spec-adjacent
/// leniency rather than throwing.
pub fn regexpFlagGetter(comptime field: []const u8) gc.NativeFn {
    return struct {
        fn get(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
            _ = ctx;
            _ = args;
            if (this.isObject()) {
                if (this.asObject().regex) |re| return Value.fromBool(@field(re.flags, field));
            }
            return Value.undefined_value;
        }
    }.get;
}

pub fn nativeRegExpGetSource(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const vm = castVm(ctx);
    if (this.isObject()) {
        if (this.asObject().properties.get(regexp_source_key)) |d| return d.value;
    }
    return vm.makeString("(?:)"); // %RegExp.prototype%.source
}

pub fn nativeRegExpGetFlags(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const vm = castVm(ctx);
    if (this.isObject()) {
        if (this.asObject().properties.get(regexp_flags_key)) |d| return d.value;
    }
    return vm.makeString("");
}

/// Write `lastIndex` with strict [[Set]] semantics: a non-writable own
/// `lastIndex` makes exec throw TypeError (spec: Set(..., true)).
pub fn regexpSetLastIndex(vm: *Vm, this: Value, n: f64) Error!void {
    if (this.isObject()) {
        if (this.asObject().properties.getPtr("lastIndex")) |desc| {
            if (!desc.is_accessor and !desc.writable) {
                return vm.throwTypeError("cannot assign to read-only property 'lastIndex'");
            }
        }
    }
    try vm.setProperty(this, "lastIndex", Value.fromNumber(n));
}

/// RegExp.prototype.test — spec: equivalent to `exec(s) !== null`.
pub fn nativeRegExpTest(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const r = try nativeRegExpExec(ctx, this, args);
    return Value.fromBool(!r.isNull());
}

/// RegExp.prototype.exec — run the compiled bilby matcher against the subject,
/// honouring `lastIndex` for global/sticky regexes. Returns the match array
/// (with `index`/`input`/`groups`) or null.
pub fn nativeRegExpExec(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    if (!this.isObject() or this.asObject().regex == null)
        return vm.throwTypeError("RegExp.prototype.exec called on a non-RegExp");
    const re = this.asObject().regex.?;

    const subject = try vm.toStringVal(argAt(args, 0));
    try vm.protect(subject);
    defer vm.unprotect();
    const units = subject.asString().units;

    // Spec: lastIndex is read (once) unconditionally, but only used — and
    // later written — for global/sticky regexes.
    const li = try vm.toNumber(try vm.getProperty(this, "lastIndex"));
    const track_last = re.flags.global or re.flags.sticky;
    var start: usize = 0;
    if (track_last) {
        if (li > @as(f64, @floatFromInt(units.len))) {
            try regexpSetLastIndex(vm, this, 0);
            return Value.null_value;
        }
        if (li >= 1) start = @intFromFloat(li);
    }

    const maybe = re.find(vm.gpa, units, start) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // Step budget exceeded (catastrophic backtracking).
        else => return vm.throwRangeError("regular expression too complex"),
    };
    const m = maybe orelse {
        if (track_last) try regexpSetLastIndex(vm, this, 0);
        return Value.null_value;
    };
    defer m.deinit(vm.gpa);

    const whole = m.groups[0].?;
    if (track_last) try regexpSetLastIndex(vm, this, @floatFromInt(whole.end));

    // Result array: [$0, $1, …] plus index / input / groups properties.
    const arr = try vm.newArray(0);
    try vm.protect(Value.fromObject(arr));
    defer vm.unprotect();
    for (m.groups) |g| {
        const v = if (g) |span| try vm.makeStringFromUtf16(units[span.start..span.end]) else Value.undefined_value;
        try vm.arrayAppend(arr, v);
    }
    try vm.defineData(arr, "index", Value.fromNumber(@floatFromInt(whole.start)), true, true, true);
    try vm.defineData(arr, "input", subject, true, true, true);

    // `groups`: an object of named captures, or undefined when there are none.
    if (re.names.count() > 0) {
        const groups_obj = try vm.newObject(vm.object_proto);
        try vm.protect(Value.fromObject(groups_obj));
        defer vm.unprotect();
        var it = re.names.iterator();
        while (it.next()) |entry| {
            const g = m.groups[entry.value_ptr.*];
            const v = if (g) |span| try vm.makeStringFromUtf16(units[span.start..span.end]) else Value.undefined_value;
            try vm.defineData(groups_obj, entry.key_ptr.*, v, true, true, true);
        }
        try vm.defineData(arr, "groups", Value.fromObject(groups_obj), true, true, true);
    } else {
        try vm.defineData(arr, "groups", Value.undefined_value, true, true, true);
    }

    return Value.fromObject(arr);
}

pub fn nativeRegExpToString(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const vm = castVm(ctx);
    if (!this.isObject()) return vm.throwTypeError("RegExp.prototype.toString called on non-object");
    const src_v = try vm.getProperty(this, "source");
    const flags_v = try vm.getProperty(this, "flags");
    const src = try vm.toStringVal(src_v);
    try vm.protect(src);
    defer vm.unprotect();
    const flags = try vm.toStringVal(flags_v);
    try vm.protect(flags);
    defer vm.unprotect();
    // "/" + source + "/" + flags
    var buf: std.ArrayList(u16) = .empty;
    defer buf.deinit(vm.gpa);
    try buf.append(vm.gpa, '/');
    try buf.appendSlice(vm.gpa, src.asString().units);
    try buf.append(vm.gpa, '/');
    try buf.appendSlice(vm.gpa, flags.asString().units);
    return vm.makeStringFromUtf16(buf.items);
}
