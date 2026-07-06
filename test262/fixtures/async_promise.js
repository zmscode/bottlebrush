// Copyright (C) 2024 bottlebrush. Fixture in Test262 format.
/*---
description: An async test using the $DONE / doneprintHandle contract.
flags: [async]
includes: [asyncHelpers.js]
features: [Promise]
---*/

Promise.resolve(42)
	.then(function (v) {
		assert.sameValue(v, 42);
	})
	.then($DONE, $DONE);
