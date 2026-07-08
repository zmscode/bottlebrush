//! bilby — a small, fast JavaScript-flavoured regular-expression engine.
//!
//! Pipeline: `pattern` (UTF-16 code units) → AST (`Parser`) → flat bytecode
//! (`Compiler`) → backtracking VM (`exec`). Backtracking (rather than a
//! Thompson NFA) is required for JavaScript semantics — backreferences and
//! lookahead can't be expressed as a pure NFA.
//!
//! The engine matches over `[]const u16` (JavaScript strings are UTF-16), which
//! is exactly bottlebrush's string representation, so no copying is needed at
//! the boundary. A per-match *step budget* bounds catastrophic backtracking so
//! a pathological pattern can't hang the host.

const std = @import("std");

pub const Error = error{
    /// Malformed pattern (unbalanced group, bad escape, trailing `\`, …).
    InvalidPattern,
    /// The pattern would compile to too large a program (e.g. `a{1000000}`).
    PatternTooComplex,
    OutOfMemory,
};

/// Runtime flags. `global`/`sticky` only influence how a caller drives repeated
/// `exec` calls (via `last_index`); the matcher honours `ignore_case`,
/// `multiline`, and `dot_all` directly.
pub const Flags = struct {
    global: bool = false,
    ignore_case: bool = false,
    multiline: bool = false,
    dot_all: bool = false,
    sticky: bool = false,
    unicode: bool = false,
    has_indices: bool = false,

    pub fn parse(s: []const u8) error{InvalidPattern}!Flags {
        var f: Flags = .{};
        for (s) |c| switch (c) {
            'g' => f.global = true,
            'i' => f.ignore_case = true,
            'm' => f.multiline = true,
            's' => f.dot_all = true,
            'y' => f.sticky = true,
            'u' => f.unicode = true,
            // v (unicodeSets) gets u's code-point semantics; the extra class
            // set notation is not implemented (those patterns error).
            'v' => f.unicode = true,
            'd' => f.has_indices = true,
            else => return error.InvalidPattern,
        };
        return f;
    }
};

// ---- character classes -----------------------------------------------------

/// One member of a character class: a code-unit range or a shorthand set.
const ClassItem = union(enum) {
    range: struct { lo: u16, hi: u16 },
    digit,
    not_digit,
    word,
    not_word,
    space,
    not_space,
};

const Class = struct {
    negated: bool,
    items: []const ClassItem,

    fn matches(self: Class, c: u16, ignore_case: bool) bool {
        if (itemsHit(self.items, c)) return !self.negated;
        if (ignore_case) {
            const swapped = swapCase(c);
            if (swapped != c and itemsHit(self.items, swapped)) return !self.negated;
        }
        return self.negated;
    }
};

fn itemsHit(items: []const ClassItem, c: u16) bool {
    for (items) |it| {
        const hit = switch (it) {
            .range => |r| c >= r.lo and c <= r.hi,
            .digit => isDigit(c),
            .not_digit => !isDigit(c),
            .word => isWord(c),
            .not_word => !isWord(c),
            .space => isSpace(c),
            .not_space => !isSpace(c),
        };
        if (hit) return true;
    }
    return false;
}

fn isDigit(c: u16) bool {
    return c >= '0' and c <= '9';
}

fn isWord(c: u16) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or isDigit(c) or c == '_';
}

fn isSpace(c: u16) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c, 0xa0, 0xfeff, 0x2028, 0x2029 => true,
        else => false,
    };
}

fn isLineTerminator(c: u16) bool {
    return c == '\n' or c == '\r' or c == 0x2028 or c == 0x2029;
}

fn toLower(c: u16) u16 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn swapCase(c: u16) u16 {
    if (c >= 'a' and c <= 'z') return c - 32;
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

// ---- AST -------------------------------------------------------------------

const Anchor = enum { bol, eol, word_boundary, not_word_boundary };

const Node = union(enum) {
    empty,
    char: u16,
    any,
    class: Class,
    anchor: Anchor,
    backref: u32,
    concat: []const *Node,
    alt: []const *Node,
    /// `child{min,max}` with greediness. `max == null` means unbounded.
    repeat: struct { child: *Node, min: u32, max: ?u32, greedy: bool },
    /// A group; `capture` is its 1-based index, or null for `(?:…)`.
    group: struct { child: *Node, capture: ?u32 },
    /// A lookaround assertion: `positive` = `(?=)`/`(?<=)`; `behind` = lookbehind.
    look: struct { child: *Node, positive: bool, behind: bool },
};

// ---- parser ----------------------------------------------------------------

const Parser = struct {
    src: []const u16,
    pos: usize = 0,
    arena: std.mem.Allocator,
    group_count: u32 = 0,
    /// Named capture groups: name (UTF-8) -> 1-based index.
    names: *std.StringHashMapUnmanaged(u32),
    gpa: std.mem.Allocator,
    /// u/v mode: code-point atoms, `\u{…}` escapes, strict escape errors.
    unicode: bool = false,

    fn peek(self: *Parser) ?u16 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }
    fn next(self: *Parser) ?u16 {
        if (self.pos >= self.src.len) return null;
        defer self.pos += 1;
        return self.src[self.pos];
    }
    fn eat(self: *Parser, c: u16) bool {
        if (self.peek() == c) {
            self.pos += 1;
            return true;
        }
        return false;
    }
    fn node(self: *Parser, n: Node) Error!*Node {
        const p = try self.arena.create(Node);
        p.* = n;
        return p;
    }

    fn parseAlternation(self: *Parser) Error!*Node {
        var branches: std.ArrayList(*Node) = .empty;
        try branches.append(self.arena, try self.parseConcat());
        while (self.eat('|')) try branches.append(self.arena, try self.parseConcat());
        if (branches.items.len == 1) return branches.items[0];
        return self.node(.{ .alt = try branches.toOwnedSlice(self.arena) });
    }

    fn parseConcat(self: *Parser) Error!*Node {
        var parts: std.ArrayList(*Node) = .empty;
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            try parts.append(self.arena, try self.parseQuantified());
        }
        if (parts.items.len == 0) return self.node(.empty);
        if (parts.items.len == 1) return parts.items[0];
        return self.node(.{ .concat = try parts.toOwnedSlice(self.arena) });
    }

    fn parseQuantified(self: *Parser) Error!*Node {
        const atom = try self.parseAtom();
        const c = self.peek() orelse return atom;
        var min: u32 = 0;
        var max: ?u32 = null;
        switch (c) {
            '*' => {
                self.pos += 1;
                min = 0;
                max = null;
            },
            '+' => {
                self.pos += 1;
                min = 1;
                max = null;
            },
            '?' => {
                self.pos += 1;
                min = 0;
                max = 1;
            },
            '{' => {
                const saved = self.pos;
                if (try self.parseBraceQuantifier(&min, &max)) {
                    // parsed
                } else {
                    self.pos = saved; // `{` is a literal here
                    return atom;
                }
            },
            else => return atom,
        }
        const greedy = !self.eat('?');
        return self.node(.{ .repeat = .{ .child = atom, .min = min, .max = max, .greedy = greedy } });
    }

    /// Parse `{n}`, `{n,}`, or `{n,m}`. Returns false (leaving `{` as a literal)
    /// when the braces don't form a valid quantifier.
    fn parseBraceQuantifier(self: *Parser, min: *u32, max: *?u32) Error!bool {
        std.debug.assert(self.src[self.pos] == '{');
        self.pos += 1;
        const lo = self.parseInt() orelse return false;
        min.* = lo;
        max.* = lo;
        if (self.eat(',')) {
            if (self.peek() == '}') {
                max.* = null; // {n,}
            } else {
                max.* = self.parseInt() orelse return false;
            }
        }
        if (!self.eat('}')) return false;
        if (max.*) |m| if (m < min.*) return error.InvalidPattern;
        return true;
    }

    fn parseInt(self: *Parser) ?u32 {
        const start = self.pos;
        var v: u64 = 0;
        while (self.peek()) |c| {
            if (c < '0' or c > '9') break;
            v = v * 10 + (c - '0');
            if (v > std.math.maxInt(u32)) v = std.math.maxInt(u32);
            self.pos += 1;
        }
        if (self.pos == start) return null;
        return @intCast(v);
    }

    fn parseAtom(self: *Parser) Error!*Node {
        const c = self.peek() orelse return error.InvalidPattern;
        switch (c) {
            '(' => return self.parseGroup(),
            '[' => return self.parseClass(),
            '.' => {
                self.pos += 1;
                return self.node(.any);
            },
            '^' => {
                self.pos += 1;
                return self.node(.{ .anchor = .bol });
            },
            '$' => {
                self.pos += 1;
                return self.node(.{ .anchor = .eol });
            },
            '\\' => return self.parseEscape(),
            '*', '+', '?' => return error.InvalidPattern, // nothing to quantify
            else => {
                self.pos += 1;
                // u-mode: a literal surrogate pair is one code-point atom
                // (so quantifiers apply to the whole pair).
                if (self.unicode and isHighSurrogate(c)) {
                    if (self.peek()) |lo| {
                        if (isLowSurrogate(lo)) {
                            self.pos += 1;
                            return self.pairNode(c, lo);
                        }
                    }
                }
                return self.node(.{ .char = c });
            },
        }
    }

    /// A surrogate-pair atom: matches exactly the two units, quantified as one.
    fn pairNode(self: *Parser, hi: u16, lo: u16) Error!*Node {
        const parts = try self.arena.alloc(*Node, 2);
        parts[0] = try self.node(.{ .char = hi });
        parts[1] = try self.node(.{ .char = lo });
        return self.node(.{ .concat = parts });
    }

    /// An atom matching `cp` (a surrogate pair when astral).
    fn codePointNode(self: *Parser, cp: u21) Error!*Node {
        if (cp <= 0xffff) return self.node(.{ .char = @intCast(cp) });
        const c = @as(u32, cp) - 0x10000;
        return self.pairNode(@intCast(0xd800 + (c >> 10)), @intCast(0xdc00 + (c & 0x3ff)));
    }

    fn parseGroup(self: *Parser) Error!*Node {
        std.debug.assert(self.src[self.pos] == '(');
        self.pos += 1;
        var capture: ?u32 = null;
        var look_positive: ?bool = null;
        var look_behind = false;
        if (self.eat('?')) {
            const k = self.next() orelse return error.InvalidPattern;
            switch (k) {
                ':' => {}, // non-capturing
                '=' => look_positive = true, // (?=…) positive lookahead
                '!' => look_positive = false, // (?!…) negative lookahead
                '<' => {
                    if (self.eat('=')) {
                        look_positive = true; // (?<=…) positive lookbehind
                        look_behind = true;
                    } else if (self.eat('!')) {
                        look_positive = false; // (?<!…) negative lookbehind
                        look_behind = true;
                    } else {
                        const name = try self.parseGroupName(); // (?<name>…)
                        self.group_count += 1;
                        capture = self.group_count;
                        try self.names.put(self.gpa, name, capture.?);
                    }
                },
                else => return error.InvalidPattern,
            }
        } else {
            self.group_count += 1;
            capture = self.group_count;
        }
        const child = try self.parseAlternation();
        if (!self.eat(')')) return error.InvalidPattern;
        if (look_positive) |pos| return self.node(.{ .look = .{ .child = child, .positive = pos, .behind = look_behind } });
        return self.node(.{ .group = .{ .child = child, .capture = capture } });
    }

    fn parseGroupName(self: *Parser) Error![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        while (self.peek()) |c| {
            if (c == '>') break;
            // Names are identifier-ish; store as UTF-8 (ASCII-only here).
            try buf.append(self.gpa, @intCast(c & 0xff));
            self.pos += 1;
        }
        if (!self.eat('>')) return error.InvalidPattern;
        if (buf.items.len == 0) return error.InvalidPattern;
        return buf.toOwnedSlice(self.gpa);
    }

    fn parseEscape(self: *Parser) Error!*Node {
        std.debug.assert(self.src[self.pos] == '\\');
        self.pos += 1;
        const c = self.next() orelse return error.InvalidPattern;
        switch (c) {
            'd' => return self.classNode(false, &.{.digit}),
            'D' => return self.classNode(false, &.{.not_digit}),
            'w' => return self.classNode(false, &.{.word}),
            'W' => return self.classNode(false, &.{.not_word}),
            's' => return self.classNode(false, &.{.space}),
            'S' => return self.classNode(false, &.{.not_space}),
            'b' => return self.node(.{ .anchor = .word_boundary }),
            'B' => return self.node(.{ .anchor = .not_word_boundary }),
            'k' => {
                // Named backreference `\k<name>` — resolved after parsing.
                if (!self.eat('<')) return error.InvalidPattern;
                const name = try self.parseGroupName();
                defer self.gpa.free(name);
                const idx = self.names.get(name) orelse return error.InvalidPattern;
                return self.node(.{ .backref = idx });
            },
            '0' => return self.node(.{ .char = 0 }),
            '1'...'9' => {
                self.pos -= 1; // reconsume digit
                const idx = self.parseInt().?;
                return self.node(.{ .backref = idx });
            },
            'u' => {
                // u-mode `\u{…}`: an arbitrary code point.
                if (self.unicode and self.peek() == '{') {
                    return self.codePointNode(try self.parseHexBraces());
                }
                const unit = try self.parseHex(4);
                // u-mode: `\uD8xx\uDCxx` escape pairs form one atom.
                if (self.unicode and isHighSurrogate(unit) and
                    self.pos + 1 < self.src.len and self.src[self.pos] == '\\' and self.src[self.pos + 1] == 'u')
                {
                    const saved = self.pos;
                    self.pos += 2;
                    if (self.parseHex(4)) |lo| {
                        if (isLowSurrogate(lo)) return self.pairNode(unit, lo);
                    } else |_| {}
                    self.pos = saved; // not a trail escape: leave it for later
                }
                return self.node(.{ .char = unit });
            },
            else => {
                if (self.unicode) return self.node(.{ .char = try self.decodeEscapeCharStrict(c) });
                return self.node(.{ .char = try self.decodeEscapeChar(c) });
            },
        }
    }

    /// u-mode escapes are strict: only recognized escapes and syntax-character
    /// identity escapes are legal (spec: anything else is a SyntaxError).
    fn decodeEscapeCharStrict(self: *Parser, c: u16) Error!u16 {
        return switch (c) {
            'n', 'r', 't', 'f', 'v', '0', 'x', 'u' => self.decodeEscapeChar(c),
            '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/', '-' => c,
            else => error.InvalidPattern,
        };
    }

    /// `{XXXXXX}` after `\u` (u-mode): 1-6 hex digits, at most 0x10FFFF.
    fn parseHexBraces(self: *Parser) Error!u21 {
        if (!self.eat('{')) return error.InvalidPattern;
        var v: u32 = 0;
        var n: usize = 0;
        while (self.peek()) |c| {
            if (c == '}') {
                self.pos += 1;
                if (n == 0 or v > 0x10FFFF) return error.InvalidPattern;
                return @intCast(v);
            }
            const d = hexDigit(c) orelse return error.InvalidPattern;
            v = v * 16 + d;
            n += 1;
            if (n > 6) return error.InvalidPattern;
            self.pos += 1;
        }
        return error.InvalidPattern;
    }

    fn classNode(self: *Parser, negated: bool, items: []const ClassItem) Error!*Node {
        return self.node(.{ .class = .{ .negated = negated, .items = try self.arena.dupe(ClassItem, items) } });
    }

    /// Decode a single-character escape (`\n`, `\xHH`, `\uHHHH`, `\.`, …) to its
    /// literal code unit.
    fn decodeEscapeChar(self: *Parser, c: u16) Error!u16 {
        return switch (c) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'f' => 0x0c,
            'v' => 0x0b,
            '0' => 0,
            'x' => try self.parseHex(2),
            'u' => try self.parseHex(4),
            else => c, // escaped metacharacter or identity escape
        };
    }

    fn parseHex(self: *Parser, digits: usize) Error!u16 {
        var v: u32 = 0;
        var i: usize = 0;
        while (i < digits) : (i += 1) {
            const c = self.next() orelse return error.InvalidPattern;
            const d = hexDigit(c) orelse return error.InvalidPattern;
            v = v * 16 + d;
        }
        return @intCast(v);
    }

    fn parseClass(self: *Parser) Error!*Node {
        std.debug.assert(self.src[self.pos] == '[');
        self.pos += 1;
        const negated = self.eat('^');
        var items: std.ArrayList(ClassItem) = .empty;
        while (self.peek()) |c| {
            if (c == ']') {
                self.pos += 1;
                return self.node(.{ .class = .{ .negated = negated, .items = try items.toOwnedSlice(self.arena) } });
            }
            const lo = try self.parseClassAtom(&items) orelse continue; // shorthand pushed itself
            // Possible range `a-z` (but not `a-]` or `a-\d`).
            if (self.peek() == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] != ']') {
                self.pos += 1; // consume '-'
                const hi = try self.parseClassAtom(&items) orelse {
                    // `-` followed by a shorthand: treat both literally-ish.
                    try items.append(self.arena, .{ .range = .{ .lo = lo, .hi = lo } });
                    try items.append(self.arena, .{ .range = .{ .lo = '-', .hi = '-' } });
                    continue;
                };
                if (hi < lo) return error.InvalidPattern;
                try items.append(self.arena, .{ .range = .{ .lo = lo, .hi = hi } });
            } else {
                try items.append(self.arena, .{ .range = .{ .lo = lo, .hi = lo } });
            }
        }
        return error.InvalidPattern; // unterminated class
    }

    /// Parse one class element. Returns a literal code unit, or null when it
    /// pushed a shorthand item (`\d`, `\w`, …) directly onto `items`.
    fn parseClassAtom(self: *Parser, items: *std.ArrayList(ClassItem)) Error!?u16 {
        const c = self.next() orelse return error.InvalidPattern;
        if (c != '\\') return c;
        const e = self.next() orelse return error.InvalidPattern;
        switch (e) {
            'd' => try items.append(self.arena, .digit),
            'D' => try items.append(self.arena, .not_digit),
            'w' => try items.append(self.arena, .word),
            'W' => try items.append(self.arena, .not_word),
            's' => try items.append(self.arena, .space),
            'S' => try items.append(self.arena, .not_space),
            'b' => return 0x08, // `\b` is backspace inside a class
            else => return try self.decodeEscapeChar(e),
        }
        return null;
    }
};

fn isHighSurrogate(u: u16) bool {
    return u >= 0xd800 and u <= 0xdbff;
}

fn isLowSurrogate(u: u16) bool {
    return u >= 0xdc00 and u <= 0xdfff;
}

fn hexDigit(c: u16) ?u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// ---- bytecode --------------------------------------------------------------

const Op = enum(u8) {
    char, // a = code unit
    char_ci, // a = lowercased code unit (compare case-insensitively)
    any, // any unit (line-terminator rules depend on dot_all)
    class, // a = index into `classes`
    match, // accept
    jmp, // a = target
    split, // try a, then b on backtrack
    save, // a = capture slot
    bol,
    eol,
    wordb,
    nwordb,
    backref, // a = 1-based group index
    look, // a = sub start, b = continuation (positive lookahead)
    look_neg, // negative lookahead
    lookbehind, // a = sub start, b = continuation (positive lookbehind)
    lookbehind_neg, // negative lookbehind
    clear_caps, // a = first group, b = last group (inclusive): reset to unset
};

const Inst = struct { op: Op, a: u32 = 0, b: u32 = 0 };

// ---- compiler --------------------------------------------------------------

const max_program_len = 1 << 20; // guard against `a{1000000}` blowups

const Compiler = struct {
    code: std.ArrayList(Inst) = .empty,
    classes: std.ArrayList(Class) = .empty,
    gpa: std.mem.Allocator,

    fn emit(self: *Compiler, inst: Inst) Error!u32 {
        if (self.code.items.len >= max_program_len) return error.PatternTooComplex;
        const pc: u32 = @intCast(self.code.items.len);
        try self.code.append(self.gpa, inst);
        return pc;
    }
    fn here(self: *Compiler) u32 {
        return @intCast(self.code.items.len);
    }

    fn compile(self: *Compiler, root: *const Node) Error!void {
        _ = try self.emit(.{ .op = .save, .a = 0 }); // group 0 start
        try self.compileNode(root);
        _ = try self.emit(.{ .op = .save, .a = 1 }); // group 0 end
        _ = try self.emit(.{ .op = .match });
    }

    fn compileNode(self: *Compiler, n: *const Node) Error!void {
        switch (n.*) {
            .empty => {},
            .char => |c| _ = try self.emit(.{ .op = .char, .a = c }),
            .any => _ = try self.emit(.{ .op = .any }),
            .class => |cls| {
                const idx: u32 = @intCast(self.classes.items.len);
                try self.classes.append(self.gpa, cls);
                _ = try self.emit(.{ .op = .class, .a = idx });
            },
            .anchor => |anc| _ = try self.emit(.{ .op = switch (anc) {
                .bol => .bol,
                .eol => .eol,
                .word_boundary => .wordb,
                .not_word_boundary => .nwordb,
            } }),
            .backref => |idx| _ = try self.emit(.{ .op = .backref, .a = idx }),
            .concat => |parts| for (parts) |p| try self.compileNode(p),
            .alt => |branches| try self.compileAlt(branches),
            .group => |g| {
                if (g.capture) |idx| {
                    _ = try self.emit(.{ .op = .save, .a = 2 * idx });
                    try self.compileNode(g.child);
                    _ = try self.emit(.{ .op = .save, .a = 2 * idx + 1 });
                } else try self.compileNode(g.child);
            },
            .look => |l| try self.compileLook(l.child, l.positive, l.behind),
            .repeat => |r| try self.compileRepeat(r.child, r.min, r.max, r.greedy),
        }
    }

    fn compileAlt(self: *Compiler, branches: []const *Node) Error!void {
        // split L0, L1 ; L0: <b0> jmp End ; L1: split .. ; … ; last: <bn> ; End:
        var jmp_ends: std.ArrayList(u32) = .empty;
        defer jmp_ends.deinit(self.gpa);
        for (branches, 0..) |b, i| {
            const last = i == branches.len - 1;
            var split_pc: u32 = 0;
            if (!last) split_pc = try self.emit(.{ .op = .split });
            try self.compileNode(b);
            if (!last) {
                try jmp_ends.append(self.gpa, try self.emit(.{ .op = .jmp }));
                self.code.items[split_pc].a = split_pc + 1; // preferred: this branch
                self.code.items[split_pc].b = self.here(); // else: next branch
            }
        }
        const end = self.here();
        for (jmp_ends.items) |j| self.code.items[j].a = end;
    }

    fn compileLook(self: *Compiler, child: *const Node, positive: bool, behind: bool) Error!void {
        const op: Op = if (behind)
            (if (positive) .lookbehind else .lookbehind_neg)
        else
            (if (positive) .look else .look_neg);
        const look_pc = try self.emit(.{ .op = op });
        self.code.items[look_pc].a = self.here(); // sub starts next
        try self.compileNode(child);
        _ = try self.emit(.{ .op = .match }); // sub terminator
        self.code.items[look_pc].b = self.here(); // continuation
    }

    fn compileRepeat(self: *Compiler, child: *const Node, min: u32, max: ?u32, greedy: bool) Error!void {
        // Spec (RepeatMatcher): the captures of groups *inside* the repeated
        // subpattern reset at the start of every iteration.
        const caps = groupSpan(child);
        // Mandatory copies.
        var i: u32 = 0;
        while (i < min) : (i += 1) {
            try self.emitClearCaps(caps);
            try self.compileNode(child);
        }

        if (max) |m| {
            // Optional copies: (child?) repeated (m-min) times.
            var opt_splits: std.ArrayList(u32) = .empty;
            defer opt_splits.deinit(self.gpa);
            var k: u32 = min;
            while (k < m) : (k += 1) {
                const sp = try self.emit(.{ .op = .split });
                try opt_splits.append(self.gpa, sp);
                try self.emitClearCaps(caps);
                try self.compileNode(child);
            }
            const end = self.here();
            for (opt_splits.items) |sp| self.setSplit(sp, greedy, sp + 1, end);
        } else {
            // Unbounded tail: a greedy/lazy star.
            const loop = try self.emit(.{ .op = .split });
            try self.emitClearCaps(caps);
            try self.compileNode(child);
            _ = try self.emit(.{ .op = .jmp, .a = loop });
            self.setSplit(loop, greedy, loop + 1, self.here());
        }
    }

    fn emitClearCaps(self: *Compiler, caps: ?[2]u32) Error!void {
        if (caps) |c| _ = try self.emit(.{ .op = .clear_caps, .a = c[0], .b = c[1] });
    }

    /// A split whose `a` is tried first. Greedy prefers entering the body;
    /// lazy prefers the exit.
    fn setSplit(self: *Compiler, pc: u32, greedy: bool, body: u32, exit: u32) void {
        if (greedy) {
            self.code.items[pc].a = body;
            self.code.items[pc].b = exit;
        } else {
            self.code.items[pc].a = exit;
            self.code.items[pc].b = body;
        }
    }
};

/// The inclusive range of capture-group indices inside `n`, or null when it
/// contains none. Group numbers are assigned in source order, so a subtree's
/// groups are always contiguous.
fn groupSpan(n: *const Node) ?[2]u32 {
    var lo: u32 = std.math.maxInt(u32);
    var hi: u32 = 0;
    collectGroups(n, &lo, &hi);
    if (lo == std.math.maxInt(u32)) return null;
    return .{ lo, hi };
}

fn collectGroups(n: *const Node, lo: *u32, hi: *u32) void {
    switch (n.*) {
        .group => |g| {
            if (g.capture) |idx| {
                lo.* = @min(lo.*, idx);
                hi.* = @max(hi.*, idx);
            }
            collectGroups(g.child, lo, hi);
        },
        .concat => |parts| for (parts) |p| collectGroups(p, lo, hi),
        .alt => |branches| for (branches) |b| collectGroups(b, lo, hi),
        .repeat => |r| collectGroups(r.child, lo, hi),
        .look => |l| collectGroups(l.child, lo, hi),
        else => {},
    }
}

// ---- compiled regex + matcher ----------------------------------------------

/// A capture span within the subject; `.start`/`.end` are code-unit indices.
pub const Span = struct { start: usize, end: usize };

/// The result of a successful match: `groups[0]` is the whole match, and
/// `groups[i]` is the i-th capture (null when the group didn't participate).
pub const Match = struct {
    groups: []const ?Span,

    pub fn deinit(self: Match, gpa: std.mem.Allocator) void {
        gpa.free(self.groups);
    }
};

/// A step budget large enough for any reasonable pattern, small enough that
/// catastrophic backtracking (e.g. `(a+)+$` on a long non-match) fails fast
/// instead of hanging.
const default_step_limit: u64 = 10_000_000;

pub const Regex = struct {
    code: []const Inst,
    classes: []const Class,
    class_item_store: []const ClassItem, // backing storage for class items
    group_count: u32,
    names: std.StringHashMapUnmanaged(u32),
    flags: Flags,
    arena: std.heap.ArenaAllocator,

    /// Compile `pattern` (UTF-16 code units) with `flags`.
    pub fn compile(gpa: std.mem.Allocator, pattern: []const u16, flags: Flags) Error!Regex {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const aa = arena.allocator();

        var names: std.StringHashMapUnmanaged(u32) = .empty;
        errdefer names.deinit(gpa);

        var parser = Parser{ .src = pattern, .arena = aa, .names = &names, .gpa = gpa, .unicode = flags.unicode };
        const root = try parser.parseAlternation();
        if (parser.pos != pattern.len) return error.InvalidPattern; // stray `)` etc.

        var compiler = Compiler{ .gpa = aa };
        try compiler.compile(root);
        if (flags.ignore_case) lowerCharOps(compiler.code.items);

        return .{
            .code = try compiler.code.toOwnedSlice(aa),
            .classes = try compiler.classes.toOwnedSlice(aa),
            .class_item_store = &.{},
            .group_count = parser.group_count,
            .names = names,
            .flags = flags,
            .arena = arena,
        };
    }

    /// Convenience: compile from a UTF-8 pattern + flag string.
    pub fn compileUtf8(gpa: std.mem.Allocator, pattern: []const u8, flag_str: []const u8) Error!Regex {
        const units = utf8ToUtf16(gpa, pattern) catch return error.InvalidPattern;
        defer gpa.free(units);
        const flags = Flags.parse(flag_str) catch return error.InvalidPattern;
        return compile(gpa, units, flags);
    }

    pub fn deinit(self: *Regex, gpa: std.mem.Allocator) void {
        var it = self.names.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        self.names.deinit(gpa);
        self.arena.deinit();
    }

    /// The number of capture groups (excluding the whole-match group 0).
    pub fn captureCount(self: *const Regex) u32 {
        return self.group_count;
    }

    /// Resolve a named group to its 1-based index.
    pub fn groupIndex(self: *const Regex, name: []const u8) ?u32 {
        return self.names.get(name);
    }

    /// True if the pattern matches anywhere at or after `start`. Uses `gpa` for
    /// transient capture storage (freed before returning).
    pub fn matchesAt(self: *const Regex, gpa: std.mem.Allocator, input: []const u16, start: usize) Error!bool {
        const m = try self.find(gpa, input, start) orelse return false;
        m.deinit(gpa);
        return true;
    }

    /// Find the leftmost match at or after `start`, returning capture spans.
    /// Honours the `sticky` flag (anchored at exactly `start`). Caller frees the
    /// returned `Match`.
    pub fn find(self: *const Regex, gpa: std.mem.Allocator, input: []const u16, start: usize) Error!?Match {
        const nslots = 2 * (self.group_count + 1);
        const caps = try gpa.alloc(?usize, nslots);
        defer gpa.free(caps);

        var m = Matcher{
            .re = self,
            .input = input,
            .caps = caps,
            .bt = .empty,
            .undo = .empty,
            .gpa = gpa,
        };
        defer m.bt.deinit(gpa);
        defer m.undo.deinit(gpa);

        var at = start;
        while (at <= input.len) : (at += 1) {
            @memset(caps, null);
            m.steps = 0;
            if (try m.run(0, at, null)) {
                const groups = try gpa.alloc(?Span, self.group_count + 1);
                for (0..self.group_count + 1) |g| {
                    const s = caps[2 * g];
                    const e = caps[2 * g + 1];
                    groups[g] = if (s != null and e != null) Span{ .start = s.?, .end = e.? } else null;
                }
                return Match{ .groups = groups };
            }
            if (self.flags.sticky) break;
        }
        return null;
    }
};

/// A backtracking thread to resume on failure.
const BtEntry = struct { pc: u32, sp: usize, undo_mark: usize };
const UndoEntry = struct { slot: usize, prev: ?usize };

const Matcher = struct {
    re: *const Regex,
    input: []const u16,
    caps: []?usize,
    bt: std.ArrayList(BtEntry),
    undo: std.ArrayList(UndoEntry),
    gpa: std.mem.Allocator,
    steps: u64 = 0,

    /// Backtracking execution from `start_pc`/`start_sp`. Returns true on match,
    /// leaving successful capture positions in `caps`. Nested (lookahead) calls
    /// share `caps`/`undo` but use a fresh backtrack region.
    /// `anchor_end`, when non-null, requires `match` to occur at exactly that
    /// position — used by lookbehind, whose sub-expression must end where the
    /// assertion is anchored. Top-level and lookahead calls pass null.
    fn run(self: *Matcher, start_pc: u32, start_sp: usize, anchor_end: ?usize) Error!bool {
        const code = self.re.code;
        const bt_base = self.bt.items.len;
        var pc = start_pc;
        var sp = start_sp;
        while (true) {
            self.steps += 1;
            if (self.steps > default_step_limit) return error.PatternTooComplex;

            const inst = code[pc];
            const ok = switch (inst.op) {
                .match => blk: {
                    if (anchor_end) |ae| {
                        if (sp != ae) break :blk false; // keep backtracking for an exact end
                    }
                    self.bt.shrinkRetainingCapacity(bt_base);
                    return true;
                },
                .char => sp < self.input.len and self.input[sp] == @as(u16, @intCast(inst.a)),
                .char_ci => sp < self.input.len and toLower(self.input[sp]) == @as(u16, @intCast(inst.a)),
                .any => sp < self.input.len and (self.re.flags.dot_all or !isLineTerminator(self.input[sp])),
                .class => sp < self.input.len and self.re.classes[inst.a].matches(self.input[sp], self.re.flags.ignore_case),
                .jmp => {
                    pc = inst.a;
                    continue;
                },
                .split => {
                    try self.bt.append(self.gpa, .{ .pc = inst.b, .sp = sp, .undo_mark = self.undo.items.len });
                    pc = inst.a;
                    continue;
                },
                .save => {
                    try self.undo.append(self.gpa, .{ .slot = inst.a, .prev = self.caps[inst.a] });
                    self.caps[inst.a] = sp;
                    pc += 1;
                    continue;
                },
                .clear_caps => {
                    var g: usize = inst.a;
                    while (g <= inst.b) : (g += 1) {
                        try self.undo.append(self.gpa, .{ .slot = 2 * g, .prev = self.caps[2 * g] });
                        self.caps[2 * g] = null;
                        try self.undo.append(self.gpa, .{ .slot = 2 * g + 1, .prev = self.caps[2 * g + 1] });
                        self.caps[2 * g + 1] = null;
                    }
                    pc += 1;
                    continue;
                },
                .bol => sp == 0 or (self.re.flags.multiline and isLineTerminator(self.input[sp - 1])),
                .eol => sp == self.input.len or (self.re.flags.multiline and isLineTerminator(self.input[sp])),
                .wordb => self.atWordBoundary(sp),
                .nwordb => !self.atWordBoundary(sp),
                .backref => blk: {
                    const consumed = self.matchBackref(inst.a, sp) orelse break :blk false;
                    sp += consumed;
                    break :blk true;
                },
                .look, .look_neg => blk: {
                    const positive = inst.op == .look;
                    const mark = self.undo.items.len;
                    const matched = try self.run(inst.a, sp, null);
                    if (!positive or !matched) {
                        // Negative lookahead discards inner captures entirely;
                        // a failed positive lookahead does too.
                        while (self.undo.items.len > mark) {
                            const u = self.undo.pop().?;
                            self.caps[u.slot] = u.prev;
                        }
                    }
                    if (matched != positive) break :blk false; // assertion failed
                    pc = inst.b; // skip over the sub-program
                    continue;
                },
                .lookbehind, .lookbehind_neg => blk: {
                    const positive = inst.op == .lookbehind;
                    const mark = self.undo.items.len;
                    // The sub must match some span *ending* exactly at `sp`; try
                    // each earlier start, preferring the longest (smallest `j`).
                    var matched = false;
                    var j: usize = 0;
                    while (j <= sp) : (j += 1) {
                        if (try self.run(inst.a, j, sp)) {
                            matched = true;
                            break;
                        }
                    }
                    if (!positive or !matched) {
                        while (self.undo.items.len > mark) {
                            const u = self.undo.pop().?;
                            self.caps[u.slot] = u.prev;
                        }
                    }
                    if (matched != positive) break :blk false;
                    pc = inst.b;
                    continue;
                },
            };

            if (ok) {
                // Consuming ops (char/any/class/backref set `ok`; anchors don't advance).
                switch (inst.op) {
                    .char, .char_ci, .class => sp += 1,
                    .any => {
                        // u-mode: `.` consumes a whole code point, so a
                        // surrogate pair is a single step.
                        if (self.re.flags.unicode and isHighSurrogate(self.input[sp]) and
                            sp + 1 < self.input.len and isLowSurrogate(self.input[sp + 1]))
                        {
                            sp += 2;
                        } else {
                            sp += 1;
                        }
                    },
                    else => {},
                }
                pc += 1;
                continue;
            }

            // Backtrack.
            if (self.bt.items.len <= bt_base) return false;
            const entry = self.bt.pop().?;
            while (self.undo.items.len > entry.undo_mark) {
                const u = self.undo.pop().?;
                self.caps[u.slot] = u.prev;
            }
            pc = entry.pc;
            sp = entry.sp;
        }
    }

    fn atWordBoundary(self: *Matcher, sp: usize) bool {
        const before = sp > 0 and isWord(self.input[sp - 1]);
        const after = sp < self.input.len and isWord(self.input[sp]);
        return before != after;
    }

    /// Match the text previously captured by group `idx` at `sp`; returns the
    /// number of units consumed, or null on mismatch. An unset group matches
    /// the empty string (per spec).
    fn matchBackref(self: *Matcher, idx: u32, sp: usize) ?usize {
        const s = self.caps[2 * idx] orelse return 0;
        const e = self.caps[2 * idx + 1] orelse return 0;
        const len = e - s;
        if (sp + len > self.input.len) return null;
        const ci = self.re.flags.ignore_case;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const a = self.input[s + i];
            const b = self.input[sp + i];
            if (a == b) continue;
            if (ci and toLower(a) == toLower(b)) continue;
            return null;
        }
        return len;
    }
};

/// Rewrite `char` ops to `char_ci` (with a lowercased operand) for case-
/// insensitive matching. Class ops handle case-insensitivity at match time.
fn lowerCharOps(code: []Inst) void {
    for (code) |*inst| {
        if (inst.op == .char) {
            inst.op = .char_ci;
            inst.a = toLower(@intCast(inst.a));
        }
    }
}

// ---- UTF conversion helpers ------------------------------------------------

pub fn utf8ToUtf16(gpa: std.mem.Allocator, s: []const u8) ![]u16 {
    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(gpa);
    const view = try std.unicode.Utf8View.init(s);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp <= 0xffff) {
            try out.append(gpa, @intCast(cp));
        } else {
            const c = cp - 0x10000;
            try out.append(gpa, @intCast(0xd800 + (c >> 10)));
            try out.append(gpa, @intCast(0xdc00 + (c & 0x3ff)));
        }
    }
    return out.toOwnedSlice(gpa);
}

pub fn utf16ToUtf8(gpa: std.mem.Allocator, units: []const u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    var buf: [4]u8 = undefined;
    while (i < units.len) : (i += 1) {
        var cp: u21 = units[i];
        if (cp >= 0xd800 and cp <= 0xdbff and i + 1 < units.len and units[i + 1] >= 0xdc00 and units[i + 1] <= 0xdfff) {
            cp = 0x10000 + ((@as(u21, units[i] - 0xd800)) << 10) + (units[i + 1] - 0xdc00);
            i += 1; // consume the low surrogate (the loop step consumes the high one)
        }
        const n = std.unicode.utf8Encode(cp, &buf) catch continue;
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

/// Compile `pattern`/`flags`, then return whether it matches (anywhere) in
/// `subject`. All UTF-8 for test ergonomics.
fn matches(pattern: []const u8, flags: []const u8, subject: []const u8) !bool {
    var re = try Regex.compileUtf8(testing.allocator, pattern, flags);
    defer re.deinit(testing.allocator);
    const units = try utf8ToUtf16(testing.allocator, subject);
    defer testing.allocator.free(units);
    const m = try re.find(testing.allocator, units, 0);
    if (m) |mm| {
        mm.deinit(testing.allocator);
        return true;
    }
    return false;
}

/// Return the whole match [start,end) code-unit span, or null.
fn firstMatch(pattern: []const u8, flags: []const u8, subject: []const u8) !?Span {
    var re = try Regex.compileUtf8(testing.allocator, pattern, flags);
    defer re.deinit(testing.allocator);
    const units = try utf8ToUtf16(testing.allocator, subject);
    defer testing.allocator.free(units);
    const m = (try re.find(testing.allocator, units, 0)) orelse return null;
    defer m.deinit(testing.allocator);
    return m.groups[0];
}

test "literals and dot" {
    try testing.expect(try matches("abc", "", "xxabcxx"));
    try testing.expect(!try matches("abc", "", "ab"));
    try testing.expect(try matches("a.c", "", "axc"));
    try testing.expect(!try matches("a.c", "", "a\nc")); // `.` excludes newline
    try testing.expect(try matches("a.c", "s", "a\nc")); // dotAll
}

test "quantifiers greedy and lazy" {
    try testing.expectEqual(@as(?Span, .{ .start = 0, .end = 4 }), try firstMatch("a+", "", "aaaa"));
    try testing.expectEqual(@as(?Span, .{ .start = 0, .end = 1 }), try firstMatch("a+?", "", "aaaa"));
    try testing.expect(try matches("ab*c", "", "ac"));
    try testing.expect(try matches("ab*c", "", "abbbc"));
    try testing.expect(try matches("colou?r", "", "color"));
    try testing.expect(try matches("colou?r", "", "colour"));
    try testing.expect(try matches("a{2,3}", "", "aa"));
    try testing.expect(!try matches("^a{2,3}$", "", "aaaa"));
}

test "classes and shorthands" {
    try testing.expect(try matches("[abc]+", "", "cabbage"));
    try testing.expect(try matches("[^0-9]", "", "a1"));
    try testing.expect(try matches("\\d{3}", "", "call 911"));
    try testing.expect(!try matches("^\\w+$", "", "has space"));
    try testing.expect(try matches("[\\d.]+", "", "3.14"));
}

test "anchors and word boundaries" {
    try testing.expect(try matches("^abc$", "", "abc"));
    try testing.expect(!try matches("^abc$", "", "xabc"));
    try testing.expect(try matches("^b", "m", "a\nb")); // multiline
    try testing.expect(try matches("\\bword\\b", "", "a word here"));
    try testing.expect(!try matches("\\bword\\b", "", "swordfish"));
}

test "alternation and groups" {
    try testing.expect(try matches("cat|dog", "", "hotdog"));
    try testing.expectEqual(@as(?Span, .{ .start = 0, .end = 6 }), try firstMatch("(ab)+", "", "ababab"));
    try testing.expect(try matches("(?:ab)+c", "", "ababc"));
}

test "backreferences" {
    try testing.expect(try matches("(a|b)\\1", "", "aa"));
    try testing.expect(!try matches("^(a|b)\\1$", "", "ab"));
    try testing.expect(try matches("(\\w+)\\s\\1", "", "hello hello"));
}

test "lookahead" {
    try testing.expect(try matches("foo(?=bar)", "", "foobar"));
    try testing.expect(!try matches("foo(?=bar)", "", "foobaz"));
    try testing.expect(try matches("foo(?!bar)", "", "foobaz"));
    try testing.expect(!try matches("foo(?!bar)", "", "foobar")); // negative assertion fails
    try testing.expect(try matches("q(?=u)(?=\\w)", "", "quick")); // stacked lookaheads
}

test "lookbehind" {
    // Positive: `bar` preceded by `foo`.
    try testing.expectEqual(@as(?Span, .{ .start = 3, .end = 6 }), try firstMatch("(?<=foo)bar", "", "foobar"));
    try testing.expect(!try matches("(?<=foo)bar", "", "xxxbar"));
    // A price: digits preceded by `$`.
    try testing.expectEqual(@as(?Span, .{ .start = 1, .end = 3 }), try firstMatch("(?<=\\$)\\d+", "", "$42"));
    // Negative lookbehind.
    try testing.expect(try matches("(?<!\\d)abc", "", "xabc"));
    try testing.expect(!try matches("(?<!x)abc", "", "xabc"));
    // Variable-length lookbehind.
    try testing.expect(try matches("(?<=a+)b", "", "aaab"));
    // Lookbehind at the start of input.
    try testing.expect(!try matches("(?<=.)^", "m", "abc"));
    // Capturing inside a positive lookbehind.
    {
        var re = try Regex.compileUtf8(testing.allocator, "(?<=(\\d{4}))-\\d\\d", "");
        defer re.deinit(testing.allocator);
        const units = try utf8ToUtf16(testing.allocator, "2026-07");
        defer testing.allocator.free(units);
        const m = (try re.find(testing.allocator, units, 0)).?;
        defer m.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), m.groups[1].?.start);
        try testing.expectEqual(@as(usize, 4), m.groups[1].?.end);
    }
}

test "case-insensitive" {
    try testing.expect(try matches("(\\w+)@(\\w+)", "i", "USER@Host")); // the CLI's demo pattern
    try testing.expect(try matches("hello", "i", "HELLO"));
    try testing.expect(try matches("[a-z]+", "i", "ABC"));
    try testing.expect(try matches("(foo)\\1", "i", "fooFOO"));
}

test "named groups" {
    var re = try Regex.compileUtf8(testing.allocator, "(?<year>\\d{4})", "");
    defer re.deinit(testing.allocator);
    try testing.expectEqual(@as(?u32, 1), re.groupIndex("year"));
    const units = try utf8ToUtf16(testing.allocator, "born 2026");
    defer testing.allocator.free(units);
    const m = (try re.find(testing.allocator, units, 0)).?;
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 5), m.groups[1].?.start);
    try testing.expectEqual(@as(usize, 9), m.groups[1].?.end);
}

test "catastrophic backtracking is bounded" {
    // Without a step budget this hangs; with one it must fail fast.
    try testing.expectError(error.PatternTooComplex, matches("(a+)+$", "", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!"));
}

test "utf conversion round-trips" {
    const cases = [_][]const u8{ "hello", "café", "日本語", "emoji 😀 mix", "" };
    for (cases) |s| {
        const units = try utf8ToUtf16(testing.allocator, s);
        defer testing.allocator.free(units);
        const back = try utf16ToUtf8(testing.allocator, units);
        defer testing.allocator.free(back);
        try testing.expectEqualStrings(s, back);
    }
}

test "invalid patterns" {
    try testing.expectError(error.InvalidPattern, matches("(abc", "", ""));
    try testing.expectError(error.InvalidPattern, matches("a)", "", ""));
    try testing.expectError(error.InvalidPattern, matches("*", "", ""));
    try testing.expectError(error.InvalidPattern, matches("a{3,2}", "", ""));
}

test "u-mode: code points" {
    // Dot consumes a whole surrogate pair.
    const m1 = (try firstMatch("^.$", "u", "😀")).?;
    try testing.expectEqual(@as(usize, 0), m1.start);
    try testing.expectEqual(@as(usize, 2), m1.end); // two code units, one code point
    try testing.expect(!(try matches("^.$", "", "😀"))); // non-u: two units

    // Quantifiers bind the whole astral atom.
    try testing.expect(try matches("^😀+$", "u", "😀😀😀"));
    {
        // Trailing lone surrogate: not another 😀 atom.
        var re = try Regex.compileUtf8(testing.allocator, "^😀+$", "u");
        defer re.deinit(testing.allocator);
        const units = [_]u16{ 0xd83d, 0xde00, 0xd83d };
        const m = try re.find(testing.allocator, &units, 0);
        try testing.expect(m == null);
    }

    // \u{...} escapes.
    try testing.expect(try matches("^\\u{1F600}$", "u", "😀"));
    try testing.expect(try matches("^\\u{61}$", "u", "a"));
    try testing.expectError(error.InvalidPattern, matches("\\u{110000}", "u", "x"));
    try testing.expectError(error.InvalidPattern, matches("\\u{}", "u", "x"));

    // Escape-pair combining: 😀 is one atom.
    try testing.expect(try matches("^\\uD83D\\uDE00+$", "u", "😀😀"));

    // Strict escapes: \q is a SyntaxError only in u-mode.
    try testing.expectError(error.InvalidPattern, matches("\\q", "u", "q"));
    try testing.expect(try matches("\\q", "", "q"));

    // v flag gets u semantics.
    try testing.expect(try matches("^.$", "v", "😀"));
}
