# pellicle Development Plan

An Emacs-style editor for macOS, written in Swift on Apple's frameworks, with a built-in
Emacs Lisp engine, designed from the ground up to remove GNU Emacs's structural pain
points. It is the successor to Reticle (`~/My_Projects/reticle`, Rust, **124 milestones
completed as of 2026-09-08**):
Reticle proved the Verilog feature set and the process; pellicle replaces the parts of
Reticle that its own README lists as limitations (fixed character-grid GUI, synchronous
remote I/O, non-rebindable minibuffer, `Rc` cycle leaks, no runtime grammars, no headless
rendering) and adds the things the owner asked for that Reticle could not host (a native
macOS shell, a real terminal, GPU rendering, a plugin ecosystem).

*Corrected 2026-09-09:* the line above said "110 milestones" from this file's first commit
until today. **That number appears nowhere in Reticle's own files.** Reticle's `README.md:420`
claims 86 "as of 2026-09-01"; its `PLAN.md:3104` has since reached `## M124 --- SystemVerilog
interfaces, non-ANSI port lists, and class prototypes (completed 2026-09-08)`, so the README is
a stale snapshot its own plan has outrun by 38 milestones. Read Reticle's `PLAN.md`, not its
README, for that project's state. The two projects measured on the same day, 2026-09-09:

Both columns are measured **at a commit**, not in a working tree: Reticle at `da7f131`
("PLAN.md: M125 record" is `2c6d32e`; `da7f131` is M124, 2026-09-08), pellicle at `1010f56`.
The reason is in the provenance note below.

| | Reticle @ `da7f131` | pellicle @ `1010f56` |
|---|---|---|
| first -> last commit | 2026-07-20 -> 2026-09-08 (50 days) | 2026-09-05 -> 2026-09-08 (3 days) |
| commits | 322 | 26 |
| source | 112,384 lines of Rust, 146 files, 7 crates | 5,662 lines of Swift, 38 files, 12 modules (7 still placeholders) |
| tests | 2,327 `#[test]`, 88 test binaries, 47 `#[ignore]` | 97 `@Test`, 13 suites |
| milestones | M124 done; only M87 stages 4-5 outstanding | M0, M1.1, M1.1b of 33 families |

The milestone counts are **not comparable**: section 8's "Milestone granularity" note records
that Reticle's milestones were the size of one command (`kill-whole-line` was its M110, which
is probably where "110" came from), while a Phase A entry here is a family of sub-milestones.
Reticle's 124 is roughly this plan's *sub*-milestone grain. Lines per day are the same order
(2,248 against 1,887); the 20x gap in size is 50 days against 3.

*Provenance of that table, and the rule it produced.* Reticle is **not a static object to
measure**: it is under active development by the same owner, and it committed M125 on
2026-09-09 while this paragraph was being written. Three passes measured it that day and got
three different answers for the same two figures -- 112,384 lines / 2,327 `#[test]` (a survey
agent), 113,188 / 2,359 (the main conversation), 113,212 / 2,364 (a cold read) -- and the
middle two were **working-tree states that never existed as a commit**, caught mid-M125. The
main conversation used its own number to "correct" the survey's, and the correction was the
error: pinned to `da7f131`, the survey's figures reproduce exactly, and the same commands at
`2c6d32e` (M125) give 113,513 / 2,366. Only the crate count was genuinely wrong and stays
corrected at **7**: Reticle's root `Cargo.toml` carries its own `[package]` beside the six
`[workspace] members`.

**The rule: a number about another repository is quoted with the commit it was measured at, or
it is not quoted.** `CLAUDE.md`'s measurement protocol already says one process and absolute
bounds for benchmarks; this is the same discipline for counting, and it costs nothing --
`git ls-tree -r --name-only <sha>` piped through `git show` is as cheap as `wc -l` on the
working tree. "Re-run a second-hand number before believing it" is necessary but was not
sufficient here, because the re-run was itself unpinned. What did hold: 88 test binaries, 47
`#[ignore]`, 322 commits, 146 files and both cited anchors reproduced at every pass.

**Positioning (owner, 2026-09-05):** pellicle is the macOS, Swift rewrite of Reticle and
of Emacs, but it must not be Reticle with a new coat: where Reticle is a Verilog editor,
pellicle is positioned as a **multi-language editor with complete org-mode support**.
Verilog/SystemVerilog stays the first language and the proving ground, the other target
languages are first-class rather than afterthoughts, and org-mode is built to GNU org's full
feature level (agenda, capture, refile, clocking, babel, export, backlinks), not as a thin
outliner. Speed of delivery matters more than method: any technique that works is welcome.

*Amended 2026-09-09 (owner).* Two readings of that last sentence were tested against the owner
and one was wrong. "Method" means the **choice of technique** -- which library, whose design,
which route -- and it is unconstrained. It does **not** mean the working method in `CLAUDE.md`:
the owner values quality, and the review discipline (cold reads with no round cap, until the
trailing diff is empty) is not negotiable and is not to be traded for delivery speed.

Three further constraints from the same conversation:

- **Reticle is the benchmark, not just the predecessor: pellicle competes with it.** Its
  feature set and design decisions are there to be studied and beaten.
- **No code is copied, from Reticle or from anywhere.** Designs, feature lists and recorded
  measurements are legitimate references; source is not. Every line here is written fresh.
  (This already held for GNU's Elisp for a licence reason -- see "Licensing of the shipped
  Elisp" in section 5 -- and now holds for Reticle, which the owner owns, for a project
  reason.)
- **Zed, VS Code and JetBrains are equally legitimate references**, subject to one limit:
  pellicle stays an **Emacs-like editor** and does not drift into being one of them. The
  extension architecture in 4.9 is the place this matters most, because that is where GNU
  Emacs is the anti-pattern rather than the model (R4, R9).

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
| R4 | Plugin ecosystem like GNU Emacs in breadth, modelled on how **Zed**, VS Code and JetBrains isolate extensions so they cannot hurt performance. GNU Emacs's extension interaction is the anti-pattern: it is what makes a configured Emacs slow (owner, restated 2026-09-09) | hard constraint |
| R5 | Every expert technique for speed and energy: GPU rendering, JIT-class engine design | hard constraint |
| R6 | **No CLI/TUI.** The app is itself an iTerm2-class terminal, and also runs shell commands the Emacs way (`M-!`, `shell-command`, `compile`) | hard constraint |
| R7 | The killer features of world-class Emacs setups (Doom, Purcell, Prot, Karthink) | 1-3 by feature |
| R8 | Written in Swift, macOS only, leaning on Apple frameworks; study VS Code, JetBrains, Zed, Doom, Purcell and Reticle | hard constraint |
| R9 | The Elisp engine is **multi-process and multi-threaded**, so that the editor stays fast and no extension can drag it down (owner, stated 2026-09-05, recorded here 2026-09-09) | hard constraint |
| R10 | **Both key layers ship; evil is installed and on out of the box**, and a user who wants GNU Emacs's bindings turns it off in the config file. GNU's bindings are therefore not a sketch behind a more-used default -- they are the layer evil sits on, and they must be complete enough to edit with alone. Promoted out of the wish list by the owner on 2026-09-09 because it constrains how already-planned milestones are built rather than adding new ones. **Corrected the same day:** this row first said the reverse (GNU default, evil opt-in) and the owner reversed it. Two consequences to carry forward. **The evil layer (W1, M20) now sits on the default startup path**, so its load cost falls on every user rather than on the ones who opted in -- and this plan has no startup budget to hold it to: section 3 promises AOT compilation at install and a post-init snapshot for fast starts, but no milestone measures startup time and no number is named anywhere. R10 is what makes that gap load-bearing; a cold read caught an earlier version of this row citing a "startup budget" as though one existed. **And every GNU binding still needs its oracle transcript** -- M8b's definition of done already requires one per command -- because turning evil off has to land the user in a complete Emacs, not a stub | hard constraint |

Three consequences the owner should read before anything else:

1. **GNU Emacs packages are a porting target, not a runtime target.** Every one of the five
   root causes of Emacs's pain (section 3) is fixable only if the Elisp contract is defined
   narrowly. Reticle took the same stance and it held for 124 milestones. pellicle runs
   *its own* Elisp dialect: lexical by default, one dedicated interpreter thread, async
   primitives, rich key events. The **config idioms** of Doom/Purcell-style setups run
   (`use-package` forms, hooks, keymaps, `setq`/`setopt`, custom variables, mode hooks); a
   literal Doom config does not, because it drives a package manager and hundreds of
   third-party symbols. `magit.el` does not run, and does not need to, because git is
   native.
2. **R9 is met by isolation, not by a parallel Lisp heap, and the owner should know that.**
   Read R9's two halves separately, because the plan answers them differently. **The
   *interpreter* becomes multi-process only at M29**, which ports Reticle's proven worker-
   process design for parallel user Elisp; that is the one place Lisp code runs in more than
   one process. 4.9's tier 3a (LSP/DAP/JSON-RPC children, XPC helpers) and tier 3b
   (ExtensionKit `.appex`) are process isolation for *extensions*, and the code in those
   processes is mostly not Elisp -- they answer R4's "no extension can hurt performance", not
   "the Elisp engine is multi-process", and a cold read was right that running the two
   together reads like a bait-and-switch. Multi-*thread* is delivered everywhere except
   inside the interpreter: 4.3 puts the UI on the main thread, Elisp on its own dedicated
   pthread, and tree-sitter parsing, LSP transport, the project index, search, git and the
   file watcher on background actors, so "layout and paint never wait for Elisp" is literally
   true and M6's definition of done tests it. **Elisp bytecode itself runs on one thread**;
   `make-thread` is cooperative, as in GNU (section 5). 4.16 records "one Elisp thread" as a
   deliberate rejection of an actor per buffer, because `set-buffer` and
   `(with-current-buffer ...)` semantics assume a single current buffer and every config
   relies on it. What actually keeps extensions from hurting the editor is the mechanism in
   4.3 and 4.9: a deadline check every 64 VM instructions, `hook-time-budget` with three-
   strikes quarantine and echo-area attribution, out-of-band `C-g`, tier-2 Wasm under memory
   limits and fuel/epoch interruption, and tier-3 process boundaries. If the owner means
   Lisp bytecode literally executing on several threads at once, that reopens 4.16's row and
   rewrites M2's heap, M3's VM and M5's command loop; the cost is lowest now, before M2
   starts.
3. **The first visible Verilog feature is far away.** A Verilog editor needs a buffer, a
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
| `@inlinable` member of a **`@usableFromInline package`** type | **inlined** (see below) | -- | -- |

Three things follow. The promoted shape reaches the same peak with no flags as package CMO
does with them, so the flags buy no speed — only the ability to keep the hot surface at
`package` visibility. `@inlinable` on a member of a `package` type does nothing without
those flags, so it is the *type* that must be promoted, not the member (an earlier version
of `CLAUDE.md` got this wrong). And library evolution without CMO is a 5.6x cliff on the
promoted shape, so a design resting on package CMO rests on an optimiser pass whose
bail-outs are silent, with a worse floor than doing nothing. Rejected alternatives and the
falsification plan are in 4.16.

**Amended 2026-09-09 (M1.2), and it changes what "promoted" means.** The table's fourth row
was never measured, and it is the row that matters: **`@usableFromInline` on a `package` type
is a promotion.** With the hot members `@inlinable`, it is inlined across the boundary with no
flags, at the same speed as the `public` shape -- measured on M1.2's cursor at 3.49 ns/chunk
against `public`'s 3.56 -- and it changes **no public API surface**. Isolated on this
project's own probe harness: with `@usableFromInline` on the type the member's symbol is
absent from the calling module's object file; delete that one attribute and the undefined
symbol reappears, with the type's plain-`package` `init` keeping its symbol in both as the
control. So "promote the type" above is right and "the containing type becomes `public`" is
one remedy, not the only one, and not the one to reach for first: `Text` is not a package
product, so `public` serves no external client, forfeits the `package`-vs-`public` signal and
emits symbols dead-code stripping can no longer remove. **Default to `@usableFromInline
package`; reach for `public` only when something outside the package must call it.** The real
price is different from the one this paragraph used to imply: promotion drags stored
properties and helpers from `private` to `internal`, so what is traded away is module-internal
encapsulation, not API surface.

Two corollaries, both learned the expensive way in M1.2:

- **The promotion unit is the whole call chain the benchmark walks, not the entry point.**
  Promoting `SumTreeCursor.next()` while leaving `descendLeftmost`/`advanceToNextLeaf` merely
  visible recovered ~35% of the win (20.7 ns/chunk against 3.56). Those two run once per leaf,
  i.e. once per <= 6 chunks, and an opaque cross-module call there cost ~17 ns/chunk by itself.
- **A plain-`package` `@inlinable` is not merely ineffective, it is unchecked.** The compiler
  does not verify `@inlinable` bodies while the enclosing type is plain `package`. Adding
  `@usableFromInline` to `TextMetric` immediately produced six "`TextSummary` is package and
  cannot be referenced from an `@inlinable` function" errors against code that compiled
  silently before. Such an annotation therefore cannot even be trusted as a statement of
  intent, and accumulates references a later promotion cannot honour. Write it or do not, but
  do not leave it decorating a `package` type.

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
struct TextSummary { utf8, utf16, scalars, lines, firstLineLen, lastLineLen, maxLineLen } // monoid
enum Node<Item: Summable> { case leaf([Item], Summary); case interior([Node], Summary, height) }
final class TextBuffer { root: Node<Chunk>; overlays: Node<OverlayRecord>; history; clock }
struct BufferSnapshot: Sendable { root, overlays, clock }   // O(1) to take, free to share
// Built so far (M1.3, M1.4): `BufferSnapshot { text: Rope; markers: MarkerTree; intervals:
// IntervalTree }`, one edit funnel, no history and no clock until something reads one.
final class MarkerTree { /* order-statistics tree of marker positions with lazy offsets */ }
struct Anchor: Sendable, Hashable { markerID, bias }  // resolved against a snapshot's MarkerTree
```

**The complexity table.** M1's definition of done in section 8 says "complexity benchmarks
match the table in 4.5". Until 2026-09-09 there was no table -- only the O(...) claims woven
through the prose below, which made that criterion unauditable. Here it is, with where each
claim is verified. "Measured" means a benchmark in the tree asserts it; the rest are promises
the milestone that implements them owes. One row -- chunk streaming -- is **not** a tidying-up
of the prose below, which never promised it: it enters the table from `dev/specs/m1.2.md`
deliverable C, because M1.2 built the primitive and it now has a cost worth holding. A cold
read caught the table claiming otherwise about itself.

| Operation | Promised | Owner | Status |
|---|---|---|---|
| Take a snapshot | O(1) | M1.1 | measured: structural sharing, snapshot isolation tests |
| Single-scalar insert, fast path | O(log n) | M1.1b | measured: 2.57 us at 1 MB, 3.90 at 10 MB |
| Single-scalar insert, general path | O(log n) | M1.1b | measured: 12.8 us at 1 MB, 16.7 at 10 MB |
| Build a rope from a `String` | O(n) | M1.2 | measured: 1.9-3.9 ms at 1 MB, 20.9-24.5 ms at 10 MB (the build it replaced: 2.60 and 25.72) |
| byte <-> UTF-16 <-> scalar <-> line/column conversion | O(log n) | M1.2 | measured, four whole-file runs: **0.59-0.82 us at 1 MB, 0.70-1.00 at 10 MB** (descent plus a <= 64-byte chunk scan, never a scan from the start). *Corrected 2026-09-10 (M1.3): this row read 0.53 and 0.77 us. Those were unmeasurable -- `conversionCost` timed each of 30 samples with `Date()`, whose smallest non-zero tick on this machine is 0.954 us, so every sample was zero or one tick and the mean was the tick-straddle fraction. The test now batches a nanosecond clock over 20000 precomputed offsets, as `generalPathInsertCost` already did* |
| Stream every chunk in order | O(1) per chunk, no allocation | M1.2 | measured: **3.86 / 4.01 ns/chunk** cross-module at 1 MB / 10 MB, against 18.23 / 16.93 for the flatten it replaced, both arms alternating in one process; 27-57 ns/chunk before the 4.2 promotion |
| Marker lookup by position or rank | O(log n) | M1.3 | built, **not separately benchmarked**: one `SumTree.find` descent, the same mechanism as the already-measured rope conversions. A cold read caught this row saying "measured" when no test times it; the honest claim is the mechanism, not a number |
| Resolve an anchor by marker identity | O(log n) | **M5** | not yet built; see the obstruction note in `dev/specs/m1.3.md` section 3 -- an ID-ordered index cannot absorb an edit in less than O(k) unless what it stores is shift-invariant, and the only shift-invariant quantities are rank (destroyed by marker creation) and relative order (needs order-maintenance labelling plus a persistent ID map). No M1.4 or M1.5 client asks for it; the Elisp `marker` object is the first that does |
| Adjust every marker after an edit | O(log n) regardless of marker count | M1.3 | **counted, not inferred**: `pathCopyEdit` recurses into one child per level, so an edit visits `height + 1` nodes -- **4 / 5 / 6** at 10k / 100k / 1M markers, counted by hooking the predicate closures during the worktree investigation, so like the 3M figures below they are a one-off diagnostic the shipped suite does not re-measure, and 20-34 summary comparisons for an edit anywhere in the tree at every size. Wall clock, release, 1000 samples, random offsets, base tree held alive across the timed region, four whole-file runs: **1.02-1.06 / 1.13-1.24 / 1.58-1.66 us**, i.e. about 1.6x across two decades against `log2`'s 1.5x. Markers *strictly inside* a deleted range remain O(k): 100k collapse in 2.03-2.07 ms, 20.3-20.7 ns each |
| Overlay / text-property lookup | O(log n + k) *(amended, see right)* | M1.4 | **built; the flat form is not what an augmented B-tree with items only in the leaves can deliver, and the honest claim is two-part.** The query is three searches (`dev/specs/m1.4.md` 1.6): starts inside the range, rank-contiguous, one descent plus O(k) cursor steps; straddlers, found by a **strict** `maxEnd > lo` prune over the rank prefix, where every visited node holds a result, so O(log n + k) when the results are rank-contiguous and O((k + 1) log n) worst case, k results scattered one per leaf each costing their own root-to-leaf path; and the empty interval at the upper bound, one more descent. Counted, not timed, by `boundaryEmptyIntervalsAtScale` and `queryVisitsAreOutputSensitive`. Measured, release, 1000 samples, n = 100,000, three whole-file runs: **1.69-1.94 us** at `k` near zero, and **64.2-65.0 us** for a 2,000-result window (200 samples, three runs). The second figure is the one with teeth: the first implementation reconstructed each scanned item's absolute start with a fresh root-to-leaf `find` instead of the `gap` the cursor had already handed back, making the scan O(k log n), and **no correctness test could see it** because the results were identical -- the counted visit tests instrument the straddler prune, and this scan does not go through it. `largeResultOverlapQuery` is the guard, and it is mutation-proven: putting the per-item `find` back measures **851-863 us**, 13x the fixed figure, against a 120 us bound |
| Adjust every interval after an edit | O((k + 1) log n + a + m + e) | M1.4 | measured: **3.30-3.54 us** at n = 100,000, release, 1000 samples, three whole-file runs, single-byte insertion at a random offset. `k` is the intervals whose extent genuinely changes (those straddling the edit point, each one independent `pathCopyEdit`), `a` those whose start lies strictly inside a deleted range (the contiguous collapse group), and `m` the tie group at the insertion point, which stage 2 stably partitions -- **`m` is a real term**: a keystroke where several overlays happen to start pays it with `k = 0`, and the doubled key `MarkerTree` uses would not remove it, because the exception in `startMoves` depends on `insertBeforeMarkers`, a property of the edit rather than of the item, so no static key sorts the movers into a suffix for every edit. The insert stage adds one more term the delete stage does not have: its straddler search must prune non-strictly (`maxEnd >= p`), because an interval whose end lands *exactly* on the insertion point still moves when `rearAdvance` or `insertBeforeMarkers` holds and a strict prune would discard it unvisited -- a silent lost `length` update, confirmed by mutation. So that search is O(log n + k + e), `e` being the intervals whose end is exactly the insertion offset. Removing `e` needs a second augmented dimension carrying the max end **restricted to items with `rearAdvance`**; deliberately not built in M1.4 |
| Open a 2 GB file read-only | under one second | **M1.6** | not yet built |
| Close a large buffer | iterative, no recursion | M1.1 | measured: no-deep-recursion release test. **Iterative is not free**: dropping the last reference to a tree is O(n) in its distinct nodes -- a marker tree measures 1.7-2.8 ms at 1M markers and 4.9-8.9 ms at 3M, paid synchronously by whoever releases it. M1.5's branching undo and M1.6's mmap view will hold many snapshots at once; releasing a chain of them is O(total distinct nodes). Found in M1.3 by an ARC-placement bug, not by design review |

- Persistent B+-tree rope; every mutation rebuilds the path to the edited leaves, so
  snapshots are structural sharing and background readers never lock.
- Summaries give O(log n) byte↔UTF-16↔line/column conversion, which the LSP client (UTF-16),
  tree-sitter (bytes) and the display (graphemes, lazily) all need; the `maxLineLen` summary
  is how a 20 MB single-line file is detected and laid out lazily instead of wrapped eagerly.
- Markers live in a **marker tree**: an order-statistics balanced tree keyed by position with
  offsets stored **relative to the previous marker**, so an edit adjusts every marker after it
  in O(log n) regardless of marker count, and a lookup is O(log n) (Emacs's linear marker list
  is its documented scaling limit). *Amended 2026-09-10 (M1.3): this line said "lazily
  propagated offsets". The requirement is the complexity bound, not the mechanism, and
  relative encoding is the persistent-data-structure equivalent of lazy propagation -- it
  makes "shift everything after K" a single-item update, which is exactly what lazy
  propagation buys in a mutable tree. True lazy propagation is in tension with persistence by
  construction: pushing a pending delta into children mutates nodes that older snapshots
  share, and path-copying the push-down makes it not lazy, only a differently spelled path
  copy.* Markers **strictly inside a deleted range** are the one case that is not O(log n):
  they all collapse to the range start, so a deletion spanning k markers costs O(k + log n).
  That is inherent under the no-retained-history constraint below -- nothing makes k distinct
  positions become equal in less than O(k) without a history to replay -- and GNU pays it
  linearly too. The tree is persistent like the rope, so a `BufferSnapshot` carries the
  marker positions of its moment and background readers resolve anchors against it. This is
  deliberately **not** Zed's anchor design: Zed resolves anchors through a CRDT fragment
  history with retained tombstones, which conflicts with R3's "memory never grows" unless a
  compaction story exists. The M1 definition of done names this choice and its complexity
  tests. Elisp `marker` objects are anchors with an identity wrapper; marker arithmetic
  (`(+ (point-marker) 1)`) resolves at use.
- Overlays and text properties live in one augmented interval tree (both start and max-end
  summarised, closing the gap Emacs 29's `itree.c` records as bug#58342). Property lookups
  are O(log n + k); the table above amends that to its two-part form, which is what M1.4
  measured and counted. **The interval tree is built (M1.4); text properties are not on it
  yet** -- a text property is a plist and there are no Lisp values until M2, so M5 wires them
  onto the same tree. Three facts from the GNU oracle that no reader would guess and that the
  M1.4 record keeps with its transcripts: `insert-before-markers` **overrides both**
  `front-advance` and `rear-advance`, so every endpoint at the insertion point advances;
  an empty overlay with `front-advance` and not `rear-advance` would **invert** under the
  per-endpoint rule (GNU keeps it where it is, which the implementation expresses as a
  conjunct of the "does the start move" predicate rather than as a clamp after the fact); and
  `overlays-in`'s docstring is wrong for an empty query range -- `(overlays-in 5 5)` returns
  a *non-empty* overlay containing 5, which shares no character with the region.
- Undo is transaction-based (grouped by command and by a 300 ms window), stored as edit
  logs plus retained snapshot checkpoints; branches are native, so an undo-tree UI is a view.
- Multi-cursor edits are one transaction with per-anchor bias rules.
- Read-only huge files (GB logs) are viewed through a line-indexed mmap without building a
  rope until the first edit. **This is M1.6.** It was in M1's definition of done from the
  start and belonged to no sub-milestone until 2026-09-09 -- not in section 8's M1.1-M1.5
  split, and listed as an open gap in the M1.1b stage 1 record with no owner. A criterion no
  sub-milestone owns is a criterion the family cannot meet.
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
tree, M1.5 undo, M1.6 the line-indexed mmap view for huge read-only files; M5.1 buffers and faces, M5.2 keymaps and rich keys, M5.3 the run queue
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

## 8b. Owner's wish list (recorded 2026-09-09; **not planned, not scheduled**)

Recorded verbatim at the owner's instruction so it is not lost, and explicitly *not* worked
into section 8's milestone order. A future session with capacity picks one up and plans it
then -- **except W9, which did not wait**: the owner promoted it to R10 on the day this list
was recorded, because it constrains milestones that are already planned rather than adding new
ones. Its row is kept below, pointing at R10, so that the list stays a complete record of what
was asked for. Nothing here has a milestone, a definition of done or an estimate, **W9
included**: R10 is a requirement, and section 1's requirements do not carry those either.
The right-hand column is the audit of what section 8 already covers, done when the list was
recorded, so that a later session does not plan something twice.

| # | Wish | Already in this plan? |
|---|---|---|
| W1 | Evil mode **+ `evil-collection`**, bundled and **enabled by default** | **Partly, and the default changed.** M20 has "the evil layer ported from Reticle's `evil.el` design"; section 5 lists `evil` among the packages tier 2 must be able to host. **`evil-collection` is new** -- nothing covers per-package vim bindings for dired, the git status buffer, `occur` and the rest. The owner settled the default on 2026-09-09: evil ships installed and active, off by a config-file setting; see R10, which M20 must now be read against |
| W2 | Magit | **Yes, in shape -- and the owner confirmed that is what was meant (2026-09-09).** 4.12 and M19 build git natively, "driving the `git` CLI as Magit and VS Code do", with a status buffer whose sections and `s`/`u`/`c`/`P` keys are Magit's, and M19's definition of done is "a scripted repository walkthrough matches Magit's observable results". Section 1 records that `magit.el` itself does not run, and that decision stands: asked directly whether he wanted the Magit *workflow* or literally to run `magit.el`, the owner chose the workflow. Consequence to remember: third-party magit extensions (forge and the like) are ports, not installs |
| W3 | SSH remote editing (building it is required; verifying against a live host may be deferred, as in Reticle) | **Yes.** M26, on VS Code Remote's model, async by construction, with Reticle's M75-M77 save-safety rules. Section 9 excludes TRAMP methods *beyond* SSH, not SSH |
| W4 | A text search system, referencing Reticle's | **Yes.** 4.12 "Search" and M11: ripgrep into an editable results buffer, wgrep-style write-through, orderless filtering, with Reticle's two recorded defects in that area fixed rather than ported |
| W5 | Language support and highlighting for Verilog, SystemVerilog, C/C++, Python, Tcl/Tk, Perl, Swift, Emacs Lisp, **Scheme**, **Java**, **Rust** | **Partly.** 4.1's grammar list is SystemVerilog, Swift, Python, Perl, Tcl, C, C++, Elisp, Org, Bash, Markdown, JSON/YAML/TOML; M9 does SystemVerilog properly and M30 is the breadth wave. **Scheme, Java and Rust are new** and are not in that list |
| W6 | Eshell and IELM, as GNU has them | **No -- both are new.** The plan has `comint`, `shell-command`, `compile` and `M-!`/`M-&`/`M-|` (M13) and a real terminal, but neither Eshell nor IELM appears anywhere in it. Reticle has both |
| W7 | Buffers as GNU has them, switchable | **The model yes, the UI unstated.** M5 builds the buffer model, and section 5's compatibility contract implies `switch-to-buffer`; but no milestone itemises the buffer-list surface (`switch-to-buffer` completion, `ibuffer`, buffer-menu). M8b's list is the editing commands and M11's is project navigation; neither names it. A cold read caught this row claiming a flat "Yes" |
| W8 | Horizontal and vertical window splitting | **Yes.** M5's windows-and-frames model, whose definition of done is that window and `display-buffer` behaviour match oracle transcripts of GNU 30.2 |
| W9 | GNU Emacs's own key bindings as the default, because not everyone uses evil | **Promoted out of this list: it is now R10 in section 1.** It was implicit everywhere and stated nowhere -- the whole plan assumes Emacs chords (4.7, M8b's command library, M6's IME rule) -- but unlike the rest of this list it is not future work, it is a condition on milestones that are already planned. The owner moved it to the requirements table on 2026-09-09 |
| W10 | A default font, the same as Reticle's; and the user can configure it | **Yes -- the default half is already exact, the configurable half is implied.** The owner confirmed on 2026-09-09 that pellicle should default to what Reticle defaults to. Reticle's `README.md:249-250`: "JetBrains Mono ships with the editor and is the default; Fira Code ships alongside it, and SF Mono is used when macOS has it installed", switched with `M-x set-font`; it bundles JetBrainsMono Regular/Bold/Italic and FiraCode Regular/Bold under OFL (`reticle/THIRD_PARTY_LICENSES.md:111-116`, which also records that Fira Code upstream ships no italic). M7 already names the same three faces bundled per Reticle M105, so the default needs no change. What is still unstated is that the **user chooses**: M7's SwiftUI settings panel implies it, but section 5's Elisp contract names no font command at all. Reticle's is `M-x set-font`; whether pellicle owes the same Elisp-level control is unwritten, which a cold read caught this row asserting as already contracted |

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

#### M1.1b, designed and not started: the edit path

*(Heading kept as it stood when M1.1 closed. **All three items of this design shipped on
2026-09-08** -- stage 1 (item (1), the path copy with overflow and underflow repair) and
stage 2 (items (2) and (3), `Fragment`/`TreeBuilder` and the `B` re-sweep), each with its own
record further down this section. The design below is unedited, so read it as the
specification as it stood, not as a description of the code: three of its details did not
survive contact with the implementation, and the stage 2 record lists them.)*

The architecture review of 2026-09-07 compared four designs against the measured problem
(one single-byte insert rebuilds ~400 nodes: 211 `concatNodes`, 296 `makeInterior`, 106
`makeLeaf` at 1 MB). Recommendation, with the comparison behind it:

| | keeps `B...2B` | 1 MB single-byte insert | verdict |
|---|---|---|---|
| relaxed invariant (xi-style) | no -- only an upper bound survives | ~10-15 us (est.) | **reject** |
| `TreeBuilder` with per-height slots (Zed `sum_tree`) | yes | 13.7-16.5 us measured | the general path |
| cursor `slice`/`push_tree` (Zed's edit path) | yes | as above; it *is* the builder plus a resumable stack | on top of it |
| **path copy with local repair** | yes | **1.22-1.55 us measured** | **the fast path** |

Reject the relaxed invariant specifically because pellicle has already *accidentally* built
it: the current `concat`-everywhere rebuild is self-healing, which is exactly why a
rebalancing mutation was invisible to the tests (finding 4 above). Making that permanent
would delete the one oracle this project's discipline depends on. Path copy argues the other
way -- it shares sibling subtrees verbatim and never re-folds neighbours, so a rebalancing
defect it introduces *persists* and an end-of-run check catches it.

Where the ~115 us goes, measured directly with `-O -wmo` (this is the table to work
against; it was nearly lost with the session scratchpad):

| operation | cost |
|---|---|
| `Node.makeLeaf` of 12 chunks | **618 ns** -- essentially all of it the chunk byte re-scan |
| `Node.makeInterior` of 12 children | 113 ns |
| copy a 12-element `[Node]` | 168 ns (a trivial-element copy is 44 ns, so ~10 ns per retain/release pair) |
| fold 12 node summaries | 98 ns |

Against the counted 296 `makeInterior` + 106 `makeLeaf` per insert, that is ~98 us of ~119 us
in node construction. ARC is ~20% and is a *symptom* of doing 402 constructions, not a cause:
it is removed by cutting constructions to ~5, not by changing `Node`'s representation, so do
**not** make `Node` `indirect` or class-backed.

New surface in `SumTree.swift`, from the review:

```swift
package enum Fragment<Item: Summable>: Sendable {   // transient; never stored
    case items(ArraySlice<Item>)                        // 0...2B items, height 0
    case nodes(ArraySlice<Node<Item>>, height: UInt8)   // 0...2B same-height nodes
}
package struct TreeBuilder<Item: Summable>: ~Copyable {
    package mutating func push(_ fragment: Fragment<Item>)
    package mutating func push(subtree: Node<Item>)     // well-formed; O(1) amortised
    package consuming func finish() -> SumTree<Item>
}
package func splitFragments(where:left:right:) -> (item: Item, itemPrefix: Item.Item_Summary)?
package func pathCopyEdit(where:_ edit: (Item, Item.Item_Summary) -> [Item]?) -> SumTree<Item>?
```

Deleted by it: `buildFromNodes` and both its call sites inside `splitNode`/`cutNode`, and
`Rope.concatMergingSeam` -- four of `replaceSubrange`'s six cursor walks exist only to serve
the seam policy, and done leaf-locally that policy is two array reads. `concatNodes`/`rewrap`
become thin wrappers over `TreeBuilder.push`, so there is one rebalancing implementation
rather than two.

**`checkInvariants()` keeps its current assertions verbatim** -- that is the point of
preferring this over the relaxed invariant, and `Fragment` being a distinct type is what
makes an underfull node unrepresentable in a stored tree rather than merely discouraged.
Add: a `Rope`-level assertion that no two *adjacent* chunks have byte counts summing to
<= 64, which is the exact postcondition of the leaf-local coalescing policy and fails
immediately when it breaks, unlike the statistical mean-fill guard it would replace.

Order: (1) path copy, handling **both** overflow and underflow -- the prototype's own bug was
underflow arriving from the coalescing policy, not from a deletion; (2) `Fragment` +
`TreeBuilder`, replacing the fallback; (3) re-sweep `B` on the new implementation, with an
iteration benchmark added, since the optimum can move once cost-per-level changes shape.
Deletion's underflow repair (borrow-from-sibling or merge-with-sibling per level) is the hard
half and is where review effort goes. Prototypes and their cautions:
`dev/spikes/m1.1b-rope-edit-path/`.

Target: single-scalar insert into a 1 MB rope **under 10 us**, asserted absolutely and not
only as a ratio.

**Known gaps.** `Rope(String)` for 1 MB takes ~11 ms (~91 MB/s) because `SumTree.build` halves
recursively through `concat`; a 10 MB file would spend 110 ms in construction before anything
else happens, so M1.2 wants a bottom-up bulk loader. *(Amended 2026-09-09, M1.2: **do not
quote these two numbers.** The 110 ms was a linear extrapolation, never measured. And the
~11 ms stopped being true within this same milestone family -- stage 2's `joinNodes` rewrite
sped this build up as an unmeasured side effect, and M1.2 measured what was actually in the
tree at 2.60 ms for 1 MB and 25.72 ms for 10 MB. M1.2's record carries the correction and what
it cost: a bound written against the stale figure claimed to catch a regression it could not.)* No character/UTF-16/line conversion API
(M1.2), no marker tree (M1.3), no interval tree (M1.4), no undo (M1.5), no line-indexed mmap
view for huge read-only files.

---

### M1.1b stage 1: the path-copy edit path -- done 2026-09-08

The edit path M1.1 left as designed-and-not-started. `SumTree.pathCopyEdit(where:edit:)`
descends once to the leaf holding the flip item, hands that leaf's whole items array to an
`edit` closure, and rebuilds only the `h+1` nodes on the path; every off-path subtree is
shared verbatim and no neighbour is ever re-folded. `Rope.tryLeafLocalReplace` is the rope
side of it, dispatched to from `replaceSubrange` whenever the inserted text is at most 64
bytes. Gate: 64 tests -> **87**, and the whole suite got *faster*, 16.7 s -> 10.9 s.

**Measured, by the main conversation, release, one process** (`swift test -c release`, the
protocol this file's "How to measure" paragraph insists on):

| n | before | after | |
|---|---|---|---|
| 10^4 | 26.8 us | **2.43 us** | 11x |
| 10^5 | 72.3 us | **2.73 us** | 26x |
| 10^6 | 120.6 us | **3.18 us** | **38x** |
| 10^7 | 168.8 us | **4.58 us** | 37x |

The target was under 10 us at 1 MB, asserted absolutely at both 1 MB and 10 MB rather than
as a ratio -- the same bar at both sizes is a claim about the design's near-flat cost in `n`,
not a number tuned until it passed. The architect's prototype measured 1.22-1.55 us; the
shipped path is 3.18 us, about twice that. The gap is **not investigated** and is recorded
rather than explained, because nothing depends on it at 3x under target.

**The design, and the one rule that made it reviewable.** A private outcome enum
(`.declined`/`.ok`/`.split`/`.underfull`) carries repair up the path. The recursion uses
**non-root bounds at every level** and the root's looser bounds are special-cased exactly
once, at the top, together with the collapse loop for a root interior left with one child.
Underflow repair is merge-or-redistribute against one sibling: merge when the underfull
node's entries plus the sibling's fit in `2B`, redistribute at the midpoint otherwise. Both
provably land every node back in `[B, 2B]`, which is why **`checkInvariants()` keeps its
assertions verbatim** -- the whole reason this was preferred to the relaxed invariant.

The rule worth reusing: **the fast path never traps, it declines.** Every shape it cannot
handle falls through to the general path's existing preconditions, so the milestone added no
new trap and "did the fast path apply?" became a deterministic assertion instead of something
visible only as a timing number. `tryLeafLocalReplace` is `package` precisely so a test can
assert it returned `true` 500 times out of 500; a silent regression to the fallback is
otherwise invisible, because `replaceSubrange` falls back without saying so.

**What five cold reviews found after the gate was already green.** Two of the four defects
were **errors in the task spec, not in the implementation**, which is the useful part:

1. **The `bytes`-validity decline check was dead code.** It called `isScalarBoundary(bytes, 0)`
   and `isScalarBoundary(bytes, bytes.count)`, both of which return `true` unconditionally at
   exactly those two offsets, so the guard could never fire: `tryLeafLocalReplace(0..<0, with:
   [0x80])` stored a lone continuation byte. `checkTreeInvariants()` cannot see that -- a
   chunk's cached summary and `recomputedSummaryFromBytes()` come from the same scan, so a
   malformed byte is counted identically on both sides of the comparison that exists to catch
   a stale cache. The spec had asked for "the cheap check that it starts and ends on a
   boundary", which is vacuous at those offsets. Replaced with a real UTF-8 validator.
   *A cheap check that is cheap because it checks nothing is the failure mode to watch for.*
2. **The no-op short-circuit bypassed the scalar-boundary check**, because the spec said to
   return "before any tree walk". `insert("", at: 1)` at an offset inside a two-byte scalar
   returned success where the file header requires a `precondition` to fire. Moved after the
   guards; the boundary check is a read-only descent and worth paying for.
3. **Four of the new validator's guards had no coverage, and nothing asserted that a *valid*
   multi-byte scalar is accepted.** The second half matters more: a false *reject* would have
   been invisible, because `replaceSubrange` silently falls back to the general path and every
   content assertion would still pass. **Eight** decline tests now reach the validator, plus
   one asserting that a valid multi-byte scalar is *accepted*.
4. **A test comment claimed a discriminating power its fixture did not have.** The 30/40-byte
   fixture sums to 70, over the 64-byte coalesce threshold, so deleting the short-circuit it
   was meant to protect did not make it fail. Rebuilt at 10/20 in a root leaf and **proved**:
   removing the short-circuit fails the test, restoring it passes.

**Mutations, executed by the main conversation** (the implementer never verifies its own
fix). Four killed: sibling combine order in both the left and right branches (caught by the
redistribute test's item-order assertion), the root collapse `children.count == 1`, and
`tryLeafLocalReplace`'s leaf-boundary decline. Two survived:

- The leaf-underflow threshold `<` -> `<=`: shape-only. It forces a needless merge on a leaf
  already at `B`, but the combined counts still land in `[B, 2B]`, so no invalid tree exists
  to observe. A performance boundary, not a correctness one.
- **The coalesce floor `>` -> `>=`**, which the reviewer predicted would be caught fast by the
  invariant checker. It was not, and the reason is the milestone's most useful finding: an
  instrumented probe showed a relaxed guard genuinely takes a leaf from **6 items to 5**, so
  the case is thoroughly reachable -- and no test fails because **stage 1's underflow repair
  absorbs it**. The guard is a shape/performance choice here, not a correctness defence. The
  spike README's caution ("guarding the coalesce with `items.count > B` fixed it") was true of
  a prototype that had no repair; it is not a statement about this code.

  *Two failed attempts at that isolation are worth more than the answer.* The first disabled
  underflow reporting entirely and watched the checker fire -- confounded, because deletion
  induces underflow too. The second asserted the post-edit leaf count unconditionally --
  confounded again, because a plain delete legitimately leaves a leaf underfull for the repair
  to fix. Only a **before/after comparison across the coalescing blocks** isolates "a coalesce
  crossed the bound" from "something else did". A probe that fires for the right reason and
  the wrong reason equally is not evidence, and it takes real care to notice that it isn't.

**The adjacency assertion this file asked for was measured and not asserted.** M1.1b's design
wanted a `Rope`-level assertion that no two adjacent chunks have byte counts summing to
`<= 64`. It is not a postcondition of a leaf-local, guarded coalesce, and asserting it would
have been false: the scan counts **15** such pairs in the large band and **2** in the small
after an ordinary randomised run. It ships as a printed measurement. Two attempts to state in
a comment *which* shapes an edit path cannot produce were each refuted by a cold read -- first
"a shape no edit path can produce" (the 15 pairs refute it), then "any edit path reaching a
root leaf would merge the pair" (`combineUnderflowedSiblings` merges two sibling leaves on
item count alone and `collapseRoot` can make the result the root, so a root leaf can hold such
a pair). The third version claims nothing general at all and states only the measured
property. **Deleting the claim was the fix, twice attempted the other way first** -- the same
lesson the formatting record above paid eleven rounds for.

**Declined, with reasons.** Removing the coalesce guard to improve fill: deferred to stage 2's
`B` re-sweep, where fill and iteration cost get measured together rather than one at a time.
The join-point pair `combineUnderflowedSiblings` creates and nothing byte-sum-checks: a
fill-policy gap, not a correctness one, unverified by construction, same deferral. Two wording
preferences from the final round (a line-wrap artifact, and how much refutation history one
comment should carry) are recorded and not acted on -- this paragraph is the loop's
terminator, not a new batch.

**`twentyThousandOperationsLargeRope` barely moved, 121.2 s -> 113.5 s, and that is not the
rope.** `runModelProperty` recomputes `scalarBoundaries(model)` -- a full O(n) scan allocating
an `[Int]` of every boundary -- on every one of its 20,000 operations, so at a 4 MB model the
oracle is essentially the entire wall clock and an edit-path change of any size disappears
into it. Left alone as out of this milestone's scope; recorded so nobody reads that number as
a rope measurement. `millionOperationsSmallRope`, whose model is ~8 KB, went 16.26 s -> 7.50 s.

**One pre-existing test was retuned**, and it was reviewed as such: the randomised model's
small band went from `maxSize: 512` to `2048`, and with it `deleteMaxWidth` 16 -> 64 and the
paste pool `[50,150,300]` -> `[200,600,1200]` -- a multi-parameter retune, not a single bound
moved. The cause is not a change in chunk *size* (`packChunks` still targets 64 bytes) but in
chunk *fill*: leaf-local coalescing packs harder than `concatMergingSeam`'s seam-only merging
did, so 512 bytes now fits in a single height-0 leaf and the band stopped reaching the
height 0->1 transition its own assertion requires. It still starts at 0 with no floor, so it
still visits the empty rope.

**Not done here, and still M1.1b's remaining half**: `Fragment` + `TreeBuilder` replacing the
general path, deleting `buildFromNodes` and `Rope.concatMergingSeam`, and the `B` re-sweep
with an iteration benchmark. The general `split`/`concat` path is untouched and still
O(B*h^2); it now runs only for edits inserting more than 64 bytes or spanning a leaf boundary.

**What was and was not cold-read, stated because the rule here is easy to satisfy in spirit
and miss in letter.** Five rounds covered every line of `Sources/` and `Tests/` in this
milestone, and the fifth found nothing to change, which is what ended the loop. **This record
itself was written and committed without one.** The loop's base case exempts a record entry
that transcribes a round's declined findings -- but only that; the moment it makes a new claim
about the code it is a batch again, and this record makes many (the measurement table, the
`combineUnderflowedSiblings`/`collapseRoot` mechanism, what each mutation did). So it was owed
a round and did not get one at commit time. It got one immediately afterwards instead, and
that round's outcome is recorded below rather than being quietly folded in.

**These commits are local.** Nothing in this repository has ever been pushed: `origin/main`
still sits six commits behind, at the state before M1.1. That is the standing arrangement, not
an oversight -- but it means the only copy of this work is this machine.

*The round this record was owed then ran, and found three false claims in it* -- all three
fixed above, and worth naming because they are what an unreviewed record costs: a test count
that was both wrong and internally inconsistent ("eight tests, five declines and one
acceptance"); `16.25 s` for a log reading `16.25501...`; and a batch-size series in the
handover that silently mixed two counting conventions. It also re-derived the underflow bound
arithmetic, both mutation-survivor explanations, the never-traps claim and every number in the
measurement table against the logs, and found those sound. Two findings are recorded and not
acted on: that "tighter chunking" invited reading a packing-size change where the change is in
fill (the paragraph above now says so), and that the record's attribution of two defects to the
task spec cannot be checked, because the spec was a prompt and was never committed -- true, and
the honest form of it is that no artifact survives to audit that attribution. This paragraph
is the loop's terminator, not a new batch.

---

### M1.1b stage 2: `Fragment` + `TreeBuilder` and the `B` re-sweep -- done 2026-09-08

M1.1b's remaining half. `splitNode`/`cutNode` called `buildFromNodes` at *every level* of their
descent, and `buildFromNodes` folded `concatNodes` across up to `B + 1` siblings, so one cursor
walk did O(B * h^2) node reconstructions. That is now one descent emitting per-level
`Fragment`s and one bottom-up join. Gate: 87 tests -> **96**.

**The idea that dissolves the obstruction** (the architect's, validated in
`dev/spikes/m1.1b-rope-edit-path/proto-fragment-pushtree.swift` over 3,926 split points and all
81 height pairs): an underfull group is legal as an *argument* to the join and illegal as a
*stored* node. `Fragment` is that distinction made into a type -- `.items(ArraySlice<Item>)` or
`.nodes(ArraySlice<Node>, height:)`, transient, never stored. When the join meets an argument of
its own height it splices that argument's **children in flat**, because each of those children is
individually well-formed even when their parent group is not. So `checkInvariants()` keeps its
assertions verbatim, which is the whole reason this was preferred to the relaxed invariant.

**Measured by the main conversation, release, one process** (`-O -wmo`, the protocol this file's
"How to measure" paragraph insists on). The "before" column is a `git worktree` of the
pre-change commit running the same benchmark; the general path had no benchmark until this
milestone added one, so this number did not exist before. It does not match stage 1's 120.6 us
for what is nearly the same code, and the gap is expected rather than a transcription slip: that
number came from a different binary in a different session, and `CLAUDE.md` records a 94-352 us
spread across binaries built from identical source. That note names an operation only as "insert", with no
size and no fast-path/general-path distinction, so read it as the order of magnitude of
cross-binary variance on this machine rather than as a bound on
this specific measurement -- round 6 was right that an earlier version of this sentence claimed it
was "for exactly this operation", which the source does not say. 96.8 against 120.6 is a 20% gap,
comfortably smaller than that spread. The ratio below is therefore read as "roughly eightfold", not as
its second digit.

| single-scalar insert, general path only | before | after | |
|---|---|---|---|
| 1 MB | 96.8 us | **12.8 us** | 7.6x |
| 10 MB | 139.2 us | **16.7 us** | 8.3x |

The design predicted 13.7-16.5 us for this builder **at 1 MB**, which is the only size that
table covers; the shipped path measures 12.8 there, just under the band. The 10 MB figure of 16.7
has nothing to compare against -- quoting it against the same band, as an earlier version of this
sentence did, borrows a prediction the design never made, and 16.7 is in any case above 16.5, not
"just under" it. The **fast path
is untouched** and measured unchanged: **2.57 us at 1 MB and 3.90 at 10 MB** on the shipped tree
(median of three release runs), against stage 1's 3.18 and 4.58. Separate binaries, so read that
as "unchanged", not as an improvement. Two earlier numbers in this record, 3.04 and 4.04, were
measured before the coalesce guard was removed and are kept only in the guard table below, where
they are one column of a comparison; round 5 caught the handover quoting the guard-kept number as
the shipped one. New iteration
benchmark: 6.4 ns/chunk, 0.176 ns/byte.

**Deleted**: `buildFromNodes`, `rewrap`, `splitNode`, `cutNode`, `Rope.concatMergingSeam`.
`concatNodes` survives as a one-line wrapper over the join, so there is one rebalancing
implementation rather than two. `SumTree.split`/`cut`/`find`/`concat` keep their signatures.

**`generalPathReplace` went from six cursor walks to two.** It was `splitTree` x2 (one `cut`
each) plus `concatMergingSeam` x2 (two `cut`s each); four of the six existed only to serve the
seam policy. It is now two `splitFragments` descents into the *original* tree and one build,
with the `<= 64` seam merge done on the boundary fragments as array reads. The builder stays
generic and knows nothing about chunk sizes -- `Rope.init(unmergedChunks:)` depends on bulk
construction *not* coalescing, so a coalescing hook inside `TreeBuilder` would have broken it.

#### The defect that mattered: a trap became silent data corruption

The first version sliced the two straddling chunks by hand without the scalar-boundary
`precondition` that the `splitTree` it replaced still performs. Reproduced by the main
conversation before fixing anything:

```
Rope("é" + String(repeating: "m", count: 100)); removeSubrange(0..<1)
before: [c3, a9, 6d, 6d]      after: [a9, 6d, 6d, 6d]      toString: "\u{FFFD}mm..."
checkTreeInvariants() PASSED
```

The pre-change commit traps on the same input (`byte offset 1 is not a scalar boundary`). So the
milestone had converted a loud programmer-error trap into silent corruption of the user's text.

**The tree oracle structurally cannot catch this.** `Rope.checkTreeInvariants` compares a chunk's
cached summary against `recomputedSummaryFromBytes()`, and both are derived from the same
corrupted bytes, so they agree. That is the same blind spot stage 1 recorded for its dead
`bytes`-validity check, hit from a different direction -- worth stating twice, because "the
invariant checker passes" reads like evidence and here it is not.

Both guards are restored. **Nothing regression-tests them**, and that was established by
mutation, not by argument: delete either one and all 96 tests pass. Every randomised and
differential test in `ropeTests.swift` draws its offsets from `scalarBoundaries`, so none can
present a non-boundary offset to this path, and asserting a `precondition` trap needs an
out-of-process crash harness this project does not have. Known gap, recorded here because the
code comment at the guards points at this record for it; the repro above is its first case.

#### `B` re-swept and kept at 6

Swept B in {4, 6, 8, 12, 16, 24} on the new implementation, five runs each, medians (a separate
binary per B, so within-binary spread -- 2-12% -- is the noise floor to beat):

| B | general-path insert 1 MB / 10 MB | fast-path insert 1 MB / 10 MB | iteration 1 MB |
|---|---|---|---|
| 4 | 11.4 / 18.0 us | 3.23 / 3.90 us | 5.89 ns/chunk |
| **6** | **11.9 / 16.3 us** | **2.69 / 3.67 us** | 5.83 ns/chunk |
| 8 | 12.0 / 16.2 us | 3.24 / 4.40 us | 4.06 ns/chunk |
| 12 | 12.7 / 17.8 us | 2.84 / 4.26 us | 4.11 ns/chunk |
| 16 | 12.4 / 18.3 us | 3.40 / 5.32 us | 3.38 ns/chunk |
| 24 | 17.2 / 21.2 us | -- | 3.42 ns/chunk |

Edit cost is flat across B = 4...8 and clearly worse at 24. The two axes then disagree:
**iteration wants a larger B** (B = 8 is 30% faster than B = 6 at 1 MB, far outside the noise)
and **the fast path wants a smaller one** (B = 6 is the optimum at both large sizes; B = 16 costs
45% at 10 MB). The mechanism is visible in the code either way: path copy rebuilds arrays of up
to `2B` children per level, so typing gets worse as B grows, while flattening gets better because
there are fewer interior nodes per item.

**Kept at 6**, deliberately: the fast path is the typing path and B = 6 is its measured optimum,
whereas iteration's gain sits on `chunks()` -- a full flatten that no product path runs per
keystroke, and the exact operation M1.2's lazy cursor is expected to replace, which would change
its cost shape entirely. Changing B would also have invalidated dozens of hard-coded B = 6
fixtures in `sumTreeTests.swift` for a gain measured on the operation most likely to be
redesigned next. Recorded so the sweep does not have to be redone; re-run it when the cursor
lands, because that is the event that could move the answer.

#### The seam policy narrowed, measured, and left alone

The new seam merge reads the boundary chunks out of the fragment lists. When an edit bound lands
exactly at a leaf edge, the neighbouring chunk sits inside a `.nodes` group instead of a
leaf-level `.items` group, and the merge declines; the old `concatMergingSeam` always reached it
through `cut`. Two A/B runs against the pre-change commit, identical operation sequences
(identical byte counts at every checkpoint, which is how the sequences were confirmed identical):

- **Scattered offsets, 20,000 general-path edits**: the new code is *better* -- mean fill 38.82
  vs 37.37, 9,999 chunks vs 10,389, 2,429 adjacent small pairs vs 3,085.
- **Boundary-aligned offsets, 30,000 edits** (the adversarial pattern, built to hit the decline):
  the new code is worse and **plateaus** -- mean fill settles at 45.9 vs 51.6 bytes per chunk,
  with adjacent-small-pairs/chunks flat at ~11% and under-32-byte-chunks/chunks flat at ~28% from
  op 5,000 onward. About 12% more chunks per byte, bounded, not a runaway.

**Declined, with the reason.** The pattern that provokes it aligns every edit to an internal
chunk boundary, which no real editing workload targets, the realistic pattern improved, and the
fix would add a new O(h) descent to the seam path -- the very code that just produced this
milestone's one high-severity defect. The fix direction is recorded instead: peel the boundary
item out of a `.nodes` fragment by descending its right (or left) spine and re-emitting the
ancestors as fragments, which is O(h) and needs no rebuild. Revisit it in M1.2 alongside the bulk
loader, where chunk fill is already on the table.

#### The two fill questions stage 1 deferred into this stage

Stage 1's record and the handover both listed these as work for stage 2's sweep, "both fill
questions and both want measuring alongside the `B` sweep, not before it". They were not in this
stage's task spec -- that was an omission, caught when the handover was re-read at record time --
so they were measured afterwards rather than as part of the implementation.

**1. The leaf coalesce guard is gone.** `tryLeafLocalReplace`'s three coalescing blocks each
required `isWholeLeaf || newItems.count > branchingFactor` before merging a pair. Stage 1 had
already established by mutation that it is not a correctness defence -- relaxing it takes a leaf
from 6 items to 5 and nothing fails, because `pathCopyEditNode`'s underflow repair absorbs it.
Measured on the current code, release, 40,000 sustained fast-path edits:

| | guard kept | guard dropped |
|---|---|---|
| adjacent chunk pairs summing `<= 64` | 176 | **56** |
| mean chunk fill | 45.45 | **47.01** |
| chunks under 32 bytes | 605 | 530 |
| 40,000 ops, wall clock | 103.0 ms | 103.3 ms |
| `scalingRatio` single insert, 1 MB / 10 MB | 3.04 / 4.04 us | 2.50 / 4.49 us |

The two `scalingRatio` numbers move in opposite directions inside a noise band that runs 5-30% on
this benchmark (the `B` sweep's 2-12% figure above is a different benchmark, measured
within one binary rather than across runs of one), which is the honest reading: **no measurable cost**, not "faster".

**And the other workload, because quoting only the favourable one is how this project's comments
have twice gone wrong.** On the mixed randomised model -- big pastes and wide deletes, so a large
share of its edits go through the general path rather than the fast path -- the guard makes no net
difference to the same metric. The Part D adjacent-pair scan reads **25 either way**, merely
redistributed across the two bands:

| | large band | small band |
|---|---|---|
| before stage 2 | 15 | 2 |
| stage 2, guard kept | 25 | 0 |
| stage 2, guard dropped (shipped) | 19 | 6 |

So the fill gain is real on a fast-path-dominated workload and a wash on a mixed one, and the
seam narrowing -- not the guard -- is what moved the large band from 15 to 25. The guard was
removed anyway, on three grounds that do not depend on which workload you weight: it is not a
correctness defence, it costs nothing measurable, and **its stated rationale was wrong** -- the
comment claimed it "must never let a leaf drop below this same bound", and the repair below it
has always been what actually holds that bound. The three comments explaining it, including
`branchingFactor`'s own doc comment whose stated reason for being `internal` was that guard, were
rewritten to say so.

**2. The join-point pair `combineUnderflowedSiblings` leaves un-checked is still there.** It is
one of the two remaining leaf-local causes of such pairs, not the only one -- a cold read caught
that overstatement in the first draft of this paragraph. The underflow repair concatenates two
sibling leaves' items with no awareness of the `<= 64` policy, so nothing inspects the pair it
creates at the join; and separately, the coalesce does not iterate to a fixpoint, so a merge
product is never re-examined against the neighbour beyond the one it just absorbed (leaf
`[..., P, F1, F2, ...]`, an edit collapses `P` to one byte, the trailing merge yields `P+F1`, and
`P+F1` against `F2` is never looked at even when it would fit). That second mechanism predates
this stage; removing the guard only widened its reach from root leaves to all leaves. It is **deferred again, explicitly**,
because fixing it is not a local edit: `SumTree` is generic over `Item` and deliberately knows
nothing about a chunk's 64-byte packing rule, so checking that pair means giving `Summable` an
item-level coalescing hook -- the same design decision the seam policy faced and was kept out of
the builder for, and one M1.4's overlay tree gets a vote in, since it will be the second `Item`
type. Deciding it here, with one client, would be deciding it on half the evidence.

*M1.4 cast that vote, and it is **no** (2026-09-11).* Intervals carry identity: two adjacent
intervals with equal fields are two distinct overlays, and merging them would destroy an object
the Lisp side holds a reference to. So the second `Item` type does not want the hook either, and
the deferral stands with one interested client rather than a tie. The chunk-packing gap is
unchanged and still belongs to whoever needs it.

#### Mutations, executed by the main conversation

| mutation | result |
|---|---|
| leaf / interior `2B` overflow, `<=` -> `<` | **survived** -- shape only: it splits earlier and both halves still land in `[B, 2B]` |
| leaf / interior overflow, allow `2B + 1` | killed, by the invariant checker *and* by the new `Fragment` bound `precondition` |
| drop `!other.isUnderfull` from the join | killed loudly (`leaf item count 1 out of bounds [6,12]`) |
| reverse left / right fragment push order | killed, 228 / 226 issues |
| `.nodes` empty-fragment guard removed | killed (`makeInterior`'s own precondition) |
| `.items` empty-fragment guard removed | **survived** -- equivalent mutant, now documented at the guard |
| seam `<= 64` -> `< 64`, both sides | **survived**, then killed by two tests written for it |
| `mergeLeadingSeam` operand order swapped | killed -- and the killer was the *restored* scalar-boundary precondition firing at offset 353, because swapped operands split a multi-byte scalar |
| either scalar-boundary `precondition` deleted | **survived** -- the known gap above |

The seam survivors are the useful ones. Every pre-existing seam test used pairs summing well
under the threshold (40 and 35), so nothing pinned the threshold's *value*; `<= 64` -> `< 64`
left the whole suite green on both sides. The cold reviewer predicted this for the leading side
only; the mutation showed it was true of both. Two tests now pin the exact boundary (34 + 30, and
a 40/30 fixture split at offset 6 leaving a 34-byte remainder), and each kills its mutant with
exactly one failing test.

#### Where the spec was wrong

Stage 1 recorded that two of its four real defects were errors in the task spec rather than in
the implementation, and that this could not be audited because the spec was a prompt and no
artifact survived. This time the spec was written to a file first, and that file is committed at
`dev/specs/m1.1b-stage2.md` -- verbatim, not tidied up afterwards, because a spec edited after
the fact cannot audit anything. Its errors, so they are on the record:

1. **It stated the `0...2B` bound on a `Fragment` only as a description, never as an
   obligation.** The spec's type definition does carry `// 0...2B items` on both cases, so the
   first version of this paragraph -- which said the spec "never stated" the bound -- was itself
   false, and both the main conversation and round 5 caught it independently. The real gap is that
   nothing in the spec said *who enforces* it or that anything could violate it, so it read as a
   property the type already had. The implementer hit it while wiring `generalPathReplace` and
   bounded it with a helper; a cold review then pointed out the bound was still unenforced at
   `TreeBuilder.push`, where it is now a `precondition`.
2. **"the last element of the last left fragment"** is the sentence that produced the seam
   narrowing above. Read literally it is what the implementation does; what the design meant was
   the last chunk in document order, which is not the same thing when the bound lands at a leaf
   edge.
3. **"`concatNodes` and `rewrap` become thin wrappers"** -- `rewrap` had zero callers after the
   rewrite and was deleted. The spec's own test list anticipated this and said to re-point the
   test rather than delete it, which is what happened (`rewrapOverflowBranchDeterministic` ->
   `interiorOverflowBranchDeterministic`).

Also deviating from the M1.1b design, deliberately: the design's `push(subtree:)` comment says
"O(1) amortised", which describes a per-height-slot builder. The shipped join is the prototype's
right-spine descent, which is O(height difference) per push and O(h) for a monotone-height
fragment run. The measurement above is of that shape, and it met the target, so the O(1) claim
was not chased.

**Review rounds.** Five, on batches of 802, 89, 19, 23 and 316 lines (added lines, one
convention for all five). Round 1 found the corruption defect above plus three others. Round 2
found that the fix for it was not regression-tested, which is the finding that produced the known
gap. Round 3 read the comment recording that gap and found nothing to change. Round 4 read the
leaf-coalesce-guard removal: it found no correctness defect -- and got there by constructing a
worse case than stage 1's, a non-root leaf of six single-byte chunks driven to **one** item
because two coalescing blocks fire in sequence on the same edit, then tracing it through
`combineUnderflowedSiblings` to show the repair still lands in `[B, 2B]` -- but it caught four
stale comments the removal had left behind, including a pair of counts quoted from before the
change. It missed a fifth, in `tryLeafLocalReplace`'s vanished-run block, which still said the
merge happened "under the same item-count guard the two blocks below use" after that guard had
been deleted from all three blocks. **Exactly one round had the chance in its own batch and
missed it** -- round 4, the one that read the removal. The sentence was *true* until that batch
deleted the guard, so rounds 1-3 had nothing to catch, and rounds 5 and 6 were given prose batches
that did not contain this file at all. Round 6 found it anyway, and how it got there is the part
worth keeping: it was checking a claim *this record* made about the code ("four stale comments the
removal had left behind") against the code itself, and walked out of its assigned batch to do it.
A record that describes code gives the next reviewer a reason to go and read that code, which is
an argument for writing the description down even when it is the thing that turns out to be
wrong. An earlier version of this paragraph said "four rounds of cold reading
missed" it, which inflated the failure by counting rounds that could not have seen it; round 7
caught that, in a paragraph whose whole subject is records getting their own review history wrong.
The lesson survives the correction and is the cheaper one anyway: when a named thing is deleted,
grep for the name rather than relying on the next reviewer to notice its ghost in prose. Round 5 read this
record and the comment fixes, and found four more things, listed in the
terminator paragraph below. **An earlier version of this paragraph said "three rounds" and
described only the first three**, because the guard-removal section was inserted later and this
summary was not updated with it; round 5 caught that, which is the second time in two milestones
that a record's own summary of its review history was the thing that was wrong.

**Declined, with reasons.** Reaching the true boundary chunk through a `.nodes` fragment: the
measurement above, deferred to M1.2. Round 3 found nothing to change in the code and two things
worth recording instead: the new `#expect(rope.height == 0, ...)` sits before the first append
while its sibling test puts the analogous check after it -- moot for a 40-byte fixture, and a
placement preference rather than a fact; and that assertion cannot be shown by any production
mutation to add coverage, because deleting an assertion can only reduce coverage, never redden a
green suite. Its value is as a tripwire against a future *fixture* edit, which is what its
siblings are for as well, and that is worth saying out loud rather than assuming. Round 3 also
re-derived the corruption mechanism independently and confirmed it: `Chunk.init` snapshots
`packedSummary` with the same `scanSummary` that `recomputedSummaryFromBytes()` later re-runs
over the same stored bytes, so the two agree by construction whether or not those bytes are valid
UTF-8, and `Chunk.init`'s own precondition checks only that the run *ends* on a scalar boundary,
never that it starts on one.

Round 5 read this record and found four things. Three were facts and are fixed above: the review-
round count, the spec attribution, and the fast-path headline number. The fourth was a Markdown
bug -- a paragraph line sitting directly against the `---` divider below, which CommonMark parses
as a setext heading rather than as prose, so this milestone's closing sentence would have rendered
as a heading. Fixed by a blank line, and worth recording because it is the only defect in this
milestone that no amount of reading the *code* could have found. Two further findings are recorded
and not acted on: that two different noise-floor percentages appear for "this machine" (they are
two different benchmarks, and the text now says which is which, but the reviewer's preference was
for one figure), and that the 96.8 us baseline sits 20% below stage 1's 120.6 us for nearly the
same code (explained above as cross-binary variance, against the 94-352 us spread `CLAUDE.md`
records -- with the caveat stated up there, not here, that the note names no *specific* operation
or size -- and not re-run to prove it).

Round 6 then read the corrections themselves and found two facts to fix -- both are fixed above --
plus two it recorded and I did not act on: that the `B` sweep table's 2.69 us for B = 6 is a
fourth fast-path number in this record without a sentence tying it to the 2.57 headline the way
the other three are tied together (it is the same configuration measured in a different binary,
which the surrounding text already establishes, so this is a clarity preference rather than a
wrong fact); and that "both the main conversation and round 5 caught it independently" is
unfalsifiable from any artifact, which is true, and it stays because the point of the sentence is
that the spec artifact existed to be checked at all. Rounds 7, 8 and 9 then read the corrections to the corrections, and each of the first two found a
real fact: round 7, that "four rounds of cold reading missed" the stale comment was inflated
arithmetic (the comment was true until round 4's own batch deleted the guard) and that the
"for this operation" overstatement had survived verbatim in a second paragraph; round 8, that
"round 6 found it" and "rounds 5 and 6 read prose batches that did not contain this file" were
contradictory without the missing piece. All three are fixed above. Round 9 found nothing to
change and recorded one thing: that the closing observation about records sending reviewers to the
code generalises from a single instance, which is true -- it is an argument, not a measurement,
and it stays because it is labelled as one. Five of the nine rounds found something in the prose
rather than the code, and that is the honest shape of this milestone: the code converged after
round 4 and the *record* took five more rounds to stop being wrong about itself. These paragraphs
transcribe rounds 5 through 9; they are the loop's terminator, not a new batch.

**One later addition, and what its cold read said.** The task spec and the general-path
benchmark existed only in a session scratchpad, so both were committed afterwards --
`dev/specs/m1.1b-stage2.md` and `RopePerfTests.generalPathInsertCost`. Until then **nothing in
the repository measured the path this milestone rewrote**: `scalingRatio` measures the stage-1
fast path, which absorbs any edit of at most 64 bytes and never reaches the general path, so the
headline 96.8 -> 12.8 us had no regression protection at all. Its review recorded one finding
worth carrying: **the benchmark asserts only an upper bound, so it can catch "too slow" but never
"wrong path".** If `replaceSubrangeGeneralPathOnly` were ever rerouted through the public
`replaceSubrange` dispatcher, its single-byte insert is exactly the shape `tryLeafLocalReplace`
accepts -- the number would get *faster*, the bound would still pass, and the general path would
silently lose its coverage again, with the differential correctness test none the wiser because
the bytes come out identical either way. A lower bound would catch it and would also fire falsely
the day the general path legitimately gets fast, so it is recorded rather than added. The other
findings were a suspected missing `import Dispatch` (settled by the gate: it builds in debug and
release and the benchmark ran) and three deviations from `scalingRatio`'s conventions -- the
timed region includes an O(1) `utf8Count` read, the rope is grown across samples instead of
reset, and the generator is re-seeded per size. All three are real and none changes a number at
this magnitude; recorded, not acted on.

---

### M1.2: conversions, bulk loader, lazy cursor -- done 2026-09-09

Spec: `dev/specs/m1.2.md`, plus `dev/specs/m1.2-promotion-and-guards.md` for the fix round.
Gate: **123 tests in 15 suites**, green, re-run by the main conversation after the cold-read fix round (119 before it; the four new tests are the cold reads' own findings turned into coverage). Perf suite: 10 of 10
whole-suite runs green after the two bound fixes below.

**What shipped.** All three deliverables, plus the two acceptance obligations the spec named.

| | Measured (this machine, release `-O -wmo`, main conversation) | Before |
|---|---|---|
| `Rope(String)` at 1 MB | **1.85-3.86 ms** whole-suite, 1.72-1.94 ms alone | **2.60 ms** |
| `Rope(String)` at 10 MB | **20.9-24.5 ms** | **25.72 ms** |
| `Rope.convert` at 1 MB / 10 MB | **0.46-1.57 us** | did not exist |
| `chunks()` streaming, cross-module | **3.86 / 4.01 ns/chunk** | 18.23 / 16.93 (flatten, same process) |

Conversions are one `TextMetric` enum over `utf8`/`utf16`/`scalars`/`lines` plus one generic
routine on `SumTree.find`, not eight hand-written functions -- the same reasoning stage 2 used
when it deleted `buildFromNodes`. The bulk loader replaced `SumTree.build`'s recursive halving
in the **generic** layer rather than adding a `Rope`-only fast path, because `build` is the
single shared bottleneck three call sites reach today and M1.3's marker tree will be the
fourth. The cursor is written from scratch: nothing in the module streamed before it.

**The cursor was reported as failing its acceptance, and it was not.** The implementer measured
43 ns/chunk against a 5.5-5.8 baseline and flagged it as the milestone's one unmet target,
guessing at cross-module dispatch but declining to act because it read the fix as an
architecture decision. A main-conversation diagnostic settled it in one run -- same process,
same rope, same code, 31.8 ns/chunk called from the test module against **3.58 in-module**. The
algorithm was never the problem.

#### The promotion, and what "promote" turns out to mean

4.2 has been amended; this is the record of why. An architect pass found the question's premise
false. Every option considered assumed promotion meant `public`. **`@usableFromInline` on a
`package` type, with `@inlinable` on the hot members, is also a promotion** -- measured at 3.49
ns/chunk against `public`'s 3.56, with **no public API surface at all**. It was isolated on this
project's own probe harness rather than argued: with the attribute the member's symbol is absent
from the calling module's object file, without it the undefined symbol reappears, and the type's
plain-`package` `init` keeps its symbol in both as the control. 14 declarations, two files,
nothing `public`. The price is that eight members go `private` -> `internal`: module-internal
encapsulation, not API.

Two corollaries worth more than the change itself:

- **The promotion unit is the whole call chain the benchmark walks.** Promoting `next()` alone
  recovered ~35% (20.7 ns/chunk). `descendLeftmost`/`advanceToNextLeaf` run once per leaf, once
  per <= 6 chunks, and an opaque call there cost ~17 ns/chunk by itself.
- **A plain-`package` `@inlinable` is unchecked, not merely ineffective.** Adding
  `@usableFromInline` to `TextMetric` immediately produced six "`TextSummary` is package and
  cannot be referenced from an `@inlinable` function" errors against code that compiled
  silently. M1.2 had shipped exactly such an annotation; it is deleted, and `TextMetric` is
  recorded as a promotion candidate whose benchmark has not asked for it.

`dev/check-inlining.sh` now guards this literally. Probes alone cannot: deleting
`SumTreeCursor`'s attribute costs 8x, leaves every probe green and every test passing. So the
script gained a third *warm* probe shape (does the toolchain still do this?) **and** a grep over
the real declarations by name (do we still ask it to?). Both, deliberately -- they answer
different questions. Verified by deleting the attribute: probes stayed green, the grep failed
with the file and declaration named.

#### Mutation pass (main conversation; the implementer does not verify its own fix)

Ten mutations: the spec's six focus points (M1-M6), two the main conversation split out while
running them (M2b, M9), and two a cold read added (M7, M8). An earlier version of this table
listed five, jumped from M3 to M5 without saying why -- M4 and M6 had simply not been run,
while the section's framing implied a complete pass -- and a later one said "six plus two" over
a table of ten. Both were caught by cold reads counting the rows. **A record's own count of
itself is the claim in it most likely to be wrong** -- stage 2's record says the same of its
review rounds, and a cold read of this very sentence pointed out that calling this "the third
such miscount" was itself a count it could not support. Do not number them; check them.

| Mutation | Result |
|---|---|
| M1 conversion predicate `>` -> `>=` | **survived -- equivalent mutant, proven** |
| M2 column base `+1` | killed |
| M2b line base `+1` | killed |
| M3 bulk-loader fill target -> `B` | killed |
| M4 bulk loader reverts to recursive halving above 30k items | **survived -- the bound does not guard what it claimed** |
| M5 cursor materialises the leaf per descent | **survived -- real defect in the defence** |
| M6 cursor observes later edits | **not expressible as a mutation** |
| M7 cursor skips each leaf's first item (added by a cold read) | killed |
| M8 `descendSeek` copies the leaf (added by a cold read) | killed |
| M9 reinstate `groupSizes`'s removed walk-down loop | survived, as predicted -- the loop was dead |

**M6 is recorded as untestable rather than left blank.** The cursor's isolation from later
edits is not a guard that can be reverted; it follows from `SumTreeCursor` storing a `Node`
*value* over copy-on-write arrays, so an edit to the source rope builds new nodes and cannot
reach the cursor's. Making it observe edits means storing a class reference -- a redesign, not
a mutation. `CLAUDE.md` requires saying so rather than pretending coverage, and the test
comment says it too.

**A trap that caught three attempts in this milestone**: `Array(anExistingArray)` does **not**
copy in Swift. A "materialise the leaf" mutation written that way is a no-op, passes, and looks
like a surviving mutant. `items.map { $0 }` is a real copy. Two of those three attempts were
the implementer's, one was the main conversation's.

M1 was not written off by reasoning. An exhaustive differential -- every scalar-boundary offset
of a multi-chunk, multi-line, mixed-scalar-width rope, all three positional metrics both ways,
**14,409 conversions**, checked against counts recomputed by scanning raw bytes rather than
against the rope's own summaries -- returned identical answers with the predicate both ways.
That test stayed in the suite; exhaustive-offset coverage is worth having regardless of the
mutant that prompted it.

**M4 was the expensive one, and it falsified a claim in this record.** Reverting `build` to
recursive halving above 30,000 items -- so 1 MB keeps the new path and 10 MB does not -- passed
`bulkBuildThroughput` untouched. Investigating why produced a correction that reaches further
than the bound: **the recursive-halving build this milestone replaced does not cost ~11 ms at
1 MB.** That figure is M1.1b *stage 1*'s, and stage 2's `joinNodes` rewrite sped the old build
up as a side effect nobody measured. Measured in the current tree, three runs each: **2.60 ms
at 1 MB and 25.72 ms at 10 MB**, against the new build's 1.9-3.9 and 20.9-24.5.

So M1.2's bulk loader is worth roughly **10-25% at 1 MB and ~17% at 10 MB**, not the ~5x this
record's first draft implied by quoting the stale 91 MB/s as its "before". It is still the
right structure -- one linear pass, no recursion, and the shared bottleneck M1.3's marker tree
would otherwise inherit -- but the number was borrowed from an improvement stage 2 had already
made. The "~110 ms at 10 MB" that both this record and the test comments cited was never
measured at all; it was a linear extrapolation from the stale 1 MB figure.

Two consequences carried into the code: the perf bounds' comments no longer claim to catch a
revert to recursive halving, because they demonstrably do not (2.60 and 25.72 sit inside 6 ms
and 40 ms), and the linearity argument is scoped down to *gross* superlinearity, because the
old build was itself near-linear in practice (9.9x for 10x the input). **A bound that cannot
distinguish the change it was written to protect is a gross-regression tripwire; saying so is
the difference between a guard and a decoration.**

M5 was real. `cursorTraversalAllocatesNothing` compared `malloc_zone_statistics`'s
`blocks_in_use` before and after, which is a **net** gauge, and the mutation's arrays are
transient -- freed as frames pop. It is replaced by a deterministic check: the base address of
the array the cursor holds against the tree's own leaf array, so a copy is observable rather
than inferred. Re-run by the main conversation: the new test fails on the mutation with the
observed addresses alternating between two recycled buffers against the tree's distinct leaves.
Also recorded, because it cost the implementer a round: `Array(anExistingArray)` **does not
copy** in Swift, so the obvious form of this mutation is a no-op and proves nothing.

#### `B` stays at 6, and this time with a reason rather than a deferral

Stage 2 kept `B = 6` and named one event that could move it: the lazy cursor landing, because
iteration's preference for a larger `B` was measured on `chunks()`, the operation the cursor
would replace. It landed. Swept 4/6/8/12, three release runs each, medians:

| B | iteration 1 MB | iteration 10 MB | fast-path insert 1 MB | fast-path insert 10 MB |
|---|---|---|---|---|
| 4 | 10.55 ns | 8.82 ns | 7.38 us | 5.25 us |
| **6** | 3.65 ns | 5.78 ns | **4.20 us** | **5.65 us** |
| 8 | 3.03 ns | 3.14 ns | 8.17 us | 9.83 us |
| 12 | 3.75 ns | 2.69 ns | 8.30 us | 10.71 us |

**The cursor did not move the answer, and the reason is that it removed the cost that made the
iteration axis matter.** Iteration is now ~5x cheaper in absolute terms, so its residual
preference for a larger `B` (0.6 ns/chunk from 6 to 8 at 1 MB) is smaller than the within-binary
spread -- B = 6 measured 3.55/3.65/6.98 across three runs of the same binary. The fast path's
preference for 6 is a 2x effect and it is the typing path. Read the iteration column as "inside
the noise", not as evidence for 6.

**A process note, because it is the second time this shape of error has been made in this
project.** The first sweep pass omitted the fast-path axis and measured only iteration and the
general path. On that evidence B = 8 or 12 looks better and the answer inverts. Stage 2's record
already contains the same incident -- its first sweep measured only edit cost, would have picked
B = 8, and reversed when the fast-path axis was added. Measure every axis the change touches,
before deciding, remains the rule; knowing the rule did not prevent repeating the failure.

#### Deliverable D: declined again, this time with numbers

Stage 2 deferred the `Fragment.nodes` seam-merge decline to M1.2 "alongside the bulk loader,
where chunk fill is already on the table". Measured at two scales: scattered 20,000 edits gave
mean chunk fill 7.51, boundary-aligned 30,000 gave 8.18; at 100,000/150,000, 7.56 and 7.85.
Boundary-aligned is **not worse** than scattered here -- the opposite direction from stage 2's
reported ~12% degradation. Declined, with two caveats recorded rather than buried: the absolute
regime differs from stage 2's (fill ~7-8 against its 38-52 plateau), and stage 2's exact
offset-selection code was never committed, so this is a reconstruction whose fidelity to that
methodology is unverified. What did not change is stage 2's own reasons: no real editing
workload aligns every edit to an internal chunk boundary, and the fix adds an O(h) descent to
the seam path that produced that milestone's one high-severity defect.

#### Three pre-existing defects this milestone's measurements exposed

None was introduced here; all three were found because M1.2 ran the perf suite, and the
inlining guard, far more than usual. (This heading said "Two" over a list of three until a
cold read counted them -- the same self-referential miscount stage 2's record made about its
own review rounds. The handover now names it as a thing to check; it did not until a cold read
observed that this sentence claimed it did.)

1. **Two perf bounds were set from the wrong distribution.** `bulkBuildThroughput`'s 1 MB bound
   (3 ms) and `scalingRatio`'s fast-path bound (10 us, from M1.1b) were both taken from the
   benchmark run *alone*, while both are only ever executed as part of the whole suite, where
   the earlier benchmarks leave the allocator in a different state. Run alone, 1 MB builds in
   1.72-1.94 ms; run in-suite, 1.85-3.86 ms on identical code. **Three of six whole-suite runs
   failed on code that meets its target**, and the fast-path bound failed two of six at 10.26 and
   10.39 us. A gate that cries wolf on a third of runs stops being read, which is worse than no
   gate. Both bounds are now set above the observed whole-suite spread and still far below what
   they guard. For the fast path that is real headroom: 25 us against the 200-627 us cost of
   the leaf-local path regressing. For the build it is **not** -- see M4 below, which found
   after this paragraph was written that the recursive-halving build costs 2.60 ms and 25.72 ms
   here, inside both bounds, so those two are gross-regression tripwires rather than guards on
   this specific change. Ten consecutive whole-suite runs green afterwards.
   **The rule, which matters more than the two numbers: a performance bound is set from the
   distribution the assertion is actually executed in, not from the cleanest way to run it.**
   The next benchmark added here will otherwise be given a third such bound by the same method.
2. **A ratio assertion that fires more readily the healthier its numerator gets.**
   `bulkBuildThroughput` divided two independently noisy measurements to check linearity, so a
   *good* 1 MB number made the ratio more likely to breach -- one run failed it while the 1 MB
   median was a healthy 2.3 ms. Removed. Linearity is now carried by the two absolute bounds
   together: 40 ms at 10 MB is tighter than ten times the 6 ms bound at 1 MB, so a *grossly*
   superlinear build cannot pass both. (10 MB was raised from 30 ms to 40 ms after this
   paragraph was written, for the same calibration reason as the 1 MB bound; and M4 below
   narrows what this argument is entitled to claim, because the build being replaced was itself
   near-linear.) Asserting absolutely at both sizes rather than as a ratio is already this
   file's stated rule; the ratio was a lapse from it.
3. **`dev/check-inlining.sh`'s body-length counter mis-attributed.** Its awk set `where` on the
   hot and cold probe headers and never reset it, so anything appended after the cold probe was
   silently counted into the cold body -- adding the warm probe took cold's count from 12 to 24
   and the script complained about the *cold* probe. Rewritten to classify each header and fail
   loudly on an unrecognised one.

#### Declined, with the reason (five cold-read rounds; the fifth found nothing)

Rounds: three parallel reviewers on the first batch (14 findings), then 2, 2, 2 and a decline.
Everything below was reported and deliberately not acted on. `CLAUDE.md`'s rule is to fix an
incorrect *fact* and record a disagreement about *wording*; each of these is the second kind.

- **Tests hard-code `6` where `branchingFactor` is in scope** (`bulkLoaderFillTarget`,
  `cursorTraversalSharesLeafStorage`, and the `[0, 1, 5, 6, 7, 12, 13, 50, 6000]` fixture).
  A DRY violation, but each site carries a comment saying `B = 6`, and the reviewer's own
  analysis is that a changed `B` makes them fail loudly rather than pass silently.
- **4.2's original sentence ("the containing type becomes `public`") was not rewritten in
  place**, only superseded by the amendment below it. That matches this file's convention of
  appending corrections rather than overwriting history, and the reviewer said so while
  raising it.
- **`SumTreeCursor.root` carries `@usableFromInline` without being referenced by any
  currently-`@inlinable` member** -- harmless over-promotion, consistent with the type's other
  stored properties. The reviewer rated this "not a bug" and flagged low confidence that it
  was even unintentional.
- **The same measurement is quoted at two precisions**, `1.85-3.86 ms` and the rounded
  `1.9-3.9 ms`. Both are true. Observed by the main conversation's own numeric sweep before
  round 5 and left alone: rounding is not an incorrect fact, and this milestone's rounds 3-5
  are a demonstration of what treating wording as fact costs.

#### What the main conversation got wrong

- **Three times, a `grep`-filtered pipeline was used to judge whether tests passed, and three
  times it hid the answer.** Once it filtered out pass/fail and kept only numbers, so a run
  whose assertion breached its bound was reported as a measurement. Once a build failure
  produced no matching line at all and eight "verification runs" that never compiled were
  reported as running. Once it captured only one benchmark's lines and missed a second failing
  assertion entirely. All three share a root: **treating "no failure text found" as evidence of
  success.** Count passes positively (`grep -c` for the success line, compare with the number of
  runs) -- absence of a match is not a green.
- An earlier `swift test ... | tail -40` made `$?` the exit code of `tail`, marking a killed
  mutation as survived.
- 4.5's complexity table and M1.6 both exist because this spec's reconnaissance found M1's
  definition of done pointing at a table that was never written, and a criterion (the 2 GB
  read-only open) that belonged to no sub-milestone. Both are now in 4.5 and section 8.

### M1.3: the marker tree -- done 2026-09-10

`Sources/Text/MarkerTree.swift` and `Sources/Text/BufferSnapshot.swift`, with
`Tests/TextTests/markerTreeTests.swift` and `markerTreePerfTests.swift`; spec in
`dev/specs/m1.3.md`. The one edit to shared machinery is a comment in `SumTree.swift`, whose
`pathCopyEdit` precondition said `Rope.tryLeafLocalReplace` was its only caller's caller.

**The design.** Markers are gap-encoded in a `SumTree<MarkerRecord>` ordered by a doubled key
`2 * byteOffset + biasRank`, where `.left` is GNU's `marker-insertion-type nil` and `.right`
is `t`. Two things fall out. Because gaps are relative, "shift every marker at or after K"
changes exactly one item, so it is one `pathCopyEdit` descent. Because the key is doubled,
every `.left` marker at a position sorts immediately before every `.right` one there, so the
whole of GNU's insertion-type behaviour is a choice of which number to seek to -- no bias
dimension in the summary, no O(m) split of a tie group. Nothing in `SumTree.swift` or
`SumTreeCursor.swift` changed: `Summable` needs one associated type and one `var summary`,
and a `private struct` in a test file already conforms.

4.5 said "lazily propagated offsets". That was amended: **the requirement is the complexity
bound, not the mechanism.** True lazy propagation conflicts with persistence -- pushing a
pending delta into children mutates nodes older snapshots share, and path-copying the
push-down makes it not lazy, only a differently spelled path copy -- and it would need a slot
on `Node`, which the rope shares and `dev/check-inlining.sh` guards by name. Relative
encoding is the persistent equivalent.

**The spec was wrong about the edit rule, and the implementer caught it by running the
oracle.** The spec described `applyEdit` as one fused pass with `delta = 2 * (L - (hi - lo))`.
That does not reproduce the spec's own `replace-at-marker` oracle row: a `.right` marker at
`lo` (key `2*lo + 1`) falls in the fused table's "unchanged" row, but GNU puts it after the
inserted text. **GNU has no atomic replace primitive with its own marker rule** -- a replace
is a delete then an insert, each adjusting markers by its own rule, so a marker that survives
the delete sitting at `lo` is afterwards indistinguishable from any other marker there and is
pushed by the insertion. The implementation is that two-stage composition. A second
correction came with it, not oracle-checkable because GNU exposes no order among markers tied
at one position: the collapse must repartition markers *already* at `lo` together with those
collapsing in, or a newly-collapsed `.left` marker (key `2*lo`) lands after a resident
`.right` one (key `2*lo + 1`) and breaks non-decreasing key order. The cold read reproduced
both and built the counterexample for the second.

**Scope: no resolution by marker identity, and 4.5's table now says so.** The tree is ordered
by position; an edit is a contiguous range in position order and an arbitrary subset in ID
order, so no ID-ordered index absorbs an edit in less than O(k) unless what it stores is
shift-invariant, and the only shift-invariant quantities are rank (destroyed by marker
creation) and relative order (needs order-maintenance labelling plus a persistent ID map --
a milestone of its own). No M1.4 or M1.5 client asks for it. 4.5's "Marker lookup" row was
ambiguous between positional and identity lookup; it now names the first and a new row gives
the second to M5. Without that split, "complexity benchmarks match the table in 4.5" was
unauditable in the same way the table's absence was until 2026-09-09. `MarkerRecord` carries
`id` from the first commit so the later index has a target.

**Mutation pass: seven designed, six killed, one survived and the survivor was right.**
`shiftingSingleItem` guarded a `pathCopyEdit` with `rank(atOrAfterKey:) < count`. Removing it
broke nothing -- because `pathCopyEdit` returns `nil` when its predicate is never true and the
next line already handles that. The guard was redundant *and* cost a second full descent on
the path every edit takes. Removed. The spec's seventh mutation was aimed at the wrong
function: the guard that is load-bearing protects `SumTreeCursor.seek`, which really does
trap, and lives in `markers(in:)` -- where the cold read then found it had no test at all.

**Three measurement lessons, each of which produced a number that was recorded and wrong.**

1. **The instrument could not resolve the quantity.** `insertBeforeAllMarkers` timed each
   sample with `Date()`, whose smallest non-zero tick here is **0.954 us**, and reported means
   of 0.5-1.1 us. Every sample was zero or one tick; the "mean of 30" was the fraction that
   straddled a tick. The tell was 10k and 100k printing the *identical* value to 13
   significant figures, which the implementer flagged as out of scope rather than passing
   over. `RopePerfTests.conversionCost` had the same defect and M1.2's row in 4.5 quoted its
   output; both are corrected here.
2. **ARC put an O(n) teardown inside the timed region, invisibly.** `let base` was bound
   outside the sample loop and last used inside it, so the release landed before the closing
   clock read, charging 30 edits with one whole-tree destruction. Hence 70-133 us at 1M. Four
   independent checks settled it: elapsed time is affine in the sample count (slope 1.11
   us/sample, intercept 2.90 ms at 1M); a 200-iteration warm-up changes nothing; teardown
   measured directly is 1.7-2.8 ms at 1M; and one statement keeping `base` alive drops 1M from
   95.91 us to 1.07 us. This also explains a spread this record previously attributed to suite
   composition: **where the optimiser places that release is not stable**, so the same binary
   read 0.89 us in one process and 3.64 in another.
3. **Counting beat timing.** Node visits were counted by hooking the predicate closures, no
   product change: `pathCopyEditNode` recurses into one child per level, so visits are
   `height + 1` -- **4 / 5 / 6 at 10k / 100k / 1M**, and 20-34 summary comparisons for an edit
   anywhere in the tree at every size. Those counts are a one-off diagnostic: the hooks
   lived in the investigation's worktree, and no shipped test re-counts them. Two timing attempts were wrong and one count was right
   the first time. A count is exact, cache-independent, and immune to where ARC puts a
   release; prefer it whenever the claim is about a complexity class.

The honest wall-clock numbers, after both fixes, from the shipped test's own runs on this
machine rather than from the investigation's worktree: **1.02-1.06 / 1.13-1.24 / 1.58-1.66
us** at 10k / 100k / 1M over four whole-file runs, 1000 samples, random offsets, release,
base held alive -- about 1.6x across two decades against `log2`'s 1.5x. The bound moved from 1000 us to **10 us**, which has power against a
constant-factor regression instead of only against a fall to O(n).

**What the cold read found, beyond the two above.** `BufferSnapshot.init(text:markers:)` set
`nextMarkerID = 0` regardless of the IDs already in the tree it was handed, so every caller
would reissue colliding IDs; it had no callers and the spec never asked for it, and it was
deleted rather than patched, on the same reasoning that kept `Anchor` out. The widened
collapse group and the `markers(in:)` guard both had no directed test and now do. The
differential generator drew deletions from `Uniform[0, 64]` against insertions from
`Uniform[0, 7]`, about **-28.5 bytes per operation**, so the buffer collapsed to single digits
almost immediately and the million-op run spent its time on an 8-byte buffer -- which also
explains the 12-minute debug run better than "debug is slow" did. Rebalanced, and the test now
asserts the distribution it reached so the degeneracy cannot return unnoticed. A memory figure
of 3.24 bytes per marker was printed for a 16-byte record; it was an allocator-state artifact,
now 22.05-22.06 bytes per marker with a `MemoryLayout<MarkerRecord>.stride * n` floor assertion under it.

**Two findings from the last review round recorded rather than acted on.** The
`withExtendedLifetime` added to `conversionCost` is described as "the number did not move
outside noise"; the before-sample was two runs, which is thin, and the 10 MB range widened
downward (0.97-0.98 to 0.70-1.00) rather than staying put. Read-only reading cannot settle
whether that is noise or a small real effect, the comment already hedges it, and nothing
depends on the answer -- the bound is 60x looser than any mean. And `markerSpan > 200` is a
bare constant in both differential tests while every other threshold beside it scales with
`maxBufferLength`, whose values differ 8x between the two files; it is a degeneracy floor
either way, so the inconsistency is style, not a defect.

*Round 5 of the cold read reported nothing fix-worthy, which is what closed this milestone.*
It re-derived the collapse arithmetic (2.03 ms / 100,000 = 20.3 ns), confirmed the file now
holds one authority for bytes per marker, and left one note recorded rather than acted on: a
161-character doc-comment line where the rest of the file wraps near 100. `swift format lint
--strict` does not flag it because it does not reflow `///` trivia, and it is formatting, so
it is recorded here instead of buying another review round. This entry transcribes that
round; it is the loop's terminator, not a new batch.

**Five rounds, and what each one cost.** Round 1 read the milestone and found eight things,
two of them real defects. Rounds 2 through 5 read only what the previous round's fixes
produced, and the top finding in three consecutive rounds was **a number that disagreed with
another copy of itself**. The pattern is worth naming because it beat three separate attempts
to stop it: a figure gets restated somewhere convenient, the restatement drifts or rounds
differently, and then someone -- usually the main conversation -- copies the restatement
rather than the source. The bytes-per-marker figure went source (22.050960-22.064304) ->
loose restatement in a neighbouring comment (22.05-22.07) -> `PLAN.md`, twice. Correcting
`PLAN.md` did not help, because the restatement was still there to be copied again; the fix
that worked was deleting the restatement so the sentence points at the measurement instead of
repeating it. **A number should exist in exactly one place, and every other mention should be
a pointer to it.**

**Follow-up, 2026-09-10, after the milestone closed.** The node-visit counts above were the
only direct evidence for the O(log n) claim and were not reproducible, which left a specific
hole rather than a theoretical one: the perf bound is 10 us against 1.58-1.66 us at 1M, about
**6x of headroom**, so a regression doubling the visit count from 6 to 12 would roughly double
the time and still pass -- and M1.4's interval tree is the second client of the same shared
machinery. `nodeVisitsAreHeightPlusOne` now counts them in the **ordinary** suite, so every
`dev/gate.sh` run holds the line: counting needs no release build, no warm-up and no sample
loop, and costs 0.53 s. It derives the expected count from the tree's own `height` rather than
hardcoding 4/5/6, so it cannot go stale if the packer's fill changes.

Two things about it are worth keeping. The first design -- a replica of the descent plus an
agreement check on the resulting marker positions -- **would have been worthless**, and the
implementer said so rather than building it: a replica walking the real `Node` structure
reports `height + 1` from the uniform-leaf-depth invariant alone whatever the real descent
does, and comparing results cannot see a regression that visits extra nodes and still returns
the right answer, which is the entire failure mode. The shipped test instead feeds a counting
predicate to the **real** `SumTree.pathCopyEdit`. Second, the mutation that matters was run
and it fails: descending into one extra child per level and discarding the result -- visits
roughly double, the answer is unchanged -- is caught. A third mutation was designed by the
cold read against **its own reasoning** (shrink the leaf in the test's edit closure; predicate
calls precede `edit`, so the count must not move) and the count did not move.

**Standing risks.**

- **Dropping a marker tree is O(n)**, 1.7-2.8 ms at 1M and 4.9-8.9 ms at 3M, paid
  synchronously by whoever releases the last reference. `SumTree.swift` recorded only that
  teardown does not recurse deeply, which is true and orthogonal. 4.5's "Close a large buffer"
  row now carries the cost. M1.5 and M1.6 hold many snapshots at once.
- **An ARC release can move O(n) work into any timed region and the source will not show it.**
  `RopePerfTests.generalPathInsertCost` was checked the same way and is unaffected.
- `RopePerfTests.scalingRatio` had the milder form of the `Date()` defect (2.5-4.8 ticks per
  sample) and was re-instrumented; its ratio still varies 1.04-2.23 between runs, which is why
  the file pairs it with an absolute bound.
- The 10 MB rope conversion grows about 2.2x per decade against `log2`'s 1.17x. Nothing
  depends on it and it is far inside its bound, but it is a measured shape 4.5 calls O(log n)
  and nobody has explained it.
- **The memory measurement is still sensitive to allocator state**, and the floor assertion is
  what makes that visible instead of silent. Adding a 3M size to the edit benchmark -- tried in
  the last fix round, and cheap in wall clock -- made `memoryForOneMillionMarkers` report
  **13.44 bytes per marker** in one run of two, below `MarkerRecord`'s own 16-byte stride;
  without it, the test's own runs sat at 22.05-22.06. The 3M size was dropped for that reason,
  not for cost. Anything that changes this suite's composition can move that number.
- **The 3M figures this record quotes are one-off diagnostics**, from the worktree investigation
  that found the teardown bug -- 1.29 us per edit and 4.9-8.9 ms teardown. No shipped test
  measures 3M, so a 3M-scale regression has nothing to catch it, and those numbers cannot be
  re-derived by running the suite.
- Marker offsets must be UTF-8 scalar boundaries, and that precondition is untested by
  construction -- every randomised test draws from a rope's valid boundary set, so reaching the
  trap needs an out-of-process crash harness this project does not have, exactly as
  `Rope.swift` already records for its own.
- A snapshot is a value, so forking one and editing both branches reuses marker IDs. M1.5's
  branching undo must decide the allocation story.


### M1.4: the interval tree for overlays -- done 2026-09-11

`Sources/Text/IntervalTree.swift`, one new generic primitive in `SumTree.swift`, and the third
field of `BufferSnapshot`, with `Tests/TextTests/intervalTreeTests.swift`,
`intervalTreePerfTests.swift` and four `visitItems` tests in `sumTreeTests.swift`; spec in
`dev/specs/m1.4.md`. Gate: `Test run with 179 tests in 19 suites passed` -- *corrected
2026-09-11 (M1.5 reconnaissance): this line and the handover both read 178. A clean-tree run at
`48b3239` gives 179 planned (164 run, the rest skipped by the perf tag and the allocation
probe's `.enabled(if:)`, which swift-testing still counts in the total). **The cause is not
determinable from the history** and the first correction guessed at one: it said the 178
predated a trailing round that added `largeResultOverlapQuery`, but `git log -S` puts that test
in `08e7758` with the rest of M1.4's code, and `48b3239` touches only this file, so the test set
is identical across both. What is verifiable is that the quoted line disagrees with a run of the
tree it describes -- most likely captured mid-milestone and never re-run before the record was
committed, which is a guess and is labelled as one.*

**The design.** Intervals are ordered by start in a `SumTree<IntervalRecord>`, the start
gap-encoded as `MarkerTree` does and the extent stored as a **length**, so an interval entirely
after an edit needs no visit at all -- shifting its start shifts its end for free -- and only
the ones straddling the edit point, whose extent genuinely changed, are touched. The summary
augments the order statistic and the prefix sum with `maxEnd` **measured relative to the range's
own base**, which is what keeps it shift-invariant; it is a monoid with `max(a.maxEnd, a.span +
b.maxEnd)`, and the right identity law needs the invariant `maxEnd >= span`, which
`checkInvariants()` asserts on every node. No doubled key: the insert stage rebuilds the tie
group at the insertion point anyway, so it stably partitions it into non-movers then movers and
one gap edit finishes the job.

**Three things the GNU oracle said that nobody would have guessed, all now in 4.5's prose and
in the tests with their transcripts.** `insert-before-markers` **overrides both** advance flags
-- the funnel already carried the flag for markers and it turns out to apply to overlays too.
An empty overlay with `front-advance` and not `rear-advance` would **invert** under the naive
per-endpoint rule (GNU keeps it still); the implementation expresses that as a conjunct of
`startMoves` rather than as a clamp applied after a shift, because the tree stores a gap and a
length, so there is no representation in which one endpoint moves alone. And `overlays-in`'s
docstring is simply wrong for an empty query range: `(overlays-in 5 5)` returns a *non-empty*
overlay containing 5, which shares no character with the region. Deletion, by contrast, is
**independent of both flags** across all twenty combinations, and a replace is a delete then an
insert -- M1.3's lesson, re-verified here row by row.

**Seven rounds of cold review on the spec, before a line was written.** They caught two defects
that would have become wrong code, and both had already survived my own reasoning. First, the
mover rule: "the tie-group members with `frontAdvance`" sweeps up the empty interval the clamp
exists to protect, and one gap edit cannot express the exception, which is what forced the
predicate form above. Second, the query prune: my first draft was strict and lost an empty
interval sitting at `lo`; the fix relaxed it to `maxEnd >= lo` and **destroyed the complexity
claim** -- `M` intervals all ending at `M`, queried at `lo == M`, return nothing while every
leaf survives the prune. The answer was not a third threshold but the three-piece decomposition
now in 1.6, each piece output-sensitive on its own. The remaining rounds found a restated bound
that had dropped a term (the failure this file names as the top finding of three consecutive
M1.3 rounds, caught this time before it reached `PLAN.md`), and four cases of a test being
weaker than the mutation it was supposed to observe -- including that test 8's fixture would
catch a broken `maxEnd` combine or not **depending on which order the author happened to type
two intervals sharing a start**.

**What the cold read of the implementation found.** Three things, all real. The query was
**O(k log n), not O(log n + k)**: pieces 1 and 3 reconstructed the running absolute start with a
fresh root-to-leaf `find` per scanned item, while the cursor was already handing back the record
whose `gap` is exactly that delta -- a defect against the milestone's central claim, invisible
to every counted test because those instrument `visitItems` and this path does not use it. The
visit-count test **could not see the mutation it exists for**: it fed `SumTree.visitItems` a
`descendInto` closure hand-written in the test, so relaxing the real prune changed nothing it
looked at; both prunes are now `internal` factory functions and the tests wrap those. And
`checkInvariants()` **folded with the operator it was checking** at interior nodes, so a wrong
combine agreed with itself; it now recomputes with explicit arithmetic and catches that class at
every level. A dead `firstRankWithEndAfter` with a real double-counting bug in it was deleted
rather than fixed.

**Mutations: twelve designed, twelve killed, and two of them earned their keep.** Ten came from
the spec, two from the reviewers. Making the insert stage's prune **strict** -- the deviation the
implementer flagged and asked about -- kills three oracle tests and the differential, which is
the evidence that the non-strict prune is necessary rather than sloppy: an interval whose end
lands exactly on the insertion point still moves when `rearAdvance` holds, and a strict prune
discards it unvisited, silently losing a `length` update. Its cost is the `e` term in 4.5's new
row. The other one that mattered was the tie-group mutation, which the differential killed by
trapping while `tieGroupPartitionKeepsOrder` -- the test written for exactly that -- **passed**:
its fixture put the group at rank 0 with a non-mover first, where the rebased gap and the item's
own gap coincide. The fixture now has an interval before the group and a mover first, and the
mutation fails it on two expectations. That is the second time in two milestones that a test
named in a spec turned out to be blind to the mutation it was named for, and both times only
running the mutation showed it.

**Numbers live in 4.5's two rows** -- the query and the per-edit adjustment, both measured on
this machine in release over three whole-file runs -- and nowhere else in this record. The
trailing round caught the new edit row's headline bound **dropping its `e` term**, in the same
record whose paragraph on the spec's review rounds, three above this one, congratulates itself
for catching that failure before it reached `PLAN.md`. It reached `PLAN.md`; a cold read took it out again. The same round found the
query fix had no regression test at all -- the defect it repaired is invisible to every
correctness test and to every counted one -- which is what `largeResultOverlapQuery` now is.

**The last trailing round's findings, transcribed rather than acted on.** It found the record's
self-reference above off by one paragraph and the new perf test's comment claiming a tree height
of 6 or 7 where the bulk build gives 4 — both facts, both corrected. Its third finding is
recorded and declined: `deleteStraddlerVisitsAreOutputSensitive`'s comment says its fixture
differs from the query test's in "its rank restriction", where strictly the rank restriction
(`prefix.count < upperRankExclusive`) is identical in both and what differs is the visit
closure's boundary on the absolute start (`<= lo` against `< lo`, matching `applyDelete`'s own).
The substance of the sentence is right and the distinction is a matter of naming, so it stays.
The round after that one reported nothing to change, which is what closed this milestone: it
re-derived the tree height from `SumTree`'s own bulk build, recounted the paragraphs, and left
one note recorded rather than acted on -- a 132-character line in this section where the rest
wraps near 90. `swift format lint` does not reflow Markdown, and it is formatting, so it is
written here instead of buying another round. This paragraph transcribes those two rounds; it is
the loop's terminator, not a new batch.

**Declined, with the reason.** Sampling `checkInvariants()` every hundredth edit in the
differential cannot see a violation that a later path-copy overwrites before the next sample and
that the round's own query does not hit; no schedule closes that class, per-round checking costs
20,000 whole-tree folds in a debug gate run, and none of the twelve mutations depends on it. The
"after every edit that empties an interval" trigger does not fire on the edit that makes two
already-empty intervals adjacent; same class, and the trigger is a cheap improvement rather than
a claim of completeness. `maxEndInvariantIsChecked` hand-builds one malformed leaf and so cannot
be killed by any mutation of the combine operator -- it exists to prove the checker can fire at
all, which is the `sumTreeTests.swift` negative-test precedent, and the query tests carry the
real duty. One wording finding on the repair committed as `2820c79` is recorded in that commit's
message.

**Standing risks.**

- **Text properties are not on this tree yet.** The stickiness oracle is in the spec so it is not
  rediscovered: text properties default rear-sticky and not front-sticky, the *opposite* default
  from an overlay's `(nil, nil)`, and `insert` never inherits while `insert-and-inherit` does.
- **Identity lookup is still O(n) without the caller's start offset**, and 4.5's table gives it
  to M5 with the obstruction argument from `dev/specs/m1.3.md` section 3. `removing(id:startingAt:)`
  takes the start so the caller pays O(log n + tie group).
- **A snapshot is a value**, so forking one and editing both branches reuses interval IDs, the
  same gap `MarkerTree` records; M1.5's branching undo owns it.
- **The `e` term has no test.** The insert prune's cost is documented and bounded but neither
  counted nor timed; a regression that widened it would not fail anything. Its neighbour did get
  one: `largeResultOverlapQuery` guards the query scan's `O(log n + k)`, with the pre-fix
  behaviour measured for contrast in 4.5's row. `e` would need the same treatment -- a fixture
  with many intervals ending exactly at the insertion point -- and does not have it.
- Interval endpoints must be UTF-8 scalar boundaries, and like `MarkerTree`'s that precondition
  cannot be reached by a test without an out-of-process crash harness this project does not have.


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
claim. The final round found nothing to change; its predecessor's one open item, that "do not
reason about its scope from anything written here" sits oddly beside three scope observations,
is recorded and not acted on -- the sentence after it already says they are observations and not
a rule.

---

## Handover: how to resume, updated 2026-09-11 (M1.5 spec complete, not implemented)

**Read this first, then start.** `CLAUDE.md`, then `dev/specs/m1.5.md`, which is the whole
briefing for the work in flight. Do not re-read `PLAN.md` whole. **No line counts, diff sizes or
measured figures are restated here** -- a cold read of the first draft of this section found
three of them already wrong or drifting, which is the failure this file documents at length; the
spec holds each number once and this section points at it.

- **State**: M0 through M1.4 are done with records in section 11. The gate is green on a clean
  tree at `48b3239` (`Test run with 179 tests in 19 suites passed`; the M1.4 record's 178
  disagrees with a clean-tree run of the very tree it describes, the cause is not determinable
  from the history, and both copies are corrected in this working tree). **Nothing of M1.5 is
  implemented.** The spec and this section are committed; nothing else is in flight.
- **What exists for M1.5**: a reconnaissance pass (the edit funnel, a GNU Emacs 30.2 undo oracle
  harvest, Reticle's undo implementation, this project's verification conventions), an architect
  pass that settled six design questions with measurements taken in an isolated worktree, and
  **seven waves of cold review on the spec -- eleven reviewer dispatches, one of which died on
  an output-token limit having written nothing and was re-sent as two narrower ones.** Every
  finding is written into the spec at the point it applies, with "a review round found..."
  saying why the text is the way it is, so the spec is self-contained and the scratchpad copies
  of the review records are disposable. A first draft of this section said "nine rounds" and a
  cold read could not confirm it; this is the countable version.
- **Where the review loop stopped, and why that is the terminator.** The final wave's two
  reviewers found a dangling test reference, deliverables filed under the wrong stage, three
  self-referential counts in this section that were wrong, a too-wide restatement of a measured
  range, an unfounded causal claim about the M1.4 test count, and one unhandled contradiction
  with the older handover below. Acting on those produced **mechanical repairs only** -- a test
  reference repointed, deliverables re-lettered and re-staged, two wording softenings, one
  fixture clause, and the deletion of the numbers named above -- **making no new design claim,
  which is what ends the loop.** That batch is `git show` on the spec commit; if you judge
  otherwise, it is the batch to send.
- **What the spec decided that 4.5 still contradicts.** 4.5's undo bullet is wrong in three of
  its four clauses and the spec's section 5 lists the edits: there is **no 300 ms window** (the
  oracle shows command identity plus a count of 20 plus a fixed 10-second safety-net timer, and
  Reticle used a character count -- the 300 ms figure was pellicle's own invention recorded as a
  port), there are **no retained snapshot checkpoints** (the spec's 1.1 carries the measured
  per-transaction cost of each representation with the fixture it was measured on -- a cold read
  caught this section restating that range too widely and dropping the fixture, so it is not
  restated here -- and the decisive argument is not the ratio anyway but that restoring a
  snapshot un-creates every marker and interval made since, which GNU never does), and grouping
  by command is M5's policy over M1.5's mechanism. Native branches survive, and an undo-tree UI
  being a view is strengthened.
- **Two stages, and the second one's spec is deliberately not written yet.** Stage 1 is the
  representation and its correctness. Stage 2 is the pruning policy, and it gets
  `dev/specs/m1.5-stage2.md` written against the built structure with mutations actually run.
  Four consecutive review rounds each found a real defect in the previous round's repair of that
  one section, every one of them there and nowhere else in the spec; it is the only part of M1.5
  with no oracle, no measurement and no precedent in the tree to check a draft against. 1.9
  lists what stage 2 inherits as settled and what stage 1 builds for it. `m1.1b-stage2.md` is
  the precedent.
- **The older handover below is stale about this, deliberately left in place.** The M1.4 section
  still describes M1.5 as "300 ms window ... edit logs plus retained snapshot checkpoints",
  which is what M1.5's spec overturned. Old handovers are kept as written rather than edited, so
  read this section and not that one; a cold read caught the first draft of this bullet
  addressing only 4.5 and not the neighbour.
- **How to run it**: the eight-step loop in `CLAUDE.md`, starting at **step 3 (implementer)**
  for stage 1. The spec's section 7 carries the fixed clauses and its section 2 the file scope
  and the deliverables A-K; the ID migration is its own commit.
- **The lesson this spec paid seven waves for, and it is the same one as M1.3's and M1.4's.** A
  test named in a spec as the one that catches a mutation is a hypothesis until the mutation is
  run -- and a *spec* claim is a hypothesis until something checks it. The reviews found two
  cells of a seven-row case table wrong, a named test that a concrete counterexample showed was
  blind, a mutation whose kill scenario was unreachable, an API assumption that cannot be
  implemented (`removing` traps rather than skipping), and a silent regression no test could see
  (re-insertion reverses a tie group). None of that would have been cheaper to find in code.


## Handover: how to resume, updated 2026-09-11 (M1.4)

**Read this first, then start.** `CLAUDE.md` plus the newest record in section 11 is the whole
briefing; nothing else needs reading to begin, and `PLAN.md` must not be read whole.

- **State**: M0, M1.1, both stages of M1.1b, M1.2, M1.3 and **M1.4** are done, each with a
  record in section 11. The gate is green (`Test run with 179 tests in 19 suites passed`, plus
  the isolated allocation probe `dev/gate.sh` now runs after it). Working tree clean.
- **Next work item**: **M1.5**, undo -- transaction-based, grouped by command and by a 300 ms
  window, edit logs plus retained snapshot checkpoints, branches native so an undo-tree UI is a
  view (4.5). Then M1.6, the line-indexed mmap view for huge read-only files, which is the last
  criterion in M1's definition of done that no sub-milestone owned until 2026-09-09.
- **What M1.5 inherits.** `BufferSnapshot` now pairs `text`, `markers` and `intervals` through
  **one** edit funnel; a fourth thing joins it there or not at all. Do not add a `clock` until
  something reads one -- M1.5 is the first milestone that plausibly does, and that is a decision
  to make on its own evidence rather than by inheritance.
- **Two things M1.5 must decide that M1.3 and M1.4 both deferred to it.** A snapshot is a value,
  so forking one and editing both branches **reuses marker and interval IDs**; branching undo is
  exactly that fork, so it owns the allocation story. And dropping a tree is O(n) in its distinct
  nodes, paid synchronously by whoever releases the last reference -- undo holds many snapshots
  at once, so the cost of releasing a chain of them is M1.5's to measure, not to assume.
- **Do not redo these.** Identity-based resolution is deliberately absent from both trees and 4.5
  gives it to M5. The item-merge hook on `Summable` was voted down by M1.4 and the chunk-packing
  gap it would have fixed stays deferred. The insert stage's non-strict prune is deliberate and
  mutation-proven necessary; its cost is the `e` term in 4.5's row.
- **The lesson M1.4 paid for twice, and M1.3 once before it.** A test named in a spec as the one
  that catches a mutation is a **hypothesis until the mutation is run**. Both milestones had a
  test that looked exactly right and was blind -- M1.4's because its fixture put the tie group
  where the correct and incorrect gap coincide, and its visit-count test because it compared
  against a hand-written copy of the predicate instead of the real one. Run every mutation the
  spec lists, and when one dies in a test other than the named one, that is a finding about the
  named test, not a bookkeeping detail.
- **Check every count a record makes about itself.** Still true, still cheap. This handover's own
  test count was wrong for a day.
- **How to run it**: one sub-milestone at a time through the eight-step loop in `CLAUDE.md`. The
  spec is worth seven review rounds before implementation starts -- M1.4's caught two defects
  that would otherwise have been written, debugged and reviewed as code.


## Handover: how to resume, updated 2026-09-10 (M1.3)

**Read this first, then start.** `CLAUDE.md` plus the newest record in section 11 is the
whole briefing; nothing else needs reading to begin, and `PLAN.md` must not be read whole.

- **State**: M0, M1.1, both stages of M1.1b, M1.2 and **M1.3** are done, each with a record in
  section 11. The gate is green (`Test run with 150 tests in 17 suites passed`). Working tree
  clean. *(This line said 149 until 2026-09-11: the M1.3 follow-up commit added
  `nodeVisitsAreHeightPlusOne` and this handover was written from the pre-follow-up count --
  the milestone-record-counts-itself-wrong failure this file warns about, in the handover.)*
- **Next work item**: **M1.4**, the interval tree for overlays and text properties (4.5: one
  augmented tree with both start and max-end summarised, closing the gap Emacs 29's `itree.c`
  records as bug#58342; lookups O(log n + k)). Then M1.5 undo, M1.6 the line-indexed mmap view.
- **What M1.4 inherits from M1.3.** The generic `SumTree` needs no change for a new item type:
  `Summable` is one associated type and one `var summary`, and `MarkerRecord` demonstrates the
  whole pattern in `Sources/Text/MarkerTree.swift`. An overlay `Item` is the second client of
  the item-merge hook stage 2 deferred by name -- and note the correction in section 4.2: that
  hook **does not exist**, `combineUnderflowedSiblings` calls nothing on `Item`, so it is a
  thing to add if a client wants it, not a seam waiting to be satisfied.
- **`BufferSnapshot` is where the second tree hangs.** It pairs `text` and `markers` today and
  has one edit funnel, `replaceSubrange`, because that is the only place both the byte range
  and the inserted length are in scope. Overlays join it there. Do not add a `clock` until
  something reads one.
- **Do not redo these.** Identity-based anchor resolution is deliberately absent and 4.5's
  table gives it to M5, with the obstruction argument in `dev/specs/m1.3.md` section 3. The
  `rank < count` guard removed from `shiftingSingleItem` was redundant, proven by mutation.
  The `@usableFromInline` promotion is still not to be extended.
- **Four measurement rules this milestone paid for**, all in the M1.3 record with the
  incidents: `Date()`'s tick on this machine is **0.954 us**, so anything near a microsecond
  must use `DispatchTime.now().uptimeNanoseconds` batched around the whole sample loop;
  **ARC can place an O(n) release inside a timed region** and the source will not show it, so
  hold the fixture alive with `withExtendedLifetime`; **count the work rather than timing it**
  when the claim is a complexity class, because a count is exact and immune to both of the
  above; and **a number should exist in exactly one place**, every other mention being a
  pointer -- a restatement drifted and was copied three times before that was fixed.
- **Check every count a record makes about itself.** Still true, still cheap, still the
  likeliest defect to reach a commit.
- **How to run it**: one sub-milestone at a time through the eight-step loop in `CLAUDE.md`.
  The mutation pass and the gate belong to the main conversation; the implementer never
  verifies its own fix. Do not skip the trailing re-review -- M1.3 took five rounds and the
  fifth still found something.


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
