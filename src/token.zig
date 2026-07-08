//! Token kinds and the reserved-word table for the lexer.
//!
//! Only *always-reserved* words get keyword kinds here. Contextual keywords
//! (`let`, `async`, `await`, `yield`, `of`, `from`, `as`, `get`, `set`,
//! `static`, `target`, `meta`) are lexed as `.identifier`; the parser decides
//! whether they act as keywords based on grammar position (see phase-1 plan).

const std = @import("std");

pub const Kind = enum {
    eof,
    invalid,

    identifier,
    private_identifier, // #name

    // Literals
    number,
    bigint,
    string,
    // Template pieces
    template_no_sub, // `...`
    template_head, // `...${
    template_middle, // }...${
    template_tail, // }...`
    regex,

    // Reserved-word literals
    kw_true,
    kw_false,
    kw_null,

    // Always-reserved keywords
    kw_break,
    kw_case,
    kw_catch,
    kw_class,
    kw_const,
    kw_continue,
    kw_debugger,
    kw_default,
    kw_delete,
    kw_do,
    kw_else,
    kw_enum,
    kw_export,
    kw_extends,
    kw_finally,
    kw_for,
    kw_function,
    kw_if,
    kw_import,
    kw_in,
    kw_instanceof,
    kw_new,
    kw_return,
    kw_super,
    kw_switch,
    kw_this,
    kw_throw,
    kw_try,
    kw_typeof,
    kw_var,
    kw_void,
    kw_while,
    kw_with,

    // Punctuators & operators
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    l_bracket,
    r_bracket,
    semicolon,
    comma,
    dot,
    ellipsis, // ...
    arrow, // =>
    colon,
    question, // ?
    question_dot, // ?.
    question_question, // ??
    question_question_eq, // ??=

    assign, // =
    eq_eq, // ==
    eq_eq_eq, // ===
    bang, // !
    not_eq, // !=
    not_eq_eq, // !==

    lt, // <
    gt, // >
    lt_eq, // <=
    gt_eq, // >=

    plus,
    minus,
    star,
    slash,
    percent,
    star_star, // **
    plus_plus, // ++
    minus_minus, // --

    plus_eq,
    minus_eq,
    star_eq,
    slash_eq,
    percent_eq,
    star_star_eq,

    shl, // <<
    shr, // >>
    ushr, // >>>
    shl_eq,
    shr_eq,
    ushr_eq,

    amp, // &
    pipe, // |
    caret, // ^
    tilde, // ~
    amp_amp, // &&
    pipe_pipe, // ||
    amp_eq,
    pipe_eq,
    caret_eq,
    amp_amp_eq, // &&=
    pipe_pipe_eq, // ||=

    /// True for any reserved-word kind (kw_*), including the literal keywords.
    pub fn isKeyword(self: Kind) bool {
        return switch (self) {
            .kw_true, .kw_false, .kw_null => true,
            else => @intFromEnum(self) >= @intFromEnum(Kind.kw_break) and
                @intFromEnum(self) <= @intFromEnum(Kind.kw_with),
        };
    }
};

pub const Token = struct {
    kind: Kind,
    /// Byte offsets into the source: [start, end).
    start: u32,
    end: u32,
    /// 1-based line of `start`.
    line: u32,
    /// A line terminator appeared between the previous token and this one.
    /// Drives Automatic Semicolon Insertion.
    newline_before: bool,
    /// An identifier that contained a `\u` escape. A ReservedWord written with
    /// an escape is illegal, and a contextual keyword (await/yield/…) spelled
    /// with one must still be recognised by its decoded name.
    escaped: bool = false,

    pub fn lexeme(self: Token, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

/// Always-reserved words plus the literal keywords true/false/null.
pub const keywords = std.StaticStringMap(Kind).initComptime(.{
    .{ "true", .kw_true },
    .{ "false", .kw_false },
    .{ "null", .kw_null },
    .{ "break", .kw_break },
    .{ "case", .kw_case },
    .{ "catch", .kw_catch },
    .{ "class", .kw_class },
    .{ "const", .kw_const },
    .{ "continue", .kw_continue },
    .{ "debugger", .kw_debugger },
    .{ "default", .kw_default },
    .{ "delete", .kw_delete },
    .{ "do", .kw_do },
    .{ "else", .kw_else },
    .{ "enum", .kw_enum },
    .{ "export", .kw_export },
    .{ "extends", .kw_extends },
    .{ "finally", .kw_finally },
    .{ "for", .kw_for },
    .{ "function", .kw_function },
    .{ "if", .kw_if },
    .{ "import", .kw_import },
    .{ "in", .kw_in },
    .{ "instanceof", .kw_instanceof },
    .{ "new", .kw_new },
    .{ "return", .kw_return },
    .{ "super", .kw_super },
    .{ "switch", .kw_switch },
    .{ "this", .kw_this },
    .{ "throw", .kw_throw },
    .{ "try", .kw_try },
    .{ "typeof", .kw_typeof },
    .{ "var", .kw_var },
    .{ "void", .kw_void },
    .{ "while", .kw_while },
    .{ "with", .kw_with },
});

/// Look up an identifier lexeme; returns its keyword kind or `.identifier`.
pub fn keywordKind(text: []const u8) Kind {
    return keywords.get(text) orelse .identifier;
}

test "keyword lookup" {
    try std.testing.expectEqual(Kind.kw_function, keywordKind("function"));
    try std.testing.expectEqual(Kind.kw_null, keywordKind("null"));
    try std.testing.expectEqual(Kind.identifier, keywordKind("foo"));
    try std.testing.expectEqual(Kind.identifier, keywordKind("async")); // contextual
    try std.testing.expect(Kind.kw_function.isKeyword());
    try std.testing.expect(Kind.kw_true.isKeyword());
    try std.testing.expect(!Kind.identifier.isKeyword());
    try std.testing.expect(!Kind.plus.isKeyword());
}
