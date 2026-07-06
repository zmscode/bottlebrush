# Phase 7 — Interpreter Performance (still no JIT)

> **Objective:** Now that the engine is *correct* (90s% Test262), make it *fast as an interpreter*. Every optimization here lands **behind the stable APIs** (Value, object, GC) established earlier, so it's localized and validated by the existing conformance suite — the number must not drop.
>
> **Definition of done:** competitive **startup + memory** vs V8/JSC (your target wins), throughput gap vs V8 measured and documented (interpreter tax, ~2–10×), Test262 % unchanged, all optimizations gated by benchmarks.

---

## 0. Prerequisites
- [ ] Phase 6 done: 90s% conformance, stable Value/object/GC APIs, differential fuzzing in CI.
- [ ] **Benchmark harness first** (see §1) — never optimize without a before/after number.

## 1. Measurement infrastructure (do this before any optimization)
- [ ] Benchmark suite: microbenchmarks (property access, arithmetic loops, function calls, string ops, allocation) + macro (SunSpider/Kraken/Octane-style, a few real scripts).
- [ ] Track three axes separately: **startup latency**, **peak memory**, **throughput**. Your competitive story is startup+memory; throughput is where you accept the interpreter tax.
- [ ] Baseline vs V8 and JSC on the same machine. Commit numbers; CI perf-regression guard on the microbenchmarks.
- [ ] Profiling wired up (perf/Instruments/`poop`); optimize what the profile says, not what you assume.

## 2. Object model — shapes / hidden classes (the biggest single lever)
- [ ] Introduce **Shape** (a.k.a. hidden class / map / structure): objects with the same property layout + attributes share a Shape; each Shape maps `PropertyKey → (offset, attributes)`.
- [ ] **Shape transition tree:** adding a property transitions to a child Shape (cached), so identical construction sequences converge on the same Shape.
- [ ] Store data properties in a flat **slot array** on the object; Shape gives the offset. Dictionary/megamorphic fallback for pathological objects (many deletes, huge/unique layouts).
- [ ] Preserve exact semantics from Phase 3 (`OrdinaryOwnPropertyKeys` order, descriptor attributes, `defineProperty` corner cases) — Test262 is the guardrail; % must not drop.

## 3. Inline caches (build on shapes)
- [ ] **IC slots** in the bytecode for `GetProp`/`SetProp`/`GetGlobal`: cache `(Shape, offset)`; monomorphic → polymorphic (small set) → megamorphic (fall back to full lookup).
- [ ] IC for method calls / prototype-chain lookups; invalidation on Shape change / prototype mutation.
- [ ] This is also the exact machinery a future JIT would reuse — designing it well here is the tier-3 down payment.

## 4. Value representation — NaN-boxing
- [ ] Swap the tagged union for **NaN-boxing** behind the Value accessor API (unchanged call sites — the payoff of the Phase 0 discipline).
- [ ] Verify no regression via Test262 + benchmarks; measure the memory/throughput delta.

## 5. Interpreter dispatch
- [ ] Replace the `switch` dispatch with **computed-goto / tail-call threading** (Zig: labeled continue on a jump table, or `@call(.always_tail, ...)` continuation style). Measure — the win varies by CPU/branch predictor.
- [ ] **Bytecode peephole / superinstructions:** fuse common op pairs (e.g. `LoadConst`+`Add`, `GetLocal`+`Call`) to cut dispatch overhead.
- [ ] Register-allocation improvements in the compiler (reduce `Mov`s, reuse temporaries) now that correctness is locked.
- [ ] Consider caching `ToNumber`/`ToString` fast paths for the common (already-primitive) cases.

## 6. Strings
- [ ] **Interning** for identifiers/property keys (pointer-equality key compares → faster Shape lookups).
- [ ] **Ropes / cons-strings** for cheap concatenation; flatten lazily on access.
- [ ] **Small-string inlining** + Latin-1 vs UTF-16 storage split (most strings are ASCII).

## 7. Garbage collector — generational
- [ ] Add a **nursery (young gen)** with bump allocation + fast minor collections; promote survivors to the mark-sweep old gen.
- [ ] **Write barrier** for old→young references (remembered set). Keep the `trace` interface and handle discipline (the API that made this swappable).
- [ ] Optional later: incremental/concurrent marking to cut pause times (your **latency** competitive angle vs V8). Compaction is a bigger step — defer unless memory fragmentation shows up in profiles.
- [ ] Validate relentlessly under `GC_STRESS=1` + differential fuzzing; a GC bug here is the worst kind.

## 8. Startup & memory (the competitive wins — prioritize these)
- [ ] **Lazy compilation:** parse/compile functions on first call, not eagerly (pre-parse for early errors only). Big startup + memory win.
- [ ] **Snapshot / lazy intrinsics:** avoid building the full intrinsic graph eagerly; or snapshot a pre-built realm.
- [ ] Shrink per-object and per-function memory (Shapes already help a lot); measure RSS on a realistic workload vs V8/JSC and make that number the headline.

## 9. Testing & guardrails
- [ ] **Test262 % must not regress** after any optimization — it's the correctness ratchet.
- [ ] Perf CI: microbenchmark regression guard; periodic macro-benchmark tracking vs V8/JSC.
- [ ] Continue differential fuzzing (optimizations, esp. ICs/shapes/GC, are prime sources of subtle miscompiles).

---

## Exit criteria
- [ ] Startup latency and peak memory **competitive with or better than V8** on the benchmark suite (the intended wins).
- [ ] Throughput gap vs V8 measured and documented (expected ~2–10× — this is the interpreter tax and quantifies the JIT's future value).
- [ ] Shapes + inline caches + NaN-boxing + generational GC landed with **no Test262 regression**.
- [ ] Every optimization has a committed before/after number.

## Notes / risks
- **Order matters:** shapes → inline caches → NaN-boxing → dispatch → GC. Shapes unlock ICs; do them first.
- The dangerous optimizations for correctness are ICs, shapes, and the generational GC/write barrier — lean hard on Test262 + fuzzing after each.
- This phase ends tier 2. The ICs/shapes/bytecode you built here are precisely the substrate a **Phase 8 baseline JIT** would reuse — but only build that if a concrete workload justifies the cost (per the LibJS lesson). Tier 2, done well, is a real and shippable engine on its own.
