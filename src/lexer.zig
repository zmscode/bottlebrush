//! The lexer: source bytes → tokens.
//!
//! Design (phase-1 plan §1):
//!   * `next()` skips whitespace/comments (tracking whether a line terminator
//!     was crossed, for ASI) then scans one token.
//!   * `/` is ambiguous (division vs regex literal). The lexer emits a `slash`
//!     or `slash_eq` token by default; the parser calls `reScanAsRegex` when a
//!     regex is grammatically expected.
//!   * Template continuations (`}...${`, `}...\``) are re-lexed on demand via
//!     `reScanTemplateContinuation`, since the parser parses the embedded
//!     expression between the pieces.
//!   * Syntax errors during lexing produce a `.invalid` token; `err_message`
//!     holds a human-readable reason. The parser turns these into SyntaxError.
//!
//! Scope notes: full Unicode ID_Start/ID_Continue tables are deferred — ASCII
//! plus `$`/`_`, `\u` escapes, and (optimistically) any byte >= 0x80 are
//! treated as identifier characters. Cooked string/template values are not
//! computed yet (Phase 1 is parse-focused); the tokens carry source spans and
//! escape *syntax* is validated.

const std = @import("std");
const token = @import("token.zig");
const Kind = token.Kind;
const Token = token.Token;

pub const Lexer = struct {
    source: []const u8,
    pos: u32 = 0,
    line: u32 = 1,
    /// Set when a line terminator is crossed while skipping trivia.
    saw_newline: bool = false,
    /// Reason for the most recent `.invalid` token.
    err_message: ?[]const u8 = null,

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source };
    }

    // ---- low-level cursor --------------------------------------------------

    fn at(self: *const Lexer, offset: u32) u8 {
        const i = self.pos + offset;
        return if (i < self.source.len) self.source[i] else 0;
    }

    fn peek(self: *const Lexer) u8 {
        return self.at(0);
    }

    fn peek1(self: *const Lexer) u8 {
        return self.at(1);
    }

    fn peek2(self: *const Lexer) u8 {
        return self.at(2);
    }

    fn eof(self: *const Lexer) bool {
        return self.pos >= self.source.len;
    }

    fn bump(self: *Lexer) void {
        self.pos += 1;
    }

    fn make(self: *Lexer, kind: Kind, start: u32, line: u32) Token {
        return .{
            .kind = kind,
            .start = start,
            .end = self.pos,
            .line = line,
            .newline_before = self.saw_newline,
        };
    }

    fn fail(self: *Lexer, start: u32, line: u32, msg: []const u8) Token {
        self.err_message = msg;
        return .{
            .kind = .invalid,
            .start = start,
            .end = self.pos,
            .line = line,
            .newline_before = self.saw_newline,
        };
    }

    // ---- trivia ------------------------------------------------------------

    fn isLineTerminator(c: u8) bool {
        return c == '\n' or c == '\r';
    }

    fn skipTrivia(self: *Lexer) void {
        self.saw_newline = false;
        while (!self.eof()) {
            const c = self.peek();
            switch (c) {
                ' ', '\t', 0x0b, 0x0c => self.bump(),
                '\n' => {
                    self.line += 1;
                    self.saw_newline = true;
                    self.bump();
                },
                '\r' => {
                    self.line += 1;
                    self.saw_newline = true;
                    self.bump();
                    if (self.peek() == '\n') self.bump(); // CRLF = one line
                },
                '/' => {
                    if (self.peek1() == '/') {
                        self.skipLineComment();
                    } else if (self.peek1() == '*') {
                        self.skipBlockComment();
                    } else return;
                },
                else => {
                    // Non-ASCII whitespace (NBSP, ZWNBSP/BOM, U+2028/2029) —
                    // minimal handling; full Unicode WhiteSpace is deferred.
                    if (c >= 0x80) {
                        // Leave it for the token scanner (treated as id char).
                        return;
                    }
                    return;
                },
            }
        }
    }

    fn skipLineComment(self: *Lexer) void {
        self.bump(); // '/'
        self.bump(); // '/'
        while (!self.eof() and !isLineTerminator(self.peek())) self.bump();
    }

    fn skipBlockComment(self: *Lexer) void {
        self.bump(); // '/'
        self.bump(); // '*'
        while (!self.eof()) {
            const c = self.peek();
            if (c == '*' and self.peek1() == '/') {
                self.bump();
                self.bump();
                return;
            }
            if (c == '\n') {
                self.line += 1;
                self.saw_newline = true;
            }
            self.bump();
        }
        // Unterminated block comment: err surfaced by the next token being EOF;
        // parsers treat trailing unterminated comment as a syntax error upstream.
    }

    // ---- main scan ---------------------------------------------------------

    pub fn next(self: *Lexer) Token {
        self.skipTrivia();
        const start = self.pos;
        const line = self.line;
        if (self.eof()) return self.make(.eof, start, line);

        const c = self.peek();

        // Identifiers / keywords. A leading backslash only begins an
        // identifier when it is a `\u` escape; otherwise it's an error handled
        // by the punctuator path (which advances, avoiding an infinite loop).
        if (isIdentStart(c) or (c == '\\' and self.peek1() == 'u') or c >= 0x80) {
            return self.scanIdentifier(start, line);
        }
        // Numbers.
        if (isDigit(c)) return self.scanNumber(start, line);
        if (c == '.' and isDigit(self.peek1())) return self.scanNumber(start, line);

        switch (c) {
            '"', '\'' => return self.scanString(start, line, c),
            '`' => return self.scanTemplate(start, line),
            '#' => {
                self.bump();
                if (!isIdentStart(self.peek()) and self.peek() != '\\') {
                    return self.fail(start, line, "invalid private identifier");
                }
                return self.scanIdentifierTail(start, line, .private_identifier);
            },
            else => return self.scanPunctuator(start, line),
        }
    }

    // ---- identifiers -------------------------------------------------------

    fn scanIdentifier(self: *Lexer, start: u32, line: u32) Token {
        return self.scanIdentifierTail(start, line, .identifier);
    }

    fn scanIdentifierTail(self: *Lexer, start: u32, line: u32, base_kind: Kind) Token {
        var escaped = false;
        while (!self.eof()) {
            const c = self.peek();
            if (isIdentPart(c) or c >= 0x80) {
                self.bump();
            } else if (c == '\\' and self.peek1() == 'u') {
                // Unicode escape in identifier: validate shape, skip it.
                escaped = true;
                if (!self.consumeUnicodeEscape()) {
                    return self.fail(start, line, "invalid unicode escape in identifier");
                }
            } else break;
        }
        if (base_kind == .private_identifier) {
            var t = self.make(.private_identifier, start, line);
            t.escaped = escaped;
            return t;
        }
        const text = self.source[start..self.pos];
        if (!escaped) {
            return self.make(token.keywordKind(text), start, line);
        }
        // An escaped identifier is lexically always an `Identifier` (a keyword
        // spelled with an escape is legal as a property name; whether it's a
        // ReservedWord violation elsewhere is the parser's context-aware call).
        var t = self.make(.identifier, start, line);
        t.escaped = escaped;
        return t;
    }

    /// Decode an identifier's `\uHHHH` / `\u{H+}` escapes into `buf` (UTF-8),
    /// yielding its canonical spelling; null if it overflows or is malformed.
    pub fn decodeIdentifier(text: []const u8, buf: []u8) ?[]const u8 {
        var out: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] != '\\') {
                if (out >= buf.len) return null;
                buf[out] = text[i];
                out += 1;
                i += 1;
                continue;
            }
            // `\u` escape.
            if (i + 1 >= text.len or text[i + 1] != 'u') return null;
            i += 2;
            var cp: u32 = 0;
            if (i < text.len and text[i] == '{') {
                i += 1;
                while (i < text.len and text[i] != '}') : (i += 1) {
                    cp = cp * 16 + (hexVal(text[i]) orelse return null);
                }
                if (i >= text.len) return null;
                i += 1; // '}'
            } else {
                var k: usize = 0;
                while (k < 4) : (k += 1) {
                    if (i >= text.len) return null;
                    cp = cp * 16 + (hexVal(text[i]) orelse return null);
                    i += 1;
                }
            }
            const n = std.unicode.utf8Encode(@intCast(cp), buf[out..]) catch return null;
            out += n;
        }
        return buf[0..out];
    }

    /// Consume `\uHHHH` or `\u{H+}` starting at the backslash. Returns false on
    /// malformed escape.
    fn consumeUnicodeEscape(self: *Lexer) bool {
        self.bump(); // backslash
        if (self.peek() != 'u') return false;
        self.bump(); // u
        if (self.peek() == '{') {
            self.bump();
            var any = false;
            while (isHexDigit(self.peek())) : (self.bump()) any = true;
            if (!any or self.peek() != '}') return false;
            self.bump(); // }
            return true;
        }
        var i: u32 = 0;
        while (i < 4) : (i += 1) {
            if (!isHexDigit(self.peek())) return false;
            self.bump();
        }
        return true;
    }

    // ---- numbers -----------------------------------------------------------

    fn scanNumber(self: *Lexer, start: u32, line: u32) Token {
        var is_bigint_allowed = true;

        if (self.peek() == '0') {
            const r = self.peek1();
            switch (r) {
                'x', 'X' => return self.scanRadix(start, line, isHexDigit),
                'o', 'O' => return self.scanRadix(start, line, isOctalDigit),
                'b', 'B' => return self.scanRadix(start, line, isBinaryDigit),
                '0'...'9' => {
                    // Legacy octal / non-octal decimal (e.g. 0777, 08). The
                    // parser rejects these in strict mode; here we just scan.
                    is_bigint_allowed = false;
                    while (isDigit(self.peek())) self.bump();
                    return self.make(.number, start, line);
                },
                else => {},
            }
        }

        // Decimal integer part (with separators).
        self.consumeDigits(isDigit);

        if (self.peek() == '.') {
            is_bigint_allowed = false;
            self.bump();
            self.consumeDigits(isDigit);
        }
        if (self.peek() == 'e' or self.peek() == 'E') {
            is_bigint_allowed = false;
            self.bump();
            if (self.peek() == '+' or self.peek() == '-') self.bump();
            if (!isDigit(self.peek())) return self.fail(start, line, "missing exponent");
            self.consumeDigits(isDigit);
        }

        if (is_bigint_allowed and self.peek() == 'n') {
            self.bump();
            return self.make(.bigint, start, line);
        }

        // An identifier char immediately after a number is a syntax error
        // (e.g. `3in`), but we leave that check to the parser for now.
        return self.make(.number, start, line);
    }

    fn scanRadix(self: *Lexer, start: u32, line: u32, comptime isValid: fn (u8) bool) Token {
        self.bump(); // 0
        self.bump(); // radix letter
        var any = false;
        while (true) {
            const c = self.peek();
            if (isValid(c)) {
                any = true;
                self.bump();
            } else if (c == '_' and any) {
                self.bump();
            } else break;
        }
        if (!any) return self.fail(start, line, "missing digits after radix prefix");
        if (self.peek() == 'n') self.bump(); // BigInt
        return self.make(.number, start, line);
    }

    fn consumeDigits(self: *Lexer, comptime isValid: fn (u8) bool) void {
        while (true) {
            const c = self.peek();
            if (isValid(c) or (c == '_' and isValid(self.peek1()))) {
                self.bump();
            } else break;
        }
    }

    // ---- strings -----------------------------------------------------------

    fn scanString(self: *Lexer, start: u32, line: u32, quote: u8) Token {
        self.bump(); // opening quote
        while (true) {
            if (self.eof()) return self.fail(start, line, "unterminated string literal");
            const c = self.peek();
            if (c == quote) {
                self.bump();
                return self.make(.string, start, line);
            }
            if (isLineTerminator(c)) {
                return self.fail(start, line, "unterminated string literal");
            }
            if (c == '\\') {
                if (!self.consumeStringEscape()) {
                    return self.fail(start, line, "invalid escape sequence");
                }
            } else {
                self.bump();
            }
        }
    }

    /// Consume an escape sequence starting at the backslash. Returns false for
    /// malformed `\x`/`\u` escapes. Line continuations are allowed.
    fn consumeStringEscape(self: *Lexer) bool {
        self.bump(); // backslash
        const c = self.peek();
        switch (c) {
            'x' => {
                self.bump();
                var i: u32 = 0;
                while (i < 2) : (i += 1) {
                    if (!isHexDigit(self.peek())) return false;
                    self.bump();
                }
                return true;
            },
            'u' => {
                // Reuse identifier-style validation: back up to the backslash.
                self.pos -= 1;
                return self.consumeUnicodeEscape();
            },
            '\r' => {
                self.line += 1;
                self.bump();
                if (self.peek() == '\n') self.bump();
                return true;
            },
            '\n' => {
                self.line += 1;
                self.bump();
                return true;
            },
            0 => return false, // trailing backslash at EOF
            else => {
                self.bump();
                return true;
            },
        }
    }

    // ---- templates ---------------------------------------------------------

    fn scanTemplate(self: *Lexer, start: u32, line: u32) Token {
        self.bump(); // backtick
        return self.scanTemplateBody(start, line, .template_no_sub, .template_head);
    }

    /// Called by the parser at a `}` that continues a template. `start` is the
    /// offset of the `}`.
    pub fn reScanTemplateContinuation(self: *Lexer, start: u32) Token {
        self.pos = start;
        self.bump(); // '}'
        return self.scanTemplateBody(start, self.line, .template_tail, .template_middle);
    }

    fn scanTemplateBody(
        self: *Lexer,
        start: u32,
        line: u32,
        end_kind: Kind, // reached closing backtick
        sub_kind: Kind, // reached ${
    ) Token {
        while (true) {
            if (self.eof()) return self.fail(start, line, "unterminated template literal");
            const c = self.peek();
            if (c == '`') {
                self.bump();
                return self.make(end_kind, start, line);
            }
            if (c == '$' and self.peek1() == '{') {
                self.bump();
                self.bump();
                return self.make(sub_kind, start, line);
            }
            if (c == '\\') {
                _ = self.consumeStringEscape(); // template escapes are lenient
                continue;
            }
            if (c == '\n') self.line += 1;
            self.bump();
        }
    }

    // ---- regex -------------------------------------------------------------

    /// Re-lex a regex literal beginning at `start` (the `/`). The default
    /// `next()` would have produced `slash`/`slash_eq` there.
    pub fn reScanAsRegex(self: *Lexer, start: u32) Token {
        self.pos = start;
        const line = self.line;
        self.bump(); // '/'
        var in_class = false;
        while (true) {
            if (self.eof()) return self.fail(start, line, "unterminated regex literal");
            const c = self.peek();
            if (isLineTerminator(c)) return self.fail(start, line, "unterminated regex literal");
            if (c == '\\') {
                self.bump();
                if (self.eof() or isLineTerminator(self.peek()))
                    return self.fail(start, line, "unterminated regex literal");
                self.bump();
                continue;
            }
            if (c == '[') in_class = true;
            if (c == ']') in_class = false;
            if (c == '/' and !in_class) {
                self.bump();
                break;
            }
            self.bump();
        }
        // Flags: identifier-part characters.
        while (isIdentPart(self.peek())) self.bump();
        return self.make(.regex, start, line);
    }

    // ---- punctuators -------------------------------------------------------

    fn scanPunctuator(self: *Lexer, start: u32, line: u32) Token {
        const c = self.peek();
        switch (c) {
            '(' => return self.single(.l_paren, start, line),
            ')' => return self.single(.r_paren, start, line),
            '{' => return self.single(.l_brace, start, line),
            '}' => return self.single(.r_brace, start, line),
            '[' => return self.single(.l_bracket, start, line),
            ']' => return self.single(.r_bracket, start, line),
            ';' => return self.single(.semicolon, start, line),
            ',' => return self.single(.comma, start, line),
            '~' => return self.single(.tilde, start, line),
            ':' => return self.single(.colon, start, line),
            '.' => {
                if (self.peek1() == '.' and self.peek2() == '.') {
                    self.bump();
                    self.bump();
                    self.bump();
                    return self.make(.ellipsis, start, line);
                }
                return self.single(.dot, start, line);
            },
            '?' => {
                if (self.peek1() == '.' and !isDigit(self.peek2())) {
                    self.bump();
                    self.bump();
                    return self.make(.question_dot, start, line);
                }
                if (self.peek1() == '?') {
                    self.bump();
                    self.bump();
                    if (self.peek() == '=') return self.single(.question_question_eq, start, line);
                    return self.make(.question_question, start, line);
                }
                return self.single(.question, start, line);
            },
            '=' => {
                if (self.peek1() == '=') {
                    self.bump();
                    self.bump();
                    if (self.peek() == '=') return self.single(.eq_eq_eq, start, line);
                    return self.make(.eq_eq, start, line);
                }
                if (self.peek1() == '>') {
                    self.bump();
                    self.bump();
                    return self.make(.arrow, start, line);
                }
                return self.single(.assign, start, line);
            },
            '!' => {
                if (self.peek1() == '=') {
                    self.bump();
                    self.bump();
                    if (self.peek() == '=') return self.single(.not_eq_eq, start, line);
                    return self.make(.not_eq, start, line);
                }
                return self.single(.bang, start, line);
            },
            '<' => {
                if (self.peek1() == '=') return self.double(.lt_eq, start, line);
                if (self.peek1() == '<') {
                    self.bump();
                    self.bump();
                    if (self.peek() == '=') return self.single(.shl_eq, start, line);
                    return self.make(.shl, start, line);
                }
                return self.single(.lt, start, line);
            },
            '>' => {
                if (self.peek1() == '=') return self.double(.gt_eq, start, line);
                if (self.peek1() == '>') {
                    self.bump();
                    self.bump();
                    if (self.peek() == '>') {
                        self.bump();
                        if (self.peek() == '=') return self.single(.ushr_eq, start, line);
                        return self.make(.ushr, start, line);
                    }
                    if (self.peek() == '=') return self.single(.shr_eq, start, line);
                    return self.make(.shr, start, line);
                }
                return self.single(.gt, start, line);
            },
            '+' => {
                if (self.peek1() == '+') return self.double(.plus_plus, start, line);
                if (self.peek1() == '=') return self.double(.plus_eq, start, line);
                return self.single(.plus, start, line);
            },
            '-' => {
                if (self.peek1() == '-') return self.double(.minus_minus, start, line);
                if (self.peek1() == '=') return self.double(.minus_eq, start, line);
                return self.single(.minus, start, line);
            },
            '*' => {
                if (self.peek1() == '*') {
                    self.bump();
                    self.bump();
                    if (self.peek() == '=') return self.single(.star_star_eq, start, line);
                    return self.make(.star_star, start, line);
                }
                if (self.peek1() == '=') return self.double(.star_eq, start, line);
                return self.single(.star, start, line);
            },
            '/' => {
                // Division by default; parser calls reScanAsRegex when needed.
                if (self.peek1() == '=') return self.double(.slash_eq, start, line);
                return self.single(.slash, start, line);
            },
            '%' => {
                if (self.peek1() == '=') return self.double(.percent_eq, start, line);
                return self.single(.percent, start, line);
            },
            '&' => {
                if (self.peek1() == '&') {
                    self.bump();
                    self.bump();
                    if (self.peek() == '=') return self.single(.amp_amp_eq, start, line);
                    return self.make(.amp_amp, start, line);
                }
                if (self.peek1() == '=') return self.double(.amp_eq, start, line);
                return self.single(.amp, start, line);
            },
            '|' => {
                if (self.peek1() == '|') {
                    self.bump();
                    self.bump();
                    if (self.peek() == '=') return self.single(.pipe_pipe_eq, start, line);
                    return self.make(.pipe_pipe, start, line);
                }
                if (self.peek1() == '=') return self.double(.pipe_eq, start, line);
                return self.single(.pipe, start, line);
            },
            '^' => {
                if (self.peek1() == '=') return self.double(.caret_eq, start, line);
                return self.single(.caret, start, line);
            },
            else => {
                self.bump();
                return self.fail(start, line, "unexpected character");
            },
        }
    }

    fn single(self: *Lexer, kind: Kind, start: u32, line: u32) Token {
        self.bump();
        return self.make(kind, start, line);
    }

    fn double(self: *Lexer, kind: Kind, start: u32, line: u32) Token {
        self.bump();
        self.bump();
        return self.make(kind, start, line);
    }
};

// ---- character classes -----------------------------------------------------

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c | 0x20 >= 'a' and c | 0x20 <= 'f');
}

fn hexVal(c: u8) ?u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn isOctalDigit(c: u8) bool {
    return c >= '0' and c <= '7';
}

fn isBinaryDigit(c: u8) bool {
    return c == '0' or c == '1';
}

fn isIdentStart(c: u8) bool {
    return (c | 0x20 >= 'a' and c | 0x20 <= 'z') or c == '_' or c == '$';
}

fn isIdentPart(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn collectKinds(alloc: std.mem.Allocator, source: []const u8) ![]Kind {
    var lx = Lexer.init(source);
    var kinds: std.ArrayList(Kind) = .empty;
    while (true) {
        const t = lx.next();
        try kinds.append(alloc, t.kind);
        if (t.kind == .eof or t.kind == .invalid) break;
    }
    return kinds.toOwnedSlice(alloc);
}

test "punctuators and operators" {
    const kinds = try collectKinds(testing.allocator, "a >>>= b ??= c ?. d ... => ** === !==");
    defer testing.allocator.free(kinds);
    const expect = [_]Kind{
        .identifier,   .ushr_eq,    .identifier, .question_question_eq, .identifier,
        .question_dot, .identifier, .ellipsis,   .arrow,                .star_star,
        .eq_eq_eq,     .not_eq_eq,  .eof,
    };
    try testing.expectEqualSlices(Kind, &expect, kinds);
}

test "keywords vs identifiers" {
    const kinds = try collectKinds(testing.allocator, "function foo() { return this; } async await");
    defer testing.allocator.free(kinds);
    // 0:function 1:foo 2:( 3:) 4:{ 5:return 6:this 7:; 8:}
    try testing.expectEqual(Kind.kw_function, kinds[0]);
    try testing.expectEqual(Kind.identifier, kinds[1]); // foo
    try testing.expectEqual(Kind.kw_return, kinds[5]);
    try testing.expectEqual(Kind.kw_this, kinds[6]);
    // async / await are contextual -> identifiers
    try testing.expectEqual(Kind.identifier, kinds[kinds.len - 3]);
    try testing.expectEqual(Kind.identifier, kinds[kinds.len - 2]);
}

test "numbers" {
    const kinds = try collectKinds(testing.allocator, "0 0x1F 0o17 0b101 3.14 1e10 1_000 42n .5 1.5e-3");
    defer testing.allocator.free(kinds);
    for (kinds[0 .. kinds.len - 1]) |k| {
        try testing.expect(k == .number or k == .bigint);
    }
    try testing.expectEqual(Kind.eof, kinds[kinds.len - 1]);
}

test "bigint suffix" {
    var lx = Lexer.init("123n");
    const t = lx.next();
    try testing.expectEqual(Kind.bigint, t.kind);
    try testing.expectEqual(@as(u32, 4), t.end);
}

test "string with escapes" {
    var lx = Lexer.init("\"a\\n\\x41\\u0042\\u{1F600}b\"");
    const t = lx.next();
    try testing.expectEqual(Kind.string, t.kind);
    try testing.expectEqual(Kind.eof, lx.next().kind);
}

test "unterminated string is invalid" {
    var lx = Lexer.init("'abc");
    const t = lx.next();
    try testing.expectEqual(Kind.invalid, t.kind);
    try testing.expect(lx.err_message != null);
}

test "newline_before tracks ASI signal" {
    var lx = Lexer.init("a\nb c");
    const a = lx.next();
    try testing.expect(!a.newline_before);
    const b = lx.next();
    try testing.expect(b.newline_before);
    const c = lx.next();
    try testing.expect(!c.newline_before);
}

test "template no-substitution and head" {
    {
        var lx = Lexer.init("`hello world`");
        try testing.expectEqual(Kind.template_no_sub, lx.next().kind);
    }
    {
        var lx = Lexer.init("`a${");
        try testing.expectEqual(Kind.template_head, lx.next().kind);
    }
}

test "regex rescan" {
    var lx = Lexer.init("/ab[/]c/gi");
    const slash = lx.next();
    try testing.expectEqual(Kind.slash, slash.kind);
    const re = lx.reScanAsRegex(slash.start);
    try testing.expectEqual(Kind.regex, re.kind);
    try testing.expectEqual(@as(u32, 10), re.end); // whole /.../gi
}

test "private identifier" {
    var lx = Lexer.init("#count");
    try testing.expectEqual(Kind.private_identifier, lx.next().kind);
}

test "escaped identifier lexes as an identifier and is flagged" {
    // Lexically, an escaped keyword is an Identifier tagged `escaped`; whether
    // it's an illegal ReservedWord is the parser's context-aware decision.
    var lx = Lexer.init("\\u0069f"); // "if" spelled with an escape
    const t = lx.next();
    try testing.expectEqual(Kind.identifier, t.kind);
    try testing.expect(t.escaped);
}

test "decodeIdentifier resolves escapes to the canonical name" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("if", Lexer.decodeIdentifier("\\u0069f", &buf).?);
    try testing.expectEqualStrings("await", Lexer.decodeIdentifier("\\u{61}wait", &buf).?);
    try testing.expectEqualStrings("foo", Lexer.decodeIdentifier("foo", &buf).?);
}
