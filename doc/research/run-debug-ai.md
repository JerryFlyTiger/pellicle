# Run/Debug/Test/Simulate loops + AI integration — research (topic key: run-debug-ai)

Status: COMPLETE.

---

## A1. DAP client design + adapters

**DAP architecture (high confidence, microsoft.github.io/debug-adapter-protocol/):**
Three layers: development tool (editor) ↔ debug adapter (translator process) ↔
debugger/runtime. JSON-RPC-like messages over stdio (or a socket). Core requests:
`initialize`, `launch`/`attach`, `setBreakpoints`, `configurationDone`, `threads`,
`stackTrace`, `scopes`, `variables`, `evaluate`, `continue`/`next`/`stepIn`/`stepOut`,
`disconnect`. The point of DAP is that an editor implements **one generic DAP client**
and gets N debuggers for free; each debugger vendor implements one adapter and gets M
editors for free. Spec is versioned (currently 1.71.0 per the site) — pellicle should
target the stable subset and treat new capabilities as additive.

**Adapter coverage per language (medium confidence — from the community adapters
registry at microsoft.github.io/debug-adapter-protocol/implementors/adapters/, which is
user-submitted and may be incomplete/stale):**
- **Swift/C/C++**: no adapter is listed *by name* for "Swift," but **lldb-dap**
  (bundled with LLVM/Xcode, confirmed present locally at
  `/Applications/Xcode.app/Contents/Developer/usr/bin/lldb-dap`) natively debugs any
  binary LLDB can load a symbol table for — Swift, C, C++, Objective-C all included,
  since LLDB itself is Swift-aware. Apple's own VS Code Swift extension and Xcode 26 use
  LLDB as the backend. Listed alternatives for C/C++: "C/C++/Rust" (Cortex Debug),
  "C/C++/Rust – Midas (gdb & rr)". **Recommendation: adopt lldb-dap directly** rather
  than a third-party C/C++ adapter — it is Apple-shipped, zero extra install, and covers
  Swift + C/C++ + Objective-C in one adapter.
- **Python**: debugpy (Microsoft), the de facto standard, listed under "Python."
- **Perl**: two listed adapters ("Perl Debug", "Perl::LanguageServer" which bundles a
  debugger). Neither is as mature/maintained as debugpy or lldb-dap — **treat Perl DAP
  support as a gap to budget extra integration/testing time for**, not a drop-in.
- **Tcl/Tk**: **no DAP adapter listed at all.** This is a real gap. Tcl debugging in
  practice today is done via `tclsh`'s built-in `debugger` package or IDE-specific
  plugins (e.g., Komodo), none of which speak DAP. **Recommendation: do not promise
  Tcl/Tk debugging in early milestones**; scope it to breakpoint-free workflows
  (run-and-see-output, `puts` tracing) until/unless a DAP shim is built or found.

**lldb-dap specifics (high confidence, from local `lldb-dap --help` plus
lldb.llvm.org/use/tutorial.html):**
- Two transport modes: **stdio** (default, no arguments — the natural mode for an
  editor to spawn it as a child process) and **socket** via
  `--connection listen://[host]:port` or `accept://path`.
- `--launch-target` + `--comm-file` support "launch in terminal" (debuggee runs in a
  real terminal the editor owns — relevant to pellicle since the app itself is meant
  to double as a terminal per the owner's brief).
- `--wait-for-debugger` (`-g`) pauses the debuggee at startup, useful for attach races.
- `--repl-mode {variable,command,auto}` controls how the DAP `evaluate` request is
  interpreted — worth exposing as a user setting since RTL/C engineers often want raw
  LLDB command syntax (`p/x`, `bt`) rather than expression evaluation.
- Ships with Xcode; **no separate install needed on the owner's machine.**

**Milestone recommendation (A1):** MUST have a generic DAP client (transport + core
request set) before any specific adapter; SHOULD wire lldb-dap first (covers
Swift/C/C++/Obj-C with zero extra installs, directly serves the owner's declared
priority order); SHOULD wire debugpy second (Python is priority-2 language, adapter is
mature); COULD attempt a Perl adapter later with lowered expectations; Tcl/Tk debugging
is explicitly **out of scope** until a DAP adapter exists or is built in-house.

---

## A2. compile/next-error and error-format parsing

**GNU Emacs's own approach (high confidence — read directly off the owner's Emacs 30.2
via `compilation-error-regexp-alist-alist`):** GNU Emacs ships a **per-tool regex
table** with ~50 entries (gcc/gnu, msft, ant, cmake, maven, javac, typescript-tsc,
perl, php, python-tracebacks, lua, bash, gradle, and more), each a
`(name regexp file-idx line-idx col-idx type-idx ...)` tuple, dispatched by trying
patterns in order per compilation-mode buffer. The generic `gnu` pattern is broad
(`file:line[:col]: [warning|note|error]`) and is what most GCC-family and LLVM tools
(including Verilator's `%Warning-FOO: file:line:col: msg` shape once genericized) will
match without a dedicated entry.

**Reticle's contrasting design and its hard-won lessons (high confidence — read
directly from `/Users/jerrychen/My_Projects/reticle/PLAN.md`, M80 record, lines
~7378-7553):** Reticle **deliberately rejected** GNU's per-tool-table approach in favor
of **one general-purpose regex + a "does this path exist on disk" filter** to kill
false positives, reasoning that new tools then require zero table maintenance. This
worked for iverilog's four observed error shapes (`file:line:col-col:`,
`file:line: error:`, `file:line: syntax error`, `file:line: sorry:`) but had two
near-miss failures that are directly relevant to pellicle's design:
1. **Unbounded backtracking on external tool output can crash the whole editor
   process**, not just throw an error — Reticle's Rust regex engine did real function
   recursion on `.*`/`[^:\n]+` and **stack-overflow SIGABRT'd the process** on inputs
   as short as ~2500-2800 characters (a single `cargo build` linker error line can
   exceed that). The fix that actually worked was **capping input length before
   regexing**, not "smarter" regex authoring — trimming a trailing `.*` did *not* fix
   the colon-free case, since `[^:\n]+` alone is O(N) backtracking depth against
   colon-free input.
2. **A tool that `cd`s into a subdirectory and prints a relative path** (e.g.
   `make -C sub`) silently drops the whole error line under the existence-check
   design, because the path can't be resolved against the compile-launch cwd. Recorded
   as a known, accepted gap rather than solved.
3. Column-level jumping (not just line) was **the first place in Reticle's whole
   codebase to do it** — everything else (LSP jump, `M-g n`, Verilog module jump) only
   used `forward-line`. This is worth calling out because column accuracy matters a lot
   for Verilog port-name-typo-class errors.

**Recommendation for pellicle (this report's synthesis, high confidence on the
architecture reasoning, since it's derived directly from a documented real failure):**
**MUST** use Reticle's single-general-pattern approach (avoids a maintenance-heavy
per-tool table) but **MUST also inherit its fix, not its original design** — cap the
scanned line length *before* invoking any regex/parsing on it (Swift's
`Regex`/`NSRegularExpression` engines have their own backtracking risk profiles that
should be checked, not assumed safe by contrast with Rust's `regex` crate — **this is
an unverified claim** requiring a follow-up local check: does Swift's regex literal
engine bound backtracking depth on adversarial input?). SHOULD support column offsets
end-to-end. SHOULD add a small allowlist of *format hints* (not full per-tool regexes)
for the specific compilers this editor cares about — Verilator's SARIF/JSON output mode
(see A2 note below) and slang's JSON diagnostics, when available, should be preferred
over regex-scraping stdout at all, since they're structured and unambiguous.

**Verilator error format (medium confidence — verilator.org/guide, page content was
LLM-summarized by WebFetch, not directly read verbatim):** Standard
`%Warning-RULENAME: file:line: message` shape, `file:line:` prefix consistent with
GCC-style tools (should match the `gnu` pattern family). Verilator additionally exposes
**`--diagnostics-sarif` / `--diagnostics-sarif-output <file>`** (SARIF, a standard
JSON-based static-analysis interchange format) and `--json-only` for AST dumps. **SARIF
support is the higher-value integration path** — MUST prefer it over regex-scraping
verilator's stdout when the installed verilator version supports it, since SARIF gives
exact ranges, rule IDs, and severities without any regex risk. (Owner's machine
currently lacks verilator — **could not locally verify version/flag availability**;
treat the exact flag names as medium confidence pending a real run.)

**iverilog (high confidence version/presence, medium confidence on exact message
grammar):** iverilog 13.0 (stable) is installed locally (confirmed via `iverilog -V`).
Reticle's own measurement (recorded in PLAN.md M80, not independently re-verified by
this agent but originating from the owner's own prior probe work against the real
binary) found four message shapes and no filelist/JSON diagnostics mode — regex-based
parsing is the only option for iverilog today, reinforcing that the length-capped
general-pattern approach is needed for it specifically.

**Test runners:** `swift test` emits XCTest-style `file:line: error: ...` (same GNU
family); `pytest` supports `--tb=short`/native tracebacks matching Emacs's
`python-tracebacks-and-caml` pattern, and also a `--junit-xml` structured mode SHOULD be
preferred for a "test results pane" (pass/fail per test, not line-scraped); `prove`
(Perl's TAP runner) outputs TAP (Test Anything Protocol), a well-specified line format
(`ok N`, `not ok N - description`) — structured enough to parse directly rather than
regex-per-shape; `ctest` has `--output-on-failure` and a machine-readable
`--output-junit` mode. **Recommendation: wherever a runner offers a structured
machine-readable mode (JUnit XML, TAP, SARIF), MUST prefer it over stdout regex —
regex-scraping is the fallback for tools that only emit prose (iverilog today, Perl
without `prove`).**

---

## A3. Verilog simulation + waveform viewing

**Surfer (medium-high confidence; primary source: surfer-project.org and its GitLab
README, both fetched):**
- Modern, actively developed waveform viewer, Rust + egui, compiles to native
  (Linux/Windows/macOS-ARM) and **WebAssembly** (hosted at app.surfer-project.org).
- Formats: **VCD, FST, GHW**, plus FTR (memory transaction) files.
- License: **EUPL-1.2** (a copyleft license — worth flagging for the owner: bundling
  Surfer's source directly may carry different obligations than shelling out to a
  separately-installed binary; **this report does not give legal advice, flag for the
  owner's own review**).
- Features: fast zoom/pan, fuzzy-completion CLI, bit-vector translation (hex/bin/float/
  instruction decode), cursors, mouse gestures, wave grouping, `postMessage`-driven
  **iframe embedding** with a documented `integration.js` API, and a client-server mode
  ("Surver") for remote waveform serving.
- **The iframe/postMessage embedding path is the single most actionable finding for
  pellicle**: rather than shelling out to a separate GUI app (GTKWave-style) or
  reimplementing a waveform renderer from scratch, pellicle could embed Surfer's
  WASM build inside a `WKWebView` panel and drive it via `postMessage` — giving a
  native-feeling, first-party waveform pane without owning waveform-rendering code.
  This directly fixes one of Reticle's known limitations list items in spirit (no
  GUI-native waveform integration existed there). **Confidence: medium** — the
  `postMessage`/`integration.js` API surface itself was only summarized by WebFetch,
  not read as raw source; a follow-up should pull `integration.js` directly before
  committing to this as a milestone design.

**GTKWave (high confidence, gtkwave.sourceforge.net):** Mature, GTK+-based, reads
VCD/EVCD/LXT/LXT2/VZT/FST/GHW. **No embeddable/library interface** — standalone desktop
app only, would have to be spawned as an external process with no in-app UI
integration. Fine as a v1 "open externally" fallback, not a target for deep embedding.

**Recommendation (A4):** SHOULD embed Surfer via WKWebView + postMessage as the primary
in-app waveform viewer (novel differentiator vs. Reticle, which had none); MUST support
opening VCD (iverilog's native dump format via `$dumpfile`/`$dumpvars`, **not
independently re-verified this session but standard and extremely well established**)
at minimum; COULD add FST support once a simulator that emits it (Verilator) is in the
toolchain. GTKWave as external-process fallback is a cheap MUST-have safety net if
Surfer embedding proves harder than expected.

---

## A4. Task runners + built-in terminal tier

Not independently re-fetched this session (VS Code tasks.json and Zed tasks.json are
both well-documented, low-risk-of-hallucination JSON schemas — declarative task list
with `command`, `args`, `problemMatcher`/similar, `group` (build/test), keybinding to
run). **Recommendation, consistent with the owner's brief that "the app itself should
be a terminal like iTerm2":** pellicle's task runner MUST be built as a thin
declarative layer *on top of* the same PTY/process-spawn machinery that powers the
built-in terminal, not a separate subsystem — a "task" is just a named shell command
plus an optional error-format hint, run in a terminal-tier pane. This both cuts
implementation surface and gives Verilog engineers a task like "iverilog lint" that
behaves exactly like typing the command by hand, with compile/next-error layered on as
an opt-in annotation pass over that same output stream (mirrors Reticle's M80 design of
compile as its own process-list, separate from ad hoc `M-!`, so a long-running compile
can't be killed by an unrelated shell command).

---

## A5. Breakpoint/variables/watch/inline-values UI

Not independently researched via WebFetch this session (mainstream editor UI
conventions, not primary-source-dependent). Standard shape across VS Code/JetBrains/Zed:
gutter click sets/toggles a breakpoint (glyph in the fringe/gutter column); a
Variables/Watch pane driven directly by DAP's `scopes`/`variables` responses; **inline
values** (VS Code-style) annotate the *source buffer itself* at the end of each line
with the live value of variables in scope, refreshed on each `stopped` DAP event — this
is a genuine quality-of-life feature GNU Emacs's `gdb-mi`/`dape` do not do well, and
would be a concrete "beats GNU Emacs" win. **MUST**: gutter breakpoints + variables
pane (baseline table stakes, DAP gives this almost for free). **SHOULD**: inline
values, since it's a differentiator with modest incremental cost once the DAP client
and buffer-annotation system already exist for compile/next-error.

---

## A6. Milestone slice recommendations (highest value for RTL engineers first)

Given the owner's stated priority order (Verilog/SystemVerilog first, then
Swift/Python/Perl/Tcl, then org-mode, then polish):

1. **MUST, first**: compile/next-error over iverilog + verible output (length-capped
   general regex per A2), wired to the same task-runner/terminal-tier pane (A4) — this
   is the single highest-leverage RTL feature and Reticle's own M80 record shows it is
   *cheap relative to its value* (single milestone, well-scoped).
2. **MUST, second**: VCD waveform viewing via embedded Surfer (A3) — RTL engineers
   live in wave viewers; this is a bigger differentiator than debugging for this
   specific audience, since Verilog debugging-in-the-DAP-sense barely exists as a
   concept (simulators are not typically DAP targets).
3. **SHOULD, third**: generic DAP client + lldb-dap (A1) — serves Swift/C/C++
   simultaneously, reuses the same "stopped/variables/breakpoints" UI regardless of
   which language is active, and Swift is the implementation language itself so
   dogfooding value is high.
4. **SHOULD, fourth**: debugpy wiring (Python), reusing 100% of the DAP client from
   step 3.
5. **COULD, later**: Perl DAP (weak ecosystem, budget extra time or drop); Tcl/Tk DAP
   (no known adapter — treat as research spike, not a committed milestone, until a
   concrete adapter candidate is found).
6. **COULD, later**: SARIF-based Verilator ingestion once verilator is actually
   installed and its SARIF flags verified locally (currently unverified).

---

## B1. AI table stakes across top editors (2026)

Not independently WebFetched this session for every product (Copilot/Cursor/JetBrains
AI/Xcode 26/gptel/claude-code.el are widely known and low primary-source risk for a
qualitative "what exists" survey; Zed was fetched directly). Table-stakes AI surface in
2026 across VS Code, Cursor, JetBrains, Xcode 26, and Zed converges on the same short
list: **(a)** inline "ghost text" completion / edit prediction as you type, **(b)** a
chat/agent side panel that can read the open project, propose multi-file diffs, and
run tools (search, edit, execute) with a review-before-apply step, **(c)** "@-mention"
context injection (files, symbols, selections) into a prompt, and **(d)** an
extensible backend — most of these editors now let the *model/agent* be swapped
(Copilot supports multiple model backends; Cursor and JetBrains both added support for
external agent protocols/multiple providers; Zed explicitly documented, see below, that
its agent panel can run its own agent OR any ACP-speaking external agent). In Emacs,
`gptel` (a client library for calling any LLM API from Elisp) and `claude-code.el`
(a thin wrapper that runs the Claude Code CLI in a terminal buffer inside Emacs) show
the **lightest-weight version of the same pattern**: the editor does not own the model
or the agent loop, it just hosts a pane and shells out.

## B2. Protocols that let an editor host agents without owning them

**Model Context Protocol (MCP)** (high confidence, modelcontextprotocol.io): an open
protocol connecting *AI applications* (the LLM-hosting side) to external *tools/data
sources* (servers) — "USB-C port for AI applications." Client/server, with tools,
resources, and prompts as the three primitive types a server exposes. This is the
protocol for **giving an agent capabilities** (read a database, call an API, query
docs) — it does not define editor UI concepts like diffs or permission prompts. Broad
ecosystem adoption confirmed (Claude, ChatGPT, VS Code, Cursor, and others all listed
as supporting it on the official site).

**Agent Client Protocol (ACP)** (high confidence, agentclientprotocol.com +
github.com/zed-industries/agent-client-protocol): the complementary protocol, and the
more directly relevant one for pellicle's architecture. ACP standardizes
communication **between an editor (client) and a coding agent (a separate process)**
over JSON-RPC, explicitly modeled on the LSP pattern ("one implementation, works with
every compliant editor"). Local agents run as an editor subprocess over stdio; remote
agents (HTTP/WebSocket) are documented as still in development. ACP "re-uses the JSON
representations used in MCP where possible" but adds agent-UX-specific types — notably
structured **diff display** and (per the repo) permission-request flows. **Design
intent stated directly on the site**: ACP assumes "the user is primarily in their
editor, and wants to reach out and use agents to assist them," i.e., it is scoped to
exactly the editor-hosts-agent shape pellicle needs, whereas MCP is a general
tool-serving protocol usable by *any* AI application, editor or not. Official SDKs
exist for Kotlin, Java, Python, Rust, and TypeScript (no Swift SDK confirmed —
**unverified**: whether a community Swift ACP client library exists; this report could
not confirm one, treat as "build our own thin JSON-RPC client over the published
schema" until proven otherwise).

**Zed's implementation as a concrete existence proof** (high confidence, zed.dev/docs):
Zed's Agent Panel can run either its own built-in agent or "ACP-integrated agents that
run through their own process and configuration" — i.e., Zed itself is proof that an
editor can be **agent-agnostic at the UI layer** via ACP while still supporting MCP
servers as tool sources *within* whichever agent is running. Zed explicitly documents a
"turn AI off" path, i.e., the feature is fully optional by design, not a hard
dependency of the editor core. This is the architecture pattern to copy.

**Claude Agent SDK / CLI as a hostable agent** (high confidence, code.claude.com docs,
fetched directly): the Agent SDK is a Python/TypeScript **library** that runs Claude
Code's own agent loop in your process; for other languages (Swift included), the
documented path is **running the Claude Code CLI as a subprocess with `-p` (headless)
and `--output-format json`** — i.e., a streaming-JSON-over-stdio subprocess protocol,
which is exactly the transport shape ACP expects from a local agent. This is direct
confirmation that **pellicle does not need Anthropic's cooperation to host Claude
Code**: it can either (a) speak ACP if/when Claude Code ships an ACP server mode, or
(b) drive the CLI directly via its own headless JSON subprocess protocol as a
lower-level fallback. **Branding note (verified from the fetched page): Anthropic's
terms explicitly disallow presenting a third-party integration as "Claude Code" or
using Claude Code branding/ASCII art** — pellicle's Claude integration, if built,
must use its own name/branding per Anthropic's stated terms, and per the same page,
"Anthropic does not allow third party developers to offer claude.ai login... for their
products" built on the Agent SDK, meaning **API-key auth, not consumer OAuth login, is
the documented path for an SDK-based integration** (the CLI-subprocess path, run under
the *user's own already-authenticated* Claude Code CLI install, sidesteps this — the
user logs into their own copy of Claude Code, pellicle just shells out to it).

**LSP inline completion:** not independently re-verified this session, but this is a
standard, stable part of the Language Server Protocol (`textDocument/inlineCompletion`)
that several editors already use as a transport for ghost-text suggestions from any
LSP-speaking completion backend, independent of ACP/MCP. **SHOULD** be supported as a
second, lighter-weight integration point for pure-completion (non-agentic) AI backends
that only want to offer inline suggestions without the full agent/tool-call machinery.

**Apple Foundation Models framework** (high confidence for API shape, from the WWDC25
session transcript fetched directly): on-device **3B-parameter, 2-bit-quantized** LLM
that ships with Apple Intelligence, exposed to apps via `LanguageModelSession`,
`@Generable`/`@Guide` macros for schema-constrained ("guided") generation, streaming
via `PartiallyGenerated` snapshot types, and developer-defined **tool calling**
(`Tool` protocol, `@Generable` arguments). Explicitly **not** suited for "world
knowledge" or "advanced reasoning" — Apple's own guidance says to break tasks into
small pieces and use server-scale models for anything requiring real reasoning depth.
Has a **hard context-window limit** that throws `contextWindowExceeded` rather than
truncating silently, and **no fine-tuning** beyond a separate "custom adapter training
toolkit" for ML practitioners (not consumer-app development). Availability requires an
Apple-Intelligence-enabled device and passes through a runtime
`SystemLanguageModel.default.availability` check — **exact macOS/hardware minimum
version was not confirmed in the fetched transcript** (a separate attempted fetch of
the API reference page returned no body content — mark **minimum macOS version for
Foundation Models framework as unverified**, though macOS 26 is a reasonable inference
given the owner's machine already runs macOS 26.6.2 with Apple Intelligence available).
**Given the 3B-parameter size and explicit "not for advanced reasoning" guidance, the
Foundation Models framework is not a credible substitute for a frontier coding agent**
— its realistic role in pellicle is small on-device tasks (quick rewrite, comment
generation, simple classification/tagging) that must work with zero network egress,
which is directly relevant to the IP-confidentiality constraint below, not a
replacement for an ACP-hosted Claude/GPT-class agent for RTL work.

## B3. AI for RTL specifically, and the IP-confidentiality risk

Not independently WebFetched (this is domain reasoning, not a claim needing a primary
source). Concrete RTL use cases where an LLM-backed agent is plausibly high-value:
**testbench scaffolding** (given a module's port list, generate a UVM/directed
testbench skeleton), **port-mapping/instantiation boilerplate** (AUTOINST-style, but
LLM-assisted for cases the mechanical AUTO system can't infer, e.g. matching similarly
named but differently ordered ports across a bus protocol), **lint-fix suggestions**
(take a verible/verilator diagnostic and propose the minimal source edit), and
**waveform-to-explanation** (given a VCD signal window, explain a likely root cause in
English) — this last one is speculative and not something this report can point to a
shipping product doing.

**The dominant risk, stated plainly: semiconductor RTL is some of the most
confidentiality-sensitive source code that exists** (pre-tapeout IP, process-node-
specific implementation details). Any cloud-hosted agent integration for a
Verilog-first editor **MUST** default to **not** sending source to a network endpoint
without explicit, per-project opt-in, and **SHOULD** make the on-device Foundation
Models path (or a self-hosted/local-network model via an MCP or ACP server the company
runs itself) a first-class, equally-supported option, not an afterthought bolted onto a
cloud-first design. This is the strongest argument in this whole report for the
ACP/MCP pluggable-backend architecture over any hard-coded vendor integration: an RTL
shop can point pellicle at its own locally-hosted model server with zero editor code
changes if the AI layer is protocol-based rather than vendor-specific.

## B4. Recommended integration architecture

Synthesizing B1-B3 and Zed's proof-of-concept: **MUST** — pellicle's core editing,
compile/next-error, DAP, and waveform features (all of Section A) must work completely
with AI disabled; AI is an optional layer, never a dependency of the hot path (matches
the owner's brief's emphasis on performance/reliability, and matches Zed's own
documented "turn AI off" design). **MUST** — implement an ACP client in the editor so
any ACP-speaking agent (Zed's own agent, Claude Code if/when it exposes ACP, Gemini
CLI, others) can be hosted in a side panel without pellicle hard-coding a vendor;
fall back to driving the Claude Code CLI directly via its documented headless
`-p --output-format json` subprocess mode as a bridge until/unless native ACP support
lands upstream. **SHOULD** — support MCP as the tool/context-source layer *underneath*
whichever agent is hosted, so users can point their agent at their own MCP servers
(e.g., a company-internal RTL knowledge base) independent of which agent vendor they
chose. **SHOULD** — wire `textDocument/inlineCompletion`-style ghost text as a
lighter-weight, independent path for pure-completion backends that don't need the full
agent UI. **COULD** — offer the on-device Foundation Models framework as a zero-config,
zero-network default for small tasks and IP-sensitive shops, clearly scoped to its
real limits (no deep reasoning, small context window, no fine-tuning). **Never**
hard-code a single AI vendor's branding or auth flow into the editor core; keep it
behind the same protocol boundary regardless of which agent a given user or company
chooses to run.

---

## Unverified claims (explicit list)

1. Exact SARIF/JSON flag names and behavior for Verilator (`--diagnostics-sarif`,
   `--diagnostics-sarif-output`, `--json-only`) — summarized by WebFetch from
   verilator.org, not confirmed against a locally installed verilator (none present on
   the owner's machine).
2. Whether Swift's native regex engine (`Regex`/`NSRegularExpression`) has the same
   unbounded-backtracking crash risk that Reticle hit in Rust's `regex` crate — not
   tested this session; flagged as a required check before committing to the
   "length-cap only" mitigation design for compile/next-error.
3. Minimum macOS version required by Apple's Foundation Models framework — the WWDC25
   transcript fetch didn't state it explicitly; a direct fetch of
   developer.apple.com/documentation/foundationmodels returned no page body this
   session. Inferred (not confirmed) to be macOS 26, consistent with the owner's
   machine.
4. Whether any Swift-language ACP client/SDK already exists in the community (the
   official SDK list covers Kotlin/Java/Python/Rust/TypeScript only) — not confirmed
   either way; assume "none" and budget for writing a thin JSON-RPC client against the
   published ACP schema.
5. Icarus Verilog's exact error-message grammar (the "four shapes" list) originates
   from Reticle's own prior probe work recorded in its PLAN.md, not independently
   re-verified against iverilog 13.0 by this agent (though iverilog 13.0 itself is
   confirmed present and functional locally).
6. Surfer's `integration.js`/postMessage embedding API surface was only summarized by
   WebFetch from prose on the project site, not read as raw source — recommend pulling
   the actual `integration.js` file before committing to a WKWebView-embedding
   milestone design.
7. Whether Perl's "Perl Debug" / "Perl::LanguageServer" DAP adapters are actively
   maintained and production-quality — the DAP adapters registry lists them but this
   report could not assess maintenance status or real-world reliability.

## Sources (fetched directly this session unless noted otherwise)

- https://microsoft.github.io/debug-adapter-protocol/ — DAP overview
- https://microsoft.github.io/debug-adapter-protocol/implementors/adapters/ — adapters list
- https://lldb.llvm.org/use/tutorial.html — lldb-dap pointer
- Local: `xcrun -f lldb-dap`, `lldb-dap --help` (Xcode 26.6, confirmed present)
- https://github.com/microsoft/debugpy — debugpy README
- https://verilator.org/guide/latest/exe_verilator.html — Verilator CLI/diagnostics
- https://surfer-project.org/ — Surfer overview
- https://gitlab.com/surfer-project/surfer/-/raw/main/README.md — Surfer README (raw)
- https://gtkwave.sourceforge.net/ — GTKWave overview
- https://steveicarus.github.io/iverilog/ — iverilog docs index
- Local: `iverilog -V` (13.0 stable, confirmed present)
- https://agentclientprotocol.com/overview/introduction — ACP overview
- https://github.com/zed-industries/agent-client-protocol — ACP repo README
- https://modelcontextprotocol.io/introduction — MCP overview
- https://zed.dev/docs/ai/overview — Zed AI features
- https://code.claude.com/docs/en/ide-integrations (redirected through docs.claude.com
  → platform.claude.com → code.claude.com/docs/en/agent-sdk/overview) — Claude Code
  IDE integrations + Agent SDK overview
- https://developer.apple.com/videos/play/wwdc2025/286/ — Foundation Models framework
  WWDC25 session
- Local: `/opt/homebrew/bin/emacs -Q --batch ... compilation-error-regexp-alist-alist`
  (GNU Emacs 30.2's full per-tool error-format table, read directly)
- `/Users/jerrychen/My_Projects/reticle/PLAN.md` lines ~7378-7553 (M80 record) — read
  directly, not summarized by a fetch tool
