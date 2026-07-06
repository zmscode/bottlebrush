# bottlebrush

A tier-2 JavaScript engine in Zig: a spec-faithful bytecode VM (no JIT),
driven by [Test262](https://github.com/tc39/test262) conformance from day one.

See [plan.md](plan.md) for the architecture and [phase/](phase/) for the
per-phase build plans.

## Status: Phase 1 — Lexer, parser & AST

The front end is in place: source text now parses to an AST, and the Test262
runner scores **parse-phase negatives** (SyntaxError tests). Execution still
starts in Phase 2.

- **Value** (`src/value.zig`) — tagged-union `Value` behind a stable accessor
  API (NaN-boxing swaps in later, Phase 7).
- **GC** (`src/gc.zig`, `src/handle.zig`) — precise stop-the-world mark-sweep
  with a `trace` interface, `HandleScope` rooting, and a `stress` flag.
- **Lexer** (`src/token.zig`, `src/lexer.zig`) — full punctuator/number/string/
  template set, keyword table, ASI signal, and parser-driven rescans for regex
  literals and template continuations.
- **Parser + AST** (`src/parser.zig`, `src/ast.zig`) — recursive descent with
  precedence-climbing expressions, arrow cover-grammar via backtracking,
  destructuring patterns, classes, and module syntax; arena-allocated AST.
- **Test262 harness** (`test262/`) — parse-phase negatives are scored (PASS iff
  a SyntaxError is reported). Positive tests and runtime negatives still SKIP
  pending the evaluator. Full Unicode ID tables and cooked literal values are
  deferred to later phases.

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
