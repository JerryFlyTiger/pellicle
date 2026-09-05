# Verilog/SystemVerilog killer coding features for swiftemacs

Topic key: verilog-killer-features. Planning research only — no code written under
swiftemacs, no builds run. Confidence tags: **high** (verified against primary source
or reproduced locally, incl. via the two servers installed on this machine and Reticle's
own probe transcripts in PLAN.md), **medium** (single secondary source / WebFetch
summary, plausible but not cross-checked), **low** (inferred). A final "unverified"
section lists anything not confirmed within the 20-call web budget (17 calls used:
2 WebSearch attempted — quota exhausted immediately, fell back to WebFetch as
instructed — plus 15 successful/partial WebFetch calls and 3 failed/404 fetches).

## 1. Method and sources

- Local primary sources (read in full): `/Users/jerrychen/My_Projects/reticle/README.md`
  (Verilog tooling section, lines ~147-220) and `/Users/jerrychen/My_Projects/reticle/PLAN.md`
  — the "Verilog/SystemVerilog gap inventory" (line 5886) and milestone records M39, M54,
  M55, M56, M59, M88, M91-M95, M99.
- Local tool probes (read-only, `--help`/`--version` only, no build):
  `verible-verilog-ls --help` → "Verible Verilog Language Server built at
  v0.0-4126-g2b611e4d"; `slang-server --version` → "slang-server version 0.2.9+4f33c99";
  `slang-server --help` → exposes `--config-schema` (the flag that solved Reticle's M99
  false-include-error saga).
- Web: Emacs verilog-mode source (`verilog-mode.el` on GitHub, primary, high confidence),
  mshr-h/vscode-verilog-hdl-support README, TerosHDL README, veridian README,
  svlangserver README, verible README, slang README, Sigasi and AMIQ DVT product pages,
  surfer project site. WebSearch was unavailable for this session (quota exhausted on
  first call); all web findings below come from direct WebFetch of the named primary
  URLs, per the task's fallback instruction.

## 2. Emacs verilog-mode AUTO system (the reference feature set)

Source: `verilog-mode.el` header comments (GitHub, veripool/verilog-mode), **high
confidence** — this is the tool's own documentation, not a summary of a summary.

| Feature | What it does |
|---|---|
| AUTOINST | Auto-generates instantiation port connections by matching the target module's port declarations |
| AUTOWIRE | Auto-declares wires for signals connected to instantiated module ports |
| AUTOARG | Auto-generates a module's port argument list from internal signal usage |
| AUTO_TEMPLATE | User-defined exact/wildcard port-to-signal mapping rules consumed by AUTOINST, so a submodule's generic port names map onto the parent's real signal names instead of identity-connecting |
| AUTOSENSE | Auto-generates an `always` block's sensitivity list from the signals it reads |
| AUTORESET | Auto-inserts reset assignments for every signal driven inside a sequential reset block |
| AUTOINPUT | Auto-declares input ports for signals driven by instantiated submodules but not yet declared |
| AUTOOUTPUT | Auto-declares output ports for signals that drive instantiated submodules |
| AUTOINOUT | Auto-declares bidirectional ports required by submodules |
| AUTOREG | Auto-declares `reg` for signals assigned procedurally that are not already wires |
| AUTOTIEOFF | Auto-ties off unconnected/unused module outputs to a constant |
| AUTOUNUSED | Auto-documents/terminates unused input signals |
| Instance arrays | AUTOINST works across parameterized/array instantiations (`u1[3:0] (...)`) |
| verilog-auto-star (`.*`) | Expands Verilog-2001/SV `.*` wildcard port connections |

Why RTL engineers value this: wrapper/glue modules in real SoCs commonly have 40-200+
ports; AUTOINST/AUTOWIRE/AUTOARG turn "manually retype every port on every port-list
edit across every instantiation site" into "press one key, safely idempotent." This is
the single most load-bearing feature of GNU verilog-mode among professional RTL
engineers and the reason "the Verilog AUTOs are in use by many of the leading IP
providers, including IP processor cores sold by Arm" (veripool.org, medium confidence —
marketing copy, not independently verified, but consistent with two decades of
verilog-mode's dominance in the RTL community).

## 3. What Reticle already built for Verilog (Reticle = reuse-candidate baseline)

All entries **high confidence** (Reticle's own PLAN.md milestone records, several
independently probed against the real `verible-verilog-ls` / `slang-server` binaries
by Reticle's own development process — see the M54/M55/M59/M94/M95/M99 probe tables).

**Built and working (candidates to port the *design*, not the code, since swiftemacs
is a new Swift codebase):**

- Homegrown AUTO system (M39, M92): AUTOINST/AUTOWIRE/AUTOARG using a real tree-sitter
  parse instead of verilog-mode's ~15k lines of regexp scanning; delete-then-regenerate
  is idempotent and pinned by round-trip tests; AUTO_TEMPLATE with GNU-faithful
  semantics (exact beats wildcard, anchored patterns, document-order wildcard
  precedence, last-exact-wins, buffer-wide lookup) added in M92, including a hard
  lesson: **template EXPR bodies must be balance-scanned from the paren, not
  regex-matched**, because RTL comments routinely contain literal parens
  (`// see (note)`) that corrupt a naive regex capture.
- Cross-file module-definition jump, `M-.`/`M-,` (M55), working with **no LSP server
  required** — a pure local tree-sitter scan of `verilog-library-directories`. Falls
  back to LSP (verible resolves cross-file correctly only if the target file was
  `didOpen`'d or a `verible.filelist` names it).
- Recursive library-directory BFS + `verible.filelist` support (M56) — the routine
  industry layout (`rtl/core/`, `rtl/mem/`, `rtl/bus/`) silently broke all three local
  consumers (AUTOINST, jump, port completion) until this shipped. Cost was measured,
  not assumed: 500 library files → 58.7ms worst-case full scan, 15.4ms warm
  incremental parse.
- Local port-name completion at instantiation sites (M54), deliberately **tier-1
  local-first, never falling through to `dabbrev`** once a port context is confirmed
  — dabbrev's buffer-only scan is "actively harmful" at a port position (pulls
  plausible-looking but wrong identifiers from the current buffer).
- Module-name and `#(...)` parameter-name completion (M91) — required three rounds to
  get right: a too-eager empty/partial-prefix trigger caused every ordinary keyword
  typed in a module body to spuriously fire the completion machinery. Final design:
  a cheap zero-I/O cache peek answers "does anything match this prefix" before paying
  for a full candidate build (5-6ms vs 13.8ms).
- `textDocument/references` — "who instantiates this module" (M59), `M-?`. Verified
  against a synthetic 890-file/154k-line RTL tree: 400/400 correct hits, symbol-table
  precision (not text matching — distinguishes a port's formal name from an unrelated
  identically-named local signal). **Known trap, high value for swiftemacs to avoid**:
  with no `verible.filelist`, references silently returns `[]`, indistinguishable from
  "there are truly no references"; with a filelist that only lists half the files, it
  silently returns half the answer with no warning.
- Two-language-server-per-buffer architecture (M94/M95/M99): verible and slang-server
  attached simultaneously to one buffer, routed **per LSP method** by which server
  answers most correctly (established by probing both against real RTL and grep
  ground truth, not by capability-flag trust). Diagnostics are **merged** (union of
  both clients' published diagnostics), not switched — because verible's lint category
  (style/coding-standard enforcement) and slang's elaboration-level diagnostics
  (undriven output port, unassigned variable, unused signal) are complementary, not
  competing; making one exclusive would silently delete the other's whole diagnostic
  class.
- Per-file indent-width detection so someone else's RTL isn't silently reformatted.
- Background project search with wgrep-style editable results and live filter-as-you-type.
- LSP-server autostart on first buffer open (M88), with the guard trap documented
  below.

**Reticle gaps** (explicitly excluded or unverified in v1, i.e. real opportunities for
swiftemacs to do better rather than just port):

- AUTOSENSE, AUTOINPUT/AUTOOUTPUT/AUTOINOUT, AUTOREG/AUTORESET/AUTOTIEOFF/AUTOUNUSED,
  instance arrays — all still unimplemented (gap-inventory row 6).
- `interface`/`modport` awareness is thin: highlighting works, but nav/AUTO/completion
  treat interfaces as essentially untested (gap row 5, marked SUSPECTED not VERIFIED).
- General identifier completion (an imported package type, a parameter defined in
  another file) has no working source at all when only verible is attached; it falls
  through to buffer-only dabbrev. **Confirmed fixable**: slang-server *does* declare
  `completionProvider` and returns real typed candidates (M91-M93 record) — this is
  exactly the kind of capability-routing swiftemacs should build in from day one rather
  than retrofit.
- `textDocument/references` incompleteness with a partial/missing filelist is silent
  by design of the servers, not fixable client-side without a disk cross-check scanner
  (gap row 7, still open in Reticle).
- Cross-directory elaboration errors from `make -C sub`-style relative paths break
  `compile`/`next-error` (gap row 9).
- Diagnostic message rows cap at 3 lines with a truncation-ellipsis bug (gap row 10).
- No caching anywhere in the nav/completion path — every `M-.` rescans every library
  file; acceptable at demonstrated scale (~59ms/500 files) but a ceiling worth
  designing past in a fresh implementation.
- Never solved architecturally: UVM class-hierarchy/factory/phase awareness, SVA
  assertion authoring support, coverage, CDC awareness, waveform viewing, hierarchy
  browser/instance tree UI, signal driver/load tracing — **none of these appear
  anywhere in Reticle's Verilog work**. This is the single biggest gap class between
  Reticle and what professional DV engineers (as opposed to RTL authors) need, and it
  maps directly onto what Sigasi/AMIQ DVT sell as differentiators (Section 4).

## 4. Commercial IDEs: Sigasi Visual HDL, AMIQ DVT

**Medium confidence** (vendor marketing pages via WebFetch, not independently
reproduced; specific numeric/architectural claims not cross-checked).

- **Sigasi Visual HDL** (VS Code-based): real-time semantic checking as you type
  (no wait for compile/simulate), a live interactive block-diagram / state-machine
  visualization of the design, built-in awareness of verification frameworks (UVM,
  OSVVM, UVVM, VUnit, Cocotb), and functional-safety-standard guidance (DO-254,
  ISO 26262, STARC) surfaced as contextual warnings. VHDL/Verilog/SystemVerilog in one
  tool.
- **AMIQ DVT (DVT Eclipse IDE)**: a full **semantic database** built by on-the-fly
  incremental IEEE-compliant parsing, explicitly marketed for "tens of thousands of
  lines" scale; class/structural browsing and semantic search across the whole
  project; dedicated UVM tooling including OVM→UVM migration checks; autogenerated
  UML/design diagrams and signal tracing; autocomplete, quick-fix, and refactoring.
  DVT is generally considered (medium/low confidence, not independently verified here)
  the closest thing the EDA industry has to a "real IDE" for SystemVerilog/UVM DV work,
  specifically because of the semantic-database-first architecture rather than a
  regex/LSP-only approach.

**Takeaway for swiftemacs**: both commercial tools' headline differentiator versus
free-tool LSP servers is a **persistent, incremental, whole-project semantic index**
(not per-request LSP round trips) that powers real-time checking, structural
navigation, and UML-style visualization at scale. Reticle never built this — it
recomputes locally on each keystroke/action and treats LSP as external. This is the
architectural gap most worth deciding on early for swiftemacs if DV/UVM users are a
target, not just RTL authors.

## 5. VS Code extensions: TerosHDL, mshr-h Verilog-HDL, svlangserver

**Medium confidence**, WebFetch of each project's own README.

- **TerosHDL**: go-to-definition, hover, a hierarchy/dependency viewer, a template
  generator, automatic documentation generation, Verilog/SystemVerilog schematic
  visualization, a state-machine viewer/designer, Verible-based style linting plus
  broad simulator/tool backend integration (Vivado, ModelSim, GHDL, Verilator,
  Quartus, Yosys, etc.), snippets. (Testbench generation, a dedicated waveform viewer,
  and project-manager specifics were not confirmed in the fetched README — see
  unverified section.)
- **mshr-h/vscode-verilog-hdl-support**: ctags-backed completion/document-symbol/
  hover/definition/peek-definition (works without any language server); a "Verilog:
  Instantiate Module" command for auto-generating an instantiation template from a
  module declaration; linting via Icarus/ModelSim/Verilator/Vivado xvlog/Slang/Verible;
  formatting via verilog-format/iStyle/verible-verilog-format; optional attach to
  external servers (svls, veridian, HDL Checker, verible-verilog-ls, vhdl_ls, tclsp);
  an embedded VCD viewer (Fliplot, or optional Vaporview extension); does **not**
  auto-generate testbenches.
- **svlangserver**: completion with no ctags dependency, document/workspace symbol
  search, go-to-definition that explicitly works for module/interface/package names
  *and* ports, hover, signature help, live Verilator/Icarus lint-on-the-fly,
  verible-verilog-format integration, module hierarchy reporting, snippets, fast
  glob-based file indexing. Explicitly documented limitation, in its own words:
  "doesn't understand most verification specific concepts (e.g. classes)" — i.e. **no
  UVM/class awareness**, a gap shared with basically every free tool surveyed here
  except DVT/Sigasi.

## 6. Language servers: verible-verilog-ls vs slang-server (capability matrix)

**High confidence** — this table is Reticle's own reproduced probe data (M54, M55,
M59, M94, M95, M99), corroborated by local `--help`/`--version` checks on this machine
(verible-verilog-ls "v0.0-4126-g2b611e4d"; slang-server "0.2.9+4f33c99", which exposes
a `--config-schema` flag not documented anywhere else that was the actual fix for a
false-positive include error 11 prior config attempts failed to clear).

| Capability | verible-verilog-ls | slang-server |
|---|---|---|
| completion | none at all | yes, with resolve, typed candidates |
| formatting (doc + range) | yes | none at all |
| diagnostics on a real SoC file | 0 (lint-only, needs `verible.filelist`/lint invocation separately) | 18 (elaboration-level: undriven output port, unassigned variable, unused signal) |
| style/coding-standard lint (e.g. no-tabs) | yes (3 hits) | 0 |
| references (cross-file, ground-truth checked) | frequently silently incomplete (echoes only the queried site on a class name; 0/7 on a wildcard-imported name) | complete and correct in every tested case |
| rename | can *corrupt* code (drops a required `endmodule : name` label — a real IEEE 1800 §23.2.5 violation) | correct, includes the label |
| definition on `import pkg::*` names | fails (`[]`) | resolves |
| documentSymbol | under-typed (module tagged generic `Method`, no params/ports) | correctly typed, more complete |
| requires `verible.filelist` for cross-file features | yes, and silently degrades without one or with a partial one | not documented/tested here |

**Conclusion, directly reusable as an architectural decision for swiftemacs**: neither
server is sufficient alone; the two are complementary (format+lint from verible,
elaboration diagnostics+completion+correct rename/references from slang). A
single-attached-server-per-buffer design (what most VS Code extensions and Reticle
started with) is a real functional regression versus attaching both and routing by
per-method probed correctness — this is Reticle's single most valuable, hard-won,
directly-portable finding for swiftemacs's LSP client design.

## 7. Lint/format/simulate loop

**verible** (medium/high confidence, own README via WebFetch): `verible-verilog-syntax`
(CST export, JSON, Python bindings), `verible-verilog-lint` (style-guide rule engine,
waivers, GitHub integration), `verible-verilog-format` (syntax-aware line-wrapping,
incremental/interactive modes, table alignment), `verible-verilog-ls`, plus
`verible-verilog-diff` (semantic-equivalence diff), `verible-verilog-project`
(whole-project transforms), `verible-verilog-obfuscate`, and a Kythe indexing
extractor for cross-reference-grade IDE integration. Reticle already depends on
`verible.filelist`/lint/format as the project's own CI gate (`demo/tools/lint_rtl.sh`).

**slang** (medium confidence, own README): markets itself as "the fastest and most
compliant SystemVerilog frontend" per the chipsalliance open-source test suite,
explicitly engineered to "remain functional even with incomplete code" so it can serve
editor completion/highlighting mid-edit — a deliberately robust-parse design point
worth adopting for swiftemacs's own SystemVerilog front end if one is ever
homegrown rather than delegated to slang.

**Simulation loop**: `iverilog` is installed locally (`/opt/homebrew/bin/iverilog`);
`verilator` is *not* installed on this machine (per CONTEXT.md's environment list) —
so its `--lint-only` error format could not be probed locally, and no web fetch was
spent on it given the 20-call budget; treat verilator `compile`/`next-error` format
support as **unverified**, to be probed once installed. Commercial simulator
(xcelium/vcs/questa) error-message formats for `compile`/`next-error` integration were
**not researched** — out of budget; flagged for a follow-up pass since these formats
are typically undocumented and vendor-specific, and getting `next-error` regex wrong
silently breaks the compile-loop (a failure mode Reticle already hit once, gap row 9,
for a different reason — relative paths from `make -C`).

## 8. Waveform viewers

**Low/medium confidence** — surfer's own marketing pages (surfer-project.org, its
GitLab project page) yielded almost no technical detail beyond "an extensible and
snappy waveform viewer" available as a native app (Linux/Windows/macOS ARM) and in-
browser (slower than native, by their own admission). VCD/FST support, GPU rendering,
and large-file/remote handling could **not** be confirmed from the fetched pages —
these are commonly cited claims about surfer elsewhere but are **unverified** here.
gtkwave was not fetched at all (budget). mshr-h's extension embeds a lightweight VCD
viewer (Fliplot) with an optional heavier Vaporview extension — this is a real,
verified pattern (bundle a basic viewer, let users opt into a fuller one) worth
copying for swiftemacs rather than either shipping nothing or over-investing in a
full waveform viewer at v1.

## 9. Project/filelist management, UVM, SVA, CDC, coverage

- **Filelist (`.f`) management, `+incdir+`/`+define+`, `-y` library dirs**: this is
  the connective tissue every server and Reticle both depend on; Reticle's hard
  lessons (M56, M59, M93, M99) are the most concrete evidence available anywhere in
  this research about how fragile filelist-rooting is in practice: a nearer `.git`
  silently shadowing a `verible.filelist` and misrooting the whole server (M93); a
  relative include path resolving against the *server process's own cwd*, not the
  workspace root or the config file's directory, so `-I include` only worked "by
  accident" for a user who happened to launch the editor from the project root (M99).
  **Any swiftemacs LSP client must explicitly set the spawned server's working
  directory to the computed project root — do not rely on inheriting the editor's own
  cwd.**
- **UVM (class hierarchy, factory, phases, snippets)**: **no tool surveyed here —
  free or Reticle — has real UVM semantic awareness**, except the two commercial IDEs
  (Sigasi, DVT) which advertise it explicitly (DVT: dedicated UVM/OVM-migration
  tooling). svlangserver documents this gap in its own words. This is a clear, large,
  currently-unaddressed opportunity for swiftemacs to differentiate for verification
  engineers specifically, not just RTL authors — but it is also the highest-effort
  item on this list (needs class-hierarchy-aware semantic analysis, not just
  syntax/LSP wiring).
- **SVA assertions, coverage, CDC awareness**: **not mentioned as implemented by any
  tool surveyed** except in passing marketing language from Sigasi/DVT (real-time
  checking framework compatibility, safety-standard guidance) — no concrete evidence
  of dedicated SVA-authoring UX, coverage visualization, or CDC-specific static
  analysis in *any* source consulted. Treat as **unverified/likely thin across the
  whole industry tooling landscape outside the top two commercial IDEs**, and as an
  open research question for a later, deeper pass if the owner wants swiftemacs to
  target DV engineers as hard as RTL authors.

## 10. Prioritized top-10 killer-feature list for swiftemacs

Ranked by (a) how many real RTL/DV edits the feature touches, per Reticle's own
frequency-based ranking rule, and (b) evidence strength.

1. **Dual/multi-language-server-per-buffer with per-method capability routing and
   diagnostic merging** — *Reticle gap-turned-feature; reuse the design.* Verified as
   the single highest-value LSP architecture decision (Section 6); a naive
   single-client design is a functional regression, not a simplification.
2. **AUTOINST/AUTOWIRE/AUTOARG/AUTO_TEMPLATE, tree-sitter-based, idempotent** —
   *exists in Reticle, reuse the design.* Verified as the most-used feature of GNU
   verilog-mode among professional RTL engineers; Reticle's version already beats
   GNU's regex approach and has AUTO_TEMPLATE's real gotchas (comment-aware
   balance-scanning) solved.
3. **Complete the AUTO family**: AUTOSENSE, AUTOINPUT/OUTPUT/INOUT,
   AUTOREG/AUTORESET/AUTOTIEOFF/AUTOUNUSED, instance arrays — *Reticle gap, new work
   for swiftemacs.* High value, low novelty risk (semantics are documented in GNU
   verilog-mode's own source, Section 2), extends #2 directly.
4. **Local-first, LSP-fallback module-name / port-name / parameter completion at
   instantiation sites, never falling through to buffer-only dabbrev at a confirmed
   port position** — *exists in Reticle, reuse the design*, including the specific
   trap of over-eager triggering on ordinary keyword prefixes (M91) and the cheap
   pre-check that avoids paying full-scan cost on every keystroke.
5. **Cross-file module/interface/package/class jump with no LSP required, LSP as a
   filelist-aware fallback** — *exists in Reticle (module only), Reticle gap
   (interface/package/class/program), reuse the jump design and extend its coverage.*
6. **A persistent, incremental, whole-project semantic index** (not per-keystroke
   local rescans, not bare LSP round-trips) — *new for swiftemacs.* This is what
   separates DVT/Sigasi from every free tool surveyed, and it is the architectural
   root cause behind Reticle's "no caching, rescans every library file" limitation.
   Worth deciding early since it affects the whole LSP/nav/completion layer's shape.
7. **Filelist/project-root correctness discipline**: explicit server cwd = computed
   project root; `.git`-vs-filelist root precedence; detect (not just silently accept)
   a filelist that omits files — *Reticle gap plus a hard-won pitfall list, reuse the
   lessons even though the underlying detection was left undone in Reticle.*
8. **Merged, ground-truth-checked references/rename/definition/documentHighlight/
   documentSymbol routing to whichever server is actually correct**, verified against
   `grep`, not against the other server or against capability flags — *exists in
   Reticle (the routing table + methodology), reuse the design and its verification
   discipline.*
9. **UVM class-hierarchy/factory/phase awareness and snippets** — *new for
   swiftemacs, no free-tool precedent found; only Sigasi/DVT claim it.* High effort,
   high differentiation for DV engineers; recommend scoping as a distinct milestone
   after RTL-author features are solid, per the owner's own stated priority order
   (Verilog first, but RTL-and-DV both fall under "Verilog/SystemVerilog" priority).
10. **A bundled lightweight waveform viewer with an escape hatch to something fuller**
    — *new for swiftemacs*, modeled on the mshr-h extension's Fliplot+Vaporview
    pattern (verified) rather than surfer's specific technical claims (unverified
    here). Lower priority than 1-9 because it's adjacent tooling, not an editing
    feature, but explicitly named in the brief.

## 11. Pitfalls / traps to avoid (from Reticle's hard-won lessons — all high confidence, directly reproducible from PLAN.md)

- **Do not trust a server's declared LSP capabilities as ground truth.** verible
  declares `hoverProvider: false` yet returns correct hover; conversely it declares
  `referencesProvider: true` and both under- and over-answers in different ways. Probe
  the real binary before writing client code, every time — this was Reticle's single
  most-repeated process rule (cited in nearly every M5x/M9x record) and directly
  applicable to a fresh swiftemacs LSP client.
- **A server that "answers" is not the same as a server that answers correctly.**
  verible's `rename` can produce code that violates IEEE 1800 §23.2.5 (mismatched
  `endmodule : name` label) — a silent correctness bug, not a missing feature.
  Reticle's fix was ground-truth comparison (`grep`), not trusting either server
  against the other.
- **Silent partial answers are worse than errors.** Missing/partial `verible.filelist`
  → `references` returns `[]` or half the true answer with zero signal to the user
  that anything is wrong. Any swiftemacs feature that depends on a filelist should
  surface filelist coverage/staleness explicitly.
- **Guard conditions that gate "does this buffer have any client" can permanently
  block a second server from ever attaching for the session, with no error message**
  (hit twice independently in Reticle, M63 and M88, then again in M94's own new
  guard) — ask about the *specific* capability/command being attempted, not "is
  anything attached."
- **A relative path in a server config resolves against the server's own process
  cwd**, not the workspace root, not the config file's directory — verified directly
  against slang-server on this machine's data (M99). `spawn`-time `cwd` must be set
  explicitly by the client.
- **Test fixtures that "pass" but never reach the code under test are a recurring,
  not rare, failure mode** — Reticle names this "masking" and hit it independently at
  least four times across different milestones (M54, M55, M91 three separate times in
  one milestone). Any swiftemacs test-writing discipline for Verilog features should
  budget for mutation testing, not just green tests, from the start.
- **Regex-based template/config parsing breaks on real RTL comments containing literal
  parentheses** (`// see (note)`) — AUTO_TEMPLATE's EXPR body had to move from regex to
  balance-scanning for exactly this reason (M92). Any new template/macro-expansion
  engine for swiftemacs's AUTO system should balance-scan from the start.

## 12. Unverified claims (explicitly not confirmed within budget)

- surfer's VCD/FST format support specifics, GPU-accelerated rendering, and
  large/remote-file handling — marketing pages fetched gave no technical detail;
  gtkwave was not researched at all.
- verilator `--lint-only` error message format and its `compile`/`next-error`
  integration shape — verilator is not installed locally and was not web-researched
  (budget); flagged for a follow-up.
- Commercial simulator (Cadence Xcelium, Synopsys VCS, Siemens Questa) compile-error
  message formats for `next-error`-style integration — not researched at all (no
  public docs budget spent; these are typically license-gated anyway).
- TerosHDL's testbench generation, dedicated waveform viewer, and project-manager
  details — its README (as fetched) did not describe these; TerosHDL's site describes
  itself as an IDE with many integrated backends, but the specific feature list is
  incomplete in what was retrieved.
- Whether any free/open-source tool (as opposed to Sigasi/DVT) has *any* real SVA
  assertion-authoring support, coverage visualization, or CDC-specific static
  analysis — no evidence of this was found anywhere in the sources consulted; this
  reads as a genuine gap across the open-source Verilog tooling landscape, but the
  research to confirm "gap, not just under-documented" would need deeper, dedicated
  investigation (e.g. actually testing the tools) beyond this pass's budget.
- Sigasi's and AMIQ DVT's large-codebase (100k+ file) navigation performance —
  claimed generically ("tens of thousands of lines") but no benchmark or independent
  verification found.
