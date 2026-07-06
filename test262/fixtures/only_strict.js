// Copyright (C) 2024 bottlebrush. Fixture in Test262 format.
/*---
description: Compound assignment works under an implicit strict-mode prologue.
flags: [onlyStrict]
---*/

var x = 40;
x += 2;
assert.sameValue(x, 42, "compound assignment in strict mode");
