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

pub const Error = gc.VmError;

const max_call_depth = 2000;

const Frame = struct {
    code: *const bc.CodeBlock,
    env: *gc.Environment,
    regs: []Value,
    this_value: Value,
};

pub const Vm = struct {
    gpa: std.mem.Allocator,
    heap: gc.Heap,
    frames: std.ArrayList(*Frame) = .empty,
    /// Values held alive across GC-triggering steps that aren't yet in a
    /// register or frame (e.g. a freshly-`new`ed `this` before the constructor
    /// frame exists). Push with `protect`, pop with `unprotect`.
    temp_roots: std.ArrayList(Value) = .empty,
    pending_exception: ?Value = null,
    depth: u32 = 0,
    // Realm intrinsics (created lazily by `bootstrap`).
    object_proto: ?*gc.Object = null,
    function_proto: ?*gc.Object = null,
    global_object: ?*gc.Object = null,
    // Error prototypes (for engine-thrown errors and `instanceof`).
    error_proto: ?*gc.Object = null,
    type_error_proto: ?*gc.Object = null,
    range_error_proto: ?*gc.Object = null,
    reference_error_proto: ?*gc.Object = null,
    syntax_error_proto: ?*gc.Object = null,
    array_proto: ?*gc.Object = null,
    string_proto: ?*gc.Object = null,
    number_proto: ?*gc.Object = null,
    regexp_proto: ?*gc.Object = null,

    pub fn init(gpa: std.mem.Allocator) Vm {
        return .{ .gpa = gpa, .heap = gc.Heap.init(gpa) };
    }
    pub fn deinit(self: *Vm) void {
        self.frames.deinit(self.gpa);
        self.temp_roots.deinit(self.gpa);
        self.heap.deinit();
    }

    /// GC root provider. Marks all reachable roots held by the VM.
    pub fn markRoots(self: *const Vm, tracer: *gc.Tracer) void {
        if (self.pending_exception) |e| e.mark(tracer);
        if (self.object_proto) |o| tracer.mark(&o.gc);
        if (self.function_proto) |o| tracer.mark(&o.gc);
        if (self.global_object) |o| tracer.mark(&o.gc);
        if (self.error_proto) |o| tracer.mark(&o.gc);
        if (self.type_error_proto) |o| tracer.mark(&o.gc);
        if (self.range_error_proto) |o| tracer.mark(&o.gc);
        if (self.reference_error_proto) |o| tracer.mark(&o.gc);
        if (self.syntax_error_proto) |o| tracer.mark(&o.gc);
        if (self.array_proto) |o| tracer.mark(&o.gc);
        if (self.string_proto) |o| tracer.mark(&o.gc);
        if (self.number_proto) |o| tracer.mark(&o.gc);
        if (self.regexp_proto) |o| tracer.mark(&o.gc);
        for (self.temp_roots.items) |v| v.mark(tracer);
        for (self.frames.items) |f| {
            tracer.mark(&f.env.gc);
            f.this_value.mark(tracer);
            for (f.regs) |v| v.mark(tracer);
        }
    }

    fn protect(self: *Vm, v: Value) Error!void {
        try self.temp_roots.append(self.gpa, v);
    }
    fn unprotect(self: *Vm) void {
        _ = self.temp_roots.pop();
    }

    fn maybeStress(self: *Vm) void {
        if (self.heap.stress) _ = self.heap.collect(self);
    }

    /// Create the base intrinsics if they don't exist yet.
    fn bootstrap(self: *Vm) Error!void {
        if (self.object_proto != null) return;
        const obj_proto = try self.heap.create(gc.Object); // [[Prototype]] = null
        self.object_proto = obj_proto;
        const fn_proto = try self.heap.create(gc.Object);
        fn_proto.prototype = obj_proto;
        self.function_proto = fn_proto;
        const global = try self.heap.create(gc.Object);
        global.prototype = obj_proto;
        self.global_object = global;

        // A few global value properties. The `Object`/`String`/error
        // constructors are not installed yet; free references to them only
        // fault if actually evaluated at run time.
        try self.defineData(global, "globalThis", Value.fromObject(global), true, false, true);
        try self.defineData(global, "NaN", Value.fromNumber(std.math.nan(f64)), false, false, false);
        try self.defineData(global, "Infinity", Value.fromNumber(std.math.inf(f64)), false, false, false);
        try self.defineData(global, "undefined", Value.undefined_value, false, false, false);

        // Install the standard library with GC stress off, so partially-built
        // intrinsics can't be collected mid-setup.
        const saved_stress = self.heap.stress;
        self.heap.stress = false;
        defer self.heap.stress = saved_stress;
        try self.installBuiltins();
    }

    fn makeNative(self: *Vm, name: []const u8, func: gc.NativeFn, length: u32) Error!*gc.Object {
        const clo = try self.heap.create(gc.Closure);
        clo.native = func;
        clo.env = null;
        const obj = try self.heap.create(gc.Object);
        obj.callable = clo;
        obj.prototype = self.function_proto;
        try self.defineData(obj, "length", Value.fromNumber(@floatFromInt(length)), false, false, true);
        try self.defineData(obj, "name", try self.makeString(name), false, false, true);
        return obj;
    }

    /// Define a method (native function) on `obj`, writable + configurable,
    /// non-enumerable (as built-in methods are).
    fn defineMethod(self: *Vm, obj: *gc.Object, name: []const u8, func: gc.NativeFn, length: u32) Error!void {
        try self.defineData(obj, name, Value.fromObject(try self.makeNative(name, func, length)), true, false, true);
    }

    /// Create a RegExp object. Phase 4 stub: the pattern is *not* compiled — the
    /// object carries `source`/`flags`/`lastIndex` and the derived flag booleans,
    /// so construction, `instanceof RegExp`, and `toString` work, but `test`/
    /// `exec` throw until a real matcher lands.
    fn makeRegExp(self: *Vm, source: []const u8, flags: []const u8) Error!*gc.Object {
        const obj = try self.newObject(self.regexp_proto);
        try self.protect(Value.fromObject(obj));
        defer self.unprotect();
        const src = if (source.len == 0) "(?:)" else source;
        try self.defineData(obj, "source", try self.makeString(src), false, false, false);
        try self.defineData(obj, "flags", try self.makeString(flags), false, false, false);
        try self.defineData(obj, "lastIndex", Value.fromNumber(0), true, false, false);
        try self.defineData(obj, "global", Value.fromBool(hasFlag(flags, 'g')), false, false, false);
        try self.defineData(obj, "ignoreCase", Value.fromBool(hasFlag(flags, 'i')), false, false, false);
        try self.defineData(obj, "multiline", Value.fromBool(hasFlag(flags, 'm')), false, false, false);
        try self.defineData(obj, "sticky", Value.fromBool(hasFlag(flags, 'y')), false, false, false);
        try self.defineData(obj, "dotAll", Value.fromBool(hasFlag(flags, 's')), false, false, false);
        return obj;
    }

    /// Create an Error object directly (for engine-thrown exceptions).
    fn makeError(self: *Vm, proto: ?*gc.Object, msg: []const u8) Error!*gc.Object {
        const obj = try self.newObject(proto);
        try self.protect(Value.fromObject(obj));
        defer self.unprotect();
        try self.defineData(obj, "message", try self.makeString(msg), true, false, true);
        return obj;
    }

    fn installBuiltins(self: *Vm) Error!void {
        const global = self.global_object.?;

        // ---- Object.prototype methods + Object constructor ----
        try self.defineMethod(self.object_proto.?, "hasOwnProperty", nativeHasOwnProperty, 1);
        try self.defineMethod(self.object_proto.?, "toString", nativeObjectToString, 0);
        try self.defineMethod(self.object_proto.?, "valueOf", nativeObjectValueOf, 0);
        try self.defineMethod(self.object_proto.?, "isPrototypeOf", nativeIsPrototypeOf, 1);

        const object_ctor = try self.makeNative("Object", nativeObject, 1);
        try self.defineData(object_ctor, "prototype", Value.fromObject(self.object_proto.?), false, false, false);
        try self.defineData(self.object_proto.?, "constructor", Value.fromObject(object_ctor), true, false, true);
        try self.defineMethod(object_ctor, "keys", nativeObjectKeys, 1);
        try self.defineMethod(object_ctor, "values", nativeObjectValues, 1);
        try self.defineMethod(object_ctor, "entries", nativeObjectEntries, 1);
        try self.defineMethod(object_ctor, "getPrototypeOf", nativeObjectGetPrototypeOf, 1);
        try self.defineMethod(object_ctor, "create", nativeObjectCreate, 2);
        try self.defineMethod(object_ctor, "defineProperty", nativeObjectDefineProperty, 3);
        try self.defineMethod(object_ctor, "getOwnPropertyDescriptor", nativeObjectGetOwnPropertyDescriptor, 2);
        try self.defineData(global, "Object", Value.fromObject(object_ctor), true, false, true);

        // ---- Error hierarchy ----
        const error_proto = try self.newObject(self.object_proto);
        self.error_proto = error_proto;
        try self.defineData(error_proto, "name", try self.makeString("Error"), true, false, true);
        try self.defineData(error_proto, "message", try self.makeString(""), true, false, true);
        try self.defineMethod(error_proto, "toString", nativeErrorToString, 0);
        const error_ctor = try self.makeNative("Error", nativeError, 1);
        try self.defineData(error_ctor, "prototype", Value.fromObject(error_proto), false, false, false);
        try self.defineData(error_proto, "constructor", Value.fromObject(error_ctor), true, false, true);
        try self.defineData(global, "Error", Value.fromObject(error_ctor), true, false, true);

        self.type_error_proto = try self.installErrorSubtype("TypeError");
        self.range_error_proto = try self.installErrorSubtype("RangeError");
        self.reference_error_proto = try self.installErrorSubtype("ReferenceError");
        self.syntax_error_proto = try self.installErrorSubtype("SyntaxError");
        _ = try self.installErrorSubtype("EvalError");
        _ = try self.installErrorSubtype("URIError");

        // ---- Array ----
        const array_proto = try self.heap.create(gc.Object);
        array_proto.prototype = self.object_proto;
        array_proto.is_array = true; // Array.prototype is itself an (empty) array
        self.array_proto = array_proto;
        try self.defineMethod(array_proto, "push", nativeArrayPush, 1);
        try self.defineMethod(array_proto, "pop", nativeArrayPop, 0);
        try self.defineMethod(array_proto, "indexOf", nativeArrayIndexOf, 1);
        try self.defineMethod(array_proto, "includes", nativeArrayIncludes, 1);
        try self.defineMethod(array_proto, "join", nativeArrayJoin, 1);
        try self.defineMethod(array_proto, "slice", nativeArraySlice, 2);
        try self.defineMethod(array_proto, "concat", nativeArrayConcat, 1);
        try self.defineMethod(array_proto, "forEach", nativeArrayForEach, 1);
        try self.defineMethod(array_proto, "map", nativeArrayMap, 1);
        try self.defineMethod(array_proto, "filter", nativeArrayFilter, 1);
        try self.defineMethod(array_proto, "toString", nativeArrayToString, 0);
        const array_ctor = try self.makeNative("Array", nativeArray, 1);
        try self.defineData(array_ctor, "prototype", Value.fromObject(array_proto), false, false, false);
        try self.defineData(array_proto, "constructor", Value.fromObject(array_ctor), true, false, true);
        try self.defineMethod(array_ctor, "isArray", nativeArrayIsArray, 1);
        try self.defineData(global, "Array", Value.fromObject(array_ctor), true, false, true);

        // ---- String (+ prototype methods for primitive strings) ----
        const string_proto = try self.newObject(self.object_proto);
        self.string_proto = string_proto;
        try self.defineMethod(string_proto, "charAt", nativeStringCharAt, 1);
        try self.defineMethod(string_proto, "charCodeAt", nativeStringCharCodeAt, 1);
        try self.defineMethod(string_proto, "indexOf", nativeStringIndexOf, 1);
        try self.defineMethod(string_proto, "includes", nativeStringIncludes, 1);
        try self.defineMethod(string_proto, "startsWith", nativeStringStartsWith, 1);
        try self.defineMethod(string_proto, "endsWith", nativeStringEndsWith, 1);
        try self.defineMethod(string_proto, "slice", nativeStringSlice, 2);
        try self.defineMethod(string_proto, "substring", nativeStringSubstring, 2);
        try self.defineMethod(string_proto, "toUpperCase", nativeStringToUpperCase, 0);
        try self.defineMethod(string_proto, "toLowerCase", nativeStringToLowerCase, 0);
        try self.defineMethod(string_proto, "trim", nativeStringTrim, 0);
        try self.defineMethod(string_proto, "repeat", nativeStringRepeat, 1);
        try self.defineMethod(string_proto, "concat", nativeStringConcat, 1);
        try self.defineMethod(string_proto, "split", nativeStringSplit, 2);
        try self.defineMethod(string_proto, "toString", nativeStringToString, 0);
        try self.defineMethod(string_proto, "valueOf", nativeStringToString, 0);
        const string_ctor = try self.makeNative("String", nativeString, 1);
        try self.defineData(string_ctor, "prototype", Value.fromObject(string_proto), false, false, false);
        try self.defineData(string_proto, "constructor", Value.fromObject(string_ctor), true, false, true);
        try self.defineMethod(string_ctor, "fromCharCode", nativeStringFromCharCode, 1);
        try self.defineData(global, "String", Value.fromObject(string_ctor), true, false, true);

        // ---- Number (+ prototype) / Boolean ----
        const number_proto = try self.newObject(self.object_proto);
        self.number_proto = number_proto;
        try self.defineMethod(number_proto, "toFixed", nativeNumberToFixed, 1);
        try self.defineMethod(number_proto, "toString", nativeNumberToString, 1);
        try self.defineMethod(number_proto, "valueOf", nativeNumberValueOf, 0);
        const number_ctor = try self.makeNative("Number", nativeNumber, 1);
        try self.defineData(number_ctor, "prototype", Value.fromObject(number_proto), false, false, false);
        try self.defineData(number_proto, "constructor", Value.fromObject(number_ctor), true, false, true);
        try self.defineData(number_ctor, "MAX_SAFE_INTEGER", Value.fromNumber(9007199254740991), false, false, false);
        try self.defineData(number_ctor, "MIN_SAFE_INTEGER", Value.fromNumber(-9007199254740991), false, false, false);
        try self.defineData(number_ctor, "POSITIVE_INFINITY", Value.fromNumber(std.math.inf(f64)), false, false, false);
        try self.defineData(number_ctor, "NEGATIVE_INFINITY", Value.fromNumber(-std.math.inf(f64)), false, false, false);
        try self.defineData(number_ctor, "NaN", Value.fromNumber(std.math.nan(f64)), false, false, false);
        try self.defineData(number_ctor, "MAX_VALUE", Value.fromNumber(1.7976931348623157e308), false, false, false);
        try self.defineData(number_ctor, "MIN_VALUE", Value.fromNumber(5e-324), false, false, false);
        try self.defineData(number_ctor, "EPSILON", Value.fromNumber(2.220446049250313e-16), false, false, false);
        try self.defineMethod(number_ctor, "isInteger", nativeNumberIsInteger, 1);
        try self.defineMethod(number_ctor, "isFinite", nativeNumberIsFinite, 1);
        try self.defineMethod(number_ctor, "isNaN", nativeNumberIsNaN, 1);
        try self.defineData(global, "Number", Value.fromObject(number_ctor), true, false, true);

        try self.defineData(global, "Boolean", Value.fromObject(try self.makeNative("Boolean", nativeBoolean, 1)), true, false, true);

        // ---- Math ----
        const math = try self.newObject(self.object_proto);
        try self.defineData(math, "PI", Value.fromNumber(std.math.pi), false, false, false);
        try self.defineData(math, "E", Value.fromNumber(std.math.e), false, false, false);
        try self.defineMethod(math, "abs", nativeMathAbs, 1);
        try self.defineMethod(math, "floor", nativeMathFloor, 1);
        try self.defineMethod(math, "ceil", nativeMathCeil, 1);
        try self.defineMethod(math, "round", nativeMathRound, 1);
        try self.defineMethod(math, "trunc", nativeMathTrunc, 1);
        try self.defineMethod(math, "sqrt", nativeMathSqrt, 1);
        try self.defineMethod(math, "sign", nativeMathSign, 1);
        try self.defineMethod(math, "max", nativeMathMax, 2);
        try self.defineMethod(math, "min", nativeMathMin, 2);
        try self.defineMethod(math, "pow", nativeMathPow, 2);
        try self.defineMethod(math, "sin", mathUnaryFn(opSin), 1);
        try self.defineMethod(math, "cos", mathUnaryFn(opCos), 1);
        try self.defineMethod(math, "tan", mathUnaryFn(opTan), 1);
        try self.defineMethod(math, "asin", mathUnaryFn(opAsin), 1);
        try self.defineMethod(math, "acos", mathUnaryFn(opAcos), 1);
        try self.defineMethod(math, "atan", mathUnaryFn(opAtan), 1);
        try self.defineMethod(math, "sinh", mathUnaryFn(opSinh), 1);
        try self.defineMethod(math, "cosh", mathUnaryFn(opCosh), 1);
        try self.defineMethod(math, "tanh", mathUnaryFn(opTanh), 1);
        try self.defineMethod(math, "asinh", mathUnaryFn(opAsinh), 1);
        try self.defineMethod(math, "acosh", mathUnaryFn(opAcosh), 1);
        try self.defineMethod(math, "atanh", mathUnaryFn(opAtanh), 1);
        try self.defineMethod(math, "exp", mathUnaryFn(opExp), 1);
        try self.defineMethod(math, "expm1", mathUnaryFn(opExpm1), 1);
        try self.defineMethod(math, "log", mathUnaryFn(opLog), 1);
        try self.defineMethod(math, "log2", mathUnaryFn(opLog2), 1);
        try self.defineMethod(math, "log10", mathUnaryFn(opLog10), 1);
        try self.defineMethod(math, "log1p", mathUnaryFn(opLog1p), 1);
        try self.defineMethod(math, "cbrt", mathUnaryFn(opCbrt), 1);
        try self.defineMethod(math, "fround", mathUnaryFn(opFround), 1);
        try self.defineMethod(math, "atan2", nativeMathAtan2, 2);
        try self.defineMethod(math, "hypot", nativeMathHypot, 2);
        try self.defineMethod(math, "clz32", nativeMathClz32, 1);
        try self.defineMethod(math, "imul", nativeMathImul, 2);
        try self.defineMethod(math, "random", nativeMathRandom, 0);
        try self.defineData(math, "LN2", Value.fromNumber(0.6931471805599453), false, false, false);
        try self.defineData(math, "LN10", Value.fromNumber(2.302585092994046), false, false, false);
        try self.defineData(math, "LOG2E", Value.fromNumber(1.4426950408889634), false, false, false);
        try self.defineData(math, "LOG10E", Value.fromNumber(0.4342944819032518), false, false, false);
        try self.defineData(math, "SQRT2", Value.fromNumber(1.4142135623730951), false, false, false);
        try self.defineData(math, "SQRT1_2", Value.fromNumber(0.7071067811865476), false, false, false);
        try self.defineData(global, "Math", Value.fromObject(math), true, false, true);

        // ---- RegExp (Phase 4 stub: construction only; matching throws) ----
        const regexp_proto = try self.newObject(self.object_proto);
        self.regexp_proto = regexp_proto;
        try self.defineMethod(regexp_proto, "test", nativeRegExpTest, 1);
        try self.defineMethod(regexp_proto, "exec", nativeRegExpExec, 1);
        try self.defineMethod(regexp_proto, "toString", nativeRegExpToString, 0);
        const regexp_ctor = try self.makeNative("RegExp", nativeRegExp, 2);
        try self.defineData(regexp_ctor, "prototype", Value.fromObject(regexp_proto), false, false, false);
        try self.defineData(regexp_proto, "constructor", Value.fromObject(regexp_ctor), true, false, true);
        try self.defineData(global, "RegExp", Value.fromObject(regexp_ctor), true, false, true);

        // ---- global functions ----
        try self.defineMethod(global, "isNaN", nativeIsNaN, 1);
        try self.defineMethod(global, "isFinite", nativeIsFinite, 1);
    }

    fn installErrorSubtype(self: *Vm, name: []const u8) Error!*gc.Object {
        const proto = try self.newObject(self.error_proto);
        try self.defineData(proto, "name", try self.makeString(name), true, false, true);
        try self.defineData(proto, "message", try self.makeString(""), true, false, true);
        const ctor = try self.makeNative(name, nativeError, 1);
        try self.defineData(ctor, "prototype", Value.fromObject(proto), false, false, false);
        try self.defineData(proto, "constructor", Value.fromObject(ctor), true, false, true);
        try self.defineData(self.global_object.?, name, Value.fromObject(ctor), true, false, true);
        return proto;
    }

    // ---- entry -------------------------------------------------------------

    /// Run a compiled program's top-level script. Returns its completion value
    /// (the script's `return`, else undefined). On an uncaught throw returns
    /// `error.JsThrow` with `pending_exception` set.
    pub fn run(self: *Vm, program: *const bc.Program) Error!Value {
        try self.bootstrap();
        const root = program.root;
        const env = try self.createEnv(null, root.num_env_slots);
        return self.execute(root, env, Value.fromObject(self.global_object.?));
    }

    /// If a JS exception is pending and is an Error-like object, return its
    /// constructor's `name` as newly-allocated UTF-8 (caller frees), else null.
    /// Used by the Test262 runner to score runtime-phase negative tests.
    pub fn pendingErrorName(self: *Vm, gpa: std.mem.Allocator) ?[]u8 {
        const exc = self.pending_exception orelse return null;
        if (!exc.isObject()) return null;
        const ctor = self.getProperty(exc, "constructor") catch return null;
        if (!ctor.isObject()) return null;
        const name_v = self.getProperty(ctor, "name") catch return null;
        if (!name_v.isString()) return null;
        return utf16ToUtf8Alloc(gpa, name_v.asString().units) catch return null;
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

    fn execute(self: *Vm, code: *const bc.CodeBlock, env: *gc.Environment, this_value: Value) Error!Value {
        const regs = try self.gpa.alloc(Value, code.num_registers);
        defer self.gpa.free(regs);
        @memset(regs, Value.undefined_value);

        var frame = Frame{ .code = code, .env = env, .regs = regs, .this_value = this_value };
        try self.frames.append(self.gpa, &frame);
        defer _ = self.frames.pop();

        var pc: u32 = 0;
        while (true) {
            const inst = code.code[pc];
            const step = self.exec(code, env, regs, frame.this_value, inst, &pc) catch |e| {
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
        this_value: Value,
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

            .get_global => regs[inst.a] = try self.getGlobal(code.constants[inst.b].string, false),
            .get_global_typeof => regs[inst.a] = try self.getGlobal(code.constants[inst.b].string, true),
            .set_global => try self.setProperty(Value.fromObject(self.global_object.?), code.constants[inst.a].string, regs[inst.b]),

            .add => regs[inst.a] = try self.opAdd(regs[inst.b], regs[inst.c]),
            .sub => regs[inst.a] = Value.fromNumber(try self.toNumber(regs[inst.b]) - try self.toNumber(regs[inst.c])),
            .mul => regs[inst.a] = Value.fromNumber(try self.toNumber(regs[inst.b]) * try self.toNumber(regs[inst.c])),
            .div => regs[inst.a] = Value.fromNumber(try self.toNumber(regs[inst.b]) / try self.toNumber(regs[inst.c])),
            .mod => regs[inst.a] = Value.fromNumber(jsMod(try self.toNumber(regs[inst.b]), try self.toNumber(regs[inst.c]))),
            .exp => regs[inst.a] = Value.fromNumber(jsPow(try self.toNumber(regs[inst.b]), try self.toNumber(regs[inst.c]))),
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
            .instance_of => regs[inst.a] = Value.fromBool(try self.instanceOf(regs[inst.b], regs[inst.c])),
            .in_op => regs[inst.a] = Value.fromBool(try self.inOperator(regs[inst.b], regs[inst.c])),

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

            .new_object => regs[inst.a] = try self.newObjectValue(),
            .new_array => regs[inst.a] = Value.fromObject(try self.newArray(inst.b)),
            .new_regex => regs[inst.a] = Value.fromObject(try self.makeRegExp(code.constants[inst.b].string, code.constants[inst.c].string)),
            .get_prop => regs[inst.a] = try self.getProperty(regs[inst.b], code.constants[inst.c].string),
            .set_prop => try self.setProperty(regs[inst.a], code.constants[inst.b].string, regs[inst.c]),
            .get_elem => {
                const key = try self.toPropertyKey(regs[inst.c]);
                defer self.gpa.free(key);
                regs[inst.a] = try self.getProperty(regs[inst.b], key);
            },
            .set_elem => {
                const key = try self.toPropertyKey(regs[inst.b]);
                defer self.gpa.free(key);
                try self.setProperty(regs[inst.a], key, regs[inst.c]);
            },
            .load_this => regs[inst.a] = this_value,

            .new_closure => regs[inst.a] = try self.makeClosure(code.children[inst.b], env),
            .call => {
                const receiver = regs[inst.b];
                const callee = regs[inst.b + 1];
                const args = regs[inst.b + 2 .. inst.b + 2 + inst.c];
                regs[inst.a] = try self.callValue(callee, receiver, args);
            },
            .construct => {
                const callee = regs[inst.b];
                const args = regs[inst.b + 1 .. inst.b + 1 + inst.c];
                regs[inst.a] = try self.constructValue(callee, args);
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
        const fn_obj = try self.heap.create(gc.Object);
        fn_obj.callable = clo;
        fn_obj.prototype = self.function_proto;
        // Every ordinary function gets a `prototype` object with a back-
        // reference, so `new f()` has a prototype to inherit from.
        const proto = try self.heap.create(gc.Object);
        proto.prototype = self.object_proto;
        try self.defineData(fn_obj, "prototype", Value.fromObject(proto), true, false, false);
        try self.defineData(proto, "constructor", Value.fromObject(fn_obj), true, false, true);
        return Value.fromObject(fn_obj);
    }

    fn callValue(self: *Vm, callee: Value, this_value: Value, args: []const Value) Error!Value {
        if (!callee.isObject() or callee.asObject().callable == null) {
            return self.throwTypeError("value is not a function");
        }
        if (self.depth >= max_call_depth) return self.throwRangeError("maximum call stack size exceeded");
        self.depth += 1;
        defer self.depth -= 1;

        const clo = callee.asObject().callable.?;
        if (clo.native) |native| {
            return native(@ptrCast(self), this_value, args);
        }
        const code: *const bc.CodeBlock = @ptrCast(@alignCast(clo.code));
        const env = try self.createEnv(clo.env, code.num_env_slots);
        var i: u32 = 0;
        while (i < code.num_params) : (i += 1) {
            env.slots[i] = if (i < args.len) args[i] else Value.undefined_value;
        }
        return self.execute(code, env, this_value);
    }

    /// The `new` operator: create an ordinary object inheriting the
    /// constructor's `prototype`, run the constructor with it as `this`, and
    /// return the constructor's object result or that object.
    fn constructValue(self: *Vm, callee: Value, args: []const Value) Error!Value {
        if (!callee.isObject() or callee.asObject().callable == null) {
            return self.throwTypeError("value is not a constructor");
        }
        const proto_val = try self.getProperty(callee, "prototype");
        const this_obj = try self.newObject(if (proto_val.isObject()) proto_val.asObject() else self.object_proto);
        // Root `this` across the constructor call (its frame doesn't exist yet).
        try self.protect(Value.fromObject(this_obj));
        defer self.unprotect();
        const result = try self.callValue(callee, Value.fromObject(this_obj), args);
        return if (result.isObject()) result else Value.fromObject(this_obj);
    }

    // ---- object model ------------------------------------------------------

    fn newObject(self: *Vm, prototype: ?*gc.Object) Error!*gc.Object {
        self.maybeStress();
        const o = try self.heap.create(gc.Object);
        o.prototype = prototype;
        return o;
    }
    fn newObjectValue(self: *Vm) Error!Value {
        return Value.fromObject(try self.newObject(self.object_proto));
    }

    fn newArray(self: *Vm, len: u32) Error!*gc.Object {
        self.maybeStress();
        const o = try self.heap.create(gc.Object);
        o.prototype = self.array_proto;
        o.is_array = true;
        if (len > 0) {
            try o.elements.resize(self.gpa, len);
            @memset(o.elements.items, Value.undefined_value);
        }
        return o;
    }

    fn setArrayElement(self: *Vm, arr: *gc.Object, i: u32, value: Value) Error!void {
        if (i >= arr.elements.items.len) {
            const old = arr.elements.items.len;
            try arr.elements.resize(self.gpa, i + 1);
            for (arr.elements.items[old..]) |*slot| slot.* = Value.undefined_value;
        }
        arr.elements.items[i] = value;
    }

    fn setArrayLength(self: *Vm, arr: *gc.Object, n: u32) Error!void {
        const old = arr.elements.items.len;
        if (n < old) {
            arr.elements.shrinkRetainingCapacity(n);
        } else if (n > old) {
            try arr.elements.resize(self.gpa, n);
            for (arr.elements.items[old..]) |*slot| slot.* = Value.undefined_value;
        }
    }

    /// Define an own data property with explicit attributes (key is duplicated).
    fn defineData(self: *Vm, obj: *gc.Object, key: []const u8, value: Value, w: bool, e: bool, c: bool) Error!void {
        const gop = try obj.properties.getOrPut(self.gpa, key);
        if (!gop.found_existing) gop.key_ptr.* = try self.gpa.dupe(u8, key);
        gop.value_ptr.* = .{ .value = value, .writable = w, .enumerable = e, .configurable = c, .is_accessor = false };
    }

    /// [[Get]] on a value: walk the prototype chain; invoke getters.
    fn getProperty(self: *Vm, base: Value, key: []const u8) Error!Value {
        if (!base.isObject()) {
            if (base.isNullish()) return self.throwTypeError("cannot read property of null or undefined");
            // String primitives: length, index access, and String.prototype.
            if (base.isString()) {
                const units = base.asString().units;
                if (std.mem.eql(u8, key, "length")) return Value.fromNumber(@floatFromInt(units.len));
                if (arrayIndex(key)) |i| {
                    if (i < units.len) return self.makeStringFromUtf16(units[i .. i + 1]);
                    return Value.undefined_value;
                }
                return self.getFromProto(self.string_proto, base, key);
            }
            // Number/boolean primitives: consult their prototype.
            if (base.isNumber()) return self.getFromProto(self.number_proto, base, key);
            return Value.undefined_value;
        }
        // Array exotic own access (length + dense elements).
        if (base.asObject().is_array) {
            const arr = base.asObject();
            if (std.mem.eql(u8, key, "length")) return Value.fromNumber(@floatFromInt(arr.elements.items.len));
            if (arrayIndex(key)) |i| {
                if (i < arr.elements.items.len) return arr.elements.items[i];
            }
        }
        var obj: ?*gc.Object = base.asObject();
        while (obj) |o| {
            if (o.properties.getPtr(key)) |desc| {
                if (desc.is_accessor) {
                    const getter = desc.get orelse return Value.undefined_value;
                    return self.callValue(getter, base, &.{});
                }
                return desc.value;
            }
            obj = o.prototype;
        }
        return Value.undefined_value;
    }

    /// [[Set]] on a value: honor setters and writability; create own data
    /// property on the receiver otherwise.
    fn setProperty(self: *Vm, base: Value, key: []const u8, value: Value) Error!void {
        if (!base.isObject()) {
            if (base.isNullish()) return self.throwTypeError("cannot set property of null or undefined");
            return; // silent no-op on primitives (sloppy)
        }
        // Array exotic own writes (length + dense elements).
        if (base.asObject().is_array) {
            const arr = base.asObject();
            if (std.mem.eql(u8, key, "length")) {
                const n = try self.toNumber(value);
                const len: u32 = if (std.math.isNan(n) or n < 0) 0 else if (n > 4294967295) 4294967295 else @intFromFloat(n);
                return self.setArrayLength(arr, len);
            }
            if (arrayIndex(key)) |i| return self.setArrayElement(arr, i, value);
        }
        const receiver = base.asObject();
        // Search prototype chain for an accessor or a non-writable data prop.
        var obj: ?*gc.Object = receiver;
        while (obj) |o| {
            if (o.properties.getPtr(key)) |desc| {
                if (desc.is_accessor) {
                    const setter = desc.set orelse return; // no setter -> ignore (sloppy)
                    _ = try self.callValue(setter, base, &.{value});
                    return;
                }
                if (o == receiver) {
                    if (!desc.writable) return; // sloppy: ignore
                    desc.value = value;
                    return;
                }
                if (!desc.writable) return; // inherited non-writable shadows
                break;
            }
            obj = o.prototype;
        }
        try self.defineData(receiver, key, value, true, true, true);
    }

    /// Look up `key` on a prototype chain, invoking getters with `receiver` as
    /// `this`. Used for primitive (string/number) property access.
    fn getFromProto(self: *Vm, proto: ?*gc.Object, receiver: Value, key: []const u8) Error!Value {
        var obj = proto;
        while (obj) |o| {
            if (o.properties.getPtr(key)) |desc| {
                if (desc.is_accessor) {
                    const getter = desc.get orelse return Value.undefined_value;
                    return self.callValue(getter, receiver, &.{});
                }
                return desc.value;
            }
            obj = o.prototype;
        }
        return Value.undefined_value;
    }

    fn hasProperty(self: *Vm, obj: *gc.Object, key: []const u8) bool {
        _ = self;
        var o: ?*gc.Object = obj;
        while (o) |cur| {
            if (cur.properties.contains(key)) return true;
            o = cur.prototype;
        }
        return false;
    }

    fn getGlobal(self: *Vm, name: []const u8, for_typeof: bool) Error!Value {
        const global = self.global_object.?;
        if (self.hasProperty(global, name)) {
            return self.getProperty(Value.fromObject(global), name);
        }
        if (for_typeof) return Value.undefined_value;
        return self.throwReferenceError(name);
    }

    fn instanceOf(self: *Vm, lhs: Value, rhs: Value) Error!bool {
        if (!rhs.isObject() or rhs.asObject().callable == null) {
            return self.throwTypeError("right-hand side of 'instanceof' is not callable");
        }
        const proto_val = try self.getProperty(rhs, "prototype");
        if (!proto_val.isObject()) return self.throwTypeError("'prototype' is not an object");
        const target = proto_val.asObject();
        if (!lhs.isObject()) return false;
        var o: ?*gc.Object = lhs.asObject().prototype;
        while (o) |cur| {
            if (cur == target) return true;
            o = cur.prototype;
        }
        return false;
    }

    fn inOperator(self: *Vm, key: Value, obj: Value) Error!bool {
        if (!obj.isObject()) return self.throwTypeError("cannot use 'in' on a non-object");
        const k = try self.toPropertyKey(key);
        defer self.gpa.free(k);
        return self.hasProperty(obj.asObject(), k);
    }

    fn toPropertyKey(self: *Vm, v: Value) Error![]u8 {
        if (v.isString()) {
            return utf16ToUtf8Alloc(self.gpa, v.asString().units);
        }
        var buf: [64]u8 = undefined;
        const s = self.primitiveToUtf8(v, &buf) catch "?";
        return self.gpa.dupe(u8, s);
    }

    /// ToPrimitive with a number hint: try valueOf then toString (spec 7.1.1
    /// OrdinaryToPrimitive, number-hint order).
    fn toPrimitive(self: *Vm, v: Value) Error!Value {
        if (!v.isObject()) return v;
        inline for (.{ "valueOf", "toString" }) |method_name| {
            const method = try self.getProperty(v, method_name);
            if (method.isObject() and method.asObject().callable != null) {
                const result = try self.callValue(method, v, &.{});
                if (!result.isObject()) return result;
            }
        }
        return self.throwTypeError("cannot convert object to primitive value");
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

    fn makeStringFromUtf16(self: *Vm, units: []const u16) Error!Value {
        self.maybeStress();
        const s = try self.heap.create(gc.String);
        s.units = try self.gpa.dupe(u16, units);
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
            .object => try self.toNumber(try self.toPrimitive(v)),
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
        const lp = try self.toPrimitive(l);
        try self.protect(lp);
        defer self.unprotect();
        const rp = try self.toPrimitive(r);
        try self.protect(rp);
        defer self.unprotect();

        if (lp.isString() or rp.isString()) {
            const lsv = try self.toStringVal(lp);
            try self.protect(lsv);
            defer self.unprotect();
            const rsv = try self.toStringVal(rp);
            try self.protect(rsv);
            defer self.unprotect();
            return self.concat(lsv.asString().units, rsv.asString().units);
        }
        return Value.fromNumber((try self.toNumber(lp)) + (try self.toNumber(rp)));
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

    /// ToString as a string `Value` (so callers can root it). Objects go
    /// through ToPrimitive(string) first.
    fn toStringVal(self: *Vm, v: Value) Error!Value {
        const p = if (v.isObject()) try self.toPrimitive(v) else v;
        if (p.isString()) return p;
        var buf: [64]u8 = undefined;
        const utf8 = self.primitiveToUtf8(p, &buf) catch "?";
        return self.makeString(utf8);
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

    /// Throw a real Error object with the given prototype and message.
    fn throwError(self: *Vm, proto: ?*gc.Object, msg: []const u8) Error {
        const obj = self.makeError(proto, msg) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.JsThrow,
        };
        self.pending_exception = Value.fromObject(obj);
        return error.JsThrow;
    }
    fn throwTypeError(self: *Vm, msg: []const u8) Error {
        return self.throwError(self.type_error_proto, msg);
    }
    fn throwRangeError(self: *Vm, msg: []const u8) Error {
        return self.throwError(self.range_error_proto, msg);
    }
    fn throwReferenceError(self: *Vm, msg: []const u8) Error {
        return self.throwError(self.reference_error_proto, msg);
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

/// JS `Number::exponentiate` — differs from C `pow` on a few edge cases
/// (`x**±0` is 1 even for NaN x; `(±1)**±Infinity` is NaN).
fn jsPow(base: f64, exp: f64) f64 {
    if (std.math.isNan(exp)) return std.math.nan(f64);
    if (exp == 0) return 1;
    if (std.math.isNan(base)) return std.math.nan(f64);
    if (std.math.isInf(exp)) {
        const ab = @abs(base);
        if (ab == 1) return std.math.nan(f64);
        if (exp > 0) return if (ab > 1) std.math.inf(f64) else 0;
        return if (ab > 1) 0 else std.math.inf(f64);
    }
    return std.math.pow(f64, base, exp);
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
    // Integer fast path only when the value fits safely in i64.
    if (n == std.math.trunc(n) and @abs(n) < 9.0e18) {
        return std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(n))}) catch "0";
    }
    return std.fmt.bufPrint(buf, "{d}", .{n}) catch "0";
}

// ---- native built-in functions ---------------------------------------------

fn castVm(ctx: *anyopaque) *Vm {
    return @ptrCast(@alignCast(ctx));
}
fn argAt(args: []const Value, i: usize) Value {
    return if (i < args.len) args[i] else Value.undefined_value;
}

fn nativeError(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
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

fn nativeErrorToString(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
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

fn nativeObject(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    _ = this;
    const v = argAt(args, 0);
    if (v.isObject()) return v;
    if (v.isNullish()) return Value.fromObject(try vm.newObject(vm.object_proto));
    // ToObject for primitives (wrapper objects) is not implemented; return a
    // fresh object so Object(x) at least yields an object.
    return Value.fromObject(try vm.newObject(vm.object_proto));
}

fn nativeObjectToString(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const vm = castVm(ctx);
    return switch (this) {
        .undefined => vm.makeString("[object Undefined]"),
        .null => vm.makeString("[object Null]"),
        else => vm.makeString("[object Object]"),
    };
}

fn nativeObjectValueOf(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    _ = args;
    return this;
}

fn nativeHasOwnProperty(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    if (!this.isObject()) return Value.fromBool(false);
    const key = try vm.toPropertyKey(argAt(args, 0));
    defer vm.gpa.free(key);
    return Value.fromBool(this.asObject().properties.contains(key));
}

fn nativeIsPrototypeOf(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    const v = argAt(args, 0);
    if (!this.isObject() or !v.isObject()) return Value.fromBool(false);
    const target = this.asObject();
    var o: ?*gc.Object = v.asObject().prototype;
    while (o) |cur| {
        if (cur == target) return Value.fromBool(true);
        o = cur.prototype;
    }
    return Value.fromBool(false);
}

fn nativeObjectGetPrototypeOf(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    _ = this;
    const v = argAt(args, 0);
    if (!v.isObject()) return vm.throwTypeError("Object.getPrototypeOf called on non-object");
    return if (v.asObject().prototype) |p| Value.fromObject(p) else Value.null_value;
}

fn nativeObjectCreate(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    _ = this;
    const proto_arg = argAt(args, 0);
    const proto: ?*gc.Object = if (proto_arg.isObject()) proto_arg.asObject() else if (proto_arg.isNull()) null else return vm.throwTypeError("Object prototype may only be an Object or null");
    return Value.fromObject(try vm.newObject(proto));
}

fn nativeObjectDefineProperty(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    _ = this;
    const obj_v = argAt(args, 0);
    if (!obj_v.isObject()) return vm.throwTypeError("Object.defineProperty called on non-object");
    const obj = obj_v.asObject();
    const key = try vm.toPropertyKey(argAt(args, 1));
    defer vm.gpa.free(key);
    const desc_v = argAt(args, 2);
    if (!desc_v.isObject()) return vm.throwTypeError("property descriptor must be an object");

    var desc = gc.PropertyDescriptor{ .enumerable = false, .writable = false, .configurable = false };
    const get_v = try vm.getProperty(desc_v, "get");
    const set_v = try vm.getProperty(desc_v, "set");
    if (get_v.isObject() or set_v.isObject()) {
        desc.is_accessor = true;
        desc.get = if (get_v.isObject()) get_v else null;
        desc.set = if (set_v.isObject()) set_v else null;
    } else {
        desc.value = try vm.getProperty(desc_v, "value");
        desc.writable = toBoolean(try vm.getProperty(desc_v, "writable"));
    }
    desc.enumerable = toBoolean(try vm.getProperty(desc_v, "enumerable"));
    desc.configurable = toBoolean(try vm.getProperty(desc_v, "configurable"));

    const gop = try obj.properties.getOrPut(vm.gpa, key);
    if (!gop.found_existing) gop.key_ptr.* = try vm.gpa.dupe(u8, key);
    gop.value_ptr.* = desc;
    return obj_v;
}

fn nativeObjectGetOwnPropertyDescriptor(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    _ = this;
    const obj_v = argAt(args, 0);
    if (!obj_v.isObject()) return vm.throwTypeError("called on non-object");
    const key = try vm.toPropertyKey(argAt(args, 1));
    defer vm.gpa.free(key);
    const desc = obj_v.asObject().properties.get(key) orelse return Value.undefined_value;
    const result = try vm.newObject(vm.object_proto);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    if (desc.is_accessor) {
        try vm.defineData(result, "get", desc.get orelse Value.undefined_value, true, true, true);
        try vm.defineData(result, "set", desc.set orelse Value.undefined_value, true, true, true);
    } else {
        try vm.defineData(result, "value", desc.value, true, true, true);
        try vm.defineData(result, "writable", Value.fromBool(desc.writable), true, true, true);
    }
    try vm.defineData(result, "enumerable", Value.fromBool(desc.enumerable), true, true, true);
    try vm.defineData(result, "configurable", Value.fromBool(desc.configurable), true, true, true);
    return Value.fromObject(result);
}

fn nativeString(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    _ = this;
    if (args.len == 0) return vm.makeString("");
    return vm.toStringVal(args[0]);
}

fn nativeNumber(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    _ = this;
    if (args.len == 0) return Value.fromNumber(0);
    return Value.fromNumber(try vm.toNumber(args[0]));
}

fn nativeBoolean(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    _ = this;
    return Value.fromBool(toBoolean(argAt(args, 0)));
}

fn mathUnary(ctx: *anyopaque, args: []const Value, comptime op: anytype) Error!Value {
    const vm = castVm(ctx);
    const x: f64 = try vm.toNumber(argAt(args, 0));
    return Value.fromNumber(op(x));
}
fn nativeMathAbs(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    return mathUnary(ctx, args, struct {
        fn f(x: f64) f64 {
            return @abs(x);
        }
    }.f);
}
fn nativeMathFloor(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    return mathUnary(ctx, args, std.math.floor);
}
fn nativeMathCeil(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    return mathUnary(ctx, args, std.math.ceil);
}
fn nativeMathRound(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    return mathUnary(ctx, args, struct {
        fn f(x: f64) f64 {
            if (std.math.isNan(x) or std.math.isInf(x) or x == 0) return x; // preserves -0
            // floor(x) + (fractional >= 0.5 ? 1 : 0); avoids the x+0.5
            // double-rounding pitfall. Ties round toward +Infinity.
            const fl = std.math.floor(x);
            const result = if (x - fl >= 0.5) fl + 1 else fl;
            // Values in [-0.5, 0) round to -0, not +0.
            if (result == 0 and x < 0) return -0.0;
            return result;
        }
    }.f);
}
fn nativeMathTrunc(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    return mathUnary(ctx, args, std.math.trunc);
}
fn nativeMathSqrt(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    return mathUnary(ctx, args, std.math.sqrt);
}
fn nativeMathSign(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    return mathUnary(ctx, args, struct {
        fn f(x: f64) f64 {
            if (std.math.isNan(x)) return x;
            if (x > 0) return 1;
            if (x < 0) return -1;
            return x; // +/-0
        }
    }.f);
}
fn nativeMathPow(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const base = try vm.toNumber(argAt(args, 0));
    const exp = try vm.toNumber(argAt(args, 1));
    return Value.fromNumber(jsPow(base, exp));
}
fn isNegZero(x: f64) bool {
    return x == 0 and std.math.signbit(x);
}
fn nativeMathMax(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    var result: f64 = -std.math.inf(f64);
    var saw_nan = false;
    // Spec: coerce every argument (side effects) before deciding.
    for (args) |a| {
        const n = try vm.toNumber(a);
        if (std.math.isNan(n)) {
            saw_nan = true;
        } else if (n > result or (n == 0 and result == 0 and isNegZero(result) and !isNegZero(n))) {
            result = n; // +0 is greater than -0
        }
    }
    return Value.fromNumber(if (saw_nan) std.math.nan(f64) else result);
}
fn nativeMathMin(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    var result: f64 = std.math.inf(f64);
    var saw_nan = false;
    for (args) |a| {
        const n = try vm.toNumber(a);
        if (std.math.isNan(n)) {
            saw_nan = true;
        } else if (n < result or (n == 0 and result == 0 and !isNegZero(result) and isNegZero(n))) {
            result = n; // -0 is less than +0
        }
    }
    return Value.fromNumber(if (saw_nan) std.math.nan(f64) else result);
}
fn nativeIsNaN(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    return Value.fromBool(std.math.isNan(try vm.toNumber(argAt(args, 0))));
}
fn nativeIsFinite(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const n = try vm.toNumber(argAt(args, 0));
    return Value.fromBool(!std.math.isNan(n) and !std.math.isInf(n));
}

/// Build a native for a unary Math function from a `fn(f64) f64`.
fn mathUnaryFn(comptime op: anytype) gc.NativeFn {
    return struct {
        fn call(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
            _ = this;
            return mathUnary(ctx, args, op);
        }
    }.call;
}

fn opSin(x: f64) f64 {
    return @sin(x);
}
fn opCos(x: f64) f64 {
    return @cos(x);
}
fn opTan(x: f64) f64 {
    return std.math.tan(x);
}
fn opAsin(x: f64) f64 {
    return std.math.asin(x);
}
fn opAcos(x: f64) f64 {
    return std.math.acos(x);
}
fn opAtan(x: f64) f64 {
    return std.math.atan(x);
}
fn opSinh(x: f64) f64 {
    return std.math.sinh(x);
}
fn opCosh(x: f64) f64 {
    return std.math.cosh(x);
}
fn opTanh(x: f64) f64 {
    return std.math.tanh(x);
}
fn opAsinh(x: f64) f64 {
    return std.math.asinh(x);
}
fn opAcosh(x: f64) f64 {
    return std.math.acosh(x);
}
fn opAtanh(x: f64) f64 {
    return std.math.atanh(x);
}
fn opExp(x: f64) f64 {
    return @exp(x);
}
fn opExpm1(x: f64) f64 {
    return std.math.expm1(x);
}
fn opLog(x: f64) f64 {
    return @log(x);
}
fn opLog2(x: f64) f64 {
    return @log2(x);
}
fn opLog10(x: f64) f64 {
    return @log10(x);
}
fn opLog1p(x: f64) f64 {
    return std.math.log1p(x);
}
fn opCbrt(x: f64) f64 {
    return std.math.cbrt(x);
}
fn opFround(x: f64) f64 {
    return @floatCast(@as(f32, @floatCast(x)));
}

fn nativeMathAtan2(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const y = try vm.toNumber(argAt(args, 0));
    const x = try vm.toNumber(argAt(args, 1));
    return Value.fromNumber(std.math.atan2(y, x));
}
fn nativeMathHypot(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    var sum: f64 = 0;
    var any_inf = false;
    for (args) |a| {
        const n = try vm.toNumber(a);
        if (std.math.isInf(n)) any_inf = true;
        sum += n * n;
    }
    // ±Infinity in any argument yields +Infinity, even alongside NaN.
    if (any_inf) return Value.fromNumber(std.math.inf(f64));
    return Value.fromNumber(@sqrt(sum));
}
fn nativeMathClz32(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const n = try vm.toUint32(argAt(args, 0));
    return Value.fromNumber(@floatFromInt(@as(u32, @clz(n))));
}
fn nativeMathImul(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const a = try vm.toInt32(argAt(args, 0));
    const b = try vm.toInt32(argAt(args, 1));
    return Value.fromNumber(@floatFromInt(a *% b));
}

var math_prng = std.Random.DefaultPrng.init(0x2545F4914F6CDD1D);
fn nativeMathRandom(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    _ = this;
    _ = args;
    return Value.fromNumber(math_prng.random().float(f64));
}

// ---- Array built-ins -------------------------------------------------------

fn isCallable(v: Value) bool {
    return v.isObject() and v.asObject().callable != null;
}

fn thisArray(vm: *Vm, this: Value) Error!*gc.Object {
    if (!this.isObject() or !this.asObject().is_array) {
        return vm.throwTypeError("Array.prototype method called on a non-array");
    }
    return this.asObject();
}

fn nativeArray(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    if (args.len == 1 and args[0].isNumber()) {
        const n = args[0].asNumber();
        const len: u32 = if (n < 0 or n != std.math.floor(n) or n > 4294967295) return vm.throwRangeError("invalid array length") else @intFromFloat(n);
        return Value.fromObject(try vm.newArray(len));
    }
    const arr = try vm.newArray(0);
    try vm.protect(Value.fromObject(arr));
    defer vm.unprotect();
    for (args, 0..) |a, i| try vm.setArrayElement(arr, @intCast(i), a);
    return Value.fromObject(arr);
}

fn nativeArrayIsArray(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    _ = this;
    const v = argAt(args, 0);
    return Value.fromBool(v.isObject() and v.asObject().is_array);
}

fn nativeArrayPush(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    for (args) |a| try arr.elements.append(vm.gpa, a);
    return Value.fromNumber(@floatFromInt(arr.elements.items.len));
}

fn nativeArrayPop(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    return arr.elements.pop() orelse Value.undefined_value;
}

fn nativeArrayIndexOf(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    const target = argAt(args, 0);
    for (arr.elements.items, 0..) |el, i| {
        if (sameTypeStrictEq(el, target)) return Value.fromNumber(@floatFromInt(i));
    }
    return Value.fromNumber(-1);
}

fn nativeArrayIncludes(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    const target = argAt(args, 0);
    for (arr.elements.items) |el| {
        // SameValueZero: like strict equality but NaN matches NaN.
        if (sameTypeStrictEq(el, target)) return Value.fromBool(true);
        if (el.isNumber() and target.isNumber() and std.math.isNan(el.asNumber()) and std.math.isNan(target.asNumber())) {
            return Value.fromBool(true);
        }
    }
    return Value.fromBool(false);
}

fn nativeArrayJoin(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    const sep_v = argAt(args, 0);
    const sep = if (sep_v.isUndefined()) try vm.makeString(",") else try vm.toStringVal(sep_v);
    try vm.protect(sep);
    defer vm.unprotect();

    var buf: std.ArrayList(u16) = .empty;
    defer buf.deinit(vm.gpa);
    for (arr.elements.items, 0..) |el, i| {
        if (i > 0) try buf.appendSlice(vm.gpa, sep.asString().units);
        if (el.isNullish()) continue; // null/undefined join as empty
        const s = try vm.toStringVal(el);
        try buf.appendSlice(vm.gpa, s.asString().units);
    }
    return vm.makeStringFromUtf16(buf.items);
}

fn nativeArrayToString(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    return nativeArrayJoin(ctx, this, args);
}

fn nativeArraySlice(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    const len: i64 = @intCast(arr.elements.items.len);
    const start = relativeIndex(try optNumber(vm, argAt(args, 0), 0), len);
    const end = relativeIndex(try optNumber(vm, argAt(args, 1), @floatFromInt(len)), len);
    const result = try vm.newArray(0);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    var i = start;
    while (i < end) : (i += 1) {
        try result.elements.append(vm.gpa, arr.elements.items[@intCast(i)]);
    }
    return Value.fromObject(result);
}

fn nativeArrayConcat(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    const result = try vm.newArray(0);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    for (arr.elements.items) |el| try result.elements.append(vm.gpa, el);
    for (args) |a| {
        if (a.isObject() and a.asObject().is_array) {
            for (a.asObject().elements.items) |el| try result.elements.append(vm.gpa, el);
        } else {
            try result.elements.append(vm.gpa, a);
        }
    }
    return Value.fromObject(result);
}

fn nativeArrayForEach(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    const cb = argAt(args, 0);
    if (!isCallable(cb)) return vm.throwTypeError("callback is not a function");
    var i: u32 = 0;
    const n: u32 = @intCast(arr.elements.items.len);
    while (i < n) : (i += 1) {
        if (i >= arr.elements.items.len) break;
        const el = arr.elements.items[i];
        _ = try vm.callValue(cb, Value.undefined_value, &.{ el, Value.fromNumber(@floatFromInt(i)), this });
    }
    return Value.undefined_value;
}

fn nativeArrayMap(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    const cb = argAt(args, 0);
    if (!isCallable(cb)) return vm.throwTypeError("callback is not a function");
    const n: u32 = @intCast(arr.elements.items.len);
    const result = try vm.newArray(n);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const el = if (i < arr.elements.items.len) arr.elements.items[i] else Value.undefined_value;
        const r = try vm.callValue(cb, Value.undefined_value, &.{ el, Value.fromNumber(@floatFromInt(i)), this });
        try vm.setArrayElement(result, i, r);
    }
    return Value.fromObject(result);
}

fn nativeArrayFilter(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const arr = try thisArray(vm, this);
    const cb = argAt(args, 0);
    if (!isCallable(cb)) return vm.throwTypeError("callback is not a function");
    const result = try vm.newArray(0);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    var i: u32 = 0;
    const n: u32 = @intCast(arr.elements.items.len);
    while (i < n) : (i += 1) {
        if (i >= arr.elements.items.len) break;
        const el = arr.elements.items[i];
        const keep = try vm.callValue(cb, Value.undefined_value, &.{ el, Value.fromNumber(@floatFromInt(i)), this });
        if (toBoolean(keep)) try result.elements.append(vm.gpa, el);
    }
    return Value.fromObject(result);
}

fn optNumber(vm: *Vm, v: Value, default: f64) Error!f64 {
    if (v.isUndefined()) return default;
    return vm.toNumber(v);
}

/// Clamp a relative index (negative counts from the end) to [0, len].
fn relativeIndex(n: f64, len: i64) i64 {
    if (std.math.isNan(n)) return 0;
    var idx: i64 = if (n < -9.2e18) -len else if (n > 9.2e18) len else @intFromFloat(std.math.trunc(n));
    if (idx < 0) idx += len;
    if (idx < 0) idx = 0;
    if (idx > len) idx = len;
    return idx;
}

// ---- Object.keys / values / entries ----------------------------------------

/// Collect an object's own enumerable string keys in spec order (integer
/// indices ascending, then insertion-order string keys).
fn ownEnumerableKeys(vm: *Vm, obj: *gc.Object, out: *std.ArrayList([]const u8)) Error!void {
    if (obj.is_array) {
        var i: usize = 0;
        while (i < obj.elements.items.len) : (i += 1) {
            var buf: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
            try out.append(vm.gpa, try vm.gpa.dupe(u8, s));
        }
    }
    var it = obj.properties.iterator();
    while (it.next()) |entry| {
        if (!entry.value_ptr.enumerable) continue;
        try out.append(vm.gpa, try vm.gpa.dupe(u8, entry.key_ptr.*));
    }
}

fn nativeObjectKeys(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const v = argAt(args, 0);
    if (!v.isObject()) return vm.throwTypeError("Object.keys called on non-object");
    var keys: std.ArrayList([]const u8) = .empty;
    defer {
        for (keys.items) |k| vm.gpa.free(k);
        keys.deinit(vm.gpa);
    }
    try ownEnumerableKeys(vm, v.asObject(), &keys);
    const result = try vm.newArray(0);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    for (keys.items) |k| {
        const s = try vm.makeString(k);
        try result.elements.append(vm.gpa, s);
    }
    return Value.fromObject(result);
}

fn nativeObjectValues(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const v = argAt(args, 0);
    if (!v.isObject()) return vm.throwTypeError("Object.values called on non-object");
    var keys: std.ArrayList([]const u8) = .empty;
    defer {
        for (keys.items) |k| vm.gpa.free(k);
        keys.deinit(vm.gpa);
    }
    try ownEnumerableKeys(vm, v.asObject(), &keys);
    const result = try vm.newArray(0);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    for (keys.items) |k| {
        const val = try vm.getProperty(v, k);
        try result.elements.append(vm.gpa, val);
    }
    return Value.fromObject(result);
}

fn nativeObjectEntries(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const v = argAt(args, 0);
    if (!v.isObject()) return vm.throwTypeError("Object.entries called on non-object");
    var keys: std.ArrayList([]const u8) = .empty;
    defer {
        for (keys.items) |k| vm.gpa.free(k);
        keys.deinit(vm.gpa);
    }
    try ownEnumerableKeys(vm, v.asObject(), &keys);
    const result = try vm.newArray(0);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();
    for (keys.items) |k| {
        const pair = try vm.newArray(2);
        try vm.protect(Value.fromObject(pair));
        defer vm.unprotect();
        pair.elements.items[0] = try vm.makeString(k);
        pair.elements.items[1] = try vm.getProperty(v, k);
        try result.elements.append(vm.gpa, Value.fromObject(pair));
    }
    return Value.fromObject(result);
}

// ---- String built-ins ------------------------------------------------------

fn coerceToString(vm: *Vm, v: Value) Error!Value {
    if (v.isString()) return v;
    return vm.toStringVal(v);
}

fn indexOfUtf16(haystack: []const u16, needle: []const u16, from: usize) ?usize {
    if (needle.len == 0) return @min(from, haystack.len);
    if (needle.len > haystack.len) return null;
    var i = from;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u16, haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn nativeStringToString(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    return coerceToString(castVm(ctx), this);
}

fn nativeStringCharAt(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
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

fn nativeStringCharCodeAt(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    const units = sv.asString().units;
    const n = try vm.toNumber(argAt(args, 0));
    if (std.math.isNan(n) or n < 0 or n >= @as(f64, @floatFromInt(units.len))) return Value.fromNumber(std.math.nan(f64));
    return Value.fromNumber(@floatFromInt(units[@intFromFloat(n)]));
}

fn nativeStringIndexOf(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
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

fn nativeStringIncludes(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    const search = try coerceToString(vm, argAt(args, 0));
    try vm.protect(search);
    defer vm.unprotect();
    return Value.fromBool(indexOfUtf16(sv.asString().units, search.asString().units, 0) != null);
}

fn nativeStringStartsWith(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    const search = try coerceToString(vm, argAt(args, 0));
    try vm.protect(search);
    defer vm.unprotect();
    return Value.fromBool(std.mem.startsWith(u16, sv.asString().units, search.asString().units));
}

fn nativeStringEndsWith(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    const search = try coerceToString(vm, argAt(args, 0));
    try vm.protect(search);
    defer vm.unprotect();
    return Value.fromBool(std.mem.endsWith(u16, sv.asString().units, search.asString().units));
}

fn nativeStringSlice(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
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

fn nativeStringSubstring(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
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

fn nativeStringToUpperCase(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    return stringMapCase(castVm(ctx), this, true);
}
fn nativeStringToLowerCase(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    return stringMapCase(castVm(ctx), this, false);
}
fn stringMapCase(vm: *Vm, this: Value, upper: bool) Error!Value {
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

fn nativeStringTrim(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
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

fn nativeStringRepeat(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
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
    while (i < count) : (i += 1) try buf.appendSlice(vm.gpa, units);
    return vm.makeStringFromUtf16(buf.items);
}

fn nativeStringConcat(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
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

fn nativeStringSplit(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const sv = try coerceToString(vm, this);
    try vm.protect(sv);
    defer vm.unprotect();
    const units = sv.asString().units;
    const result = try vm.newArray(0);
    try vm.protect(Value.fromObject(result));
    defer vm.unprotect();

    const sep_v = argAt(args, 0);
    if (sep_v.isUndefined()) {
        try result.elements.append(vm.gpa, sv);
        return Value.fromObject(result);
    }
    const sep = try coerceToString(vm, sep_v);
    try vm.protect(sep);
    defer vm.unprotect();
    const sep_units = sep.asString().units;

    if (sep_units.len == 0) {
        // Split into individual code units.
        for (units) |u| {
            const piece = try vm.makeStringFromUtf16(&[_]u16{u});
            try result.elements.append(vm.gpa, piece);
        }
        return Value.fromObject(result);
    }

    var start: usize = 0;
    while (indexOfUtf16(units, sep_units, start)) |idx| {
        const piece = try vm.makeStringFromUtf16(units[start..idx]);
        try result.elements.append(vm.gpa, piece);
        start = idx + sep_units.len;
    }
    const last = try vm.makeStringFromUtf16(units[start..]);
    try result.elements.append(vm.gpa, last);
    return Value.fromObject(result);
}

fn nativeStringFromCharCode(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
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

// ---- Number built-ins ------------------------------------------------------

fn thisNumber(vm: *Vm, this: Value) Error!f64 {
    if (this.isNumber()) return this.asNumber();
    return vm.throwTypeError("Number.prototype method called on non-number");
}

fn nativeNumberValueOf(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = args;
    return Value.fromNumber(try thisNumber(castVm(ctx), this));
}

fn nativeNumberToString(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const x = try thisNumber(vm, this);
    const radix_v = argAt(args, 0);
    const radix: u8 = if (radix_v.isUndefined()) 10 else @intFromFloat(try vm.toNumber(radix_v));
    if (radix == 10) {
        var buf: [64]u8 = undefined;
        return vm.makeString(numberToString(x, &buf));
    }
    if (radix < 2 or radix > 36) return vm.throwRangeError("toString() radix must be between 2 and 36");
    var buf: [72]u8 = undefined;
    // Fall back to decimal formatting for non-finite or out-of-i64-range values.
    if (std.math.isNan(x) or std.math.isInf(x) or @abs(x) >= 9.0e18) {
        return vm.makeString(numberToString(x, &buf));
    }
    // Integer radix conversion (fractional part not supported for non-decimal).
    const i: i64 = @intFromFloat(std.math.trunc(x));
    return vm.makeString(formatRadix(i, radix, &buf));
}

fn nativeNumberToFixed(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    const vm = castVm(ctx);
    const x = try thisNumber(vm, this);
    const d = try vm.toNumber(argAt(args, 0));
    const digits: usize = if (std.math.isNan(d) or d < 0) 0 else if (d > 100) 100 else @intFromFloat(d);
    if (std.math.isNan(x)) return vm.makeString("NaN");
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{[v]d:.[p]}", .{ .v = x, .p = digits }) catch return vm.makeString("0");
    return vm.makeString(s);
}

fn nativeNumberIsInteger(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    _ = this;
    const v = argAt(args, 0);
    if (!v.isNumber()) return Value.fromBool(false);
    const n = v.asNumber();
    return Value.fromBool(!std.math.isNan(n) and !std.math.isInf(n) and n == std.math.trunc(n));
}
fn nativeNumberIsFinite(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    _ = this;
    const v = argAt(args, 0);
    return Value.fromBool(v.isNumber() and !std.math.isNan(v.asNumber()) and !std.math.isInf(v.asNumber()));
}
fn nativeNumberIsNaN(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = ctx;
    _ = this;
    const v = argAt(args, 0);
    return Value.fromBool(v.isNumber() and std.math.isNan(v.asNumber()));
}

// ---- RegExp built-ins (stub) -----------------------------------------------

fn hasFlag(flags: []const u8, f: u8) bool {
    return std.mem.indexOfScalar(u8, flags, f) != null;
}

fn nativeRegExp(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
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

fn nativeRegExpTest(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    _ = args;
    return castVm(ctx).throwTypeError("RegExp matching is not yet implemented (Phase 4 stub)");
}
fn nativeRegExpExec(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    _ = args;
    return castVm(ctx).throwTypeError("RegExp matching is not yet implemented (Phase 4 stub)");
}

fn nativeRegExpToString(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
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

fn clampIndex(n: f64, len: i64) i64 {
    if (std.math.isNan(n) or n < 0) return 0;
    if (n > @as(f64, @floatFromInt(len))) return len;
    return @intFromFloat(std.math.trunc(n));
}

fn isJsSpace(u: u16) bool {
    return u == ' ' or u == '\t' or u == '\n' or u == '\r' or u == 0x0b or u == 0x0c or u == 0xa0 or u == 0xfeff;
}

/// Format an integer in the given radix into `buf`, returning the slice.
fn formatRadix(value: i64, radix: u8, buf: []u8) []const u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    var n: u64 = if (value < 0) @intCast(-value) else @intCast(value);
    var i: usize = buf.len;
    while (n > 0) {
        i -= 1;
        buf[i] = digits[@intCast(n % radix)];
        n /= radix;
    }
    if (value < 0) {
        i -= 1;
        buf[i] = '-';
    }
    return buf[i..];
}

fn utf16ToUtf8Alloc(gpa: std.mem.Allocator, units: []const u16) Error![]u8 {
    return std.unicode.utf16LeToUtf8Alloc(gpa, units) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => try gpa.dupe(u8, ""),
    };
}

/// Parse a canonical array-index string (no leading zeros, < 2^32-1), else null.
fn arrayIndex(key: []const u8) ?u32 {
    if (key.len == 0 or key.len > 10) return null;
    if (key.len > 1 and key[0] == '0') return null;
    var n: u64 = 0;
    for (key) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
    }
    if (n >= 4294967295) return null;
    return @intCast(n);
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

test "object literals and member access" {
    try testing.expectEqual(@as(f64, 3), try evalNumber("var o = { a: 1, b: 2 }; return o.a + o.b;"));
    try testing.expectEqual(@as(f64, 5), try evalNumber("var o = {}; o.x = 5; return o.x;"));
    try testing.expectEqual(@as(f64, 7), try evalNumber("var o = {}; o['k'] = 7; return o['k'];"));
    try testing.expectEqual(@as(f64, 3), try evalNumber("var o = { a: { b: 3 } }; return o.a.b;"));
    try testing.expectEqual(@as(f64, 0), try evalNumber("var o = {}; return o.missing === undefined ? 0 : 1;"));
}

test "methods and this" {
    try testing.expectEqual(@as(f64, 10), try evalNumber(
        \\var o = { x: 10, getX() { return this.x; } };
        \\return o.getX();
    ));
    try testing.expectEqual(@as(f64, 30), try evalNumber(
        \\var o = { a: 10, b: 20, sum: function() { return this.a + this.b; } };
        \\return o.sum();
    ));
}

test "new and constructors" {
    try testing.expectEqual(@as(f64, 5), try evalNumber(
        \\function Point(x) { this.x = x; }
        \\var p = new Point(5);
        \\return p.x;
    ));
    try testing.expectEqual(@as(f64, 7), try evalNumber(
        \\function Box(v) { this.v = v; }
        \\Box.prototype.get = function() { return this.v; };
        \\var b = new Box(7);
        \\return b.get();
    ));
    try testing.expectEqual(@as(f64, 3), try evalNumber(
        \\function Counter() { this.n = 0; }
        \\Counter.prototype.inc = function() { this.n = this.n + 1; return this; };
        \\var c = new Counter();
        \\c.inc().inc().inc();
        \\return c.n;
    ));
}

test "object toString coercion in concatenation" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    const v = try eval(&vm,
        \\var o = { toString: function() { return "hi"; } };
        \\return o + "!";
    );
    try testing.expect(v.isString());
    try testing.expectEqualSlices(u16, &[_]u16{ 'h', 'i', '!' }, v.asString().units);
}

test "globals, instanceof, in, typeof-undeclared" {
    try testing.expectEqual(@as(f64, 42), try evalNumber("foo = 42; return foo;"));
    try testing.expectEqual(@as(f64, 7), try evalNumber("globalThis.bar = 7; return bar;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\function C() {}
        \\var c = new C();
        \\return (c instanceof C) ? 1 : 0;
    ));
    try testing.expectEqual(@as(f64, 1), try evalNumber("var o = { a: 1 }; return ('a' in o) ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 0), try evalNumber("var o = { a: 1 }; return ('b' in o) ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return (typeof notDeclared === 'undefined') ? 1 : 0;"));
}

test "reading an undeclared global throws ReferenceError" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    try testing.expectError(error.JsThrow, eval(&vm, "return missingGlobalVar;"));
}

test "error objects and instanceof" {
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var e = new TypeError("boom");
        \\return (e.message === "boom" && e.name === "TypeError") ? 1 : 0;
    ));
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var e = new RangeError("x");
        \\return (e instanceof RangeError && e instanceof Error) ? 1 : 0;
    ));
    // Engine-thrown errors are real Error objects now.
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\try { null.x; } catch (e) { return (e instanceof TypeError) ? 1 : 0; }
        \\return 0;
    ));
}

test "Error.prototype.toString" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    const v = try eval(&vm, "return new Error('nope').toString();");
    try testing.expect(v.isString());
    try testing.expectEqualSlices(u16, &[_]u16{ 'E', 'r', 'r', 'o', 'r', ':', ' ', 'n', 'o', 'p', 'e' }, v.asString().units);
}

test "String / Number / Boolean" {
    try testing.expectEqual(@as(f64, 1), try evalNumber("return String(42) === '42' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 3.5), try evalNumber("return Number('3.5');"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return Boolean(0) === false ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return String(true) === 'true' ? 1 : 0;"));
}

test "Math" {
    try testing.expectEqual(@as(f64, 5), try evalNumber("return Math.abs(-5);"));
    try testing.expectEqual(@as(f64, 3), try evalNumber("return Math.floor(3.9);"));
    try testing.expectEqual(@as(f64, 4), try evalNumber("return Math.ceil(3.1);"));
    try testing.expectEqual(@as(f64, 4), try evalNumber("return Math.sqrt(16);"));
    try testing.expectEqual(@as(f64, 7), try evalNumber("return Math.max(1, 7, 3);"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return Math.min(1, 7, 3);"));
    try testing.expectEqual(@as(f64, 8), try evalNumber("return Math.pow(2, 3);"));
}

test "Object builtins" {
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var o = { a: 1 };
        \\return o.hasOwnProperty('a') && !o.hasOwnProperty('b') ? 1 : 0;
    ));
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var proto = { greet: 5 };
        \\var o = Object.create(proto);
        \\return (Object.getPrototypeOf(o) === proto && o.greet === 5) ? 1 : 0;
    ));
    try testing.expectEqual(@as(f64, 42), try evalNumber(
        \\var o = {};
        \\Object.defineProperty(o, 'x', { value: 42, enumerable: false });
        \\return o.x;
    ));
}

test "array literals and indexing" {
    try testing.expectEqual(@as(f64, 40), try evalNumber("var a = [10, 20, 30]; return a[0] + a[2];"));
    try testing.expectEqual(@as(f64, 3), try evalNumber("return [1, 2, 3].length;"));
    try testing.expectEqual(@as(f64, 4), try evalNumber("var a = []; a[3] = 9; return a.length;"));
    try testing.expectEqual(@as(f64, 2), try evalNumber("var a = [1, 2, 3, 4]; a.length = 2; return a.length;"));
    try testing.expectEqual(@as(f64, 3), try evalNumber("return new Array(3).length;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return Array.isArray([]) && !Array.isArray({}) ? 1 : 0;"));
}

test "array mutation methods" {
    try testing.expectEqual(@as(f64, 5), try evalNumber("var a = [1]; a.push(2); a.push(3); return a.pop() + a.length;"));
    try testing.expectEqual(@as(f64, 4), try evalNumber("return [1, 2].concat([3, 4]).length;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("var a = [1, 2, 3]; return (a.indexOf(2) === 1 && a.includes(3)) ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return [1, 2, 3].join('-') === '1-2-3' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("var a = [1, 2, 3, 4].slice(1, 3); return (a.length === 2 && a[0] === 2) ? 1 : 0;"));
}

test "array higher-order methods" {
    try testing.expectEqual(@as(f64, 12), try evalNumber(
        \\var a = [1, 2, 3].map(function (x) { return x * 2; });
        \\return a[0] + a[1] + a[2];
    ));
    try testing.expectEqual(@as(f64, 2), try evalNumber(
        \\var a = [1, 2, 3, 4].filter(function (x) { return x % 2 === 0; });
        \\return a.length;
    ));
    try testing.expectEqual(@as(f64, 6), try evalNumber(
        \\var sum = 0;
        \\[1, 2, 3].forEach(function (x) { sum += x; });
        \\return sum;
    ));
}

test "Object.keys/values/entries" {
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var o = { a: 1, b: 2 };
        \\var k = Object.keys(o);
        \\return (k.length === 2 && k[0] === 'a' && k[1] === 'b') ? 1 : 0;
    ));
    try testing.expectEqual(@as(f64, 3), try evalNumber(
        \\var o = { a: 1, b: 2 };
        \\var v = Object.values(o);
        \\return v[0] + v[1];
    ));
}

test "string primitive access and methods" {
    try testing.expectEqual(@as(f64, 5), try evalNumber("return 'hello'.length;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return 'hello'[1] === 'e' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 104), try evalNumber("return 'hello'.charCodeAt(0);"));
    try testing.expectEqual(@as(f64, 2), try evalNumber("return 'hello'.indexOf('ll');"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return 'hello'.includes('ell') ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return 'hello'.slice(1, 3) === 'el' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return 'Hello'.toUpperCase() === 'HELLO' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return 'Hello'.toLowerCase() === 'hello' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return '  hi  '.trim() === 'hi' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return 'ab'.repeat(3) === 'ababab' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 3), try evalNumber("return 'a,b,c'.split(',').length;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return 'a'.concat('b', 'c') === 'abc' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return String.fromCharCode(104, 105) === 'hi' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return ('hi'.startsWith('h') && 'hi'.endsWith('i')) ? 1 : 0;"));
}

test "RegExp construction (stub)" {
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var re = /abc/gi;
        \\return (re.source === "abc" && re.flags === "gi" && re.global && re.ignoreCase && !re.multiline) ? 1 : 0;
    ));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return (/x/ instanceof RegExp) ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var re = new RegExp("foo", "m");
        \\return (re.source === "foo" && re.multiline && re.flags === "m") ? 1 : 0;
    ));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return /ab/g.toString() === '/ab/g' ? 1 : 0;"));
}

test "RegExp matching throws (stub, replace later)" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    try testing.expectError(error.JsThrow, eval(&vm, "return /x/.test('x');"));
}

test "switch statements" {
    try testing.expectEqual(@as(f64, 20), try evalNumber(
        \\function f(n) {
        \\  switch (n) {
        \\    case 1: return 10;
        \\    case 2: return 20;
        \\    default: return 0;
        \\  }
        \\}
        \\return f(2);
    ));
    try testing.expectEqual(@as(f64, 99), try evalNumber(
        \\function f(n) { switch (n) { case 1: return 1; default: return 99; } }
        \\return f(7);
    ));
    // Fall-through until break.
    try testing.expectEqual(@as(f64, 3), try evalNumber(
        \\var x = 0;
        \\switch (1) { case 1: x += 1; case 2: x += 2; break; case 3: x += 100; }
        \\return x;
    ));
}

test "for-of over arrays and strings" {
    try testing.expectEqual(@as(f64, 6), try evalNumber("var s = 0; for (var x of [1, 2, 3]) s += x; return s;"));
    try testing.expectEqual(@as(f64, 30), try evalNumber("var s = 0; for (const x of [10, 20]) s += x; return s;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var out = "";
        \\for (var c of "abc") { out = out + c; }
        \\return out === "abc" ? 1 : 0;
    ));
    try testing.expectEqual(@as(f64, 3), try evalNumber(
        \\var s = 0;
        \\for (var x of [1, 2, 3, 4]) { if (x === 3) break; s += x; }
        \\return s;
    ));
    try testing.expectEqual(@as(f64, 4), try evalNumber(
        \\var s = 0;
        \\for (var x of [1, 2, 3]) { if (x === 2) continue; s += x; }
        \\return s;
    ));
}

test "number methods" {
    try testing.expectEqual(@as(f64, 1), try evalNumber("return (255).toString(16) === 'ff' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return (3.14159).toFixed(2) === '3.14' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return Number.isInteger(5) && !Number.isInteger(5.5) ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return (10).toString(2) === '1010' ? 1 : 0;"));
}

test "arrays under GC stress" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    vm.heap.stress = true;
    const v = try eval(&vm,
        \\var a = [];
        \\for (var i = 0; i < 20; i++) { a.push(i); }
        \\var b = a.map(function (x) { return x + 1; });
        \\return b[19] + a.length;
    );
    try testing.expectEqual(@as(f64, 40), v.asNumber()); // 20 + 20
}

test "objects under GC stress" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    vm.heap.stress = true;
    const v = try eval(&vm,
        \\function Node(v) { this.v = v; this.next = null; }
        \\var head = new Node(1);
        \\head.next = new Node(2);
        \\head.next.next = new Node(3);
        \\return head.v + head.next.v + head.next.next.v;
    );
    try testing.expectEqual(@as(f64, 6), v.asNumber());
}
