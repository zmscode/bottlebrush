//! Swarm fuzzing of the lexer, parser and compiler.
//!
//!   zig build test-fuzz
//!   zig build test-fuzz -Dfuzz-seed=12345 -Dfuzz-runs=100000
//!
//! Two fuzzers, with different oracles.
//!
//! **The grammar fuzzer** generates JavaScript that is *valid by construction*:
//! it walks the grammar, tracks context (inside a function? a generator? a
//! loop?) and only emits productions legal there, with unique binding names so
//! nothing redeclares. That buys a real oracle — a syntax error is a parser
//! bug, not an expected outcome — where a byte-level fuzzer can only assert
//! "did not crash". Programs are compiled too, since the compiler now asserts
//! its register-allocator invariants: assertions and fuzzing are one technique,
//! the fuzzer reaches the state and the assertion notices it is wrong.
//!
//! It is a **swarm** fuzzer, after TigerBeetle's `random_enum_weights`. Each run
//! picks a random subset of grammar productions, *disables the rest entirely*,
//! and gives the survivors weights spread over two orders of magnitude. So one
//! run is nothing but nested arrow functions, the next is all classes and
//! private fields, the next is `try`/`catch` around destructuring. A uniform
//! sampler explores the average program; a swarm explores the corners, which is
//! where parser bugs live.
//!
//! **The byte fuzzer** keeps the old uniform token soup. Valid-by-construction
//! generation never exercises the lexer's error paths, so both are needed.
//!
//! The seed defaults to the low 64 bits of `git rev-parse HEAD`, so every commit
//! fuzzes differently while any failure reproduces from the commit alone.

const std = @import("std");
const testing = std.testing;
const bottlebrush = @import("bottlebrush");
const options = @import("fuzz_options");

/// A grammar production. The swarm enables a subset of these per run.
const Feature = enum {
    // Statements.
    st_expr,
    st_var,
    st_let,
    st_const,
    st_if,
    st_block,
    st_while,
    st_do,
    st_for,
    st_for_in,
    st_for_of,
    st_func,
    st_generator,
    st_async_func,
    st_class,
    st_try,
    st_switch,
    st_labeled,
    st_return,
    st_throw,
    st_empty,
    st_debugger,

    // Expressions.
    ex_ident,
    ex_number,
    ex_string,
    ex_template,
    ex_tagged_template,
    ex_regex,
    ex_array,
    ex_object,
    ex_arrow,
    ex_async_arrow,
    ex_func,
    ex_class,
    ex_call,
    ex_call_spread,
    ex_new,
    ex_member,
    ex_index,
    ex_assign,
    ex_compound_assign,
    ex_binary,
    ex_logical,
    ex_unary,
    ex_update,
    ex_cond,
    ex_seq,
    ex_this,
    ex_yield,
    ex_await,
    ex_typeof,
    ex_delete,
    ex_in,
    ex_instanceof,

    // Binding patterns.
    pat_ident,
    pat_array,
    pat_object,
    pat_default,

    // Parameters.
    param_simple,
    param_default,
    param_rest,
    param_pattern,

    // Class elements.
    cls_method,
    cls_static_method,
    cls_getter,
    cls_field,
    cls_private_field,
    cls_extends,

    fn category(f: Feature) Category {
        const i = @intFromEnum(f);
        if (i <= @intFromEnum(Feature.st_debugger)) return .statement;
        if (i <= @intFromEnum(Feature.ex_instanceof)) return .expression;
        if (i <= @intFromEnum(Feature.pat_default)) return .pattern;
        if (i <= @intFromEnum(Feature.param_pattern)) return .param;
        return .class_element;
    }
};

const Category = enum { statement, expression, pattern, param, class_element };
const feature_count = @typeInfo(Feature).@"enum".fields.len;

/// Never disabled: without a terminal in every category the generator cannot
/// bottom out, and without `st_expr` it cannot emit anything at all.
const always_enabled = [_]Feature{
    .st_expr,
    .ex_number,
    .pat_ident,
    .param_simple,
    .cls_method,
};

/// Where we are in the grammar. Determines which productions are legal: `yield`
/// only inside a generator, `return` only inside a function, and so on. Getting
/// this right is what makes the output valid by construction.
const Ctx = struct {
    depth: u8 = 0,
    in_function: bool = false,
    in_generator: bool = false,
    in_async: bool = false,
    in_loop: bool = false,
    in_class: bool = false,
    /// Inside a parameter list, where `yield`/`await` are illegal even in a
    /// generator or async function.
    in_params: bool = false,

    fn nest(self: Ctx) Ctx {
        var c = self;
        c.depth += 1;
        return c;
    }
};

const max_depth = 4;

const Gen = struct {
    rand: std.Random,
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    weights: [feature_count]u32,
    /// Monotonic, so no binding is ever declared twice in the same scope.
    next_name: u32 = 0,

    fn write(g: *Gen, bytes: []const u8) std.mem.Allocator.Error!void {
        try g.out.appendSlice(g.gpa, bytes);
    }

    fn print(g: *Gen, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        try g.out.print(g.gpa, fmt, args);
    }

    fn freshName(g: *Gen) u32 {
        const n = g.next_name;
        g.next_name += 1;
        return n;
    }

    /// Weighted choice among the enabled productions of `cat` that are legal in
    /// `ctx`. Falls back to the category's always-enabled terminal.
    fn choose(g: *Gen, cat: Category, ctx: Ctx) Feature {
        var total: u32 = 0;
        for (g.weights, 0..) |w, i| {
            const f: Feature = @enumFromInt(i);
            if (f.category() != cat or !legal(f, ctx)) continue;
            total += w;
        }
        if (total == 0) return fallback(cat);

        var roll = g.rand.intRangeLessThan(u32, 0, total);
        for (g.weights, 0..) |w, i| {
            const f: Feature = @enumFromInt(i);
            if (f.category() != cat or !legal(f, ctx)) continue;
            if (roll < w) return f;
            roll -= w;
        }
        unreachable;
    }

    fn fallback(cat: Category) Feature {
        return switch (cat) {
            .statement => .st_expr,
            .expression => .ex_number,
            .pattern => .pat_ident,
            .param => .param_simple,
            .class_element => .cls_method,
        };
    }

    /// The context rules. Everything the grammar forbids here is filtered out,
    /// so the generator cannot emit a program the parser is right to reject.
    fn legal(f: Feature, ctx: Ctx) bool {
        // At the depth limit only terminals remain, or generation never ends.
        const terminal = switch (f) {
            .st_expr, .st_empty, .st_debugger => true,
            .ex_ident, .ex_number, .ex_string, .ex_regex, .ex_this => true,
            .pat_ident, .param_simple, .cls_method => true,
            else => false,
        };
        if (ctx.depth >= max_depth and !terminal) return false;

        return switch (f) {
            .st_return => ctx.in_function,
            .ex_yield => ctx.in_generator and !ctx.in_params,
            .ex_await => ctx.in_async and !ctx.in_params,
            .ex_this => ctx.in_function or ctx.in_class,
            .cls_private_field => ctx.in_class,
            else => true,
        };
    }

    // ---- statements --------------------------------------------------------

    fn statement(g: *Gen, ctx: Ctx) std.mem.Allocator.Error!void {
        switch (g.choose(.statement, ctx)) {
            .st_expr => {
                // Parenthesised: an expression statement may not begin with
                // `{`, `function`, `class`, or `let [`.
                try g.write("(");
                try g.expression(ctx.nest());
                try g.write(");\n");
            },
            .st_empty => try g.write(";\n"),
            .st_debugger => try g.write("debugger;\n"),
            .st_var => try g.declaration("var", ctx),
            .st_let => try g.declaration("let", ctx),
            .st_const => try g.declaration("const", ctx),
            .st_block => {
                try g.write("{\n");
                try g.statements(ctx.nest());
                try g.write("}\n");
            },
            .st_if => {
                try g.write("if (");
                try g.expression(ctx.nest());
                try g.write(") {\n");
                try g.statements(ctx.nest());
                try g.write("}");
                if (g.rand.boolean()) {
                    try g.write(" else {\n");
                    try g.statements(ctx.nest());
                    try g.write("}");
                }
                try g.write("\n");
            },
            .st_while => {
                try g.write("while (");
                try g.expression(ctx.nest());
                try g.write(") {\n");
                var c = ctx.nest();
                c.in_loop = true;
                try g.statements(c);
                try g.breakOrContinue(c);
                try g.write("}\n");
            },
            .st_do => {
                try g.write("do {\n");
                var c = ctx.nest();
                c.in_loop = true;
                try g.statements(c);
                try g.write("} while (");
                try g.expression(ctx.nest());
                try g.write(");\n");
            },
            .st_for => {
                const n = g.freshName();
                try g.print("for (let v{d} = ", .{n});
                try g.expression(ctx.nest());
                try g.print("; v{d}; v{d}++) {{\n", .{ n, n });
                var c = ctx.nest();
                c.in_loop = true;
                try g.statements(c);
                try g.write("}\n");
            },
            .st_for_in => try g.forInOf("in", ctx),
            .st_for_of => try g.forInOf("of", ctx),
            .st_func => try g.functionDecl("function", ctx),
            .st_generator => try g.functionDecl("function*", ctx),
            .st_async_func => try g.functionDecl("async function", ctx),
            .st_class => {
                try g.write("class ");
                try g.classTail(ctx.nest());
                try g.write("\n");
            },
            .st_try => {
                try g.write("try {\n");
                try g.statements(ctx.nest());
                try g.write("}");
                const has_catch = g.rand.boolean();
                if (has_catch) {
                    if (g.rand.boolean()) {
                        try g.print(" catch (v{d}) {{\n", .{g.freshName()});
                    } else {
                        try g.write(" catch {\n"); // optional catch binding
                    }
                    try g.statements(ctx.nest());
                    try g.write("}");
                }
                if (!has_catch or g.rand.boolean()) {
                    try g.write(" finally {\n");
                    try g.statements(ctx.nest());
                    try g.write("}");
                }
                try g.write("\n");
            },
            .st_switch => {
                try g.write("switch (");
                try g.expression(ctx.nest());
                try g.write(") {\ncase ");
                try g.expression(ctx.nest());
                try g.write(":\n");
                try g.statements(ctx.nest());
                if (g.rand.boolean()) try g.write("break;\n");
                if (g.rand.boolean()) {
                    try g.write("default:\n");
                    try g.statements(ctx.nest());
                }
                try g.write("}\n");
            },
            .st_labeled => {
                const n = g.freshName();
                try g.print("L{d}: while (0) {{ break L{d}; }}\n", .{ n, n });
            },
            .st_return => {
                std.debug.assert(ctx.in_function);
                try g.write("return");
                if (g.rand.boolean()) {
                    try g.write(" (");
                    try g.expression(ctx.nest());
                    try g.write(")");
                }
                try g.write(";\n");
            },
            .st_throw => {
                try g.write("throw (");
                try g.expression(ctx.nest());
                try g.write(");\n");
            },
            else => unreachable,
        }
    }

    fn declaration(g: *Gen, kw: []const u8, ctx: Ctx) std.mem.Allocator.Error!void {
        try g.print("{s} ", .{kw});
        // A declaration binds a *target*; the initialiser below is the only
        // `=` allowed here. Always present: `const` requires it, so does a
        // destructuring pattern.
        try g.bindingTarget(ctx.nest());
        try g.write(" = ");
        try g.expression(ctx.nest());
        try g.write(";\n");
    }

    fn forInOf(g: *Gen, op: []const u8, ctx: Ctx) std.mem.Allocator.Error!void {
        try g.print("for (const v{d} {s} ", .{ g.freshName(), op });
        try g.expression(ctx.nest());
        try g.write(") {\n");
        var c = ctx.nest();
        c.in_loop = true;
        try g.statements(c);
        try g.write("}\n");
    }

    fn functionDecl(g: *Gen, prefix: []const u8, ctx: Ctx) std.mem.Allocator.Error!void {
        try g.print("{s} f{d}", .{ prefix, g.freshName() });
        var c = ctx.nest();
        c.in_function = true;
        c.in_generator = std.mem.endsWith(u8, prefix, "*");
        c.in_async = std.mem.startsWith(u8, prefix, "async");
        c.in_loop = false; // `break` does not cross a function boundary
        try g.params(c);
        try g.write(" {\n");
        try g.statements(c);
        try g.write("}\n");
    }

    fn breakOrContinue(g: *Gen, ctx: Ctx) std.mem.Allocator.Error!void {
        std.debug.assert(ctx.in_loop);
        if (g.rand.boolean()) return;
        try g.write(if (g.rand.boolean()) "break;\n" else "continue;\n");
    }

    fn statements(g: *Gen, ctx: Ctx) std.mem.Allocator.Error!void {
        const n = if (ctx.depth >= max_depth) 1 else g.rand.intRangeAtMost(u32, 0, 3);
        var i: u32 = 0;
        while (i < n) : (i += 1) try g.statement(ctx);
    }

    // ---- expressions -------------------------------------------------------

    fn expression(g: *Gen, ctx: Ctx) std.mem.Allocator.Error!void {
        switch (g.choose(.expression, ctx)) {
            .ex_ident => try g.write("undefined"),
            .ex_number => try g.print("{d}", .{g.rand.intRangeAtMost(u32, 0, 999)}),
            .ex_string => try g.write("'s'"),
            .ex_template => {
                try g.write("`t${");
                try g.expression(ctx.nest());
                try g.write("}`");
            },
            .ex_tagged_template => {
                try g.write("String.raw`x${");
                try g.expression(ctx.nest());
                try g.write("}`");
            },
            .ex_regex => try g.write("/a[b-c]+/gi"),
            .ex_this => try g.write("this"),
            .ex_array => {
                try g.write("[");
                const n = g.rand.intRangeAtMost(u32, 0, 3);
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    if (i > 0) try g.write(", ");
                    if (g.rand.boolean()) try g.write("...");
                    try g.expression(ctx.nest());
                }
                try g.write("]");
            },
            .ex_object => try g.objectLiteral(ctx),
            .ex_arrow => try g.arrow(false, ctx),
            .ex_async_arrow => try g.arrow(true, ctx),
            .ex_func => {
                var c = ctx.nest();
                c.in_function = true;
                c.in_generator = false;
                c.in_async = false;
                c.in_loop = false;
                try g.write("(function ");
                try g.params(c);
                try g.write(" { ");
                try g.statements(c);
                try g.write(" })");
            },
            .ex_class => {
                try g.write("(class ");
                try g.classTail(ctx.nest());
                try g.write(")");
            },
            .ex_call => {
                try g.write("(");
                try g.expression(ctx.nest());
                try g.write(")(");
                try g.expression(ctx.nest());
                try g.write(")");
            },
            .ex_call_spread => {
                try g.write("(");
                try g.expression(ctx.nest());
                try g.write(")(...[");
                try g.expression(ctx.nest());
                try g.write("])");
            },
            .ex_new => {
                try g.write("(new (");
                try g.expression(ctx.nest());
                try g.write("))");
            },
            .ex_member => {
                try g.write("(");
                try g.expression(ctx.nest());
                try g.write(").p");
            },
            .ex_index => {
                try g.write("(");
                try g.expression(ctx.nest());
                try g.write(")[");
                try g.expression(ctx.nest());
                try g.write("]");
            },
            .ex_assign => try g.assign("=", ctx),
            .ex_compound_assign => try g.assign("+=", ctx),
            .ex_binary => {
                const ops = [_][]const u8{
                    "+",  "-",   "*",   "/", "%", "**", "<",
                    ">",  "===", "!==", "&", "|", "^",  "<<",
                    ">>",
                };
                try g.write("(");
                try g.expression(ctx.nest());
                try g.print(" {s} ", .{ops[g.rand.intRangeLessThan(usize, 0, ops.len)]});
                try g.expression(ctx.nest());
                try g.write(")");
            },
            .ex_logical => {
                // `??` may not be mixed with `&&`/`||` unparenthesised; every
                // operand here is already parenthesised, so this is safe.
                const ops = [_][]const u8{ "&&", "||", "??" };
                try g.write("(");
                try g.expression(ctx.nest());
                try g.print(" {s} ", .{ops[g.rand.intRangeLessThan(usize, 0, ops.len)]});
                try g.expression(ctx.nest());
                try g.write(")");
            },
            .ex_unary => {
                const ops = [_][]const u8{ "-", "+", "!", "~", "void " };
                try g.print("({s}", .{ops[g.rand.intRangeLessThan(usize, 0, ops.len)]});
                try g.expression(ctx.nest());
                try g.write(")");
            },
            .ex_update => try g.print("(v{d}++)", .{g.freshName()}),
            .ex_typeof => {
                try g.write("(typeof ");
                try g.expression(ctx.nest());
                try g.write(")");
            },
            .ex_delete => {
                try g.write("(delete (");
                try g.expression(ctx.nest());
                try g.write(").p)");
            },
            .ex_in => try g.relational("in", ctx),
            .ex_instanceof => try g.relational("instanceof", ctx),
            .ex_cond => {
                try g.write("(");
                try g.expression(ctx.nest());
                try g.write(" ? ");
                try g.expression(ctx.nest());
                try g.write(" : ");
                try g.expression(ctx.nest());
                try g.write(")");
            },
            .ex_seq => {
                try g.write("(");
                try g.expression(ctx.nest());
                try g.write(", ");
                try g.expression(ctx.nest());
                try g.write(")");
            },
            .ex_yield => {
                std.debug.assert(ctx.in_generator);
                try g.write("(yield ");
                if (g.rand.boolean()) {
                    try g.write("* [1]");
                } else {
                    try g.expression(ctx.nest());
                }
                try g.write(")");
            },
            .ex_await => {
                std.debug.assert(ctx.in_async);
                try g.write("(await ");
                try g.expression(ctx.nest());
                try g.write(")");
            },
            else => unreachable,
        }
    }

    fn assign(g: *Gen, op: []const u8, ctx: Ctx) std.mem.Allocator.Error!void {
        try g.print("(v{d} {s} ", .{ g.freshName(), op });
        try g.expression(ctx.nest());
        try g.write(")");
    }

    fn relational(g: *Gen, op: []const u8, ctx: Ctx) std.mem.Allocator.Error!void {
        try g.print("(('p') {s} ", .{op});
        try g.expression(ctx.nest());
        try g.write(")");
    }

    fn arrow(g: *Gen, is_async: bool, ctx: Ctx) std.mem.Allocator.Error!void {
        var c = ctx.nest();
        c.in_function = true;
        c.in_generator = false;
        c.in_async = is_async;
        c.in_loop = false;
        try g.write(if (is_async) "(async " else "(");
        try g.params(c);
        try g.write(" => { ");
        try g.statements(c);
        try g.write(" })");
    }

    fn objectLiteral(g: *Gen, ctx: Ctx) std.mem.Allocator.Error!void {
        try g.write("({");
        const n = g.rand.intRangeAtMost(u32, 0, 3);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            if (i > 0) try g.write(", ");
            switch (g.rand.intRangeLessThan(u8, 0, 5)) {
                0 => try g.write("undefined"), // shorthand
                1 => {
                    try g.write("[");
                    try g.expression(ctx.nest());
                    try g.write("]: ");
                    try g.expression(ctx.nest());
                },
                2 => {
                    try g.write("...");
                    try g.expression(ctx.nest());
                },
                3 => try g.print("get p{d}() {{ return 1; }}", .{g.freshName()}),
                else => {
                    try g.print("p{d}: ", .{g.freshName()});
                    try g.expression(ctx.nest());
                },
            }
        }
        try g.write("})");
    }

    // ---- binding patterns --------------------------------------------------
    //
    // The grammar distinguishes a BindingPattern (what `let` binds, what a
    // parameter names) from a BindingElement (a pattern with an optional
    // initialiser). Conflating them yields `let v0 = 1 = expr;`, which is not
    // JavaScript — so `bindingTarget` never emits a default, and `bindingElement`
    // emits at most one.

    fn bindingTarget(g: *Gen, ctx: Ctx) std.mem.Allocator.Error!void {
        // `pat_default` is not a target; re-roll it onto the identifier.
        const f = g.choose(.pattern, ctx);
        switch (f) {
            .pat_array => {
                try g.write("[");
                const n = g.rand.intRangeAtMost(u32, 1, 3);
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    if (i > 0) try g.write(", ");
                    try g.bindingElement(ctx.nest());
                }
                // A rest element is only legal last, and takes no initialiser.
                if (g.rand.boolean()) try g.print(", ...v{d}", .{g.freshName()});
                try g.write("]");
            },
            .pat_object => {
                try g.write("{");
                const n = g.rand.intRangeAtMost(u32, 1, 3);
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    if (i > 0) try g.write(", ");
                    try g.print("p{d}: ", .{i});
                    try g.bindingElement(ctx.nest());
                }
                if (g.rand.boolean()) try g.print(", ...v{d}", .{g.freshName()});
                try g.write("}");
            },
            else => try g.print("v{d}", .{g.freshName()}),
        }
    }

    fn bindingElement(g: *Gen, ctx: Ctx) std.mem.Allocator.Error!void {
        try g.bindingTarget(ctx);
        const defaults_enabled = g.weights[@intFromEnum(Feature.pat_default)] > 0;
        if (defaults_enabled and ctx.depth < max_depth and g.rand.boolean()) {
            try g.write(" = ");
            try g.expression(ctx.nest());
        }
    }

    // ---- parameters --------------------------------------------------------

    fn params(g: *Gen, ctx: Ctx) std.mem.Allocator.Error!void {
        var c = ctx;
        c.in_params = true;

        try g.write("(");
        const n = g.rand.intRangeAtMost(u32, 0, 3);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            if (i > 0) try g.write(", ");
            switch (g.choose(.param, c)) {
                .param_simple => try g.print("v{d}", .{g.freshName()}),
                .param_default => {
                    try g.print("v{d} = ", .{g.freshName()});
                    try g.expression(c.nest());
                },
                .param_pattern => try g.bindingElement(c.nest()),
                .param_rest => {
                    // Rest must be the last parameter, and takes no default.
                    try g.print("...v{d}", .{g.freshName()});
                    break;
                },
                else => unreachable,
            }
        }
        try g.write(")");
    }

    // ---- classes -----------------------------------------------------------

    fn classTail(g: *Gen, ctx: Ctx) std.mem.Allocator.Error!void {
        var c = ctx;
        c.in_class = true;
        c.in_loop = false;

        const derived = g.weights[@intFromEnum(Feature.cls_extends)] > 0 and g.rand.boolean();
        try g.print("C{d} ", .{g.freshName()});
        if (derived) try g.write("extends Object ");
        try g.write("{\n");
        // A derived constructor must call super() before touching `this`.
        if (derived) try g.write("constructor() { super(); }\n");

        const n = g.rand.intRangeAtMost(u32, 0, 3);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            var mc = c.nest();
            mc.in_function = true;
            mc.in_generator = false;
            mc.in_async = false;
            switch (g.choose(.class_element, c)) {
                .cls_method => {
                    try g.print("m{d}", .{g.freshName()});
                    try g.params(mc);
                    try g.write(" {\n");
                    try g.statements(mc);
                    try g.write("}\n");
                },
                .cls_static_method => {
                    try g.print("static m{d}", .{g.freshName()});
                    try g.params(mc);
                    try g.write(" {\n");
                    try g.statements(mc);
                    try g.write("}\n");
                },
                .cls_getter => try g.print("get g{d}() {{ return 1; }}\n", .{g.freshName()}),
                .cls_field => {
                    try g.print("f{d} = ", .{g.freshName()});
                    try g.expression(mc);
                    try g.write(";\n");
                },
                .cls_private_field => try g.print("#x{d} = 1;\n", .{g.freshName()}),
                .cls_extends => {}, // consumed above
                else => unreachable,
            }
        }
        try g.write("}");
    }
};

/// Swarm: disable a random subset of productions outright, weight the rest over
/// two orders of magnitude. The always-enabled terminals are restored after, so
/// the generator can always bottom out.
fn swarmWeights(rand: std.Random, weights: *[feature_count]u32) void {
    const enabled = rand.intRangeAtMost(usize, 1, feature_count);
    @memset(weights, 0);

    var pool: [feature_count]u8 = undefined;
    for (&pool, 0..) |*p, i| p.* = @intCast(i);
    var remaining: usize = feature_count;
    var picked: usize = 0;
    while (picked < enabled) : (picked += 1) {
        const j = rand.intRangeLessThan(usize, 0, remaining);
        weights[pool[j]] = rand.intRangeAtMost(u32, 1, 100);
        remaining -= 1;
        pool[j] = pool[remaining];
    }
    for (always_enabled) |f| {
        if (weights[@intFromEnum(f)] == 0) weights[@intFromEnum(f)] = 1;
    }
}

const Outcome = union(enum) {
    /// The parser's own diagnostic, so a rejection can be triaged without
    /// re-running by hand.
    parse_error: struct { message: []const u8, pos: u32 },
    compile_gap,
    compiled,
};

/// Parse, and compile whatever parses. Never panics, never leaks.
fn exercise(gpa: std.mem.Allocator, source: []const u8) !Outcome {
    var pr = bottlebrush.parser.parse(gpa, source, .script) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.SyntaxError => return .{ .parse_error = .{ .message = "?", .pos = 0 } },
    };
    switch (pr) {
        .syntax_error => |d| return .{ .parse_error = .{ .message = d.message, .pos = d.pos } },
        .ok => |*tree| {
            defer tree.deinit();
            var cr = bottlebrush.compiler.compile(gpa, tree.root, source) catch |e| switch (e) {
                error.OutOfMemory => return e,
                // A declined construct is a documented gap, not a crash.
                error.Unsupported, error.BadCode => return .compile_gap,
            };
            switch (cr) {
                .compile_error => return .compile_gap,
                .ok => |*program| {
                    program.deinit();
                    return .compiled;
                },
            }
        },
    }
}

test "swarm fuzz: the parser accepts every valid program the grammar emits" {
    const gpa = testing.allocator;

    // A failing run is worthless if you cannot repeat it. The seed defaults to
    // the low 64 bits of `git rev-parse HEAD`, so even a crash that bypasses
    // this handler reproduces from the commit alone.
    errdefer std.debug.print(
        "\nfuzz seed={d}  (replay: zig build test-fuzz -Dfuzz-seed={d})\n",
        .{ options.seed, options.seed },
    );

    var prng = std.Random.DefaultPrng.init(options.seed);
    const rand = prng.random();

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);

    var weights: [feature_count]u32 = undefined;
    var compiled: u32 = 0;

    var run: u32 = 0;
    while (run < options.runs) : (run += 1) {
        // One swarm per run: the enabled set holds for the whole program, so a
        // run is thematically coherent rather than uniformly average.
        swarmWeights(rand, &weights);

        source.clearRetainingCapacity();
        if (rand.boolean()) try source.appendSlice(gpa, "\"use strict\";\n");

        var gen = Gen{ .rand = rand, .out = &source, .gpa = gpa, .weights = weights };
        const stmts = rand.intRangeAtMost(u32, 1, 6);
        var i: u32 = 0;
        while (i < stmts) : (i += 1) try gen.statement(.{});

        const outcome = exercise(gpa, source.items) catch |e| {
            std.debug.print("fuzz run={d} errored on:\n{s}\n", .{ run, source.items });
            return e;
        };
        // The oracle. The generator only emits productions legal in context,
        // with unique binding names, so nothing it produces may be rejected.
        // A syntax error here is a parser bug.
        switch (outcome) {
            .parse_error => |d| {
                std.debug.print(
                    "fuzz run={d}: parser rejected a valid program: {s} (at {d})\n{s}\n",
                    .{ run, d.message, d.pos, source.items },
                );
                return error.ValidProgramRejected;
            },
            .compiled => compiled += 1,
            .compile_gap => {},
        }
    }
    // Guard against the generator degenerating into `;;;` and proving nothing.
    try testing.expect(compiled > options.runs / 4);
}

test "byte fuzz: the lexer survives arbitrary input" {
    // Valid-by-construction generation never reaches the lexer's error paths,
    // so keep the uniform token soup too. Here the only oracle is "does not
    // crash, does not leak", which is all a byte fuzzer can offer.
    const gpa = testing.allocator;
    errdefer std.debug.print("\nfuzz seed={d}\n", .{options.seed});

    var prng = std.Random.DefaultPrng.init(options.seed ^ 0x5DEECE66D);
    const rand = prng.random();

    const alphabet = "abc123 (){}[];,.=+-*/%<>!&|?:'\"`\\\n\t" ++
        "/*use strict*/functionreturnvarletconst=>...#";
    var buf: [128]u8 = undefined;
    var i: u32 = 0;
    while (i < options.runs) : (i += 1) {
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        for (buf[0..len]) |*b| b.* = alphabet[rand.intRangeLessThan(usize, 0, alphabet.len)];
        _ = exercise(gpa, buf[0..len]) catch |e| {
            std.debug.print("fuzz run={d} errored on bytes:\n{s}\n", .{ i, buf[0..len] });
            return e;
        };
    }
}
