# GNU Emacs pain-point inventory and what Emacs 29–31 did about them

Research report for the swiftemacs planning run. Date: 2026-09-05.
Scope: every widely reported GNU Emacs pain point, its root cause, what upstream did in
Emacs 29/30/31, whether a from-scratch implementation can fix it *by design*, and the design
that fixes it. This is the spec behind the owner's requirement "solve every well-known pain
point of GNU Emacs".

Confidence legend: **[H]** confirmed from a primary source fetched during this run;
**[M]** from a secondary source or a search-engine summary of a primary source;
**[L]** plausible, not confirmed; see "Unverified" at the end.

Sources are cited inline; a consolidated list is at the end. Reticle
(`/Users/jerrychen/My_Projects/reticle`, read-only) is cited where its README documents an
approach that worked or a limitation the owner wants gone.

---

## 0. Executive summary

Almost every Emacs pain point traces back to five architectural decisions made in the
1980s and never reversed because ~40 years of Elisp depends on them:

| Root decision | Pain points it causes |
|---|---|
| **One thread owns everything** (current buffer, point, narrowing, redisplay, the Lisp heap, dynamic bindings) | blocking UI, no real async, no per-buffer threads, hooks/advice stall typing, TRAMP freezes, LSP stalls, package-update freezes, native-comp trampoline stalls |
| **Non-generational stop-the-world mark & sweep GC** with an 800 KB default threshold | GC pauses (56 % of surveyed users see >0.1 s pauses), the `gc-cons-threshold` cargo cult, startup cost |
| **Text-terminal display model** (character grid, `xdisp.c` ~38 k lines, everything is text in a buffer) | redisplay complexity, no GUI widgets, child-frame hacks, scrolling jank, long-line collapse, ligature/composition hacks, non-native macOS behaviour |
| **Terminal key encoding** (ASCII control chars, ESC = Meta prefix) | C-i = TAB, C-m = RET, ESC delays, ESC-ESC-ESC quitting |
| **Load-everything-at-startup Elisp with global mutable state and no sandbox** | slow startup, config fragility, package-manager churn, byte-compile warning noise, hook interaction bugs |

Upstream has spent 29→31 attacking symptoms, mostly successfully at the edges: long lines
(29), a native JSON parser that is 8–9× faster (30), native-comp on by default (30),
`read-process-output-max` 4 KB→64 KB (30), a native default process filter (30), tree-sitter
grammar auto-install (31), `process-adaptive-read-buffering` off by default (31),
minibuffer-nonselected-mode (31). The one structural fix — the incremental, generational
MPS-based GC ("igc") — **was explicitly excluded from Emacs 31** on 2026-04-30 and still
lives on `feature/igc3` as of August 2026 [H]. Multithreading has no path forward on
emacs-devel beyond thread-local point/narrowing proposals [H].

**Conclusion for swiftemacs:** all five root decisions are fixable by design in a new
implementation *provided the Elisp compatibility contract is defined narrowly enough*:
per-buffer actors with a single UI actor, a generational/incremental GC or ARC+cycle
collector with bounded pauses, a real layout engine instead of a character grid, a modern
key model that keeps a terminal-compatibility translation layer, and a lazy, sandboxed,
statically-analysable extension model. The cost is that GNU Emacs packages will not run
unmodified; Reticle already accepted that trade ("does not run GNU Emacs packages", Reticle
README).

---

## 1. Single-threaded, blocking UI

**Symptom.** Any long Lisp computation, synchronous process call, TRAMP operation,
package update or GC freezes the whole editor; "Emacs freezing for up to a minute when
updating packages" [M, HN 42198822]; Gnus "notorious for blocking everything" [M, HN].
Karthink: "Emacs can, as of today, only do one thing at a time. So every 'background' task
must, at some point, surface to the foreground and block Emacs for a bit." [H, Karthink,
*Cool your heels, Emacs*].

**Root cause.** Global C state: `current_buffer`, `PT`, `BEGV`/`ZV` (narrowing), the
specpdl (dynamic bindings), buffer-local C variables (`Vfoo` mirrors), redisplay
structures and the allocator are all process-global. Ihor Radchenko (emacs-devel, July
2023): "Only a single `main-thread' should be allowed to modify frames, window
configurations"; async threads would make `(set-buffer "1") (goto-char 100) (set-buffer
"2") (set-buffer "1") (= (point) 100)` invalid; buffer-local C variables mean "C code does
not need to worry about Vfoo being buffer-local or not" — so it cannot be thread-safe [H,
emacs-devel 2023-07 msg00358]. The 26.1 threads are "mostly cooperative": Emacs switches
only while waiting for keyboard input/process output, on `thread-yield`, or when blocked on
a mutex/`thread-join`; "only one thread runs at a time ... there is no parallelism" [H, Elisp
manual *Threads* (via mirror); LWN 755833]. Troy Hinckley: the existing threading library
"suffers from data races", "one of the reasons I believe it has not seen much adoption" [H,
coredumped.dev 2022].

**Upstream status 29–31.** No change to the model. Emacs 30 rewrote the default process
filter in C ("reducing GC churn") and raised `read-process-output-max` to 65536 [H,
NEWS.30]; Emacs 31 sets `process-adaptive-read-buffering` to nil by default [H, Mastering
Emacs 31.1]. These shave overhead; they do not remove blocking.

**Fixable by design?** Yes — this is the single highest-leverage design decision.

**Design that fixes it.**
- One **UI actor** (main thread) owns windows, frames, input and redisplay. Every buffer is
  an **actor** (Swift `actor` or a serial `DispatchQueue`) owning its text, markers,
  properties, undo list and its own Elisp *thread-local context* (current buffer, point,
  narrowing, match data, dynamic bindings). Radchenko's list above is exactly the set of
  per-actor state.
- Cross-buffer operations are **messages with copied or immutable payloads**
  (Hinckley: "The first time a sub-thread does a lookup of a global variable, its value is
  copied from the main thread"; "Messages can be passed to any thread and they can return
  a result"; functions shared and immutable) [H, coredumped.dev].
- Long-running Elisp is **preemptible**: an interrupt check every N bytecode
  instructions/every N tree-walk steps, with a per-hook time budget. Reticle proved this
  works: "An interrupt mechanism preempts both the tree-walker and the bytecode VM every 64
  steps. Hooks on the keystroke path run under a 50ms budget, and a hook that blows that
  budget three times is removed automatically with a named message" [H, Reticle README].
- **All I/O is async by construction**: processes, files, network, remote editing return
  futures/continuations; Elisp gets `async`/`await`-style primitives plus a
  compatibility `call-process` that runs on the caller's actor without blocking the UI actor.
- Redisplay reads a **snapshot** of buffer state (immutable rope/piece-table version) so a
  mutation in progress never blocks a frame.

Trade-off: `save-window-excursion`, `display-buffer` etc. must hop to the UI actor; code
that assumes "point is global" breaks. Document it as the compatibility boundary.

---

## 2. GC pauses (and the igc/MPS branch)

**Symptom.** Periodic freezes of 0.1–1 s; 129 users' `emacs-gc-stats` data: "56 % of users
experience pauses exceeding 0.1 seconds", "25 % ... over 0.2 seconds", some "near 1 sec";
"50 % of garbage collections occur less than 10 seconds apart"; GC "adds more than one second
to startup" for 50 % of submissions and 3 s for 20 % [H, EmacsConf 2023 gc talk].

**Root cause.** Non-moving, non-generational, stop-the-world mark & sweep over a single heap;
the default `gc-cons-threshold` is 800 KB, so collections are frequent; raising it makes each
pause longer and can cost "gigabytes extra RAM usage" [H, EmacsConf 2023; M, bling.github.io].
Every package config therefore carries `gcmh`/threshold hacks (Doom sets
`gc-cons-threshold` to `most-positive-fixnum` during boot and relies on `gcmh` afterwards)
[M, Doom docs].

**Upstream status.** Emacs 30 added `--disable-gc-mark-trace` "for about 5 % better garbage
collection performance" [H, NEWS.30]. The real fix, **igc** (Gerd Möllmann, Pip Cet, Helmut
Eller; Eli Zaretskii and Stefan Kangas co-maintaining) builds on Ravenbrook's MPS: "The new
GC is incremental and generational", configured with `--with-mps=yes|debug|no`, and "MPS
uses the SIGSEGV POSIX signal or its emulation as part of its normal operation"; macOS 13+
can use Homebrew `libmps` [H, README-IGC on feature/igc3]. Eli's April 2025 blocker list:
MPS distribution/patches not upstream, unsupported platforms, whether MPS "is still being
actively maintained", signal handling ("I'm not convinced the solution is the best one"),
"still FIXMEs in igc.c" [H, emacs-devel 2025-04 msg00857]. Sean Whitton, 2026-04-30: "This
means that, sadly, the new garbage collector will not be part of Emacs 31." [H]. The branch
is now `feature/igc3`, last updated 2026-08-06; a June 2026 status question got no roadmap
answer [H, emacs-devel 2026-06 msg00167/175]. (A search summary claimed igc "has landed in
master"; the primary sources contradict this — treated as false.) HN users testing it in
2024: "there are still crashes" [M].

**Fixable by design?** Yes.

**Design that fixes it.**
- Choose a GC with **bounded pause times** from day one: generational + incremental, with
  a nursery sized for a few ms of allocation and a write barrier in the object model
  (Swift can host this as an arena managed by the interpreter). Alternative: Swift ARC for
  Lisp objects plus a **backup cycle collector** (Reticle used Rc and admits "Reference
  cycles held entirely through external objects ... can leak" — so a cycle collector is
  mandatory, not optional) [H, Reticle README].
- **Per-actor heaps** (Section 1) make most collections local and small; only shared
  immutable data (functions, symbols, interned strings) lives in a global, rarely-collected
  space (Hinckley's design).
- No user-visible `gc-cons-threshold`; expose only telemetry (pause histogram) so the
  `gcmh` cargo cult never starts.
- Avoid MPS-style SIGSEGV barriers on macOS (Eli's stated discomfort; Mach exception
  handling complications [L]) — use software barriers in the interpreter.

---

## 3. Long-line slowness

**Symptom.** Historic: a single multi-megabyte line (minified JS, log dumps) made Emacs
unusable; `so-long` (Emacs 27) mitigated by switching modes off [M, GNU ELPA so-long].

**Root cause.** Redisplay and many commands walk from line beginning to point in O(n) of the
line, repeatedly; column computation, `beginning-of-line` scans, font-lock and bidi all scale
with line length. Eli's own diagnosis of the display engine: "one basic problem is the
completely unstructured, unidimensional representation" [H, quoted in *Why Rewriting Emacs Is
Hard*].

**Upstream status.** Emacs 29: "Emacs is now capable of editing files with very long lines
... should no longer choke"; `long-line-threshold`, `large-hscroll-threshold`,
`long-line-optimizations-region-size`; **and a real behaviour change**: in such buffers
"`fontification-functions`, `pre-command-hook` and `post-command-hook` hooks are executed
on a narrowed portion of the buffer" [H, NEWS.29]. This is a mitigation with semantic
side effects (hooks silently see a narrowed buffer).

**Fixable by design?** Yes, fully.

**Design that fixes it.**
- Store text in a **rope / piece table with line and column indices** (monoid sums per
  chunk) so position↔line↔column and width queries are O(log n) regardless of line length.
- **Layout is per visual line, lazily**: line breaking/shaping only for the viewport plus a
  margin; cache shaped runs keyed by (text version, face run).
- Font-lock and tree-sitter operate on **byte ranges**, never "from line start".
- No `long-line-threshold` special mode, no narrowing surprises.

---

## 4. Slow startup and package loading

**Symptom.** Multi-second startups; users measure `emacs-init-time` and adopt Doom/`gcmh`/
`early-init.el` tricks.

**Root cause.** (a) GC during load (see §2; "GC adds more than one second to startup" for
half the users). (b) `file-name-handler-alist` "is consulted during every require, load, and
file I/O operation" [M, Doom docs]. (c) `package.el` "loads all installed packages on
startup" and activates autoloads for everything [M]. (d) Hundreds of `.el`/`.elc` files
opened and evaluated; no image of the *user's* configured state — only the pdumper image of
the pristine Emacs (Emacs 31 removed the old unexec dumper entirely, keeping the portable
dumper) [H, Mastering Emacs 31.1]. Doom's counter-measures show what the platform lacks:
"generates an init-file, which concatenates all package autoloads ... into one elisp file";
"caches expensive variables like load-path, Info-directory-list and auto-mode-alist";
"lazy loads most of its packages ... until you use them" [H, Doom FAQ; M, Doom docs].

**Upstream status.** Native-comp on by default (30) speeds execution but adds compile
stalls (§7); no change to the load model.

**Fixable by design?** Yes.

**Design that fixes it.**
- **Lazy by default**: packages declare *activation triggers* (commands, file patterns,
  major modes, hooks) in a static manifest; nothing is evaluated until triggered — the
  VS Code `activationEvents` model, which Doom reinvents with `doom sync`.
- **Snapshot the initialised state**: after the first successful start, serialise the
  post-init heap (functions, keymaps, autoload tables) so subsequent starts map it —
  a user-level pdumper.
- Parallel, actor-local loading of independent packages; UI shown before init finishes.
- Precompiled bytecode/native cache keyed by content hash, shipped or built once at
  install, not "async in the background while you work".

---

## 5. Redisplay complexity

**Symptom.** Hard to add GUI features (smooth scrolling, proportional layout, inline
widgets, minimap); rendering bugs on macOS ("tearings", partial scroll redraw) [M, bug#62299
via search]; `display-line-number-mode` alone costs ~50 % [M, emacs-devel 2021-05 thread].

**Root cause.** `xdisp.c` ≈ 38 000 lines / 1.2 MB; per emacs-devel (2010): functions like
`move_it_in_display_line_to` and `display_line` "contain so much cruft ... that it is next to
impossible to grasp the overall control and data flow"; bidi "adds quite some hair" [M,
emacs-devel 2010-04 msg00103; H, kyo.iroiro.party]. The model is a text-terminal glyph
matrix (rows of glyphs, current vs desired matrices); overlays, text properties, `display`
properties, compositions, invisible text, images and bidi are all folded into one iterator.
This is the same reason remacs-style incremental rewrites stalled [M].

**Fixable by design?** Yes — by not reproducing the glyph-matrix model.

**Design that fixes it.**
- Separate **model → layout → paint**: buffer + properties → attributed runs → shaped
  lines (CoreText/TextKit-class shaping, in Swift) → GPU-composited layers (Metal/CALayer).
  Redisplay becomes "diff attributed runs, re-shape dirty lines, re-composite".
- Keep the *Elisp-visible* abstractions (faces, overlays, text properties, `display`
  property, invisible text) but implement them as attributes on the rope, not as
  iterator special cases.
- Reticle's lesson in reverse: its "single screen-grid redisplay model shared by both
  front ends" is exactly what precluded "proportional/sub-cell layout, smooth scrolling,
  minimap" [H, CONTEXT.md; Reticle README limitations]. swiftemacs has no TUI, so it does
  not need a grid at all.
- Headless render-to-image path for tests (Reticle: "egui has no headless screenshot
  pipeline to assert against" cost it repeated eyeballing incidents) [H, Reticle README/
  CLAUDE.md].

---

## 6. No async by design (process filters / timers / `while-no-input` hacks)

**Symptom.** Package authors simulate concurrency with `run-with-idle-timer`, process
filters/sentinels, `while-no-input`, `input-pending-p`, debounce/throttle advice
(Karthink's post supplies a throttle/debounce library precisely because "packages install
functions into hooks ... that run after every Emacs command, after typing in text, after
window changes ... i.e. all the time") [H, Karthink]. lsp-booster exists because "Emacs may
block while attempting to send data to the server ... because the server may be busy" and
"The server may block on sending data to emacs when the buffer is full, because Emacs is
consuming the data too slowly" [H, emacs-lsp-booster README].

**Root cause.** Same as §1: process output is delivered by the main loop into Lisp filters
on the one thread; timers run on the same thread between commands; there is no
continuation/future primitive.

**Fixable by design?** Yes.

**Design that fixes it.**
- Structured concurrency in the Elisp runtime: `(async ...)` returning a promise,
  `(await p)`, cancellation tokens; timers and process I/O scheduled by the runtime onto
  the owning actor, not the UI.
- Process I/O framed by the runtime (JSON-RPC, line, raw) with **back-pressure**: a
  bounded queue per process; reading and writing on separate threads (lsp-booster's
  design, in-core).
- Idle work (font-lock stealth, indexing, GC) runs on background actors with the UI actor
  reserved for input → layout → paint.

---

## 7. Native-comp compile stalls and warnings

**Symptom.** After install/upgrade, Emacs "spews hundreds of warnings whilst native
compiling, preventing productive work for quite some time" [M, jeffkreeftmeijer.com];
laptop fans spin; CPU spikes; first use of an advised primitive stalls while a trampoline is
compiled.

**Root cause.** Native compilation via libgccjit is slow (it invokes a GCC pipeline per
file), so it is deferred: `native-comp-jit-compilation` "enables asynchronous (a.k.a.
just-in-time) native compilation of the *.elc files loaded by Emacs for which the
corresponding *.eln files do not already exist", in `native-comp-async-jobs-number`
subprocesses (default half the cores) [H, Elisp manual]. Warnings are shown by default:
`native-comp-async-report-warnings-errors` "default value `t` means display the resulting
buffer" [H]. A frequent cause: the async subprocess lacks a `require` the main session had
[M]. Trampolines: "a small piece of native code required to allow calling Lisp primitives,
which were advised or redefined, from Lisp code that was natively compiled with
`native-comp-speed` set to 2 or greater" — generated on demand, and if unavailable
"calls to that primitive from native-compiled Lisp will ignore redefinitions and advices"
[H, Elisp manual]. Emacs 31 adds `native-comp-async-on-battery-power` — an admission that
the background compiler hurts laptops [H, Mastering Emacs 31.1].

**Fixable by design?** Yes.

**Design that fixes it.**
- Compile **ahead of time at install** (package manifest + content hash), never in the
  background of an interactive session; ship prebuilt artefacts for bundled Lisp.
- Use a **fast tiered JIT** (interpreter → bytecode → baseline native) whose compile
  latency is milliseconds, so nothing needs deferral. Reticle's Cranelift tier hit ~575×
  on tight integer loops but 1.0× on `fib` because calls were outside the subset — the
  lesson is that the JIT must optimise *calls*, not only arithmetic [H, Reticle README].
- Advice/redefinition handled by **indirection through the function cell** at every
  call site (no trampolines; a redefinition just updates the cell; inline caches
  invalidate).
- Warnings go to a diagnostics panel, never a pop-up buffer.

---

## 8. Terminal-era key model (C-i/TAB, C-m/RET, ESC as Meta, ESC delays)

**Symptom.** Binding `C-i` clobbers TAB and vice versa ("Emacs may report that you've
pressed TAB, meaning you've lost C-i") [M, gnu.emacs.help; Doom issue #3090]; `C-m` = RET,
`C-[` = ESC; on a TTY, Evil needs `evil-esc-delay` (0.01 s) because "if Emacs receives an
ESC event there is no way to tell whether the escape key has been pressed ... or a M-<key>
combination" [H, Evil FAQ]; even in the GUI, ESC is the Meta prefix so "get out" is
`ESC ESC ESC` (`keyboard-escape-quit`), which "cannot ... stop a command that is running.
That's because it executes as an ordinary command" [H, Emacs manual *Quitting*]. Three
translation keymaps (`input-decode-map`, `local-function-key-map`, `key-translation-map`)
exist to paper over this [H, Elisp manual *Translation Keymaps*].

**Root cause.** Key events are modelled as ASCII control characters (32 control codes) plus
function-key symbols; GUI Emacs deliberately maps `<tab>` → TAB (9) for compatibility with
TTY bindings.

**Upstream status.** None; Spacemacs/Doom carry `key-translation-map` hacks.

**Fixable by design?** Yes, with a compatibility layer.

**Design that fixes it.**
- Model events as **(physical key, modifiers, text)** from the OS (NSEvent-class data);
  `C-i`, `TAB`, `C-m`, `RET`, `ESC`, `C-[` are all distinct.
- Keymaps keyed on the rich event; a **compatibility normaliser** lets `(kbd "TAB")`
  match both `<tab>` and `C-i` *only if the user asks for it* (default: distinct).
- No terminal ESC ambiguity because there is no TTY front end; the embedded terminal
  emulator (iTerm2-like) handles escape sequences on its own pty, unrelated to editor
  keys.
- `ESC` is a first-class "escape" key (quit minibuffer, clear region, exit transient
  state); Meta is Option/Command per user choice, as emacs-mac/NS already allow via
  `ns-alternate-modifier`/`mac-option-modifier` [M].
- `C-g` is handled **out of band** on the UI actor and cancels the running task via
  cancellation tokens — the manual's "quitting is impossible unless special pains are
  taken" while waiting on I/O disappears because I/O is async (§6).

---

## 9. Non-native macOS look and behaviour

**Symptom.** Users choose between the NS port (official) and Mitsuharu Yamamoto's Mac port
(`emacs-mac`, railwaycat tap) or emacs-plus patches. The Mac port adds: Core Text shaping
with "Non-integral x positions for antialiased proportional fonts", native `fullscreen`
frame parameter, `sticky` frames, Retina images, `mac-start-animation` via Core Animation,
Apple Event handlers, Services menu, `system-move-file-to-trash`, image+text clipboard
[H, README-mac]; plus smooth/trackpad scrolling and native ligatures [M]. emacs-plus
patches: `system-appearance` (`ns-system-appearance-change-functions` for light/dark),
`fix-window-role`, `no-frame-refocus`, `round-undecorated-frame`, historically
`no-titlebar` [H, emacs-plus README]. Doom FAQ: "On some systems (particularly MacOS),
manipulating the fringes or window margins can cause Emacs to crash" [H]. Measured input
latency with a high-speed camera: NS 101.2 ms, Mac port 97.1 ms, Mac port + Metal 88.6 ms
(large frame) [H, emacs-devel 2021-05 msg00866]; NS event handling "is single threaded"
while the Mac port "uses a separate thread for toolkit operations" [M, same thread].

**Root cause.** The NS port draws the glyph matrix into an NSView with Cocoa drawing
primitives on the single Lisp thread; no CALayer/Metal path; frame/window semantics are
Emacs's own (frames ≠ NSWindows one-to-one in behaviour; tabs, Services, Dark Mode,
trackpad gestures, secure input, dictation, Continuity are afterthoughts).

**Fixable by design?** Yes — this is the reason the owner chose Swift + Apple frameworks.

**Design that fixes it.**
- Native `NSWindow`/`NSView` per frame, native tab bar, toolbar, Touch ID/secure input,
  Services, Dark Mode via `NSAppearance`, trackpad momentum/`NSEvent` phases, Dictation,
  Handoff, Spotlight metadata, Quick Look previews — all first-class. (Exact API choices
  belong to the Apple-frameworks research agent; treat names here as [M].)
- Rendering on a GPU-backed layer tree; input handled on the main thread with layout/
  paint decoupled from Lisp execution (§1, §5).
- Ship a **notarised .app** with sane defaults (Command = Super/⌘ shortcuts for
  copy/paste/save alongside Emacs keys), so no emacs-plus/emacs-mac fork is needed.

---

## 10. Config fragility and package-manager churn

**Symptom.** `package.el` (tarballs from ELPA/MELPA, synchronous) vs `straight.el`
(git checkouts, "purely functional", reproducible, synchronous clones) vs `elpaca` ("installs
packages asynchronously, in parallel") — and Doom sits on its own layer [M, System Crafters;
elpaca manual]. Users migrate every few years; configs break on Emacs upgrades; "package
repositories, mirrors going down in the middle of the workday, native compilation hiccups"
drove one user to a zero-external-package config [M, rahuljuliato.com]. Security: "Emacs has
no sandbox, every package you install runs arbitrary Lisp with your full privileges" [M,
blog.fidelramos.net].

**Root cause.** (a) No package *manifest* format with declared entry points, dependencies
and version constraints that the core understands — autoloads are generated by scanning
source cookies. (b) Global mutable namespace: any package can `advice-add`, `setq` a
global, or redefine a function; two packages' hooks interact unpredictably (Karthink: "Few
Emacs packages can afford to be defensive drivers that guard against unpredictable
interactions" [M]). (c) No isolation, no capability model. (d) Installing = compiling on
the user's machine (byte + native), so installation failures are common.

**Upstream status.** `package-vc-install` (29), `use-package` built-in (29), `:vc` keyword
(30), `package-install-upgrade-built-in` (29) [H, NEWS.29/30]. Incremental.

**Fixable by design?** Yes.

**Design that fixes it.**
- **One built-in package manager** with a declarative manifest (name, version, semver
  dependency ranges, activation triggers, contributed commands/keymaps/modes, required
  capabilities), a lockfile for reproducibility, async parallel fetch, prebuilt
  artefacts, and atomic upgrade/rollback. Borrow from VS Code's `package.json`
  contributions and Elpaca's async queue.
- **Namespaces and capabilities**: packages get a namespace; touching another package's
  symbols or the file system/network requires a declared capability, surfaced at
  install time (VS Code-style trust prompt).
- **Advice as a first-class, ordered, introspectable mechanism** (`describe-advice`
  shows who wrapped what) with a per-package "disable all advice from X" switch.
- Config in Elisp *and* a validated declarative layer (settings schema with UI), so a
  typo cannot brick startup; safe-mode start with the last-known-good snapshot (§4).

---

## 11. Tree-sitter adoption pains

**Symptom.** Grammar ABI mismatches ("Latest tree-sitter-python grammar incompatible with
treesit ABI version 14") [M, Doom #8503]; manual grammar compilation requiring "a C compiler
and Git on the user's machine, which is not ideal"; no `.scm` query support — "you end up
maintaining a parallel set of queries that can drift from upstream"; API "moving target"
across 29/30/31 (29 lacks `treesit-thing-settings`, 30 has `treesit-range-settings` offset
bugs, 31 an off-by-one in `treesit-forward-comment`); indentation "The first matching rule
wins"; empty-line indentation falls back to column 0; font-lock "The entire node gets
skipped if any child is already fontified" [H, Batsov 2026]. Casouri (Emacs 30 notes): "The
lack of versioning for language grammars breaks major modes from time to time"; "Installing
tree-sitter grammar is not very easy"; "No automatic major mode fallback mechanism" [H].
`-ts-mode`s are separate modes, so users maintain `major-mode-remap-alist` and lose
features (e.g. cc-mode's fill/comment behaviours) [M].

**Upstream status.** 29: introduction + `treesit-install-language-grammar`. 30: ts modes
derive from the classic modes, `treesit-thing-settings`, local parsers (`:local t`),
`treesit-primary-parser`, new modes [H, NEWS.30; Casouri]. 31: `treesit-auto-install-grammar`,
`treesit-extra-load-path`, sources pinned by commit, `treesit-forward-list` family,
bundled sources for TypeScript/Rust/TOML/YAML/Dockerfile [H, Mastering Emacs 31.1].

**Fixable by design?** Yes.

**Design that fixes it.**
- **Bundle grammars** (compiled `.dylib`s, ABI-pinned) with the app for the priority
  languages — SystemVerilog/Verilog first, then Swift, Python, Perl, Tcl, C/C++ — and a
  signed grammar registry for the rest; never require a C compiler on the user's machine.
- Support upstream **`.scm` query files directly** (highlights/locals/injections/indents)
  with a face-mapping layer, so queries do not drift from upstream (Neovim/Helix/Zed model).
- One major mode per language, tree-sitter-first, with explicit fallback to a regex
  highlighter when a grammar is missing (Reticle's font-lock-style "declaration sites
  coloured, bare identifiers not" philosophy [H, Reticle README]).
- Parsing on a background actor with debounce (Reticle: "background thread with a 30ms
  debounce" [H]); injections via ranges; indentation rules with an explicit, testable
  spec and a debug view.

---

## 12. LSP performance (lsp-mode vs eglot, JSON, lsp-booster)

**Symptom.** lsp-mode's performance page: default `gc-cons-threshold` "too low ... client/
server communication generates a lot of memory/garbage"; `read-process-output-max` "4k
considering that the some of the language server responses are in 800k - 3M range";
`lsp-log-io` "a great performance hit"; plists vs hash tables matter [H, lsp-mode docs].
On Linux, values above 64 KB were ignored until Emacs added an `fcntl` pipe-size call [M,
lsp-mode discussion #3561]. `emacs-lsp-booster` wraps the server, converts JSON to
**Elisp bytecode** ("~4x for large json objects"), dedupes objects, and moves I/O to threads
[H, README]; with Emacs 30's parser, "decodes faster than elisp bytecode, but the I/O takes
longer", hence `eglot-booster-io-only` [M, eglot-booster README].

**Root cause.** (a) JSON parsed on the UI thread; jansson built an intermediate tree —
Géza Herman's Emacs 30 parser "runs 8-9x faster than the jansson based parser ... (tested on
clangd language server messages)" [H, emacs-devel 2024-03 msg00244]. (b) Process output
delivered in small chunks to Lisp filters (§6). (c) Everything (diagnostics rendering,
completion popups, semantic tokens) then runs on the same thread. (d) GC churn from
transient message objects (§2).

**Upstream status.** Emacs 30: native parser, no libjansson, 64 KB read buffer, C default
filter [H, NEWS.30]; Emacs 31: adaptive read buffering off [H]. eglot built-in since 29.

**Fixable by design?** Yes.

**Design that fixes it.**
- LSP transport, framing and JSON decoding in **Swift on a background actor**
  (Codable/simd-JSON-class parser), delivering typed, already-decoded structures to the
  buffer actor; UI actor only receives diff-shaped updates (diagnostics deltas, completion
  lists).
- Reticle's split — "Transport and JSON-RPC framing in Rust; all protocol semantics in
  Elisp" [H] — is a good default, but keep hot paths (semantic tokens, inlay hints,
  diagnostics decoration) native and expose Elisp hooks for policy, not per-message work.
- Bounded, cancellable requests (typing cancels stale completion requests), request
  coalescing, and per-server back-pressure.
- Built-in profiles for verible-verilog-ls, slang-server, clangd, pyright,
  sourcekit-lsp, rust-analyzer (present on the owner's machine) with server-specific
  capability quirks handled natively — Reticle's rule "test against a real server ...
  before starting work" stands [H, Reticle CLAUDE.md].

---

## 13. Org-mode slowness on big files

**Symptom.** "A 400 KB org file that used to take 5 seconds on first load needed more than 2
minutes" after an update [M, orgmode list]; typing lag in large org files traced to
`org-activate-footnote-links`, `org-footnote-next-reference-or-definition`, `org-in-block-p`
in font-lock [M, Doom #2118]; agenda over many files is slow because "Emacs opens a new
file ... activating all kinds of minor modes"; ">1000 agenda files ... still take a long time"
even on Emacs 30 [M, worg agenda-optimization]; `org-cycle-hide-drawer-startup` default
increased buffer-open time [M, orgmode list 2022-12].

**Root cause.** Org is a regexp-based parser (`org-element`) re-run on demand, layered on
font-lock regexps, with a cache (`org-element-cache`, persistent since 9.6) that "only
stores elements within individual sections"; Ihor's headline-cache proposal claimed "up to
2.5x" for agenda/tag/property queries [H, orgmode list 2021-09]. Folding uses overlays or
`org-fold` text properties; agenda scans buffers linearly.

**Fixable by design?** Yes.

**Design that fixes it.**
- An **incremental org parser** (a tree-sitter org grammar, or a hand-written incremental
  parser producing a persistent AST) feeding both highlighting and structure queries;
  edits re-parse only the affected subtree.
- A **project-wide org index** (headlines, tags, properties, timestamps, IDs) maintained
  on a background actor and persisted (SQLite-class store), so agenda/refile/ID lookup
  are index queries, not buffer scans. Agenda no longer opens files.
- Folding as a layout attribute on the rope (§5), not overlays.
- File-format compatibility retained (Reticle: "file-format compatible with real org
  files" [H]).

---

## 14. Undo confusion

**Symptom.** "Emacs's undo history can easily get out of hand when you undo, then undo that
undo, then undo the undo of undo" [M, Casouri]; the concept "redo = undo an undo" surprises
everyone; `undo-tree` had "long standing unresolved bugs" that motivated `undo-fu` [M,
undo-fu README].

**Root cause.** `buffer-undo-list` is a linear list into which undo commands themselves
push entries; redo is expressed as breaking the undo chain by a non-undo command. Emacs 28
added `undo-only` and `undo-redo` ("will not record itself as an undoable command") [M,
Emacs manual *Undo*], but `C-/` still defaults to the old behaviour.

**Fixable by design?** Yes.

**Design that fixes it.**
- Native **undo tree** per buffer with linear undo/redo as the default UI, branch
  navigation and a visualiser; group edits by command and by time; persist across
  sessions; selective/region undo built in. Undo entries reference rope versions
  (persistent data structure), making them cheap.

---

## 15. Minibuffer and keyboard-quit quirks

**Symptom.** A forgotten active minibuffer swallows `C-x C-f` in another window; recursive
minibuffers (`enable-recursive-minibuffers`) confuse; `C-g` sometimes "does not work" —
because `C-g` "is only actually executed as a command if you type it while Emacs is waiting
for input" and "When Emacs is waiting for the operating system to do something, quitting is
impossible unless special pains are taken" [H, Emacs manual *Quitting*]; the escape hatch is
`pkill -SIGUSR2 emacs` [M, Irreal]. Reticle hit the analogous problem in its own design:
"Minibuffer keys are a hardcoded Rust dispatch and are not rebindable from Elisp" and
"Closing the minibuffer with ESC has no Elisp-observable hook" [H, Reticle README].

**Upstream status.** Emacs 31 turns on `minibuffer-nonselected-mode` by default to
highlight an inactive minibuffer [H, Mastering Emacs 31.1]. Cosmetic.

**Fixable by design?** Yes.

**Design that fixes it.**
- The minibuffer is an **ordinary buffer with an ordinary keymap** (fully rebindable),
  hosted in a native panel/popover; recursive prompts are a visible stack; leaving it is
  observable (hooks) and cancellation propagates to the awaiting task.
- `C-g`/ESC handled by the UI actor and delivered as **cancellation** to whichever task is
  running (§8); never lost because no Lisp runs on the input thread.

---

## 16. No proper GUI widgets

**Symptom.** Completion popups (Corfu/Company), tooltips, dialogs are built from
**child frames** ("posframe, corfu ... essentially workarounds for the missing native widget
support") and `widget.el` text widgets; Emacs 31 even brings child frames to the TTY
(`tty-child-frames`, `tty-tip-mode`) [H, Mastering Emacs 31.1]. No native tree view,
scrollable panels, split-pane docking, inline images with layout, or accessible controls.

**Root cause.** The display model can only draw glyph rows into windows (§5); everything
must be text in a buffer.

**Fixable by design?** Yes.

**Design that fixes it.**
- A small **widget layer exposed to Elisp** (popover, list picker, inline hint, side
  panel, tree, tabs, notifications, progress) implemented natively (AppKit/SwiftUI
  hosting) and driven by data, with keyboard-first behaviour so Emacs users are not forced
  into the mouse. Buffers remain the primary document surface; widgets are for chrome.
- Accessibility (VoiceOver) for free from native controls — a permanent gap in Emacs
  outside Emacspeak.

---

## 17. Font and ligature setup pain

**Symptom.** Ligatures need HarfBuzz builds (28+) plus `ligature.el` or hand-generated
`composition-function-table` entries per font (a Haskell generator exists just for Fira
Code) [M, ligature.el; EmacsFiraCode]; Doom FAQ: "Ligatures can cause Emacs to crash"; "Some
fonts cause Emacs to crash when they lack support for a particular glyph" [H, Doom FAQ].
Fontsets, fallback fonts, emoji, CJK widths and `face-font-rescale-alist` are manual.

**Root cause.** Composition is a per-character-range table mechanism bolted onto the glyph
matrix rather than a text-shaping pass; font fallback is Emacs's own fontset logic, not the
platform's cascade list.

**Fixable by design?** Yes.

**Design that fixes it.**
- Shape whole runs with the platform shaper (CoreText/HarfBuzz-class), enabling font
  features (`calt`, `liga`, `ss0x`) by attribute; platform font fallback/cascade; emoji
  and colour fonts; variable fonts; per-face features exposed as face attributes. Ligature
  toggling is a font-feature flag, not a table.
- Grid-alignment mode (monospace snapping) available for terminals and column-sensitive
  buffers.

---

## 18. Scrolling jank

**Symptom.** `pixel-scroll-precision-mode` (29) is "very CPU intensive" and choppy under
power-saving CPU governors [H, bug#59134; Po Lu: "I know of this problem and will try to fix
it"]; "Rapid scrolling through large, heavily fontified files can introduce noticeable input
lag" [M, jamescherti.com]; users install `ultra-scroll` [M]. `redisplay-skip-fontification-
on-input` exists to drop fontification when input is pending [M].

**Root cause.** Each scroll event triggers a full redisplay pass and JIT font-lock on the
UI thread; there is no retained layout, no compositor, and no frame pacing (vsync).

**Fixable by design?** Yes.

**Design that fixes it.**
- Retained, GPU-composited line layers; scrolling translates layers at display refresh
  (ProMotion-aware), with fontification of newly exposed lines done off-thread and painted
  when ready (placeholder-then-fill). Trackpad phases/momentum and rubber-banding native.
- Frame budget enforcement: input → paint under ~8 ms; Lisp never runs on the paint path.

---

## 19. No per-buffer threads

Covered by §1 root cause; Elisp threads share the one heap and the one current-buffer
state (thread-local current buffer and match data exist, but point/narrowing/buffer-locals
do not) [H, Elisp manual mirror; Radchenko]. **Design:** buffer = actor, with per-actor
Elisp context (§1). Cross-buffer iteration (`ibuffer`, agenda) uses snapshot queries via the
index (§13) rather than sequential locking (Hinckley's acknowledged open problem).

---

## 20. TRAMP slowness

**Symptom.** "Each call through TRAMP takes about 50-100ms. Compare that to a normal
external process call in Emacs which would take around 1 ms"; "a simple magit command might
run 30 individual shell commands"; "magit was making 176 calls over TRAMP, even though it
only needed 6 of them" [H, coredumped.dev 2025]. Recommended mitigations are a wall of
settings (`remote-file-name-inhibit-locks`, `tramp-use-scp-direct-remote-copying`,
`remote-file-name-inhibit-auto-save-visited`, `tramp-copy-size-limit`, direct async
processes, disabling vc/LSP remotely) [H].

**Root cause.** TRAMP emulates a file system by **synchronously** driving a remote shell
over ssh through `file-name-handler-alist`; every primitive (`file-exists-p`,
`file-attributes`, locks, auto-save, vc probes) is a round trip on the UI thread; no
batching, weak caching. Reticle's remote editing was "Fully synchronous. Remote operations
block the UI" — the owner explicitly wants this gone [H, Reticle README; CONTEXT.md].

**Fixable by design?** Yes.

**Design that fixes it.**
- A **remote agent** protocol: a small binary (or a shell-only fallback) on the host
  serving batched file-system RPC over one multiplexed ssh channel; all calls async on a
  remote-fs actor; aggressive metadata cache with invalidation from a remote watcher;
  file-transfer streaming.
- Remote LSP/terminal/compile run through the same channel (VS Code Remote model).
- The VFS layer is native, not `file-name-handler-alist`; Elisp sees ordinary async file
  primitives.

---

## 21. Byte-compile warnings

**Symptom.** "docstring wider than 80 characters" fired even "when there is no docstring"
(bug#65790, Emacs 29.1) and on macro-generated docstrings (`cl-defun`, `cl-defstruct`,
`defclass`, `defhydra`), breaking CI (CIDER #3191) [M]; users see `*Compile-Log*`/`*Warnings*`
noise from third-party code they cannot fix.

**Root cause.** The byte compiler is also the linter; warnings are global, not scoped to
"my code vs dependencies", and there is no suppression at the package boundary.

**Fixable by design?** Yes.

**Design that fixes it.**
- Separate **compiler** (silent unless it is an error) from **linter** (opt-in, project-
  scoped, with a diagnostics panel); dependency warnings never shown to end users; a
  proper `#lint:` pragma; the docstring-width check off by default for generated code.

---

## 22. Unpredictable latency from hooks and advice

**Symptom.** Typing lag whose cause is invisible: `smartparens`' `sp--post-self-insert-hook-
handler` [M, smartparens #595]; `smart-mode-line`'s mode-line string generation "consumed 9 %
of CPU time during routine editing" [H, Karthink]; AUCTeX cursor-movement lag [M]; Emacs
profiler and `explain-pause-mode` exist because nothing in the platform attributes latency
to a package.

**Root cause.** Hooks run synchronously on the UI thread in arbitrary order; advice wraps
functions without budget or attribution; the mode line is recomputed every redisplay.

**Fixable by design?** Yes.

**Design that fixes it.**
- Hooks on the keystroke path run under a **time budget with automatic quarantine and
  attribution** (Reticle: 50 ms budget, three strikes, "a named message telling you which
  one it was" [H]); hooks may declare themselves async (run off the UI actor).
- A built-in **latency profiler** (per command, per hook, per package) always on with
  negligible cost; flame view in a panel.
- Mode line/header line as cached, invalidation-driven views.

---

## 23. Additional pain points surfaced during research (not in the brief)

| Pain | Evidence | Design |
|---|---|---|
| No package sandbox/security | "every package you install runs arbitrary Lisp with your full privileges" [M] | capabilities + trust prompts (§10) |
| Crashes from fonts/fringes on macOS | Doom FAQ [H] | native text stack (§17), no fringe hacks |
| Lossy/legacy string model burdens rewrites | Emacs chars up to `#x3FFFFF`, CCL, case tables [H, kyo.iroiro.party] | define swiftemacs strings as Unicode scalars + raw-byte escapes; do not emulate CCL |
| Dynamic binding blocks parallelism | "Dynamic binding is a big blocker for multithreading" [M, HN] | lexical binding default (Reticle did this [H]); dynamic bindings thread-local |
| No automated tests culture in packages | "automated tests ... never gained much traction in the Emacs community" [H, Batsov] | ship a test runner and headless render in the SDK |
| Emacs survey lacks pain-point data | 2022 survey (~7 000 responses) published demographics only; pain analysis "to come later" and was not found [H, EmacsConf 2022] | — (do not cite the survey for pain points) |

---

## 24. Cross-cutting design principles derived from the inventory

1. **UI actor + buffer actors + async everything.** Fixes §1, 6, 12, 19, 20, 22.
2. **Bounded-pause GC with cycle collection.** Fixes §2, 4, 12.
3. **Rope with indices + retained GPU layout.** Fixes §3, 5, 16, 17, 18.
4. **Rich key events, terminal only inside the embedded terminal.** Fixes §8, 15.
5. **Manifest-driven, lazy, sandboxed packages; AOT compilation at install.** Fixes §4, 7, 10, 21.
6. **Tree-sitter-first with bundled grammars and `.scm` queries; incremental org parser +
   index.** Fixes §11, 13.
7. **Native macOS chrome.** Fixes §9, 16.
8. **Observability built in** (latency attribution, GC telemetry, advice introspection).
   Fixes §22 and prevents the config-tuning folklore of §2/§4.

The compatibility boundary to state up front: swiftemacs runs *its own* Elisp dialect
(lexical by default, actor-aware, async primitives, rich events). GNU packages are a
porting target, not a runtime target — the same stance Reticle took, and the only stance
under which every item above is fixable.

---

## Sources (fetched or searched during this run)

Primary / project sources
- Emacs NEWS.29 (raw): https://raw.githubusercontent.com/emacs-mirror/emacs/master/etc/NEWS.29
- Emacs NEWS.30 (raw): https://raw.githubusercontent.com/emacs-mirror/emacs/master/etc/NEWS.30
- Mastering Emacs, "What's New in Emacs 31.1?": https://www.masteringemacs.org/article/whats-new-in-emacs-311
- Sean Whitton, "The emacs-31 branch will be cut in one week" (2026-04-30): https://lists.gnu.org/archive/html/emacs-devel/2026-04/msg01089.html
- Sean Whitton, "The emacs-31 feature freeze has begun" (2026-05-07): https://lists.gnu.org/archive/html/emacs-devel/2026-05/msg00194.html
- Eli Zaretskii, "Re: Next steps for igc feature branch" (2025-04-23): https://lists.gnu.org/archive/html/emacs-devel/2025-04/msg00857.html
- "Status of feature/igc3" (2026-06): https://lists.gnu.org/archive/html/emacs-devel/2026-06/msg00167.html , msg00175.html
- README-IGC (feature/igc3): https://raw.githubusercontent.com/emacs-mirror/emacs/feature/igc3/README-IGC
- Stefan Kangas et al., "Merging MPS a.k.a. scratch/igc, yet again": https://lists.gnu.org/archive/html/emacs-devel/2024-12/msg00359.html
- Ihor Radchenko, "Re: Concurrency via isolated process/thread" (2023-07): https://lists.gnu.org/archive/html/emacs-devel/2023-07/msg00358.html
- Elisp manual, Threads: https://www.gnu.org/software/emacs/manual/html_node/elisp/Threads.html (fetched via mirror https://ayatakesi.github.io/lispref/29.1/html/Threads.html)
- LWN, "Emacs 26.1 released: About concurrency": https://lwn.net/Articles/755833/
- Elisp manual, Native-Compilation Variables: https://www.gnu.org/software/emacs/manual/html_node/elisp/Native_002dCompilation-Variables.html
- Emacs manual, Quitting: https://www.gnu.org/software/emacs/manual/html_node/emacs/Quitting.html
- Elisp manual, Translation Keymaps: http://www.gnu.org/software/emacs/manual/html_node/elisp/Translation-Keymaps.html
- Géza Herman, "I created a faster JSON parser" (2024-03): https://lists.gnu.org/archive/html/emacs-devel/2024-03/msg00244.html
- EmacsConf 2023, Ihor Radchenko, emacs-gc-stats: https://emacsconf.org/2023/talks/gc/
- EmacsConf 2022, survey results: https://emacsconf.org/2022/talks/survey/
- bug#59134 pixel-scroll-precision-mode CPU: https://lists.gnu.org/archive/html/bug-gnu-emacs/2022-11/msg00633.html
- emacs-devel 2021-05, Mac port Metal latency numbers: https://lists.gnu.org/r/emacs-devel/2021-05/msg00866.html
- emacs-mac README-mac: https://bitbucket.org/mituharu/emacs-mac/raw/master/README-mac
- homebrew-emacs-plus README: https://raw.githubusercontent.com/d12frosted/homebrew-emacs-plus/master/README.org
- emacs-lsp-booster README: https://github.com/blahgeek/emacs-lsp-booster/blob/master/README.md
- eglot-booster: https://github.com/jdtsmith/eglot-booster
- lsp-mode performance page: https://emacs-lsp.github.io/lsp-mode/page/performance/
- Doom Emacs FAQ: https://github.com/doomemacs/doomemacs/blob/master/docs/faq.org
- Evil FAQ (ESC delay): https://evil.readthedocs.io/en/latest/faq.html
- Casouri, "Tree-sitter Changes in Emacs 30": https://archive.casouri.cc/note/2024/emacs-30-tree-sitter/
- Bozhidar Batsov, "Building Emacs Major Modes with Tree-sitter: Lessons Learned" (2026-02): https://batsov.com/articles/2026/02/27/building-emacs-major-modes-with-treesitter-lessons-learned/
- Karthik Chikmagalur, "Cool your heels, Emacs": https://karthinks.com/software/cool-your-heels-emacs/
- Troy Hinckley, "A vision of a multi-threaded Emacs": https://coredumped.dev/2022/05/19/a-vision-of-a-multi-threaded-emacs/
- Troy Hinckley, "Making TRAMP go Brrrr": https://coredumped.dev/2025/06/18/making-tramp-go-brrrr./
- "Why Rewriting Emacs Is Hard": https://kyo.iroiro.party/en/posts/why-rewriting-emacs-is-hard/
- Ihor Radchenko, headline caching proposal: https://list.orgmode.org/orgmode/87bl4p6n0m.fsf@localhost/
- Worg agenda optimisation: https://orgmode.org/worg/agenda-optimization.html
- Reticle README and CLAUDE.md: /Users/jerrychen/My_Projects/reticle/README.md , /Users/jerrychen/My_Projects/reticle/CLAUDE.md

Secondary (search summaries, blogs, issues)
- Phoronix on Emacs 29.1 long lines; 200ok long-lines guide; GNU ELPA so-long
- emacs-devel 2010-04 "redisplay code is ugly": https://lists.gnu.org/archive/html/emacs-devel/2010-04/msg00103.html
- Doom issues #3090 (C-i/TAB), #8503 (grammar ABI), #2118 (org typing lag)
- smartparens #595; CIDER #3191; bug#65790 (docstring warnings)
- lsp-mode discussion #3561 (pipe capacity)
- Casouri, visual undo tree; undo-fu README; Emacs manual Undo
- jamescherti.com scrolling; ultra-scroll; Irreal "How to Fix a Stuck Emacs"
- System Crafters (Elpaca/straight); elpaca manual; rahuljuliato.com; blog.fidelramos.net
- HN threads 40154776, 42198822, 39408162; EmacsWiki NoThreading
- onlisp.co.uk igc testing guide; emacs-gc-stats ELPA page
