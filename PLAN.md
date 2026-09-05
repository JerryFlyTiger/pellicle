# swiftemacs Development Plan

An Emacs-style editor for macOS, written in Swift on Apple's frameworks, with a built-in
Emacs Lisp engine, designed from the ground up to remove GNU Emacs's structural pain
points. It is the successor to Reticle (`~/My_Projects/reticle`, Rust, 110 milestones):
Reticle proved the Verilog feature set and the process; swiftemacs replaces the parts of
Reticle that its own README lists as limitations (fixed character-grid GUI, synchronous
remote I/O, non-rebindable minibuffer, `Rc` cycle leaks, no runtime grammars, no headless
rendering) and adds the things the owner asked for that Reticle could not host (a native
macOS shell, a real terminal, GPU rendering, a plugin ecosystem).

**Positioning (owner, 2026-09-05):** swiftemacs is the macOS, Swift rewrite of Reticle and
of Emacs, but it must not be Reticle with a new coat: where Reticle is a Verilog editor,
swiftemacs is positioned as a **multi-language editor with complete org-mode support**.
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
   narrowly. Reticle took the same stance and it held for 110 milestones. swiftemacs runs
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

| Root decision in GNU Emacs | Pain it causes | swiftemacs decision that removes it |
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

SwiftPM package `swiftemacs`, Swift 6 language mode. `package` access is visibility only;
cross-module optimisation needs `-package-cmo` (present in this toolchain's `swiftc -help`)
or `@inlinable`/`@usableFromInline` on the hot paths, and M0 benchmarks one hot call across
the `Lisp`↔`Editor`↔`Text` boundary to prove the flag works. Dependencies point downward
only.

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
  Platform/            C shims (sys_icache_invalidate, MAP_JIT helpers, PTY ioctls),
                       FSEvents, process spawning with DispatchIO, energy/latency telemetry
lisp/                  the shipped Elisp library (simple, subr, modes, verilog, org glue)
queries/               tree-sitter .scm files, one directory per language
Tests/                 Swift Testing suites per module; golden-image tests for Canvas;
                       Elisp conformance tests run against GNU Emacs 30.2 output
dev/                   screenshot driver, LSP probe, mutation runner, benchmark suite,
                       app-bundle script, energy protocol scripts
```

Dependency direction: `App → Chrome → Canvas/Terminal → Editor → Text`, `Editor → Lisp`,
`Lang/Org/Git → Editor + Lisp`, `Extensions → Lisp + Editor + Platform`. `Lisp` and `Text`
depend on nothing above them and are testable in isolation; `Canvas` depends on `Text` (for
snapshots) and on the `DisplaySnapshot` type owned by `Editor`, never on `Lisp`.

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
- **Scope decision (owner, 2026-09-05)**: GNU org does complete GTD, so swiftemacs does
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

**Tier 3, never.** The `emacs-module.h` ABI (swiftemacs has its own module ABI); native-comp
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
  targets), `-package-cmo` proven on one cross-module hot call, `dev/gate.sh` (`swift format
  lint --strict`, `swift build`, `swift test`), `dev/ci.sh` (the gate plus golden images and
  the short energy checks, run on this machine; there is no remote CI), `dev/make-app-
  bundle.sh` (Info.plist, entitlements `allow-jit` + `disable-library-validation`, `.icon` +
  `.icns` per Reticle M98, codesign with hardened runtime), a launch-time self-test that
  exercises MAP_JIT and `dlopen`s a bundled test dylib, `MXMetricManager` subscription,
  `os_signpost` handles and the main-actor watchdog from day one, `CLAUDE.md`, `Tests` smoke
  test. Done when the gate is green, the `.app` launches an empty native window and the
  self-test passes under the hardened runtime.
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
| 23 | `package` access alone does not give cross-module optimisation | accepted: `-package-cmo` in M0 with a benchmark (4.2) |
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

## Handover: state after planning, 2026-09-05

- Nothing is built. The repository holds `PLAN.md`, `CLAUDE.md`, `doc/research/` (16
  reports + context), `dev/spikes/` (five spikes with `RESULTS.md`), `.gitignore`. No
  `git init` yet (the owner decides when).
- Next work item: **M0 Repository and gate** (section 8), then M1.1 onward, one sub-
  milestone at a time through the loop in `CLAUDE.md`.
- The owner asked that the implementation sessions run on **opus** (this planning session
  ran on Fable and was judged too expensive) and that "which approach" decisions be made
  without asking.
- Open owner-independent questions live in 4.17 and are settled by the spikes named there,
  starting with the M6 display-link spike; nothing in M0-M5 depends on them.
