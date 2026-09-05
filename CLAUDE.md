# swiftemacs

An Emacs-style editor for macOS in Swift: a native AppKit shell, a Metal text canvas, a
persistent-rope text model, a homegrown Emacs Lisp engine (tagged values, own GC, bytecode
VM), tree-sitter and LSP language intelligence, a built-in terminal, org-mode, git, and a
three-tier extension system. Design decisions and milestone records are in `PLAN.md` (long;
**look up the section you need, do not read it whole**). Reticle (`~/My_Projects/reticle`,
read-only) is the predecessor whose designs this project ports where they were proven.

**Positioning: a multi-language editor with complete org-mode support** (the owner's words,
2026-09-05), not Reticle in Swift. Feature priority: Verilog/SystemVerilog first as the
proving-ground language, the other target languages (Swift, Python, Perl, Tcl/Tk, C/C++)
first-class rather than afterthoughts, org-mode built to GNU org's full feature level
including its GTD workflow, then visual quality, performance, energy and stability. The
question to ask before starting anything: *is there a known gap in Verilog/SystemVerilog
support, then in org-mode?* If yes, that is the work. Native macOS quality, the terminal, extensibility and long-session stability are
hard constraints on every milestone, not phases. Decisions of the "which approach" kind
(the owner, 2026-09-05: "black cat or white cat, whichever catches mice") are made in the
main conversation on evidence and recorded in `PLAN.md`; they are not put to the owner.

**The target user is an industry RTL engineer**, not this project's author. Judge a feature
against real RTL practice (parameterised modules are routine, module names are numerous and
long, instantiations with 40+ ports are common). Reticle's `demo/rtl/` is the test corpus for
Verilog work; do not fabricate more until it runs out.

## Three oracles, and the rule they share

Write no specification from memory. Each kind of claim has an oracle, and the spec quotes
the oracle's output so the next reader can check it:

- **GNU parity**: GNU Emacs 30.2 is at `/opt/homebrew/bin/emacs`. `emacs -Q --batch --eval
  '(progn ...)'` answers "what does GNU do here" in one command. Reticle M110 built a
  data-corrupting `kill-whole-line` from a spec written from memory; a cold reviewer caught it
  by running the real thing. Conformance tests carry the recorded oracle output.
- **LSP**: probe the real server with `dev/lsp-probe.py` (ported from Reticle) before scoping
  any LSP work, against the *Verilog* servers first. Declared capabilities lie: verible
  declares no hover and answers it; declares references and answers them incompletely;
  its rename can corrupt code. A repro that holds on rust-analyzer is not a reason to do it.
- **Pixels**: every claim about what the GUI looks like is settled by a golden image from the
  canvas's headless path or a screenshot of the real window (`dev/gui-shot.sh`), never by
  reading code. Reticle's eyeballing was wrong twice, and three converging code-level
  arguments were all correct while the pixels still disagreed.

Candidate lists, "known unfixed" notes and research leads are **hypotheses, not specs**.
Reproduce the symptom before writing a spec; ask both "does this defect exist" and "does
fixing it serve Verilog". Reticle's history shows the thing worth doing was usually found
incidentally by reconnaissance, not on any list, so reconnaissance tasks must say "list
**all** X, not just the ones the entry names" and "say explicitly when the entry does not
match the code".

## Build and verification

Toolchain: Xcode 26.6, Swift 6.3, SwiftPM only (no `.xcodeproj`); `xcodebuild`/`actool` are
used only by `dev/make-app-bundle.sh` for the icon and bundle. Tests use Swift Testing.

**Definition of done (all required):**

```sh
dev/gate.sh    # = swift format lint --strict --recursive Sources Tests
               #   && swift build -c debug && swift build -c release
               #   && swift test --parallel 2>&1 | tee .build/test.log
```

Read the result from the log file, never from `$?` after a pipe (the exit code of `tee` is
always 0). Never truncate output when the finding is whether a line is present at all.
The gate is cheap: run it, do not plan around it.

Swift conventions: Swift 6 language mode with strict concurrency; no `-Ounchecked` or
`-enforce-exclusivity=unchecked` project-wide (Apple advises against it and the spike showed
no gain); `package` access with `@inlinable package` across modules, `final` classes on hot
paths; no force-unwrap or `try!` in product code (tests may); C shims live only in
`Sources/Platform` with a header comment saying why Swift could not do it; anything holding
a resource has an explicit `close()`, never an `isolated deinit`; long chains are torn down
iteratively (the 1M-node recursive-release segfault is a measured fact on this machine);
every timer has a tolerance; nothing polls.

**The shipped Elisp is clean-room.** GNU's `subr.el`/`simple.el` are GPLv3: run them as an
oracle with `emacs -Q --batch`, quote their output in tests, never copy or paraphrase their
source into `lisp/`. The licence of a Developer-ID app depends on this.

**Third-party code.** The default is none: SQLite comes from the system, tree-sitter and
grammars are vendored C sources compiled as SwiftPM C targets, ripgrep and git are
subprocesses. Adding a SwiftPM dependency is a milestone decision recorded in `PLAN.md`
with its license; before the first `swift build` that fetches it, read its `Package.swift`
and any build plugins, because a build runs that code with the user's full permissions.

**GUI verification.** `dev/make-app-bundle.sh` then `dev/gui-shot.sh FILE OUT.png` for a
frame at startup; `dev/gui-drive.sh DRIVER.el FILE OUT-DIR [SECONDS...]` for anything that
changes while running (a throwaway `HOME`, the driver as init file, pixel diffs between
frames). Both refuse to run against a binary older than the sources; build first. Keystroke
automation from an agent session did not work for Reticle (three attempts); drive the GUI
from Elisp through the editor's own idle hooks instead.

**Performance numbers** an agent measured are a sanity check only. Authoritative before/after
comparisons are re-measured by the main conversation on this machine against a controlled
baseline (`git worktree` of the old commit). Energy and latency claims use the release
protocol in `PLAN.md` section 4.14 (`powermetrics`, `xctrace`, soak).

Document every known gap (file header plus the "not in v1" section of `PLAN.md`). Mutation-
test important fixes with `dev/mutate.py`; where a defence cannot be observed by a test,
say so in the test comments instead of pretending.

## Wayfinding

Module responsibilities and dependency direction are in `PLAN.md` section 4.2 and in each
target's top-level doc comment. Two things the code will not tell you:

- **Modes and commands have no Swift type.** They are Elisp values dispatched through
  keymaps; to find an interactive command, search its registered name under
  `Sources/Lisp/Builtins/` and `lisp/`, not for a struct.
- **The UI actor never touches a buffer.** It renders the last `DisplaySnapshot` (viewport-
  independent; visual lines are derived on the UI side) and forwards input to the Elisp actor. Code that reaches from `Canvas` or `Chrome` into `Editor` state
  is wrong by construction, however convenient.

## Testing conventions

- Swift Testing suites live in `Tests/<Module>Tests/`, one file per feature
  (`<feature>Tests.swift`); performance tests get `<feature>PerfTests.swift` and are tagged
  so the default run skips them. Put new tests into the existing file for the feature.
- Oracle-backed conformance tests quote the `emacs -Q --batch` command and its output in a
  comment above the expectation.
- Golden images live in `Tests/CanvasTests/Golden/`; regenerate only with a stated reason in
  the commit message, and never in the same commit as the change they protect (capture the
  golden from the pre-change commit, as Reticle M87 stage 1a did).
- Races are verified with a filtered run over several rounds, not only the full suite: the
  same test can be green in the full run and red when run alone (Reticle M84: 12/12 vs 20
  failures in 30).

## Milestone execution loop

One milestone at a time. Eight steps, each traceable to a Reticle incident:

1. **Reconnaissance first**: parallel read-only agents produce `file:line`-anchored maps.
   Overlap them with whatever else is running; do not read files piecemeal in the main
   conversation (they get re-billed every turn).
2. **Spec**: anchors plus decisions, a test list, mutation focus points, oracle quotes. For
   architecture-level changes, an architect compares designs first.
3. **Implementer** with the fixed clauses below.
4. **Reviewer**: cold, independent, tries to refute; reports every finding with confidence;
   produces the mutation checklist. Read-only; use `isolation: "worktree"` if it must run
   experiments.
5. **Fix round**: reproduce first. Mutations are designed by the reviewer and executed by
   the main conversation (the implementer never verifies its own fix); revert via file backup
   plus a targeted edit and bump the mtime, never `git checkout --`.
6. **Main-conversation gate**: rerun `dev/gate.sh` yourself; do not trust a subagent's
   numbers.
7. **Trailing re-review** if product code changed after step 4: give the reviewer only the
   trailing diff and say which batches nobody has read. One round, no recursion; if the
   trailing changes were test-only, record that instead.
8. **Two commits**: `M<NN>: <summary>` and `PLAN.md: M<NN> record`.

## Delegation discipline

- Delegation criteria and model selection are in the global `~/.claude/CLAUDE.md`.
- **At most four background agents at once, sonnet by default for research and surveying.**
  This plan's research phase hit the session usage limit twice with eight concurrent
  high-effort agents and lost all of their work; the third attempt, throttled, finished.
  Research and long tasks write their output incrementally to disk so a cut-off leaves a
  usable partial.
- Commit authority belongs to the main conversation; the PreToolUse hook
  `~/.claude/hooks/subagent-git-guard.py` (enabled in the global `~/.claude/settings.json`)
  blocks agent git writes and lets the main thread through.
- No agent touches files the mutation runner is mutating; confirm nothing is running before
  a mutation pass.
- On an API interruption, check `git status` and the diff size before deciding to resume
  the agent (`SendMessage`) or audit with a fresh one; never redo blindly and never trust a
  "completed" report.

## Fixed clauses for task specs

Written in the second person to the agent, every time:

- **Scope**: the exact files that may be touched.
- **No git writes**: `commit`, `push`, `reset`, `checkout --`, `restore`, `clean` forbidden.
- **No sub-delegation**: do not spawn agents; stop and report if you cannot finish.
- **Foreground execution**: no `nohup`/`&` followed by waiting for a notification that will
  never come; split work over ten minutes into steps.
- **Effort budget and stop-loss**: "if N rounds of the test loop are not green, stop and
  report the state and what remains"; "if more than N files need changes, stop and report
  the scope change".
- **Do not run the full gate or report pass/fail**: run only the targeted tests you need,
  attach the exact command line and the last lines of raw output, state whether you ran the
  whole suite or a filter (the two can disagree), and never write "verified", "all green"
  or "confirmed".
- **Touching `lisp/*.el` requires the Elisp hygiene test** (`swift test --filter
  LispHygiene`): it catches an unescaped quote inside a docstring, which the reader accepts
  silently and which fails later with an error naming a symbol that does not exist.
- **Do not run `dev/mutate.py` yourself**; self-check with a file backup, a targeted edit and
  `touch`.
- **"Flaky" requires evidence**: no "environmental noise" without an observation that
  distinguishes it; rerun a dozen times first.
- **Wrap-up**: `git status` converged to the original file set, no scratch files left.

## Token throttling

Open one module at a time; verify with `swift build`/`swift test --filter` as soon as you
finish writing rather than re-reading. Dispatch Explore for lookups. Pipe long output to a
file and grep it; never truncate output you are testing for absence. Run `/clear` between
milestones and continue from the latest `PLAN.md` records plus this file.
