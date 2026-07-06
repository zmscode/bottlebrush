# Phase 4 — The Built-in Library (+ Regex Engine)

> **Objective:** Implement the standard library, spec-literal, one Test262 directory at a time. This is the long grind that moves the overall conformance number the most — realistically from ~40% into the 80s%.
>
> **Definition of done:** `built-ins/**` climbing broadly; the major constructors and their prototypes green.

---

## 0. Prerequisites
- [ ] Phase 3 object model + abstract operations complete. Iteration protocol helpers ready (or built early here).

## 1. Iteration protocol (do this first — half the library depends on it)
- [ ] `@@iterator` / `@@asyncIterator` well-known symbols; `GetIterator`, `IteratorNext`, `IteratorComplete`, `IteratorValue`, `IteratorStep`, `IteratorClose`, `CreateIterResultObject`.
- [ ] `%IteratorPrototype%`, `%ArrayIteratorPrototype%`, `%StringIteratorPrototype%`, etc.
- [ ] Spread, array destructuring, `for-of` now route through this (revisit Phase 2 lowerings if they short-cut it).

## 2. Constructors & prototypes (each = a Test262 directory to green)
- [ ] **Array:** all prototype methods (`map/filter/reduce/forEach/slice/splice/sort/flat/flatMap/copyWithin/fill/find(Last)(Index)/includes/indexOf/join/concat/reverse/at/…`), `Array.from/of/isArray`, `@@species`, holes/sparse semantics, `length` interactions (lean on Phase 3 `ArraySetLength`). **`sort` correctness + stability** is fiddly — budget for it.
- [ ] **String:** prototype (`slice/substring/substr/indexOf/includes/startsWith/endsWith/pad/repeat/replace(All)/match(All)/search/split/normalize/trim/at/codePointAt/charCodeAt/localeCompare(stub)/…`), `String.fromCharCode/fromCodePoint/raw`, well-formed Unicode methods. Many methods depend on RegExp (§5).
- [ ] **Number / Math / Boolean:** `Number` parse/format (`toFixed/toPrecision/toExponential/toString(radix)`), `Number.is*`, constants; full `Math` (watch `Math.round` half-even-ish rules, `hypot`, `clz32`, `imul`, `fround`); `Boolean` wrapper.
- [ ] **Symbol:** registry (`for`/`keyFor`), well-known symbols wired everywhere, `@@toPrimitive`/`@@toStringTag`/`@@species`/`@@hasInstance`/`@@isConcatSpreadable`/`@@unscopables`.
- [ ] **BigInt:** arithmetic (needs a bignum core — implement or vendor), `asIntN/asUintN`, `toString(radix)`, mixed-type TypeErrors.
- [ ] **JSON:** `parse` (reviver, spec grammar — not just a permissive parser) + `stringify` (replacer array/function, `space`, `toJSON`, cyclic → TypeError, BigInt → TypeError).
- [ ] **Date:** time-clip, parsing (ISO + legacy), `getX/setX` (UTC + local), `toISOString/toJSON/toString` families. Timezone/locale bits can be minimal; core numeric behavior must be right.
- [ ] **Map / Set / WeakMap / WeakSet:** hash by SameValueZero, insertion-order iteration, `@@species`; Weak variants integrate with GC (do **not** keep keys alive — needs GC ephemeron support; coordinate with `gc/heap.zig`).
- [ ] **Reflect:** the 1:1 mirror of internal methods (nearly free given Phase 3).
- [ ] **Proxy:** all 13 traps + invariant checks (`[[Get]]/[[Set]]/has/deleteProperty/ownKeys/getOwnPropertyDescriptor/defineProperty/getPrototypeOf/setPrototypeOf/isExtensible/preventExtensions/apply/construct`); revocable proxies. **Invariant enforcement is the hard, test-dense part.**
- [ ] **Error types:** `Error`/`TypeError`/… `.message`/`.name`/`.stack`(non-standard, minimal), `Error.captureStackTrace`(V8-ism, optional), `AggregateError`, `cause` option, `.stack` format left simple.
- [ ] **ArrayBuffer / SharedArrayBuffer(stub) / DataView / TypedArrays:** the integer-indexed exotic object, all typed-array flavors, `%TypedArray%` shared prototype methods, `set`/`subarray`/`slice`, endianness in DataView, detach semantics (`$262.detachArrayBuffer`), `Atomics`(minimal/stub).

## 3. `globalThis` & global functions
- [ ] `globalThis`, `parseInt`/`parseFloat`, `isNaN`/`isFinite`, `encodeURI(Component)`/`decodeURI(Component)`, `escape`/`unescape` (Annex B), `eval` (direct vs indirect — direct eval needs caller scope; wire carefully), `Function` constructor (parses a program).

## 4. `function*`-free control still — generators/async are Phase 5
- [ ] Anything here needing generators/async (e.g. async iterator helpers) is deferred to Phase 5; stub and skip in Test262.

## 5. Regex engine (`regex/` — a real subproject)
- [ ] **Parser:** RegExp grammar → AST (alternation, quantifiers greedy/lazy, groups: capturing/non-capturing/named, backreferences, lookahead/lookbehind, char classes, `\d\w\s`/negations, boundaries, unicode property escapes `\p{…}`, `.` with/without `s` flag).
- [ ] **Flags:** `g i m s u y d v` — `u`/`v` change parsing & matching (code points, class set ops for `v`), `y` sticky, `d` indices, `m`/`s` anchors/dot.
- [ ] **Compiler + matcher:** backtracking VM (QuickJS `libregexp` is the reference for scope). Capture groups, lastIndex handling.
- [ ] **Integrate:** `RegExp` constructor/prototype (`exec/test/@@match/@@replace/@@split/@@search/@@matchAll`, `source`/`flags`/`lastIndex`), and wire the `String` methods that consume RegExp.
- [ ] Can be **stubbed at phase start** (String methods that need it skip in Test262) and filled mid-phase so the rest of the library isn't blocked.

## 6. Testing
- [ ] Turn `built-ins/<X>/**` green directory-by-directory; keep a checklist of which constructors are "done."
- [ ] Update the expected-fail/skip list as areas complete (regressions become visible).
- [ ] `GC_STRESS=1` everywhere; Weak collections + ephemerons get dedicated GC stress tests.

---

## Exit criteria
- [ ] Major constructors + prototypes green: Object(✓ Phase 3), Array, String, Number, Math, Symbol, JSON, Map/Set/Weak*, Reflect, Proxy, Error family, TypedArray/ArrayBuffer/DataView, BigInt, Date (core), RegExp.
- [ ] Overall Test262 into the ~80s% range.
- [ ] Regex engine passes the bulk of `built-ins/RegExp/**` (property escapes / `v`-flag long tail may remain).

## Notes / risks
- **Biggest time sinks:** RegExp (esp. `u`/`v` + property escapes), Proxy invariants, Array `sort`, TypedArrays, BigInt bignum. Sequence them deliberately; don't let RegExp block everything else.
- Weak collections require **ephemeron** support in the collector — surface that requirement to the GC now, not in Phase 7.
- Prefer breadth of "mostly-correct constructors" then depth, to keep the conformance graph rising steadily and morale high.
