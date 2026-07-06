//! The bytecode interpreter (phase-2 plan §3–4).
//!
//! Executes a compiled `bytecode.Program`. Each function activation gets a
//! register file and a heap `Environment`. Calls recurse on the native stack
//! (depth-guarded). Exceptions set `pending_exception` and unwind via each
//! frame's handler table.
//!
//! The VM is a GC root provider: `markRoots` marks every active frame's
//! registers and environment plus the pending exception and globals.
//!
//! Phase-2 value semantics are pragmatic: coercions cover primitives; objects
//! have no `ToPrimitive` yet (they coerce to NaN / "[object Object]"), and
//! engine-thrown errors (TypeError/…) are represented as strings until real
//! Error objects arrive with the object model. These are documented
//! simplifications, not final behavior.

const std = @import("std");
const gc = @import("gc.zig");
const bc = @import("bytecode.zig");
const Value = @import("value.zig").Value;

pub const Error = error{ JsThrow, OutOfMemory, StackOverflow };

const max_call_depth = 2000;

const Frame = struct {
    code: *const bc.CodeBlock,
    env: *gc.Environment,
    regs: []Value,
};

pub const Vm = struct {
    gpa: std.mem.Allocator,
    heap: gc.Heap,
    frames: std.ArrayList(*Frame) = .empty,
    pending_exception: ?Value = null,
    depth: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) Vm {
        return .{ .gpa = gpa, .heap = gc.Heap.init(gpa) };
    }
    pub fn deinit(self: *Vm) void {
        self.frames.deinit(self.gpa);
        self.heap.deinit();
    }

    /// GC root provider. Marks all reachable roots held by the VM.
    pub fn markRoots(self: *const Vm, tracer: *gc.Tracer) void {
        if (self.pending_exception) |e| e.mark(tracer);
        for (self.frames.items) |f| {
            tracer.mark(&f.env.gc);
            for (f.regs) |v| v.mark(tracer);
        }
    }

    fn maybeStress(self: *Vm) void {
        if (self.heap.stress) _ = self.heap.collect(self);
    }

    // ---- entry -------------------------------------------------------------

    /// Run a compiled program's top-level script. Returns its completion value
    /// (the script's `return`, else undefined). On an uncaught throw returns
    /// `error.JsThrow` with `pending_exception` set.
    pub fn run(self: *Vm, program: *const bc.Program) Error!Value {
        const root = program.root;
        const env = try self.createEnv(null, root.num_env_slots);
        return self.execute(root, env);
    }

    fn createEnv(self: *Vm, parent: ?*gc.Environment, n: u32) Error!*gc.Environment {
        self.maybeStress();
        const e = try self.heap.create(gc.Environment);
        e.parent = parent;
        if (n > 0) {
            const slots = try self.gpa.alloc(Value, n);
            @memset(slots, Value.undefined_value);
            e.slots = slots;
        }
        return e;
    }

    // ---- execution ---------------------------------------------------------

    const Step = union(enum) { advance, jumped, returned: Value };

    fn execute(self: *Vm, code: *const bc.CodeBlock, env: *gc.Environment) Error!Value {
        const regs = try self.gpa.alloc(Value, code.num_registers);
        defer self.gpa.free(regs);
        @memset(regs, Value.undefined_value);

        var frame = Frame{ .code = code, .env = env, .regs = regs };
        try self.frames.append(self.gpa, &frame);
        defer _ = self.frames.pop();

        var pc: u32 = 0;
        while (true) {
            const inst = code.code[pc];
            const step = self.exec(code, env, regs, inst, &pc) catch |e| {
                if (e != error.JsThrow) return e;
                if (self.findHandler(code, pc)) |h| {
                    regs[h.catch_reg] = self.pending_exception.?;
                    self.pending_exception = null;
                    pc = h.target_pc;
                    continue;
                }
                return error.JsThrow;
            };
            switch (step) {
                .advance => pc += 1,
                .jumped => {},
                .returned => |v| return v,
            }
        }
    }

    fn findHandler(self: *const Vm, code: *const bc.CodeBlock, pc: u32) ?bc.Handler {
        _ = self;
        var best: ?bc.Handler = null;
        for (code.handlers) |h| {
            if (h.kind != .catch_clause) continue;
            if (pc >= h.try_start and pc < h.try_end) {
                // Prefer the innermost (narrowest) enclosing handler.
                if (best == null or (h.try_start >= best.?.try_start and h.try_end <= best.?.try_end)) {
                    best = h;
                }
            }
        }
        return best;
    }

    fn exec(
        self: *Vm,
        code: *const bc.CodeBlock,
        env: *gc.Environment,
        regs: []Value,
        inst: bc.Inst,
        pc: *u32,
    ) Error!Step {
        switch (inst.op) {
            .nop => {},
            .load_const => regs[inst.a] = try self.materializeConst(code.constants[inst.b]),
            .load_undefined => regs[inst.a] = Value.undefined_value,
            .load_null => regs[inst.a] = Value.null_value,
            .load_true => regs[inst.a] = Value.fromBool(true),
            .load_false => regs[inst.a] = Value.fromBool(false),
            .move => regs[inst.a] = regs[inst.b],

            .get_var => regs[inst.a] = self.envAt(env, inst.b).slots[inst.c],
            .set_var, .init_var => self.envAt(env, inst.a).slots[inst.b] = regs[inst.c],

            .add => regs[inst.a] = try self.opAdd(regs[inst.b], regs[inst.c]),
            .sub => regs[inst.a] = Value.fromNumber(try self.toNumber(regs[inst.b]) - try self.toNumber(regs[inst.c])),
            .mul => regs[inst.a] = Value.fromNumber(try self.toNumber(regs[inst.b]) * try self.toNumber(regs[inst.c])),
            .div => regs[inst.a] = Value.fromNumber(try self.toNumber(regs[inst.b]) / try self.toNumber(regs[inst.c])),
            .mod => regs[inst.a] = Value.fromNumber(jsMod(try self.toNumber(regs[inst.b]), try self.toNumber(regs[inst.c]))),
            .exp => regs[inst.a] = Value.fromNumber(std.math.pow(f64, try self.toNumber(regs[inst.b]), try self.toNumber(regs[inst.c]))),
            .neg => regs[inst.a] = Value.fromNumber(-(try self.toNumber(regs[inst.b]))),
            .to_number => regs[inst.a] = Value.fromNumber(try self.toNumber(regs[inst.b])),

            .bit_and => regs[inst.a] = Value.fromNumber(@floatFromInt(try self.toInt32(regs[inst.b]) & try self.toInt32(regs[inst.c]))),
            .bit_or => regs[inst.a] = Value.fromNumber(@floatFromInt(try self.toInt32(regs[inst.b]) | try self.toInt32(regs[inst.c]))),
            .bit_xor => regs[inst.a] = Value.fromNumber(@floatFromInt(try self.toInt32(regs[inst.b]) ^ try self.toInt32(regs[inst.c]))),
            .shl => regs[inst.a] = Value.fromNumber(@floatFromInt(jsShl(try self.toInt32(regs[inst.b]), try self.toUint32(regs[inst.c])))),
            .shr => regs[inst.a] = Value.fromNumber(@floatFromInt(jsShr(try self.toInt32(regs[inst.b]), try self.toUint32(regs[inst.c])))),
            .ushr => regs[inst.a] = Value.fromNumber(@floatFromInt(jsUshr(try self.toInt32(regs[inst.b]), try self.toUint32(regs[inst.c])))),
            .bit_not => regs[inst.a] = Value.fromNumber(@floatFromInt(~(try self.toInt32(regs[inst.b])))),

            .eq => regs[inst.a] = Value.fromBool(try self.looseEquals(regs[inst.b], regs[inst.c])),
            .ne => regs[inst.a] = Value.fromBool(!(try self.looseEquals(regs[inst.b], regs[inst.c]))),
            .strict_eq => regs[inst.a] = Value.fromBool(self.strictEquals(regs[inst.b], regs[inst.c])),
            .strict_ne => regs[inst.a] = Value.fromBool(!self.strictEquals(regs[inst.b], regs[inst.c])),
            .lt => regs[inst.a] = Value.fromBool(try self.compare(regs[inst.b], regs[inst.c], .lt)),
            .le => regs[inst.a] = Value.fromBool(try self.compare(regs[inst.b], regs[inst.c], .le)),
            .gt => regs[inst.a] = Value.fromBool(try self.compare(regs[inst.b], regs[inst.c], .gt)),
            .ge => regs[inst.a] = Value.fromBool(try self.compare(regs[inst.b], regs[inst.c], .ge)),

            .logical_not => regs[inst.a] = Value.fromBool(!toBoolean(regs[inst.b])),
            .type_of => regs[inst.a] = try self.typeOf(regs[inst.b]),

            .jump => {
                pc.* = inst.a;
                return .jumped;
            },
            .jump_if_true => if (toBoolean(regs[inst.a])) {
                pc.* = inst.b;
                return .jumped;
            },
            .jump_if_false => if (!toBoolean(regs[inst.a])) {
                pc.* = inst.b;
                return .jumped;
            },
            .jump_if_nullish => if (regs[inst.a].isNullish()) {
                pc.* = inst.b;
                return .jumped;
            },
            .jump_if_not_nullish => if (!regs[inst.a].isNullish()) {
                pc.* = inst.b;
                return .jumped;
            },

            .new_closure => regs[inst.a] = try self.makeClosure(code.children[inst.b], env),
            .call => {
                const callee = regs[inst.b];
                const args = regs[inst.b + 1 .. inst.b + 1 + inst.c];
                regs[inst.a] = try self.callValue(callee, args);
            },
            .ret => return Step{ .returned = regs[inst.a] },

            .throw => {
                self.pending_exception = regs[inst.a];
                return error.JsThrow;
            },
            .end_finally => {
                if (self.pending_exception != null) return error.JsThrow;
            },
        }
        return .advance;
    }

    fn envAt(self: *const Vm, env: *gc.Environment, depth: u32) *gc.Environment {
        _ = self;
        var e = env;
        var d = depth;
        while (d > 0) : (d -= 1) e = e.parent.?;
        return e;
    }

    // ---- calls & closures --------------------------------------------------

    fn makeClosure(self: *Vm, child: *const bc.CodeBlock, env: *gc.Environment) Error!Value {
        self.maybeStress();
        const clo = try self.heap.create(gc.Closure);
        clo.code = child;
        clo.env = env;
        const obj = try self.heap.create(gc.Object);
        obj.callable = clo;
        return Value.fromObject(obj);
    }

    fn callValue(self: *Vm, callee: Value, args: []const Value) Error!Value {
        if (!callee.isObject() or callee.asObject().callable == null) {
            return self.throwTypeError("value is not a function");
        }
        if (self.depth >= max_call_depth) return self.throwRangeError("maximum call stack size exceeded");
        self.depth += 1;
        defer self.depth -= 1;

        const clo = callee.asObject().callable.?;
        const code: *const bc.CodeBlock = @ptrCast(@alignCast(clo.code));
        const env = try self.createEnv(clo.env, code.num_env_slots);
        var i: u32 = 0;
        while (i < code.num_params) : (i += 1) {
            env.slots[i] = if (i < args.len) args[i] else Value.undefined_value;
        }
        return self.execute(code, env);
    }

    // ---- constant materialization ------------------------------------------

    fn materializeConst(self: *Vm, c: bc.Const) Error!Value {
        switch (c) {
            .number => |n| return Value.fromNumber(n),
            .string => |bytes| return self.makeString(bytes),
            .bigint => |digits| {
                self.maybeStress();
                const b = try self.heap.create(gc.BigInt);
                b.value = std.fmt.parseInt(i64, digits, 10) catch 0;
                return Value.fromBigInt(b);
            },
        }
    }

    fn makeString(self: *Vm, utf8: []const u8) Error!Value {
        self.maybeStress();
        const s = try self.heap.create(gc.String);
        s.units = std.unicode.utf8ToUtf16LeAlloc(self.gpa, utf8) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => try self.gpa.alloc(u16, 0), // cooked strings are valid UTF-8
        };
        return Value.fromString(s);
    }

    // ---- coercions ---------------------------------------------------------

    fn toNumber(self: *Vm, v: Value) Error!f64 {
        return switch (v) {
            .undefined => std.math.nan(f64),
            .null => 0,
            .boolean => |b| if (b) 1 else 0,
            .number => |n| n,
            .string => |s| stringToNumber(s.units),
            .bigint => return self.throwTypeError("cannot convert a BigInt to a number"),
            .symbol => return self.throwTypeError("cannot convert a Symbol to a number"),
            .object => std.math.nan(f64), // no ToPrimitive yet
        };
    }

    fn toInt32(self: *Vm, v: Value) Error!i32 {
        const n = try self.toNumber(v);
        return doubleToInt32(n);
    }
    fn toUint32(self: *Vm, v: Value) Error!u32 {
        const n = try self.toNumber(v);
        return @bitCast(doubleToInt32(n));
    }

    fn opAdd(self: *Vm, l: Value, r: Value) Error!Value {
        if (l.isString() or r.isString()) {
            const ls = try self.toStringValue(l);
            const rs = try self.toStringValue(r);
            return self.concat(ls, rs);
        }
        return Value.fromNumber((try self.toNumber(l)) + (try self.toNumber(r)));
    }

    fn concat(self: *Vm, a: []const u16, b: []const u16) Error!Value {
        self.maybeStress();
        const s = try self.heap.create(gc.String);
        const units = try self.gpa.alloc(u16, a.len + b.len);
        @memcpy(units[0..a.len], a);
        @memcpy(units[a.len..], b);
        s.units = units;
        return Value.fromString(s);
    }

    /// Returns UTF-16 units for a value (borrowing existing string storage, or
    /// producing freshly-materialized units for primitives).
    fn toStringValue(self: *Vm, v: Value) Error![]const u16 {
        return switch (v) {
            .string => |s| s.units,
            else => {
                var buf: [64]u8 = undefined;
                const utf8 = self.primitiveToUtf8(v, &buf) catch "?";
                // Materialize into a temporary heap string to get u16 units.
                const sv = try self.makeString(utf8);
                return sv.asString().units;
            },
        };
    }

    fn primitiveToUtf8(self: *Vm, v: Value, buf: []u8) ![]const u8 {
        _ = self;
        return switch (v) {
            .undefined => "undefined",
            .null => "null",
            .boolean => |b| if (b) "true" else "false",
            .number => |n| numberToString(n, buf),
            .bigint => |b| try std.fmt.bufPrint(buf, "{d}", .{b.value}),
            .object => "[object Object]",
            .symbol => "Symbol()",
            .string => "", // handled by caller
        };
    }

    fn typeOf(self: *Vm, v: Value) Error!Value {
        const name: []const u8 = switch (v) {
            .undefined => "undefined",
            .null => "object",
            .boolean => "boolean",
            .number => "number",
            .string => "string",
            .symbol => "symbol",
            .bigint => "bigint",
            .object => |o| if (o.callable != null) "function" else "object",
        };
        return self.makeString(name);
    }

    // ---- equality & comparison ---------------------------------------------

    fn strictEquals(self: *const Vm, a: Value, b: Value) bool {
        _ = self;
        return sameTypeStrictEq(a, b);
    }

    fn looseEquals(self: *Vm, a: Value, b: Value) Error!bool {
        // Same-type: strict semantics.
        if (@intFromEnum(std.meta.activeTag(a)) == @intFromEnum(std.meta.activeTag(b))) {
            return sameTypeStrictEq(a, b);
        }
        // null == undefined.
        if (a.isNullish() and b.isNullish()) return true;
        // number/string coercion; boolean coerces to number; others -> number.
        if (a.isNullish() or b.isNullish()) return false;
        const an = try self.toNumber(a);
        const bn = try self.toNumber(b);
        return an == bn;
    }

    const Cmp = enum { lt, le, gt, ge };

    fn compare(self: *Vm, a: Value, b: Value, op: Cmp) Error!bool {
        if (a.isString() and b.isString()) {
            const order = compareUtf16(a.asString().units, b.asString().units);
            return switch (op) {
                .lt => order < 0,
                .le => order <= 0,
                .gt => order > 0,
                .ge => order >= 0,
            };
        }
        const an = try self.toNumber(a);
        const bn = try self.toNumber(b);
        if (std.math.isNan(an) or std.math.isNan(bn)) return false;
        return switch (op) {
            .lt => an < bn,
            .le => an <= bn,
            .gt => an > bn,
            .ge => an >= bn,
        };
    }

    // ---- error throwing (placeholder string errors) ------------------------

    fn throwWith(self: *Vm, comptime kind: []const u8, msg: []const u8) Error {
        var buf: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{s}: {s}", .{ kind, msg }) catch kind;
        self.pending_exception = self.makeString(text) catch Value.undefined_value;
        return error.JsThrow;
    }
    fn throwTypeError(self: *Vm, msg: []const u8) Error {
        return self.throwWith("TypeError", msg);
    }
    fn throwRangeError(self: *Vm, msg: []const u8) Error {
        return self.throwWith("RangeError", msg);
    }
};

// ---- free helpers ----------------------------------------------------------

fn sameTypeStrictEq(a: Value, b: Value) bool {
    return switch (a) {
        .undefined => b.isUndefined(),
        .null => b.isNull(),
        .boolean => |x| b.isBoolean() and x == b.asBool(),
        .number => |x| b.isNumber() and x == b.asNumber(), // NaN != NaN, +0 == -0
        .string => |x| b.isString() and std.mem.eql(u16, x.units, b.asString().units),
        .bigint => |x| b.isBigInt() and x.value == b.asBigInt().value,
        .symbol => |x| b.isSymbol() and x == b.asSymbol(),
        .object => |x| b.isObject() and x == b.asObject(),
    };
}

pub fn toBoolean(v: Value) bool {
    return switch (v) {
        .undefined, .null => false,
        .boolean => |b| b,
        .number => |n| n != 0 and !std.math.isNan(n),
        .string => |s| s.units.len != 0,
        .bigint => |b| b.value != 0,
        .symbol, .object => true,
    };
}

fn jsMod(a: f64, b: f64) f64 {
    return @rem(a, b);
}

fn jsShl(a: i32, count: u32) i32 {
    const x: u32 = @bitCast(a);
    const sh: u5 = @intCast(count & 31);
    return @bitCast(@as(u32, @truncate(@as(u64, x) << sh)));
}
fn jsShr(a: i32, count: u32) i32 {
    const sh: u5 = @intCast(count & 31);
    return a >> sh;
}
fn jsUshr(a: i32, count: u32) u32 {
    const x: u32 = @bitCast(a);
    const sh: u5 = @intCast(count & 31);
    return x >> sh;
}

fn doubleToInt32(n: f64) i32 {
    if (std.math.isNan(n) or std.math.isInf(n)) return 0;
    const truncated = std.math.trunc(n);
    const modulo = @mod(truncated, 4294967296.0);
    const as_u32: u32 = @intFromFloat(if (modulo < 0) modulo + 4294967296.0 else modulo);
    return @bitCast(as_u32);
}

fn stringToNumber(units: []const u16) f64 {
    // Convert to ASCII, trim, parse. Non-ASCII or malformed -> NaN.
    var buf: [64]u8 = undefined;
    if (units.len == 0) return 0;
    if (units.len >= buf.len) return std.math.nan(f64);
    var n: usize = 0;
    for (units) |u| {
        if (u > 127) return std.math.nan(f64);
        buf[n] = @intCast(u);
        n += 1;
    }
    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (trimmed.len == 0) return 0;
    if (std.mem.eql(u8, trimmed, "Infinity") or std.mem.eql(u8, trimmed, "+Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, trimmed, "-Infinity")) return -std.math.inf(f64);
    const compiler = @import("compiler.zig");
    return compiler.parseNumber(trimmed) catch std.math.nan(f64);
}

fn numberToString(n: f64, buf: []u8) []const u8 {
    if (std.math.isNan(n)) return "NaN";
    if (std.math.isInf(n)) return if (n > 0) "Infinity" else "-Infinity";
    if (n == 0) return "0";
    if (n == std.math.trunc(n) and @abs(n) < 1e21) {
        return std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(n))}) catch "0";
    }
    return std.fmt.bufPrint(buf, "{d}", .{n}) catch "0";
}

fn compareUtf16(a: []const u16, b: []const u16) i32 {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return if (a[i] < b[i]) -1 else 1;
    }
    if (a.len == b.len) return 0;
    return if (a.len < b.len) -1 else 1;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

/// Compile and run `source`; return the script's completion value.
fn eval(vm: *Vm, source: []const u8) !Value {
    const parser = @import("parser.zig");
    const compiler = @import("compiler.zig");
    var pr = try parser.parse(testing.allocator, source, .script);
    switch (pr) {
        .syntax_error => return error.ParseFailed,
        .ok => |*a| {
            defer a.deinit();
            var cr = try compiler.compile(testing.allocator, a.root, source);
            switch (cr) {
                .compile_error => return error.CompileFailed,
                .ok => |*program| {
                    defer program.deinit();
                    return vm.run(program);
                },
            }
        },
    }
}

fn evalNumber(source: []const u8) !f64 {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    const v = try eval(&vm, source);
    try testing.expect(v.isNumber());
    return v.asNumber();
}

test "arithmetic" {
    try testing.expectEqual(@as(f64, 7), try evalNumber("return 1 + 2 * 3;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return 10 % 3;"));
    try testing.expectEqual(@as(f64, 8), try evalNumber("return 2 ** 3;"));
    try testing.expectEqual(@as(f64, -5), try evalNumber("return -(2 + 3);"));
    try testing.expectEqual(@as(f64, 6), try evalNumber("return (0xF & 0x6) | 0;"));
}

test "variables and assignment" {
    try testing.expectEqual(@as(f64, 30), try evalNumber("var a = 10; var b = 20; return a + b;"));
    try testing.expectEqual(@as(f64, 15), try evalNumber("var a = 10; a += 5; return a;"));
    try testing.expectEqual(@as(f64, 3), try evalNumber("var a = 1; var b = a++; return a + b;"));
    try testing.expectEqual(@as(f64, 4), try evalNumber("var a = 1; var b = ++a; return a + b;"));
}

test "control flow" {
    try testing.expectEqual(@as(f64, 1), try evalNumber("if (true) return 1; return 2;"));
    try testing.expectEqual(@as(f64, 2), try evalNumber("if (false) return 1; else return 2;"));
    try testing.expectEqual(@as(f64, 55), try evalNumber(
        \\var sum = 0;
        \\for (var i = 1; i <= 10; i++) sum += i;
        \\return sum;
    ));
    try testing.expectEqual(@as(f64, 6), try evalNumber(
        \\var n = 3; var f = 1;
        \\while (n > 0) { f *= n; n--; }
        \\return f;
    ));
    try testing.expectEqual(@as(f64, 4), try evalNumber(
        \\var i = 0;
        \\for (;;) { i++; if (i === 4) break; }
        \\return i;
    ));
}

test "functions, recursion, closures" {
    try testing.expectEqual(@as(f64, 120), try evalNumber(
        \\function fact(n) { if (n <= 1) return 1; return n * fact(n - 1); }
        \\return fact(5);
    ));
    try testing.expectEqual(@as(f64, 55), try evalNumber(
        \\function fib(n) { if (n < 2) return n; return fib(n-1) + fib(n-2); }
        \\return fib(10);
    ));
    try testing.expectEqual(@as(f64, 8), try evalNumber(
        \\function adder(x) { return function(y) { return x + y; }; }
        \\var add5 = adder(5);
        \\return add5(3);
    ));
    try testing.expectEqual(@as(f64, 25), try evalNumber(
        \\var square = (x) => x * x;
        \\return square(5);
    ));
}

test "logical and conditional" {
    try testing.expectEqual(@as(f64, 2), try evalNumber("return 0 || 2;"));
    try testing.expectEqual(@as(f64, 3), try evalNumber("return 1 && 3;"));
    try testing.expectEqual(@as(f64, 5), try evalNumber("return null ?? 5;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return true ? 1 : 2;"));
}

test "strings and equality" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();

    const v = try eval(&vm, "return 'foo' + 'bar';");
    try testing.expect(v.isString());
    try testing.expectEqualSlices(u16, &[_]u16{ 'f', 'o', 'o', 'b', 'a', 'r' }, v.asString().units);

    try testing.expect(toBoolean(try eval(&vm, "return 1 == '1';")));
    try testing.expect(!toBoolean(try eval(&vm, "return 1 === '1';")));
    try testing.expect(toBoolean(try eval(&vm, "return null == undefined;")));
    try testing.expect(toBoolean(try eval(&vm, "return 'a' < 'b';")));
}

test "typeof" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    const v = try eval(&vm, "return typeof 42;");
    try testing.expectEqualSlices(u16, &[_]u16{ 'n', 'u', 'm', 'b', 'e', 'r' }, v.asString().units);
}

test "try/catch catches a throw" {
    try testing.expectEqual(@as(f64, 42), try evalNumber(
        \\var result = 0;
        \\try { throw 42; } catch (e) { result = e; }
        \\return result;
    ));
}

test "uncaught throw propagates" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    const r = eval(&vm, "throw 99;");
    try testing.expectError(error.JsThrow, r);
    try testing.expect(vm.pending_exception.?.isNumber());
    try testing.expectEqual(@as(f64, 99), vm.pending_exception.?.asNumber());
}

test "calling a non-function throws" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    const r = eval(&vm, "var x = 5; return x();");
    try testing.expectError(error.JsThrow, r);
}

test "runs under GC stress" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    vm.heap.stress = true;
    const v = try eval(&vm,
        \\function make(n) { return function() { return n; }; }
        \\var f = make(7);
        \\return f() + f();
    );
    try testing.expect(v.isNumber());
    try testing.expectEqual(@as(f64, 14), v.asNumber());
}
