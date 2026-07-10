# Phase 5 — Advanced Control Flow: Generators, Async, Modules

> **Objective:** Add the three big control-flow features that need real interpreter support beyond straight-line bytecode: suspendable functions (generators), the job/microtask machinery (Promises/async), and the module system (linking + top-level await).
>
> **Definition of done:** `built-ins/Promise/**`, generator, async-function, and module Test262 slices green.

---

## 0. Prerequisites
- [x] Phase 4 iteration protocol + library in place (async iterators build on it). **DONE (Phase 4).**

## 1. Resumable frames (the enabling primitive)
- [x] Design a **suspendable call frame**: a generator/async frame must be heap-allocated (a GC object), capturing register file + instruction pointer + environment so it can be parked and resumed. **DONE for generators: `gc.GeneratorState` (heap-owned) holds `regs` + `pc` + `env` + `this`; the generator object references it. (Async frames reuse this once async lands.)**
- [x] Bytecode support: `Suspend`/`Resume` (or `Yield`), `Await`, saving/restoring the operand state at a suspend point. The compiler must split functions at suspend points and know which registers are live across them. **DONE: `gen_yield` implements suspend/resume for yield AND await (its c-flag marks await suspensions); the whole register file is preserved, so no liveness analysis is needed.**
- [x] `trace` the parked frame's registers as GC roots while suspended. **DONE: `Object.trace` marks a suspended generator's `env`, `this_value`, and all `regs`.**

## 2. Generators (`function*`)
- [x] Generator objects + `%GeneratorPrototype%` (`next`/`return`/`throw`), generator states (`suspendedStart/suspendedYield/executing/completed`), `GeneratorResume(Abrupt)`. **DONE: `makeGenerator`/`generatorResume` with start/suspended/executing/completed states; next/return/throw modes; enabled in the runner (+415).**
- [ ] `yield` and `yield*` (delegation: forwards `next/return/throw` to the inner iterable, `IteratorClose` on early completion). **PARTIAL: `yield` and `yield*` value delegation work (for-of/spread over a delegated iterator); `yield*` does NOT yet forward `return`/`throw` into the inner iterator or run `IteratorClose` on early completion. Generator early-errors (yield in labels/params, yield* after newline) are enforced.**
- [x] `for-of`/spread already route through iteration protocol (Phase 4) → generators just work as iterables. **DONE.**

## 3. Jobs & the microtask queue (Agent)
- [x] `Agent` owns a **job queue** (microtasks). `HostEnqueuePromiseJob`, `RunJobs` drains after each script/module + between turns. **DONE: `Vm.jobs` FIFO (cursor-drained, GC-rooted incl. the running job), drained by `run()` after the script — including abrupt completions.**
- [x] Wire the Test262 `async` flag path: the harness's `doneprintHandle`/`$DONE` contract must actually pump the job queue to completion and detect `Test262:AsyncTestComplete`. **DONE: jobs drain inside vm.run, so `$DONE` fires from promise chains; the runner scores by the sentinel.**
- [x] `queueMicrotask` global. **DONE.**

## 4. Promises
- [x] `Promise` constructor (executor, `resolve`/`reject` capabilities), states, `PromiseResolveThenableJob`, `FulfillPromise`/`RejectPromise`, `PerformPromiseThen`. **DONE: `gc.PromiseState` + Vm core ops (settlePromise/resolvePromiseWith/performPromiseThen/promiseResolveValue); thenable assimilation via the thenable job.**
- [x] Prototype `then`/`catch`/`finally`; statics `resolve`/`reject`/`all`/`allSettled`/`any`(→ `AggregateError`)/`race`/`withResolvers`. **DONE (`runtime/builtins/promise.zig`); AggregateError installed with an `errors` array.**
- [x] `@@species` handling; the exact ordering of reaction jobs (Test262 checks ordering precisely). **DONE: NewPromiseCapability + per-pair CreateResolvingFunctions latches; `then` derives via SpeciesConstructor + Promise[@@species]; combinators/statics are `this`/subclass-aware; reactions carry capability fn pairs. built-ins/Promise vendored: 624/729 pass.**

## 5. async / await
- [x] `async function` = generator-like machinery over the Promise job queue: `await` suspends, schedules resumption via a promise reaction. **DONE: `await` compiles to the generator suspension; callAsyncFunction drives the frame (Await = PromiseResolve + PerformPromiseThen with no capability); errors before the first await reject the promise; deep sync-prefix recursion raises RangeError.**
- [x] `async` methods, async arrows, async function **expressions**. **DONE (async arrows reserve `await` in their bodies; lexical `this`). `async function` in expression position was missing entirely — `async` lexes as an identifier, so `parsePrimary` returned it before the `async function` check could run.**
- [x] **Async generators** (`async function*`) + `@@asyncIterator` + `for await…of`: the async-iterator queue, `%AsyncGeneratorPrototype%`, `%AsyncIteratorPrototype%`. This is the fiddliest combination — its own sub-milestone. **DONE: request-queue pump over the shared suspendable frame (gen_yield's c-flag distinguishes await from yield suspensions); next/return/throw return promises; yielded values are awaited; `for await` prefers @@asyncIterator and awaits both step results and sync-wrapped element values. Enabled the async-iteration corpus (+375).**

## 6. Modules
- [ ] **Module records:** `SourceTextModuleRecord`, parse (done Phase 1) → `ParseModule`.
- [ ] **Linking:** `GetExportedNames`, `ResolveExport` (incl. `export *` ambiguity + cycles), `InitializeEnvironment`, module environment records; import/export bindings are *live* (indirect bindings).
- [ ] **Evaluation:** `Link` then `Evaluate`; **top-level await** integrates modules with the promise/job machinery (async module evaluation, `[[AsyncEvaluation]]`, dependency ordering).
- [ ] **Host hooks:** `HostResolveImportedModule`/`HostLoadImportedModule` (module resolution/loading — a minimal filesystem or in-memory resolver for now), `HostGetImportMetaProperties` (`import.meta`), dynamic `import()` returning a promise.
- [ ] `$262.evalScript` vs module evaluation distinction respected by the harness (module-flagged tests run as modules).

## 7. Remaining control-flow semantics
- [ ] `try/catch/finally` interaction with `await`/`yield` (suspend inside `try` must preserve handler state across resume) — dedicated tests.
- [ ] `with` (sloppy) object-environment records finalized; direct `eval` scope injection finalized.

## 8. Testing
- [x] `built-ins/Promise/**` (ordering-sensitive), `language/statements/generators`, `language/expressions/async-*`, `built-ins/AsyncGeneratorFunction`. **DONE — all vendored and running (built-ins/Promise 611/729). `language/module-code/**` waits on §6.**
- [x] Async harness path validated end-to-end (a failing async test must report, not hang — add a job-queue watchdog/timeout). **DONE: the runner scores async tests by the `Test262:AsyncTestComplete` sentinel, and the VM's step budget turns a non-terminating job chain into a `timeout` skip rather than a hang.**
- [x] `GC_STRESS=1` with special attention to parked frames and pending promise reactions (classic root-tracing bugs). **DONE: `zig build test262-stress` (env `GC_STRESS=1`) collects at every allocation safe-point, and `Heap.destroy` poisons dead cells so a surviving reference faults at the use instead of reading whatever the allocator recycles into the slot. The full 6706-file corpus now produces an identical pass/fail set with stress on. Six missed roots found and fixed: iterator elements (`makeIterResult`), a native's callback arguments (now rooted at the `callValue`/`constructValue` boundary), `makeDataDescriptor`'s value, `RegExp[@@split]`'s exec record, promise capability functions + their environments, and an async generator's queued request (shifted off its only root before allocating). Regression tests in `src/tests/stress_tests.zig`; run with `zig build test-stress`.**

---

## Exit criteria
- [ ] Generators (`next/return/throw` + `yield*`) correct; async/await + async generators correct.
- [ ] Promise reaction **ordering** matches spec (Test262 ordering tests green).
- [ ] Modules link + evaluate incl. cycles, live bindings, `import()`, `import.meta`, top-level await.
- [ ] Async Test262 tests complete deterministically (no hangs).

## Notes / risks
- **Suspendable frames + GC** is the deepest engineering in the whole tier-2 project. Design the parked-frame representation carefully; it's load-bearing for generators, async, and async generators simultaneously.
- Promise job **ordering** is exact and heavily tested — implement `PerformPromiseThen`/reaction jobs by the spec steps, not by intuition.
- Module cycles + `export *` ambiguity are subtle; lean on `language/module-code` tests to drive correctness.
