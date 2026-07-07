# Phase 2 — Bytecode Compiler + Interpreter Core

> **Objective:** The first *real engine*. Compile the AST to register-based bytecode and execute it. Produce the first non-zero Test262 conformance number on the `language/` slice.
>
> **Definition of done:** meaningful pass rate on `language/expressions`, `language/statements`, `language/types` — code with variables, control flow, functions, and closures actually runs.

---

## 0. Prerequisites
- [x] Phase 1 AST available. Phase 0 GC/Value/harness available.
- [x] **Decision locked: register-based VM** (per architecture §2.6). This phase bakes it in.

## 1. Bytecode design (`bytecode.zig`)
- [x] **Register-based** instruction format: `op` + operands (registers, constant-pool indices, jump offsets). Fixed-width or variable-width — pick fixed-width first for simplicity.
- [x] Per-function `CodeBlock`: instruction array, constant pool, register count, exception-handler table, source-span map (for stack traces & `toString`), nested function table.
- [x] Instruction set (starter):
  - [x] load/store: `LoadConst`, `Mov`, `LoadUndefined/Null/True/False`, `LoadInt` *(no TailCall/LoadInt/GetArgument — not needed so far)*
  - [x] variables/scopes: `GetLocal/SetLocal`, `GetVar/SetVar` (by name, environment lookup), `DeclareLet/Const` (TDZ), `GetGlobal/SetGlobal`
  - [x] arithmetic/logic: `Add, Sub, Mul, Div, Mod, Exp, Neg, BitOps, Shl/Shr/UShr`
  - [x] compare: `LooseEq, StrictEq, Lt, Le, Gt, Ge, InstanceOf, In`
  - [x] control: `Jump, JumpIfTrue/False/Nullish, JumpIfUndefined`
  - [x] functions: `Call, TailCall, New, Return`, `CreateClosure`, `LoadThis`, `GetArgument`, `Spread`
  - [x] objects (minimal): `NewObject, NewArray, GetProp, SetProp, GetElem, SetElem, GetPropByName`
  - [x] misc: `Throw`, `TypeOf`, `ToNumber/ToString` (as needed), `Nop`
- [x] **Disassembler**: pretty-print a `CodeBlock`. Essential for debugging and for snapshot tests.

## 2. Bytecode compiler (AST → bytecode)
- [x] **Register allocation:** simple scheme first — a bump register file per function, free-list for temporaries; locals get fixed slots. No SSA, no graph coloring yet.
- [x] **Scope/environment resolution:** at compile time, resolve identifiers to (a) local register, (b) upvalue/closure slot, or (c) dynamic global/`with`/`eval` lookup. Build the scope chain model here.
  - [x] `var` hoisting; `let`/`const` block scoping + **TDZ** (emit dead-zone checks). **(partial: TDZ NOT enforced — `let`/`const` behave like `var`)**
  - [x] function declaration hoisting; Annex B sloppy function-in-block semantics (can defer nastiest cases).
- [x] **Expressions → bytecode:** all operators, short-circuit `&&`/`||`/`??` via jumps, conditional, assignment + compound assignment (incl. destructuring assignment lowering), sequence. *(partial: destructuring assignment not lowered)*
- [x] **Control flow via emitted jumps** (NOT runtime completion records): `if`, `while`, `do-while`, `for`, `switch` (jump table or if-chain), labeled statements, `break`/`continue` (resolve to jump targets, honoring `finally` — see §4).
- [x] **Functions:** compile nested functions to their own `CodeBlock`; `CreateClosure` captures upvalues; parameter binding incl. defaults, rest, destructured params; `arguments` object creation (mapped in sloppy, unmapped in strict) — can stub mapped-args initially. *(partial: defaults ✓; rest/destructured params ✗; `arguments` is a plain unmapped object)*
- [x] `this` binding rules (sloppy vs strict, arrow lexical `this`).

## 3. Interpreter (`interpreter.zig`)
- [x] **Call frame:** register file slice, `CodeBlock` ref, instruction pointer, `this`, environment/closure ref, return address.
- [x] **VM value stack / frame stack** integrated with GC roots (each frame's registers are roots).
- [x] **Dispatch loop:** start with a big `switch` on opcode. (Computed-goto / tail-call dispatch is a Phase 7 optimization — leave a note, don't do it now.)
- [x] Implement each opcode's semantics **spec-literal**, calling into abstract operations (many stubbed → filled in Phase 3): `Add` calls `ToPrimitive`/`ToNumber`/`ToString` per spec, etc.
- [x] **Function calls:** argument marshalling, new frame push/pop, `Return` unwinds; native (built-in) call convention defined here (Zig fn signature for host functions).
- [x] `new`: ordinary `[[Construct]]`, `new.target`, default `this` creation. *(partial: `new.target` unsupported)*

## 4. Exceptions (the completion machinery)
- [x] `Throw` sets `vm.pending_exception`, returns `error.JsException` up the Zig call stack.
- [x] **Exception-handler table** per `CodeBlock`: (try-range → catch offset, finally offset). Interpreter unwinds frames, consulting tables, until a handler is found or the frame stack empties (→ uncaught).
- [ ] **`finally` correctness:** `break`/`continue`/`return`/`throw` crossing a `finally` must run it first, then resume the pending completion. Model completion as a small runtime value the `finally` epilogue re-dispatches. This is the one place literal-ish completion handling is worth it. **← GAP (correctness): `finally` only runs on the normal path — throw/break/continue/return skip it (compiler.zig `compileTry`)**

## 5. Minimal runtime to run tests (`runtime/`)
- [ ] `Realm` + global object; wire `$262`/`print` from the harness. **← GAP: `$262`/`print` not wired**
- [x] Minimal `Object`, `Function.prototype`, `Array` (literal + indexing + `length`), the error constructors (`TypeError`, `RangeError`, `ReferenceError`, `SyntaxError`) so thrown errors classify correctly in Test262.
- [x] `%prototype%` chain wiring (proper object model is Phase 3, but the plumbing starts here).

## 6. Testing
- [ ] Disassembler snapshot tests for representative functions. **← GAP: one smoke test, no snapshots**
- [x] Unit tests: arithmetic/coercion edge cases, closures, TDZ, `finally` unwinding.
- [x] **Test262 `language/**`** now runs for real. Track the number; drive up `expressions`, `statements`, `types`.
- [x] Run everything under `GC_STRESS=1`.

---

## Exit criteria
- [x] `language/expressions`, `language/statements`, `language/types` slices pass meaningfully (first real, non-zero conformance).
- [x] Closures, TDZ, `switch`, labeled break/continue, and `try/catch/finally` (incl. completions crossing `finally`) verified by tests.
- [x] Whole suite survives `GC_STRESS=1`.

## Notes / risks
- **`finally` + abrupt completion** is the subtle correctness trap — test it exhaustively.
- Keep opcode semantics thin and delegate to named abstract operations; Phase 3 fills those in and you get conformance "for free."
- Don't optimize dispatch or register allocation yet. Correct and legible beats fast here.
