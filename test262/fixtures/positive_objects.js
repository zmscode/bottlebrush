// Copyright (C) 2024 bottlebrush. Fixture in Test262 format.
/*---
description: Objects, this, prototype methods, and method chaining.
---*/

function Counter(start) {
	this.n = start;
}
Counter.prototype.inc = function () {
	this.n = this.n + 1;
	return this;
};

var c = new Counter(10);
c.inc().inc();
assert.sameValue(c.n, 12, "counter increments via prototype method");

var o = { a: 1, b: 2 };
assert.sameValue(o.a + o.b, 3, "object member sum");
assert.sameValue(c instanceof Counter, true, "instanceof");
