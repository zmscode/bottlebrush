// Copyright (C) 2024 bottlebrush. Fixture in Test262 format.
/*---
description: RegExp literal and constructor object shape (matching is stubbed).
---*/

var re = /ab+c/gi;
assert.sameValue(re.source, "ab+c", "source");
assert.sameValue(re.flags, "gi", "flags");
assert.sameValue(re.global, true, "global flag");
assert.sameValue(re.ignoreCase, true, "ignoreCase flag");
assert.sameValue(re.multiline, false, "multiline flag");
assert.sameValue(re instanceof RegExp, true, "instanceof RegExp");
assert.sameValue(re.toString(), "/ab+c/gi", "toString");

var re2 = new RegExp("x", "m");
assert.sameValue(re2.source, "x", "constructor source");
assert.sameValue(re2.multiline, true, "constructor flag");
