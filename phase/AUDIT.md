# Retrospective audit — Phases 0–4 (2026-07-08)

Cross-check of `phase/phase-{0..4}/plan.md` against the actual code at commit
`4ef1410`. Checkboxes in each plan are now ticked with inline annotations;
this file is the consolidated view. Conformance at audit time: **1331 pass /
153 fail / 88 skip over 1572 vendored files (84.67% of all, 89.69% of
executed)**, 110/110 unit tests, corpus wall time ~0.5 s.

## Scoreboard

| Phase | Ticked | Flagged gaps | Verdict |
|---|---|---|---|
| 0 — Skeleton & harness | 34/38 | 4 | Done, with harness-fidelity gaps |
| 1 — Lexer/parser/AST | 29/33 | 4 | Done for the sloppy-mode grammar |
| 2 — Bytecode + interpreter | 38/41 | 3 | Done, **one real correctness bug** |
| 3 — Object model | 25/28 | 3 | Done, spec-literal shortcuts noted |
| 4 — Built-in library + regex | 27/29 | 2 | Done to exit criteria (80s% band) |

## The 16 flagged gaps, by severity

### Correctness bugs (fix before they bite)
1. **`finally` skips abrupt completions** (`compiler.zig` `compileTry`): it only
   runs on the normal path — `throw`/`return`/`break`/`continue` bypass it.
   Phase 2's plan explicitly called this "the one place literal-ish completion
   handling is worth it." Highest-priority carry-over.
2. **TDZ not enforced** — `let`/`const` behave like `var`. The bytecode has
   `init_var` reserved for it; the checks were never emitted.
3. **`ValidateAndApplyPropertyDescriptor` missing** — `Object.defineProperty`
   replaces descriptors blindly; non-configurable invariants are not enforced.
4. **`Number("0x10")` → NaN** — the ToNumber string grammar lacks hex/octal/
   binary forms.

### Missing subsystems (deliberate, now explicit)
5. **Strict mode does not exist** — not tracked in parser, compiler, or VM.
   This also blocks the harness's strict/sloppy dual-run (each non-flagged
   Test262 file should run twice; we run once, sloppy).
6. **`$262` host object** absent (createRealm/evalScript/detachArrayBuffer/gc).
7. **Destructuring** — parses, compiler rejects everywhere (params, targets).
8. **Classes and template literals** — parse but do not compile.
9. **Mapped `arguments`** — plain object; no parameter aliasing, no strict
   variant.
10. **`[[SetPrototypeOf]]`** — no `Object.setPrototypeOf`, no `__proto__`
    accessor, no cycle check. Also missing Object statics: `assign`,
    `fromEntries`, `is`, `hasOwn`, `getOwnPropertyDescriptors`.
11. **Well-known symbols are inert** — they exist as values but the engine
    never consults `@@toPrimitive`/`@@toStringTag`/`@@hasInstance`/`@@match`/….
12. **BigInt is an i64 stub** — no bignum, no `asIntN`, no mixed-type errors.
13. **WeakMap/WeakSet** — need GC ephemeron support.
14. **Proxy invariants** — 5 of 13 traps dispatch; no invariant checks.
15. **Regex `u`/`v` modes** — flags accepted but matching is code-unit based;
    no `\p{…}`.
16. **No file runner / REPL** — `main.zig` still runs a fixed demo.

### "Falsely missed" (plan says missing, actually done)
None the other way — but until today **all 169 boxes read as unticked** while
~90% of the work was done. Notable items the plans undersold: the array
representation exceeds the plan (V8-style holes + dictionary mode was a
Phase 7 idea), the runner is multithreaded (never planned), the GC gained
allocation-triggered collection (planned for Phase 7), and bilby implements
lookbehind (many production engines shipped without it for years).

### Also missing but small (unflagged in plans)
Array: `splice/sort/reverse/reduce(Right)/find*/some/every/shift/unshift/
fill/copyWithin/flat(Map)/at/lastIndexOf`, `Array.from/of`, `@@species`.
String: `padStart/End/at/codePointAt/replaceAll/matchAll/substr/normalize/
trimStart/End`, `String.fromCodePoint/raw`. Date: legacy parse formats.
Error: `cause`, `AggregateError`, `stack`. `escape`/`unescape`. Reporting:
per-directory pass/fail counts.

## Recommended order of attack (pre/with Phase 5)
1. `finally` abrupt-completion correctness (small, self-contained, real bug).
2. TDZ enforcement (compiler emits checks; op already reserved).
3. Strict mode threading (parser directive → CodeBlock flag → VM behaviors) —
   unlocks the harness dual-run and dozens of deferred semantics.
4. Destructuring lowering (params + assignment) — biggest remaining
   language-surface gap; blocks many Phase 5 tests too.
5. ValidateAndApplyPropertyDescriptor + setPrototypeOf + Object statics batch.
6. Well-known symbol dispatch (@@toPrimitive/@@toStringTag first).
7. The Array/String method tail (mechanical, an afternoon).

---

# Code structure assessment

## Current shape

| File | Lines | Role |
|---|---|---|
| `src/interpreter.zig` | **7,192** | VM + object model + **all built-ins** + coercions + JSON + Date + ~90 tests |
| `src/parser.zig` | 1,617 | fine |
| `src/compiler.zig` | 1,502 | fine |
| `bilby/src/regex.zig` | 1,145 | fine (self-contained engine) |
| everything else | ≤ 736 each | fine |

`interpreter.zig` is half the project and growing ~1,000 lines per feature
batch. It currently mixes five concerns: (1) the dispatch loop + frames,
(2) the object model's abstract operations (get/set/define/delete/enumerate),
(3) coercions (ToNumber/ToString/ToPrimitive…), (4) ~150 native built-ins
across 15 constructors, (5) the realm bootstrap (`installBuiltins`).

## Verdict: yes — split it, but along runtime seams, not file size

The original Phase 0 plan already prescribed the shape (`runtime/` dir); we
drifted away from it because Zig makes single-file growth frictionless. The
natural cut lines, in dependency order:

```
src/
  interpreter.zig   → keeps: Vm struct, dispatch loop, frames, call/construct,
                      exceptions, generators, register slabs, GC rooting  (~1.5k)
  runtime/
    abstract.zig    → coercions + spec AOs: toNumber/toString/toPrimitive,
                      sameValue*, lengthOfArrayLike, hasProperty…           (~600)
    object.zig      → property get/set/define/delete/enumerate, descriptors,
                      orderedOwnKeys, array element storage (fast/dict)     (~1k)
    realm.zig       → installBuiltins + intrinsics wiring                   (~700)
    builtins/
      object.zig, array.zig, string.zig, number.zig, json.zig,
      date.zig, regexp.zig, collections.zig (Map/Set), typedarray.zig,
      reflect_proxy.zig, global.zig (eval/parseInt/URI…)                    (~300–600 each)
  tests moved beside their subjects (Zig `test` blocks travel with the code).
```

Mechanics that make this cheap in Zig:
- The natives are already free functions taking `(*anyopaque, this, args)` —
  they move verbatim; only `castVm`/helpers need a shared import.
- A `runtime/internal.zig` can re-export the Vm + helper surface the builtins
  need (`protect`, `defineData`, `makeString`, `argAt`…), so builtin files
  import one thing.
- No behavior change, so the Test262 number is the regression harness for the
  refactor itself: 1331 before, must be 1331 after.

**When:** before Phase 5, not during. Async/generators touch the dispatch
loop; landing the split first means Phase 5 edits ~1.5k-line files instead of
7k. Estimated effort: one focused session, mostly mechanical moves.

**bilby:** leave as one file. It is a complete, coherent engine at 1,145
lines with its own test suite — splitting it would add imports, not clarity.
