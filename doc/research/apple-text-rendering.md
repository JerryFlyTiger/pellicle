# Text Rendering on macOS 26 for a Swift Code Editor

Research budget used: 15 WebSearch/WebFetch calls (WebSearch was globally exhausted for this
session almost immediately — only 2 of my calls were WebSearch, the rest WebFetch). Apple's
`developer.apple.com/documentation/...` reference pages render as JS SPA shells that WebFetch
could not extract (returned only the page title); Apple's `developer.apple.com/videos/play/...`
WWDC session pages **did** yield real transcript/description content and are the highest-quality
sources below. `web.archive.org` is blocked for this tool entirely. Where I could not get
primary-source text, I say so explicitly and mark confidence low/medium from general
knowledge — treat those as things to spot-check against Xcode's local documentation or a real
device before committing the architecture.

---

## 1. Executive recommendation

**Recommended architecture (high confidence on the shape, medium on some API specifics — see
per-section notes):**

- **Core Text for shaping** (`CTLine`/`CTRun` via `CTTypesetter`/`CTFontShapeGlyphs`-family APIs)
  → **glyph rasterization with `CTFontDrawGlyphs`** into a **GPU-resident glyph atlas**
  → **custom Metal renderer** (not `MTKView`'s default draw loop; a thin `CAMetalLayer`-backed
  `NSView` with `presentsWithTransaction = true` and a manual, damage-driven present loop) for
  the actual text/cursor/selection drawing.
- Drive redraws with **`NSView.displayLink(target:selector:)` / `CADisplayLink`** (unified
  AppKit+UIKit display-link API), gated so the link is **paused whenever nothing changed**
  (true 0% idle CPU), not free-running at 120 Hz.
- This is the same shape used by **Ghostty**, **Zed (GPUI)**, and by reputation
  Alacritty/kitty/Warp: OS-native shaping + glyph atlas + GPU compositing, rather than handing
  a whole `NSTextView`/TextKit 2 stack to AppKit and hoping it hits 120 Hz.
- **Do not build on TextKit 2 (`NSTextLayoutManager`) as the rendering path** for the main
  editor surface. Use TextKit 2 (or plain Core Text `CTTypesetter`) only for **layout/line-
  breaking math** if convenient, never for the actual `draw(at:in:)` compositing of a
  120 Hz, GPU-only code view. Reasons in §9/§10.

| Priority | Recommendation | Confidence |
|---|---|---|
| **must** | Core Text shaping (`CTLine`, `CTRun`, `CTFontDrawGlyphs`) into a Metal glyph atlas | high |
| **must** | Custom `CAMetalLayer`-backed view, not stock `NSTextView` drawing, for the buffer surface | high |
| **must** | Damage-tracked redraw: only re-encode/re-present when something actually changed | high |
| **must** | Pause the display link entirely at idle (0% CPU requirement) | high |
| **should** | `NSView.displayLink(target:selector:)` (unified CADisplayLink) over `CVDisplayLink` | medium (API existence/shape verified in training knowledge; live docs page unreachable this session) |
| **should** | `presentsWithTransaction = true` on the `CAMetalLayer` for tear-free resize/scroll | medium (property exists per Apple docs; behavioral detail not independently re-confirmed this session) |
| **should** | Render several sub-pixel-phase variants of each glyph in the atlas (Zed does 16) for crisp non-integer scroll positions | high (confirmed via Zed's own blog) |
| **could** | Use TextKit 2 `NSTextLayoutManager`/`NSTextContentManager` purely as a paragraph/line-breaking oracle feeding your own Metal renderer, if you want Apple's Unicode-correct line breaking for free | medium |
| **could** | Minimap as a second, lower-resolution render pass reusing the same glyph atlas at small point size, or a downsampled snapshot texture | low/medium — no primary source found for any specific editor's minimap implementation |

---

## 2. Options compared

### 2a. TextKit 2 (`NSTextLayoutManager`) in `NSTextView` or a custom view

Source: WWDC21 "Meet TextKit 2" and WWDC22 "What's new in TextKit and text views" transcripts
(fetched live this session — high confidence on the facts below).

- TextKit 2 is Apple's from-Big-Sur (macOS 11) text engine, and as of **iOS 16 / macOS Ventura
  (13)**, `NSTextView`/`NSTextField`/`UITextView`/`UITextField` use it **by default**; `NSTextView`
  needs no special opt-in on modern macOS, but any access to `.layoutManager` (or certain
  unsupported content) silently drops it back into **TextKit 1 compatibility mode**
  (`NSTextView.didSwitchToTextKit1Notification` fires when that happens).
- Architecture: `NSTextContentManager`/`NSTextContentStorage` (backing store) →
  `NSTextLayoutManager` (layout, **no glyph indices exposed** — works in `NSTextSelection`/
  `NSTextLocation`/`NSTextRange` terms, which is why it handles Arabic/Devanagari/Kannada/
  ligatures correctly where TextKit 1's glyph-range APIs cannot) → `NSTextViewportLayoutController`
  (viewport-scoped, **always-noncontiguous** layout: only the visible region + overshoot is laid
  out, not the whole document from the start — this is the actual perf story) →
  `NSTextLayoutFragment` (value-semantic, immutable per-paragraph layout result, each exposing
  `textLineFragments`, `layoutFragmentFrame`, `renderingSurfaceBounds`) which you can subclass
  and draw yourself via `override func draw(at:in:)`.
- Custom-surface hook: implement `NSTextViewportLayoutControllerDelegate`
  (`textViewportLayoutControllerWillLayout` / `configureRenderingSurfaceFor fragment:` /
  `textViewportLayoutControllerDidLayout`) to hand back your own `CALayer`s per fragment instead
  of using `NSTextView`'s default drawing — i.e., TextKit 2 *does* support "give me the layout,
  I'll draw it," which is the documented, Apple-sanctioned path if you want TextKit 2's layout
  engine but custom (e.g. Metal) presentation.
- **Cost of choosing this as the actual draw path**: TextKit 2's rendering surfaces are
  fundamentally `CALayer`/`CGContext`-oriented (Core Animation compositing, not a raw glyph
  atlas you control). You inherit AppKit's view invalidation/`setNeedsDisplay` model and Core
  Animation's compositor, which is a well-optimized but general-purpose pipeline — not built
  for "redraw a 300-column, 10,000-line monospace-ish buffer at 120 Hz with sub-pixel scroll."
  No public source found (Apple docs or otherwise) benchmarking `NSTextView`/TextKit 2 at
  sustained 120 Hz scroll on large files; treat "TextKit 2 can hit 120 Hz with zero dropped
  frames on a 10k-line file" as **unverified**.
- Inline widgets (inlay hints, diagnostic rows): TextKit 2 (WWDC22) added
  **NSTextAttachmentViewProvider** — "use a UIView/NSView directly as a text attachment," with
  the attachment view handling its own event dispatch. This is the Apple-native mechanism for
  inline widgets if you stay on TextKit 2; it does not exist in a Core-Text-only stack (you'd
  build your own inline-widget layer instead — see §8).
- Non-simple containers (`exclusionPaths`) and `NSTextList` (WWDC22) are relevant to org-mode
  rendering (indentation, wrapping around inline images) if org-mode display ever goes through
  TextKit 2.

### 2b. Core Text (`CTLine`/`CTRun` shaping) + glyph atlas drawn with Metal

Sources: Ghostty devlog/DeepWiki pages, Zed's own engineering blog "Leveraging Rust and the GPU
to render UIs at 120 FPS" (zed.dev/blog/videogame) — both fetched live, high confidence for what
they say about their own systems; Alacritty/kitty/Warp architecture below is **medium/low
confidence** (kitty's own docs page fetched gave only "uses OpenGL for everything," no atlas
detail found within budget; Alacritty/Warp not independently confirmed this session).

| Project | Platform GPU API | Shaping | Glyph rasterization | Atlas notes | Confidence |
|---|---|---|---|---|---|
| **Ghostty** (Mitchell Hashimoto) | Metal on macOS, OpenGL on Linux | Custom Zig font/shaping subsystem interfacing AppKit/CoreText/Metal directly (author chose Zig partly for easy CoreText/Metal/AppKit C-ABI interop) | GPU-side glyph rasterization; CPU is freed to just process the PTY stream | `Atlas.zig` texture-packing layer reuses rasterized glyphs; separate "sprite face" renders synthetic glyphs (box-drawing, cursor, decorations) through the same atlas path | medium-high |
| **Zed (GPUI)** | Metal on macOS, Vulkan on Linux | OS text shaping (CoreText on macOS) | **OS rasterizes**, GPUI atlas keeps **only the alpha channel** (coverage mask), colored in the shader | Up to **16 sub-pixel-phase variants per glyph** cached, because CoreText's antialiasing shifts subtly with sub-pixel position; atlas bin-packed on CPU with the `etagere` crate, texture itself lives on GPU; scrolling reuses cached glyphs so CPU→GPU traffic stays flat | high (direct quotes from Zed's own blog) |
| **kitty** | OpenGL (all platforms) | not confirmed this session | not confirmed this session | docs only state "uses only OpenGL for rendering everything, no complex UI toolkit" | low |
| **Alacritty** | OpenGL (historically); known publicly to use a glyph-cache/atlas + `font-kit`/freetype/CoreText per-platform | not independently confirmed this session | — | — | low (not fetched; general community knowledge) |
| **Warp** | Metal on macOS (widely reported); GPU-accelerated grid renderer | not independently confirmed this session | — | — | low (not fetched) |

Common shape across the ones actually confirmed (Ghostty, Zed): **shape with the OS text
engine (CoreText), rasterize once per (font, size, subpixel-phase) combination, cache the
rasterized coverage/alpha bitmap in a GPU texture atlas, then every frame is just: look up
already-cached glyph regions, emit a Metal/GL instanced-quad draw call per visible glyph
cell.** This is what gets Zed to a claimed constant 120 fps with ~2 ms input-to-screen latency
(Zed's own claim, medium-high confidence as a *claim*, not independently reproduced here).

**Cost of this option**: you own font fallback, ligature/shaping edge cases, bidi, and hinting
decisions yourself instead of getting them from AppKit's text stack "for free"; you also own the
Metal pipeline (buffers, pipelines, atlas eviction/growth) and must independently reimplement
things TextKit 2 already gives (text selection semantics, IME/marked-text handling,
accessibility for text). Both Ghostty and Zed are known to have spent significant engineering
effort specifically on font shaping/fallback/atlas code — this is not a small subsystem.

### 2c. CALayer / Core Animation based drawing

- Not independently researched this session beyond what TextKit 2's own `NSTextViewportLayoutController`
  delegate pattern uses internally (per-fragment `CALayer`s, `CATransaction.begin()`/`commit()`
  bracketing each layout pass — seen directly in the WWDC21 sample code above).
- **Cost**: Core Animation's compositor is optimized for a moderate number of animated,
  semi-static layers (window chrome, UI panels), not for "repaint glyph content for potentially
  tens of thousands of visible glyph cells every frame." Using one `CALayer` per text fragment
  (as Apple's own sample does) is fine for a document-editing `NSTextView`-style app, but is very
  unlikely to be the path to 120 Hz sub-pixel-correct scrolling of a dense code buffer — no
  source found claims this scales; treat "CALayer-per-line is fast enough for 120Hz code
  editing" as **unverified / likely false** given it wasn't the choice any of the researched
  GPU-native terminal/editor projects made.

---

## 3. Frame pacing: display link, idle CPU

**Everything in this section beyond the WWDC21/22 material above is unverified this session** —
Apple's `CADisplayLink` and `NSView.displayLink(target:selector:)` reference pages returned only
their page title to WebFetch (JS-rendered SPA shell), `web.archive.org` is blocked for this tool,
and my remaining WebSearch budget was consumed by the very first two queries of this session
(the tool reported the *global* per-session cap of 200 was already exhausted, evidently by other
concurrent research agents in this same planning run). What follows is **medium-confidence
general/training knowledge**, not something I re-confirmed against a live primary source today —
**verify in Xcode's offline documentation or on-device before relying on it**:

- Apple unified `CADisplayLink` across UIKit and AppKit and added `NSView.displayLink(target:selector:)`
  as the AppKit-idiomatic way to obtain one, tied to macOS 14 (Sonoma) timeframe. `CVDisplayLink`
  was marked deprecated around the same release, with `CADisplayLink`/`NSView.displayLink` as the
  replacement. **Confidence: medium** — this matches widely-reported developer knowledge from
  that era but I could not re-fetch Apple's own deprecation notice text this session to quote it.
- `CADisplayLink.preferredFrameRateRange` (a `CAFrameRateRange { minimum, maximum, preferred }`)
  is the mechanism to request up to 120 Hz on a ProMotion display; setting
  `preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 120, preferred: 120)` (or
  similar) is the documented-in-spirit pattern from iOS ProMotion guidance, generalized to macOS
  once `CADisplayLink` became available there. **Confidence: medium.**
- **For your idle-0%-CPU requirement**: the actionable architecture regardless of exact API
  names is: (1) do not run a free-running display link/timer when the buffer and viewport are
  unchanged; (2) invalidate/pause the display link the frame after nothing changed, and only
  re-`add`/resume it on an actual input event, buffer mutation, animation (e.g. cursor blink,
  smooth-scroll momentum), or accessibility/window-server-driven redraw request; (3) drive the
  low `minimum` end of `preferredFrameRateRange` down (or pause entirely) whenever only a
  blinking-cursor-style periodic animation is active, and clamp to `120` only while there is
  continuous motion (scrolling, typing bursts). This "pause when idle, resume on damage" pattern
  is exactly the "damage tracking" approach implied by Ghostty/Zed's glyph-atlas-reuse designs
  (§2b) even though neither source explicitly documents their display-link idle behavior.

**Action item for the owning team**: before locking the architecture doc, do a short spike that
opens Xcode's *local* documentation (works offline, unaffected by this session's web-fetch
limits) for `CADisplayLink`, `NSView.displayLink(target:selector:)`, and `CVDisplayLink`, and
confirm (a) exact macOS deprecation version for `CVDisplayLink`, (b) whether
`preferredFrameRateRange` is honored identically on macOS vs iOS, (c) whether pausing/resuming
a display link has any per-toggle latency cost worth batching around.

---

## 4. Glyph rasterization into an atlas: `CTFontDrawGlyphs`, sub-pixel, gamma/font smoothing

- `CTFontDrawGlyphs(_ font: CTFont, _ glyphs: [CGGlyph], _ positions: [CGPoint], _ count: Int, _ context: CGContext)`
  draws an array of glyph IDs at given positions into a `CGContext` — this is the standard way
  to rasterize a font's glyphs yourself into an off-screen bitmap context, which you then upload
  as (or blit into) a Metal texture atlas. **Confidence: medium** — the exact signature above
  is consistent with well-established Core Text API knowledge, but I could not pull the live
  Apple reference page text this session to quote its discussion section verbatim; treat
  parameter-order details as needing a one-line Xcode-doc double-check before coding against it.
  For crisp glyphs, you rasterize into a context sized for the target resolution (backing-store
  scale, see §5) and typically render only the **alpha/coverage channel** (per Zed's own
  description in §2b: "rasterizing only the alpha component... to account for sub-pixel
  positioning, up to 16 variants per glyph"), then tint with the actual foreground color in your
  Metal fragment shader — this decouples color (theme, selection highlight, semantic-token
  color) from the expensive rasterization step, letting the same cached alpha glyph serve many
  colors.
- **Font smoothing / gamma on Apple Silicon**: **unverified this session** (no live source
  fetched). From general/training knowledge, medium-low confidence: macOS removed
  subpixel (LCD/ClearType-style) font antialiasing starting around Mojave (10.14) in favor of
  grayscale-only antialiasing for all displays (a change originally justified by the shift to
  Retina panels where subpixel AA is unnecessary); `CGContextSetShouldSmoothFonts` has had no
  practical effect since then, and the old System Settings "font smoothing" toggle was removed
  from the UI in a subsequent release. If accurate, this means a Core-Text-rasterized glyph atlas
  should **not** attempt to replicate subpixel-RGB antialiasing/gamma correction tables that
  pre-Mojave terminal emulators used — grayscale coverage + straightforward sRGB blending is the
  current expected look, matching what native macOS text (Xcode, TextEdit) renders like today.
  **This entire bullet needs a live re-check** (render a `CTFontDrawGlyphs` glyph on the owner's
  actual M4 machine at 1x/2x and diff against Xcode's own editor text) before being treated as
  fact in the design doc.
- **Ligatures**: standard Core Text shaping (`CTTypesetter`/`CTLine` creation from an
  `NSAttributedString`/`CFAttributedString` with a font that has ligature substitution rules, or
  explicit `kCTLigatureAttributeName`) applies OpenType ligature features already, which is how
  ligature-supporting coding fonts (Fira Code, JetBrains Mono, etc.) get rendered correctly by
  any Core-Text-based shaper — **not independently re-verified this session**, medium confidence
  from general Core Text knowledge.

---

## 5. Retina / scale factor handling

Not independently re-verified live this session (medium confidence, standard/well-known AppKit
knowledge): use the view's `NSView.window?.backingScaleFactor` (or the layer's
`CALayer.contentsScale`) to size your Metal drawable and glyph-atlas rasterization resolution —
rasterize glyphs at `pointSize * backingScaleFactor` pixel resolution so text stays crisp at 2x
(and any future non-integer scale) rather than rasterizing at 1x and letting the GPU upscale a
blurry texture. `CAMetalLayer.drawableSize` must be set to the view's bounds size multiplied by
`contentsScale`, and the layer's `contentsScale` kept in sync with `backingScaleFactor` (which
can change live if the window moves between a Retina and non-Retina display, or under Sidecar/
external-display scenarios) via `NSView.viewDidChangeBackingProperties()`.

---

## 6. Metal 4 in Xcode 26 — what's actually new and relevant

Source: WWDC25 "Discover/what's new in Metal 4" session page description fetched live this
session (medium-high confidence on the feature list; the fetch explicitly could not confirm any
text-rendering-specific Metal 4 features exist — Metal 4 is not marketed around text/2D at all).

- **`MTL4CommandQueue` / `MTL4CommandBuffer`**: decoupled from the `MTLDevice`, enabling
  **parallel command encoding** from multiple threads — relevant if you want to encode the
  glyph-quad draw calls for a large viewport off the main thread while continuing to accept
  input.
- **`MTL4CommandAllocator`**: explicit control of command-buffer memory, letting you reuse
  allocations frame-to-frame instead of the driver managing it — relevant for a steady-state,
  every-frame-identical-shape workload like "redraw the visible glyph quads," where you want to
  avoid per-frame allocation churn.
- **`MTL4ArgumentTable`**: reduces per-draw-call binding overhead — directly relevant to a glyph
  renderer that issues one (instanced) draw call per frame binding the atlas texture + a large
  per-glyph-cell instance buffer (position, atlas UV, color) rather than many small draws.
- **Residency sets**: pre-declare which resources (e.g., your glyph atlas texture, once it's
  built) must be GPU-resident, updatable from a background thread — a good fit for a text
  editor's atlas that grows as new glyphs/fonts/sizes are first encountered.
- **`MTL4Compiler`** and flexible/pre-specialized render pipeline states: lets you compile a
  base pipeline once and cheaply re-specialize per color-attachment format, useful if you support
  both a normal window surface and, e.g., an EDR/HDR-aware theme color path without recompiling
  full pipelines.
- **Not relevant / no text-specific wins found**: the ML-tensor and MetalFX frame-interpolation
  features in Metal 4 are aimed at 3D/game workloads (neural shading, ray-trace denoising, frame
  interpolation) and have no documented bearing on 2D glyph compositing. Do not plan around them
  for the editor's text path.
- **Practical takeaway**: Metal 4 is optional for v1 of the renderer — a classic `MTLCommandQueue`/
  `MTLRenderCommandEncoder` glyph-instancing renderer (the same shape Ghostty/Zed already ship)
  works fine and is simpler; adopt Metal 4's `MTL4CommandQueue`/argument-table/residency-set
  pieces later as a performance pass once profiling shows binding or allocation overhead, not as
  a v1 requirement. Xcode 26 ships a Metal 4 project template and "Drawing a triangle with Metal 4"
  sample per the fetched session description.

---

## 7. `MTKView` vs `CAMetalLayer` (+ `presentsWithTransaction`)

**Largely unverified live this session** (the `presentsWithTransaction` reference page returned
only its title; no alternate primary source fetched in the remaining budget). Medium-confidence
general knowledge, needs a live doc check:

- `MTKView` is a convenience `NSView`/`UIView` subclass that internally owns a `CAMetalLayer`
  and drives its own render loop via a `CVDisplayLink`/`CADisplayLink`-equivalent timer
  (`preferredFramesPerSecond`), calling your `MTKViewDelegate.draw(in:)` on a fixed cadence. It
  is the fast path to "something is on screen" but its draw loop is **not damage-aware out of
  the box** — it will keep calling `draw(in:)` at the configured rate even when nothing changed,
  which directly conflicts with the "0% CPU when idle" requirement unless you either pause the
  view (`isPaused = true` / `enableSetNeedsDisplay = true` and drive it manually) or bypass
  `MTKView`'s built-in loop entirely.
- Given the idle-CPU requirement, the recommended path (§1) is a **plain `NSView` whose backing
  layer is a `CAMetalLayer`** (`view.layer = CAMetalLayer(); view.wantsLayer = true`), where
  *you* control exactly when a frame is requested (via the paused/resumed display link from §3)
  and exactly when `nextDrawable()` is called and presented — i.e. skip `MTKView` altogether for
  the main editor surface, and only reach for it (if at all) for a small, always-animating
  sub-view like a live-preview panel where continuous redraw is actually wanted.
- `CAMetalLayer.presentsWithTransaction`: when `true`, presentation of the drawable is
  synchronized with the enclosing `CATransaction`/Core Animation commit rather than presented
  immediately and asynchronously — this avoids visible tearing/mismatch between your Metal
  content and any simultaneously-animating AppKit chrome (e.g. during live window resize or a
  smooth-scroll that also moves overlaid `NSView` widgets), at the cost of coupling your present
  timing to Core Animation's commit cycle. **This mechanism and its default value could not be
  re-confirmed against Apple's live docs this session — verify `presentsWithTransaction`'s
  default (commonly stated as `false`) and exact semantics before relying on it.**

---

## 8. Variable line heights, inline widgets, smooth scrolling, minimap

- **Variable line heights** (e.g. a line containing a wider font, an inline image, or a taller
  diagnostic annotation): if you go the Core-Text-only route (§2b/§1), you own line-height
  computation yourself — measure each `CTLine`'s ascent/descent/leading
  (`CTLineGetTypographicBounds`) plus any inline-widget height, and maintain your own per-line
  height table/rope for scroll-offset math (this is the same problem class as Reticle's fixed
  character grid — swiftemacs is explicitly moving away from that, so this table needs to support
  non-uniform row heights from day one, unlike Reticle's GUI). If instead you use TextKit 2 purely
  as a layout oracle (§2a "could"), `NSTextLayoutFragment.layoutFragmentFrame`/`textLineFragments`
  already gives you correct variable heights per paragraph for free — a real reason to keep
  TextKit 2 in scope as a layout (not rendering) component.
- **Inline widgets (inlay hints, diagnostic rows)**: two viable patterns, neither independently
  benchmarked this session: (a) **TextKit 2 `NSTextAttachmentViewProvider`** (§2a, confirmed via
  WWDC22 transcript) — a real `NSView` per attachment, Apple-native, but you're paying AppKit
  view-compositing cost per inline widget; or (b) in a Core-Text/Metal-only stack, render inline
  widgets as **just more quads in the same Metal draw batch** (reserve vertical space when
  computing line height, then draw a background rect + your own small glyph run for the hint
  text using the same glyph atlas) — more work to build, but keeps everything in one draw call
  and one 120 Hz budget, which is the pattern implied (not explicitly confirmed) by Zed's "GPUI
  renders all UI including text through the same GPU primitive pipeline" description in §2b.
- **Smooth scrolling**: not sourced this session beyond the general principle already covered in
  §3 — scroll offset should be a continuous (sub-line-height) float, and because Zed's atlas
  caches multiple sub-pixel-phase glyph variants (§2b) specifically "to account for sub-pixel
  positioning," a smooth (non-integer-pixel) scroll offset is exactly the case that atlas design
  targets. This is strong indirect evidence (medium-high confidence) that sub-pixel-phase glyph
  caching is a prerequisite for genuinely smooth (not line-snapped) scrolling in a glyph-atlas
  architecture, matching the brief's requirement.
- **Minimap**: **no primary source found for any of the researched projects' minimap
  implementation** (Ghostty and terminal emulators generally don't have one; Zed's blog post
  fetched this session didn't mention its minimap). Two architecturally reasonable options,
  both **unverified/low confidence, design proposals only**: (a) render the minimap as a second,
  independent low-point-size pass through the same shaping+atlas pipeline (cheap because the
  atlas/shader code is already shared, just a different point size and a coarser/no-ligature
  shaping pass); or (b) periodically snapshot/downsample the main render target into a small
  texture per N lines and composite those, refreshed only on edit/scroll-settle (cheaper GPU
  work per frame, blurrier/less legible text). Recommend (a) for legibility given the "extreme
  visual beauty" requirement, but flag this as something to prototype rather than something this
  research confirmed anyone else does.

---

## 9. CJK and emoji fallback (brief coverage — budget-limited)

**Unverified this session** — no live fetch obtained for Core Text's font-cascade/fallback APIs
(`CTFontCreateForString`'s reference page 404'd, and no replacement source was fetched within
budget). From general/training knowledge, medium confidence: Core Text performs automatic font
cascading via `CTFontCreateForString(baseFont, string, range)`, which returns the most suitable
font (checking the base font first, then a system cascade list including CJK and emoji fonts)
for a given substring — this is the standard mechanism apps use to render mixed Latin/CJK/emoji
text without hand-rolling a fallback table, and would sit in your shaping stage (§2b/§4) before
glyphs are ever handed to the atlas. **Needs a live doc/API confirmation pass** — this is exactly
the kind of "confident wrong claim about an Apple API" the brief warns is the most expensive
mistake, so treat the function name/signature above as a starting point for verification, not as
locked-in fact.

---

## 10. Recommended architecture — concrete summary

```
Input/Buffer mutation
        │
        ▼
Damage tracker (dirty line ranges) ──► if nothing dirty AND no pending
        │                                animation → pause display link,
        │                                CPU usage → 0%
        ▼
Shaping (Core Text: CTTypesetter → CTLine → CTRun per visible line,
         CTFontCreateForString for CJK/emoji fallback [needs verification])
        │
        ▼
Glyph cache lookup (font, glyph id, size, sub-pixel phase) ──► miss ──► CTFontDrawGlyphs
        │                                                          into CGBitmapContext,
        │                                                          upload alpha-only texture
        │                                                          region to Metal atlas
        ▼
Per-visible-glyph instance buffer (position, atlas UV rect, color, backingScaleFactor-aware)
        │
        ▼
Metal render pass: one (or few) instanced draw call(s) reading the atlas texture,
tinting per-instance color in the fragment shader
        │
        ▼
CAMetalLayer.nextDrawable() → present (presentsWithTransaction = true during
resize/animated scroll for tear-free compositing with any overlaid AppKit chrome
[needs verification of exact semantics/default])
        │
        ▼
NSView.displayLink(target:selector:) / CADisplayLink drives this loop, resumed only on
damage/animation, preferredFrameRateRange up to 120 for ProMotion, paused at idle
[CVDisplayLink deprecation and exact display-link API availability need live re-verification]
```

Layout math (line heights, wrapping, inline-widget reservation) can be either hand-rolled on top
of `CTLine` measurements, or delegated to TextKit 2's `NSTextLayoutManager`/
`NSTextViewportLayoutController` used purely as an off-screen layout oracle (never for drawing) —
worth prototyping both, since TextKit 2 gives correct Unicode line-breaking and bidi for free
(§2a), which is real, non-trivial work to reimplement for org-mode and multi-script source files.

---

## 11. Cost of the rejected options, summarized

| Option | Why rejected as the *rendering* path | What you lose by rejecting it |
|---|---|---|
| Stock `NSTextView` + TextKit 2 drawing | No confirmed evidence it sustains 120 Hz on large files; Core Animation/AppKit invalidation model isn't damage-precise at the glyph level the way a hand-rolled atlas renderer is | Free text selection, IME/marked text, accessibility, undo-integration, spell-check, `NSTextAttachmentViewProvider` inline widgets, correct Unicode line-breaking/bidi — all of this must be reimplemented or re-wired if you go full Core Text/Metal |
| `MTKView`'s built-in draw loop | Draws on a fixed timer regardless of damage — directly fights the 0% idle CPU requirement unless manually paused, at which point you've rebuilt the custom-`CAMetalLayer` loop anyway | `MTKView`'s convenience: automatic drawable/depth-buffer management, simpler boilerplate for a first prototype |
| `CALayer`-per-line (Core Animation) compositing | No source found suggesting this scales to dense, high-glyph-count, 120 Hz redraw; it's the pattern Apple's own TextKit 2 sample uses for illustrative purposes, not a documented high-perf-at-scale claim | Simpler mental model, automatic layer-level animation (implicit `CATransaction` animations), easier interop with ordinary AppKit views layered on top |
| CVDisplayLink | Reported (medium confidence, not re-verified live) as deprecated in favor of the unified `CADisplayLink`/`NSView.displayLink` | N/A — no reason to choose it for new code even if still functional |

---

## 12. Unverified claims — explicit list (do not treat as fact without a live check)

1. Exact macOS version where `CVDisplayLink` was deprecated and `CADisplayLink`/
   `NSView.displayLink(target:selector:)` became available (medium confidence: macOS 14 Sonoma
   era, not re-confirmed live this session).
2. `CADisplayLink.preferredFrameRateRange` behaving identically on macOS vs iOS, and its exact
   default/behavior when unset.
3. `CAMetalLayer.presentsWithTransaction`'s default value and precise synchronization semantics.
4. Whether macOS on Apple Silicon still exposes any subpixel/gamma font-smoothing knobs, or
   whether grayscale-only AA (no subpixel, no user-facing gamma control) is now universal —
   stated here at medium-low confidence from pre-Apple-Silicon-era general knowledge, not
   re-verified for macOS 26 specifically.
5. `CTFontCreateForString`'s exact signature/behavior for CJK/emoji cascade fallback (reference
   page returned 404 this session; function name/shape is from general knowledge only).
6. `CTFontDrawGlyphs`'s exact parameter order/discussion text (reconstructed from general
   knowledge; the live reference page did not return body content).
7. Any claim about kitty's, Alacritty's, or Warp's specific glyph-atlas/rendering implementation
   (kitty: only "uses OpenGL" confirmed; Alacritty/Warp: not fetched at all this session).
8. Whether TextKit 2/`NSTextView` can or cannot sustain 120 Hz scrolling on large files — absence
   of evidence, not evidence of absence; nobody's benchmark was found either way.
9. Any minimap implementation detail for any real editor — no source found; §8's minimap section
   is original design reasoning, not a researched fact.

## Sources

- Ghostty devlog / architecture: https://mitchellh.com/writing/ghostty-devlog-001 ,
  https://deepwiki.com/ghostty-org/ghostty/5.5.3-glyph-rendering-and-atlases ,
  https://rexbrahh.github.io/ghostty-knowledge-base/guide/26-rendering-input-fonts/font-architecture/
  (medium confidence — third-party summaries/wiki, not Ghostty's own docs site, but consistent
  with author's own public statements quoted in search results)
- Zed engineering blog (primary, author-written): https://zed.dev/blog/videogame (high confidence)
- Apple WWDC21 "Meet TextKit 2" session page: https://developer.apple.com/videos/play/wwdc2021/10061/
  (high confidence — transcript/description content successfully fetched)
- Apple WWDC22 "What's new in TextKit and text views": https://developer.apple.com/videos/play/wwdc2022/10090/
  (high confidence — transcript/description content successfully fetched)
- Apple WWDC25 "Discover Metal 4" session (session 205, URL guessed and fetched successfully):
  https://developer.apple.com/videos/play/wwdc2025/205/ (medium-high confidence)
- Apple reference pages attempted but returned only page titles, not body content (cite for
  completeness, content NOT verified): https://developer.apple.com/documentation/appkit/nsview/displaylink(target:selector:) ,
  https://developer.apple.com/documentation/quartzcore/cadisplaylink ,
  https://developer.apple.com/documentation/coretext/ctfontdrawglyphs(_:_:_:_:_:) ,
  https://developer.apple.com/documentation/quartzcore/cametallayer/presentswithtransaction
- kitty overview docs: https://sw.kovidgoyal.net/kitty/overview/ (low information yield)
