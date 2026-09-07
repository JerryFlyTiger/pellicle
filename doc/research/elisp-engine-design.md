# Emacs Lisp engine design for pellicle — compatibility without a bottomless pit

Status: draft, single research pass. Builds on `spikes/RESULTS.md` (value representation,
JIT feasibility), `research/jit-on-macos.md` §10 (staged JIT plan), and
`research/swift-interpreter-perf.md` §11 (Swift performance conclusions). Does not repeat
their content; cites by section number instead.

## 0. Method note

GNU Emacs 30.2 at `/opt/homebrew/bin/emacs` used as the live semantic oracle throughout
(`emacs -Q --batch --eval ...`). Claims tagged **[oracle]** were directly executed against
that binary today (2026-09-05) and are high-confidence. Claims tagged **[reticle]** come
from reading `/Users/jerrychen/My_Projects/reticle` source read-only (high-confidence for
"what Reticle does", not a semantics oracle for real Emacs). Claims tagged **[fetch]** come
from a WebFetch of a primary source URL, cited at point of use and in §18. Everything else
is stated from general knowledge of Emacs Lisp and marked **[general]** — treat these as
medium-confidence and re-verify against the oracle before relying on a specific detail in
implementation. WebSearch was unavailable (session quota exhausted per instructions); 2 of
the allowed 20 WebFetch calls were used, both high-yield (GNU sources), so budget was not
the limiting factor — oracle queries against the local Emacs binary were preferred wherever
they could answer the same question, since they're free and higher-confidence than a fetch
summary.

## 1. Tiered compatibility target

The owner's brief is explicit: users come from Doom/Purcell-style setups and write configs
in Elisp, but pellicle does not commit to running arbitrary GNU packages. That means the
target is **"a config author's Elisp always works; a package author's Elisp usually works
for the packages we chose to port; nothing promises byte-for-byte parity with the C core."**

**Tier 1 — must-have for configs to load and behave (the `init.el` surface).**
Reader (full syntax), lexical binding as default with `;;; -*- lexical-binding: t -*-`
cookie support (and the historical `nil` default respected per-file, since ported package
files may still say `lexical-binding: nil` or omit it), `defvar`/`defcustom`/`setq`,
`let`/`let*` incl. buffer-local dynamic rebinding, all 22 special forms **[oracle]**,
`defun`/`defmacro`/`lambda`/closures, `require`/`provide`/`autoload`/`load-path`,
`condition-case`/`signal`/`error`/`user-error`, `catch`/`throw`, `unwind-protect`, hooks
(`add-hook`/`run-hooks`/`run-hook-with-args`), basic keymaps (`define-key`, `global-set-key`,
`use-package`-style `:bind`), `defgroup`/`defcustom`/`customize` enough to not error (does
not need the Customize UI), `use-package` macro itself (it's a macro-only dependency —
expands entirely at compile/load time into `require`/`bind-keys`/etc., so shipping it is
cheap and removes the single biggest Doom/Purcell compatibility blocker), buffer-local
variables and `make-local-variable`/`setq-local`/`with-current-buffer`, basic process/timer
primitives so config code that starts a server or schedules an idle function doesn't error
at load time even if the process backend is thin initially.

**Tier 2 — for porting popular packages (evil, magit, org, company/corfu, projectile,
lsp-mode/eglot, which-key, vertico/consult, treesit-based modes).** `cl-lib` (`cl-defun`,
`cl-defstruct`, `cl-loop`, `cl-case`, `cl-typecase`, generic dispatch subset), `seq.el`,
`map.el`, `pcase` (used pervasively by magit/eglot internals), `subr-x` (`when-let*`,
`if-let*`, `thread-first`/`thread-last`, `string-trim` family — some now built into `subr.el`
core in Emacs 29+ **[general, re-check against 30.2]**), `nadvice.el` (`advice-add` —
magit and many packages patch core functions; confirmed **[fetch]** it wraps the function
cell in an OClosure-shaped `(car cdr how props)` chain, not a source patch, so an engine
only needs `fset`/function-cell indirection + a combinator table, not source rewriting),
full regex incl. `\_<`/`\_>` symbol-boundary, backreferences, syntax-class regex `\s-`/`\Sw`
(needed by font-lock and many indentation functions), syntax tables +
`syntax-ppss`/`forward-sexp`/`scan-sexps` (needed by nearly every language mode and by
`show-paren-mode`/`electric-pair-mode`), `define-derived-mode`/`define-minor-mode` (Reticle
explicitly lacks this — **[reticle]** confirmed absence in README "Known limitations"),
overlays with priority/face/keymap properties, markers that survive edits, text properties
incl. `read-only`/`invisible`/`display`, `format` with full C-style width/flags/precision
(Reticle's `%-6s`/`%5d`/`%.2f` gap **[reticle]** is exactly the kind of thing package code
relies on), asynchronous `make-process`/`start-process` with filters and sentinels (needed
by any LSP client, magit, compilation-mode), idle timers, `run-with-timer`, threads
(`make-thread` — many packages just no-op if absent, but eglot/lsp-mode assume
`accept-process-output` semantics work correctly while other timers still fire).

**Tier 3 — never (explicitly out of scope, matching "no bottomless pit").** GNU's C-level
internals a package should never poke directly but some do: `emacs-module.h` dynamic-module
ABI (Reticle already excludes this **[reticle]**; re-implementing the C ABI for arbitrary
`.so`/`.dylib` modules is a multi-month undertaking with negative ROI when the target is a
curated package set); native-comp (`.eln` compilation via libgccjit) — irrelevant, since
pellicle's own bytecode/JIT tiers replace the reason native-comp exists; TTY/terminfo
line-discipline compatibility (X11/termcap-era code paths); obsolete APIs frozen for
backward compat only (`cl.el` old-style, `common-lisp-indent-function`'s more obscure
corners); byte-for-byte compatibility with `.elc` files compiled by GNU Emacs's own
`bytecomp.el` (pellicle must compile Elisp *source* itself — pre-compiled `.elc` blobs
from GNU's compiler encode GNU's opcode numbering, not pellicle's; **[general]**, Reticle
made the same call implicitly by having its own compiler); multi-frame/multi-tty display
server code irrelevant to a single-window macOS app initially; `gnutls`/`tramp`'s full
method zoo beyond SSH (Reticle already narrowed this to SSH-only key-auth **[reticle]** —
inherit that scope, don't widen it just because "Emacs has it").

## 2. The reader

Full syntax coverage is Tier 1 because a config file that fails to *read* fails completely,
unlike a function that fails to *run* (which at least degrades one feature). Verified today
**[oracle]**:

- `#s(hash-table test eq data (a 1 b 2))` reads to a hash-table object directly (the reader,
  not `read-from-string` post-processing, handles `#s(...)`).
- `#&N"bits"` bool-vector syntax reads (`#&5"\x1f"` round-tripped).
- Char syntax: `?\C-x` → 24 (`0x18`, i.e. `x & 0x1f` for a letter), `?\M-x` → 134217848
  (`(2**27) | ?x`, the Meta bit is bit 27 in Emacs's internal character representation, not
  a separate modifier byte), `?\C-\M-x` → 134217752 (both bits combined). This matters
  directly for engine design: **Emacs characters are not bytes**, they're integers up to
  ~22-27 bits with modifier bits packed in high positions, and the reader must reproduce
  this bit-packing exactly for `?\C-`, `?\M-`, `?\S-`, `?\H-`, `?\s-`, `?\A-` combinations,
  or every third-party mode that computes on char codes silently breaks.
- Reader-level `TAB` (`?\^I`) and `?\C-i` are both plain integer 9 — **the "TAB vs C-i"
  distinction is not a character-code distinction at all**; it only exists at the
  *key-event* layer where GUI frames can deliver a `tab` function-key symbol event distinct
  from a literal Ctrl+I keypress event. `(kbd "TAB")` reads as the string `"\t"` (char 9)
  while `(kbd "<tab>")` reads as the vector `[tab]` — two different Lisp objects bound
  through two different keymap lookup paths **[oracle]**. See §9.
- Symbols-with-position (`symbols-with-pos-enabled`, used by newer `pcase`/`macroexp` error
  reporting) and reader shorthands (`read-symbol-shorthands` file-local variable, lets a
  file write `pk-foo` and have it read as `package-foo`) are Emacs 28+/29+ features some
  modern packages' macros rely on for good error messages; **[general]**, not independently
  spiked this session — treat as Tier 2, needed for good error UX porting recent packages
  but not for basic loading.

**Design for pellicle's reader:** a hand-written recursive-descent/state-machine reader
operating on `String.utf8`/raw bytes per swift-interpreter-perf.md §11's lexing guidance,
not grapheme-cluster iteration; must produce the tagged-word `Value` representation directly
(no intermediate boxed AST) per spikes/RESULTS.md #3's tagged-word conclusion. Needs: `#'`
function-quote, `` ` ``/`,`/`,@` backquote (see §4), `#x`/`#o`/`#b` radix literals, `#[...]`
raw bytecode-object literal syntax (used inside pre-compiled forms; pellicle's own
compiler can just skip emitting this and use its own internal representation — **do not**
try to parse GNU's `#[...]` byte-string payload, since it's GNU's opcode encoding, not
transferable, consistent with the Tier-3 call on `.elc` above), `?\N{...}` Unicode name char
literals, and circular-structure `#1=`/`#1#` labels (used in some serialized data, rare in
configs but occasionally emitted by `pp`/`prin1` round-trips of complex data — Tier 2).

## 3. Dynamic vs lexical binding, buffer-locals, and the threading model

Emacs's binding model is the single most load-bearing piece of semantics for compatibility,
because `defvar`-declared "special" variables are pervasive in real configs (every
`use-package :custom`, every mode's option variable) and their *dynamic* scoping (as opposed
to the lexical scoping every other binding gets under `lexical-binding: t`) is exactly the
mechanism buffer-local variables piggyback on.

**Model [general, standard Emacs semantics, cross-check against oracle recommended before
implementation]:**
- Every symbol has a **global value cell**. `defvar`/`defconst` at top level marks the
  symbol *special* (a property on the symbol, not the value) — from that point on, *any*
  `let` binding of that symbol name, anywhere, in any lexically-scoped file, becomes dynamic
  again for the extent of that `let`. This is why `defvar` inside a `(when nil ...)` still
  works as a declaration in real Emacs — it's a compile-time-ish marking effect, not a
  runtime value assignment, and it is global once done (loading order matters for whether a
  later file's `let` on that name is treated as lexical or dynamic).
- A **buffer-local value** is a *second* cell, attached to (symbol, buffer) pairs, checked
  first when the symbol is "buffer-local in this buffer" (via `make-local-variable`,
  `setq-local`, or `make-variable-buffer-local` for automatic per-buffer locality on any
  `setq`). The **default value** (`default-value`/`setq-default`) is the fallback for
  buffers that haven't localized it — this is a third slot, distinct from "the global value
  as seen from a buffer with no local binding," though in practice they coincide unless code
  explicitly diverges them.
- **`let`-binding a buffer-local variable** dynamically saves/restores *whichever cell is
  currently active for the current buffer* at bind time — if buffer A has localized `foo`
  and buffer B hasn't, `(let ((foo 1)) ...)` executed with A current saves A's local cell;
  with B current it saves the default/global cell. Switching the current buffer *inside* the
  extent of such a `let` does not "follow" the binding to the new buffer's local cell — the
  save/restore pair is bound to whichever cell was resolved at entry. This is a genuine
  Emacs gotcha real package authors trip over and any compatible engine must reproduce
  exactly, not approximate.
- **specpdl**: Emacs implements all of this with a single global stack of "specbindings"
  (the "special pdl") — each dynamic `let` pushes an entry recording (symbol, old value,
  which cell) and `unbind_to` pops back to a saved stack depth on scope exit *or* on
  non-local exit (`throw`, `signal`, `unwind-protect` triggering). This is precisely how
  Emacs guarantees dynamic bindings are restored even through non-local control flow, and
  it's the natural design to port: a flat specpdl vector in the interpreter state, entries
  tagged by kind (plain dynamic var / buffer-local cell / `unwind-protect` cleanup thunk /
  catch tag), unwound by popping to a saved index. Reticle's bytecode already has this shape
  — `DynBind(SymId)` / `DynUnbind(count)` instructions **[reticle]** (`bytecode.rs`) — this
  is proven-workable prior art to build on directly rather than re-deriving.

**Design for pellicle's buffer-local variables (concrete proposal):**
- Global value cell: a flat array indexed by interned `SymId` (matches spikes' tagged-word
  design; O(1) global lookup, no hashing on the hot path).
- Buffer-local cell: each `Buffer` object owns a small hash map `SymId -> Value` for
  variables it has localized, plus a bitset/hashset of "which SymIds are buffer-local *in
  general*" (the `make-variable-buffer-local` automatic-localization flag) kept globally so
  a plain `setq` can check in O(1) whether it should auto-localize.
- Symbol-level flags needed per the model above: `is-special` (defvar'd — dynamic scoping
  applies to `let`), `is-always-buffer-local` (from `make-variable-buffer-local`), a
  `default-value` slot separate from the global slot when they've diverged (can start as
  "same slot, copy-on-first-setq-default-divergence" to avoid paying for the common case
  where they never diverge — an optimization Reticle-style engines should consider but which
  needs its own correctness spike before committing).
- specpdl entries carry an enum: `{ dynamicGlobal(sym, oldValue), dynamicBufferLocal(sym,
  buffer, oldValue), unwindProtect(thunk), catchTag(tag) }` so `unbind_to`-equivalent code
  is one dispatch loop regardless of what's being unwound — mirrors Reticle's proven
  approach and gives a single place to add GC root-visibility for the saved-value payloads
  (spikes' arena/GC design in swift-interpreter-perf.md needs specpdl entries to be
  GC-visible roots, since a `let`-saved old value can be the only live reference to it).

**Threading model — the load-bearing constraint.** swift-interpreter-perf.md §11 already
concluded (High confidence, SE-0392/SE-0412 primary sources) that the interpreter must run
on **one dedicated thread/executor**, never hopped mid-evaluation. This is not just a
performance choice, it is a **correctness requirement for the binding model just described**:
specpdl, the global-value array, and every buffer's local-variable map are the kind of
globally-mutable, order-dependent state that a dynamic-binding stack fundamentally is — two
Lisp evaluations interleaving on different threads against one specpdl is not a performance
bug, it's a semantic impossibility (Emacs itself has exactly this property: it is
single-threaded for Lisp evaluation even though `make-thread` exists — see §14). Concretely:
**there is exactly one Elisp interpreter thread; the UI thread never evaluates Elisp
directly**, it only (a) enqueues events/commands for the interpreter thread to run and (b)
reads back buffer/display state the interpreter thread has finished mutating, using
whatever cross-thread synchronization macOS's AppKit/text-rendering pipeline requires
(likely a snapshot-and-hand-off pattern, matching the "JetBrains model" already chosen for
background analysis work per PLAN.md's M15 note — read-only snapshots for cross-thread work,
never live mutation from a second thread). `make-thread` (Emacs 26+ genuine OS threads) can
exist in pellicle as a *user-facing* feature backed by the same GIL-like global-interpreter
mutex Emacs itself uses (only one thread runs Lisp at a time even with `make-thread`,
per Emacs's actual design **[general]** — verify against oracle/`threads.c` before building
if this feature is prioritized; it is Tier 2 at best since it's rarely load-bearing in
configs).

## 4. Evaluator: special forms and macro expansion

**The complete special-form list, verified today [oracle]** (22 total; the `mapatoms` +
`special-form-p` scan across all 17,928 interned symbols in a bare `-Q` session found
exactly these):

```
and catch cond condition-case defconst defvar function if inline interactive
let let* or prog1 progn quote save-current-buffer save-excursion
save-restriction setq unwind-protect while
```

(21 shown; `function` and `quote` both count, giving 22 with `interactive` — the scan
printed 21 distinct symbols but the count query independently returned `special=22`; the
one-off discrepancy needs a second pass before finalizing the list for implementation —
flagged in §17, likely `#'` reader macro for `function` producing a duplicate mapatoms hit
worth re-checking, not a semantic gap.)

All of these are Tier 1 — a config cannot avoid using `let`, `if`, `cond`, `and`/`or`,
`unwind-protect`, `condition-case`, `while`, `setq`. `save-excursion`/`save-restriction`/
`save-current-buffer` are specifically about point/mark/narrowing/current-buffer being
dynamic state that must be saved via the same specpdl mechanism as §3 (they're really sugar
over "push a specpdl entry that restores buffer state, then unwind-protect-style pop it"),
so implementing specpdl correctly gets these almost for free.

**Everything else load-bearing is a macro, not a special form** — `when`, `unless`, `dolist`,
`dotimes`, `pcase`, `cl-case`, `with-current-buffer`, `setq-local`, `push`/`pop`,
`ignore-errors`, all expand via `macroexpand` to combinations of the 22 forms above plus
function calls. This is the leverage point: **implementing 22 special forms + a correct
macro expander + backquote gets a very large fraction of the language for free**, because
the Elisp standard library itself is written this way. Reticle's own approach (writing an
Elisp standard library in Elisp, `crates/core/lisp/` **[reticle]**) is the right model to
keep: ship a pellicle-authored `subr.el`/`simple.el`-equivalent in Elisp itself rather than
hand-porting every macro to Swift, and get correctness by testing it against the same
`emacs -Q --batch` oracle used in this report.

**Backquote**: `` ` ``/`,`/`,@` desugars to `list`/`append`/`cons` calls by the reader or an
early macro pass (GNU's `backquote.el`); this is a small, well-understood piece of code
worth porting near-verbatim rather than reinventing, since its edge cases (nested backquote
levels, `,@` at various positions) are exactly the kind of thing that's easy to get subtly
wrong and hard to notice until a macro-heavy package (which is most of them) breaks.

**Macro expansion timing**: real Emacs expands macros lazily at the point of use during
evaluation (tree-walker) or ahead-of-time during byte-compilation (bytecode path) — the same
macro can therefore be re-expanded on every call in interpreted mode. A production engine
should **compile by default** (matching Reticle's stated direction "Ship with a
`(byte-compile)` that runs by default on load" from jit-on-macos.md §10 Stage 1) precisely
to avoid repeated macro-expansion cost, but the tree-walking fallback tier must still expand
macros correctly for code paths that reach `eval` on freshly-read forms (e.g. `M-:`,
`eval-region`, `ielm`).

## 5. condition-case/signal, catch/throw, unwind-protect

Confirmed condition hierarchy today **[oracle]**:

| Symbol | `error-conditions` |
|---|---|
| `error` | `(error)` |
| `quit` | `(quit)` — **not** a subcondition of `error` |
| `wrong-type-argument` | `(wrong-type-argument error)` |
| `args-out-of-range` | `(args-out-of-range error)` |
| `void-variable` | `(void-variable error)` |
| `void-function` | `(void-function error)` |
| `wrong-number-of-arguments` | `(wrong-number-of-arguments error)` |
| `arith-error` | `(arith-error error)` |
| `file-error` | `(file-error error)` |
| `file-missing` | `(file-missing file-error error)` — three-level chain |
| `end-of-file` | `(end-of-file error)` |
| `user-error` | `(user-error error)` — Tier 1: `(user-error "msg")` is the idiomatic way
  interactive commands report user mistakes without a backtrace |
| `cl-no-applicable-method` | `(cl-no-applicable-method cl-no-method error)` |
| `scan-error` | `(scan-error error)` — signaled by `forward-sexp`/`scan-sexps`, so needed
  once §8's syntax machinery exists |

The **`quit` not being a subcondition of `error`** is the single most important correctness
property here, and Reticle already independently arrived at the identical design for its own
`elisp-timeout` condition (PLAN.md M15: "`elisp-timeout` is deliberately not a subcondition
of `error`... a hook wrapping itself in `ignore-errors` cannot swallow the interruption
either" **[reticle]**) — confirming Reticle's designer correctly intuited real Emacs's actual
`quit` semantics independently. **pellicle should keep `quit`/interrupt as a condition
strictly outside the `error` hierarchy**, and any pellicle-specific interrupt condition
(timeout, budget-exceeded — see PLAN.md M15 hook budgets) should follow the same rule: only
an explicit handler for that exact condition symbol (or `t`/`condition-case`'s catch-all,
which real Emacs's `condition-case` *does* allow via the `t` handler — verify) can intercept
it, `(error ...)`-scoped handlers must not.

`condition-case`/`signal`/`error` is Tier 1 in full: `condition-case` handler clauses match
by testing whether the signaled condition's `error-conditions` list intersects the handler's
declared condition(s), `:success` handler clause (Emacs 25+, runs on non-error return),
`condition-case-unless-debug`, and the `err` variable binding a `(SYMBOL . DATA)` cons. Also
Tier 1: `condition-case`'s implicit `unwind-protect`-like cleanup ordering when combined with
other handlers up the stack must be correct, since packages nest these constructs freely
(e.g. `unwind-protect` wrapping a `condition-case`, or vice versa) and getting the interleave
of specpdl unwinding vs. handler search order wrong produces bugs that only manifest under
error conditions — exactly the kind of bug that's invisible in a demo and devastating in
production. `catch`/`throw` is a simpler, separate non-local-exit mechanism (tag-based, not
condition-based) but shares the same underlying "unwind to a saved specpdl/stack depth"
machinery — implement both on one unwinding primitive.

## 6. Closures and the GNU bytecode design vs. a tagged-word VM

**GNU's bytecode.c design, confirmed via fetch [fetch]**: a stack-based bytecode interpreter
with ~90+ opcodes, dispatched via **threaded dispatch** (GCC computed-goto over a 256-entry
`void*` table when available, falling back to a plain `switch` otherwise) rather than a naive
switch everywhere. Notable opcode groups: `Bstack_ref` has **7 numbered variants** (dedicated
opcodes for referencing stack slots 1-7 back, avoiding an operand byte for the common shallow
case — a cheap superinstruction-like optimization), `Bcall` similarly has **8 numbered
variants** for 0-7 argument calls (again avoiding an operand fetch for the overwhelmingly
common small-arity call). Type-checking is inlined before dispatching to generic paths (e.g.
`Bplus` checks both operands are fixnums inline before falling back to generic `+`) — this is
exactly the "fast-path arithmetic...pop the operands, run the common case inline...fall back
to calling the real builtin" pattern Reticle's own bytecode compiler already implements
**[reticle]** (`bytecode.rs` `Instr` doc comments describe the identical strategy). Quit
checking is done via a `quitcounter` incremented on **backward branches only** (`new_pc <
pc`), checked against a threshold before calling `maybe_quit()` — i.e. GNU only samples for
interruption at loop back-edges, not on every instruction, which is the same design point
jit-on-macos.md §10 Stage 0 already recommends ("Back-edge and call-entry check...JSC's
points model") and that Reticle already ships (PLAN.md M15: check every 64 steps, ~[reticle]).
This is now triple-corroborated (GNU's real design, JSC's design per prior research, and
Reticle's own measured-safe implementation) — high confidence this is the right interruption
strategy for pellicle's VM too.

**What to keep vs. change for a tagged-word VM with inline caches:**

*Keep:* the stack-machine shape (locals + operand stack, not a register machine — simpler
compiler, and Reticle's own VM already validates this shape at ~8x over tree-walking
**[reticle]**); numbered small-arity superinstructions for `stack-ref`/`call` exactly as GNU
does — cheap to add, removes an operand-byte fetch from the hottest paths; back-edge-only
interrupt sampling; inline fixnum fast paths before falling back to generic dispatch for
arithmetic/`car`/`cdr`/`cons`/`aref`/`eq`.

*Change:* GNU's bytecode operates on **boxed Lisp_Object values manipulated through C**, with
no inline caching for `symbol-value`/`funcall`/property lookups — every global variable
reference and every function call re-resolves from scratch (a hash/array lookup) on every
execution. jit-on-macos.md §10 Stage 1 already specifies the upgrade: "quickened
`symbol-value`/`funcall`/`get-text-property` with inline caches" — this is a genuine design
improvement over GNU's own bytecode, not merely porting it, and is the highest-leverage
single addition given that config/package code repeatedly re-reads the same small set of
`defcustom` variables and calls the same small set of functions in hot loops (font-lock,
`post-command-hook` chains). GNU's design has no IC slots reserved in its instruction
encoding at all (each opcode is a single byte, occasionally followed by a 1-2 byte operand);
pellicle's bytecode should reserve fixed-width operand fields with unused padding for an
inline-cache slot (function-redefinition epoch + cached resolved target) from the start, per
jit-on-macos.md §10 Stage 0's explicit call-out ("Bytecode with fixed-width operands and
reserved inline-cache slots"). Also change: GNU's `Value` is a boxed/tagged
pointer-into-a-C-struct-heap (Lisp_Object), which is a different representation strategy than
the tagged-64-bit-word-plus-manual-arena spikes/RESULTS.md #3 already measured and chose for
Swift (High confidence) — the bytecode *shape* (opcodes, stack machine, dispatch strategy)
transfers, the underlying `Value` representation does not and should follow the Swift-native
spike result instead.

**Closures**: Reticle's `MakeClosure`/`PushFrame`/`PopFrame`/`EnvDefine` design
**[reticle]** (captures the lexical frame chain by reference, not by snapshot — "closures
capture variables, not values", matching real Elisp's actual semantics under
`lexical-binding: t`) is correct and should be inherited directly rather than re-derived;
it also correctly distinguishes captured/free variables (`EnvDefine`, heap-allocated frame
slot, shared with the defining function) from purely local slots (`LoadLocal`/`StoreLocal`,
can live on the VM's flat stack with no separate heap frame when nothing captures them) —
this local/captured distinction is exactly the optimization a naive port would miss (boxing
every local "just in case" is a measurable tax; Reticle already avoids it).

## 7. Strings, symbols, obarrays, text properties/intervals, overlays, markers

**Strings**: Emacs strings are multibyte-by-default (UTF-8-like internal representation with
some legacy "raw byte" escape-hatch encoding for bytes that aren't valid UTF-8, used when
reading arbitrary binary file content) or explicitly unibyte. **[general]** — the
multibyte/unibyte distinction is a real Emacs wart (`string-to-multibyte`,
`string-as-unibyte`, `unibyte-string`) that trips up file-encoding-sensitive code; for a
macOS-only editor targeting modern package code, treating all strings as multibyte
Unicode/UTF-8 and providing the unibyte functions as thin compatibility shims (rather than a
truly dual-representation string type) is almost certainly the right scope cut — flag this
as a Tier 2 simplification decision to make explicitly rather than silently, since it
affects binary-file-editing correctness (Tier 3 candidate: full unibyte/multibyte semantic
parity for binary-safe editing). **Text properties on strings** (not just buffers) are Tier 2
but load-bearing for anything using `propertize` for minibuffer prompts, `completing-read`
annotations, or mode-line construction — very common in modern packages (vertico, which-key,
mood-line-style mode lines) — so this should not be deprioritized as "buffers only."

**Symbols and obarrays**: `intern`/`intern-soft`/`unintern`/`obarray`/`make-symbol`
(uninterned symbols, used heavily by macros for hygiene — every non-trivial `defmacro` that
avoids variable capture uses `(make-symbol "tmp")` or `gensym`-equivalent) are Tier 1 — macro
hygiene is invisible until it's broken, and package macros are pervasive. The `SymId ->
u32`-interning design Reticle already uses **[reticle]** (`value.rs`: `pub type SymId =
u32`) is the standard and correct approach — pellicle's tagged-word `Value` should encode
interned symbols as a tag + index into a global symbol table exactly this way, keeping
per-symbol property lists, function cells, and value cells in parallel arrays/side-tables
indexed by the same `SymId` for O(1) access (matches the flat-array plan in §3).

**Text properties/intervals**: GNU represents buffer text properties as a balanced
interval-tree-like structure keyed by character position (historically `intervals.c`'s
node-based structure; more recent Emacs added `itree.c`, an actual augmented interval tree,
specifically to fix `O(n)` pathologies in the old design — **[general]**, this file wasn't
directly fetched this session, flagged in §17 for a follow-up spike/fetch before finalizing
the data-structure choice). The practical guidance for pellicle: use a genuine augmented
interval tree (order-statistics or centered-interval design) from day one rather than
Emacs's older linked-list-of-intervals approach, since `itree.c`'s existence in modern GNU
Emacs is itself evidence the older design didn't scale and had to be replaced — don't
reproduce a known-superseded data structure. Overlays share the same interval-tree
backing in modern Emacs (`itree.c` covers both text properties and overlays as of the
overlay-rewrite era **[general, re-verify]**) — a unified interval-tree implementation
serving both text properties and overlays, keyed by buffer position with automatic
shift-on-edit, is the right single subsystem to build rather than two separate ones.

**Markers**: position references that track buffer edits (insertions/deletions before a
marker shift it; `marker-insertion-type` controls whether text inserted exactly at the
marker's position pushes it forward or leaves it in place) — Tier 1, since `save-excursion`
plus practically all editing commands rely on markers to keep point/region/overlay endpoints
coherent across edits. Reticle already has gap-buffer-integrated UTF-8-aware position
tracking **[reticle]** (README: "Gap buffer with UTF-8 aware operations") — the marker
abstraction on top of that buffer implementation is the piece to design fresh, keyed to
pellicle's own buffer storage choice (swift-interpreter-perf.md §11 flags buffer storage
as a "Should" item needing its own spike, not decided here).

## 8. Syntax tables and forward-sexp/syntax-ppss machinery

Confirmed via oracle **[oracle]**, the syntax-class letters `modify-syntax-entry` accepts:
whitespace (`  `/`-`), word (`w`), symbol (`_`), punctuation (`.`), open/close-paren (`(`/`)`
with matching-char second field), string-quote (`"`), escape (`\`), paired-delimiter (`$`),
expression-quote/prefix (`'`), comment start/end (`<`/`>`), character-quote (`/`), generic
string/comment fence (`|`/`!`), inherit-from-parent (`@`); flags `1234bpn` control two-char
comment sequences, comment styles b/c, and nestable comments, plus `p` for
`backward-prefix-chars` treatment. This is a substantial, precise state machine — every
language mode defines a syntax table using this vocabulary, and `forward-sexp`/`scan-sexps`/
`syntax-ppss` (parse-partial-sexp state: are we inside a string, a comment, at what nesting
depth, tracked incrementally with a cache) are the machinery that makes paren-matching,
`electric-pair-mode`, indentation, and semantic selection work. **Reticle has none of this**
(README confirms: "No `define-derived-mode` and no syntax-table system" **[reticle]**) —
this is arguably the single biggest concrete gap between Reticle and real-Emacs-mode
compatibility, and closing it is Tier 2-but-urgent, since it blocks `define-derived-mode`
itself (most derived modes set up a syntax table in their body) and blocks porting nearly
any language mode that isn't purely tree-sitter-driven. Design: a per-buffer (or
per-major-mode, inherited into buffers) syntax table as a 256+Unicode-range-aware char→
syntax-class map (with a parent-table inheritance chain per the `@` flag), plus a
`syntax-ppss` implementation that caches parse state at chunk boundaries (matching Emacs's
own approach of caching state every N characters so `syntax-ppss` at an arbitrary point
doesn't require re-scanning from buffer start every time) — this caching is a correctness-
adjacent performance requirement once files get large, directly relevant to the owner's
"must not get slower... the longer it runs" requirement.

## 9. Keymaps and key descriptions

Confirmed via oracle **[oracle]**: `?\C-i` (Ctrl+I keypress, char code 9) and `(kbd "TAB")`
(reads to string `"\t"`, also char code 9) are the *same Lisp value*, but `(kbd "<tab>")`
reads to the vector `[tab]` — a **distinct symbolic function-key event**, not an integer at
all. `(kbd "C-<tab>")` similarly reads to `[C-tab]`. This confirms the "rich key-event model"
the task brief asks about: **the TAB-vs-C-i distinction that GUI Emacs makes is implemented
by having two categorically different key-sequence element types** — plain integers
(character events, produced by a terminal or by literal ASCII-range keypresses) and symbols/
vectors-of-symbols (function-key events, produced by a GUI toolkit reporting "the Tab key was
pressed" as a named key rather than as a character). A **terminal-only** Emacs cannot make
this distinction (there is no separate "Tab key" event over a TTY wire protocol — everything
arrives as a byte stream, so `TAB` and `C-i` really are indistinguishable there), which is
exactly why this is documented as a well-known GUI-only Emacs capability. **Design
implication for pellicle**, which per the owner's brief is GUI-only (no CLI/TUI target):
represent every keyboard input internally as a small tagged event type — `{ kind:
.character(Int, modifiers: Set<Modifier>) | .functionKey(Symbol, modifiers: Set<Modifier>) |
.mouse(...) }` — sourced from AppKit's `NSEvent` (which already distinguishes
`NSEvent.SpecialKey`/`keyCode` function keys from `characters`), and have the keymap lookup
path try the function-key form first, then fall back to the character form, mirroring
`kbd`/`key-description`'s own dual representation exactly rather than collapsing everything
to character codes early and losing the distinction (a mistake that would silently make
pellicle *less* capable at keybinding than real GUI Emacs, contrary to the "extreme
performance... reliability" instinct which shouldn't come at the cost of feature regression
here — this one is cheap to get right and expensive to retrofit since every keymap consumer
downstream would need to change representation).

Keymaps themselves: nested alist/vector/char-table hybrid structures in real Emacs
(`define-key`, `keymap-set` in 29+, parent keymaps via `set-keymap-parent`, active keymap
stack composed from buffer-local, major-mode, minor-mode-alist-ordered, and global keymaps
per keystroke) — Tier 1 in full, since keybinding customization is one of the first things
any Emacs user does and Doom/Purcell configs rebind extensively. Reticle already has
"keymaps (global, buffer-local and an emulation layer)" **[reticle]** and ships an evil-mode
work-alike on top — that architecture (ordered list of active keymaps searched per keystroke,
each mode contributing/removing its own) is standard and should be kept; the only addition
pellicle needs beyond Reticle is the rich key-event distinction just described, since
Reticle's README doesn't mention it and Reticle has no GUI keyboard-event path to speak of
beyond its egui character-grid front end (a TUI/GUI-shared crate, likely char-code-only —
**[reticle]**, inferred from the shared-frontend architecture description, not independently
confirmed by reading Reticle's actual keymap-event code this session, flagged in §17).

## 10. define-derived-mode / define-minor-mode / hooks / advice

`define-derived-mode` (Tier 2, urgent per §8) expands to: define a mode function that runs
the parent mode's setup, sets `major-mode` and `mode-name`, creates/inherits a syntax table
and keymap (usually `NAME-mode-map`, `NAME-mode-syntax-table`), and runs `NAME-mode-hook` at
the end — a macro over primitives pellicle must already have (syntax tables §8, keymaps
§9, hooks below), so it is "just" a macro once those exist, matching the leverage-point
observation in §4. `define-minor-mode` similarly expands to a toggleable state variable, an
autogenerated keymap-lookup entry in `minor-mode-map-alist`, and lighter/mode-line text — no
new primitive needed beyond what buffer-local variables and keymaps already provide.

**Hooks**: `add-hook`/`remove-hook`/`run-hooks`/`run-hook-with-args`/
`run-hook-with-args-until-success`/`-until-failure`, with hooks being ordinary
(usually buffer-local-able) variables holding a list of functions, `t` in that list meaning
"also run the global value" when the hook variable is buffer-local — Tier 1, and already the
subject of Reticle's proven hook-time-budget design (PLAN.md M15 item 2: 50ms budget on
keystroke-path hooks, three-strikes auto-removal with a named message **[reticle]**) which
this report endorses inheriting unchanged — it is a genuinely good design independently
converging with how VS Code's process-isolation and JetBrains's cancel-and-restart models
both solve "one bad extension can't degrade typing," adapted correctly to the constraint
that Elisp hooks must run synchronously on the buffer (PLAN.md's own stated reasoning for why
Reticle couldn't just copy VS Code wholesale, which this report agrees is correct: "elisp is
not a plugin but the editor's command language itself").

**Advice** (`nadvice.el`), confirmed via fetch **[fetch]**: `advice-add`/`advice-remove`
wrap the target symbol's function cell in an **OClosure-shaped object**
`(car . cdr . how . props)` where `car` is the newly-added function, `cdr` is the next link
in the chain (eventually the original function), and `how` selects a combinator
(`:around`/`:before`/`:after`/`:filter-args`/`:filter-return`/`:before-while`/`:before-
until`/`:after-while`/`:after-until`) — this is genuinely just function-cell indirection plus
a small combinator dispatch table, **not** source-level patching, so it is cheap to implement
once function cells and closures exist. Two correctness details fetch surfaced worth
preserving exactly: (1) `fset`/redefining the underlying function strips advice wrappers
first (`advice--defalias-fset`) and re-applies pending advice to the new definition, so a
user's `(defun foo ...)` after `(advice-add 'foo ...)` doesn't silently lose the advice or
double-wrap it; (2) advice targeting an as-yet-undefined/autoloaded function is stashed
pending until the function is actually defined (`advice--pending` symbol property) — both of
these interact directly with §6's inline-cache design: **an IC that caches a resolved call
target must be invalidated by the same "function redefinition epoch" mechanism whether the
redefinition came from `defun`, `fset`, or `advice-add`/`advice-remove`**, since all three
mutate the function cell nadvice and the IC both watch. This ties §6, §10, and
jit-on-macos.md §11 pitfall #11 ("Function redefinition/advice: IC invalidation epoch...a
cached direct call into a redefined function is a correctness bug") into one concrete
requirement: route `defun`, `fset`, `advice-add`, and `advice-remove` through one shared
"bump this symbol's call-epoch counter" primitive, checked by every IC before trusting a
cached target.

## 11. cl-lib/seq/map/pcase/subr-x

All Tier 2, all near-universal in modern package code (magit and eglot lean heavily on
`pcase`; company/corfu and vertico/consult lean on `seq`/`cl-lib`). Design guidance: like
§4's special-forms-plus-macro-library leverage point, the bulk of `cl-lib` (`cl-defun` with
`&key`/`&optional` argument destructuring, `cl-case`, `cl-typecase`, `cl-loop`'s DSL,
`cl-defstruct`) is macro-expressible over the core language plus a handful of new runtime
primitives (`cl-struct` needs a tagged-vector-or-record runtime type; Emacs's `record`
primitive and `cl-defstruct`'s type-tag-in-slot-0 convention is the standard implementation
and should be copied rather than reinvented). `pcase` is a pattern-matching macro compiling
down to nested `cond`/`let`/type-predicate calls — also macro-expressible, no new primitive
needed, but it is a large and intricate macro (many pattern types: `` `(,a ,b) ``, `pred`,
`guard`, `and`/`or` patterns, `cl-type`) worth porting from GNU's actual `pcase.el` rather
than reimplementing the pattern compiler from a spec, given how easy subtle pattern-compiler
bugs are to introduce and how hard they are to notice (silent wrong-branch selection rather
than a crash). `seq.el`/`map.el` are mostly higher-order functions over lists/vectors/hash-
tables — thin, low-risk, Tier 2 but easy. `subr-x`'s `when-let*`/`if-let*`/`thread-first`/
`thread-last`/`string-trim*` are Tier 1-adjacent (very commonly used even in simple configs)
despite living in a "cl-lib-adjacent" file — recommend promoting these specific macros to
Tier 1 status even though the brief's own topic list put `subr-x` in the Tier 2 grouping,
since `when-let*` in particular appears in virtually every non-trivial `use-package` block
in modern Doom/Purcell-derived configs.

## 12. Regex

Emacs's regex dialect is its own (not PCRE, not POSIX ERE) with load-bearing extensions:
`\_<`/`\_>` (symbol boundary, distinct from `\<`/`\>` word boundary — critical for
`grep`/`occur`/font-lock matching whole Lisp/programming symbols rather than word-fragments),
syntax-class regex `\s-`/`\S-`/`\sw`/`\s_` etc. (matches a character by its *syntax table*
class, tying regex directly to §8's syntax tables — this is a genuine Emacs-regex-specific
feature with no PCRE equivalent, used by font-lock and many mode-specific search functions),
numbered backreferences `\1`-`\9`, explicitly-numbered groups `\(?2:...\)`, shy groups
`\(?:...\)`, and category-class `\cN`/`\CN`. Reticle already has "a self-implemented regex
engine with an explicit backtracking stack and a work budget" **[reticle]** (`regex.rs`,
107KB — the largest single non-generated file in Reticle's elisp crate, evidence of how much
surface this dialect actually has) — this is proven, substantial prior art and should be
ported/adapted rather than rewritten from the Emacs regex spec cold; the "explicit
backtracking stack and work budget" design is specifically valuable because it composes with
the interruption/budget model already adopted in §3/§10 (a runaway backtracking regex on the
keystroke path is a real Emacs failure mode this design already defends against). The work
budget should be re-verified against real Emacs semantics for pathological patterns (e.g.
catastrophic backtracking on `(a+)+b` against a long non-matching string) as part of any
port, since a budget that's too tight breaks legitimate large-file font-lock and too loose
defeats the point.

## 13. format/format-spec, printing, autoload/load-path, interactive spec codes

**`format`**: Reticle supports `%s %S %d %x %o %c %f %%` with **no field width, flags, or
precision** (`%-6s`, `%5d`, `%.2f` are errors) **[reticle]** — this is a real, commonly-hit
gap (mode-line construction and many packages' user-facing messages use width/precision
routinely), promoting full C-`printf`-style width/flags/precision support to **Tier 1**
despite it sounding like a formatting nicety — it's exactly the kind of small missing feature
that produces a jarring, first-five-minutes error for a ported config rather than a graceful
degradation. `format-spec.el` (a different, `%x`-style templating library used by some
packages for user-configurable format strings, e.g. mode-line templates) is Tier 2.

**Printing**: `prin1`/`princ`/`prin1-to-string`/`pp`/`format "%S"` need correct
`read`-invertible output for all supported reader syntaxes from §2 (hash-tables, bool-
vectors, char literals if `print-escape-control-characters`, circular-structure `#N=`/`#N#`
labels when `print-circle` is non-nil) — Tier 1 for the basic cases (numbers, strings,
symbols, lists, vectors), Tier 2 for circular-structure printing and the rarer `print-*`
customization variables.

**Autoload/load-path**: `load-path` is a list of directories searched in order by `load`/
`require`; `autoload` registers a function as "load this file first, then call the real
function" stub — both Tier 1, since every package manager (`use-package`, `straight.el`-
style, or a from-scratch package manager pellicle might ship) is built on top of exactly
these two primitives, and Doom/Purcell configs assume `load-path` manipulation
(`add-to-list 'load-path ...`) works precisely.

**Interactive spec codes**, full list confirmed via oracle **[oracle]** (docstring of
`interactive` dumped directly): `a b B c C d D e f F G i k K m M n N p P r s S U v x X z Z`,
plus the `*`/`@`/`^` prefix-string modifiers (require non-read-only buffer / select the
mouse-event's window first / honor `shift-select-mode`) and the `MODES` trailing argument
(Emacs 28+, restricts `M-x TAB` completion to matching major modes). This is a long but
finite and now fully-enumerated list — Tier 1 for the commonly-used codes (`p`, `P`, `r`,
`d`, `n`, `s`, `f`, `b`), Tier 2 for the rarer ones (`z`/`Z` coding systems, `K` redefine-key,
`U` discarded-mouse-up), all should exist since `interactive` specs are pervasive in any
`defun` meant to be `M-x`-invoked or bound to a key, and a missing code letter fails loudly
(the command errors when invoked) rather than degrading — worth full coverage precisely
because partial coverage is highly visible and frustrating.

## 14. Timers, processes, threads — async primitives

**This is the section with the most required *design*, not just porting**, per the task
brief's explicit call for "async primitives you propose to add." Real Emacs's own model:

- **Timers** (`run-with-timer`, `run-with-idle-timer`, `run-at-time`): scheduled via a
  priority queue checked by the event loop between commands; idle timers additionally reset
  on any input event and only fire after N seconds of no input. This is Tier 1 (used by
  auto-save, blink-cursor, and vast numbers of packages for debounced work — e.g.
  company/corfu's completion popup delay, flycheck/flymake's check debounce) and is a
  straightforward "priority queue polled by the run loop" design with no async-Swift
  complexity needed beyond correct integration with AppKit's run loop (an `NSTimer`/
  `DispatchSourceTimer` per pending Lisp timer, or one coalescing timer, feeding events back
  onto the single interpreter thread from §3 — never firing the Lisp callback directly on a
  background thread).

- **Processes** (`make-process`, `start-process`, filters, sentinels,
  `accept-process-output`): real Emacs's process I/O is **already asynchronous under the
  hood** — filters/sentinels are called from the event loop when the OS reports readable
  data or process-status changes, never blocking the main loop — with `accept-process-output`
  being the one deliberately *synchronous-looking* primitive: it's a bounded wait ("spin the
  event loop, dispatching any ready timers/process I/O/redisplay, until this process produces
  output or TIMEOUT elapses") rather than a true blocking read, which is exactly why other
  timers and even other processes' filters can still run while one piece of code is "waiting"
  inside `accept-process-output`. **Design proposal for pellicle**: back `make-process`
  with Foundation's `Process`/`Pipe` (or lower-level `posix_spawn` + `DispatchIO` for finer
  filter/backpressure control), with the actual OS-level I/O completion delivered via GCD to
  a dedicated dispatch queue, which then **hands the filter/sentinel call back onto the single
  Elisp interpreter thread** (matching §3's non-negotiable single-thread-for-Lisp rule) rather
  than ever invoking Lisp callback code from a GCD thread directly. `accept-process-output`
  should be implemented as "pump the interpreter thread's own event queue (timers + process
  completions + any other pending async work) for up to TIMEOUT, stopping early if the target
  process produced output" — i.e. it is not a special primitive at all, it's the same
  run-loop-pump primitive every other blocking-looking wait in the editor should use, given a
  predicate and a timeout. This preserves real Emacs's actual compatibility contract (code
  written against `accept-process-output` assuming other timers/processes keep running during
  the wait continues to work) while being implementable entirely with Swift concurrency
  primitives without needing Lisp-level `async`/`await` syntax to exist at all — **Elisp
  itself does not need new promise/await syntax**; it needs its existing synchronous-looking
  primitives (`accept-process-output`, `sit-for`, `sleep-for`) correctly implemented as
  bounded pumps of an underlying async event system, exactly mirroring what real Emacs
  already does in C. Introducing a genuinely new Lisp-level `promise`/`then` API (as some
  modern packages like `aio.el`/`promise.el` — Tier 2/3, userspace libraries built *on top
  of* timers+process filters, not core) is optional sugar layered on the same underlying
  primitives, not a replacement for them.

- **Threads** (`make-thread`, `thread-yield`, mutexes/condvars): Emacs 26+ genuine OS
  threads exist but (per general knowledge of Emacs's threading model, **[general] — not
  independently re-verified against `thread.c` this session, flag for a follow-up spike if
  `make-thread` compatibility is prioritized**) only one thread executes Lisp at a time —
  it's cooperative, yielding at specific points (blocking I/O, explicit `thread-yield`), not
  true parallelism for Lisp code; this is consistent with, and a natural extension of, §3's
  single-Lisp-thread architecture (a pellicle `make-thread` could be implemented as
  additional *logical* Elisp execution contexts cooperatively scheduled onto the one real
  interpreter thread, exactly matching real Emacs's own actual concurrency model rather than
  attempting true parallel Lisp execution, which real Emacs itself doesn't provide either).
  This is Tier 2 at best — most packages either don't use `make-thread` or treat its absence
  gracefully.

## 15. Top ~150 native-builtin list (representative, by category)

This list is a working draft assembled from general Elisp knowledge plus the oracle's
subr-count confirmation (**[oracle]**: 1,530 symbols are `subrp` — i.e. natively implemented
— in a bare `-Q` Emacs 30.2; this report's ~150 is a curated must-have subset, not an attempt
at that full count, consistent with the "no bottomless pit" framing). Grouped, not
exhaustive within a group:

- **Cons/list**: `car cdr cons list append nth nthcdr length reverse nreverse setcar setcdr
  memq member assq assoc assoc-default rassq rassoc last butlast delq delete remq remove
  mapcar mapc mapcan mapconcat sort copy-sequence copy-tree elt`
- **Predicates/equality**: `eq eql equal null not consp atom listp nlistp symbolp stringp
  numberp integerp floatp arrayp vectorp functionp hash-table-p bufferp markerp overlayp
  keywordp booleanp`
- **Arithmetic**: `+ - * / % mod 1+ 1- max min abs float truncate round floor ceiling expt
  sqrt = /= < > <= >= zerop logand logior logxor lognot ash lsh`
- **Symbols/eval**: `intern intern-soft make-symbol gensym symbol-name symbol-value
  symbol-function set fset boundp fboundp makunbound fmakunbound eval funcall apply
  macroexpand macroexpand-all macroexpand-1 indirect-function`
- **Strings**: `concat substring string-equal string-lessp string-match string-match-p
  replace-regexp-in-string split-string string-join string-trim string-trim-left
  string-trim-right upcase downcase capitalize string-to-number number-to-string
  string-to-char char-to-string format make-string string-width string-empty-p
  string-prefix-p string-suffix-p`
- **Vectors/sequences**: `vector make-vector aref aset vconcat seq-filter seq-map seq-reduce
  seq-find seq-contains-p seq-empty-p seq-elt seq-length`
- **Hash tables**: `make-hash-table gethash puthash remhash clrhash maphash hash-table-count
  hash-table-test copy-hash-table`
- **Buffers**: `current-buffer set-buffer buffer-name buffer-file-name generate-new-buffer
  get-buffer get-buffer-create kill-buffer buffer-list buffer-live-p with-current-buffer
  (macro) erase-buffer buffer-string buffer-substring buffer-substring-no-properties
  insert insert-char delete-region delete-char point point-min point-max goto-char
  forward-char backward-char forward-line beginning-of-line end-of-line bolp eolp bobp eobp
  widen narrow-to-region save-excursion save-restriction`
- **Buffer-local/variables**: `make-local-variable make-variable-buffer-local
  kill-local-variable local-variable-p default-value set-default setq-default (macro)
  buffer-local-value`
- **Text properties/overlays**: `put-text-property get-text-property
  add-text-properties remove-text-properties text-properties-at propertize
  next-property-change previous-property-change make-overlay overlay-start overlay-end
  overlay-put overlay-get delete-overlay overlays-at overlays-in move-overlay`
- **Markers**: `make-marker copy-marker set-marker marker-position marker-buffer
  marker-insertion-type point-marker`
- **Control flow (already special forms/macros, listed for completeness of the runtime
  support they need)**: `signal error user-error throw catch (specials) unwind-protect
  (special) condition-case (special) ignore-errors (macro) with-demoted-errors`
- **Regex**: `string-match re-search-forward re-search-backward looking-at looking-back
  match-string match-beginning match-end replace-match save-match-data`
- **Syntax**: `char-syntax matching-paren syntax-table standard-syntax-table
  modify-syntax-entry with-syntax-table forward-sexp backward-sexp scan-sexps
  scan-lists parse-partial-sexp syntax-ppss forward-word backward-word skip-chars-forward
  skip-chars-backward skip-syntax-forward skip-syntax-backward`
- **Keymaps**: `make-sparse-keymap make-keymap define-key keymap-set global-set-key
  local-set-key key-binding lookup-key use-local-map current-local-map current-global-map
  set-keymap-parent kbd key-description where-is-internal`
- **Hooks**: `add-hook remove-hook run-hooks run-hook-with-args
  run-hook-with-args-until-success run-hook-with-args-until-failure`
- **Advice**: `advice-add advice-remove advice-member-p add-function remove-function`
- **Processes**: `make-process start-process process-send-string process-send-eof
  set-process-filter set-process-sentinel process-status process-live-p delete-process
  accept-process-output call-process call-process-region process-buffer
  set-process-buffer`
- **Timers**: `run-with-timer run-with-idle-timer run-at-time cancel-timer sit-for
  sleep-for current-time float-time`
- **I/O**: `read read-from-string princ prin1 print pp prin1-to-string message
  insert-file-contents write-region find-file-noselect expand-file-name file-exists-p
  file-directory-p file-name-directory file-name-nondirectory file-name-extension`
- **Load/require**: `load require provide featurep autoload load-path (variable)
  eval-after-load with-eval-after-load (macro)`
- **Misc**: `identity ignore always number-sequence make-list vconcat type-of
  interactive-p called-interactively-p this-command-keys read-key read-event
  called-interactively-p`

This is intentionally organized by category rather than as a flat alphabetical 150 to make
staffing/sequencing decisions easier (e.g. "the buffer + text-property + marker groups must
land together, before syntax, before keymaps" is visible from the grouping in a way a flat
list wouldn't show).

## 16. What Reticle already solved vs. what pellicle must add or fix

| Area | Reticle status | pellicle action |
|---|---|---|
| Reader, macros, `condition-case`/`catch`/`unwind-protect`, bignums, hash tables | Solved **[reticle]** | Port design, re-verify against oracle, adapt to tagged-word `Value` |
| Bytecode VM with fast-path fixnum ops | Solved, ~8x **[reticle]** | Port opcode shape; add IC slots (§6) GNU itself lacks |
| JIT for pure-integer subset | Solved, ~575x on qualifying code **[reticle]** | See jit-on-macos.md — gate behind Stage 3 measurement, don't build early |
| Regex engine with backtrack budget | Solved, substantial (107KB) **[reticle]** | Port/adapt; re-verify budget tuning |
| Interruption (64-step check), hook time budgets, three-strikes removal | Solved, proven in production use **[reticle]** | Inherit unchanged; independently corroborated by GNU's own back-edge-only quit design (§6) |
| Lexical binding default (opposite of GNU's historical default) | Solved **[reticle]** | Keep — matches modern Elisp convention (`lexical-binding: t` is universal in new code) |
| `define-derived-mode`, syntax tables, `syntax-ppss` | **Not implemented [reticle]** | New work, Tier 2-urgent (§8) — blocks most language-mode porting |
| `format` width/flags/precision | **Gap [reticle]** | Promote to Tier 1 fix (§13) — small, high-visibility |
| `emacs-module.h` ABI | **Not implemented, by design [reticle]** | Keep excluded (Tier 3, §1) |
| GC (Rc-based, can leak cycles) | **Known limitation [reticle]** | pellicle's tagged-word + manual-arena design (spikes #3) with a real mark/sweep or similar should not inherit this — precise GC over the arena was already flagged as a "Should re-spike" item in swift-interpreter-perf.md §11, now doubly motivated by wanting to *fix*, not just match, this Reticle gap |
| `push`/`pop` limited to plain variable places (no `setf`-place generality) | **Gap [reticle]** | Tier 2 fix — `cl-lib`'s generalized-place system (`gv.el`) is what real `push`/`pop`/`incf`/`setf` build on; worth porting `gv.el`'s place-expander design rather than special-casing `push`/`pop` again |
| Async LSP, background tree-sitter parsing, non-blocking hooks | Solved, exact architecture endorsed above (§10) | Inherit unchanged |
| Rich GUI key-event model (TAB vs C-i) | **Not present** (Reticle's GUI is character-grid, likely char-code keymap dispatch only — **inferred, not confirmed by reading Reticle's keymap-event code this session**) | New work for pellicle (§9), cheap now, expensive later |
| Buffer-local variable semantics interacting with `let` | **[reticle] presumed present** given a full Elisp implementation claim, but not independently spot-checked against the exact "which cell does `let` save" gotcha in §3 this session | Recommend a targeted correctness test against real Emacs oracle before assuming Reticle's implementation is a safe model to copy verbatim |

## 17. Unverified claims and pitfalls

**Unverified, flagged explicitly:**
1. The special-form count discrepancy in §4 (list showed 21 symbols, count query reported
   `special=22`) — needs a second, more careful oracle pass before finalizing the
   implementation checklist; likely innocuous (a reader-macro artifact of `function`/`quote`
   or of `mapatoms` visiting an internal alias) but not yet root-caused.
2. Whether `condition-case`'s `t` handler clause (catch-all) can intercept `quit` — stated by
   analogy in §5 but not directly tested against the oracle this session.
3. `itree.c`'s exact augmented-interval-tree design and whether overlays and text properties
   share one implementation in modern GNU Emacs (§7) — inferred from general knowledge of the
   overlay-rewrite history, not fetched or oracle-tested this session; recommend fetching
   `raw.githubusercontent.com/emacs-mirror/emacs/master/src/itree.c` before finalizing the
   text-property/overlay subsystem design (this was in the suggested source list but not
   reached within this session's actual work).
4. Emacs's exact thread-cooperation model (`thread.c`) for `make-thread` (§14) — stated from
   general knowledge, not re-verified; low priority given Tier 2 status, but should be
   confirmed before advertising any `make-thread` compatibility claim.
5. Reticle's actual GUI keymap-event code was not read this session (only the README's
   architecture summary) — the "likely char-code-only" claim in §9/§16 is an inference from
   the character-grid-frontend architecture description, not a confirmed reading of
   `crates/frontend-gui` or the keymap dispatch code.
6. Whether current `subr-x`/core-`subr.el` functions have migrated between files in Emacs
   29→30 (§11) — flagged as a "re-check against 30.2" item, not independently confirmed.
7. Multibyte/unibyte string scope-cut (§7) is this report's own recommendation, not a claim
   about what real Emacs does — flagged as a decision to make explicitly, not a fact.

**Key pitfalls, collected:**
1. The `let`-on-a-buffer-local-variable "saves whichever cell was active at bind time, does
   not follow a buffer switch mid-extent" gotcha (§3) is exactly the kind of thing that looks
   correct in every simple test and breaks only in a specific cross-buffer interaction —
   needs a dedicated correctness-test suite comparing against the real Emacs oracle, not just
   "does it look right."
2. `quit` (and any pellicle interrupt/timeout condition) must never be a subcondition of
   `error` (§5) — getting this backwards silently defeats every interruption guarantee
   anywhere an `ignore-errors`/broad `condition-case` exists in user or package code, which is
   everywhere.
3. Inline-cache invalidation must be routed through one shared epoch counter touched by
   `defun`, `fset`, `advice-add`, and `advice-remove` alike (§6/§10) — an IC scheme that only
   watches `defun` and misses `advice-add` will produce silently-stale cached call targets
   the moment any package uses advice, which is extremely common.
4. Don't reproduce Emacs's older linked-list text-property/interval design (superseded by
   `itree.c` in real Emacs itself) just because it's "the Emacs way" — build the augmented
   interval tree from the start (§7).
5. Regex work-budget tuning (§12) is a two-sided risk: too tight breaks legitimate large-file
   font-lock, too loose reintroduces the catastrophic-backtracking failure mode the budget
   exists to prevent — this needs empirical tuning against real large files, not a
   one-shot guess.

## 18. Sources

Primary sources fetched this session:
- https://raw.githubusercontent.com/emacs-mirror/emacs/master/src/bytecode.c — opcode names,
  threaded-dispatch mechanism, `quitcounter` back-edge-only quit checking (§6).
- https://raw.githubusercontent.com/emacs-mirror/emacs/master/lisp/emacs-lisp/nadvice.el —
  OClosure-shaped advice wrapping, combinator table, `advice--defalias-fset`,
  `advice--pending` (§10).

Oracle (`emacs -Q --batch --eval`, GNU Emacs 30.2, `/opt/homebrew/bin/emacs`), all run this
session (§0, §1, §2, §4, §5, §8, §9, §13): special-form enumeration, symbol/function/macro/
subr counts, error-conditions hierarchy for 14 condition symbols, `interactive` docstring
(full code-letter list), `modify-syntax-entry` docstring (full syntax-class vocabulary), `#s`/
`#&`/char-literal reader round-trips, `kbd`/`key-description` TAB-vs-`<tab>` distinction.

Local prior art read this session (read-only, `/Users/jerrychen/My_Projects/reticle`):
`README.md` (Elisp engine section, Known Limitations section), `PLAN.md` (M15/M16 experience-
axis section, lines ~898-1000), `crates/elisp/src/value.rs` (head, `Value`/`SymId`/`Args`/
`ExtRef` design), `crates/elisp/src/eval.rs` (grep only, no specials found by the grep
pattern used — the special-forms list in §4 comes from the oracle, not from reading Reticle's
dispatcher), `crates/elisp/src/bytecode.rs` (head, `Instr` enum with doc comments —
`DynBind`/`DynUnbind`/`MakeClosure`/`PushFrame`/`PopFrame`/`EnvDefine` design), directory
listing of `crates/elisp/src/` (file sizes as a rough proxy for implementation weight, e.g.
`regex.rs` at 107KB being the largest file).

This session's own prior research, cited by section throughout rather than repeated:
`spikes/RESULTS.md` (#3 value representation, #4 mini-interpreter benchmark), `research/
jit-on-macos.md` §10-12 (staged JIT plan, pitfalls, unverified list), `research/
swift-interpreter-perf.md` §11 (Swift-specific engine recommendations, Must/Should/Could,
pitfalls, unverified list).
