<p align="center">
  <img src="assets/icon/pellicle-256.png" width="128" alt="">
</p>

<h1 align="center">pellicle</h1>

<p align="center">
An Emacs-style editor for macOS, written in Swift.
</p>

---

A native AppKit shell over a Metal text canvas, a persistent-rope text model, a homegrown
Emacs Lisp engine with tagged values, its own garbage collector and a bytecode VM,
tree-sitter and LSP language intelligence, a built-in terminal, org-mode, git, and a
three-tier extension system.

It is aimed at one reader in particular: an **industry RTL engineer**. Verilog and
SystemVerilog come first and are the proving ground; Swift, Python, Perl, Tcl/Tk and C/C++
are first-class rather than afterthoughts; org-mode is built out to GNU org's full feature
level, GTD workflow included. Native macOS quality, the terminal, extensibility and
long-session stability are constraints on every milestone rather than phases of their own.

## Status

**M0 of 33 done; M1 under way.** There is no editor yet — nothing here opens a file or draws
a character. What exists is the floor everything else is built on, plus the text model that
sits on it, and both are finished and verified.

**M0, the repository and the gate** (2026-09-06):

- a SwiftPM package with the module layout the design calls for — twelve Swift modules,
  `Platform`, `Text`, `Lisp`, `Editor`, `Canvas`, `Terminal`, `Lang`, `Org`, `Git`,
  `Extensions`, `Chrome` and `App`, over a small C shim in `CPlatform`. `Platform` and
  `App` carry the infrastructure below, about 440 lines between them once blanks and
  comments are set aside (684 by `wc -l`); `Lisp` and
  `Editor` carry a placeholder plus the probes `dev/check-inlining.sh` measures; the other
  seven are placeholders of three code lines each, waiting for their milestone;
- `dev/gate.sh`, the definition of done: format lint, a debug build, a release build, and
  the test suite;
- a signed, hardened-runtime `.app` whose launch-time self-test proves the two entitlements
  the Lisp engine's future JIT will need — `allow-jit`, so `mmap(..., MAP_JIT, ...)`
  succeeds, and `disable-library-validation`, so the ad-hoc-signed `SelfTestProbe` dylib
  bundled beside it can be `dlopen`ed;
- `MXMetricManager`, `os_signpost` handles and a main-actor watchdog wired in from the
  first commit rather than retrofitted;
- `dev/check-inlining.sh`, a standing regression test for the cross-module inlining
  convention (measured: `-package-cmo` is silently dropped by this toolchain, so hot
  members are promoted deliberately in the source instead);
- the app icon: an Icon Composer package whose layer artwork `dev/gen-icon.py` generates.

**M1.1 and M1.1b, the rope** (2026-09-08) — `Text` is now 1,995 lines:

- a persistent B+-tree rope over UTF-8 chunks, with per-node summaries, O(1) `Sendable`
  snapshots and a structural invariant check, property-tested against a naive `[UInt8]` model
  over randomised operation sequences. `B = 6` is measured on this machine, not inherited;
- a path-copy edit path, and then a `Fragment`/`TreeBuilder` n-ary join that replaced the
  general path outright: one descent emitting per-level fragments and one bottom-up build,
  where the old code rebuilt nodes at every level of its descent. A single-scalar insert into
  1 MB costs **2.6 µs** on the fast path and **12.8 µs** through the general path, the latter
  down from 96.8 µs; `generalPathReplace` went from six cursor walks to two;
- 97 tests in 13 suites, green.

Running it opens an empty native window. Next up is M1.2 — byte, character, UTF-16 and line
conversions, a bottom-up bulk loader, and a lazy cursor.

## Building

Requires **macOS 26**, **Xcode 26.6**, **Swift 6.3**. SwiftPM only — there is no
`.xcodeproj`, and no script here invokes `xcodebuild`. The one Xcode tool used is `actool`,
which `dev/make-app-bundle.sh` calls to compile the icon.

```sh
dev/gate.sh              # lint, debug build, release build, tests — the definition of done
dev/make-app-bundle.sh   # .build/pellicle.app, ad-hoc signed, hardened runtime
open .build/pellicle.app
```

Every claim about what the GUI looks like is settled by a rendered image, never by reading
code — `dev/gui-shot.sh FILE OUT.png` captures one frame of the real window at startup, and
refuses to run against a binary older than the sources.

## Design notes

- **The Elisp is clean-room.** GNU's `subr.el` and `simple.el` are GPLv3. They are run as
  an oracle with `emacs -Q --batch` and their output is quoted in tests; none of their
  source is copied or paraphrased.
- **Three oracles, one rule: no specification is written from memory.** GNU parity is
  settled by running GNU Emacs 30.2, LSP behaviour by probing the real language server
  (declared capabilities lie), and anything visual by pixels.
- **Third-party code: none by default.** SQLite comes from the system; tree-sitter and its
  grammars are vendored C compiled as SwiftPM C targets; ripgrep and git are subprocesses.
  Adding a SwiftPM dependency is a milestone decision, recorded with its licence.
- **Swift 6 language mode, strict concurrency.** No `-Ounchecked`, no `unsafeFlags`, no
  force-unwraps in product code. Anything holding a resource has an explicit `close()`;
  long chains are torn down iteratively; every timer has a tolerance; nothing polls.

## Repository

| Path | |
|---|---|
| `PLAN.md` | The design, the milestones, and a record of each one as it lands. Long; look up the section you need. |
| `CLAUDE.md` | How work on this repository is actually carried out. |
| `doc/research/` | The research the plan was built on. |
| `dev/` | Gate, CI, app bundle, GUI capture, inlining check, icon generator, spikes. |
| `Sources/`, `Tests/` | The modules and their suites. |
| `assets/icon/` | The Icon Composer package, a flat SVG, and the PNG at the top of this file. |

[Reticle](https://github.com/JerryFlyTiger/reticle), an Emacs-class editor for RTL work
written in Rust, is this project's predecessor; designs that were proven there are ported
here rather than reinvented.

## Licence

**Source-available, not open source**: the [Functional Source License 1.1 with an Apache
2.0 future grant](https://fsl.software/) (`FSL-1.1-ALv2`), the same licence Reticle uses.
Use it for any purpose that is not a competing commercial product or service; two years
after each version is published, that version is additionally available under Apache 2.0.
Full text in `LICENSE.md`.

The clean-room rule on the shipped Elisp is what left this choice open. GNU's `subr.el`
and `simple.el` are GPLv3, and GPLv3 is copyleft: anything derived from them would have had
to ship as GPLv3 itself. That rule predates this licence decision rather than following
from it. (The reverse direction is not a problem — the FSF lists Apache 2.0 as compatible
*with* GPLv3; it is GPLv2 that Apache 2.0 conflicts with.)
