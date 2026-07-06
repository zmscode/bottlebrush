// Copyright (C) 2017 Ecma International. All rights reserved.
// This code is governed by the BSD license found in the LICENSE file.
/*---
description: |
    Provides the Test262Error class used by other assertion helpers.
---*/

function Test262Error(message) {
	this.message = message || "";
}

Test262Error.prototype.toString = function () {
	return "Test262Error: " + this.message;
};

Test262Error.thrower = function (message) {
	throw new Test262Error(message);
};

function $DONOTEVALUATE() {
	throw "Test262: This statement should not be evaluated.";
}
