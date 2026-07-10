//! End-to-end VM tests under GC stress (collect on every allocation) — the
//! slow suite. Run with `zig build test-stress`.

const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");
const eval = helpers.eval;
const evalNumber = helpers.evalNumber;
const Vm = helpers.Vm;
const Value = helpers.Value;
const toBoolean = helpers.toBoolean;
const utf16ToUtf8Alloc = helpers.utf16ToUtf8Alloc;

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

test "weak collections drop dead entries under GC stress" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    vm.heap.stress = true;
    // The literal passed to set() is unreachable once set() returns; under
    // stress the very next allocation collects it, so the entry must vanish
    // while the still-referenced key survives.
    const v = try eval(&vm,
        \\var wm = new WeakMap();
        \\var kept = {};
        \\wm.set(kept, { big: "value" });
        \\wm.set({}, "doomed");
        \\var wr = new WeakRef({});
        \\var x = [];
        \\for (var i = 0; i < 50; i++) { x.push({ n: i }); }
        \\return (wm.has(kept) && wm.get(kept).big === "value" &&
        \\        wr.deref() === undefined) ? 1 : 0;
    );
    try testing.expectEqual(@as(f64, 1), v.asNumber());
}

// ---- Regressions found by running the Test262 corpus under GC stress -------
//
// Each of these passed the ordinary suite and the whole 6706-file conformance
// run; only stress (collect at every allocation safe-point) exposed the missed
// root. They are the cheapest possible guard against reintroducing the bug.

// The per-character string a string iterator produces is the only reference to
// a brand-new cell, and `makeIterResult` allocates.
test "string iterator elements survive GC stress" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    vm.heap.stress = true;
    const v = try eval(&vm,
        \\var out = [];
        \\for (var ch of 'xyz') out.push(ch);
        \\return out.join(",") + "/" + [...'ab'].join(",");
    );
    const s = try utf16ToUtf8Alloc(testing.allocator, v.asString().units);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("x,y,z/a,b", s);
}

// `entries()` builds a fresh pair array, then `makeIterResult` allocates.
test "Map/Object entries pairs survive GC stress" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    vm.heap.stress = true;
    const v = try eval(&vm,
        \\var m = new Map([["a", 1], ["b", 2]]);
        \\var out = [];
        \\for (var e of m) out.push(e[0] + "=" + e[1]);
        \\return out.join(",");
    );
    const s = try utf16ToUtf8Alloc(testing.allocator, v.asString().units);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("a=1,b=2", s);
}

// A native calling back into JS with a freshly allocated argument (the proxy
// trap's key string) — callee setup allocates the `arguments` object.
test "proxy trap arguments survive GC stress" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    vm.heap.stress = true;
    const v = try eval(&vm,
        \\var p = new Proxy({}, {
        \\  ownKeys: function() { return ["a", "b"]; },
        \\  getOwnPropertyDescriptor: function(t, k) {
        \\    return { value: k, enumerable: true, configurable: true, writable: true };
        \\  },
        \\  get: function(t, k) { return "v" + k; }
        \\});
        \\var o = { ...p };
        \\return o.a + "," + o.b;
    );
    const s = try utf16ToUtf8Alloc(testing.allocator, v.asString().units);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("va,vb", s);
}

// `makeDataDescriptor(try makeStringFromUtf16(..))`: the value is allocated,
// then the descriptor object allocation collects it.
test "String-object property descriptor survives GC stress" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    vm.heap.stress = true;
    const v = try eval(&vm,
        \\var d = Object.getOwnPropertyDescriptor(new String("123"), "2");
        \\return d.value + ":" + d.writable + ":" + d.enumerable;
    );
    const s = try utf16ToUtf8Alloc(testing.allocator, v.asString().units);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("3:false:true", s);
}

// RegExp.prototype[@@split] reads the exec result *after* appending a freshly
// built substring to the output array.
test "RegExp @@split species path survives GC stress" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    vm.heap.stress = true;
    const v = try eval(&vm,
        \\function MyRe() {}
        \\MyRe[Symbol.species] = function(s, f) { return new RegExp(s, f); };
        \\var re = /-/;
        \\re.constructor = MyRe;
        \\return "a-b-c".split(re).join("|");
    );
    const s = try utf16ToUtf8Alloc(testing.allocator, v.asString().units);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("a|b|c", s);
}

// Promise capability functions (resolve/reject) and their environments are
// created unrooted by NewPromiseCapability; async generators shift a request
// off its queue — its only root — before allocating the iterator result.
test "promise capabilities and async generators survive GC stress" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    vm.heap.stress = true;
    const v = try eval(&vm,
        \\var log = [];
        \\var P = function(ex) { return new Promise(function() { ex(function() {}, function() {}); }); };
        \\Promise.reject.call(P);
        \\async function* gen() { yield "a"; yield await Promise.resolve("b"); }
        \\(async function() {
        \\  for await (var x of gen()) log.push(x);
        \\  log.push((await Promise.any('xy')) + (await Promise.race('pq')));
        \\})();
        \\return log;
    );
    _ = v;
    try vm.runJobs();
    const out = try eval(&vm, "return log.join(',');");
    const s = try utf16ToUtf8Alloc(testing.allocator, out.asString().units);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("a,b,xp", s);
}
