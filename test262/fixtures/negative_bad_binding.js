// Copyright (C) 2024 bottlebrush. Fixture in Test262 format.
/*---
description: A numeric literal is not a valid binding target.
negative:
  phase: parse
  type: SyntaxError
flags: [raw]
---*/

var 123 = 1;
