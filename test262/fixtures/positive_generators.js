// Copyright (C) 2024 bottlebrush. Fixture in Test262 format.
/*---
description: Generators and the iteration protocol.
---*/

function* range(start, end) {
	for (var i = start; i < end; i++) yield i;
}
var total = 0;
for (var x of range(1, 5)) total += x;
assert.sameValue(total, 10, "for-of over a generator");

var it = range(0, 3);
assert.sameValue(it.next().value, 0, "next 1");
assert.sameValue(it.next().value, 1, "next 2");
assert.sameValue(it.next().value, 2, "next 3");
assert.sameValue(it.next().done, true, "exhausted");

function* letters() {
	yield "a";
	yield "b";
}
assert.sameValue([...letters()].join(""), "ab", "spread a generator");

function* inner() {
	yield 2;
	yield 3;
}
function* outer() {
	yield 1;
	yield* inner();
	yield 4;
}
var sum = 0;
for (var n of outer()) sum += n;
assert.sameValue(sum, 10, "yield* delegation");

var setSum = 0;
for (var v of new Set([5, 5, 10])) setSum += v;
assert.sameValue(setSum, 15, "for-of over a Set");
assert.sameValue([...new Map([["a", 1]]).keys()][0], "a", "Map keys iterator");
