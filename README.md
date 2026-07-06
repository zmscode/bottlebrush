# bottlebrush

A tier-2 JavaScript engine in Zig: a spec-faithful bytecode VM (no JIT),
driven by [Test262](https://github.com/tc39/test262) conformance from day one.

See [plan.md](plan.md) for the architecture and [phase/](phase/) for the
per-phase build plans.

## Status: Phase 3 — Object model & harness (complete)

Objects work, and **positive Test262 tests now execute against the real
`assert.js` harness**. The engine has a full object model — prototypes,
property descriptors, member access, `this`, `new`, method calls, `instanceof`,
`in`, a global object, and coercion via `ToPrimitive`/`valueOf`/`toString` — all
exercised under GC stress. The runner concatenates `sta.js` + `assert.js` +
`includes` with each test, runs it in a fresh realm, and scores PASS/FAIL/SKIP.
`zig build run` runs a constructor + prototype-method + method-chaining demo.

Still ahead (Phase 4): the standard library — `Object`/`Array`/`String`/`Error`
constructors, etc. — which is what lets the bulk of the corpus run.

Earlier phases (all complete):

- **Value** (`src/value.zig`) — tagged-union `Value` behind a stable accessor API.
- **GC** (`src/gc.zig`) — precise mark-sweep with `Environment`, `Closure`, and
  property-bearing `Object` cells; a `trace` interface and a `stress` mode.
- **Lexer / Parser / AST** (`src/{token,lexer,parser,ast}.zig`) — full front end.
- **Bytecode / Compiler / Interpreter** — register-based VM with scope analysis,
  var hoisting, control flow, functions/closures, and now objects: property
  get/set (dot + computed), object literals, `this`, `new`/construct, method
  calls, prototype chains, and `ToPrimitive` coercion. GC-safe under stress via
  frame roots + a temp-root stack for unrooted intermediates.
- **Test262 harness** (`test262/`) — parse-phase negatives scored (100% of the
  fixture slice). Positive tests still SKIP pending the global object + harness.

**Simplifications** (documented inline, tightened later): one environment per
function (no per-iteration `let`, no TDZ), symbol keys / arrays / accessors-in-
object-literals / destructuring / generators not yet supported, engine-thrown
errors are strings pending real `Error` objects, and there is no global object
yet (top-level bindings use the environment chain).

## Requirements

- Zig **0.16.0** (uses the new `std.Io` model and unmanaged `std.ArrayList`).

## Commands

```sh
zig build            # build the CLI + test262 runner
zig build test       # unit + harness tests
zig build test262    # run the conformance speedometer (prints a scoreboard)
zig build run        # print the CLI banner
```

## Test262 corpus

The runner defaults to the bundled fixtures in `test262/fixtures/` (a handful of
files in Test262 format, enough to exercise the harness). Vendoring the full
tc39/test262 corpus and CLI directory selection come as the harness matures.

## Conformance

CI (`.github/workflows/ci.yml`) runs the speedometer and fails on any regression
below `test262/baseline.json`. The number only goes up.
