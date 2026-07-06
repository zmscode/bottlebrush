// Copyright (C) 2024 bottlebrush. Fixture in Test262 format.
/*---
description: Map and Set basics — identity keys, SameValueZero, chaining, forEach.
---*/

var m = new Map();
m.set("a", 1).set("b", 2);
assert.sameValue(m.get("a"), 1, "Map.get");
assert.sameValue(m.size, 2, "Map.size");
assert.sameValue(m.has("b"), true, "Map.has");
m.delete("a");
assert.sameValue(m.has("a"), false, "Map.delete");

var key = {};
m.set(key, 99);
assert.sameValue(m.get(key), 99, "object key by identity");
m.set(NaN, 7);
assert.sameValue(m.get(NaN), 7, "NaN key via SameValueZero");

var s = new Set([1, 2, 2, 3]);
assert.sameValue(s.size, 3, "Set dedups");
s.add(4);
assert.sameValue(s.has(4), true, "Set.add/has");

var sum = 0;
new Map([["x", 10], ["y", 20]]).forEach(function (v) { sum += v; });
assert.sameValue(sum, 30, "Map.forEach");
