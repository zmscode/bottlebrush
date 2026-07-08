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

### Correctness bugs (ALL FIXED 2026-07-08, same day as the audit)
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
5. ~~**Strict mode does not exist**~~ **FIXED 2026-07-08**: "use strict"
   directive threaded compiler→CodeBlock; strict semantics in the VM
   (undeclared-global assignment ReferenceError, read-only write TypeError,
   delete-failure TypeError, uncoerced `this`; sloppy nullish `this` now
   correctly coerces to globalThis). The harness runs the spec dual-run
   (sloppy + strict per non-flagged file) — and the score *rose* under it.
6. ~~**`$262` host object**~~ **FIXED 2026-07-09**: `Vm.installHost262`
   (runner realms only) provides `global`, `evalScript` (same-realm,
   indirect-eval scoping), `gc` (forced collection), and
   `detachArrayBuffer` (typed-element reads/writes guard the detached
   state). `createRealm` needs per-realm intrinsics — `cross-realm`
   feature tests skip via the denylist instead.
7. ~~**Destructuring**~~ **FIXED 2026-07-08**: array/object patterns lower
   everywhere — declarations, parameters (incl. whole-pattern defaults),
   assignment expressions (incl. member targets), for-of/for-in heads, catch
   params; iterator-protocol based; nested; defaults; array rest. Object
   rest landed later the same day via the `copy_rest` op
   (CopyDataProperties with runtime excluded-keys), which also powers
   object literal spread; literal accessors compile too.
8. ~~**Classes and template literals**~~ **FIXED 2026-07-08**: classes lower
   to constructor functions — decl/expr forms, methods (non-enumerable via
   `def_prop`/`def_elem`), static members, get/set accessors (via runtime
   defineProperty), `extends` with both prototype chains wired,
   `super(...)`/`super.m(...)`/`super.x` through synthetic captured
   bindings, implicitly strict bodies. Class FIELDS also landed: instance
   fields initialize in the constructor prologue (declaration order,
   `this`-referencing initializers, per-instance values); static fields
   evaluate at class creation with `this` = the constructor. Private
   (#name) members still unsupported — the dominant remaining fail
   cluster. Templates: untagged (string-seeded concat) and tagged (strings
   array + `.raw` + substitutions).
9. ~~**Mapped `arguments`**~~ **FIXED 2026-07-08**: sloppy functions with
   simple parameter lists get mapped arguments — indices alias the
   parameter env slots both directions (`args_env` + `args_map` bitmask on
   the object, capped at 64 params); `delete` and
   defineProperty-with-accessor-or-writable:false sever the alias (value
   redefinitions write through); strict or non-simple-param functions stay
   unmapped.
10. ~~**`[[SetPrototypeOf]]`**~~ **FIXED 2026-07-08**: Object.setPrototypeOf
    with cycle check + `__proto__` accessor; Object.assign/is/hasOwn/
    fromEntries/getOwnPropertyDescriptors added.
11. ~~**Well-known symbols are inert**~~ **FIXED 2026-07-08**:
    @@toPrimitive (with hints), @@toStringTag (plus builtin tags), and
    @@hasInstance are consulted; RegExp.prototype implements
    @@match/@@replace/@@search/@@split and the String methods dispatch
    through them (object patterns only, per spec — primitives never
    consult the symbol). Runner denylist no longer skips Symbol features.
12. ~~**BigInt is an i64 stub**~~ **FIXED 2026-07-09**: real arbitrary
    precision via std.math.big (limbs on the gc.BigInt cell). Literals
    (incl. 0x/0o/0b), full arithmetic (`/` and `%` truncate, `**`,
    division-by-zero RangeError), bitwise ops, signed shifts (negative
    counts reverse direction), `~`/unary `-`, mixed-type TypeErrors,
    loose == across Number/String/boolean (exactness-aware), relational
    compares, `BigInt()`/`asIntN`/`asUintN`, `toString(radix)`,
    @@toStringTag, explicit `Number(bigint)`, JSON TypeError. BigInt off
    the runner denylist.
13. ~~**WeakMap/WeakSet**~~ **FIXED 2026-07-09**: GC ephemeron semantics —
    weak collections skip strong-marking their entries; `Heap.collect`
    runs a mark fixpoint (values live only while keys live) and clears
    dead entries on survivors before the sweep. WeakMap
    get/set/has/delete, WeakSet add/has/delete, WeakRef deref (cleared
    when the referent dies). Verified under GC stress.
14. ~~**Proxy invariants**~~ **MOSTLY FIXED 2026-07-09**: 13 trap sites
    dispatch (added deleteProperty, defineProperty,
    getOwnPropertyDescriptor, ownKeys, getPrototypeOf, setPrototypeOf,
    isExtensible, preventExtensions to the existing 5), with the
    essential invariants: get pins non-configurable non-writable values,
    has can't hide non-configurable props, deleteProperty can't claim
    them deleted, isExtensible must match the target, falsy
    set/defineProperty/preventExtensions/setPrototypeOf results throw.
    Proxy.revocable + revoked-proxy TypeErrors everywhere. Deep ownKeys
    invariant checks remain simplified.
15. **Regex `u`/`v` modes** — flags accepted but matching is code-unit based;
    no `\p{…}`.
16. **No file runner / REPL** — `main.zig` still runs a fixed demo.

*(The "also missing but small" Array/String method tail below was also filled
on 2026-07-08: 21 Array methods + Array.from/of, 9 String methods +
String.fromCodePoint.)*

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
