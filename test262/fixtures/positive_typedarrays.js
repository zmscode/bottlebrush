// Copyright (C) 2024 bottlebrush. Fixture in Test262 format.
/*---
description: TypedArrays, ArrayBuffer views, element coercion, and methods.
---*/

var a = new Int32Array([10, 20, 30]);
assert.sameValue(a.length, 3, "length");
assert.sameValue(a[1], 20, "element access");
assert.sameValue(a.byteLength, 12, "byteLength");
assert.sameValue(Int32Array.BYTES_PER_ELEMENT, 4, "BYTES_PER_ELEMENT");
assert.sameValue(a instanceof Int32Array, true, "instanceof");

var u8 = new Uint8Array(1);
u8[0] = 300;
assert.sameValue(u8[0], 44, "Uint8 wraps mod 256");

var clamped = new Uint8ClampedArray(1);
clamped[0] = 500;
assert.sameValue(clamped[0], 255, "Uint8Clamped clamps high");

var buf = new ArrayBuffer(4);
assert.sameValue(buf.byteLength, 4, "ArrayBuffer byteLength");
var bytes = new Uint8Array(buf);
var i32 = new Int32Array(buf);
i32[0] = 1;
assert.sameValue(bytes[0], 1, "views share one buffer (little-endian)");

var f = new Int32Array(4);
f.fill(5);
assert.sameValue(f[2], 5, "fill");
f.set([7, 8], 1);
assert.sameValue(f[1] + f[2], 15, "set at offset");

var sub = new Int32Array([1, 2, 3, 4]).subarray(1, 3);
assert.sameValue(sub.length, 2, "subarray length");
assert.sameValue(new Int32Array([1, 2, 3]).join("-"), "1-2-3", "join");
