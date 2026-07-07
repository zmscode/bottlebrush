//! JSON.parse / JSON.stringify (parser struct + serialization helpers).

const std = @import("std");
const gc = @import("../../gc.zig");
const bc = @import("../../bytecode.zig");
const bilby = @import("bilby");
const Value = @import("../../value.zig").Value;
const interpreter = @import("../../interpreter.zig");
const Vm = interpreter.Vm;
const Error = interpreter.Error;

const support_mod = @import("../support.zig");
const argAt = support_mod.argAt;
const castVm = support_mod.castVm;
const coerceToString = support_mod.coerceToString;
const isCallable = support_mod.isCallable;
const numberToString = support_mod.numberToString;
const utf16ToUtf8Alloc = support_mod.utf16ToUtf8Alloc;

pub fn appendJsonChar(gpa: std.mem.Allocator, out: *std.ArrayList(u8), u: u16) Error!void {
    switch (u) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        8 => try out.appendSlice(gpa, "\\b"),
        12 => try out.appendSlice(gpa, "\\f"),
        else => {
            if (u < 0x20) {
                const hex = "0123456789abcdef";
                try out.appendSlice(gpa, "\\u");
                try out.append(gpa, hex[(u >> 12) & 0xf]);
                try out.append(gpa, hex[(u >> 8) & 0xf]);
                try out.append(gpa, hex[(u >> 4) & 0xf]);
                try out.append(gpa, hex[u & 0xf]);
            } else if (u < 0x80) {
                try out.append(gpa, @intCast(u));
            } else {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(u, &buf) catch {
                    try out.append(gpa, '?');
                    return;
                };
                try out.appendSlice(gpa, buf[0..n]);
            }
        },
    }
}

pub const JsonParser = struct {
    vm: *Vm,
    s: []const u8,
    i: usize,

    pub fn skipWs(self: *JsonParser) void {
        while (self.i < self.s.len) {
            switch (self.s[self.i]) {
                ' ', '\t', '\n', '\r' => self.i += 1,
                else => break,
            }
        }
    }
    pub fn peek(self: *JsonParser) u8 {
        return if (self.i < self.s.len) self.s[self.i] else 0;
    }

    pub fn parseValue(self: *JsonParser) Error!Value {
        self.skipWs();
        switch (self.peek()) {
            '{' => return self.parseObject(),
            '[' => return self.parseArray(),
            '"' => return self.parseString(),
            't' => {
                try self.expectWord("true");
                return Value.fromBool(true);
            },
            'f' => {
                try self.expectWord("false");
                return Value.fromBool(false);
            },
            'n' => {
                try self.expectWord("null");
                return Value.null_value;
            },
            '-', '0'...'9' => return self.parseNumber(),
            else => return self.vm.throwSyntaxError("Unexpected token in JSON"),
        }
    }

    pub fn expectWord(self: *JsonParser, word: []const u8) Error!void {
        if (self.i + word.len > self.s.len or !std.mem.eql(u8, self.s[self.i .. self.i + word.len], word)) {
            return self.vm.throwSyntaxError("Unexpected token in JSON");
        }
        self.i += word.len;
    }

    pub fn parseNumber(self: *JsonParser) Error!Value {
        const start = self.i;
        if (self.peek() == '-') self.i += 1;
        while (self.i < self.s.len and self.s[self.i] >= '0' and self.s[self.i] <= '9') self.i += 1;
        if (self.peek() == '.') {
            self.i += 1;
            while (self.i < self.s.len and self.s[self.i] >= '0' and self.s[self.i] <= '9') self.i += 1;
        }
        if (self.peek() == 'e' or self.peek() == 'E') {
            self.i += 1;
            if (self.peek() == '+' or self.peek() == '-') self.i += 1;
            while (self.i < self.s.len and self.s[self.i] >= '0' and self.s[self.i] <= '9') self.i += 1;
        }
        const n = std.fmt.parseFloat(f64, self.s[start..self.i]) catch return self.vm.throwSyntaxError("Invalid number in JSON");
        return Value.fromNumber(n);
    }

    /// Parse a JSON string; returns UTF-8 bytes in `buf` (caller-owned scratch).
    pub fn parseStringInto(self: *JsonParser, buf: *std.ArrayList(u8)) Error!void {
        if (self.peek() != '"') return self.vm.throwSyntaxError("Expected string in JSON");
        self.i += 1;
        while (self.i < self.s.len) {
            const c = self.s[self.i];
            self.i += 1;
            if (c == '"') return;
            if (c == '\\') {
                const e = self.peek();
                self.i += 1;
                switch (e) {
                    '"' => try buf.append(self.vm.gpa, '"'),
                    '\\' => try buf.append(self.vm.gpa, '\\'),
                    '/' => try buf.append(self.vm.gpa, '/'),
                    'b' => try buf.append(self.vm.gpa, 8),
                    'f' => try buf.append(self.vm.gpa, 12),
                    'n' => try buf.append(self.vm.gpa, '\n'),
                    'r' => try buf.append(self.vm.gpa, '\r'),
                    't' => try buf.append(self.vm.gpa, '\t'),
                    'u' => {
                        if (self.i + 4 > self.s.len) return self.vm.throwSyntaxError("Invalid \\u escape in JSON");
                        const cp = std.fmt.parseInt(u21, self.s[self.i .. self.i + 4], 16) catch return self.vm.throwSyntaxError("Invalid \\u escape in JSON");
                        self.i += 4;
                        var ub: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &ub) catch {
                            try buf.append(self.vm.gpa, '?');
                            continue;
                        };
                        try buf.appendSlice(self.vm.gpa, ub[0..n]);
                    },
                    else => return self.vm.throwSyntaxError("Invalid escape in JSON"),
                }
            } else {
                try buf.append(self.vm.gpa, c);
            }
        }
        return self.vm.throwSyntaxError("Unterminated string in JSON");
    }

    pub fn parseString(self: *JsonParser) Error!Value {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.vm.gpa);
        try self.parseStringInto(&buf);
        return self.vm.makeString(buf.items);
    }

    pub fn parseArray(self: *JsonParser) Error!Value {
        self.i += 1; // '['
        const arr = try self.vm.newArray(0);
        try self.vm.protect(Value.fromObject(arr));
        defer self.vm.unprotect();
        self.skipWs();
        if (self.peek() == ']') {
            self.i += 1;
            return Value.fromObject(arr);
        }
        while (true) {
            const v = try self.parseValue();
            try self.vm.arrayAppend(arr, v);
            self.skipWs();
            const c = self.peek();
            if (c == ',') {
                self.i += 1;
                continue;
            }
            if (c == ']') {
                self.i += 1;
                break;
            }
            return self.vm.throwSyntaxError("Expected ',' or ']' in JSON array");
        }
        return Value.fromObject(arr);
    }

    pub fn parseObject(self: *JsonParser) Error!Value {
        self.i += 1; // '{'
        const obj = try self.vm.newObject(self.vm.object_proto);
        try self.vm.protect(Value.fromObject(obj));
        defer self.vm.unprotect();
        self.skipWs();
        if (self.peek() == '}') {
            self.i += 1;
            return Value.fromObject(obj);
        }
        while (true) {
            self.skipWs();
            var key_buf: std.ArrayList(u8) = .empty;
            defer key_buf.deinit(self.vm.gpa);
            try self.parseStringInto(&key_buf);
            self.skipWs();
            if (self.peek() != ':') return self.vm.throwSyntaxError("Expected ':' in JSON object");
            self.i += 1;
            const v = try self.parseValue();
            try self.vm.setProperty(Value.fromObject(obj), key_buf.items, v);
            self.skipWs();
            const c = self.peek();
            if (c == ',') {
                self.i += 1;
                continue;
            }
            if (c == '}') {
                self.i += 1;
                break;
            }
            return self.vm.throwSyntaxError("Expected ',' or '}' in JSON object");
        }
        return Value.fromObject(obj);
    }
};

pub fn nativeJSONStringify(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);

    // The `space` argument -> indentation gap (max 10).
    const ten_spaces = "          ";
    var gap_buf: [64]u8 = undefined;
    var gap: []const u8 = "";
    const space = argAt(args, 2);
    if (space.isNumber()) {
        const n: usize = if (space.asNumber() < 0) 0 else if (space.asNumber() > 10) 10 else @intFromFloat(space.asNumber());
        gap = ten_spaces[0..n];
    } else if (space.isString()) {
        const units = space.asString().units;
        var len: usize = 0;
        for (units[0..@min(units.len, 10)]) |u| {
            if (len < gap_buf.len) {
                gap_buf[len] = if (u < 0x80) @intCast(u) else ' ';
                len += 1;
            }
        }
        gap = gap_buf[0..len];
    }

    // The `replacer` argument -> a function, or an allow-list of keys.
    var replacer: Value = Value.undefined_value;
    var keys_owned: std.ArrayList([]const u8) = .empty;
    defer {
        for (keys_owned.items) |k| vm.gpa.free(k);
        keys_owned.deinit(vm.gpa);
    }
    var keys_filter: ?[]const []const u8 = null;
    const replacer_arg = argAt(args, 1);
    if (isCallable(replacer_arg)) {
        replacer = replacer_arg;
    } else if (replacer_arg.isObject() and replacer_arg.asObject().is_array) {
        const ra = replacer_arg.asObject();
        var ri: u32 = 0;
        while (ri < ra.array_length) : (ri += 1) {
            const el = Vm.arrayGetOwn(ra, ri) orelse continue;
            if (el.isString()) {
                const kb = try utf16ToUtf8Alloc(vm.gpa, el.asString().units);
                try keys_owned.append(vm.gpa, kb);
            } else if (el.isNumber()) {
                var nb: [24]u8 = undefined;
                const ks = numberToString(el.asNumber(), &nb);
                try keys_owned.append(vm.gpa, try vm.gpa.dupe(u8, ks));
            }
        }
        keys_filter = keys_owned.items;
    }

    // Wrap the value in a holder for SerializeJSONProperty.
    const holder = try vm.newObject(vm.object_proto);
    try vm.protect(Value.fromObject(holder));
    defer vm.unprotect();
    try vm.defineData(holder, "", argAt(args, 0), true, true, true);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.gpa);
    var stack: std.ArrayList(*gc.Object) = .empty;
    defer stack.deinit(vm.gpa);
    var indent: std.ArrayList(u8) = .empty;
    defer indent.deinit(vm.gpa);
    const c = Vm.JsonCtx{ .out = &out, .stack = &stack, .indent = &indent, .gap = gap, .replacer = replacer, .keys_filter = keys_filter };

    if (!try vm.jsonSerializeProperty(c, Value.fromObject(holder), "")) return Value.undefined_value;
    return vm.makeString(out.items);
}

pub fn nativeJSONParse(ctx: *anyopaque, this: Value, args: []const Value) Error!Value {
    _ = this;
    const vm = castVm(ctx);
    const text_v = try coerceToString(vm, argAt(args, 0));
    try vm.protect(text_v);
    defer vm.unprotect();
    const utf8 = try utf16ToUtf8Alloc(vm.gpa, text_v.asString().units);
    defer vm.gpa.free(utf8);
    return vm.jsonParse(utf8, argAt(args, 1));
}
