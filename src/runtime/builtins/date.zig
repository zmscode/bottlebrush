//! Date constructor, civil-date math, formatting, and the component
//! get/set method family.

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
const utf16ToUtf8Alloc = support_mod.utf16ToUtf8Alloc;

pub const date_key = "\x00DateValue";

pub fn dateTimeOf(vm: *Vm, this: Value) Error!f64 {
    if (!this.isObject()) return vm.throwTypeError("this is not a Date");
    const v = try vm.getProperty(this, date_key);
    return if (v.isNumber()) v.asNumber() else std.math.nan(f64);
}

pub fn setDateTime(vm: *Vm, obj: *gc.Object, ms: f64) Error!void {
    try vm.defineData(obj, date_key, Value.fromNumber(ms), true, false, false);
}

pub fn timeClip(t: f64) f64 {
    if (std.math.isNan(t) or std.math.isInf(t) or @abs(t) > 8.64e15) return std.math.nan(f64);
    return std.math.trunc(t);
}

pub const CivilDate = struct { y: i64, m: i64, d: i64 };

pub fn civilFromDays(z_in: i64) CivilDate {
    const z = z_in + 719468;
    const era = @divTrunc(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = y + (if (m <= 2) @as(i64, 1) else 0), .m = m, .d = d };
}

pub fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divTrunc(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400;
    const mp = if (m > 2) m - 3 else m + 9;
    const doy = @divTrunc(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub const DateParts = struct { year: i64, month: i64, day: i64, hours: i64, minutes: i64, seconds: i64, millis: i64, weekday: i64 };

pub fn msToParts(ms_f: f64) DateParts {
    const t: i64 = @intFromFloat(std.math.floor(ms_f));
    const day = @divFloor(t, 86400000);
    var rem = @mod(t, 86400000);
    const hours = @divFloor(rem, 3600000);
    rem = @mod(rem, 3600000);
    const minutes = @divFloor(rem, 60000);
    rem = @mod(rem, 60000);
    const seconds = @divFloor(rem, 1000);
    const millis = @mod(rem, 1000);
    const weekday = @mod(@mod(day + 4, 7) + 7, 7); // day 0 (epoch) is Thursday
    const c = civilFromDays(day);
    return .{ .year = c.y, .month = c.m - 1, .day = c.d, .hours = hours, .minutes = minutes, .seconds = seconds, .millis = millis, .weekday = weekday };
}

/// Assemble a time value from components (month is 0-based; overflow allowed).
pub fn makeDateTime(year_in: f64, month: f64, day: f64, h: f64, mi: f64, s: f64, ms: f64) f64 {
    for ([_]f64{ year_in, month, day, h, mi, s, ms }) |c| {
        if (std.math.isNan(c) or std.math.isInf(c)) return std.math.nan(f64);
    }
    var year: i64 = @intFromFloat(std.math.trunc(year_in));
    var mon: i64 = @intFromFloat(std.math.trunc(month));
    year += @divFloor(mon, 12);
    mon = @mod(mon, 12);
    const days = daysFromCivil(year, mon + 1, 1) + @as(i64, @intFromFloat(std.math.trunc(day))) - 1;
    const total = days * 86400000 +
        @as(i64, @intFromFloat(std.math.trunc(h))) * 3600000 +
        @as(i64, @intFromFloat(std.math.trunc(mi))) * 60000 +
        @as(i64, @intFromFloat(std.math.trunc(s))) * 1000 +
        @as(i64, @intFromFloat(std.math.trunc(ms)));
    return @floatFromInt(total);
}

/// Current wall-clock time in ms since the Unix epoch.
pub fn nowMs() f64 {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const ts = std.Io.Clock.now(.real, io);
    const ms: i64 = @intCast(@divTrunc(ts.nanoseconds, 1_000_000));
    return @floatFromInt(ms);
}

pub fn nativeDateNow(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    _ = this;
    _ = args;
    return Value.fromNumber(nowMs());
}

pub fn componentsToMs(vm: *Vm, args: []const Value) Error!f64 {
    var y = try vm.toNumber(argAt(args, 0));
    if (y >= 0 and y <= 99 and y == std.math.trunc(y)) y += 1900;
    const mo = try vm.toNumber(argAt(args, 1));
    const d = if (args.len > 2) try vm.toNumber(args[2]) else 1;
    const h = if (args.len > 3) try vm.toNumber(args[3]) else 0;
    const mi = if (args.len > 4) try vm.toNumber(args[4]) else 0;
    const s = if (args.len > 5) try vm.toNumber(args[5]) else 0;
    const ms = if (args.len > 6) try vm.toNumber(args[6]) else 0;
    return makeDateTime(y, mo, d, h, mi, s, ms);
}

pub fn nativeDate(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    // Called without `new`: return a string for the current time.
    if (!this.isObject() or this.asObject().prototype != vm.date_proto) {
        var buf: [40]u8 = undefined;
        return vm.makeString(formatIso(&buf, nowMs()));
    }
    const obj = this.asObject();
    var ms: f64 = undefined;
    if (args.len == 0) {
        ms = nowMs();
    } else if (args.len == 1) {
        const a = args[0];
        if (a.isObject() and a.asObject().prototype == vm.date_proto) {
            ms = try dateTimeOf(vm, a);
        } else if (a.isString()) {
            const utf8 = try utf16ToUtf8Alloc(vm.gpa, a.asString().units);
            defer vm.gpa.free(utf8);
            ms = parseIsoDate(utf8);
        } else {
            ms = timeClip(try vm.toNumber(a));
        }
    } else {
        ms = timeClip(try componentsToMs(vm, args));
    }
    try setDateTime(vm, obj, timeClip(ms));
    return this;
}

pub fn nativeDateUTC(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    return Value.fromNumber(timeClip(try componentsToMs(vm, args)));
}

pub fn nativeDateParse(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const s = try coerceToString(vm, argAt(args, 0));
    try vm.protect(s);
    defer vm.unprotect();
    const utf8 = try utf16ToUtf8Alloc(vm.gpa, s.asString().units);
    defer vm.gpa.free(utf8);
    return Value.fromNumber(parseIsoDate(utf8));
}

pub fn nativeDateGetTime(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    return Value.fromNumber(try dateTimeOf(castVm(ctx), this));
}

pub fn nativeDateSetTime(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    if (!this.isObject()) return vm.throwTypeError("this is not a Date");
    const ms = timeClip(try vm.toNumber(argAt(args, 0)));
    try setDateTime(vm, this.asObject(), ms);
    return Value.fromNumber(ms);
}

pub fn dateField(vm: *Vm, this: Value, comptime field: []const u8) Error!Value {
    const t = try dateTimeOf(vm, this);
    if (std.math.isNan(t)) return Value.fromNumber(std.math.nan(f64));
    const p = msToParts(t);
    return Value.fromNumber(@floatFromInt(@field(p, field)));
}

pub fn nativeDateGetFullYear(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    return dateField(castVm(ctx), this, "year");
}

pub fn nativeDateGetMonth(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    return dateField(castVm(ctx), this, "month");
}

pub fn nativeDateGetDate(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    return dateField(castVm(ctx), this, "day");
}

pub fn nativeDateGetDay(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    return dateField(castVm(ctx), this, "weekday");
}

pub fn nativeDateGetHours(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    return dateField(castVm(ctx), this, "hours");
}

pub fn nativeDateGetMinutes(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    return dateField(castVm(ctx), this, "minutes");
}

pub fn nativeDateGetSeconds(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    return dateField(castVm(ctx), this, "seconds");
}

pub fn nativeDateGetMs(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    return dateField(castVm(ctx), this, "millis");
}

pub const weekday_names = [7][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

pub const month_names = [12][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// One component-setter for the whole set*/setUTC* family (local == UTC here).
/// `first` indexes [year, month, day, hours, minutes, seconds, ms]; `count`
/// arguments starting there are replaced (missing ones keep current values).
pub fn dateSet(vm: *Vm, this: Value, args: []const Value, first: usize, count: usize) Error!Value {
    const t = try dateTimeOf(vm, this);
    var comps: [7]f64 = undefined;
    if (std.math.isNan(t)) {
        if (first == 0) {
            // setFullYear on an invalid date starts from +0 per spec.
            comps = .{ 1970, 0, 1, 0, 0, 0, 0 };
        } else {
            @memset(&comps, std.math.nan(f64));
        }
    } else {
        const p = msToParts(t);
        comps = .{
            @floatFromInt(p.year),   @floatFromInt(p.month),   @floatFromInt(p.day),
            @floatFromInt(p.hours),  @floatFromInt(p.minutes), @floatFromInt(p.seconds),
            @floatFromInt(p.millis),
        };
    }
    var i: usize = 0;
    while (i < count and i < args.len) : (i += 1) {
        comps[first + i] = try vm.toNumber(args[i]);
    }
    const nt = timeClip(makeDateTime(comps[0], comps[1], comps[2], comps[3], comps[4], comps[5], comps[6]));
    if (!this.isObject()) return vm.throwTypeError("this is not a Date");
    try setDateTime(vm, this.asObject(), nt);
    return Value.fromNumber(nt);
}

pub fn nativeDateSetFullYear(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return dateSet(castVm(ctx), this, args, 0, 3);
}

pub fn nativeDateSetMonth(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return dateSet(castVm(ctx), this, args, 1, 2);
}

pub fn nativeDateSetDate(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return dateSet(castVm(ctx), this, args, 2, 1);
}

pub fn nativeDateSetHours(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return dateSet(castVm(ctx), this, args, 3, 4);
}

pub fn nativeDateSetMinutes(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return dateSet(castVm(ctx), this, args, 4, 3);
}

pub fn nativeDateSetSeconds(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return dateSet(castVm(ctx), this, args, 5, 2);
}

pub fn nativeDateSetMilliseconds(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return dateSet(castVm(ctx), this, args, 6, 1);
}

pub fn nativeDateGetTimezoneOffset(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const t = try dateTimeOf(castVm(ctx), this);
    if (std.math.isNan(t)) return Value.fromNumber(std.math.nan(f64));
    return Value.fromNumber(0); // local time == UTC in this engine
}

pub fn nativeDateToDateString(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const vm = castVm(ctx);
    const t = try dateTimeOf(vm, this);
    if (std.math.isNan(t)) return vm.makeString("Invalid Date");
    const p = msToParts(t);
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s} {s} {d:0>2} {d}", .{
        weekday_names[@intCast(p.weekday)], month_names[@intCast(p.month)], @as(u64, @intCast(p.day)), p.year,
    }) catch unreachable;
    return vm.makeString(s);
}

pub fn nativeDateToTimeString(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const vm = castVm(ctx);
    const t = try dateTimeOf(vm, this);
    if (std.math.isNan(t)) return vm.makeString("Invalid Date");
    const p = msToParts(t);
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}:{d:0>2} GMT+0000 (Coordinated Universal Time)", .{
        @as(u64, @intCast(p.hours)), @as(u64, @intCast(p.minutes)), @as(u64, @intCast(p.seconds)),
    }) catch unreachable;
    return vm.makeString(s);
}

pub fn nativeDateToUTCString(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const vm = castVm(ctx);
    const t = try dateTimeOf(vm, this);
    if (std.math.isNan(t)) return vm.makeString("Invalid Date");
    const p = msToParts(t);
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        weekday_names[@intCast(p.weekday)], @as(u64, @intCast(p.day)),   month_names[@intCast(p.month)],
        p.year,                             @as(u64, @intCast(p.hours)), @as(u64, @intCast(p.minutes)),
        @as(u64, @intCast(p.seconds)),
    }) catch unreachable;
    return vm.makeString(s);
}

/// Write `val` right-aligned, zero-padded to `width` digits into `dst`.
pub fn writePadded(dst: []u8, val: i64, width: usize) usize {
    var v: u64 = @intCast(if (val < 0) 0 else val);
    var j = width;
    while (j > 0) {
        j -= 1;
        dst[j] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    return width;
}

pub fn formatIso(buf: []u8, ms: f64) []const u8 {
    if (std.math.isNan(ms)) return "Invalid Date";
    const p = msToParts(ms);
    var i: usize = 0;
    i += writePadded(buf[i..], p.year, 4);
    buf[i] = '-';
    i += 1;
    i += writePadded(buf[i..], p.month + 1, 2);
    buf[i] = '-';
    i += 1;
    i += writePadded(buf[i..], p.day, 2);
    buf[i] = 'T';
    i += 1;
    i += writePadded(buf[i..], p.hours, 2);
    buf[i] = ':';
    i += 1;
    i += writePadded(buf[i..], p.minutes, 2);
    buf[i] = ':';
    i += 1;
    i += writePadded(buf[i..], p.seconds, 2);
    buf[i] = '.';
    i += 1;
    i += writePadded(buf[i..], p.millis, 3);
    buf[i] = 'Z';
    i += 1;
    return buf[0..i];
}

pub fn nativeDateToISOString(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const vm = castVm(ctx);
    const t = try dateTimeOf(vm, this);
    if (std.math.isNan(t)) return vm.throwRangeError("Invalid time value");
    var buf: [40]u8 = undefined;
    return vm.makeString(formatIso(&buf, t));
}

/// Minimal ISO 8601 parser: `YYYY-MM-DD` and `YYYY-MM-DDTHH:mm:ss(.sss)?Z?`.
pub fn parseIsoDate(s: []const u8) f64 {
    const nan = std.math.nan(f64);
    if (s.len < 10) return nan;
    const year = std.fmt.parseInt(i64, s[0..4], 10) catch return nan;
    if (s[4] != '-' or s[7] != '-') return nan;
    const month = std.fmt.parseInt(i64, s[5..7], 10) catch return nan;
    const day = std.fmt.parseInt(i64, s[8..10], 10) catch return nan;
    var h: f64 = 0;
    var mi: f64 = 0;
    var sec: f64 = 0;
    var ms: f64 = 0;
    if (s.len >= 19 and (s[10] == 'T' or s[10] == ' ')) {
        h = @floatFromInt(std.fmt.parseInt(i64, s[11..13], 10) catch return nan);
        mi = @floatFromInt(std.fmt.parseInt(i64, s[14..16], 10) catch return nan);
        sec = @floatFromInt(std.fmt.parseInt(i64, s[17..19], 10) catch return nan);
        if (s.len >= 23 and s[19] == '.') {
            ms = @floatFromInt(std.fmt.parseInt(i64, s[20..23], 10) catch return nan);
        }
    }
    return timeClip(makeDateTime(@floatFromInt(year), @floatFromInt(month - 1), @floatFromInt(day), h, mi, sec, ms));
}
