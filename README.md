# bottlebrush

A tier-2 JavaScript engine in Zig: a spec-faithful bytecode VM (no JIT),
driven by [Test262](https://github.com/tc39/test262) conformance from day one.

See [plan.md](plan.md) for the architecture and [phase/](phase/) for the
per-phase build plans.

## Status: Phase 4 — Standard library (practical core complete)

The engine has native (Zig-implemented) built-ins, real `Error` objects, arrays,
strings with a prototype, and `for-of`. `assert.throws`, `instanceof`, and
runtime-phase negative tests all work.

- **Native function** mechanism (a `Closure` can dispatch to Zig).
- **Error** + `TypeError`/`RangeError`/`ReferenceError`/`SyntaxError`/`EvalError`/
  `URIError` (real prototype chain; engine throws are now Error objects).
- **Object**: constructor, prototype methods, and statics `getPrototypeOf`/
  `create`/`defineProperty`/`getOwnPropertyDescriptor`/`keys`/`values`/`entries`.
- **Array**: literals, dense storage + exotic `length`, `push`/`pop`/`indexOf`/
  `includes`/`join`/`slice`/`concat`/`forEach`/`map`/`filter`, `Array.isArray`.
- **String**: primitive property access (`length`, indexing) + `String.prototype`
  (`charAt`/`charCodeAt`/`indexOf`/`includes`/`startsWith`/`endsWith`/`slice`/
  `substring`/`toUpperCase`/`toLowerCase`/`trim`/`repeat`/`concat`/`split`),
  `String.fromCharCode`.
- **Number**: `toString(radix)`/`toFixed`/`valueOf`, `Number.isInteger`/`isFinite`/
  `isNaN`, `MAX_SAFE_INTEGER`; **Math** (11 methods + PI/E); `isNaN`/`isFinite`.
- **`for-of`** over arrays and strings.
- **RegExp** (stub): literals `/.../flags` and `new RegExp(...)` construct with
  `source`/`flags`/`lastIndex` + derived flag booleans, `instanceof RegExp`, and
  `toString`. **Matching (`test`/`exec`) is not implemented yet** — it throws, to
  be replaced by a real backtracking engine behind the same interface.

The Test262 runner scores positives (run + assert), parse-negatives, and
runtime-negatives (by thrown constructor name).

Deferred to later work (each a sizable subsystem): a real RegExp matcher, the
full iteration protocol (`Symbol.iterator`, generators), spread, `JSON`, `Date`,
`Map`/`Set`, TypedArrays, `Proxy`, `Symbol`, full Unicode case mapping, and
per-iteration `let` bindings / TDZ.

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
