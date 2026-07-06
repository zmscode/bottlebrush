// Copyright (C) 2024 bottlebrush. Fixture in Test262 format.
/*---
description: Array literals, indexing, mutation, higher-order methods, Object.keys.
---*/

var a = [1, 2, 3, 4];
assert.sameValue(a.length, 4, "length");
assert.sameValue(a[2], 3, "index access");

a.push(5);
assert.sameValue(a.length, 5, "push updates length");
assert.sameValue(a.pop(), 5, "pop returns last");

var doubled = [1, 2, 3].map(function (x) { return x * 2; });
assert.sameValue(doubled[0] + doubled[1] + doubled[2], 12, "map");

var evens = [1, 2, 3, 4].filter(function (x) { return x % 2 === 0; });
assert.sameValue(evens.length, 2, "filter");

assert.sameValue([1, 2, 3].join("-"), "1-2-3", "join");
assert.sameValue(Array.isArray(a), true, "Array.isArray");
assert.sameValue([1, 2].concat([3, 4]).length, 4, "concat");

var o = { x: 1, y: 2 };
assert.sameValue(Object.keys(o).length, 2, "Object.keys");
assert.sameValue(Object.values(o)[1], 2, "Object.values");
