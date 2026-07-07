//! Register-based bytecode (phase-2 plan §1).
//!
//! A `CodeBlock` is one compiled function (or the top-level script). Each frame
//! gets a flat register file of `num_registers` slots; instructions address
//! registers, constant-pool entries, nested code blocks, and jump targets via
//! the `a`/`b`/`c` operand fields.
//!
//! Named variables live in heap `Environment`s (resolved to depth/slot at
//! compile time); registers hold expression temporaries and function locals in
//! stack discipline. Optimizing non-captured locals into pure registers is a
//! later-phase concern.

const std = @import("std");
const Value = @import("value.zig").Value;

pub const Op = enum(u8) {
    nop,

    // Loads
    load_const, // a=dst, b=const index
    load_undefined, // a=dst
    load_null, // a=dst
    load_true, // a=dst
    load_false, // a=dst
    move, // a=dst, b=src

    // Variables (environment chain)
    get_var, // a=dst, b=depth, c=slot
    set_var, // a=depth, b=slot, c=src
    init_var, // a=depth, b=slot, c=src  (declaration init; clears TDZ)
    set_dead, // a=depth, b=slot  (mark a lexical slot uninitialized — TDZ)

    // Globals (properties of the global object)
    get_global, // a=dst, b=name const  (ReferenceError if absent)
    get_global_typeof, // a=dst, b=name const  (undefined if absent)
    set_global, // a=name const, b=src

    // Arithmetic
    add, // a=dst, b=lhs, c=rhs  (numeric add or string concat)
    sub,
    mul,
    div,
    mod,
    exp,
    neg, // a=dst, b=operand
    to_number, // a=dst, b=operand (unary +)

    // Bitwise
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    ushr,
    bit_not, // a=dst, b=operand

    // Comparison
    eq, // ==
    ne, // !=
    strict_eq, // ===
    strict_ne, // !==
    lt,
    le,
    gt,
    ge,
    instance_of, // a=dst, b=lhs, c=rhs  (lhs instanceof rhs)
    in_op, // a=dst, b=key, c=obj  (key in obj)

    // Logical / misc unary
    logical_not, // a=dst, b=operand
    type_of, // a=dst, b=operand

    // Control flow
    jump, // a=target pc
    jump_if_true, // a=cond reg, b=target
    jump_if_false, // a=cond reg, b=target
    jump_if_nullish, // a=cond reg, b=target (null or undefined)
    jump_if_not_nullish, // a=cond reg, b=target

    // Objects & properties
    new_object, // a=dst  (empty {} with Object.prototype)
    new_array, // a=dst, b=length  (array with `length` holes)
    new_regex, // a=dst, b=source const, c=flags const
    get_prop, // a=dst, b=obj reg, c=name const index
    set_prop, // a=obj reg, b=name const index, c=value reg
    get_elem, // a=dst, b=obj reg, c=key reg
    set_elem, // a=obj reg, b=key reg, c=value reg
    delete_prop, // a=dst (bool), b=obj reg, c=name const
    delete_elem, // a=dst (bool), b=obj reg, c=key reg
    load_this, // a=dst
    arr_push, // a=array reg, b=value reg  (append one)
    arr_spread, // a=array reg, b=iterable reg  (append all elements)
    iter_init, // a=dst iterator, b=iterable reg  (GetIterator)
    iter_next, // a=dst result{value,done}, b=iterator reg  (IteratorNext)
    enum_keys, // a=dst array, b=object reg  (enumerable keys, for for-in)
    gen_yield, // a=dst (resumed value), b=yielded value reg

    // Functions
    new_closure, // a=dst, b=child code-block index
    call, // a=dst, b=base reg, c=argc  (this=base, callee=base+1, args=base+2..)
    call_apply, // a=dst, b=base reg  (this=base, callee=base+1, args array=base+2)
    construct, // a=dst, b=callee reg, c=argc  (args in callee+1 .. callee+argc)
    ret, // a=src

    // Exceptions
    throw, // a=src
    end_finally, // rethrows the pending exception if the finally was entered abnormally

    pub fn mnemonic(self: Op) []const u8 {
        return @tagName(self);
    }
};

pub const Inst = struct {
    op: Op,
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
};

/// Constant-pool entry. Strings/bigints hold raw source text and are
/// materialized into heap cells at run time; numbers are immediate.
pub const Const = union(enum) {
    number: f64,
    string: []const u8, // cooked UTF-8 (Phase 2 cooking is minimal)
    bigint: []const u8,
};

pub const HandlerKind = enum { catch_clause, finally_clause };

pub const Handler = struct {
    try_start: u32,
    try_end: u32,
    target_pc: u32,
    /// Register to receive the caught exception (for catch handlers).
    catch_reg: u32,
    kind: HandlerKind,
};

pub const CodeBlock = struct {
    name: []const u8,
    num_params: u32 = 0,
    num_registers: u32 = 0,
    is_generator: bool = false,
    /// Arrow function: has no own `this`/`arguments` and is not `new`-able.
    is_arrow: bool = false,
    /// The function's `length` property: parameters before the first default
    /// or rest parameter (may differ from `num_params`).
    fn_length: u32 = 0,
    /// Slots in this block's own environment record.
    num_env_slots: u32 = 0,
    /// Env slot to receive the `arguments` object on entry; null for arrow
    /// functions and the top-level script (which have no own `arguments`).
    arguments_slot: ?u32 = null,
    code: []Inst = &.{},
    constants: []Const = &.{},
    children: []*CodeBlock = &.{},
    handlers: []Handler = &.{},

    pub fn disassemble(self: *const CodeBlock, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try out.print(gpa, "== {s} (params={d}, regs={d}, env_slots={d}) ==\n", .{
            self.name, self.num_params, self.num_registers, self.num_env_slots,
        });
        for (self.code, 0..) |inst, pc| {
            try out.print(gpa, "{d:>4}  {s:<18} a={d} b={d} c={d}\n", .{
                pc, inst.op.mnemonic(), inst.a, inst.b, inst.c,
            });
        }
        for (self.children) |child| {
            try out.print(gpa, "\n", .{});
            try child.disassemble(gpa, out);
        }
    }
};

/// Owns the arena backing a compiled program (root block + all nested blocks,
/// code, constants, and handler tables).
pub const Program = struct {
    arena: std.heap.ArenaAllocator,
    root: *CodeBlock,

    pub fn deinit(self: *Program) void {
        self.arena.deinit();
    }
};

test "codeblock disassembles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const code = try a.alloc(Inst, 3);
    code[0] = .{ .op = .load_const, .a = 0, .b = 0 };
    code[1] = .{ .op = .load_const, .a = 1, .b = 1 };
    code[2] = .{ .op = .add, .a = 0, .b = 0, .c = 1 };

    const consts = try a.alloc(Const, 2);
    consts[0] = .{ .number = 1 };
    consts[1] = .{ .number = 2 };

    var cb: CodeBlock = .{ .name = "test", .num_registers = 2, .code = code, .constants = consts };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try cb.disassemble(std.testing.allocator, &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "add") != null);
}
