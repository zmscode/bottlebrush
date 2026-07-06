// Copyright (C) 2024 bottlebrush. Fixture in Test262 format.
/*---
description: Proxy traps (get/set/has/apply) and Reflect mirror operations.
---*/

var p = new Proxy(
	{},
	{
		get: function (t, k) {
			return k === "answer" ? 42 : t[k];
		},
		set: function (t, k, v) {
			t[k] = v * 2;
			return true;
		},
		has: function (t, k) {
			return k === "known";
		},
	},
);
assert.sameValue(p.answer, 42, "get trap");
p.n = 5;
assert.sameValue(p.n, 10, "set trap doubled the stored value");
assert.sameValue("known" in p, true, "has trap true");
assert.sameValue("other" in p, false, "has trap false");

var forwarded = new Proxy({ v: 7 }, {});
assert.sameValue(forwarded.v, 7, "no trap forwards to target");

function base(a, b) {
	return a + b;
}
var callable = new Proxy(base, {
	apply: function (t, thisArg, args) {
		return args[0] - args[1];
	},
});
assert.sameValue(callable(10, 3), 7, "apply trap");

assert.sameValue(Reflect.apply(base, null, [2, 3]), 5, "Reflect.apply");
assert.sameValue(Reflect.ownKeys({ a: 1, b: 2 }).length, 2, "Reflect.ownKeys");
