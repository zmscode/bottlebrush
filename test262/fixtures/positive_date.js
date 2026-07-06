// Copyright (C) 2024 bottlebrush. Fixture in Test262 format.
/*---
description: Date construction, field getters, UTC, ISO string, and parsing.
---*/

var d = new Date(1623760245123); // 2021-06-15T12:30:45.123Z
assert.sameValue(d.getTime(), 1623760245123, "getTime");
assert.sameValue(d.getFullYear(), 2021, "getFullYear");
assert.sameValue(d.getMonth(), 5, "getMonth (0-based, June)");
assert.sameValue(d.getDate(), 15, "getDate");
assert.sameValue(d.getDay(), 2, "getDay (Tuesday)");
assert.sameValue(d.getHours(), 12, "getHours");
assert.sameValue(d.getSeconds(), 45, "getSeconds");
assert.sameValue(d.toISOString(), "2021-06-15T12:30:45.123Z", "toISOString");

assert.sameValue(Date.UTC(2021, 5, 15, 12, 30, 45, 123), 1623760245123, "Date.UTC");
assert.sameValue(Date.parse("2021-06-15T12:30:45.123Z"), 1623760245123, "Date.parse");
assert.sameValue(new Date(1970, 0, 1, 0, 0, 0, 0).getTime(), 0, "epoch from components");
assert.sameValue(typeof Date.now(), "number", "Date.now is a number");
