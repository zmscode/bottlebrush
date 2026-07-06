// Copyright (C) 2024 bottlebrush. Fixture in Test262 format.
/*---
description: Symbol primitives, registry, well-known symbols, symbol keys.
---*/

assert.sameValue(typeof Symbol(), "symbol", "typeof");
assert.sameValue(Symbol("a") === Symbol("a"), false, "symbols are unique");
assert.sameValue(Symbol("x").toString(), "Symbol(x)", "toString");
assert.sameValue(Symbol("x").description, "x", "description");
assert.sameValue(Symbol.for("k") === Symbol.for("k"), true, "registry");
assert.sameValue(Symbol.keyFor(Symbol.for("key")), "key", "keyFor");
assert.sameValue(typeof Symbol.iterator, "symbol", "well-known symbol");

var s = Symbol("prop");
var o = { a: 1 };
o[s] = 99;
assert.sameValue(o[s], 99, "symbol-keyed property");
assert.sameValue(Object.keys(o).length, 1, "symbol keys excluded from Object.keys");
assert.sameValue(JSON.stringify(o), '{"a":1}', "symbol keys excluded from JSON");
