# How TigerBeetle builds a large Zig program

A study of [tigerbeetle/tigerbeetle](https://github.com/tigerbeetle/tigerbeetle) (155k lines of Zig
across 244 files, read at `main`, July 2026), written as a description of *their* system on its own
terms. An assessment of what applies to bottlebrush follows in the second half.

TigerBeetle is a financial-transactions database: a replicated state machine (Viewstamped
Replication) over a custom LSM storage engine, deployed as a single static binary. Its two defining
constraints are that it must not lose or corrupt a transaction, and that it must sustain roughly a
million transfers per second. Almost every technique below falls out of holding both of those at
once.

Their engineering doctrine is written down as [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md)
(511 lines, `docs/TIGER_STYLE.md`), which is descended from NASA's *Power of Ten* rules for
safety-critical code. What makes it worth studying is not the document — plenty of projects have
style guides — but that the codebase visibly obeys it and the build system mechanically enforces
large parts of it.

---

## 1. Safety: assertions as the primary tool

The load-bearing idea, in their words:

> Assertions detect programmer errors. Unlike operating errors, which are expected and which must be
> handled, assertion failures are unexpected. The only correct way to handle corrupt code is to
> crash. **Assertions downgrade catastrophic correctness bugs into liveness bugs. Assertions are a
> force multiplier for discovering bugs by fuzzing.**

That last sentence is the whole strategy in miniature. A fuzzer can only find a bug if the bug
*announces itself*. Silent corruption — a wrong balance, a stale pointer that happens to still point
at plausible memory — passes the fuzzer and ships. An assertion converts silent corruption into a
loud crash at the moment of violation, and *that* is what the fuzzer can detect. Assertions and
randomized testing are not two independent practices; each is nearly useless without the other.

Counted at `main`: **8,245 `assert(…)` calls across 4,223 functions — 1.95 per function**, against
their stated floor of two. It is not aspirational. It is the actual density of the code.

The rules that shape where assertions go:

- **Assert every function's arguments, return values, pre/postconditions and invariants.** "A
  function must not operate blindly on data it has not checked."
- **Pair assertions.** For each property, find *two different code paths* to assert it. Their example
  is asserting data validity immediately before writing it to disk, and again immediately after
  reading it back. One assertion checks your code; two check your *model* of the code, because a
  wrong model usually fails to be wrong twice in the same way. There is a whole blog post behind this
  ("it takes two to contract").
- **Assert the negative space, not just the positive.** Assert what you expect *and* what you
  expressly do not expect. Bugs congregate at the boundary between valid and invalid.
- **Split compound assertions:** `assert(a); assert(b);` rather than `assert(a and b)`, so a failure
  says which half broke.
- **Assert compile-time constants against each other.** `message_pool.zig` opens with

  ```zig
  comptime {
      // message_size_max must be a multiple of sector_size for Direct I/O
      assert(constants.message_size_max % constants.sector_size == 0);
  }
  ```

  This checks a design invariant *before the program runs*, and it is also the comment — the
  assertion cannot go stale the way prose does.
- **`stdx.maybe(ok)`**, defined as `assert(ok or !ok)`. It is a no-op that documents "this condition
  may hold or may not, and I have thought about both." It marks the places a reader would otherwise
  wonder whether an invariant was forgotten.

They are also candid that assertions are not a substitute for thought:

> Build a precise mental model of the code first, encode your understanding in the form of
> assertions, write the code and comments to explain and justify the mental model to your reviewer,
> and use VOPR as the final line of defense, to find bugs in your and reviewer's understanding.

### The assertion/performance trade, made explicit

A million transfers per second and two assertions per function are in obvious tension. They resolve
it by splitting the system into a **control plane** and a **data plane**, and giving the two
different budgets. From `constants.zig`:

> For production, 5% slow down might be deemed critical, tests tolerate slowdowns up to 5x. […] In
> the control plane (eg, vsr proper) assert unconditionally. Due to batching, control plane overhead
> is negligible. **It is acceptable to spend O(N) time to verify O(1) computation.** In the data
> plane (eg, lsm tree), finer grained judgement is required. Do an unconditional O(1) assert before
> an O(N) loop (e.g. a bounds check). Inside the loop, […] guard the assert with `if
> (constants.verify)`.

And a subtlety that only shows up once fuzzing is your main test method:

> In the data plane, never use O(N) asserts for O(1) computations — due to randomized testing the
> overall coverage is proportional to the number of tests run. Slow thorough assertions decrease the
> overall test coverage.

An assertion that halves your fuzzing throughput has to earn its keep against the bugs the lost half
would have found. Very few codebases think at this resolution.

---

## 2. Bounds on everything

- **No recursion, anywhere.** So that every execution which should be bounded *is* bounded. The
  native stack is a resource with no runtime check, and recursion is the one construct that consumes
  it without a limit you can see.
- **Every loop and every queue has a fixed upper bound.** Where a loop genuinely cannot terminate (an
  event loop), that fact must itself be asserted.
- **Explicitly-sized integers.** `u32`, not `usize`. Architecture-dependent widths are a portability
  and overflow hazard that buys nothing.
- **All memory is statically allocated at startup; nothing is allocated or freed afterwards.**

That last one is enforced by a type, not by discipline. `static_allocator.zig` is an `Allocator`
wrapper with three states:

```zig
const State = enum {
    /// Allow `alloc` and `resize`.
    init,
    /// Don't allow any calls.
    static,
    /// Allow `free` but not `alloc` and `resize`.
    deinit,
};
```

Startup runs in `.init`; then `transition_from_init_to_static()` flips it, and every subsequent
`alloc` trips `assert(self.state == .init)` and crashes. Use-after-free becomes impossible because
nothing is freed. Peak memory is knowable because it is decided before the first request. Their
claim, worth quoting because it is the non-obvious part:

> As a second-order effect, it is our experience that this also makes for more efficient, simpler
> designs […] compared to designs that do not consider all possible memory usage patterns upfront as
> part of the design.

The corollary is a family of fixed-capacity data structures replacing the usual growable ones:
`stdx.BoundedArrayType`, `IOPSType(T, size)` (a fixed pool of in-flight I/O slots indexed by a
bitset, capped at 255 by taking a `u8`), `StackType`, `QueueType`, `RingBuffer`, `MessagePool`.

---

## 3. Performance: design-time, not profile-time

> The best time to solve performance, to get the huge 1000x wins, is in the design phase, which is
> precisely when we can't measure or profile.

Their method is **back-of-the-envelope sketches over four resources (network, disk, memory, CPU) and
two characteristics (bandwidth, latency)**, done before writing code, aiming to land "within 90% of
the global maximum." Optimize the slowest resource first — *after* weighting by frequency, since a
memory cache miss repeated a million times can cost more than one `fsync`.

The concrete levers, in the order they matter:

1. **Batching.** A request message carries thousands of transfers: `StateMachine.batch_max.create_transfers`
   is *derived* from `message_body_size_max` (a 1 MiB message by default) divided by the event size,
   rather than being a tuned constant. This is what makes the control plane's unconditional assertions
   free — the per-batch cost of consensus, assertions and bookkeeping is amortized across the whole
   batch. Batching is simultaneously the performance strategy *and* the safety budget.
2. **Predictable CPU work.** "Let the CPU be a sprinter doing the 100m. Be predictable. Don't force
   the CPU to zig zag and change lanes."
3. **Explicitness over compiler faith.** "Minimize dependence on the compiler to do the right thing
   for you." Specifically: extract hot loops into standalone functions taking primitive arguments,
   *without* `self` — so the compiler needn't prove it can cache struct fields in registers, and a
   human can see redundant computation.
4. **Mechanical sympathy in the layout**: `sector_size = 4096`, Direct I/O, cache-line alignment as a
   named constant, `io_uring` on Linux (with hand-written `darwin`/`windows`/`test` backends behind
   the same interface).

They tool this too. `copyhound.zig` parses the emitted LLVM IR to find (a) large `memcpy`s with
compile-time-known size and (b) functions bloated by monomorphisation — catching whole classes of
accidental cost that a profiler shows only as diffuse slowness. `counting_allocator.zig` tracks
allocation totals. `trace.zig` and `devhub/` track benchmark results per commit on a dashboard.

---

## 4. Testing: determinism first, then chaos

The centrepiece is **VOPR** (`vopr.zig`), a deterministic simulator of an entire TigerBeetle cluster.
Everything nondeterministic is replaced by a seeded, simulated implementation: `testing/storage.zig`
(in-memory disk with injected latency and faults), `testing/packet_simulator.zig` (network with
delay, reorder, drop, partition), `testing/time.zig` (a clock that ticks when told), plus simulated
crash, restart, pause and reformat of replicas.

A single `u64` seed drives all of it. Given a seed, the run is bit-for-bit reproducible — which is
what makes a simulator a *debugging* tool rather than merely a bug detector. From `vopr.zig`'s
`Options`, every knob is a probability: `replica_crash_probability`, `replica_restart_probability`,
`replica_reformat_probability`, `replica_pause_probability`, each with a "stability" minimum
duration.

Two details that show this is a mature practice rather than a demo:

- **Probabilities are `Ratio { numerator, denominator }`, not floats.** `stdx/prng.zig` is a
  from-scratch PRNG whose header explains: they avoid `std.Random` in order to "remove floating point
  from the API, to ensure determinism," and to insulate themselves from stdlib churn and PRNG
  algorithm churn. Floating point is a determinism hazard; they refuse to have any in the test
  substrate.
- **Fault injection is designed to be survivable, and says so.** `testing/storage.zig`'s header
  documents exactly which faults each zone tolerates — "one read/write fault per superblock area";
  grid faults disabled when `replica_count ≤ 2`; a `ClusterFaultAtlas` guaranteeing at least one
  replica retains a good copy so repair is *possible*. The simulator injects the worst faults the
  system is *supposed* to survive, no more. Otherwise every run fails and the simulator teaches you
  nothing.

The simulator asserts liveness as well as safety: it drives the cluster until `requests_replied ==
requests_max`, then enters a "liveness mode" (crash/pause probabilities set to zero) and requires the
core to converge, failing with `no state convergence` otherwise. A hung-but-uncorrupted cluster is a
bug too.

### Swarm testing

`testing/fuzz.zig` is small (143 lines) and dense. The key function:

```zig
/// Return a distribution for use with `random_enum`.
///
/// This is swarm testing: some variants are disabled completely,
/// and the rest have wildly different probabilities.
pub fn random_enum_weights(prng: *stdx.PRNG, comptime Enum: type) …
```

Rather than sampling operations uniformly, each fuzz run randomly *disables* a subset of operations
entirely and gives the survivors wildly skewed weights. A uniform fuzzer spends its budget on the
average program; a swarm fuzzer explores runs that are all-inserts, or inserts-and-deletes-only, and
finds interactions a uniform sampler statistically never reaches. `random_id` applies the same
thinking to keys: flip a coin between a small hot ID set (to force collisions) and a large cold one
(to blow out caches).

Seeds come from CI as the **git commit hash**, truncated to `u64` (`parse_seed` accepts a 40-char hex
string as a special case) — so every commit fuzzes with a different seed, yet any failure is
reproducible from the commit hash alone.

`fuzz_tests.zig` registers ~14 targeted fuzzers (`lsm_tree`, `lsm_forest`, `vsr_free_set`,
`vsr_superblock`, `storage`, `message_bus`, `ewah`, …). The unit of fuzzing is a data structure,
not the whole program.

### Exhaustive generation

`testing/exhaustigen.zig` is the counterweight to randomness: a generator that enumerates *all*
values in a bounded space rather than sampling them. `while (!g.done())` with `g.index(pool)` inside
walks every permutation. For small state spaces, exhaustive beats random — you get a proof rather
than a probability.

### Snapshot testing

`stdx/testing/snaptest.zig` provides `Snap`: expected values written inline in the test source, and
`SNAP_UPDATE=1 zig test …` rewrites them in place. This makes "assert the exact output" cheap enough
that they do it for formatted headers, JSON traces, CLI flag output and PRNG distributions — places
where a hand-written expectation would be too tedious to maintain and so would not exist.

### Lint as a test: `tidy.zig`

1,463 lines, run as `test "tidy"`, walking the source with Zig's own `std.zig.Ast`. It enforces:

- **A ban list with replacements**, each entry a `{banned, replacement}` pair. A sample:
  `std.BoundedArray` → `stdx.BoundedArrayType`; `@memcpy(` → `stdx.copy_disjoint`; `parseInt` →
  `stdx.parse_int`; `intRangeAtMost` → `stdx.PRNG`; `debug.assert(` → "unqualified assert";
  `usingnamespace` → "something else". Two entries are pure language footguns: `== error.` and `!=
  error.` are banned in favour of `switch`, "to avoid silent anyerror upcast".
- **`FIXME` and `dbg(` as *reminders*** — allowed while iterating, rejected before merge. The tool
  encodes the workflow, not just the rule.
- **100-column lines**, with a hand-maintained list of principled exemptions (URLs, wide table tests,
  ASCII diagrams) rather than a blanket opt-out.
- **Dead declarations and dead files.** An `IdentifierCounter` plus a `DeadFilesDetector` fail the
  build on unreferenced private declarations and unreachable modules. Dead code is a test failure,
  not a code-review opinion.

The insight here is procedural: every convention that *can* be checked mechanically is checked by a
test, so code review is freed to discuss design. Nobody at TigerBeetle spends a review comment on
line length.

---

## 5. Naming, comments, and technical debt

- **Zero technical debt.** Do it right the first time; "the best time to solve a problem is now."
  Debt compounds, and in a database the interest is paid in corrupted data.
- **Function shape**: hard limit of **70 lines**, motivated physically ("a sharp discontinuity
  between a function fitting on a screen, and having to scroll"). The advice on *how* to split is the
  useful part: **"push `if`s up and `for`s down."** Keep all branching in the parent function, move
  straight-line work into leaf helpers, keep leaves pure. Centralize state manipulation in the parent
  and let helpers compute what should change rather than applying it.
- **100 columns**, chosen so two copies fit side by side.
- **Declare variables at the smallest possible scope**; minimize how many are live at once.
- Comments explain *why*, and are written as complete sentences. Assertions are preferred wherever an
  invariant can be stated in code instead of prose, because prose goes stale and `assert` does not.

---

## 6. The shape of the whole

Stepping back, TigerBeetle's methodology is a single loop, and each stage exists to make the next one
work:

1. **Design for bounds.** Everything is fixed-size, statically allocated, non-recursive. This makes
   the state space small and enumerable.
2. **Assert the invariants of that design**, twice, in both the positive and negative space. This
   makes violations *loud*.
3. **Make execution deterministic** — own PRNG, no floats, simulated clock, disk and network. This
   makes violations *reproducible*.
4. **Fuzz the determinism** with swarm testing and commit-hash seeds. This makes violations *findable*.
5. **Mechanize every rule that can be mechanized** (`tidy.zig`, `copyhound.zig`, snapshot tests). This
   keeps human attention on the parts that cannot be mechanized.

Remove any one stage and the others degrade sharply. Assertions without determinism give you crashes
you cannot reproduce. Determinism without assertions gives you reproducible runs of a program that is
silently wrong. Fuzzing without bounds gives you a fuzzer that spends its budget on `OutOfMemory`.

That interlock — not any individual rule — is the thing worth copying.

---
---

# Assessment: what transfers to bottlebrush

bottlebrush is a tier-2 JavaScript engine: a register-based bytecode VM with a precise mark-sweep GC,
6,706 Test262 files, 172 unit tests, ~19k lines of Zig. Where TigerBeetle is a database that must not
lose data, bottlebrush is an interpreter that must not *compute the wrong answer* — and, being a GC'd
language runtime, must not use a value after collecting it.

Two of those three concerns map cleanly onto TigerStyle. One does not.

## Where we stand today, measured

| | bottlebrush | TigerBeetle |
|---|---:|---:|
| assertions | **4** | 8,245 |
| functions | 877 | 4,223 |
| assertions per function | **0.005** | 1.95 |
| functions over 70 lines | 24 (2.7%) | — (enforced at 0) |
| lines over 100 columns | 836 | 0 (enforced) |

All four of our assertions are in `bilby/src/regex.zig`, the vendored regex engine. `interpreter.zig`
(3,500 lines), `compiler.zig` (2,900), `parser.zig` (2,100) and `gc.zig` (570) contained, until this
week, **zero**.

Our longest functions: `installBuiltins` 611 lines, `scanTemplateBody` 375, `compileClass` 198, `exec`
189, `compileFunction` 184.

## The techniques that transfer, ranked

### 1. Deterministic stress over the corpus — *already done, and it paid immediately*

This is the direct analogue of VOPR, and we already own the corpus that makes it work. Setting
`heap.stress = true` collects at every allocation safe-point, so *any* value the VM holds across an
allocation without rooting it is swept instantly. The 6,706-file Test262 corpus then becomes a
root-tracing fuzzer, because every test is a different program exercising different allocation
sequences.

I built it (`zig build test262-stress`, env `GC_STRESS=1`) and it found **six real use-after-collect
bugs** that 172 unit tests and 6,706 conformance files had never surfaced:

- the per-character string a string iterator yields, and the pair array `entries()` builds, both
  freed by `makeIterResult`'s own allocation;
- the arguments a native passes when calling back into JS — `callValue(trap, h, &.{try
  makeString(key)})` — freed while building the callee's `arguments` object;
- `makeDataDescriptor`'s value, freed by the descriptor object's allocation;
- `RegExp.prototype[@@split]`'s exec record, read after appending a fresh substring to the result;
- promise capability functions and their environments, unrooted between `NewPromiseCapability` and
  the first call;
- an async generator's queued request, shifted off its only root before allocating the iterator
  result that settles it.

The corpus now yields an **identical pass/fail set with stress on**, so this is a regression gate, not
a one-off.

Two TigerBeetle-derived details made the difference:

- **Poisoning.** `Heap.destroy` now overwrites dead cells with `0xAA` under stress. Without it, the
  bugs were invisible single-threaded (freed memory happened to still hold valid-looking data) and
  only appeared under the parallel test runner, where another worker refilled the cell. Poison turns
  a timing-dependent heisenbug into a deterministic fault *at the use*. This is exactly the "make
  violations loud" step.
- **Assertions and fuzzing are one technique.** Every one of the six was found because the corrupt
  value hit a `switch` on a poisoned enum tag — an implicit assertion. The bugs existed for months
  under a test suite that could not see them.

Fixing the fifth and sixth also required generalising the fix rather than patching call sites:
rooting the `(callee, this, args)` triple at the `callValue`/`constructValue` boundary makes ~100
native call sites correct by construction. That is TigerStyle's "put the invariant where it cannot be
violated."

### 2. Assertions on VM invariants — *the largest remaining gap, and the highest leverage*

Going from 0.005 to 2.0 assertions per function is not a realistic sprint, and mechanically sprinkling
`assert` would be cargo-culting. But the *targeted* version is straightforwardly valuable, because our
bug profile is a near-perfect match for what assertions catch: silent corruption that only manifests
much later.

I've made a start on the invariant that caused this entire week's work. `callValue` now records the
depth of the value-root stack on entry and asserts on exit that the call left it exactly as it found
it — so a `protect` without its `unprotect`, anywhere inside a native or on a throw path, fails at
that call rather than as a mysterious sweep some thousands of allocations later. `unprotectEnv` and
`unprotectCall` assert their stacks are non-empty before popping. I verified the assertion is
load-bearing rather than decorative by deliberately leaking one `protect` in a native: it trips
immediately.

The next candidates, in order of expected yield:

- **`gc.zig`**: assert a cell's `kind` tag is in range on every `mark` (a pair assertion with the
  poison); assert `live_count` equals the length of the intrusive list after sweep; assert that a
  marked cell is never freed.
- **Register allocation in `compiler.zig`**: assert `reg < fs.reg_count` on every emit; assert
  `freeTo` only ever shrinks. Register-file overruns are silent and produce wrong answers.
- **`interpreter.zig` frame discipline**: assert the register slab `top` is restored exactly on frame
  exit (a pair assertion: record on push, check on pop). We already rely on "strict LIFO" in a
  comment — that comment should be an assertion.
- **Comptime assertions on bytecode layout**: `Instruction` field widths versus the maximum register
  count and constant-pool index. If a `u8` operand can't address the registers a function may
  allocate, that is a design bug we should learn about at compile time, not from a corrupted `regs[]`.

### 3. `tidy.zig`-style lint as a test — *cheap, and we have accumulating drift*

836 lines over 100 columns and no enforcement. More usefully than line length, a ban list would let us
encode the project's hard-won knowledge as a failing test rather than tribal memory. Ours would start:

- `std.posix.getenv` → `init.environ_map.get` (removed in Zig 0.16; it cost me a stale-binary detour
  this session, because the runner failed to compile while `zig-out/bin/test262` silently kept running
  the previous build).
- `DEBUG` / `TODO(now)` / `heap.stress = true` outside `stress_tests.zig` — reminders, in TigerBeetle's
  sense, that block a merge.
- Dead-declaration detection over `src/runtime/builtins/` in particular, where natives get orphaned
  when a spec path is rewritten.

### 4. Swarm testing for the parser fuzzer — *a small change with real upside*

We have a lexer/parser fuzz test that feeds 4k random inputs. It is a uniform fuzzer, which means it
mostly generates garbage that fails in the first hundred bytes. `random_enum_weights` applied to a
token-level generator — disable a random subset of token kinds per run, skew the rest — would generate
inputs that are *plausible JavaScript with one weird feature over-represented*, which is where parser
bugs actually live. Seeding from the commit hash gives us CI-wide seed diversity with reproducibility
from the hash alone.

### 5. Bounded recursion — *we have a live bug here, found while writing this*

TigerStyle bans recursion outright, "to ensure that all executions that should be bounded are
bounded." We cannot follow that literally: a recursive-descent parser and a tree-walking mark phase
are the natural shapes for their problems, and rewriting both as explicit worklists is real work.

But their *reason* applies exactly, and we have already been bitten by it twice:

- The `tail-call-optimization` Test262 tests recurse ~100k deep and exhaust the native stack. We have
  them on a denylist. That is a workaround, not a fix.
- **`Tracer.mark` recurses over the object graph.** So a JavaScript program that builds a
  400,000-node linked list segfaults *inside the garbage collector*:

  ```js
  var head = null;
  for (var i = 0; i < 400000; i++) head = { next: head };
  ```

  ```
  Segmentation fault at address 0x16c8c3fb0
  src/gc.zig:334 in mark
  src/gc.zig:187 in trace   // if (self.prototype) |p| t.mark(&p.gc);
  ```

  This is not a synthetic concern: deep linked lists, long prototype chains and long scope chains are
  ordinary JavaScript. Any page that builds one can crash the engine, and it is reachable from
  untrusted input. The fix is the TigerBeetle one — replace the recursion with an explicit, bounded
  mark stack — and it should be treated as a correctness bug rather than a hardening nicety.

  (Filed as a follow-up; it is out of scope for the GC-root work already committed.)

The general policy I'd adopt, short of "no recursion": **every recursion must have an explicit depth
counter and a bound, and the bound must be asserted.** The parser already has a nesting budget; the
tracer has none; the interpreter's `callValue` has a depth charge, which is why deep JS recursion
raises `RangeError` instead of dying — that is the model to copy into `gc.zig`.

## What does *not* transfer

Worth being explicit, because the failure mode of reading TigerStyle is to adopt all of it:

- **Static allocation.** A JavaScript engine's heap *is* the product; `new` is a language keyword. We
  cannot allocate everything at startup. The disciplined version of the idea we *can* take is the
  `StaticAllocator` trick applied narrowly: make it an assertion failure to allocate on paths where we
  believe we don't, e.g. inside `markRoots`, or between a `createEnv` and its frame push.
- **Explicit `u32` everywhere.** We have 129 `usize` uses. Some are worth changing (register indices,
  bytecode offsets, where a `u32` also documents the bytecode's own limits and would have caught the
  `arguments`-object bug class earlier). Most are slice indices where `usize` is what the language
  hands you and churning them buys nothing.
- **VOPR proper.** We have no cluster, no network, no disk. Our nondeterminism is the GC schedule and
  the job queue, and we now control the first exactly (`GC_STRESS`) and the second by construction
  (a deterministic FIFO). There is nothing left to simulate.
- **Zero technical debt / 70-line functions.** Correct in principle. `installBuiltins` at 611 lines is
  a flat registration table, and splitting it would be motion rather than progress. `compileClass` at
  198 and `exec` at 189 are genuinely branchy and *would* benefit from "push `if`s up, `for`s down" —
  but that's a refactor to schedule, not a rule to adopt.

## Recommendation

The single highest-value idea in TigerBeetle is not any rule in the style guide. It is that
**assertions and randomized execution are one technique, and each is close to worthless without the
other.** We had a large randomized corpus and no assertions, so it found spec bugs and no memory bugs.
Adding one deterministic stress mode and one poison pattern — a day's work — surfaced six
use-after-collect bugs and, incidentally, two real language bugs (`async function` expressions never
parsed; declarations were accepted as nested statement bodies).

Concretely, in order:

1. **Done:** `zig build test262-stress` as a permanent gate, dead-cell poisoning, root-stack pair
   assertion, six root fixes, regression tests.
2. **Next:** fix `Tracer.mark`'s unbounded recursion — it is a reachable crash.
3. **Then:** assertions in `gc.zig` and the compiler's register allocator; comptime assertions on
   bytecode operand widths.
4. **Then:** `tidy.zig`-style ban-list test; swarm-weighted parser fuzzing seeded by commit hash.

Everything else is style, and style is worth much less than the interlock.
