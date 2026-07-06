// Copyright (C) 2024 bottlebrush. Fixture in Test262 format.
/*---
description: DataView big/little-endian access over a shared ArrayBuffer.
---*/

var dv = new DataView(new ArrayBuffer(8));
dv.setInt32(0, 305419896); // 0x12345678, big-endian by default
assert.sameValue(dv.getInt32(0), 305419896, "int32 round-trip");
assert.sameValue(dv.getUint8(0), 0x12, "big-endian first byte");

dv.setInt32(0, 1, true); // little-endian
assert.sameValue(dv.getUint8(0), 1, "little-endian first byte");

dv.setFloat64(0, 3.5);
assert.sameValue(dv.getFloat64(0), 3.5, "float64 round-trip");
assert.sameValue(dv.byteLength, 8, "byteLength");
