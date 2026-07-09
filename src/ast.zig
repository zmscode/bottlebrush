//! The abstract syntax tree.
//!
//! Nodes are arena-allocated (freed all at once with the `Ast`) and carry
//! source spans for diagnostics and `Function.prototype.toString`. Child links
//! are `*Node`; sequences are arena-allocated `[]*Node` slices. Literal values
//! are stored as raw source slices — the Phase 2 bytecode compiler computes the
//! actual numeric/string values, keeping parsing allocation-light.
//!
//! Not every variant is produced by the current parser; the union is defined
//! ahead of the parser so both can grow together.

const std = @import("std");
const token = @import("token.zig");

pub const SourceType = enum { script, module };
pub const VarKind = enum { keyword_var, let, keyword_const };
pub const PropKind = enum { init, get, set, method, spread };
pub const MethodKind = enum { method, get, set, constructor, field };
pub const ImportKind = enum { named, default, namespace };

pub const FunctionFlags = struct {
    is_async: bool = false,
    is_generator: bool = false,
    is_arrow: bool = false,
    /// Arrow with a concise expression body (no block).
    expression_body: bool = false,
    /// Strict-mode code: this function has a `"use strict"` prologue, or is
    /// nested in strict code / a class body / a module. Set by the parser.
    strict: bool = false,
};

pub const Function = struct {
    name: ?[]const u8,
    params: []*Node,
    body: *Node,
    flags: FunctionFlags,
};

pub const Class = struct {
    name: ?[]const u8,
    super_class: ?*Node,
    members: []*Node,
};

pub const Property = struct {
    key: *Node,
    value: ?*Node,
    kind: PropKind,
    computed: bool = false,
    shorthand: bool = false,
    /// Class members only: declared with `static`.
    is_static: bool = false,
};

pub const ClassMember = struct {
    key: *Node,
    value: ?*Node,
    kind: MethodKind,
    is_static: bool = false,
    computed: bool = false,
    is_private: bool = false,
};

pub const Node = struct {
    start: u32,
    end: u32,
    kind: Kind,

    pub const Kind = union(enum) {
        // ---- literals & primaries ----
        ident: []const u8,
        private_name: []const u8,
        number: struct { raw: []const u8, bigint: bool },
        string: []const u8, // raw, including quotes
        regex: []const u8,
        bool_literal: bool,
        null_literal,
        this_expr,
        super_expr,
        template: struct { quasis: [][]const u8, exprs: []*Node },
        tagged_template: struct { tag: *Node, quasi: *Node },

        array_literal: []?*Node, // null = elision
        object_literal: []*Node, // each is a `property`
        property: Property,

        function: Function,
        class: Class,

        // ---- operators ----
        unary: struct { op: token.Kind, operand: *Node },
        update: struct { op: token.Kind, operand: *Node, prefix: bool },
        binary: struct { op: token.Kind, left: *Node, right: *Node },
        logical: struct { op: token.Kind, left: *Node, right: *Node },
        assignment: struct { op: token.Kind, target: *Node, value: *Node },
        conditional: struct { cond: *Node, then_expr: *Node, else_expr: *Node },
        call: struct { callee: *Node, args: []*Node, optional: bool },
        new_expr: struct { callee: *Node, args: []*Node },
        member: struct { object: *Node, property: *Node, computed: bool, optional: bool },
        sequence: []*Node,
        spread: *Node,
        yield_expr: struct { argument: ?*Node, delegate: bool },
        await_expr: *Node,
        meta_property: struct { meta: []const u8, property: []const u8 },

        // ---- patterns ----
        array_pattern: []?*Node,
        object_pattern: []*Node,
        assignment_pattern: struct { left: *Node, right: *Node },
        rest_element: *Node,

        // ---- statements ----
        program: struct { body: []*Node, source_type: SourceType, strict: bool = false },
        block_stmt: []*Node,
        var_decl: struct { kind: VarKind, decls: []*Node },
        variable_declarator: struct { id: *Node, init: ?*Node },
        empty_stmt,
        expression_stmt: *Node,
        if_stmt: struct { cond: *Node, then_branch: *Node, else_branch: ?*Node },
        for_stmt: struct { init: ?*Node, cond: ?*Node, update: ?*Node, body: *Node },
        for_in_stmt: struct { left: *Node, right: *Node, body: *Node },
        for_of_stmt: struct { left: *Node, right: *Node, body: *Node, is_await: bool },
        while_stmt: struct { cond: *Node, body: *Node },
        do_while_stmt: struct { body: *Node, cond: *Node },
        switch_stmt: struct { discriminant: *Node, cases: []*Node },
        switch_case: struct { test_expr: ?*Node, body: []*Node },
        try_stmt: struct { block: *Node, handler: ?*Node, finalizer: ?*Node },
        catch_clause: struct { param: ?*Node, body: *Node },
        throw_stmt: *Node,
        return_stmt: ?*Node,
        break_stmt: ?[]const u8,
        continue_stmt: ?[]const u8,
        labeled_stmt: struct { label: []const u8, body: *Node },
        with_stmt: struct { object: *Node, body: *Node },
        debugger_stmt,
        function_decl: Function,
        class_decl: Class,

        // ---- modules (parsed now; linked in Phase 5) ----
        import_decl: struct { specifiers: []*Node, source: []const u8 },
        import_specifier: struct { local: []const u8, imported: ?[]const u8, kind: ImportKind },
        export_named: struct { specifiers: []*Node, source: ?[]const u8, declaration: ?*Node },
        export_specifier: struct { local: []const u8, exported: []const u8 },
        export_default: *Node,
        export_all: struct { exported: ?[]const u8, source: []const u8 },
    };
};

/// Owns the arena backing an entire parse tree.
pub const Ast = struct {
    arena: std.heap.ArenaAllocator,
    root: *Node,
    source: []const u8,
    source_type: SourceType,

    pub fn deinit(self: *Ast) void {
        self.arena.deinit();
    }
};

test "node union is constructible" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const id = try a.create(Node);
    id.* = .{ .start = 0, .end = 1, .kind = .{ .ident = "x" } };

    const num = try a.create(Node);
    num.* = .{ .start = 4, .end = 5, .kind = .{ .number = .{ .raw = "1", .bigint = false } } };

    const bin = try a.create(Node);
    bin.* = .{ .start = 0, .end = 5, .kind = .{ .binary = .{ .op = .plus, .left = id, .right = num } } };

    try std.testing.expectEqual(token.Kind.plus, bin.kind.binary.op);
    try std.testing.expectEqualStrings("x", bin.kind.binary.left.kind.ident);
}
