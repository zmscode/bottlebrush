// Copyright (C) 2015 the V8 project authors. All rights reserved.
// This code is governed by the BSD license found in the LICENSE file.
/*---
description: |
    Define the $DONE function used by asynchronous tests. It prints the
    Test262:AsyncTestComplete / Test262:AsyncTestFailure sentinels that the
    host runner inspects to score the test.
---*/

function $DONE(error) {
  if (error) {
    if (typeof error === 'object' && error !== null && 'name' in error) {
      print('Test262:AsyncTestFailure:' + error.name + ': ' + error.message);
    } else {
      print('Test262:AsyncTestFailure:Test262Error: ' + error);
    }
  } else {
    print('Test262:AsyncTestComplete');
  }
}
