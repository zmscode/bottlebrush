//! End-to-end VM tests: compile + run JS snippets through the full pipeline.

const std = @import("std");
const Value = @import("value.zig").Value;
const interpreter = @import("interpreter.zig");
const Vm = interpreter.Vm;

const support = @import("runtime/support.zig");
const toBoolean = support.toBoolean;
const utf16ToUtf8Alloc = support.utf16ToUtf8Alloc;

const testing = std.testing;

/// Compile and run `source`; return the script's completion value.
fn eval(vm: *Vm, source: []const u8) !Value {
    const parser = @import("parser.zig");
    const compiler = @import("compiler.zig");
    var pr = try parser.parse(testing.allocator, source, .script);
    switch (pr) {
        .syntax_error => return error.ParseFailed,
        .ok => |*a| {
            defer a.deinit();
            var cr = try compiler.compile(testing.allocator, a.root, source);
            switch (cr) {
                .compile_error => return error.CompileFailed,
                .ok => |*program| {
                    defer program.deinit();
                    return vm.run(program);
                },
            }
        },
    }
}

fn evalNumber(source: []const u8) !f64 {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    const v = try eval(&vm, source);
    try testing.expect(v.isNumber());
    return v.asNumber();
}

test "arithmetic" {
    try testing.expectEqual(@as(f64, 7), try evalNumber("return 1 + 2 * 3;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return 10 % 3;"));
    try testing.expectEqual(@as(f64, 8), try evalNumber("return 2 ** 3;"));
    try testing.expectEqual(@as(f64, -5), try evalNumber("return -(2 + 3);"));
    try testing.expectEqual(@as(f64, 6), try evalNumber("return (0xF & 0x6) | 0;"));
}

test "variables and assignment" {
    try testing.expectEqual(@as(f64, 30), try evalNumber("var a = 10; var b = 20; return a + b;"));
    try testing.expectEqual(@as(f64, 15), try evalNumber("var a = 10; a += 5; return a;"));
    try testing.expectEqual(@as(f64, 3), try evalNumber("var a = 1; var b = a++; return a + b;"));
    try testing.expectEqual(@as(f64, 4), try evalNumber("var a = 1; var b = ++a; return a + b;"));
}

test "control flow" {
    try testing.expectEqual(@as(f64, 1), try evalNumber("if (true) return 1; return 2;"));
    try testing.expectEqual(@as(f64, 2), try evalNumber("if (false) return 1; else return 2;"));
    try testing.expectEqual(@as(f64, 55), try evalNumber(
        \\var sum = 0;
        \\for (var i = 1; i <= 10; i++) sum += i;
        \\return sum;
    ));
    try testing.expectEqual(@as(f64, 6), try evalNumber(
        \\var n = 3; var f = 1;
        \\while (n > 0) { f *= n; n--; }
        \\return f;
    ));
    try testing.expectEqual(@as(f64, 4), try evalNumber(
        \\var i = 0;
        \\for (;;) { i++; if (i === 4) break; }
        \\return i;
    ));
}

test "functions, recursion, closures" {
    try testing.expectEqual(@as(f64, 120), try evalNumber(
        \\function fact(n) { if (n <= 1) return 1; return n * fact(n - 1); }
        \\return fact(5);
    ));
    try testing.expectEqual(@as(f64, 55), try evalNumber(
        \\function fib(n) { if (n < 2) return n; return fib(n-1) + fib(n-2); }
        \\return fib(10);
    ));
    try testing.expectEqual(@as(f64, 8), try evalNumber(
        \\function adder(x) { return function(y) { return x + y; }; }
        \\var add5 = adder(5);
        \\return add5(3);
    ));
    try testing.expectEqual(@as(f64, 25), try evalNumber(
        \\var square = (x) => x * x;
        \\return square(5);
    ));
}

test "logical and conditional" {
    try testing.expectEqual(@as(f64, 2), try evalNumber("return 0 || 2;"));
    try testing.expectEqual(@as(f64, 3), try evalNumber("return 1 && 3;"));
    try testing.expectEqual(@as(f64, 5), try evalNumber("return null ?? 5;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return true ? 1 : 2;"));
}

test "strings and equality" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();

    const v = try eval(&vm, "return 'foo' + 'bar';");
    try testing.expect(v.isString());
    try testing.expectEqualSlices(u16, &[_]u16{ 'f', 'o', 'o', 'b', 'a', 'r' }, v.asString().units);

    try testing.expect(toBoolean(try eval(&vm, "return 1 == '1';")));
    try testing.expect(!toBoolean(try eval(&vm, "return 1 === '1';")));
    try testing.expect(toBoolean(try eval(&vm, "return null == undefined;")));
    try testing.expect(toBoolean(try eval(&vm, "return 'a' < 'b';")));
}

test "typeof" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    const v = try eval(&vm, "return typeof 42;");
    try testing.expectEqualSlices(u16, &[_]u16{ 'n', 'u', 'm', 'b', 'e', 'r' }, v.asString().units);
}

test "try/catch catches a throw" {
    try testing.expectEqual(@as(f64, 42), try evalNumber(
        \\var result = 0;
        \\try { throw 42; } catch (e) { result = e; }
        \\return result;
    ));
}

test "uncaught throw propagates" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    const r = eval(&vm, "throw 99;");
    try testing.expectError(error.JsThrow, r);
    try testing.expect(vm.pending_exception.?.isNumber());
    try testing.expectEqual(@as(f64, 99), vm.pending_exception.?.asNumber());
}

test "calling a non-function throws" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    const r = eval(&vm, "var x = 5; return x();");
    try testing.expectError(error.JsThrow, r);
}

test "runs under GC stress" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    vm.heap.stress = true;
    const v = try eval(&vm,
        \\function make(n) { return function() { return n; }; }
        \\var f = make(7);
        \\return f() + f();
    );
    try testing.expect(v.isNumber());
    try testing.expectEqual(@as(f64, 14), v.asNumber());
}

test "object literals and member access" {
    try testing.expectEqual(@as(f64, 3), try evalNumber("var o = { a: 1, b: 2 }; return o.a + o.b;"));
    try testing.expectEqual(@as(f64, 5), try evalNumber("var o = {}; o.x = 5; return o.x;"));
    try testing.expectEqual(@as(f64, 7), try evalNumber("var o = {}; o['k'] = 7; return o['k'];"));
    try testing.expectEqual(@as(f64, 3), try evalNumber("var o = { a: { b: 3 } }; return o.a.b;"));
    try testing.expectEqual(@as(f64, 0), try evalNumber("var o = {}; return o.missing === undefined ? 0 : 1;"));
}

test "methods and this" {
    try testing.expectEqual(@as(f64, 10), try evalNumber(
        \\var o = { x: 10, getX() { return this.x; } };
        \\return o.getX();
    ));
    try testing.expectEqual(@as(f64, 30), try evalNumber(
        \\var o = { a: 10, b: 20, sum: function() { return this.a + this.b; } };
        \\return o.sum();
    ));
}

test "new and constructors" {
    try testing.expectEqual(@as(f64, 5), try evalNumber(
        \\function Point(x) { this.x = x; }
        \\var p = new Point(5);
        \\return p.x;
    ));
    try testing.expectEqual(@as(f64, 7), try evalNumber(
        \\function Box(v) { this.v = v; }
        \\Box.prototype.get = function() { return this.v; };
        \\var b = new Box(7);
        \\return b.get();
    ));
    try testing.expectEqual(@as(f64, 3), try evalNumber(
        \\function Counter() { this.n = 0; }
        \\Counter.prototype.inc = function() { this.n = this.n + 1; return this; };
        \\var c = new Counter();
        \\c.inc().inc().inc();
        \\return c.n;
    ));
}

test "arrow functions capture lexical this" {
    try testing.expectEqual(@as(f64, 42), try evalNumber(
        \\var o = {
        \\  x: 42,
        \\  get: function () {
        \\    var f = () => this.x;
        \\    return f();
        \\  }
        \\};
        \\return o.get();
    ));
    // The arrow's `this` survives extraction and .call() with another receiver.
    try testing.expectEqual(@as(f64, 7), try evalNumber(
        \\var o = { x: 7, mk: function () { return () => this.x; } };
        \\var f = o.mk();
        \\return f.call({ x: 99 });
    ));
}

test "arrow functions and non-constructors are not new-able" {
    // Arrow functions have no [[Construct]].
    {
        var vm = Vm.init(testing.allocator);
        defer vm.deinit();
        try testing.expectError(error.JsThrow, eval(&vm, "var f = () => {}; return new f();"));
    }
    // Ordinary function declarations still construct.
    try testing.expectEqual(@as(f64, 9), try evalNumber(
        \\function Sq(x) { this.v = x * x; }
        \\return new Sq(3).v;
    ));
    // Native built-ins that aren't constructors reject `new`.
    {
        var vm = Vm.init(testing.allocator);
        defer vm.deinit();
        try testing.expectError(error.JsThrow, eval(&vm, "return new Math.abs(1);"));
    }
}

test "object toString coercion in concatenation" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    const v = try eval(&vm,
        \\var o = { toString: function() { return "hi"; } };
        \\return o + "!";
    );
    try testing.expect(v.isString());
    try testing.expectEqualSlices(u16, &[_]u16{ 'h', 'i', '!' }, v.asString().units);
}

test "globals, instanceof, in, typeof-undeclared" {
    try testing.expectEqual(@as(f64, 42), try evalNumber("foo = 42; return foo;"));
    try testing.expectEqual(@as(f64, 7), try evalNumber("globalThis.bar = 7; return bar;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\function C() {}
        \\var c = new C();
        \\return (c instanceof C) ? 1 : 0;
    ));
    try testing.expectEqual(@as(f64, 1), try evalNumber("var o = { a: 1 }; return ('a' in o) ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 0), try evalNumber("var o = { a: 1 }; return ('b' in o) ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return (typeof notDeclared === 'undefined') ? 1 : 0;"));
}

test "reading an undeclared global throws ReferenceError" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    try testing.expectError(error.JsThrow, eval(&vm, "return missingGlobalVar;"));
}

test "error objects and instanceof" {
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var e = new TypeError("boom");
        \\return (e.message === "boom" && e.name === "TypeError") ? 1 : 0;
    ));
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var e = new RangeError("x");
        \\return (e instanceof RangeError && e instanceof Error) ? 1 : 0;
    ));
    // Engine-thrown errors are real Error objects now.
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\try { null.x; } catch (e) { return (e instanceof TypeError) ? 1 : 0; }
        \\return 0;
    ));
}

test "Error.prototype.toString" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    const v = try eval(&vm, "return new Error('nope').toString();");
    try testing.expect(v.isString());
    try testing.expectEqualSlices(u16, &[_]u16{ 'E', 'r', 'r', 'o', 'r', ':', ' ', 'n', 'o', 'p', 'e' }, v.asString().units);
}

test "String / Number / Boolean" {
    try testing.expectEqual(@as(f64, 1), try evalNumber("return String(42) === '42' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 3.5), try evalNumber("return Number('3.5');"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return Boolean(0) === false ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return String(true) === 'true' ? 1 : 0;"));
}

test "Math" {
    try testing.expectEqual(@as(f64, 5), try evalNumber("return Math.abs(-5);"));
    try testing.expectEqual(@as(f64, 3), try evalNumber("return Math.floor(3.9);"));
    try testing.expectEqual(@as(f64, 4), try evalNumber("return Math.ceil(3.1);"));
    try testing.expectEqual(@as(f64, 4), try evalNumber("return Math.sqrt(16);"));
    try testing.expectEqual(@as(f64, 7), try evalNumber("return Math.max(1, 7, 3);"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return Math.min(1, 7, 3);"));
    try testing.expectEqual(@as(f64, 8), try evalNumber("return Math.pow(2, 3);"));
}

test "Object builtins" {
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var o = { a: 1 };
        \\return o.hasOwnProperty('a') && !o.hasOwnProperty('b') ? 1 : 0;
    ));
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var proto = { greet: 5 };
        \\var o = Object.create(proto);
        \\return (Object.getPrototypeOf(o) === proto && o.greet === 5) ? 1 : 0;
    ));
    try testing.expectEqual(@as(f64, 42), try evalNumber(
        \\var o = {};
        \\Object.defineProperty(o, 'x', { value: 42, enumerable: false });
        \\return o.x;
    ));
}

test "array literals and indexing" {
    try testing.expectEqual(@as(f64, 40), try evalNumber("var a = [10, 20, 30]; return a[0] + a[2];"));
    try testing.expectEqual(@as(f64, 3), try evalNumber("return [1, 2, 3].length;"));
    try testing.expectEqual(@as(f64, 4), try evalNumber("var a = []; a[3] = 9; return a.length;"));
    try testing.expectEqual(@as(f64, 2), try evalNumber("var a = [1, 2, 3, 4]; a.length = 2; return a.length;"));
    try testing.expectEqual(@as(f64, 3), try evalNumber("return new Array(3).length;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return Array.isArray([]) && !Array.isArray({}) ? 1 : 0;"));
}

test "array mutation methods" {
    try testing.expectEqual(@as(f64, 5), try evalNumber("var a = [1]; a.push(2); a.push(3); return a.pop() + a.length;"));
    try testing.expectEqual(@as(f64, 4), try evalNumber("return [1, 2].concat([3, 4]).length;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("var a = [1, 2, 3]; return (a.indexOf(2) === 1 && a.includes(3)) ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return [1, 2, 3].join('-') === '1-2-3' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("var a = [1, 2, 3, 4].slice(1, 3); return (a.length === 2 && a[0] === 2) ? 1 : 0;"));
}

test "array higher-order methods" {
    try testing.expectEqual(@as(f64, 12), try evalNumber(
        \\var a = [1, 2, 3].map(function (x) { return x * 2; });
        \\return a[0] + a[1] + a[2];
    ));
    try testing.expectEqual(@as(f64, 2), try evalNumber(
        \\var a = [1, 2, 3, 4].filter(function (x) { return x % 2 === 0; });
        \\return a.length;
    ));
    try testing.expectEqual(@as(f64, 6), try evalNumber(
        \\var sum = 0;
        \\[1, 2, 3].forEach(function (x) { sum += x; });
        \\return sum;
    ));
}

test "Object.keys/values/entries" {
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var o = { a: 1, b: 2 };
        \\var k = Object.keys(o);
        \\return (k.length === 2 && k[0] === 'a' && k[1] === 'b') ? 1 : 0;
    ));
    try testing.expectEqual(@as(f64, 3), try evalNumber(
        \\var o = { a: 1, b: 2 };
        \\var v = Object.values(o);
        \\return v[0] + v[1];
    ));
}

test "string primitive access and methods" {
    try testing.expectEqual(@as(f64, 5), try evalNumber("return 'hello'.length;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return 'hello'[1] === 'e' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 104), try evalNumber("return 'hello'.charCodeAt(0);"));
    try testing.expectEqual(@as(f64, 2), try evalNumber("return 'hello'.indexOf('ll');"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return 'hello'.includes('ell') ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return 'hello'.slice(1, 3) === 'el' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return 'Hello'.toUpperCase() === 'HELLO' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return 'Hello'.toLowerCase() === 'hello' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return '  hi  '.trim() === 'hi' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return 'ab'.repeat(3) === 'ababab' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 3), try evalNumber("return 'a,b,c'.split(',').length;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return 'a'.concat('b', 'c') === 'abc' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return String.fromCharCode(104, 105) === 'hi' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return ('hi'.startsWith('h') && 'hi'.endsWith('i')) ? 1 : 0;"));
}

test "Map" {
    try testing.expectEqual(@as(f64, 5), try evalNumber(
        \\var m = new Map();
        \\m.set("a", 1); m.set("b", 2);
        \\return m.get("a") + m.get("b") + m.size;
    ));
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var m = new Map();
        \\m.set(1, "x");
        \\var had = m.has(1);
        \\m.delete(1);
        \\return (had && !m.has(1) && m.size === 0) ? 1 : 0;
    ));
    // Object keys by identity; NaN key via SameValueZero.
    try testing.expectEqual(@as(f64, 42), try evalNumber("var m = new Map(); var k = {}; m.set(k, 42); return m.get(k);"));
    try testing.expectEqual(@as(f64, 5), try evalNumber("var m = new Map(); m.set(NaN, 5); return m.get(NaN);"));
    try testing.expectEqual(@as(f64, 2), try evalNumber("var m = new Map([['a', 1], ['b', 2]]); return m.get('b');"));
    // Overwrite keeps size; chaining returns the map.
    try testing.expectEqual(@as(f64, 1), try evalNumber("var m = new Map(); m.set(1, 'a'); m.set(1, 'b'); return m.size;"));
    try testing.expectEqual(@as(f64, 6), try evalNumber(
        \\var m = new Map([['a', 1], ['b', 2], ['c', 3]]);
        \\var sum = 0;
        \\m.forEach(function (v) { sum += v; });
        \\return sum;
    ));
}

test "Set" {
    try testing.expectEqual(@as(f64, 2), try evalNumber("var s = new Set(); s.add(1); s.add(2); s.add(1); return s.size;"));
    try testing.expectEqual(@as(f64, 3), try evalNumber("var s = new Set([1, 2, 2, 3]); return s.size;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var s = new Set();
        \\s.add("x");
        \\var had = s.has("x");
        \\s.delete("x");
        \\return (had && !s.has("x") && s.size === 0) ? 1 : 0;
    ));
    try testing.expectEqual(@as(f64, 6), try evalNumber(
        \\var s = new Set([1, 2, 3]);
        \\var sum = 0;
        \\s.forEach(function (v) { sum += v; });
        \\return sum;
    ));
}

test "Map/Set under GC stress" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    vm.heap.stress = true;
    const v = try eval(&vm,
        \\var m = new Map();
        \\for (var i = 0; i < 15; i++) { m.set("k" + i, i); }
        \\var s = new Set();
        \\for (var j = 0; j < 15; j++) { s.add(j % 5); }
        \\return m.size + s.size;
    );
    try testing.expectEqual(@as(f64, 20), v.asNumber()); // 15 + 5
}

test "JSON.stringify" {
    try testing.expectEqual(@as(f64, 1), try evalNumber("return JSON.stringify(42) === '42' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return JSON.stringify('hi') === '\"hi\"' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return JSON.stringify(true) === 'true' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return JSON.stringify(null) === 'null' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return JSON.stringify([1, 2, 3]) === '[1,2,3]' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return JSON.stringify({ a: 1, b: 2 }) === '{\"a\":1,\"b\":2}' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return JSON.stringify({ a: [1, 2], b: { c: 3 } }) === '{\"a\":[1,2],\"b\":{\"c\":3}}' ? 1 : 0;"));
    // undefined / functions omitted from objects, null in arrays.
    try testing.expectEqual(@as(f64, 1), try evalNumber("return JSON.stringify({ a: 1, b: undefined }) === '{\"a\":1}' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return JSON.stringify([1, undefined, 3]) === '[1,null,3]' ? 1 : 0;"));
}

test "JSON.parse and round-trip" {
    try testing.expectEqual(@as(f64, 42), try evalNumber("return JSON.parse('42');"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return JSON.parse('\"hi\"') === 'hi' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return JSON.parse('true') === true ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return JSON.parse('null') === null ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 5), try evalNumber(
        \\var o = JSON.parse('{"a":1,"b":[2,3]}');
        \\return o.a + o.b[0] + o.b[1] - 1;
    ));
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var o = { x: 1, y: [2, 3], z: "hi" };
        \\var r = JSON.parse(JSON.stringify(o));
        \\return (r.x === 1 && r.y[1] === 3 && r.z === "hi") ? 1 : 0;
    ));
}

test "JSON.stringify space and replacer" {
    // Indentation with a numeric space.
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\return JSON.stringify({ a: 1 }, null, 2) === '{\n  "a": 1\n}' ? 1 : 0;
    ));
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\return JSON.stringify([1, 2], null, 1) === '[\n 1,\n 2\n]' ? 1 : 0;
    ));
    // Replacer function.
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var r = JSON.stringify({ a: 1, b: 2 }, function (k, v) { return k === 'b' ? undefined : v; });
        \\return r === '{"a":1}' ? 1 : 0;
    ));
    // Replacer allow-list.
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\return JSON.stringify({ a: 1, b: 2, c: 3 }, ["a", "c"]) === '{"a":1,"c":3}' ? 1 : 0;
    ));
}

test "JSON.parse reviver" {
    try testing.expectEqual(@as(f64, 20), try evalNumber(
        \\var o = JSON.parse('{"a":5,"b":5}', function (k, v) { return typeof v === 'number' ? v * 2 : v; });
        \\return o.a + o.b;
    ));
    // Reviver returning undefined deletes the property.
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var o = JSON.parse('{"a":1,"drop":2}', function (k, v) { return k === 'drop' ? undefined : v; });
        \\return ('drop' in o) ? 0 : 1;
    ));
}

test "JSON cyclic structure throws" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    try testing.expectError(error.JsThrow, eval(&vm, "var o = {}; o.self = o; return JSON.stringify(o);"));
}

test "RegExp construction" {
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var re = /abc/gi;
        \\return (re.source === "abc" && re.flags === "gi" && re.global && re.ignoreCase && !re.multiline) ? 1 : 0;
    ));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return (/x/ instanceof RegExp) ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var re = new RegExp("foo", "m");
        \\return (re.source === "foo" && re.multiline && re.flags === "m") ? 1 : 0;
    ));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return /ab/g.toString() === '/ab/g' ? 1 : 0;"));
}

test "RegExp.prototype.test" {
    try testing.expectEqual(@as(f64, 1), try evalNumber("return /x/.test('axb') ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 0), try evalNumber("return /x/.test('ab') ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return /^\\d{3}-\\d{4}$/.test('555-1234') ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return /hello/i.test('HELLO world') ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return /(?<=\\$)\\d+/.test('$42') ? 1 : 0;")); // lookbehind
    try testing.expectEqual(@as(f64, 1), try evalNumber("return new RegExp('a+b').test('caaab') ? 1 : 0;"));
}

test "RegExp.prototype.exec: match array, index, captures" {
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var m = /(\d{4})-(\d{2})/.exec("born 2026-07!");
        \\return (m[0] === "2026-07" && m[1] === "2026" && m[2] === "07" &&
        \\        m.index === 5 && m.input === "born 2026-07!" && m.length === 3) ? 1 : 0;
    ));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return /z/.exec('abc') === null ? 1 : 0;"));
    // Unmatched optional group is undefined.
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var m = /a(b)?c/.exec("ac");
        \\return (m[0] === "ac" && m[1] === undefined) ? 1 : 0;
    ));
    // Named groups.
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var m = /(?<y>\d{4})-(?<mo>\d{2})/.exec("2026-07");
        \\return (m.groups.y === "2026" && m.groups.mo === "07") ? 1 : 0;
    ));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return /(a)/.exec('a').groups === undefined ? 1 : 0;"));
}

test "RegExp global: lastIndex drives repeated exec" {
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var re = /\d+/g;
        \\var a = re.exec("a1 b22 c333");
        \\var b = re.exec("a1 b22 c333");
        \\var c = re.exec("a1 b22 c333");
        \\var d = re.exec("a1 b22 c333");
        \\return (a[0] === "1" && b[0] === "22" && c[0] === "333" && d === null && re.lastIndex === 0) ? 1 : 0;
    ));
    // Sticky: anchored at lastIndex exactly.
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var re = /b/y;
        \\re.lastIndex = 1;
        \\var hit = re.exec("abc");
        \\re.lastIndex = 0;
        \\var miss = re.exec("abc");
        \\return (hit !== null && miss === null) ? 1 : 0;
    ));
}

test "RegExp invalid pattern throws SyntaxError" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    const v = try eval(&vm,
        \\try { new RegExp("(unclosed"); return "no-throw"; }
        \\catch (e) { return (e instanceof SyntaxError) ? "syntax" : "other"; }
    );
    try testing.expect(v.isString());
    const utf8 = try utf16ToUtf8Alloc(testing.allocator, v.asString().units);
    defer testing.allocator.free(utf8);
    try testing.expectEqualStrings("syntax", utf8);
}

test "String.prototype.search and match" {
    try testing.expectEqual(@as(f64, 4), try evalNumber("return 'abc 123'.search(/\\d+/);"));
    try testing.expectEqual(@as(f64, -1), try evalNumber("return 'abc'.search(/z/);"));
    try testing.expectEqual(@as(f64, 2), try evalNumber("return 'ab3'.search('3');")); // string coerced to regex
    // Non-global match = exec.
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var m = "id-42".match(/(\d+)/);
        \\return (m[0] === "42" && m[1] === "42" && m.index === 3) ? 1 : 0;
    ));
    // Global match = all matched substrings.
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var m = "a1 b22 c333".match(/\d+/g);
        \\return (m.length === 3 && m[0] === "1" && m[1] === "22" && m[2] === "333") ? 1 : 0;
    ));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return 'abc'.match(/z/g) === null ? 1 : 0;"));
}

test "String.prototype.replace" {
    try testing.expectEqual(@as(f64, 1), try evalNumber("return 'a-b-c'.replace('-', '+') === 'a+b-c' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return 'a-b-c'.replace(/-/g, '+') === 'a+b+c' ? 1 : 0;"));
    // $& $1 $` $' substitutions.
    try testing.expectEqual(@as(f64, 1), try evalNumber("return 'John Smith'.replace(/(\\w+) (\\w+)/, '$2 $1') === 'Smith John' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return 'abc'.replace(/b/, '[$&]') === 'a[b]c' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return 'x$y'.replace('$', '$$') === 'x$y' ? 1 : 0;"));
    // Named-group substitution.
    try testing.expectEqual(@as(f64, 1), try evalNumber("return '2026-07'.replace(/(?<y>\\d+)-(?<m>\\d+)/, '$<m>/$<y>') === '07/2026' ? 1 : 0;"));
    // Function replacer.
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var s = "a1b2".replace(/\d/g, function (m, off) { return "<" + m + "@" + off + ">"; });
        \\return s === "a<1@1>b<2@3>" ? 1 : 0;
    ));
}

test "String.prototype.split with regex and limit" {
    try testing.expectEqual(@as(f64, 1), try evalNumber("return 'a1b22c'.split(/\\d+/).join(',') === 'a,b,c' ? 1 : 0;"));
    // Captures are spliced into the result.
    try testing.expectEqual(@as(f64, 1), try evalNumber("return 'a1b'.split(/(\\d)/).join(',') === 'a,1,b' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 2), try evalNumber("return 'a-b-c'.split('-', 2).length;"));
    try testing.expectEqual(@as(f64, 0), try evalNumber("return 'a-b'.split('-', 0).length;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return 'ab'.split(/a*/).join(',') === ',b' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return ''.split('x').join('|') === '' ? 1 : 0;"));
}

test "RegExp under GC stress" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    vm.heap.stress = true;
    const v = try eval(&vm,
        \\var total = 0;
        \\for (var i = 0; i < 5; i++) {
        \\  var m = /(\w+)-(\w+)/.exec("aa-bb");
        \\  total += m[1].length + m[2].length;
        \\}
        \\return total;
    );
    try testing.expectEqual(@as(f64, 20), v.asNumber());
}

test "TypedArrays: construction and element access" {
    try testing.expectEqual(@as(f64, 4), try evalNumber("return new Int32Array(4).length;"));
    try testing.expectEqual(@as(f64, 30), try evalNumber("var a = new Int32Array(3); a[0] = 10; a[1] = 20; return a[0] + a[1];"));
    try testing.expectEqual(@as(f64, 6), try evalNumber("var a = new Int32Array([1, 2, 3]); return a[0] + a[1] + a[2];"));
    try testing.expectEqual(@as(f64, 4), try evalNumber("return Int32Array.BYTES_PER_ELEMENT;"));
    try testing.expectEqual(@as(f64, 16), try evalNumber("return new Int32Array(4).byteLength;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return (new Int32Array(1) instanceof Int32Array) ? 1 : 0;"));
}

test "TypedArrays: element type coercion" {
    try testing.expectEqual(@as(f64, 44), try evalNumber("var a = new Uint8Array(1); a[0] = 300; return a[0];")); // 300 & 255
    try testing.expectEqual(@as(f64, -56), try evalNumber("var a = new Int8Array(1); a[0] = 200; return a[0];")); // 200 as i8
    try testing.expectEqual(@as(f64, 255), try evalNumber("var a = new Uint8ClampedArray(1); a[0] = 300; return a[0];")); // clamped
    try testing.expectEqual(@as(f64, 0), try evalNumber("var a = new Uint8ClampedArray(1); a[0] = -5; return a[0];")); // clamped low
    try testing.expectEqual(@as(f64, 3.5), try evalNumber("var a = new Float64Array(1); a[0] = 3.5; return a[0];"));
}

test "TypedArrays: ArrayBuffer views" {
    try testing.expectEqual(@as(f64, 16), try evalNumber("return new ArrayBuffer(16).byteLength;"));
    try testing.expectEqual(@as(f64, 14), try evalNumber(
        \\var b = new ArrayBuffer(8);
        \\var a = new Int32Array(b);
        \\a[0] = 5; a[1] = 7;
        \\return a.length + a[0] + a[1];
    ));
    // Two views share one buffer (little-endian low byte).
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var b = new ArrayBuffer(4);
        \\var bytes = new Uint8Array(b);
        \\var ints = new Int32Array(b);
        \\ints[0] = 1;
        \\return bytes[0];
    ));
}

test "TypedArrays: methods" {
    try testing.expectEqual(@as(f64, 28), try evalNumber("var a = new Int32Array(4); a.fill(7); return a[0] + a[1] + a[2] + a[3];"));
    try testing.expectEqual(@as(f64, 6), try evalNumber("var a = new Int32Array(4); a.set([1, 2, 3], 1); return a[1] + a[2] + a[3];"));
    try testing.expectEqual(@as(f64, 4), try evalNumber("var a = new Int32Array([1, 2, 3, 4]); var s = a.subarray(1, 3); return s.length + s[0];"));
    // subarray shares the buffer.
    try testing.expectEqual(@as(f64, 99), try evalNumber("var a = new Int32Array([1, 2, 3, 4]); var s = a.subarray(1); s[0] = 99; return a[1];"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return new Int32Array([1, 2, 3]).join('-') === '1-2-3' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return new Int32Array([5, 6, 7]).indexOf(6);"));
    try testing.expectEqual(@as(f64, 6), try evalNumber(
        \\var sum = 0;
        \\new Int32Array([1, 2, 3]).forEach(function (x) { sum += x; });
        \\return sum;
    ));
}

test "TypedArrays under GC stress" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    vm.heap.stress = true;
    const v = try eval(&vm,
        \\var total = 0;
        \\for (var i = 0; i < 10; i++) {
        \\  var a = new Float64Array(8);
        \\  a.fill(i);
        \\  total += a[3];
        \\}
        \\return total;
    );
    try testing.expectEqual(@as(f64, 45), v.asNumber()); // 0+1+...+9
}

test "Proxy" {
    // get trap.
    try testing.expectEqual(@as(f64, 100), try evalNumber(
        \\var p = new Proxy({}, { get: function (t, k) { return 100; } });
        \\return p.anything;
    ));
    // set trap intercepts.
    try testing.expectEqual(@as(f64, 5), try evalNumber(
        \\var log = 0;
        \\var p = new Proxy({}, { set: function (t, k, v) { log = v; return true; } });
        \\p.x = 5;
        \\return log;
    ));
    // has trap for `in`.
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var p = new Proxy({}, { has: function (t, k) { return k === 'yes'; } });
        \\return (('yes' in p) && !('no' in p)) ? 1 : 0;
    ));
    // No trap -> forwards to target.
    try testing.expectEqual(@as(f64, 42), try evalNumber("var p = new Proxy({ v: 42 }, {}); return p.v;"));
    // apply trap.
    try testing.expectEqual(@as(f64, 20), try evalNumber(
        \\function base() { return 1; }
        \\var p = new Proxy(base, { apply: function (t, thisArg, args) { return args[0] * 2; } });
        \\return p(10);
    ));
}

test "Reflect" {
    try testing.expectEqual(@as(f64, 3), try evalNumber("return Reflect.get({ a: 3 }, 'a');"));
    try testing.expectEqual(@as(f64, 9), try evalNumber("var o = {}; Reflect.set(o, 'x', 9); return o.x;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return Reflect.has({ a: 1 }, 'a') ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 2), try evalNumber("return Reflect.ownKeys({ a: 1, b: 2 }).length;"));
    try testing.expectEqual(@as(f64, 7), try evalNumber(
        \\function add(a, b) { return a + b; }
        \\return Reflect.apply(add, null, [3, 4]);
    ));
    try testing.expectEqual(@as(f64, 5), try evalNumber(
        \\function Point(x) { this.x = x; }
        \\return Reflect.construct(Point, [5]).x;
    ));
}

test "Symbol" {
    try testing.expectEqual(@as(f64, 1), try evalNumber("return typeof Symbol() === 'symbol' ? 1 : 0;"));
    // Each Symbol is unique.
    try testing.expectEqual(@as(f64, 1), try evalNumber("return (Symbol('x') === Symbol('x')) ? 0 : 1;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("var s = Symbol('desc'); return s === s ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return Symbol('hi').toString() === 'Symbol(hi)' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return Symbol('hi').description === 'hi' ? 1 : 0;"));
    // Symbol.for registry.
    try testing.expectEqual(@as(f64, 1), try evalNumber("return (Symbol.for('k') === Symbol.for('k')) ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return Symbol.keyFor(Symbol.for('key')) === 'key' ? 1 : 0;"));
    // Well-known symbols exist.
    try testing.expectEqual(@as(f64, 1), try evalNumber("return typeof Symbol.iterator === 'symbol' ? 1 : 0;"));
}

test "Symbol-keyed properties" {
    // Symbol keys work and are distinct from string keys.
    try testing.expectEqual(@as(f64, 42), try evalNumber(
        \\var s = Symbol('k');
        \\var o = {};
        \\o[s] = 42;
        \\return o[s];
    ));
    // Symbol keys are excluded from Object.keys / for-in / JSON.
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var o = { a: 1 };
        \\o[Symbol('hidden')] = 99;
        \\return (Object.keys(o).length === 1 && Object.keys(o)[0] === 'a') ? 1 : 0;
    ));
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var o = { a: 1 };
        \\o[Symbol.iterator] = 5;
        \\return JSON.stringify(o) === '{"a":1}' ? 1 : 0;
    ));
    // Well-known symbols usable as keys, retrievable.
    try testing.expectEqual(@as(f64, 7), try evalNumber(
        \\var o = {};
        \\o[Symbol.iterator] = 7;
        \\return o[Symbol.iterator];
    ));
}

test "DataView" {
    // Big-endian (default) vs little-endian round-trip.
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var dv = new DataView(new ArrayBuffer(8));
        \\dv.setInt32(0, 305419896); // 0x12345678
        \\return dv.getInt32(0) === 305419896 ? 1 : 0;
    ));
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var dv = new DataView(new ArrayBuffer(8));
        \\dv.setInt32(0, 1, true); // little-endian
        \\return (dv.getUint8(0) === 1 && dv.getUint8(3) === 0) ? 1 : 0;
    ));
    // Endianness is observable byte-by-byte (big-endian default).
    try testing.expectEqual(@as(f64, 18), try evalNumber(
        \\var dv = new DataView(new ArrayBuffer(4));
        \\dv.setInt32(0, 305419896); // 0x12345678, big-endian
        \\return dv.getUint8(0); // 0x12 = 18
    ));
    // Float round-trip.
    try testing.expectEqual(@as(f64, 3.5), try evalNumber(
        \\var dv = new DataView(new ArrayBuffer(8));
        \\dv.setFloat64(0, 3.5);
        \\return dv.getFloat64(0);
    ));
    // Shares the underlying ArrayBuffer with a typed array.
    try testing.expectEqual(@as(f64, 255), try evalNumber(
        \\var buf = new ArrayBuffer(4);
        \\var u8 = new Uint8Array(buf);
        \\var dv = new DataView(buf);
        \\dv.setUint8(0, 255);
        \\return u8[0];
    ));
    try testing.expectEqual(@as(f64, 8), try evalNumber("return new DataView(new ArrayBuffer(8)).byteLength;"));
}

test "Date" {
    // 2021-06-15T12:30:45.123Z = 1623760245123 ms.
    try testing.expectEqual(@as(f64, 1623760245123), try evalNumber("return new Date(1623760245123).getTime();"));
    try testing.expectEqual(@as(f64, 2021), try evalNumber("return new Date(1623760245123).getFullYear();"));
    try testing.expectEqual(@as(f64, 5), try evalNumber("return new Date(1623760245123).getMonth();")); // June = 5
    try testing.expectEqual(@as(f64, 15), try evalNumber("return new Date(1623760245123).getDate();"));
    try testing.expectEqual(@as(f64, 12), try evalNumber("return new Date(1623760245123).getHours();"));
    try testing.expectEqual(@as(f64, 45), try evalNumber("return new Date(1623760245123).getSeconds();"));
    try testing.expectEqual(@as(f64, 2), try evalNumber("return new Date(1623760245123).getDay();")); // Tuesday
    try testing.expectEqual(@as(f64, 0), try evalNumber("return new Date(1970, 0, 1, 0, 0, 0, 0).getTime();"));
    try testing.expectEqual(@as(f64, 1623760245123), try evalNumber("return Date.UTC(2021, 5, 15, 12, 30, 45, 123);"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return new Date(1623760245123).toISOString() === '2021-06-15T12:30:45.123Z' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1623760245123), try evalNumber("return Date.parse('2021-06-15T12:30:45.123Z');"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return (typeof Date.now() === 'number' && Date.now() > 0) ? 1 : 0;"));
}

test "spread in array literals and calls" {
    try testing.expectEqual(@as(f64, 15), try evalNumber(
        \\var a = [1, 2, 3];
        \\var b = [0, ...a, 4, 5];
        \\return b[0] + b[1] + b[2] + b[3] + b[4] + b[5]; // 0+1+2+3+4+5
    ));
    try testing.expectEqual(@as(f64, 6), try evalNumber(
        \\function add(a, b, c) { return a + b + c; }
        \\var nums = [1, 2, 3];
        \\return add(...nums);
    ));
    try testing.expectEqual(@as(f64, 10), try evalNumber(
        \\function add4(a, b, c, d) { return a + b + c + d; }
        \\return add4(1, ...[2, 3], 4); // mixed spread + normal args
    ));
    // Spread a string into an array (per code unit).
    try testing.expectEqual(@as(f64, 3), try evalNumber("return [...'abc'].length;"));
    // Spread a Set.
    try testing.expectEqual(@as(f64, 3), try evalNumber("return [...new Set([1, 2, 2, 3])].length;"));
}

test "switch statements" {
    try testing.expectEqual(@as(f64, 20), try evalNumber(
        \\function f(n) {
        \\  switch (n) {
        \\    case 1: return 10;
        \\    case 2: return 20;
        \\    default: return 0;
        \\  }
        \\}
        \\return f(2);
    ));
    try testing.expectEqual(@as(f64, 99), try evalNumber(
        \\function f(n) { switch (n) { case 1: return 1; default: return 99; } }
        \\return f(7);
    ));
    // Fall-through until break.
    try testing.expectEqual(@as(f64, 3), try evalNumber(
        \\var x = 0;
        \\switch (1) { case 1: x += 1; case 2: x += 2; break; case 3: x += 100; }
        \\return x;
    ));
}

test "generators" {
    // Basic yielding, consumed by for-of.
    try testing.expectEqual(@as(f64, 6), try evalNumber(
        \\function* g() { yield 1; yield 2; yield 3; }
        \\var sum = 0;
        \\for (var x of g()) sum += x;
        \\return sum;
    ));
    // Manual next().
    try testing.expectEqual(@as(f64, 30), try evalNumber(
        \\function* g() { yield 10; yield 20; }
        \\var it = g();
        \\return it.next().value + it.next().value;
    ));
    // done flag.
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\function* g() { yield 1; }
        \\var it = g();
        \\it.next();
        \\return it.next().done ? 1 : 0;
    ));
    // Local state across yields (a loop inside the generator).
    try testing.expectEqual(@as(f64, 10), try evalNumber(
        \\function* range(n) { for (var i = 0; i < n; i++) yield i; }
        \\var s = 0;
        \\for (var x of range(5)) s += x;
        \\return s;
    ));
    // Sent value: `x = yield v` receives next()'s argument.
    try testing.expectEqual(@as(f64, 42), try evalNumber(
        \\function* g() { var x = yield 1; return x; }
        \\var it = g();
        \\it.next();
        \\return it.next(42).value;
    ));
    // return value becomes the final {value, done:true}.
    try testing.expectEqual(@as(f64, 99), try evalNumber(
        \\function* g() { yield 1; return 99; }
        \\var it = g();
        \\it.next();
        \\return it.next().value;
    ));
    // yield* delegation.
    try testing.expectEqual(@as(f64, 6), try evalNumber(
        \\function* inner() { yield 1; yield 2; }
        \\function* outer() { yield 0; yield* inner(); yield 3; }
        \\var s = 0;
        \\for (var x of outer()) s += x;
        \\return s;
    ));
    // Generators are spreadable.
    try testing.expectEqual(@as(f64, 3), try evalNumber(
        \\function* g() { yield 1; yield 2; yield 3; }
        \\return [...g()].length;
    ));
}

test "generators under GC stress" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    vm.heap.stress = true;
    const v = try eval(&vm,
        \\function* fib() {
        \\  var a = 0, b = 1;
        \\  while (true) { yield a; var t = a + b; a = b; b = t; }
        \\}
        \\var it = fib();
        \\var sum = 0;
        \\for (var i = 0; i < 10; i++) sum += it.next().value;
        \\return sum;
    );
    try testing.expectEqual(@as(f64, 88), v.asNumber()); // 0+1+1+2+3+5+8+13+21+34
}

test "iteration protocol" {
    // for-of over Set / Map / Array iterators.
    try testing.expectEqual(@as(f64, 6), try evalNumber("var s = 0; for (var x of new Set([1, 2, 3])) s += x; return s;"));
    try testing.expectEqual(@as(f64, 3), try evalNumber(
        \\var s = 0;
        \\for (var e of new Map([['a', 1], ['b', 2]])) s += e[1];
        \\return s;
    ));
    try testing.expectEqual(@as(f64, 30), try evalNumber("var s = 0; for (var v of [10, 20].values()) s += v; return s;"));
    try testing.expectEqual(@as(f64, 3), try evalNumber("var s = 0; for (var k of [0, 0, 0].keys()) s += 1; return s;"));
    try testing.expectEqual(@as(f64, 5), try evalNumber("var it = [5].entries().next(); return it.value[0] + it.value[1];"));
    // Manual iterator use.
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var it = [1, 2][Symbol.iterator]();
        \\var r = it.next();
        \\return (r.value === 1 && r.done === false) ? 1 : 0;
    ));
    // Custom iterable via a computed Symbol.iterator key.
    try testing.expectEqual(@as(f64, 3), try evalNumber(
        \\var obj = {};
        \\obj[Symbol.iterator] = function () {
        \\  var i = 0;
        \\  return { next: function () { return i < 3 ? { value: i++, done: false } : { value: undefined, done: true }; } };
        \\};
        \\var s = 0;
        \\for (var x of obj) s += x;
        \\return s;
    ));
}

test "for-of over arrays and strings" {
    try testing.expectEqual(@as(f64, 6), try evalNumber("var s = 0; for (var x of [1, 2, 3]) s += x; return s;"));
    try testing.expectEqual(@as(f64, 30), try evalNumber("var s = 0; for (const x of [10, 20]) s += x; return s;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var out = "";
        \\for (var c of "abc") { out = out + c; }
        \\return out === "abc" ? 1 : 0;
    ));
    try testing.expectEqual(@as(f64, 3), try evalNumber(
        \\var s = 0;
        \\for (var x of [1, 2, 3, 4]) { if (x === 3) break; s += x; }
        \\return s;
    ));
    try testing.expectEqual(@as(f64, 4), try evalNumber(
        \\var s = 0;
        \\for (var x of [1, 2, 3]) { if (x === 2) continue; s += x; }
        \\return s;
    ));
}

test "number methods" {
    try testing.expectEqual(@as(f64, 1), try evalNumber("return (255).toString(16) === 'ff' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return (3.14159).toFixed(2) === '3.14' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return Number.isInteger(5) && !Number.isInteger(5.5) ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return (10).toString(2) === '1010' ? 1 : 0;"));
}

test "arrays under GC stress" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    vm.heap.stress = true;
    const v = try eval(&vm,
        \\var a = [];
        \\for (var i = 0; i < 20; i++) { a.push(i); }
        \\var b = a.map(function (x) { return x + 1; });
        \\return b[19] + a.length;
    );
    try testing.expectEqual(@as(f64, 40), v.asNumber()); // 20 + 20
}

test "objects under GC stress" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    vm.heap.stress = true;
    const v = try eval(&vm,
        \\function Node(v) { this.v = v; this.next = null; }
        \\var head = new Node(1);
        \\head.next = new Node(2);
        \\head.next.next = new Node(3);
        \\return head.v + head.next.v + head.next.next.v;
    );
    try testing.expectEqual(@as(f64, 6), v.asNumber());
}

test "finally runs on abrupt completions" {
    // throw path: finally observed, exception still propagates to catch.
    try std.testing.expectEqual(@as(f64, 12), try evalNumber(
        \\var log = 0;
        \\try {
        \\  try { throw 1; } finally { log += 10; }
        \\} catch (e) { log += e * 2; }
        \\return log;
    ));
    // return path: finally runs before the function returns.
    try std.testing.expectEqual(@as(f64, 7), try evalNumber(
        \\var side = 0;
        \\function f() { try { return 7; } finally { side = 1; } }
        \\var r = f();
        \\return side === 1 ? r : -1;
    ));
    // break path.
    try std.testing.expectEqual(@as(f64, 5), try evalNumber(
        \\var n = 0;
        \\for (var i = 0; i < 3; i++) {
        \\  try { if (i === 1) break; } finally { n += 2; }
        \\  n += 1;
        \\}
        \\return n; // i=0: fin+body=3, i=1: fin then break=2 -> 5
    ));
    // continue path + nested finallys ordering (inner before outer).
    try std.testing.expectEqual(@as(f64, 21), try evalNumber(
        \\var order = 0;
        \\function g() {
        \\  try {
        \\    try { return 0; } finally { order = order * 10 + 1; }
        \\  } finally { order = order * 10 + 2; }
        \\}
        \\g();
        \\return order + 9; // 12 + 9
    ));
    // finally overrides the completion: its return wins over the throw.
    try std.testing.expectEqual(@as(f64, 42), try evalNumber(
        \\function h() { try { throw "boom"; } finally { return 42; } }
        \\return h();
    ));
}

test "let/const temporal dead zone" {
    // Use before declaration in the same block throws ReferenceError.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\try { x; let x = 1; return 0; }
        \\catch (e) { return (e instanceof ReferenceError) ? 1 : 2; }
    ));
    // Assignment before declaration also throws.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\try { y = 5; let y; return 0; }
        \\catch (e) { return (e instanceof ReferenceError) ? 1 : 2; }
    ));
    // After initialization everything works; `let x;` initializes to undefined.
    try std.testing.expectEqual(@as(f64, 3), try evalNumber(
        \\let a = 3;
        \\{ let b; if (b === undefined) { b = a; } return b; }
    ));
}

test "ToNumber non-decimal numeric strings" {
    try std.testing.expectEqual(@as(f64, 16), try evalNumber("return Number('0x10');"));
    try std.testing.expectEqual(@as(f64, 255), try evalNumber("return Number('0xFF');"));
    try std.testing.expectEqual(@as(f64, 15), try evalNumber("return Number('0o17');"));
    try std.testing.expectEqual(@as(f64, 5), try evalNumber("return Number('0b101');"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return isNaN(Number('0xZZ')) ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return isNaN(Number('-0x10')) ? 1 : 0;")); // sign not allowed
}

test "defineProperty enforces non-configurable invariants" {
    // Redefining configurable:false -> true throws.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var o = {};
        \\Object.defineProperty(o, "p", { value: 1 });
        \\try { Object.defineProperty(o, "p", { configurable: true }); return 0; }
        \\catch (e) { return (e instanceof TypeError) ? 1 : 2; }
    ));
    // Changing the value of a non-configurable, non-writable property throws.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var o = {};
        \\Object.defineProperty(o, "p", { value: 1 });
        \\try { Object.defineProperty(o, "p", { value: 2 }); return 0; }
        \\catch (e) { return (e instanceof TypeError) ? 1 : 2; }
    ));
    // Same value is allowed; partial descriptors merge instead of resetting.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var o = {};
        \\Object.defineProperty(o, "p", { value: 9, enumerable: true });
        \\Object.defineProperty(o, "p", { value: 9 });
        \\var d = Object.getOwnPropertyDescriptor(o, "p");
        \\return (d.value === 9 && d.enumerable === true) ? 1 : 0;
    ));
    // New properties on a non-extensible object throw.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var o = Object.preventExtensions({});
        \\try { Object.defineProperty(o, "q", { value: 1 }); return 0; }
        \\catch (e) { return (e instanceof TypeError) ? 1 : 2; }
    ));
}

test "Object statics batch" {
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var proto = { greet: function () { return 1; } };
        \\var o = {};
        \\Object.setPrototypeOf(o, proto);
        \\return o.greet();
    ));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var o = {};
        \\try { Object.setPrototypeOf(o, o); return 0; }
        \\catch (e) { return (e instanceof TypeError) ? 1 : 2; }
    ));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("var p = {}; var o = Object.create(p); return o.__proto__ === p ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 6), try evalNumber(
        \\var t = Object.assign({ a: 1 }, { b: 2 }, { c: 3 });
        \\return t.a + t.b + t.c;
    ));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return Object.is(NaN, NaN) && !Object.is(0, -0) && Object.is(1, 1) ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return Object.hasOwn({ x: 1 }, 'x') && !Object.hasOwn({}, 'x') ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 3), try evalNumber("return Object.fromEntries([['a', 1], ['b', 2]]).a + 2;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var ds = Object.getOwnPropertyDescriptors({ p: 5 });
        \\return (ds.p.value === 5 && ds.p.writable === true) ? 1 : 0;
    ));
}

test "Array method tail" {
    try std.testing.expectEqual(@as(f64, 3), try evalNumber("return [1,2,3].at(-1);"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("var a=[1,2,3]; return a.shift() === 1 && a.length === 2 && a[0] === 2 ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("var a=[3]; a.unshift(1,2); return (a.join(',')==='1,2,3') ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return [1,2,3].reverse().join(',') === '3,2,1' ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return [1,2,3,4].fill(0,1,3).join(',') === '1,0,0,4' ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 3), try evalNumber("return [1,2,1,2].lastIndexOf(2);"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return [1,2,3].some(function(x){return x>2;}) && ![1,2].some(function(x){return x>2;}) ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return [2,4].every(function(x){return x%2===0;}) ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 4), try evalNumber("return [1,4,9].find(function(x){return x>3;});"));
    try std.testing.expectEqual(@as(f64, 2), try evalNumber("return [1,4,9].findLastIndex(function(x){return x>3;});"));
    try std.testing.expectEqual(@as(f64, 10), try evalNumber("return [1,2,3,4].reduce(function(a,b){return a+b;});"));
    try std.testing.expectEqual(@as(f64, 20), try evalNumber("return [1,2,3,4].reduceRight(function(a,b){return a+b;}, 10);"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var a = [1,2,3,4,5];
        \\var removed = a.splice(1, 2, "x");
        \\return (a.join(',') === '1,x,4,5' && removed.join(',') === '2,3') ? 1 : 0;
    ));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return [3,1,2].sort().join(',') === '1,2,3' ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return [10,9,1].sort().join(',') === '1,10,9' ? 1 : 0;")); // default = string order
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return [10,9,1].sort(function(a,b){return a-b;}).join(',') === '1,9,10' ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return [1,2,3,4,5].copyWithin(0,3).join(',') === '4,5,3,4,5' ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return [1,[2,[3]]].flat().length === 3 ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return [1,[2,[3]]].flat(2).join(',') === '1,2,3' ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return [1,2].flatMap(function(x){return [x, x*10];}).join(',') === '1,10,2,20' ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return Array.of(1,2,3).join(',') === '1,2,3' ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return Array.from('abc').join(',') === 'a,b,c' ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return Array.from([1,2], function(x){return x*2;}).join(',') === '2,4' ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return Array.from({length: 2, 0: 'a', 1: 'b'}).join(',') === 'a,b' ? 1 : 0;"));
}

test "String method tail" {
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return 'abc'.at(-1) === 'c' ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return '5'.padStart(3, '0') === '005' ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return 'ab'.padEnd(5, 'xy') === 'abxyx' ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 97), try evalNumber("return 'abc'.codePointAt(0);"));
    try std.testing.expectEqual(@as(f64, 128512), try evalNumber("return '😀'.codePointAt(0);"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return String.fromCodePoint(128512).codePointAt(0) === 128512 ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return 'abcdef'.substr(1, 3) === 'bcd' ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return '  hi  '.trimStart() === 'hi  ' && '  hi  '.trimEnd() === '  hi' ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return 'a-b-c'.replaceAll('-', '+') === 'a+b+c' ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return 'a1b2'.replaceAll(/\\d/g, '#') === 'a#b#' ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\try { 'x'.replaceAll(/x/, 'y'); return 0; }
        \\catch (e) { return (e instanceof TypeError) ? 1 : 2; }
    ));
}

test "well-known symbol dispatch" {
    // @@toPrimitive controls coercion, with the hint.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var o = {};
        \\o[Symbol.toPrimitive] = function (hint) {
        \\  return hint === "number" ? 42 : "str";
        \\};
        \\return (+o === 42 && ("" + o) !== "42") ? 1 : 0;
    ));
    // String hint flows through template-ish concatenation via toStringVal.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var o = { toString: function () { return "T"; }, valueOf: function () { return 9; } };
        \\return (String(o) === "T" && o * 1 === 9) ? 1 : 0;
    ));
    // @@toStringTag changes Object.prototype.toString.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var o = {};
        \\o[Symbol.toStringTag] = "Custom";
        \\return Object.prototype.toString.call(o) === "[object Custom]" ? 1 : 0;
    ));
    // Builtin tags.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var t = Object.prototype.toString;
        \\return (t.call([]) === "[object Array]" && t.call(t) === "[object Function]" &&
        \\        t.call("s") === "[object String]" && t.call(5) === "[object Number]") ? 1 : 0;
    ));
    // @@hasInstance overrides instanceof.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var Even = {};
        \\Even[Symbol.hasInstance] = function (v) { return v % 2 === 0; };
        \\return (4 instanceof Even) && !(3 instanceof Even) ? 1 : 0;
    ));
}

test "destructuring: declarations" {
    try std.testing.expectEqual(@as(f64, 3), try evalNumber("var [a, b] = [1, 2]; return a + b;"));
    try std.testing.expectEqual(@as(f64, 3), try evalNumber("let [x, , z] = [1, 9, 2]; return x + z;"));
    try std.testing.expectEqual(@as(f64, 7), try evalNumber("const { p, q } = { p: 3, q: 4 }; return p + q;"));
    try std.testing.expectEqual(@as(f64, 5), try evalNumber("var { a: renamed } = { a: 5 }; return renamed;"));
    try std.testing.expectEqual(@as(f64, 9), try evalNumber("var { missing = 9 } = {}; return missing;"));
    try std.testing.expectEqual(@as(f64, 6), try evalNumber("var [h = 6] = []; return h;"));
    // Nested.
    try std.testing.expectEqual(@as(f64, 12), try evalNumber(
        \\var { a: [x, y], b: { c } } = { a: [3, 4], b: { c: 5 } };
        \\return x + y + c;
    ));
    // Array rest.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var [first, ...rest] = [1, 2, 3, 4];
        \\return (first === 1 && rest.length === 3 && rest[2] === 4) ? 1 : 0;
    ));
    // Strings destructure via the iterator protocol.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("var [c1, c2] = 'hi'; return (c1 === 'h' && c2 === 'i') ? 1 : 0;"));
}

test "destructuring: params, assignment, for-of, catch" {
    try std.testing.expectEqual(@as(f64, 7), try evalNumber(
        \\function f([a, b], { c }) { return a + b + c; }
        \\return f([1, 2], { c: 4 });
    ));
    // Pattern param with a whole-pattern default.
    try std.testing.expectEqual(@as(f64, 3), try evalNumber(
        \\function g({ n } = { n: 3 }) { return n; }
        \\return g();
    ));
    // Assignment-expression destructuring (existing bindings + member targets).
    try std.testing.expectEqual(@as(f64, 12), try evalNumber(
        \\var a, b; var o = {};
        \\[a, b] = [4, 8];
        \\({ x: o.stored } = { x: 100 });
        \\return a + b;
    ));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var swap_a = 1, swap_b = 2;
        \\[swap_a, swap_b] = [swap_b, swap_a];
        \\return (swap_a === 2 && swap_b === 1) ? 1 : 0;
    ));
    // for-of head patterns.
    try std.testing.expectEqual(@as(f64, 21), try evalNumber(
        \\var total = 0;
        \\for (const [k, v] of [[1, 2], [3, 4], [5, 6]]) { total += k + v; }
        \\return total;
    ));
    // catch parameter pattern.
    try std.testing.expectEqual(@as(f64, 42), try evalNumber(
        \\try { throw { code: 42 }; }
        \\catch ({ code }) { return code; }
    ));
}

test "strict mode semantics" {
    // Assignment to an undeclared global throws in strict mode…
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\"use strict";
        \\try { undeclared_target = 1; return 0; }
        \\catch (e) { return (e instanceof ReferenceError) ? 1 : 2; }
    ));
    // …and still works (creates the global) in sloppy mode.
    try std.testing.expectEqual(@as(f64, 5), try evalNumber("sloppy_target = 5; return sloppy_target;"));
    // Writing a read-only property throws in strict mode only.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\"use strict";
        \\var o = Object.freeze({ p: 1 });
        \\try { o.p = 2; return 0; }
        \\catch (e) { return (e instanceof TypeError) ? 1 : 2; }
    ));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var o = Object.freeze({ p: 1 });
        \\o.p = 2; // sloppy: silently ignored
        \\return o.p;
    ));
    // delete of a non-configurable property throws in strict mode.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\"use strict";
        \\var o = {};
        \\Object.defineProperty(o, "p", { value: 1 });
        \\try { delete o.p; return 0; }
        \\catch (e) { return (e instanceof TypeError) ? 1 : 2; }
    ));
    // Strict `this` is not coerced; sloppy nullish `this` becomes globalThis.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\function strictThis() { "use strict"; return this === undefined; }
        \\function sloppyThis() { return this === globalThis; }
        \\return (strictThis() && sloppyThis()) ? 1 : 0;
    ));
    // Strictness is inherited by nested functions.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\"use strict";
        \\function outer() { function inner() { return this === undefined; } return inner(); }
        \\return outer() ? 1 : 0;
    ));
}
