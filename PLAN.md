# pellicle Development Plan

An Emacs-style editor for macOS, written in Swift on Apple's frameworks, with a built-in
Emacs Lisp engine, designed from the ground up to remove GNU Emacs's structural pain
points. It is the successor to Reticle (`~/My_Projects/reticle`, Rust, 110 milestones):
Reticle proved the Verilog feature set and the process; pellicle replaces the parts of
Reticle that its own README lists as limitations (fixed character-grid GUI, synchronous
remote I/O, non-rebindable minibuffer, `Rc` cycle leaks, no runtime grammars, no headless
rendering) and adds the things the owner asked for that Reticle could not host (a native
macOS shell, a real terminal, GPU rendering, a plugin ecosystem).

**Positioning (owner, 2026-09-05):** pellicle is the macOS, Swift rewrite of Reticle and
of Emacs, but it must not be Reticle with a new coat: where Reticle is a Verilog editor,
pellicle is positioned as a **multi-language editor with complete org-mode support**.
Verilog/SystemVerilog stays the first language and the proving ground, the other target
languages are first-class rather than afterthoughts, and org-mode is built to GNU org's full
feature level (agenda, capture, refile, clocking, babel, export, backlinks), not as a thin
outliner. Speed of delivery matters more than method: any technique that works is welcome.

This file is the design record. The working rules live in `CLAUDE.md`, which is loaded in
every session; this file is not. Look up the section you need rather than reading it whole.

Planning date: 2026-09-05. Research corpus: 16 research reports (`doc/research/`) and five
feasibility spikes run on the owner's machine (`dev/spikes/`, numbers in its `RESULTS.md`);
their conclusions are folded in below with confidence noted where a claim was not verified
against a primary source.

---

## 1. The brief

The owner's wish list, restated as requirements (priority order is the owner's):

| # | Requirement | Priority |
|---|---|---|
| R1 | Killer coding features, **Verilog / SystemVerilog first**; Swift, Python, Perl, Tcl/Tk, C/C++ supported but second | 1 |
| R2 | **org-mode, complete**: file-format compatible and at GNU org's feature level, including its full GTD workflow (agenda, capture, refile, archive, clocking) | 2 |
| R3 | Extreme visual beauty, extreme performance, low power, long-session stability (never slower, hotter or crashier over time) | 3 |
| R4 | Plugin ecosystem like GNU Emacs in breadth, modelled on how VS Code / JetBrains isolate extensions so they cannot hurt performance | hard constraint |
| R5 | Every expert technique for speed and energy: GPU rendering, JIT-class engine design | hard constraint |
| R6 | **No CLI/TUI.** The app is itself an iTerm2-class terminal, and also runs shell commands the Emacs way (`M-!`, `shell-command`, `compile`) | hard constraint |
| R7 | The killer features of world-class Emacs setups (Doom, Purcell, Prot, Karthink) | 1-3 by feature |
| R8 | Written in Swift, macOS only, leaning on Apple frameworks; study VS Code, JetBrains, Zed, Doom, Purcell and Reticle | hard constraint |

Two consequences the owner should read before anything else:

1. **GNU Emacs packages are a porting target, not a runtime target.** Every one of the five
   root causes of Emacs's pain (section 3) is fixable only if the Elisp contract is defined
   narrowly. Reticle took the same stance and it held for 110 milestones. pellicle runs
   *its own* Elisp dialect: lexical by default, one dedicated interpreter thread, async
   primitives, rich key events. The **config idioms** of Doom/Purcell-style setups run
   (`use-package` forms, hooks, keymaps, `setq`/`setopt`, custom variables, mode hooks); a
   literal Doom config does not, because it drives a package manager and hundreds of
   third-party symbols. `magit.el` does not run, and does not need to, because git is
   native.
2. **The first visible Verilog feature is far away.** A Verilog editor needs a buffer, a
   renderer, a command loop, an Elisp engine and an LSP client before `AUTOINST` can exist.
   The milestone plan (section 8) is ordered so that the foundation stages are each usable
   and testable on real RTL, and Verilog features start at the earliest point where they can
   be shown in a screenshot, not at the end.

---

## 2. Verified facts (this machine, 2026-09-05)

Environment: macOS 26.6.2 (Darwin 25.6), Apple M4, 24 GB, a 4K panel driven at 1920x1080
(scaled) **at 60 Hz, no ProMotion**, Metal 4; Xcode 26.6,
Swift 6.3.3, SDK 26.5, `swift format` 6.3.0, `swift test` runs Swift Testing; GNU Emacs
30.2 at `/opt/homebrew/bin/emacs` (the parity oracle); verible-verilog-ls, slang-server
0.2.9, sourcekit-lsp, clangd, pyright, rust-analyzer, iverilog installed; Homebrew has
libtree-sitter 0.25, harfbuzz, libgit2 1.9, ripgrep, fd. verilator, node, tree-sitter CLI
absent.

Spikes (sources and full numbers in `dev/spikes/`):

| Spike | Result | Consequence |
|---|---|---|
| MAP_JIT in Swift | Works ad-hoc signed; `mmap` fails with EINVAL under hardened runtime without `com.apple.security.cs.allow-jit`; works with it | A JIT is feasible; the shipped app must carry the entitlement; `sys_icache_invalidate` needs a C shim or `@_silgen_name` |
| macOS 26 SDK typecheck | `InlineArray`, `Span`, `RawSpan`, `~Copyable`, `NSView.displayLink`, `MTL4CommandQueue`, `CAMetalLayer.presentsWithTransaction`, `NSTextLayoutManager`, `SystemLanguageModel`, `NSGlassEffectView`, ExtensionKit/ExtensionFoundation all compile | Every API the design names exists in this SDK |
| Lisp value representation (1M-cons list, 20 traversals, 20M-step loop) | indirect enum ~0.55 s (27x); enum with final-class cons ~0.10 s (5x); tagged UInt64 + arena ~0.02 s (1x). `-Ounchecked` changes nothing | Tagged word + engine-owned heap is the target representation; indirect enums are ruled out |
| Recursive release | Both ARC representations segfault (exit 139) when a 1M-node list dies, even with an 8 MB stack | Any ARC-linked structure needs iterative teardown; another reason for the arena |
| Mini tree-walking Elisp evaluator (ARC values, flat symbol table) | Reticle's `loop-sum(20M)`: 2.4 s vs Reticle's measured Rust tree-walker 9.96 s and bytecode VM 2.55 s (Reticle `PLAN.md` M7 record) | Not like-for-like (Reticle does more per node), but Swift dispatch cost is ~10 ns/node: Swift is not intrinsically too slow for this, and a Swift VM must be judged against an absolute target, not against Reticle |

---

## 3. Design principles: what Emacs got wrong and what fixes it

The pain-point inventory (22 reported pain points, each traced to its root cause with
primary sources, and what Emacs 29-31 did about it) reduces to five decisions GNU Emacs
made in the 1980s and cannot reverse:

| Root decision in GNU Emacs | Pain it causes | pellicle decision that removes it |
|---|---|---|
| One thread owns everything: current buffer, point, narrowing, redisplay, the Lisp heap, dynamic bindings | Blocking UI, no real async, hooks and advice stall typing, TRAMP and LSP freezes, package updates freeze | **Three isolation domains**: the UI actor (main thread: input, layout, paint, AppKit), the Elisp actor (one dedicated thread with its own executor; all Elisp runs here, preemptible), and background actors (parse, index, search, LSP transport). Buffers are owned by the Elisp actor; everyone else reads immutable snapshots. `C-g` is delivered out of band as cancellation. |
| Non-generational stop-the-world GC with an 800 KB threshold | Pauses over 100 ms for 56% of surveyed users; the `gc-cons-threshold` cargo cult; startup cost; the MPS-based `igc` still not merged as of Emacs 31 | **Engine-owned heap with a precise, incremental, generational collector** written in Swift over raw arenas (ARC does not manage Lisp objects). Explicit root stack; write barrier in the object model; pause budget measured in CI. Telemetry exposed, no user knob. |
| Text-terminal display model (character grid, 38k-line `xdisp.c`, everything is text in a buffer) | Redisplay complexity, no widgets, child-frame hacks, scroll jank, long-line collapse, ligature hacks, non-native macOS behaviour | **Model → layout → paint pipeline**: rope with indices, attributed runs, Core Text shaping, Metal glyph atlas, damage-driven presentation at up to 120 Hz, paused at idle. Faces, overlays, text properties and `display`/`invisible` survive as attributes on the rope, not as iterator special cases. Native AppKit chrome around the canvas. |
| Terminal key encoding (ASCII control chars, ESC as Meta) | `C-i` is TAB, `C-m` is RET, ESC delays, `ESC ESC ESC` | **Rich key events** (physical key, modifiers, text) from `NSEvent`; `TAB` and `C-i` distinct by default with an opt-in compatibility normaliser; the terminal's escape sequences live inside the terminal subsystem only. |
| Load-everything Elisp with global mutable state and no sandbox | Slow startup, config fragility, package-manager churn, byte-compile warning noise, "every package runs with full privileges" | **Manifest-driven, lazy, capability-declaring packages**; ahead-of-time compilation at install; a post-init snapshot for fast starts; three plugin tiers with a real sandbox for the middle one (section 4.9). |

Cross-cutting rules derived from the same inventory, each of which becomes a milestone
definition-of-done somewhere in section 8:

1. **The cost on the keystroke path has a known upper bound.** Hooks run under a time
   budget with attribution and automatic quarantine (Reticle: 50 ms, three strikes, named
   in the echo area). Layout and paint never wait for Elisp.
2. **All I/O is async by construction.** Processes, files, network and remote editing return
   futures; Elisp gets `async`/`await`-style primitives; the compatibility `call-process`
   blocks only the Elisp actor, never the UI.
3. **Everything is incremental.** Parsing (tree-sitter `ts_tree_edit`), highlighting, layout,
   org structure, indexes.
4. **Observability is built in**: per-command and per-hook latency, GC pause histogram,
   advice introspection, a latency profiler that is always on and cheap.
5. **Every visual claim is settled by a screenshot, every behavioural claim by a test, every
   GNU-parity claim by running GNU Emacs 30.2**, and every LSP claim by probing the real
   server. These are Reticle's rules; each one exists because of a recorded incident.

---

## 4. Architecture

### 4.1 One-page summary of the bets

- **Shell**: AppKit for windows, toolbar, menus, split views, sidebars, popovers; SwiftUI only
  for settings and shallow panels via `NSHostingController`; Liquid Glass (`NSGlassEffectView`)
  restricted to the navigation layer, never over text (Apple's own rule).
- **Canvas**: a custom `NSView` backed by `CAMetalLayer`; Core Text for shaping and glyph
  rasterisation into a Metal atlas (with several sub-pixel phases per glyph, as Zed does);
  instanced quads per frame; `NSView.displayLink` paused whenever nothing is dirty. TextKit 2
  is a candidate layout oracle for line breaking and bidi, never the drawing path.
- **Text model**: a persistent rope (B+-tree of UTF-8 chunks with summaries for bytes, UTF-16
  units, lines, longest line) whose snapshots are O(1) and `Sendable`; Zed-style anchors
  instead of live markers; an augmented interval tree for overlays and text properties;
  display transforms (folds, inlays, wraps, blocks) as layers above the buffer.
- **Elisp engine**: tagged 64-bit values on an engine-owned heap with a precise generational
  GC; a bytecode VM with fixed-width instructions, inline-cache slots, superinstructions and a
  contiguous frame stack; builtins behind one C-ABI-shaped entry point; no JIT until an
  editor-workload benchmark shows ≥20% of time in dispatch; the design keeps a baseline ARM64
  JIT possible.
- **Command loop**: one Elisp actor thread runs commands, hooks, timers and redisplay
  requests in Emacs order; the UI actor feeds it rich key events and paints snapshots. Minibuffer
  is an ordinary buffer with an ordinary keymap hosted in a native panel.
- **Language intelligence**: tree-sitter grammars compiled in as SwiftPM C targets (SystemVerilog,
  Swift, Python, Perl, Tcl, C, C++, Elisp, Org, Bash, Markdown, JSON/YAML/TOML), upstream `.scm`
  queries; LSP transport and JSON in Swift on a background actor, protocol policy in Elisp;
  **two servers per Verilog buffer routed per method** (verible for format and style lint,
  slang for diagnostics, completion, references, rename); a persistent project index for
  symbols, modules and org headlines.
- **Extensions**: tier 1 in-process Elisp (config, commands, modes, hooks, with budgets); tier
  2 sandboxed Wasm (WasmKit from the Swift toolchain; wasmtime C API as the escape hatch when
  epoch interruption or JIT speed is needed) for language packs, themes and pure computation;
  tier 3 out-of-process via LSP/DAP/JSON-RPC and XPC for anything that needs the shell, the
  filesystem or the network. Native dynamic modules keep Reticle's versioned function-table
  ABI shape.
- **Terminal**: own VT parser (Williams state machine) in Swift; scrollback is a real buffer
  with OSC 133 markers as overlays; the alternate screen is a grid overlay; eat.el's three
  input modes (semi-char, char, buffer) reimplemented natively; SwiftTerm is the reference and
  the candidate fallback for the alt-screen widget; libghostty rejected for v1.
- **org-mode**: own incremental parser producing a persistent element tree, file-format
  compatible; a project-wide org index (headlines, tags, timestamps, IDs) in SQLite so agenda
  and refile never open files.
- **git**: native, driving the git CLI with porcelain formats (Magit's approach), with a
  section-based status buffer, hunk and line staging, and transient menus.
- **Energy and stability**: 0% idle CPU by construction; every timer coalesced; QoS-tiered
  background work; memory ceilings and soak tests in the release protocol; crash isolation per
  subprocess and per Wasm instance.
- **Distribution**: SwiftPM for everything, a script that assembles the `.app` (Info.plist,
  entitlements `allow-jit` and `disable-library-validation` (the latter because native
  modules and runtime grammar dylibs signed by other teams fail `dlopen` silently under the
  hardened runtime without it), `.icon` + `.icns` as Reticle M98 established), Developer
  ID + hardened runtime + notarization, Sparkle for updates. No App Store (an editor that spawns
  shells cannot be sandboxed).

### 4.2 Modules and dependency direction

SwiftPM package `pellicle`, Swift 6 language mode. Dependencies point downward only.
`package` access is visibility only, and M0 settled how the project actually gets
cross-module optimisation — see "Cross-module optimisation" below; the short answer is no
build flags at all.

```
Sources/
  App/                 the .app target: NSApplication delegate, windows, menus, panels
  Chrome/              AppKit/SwiftUI shell: split views, sidebar, tab strip, mode line,
                       command palette panel, settings (SwiftUI), popovers, accessibility
  Canvas/              the Metal text canvas: glyph atlas, shaping cache, layout, damage
                       tracking, display link, minimap, cursor/selection/decorations
  Terminal/            PTY, VT parser, grid overlay, shell integration, input modes
  Editor/              buffers, windows/frames model, keymaps, command loop, minibuffer,
                       completion protocol, undo, faces, overlays, the redisplay planner
                       (produces DisplaySnapshots for Canvas)
  Text/                rope, anchors, interval tree, display transforms, encodings
  Lisp/                reader, printer, values, heap+GC, evaluator, bytecode compiler, VM,
                       regex engine, the builtin registry, the Swift<->Elisp boundary
  Lang/                tree-sitter binding, grammars (C targets), queries, indent engine,
                       LSP client, DAP client, project index, per-language packs
  Org/                 org parser, element tree, org index, agenda/capture/export
  Git/                 CLI driver, porcelain parsers, diff model, status/log/blame views
  Extensions/          manifests, package manager, Wasm host, XPC host, native module ABI
  Platform/            the Swift face of the platform: FSEvents, process spawning with
                       DispatchIO, energy/latency telemetry, signposts, the main-actor
                       watchdog, MetricKit, the launch-time self-test
  CPlatform/           the only C target that is not a vendored library: sys_icache_invalidate,
                       MAP_JIT helpers, PTY ioctls. Each shim carries a header comment
                       saying why Swift could not express it
lisp/                  the shipped Elisp library (simple, subr, modes, verilog, org glue)
queries/               tree-sitter .scm files, one directory per language
Tests/                 Swift Testing suites per module; golden-image tests for Canvas;
                       Elisp conformance tests run against GNU Emacs 30.2 output
dev/                   screenshot driver, LSP probe, mutation runner, benchmark suite,
                       app-bundle script, energy protocol scripts
```

Dependency direction: `App → Chrome → Canvas/Terminal → Editor → Text`, `Editor → Lisp`,
`Lisp → Text`, `Lang/Org/Git → Editor + Lisp`, `Extensions → Lisp + Editor + Platform`.
`Text` depends on nothing above it and both `Text` and `Lisp` are testable in isolation;
`Canvas` depends on `Text` (for snapshots) and on the `DisplaySnapshot` type owned by
`Editor`, never on `Lisp`. All C code lives in the `CPlatform` C target, wrapped by
`Platform`; no other target contains C.

The `Lisp → Text` edge is not decoration and was added in M0 after the cross-module study
found it missing. 4.6 puts the buffer-editing primitives, markers and the regex engine in
`Lisp`, and says the regex engine runs "on the rope's chunks without copying" — which is
impossible if `Lisp` cannot name a rope type. The alternative, a protocol defined in `Lisp`
and conformed by `Editor`, was rejected: cross-module generic and existential calls are not
devirtualised in any build configuration measured on this toolchain, so every scanned byte
would pay a witness call. `Lisp` therefore sees rope and chunk *types*; buffer, window and
command-loop *objects* stay in `Editor`, so the layering argument is unchanged.

**Cross-module optimisation.** The package builds with no `-package-cmo`, no
`-enable-library-evolution` and no `unsafeFlags` of any kind. Default access is `package`
and compiles to a real cross-module call. A call a benchmark shows is hot is promoted
deliberately in the source: the containing type becomes `public`, the hot members get
`@inlinable`, and anything an inlinable body touches gets `@usableFromInline`. Measured on
this machine (Swift 6.3.3, a two-op member called in a 100M-iteration cross-module loop,
best of three):

| shape | no flags | `-enable-library-evolution` + `-Xfrontend -package-cmo` + `-Xfrontend -allow-non-resilient-access` | `-enable-library-evolution` alone |
|---|---|---|---|
| plain `package func` (cold default) | 0.3309 s | 0.3319 s | 0.3313 s |
| `@inlinable` member of a **`public`** type | **0.0135 s** | 0.0135 s | 0.0762 s |
| `@inlinable` member of a **`package`** type | 0.0763 s | 0.0133 s | 0.0763 s |

Three things follow. The promoted shape reaches the same peak with no flags as package CMO
does with them, so the flags buy no speed — only the ability to keep the hot surface at
`package` visibility. `@inlinable` on a member of a `package` type does nothing without
those flags, so it is the *type* that must be promoted, not the member (an earlier version
of `CLAUDE.md` got this wrong). And library evolution without CMO is a 5.6x cliff on the
promoted shape, so a design resting on package CMO rests on an optimiser pass whose
bail-outs are silent, with a worse floor than doing nothing. Rejected alternatives and the
falsification plan are in 4.16.

The promoted hot surface is listed here explicitly, because it is now a source-level
decision rather than a build-flag one, and it is guarded by `dev/check-inlining.sh` (one
stock release build; asserts the promoted symbols are absent from the caller's object file
and the cold controls are still present). As of M0 it is empty apart from the probes; the
candidates, in the order the milestones need them, are: `Text.Chunk` and its byte
subscript; the `Text` snapshot cursor and its chunk-batch iteration; `Text.Anchor`
resolution; `Lisp`'s tagged `UInt64` value (tag test, fixnum extract, pointer decode) and
the arena accessors; and the line/run accessors of `Editor.DisplaySnapshot` that `Canvas`
reads. Everything else stays `package` and cold by default.

### 4.3 Threading and data flow

```
 NSEvent ──► UI actor (main thread)                       background actors
              │ rich KeyEvent, mouse, resize, focus         ┌─ tree-sitter parse (per buffer)
              ▼                                             ├─ LSP transport + JSON (per server)
         Elisp actor (dedicated pthread, custom             ├─ project index (SQLite)
         SerialExecutor; owns buffers, keymaps,             ├─ search (ripgrep-class)
         Lisp heap, timers; runs commands + hooks)          ├─ git CLI driver
              │ publishes DisplaySnapshot (viewport-free)       └─ file watcher (FSEvents)
              ▼                                                      │ results as Sendable
 Canvas (UI actor) ── shapes dirty lines, encodes Metal ─► present     values → Elisp actor
```

- **Ownership**: the Elisp actor owns mutable editor state. The UI actor never touches a
  buffer; it renders the last `DisplaySnapshot` (a value type) and forwards input.
  Background actors receive `BufferSnapshot`s and return `Sendable` results that the Elisp
  actor applies (diagnostics, parse trees, search hits).
- **The Elisp actor is an explicit run queue, not a bare executor.** Swift's
  `SerialExecutor` is only the mailbox that appends jobs; the actor owns a nestable loop
  (`recursive-edit` depth) it can re-enter from inside a running command. That is what
  `read-from-minibuffer`, `completing-read`, `y-or-n-p`, `recursive-edit`,
  `accept-process-output` and `sit-for` need: they return values synchronously inside a
  command by pumping the queue with a predicate and a timeout, exactly as GNU does in C.
  Swift gives no way to drain an executor from inside a job, so this is designed in M5, not
  discovered in M15.
- **Per-task Lisp context.** Every point at which Elisp can yield (`await`, the pumps above,
  cooperative `make-thread` switches) saves and restores a `LispContext`: specpdl top, current
  buffer, restriction, match data, `this-command`/`last-command`, excursion state. `await`
  inside a `let` of a special variable is rejected by the compiler unless the binding is
  captured. GNU keeps specpdl per thread and swaps `current_buffer` on switch; this is the
  same rule stated for the new primitives too, with an M3/M5 conformance test.
- **Preemption**: the VM checks a deadline every 64 instructions and on every call and
  back-edge; `post-command-hook` and `post-self-insert-hook` entries run under
  `hook-time-budget` (default 50 ms) with three-strikes quarantine, exactly Reticle's rule
  and no wider: commands the user invoked have no budget (`C-g` is the user's tool),
  `find-file-hook` and save hooks are exempt, and **change hooks
  (`before/after-change-functions`) are never quarantined**, because silently dropping one
  corrupts every derived structure (font-lock, org cache, LSP sync). An M5 test asserts the
  exemptions; `C-g` sets a flag the VM observes at the next check. JIT code, if
  ever added, must keep back-edge checks (Reticle's JIT lacked them; recorded as a limitation).
- **Redisplay**: after each command the Elisp actor publishes a **viewport-independent**
  `DisplaySnapshot` per window: the buffer snapshot, the face and decoration snapshot
  (font-lock and overlay attributes as ranges), the fold set, inlay and block-row records,
  point, mark and the window-start hint. The UI actor derives visual lines from it (wrapping,
  shaping, row heights) for whatever viewport it is showing, so a 120 Hz scroll or a momentum
  fling never asks the Elisp actor for anything. The Elisp actor learns the new window start
  after the fact, as GNU's redisplay does. Reticle's equivalent was the `Grid` with
  `PaintRun`s built on the Lisp thread; moving visual-line derivation to the UI side is what
  makes "layout and paint never wait for Elisp" literally true. M6's definition of done
  includes scrolling at full frame rate while the Elisp actor runs a ten-second loop.
- **Why not one actor per buffer** (Hinckley's design): cross-buffer commands (`ibuffer`,
  agenda, `save-some-buffers`, `switch-to-buffer` in a hook) are the common case in Elisp,
  and the Elisp semantics of `set-buffer` assume one thread. One Elisp thread plus snapshots
  for readers gives the parallelism that matters (parse, index, search, LSP, git, paint) without
  breaking `(with-current-buffer ...)`. Recorded as the deliberate compatibility boundary.
- **Worker processes** for user-level parallel Elisp (Reticle's M8 design: same executable in
  `--worker` mode, sexp protocol, kill-able) come back in a later milestone; they were proven
  and are cheap to port.

### 4.4 Rendering pipeline

Recommendation from the text-rendering research, matching what Ghostty and Zed do:

1. `DisplaySnapshot` → visual lines for the viewport (wrap, folds, blocks) → per visible
   line, an attributed run list (text, face, font features).
2. Shaping with Core Text (`CTTypesetter`/`CTLine`/`CTRun`), cached by (run text, face,
   font); font fallback for CJK and emoji from the system cascade; coding ligatures via
   `calt`/`liga` font features per face (Reticle's finding that a coding ligature is one glyph
   per character at uniform advance still holds for monospace faces and lets the terminal keep
   its grid).
3. Glyph cache keyed by (font, glyph id, size, sub-pixel phase) → miss → `CTFontDrawGlyphs`
   into a `CGBitmapContext` → upload to an alpha atlas texture.
4. Instance buffer of quads (position, atlas rect, colour) plus rects for backgrounds,
   cursors, selections, indent guides, diagnostic squiggles; one or few instanced draws.
5. `CAMetalLayer`, with `presentsWithTransaction` **only during live resize** (its contract
   serialises CPU and GPU per frame: commit, `waitUntilScheduled`, present inside the
   `CATransaction`; the M6 spike measures that cost before it is used anywhere else);
   `NSView.displayLink(target:selector:)` requested up to 120 Hz only while something is
   animating (smooth scroll, cursor fade, momentum) and **removed entirely when idle**.
6. Variable row heights (inline diagnostics rows, org headings, images), inline widgets and a
   minimap are all rows or additional passes over the same atlas; nothing needs a widget tree.

Rejected: `NSTextView`/TextKit 2 as the drawing path (no evidence it sustains 120 Hz on
large files; invalidation is not glyph-precise), `MTKView`'s timer loop (fights 0% idle),
one `CALayer` per line (no evidence at code-buffer density). TextKit 2 stays on the table as
an offline layout oracle for Unicode line breaking and bidi in org and prose buffers, to be
decided by the M6 spike.

Accessibility is the cost of a custom canvas and is scheduled, not deferred: the canvas
implements `NSAccessibilityStaticText`/navigable text protocols from the first canvas
milestone, because retrofitting it later is how every custom editor ends up inaccessible.

### 4.5 Text model

```swift
struct Chunk { var bytes: InlineArray<64, UInt8>; var count: UInt8 }          // leaf payload
struct TextSummary { utf8, utf16, lines, firstLineLen, lastLineLen, maxLineLen } // monoid
enum Node<Item: Summable> { case leaf([Item], Summary); case interior([Node], Summary, height) }
final class TextBuffer { root: Node<Chunk>; overlays: Node<OverlayRecord>; history; clock }
struct BufferSnapshot: Sendable { root, overlays, clock }   // O(1) to take, free to share
final class MarkerTree { /* order-statistics tree of marker positions with lazy offsets */ }
struct Anchor: Sendable, Hashable { markerID, bias }  // resolved against a snapshot's MarkerTree
```

- Persistent B+-tree rope; every mutation rebuilds the path to the edited leaves, so
  snapshots are structural sharing and background readers never lock.
- Summaries give O(log n) byte↔UTF-16↔line/column conversion, which the LSP client (UTF-16),
  tree-sitter (bytes) and the display (graphemes, lazily) all need; the `maxLineLen` summary
  is how a 20 MB single-line file is detected and laid out lazily instead of wrapped eagerly.
- Markers live in a **marker tree**: an order-statistics balanced tree keyed by position with
  lazily propagated offsets, so an edit adjusts every marker after it in O(log n) regardless
  of marker count, and a lookup is O(log n) (Emacs's linear marker list is its documented
  scaling limit). The tree is persistent like the rope, so a `BufferSnapshot` carries the
  marker positions of its moment and background readers resolve anchors against it. This is
  deliberately **not** Zed's anchor design: Zed resolves anchors through a CRDT fragment
  history with retained tombstones, which conflicts with R3's "memory never grows" unless a
  compaction story exists. The M1 definition of done names this choice and its complexity
  tests. Elisp `marker` objects are anchors with an identity wrapper; marker arithmetic
  (`(+ (point-marker) 1)`) resolves at use.
- Overlays and text properties live in one augmented interval tree (both start and max-end
  summarised, closing the gap Emacs 29's `itree.c` records as bug#58342). Property lookups
  are O(log n + k).
- Undo is transaction-based (grouped by command and by a 300 ms window), stored as edit
  logs plus retained snapshot checkpoints; branches are native, so an undo-tree UI is a view.
- Multi-cursor edits are one transaction with per-anchor bias rules.
- Read-only huge files (GB logs) are viewed through a line-indexed mmap without building a
  rope until the first edit.
- Node arrays are value types; the one ARC hazard measured in the spike (recursive release
  of long chains) is avoided because tree height is logarithmic, and closing a large buffer
  drops subtrees iteratively.

### 4.6 The Elisp engine

The engine is where Reticle's biggest lesson lands: its `Rc`-based enum values and re-run
error model made the JIT unwidenable and let cycles leak. The value representation is the
JIT decision and the GC decision; it is made once, here.

- **Values**: 64-bit tagged words. Fixnums (62-bit), characters, `nil`/`t`/symbols by
  index, heap pointers into engine-owned arenas for cons, string, vector, record, closure,
  bignum, float (boxed), hash table, and **every Lisp-visible editor object** (buffer,
  marker, overlay, window, frame, keymap, process, timer). ARC never owns a Lisp object.
  **The boundary rule**, which is where Reticle's cycle leaks lived (its README: cycles held
  through keymaps and overlays leak): editor objects *are* heap objects whose Lisp-valued
  fields (overlay plists, buffer-local bindings, process filters and sentinels, timer
  closures, undo entries) are traced by the collector like any other; the Swift-side state
  of such an object (the rope, the PTY, the socket) lives in a side table keyed by heap
  object id, never the reverse. Swift code that must hold a Lisp value across an allocation
  holds a registered `LispRef` handle that is a root while alive. A buffer→closure→overlay
  →buffer cycle is therefore ordinary garbage; M2's torture test builds exactly that cycle
  and asserts it is collected.
- **Heap and GC**: bump-allocated nursery, mark-compact or mark-sweep old space (decide by
  measurement in M4), precise roots from an explicit handle stack and the VM frame stack,
  write barrier on old→young stores, incremental marking with a per-slice budget so the
  pause histogram stays under the keystroke budget. Cycle-safe by construction, which retires
  Reticle's registry-plus-idle-collector design. **Allocation may collect**: any builtin that
  allocates must have rooted its intermediates on the handle stack, and the M2 torture mode
  collects on *every* allocation to make a missing root fail immediately rather than rarely.
- **Reader and printer**: full Emacs syntax (`#s(hash-table ...)`, `#&` bool-vectors,
  `?\C-x`, shorthands, `#'`, backquote), positions recorded for error messages.
- **Evaluator**: a bytecode compiler that runs by default on load (compiled objects keep
  the `interactive` form, arity, docstring and closure environment; Reticle M7 recorded
  commands silently failing once compiled because the interactive spec was lost, so M3 tests
  that `commandp`, `func-arity`, `documentation` and `interactive-form` agree between the
  interpreted and compiled definition) (no tree-walking tier in
  the product; the tree-walker exists only for `eval` of one-off forms and for bootstrapping
  the compiler). Fixed-width instructions with inline-cache slots; superinstructions for the
  hot Emacs opcodes; quickened `symbol-value`, `funcall`, `get-text-property`; no-allocation
  call path; specpdl-style dynamic binding; a function-redefinition epoch that invalidates
  inline caches (this is also how `advice-add` stays correct without trampolines).
- **Binding**: lexical by default (`lexical-binding: nil` cookie opts a file into dynamic
  scope, as Reticle did); `defvar` makes a symbol special; buffer-local variables with
  default values and `let` of buffer-locals implemented per GNU semantics because Doom-style
  configs rely on them.
- **Errors and non-local exits**: `condition-case`, `signal` with the full error-symbol
  hierarchy, `catch`/`throw`, `unwind-protect`; `quit` and `elisp-timeout` are not
  sub-conditions of `error` (a hook wrapped in `ignore-errors` cannot swallow them; Reticle's
  rule). Errors cross the Swift boundary as return codes, never as Swift `throws`, so native
  frames never need Swift unwinding.
- **Builtins**: one C-ABI-shaped Swift entry point per builtin taking a frame pointer and
  argument count; ~150 primitives native in Swift (list/sequence/string/hash/number core,
  buffer editing primitives, text properties, markers, regex search, keymaps, faces,
  processes, files, timers), the rest in the shipped Elisp library.
- **Regex**: Emacs syntax (`\(`, `\|`, `\{n,m\}`, syntax classes, `\_<`, backreferences)
  compiled to a matcher bytecode with an explicit backtracking stack and a work budget
  (Reticle's M81 design), running on the rope's chunks without copying.
- **Concurrency primitives added to the dialect**: `(async-run FN)` returning a promise,
  `(await P)`, cancellation tokens, `make-process` with filters and sentinels delivered on
  the Elisp actor, `call-process`/`shell-command-to-string` blocking only the Elisp actor with
  the UI still painting and `C-g` still working.
- **JIT policy**: none in v1. Reserved: MAP_JIT region, `allow-jit` entitlement, interpreter-
  compatible frames, back-edge checks, a side table for crash symbolication. A regex JIT is
  the first candidate if font-lock profiles show matching dominating, before any Elisp JIT.
- **Compatibility tiers** (the full list is the elisp-engine research report and becomes the
  conformance test list in M3-M5): tier 1, everything a Doom/Purcell-style config uses
  (`use-package`-like declarations, `setq`/`setopt`, hooks, keymaps, `defun`/`defmacro`,
  `cl-lib`/`seq`/`map`/`pcase`/`subr-x`, `define-derived-mode`, `define-minor-mode`,
  `advice-add`, `custom` basics, timers, processes); tier 2, what popular packages need to be
  ported (syntax tables and `syntax-ppss`, text properties on strings, `format-spec`,
  `completing-read` metadata, `transient`-shaped menus); tier 3, never (CCL, coding-system
  internals, the old dumper, `unexec`, frame parameters as the display model).

### 4.7 Command loop, keymaps, minibuffer, windows

- Key events are `(key, modifiers, text)`; keymaps bind either. `(kbd "TAB")` and
  `(kbd "C-i")` differ unless `key-compat-mode` is on. `ESC` is a real key: cancels the
  minibuffer, clears the region, leaves transient states. Meta is Option by default, Command
  optional, as emacs-mac allows.
- Emacs chords are handled in the canvas's first-responder `keyDown`, so `NSMenu` key
  equivalents (`⌘S`, `⌘Z`, `⌘,`) coexist and give newcomers the standard on-ramp; a native
  `NSTextField` in a dialog keeps macOS text behaviour.
- The minibuffer is an ordinary buffer with an ordinary keymap, hosted in a native panel at the
  bottom of the frame (or as a floating palette for `M-x`); recursive minibuffers are a visible
  stack; leaving it runs hooks and cancels the awaiting task (Reticle's non-rebindable Rust
  minibuffer and unobservable ESC are both gone).
- One completion-table protocol (candidates, metadata, category, affixation, annotation) feeds
  every picker; one completion-at-point protocol feeds the in-buffer popup. Orderless-style
  matching, marginalia-style annotations, embark-style category actions and which-key HUD are
  core, because every expert setup installs them (killer-features report, rank 2-4).
- Windows, frames, `display-buffer` actions, `split-window` ratios: GNU semantics, verified
  against GNU Emacs 30.2 with `emacs -Q --batch` where possible (Reticle M102/M103 recorded the
  behaviours already).
- Undo-tree UI, multiple cursors at the input-loop level, transient-style menus, a
  label-jump primitive (avy), a live-linked-region primitive (snippets, iedit, LSP rename)
  are core primitives, not packages.

### 4.8 Language intelligence

- tree-sitter via the C API in a SwiftPM system/C target (SwiftTreeSitter is BSD-3 and a
  good reference, but a thin own binding keeps the rope-backed `TSInput` and cancellation
  under control). Parsing on a background actor with `ts_tree_edit` incremental reparse,
  debounced, cancellable, feeding highlights (upstream `.scm`), indentation, folding,
  structural selection, symbol outlines and the AUTO system.
- Grammars compiled in (`tree-sitter-systemverilog` ~60 MB compiled is the largest; MIT).
  A `GrammarProvider` abstraction keeps runtime `.dylib` loading possible for language packs.
  Tcl needs a grammar found or written (unverified availability).
- LSP: transport, framing and JSON on a background actor in Swift with back-pressure
  (lsp-booster's lesson); typed messages handed to the Elisp actor; policy (which server, which
  method, what to do with a result) in the shipped Elisp, as Reticle did. Requests are
  cancellable and coalesced; UTF-16 positions are converted by rope summaries, never by
  scanning. Every server integration starts with a probe against the real binary (Reticle's
  `dev/lsp-probe.py`, ported) because declared capabilities lie.
- **Verilog specifics**: verible-verilog-ls and slang-server both attach; methods route by
  probed correctness (format/range-format/style lint → verible; diagnostics, completion,
  definition on package imports, references, rename, documentSymbol → slang), diagnostics
  merged; explicit server `cwd` = project root; filelist coverage surfaced to the user rather
  than silently degrading. This routing table was Reticle's most valuable finding and ports as
  data.
- A **persistent project index** (SQLite) built by background workers from tree-sitter tags
  queries: modules/interfaces/packages/classes and their ports and parameters for Verilog, top-
  level symbols for other languages, org headlines/tags/IDs. Kept fresh by FSEvents. It is
  what makes cross-file jump, instantiation completion and agenda instant on 100k-file trees,
  and it is the architectural answer to Reticle's "no cache, rescans every library file".
- DAP client for lldb-dap (Swift/C/C++) and debugpy; `compile`/`next-error` with error
  formats for make, ninja, iverilog, verilator, verible, slang and the commercial simulators
  where formats are public.

### 4.9 Extension tiers

| Tier | Runs where | Can do | Cannot do | Isolation |
|---|---|---|---|---|
| 1. Elisp | in the Elisp actor | everything a mode or command needs: buffers, keymaps, hooks, faces, minibuffer, processes | block the UI: hooks are budgeted and quarantined; long computation is preempted | time budgets, quarantine, attribution |
| 2. Wasm | WasmKit (interpreter, ships with the Swift toolchain, no fetch) or wasmtime C API where JIT speed and epoch interruption are needed | language packs (grammar + queries + server config), themes, formatters, pure computation over snapshots, completion sources | touch buffers directly, spawn processes, read files outside declared paths | memory limits, fuel/epoch interruption, crash contained per instance |
| 3a. Process | LSP/DAP/JSON-RPC children and XPC services (our own unsandboxed helper binaries or user-installed tools) | anything, with the shell, filesystem and network the user granted | share memory with the editor | OS process boundary |
| 3b. ExtensionKit | `.appex` extensions discovered through `AppExtensionIdentity` | UI-bearing sandboxed extensions | leave the App Sandbox; be installed as a loose file: they ship inside an installed, LaunchServices-registered `.app`, which shapes distribution | App Sandbox + process |

Packages declare a manifest (name, semver, dependencies, activation triggers, contributed
commands/modes/keymaps, required capabilities, tier). Installation compiles ahead of time,
never in the background of an interactive session. A native-module ABI keeps Reticle's shape
(versioned `repr(C)` function table, opaque `u32` handles, size-prefixed structs).

### 4.10 Terminal

- PTY via `posix_openpt` and `posix_spawn` with the slave as the child's stdio (never
  `forkpty` from a multithreaded Swift process: nothing between fork and exec may touch the
  Swift runtime), login shell with the user's environment, `TIOCSWINSZ` on
  resize, `TERM=xterm-256color` (no new terminfo entry).
- Own VT parser (Williams' VT500 state machine) in Swift; SGR, DEC private modes,
  bracketed paste, mouse reporting, 24-bit colour, OSC 7 (cwd), OSC 8 (hyperlinks), OSC 133
  (prompt/command marks), OSC 1337 and kitty graphics for inline images; the kitty keyboard
  protocol for unambiguous keys in char mode.
- A terminal pane is a buffer: scrollback is real text with SGR spans as text properties and
  command boundaries as overlays; `isearch`, `occur`, kill-ring and `compile`-style error
  scanning restricted to the last command's output all work with no copy mode. On DECSET
  1049 (vim, htop, tmux, less) the live region becomes a grid overlay drawn on the same atlas;
  it collapses back to text on exit.
- Input modes (eat.el's proven model): semi-char (keys go to the shell except a small reserved
  Emacs set), char (everything goes to the program, one escape chord), buffer (no forwarding;
  ordinary editing). The mode is shown in the mode line and by cursor shape.
- `M-!`, `M-&`, `M-|`, `shell-command`, `compile`, `comint` run on the same engine.
- SwiftTerm (MIT) is the semantic reference and the candidate widget for the alt-screen;
  libghostty is rejected for v1 (opaque surface API, Zig toolchain). Both decisions are
  re-examined by the M13 spike.

### 4.11 org-mode

Every non-Emacs Org implementation surveyed (orgmode.nvim, orgize, uniorg, organice, Logseq)
converged on two lessons: a rigid grammar (tree-sitter-org) cannot reproduce Org's
context-dependent parsing exactly, and byte-for-byte round-trip fidelity is non-negotiable
because org files are irreplaceable personal data. So:

- **Parser**: hand-written recursive descent producing a lossless syntax tree (every source
  byte reconstructable), in two tiers: a cheap context-free skeleton scan (headlines,
  sections, property drawers, planning lines) that re-runs incrementally on the touched
  region, and lazy deep parsing of a section's contents (paragraphs, lists, tables, blocks,
  objects) only when rendered, unfolded, exported or executed. This mirrors `org-element-cache`
  and is what keeps 10k-line files instant. The element/object taxonomy mirrors
  `org-element.el`'s three tiers (verified against the installed Org 9.7.11 by a batch probe)
  so ox-style exporters and roam-style tools port with the same concepts. tree-sitter-org may
  bootstrap fontification in the first org milestone and is then retired.
- **Folding** is a display transform on the rope, never overlay bookkeeping. Reticle's org
  fontification bottleneck turned out to be O(L²) overlay scans (616 ms → 132 ms on 60k lines
  after a sorted structure); the interval tree in 4.5 makes that class of bug impossible.
- **Index**: one SQLite store (Apple's bundled SQLite3, no dependency) keyed by file path and
  content hash: headline positions and levels, TODO state, priority, tags with a materialised
  inherited-tags column, planning timestamps, `:ID:` properties, link sources and targets.
  Updated per changed file or subtree by a background worker; agenda, refile, ID lookup and
  backlinks are SQL queries, so agenda never opens a buffer.
- **Round-trip test**: a corpus of real `.org` files must open and save byte-identical, and
  the parser's element tree must match `org-element-parse-buffer` from GNU Emacs 30.2 on the
  same corpus (the parity oracle again).
- **Ordering inside the org axis** (section 8: M16, M17, M18, M23, M24): core outliner (fold, TODO sequences,
  priorities, tags with inheritance, lists and checkboxes with statistics cookies, timestamps,
  fontification) → structure (property drawers, tables with alignment and simple `#+TBLFM`
  arithmetic, links with an extensible type registry, footnotes, planning lines with
  repeaters) → index plus agenda/capture/refile/archive → org-modern-style polish (pill tags,
  bullets, inline images and LaTeX previews as non-destructive attributes) → babel (single
  block execution and tangle first, then multi-language babel with noweb) and export
  (HTML, Markdown, LaTeX/PDF when a TeX toolchain is present) → roam-style backlinks on the
  same index. All of it is in scope for v1; only mobile sync is not.
- **Scope decision (owner, 2026-09-05)**: GNU org does complete GTD, so pellicle does
  too. The editor's agenda is the full thing (agenda views with custom commands, capture
  templates, refile with path completion, archiving, clocking and effort, habits, column
  view), not a complement to the owner's orgtd web app; orgtd's data model is a reference for
  what a real GTD user needs, nothing more.

### 4.12 git, search and navigation

**git.** Native, driving the `git` CLI as Magit and VS Code do: `status --porcelain=v2`
with `--no-optional-locks`, `diff` and `--word-diff=porcelain` for word-level highlights,
hunk and line staging by synthesising a patch and running `apply --cached` (the edge cases,
overlapping hunks and renames, get their own test budget), `blame --porcelain`, `log` with a
fixed format, interactive rebase by serving the todo list through `GIT_SEQUENCE_EDITOR`.
The status buffer is the hub (sections, TAB to expand, `s`/`u`/`c`/`P` as in Magit), every
flag-heavy command opens a transient menu, diffs and blame render natively rather than by
parsing ANSI. libgit2 (GPLv2 with linking exception) is allowed only as a narrow supplement
if profiling shows the CLI too slow for something like blame-on-scroll. A 3-way merge editor
and forge-style PR/issue views come after the Magit core.

**Search.** Project search shells out to ripgrep (inherits `.gitignore` handling, proven
throughput) streaming into an editable results buffer: Reticle's M82-M85 design (background
search, wgrep-style write-through, orderless filtering) ports, with its two recorded defects
fixed by design (O(N) re-rank per navigation keystroke; `C-g` not restoring state). A
Smith-Waterman fuzzy scorer of the nucleo/fzf kind with frecency ranks quick-open and
command-palette candidates. In-process regex for buffer search is the engine from 4.6; an
in-process project search engine is not planned unless subprocess latency proves a problem.

**Navigation.** The project index (4.8) is the primary cross-file jump for Verilog at
100k-file scale (LSP workspace-symbol scaling is unproven for both Verilog servers), with LSP
as fallback for other languages; xref-style pluggable backends; breadcrumbs and outline from
tree-sitter; bookmarks, registers, recent files and a jump list are core.

### 4.13 The Verilog killer-feature path

Ordered by how many real RTL edits each touches (the verilog-killer-features report, backed by
Reticle's probes):

1. Dual-server routing and merged diagnostics (4.8).
2. AUTOINST / AUTOWIRE / AUTOARG / AUTO_TEMPLATE on tree-sitter, idempotent, comment-safe
   (Reticle's design ports; balance-scan templates, never regex).
3. The rest of the AUTO family: AUTOSENSE, AUTOINPUT/OUTPUT/INOUT, AUTOREG, AUTORESET,
   AUTOTIEOFF, AUTOUNUSED, instance arrays, `.*`.
4. Local-first completion for module names, ports and parameters at instantiation sites,
   with LSP fallback and never dabbrev at a confirmed port position.
5. Cross-file jump for modules, interfaces, packages, classes and programs from the project
   index, LSP as fallback.
6. Filelist and project-root discipline: `.f` files with `+incdir+`/`+define+`/`-y`,
   `verible.filelist`, explicit root, coverage warnings.
7. Ground-truth-checked references/rename/definition routing (verified against `grep`).
8. Hierarchy browser and instance tree from the index; signal driver/load tracing via slang.
9. Lint/format/simulate loop: verible format on save with selectable style, verilator/slang
   lint, iverilog/verilator run with `next-error`, waveform hand-off to surfer/gtkwave, later a
   bundled lightweight VCD/FST viewer.
10. UVM awareness (class hierarchy, factory, phases, snippets) and SVA authoring aids, after
    the RTL-author features are solid.

### 4.13b Build, run, debug, simulate, and AI

- **compile / next-error**: a generic error-regexp table (make, ninja, iverilog, verilator,
  verible, slang, VCS/Xcelium/Questa where formats are public; the GNU
  `compilation-error-regexp-alist` is the seed) with a length cap and work budget per line,
  because Reticle's M80 nearly hung the editor on unbounded backtracking over real `cargo`
  output. Structured output (SARIF, JUnit, TAP) is preferred whenever a tool offers it.
- **Run configurations / tasks** live in a per-project file and run on the terminal tier.
- **DAP**: a generic client, lldb-dap first (bundled with Xcode: Swift, C, C++, ObjC),
  debugpy second; breakpoints in the gutter, variables and watch panes, inline values in the
  buffer (a real "beats GNU Emacs" item). Perl adapters are weak and Tcl has none; neither is
  promised.
- **Simulation**: iverilog and verilator runs with `next-error`; waveform hand-off to surfer
  or gtkwave first; an embedded waveform pane (surfer via `WKWebView` and `postMessage`, whose
  EUPL-1.2 license needs the owner's sign-off, or an own lightweight VCD/FST viewer) later.
- **AI**: fully optional and off the hot path. The editor implements an **Agent Client
  Protocol** client so any ACP agent can be hosted (Claude Code via its CLI in headless JSON
  mode, Gemini CLI, Zed's agents) without a hard-coded vendor; **MCP** is the tool and context
  layer beneath whichever agent runs; LSP `inlineCompletion` is the lighter path for ghost
  text; Apple's on-device Foundation Models framework (a ~3B model, no fine-tuning, hard
  context limit) is a candidate for small zero-network tasks such as commit-message drafts.
  For RTL shops, **nothing leaves the machine without explicit per-project opt-in**; IP
  confidentiality is the dominant risk. Anthropic's terms forbid presenting a third-party
  integration as "Claude Code" or offering claude.ai login on top of the SDK; shelling out to
  the user's own logged-in CLI or API-key auth are the compliant paths.

### 4.14 Energy and stability rules

Each rule is a definition-of-done item somewhere in section 8 and a line in the release
protocol below.

1. No free-running draw loop: the display link is added on input, mutation or animation,
   kept for about one second after the last change (Zed's measured sweet spot on ProMotion),
   then removed. Idle CPU must be indistinguishable from an idle TextEdit window.
2. Every non-input timer carries a tolerance of at least 10% of its interval
   (`Timer.tolerance`, `DispatchSourceTimer` leeway) so the OS can coalesce wake-ups.
3. Background parse, index and search run at `.utility` QoS (maintenance at `.background`)
   on their own queues, cancel on the next edit, and never share a lock with the input or
   paint path beyond a short critical section. The P/E-core split then keeps them off the
   keystroke path structurally.
4. Main-actor hops are batched per logical unit (one hop per diagnostics batch, not per
   diagnostic); Apple documents a main-actor crossing as a real context switch.
5. Work that must continue in the background (a running shell, a compile, an index the user
   is watching) holds a `ProcessInfo` activity assertion; Metal does not exempt an app from App
   Nap.
6. Long ARC chains are never released recursively (the spike's segfault); tree structures are
   torn down iteratively.
7. The Lisp GC is incremental with a per-slice budget checked at safepoints; a stop-the-world
   pause on a keystroke is a bug.
8. Every cache is bounded proactively (glyph atlas, shaped runs, parse trees, LSP symbols,
   undo horizon), with a process-wide RSS ceiling that drops soft caches before the OS memory
   pressure signal arrives.
9. Every observer, timer and long-lived closure has a tested teardown; an open-N/close-all/
   assert-zero-leftovers test is a standing regression test.
10. Directory trees are watched with FSEvents, open files with `DispatchSource` on kqueue;
    nothing polls with `stat`.
11. Child-process I/O streams through `DispatchIO`/`FileHandle.readabilityHandler`, its QoS
    tied to the pane's visibility; nothing polls a pipe.
12. One shared damage representation (dirty byte ranges since the last stable point) feeds
    rendering, shaping, highlighting and LSP incremental sync.
13. Every LSP server and external tool is supervised: restart with backoff, visible but
    non-blocking status, never able to hang or crash the host.
14. `MXMetricManager` subscribed from day one (hangs, CPU exceptions, crashes) and
    `os_signpost` intervals around every subsystem boundary (key received, reparse, display
    link resume/pause, LSP round trip) behind a disable-able `OSLog` handle.
15. An in-process watchdog pings the UI actor from a low-priority thread and logs any round
    trip over 200 ms during development.

**Release protocol** (run before every tagged build, results appended to
`release-checks/<date>.md` so trends are visible):

| Check | Method | Pass |
|---|---|---|
| A. Idle | 60 s untouched with a 5-10k-line file open; `sudo powermetrics -i 1000 -n 60 --show-process-energy` | average CPU indistinguishable from the TextEdit baseline re-measured on the same OS; no regression versus the previous release |
| B. Typing burst | 200 scripted keystrokes under `powermetrics -i 200 --show-process-gpu`; signposts show the display link pausing between keys | no sustained P-state ceiling; return to idle within 1-2 s |
| C. Keystroke latency | signpost interval from key event to frame commit, captured with `xctrace` Time Profiler over a few hundred keystrokes | p99 under one frame at the display's refresh (16.7 ms on this machine, 8.3 ms on ProMotion); no regression |
| D. Soak | 8 hours scripted (24 before a tagged release): open/close files in every target language, type, index, run shell commands, run LSP servers; RSS and energy every 5 min | RSS within +10% of the 30-minute baseline; zero crashes; no thermal creep in the second half; no MetricKit hang diagnostics |
| E. QoS tripwire | soak again under `sudo taskpolicy -c utility` | diagnostic only: a latency cliff means the input path is not actually `.userInteractive` |

### 4.15 Verification strategy

- **Swift Testing** suites per module; the Lisp engine has a conformance suite whose expected
  values are produced by `emacs -Q --batch` (recorded, not hand-written, because Reticle M110
  showed a spec written from memory corrupts data).
- **Golden-image tests** for the canvas: the renderer has a headless path (render a
  `DisplaySnapshot` to a texture, read back) from its first milestone, so "what does it look like"
  is a test, not a screenshot ritual. Screenshots of the real window remain the final word for
  chrome.
- **Mutation testing** for important fixes (`dev/mutate.py` ported from Reticle).
- **Benchmark suite** (editor workloads: fontify a 20k-line `.sv`, 10k keystrokes through
  hook chains, org agenda over 1,000 files, project search on 100k files) run before every
  release and compared with Emacs 30.2 and with the previous build.
- **LSP probes** against real servers before any LSP work.

### 4.16 Decision log (rejected alternatives)

| Decision | Rejected | Why |
|---|---|---|
| Custom Metal canvas | NSTextView / TextKit 2 drawing | no evidence of 120 Hz on large files; glyph-imprecise invalidation; would repeat Emacs's "display owns everything" coupling |
| Rope | gap buffer (Emacs, Reticle), piece table (VS Code) | gap buffer has no O(1) snapshots for background readers; piece tables fragment under heavy editing |
| `@inlinable` on a `public` type for hot cross-module calls (M0) | library evolution + package CMO; merging `Text`/`Lisp` into one module; a protocol boundary | measured parity with package CMO at zero flags (0.0135 s vs 0.0133 s), and package CMO's prerequisite — library evolution — is a 5.6x cliff whenever its silent bail-outs fire. Merging modules buys nothing once the call is inlined and gives up the only enforcement of "`Canvas` never imports `Lisp`". A protocol boundary was measured non-devirtualised in every configuration |
| Tagged words + own GC | ARC-managed Lisp objects + cycle collector (Reticle) | measured 5x on traversal, recursive-release crashes, cycle leaks, and it forecloses a JIT |
| One Elisp thread | actor per buffer | breaks `set-buffer` semantics that every config relies on; parallelism goes to readers instead |
| Bytecode VM, no JIT | Cranelift-style JIT first (Reticle) | 575x on loops, 1.0x on `fib`; editor time is in runtime calls, not dispatch |
| Own VT parser + buffer scrollback | libghostty | opaque surface API fights "terminal output is buffer text"; Zig toolchain in a Swift build |
| git CLI | libgit2 | GPLv2-with-exception, thread-safety and feature gaps; Magit proves the CLI path |
| WasmKit default | wasmtime default | WasmKit ships with the toolchain and needs no fetch; wasmtime kept as the escape hatch |
| AppKit shell | SwiftUI shell, GPUI-style own UI | SwiftUI's text and split-view control is insufficient for an editor; an own UI framework is Zed's multi-year detour |
| No TUI | dual frontends (Reticle) | the owner's requirement; it is also what freed the display model from the grid |
| Developer ID + Sparkle | Mac App Store | an editor that spawns arbitrary shells cannot live in the App Sandbox |

### 4.17 Open questions to settle by experiment

| Question | Experiment | Milestone |
|---|---|---|
| Does `NSView.displayLink` pause/resume cheaply enough to toggle per damage event, and does `preferredFrameRateRange` behave on macOS as on iOS? | 200-line canvas spike measuring idle CPU with `powermetrics` and frame pacing with `xctrace` | M6 |
| TextKit 2 as a layout oracle: does `NSTextLayoutManager` give correct line breaking for org prose without owning drawing, at acceptable cost? | lay out a 5 MB org file both ways, measure | M6/M16 |
| Mark-compact vs mark-sweep old space | implement sweep first; measure fragmentation on the benchmark suite | M4 |
| WasmKit interpreter speed for a completion source over a 20k-line snapshot | spike with a Wasm fuzzy matcher | M22 |
| SwiftTerm alt-screen widget vs own grid | two-week spike, vttest + vim + htop + tmux | M13 |
| Tcl grammar availability | search, else write a small grammar | M15 |
| Sub-pixel glyph phases: 4 vs 16 | measure atlas size and scroll smoothness at 120 Hz | M6 |

---

## 5. Elisp compatibility contract

The engine research report (`doc/research/elisp-engine-design.md`) defines three tiers;
they are reproduced here because they are the conformance-test list for M3-M5 and M15.

**Tier 1, must work for a Doom/Purcell-style `init.el` to load and behave.** The full
reader; lexical binding by default with the `lexical-binding` cookie honoured per file (a
ported file may say `nil`); `defvar`/`defconst`/`defcustom`/`setq`/`setopt`; `let`/`let*`
including dynamic rebinding of buffer-locals with GNU's exact "which cell was active at bind
time" rule; all 22 special forms (the oracle's `special-form-p` census is the list);
`defun`/`defmacro`/`lambda`/closures; `require`/`provide`/`autoload`/`load-path`;
`condition-case`/`signal`/`error`/`user-error`, `catch`/`throw`, `unwind-protect`; hooks;
keymaps and `use-package` (a macro-only dependency, so it ships); `defgroup`/`defcustom`
enough not to error; buffer-local variables (`make-local-variable`, `setq-local`,
`make-variable-buffer-local`, `default-value`, `with-current-buffer`); timers and
processes at least to the point where a config that starts a server does not error;
`format` with full width, flags and precision (a Reticle gap promoted to tier 1); and the
command-loop primitives that ported packages lean on and that are easy to forget:
`while-no-input`, `unread-command-events`, `buffer-undo-list` manipulation, narrowing with
`save-restriction`, indirect buffers, text-property stickiness, `before/after-change-
functions`, prefix arguments, keyboard macros, `recursive-edit`.

**Tier 2, needed to port the packages the plan chooses to port** (evil, corfu/cape,
which-key, consult-class pickers, project.el, transient-shaped menus, org, tree-sitter
modes). `cl-lib` (`cl-defun`, `cl-defstruct`, `cl-loop`, `cl-case`, generic dispatch subset)
with `gv.el`-style generalised places so `push`/`pop`/`incf`/`setf` are general (another
Reticle gap); `seq`, `map`, `pcase`, `subr-x`; `nadvice` implemented as function-cell wrapping
with a shared redefinition epoch; the full regex dialect including `\\_<`, backreferences and
syntax-class classes; syntax tables plus `syntax-ppss`/`forward-sexp`/`scan-sexps`
(Reticle's largest gap; nearly every language mode needs it); `define-derived-mode` and
`define-minor-mode`; overlays with priority, face and keymap properties; text properties on
strings (`propertize`); `completing-read` metadata; async `make-process` with filters and
sentinels; idle timers; `make-thread` as cooperative logical threads on the one interpreter
thread, exactly as GNU does it.

**Tier 3, never.** The `emacs-module.h` ABI (pellicle has its own module ABI); native-comp
and `.eln`; byte-for-byte `.elc` compatibility (the compiler consumes source); TTY and
terminfo code paths; the old dumper; TRAMP methods beyond SSH; multi-tty display code; CCL
and coding-system internals (strings are Unicode scalars with raw-byte escapes).

**Async contract.** No new promise syntax is required for compatibility: `accept-process-
output`, `sit-for` and `sleep-for` are implemented as bounded pumps of the Elisp actor's event
queue with a predicate and timeout, which is what GNU does in C and what eglot-style code
assumes (other timers and process filters keep running during the wait). Filters and
sentinels are always invoked on the Elisp actor, never on a GCD thread. `(async-run ...)` and
`(await ...)` are additive sugar on the same queue for new code.

**Licensing of the shipped Elisp.** `lisp/` is clean-room: GNU's `subr.el`, `simple.el` and
friends are GPLv3 and are used **only as a behavioural oracle** through `emacs -Q --batch`,
never as source to derive from. File names avoid GNU's. This is a decision, recorded here
because a Developer-ID-distributed app's licence depends on it.

*Settled 2026-09-07, by the owner:* the project ships under **FSL-1.1-ALv2**, the
Functional Source License 1.1 with an Apache 2.0 future grant -- the same licence Reticle
uses, `LICENSE.md` at the repository root, byte-identical to fsl.software's template but
for the copyright line. The clean-room rule above -- which predates this decision -- is
what left the choice open: GPLv3 is copyleft, so anything derived from GNU's files would
have had to ship as GPLv3 itself. Not, as this paragraph first said, because Apache 2.0 is
incompatible with GPLv3; a cold reviewer fetched the FSF's licence list and it says the
opposite, that Apache 2.0 *is* compatible with GPLv3 and it is GPLv2 that conflicts. The
error was in the README too. Nothing else in the tree is third-party today, so there is no
`THIRD_PARTY_LICENSES.md` counterpart to Reticle's; the rule in `CLAUDE.md` that adding a
SwiftPM dependency is a milestone decision recorded with its licence is what keeps that
true.

*Round 2 of the cold read on that correction found nothing to change.* It re-fetched the
FSF list and got the same answer, checked the Competing Use summary against `LICENSE.md`,
and dated the clean-room rule to the initial commit (2026-09-05) against this decision
(2026-09-07), two days apart. Its three remaining notes are recorded rather than acted on,
all of them precision rather than fact, and it said it would not block on any: that GNU's
headers read "version 3 ... or (at your option) any later version", so "would have had to
ship as GPLv3 itself" is a simplification; that the one-line Competing Use summary drops
the clause's "making the Software available to others", which cannot mislead because
non-distribution cannot infringe; and that `README.md`'s design note says "a dependency"
where this paragraph now says "a SwiftPM dependency" -- a line that neither round touched.
This entry transcribes that round; it is the loop's terminator, not a new batch.

**Native builtins.** About 150 primitives are native Swift at first (the engine report lists
them by group: cons/list, predicates, arithmetic, symbols/eval, strings, vectors/sequences,
hash tables, buffers and editing, buffer-locals, text properties and overlays, markers,
regex, syntax, keymaps, hooks, advice, processes, timers, I/O, load/require). The groups
land in dependency order: values and lists → buffers, text properties, markers → regex →
syntax → keymaps → processes and timers. GNU 30.2 has 1,530 `subrp` symbols; the rest is
Elisp or out of scope (1,483 distinct primitives once aliases are removed).

**Verification.** Every tier-1 and tier-2 behaviour gets a conformance test whose expected
output is recorded from `emacs -Q --batch` and quoted in the test, never written from
memory (Reticle M110). The interpreter has a `--batch`/`--eval`/`--script` mode purely for
this test harness and for the mutation runner; it is not a user-facing CLI.

---

## 6. Risks and countermeasures

| Risk | Why it is real | Countermeasure |
|---|---|---|
| The engine's value representation and GC are a from-scratch systems project inside Swift | Swift gives arenas that ARC ignores but no root enumeration, no relocation, no barriers; the research is explicit that this is "writing a GC in C, in Swift" | M2 lands the heap with a non-moving mark-sweep and an explicit root stack first; generational and incremental work is M4 with the pause histogram as the gate; the API between `Lisp` and everything else is handles, so the collector can change without touching callers |
| Custom canvas means custom accessibility, IME, selection and Unicode line breaking | Every custom-drawn editor pays this; deferring it is how editors end up inaccessible | M6 includes `NSAccessibility` protocols and `NSTextInputClient` (marked text for CJK input methods) in its definition of done; TextKit 2 is kept as a line-breaking oracle option |
| Apple API behaviour on macOS 26 not fully verified from primary docs during research | Reference pages were unreachable in this run; display-link pausing, `preferredFrameRateRange` and `presentsWithTransaction` semantics are medium confidence | M6 starts with a measured spike (4.17) before any dependent code; Xcode's offline documentation is the source |
| Elisp compatibility scope creep (Reticle's Risk 1) | Every package pulls in more primitives | The tier contract in section 5; anything outside tier 2 needs a milestone decision, not a drive-by |
| VT compatibility takes years to reach xterm parity | Hundreds of DEC modes and application quirks | vttest plus a fixed set of real programs (vim, htop, tmux, less, fzf) as the acceptance list; SwiftTerm as the semantic reference; the alt-screen widget may be SwiftTerm's if the M13 spike says so |
| Two Verilog servers, both imperfect and both moving | verible has no completion and corrupts rename; slang has no formatting | Routing is data, re-probed per server version with the ported probe tool; diagnostics merged; nothing routed on declared capabilities |
| Session-limit and delegation cost in the development process itself | The research phase of this plan hit the usage limit twice with eight concurrent agents | `CLAUDE.md` caps concurrent background agents and sizes tasks by work budget |
| One developer plus agents maintaining ~15 modules | Breadth is the enemy of a solo project | Milestones are single-topic and each ends usable; the foundation phase is deliberately narrow (one language, one server pair) before breadth |
| A JIT entitlement and W^X mistakes are silent failures in shipped builds | `mmap` returns EINVAL with no message | The bundle script signs with the entitlement and a launch-time self-test exercises MAP_JIT (even before any JIT exists) so a broken signature is caught on first run |

---

## 7. Working method

The rules live in `CLAUDE.md` (loaded every session). They are Reticle's rules, each of which
came from a recorded incident, adapted to Swift tooling: reconnaissance first, specs with
oracle-quoted behaviour, cold-read review that tries to refute, mutation testing on
important fixes, the three-gate definition of done, screenshots or golden images for every
visual claim, LSP probes before LSP work, and a cap on concurrent agents. This file records
only design decisions and milestone outcomes; the empirical origin of each rule stays in
Reticle's `PLAN.md` ("Empirical sources of the rules") and is not duplicated here.

---

## 8. Milestones

Ordering rationale. The owner's priority is Verilog > org > beauty/performance/power, and
the hard constraints (native macOS, terminal, extensibility, stability) apply throughout.
A Verilog feature cannot be shown before there is a buffer, an engine, a renderer and an LSP
client, so M0-M8 are foundation, chosen so each is usable and testable on real RTL from
Reticle's `demo/rtl`. Verilog features begin at M9 and reach a daily-driver point at M14;
org begins at M16, right after the Elisp library work it depends on, and runs to full GTD
parity by M18 before git and the killer-feature core; beauty and energy work
is not a phase but a definition-of-done item in every GUI milestone, with one dedicated
stability wave at M21. Every milestone follows the eight-step loop in `CLAUDE.md` and ends
with two commits.

Definitions of done are written to be verifiable by a test, a golden image, a screenshot, a
recorded oracle transcript or a measurement, never by reading code.

### Phase A: foundation (M0-M8)

- **M0 Repository and gate.** SwiftPM package with the module layout of 4.2 (empty
  targets), the cross-module hot call settled by benchmark, `dev/gate.sh` (`swift format
  lint --strict`, `swift build`, `swift test`), `dev/ci.sh` (the gate, the inlining check,
  the app bundle, the self-test and a codesign verify, run on this machine; there is no
  remote CI), `dev/make-app-bundle.sh` (Info.plist, entitlements `allow-jit` +
  `disable-library-validation`, `.icon` + `.icns` per Reticle M98, codesign with hardened
  runtime), a launch-time self-test that
  exercises MAP_JIT and `dlopen`s a bundled test dylib, `MXMetricManager` subscription,
  `os_signpost` handles and the main-actor watchdog from day one, `CLAUDE.md`, `Tests` smoke
  test. Done when the gate is green, the `.app` launches an empty native window and the
  self-test passes under the hardened runtime.
  *Amended 2026-09-07:* this entry used to say `-package-cmo` would be "proven on one
  cross-module hot call" and that `dev/ci.sh` was "the gate plus golden images and the short
  energy checks". M0 settled the first the other way -- the driver never forwards the flag,
  and `public` + `@inlinable` reaches the same speed with none -- and built the second
  without those two stages, neither of which has anything to run yet. Corrected in place
  above rather than left standing beside this note; the record is in section 11.
- **M1 Text.** Rope with summaries, snapshots, anchors, interval tree, transactions and undo
  checkpoints, line-indexed mmap view. Done when property tests against a naive string model
  pass over 1M random edits, complexity benchmarks match the table in 4.5, a 2 GB file opens
  read-only in under a second, closing it does not recurse, and the marker-tree choice
  (4.5) is implemented with its O(log n)-per-edit test at one million markers.
- **M2 Lisp values, heap, reader, printer.** Tagged words, arenas, handles, root stack,
  non-moving mark-sweep, reader and printer for the full syntax, editor objects as heap
  objects with Swift side tables. Done when read → print → read yields `equal` structure for
  every top-level form of GNU's `subr.el` (the oracle: `?\C-x` reads as 24 and prints as 24,
  so textual identity is not the test), the torture mode that collects on every allocation
  passes a scripted session, the buffer→closure→overlay→buffer cycle is collected, and the
  pause histogram is recorded.
- **M3 Evaluator and VM.** Special forms, macros and backquote, specpdl and buffer-locals,
  errors and non-local exits, bytecode compiler with inline-cache slots and superinstructions,
  deadline checks, the first ~80 builtins (values, lists, strings, symbols, hash tables,
  numbers with bignums), compiled objects keeping their `interactive` form, arity,
  docstring and environment. Done when the oracle-generated conformance suite for those
  groups passes, the `LispContext` save/restore tests pass, and `loop-sum(20M)` runs in
  0.5 s or less (25 ns per iteration; Reticle's VM measured 2.55 s and the Swift tree-walker
  already does 2.4 s, so "at or below Reticle" would gate nothing).
- **M4 Engine performance and regex.** Generational nursery and incremental old-space
  marking with a per-slice budget; the regex engine; `format` with full flags. Done when the
  pause histogram's p99 is under the keystroke budget on the torture suite and the regex
  conformance suite (oracle-generated, including Reticle's org patterns) passes.
- **M5 Editor core.** Buffers, windows and frames model, faces, overlays and text properties
  on the interval tree, keymaps with rich key events, the Elisp actor with its executor, the
  command loop, hooks with budgets and quarantine, timers, async processes, the minibuffer as
  a buffer, the completion-table and completion-at-point protocols, undo commands, the
  `DisplaySnapshot` publisher, and a headless driver. Done when a scripted session opens Reticle's
  `demo/rtl/top/soc_top.sv`, edits, searches and saves it through the driver with `DisplaySnapshot`
  assertions, a slow hook is quarantined with its name in the echo area, and the window and
  `display-buffer` behaviours match oracle transcripts (Reticle M102/M103's cases).
- **M6 Canvas.** The 4.17 spike first (display link pausing, frame-rate range,
  `presentsWithTransaction`, sub-pixel phases), then the Metal renderer: atlas, shaping cache,
  instanced draws, cursor, selection, indent guides, squiggles, smooth scrolling, variable row
  heights, a headless render-to-texture path, golden-image tests, `NSTextInputClient` for
  CJK input and the `NSAccessibility` text-area surface (`AXSelectedTextRange`,
  `AXStringForRange`, `AXLineForIndex`, a per-line element tree). Done when a 20k-line `.sv`
  scrolls at the display's native refresh with no dropped frames **while the Elisp actor
  runs a ten-second loop**, the display link is removed at idle (powermetrics shows the
  TextEdit baseline), golden images match across the fixture set, VoiceOver reads and
  navigates lines, a Chinese input method composes text, and Emacs chords still reach the
  command loop while an IME is composing (with a stated compatibility rule for cancelling
  composition). The 8.3 ms frame budget is an internal target; this machine has no ProMotion
  display, so the frame-rate-range question in 4.17 is recorded as untested until one is
  available.
- **M7 App shell.** `NSWindow` with native tabs, menu bar with `⌘` equivalents coexisting
  with chords, toolbar, sidebar (`NSOutlineView` file tree), editor-drawn tab strip and mode
  line, command palette panel, `NSPopover` hover and completion popups, SwiftUI settings,
  themes (Dracula default, Xcode, VS Code, light; colours from upstream sources as Reticle
  M107 did), fonts (JetBrains Mono default, Fira Code, SF Mono; bundled per M105),
  transparency with a faded, scalable background image, dark/light/auto. Its first step
  captures the design reference set (named screenshots of Xcode 26, Zed, Ghostty and iTerm2
  chrome into `doc/design-refs/`). Done when screenshots of each element are compared with
  that set in the record and the which-key HUD shows after a prefix key.
- **M8 Files.** Open, save with disk-change detection (Reticle M62), revert, autosave and
  backups, encodings, FSEvents and kqueue watching, recent files, a dired buffer plus the
  native tree, trash instead of delete. Done when the external-modification tests pass and
  a 100k-file tree's watcher costs nothing at idle.

- **M8b Editing command library.** The `interactive` machinery with every spec code, prefix
  arguments, the kill ring bridged to `NSPasteboard` (plus drag and drop and the Services
  menu), isearch, `occur`, query-replace, rectangles, registers, keyboard macros, narrowing
  and indirect buffers, `save-excursion`/`save-restriction`, undo commands, auto-save
  **recovery** and session/window restore, spell checking via `NSSpellChecker`, the kill/
  yank/transpose/case/fill family, and a counted command list taken from GNU's `simple.el`
  surface. Reticle needed its M6 plus two parity waves (M19-M23) plus M110 for this class;
  it gets its own milestone family here (M8b.1 movement and killing, M8b.2 search and
  replace, M8b.3 macros, registers, rectangles, M8b.4 recovery and restore). Done when each
  command has an oracle transcript and the count is published in the record.

**Milestone granularity.** Reticle's milestones were the size of one command (`kill-whole-
line` was M110). Each Phase A entry above is a *family* whose record splits it into numbered
sub-milestones (M1.1 rope, M1.2 summaries and conversions, M1.3 marker tree, M1.4 interval
tree, M1.5 undo; M5.1 buffers and faces, M5.2 keymaps and rich keys, M5.3 the run queue
and nested loop, M5.4 hooks and budgets, M5.5 minibuffer, M5.6 completion protocols, M5.7
processes and timers, M5.8 DisplaySnapshot and the headless driver; and so on), each with
one falsifiable definition of done, executed one at a time through the loop in `CLAUDE.md`.
The family list exists so the plan is readable; the sub-milestones are what get built.

**Gate A**: the owner can edit a real RTL file all day with no highlighting yet, the
owner's Reticle Elisp (22k lines) has a recorded migration inventory (what ports as-is,
what needs the tier-2 features of M15, what is retired because it is native now), and
nothing in the release protocol (4.14) regresses.

### Phase B: Verilog daily driver (M9-M14)

- **M9 tree-sitter and SystemVerilog.** The binding, background incremental parsing on
  snapshots, the SystemVerilog grammar and upstream queries, highlighting in Reticle's
  font-lock philosophy, the indentation engine (Reticle M36/M73/M90/M100 rules as the test
  list, verified against `verible-verilog-format`), folding, structural selection, electric
  pairs, rainbow depth. Done when highlight golden images match on `demo/rtl`, indentation
  matches verible on the fixture set, and reparse after a keystroke is under 5 ms on a 20k-
  line file.
- **M10 LSP.** Transport and JSON on a background actor, policy in Elisp, the probe tool
  ported, both Verilog servers attached with the per-method routing table and merged
  diagnostics, diagnostics gutter/squiggles/inline rows, completion popup, hover, definition,
  references, rename with ground-truth checks, formatting on save with selectable style
  (Reticle M104), server supervision with restart. Done when the recorded probe transcripts
  for both servers are in the repo and the e2e tests pass against the real binaries.
- **M11 Project, index and search.** Workspace model, the SQLite project index built from
  tags queries, quick-open with fuzzy scoring, ripgrep project search into an editable results
  buffer, xref backends, breadcrumbs and outline, bookmarks and jump list. Done when a
  synthetic 100k-file tree indexes in the background without touching idle CPU, quick-open
  answers in under 50 ms and the wgrep write-through tests (Reticle M83) pass.
- **M12 Verilog killer features, wave 1.** AUTOINST/AUTOWIRE/AUTOARG/AUTO_TEMPLATE ported to
  the new engine, then the rest of the AUTO family and instance arrays; instantiation
  completion for modules, ports and parameters; cross-file jump for modules, interfaces,
  packages, classes and programs from the index; `.f` filelists with `+incdir+`, `+define+`,
  `-y` and `verible.filelist`, explicit project root, coverage warnings; hierarchy browser.
  Done when Reticle's `demo_smoke_tests` claims hold on the new editor and each new AUTO
  directive has oracle fixtures from GNU verilog-mode's own documentation.
- **M13 Terminal.** PTY, VT parser, scrollback as buffer text with SGR properties and OSC
  133 overlays, alt-screen overlay (after the SwiftTerm-vs-own spike), the three input modes
  with mode-line indication, OSC 7/8, images, bracketed paste, mouse, kitty keyboard
  protocol, `M-!`/`M-&`/`M-|`, `shell-command`, `compile`, comint, a scrollback cap and an
  output coalescing window. Done when the vttest subset and the program acceptance list
  (vim, htop, tmux, less, fzf) pass, a 100 MB flood loses no data, keeps RSS bounded and the
  UI responsive at a stated sustained MB/s (dropping frames under flood is correct), and
  jump-to-error works on a `make` run inside the pane.
- **M14 Build, lint, simulate.** `compile`/`next-error` with the error-format table and
  budgets, lint on save (verilator, slang, verible lint), iverilog and verilator runs,
  waveform hand-off to surfer/gtkwave, run configurations. Done when every format has a
  fixture and the budget test proves a pathological line cannot stall the editor.

**Gate B**: the owner switches from Reticle for RTL work. The release protocol runs and its
numbers are recorded as the baseline.

### Phase C: Elisp library, org to full GTD, git, killer features (M15-M20)

- **M15 Elisp library and packages.** Tier-2 features (syntax tables and `syntax-ppss`,
  `define-derived-mode`, `cl-lib` with `gv`, `seq`, `map`, `pcase`, `subr-x`, `nadvice`,
  `use-package`, `propertize`), the package manifest and manager with lazy activation, AOT
  compilation and the post-init snapshot, the diagnostics panel replacing warning buffers,
  and language packs for Swift (sourcekit-lsp), Python (basedpyright), C/C++ (clangd), Perl
  (PerlNavigator), Tcl (tclint; grammar TBD), Bash; the servers not yet on this machine
  (basedpyright, PerlNavigator, tclint) are installed and probed as the first step. Done
  when the tier-2 conformance suite
  passes, a Purcell-style init loads with no errors, and each language pack highlights,
  indents and completes on a fixture.
- **M16 org, outliner.** Skeleton parser, folding as a display transform, TODO sequences,
  priorities, tags with inheritance, lists and checkboxes with statistics, timestamps,
  fontification. Done when the corpus round-trips byte-identical and the element tree matches
  the oracle's `org-element-parse-buffer` on it after a stated normalisation (drop `:parent`
  back-references, compare positions as offsets, ignore `:post-blank` where the spec allows).
- **M17 org, structure.** Deep parsing of sections, property drawers, tables with alignment
  and simple `#+TBLFM` arithmetic, links with a type registry, footnotes, planning lines with
  repeaters. Same oracle gate.
- **M18 org, GTD.** The SQLite org index, agenda views with custom agenda commands,
  capture templates, refile with path completion, archiving, clocking, effort and habits,
  column view. Done when agenda over 1,000 files opens in under 100 ms without opening a
  buffer and a scripted GTD day (capture → refile → schedule → clock → archive) matches GNU
  org's file output on the same inputs.
- **M19 git.** Status hub, hunk and line staging, commit buffer, log, blame, diff with
  word-level highlights, branches and remotes, stash, interactive rebase, transient menus.
  Done when a scripted repository walkthrough matches Magit's observable results and the
  partial-hunk staging edge cases have fixtures.
- **M20 Killer-feature core.** which-key HUD (M7 started it), avy-style label jumps, the
  undo-tree visualiser, multiple cursors at the input loop, expand-region on tree-sitter
  (Reticle M101), linked regions for snippets, iedit and LSP rename, the evil layer ported
  from Reticle's `evil.el` design, workspaces, declarative popup placement, a dashboard.
  Done when each of the ten week-one items (`doc/research/emacs-killer-features.md` section
  4) has a scripted driver session under `dev/drivers/` whose screenshots are in the record.

### Phase D: stability, extensibility, org completion (M21-M25)

- **M21 Stability and energy wave.** MetricKit, signposts, the watchdog, the soak harness,
  the benchmark suite (fontify 20k-line `.sv`, 10k keystrokes through hook chains, org agenda
  on 1,000 files, search on 100k files) compared with Emacs 30.2, the release protocol
  scripted (the instrumentation itself has existed since M0; this wave adds the harnesses
  and the numbers). Done when the 24-hour soak passes and the JIT gate measurement is
  recorded (share of time in VM dispatch; if ≥20%, M29 becomes a JIT milestone, otherwise it
  is retired). The owner signed off on this reading of requirement R5 on 2026-09-05 and
  asked that decisions of this kind be made without asking again.
- **M22 Extension tiers.** The Wasm host (WasmKit, wasmtime escape hatch), the XPC host, the
  native module ABI, capability prompts, three example extensions (a theme, a language pack,
  a Wasm completion source). Done when an extension that loops forever or allocates without
  bound is contained and reported without a dropped frame.
- **M23 org, babel and export.** Source-block execution and tangling, noweb, multi-
  language babel (shell, Python, Elisp first), export to HTML and Markdown, LaTeX/PDF when a
  TeX toolchain is present. Done when GNU org's own babel and export test corpus subset
  produces identical output.
- **M24 org, polish and backlinks.** org-modern-style rendering, inline images and LaTeX
  previews as attributes, org-roam-style backlinks and a graph view on the index. Golden
  images.
- **M25 Debugging.** DAP client, lldb-dap and debugpy, breakpoints, variables, watch, inline
  values. Done on fixtures for Swift, C++ and Python.

### Phase E: breadth (M26-M31)

- **M26 Remote editing.** An SSH-multiplexed remote agent protocol, async by construction,
  remote LSP and terminal (VS Code Remote's model; Reticle's M75-M77 save-safety rules as the
  test list).
- **M27 AI.** ACP client, MCP, inline completion, on-device model tasks, per-project network
  opt-in.
- **M28 Verilog, wave 2.** UVM class hierarchy, factory and phase awareness with snippets,
  SVA authoring aids, signal driver/load tracing via slang, an embedded waveform pane
  (license decision recorded).
- **M29 Workers and the JIT gate.** Reticle's worker-process design for parallel user Elisp;
  a regex JIT or a baseline ARM64 JIT only if M21's measurement demanded it.
- **M30 Language breadth wave.** Second pass over Swift, Python, C/C++, Perl, Tcl/Tk with
  the same rigour as Verilog got: per-language indent engines verified against the
  language's own formatter, DAP where an adapter exists, test-runner integration, and a
  demo corpus in each language.
- **M31 Distribution.** Sparkle updates, notarization pipeline, documentation, the demo
  corpus (Reticle's `demo/` conventions: every claim run, one directory per role).

---

## 9. Not in v1 (recorded so it is not rediscovered as new)

Mac App Store distribution; a TUI or CLI editor mode; running unmodified GNU packages;
`emacs-module.h` compatibility; TRAMP methods beyond SSH; multi-frame TTY semantics; the
full Calc formula language in tables (arithmetic, references and `vsum`-class functions are
in; symbolic Calc is not); mobile org sync; Tcl debugging;
collaboration (the rope's transaction log keeps a CRDT possible later, but the marker
tree is not a CRDT and nothing here retains deleted text); Windows or Linux.

---

## 10. Critique disposition (2026-09-05)

An adversarial review by an architect agent (five lenses: Swift engine, Apple platform,
Emacs semantics, terminal, delivery) produced 26 findings against the first draft. Each is
listed with its disposition; the accepted ones are already folded into the sections above.

| # | Finding | Disposition |
|---|---|---|
| 1 | Zed-style anchors had no fragment history to resolve against | accepted: replaced by a persistent marker tree (4.5); M1 DoD names it |
| 2 | Editor objects as ARC handles holding Lisp values recreate Reticle's boundary cycle leaks | accepted: editor objects are heap objects with Swift side tables; M2 cycle torture test (4.6) |
| 3 | A viewport-dependent DisplayMap built on the Elisp actor re-couples paint to Elisp | accepted: viewport-independent DisplaySnapshot, visual lines derived on the UI side (4.3); M6 scroll-while-busy DoD |
| 4 | Synchronous minibuffer/`accept-process-output` cannot be built on a bare SerialExecutor | accepted: explicit run queue with a nestable loop, designed in M5 (4.3) |
| 5 | No owner for specpdl/current buffer across `await` and cooperative threads | accepted: `LispContext` saved at every yield point; compiler rejects `await` inside a special `let` (4.3) |
| 6 | No milestone delivers the editing command set; Gate A unreachable | accepted: M8b family; missing primitives added to tier 1 (5) |
| 7 | Milestones ~4x too coarse compared with Reticle's record | accepted: families with numbered sub-milestones (8) |
| 8 | Hardened runtime blocks `dlopen` of foreign dylibs without `disable-library-validation` | accepted: entitlement and a `dlopen` self-test in M0 (4.1, 8) |
| 9 | The display is 60 Hz, not ProMotion; 120 Hz DoDs unverifiable here | accepted: "native refresh, no dropped frames"; ProMotion questions recorded as untested (2, 8, 4.14) |
| 10 | M3's gate compared against a wrong Reticle number the tree-walker already beats | accepted: absolute 0.5 s target; Reticle's measured 2.55 s recorded (2, 8) |
| 11 | M2's textual round-trip DoD is impossible (`?\C-x` prints as 24) | accepted: structural read→print→read equality (8) |
| 12 | Hook quarantine over-generalised beyond Reticle's exemptions; change hooks must never be quarantined | accepted verbatim (4.3) |
| 13 | "GC only at safepoints" contradicts allocation in builtins | accepted: allocation may collect; every builtin roots intermediates; torture collects on every allocation (4.6, 8) |
| 14 | Terminal "no dropped frame at 100 MB" is the wrong DoD; `forkpty` unsafe in a multithreaded Swift process | accepted: data-loss/RSS/responsiveness DoD, scrollback cap, `posix_spawn` (4.10, 8) |
| 15 | `presentsWithTransaction` on the scroll path serialises CPU and GPU | accepted: live resize only, measured in the M6 spike (4.4) |
| 16 | Compiled functions must keep `interactive` form, arity, docstring (Reticle M7) | accepted: M3 test (4.6, 8) |
| 17 | "Doom configs run" overclaims; six load-bearing primitives missing from tiers | accepted: "config idioms" wording; primitives added (1, 5) |
| 18 | Shipped Elisp derived from GNU's GPLv3 files would set the app's licence | accepted: clean-room rule, GNU as oracle only (5, `CLAUDE.md`) |
| 19 | IME composition swallowing chords; `NSAccessibilityStaticText` is read-only | accepted: M6 DoD names the text-area AX surface and the chord-during-composition rule (8) |
| 20 | ExtensionKit extensions are sandboxed and ship inside installed apps | accepted: tier 3 split into 3a/3b with the delivery constraint (4.9) |
| 21 | Stability instrumentation lands six milestones after the owner is asked to daily-drive; soak durations disagree | accepted: MetricKit, signposts, watchdog in M0; 8 h routine / 24 h release (8, 4.14) |
| 22 | Deferring the JIT changes requirement R5 without the owner's sign-off | accepted; the owner signed off on 2026-09-05 (8, M21) |
| 23 | `package` access alone does not give cross-module optimisation | accepted, then re-settled by the M0 benchmark: not `-package-cmo`, which the driver silently drops, but `public` + `@inlinable` on a small member, held by `dev/check-inlining.sh` (4.2, 11) |
| 24 | Factual drift in "verified facts": report count, display, subr count, parser state count | accepted and corrected (2, 4.10, 5) |
| 25 | Several DoDs unverifiable (design references, week-one demo, org tree equality, uninstalled servers) | accepted: reference-set capture, driver sessions, normalisation spec, install-and-probe steps (8) |
| 26 | Missing: clipboard/drag-and-drop/Services, crash and auto-save recovery, session restore, spell check, CI, Reticle Elisp migration | accepted: M8b, `dev/ci.sh` in M0, migration inventory in Gate A (8) |

Claims the review attacked and could not break, kept as-is: the 22-special-form census;
marker arithmetic under the anchor wrapper; the `BufferSnapshot` types typecheck as
`Sendable` (and the recursive `Node` enum needs no `indirect`, so spike 3's indirect-enum
penalty does not apply); `CADisplayLink.preferredFrameRateRange` exists on macOS 14+; the
MAP_JIT entitlement rule and self-test; rope over gap buffer; one Elisp thread over
actor-per-buffer; own VT parser; git CLI over libgit2; dual-server Verilog routing by
probe; org's lossless hand-written parser; errors as return codes across the boundary;
App Nap via activity assertions; no App Store.


---

## 11. Milestone records

### M0 Repository and gate — done 2026-09-06

Split into M0.1 (package skeleton, gate, the cross-module study) and M0.2 (app bundle,
hardened-runtime self-test, telemetry, screenshot driver), per the granularity rule in
section 8.

**Definition of done, as actually run by the main conversation:**

| Check | Result |
|---|---|
| `dev/gate.sh` | `Test run with 20 tests in 9 suites passed`; `all stages passed` |
| `dev/check-inlining.sh` | `hot text=0 lisp=0` (want 0), `cold text=1 lisp=1` (want >0) |
| `dev/make-app-bundle.sh` | assembled, ad-hoc signed with `--options runtime` + entitlements |
| `--self-test` **from inside the signed bundle** | `PASS MAP_JIT`, `PASS dlopen`, exit 0 |
| `codesign --verify --strict` | `valid on disk`, `satisfies its Designated Requirement` |
| `dev/gui-shot.sh` | 1200x832 native window, title `swiftemacs`, empty content view |

**The entitlements are load-bearing, and that was falsified rather than assumed.** The
bundle was copied three times and each copy re-signed with a reduced entitlements plist:

| Entitlements carried | MAP_JIT | dlopen | exit |
|---|---|---|---|
| allow-jit + disable-library-validation | PASS | PASS | 0 |
| disable-library-validation only | FAIL, `errno=22 (Invalid argument)` | PASS | 1 |
| allow-jit only | PASS | FAIL, `different Team IDs` | 1 |
| neither | FAIL | FAIL | 1 |

Each check fails exactly when its own entitlement is withheld, and only then. Note for
future readers: the *unbundled* `.build/release/pellicle --self-test` also prints two
PASSes and proves nothing — `codesign -dv` shows `adhoc,linker-signed` with no hardened
runtime, so neither restriction is being enforced there. Only the bundle
(`adhoc,runtime`, `Runtime Version=26.5.0`) is the real test.

**The cross-module optimisation question was reopened and settled the other way.** The plan
said M0 would prove `-package-cmo` works. It does not work as the plan assumed, and the
first measurement of it was wrong in a way worth recording:

1. `swiftc -package-cmo` and `-allow-non-resilient-access` appear in `swiftc -help` and are
   accepted without error, but the driver **never forwards them to the frontend**
   (`swiftc -v` shows only `-package-name`; the emitted `.swiftmodule` is byte-identical
   with and without them). They take effect only as `-Xfrontend -package-cmo -Xfrontend
   -allow-non-resilient-access`, and only alongside `-enable-library-evolution`.
2. With all three, the cross-module `package` call is inlined. But `@inlinable` on a member
   of a **`public`** type reaches the same speed with **no flags at all** (0.0135 s vs
   0.0133 s over 100M iterations), so the flags buy no peak performance — only the ability
   to keep the hot surface at `package` visibility. Library evolution *without* CMO is a
   5.6x cliff on that same shape (0.0135 → 0.0762 s), so option A's floor is worse than
   doing nothing while its ceiling is identical.
3. `@inlinable` on a member of a `package` type does nothing without those flags. The
   convention in `CLAUDE.md` said the opposite and has been corrected: it is the *type*
   that gets promoted, not the member.

Decision and its rationale are in 4.2 and 4.16; `dev/check-inlining.sh` is the standing
regression test. The `Lisp → Text` dependency edge was added here too, resolving a
contradiction the study surfaced between 4.6 (the regex engine scans the rope's chunks) and
4.2 (which gave `Lisp` no way to name a rope type).

**Review and mutation.** A cold review produced twelve findings; three were real defects —
`dev/check-inlining.sh` picking its object file non-deterministically between the debug and
release trees, a `close()` race in `MainActorWatchdog` that could leave the thread running
forever while `isRunning` reported `false`, and a `.unsafeFlags` linker setting
contradicting the "no unsafeFlags" rule stated in the same commit. All eleven actioned
findings were fixed and the checklist was executed by the main conversation, never by the
implementer. Nine of eleven mutations were killed. Three results are worth carrying
forward:

- **`@inlinable` does not oblige the optimiser to inline.** Deleting `@inlinable` from the
  probe originally changed nothing, because at ~5 statements a `public` cross-module call
  is inlined either way. Measured band on this machine: 4 statements → inlined annotated or
  not; 8-16 → inlined only when annotated; 24+ → never. The probes were lengthened to 12
  statements, inside the band, and `dev/check-inlining.sh` now counts each probe body and
  refuses to run if either has left it. **Consequence for the design: promoted hot members
  must stay small** — which is what the promoted surface in 4.2 already consists of.
- **A defence whose only observer is a tautology is not covered.** Three teardown tests
  asserted `isRunning == false` after `close()`, which is true the instant `close()` sets
  `closed` whether or not the thread ever exits — exactly how the race stayed invisible.
  They now assert on `isThreadAlive`, which reports the thread's physical state.
- **`CFRunLoopStop` in `close()` is not mutation-observable** and is recorded as such
  rather than pretended: `timer.invalidate()` runs first and `RunLoop.run()` returns once
  its last timer is gone, so the thread exits either way. The `dlopen` half of the
  self-test likewise has no `swift test`-level observer; the entitlement matrix above is
  its evidence.

**Cold-read coverage: four rounds, and the loop rule was rewritten during them.** Round 1
read the whole milestone (twelve findings, three real defects). Round 2 read the fix round
and the probe/watchdog changes made while running the mutation checklist (eight findings;
the best one in the milestone was that three teardown tests asserted `isRunning == false`,
which is true the instant `close()` sets `closed` whether or not the thread ever exits —
exactly the mechanism by which the `close()` race had stayed invisible. One of its eight
was itself mistaken: it said `CLAUDE.md` does not claim "no unsafeFlags", which the same
commit's `CLAUDE.md` does say. Reviewers are refuted the same way as anyone else.)

Acting on round 2 produced a fourth batch which, under the old "one trailing round, no
recursion" rule, would have shipped unread: the three teardown tests switched to
`isThreadAlive`; `dev/check-inlining.sh` gained a probe body-length guard and had its
object-file lookup reimplemented from `find` to a shell glob (the substantive part of that
lookup — constrain to the release tree, error on more than one match — was in the fix round
and round 2 had read it; only the mechanism changed here); `MetricsSubscriber`'s counters
became lock-taking accessors; and the parallel statement-count constant was deleted in
favour of the check in the script. **That batch was
not harmless.** The new guard's first version averaged the two probe bodies, so a
mutation that shortened only the hot one survived it — caught because the main conversation
happened to run that mutation, by no review at all. `CLAUDE.md` step 7 now requires rounds
until the trailing diff is empty, anchored on the git index rather than on the coordinator's
memory.

That mutation is the only evidence cited for changing the loop rule, so it is recorded as a
recipe rather than as a memory: the buggy draft was never committed, and a later reviewer
looking for it found nothing either way. From this tree — replace the per-body `awk` counter
in `dev/check-inlining.sh` with `statements=$(grep -c '^        v = (v ' "$probe")` and
`per_body=$((statements / 2))`, dropping the `hot_n`/`cold_n` equality check with it, then
delete eight mixing statements from `TextHotProbe.packedByteLength` only, leaving
`TextColdProbe` at twelve. The averaged guard prints `8 mixing statements per body (band is
8-16)`, the symbol check still passes (`hot text=0 lisp=0 | cold text=1 lisp=1`, because a
four-statement body is inlined with or without the annotation), and the script exits 0.
Restore the per-body counter and the same mutation exits 1 with `Sources/Text/
InliningProbe.swift's hot body has 4 mixing statements`. Re-measured 2026-09-06, after the
milestone was committed and prompted by the question of which working artifacts were worth
keeping: the answer was none of them, because a claim worth keeping should be reproducible
from the tree instead. A cold reader then ran this recipe in a throwaway copy of the tree
and reproduced both directions with the quoted strings matching byte for byte. It declined
one point, recorded here: the recipe does not spell out that the band-range loop over
`hot_n`/`cold_n` has to be collapsed along with the counter, so it is not literally
guess-free — though it judged the guess forced and reproduced the exact output on its first
attempt.

Round 3 read that batch and found no correctness defect. Its two open items:

- *The lock added to `MetricsSubscriber`'s counters is not observable by any test* — true,
  and now said so in `Sources/Platform/Metrics.swift` rather than left implied. Every caller
  is single-threaded, so the value is the same either way; what is observable is the
  counting, and deleting either increment fails `MetricsTests`.
- *`Thread.sleep` in the tests' `expectThreadGone` helper might starve Swift Testing's
  cooperative pool under `--parallel`* — the reviewer recorded it unresolved after three
  attempts to settle it by reading. Settled here by measurement instead: ten consecutive
  full parallel runs (0.707-0.729 s, 20/20 tests each) and twelve filtered
  `MainActorWatchdogTests` runs (0.717-0.727 s, 6/6 each). No starvation, no flakiness; the
  retry loop almost always exits on its first read, which is what the timings say. Per
  `CLAUDE.md`, "flaky" needs an observation, and there is none.

Round 4 read the batch that produced (a doc comment and these two records) and blocked the
commit over a factual error in it: the incident note then said the unread batch had changed
`dev/gate.sh`'s verdict, which is false — that change was in the fix round and round 2 had
read it. Corrected above and in `CLAUDE.md`. It also found a sentence duplicated by a bad
edit, and four rule-quality gaps that were adopted: persist the review boundary in the git
index, rerun the gate before re-reviewing a batch that touched product code, state the
"decline and record" exit symmetrically so the loop cannot be churned by wording
disagreements, and tell reviewers plainly that "nothing to change" is what ends it.

Rounds 5 and 6 closed it. Round 5 blocked on a second misattribution of the same species
as round 4's — the record claimed the unreviewed batch had changed the object-file lookup in
`dev/check-inlining.sh` "from a `find` over all of `.build` to an explicit release glob",
when the substantive half of that lookup was in the fix round and round 2 had read it. Two
such errors in a row, both overstating what went unreviewed, is a pattern worth naming: a
coordinator writing its own history from memory drifts toward the more dramatic version, and
the artifacts (`git cat-file` on the pre-review blob, the reviewed diff, the current file)
are the oracle. Round 5 also closed two gaps in the new rule: `Tests/` was missing from the
list of directories whose modification requires rerunning the gate before re-review — which
contradicted the same step's rejection of an "it was only tests" exemption — and the
git-index anchor had no warning that staging anything for an unrelated reason while a round
is out silently moves files into "already read".

Round 6 found no factual error and declined to push two true-but-imprecise phrasings:
`PLAN.md`'s gloss calling `Tests/` "product code", and `CLAUDE.md`'s "the one way to break
this silently is to `git add`", which is true in this project's workflow but not literally
exhaustive (`git rm`, `git mv`, `git reset` would do it too, and none is ever prescribed
here). It also noted, outside the diff's scope, that `dev/check-inlining.sh`'s glob
`.build/*/release/...` requires exactly one path segment where the `find` it replaced would
also have matched `.build/release/...`; on this toolchain only the former exists, and if
SwiftPM's layout ever changes the glob stays unexpanded and the script's `[ ! -f "$OBJ" ]`
guard fails loudly rather than silently picking the wrong object. All three are recorded
here rather than acted on.

Round 7 read the base case itself and found no factual error. It declined two
wording-precision points, transcribed here as the loop's terminator: that the base case's
closing clause voids the exemption "the moment it makes any new claim about *the code*",
which is narrower than what it guards against (a smuggled claim about process or tooling
would not be "the code" under a hyper-literal reading) — though it observed the exemption is
scoped to record entries, so anything else falls back to the default rule regardless; and
that step 7's "do not proceed to step 8 while an unreviewed change exists" is not
cross-referenced to the base case sitting just above it, so a reader could momentarily
read a record-only edit as forbidden. Neither was acted on, which is what ends the loop —
seven rounds, and the last three found nothing that changed a line of code.

Two methodology notes for later milestones. Swift Testing's `--filter` matches the *type*
name, not the `@Suite` display name: a filter that matches nothing yields "Test run with 0
tests ... passed" and exit 0, which reads exactly like a surviving mutation — the mutation
runner must assert that tests actually ran, and `dev/gate.sh` now rejects a zero-test run.
And test seams must be per-instance: two hooks added to `MainActorWatchdog` were first
written as statics, and because Swift Testing runs suites in parallel every other test's
watchdog parked in them.

**Known gaps carried forward.** `versionString()` in `Sources/App` has no test target.
Does not block anything.

*Amended 2026-09-07:* the icon gap this section recorded is closed early, out of milestone
order, at the owner's request; see the icon record below.

### M1.1 Rope -- done 2026-09-08

The persistent B+-tree rope of 4.5: `TextSummary` (the monoid), `Chunk` (up to 64 bytes of
UTF-8 stored inline), `SumTree` (generic over `Item: Summable`, because M1.4's interval tree
is its second instance), `Rope` (byte-indexed, value-semantic, `Sendable`, O(1) snapshot by
struct copy). Gate: `Test run with 64 tests in 13 suites passed`, all stages.

**Deviations from 4.5's sketch.** `TextSummary` carries a seventh field, `scalars` (Unicode
scalars == Emacs character positions); the sketch lists only utf8/utf16/lines/firstLineLen/
lastLineLen/maxLineLen, but Emacs buffer positions count characters, not UTF-16 units, so M5
needs it and adding it later would mean recomputing every leaf summary in the project.
`Chunk` caches its own summary packed into seven `UInt8`s (stride 65 -> 72); storing a
`TextSummary` instead was measured and takes stride to 128 through alignment padding.

**`B = 6` is now measured rather than inherited from Zed.** A rebuild copies a whole node, so
cost per level grows linearly in `B` while levels fall only as `1/log B`; the rebuild cost is
`~2B*log_B(n)`, minimised analytically near `B = e` and empirically at 4-6. Single-byte
insert into 1 MB at B = 2/4/6/8/12/16/32: 64/108/128/218/270/617/2008 us. A scan-heavy
workload (whole-buffer iteration, tree-sitter feeding) would argue the other way, so re-run
the sweep with an iteration benchmark before ever changing it.

**Performance.** `isScalarBoundary` went 23-29 us -> **0.39 us** on a 1 MB rope once it was
rewritten onto a read-only descent (`SumTree.find`) that allocates, copies and rebuilds
nothing. The *edit* path is unchanged and a single-byte insert into 1 MB still costs ~115 us:
`splitNode`/`cutNode` call `buildFromNodes` at every level of the descent and
`buildFromNodes` folds `concat` across up to `B+1` siblings, so they are O(B*h^2), not the
O(log n) the original doc comments claimed. That is **M1.1b**, designed and not started: a
path-copy edit (descend once, rebuild the `h+1` nodes on the path, propagate a sibling only
on overflow), prototyped by the architect review at **1.5 us**, with a `Fragment` +
`TreeBuilder` n-ary join for edits that genuinely span leaves. The obstruction that looked
fatal -- a per-level group of `k < B` nodes cannot become a well-formed node -- dissolves if
underfull is representable only as a transient *argument* to the join and never as a stored
node, which leaves `checkInvariants()`'s assertions exactly as they are. Its hard half is
deletion's underflow repair (borrow-from-sibling or merge-with-sibling per level).

## What five reviews and three mutation passes found after the gate was already green

Every defect below was found *after* `dev/gate.sh` passed. That is the point of the loop.

1. **The property tests were degenerate -- the worst defect, and one no gate could show.**
   The delete and replace cases drew a range between two independent uniform boundaries,
   removing ~n/3 per operation against inserts of ~2.4 bytes at 2-in-5 frequency, so the size
   random walk collapsed. Measured over the model's exact trajectory: the rope reached a
   **maximum of 49 bytes**, averaged 9, and spent 57% of operations under ten bytes; its root
   height never exceeded 0, so every `checkTreeInvariants()` call in the default suite ran
   against a single leaf. Section 8's headline M1 condition -- property tests over 1,000,000
   random edits -- performed essentially all of them on a rope of about nine bytes.
   **The rule this earns: a randomised test must assert its own non-degeneracy, or it reports
   success for free.** A size *cap* was specified and delivered; nobody asked what the
   distribution actually did.
2. **Fixing that produced two more of the same defect, in new shapes.** First a floor guard
   was added, which stopped the collapse but pinned the walk to its floor (excursion of 46
   bytes across a nominal 56 KB band) and cost the randomised suite all small-rope coverage,
   flipping it from "only tests tiny ropes" to "only tests large ones". Then the replacement
   non-degeneracy assertions were **tautologies**: `minModelSize` was initialised before the
   loop and only ever decreased, so it could never exceed `initialSize` -- `minModelSize <=
   8192 + 32` was unconditionally true for a band whose floor *was* 8192, and would have
   passed even if the floor guard were broken. Both were caught by cold reviewers, not by me.
   The settled form is two bands (a small one with no floor, 0-512 bytes, that visits the
   empty rope and the height 0->1 transition; a large one, 8-64 KB, that reaches height 2)
   and an **oscillation** property -- the minimum observed *after* the maximum was reached
   must fall to at most half of it. That one is falsifiable and was falsified: reverting the
   tuning fails it with "min size after max 47471 did not fall to at most half of max 53971".
3. **`rewrap`'s rebalancing overflow branch was live code no test reached.** Instrumented: 0
   hits across the whole `sumTreeTests` suite, 0 across the randomised model test, 286 inside
   the fragmentation guard -- which never called `checkInvariants()`. It is reachable (171
   hits across 3,000 rounds of random `append`/`insert` of randomly-*sized* ropes) and the
   checker does catch corruption there, but every existing test concatenated only equal-sized
   or single-item trees. Now covered by a deterministic test that reaches the branch in one
   operation and a randomised one that reaches it by volume.
4. **Invariant-check cadence is load-bearing, measured.** Because the `concat`-everywhere
   rebuild re-folds neighbours, a malformed node is *self-healing* -- it survives ~0.26
   operations. With `rewrap` mutated to split `1/rest`: checking after every one of 20,000
   inserts catches 80 violations, every 50 ops catches 2, every 1,000 ops catches **0**. A
   mutation checklist that says "run the model test" reports a false pass. The default tier
   now checks after every operation, which is most of why it costs ~17 s.
5. **`find` had zero coverage after being added.** Two mutations proved it: `findNode`
   returning the post-item prefix, and `Rope.locate`'s predicate off by one, both survived the
   entire suite. `find` had one call site, `locate` had one caller, and that caller
   (`isScalarBoundary`, public API) was never called by any test.
6. **`checkInvariants()` had no negative test.** Mutations deleting its leaf lower-bound check
   and its empty-leaf check both survived. Everything trusted the checker; nothing checked it.
7. **Three doc comments asserted false things.** `split`/`cut`/`concat` were documented "all
   O(log n)" when they are O(B*h^2); `Rope.locate` claimed "never materialising the preceding
   chunks" while rebuilding both sides; and `MemoryLayout<Node<Chunk>>.stride` was documented
   as 24 when it is 72. **That last number came from the main conversation's own verification
   probe**, which used `Int` as the summary type instead of the real 56-byte `TextSummary`,
   and travelled from the spec into a code comment. *A fact checked against a simplified
   stand-in is not a checked fact.*
8. **A benchmark harness without `-wmo` is not measuring the shipping configuration.** The
   main conversation's first numbers were 2-3x pessimistic: `swift build -c release` passes
   `-whole-module-optimization` and `swiftc -O` alone does not, and `dev/spikes/RESULTS.md:30`
   had already recorded `-O -wmo` as the protocol. Worse, **`swift test` builds in debug**, so
   the perf suite's original numbers measured unoptimised code entirely. The perf tier is now
   gated on release as well as on `PELLICLE_PERF`.
9. **A ratio assertion alone is the wrong shape for a performance test.** `scalingRatio`
   asserted only that per-edit cost across three decades of `n` grew by less than 8x. It
   passed comfortably at 3.7x while every operation was ~100x too slow, because the cost was
   dominated by a size-independent constant -- **a uniformly slow implementation has an
   excellent ratio.** It now carries an absolute floor too. The same trap recurred one level
   up when the band bar was set to exactly the value the walk reached (32768 against a bar of
   32768, a pass by zero bytes); the bar is now 24 KB, and its comment states what it does and
   does not prove rather than being tuned a third time.

**Defences that cannot be observed, recorded rather than faked** (CLAUDE.md's rule). Removing
`concatNodes`'s empty short-circuit changes no result -- it is a performance guard, not a
correctness one. Loosening `packChunks`'s backoff floor changes nothing for valid UTF-8, since
a non-final chunk is always exactly 64 bytes wide before backoff and a scalar is at most 4.
`checkInvariants`'s empty-leaf check is strictly subsumed by its lower-bound check. `locate`'s
`>` vs `>=` is indistinguishable *through `isScalarBoundary`*, which filters both endpoints
before calling it -- though the two genuinely diverge at `byteOffset == utf8Count`, so the
equivalence belongs to the caller, not the predicate. The `cutNode` and `findNode`
preconditions cannot be reached by any current caller. Note for future mutation work: those
two preconditions make "force the predicate true to manufacture a non-nil result" an unusable
technique against either function's interior recursion -- it crashes the process instead of
failing a test.

**Declined, with reasons.** The edit-path rewrite is deferred to M1.1b rather than folded in
here, so that the test defences above landed *before* the rewrite that will stress them -- the
architect's staging, and the reason the `rewrap` coverage exists at all. The 24 KB bar is
cleared by a single 20,000-byte paste in ~98% of runs and so evidences an excursion rather
than a traversal; it was kept and documented rather than re-tuned, because a bar picked until
it barely passes is the defect this sub-milestone is about.

**Known gaps.** `Rope(String)` for 1 MB takes ~11 ms (~91 MB/s) because `SumTree.build` halves
recursively through `concat`; a 10 MB file would spend 110 ms in construction before anything
else happens, so M1.2 wants a bottom-up bulk loader. No character/UTF-16/line conversion API
(M1.2), no marker tree (M1.3), no interval tree (M1.4), no undo (M1.5), no line-indexed mmap
view for huge read-only files.

---

## Icon, 2026-09-07 (out of milestone order, at the owner's request)

**The mark.** A lowercase lambda -- Emacs Lisp -- inside Lisp parentheses, its right leg
swept into a tapered wing tip for Swift. Background gradient Swift orange `#ff7a33` to
Emacs purple, brightened, `#9a6be6`. GNU Emacs 30.2's own icon is a purple family running
`#211f46` to `#d3d2e8`, its body carried by `#7e55b3` and `#5b2a85`
(`grep -oiE '#[0-9a-f]{6}' /opt/homebrew/Cellar/emacs-plus@30/30.2/share/emacs/30.2/etc/
images/icons/hicolor/scalable/apps/emacs.svg | sort | uniq -c`); the stop shipped here is
brighter than those two, and deliberately so. The *dark* appearance was first rendered at
128 px with `#7c4dbe` -- the value `icon.json` carried at that point, recoverable only from
this record -- and the lower half of the glyph was too dim to read,
because Icon Composer's dark treatment darkens the background to near-black and moves the
gradient onto the glyph -- so the darkest stop, which carries the most contrast against a
light background, lands on the least against a dark one.

**Files.** `assets/icon/pellicle.icon` is the Icon Composer package: hand-authored
`icon.json` (two-group layering, so the parentheses and the glyph get separate glass,
shadow and parallax) plus two generated layer SVGs. `dev/gen-icon.py` generates those and
`assets/icon/pellicle-flat.svg`, a flat single file for docs and the web, reading the
gradient back out of `icon.json` so the two cannot drift. `dev/make-app-bundle.sh` needed
no change beyond its comments -- its conditional actool step was written in M0 for exactly
this artwork and compiled it unmodified.

**Why the geometry is generated.** actool takes only a subset of SVG and Reticle's
`Reticle.icon` artwork is likewise fill-only, so every stroke has to ship as an explicit
filled outline; hand-maintaining several hundred outline points is not on, a dozen
centreline control points and a width profile is. Round terminals are emitted as arcs, and
subpaths are normalised to counter-clockwise because the nonzero fill rule unions
overlapping subpaths only when they wind the same way.

**Three things the pixels decided, none of which reading the file would have.**

1. The first draft ran the lambda's tail collinear with its right leg. At 256 px it read as
   an "A". The tail is now its own, shallower stroke breaking about 30 degrees off the leg.
2. The layers were first `"fill": "automatic"`, as Reticle's are. That renders the glyph as
   dark glass on the gradient; `{"solid": "srgb:1,1,1,1"}` -- white -- is markedly bolder at
   64 px, which is the size that decides whether a Dock icon works.
3. The parentheses at half-width 26 with a shallow bulge read as straight sticks; 31 with a
   deeper bulge reads as parentheses.

**actool constraint, quoted.** A three-stop gradient makes actool throw
`-[__NSPlaceholderArray initWithObjects:count:]: attempt to insert nil object` with the real
cause printed above the backtrace: `Linear gradients require exactly 2 colors`. Recorded in
`dev/make-app-bundle.sh` next to the actool invocation. A relative path to the `.icon`
package also failed, with `The file “swiftemacs.icon” couldn’t be opened because there is
no such file` above a path that had the relative one appended to the package's own
(`.../assets/icon/swiftemacs.icon/assets/icon/swiftemacs.icon`) -- the project's name at
the time, left as the tool printed it. That is the observation,
not a mechanism: a cold reviewer could not reproduce it cleanly and left it unresolved, and
neither could a later attempt from inside the package directory, which compiled normally.
It does not reach the shipped code either way -- `ROOT` at `dev/make-app-bundle.sh:51` is
absolute and `mktemp -d` returns absolute paths.

**Verification.** Pixels, per the third oracle: `dev/make-app-bundle.sh` then the rendered
bundle icon at 512, 128 and 48 px in the system's dark appearance, and actool's own `.icns`
output at 256 and 64 px for the light one. The clearance between the lambda and the
parentheses and the content bounding box are printed by `dev/gen-icon.py` (currently
32.28 px and 67% x 68% of the canvas) rather than eyeballed. That distance is between
vertices of the 240-sample outlines, so it is an upper bound on the true curve-to-curve
distance and is named as one in the script. `dev/gate.sh` is unaffected -- nothing here
compiles -- but was run.

**Not done.** No `.icns` or `.ico` is checked in (actool emits the `.icns` at build time,
and there is no Windows target), and there is no golden-image test over the icon: nothing
in `dev/gate.sh` would notice if the artwork changed. The renditions are checked by hand,
by rendering them.

*Amended 2026-09-07 by the dark-appearance record below.* This paragraph was moved here
from the end of this section and reworded; it used to end "and no rendering of the tinted
or clear appearances, which were taken on trust from the format", and that had stopped
being true.

**Review.** One round, cold, on the staged diff. It found no correctness defect and seven
smaller things; six were acted on and are in the trailing batch: the clearance metric
subsampled 1-in-4 vertices, which can only overstate the margin, and now runs over every
pair (0.19 s in total, and the number it prints is unchanged at two decimal places from the
reviewer's independent full-resolution measurement); the ribbon's normal fell back to
dividing by 1.0 at a degenerate central difference, yielding the zero vector and a pinched
outline rather than a direction, and now carries the previous normal, seeded arbitrarily at
the first sample (no centreline here comes close -- the smallest central difference across
all five is 0.435); `ccw()`'s
nonzero-union guarantee holds only while each ribbon is simple, now said in both
docstrings; a three-stop `icon.json` failed with a bare `too many values to unpack` and now
fails naming the actool limit, before anything is written; and the two PLAN.md claims
amended above. Declined, with the reason, per the loop's terminating rule:

- *Nothing checks that the checked-in SVGs are current with the generator, so a hand-edit
  to `icon.json` or to a curve constant would silently drift them.* True, and the reviewer
  confirmed there is no drift today by regenerating and diffing. Declined: the artwork is a
  one-off asset, `dev/gate.sh` is the definition of done for code that compiles, and adding
  an asset-freshness stage to it is a change to the project's gate that this task did not
  ask for. The generator is deterministic and takes 0.19 s; re-running it is the check.

Round 2 read that batch, 161 lines over `dev/gen-icon.py` and this file. It found one real
defect and four smaller ones, all acted on. The real one: round 1's fix that was supposed
to put the self-overlap caveat in the module docstring **never landed** -- the `replace`
that carried it silently matched nothing, because the target text wrapped across lines
differently than it had been typed, so `ccw()`'s docstring pointed at a caveat that did not
exist and this record claimed it was "said in both docstrings" when it was said in one. The
others: the newly-added `#7c4dbe` was as uncited as the claim round 1 had objected to;
citing only `#7e55b3`, `#5b2a85` and `#a52ecb` was selective, since the same file carries
lighter purples than the shipped stop, so "brighter than any of them" only survived on a
narrow reading; "carries the last good normal" is wrong for a run of degenerate leading
samples, which would carry the seed; and "five were acted on" undercounted six. Round 2
also disclosed that it executed two of its own designed mutations rather than only
designing them, in an rsync copy outside the repository -- its numbers for the first
(32.27994 full-resolution against 32.43144 subsampled) reproduce what is printed here.

Round 3 read that batch, 96 lines over the same two files, and reported nothing to change.
It reproduced every number the record quotes, recomputed the offset-curve margin the new
caveat asserts (radius of curvature minus half-width, worst case +124.6 on the tail), and
noted one thing it decided not to flag: the `grep` line above wraps inside a Markdown code
span, so a reader copying the *rendered* text gets a broken path -- it found the same
pattern already at nine other places in this file and took it as the document's convention
rather than something this change introduced. Declined here for that reason. This entry
transcribes that round; it is the loop's terminator, not a new batch.

---

## Icon, dark appearance, 2026-09-07

The owner opened the icon in the Dock, saw the dark appearance -- near-black background,
gradient glyph -- and said they preferred the orange one. This makes the icon render the
same in both appearances, and supersedes three statements in the record above: the package
is no longer two groups with separate glass and parallax, it no longer has `lambda.svg` and
`parens.svg` as separate layers, and the layers no longer carry a white `fill`.

**What Icon Composer 1.6 (Xcode 26.6) does not let you author.** The dark appearance's
background is not derived from the authored colours at all: it is a fixed neutral ramp,
gray-gamma-22 white 0.192 to 0.078, which `ictool --export-intermediate-representation`
shows as its own `Gradient-2` in the emitted `.xcassets`. There is no per-appearance
override in this version. The `fill-specializations` key that later versions use appears in
`IconComposerFoundation`'s strings but is not read: giving each candidate key a garbage
string and seeing which ones make the decoder throw shows the top level reads only `fill`,
`groups`, `supported-platforms`, `color-space-for-untagged-svg-colors`, `features`,
`languages` and `implicit-asset-mirroring`. Under `ictool`, `groups: "GARBAGE-STRING"`
fails with *The data couldn’t be read because it isn’t in the correct format* while
`fill-specializations: "GARBAGE-STRING"` renders normally; under `actool --compile` on a
copy of the package, the same two give `rc=1`, no `Assets.car`, *Exception while running
actool: -[__NSPlaceholderArray initWithObjects:count:]: attempt to insert nil object* and
`rc=0` with an `Assets.car`. Every `features` value tried was rejected as being from a
newer version. Two cold reviewers reproduced the `ictool` half exactly and neither could
test the `actool` half at all: in both environments `actool` exited 0 and emitted nothing,
with no diagnostic, for all three variants including the unmodified control. Whatever that
is, it is not the package. Re-run before relying on the `actool` half.

**What does survive into the dark appearance is a layer's own artwork** -- but only if it is
the *only* layer. Any layer beyond one is composited as glass there, at a fill opacity low
enough that a white glyph over a bright background disappears; at 48 px, the Dock size, the
mark was gone. That is measured against the alternatives, all rendered at 220 px and
compared to the unchanged version: translucency off moves 18/255 at most, `blend-mode` and
`lighting` move nothing at all, `glass: false` makes it worse (87/255, and visibly thinner),
a duplicated layer stack moves 12/255, a stronger or layer-coloured shadow 12 and 50. Only
the fill colour moves it (199/255) -- a dark glyph reads, a white one does not -- and that
is not the mark the owner picked. It also makes no difference whether the colour comes from
the layer `fill` or from the SVG's own paint.

**So the icon is one layer containing everything**, `Assets/whole.svg`, which the dark
appearance leaves alone. Default and Dark now differ by a mean of 0.94/255 (max 44 on 7.9%
of pixels, the icon-level specular). The cost is the per-layer parallax and specular the
first record described; the alternative was an icon whose glyph vanished in the Dock. The
tinted and clear renditions still work -- they were rendered and checked, not assumed.

**Two things this needed that only pixels could have told us.**

1. *Colour space.* `color-space-for-untagged-svg-colors` accepts no value but `display-p3`
   (`srgb`, `sRGB`, `s-rgb`, `extended-srgb`, `p3`, `auto` and five more are all rejected
   outright), so untagged SVG hex is Display P3 and writing sRGB hex there shifted the
   render by up to 64/255. A flat-colour probe settles the direction exactly: a document
   fill of `srgb:#ff7a33` renders as P3 `#ee8246`, while an SVG `#ff7a33` renders as
   `#ff7a33`. `dev/gen-icon.py` therefore converts, and the document `fill` stays the sRGB
   authoring source for both it and the flat file. Its conversion gives `#ee8146`, one
   step of green off what Icon Composer renders for the tagged fill; a cold reviewer
   cross-checked the matrices against macOS ColorSync (`sips -m "Display P3.icc"`) and got
   the generator's value, so the odd one out is Icon Composer's own rounding. It is the
   whole of the 1/255 quoted below.
2. *Gradient span.* The document `fill` runs its gradient across the icon *shape*; a layer's
   own gradient runs across the *canvas*, and the macOS shape is the middle 80% of it. A
   black-to-white ramp rendered both ways at 512 px reads 0.1874/0.4998/0.8120 at
   y=128/256/384 for the fill and 0.2496/0.4998/0.7495 for the layer -- spans of exactly
   512*0.8 and 512. The layer's gradient is pinned to the shape's box with
   `gradientUnits="userSpaceOnUse"`, after which the background matches the previous
   version to 1/255 at both ends.

**Review.** One round, cold. No correctness defect in the code. It reproduced independently
the two decoder probes, the `display-p3` rejections (adding that even `display-P3` and
`DisplayP3` are rejected -- only the exact spelling works), the fixed dark ramp's 0.192 and
0.078, the shape's 80% span, the Default-to-Dark statistics, and the matrices; the three
amendments above are its three findings. What it did not reach, and this is a real gap in
the record's support: the rejected-alternative measurements that justify the single-layer
design (translucency 18/255, `glass: false` 87/255, and the rest) were each a separate
`icon.json` variant and it did not rebuild them, so they rest on the main conversation's
runs alone. It also flagged that every mutation it could design for this change is
invisible to `dev/gate.sh` -- there is no test anywhere under `Tests/` that references the
icon -- which the "Not done" note above already says.

Round 2 read the amendments and found no incorrect fact in their technical claims, though
two in their bookkeeping, below; it reproduced the `ictool`
probes, `p3_hex_of()`'s output, the ColorSync cross-check, and the `display-P3`/`DisplayP3`
rejections, and went one step further than the text by rendering the *purple* stop's tagged
fill too -- `#936ddf`, an exact match to the generator, so the top stop's single step of
green really is the whole residual. It hit the same `actool` wall as round 1, which is why
the paragraph above now says two reviewers did. Its two findings were about this record and
are fixed here: the `*Amended*` marker said the paragraph it marks had been "rewritten in
place" when it had been moved, and it had been wedged mid-paragraph, taking a sentence of
**Verification** with it; and the `ictool` message was quoted with straight apostrophes
where the tool prints curly ones, which in a file whose rule is that oracle output is
quoted so the next reader can check it is worth getting right.

Round 3 found no incorrect fact in that batch and reproduced all four of its claims,
including the purple stop's `#936ddf` by both routes. Two of its three remaining notes are
recorded rather than acted on. Its methodology caveat: Icon Composer lays a faint grain
over even a flat fill, so a *single-pixel* sample of that purple probe reads `#936cdf`, one
low, and the exact value comes back only from a mean or mode over a block -- worth knowing
before anyone spot-checks these hex values and thinks they have caught something. Declined
as wording: that this paragraph names **Verification** in bold where a nearby line quotes
"Not done" instead. Acted on, because it is the same class of slip round 2 caught and this
session has the output: the `actool` quotation in "actool constraint, quoted" above had
straight quotes and a straight apostrophe where actool printed curly ones.

Round 4 read that batch and reported nothing to change. It reproduced the grain caveat
exactly -- single pixel `#936cdf`, block mean and mode `#936ddf`, the same channel and the
same direction -- and codepoint-checked the corrected quotation against the already-correct
sibling message in this record. It hit the `actool` wall a third time, and adds one thing
about it worth keeping: the relative-path behaviour is stateful, not a function of the path
given, since two invocations from two different directories both echoed the *repository's*
absolute prefix. It left one wording disagreement, recorded and not acted on: this
paragraph says round 3 "reproduced all four of its claims, including the purple stop's
`#936ddf`", while round 2's paragraph frames that same check as going one step further than
the four it lists, so whether the purple stop is the fourth or a fifth is ambiguous on a
cold read. This entry transcribes that round; it is the loop's terminator, not a new batch.

**The README's image**, `assets/icon/pellicle-256.png`, is a render, not artwork:
`ictool ... --rendition Default --width 256 --height 256 --scale 1` against the package.
`dev/gen-icon.py` does not produce it; regenerate it with that command if the mark changes.

**Verification.** All six macOS renditions through `ictool --export-image`, plus the signed
bundle's icon as macOS renders it at 512 and 48 px in the system's dark appearance.
`ictool` lives inside `Icon Composer.app/Contents/Executables/` and is what `actool` shells
out to for a `.icon` package; it is a far better pixel oracle than assembling a bundle, and
it is what the next person should reach for.

---

## Documentation sweep, 2026-09-07

The owner's rule, in their words: an error you do not fix now is one you forget, and it
stays. So every repository path `CLAUDE.md` names was extracted and checked against the
tree, and the plan sections were checked against their own M0 record. Eight things were
wrong and are fixed:

- **Three tools `CLAUDE.md` tells you to run do not exist here**: `dev/lsp-probe.py` (which
  it even described as "ported from Reticle"), `dev/gui-drive.sh`, and `dev/mutate.py`,
  which a fixed clause for task specs also named. All three are in `~/My_Projects/reticle/
  dev/`; none has been ported. `CLAUDE.md` now says so, names the file to port and the
  milestone that needs it, and describes mutation the way M0 actually did it -- by hand,
  with a file backup, a targeted edit and `touch`.
- **`xcodebuild` is invoked by no script here**, though `CLAUDE.md` said it was used by
  `dev/make-app-bundle.sh`. That script calls `actool` and nothing else from Xcode. This
  one had already propagated into `README.md` by being copied from `CLAUDE.md`.
- **Two plan entries were contradicted by their own M0 record** and had been standing next
  to it since: the M0 milestone's "`-package-cmo` proven on one cross-module hot call" and
  "`dev/ci.sh` (the gate plus golden images and the short energy checks)", and decision-log
  row 23's resolution. Corrected in place with an `*Amended*` note.
- `README.md`'s dependency rule said "a dependency" where `CLAUDE.md` says "a SwiftPM
  dependency".

Two cold rounds. The first cleared seven of the eight but found the amendment on the M0
entry had been wedged into the middle of the bullet, leaving the false text standing a few
lines below it -- so the entry contradicted itself, while the same batch fixed the same
fact by direct rewrite in the risk table. It also found "M6 or M7" for `gui-drive.sh` was a
guess where the sibling fix stated M10 from the plan. Both fixed; the second round found
nothing to change and declined to file its one observation (that `dev/ci.sh`'s parenthetical
now overlaps the bullet's own fuller mentions, which the bullet already did before). This
entry transcribes that round; it is the loop's terminator, not a new batch.

Left alone deliberately: `lisp/`, `Sources/Lisp/Builtins/` and `Tests/CanvasTests/Golden/`
are named by `CLAUDE.md` as conventions for where things go when they exist, not as things
to run, and their milestones have not happened.

---

## Renamed from swiftemacs to pellicle, 2026-09-07

**Why.** The owner asked whether the icon or the name carried infringement risk. The icon
does not; the name did.

- **Copyright, and Taiwan's reproduction offence specifically.** `著作權法` Art. 91 punishes
  one who "擅自以重製之方法侵害他人之著作財產權" -- up to three years, or six months to five
  years where there is intent to sell. The offence needs a work that was reproduced, and
  there is none: the icon's geometry is Bezier control points chosen in `dev/gen-icon.py`,
  with no font outline, no tracing and no reference to any existing mark. Art. 9(3) puts
  "通用之符號" outside copyright altogether, which is what a lambda and a pair of brackets
  are, and Art. 10-1 limits protection to expression, not the idea of using a lambda for
  Lisp. GNU Emacs 30.2's own icon was rendered and compared: a purple disc with a white
  ribbon E, sharing nothing with this mark but the existence of purple.
- **The name was the real exposure.** `Swift®` is on Apple's published trademark list as
  "software technology", and Apple's third-party guidelines say: "You may not use or
  register, in whole or in part, Apple, iPod, iTunes, Macintosh, iMac, **or any other Apple
  trademark**...as or as part of a company name, trade name, product name, or service
  name except as specifically noted in these guidelines." The only carve-out is "Mac", and
  only for products that are not computers or operating-system software. `swiftemacs` used
  the mark in a product name in Apple's own field, developer software, which is where a
  confusion argument is strongest. Apple has tolerated SwiftLint and its kin, but tolerance
  is not permission, and those are libraries rather than a signed, distributed application.
- **`Emacs` was not the problem.** The FSF's registered marks are FSF, Free Software
  Foundation and GNU; Emacs does not appear among them, and XEmacs, Aquamacs, Spacemacs and
  Doom Emacs have coexisted for years. (Secondary source: the FSF's own trademark page
  returned 404.)
- Valve holds an EU trademark on the lowercase lambda, scoped to downloadable game
  software. Different class, and its mark is a bare orange lambda where this one is a white
  lambda inside parentheses on a gradient. Recorded as known, not as a blocker.

**The name.** A pellicle is the thin transparent membrane suspended above a photomask,
keeping particles out of the focal plane so that defects do not print. It continues
Reticle's lithography vocabulary without reusing its name, it is the layer that sits *on* a
reticle, and "the layer that keeps defects out of the product" is what this project's cold
reads, gates and oracles are for. GitHub has no project of consequence by that name.

**What changed.** Every occurrence, 298 of `swiftemacs` plus nine `SWIFTEMACS` environment
variables and one `SwiftEmacs`: the executable and product name, the bundle identifier
(`app.swiftemacs` to `app.pellicle`), the entitlements file, the icon package and its two
exports, the `pellicle_icache_invalidate` C shim symbol, `PELLICLE_WATCHDOG` and
`PELLICLE_SIGNPOSTS`, this file, `CLAUDE.md`, `README.md` and the research reports. Prose
still says the editor is written in Swift, which is the referential use Apple's own
guidelines permit. Verified after the rename: the gate green at 20 tests, the bundle built
and ad-hoc signed, both self-test entitlement checks passing under the hardened runtime,
and the icon regenerating byte-identical and rendering.

**Where the old name survives, and the rule for it.** A global replace rewrites history as
happily as it rewrites code, and a cold read caught it doing exactly that four times. The
rule applied: **the new name everywhere the text describes the project; the old name
wherever the text quotes something, cites a path that existed, or states a dated
observation.** So `swiftemacs` still stands in the actool error message this file quotes
verbatim, in the M0 done-table's observed window title (commit `88a319f` set
`window.title = "swiftemacs"`, so no other value was ever seen on 2026-09-06), in the
planning brief's scratch-path guard, and in two research reports' citations of scratch
paths that really existed under that name. The same read caught fourteen possessives that
the replace had broken: `swiftemacs'` is correct for a name ending in *s*, `pellicle's` is
not, and the apostrophe had been left bare.

*Round 2 of the cold read found nothing to change.* It re-derived the window title from
`88a319f`, diffed the restored quotation and all three path citations byte-for-byte against
the pre-rename `HEAD`, counted the fourteen possessives in the diff, and swept the tree in
both directions -- nothing left unrestored, nothing restored that was describing the project
rather than quoting it. Its one observation is recorded and not acted on: the list above
groups the two research reports' path citations as one item, so it reads as four categories
where another reading would say three files. This entry transcribes that round; it is the
loop's terminator, not a new batch.

**The sweep afterwards, and what it covered**, so nobody has to redo it wondering whether
the rename was complete. A cold read refuted the first version of this paragraph,
finding six things wrong with it, which is recorded here because the errors were of the
kind a sweep is most likely to make -- undercounting what it found and overstating how
clean the result was.

- **Tracked files**: fourteen `swiftemacs` remain, each on the historical side of the rule
  above. **Three** of them are references to the old *directory*, not one as this paragraph
  first said: the planning brief's scratch-path guard and two research reports' citations of
  scratchpad paths. That count was already stated correctly earlier in this section, and
  the first version contradicted it.
- **Case variants**: one `SwiftEmacs` and one `SWIFTEMACS`, both inside this record
  describing what was replaced.
- **Untracked and ignored files**: `.build`, which is regenerated, and a root `.DS_Store`,
  which `strings` shows carries nothing. Nothing else.
- **Binary files**, read with `strings`: clean, the icon PNG included.
- **`.git/config`**: the remote points at the renamed repository, and GitHub 301-redirects
  the old URL.
- **Outside the repository**: `~/.claude`'s `settings.json`, agent definitions and hooks
  name nothing from this project. The global `CLAUDE.md` does still say `swiftemacs` once,
  in a dated note -- "2026-09-06 實測（swiftemacs M0）" -- which is a dated observation and
  stays by the same rule; the first version of this paragraph said only that no *path*
  survived there, which was true but read as more than it meant.
- **The per-project memory directory** exists under the new name with its five files, and
  there is no memory directory left under the old name -- it moved whole. What does still
  exist under the old name is the *session* directory beside it: this session keeps the
  identity it started with, so its transcript goes on being written there.
- **macOS's Launch Services database** held six distinct bundle registrations for
  `app.swiftemacs` (24 string hits, four per record -- the first version reported the raw
  grep count as though it were the number of entries). Five of them were throwaway `.app`
  copies this session left in its scratchpad while investigating the dark appearance, and
  they still existed, so "its paths no longer exist" was false for the majority. They have
  been unregistered and deleted. One registration remains, for
  `.build/swiftemacs.app`, whose path is genuinely gone; that entry is an OS cache outside
  this repository and prunes itself, and rebuilding the whole database for it would be a
  machine-wide operation for something that disappears on its own.

*Round 3 found nothing to change.* It re-derived the six from the two patches, placed the
earlier statement of the count, checked that no memory directory survives under the old
name while the session directory beside it does, and re-ran the counts this batch did not
touch to see whether the edits had invalidated a neighbour -- they had not. Its one
observation is recorded and not acted on: the sentence above calls the first version's
errors "undercounting what it found and overstating how clean the result was", and one of
the six fits neither, since reporting a raw `grep -c` of 24 as an entry count inflated the
mess rather than hid it. That is a characterisation, not a claim about the machine. This
entry transcribes that round; it is the loop's terminator, not a new batch.

**Not settled here.** Whether a mark is confusingly similar is a lawyer's judgement and not
one this record can make. What it can record is that the specific, documented conflict --
an Apple registered mark used as part of a product name in Apple's own field -- is gone.

---

## Swift formatting, 2026-09-07

`dev/gate.sh` lints `Sources` and `Tests` with `swift format lint --strict` on every run,
so those cannot drift and running the formatter over them changed nothing. Six Swift files
sit outside that: `Package.swift` and `dev/gui-shot.swift`, both already clean, and the four
`dev/spikes/spike_*.swift`, which had never been linted. Those four are now formatted.

**The formatter is Apple's `swift format` (6.3.0), not Nick Lockwood's SwiftFormat**, which
is a different tool with different rules and is not installed here. Running that one instead
would likely produce code the gate then rejects.

**The spikes changed more than whitespace.** Five rules did it, and each preserves meaning:
`DoNotUseSemicolons`, `UseLetInEveryBoundCaseVariable` (`case let .cons(car, cdr)` becoming
`case .cons(let car, let cdr)`), `OneVariableDeclarationPerLine`, `OneCasePerLine` (one
`case a, b, c` split per enum) and `OrderedImports`. Four more are whitespace only:
`Indentation`, `LineLength`, `AddLines`, `Spacing`. All four files still pass
`swiftc -typecheck` before and after, and `RESULTS.md` cites no line numbers into them, so
the measurements it records stand -- taken, it should be said, against the pre-format text.

**This paragraph used to quote a hit count per rule. It does not any more, and that is the
most useful thing in this section.** Three cold rounds each found the counts wrong, in a
different way every time. The first version named two rules because it read the diff instead
of listing them. The second listed them, but against copies in a `mktemp` directory --
`swift format` finds `.swift-format` by walking up from the *file* it is linting, so a copy
outside the tree silently gets the tool's defaults, and three of the four whitespace rules
change count between two-space and four-space indent. The third deduplicated nothing:
`swift format lint` emits the same diagnostic repeatedly for `DoNotUseSemicolons` and
`UseLetInEveryBoundCaseVariable`, so a raw `grep -c` reports 189 and 44 where the distinct
sites are 55 and 37. Nothing depended on any of those numbers. A count in a record that no
decision rests on is not evidence, it is a standing opportunity to be wrong -- which rules
fired, and that each is meaning-preserving, is the whole of what a reader needs. The two
lessons that generalise are worth more than the counts were: lint a scratch copy with
`--configuration` or you are measuring a different codebase, and de-duplicate before
counting anything this tool prints.

**What the formatter did not fix**: fifteen `AlwaysUseLowerCamelCase` diagnostics and one
`NoBlockComments`, none of which it auto-applies. `spike_interp.swift` has twelve -- ten
constants, the function `L`, and the block comment, so they are not all naming;
`spike_repr.swift` has three constants and `spike_jit.swift` one function.

**And the reason first given for leaving `sys_icache_invalidate` alone was wrong.** This
record said renaming it would break the file. It would not: the binding is the string in
`@_silgen_name("sys_icache_invalidate")`, not the Swift identifier, so renaming the function
while leaving the string typechecks -- checked, after a cold reviewer refuted the claim. The
real reason is the general one, that `swift format`'s naming rules are lint-only and it
performs no cross-reference rename. Left standing here because a wrong specific reason is
worse than none: it would talk a future reader out of a cleanup that is actually safe.

**Nothing in the test suite would notice** if an edit to a spike changed its behaviour. They
are standalone scripts outside `Package.swift`'s targets and outside `swift test`'s reach.
That is a gap, stated rather than papered over.

Extending the gate to cover these four was **not attempted**, and this record deliberately
does not prescribe how. Two earlier versions of this paragraph did, and cold reads refuted
both: the first said `swift format` has no path-scoped configuration, when a nested
`.swift-format` does govern the files beneath it; the second recommended that route and
understated it badly. What is measured, and all this record should claim:

- A nested `.swift-format` **replaces** the parent, it does not merge. It therefore drops
  back to the tool's default indent width unless it restates it, which instantly conflicts
  with files formatted to this project's four spaces.
- Worse, and silently: the moment a configuration declares any `rules` key at all, **every
  rule it does not list is off**. A nested file disabling two rules disables the rest too --
  `DoNotUseSemicolons` goes from firing to not firing with no diagnostic to say so. The root
  `.swift-format` here declares no `rules` key, so it gets the tool's defaults; a child
  cannot partially override that.
- The alternative is `// swift-format-ignore: RuleName`. **Do not reason about its scope
  from anything written here or anywhere else -- measure it.** Five attempts in this record
  to state how it scopes were each refuted by the next cold read: that it does not attach to
  statements, that it does, that declarations and statements differ, a false aside about
  these files being top-level scripts, and that the reach follows the rule rather than the
  position. Three observations survive, and they are observations, not a rule -- both the
  rule named and where the comment sits change the answer, and they interact differently for
  each rule:
    - `AlwaysUseLowerCamelCase`, comment above a declaration: silences that declaration
      only, whether or not it is the first thing in its block.
    - `NoBlockComments`, comment above the block comment: silences it, wherever in the block
      it sits.
    - `OneVariableDeclarationPerLine`, comment above the block's *first* statement: silences
      every such declaration in the block. Put one ordinary statement before it and the
      comment silences nothing at all, not even the line directly beneath it.

  So check both directions after using one: that the diagnostic you meant to silence is
  gone, and that the ones you did not mean to silence still fire.

Whoever does it should derive the recipe themselves against the tool and test that the
gate is still enforcing what it enforced before. Nothing edits a finished spike, so there
is no hurry.

**This section cost eleven cold-read rounds, and that is the record's most useful line.**
Every round found something real, so the loop was not spinning; what kept failing was the
writing. Nine of the eleven were spent on two things nobody needed: per-rule hit counts, and
an explanation of a mechanism for work that was never done. Each was fixed by deleting it
rather than by getting it right on the next try. The general form, for whoever writes the
next record: *a claim that no decision depends on is not evidence, it is a standing
opportunity to be wrong* -- and a mechanism you have not built is exactly that kind of
claim. The final round found nothing to change; its predecessor's one open item, that "do
not reason about its scope from anything written here" sits oddly beside three scope
observations, is recorded and not acted on -- the sentence after it already says they are
observations and not a rule.

---

## Handover: state after M0, 2026-09-06

- `git init` done; two commits per milestone as `CLAUDE.md` prescribes. M0 is built and its
  record is in section 11.
- Next work item: **M1.1b**, the rope's edit path (path-copy plus a `Fragment`/`TreeBuilder`
  n-ary join), designed in the M1.1 record above and not started; then M1.2 onward, one sub-
  milestone at a time through the loop in `CLAUDE.md`. *(This line said "M1.1 rope" until
  2026-09-08; M1.1 is done and its record is in section 11.)*
- The owner asked that the implementation sessions run on **opus** (the planning session
  ran on Fable and was judged too expensive) and that "which approach" decisions be made
  without asking.
- Open owner-independent questions live in 4.17 and are settled by the spikes named there,
  starting with the M6 display-link spike; nothing in M1-M5 depends on them.
- The cross-module convention that M1 must follow is in 4.2: default `package` and cold;
  promote a *type* to `public` with `@inlinable` members only where a benchmark shows the
  boundary is hot, keep those members small, and let `dev/check-inlining.sh` hold the line.
