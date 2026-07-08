//! String constructor and String.prototype natives, including the
//! RegExp-consuming methods (match/search/replace/split).

const std = @import("std");
const gc = @import("../../gc.zig");
const bc = @import("../../bytecode.zig");
const bilby = @import("bilby");
const Value = @import("../../value.zig").Value;
const interpreter = @import("../../interpreter.zig");
const Vm = interpreter.Vm;
const Error = interpreter.Error;

const regexp_mod = @import("regexp.zig");
const nativeRegExpExec = regexp_mod.nativeRegExpExec;
const support_mod = @import("../support.zig");
const toIntegerOrInfinity = support_mod.toIntegerOrInfinity;
const argAt = support_mod.argAt;
const castVm = support_mod.castVm;
const clampIndex = support_mod.clampIndex;
const coerceToString = support_mod.coerceToString;
const compareUtf16 = support_mod.compareUtf16;
const indexOfUtf16 = support_mod.indexOfUtf16;
const isCallable = support_mod.isCallable;
const isJsSpace = support_mod.isJsSpace;
const optNumber = support_mod.optNumber;
const prim_key = support_mod.prim_key;
const relativeIndex = support_mod.relativeIndex;
const utf16ToUtf8Alloc = support_mod.utf16ToUtf8Alloc;

pub fn nativeString(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const s = if (args.len == 0) try vm.makeString("") else try vm.toStringVal(args[0]);
    // As a constructor, `this` is a fresh object inheriting String.prototype:
    // store [[StringData]] so wrapper coercions and methods reach the primitive.
    if (this.isObject() and this.asObject().prototype == vm.string_proto) {
        try vm.protect(s);
        defer vm.unprotect();
        try vm.defineData(this.asObject(), prim_key, s, false, false, false);
        try vm.defineData(this.asObject(), "length", Value.fromNumber(@floatFromInt(s.asString().units.len)), false, false, false);
    }
    return s;
}

pub fn nativeStringToString(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    if (this.isString()) return this;
    // A String wrapper returns its boxed [[StringData]]. Anything else throws
    // (per spec) — which also breaks the toString -> ToPrimitive recursion.
    if (this.isObject()) {
        if (this.asObject().properties.get(prim_key)) |d| {
            if (d.value.isString()) return d.value;
        }
    }
    return castVm(ctx).throwTypeError("String.prototype.toString requires a String");
}

pub fn nativeStringLastIndexOf(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    const units = sv.asString().units;
    const needle_s = try coerceToString(vm, argAt(args, 0));
    try vm.protect(needle_s);
    defer vm.unprotect();
    const needle = needle_s.asString().units;

    // fromIndex clamps the latest allowed *start* position (NaN -> +inf).
    var limit: usize = units.len;
    if (args.len >= 2 and !args[1].isUndefined()) {
        const n = try vm.toNumber(args[1]);
        if (!std.math.isNan(n)) {
            if (n < 0) {
                limit = 0;
            } else if (n < @as(f64, @floatFromInt(units.len))) {
                limit = @intFromFloat(n);
            }
        }
    }
    if (needle.len > units.len) return Value.fromNumber(-1);
    var start = @min(limit, units.len - needle.len);
    while (true) {
        if (std.mem.eql(u16, units[start .. start + needle.len], needle)) return Value.fromNumber(@floatFromInt(start));
        if (start == 0) return Value.fromNumber(-1);
        start -= 1;
    }
}

pub fn nativeStringLocaleCompare(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    const other = try coerceToString(vm, argAt(args, 0));
    return Value.fromNumber(@floatFromInt(compareUtf16(sv.asString().units, other.asString().units)));
}

pub fn nativeStringCharAt(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    const units = sv.asString().units;
    const n = try vm.toNumber(argAt(args, 0));
    if (std.math.isNan(n) or n < 0 or n >= @as(f64, @floatFromInt(units.len))) return vm.makeString("");
    const i: usize = @intFromFloat(n);
    return vm.makeStringFromUtf16(units[i .. i + 1]);
}

pub fn nativeStringCharCodeAt(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    const units = sv.asString().units;
    const n = try vm.toNumber(argAt(args, 0));
    if (std.math.isNan(n) or n < 0 or n >= @as(f64, @floatFromInt(units.len))) return Value.fromNumber(std.math.nan(f64));
    return Value.fromNumber(@floatFromInt(units[@intFromFloat(n)]));
}

pub fn nativeStringIndexOf(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    const search = try coerceToString(vm, argAt(args, 0));
    try vm.protect(search);
    defer vm.unprotect();
    const idx = indexOfUtf16(sv.asString().units, search.asString().units, 0);
    return Value.fromNumber(if (idx) |i| @floatFromInt(i) else -1);
}

pub fn nativeStringIncludes(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    const search = try coerceToString(vm, argAt(args, 0));
    try vm.protect(search);
    defer vm.unprotect();
    return Value.fromBool(indexOfUtf16(sv.asString().units, search.asString().units, 0) != null);
}

pub fn nativeStringStartsWith(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    const search = try coerceToString(vm, argAt(args, 0));
    try vm.protect(search);
    defer vm.unprotect();
    return Value.fromBool(std.mem.startsWith(u16, sv.asString().units, search.asString().units));
}

pub fn nativeStringEndsWith(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    const search = try coerceToString(vm, argAt(args, 0));
    try vm.protect(search);
    defer vm.unprotect();
    return Value.fromBool(std.mem.endsWith(u16, sv.asString().units, search.asString().units));
}

pub fn nativeStringSlice(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    const units = sv.asString().units;
    const len: i64 = @intCast(units.len);
    const start = relativeIndex(try optNumber(vm, argAt(args, 0), 0), len);
    const end = relativeIndex(try optNumber(vm, argAt(args, 1), @floatFromInt(len)), len);
    if (start >= end) return vm.makeString("");
    return vm.makeStringFromUtf16(units[@intCast(start)..@intCast(end)]);
}

pub fn nativeStringSubstring(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    const units = sv.asString().units;
    const len: i64 = @intCast(units.len);
    var a = clampIndex(try optNumber(vm, argAt(args, 0), 0), len);
    var b = clampIndex(try optNumber(vm, argAt(args, 1), @floatFromInt(len)), len);
    if (a > b) {
        const t = a;
        a = b;
        b = t;
    }
    return vm.makeStringFromUtf16(units[@intCast(a)..@intCast(b)]);
}

pub fn nativeStringToUpperCase(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    return stringMapCase(castVm(ctx), this, true);
}

pub fn nativeStringToLowerCase(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    return stringMapCase(castVm(ctx), this, false);
}

pub fn stringMapCase(vm: *Vm, this: Value, upper: bool) Error!Value {
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    const units = sv.asString().units;
    const out = try vm.gpa.alloc(u16, units.len);
    defer vm.gpa.free(out);
    for (units, 0..) |u, i| {
        // ASCII case mapping (full Unicode case folding is deferred).
        out[i] = if (upper and u >= 'a' and u <= 'z') u - 32 else if (!upper and u >= 'A' and u <= 'Z') u + 32 else u;
    }
    return vm.makeStringFromUtf16(out);
}

pub fn nativeStringTrim(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    const units = sv.asString().units;
    var start: usize = 0;
    var end: usize = units.len;
    while (start < end and isJsSpace(units[start])) start += 1;
    while (end > start and isJsSpace(units[end - 1])) end -= 1;
    return vm.makeStringFromUtf16(units[start..end]);
}

pub fn nativeStringRepeat(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    const n = try vm.toNumber(argAt(args, 0));
    if (n < 0 or std.math.isNan(n) or n > 4294967295) return vm.throwRangeError("invalid count value");
    const count: usize = @intFromFloat(n);
    const units = sv.asString().units;
    var buf: std.ArrayList(u16) = .empty;
    defer buf.deinit(vm.gpa);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try vm.checkBudget();
        try buf.appendSlice(vm.gpa, units);
    }
    return vm.makeStringFromUtf16(buf.items);
}

pub fn nativeStringConcat(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    var buf: std.ArrayList(u16) = .empty;
    defer buf.deinit(vm.gpa);
    try buf.appendSlice(vm.gpa, sv.asString().units);
    for (args) |a| {
        const s = try coerceToString(vm, a);
        try buf.appendSlice(vm.gpa, s.asString().units);
    }
    return vm.makeStringFromUtf16(buf.items);
}

/// If `pat` has a callable method under `sym_key`, invoke it — this is the
/// @@match/@@replace/@@search/@@split protocol (RegExp.prototype provides the
/// built-in implementations; custom pattern objects can hook it). Primitives
/// never dispatch: the spec only consults the symbol when the pattern is an
/// Object, so e.g. a poisoned String.prototype[@@match] must not be read.
fn dispatchPatternSymbol(vm: *Vm, pat: Value, sym_key: []const u8, argv: []const Value) Error!?Value {
    if (!pat.isObject() or sym_key.len == 0) return null;
    const method = try vm.getProperty(pat, sym_key);
    if (!isCallable(method)) return null;
    return try vm.callValue(method, pat, argv);
}

/// RegExp @@split core: split between matches; captures are spliced in.
fn splitRegexImpl(vm: *Vm, re: *const bilby.Regex, sv: Value, lim: u32) Error!Value {
    const units = sv.asString().units;
    const result = try vm.newArray(0);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    if (lim == 0) return Value.fromObject(result);
    if (units.len == 0) {
        // Empty subject: [] if the pattern matches empty, else [S].
        if (try regexFind(vm, re, units, 0)) |m| {
            m.deinit(vm.gpa);
        } else {
            try vm.arrayAppend(result, sv);
        }
        return Value.fromObject(result);
    }
    var p: usize = 0; // start of the current unmatched piece
    var pos: usize = 0;
    while (pos < units.len) {
        const m = (try regexFind(vm, re, units, pos)) orelse break;
        defer m.deinit(vm.gpa);
        const w = m.groups[0].?;
        if (w.start >= units.len) break; // separator may not match at the very end
        if (w.end == p) {
            pos = w.start + 1; // empty/degenerate match: advance, no split
            continue;
        }
        try vm.arrayAppend(result, try vm.makeStringFromUtf16(units[p..w.start]));
        if (result.array_length >= lim) return Value.fromObject(result);
        for (m.groups[1..]) |g| {
            const v = if (g) |sp| try vm.makeStringFromUtf16(units[sp.start..sp.end]) else Value.undefined_value;
            try vm.arrayAppend(result, v);
            if (result.array_length >= lim) return Value.fromObject(result);
        }
        p = w.end;
        pos = if (w.end == w.start) w.start + 1 else w.end;
    }
    try vm.arrayAppend(result, try vm.makeStringFromUtf16(units[p..]));
    return Value.fromObject(result);
}

pub fn nativeStringSplit(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();

    const sep_v = argAt(args, 0);
    const limit_v = argAt(args, 1);
    // Protocol dispatch happens before limit coercion (spec order).
    if (try dispatchPatternSymbol(vm, sep_v, vm.symbol_split_key, &.{ sv, limit_v })) |r| return r;

    const units = sv.asString().units;
    const result = try vm.newArray(0);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();

    const lim: u32 = if (limit_v.isUndefined()) std.math.maxInt(u32) else try vm.toUint32(limit_v);
    if (lim == 0) return Value.fromObject(result);

    if (sep_v.isUndefined()) {
        try vm.arrayAppend(result, sv);
        return Value.fromObject(result);
    }

    const sep = try coerceToString(vm, sep_v);
    try vm.protect(sep);
    defer vm.unprotect();
    const sep_units = sep.asString().units;

    if (sep_units.len == 0) {
        // Split into individual code units (bounded by limit).
        for (units) |u| {
            if (result.array_length >= lim) break;
            const piece = try vm.makeStringFromUtf16(&[_]u16{u});
            try vm.arrayAppend(result, piece);
        }
        return Value.fromObject(result);
    }

    var start: usize = 0;
    while (indexOfUtf16(units, sep_units, start)) |idx| {
        const piece = try vm.makeStringFromUtf16(units[start..idx]);
        try vm.arrayAppend(result, piece);
        if (result.array_length >= lim) return Value.fromObject(result);
        start = idx + sep_units.len;
    }
    const last = try vm.makeStringFromUtf16(units[start..]);
    try vm.arrayAppend(result, last);
    return Value.fromObject(result);
}

/// Get the RegExp object for a String-method argument. Per spec, a non-RegExp
/// argument is coerced via `new RegExp(ToString(arg))` (undefined -> empty
/// pattern). Caller should protect the returned object across allocations.
pub fn regexArgObject(vm: *Vm, v: Value) Error!*gc.Object {
    if (v.isObject() and v.asObject().regex != null) return v.asObject();
    var src_owned: ?[]u8 = null;
    defer if (src_owned) |s| vm.gpa.free(s);
    var source: []const u8 = "";
    if (!v.isUndefined()) {
        const s = try vm.toStringVal(v);
        try vm.protect(s);
        defer vm.unprotect();
        src_owned = try utf16ToUtf8Alloc(vm.gpa, s.asString().units);
        source = src_owned.?;
    }
    return vm.makeRegExp(source, "");
}

/// Run `re` against `units` from `start`, mapping engine errors to JS throws.
pub fn regexFind(vm: *Vm, re: *const bilby.Regex, units: []const u16, start: usize) Error!?bilby.Match {
    return re.find(vm.gpa, units, start) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return vm.throwRangeError("regular expression too complex"),
    };
}

/// RegExp @@search core: first match index or -1; lastIndex untouched.
fn searchRegexImpl(vm: *Vm, rx: *gc.Object, sv: Value) Error!Value {
    const m = (try regexFind(vm, rx.regex.?, sv.asString().units, 0)) orelse return Value.fromNumber(-1);
    defer m.deinit(vm.gpa);
    return Value.fromNumber(@floatFromInt(m.groups[0].?.start));
}

pub fn nativeStringSearch(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    if (try dispatchPatternSymbol(vm, argAt(args, 0), vm.symbol_search_key, &.{sv})) |r| return r;
    const rx = try regexArgObject(vm, argAt(args, 0));
    try vm.protect(Value.fromObject(rx));
    defer vm.unprotect();
    return searchRegexImpl(vm, rx, sv);
}

/// RegExp @@match core: exec once (non-global) or collect all matched
/// substrings (global), null when nothing matches.
fn matchRegexImpl(vm: *Vm, rx: *gc.Object, sv: Value) Error!Value {
    const re = rx.regex.?;

    // Non-global: identical to rx.exec(S).
    if (!re.flags.global) return nativeRegExpExec(@ptrCast(vm), Value.fromObject(rx), &.{sv});

    // Global: an array of all matched substrings (no captures), or null.
    try vm.setProperty(Value.fromObject(rx), "lastIndex", Value.fromNumber(0));
    const units = sv.asString().units;
    const result = try vm.newArray(0);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    var pos: usize = 0;
    var found = false;
    while (pos <= units.len) {
        const m = (try regexFind(vm, re, units, pos)) orelse break;
        const w = m.groups[0].?;
        m.deinit(vm.gpa);
        found = true;
        try vm.arrayAppend(result, try vm.makeStringFromUtf16(units[w.start..w.end]));
        pos = if (w.end == w.start) w.end + 1 else w.end;
    }
    if (!found) return Value.null_value;
    return Value.fromObject(result);
}

pub fn nativeStringMatch(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    if (try dispatchPatternSymbol(vm, argAt(args, 0), vm.symbol_match_key, &.{sv})) |r| return r;
    const rx = try regexArgObject(vm, argAt(args, 0));
    try vm.protect(Value.fromObject(rx));
    defer vm.unprotect();
    return matchRegexImpl(vm, rx, sv);
}

/// GetSubstitution: expand `$$ $& $` $' $n $nn $<name>` in a replacement
/// string. Unrecognized `$` sequences are literal.
pub fn appendSubstitution(
    vm: *Vm,
    out: *std.ArrayList(u16),
    rep: []const u16,
    units: []const u16,
    groups: []const ?bilby.Span,
    names: *const std.StringHashMapUnmanaged(u32),
) Error!void {
    const whole = groups[0].?;
    var i: usize = 0;
    while (i < rep.len) {
        const c = rep[i];
        if (c != '$' or i + 1 >= rep.len) {
            try out.append(vm.gpa, c);
            i += 1;
            continue;
        }
        switch (rep[i + 1]) {
            '$' => {
                try out.append(vm.gpa, '$');
                i += 2;
            },
            '&' => {
                try out.appendSlice(vm.gpa, units[whole.start..whole.end]);
                i += 2;
            },
            '`' => {
                try out.appendSlice(vm.gpa, units[0..whole.start]);
                i += 2;
            },
            '\'' => {
                try out.appendSlice(vm.gpa, units[whole.end..]);
                i += 2;
            },
            '0'...'9' => {
                var num: usize = rep[i + 1] - '0';
                var consumed: usize = 2;
                // Prefer the two-digit reference when it names a real group.
                if (i + 2 < rep.len and rep[i + 2] >= '0' and rep[i + 2] <= '9') {
                    const two = num * 10 + (rep[i + 2] - '0');
                    if (two >= 1 and two < groups.len) {
                        num = two;
                        consumed = 3;
                    }
                }
                if (num >= 1 and num < groups.len) {
                    if (groups[num]) |sp| try out.appendSlice(vm.gpa, units[sp.start..sp.end]);
                    i += consumed;
                } else {
                    try out.append(vm.gpa, '$');
                    i += 1;
                }
            },
            '<' => {
                // $<name> — only meaningful when the pattern has named groups.
                const close = std.mem.indexOfScalarPos(u16, rep, i + 2, '>') orelse {
                    try out.append(vm.gpa, '$');
                    i += 1;
                    continue;
                };
                if (names.count() == 0) {
                    try out.append(vm.gpa, '$');
                    i += 1;
                    continue;
                }
                var name8: std.ArrayList(u8) = .empty;
                defer name8.deinit(vm.gpa);
                for (rep[i + 2 .. close]) |u| try name8.append(vm.gpa, @intCast(u & 0xff));
                if (names.get(name8.items)) |idx| {
                    if (groups[idx]) |sp| try out.appendSlice(vm.gpa, units[sp.start..sp.end]);
                }
                i = close + 1;
            },
            else => {
                try out.append(vm.gpa, '$');
                i += 1;
            },
        }
    }
}

/// Invoke a replacer callback with (matched, p1.., offset, string) and append
/// the ToString of its result.
pub fn appendReplacerCall(
    vm: *Vm,
    out: *std.ArrayList(u16),
    cb: Value,
    units: []const u16,
    groups: []const ?bilby.Span,
    subject: Value,
) Error!void {
    var argv: std.ArrayList(Value) = .empty;
    defer argv.deinit(vm.gpa);
    var protected: usize = 0;
    defer {
        var k: usize = 0;
        while (k < protected) : (k += 1) vm.unprotect();
    }
    for (groups) |g| {
        if (g) |sp| {
            const s = try vm.makeStringFromUtf16(units[sp.start..sp.end]);
            try vm.protect(s);
            protected += 1;
            try argv.append(vm.gpa, s);
        } else {
            try argv.append(vm.gpa, Value.undefined_value);
        }
    }
    try argv.append(vm.gpa, Value.fromNumber(@floatFromInt(groups[0].?.start)));
    try argv.append(vm.gpa, subject);
    const r = try vm.callValue(cb, Value.undefined_value, argv.items);
    try vm.protect(r);
    defer vm.unprotect();
    const rs = try vm.toStringVal(r);
    try out.appendSlice(vm.gpa, rs.asString().units);
}

/// RegExp @@replace core: substitute the first (or all, when global) matches
/// with a replacement string or callback result.
fn replaceRegexImpl(vm: *Vm, rx: *gc.Object, sv: Value, rep: Value) Error!Value {
    const units = sv.asString().units;
    const rep_is_fn = isCallable(rep);
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(vm.gpa);
    const re = rx.regex.?;
    var last_end: usize = 0;
    var pos: usize = 0;
    while (pos <= units.len) {
        const m = (try regexFind(vm, re, units, pos)) orelse break;
        defer m.deinit(vm.gpa);
        const w = m.groups[0].?;
        try out.appendSlice(vm.gpa, units[last_end..w.start]);
        if (rep_is_fn) {
            try appendReplacerCall(vm, &out, rep, units, m.groups, sv);
        } else {
            const rs = try vm.toStringVal(rep);
            try vm.protect(rs);
            defer vm.unprotect();
            try appendSubstitution(vm, &out, rs.asString().units, units, m.groups, &re.names);
        }
        last_end = w.end;
        pos = if (w.end == w.start) w.end + 1 else w.end;
        if (!re.flags.global) break;
    }
    try out.appendSlice(vm.gpa, units[last_end..]);
    return vm.makeStringFromUtf16(out.items);
}

pub fn nativeStringReplace(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    const units = sv.asString().units;
    const pat = argAt(args, 0);
    const rep = argAt(args, 1);
    if (try dispatchPatternSymbol(vm, pat, vm.symbol_replace_key, &.{ sv, rep })) |r| return r;
    const rep_is_fn = isCallable(rep);

    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(vm.gpa);

    // String pattern: replace the first occurrence only.
    const pat_s = try vm.toStringVal(pat);
    try vm.protect(pat_s);
    defer vm.unprotect();
    const pat_units = pat_s.asString().units;
    const idx = indexOfUtf16(units, pat_units, 0) orelse return sv;
    const span = [_]?bilby.Span{.{ .start = idx, .end = idx + pat_units.len }};
    try out.appendSlice(vm.gpa, units[0..idx]);
    if (rep_is_fn) {
        try appendReplacerCall(vm, &out, rep, units, &span, sv);
    } else {
        const rs = try vm.toStringVal(rep);
        try vm.protect(rs);
        defer vm.unprotect();
        const no_names: std.StringHashMapUnmanaged(u32) = .empty;
        try appendSubstitution(vm, &out, rs.asString().units, units, &span, &no_names);
    }
    try out.appendSlice(vm.gpa, units[idx + pat_units.len ..]);
    return vm.makeStringFromUtf16(out.items);
}

pub fn nativeStringFromCharCode(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const out = try vm.gpa.alloc(u16, args.len);
    defer vm.gpa.free(out);
    for (args, 0..) |a, i| {
        const n = try vm.toNumber(a);
        out[i] = @truncate(@as(u32, @intFromFloat(@mod(n, 65536))));
    }
    return vm.makeStringFromUtf16(out);
}

pub fn nativeStringAt(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    const units = sv.asString().units;
    var k = try toIntegerOrInfinity(vm, argAt(args, 0));
    if (k < 0) k += @floatFromInt(units.len);
    if (k < 0 or k >= @as(f64, @floatFromInt(units.len))) return Value.undefined_value;
    const i: usize = @intFromFloat(k);
    return vm.makeStringFromUtf16(units[i .. i + 1]);
}

fn stringPad(vm: *Vm, this: Value, args: []const Value, at_start: bool) Error!Value {
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    const units = sv.asString().units;
    const target_f = try toIntegerOrInfinity(vm, argAt(args, 0));
    if (target_f <= @as(f64, @floatFromInt(units.len))) return sv;
    if (target_f > 1e7) return vm.throwRangeError("pad length too large");
    const target: usize = @intFromFloat(target_f);

    var fill_units: []const u16 = &[_]u16{' '};
    var fill_owned: ?Value = null;
    if (!argAt(args, 1).isUndefined()) {
        const fs = try vm.toStringVal(args[1]);
        fill_owned = fs;
        try vm.protect(fs);
        fill_units = fs.asString().units;
    }
    defer if (fill_owned != null) vm.unprotect();
    if (fill_units.len == 0) return sv;

    var buf: std.ArrayList(u16) = .empty;
    defer buf.deinit(vm.gpa);
    const pad_len = target - units.len;
    if (!at_start) try buf.appendSlice(vm.gpa, units);
    var i: usize = 0;
    while (i < pad_len) : (i += 1) {
        try vm.checkBudget();
        try buf.append(vm.gpa, fill_units[i % fill_units.len]);
    }
    if (at_start) try buf.appendSlice(vm.gpa, units);
    return vm.makeStringFromUtf16(buf.items);
}

pub fn nativeStringPadStart(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return stringPad(castVm(ctx), this, args, true);
}
pub fn nativeStringPadEnd(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return stringPad(castVm(ctx), this, args, false);
}

pub fn nativeStringCodePointAt(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    const units = sv.asString().units;
    const n = try toIntegerOrInfinity(vm, argAt(args, 0));
    if (n < 0 or n >= @as(f64, @floatFromInt(units.len))) return Value.undefined_value;
    const i: usize = @intFromFloat(n);
    const first = units[i];
    if (first >= 0xd800 and first <= 0xdbff and i + 1 < units.len) {
        const second = units[i + 1];
        if (second >= 0xdc00 and second <= 0xdfff) {
            const cp = 0x10000 + (@as(u32, first - 0xd800) << 10) + (second - 0xdc00);
            return Value.fromNumber(@floatFromInt(cp));
        }
    }
    return Value.fromNumber(@floatFromInt(first));
}

pub fn nativeStringFromCodePoint(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    var buf: std.ArrayList(u16) = .empty;
    defer buf.deinit(vm.gpa);
    for (args) |a| {
        const n = try vm.toNumber(a);
        if (std.math.isNan(n) or n < 0 or n > 0x10FFFF or n != std.math.trunc(n)) {
            return vm.throwRangeError("invalid code point");
        }
        const cp: u32 = @intFromFloat(n);
        if (cp <= 0xffff) {
            try buf.append(vm.gpa, @intCast(cp));
        } else {
            const c = cp - 0x10000;
            try buf.append(vm.gpa, @intCast(0xd800 + (c >> 10)));
            try buf.append(vm.gpa, @intCast(0xdc00 + (c & 0x3ff)));
        }
    }
    return vm.makeStringFromUtf16(buf.items);
}

pub fn nativeStringSubstr(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    const units = sv.asString().units;
    const len: i64 = @intCast(units.len);
    var start: i64 = @intFromFloat(@max(@min(try toIntegerOrInfinity(vm, argAt(args, 0)), 9.0e18), -9.0e18));
    if (start < 0) start = @max(len + start, 0);
    if (start >= len) return vm.makeString("");
    const want: i64 = if (argAt(args, 1).isUndefined())
        len - start
    else
        @intFromFloat(@max(@min(try toIntegerOrInfinity(vm, args[1]), 9.0e18), 0));
    const count = @min(want, len - start);
    if (count <= 0) return vm.makeString("");
    return vm.makeStringFromUtf16(units[@intCast(start)..@intCast(start + count)]);
}

fn stringTrimSide(vm: *Vm, this: Value, trim_start: bool, trim_end: bool) Error!Value {
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    var units = sv.asString().units;
    if (trim_start) while (units.len > 0 and isJsSpace(units[0])) {
        units = units[1..];
    };
    if (trim_end) while (units.len > 0 and isJsSpace(units[units.len - 1])) {
        units = units[0 .. units.len - 1];
    };
    return vm.makeStringFromUtf16(units);
}

pub fn nativeStringTrimStart(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    return stringTrimSide(castVm(ctx), this, true, false);
}
pub fn nativeStringTrimEnd(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    return stringTrimSide(castVm(ctx), this, false, true);
}

pub fn nativeStringReplaceAll(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const pat = argAt(args, 0);
    // A RegExp pattern must be global; its @@replace already loops on g.
    if (pat.isObject() and pat.asObject().regex != null) {
        if (!pat.asObject().regex.?.flags.global) {
            return vm.throwTypeError("replaceAll must be called with a global RegExp");
        }
        const rx_sv = try coerceToString(vm, this);
        try vm.protect(rx_sv);
        defer vm.unprotect();
        return replaceRegexImpl(vm, pat.asObject(), rx_sv, argAt(args, 1));
    }
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    const units = sv.asString().units;
    const rep = argAt(args, 1);
    const rep_is_fn = isCallable(rep);
    const pat_s = try vm.toStringVal(pat);
    try vm.protect(pat_s);
    defer vm.unprotect();
    const pat_units = pat_s.asString().units;

    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(vm.gpa);
    var pos: usize = 0;
    const no_names: std.StringHashMapUnmanaged(u32) = .empty;
    while (pos <= units.len) {
        try vm.checkBudget();
        const idx = indexOfUtf16(units, pat_units, pos) orelse break;
        try out.appendSlice(vm.gpa, units[pos..idx]);
        const span = [_]?bilby.Span{.{ .start = idx, .end = idx + pat_units.len }};
        if (rep_is_fn) {
            try appendReplacerCall(vm, &out, rep, units, &span, sv);
        } else {
            const rs = try vm.toStringVal(rep);
            try vm.protect(rs);
            defer vm.unprotect();
            try appendSubstitution(vm, &out, rs.asString().units, units, &span, &no_names);
        }
        pos = if (pat_units.len == 0) idx + 1 else idx + pat_units.len;
        if (pat_units.len == 0 and idx < units.len) try out.appendSlice(vm.gpa, units[idx .. idx + 1]);
    }
    if (pos <= units.len) try out.appendSlice(vm.gpa, units[pos..]);
    return vm.makeStringFromUtf16(out.items);
}

// ---- RegExp.prototype pattern-protocol methods ------------------------------

/// Validate the receiver of a RegExp @@-method and coerce the subject string.
fn regexProtocolThis(vm: *Vm, this: Value, args: []const Value) Error!struct { rx: *gc.Object, sv: Value } {
    if (!this.isObject() or this.asObject().regex == null) {
        return vm.throwTypeError("receiver is not a RegExp");
    }
    const sv = try coerceToString(vm, argAt(args, 0));
    return .{ .rx = this.asObject(), .sv = sv };
}

pub fn nativeRegExpSymbolMatch(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const p = try regexProtocolThis(vm, this, args);
    try vm.protect(p.sv);
    defer vm.unprotect();
    return matchRegexImpl(vm, p.rx, p.sv);
}

pub fn nativeRegExpSymbolSearch(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const p = try regexProtocolThis(vm, this, args);
    try vm.protect(p.sv);
    defer vm.unprotect();
    return searchRegexImpl(vm, p.rx, p.sv);
}

pub fn nativeRegExpSymbolReplace(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const p = try regexProtocolThis(vm, this, args);
    try vm.protect(p.sv);
    defer vm.unprotect();
    return replaceRegexImpl(vm, p.rx, p.sv, argAt(args, 1));
}

pub fn nativeRegExpSymbolSplit(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const p = try regexProtocolThis(vm, this, args);
    try vm.protect(p.sv);
    defer vm.unprotect();
    const limit_v = argAt(args, 1);
    const lim: u32 = if (limit_v.isUndefined()) std.math.maxInt(u32) else try vm.toUint32(limit_v);
    return splitRegexImpl(vm, p.rx.regex.?, p.sv, lim);
}
