# Phase 6 — Conformance Hardening

> **Objective:** Grind the long tail of correctness until overall Test262 reaches the **90s%** — LibJS territory, "tier-2 done well." No new subsystems; this is systematic bug-killing and edge-case closure, plus differential fuzzing to find what Test262 misses.
>
> **Definition of done:** overall Test262 in the 90s%, a clean/minimal expected-fail list with every remaining failure *categorized and justified* (staged proposal, intentional deviation, host-specific, or ticketed bug).

---

## 0. Prerequisites
- [ ] Phases 1–5 complete: full language + library + async + modules running.

## 1. Triage infrastructure
- [ ] Build a **failure dashboard**: group current failures by directory/feature, sort by count. Attack the biggest buckets first.
- [ ] Every remaining failure gets a label: `bug` (fix it), `proposal` (staged/unshipped → skip by feature), `intentional` (documented deviation), `host` (needs host behavior we stub), `wontfix-tier2` (needs JIT/Intl/Wasm — out of scope).
- [ ] Baseline enforcement tightened: CI fails on ANY new failure in a "done" directory.

## 2. Long-tail correctness areas (typical high-count buckets)
- [ ] **Annex B** legacy semantics: `String.prototype` HTML methods (`anchor`, `big`, …), `RegExp.prototype.compile`, legacy octal escapes, `__proto__` object-literal key, sloppy block-scoped function hoisting, `escape`/`unescape`, `Date.prototype.getYear/setYear/toGMTString`, HTML comments.
- [ ] **`Function.prototype.toString`**: return source text verbatim for user functions; `native code` form for built-ins; correct for bound/proxy/class. Requires the source-span retention from Phase 1.
- [ ] **Well-known symbols everywhere**: audit every place `@@species`, `@@toPrimitive`, `@@toStringTag`, `@@hasInstance`, `@@isConcatSpreadable`, `@@unscopables`, `@@iterator/@@asyncIterator`, `@@match/@@replace/@@search/@@split/@@matchAll` must be consulted. Test262 checks these exhaustively.
- [ ] **Subclassing built-ins**: `class X extends Array/Map/Promise/Error/…` — `@@species`, `[[Construct]]` with `new.target`, `OrdinaryCreateFromConstructor` proto derivation, internal-slot installation on subclass instances.
- [ ] **Coercion edge cases**: `@@toPrimitive` ordering, `valueOf`/`toString` fallbacks, `-0`/`NaN`/`Infinity` formatting, `ToString(number)` corner cases, `parseInt`/`parseFloat` grammar edges.
- [ ] **Property enumeration order** across `for-in`, `Object.keys`, `JSON.stringify`, spread — integer-index ordering + prototype chain `for-in` shadowing/dedup.
- [ ] **Strict vs sloppy** deltas: `this` coercion, poison pills, `arguments` aliasing, assignment to non-writable → TypeError, `delete` of unqualified name, duplicate params.
- [ ] **Error `.message`/`.name`/constructor** exactness where tested; `AggregateError`, error `cause`.
- [ ] **TypedArray/ArrayBuffer** long tail: detached-buffer guards on every operation, `@@species`, out-of-bounds, `%TypedArray%` static/proto completeness, canonical numeric string keys.
- [ ] **RegExp** long tail: `v`-flag set operations, full Unicode property escapes, lookbehind edge cases, `d`-flag indices, `@@replace` with named groups/`$<name>`.
- [ ] **Number/BigInt formatting**: `toFixed/toPrecision/toExponential` rounding, `toString(radix)` for fractions, BigInt radix conversion.

## 3. Differential fuzzing (find what Test262 doesn't cover)
- [ ] Build/adapt a small JS program generator (or use an existing grammar fuzzer corpus).
- [ ] Run each program through **our engine and V8 (and/or JSC)**; diff observable output (result value stringified, thrown error type, console output, property enumeration).
- [ ] Auto-minimize divergences to small repros; file them as `bug` and add regression tests.
- [ ] Also fuzz for **crash-safety** (panics, OOM, infinite loops) with `GC_STRESS=1`.

## 4. Robustness & limits
- [ ] Stack-overflow → `RangeError` (recursion depth guard in interpreter + parser), not a native crash.
- [ ] Deterministic behavior under OOM where the spec requires a throw.
- [ ] Ensure every `unreachable`/`@panic` in hot paths is either provably unreachable or converted to a proper error.

## 5. Testing
- [ ] Full Test262 run (not just slices) tracked; publish the headline % and per-area breakdown.
- [ ] Regression corpus from fuzzing folded into the unit-test suite.
- [ ] Nightly CI: full Test262 + a fuzzing budget (e.g. N minutes) with divergence reporting.

---

## Exit criteria
- [ ] Overall Test262 in the **90s%**.
- [ ] Expected-fail list is small and **every entry is categorized** (`proposal`/`intentional`/`host`/`wontfix-tier2`) — no uncategorized failures.
- [ ] Differential fuzzing runs in CI and finds no new divergences over a defined budget.
- [ ] No native crashes/panics on adversarial input; stack overflow → `RangeError`.

## Notes / risks
- Progress here is measured in fractions of a percent per fix; the dashboard + bucket-by-biggest discipline is what keeps it efficient.
- Differential fuzzing against V8 is the highest-value tool for finding the bugs Test262 misses — invest in the minimizer, it pays for itself.
- Resist the urge to start Phase 7 optimizations to "fix" slowness now — correctness first; perf is quarantined to the next phase behind stable APIs.
