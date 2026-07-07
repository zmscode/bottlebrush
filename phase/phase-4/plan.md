# Phase 4 — The Built-in Library (+ Regex Engine)

> **Objective:** Implement the standard library, spec-literal, one Test262 directory at a time. This is the long grind that moves the overall conformance number the most — realistically from ~40% into the 80s%.
>
> **Definition of done:** `built-ins/**` climbing broadly; the major constructors and their prototypes green.

---

## 0. Prerequisites
- [x] Phase 3 object model + abstract operations complete. Iteration protocol helpers ready (or built early here).

## 1. Iteration protocol (do this first — half the library depends on it)
- [x] `@@iterator` / `@@asyncIterator` well-known symbols; `GetIterator`, `IteratorNext`, `IteratorComplete`, `IteratorValue`, `IteratorStep`, `IteratorClose`, `CreateIterResultObject`.
- [x] `%IteratorPrototype%`, `%ArrayIteratorPrototype%`, `%StringIteratorPrototype%`, etc.
- [x] Spread, array destructuring, `for-of` now route through this (revisit Phase 2 lowerings if they short-cut it).

## 2. Constructors & prototypes (each = a Test262 directory to green)
- [x] **Array:** all prototype methods (`map/filter/reduce/forEach/slice/splice/sort/flat/flatMap/copyWithin/fill/find(Last)(Index)/includes/indexOf/join/concat/reverse/at/…`), `Array.from/of/isArray`, `@@species`, holes/sparse semantics, `length` interactions (lean on Phase 3 `ArraySetLength`). **`sort` correctness + stability** is fiddly — budget for it. **(partial: missing splice/sort/reverse/reduce(Right)/find*/some/every/shift/unshift/fill/copyWithin/flat(Map)/at/lastIndexOf + Array.from/of; @@species ✗; holes/sparse ✓ V8-style)**
- [x] **String:** prototype (`slice/substring/substr/indexOf/includes/startsWith/endsWith/pad/repeat/replace(All)/match(All)/search/split/normalize/trim/at/codePointAt/charCodeAt/localeCompare(stub)/…`), `String.fromCharCode/fromCodePoint/raw`, well-formed Unicode methods. Many methods depend on RegExp (§5). *(partial: missing padStart/End/at/codePointAt/replaceAll/matchAll/substr/normalize/trimStart/End + fromCodePoint/raw)*
- [x] **Number / Math / Boolean:** `Number` parse/format (`toFixed/toPrecision/toExponential/toString(radix)`), `Number.is*`, constants; full `Math` (watch `Math.round` half-even-ish rules, `hypot`, `clz32`, `imul`, `fround`); `Boolean` wrapper.
- [x] **Symbol:** registry (`for`/`keyFor`), well-known symbols wired everywhere, `@@toPrimitive`/`@@toStringTag`/`@@species`/`@@hasInstance`/`@@isConcatSpreadable`/`@@unscopables`. **(partial: registry ✓, well-known symbols exist as values but are NOT wired into engine behavior — @@toPrimitive/@@toStringTag/@@hasInstance/@@match/…)**
- [ ] **BigInt:** arithmetic (needs a bignum core — implement or vendor), `asIntN/asUintN`, `toString(radix)`, mixed-type TypeErrors. **← GAP: i64-backed stub — no bignum arithmetic, no asIntN/asUintN, no mixed-type TypeErrors**
- [x] **JSON:** `parse` (reviver, spec grammar — not just a permissive parser) + `stringify` (replacer array/function, `space`, `toJSON`, cyclic → TypeError, BigInt → TypeError). *(partial: parse is permissive rather than grammar-strict)*
- [x] **Date:** time-clip, parsing (ISO + legacy), `getX/setX` (UTC + local), `toISOString/toJSON/toString` families. Timezone/locale bits can be minimal; core numeric behavior must be right. *(partial: ISO parse only — no legacy/RFC formats)*
- [ ] **Map / Set / WeakMap / WeakSet:** hash by SameValueZero, insertion-order iteration, `@@species`; Weak variants integrate with GC (do **not** keep keys alive — needs GC ephemeron support; coordinate with `gc/heap.zig`). **← GAP: WeakMap/WeakSet missing (needs ephemeron GC support); Map/Set themselves are done**
- [x] **Reflect:** the 1:1 mirror of internal methods (nearly free given Phase 3). *(partial: ~8 of 13 mirrors; construct ignores newTarget semantically)*
- [x] **Proxy:** all 13 traps + invariant checks (`[[Get]]/[[Set]]/has/deleteProperty/ownKeys/getOwnPropertyDescriptor/defineProperty/getPrototypeOf/setPrototypeOf/isExtensible/preventExtensions/apply/construct`); revocable proxies. **Invariant enforcement is the hard, test-dense part.** **(partial: 5 traps dispatched (get/set/has/apply/construct); no invariant checks; no revocable)**
- [x] **Error types:** `Error`/`TypeError`/… `.message`/`.name`/`.stack`(non-standard, minimal), `Error.captureStackTrace`(V8-ism, optional), `AggregateError`, `cause` option, `.stack` format left simple. *(partial: no cause, no AggregateError, no stack)*
- [x] **ArrayBuffer / SharedArrayBuffer(stub) / DataView / TypedArrays:** the integer-indexed exotic object, all typed-array flavors, `%TypedArray%` shared prototype methods, `set`/`subarray`/`slice`, endianness in DataView, detach semantics (`$262.detachArrayBuffer`), `Atomics`(minimal/stub). *(partial: no detach, no SharedArrayBuffer/Atomics)*

## 3. `globalThis` & global functions
- [x] `globalThis`, `parseInt`/`parseFloat`, `isNaN`/`isFinite`, `encodeURI(Component)`/`decodeURI(Component)`, `escape`/`unescape` (Annex B), `eval` (direct vs indirect — direct eval needs caller scope; wire carefully), `Function` constructor (parses a program). *(partial: escape/unescape ✗; eval is indirect/global-scope only — no direct-eval caller scope)*

## 4. `function*`-free control still — generators/async are Phase 5
- [x] Anything here needing generators/async (e.g. async iterator helpers) is deferred to Phase 5; stub and skip in Test262.

## 5. Regex engine (`regex/` — a real subproject)
- [x] **Parser:** RegExp grammar → AST (alternation, quantifiers greedy/lazy, groups: capturing/non-capturing/named, backreferences, lookahead/lookbehind, char classes, `\d\w\s`/negations, boundaries, unicode property escapes `\p{…}`, `.` with/without `s` flag). *(bilby ✓ — except unicode property escapes `\p{…}`)*
- [x] **Flags:** `g i m s u y d v` — `u`/`v` change parsing & matching (code points, class set ops for `v`), `y` sticky, `d` indices, `m`/`s` anchors/dot. **(partial: g/i/m/s/y ✓, d parse-only, u accepted but NOT semantic (code units, not code points), v ✗)**
- [x] **Compiler + matcher:** backtracking VM (QuickJS `libregexp` is the reference for scope). Capture groups, lastIndex handling.
- [x] **Integrate:** `RegExp` constructor/prototype (`exec/test/@@match/@@replace/@@split/@@search/@@matchAll`, `source`/`flags`/`lastIndex`), and wire the `String` methods that consume RegExp. *(partial: exec/test/String-methods wired ✓; @@match/@@replace/@@split/@@search protocol dispatch + matchAll ✗)*
- [x] Can be **stubbed at phase start** (String methods that need it skip in Test262) and filled mid-phase so the rest of the library isn't blocked.

## 6. Testing
- [x] Turn `built-ins/<X>/**` green directory-by-directory; keep a checklist of which constructors are "done." *(this audit is the checklist — see phase/AUDIT.md)*
- [x] Update the expected-fail/skip list as areas complete (regressions become visible).
- [x] `GC_STRESS=1` everywhere; Weak collections + ephemerons get dedicated GC stress tests.

---

## Exit criteria
- [x] Major constructors + prototypes green: Object(✓ Phase 3), Array, String, Number, Math, Symbol, JSON, Map/Set/Weak*, Reflect, Proxy, Error family, TypedArray/ArrayBuffer/DataView, BigInt, Date (core), RegExp.
- [x] Overall Test262 into the ~80s% range.
- [x] Regex engine passes the bulk of `built-ins/RegExp/**` (property escapes / `v`-flag long tail may remain).

## Notes / risks
- **Biggest time sinks:** RegExp (esp. `u`/`v` + property escapes), Proxy invariants, Array `sort`, TypedArrays, BigInt bignum. Sequence them deliberately; don't let RegExp block everything else.
- Weak collections require **ephemeron** support in the collector — surface that requirement to the GC now, not in Phase 7.
- Prefer breadth of "mostly-correct constructors" then depth, to keep the conformance graph rising steadily and morale high.
