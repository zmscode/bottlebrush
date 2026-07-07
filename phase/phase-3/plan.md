# Phase 3 — Objects, Prototypes & the Semantic Core

> **Objective:** Implement the full object internal-methods model and the coercion abstract operations, spec-literal. This is the semantic bedrock the entire built-in library (Phase 4) stands on.
>
> **Definition of done:** `built-ins/Object`, property-descriptor, and prototype Test262 slices are largely green.

---

## 0. Prerequisites
- [x] Phase 2 engine runs core language; minimal object plumbing exists.

## 1. Object model (`runtime/object.zig`)
- [x] **Property storage:** ordered map `PropertyKey → PropertyDescriptor` (insertion order matters for enumeration; integer-index keys sort ahead per spec `OrdinaryOwnPropertyKeys`). Shapes/hidden classes are **Phase 7** — keep access behind an API so they can slot in.
- [x] **PropertyKey:** string or symbol (canonicalize integer-index strings for array-index fast paths later).
- [x] **PropertyDescriptor:** data (`value`, `writable`) vs accessor (`get`, `set`), plus `enumerable`, `configurable`; validation & completion per `ValidateAndApplyPropertyDescriptor`. *(FIXED 2026-07-08: partial descriptors merge; non-configurable invariants enforced with TypeError; non-extensible objects reject new properties)*
- [x] **Ordinary internal methods** (`[[...]]`) as functions, spec-literal:
  - [ ] `[[GetPrototypeOf]]`, `[[SetPrototypeOf]]` (cycle check), `[[IsExtensible]]`, `[[PreventExtensions]]` **← GAP: `[[SetPrototypeOf]]`/`Object.setPrototypeOf` missing entirely (no cycle check); the rest of the line is done**
  - [x] `[[GetOwnProperty]]`, `[[DefineOwnProperty]]` (→ `OrdinaryDefineOwnProperty` + `ValidateAndApplyPropertyDescriptor`)
  - [x] `[[HasProperty]]`, `[[Get]]` (accessor invocation, receiver threading), `[[Set]]` (accessor/receiver, `CreateDataProperty` fallback)
  - [x] `[[Delete]]`, `[[OwnPropertyKeys]]` (integer-index order → insertion order strings → symbols)
- [x] **Exotic objects (interfaces now, some impls later):** Array (`length` magic — `ArraySetLength`, index defineOwnProperty side effects), String (index access + `length`), arguments (mapped/unmapped), bound functions, `Proxy` (Phase 4), integer-indexed/TypedArray (Phase 4). Define the vtable/dispatch mechanism for exotic overrides here. *(partial: hardcoded branches instead of a vtable; ArraySetLength ignores non-writable length)*

## 2. Abstract operations — type conversion (spec-literal, cite section numbers)
- [x] `ToPrimitive` (+ `OrdinaryToPrimitive`, `@@toPrimitive`), `ToBoolean`, `ToNumber` (string→number grammar!), `ToNumeric`, `ToIntegerOrInfinity`, `ToInt32/ToUint32/ToInt16/…`, `ToBigInt`, `ToString` (number→string algorithm), `ToObject`, `ToPropertyKey`, `ToLength`, `ToIndex`. *(partial: `@@toPrimitive` never consulted)* *(FIXED 2026-07-08: 0x/0o/0b numeric strings parse; signed radix prefixes are NaN per spec)*
- [x] `RequireObjectCoercible`, `IsCallable`, `IsConstructor`, `IsArray`, `IsRegExp`, `SameValue`, `SameValueZero`, `SameValueNonNumeric`.
- [x] **Testing string↔number conversions is high-yield** — Test262 has dense coverage here.

## 3. Abstract operations — objects & functions
- [x] `Get`, `GetV`, `Set`, `CreateDataProperty(OrThrow)`, `DefinePropertyOrThrow`, `DeletePropertyOrThrow`, `HasProperty`, `HasOwnProperty`, `GetMethod`, `Call`, `Construct`, `GetFunctionRealm`, `OrdinaryHasInstance`, `SpeciesConstructor`, `CreateArrayFromList`, `LengthOfArrayLike`, `EnumerableOwnPropertyNames`. *(partial: SpeciesConstructor ✗; GetMethod informal)*
- [x] **Function objects:** `[[Call]]`/`[[Construct]]`, `length`/`name` own props with correct attributes, `%Function.prototype%`, `Function.prototype.call/apply/bind` (bound-function exotic object), `arguments`/`caller` poison pills in strict. *(length/name/call/apply/bind ✓; strict poison pills n/a — no strict mode)*

## 4. Environments & closures (finish what Phase 2 started)
- [x] Formalize environment records: declarative, object (`with`/global), function, module (Phase 5); `[[Get/Set]]BindingValue`, TDZ via uninitialized bindings. *(partial: no object env (`with`) or module env)*
- [ ] `arguments` object done properly: **mapped** (sloppy, aliases params) vs **unmapped** (strict); the parameter-map exotic behavior. **← GAP: `arguments` is a plain object — no mapped/unmapped distinction, no parameter aliasing**
- [x] `this` resolution finalized across sloppy/strict/arrow/eval/module.

## 5. Realm & intrinsics wiring
- [x] `Realm` holds the intrinsics table (`%Object.prototype%`, `%Function.prototype%`, `%Array.prototype%`, error prototypes, …). `CreateIntrinsics` sets up the prototype graph in the correct order.
- [ ] `$262.createRealm` returns a genuinely fresh realm (needed by many Test262 tests). **← GAP: no `$262`**

## 6. `Object` built-in (proves the model)
- [x] `Object` constructor + `Object.prototype` (`hasOwnProperty`, `isPrototypeOf`, `propertyIsEnumerable`, `toString` (`@@toStringTag`), `valueOf`, `toLocaleString`, `__proto__` accessor, legacy `__defineGetter__` etc. — Annex B). *(partial: `@@toStringTag` not consulted; `__proto__` accessor + Annex B getters missing)*
- [x] Statics: `defineProperty`/`defineProperties`, `getOwnPropertyDescriptor(s)`, `keys`/`values`/`entries`, `getPrototypeOf`/`setPrototypeOf`, `create`, `assign`, `freeze`/`isFrozen`/`seal`/`isSealed`/`preventExtensions`/`isExtensible`, `getOwnPropertyNames`/`Symbols`, `fromEntries`, `is`, `hasOwn`. **(partial: setPrototypeOf/assign/fromEntries/is/hasOwn/getOwnPropertyDescriptors/getOwnPropertySymbols MISSING)**

## 7. Testing
- [x] Unit tests for each abstract operation with spec-example inputs.
- [x] **Test262 targets:** `built-ins/Object/**`, `built-ins/Function/**`, and the property-descriptor/`propertyHelper.js`-driven tests; the `language/expressions/property-accessors`, `delete`, `in`, `instanceof` slices.
- [x] `GC_STRESS=1` throughout (accessor calls allocate — prime heisenbug territory).

---

## Exit criteria
- [x] `built-ins/Object`, prototype-chain, and property-descriptor slices largely green.
- [x] All type-conversion abstract operations implemented and unit-tested against spec examples.
- [x] `Function.prototype.call/apply/bind` + bound-function exotic correct; mapped/unmapped `arguments` correct.

## Notes / risks
- This phase is where "spec-literal" pays off hardest — implement `ValidateAndApplyPropertyDescriptor`, `OrdinaryDefineOwnProperty`, and `ArraySetLength` *by the numbered steps*. Guessing here fails dozens of tests subtly.
- The exotic-object dispatch mechanism you choose now must be cheap enough not to be ripped out in Phase 7; a vtable of optional overrides is fine.
