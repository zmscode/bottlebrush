//! Phase 0 garbage collector: a precise, stop-the-world mark-sweep heap.
//!
//! Design notes (see ../phase/phase-0/plan.md §3):
//!   * Every heap object begins with a `GcHeader` (its first field), linked
//!     into an intrusive list of all live cells for sweeping.
//!   * Each cell type exposes `trace(self, *Tracer)` to mark its children.
//!     Phase 0 cells have no children, so these are no-ops for now.
//!   * `collect` takes a *root provider* (anything with `markRoots(*Tracer)`),
//!     so this file never needs to know about `Value`, `HandleScope`, or the
//!     VM — that keeps the dependency graph one-directional.
//!   * `stress` requests a collection at every allocation safe-point; the VM
//!     will honor it in Phase 2. It is the project's best use-after-GC catcher.
//!
//! This is deliberately the simplest correct collector: non-moving, no
//! generations, no compaction. The `trace`/root interface is what stays stable
//! when Phase 7 swaps in a generational GC.

const std = @import("std");
// Mutual import with value.zig: value references cell pointers, and cells
// (Environment/Closure) reference `Value`. This is cycle-free at the type level
// because all references are pointers/slices — no struct-size loop.
const Value = @import("value.zig").Value;
// bilby is a leaf dependency (no back-reference to bottlebrush); a RegExp object
// owns a heap-allocated compiled `bilby.Regex`, freed in `deinitCell`.
const bilby = @import("bilby");

pub const Kind = enum(u8) {
    string,
    object,
    symbol,
    bigint,
    environment,
    closure,
};

/// Header prepended (as the first field) to every GC-managed cell.
pub const GcHeader = struct {
    kind: Kind,
    marked: bool = false,
    /// Intrusive link through the heap's list of all live cells.
    next: ?*GcHeader = null,
    /// Intrusive link through the collector's gray stack (the mark worklist).
    /// Meaningful only while the cell is gray — between `Tracer.mark` pushing
    /// it and `Tracer.drain` popping it. `marked` guards the push, so a cell is
    /// on the stack at most once and this link is never overwritten in place.
    gray: ?*GcHeader = null,
};

// ---- Cell types ------------------------------------------------------------
// Phase 0 keeps these minimal: enough for `Value` to point at and for the GC
// machinery to be exercised end-to-end. The real object model (properties,
// prototype chain) arrives in Phase 3; ropes/interning in Phase 7.

pub const String = struct {
    pub const gc_kind: Kind = .string;
    gc: GcHeader,
    /// WTF-16 code units. Latin-1 fast path and ropes are a Phase 7 concern.
    units: []u16 = &.{},

    pub fn trace(_: *String, _: *Tracer) void {}
};

/// A property descriptor (data or accessor). Absent accessor fields default to
/// null; `is_accessor` selects between the data (`value`/`writable`) and
/// accessor (`get`/`set`) shapes.
pub const PropertyDescriptor = struct {
    value: Value = Value.undefined_value,
    get: ?Value = null,
    set: ?Value = null,
    writable: bool = true,
    enumerable: bool = true,
    configurable: bool = true,
    is_accessor: bool = false,
};

/// Ordered map of own properties (insertion order drives enumeration). Keys are
/// UTF-8, owned by the object and freed in `deinitCell`. Symbol keys are a
/// later addition.
pub const PropertyMap = std.StringArrayHashMapUnmanaged(PropertyDescriptor);

pub const Collection = enum { none, map, set, weak_map, weak_set };

/// Typed-array element kinds.
pub const TAKind = enum { i8, u8, u8c, i16, u16, i32, u32, f32, f64 };

pub fn bytesPerElement(k: TAKind) u32 {
    return switch (k) {
        .i8, .u8, .u8c => 1,
        .i16, .u16 => 2,
        .i32, .u32, .f32 => 4,
        .f64 => 8,
    };
}

/// The saved, resumable state of a generator activation.
pub const GeneratorState = struct {
    code: *const anyopaque, // *const bytecode.CodeBlock
    env: *Environment,
    regs: []Value,
    this_value: Value,
    pc: u32 = 0,
    status: enum(u8) { start, suspended, executing, completed } = .start,
};

/// A promise's internal state (spec 27.2): status, settled value/reason, and
/// the reactions registered while pending. Heap-owned by its promise object.
pub const PromiseState = struct {
    status: enum(u8) { pending, fulfilled, rejected } = .pending,
    /// The fulfillment value or rejection reason once settled.
    value: Value = Value.undefined_value,
    reactions: std.ArrayList(PromiseReaction) = .empty,
};

/// One registered reaction: the handler to call with the settled value (or
/// `undefined` for pass-through), and the capability functions its result
/// settles (both `undefined` for internal capability-less reactions — an
/// async function's Await).
pub const PromiseReaction = struct {
    handler: Value,
    cap_resolve: Value,
    cap_reject: Value,
    on_fulfill: bool,
};

/// A typed-array view over an ArrayBuffer.
pub const TypedArrayView = struct {
    buffer: *Object, // the backing ArrayBuffer object
    offset: u32, // byte offset into the buffer
    length: u32, // element count
    kind: TAKind,
};

pub const Object = struct {
    pub const gc_kind: Kind = .object;
    gc: GcHeader,
    /// [[Prototype]] — the prototype chain link.
    prototype: ?*Object = null,
    /// Own properties, in insertion order.
    properties: PropertyMap = .empty,
    /// [[Call]] blueprint when this object is a function; null otherwise.
    callable: ?*Closure = null,
    /// [[Extensible]].
    extensible: bool = true,
    /// Array exotic: when true, this is an Array. Indexed elements live either
    /// in the dense `elements` store (fast mode, holes marked with `Value.hole`)
    /// or, once too sparse, in `array_dict` (dictionary mode). `array_length` is
    /// the logical `.length`, independent of the backing store's size.
    is_array: bool = false,
    array_length: u32 = 0,
    /// Dictionary (slow) element store for sparse arrays. Populated when a write
    /// would leave too large a gap in the dense store; `elements` is then empty.
    array_dict: std.AutoHashMapUnmanaged(u32, Value) = .empty,
    dictionary_mode: bool = false,
    /// Collection kind: Map stores interleaved key/value pairs in `elements`,
    /// Set stores values in `elements`.
    collection: Collection = .none,
    /// Dense element store: array elements, or Map/Set entries.
    elements: std.ArrayList(Value) = .empty,
    /// ArrayBuffer backing bytes (owned); null for non-buffers.
    buffer_data: ?[]u8 = null,
    /// TypedArray view metadata; null for non-typed-arrays. Also used by
    /// DataView (with `is_dataview` set), where `ta.length` is a byte count.
    ta: ?TypedArrayView = null,
    is_dataview: bool = false,
    /// Proxy exotic: when set, fundamental operations dispatch to trap functions
    /// on `proxy_handler`, with `proxy_target` as the underlying object.
    proxy_target: ?*Object = null,
    /// Revoked proxies keep their identity but every operation throws.
    proxy_revoked: bool = false,
    proxy_handler: ?*Object = null,
    /// Generator activation state (heap-owned); null for non-generators.
    generator: ?*GeneratorState = null,
    /// Promise internal state (heap-owned); null for non-promises.
    promise: ?*PromiseState = null,
    /// Bound-function exotic: when set, [[Call]]/[[Construct]] forward to
    /// `bound_target` with `bound_this` prepended to the bound args (which live
    /// in `elements`).
    bound_target: ?Value = null,
    bound_this: Value = Value.undefined_value,
    /// RegExp exotic: the compiled matcher (heap-owned); null for non-regexps.
    regex: ?*bilby.Regex = null,
    /// Mapped `arguments` exotic: the frame environment whose parameter slots
    /// alias this object's indices, and a bitmask of still-mapped indices
    /// (bit i => index i aliases env slot i; capped at 64 parameters).
    args_env: ?*Environment = null,
    args_map: u64 = 0,
    /// WeakRef exotic: the referent (an object or non-registered symbol, held
    /// weakly; set to `.hole` once dead — deref then returns undefined).
    weak_target: ?Value = null,

    pub fn trace(self: *Object, t: *Tracer) void {
        if (self.prototype) |p| t.mark(&p.gc);
        if (self.callable) |c| t.mark(&c.gc);
        var it = self.properties.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.value.mark(t);
            if (entry.value_ptr.get) |g| g.mark(t);
            if (entry.value_ptr.set) |s| s.mark(t);
        }
        // Weak collections hold their entries weakly: the collector's
        // ephemeron pass (Heap.collect) decides what survives.
        if (self.collection != .weak_map and self.collection != .weak_set) {
            for (self.elements.items) |v| v.mark(t);
        }
        if (self.dictionary_mode) {
            var dit = self.array_dict.valueIterator();
            while (dit.next()) |v| v.mark(t);
        }
        if (self.ta) |ta| t.mark(&ta.buffer.gc);
        if (self.proxy_target) |p| t.mark(&p.gc);
        if (self.proxy_handler) |h| t.mark(&h.gc);
        if (self.generator) |g| {
            t.mark(&g.env.gc);
            g.this_value.mark(t);
            for (g.regs) |v| v.mark(t);
        }
        if (self.promise) |p| {
            p.value.mark(t);
            for (p.reactions.items) |r| {
                r.handler.mark(t);
                r.cap_resolve.mark(t);
                r.cap_reject.mark(t);
            }
        }
        if (self.bound_target) |bt| bt.mark(t);
        self.bound_this.mark(t);
        if (self.args_env) |e| t.mark(&e.gc);
    }

    pub fn deinitCell(self: *Object, gpa: std.mem.Allocator) void {
        for (self.properties.keys()) |k| gpa.free(k);
        self.properties.deinit(gpa);
        self.elements.deinit(gpa);
        self.array_dict.deinit(gpa);
        if (self.buffer_data) |b| gpa.free(b);
        if (self.generator) |g| {
            gpa.free(g.regs);
            gpa.destroy(g);
        }
        if (self.promise) |p| {
            p.reactions.deinit(gpa);
            gpa.destroy(p);
        }
        if (self.regex) |re| {
            re.deinit(gpa);
            gpa.destroy(re);
        }
    }
};

/// The engine-wide error set (used by the interpreter and native functions).
/// `JsThrow` means a JS exception is pending in the VM; the others are host
/// failures.
pub const VmError = error{ JsThrow, OutOfMemory, StackOverflow, Timeout };

/// A built-in function implemented in Zig. `ctx` is the `*Vm` (opaque here to
/// avoid a gc→interpreter import cycle); the callee casts it back.
pub const NativeFn = *const fn (ctx: *anyopaque, this: Value, args: []const Value) VmError!Value;

/// A function activation blueprint: either compiled bytecode plus a captured
/// environment, or a native Zig function. `code` is an opaque
/// `*const bytecode.CodeBlock` (kept opaque to avoid a gc→bytecode→value import
/// cycle); the interpreter casts it back.
pub const Closure = struct {
    pub const gc_kind: Kind = .closure;
    gc: GcHeader,
    /// `*const bytecode.CodeBlock` (opaque here). Unused for native functions.
    code: *const anyopaque = undefined,
    env: ?*Environment = null,
    /// Non-null for built-ins; when set, the interpreter dispatches here
    /// instead of running bytecode.
    native: ?NativeFn = null,
    /// Whether this function implements [[Construct]] (is `new`-able). User
    /// function declarations/expressions are constructors; generators, arrows,
    /// and most built-in functions are not.
    constructor: bool = false,
    /// Arrow functions capture the `this` of their creation site (lexical
    /// `this`); null for ordinary functions, whose `this` is the call receiver.
    captured_this: ?Value = null,

    pub fn trace(self: *Closure, t: *Tracer) void {
        if (self.env) |e| t.mark(&e.gc);
        if (self.captured_this) |v| v.mark(t);
    }
};

/// A declarative environment record: a flat array of variable slots plus a
/// parent link. Identifiers are resolved at compile time to (depth, slot).
pub const Environment = struct {
    pub const gc_kind: Kind = .environment;
    gc: GcHeader,
    parent: ?*Environment = null,
    slots: []Value = &.{},

    pub fn trace(self: *Environment, t: *Tracer) void {
        if (self.parent) |p| t.mark(&p.gc);
        for (self.slots) |v| v.mark(t);
    }

    pub fn deinitCell(self: *Environment, gpa: std.mem.Allocator) void {
        if (self.slots.len != 0) gpa.free(self.slots);
    }
};

pub const Symbol = struct {
    pub const gc_kind: Kind = .symbol;
    gc: GcHeader,
    description: ?[]u16 = null,

    pub fn trace(_: *Symbol, _: *Tracer) void {}
};

pub const BigInt = struct {
    pub const gc_kind: Kind = .bigint;
    gc: GcHeader,
    /// Arbitrary-precision magnitude (std.math.big little-endian limbs; owned).
    limbs: []std.math.big.Limb = &.{},
    positive: bool = true,

    pub fn trace(_: *BigInt, _: *Tracer) void {}

    pub fn toConst(self: *const BigInt) std.math.big.int.Const {
        if (self.limbs.len == 0) {
            // Zero: a Const must have at least one limb.
            return .{ .limbs = &[_]std.math.big.Limb{0}, .positive = true };
        }
        return .{ .limbs = self.limbs, .positive = self.positive };
    }
};

// ---- Tracer ----------------------------------------------------------------

/// Marks reachable cells during the mark phase. Root providers and cell
/// `trace` methods drive marking through `mark`.
///
/// Marking is **iterative, not recursive**. `mark` only colours a cell and
/// pushes it onto a gray stack; `drain` pops and traces until the stack is
/// empty. Recursing over the object graph would put its depth on the native
/// stack, and that depth is chosen by the program under test: a long linked
/// list, prototype chain or scope chain is ordinary JavaScript, and a few
/// hundred thousand links used to segfault the collector.
///
/// The gray stack is threaded through the cells themselves (`GcHeader.gray`),
/// so a collection allocates nothing and cannot fail. A cell is pushed at most
/// once, because `marked` is set before the push.
pub const Tracer = struct {
    heap: *Heap,
    gray: ?*GcHeader = null,

    /// Colour a cell reachable and enqueue it for tracing. Idempotent.
    pub fn mark(self: *Tracer, header: *GcHeader) void {
        std.debug.assert(@intFromEnum(header.kind) <= @intFromEnum(Kind.closure));
        if (header.marked) return;
        header.marked = true;
        std.debug.assert(header.gray == null);
        header.gray = self.gray;
        self.gray = header;
    }

    /// Trace every gray cell, and everything they reach, to fixpoint.
    pub fn drain(self: *Tracer) void {
        while (self.gray) |header| {
            self.gray = header.gray;
            header.gray = null;
            std.debug.assert(header.marked);
            switch (header.kind) {
                .string => cellFromHeader(String, header).trace(self),
                .object => cellFromHeader(Object, header).trace(self),
                .symbol => cellFromHeader(Symbol, header).trace(self),
                .bigint => cellFromHeader(BigInt, header).trace(self),
                .environment => cellFromHeader(Environment, header).trace(self),
                .closure => cellFromHeader(Closure, header).trace(self),
            }
        }
    }
};

fn cellFromHeader(comptime T: type, header: *GcHeader) *T {
    return @fieldParentPtr("gc", header);
}

// ---- Heap ------------------------------------------------------------------

pub const Heap = struct {
    gpa: std.mem.Allocator,
    /// Intrusive singly-linked list of every live cell.
    all: ?*GcHeader = null,
    live_count: usize = 0,
    /// Total cells ever allocated (for diagnostics/tests).
    total_allocated: usize = 0,
    /// When set, the VM should `collect` at every allocation safe-point.
    stress: bool = false,
    /// Allocation-triggered GC threshold (live cells): collect when
    /// `live_count` reaches this, then set it to ~2x the surviving live set
    /// (V8-style heap growth factor). Keeps long-running programs bounded.
    next_gc: usize = 16 * 1024,

    pub fn init(gpa: std.mem.Allocator) Heap {
        return .{ .gpa = gpa };
    }

    /// Free every remaining cell. Call at engine shutdown.
    pub fn deinit(self: *Heap) void {
        var it = self.all;
        while (it) |header| {
            const next = header.next;
            self.destroy(header);
            it = next;
        }
        self.all = null;
        self.live_count = 0;
    }

    /// Allocate a new cell of type `T`. The caller must root the returned
    /// pointer (via a `HandleScope`) before the next allocation if it needs to
    /// survive a collection. The `gc` header is initialized here; the caller
    /// fills the remaining payload fields.
    pub fn create(self: *Heap, comptime T: type) !*T {
        const live_before = self.live_count;
        const cell = try self.gpa.create(T);
        cell.* = T{ .gc = .{ .kind = T.gc_kind } };
        // A cell is born white and off the gray stack. If either were true of a
        // fresh cell, the very next collection would skip tracing it (already
        // "marked") or corrupt the worklist.
        std.debug.assert(!cell.gc.marked);
        std.debug.assert(cell.gc.gray == null);
        cell.gc.next = self.all;
        self.all = &cell.gc;
        self.live_count += 1;
        self.total_allocated += 1;
        std.debug.assert(self.live_count == live_before + 1);
        return cell;
    }

    /// Full mark-sweep collection. `root_provider` must expose
    /// `markRoots(*Tracer)` which marks every root (VM stack, call frames,
    /// active handle scopes). Returns the number of cells freed.
    pub fn collect(self: *Heap, root_provider: anytype) usize {
        const live_before = self.live_count;

        // Mark.
        var tracer = Tracer{ .heap = self };
        root_provider.markRoots(&tracer);
        tracer.drain();
        std.debug.assert(tracer.gray == null);

        // Ephemeron fixpoint: a WeakMap entry's value is reachable only while
        // its key is. Marking a value can make further keys reachable, so
        // iterate until stable.
        var changed = true;
        while (changed) {
            changed = false;
            var it = self.all;
            while (it) |header| : (it = header.next) {
                if (!header.marked or header.kind != .object) continue;
                const o = cellFromHeader(Object, header);
                if (o.collection != .weak_map) continue;
                var i: usize = 0;
                while (i + 1 < o.elements.items.len) : (i += 2) {
                    const kh = o.elements.items[i].cellHeader() orelse continue;
                    if (!kh.marked) continue;
                    if (o.elements.items[i + 1].cellHeader()) |vh| {
                        if (!vh.marked) {
                            tracer.mark(vh);
                            changed = true;
                        }
                    }
                }
            }
            // Tracing a newly-live value can reach further weak-map keys, which
            // is why the outer loop iterates; drain before re-scanning.
            tracer.drain();
        }
        std.debug.assert(tracer.gray == null);

        // Clear dead weak entries and WeakRef targets on survivors (their key
        // pointers dangle once the sweep frees the cells).
        var it = self.all;
        while (it) |header| : (it = header.next) {
            if (!header.marked or header.kind != .object) continue;
            const o = cellFromHeader(Object, header);
            switch (o.collection) {
                .weak_map => {
                    var i: usize = 0;
                    while (i + 1 < o.elements.items.len) {
                        const kh = o.elements.items[i].cellHeader();
                        if (kh != null and !kh.?.marked) {
                            // Remove the pair, preserving order.
                            _ = o.elements.orderedRemove(i + 1);
                            _ = o.elements.orderedRemove(i);
                        } else {
                            i += 2;
                        }
                    }
                },
                .weak_set => {
                    var i: usize = 0;
                    while (i < o.elements.items.len) {
                        const kh = o.elements.items[i].cellHeader();
                        if (kh != null and !kh.?.marked) {
                            _ = o.elements.orderedRemove(i);
                        } else {
                            i += 1;
                        }
                    }
                },
                else => {},
            }
            if (o.weak_target) |t| {
                if (t.cellHeader()) |h| {
                    if (!h.marked) o.weak_target = Value.hole_value; // referent died
                }
            }
        }

        // Sweep: walk the intrusive list, freeing unmarked cells and clearing
        // mark bits on survivors.
        var freed: usize = 0;
        var survivors: usize = 0;
        var link: *?*GcHeader = &self.all;
        while (link.*) |header| {
            // Every cell must have been popped off the gray stack by `drain`.
            std.debug.assert(header.gray == null);
            if (header.marked) {
                header.marked = false;
                survivors += 1;
                link = &header.next;
            } else {
                link.* = header.next;
                self.destroy(header);
                self.live_count -= 1;
                freed += 1;
            }
        }
        // Pair the sweep's own counting against the heap's running total: an
        // `all` list that has drifted from `live_count` means a cell was
        // created or destroyed behind the heap's back.
        std.debug.assert(freed + survivors == live_before);
        std.debug.assert(survivors == self.live_count);
        return freed;
    }

    /// Overwrite a dead cell with a pattern that is neither a valid `Kind` nor
    /// a canonical pointer, so that a surviving reference faults *here*, at the
    /// use, rather than silently reading whatever the allocator later puts in
    /// this slot. Only under `stress`: recycled memory is otherwise the sole
    /// thing hiding a missed GC root, and the reuse is timing-dependent (a
    /// single-threaded run happens to leave the bytes intact, a parallel one
    /// does not).
    fn poison(self: *Heap, comptime T: type, cell: *T) void {
        if (self.stress) @memset(std.mem.asBytes(cell), 0xAA);
    }

    fn destroy(self: *Heap, header: *GcHeader) void {
        // Pairs with the sweep: a marked cell is reachable, and freeing one is
        // the single worst thing this file can do. Assert it here too, so the
        // property is checked on the path that would cause the damage.
        std.debug.assert(!header.marked);
        std.debug.assert(header.gray == null);
        switch (header.kind) {
            .string => {
                const s = cellFromHeader(String, header);
                if (s.units.len != 0) self.gpa.free(s.units);
                self.poison(String, s);
                self.gpa.destroy(s);
            },
            .object => {
                const o = cellFromHeader(Object, header);
                o.deinitCell(self.gpa);
                self.poison(Object, o);
                self.gpa.destroy(o);
            },
            .symbol => {
                const s = cellFromHeader(Symbol, header);
                if (s.description) |d| self.gpa.free(d);
                self.poison(Symbol, s);
                self.gpa.destroy(s);
            },
            .bigint => {
                const bi = cellFromHeader(BigInt, header);
                if (bi.limbs.len > 0) self.gpa.free(bi.limbs);
                self.poison(BigInt, bi);
                self.gpa.destroy(bi);
            },
            .environment => {
                const e = cellFromHeader(Environment, header);
                e.deinitCell(self.gpa);
                self.poison(Environment, e);
                self.gpa.destroy(e);
            },
            .closure => {
                const c = cellFromHeader(Closure, header);
                self.poison(Closure, c);
                self.gpa.destroy(c);
            },
        }
    }
};

// ---- Tests -----------------------------------------------------------------

/// A trivial root provider for tests: marks a fixed slice of headers.
const FixedRoots = struct {
    headers: []const *GcHeader,
    fn markRoots(self: FixedRoots, tracer: *Tracer) void {
        for (self.headers) |h| tracer.mark(h);
    }
};

test "allocate and sweep everything when unrooted" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    _ = try heap.create(Object);
    _ = try heap.create(Object);
    const s = try heap.create(String);
    s.units = try std.testing.allocator.dupe(u16, &.{ 'h', 'i' });

    try std.testing.expectEqual(@as(usize, 3), heap.live_count);

    const freed = heap.collect(FixedRoots{ .headers = &.{} });
    try std.testing.expectEqual(@as(usize, 3), freed);
    try std.testing.expectEqual(@as(usize, 0), heap.live_count);
}

test "rooted cells survive collection" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const keep = try heap.create(Object);
    _ = try heap.create(Object); // garbage

    const freed = heap.collect(FixedRoots{ .headers = &.{&keep.gc} });
    try std.testing.expectEqual(@as(usize, 1), freed);
    try std.testing.expectEqual(@as(usize, 1), heap.live_count);

    // The survivor's mark bit must be cleared for the next cycle.
    try std.testing.expectEqual(false, keep.gc.marked);
}

test "mark is idempotent across duplicate roots" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const keep = try heap.create(Object);
    const freed = heap.collect(FixedRoots{ .headers = &.{ &keep.gc, &keep.gc } });
    try std.testing.expectEqual(@as(usize, 0), freed);
    try std.testing.expectEqual(@as(usize, 1), heap.live_count);
}

test "marking a deep object graph does not use the native stack" {
    // A recursive `Tracer.mark` put the *object graph's* depth on the native
    // stack, and that depth is chosen by the program under test: a long linked
    // list, prototype chain or scope chain is ordinary JavaScript. 200k links
    // reliably segfaulted the collector before the mark worklist landed. Debug
    // stack frames are fat, so this is a generous margin over any plausible
    // recursive implementation.
    const depth = 200_000;

    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    // A chain of environments, each the parent of the next: env[0] <- env[1] <- …
    var head = try heap.create(Environment);
    var i: usize = 1;
    while (i < depth) : (i += 1) {
        const child = try heap.create(Environment);
        child.parent = head;
        head = child;
    }
    // Plus one unrooted cell, so the sweep has something to do.
    _ = try heap.create(Environment);
    try std.testing.expectEqual(@as(usize, depth + 1), heap.live_count);

    // Rooting only the tail must keep the whole chain alive.
    const roots = [_]*GcHeader{&head.gc};
    const freed = heap.collect(FixedRoots{ .headers = &roots });
    try std.testing.expectEqual(@as(usize, 1), freed);
    try std.testing.expectEqual(@as(usize, depth), heap.live_count);

    // And the chain is intact, link for link.
    var n: usize = 0;
    var p: ?*Environment = head;
    while (p) |e| : (p = e.parent) n += 1;
    try std.testing.expectEqual(depth, n);
}

test "gray stack is empty between collections" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const a = try heap.create(Environment);
    const b = try heap.create(Environment);
    b.parent = a;

    const roots = [_]*GcHeader{&b.gc};
    _ = heap.collect(FixedRoots{ .headers = &roots });
    // `drain` must pop every cell it pushes, and clear the link on the way out.
    try std.testing.expect(a.gc.gray == null);
    try std.testing.expect(b.gc.gray == null);
    _ = heap.collect(FixedRoots{ .headers = &roots });
    try std.testing.expectEqual(@as(usize, 2), heap.live_count);
}
