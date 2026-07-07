# Phase 0 — Skeleton & Test262 Harness

> **Objective:** Stand up the Zig project, the core memory/value primitives, and — most importantly — a working Test262 harness that reports **0%** in CI. This phase produces almost no JS behavior; it produces the *speedometer* and the scaffolding every later phase leans on.
>
> **Definition of done:** `zig build test262` runs, executes a real (filtered) slice of Test262, classifies every result as pass/fail/skip, prints a scoreboard, and CI publishes the number. It will say ~0% pass. That is success.

---

## 0. Prerequisites
- [x] Rust/Metal toolchain is irrelevant here — this is a standalone Zig project. Pin a Zig version (`.zigversion` / note in README). Use a recent stable Zig.
- [x] Decide repo location (this is currently living in bottlebrush; a dedicated repo is cleaner long-term).
- [x] Clone `github.com/tc39/test262` as a submodule or vendored checkout at a pinned commit. Read its `INTERPRETING.md` end to end before writing the harness. *(deviation: sparse-vendored slices at `test262/fixtures/vendored/` instead of a submodule — works well)*

## 1. Project layout
- [x] `build.zig` + `build.zig.zon` with steps: `run` (REPL/file runner), `test` (unit tests), `test262` (conformance runner).
- [x] Source tree skeleton (empty stubs, they fill in later phases): *(deviation: flat `src/`; no `gc/`/`runtime/` dirs, no `embed.zig`)*
  ```
  src/
    main.zig            # CLI entry: run file / REPL
    value.zig           # Value type + accessor API   (§2)
    gc/
      heap.zig          # allocator + cell header      (§3)
      handle.zig        # HandleScope / rooting         (§3)
    lexer.zig           # (Phase 1 stub)
    parser.zig          # (Phase 1 stub)
    ast.zig             # (Phase 1 stub)
    bytecode.zig        # (Phase 2 stub)
    interpreter.zig     # (Phase 2 stub)
    runtime/
      object.zig        # (Phase 2/3 stub)
      realm.zig         # (Phase 2 stub)
    embed.zig           # C ABI + Zig embedding API (stub)
  test262/
    runner.zig          # the harness (THIS PHASE)
    frontmatter.zig
    report.zig
  ```

## 2. Value type (the API that must not change; representation can)
- [x] Define `Value` as a **tagged union** (`undefined, null, boolean, f64, string, symbol, bigint, object`).
- [x] Write the **accessor API** now — everything downstream uses only this, never the union fields directly:
  - [x] predicates: `isUndefined/isNull/isBoolean/isNumber/isString/isSymbol/isBigInt/isObject/isNullish`
  - [x] constructors: `Value.number(f64)`, `Value.boolean(bool)`, `Value.object(*Object)`, `Value.undefined()`, `Value.null()` …
  - [x] extractors: `asNumber() f64`, `asObject() *Object`, `asString() *String` …
  - [x] `eql` (SameValueZero / SameValue helpers stubbed; real semantics later)
- [x] Add a doc comment: "Representation is swappable to NaN-boxing in Phase 7. Do not access fields outside this file."

## 3. GC foundation (correct-but-slow; the interface is what matters)
- [x] `GcHeader`: mark bit, type tag/kind, size, intrusive free/sweep list link.
- [x] `Heap`: bump/free-list allocator over Zig allocator; `alloc(comptime T)` returns a rooted-safe pointer.
- [x] **Tracing interface:** every heap type exposes `fn trace(self, *Visitor) void`. Define `Visitor` (marks a `Value`/cell). Stub for now; types implement it as they're born.
- [x] **Rooting: `HandleScope` + `Handle(T)`.** Decide and document the convention NOW (before any built-in exists): *(handle.zig exists; in practice the VM roots via `temp_roots` protect/unprotect)*
  - [x] roots = VM value stack + call frames + active `HandleScope`s.
  - [x] Rule (write it in `handle.zig` header): *native code must not hold a raw cell pointer across an allocation; wrap it in a `Handle`.*
- [x] `collect()`: stop-the-world mark-sweep. Mark from roots via `trace`, sweep unmarked. No generations, no compaction.
- [x] **Stress mode:** env/flag `GC_STRESS=1` → collect on *every* allocation. This is your single best bug-catcher for the whole project; wire it in now. *(✓; plus allocation-triggered GC with 2x growth added later)*

## 4. Test262 harness (the real deliverable)
- [x] **Frontmatter parser** (`frontmatter.zig`): parse the `/*--- ... ---*/` YAML block → `flags` (`onlyStrict`, `noStrict`, `module`, `raw`, `async`, `CanBlockIsFalse`…), `features`, `includes`, `negative` (`phase`, `type`), `es5id`/`es6id`/`esid`.
- [x] **Harness file loader:** always prepend `harness/assert.js` + `harness/sta.js` (unless `raw`); load `harness/<include>.js` for each `includes:` (e.g. `propertyHelper.js`, `compareArray.js`, `doneprintHandle.js`).
- [x] **Runner (`runner.zig`):** for each test file →
  - [ ] compute the run variants: `onlyStrict` → strict only; `noStrict` → sloppy only; neither → run **both** (prepend `"use strict";` for the strict variant). **← GAP: engine has no strict mode; tests run once (sloppy); `onlyStrict` prepends a directive the engine ignores**
  - [x] fresh realm per test (realm is a stub now; interface exists).
  - [x] execute; capture thrown value / uncaught error.
  - [x] **classify:**
    - `negative` test → PASS iff it throws the expected error type at the expected phase (parse vs runtime).
    - normal test → PASS iff it completes with no exception.
    - engine can't-yet-run (unimplemented) → **SKIP** with reason, not FAIL.
  - [ ] `async` flag → wait for `print('Test262:AsyncTestComplete')` sentinel via the `doneprintHandle` harness contract (stub the print hook now). *(deferred with async to Phase 5)*
- [ ] **`$262` host object** (stub methods, real later): `$262.createRealm`, `$262.evalScript`, `$262.detachArrayBuffer`, `$262.gc`, `$262.global`, `$262.agent`. **← GAP: `$262` absent; dependent tests skip/fail**
- [x] **Filtering:** CLI flags to run a subdir (`--path language/types`), by feature include/exclude, and an **expected-fail / skip list file** (so known-unimplemented areas don't spam FAIL). *(partial: directory arg ✓; feature denylist is in-code, no skip-list file)*
- [x] **Reporting (`report.zig`):** totals + per-directory pass/fail/skip counts; machine-readable JSON output for CI to chart over time; non-zero exit on *regression* vs a committed baseline (not on absolute failures). *(partial: totals + JSON + CI regression ✓; no per-directory counts)*

## 5. CLI & REPL
- [ ] `main.zig`: `engine run file.js`, `engine` (REPL). Evaluation is a stub that returns `undefined`; wire the plumbing (read → [stub eval] → print). **← GAP: main.zig runs a fixed demo; no file runner/REPL**

## 6. CI
- [x] GitHub Actions (or chosen CI): build, `zig build test`, `zig build test262 --path <small slice>`, upload the JSON scoreboard as an artifact, fail on regression against baseline.
- [x] Commit an initial `baseline.json` (everything skipped/failing → 0% pass). **This graph only goes up from here.**

---

## Exit criteria (all must hold)
- [x] `zig build` clean; `zig build test` green (harness unit tests).
- [x] `zig build test262` runs a real Test262 slice, prints a scoreboard, reports ~0% pass with the rest **skipped, not errored**.
- [x] `GC_STRESS=1` runs without crashing on the (trivial) code paths that exist.
- [x] CI publishes the conformance number and fails on regression.

## Notes / risks
- Resist implementing any language feature this phase. The temptation is huge; the payoff of a trustworthy harness first is bigger.
- The hardest correctness work all project-long is GC rooting. Getting `HandleScope` and `GC_STRESS` in *now* means every later phase is validated against use-after-GC from birth.
