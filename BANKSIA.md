# banksia — a RAW photo editor in Zig

*Project proposal and phased implementation plan. Named for the banksia,
following the house style: Australian flora for projects, Australian fauna
for the libraries inside (bottlebrush/bilby precedent). Parked in this repo
for now; lives best as a fresh `banksia` repo when work starts.*

## One-liner

A headless, deterministic RAW develop engine in Zig — non-destructive edits,
content-addressed storage, and git-like versioning built in — with a thin
macOS SwiftUI shell for visual inspection, and a fast keyboard-driven
culling/develop tool as the eventual product. Engine priorities follow
Capture One, not Lightroom: colour fidelity, processing speed, and studio
workflow over UI breadth.

## Why this and not "Lightroom in Zig"

- **The product wedge**: darktable is powerful but heavy; Lightroom is a
  subscription; Photo Mechanic ($139) owns "fast culling" and does no
  developing; Capture One is the engine-quality benchmark but costs more
  than Lightroom. *Fast, minimal, keyboard-driven culling + C1-grade
  processing + real version control* is an underserved niche.
- **The byproducts** are standalone ecosystem gaps in Zig: a develop engine,
  a content-addressed store with a columnar catalog, a perceptual-hash
  library. The editor is the forcing function that makes them real.
- **The engine is headless.** `(RAW file, edit recipe) → image`,
  deterministic, no UI dependency. Testable with golden renders and oracles,
  scriptable, embeddable. The GUI — Zig's weakest ecosystem link — is an
  add-on to iterate on, not a foundation to bet on.

## Architecture

Three fauna libraries under one flora project:

| Component | Name | Scope |
|---|---|---|
| The project / app | **banksia** | C ABI, CLI, versioning semantics, export engine, the UIs |
| Develop engine | **emu** | RAW decode, colour management + camera profiles, the linear-f32 pipeline, render cache, thumbnails. Fast; only runs forward. |
| Storage | **wombat** | Content-addressed blob vault, content-defined chunking, the columnar catalog, sessions, persistence. The burrow: everything on disk. |
| Similarity | **lyrebird** | Perceptual hashing, near-duplicate detection, burst grouping, focus/sharpness scoring. The great mimic finds the copies. |

Data flow: **wombat** hands **emu** immutable RAW blobs; **emu** renders
`(blob, recipe) → image` and memoizes stage outputs back into **wombat**'s
CAS; **lyrebird** indexes blobs into burst groups and sharpness scores
stored as catalog columns; **banksia** wires it together behind a C ABI,
the CLI, and the UIs.

## Capture One influences (processing over UI)

The features worth stealing are engine features. Where each lands:

| Capture One feature | banksia take | Phase |
|---|---|---|
| Per-camera colour profiles | Hand-tunable camera profiles in emu (matrix + LUT), not just the bare DNG matrix — C1's colour reputation comes from exactly this | 5 |
| Process-engine versioning | Recipes/commits record the engine version; old commits render identically forever. Determinism + content addressing make this nearly free, and it hardens the git story | 3 |
| Sessions vs catalogs | wombat supports both: the global vault/catalog *and* self-contained folder-scoped sessions for shoots (portable, no monolith) | 2 |
| Process recipes (batch export) | One decode → many simultaneous outputs (formats/sizes/sharpening per output); parallel export queue off the render cache | 6 |
| Focus mask | Per-tile sharpness scoring (lyrebird) surfaced as a culling overlay and a sortable catalog column — cull the soft frames without zooming | 4 |
| Advanced colour editor | Targeted hue/sat/lightness by colour range; skin-tone uniformity as a range preset | 5 |
| Structure/clarity | Local-contrast ops in the pipeline | 5 |
| Layered local adjustments | Adjustment layers = op groups with masks (parametric + luma/colour range) in the recipe | 5 |
| Per-ISO noise profiles | Denoise parameterized by (camera, ISO) profile data | 5 |
| GPU-first processing | Metal compute path; CPU path stays as the reference implementation | 6 |
| Tethered capture | PTP over USB/IP → instant import → render — the studio workflow C1 owns | 7 |

## Design pillars

### The catalog is a column store — `std.MultiArrayList` is exactly that

A library is 100k+ records of heterogeneous fields, and every interesting
operation is a filter or sort touching two or three fields out of twenty:

```zig
const Asset = struct {
    hash: [32]u8,       // content address of the RAW blob
    recipe_head: u32,   // current edit version (commit id)
    capture_time: i64,
    rating: u3,
    flags: packed struct { rejected: bool, pick: bool },
    camera: CameraId,
    lens: LensId,
    iso: u32,
    burst_group: u32,   // populated by lyrebird
    sharpness: f16,     // populated by lyrebird (focus mask score)
};

catalog: std.MultiArrayList(Asset),

// "rating >= 4 shot on the 35mm" scans two dense arrays, not
// 100k scattered structs:
const ratings = catalog.items(.rating);
const lenses  = catalog.items(.lens);
```

Filtering a six-figure library becomes a couple of linear scans over
contiguous, cache-friendly, SIMD-able columns — smart collections as full
scans fast enough to skip indexes. Columns also serialize and diff cleanly,
which feeds the versioning layer.

### Pixels want SoA too — but as planes, not `MultiArrayList`

`MultiArrayList` is for growable heterogeneous records; an image is
fixed-size homogeneous data. The same struct-of-arrays argument says: store
planar `[]f32` per channel rather than interleaved RGB. Every kernel becomes
a clean `@Vector` loop:

```zig
const V = @Vector(8, f32);

fn applyExposure(plane: []f32, ev: f32) void {
    const gain: V = @splat(std.math.exp2(ev));
    var i: usize = 0;
    while (i + 8 <= plane.len) : (i += 8) {
        const v: V = plane[i..][0..8].*;
        plane[i..][0..8].* = v * gain;
    }
    while (i < plane.len) : (i += 1) plane[i] *= std.math.exp2(ev);
}
```

`MultiArrayList` returns for the record-shaped small stuff: the edit stack
(`MultiArrayList(Op)` — scan the tag column to plan the pipeline without
touching params), mask control points, tile descriptors.

### The pipeline (emu)

- **Linear scene-referred f32 end to end** (darktable's modern architecture,
  and effectively C1's too): do the math in linear light, convert to display
  space last. The single biggest correct-by-construction decision in a RAW
  pipeline.
- **Comptime specialization**: demosaic kernels monomorphized per Bayer
  pattern (RGGB/BGGR/…); ops specialized over pixel format.
- **Tiled, threaded execution**: tiles with overlap for convolution ops,
  `std.Thread.Pool` across tiles, an arena per render so cleanup is one free.
- **Content-addressed render caching**: each stage's output keyed by
  `hash(input_hash ++ op_params ++ engine_version)`, stored in wombat.
  Change the tone curve and everything upstream — including the expensive
  demosaic — is a cache hit. It's also what makes scrubbing edit *history*
  (or comparing two branches of an edit) nearly free.

### Versioning (banksia, on top of wombat)

- RAWs are immutable → the heavy data is write-once. All change lives in
  recipes and catalog state, which are kilobytes.
- **CAS vault**: import dedups by hash; blobs tier to NAS/S3; check out only
  what you're working on (the git-annex trick — history tracks references,
  not content).
- **Git-like tree over recipes + catalog**: commits, branches, merges.
  "Virtual copies" become branches of a recipe. Branching a 200GB library
  costs kilobytes.
- **Engine-versioned rendering** (the C1 idea): a commit pins the engine
  version it was made with, so historical commits render bit-identically
  even after the pipeline improves. Determinism makes this cheap; it also
  makes golden tests trivially stable.
- **Content-defined chunking (FastCDC)** for the few big files that do get
  rewritten (exports, DNG conversions): small change → store only changed
  chunks.

Honest caveat: dedup won't shrink distinct compressed RAWs — the win is
"versioning forever costs ~nothing on top of the originals," plus dedup of
the accidental copies every real library contains.

## The three hard parts, with mitigations

1. **The camera format zoo.** Hundreds of proprietary formats is why
   everyone uses libraw/rawspeed (C++). Mitigation — the bilby strategy:
   define emu's decode interface, back it with **libraw via C interop on day
   one**, write the pure-Zig decoder for **DNG first** (documented spec;
   Adobe's converter turns anything into DNG), add native CR3/NEF/ARW by
   popularity later.
2. **Colour science.** Camera matrices, white-point adaptation, gamut
   mapping — deep water; *correct* vs *pleasing* is where C1 and darktable
   spent a decade. Mitigation: the oracle exists. dcraw/libraw reference
   renders and `darktable-cli` give comparison targets, so the Test262
   workflow transplants: RAW corpus + reference outputs + perceptual-diff
   threshold = a conformance speedometer. The number only goes up. C1-grade
   *pleasing* colour then becomes profile data (Phase 5), not engine
   rewrites.
3. **The GUI.** Headless-first buys time; the Phase 1 SwiftUI harness covers
   inspection. The real UI decision (dvui vs ImGui vs custom) is deferred
   until the engine earns it.

## macOS visual harness: Zig core + SwiftUI shell

Goal: *see* the pipeline working with sliders. Not the product UI.

- Zig builds `libbanksia.dylib` exposing a tiny **C ABI** (opaque handle +
  ~6 functions). Swift imports C headers natively — no bridging codegen.
- SwiftUI app: file picker, 3–4 sliders (EV, temp, tint, contrast), an
  `Image`. Slider change → rebuild recipe JSON → background render → wrap
  pixels in `CGImage` → display. ~150 lines of Swift.

### Zig side (`src/capi.zig`)

```zig
export fn bk_engine_create() ?*Engine;
export fn bk_engine_destroy(e: *Engine) void;
export fn bk_load_raw(e: *Engine, path: [*:0]const u8) i32;         // 0 = ok
export fn bk_set_recipe_json(e: *Engine, json: [*:0]const u8) i32;  // 0 = ok
// Renders RGBA8; engine owns the buffer, valid until the next render call.
export fn bk_render(e: *Engine, max_edge: u32, out_w: *u32, out_h: *u32) ?[*]u8;
export fn bk_last_error(e: *Engine) [*:0]const u8;
```

Notes:
- Hand-write `include/banksia.h` (Zig's auto C-header emission was removed;
  at six functions, keeping it in lockstep manually is fine).
- Recipe crosses the boundary as a JSON string — trivially debuggable; swap
  for something binary later if it ever matters.
- Engine-owns-buffer is the simplest ownership contract for a harness.
- `max_edge` enables preview-resolution renders while a slider drags,
  full-res on release — the first "feels responsive" trick.

### Swift side

```
// CBanksia/module.modulemap
module CBanksia {
    header "banksia.h"
    link "banksia"
    export *
}
```

```swift
import CBanksia

let engine = bk_engine_create()
bk_load_raw(engine, path)
bk_set_recipe_json(engine, recipeJSON)
var w: UInt32 = 0, h: UInt32 = 0
if let px = bk_render(engine, 1600, &w, &h) {
    let data = Data(bytes: px, count: Int(w * h * 4))   // copy = safe to display
    // wrap in CGImage via CGDataProvider → SwiftUI Image(decorative:)
}
```

Threading contract: the engine is not thread-safe; one Swift `actor` owns
the handle and serializes render calls. Renders run off the main thread;
SwiftUI receives the finished `CGImage`.

Dev loop: a Makefile that runs `zig build` (dylib + header) then
`xcodebuild`/opens Xcode. Even before the shell exists, Phase 0's CLI
(`recipe.json + raw → png` + `open`) gives visual inspection on day one.

---

# Phased implementation

Bottlebrush rules apply: every phase ends with a measurable number in CI,
and the number only goes up.

## Phase 0 — emu bootstrap: decode, minimal pipeline, golden harness

> **Objective:** A CLI that renders a real DNG to a PNG through a linear-f32
> pipeline, scored against reference renders in CI. This phase produces the
> *speedometer* and the engine skeleton every later phase leans on.
>
> **Definition of done:** `zig build render -- shot.dng recipe.json out.png`
> works; `zig build golden` compares a small RAW corpus against committed
> reference outputs with a perceptual-diff threshold and CI fails on
> regression.

- [ ] Project skeleton: `build.zig` with steps `render` (CLI), `test`
      (unit), `golden` (conformance); `emu/`, `wombat/`, `lyrebird/` as
      module dirs from day one, even if the latter two are stubs.
- [ ] Decode interface (`emu/decode.zig`): `decode(path) → SensorData`
      (Bayer plane, CFA pattern, black/white levels, colour matrix, WB
      coefficients, orientation). The interface is the contract; backends
      are swappable.
- [ ] libraw backend via C interop (the bilby strategy: real engine behind
      the interface later).
- [ ] Pure-Zig DNG decoder for uncompressed + lossless-JPEG DNG (TIFF
      container walk, IFDs, the handful of tags that matter).
- [ ] Pipeline core (`emu/pipeline.zig`): planar `[]f32` image type; op
      stack as `MultiArrayList(Op)`; ops: black point → white balance →
      bilinear demosaic → exposure → tone curve → sRGB encode.
- [ ] `@Vector` kernels for the per-pixel ops; comptime-specialized demosaic
      per CFA pattern.
- [ ] Determinism from day one: identical output across thread counts and
      tile sizes (this is what Phase 3's engine versioning leans on). Test
      it.
- [ ] Recipe JSON: parse/serialize the op stack; recipes carry an
      `engine_version` field from the first commit.
- [ ] PNG writer (or minimal-dependency equivalent) for CLI output.
- [ ] **Golden harness**: 5–10 vendored DNGs; reference renders from
      dcraw/libraw; perceptual diff (mean ΔE or SSIM) with a committed
      threshold; `golden/baseline.json` in CI — regressions fail the build.

## Phase 1 — the C ABI and the SwiftUI inspection shell

> **Objective:** Move visual inspection from "render a PNG and `open` it" to
> live sliders. Prove the Zig↔Swift boundary before any storage work.
>
> **Definition of done:** A macOS app with EV/temp/tint/contrast sliders
> re-renders a loaded RAW live (sub-second at preview resolution); the C ABI
> surface is ≤ 8 functions and documented in `include/banksia.h`.

- [ ] `src/capi.zig` with the `bk_*` surface above; `b.addLibrary(.{
      .linkage = .dynamic })` producing `libbanksia.dylib`; install step
      copies dylib + hand-written header.
- [ ] Error-handling convention across the boundary: integer codes +
      `bk_last_error` string; no Zig errors escape.
- [ ] Xcode project (or SwiftPM app) with `CBanksia` module map; Makefile
      dev loop (`zig build && xcodebuild`).
- [ ] Swift `actor` wrapping the engine handle; renders on a background
      task; `CGImage` wrapping of the RGBA8 buffer.
- [ ] SwiftUI: file picker, sliders bound to a recipe model, debounced
      re-render, image view.
- [ ] Preview-resolution renders while dragging (`max_edge`), full-res on
      release.
- [ ] CI: build the dylib on a macOS runner; smoke-test the C ABI from a
      tiny C program (no Xcode needed in CI).

## Phase 2 — wombat: content-addressed vault + columnar catalog

> **Objective:** The storage layer: import photos into a CAS vault with
> dedup, and a columnar catalog fast enough to filter a six-figure library
> by full scan. Simulation-tested from day one. Both C1 workflow shapes:
> the global catalog and self-contained sessions.
>
> **Definition of done:** `banksia import <dir>` ingests a card, dedups
> byte-identical files, and populates the catalog; a 100k-asset synthetic
> catalog filters by rating+lens in single-digit milliseconds; the crash
> simulator (inject torn writes / kill mid-import) never loses an
> acknowledged blob across 10k randomized runs in CI.

- [ ] Blob store: BLAKE3-addressed files in a sharded object dir; write =
      hash → temp file → fsync → rename; verify-on-read mode.
- [ ] **Deterministic simulation harness** (the TigerBeetle discipline): a
      filesystem shim that injects crashes, torn writes, and reordering;
      seed-reproducible; runs in CI.
- [ ] FastCDC chunking for mutable big files (exports, catalogs); chunk
      index. Distinct RAWs won't chunk-dedup — that's fine and documented.
- [ ] Catalog: `MultiArrayList(Asset)` + string/keyword interning tables;
      snapshot-to-disk persistence with a small WAL for incremental updates.
- [ ] **Sessions** (C1): a session = a self-contained directory (vault +
      catalog + recipes scoped to one shoot), portable across machines;
      `banksia session new <dir>`; import-into-catalog from a session later.
- [ ] Import pipeline: hash → dedup check → blob write → EXIF extract
      (capture time, camera, lens, ISO) → catalog append.
- [ ] Thumbnail cache: emu renders small previews, memoized into the CAS
      (first use of the render-cache pattern).
- [ ] Filter engine: predicate → columnar scans; benchmark target in CI
      (the speedometer for this phase is a latency number).

## Phase 3 — versioning: recipes as commits, engines as versions

> **Objective:** The git layer. Every edit is a commit; virtual copies are
> branches; history is scrubbable; commits render identically forever. This
> is the feature no competitor has (C1's process-engine versioning is the
> closest, and it has no history/branches).
>
> **Definition of done:** `banksia log <photo>` shows edit history;
> `banksia branch <photo> alt-crop` forks a recipe; checking out any
> historical version re-renders via cache in under 100ms at preview size;
> a commit made under engine v1 renders bit-identically after the pipeline
> gains new ops; the version store for a 10k-photo library stays under 50MB.

- [ ] Commit model: recipe blobs (canonical-form JSON, content-addressed in
      wombat) + a commit object (parent hash, recipe hash, engine version,
      timestamp, message) — a Merkle chain per asset, plus library-level
      snapshots of catalog state.
- [ ] **Engine versioning** (C1): the pipeline registry is versioned; a
      commit's `engine_version` selects op implementations, so improving a
      curve or demosaic never silently changes old renders. New edits get
      the newest engine; `banksia upgrade <photo>` migrates explicitly.
- [ ] `recipe_head` column in the catalog points at the current commit;
      branches are named refs per asset.
- [ ] Render-cache keying by `(blob hash, recipe hash, engine version,
      stage index)` so history scrubbing and branch comparison are cache
      hits.
- [ ] CLI verbs: `log`, `branch`, `checkout`, `diff` (recipe diff — it's
      JSON, diff the op stacks structurally), `upgrade`.
- [ ] Merge = op-stack merge with conflicts surfaced (last-writer-wins per
      op as the v1 policy; real merge UI later).
- [ ] Harness-shell support: a history scrubber slider in the SwiftUI app —
      drag through an edit's history live (this is the demo).

## Phase 4 — lyrebird + the culling workflow

> **Objective:** Perceptual similarity, sharpness scoring, and the first
> *product* surface: a keyboard-driven culling grid with burst stacks and a
> C1-style focus mask.
>
> **Definition of done:** Import a 1000-shot shoot; bursts are auto-grouped;
> the grid navigates/rates/rejects entirely from the keyboard at 60fps; the
> focus overlay separates sharp from soft frames without zooming; lyrebird's
> precision/recall on a labelled burst corpus is scored in CI.

- [ ] lyrebird: dHash/pHash over emu preview renders; Hamming-distance
      BK-tree or SIMD linear scan (100k × 64-bit hashes is small — measure
      first).
- [ ] Time-windowed burst grouping (perceptual distance + capture-time
      proximity); writes the `burst_group` column.
- [ ] **Focus mask** (C1): per-tile Laplacian-variance sharpness from the
      preview render → `sharpness` column (sortable: "show me the soft
      ones") + an edge-overlay heatmap in the UI for the selected frame.
- [ ] Labelled corpus + precision/recall scoring in CI (lyrebird's
      speedometer); sharpness scored against a hand-labelled sharp/soft set.
- [ ] Culling UI (grow the SwiftUI shell): virtualized thumbnail grid off
      the columnar catalog, burst stacks collapse to the pick, J/K/arrows +
      number-key ratings, X to reject, F toggles the focus overlay; every
      action is a catalog commit (undo = version history, for free).
- [ ] `banksia dedupe` CLI: near-duplicate report across the whole library.

## Phase 5 — develop maturity: C1-grade processing

> **Objective:** From "proves the pipeline" to "produces keepers": better
> demosaic, real colour management with camera profiles, the colour editor,
> local adjustments as layers, and the develop UI.
>
> **Definition of done:** The golden-corpus perceptual score against
> darktable-cli reference renders crosses an agreed threshold; at least two
> cameras have tuned profiles that beat the bare-matrix render in a blind
> A/B; a real shoot can be culled *and* finished in banksia end to end.

- [ ] RCD (or AMaZE) demosaic behind the same comptime-specialized
      interface; golden corpus scores the improvement.
- [ ] Proper colour management: camera matrix → working space →
      display-referred output transform (filmic-style tone mapping).
- [ ] **Camera profiles** (C1's crown jewel): per-camera profile = matrix +
      1D/3D LUT, loadable as data; a profile-tuning workflow (render a
      ColorChecker shot, solve for the LUT); ship hand-tuned profiles for
      the developer's own cameras first.
- [ ] **Colour editor** (C1): targeted hue/sat/lightness adjustments by
      colour range (hue wedge + smooth falloff); skin-tone range preset with
      uniformity control.
- [ ] **Structure/clarity**: local-contrast ops (guided-filter or bilateral
      base/detail split).
- [ ] **Per-ISO denoise profiles** (C1): profiled non-local-means or wavelet
      denoise parameterized by (camera, ISO); profile data measured from
      dark/flat frames.
- [ ] **Adjustment layers** (C1): recipe ops grouped into layers, each with
      a mask — parametric shapes (elliptical/gradient), luma range, colour
      range; mask control points in `MultiArrayList`; layers compose in
      order.
- [ ] Crop/rotate with the geometry op recorded in the recipe like any
      other.
- [ ] Develop UI: single-image view, op-stack/layers panel, before/after,
      side-by-side branch comparison (the Phase 3 payoff made visual).

## Phase 6 — performance + the export engine

> **Objective:** Speed where it's felt: GPU processing, native decoders for
> the big three, and C1-style process recipes for batch export.
>
> **Definition of done:** Slider-drag re-render at preview res under 16ms on
> Apple Silicon for the common op subset; a 500-photo shoot exports to two
> simultaneous output recipes (full-res JPEG + 2048px web) saturating all
> cores; top-3 native decoders pass the golden corpus without libraw.

- [ ] Metal compute path for the hot ops (keep the CPU path as the
      reference implementation the GPU path is tested against — determinism
      contract: GPU output must match CPU within the golden threshold).
- [ ] **Process recipes** (C1): named output configurations (format, size,
      colour space, output sharpening); one develop render fans out to N
      outputs; `banksia export --recipe web --recipe print <selection>`.
- [ ] Parallel export queue: per-photo renders across the thread pool,
      reusing the render cache for shared prefixes of the op stack.
- [ ] Native decoders: CR3, NEF, ARW — validated against libraw output on
      the corpus, then libraw becomes optional.
- [ ] Tile-level parallel render-cache warming (background full-res render
      after the preview lands).
- [ ] Profile-guided pass over the catalog scans and import path at 500k
      assets.

## Phase 7 — studio: tethered capture

> **Objective:** The workflow Capture One owns and nothing open-source does
> well: camera → cable → instant render. Sessions (Phase 2) were built for
> this.
>
> **Definition of done:** A supported camera shoots tethered into a live
> session: frame lands, imports, renders with the session's default recipe,
> and appears in the grid in under 2 seconds, hands-free.

- [ ] PTP over USB (and PTP/IP for the cameras that support it); start with
      one camera family the developer owns.
- [ ] Live session ingest: capture event → wombat import → emu preview
      render → catalog append → UI update, as one streaming path.
- [ ] Session default recipe: new frames inherit the shoot's develop
      settings (white balance dialed on frame 1 applies to frame 400).
- [ ] Overlay/compare: live frame against a pinned reference frame (the
      studio use case: matching a layout comp).
- [ ] Graceful degradation: tether drops are recoverable; the simulation
      harness gets a flaky-transport mode.

## Sequencing notes

- Phases 0→1 are strictly ordered (the shell needs the ABI needs the
  engine). Phase 2 (wombat) is independent of Phase 1 and can interleave.
- lyrebird (Phase 4) needs emu previews (Phase 0) and the catalog (Phase 2)
  but not versioning (Phase 3).
- Phase 5's camera profiles and colour editor are independent of Phase 4
  and can pull forward if develop quality matters sooner than culling.
- Phase 7 (tether) depends on sessions (Phase 2) and the import path, not
  on Phases 5–6 — it can pull forward for a studio-first strategy.
- Every phase keeps the golden/bench/simulation numbers from earlier phases
  running in CI — the banksia scoreboard accretes, never resets.
