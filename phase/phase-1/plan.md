# Phase 1 — Lexer + Parser + AST

> **Objective:** Turn source text into a fully-typed AST for (essentially) the whole ECMAScript grammar. No execution yet — but the **parser is testable against Test262's negative (SyntaxError) corpus**, so this phase produces a real, rising conformance signal on the "does it parse / does it correctly reject" axis.
>
> **Definition of done:** parses the vast majority of Test262 source files without crashing, and correctly accepts/rejects the `negative: {phase: parse}` tests.

---

## 0. Prerequisites
- [ ] Phase 0 harness can invoke "parse only" mode and classify parse-phase negatives.

## 1. Lexer (`lexer.zig`)
- [ ] Token type enum + `Token{ kind, start, end, line, col }`; source kept as UTF-8, decoded to code points on demand.
- [ ] **Whitespace & line terminators** incl. ` `, `﻿`, ` `/` `; track "newline before this token" (needed for ASI).
- [ ] **Comments:** `//`, `/* */` (multiline sets the newline flag), HTML-like comments `<!--` / `-->` (Annex B).
- [ ] **Identifiers:** Unicode ID_Start / ID_Continue, `\u` and `\u{}` escapes in identifiers, `$`/`_`.
- [ ] **Keywords & reserved words:** contextual keywords (`let`, `yield`, `async`, `await`, `of`, `static`, `get`/`set`) resolved by parser, not lexer.
- [ ] **Numeric literals:** decimal, `0x`/`0o`/`0b`, legacy octal (`0777`, Annex B, sloppy only), `BigInt` suffix `n`, numeric separators `_`, exponents, leading-dot / trailing-dot.
- [ ] **String literals:** single/double, all escape forms (`\x`, `\u`, `\u{}`, line continuations, legacy octal escapes — sloppy only).
- [ ] **Template literals:** `` ` ``, `${`…`}` re-entrancy, `TemplateHead/Middle/Tail`, cooked vs raw, invalid-escape rules (tagged templates allow them).
- [ ] **Punctuators:** full set incl. `?.` (with the `?.` + digit disambiguation), `??`, `??=`, `&&=`, `||=`, `**`, `**=`, `...`, `=>`.
- [ ] **Regex vs division disambiguation:** lexer needs parser context (or a goal-symbol flag) to know whether `/` starts a regex literal. Implement via a `reScanAsRegex` hook the parser calls.

## 2. Parser (`parser.zig`) — recursive descent, cover grammars where needed
- [ ] Pratt/precedence-climbing for expressions; statement dispatch by leading token.
- [ ] **Automatic Semicolon Insertion (ASI):** the three rules (offending token, restricted productions, end-of-input); restricted productions: `return`/`throw`/`break`/`continue`/postfix `++`/`--`/`yield`/arrow.
- [ ] **Expressions:**
  - [ ] primary: literals, identifiers, `this`, `(` … `)`, array/object literals (incl. spread, shorthand, computed keys, getters/setters, `__proto__`), template & tagged template.
  - [ ] member/call/new/optional-chaining, `new.target`, `import.meta`, `import()` call.
  - [ ] unary, update, binary, logical, nullish, conditional, assignment (+ compound), comma, `yield`/`yield*`, `await`, exponentiation right-assoc.
  - [ ] **arrow functions:** the cover-grammar problem — parse `( … )` as *either* parenthesized expr or arrow params, reinterpret on seeing `=>`.
  - [ ] **destructuring:** reinterpret array/object *literals* as assignment/binding *patterns* (another cover grammar); defaults, nested, rest.
- [ ] **Statements & declarations:** block, `var`/`let`/`const` (+ TDZ marker in AST), `if`, `for`/`for-in`/`for-of` (+ `for await`), `while`/`do-while`, `switch`, `try/catch/finally` (optional catch binding), `throw`, `return`, labeled, `break`/`continue`, `with` (sloppy), `debugger`, empty, expression stmt (+ `use strict` directive prologue detection).
- [ ] **Functions & classes:** function/generator/async/async-generator decls & exprs; params (defaults, rest, destructured) + `length`/`name` info; class decls/exprs, `extends`, constructor, methods, static, `#private` fields & methods, static blocks, accessors, computed names.
- [ ] **Modules:** `import`/`export` (named, default, namespace, `export * as`, re-export), `import.meta`, top-level `await` allowed flag. Parse now; **linking is Phase 5**.
- [ ] **Early errors:** duplicate lexical bindings, `let` named `let`, `new.target` outside function, `await`/`yield` context rules, invalid assignment targets, duplicate `__proto__`, labelled/`break`/`continue` target validation, strict-mode reserved words & octal, `with` in strict mode. These are the bulk of parse-phase Test262 negatives.

## 3. AST (`ast.zig`)
- [ ] Node union with source spans on every node (needed for `Function.prototype.toString`, errors).
- [ ] Keep a **strict-mode flag** threaded through scopes.
- [ ] Store enough to reconstruct source text ranges verbatim (for `toString`).
- [ ] Consider an arena allocator for AST nodes (freed after bytecode compile).

## 4. Testing
- [ ] Unit: golden AST snapshots for a curated set of tricky inputs (arrows, destructuring, ASI edge cases, template nesting, regex-vs-div).
- [ ] **Test262 parse mode:** run `language/**` with "parse only"; PASS negatives that should be `SyntaxError` at parse phase; PASS positives that parse cleanly. Ignore runtime semantics for now (skip).
- [ ] Fuzz the lexer/parser with random byte strings for crash-safety.

---

## Exit criteria
- [ ] Parses the overwhelming majority of Test262 `.js` sources without panics.
- [ ] Correctly accepts/rejects `negative: {phase: parse, type: SyntaxError}` tests (target: high pass rate on the parse-phase negative corpus).
- [ ] AST carries source spans + strict-mode flags; arena lifecycle documented.

## Notes / risks
- **Cover grammars (arrows, destructuring) are the classic time sink.** Budget for them explicitly; get them right with snapshot tests before moving on.
- Don't gold-plate error *messages* yet — just the correct *classification* (SyntaxError vs not) is what Test262 checks.
- Contextual keywords + ASI interact subtly; keep a running list of failing negatives and drive them to green one at a time.
