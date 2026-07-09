# Test262 Conformance Audit

Snapshot of every failing and skipped Test262 case in the vendored corpus,
grouped by root cause and ranked by payoff. Regenerate the raw data by flipping
`trace_files = true` in `test262/runner.zig`, rebuilding, and grepping the
runner's `FAILCASE`/`SKIPCASE` lines (each is `TAG <path> <reason>`).

**As of 2026-07-09** (commit `e879474`):

| Bucket | Count | % of corpus |
|--------|------:|------------:|
| **files** | 5977 | 100% |
| **pass** | 3591 | 60.1% |
| **fail** | 736 | 12.3% |
| **skip** | 1650 | 27.6% |
| pass of executed (pass+fail) | | **83.0%** |

> **Progress since the first audit (was 3327 pass / 990 fail):** F1
> escaped-keys (+172), F5 RegExp @@split species (+22), and the F2/S1
> worklist — shorthand-reserved (+46), undeclared-private (+5),
> per-function strict (+9), for-in head (+2), rest parameters (+8 and
> `super(...args)` forwarding). Remaining fails are the Proxy invariants
> (F3, ~104), the direct-eval + brand-ordering class runtime (F4, ~54),
> the smaller runtime tail (F6), and the fiddlier parse-negatives
> (cover-init-name, deep dstr-target validation, await/yield labels).

"Executed rate" is the honest correctness signal; "skip" is coverage we
deliberately or unavoidably decline. The goal of this document is to convert the
990 fails + the *recoverable* skips into a prioritized worklist.

---

## Part 1 — Fails (990)

By failure shape:

| Shape | Count |
|-------|------:|
| assertion failure (`Test262Error` thrown by the harness) | 617 |
| missing early-error (parse-negative parsed OK) | 223 |
| unexpected `TypeError` at runtime | 110 |
| unexpected `SyntaxError` (parse/compile gap surfaced at run time) | 36 |
| unexpected `RangeError` | 4 |

By area (top): object 234, assignment 164, class 163, Proxy 104, RegExp 70,
for-in 34, WeakMap 33, Reflect 30, Object 29, BigInt 23, String 23, Array 20.

### F1. Escaped property keys / method names are not decoded — ~172 fails ★ TOP

Root cause: an identifier property **key** written with a unicode escape keeps
its raw text instead of decoding to the canonical name. `parseIdentifier`
decodes escapes (fixed in `f09ff7f`), but property keys flow through
`parsePropertyKey` / `propNameConst`, which do not.

```js
var y = { finally: x } = { finally: 42 };
// reads property "finally" (undefined) instead of "finally" (42)
```

- 129 × `assignment/dstr/*-escaped` and `object/*-escaped` — "property exists
  Expected SameValue(«undefined», «42»)".
- 43 × `object/ident-name-method-def-*-escaped` — "value is not a function"
  (the method is stored under the escaped key, so the canonical lookup misses).

**Fix**: decode escaped identifier/string keys in `parsePropertyKey` and
`propNameConst` (reuse `Lexer.decodeIdentifier`; the `Token.escaped` flag is
already threaded). Single localized change, ~172 tests. **Do this first.**

### F2. Missing parser early-errors — 223 (parse-negatives)

Parse-negative tests that our parser accepts. Remaining sub-buckets after the
checks already landed (delete-private, field-init super/arguments, dup private
names, template escapes, strict bindings, static-prototype, dup __proto__,
constructor-name):

| Sub-bucket | ~Count | Notes |
|------------|-------:|-------|
| undeclared private name (`this.#x` with no `#x` in scope) | ~14 | compiler already errors; parse-negatives only run the parser, so needs a **parser-side private-name scope** |
| object shorthand reserved-in-strict (`({ yield })`, `({ eval })`) | ~20 | strict reserved words as *shorthand references*, not bindings |
| assignment/dstr invalid targets (`[a+b] = x`, cover-init `({a=1})`) | ~30 | destructuring-assignment target validation (AssignmentTargetType) |
| for-in/of head validation (`for (this in …)`, dup let names) | ~17 | invalid LHS / duplicate lexical bound names |
| async/generator label + misc escaped keywords | ~10 | `await:`/`yield:` labels in async/gen |

### F3. Proxy deep invariants — 104 (all assertion failures)

The 13 traps dispatch and the essential invariants are enforced, but many
finer invariants and trap-argument details are not:

- `getOwnPropertyDescriptor` result-vs-target consistency (non-configurable /
  non-writable reconciliation).
- `ownKeys` completeness invariants (must include all non-configurable keys;
  no duplicates; extensibility consistency).
- Trap `this` / argument-list exactness ("handler is context", "arguments list
  contains all call arguments").
- `apply`/`construct` trap edge cases; `Proxy.revocable` revoke fn `.name`.
- 47 are "Expected a TypeError to be thrown but no exception" — invariant
  violations we silently allow.

### F4. Class element runtime + direct-eval — 163 area (54 non-parse)

- **30 × direct-eval private/super visibility** — "SyntaxError: eval: invalid
  or unsupported source". `eval("this.#x")` inside a method must see the
  enclosing private names; we only do indirect eval (fresh global scope).
  Architectural: needs direct eval capturing the lexical + private environment.
- **~12 × brand/installation ordering** — "private methods are not installed
  before super returns" etc. In a derived constructor, instance elements must
  be installed *after* `super()` returns; we install them in the prologue.
- **6 ×** "Expected a SyntaxError but got a ReferenceError" — undeclared
  private name should be an early (parse) error, see F2.

### F5. RegExp — 70

- **@@split species** (~27) — `Symbol.split` must construct a fresh sticky
  RegExp via `SpeciesConstructor`; we require a real matcher and don't clone.
- functional-replace / GetSubstitution edge cases, named-group substitution,
  `lastIndex` corner cases on subclasses.

### F6. Smaller runtime buckets

| Area | ~Count | Root cause |
|------|-------:|-----------|
| WeakMap/WeakSet/WeakRef | 39 | mostly symbol-key edge cases + iterator-abrupt handling |
| Reflect | 30 | `ownKeys` ordering, descriptor round-trips, receiver arg to get/set |
| Object | 29 | `defineProperty`/descriptor invariant edges, `getOwnPropertyNames` order |
| BigInt | 23 | `asUintN`/`asIntN` wrap edges, `toString` radix, mixed TypeErrors, `RangeError` on `**` |
| String | 23 | normalize/locale + regex-method delegation edges |
| Array | 20 | `indexOf`/species/holey edge cases |
| arguments-object/mapped | 11 | strict-mode mapping edges, `caller`/`callee` poison |
| tagged-template | 9 | cached template object identity, `.raw` frozen-ness |

---

## Part 2 — Skips (1660)

Skips are tests the runner declines to score. They split into **deliberate**
(unimplemented feature, out of current scope) and **recoverable** (an engine
gap that, once filled, converts the test to pass/fail).

| Reason | Count | Kind |
|--------|------:|------|
| `feature:generators` | 635 | deliberate (denylist) |
| `feature:async-iteration` | 595 | deliberate (denylist) |
| `async/module` | 157 | deliberate (no async/modules) |
| **`parse-gap` (parser rejects)** | 127 | recoverable |
| **`compile-gap` (compiler rejects)** | 73 | recoverable |
| `feature:cross-realm` | 42 | deliberate (no `createRealm`) |
| `missing-include` | 11 | deliberate (unavailable harness helper) |
| `feature:Math.sumPrecise` | 9 | deliberate |
| `feature:Float16Array` | 5 | deliberate |
| `feature:tail-call-optimization` | 3 | deliberate |
| `reference-error` (missing global) | 3 | recoverable (Promise, others) |

Deliberate skips dominate (≈1450): generators, async iteration, async/await
execution, modules, cross-realm, `Math.sumPrecise`, `Float16Array`, TCO — all
denylisted in `runner.zig` as unimplemented subsystems.

### S1. Recoverable: compile-gap (73)

The parser accepts the source but the bytecode compiler rejects a construct:

| Message | Count |
|---------|------:|
| `yield outside generator` | 18 |
| `unsupported statement` | 14 |
| `rest params unsupported` (`function f(...args)`) | 10 |
| `unsupported member target` | 7 |
| `private name is not defined in an enclosing class` | 6 |
| `unsupported expression` | 4 |
| `'super' outside a class method` | 4 |
| `for-of target unsupported` | 3 |
| `unsupported assignment operator` | 3 |
| `invalid number`, `optional chaining unsupported`, … | ≤2 each |

Highest-value: **rest parameters** (`function f(...args)`) — 10 direct skips
plus it unblocks `super(...args)` argument forwarding (see F4) and many
generator/array tests. **`yield outside generator`** (18) is really the lenient
always-parse-`yield` behavior misfiring; a proper generator-context yield would
convert these.

### S2. Recoverable: parse-gap (127)

The parser rejects source it should accept:

| Message | Count |
|---------|------:|
| `unexpected token` | 86 |
| `invalid property key` | 32 |
| `expected property name` | 4 |
| `'yield' is reserved here` | 2 |
| `unexpected keyword in binding` | 2 |

`unexpected token` (86) and `invalid property key` (32) are the grab-bag — need
per-case triage (likely `async` methods, computed/generator method combos,
numeric-separator or other literal forms, optional-chaining shapes).

### S3. Recoverable: reference-error (3)

`Promise`, plus two harness-local names. `Promise` is the only real global gap
here (it's otherwise mostly covered by the async denylist).

---

## Part 3 — Prioritized worklist

Ranked by (tests recovered ÷ effort), cheapest-first:

1. **Escaped property keys/names** (F1) — ~172 fails, one localized decode in
   `parsePropertyKey`/`propNameConst`. **Highest payoff in the whole corpus.**
2. **Rest parameters** (S1) — ~10 skips directly, unblocks `super(...args)`
   forwarding (F4) and more; enables a chunk of currently-skipped tests.
3. **Parser early-errors tail** (F2) — ~90, incremental: dstr-assignment target
   validation, object-shorthand strict reserved, for-in head, undeclared
   private name (needs a parser private-name scope).
4. **RegExp @@split species** (F5) — ~27, self-contained once a
   SpeciesConstructor helper exists.
5. **Proxy deep invariants** (F3) — ~104, but fiddly and case-by-case.
6. **Smaller runtime polish** (F6) — BigInt/Reflect/Object/Array/String edges,
   ~120 spread thin.
7. **Direct-eval private/super visibility** (F4) — ~30, architectural (direct
   eval); defer until an async/module pass reworks scoping anyway.

Deliberate skips (generators, async, modules, cross-realm) are **Phase 5**
subsystems — out of scope for conformance-hardening and correctly denylisted.

---

## How to regenerate

```sh
# in test262/runner.zig set: const trace_files = true;
zig build && ./zig-out/bin/test262 2>&1 | grep -E '^FAILCASE|^SKIPCASE' > /tmp/audit.txt
# then bucket by the third tab-separated field (the reason)
```
