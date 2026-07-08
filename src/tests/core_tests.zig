//! End-to-end VM tests: core language (control flow, functions, errors,
//! generators, iteration, TDZ). Run with `zig build test-core`.

const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");
const eval = helpers.eval;
const evalNumber = helpers.evalNumber;
const Vm = helpers.Vm;
const Value = helpers.Value;
const toBoolean = helpers.toBoolean;
const utf16ToUtf8Alloc = helpers.utf16ToUtf8Alloc;

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
    var vm = Vm.init(helpers.gpa);
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
    var vm = Vm.init(helpers.gpa);
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
    var vm = Vm.init(helpers.gpa);
    defer vm.deinit();
    const r = eval(&vm, "throw 99;");
    try testing.expectError(error.JsThrow, r);
    try testing.expect(vm.pending_exception.?.isNumber());
    try testing.expectEqual(@as(f64, 99), vm.pending_exception.?.asNumber());
}

test "calling a non-function throws" {
    var vm = Vm.init(helpers.gpa);
    defer vm.deinit();
    const r = eval(&vm, "var x = 5; return x();");
    try testing.expectError(error.JsThrow, r);
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
        var vm = Vm.init(helpers.gpa);
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
        var vm = Vm.init(helpers.gpa);
        defer vm.deinit();
        try testing.expectError(error.JsThrow, eval(&vm, "return new Math.abs(1);"));
    }
}

test "object toString coercion in concatenation" {
    var vm = Vm.init(helpers.gpa);
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
    var vm = Vm.init(helpers.gpa);
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
    var vm = Vm.init(helpers.gpa);
    defer vm.deinit();
    const v = try eval(&vm, "return new Error('nope').toString();");
    try testing.expect(v.isString());
    try testing.expectEqualSlices(u16, &[_]u16{ 'E', 'r', 'r', 'o', 'r', ':', ' ', 'n', 'o', 'p', 'e' }, v.asString().units);
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
