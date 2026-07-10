# firewheel — a RAW photo editor in Zig

*Project proposal. Named for the firewheel tree (Stenocarpus sinuatus), whose
flower looks like a ring of aperture blades. Naming scheme follows the house
style: Australian flora for projects, Australian fauna for the libraries
inside (bottlebrush/bilby precedent). See [Names](#names) at the end.*

## One-liner

A headless, deterministic RAW develop engine in Zig — non-destructive edits,
content-addressed storage, and git-like versioning built in — with a thin
macOS SwiftUI shell for visual inspection, and a fast keyboard-driven
culling/develop UI as the eventual product.

## Why this and not "Lightroom in Zig"

A RAW editor is four projects wearing a trenchcoat. The design work is
deciding which parts are the product and which are the byproducts:

- **The product wedge**: darktable is powerful but heavy; Lightroom is a
  subscription; Photo Mechanic ($139) owns "fast culling" and does no
  developing. *Fast, minimal, keyboard-driven culling + basic develop, with
  real version control* is an underserved niche.
- **The byproducts** are standalone ecosystem gaps in Zig: a pure-Zig
  DNG/TIFF reader, demosaic/colour kernels, a content-addressed chunk store,
  a columnar catalog engine, a perceptual-hash library. The editor is the
  forcing function that makes them real.
- **The engine is headless.** `(RAW file, edit recipe) → image`,
  deterministic, no UI dependency. Testable with golden renders and oracles,
  scriptable, embeddable. The GUI — Zig's weakest ecosystem link — becomes an
  add-on to iterate on, not a foundation to bet on.

## Architecture

Five layers, bottom to top:

1. **Decode** — camera RAW → Bayer/X-Trans sensor data + metadata (colour
   matrices, black/white levels, orientation).
2. **Pipeline** — an ordered stack of ops over linear scene-referred f32
   data: black point, white balance, demosaic, exposure, tone curve, colour
   grading, denoise, sharpen, crop. Non-destructive; the RAW is never
   modified.
3. **Recipe** — the serialized edit stack. Kilobytes, diffable, versionable.
4. **Catalog** — the library: assets, ratings, tags, bursts, collections.
5. **Store** — the content-addressed vault: RAWs deduped by hash, blobs
   tiered across local disk / NAS / S3, laptop holds only what's checked out.

## Data-oriented design (SoA everywhere, precisely)

Two distinct mechanisms; worth keeping them straight.

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
    burst_group: u32,   // populated by perceptual hashing
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
touching params), mask control points, tile descriptors for the scheduler.

## Pipeline design

- **Linear scene-referred f32 end to end** (darktable's modern
  architecture): do the math in linear light, convert to display space last.
  The single biggest correct-by-construction decision in a RAW pipeline.
- **Comptime specialization**: demosaic kernels monomorphized per Bayer
  pattern (RGGB/BGGR/…) instead of per-pixel branching; ops specialized over
  pixel format.
- **Tiled, threaded execution**: tiles with overlap for convolution ops,
  `std.Thread.Pool` across tiles, an arena per render so cleanup is one free.
- **Content-addressed render caching**: each stage's output is keyed by
  `hash(input_hash ++ op_params)`. Change the tone curve and everything
  upstream — including the expensive demosaic — is a cache hit. Build-system
  memoization applied to image ops; it's also what makes scrubbing through
  edit *history* (or comparing two branches of an edit) nearly free. Same CAS
  engine as the vault, same self-verifying-integrity property.

## Versioning layer

- RAWs are immutable → the heavy data is write-once. All change lives in
  recipes and catalog state, which are kilobytes.
- **CAS vault**: import dedups by hash; blobs tier to NAS/S3; checkout only
  what you're working on (the git-annex/LFS trick — history tracks
  references, not content).
- **Git-like tree over recipes + catalog**: commits, branches, merges.
  "Virtual copies" become branches of a recipe. "What did I cull last month
  and why" becomes history. Branching a 200GB library costs kilobytes.
- **Content-defined chunking (FastCDC)** for the few big files that *do* get
  rewritten (exports, DNG conversions, catalogs): small change → store only
  changed chunks.
- **Perceptual hashing** populates `burst_group`: bursts and re-exports
  aren't byte-identical, so crypto-hash dedup misses them; a perceptual index
  lets the culling UI collapse a 14-frame burst into one stack.

Honest caveat: dedup won't shrink distinct compressed RAWs — the win is
"versioning forever costs ~nothing on top of the originals," plus dedup of
the accidental copies every real library contains. Optional lossless
DNG-style recompression on import is the add-on if actual size reduction is
wanted.

## The three hard parts, with mitigations

1. **The camera format zoo.** Hundreds of proprietary formats is why
   everyone uses libraw/rawspeed (C++). Mitigation — the bilby strategy:
   define the decode interface, back it with **libraw via Zig C interop on
   day one**, write the pure-Zig decoder for **DNG first** (documented spec;
   Adobe's converter turns anything into DNG), then add native CR3/NEF/ARW
   by popularity. Productive immediately, de-risked incrementally.
2. **Colour science.** Camera matrices, white-point adaptation, gamut
   mapping, filmic tone mapping — deep water; *correct* vs *pleasing* is
   where darktable spent a decade. Mitigation: the oracle exists.
   dcraw/libraw reference renders and `darktable-cli` give comparison
   targets, so the Test262 workflow transplants: RAW corpus + reference
   outputs + perceptual-diff threshold = a conformance speedometer. The
   number only goes up.
3. **The GUI.** Headless-first buys time. The mac harness below covers
   inspection; the real UI decision (dvui vs ImGui vs custom wgpu) is
   deferred until the engine earns it.

## macOS visual harness: Zig core + SwiftUI shell

Goal: *see* the pipeline working with sliders, nothing more. Not the
product UI.

### Shape

- Zig builds `libfirewheel.dylib` exposing a tiny **C ABI** (opaque handle +
  ~6 functions). C is the lingua franca: Swift imports C headers natively,
  no bridging code generation needed.
- SwiftUI app: file picker, 3–4 sliders (EV, temp, tint, contrast), an
  `Image`. Slider change → rebuild recipe JSON → background render → wrap
  pixels in `CGImage` → display. ~150 lines of Swift.

### Zig side (`src/capi.zig`)

```zig
export fn fw_engine_create() ?*Engine;
export fn fw_engine_destroy(e: *Engine) void;
export fn fw_load_raw(e: *Engine, path: [*:0]const u8) i32;         // 0 = ok
export fn fw_set_recipe_json(e: *Engine, json: [*:0]const u8) i32;  // 0 = ok
// Renders RGBA8; engine owns the buffer, valid until the next render call.
export fn fw_render(e: *Engine, out_w: *u32, out_h: *u32) ?[*]u8;
export fn fw_last_error(e: *Engine) [*:0]const u8;
```

Notes:
- Hand-write `include/firewheel.h` (Zig's auto C-header emission was
  removed; the surface is 6 functions, keep it in lockstep manually).
- Recipe crosses the boundary as a JSON string for now — trivially debuggable,
  swap for something binary later if it ever matters.
- Engine-owns-buffer is the simplest ownership contract for a harness;
  revisit for the real UI.
- Build: `zig build -Dlib` producing the dylib
  (`b.addLibrary(.{ .linkage = .dynamic, ... })`), plus an install step that
  copies dylib + header where Xcode looks.

### Swift side

Module map so Swift can import the C header:

```
// CFirewheel/module.modulemap
module CFirewheel {
    header "firewheel.h"
    link "firewheel"
    export *
}
```

```swift
import CFirewheel

let engine = fw_engine_create()
fw_load_raw(engine, path)
fw_set_recipe_json(engine, recipeJSON)
var w: UInt32 = 0, h: UInt32 = 0
if let px = fw_render(engine, &w, &h) {
    let data = Data(bytes: px, count: Int(w * h * 4))   // copy = safe to display
    let provider = CGDataProvider(data: data as CFData)!
    let image = CGImage(width: Int(w), height: Int(h),
        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(w) * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
        provider: provider, decode: nil, shouldInterpolate: false,
        intent: .defaultIntent)
}
```

SwiftUI glue:

```swift
@Observable final class DevelopModel {
    var ev = 0.0, temp = 6500.0, tint = 0.0
    var preview: CGImage?
    private let renderer = RendererActor()   // serializes access to the engine

    func recipeChanged() {
        Task { preview = await renderer.render(recipeJSON()) }  // debounce later
    }
}

struct DevelopView: View {
    @State var model: DevelopModel
    var body: some View {
        VStack {
            if let img = model.preview {
                Image(decorative: img, scale: 1).resizable().scaledToFit()
            }
            Slider(value: $model.ev, in: -4...4) { Text("EV") }
                .onChange(of: model.ev) { model.recipeChanged() }
            // temp / tint / contrast sliders likewise
        }
    }
}
```

Threading contract: the engine is not thread-safe; one Swift `actor` owns the
handle and serializes render calls. Renders run off the main thread; SwiftUI
just receives the finished `CGImage`.

### Dev loop

```
make            # zig build (dylib + header) && xcodebuild / open Xcode
```

A Makefile that rebuilds the dylib and pokes Xcode is enough. Even before
the Swift shell exists, phase 0's CLI (`recipe.json + raw → png` + `open`)
gives visual inspection on day one. Half-resolution render while a slider is
dragging, full-res on release, is the first "feels responsive" trick when
needed.

## Testing

- **Golden renders**: RAW corpus + committed reference outputs + perceptual
  diff threshold; dcraw/libraw/darktable-cli as oracles. Baseline file in CI;
  regressions fail the build (the bottlebrush speedometer pattern).
- **Property tests**: ops idempotent/commutative where they should be;
  pipeline deterministic across thread counts and tile sizes.
- **Vault**: simulation-tested — inject crashes/torn writes mid-import,
  verify the store never loses an acknowledged byte. Content addressing is a
  built-in oracle: the data proves its own integrity.

## Phases

- **Phase 0** — DNG decode (+ libraw fallback), linear pipeline: WB →
  bilinear demosaic → exposure → tone curve → sRGB. CLI:
  `recipe.json + raw → png`. Golden-render tests from day one.
- **Phase 1** — C ABI + the SwiftUI inspection shell (sliders → render).
- **Phase 2** — CAS vault + import/dedup; columnar catalog with persistence;
  thumbnail cache.
- **Phase 3** — recipe versioning: commits, branches, history scrubbing via
  the render cache.
- **Phase 4** — culling UI: grid, burst stacks, ratings, keyboard-driven.
- **Phase 5** — develop UI; better demosaic (RCD/AMaZE), denoise,
  masks/local adjustments.
- **Phase 6** — GPU compute path (Metal/wgpu); native decoders for the top
  camera formats.

## Names

House style: Australian flora for projects, fauna for the libraries inside.

| Component | Name | Why |
|---|---|---|
| The editor (project) | **firewheel** | Stenocarpus sinuatus — the flower is a ring of aperture blades |
| RAW decoder | **quokka** | the selfie animal; it gets the picture out |
| CAS vault / chunk store | **bowerbird** | collects treasures and arranges them by colour |
| Columnar catalog | **wombat** | master burrower; famously cubic output — structured storage |
| Colour management | **lorikeet** | rainbow lorikeet — the colour bird |
| Perceptual hash / dedup | **lyrebird** | the great mimic — finds near-duplicates |
| Pipeline / render engine | **emu** | fast and only runs forward, like the pipeline |
| Thumbnails / previews | **budgie** | small and colourful |

Alternate project names if firewheel doesn't stick: **waratah** (bold, iconic,
photogenic), **banksia**, **quandong**, **grevillea**.
