# Extension architectures compared, and sandboxed hosting options on macOS

Topic key: extension-architectures. Research for pellicle planning (macOS-only Swift
editor with a built-in Elisp interpreter). Confidence marked per claim: **high** (primary
source, directly read), **medium** (primary source but inferred/summarized, or slightly
stale), **low** (secondary/blog or memory-based), and a final **unverified** section for
anything WebFetch could not confirm this session (WebSearch quota exhausted, so no
independent corroboration was possible — everything below rests on whatever primary URLs
WebFetch could reach, plus prior knowledge explicitly flagged as such).

## Outline

1. VS Code extension host
2. JetBrains plugin model / Fleet
3. Neovim (Lua in-process + msgpack-RPC remote plugins)
4. Zed (Wasm/WIT via wasmtime)
5. GNU Emacs (in-process Elisp + dynamic modules) — includes Reticle's own C-ABI as prior art
6. Comparison table: isolation, latency, capability surface, UI exposure, crash containment,
   hot reload, API versioning, marketplace
7. macOS native hosting options: ExtensionKit/ExtensionFoundation, XPC/NSXPCConnection,
   App Sandbox vs. a shell-running/any-file editor
8. Wasm runtimes usable from Swift: WasmKit, wasmtime C API, wasm3, WAMR
9. Recommendation: tiered plugin model for pellicle
10. Unverified / could-not-confirm list

---

## 1. VS Code: separate extension host process

- **Isolation boundary**: extensions run in a Node.js **Extension Host** process, separate
  from the renderer/UI process. VS Code supports a local host (same machine), a remote host
  (container/SSH), and a web host (browser). (High confidence — code.visualstudio.com/api/advanced-topics/extension-host,
  fetched directly.) The exact IPC transport and crash-recovery behavior of the host process
  were **not stated** on the fetched page — treat those specifics as unverified.
- **Activation events** (medium-high confidence, code.visualstudio.com/api/references/activation-events):
  extensions declare `activationEvents` in `package.json` (`onLanguage:*`, `onCommand:*`,
  `onDebug`, `onView:*`, `onUri`, `workspaceContains:*`, `onStartupFinished`, the catch-all
  `*`) and are loaded lazily only when one fires. `onStartupFinished` is explicitly
  documented as not slowing startup (fires "some time after" startup); `*` is discouraged
  ("only... when no other activation events combination works").
- **Contribution points** (high confidence, code.visualstudio.com/api/references/contribution-points):
  a large declarative surface in `package.json`'s `contributes` field — commands, menus,
  keybindings, views/viewsContainers, languages/grammars/snippets, themes/iconThemes,
  configuration, authentication, debuggers, customEditors, taskDefinitions, terminal
  profiles, walkthroughs. Crucially, contributions are **declared statically and read
  without activating the extension's code** — this is the mechanism that lets VS Code know
  an extension's UI/capability surface exists before paying the cost of loading it.
- **Language features via LSP**: not independently re-fetched this session, but consistent
  with VS Code's well-documented architecture (medium confidence, prior knowledge): heavy
  language intelligence (indexing, completion, diagnostics) is pushed into a **separate
  Language Server process** over JSON-RPC (LSP), not into the extension host's JS thread —
  a second layer of process isolation beyond the extension-host/renderer split.
- **Net effect on the isolation/latency/crash axes**: extension code cannot block the UI
  (separate process), but a misbehaving extension *can* still starve the single-threaded
  Node extension host and slow down every other extension sharing it — VS Code's isolation
  is host-vs-UI, not extension-vs-extension. Hot reload is per-extension via
  activate/deactivate lifecycle hooks; marketplace is centralized (Microsoft Marketplace)
  with semver-ish `engines.vscode` version gating.

## 2. JetBrains: in-process JVM plugins, Fleet's split

- **Extension points** (high confidence, plugins.jetbrains.com/docs/intellij/plugin-extension-points.html,
  fetched directly): plugins declare `<extensionPoints>` (interface-based: other plugins
  supply implementing classes; or bean-based: other plugins supply data deserialized into a
  bean class) and other plugins/the platform itself register `<extensions>` against them in
  `plugin.xml`, discovered at runtime via `ExtensionPointName`. Indexing-aware filtering
  exists (`PossiblyDumbAware`, `DumbService.getDumbAwareExtensions()`) so extensions can opt
  into running during "dumb mode" (index rebuild) or be excluded.
- **In-process execution**: the fetched extension-points page did **not** explicitly state
  whether plugins share the IDE's JVM (that detail fell outside that specific page's scope —
  explicitly flagged by the fetch as not covered). This is treated as **medium confidence
  from prior knowledge, not re-verified this session**: classic IntelliJ plugins run
  **in-process in the same JVM** as the IDE, with per-plugin classloaders providing load/
  dependency isolation but not fault or memory isolation — an unhandled plugin exception is
  typically caught and reported without crashing the whole IDE (IntelliJ has long had a
  "Plugin X is slow/misbehaving" instrumentation layer), but a genuine hang (e.g. blocking
  the EDT) or an OOM inside a plugin **can** degrade or crash the whole IDE, since there is
  no process boundary. Dynamic plugin loading/unloading without restart ("dynamic plugins")
  exists for compliant plugins (also prior knowledge, medium confidence, not re-verified).
- **Fleet's split** (low confidence — **could not fetch either the JetBrains blog
  architecture post or the current help.jetbrains.com Fleet architecture page this
  session; both returned 404 to WebFetch**): from prior knowledge only, Fleet's architecture
  separates a lightweight frontend (UI/editing) from one or more backends that can run
  locally or remotely (SSH/container) and reuse IntelliJ platform code (indexing, PSI,
  inspections) out-of-process from the UI, communicating over RPC. This whole subsection
  should be treated as **unverified** pending a source that actually loads.

## 3. Neovim: in-process Lua + msgpack-RPC remote plugins

(High confidence — github raw `runtime/doc/api.txt`, fetched directly; the `neovim.io` doc
mirror itself returned empty/unfetchable content for both `remote_plugin.html` and
`api.html`, so all Neovim claims below come from the GitHub-hosted source doc, not the
neovim.io site as the brief specified.)

- **In-process Lua**: Lua plugins/config run inside the Nvim process itself via the
  embedded LuaJIT/Lua runtime — zero IPC cost, full access to editor internals, but also
  no isolation: a Lua callback that throws or hangs can affect the editor directly. The doc
  notes in-process Lua callbacks run in "fast" contexts with restrictions on some editor
  operations via `textlock` (a re-entrancy guard, not a security sandbox).
- **Remote plugins / RPC clients**: fully **out-of-process**, communicating over
  **msgpack-RPC** (TCP/IP or named pipe / Unix domain socket; `v:servername` exposes the
  default socket, `--listen host:port` or `serverstart()` create more). This is
  language-agnostic — any process that speaks msgpack-RPC can be a "remote plugin," which is
  how Neovim supports plugins in Python, Ruby, etc. via host shims, and is architecturally
  the same shape as an LSP/DAP client.
- **API versioning**: exposed via `nvim_get_api_info()` returning `api_level` (monotonic
  integer), `api_compatible` (minimum compatible level), `api_prerelease` (instability
  flag). The API follows a "versionless evolution" contract: existing function signatures
  never change meaning, new functions are additive, and new fields land as optional `opts`
  parameters that old clients can omit — a pragmatic, low-ceremony versioning scheme
  compared to VS Code's `engines` semver gate or Zed's WIT-schema-version gate.
- **Isolation/latency/crash summary**: two-tier by construction — in-process Lua is zero
  latency / zero isolation; RPC remote plugins are fully isolated (separate process, crash
  cannot take down Nvim) at msgpack-RPC latency (local IPC, sub-millisecond typically, but
  now serialization + context-switch cost per call, unattractive for very hot paths like
  per-keystroke completion filtering).

## 4. Zed: Wasm/WIT sandbox via wasmtime

- **Compilation target**: confirmed (github.com/zed-industries/zed extension_api README,
  high confidence, fetched directly) that Zed extensions compile to **`wasm32-wasip2`** and
  are packaged as `.wasm` files; developers implement an `Extension` trait and register it
  via `zed::register_extension!()`.
- **Versioning**: confirmed via the same README's compatibility table — the
  `zed_extension_api` crate is versioned and each version is pinned to a **range of Zed
  releases** (e.g. `0.6.0` ↔ Zed `0.192.x`, `0.0.1` ↔ Zed `0.128.x` and earlier) — an
  explicit, published compatibility matrix rather than a loose semver promise.
- **Wasm sandbox quirks** (high confidence, same README): because the extension runs in a
  wasm32-wasip2 sandbox, ordinary Rust std facilities that assume a native process
  environment silently misbehave — `cfg`-directives don't work as expected and
  `std::env::var` "will also not yield the expected results"; extensions must instead use
  `zed_extension_api::current_platform()` and a `Worktree` handle for environment/platform
  info. This is a concrete, documented example of "what extensions cannot do": they cannot
  freely read the host process's real environment or assume standard OS process semantics.
- **What could not be confirmed**: the specific runtime (wasmtime) is used by Zed per prior
  public knowledge and the brief's own framing, but **the two Zed pages/repo views fetched
  this session did not themselves state "wasmtime"** (the extension_host crate's actual
  source wasn't reachable as a directory listing gave no file contents, and zed.dev's
  extensions docs pages returned only nav-level content, not the deeper "developing
  extensions" body). Treat "Zed uses wasmtime" as **medium confidence, not re-confirmed by
  a primary source this session** even though it is widely reported and consistent with the
  crate name `extension_host` depending on `wasmtime` in Zed's own `Cargo.toml` (not
  re-checked here). WIT interface definitions, fuel/epoch use, and hot-reload behavior
  inside `extension_host` were **not** retrievable this session (GitHub directory listing
  has no file content via WebFetch) — mark as **unverified**.
- **Isolation/latency summary (medium confidence, inferred from the sandboxing facts
  above rather than directly documented)**: Wasm sandboxing gives Zed strong isolation
  (extensions cannot touch arbitrary host memory or make arbitrary syscalls — WASI mediates
  I/O) with near-native compute latency for the parts that stay inside the sandbox, but any
  call that crosses into the host (LSP binary download, filesystem read) goes through an
  explicit host-provided WIT-bound API surface, which is also where Zed can meter/limit/
  deny.

## 5. GNU Emacs: in-process Elisp + dynamic modules; Reticle's C-ABI as prior art

(Prior knowledge for real GNU Emacs, medium-high confidence — this is well-established
public information about a system already installed on the owner's machine (Emacs 30.2)
and not something WebFetch access was spent on, per the work budget; Reticle's own module
ABI was read directly from source, high confidence.)

- **In-process Elisp**: the classic Emacs model — Elisp runs inside the single Emacs
  process, byte-compiled or interpreted, with full access to buffer/window/frame internals
  and no isolation whatsoever. This is what gives Emacs its famous introspectability and
  also its famous failure mode: a runaway or infinite-looping Lisp form freezes the entire
  editor (single-threaded core; `C-g` / `signal` are the only escape hatches), and a fatal
  error in a package can corrupt shared global state (advice, hooks, `defvar`s) for the rest
  of the session.
- **Dynamic modules** (`emacs-module.h`, real Emacs 25+): native code (C/Rust/etc.) loaded
  into the *same process* via `dynamic-module-p`/`module-load`, exposed to Elisp through a
  versioned table of function pointers (`emacs_env`) and small opaque `emacs_value` handles.
  This is still in-process — a segfault in a module crashes Emacs — but it decouples the
  module's *implementation language* from Elisp and gives some ABI stability across Emacs
  versions via the `size`-prefixed struct trick.
- **Reticle's own module-abi** (`/Users/jerrychen/My_Projects/reticle/crates/module-abi/src/lib.rs`,
  read directly): deliberately modeled on `emacs-module.h` — a versioned `#[repr(C)]`
  `ModuleEnv` struct of `extern "C" fn` pointers (`make_integer`, `extract_integer`,
  `make_string`, `copy_string_contents`, `intern`, `eq`, `funcall`, `make_function`,
  `signal_error`), with values exchanged as an opaque `ModuleValue(u32)` handle — **not a
  pointer into the host's real `Value`/`Rc` internals**, so a module can never forge or
  corrupt a host value, and the host's internal representation is free to change without
  breaking the ABI. `size: usize` at the front of `ModuleEnv` lets a module detect a
  host/module version mismatch instead of reading garbage past a shorter/longer struct.
  `signal_error` is a deliberately narrowed v1 (`msg` only, no condition-symbol/data list
  like real Emacs's `non_local_exit_signal`), documented in Reticle's PLAN.md M13 as an
  explicit scope cut. This is a good template for pellicle's own C-ABI module tier: small
  function-pointer table, opaque handles, self-describing size for version skew detection,
  same-process (fast, unsafe) trust model reserved for code the user explicitly opted into.
- **Net comparison to VS Code/JetBrains/Zed**: Emacs (and Reticle) sit at the opposite end
  of the isolation spectrum from Zed — maximal capability and latency, zero isolation, by
  design. There is no marketplace-level version gate; compatibility is whatever the loaded
  `.el`/`.so`/`.dylib` and the running Emacs happen to agree on at load time.

## 6. Comparison table

| | Isolation boundary | Latency | Capability surface | UI exposure | Crash containment | Hot reload | API versioning | Marketplace |
|---|---|---|---|---|---|---|---|---|
| **VS Code** | separate Node extension-host process (+ separate LSP process for language features) | IPC per call, but heavy language work already isolated into LSP | broad JS/TS API + declarative contribution points | contributes views/menus/webviews; extension can't touch DOM directly | host crash doesn't crash renderer; single host shared by all extensions so one can still starve others | activate/deactivate lifecycle; window reload for most changes | `engines.vscode` semver range in package.json | centralized Marketplace, curated but broadly open |
| **JetBrains (classic)** | none (in-process JVM) — classloader isolation only | zero IPC, native call speed | very deep (PSI, indexing, UI, everything) | full Swing/IntelliJ UI toolkit access | best-effort exception containment; true hangs/OOM can take down the IDE (medium confidence, not fully re-verified) | "dynamic plugins" subset can hot-load/unload w/o restart (medium confidence) | plugin.xml `since-build`/`until-build` IDE version ranges | JetBrains Marketplace |
| **JetBrains Fleet** | frontend/backend process split (**unverified this session** — sources 404'd) | RPC-level (unverified) | backend reuses IntelliJ platform code (unverified) | thin frontend renders what backend sends (unverified) | unverified | unverified | unverified | unverified |
| **Neovim (Lua)** | none (in-process) | zero | full editor internals via Lua API | direct buffer/window manipulation | a throwing/hanging callback affects the editor directly | `:source`/module reload patterns, no formal hot-reload system | none formal; Lua API stability is by convention | no central marketplace; git-based plugin managers |
| **Neovim (remote/RPC)** | separate OS process, msgpack-RPC | local IPC (socket/pipe) latency per call | whatever the RPC API exposes (`nvim_*` functions) | indirect, via buffer/window RPC calls | fully contained — remote process crash cannot crash Nvim | independent process restart | `api_level`/`api_compatible`/`api_prerelease`, additive/versionless evolution | no central marketplace |
| **Zed** | Wasm sandbox (`wasm32-wasip2`) via a host runtime, WASI-mediated I/O | near-native inside sandbox; host calls cross an explicit WIT boundary | deliberately narrow: languages, themes, LSP/DAP/context-server registration, slash commands — no arbitrary host env/syscalls | no direct UI toolkit access; contributes via declared extension points | wasm trap is contained to the extension, cannot corrupt host memory | unconfirmed this session (extension_host internals not reachable) | `zed_extension_api` version pinned to Zed release ranges (published compatibility table) | curated Zed extension registry |
| **GNU Emacs (Elisp)** | none (in-process) | zero | maximal — entire editor is Lisp-observable/mutable | full, unmediated | none — errors can be caught by `condition-case` but a hang freezes the whole (single-threaded) editor | `eval-buffer`/`load` re-evaluates definitions live | none formal; `package.el` version deps are advisory | ELPA/MELPA/non-GNU ELPA, largely uncurated |
| **Emacs dynamic modules / Reticle module-abi** | none (in-process native code) | zero (native call) | whatever the function table exposes (Reticle: integers/floats/strings/funcall/signal-error) | none directly; modules define elisp functions that then act on the editor | a segfault in the module crashes the host process | requires reload/relink | `size`-prefixed struct for host/module skew detection (Reticle); real Emacs uses similar `emacs_runtime`/`emacs_env` versioning | none; ad hoc `.dylib`/`.so` distribution |

## 7. macOS native hosting options

- **ExtensionKit / ExtensionFoundation** (confidence: **medium** — the ExtensionKit
  overview page fetch returned a well-structured summary but WebFetch pages for Apple
  Developer Documentation are frequently JS-rendered shells, so treat specifics below as
  plausible-and-consistent-with-public-knowledge rather than independently re-verified
  verbatim quotes; the more specific `AppExtensionScene` page and the WWDC22 "Meet
  ExtensionKit" session both 404'd/mismatched this session and could not be confirmed):
  - `EXHostViewController` lives in the **host app's process** and embeds an extension's UI;
    the extension itself (`EXAppExtension`/`AppExtensionScene` under ExtensionFoundation) runs
    in its **own separate, sandboxed process**, so an extension crash does not crash the host,
    and IPC between them is XPC-based under the hood.
  - Reported as **not requiring Mac App Store distribution** for macOS ExtensionKit
    extensions, with **App Sandbox mandatory** for the extension side. This "no App Store
    required" point is important for pellicle (a non-App-Store editor) but should be
    treated as **medium confidence** pending a cleaner primary-source confirmation — the
    RESULTS.md spike already separately confirmed (section 2, high confidence, actually
    compiled) that `import ExtensionKit` and `import ExtensionFoundation` both typecheck
    against the macOS 26 SDK from a Swift 6.3 command-line target, i.e. the frameworks are
    present and importable outside an Xcode app-extension project template.
  - **Ergonomics/limits for a non-App-Store editor**: ExtensionKit's process model matches
    exactly what a tiered plugin architecture wants for a "sandboxed tier" — real OS-level
    process isolation with a supported UI-embedding story (unlike raw XPC, which has no UI
    story at all). The catch is that ExtensionKit extensions are still built as **separate
    executable targets** (`.appex`-shaped bundles) with their own Info.plist extension-point
    declaration and, per the App Sandbox requirement, extensions themselves are constrained
    in filesystem/network access unless explicitly entitled — workable for a "plugin renders
    a WebView-like side panel" tier, awkward for a plugin that needs to `exec` a shell (that
    capability belongs in the in-process or LSP/XPC-service tier instead, not an
    App-Sandboxed ExtensionKit extension).
- **XPC services / `NSXPCConnection`** (high confidence — this is long-standing, stable
  Apple API surface, prior knowledge, not requiring a fresh fetch): a lighter-weight
  alternative to ExtensionKit for pure computation/service isolation without a UI story.
  An `NSXPCConnection` to a helper tool or `.xpc` bundle gives process isolation, a
  Swift-protocol-shaped RPC surface (`NSXPCInterface`), and independent crash containment
  (the connection's `interruptionHandler`/`invalidationHandler` fire on the helper's death
  without taking down the host). This is the natural mechanism for pellicle's
  "sandboxed tier" plugins that need to do real work (parse a file, run a linter binary)
  without UI, and pairs well with a `Codable`-based JSON message shape if the team wants an
  API surface that could later also be spoken over stdio (matching the LSP/DAP tier).
- **App Sandbox vs. an editor that must run shells and read any file**: pellicle's own
  requirement (iTerm2-like shell hosting, `M-!`/`shell-command`, editing arbitrary files
  outside a sandboxed container) is fundamentally incompatible with the **host app itself**
  being App-Sandboxed with the default file-access entitlements — this is why the top-level
  pellicle.app should almost certainly ship **unsandboxed** (like Emacs.app, iTerm2, VS
  Code, and Zed all do), while *specific plugin-hosting extension processes* it launches
  (ExtensionKit `.appex`, XPC helpers) can still be sandboxed individually. Sandboxing is a
  property of the process being launched, not a project-wide either/or — the recommended
  shape is: unsandboxed host, sandboxed extension/plugin processes for the tier that doesn't
  need shell/filesystem breadth.

## 8. Wasm runtimes usable from Swift

- **WasmKit** (high confidence, github.com/swiftwasm/WasmKit README, fetched directly):
  pure-Swift WebAssembly runtime/VM, no Foundation dependency, minimal dependencies
  (swift-system only for the core engine). Interpreter-based (register-machine
  architecture), not JIT — described as "reasonably fast" with no benchmark numbers on the
  fetched page. WASI 0.1 support covers "majority of syscalls" but is incomplete; WASI
  Threads not implemented. Component Model / WIT support is explicitly "in progress" on
  main — i.e., **not yet usable** for a WIT-based plugin API as of the fetched state.
  Fuel/gas metering and execution-interruption mechanisms were **not documented** on the
  fetched page — treat as **unverified/likely-absent**, which matters a lot for a plugin
  host that must guarantee it can preempt a runaway plugin. Platform support spans macOS
  10.13+/iOS/tvOS/watchOS/Linux/Android/Windows, and it ships inside the official Swift
  toolchain for Linux/macOS starting Swift 6.2 — meaning it can likely be adopted with **no
  external dependency at all**, just `import WasmKit` (or whatever the toolchain-provided
  module is named) from a Swift 6.3 project, which is attractive for pellicle's
  "no third-party build" constraints during early milestones.
- **wasmtime (via C API)** (high confidence for the interruption mechanisms, medium for
  everything else — the general C-API doc page fetched thin content, but the dedicated
  "interrupting wasm" doc page fetched full, specific content): C API ships as
  `wasmtime.h`/`wasi.h`/`wasm.h`, consumable from Swift via a C-interop module map (the
  standard way to use any C library from Swift) or via the `wasmtime.hh` C++ wrapper (not
  directly Swift-importable without an Objective-C++ or C shim layer). Two execution-limiting
  mechanisms, confirmed directly from wasmtime's own docs:
  - **Fuel metering** (`Config::consume_fuel` + `Store::set_fuel`): deterministic,
    instruction-counted interruption, but with real measured runtime overhead ("slowing down
    Wasm programs").
  - **Epoch-based interruption** (`Config::epoch_interruption` + `Engine::increment_epoch`):
    wall-clock-driven, ~10% overhead, non-deterministic interrupt point. This is the
    documented, cited recommendation for keeping a host UI thread responsive against
    runaway guest code, since low overhead matters more than reproducibility for that goal.
  - **Component model / WIT maturity**: the component-model API docs (`wasmtime` crate,
    `component` module) are gated behind a `component-model` Cargo feature flag and, as of
    the fetched dev-branch docs (version string `50.0.0-dev`), still mark async-related
    component-model features as experimental. No explicit "production ready" statement was
    found — **treat wasmtime's component model as still-maturing, not yet a settled
    foundation to build a long-term plugin ABI on**, consistent with Zed's own choice to
    target `wasm32-wasip2` (WASI Preview 2, which itself layers on the component model) via
    hand-rolled `Extension` trait bindings rather than declaring the component model "done."
  - Memory limits: not independently confirmed this session (no page reached that
    documented `Store::limiter`/`ResourceLimiter`); this is well-known wasmtime
    functionality from general knowledge (medium confidence, not re-verified) — a host can
    cap a `Store`'s linear memory and table growth via a `ResourceLimiter` callback.
  - Hot reload: not covered by any fetched page; unverified this session, though
    recompiling/re-instantiating a wasm module and swapping the `Store`/`Instance` is the
    generic pattern any embedder (including wasmtime) supports, since wasm modules are
    already loaded per-instantiation rather than linked once at process start.
- **wasm3 / WAMR**: **not fetched this session** (budget spent on WasmKit/wasmtime, which
  are the two most relevant candidates for a Swift host per the brief). From prior
  knowledge only (low confidence, unverified): wasm3 is a small, fast pure-C interpreter
  with minimal footprint but has seen reduced maintenance activity in recent years and no
  native Swift bindings; WAMR (WebAssembly Micro Runtime, Bytecode Alliance) offers an
  interpreter, a fast "AOT" ahead-of-time compilation path, and a small runtime footprint
  aimed at embedded use, with a C API bindable from Swift the same way wasmtime's C API
  would be, but likewise has no first-class Swift package. Neither was verified this
  session — mark **both as unverified**, and note that WasmKit's inclusion in the official
  Swift toolchain makes it the path of least friction regardless of wasm3/WAMR's specific
  merits, unless wasmtime's JIT-class performance or fuel/epoch interruption specifically is
  required (WasmKit's interpreter-only execution and undocumented interruption support are
  the two things that would push toward the wasmtime C API instead, at the cost of a
  non-Swift-native dependency and a `50.0.0-dev` component-model surface).

## 9. Recommended tiered plugin model for pellicle

Given the comparison above and pellicle's own constraints (must feel like Emacs
architecturally — in-process Elisp for config — but must not let plugins degrade
performance/stability, and the host app itself must be unsandboxed to act as a shell/
terminal), the recommended shape is a **three-tier model**, deliberately mirroring the
spread already visible across VS Code (host process boundary), Zed (Wasm sandbox), and
Neovim (RPC remote plugins) rather than picking just one:

**Tier 1 — in-process Elisp (config + light extension, the default/"just works" tier).**
Runs on pellicle's own Elisp interpreter, in the main process, same trust model as real
GNU Emacs. This is where `init.el`, mode hooks, keybindings, minor UI tweaks, and
`define-derived-mode`/syntax-table style customization live — anything the owner would
naturally reach for a `(defun my-...)` for. Principles to keep this tier from wrecking
performance, borrowing Neovim's `textlock` idea and Emacs's own C-g/timeout culture:
  - **Never run Elisp on the UI-rendering thread's hot path** — buffer mutation and
    redisplay-triggering calls happen off the "must render this frame" critical section;
    pellicle's redisplay should be able to skip a frame and show stale-but-consistent
    state rather than block on Elisp.
  - Give every user-invoked Elisp call path a **soft wall-clock budget with a warning**
    (not a hard kill — killing Lisp mid-mutation risks corrupting buffer state the way a
    hard `SIGKILL` would), analogous to Emacs's `max-lisp-eval-depth`/`with-timeout` but
    surfaced proactively, e.g. "this hook took 400ms" logged instead of discovered as a
    freeze.
  - Elisp should still be allowed to do essentially everything real Emacs Lisp can do
    in-process: read/write buffers, install hooks/advice, define commands and keymaps,
    talk to Tier 2/3 plugins over their RPC surface (Elisp is the *orchestrator*, not
    excluded from talking to sandboxed code) — the goal is not to weaken Elisp, it's to keep
    *native, compiled, untrusted* code out of this tier. A byte-compiled/JIT'd Elisp form is
    still interpreted/compiled by pellicle's own trusted runtime, so a bug in it is a bug
    in Elisp code, not memory corruption in the host.

**Tier 2 — sandboxed native extensions, Wasm-first with an XPC/ExtensionKit escape hatch.**
This is the tier for compiled, potentially untrusted, performance-sensitive extensions
(e.g. a fast syntax highlighter, a custom completion scorer, a themed renderer plugin) that
need native speed but should not be trusted with the run of the process:
  - **Primary mechanism: WasmKit**, since it ships in the Swift toolchain itself (Swift
    6.2+, confirmed for macOS) — zero extra build/fetch step, consistent with pellicle's
    "lean on Apple/Swift-native" mandate and its avoidance of third-party build systems.
    Given WasmKit's interpreter-only execution and undocumented interruption/fuel support,
    pellicle should design its own cooperative interruption points into the host-call
    boundary (WASI imports) rather than assume WasmKit gives free preemption — every
    host-import function the extension can call should itself check a deadline and trap
    cleanly, which sidesteps needing wasmtime's epoch mechanism.
  - **Escape hatch: wasmtime C API**, reserved for if/when a plugin genuinely needs
    JIT-class Wasm performance or wasmtime's epoch-interruption guarantee; bind it via a
    thin C shim module map. Not the default, given its non-Swift-native dependency and the
    component model's `-dev` maturity.
  - **API shape**: define pellicle's own narrow WIT-like interface (can literally start as
    a small set of `extern "C"`-shaped host functions passed into WasmKit's import table,
    Reticle-module-abi-style: opaque handles, no raw pointers into buffer internals,
    `size`-prefixed capability struct for version-skew detection) rather than depending on
    wasmtime's not-yet-settled component model. Capability surface should look like Zed's:
    register a language, contribute a theme, contribute a completion/formatter provider,
    read (not arbitrarily write) buffer text via a copy-out call — explicitly **no**
    filesystem/network/process-spawn access from this tier (that's what Tier 3 is for).
  - For a UI-bearing sandboxed extension (e.g. a rendered side panel), use
    **ExtensionKit/ExtensionFoundation** instead of raw Wasm — real OS process isolation
    plus a supported `EXHostViewController` UI-embedding story, at the cost of packaging
    the extension as a separate signed executable target. This is the right tool
    specifically when the extension needs to draw its own UI; Wasm is right when it's pure
    computation feeding back into pellicle's own renderer.

**Tier 3 — out-of-process services via LSP/DAP/JSON-RPC or XPC.**
For anything that needs to be a real, capable program — language servers (already the plan
per the brief: verible/slang/clangd/pyright/sourcekit-lsp), debuggers (DAP), linters,
formatters, or a plugin the owner writes as an arbitrary external script/binary:
  - Standardize on JSON-RPC-over-stdio (LSP/DAP shape) as the default IPC, since it's
    already required for language servers and gives pellicle a single client
    implementation to maintain, matching Neovim's "remote plugin" philosophy of
    language-agnostic RPC rather than a bespoke ABI per plugin language.
  - Use **XPC/`NSXPCConnection`** instead when the plugin is itself Swift/Obj-C code
    shipped as a helper tool bundled with pellicle (not a arbitrary external binary the
    user points at) — gives typed `NSXPCInterface` calls, independent crash/interruption
    handling, and a natural sandboxing boundary for the helper process, without inventing a
    wire protocol.
  - Crash containment is trivial here (separate OS process by construction); hot reload is
    "restart the process," same as VS Code's extension-host reload and Neovim's RPC-client
    restart; capability surface is unbounded (a Tier 3 plugin can run a shell, hit the
    network, spawn children) which is exactly why it's the *most* isolated tier rather than
    the least — the process boundary is what makes broad capability safe.

**Cross-tier principles that keep plugins off the UI thread (applies to all three tiers):**
1. The redisplay/rendering path must be able to proceed on stale-but-valid state; no tier's
   plugin call should be awaited synchronously inside a frame's render pass.
2. Every cross-tier call (Elisp→Wasm, Elisp→XPC, host→LSP) is async/callback-based from the
   Elisp scheduler's perspective — Tier 1 Elisp itself may block *itself* (accepted, same
   trade-off real Emacs makes), but must never block the Swift-side renderer/event loop.
3. Give the user an Emacs-style visible "extension X is slow" signal (Tier 1: wall-clock
   logging as above; Tier 2/3: since they're already async, a stalled call just shows as a
   pending/loading UI state with a cancel affordance, never a frozen window).
4. Version-gate every tier explicitly at load time (Elisp: `require`/feature version
   checks by convention, same as ELPA; Tier 2: the `size`-prefixed capability struct plus a
   manifest schema version, Zed-style; Tier 3: LSP's own capability-negotiation handshake,
   which already solves this problem for that tier).

## 10. Unverified / could not confirm this session

- JetBrains Fleet's frontend/backend split architecture, its blog posts, and
  help.jetbrains.com's Fleet architecture page (both attempted URLs 404'd).
- Whether classic IntelliJ plugins run strictly in the IDE's own JVM process and the exact
  crash/hang containment story (medium confidence from prior knowledge only; the specific
  extension-points doc page fetched explicitly did not cover this).
- Zed's actual use of "wasmtime" by name as the embedding runtime, its WIT file contents,
  fuel/epoch usage, and hot-reload behavior inside `extension_host` — GitHub directory
  listings and zed.dev doc pages returned only navigational content, not source/body text,
  to WebFetch this session.
- The WWDC22 "Meet ExtensionKit" session transcript — the guessed session URL
  (wwdc2022/10142) resolved to an unrelated session ("Efficiency awaits: Background tasks
  in SwiftUI"); the correct session ID was not found within budget.
- `AppExtensionScene`'s exact API and entitlement requirements (404).
- ExtensionKit's "no App Store requirement" / "App Sandbox mandatory" claims — plausible
  and consistent with public knowledge, but the fetched Apple Developer Documentation page
  likely returned a JS-rendered-shell-derived summary rather than verbatim page text; treat
  as medium confidence pending a cleaner source.
- wasm3 and WAMR were not fetched at all this session (budget prioritized WasmKit/wasmtime
  as the two candidates most relevant to a Swift host); any claims about them above are
  explicitly flagged low-confidence/unverified.
- wasmtime `ResourceLimiter`/memory-limit API specifics, and wasm module hot-reload
  patterns — not covered by any page actually fetched.
- VS Code extension-host crash-recovery behavior and its exact IPC transport — the fetched
  page discussed the local/remote/web split but not crash semantics.
