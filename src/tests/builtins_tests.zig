//! End-to-end VM tests: the built-in library (Object/Array/String/Math/JSON/
//! RegExp/collections/TypedArrays/Date). Run with `zig build test-builtins`.

const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");
const eval = helpers.eval;
const evalNumber = helpers.evalNumber;
const Vm = helpers.Vm;
const Value = helpers.Value;
const toBoolean = helpers.toBoolean;
const utf16ToUtf8Alloc = helpers.utf16ToUtf8Alloc;

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
    var vm = Vm.init(helpers.gpa);
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
    var vm = Vm.init(helpers.gpa);
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

test "number methods" {
    try testing.expectEqual(@as(f64, 1), try evalNumber("return (255).toString(16) === 'ff' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return (3.14159).toFixed(2) === '3.14' ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return Number.isInteger(5) && !Number.isInteger(5.5) ? 1 : 0;"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("return (10).toString(2) === '1010' ? 1 : 0;"));
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

test "regex symbol protocol: @@match/@@replace/@@search/@@split" {
    // RegExp.prototype provides the built-ins (String methods still work).
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\return ("a1b2".match(/\d/g).join(",") === "1,2" &&
        \\        "hay".search(/y/) === 2 &&
        \\        "x-y".split(/-/).join("") === "xy" &&
        \\        "aaa".replace(/a/g, "b") === "bbb") ? 1 : 0;
    ));
    // They are real methods on RegExp.prototype.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\return (typeof RegExp.prototype[Symbol.match] === "function" &&
        \\        typeof RegExp.prototype[Symbol.replace] === "function" &&
        \\        typeof RegExp.prototype[Symbol.search] === "function" &&
        \\        typeof RegExp.prototype[Symbol.split] === "function") ? 1 : 0;
    ));
    // Direct invocation works.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\return /o/[Symbol.search]("hoot") === 1 ? 1 : 0;
    ));
    // Custom pattern objects hook the String methods.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var pat = {};
        \\pat[Symbol.match] = function (s) { return "matched:" + s; };
        \\pat[Symbol.replace] = function (s, r) { return s + "|" + r; };
        \\pat[Symbol.search] = function (s) { return 42; };
        \\pat[Symbol.split] = function (s, lim) { return [s, lim]; };
        \\var sp = "str".split(pat, 7);
        \\return ("abc".match(pat) === "matched:abc" &&
        \\        "abc".replace(pat, "R") === "abc|R" &&
        \\        "abc".search(pat) === 42 &&
        \\        sp[0] === "str" && sp[1] === 7) ? 1 : 0;
    ));
}

test "RegExp u/v modes" {
    // Dot spans a full code point under u; two units without it.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\return (/^.$/u.test("😀") && !/^.$/.test("😀") && /^.$/v.test("😀")) ? 1 : 0;
    ));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\return (/\u{1F600}/u.test("ab😀c") && /^😀+$/u.test("😀😀")) ? 1 : 0;
    ));
    // Strict escapes: \q throws only in u-mode.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var threw = false;
        \\try { new RegExp("\\q", "u"); } catch (e) { threw = e instanceof SyntaxError; }
        \\return (threw && new RegExp("\\q").test("q")) ? 1 : 0;
    ));
}

test "symbols as weak keys" {
    // Non-registered symbols can be held weakly.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var wm = new WeakMap();
        \\var s = Symbol("k");
        \\wm.set(s, 42);
        \\return (wm.get(s) === 42 && wm.has(s)) ? 1 : 0;
    ));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var ws = new WeakSet();
        \\var s = Symbol();
        \\ws.add(s);
        \\return (ws.has(s) && new WeakRef(s).deref() === s) ? 1 : 0;
    ));
    // Registered symbols (Symbol.for) cannot.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var wm = new WeakMap();
        \\try { wm.set(Symbol.for("x"), 1); return 0; }
        \\catch (e) { return (e instanceof TypeError) ? 1 : 2; }
    ));
    // Primitives still throw.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var ws = new WeakSet();
        \\try { ws.add("str"); return 0; }
        \\catch (e) { return (e instanceof TypeError) ? 1 : 2; }
    ));
}

test "Reflect completion" {
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var o = {};
        \\var ok = Reflect.defineProperty(o, "x", { value: 5, configurable: false });
        \\var d = Reflect.getOwnPropertyDescriptor(o, "x");
        \\return (ok === true && d.value === 5 && d.configurable === false) ? 1 : 0;
    ));
    // defineProperty returns false (not throw) on a rejected redefine.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var o = {};
        \\Reflect.defineProperty(o, "x", { value: 1, configurable: false, writable: false });
        \\return Reflect.defineProperty(o, "x", { value: 2 }) === false ? 1 : 0;
    ));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var proto = { tag: 1 };
        \\var o = {};
        \\return (Reflect.setPrototypeOf(o, proto) === true && Reflect.getPrototypeOf(o) === proto) ? 1 : 0;
    ));
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var o = {};
        \\var before = Reflect.isExtensible(o);
        \\Reflect.preventExtensions(o);
        \\return (before === true && Reflect.isExtensible(o) === false) ? 1 : 0;
    ));
    // deleteProperty honors non-configurable (returns false).
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var o = {};
        \\Object.defineProperty(o, "p", { value: 1, configurable: false });
        \\return Reflect.deleteProperty(o, "p") === false ? 1 : 0;
    ));
}

test "function and method .name" {
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var o = { method() {}, get x() {}, set x(v) {} };
        \\var d = Object.getOwnPropertyDescriptor(o, "x");
        \\return (o.method.name === "method" && d.get.name === "get x" && d.set.name === "set x") ? 1 : 0;
    ));
    // NamedEvaluation: anonymous fn / arrow / class assigned to a binding.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var f = function () {};
        \\var g = () => {};
        \\const C = class {};
        \\var h; h = function () {};
        \\return (f.name === "f" && g.name === "g" && C.name === "C" && h.name === "h") ? 1 : 0;
    ));
    // A named function expression keeps its own name.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var f = function original() {};
        \\return f.name === "original" ? 1 : 0;
    ));
    // .name is non-writable, configurable.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\function foo() {}
        \\var d = Object.getOwnPropertyDescriptor(foo, "name");
        \\return (d.writable === false && d.configurable === true && d.enumerable === false) ? 1 : 0;
    ));
}

test "RegExp exec protocol (Symbol methods honor custom exec)" {
    // A custom `exec` on a RegExp is used by String.prototype.match.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var re = /x/;
        \\var calls = 0;
        \\re.exec = function () { calls++; return calls === 1 ? ["HIT"] : null; };
        \\var m = "zzz".match(re);
        \\return (calls >= 1 && m[0] === "HIT") ? 1 : 0;
    ));
    // Symbol.search returns the result's `index` and restores lastIndex.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var re = /b/;
        \\re.lastIndex = 5;
        \\var idx = "aabaa".search(re);
        \\return (idx === 2 && re.lastIndex === 5) ? 1 : 0;
    ));
    // A plain object with a Symbol.replace is honored by String.prototype.replace.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var pat = {};
        \\pat[Symbol.replace] = function (s, r) { return "[" + s + "|" + r + "]"; };
        \\return "abc".replace(pat, "X") === "[abc|X]" ? 1 : 0;
    ));
    // Symbol.match on a non-object receiver throws TypeError.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\try { RegExp.prototype[Symbol.match].call(5, "x"); return 0; }
        \\catch (e) { return (e instanceof TypeError) ? 1 : 2; }
    ));
    // Custom exec whose result isn't object/null throws TypeError.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var re = /x/g;
        \\re.exec = function () { return 42; };
        \\try { "x".match(re); return 0; }
        \\catch (e) { return (e instanceof TypeError) ? 1 : 2; }
    ));
}

test "RegExp @@split species and exec protocol" {
    // Plain split still works (fast path).
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\return ("a1b2c".split(/\d/).join("|") === "a|b|c") ? 1 : 0;
    ));
    // Captures are spliced into the result.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\return ("2016-01".split(/(-)/).join(",") === "2016,-,01") ? 1 : 0;
    ));
    // limit is honored.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\return ("a,b,c,d".split(/,/, 2).join("|") === "a|b") ? 1 : 0;
    ));
    // @@species selects the splitter constructor.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\var re = /x/iy;
        \\re.constructor = function () {};
        \\re.constructor[Symbol.species] = function () { return /[db]/y; };
        \\var r = RegExp.prototype[Symbol.split].call(re, "abcde");
        \\return (r.join("") === "ace") ? 1 : 0;
    ));
    // RegExp[@@species] returns the receiver.
    try std.testing.expectEqual(@as(f64, 1), try evalNumber(
        \\return RegExp[Symbol.species] === RegExp ? 1 : 0;
    ));
}
