//! AST → register-based bytecode (phase-2 plan §2).
//!
//! Model: named variables live in per-function heap environments, resolved at
//! compile time to (depth, slot) where depth counts enclosing *functions*.
//! Registers hold expression temporaries in stack discipline. Blocks share
//! their function's environment (one env per function), so `let` in a loop does
//! not yet create per-iteration bindings and TDZ is not enforced — both noted
//! as Phase-2 simplifications to tighten later.
//!
//! Supported: literals, identifiers, arithmetic/bitwise/comparison, logical &
//! nullish short-circuit, unary, prefix/postfix update on identifiers,
//! assignment (identifier + compound), conditional, sequence, calls, functions
//! (declarations/expressions/arrows/closures), and the statement set
//! (var/let/const, if, while, for C-style, do-while, blocks, return,
//! break/continue, throw, try/catch/finally). Objects, arrays, member access,
//! destructuring, for-in/of, classes, generators/async, and `new` require the
//! object model and are reported as unsupported for now.

const std = @import("std");
const ast = @import("ast.zig");
const bc = @import("bytecode.zig");
const token = @import("token.zig");

const Node = ast.Node;
const Inst = bc.Inst;
const Op = bc.Op;

pub const Diagnostic = struct {
    message: []const u8,
    pos: u32,
};

pub const Result = union(enum) {
    ok: bc.Program,
    compile_error: Diagnostic,
};

const CompileError = error{ Unsupported, BadCode, OutOfMemory };

const Binding = struct { depth: u32, slot: u32, is_const: bool = false };

/// One declared name in a block: its env slot, and whether writes to it are
/// illegal (`const` — assignment throws a TypeError at run time).
const BlockBinding = struct { slot: u32, is_const: bool = false };

/// One class body's private-name namespace: maps `#name` (as written) to the
/// hidden storage key used at run time.
const PrivateScope = struct {
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
};

const Block = struct {
    names: std.StringHashMapUnmanaged(BlockBinding) = .empty,
};

const FnState = struct {
    parent: ?*FnState,
    name: []const u8,
    is_generator: bool = false,
    is_async: bool = false,
    is_arrow: bool = false,
    is_strict: bool = false,
    simple_params: bool = true,
    num_params: u32 = 0,
    fn_length: u32 = 0,
    arguments_slot: ?u32 = null,
    rest_slot: ?u32 = null,
    rest_from: u32 = 0,
    /// pc just past the parameter-init prologue (defaults + destructuring), so a
    /// generator can evaluate its parameters eagerly at creation.
    param_prologue_end: u32 = 0,
    /// Derived-class constructor: instance fields and private methods install
    /// only after `super(...)` returns (not at frame entry), so `this` isn't
    /// touched before initialization. Empty for base constructors (which
    /// install in the prologue) and non-constructors.
    deferred_instance_fields: []const *Node = &.{},
    /// Private names visible in this function's body (snapshot of the enclosing
    /// class private scopes), captured so a direct `eval` can resolve them.
    private_env: []const bc.PrivateBinding = &.{},
    /// Whether `new.target` is legal here (any real function body; not the
    /// top-level script/indirect-eval scope).
    new_target_allowed: bool = false,
    env_slot_count: u32 = 0,
    reg_top: u32 = 0,
    max_regs: u32 = 0,
    /// Script top only: a reserved register holding the running completion
    /// value, returned instead of undefined (eval/REPL completion semantics).
    completion_reg: ?u32 = null,
    code: std.ArrayList(Inst) = .empty,
    constants: std.ArrayList(bc.Const) = .empty,
    children: std.ArrayList(*bc.CodeBlock) = .empty,
    handlers: std.ArrayList(bc.Handler) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    /// Finalizer bodies of the `try` statements enclosing the code being
    /// compiled. `return`/`break`/`continue` inline these (innermost first)
    /// before leaving the protected region.
    finally_stack: std.ArrayList(*Node) = .empty,
};

pub const Compiler = struct {
    gpa: std.mem.Allocator, // scratch (freed as we go)
    arena: std.mem.Allocator, // program arena (outlives compilation)
    source: []const u8,
    fs: *FnState,
    diag: ?Diagnostic = null,
    /// Innermost loop context, for `continue` jump patching.
    loop: ?*LoopCtx = null,
    /// Innermost breakable context (loop or switch), for `break`.
    break_target: ?*LoopCtx = null,
    /// Lexical stack of class private-name scopes (`#name` -> hidden key).
    /// Resolving a private name searches inner-to-outer; unresolved is an error.
    private_scopes: std.ArrayList(PrivateScope) = .empty,
    /// Monotonic id giving each class body its own private-name namespace, so
    /// two classes' `#x` never collide.
    private_class_seq: u32 = 0,
    /// Whether `new.target` is legal at the root (top-level) function. False
    /// for a script/indirect eval (SyntaxError there), true for a direct eval
    /// that inherits an enclosing function's new-target.
    root_new_target_allowed: bool = false,
    /// True while compiling a direct `eval`'s source. `new.target` is only
    /// modelled (as undefined) there; elsewhere it stays unsupported so real
    /// new-target-value code remains a declined compile-gap rather than a
    /// wrong-answer pass.
    eval_compile: bool = false,

    fn fail(self: *Compiler, comptime msg: []const u8, pos: u32) CompileError {
        if (self.diag == null) self.diag = .{ .message = msg, .pos = pos };
        return error.Unsupported;
    }

    // ---- registers ---------------------------------------------------------

    fn allocReg(self: *Compiler) u32 {
        const r = self.fs.reg_top;
        self.fs.reg_top += 1;
        if (self.fs.reg_top > self.fs.max_regs) self.fs.max_regs = self.fs.reg_top;
        return r;
    }
    fn freeTo(self: *Compiler, top: u32) void {
        self.fs.reg_top = top;
    }

    // ---- emit / patch ------------------------------------------------------

    fn emit(self: *Compiler, inst: Inst) CompileError!u32 {
        const pc: u32 = @intCast(self.fs.code.items.len);
        try self.fs.code.append(self.gpa, inst);
        return pc;
    }
    fn here(self: *Compiler) u32 {
        return @intCast(self.fs.code.items.len);
    }
    fn patchTarget(self: *Compiler, pc: u32, target: u32) void {
        // Jump target lives in operand `a` for `jump`, `b` for conditional jumps.
        const op = self.fs.code.items[pc].op;
        switch (op) {
            .jump => self.fs.code.items[pc].a = target,
            else => self.fs.code.items[pc].b = target,
        }
    }

    fn addConst(self: *Compiler, c: bc.Const) CompileError!u32 {
        const idx: u32 = @intCast(self.fs.constants.items.len);
        try self.fs.constants.append(self.gpa, c);
        return idx;
    }

    // ---- scopes ------------------------------------------------------------

    fn pushBlock(self: *Compiler) CompileError!void {
        try self.fs.blocks.append(self.gpa, .{});
    }
    fn popBlock(self: *Compiler) void {
        var b = self.fs.blocks.pop().?;
        b.names.deinit(self.gpa);
    }
    fn declare(self: *Compiler, name: []const u8) CompileError!u32 {
        const b = &self.fs.blocks.items[self.fs.blocks.items.len - 1];
        if (b.names.get(name)) |bind| return bind.slot; // redeclaration -> same slot
        const slot = self.fs.env_slot_count;
        self.fs.env_slot_count += 1;
        try b.names.put(self.gpa, name, .{ .slot = slot });
        return slot;
    }

    /// Mark a name just declared in the current block as `const` (writes throw).
    fn markConst(self: *Compiler, name: []const u8) void {
        const b = &self.fs.blocks.items[self.fs.blocks.items.len - 1];
        if (b.names.getPtr(name)) |bind| bind.is_const = true;
    }
    fn resolve(self: *Compiler, name: []const u8) ?Binding {
        var fs: ?*FnState = self.fs;
        var depth: u32 = 0;
        while (fs) |f| {
            var i = f.blocks.items.len;
            while (i > 0) {
                i -= 1;
                if (f.blocks.items[i].names.get(name)) |bind| return .{ .depth = depth, .slot = bind.slot, .is_const = bind.is_const };
            }
            fs = f.parent;
            depth += 1;
        }
        return null;
    }

    // ---- hoisting ----------------------------------------------------------

    /// Pre-declare `var` and function-declaration names in the current
    /// function's top block so they are function-scoped and forward-visible.
    fn hoist(self: *Compiler, body: []*Node) CompileError!void {
        for (body) |stmt| try self.hoistStmt(stmt);
    }
    fn hoistStmt(self: *Compiler, stmt: *Node) CompileError!void {
        switch (stmt.kind) {
            .var_decl => |vd| {
                if (vd.kind == .keyword_var) {
                    for (vd.decls) |d| try self.hoistTarget(d.kind.variable_declarator.id);
                }
            },
            .function_decl => |f| {
                // Top-level function declarations become global properties
                // (defined here, assigned in emitHoistedFunctions so strict
                // set_global finds them); nested ones get env slots.
                if (f.name) |n| {
                    if (self.atScriptTop()) {
                        const idx = try self.addConst(.{ .string = n });
                        _ = try self.emit(.{ .op = .ensure_global, .a = idx });
                    } else {
                        _ = try self.declare(n);
                    }
                }
            },
            .if_stmt => |s| {
                try self.hoistStmt(s.then_branch);
                if (s.else_branch) |e| try self.hoistStmt(e);
            },
            .for_stmt => |s| {
                if (s.init) |init_node| try self.hoistStmt(init_node);
                try self.hoistStmt(s.body);
            },
            .for_in_stmt => |s| {
                try self.hoistStmt(s.left);
                try self.hoistStmt(s.body);
            },
            .for_of_stmt => |s| {
                try self.hoistStmt(s.left);
                try self.hoistStmt(s.body);
            },
            .while_stmt => |s| try self.hoistStmt(s.body),
            .do_while_stmt => |s| try self.hoistStmt(s.body),
            .block_stmt => |b| try self.hoist(b),
            .try_stmt => |s| {
                try self.hoistStmt(s.block);
                if (s.handler) |h| try self.hoistStmt(h.kind.catch_clause.body);
                if (s.finalizer) |fin| try self.hoistStmt(fin);
            },
            .labeled_stmt => |s| try self.hoistStmt(s.body),
            .switch_stmt => |s| for (s.cases) |c| try self.hoist(c.kind.switch_case.body),
            else => {},
        }
    }
    /// True when compiling the top-level script itself (not a function): var
    /// and function declarations become global-object properties.
    fn atScriptTop(self: *const Compiler) bool {
        return self.fs.parent == null;
    }

    fn hoistTarget(self: *Compiler, target: *Node) CompileError!void {
        switch (target.kind) {
            .ident => |name| {
                if (self.atScriptTop()) {
                    const idx = try self.addConst(.{ .string = name });
                    _ = try self.emit(.{ .op = .ensure_global, .a = idx });
                } else {
                    _ = try self.declare(name);
                }
            },
            .assignment_pattern => |ap| try self.hoistTarget(ap.left),
            .rest_element => |inner| try self.hoistTarget(inner),
            .array_pattern => |elems| for (elems) |maybe| {
                if (maybe) |e| try self.hoistTarget(e);
            },
            .object_pattern => |props| for (props) |pr| {
                if (pr.kind == .property) {
                    if (pr.kind.property.value) |pv| try self.hoistTarget(pv);
                }
                if (pr.kind == .rest_element) try self.hoistTarget(pr.kind.rest_element);
            },
            else => {},
        }
    }

    // ---- function compilation ---------------------------------------------

    fn compileFunction(
        self: *Compiler,
        name: []const u8,
        params: []*Node,
        body: *Node,
        is_expression_body: bool,
        is_generator: bool,
        is_async: bool,
        is_arrow: bool,
        force_strict: bool,
        /// Instance-field members (class constructors only): `this.key = init`
        /// runs in declaration order before the constructor body.
        class_fields: []const *Node,
        /// Derived-class constructor: defer instance-element installation until
        /// after `super(...)` returns instead of the prologue.
        is_derived_ctor: bool,
        parent_fs: ?*FnState,
    ) CompileError!*bc.CodeBlock {
        // Async generators need the async-iteration machinery (Phase 5 §5c).
        if (is_async and is_generator) return self.fail("async generators unsupported", 0);
        var fs = FnState{ .parent = parent_fs, .name = name, .is_generator = is_generator, .is_async = is_async, .is_arrow = is_arrow };
        if (is_derived_ctor) fs.deferred_instance_fields = class_fields;
        // `new.target` is legal in any non-arrow function body; an arrow
        // inherits its enclosing function's new-target (so an arrow at the
        // script / indirect-eval top level has none — a SyntaxError).
        fs.new_target_allowed = if (is_arrow)
            (if (parent_fs) |pf| pf.new_target_allowed else self.root_new_target_allowed)
        else
            (if (parent_fs == null) self.root_new_target_allowed else true);
        // Strict mode is inherited from the enclosing function, forced by the
        // context (class bodies), or switched on by a "use strict" directive.
        if (parent_fs) |pf| fs.is_strict = pf.is_strict;
        if (force_strict) fs.is_strict = true;
        if (!is_expression_body and body.kind == .block_stmt and hasUseStrictDirective(body.kind.block_stmt)) {
            fs.is_strict = true;
        }
        const prev = self.fs;
        self.fs = &fs;
        defer self.fs = prev;
        defer self.deinitFnState(&fs);

        // Snapshot the private names in scope so a direct `eval` in this body
        // can resolve `#name` against the same hidden keys.
        {
            var pe: std.ArrayList(bc.PrivateBinding) = .empty;
            defer pe.deinit(self.gpa);
            for (self.private_scopes.items) |scope| {
                var it = scope.names.iterator();
                while (it.next()) |e| try pe.append(self.gpa, .{
                    .name = try self.arena.dupe(u8, e.key_ptr.*),
                    .key = e.value_ptr.*,
                });
            }
            fs.private_env = try self.arena.dupe(bc.PrivateBinding, pe.items);
        }

        try self.pushBlock();

        // Parameters occupy the first env slots. `fn_length` counts only the
        // ones before the first default/rest parameter (the `length` property).
        var counting_length = true;
        for (params, 0..) |p, pidx| {
            if (p.kind != .ident) fs.simple_params = false;
            switch (p.kind) {
                .ident => |pn| {
                    _ = try self.declare(pn);
                    if (counting_length) fs.fn_length += 1;
                },
                .assignment_pattern => |ap| {
                    counting_length = false;
                    if (ap.left.kind == .ident) {
                        _ = try self.declare(ap.left.kind.ident);
                    } else {
                        // Pattern param with default: raw argument lives in a
                        // uniquely named synthetic slot; the pattern binds after
                        // defaults are applied.
                        _ = try self.declare(try std.fmt.allocPrint(self.arena, "\x00param{d}", .{pidx}));
                    }
                },
                .array_pattern, .object_pattern => {
                    if (counting_length) fs.fn_length += 1;
                    _ = try self.declare(try std.fmt.allocPrint(self.arena, "\x00param{d}", .{pidx}));
                },
                .rest_element => |target| {
                    // `...r`: not counted in `length`; the trailing arguments
                    // are gathered into an array at frame entry.
                    counting_length = false;
                    const slot = if (target.kind == .ident)
                        try self.declare(target.kind.ident)
                    else
                        try self.declare(try std.fmt.allocPrint(self.arena, "\x00param{d}", .{pidx}));
                    fs.rest_slot = slot;
                    fs.rest_from = @intCast(pidx);
                },
                else => return self.fail("pattern params unsupported", p.start),
            }
        }
        // The interpreter fills positional slots for the non-rest parameters;
        // the rest slot (if any) is populated separately.
        fs.num_params = if (fs.rest_slot != null) fs.rest_from else @intCast(params.len);

        // Default parameter values: `param = param === undefined ? dflt : param`.
        for (params, 0..) |p, slot| {
            if (p.kind != .assignment_pattern) continue;
            const ap = p.kind.assignment_pattern;
            const cur = self.allocReg();
            _ = try self.emit(.{ .op = .get_var, .a = cur, .b = 0, .c = @intCast(slot) });
            const und = self.allocReg();
            _ = try self.emit(.{ .op = .load_undefined, .a = und });
            const cmp = self.allocReg();
            _ = try self.emit(.{ .op = .strict_eq, .a = cmp, .b = cur, .c = und });
            const jskip = try self.emit(.{ .op = .jump_if_false, .a = cmp });
            const dflt = self.allocReg();
            try self.compileExprInto(dflt, ap.right);
            _ = try self.emit(.{ .op = .set_var, .a = 0, .b = @intCast(slot), .c = dflt });
            self.patchTarget(jskip, self.here());
            self.freeTo(cur);
        }

        // Destructured parameters: bind the pattern from the raw argument slot.
        for (params, 0..) |p, slot| {
            const pattern: ?*Node = switch (p.kind) {
                .array_pattern, .object_pattern => p,
                .assignment_pattern => |ap2| if (ap2.left.kind != .ident) ap2.left else null,
                // A rest parameter whose target is a pattern (`...[a, b]`) binds
                // from the gathered rest array.
                .rest_element => |target| if (target.kind != .ident) target else null,
                else => null,
            };
            if (pattern) |pt| {
                const v = self.allocReg();
                _ = try self.emit(.{ .op = .get_var, .a = v, .b = 0, .c = @intCast(slot) });
                try self.compilePatternBind(pt, v, .decl_lexical);
                self.freeTo(v);
            }
        }
        // End of the parameter-initialization prologue (default + destructuring
        // evaluation). A generator runs this eagerly at creation, per spec, then
        // suspends the body from here.
        fs.param_prologue_end = self.here();

        // Ordinary (non-arrow) functions get an implicit `arguments` binding,
        // materialized at run time. Skip the top-level script (parent == null)
        // and any function that already binds the name as a parameter.
        if (!is_arrow and parent_fs != null) {
            const top = &fs.blocks.items[fs.blocks.items.len - 1];
            if (!top.names.contains("arguments")) {
                fs.arguments_slot = try self.declare("arguments");
            }
        }

        if (is_expression_body) {
            const r = try self.compileExprToNew(body);
            _ = try self.emit(.{ .op = .ret, .a = r });
            self.freeTo(0);
        } else {
            const stmts = body.kind.block_stmt;
            try self.hoist(stmts);
            try self.declareLexicals(stmts);
            try self.emitHoistedFunctions(stmts);
            // Instance elements install on `this` before the constructor body
            // runs — but a derived constructor defers them until `super(...)`
            // returns (see compileCall), since `this` isn't bound before then.
            if (!is_derived_ctor) try self.emitInstanceElements(class_fields);
            // Script top: reserve reg 0 as the completion value (seeded
            // undefined), which top-level expression statements update.
            if (parent_fs == null) {
                const creg = self.allocReg();
                _ = try self.emit(.{ .op = .load_undefined, .a = creg });
                fs.completion_reg = creg;
            }
            for (stmts) |s| try self.compileStmt(s);
            if (fs.completion_reg) |creg| {
                _ = try self.emit(.{ .op = .ret, .a = creg });
            } else {
                // Implicit `return undefined`.
                const r = self.allocReg();
                _ = try self.emit(.{ .op = .load_undefined, .a = r });
                _ = try self.emit(.{ .op = .ret, .a = r });
            }
            self.freeTo(0);
        }

        self.popBlock();
        return self.finishCodeBlock(&fs);
    }

    fn emitHoistedFunctions(self: *Compiler, body: []*Node) CompileError!void {
        for (body) |stmt| {
            if (stmt.kind == .function_decl) {
                const f = stmt.kind.function_decl;
                const child = try self.compileFunction(f.name orelse "", f.params, f.body, false, f.flags.is_generator, f.flags.is_async, false, false, &.{}, false, self.fs);
                const idx: u32 = @intCast(self.fs.children.items.len);
                try self.fs.children.append(self.gpa, child);
                const r = self.allocReg();
                _ = try self.emit(.{ .op = .new_closure, .a = r, .b = idx });
                if (self.resolve(f.name.?)) |bind| {
                    _ = try self.emit(.{ .op = .set_var, .a = bind.depth, .b = bind.slot, .c = r });
                } else {
                    // Top-level function: a property of the global object.
                    const nidx = try self.addConst(.{ .string = f.name.? });
                    _ = try self.emit(.{ .op = .set_global, .a = nidx, .b = r });
                }
                self.freeTo(r);
            }
        }
    }

    fn finishCodeBlock(self: *Compiler, fs: *FnState) CompileError!*bc.CodeBlock {
        const cb = try self.arena.create(bc.CodeBlock);
        cb.* = .{
            .name = try self.arena.dupe(u8, fs.name),
            .num_params = fs.num_params,
            .num_registers = fs.max_regs,
            .num_env_slots = fs.env_slot_count,
            .is_generator = fs.is_generator,
            .is_async = fs.is_async,
            .is_arrow = fs.is_arrow,
            .is_strict = fs.is_strict,
            .simple_params = fs.simple_params,
            .fn_length = fs.fn_length,
            .arguments_slot = fs.arguments_slot,
            .rest_slot = fs.rest_slot,
            .rest_from = fs.rest_from,
            .param_prologue_end = fs.param_prologue_end,
            .private_env = fs.private_env,
            .code = try self.arena.dupe(Inst, fs.code.items),
            .constants = try self.dupeConstants(fs.constants.items),
            .children = try self.arena.dupe(*bc.CodeBlock, fs.children.items),
            .handlers = try self.arena.dupe(bc.Handler, fs.handlers.items),
        };
        return cb;
    }

    fn dupeConstants(self: *Compiler, src: []const bc.Const) CompileError![]bc.Const {
        const out = try self.arena.alloc(bc.Const, src.len);
        for (src, 0..) |c, i| {
            out[i] = switch (c) {
                .number => |n| .{ .number = n },
                .string => |s| .{ .string = try self.arena.dupe(u8, s) },
                .bigint => |s| .{ .bigint = try self.arena.dupe(u8, s) },
            };
        }
        return out;
    }

    fn deinitFnState(self: *Compiler, fs: *FnState) void {
        fs.code.deinit(self.gpa);
        fs.constants.deinit(self.gpa);
        fs.children.deinit(self.gpa);
        fs.handlers.deinit(self.gpa);
        for (fs.blocks.items) |*b| b.names.deinit(self.gpa);
        fs.blocks.deinit(self.gpa);
        fs.finally_stack.deinit(self.gpa);
    }

    /// Inline the pending finalizers from the top of the stack down to (but
    /// not including) `base`, innermost first — used when a `return`/`break`/
    /// `continue` leaves their protected regions. While a finalizer compiles,
    /// the stack is truncated to its own level so abrupt exits *inside* the
    /// finalizer only run the finalizers that enclose it.
    fn emitFinalizersDownTo(self: *Compiler, base: usize) CompileError!void {
        const saved_len = self.fs.finally_stack.items.len;
        var i = saved_len;
        while (i > base) {
            i -= 1;
            const fin = self.fs.finally_stack.items[i];
            self.fs.finally_stack.items.len = i;
            try self.compileStmt(fin);
            self.fs.finally_stack.items.len = saved_len;
        }
    }

    // ---- statements --------------------------------------------------------

    fn compileStmt(self: *Compiler, stmt: *Node) CompileError!void {
        switch (stmt.kind) {
            .empty_stmt, .debugger_stmt => {},
            .function_decl => {}, // handled by emitHoistedFunctions
            .expression_stmt => |e| {
                const r = try self.compileExprToNew(e);
                // Script top: record it as the running completion value.
                if (self.fs.completion_reg) |creg| {
                    _ = try self.emit(.{ .op = .move, .a = creg, .b = r });
                }
                self.freeTo(r);
            },
            .var_decl => |vd| try self.compileVarDecl(vd),
            .block_stmt => |b| {
                try self.pushBlock();
                try self.declareLexicals(b);
                for (b) |s| try self.compileStmt(s);
                self.popBlock();
            },
            .if_stmt => |s| try self.compileIf(s),
            .while_stmt => |s| try self.compileWhile(s),
            .do_while_stmt => |s| try self.compileDoWhile(s),
            .for_stmt => |s| try self.compileFor(s),
            .for_of_stmt => |s| try self.compileForOf(s),
            .for_in_stmt => |s| try self.compileForIn(s),
            .switch_stmt => |s| try self.compileSwitch(s),
            .return_stmt => |arg| {
                // The return operand is evaluated *before* any pending
                // finalizers run (spec order), and its register survives them.
                const r = if (arg) |a| try self.compileExprToNew(a) else blk: {
                    const rr = self.allocReg();
                    _ = try self.emit(.{ .op = .load_undefined, .a = rr });
                    break :blk rr;
                };
                try self.emitFinalizersDownTo(0);
                _ = try self.emit(.{ .op = .ret, .a = r });
                self.freeTo(r);
            },
            .throw_stmt => |arg| {
                const r = try self.compileExprToNew(arg);
                _ = try self.emit(.{ .op = .throw, .a = r });
                self.freeTo(r);
            },
            .break_stmt => |label| {
                if (label != null) return self.fail("labeled break unsupported", stmt.start);
                try self.emitLoopJump(.brk, stmt.start);
            },
            .continue_stmt => |label| {
                if (label != null) return self.fail("labeled continue unsupported", stmt.start);
                try self.emitLoopJump(.cont, stmt.start);
            },
            .try_stmt => |s| try self.compileTry(s),
            .labeled_stmt => |s| try self.compileStmt(s.body), // label ignored for now
            .class_decl => |cls| {
                const name = cls.name orelse return self.fail("class declaration requires a name", stmt.start);
                const slot = try self.declare(name);
                const r = self.allocReg();
                try self.compileClass(r, cls, stmt.start);
                _ = try self.emit(.{ .op = .init_var, .a = 0, .b = slot, .c = r });
                self.freeTo(r);
            },
            else => return self.fail("unsupported statement", stmt.start),
        }
    }

    // ---- destructuring ------------------------------------------------------

    const BindMode = enum { decl_lexical, decl_const, decl_var, assign };

    fn bindPatternName(self: *Compiler, name: []const u8, src: u32, mode: BindMode) CompileError!void {
        switch (mode) {
            .decl_lexical, .decl_const => {
                const slot = try self.declare(name);
                if (mode == .decl_const) self.markConst(name);
                _ = try self.emit(.{ .op = .init_var, .a = 0, .b = slot, .c = src });
            },
            .decl_var => {
                // Top-level `var` patterns bind global properties (hoistTarget
                // already emitted ensure_global for each name).
                if (self.atScriptTop()) {
                    const idx = try self.addConst(.{ .string = name });
                    _ = try self.emit(.{ .op = .set_global, .a = idx, .b = src });
                    return;
                }
                const slot = if (self.resolve(name)) |b| (if (b.depth == 0) b.slot else try self.declare(name)) else try self.declare(name);
                _ = try self.emit(.{ .op = .init_var, .a = 0, .b = slot, .c = src });
            },
            .assign => {
                if (self.resolve(name)) |b| {
                    if (b.is_const) {
                        const midx = try self.addConst(.{ .string = "assignment to constant variable" });
                        _ = try self.emit(.{ .op = .throw_type_error, .a = midx });
                        return;
                    }
                    _ = try self.emit(.{ .op = .set_var, .a = b.depth, .b = b.slot, .c = src });
                } else {
                    const idx = try self.addConst(.{ .string = name });
                    _ = try self.emit(.{ .op = .set_global, .a = idx, .b = src });
                }
            },
        }
    }

    /// Store the value in `src` into a member-expression target (`[o.x] = v`).
    fn storeToMember(self: *Compiler, m_node: *Node, src: u32) CompileError!void {
        const m = m_node.kind.member;
        const obj = self.allocReg();
        try self.compileExprInto(obj, m.object);
        if (m.computed) {
            const k = self.allocReg();
            try self.compileExprInto(k, m.property);
            _ = try self.emit(.{ .op = .set_elem, .a = obj, .b = k, .c = src });
        } else {
            if (m.property.kind != .ident) return self.fail("unsupported member target", m_node.start);
            const idx = try self.addConst(.{ .string = m.property.kind.ident });
            _ = try self.emit(.{ .op = .set_prop, .a = obj, .b = idx, .c = src });
        }
        self.freeTo(obj);
    }

    /// Bind `target` to `src`, substituting `dflt` when `src` is undefined.
    fn bindWithDefault(self: *Compiler, target: *Node, dflt: *Node, src: u32, mode: BindMode) CompileError!void {
        const v = self.allocReg();
        _ = try self.emit(.{ .op = .move, .a = v, .b = src });
        const und = self.allocReg();
        _ = try self.emit(.{ .op = .load_undefined, .a = und });
        const cmp = self.allocReg();
        _ = try self.emit(.{ .op = .strict_eq, .a = cmp, .b = v, .c = und });
        const jskip = try self.emit(.{ .op = .jump_if_false, .a = cmp });
        try self.compileExprInto(v, dflt);
        // NamedEvaluation: `{ x = () => {} }` / `[x = function(){}]` names the
        // anonymous default after the binding — but only when the target is a
        // plain identifier and the default was actually taken (this branch).
        if (target.kind == .ident and isAnonFnLike(dflt)) {
            const idx = try self.addConst(.{ .string = target.kind.ident });
            _ = try self.emit(.{ .op = .set_fn_name, .a = v, .b = idx });
        }
        self.patchTarget(jskip, self.here());
        self.freeTo(und);
        try self.compilePatternBind(target, v, mode);
        self.freeTo(v);
    }

    /// One IteratorBindingInitialization step into `val`: if the record is
    /// already done, `val = undefined`; otherwise advance, record done-ness,
    /// and read the value (undefined if this step reached the end).
    fn emitIterStep(self: *Compiler, iter: u32, done: u32, val: u32, value_name: u32, done_name: u32) CompileError!void {
        const juse1 = try self.emit(.{ .op = .jump_if_true, .a = done });
        // IteratorStep / IteratorValue set the record's Done on an abrupt
        // completion, so a throw from next() or the value getter must NOT
        // trigger IteratorClose. Mark done pessimistically, clear it only once
        // a value is successfully read.
        _ = try self.emit(.{ .op = .load_true, .a = done });
        const res = self.allocReg();
        _ = try self.emit(.{ .op = .iter_next, .a = res, .b = iter });
        const d = self.allocReg();
        _ = try self.emit(.{ .op = .get_prop, .a = d, .b = res, .c = done_name });
        const juse2 = try self.emit(.{ .op = .jump_if_true, .a = d });
        _ = try self.emit(.{ .op = .get_prop, .a = val, .b = res, .c = value_name });
        _ = try self.emit(.{ .op = .load_false, .a = done });
        self.freeTo(res);
        const jhave = try self.emit(.{ .op = .jump });
        self.patchTarget(juse1, self.here());
        self.patchTarget(juse2, self.here());
        _ = try self.emit(.{ .op = .load_undefined, .a = val });
        self.patchTarget(jhave, self.here());
    }

    fn bindArrayPattern(self: *Compiler, elems: []?*Node, src: u32, mode: BindMode) CompileError!void {
        // Iterator-protocol based, per spec: works for arrays, strings, Maps,
        // Sets, generators, and custom iterables alike. Tracks the iterator's
        // done-ness so it can be IteratorClose'd on normal completion (not
        // exhausted) or on an abrupt one (a target/default that throws).
        const iter = self.allocReg();
        _ = try self.emit(.{ .op = .iter_init, .a = iter, .b = src });
        const done = self.allocReg();
        _ = try self.emit(.{ .op = .load_false, .a = done });
        const value_name = try self.addConst(.{ .string = "value" });
        const done_name = try self.addConst(.{ .string = "done" });

        const hstart = self.here();
        for (elems) |maybe| {
            if (maybe) |el| {
                if (el.kind == .rest_element or el.kind == .spread) {
                    const target = if (el.kind == .rest_element) el.kind.rest_element else el.kind.spread;
                    // Collect the remaining elements into a fresh array.
                    const arr = self.allocReg();
                    _ = try self.emit(.{ .op = .new_array, .a = arr, .b = 0 });
                    const top = self.here();
                    const jexit = try self.emit(.{ .op = .jump_if_true, .a = done });
                    _ = try self.emit(.{ .op = .load_true, .a = done }); // pessimistic (see emitIterStep)
                    const res = self.allocReg();
                    _ = try self.emit(.{ .op = .iter_next, .a = res, .b = iter });
                    const d = self.allocReg();
                    _ = try self.emit(.{ .op = .get_prop, .a = d, .b = res, .c = done_name });
                    const jexit2 = try self.emit(.{ .op = .jump_if_true, .a = d });
                    const val = self.allocReg();
                    _ = try self.emit(.{ .op = .get_prop, .a = val, .b = res, .c = value_name });
                    _ = try self.emit(.{ .op = .load_false, .a = done });
                    _ = try self.emit(.{ .op = .arr_push, .a = arr, .b = val });
                    _ = try self.emit(.{ .op = .jump, .a = top });
                    self.patchTarget(jexit, self.here());
                    self.patchTarget(jexit2, self.here());
                    self.freeTo(res);
                    try self.compilePatternBind(target, arr, mode);
                    self.freeTo(arr);
                    break;
                }
                const val = self.allocReg();
                try self.emitIterStep(iter, done, val, value_name, done_name);
                try self.compilePatternBind(el, val, mode);
                self.freeTo(val);
            } else {
                // Elision: consume one iterator result, bind nothing.
                const val = self.allocReg();
                try self.emitIterStep(iter, done, val, value_name, done_name);
                self.freeTo(val);
            }
        }
        const hend = self.here();

        // Normal completion: close the iterator unless it is already exhausted.
        const jskip = try self.emit(.{ .op = .jump_if_true, .a = done });
        _ = try self.emit(.{ .op = .iter_close, .a = iter });
        self.patchTarget(jskip, self.here());
        const jover = try self.emit(.{ .op = .jump });

        // Abrupt completion within the binding: best-effort close, then rethrow.
        const catch_reg = self.allocReg();
        try self.fs.handlers.append(self.gpa, .{
            .try_start = hstart,
            .try_end = hend,
            .target_pc = self.here(),
            .catch_reg = catch_reg,
            .kind = .catch_clause,
        });
        // Only close when the record is not already done (an iterator/value
        // error marks it done, so the close is skipped).
        const jskip_q = try self.emit(.{ .op = .jump_if_true, .a = done });
        _ = try self.emit(.{ .op = .iter_close_quiet, .a = iter });
        self.patchTarget(jskip_q, self.here());
        _ = try self.emit(.{ .op = .throw, .a = catch_reg });
        self.freeTo(catch_reg);
        self.patchTarget(jover, self.here());

        self.freeTo(iter);
    }

    fn bindObjectPattern(self: *Compiler, props: []*Node, src: u32, mode: BindMode) CompileError!void {
        // RequireObjectCoercible: `{} = null` / `{ x } = undefined` throw a
        // TypeError before any property access (even for an empty pattern).
        _ = try self.emit(.{ .op = .require_coercible, .a = src });
        // A rest element needs the set of already-bound keys at run time (for
        // computed keys), so collect every key into an excluded-keys array.
        // Binding patterns spell rest as a .rest_element node; the assignment
        // cover grammar spells it as a spread-kind property.
        var has_rest = false;
        for (props) |p| {
            if (p.kind == .rest_element or p.kind == .spread) has_rest = true;
            if (p.kind == .property and p.kind.property.kind == .spread) has_rest = true;
        }
        const excluded: u32 = if (has_rest) blk: {
            const r = self.allocReg();
            _ = try self.emit(.{ .op = .new_array, .a = r, .b = 0 });
            break :blk r;
        } else 0;

        for (props) |p| {
            switch (p.kind) {
                .rest_element, .spread => {
                    const target = if (p.kind == .rest_element) p.kind.rest_element else p.kind.spread;
                    const rest = self.allocReg();
                    _ = try self.emit(.{ .op = .new_object, .a = rest });
                    _ = try self.emit(.{ .op = .copy_rest, .a = rest, .b = src, .c = excluded });
                    try self.compilePatternBind(target, rest, mode);
                    self.freeTo(rest);
                },
                .property => |prop| {
                    if (prop.kind == .spread) {
                        const target = prop.key; // spread stores its expression in `key`
                        const rest = self.allocReg();
                        _ = try self.emit(.{ .op = .new_object, .a = rest });
                        _ = try self.emit(.{ .op = .copy_rest, .a = rest, .b = src, .c = excluded });
                        try self.compilePatternBind(target, rest, mode);
                        self.freeTo(rest);
                        continue;
                    }
                    if (prop.kind != .init and prop.kind != .method) return self.fail("invalid destructuring property", p.start);
                    const val = self.allocReg();
                    if (prop.computed or prop.key.kind == .number) {
                        // Evaluated keys (computed, numeric literals) go through
                        // get_elem for canonical ToPropertyKey handling.
                        const k = self.allocReg();
                        try self.compileExprInto(k, prop.key);
                        _ = try self.emit(.{ .op = .get_elem, .a = val, .b = src, .c = k });
                        if (has_rest) _ = try self.emit(.{ .op = .arr_push, .a = excluded, .b = k });
                    } else {
                        const idx: u32 = switch (prop.key.kind) {
                            .ident => |n| try self.addConst(.{ .string = n }),
                            .string => |raw| try self.addConst(.{ .string = try self.cookString(raw) }),
                            else => return self.fail("unsupported destructuring key", p.start),
                        };
                        _ = try self.emit(.{ .op = .get_prop, .a = val, .b = src, .c = idx });
                        if (has_rest) {
                            const k = self.allocReg();
                            _ = try self.emit(.{ .op = .load_const, .a = k, .b = idx });
                            _ = try self.emit(.{ .op = .arr_push, .a = excluded, .b = k });
                            self.freeTo(k);
                        }
                    }
                    const target_node = prop.value orelse return self.fail("invalid destructuring property", p.start);
                    try self.compilePatternBind(target_node, val, mode);
                    self.freeTo(val);
                },
                else => return self.fail("invalid destructuring property", p.start),
            }
        }
        if (has_rest) self.freeTo(excluded);
    }

    /// Bind a destructuring target (binding pattern *or* the literal cover form
    /// used in assignment expressions) to the value in `src`.
    fn compilePatternBind(self: *Compiler, pat: *Node, src: u32, mode: BindMode) CompileError!void {
        switch (pat.kind) {
            .ident => |name| try self.bindPatternName(name, src, mode),
            .member => {
                if (mode != .assign) return self.fail("member expression not allowed in binding pattern", pat.start);
                try self.storeToMember(pat, src);
            },
            .assignment_pattern => |ap| try self.bindWithDefault(ap.left, ap.right, src, mode),
            .assignment => |a| {
                // Literal cover form: `[x = 1] = v` parses the default as an
                // assignment expression.
                if (a.op != .assign) return self.fail("invalid destructuring default", pat.start);
                try self.bindWithDefault(a.target, a.value, src, mode);
            },
            .array_pattern => |elems| try self.bindArrayPattern(elems, src, mode),
            .array_literal => |elems| try self.bindArrayPattern(elems, src, mode),
            .object_pattern => |props| try self.bindObjectPattern(props, src, mode),
            .object_literal => |props| try self.bindObjectPattern(props, src, mode),
            else => return self.fail("unsupported destructuring target", pat.start),
        }
    }

    fn compileVarDecl(self: *Compiler, vd: anytype) CompileError!void {
        const lexical = vd.kind != .keyword_var;
        for (vd.decls) |d| {
            const decl = d.kind.variable_declarator;
            if (decl.id.kind != .ident) {
                const init_expr = decl.init orelse return self.fail("destructuring declaration requires an initializer", decl.id.start);
                const r = try self.compileExprToNew(init_expr);
                const pmode: BindMode = if (vd.kind == .keyword_const) .decl_const else if (lexical) .decl_lexical else .decl_var;
                try self.compilePatternBind(decl.id, r, pmode);
                self.freeTo(r);
                continue;
            }
            const name = decl.id.kind.ident;
            // Top-level `var` targets the global object (ensure_global made the
            // property; init writes through it). No initializer -> already
            // undefined, nothing to emit.
            if (vd.kind == .keyword_var and self.atScriptTop()) {
                if (decl.init) |init_expr| {
                    const r = try self.compileExprToNew(init_expr);
                    const idx = try self.addConst(.{ .string = name });
                    if (isAnonFnLike(init_expr)) _ = try self.emit(.{ .op = .set_fn_name, .a = r, .b = idx });
                    _ = try self.emit(.{ .op = .set_global, .a = idx, .b = r });
                    self.freeTo(r);
                }
                continue;
            }
            const slot = if (vd.kind == .keyword_var)
                self.resolve(name).?.slot // already hoisted
            else blk: {
                const s = try self.declare(name);
                if (vd.kind == .keyword_const) self.markConst(name);
                break :blk s;
            };
            if (decl.init) |init_expr| {
                const r = try self.compileExprToNew(init_expr);
                // `var f = function(){}` / `= () => …` / `= class {}` names the
                // function after the binding (NamedEvaluation).
                if (isAnonFnLike(init_expr)) {
                    const idx = try self.addConst(.{ .string = name });
                    _ = try self.emit(.{ .op = .set_fn_name, .a = r, .b = idx });
                }
                // Lexical declarations write through init_var, which clears TDZ.
                _ = try self.emit(.{ .op = if (lexical) .init_var else .set_var, .a = 0, .b = slot, .c = r });
                self.freeTo(r);
            } else if (lexical) {
                // `let x;` initializes to undefined (ends the dead zone).
                const r = self.allocReg();
                _ = try self.emit(.{ .op = .load_undefined, .a = r });
                _ = try self.emit(.{ .op = .init_var, .a = 0, .b = slot, .c = r });
                self.freeTo(r);
            }
        }
    }

    /// True when a statement list's directive prologue (leading string-literal
    /// expression statements) contains "use strict".
    fn hasUseStrictDirective(stmts: []*Node) bool {
        for (stmts) |stmt| {
            if (stmt.kind != .expression_stmt) return false;
            const e = stmt.kind.expression_stmt;
            if (e.kind != .string) return false;
            const raw = e.kind.string;
            if (std.mem.eql(u8, raw, "\"use strict\"") or std.mem.eql(u8, raw, "'use strict'")) return true;
        }
        return false;
    }

    /// Pre-declare a statement list's `let`/`const` bindings and mark their
    /// slots dead (TDZ) at block entry; the declaration statement later
    /// initializes them via `init_var`.
    fn declareLexicals(self: *Compiler, stmts: []*Node) CompileError!void {
        for (stmts) |stmt| {
            if (stmt.kind != .var_decl) continue;
            const vd = stmt.kind.var_decl;
            if (vd.kind == .keyword_var) continue;
            for (vd.decls) |d| {
                const decl = d.kind.variable_declarator;
                if (decl.id.kind != .ident) continue; // destructuring rejected later
                const slot = try self.declare(decl.id.kind.ident);
                if (vd.kind == .keyword_const) self.markConst(decl.id.kind.ident);
                _ = try self.emit(.{ .op = .set_dead, .a = 0, .b = slot });
            }
        }
    }

    fn compileIf(self: *Compiler, s: anytype) CompileError!void {
        const c = try self.compileExprToNew(s.cond);
        const jf = try self.emit(.{ .op = .jump_if_false, .a = c });
        self.freeTo(c);
        try self.compileStmt(s.then_branch);
        if (s.else_branch) |e| {
            const jend = try self.emit(.{ .op = .jump });
            self.patchTarget(jf, self.here());
            try self.compileStmt(e);
            self.patchTarget(jend, self.here());
        } else {
            self.patchTarget(jf, self.here());
        }
    }

    const LoopKind = enum { brk, cont };

    fn compileWhile(self: *Compiler, s: anytype) CompileError!void {
        var ctx = LoopCtx{ .finally_base = self.fs.finally_stack.items.len };
        const prev_loop = self.loop;
        const prev_break = self.break_target;
        self.loop = &ctx;
        self.break_target = &ctx;
        defer self.loop = prev_loop;
        defer self.break_target = prev_break;

        const top = self.here();
        const c = try self.compileExprToNew(s.cond);
        const jf = try self.emit(.{ .op = .jump_if_false, .a = c });
        self.freeTo(c);
        try self.compileStmt(s.body);
        _ = try self.emit(.{ .op = .jump, .a = top });
        self.patchTarget(jf, self.here());
        try self.patchBreaks(&ctx, self.here());
        try self.patchContinues(&ctx, top);
    }

    fn compileDoWhile(self: *Compiler, s: anytype) CompileError!void {
        var ctx = LoopCtx{ .finally_base = self.fs.finally_stack.items.len };
        const prev_loop = self.loop;
        const prev_break = self.break_target;
        self.loop = &ctx;
        self.break_target = &ctx;
        defer self.loop = prev_loop;
        defer self.break_target = prev_break;

        const top = self.here();
        try self.compileStmt(s.body);
        const cont_target = self.here();
        const c = try self.compileExprToNew(s.cond);
        _ = try self.emit(.{ .op = .jump_if_true, .a = c, .b = top });
        self.freeTo(c);
        try self.patchBreaks(&ctx, self.here());
        try self.patchContinues(&ctx, cont_target);
    }

    fn compileFor(self: *Compiler, s: anytype) CompileError!void {
        try self.pushBlock();
        defer self.popBlock();

        if (s.init) |init_node| {
            switch (init_node.kind) {
                .var_decl => |vd| {
                    if (vd.kind != .keyword_var) {
                        for (vd.decls) |d| {
                            if (d.kind.variable_declarator.id.kind == .ident)
                                _ = try self.declare(d.kind.variable_declarator.id.kind.ident);
                        }
                    }
                    try self.compileVarDecl(vd);
                },
                else => {
                    const r = try self.compileExprToNew(init_node);
                    self.freeTo(r);
                },
            }
        }

        var ctx = LoopCtx{ .finally_base = self.fs.finally_stack.items.len };
        const prev_loop = self.loop;
        const prev_break = self.break_target;
        self.loop = &ctx;
        self.break_target = &ctx;
        defer self.loop = prev_loop;
        defer self.break_target = prev_break;

        const top = self.here();
        var jf: ?u32 = null;
        if (s.cond) |cond| {
            const c = try self.compileExprToNew(cond);
            jf = try self.emit(.{ .op = .jump_if_false, .a = c });
            self.freeTo(c);
        }
        try self.compileStmt(s.body);
        const cont_target = self.here();
        if (s.update) |u| {
            const r = try self.compileExprToNew(u);
            self.freeTo(r);
        }
        _ = try self.emit(.{ .op = .jump, .a = top });
        if (jf) |j| self.patchTarget(j, self.here());
        try self.patchBreaks(&ctx, self.here());
        try self.patchContinues(&ctx, cont_target);
    }

    /// `for (LHS in RHS) body`: enumerate the enumerable keys of RHS into an
    /// array and loop over it by index, binding each key.
    fn compileForIn(self: *Compiler, s: anytype) CompileError!void {
        try self.pushBlock();
        defer self.popBlock();

        const target = try self.forHeadTarget(s.left);

        const keys_reg = self.allocReg();
        {
            const src_reg = self.allocReg();
            try self.compileExprInto(src_reg, s.right);
            _ = try self.emit(.{ .op = .enum_keys, .a = keys_reg, .b = src_reg });
            self.freeTo(src_reg + 1);
        }
        const idx_reg = self.allocReg();
        const zero = try self.addConst(.{ .number = 0 });
        _ = try self.emit(.{ .op = .load_const, .a = idx_reg, .b = zero });

        var ctx = LoopCtx{ .finally_base = self.fs.finally_stack.items.len };
        const prev_loop = self.loop;
        const prev_break = self.break_target;
        self.loop = &ctx;
        self.break_target = &ctx;
        defer self.loop = prev_loop;
        defer self.break_target = prev_break;

        const top = self.here();
        const len_reg = self.allocReg();
        const len_name = try self.addConst(.{ .string = "length" });
        _ = try self.emit(.{ .op = .get_prop, .a = len_reg, .b = keys_reg, .c = len_name });
        const cond_reg = self.allocReg();
        _ = try self.emit(.{ .op = .ge, .a = cond_reg, .b = idx_reg, .c = len_reg });
        const jexit = try self.emit(.{ .op = .jump_if_true, .a = cond_reg });
        self.freeTo(len_reg);

        const key_reg = self.allocReg();
        _ = try self.emit(.{ .op = .get_elem, .a = key_reg, .b = keys_reg, .c = idx_reg });
        try self.emitAssignTarget(target, key_reg);
        self.freeTo(key_reg);

        try self.compileStmt(s.body);

        const cont_target = self.here();
        const one_reg = self.allocReg();
        const one = try self.addConst(.{ .number = 1 });
        _ = try self.emit(.{ .op = .load_const, .a = one_reg, .b = one });
        _ = try self.emit(.{ .op = .add, .a = idx_reg, .b = idx_reg, .c = one_reg });
        self.freeTo(one_reg);
        _ = try self.emit(.{ .op = .jump, .a = top });

        self.patchTarget(jexit, self.here());
        try self.patchBreaks(&ctx, self.here());
        try self.patchContinues(&ctx, cont_target);
        self.freeTo(keys_reg);
    }

    /// `for (LHS of RHS) body` using the iteration protocol: get an iterator
    /// via @@iterator, then loop over `iterator.next()` until `{done: true}`.
    fn compileForOf(self: *Compiler, s: anytype) CompileError!void {
        try self.pushBlock();
        defer self.popBlock();

        const target = try self.forHeadTarget(s.left);

        // iter = GetIterator(RHS)
        const iter_reg = self.allocReg();
        {
            const src_reg = self.allocReg();
            try self.compileExprInto(src_reg, s.right);
            _ = try self.emit(.{ .op = .iter_init, .a = iter_reg, .b = src_reg });
            self.freeTo(src_reg + 1); // free src_reg, keep iter_reg
        }

        var ctx = LoopCtx{ .finally_base = self.fs.finally_stack.items.len };
        const prev_loop = self.loop;
        const prev_break = self.break_target;
        self.loop = &ctx;
        self.break_target = &ctx;
        defer self.loop = prev_loop;
        defer self.break_target = prev_break;

        const top = self.here();
        // result = iter.next(); if (result.done) break
        const result_reg = self.allocReg();
        _ = try self.emit(.{ .op = .iter_next, .a = result_reg, .b = iter_reg });
        const done_reg = self.allocReg();
        const done_name = try self.addConst(.{ .string = "done" });
        _ = try self.emit(.{ .op = .get_prop, .a = done_reg, .b = result_reg, .c = done_name });
        const jexit = try self.emit(.{ .op = .jump_if_true, .a = done_reg });
        self.freeTo(result_reg + 1); // free done_reg, keep result_reg

        // loopVar = result.value
        const value_reg = self.allocReg();
        const value_name = try self.addConst(.{ .string = "value" });
        _ = try self.emit(.{ .op = .get_prop, .a = value_reg, .b = result_reg, .c = value_name });
        try self.emitAssignTarget(target, value_reg);
        self.freeTo(result_reg);

        try self.compileStmt(s.body);

        const cont_target = self.here();
        _ = try self.emit(.{ .op = .jump, .a = top });

        self.patchTarget(jexit, self.here());
        try self.patchBreaks(&ctx, self.here());
        try self.patchContinues(&ctx, cont_target);
        self.freeTo(iter_reg);
    }

    const ForTarget = union(enum) {
        local: Binding,
        global: u32, // name const index
        pattern: struct { node: *Node, mode: BindMode },
    };

    fn forHeadTarget(self: *Compiler, left: *Node) CompileError!ForTarget {
        switch (left.kind) {
            .var_decl => |vd| {
                const id = vd.decls[0].kind.variable_declarator.id;
                if (id.kind != .ident) {
                    const mode: BindMode = if (vd.kind == .keyword_var) .decl_var else .decl_lexical;
                    return .{ .pattern = .{ .node = id, .mode = mode } };
                }
                const name = id.kind.ident;
                // Top-level `for (var x of …)` binds the global property.
                if (vd.kind == .keyword_var and self.atScriptTop()) {
                    return .{ .global = try self.addConst(.{ .string = name }) };
                }
                const slot = if (vd.kind == .keyword_var) (self.resolve(name) orelse unreachable).slot else try self.declare(name);
                return .{ .local = .{ .depth = 0, .slot = slot } };
            },
            .ident => |name| {
                if (self.resolve(name)) |bind| return .{ .local = bind };
                return .{ .global = try self.addConst(.{ .string = name }) };
            },
            .array_literal, .object_literal, .array_pattern, .object_pattern => {
                return .{ .pattern = .{ .node = left, .mode = .assign } };
            },
            else => return self.fail("for-of target unsupported", left.start),
        }
    }

    fn emitAssignTarget(self: *Compiler, target: ForTarget, src: u32) CompileError!void {
        switch (target) {
            .local => |b| _ = try self.emit(.{ .op = .set_var, .a = b.depth, .b = b.slot, .c = src }),
            .global => |idx| _ = try self.emit(.{ .op = .set_global, .a = idx, .b = src }),
            .pattern => |pt| try self.compilePatternBind(pt.node, src, pt.mode),
        }
    }

    fn compileSwitch(self: *Compiler, s: anytype) CompileError!void {
        try self.pushBlock();
        defer self.popBlock();

        const disc_reg = self.allocReg();
        try self.compileExprInto(disc_reg, s.discriminant);

        var ctx = LoopCtx{ .finally_base = self.fs.finally_stack.items.len };
        const prev_break = self.break_target;
        self.break_target = &ctx;
        defer self.break_target = prev_break;

        // Comparison chain: strict-equality test per case, jump to its body.
        var case_jumps: std.ArrayList(?u32) = .empty;
        defer case_jumps.deinit(self.gpa);
        var default_index: ?usize = null;
        for (s.cases, 0..) |c, i| {
            const sc = c.kind.switch_case;
            if (sc.test_expr) |t| {
                const tmp = self.allocReg();
                try self.compileExprInto(tmp, t);
                const cmp = self.allocReg();
                _ = try self.emit(.{ .op = .strict_eq, .a = cmp, .b = disc_reg, .c = tmp });
                const jpc = try self.emit(.{ .op = .jump_if_true, .a = cmp });
                try case_jumps.append(self.gpa, jpc);
                self.freeTo(tmp);
            } else {
                default_index = i;
                try case_jumps.append(self.gpa, null);
            }
        }
        // No case matched -> jump to default (or past the switch).
        const default_jump = try self.emit(.{ .op = .jump });

        // Emit case bodies, recording each body's start pc.
        var body_starts: std.ArrayList(u32) = .empty;
        defer body_starts.deinit(self.gpa);
        for (s.cases) |c| {
            try body_starts.append(self.gpa, self.here());
            for (c.kind.switch_case.body) |stmt| try self.compileStmt(stmt);
        }
        const end_pc = self.here();

        // Patch the comparison jumps and the default jump.
        for (case_jumps.items, 0..) |maybe_jpc, i| {
            if (maybe_jpc) |jpc| self.patchTarget(jpc, body_starts.items[i]);
        }
        self.patchTarget(default_jump, if (default_index) |di| body_starts.items[di] else end_pc);
        try self.patchBreaks(&ctx, end_pc);
        self.freeTo(disc_reg);
    }

    fn compileTry(self: *Compiler, s: anytype) CompileError!void {
        // While compiling the block and catch body, the finalizer is pending:
        // any return/break/continue leaving them inlines it (emitFinalizersDownTo).
        const has_fin = s.finalizer != null;
        if (has_fin) try self.fs.finally_stack.append(self.gpa, s.finalizer.?);

        const try_start = self.here();
        try self.compileStmt(s.block);
        const try_end = self.here();
        const jover = try self.emit(.{ .op = .jump }); // normal completion

        var protect_end = try_end; // end of the region the finalizer protects
        var jover2: ?u32 = null;
        if (s.handler) |h| {
            const cc = h.kind.catch_clause;
            const catch_reg = self.allocReg();
            try self.fs.handlers.append(self.gpa, .{
                .try_start = try_start,
                .try_end = try_end,
                .target_pc = self.here(),
                .catch_reg = catch_reg,
                .kind = .catch_clause,
            });
            try self.pushBlock();
            if (cc.param) |p| {
                if (p.kind == .ident) {
                    const slot = try self.declare(p.kind.ident);
                    _ = try self.emit(.{ .op = .set_var, .a = 0, .b = slot, .c = catch_reg });
                } else {
                    try self.compilePatternBind(p, catch_reg, .decl_lexical);
                }
            }
            self.freeTo(catch_reg);
            try self.compileStmt(cc.body);
            self.popBlock();
            protect_end = self.here();
            if (has_fin) jover2 = try self.emit(.{ .op = .jump });
        }

        if (has_fin) {
            _ = self.fs.finally_stack.pop();
            // Exceptional path: a catch-all over the block *and* the catch body
            // that runs the finalizer, then rethrows. If the finalizer itself
            // completes abruptly (return/break), the rethrow never runs — the
            // finalizer's completion replaces the exception, per spec.
            const exc_reg = self.allocReg();
            try self.fs.handlers.append(self.gpa, .{
                .try_start = try_start,
                .try_end = protect_end,
                .target_pc = self.here(),
                .catch_reg = exc_reg,
                .kind = .catch_clause,
            });
            try self.compileStmt(s.finalizer.?);
            _ = try self.emit(.{ .op = .throw, .a = exc_reg });
            self.freeTo(exc_reg);
        }

        // Normal-completion landing point (block or catch fell through).
        self.patchTarget(jover, self.here());
        if (jover2) |j2| self.patchTarget(j2, self.here());
        if (has_fin) try self.compileStmt(s.finalizer.?);
    }

    // ---- loop break/continue plumbing --------------------------------------

    const LoopCtx = struct {
        breaks: std.ArrayList(u32) = .empty,
        continues: std.ArrayList(u32) = .empty,
        /// finally_stack depth when this loop/switch began: a break/continue
        /// targeting it inlines the finalizers pushed since.
        finally_base: usize = 0,
    };

    fn emitLoopJump(self: *Compiler, kind: LoopKind, pos: u32) CompileError!void {
        switch (kind) {
            .brk => {
                const ctx = self.break_target orelse return self.fail("break outside loop or switch", pos);
                try self.emitFinalizersDownTo(ctx.finally_base);
                const pc = try self.emit(.{ .op = .jump });
                try ctx.breaks.append(self.gpa, pc);
            },
            .cont => {
                const ctx = self.loop orelse return self.fail("continue outside loop", pos);
                try self.emitFinalizersDownTo(ctx.finally_base);
                const pc = try self.emit(.{ .op = .jump });
                try ctx.continues.append(self.gpa, pc);
            },
        }
    }
    fn patchBreaks(self: *Compiler, ctx: *LoopCtx, target: u32) CompileError!void {
        for (ctx.breaks.items) |pc| self.patchTarget(pc, target);
        ctx.breaks.deinit(self.gpa);
    }
    fn patchContinues(self: *Compiler, ctx: *LoopCtx, target: u32) CompileError!void {
        for (ctx.continues.items) |pc| self.patchTarget(pc, target);
        ctx.continues.deinit(self.gpa);
    }

    // ---- expressions -------------------------------------------------------

    fn compileExprToNew(self: *Compiler, node: *Node) CompileError!u32 {
        const dst = self.allocReg();
        try self.compileExprInto(dst, node);
        return dst;
    }

    fn compileExprInto(self: *Compiler, dst: u32, node: *Node) CompileError!void {
        switch (node.kind) {
            .number => |n| {
                if (n.bigint) {
                    // Strip the trailing `n`; the VM parses the digits at
                    // constant-materialization time (arbitrary precision).
                    const digits = if (std.mem.endsWith(u8, n.raw, "n")) n.raw[0 .. n.raw.len - 1] else n.raw;
                    const idx = try self.addConst(.{ .bigint = digits });
                    _ = try self.emit(.{ .op = .load_const, .a = dst, .b = idx });
                    return;
                }
                const val = parseNumber(n.raw) catch return self.fail("invalid number", node.start);
                const idx = try self.addConst(.{ .number = val });
                _ = try self.emit(.{ .op = .load_const, .a = dst, .b = idx });
            },
            .string => |raw| {
                const cooked = try self.cookString(raw);
                const idx = try self.addConst(.{ .string = cooked });
                _ = try self.emit(.{ .op = .load_const, .a = dst, .b = idx });
            },
            .bool_literal => |b| _ = try self.emit(.{ .op = if (b) .load_true else .load_false, .a = dst }),
            .null_literal => _ = try self.emit(.{ .op = .load_null, .a = dst }),
            .this_expr => _ = try self.emit(.{ .op = .load_this, .a = dst }),
            .ident => |name| try self.compileIdentLoad(dst, name, node.start),
            .binary => |b| try self.compileBinary(dst, b),
            .logical => |b| try self.compileLogical(dst, b),
            .unary => |u| try self.compileUnary(dst, u, node.start),
            .update => |u| try self.compileUpdate(dst, u, node.start),
            .assignment => |a| try self.compileAssignment(dst, a, node.start),
            .conditional => |c| try self.compileConditional(dst, c),
            .member => |m| try self.compileMemberLoad(dst, m),
            .new_expr => |n| try self.compileNew(dst, n, node.start),
            .object_literal => |props| try self.compileObjectLiteral(dst, props, node.start),
            .array_literal => |elems| try self.compileArrayLiteral(dst, elems, node.start),
            .regex => |raw| try self.compileRegexLiteral(dst, raw),
            .sequence => |exprs| {
                for (exprs, 0..) |e, i| {
                    if (i + 1 < exprs.len) {
                        const r = try self.compileExprToNew(e);
                        self.freeTo(r);
                    } else try self.compileExprInto(dst, e);
                }
            },
            .call => |c| try self.compileCall(dst, c, node.start),
            .function => |f| try self.compileFunctionExpr(dst, f),
            .template => |t| try self.compileTemplate(dst, t),
            .tagged_template => |tt| try self.compileTaggedTemplate(dst, tt),
            .class => |cls| try self.compileClass(dst, cls, node.start),
            .yield_expr => |y| try self.compileYield(dst, y),
            // `await x` suspends the async frame exactly like a yield; the
            // async driver (callAsyncFunction) interprets the suspension as an
            // Await rather than an iterator step.
            .await_expr => |operand| {
                if (!self.fs.is_async) return self.fail("await outside an async function", node.start);
                const val_reg = self.allocReg();
                try self.compileExprInto(val_reg, operand);
                _ = try self.emit(.{ .op = .gen_yield, .a = dst, .b = val_reg });
                self.freeTo(val_reg);
            },
            // `new.target`. Only modelled inside a direct eval (as undefined,
            // which is correct for the method/field-initializer contexts these
            // tests use). Elsewhere it's left unsupported so real new-target
            // value semantics stay a declined compile-gap, not a wrong pass.
            // At an eval root that isn't a function (indirect eval) it's a
            // SyntaxError.
            .meta_property => {
                if (!self.eval_compile) return self.fail("new.target value is not supported", node.start);
                if (!self.fs.new_target_allowed) return self.fail("new.target is only valid inside functions", node.start);
                _ = try self.emit(.{ .op = .load_undefined, .a = dst });
            },
            else => return self.fail("unsupported expression", node.start),
        }
    }

    fn compileIdentLoad(self: *Compiler, dst: u32, name: []const u8, pos: u32) CompileError!void {
        _ = pos;
        if (std.mem.eql(u8, name, "undefined")) {
            _ = try self.emit(.{ .op = .load_undefined, .a = dst });
            return;
        }
        if (self.resolve(name)) |bind| {
            _ = try self.emit(.{ .op = .get_var, .a = dst, .b = bind.depth, .c = bind.slot });
        } else {
            // Free identifier -> a property of the global object.
            const idx = try self.addConst(.{ .string = name });
            _ = try self.emit(.{ .op = .get_global, .a = dst, .b = idx });
        }
    }

    fn compileBinary(self: *Compiler, dst: u32, b: anytype) CompileError!void {
        // `#x in obj`: an ergonomic brand check, not a normal `in`.
        if (b.op == .kw_in and b.left.kind == .private_name) {
            const objreg = self.allocReg();
            try self.compileExprInto(objreg, b.right);
            const pk = try self.privateKeyConst(b.left.kind.private_name, b.left.start);
            _ = try self.emit(.{ .op = .has_private, .a = dst, .b = objreg, .c = pk });
            self.freeTo(objreg);
            return;
        }
        const rhs = self.allocReg();
        try self.compileExprInto(dst, b.left);
        try self.compileExprInto(rhs, b.right);
        const op = binaryOpcode(b.op) orelse return self.fail("unsupported binary operator", 0);
        _ = try self.emit(.{ .op = op, .a = dst, .b = dst, .c = rhs });
        self.freeTo(rhs);
    }

    fn compileLogical(self: *Compiler, dst: u32, b: anytype) CompileError!void {
        try self.compileExprInto(dst, b.left);
        const jump_op: Op = switch (b.op) {
            .amp_amp => .jump_if_false,
            .pipe_pipe => .jump_if_true,
            .question_question => .jump_if_not_nullish,
            else => return self.fail("unsupported logical operator", 0),
        };
        const j = try self.emit(.{ .op = jump_op, .a = dst });
        try self.compileExprInto(dst, b.right);
        self.patchTarget(j, self.here());
    }

    fn compileUnary(self: *Compiler, dst: u32, u: anytype, pos: u32) CompileError!void {
        if (u.op == .kw_delete) return self.compileDelete(dst, u.operand);
        // `typeof <free identifier>` must yield "undefined", not ReferenceError.
        if (u.op == .kw_typeof and u.operand.kind == .ident) {
            const name = u.operand.kind.ident;
            if (!std.mem.eql(u8, name, "undefined") and self.resolve(name) == null) {
                const idx = try self.addConst(.{ .string = name });
                _ = try self.emit(.{ .op = .get_global_typeof, .a = dst, .b = idx });
                _ = try self.emit(.{ .op = .type_of, .a = dst, .b = dst });
                return;
            }
        }
        try self.compileExprInto(dst, u.operand);
        const op: Op = switch (u.op) {
            .minus => .neg,
            .plus => .to_number,
            .bang => .logical_not,
            .tilde => .bit_not,
            .kw_typeof => .type_of,
            .kw_void => {
                _ = try self.emit(.{ .op = .load_undefined, .a = dst });
                return;
            },
            else => return self.fail("unsupported unary operator", pos),
        };
        _ = try self.emit(.{ .op = op, .a = dst, .b = dst });
    }

    /// `delete obj.prop` / `delete obj[expr]`. Deleting a non-member reference
    /// (e.g. a plain identifier) evaluates to `true` (a Phase-4 simplification;
    /// sloppy-mode `delete x` on a declared binding should be `false`).
    fn compileDelete(self: *Compiler, dst: u32, operand: *Node) CompileError!void {
        if (operand.kind == .member and !operand.kind.member.optional) {
            const m = operand.kind.member;
            const obj_reg = self.allocReg();
            try self.compileExprInto(obj_reg, m.object);
            if (m.computed) {
                const key_reg = self.allocReg();
                try self.compileExprInto(key_reg, m.property);
                _ = try self.emit(.{ .op = .delete_elem, .a = dst, .b = obj_reg, .c = key_reg });
            } else {
                const name_idx = try self.propNameConst(m.property);
                _ = try self.emit(.{ .op = .delete_prop, .a = dst, .b = obj_reg, .c = name_idx });
            }
            self.freeTo(obj_reg);
            return;
        }
        _ = try self.emit(.{ .op = .load_true, .a = dst });
    }

    fn compileUpdate(self: *Compiler, dst: u32, u: anytype, pos: u32) CompileError!void {
        if (u.operand.kind == .member) return self.compileMemberUpdate(dst, u);
        if (u.operand.kind != .ident) return self.fail("update target must be an identifier", pos);
        const name = u.operand.kind.ident;
        const bind = self.resolve(name);
        // A free identifier updates the corresponding global property.
        const gidx: ?u32 = if (bind == null) try self.addConst(.{ .string = name }) else null;
        const one = try self.addConst(.{ .number = 1 });

        // Load current value into dst.
        if (bind) |b| {
            _ = try self.emit(.{ .op = .get_var, .a = dst, .b = b.depth, .c = b.slot });
        } else {
            _ = try self.emit(.{ .op = .get_global, .a = dst, .b = gidx.? });
        }
        const delta = self.allocReg();
        if (u.prefix) {
            _ = try self.emit(.{ .op = .load_const, .a = delta, .b = one });
            _ = try self.emit(.{ .op = if (u.op == .plus_plus) .add else .sub, .a = dst, .b = dst, .c = delta });
            try self.emitUpdateStore(bind, gidx, dst);
        } else {
            // Postfix: dst keeps the old (numeric) value; compute new separately.
            _ = try self.emit(.{ .op = .to_number, .a = dst, .b = dst });
            const newv = self.allocReg();
            _ = try self.emit(.{ .op = .load_const, .a = delta, .b = one });
            _ = try self.emit(.{ .op = if (u.op == .plus_plus) .add else .sub, .a = newv, .b = dst, .c = delta });
            try self.emitUpdateStore(bind, gidx, newv);
            self.freeTo(newv);
        }
        self.freeTo(delta);
    }

    fn emitUpdateStore(self: *Compiler, bind: ?Binding, gidx: ?u32, src: u32) CompileError!void {
        if (bind) |b| {
            if (b.is_const) {
                const midx = try self.addConst(.{ .string = "assignment to constant variable" });
                _ = try self.emit(.{ .op = .throw_type_error, .a = midx });
                return;
            }
            _ = try self.emit(.{ .op = .set_var, .a = b.depth, .b = b.slot, .c = src });
        } else {
            _ = try self.emit(.{ .op = .set_global, .a = gidx.?, .b = src });
        }
    }

    /// `obj.p++` / `--obj.p` etc., including private members. The object and
    /// key are evaluated once; `dst` receives the expression's value.
    fn compileMemberUpdate(self: *Compiler, dst: u32, u: anytype) CompileError!void {
        const m = u.operand.kind.member;
        const objreg = self.allocReg();
        try self.compileExprInto(objreg, m.object);
        const key: MemberKey = if (m.property.kind == .private_name)
            .{ .private = try self.privateKeyConst(m.property.kind.private_name, m.property.start) }
        else if (m.computed) blk: {
            const keyreg = self.allocReg();
            try self.compileExprInto(keyreg, m.property);
            break :blk MemberKey{ .computed = keyreg };
        } else .{ .named = try self.propNameConst(m.property) };

        const one = try self.addConst(.{ .number = 1 });
        const cur = self.allocReg();
        try self.emitMemberGet(cur, objreg, key);
        _ = try self.emit(.{ .op = .to_number, .a = cur, .b = cur });
        const delta = self.allocReg();
        _ = try self.emit(.{ .op = .load_const, .a = delta, .b = one });
        const newv = self.allocReg();
        _ = try self.emit(.{ .op = if (u.op == .plus_plus) .add else .sub, .a = newv, .b = cur, .c = delta });
        try self.emitMemberSet(objreg, key, newv);
        // Prefix yields the new value; postfix the old (already ToNumber'd).
        _ = try self.emit(.{ .op = .move, .a = dst, .b = if (u.prefix) newv else cur });
        self.freeTo(objreg);
    }

    fn compileAssignment(self: *Compiler, dst: u32, a: anytype, pos: u32) CompileError!void {
        if (a.target.kind == .member) {
            return self.compileMemberStore(dst, a, pos);
        }
        switch (a.target.kind) {
            .array_literal, .object_literal, .array_pattern, .object_pattern => {
                if (a.op != .assign) return self.fail("destructuring requires plain assignment", pos);
                try self.compileExprInto(dst, a.value);
                try self.compilePatternBind(a.target, dst, .assign);
                return;
            },
            else => {},
        }
        if (a.target.kind != .ident) return self.fail("assignment target must be an identifier or member", pos);
        const name = a.target.kind.ident;

        if (self.resolve(name)) |bind| {
            if (a.op == .assign) {
                try self.compileExprInto(dst, a.value);
                if (isAnonFnLike(a.value)) {
                    const nidx = try self.addConst(.{ .string = name });
                    _ = try self.emit(.{ .op = .set_fn_name, .a = dst, .b = nidx });
                }
            } else {
                _ = try self.emit(.{ .op = .get_var, .a = dst, .b = bind.depth, .c = bind.slot });
                const rhs = self.allocReg();
                try self.compileExprInto(rhs, a.value);
                const op = compoundOpcode(a.op) orelse return self.fail("unsupported assignment operator", pos);
                _ = try self.emit(.{ .op = op, .a = dst, .b = dst, .c = rhs });
                self.freeTo(rhs);
            }
            // Assignment to a `const` binding: the RHS still evaluates (spec
            // order), then the write itself throws.
            if (bind.is_const) {
                const midx = try self.addConst(.{ .string = "assignment to constant variable" });
                _ = try self.emit(.{ .op = .throw_type_error, .a = midx });
                return;
            }
            _ = try self.emit(.{ .op = .set_var, .a = bind.depth, .b = bind.slot, .c = dst });
        } else {
            // Free identifier -> global property.
            const idx = try self.addConst(.{ .string = name });
            if (a.op == .assign) {
                try self.compileExprInto(dst, a.value);
                if (isAnonFnLike(a.value)) _ = try self.emit(.{ .op = .set_fn_name, .a = dst, .b = idx });
            } else {
                _ = try self.emit(.{ .op = .get_global, .a = dst, .b = idx });
                const rhs = self.allocReg();
                try self.compileExprInto(rhs, a.value);
                const op = compoundOpcode(a.op) orelse return self.fail("unsupported assignment operator", pos);
                _ = try self.emit(.{ .op = op, .a = dst, .b = dst, .c = rhs });
                self.freeTo(rhs);
            }
            _ = try self.emit(.{ .op = .set_global, .a = idx, .b = dst });
        }
    }

    /// How a member's key is addressed, so a get/set pair can share it.
    const MemberKey = union(enum) {
        private: u32, // private-key const index
        computed: u32, // register holding the evaluated key
        named: u32, // property-name const index
    };

    fn emitMemberGet(self: *Compiler, dst: u32, objreg: u32, key: MemberKey) CompileError!void {
        _ = try self.emit(switch (key) {
            .private => |c| .{ .op = .get_private, .a = dst, .b = objreg, .c = c },
            .computed => |r| .{ .op = .get_elem, .a = dst, .b = objreg, .c = r },
            .named => |c| .{ .op = .get_prop, .a = dst, .b = objreg, .c = c },
        });
    }

    fn emitMemberSet(self: *Compiler, objreg: u32, key: MemberKey, src: u32) CompileError!void {
        _ = try self.emit(switch (key) {
            .private => |c| .{ .op = .set_private, .a = objreg, .b = c, .c = src },
            .computed => |r| .{ .op = .set_elem, .a = objreg, .b = r, .c = src },
            .named => |c| .{ .op = .set_prop, .a = objreg, .b = c, .c = src },
        });
    }

    fn compileMemberStore(self: *Compiler, dst: u32, a: anytype, pos: u32) CompileError!void {
        _ = pos;
        const m = a.target.kind.member;
        const objreg = self.allocReg();
        try self.compileExprInto(objreg, m.object);
        const key: MemberKey = if (m.property.kind == .private_name)
            .{ .private = try self.privateKeyConst(m.property.kind.private_name, m.property.start) }
        else if (m.computed) blk: {
            const keyreg = self.allocReg();
            try self.compileExprInto(keyreg, m.property);
            break :blk MemberKey{ .computed = keyreg };
        } else .{ .named = try self.propNameConst(m.property) };

        if (a.op == .assign) {
            try self.compileExprInto(dst, a.value);
        } else {
            // `obj.p op= v`: read, combine, write back (obj/key evaluated once).
            try self.emitMemberGet(dst, objreg, key);
            const rhs = self.allocReg();
            try self.compileExprInto(rhs, a.value);
            const op = compoundOpcode(a.op) orelse return self.fail("unsupported assignment operator", m.object.start);
            _ = try self.emit(.{ .op = op, .a = dst, .b = dst, .c = rhs });
            self.freeTo(rhs);
        }
        try self.emitMemberSet(objreg, key, dst);
        self.freeTo(objreg);
    }

    fn compileMemberLoad(self: *Compiler, dst: u32, m: anytype) CompileError!void {
        if (m.optional) return self.fail("optional chaining unsupported", 0);
        const objreg = self.allocReg();
        if (m.object.kind == .super_expr) {
            // super.x reads from the parent prototype.
            const sp = self.resolve("\x00super_proto") orelse return self.fail("'super' outside a class method", m.object.start);
            _ = try self.emit(.{ .op = .get_var, .a = objreg, .b = sp.depth, .c = sp.slot });
        } else try self.compileExprInto(objreg, m.object);
        if (m.property.kind == .private_name) {
            const pk = try self.privateKeyConst(m.property.kind.private_name, m.property.start);
            _ = try self.emit(.{ .op = .get_private, .a = dst, .b = objreg, .c = pk });
        } else if (m.computed) {
            const keyreg = self.allocReg();
            try self.compileExprInto(keyreg, m.property);
            _ = try self.emit(.{ .op = .get_elem, .a = dst, .b = objreg, .c = keyreg });
        } else {
            const name_idx = try self.propNameConst(m.property);
            _ = try self.emit(.{ .op = .get_prop, .a = dst, .b = objreg, .c = name_idx });
        }
        self.freeTo(objreg);
    }

    fn compileNew(self: *Compiler, dst: u32, n: anytype, pos: u32) CompileError!void {
        const base = self.allocReg();
        try self.compileExprInto(base, n.callee);
        for (n.args) |arg| {
            if (arg.kind == .spread) return self.fail("spread arguments unsupported", pos);
            const ar = self.allocReg();
            try self.compileExprInto(ar, arg);
        }
        _ = try self.emit(.{ .op = .construct, .a = dst, .b = base, .c = @intCast(n.args.len) });
        self.freeTo(base);
    }

    /// A `/pattern/flags` literal → `new_regex` with the pattern and flag
    /// strings. Flags are the trailing ASCII letters; the char before them is
    /// the closing delimiter.
    fn compileRegexLiteral(self: *Compiler, dst: u32, raw: []const u8) CompileError!void {
        var end = raw.len;
        while (end > 0 and isRegexFlagChar(raw[end - 1])) end -= 1;
        // raw[end-1] is the closing '/'; pattern is between the delimiters.
        const pattern = if (end >= 2) raw[1 .. end - 1] else "";
        const flags = raw[end..];
        const src_idx = try self.addConst(.{ .string = pattern });
        const flags_idx = try self.addConst(.{ .string = flags });
        _ = try self.emit(.{ .op = .new_regex, .a = dst, .b = src_idx, .c = flags_idx });
    }

    fn compileArrayLiteral(self: *Compiler, dst: u32, elems: []?*Node, pos: u32) CompileError!void {
        _ = pos;
        var has_spread = false;
        for (elems) |maybe| {
            if (maybe) |e| if (e.kind == .spread) {
                has_spread = true;
            };
        }

        if (!has_spread) {
            // Fast path: fixed length, indexed stores.
            _ = try self.emit(.{ .op = .new_array, .a = dst, .b = @intCast(elems.len) });
            for (elems, 0..) |maybe, i| {
                const elem = maybe orelse continue; // elision -> leave the hole
                const idx_reg = self.allocReg();
                const idx_const = try self.addConst(.{ .number = @floatFromInt(i) });
                _ = try self.emit(.{ .op = .load_const, .a = idx_reg, .b = idx_const });
                const val_reg = self.allocReg();
                try self.compileExprInto(val_reg, elem);
                _ = try self.emit(.{ .op = .set_elem, .a = dst, .b = idx_reg, .c = val_reg });
                self.freeTo(idx_reg);
            }
            return;
        }

        // Spread path: build by appending.
        _ = try self.emit(.{ .op = .new_array, .a = dst, .b = 0 });
        for (elems) |maybe| {
            const r = self.allocReg();
            if (maybe) |elem| {
                if (elem.kind == .spread) {
                    try self.compileExprInto(r, elem.kind.spread);
                    _ = try self.emit(.{ .op = .arr_spread, .a = dst, .b = r });
                } else {
                    try self.compileExprInto(r, elem);
                    _ = try self.emit(.{ .op = .arr_push, .a = dst, .b = r });
                }
            } else {
                _ = try self.emit(.{ .op = .load_undefined, .a = r }); // elision -> undefined
                _ = try self.emit(.{ .op = .arr_push, .a = dst, .b = r });
            }
            self.freeTo(r);
        }
    }

    /// Emit `Object.defineProperty(target, key, { get/set: fr, configurable,
    /// enumerable })` — used for class accessors (non-enumerable) and object
    /// literal accessors (enumerable).
    fn emitDefineAccessor(self: *Compiler, target: u32, prop: ast.Property, fr: u32, enumerable: bool) CompileError!void {
        const base = self.allocReg(); // receiver = Object
        const obj_idx = try self.addConst(.{ .string = "Object" });
        _ = try self.emit(.{ .op = .get_global, .a = base, .b = obj_idx });
        const callee = self.allocReg();
        const dp_idx = try self.addConst(.{ .string = "defineProperty" });
        _ = try self.emit(.{ .op = .get_prop, .a = callee, .b = base, .c = dp_idx });
        const arg0 = self.allocReg();
        _ = try self.emit(.{ .op = .move, .a = arg0, .b = target });
        const arg1 = self.allocReg();
        if (prop.computed) {
            try self.compileExprInto(arg1, prop.key);
        } else {
            const idx = try self.propNameConst(prop.key);
            _ = try self.emit(.{ .op = .load_const, .a = arg1, .b = idx });
        }
        const arg2 = self.allocReg();
        _ = try self.emit(.{ .op = .new_object, .a = arg2 });
        const acc_idx = try self.addConst(.{ .string = if (prop.kind == .get) "get" else "set" });
        _ = try self.emit(.{ .op = .set_prop, .a = arg2, .b = acc_idx, .c = fr });
        const tr = self.allocReg();
        _ = try self.emit(.{ .op = .load_true, .a = tr });
        const conf_idx = try self.addConst(.{ .string = "configurable" });
        _ = try self.emit(.{ .op = .set_prop, .a = arg2, .b = conf_idx, .c = tr });
        if (enumerable) {
            const enum_idx = try self.addConst(.{ .string = "enumerable" });
            _ = try self.emit(.{ .op = .set_prop, .a = arg2, .b = enum_idx, .c = tr });
        }
        self.freeTo(tr);
        const res = self.allocReg();
        _ = try self.emit(.{ .op = .call, .a = res, .b = base, .c = 3 });
        self.freeTo(base);
    }

    fn compileObjectLiteral(self: *Compiler, dst: u32, props: []*Node, pos: u32) CompileError!void {
        _ = try self.emit(.{ .op = .new_object, .a = dst });
        for (props) |p| {
            const prop = p.kind.property;
            switch (prop.kind) {
                .spread => {
                    // { ...expr }: copy own enumerable props; nullish is a no-op.
                    const sreg = self.allocReg();
                    try self.compileExprInto(sreg, prop.key);
                    const jskip = try self.emit(.{ .op = .jump_if_nullish, .a = sreg });
                    const und = self.allocReg();
                    _ = try self.emit(.{ .op = .load_undefined, .a = und }); // no exclusions
                    _ = try self.emit(.{ .op = .copy_rest, .a = dst, .b = sreg, .c = und });
                    self.patchTarget(jskip, self.here());
                    self.freeTo(sreg);
                    continue;
                },
                .get, .set => {
                    const fnode = prop.value orelse return self.fail("malformed accessor", pos);
                    if (fnode.kind != .function) return self.fail("malformed accessor", pos);
                    const f = fnode.kind.function;
                    const name = try self.functionNameFor(prop);
                    const child = try self.compileFunction(name, f.params, f.body, false, false, false, false, false, &.{}, false, self.fs);
                    const child_idx: u32 = @intCast(self.fs.children.items.len);
                    try self.fs.children.append(self.gpa, child);
                    const fr = self.allocReg();
                    _ = try self.emit(.{ .op = .new_closure, .a = fr, .b = child_idx });
                    try self.emitDefineAccessor(dst, prop, fr, true);
                    self.freeTo(fr);
                    continue;
                },
                .init, .method => {},
            }
            const value = prop.value orelse return self.fail("invalid object property", pos);
            if (prop.computed) {
                const keyreg = self.allocReg();
                try self.compileExprInto(keyreg, prop.key);
                const valreg = self.allocReg();
                try self.compileExprInto(valreg, value);
                _ = try self.emit(.{ .op = .set_elem, .a = dst, .b = keyreg, .c = valreg });
                self.freeTo(keyreg);
            } else {
                const name_idx = try self.propNameConst(prop.key);
                const valreg = self.allocReg();
                try self.compileExprInto(valreg, value);
                // A method, or an anonymous function/arrow/class value, takes
                // the property name (NamedEvaluation / MethodDefinition).
                if (prop.kind == .method or isAnonFnLike(value)) {
                    _ = try self.emit(.{ .op = .set_fn_name, .a = valreg, .b = name_idx });
                }
                _ = try self.emit(.{ .op = .set_prop, .a = dst, .b = name_idx, .c = valreg });
                self.freeTo(valreg);
            }
        }
    }

    /// A constant-pool index for a non-computed property name.
    fn propNameConst(self: *Compiler, key: *Node) CompileError!u32 {
        const name: []const u8 = switch (key.kind) {
            .ident => |n| n,
            .private_name => |n| n,
            .string => |raw| try self.cookString(raw),
            .number => |num| num.raw,
            else => return self.fail("unsupported property key", key.start),
        };
        return self.addConst(.{ .string = name });
    }

    /// True for expressions that produce an anonymous function object eligible
    /// for NamedEvaluation: `function(){}`, `() => …`, `class {}`.
    fn isAnonFnLike(node: *Node) bool {
        return switch (node.kind) {
            .function => |f| f.name == null,
            .class => |c| c.name == null,
            else => false,
        };
    }

    /// The `.name` a class/object member's function should carry: the static
    /// key text, with a `get `/`set ` prefix for accessors. Computed keys and
    /// symbols yield "" (NamedEvaluation would set those at run time).
    fn functionNameFor(self: *Compiler, prop: ast.Property) CompileError![]const u8 {
        if (prop.computed) return "";
        const base: []const u8 = switch (prop.key.kind) {
            .ident => |n| n,
            .private_name => |n| n, // includes the leading '#'
            .string => |raw| try self.cookString(raw),
            .number => |num| num.raw,
            else => return "",
        };
        return switch (prop.kind) {
            .get => try std.fmt.allocPrint(self.arena, "get {s}", .{base}),
            .set => try std.fmt.allocPrint(self.arena, "set {s}", .{base}),
            else => base,
        };
    }

    // ---- private class members ---------------------------------------------

    /// The hidden run-time key for a private name, unique per class body.
    /// Encoded `\x00P<classid>\x00#name`; the NUL prefix keeps it out of
    /// enumeration and ordinary property access.
    fn makePrivateKey(self: *Compiler, class_id: u32, name: []const u8) CompileError![]const u8 {
        return std.fmt.allocPrint(self.arena, "\x00P{d}\x00{s}", .{ class_id, name });
    }

    /// Resolve `#name` to its hidden key, searching enclosing class scopes.
    /// A private name with no declaring class in scope is an early error.
    fn resolvePrivate(self: *Compiler, name: []const u8, pos: u32) CompileError![]const u8 {
        var i = self.private_scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.private_scopes.items[i].names.get(name)) |key| return key;
        }
        return self.fail("private name is not defined in an enclosing class", pos);
    }

    fn privateKeyConst(self: *Compiler, name: []const u8, pos: u32) CompileError!u32 {
        return self.addConst(.{ .string = try self.resolvePrivate(name, pos) });
    }

    /// Whether `prop` is a private member (its key is a `#name`).
    fn isPrivateMember(prop: ast.Property) bool {
        return prop.key.kind == .private_name;
    }

    /// A synthetic `.ident` node (for compiler-generated AST like the default
    /// constructor's `super(...args)`).
    fn makeIdentNode(self: *Compiler, name: []const u8, pos: u32) CompileError!*Node {
        const n = try self.arena.create(Node);
        n.* = .{ .start = pos, .end = pos, .kind = .{ .ident = name } };
        return n;
    }

    /// Install one private instance method/accessor on the receiver in `thisr`
    /// (constructor prologue). The closure captures the constructor's scope, so
    /// it sees enclosing private names and `super`.
    fn emitInstancePrivateMember(self: *Compiler, thisr: u32, prop: ast.Property, start: u32) CompileError!void {
        const fnode = prop.value orelse return self.fail("malformed private member", start);
        if (fnode.kind != .function) return self.fail("malformed private member", start);
        const f = fnode.kind.function;
        const child = try self.compileFunction(try self.functionNameFor(prop), f.params, f.body, false, f.flags.is_generator, f.flags.is_async, false, true, &.{}, false, self.fs);
        const child_idx: u32 = @intCast(self.fs.children.items.len);
        try self.fs.children.append(self.gpa, child);
        const fr = self.allocReg();
        _ = try self.emit(.{ .op = .new_closure, .a = fr, .b = child_idx });
        const pk = try self.privateKeyConst(prop.key.kind.private_name, start);
        _ = try self.emit(.{ .op = switch (prop.kind) {
            .method => .def_pmethod,
            .get => .def_pget,
            .set => .def_pset,
            else => return self.fail("unsupported private member", start),
        }, .a = thisr, .b = pk, .c = fr });
        self.freeTo(fr);
    }

    /// Install a constructor's instance elements on `this`: private
    /// methods/accessors first (so field initializers can call them), then
    /// public/private fields in source order. Used at the prologue for base
    /// constructors and just after `super(...)` returns for derived ones.
    fn emitInstanceElements(self: *Compiler, class_fields: []const *Node) CompileError!void {
        if (class_fields.len == 0) return;
        const thisr = self.allocReg();
        _ = try self.emit(.{ .op = .load_this, .a = thisr });
        for (class_fields) |fp| {
            const prop = fp.kind.property;
            if (prop.kind == .init) continue; // fields: second pass
            try self.emitInstancePrivateMember(thisr, prop, fp.start);
        }
        for (class_fields) |fp| {
            const prop = fp.kind.property;
            if (prop.kind != .init) continue; // methods/accessors: first pass
            const vreg = self.allocReg();
            if (prop.value) |init_expr| {
                try self.compileExprInto(vreg, init_expr);
            } else {
                _ = try self.emit(.{ .op = .load_undefined, .a = vreg });
            }
            if (isPrivateMember(prop)) {
                _ = try self.emit(.{ .op = .def_pfield, .a = thisr, .b = try self.privateKeyConst(prop.key.kind.private_name, fp.start), .c = vreg });
            } else if (prop.computed) {
                const k = self.allocReg();
                try self.compileExprInto(k, prop.key);
                _ = try self.emit(.{ .op = .set_elem, .a = thisr, .b = k, .c = vreg });
            } else {
                const idx = try self.propNameConst(prop.key);
                _ = try self.emit(.{ .op = .set_prop, .a = thisr, .b = idx, .c = vreg });
            }
            self.freeTo(vreg);
        }
        self.freeTo(thisr);
    }

    fn compileConditional(self: *Compiler, dst: u32, c: anytype) CompileError!void {
        const cr = self.allocReg();
        try self.compileExprInto(cr, c.cond);
        const jf = try self.emit(.{ .op = .jump_if_false, .a = cr });
        self.freeTo(cr);
        try self.compileExprInto(dst, c.then_expr);
        const jend = try self.emit(.{ .op = .jump });
        self.patchTarget(jf, self.here());
        try self.compileExprInto(dst, c.else_expr);
        self.patchTarget(jend, self.here());
    }

    fn compileCall(self: *Compiler, dst: u32, c: anytype, pos: u32) CompileError!void {
        if (c.optional) return self.fail("optional call unsupported", pos);
        var has_spread = false;
        for (c.args) |arg| {
            if (arg.kind == .spread) has_spread = true;
        }

        // Direct eval: `eval(x)` where `eval` is not a local binding runs `x`
        // in this scope (private members, `this`, and the local environment
        // stay visible). Only the plain single-argument, non-spread form.
        if (c.callee.kind == .ident and std.mem.eql(u8, c.callee.kind.ident, "eval") and
            self.resolve("eval") == null and !has_spread and c.args.len <= 1)
        {
            if (c.args.len == 0) {
                _ = try self.emit(.{ .op = .load_undefined, .a = dst });
                return;
            }
            const argr = self.allocReg();
            try self.compileExprInto(argr, c.args[0]);
            _ = try self.emit(.{ .op = .direct_eval, .a = dst, .b = argr });
            self.freeTo(argr);
            return;
        }

        // Call layout: base=receiver (this), base+1=callee.
        const base = self.allocReg();
        if (c.callee.kind == .super_expr) {
            // super(...): call the parent constructor with the current `this`
            // (approximation of derived-constructor semantics: `this` is
            // created from the subclass prototype, then parent-initialized).
            const sc = self.resolve("\x00super_ctor") orelse return self.fail("'super' outside a derived class", pos);
            _ = try self.emit(.{ .op = .load_this, .a = base });
            const funcreg = self.allocReg();
            _ = try self.emit(.{ .op = .get_var, .a = funcreg, .b = sc.depth, .c = sc.slot });
        } else if (c.callee.kind == .member and c.callee.kind.member.object.kind == .super_expr) {
            // super.m(...): look the method up on the parent prototype, call
            // it with the current `this`.
            const m = c.callee.kind.member;
            const sp = self.resolve("\x00super_proto") orelse return self.fail("'super' outside a class method", pos);
            _ = try self.emit(.{ .op = .load_this, .a = base });
            const funcreg = self.allocReg();
            const protoreg = self.allocReg();
            _ = try self.emit(.{ .op = .get_var, .a = protoreg, .b = sp.depth, .c = sp.slot });
            if (m.computed) {
                const keyreg = self.allocReg();
                try self.compileExprInto(keyreg, m.property);
                _ = try self.emit(.{ .op = .get_elem, .a = funcreg, .b = protoreg, .c = keyreg });
            } else {
                const name_idx = try self.propNameConst(m.property);
                _ = try self.emit(.{ .op = .get_prop, .a = funcreg, .b = protoreg, .c = name_idx });
            }
            self.freeTo(funcreg + 1);
        } else if (c.callee.kind == .member and !c.callee.kind.member.optional) {
            // Method call: receiver is the object; callee is obj.prop.
            const m = c.callee.kind.member;
            try self.compileExprInto(base, m.object);
            const funcreg = self.allocReg(); // base+1
            if (m.property.kind == .private_name) {
                const pk = try self.privateKeyConst(m.property.kind.private_name, m.property.start);
                _ = try self.emit(.{ .op = .get_private, .a = funcreg, .b = base, .c = pk });
            } else if (m.computed) {
                const keyreg = self.allocReg(); // base+2 (temporary)
                try self.compileExprInto(keyreg, m.property);
                _ = try self.emit(.{ .op = .get_elem, .a = funcreg, .b = base, .c = keyreg });
                self.freeTo(funcreg + 1); // free keyreg; keep receiver + callee
            } else {
                const name_idx = try self.propNameConst(m.property);
                _ = try self.emit(.{ .op = .get_prop, .a = funcreg, .b = base, .c = name_idx });
            }
        } else {
            // Plain call: receiver is undefined.
            _ = try self.emit(.{ .op = .load_undefined, .a = base });
            const funcreg = self.allocReg(); // base+1
            try self.compileExprInto(funcreg, c.callee);
        }

        if (!has_spread) {
            // Arguments contiguous at base+2, base+3, ...
            for (c.args) |arg| {
                const ar = self.allocReg();
                try self.compileExprInto(ar, arg);
            }
            _ = try self.emit(.{ .op = .call, .a = dst, .b = base, .c = @intCast(c.args.len) });
        } else {
            // Build an argument array (base+2), then apply.
            const args_arr = self.allocReg(); // base+2
            _ = try self.emit(.{ .op = .new_array, .a = args_arr, .b = 0 });
            for (c.args) |arg| {
                const r = self.allocReg();
                if (arg.kind == .spread) {
                    try self.compileExprInto(r, arg.kind.spread);
                    _ = try self.emit(.{ .op = .arr_spread, .a = args_arr, .b = r });
                } else {
                    try self.compileExprInto(r, arg);
                    _ = try self.emit(.{ .op = .arr_push, .a = args_arr, .b = r });
                }
                self.freeTo(r);
            }
            _ = try self.emit(.{ .op = .call_apply, .a = dst, .b = base });
        }
        self.freeTo(base);
        // A derived constructor installs its instance elements the moment
        // `super(...)` returns (so private methods/fields aren't visible until
        // then — the spec's brand-check-before-super semantics).
        if (c.callee.kind == .super_expr and self.fs.deferred_instance_fields.len > 0) {
            try self.emitInstanceElements(self.fs.deferred_instance_fields);
        }
    }

    fn compileYield(self: *Compiler, dst: u32, y: anytype) CompileError!void {
        // `yield` outside a generator (e.g. as a sloppy-mode identifier) is not
        // supported — reject at compile time rather than yield from a plain frame.
        if (!self.fs.is_generator) return self.fail("yield outside generator", 0);
        if (y.delegate) return self.compileYieldStar(dst, y);
        const val_reg = self.allocReg();
        if (y.argument) |arg| {
            try self.compileExprInto(val_reg, arg);
        } else {
            _ = try self.emit(.{ .op = .load_undefined, .a = val_reg });
        }
        // Yields regs[val_reg]; on resume, regs[dst] receives the sent value.
        _ = try self.emit(.{ .op = .gen_yield, .a = dst, .b = val_reg });
        self.freeTo(val_reg);
    }

    /// `yield* iterable`: yield every value the inner iterable produces, then
    /// evaluate to its final `{done:true}` value. (Sent values and throw/return
    /// are not forwarded into the inner iterator yet.)
    fn compileYieldStar(self: *Compiler, dst: u32, y: anytype) CompileError!void {
        const arg = y.argument orelse return self.fail("yield* requires an operand", 0);
        const iter_reg = self.allocReg();
        {
            const src_reg = self.allocReg();
            try self.compileExprInto(src_reg, arg);
            _ = try self.emit(.{ .op = .iter_init, .a = iter_reg, .b = src_reg });
            self.freeTo(src_reg + 1);
        }
        const result_reg = self.allocReg();
        const top = self.here();
        _ = try self.emit(.{ .op = .iter_next, .a = result_reg, .b = iter_reg });
        const done_reg = self.allocReg();
        const done_name = try self.addConst(.{ .string = "done" });
        _ = try self.emit(.{ .op = .get_prop, .a = done_reg, .b = result_reg, .c = done_name });
        const jdone = try self.emit(.{ .op = .jump_if_true, .a = done_reg });
        self.freeTo(result_reg + 1);

        const val_reg = self.allocReg();
        const value_name = try self.addConst(.{ .string = "value" });
        _ = try self.emit(.{ .op = .get_prop, .a = val_reg, .b = result_reg, .c = value_name });
        const scratch = self.allocReg();
        _ = try self.emit(.{ .op = .gen_yield, .a = scratch, .b = val_reg });
        self.freeTo(val_reg);
        _ = try self.emit(.{ .op = .jump, .a = top });

        self.patchTarget(jdone, self.here());
        // dst = result.value (the completion value of the delegated iterator)
        _ = try self.emit(.{ .op = .get_prop, .a = dst, .b = result_reg, .c = value_name });
        self.freeTo(iter_reg);
    }

    /// Untagged template: seed with the first cooked quasi (so the accumulator
    /// is always a string), then alternate `+ ToString(sub)` and `+ quasi`.
    fn compileTemplate(self: *Compiler, dst: u32, t: anytype) CompileError!void {
        const c0 = try self.addConst(.{ .string = try self.cookTemplateQuasi(t.quasis[0]) });
        _ = try self.emit(.{ .op = .load_const, .a = dst, .b = c0 });
        for (t.exprs, 0..) |e, i| {
            const r = self.allocReg();
            try self.compileExprInto(r, e);
            _ = try self.emit(.{ .op = .add, .a = dst, .b = dst, .c = r });
            const cq = try self.addConst(.{ .string = try self.cookTemplateQuasi(t.quasis[i + 1]) });
            _ = try self.emit(.{ .op = .load_const, .a = r, .b = cq });
            _ = try self.emit(.{ .op = .add, .a = dst, .b = dst, .c = r });
            self.freeTo(r);
        }
    }

    /// Tagged template: `tag(strings, ...subs)` where `strings` is the cooked
    /// array carrying a `.raw` array of the uncooked text.
    fn compileTaggedTemplate(self: *Compiler, dst: u32, tt: anytype) CompileError!void {
        if (tt.quasi.kind != .template) return self.fail("malformed tagged template", tt.quasi.start);
        const t = tt.quasi.kind.template;

        // Receiver + callee follow the standard call layout.
        const base = self.allocReg();
        if (tt.tag.kind == .member and !tt.tag.kind.member.optional) {
            const m = tt.tag.kind.member;
            try self.compileExprInto(base, m.object);
            const funcreg = self.allocReg(); // base+1
            if (m.computed) {
                const keyreg = self.allocReg();
                try self.compileExprInto(keyreg, m.property);
                _ = try self.emit(.{ .op = .get_elem, .a = funcreg, .b = base, .c = keyreg });
                self.freeTo(funcreg + 1);
            } else {
                const name_idx = try self.propNameConst(m.property);
                _ = try self.emit(.{ .op = .get_prop, .a = funcreg, .b = base, .c = name_idx });
            }
        } else {
            _ = try self.emit(.{ .op = .load_undefined, .a = base });
            const funcreg = self.allocReg();
            try self.compileExprInto(funcreg, tt.tag);
        }

        // strings array (first argument, at base+2), with .raw attached.
        const sarr = self.allocReg();
        _ = try self.emit(.{ .op = .new_array, .a = sarr, .b = 0 });
        {
            const rarr = self.allocReg();
            _ = try self.emit(.{ .op = .new_array, .a = rarr, .b = 0 });
            const tmp = self.allocReg();
            for (t.quasis) |q| {
                const cooked = try self.addConst(.{ .string = try self.cookTemplateQuasi(q) });
                _ = try self.emit(.{ .op = .load_const, .a = tmp, .b = cooked });
                _ = try self.emit(.{ .op = .arr_push, .a = sarr, .b = tmp });
                const raw = try self.addConst(.{ .string = try self.arena.dupe(u8, templateQuasiInner(q)) });
                _ = try self.emit(.{ .op = .load_const, .a = tmp, .b = raw });
                _ = try self.emit(.{ .op = .arr_push, .a = rarr, .b = tmp });
            }
            const raw_idx = try self.addConst(.{ .string = "raw" });
            _ = try self.emit(.{ .op = .set_prop, .a = sarr, .b = raw_idx, .c = rarr });
            self.freeTo(rarr);
        }

        // Substitution values at base+3, base+4, …
        for (t.exprs) |e| {
            const ar = self.allocReg();
            try self.compileExprInto(ar, e);
        }
        _ = try self.emit(.{ .op = .call, .a = dst, .b = base, .c = @intCast(1 + t.exprs.len) });
        self.freeTo(base);
    }

    /// Lower a class to a constructor function + prototype/static members.
    /// `extends` wires both prototype chains and provides `super` via synthetic
    /// bindings (`\x00super_ctor` / `\x00super_proto`) that member closures
    /// capture. Private members (`#name`) resolve to hidden per-object keys.
    fn compileClass(self: *Compiler, dst: u32, cls: ast.Class, pos: u32) CompileError!void {
        try self.pushBlock();
        defer self.popBlock();

        // Push this class's private-name scope (active while compiling every
        // member body, so `this.#x` resolves), popped when the class is done.
        {
            const class_id = self.private_class_seq;
            self.private_class_seq += 1;
            var scope: PrivateScope = .{};
            for (cls.members) |m| {
                if (m.kind != .property) continue;
                const prop = m.kind.property;
                if (prop.key.kind != .private_name) continue;
                const name = prop.key.kind.private_name;
                if (scope.names.contains(name)) continue; // get/set pairs share one key
                try scope.names.put(self.arena, name, try self.makePrivateKey(class_id, name));
            }
            try self.private_scopes.append(self.gpa, scope);
        }
        defer _ = self.private_scopes.pop();

        // Superclass bindings, captured by member closures for `super`.
        if (cls.super_class) |sc| {
            const sc_slot = try self.declare("\x00super_ctor");
            const sp_slot = try self.declare("\x00super_proto");
            const r = try self.compileExprToNew(sc);
            _ = try self.emit(.{ .op = .init_var, .a = 0, .b = sc_slot, .c = r });
            const pr = self.allocReg();
            const proto_idx = try self.addConst(.{ .string = "prototype" });
            _ = try self.emit(.{ .op = .get_prop, .a = pr, .b = r, .c = proto_idx });
            _ = try self.emit(.{ .op = .init_var, .a = 0, .b = sp_slot, .c = pr });
            self.freeTo(r);
        }

        // Instance elements installed per-object in the constructor prologue:
        // public/private fields and private methods/accessors (public methods
        // live on the prototype, so they're excluded here).
        var instance_elements: std.ArrayList(*Node) = .empty;
        defer instance_elements.deinit(self.gpa);
        for (cls.members) |m| {
            if (m.kind != .property) continue;
            const prop = m.kind.property;
            if (prop.is_static) continue;
            if (prop.kind == .init or isPrivateMember(prop)) try instance_elements.append(self.gpa, m);
        }

        // The constructor (or an empty default one).
        var ctor_block: ?*bc.CodeBlock = null;
        for (cls.members) |m| {
            if (m.kind != .property) continue;
            const prop = m.kind.property;
            if (prop.kind == .method and !prop.computed and prop.key.kind == .ident and
                std.mem.eql(u8, prop.key.kind.ident, "constructor"))
            {
                const f = (prop.value orelse return self.fail("malformed constructor", m.start)).kind.function;
                ctor_block = try self.compileFunction(cls.name orelse "", f.params, f.body, false, false, false, false, true, instance_elements.items, cls.super_class != null, self.fs);
                break;
            }
        }
        if (ctor_block == null) {
            // Synthesize the default constructor. A derived class's is
            // `constructor(...args) { super(...args); }`, forwarding every
            // argument so the parent's instance elements get installed.
            var body_stmts: []*Node = &.{};
            var ctor_params: []*Node = &.{};
            if (cls.super_class != null) {
                const args_ident = try self.makeIdentNode("\x00rest", pos);
                const rest_param = try self.arena.create(Node);
                rest_param.* = .{ .start = pos, .end = pos, .kind = .{ .rest_element = args_ident } };
                const params = try self.arena.alloc(*Node, 1);
                params[0] = rest_param;
                ctor_params = params;

                const super_node = try self.arena.create(Node);
                super_node.* = .{ .start = pos, .end = pos, .kind = .super_expr };
                const spread_node = try self.arena.create(Node);
                spread_node.* = .{ .start = pos, .end = pos, .kind = .{ .spread = try self.makeIdentNode("\x00rest", pos) } };
                const call_args = try self.arena.alloc(*Node, 1);
                call_args[0] = spread_node;
                const call_node = try self.arena.create(Node);
                call_node.* = .{ .start = pos, .end = pos, .kind = .{ .call = .{ .callee = super_node, .args = call_args, .optional = false } } };
                const stmt = try self.arena.create(Node);
                stmt.* = .{ .start = pos, .end = pos, .kind = .{ .expression_stmt = call_node } };
                const arr = try self.arena.alloc(*Node, 1);
                arr[0] = stmt;
                body_stmts = arr;
            }
            const body = try self.arena.create(Node);
            body.* = .{ .start = pos, .end = pos, .kind = .{ .block_stmt = body_stmts } };
            ctor_block = try self.compileFunction(cls.name orelse "", ctor_params, body, false, false, false, false, true, instance_elements.items, cls.super_class != null, self.fs);
        }
        const ctor_idx: u32 = @intCast(self.fs.children.items.len);
        try self.fs.children.append(self.gpa, ctor_block.?);
        _ = try self.emit(.{ .op = .new_closure, .a = dst, .b = ctor_idx });

        const proto_reg = self.allocReg();
        const proto_idx = try self.addConst(.{ .string = "prototype" });
        _ = try self.emit(.{ .op = .get_prop, .a = proto_reg, .b = dst, .c = proto_idx });

        // extends: wire prototype.[[Prototype]] and constructor.[[Prototype]]
        // through the `__proto__` accessor.
        if (cls.super_class != null) {
            const dunder = try self.addConst(.{ .string = "__proto__" });
            const t = self.allocReg();
            const sp = self.resolve("\x00super_proto").?;
            _ = try self.emit(.{ .op = .get_var, .a = t, .b = sp.depth, .c = sp.slot });
            _ = try self.emit(.{ .op = .set_prop, .a = proto_reg, .b = dunder, .c = t });
            const sc = self.resolve("\x00super_ctor").?;
            _ = try self.emit(.{ .op = .get_var, .a = t, .b = sc.depth, .c = sc.slot });
            _ = try self.emit(.{ .op = .set_prop, .a = dst, .b = dunder, .c = t });
            self.freeTo(t);
        }

        // Prototype / static members. Private instance members were installed
        // per-object in the constructor prologue, so they're skipped here.
        for (cls.members) |m| {
            if (m.kind != .property) continue;
            const prop = m.kind.property;
            if (prop.kind == .method and !prop.computed and prop.key.kind == .ident and
                std.mem.eql(u8, prop.key.kind.ident, "constructor")) continue;
            if (isPrivateMember(prop) and !prop.is_static) continue; // done in ctor

            if (prop.kind == .init) {
                if (!prop.is_static) continue; // public instance field: done in ctor
                // Static field: the initializer runs now with `this` = the
                // constructor (compiled as an expression-body closure).
                const vreg = self.allocReg();
                if (prop.value) |init_expr| {
                    const child = try self.compileFunction("", &.{}, init_expr, true, false, false, false, true, &.{}, false, self.fs);
                    const child_idx: u32 = @intCast(self.fs.children.items.len);
                    try self.fs.children.append(self.gpa, child);
                    const base = self.allocReg(); // receiver = the constructor
                    _ = try self.emit(.{ .op = .move, .a = base, .b = dst });
                    const callee = self.allocReg();
                    _ = try self.emit(.{ .op = .new_closure, .a = callee, .b = child_idx });
                    _ = try self.emit(.{ .op = .call, .a = vreg, .b = base, .c = 0 });
                    self.freeTo(base);
                } else {
                    _ = try self.emit(.{ .op = .load_undefined, .a = vreg });
                }
                if (isPrivateMember(prop)) {
                    _ = try self.emit(.{ .op = .def_pfield, .a = dst, .b = try self.privateKeyConst(prop.key.kind.private_name, m.start), .c = vreg });
                } else if (prop.computed) {
                    const k = self.allocReg();
                    try self.compileExprInto(k, prop.key);
                    _ = try self.emit(.{ .op = .set_elem, .a = dst, .b = k, .c = vreg });
                } else {
                    const idx = try self.propNameConst(prop.key);
                    _ = try self.emit(.{ .op = .set_prop, .a = dst, .b = idx, .c = vreg });
                }
                self.freeTo(vreg);
                continue;
            }
            const fnode = prop.value orelse return self.fail("malformed class member", m.start);
            if (fnode.kind != .function) return self.fail("malformed class member", m.start);
            const f = fnode.kind.function;

            const member_name = try self.functionNameFor(prop);
            const child = try self.compileFunction(member_name, f.params, f.body, false, f.flags.is_generator, f.flags.is_async, false, true, &.{}, false, self.fs);
            const child_idx: u32 = @intCast(self.fs.children.items.len);
            try self.fs.children.append(self.gpa, child);
            const fr = self.allocReg();
            _ = try self.emit(.{ .op = .new_closure, .a = fr, .b = child_idx });

            // Static private method/accessor: install on the constructor itself.
            if (isPrivateMember(prop)) {
                const pk = try self.privateKeyConst(prop.key.kind.private_name, m.start);
                _ = try self.emit(.{ .op = switch (prop.kind) {
                    .method => .def_pmethod,
                    .get => .def_pget,
                    .set => .def_pset,
                    else => return self.fail("unsupported class member", m.start),
                }, .a = dst, .b = pk, .c = fr });
                self.freeTo(fr);
                continue;
            }

            const target: u32 = if (prop.is_static) dst else proto_reg;
            switch (prop.kind) {
                .method => {
                    // Class methods are non-enumerable (spec MethodDefinitionEvaluation).
                    if (prop.computed) {
                        const k = self.allocReg();
                        try self.compileExprInto(k, prop.key);
                        _ = try self.emit(.{ .op = .def_elem, .a = target, .b = k, .c = fr });
                    } else {
                        const idx = try self.propNameConst(prop.key);
                        _ = try self.emit(.{ .op = .def_prop, .a = target, .b = idx, .c = fr });
                    }
                },
                .get, .set => try self.emitDefineAccessor(target, prop, fr, false),
                else => return self.fail("unsupported class member", m.start),
            }
            self.freeTo(fr);
        }
        self.freeTo(proto_reg);
    }

    fn compileFunctionExpr(self: *Compiler, dst: u32, f: ast.Function) CompileError!void {
        const child = try self.compileFunction(
            f.name orelse "",
            f.params,
            f.body,
            f.flags.expression_body,
            f.flags.is_generator,
            f.flags.is_async,
            f.flags.is_arrow,
            false,
            &.{},
            false,
            self.fs,
        );
        const idx: u32 = @intCast(self.fs.children.items.len);
        try self.fs.children.append(self.gpa, child);
        _ = try self.emit(.{ .op = .new_closure, .a = dst, .b = idx });
    }

    // ---- literal cooking ---------------------------------------------------

    /// Strip a template quasi's delimiters: a leading `` ` `` or `}` and a
    /// trailing `` ` `` or `${`.
    fn templateQuasiInner(raw: []const u8) []const u8 {
        var inner = raw;
        if (inner.len > 0 and (inner[0] == '`' or inner[0] == '}')) inner = inner[1..];
        if (std.mem.endsWith(u8, inner, "${")) {
            inner = inner[0 .. inner.len - 2];
        } else if (std.mem.endsWith(u8, inner, "`")) {
            inner = inner[0 .. inner.len - 1];
        }
        return inner;
    }

    /// Cook a template quasi: escape-process the delimiter-stripped text.
    fn cookTemplateQuasi(self: *Compiler, raw: []const u8) CompileError![]u8 {
        return self.cookInner(templateQuasiInner(raw));
    }

    /// Strip quotes and process common escape sequences into UTF-8.
    fn cookString(self: *Compiler, raw: []const u8) CompileError![]u8 {
        if (raw.len < 2) return self.arena.dupe(u8, "");
        return self.cookInner(raw[1 .. raw.len - 1]);
    }

    fn cookInner(self: *Compiler, inner: []const u8) CompileError![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);
        var i: usize = 0;
        while (i < inner.len) {
            const c = inner[i];
            if (c != '\\') {
                try out.append(self.gpa, c);
                i += 1;
                continue;
            }
            i += 1;
            if (i >= inner.len) break;
            const e = inner[i];
            i += 1;
            switch (e) {
                'n' => try out.append(self.gpa, '\n'),
                't' => try out.append(self.gpa, '\t'),
                'r' => try out.append(self.gpa, '\r'),
                'b' => try out.append(self.gpa, 0x08),
                'f' => try out.append(self.gpa, 0x0c),
                'v' => try out.append(self.gpa, 0x0b),
                '0' => try out.append(self.gpa, 0),
                '\\' => try out.append(self.gpa, '\\'),
                '\'' => try out.append(self.gpa, '\''),
                '"' => try out.append(self.gpa, '"'),
                '`' => try out.append(self.gpa, '`'),
                'x' => {
                    if (i + 2 <= inner.len) {
                        const cp = std.fmt.parseInt(u21, inner[i .. i + 2], 16) catch 0;
                        i += 2;
                        try appendCodepoint(self.gpa, &out, cp);
                    }
                },
                'u' => {
                    if (i < inner.len and inner[i] == '{') {
                        const close = std.mem.indexOfScalarPos(u8, inner, i, '}') orelse inner.len;
                        const cp = std.fmt.parseInt(u21, inner[i + 1 .. close], 16) catch 0;
                        i = close + 1;
                        try appendCodepoint(self.gpa, &out, cp);
                    } else if (i + 4 <= inner.len) {
                        const cp = std.fmt.parseInt(u21, inner[i .. i + 4], 16) catch 0;
                        i += 4;
                        try appendCodepoint(self.gpa, &out, cp);
                    }
                },
                '\n' => {}, // line continuation
                else => try out.append(self.gpa, e),
            }
        }
        // Move into the program arena (out was scratch).
        const result = try self.arena.dupe(u8, out.items);
        out.deinit(self.gpa);
        return result;
    }
};

fn appendCodepoint(gpa: std.mem.Allocator, out: *std.ArrayList(u8), cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch {
        try out.append(gpa, '?');
        return;
    };
    try out.appendSlice(gpa, buf[0..n]);
}

// ---- operator tables -------------------------------------------------------

fn isRegexFlagChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn binaryOpcode(k: token.Kind) ?Op {
    return switch (k) {
        .plus => .add,
        .minus => .sub,
        .star => .mul,
        .slash => .div,
        .percent => .mod,
        .star_star => .exp,
        .amp => .bit_and,
        .pipe => .bit_or,
        .caret => .bit_xor,
        .shl => .shl,
        .shr => .shr,
        .ushr => .ushr,
        .eq_eq => .eq,
        .not_eq => .ne,
        .eq_eq_eq => .strict_eq,
        .not_eq_eq => .strict_ne,
        .lt => .lt,
        .lt_eq => .le,
        .gt => .gt,
        .gt_eq => .ge,
        .kw_instanceof => .instance_of,
        .kw_in => .in_op,
        else => null,
    };
}

fn compoundOpcode(k: token.Kind) ?Op {
    return switch (k) {
        .plus_eq => .add,
        .minus_eq => .sub,
        .star_eq => .mul,
        .slash_eq => .div,
        .percent_eq => .mod,
        .star_star_eq => .exp,
        .amp_eq => .bit_and,
        .pipe_eq => .bit_or,
        .caret_eq => .bit_xor,
        .shl_eq => .shl,
        .shr_eq => .shr,
        .ushr_eq => .ushr,
        else => null,
    };
}

/// Parse a numeric literal (decimal/hex/octal/binary, separators, exponent).
pub fn parseNumber(raw: []const u8) !f64 {
    var buf: [256]u8 = undefined;
    if (raw.len == 0) return error.Invalid;
    // Strip separators and a trailing BigInt `n`.
    var len: usize = 0;
    for (raw) |ch| {
        if (ch == '_') continue;
        if (ch == 'n') break;
        if (len >= buf.len) return error.Invalid;
        buf[len] = ch;
        len += 1;
    }
    const s = buf[0..len];
    if (s.len >= 2 and s[0] == '0') {
        switch (s[1]) {
            'x', 'X' => return @floatFromInt(try std.fmt.parseInt(u64, s[2..], 16)),
            'o', 'O' => return @floatFromInt(try std.fmt.parseInt(u64, s[2..], 8)),
            'b', 'B' => return @floatFromInt(try std.fmt.parseInt(u64, s[2..], 2)),
            else => {},
        }
    }
    return std.fmt.parseFloat(f64, s);
}

// ---- public entry ----------------------------------------------------------

pub fn compile(gpa: std.mem.Allocator, program: *Node, source: []const u8) CompileError!Result {
    var arena = std.heap.ArenaAllocator.init(gpa);
    var root_fs: FnState = undefined; // set inside compileFunction
    _ = &root_fs;

    var c = Compiler{
        .gpa = gpa,
        .arena = arena.allocator(),
        .source = source,
        .fs = undefined,
    };
    defer c.private_scopes.deinit(gpa);

    const body = program.kind.program.body;
    // Wrap the script body as a function with no params.
    const dummy_body = try c.arena.create(Node);
    dummy_body.* = .{ .start = program.start, .end = program.end, .kind = .{ .block_stmt = body } };

    const root = c.compileFunction("<script>", &.{}, dummy_body, false, false, false, false, false, &.{}, false, null) catch |e| switch (e) {
        error.OutOfMemory => {
            arena.deinit();
            return error.OutOfMemory;
        },
        else => {
            const diag = c.diag orelse Diagnostic{ .message = "compile error", .pos = program.start };
            arena.deinit();
            return .{ .compile_error = diag };
        },
    };

    return .{ .ok = .{ .arena = arena, .root = root } };
}

/// Compile a direct `eval`'s source, seeding the private-name scope with the
/// caller's visible private members so `this.#x` resolves to the same keys.
pub fn compileEval(gpa: std.mem.Allocator, program: *Node, source: []const u8, private_env: []const bc.PrivateBinding) CompileError!Result {
    var arena = std.heap.ArenaAllocator.init(gpa);
    var c = Compiler{
        .gpa = gpa,
        .arena = arena.allocator(),
        .source = source,
        .fs = undefined,
        // A direct eval sits inside some function, so `new.target` is legal
        // (evaluates to undefined) rather than a top-level SyntaxError.
        .root_new_target_allowed = true,
        .eval_compile = true,
    };
    defer c.private_scopes.deinit(gpa);

    // Seed a private-name scope from the caller's captured bindings.
    if (private_env.len > 0) {
        var scope: PrivateScope = .{};
        for (private_env) |pb| {
            scope.names.put(c.arena, pb.name, pb.key) catch {
                arena.deinit();
                return error.OutOfMemory;
            };
        }
        c.private_scopes.append(gpa, scope) catch {
            arena.deinit();
            return error.OutOfMemory;
        };
    }

    const body = program.kind.program.body;
    const dummy_body = try c.arena.create(Node);
    dummy_body.* = .{ .start = program.start, .end = program.end, .kind = .{ .block_stmt = body } };

    const root = c.compileFunction("<eval>", &.{}, dummy_body, false, false, false, false, false, &.{}, false, null) catch |e| switch (e) {
        error.OutOfMemory => {
            arena.deinit();
            return error.OutOfMemory;
        },
        else => {
            const diag = c.diag orelse Diagnostic{ .message = "compile error", .pos = program.start };
            arena.deinit();
            return .{ .compile_error = diag };
        },
    };

    return .{ .ok = .{ .arena = arena, .root = root } };
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "parseNumber forms" {
    try testing.expectEqual(@as(f64, 255), try parseNumber("0xFF"));
    try testing.expectEqual(@as(f64, 15), try parseNumber("0o17"));
    try testing.expectEqual(@as(f64, 5), try parseNumber("0b101"));
    try testing.expectEqual(@as(f64, 1000), try parseNumber("1_000"));
    try testing.expectEqual(@as(f64, 3.14), try parseNumber("3.14"));
    try testing.expectEqual(@as(f64, 1e10), try parseNumber("1e10"));
    try testing.expectEqual(@as(f64, 42), try parseNumber("42n"));
}

fn compileOk(source: []const u8) !bc.Program {
    const parser = @import("parser.zig");
    var pr = try parser.parse(testing.allocator, source, .script);
    switch (pr) {
        .syntax_error => return error.ParseFailed,
        .ok => |*a| {
            defer a.deinit();
            const r = try compile(testing.allocator, a.root, source);
            switch (r) {
                .compile_error => |d| {
                    std.debug.print("compile error: {s}\n", .{d.message});
                    return error.CompileFailed;
                },
                .ok => |p| return p,
            }
        },
    }
}

test "compiles arithmetic and variables" {
    var p = try compileOk("var a = 1 + 2 * 3; var b = a - 1;");
    defer p.deinit();
    try testing.expect(p.root.code.len > 0);
}

/// Disassemble `source` and collapse runs of whitespace to single spaces, so
/// the golden snapshot pins the instruction stream (headers, opcodes, operands)
/// without being brittle about the disassembler's column widths.
fn disasmSnapshot(source: []const u8, out: *std.ArrayList(u8)) !void {
    var p = try compileOk(source);
    defer p.deinit();
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(testing.allocator);
    try p.root.disassemble(testing.allocator, &raw);
    var prev_space = false;
    for (raw.items) |c| {
        if (c == ' ' or c == '\t') {
            if (!prev_space) try out.append(testing.allocator, ' ');
            prev_space = true;
        } else {
            try out.append(testing.allocator, c);
            prev_space = c == '\n';
        }
    }
}

test "disassembler snapshot: function with a call and a return" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try disasmSnapshot("function add(a, b) { return a + b; }", &out);
    try testing.expectEqualStrings(
        \\== <script> (params=0, regs=1, env_slots=0) ==
        \\0 ensure_global a=0 b=0 c=0
        \\1 new_closure a=0 b=0 c=0
        \\2 set_global a=1 b=0 c=0
        \\3 load_undefined a=0 b=0 c=0
        \\4 ret a=0 b=0 c=0
        \\
        \\== add (params=2, regs=2, env_slots=3) ==
        \\0 get_var a=0 b=0 c=0
        \\1 get_var a=1 b=0 c=1
        \\2 add a=0 b=0 c=1
        \\3 ret a=0 b=0 c=0
        \\4 load_undefined a=0 b=0 c=0
        \\5 ret a=0 b=0 c=0
        \\
    , out.items);
}

test "disassembler snapshot: if/else branch" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try disasmSnapshot("var x = a ? 1 : 2;", &out);
    // Just pin the branch structure (conditional lowers to jumps).
    try testing.expect(std.mem.indexOf(u8, out.items, "jump_if_false") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "jump a=") != null);
}

test "compiles control flow and functions" {
    var p = try compileOk(
        \\function fib(n) {
        \\  if (n < 2) return n;
        \\  return fib(n - 1) + fib(n - 2);
        \\}
        \\var result = fib(10);
    );
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.root.children.len);
}

test "reports unsupported constructs" {
    const src = "var x = a?.b;"; // optional chaining does not compile yet
    const parser = @import("parser.zig");
    var pr = try parser.parse(testing.allocator, src, .script);
    switch (pr) {
        .syntax_error => return error.ParseFailed,
        .ok => |*a| {
            defer a.deinit();
            var r = try compile(testing.allocator, a.root, src);
            switch (r) {
                .compile_error => {}, // destructuring not yet supported -> expected
                .ok => |*p| {
                    p.deinit();
                    return error.ExpectedCompileError;
                },
            }
        },
    }
}
