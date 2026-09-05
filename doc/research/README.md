# Research corpus behind PLAN.md (2026-09-05)

Eighteen reports written by research agents during the planning run, plus the planning
context they were given. Each report marks the confidence of every claim and lists what it
could not verify; several were written while web search was unavailable and say so. They
are inputs to `PLAN.md`, not specifications: re-verify a claim against its primary source or
the relevant oracle before building on it.

| File | Topic |
|---|---|
| 00-planning-context.md | the owner's brief, environment, Reticle summary, ground rules |
| apple-text-rendering.md | Core Text + Metal atlas vs TextKit 2; display link; frame pacing |
| macos-ui-design.md | AppKit/SwiftUI shell, Liquid Glass, chrome, accessibility, distribution |
| swift-interpreter-perf.md | Swift 6.3 for a Lisp engine: representation, ARC, concurrency, GC |
| jit-on-macos.md | MAP_JIT mechanics, JIT options, why the VM comes first |
| elisp-engine-design.md | compatibility tiers, binding model, bytecode, async, builtins |
| buffer-data-structures.md | rope, anchors, interval tree, undo, huge files |
| treesitter-lsp-swift.md | tree-sitter and LSP/DAP from Swift, grammars, servers, licenses |
| emacs-pain-points.md | 22 GNU Emacs pain points, root causes, designs that fix them |
| emacs-killer-features.md | ranked packages, core mechanisms they need, week-one set |
| verilog-killer-features.md | RTL/DV engineer needs, server capability matrix, top-10 |
| org-mode.md | parser architecture, index, milestone order, deferrals |
| terminal-emulator.md | iTerm2/Ghostty/SwiftTerm, VT design, buffer-as-scrollback |
| perf-power.md | energy rules, stability practices, release measurement protocol |
| extension-architectures.md | VS Code/JetBrains/Neovim/Zed/Emacs; ExtensionKit, XPC, Wasm |
| git-and-navigation.md | Magit-level git via the CLI; search, fuzzy finding, indexing |
| run-debug-ai.md | DAP, compile/next-error, simulation, waveforms; ACP/MCP/AI policy |

`dev/spikes/` holds the feasibility spikes (sources and `RESULTS.md`) run on the owner's
machine the same day.
