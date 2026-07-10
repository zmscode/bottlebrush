---
name: banksia
description: Use when implementing or designing any part of banksia, the RAW photo editor in Zig — the emu develop engine, wombat storage, lyrebird similarity, the bk_ C ABI, or the SwiftUI shell. Encodes the architecture invariants, Zig style, testing discipline, and performance method the project follows, distilled from TigerBeetle, the Zig compiler, Ghostty, and Bun.
---

# Building banksia

banksia is a headless, deterministic RAW develop engine in Zig with a thin
native UI on top. The full plan, phase list, and definitions of done live in
`BANKSIA.md` — read the current phase's section before starting work, do the
next unchecked task, and never regress a CI number. Every phase ends with a
measurable number (golden score, latency, simulation runs, precision/recall),
and the number only goes up.

## Layout

| Module | Role |
|---|---|
| `emu/` | develop engine: decode, colour, linear-f32 pipeline, render cache, thumbnails |
| `wombat/` | storage: CAS blob vault, chunking, columnar catalog, sessions, persistence |
| `lyrebird/` | similarity: perceptual hashing, burst grouping, sharpness scoring |
| `src/` (banksia) | C ABI (`bk_*`), CLI, versioning semantics, export engine |
| `macos/` | SwiftUI shell; talks to the core only through the C ABI |

## Architecture invariants — never violate these

1. **emu is a pure function.** `(blob, recipe, engine_version, max_edge) →
   pixels`. No clock, no RNG, no environment reads, no I/O except the input
   blob, no global mutable state. Output is bit-identical across thread
   counts and tile sizes — there is a test asserting this; keep it green.
2. **Engine versioning is sacred.** A commit pins its `engine_version`;
   improving an op must never change the output of an existing version.
   Behaviour changes go in a new engine version, never in place.
3. **wombat owns every byte on disk.** Blob writes are hash → temp file →
   fsync → rename. Nothing else in the codebase opens files for writing.
4. **The UI is a client.** Swift talks only through `bk_*`. If the shell
   needs something, the C ABI grows a function; the shell never links Zig
   internals directly (the libghostty architecture).
5. **Recipes are data.** Canonical-form JSON, content-addressed, diffable.
   Ops are added to the registry; existing op semantics are frozen per
   engine version.

## Zig style (TigerStyle, calibrated for banksia)

- **Assertions**: target two per function minimum. Assert arguments, return
  values, pre/postconditions, and invariants. Pair assertions — check a
  property on two different code paths (assert before writing a blob AND
  after reading it back). Split compounds: `assert(a); assert(b);` never
  `assert(a and b)`. Assert the negative space too. Use `comptime { assert(...) }`
  for layout/constant relationships — it's a comment that can't go stale.
- **Control plane vs data plane**: catalog ops, import, versioning, the C
  ABI = control plane — assert unconditionally, O(N) checks for O(1) work
  are fine. Pixel kernels = data plane — O(1) asserts before the loop
  (bounds, alignment, plane sizes), per-pixel asserts only behind
  `if (constants.verify)`. Slow assertions reduce fuzz coverage; they must
  earn their keep.
- **No recursion** in engine code. Anything tree-shaped (op DAGs, TIFF IFD
  walks, merge logic) uses an explicit worklist with a bounded capacity. If
  recursion is truly unavoidable, it carries a depth counter with an
  asserted bound.
- **Bounds on everything**: every loop, queue, and buffer has a fixed upper
  bound; event loops assert that they are the intended infinite loop.
- **Explicitly sized integers.** `u32` indices, not `usize`, not pointers —
  handles into arrays are the currency (see data-oriented design below).
- **Functions ≤ 70 lines.** Push `if`s up and `for`s down: branching lives
  in the parent, straight-line work in leaf helpers, leaves stay pure.
- **100 columns**, enforced as a per-file ratchet, not a big-bang reformat.
- **Naming**: `snake_case`; no abbreviations; units and qualifiers in
  descending significance (`edge_px_max`, not `max_edge_px`); equal-length
  pair names (`source`/`target`); helpers prefixed by their caller's name.
- **Zero dependencies** beyond the Zig toolchain, with two documented
  temporary exceptions: libraw (until native decoders pass the corpus) and
  the system PNG route if hand-rolling is deferred. Everything else is
  written or vendored. Tooling and scripts are Zig programs, not bash.

## Memory discipline

- **Allocators are parameters**, never globals. Every subsystem takes its
  allocator explicitly.
- **The render path allocates at plan time, not render time.** Planning a
  pipeline computes every buffer size (planes, tile pool, scratch for the
  widest convolution); rendering then runs allocation-free. Enforce it, not
  hope it: in debug builds the pixel loop runs under a TigerBeetle-style
  state-machine allocator that panics on alloc after `transition_to_static()`.
- **Arena per render** for plan-time data; reset is the only free.
- **Catalog and edit stacks are `std.MultiArrayList`** (struct-of-arrays).
  Filters scan only the columns they touch. Strings (camera, lens, keywords)
  are interned once into id tables; rows store `u32` ids.
- **Shrink the structs** (the Zig-compiler lesson): smaller rows = fewer
  cache misses = faster scans. Prefer `u32`/`u16`/packed flags over
  pointer-sized fields; move rare/large payloads out-of-band into side
  arrays indexed by handle.

## Performance method

- **Napkin math before code.** Images are memory-bandwidth problems: a 24MP
  frame is ~288MB as three f32 planes, so *count full-image traversals* —
  they dominate everything. Sketch network/disk/memory/CPU × bandwidth/
  latency before designing a stage; land within 90% of the sketch or know
  why.
- **Batching = tiles.** Fuse adjacent per-pixel ops into one pass over a
  tile while it's hot in cache, instead of one full-image pass per op.
  Convolution ops set tile overlap; the planner computes it once.
- **Hot kernels are standalone functions with primitive arguments** — no
  `self`, no struct field access inside the loop. The compiler shouldn't
  have to prove field caching is safe, and a human should be able to see
  redundant work.
- **comptime specialization** (the Ghostty pattern): demosaic monomorphized
  per CFA layout, kernels per pixel format, platform backends as comptime
  interfaces. Zero-cost dispatch for anything known at compile time.
- **`@Vector` SIMD** with a scalar tail in every per-pixel kernel; measure
  before hand-tuning further.
- **Threading**: tiles across a `std.Thread.Pool`; in the shell, IO and
  rendering are separate threads feeding the UI (Ghostty's surface model).
  The GPU path (Phase 6) is an *optimization of* the CPU path — the CPU
  implementation is the reference the GPU is tested against, within the
  golden threshold.

## Testing — the interlock

Determinism, assertions, and randomized testing are one technique; each is
nearly useless alone. Deterministic execution makes failures reproducible,
assertions make corruption loud, fuzzing makes the two of them find bugs.

- **Golden harness first** (Phase 0): vendored RAW corpus, reference renders
  (dcraw/libraw/darktable-cli as oracles), perceptual-diff threshold,
  `golden/baseline.json` ratchet in CI. Every later phase keeps it green.
- **wombat is simulation-tested**: a filesystem shim injects crashes, torn
  writes, and reordering; runs are seed-reproducible; CI seeds from the git
  commit hash truncated to `u64`, so every commit explores differently and
  any failure replays from the hash. Probabilities are integer
  `Ratio{num, den}`, never floats — floats are a determinism hazard.
- **Swarm-fuzz structured inputs** (recipes, catalogs, import batches): each
  run disables a random subset of op kinds entirely and gives survivors
  wildly skewed weights; generate valid-by-construction inputs so the oracle
  is "wrong answer," not just "didn't crash."
- **Poison freed memory** (`0xAA`) in debug/stress builds so use-after-free
  fails deterministically at the use site instead of heisenbugging.
- **Snapshot tests** for CLI output, recipe JSON, and headers, with an
  update mode (`SNAP_UPDATE=1`) so exact-output assertions stay cheap.
- **`tidy.zig` from day one**, run as a test: banned constructs each with a
  named replacement, `FIXME`/`TODO(now)` allowed while iterating but
  rejected on main, the 100-column ratchet, dead-declaration detection.
  Every rule that can be mechanized is mechanized; review time goes to
  design.

## C ABI rules (`src/capi.zig` + `include/banksia.h`)

- All exports are `bk_`-prefixed; handles are opaque pointers; errors are
  integer codes plus `bk_last_error(engine)` for the message. No Zig error
  unions, no panics, no Zig types cross the boundary.
- The engine owns returned buffers; they are valid until the next call on
  the same handle. Document lifetime on every function in the header.
- The header is hand-written; when the ABI changes, change the header in the
  same commit (there is no auto-emit). CI smoke-tests the ABI from a tiny C
  program on a macOS runner — no Xcode required.
- The engine is single-threaded per handle; the Swift shell serializes calls
  through one actor. Do not add internal locking to "fix" misuse.

## Swift shell conventions

- SwiftUI, minimal: the shell exists to *see* the engine work. Sliders →
  recipe JSON → debounced background render (`max_edge` preview while
  dragging, full-res on release) → `CGImage` → view.
- Copy pixels out of the engine buffer before displaying (`Data(bytes:count:)`)
  — never let a `CGImage` alias memory the next render will overwrite.
- SwiftLint on the Swift side; the Makefile dev loop is
  `zig build && xcodebuild`.

## Workflow

- Find the current phase in `BANKSIA.md`; do the next unchecked task; check
  it off in the same commit as the implementation.
- A task isn't done until its tests exist and the phase's CI numbers hold.
  New capability without a new number is not done.
- Commit messages: what changed and why, present tense, no fluff. Zero
  technical debt policy — do it right the first time; in a photo tool the
  interest on debt is paid in someone's corrupted library.
