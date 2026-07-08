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
