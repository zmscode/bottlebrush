// Copyright (C) 2024 bottlebrush. Fixture in Test262 format.
/*---
description: String prototype methods, number formatting, and for-of iteration.
---*/

assert.sameValue("hello".length, 5, "length");
assert.sameValue("hello"[1], "e", "index access");
assert.sameValue("hello".toUpperCase(), "HELLO", "toUpperCase");
assert.sameValue("hello".slice(1, 3), "el", "slice");
assert.sameValue("a,b,c".split(",").length, 3, "split");
assert.sameValue("  trim  ".trim(), "trim", "trim");
assert.sameValue("ab".repeat(3), "ababab", "repeat");
assert.sameValue((255).toString(16), "ff", "Number.toString radix");
assert.sameValue((3.14159).toFixed(2), "3.14", "Number.toFixed");

var sum = 0;
for (var x of [1, 2, 3, 4]) {
  sum += x;
}
assert.sameValue(sum, 10, "for-of over an array");

var chars = "";
for (var c of "xyz") {
  chars += c;
}
assert.sameValue(chars, "xyz", "for-of over a string");
