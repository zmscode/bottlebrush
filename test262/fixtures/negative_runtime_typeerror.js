// Copyright (C) 2024 bottlebrush. Fixture in Test262 format.
/*---
description: Reading a property of null throws a TypeError at runtime.
negative:
  phase: runtime
  type: TypeError
---*/

var x = null;
x.oops;
