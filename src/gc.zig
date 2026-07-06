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

pub const Collection = enum { none, map, set };

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
    /// Array exotic: when true, indexed elements live in `elements` and
    /// `length` is `elements.items.len` (see the interpreter's array paths).
    is_array: bool = false,
    /// Collection kind: Map stores interleaved key/value pairs in `elements`,
    /// Set stores values in `elements`.
    collection: Collection = .none,
    /// Dense element store: array elements, or Map/Set entries.
    elements: std.ArrayList(Value) = .empty,
    /// ArrayBuffer backing bytes (owned); null for non-buffers.
    buffer_data: ?[]u8 = null,
    /// TypedArray view metadata; null for non-typed-arrays.
    ta: ?TypedArrayView = null,

    pub fn trace(self: *Object, t: *Tracer) void {
        if (self.prototype) |p| t.mark(&p.gc);
        if (self.callable) |c| t.mark(&c.gc);
        var it = self.properties.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.value.mark(t);
            if (entry.value_ptr.get) |g| g.mark(t);
            if (entry.value_ptr.set) |s| s.mark(t);
        }
        for (self.elements.items) |v| v.mark(t);
        if (self.ta) |ta| t.mark(&ta.buffer.gc);
    }

    pub fn deinitCell(self: *Object, gpa: std.mem.Allocator) void {
        for (self.properties.keys()) |k| gpa.free(k);
        self.properties.deinit(gpa);
        self.elements.deinit(gpa);
        if (self.buffer_data) |b| gpa.free(b);
    }
};

/// The engine-wide error set (used by the interpreter and native functions).
/// `JsThrow` means a JS exception is pending in the VM; the others are host
/// failures.
pub const VmError = error{ JsThrow, OutOfMemory, StackOverflow };

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

    pub fn trace(self: *Closure, t: *Tracer) void {
        if (self.env) |e| t.mark(&e.gc);
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
    /// Placeholder magnitude; Phase 4 replaces this with a real bignum.
    value: i64 = 0,

    pub fn trace(_: *BigInt, _: *Tracer) void {}
};

// ---- Tracer ----------------------------------------------------------------

/// Marks reachable cells during the mark phase. Root providers and cell
/// `trace` methods drive marking through `mark`.
pub const Tracer = struct {
    heap: *Heap,

    /// Mark a cell reachable and recursively trace its children. Idempotent.
    pub fn mark(self: *Tracer, header: *GcHeader) void {
        if (header.marked) return;
        header.marked = true;
        switch (header.kind) {
            .string => cellFromHeader(String, header).trace(self),
            .object => cellFromHeader(Object, header).trace(self),
            .symbol => cellFromHeader(Symbol, header).trace(self),
            .bigint => cellFromHeader(BigInt, header).trace(self),
            .environment => cellFromHeader(Environment, header).trace(self),
            .closure => cellFromHeader(Closure, header).trace(self),
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
        const cell = try self.gpa.create(T);
        cell.* = T{ .gc = .{ .kind = T.gc_kind } };
        cell.gc.next = self.all;
        self.all = &cell.gc;
        self.live_count += 1;
        self.total_allocated += 1;
        return cell;
    }

    /// Full mark-sweep collection. `root_provider` must expose
    /// `markRoots(*Tracer)` which marks every root (VM stack, call frames,
    /// active handle scopes). Returns the number of cells freed.
    pub fn collect(self: *Heap, root_provider: anytype) usize {
        // Mark.
        var tracer = Tracer{ .heap = self };
        root_provider.markRoots(&tracer);

        // Sweep: walk the intrusive list, freeing unmarked cells and clearing
        // mark bits on survivors.
        var freed: usize = 0;
        var link: *?*GcHeader = &self.all;
        while (link.*) |header| {
            if (header.marked) {
                header.marked = false;
                link = &header.next;
            } else {
                link.* = header.next;
                self.destroy(header);
                self.live_count -= 1;
                freed += 1;
            }
        }
        return freed;
    }

    fn destroy(self: *Heap, header: *GcHeader) void {
        switch (header.kind) {
            .string => {
                const s = cellFromHeader(String, header);
                if (s.units.len != 0) self.gpa.free(s.units);
                self.gpa.destroy(s);
            },
            .object => {
                const o = cellFromHeader(Object, header);
                o.deinitCell(self.gpa);
                self.gpa.destroy(o);
            },
            .symbol => {
                const s = cellFromHeader(Symbol, header);
                if (s.description) |d| self.gpa.free(d);
                self.gpa.destroy(s);
            },
            .bigint => self.gpa.destroy(cellFromHeader(BigInt, header)),
            .environment => {
                const e = cellFromHeader(Environment, header);
                e.deinitCell(self.gpa);
                self.gpa.destroy(e);
            },
            .closure => self.gpa.destroy(cellFromHeader(Closure, header)),
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
