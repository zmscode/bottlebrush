# bottlebrush

A tier-2 JavaScript engine in Zig: a spec-faithful bytecode VM (no JIT),
driven by [Test262](https://github.com/tc39/test262) conformance from day one.

See [plan.md](plan.md) for the architecture and [phase/](phase/) for the
per-phase build plans.

## Status: Phase 2 — Bytecode compiler & interpreter

The engine **executes**. Source compiles to register-based bytecode and runs on
the interpreter: arithmetic, variables, control flow, functions, recursion, and
closures all work (`zig build run` runs a demo). Objects, arrays, and the
standard library arrive next, which is what unlocks Test262 *positive* scoring.

- **Value** (`src/value.zig`) — tagged-union `Value` behind a stable accessor
  API (NaN-boxing swaps in later, Phase 7).
- **GC** (`src/gc.zig`, `src/handle.zig`) — precise mark-sweep with `Environment`
  and `Closure` cells, a `trace` interface, and a `stress` mode the VM honors.
- **Lexer / Parser / AST** (`src/{token,lexer,parser,ast}.zig`) — full front end.
- **Bytecode** (`src/bytecode.zig`) — register-based ops, `CodeBlock`, disassembler.
- **Compiler** (`src/compiler.zig`) — AST → bytecode: scope analysis, var
  hoisting, stack-discipline register allocation, control flow via jumps,
  functions/closures.
- **Interpreter** (`src/interpreter.zig`) — dispatch loop, coercions, equality,
  calls (native-stack recursion, depth-guarded), and try/catch exception
  unwinding via handler tables. The VM is a GC root provider.
- **Test262 harness** (`test262/`) — parse-phase negatives are scored (100% of
  the fixture slice). Positive tests still SKIP pending objects + the harness.

**Phase-2 simplifications** (documented inline, tightened later): one
environment per function (no per-iteration `let` bindings, no TDZ enforcement),
`this` is `undefined`, engine-thrown errors are strings (real `Error` objects
need the object model), and objects/arrays/member-access/`new`/destructuring/
generators are reported as unsupported by the compiler for now.

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
