//! End-to-end VM tests: newer language features (destructuring, strict mode,
//! templates, classes, mapped arguments). Run with `zig build test-lang`.

const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");
const eval = helpers.eval;
const evalNumber = helpers.evalNumber;
const Vm = helpers.Vm;
const Value = helpers.Value;
const toBoolean = helpers.toBoolean;
const utf16ToUtf8Alloc = helpers.utf16ToUtf8Alloc;

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

test "template literals" {
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("var n = 7; return `n is ${n}!` === 'n is 7!' ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return `${1}${2}` === '12' ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return `a${'b'}c${'d'}e` === 'abcde' ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return `line\\n` === 'line\\n' ? 1 : 0;")); // escapes cook
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return `${`in${'ner'}`}!` === 'inner!' ? 1 : 0;")); // nesting
    // Tagged: strings, raw, and substitutions all arrive.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\function tag(strings, a, b) {
        \\  return (strings[0] === "x" && strings[1] === "y" && strings[2] === "z" &&
        \\          strings.raw[1] === "y" && a === 1 && b === 2) ? 1 : 0;
        \\}
        \\return tag`x${1}y${2}z`;
    ));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\function raw(strings) { return strings.raw[0] === "a\\nb" ? 1 : 0; }
        \\return raw`a\nb`; // raw keeps the backslash-n as two characters
    ));
}

test "classes: methods, static, accessors, extends, super" {
    try std.testing.expectEqual(@as(f64, 25), try evalNumber(
        \\class Point {
        \\  constructor(x, y) { this.x = x; this.y = y; }
        \\  sum() { return this.x + this.y; }
        \\}
        \\var p = new Point(10, 15);
        \\return p.sum();
    ));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\class A {}
        \\var a = new A();
        \\return (a instanceof A && typeof A === "function") ? 1 : 0;
    ));
    try std.testing.expectEqual(@as(f64, 99), try evalNumber(
        \\class Util { static answer() { return 99; } }
        \\return Util.answer();
    ));
    try std.testing.expectEqual(@as(f64, 8), try evalNumber(
        \\class Box {
        \\  constructor(v) { this._v = v; }
        \\  get value() { return this._v; }
        \\  set value(v) { this._v = v * 2; }
        \\}
        \\var b = new Box(1);
        \\b.value = 4;
        \\return b.value;
    ));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\class Animal {
        \\  constructor(name) { this.name = name; }
        \\  speak() { return this.name + " makes a sound"; }
        \\}
        \\class Dog extends Animal {
        \\  constructor(name) { super(name); this.kind = "dog"; }
        \\  speak() { return super.speak() + ", woof"; }
        \\}
        \\var d = new Dog("Rex");
        \\return (d.speak() === "Rex makes a sound, woof" &&
        \\        d instanceof Dog && d instanceof Animal && d.kind === "dog") ? 1 : 0;
    ));
    // Class expressions work too.
    try std.testing.expectEqual(@as(f64, 5), try evalNumber(
        \\var C = class { five() { return 5; } };
        \\return new C().five();
    ));
    // Class bodies are strict.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\class S { m() { return this; } }
        \\var m = new S().m;
        \\return m() === undefined ? 1 : 0;
    ));
}

test "object rest destructuring" {
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var { a, ...rest } = { a: 1, b: 2, c: 3 };
        \\return (a === 1 && rest.a === undefined && rest.b === 2 && rest.c === 3 &&
        \\        Object.keys(rest).length === 2) ? 1 : 0;
    ));
    // Rest alone copies everything.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var { ...all } = { x: 1, y: 2 };
        \\return (all.x === 1 && all.y === 2) ? 1 : 0;
    ));
    // Computed keys are excluded at run time.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var k = "skip";
        \\var { [k]: v, ...others } = { skip: 9, keep: 10 };
        \\return (v === 9 && others.skip === undefined && others.keep === 10) ? 1 : 0;
    ));
    // Rest in parameters and assignment position.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\function f({ first, ...more }) { return first + more.second; }
        \\var out;
        \\({ ...out } = { z: 5 });
        \\return (f({ first: 1, second: 2 }) === 3 && out.z === 5) ? 1 : 0;
    ));
    // Getters are invoked; rest is a fresh plain object.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var src = { plain: 1, get computed() { return 2; } };
        \\var { ...r } = src;
        \\return (r.computed === 2 && r !== src) ? 1 : 0;
    ));
    // null/undefined sources throw.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\try { var { ...r } = null; return 0; }
        \\catch (e) { return (e instanceof TypeError) ? 1 : 2; }
    ));
}

test "object literal spread and accessors" {
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var base = { a: 1, b: 2 };
        \\var o = { ...base, b: 3, ...null, ...undefined };
        \\return (o.a === 1 && o.b === 3 && Object.keys(o).length === 2) ? 1 : 0;
    ));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var o = {
        \\  _v: 2,
        \\  get v() { return this._v; },
        \\  set v(x) { this._v = x * 10; },
        \\};
        \\o.v = 3;
        \\return (o.v === 30 && Object.keys(o).indexOf("v") >= 0) ? 1 : 0;
    ));
}

test "class fields" {
    // Instance fields: defaults, initializers, this-references, declaration order.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\class P {
        \\  x = 1;
        \\  y;
        \\  z = this.x + 1;
        \\  constructor(n) { this.total = this.x + this.z + n; }
        \\}
        \\var p = new P(10);
        \\return (p.x === 1 && p.y === undefined && p.z === 2 && p.total === 13) ? 1 : 0;
    ));
    // Fields work with the default constructor and with extends.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\class A { tag = "a"; }
        \\class B extends A { own = 5; constructor() { super(); } }
        \\var b = new B();
        \\return (b.own === 5 && b.tag === "a") ? 1 : 0;
    ));
    // Static fields: value, this = constructor, undefined default.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\class C {
        \\  static count = 3;
        \\  static double = this.count * 2;
        \\  static blank;
        \\}
        \\return (C.count === 3 && C.double === 6 && C.blank === undefined &&
        \\        Object.hasOwn(C, "blank")) ? 1 : 0;
    ));
    // Computed field names.
    try std.testing.expectEqual(@as(f64, 7), try evalNumber(
        \\var k = "dyn";
        \\class D { [k] = 7; }
        \\return new D().dyn;
    ));
    // Field initializers are per-instance (fresh objects each construction).
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\class E { list = []; }
        \\var e1 = new E(), e2 = new E();
        \\e1.list.push(1);
        \\return (e1.list.length === 1 && e2.list.length === 0) ? 1 : 0;
    ));
}

test "mapped arguments" {
    // arguments[i] <-> parameter aliasing, both directions (sloppy mode).
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\function f(x, y) {
        \\  x = 10;
        \\  arguments[1] = 20;
        \\  return (arguments[0] === 10 && y === 20) ? 1 : 0;
        \\}
        \\return f(1, 2);
    ));
    // Unpassed params are not mapped; length reflects the call.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\function g(a, b) {
        \\  b = 7;
        \\  return (arguments.length === 1 && arguments[1] === undefined) ? 1 : 0;
        \\}
        \\return g(1);
    ));
    // Strict functions are unmapped.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\function s(x) { "use strict"; x = 9; return arguments[0]; }
        \\return s(1) === 1 ? 1 : 0;
    ));
    // Non-simple parameter lists are unmapped.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\function d(x = 0) { x = 9; return arguments[0]; }
        \\return d(1) === 1 ? 1 : 0;
    ));
    // delete severs the alias.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\function h(x) {
        \\  delete arguments[0];
        \\  arguments[0] = 99;
        \\  return (x === 1 && arguments[0] === 99) ? 1 : 0;
        \\}
        \\return h(1);
    ));
    // defineProperty with writable:false unmaps (after writing through).
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\function k(x) {
        \\  Object.defineProperty(arguments, "0", { value: 5, writable: false });
        \\  var frozen_saw = x; // write-through happened before severing
        \\  x = 6;              // no longer aliased
        \\  return (frozen_saw === 5 && arguments[0] === 5) ? 1 : 0;
        \\}
        \\return k(1);
    ));
}

test "BigInt" {
    // Literals, typeof, arithmetic beyond 2^53.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return typeof 1n === \"bigint\" ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return (9007199254740993n + 1n) === 9007199254740994n ? 1 : 0;"));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber("return (2n ** 64n).toString() === \"18446744073709551616\" ? 1 : 0;"));
    // Mixed arithmetic throws; comparisons and loose equality do not.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var threw = false;
        \\try { 1n + 1; } catch (e) { threw = e instanceof TypeError; }
        \\return (threw && 1n == 1 && 1n === 1n && !(1n === 1) && 2n > 1 && 1n < 2) ? 1 : 0;
    ));
    // Division truncates; modulo; division by zero throws RangeError.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var threw = false;
        \\try { 1n / 0n; } catch (e) { threw = e instanceof RangeError; }
        \\return (7n / 2n === 3n && -7n / 2n === -3n && 7n % 2n === 1n && threw) ? 1 : 0;
    ));
    // Bitwise, shifts, negate, bit-not.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\return ((12n & 10n) === 8n && (12n | 3n) === 15n && (12n ^ 10n) === 6n &&
        \\        (1n << 100n) === 1267650600228229401496703205376n &&
        \\        (256n >> 4n) === 16n && -5n === -(5n) && ~5n === -6n) ? 1 : 0;
    ));
    // BigInt() conversions.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var bad = false;
        \\try { BigInt(1.5); } catch (e) { bad = e instanceof RangeError; }
        \\return (BigInt(42) === 42n && BigInt("0x10") === 16n && BigInt("  7  ") === 7n &&
        \\        BigInt(true) === 1n && bad) ? 1 : 0;
    ));
    // toString radix, String(), asIntN/asUintN.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\return ((255n).toString(16) === "ff" && String(-10n) === "-10" &&
        \\        BigInt.asIntN(8, 255n) === -1n && BigInt.asUintN(8, 257n) === 1n &&
        \\        BigInt.asIntN(8, -129n) === 127n) ? 1 : 0;
    ));
    // Booleans, JSON, Number() explicit conversion.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var jthrew = false;
        \\try { JSON.stringify({ x: 1n }); } catch (e) { jthrew = e instanceof TypeError; }
        \\return ((0n ? 1 : 0) === 0 && (1n ? 1 : 0) === 1 && Number(5n) === 5 && jthrew) ? 1 : 0;
    ));
}

test "WeakMap / WeakSet / WeakRef basics" {
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var wm = new WeakMap();
        \\var k1 = {}, k2 = {};
        \\wm.set(k1, "one").set(k2, 2);
        \\var deleted = wm.delete(k2);
        \\return (wm.get(k1) === "one" && wm.has(k1) && deleted && !wm.has(k2) &&
        \\        wm.get(k2) === undefined && !wm.has("prim")) ? 1 : 0;
    ));
    // Non-object keys throw on insert.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var wm = new WeakMap();
        \\try { wm.set(1, "x"); return 0; }
        \\catch (e) { return (e instanceof TypeError) ? 1 : 2; }
    ));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var ws = new WeakSet();
        \\var o = {};
        \\ws.add(o);
        \\var had = ws.has(o);
        \\ws.delete(o);
        \\return (had && !ws.has(o)) ? 1 : 0;
    ));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var target = { alive: true };
        \\var ref = new WeakRef(target);
        \\return (ref.deref() === target) ? 1 : 0;
    ));
}

test "Proxy traps and invariants" {
    // deleteProperty, getPrototypeOf, setPrototypeOf, ownKeys, defineProperty,
    // getOwnPropertyDescriptor, isExtensible/preventExtensions traps.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var deleted = [];
        \\var p = new Proxy({ a: 1, b: 2 }, {
        \\  deleteProperty: function (t, k) { deleted.push(k); delete t[k]; return true; },
        \\  ownKeys: function (t) { return ["x", "y"]; },
        \\});
        \\delete p.a;
        \\var keys = Object.keys(p);
        \\return (deleted[0] === "a" && keys.length === 2 && keys[0] === "x" && keys[1] === "y") ? 1 : 0;
    ));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var fakeProto = { marker: true };
        \\var p = new Proxy({}, { getPrototypeOf: function () { return fakeProto; } });
        \\return Object.getPrototypeOf(p) === fakeProto ? 1 : 0;
    ));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var defined = null;
        \\var p = new Proxy({}, {
        \\  defineProperty: function (t, k, d) { defined = k; Object.defineProperty(t, k, d); return true; },
        \\  getOwnPropertyDescriptor: function (t, k) { return { value: 99, writable: true, enumerable: true, configurable: true }; },
        \\});
        \\Object.defineProperty(p, "q", { value: 5 });
        \\var d = Object.getOwnPropertyDescriptor(p, "anything");
        \\return (defined === "q" && d.value === 99) ? 1 : 0;
    ));
    // get invariant: non-configurable non-writable target prop pins the value.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var t = {};
        \\Object.defineProperty(t, "locked", { value: 1 });
        \\var p = new Proxy(t, { get: function () { return 2; } });
        \\try { p.locked; return 0; }
        \\catch (e) { return (e instanceof TypeError) ? 1 : 2; }
    ));
    // has invariant: cannot hide a non-configurable own property.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var t = {};
        \\Object.defineProperty(t, "hidden", { value: 1 });
        \\var p = new Proxy(t, { has: function () { return false; } });
        \\try { "hidden" in p; return 0; }
        \\catch (e) { return (e instanceof TypeError) ? 1 : 2; }
    ));
    // set trap refusal throws in strict mode.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\"use strict";
        \\var p = new Proxy({}, { set: function () { return false; } });
        \\try { p.x = 1; return 0; }
        \\catch (e) { return (e instanceof TypeError) ? 1 : 2; }
    ));
    // isExtensible must agree with the target.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var p = new Proxy({}, { isExtensible: function () { return false; } });
        \\try { Object.isExtensible(p); return 0; }
        \\catch (e) { return (e instanceof TypeError) ? 1 : 2; }
    ));
}

test "Proxy.revocable" {
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var r = Proxy.revocable({ v: 7 }, {});
        \\var before = r.proxy.v;
        \\r.revoke();
        \\try { r.proxy.v; return 0; }
        \\catch (e) { return (before === 7 && e instanceof TypeError) ? 1 : 2; }
    ));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var r = Proxy.revocable({}, {});
        \\r.revoke();
        \\r.revoke(); // idempotent
        \\try { "x" in r.proxy; return 0; }
        \\catch (e) { return (e instanceof TypeError) ? 1 : 2; }
    ));
}

test "$262 host object" {
    var vm = helpers.Vm.init(helpers.gpa);
    defer vm.deinit();
    try vm.installHost262();
    // Note: `var` inside evalScript stays in the eval program's env (known
    // indirect-eval scoping gap), so the script communicates via an implicit
    // global assignment.
    const v = try eval(&vm,
        \\var g = $262.global;
        \\$262.evalScript("fromEval = 41;");
        \\$262.gc();
        \\return (g === globalThis && fromEval === 41 && typeof $262.detachArrayBuffer === "function") ? 1 : 0;
    );
    try std.testing.expectEqual(@as(f64, 1), v.asNumber());
}

test "private class members" {
    // Instance fields (with and without initializer), read/write, methods.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\class Counter {
        \\  #count = 0;
        \\  #step;
        \\  constructor(s) { this.#step = s; }
        \\  inc() { this.#count += this.#step; return this.#count; }
        \\  get value() { return this.#count; }
        \\}
        \\var c = new Counter(5);
        \\return (c.inc() === 5 && c.inc() === 10 && c.value === 10) ? 1 : 0;
    ));
    // Private methods, and calling one from another.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\class A {
        \\  #secret() { return 42; }
        \\  reveal() { return this.#secret(); }
        \\}
        \\return new A().reveal() === 42 ? 1 : 0;
    ));
    // Private accessors.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\class Box {
        \\  #v = 0;
        \\  get #inner() { return this.#v; }
        \\  set #inner(x) { this.#v = x * 2; }
        \\  run() { this.#inner = 5; return this.#inner; }
        \\}
        \\return new Box().run() === 10 ? 1 : 0;
    ));
    // Static private field + method + update.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\class Reg {
        \\  static #n = 0;
        \\  constructor() { Reg.#n++; }
        \\  static count() { return Reg.#n; }
        \\}
        \\new Reg(); new Reg(); new Reg();
        \\return Reg.count() === 3 ? 1 : 0;
    ));
    // Brand check `#x in obj`.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\class C {
        \\  #brand = 1;
        \\  static has(o) { return #brand in o; }
        \\}
        \\return (C.has(new C()) && !C.has({}) && !C.has(null === null ? {} : 0)) ? 1 : 0;
    ));
    // Accessing a private member an object never received throws TypeError.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\class C {
        \\  #x = 1;
        \\  static read(o) { return o.#x; }
        \\}
        \\try { C.read({}); return 0; }
        \\catch (e) { return (e instanceof TypeError) ? 1 : 2; }
    ));
    // Writing to a private method throws.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\class C {
        \\  #m() {}
        \\  static clobber(o) { o.#m = 1; }
        \\  static run() { try { C.clobber(new C()); return 0; } catch (e) { return (e instanceof TypeError) ? 1 : 2; } }
        \\}
        \\return C.run();
    ));
    // Two classes with the same private name don't collide.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\class A { #x = "a"; getA() { return this.#x; } }
        \\class B { #x = "b"; getB() { return this.#x; } static hasA(o) { return #x in o; } }
        \\var a = new A(), b = new B();
        \\return (a.getA() === "a" && b.getB() === "b" && B.hasA(b) && !B.hasA(a)) ? 1 : 0;
    ));
    // Private members are invisible to enumeration and normal access.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\class C { #hidden = 1; pub = 2; }
        \\var c = new C();
        \\return (Object.keys(c).length === 1 && Object.keys(c)[0] === "pub" && c["#hidden"] === undefined) ? 1 : 0;
    ));
    // Private field in derived class alongside super().
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\class Base { constructor() { this.base = 1; } }
        \\class Sub extends Base { #own = 2; constructor() { super(); } total() { return this.base + this.#own; } }
        \\return new Sub().total() === 3 ? 1 : 0;
    ));
}

test "early errors: delete private and field-init super/arguments" {
    const parser = @import("bottlebrush").parser;
    const bad = [_][]const u8{
        "class C { #x; m() { delete this.#x; } }",
        "class C { #x; m() { delete (this.#x); } }",
        "class C { x = arguments; }",
        "class C { x = super(); }",
        "class C { x = () => arguments; }",
        "class C { x = y ? arguments : 0; }",
        "class C { #x; #x; }",
        "class C { #x(){} #x(){} }",
        "class C { get #x(){} get #x(){} }",
        "var s = `\\x0`;",
        "var s = `\\u{110000}`;",
        "var s = `\\7`;",
    };
    for (bad) |src| {
        var pr = try parser.parse(testing.allocator, src, .script);
        switch (pr) {
            .syntax_error => {},
            .ok => |*a| {
                a.deinit();
                std.debug.print("expected SyntaxError for: {s}\n", .{src});
                return error.ExpectedSyntaxError;
            },
        }
    }
    // These are legal and must still parse.
    const ok = [_][]const u8{
        "class C { x = 1; m() { return arguments; } }",
        "class C { x = function () { return arguments; }; }",
        "class D {} class C extends D { x = 1; constructor() { super(); } }",
        "class C { m() { delete this.x; } }",
        "class C { get #x(){} set #x(v){} m(){ return this.#x; } }",
        "var s = `\\u{1F600}ok`;",
        "var s = String.raw`\\x0`;",
    };
    for (ok) |src| {
        var pr = try parser.parse(testing.allocator, src, .script);
        switch (pr) {
            .ok => |*a| a.deinit(),
            .syntax_error => {
                std.debug.print("unexpected SyntaxError for: {s}\n", .{src});
                return error.UnexpectedSyntaxError;
            },
        }
    }
}

test "strict-mode reserved binding names" {
    const parser = @import("bottlebrush").parser;
    const bad = [_][]const u8{
        "\"use strict\"; var eval = 1;",
        "\"use strict\"; let package = 1;",
        "\"use strict\"; function f(arguments) {}",
        "\"use strict\"; var [implements] = [1];",
        "class C { static prototype() {} }",
        "class C { static prototype = 1; }",
        "var o = { __proto__: 1, __proto__: 2 };",
    };
    for (bad) |src| {
        var pr = try parser.parse(std.testing.allocator, src, .script);
        switch (pr) {
            .syntax_error => {},
            .ok => |*a| {
                a.deinit();
                std.debug.print("expected SyntaxError: {s}\n", .{src});
                return error.ExpectedSyntaxError;
            },
        }
    }
    // Legal in sloppy mode.
    var pr = try parser.parse(std.testing.allocator, "var eval = 1; function f(arguments) {}", .script);
    switch (pr) {
        .ok => |*a| a.deinit(),
        .syntax_error => return error.UnexpectedSyntaxError,
    }
}

test "escaped keywords and async/generator context" {
    const parser = @import("bottlebrush").parser;
    const bad = [_][]const u8{
        "var \\u0069f = 1;", // escaped `if` (reserved) as a binding
        "\\u0076ar x;", // escaped `var`
        "x = \\u0074his;", // escaped `this` as reference
        "class C { async m() { void \\u0061wait; } }", // escaped await in async
        "function* g() { var \\u0079ield = 1; }", // escaped yield in generator
    };
    for (bad) |src| {
        var pr = try parser.parse(std.testing.allocator, src, .script);
        switch (pr) {
            .syntax_error => {},
            .ok => |*a| {
                a.deinit();
                std.debug.print("expected SyntaxError: {s}\n", .{src});
                return error.ExpectedSyntaxError;
            },
        }
    }
    // Escaped keywords ARE valid as property names / keys.
    const ok = [_][]const u8{
        "var o = { \\u0069f: 1 }; o.\\u0063lass;",
        "var o = {}; o.\\u0066or = 1;",
        "var \\u0066oo = 5;", // escaped non-keyword identifier
    };
    for (ok) |src| {
        var pr = try parser.parse(std.testing.allocator, src, .script);
        switch (pr) {
            .ok => |*a| a.deinit(),
            .syntax_error => {
                std.debug.print("unexpected SyntaxError: {s}\n", .{src});
                return error.UnexpectedSyntaxError;
            },
        }
    }
}

test "derived default constructor installs parent elements; constructor-name errors" {
    // A derived class with no explicit constructor must still run the parent
    // constructor (default `super(...args)`), forwarding arguments and
    // installing parent private fields/methods.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\class A { #x = "Av"; read() { return this.#x; } }
        \\class B extends A {}
        \\return new B().read() === "Av" ? 1 : 0;
    ));
    try std.testing.expectEqual(@as(f64, 7), try evalNumber(
        \\class A { constructor(a, b) { this.s = a + b; } }
        \\class B extends A {}
        \\return new B(3, 4).s;
    ));
    // Private members from both a class and its superclass coexist per instance.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\class S { get #m() { return "s"; } sup() { return this.#m; } }
        \\class C extends S { get #m() { return "c"; } acc() { return this.#m; } }
        \\var c = new C();
        \\return (c.sup() === "s" && c.acc() === "c") ? 1 : 0;
    ));
    // constructor-name early errors (parser).
    const parser = @import("bottlebrush").parser;
    const bad = [_][]const u8{
        "class C { constructor; }",
        "class C { static constructor; }",
        "class C { get constructor() {} }",
        "class C { *constructor() {} }",
        "class C { async constructor() {} }",
    };
    for (bad) |src| {
        var pr = try parser.parse(std.testing.allocator, src, .script);
        switch (pr) {
            .syntax_error => {},
            .ok => |*a| {
                a.deinit();
                std.debug.print("expected SyntaxError: {s}\n", .{src});
                return error.ExpectedSyntaxError;
            },
        }
    }
}

test "escaped property keys decode to canonical names" {
    // Destructuring with an escaped key reads the decoded property.
    try std.testing.expectEqual(@as(f64, 42), try evalNumber(
        "var x; ({ \\u0066inally: x } = { finally: 42 }); return x;",
    ));
    // Escaped member access resolves to the canonical property.
    try std.testing.expectEqual(@as(f64, 3), try evalNumber(
        "var o = { class: 3 }; return o.\\u0063lass;",
    ));
    // Escaped key in an object literal defines the canonical property.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        "var o = { \\u0063lass: 9 }; return o[\"class\"] === 9 ? 1 : 0;",
    ));
}

test "more parser early errors: per-function strict, for-in head" {
    const parser = @import("bottlebrush").parser;
    const bad = [_][]const u8{
        "function f() { \"use strict\"; var eval = 1; }", // strict binding inside a fn
        "function f() { \"use strict\"; ({ package }); }", // strict shorthand inside a fn
        "for (this in {}) {}", // invalid for-in LHS
        "for (1 of []) {}", // invalid for-of LHS
    };
    for (bad) |src| {
        var pr = try parser.parse(std.testing.allocator, src, .script);
        switch (pr) {
            .syntax_error => {},
            .ok => |*a| {
                a.deinit();
                std.debug.print("expected SyntaxError: {s}\n", .{src});
                return error.ExpectedSyntaxError;
            },
        }
    }
    const ok = [_][]const u8{
        "function f() { var eval = 1; }", // sloppy: fine
        "for (x in { a: 1 }) {}",
        "for (var y in {}) {}",
        "for ([a, b] of [[1, 2]]) {}",
    };
    for (ok) |src| {
        var pr = try parser.parse(std.testing.allocator, src, .script);
        switch (pr) {
            .ok => |*a| a.deinit(),
            .syntax_error => {
                std.debug.print("unexpected SyntaxError: {s}\n", .{src});
                return error.UnexpectedSyntaxError;
            },
        }
    }
}

test "rest parameters" {
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\function f(...args) { return args.length === 3 && args[0] === 1 && args[2] === 3; }
        \\return f(1, 2, 3) ? 1 : 0;
    ));
    // Rest after fixed params, and empty rest.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\function f(a, b, ...rest) { return a + b + rest.length; }
        \\return (f(1, 2, 3, 4, 5) === 6 && f(9, 1) === 10) ? 1 : 0;
    ));
    // Rest is a real Array.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\function f(...xs) { return Array.isArray(xs) && xs.map(function (x) { return x * 2; }).join(","); }
        \\return (f(1, 2) === "2,4") ? 1 : 0;
    ));
    // Destructured rest, and arrow rest.
    try std.testing.expectEqual(@as(f64, 30), try evalNumber(
        \\function f(...[a, b]) { return a + b; }
        \\return f(10, 20);
    ));
    try std.testing.expectEqual(@as(f64, 10), try evalNumber(
        \\var g = (...xs) => xs.reduce(function (a, b) { return a + b; }, 0);
        \\return g(1, 2, 3, 4);
    ));
    // length excludes the rest parameter.
    try std.testing.expectEqual(@as(f64, 2), try evalNumber(
        \\function f(a, b, ...rest) {}
        \\return f.length;
    ));
}
