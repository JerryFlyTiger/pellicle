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
- **LSP**: probe the real server before scoping any LSP work, against the *Verilog* servers
  first. Declared capabilities lie: verible declares no hover and answers it; declares
  references and answers them incompletely; its rename can corrupt code. A repro that holds
  on rust-analyzer is not a reason to do it. **The prober is not here yet**:
  `~/My_Projects/reticle/dev/lsp-probe.py` is the one to port, in the first milestone that
  needs it (M10).
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

Toolchain: Xcode 26.6, Swift 6.3, SwiftPM only (no `.xcodeproj`). No script here invokes
`xcodebuild`; the one Xcode tool used is `actool`, which `dev/make-app-bundle.sh` calls to
compile the icon. Tests use Swift Testing.

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
no gain); `final` classes on hot paths; no force-unwrap or `try!` in product code (tests
may); C shims live only in `Sources/CPlatform`, wrapped by `Sources/Platform`, with a
header comment saying why Swift could not do it; anything holding
a resource has an explicit `close()`, never an `isolated deinit`; long chains are torn down
iteratively (the 1M-node recursive-release segfault is a measured fact on this machine);
every timer has a tolerance; nothing polls.

**Cross-module optimisation.** The package builds with **no** `-package-cmo`, no
`-enable-library-evolution` and no `unsafeFlags`; default access is `package`, which is
visibility only. A call a benchmark shows is hot across a module boundary is promoted
deliberately in the source: **the containing type becomes `public`, the hot members get
`@inlinable`, and anything an inlinable body touches gets `@usableFromInline`.** Promoting
the member alone does nothing — on Swift 6.3.3 `@inlinable` has no effect on a member of a
`package` type. Never rely on a plain `public` function being inlined; that is an
unannotated heuristic with a size threshold. `dev/check-inlining.sh` is the standing
regression test: it asserts from one stock release build that the promoted symbols are
absent from the caller's object file and that the cold controls are still there. Measured
basis in `PLAN.md` 4.2 and 4.16; the numbers say this reaches the same peak as library
evolution plus package CMO and has no cliff when the optimiser declines.

**The shipped Elisp is clean-room.** GNU's `subr.el`/`simple.el` are GPLv3: run them as an
oracle with `emacs -Q --batch`, quote their output in tests, never copy or paraphrase their
source into `lisp/`. The licence of a Developer-ID app depends on this.

**Third-party code.** The default is none: SQLite comes from the system, tree-sitter and
grammars are vendored C sources compiled as SwiftPM C targets, ripgrep and git are
subprocesses. Adding a SwiftPM dependency is a milestone decision recorded in `PLAN.md`
with its license; before the first `swift build` that fetches it, read its `Package.swift`
and any build plugins, because a build runs that code with the user's full permissions.

**GUI verification.** `dev/make-app-bundle.sh` then `dev/gui-shot.sh FILE OUT.png` for a
frame at startup; it refuses to run against a binary older than the sources, so build first.
For anything that changes while running there is no tool here yet: port
`~/My_Projects/reticle/dev/gui-drive.sh` (a throwaway `HOME`, an Elisp driver as init file,
pixel diffs between frames) in the first milestone whose done-condition needs the GUI
watched while it runs — M6's "chords still reach the command loop while an IME is
composing" and M7's "the which-key HUD shows after a prefix key" are both that shape. Keystroke
automation from an agent session did not work for Reticle (three attempts); drive the GUI
from Elisp through the editor's own idle hooks instead.

**Performance numbers** an agent measured are a sanity check only. Authoritative before/after
comparisons are re-measured by the main conversation on this machine against a controlled
baseline (`git worktree` of the old commit). Energy and latency claims use the release
protocol in `PLAN.md` section 4.14 (`powermetrics`, `xctrace`, soak).

Document every known gap (file header plus the "not in v1" section of `PLAN.md`). Mutation-
test important fixes; where a defence cannot be observed by a test, say so in the test
comments instead of pretending. **There is no runner here yet** — mutations are done by
hand, with a file backup, a targeted edit and `touch`, which is what M0 did.
`~/My_Projects/reticle/dev/mutate.py` is the one to port, and it is Rust-specific enough
that porting is a real job rather than a copy.

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
7. **Trailing re-review, repeated until the trailing diff is empty.** Nothing reaches a
   commit without a cold read — there is no batch size, no "it was only tests" and no
   round limit that exempts one.
   - **The anchor is the git index, not your memory.** Immediately before handing a diff
     to a reviewer, `git add -A`. The index then holds exactly the state that round read,
     the next round's batch is exactly `git diff`, and both survive a session dying
     mid-milestone (`git commit` moves `HEAD`, not the index or the working tree, so it
     does not disturb the anchor either). Do not rely on a scratch file: the scratch
     directory is per-session, so an interrupted milestone would lose the only record of
     where the last review stopped. The one way to break this silently is to `git add`
     for some unrelated reason while a round is pending — that moves files into
     "already read" with nothing to detect it. While a round is out, stage nothing.
   - If that diff is non-empty, hand it — only it, never the whole milestone — to a fresh
     reviewer, saying which batch it is and what earlier rounds covered. If the batch
     touched anything that compiles or runs — `Sources/`, `Tests/`, `lisp/`, `dev/` —
     rerun step 6 first: a reviewer reading code that does not build wastes the round, and
     a test file is code.
   - Acting on the findings produces a new batch, reviewed the same way. **The loop
     terminates because the variable is *changes made*, not *findings reported*.** A round
     whose findings you record rather than act on ends it, and declining is a normal
     outcome, not a failure: findings you decline go into the milestone record with the
     reason. Say so in the task spec too — a reviewer told that "nothing to change" is the
     thing that ends the loop will not manufacture a finding to look useful.
   - **The base case, without which this rule cannot terminate.** Writing declined findings
     into the record is itself an edit, so a literal reading would demand yet another round
     for it, forever. It does not get one: **the record entry that transcribes a round's
     declined findings is the loop's terminator, not a new batch.** It is allowed to say
     only what that reviewer wrote and why you declined it; the moment it makes any new
     claim about the code, it is a batch again and goes back through.
   - Prose findings about the milestone record itself are the usual place this runs away.
     Fix an incorrect *fact*; record a disagreement about *wording* and stop.
   - **Do not proceed to step 8 while an unreviewed change exists.**<br>2026-09-06 (M0):
     the old rule capped this at one round and told you to record the remainder as unread.
     Four fixes then shipped uninspected, one of them a new body-length guard in
     `dev/check-inlining.sh` — and that guard's first version was itself wrong (it averaged
     the two probe bodies, so a mutation shortening only the hot one survived), caught only
     because the main conversation happened to run a mutation against it, by no review. A
     cap that exempts the last batch exempts exactly the code written in a hurry at the
     end. Two further rounds, on batches of 46 and then 12 lines, each still found
     something — including a wrong attribution in this very paragraph, which originally
     blamed `dev/gate.sh` for a change that round 2 had in fact already read.
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
- **Do not run a mutation pass yourself**; self-check with a file backup, a targeted edit
  and `touch`.
- **"Flaky" requires evidence**: no "environmental noise" without an observation that
  distinguishes it; rerun a dozen times first.
- **Wrap-up**: `git status` converged to the original file set, no scratch files left.

## Token throttling

Open one module at a time; verify with `swift build`/`swift test --filter` as soon as you
finish writing rather than re-reading. Dispatch Explore for lookups. Pipe long output to a
file and grep it; never truncate output you are testing for absence. Run `/clear` between
milestones and continue from the latest `PLAN.md` records plus this file.
