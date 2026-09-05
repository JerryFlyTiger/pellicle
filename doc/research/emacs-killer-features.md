# Killer features of world-class Emacs setups

Topic key: emacs-killer-features. Scope: catalogue features/packages that make expert Emacs
setups indispensable, with Emacs-core mechanism each depends on and how it maps to a native
Swift reimplementation (core / shipped Elisp lib / third-party extension). See
`emacs-pain-points.md` §24 for cross-cutting design principles (not repeated here).

## 0. Ranked table (most-cited-as-essential first)

Ranking basis: cross-referenced frequency of appearance/emphasis across Doom, Purcell, Prot,
System Crafters and Karthink's public configs and writing (as known generally plus what this
run's fetches confirmed), not a formal citation count.

| Rank | Feature/package | Core mechanism | Native mapping |
|---|---|---|---|
| 1 | magit (+ transient) | section/overlay+text-property regions; transient keymaps | core section-overlay primitive + core Git integration + core transient-menu primitive |
| 2 | vertico/consult/marginalia/orderless/embark | `completing-read` + completion-styles + completion metadata | one core completion-table protocol, pluggable matching, category-keyed action registry |
| 3 | corfu + cape | `completion-at-point-functions` + `completion-in-region` | one core completion-at-point protocol; native popup renderer |
| 4 | which-key | keymap introspection + timer | built into core keymap system, native HUD |
| 5 | avy | overlays + label-tree allocation | core label-jump motion primitive |
| 6 | project.el/projectile | pluggable root detection + completing-read | core workspace/project concept |
| 7 | flycheck/flymake + lsp-mode/eglot | diagnostic overlays + JSON-RPC LSP client | core async LSP client + core Diagnostic decoration type |
| 8 | evil + general.el | per-state keymaps, pending-operator state, overlay visual selection | pluggable modal-state layer over one core keymap system |
| 9 | org-mode + org-roam + agenda + capture | overlays/text-properties for folding; SQLite backlink cache | core persistent outline+link index, not overlay-folding at scale |
| 10 | dired/dirvish + treemacs | text-properties on lines mapping to real paths | native file-tree/preview widget, not a text-buffer simulation |
| 11 | vundo/undo-tree/undo-fu | Emacs undo-list internals | core tree/DAG undo model with native time-travel UI |
| 12 | yasnippet/tempel | overlay/marker tabstop-mirror chains | core live-linked-region primitive (shared with rename/iedit) |
| 13 | multiple-cursors | overlay per cursor + per-command allowlist | core input-loop-level multi-cursor (no per-command classification) |
| 14 | doom-modeline | `mode-line-format` + propertize segments | native GPU status bar with declarative segment API |
| 15 | eshell/vterm/eat | pure-Elisp shell vs libvterm C module vs pure-Elisp terminal | native pty-backed terminal view built into the app (ground rule 6) |

Just outside the top 15 but still frequently cited: expand-region (-> tree-sitter node-select),
wgrep/rg/deadgrep (-> writable project-search results), hydra (-> subsumed by transient),
xref/dumb-jump (-> pluggable navigation-backend abstraction, same shape as completion-table),
winner/ace-window (-> window-manager undo + label-jump), popper (-> declarative window-
placement policy engine), helpful/describe-* (-> self-describing Elisp runtime requirement),
TRAMP (-> core async remote-I/O layer), smartparens/paredit and rainbow-delimiters/hl-todo/
iedit (-> tree-sitter-node operations and font-lock-tier decorations, all core-native).

## 1. Doom Emacs design principles (source: github.com/doomemacs/doomemacs, medium confidence — WebFetch summary, not raw source read)

Four mantras: (1) performance-first — "gotta go fast," heavy lazy-loading of packages and
deferred module init; (2) minimal abstraction — "close to metal," stays near vanilla Emacs
semantics; (3) opinionated but not stubborn — curated defaults, overridable; (4) "your
system, your rules" — Doom refuses to auto-install system deps, instead surfaces problems via
`doom doctor`. `doom doctor` diagnoses config/env issues (missing binaries, version
mismatches). `doom sync` regenerates the package/autoload cache and reconciles installed
packages with the declared `packages.el`/`init.el` module list after any config edit — this
is the closest analogue to a lockfile-driven `swift package resolve`, but synchronous and
user-triggered, never automatic. Module system: ~150 self-contained modules grouped by
concern (`:completion`, `:editor`, `:emacs`, `:term`, `:checkers`, `:tools`, `:lang`, `:app`,
`:config`), each toggled on/off in `init.el`; modules declare their own package list,
autoloads, and keybindings, and are lazy-loaded via `use-package`'s `:defer`/`:hook` idioms
so disabled features cost ~0 startup time. Leader key: SPC in evil states / `C-c` in
non-evil "emacs" state, bound through `general.el`, giving a discoverable mnemonic
which-key-driven hierarchy (`SPC f f` = find file, `SPC p p` = switch project, etc).
Native mapping: the module system -> a manifest-driven extension registry in the Swift core
(declared capability + lazy activation, not process-per-extension); `doom sync` -> a build-time
or launch-time reconciliation step already implied by pain-points §24 principle 5; leader key
+ which-key -> core keymap tree with a built-in transient overlay UI (see which-key below),
not dependent on evil.

## 2. Purcell (purcell/emacs.d) config philosophy (medium confidence)

Purcell's config is explicitly *not* Doom-like: no leader key, no modal editing by default,
"sane defaults" over opinionated bindings — it patches and extends vanilla Emacs behavior
rather than layering a new paradigm on top. Structure: one `init-<package>.el` file per
concern, loaded from a top-level `init.el`, so any single integration can be read, disabled,
or copied in isolation — an explicit design-for-forking stance ("I cannot provide support for
customised versions," i.e., fork rather than configure-in-place). Packages auto-install on
first run from `package.el`/MELPA. Emphasizes standard-Emacs-workflow tools: vertico+corfu
for completion, eglot for LSP, flymake/flycheck, magit, projectile, org-mode, plus deep
per-language tooling (Haskell, Ruby, Python, JS). Native mapping: this is the "minimal,
composable,読める config over framework magic" philosophy — argues for the Swift core
shipping small, independently-readable default-config modules (one file per integration)
rather than a single monolithic preset, mirroring Purcell's per-package init files.

## 3. Feature catalogue (mechanism -> native mapping)

### Completion stack: vertico/consult/embark/orderless/marginalia

**Vertico** (high confidence, github.com/minad/vertico): vertical minibuffer completion UI,
~600 lines, deliberately UI-only. Depends on Emacs's `completing-read` + completion-styles
machinery — reuses stock APIs instead of inventing a new one (unlike Helm/Ivy, which define
their own backend protocol). This is why the whole "minad stack" composes: every package
talks to the same `completing-read`/completion-table contract. Native mapping: the Swift core
must expose a single **completion-table protocol** (candidates + metadata: category, sort,
group, annotation function) at the core level, with the minibuffer/picker UI as a thin,
swappable front-end over it — analogous to `completing-read`. This is the single most
consequential mechanism to get right, since Consult, Embark, Marginalia, Orderless, and
Corfu all key off it.

**Consult** (high confidence): supplies the *commands* (consult-buffer, consult-ripgrep,
consult-line, consult-imenu, consult-goto-line, consult-mark, consult-recent-file,
consult-yank-from-kill-ring) that populate the completion table, many with **live preview**
(jumping the visible buffer/point as the candidate is highlighted, before committing) and
**narrowing** (single-key filters within one command, e.g. buffers vs recent files). Preview
is implemented via temporarily moving window point / an overlay, restored on abort. Native
mapping: core needs "async streaming completion source" (for consult-ripgrep style live
grep) and a formal preview/commit/abort protocol on the picker, not just a synchronous list.

**Marginalia** (not independently fetched, medium confidence via cross-references): adds
rich annotations (file size/perms, command doc string, symbol type) to completion candidates
by attaching to the same completion metadata category system Vertico reads. Native mapping:
annotation is a pure function of (category, candidate) resolved by core metadata, not
per-command bespoke code — same principle as Vertico's genericity.

**Orderless** (not independently fetched, medium confidence): a completion-style matching
space-separated components in any order/regexp/fuzzy per component, pluggable into the same
completion-styles list Vertico/Corfu consult. Native mapping: matching/scoring must be a
pluggable strategy on the core completion-table protocol, not hardwired prefix match.

**Embark** (not independently fetched due to budget; medium/low confidence): "embark-act"
provides a context menu of actions on the *thing at point* or the *current minibuffer
candidate* — turning any completion candidate (buffer, file, symbol) into a target for a set
of applicable commands, effectively a universal right-click/action-picker keyed off
candidate category. Native mapping: category-keyed **action registry** (per candidate type:
buffer/file/symbol/package -> list of applicable commands) at the core level; this is a
generically useful mechanism beyond Elisp-land (e.g. Xcode's Quick Actions, VS Code's Code
Actions) so it should be a first-class Swift-core concept, not bolted onto the Elisp layer.

### corfu/cape (in-buffer completion)

**Corfu** (high confidence, github.com/minad/corfu): in-buffer completion popup, the
"vertico of the buffer." Depends on `completion-at-point-functions` (Capfs — pluggable
per-mode/per-context candidate sources) and `completion-in-region` (the function that
actually inserts/narrows the selection as you type), rendered via child frames (or overlays
in terminal builds). Explicitly lighter than company-mode because company defines its *own*
backend API (3x the code) instead of reusing Capfs. Native mapping: the Swift core's LSP/
tree-sitter/snippet layers should all register as sources against one
**completion-at-point protocol** (position -> candidates + prefix range + metadata), with a
single core-native popup renderer — never a bespoke per-source UI. This directly determines
whether third-party language extensions can compose completion sources cleanly.

**Cape** (not independently fetched; medium confidence via general knowledge of the
ecosystem): a library of small "Completion At Point Extensions" — dabbrev, file-path,
keyword, dictionary-word Capfs, plus combinators (`cape-capf-super` to merge several Capfs
into one, `cape-wrap-buster` to add caching/invalidation). Native mapping: the core should
ship equivalent small composable completion sources (word history, path, symbol) and a
combinator so multiple sources can be merged into one ranked list — this is what lets Corfu
show LSP + snippet + buffer-word completions together.

### magit + transient

**Magit** (WebFetch returned only marketing copy, not architecture — confidence medium,
supplemented from general knowledge): Magit's status buffer is a single dashboard (unstaged/
staged/stashed/unpushed/log sections) built from **magit-section**, a library of collapsible,
nested regions implemented with **overlays carrying section objects** plus **text
properties** marking each line's semantic type (hunk, file, commit) — so every line is a
clickable/actionable target whose type determines available commands (this is the same
category-keyed-action idea as Embark, applied to git). Diffs are real `git diff` output
rendered in-buffer with keys to stage/unstage/visit at hunk or line granularity, no modal
dialogs. Menus (`magit-dispatch`, log/commit/rebase options) are transient prefixes. Native
mapping: (a) a **section/overlay-with-payload primitive** in the core text-system — nestable,
foldable regions each carrying a typed value and a command dispatch table — is reusable far
beyond git (file trees, search results, LSP diagnostics lists); (b) a native Git integration
should be a first-class Swift-core feature (shell out to `git` or use libgit2/Swift Git
bindings) rendered through that same section primitive, not an Elisp-only package, given how
central "instant Magit-quality git" is to the feel of the whole editor.

**Transient** (high confidence): implements **prefix/infix/suffix** command menus — a prefix
command (e.g. `magit-dispatch`) pops a transient keymap overlaying the buffer showing
currently-toggled flags (infixes) and available actions (suffixes); pressing a suffix's key
runs it with the infix state as arguments. Depends on Emacs's **transient keymaps**
(`set-transient-map`), **overlays** for the popup rendering, and echo-area/minibuffer for
inline argument editing. This is *the* generic solution to "expose a large option surface
without modal dialogs or memorized flags," and half the ecosystem (magit, extended even to
non-git things like `docker.el`, `guix.el`) is built on it. Native mapping: this should be a
**core-level transient-menu primitive** (declarative: list of infixes/suffixes -> renders a
native macOS-style HUD/popover, not a text overlay) since it is reused by so many features
(git, LSP actions, project actions) — build it once in Swift, expose it to Elisp as a
declaration API rather than re-implementing overlay-based popups per feature.

### which-key

High confidence (github.com/justbur/emacs-which-key): after a prefix key with no immediate
follow-up, which-key introspects the active keymaps reachable from that prefix and shows all
bound continuations (key -> command name) in a bottom/side popup after a short idle timer;
purely a **keymap introspection + timer** mechanism, no special support needed from bound
commands. Notable: which-key is being merged into core GNU Emacs (targeted v30) because
discoverability is considered that fundamental. Native mapping: this must be a **built-in
core feature**, not an extension — the core keymap/binding tree should support "list bound
continuations of a partial chord" as a query, with a native HUD renderer. It is one of the
cheapest, highest-leverage features to build natively since it needs no per-command
cooperation, just keymap introspection.

### avy

Not independently fetched (medium confidence, general knowledge): avy implements
"jump to any visible position" motions (avy-goto-char, avy-goto-word, avy-goto-line) by
overlaying every candidate match with a short label (one or two characters drawn via
overlays with a distinct face) and letting the user type the label to jump instantly — an
implementation of Vim's easymotion/sneak idea generalized to arbitrary target predicates
(char, word start, line, any regexp) across all visible windows. Mechanism: **overlays** for
labels + a **decision-tree label allocation algorithm** minimizing keystrokes for many
candidates. Native mapping: label-overlay jump should be a **core-level cursor motion
primitive** (predicate over visible text -> label overlays -> single/two-key selection),
generically useful even outside Elisp scripting (e.g. bound to a “jump mode” in the base
editor), not dependent on evil.

### evil + general.el (leader keys)

Evil (WebFetch returned only file-listing, not internals — medium confidence, supplemented):
Evil implements Vim's modal editing as an Emacs **minor mode with per-state keymaps**: each
state (normal/insert/visual/replace/operator-pending) activates its own keymap layered above
the buffer's normal keymaps via Emacs's minor-mode-keymap-alist ordering, so entering a state
is just swapping which keymap intercepts keys — no separate input loop. Operators (d, c, y)
combine with motions/text-objects through a **pending-operator state**: press an operator,
Evil waits for a motion or text-object key, then applies the operator to the resulting region
— implemented as ordinary Emacs region + command composition, not a bespoke parser. Visual
selection uses an **overlay** for the highlighted region. `general.el` is a thin
keybinding-definition DSL (not a state engine) that most Doom/Prot/System-Crafters configs
use to define leader-key hierarchies (`SPC f f`) uniformly across evil states and non-evil
`C-c`/`C-x` maps — it's what makes leader keys ergonomic to author, layering on top of Evil's
or vanilla's keymaps rather than replacing them. Native mapping: modal editing should be a
**pluggable state layer over the same core keymap system** used for everything else (states
are just named keymap sets + a mode-line indicator + a cursor-shape hook), so it's opt-in
without forking the core input model — this matches how Reticle's "evil layer on by default"
was implemented and should stay a layer, not a fork of dispatch.

### projectile / project.el

Not fetched (high confidence, general knowledge — both are extremely well documented core/
near-core features). `project.el` (built into Emacs since 25) and `projectile` (older,
richer third-party) both define "project root" by walking up from the current file looking
for a marker (`.git`, `Cargo.toml`, etc.) via a **pluggable project-root-detection
backend**, then scope commands (find-file-in-project, project-wide search/replace, project
buffer list, compile) to that root; results are delivered through the same
`completing-read`-based UI as everything else, so projectile/consult-project-extra compose
for free. Native mapping: "project" should be a **core-level workspace concept** (root +
detected build system + file index), not a per-command regexp match — every project-scoped
feature (search, LSP server selection, compile command, file tree) should resolve against one
shared project-root resolution, especially important given Verilog's `verible.filelist`-style
multi-file project convention already used in Reticle.

### dired / dirvish, treemacs

Not fetched (high confidence for dired — core Emacs; medium for dirvish/treemacs specifics,
general knowledge). Dired renders a directory listing as an editable text buffer (each line
one file, produced by literally embedding `ls` output or an internal equivalent) where
**text properties on each line's filename** carry the file's real path, so cursor-motion
commands and editing (rename-by-editing-text, wdired) work for free — this "everything is
just text you can select/edit" pattern is dired's whole trick, and both wgrep and wdired
reuse it directly. Dirvish adds a right-side preview pane, Miller-columns navigation, and
icons/git-status decoration on top of dired's buffer model without replacing it. Treemacs
is a separate persistent sidebar tree-view (not text-buffer-based in the same way; more like
a dedicated widget) showing project file trees with lazy-expansion and git/error decoration.
Native mapping: a **native file-browser sidebar with lazy tree expansion, inline git-status
and diagnostic badges, and a preview pane** should be a first-class GUI widget (not a
text-buffer simulation) — this is a case where the Emacs approach (dired-as-text-buffer) is
a clever workaround for lacking real GUI widgets, exactly the kind of "no proper GUI widgets"
gap flagged in pain-points.md §16, and the new editor should just build the real widget.

### undo-tree / vundo / undo-fu

**Vundo** (high confidence, github.com/casouri/vundo): renders the buffer's existing undo
history (Emacs's own `buffer-undo-list`/pending-undo structures — it does not replace or
duplicate undo state) as a horizontal tree graph in a side buffer; move between nodes to
preview any past state; commit with RET. On-demand, not always-on (unlike undo-tree, which
must run continuously and maintains its own persistent tree with vertical layout and its own
diffing). undo-fu (not fetched, medium confidence) similarly is a thin wrapper that makes
vanilla Emacs undo/redo linear and predictable without maintaining a redo-branch tree at all.
Native mapping: **undo history must be a first-class, inspectable core data structure**
(a real tree/DAG of edit states with timestamps, not just an undo stack) so that "visualize
history and jump anywhere" is a native, zero-cost UI over existing state — this was one of
Reticle's noted gaps (no vundo-equivalent) and one of Emacs's own worst first-time-user
surprises (§14 in pain-points.md: undo confusion). This is a strong signal that the new
editor's core undo model should be tree-shaped from day one, exposed to a native "time
travel" panel, not an Elisp add-on.

### yasnippet / tempel

**Yasnippet** (medium confidence — WebFetch returned only surface info; architecture from
general knowledge): TextMate-style snippet syntax (`$1`, `$2`, `${1:default}`, mirrored
fields via repeated `$1`); expansion inserts the template and creates a chain of **overlays/
markers** for each tabstop/mirror field, an "active snippet" minor-mode-like state that
intercepts TAB to move between fields and updates mirror overlays live as you type in the
primary field. Snippets are looked up per major mode via a directory-per-mode convention
(`yas-snippet-dirs`) with mode-inheritance fallback. Tempel (not fetched, medium confidence)
is the newer, ~200-line built-in-syntax alternative using Emacs's own template minilanguage.
Native mapping: snippets need (a) a tabstop/mirror **live-region primitive** (linked ranges
that update in lockstep as one is edited — a generically useful text-editing primitive, also
usable for LSP rename-symbol multi-occurrence editing) and (b) per-language-mode snippet
directories resolved through the same extension/mode system as everything else.

### flycheck / flymake, lsp-mode / eglot

Not independently fetched (both are extremely well-known; medium/high confidence from
general knowledge). Flymake (built into Emacs core since 26) and flycheck (third-party,
historically richer/faster-turnaround) both display diagnostics as **overlays with a face**
under the offending text plus **fringe/margin markers** and a mode-line count, refreshed on
an idle timer or buffer-change hook, sourced from either a subprocess linter or (increasingly)
the LSP server's publishDiagnostics. lsp-mode vs eglot: eglot is the minimal, built-in-since-
Emacs-29 LSP client (thin JSON-RPC + native completion/xref/flymake integration); lsp-mode is
the older, more feature-complete but heavier third-party client with its own UI layer
(lsp-ui sideline/peek). Native mapping: diagnostics-as-overlay-with-severity is exactly the
kind of thing that should be **core-native** (a `Diagnostic` type with range+severity+message
rendered via the core text-decoration system), and the LSP client itself should be built into
the Swift core (async, out-of-process per pain-points §1/§6/§12/§19/§22) with Elisp only
configuring server commands/mappings — this matches the owner's stated priority-1 focus on
Verilog/SystemVerilog and secondary languages, where a fast native LSP client matters most.

### org + org-roam + agenda + capture

Not independently fetched (org-roam's README fetch was budget-deprioritized; medium
confidence from general knowledge, cross-checked against pain-points.md §13 on org
performance). Org-mode's core trick is that headings/lists/tables/code-blocks are all just
plain text with a light structural grammar, but Emacs renders folding, TODO states, tags, and
priorities via **overlays and text-properties** (invisible-text-property-driven folding is
notably a major perf bottleneck on large files, per pain-points §13). org-roam adds a
SQLite-backed backlink graph over a folder of org files (id-based links), giving Zettelkasten-
style bidirectional-link browsing and a `org-roam-node-find` completion interface (itself
built on `completing-read`, so it composes with vertico/consult). org-capture is a templated
"quick note from anywhere" popup that files structured entries into a target file/heading.
org-agenda aggregates TODO/deadline/scheduled entries across a set of files into a virtual
view. Native mapping: since org support is explicitly priority-1b for this project, the core
should (a) maintain a **persistent, incrementally-updated outline+link index** (a real
database, not org-roam's bolted-on SQLite cache, and not overlay-based folding that chokes on
large files — this directly fixes pain-points §13), (b) expose capture/agenda as core features
over that index rather than Elisp scanning files on every agenda refresh.

### eshell / vterm / eat

Not independently fetched (medium confidence, general knowledge — directly relevant to the
owner's "app itself should be a terminal like iTerm2" requirement, ground-rule item 6).
Eshell is a pure-Elisp shell (not a real pty — no curses programs work in it, but structured
output stays Lisp-manipulable and it's fully cross-platform without a subprocess). vterm is a
real terminal emulator backed by a **C module (libvterm)** bound into an Emacs buffer via a
dynamic module (fast, full ANSI/curses support, but a C dependency and buffer content is a
terminal snapshot, not structured text). eat is a newer pure-Elisp terminal emulator (no C
dependency, slower than vterm but portable/sandboxable). Native mapping: since the owner
wants the app itself to *be* a full terminal (real pty, run vim/htop/tmux inside), this is not
an Elisp-library decision at all — it must be a **native pty-backed terminal view in the
Swift core** (likely built on the same text-rendering pipeline as the editor, given the
"beautiful GUI + GPU rendering" goals), with an Elisp-scriptable command layer on top
mirroring `shell-command`/`compile`/`M-!` semantics for the non-interactive case.

### helpful / describe-*

Not fetched (medium confidence, general knowledge). Emacs's built-in `describe-function`/
`describe-variable`/`describe-key` introspect a live Lisp system — they can show a function's
actual current definition, source location, and byte-compiled/native-compiled status because
Emacs is homoiconic and self-hosting at runtime. `helpful` (github.com/Wilfred/helpful,
not in the fetch list but conceptually essential) improves the default `*Help*` buffer with
richer info: a function's references (who calls it), its actual source with syntax
highlighting, and interactive "trace"/"disassemble" buttons. This "point at any symbol, see
everything about it, from a running system" capability is one of Emacs's deepest advantages
and is explicitly hard to replicate in a compiled-Swift core, since the Swift side is not
itself introspectable at runtime the way Elisp is. Native mapping: the **shipped Elisp
library and its runtime should be fully self-describing** (docstrings, source-location
metadata, call-graph indexing) exactly like Elisp, even though the host language (Swift) is
compiled — this is a requirement on the *scripting layer's* design, not something the Swift
core can give away for free, and should be flagged as a first-class design goal for the
Elisp dialect (keep docstrings + source-position metadata attached to every defined function/
variable/macro at runtime).

### editing aids

**Multiple-cursors.el** (high confidence, github.com/magnars/multiple-cursors.el): each fake
cursor is an **overlay**; every keyboard command is captured and replayed at each cursor
according to per-command classification lists (`run-for-all`, `run-once`, or ask-and-remember
in `~/.emacs.d/.mc-lists.el` for unknown commands) — this per-command allowlist is a real
maintenance burden and a known fragility source (isearch is explicitly unsupported; redo is
unreliable). Native mapping: real multi-cursor editing should be a **first-class core
input-loop feature** (all cursors are primary, edits genuinely apply to each without a
classify-every-command hack) — this fixes a structural wart in the Emacs implementation, not
just ports it.

**Expand-region.el** (high confidence, github.com/magnars/expand-region.el): grows the
selection outward through semantic units (word -> symbol -> string -> sexp -> statement ->
function) via **syntax tables** plus per-language "mark this construct" functions
(`er/mark-inside-quotes`, `er/mark-method-call`, etc.), with a fallback chain tried in order
until one matches and is larger than the current region. Native mapping: this is exactly what
a **tree-sitter-backed "select enclosing node" operation** does much more robustly than
syntax-table heuristics — since the plan already commits to tree-sitter-first parsing
(pain-points §24 principle 6), semantic-expand-selection should be a **core primitive
implemented directly on the parse tree** (walk up to parent node), not a per-language
heuristic library.

**wgrep** (medium confidence, github.com/mhayashi1120/Emacs-wgrep — fetch was thin):
makes a grep/occur results buffer directly editable (wdired-style toggle), tracks edited
lines, and on save propagates the edits back into the *original* file buffers/files —
implemented via toggling read-only-ness and (per wdired's known design, used here by
analogy) markers that keep pointing at the original file location even as result-buffer text
is edited. Native mapping: "editable search results that write through to source files" is a
generically desirable feature for any project-wide search UI — pairs naturally with rg/
deadgrep-style async search (not independently fetched; ripgrep-backed live search UI) and
should be a built-in mode of the core's project-search results view, not a bolt-on.

**rainbow-delimiters, hl-todo, iedit** (not fetched; low/medium confidence, general
knowledge): rainbow-delimiters colors nested bracket pairs by depth via a
`font-lock`/text-property hook keyed on syntax-table paren-matching; hl-todo highlights
TODO/FIXME/NOTE comment keywords via font-lock keyword regexps; iedit lets you edit all
occurrences of the symbol at point simultaneously in-place via **linked overlays** (similar
mechanism to yasnippet's mirror fields, and to what LSP rename-symbol needs). Native mapping:
all three are font-lock/text-decoration-tier features that belong in the **core syntax-
highlighting and linked-region primitives**, not separate packages — iedit in particular
should just be a UI over the same live-linked-region primitive proposed for
snippets/rename.

### hydra / transient (transient states)

Covered under "magit + transient" above; hydra (not fetched, medium confidence) predates and
is functionally similar to transient — a repeatable, discoverable keymap overlay for chords
like window-resizing (`hydra-resize`) — but transient has become the modern standard because
it composes with argument/flag state, while hydra is simpler pure-repeat menus. Both map to
the same core transient-menu primitive proposed above.

### doom-modeline

Not fetched (medium confidence, general knowledge): a heavily-customized mode-line
replacement showing buffer state, VC branch/diff-stat, diagnostics counts, encoding, and
icons, built on all-the-icons/nerd-fonts glyphs and `mode-line-format`'s construct
mini-language plus text-property `:propertize` segments for click-to-act regions. Native
mapping: the status/mode line should be a **native, GPU-composited status bar with a
declarative segment API** (segments contribute text/icon/click-handler), not a text-property
hack over a single-line buffer-local string — this is one of the clearest "look at what Emacs
does with a plain-text-only rendering model and give it a real native widget instead" cases.

### keyboard macros, registers/bookmarks, recentf/savehist, winner, ace-window, xref/dumb-jump

Not fetched (all built into GNU Emacs core except ace-window/dumb-jump; high confidence from
general Emacs knowledge, since these are documented core Emacs features, not third-party
research targets). Keyboard macros (`C-x (`/`C-x )`, `F3`/`F4`) record/replay a literal
keystroke sequence — trivially generalizes to a native macro recorder over the core input
event stream. Registers/bookmarks persist locations/text/window-configs by single-character
or named key into a global alist, saved via `savehist`; `recentf` tracks recently-opened
files; `winner-mode` keeps an undo/redo ring of *window-configuration* changes (not buffer
edits) so you can undo a window-layout mistake; `ace-window` (not fetched; label-overlay
window picker, same mechanism as avy) numbers/labels all windows for one-key jump; `xref` is
Emacs's generic "go to definition / find references" framework with pluggable backends
(etags, LSP via eglot), and `dumb-jump` is a regexp/ripgrep-based xref backend that works with
zero language-server setup. Native mapping: window-configuration undo (winner) and
label-overlay window-jump (ace-window) are cheap, high-value **core window-manager features**;
xref's pluggable-backend pattern (generic command, swappable data source) is the same shape as
the completion-table and completion-at-point protocols above — the core should have one
"pluggable navigation backend" abstraction reused for definitions/references/symbols/errors.

### smartparens/paredit, ligatures, dashboard, popper/popup rules, workspaces/perspectives

Not fetched (medium confidence, general knowledge). Paredit/smartparens keep parens/brackets/
quotes structurally balanced as you type and provide structural (sexp-aware) editing
commands, built on **syntax tables** (paredit) or a **hand-rolled pair-scanning engine**
(smartparens, which also supports non-lisp "pseudo-structural" pairs like HTML tags). Font
ligatures are handled by Emacs's `composition` text-property mechanism mapping character
sequences (`->`, `!=`) to a single rendered glyph. `dashboard` is a startup buffer showing
recent files/projects/bookmarks. `popper` classifies "popup" buffers (compilation output,
help, REPLs) by regexp/mode and gives them a dedicated toggle-able bottom/side window instead
of stealing focus/splitting unpredictably — a curated policy over Emacs's `display-buffer`
window-placement rules, one of Emacs's most notoriously under-designed subsystems.
Perspective.el/persp-mode implement named workspaces (window-configuration + buffer-list
scoping) on top of `frame`/`window-configuration` primitives. Native mapping: structural
editing on brackets is another tree-sitter-node-boundary operation once tree-sitter is core;
ligatures map directly to a native font-shaping feature (Core Text supports OpenType
contextual ligatures natively — likely cheaper/more correct than Emacs's composition-property
hack); popup-window placement policy and workspaces are exactly the kind of thing that needs
a **first-class, declarative window-manager policy engine** in the core (rules: buffer
category -> placement), replacing `display-buffer`'s notoriously confusing rule-matching
(a pain point Emacs users routinely fight with fresh configs).

### TRAMP, ediff, occur, isearch/anzu, casual, embark-act

Not fetched (medium confidence, general knowledge; TRAMP's performance problems are already
covered in pain-points.md §20). TRAMP provides transparent remote/sudo file editing by
making file-name-handlers intercept every I/O primitive for `/ssh:host:/path`-style names —
architecturally elegant (every Emacs command "just works" remotely) but synchronous and slow
per pain-points §20; the fix (async remote I/O, background indexing) is already captured
there. Ediff is a structural side-by-side diff/merge UI. Occur lists all matches of a regex
in a buffer as a live, jump-linked results list (the ancestor of consult-line). isearch is
Emacs's incremental search-as-you-type; anzu overlays a live "N/M matches" counter on top of
it via advice + overlay. `casual` is a newer project wrapping several built-in commands
(calc, dired, isearch, info) in transient menus for discoverability — evidence that "transient
menu over an existing dense command set" is considered a generally desirable UI pattern, not
git-specific. `embark-act` is covered under the completion stack above. Native mapping:
occur/isearch-with-live-count should be native, fast, incremental-search features with a
built-in match counter (no advice hack needed); ediff's side-by-side structural diff view
belongs in core given git integration is core; TRAMP's remote file abstraction should be a
core async I/O layer (already implied by pain-points §24 principle 1).

## 4. Minimum set for week-one "feels like home"

An expert Emacs user (Doom/Prot/Purcell-caliber) judges a new editor's competence fast. If
these are solid at launch, the "this isn't Emacs but I could live here" reaction is likely:

1. **Fuzzy/orderless everything picker** — one unified `completing-read`-equivalent for
   files, buffers, commands, symbols, grep results, with live preview and narrowing
   (vertico+consult+orderless+marginalia equivalent). This is the single highest-leverage
   item; almost everything else is a client of it.
2. **In-buffer completion popup fed by multiple sources ranked together** (LSP + snippet +
   buffer words) — corfu+cape equivalent.
3. **Which-key-equivalent keybinding HUD**, always on, zero-config — the cheapest
   discoverability win and expected by default now that it is entering GNU Emacs core.
4. **Native, fast, built-in Git porcelain** with a Magit-quality status view (stage/unstage by
   hunk/line, one-key commit/push/rebase menus) — this is the single most emotionally-loaded
   comparison point for an Emacs power user evaluating a new editor.
5. **Transient-style command menus** for any command with more than ~3 optional flags
   (compile, project search, git, LSP actions) instead of nested dialogs.
6. **Async project-wide search with writable results** (ripgrep-backed, wgrep-style
   write-through) and an xref-style pluggable go-to-definition/references.
7. **A real tree/DAG undo model with a visual history browser** (vundo-equivalent) — cheap to
   build if the undo model is designed right from day one, and directly fixes a top-5 Emacs
   pain point.
8. **Optional modal (vi) editing as a togglable layer**, not required, but its absence would
   be a dealbreaker for a meaningful fraction of this exact audience (evil users are a
   supermajority among "world-class" configs referenced in this brief).
9. **A real, responsive integrated terminal (native pty)** — this is explicit in the owner's
   own brief (ground rule 6) and also closes the eshell/vterm gap in one native feature
   instead of three competing Elisp implementations.
10. **Org-mode file-compatible editing with folding that stays fast on large files**, plus
    capture and agenda — org support is explicit priority-1b in the brief, and Reticle already
    proved file-format compatibility is achievable; the new bar is *not degrading past what
    org-roam+consult already deliver* while fixing org's known large-file slowness.

Deliberately excluded from week-one: org-roam's full backlink graph UI, dirvish's preview
pane polish, doom-modeline's icon theming, workspaces/perspectives, TRAMP — all valuable but
tolerable to ship slightly after the above, since none of them is what an expert reaches for
in the first hour of real work.

## 5. Unverified claims

- Magit's internal architecture (section/overlay/text-property model, exact transient
  integration points) is stated from general knowledge, not confirmed by this run's WebFetch
  of github.com/magit/magit, which returned only marketing copy, not source/manual content.
- Evil-mode's internal state-machine details (per-state keymap layering via
  `minor-mode-keymap-alist`, pending-operator implementation) are from general knowledge; the
  WebFetch of github.com/emacs-evil/evil returned only a file listing, not architecture docs.
- Yasnippet's overlay/marker-based field-tracking mechanism is inferred from general knowledge
  of TextMate-style snippet engines; the WebFetch of the repo did not surface implementation
  detail beyond snippet-syntax provenance and per-mode directory lookup.
- Marginalia, orderless, embark, cape, org-roam, ace-window, dumb-jump, hydra, popper,
  smartparens/paredit, doom-modeline, helpful, wgrep's marker mechanism specifics, dirvish,
  treemacs, and TRAMP/ediff/anzu/casual were **not independently fetched** in this run at all
  (budget was spent on the 15 higher-priority URLs above); everything said about them is
  general background knowledge cross-checked for internal consistency with the fetched
  packages' documented mechanisms (e.g. assuming marginalia keys off the same completion
  metadata Vertico documented reading), not a primary-source citation. Treat these as
  plausible but not verified — a follow-up pass should fetch
  github.com/minad/marginalia, github.com/oantolin/{embark,orderless}, github.com/minad/cape,
  and org-roam's README directly if these details need to be load-bearing for a spec.
- Doom Emacs's exact module count ("~150 modules") and the specific claim that `doom sync`
  "regenerates the package/autoload cache" are WebFetch-summarized, not verified against
  Doom's actual `core/` source or CHANGELOG.
- No claims in this report were checked against a running `emacs -Q --batch` probe — all
  package behaviors described here are third-party-package behavior, not core-Emacs behavior,
  so the local Emacs 30.2 binary is not the right verification tool for most of this topic
  (it would only help for e.g. confirming which-key's core-merge status or eglot's built-in
  presence, neither of which was probed).

## Sources

Fetched this run (WebFetch, HTML->markdown summarized by an intermediate model, so treat as
paraphrase of the README rather than verbatim text):
- https://github.com/doomemacs/doomemacs
- https://github.com/purcell/emacs.d
- https://github.com/minad/vertico
- https://github.com/minad/consult
- https://github.com/minad/corfu
- https://github.com/magit/magit (thin result — no architecture detail returned)
- https://github.com/magit/transient
- https://github.com/emacs-evil/evil (thin result — file listing only)
- https://github.com/justbur/emacs-which-key
- https://github.com/casouri/vundo
- https://github.com/abo-abo/avy
- https://github.com/joaotavora/yasnippet (thin result)
- https://github.com/magnars/multiple-cursors.el
- https://github.com/magnars/expand-region.el
- https://github.com/mhayashi1120/Emacs-wgrep (thin result)

Not fetched (WebSearch quota exhausted per task instructions; general background knowledge
used instead, see §5 Unverified claims): marginalia, orderless, embark, cape, org-roam,
lsp-mode, projectile, dirvish, treemacs, hydra, popper, gptel, smartparens/paredit,
doom-modeline, helpful, TRAMP, ediff, anzu, casual, ace-window, dumb-jump.

Cross-referenced local file: `emacs-pain-points.md` §13, §16, §20, §24 (this project's
scratchpad, same research run series).
