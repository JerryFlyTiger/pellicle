# pellicle — planning context (read this first)

## What the owner asked for (translated from the owner's Traditional Chinese brief, 2026-09-05)

The editor is named **pellicle**. It must be written in **Swift**, carry a built-in
**Emacs Lisp interpreter**, and **solve every well-known pain point of GNU Emacs**. It targets
**macOS only** for now, and should lean heavily on **Apple's own frameworks**.

Wish list, verbatim in spirit:

1. Study the best editors/IDEs (including but not limited to VS Code, JetBrains IDEs, Zed,
   Doom Emacs) and world-class Emacs users' setups (Doom Emacs, Steve Purcell, ...). Also
   study the owner's previous project **Reticle** (an Emacs-like editor in Rust at
   `/Users/jerrychen/My_Projects/reticle`, 110 milestones, read-only reference).
2. Development priority order:
   a. **Killer coding features**, above all for **Verilog / SystemVerilog**; Swift, Python,
      Perl, Tcl/Tk, C/C++ must also be supported but rank second.
   b. **org-mode** support.
   c. **Extreme visual beauty, extreme performance, low power, reliability/stability**
      (it must NOT get slower, hotter, or crash the longer it runs).
3. Like GNU Emacs it must support many plugins/extensions. The name says Emacs but the look
   and the implementation may differ a lot — study how VS Code and JetBrains interact with
   extensions efficiently without hurting performance.
4. Use every expert technique for speed and power efficiency: GPU-accelerated rendering,
   JIT, and so on.
5. Study how top IDEs/editors render, and reach an extremely beautiful GUI.
6. **No CLI/TUI version.** The app itself should be a terminal like **iTerm2**: it can run a
   shell and be used exactly like a terminal, and it can also run shell commands directly the
   way GNU Emacs does (M-!, shell-command, compile, ...).
7. Find and implement the killer features of world-class Emacs setups.

## Environment (verified 2026-09-05 on the owner's machine)

- macOS 26.6.2 (Darwin 25.6), Apple M4, 24 GB, 4K display, Metal 4.
- Xcode 26.6, Swift 6.3.3 (swiftlang-6.3.3.1.3), target arm64-apple-macosx26.0.
- Installed: GNU Emacs 30.2 (/opt/homebrew/bin/emacs), iTerm2, VS Code, Xcode.
- Language servers present: verible-verilog-ls, verible-verilog-format, slang-server,
  rust-analyzer, clangd, pyright-langserver, sourcekit-lsp. iverilog present. verilator,
  node, swiftlint, swiftformat, tree-sitter CLI absent.

## Reticle in one paragraph (the owner's previous editor; borrow what worked, fix what did not)

Rust, ~102k lines Rust + 22k lines Elisp. Homegrown Elisp (tree-walker + bytecode VM +
Cranelift JIT for a pure-integer subset; ~8x and ~575x on tight loops, 1.0x on fib), gap
buffer, character-grid redisplay shared by a TUI (crossterm) and a GUI (egui), tree-sitter
highlighting for 9 languages, LSP client (transport in Rust, semantics in Elisp), evil layer
on by default, org-mode file-compatible, Verilog AUTO system (AUTOINST/AUTOWIRE/AUTOARG/
AUTO_TEMPLATE), cross-file module jump, verible.filelist, port completion, indent-width
detection, background project search with editable results, TRAMP-style SSH editing, C ABI
dynamic modules, three themes, bundled fonts. Known limitations that the owner presumably
wants gone in pellicle: fixed character-grid GUI (no proportional/sub-cell layout, no
smooth scrolling, no minimap, no tab bar), synchronous remote editing, minibuffer keys not
rebindable from Elisp, no define-derived-mode / syntax tables, no runtime grammar loading,
no emacs-module ABI, Rc-based GC that can leak cycles, egui with no headless screenshot
path. Its CLAUDE.md (`/Users/jerrychen/My_Projects/reticle/CLAUDE.md`) records hard-won
process rules; its README lists features and limitations.

## Ground rules for every agent in this planning run

- This is **planning only**. Do not create any file under
  `/Users/jerrychen/My_Projects/swiftemacs/`. Write only under the scratchpad directory
  given in your task. Do not modify anything under `/Users/jerrychen/My_Projects/reticle/`.
- Do not run `swift build`, `swift package resolve`, `xcodebuild`, `brew install`, `npm`,
  `cargo`, or anything that fetches or compiles third-party code.
- Prefer primary sources (Apple developer docs, project source trees, official docs,
  talks by the authors) over blog summaries; cite URLs. Mark every claim's confidence.
- Say explicitly what you could not verify. A confident wrong claim about an Apple API is
  the most expensive kind of error this plan can contain.
