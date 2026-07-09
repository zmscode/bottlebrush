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

const realm = @import("runtime/realm.zig");
const errors_mod = @import("runtime/builtins/errors.zig");
const nativeError = errors_mod.nativeError;
const json_mod = @import("runtime/builtins/json.zig");
const JsonParser = json_mod.JsonParser;
const appendJsonChar = json_mod.appendJsonChar;
const support_mod = @import("runtime/support.zig");
const arrayIndex = support_mod.arrayIndex;
const compareUtf16 = support_mod.compareUtf16;
const doubleToInt32 = support_mod.doubleToInt32;
const isCallable = support_mod.isCallable;
const isConstructorValue = support_mod.isConstructorValue;
const jsMod = support_mod.jsMod;
const jsPow = support_mod.jsPow;
const jsShl = support_mod.jsShl;
const jsShr = support_mod.jsShr;
const jsUshr = support_mod.jsUshr;
const numberToString = support_mod.numberToString;
const orderedOwnKeys = support_mod.orderedOwnKeys;
const ownEnumerableKeys = support_mod.ownEnumerableKeys;
const prim_key = support_mod.prim_key;
const readTypedElement = support_mod.readTypedElement;
const regexp_flags_key = support_mod.regexp_flags_key;
const regexp_source_key = support_mod.regexp_source_key;
const sameTypeStrictEq = support_mod.sameTypeStrictEq;
const sameValue = support_mod.sameValue;
const stringToNumber = support_mod.stringToNumber;
const toBoolean = support_mod.toBoolean;
const utf16ToUtf8Alloc = support_mod.utf16ToUtf8Alloc;
const writeTypedElement = support_mod.writeTypedElement;

const std = @import("std");

const gc = @import("gc.zig");

const bc = @import("bytecode.zig");

const bilby = @import("bilby");

const Value = @import("value.zig").Value;

pub const Error = gc.VmError;

const max_call_depth = 2000;

/// One segment of the register stack. `top` is the allocation watermark.
const RegSlab = struct { mem: []Value, top: usize };

/// Initial register-slab size (Values); each additional slab doubles.
const reg_slab_initial = 1 << 12;

/// Instruction budget per `run`. A hung/looping test throws `error.Timeout`
/// (scored as an engine limit, not a conformance failure) instead of spinning
/// forever. Generous enough for legitimately heavy tests.
const max_steps = 50_000_000;

/// Wall-clock budget per `run` (nanoseconds). Catches runaways whose cost is in
/// GC or native loops rather than raw instruction count. Checked every
/// `wall_check_mask + 1` steps to keep the clock read off the hot path.
const max_wall_ns: i96 = 2 * std.time.ns_per_s;

const wall_check_mask: u64 = 0x3FFF; // ~16k steps

const Frame = struct {
    code: *const bc.CodeBlock,
    env: *gc.Environment,
    regs: []Value,
    this_value: Value,
    pc: u32 = 0,
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
    /// Instructions executed in the current `run`. Bounds pathological or
    /// intentionally-infinite scripts so a single test can't hang the host.
    steps: u64 = 0,
    /// Monotonic-clock provider + wall-clock deadline (nanoseconds). The step
    /// budget alone can't bound wall time when the cost is in GC or native
    /// loops, so `run` also arms a deadline checked periodically in the loop.
    threaded: std.Io.Threaded = std.Io.Threaded.init_single_threaded,
    deadline_ns: i96 = 0,
    /// Bytecode compiled at run time (eval / new Function). Kept alive for the
    /// VM's lifetime because closures reference their CodeBlocks.
    eval_programs: std.ArrayList(bc.Program) = .empty,
    /// Segmented register stack (V8-Ignition style): frames carve slices out
    /// of slabs instead of heap-allocating a register file per call. Growth
    /// appends a bigger slab, so outstanding frame slices stay valid; slabs
    /// are reused for the VM's lifetime.
    reg_slabs: std.ArrayList(RegSlab) = .empty,
    /// Interned constant-pool strings (content-keyed), so re-executing
    /// `load_const` reuses one heap string instead of allocating each time.
    /// Marked as GC roots; keys are gpa-owned.
    intern: std.StringHashMapUnmanaged(Value) = .empty,
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
    boolean_proto: ?*gc.Object = null,
    regexp_proto: ?*gc.Object = null,
    map_proto: ?*gc.Object = null,
    set_proto: ?*gc.Object = null,
    date_proto: ?*gc.Object = null,
    arraybuffer_proto: ?*gc.Object = null,
    typed_array_proto: ?*gc.Object = null,
    dataview_proto: ?*gc.Object = null,
    symbol_proto: ?*gc.Object = null,
    /// Global symbol registry (Symbol.for / Symbol.keyFor).
    symbol_registry: std.ArrayList(SymbolReg) = .empty,
    /// The well-known @@iterator symbol (used to drive the iteration protocol).
    symbol_iterator: ?Value = null,
    /// The property-map key encoding @@iterator (owned).
    symbol_iterator_key: []const u8 = &.{},
    /// Encoded property keys for the well-known symbols the engine consults.
    symbol_to_primitive_key: []const u8 = &.{},
    symbol_to_string_tag_key: []const u8 = &.{},
    symbol_has_instance_key: []const u8 = &.{},
    symbol_match_key: []const u8 = &.{},
    symbol_replace_key: []const u8 = &.{},
    symbol_search_key: []const u8 = &.{},
    symbol_split_key: []const u8 = &.{},
    symbol_species_key: []const u8 = &.{},
    iterator_proto: ?*gc.Object = null,
    generator_proto: ?*gc.Object = null,
    bigint_proto: ?*gc.Object = null,
    /// Every realm ever built (primary at index 0, plus `$262.createRealm`
    /// results). The active realm's intrinsics live in the flat fields above;
    /// this list keeps the others rooted and lets `evalScript` swap in a realm.
    realms: std.ArrayList(Realm) = .empty,

    const SymbolReg = struct { key: []u8, sym: *gc.Symbol };

    /// A snapshot of one realm's intrinsics. Field names match the `Vm`
    /// intrinsic fields exactly, so capture/restore is a reflective copy. The
    /// global symbol registry is intentionally excluded (it is agent-wide).
    pub const Realm = struct {
        object_proto: ?*gc.Object = null,
        function_proto: ?*gc.Object = null,
        global_object: ?*gc.Object = null,
        error_proto: ?*gc.Object = null,
        type_error_proto: ?*gc.Object = null,
        range_error_proto: ?*gc.Object = null,
        reference_error_proto: ?*gc.Object = null,
        syntax_error_proto: ?*gc.Object = null,
        array_proto: ?*gc.Object = null,
        string_proto: ?*gc.Object = null,
        number_proto: ?*gc.Object = null,
        boolean_proto: ?*gc.Object = null,
        regexp_proto: ?*gc.Object = null,
        map_proto: ?*gc.Object = null,
        set_proto: ?*gc.Object = null,
        date_proto: ?*gc.Object = null,
        arraybuffer_proto: ?*gc.Object = null,
        typed_array_proto: ?*gc.Object = null,
        dataview_proto: ?*gc.Object = null,
        symbol_proto: ?*gc.Object = null,
        symbol_iterator: ?Value = null,
        symbol_iterator_key: []const u8 = &.{},
        symbol_to_primitive_key: []const u8 = &.{},
        symbol_to_string_tag_key: []const u8 = &.{},
        symbol_has_instance_key: []const u8 = &.{},
        symbol_match_key: []const u8 = &.{},
        symbol_replace_key: []const u8 = &.{},
        symbol_search_key: []const u8 = &.{},
        symbol_split_key: []const u8 = &.{},
        symbol_species_key: []const u8 = &.{},
        iterator_proto: ?*gc.Object = null,
        generator_proto: ?*gc.Object = null,
        bigint_proto: ?*gc.Object = null,
    };

    /// Copy the active realm (flat fields) into a `Realm` snapshot.
    fn captureRealm(self: *const Vm) Realm {
        var r: Realm = undefined;
        inline for (std.meta.fields(Realm)) |f| @field(r, f.name) = @field(self, f.name);
        return r;
    }

    /// Make `r` the active realm by copying it into the flat fields.
    fn loadRealm(self: *Vm, r: Realm) void {
        inline for (std.meta.fields(Realm)) |f| @field(self, f.name) = @field(r, f.name);
    }

    /// Blank the active-realm fields (without freeing the strings, which the
    /// previously-captured realm still owns) so `buildRealm` starts fresh.
    fn resetRealmFields(self: *Vm) void {
        inline for (std.meta.fields(Realm)) |f| {
            @field(self, f.name) = switch (@typeInfo(f.type)) {
                .optional => null,
                .pointer => &.{},
                else => unreachable,
            };
        }
    }

    fn markRealm(r: *const Realm, tracer: *gc.Tracer) void {
        inline for (std.meta.fields(Realm)) |f| {
            if (f.type == ?*gc.Object) {
                if (@field(r, f.name)) |o| tracer.mark(&o.gc);
            } else if (f.type == ?Value) {
                if (@field(r, f.name)) |v| v.mark(tracer);
            }
        }
    }

    pub fn init(gpa: std.mem.Allocator) Vm {
        return .{ .gpa = gpa, .heap = gc.Heap.init(gpa) };
    }

    pub fn deinit(self: *Vm) void {
        self.frames.deinit(self.gpa);
        self.temp_roots.deinit(self.gpa);
        for (self.symbol_registry.items) |r| self.gpa.free(r.key);
        self.symbol_registry.deinit(self.gpa);
        // Each realm allocated its own well-known-symbol keys; free per realm
        // (the active realm's keys alias realms[0], so they are freed here too).
        for (self.realms.items) |rlm| {
            inline for (std.meta.fields(Realm)) |f| {
                if (comptime std.mem.endsWith(u8, f.name, "_key")) {
                    const k = @field(rlm, f.name);
                    if (k.len != 0) self.gpa.free(k);
                }
            }
        }
        self.realms.deinit(self.gpa);
        // Programs compiled by eval/Function() live as long as the VM: closures
        // created inside them keep pointing at their bytecode arenas.
        for (self.eval_programs.items) |*p| p.deinit();
        self.eval_programs.deinit(self.gpa);
        for (self.reg_slabs.items) |s| self.gpa.free(s.mem);
        self.reg_slabs.deinit(self.gpa);
        var iit = self.intern.keyIterator();
        while (iit.next()) |k| self.gpa.free(k.*);
        self.intern.deinit(self.gpa);
        self.heap.deinit();
    }

    /// GC root provider. Marks all reachable roots held by the VM.
    pub fn markRoots(self: *const Vm, tracer: *gc.Tracer) void {
        if (self.pending_exception) |e| e.mark(tracer);
        var intern_it = self.intern.valueIterator();
        while (intern_it.next()) |v| v.mark(tracer);
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
        if (self.boolean_proto) |o| tracer.mark(&o.gc);
        if (self.regexp_proto) |o| tracer.mark(&o.gc);
        if (self.map_proto) |o| tracer.mark(&o.gc);
        if (self.set_proto) |o| tracer.mark(&o.gc);
        if (self.date_proto) |o| tracer.mark(&o.gc);
        if (self.arraybuffer_proto) |o| tracer.mark(&o.gc);
        if (self.typed_array_proto) |o| tracer.mark(&o.gc);
        if (self.dataview_proto) |o| tracer.mark(&o.gc);
        if (self.symbol_proto) |o| tracer.mark(&o.gc);
        if (self.symbol_iterator) |s| s.mark(tracer);
        if (self.iterator_proto) |o| tracer.mark(&o.gc);
        if (self.generator_proto) |o| tracer.mark(&o.gc);
        if (self.bigint_proto) |o| tracer.mark(&o.gc);
        for (self.symbol_registry.items) |r| tracer.mark(&r.sym.gc);
        // Keep every realm's intrinsics alive (the active one overlaps the flat
        // fields above; the rest are only reachable here).
        for (self.realms.items) |*rlm| markRealm(rlm, tracer);
        for (self.temp_roots.items) |v| v.mark(tracer);
        for (self.frames.items) |f| {
            tracer.mark(&f.env.gc);
            f.this_value.mark(tracer);
            for (f.regs) |v| v.mark(tracer);
        }
    }

    pub fn protect(self: *Vm, v: Value) Error!void {
        try self.temp_roots.append(self.gpa, v);
    }
    pub fn unprotect(self: *Vm) void {
        _ = self.temp_roots.pop();
    }

    /// Allocation safe-point: under stress, collect every time; otherwise
    /// collect when the live set reaches the threshold, then re-arm it at ~2x
    /// the survivors (V8-style growth factor).
    pub fn maybeStress(self: *Vm) void {
        if (self.heap.stress) {
            _ = self.heap.collect(self);
            return;
        }
        if (self.heap.live_count >= self.heap.next_gc) {
            _ = self.heap.collect(self);
            self.heap.next_gc = @max(16 * 1024, self.heap.live_count * 2);
        }
    }

    /// Create the base intrinsics if they don't exist yet.
    pub fn bootstrap(self: *Vm) Error!void {
        if (self.object_proto != null) return;
        try self.buildRealm();
        // Register the primary realm so the collector keeps it (and any later
        // realms) rooted even while another realm is swapped in.
        try self.realms.append(self.gpa, self.captureRealm());
    }

    /// Build a fresh set of realm intrinsics into the active (flat) fields.
    fn buildRealm(self: *Vm) Error!void {
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
        try realm.installBuiltins(self);
    }

    /// `$262.createRealm`: build a genuinely fresh realm (its own global object
    /// and intrinsics) and return its index in `self.realms`. The primary realm
    /// is restored as active; callers run code in the new realm by swapping it
    /// in (see `nativeRealmEvalScript`).
    pub fn createRealm(self: *Vm) Error!usize {
        try self.bootstrap();
        const saved = self.captureRealm(); // primary (kept rooted via realms[0])
        self.resetRealmFields();
        self.buildRealm() catch |e| {
            self.resetRealmFields();
            self.loadRealm(saved);
            return e;
        };
        const fresh = self.captureRealm();
        try self.realms.append(self.gpa, fresh);
        self.loadRealm(saved); // restore the primary realm as active
        return self.realms.items.len - 1;
    }

    /// Test262 host hooks: define `$262` on the global. Called by the
    /// conformance runner only — normal realms never see it.
    pub fn installHost262(self: *Vm) Error!void {
        try self.bootstrap();
        const host = try self.newObject(self.object_proto);
        try self.protect(Value.fromObject(host));
        defer self.unprotect();
        try self.defineData(host, "global", Value.fromObject(self.global_object.?), true, false, true);
        try self.defineMethod(host, "evalScript", nativeHostEvalScript, 1);
        try self.defineMethod(host, "gc", nativeHostGc, 0);
        try self.defineMethod(host, "detachArrayBuffer", nativeHostDetachArrayBuffer, 1);
        try self.defineMethod(host, "createRealm", nativeHostCreateRealm, 0);
        try self.defineData(host, "agent", Value.fromObject(try self.makeAgentStub()), true, false, true);
        try self.defineData(self.global_object.?, "$262", Value.fromObject(host), true, false, true);
    }

    /// `$262.createRealm()` → a `$262`-shaped object bound to a fresh realm.
    /// `evalScript` on it swaps that realm in for the duration of the eval, so
    /// objects it creates use the new realm's intrinsics (distinct identities).
    fn nativeHostCreateRealm(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
        _ = this;
        _ = args;
        const vm: *Vm = @ptrCast(@alignCast(ctx));
        const idx = try vm.createRealm();
        const rlm = vm.realms.items[idx];
        const desc = try vm.newObject(vm.object_proto);
        try vm.protect(Value.fromObject(desc));
        defer vm.unprotect();
        try vm.defineData(desc, "global", Value.fromObject(rlm.global_object.?), true, false, true);
        try vm.defineData(desc, "\x00realmIdx", Value.fromNumber(@floatFromInt(idx)), false, false, false);
        try vm.defineMethod(desc, "evalScript", nativeRealmEvalScript, 1);
        try vm.defineMethod(desc, "createRealm", nativeHostCreateRealm, 0);
        try vm.defineMethod(desc, "gc", nativeHostGc, 0);
        try vm.defineMethod(desc, "detachArrayBuffer", nativeHostDetachArrayBuffer, 1);
        return Value.fromObject(desc);
    }

    /// `evalScript` bound to a specific realm (read from the receiver's hidden
    /// index slot): run the source with that realm's intrinsics active.
    fn nativeRealmEvalScript(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
        const vm: *Vm = @ptrCast(@alignCast(ctx));
        const idxv = if (this.isObject()) this.asObject().properties.get("\x00realmIdx") else null;
        if (idxv == null or !idxv.?.value.isNumber()) return vm.throwTypeError("evalScript called on a non-realm object");
        const idx: usize = @intFromFloat(idxv.?.value.asNumber());
        const sv = try vm.toStringVal(if (args.len > 0) args[0] else Value.undefined_value);
        try vm.protect(sv);
        defer vm.unprotect();
        const utf8 = try utf16ToUtf8Alloc(vm.gpa, sv.asString().units);
        defer vm.gpa.free(utf8);
        const saved = vm.captureRealm();
        vm.loadRealm(vm.realms.items[idx]);
        defer vm.loadRealm(saved);
        return vm.evalSource(utf8);
    }

    /// `$262.agent` stub: the method surface the harness expects, inert because
    /// there is no multi-agent/SharedArrayBuffer support yet.
    fn makeAgentStub(self: *Vm) Error!*gc.Object {
        const agent = try self.newObject(self.object_proto);
        try self.protect(Value.fromObject(agent));
        defer self.unprotect();
        const names = [_][]const u8{ "start", "broadcast", "getReport", "sleep", "monotonicNow", "receiveBroadcast", "report", "leaving" };
        inline for (names) |n| try self.defineMethod(agent, n, nativeAgentInert, 0);
        return agent;
    }

    fn nativeAgentInert(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
        _ = ctx;
        _ = this;
        _ = args;
        // monotonicNow-ish callers expect a number; others ignore the result.
        return Value.fromNumber(0);
    }

    fn nativeHostEvalScript(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
        _ = this;
        const vm: *Vm = @ptrCast(@alignCast(ctx));
        const sv = try vm.toStringVal(if (args.len > 0) args[0] else Value.undefined_value);
        try vm.protect(sv);
        defer vm.unprotect();
        const utf8 = try utf16ToUtf8Alloc(vm.gpa, sv.asString().units);
        defer vm.gpa.free(utf8);
        return vm.evalSource(utf8);
    }

    fn nativeHostGc(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
        _ = this;
        _ = args;
        const vm: *Vm = @ptrCast(@alignCast(ctx));
        _ = vm.heap.collect(vm);
        return Value.undefined_value;
    }

    fn nativeHostDetachArrayBuffer(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
        _ = this;
        const vm: *Vm = @ptrCast(@alignCast(ctx));
        if (args.len > 0 and args[0].isObject()) {
            const o = args[0].asObject();
            if (o.buffer_data) |data| {
                vm.gpa.free(data);
                o.buffer_data = null;
            }
        }
        return Value.undefined_value;
    }

    pub fn makeNative(self: *Vm, name: []const u8, func: gc.NativeFn, length: u32) Error!*gc.Object {
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

    /// Mark a native function object as a constructor (implements [[Construct]])
    /// and return it, so ctor definitions can wrap `makeNative` inline.
    pub fn asCtor(obj: *gc.Object) *gc.Object {
        obj.callable.?.constructor = true;
        return obj;
    }

    /// Define a method (native function) on `obj`, writable + configurable,
    /// non-enumerable (as built-in methods are).
    pub fn defineMethod(self: *Vm, obj: *gc.Object, name: []const u8, func: gc.NativeFn, length: u32) Error!void {
        try self.defineData(obj, name, Value.fromObject(try self.makeNative(name, func, length)), true, false, true);
    }

    /// Define an accessor property with a native getter (no setter).
    pub fn defineGetter(self: *Vm, obj: *gc.Object, name: []const u8, getter: gc.NativeFn) Error!void {
        const getter_obj = try self.makeNative(name, getter, 0);
        const gop = try obj.properties.getOrPut(self.gpa, name);
        if (!gop.found_existing) gop.key_ptr.* = try self.gpa.dupe(u8, name);
        gop.value_ptr.* = .{
            .is_accessor = true,
            .get = Value.fromObject(getter_obj),
            .set = null,
            .enumerable = false,
            .configurable = true,
        };
    }

    /// Define an accessor property with both a native getter and setter.
    pub fn defineAccessor(self: *Vm, obj: *gc.Object, name: []const u8, getter: gc.NativeFn, setter: gc.NativeFn) Error!void {
        const getter_obj = try self.makeNative(name, getter, 0);
        try self.protect(Value.fromObject(getter_obj));
        defer self.unprotect();
        const setter_obj = try self.makeNative(name, setter, 1);
        try self.protect(Value.fromObject(setter_obj));
        defer self.unprotect();
        const gop = try obj.properties.getOrPut(self.gpa, name);
        if (!gop.found_existing) gop.key_ptr.* = try self.gpa.dupe(u8, name);
        gop.value_ptr.* = .{
            .is_accessor = true,
            .get = Value.fromObject(getter_obj),
            .set = Value.fromObject(setter_obj),
            .enumerable = false,
            .configurable = true,
        };
    }

    pub fn newMap(self: *Vm) Error!*gc.Object {
        self.maybeStress();
        const o = try self.heap.create(gc.Object);
        o.prototype = self.map_proto;
        o.collection = .map;
        return o;
    }
    pub fn newSet(self: *Vm) Error!*gc.Object {
        self.maybeStress();
        const o = try self.heap.create(gc.Object);
        o.prototype = self.set_proto;
        o.collection = .set;
        return o;
    }

    /// Create a RegExp object: compile the pattern with bilby (the sibling regex
    /// engine) and attach the compiled matcher to the object. Throws SyntaxError
    /// for an invalid pattern or flags, per spec.
    pub fn makeRegExp(self: *Vm, source: []const u8, flags: []const u8) Error!*gc.Object {
        const obj = try self.newObject(self.regexp_proto);
        try self.protect(Value.fromObject(obj));
        defer self.unprotect();

        const parsed_flags = bilby.Flags.parse(flags) catch
            return self.throwSyntaxError("invalid regular expression flags");
        const pattern_units = bilby.utf8ToUtf16(self.gpa, source) catch
            return self.throwSyntaxError("invalid regular expression");
        defer self.gpa.free(pattern_units);
        obj.regex = blk: {
            const re = try self.gpa.create(bilby.Regex);
            errdefer self.gpa.destroy(re);
            re.* = bilby.Regex.compile(self.gpa, pattern_units, parsed_flags) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return self.throwSyntaxError("invalid regular expression"),
            };
            break :blk re; // the object owns it from here (freed in deinitCell)
        };

        // `source`/`flags`/flag booleans are accessors on RegExp.prototype
        // (per ES2015+); instances carry only the internal source text and a
        // writable `lastIndex`.
        const src = if (source.len == 0) "(?:)" else source;
        try self.defineData(obj, regexp_source_key, try self.makeString(src), false, false, false);
        try self.defineData(obj, regexp_flags_key, try self.makeString(flags), false, false, false);
        try self.defineData(obj, "lastIndex", Value.fromNumber(0), true, false, false);
        return obj;
    }

    /// Create an Error object directly (for engine-thrown exceptions).
    pub fn makeError(self: *Vm, proto: ?*gc.Object, msg: []const u8) Error!*gc.Object {
        const obj = try self.newObject(proto);
        try self.protect(Value.fromObject(obj));
        defer self.unprotect();
        try self.defineData(obj, "message", try self.makeString(msg), true, false, true);
        return obj;
    }

    pub fn installErrorSubtype(self: *Vm, name: []const u8) Error!*gc.Object {
        const proto = try self.newObject(self.error_proto);
        try self.defineData(proto, "name", try self.makeString(name), true, false, true);
        try self.defineData(proto, "message", try self.makeString(""), true, false, true);
        const ctor = asCtor(try self.makeNative(name, nativeError, 1));
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
        self.steps = 0;
        self.threaded = std.Io.Threaded.init_single_threaded;
        self.deadline_ns = std.Io.Clock.now(.awake, self.threaded.io()).nanoseconds + max_wall_ns;
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

    pub fn pendingErrorMessage(self: *Vm, gpa: std.mem.Allocator) ?[]u8 {
        const exc = self.pending_exception orelse return null;
        if (!exc.isObject()) return null;
        const msg_v = self.getProperty(exc, "message") catch return null;
        if (!msg_v.isString()) return null;
        return utf16ToUtf8Alloc(gpa, msg_v.asString().units) catch return null;
    }

    pub fn createEnv(self: *Vm, parent: ?*gc.Environment, n: u32) Error!*gc.Environment {
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

    const Step = union(enum) { advance, jumped, returned: Value, yielded: Value };
    const RunResult = union(enum) { returned: Value, yielded: Value };

    /// Carve `need` registers off the segmented stack. Returns the slab index
    /// and base; the caller restores `top` on frame exit (strict LIFO).
    pub fn pushRegs(self: *Vm, need: usize) Error!struct { slab: usize, base: usize, regs: []Value } {
        // Find room in the topmost slab, else append a bigger one. Older
        // slabs' outstanding slices are never moved.
        if (self.reg_slabs.items.len == 0) {
            const n = @max(reg_slab_initial, need);
            try self.reg_slabs.append(self.gpa, .{ .mem = try self.gpa.alloc(Value, n), .top = 0 });
        }
        var idx = self.reg_slabs.items.len - 1;
        var slab = &self.reg_slabs.items[idx];
        if (slab.top + need > slab.mem.len) {
            const n = @max(slab.mem.len * 2, need);
            try self.reg_slabs.append(self.gpa, .{ .mem = try self.gpa.alloc(Value, n), .top = 0 });
            idx = self.reg_slabs.items.len - 1;
            slab = &self.reg_slabs.items[idx];
        }
        const base = slab.top;
        slab.top += need;
        const regs = slab.mem[base .. base + need];
        @memset(regs, Value.undefined_value);
        return .{ .slab = idx, .base = base, .regs = regs };
    }

    pub fn execute(self: *Vm, code: *const bc.CodeBlock, env: *gc.Environment, this_value: Value) Error!Value {
        // Registers come from the segmented slab stack (no per-call allocation).
        const r = try self.pushRegs(code.num_registers);
        defer self.reg_slabs.items[r.slab].top = r.base;
        const regs = r.regs;

        var frame = Frame{ .code = code, .env = env, .regs = regs, .this_value = this_value };
        try self.frames.append(self.gpa, &frame);
        defer _ = self.frames.pop();

        return switch (try self.runLoop(&frame)) {
            .returned => |v| v,
            // Only generator frames should yield; a stray gen_yield in a plain
            // frame throws instead of crashing the host.
            .yielded => self.throwTypeError("yield outside generator"),
        };
    }

    /// The core dispatch loop over a frame. Runs until the function returns or a
    /// generator yields (leaving `frame.pc` at the `gen_yield` instruction).
    /// Parse, compile, and run `src8` in the global scope (indirect-eval
    /// semantics; direct eval's caller-scope capture is not supported). The
    /// compiled program is kept alive for the VM's lifetime.
    pub fn evalSource(self: *Vm, src8: []const u8) Error!Value {
        try self.bootstrap(); // a fresh VM (e.g. the REPL) may eval before any run()
        const parser_mod = @import("parser.zig");
        const compiler_mod = @import("compiler.zig");
        const pr = parser_mod.parse(self.gpa, src8, .script) catch return error.OutOfMemory;
        var tree = switch (pr) {
            .syntax_error => return self.throwSyntaxError("eval: invalid or unsupported source"),
            .ok => |t| t,
        };
        defer tree.deinit();
        const cr = compiler_mod.compile(self.gpa, tree.root, src8) catch return error.OutOfMemory;
        const program = switch (cr) {
            .compile_error => return self.throwSyntaxError("eval: invalid or unsupported source"),
            .ok => |p| p,
        };
        try self.eval_programs.append(self.gpa, program);
        const root = self.eval_programs.items[self.eval_programs.items.len - 1].root;
        const env = try self.createEnv(null, root.num_env_slots);
        return self.execute(root, env, Value.fromObject(self.global_object.?));
    }

    /// Direct `eval(src)`: compile `src` against the caller's private-name
    /// scope and run it with the caller's `this` and a child of the caller's
    /// environment, so private members and `this` stay visible. Outer locals
    /// resolved by the fragment fall back to global lookup (a partial model:
    /// `super` and outer non-global bindings aren't captured yet).
    pub fn directEval(self: *Vm, arg: Value, caller_env: *gc.Environment, caller_this: Value, code: *const bc.CodeBlock) Error!Value {
        if (!arg.isString()) return arg; // non-strings pass through unchanged
        const src8 = try utf16ToUtf8Alloc(self.gpa, arg.asString().units);
        defer self.gpa.free(src8);

        const parser_mod = @import("parser.zig");
        const compiler_mod = @import("compiler.zig");
        const pr = parser_mod.parseWithOptions(self.gpa, src8, .script, code.private_env.len > 0) catch return error.OutOfMemory;
        var tree = switch (pr) {
            .syntax_error => return self.throwSyntaxError("eval: invalid or unsupported source"),
            .ok => |t| t,
        };
        defer tree.deinit();
        const cr = compiler_mod.compileEval(self.gpa, tree.root, src8, code.private_env) catch return error.OutOfMemory;
        const program = switch (cr) {
            .compile_error => return self.throwSyntaxError("eval: invalid or unsupported source"),
            .ok => |p| p,
        };
        try self.eval_programs.append(self.gpa, program);
        const root = self.eval_programs.items[self.eval_programs.items.len - 1].root;
        const eval_env = try self.createEnv(caller_env, root.num_env_slots);
        return self.execute(root, eval_env, caller_this);
    }

    /// True once the current `run` has exceeded its wall-clock deadline.
    pub fn overBudget(self: *Vm) bool {
        return std.Io.Clock.now(.awake, self.threaded.io()).nanoseconds > self.deadline_ns;
    }

    /// Tick the execution budget once and raise `error.Timeout` if the step or
    /// wall-clock limit is exceeded. Called from the dispatch loop and from
    /// native loops whose trip count is controlled by a JS `length`.
    pub fn checkBudget(self: *Vm) Error!void {
        self.steps += 1;
        if (self.steps > max_steps) return error.Timeout;
        if (self.steps & wall_check_mask == 0 and self.overBudget()) return error.Timeout;
    }

    pub fn runLoop(self: *Vm, frame: *Frame) Error!RunResult {
        const code = frame.code;
        while (true) {
            try self.checkBudget();
            const inst = code.code[frame.pc];
            const step = self.exec(code, frame.env, frame.regs, frame.this_value, inst, &frame.pc) catch |e| {
                if (e != error.JsThrow) return e;
                if (self.findHandler(code, frame.pc)) |h| {
                    frame.regs[h.catch_reg] = self.pending_exception.?;
                    self.pending_exception = null;
                    frame.pc = h.target_pc;
                    continue;
                }
                return error.JsThrow;
            };
            switch (step) {
                .advance => frame.pc += 1,
                .jumped => {},
                .returned => |v| return .{ .returned = v },
                .yielded => |v| return .{ .yielded = v },
            }
        }
    }

    pub fn findHandler(self: *const Vm, code: *const bc.CodeBlock, pc: u32) ?bc.Handler {
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

    pub fn exec(
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

            .get_var => {
                const v = self.envAt(env, inst.b).slots[inst.c];
                if (v.isHole()) return self.throwReferenceError("cannot access lexical binding before initialization");
                regs[inst.a] = v;
            },
            .set_var => {
                const slot = &self.envAt(env, inst.a).slots[inst.b];
                if (slot.isHole()) return self.throwReferenceError("cannot access lexical binding before initialization");
                slot.* = regs[inst.c];
            },
            .init_var => self.envAt(env, inst.a).slots[inst.b] = regs[inst.c],
            .set_dead => self.envAt(env, inst.a).slots[inst.b] = Value.hole_value,

            .get_global => regs[inst.a] = try self.getGlobal(code.constants[inst.b].string, false),
            .get_global_typeof => regs[inst.a] = try self.getGlobal(code.constants[inst.b].string, true),
            .ensure_global => {
                // GlobalDeclarationInstantiation: top-level `var`/`function`
                // declarations create global properties (kept if they exist).
                const gname = code.constants[inst.a].string;
                if (!self.hasProperty(self.global_object.?, gname)) {
                    try self.defineData(self.global_object.?, gname, Value.undefined_value, true, true, false);
                }
            },
            .set_global => {
                const gname = code.constants[inst.a].string;
                // Strict mode: assigning to an undeclared global is a ReferenceError.
                if (code.is_strict and !self.hasProperty(self.global_object.?, gname)) {
                    return self.throwReferenceError("assignment to undeclared variable");
                }
                try self.setPropertyMode(Value.fromObject(self.global_object.?), gname, regs[inst.b], code.is_strict);
            },

            .add => regs[inst.a] = try self.opAdd(regs[inst.b], regs[inst.c]),
            .sub => regs[inst.a] = try self.numericBinop(.sub, regs[inst.b], regs[inst.c]),
            .mul => regs[inst.a] = try self.numericBinop(.mul, regs[inst.b], regs[inst.c]),
            .div => regs[inst.a] = try self.numericBinop(.div, regs[inst.b], regs[inst.c]),
            .mod => regs[inst.a] = try self.numericBinop(.mod, regs[inst.b], regs[inst.c]),
            .exp => regs[inst.a] = try self.numericBinop(.exp, regs[inst.b], regs[inst.c]),
            .neg => regs[inst.a] = try self.opNegate(regs[inst.b]),
            .to_number => regs[inst.a] = Value.fromNumber(try self.toNumber(regs[inst.b])),

            .bit_and => regs[inst.a] = try self.numericBinop(.bit_and, regs[inst.b], regs[inst.c]),
            .bit_or => regs[inst.a] = try self.numericBinop(.bit_or, regs[inst.b], regs[inst.c]),
            .bit_xor => regs[inst.a] = try self.numericBinop(.bit_xor, regs[inst.b], regs[inst.c]),
            .shl => regs[inst.a] = try self.numericBinop(.shl, regs[inst.b], regs[inst.c]),
            .shr => regs[inst.a] = try self.numericBinop(.shr, regs[inst.b], regs[inst.c]),
            .ushr => regs[inst.a] = try self.numericBinop(.ushr, regs[inst.b], regs[inst.c]),
            .bit_not => regs[inst.a] = try self.opBitNot(regs[inst.b]),

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
            .set_prop => try self.setPropertyMode(regs[inst.a], code.constants[inst.b].string, regs[inst.c], code.is_strict),
            .def_prop => try self.defineData(regs[inst.a].asObject(), code.constants[inst.b].string, regs[inst.c], true, false, true),
            .get_private => regs[inst.a] = try self.privateGet(regs[inst.b], code.constants[inst.c].string),
            .set_private => try self.privateSet(regs[inst.a], code.constants[inst.b].string, regs[inst.c]),
            .has_private => regs[inst.a] = Value.fromBool(try self.privateHas(regs[inst.b], code.constants[inst.c].string)),
            .def_pfield => try self.privateFieldAdd(regs[inst.a].asObject(), code.constants[inst.b].string, regs[inst.c]),
            .def_pmethod => try self.privateMethodAdd(regs[inst.a].asObject(), code.constants[inst.b].string, regs[inst.c]),
            .def_pget => try self.privateAccessorAdd(regs[inst.a].asObject(), code.constants[inst.b].string, regs[inst.c], true),
            .def_pset => try self.privateAccessorAdd(regs[inst.a].asObject(), code.constants[inst.b].string, regs[inst.c], false),
            .def_elem => {
                const key = try self.toPropertyKey(regs[inst.b]);
                defer self.gpa.free(key);
                try self.defineData(regs[inst.a].asObject(), key, regs[inst.c], true, false, true);
            },
            .get_elem => {
                const key = try self.toPropertyKey(regs[inst.c]);
                defer self.gpa.free(key);
                regs[inst.a] = try self.getProperty(regs[inst.b], key);
            },
            .set_elem => {
                const key = try self.toPropertyKey(regs[inst.b]);
                defer self.gpa.free(key);
                try self.setPropertyMode(regs[inst.a], key, regs[inst.c], code.is_strict);
            },
            .delete_prop => {
                const ok = try self.deleteProperty(regs[inst.b], code.constants[inst.c].string);
                if (code.is_strict and !ok) return self.throwTypeError("cannot delete non-configurable property");
                regs[inst.a] = Value.fromBool(ok);
            },
            .delete_elem => {
                const key = try self.toPropertyKey(regs[inst.c]);
                defer self.gpa.free(key);
                const ok = try self.deleteProperty(regs[inst.b], key);
                if (code.is_strict and !ok) return self.throwTypeError("cannot delete non-configurable property");
                regs[inst.a] = Value.fromBool(ok);
            },
            .load_this => regs[inst.a] = this_value,
            .arr_push => try self.arrayAppend(regs[inst.a].asObject(), regs[inst.b]),
            .arr_spread => try self.spreadInto(regs[inst.a].asObject(), regs[inst.b]),
            .iter_init => regs[inst.a] = try self.getIterator(regs[inst.b]),
            .iter_next => regs[inst.a] = try self.iteratorNext(regs[inst.b]),
            .enum_keys => regs[inst.a] = Value.fromObject(try self.enumKeys(regs[inst.b])),
            .copy_rest => try self.copyRestProperties(regs[inst.a].asObject(), regs[inst.b], regs[inst.c]),
            .gen_yield => return Step{ .yielded = regs[inst.b] },

            .new_closure => regs[inst.a] = try self.makeClosure(code.children[inst.b], env, this_value),
            .direct_eval => regs[inst.a] = try self.directEval(regs[inst.b], env, this_value, code),
            .set_fn_name => try self.setFunctionName(regs[inst.a], code.constants[inst.b].string),
            .call => {
                const receiver = regs[inst.b];
                const callee = regs[inst.b + 1];
                const args = regs[inst.b + 2 .. inst.b + 2 + inst.c];
                regs[inst.a] = try self.callValue(callee, receiver, args);
            },
            .call_apply => {
                const receiver = regs[inst.b];
                const callee = regs[inst.b + 1];
                const args_arr = regs[inst.b + 2];
                regs[inst.a] = try self.callValue(callee, receiver, args_arr.asObject().elements.items);
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

    pub fn envAt(self: *const Vm, env: *gc.Environment, depth: u32) *gc.Environment {
        _ = self;
        var e = env;
        var d = depth;
        while (d > 0) : (d -= 1) e = e.parent.?;
        return e;
    }

    // ---- calls & closures --------------------------------------------------

    /// SetFunctionName (NamedEvaluation): give an anonymous function the name
    /// of the binding/property it's assigned to — but only if it doesn't
    /// already have one (`function foo(){}` keeps "foo").
    pub fn setFunctionName(self: *Vm, v: Value, name: []const u8) Error!void {
        if (!v.isObject()) return;
        const o = v.asObject();
        if (o.callable == null and o.proxy_target == null) return;
        if (o.properties.getPtr("name")) |desc| {
            if (desc.value.isString() and desc.value.asString().units.len != 0) return; // already named
        }
        try self.defineData(o, "name", try self.makeString(name), false, false, true);
    }

    pub fn makeClosure(self: *Vm, child: *const bc.CodeBlock, env: *gc.Environment, creator_this: Value) Error!Value {
        self.maybeStress();
        const clo = try self.heap.create(gc.Closure);
        clo.code = child;
        clo.env = env;
        clo.constructor = !child.is_generator and !child.is_arrow; // generators/arrows aren't `new`-able
        if (child.is_arrow) clo.captured_this = creator_this; // lexical `this`
        const fn_obj = try self.heap.create(gc.Object);
        fn_obj.callable = clo;
        fn_obj.prototype = self.function_proto;
        try self.protect(Value.fromObject(fn_obj));
        defer self.unprotect();
        try self.defineData(fn_obj, "length", Value.fromNumber(@floatFromInt(child.fn_length)), false, false, true);
        try self.defineData(fn_obj, "name", try self.makeString(child.name), false, false, true);
        // Ordinary functions get a `prototype` object with a back-reference so
        // `new f()` has a prototype to inherit from; arrows have none.
        if (!child.is_arrow) {
            const proto = try self.heap.create(gc.Object);
            proto.prototype = self.object_proto;
            try self.defineData(fn_obj, "prototype", Value.fromObject(proto), true, false, false);
            try self.defineData(proto, "constructor", Value.fromObject(fn_obj), true, false, true);
        }
        return Value.fromObject(fn_obj);
    }

    /// Allocate `bound ++ call` into a fresh gpa buffer. The individual Values
    /// remain reachable via their owners (the bound function / caller frame),
    /// so only the backing memory needs to be freed by the caller.
    pub fn concatBoundArgs(self: *Vm, bound: []const Value, call: []const Value) Error![]Value {
        const buf = try self.gpa.alloc(Value, bound.len + call.len);
        @memcpy(buf[0..bound.len], bound);
        @memcpy(buf[bound.len..], call);
        return buf;
    }

    pub fn callValue(self: *Vm, callee: Value, this_value: Value, args: []const Value) Error!Value {
        // Callable proxy: dispatch to the `apply` trap, else forward to target.
        if (callee.isObject()) {
            if (callee.asObject().proxy_target) |target| {
                if (callee.asObject().proxy_revoked) return self.throwTypeError("cannot perform operation on a revoked proxy");
                const handler = callee.asObject().proxy_handler.?;
                if (try self.proxyTrapFn(handler, "apply")) |trap| {
                    const arr = try self.newArray(0);
                    try self.protect(Value.fromObject(arr));
                    defer self.unprotect();
                    for (args) |a| try self.arrayAppend(arr, a);
                    return self.callValue(trap, Value.fromObject(handler), &.{ Value.fromObject(target), this_value, Value.fromObject(arr) });
                }
                return self.callValue(Value.fromObject(target), this_value, args);
            }
            // Bound function: forward to the target with bound this + bound args.
            if (callee.asObject().bound_target) |target| {
                const o = callee.asObject();
                const combined = try self.concatBoundArgs(o.elements.items, args);
                defer self.gpa.free(combined);
                return self.callValue(target, o.bound_this, combined);
            }
        }
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
        // Calling a generator function creates (but does not run) a generator.
        if (code.is_generator) return self.makeGenerator(code, clo.env, this_value, args);
        // Build `arguments` before the env exists (createEnv can GC, and the
        // env isn't rooted yet — so root the object across it).
        var args_obj: ?Value = null;
        if (code.arguments_slot != null) {
            args_obj = Value.fromObject(try self.makeArgumentsObject(args));
            try self.protect(args_obj.?);
        }
        defer if (args_obj != null) self.unprotect();
        const env = try self.createEnv(clo.env, code.num_env_slots);
        var i: u32 = 0;
        while (i < code.num_params) : (i += 1) {
            env.slots[i] = if (i < args.len) args[i] else Value.undefined_value;
        }
        if (code.arguments_slot) |slot| {
            env.slots[slot] = args_obj.?;
            mapArguments(args_obj.?.asObject(), code, env, args.len);
        }
        try self.buildRestParam(code, env, args);
        // Arrows ignore the call receiver: `this` is the creation site's.
        // Sloppy functions coerce a nullish receiver to the global object;
        // strict functions see it as-is.
        var effective_this = if (code.is_arrow) (clo.captured_this orelse Value.undefined_value) else this_value;
        if (!code.is_arrow and !code.is_strict and effective_this.isNullish()) {
            effective_this = Value.fromObject(self.global_object.?);
        }
        return self.execute(code, env, effective_this);
    }

    /// Build an `arguments` object: an ordinary object with own indexed
    /// properties for each argument plus a writable, non-enumerable `length`.
    /// Turn a fresh arguments object into a mapped one: indices below
    /// min(argc, num_params) alias the frame's parameter env slots. Only for
    /// sloppy functions with simple (all-identifier) parameter lists.
    /// Populate a rest parameter's env slot with an array of the trailing
    /// arguments (`function f(a, ...r)` -> r = [args from rest_from on]).
    fn buildRestParam(self: *Vm, code: *const bc.CodeBlock, env: *gc.Environment, args: []const Value) Error!void {
        const slot = code.rest_slot orelse return;
        const arr = try self.newArray(0);
        try self.protect(Value.fromObject(arr));
        defer self.unprotect();
        var i: usize = code.rest_from;
        while (i < args.len) : (i += 1) try self.arrayAppend(arr, args[i]);
        env.slots[slot] = Value.fromObject(arr);
    }

    fn mapArguments(obj: *gc.Object, code: *const bc.CodeBlock, env: *gc.Environment, argc: usize) void {
        if (code.is_strict or !code.simple_params) return;
        const n = @min(@min(argc, code.num_params), 64);
        if (n == 0) return;
        obj.args_env = env;
        obj.args_map = if (n == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(n)) - 1;
    }

    /// The mapped-slot index for `key` on an arguments object, if still mapped.
    fn mappedArgIndex(obj: *const gc.Object, key: []const u8) ?u32 {
        if (obj.args_env == null) return null;
        const i = arrayIndex(key) orelse return null;
        if (i < 64 and (obj.args_map >> @intCast(i)) & 1 == 1) return i;
        return null;
    }

    pub fn makeArgumentsObject(self: *Vm, args: []const Value) Error!*gc.Object {
        const obj = try self.newObject(self.object_proto);
        try self.protect(Value.fromObject(obj));
        defer self.unprotect();
        for (args, 0..) |a, idx| {
            var b: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&b, "{d}", .{idx}) catch unreachable;
            try self.defineData(obj, s, a, true, true, true);
        }
        try self.defineData(obj, "length", Value.fromNumber(@floatFromInt(args.len)), true, false, true);
        return obj;
    }

    /// The `new` operator: create an ordinary object inheriting the
    /// constructor's `prototype`, run the constructor with it as `this`, and
    /// return the constructor's object result or that object.
    pub fn constructValue(self: *Vm, callee: Value, args: []const Value) Error!Value {
        // Constructor proxy: dispatch to the `construct` trap, else forward.
        if (callee.isObject()) {
            if (callee.asObject().proxy_target) |target| {
                if (callee.asObject().proxy_revoked) return self.throwTypeError("cannot perform operation on a revoked proxy");
                if (!isConstructorValue(Value.fromObject(target))) return self.throwTypeError("proxy target is not a constructor");
                const handler = callee.asObject().proxy_handler.?;
                if (try self.proxyTrapFn(handler, "construct")) |trap| {
                    const arr = try self.newArray(0);
                    try self.protect(Value.fromObject(arr));
                    defer self.unprotect();
                    for (args) |a| try self.arrayAppend(arr, a);
                    const r = try self.callValue(trap, Value.fromObject(handler), &.{ Value.fromObject(target), Value.fromObject(arr), callee });
                    if (!r.isObject()) return self.throwTypeError("proxy construct trap must return an object");
                    return r;
                }
                return self.constructValue(Value.fromObject(target), args);
            }
            // Bound function: construct the target with the bound args prepended.
            if (callee.asObject().bound_target) |target| {
                const o = callee.asObject();
                const combined = try self.concatBoundArgs(o.elements.items, args);
                defer self.gpa.free(combined);
                return self.constructValue(target, combined);
            }
        }
        if (!isConstructorValue(callee)) {
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

    // ---- generators --------------------------------------------------------

    pub fn makeGenerator(self: *Vm, code: *const bc.CodeBlock, closure_env: ?*gc.Environment, this_value: Value, args: []const Value) Error!Value {
        const obj = try self.newObject(self.generator_proto);
        try self.protect(Value.fromObject(obj));
        defer self.unprotect();
        var args_obj: ?Value = null;
        if (code.arguments_slot != null) {
            args_obj = Value.fromObject(try self.makeArgumentsObject(args));
            try self.protect(args_obj.?);
        }
        defer if (args_obj != null) self.unprotect();
        const env = try self.createEnv(closure_env, code.num_env_slots);
        var i: u32 = 0;
        while (i < code.num_params) : (i += 1) {
            env.slots[i] = if (i < args.len) args[i] else Value.undefined_value;
        }
        if (code.arguments_slot) |slot| {
            env.slots[slot] = args_obj.?;
            mapArguments(args_obj.?.asObject(), code, env, args.len);
        }
        try self.buildRestParam(code, env, args);
        // From here on: only gpa allocations (no GC), so env/regs/state stay live.
        const regs = try self.gpa.alloc(Value, code.num_registers);
        @memset(regs, Value.undefined_value);
        const state = try self.gpa.create(gc.GeneratorState);
        state.* = .{ .code = code, .env = env, .regs = regs, .this_value = this_value };
        obj.generator = state;
        return Value.fromObject(obj);
    }

    /// Resume a generator. mode: 0=next(v), 1=return(v), 2=throw(v). Returns an
    /// iterator-result object (or throws for mode 2 propagation).
    pub fn generatorResume(self: *Vm, this: Value, sent: Value, mode: u8) Error!Value {
        if (!this.isObject() or this.asObject().generator == null) return self.throwTypeError("not a generator");
        const g = this.asObject().generator.?;
        if (g.status == .executing) return self.throwTypeError("generator is already running");

        if (g.status == .completed) {
            if (mode == 2) {
                self.pending_exception = sent;
                return error.JsThrow;
            }
            return self.makeIterResult(if (mode == 1) sent else Value.undefined_value, true);
        }

        const code: *const bc.CodeBlock = @ptrCast(@alignCast(g.code));
        var frame = Frame{ .code = code, .env = g.env, .regs = g.regs, .this_value = g.this_value, .pc = g.pc };

        if (g.status == .start) {
            if (mode == 1) {
                g.status = .completed;
                return self.makeIterResult(sent, true);
            }
            if (mode == 2) {
                g.status = .completed;
                self.pending_exception = sent;
                return error.JsThrow;
            }
            // mode 0: begin at pc 0 (the initial `next` value is discarded).
        } else {
            // Suspended at a `gen_yield`. Resume based on mode.
            const yield_dst = code.code[g.pc].a;
            if (mode == 1) {
                g.status = .completed;
                return self.makeIterResult(sent, true);
            } else if (mode == 2) {
                // Inject a throw at the yield point (respect an enclosing catch).
                if (self.findHandler(code, g.pc)) |h| {
                    frame.regs[h.catch_reg] = sent;
                    frame.pc = h.target_pc;
                } else {
                    g.status = .completed;
                    self.pending_exception = sent;
                    return error.JsThrow;
                }
            } else {
                // next(v): the yield expression evaluates to `sent`.
                frame.regs[yield_dst] = sent;
                frame.pc += 1;
            }
        }

        if (self.depth >= max_call_depth) return self.throwRangeError("maximum call stack size exceeded");
        self.depth += 1;
        defer self.depth -= 1;
        g.status = .executing;
        try self.frames.append(self.gpa, &frame);
        defer _ = self.frames.pop();

        const result = self.runLoop(&frame) catch |e| {
            g.status = .completed;
            return e;
        };
        switch (result) {
            .yielded => |v| {
                g.pc = frame.pc;
                g.status = .suspended;
                return self.makeIterResult(v, false);
            },
            .returned => |v| {
                g.status = .completed;
                return self.makeIterResult(v, true);
            },
        }
    }

    // ---- object model ------------------------------------------------------

    pub fn newObject(self: *Vm, prototype: ?*gc.Object) Error!*gc.Object {
        self.maybeStress();
        const o = try self.heap.create(gc.Object);
        o.prototype = prototype;
        return o;
    }
    pub fn newObjectValue(self: *Vm) Error!Value {
        return Value.fromObject(try self.newObject(self.object_proto));
    }

    /// Append the iterated elements of `src` to array `dst`. Arrays copy
    /// directly; everything else goes through the @@iterator protocol (so Sets,
    /// Maps, generators, and custom iterables all work).
    pub fn spreadInto(self: *Vm, dst: *gc.Object, src: Value) Error!void {
        if (src.isObject() and src.asObject().is_array) {
            // Array spread visits 0..length (holes yield `undefined`). `n` is
            // snapshotted so a self-spread appends past the original range.
            const a = src.asObject();
            const n = a.array_length;
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                try self.checkBudget();
                try self.arrayAppend(dst, arrayGetOwn(a, i) orelse Value.undefined_value);
            }
            return;
        }
        const iter = try self.getIterator(src);
        try self.protect(iter);
        defer self.unprotect();
        while (true) {
            const r = try self.iteratorNext(iter);
            if (toBoolean(try self.getProperty(r, "done"))) break;
            try self.arrayAppend(dst, try self.getProperty(r, "value"));
        }
    }

    /// Collect the enumerable string keys of an object and its prototype chain
    /// (deduplicated), as an array — for `for-in`.
    /// CopyDataProperties (object rest + object spread): copy `src`'s own
    /// enumerable properties onto `target`, minus the keys in the `excluded_v`
    /// array (non-object = no exclusions). Getters are invoked. For rest
    /// destructuring a nullish source throws; spread callers pre-filter.
    pub fn copyRestProperties(self: *Vm, target: *gc.Object, src: Value, excluded_v: Value) Error!void {
        if (src.isNullish()) return self.throwTypeError("cannot destructure null or undefined");

        // Materialize the excluded keys once.
        var excluded: std.ArrayList([]u8) = .empty;
        defer {
            for (excluded.items) |k| self.gpa.free(k);
            excluded.deinit(self.gpa);
        }
        if (excluded_v.isObject()) {
            const ex_arr = excluded_v.asObject();
            var i: u32 = 0;
            while (i < ex_arr.array_length) : (i += 1) {
                if (Vm.arrayGetOwn(ex_arr, i)) |kv| {
                    try excluded.append(self.gpa, try self.toPropertyKey(kv));
                }
            }
        }

        // A string source exposes its indices; other primitives contribute none.
        if (!src.isObject()) {
            if (src.isString()) {
                const units = src.asString().units;
                var i: usize = 0;
                var buf: [16]u8 = undefined;
                while (i < units.len) : (i += 1) {
                    const key = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
                    if (keyIn(excluded.items, key)) continue;
                    const ch = try self.makeStringFromUtf16(units[i .. i + 1]);
                    try self.defineData(target, key, ch, true, true, true);
                }
            }
            return;
        }

        var keys: std.ArrayList([]const u8) = .empty;
        defer {
            for (keys.items) |k| self.gpa.free(k);
            keys.deinit(self.gpa);
        }
        try ownEnumerableKeys(self, src.asObject(), &keys);
        for (keys.items) |key| {
            if (keyIn(excluded.items, key)) continue;
            const v = try self.getProperty(src, key);
            try self.protect(v);
            defer self.unprotect();
            try self.defineData(target, key, v, true, true, true);
        }
    }

    fn keyIn(list: []const []u8, key: []const u8) bool {
        for (list) |k| {
            if (std.mem.eql(u8, k, key)) return true;
        }
        return false;
    }

    pub fn enumKeys(self: *Vm, base: Value) Error!*gc.Object {
        const arr = try self.newArray(0);
        if (!base.isObject()) return arr;
        try self.protect(Value.fromObject(arr));
        defer self.unprotect();

        // Keys already visited (or shadowed by a non-enumerable own property on
        // a nearer object). Owns its keys.
        var seen = std.StringHashMap(void).init(self.gpa);
        defer {
            var kit = seen.keyIterator();
            while (kit.next()) |k| self.gpa.free(k.*);
            seen.deinit();
        }

        var o: ?*gc.Object = base.asObject();
        while (o) |cur| {
            // Emit this level's enumerable keys (spec order) not yet visited.
            var emit: std.ArrayList([]const u8) = .empty;
            defer {
                for (emit.items) |k| self.gpa.free(k);
                emit.deinit(self.gpa);
            }
            try orderedOwnKeys(self, cur, true, &emit);
            for (emit.items) |k| {
                if (seen.contains(k)) continue;
                try self.arrayAppend(arr, try self.makeString(k));
            }
            // Then mark ALL own keys — a non-enumerable own property shadows
            // an enumerable prototype property of the same name.
            var all: std.ArrayList([]const u8) = .empty;
            defer {
                for (all.items) |k| self.gpa.free(k);
                all.deinit(self.gpa);
            }
            try orderedOwnKeys(self, cur, false, &all);
            for (all.items) |k| {
                const gop = try seen.getOrPut(k);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try self.gpa.dupe(u8, k);
                }
            }
            o = cur.prototype;
        }
        return arr;
    }

    // ---- iteration protocol ------------------------------------------------

    pub fn makeIterResult(self: *Vm, value: Value, done: bool) Error!Value {
        const o = try self.newObject(self.object_proto);
        try self.protect(Value.fromObject(o));
        defer self.unprotect();
        try self.defineData(o, "value", value, true, true, true);
        try self.defineData(o, "done", Value.fromBool(done), true, true, true);
        return Value.fromObject(o);
    }

    /// A built-in iterator over `target`. kind: 0=values, 1=keys, 2=entries.
    pub fn makeIterator(self: *Vm, target: Value, kind: u8) Error!Value {
        const it = try self.newObject(self.iterator_proto);
        try self.protect(Value.fromObject(it));
        defer self.unprotect();
        try self.defineData(it, "\x00itT", target, true, false, false);
        try self.defineData(it, "\x00itI", Value.fromNumber(0), true, false, false);
        try self.defineData(it, "\x00itK", Value.fromNumber(@floatFromInt(kind)), true, false, false);
        return Value.fromObject(it);
    }

    /// GetIterator(obj): obj[@@iterator]().
    pub fn getIterator(self: *Vm, iterable: Value) Error!Value {
        const method = try self.getProperty(iterable, self.symbol_iterator_key);
        if (!isCallable(method)) return self.throwTypeError("value is not iterable");
        const iter = try self.callValue(method, iterable, &.{});
        if (!iter.isObject()) return self.throwTypeError("iterator method did not return an object");
        return iter;
    }

    /// IteratorNext(iter): iter.next().
    pub fn iteratorNext(self: *Vm, iter: Value) Error!Value {
        const next = try self.getProperty(iter, "next");
        const r = try self.callValue(next, iter, &.{});
        if (!r.isObject()) return self.throwTypeError("iterator result is not an object");
        return r;
    }

    pub fn iterPair(self: *Vm, a: Value, b: Value) Error!Value {
        const arr = try self.newArray(0);
        try self.protect(Value.fromObject(arr));
        defer self.unprotect();
        try self.arrayAppend(arr, a);
        try self.arrayAppend(arr, b);
        return Value.fromObject(arr);
    }
    pub fn iterEntryValue(self: *Vm, kind: u8, index: Value, element: Value) Error!Value {
        return switch (kind) {
            1 => index, // keys
            2 => self.iterPair(index, element), // entries
            else => element, // values
        };
    }

    /// Create an array of logical length `len`. Elements are absent (holes)
    /// until written — the dense store is not pre-materialized, so
    /// `new Array(1e9)` costs nothing.
    pub fn newArray(self: *Vm, len: u32) Error!*gc.Object {
        self.maybeStress();
        const o = try self.heap.create(gc.Object);
        o.prototype = self.array_proto;
        o.is_array = true;
        o.array_length = len;
        return o;
    }

    pub fn newArrayBuffer(self: *Vm, len: u32) Error!*gc.Object {
        self.maybeStress();
        const o = try self.heap.create(gc.Object);
        o.prototype = self.arraybuffer_proto;
        const data = try self.gpa.alloc(u8, len);
        @memset(data, 0);
        o.buffer_data = data;
        return o;
    }

    /// Create a typed-array view object over a (possibly new) buffer.
    pub fn newTypedArray(self: *Vm, proto: ?*gc.Object, buffer: *gc.Object, offset: u32, length: u32, kind: gc.TAKind) Error!*gc.Object {
        self.maybeStress();
        const o = try self.heap.create(gc.Object);
        o.prototype = proto;
        o.ta = .{ .buffer = buffer, .offset = offset, .length = length, .kind = kind };
        return o;
    }

    // ---- array element storage (V8-style: fast dense + dictionary fallback) ---

    /// The dense store may lead the write index by at most this much before the
    /// array flips to dictionary mode (mirrors V8's `kMaxGap`).
    const array_max_gap: u32 = 1024;

    /// The array's own element at `i`, or null if it's a hole/absent. No
    /// prototype lookup — callers that need the JS `[[Get]]` fall back themselves.
    pub fn arrayGetOwn(arr: *gc.Object, i: u32) ?Value {
        if (arr.dictionary_mode) return arr.array_dict.get(i);
        if (i < arr.elements.items.len) {
            const v = arr.elements.items[i];
            return if (v.isHole()) null else v;
        }
        return null;
    }

    pub fn arrayHasOwn(arr: *gc.Object, i: u32) bool {
        return arrayGetOwn(arr, i) != null;
    }

    pub fn bumpArrayLength(arr: *gc.Object, i: u32) void {
        const want: u64 = @as(u64, i) + 1;
        if (want > arr.array_length) arr.array_length = @intCast(want);
    }

    /// Move all present dense elements into the dictionary store and switch mode.
    pub fn arrayToDictionary(self: *Vm, arr: *gc.Object) Error!void {
        for (arr.elements.items, 0..) |v, idx| {
            if (v.isHole()) continue;
            try arr.array_dict.put(self.gpa, @intCast(idx), v);
        }
        arr.elements.clearAndFree(self.gpa);
        arr.dictionary_mode = true;
    }

    /// `arr[i] = value` (an ordinary value, never a hole). Grows the dense store
    /// (filling the gap with holes) for small gaps, else converts to dictionary
    /// mode so a far-out write can't balloon the backing store.
    pub fn setArrayElement(self: *Vm, arr: *gc.Object, i: u32, value: Value) Error!void {
        if (arr.dictionary_mode) {
            try arr.array_dict.put(self.gpa, i, value);
            bumpArrayLength(arr, i);
            return;
        }
        const cap: u32 = @intCast(arr.elements.items.len);
        if (i < cap) {
            arr.elements.items[i] = value;
        } else if (i - cap < array_max_gap) {
            try arr.elements.resize(self.gpa, i + 1);
            for (arr.elements.items[cap..i]) |*slot| slot.* = Value.hole_value;
            arr.elements.items[i] = value;
        } else {
            try self.arrayToDictionary(arr);
            try arr.array_dict.put(self.gpa, i, value);
        }
        bumpArrayLength(arr, i);
    }

    /// Append `value` at the current length.
    pub fn arrayAppend(self: *Vm, arr: *gc.Object, value: Value) Error!void {
        try self.setArrayElement(arr, arr.array_length, value);
    }

    /// Delete the own element at `i` (leaves a hole; length unchanged).
    pub fn deleteArrayElement(self: *Vm, arr: *gc.Object, i: u32) void {
        _ = self;
        if (arr.dictionary_mode) {
            _ = arr.array_dict.remove(i);
        } else if (i < arr.elements.items.len) {
            arr.elements.items[i] = Value.hole_value;
        }
    }

    pub fn setArrayLength(self: *Vm, arr: *gc.Object, n: u32) Error!void {
        if (arr.dictionary_mode) {
            if (n < arr.array_length) {
                var doomed: std.ArrayList(u32) = .empty;
                defer doomed.deinit(self.gpa);
                var it = arr.array_dict.keyIterator();
                while (it.next()) |k| {
                    if (k.* >= n) try doomed.append(self.gpa, k.*);
                }
                for (doomed.items) |k| _ = arr.array_dict.remove(k);
            }
        } else if (n < arr.elements.items.len) {
            arr.elements.shrinkRetainingCapacity(n);
        }
        arr.array_length = n;
    }

    /// Collect the present (non-hole) own indices in ascending order. Bounded by
    /// the number of stored elements, never by the logical length — so builtins
    /// stay cheap on sparse arrays. Caller owns `out`.
    pub fn arrayPresentIndices(self: *Vm, arr: *gc.Object, out: *std.ArrayList(u32)) Error!void {
        if (arr.dictionary_mode) {
            var it = arr.array_dict.keyIterator();
            while (it.next()) |k| try out.append(self.gpa, k.*);
            std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
        } else {
            for (arr.elements.items, 0..) |v, i| {
                if (!v.isHole()) try out.append(self.gpa, @intCast(i));
            }
        }
    }

    /// Materialize an array value's 0..length elements (holes -> undefined) into
    /// a fresh gpa buffer, for use as an argument list (`apply`/`Reflect`). The
    /// values stay reachable via the source array; the caller frees the buffer.
    pub fn argListFromArray(self: *Vm, v: Value) Error![]Value {
        if (!v.isObject() or !v.asObject().is_array) return self.gpa.alloc(Value, 0);
        const a = v.asObject();
        const buf = try self.gpa.alloc(Value, a.array_length);
        for (buf, 0..) |*slot, i| slot.* = arrayGetOwn(a, @intCast(i)) orelse Value.undefined_value;
        return buf;
    }

    /// Build a `{value, writable, enumerable, configurable}` descriptor object
    /// (as returned by `Object.getOwnPropertyDescriptor`).
    pub fn makeDataDescriptor(self: *Vm, value: Value, w: bool, e: bool, c: bool) Error!Value {
        const result = try self.newObject(self.object_proto);
        try self.protect(Value.fromObject(result));
        defer self.unprotect();
        try self.defineData(result, "value", value, true, true, true);
        try self.defineData(result, "writable", Value.fromBool(w), true, true, true);
        try self.defineData(result, "enumerable", Value.fromBool(e), true, true, true);
        try self.defineData(result, "configurable", Value.fromBool(c), true, true, true);
        return Value.fromObject(result);
    }

    /// Define an own data property with explicit attributes (key is duplicated).
    pub fn defineData(self: *Vm, obj: *gc.Object, key: []const u8, value: Value, w: bool, e: bool, c: bool) Error!void {
        const gop = try obj.properties.getOrPut(self.gpa, key);
        if (!gop.found_existing) gop.key_ptr.* = try self.gpa.dupe(u8, key);
        gop.value_ptr.* = .{ .value = value, .writable = w, .enumerable = e, .configurable = c, .is_accessor = false };
    }

    // ---- private class members (# names) -----------------------------------
    //
    // A private element is a per-object property stored under a hidden,
    // class-unique key (encoded `\x00P<classid>\x00#name`). These keys are never
    // produced by ordinary property access or enumeration, so private elements
    // are invisible except through the dedicated private opcodes. Access is
    // own-only (no prototype walk) and brand-checked: touching a private member
    // an object never received is a TypeError.

    pub fn privateGet(self: *Vm, base: Value, key: []const u8) Error!Value {
        if (!base.isObject()) return self.throwTypeError("cannot read a private member from a non-object");
        const desc = base.asObject().properties.get(key) orelse
            return self.throwTypeError("cannot read private member from an object whose class did not declare it");
        if (desc.is_accessor) {
            const getter = desc.get orelse return self.throwTypeError("private member was defined without a getter");
            return self.callValue(getter, base, &.{});
        }
        return desc.value;
    }

    pub fn privateSet(self: *Vm, base: Value, key: []const u8, v: Value) Error!void {
        if (!base.isObject()) return self.throwTypeError("cannot write a private member to a non-object");
        const desc = base.asObject().properties.getPtr(key) orelse
            return self.throwTypeError("cannot write private member to an object whose class did not declare it");
        if (desc.is_accessor) {
            const setter = desc.set orelse return self.throwTypeError("private member was defined without a setter");
            _ = try self.callValue(setter, base, &.{v});
            return;
        }
        if (!desc.writable) return self.throwTypeError("cannot write to a private method");
        desc.value = v;
    }

    pub fn privateHas(self: *Vm, base: Value, key: []const u8) Error!bool {
        // `#x in obj`: the right operand must be an object.
        if (!base.isObject()) return self.throwTypeError("cannot use 'in' to test a private member on a non-object");
        return base.asObject().properties.contains(key);
    }

    pub fn privateFieldAdd(self: *Vm, obj: *gc.Object, key: []const u8, v: Value) Error!void {
        if (obj.properties.contains(key)) {
            return self.throwTypeError("cannot initialize the same private member twice on an object");
        }
        try self.defineData(obj, key, v, true, false, false); // writable, non-enumerable, non-configurable
    }

    pub fn privateMethodAdd(self: *Vm, obj: *gc.Object, key: []const u8, closure: Value) Error!void {
        // Non-writable: `obj.#m = x` throws. Added once per object.
        try self.defineData(obj, key, closure, false, false, false);
    }

    pub fn privateAccessorAdd(self: *Vm, obj: *gc.Object, key: []const u8, fnv: Value, is_get: bool) Error!void {
        const gop = try obj.properties.getOrPut(self.gpa, key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.gpa.dupe(u8, key);
            gop.value_ptr.* = .{ .is_accessor = true, .get = null, .set = null, .enumerable = false, .configurable = false, .writable = false };
        }
        if (is_get) gop.value_ptr.get = fnv else gop.value_ptr.set = fnv;
    }

    /// GetMethod(handler, name) for a proxy trap: returns the callable trap, or
    /// null when it is undefined/null (the caller forwards to the target).
    /// Throws TypeError when the trap is present but not callable.
    fn proxyTrapFn(self: *Vm, handler: *gc.Object, name: []const u8) Error!?Value {
        const trap = try self.getProperty(Value.fromObject(handler), name);
        if (trap.isNullish()) return null;
        if (!isCallable(trap)) return self.throwTypeError("proxy trap is not callable");
        return trap;
    }

    /// [[Get]] on a proxy with an explicit receiver (spec 10.5.8). Used both
    /// when the proxy is the base and when it appears in a prototype chain.
    fn proxyGet(self: *Vm, p: *gc.Object, key: []const u8, receiver: Value) Error!Value {
        if (p.proxy_revoked) return self.throwTypeError("cannot perform operation on a revoked proxy");
        const handler = p.proxy_handler.?;
        const target = p.proxy_target.?;
        if (try self.proxyTrapFn(handler, "get")) |trap| {
            const result = try self.callValue(trap, Value.fromObject(handler), &.{ Value.fromObject(target), try self.makeString(key), receiver });
            // Invariants against a non-configurable own property of the target.
            if (target.properties.get(key)) |desc| {
                if (!desc.is_accessor and !desc.configurable and !desc.writable and !sameValue(result, desc.value))
                    return self.throwTypeError("proxy get must report the same value for a non-configurable, non-writable property");
                if (desc.is_accessor and !desc.configurable and desc.get == null and !result.isUndefined())
                    return self.throwTypeError("proxy get must report undefined for a non-configurable accessor with an undefined getter");
            }
            return result;
        }
        return self.getProperty(Value.fromObject(target), key);
    }

    /// [[Set]] on a proxy with an explicit receiver (spec 10.5.9). Returns
    /// false when the trap refuses the write.
    fn proxySet(self: *Vm, p: *gc.Object, key: []const u8, value: Value, receiver: Value) Error!bool {
        if (p.proxy_revoked) return self.throwTypeError("cannot perform operation on a revoked proxy");
        const handler = p.proxy_handler.?;
        const target = p.proxy_target.?;
        if (try self.proxyTrapFn(handler, "set")) |trap| {
            const r = try self.callValue(trap, Value.fromObject(handler), &.{ Value.fromObject(target), try self.makeString(key), value, receiver });
            if (!toBoolean(r)) return false;
            // Invariants against a non-configurable own property of the target.
            if (target.properties.get(key)) |desc| {
                if (!desc.is_accessor and !desc.configurable and !desc.writable and !sameValue(value, desc.value))
                    return self.throwTypeError("proxy set cannot change the value of a non-configurable, non-writable property");
                if (desc.is_accessor and !desc.configurable and desc.set == null)
                    return self.throwTypeError("proxy set cannot succeed for a non-configurable accessor with an undefined setter");
            }
            return true;
        }
        return self.setPropertyInner(Value.fromObject(target), key, value);
    }

    /// [[Get]] on a value: walk the prototype chain; invoke getters.
    pub fn getProperty(self: *Vm, base: Value, key: []const u8) Error!Value {
        if (base.isObject()) {
            if (base.asObject().proxy_target != null) {
                return self.proxyGet(base.asObject(), key, base);
            }
        }
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
            if (base.isBoolean()) return self.getFromProto(self.boolean_proto, base, key);
            if (base.isSymbol()) return self.getFromProto(self.symbol_proto, base, key);
            if (base.isBigInt()) return self.getFromProto(self.bigint_proto, base, key);
            return Value.undefined_value;
        }
        // Mapped `arguments` exotic: mapped indices alias the parameter slots.
        if (mappedArgIndex(base.asObject(), key)) |i| {
            return base.asObject().args_env.?.slots[i];
        }
        // String wrapper exotic: indexed access reads the boxed string.
        if (arrayIndex(key)) |i| {
            if (base.asObject().properties.get(prim_key)) |d| {
                if (d.value.isString()) {
                    const su = d.value.asString().units;
                    if (i < su.len) return self.makeStringFromUtf16(su[i .. i + 1]);
                    return Value.undefined_value;
                }
            }
        }
        // Array exotic own access (length + own elements). A hole/absent index
        // falls through to the prototype chain below.
        if (base.asObject().is_array) {
            const arr = base.asObject();
            if (std.mem.eql(u8, key, "length")) return Value.fromNumber(@floatFromInt(arr.array_length));
            if (arrayIndex(key)) |i| {
                if (arrayGetOwn(arr, i)) |v| return v;
                return self.getFromProto(arr.prototype, base, key);
            }
        }
        // TypedArray exotic own access (indexed elements + view properties).
        if (base.asObject().ta) |ta| {
            if (base.asObject().is_dataview) {
                // DataView: byte-count `byteLength`, no indexed access.
                if (std.mem.eql(u8, key, "byteLength")) return Value.fromNumber(@floatFromInt(ta.length));
                if (std.mem.eql(u8, key, "byteOffset")) return Value.fromNumber(@floatFromInt(ta.offset));
                if (std.mem.eql(u8, key, "buffer")) return Value.fromObject(ta.buffer);
            } else {
                if (arrayIndex(key)) |i| {
                    if (i < ta.length) return readTypedElement(ta, i);
                    return Value.undefined_value;
                }
                if (std.mem.eql(u8, key, "length")) return Value.fromNumber(@floatFromInt(ta.length));
                if (std.mem.eql(u8, key, "byteLength")) return Value.fromNumber(@floatFromInt(ta.length * gc.bytesPerElement(ta.kind)));
                if (std.mem.eql(u8, key, "byteOffset")) return Value.fromNumber(@floatFromInt(ta.offset));
                if (std.mem.eql(u8, key, "buffer")) return Value.fromObject(ta.buffer);
            }
        }
        // ArrayBuffer byteLength.
        if (base.asObject().buffer_data) |buf| {
            if (base.asObject().ta == null and std.mem.eql(u8, key, "byteLength")) return Value.fromNumber(@floatFromInt(buf.len));
        }
        var obj: ?*gc.Object = base.asObject();
        while (obj) |o| {
            // A proxy encountered while walking the prototype chain dispatches
            // its own [[Get]], preserving the original receiver.
            if (o != base.asObject() and o.proxy_target != null) {
                return self.proxyGet(o, key, base);
            }
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
    /// Sloppy-mode [[Set]]: failures are silently ignored (native callers).
    pub fn setProperty(self: *Vm, base: Value, key: []const u8, value: Value) Error!void {
        _ = try self.setPropertyInner(base, key, value);
    }

    /// [[Set]] reporting the boolean success/refusal (for `Reflect.set`).
    pub fn setPropertyReport(self: *Vm, base: Value, key: []const u8, value: Value) Error!bool {
        return self.setPropertyInner(base, key, value);
    }

    /// Mode-aware [[Set]] for compiled code: in strict mode a failed write
    /// throws TypeError.
    pub fn setPropertyMode(self: *Vm, base: Value, key: []const u8, value: Value, strict: bool) Error!void {
        const ok = try self.setPropertyInner(base, key, value);
        if (strict and !ok) return self.throwTypeError("cannot assign to read-only property");
    }

    /// [[Set]] core: returns false when the write was refused (non-writable,
    /// setter-less accessor, non-extensible receiver, primitive receiver).
    fn setPropertyInner(self: *Vm, base: Value, key: []const u8, value: Value) Error!bool {
        if (base.isObject()) {
            if (base.asObject().proxy_target != null) {
                return self.proxySet(base.asObject(), key, value, base);
            }
        }
        if (!base.isObject()) {
            if (base.isNullish()) return self.throwTypeError("cannot set property of null or undefined");
            return false; // writes to primitives always fail
        }
        // Mapped `arguments` exotic: writes flow through to the parameter slot
        // (and fall through so the backing own property stays in sync).
        if (mappedArgIndex(base.asObject(), key)) |i| {
            base.asObject().args_env.?.slots[i] = value;
        }
        // Array exotic own writes (length + dense elements).
        if (base.asObject().is_array) {
            const arr = base.asObject();
            if (std.mem.eql(u8, key, "length")) {
                const n = try self.toNumber(value);
                const len: u32 = if (std.math.isNan(n) or n < 0) 0 else if (n > 4294967295) 4294967295 else @intFromFloat(n);
                try self.setArrayLength(arr, len);
                return true;
            }
            if (arrayIndex(key)) |i| {
                try self.setArrayElement(arr, i, value);
                return true;
            }
        }
        // TypedArray exotic indexed write (not for DataView).
        if (base.asObject().ta) |ta| {
            if (!base.asObject().is_dataview) {
                if (arrayIndex(key)) |i| {
                    if (i < ta.length) writeTypedElement(ta, i, try self.toNumber(value));
                    return true;
                }
            }
        }
        const receiver = base.asObject();
        // Search prototype chain for an accessor or a non-writable data prop.
        var obj: ?*gc.Object = receiver;
        while (obj) |o| {
            // A proxy in the prototype chain runs its own [[Set]] with the
            // original receiver.
            if (o != receiver and o.proxy_target != null) {
                return self.proxySet(o, key, value, base);
            }
            if (o.properties.getPtr(key)) |desc| {
                if (desc.is_accessor) {
                    const setter = desc.set orelse return false; // no setter
                    _ = try self.callValue(setter, base, &.{value});
                    return true;
                }
                if (o == receiver) {
                    if (!desc.writable) return false;
                    desc.value = value;
                    return true;
                }
                if (!desc.writable) return false; // inherited non-writable shadows
                break;
            }
            obj = o.prototype;
        }
        if (!receiver.extensible) return false; // refuse new props
        try self.defineData(receiver, key, value, true, true, true);
        return true;
    }

    /// Look up `key` on a prototype chain, invoking getters with `receiver` as
    /// `this`. Used for primitive (string/number) property access.
    pub fn getFromProto(self: *Vm, proto: ?*gc.Object, receiver: Value, key: []const u8) Error!Value {
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

    /// [[Delete]]: remove an own property. Returns false only when the property
    /// exists and is non-configurable (per the spec), true otherwise.
    pub fn deleteProperty(self: *Vm, base: Value, key: []const u8) Error!bool {
        if (!base.isObject()) return true;
        const o = base.asObject();
        // Proxy: dispatch to the deleteProperty trap, with the
        // non-configurable invariant.
        if (o.proxy_target) |target| {
            if (o.proxy_revoked) return self.throwTypeError("cannot perform operation on a revoked proxy");
            const handler = o.proxy_handler.?;
            if (try self.proxyTrapFn(handler, "deleteProperty")) |trap| {
                const r = try self.callValue(trap, Value.fromObject(handler), &.{ Value.fromObject(target), try self.makeString(key) });
                if (!toBoolean(r)) return false;
                // Invariants: a still-present target property may not be
                // reported deleted if it is non-configurable, or if the target
                // is non-extensible.
                if (target.properties.get(key)) |desc| {
                    if (!desc.configurable)
                        return self.throwTypeError("proxy deleteProperty cannot report a non-configurable property as deleted");
                    if (!target.extensible)
                        return self.throwTypeError("proxy deleteProperty cannot report a property of a non-extensible target as deleted");
                }
                return true;
            }
            return self.deleteProperty(Value.fromObject(target), key);
        }
        // Deleting a mapped arguments index severs the parameter alias.
        if (mappedArgIndex(o, key)) |i| {
            o.args_map &= ~(@as(u64, 1) << @intCast(i));
        }
        if (o.is_array) {
            // `length` is a non-configurable own property; deleting it fails.
            if (std.mem.eql(u8, key, "length")) return false;
            if (arrayIndex(key)) |i| {
                self.deleteArrayElement(o, i);
                return true;
            }
        }
        if (o.properties.getPtr(key)) |desc| {
            if (!desc.configurable) return false;
            if (o.properties.fetchOrderedRemove(key)) |kv| self.gpa.free(kv.key);
        }
        return true;
    }

    pub fn hasProperty(self: *Vm, obj: *gc.Object, key: []const u8) bool {
        _ = self;
        var o: ?*gc.Object = obj;
        while (o) |cur| {
            if (cur.is_array) {
                if (std.mem.eql(u8, key, "length")) return true;
                if (arrayIndex(key)) |i| {
                    if (arrayHasOwn(cur, i)) return true;
                }
            }
            if (cur.properties.contains(key)) return true;
            o = cur.prototype;
        }
        return false;
    }

    pub fn getGlobal(self: *Vm, name: []const u8, for_typeof: bool) Error!Value {
        const global = self.global_object.?;
        if (self.hasProperty(global, name)) {
            return self.getProperty(Value.fromObject(global), name);
        }
        if (for_typeof) return Value.undefined_value;
        return self.throwReferenceError(name);
    }

    pub fn instanceOf(self: *Vm, lhs: Value, rhs: Value) Error!bool {
        if (!rhs.isObject()) {
            return self.throwTypeError("right-hand side of 'instanceof' is not an object");
        }
        // A callable @@hasInstance takes precedence over OrdinaryHasInstance.
        if (self.symbol_has_instance_key.len != 0) {
            const custom = try self.getProperty(rhs, self.symbol_has_instance_key);
            if (custom.isObject() and custom.asObject().callable != null) {
                const r = try self.callValue(custom, rhs, &.{lhs});
                return toBoolean(r);
            }
        }
        // Bound functions delegate to their target.
        if (rhs.asObject().bound_target) |bt| return self.instanceOf(lhs, bt);
        if (rhs.asObject().callable == null) {
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

    /// [[HasProperty]] on a proxy (spec 10.5.7).
    fn proxyHas(self: *Vm, p: *gc.Object, key: []const u8) Error!bool {
        if (p.proxy_revoked) return self.throwTypeError("cannot perform operation on a revoked proxy");
        const handler = p.proxy_handler.?;
        const target = p.proxy_target.?;
        if (try self.proxyTrapFn(handler, "has")) |trap| {
            const r = try self.callValue(trap, Value.fromObject(handler), &.{ Value.fromObject(target), try self.makeString(key) });
            if (toBoolean(r)) return true;
            // Invariants: a non-configurable own property, or any own property
            // of a non-extensible target, may not be reported absent.
            if (target.properties.get(key)) |desc| {
                if (!desc.configurable)
                    return self.throwTypeError("proxy has cannot report a non-configurable own property as absent");
                if (!target.extensible)
                    return self.throwTypeError("proxy has cannot report a property of a non-extensible target as absent");
            }
            return false;
        }
        return self.hasPropertyChain(target, key);
    }

    /// [[HasProperty]] walking the prototype chain, dispatching any proxy found
    /// along the way (so `in` sees proxy `has` traps at every level).
    fn hasPropertyChain(self: *Vm, obj: *gc.Object, key: []const u8) Error!bool {
        var o: ?*gc.Object = obj;
        while (o) |cur| {
            if (cur.proxy_target != null) return self.proxyHas(cur, key);
            if (cur.is_array) {
                if (std.mem.eql(u8, key, "length")) return true;
                if (arrayIndex(key)) |i| {
                    if (arrayHasOwn(cur, i)) return true;
                }
            }
            if (cur.properties.contains(key)) return true;
            o = cur.prototype;
        }
        return false;
    }

    pub fn inOperator(self: *Vm, key: Value, obj: Value) Error!bool {
        if (!obj.isObject()) return self.throwTypeError("cannot use 'in' on a non-object");
        const k = try self.toPropertyKey(key);
        defer self.gpa.free(k);
        return self.hasPropertyChain(obj.asObject(), k);
    }

    pub fn toPropertyKey(self: *Vm, v: Value) Error![]u8 {
        if (v.isString()) {
            return utf16ToUtf8Alloc(self.gpa, v.asString().units);
        }
        if (v.isBigInt()) return self.bigintToStringAlloc(v.asBigInt(), 10);
        if (v.isSymbol()) {
            // Encode a symbol as a NUL-prefixed internal key (by identity), so
            // symbol-keyed properties reuse the string map but stay out of
            // string enumeration (which skips NUL-prefixed keys).
            var buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "\x00S{x}", .{@intFromPtr(v.asSymbol())}) catch unreachable;
            return self.gpa.dupe(u8, s);
        }
        var buf: [64]u8 = undefined;
        const s = self.primitiveToUtf8(v, &buf) catch "?";
        return self.gpa.dupe(u8, s);
    }

    /// ToPrimitive with a number hint: try valueOf then toString (spec 7.1.1
    /// OrdinaryToPrimitive, number-hint order).
    pub const PrimitiveHint = enum { default, number, string };

    pub fn toPrimitive(self: *Vm, v: Value) Error!Value {
        return self.toPrimitiveHint(v, .default);
    }

    pub fn toPrimitiveHint(self: *Vm, v: Value, hint: PrimitiveHint) Error!Value {
        if (!v.isObject()) return v;
        // A user-supplied @@toPrimitive takes precedence over OrdinaryToPrimitive.
        if (self.symbol_to_primitive_key.len != 0) {
            const exotic = try self.getProperty(v, self.symbol_to_primitive_key);
            if (exotic.isObject() and exotic.asObject().callable != null) {
                const hint_str = try self.makeString(switch (hint) {
                    .default => "default",
                    .number => "number",
                    .string => "string",
                });
                try self.protect(hint_str);
                defer self.unprotect();
                const result = try self.callValue(exotic, v, &.{hint_str});
                if (!result.isObject()) return result;
                return self.throwTypeError("@@toPrimitive must return a primitive");
            }
        }
        // OrdinaryToPrimitive: string hint tries toString first.
        const order: [2][]const u8 = if (hint == .string)
            .{ "toString", "valueOf" }
        else
            .{ "valueOf", "toString" };
        for (order) |method_name| {
            const method = try self.getProperty(v, method_name);
            if (method.isObject() and method.asObject().callable != null) {
                const result = try self.callValue(method, v, &.{});
                if (!result.isObject()) return result;
            }
        }
        return self.throwTypeError("cannot convert object to primitive value");
    }

    // ---- constant materialization ------------------------------------------

    pub fn materializeConst(self: *Vm, c: bc.Const) Error!Value {
        switch (c) {
            .number => |n| return Value.fromNumber(n),
            // Constant strings are interned by content (V8-style heap
            // constants): a hot `load_const` in a loop allocates once, ever.
            .string => |bytes| {
                if (self.intern.get(bytes)) |v| return v;
                const v = try self.makeString(bytes);
                const key = try self.gpa.dupe(u8, bytes);
                try self.intern.put(self.gpa, key, v);
                return v;
            },
            .bigint => |digits| {
                return (try self.parseBigIntDigits(digits)) orelse
                    self.throwSyntaxError("invalid BigInt literal");
            },
        }
    }

    pub fn makeString(self: *Vm, utf8: []const u8) Error!Value {
        self.maybeStress();
        const s = try self.heap.create(gc.String);
        s.units = std.unicode.utf8ToUtf16LeAlloc(self.gpa, utf8) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => try self.gpa.alloc(u16, 0), // cooked strings are valid UTF-8
        };
        return Value.fromString(s);
    }

    pub fn makeStringFromUtf16(self: *Vm, units: []const u16) Error!Value {
        self.maybeStress();
        const s = try self.heap.create(gc.String);
        s.units = try self.gpa.dupe(u16, units);
        return Value.fromString(s);
    }

    /// A registered symbol is one produced by `Symbol.for` (present in the
    /// global registry). Registered symbols cannot be held weakly.
    pub fn symbolIsRegistered(self: *Vm, sym: *gc.Symbol) bool {
        for (self.symbol_registry.items) |r| {
            if (r.sym == sym) return true;
        }
        return false;
    }

    /// CanBeHeldWeakly: objects always; non-registered symbols too.
    pub fn canBeHeldWeakly(self: *Vm, v: Value) bool {
        if (v.isObject()) return true;
        if (v.isSymbol()) return !self.symbolIsRegistered(v.asSymbol());
        return false;
    }

    pub fn makeSymbol(self: *Vm, description: ?[]const u8) Error!Value {
        self.maybeStress();
        const s = try self.heap.create(gc.Symbol);
        if (description) |d| {
            s.description = std.unicode.utf8ToUtf16LeAlloc(self.gpa, d) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidUtf8 => try self.gpa.alloc(u16, 0),
            };
        }
        return Value.fromSymbol(s);
    }

    // ---- coercions ---------------------------------------------------------

    pub fn toNumber(self: *Vm, v: Value) Error!f64 {
        return switch (v) {
            .undefined => std.math.nan(f64),
            .null => 0,
            .boolean => |b| if (b) 1 else 0,
            .number => |n| n,
            .string => |s| stringToNumber(s.units),
            .bigint => return self.throwTypeError("cannot convert a BigInt to a number"),
            .symbol => return self.throwTypeError("cannot convert a Symbol to a number"),
            .object => try self.toNumber(try self.toPrimitiveHint(v, .number)),
            .hole => unreachable, // holes never escape array storage
        };
    }

    pub fn toInt32(self: *Vm, v: Value) Error!i32 {
        const n = try self.toNumber(v);
        return doubleToInt32(n);
    }
    pub fn toUint32(self: *Vm, v: Value) Error!u32 {
        const n = try self.toNumber(v);
        return @bitCast(doubleToInt32(n));
    }

    pub fn opAdd(self: *Vm, l: Value, r: Value) Error!Value {
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
        if (lp.isBigInt() or rp.isBigInt()) {
            if (!lp.isBigInt() or !rp.isBigInt()) {
                return self.throwTypeError("cannot mix BigInt and other types, use explicit conversions");
            }
            return self.bigintBinop(.add, lp.asBigInt(), rp.asBigInt());
        }
        return Value.fromNumber((try self.toNumber(lp)) + (try self.toNumber(rp)));
    }

    // ---- BigInt arithmetic ---------------------------------------------------

    pub const NumOp = enum { add, sub, mul, div, mod, exp, bit_and, bit_or, bit_xor, shl, shr, ushr };

    /// Allocate a BigInt heap cell holding a copy of `c` (zero -> empty limbs).
    pub fn makeBigIntConst(self: *Vm, c: std.math.big.int.Const) Error!Value {
        self.maybeStress();
        const cell = try self.heap.create(gc.BigInt);
        if (!c.eqlZero()) {
            cell.limbs = try self.gpa.dupe(std.math.big.Limb, c.limbs);
            cell.positive = c.positive;
        }
        return Value.fromBigInt(cell);
    }

    /// Consume a Managed (deinits it) into a heap BigInt value.
    fn makeBigIntManaged(self: *Vm, m: *std.math.big.int.Managed) Error!Value {
        defer m.deinit();
        return self.makeBigIntConst(m.toConst());
    }

    /// Parse BigInt literal/StringToBigInt text (0x/0o/0b prefixes, no sign
    /// for literals; StringToBigInt callers pre-trim and pass signs through).
    pub fn parseBigIntDigits(self: *Vm, digits: []const u8) Error!?Value {
        var s = digits;
        var negative = false;
        if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
            negative = s[0] == '-';
            s = s[1..];
        }
        var base: u8 = 10;
        if (s.len > 2 and s[0] == '0') {
            switch (s[1]) {
                'x', 'X' => {
                    base = 16;
                    s = s[2..];
                },
                'o', 'O' => {
                    base = 8;
                    s = s[2..];
                },
                'b', 'B' => {
                    base = 2;
                    s = s[2..];
                },
                else => {},
            }
        }
        if (s.len == 0) return null;
        var m = std.math.big.int.Managed.init(self.gpa) catch return error.OutOfMemory;
        m.setString(base, s) catch |e| switch (e) {
            error.OutOfMemory => {
                m.deinit();
                return error.OutOfMemory;
            },
            else => {
                m.deinit();
                return null;
            },
        };
        if (negative) m.negate();
        return try self.makeBigIntManaged(&m);
    }

    /// Numeric binary operator with BigInt dispatch: both-BigInt operands use
    /// arbitrary-precision arithmetic, both-Number uses f64, mixing throws.
    fn numericBinop(self: *Vm, comptime op: NumOp, lv: Value, rv: Value) Error!Value {
        const lp = try self.toPrimitiveHint(lv, .number);
        try self.protect(lp);
        defer self.unprotect();
        const rp = try self.toPrimitiveHint(rv, .number);
        try self.protect(rp);
        defer self.unprotect();
        if (lp.isBigInt() or rp.isBigInt()) {
            if (!lp.isBigInt() or !rp.isBigInt()) {
                return self.throwTypeError("cannot mix BigInt and other types, use explicit conversions");
            }
            return self.bigintBinop(op, lp.asBigInt(), rp.asBigInt());
        }
        return switch (op) {
            .add => Value.fromNumber((try self.toNumber(lp)) + (try self.toNumber(rp))),
            .sub => Value.fromNumber((try self.toNumber(lp)) - (try self.toNumber(rp))),
            .mul => Value.fromNumber((try self.toNumber(lp)) * (try self.toNumber(rp))),
            .div => Value.fromNumber((try self.toNumber(lp)) / (try self.toNumber(rp))),
            .mod => Value.fromNumber(jsMod(try self.toNumber(lp), try self.toNumber(rp))),
            .exp => Value.fromNumber(jsPow(try self.toNumber(lp), try self.toNumber(rp))),
            .bit_and => Value.fromNumber(@floatFromInt((try self.toInt32(lp)) & (try self.toInt32(rp)))),
            .bit_or => Value.fromNumber(@floatFromInt((try self.toInt32(lp)) | (try self.toInt32(rp)))),
            .bit_xor => Value.fromNumber(@floatFromInt((try self.toInt32(lp)) ^ (try self.toInt32(rp)))),
            .shl => Value.fromNumber(@floatFromInt(jsShl(try self.toInt32(lp), try self.toUint32(rp)))),
            .shr => Value.fromNumber(@floatFromInt(jsShr(try self.toInt32(lp), try self.toUint32(rp)))),
            .ushr => Value.fromNumber(@floatFromInt(jsUshr(try self.toInt32(lp), try self.toUint32(rp)))),
        };
    }

    fn bigintShiftCount(self: *Vm, b: std.math.big.int.Const) Error!usize {
        // Cap shifts to keep pathological programs from OOMing the heap.
        const max_shift: usize = 1 << 26;
        if (b.limbs.len > 1) return self.throwRangeError("BigInt shift count too large");
        const n: usize = @intCast(b.limbs[0]);
        if (n > max_shift) return self.throwRangeError("BigInt shift count too large");
        return n;
    }

    fn bigintBinop(self: *Vm, op: NumOp, a: *gc.BigInt, b: *gc.BigInt) Error!Value {
        const Managed = std.math.big.int.Managed;
        const ac = a.toConst();
        const bcst = b.toConst();
        var ma = Managed.init(self.gpa) catch return error.OutOfMemory;
        defer ma.deinit();
        ma.copy(ac) catch return error.OutOfMemory;
        var mb = Managed.init(self.gpa) catch return error.OutOfMemory;
        defer mb.deinit();
        mb.copy(bcst) catch return error.OutOfMemory;
        var r = Managed.init(self.gpa) catch return error.OutOfMemory;
        errdefer r.deinit();

        switch (op) {
            .add => r.add(&ma, &mb) catch return error.OutOfMemory,
            .sub => r.sub(&ma, &mb) catch return error.OutOfMemory,
            .mul => r.mul(&ma, &mb) catch return error.OutOfMemory,
            .div, .mod => {
                if (bcst.eqlZero()) return self.throwRangeError("division by zero");
                var rem = Managed.init(self.gpa) catch return error.OutOfMemory;
                defer rem.deinit();
                r.divTrunc(&rem, &ma, &mb) catch return error.OutOfMemory;
                if (op == .mod) r.swap(&rem);
            },
            .exp => {
                if (!bcst.positive and !bcst.eqlZero()) return self.throwRangeError("BigInt exponent must be non-negative");
                if (bcst.limbs.len > 1 or bcst.limbs[0] > std.math.maxInt(u32)) {
                    return self.throwRangeError("BigInt exponent too large");
                }
                const e: u32 = @intCast(bcst.limbs[0]);
                r.pow(&ma, e) catch return error.OutOfMemory;
            },
            .bit_and => r.bitAnd(&ma, &mb) catch return error.OutOfMemory,
            .bit_or => r.bitOr(&ma, &mb) catch return error.OutOfMemory,
            .bit_xor => r.bitXor(&ma, &mb) catch return error.OutOfMemory,
            .shl, .shr => {
                // A negative count shifts the other way.
                const left = (op == .shl) == bcst.positive;
                var abs_bc = bcst;
                abs_bc.positive = true;
                const n = try self.bigintShiftCount(abs_bc);
                if (left) {
                    r.shiftLeft(&ma, n) catch return error.OutOfMemory;
                } else {
                    r.shiftRight(&ma, n) catch return error.OutOfMemory;
                }
            },
            .ushr => return self.throwTypeError("BigInts have no unsigned right shift"),
        }
        return self.makeBigIntManaged(&r);
    }

    fn opNegate(self: *Vm, v: Value) Error!Value {
        const p = try self.toPrimitiveHint(v, .number);
        if (p.isBigInt()) {
            var c = p.asBigInt().toConst();
            c.positive = !c.positive or c.eqlZero();
            return self.makeBigIntConst(c);
        }
        return Value.fromNumber(-(try self.toNumber(p)));
    }

    fn opBitNot(self: *Vm, v: Value) Error!Value {
        const p = try self.toPrimitiveHint(v, .number);
        if (p.isBigInt()) {
            // ~a == -(a + 1)
            const Managed = std.math.big.int.Managed;
            var ma = Managed.init(self.gpa) catch return error.OutOfMemory;
            defer ma.deinit();
            ma.copy(p.asBigInt().toConst()) catch return error.OutOfMemory;
            var one = Managed.initSet(self.gpa, 1) catch return error.OutOfMemory;
            defer one.deinit();
            var r = Managed.init(self.gpa) catch return error.OutOfMemory;
            r.add(&ma, &one) catch {
                r.deinit();
                return error.OutOfMemory;
            };
            r.negate();
            return self.makeBigIntManaged(&r);
        }
        return Value.fromNumber(@floatFromInt(~(try self.toInt32(p))));
    }

    /// Lossy Number(bigint) conversion (round-to-nearest f64).
    pub fn bigintToF64(b: *const gc.BigInt) f64 {
        const res = b.toConst().toFloat(f64, .nearest_even);
        return res[0];
    }

    pub fn concat(self: *Vm, a: []const u16, b: []const u16) Error!Value {
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
    pub fn toStringVal(self: *Vm, v: Value) Error!Value {
        const p = if (v.isObject()) try self.toPrimitiveHint(v, .string) else v;
        if (p.isString()) return p;
        if (p.isBigInt()) {
            const s = try self.bigintToStringAlloc(p.asBigInt(), 10);
            defer self.gpa.free(s);
            return self.makeString(s);
        }
        var buf: [64]u8 = undefined;
        const utf8 = self.primitiveToUtf8(p, &buf) catch "?";
        return self.makeString(utf8);
    }

    /// Decimal (or radix) text of a BigInt; caller frees.
    pub fn bigintToStringAlloc(self: *Vm, b: *const gc.BigInt, base: u8) Error![]u8 {
        return b.toConst().toStringAlloc(self.gpa, base, .lower) catch return error.OutOfMemory;
    }

    pub fn primitiveToUtf8(self: *Vm, v: Value, buf: []u8) ![]const u8 {
        _ = self;
        return switch (v) {
            .undefined => "undefined",
            .null => "null",
            .boolean => |b| if (b) "true" else "false",
            .number => |n| numberToString(n, buf),
            // Fixed-buffer callers only; big values overflow -> error ("?").
            .bigint => |b| blk: {
                var scratch: [128]std.math.big.Limb = undefined;
                const c = b.toConst();
                if (c.limbs.len > 8) break :blk error.NoSpaceLeft;
                const len = c.toString(buf, 10, .lower, &scratch);
                break :blk buf[0..len];
            },
            .object => "[object Object]",
            .symbol => "Symbol()",
            .string => "", // handled by caller
            .hole => unreachable,
        };
    }

    pub fn typeOf(self: *Vm, v: Value) Error!Value {
        const name: []const u8 = switch (v) {
            .undefined => "undefined",
            .null => "object",
            .boolean => "boolean",
            .number => "number",
            .string => "string",
            .symbol => "symbol",
            .bigint => "bigint",
            .object => |o| if (o.callable != null) "function" else "object",
            .hole => unreachable,
        };
        return self.makeString(name);
    }

    // ---- equality & comparison ---------------------------------------------

    pub fn strictEquals(self: *const Vm, a: Value, b: Value) bool {
        _ = self;
        return sameTypeStrictEq(a, b);
    }

    pub fn looseEquals(self: *Vm, a: Value, b: Value) Error!bool {
        // Same-type: strict semantics.
        if (@intFromEnum(std.meta.activeTag(a)) == @intFromEnum(std.meta.activeTag(b))) {
            return sameTypeStrictEq(a, b);
        }
        // null == undefined.
        if (a.isNullish() and b.isNullish()) return true;
        if (a.isNullish() or b.isNullish()) return false;
        // BigInt vs anything else: mathematical equality.
        if (a.isBigInt() or b.isBigInt()) {
            const bi = if (a.isBigInt()) a.asBigInt() else b.asBigInt();
            const other = if (a.isBigInt()) b else a;
            return self.bigintLooseEq(bi, other);
        }
        // number/string coercion; boolean coerces to number; others -> number.
        const an = try self.toNumber(a);
        const bn = try self.toNumber(b);
        return an == bn;
    }

    /// BigInt == non-BigInt (spec 7.2.13 steps 6-9): strings go through
    /// StringToBigInt; numbers/booleans compare mathematically; objects
    /// re-enter loose equality after ToPrimitive.
    fn bigintLooseEq(self: *Vm, bi: *gc.BigInt, other: Value) Error!bool {
        if (other.isString()) {
            const utf8 = try utf16ToUtf8Alloc(self.gpa, other.asString().units);
            defer self.gpa.free(utf8);
            const trimmed = std.mem.trim(u8, utf8, " \t\n\r");
            if (trimmed.len == 0) return bi.toConst().eqlZero();
            const parsed = (try self.parseBigIntDigits(trimmed)) orelse return false;
            return bi.toConst().order(parsed.asBigInt().toConst()) == .eq;
        }
        if (other.isObject()) {
            const p = try self.toPrimitive(other);
            return self.looseEquals(Value.fromBigInt(bi), p);
        }
        const n: f64 = if (other.isBoolean()) (if (other.asBool()) 1 else 0) else if (other.isNumber()) other.asNumber() else return false;
        if (!std.math.isFinite(n) or n != std.math.trunc(n)) return false;
        // A BigInt not exactly representable as f64 cannot equal any f64.
        const conv = bi.toConst().toFloat(f64, .nearest_even);
        return conv[1] == .exact and conv[0] == n;
    }

    const Cmp = enum { lt, le, gt, ge };

    pub fn compare(self: *Vm, a: Value, b: Value, op: Cmp) Error!bool {
        if (a.isString() and b.isString()) {
            const order = compareUtf16(a.asString().units, b.asString().units);
            return switch (op) {
                .lt => order < 0,
                .le => order <= 0,
                .gt => order > 0,
                .ge => order >= 0,
            };
        }
        if (a.isBigInt() or b.isBigInt()) {
            const ord: std.math.Order = blk: {
                if (a.isBigInt() and b.isBigInt()) break :blk a.asBigInt().toConst().order(b.asBigInt().toConst());
                // Mixed: compare through f64 (lossy above 2^53; adequate).
                const af: f64 = if (a.isBigInt()) bigintToF64(a.asBigInt()) else try self.toNumber(a);
                const bf: f64 = if (b.isBigInt()) bigintToF64(b.asBigInt()) else try self.toNumber(b);
                if (std.math.isNan(af) or std.math.isNan(bf)) return false;
                break :blk std.math.order(af, bf);
            };
            return switch (op) {
                .lt => ord == .lt,
                .le => ord != .gt,
                .gt => ord == .gt,
                .ge => ord != .lt,
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
    pub fn throwError(self: *Vm, proto: ?*gc.Object, msg: []const u8) Error {
        const obj = self.makeError(proto, msg) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.JsThrow,
        };
        self.pending_exception = Value.fromObject(obj);
        return error.JsThrow;
    }
    pub fn throwTypeError(self: *Vm, msg: []const u8) Error {
        return self.throwError(self.type_error_proto, msg);
    }
    pub fn throwRangeError(self: *Vm, msg: []const u8) Error {
        return self.throwError(self.range_error_proto, msg);
    }
    pub fn throwReferenceError(self: *Vm, msg: []const u8) Error {
        return self.throwError(self.reference_error_proto, msg);
    }
    pub fn throwSyntaxError(self: *Vm, msg: []const u8) Error {
        return self.throwError(self.syntax_error_proto, msg);
    }

    // ---- JSON --------------------------------------------------------------

    /// Serialize `value` to compact JSON, appending to `out`. Returns false if
    /// the value has no JSON representation (undefined/function/symbol) and
    /// should be omitted. `stack` detects cycles. Indentation (`space`) is not
    /// yet supported.
    pub const JsonCtx = struct {
        out: *std.ArrayList(u8),
        stack: *std.ArrayList(*gc.Object),
        indent: *std.ArrayList(u8),
        gap: []const u8,
        replacer: Value, // callable, or undefined
        keys_filter: ?[]const []const u8, // allowed keys (array replacer)
    };

    /// SerializeJSONProperty: read holder[key], apply toJSON + replacer, emit.
    pub fn jsonSerializeProperty(self: *Vm, ctx: JsonCtx, holder: Value, key: []const u8) Error!bool {
        var value = try self.getProperty(holder, key);
        if (value.isObject()) {
            const to_json = try self.getProperty(value, "toJSON");
            if (isCallable(to_json)) {
                const ks = try self.makeString(key);
                try self.protect(ks);
                defer self.unprotect();
                value = try self.callValue(to_json, value, &.{ks});
            }
        }
        if (isCallable(ctx.replacer)) {
            const ks = try self.makeString(key);
            try self.protect(ks);
            defer self.unprotect();
            value = try self.callValue(ctx.replacer, holder, &.{ ks, value });
        }
        return self.jsonSerializeValue(ctx, value);
    }

    pub fn jsonSerializeValue(self: *Vm, ctx: JsonCtx, value: Value) Error!bool {
        switch (value) {
            .undefined, .symbol => return false,
            .null => try ctx.out.appendSlice(self.gpa, "null"),
            .boolean => |b| try ctx.out.appendSlice(self.gpa, if (b) "true" else "false"),
            .number => |n| {
                if (std.math.isNan(n) or std.math.isInf(n)) {
                    try ctx.out.appendSlice(self.gpa, "null");
                } else {
                    var buf: [64]u8 = undefined;
                    try ctx.out.appendSlice(self.gpa, numberToString(n, &buf));
                }
            },
            .bigint => return self.throwTypeError("Do not know how to serialize a BigInt"),
            .string => |s| try self.jsonQuote(ctx.out, s.units),
            .object => |o| {
                if (o.callable != null) return false; // functions omitted
                for (ctx.stack.items) |st| {
                    if (st == o) return self.throwTypeError("Converting circular structure to JSON");
                }
                try ctx.stack.append(self.gpa, o);
                defer _ = ctx.stack.pop();
                if (o.is_array) try self.jsonArray(ctx, o) else try self.jsonObject(ctx, value, o);
            },
            .hole => unreachable,
        }
        return true;
    }

    pub fn newlineIndent(self: *Vm, ctx: JsonCtx, to_len: usize) Error!void {
        if (ctx.gap.len == 0) return;
        try ctx.out.append(self.gpa, '\n');
        try ctx.out.appendSlice(self.gpa, ctx.indent.items[0..to_len]);
    }

    pub fn jsonArray(self: *Vm, ctx: JsonCtx, o: *gc.Object) Error!void {
        try ctx.out.append(self.gpa, '[');
        const prev = ctx.indent.items.len;
        try ctx.indent.appendSlice(self.gpa, ctx.gap);
        const n = o.array_length; // holes/undefined serialize as "null"
        var i: usize = 0;
        while (i < n) : (i += 1) {
            try self.checkBudget();
            if (i > 0) try ctx.out.append(self.gpa, ',');
            try self.newlineIndent(ctx, ctx.indent.items.len);
            var kbuf: [24]u8 = undefined;
            const ks = std.fmt.bufPrint(&kbuf, "{d}", .{i}) catch unreachable;
            if (!try self.jsonSerializeProperty(ctx, Value.fromObject(o), ks)) try ctx.out.appendSlice(self.gpa, "null");
        }
        if (n > 0) try self.newlineIndent(ctx, prev);
        ctx.indent.shrinkRetainingCapacity(prev);
        try ctx.out.append(self.gpa, ']');
    }

    pub fn jsonObject(self: *Vm, ctx: JsonCtx, holder: Value, o: *gc.Object) Error!void {
        try ctx.out.append(self.gpa, '{');
        const prev = ctx.indent.items.len;
        try ctx.indent.appendSlice(self.gpa, ctx.gap);

        var owned: std.ArrayList([]const u8) = .empty;
        defer {
            for (owned.items) |k| self.gpa.free(k);
            owned.deinit(self.gpa);
        }
        var key_list: []const []const u8 = undefined;
        if (ctx.keys_filter) |kf| {
            key_list = kf;
        } else {
            try ownEnumerableKeys(self, o, &owned);
            key_list = owned.items;
        }

        var first = true;
        for (key_list) |k| {
            const mark = ctx.out.items.len;
            if (!first) try ctx.out.append(self.gpa, ',');
            try self.newlineIndent(ctx, ctx.indent.items.len);
            try self.jsonQuoteBytes(ctx.out, k);
            try ctx.out.append(self.gpa, ':');
            if (ctx.gap.len > 0) try ctx.out.append(self.gpa, ' ');
            if (try self.jsonSerializeProperty(ctx, holder, k)) {
                first = false;
            } else {
                ctx.out.shrinkRetainingCapacity(mark); // omit this key
            }
        }
        if (!first) try self.newlineIndent(ctx, prev);
        ctx.indent.shrinkRetainingCapacity(prev);
        try ctx.out.append(self.gpa, '}');
    }

    pub fn jsonQuote(self: *Vm, out: *std.ArrayList(u8), units: []const u16) Error!void {
        try out.append(self.gpa, '"');
        for (units) |u| try appendJsonChar(self.gpa, out, u);
        try out.append(self.gpa, '"');
    }
    pub fn jsonQuoteBytes(self: *Vm, out: *std.ArrayList(u8), bytes: []const u8) Error!void {
        try out.append(self.gpa, '"');
        for (bytes) |b| try appendJsonChar(self.gpa, out, b);
        try out.append(self.gpa, '"');
    }

    pub fn jsonParse(self: *Vm, text: []const u8, reviver: Value) Error!Value {
        var p = JsonParser{ .vm = self, .s = text, .i = 0 };
        p.skipWs();
        const v = try p.parseValue();
        p.skipWs();
        if (p.i != text.len) return self.throwSyntaxError("Unexpected non-whitespace character after JSON");
        if (!isCallable(reviver)) return v;
        // InternalizeJSONProperty over a {"": v} holder.
        const holder = try self.newObject(self.object_proto);
        try self.protect(Value.fromObject(holder));
        defer self.unprotect();
        try self.defineData(holder, "", v, true, true, true);
        return self.internalizeJSON(Value.fromObject(holder), "", reviver);
    }

    pub fn internalizeJSON(self: *Vm, holder: Value, key: []const u8, reviver: Value) Error!Value {
        const val = try self.getProperty(holder, key);
        if (val.isObject()) {
            const o = val.asObject();
            if (o.is_array) {
                var i: u32 = 0;
                while (i < o.array_length) : (i += 1) {
                    try self.checkBudget();
                    var kbuf: [24]u8 = undefined;
                    const ks = std.fmt.bufPrint(&kbuf, "{d}", .{i}) catch unreachable;
                    try self.setArrayElement(o, i, try self.internalizeJSON(val, ks, reviver));
                }
            } else {
                var keys: std.ArrayList([]const u8) = .empty;
                defer {
                    for (keys.items) |k| self.gpa.free(k);
                    keys.deinit(self.gpa);
                }
                try ownEnumerableKeys(self, o, &keys);
                for (keys.items) |k| {
                    const new_elem = try self.internalizeJSON(val, k, reviver);
                    if (new_elem.isUndefined()) {
                        if (o.properties.fetchOrderedRemove(k)) |kv| self.gpa.free(kv.key);
                    } else {
                        try self.setProperty(val, k, new_elem);
                    }
                }
            }
        }
        const ks = try self.makeString(key);
        try self.protect(ks);
        defer self.unprotect();
        return self.callValue(reviver, holder, &.{ ks, val });
    }
};
