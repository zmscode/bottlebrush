# Phase 5 — Advanced Control Flow: Generators, Async, Modules

> **Objective:** Add the three big control-flow features that need real interpreter support beyond straight-line bytecode: suspendable functions (generators), the job/microtask machinery (Promises/async), and the module system (linking + top-level await).
>
> **Definition of done:** `built-ins/Promise/**`, generator, async-function, and module Test262 slices green.

---

## 0. Prerequisites
- [ ] Phase 4 iteration protocol + library in place (async iterators build on it).

## 1. Resumable frames (the enabling primitive)
- [ ] Design a **suspendable call frame**: a generator/async frame must be heap-allocated (a GC object), capturing register file + instruction pointer + environment so it can be parked and resumed.
- [ ] Bytecode support: `Suspend`/`Resume` (or `Yield`), `Await`, saving/restoring the operand state at a suspend point. The compiler must split functions at suspend points and know which registers are live across them.
- [ ] `trace` the parked frame's registers as GC roots while suspended.

## 2. Generators (`function*`)
- [ ] Generator objects + `%GeneratorPrototype%` (`next`/`return`/`throw`), generator states (`suspendedStart/suspendedYield/executing/completed`), `GeneratorResume(Abrupt)`.
- [ ] `yield` and `yield*` (delegation: forwards `next/return/throw` to the inner iterable, `IteratorClose` on early completion).
- [ ] `for-of`/spread already route through iteration protocol (Phase 4) → generators just work as iterables.

## 3. Jobs & the microtask queue (Agent)
- [ ] `Agent` owns a **job queue** (microtasks). `HostEnqueuePromiseJob`, `RunJobs` drains after each script/module + between turns.
- [ ] Wire the Test262 `async` flag path: the harness's `doneprintHandle`/`$DONE` contract must actually pump the job queue to completion and detect `Test262:AsyncTestComplete`.
- [ ] `queueMicrotask` global.

## 4. Promises
- [ ] `Promise` constructor (executor, `resolve`/`reject` capabilities), states, `PromiseResolveThenableJob`, `FulfillPromise`/`RejectPromise`, `PerformPromiseThen`.
- [ ] Prototype `then`/`catch`/`finally`; statics `resolve`/`reject`/`all`/`allSettled`/`any`(→ `AggregateError`)/`race`/`withResolvers`.
- [ ] `@@species` handling; the exact ordering of reaction jobs (Test262 checks ordering precisely).

## 5. async / await
- [ ] `async function` = generator-like machinery over the Promise job queue: `await` suspends, schedules resumption via a promise reaction.
- [ ] `async` methods, async arrows.
- [ ] **Async generators** (`async function*`) + `@@asyncIterator` + `for await…of`: the async-iterator queue, `%AsyncGeneratorPrototype%`, `%AsyncIteratorPrototype%`. This is the fiddliest combination — its own sub-milestone.

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
- [ ] `built-ins/Promise/**` (ordering-sensitive), `language/statements/generators`, `language/expressions/async-*`, `built-ins/AsyncGeneratorFunction`, `language/module-code/**`.
- [ ] Async harness path validated end-to-end (a failing async test must report, not hang — add a job-queue watchdog/timeout).
- [ ] `GC_STRESS=1` with special attention to parked frames and pending promise reactions (classic root-tracing bugs).

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
