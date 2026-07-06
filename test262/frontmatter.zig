//! Parser for the Test262 YAML frontmatter block.
//!
//! Every Test262 file carries a `/*--- ... ---*/` block describing how to run
//! it. See test262/INTERPRETING.md. Phase 0 parses the fields the runner needs
//! to classify results: `flags`, `features`, `includes`, and `negative`.
//!
//! Strings in `includes`/`features` borrow from the source text; only the outer
//! arrays are allocated. Call `Meta.deinit` to free them.

const std = @import("std");

pub const Phase = enum { parse, resolution, runtime };

pub const Negative = struct {
    phase: Phase,
    /// Error constructor name expected, e.g. "SyntaxError". Borrows from source.
    type_name: []const u8,
};

pub const Flags = struct {
    /// Run only with an implicit "use strict" prologue.
    only_strict: bool = false,
    /// Run only in sloppy mode.
    no_strict: bool = false,
    /// Evaluate as a module.
    module: bool = false,
    /// Do not inject the standard harness (assert.js/sta.js).
    raw: bool = false,
    /// Test completes asynchronously via the $DONE / doneprintHandle contract.
    is_async: bool = false,
    /// Test may not run where [[CanBlock]] is true.
    can_block_is_false: bool = false,
    /// Mechanically generated (informational).
    generated: bool = false,
};

pub const Meta = struct {
    has_frontmatter: bool = false,
    flags: Flags = .{},
    negative: ?Negative = null,
    /// Harness helpers to prepend (borrowed from source).
    includes: [][]const u8 = &.{},
    /// Language/library features exercised (borrowed from source).
    features: [][]const u8 = &.{},

    pub fn deinit(self: *Meta, gpa: std.mem.Allocator) void {
        if (self.includes.len != 0) gpa.free(self.includes);
        if (self.features.len != 0) gpa.free(self.features);
        self.includes = &.{};
        self.features = &.{};
    }

    /// A test with neither flag runs in BOTH strict and sloppy variants.
    pub fn runsStrict(self: Meta) bool {
        return !self.flags.no_strict and !self.flags.module and !self.flags.raw;
    }
    pub fn runsSloppy(self: Meta) bool {
        return !self.flags.only_strict and !self.flags.module and !self.flags.raw;
    }
};

const open_marker = "/*---";
const close_marker = "---*/";

pub fn parse(gpa: std.mem.Allocator, source: []const u8) !Meta {
    const start = std.mem.indexOf(u8, source, open_marker) orelse return .{};
    const body_start = start + open_marker.len;
    const rel_end = std.mem.indexOf(u8, source[body_start..], close_marker) orelse return .{};
    const body = source[body_start .. body_start + rel_end];

    var meta: Meta = .{ .has_frontmatter = true };
    errdefer meta.deinit(gpa);

    var includes: std.ArrayList([]const u8) = .empty;
    defer includes.deinit(gpa);
    var features: std.ArrayList([]const u8) = .empty;
    defer features.deinit(gpa);

    var lines = std.mem.splitScalar(u8, body, '\n');
    var in_negative = false;
    while (lines.next()) |raw_line| {
        const line = trimEnd(raw_line);
        const indented = line.len != 0 and (line[0] == ' ' or line[0] == '\t');
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;

        // Inside the nested `negative:` block, consume indented `phase:`/`type:`.
        if (in_negative and indented) {
            if (stripKey(t, "phase:")) |v| {
                meta.negative.?.phase = parsePhase(v);
            } else if (stripKey(t, "type:")) |v| {
                meta.negative.?.type_name = v;
            }
            continue;
        }
        in_negative = false;

        if (stripKey(t, "flags:")) |v| {
            var it = arrayItems(v);
            while (it.next()) |item| applyFlag(&meta.flags, item);
        } else if (stripKey(t, "includes:")) |v| {
            var it = arrayItems(v);
            while (it.next()) |item| try includes.append(gpa, item);
        } else if (stripKey(t, "features:")) |v| {
            var it = arrayItems(v);
            while (it.next()) |item| try features.append(gpa, item);
        } else if (stripKey(t, "negative:")) |v| {
            // Default; refined by the nested lines or an inline flow mapping.
            meta.negative = .{ .phase = .parse, .type_name = "" };
            const flow = std.mem.trim(u8, v, " \t{}");
            if (flow.len != 0) {
                // Inline form: negative: {phase: parse, type: SyntaxError}
                var pairs = std.mem.splitScalar(u8, flow, ',');
                while (pairs.next()) |pair| {
                    const p = std.mem.trim(u8, pair, " \t");
                    if (stripKey(p, "phase:")) |pv| meta.negative.?.phase = parsePhase(pv);
                    if (stripKey(p, "type:")) |tv| meta.negative.?.type_name = std.mem.trim(u8, tv, " \t");
                }
            } else {
                in_negative = true;
            }
        }
    }

    meta.includes = try includes.toOwnedSlice(gpa);
    meta.features = try features.toOwnedSlice(gpa);
    return meta;
}

/// If `line` begins with `key`, return the trimmed remainder, else null.
fn stripKey(line: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    return std.mem.trim(u8, line[key.len..], " \t\r");
}

fn parsePhase(v: []const u8) Phase {
    const s = std.mem.trim(u8, v, " \t");
    if (std.mem.eql(u8, s, "parse")) return .parse;
    if (std.mem.eql(u8, s, "resolution")) return .resolution;
    return .runtime;
}

fn applyFlag(flags: *Flags, name: []const u8) void {
    if (std.mem.eql(u8, name, "onlyStrict")) flags.only_strict = true;
    if (std.mem.eql(u8, name, "noStrict")) flags.no_strict = true;
    if (std.mem.eql(u8, name, "module")) flags.module = true;
    if (std.mem.eql(u8, name, "raw")) flags.raw = true;
    if (std.mem.eql(u8, name, "async")) flags.is_async = true;
    if (std.mem.eql(u8, name, "CanBlockIsFalse")) flags.can_block_is_false = true;
    if (std.mem.eql(u8, name, "generated")) flags.generated = true;
}

/// Iterator over the items of a `[a, b, c]` flow array (or a bare scalar).
const ArrayItems = struct {
    inner: std.mem.SplitIterator(u8, .scalar),
    fn next(self: *ArrayItems) ?[]const u8 {
        while (self.inner.next()) |raw| {
            const item = std.mem.trim(u8, raw, " \t\r[]");
            if (item.len != 0) return item;
        }
        return null;
    }
};

fn arrayItems(v: []const u8) ArrayItems {
    const inner = std.mem.trim(u8, v, " \t\r[]");
    return .{ .inner = std.mem.splitScalar(u8, inner, ',') };
}

fn trimEnd(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, " \t\r");
}

// ---- Tests -----------------------------------------------------------------

test "no frontmatter" {
    var m = try parse(std.testing.allocator, "var x = 1;\n");
    defer m.deinit(std.testing.allocator);
    try std.testing.expect(!m.has_frontmatter);
    try std.testing.expect(m.negative == null);
}

test "flags, includes, features" {
    const src =
        \\// comment
        \\/*---
        \\description: something
        \\flags: [onlyStrict, async]
        \\includes: [propertyHelper.js, compareArray.js]
        \\features: [Symbol.iterator, BigInt]
        \\---*/
        \\doStuff();
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit(std.testing.allocator);

    try std.testing.expect(m.has_frontmatter);
    try std.testing.expect(m.flags.only_strict);
    try std.testing.expect(m.flags.is_async);
    try std.testing.expect(!m.flags.no_strict);
    try std.testing.expect(m.runsStrict());
    try std.testing.expect(!m.runsSloppy()); // onlyStrict

    try std.testing.expectEqual(@as(usize, 2), m.includes.len);
    try std.testing.expectEqualStrings("propertyHelper.js", m.includes[0]);
    try std.testing.expectEqualStrings("compareArray.js", m.includes[1]);
    try std.testing.expectEqual(@as(usize, 2), m.features.len);
    try std.testing.expectEqualStrings("BigInt", m.features[1]);
}

test "negative block (multiline)" {
    const src =
        \\/*---
        \\negative:
        \\  phase: parse
        \\  type: SyntaxError
        \\flags: [raw]
        \\---*/
        \\(
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit(std.testing.allocator);

    try std.testing.expect(m.negative != null);
    try std.testing.expectEqual(Phase.parse, m.negative.?.phase);
    try std.testing.expectEqualStrings("SyntaxError", m.negative.?.type_name);
    try std.testing.expect(m.flags.raw);
}

test "negative block (inline flow)" {
    const src =
        \\/*---
        \\negative: {phase: runtime, type: TypeError}
        \\---*/
        \\null.x;
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit(std.testing.allocator);

    try std.testing.expect(m.negative != null);
    try std.testing.expectEqual(Phase.runtime, m.negative.?.phase);
    try std.testing.expectEqualStrings("TypeError", m.negative.?.type_name);
}

test "default variants run both strict and sloppy" {
    var m = try parse(std.testing.allocator, "/*---\ndescription: x\n---*/\n1;");
    defer m.deinit(std.testing.allocator);
    try std.testing.expect(m.runsStrict());
    try std.testing.expect(m.runsSloppy());
}
