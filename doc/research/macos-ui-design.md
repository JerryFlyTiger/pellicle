# macOS 26 native look and app shell for swiftemacs

Topic key: macos-ui-design. Planning only — no code written to swiftemacs. Web research budget:
session-wide WebSearch was already exhausted before this agent ran (0 usable searches); all
findings below come from WebFetch against primary-source URLs (Apple Developer docs / WWDC
session transcripts / project docs) plus this agent's trained knowledge, with confidence marked
per claim. Several Apple Developer Documentation *reference* pages (API stub pages) render as
JS-only shells to WebFetch and returned no body text — those claims are marked medium/low and
should be re-verified by opening the page in a real browser before implementation. WWDC session
*video* transcript pages and prose "Technology Overview" pages *did* return full text.

---

## 1. Liquid Glass on macOS 26 — what it is, materials, APIs

**Source with full transcript retrieved (high confidence):** WWDC 2025 "Meet Liquid Glass"
(https://developer.apple.com/videos/play/wwdc2025/219/) and "Build a UIKit app with the new
design" (https://developer.apple.com/videos/play/wwdc2025/284/, UIKit-specific but the
material model is cross-platform).

- Liquid Glass is Apple's cross-platform (iOS/iPadOS/macOS/tvOS/visionOS/watchOS) "digital
  meta-material" introduced 2025, unifying the design language. It is not a texture but a
  dynamic optical model ("Lensing") that bends/refracts the content beneath it in real time,
  reacts to touch/pointer and device motion, and adapts tint/contrast to whatever content sits
  underneath. High confidence.
- Two variants: **Regular** (adaptive, flips light/dark per background, used almost
  everywhere) and **Clear** (permanently more transparent, no adaptive flip, requires an
  explicit dimming layer, and Apple restricts it to: over media-rich content, where a dimming
  layer won't hurt that content, and where the content above is bold/bright). For a code
  editor, **Regular is the only variant that makes sense** — text buffers are not "media-rich
  content" in Apple's sense, and Clear would fight code legibility. High confidence.
- Explicit dos/don'ts from Apple (high confidence, quoted from the transcript):
  - Reserve Liquid Glass for the **navigation layer that floats above content** — toolbars,
    tab bars, sidebars, popovers — never for the content layer itself (e.g. a table/text view).
  - **Never stack glass on glass** ("glass-on-glass"); don't let two Liquid Glass elements
    overlap/intersect in a steady state.
  - Tint sparingly, only on primary actions/elements — not applied broadly.
  - Larger elements (sidebars, menus) get thicker material and deeper shadow/lensing than
    small elements (a segmented control), and large elements do **not** flip light/dark the
    way small chrome does (a flip on a whole sidebar would be visually distracting).
  - Accessibility is automatic and required to be honored: **Reduce Transparency** makes glass
    frostier/more opaque, **Increase Contrast** turns glass into near-solid black/white with
    hard borders, **Reduce Motion** removes the elastic/lensing animation. An app using
    `NSGlassEffectView`/`glassEffect()` gets these for free from the system; a hand-rolled
    "glass-look" view (custom Metal/Core Image blur) would have to reimplement all three itself
    — a strong argument for using Apple's real glass APIs rather than imitating the look.
- Confirmed present on this machine's SDK (from spikes/RESULTS.md section 2, high confidence,
  locally verified by typechecking): `NSGlassEffectView` exists in AppKit on macOS 26 and
  typechecks under Swift 6.3 targeting `arm64-apple-macosx26.0`.
- **Not independently confirmed by this agent** (medium confidence, general/training
  knowledge, Apple reference pages for these returned no body text to WebFetch):
  `NSGlassEffectView` properties are understood to include a `contentView`, `cornerRadius`,
  and `tintColor`, and there is a companion `NSGlassEffectContainerView` for merging adjacent
  glass shapes (mirroring SwiftUI's `GlassEffectContainer`) so multiple glass controls in one
  toolbar visually merge instead of each casting its own separate highlight. SwiftUI exposes
  the same system as the `.glassEffect(_:in:)` view modifier and `GlassEffectContainer`. UIKit
  (confirmed by transcript, high confidence) exposes `UIGlassEffect`, `UIVisualEffectView`,
  `UIGlassContainerEffect`, and `UIButtonConfiguration.glass()` / `.prominentGlass()`; AppKit's
  naming almost certainly parallels this (`NSGlassEffectView` plays the role of
  `UIVisualEffectView`+`UIGlassEffect`) but the exact AppKit method/property names should be
  verified in Xcode's Quick Help or the local SDK headers before writing code — **do not trust
  the property names above without opening the header**.
- **NSVisualEffectView** (the pre-26 vibrancy/blur view) still exists and still works — Apple
  did not announce its removal — but it renders the old-style frosted-blur material, not
  Liquid Glass's lensing/adaptive behavior. Medium confidence: for a macOS-26-only app (per
  the brief's target of macOS 26.6.2 exclusively), prefer `NSGlassEffectView` throughout and
  avoid mixing the two materials in the same window, since Apple's HIG explicitly warns
  against inconsistent material mixing (this specific warning was stated for glass-on-glass;
  by extension, mixing an old-style vibrancy panel next to a new glass toolbar in the same
  window would look like two different app generations glued together — this generalization is
  this agent's inference, not a quoted Apple rule, so treat it as medium confidence).

## 2. App shell architecture: AppKit vs SwiftUI vs hybrid

**Recommendation: hybrid, AppKit-hosted.** Build the window/shell/chrome in AppKit
(`NSWindow`, `NSToolbar`, `NSSplitViewController`, `NSMenu`, `NSDocument`) and host SwiftUI only
for isolated, state-light chrome (settings/preferences window, small popovers, about panel,
font/theme pickers) via `NSHostingController`/`NSHostingView`. The core text-editing surface
should be a **custom NSView subclass with its own Metal/Core Animation-backed drawing**, not
`NSTextView` and not SwiftUI `Text`/`TextEditor` — this is the load-bearing decision for the
"extreme performance" requirement in the brief.

Why, with evidence:

- **Ghostty precedent (verified, high confidence — fetched https://ghostty.org/docs/about):**
  Ghostty's macOS app is "Swift with AppKit and SwiftUI," built on top of `libghostty`, a
  Zig-based cross-platform core library that is UI-agnostic. The GUI layer "leverages native
  components through AppKit and SwiftUI" including native features like Quick Look and force
  touch. This is close to the swiftemacs situation: a performance-critical core (terminal
  emulation for Ghostty, buffer+Elisp+rendering for swiftemacs) driving a native shell, with
  AppKit for the parts that need precise control (window chrome, menu, tight keyboard handling)
  and SwiftUI for auxiliary panels. Ghostty's core is *not* SwiftUI/AppKit at all — those only
  own the shell.
- **Zed counter-example (verified, high confidence — fetched
  https://zed.dev/blog/videogame):** Zed deliberately does **not** use AppKit or SwiftUI even
  for chrome. It built a fully custom GPU-rendering framework (GPUI) with per-primitive Metal
  shaders (rectangles, shadows, text, icons, images) specifically because existing UI
  frameworks (including a prior attempt with Pathfinder) could not hit their performance target
  of a sustained 120 FPS. This is the "go it entirely alone" end of the spectrum. For
  swiftemacs this is **not recommended**: it would mean reimplementing every native affordance
  (Liquid Glass, VoiceOver, Services menu, window tabs, Mission Control, Stage Manager
  integration, Continuity Camera drag-and-drop, etc.) that AppKit gives for free, and the brief
  explicitly says "lean heavily on Apple's own frameworks." Zed's approach is a defensible
  choice for a company targeting three OSes at once from one Rust codebase; swiftemacs is
  macOS-only and Swift-native, which removes Zed's central justification.
- **Why not pure SwiftUI for the shell:** SwiftUI's `NSHostingView`/`NSViewRepresentable`
  bridge has real, documented interop cost — every SwiftUI subtree hosted inside AppKit (or
  vice versa) pays a layout/state-sync bridge, and fine-grained keyboard event routing (needed
  for Emacs-style chord prefixes intercepting nearly every keystroke, see §6) is most directly
  controlled by overriding `NSResponder.keyDown(with:)`/`performKeyEquivalent(with:)` on an
  `NSView`, which is AppKit's native vocabulary, not SwiftUI's. `NSDocument` (multi-window,
  multi-file document architecture, versions/autosave-in-place, iCloud document integration)
  is AppKit-only; SwiftUI's `DocumentGroup` is a thin SwiftUI-idiomatic wrapper better suited to
  simple single-editor-per-window apps than to an Emacs-style app that treats buffers, windows,
  and frames as separate, freely recombinable concepts. Medium-high confidence (architectural
  reasoning; not a single Apple doc states "don't use SwiftUI for Emacs-style editors").
- **Why not pure AppKit either:** things like a Settings/Preferences window with live-updating
  form controls, a font/theme picker with grid previews, or a "Command Palette" fuzzy-list are
  meaningfully faster to build correctly (list diffing, animations, accessibility labels) in
  SwiftUI, and Apple's own newer System Settings-style panels are SwiftUI. Hosting these as
  `NSHostingController` panels inside AppKit-managed windows/sheets is standard and low-risk
  because they are shallow view trees with infrequent updates — the interop tax is negligible
  there, unlike hosting the 60fps text canvas.
- **The editor canvas itself:** neither `NSTextView` (TextKit 1/2) nor SwiftUI `TextEditor`
  should be the rendering surface. `NSTextLayoutManager` (TextKit 2, confirmed present in the
  SDK per spikes/RESULTS.md §2, high confidence) is worth using for **text layout services**
  (line breaking, glyph shaping, bidi, ligatures — genuinely hard problems Apple has already
  solved), but final pixel presentation should go through a custom `CALayer`-backed or
  Metal-backed `NSView` so the redisplay loop (partial-buffer invalidation, smooth scrolling,
  minimap, GPU-accelerated cursor/selection painting) is fully under swiftemacs's control —
  this is the single biggest gap Reticle's README lists as a limitation ("fixed character-grid
  GUI ... no smooth scrolling, no minimap") and the fix is architectural, not incremental.
  Medium-high confidence recommendation (TextKit 2's existence and API shape is high
  confidence/locally verified; the recommendation to *drive rendering through Metal rather than
  through NSTextLayoutManager's own view* is this agent's synthesis based on the Zed/Ghostty
  precedents above, not a quoted Apple statement).

## 3. Chrome survey: Xcode 26, Zed, Ghostty, Warp, Nova, Sublime, VS Code, JetBrains Fleet

Confidence note: only Ghostty and Zed were independently re-verified this session (§2). The
rest reflect this agent's trained knowledge (as of the January 2026 cutoff) and should be
treated as **medium confidence** — worth a quick visual re-check against each app's current
build before locking the visual language, since Liquid Glass shipped mid-2025 and several of
these apps may have re-skinned their chrome since training data was collected.

| App | Shell tech (medium confidence unless noted) | Notable chrome pattern relevant to swiftemacs |
|---|---|---|
| **Xcode 26** | AppKit, now visibly re-skinned for Liquid Glass (high confidence — Xcode 26.6 is installed on this machine per CONTEXT.md, so a live look is possible without web research) | Navigator/editor/inspector 3-pane `NSSplitViewController`; floating glass toolbar with segmented jump-bar; minimap on the editor's right edge; bottom debug/console drawer that overlays rather than reflows |
| **Zed** | Custom GPUI (verified, no AppKit/SwiftUI at all) | Command palette (`Cmd-Shift-P`) as a centered modal overlay; status line at bottom with git branch/diagnostics; multi-pane splits with lightweight tab strip per pane |
| **Ghostty** | AppKit+SwiftUI shell over Zig core (verified) | Native macOS window, "Quick Terminal" as a borderless overlay panel (Spotlight-like), background-image/opacity blending done in its own Metal renderer, not `NSVisualEffectView`, because terminal transparency needs to composite over arbitrary backgrounds, not the desktop's own vibrancy stack |
| **Warp** | Rust core + native shell (Warp is closed-source; exact rendering stack not independently re-verified this session) | Blocks-based command output, AI command palette overlay, GPU-accelerated text rendering |
| **Nova (Panic)** | AppKit-native, out-of-process extensions | Clean single-pane-by-default editor, sidebar with symbol/file navigator, extension marketplace built into the app, minimal chrome philosophy (Panic markets it as deliberately "less overwhelming" than VS Code) |
| **Sublime Text** | Custom cross-platform (own GPU-accelerated rendering, not native AppKit widgets for the editor surface) | Minimap, command palette (`Cmd-Shift-P`), goto-anything, distraction-free mode, extremely lightweight/fast chrome |
| **VS Code** | Electron/Chromium, not native | Command palette, activity bar + sidebar + panel + status bar 4-region layout familiar to most developers; extension host runs out-of-process for stability |
| **JetBrains Fleet** | Custom cross-platform UI toolkit (Skija/Skiko-based, not AppKit) | "Smart mode" progressive UI (chrome appears only as needed), distributed/remote workspaces, minimal always-on chrome |

Cross-app pattern relevant to the brief's iTerm2 requirement (item 6): **iTerm2's transparent
window with a faded/scaled background image** is implemented as the app drawing its own
background (image + alpha blend) behind a transparent `NSWindow`
(`window.isOpaque = false`, `backgroundColor = .clear`), not via `NSVisualEffectView`/glass —
vibrancy materials blur/sample the *desktop and windows behind* the app, whereas iTerm2's
effect is the app's *own* image content faded and scaled, unrelated to what is behind the
window. **Recommendation for swiftemacs (medium confidence):** implement the "terminal-like
background image" feature the same way — a custom-drawn background layer under the text
canvas, independent of Liquid Glass chrome, which stays reserved for the surrounding toolbar/
sidebar per Apple's don't-use-glass-on-content rule from §1.

## 4. Concrete chrome-by-chrome recommendation: native control vs editor-drawn

| Chrome element | Recommendation | Rationale / confidence |
|---|---|---|
| Window, titlebar, traffic lights, full-screen, window tabs (`NSWindow` native tabbing) | **Native** — `NSWindow` + `NSWindowController`, enable `tabbingMode` | Free Stage Manager/Mission Control/window-tabs integration; high confidence this is table stakes |
| Toolbar | **Native** — `NSToolbar` with `NSGlassEffectView`-based items where custom | Gets Liquid Glass adaptivity, Reduce Transparency/Contrast/Motion for free (§1); medium-high confidence |
| Sidebar (file tree / buffer list) | **Native** — `NSOutlineView` inside `NSSplitViewItem(sidebar:)` | Standard sidebar semantics (selection, drag-drop, source-list style) come free; medium confidence on exact API name, verify in headers |
| Main editor text canvas | **Editor-drawn** — custom `NSView`/Metal layer, TextKit 2 for layout only | Perf/smooth-scroll/minimap requirement in the brief; this is the crux decision, medium-high confidence (see §2) |
| Tab bar (open buffers) | **Editor-drawn**, styled to match native tab bars | Emacs "buffers" don't map 1:1 onto `NSWindow` native tabs (which are per-window, not per-buffer); a custom lightweight tab strip above the canvas mimicking Big Sur+ tab-bar visuals gives control needed for unsaved-dot indicators, mode icons, split-adjacent tabs; medium confidence |
| Command palette (M-x equivalent) | **Editor-drawn** overlay, visually matching Liquid Glass popover style via `NSGlassEffectView` panel | No single native control fits fuzzy-match command lists with live keyboard narrowing; both Zed and Xcode implement this as a custom floating panel, not a native menu; medium confidence |
| Popovers (autocomplete, quick docs, LSP hover) | **Native** `NSPopover` | Handles positioning/dismissal/VoiceOver semantics automatically; high confidence this is the standard tool for the job |
| Status/mode line | **Editor-drawn** thin `NSView` bar | Needs Emacs-specific density (mode name, line/col, encoding, VC branch, LSP status) that no native control models; low-risk custom view, medium confidence |
| Settings/Preferences | **SwiftUI**, hosted via `NSHostingController` in a standard Settings window | Fast to build correctly with accessibility/animations; §2 |
| Font/theme picker | **SwiftUI** grid/list inside a sheet or popover | Live preview + selection list is SwiftUI's strength; medium confidence |
| Menu bar | **Native** `NSMenu`, standard `NSApplication` main menu | Non-negotiable on macOS; also the fallback discoverability path for Emacs chords, see §6 |
| Dark/Light/Auto theme switching | **Native** — follow `NSApplication.effectiveAppearance` / `NSAppearance`, let the system's `Auto` (Appearance = System) setting drive it | Standard API, high confidence; app-specific "theme" (syntax colors) is a separate, editor-owned concept layered on top |

## 5. Accessibility: VoiceOver / NSAccessibility for a custom text view

**Medium confidence** (Apple's `NSAccessibility` reference page returned no body text to
WebFetch this session; the following reflects this agent's trained knowledge of the protocol
family, cross-checked against the fact that these protocol/role names are real and stable
across many macOS releases):

- A fully custom text-drawing `NSView` (per §2's recommendation) must implement accessibility
  itself rather than inheriting `NSTextView`'s built-in support — this is the accessibility
  cost of choosing custom rendering, and it is real, non-optional work, not a nice-to-have.
- Relevant protocol surface: `NSAccessibilityElement` (or overriding the `NSAccessibility`
  informal protocol methods directly on the view), with role `.textArea`; for editable text,
  conform to text-specific accessibility protocols exposing `accessibilityValue`,
  `accessibilitySelectedText`, `accessibilitySelectedTextRange`, `accessibilityVisibleCharacterRange`,
  `accessibilityNumberOfCharacters`, and character/line/word-boundary querying
  (`accessibilityRangeForLine(_:)`, `accessibilityLineForIndex(_:)`) so VoiceOver's
  line-by-line and word-by-word navigation works.
- Post `NSAccessibility.Notification.valueChanged` / `.selectedTextChanged` notifications via
  `NSAccessibility.post(element:notification:)` whenever the buffer or selection changes so
  VoiceOver announces edits and cursor movement — without this, VoiceOver will read stale
  content after every edit.
- **Recommendation:** budget this as a first-class milestone, not a follow-up. Reticle's own
  known-limitations list (from CONTEXT.md) doesn't mention accessibility, which likely means it
  was never done for the character-grid GUI; swiftemacs should not repeat that gap given the
  brief's "solve every known pain point" and "extreme quality" framing.
- **Unverified:** the exact current (macOS 26) names of the accessibility protocols
  (`NSAccessibilityStaticText` vs a unified informal-protocol approach) should be confirmed by
  reading the live `NSAccessibility.h`/Swift overlay headers in the installed Xcode 26.6, which
  this agent did not have file access to. Flag for a follow-up spike with actual header access
  rather than treating the names above as final.

## 6. Keyboard-first UX: Emacs chords vs Command shortcuts vs the menu bar

**Confidence: medium** (Apple's Keyboards HIG page returned no body text to WebFetch; the
Cmd/Shift/Option/Control modifier conventions below are extremely well-established, stable
Apple platform facts from this agent's training, not from a freshly fetched source this
session).

- macOS reserves `Cmd`+letter as the primary application-shortcut modifier; `Cmd-Option`,
  `Cmd-Shift`, and `Cmd-Control` combinations are the normal way apps add secondary shortcuts.
  Plain `Control`+letter and multi-key chord sequences (like Emacs's `C-x C-s`) are **not**
  claimed by the system for anything that would conflict at the OS level (system-wide chords
  are rare and mostly `Cmd`-based, e.g. `Cmd-Space` for Spotlight), so an Emacs-style
  `Control`-prefixed chord scheme can coexist with standard macOS `Cmd`-shortcuts without
  clashing, **provided** the app is careful about a few specific system collisions:
  `Ctrl-F2`/`Ctrl-F3` (menu bar/Dock focus), `Ctrl-Space` (input source switch, commonly
  reassigned by users), and various `Ctrl-Cmd-*` window-management shortcuts from third-party
  tools (Rectangle, Magnet) or system window tiling. These should be treated as soft
  conflicts — detectable and remappable, not hard-blocked.
- **Recommended architecture (medium-high confidence, architectural synthesis rather than a
  quoted Apple rule):** implement Emacs chords (`C-x C-s`, prefix-key sequences,
  `which-key`-style hint popups) entirely inside the custom editor `NSView`'s
  `keyDown(with:)`/`interpretKeyEvents(_:)` handling for events that occur while the editor has
  first responder status, so they never reach `NSApplication`'s `performKeyEquivalent` /
  main-menu key-equivalent dispatch. Reserve real `NSMenu` key equivalents (with real `Cmd-`
  shortcuts shown in the menu bar) for the subset of commands non-Emacs users expect to find
  there (`Cmd-S` Save, `Cmd-Z` Undo, `Cmd-,` Preferences, `Cmd-Q` Quit) — this gives new users a
  standard-macOS on-ramp via the menu bar while power users live in chords, mirroring how Doom
  Emacs and Spacemacs each provide a discoverable leader-key popup (`which-key`) *and* keep
  standard bindings reachable. This directly answers the brief's ask about coexistence.
- A first-responder-scoped key handler also naturally solves the "Emacs binds nearly every key"
  problem without permanently stealing keys application-wide: chords are only active while the
  editor view is key, so other views (a SwiftUI settings sheet, a native `NSTextField` in a
  dialog) keep standard macOS text-field behavior (`Cmd-A` select all, arrow-key navigation)
  unless the user explicitly wants Emacs-style navigation everywhere (a well-known Emacs-user
  complaint about editors that hijack keys globally, sometimes solved by opt-in "Emacs key
  bindings" system-wide text field support macOS itself partially offers via
  `~/Library/KeyBindings/DefaultKeyBinding.dict`, which is a real, low-confidence-recalled
  Apple mechanism this agent did not re-verify this session but is worth spiking).

## 7. App icon: `.icon` / Icon Composer (inherited from Reticle's M98)

**High confidence — grounded in `/Users/jerrychen/My_Projects/reticle/PLAN.md` M98 (completed
2026-09-03), read directly, not web research.** Key transferable findings for swiftemacs:

- macOS 26 no longer renders a bundle's `.icns` as drawn: the system plates it inside a glass
  container automatically (confirmed true even for full-bleed/square source art — margin is
  not the cause). Only the new **`.icon` package format** (edited with **Icon Composer**)
  escapes the auto-plating: it takes a flat glyph SVG plus a gradient definition and lets the
  OS render the glass itself, producing a result Apple actually designed for.
- A bundle should ship **both**: `.icon`/`Assets.car` for macOS 26 (`CFBundleIconName` +
  `Assets.car` takes priority when present — verified by Reticle via pixel-diff, mean diff
  0.00 vs new-format-only) and a legacy `.icns` for pre-26 systems as fallback (a legacy-only
  bundle differed by 27.27 mean pixel value from the correct macOS-26 render — i.e. visibly
  wrong without the new format).
- **Trap to avoid, already found once:** Xcode's `actool` also auto-generates its own
  `<AppName>.icns` from the flat glyph when building the asset catalog. That auto-generated
  `.icns` is a worse (flat, un-lit) render than a hand-crafted one and will silently shadow a
  better hand-made `.icns` on pre-26 systems if both are copied into the bundle. Only take
  `Assets.car` from the build output; keep a hand-authored `.icns` as the checked-in pre-26
  fallback, generated by the project's own icon-drawing pipeline (Reticle used a Python
  centerline-based SVG generator; swiftemacs should design its own mark but can reuse this
  build-and-ship pattern).
- Recommend committing the `.icon` **source** (gradient stops, flat glyph SVG) to the repo, not
  the compiled `Assets.car` (a build artifact), and deriving both representations' colors from
  one shared set of constants so the two icon representations cannot visually drift — this was
  Reticle's approach and worked.
- **Not re-verified this session (medium confidence carried over from Reticle's own
  documented findings, not independently re-confirmed via WWDC this time):** the general
  claim that Icon Composer/`​.icon` was introduced alongside Liquid Glass at WWDC 2025 is
  consistent with public knowledge and with Reticle's dated finding (2026-09-03, on this same
  machine, same macOS 26 build) — treat as high confidence since it's a local, reproducible,
  already-tested fact rather than a web claim.

## 8. Distribution: Sparkle vs App Store, notarization, hardened runtime

**Sparkle (medium-high confidence — fetched https://sparkle-project.org/documentation/,
got real body text):**
- Sparkle is a self-hosted auto-update framework: an EdDSA (ed25519) keypair signs update
  archives/delta-updates/installer packages; the public key lives in `Info.plist`, the private
  key in the developer's keychain (via a `generate_keys` tool). Updates are announced through
  an "appcast" — an RSS-like XML feed, either hand-written or produced by a
  `generate_appcast` tool.
- Requires HTTPS-served updates and Apple notarization of the shipped app regardless of
  distributing outside the App Store — Sparkle's own docs stress this because it is "installing
  executable code" on users' machines and treats that as a serious trust boundary.
- Sandboxed apps need Sparkle's separate sandboxing guide/XPC services setup; non-sandboxed
  apps can drop the XPC services to shrink the bundle.
- Sparkle is incompatible with Mac App Store distribution (Apple controls updates there); it's
  the standard choice for **Developer-ID-signed, directly-distributed** macOS apps — which fits
  swiftemacs given it needs broad filesystem/shell access (M-! / shell-command / running an
  actual terminal per the brief) that is friction-heavy or impossible under the App Store
  sandbox.

**Notarization / hardened runtime (medium confidence — WebFetch on Apple's notarization
reference page did not return body text; the following is this agent's trained, stable
knowledge of a long-unchanged Apple process, cross-checked against Sparkle's own docs above
which independently corroborate "notarize via Developer ID"):**
- Sign with a **Developer ID Application** certificate, with **Hardened Runtime** enabled
  (`codesign --options runtime`), then submit via `xcrun notarytool submit ... --wait`, then
  `xcrun stapler staple` the approved ticket onto the `.app`/`.dmg`/`.pkg`.
- Hardened Runtime entitlements likely to matter for swiftemacs specifically, because it embeds
  a Lisp interpreter (possibly JIT-compiling, per the brief's "JIT" ask) and spawns a real
  shell: `com.apple.security.cs.allow-jit` and/or
  `com.apple.security.cs.allow-unsigned-executable-memory` if any JIT path writes+executes
  memory pages directly, and standard entitlements for spawning subprocesses (running a shell
  under Hardened Runtime is generally fine — Terminal.app and iTerm2 both ship notarized with
  Hardened Runtime — but a custom Elisp JIT emitting native code at runtime should be treated as
  a known notarization risk area worth a dedicated spike; **unverified** whether
  `allow-jit`/`allow-unsigned-executable-memory` alone suffices or whether additional
  entitlements are needed for a *custom* JIT (as opposed to `WKWebView`'s JIT, which is the
  common documented case) — flag for its own investigation before committing to a JIT design).
- **Recommendation:** Sparkel-based Developer-ID distribution (**must**), notarization +
  hardened runtime (**must** — required by Gatekeeper for any distribution outside the Mac App
  Store on current macOS), App Store as a **could** (secondary channel, likely blocked in
  practice by the sandbox vs. shell/subprocess requirement — treat as unlikely, not pursued
  initially).

## 9. Recommendations (must / should / could)

**Must**
- Hybrid shell: AppKit for window/toolbar/menu/split-view/document architecture; SwiftUI only
  for Settings/preferences and other shallow, infrequently-updated panels via
  `NSHostingController`.
- Custom-drawn, GPU-accelerated text canvas (`NSView` + Metal/CALayer), using TextKit 2
  (`NSTextLayoutManager`) for layout computation only, not for final presentation — directly
  fixes Reticle's documented "no smooth scrolling / no minimap / fixed character grid"
  limitations.
- `NSGlassEffectView`-based chrome (toolbar, sidebar, popovers, command palette) for the
  Liquid Glass look, reserved strictly for the navigation layer, never over the text content
  layer (Apple's explicit rule, §1).
- First-responder-scoped key handling so Emacs chords live inside the editor view's
  `keyDown`/`interpretKeyEvents` path and never fight `NSMenu` key-equivalent dispatch;
  standard `Cmd-`-shortcut menu items kept for the common commands new users expect.
- Ship both `.icon`(Icon Composer)/`Assets.car` and a hand-authored `.icns` fallback, following
  Reticle M98's exact pattern (commit the `.icon` source, not `Assets.car`; never let `actool`'s
  auto-generated `.icns` shadow the hand-authored one).
- Sparkle for updates, Developer-ID signing + Hardened Runtime + notarization + stapling for
  distribution outside the App Store.
- Full custom `NSAccessibility` implementation for the text canvas from the start (not
  deferred) — accessibility is the direct cost of choosing a custom-drawn canvas over
  `NSTextView`, and skipping it repeats a plausible Reticle-class gap the brief asks to avoid.

**Should**
- Use `NSPopover` for autocomplete/hover-doc/quick-info rather than a hand-rolled floating
  panel — native positioning/dismissal/VoiceOver semantics come free.
- Follow `NSApplication.effectiveAppearance`/system Appearance for Dark/Light/Auto rather than
  building a separate app-level light/dark toggle; keep syntax-highlighting "theme" as a
  logically separate, editor-owned concept layered on top of system appearance.
- Investigate `~/Library/KeyBindings/DefaultKeyBinding.dict`-style system text-field Emacs
  bindings as a reference/interop point, but do not depend on it for the main editor (it is a
  system mechanism for standard `NSTextView`/`NSTextField` fields, not something a
  custom-drawn canvas participates in automatically).

**Could**
- Explore Mac App Store as a secondary, sandboxed-lite distribution channel later, if a
  reduced-capability build (no arbitrary shell execution) is ever wanted for a wider, lower-
  trust audience — not a near-term priority given the brief's iTerm2-equivalence requirement.
- Adopt `NSGlassEffectContainerView`/`GlassEffectContainer`-style merging for toolbar item
  groups once the exact AppKit API is confirmed from local headers, to get Apple's visual
  "adjacent glass shapes merge into one" polish rather than each toolbar control looking like
  a separate glass chip.

## 10. Unverified claims (do not treat as fact without re-checking)

- Exact AppKit property/method names on `NSGlassEffectView` (`contentView`, `cornerRadius`,
  `tintColor`) and the exact name/shape of `NSGlassEffectContainerView` — Apple's reference
  page did not return body text to this agent; verify against the local Xcode 26.6 SDK headers
  or Quick Help directly (fast, zero web-research cost, and authoritative).
- Exact current `NSAccessibility` protocol/role names for a custom editable-text view
  (`NSAccessibilityStaticText` vs the modern informal-protocol-only approach) — same
  reference-page-body limitation; verify against local headers.
- Whether `com.apple.security.cs.allow-jit` / `allow-unsigned-executable-memory` alone is
  sufficient Hardened Runtime entitlement coverage for a *custom* Elisp JIT (as distinct from
  `WKWebView`'s JIT, the commonly-documented case) — flagged in §8 as needing its own spike.
  Apple's notarization reference page also did not return body text this session.
  Apple's Keyboards HIG page did not return body text this session; the modifier-key
  conventions cited in §6 are stable, well-known platform facts but the specific
  system-reserved `Ctrl-`-combinations list should be re-checked against current macOS 26
  System Settings > Keyboard > Shortcuts before finalizing which chords are safe.
- The current (as of 2026) chrome/rendering-stack claims for Warp, Nova, Sublime Text, VS
  Code, and JetBrains Fleet in §3's table reflect this agent's training-time knowledge and were
  **not** re-fetched this session (WebSearch was unavailable and time/budget did not allow
  fetching each project's site individually) — worth a quick visual spot-check against each
  app's current UI before using them as design references, since Liquid Glass shipped mid-2025
  and any of these may have already re-skinned.
