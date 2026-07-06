# A Tier-2 JavaScript Engine in Zig — Phased Architecture

*Exploratory design doc. Target: a spec-faithful bytecode VM (no JIT), driven by Test262, with a clean seam for a JIT later. Modeled on the lessons from QuickJS (small, complete) and LibJS (spec-literal, correctness-first).*

---

## 0. Goals, non-goals, principles

**Goal:** A correct, embeddable ECMAScript engine — lexer → parser → bytecode compiler → bytecode interpreter → runtime — that climbs Test262 conformance steadily and is usable at every phase.

**Non-goals (for now):**
- No JIT / machine-code generation. Everything is interpreted bytecode.
- No Wasm, no full `Intl` (ICU is a huge separate mountain — stub it).
- No browser DOM / host bindings beyond a minimal embedding API.
- Not chasing V8 throughput. Correctness and startup/memory are the wins.

**Principles (steal these directly from LibJS):**
1. **Spec-literal.** Implement ECMAScript abstract operations as functions that mirror the spec's numbered steps, with comments citing the section (e.g. `// 7.2.1 RequireObjectCoercible`). Don't invent semantics — transcribe them.
2. **Test262 is the north star.** Every phase has an exit criterion expressed as a Test262 pass rate on a defined subset. No feature is "done" until its Test262 slice is green.
3. **The JIT is a detachable module, added last (or never).** The interpreter must be a complete, correct engine on its own. LibJS added a JIT and removed it without disturbing the core — design for that seam from day one.
4. **Simplest thing that's correct, then optimize.** Naive GC and slow property lookups first; shapes and generational GC once conformance is high and benchmarks say where it hurts.

---

## 1. Top-level architecture

```
                 ┌─────────────────────────────────────────────┐
 source text ──► │ Lexer ─► Parser ─► AST ─► Bytecode Compiler  │  front end
                 └─────────────────────────────────────────────┘
                                     │ bytecode (per-function)
                                     ▼
                 ┌─────────────────────────────────────────────┐
                 │ Interpreter (bytecode VM)                    │  execution
                 │   ├─ value representation                    │
                 │   ├─ call frames / execution contexts        │
                 │   └─ exception (completion) handling         │
                 └─────────────────────────────────────────────┘
                                     │ operates on
                                     ▼
                 ┌─────────────────────────────────────────────┐
                 │ Runtime                                      │  semantics
                 │   ├─ Object model (shapes/hidden classes)    │
                 │   ├─ Built-ins (Object, Array, String, ...)  │
                 │   ├─ Realm / Agent / Global object           │
                 │   └─ Garbage collector (heap)                │
                 └─────────────────────────────────────────────┘
                                     │ wrapped by
                                     ▼
                 ┌─────────────────────────────────────────────┐
                 │ Embedding API (C ABI + Zig API)              │  host
                 └─────────────────────────────────────────────┘
```

The **JIT seam:** the interpreter dispatches on bytecode ops. A future baseline JIT consumes the *same* bytecode and emits machine code per function, sharing the runtime (objects, GC, ICs) untouched. Keep bytecode as the stable contract between "how we execute" and "what the semantics are."

---

## 2. Cross-cutting design decisions (make these early — they're expensive to change)

### 2.1 Value representation — **tagged union first, NaN-boxing later**
A JS value is `undefined | null | boolean | number(f64) | string | symbol | bigint | object`.

- **Phase-1 choice: Zig tagged union** (`union(enum)`). Dead simple, debuggable, obviously correct. ~16 bytes.
- **Optimization target: NaN-boxing** — pack everything into a 64-bit word using the unused bit patterns of an IEEE-754 NaN, pointers in the payload. Halves memory, improves cache behavior. This is a *representation swap behind an accessor API* — if all value access goes through `Value.isNumber()`, `Value.asObject()` etc., you can switch later without touching the interpreter. **Design the Value API now so the representation is swappable.**

Zig note: `comptime` + a thin accessor struct makes the tagged-union→NaN-box migration a localized change. This is a genuine Zig ergonomic win over doing it in C.

### 2.2 Object model — **property map first, shapes later**
- **Phase-1:** each object holds an ordered hash map of `PropertyKey → PropertyDescriptor`. Correct, slow, easy.
- **Optimization target: shapes / hidden classes** (V8 "maps", JSC "structures"). Objects with the same property layout share a shape; property access becomes an offset lookup. This is *the* single biggest interpreter perf lever and the foundation any future inline caches and JIT need. Introduce it once conformance is high — but keep property access behind an API (`object.get(key)`, `object.defineOwnProperty(...)`) so the internals can change underneath.

### 2.3 Garbage collector — **precise mark-sweep, upgrade path noted**
- **Phase-1:** a simple **precise, stop-the-world mark-sweep** collector. Every heap object is a GC cell with a header; roots come from the VM stack, call frames, and handles. Slow pauses, fine for conformance.
  - Zig note: you're doing manual memory management anyway; a GC is "just" a specialized allocator + tracer. Give every GC-managed type a `trace(self, visitor)` method (spec-literal style: explicit, boring, correct).
  - **Handle discipline from day one.** Native/built-in code that holds a heap pointer across an allocation must root it (a `Handle`/`HandleScope` pattern, like V8). Getting this wrong = the classic "GC moved my object" heisenbug. Decide the rooting convention *before* writing built-ins, not after.
- **Upgrade path:** generational (nursery + old gen) → incremental/concurrent marking → compaction. Each is a real project; none is needed for tier 2. The `trace` interface and handle discipline make these swappable.
- **Decision to make explicitly:** moving vs non-moving collector. Non-moving mark-sweep is simpler and lets native code hold raw pointers more freely; moving/compacting needs handles everywhere but gives better locality and cheap allocation. **Recommendation: start non-moving**, keep handle discipline anyway so a moving collector stays possible.

### 2.4 Strings — **UTF-16 semantics, WTF-16 storage, ropes later**
JS strings are sequences of UTF-16 code units (with lone surrogates allowed → WTF-16).
- **Phase-1:** store as `[]u16`, plus a Latin-1 fast path (most strings are ASCII) to save memory.
- **Optimization targets:** string interning for identifiers/property keys, ropes for cheap concatenation, small-string inlining. Defer all of it.

### 2.5 Exceptions — **Zig error unions carry a "there is a pending exception" signal, value lives in the VM**
The spec models everything as **Completion Records** (`normal | throw | return | break | continue`). Don't model the *thrown value* with Zig's error type (errors can't carry payloads). Instead:
- Abrupt completions return a Zig error like `error.JsException`; the actual thrown JS value sits in a `vm.pending_exception` slot.
- `break`/`continue`/`return` inside bytecode are handled by the compiler emitting jumps, not by propagating completions at runtime — much faster and simpler than literal completion records.
- Keep the spec-literal *naming* (functions named after abstract operations) even though the completion mechanism is optimized. Correctness of *observable behavior*, not literal reproduction of spec data structures.

### 2.6 Bytecode VM shape — **register-based** (recommended)
- **Register-based** (like Ignition/Lua) vs **stack-based** (like JVM/CPython/QuickJS). Register-based tends to mean fewer instructions per operation, less shuffling, and maps more naturally to a future JIT's SSA IR. QuickJS is stack-based and tiny; V8 Ignition is register-based.
- **Recommendation: register-based** with a flat register file per call frame, because the tier-3 future is easier from there. If you want maximum simplicity for phase 1 and don't trust the JIT will ever happen, stack-based is the lower-effort start. Pick now; it colors the compiler and interpreter.

---

## 3. Phases

Each phase ends with a **Test262 gate**: a defined subset run in CI, with a target pass rate. Phases deliberately deliver a *runnable* engine early and often.

### Phase 0 — Skeleton & harness (the boring, decisive part)
- Zig project layout, build graph, `Value` API (tagged union), GC cell header + allocator, `HandleScope` convention.
- A minimal REPL / file runner: read source, (stub) evaluate, print.
- **Test262 harness wired up first, running zero tests but green.** Build the runner that: parses Test262 frontmatter (`flags`, `features`, `includes`, `negative`), loads harness files (`sta.js`, `assert.js`), runs each test in a fresh realm, classifies pass/fail/skip, and emits a scoreboard. This is your speedometer for the entire project — build it before you can even run anything.
- **Exit:** harness runs, reports 0%, CI publishes the number.

### Phase 1 — Lexer + Parser + AST
- Full ECMAScript lexical grammar: tokens, keywords, numeric literals (incl. legacy octal, BigInt `n`, separators), string/template literals, regex literal disambiguation, ASI, Unicode identifiers.
- Recursive-descent parser producing an AST. Cover expressions, statements, functions, classes, destructuring, modules (parse now, link later). Handle the cover-grammar pain points (arrow vs parenthesized expr, async).
- No execution yet — but you can Test262 the **parser** against the `negative: SyntaxError` tests and the "does it parse" corpus.
- **Exit:** parses the vast majority of Test262 sources without crashing; correctly rejects syntax-error tests.

### Phase 2 — Bytecode compiler + interpreter core (the first *real* engine)
- AST → bytecode compiler for the core language: variables (`var`/`let`/`const` + TDZ), scopes/environments, arithmetic & comparison (full abstract-equality + strict-equality semantics), control flow (`if`/loops/`switch`/labeled break-continue via emitted jumps), function declarations & calls, `return`.
- Interpreter dispatch loop (start with a `switch`; computed-goto/tail-call dispatch is a later optimization). Call frames, `this` binding, arguments.
- Minimal object model (property map), minimal built-ins needed to run tests: `Object`, `Function`, `Array` (basics), `%prototype%` chain, `TypeError`/`RangeError`/etc.
- **Exit:** meaningfully passing Test262 language subset (`language/expressions`, `language/statements` slices). First real conformance number that isn't 0.

### Phase 3 — Objects, prototypes, and the semantic core
- Full internal methods: `[[Get]]`, `[[Set]]`, `[[DefineOwnProperty]]`, `[[GetPrototypeOf]]`, property descriptors, getters/setters, `Object.defineProperty`/`freeze`/`seal`, prototype chain walking.
- Coercion abstract operations done spec-literal: `ToPrimitive`, `ToNumber`, `ToString`, `ToPropertyKey`, `OrdinaryToPrimitive`, etc.
- `arguments` object, closures over environments, function `length`/`name`.
- **Exit:** `built-ins/Object`, prototype, and property-descriptor Test262 slices largely green.

### Phase 4 — The built-in library (the long grind that moves the % most)
Implement, spec-literal, the standard library. Each maps to a Test262 directory you can turn green one at a time:
- `Array` (+ iteration protocol), `String`, `Number`, `Boolean`, `Math`, `Symbol`, `RegExp` (needs a regex engine — see 4a), `JSON`, `Date`, `Map`/`Set`/`WeakMap`/`WeakSet`, `Proxy`/`Reflect`, `BigInt`, error types, `TypedArray`/`ArrayBuffer`/`DataView`.
- **4a. Regex engine.** A real subproject: parse the RegExp grammar, compile to a backtracking matcher (Unicode-aware, `u`/`v` flags, property escapes). QuickJS's regex (libregexp) is a good reference for scope. Can be stubbed early and filled in.
- **Exit:** `built-ins/*` climbing steadily; this is where you go from ~40% to ~80%+ overall.

### Phase 5 — Advanced control flow
- **Iterators & generators** (bytecode support for suspend/resume — a real interpreter feature, needs a resumable frame representation).
- **`async`/`await` & Promises** (jobs/microtask queue, the Agent's job queue).
- **Modules**: linking, `import`/`export`, module namespace objects, top-level await.
- `try`/`catch`/`finally` with correct completion semantics, `with` (sloppy mode), `eval` (direct/indirect), strict mode everywhere.
- **Exit:** `built-ins/Promise`, generators, async, and module Test262 slices green.

### Phase 6 — Conformance hardening
- Grind the long tail: annex B legacy semantics, `Function.prototype.toString`, edge cases in coercion, subclassing built-ins, `Symbol.species`/`Symbol.toPrimitive`/well-known symbols everywhere, spec compliance nits Test262 loves.
- Fuzzing (differential against V8/JSC: run random programs, compare output).
- **Exit:** overall Test262 into the **90s %** — LibJS territory, tier-2 done well.

### Phase 7 — Interpreter performance (still no JIT)
- Now that it's correct, make it fast *as an interpreter*: shapes/hidden classes (§2.2), inline caches for property access, computed-goto or tail-call dispatch, NaN-boxing (§2.1), string interning & ropes, generational GC (§2.3), bytecode peephole optimizations.
- Benchmark against V8/JSC on startup + memory (your target wins), and on throughput (accept being 2–10× slower — that's the interpreter tax; it's the JIT's job to close it).
- **Exit:** competitive startup/memory; documented throughput gap that quantifies the JIT's future value.

### Phase 8 (optional / future) — The JIT seam
Not tier 2. But if you built the bytecode as a stable contract and kept the runtime independent, a **baseline JIT** (bytecode → machine code, one-to-few instructions per op, reusing the ICs and GC) is an additive module. Take LibJS's lesson seriously: only build it if a concrete win (throughput for a real workload) justifies the maintenance and cross-architecture cost.

---

## 4. Testing & CI strategy

- **Test262 as the primary gate.** CI runs the defined subset each commit and tracks the pass rate over time (a graph that only goes up is the project's heartbeat). Maintain an explicit **skip/expected-fail list** so regressions are visible and new failures can't hide.
- **Unit tests** for the lexer, parser (AST snapshots), bytecode compiler (disassembly snapshots), and GC (allocation/collection invariants, handle-safety stress tests).
- **Differential fuzzing** (phase 6+): generate programs, run through your engine and V8, diff observable output.
- **`assert.js`/`sta.js` harness compatibility** is table stakes; also support the `$262` host object Test262 uses (`$262.createRealm`, `$262.detachArrayBuffer`, `$262.evalScript`, `$262.gc`).

---

## 5. Risk register (where from-scratch engines die)

| Risk | Mitigation |
|---|---|
| **GC memory-safety bugs** (raw pointer held across allocation) | Handle discipline (§2.3) decided *before* writing built-ins; non-moving GC first; stress tests that GC on every allocation. |
| **Deopt/JIT rabbit hole** | Out of scope for tier 2 by design. Don't start it. LibJS's retreat is the precedent. |
| **Scope creep into `Intl`/Wasm/DOM** | Explicit non-goals (§0). Stub `Intl`; Test262 lets you filter it out by `features`. |
| **Never-runnable engine** (big-bang integration) | Phased delivery: a runnable engine by end of Phase 2, conformance number rising every phase. |
| **Spec drift / guessed semantics** | Spec-literal method (§0). If a Test262 test fails, read the cited spec steps, don't guess. |
| **Boiling the ocean on perf too early** | Perf work is quarantined to Phase 7, *after* correctness. Optimize behind stable APIs (Value, object, GC) so it's localized. |

---

## 6. Reference material to mine

- **ECMAScript spec** (tc39.es/ecma262) — the source of truth; every abstract operation you implement is here.
- **Test262** (github.com/tc39/test262) — the proof. Read `INTERPRETING.md` for the harness contract.
- **QuickJS** (bellard.org/quickjs) — proof one person can build a near-complete engine; great reference for a compact bytecode VM, regex, and BigInt.
- **LibJS** (Ladybird) — the spec-literal method and the JIT-as-detachable lesson; public Test262 dashboard (libjs.dev/test262).
- **Boa** (Rust) — well-documented modern from-scratch engine, Test262-driven; good architectural companion since Rust↔Zig concerns overlap.
- **V8 "Ignition" design docs & Franziska Hinkelmann's talks** — register-based bytecode interpreter design.
- **Crafting Interpreters** (Nystrom) — the clearest intro to bytecode VMs, dispatch, and a simple GC; not JS-specific but the mental model is exactly right for Phases 0–2.

---

## 7. The one-paragraph summary

Build a register-based bytecode VM in Zig, spec-literal in the LibJS tradition, with Test262 wired up on day zero as your speedometer. Deliver a runnable engine by Phase 2 and drive the conformance number up through the built-in library (Phases 3–5) into the 90s (Phase 6), keeping the Value representation, object model, and GC behind stable APIs so that interpreter-level performance (Phase 7) and an eventual optional JIT (Phase 8) are localized, additive changes rather than rewrites. Correctness first, startup/memory as your competitive wins, and the JIT strictly last — and only if a real workload justifies it.
