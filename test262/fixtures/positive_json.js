// Copyright (C) 2024 bottlebrush. Fixture in Test262 format.
/*---
description: JSON.stringify and JSON.parse, including round-trip and cycles.
---*/

assert.sameValue(JSON.stringify(42), "42", "number");
assert.sameValue(JSON.stringify("hi"), '"hi"', "string");
assert.sameValue(JSON.stringify([1, 2, 3]), "[1,2,3]", "array");
assert.sameValue(JSON.stringify({ a: 1, b: [2, 3] }), '{"a":1,"b":[2,3]}', "nested");
assert.sameValue(JSON.stringify({ a: 1, b: undefined }), '{"a":1}', "undefined omitted");
assert.sameValue(JSON.stringify([1, undefined, 3]), "[1,null,3]", "undefined -> null in array");

var o = JSON.parse('{"x":1,"y":[2,3],"z":"s"}');
assert.sameValue(o.x, 1, "parse number");
assert.sameValue(o.y[1], 3, "parse nested array");
assert.sameValue(o.z, "s", "parse string");

var round = JSON.parse(JSON.stringify({ n: 5, arr: [true, null, "x"] }));
assert.sameValue(round.arr[0], true, "round-trip bool");
assert.sameValue(round.arr[1], null, "round-trip null");

assert.throws(TypeError, function () {
  var c = {};
  c.self = c;
  JSON.stringify(c);
}, "cyclic structure throws TypeError");
