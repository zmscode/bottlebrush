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

const Binding = struct { depth: u32, slot: u32 };

const Block = struct {
    names: std.StringHashMapUnmanaged(u32) = .empty,
};

const FnState = struct {
    parent: ?*FnState,
    name: []const u8,
    num_params: u32 = 0,
    env_slot_count: u32 = 0,
    reg_top: u32 = 0,
    max_regs: u32 = 0,
    code: std.ArrayList(Inst) = .empty,
    constants: std.ArrayList(bc.Const) = .empty,
    children: std.ArrayList(*bc.CodeBlock) = .empty,
    handlers: std.ArrayList(bc.Handler) = .empty,
    blocks: std.ArrayList(Block) = .empty,
};

pub const Compiler = struct {
    gpa: std.mem.Allocator, // scratch (freed as we go)
    arena: std.mem.Allocator, // program arena (outlives compilation)
    source: []const u8,
    fs: *FnState,
    diag: ?Diagnostic = null,
    /// Innermost loop context, for break/continue jump patching.
    loop: ?*LoopCtx = null,

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
        if (b.names.get(name)) |slot| return slot; // redeclaration -> same slot
        const slot = self.fs.env_slot_count;
        self.fs.env_slot_count += 1;
        try b.names.put(self.gpa, name, slot);
        return slot;
    }
    fn resolve(self: *Compiler, name: []const u8) ?Binding {
        var fs: ?*FnState = self.fs;
        var depth: u32 = 0;
        while (fs) |f| {
            var i = f.blocks.items.len;
            while (i > 0) {
                i -= 1;
                if (f.blocks.items[i].names.get(name)) |slot| return .{ .depth = depth, .slot = slot };
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
                if (f.name) |n| _ = try self.declare(n);
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
    fn hoistTarget(self: *Compiler, target: *Node) CompileError!void {
        switch (target.kind) {
            .ident => |name| _ = try self.declare(name),
            else => {}, // destructuring var hoisting deferred
        }
    }

    // ---- function compilation ---------------------------------------------

    fn compileFunction(
        self: *Compiler,
        name: []const u8,
        params: []*Node,
        body: *Node,
        is_expression_body: bool,
        parent_fs: ?*FnState,
    ) CompileError!*bc.CodeBlock {
        var fs = FnState{ .parent = parent_fs, .name = name };
        const prev = self.fs;
        self.fs = &fs;
        defer self.fs = prev;
        defer self.deinitFnState(&fs);

        try self.pushBlock();

        // Parameters occupy the first env slots.
        for (params) |p| {
            switch (p.kind) {
                .ident => |pn| _ = try self.declare(pn),
                .assignment_pattern => |ap| {
                    if (ap.left.kind == .ident) {
                        _ = try self.declare(ap.left.kind.ident);
                    } else return self.fail("destructuring params unsupported", p.start);
                },
                .rest_element => return self.fail("rest params unsupported", p.start),
                else => return self.fail("pattern params unsupported", p.start),
            }
        }
        fs.num_params = @intCast(params.len);

        if (is_expression_body) {
            const r = try self.compileExprToNew(body);
            _ = try self.emit(.{ .op = .ret, .a = r });
            self.freeTo(0);
        } else {
            const stmts = body.kind.block_stmt;
            try self.hoist(stmts);
            try self.emitHoistedFunctions(stmts);
            for (stmts) |s| try self.compileStmt(s);
            // Implicit `return undefined`.
            const r = self.allocReg();
            _ = try self.emit(.{ .op = .load_undefined, .a = r });
            _ = try self.emit(.{ .op = .ret, .a = r });
            self.freeTo(0);
        }

        self.popBlock();
        return self.finishCodeBlock(&fs);
    }

    fn emitHoistedFunctions(self: *Compiler, body: []*Node) CompileError!void {
        for (body) |stmt| {
            if (stmt.kind == .function_decl) {
                const f = stmt.kind.function_decl;
                const child = try self.compileFunction(f.name orelse "", f.params, f.body, false, self.fs);
                const idx: u32 = @intCast(self.fs.children.items.len);
                try self.fs.children.append(self.gpa, child);
                const r = self.allocReg();
                _ = try self.emit(.{ .op = .new_closure, .a = r, .b = idx });
                const bind = self.resolve(f.name.?).?;
                _ = try self.emit(.{ .op = .set_var, .a = bind.depth, .b = bind.slot, .c = r });
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
    }

    // ---- statements --------------------------------------------------------

    fn compileStmt(self: *Compiler, stmt: *Node) CompileError!void {
        switch (stmt.kind) {
            .empty_stmt, .debugger_stmt => {},
            .function_decl => {}, // handled by emitHoistedFunctions
            .expression_stmt => |e| {
                const r = try self.compileExprToNew(e);
                self.freeTo(r);
            },
            .var_decl => |vd| try self.compileVarDecl(vd),
            .block_stmt => |b| {
                try self.pushBlock();
                for (b) |s| try self.compileStmt(s);
                self.popBlock();
            },
            .if_stmt => |s| try self.compileIf(s),
            .while_stmt => |s| try self.compileWhile(s),
            .do_while_stmt => |s| try self.compileDoWhile(s),
            .for_stmt => |s| try self.compileFor(s),
            .return_stmt => |arg| {
                const r = if (arg) |a| try self.compileExprToNew(a) else blk: {
                    const rr = self.allocReg();
                    _ = try self.emit(.{ .op = .load_undefined, .a = rr });
                    break :blk rr;
                };
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
            else => return self.fail("unsupported statement", stmt.start),
        }
    }

    fn compileVarDecl(self: *Compiler, vd: anytype) CompileError!void {
        for (vd.decls) |d| {
            const decl = d.kind.variable_declarator;
            if (decl.id.kind != .ident) return self.fail("destructuring declarations unsupported", decl.id.start);
            const name = decl.id.kind.ident;
            const slot = if (vd.kind == .keyword_var)
                self.resolve(name).?.slot // already hoisted
            else
                try self.declare(name);
            if (decl.init) |init_expr| {
                const r = try self.compileExprToNew(init_expr);
                _ = try self.emit(.{ .op = .set_var, .a = 0, .b = slot, .c = r });
                self.freeTo(r);
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
        var ctx = LoopCtx{};
        const prev = self.loop;
        self.loop = &ctx;
        defer self.loop = prev;

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
        var ctx = LoopCtx{};
        const prev = self.loop;
        self.loop = &ctx;
        defer self.loop = prev;

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

        var ctx = LoopCtx{};
        const prev = self.loop;
        self.loop = &ctx;
        defer self.loop = prev;

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

    fn compileTry(self: *Compiler, s: anytype) CompileError!void {
        const try_start = self.here();
        try self.compileStmt(s.block);
        const try_end = self.here();
        const jover = try self.emit(.{ .op = .jump }); // skip handler on normal completion

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
                } else return self.fail("destructuring catch param unsupported", p.start);
            }
            self.freeTo(catch_reg);
            try self.compileStmt(cc.body);
            self.popBlock();
        }
        self.patchTarget(jover, self.here());

        if (s.finalizer) |fin| {
            // Simplified finally: run on the normal path here. Exceptional and
            // abrupt-completion paths through finally are a later refinement.
            try self.compileStmt(fin);
        }
    }

    // ---- loop break/continue plumbing --------------------------------------

    const LoopCtx = struct {
        breaks: std.ArrayList(u32) = .empty,
        continues: std.ArrayList(u32) = .empty,
    };

    fn emitLoopJump(self: *Compiler, kind: LoopKind, pos: u32) CompileError!void {
        const ctx = self.loop orelse return self.fail("break/continue outside loop", pos);
        const pc = try self.emit(.{ .op = .jump });
        switch (kind) {
            .brk => try ctx.breaks.append(self.gpa, pc),
            .cont => try ctx.continues.append(self.gpa, pc),
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
        if (u.op == .kw_delete) return self.fail("delete unsupported", pos);
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

    fn compileUpdate(self: *Compiler, dst: u32, u: anytype, pos: u32) CompileError!void {
        if (u.operand.kind != .ident) return self.fail("update target must be an identifier", pos);
        const name = u.operand.kind.ident;
        const bind = self.resolve(name) orelse return self.fail("undeclared identifier", pos);
        const one = try self.addConst(.{ .number = 1 });

        // Load current value into dst.
        _ = try self.emit(.{ .op = .get_var, .a = dst, .b = bind.depth, .c = bind.slot });
        const delta = self.allocReg();
        if (u.prefix) {
            _ = try self.emit(.{ .op = .load_const, .a = delta, .b = one });
            _ = try self.emit(.{ .op = if (u.op == .plus_plus) .add else .sub, .a = dst, .b = dst, .c = delta });
            _ = try self.emit(.{ .op = .set_var, .a = bind.depth, .b = bind.slot, .c = dst });
        } else {
            // Postfix: dst keeps the old (numeric) value; compute new separately.
            _ = try self.emit(.{ .op = .to_number, .a = dst, .b = dst });
            const newv = self.allocReg();
            _ = try self.emit(.{ .op = .load_const, .a = delta, .b = one });
            _ = try self.emit(.{ .op = if (u.op == .plus_plus) .add else .sub, .a = newv, .b = dst, .c = delta });
            _ = try self.emit(.{ .op = .set_var, .a = bind.depth, .b = bind.slot, .c = newv });
            self.freeTo(newv);
        }
        self.freeTo(delta);
    }

    fn compileAssignment(self: *Compiler, dst: u32, a: anytype, pos: u32) CompileError!void {
        if (a.target.kind == .member) {
            return self.compileMemberStore(dst, a, pos);
        }
        if (a.target.kind != .ident) return self.fail("assignment target must be an identifier or member", pos);
        const name = a.target.kind.ident;

        if (self.resolve(name)) |bind| {
            if (a.op == .assign) {
                try self.compileExprInto(dst, a.value);
            } else {
                _ = try self.emit(.{ .op = .get_var, .a = dst, .b = bind.depth, .c = bind.slot });
                const rhs = self.allocReg();
                try self.compileExprInto(rhs, a.value);
                const op = compoundOpcode(a.op) orelse return self.fail("unsupported assignment operator", pos);
                _ = try self.emit(.{ .op = op, .a = dst, .b = dst, .c = rhs });
                self.freeTo(rhs);
            }
            _ = try self.emit(.{ .op = .set_var, .a = bind.depth, .b = bind.slot, .c = dst });
        } else {
            // Free identifier -> global property.
            const idx = try self.addConst(.{ .string = name });
            if (a.op == .assign) {
                try self.compileExprInto(dst, a.value);
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

    fn compileMemberStore(self: *Compiler, dst: u32, a: anytype, pos: u32) CompileError!void {
        if (a.op != .assign) return self.fail("compound member assignment unsupported", pos);
        const m = a.target.kind.member;
        const objreg = self.allocReg();
        try self.compileExprInto(objreg, m.object);
        if (m.computed) {
            const keyreg = self.allocReg();
            try self.compileExprInto(keyreg, m.property);
            try self.compileExprInto(dst, a.value);
            _ = try self.emit(.{ .op = .set_elem, .a = objreg, .b = keyreg, .c = dst });
        } else {
            const name_idx = try self.propNameConst(m.property);
            try self.compileExprInto(dst, a.value);
            _ = try self.emit(.{ .op = .set_prop, .a = objreg, .b = name_idx, .c = dst });
        }
        self.freeTo(objreg);
    }

    fn compileMemberLoad(self: *Compiler, dst: u32, m: anytype) CompileError!void {
        if (m.optional) return self.fail("optional chaining unsupported", 0);
        const objreg = self.allocReg();
        try self.compileExprInto(objreg, m.object);
        if (m.computed) {
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

    fn compileArrayLiteral(self: *Compiler, dst: u32, elems: []?*Node, pos: u32) CompileError!void {
        _ = try self.emit(.{ .op = .new_array, .a = dst, .b = @intCast(elems.len) });
        for (elems, 0..) |maybe, i| {
            const elem = maybe orelse continue; // elision -> leave the hole
            if (elem.kind == .spread) return self.fail("array spread unsupported", pos);
            const idx_reg = self.allocReg();
            const idx_const = try self.addConst(.{ .number = @floatFromInt(i) });
            _ = try self.emit(.{ .op = .load_const, .a = idx_reg, .b = idx_const });
            const val_reg = self.allocReg();
            try self.compileExprInto(val_reg, elem);
            _ = try self.emit(.{ .op = .set_elem, .a = dst, .b = idx_reg, .c = val_reg });
            self.freeTo(idx_reg);
        }
    }

    fn compileObjectLiteral(self: *Compiler, dst: u32, props: []*Node, pos: u32) CompileError!void {
        _ = try self.emit(.{ .op = .new_object, .a = dst });
        for (props) |p| {
            const prop = p.kind.property;
            switch (prop.kind) {
                .spread => return self.fail("object spread unsupported", pos),
                .get, .set => return self.fail("object literal accessors unsupported", pos),
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
        // Call layout: base=receiver (this), base+1=callee, base+2..=args.
        const base = self.allocReg();
        if (c.callee.kind == .member and !c.callee.kind.member.optional) {
            // Method call: receiver is the object; callee is obj.prop.
            const m = c.callee.kind.member;
            try self.compileExprInto(base, m.object);
            const funcreg = self.allocReg(); // base+1
            if (m.computed) {
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
        // Arguments at base+2, base+3, ...
        for (c.args) |arg| {
            if (arg.kind == .spread) return self.fail("spread arguments unsupported", pos);
            const ar = self.allocReg();
            try self.compileExprInto(ar, arg);
        }
        _ = try self.emit(.{ .op = .call, .a = dst, .b = base, .c = @intCast(c.args.len) });
        self.freeTo(base);
    }

    fn compileFunctionExpr(self: *Compiler, dst: u32, f: ast.Function) CompileError!void {
        const child = try self.compileFunction(
            f.name orelse "",
            f.params,
            f.body,
            f.flags.expression_body,
            self.fs,
        );
        const idx: u32 = @intCast(self.fs.children.items.len);
        try self.fs.children.append(self.gpa, child);
        _ = try self.emit(.{ .op = .new_closure, .a = dst, .b = idx });
    }

    // ---- literal cooking ---------------------------------------------------

    /// Strip quotes and process common escape sequences into UTF-8.
    fn cookString(self: *Compiler, raw: []const u8) CompileError![]u8 {
        if (raw.len < 2) return self.arena.dupe(u8, "");
        const inner = raw[1 .. raw.len - 1];
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

    const body = program.kind.program.body;
    // Wrap the script body as a function with no params.
    const dummy_body = try c.arena.create(Node);
    dummy_body.* = .{ .start = program.start, .end = program.end, .kind = .{ .block_stmt = body } };

    const root = c.compileFunction("<script>", &.{}, dummy_body, false, null) catch |e| switch (e) {
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
    const src = "var [a, b] = arr;"; // destructuring declarations not yet supported
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
