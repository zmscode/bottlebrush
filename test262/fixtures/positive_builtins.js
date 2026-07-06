// Copyright (C) 2024 bottlebrush. Fixture in Test262 format.
/*---
description: assert.throws with a real error constructor, plus Math/String/Object.
---*/

assert.throws(TypeError, function () {
  var n = null;
  n.property;
}, "reading a property of null throws TypeError");

assert.sameValue(Math.max(1, 5, 3), 5, "Math.max");
assert.sameValue(Math.abs(-4), 4, "Math.abs");
assert.sameValue(String(42), "42", "String coercion");
assert.sameValue(Number("2.5"), 2.5, "Number coercion");
assert.sameValue(({ a: 1 }).hasOwnProperty("a"), true, "hasOwnProperty");
assert.sameValue(new RangeError("x") instanceof Error, true, "error inheritance");
