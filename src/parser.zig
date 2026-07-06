//! Recursive-descent parser producing the `ast.Node` tree.
//!
//! Expressions use precedence climbing; arrow functions and other cover
//! grammars are handled by backtracking (snapshot/restore of lexer+token
//! state). ASI is implemented in `semicolon`. Regex-vs-division and template
//! continuations are resolved by driving the lexer's rescans at the right
//! grammar positions.
//!
//! Scope (phase-1): covers the core of the language well enough to accept the
//! bulk of real programs and to reject clear syntax errors — the signal the
//! Test262 parse-phase corpus checks. Some early-error checks and the full
//! destructuring cover-grammar reinterpretation are intentionally lenient for
//! now (noted inline); they tighten in later passes.

const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");
const Lexer = @import("lexer.zig").Lexer;
const Kind = token.Kind;
const Token = token.Token;
const Node = ast.Node;

pub const Diagnostic = struct {
    message: []const u8,
    pos: u32,
    line: u32,
};

pub const Result = union(enum) {
    ok: ast.Ast,
    syntax_error: Diagnostic,
};

const ParseError = error{ SyntaxError, OutOfMemory };

pub const Parser = struct {
    source: []const u8,
    lexer: Lexer,
    cur: Token,
    prev_end: u32 = 0,
    arena: std.mem.Allocator,
    strict: bool,
    source_type: ast.SourceType,
    /// Disallow the `in` operator (inside a for-loop header). RAII-style saved.
    no_in: bool = false,
    diag: ?Diagnostic = null,

    const Snapshot = struct {
        pos: u32,
        line: u32,
        saw_newline: bool,
        cur: Token,
        prev_end: u32,
    };

    fn save(self: *Parser) Snapshot {
        return .{
            .pos = self.lexer.pos,
            .line = self.lexer.line,
            .saw_newline = self.lexer.saw_newline,
            .cur = self.cur,
            .prev_end = self.prev_end,
        };
    }
    fn restore(self: *Parser, s: Snapshot) void {
        self.lexer.pos = s.pos;
        self.lexer.line = s.line;
        self.lexer.saw_newline = s.saw_newline;
        self.cur = s.cur;
        self.prev_end = s.prev_end;
    }

    // ---- token stream ------------------------------------------------------

    fn advance(self: *Parser) void {
        self.prev_end = self.cur.end;
        self.cur = self.lexer.next();
    }
    fn at(self: *const Parser, k: Kind) bool {
        return self.cur.kind == k;
    }
    fn eat(self: *Parser, k: Kind) bool {
        if (self.at(k)) {
            self.advance();
            return true;
        }
        return false;
    }
    fn expect(self: *Parser, k: Kind) ParseError!void {
        if (!self.eat(k)) return self.fail("unexpected token");
    }
    fn fail(self: *Parser, msg: []const u8) ParseError {
        if (self.diag == null) {
            self.diag = .{ .message = msg, .pos = self.cur.start, .line = self.cur.line };
        }
        return error.SyntaxError;
    }

    /// Is `cur` a contextual keyword with the given spelling (an identifier)?
    fn atContextual(self: *const Parser, word: []const u8) bool {
        return self.cur.kind == .identifier and
            std.mem.eql(u8, self.cur.lexeme(self.source), word);
    }

    /// ASI: consume a `;`, or insert one before `}`, EOF, or a line break.
    fn semicolon(self: *Parser) ParseError!void {
        if (self.eat(.semicolon)) return;
        if (self.at(.r_brace) or self.at(.eof) or self.cur.newline_before) return;
        return self.fail("expected semicolon");
    }

    // ---- allocation helpers ------------------------------------------------

    fn node(self: *Parser, start: u32, end: u32, kind: Node.Kind) ParseError!*Node {
        const n = try self.arena.create(Node);
        n.* = .{ .start = start, .end = end, .kind = kind };
        return n;
    }

    const NodeList = std.ArrayList(*Node);
    const OptNodeList = std.ArrayList(?*Node);

    // ---- program -----------------------------------------------------------

    pub fn parseProgram(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        var body: NodeList = .empty;
        // Directive prologue: an initial "use strict" enables strict mode.
        try self.parseDirectivePrologue(&body);
        while (!self.at(.eof)) {
            try body.append(self.arena, try self.parseStatementListItem());
        }
        return self.node(start, self.prev_end, .{ .program = .{
            .body = try body.toOwnedSlice(self.arena),
            .source_type = self.source_type,
        } });
    }

    fn parseDirectivePrologue(self: *Parser, body: *NodeList) ParseError!void {
        while (self.at(.string)) {
            const s = self.save();
            const lit = self.cur.lexeme(self.source);
            const start = self.cur.start;
            self.advance();
            // A directive is a string literal followed by a statement end.
            if (self.at(.semicolon) or self.at(.r_brace) or self.at(.eof) or self.cur.newline_before) {
                _ = self.eat(.semicolon);
                if (std.mem.eql(u8, lit, "\"use strict\"") or std.mem.eql(u8, lit, "'use strict'")) {
                    self.strict = true;
                }
                const str = try self.node(start, self.prev_end, .{ .string = lit });
                try body.append(self.arena, try self.node(start, self.prev_end, .{ .expression_stmt = str }));
            } else {
                // Not a directive (e.g. `"x".length`); reparse as a statement.
                self.restore(s);
                break;
            }
        }
    }

    // ---- statements --------------------------------------------------------

    fn parseStatementListItem(self: *Parser) ParseError!*Node {
        switch (self.cur.kind) {
            .kw_function => return self.parseFunctionDeclaration(false),
            .kw_class => return self.parseClassDeclaration(),
            .kw_const => return self.parseVarStatement(.keyword_const),
            .kw_import => if (self.source_type == .module) return self.parseImport(),
            .kw_export => if (self.source_type == .module) return self.parseExport(),
            .identifier => {
                if (self.atContextual("let")) return self.parseVarStatement(.let);
                if (self.atContextual("async") and self.peekIsFunctionNoBreak()) {
                    return self.parseFunctionDeclaration(false);
                }
            },
            else => {},
        }
        return self.parseStatement();
    }

    /// After `async`, is the next token `function` with no line break between?
    fn peekIsFunctionNoBreak(self: *Parser) bool {
        const s = self.save();
        defer self.restore(s);
        self.advance();
        return self.at(.kw_function) and !self.cur.newline_before;
    }

    fn parseStatement(self: *Parser) ParseError!*Node {
        switch (self.cur.kind) {
            .l_brace => return self.parseBlock(),
            .semicolon => {
                const start = self.cur.start;
                self.advance();
                return self.node(start, self.prev_end, .empty_stmt);
            },
            .kw_var => return self.parseVarStatement(.keyword_var),
            .kw_if => return self.parseIf(),
            .kw_for => return self.parseFor(),
            .kw_while => return self.parseWhile(),
            .kw_do => return self.parseDoWhile(),
            .kw_switch => return self.parseSwitch(),
            .kw_try => return self.parseTry(),
            .kw_return => return self.parseReturn(),
            .kw_throw => return self.parseThrow(),
            .kw_break => return self.parseBreakContinue(true),
            .kw_continue => return self.parseBreakContinue(false),
            .kw_with => return self.parseWith(),
            .kw_debugger => {
                const start = self.cur.start;
                self.advance();
                try self.semicolon();
                return self.node(start, self.prev_end, .debugger_stmt);
            },
            .kw_function => return self.parseFunctionDeclaration(false),
            .kw_class => return self.parseClassDeclaration(),
            else => return self.parseExpressionOrLabeled(),
        }
    }

    fn parseBlock(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        try self.expect(.l_brace);
        var body: NodeList = .empty;
        while (!self.at(.r_brace) and !self.at(.eof)) {
            try body.append(self.arena, try self.parseStatementListItem());
        }
        try self.expect(.r_brace);
        return self.node(start, self.prev_end, .{ .block_stmt = try body.toOwnedSlice(self.arena) });
    }

    fn parseVarStatement(self: *Parser, kind: ast.VarKind) ParseError!*Node {
        const decl = try self.parseVarDeclaration(kind);
        try self.semicolon();
        return decl;
    }

    fn parseVarDeclaration(self: *Parser, kind: ast.VarKind) ParseError!*Node {
        const start = self.cur.start;
        self.advance(); // var/let/const keyword or `let` identifier
        var decls: NodeList = .empty;
        while (true) {
            const d_start = self.cur.start;
            const id = try self.parseBindingTarget();
            var init_expr: ?*Node = null;
            if (self.eat(.assign)) init_expr = try self.parseAssignment();
            try decls.append(self.arena, try self.node(d_start, self.prev_end, .{
                .variable_declarator = .{ .id = id, .init = init_expr },
            }));
            if (!self.eat(.comma)) break;
        }
        return self.node(start, self.prev_end, .{ .var_decl = .{
            .kind = kind,
            .decls = try decls.toOwnedSlice(self.arena),
        } });
    }

    fn parseIf(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        self.advance();
        try self.expect(.l_paren);
        const cond = try self.parseExpression();
        try self.expect(.r_paren);
        const then_branch = try self.parseStatement();
        var else_branch: ?*Node = null;
        if (self.eat(.kw_else)) else_branch = try self.parseStatement();
        return self.node(start, self.prev_end, .{ .if_stmt = .{
            .cond = cond,
            .then_branch = then_branch,
            .else_branch = else_branch,
        } });
    }

    fn parseFor(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        self.advance();
        const is_await = self.atContextual("await");
        if (is_await) self.advance();
        try self.expect(.l_paren);

        // Header init: a declaration, an expression, or empty.
        var init_node: ?*Node = null;
        if (self.at(.semicolon)) {
            // no init
        } else if (self.at(.kw_var) or self.at(.kw_const) or self.atContextual("let")) {
            const kind: ast.VarKind = if (self.at(.kw_var)) .keyword_var else if (self.at(.kw_const)) .keyword_const else .let;
            self.no_in = true;
            init_node = try self.parseVarDeclaration(kind);
            self.no_in = false;
        } else {
            self.no_in = true;
            init_node = try self.parseExpression();
            self.no_in = false;
        }

        // for-in / for-of
        if (self.at(.kw_in) or self.atContextual("of")) {
            const is_of = self.atContextual("of");
            self.advance();
            const right = if (is_of) try self.parseAssignment() else try self.parseExpression();
            try self.expect(.r_paren);
            const body = try self.parseStatement();
            const left = init_node.?;
            if (is_of) {
                return self.node(start, self.prev_end, .{ .for_of_stmt = .{
                    .left = left,
                    .right = right,
                    .body = body,
                    .is_await = is_await,
                } });
            }
            return self.node(start, self.prev_end, .{ .for_in_stmt = .{
                .left = left,
                .right = right,
                .body = body,
            } });
        }

        // C-style for(;;)
        try self.expect(.semicolon);
        var cond: ?*Node = null;
        if (!self.at(.semicolon)) cond = try self.parseExpression();
        try self.expect(.semicolon);
        var update: ?*Node = null;
        if (!self.at(.r_paren)) update = try self.parseExpression();
        try self.expect(.r_paren);
        const body = try self.parseStatement();
        return self.node(start, self.prev_end, .{ .for_stmt = .{
            .init = init_node,
            .cond = cond,
            .update = update,
            .body = body,
        } });
    }

    fn parseWhile(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        self.advance();
        try self.expect(.l_paren);
        const cond = try self.parseExpression();
        try self.expect(.r_paren);
        const body = try self.parseStatement();
        return self.node(start, self.prev_end, .{ .while_stmt = .{ .cond = cond, .body = body } });
    }

    fn parseDoWhile(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        self.advance();
        const body = try self.parseStatement();
        if (!self.eat(.kw_while)) return self.fail("expected 'while'");
        try self.expect(.l_paren);
        const cond = try self.parseExpression();
        try self.expect(.r_paren);
        _ = self.eat(.semicolon);
        return self.node(start, self.prev_end, .{ .do_while_stmt = .{ .body = body, .cond = cond } });
    }

    fn parseSwitch(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        self.advance();
        try self.expect(.l_paren);
        const disc = try self.parseExpression();
        try self.expect(.r_paren);
        try self.expect(.l_brace);
        var cases: NodeList = .empty;
        while (!self.at(.r_brace) and !self.at(.eof)) {
            const c_start = self.cur.start;
            var test_expr: ?*Node = null;
            if (self.eat(.kw_case)) {
                test_expr = try self.parseExpression();
            } else if (!self.eat(.kw_default)) {
                return self.fail("expected 'case' or 'default'");
            }
            try self.expect(.colon);
            var body: NodeList = .empty;
            while (!self.at(.kw_case) and !self.at(.kw_default) and !self.at(.r_brace) and !self.at(.eof)) {
                try body.append(self.arena, try self.parseStatementListItem());
            }
            try cases.append(self.arena, try self.node(c_start, self.prev_end, .{ .switch_case = .{
                .test_expr = test_expr,
                .body = try body.toOwnedSlice(self.arena),
            } }));
        }
        try self.expect(.r_brace);
        return self.node(start, self.prev_end, .{ .switch_stmt = .{
            .discriminant = disc,
            .cases = try cases.toOwnedSlice(self.arena),
        } });
    }

    fn parseTry(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        self.advance();
        const block = try self.parseBlock();
        var handler: ?*Node = null;
        var finalizer: ?*Node = null;
        if (self.at(.kw_catch)) {
            const h_start = self.cur.start;
            self.advance();
            var param: ?*Node = null;
            if (self.eat(.l_paren)) {
                param = try self.parseBindingTarget();
                try self.expect(.r_paren);
            }
            const h_body = try self.parseBlock();
            handler = try self.node(h_start, self.prev_end, .{ .catch_clause = .{ .param = param, .body = h_body } });
        }
        if (self.eat(.kw_finally)) finalizer = try self.parseBlock();
        if (handler == null and finalizer == null) return self.fail("missing catch or finally");
        return self.node(start, self.prev_end, .{ .try_stmt = .{
            .block = block,
            .handler = handler,
            .finalizer = finalizer,
        } });
    }

    fn parseReturn(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        self.advance();
        var arg: ?*Node = null;
        if (!self.at(.semicolon) and !self.at(.r_brace) and !self.at(.eof) and !self.cur.newline_before) {
            arg = try self.parseExpression();
        }
        try self.semicolon();
        return self.node(start, self.prev_end, .{ .return_stmt = arg });
    }

    fn parseThrow(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        self.advance();
        if (self.cur.newline_before) return self.fail("illegal newline after throw");
        const arg = try self.parseExpression();
        try self.semicolon();
        return self.node(start, self.prev_end, .{ .throw_stmt = arg });
    }

    fn parseBreakContinue(self: *Parser, is_break: bool) ParseError!*Node {
        const start = self.cur.start;
        self.advance();
        var label: ?[]const u8 = null;
        if (self.at(.identifier) and !self.cur.newline_before) {
            label = self.cur.lexeme(self.source);
            self.advance();
        }
        try self.semicolon();
        return self.node(start, self.prev_end, if (is_break)
            .{ .break_stmt = label }
        else
            .{ .continue_stmt = label });
    }

    fn parseWith(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        self.advance();
        try self.expect(.l_paren);
        const obj = try self.parseExpression();
        try self.expect(.r_paren);
        const body = try self.parseStatement();
        return self.node(start, self.prev_end, .{ .with_stmt = .{ .object = obj, .body = body } });
    }

    fn parseExpressionOrLabeled(self: *Parser) ParseError!*Node {
        // `ident :` is a labeled statement.
        if (self.at(.identifier)) {
            const s = self.save();
            const label = self.cur.lexeme(self.source);
            const start = self.cur.start;
            self.advance();
            if (self.eat(.colon)) {
                const body = try self.parseStatement();
                return self.node(start, self.prev_end, .{ .labeled_stmt = .{ .label = label, .body = body } });
            }
            self.restore(s);
        }
        const start = self.cur.start;
        const expr = try self.parseExpression();
        try self.semicolon();
        return self.node(start, self.prev_end, .{ .expression_stmt = expr });
    }

    // ---- functions & classes ----------------------------------------------

    fn parseFunctionDeclaration(self: *Parser, is_expr: bool) ParseError!*Node {
        const start = self.cur.start;
        var flags: ast.FunctionFlags = .{};
        if (self.atContextual("async")) {
            flags.is_async = true;
            self.advance();
        }
        try self.expect(.kw_function);
        if (self.eat(.star)) flags.is_generator = true;
        var name: ?[]const u8 = null;
        if (self.at(.identifier)) {
            name = self.cur.lexeme(self.source);
            self.advance();
        } else if (!is_expr) {
            return self.fail("function declaration requires a name");
        }
        const params = try self.parseParams();
        const body = try self.parseBlock();
        const func: ast.Function = .{ .name = name, .params = params, .body = body, .flags = flags };
        return self.node(start, self.prev_end, if (is_expr)
            .{ .function = func }
        else
            .{ .function_decl = func });
    }

    fn parseParams(self: *Parser) ParseError![]*Node {
        try self.expect(.l_paren);
        var params: NodeList = .empty;
        while (!self.at(.r_paren) and !self.at(.eof)) {
            if (self.at(.ellipsis)) {
                const r_start = self.cur.start;
                self.advance();
                const target = try self.parseBindingTarget();
                try params.append(self.arena, try self.node(r_start, self.prev_end, .{ .rest_element = target }));
                break;
            }
            try params.append(self.arena, try self.parseBindingElement());
            if (!self.eat(.comma)) break;
        }
        try self.expect(.r_paren);
        return params.toOwnedSlice(self.arena);
    }

    fn parseClassDeclaration(self: *Parser) ParseError!*Node {
        return self.parseClass(false);
    }

    fn parseClass(self: *Parser, is_expr: bool) ParseError!*Node {
        const start = self.cur.start;
        try self.expect(.kw_class);
        var name: ?[]const u8 = null;
        if (self.at(.identifier)) {
            name = self.cur.lexeme(self.source);
            self.advance();
        }
        var super_class: ?*Node = null;
        if (self.eat(.kw_extends)) super_class = try self.parseLeftHandSide();
        try self.expect(.l_brace);
        var members: NodeList = .empty;
        while (!self.at(.r_brace) and !self.at(.eof)) {
            if (self.eat(.semicolon)) continue;
            try members.append(self.arena, try self.parseClassMember());
        }
        try self.expect(.r_brace);
        const class: ast.Class = .{
            .name = name,
            .super_class = super_class,
            .members = try members.toOwnedSlice(self.arena),
        };
        return self.node(start, self.prev_end, if (is_expr) .{ .class = class } else .{ .class_decl = class });
    }

    fn parseClassMember(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        var is_static = false;
        if (self.atContextual("static")) {
            const s = self.save();
            self.advance();
            if (self.at(.l_paren) or self.at(.assign)) {
                self.restore(s); // `static` is actually the member name
            } else {
                is_static = true;
            }
        }
        var m_kind: ast.MethodKind = .method;
        var flags: ast.FunctionFlags = .{};
        if (self.atContextual("async")) {
            const s = self.save();
            self.advance();
            if (self.at(.l_paren) or self.at(.assign) or self.cur.newline_before) {
                self.restore(s);
            } else {
                flags.is_async = true;
            }
        }
        if (self.eat(.star)) flags.is_generator = true;
        if (self.atContextual("get") or self.atContextual("set")) {
            const is_get = self.atContextual("get");
            const s = self.save();
            self.advance();
            if (self.at(.l_paren) or self.at(.assign) or self.at(.semicolon) or self.at(.r_brace)) {
                self.restore(s); // `get`/`set` is the member name
            } else {
                m_kind = if (is_get) .get else .set;
            }
        }

        var computed = false;
        var is_private = false;
        const key = try self.parsePropertyKey(&computed, &is_private);

        if (self.at(.l_paren)) {
            // Method (or get/set/constructor).
            const params = try self.parseParams();
            const body = try self.parseBlock();
            const fnode = try self.node(start, self.prev_end, .{ .function = .{
                .name = null,
                .params = params,
                .body = body,
                .flags = flags,
            } });
            if (m_kind == .method and !computed and key.kind == .string) {
                // constructor detection is approximate; refined later.
            }
            return self.node(start, self.prev_end, .{ .property = .{
                .key = key,
                .value = fnode,
                .kind = switch (m_kind) {
                    .get => .get,
                    .set => .set,
                    else => .method,
                },
                .computed = computed,
            } });
        }

        // Field. (Phase 1 records fields as `property` nodes; static/private
        // flags are parsed for validity but not yet threaded into the AST.)
        var value: ?*Node = null;
        if (self.eat(.assign)) value = try self.parseAssignment();
        try self.semicolon();
        return self.node(start, self.prev_end, .{ .property = .{
            .key = key,
            .value = value,
            .kind = .init,
            .computed = computed,
        } });
    }

    // ---- binding targets / patterns ----------------------------------------

    fn parseBindingElement(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        const target = try self.parseBindingTarget();
        if (self.eat(.assign)) {
            const def = try self.parseAssignment();
            return self.node(start, self.prev_end, .{ .assignment_pattern = .{ .left = target, .right = def } });
        }
        return target;
    }

    fn parseBindingTarget(self: *Parser) ParseError!*Node {
        switch (self.cur.kind) {
            .identifier => return self.parseIdentifier(),
            .l_bracket => return self.parseArrayPattern(),
            .l_brace => return self.parseObjectPattern(),
            else => {
                // Contextual keywords are valid binding names in many positions.
                if (self.cur.kind.isKeyword()) return self.fail("unexpected keyword in binding");
                return self.fail("invalid binding target");
            },
        }
    }

    fn parseArrayPattern(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        try self.expect(.l_bracket);
        var elems: OptNodeList = .empty;
        while (!self.at(.r_bracket) and !self.at(.eof)) {
            if (self.eat(.comma)) {
                try elems.append(self.arena, null); // elision
                continue;
            }
            if (self.at(.ellipsis)) {
                const r_start = self.cur.start;
                self.advance();
                const t = try self.parseBindingTarget();
                try elems.append(self.arena, try self.node(r_start, self.prev_end, .{ .rest_element = t }));
                break;
            }
            try elems.append(self.arena, try self.parseBindingElement());
            if (!self.eat(.comma)) break;
        }
        try self.expect(.r_bracket);
        return self.node(start, self.prev_end, .{ .array_pattern = try elems.toOwnedSlice(self.arena) });
    }

    fn parseObjectPattern(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        try self.expect(.l_brace);
        var props: NodeList = .empty;
        while (!self.at(.r_brace) and !self.at(.eof)) {
            if (self.at(.ellipsis)) {
                const r_start = self.cur.start;
                self.advance();
                const t = try self.parseBindingTarget();
                try props.append(self.arena, try self.node(r_start, self.prev_end, .{ .rest_element = t }));
                break;
            }
            const p_start = self.cur.start;
            var computed = false;
            var is_private = false;
            const key = try self.parsePropertyKey(&computed, &is_private);
            var value: *Node = key;
            var shorthand = true;
            if (self.eat(.colon)) {
                value = try self.parseBindingElement();
                shorthand = false;
            } else if (self.eat(.assign)) {
                const def = try self.parseAssignment();
                value = try self.node(p_start, self.prev_end, .{ .assignment_pattern = .{ .left = key, .right = def } });
            }
            try props.append(self.arena, try self.node(p_start, self.prev_end, .{ .property = .{
                .key = key,
                .value = value,
                .kind = .init,
                .computed = computed,
                .shorthand = shorthand,
            } }));
            if (!self.eat(.comma)) break;
        }
        try self.expect(.r_brace);
        return self.node(start, self.prev_end, .{ .object_pattern = try props.toOwnedSlice(self.arena) });
    }

    fn parsePropertyKey(self: *Parser, computed: *bool, is_private: *bool) ParseError!*Node {
        if (self.eat(.l_bracket)) {
            computed.* = true;
            const expr = try self.parseAssignment();
            try self.expect(.r_bracket);
            return expr;
        }
        const start = self.cur.start;
        switch (self.cur.kind) {
            .string => {
                const lit = self.cur.lexeme(self.source);
                self.advance();
                return self.node(start, self.prev_end, .{ .string = lit });
            },
            .number, .bigint => {
                const raw = self.cur.lexeme(self.source);
                const bi = self.cur.kind == .bigint;
                self.advance();
                return self.node(start, self.prev_end, .{ .number = .{ .raw = raw, .bigint = bi } });
            },
            .private_identifier => {
                is_private.* = true;
                const name = self.cur.lexeme(self.source);
                self.advance();
                return self.node(start, self.prev_end, .{ .private_name = name });
            },
            else => {
                // Identifier or keyword used as a property name.
                if (self.cur.kind == .identifier or self.cur.kind.isKeyword()) {
                    const name = self.cur.lexeme(self.source);
                    self.advance();
                    return self.node(start, self.prev_end, .{ .ident = name });
                }
                return self.fail("invalid property key");
            },
        }
    }

    fn parseIdentifier(self: *Parser) ParseError!*Node {
        if (!self.at(.identifier)) return self.fail("expected identifier");
        const start = self.cur.start;
        const name = self.cur.lexeme(self.source);
        self.advance();
        return self.node(start, self.prev_end, .{ .ident = name });
    }

    // ---- expressions -------------------------------------------------------

    fn parseExpression(self: *Parser) ParseError!*Node {
        const first = try self.parseAssignment();
        if (!self.at(.comma)) return first;
        const start = first.start;
        var exprs: NodeList = .empty;
        try exprs.append(self.arena, first);
        while (self.eat(.comma)) {
            try exprs.append(self.arena, try self.parseAssignment());
        }
        return self.node(start, self.prev_end, .{ .sequence = try exprs.toOwnedSlice(self.arena) });
    }

    fn parseAssignment(self: *Parser) ParseError!*Node {
        // Arrow functions (cover grammar) — try, then backtrack.
        if (try self.tryParseArrow()) |arrow| return arrow;

        if (self.atContextual("yield")) return self.parseYield();

        const start = self.cur.start;
        const left = try self.parseConditional();
        if (assignmentOp(self.cur.kind)) |op| {
            self.advance();
            const right = try self.parseAssignment();
            return self.node(start, self.prev_end, .{ .assignment = .{ .op = op, .target = left, .value = right } });
        }
        return left;
    }

    fn parseYield(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        self.advance(); // yield
        const delegate = self.eat(.star);
        var arg: ?*Node = null;
        if (!self.cur.newline_before and !self.at(.semicolon) and !self.at(.r_paren) and
            !self.at(.r_brace) and !self.at(.r_bracket) and !self.at(.comma) and
            !self.at(.colon) and !self.at(.eof))
        {
            arg = try self.parseAssignment();
        }
        return self.node(start, self.prev_end, .{ .yield_expr = .{ .argument = arg, .delegate = delegate } });
    }

    /// Attempt to parse an arrow function; returns null (and restores state) if
    /// the input is not an arrow.
    fn tryParseArrow(self: *Parser) ParseError!?*Node {
        const s = self.save();
        const start = self.cur.start;
        var flags: ast.FunctionFlags = .{ .is_arrow = true };

        if (self.atContextual("async")) {
            // `async` arrow only if no line break before params and it's not a call.
            const after = self.save();
            self.advance();
            if (self.cur.newline_before or (!self.at(.identifier) and !self.at(.l_paren))) {
                self.restore(after);
            } else {
                flags.is_async = true;
            }
        }

        var params: []*Node = &.{};
        if (self.at(.identifier)) {
            const id = self.parseIdentifier() catch {
                self.restore(s);
                return null;
            };
            const one = self.arena.alloc(*Node, 1) catch return error.OutOfMemory;
            one[0] = id;
            params = one;
        } else if (self.at(.l_paren)) {
            params = self.parseParams() catch {
                self.restore(s);
                return null;
            };
        } else {
            self.restore(s);
            return null;
        }

        if (!self.at(.arrow) or self.cur.newline_before) {
            self.restore(s);
            return null;
        }
        self.advance(); // =>

        var expression_body = false;
        const body = if (self.at(.l_brace))
            try self.parseBlock()
        else blk: {
            expression_body = true;
            break :blk try self.parseAssignment();
        };
        flags.expression_body = expression_body;
        return try self.node(start, self.prev_end, .{ .function = .{
            .name = null,
            .params = params,
            .body = body,
            .flags = flags,
        } });
    }

    fn parseConditional(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        const cond = try self.parseBinary(0);
        if (!self.eat(.question)) return cond;
        const then_expr = try self.parseAssignment();
        try self.expect(.colon);
        const else_expr = try self.parseAssignment();
        return self.node(start, self.prev_end, .{ .conditional = .{
            .cond = cond,
            .then_expr = then_expr,
            .else_expr = else_expr,
        } });
    }

    fn parseBinary(self: *Parser, min_prec: u8) ParseError!*Node {
        var left = try self.parseUnary();
        while (true) {
            const op = self.cur.kind;
            if (op == .kw_in and self.no_in) break;
            const prec = binaryPrec(op) orelse break;
            if (prec < min_prec) break;
            const is_logical = op == .amp_amp or op == .pipe_pipe or op == .question_question;
            const right_assoc = op == .star_star;
            self.advance();
            const next_min = if (right_assoc) prec else prec + 1;
            const right = try self.parseBinary(next_min);
            const start = left.start;
            left = try self.node(start, self.prev_end, if (is_logical)
                .{ .logical = .{ .op = op, .left = left, .right = right } }
            else
                .{ .binary = .{ .op = op, .left = left, .right = right } });
        }
        return left;
    }

    fn parseUnary(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        switch (self.cur.kind) {
            .kw_delete, .kw_void, .kw_typeof, .plus, .minus, .tilde, .bang => {
                const op = self.cur.kind;
                self.advance();
                const operand = try self.parseUnary();
                return self.node(start, self.prev_end, .{ .unary = .{ .op = op, .operand = operand } });
            },
            .plus_plus, .minus_minus => {
                const op = self.cur.kind;
                self.advance();
                const operand = try self.parseUnary();
                return self.node(start, self.prev_end, .{ .update = .{ .op = op, .operand = operand, .prefix = true } });
            },
            else => {
                if (self.atContextual("await")) {
                    self.advance();
                    const operand = try self.parseUnary();
                    return self.node(start, self.prev_end, .{ .await_expr = operand });
                }
                return self.parsePostfix();
            },
        }
    }

    fn parsePostfix(self: *Parser) ParseError!*Node {
        const expr = try self.parseLeftHandSide();
        if ((self.at(.plus_plus) or self.at(.minus_minus)) and !self.cur.newline_before) {
            const op = self.cur.kind;
            self.advance();
            return self.node(expr.start, self.prev_end, .{ .update = .{ .op = op, .operand = expr, .prefix = false } });
        }
        return expr;
    }

    fn parseLeftHandSide(self: *Parser) ParseError!*Node {
        const expr = if (self.at(.kw_new)) try self.parseNew() else try self.parsePrimary();
        return self.parseCallMemberTail(expr);
    }

    fn parseNew(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        self.advance(); // new
        if (self.eat(.dot)) {
            // new.target
            if (!self.atContextual("target")) return self.fail("expected 'target'");
            self.advance();
            return self.node(start, self.prev_end, .{ .meta_property = .{ .meta = "new", .property = "target" } });
        }
        const callee = if (self.at(.kw_new)) try self.parseNew() else try self.parseMemberOnly(try self.parsePrimary());
        var args: []*Node = &.{};
        if (self.at(.l_paren)) args = try self.parseArguments();
        return self.node(start, self.prev_end, .{ .new_expr = .{ .callee = callee, .args = args } });
    }

    /// Member accesses only (no call) — used for the callee of `new`.
    fn parseMemberOnly(self: *Parser, base: *Node) ParseError!*Node {
        var expr = base;
        while (true) {
            if (self.eat(.dot)) {
                const prop = try self.parseMemberProperty();
                expr = try self.node(expr.start, self.prev_end, .{ .member = .{ .object = expr, .property = prop, .computed = false, .optional = false } });
            } else if (self.eat(.l_bracket)) {
                const prop = try self.parseExpression();
                try self.expect(.r_bracket);
                expr = try self.node(expr.start, self.prev_end, .{ .member = .{ .object = expr, .property = prop, .computed = true, .optional = false } });
            } else break;
        }
        return expr;
    }

    fn parseCallMemberTail(self: *Parser, base: *Node) ParseError!*Node {
        var expr = base;
        while (true) {
            switch (self.cur.kind) {
                .dot => {
                    self.advance();
                    const prop = try self.parseMemberProperty();
                    expr = try self.node(expr.start, self.prev_end, .{ .member = .{ .object = expr, .property = prop, .computed = false, .optional = false } });
                },
                .l_bracket => {
                    self.advance();
                    const prop = try self.parseExpression();
                    try self.expect(.r_bracket);
                    expr = try self.node(expr.start, self.prev_end, .{ .member = .{ .object = expr, .property = prop, .computed = true, .optional = false } });
                },
                .l_paren => {
                    const args = try self.parseArguments();
                    expr = try self.node(expr.start, self.prev_end, .{ .call = .{ .callee = expr, .args = args, .optional = false } });
                },
                .question_dot => {
                    self.advance();
                    if (self.at(.l_paren)) {
                        const args = try self.parseArguments();
                        expr = try self.node(expr.start, self.prev_end, .{ .call = .{ .callee = expr, .args = args, .optional = true } });
                    } else if (self.eat(.l_bracket)) {
                        const prop = try self.parseExpression();
                        try self.expect(.r_bracket);
                        expr = try self.node(expr.start, self.prev_end, .{ .member = .{ .object = expr, .property = prop, .computed = true, .optional = true } });
                    } else {
                        const prop = try self.parseMemberProperty();
                        expr = try self.node(expr.start, self.prev_end, .{ .member = .{ .object = expr, .property = prop, .computed = false, .optional = true } });
                    }
                },
                .template_no_sub, .template_head => {
                    const quasi = try self.parseTemplate();
                    expr = try self.node(expr.start, self.prev_end, .{ .tagged_template = .{ .tag = expr, .quasi = quasi } });
                },
                else => break,
            }
        }
        return expr;
    }

    fn parseMemberProperty(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        if (self.at(.private_identifier)) {
            const name = self.cur.lexeme(self.source);
            self.advance();
            return self.node(start, self.prev_end, .{ .private_name = name });
        }
        if (self.at(.identifier) or self.cur.kind.isKeyword()) {
            const name = self.cur.lexeme(self.source);
            self.advance();
            return self.node(start, self.prev_end, .{ .ident = name });
        }
        return self.fail("expected property name");
    }

    fn parseArguments(self: *Parser) ParseError![]*Node {
        try self.expect(.l_paren);
        var args: NodeList = .empty;
        while (!self.at(.r_paren) and !self.at(.eof)) {
            if (self.at(.ellipsis)) {
                const r_start = self.cur.start;
                self.advance();
                const arg = try self.parseAssignment();
                try args.append(self.arena, try self.node(r_start, self.prev_end, .{ .spread = arg }));
            } else {
                try args.append(self.arena, try self.parseAssignment());
            }
            if (!self.eat(.comma)) break;
        }
        try self.expect(.r_paren);
        return args.toOwnedSlice(self.arena);
    }

    fn parsePrimary(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        switch (self.cur.kind) {
            .identifier => return self.parseIdentifier(),
            .private_identifier => {
                // `#x in obj` ergonomic brand check.
                const name = self.cur.lexeme(self.source);
                self.advance();
                return self.node(start, self.prev_end, .{ .private_name = name });
            },
            .number, .bigint => {
                const raw = self.cur.lexeme(self.source);
                const bi = self.cur.kind == .bigint;
                self.advance();
                return self.node(start, self.prev_end, .{ .number = .{ .raw = raw, .bigint = bi } });
            },
            .string => {
                const lit = self.cur.lexeme(self.source);
                self.advance();
                return self.node(start, self.prev_end, .{ .string = lit });
            },
            .slash, .slash_eq => {
                const re = self.lexer.reScanAsRegex(self.cur.start);
                self.cur = re;
                if (re.kind == .invalid) return self.fail("invalid regular expression");
                const raw = re.lexeme(self.source);
                self.advance();
                return self.node(start, self.prev_end, .{ .regex = raw });
            },
            .template_no_sub, .template_head => return self.parseTemplate(),
            .kw_true => {
                self.advance();
                return self.node(start, self.prev_end, .{ .bool_literal = true });
            },
            .kw_false => {
                self.advance();
                return self.node(start, self.prev_end, .{ .bool_literal = false });
            },
            .kw_null => {
                self.advance();
                return self.node(start, self.prev_end, .null_literal);
            },
            .kw_this => {
                self.advance();
                return self.node(start, self.prev_end, .this_expr);
            },
            .kw_super => {
                self.advance();
                return self.node(start, self.prev_end, .super_expr);
            },
            .kw_function => return self.parseFunctionDeclaration(true),
            .kw_class => return self.parseClass(true),
            .kw_import => {
                self.advance();
                if (self.eat(.dot)) {
                    if (!self.atContextual("meta")) return self.fail("expected 'meta'");
                    self.advance();
                    return self.node(start, self.prev_end, .{ .meta_property = .{ .meta = "import", .property = "meta" } });
                }
                // dynamic import()
                const args = try self.parseArguments();
                const callee = try self.node(start, start, .{ .ident = "import" });
                return self.node(start, self.prev_end, .{ .call = .{ .callee = callee, .args = args, .optional = false } });
            },
            .l_paren => {
                self.advance();
                const expr = try self.parseExpression();
                try self.expect(.r_paren);
                return expr;
            },
            .l_bracket => return self.parseArrayLiteral(),
            .l_brace => return self.parseObjectLiteral(),
            else => {
                if (self.atContextual("async") and self.peekIsFunctionNoBreak()) {
                    return self.parseFunctionDeclaration(true);
                }
                return self.fail("unexpected token in expression");
            },
        }
    }

    fn parseTemplate(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        var quasis: std.ArrayList([]const u8) = .empty;
        var exprs: NodeList = .empty;

        if (self.at(.template_no_sub)) {
            try quasis.append(self.arena, self.cur.lexeme(self.source));
            self.advance();
            return self.node(start, self.prev_end, .{ .template = .{
                .quasis = try quasis.toOwnedSlice(self.arena),
                .exprs = try exprs.toOwnedSlice(self.arena),
            } });
        }

        // template_head ... (expr) (middle ... expr)* tail
        try quasis.append(self.arena, self.cur.lexeme(self.source));
        self.advance();
        while (true) {
            try exprs.append(self.arena, try self.parseExpression());
            // The embedded expression ends at a `}` token; rescan it as a
            // template continuation (middle or tail).
            if (!self.at(.r_brace)) return self.fail("unterminated template expression");
            const cont = self.lexer.reScanTemplateContinuation(self.cur.start);
            self.cur = cont;
            if (cont.kind == .invalid) return self.fail("unterminated template literal");
            try quasis.append(self.arena, cont.lexeme(self.source));
            const is_tail = cont.kind == .template_tail;
            self.advance();
            if (is_tail) break;
        }
        return self.node(start, self.prev_end, .{ .template = .{
            .quasis = try quasis.toOwnedSlice(self.arena),
            .exprs = try exprs.toOwnedSlice(self.arena),
        } });
    }

    fn parseArrayLiteral(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        try self.expect(.l_bracket);
        var elems: OptNodeList = .empty;
        while (!self.at(.r_bracket) and !self.at(.eof)) {
            if (self.at(.comma)) {
                self.advance();
                try elems.append(self.arena, null); // elision
                continue;
            }
            if (self.at(.ellipsis)) {
                const r_start = self.cur.start;
                self.advance();
                const arg = try self.parseAssignment();
                try elems.append(self.arena, try self.node(r_start, self.prev_end, .{ .spread = arg }));
            } else {
                try elems.append(self.arena, try self.parseAssignment());
            }
            if (!self.at(.r_bracket) and !self.eat(.comma)) break;
        }
        try self.expect(.r_bracket);
        return self.node(start, self.prev_end, .{ .array_literal = try elems.toOwnedSlice(self.arena) });
    }

    fn parseObjectLiteral(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        try self.expect(.l_brace);
        var props: NodeList = .empty;
        while (!self.at(.r_brace) and !self.at(.eof)) {
            try props.append(self.arena, try self.parseObjectMember());
            if (!self.eat(.comma)) break;
        }
        try self.expect(.r_brace);
        return self.node(start, self.prev_end, .{ .object_literal = try props.toOwnedSlice(self.arena) });
    }

    fn parseObjectMember(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        if (self.at(.ellipsis)) {
            self.advance();
            const arg = try self.parseAssignment();
            return self.node(start, self.prev_end, .{ .property = .{
                .key = arg,
                .value = null,
                .kind = .spread,
            } });
        }

        var flags: ast.FunctionFlags = .{};
        var m_kind: ast.PropKind = .init;
        if (self.atContextual("async")) {
            const s = self.save();
            self.advance();
            if (self.at(.colon) or self.at(.comma) or self.at(.r_brace) or self.at(.l_paren) or self.cur.newline_before) {
                self.restore(s);
            } else {
                flags.is_async = true;
            }
        }
        if (self.eat(.star)) flags.is_generator = true;
        if (self.atContextual("get") or self.atContextual("set")) {
            const is_get = self.atContextual("get");
            const s = self.save();
            self.advance();
            if (self.at(.colon) or self.at(.comma) or self.at(.r_brace) or self.at(.l_paren)) {
                self.restore(s);
            } else {
                m_kind = if (is_get) .get else .set;
            }
        }

        var computed = false;
        var is_private = false;
        const key = try self.parsePropertyKey(&computed, &is_private);

        if (self.at(.l_paren)) {
            const params = try self.parseParams();
            const body = try self.parseBlock();
            const fnode = try self.node(start, self.prev_end, .{ .function = .{
                .name = null,
                .params = params,
                .body = body,
                .flags = flags,
            } });
            return self.node(start, self.prev_end, .{ .property = .{
                .key = key,
                .value = fnode,
                .kind = m_kind,
                .computed = computed,
            } });
        }

        if (self.eat(.colon)) {
            const value = try self.parseAssignment();
            return self.node(start, self.prev_end, .{ .property = .{
                .key = key,
                .value = value,
                .kind = .init,
                .computed = computed,
            } });
        }

        // Shorthand `{ x }` or `{ x = default }` (cover for destructuring).
        var value: *Node = key;
        if (self.eat(.assign)) {
            const def = try self.parseAssignment();
            value = try self.node(start, self.prev_end, .{ .assignment_pattern = .{ .left = key, .right = def } });
        }
        return self.node(start, self.prev_end, .{ .property = .{
            .key = key,
            .value = value,
            .kind = .init,
            .computed = computed,
            .shorthand = true,
        } });
    }

    // ---- modules -----------------------------------------------------------

    fn parseImport(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        self.advance(); // import
        var specifiers: NodeList = .empty;
        if (self.at(.string)) {
            // bare `import "mod";`
            const src = self.cur.lexeme(self.source);
            self.advance();
            try self.semicolon();
            return self.node(start, self.prev_end, .{ .import_decl = .{
                .specifiers = try specifiers.toOwnedSlice(self.arena),
                .source = src,
            } });
        }
        // default and/or namespace and/or named
        if (self.at(.identifier)) {
            const local = self.cur.lexeme(self.source);
            const s0 = self.cur.start;
            self.advance();
            try specifiers.append(self.arena, try self.node(s0, self.prev_end, .{ .import_specifier = .{
                .local = local,
                .imported = null,
                .kind = .default,
            } }));
            _ = self.eat(.comma);
        }
        if (self.eat(.star)) {
            if (!self.atContextual("as")) return self.fail("expected 'as'");
            self.advance();
            const local = self.cur.lexeme(self.source);
            const s0 = self.prev_end;
            try self.expectIdentifier();
            try specifiers.append(self.arena, try self.node(s0, self.prev_end, .{ .import_specifier = .{
                .local = local,
                .imported = null,
                .kind = .namespace,
            } }));
        } else if (self.at(.l_brace)) {
            self.advance();
            while (!self.at(.r_brace) and !self.at(.eof)) {
                const s0 = self.cur.start;
                const imported = self.cur.lexeme(self.source);
                if (!self.at(.identifier) and !self.at(.string) and !self.cur.kind.isKeyword()) return self.fail("expected import name");
                self.advance();
                var local = imported;
                if (self.atContextual("as")) {
                    self.advance();
                    local = self.cur.lexeme(self.source);
                    try self.expectIdentifier();
                }
                try specifiers.append(self.arena, try self.node(s0, self.prev_end, .{ .import_specifier = .{
                    .local = local,
                    .imported = imported,
                    .kind = .named,
                } }));
                if (!self.eat(.comma)) break;
            }
            try self.expect(.r_brace);
        }
        if (!self.atContextual("from")) return self.fail("expected 'from'");
        self.advance();
        if (!self.at(.string)) return self.fail("expected module specifier");
        const src = self.cur.lexeme(self.source);
        self.advance();
        try self.semicolon();
        return self.node(start, self.prev_end, .{ .import_decl = .{
            .specifiers = try specifiers.toOwnedSlice(self.arena),
            .source = src,
        } });
    }

    fn parseExport(self: *Parser) ParseError!*Node {
        const start = self.cur.start;
        self.advance(); // export
        if (self.eat(.kw_default)) {
            const decl = if (self.at(.kw_function) or self.atContextual("async"))
                try self.parseFunctionDeclaration(false)
            else if (self.at(.kw_class))
                try self.parseClassDeclaration()
            else blk: {
                const e = try self.parseAssignment();
                try self.semicolon();
                break :blk e;
            };
            return self.node(start, self.prev_end, .{ .export_default = decl });
        }
        if (self.eat(.star)) {
            var exported: ?[]const u8 = null;
            if (self.atContextual("as")) {
                self.advance();
                exported = self.cur.lexeme(self.source);
                try self.expectIdentifier();
            }
            if (!self.atContextual("from")) return self.fail("expected 'from'");
            self.advance();
            const src = self.cur.lexeme(self.source);
            if (!self.at(.string)) return self.fail("expected module specifier");
            self.advance();
            try self.semicolon();
            return self.node(start, self.prev_end, .{ .export_all = .{ .exported = exported, .source = src } });
        }
        if (self.at(.l_brace)) {
            self.advance();
            var specs: NodeList = .empty;
            while (!self.at(.r_brace) and !self.at(.eof)) {
                const s0 = self.cur.start;
                const local = self.cur.lexeme(self.source);
                self.advance();
                var exported = local;
                if (self.atContextual("as")) {
                    self.advance();
                    exported = self.cur.lexeme(self.source);
                    self.advance();
                }
                try specs.append(self.arena, try self.node(s0, self.prev_end, .{ .export_specifier = .{
                    .local = local,
                    .exported = exported,
                } }));
                if (!self.eat(.comma)) break;
            }
            try self.expect(.r_brace);
            var src: ?[]const u8 = null;
            if (self.atContextual("from")) {
                self.advance();
                src = self.cur.lexeme(self.source);
                self.advance();
            }
            try self.semicolon();
            return self.node(start, self.prev_end, .{ .export_named = .{
                .specifiers = try specs.toOwnedSlice(self.arena),
                .source = src,
                .declaration = null,
            } });
        }
        // export <declaration>
        const decl = try self.parseStatementListItem();
        return self.node(start, self.prev_end, .{ .export_named = .{
            .specifiers = &.{},
            .source = null,
            .declaration = decl,
        } });
    }

    fn expectIdentifier(self: *Parser) ParseError!void {
        if (!self.at(.identifier)) return self.fail("expected identifier");
        self.advance();
    }
};

// ---- operator tables -------------------------------------------------------

fn assignmentOp(k: Kind) ?Kind {
    return switch (k) {
        .assign,
        .plus_eq,
        .minus_eq,
        .star_eq,
        .slash_eq,
        .percent_eq,
        .star_star_eq,
        .shl_eq,
        .shr_eq,
        .ushr_eq,
        .amp_eq,
        .pipe_eq,
        .caret_eq,
        .amp_amp_eq,
        .pipe_pipe_eq,
        .question_question_eq,
        => k,
        else => null,
    };
}

fn binaryPrec(k: Kind) ?u8 {
    return switch (k) {
        .question_question => 1,
        .pipe_pipe => 2,
        .amp_amp => 3,
        .pipe => 4,
        .caret => 5,
        .amp => 6,
        .eq_eq, .not_eq, .eq_eq_eq, .not_eq_eq => 7,
        .lt, .gt, .lt_eq, .gt_eq, .kw_instanceof, .kw_in => 8,
        .shl, .shr, .ushr => 9,
        .plus, .minus => 10,
        .star, .slash, .percent => 11,
        .star_star => 12,
        else => null,
    };
}

// ---- public entry ----------------------------------------------------------

pub fn parse(gpa: std.mem.Allocator, source: []const u8, source_type: ast.SourceType) ParseError!Result {
    var arena = std.heap.ArenaAllocator.init(gpa);
    var p = Parser{
        .source = source,
        .lexer = Lexer.init(source),
        .cur = undefined,
        .arena = arena.allocator(),
        .strict = source_type == .module,
        .source_type = source_type,
    };
    p.cur = p.lexer.next();

    const root = p.parseProgram() catch |e| switch (e) {
        error.OutOfMemory => {
            arena.deinit();
            return error.OutOfMemory;
        },
        error.SyntaxError => {
            const diag = p.diag orelse Diagnostic{ .message = "syntax error", .pos = p.cur.start, .line = p.cur.line };
            arena.deinit();
            return .{ .syntax_error = diag };
        },
    };

    return .{ .ok = .{
        .arena = arena,
        .root = root,
        .source = source,
        .source_type = source_type,
    } };
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn expectParses(source: []const u8) !void {
    var r = try parse(testing.allocator, source, .script);
    switch (r) {
        .ok => |*a| a.deinit(),
        .syntax_error => |d| {
            std.debug.print("unexpected syntax error: {s} at {d}\n", .{ d.message, d.pos });
            return error.UnexpectedSyntaxError;
        },
    }
}

fn expectRejects(source: []const u8) !void {
    var r = try parse(testing.allocator, source, .script);
    switch (r) {
        .ok => |*a| {
            a.deinit();
            return error.ExpectedSyntaxError;
        },
        .syntax_error => {},
    }
}

test "parses expressions" {
    try expectParses("1 + 2 * 3 - 4 / 5;");
    try expectParses("a = b ? c : d;");
    try expectParses("x = 1 ?? 2 || 3 && 4;");
    try expectParses("-a ** 2;");
    try expectParses("!a === typeof b;");
    try expectParses("a.b.c[d](e, ...f);");
    try expectParses("obj?.a?.[b]?.(c);");
    try expectParses("new Foo(1, 2).bar;");
    try expectParses("new.target;");
}

test "parses statements" {
    try expectParses("var a = 1, b, c = 3;");
    try expectParses("let x = 1; const y = 2;");
    try expectParses("if (a) b(); else c();");
    try expectParses("for (let i = 0; i < 10; i++) f(i);");
    try expectParses("for (const k in obj) g(k);");
    try expectParses("for (const v of arr) h(v);");
    try expectParses("while (a) { b(); }");
    try expectParses("do x(); while (y);");
    try expectParses("switch (a) { case 1: b(); break; default: c(); }");
    try expectParses("try { a(); } catch (e) { b(e); } finally { c(); }");
    try expectParses("try { a(); } catch { b(); }");
    try expectParses("throw new Error('x');");
    try expectParses("label: for (;;) break label;");
    try expectParses("with (o) { x; }");
    try expectParses(";;;");
}

test "parses functions and classes" {
    try expectParses("function f(a, b = 1, ...rest) { return a + b; }");
    try expectParses("const g = (x) => x * 2;");
    try expectParses("const h = x => { return x; };");
    try expectParses("const j = async (a, b) => a + b;");
    try expectParses("async function k() { await p; }");
    try expectParses("function* gen() { yield 1; yield* other; }");
    try expectParses("class A extends B { constructor() { super(); } method() {} get x() { return 1; } static s() {} #priv = 1; }");
}

test "parses destructuring and templates" {
    try expectParses("const [a, , b, ...c] = arr;");
    try expectParses("const { x, y: z, w = 1, ...rest } = obj;");
    try expectParses("const s = `a${b}c${d}e`;");
    try expectParses("tag`hello ${name}`;");
    try expectParses("const o = { a, b: 1, [c]: 2, m() {}, get g() { return 1; } };");
}

test "parses ASI" {
    try expectParses("var a = 1\nvar b = 2");
    try expectParses("return\n"); // in a function context this ASIs; at top level it's an error, but we only lex/parse
    try expectParses("a\nb\nc");
}

test "parses regex vs division" {
    try expectParses("var re = /ab+c/gi;");
    try expectParses("var x = a / b / c;");
    try expectParses("f(/pattern/);");
}

test "rejects syntax errors" {
    try expectRejects("var = 1;");
    try expectRejects("function () {}"); // declaration needs a name
    try expectRejects("1 +;");
    try expectRejects("if (a b();");
    try expectRejects("{ unterminated ;");
    try expectRejects("for (;;");
    try expectRejects(")(");
}

test "parses modules" {
    var r = try parse(testing.allocator, "import a, { b, c as d } from 'm'; export { a }; export default 1; export * from 'n';", .module);
    switch (r) {
        .ok => |*a| a.deinit(),
        .syntax_error => |d| {
            std.debug.print("module parse error: {s}\n", .{d.message});
            return error.UnexpectedSyntaxError;
        },
    }
}
