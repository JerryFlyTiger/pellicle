# JIT compilation for an Elisp engine on macOS / Apple Silicon: feasibility and value

Topic key: `jit-on-macos` — planning research for swiftemacs, 2026-09-05.
Author: research agent (Fable 5.1). Environment facts were verified on the owner's machine
(macOS 26.6.2, Apple M4, Xcode 26.6 / Swift 6.3.3, macOS 26 SDK). Every claim carries a
confidence tag: **[verified]** = primary source read or reproduced locally; **[high]** =
primary source summarized by a tool; **[medium]** = secondary source or inference from
primary facts; **[low]** = plausible but not confirmed. Anything I could not confirm is
collected in §12, not asserted elsewhere.

---

## 1. Executive answer

**A native-code JIT is feasible on macOS/Apple Silicon and the platform mechanics are
well-documented and cheap, but for an editor's Elisp workload it is the wrong first,
second or third investment.** The evidence lines up from four independent directions:

1. **What Elisp in an editor actually does.** Profiles of slow Emacs sessions bottom out in
   `redisplay_internal → jit-lock-function → font-lock-fontify-region → (regex / tree-sitter
   / text-property calls)` and in garbage collection, not in Elisp arithmetic (§2). Those
   are calls *into* the runtime (buffer text, regex matcher, interval tree, GC). A JIT
   speeds up only the Elisp-to-Elisp glue between such calls.
2. **Reticle's own measurement** (§3): a Cranelift JIT gave ~575x on a pure-integer loop
   and **1.0x on recursive `fib`**, because the moment a function calls anything the cost
   is the calling convention and value boxing, not instruction dispatch. Both tiers gave
   1.0x on `fib`. The lesson is that the *calling convention and value representation* of
   the VM decide performance; the code generator is a second-order effect.
3. **Emacs native-comp** (§8): 2.3x–42x on micro-benchmarks (the paper's numbers), manual
   claims "2.5 to 5 times faster than byte-code", yet the maintainers themselves note that
   GC and the C redisplay engine cap what any Elisp execution engine can deliver, and the
   feature's user-visible reputation is dominated by background compile CPU, warnings
   buffers, eln-cache management, and on macOS by libgccjit packaging and a dyld crash.
4. **CPython's copy-and-patch JIT** (§7): after two years, in June 2026 it is at 4–12%
   geometric-mean over a specializing interpreter (12.6% on an M3 Pro), while the
   *interpreter* work (specialization, inline caches, superinstructions) delivered ~25% in
   3.11 alone and "nearly 50% in less than four years" without a JIT. Baseline JITs
   (V8 Sparkplug) buy 5–15% of main-thread time in browsing workloads; JSC's Baseline is
   ~2.3x over its interpreter per bytecode but the big wins come from DFG/FTL speculation,
   which is a multi-year, multi-engineer effort.

**Recommendation in one line:** design the bytecode VM so a baseline JIT *could* be bolted
on later (tagged-word values, contiguous VM stack, fixed-width bytecode with inline-cache
slots, Swift-native builtins with a C-ABI-shaped fast path), ship without a JIT, build an
editor-workload benchmark suite (font-lock a 20k-line SystemVerilog file, per-keystroke hook
chains, org parsing, text-property churn), and only revisit a hand-written ARM64 baseline
JIT if that suite shows ≥20% of wall time in bytecode dispatch after the VM work is done.
The one JIT that plausibly pays for itself in an editor is a **regex JIT** (WebKit's Yarr,
PCRE2's sljit both exist because regex matching dominates text workloads) — and even that
should come after a compiled-to-bytecode regex matcher is measured.

---

## 2. What an editor's Elisp workload actually spends time in

| Evidence | What it shows | Confidence |
|---|---|---|
| A user profile of a slow LSP go-to-definition in a 26k-line file: `redisplay_internal (C function) 5109 75%` with the chain `jit-lock-function → jit-lock-fontify-now → font-lock-fontify-region → tree-sitter-hl--highlight-region` ([ianyepan.github.io](https://ianyepan.github.io/posts/emacs-profiling/)) | Time is in fontification driven by redisplay, i.e. hooks + regex/parser + text properties | [high] |
| EXWM keymap load: "73% of the CPU time during the hangup was spent on garbage collection"; raising `gc-cons-threshold` from 800 KB to 100 MB cut a 10–20 s freeze to 2–3 s and halved startup ([elmord.org](https://elmord.org/blog/?entry=20190913-emacs-gc)) | Allocation/GC, not instruction execution, is a first-order cost | [high] |
| Emacs long-line pathology: "if the lines are long enough (just a couple thousand characters), Emacs will crawl to a halt while utilizing 100% CPU" because redisplay scans lines repeatedly ([200ok.ch](https://200ok.ch/posts/2020-09-29_comprehensive_guide_on_handling_long_lines_in_emacs.html)) | Redisplay/layout algorithms, in C, not Elisp | [medium] |
| emacs-devel 2023-09 design thread: display engine "optimized towards CPU-driven redisplay… will probably need a more thorough redesign" ([lists.gnu.org](https://lists.gnu.org/archive/html/emacs-devel/2023-09/msg00879.html)); search summary also surfaced the point that "no matter how fast you make your Elisp execution engine, the time taken by GC establishes a hard limit" | Maintainers' own view of where the ceiling is | [medium] — the GC sentence is from a search summary, not a page I read in full |
| Reticle's hook guardrails: `post-command-hook`/`post-self-insert-hook` run under a 50 ms `hook-time-budget` ([reticle PLAN.md ~L953-960](/Users/jerrychen/My_Projects/reticle/PLAN.md)) | The owner's previous project found *hooks* to be the keystroke-path risk, not arithmetic | [verified] |
| Emacs text properties live in an interval tree (`intervals.c`); every `get-text-property`, `next-single-property-change`, overlay lookup is a runtime call | Text-property-heavy Elisp (font-lock, org) is bound by the runtime data structure | [medium] |

Consequence for a JIT: in all of these, the Elisp function is a thin driver around
calls into the runtime — `re-search-forward`, `put-text-property`, `buffer-substring`,
`run-hooks`, `funcall` of a hook closure. A JIT compiles the driver, not the callee. The
only way a JIT helps such code is by making **calls** and **argument/return marshalling**
cheaper — which is precisely where Reticle's JIT was excluded (§3) and where a VM with a
good calling convention already wins.

---

## 3. Reticle's measured result and what it teaches

Source: `/Users/jerrychen/My_Projects/reticle` — `README.md` L44-66, `PLAN.md` L160-212,
L365-380, L513-520, L953, L6104-6110, `crates/elisp/src/jit.rs` (953 lines),
`dev/bench-tiers.el`. All **[verified]** by reading.

| Tier | Tight integer loop | Recursive `fib` |
|---|---|---|
| Tree-walking evaluator | baseline | baseline |
| Bytecode VM (`byte-compile`) | ~8x (8.01–8.20x over 8 runs) | **1.0x** |
| Cranelift JIT (`native-compile`) | ~575x (573–577x) | **1.0x** (not eligible; stays bytecode) |

Earlier internal measurement (PLAN.md L198-208): `loop-sum` over 20,000,000 iterations —
interpreter 9.96 s, bytecode 2.55 s, native 0.015 s (~660x / ~170x).

Design facts from `jit.rs`:

- Compiles from the **already-compiled bytecode chunk**, not the AST — reusing macro
  expansion, control-flow flattening and jump backpatching. Adds only a backend.
- Eligibility: functions that touch only their own locals, integer arithmetic and a
  whitelist `+ - * / % 1+ 1- < > <= >= = /=`; no free variables, no dynamic binding, no
  closures, no calls, no `Interpret` fallback instructions. Everything is a bare `i64`.
- Overflow / division by zero → native call reports failure and the caller **re-runs the
  whole call through the bytecode VM**. Safe only because eligible functions are pure.
- Comparison results may only feed a branch (`JumpIfNil`/`JumpIfNonNil`), `Dup` or `Pop`.
- Stack-machine → SSA conversion needed a pre-pass (`analyze_shapes`) to compute block
  parameters (phis) at merge points; the `(if (and (>= x lo) (<= x hi)) 1 0)` case broke
  the naive approach.
- Known limitation: native code cannot be interrupted (no back-edge checks).
- The `fib` row: "call overhead dominates" — byte-compiling buys nothing either.
- Later VM work (PLAN.md L365-380) added `Add2/Sub2/Mul2/...Car1/Cdr1/Eq2/Cons2`
  superinstructions with inlined Int×Int fast paths, peephole + constant folding, and
  tiered auto-compilation (64 calls → byte-compile, 1024 → native attempt). The JIT's
  analyzer had to be kept in sync with every new instruction — a maintenance tax noted
  at L1552.
- Widening the JIT to real code (calls, floats, `car`/`cdr`) was deferred because it
  requires (a) replacing "re-run the function" with in-place `arith-error` signalling and
  (b) operating on tagged `Value`s with reference counting — "native code will have to
  operate on tagged Values and keep…" (L515-520), i.e. the JIT would inherit exactly the
  costs that make `fib` 1.0x.

**Lessons for swiftemacs:**

1. The 575x number measures the *absence of value boxing and dispatch* on a loop with no
   calls. Real Elisp always calls. The VM's call path (`funcall`, arg passing, frame push,
   dynamic-binding save/restore, `&optional`/`&rest` handling) is where the time goes, and
   it is fixable in the VM.
2. Reticle's JIT could not be widened cheaply because its **value representation** (an
   `Rc`-based enum) and its **error model** (re-run) were not designed for native code.
   Whatever swiftemacs chooses for values and errors in stage 1 determines whether a JIT is
   ever possible; that decision is the JIT decision.
3. A JIT that can't be interrupted, can't be profiled and can't be stepped through is a
   support burden — Reticle documented all three.

---

## 4. Apple platform mechanics (verified on the owner's machine and against Apple docs)

### 4.1 The API surface

From the macOS 26 SDK header `usr/include/pthread/pthread.h` L586-727 **[verified]**:

| Symbol | Availability | Notes |
|---|---|---|
| `void pthread_jit_write_protect_np(int enabled)` | macOS 11.0; **unavailable** on iOS/tvOS/watchOS/driverkit | Toggles the calling thread between `rw-` and `r-x` views of all `MAP_JIT` pages |
| `int pthread_jit_write_protect_supported_np(void)` | macOS 11.0, iOS 17.4 | Returned `1` on the M4 |
| `int pthread_jit_write_with_callback_np(cb, ctx)` | macOS 11.4, iOS 17.4 | **`__SWIFT_UNAVAILABLE_MSG("This interface cannot be safely used from Swift")`** — must be called from a C/ObjC/C++ target |
| `PTHREAD_JIT_WRITE_ALLOW_CALLBACKS_NP(...)` | macro; C99/ObjC/C++ only | Emits a `static const` array in section `__DATA_CONST,__pth_jit_func`; "may be invoked only once per executable/library". Function-like macro → **not importable into Swift** (Swift imports only constant-like macros, [Apple: Using imported C macros in Swift](https://developer.apple.com/documentation/swift/using-imported-c-macros-in-swift)) |
| `void pthread_jit_write_freeze_callbacks_np(void)` | macOS 12.1 | Only meaningful with `com.apple.security.cs.jit-write-allowlist-freeze-late`; calling it without that entitlement "is an error" |
| `MAP_JIT` = `0x0800` (`sys/mman.h` L125) | — | Simple constant → imports into Swift as `MAP_JIT` (used in the probe) |
| `void sys_icache_invalidate(void *start, size_t len)` (`libkern/OSCacheControl.h` L58) | macOS 10.5 | **Not visible with `import Darwin`**; visible with `import Foundation` (typecheck error reproduced). A tiny C shim or module map is the clean fix. |

Header discussion text worth designing around **[verified]**:

- `pthread_jit_write_with_callback_np` "assumes that the MAP_JIT region has executable
  protection when called… invalid to call it recursively"; callbacks "must not perform any
  non-local transfer of control flow (e.g. throw an exception, longjmp(3))".
- Without the `com.apple.security.cs.jit-write-allowlist` entitlement the callback API
  "toggles protection… calls @callback… without validating that @callback is an allowed
  function" — so libraries can adopt it incrementally and the app adds the entitlement
  last. With the entitlement, `pthread_jit_write_protect_np` becomes **disallowed**.
- "Callbacks should assume an attacker can control the input… simplifying control flow and
  avoiding spills of sensitive registers"; on invalid input prefer `__builtin_trap()`.

### 4.2 Apple's guidance ([Porting just-in-time compilers to Apple silicon](https://developer.apple.com/documentation/apple-silicon/porting-just-in-time-compilers-to-apple-silicon)) **[high]**

- With Hardened Runtime, `mmap(MAP_JIT)` requires `com.apple.security.cs.allow-jit`;
  "If you don't have this entitlement, calls using that flag return an error."
- "When your app has the Hardened Runtime capability and the allow-jit entitlement, it can
  only create one memory region with the MAP_JIT flag set." (See §4.4 — my probe created
  two; treat the doc as the design constraint anyway: one big reservation.)
- "Apple silicon enables memory protection for all apps, regardless of whether they adopt
  the Hardened Runtime." (Per-thread W^X is always on; only the *entitlement* is
  hardened-runtime-specific.)
- Recommended flow: write inside an allow-listed callback → `sys_icache_invalidate` →
  execute. "On Apple silicon, the instruction caches aren't coherent with data caches."
- Adding `com.apple.security.cs.jit-write-allowlist` disables `pthread_jit_write_protect_np`.
- Allowlist "at most one" per executable/library; dynamic libraries need the
  `jit-write-allowlist-freeze-late` entitlement plus an explicit freeze before first write.

### 4.3 Hardware mechanism (why the toggle is cheap) **[medium]**

Sven Peter's reverse-engineering of M1 ([blog.svenpeter.dev](https://blog.svenpeter.dev/posts/m1_sprr_gxf/)):
`pthread_jit_write_protect_np` loads a kernel-provided 64-bit value from the commpage
(`0xfffffc110`/`0xfffffc118`) and writes it to the SPRR register `S3_6_C15_C1_5`, followed
by `isb`. A single register write flips **all** `MAP_JIT` pages of the current thread
between `r-x` and `rw-` — no page-table walk, no syscall. saagarjha's `fixjit.c` gist reads
`s3_4_c15_c2_7` and confirms new threads start **write-protected** by default
([gist](https://gist.github.com/saagarjha/d1ddd98537150e4a09520ed3ede54f5e)). CPython
measured "an overall 1.4% speed improvement" from replacing `mprotect` with the pthread
toggle ([python/cpython#126195](https://github.com/python/cpython/issues/126195)).

Security corollary (from the v8-dev thread and Apple text, [medium]): the permission is
per-thread, so a writer thread and an executor thread must not share the region in
opposite states; keep one compile thread or serialize writes.

### 4.4 Local experiments (own code, in the scratchpad) **[verified]**

Files: `scratchpad/jitprobe/jitprobe.swift`, `probe2.swift`, `jit.entitlements`.
Compiled with `swiftc -O` (no packages, no third-party code), signed ad-hoc.

| Configuration | `mmap(MAP_JIT)` | Result |
|---|---|---|
| Ad-hoc signed, no hardened runtime | ok (two 16 KB regions) | `mov x0,#42; ret` returned 42 |
| Ad-hoc + `--options runtime`, no entitlement | **fails, `errno=22 EINVAL`** (both regions) | — |
| Ad-hoc + `--options runtime` + `com.apple.security.cs.allow-jit` | ok (**two** regions succeeded) | returned 42 |

Micro-timings on the M4 (single run, `-O`, 1,000,000 iterations):

- `pthread_jit_write_protect_np(0); pthread_jit_write_protect_np(1)` pair: **~47.5 ns**
  (≈24 ns per toggle).
- `sys_icache_invalidate(p, 8)`: **~249 ns** per call — roughly 10x the toggle. Inline-cache
  patching that toggles+invalidates per site would cost ~300 ns each; batch patches.

Observations: (a) the failure mode without the entitlement is `EINVAL`, not `EPERM` — test
for `MAP_FAILED`, don't test errno; (b) two `MAP_JIT` regions were accepted under hardened
runtime + entitlement on macOS 26.6 with ad-hoc signing, contradicting the doc's "only one
region" sentence — I did **not** test with a Developer ID identity or the App Sandbox, so
design for a single reservation regardless; (c) `unsafeBitCast` to a
`@convention(c) () -> Int64` is a working way to call JIT code from Swift.

### 4.5 Entitlements, notarization, App Store

| Entitlement | Meaning | Confidence |
|---|---|---|
| `com.apple.security.cs.allow-jit` (Bool, macOS 10.7+) | "may create writable and executable memory using the MAP_JIT flag"; listed users: JavaScriptCore fast path, "certain Python frameworks", PCRE, proprietary macro languages ([Apple](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-jit)) | [high] |
| `com.apple.security.cs.allow-unsigned-executable-memory` | "writable and executable memory without the restrictions imposed by using the MAP_JIT flag"; Apple: "exposes your app to common vulnerabilities in memory-unsafe code languages" — for legacy `NSCreateObjectFileImageFromMemory`, DVDPlayback ([Apple](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-unsigned-executable-memory)). **Do not use.** | [high] |
| `com.apple.security.cs.disable-executable-page-protection` | "extreme entitlement that removes a fundamental security protection"; includes allow-unsigned-executable-memory ([Apple](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-executable-page-protection)). **Never.** | [high] |
| `com.apple.security.cs.jit-write-allowlist` (+ `-freeze-late`) | Enforces the callback allowlist; disables the plain toggle ([Apple porting guide](https://developer.apple.com/documentation/apple-silicon/porting-just-in-time-compilers-to-apple-silicon)) | [high] |

- Notarization **requires** Hardened Runtime ("The executable does not have the hardened
  runtime enabled" is a rejection) and a secure timestamp; the only entitlement the
  notarization-issues page rejects is `get-task-allow` ([Apple: Resolving common
  notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)). `allow-jit` is a normal Hardened Runtime exception and is what Chrome/Electron/JSC-hosting apps ship with. [high for the requirement, medium for "allow-jit is accepted" — inferred from the entitlement being an official runtime exception and from Electron/electron-builder documentation, not from a page saying "notarization accepts allow-jit"]
- Mac App Store: electron-builder's notarization docs state MAS builds embedding V8 need
  `allow-jit` together with the sandbox ([electron.build](https://www.electron.build/docs/features/code-signing/notarization/)). [medium] There is an open Apple Forums thread (2026) reporting a deterministic `EXC_BREAKPOINT` on **macOS 26 + App Sandbox + arm64** when V8 flips pages with `mprotect`, working on macOS 15.x and on macOS 26 without sandbox; Apple DTS replied that guidance is unchanged and pointed at the porting guide ([forums thread 821584](https://developer.apple.com/forums/thread/821584)). Relevance: if swiftemacs is ever sandboxed, use the pthread toggle/callback API, never `mprotect`, and test on the shipping OS. [high that the thread exists and says this; low on the root cause]
- A libgccjit-style design (compile to `.eln` dylibs and `dlopen` them) is *worse* on
  macOS than in-process `MAP_JIT`: Hardened Runtime's library validation rejects code not
  signed by the same Team ID or Apple, so each generated dylib would have to be signed with
  the app's identity at runtime or the app would need
  `com.apple.security.cs.disable-library-validation` (which Apple DTS explicitly discouraged
  in the thread above). [medium — library-validation semantics from Apple's hardened-runtime
  table ("Allows loading arbitrary plug-ins or frameworks without requiring code signing");
  I did not test dlopen of an ad-hoc dylib under hardened runtime]

### 4.6 What this means for a Swift codebase

- **A C target is mandatory** for the secure path: `PTHREAD_JIT_WRITE_ALLOW_CALLBACKS_NP`
  and `pthread_jit_write_with_callback_np` are unusable from Swift by SDK decree. Put the
  JIT's *code-copy* step (memcpy of validated bytes into the region) into a ~50-line C file
  with the allowlist, and keep the *code generation* in Swift writing into an ordinary
  Swift buffer. This also matches Apple's "validate the instructions you are about to
  write" model: the C callback receives `(bytes, len, offset)` and bounds-checks them.
- `sys_icache_invalidate` needs `import Foundation` or the same C shim.
- Swift can call generated code via `@convention(c)` function types; the generated code
  must follow Apple's ARM64 ABI (§5).
- SwiftPM: a `cTarget` with the allowlist compiles fine; entitlements are attached at
  `codesign` time in the Xcode app target, not in SwiftPM. Use ad-hoc signing with the
  `.entitlements` file for local runs (as in §4.4) so the entitlement path is exercised
  from day one — otherwise the JIT will "work" in development and fail with `EINVAL` in the
  notarized build.

---

## 5. ARM64 codegen basics for a hand-written emitter in Swift

Apple ABI facts ([Apple: Writing ARM64 code for Apple platforms](https://developer.apple.com/documentation/xcode/writing-arm64-code-for-apple-platforms)) **[high]**:

- `x18` is reserved — never touch it. `x29` must always point at a valid frame record
  (leaf functions may omit it); keep it so crash reports and Instruments can unwind
  through JIT frames.
- 128-byte red zone below `sp`; 16-byte `sp` alignment at calls.
- Apple diverges from AAPCS64: the **caller** sign/zero-extends sub-32-bit arguments;
  stack arguments pack at natural alignment (not 8-byte slots); variadic args always go on
  the stack (`va_list` is `char*`); 16-byte-aligned types may start in an odd register.
  For an Elisp JIT you call Swift/C builtins with 64-bit words and pointers only, which
  sidesteps all of these — but the emitter must still honor the caller-extension rule if
  it ever passes `Int32`/`Bool`.
- Default third-party arm64 (not arm64e) has no pointer authentication; BTI/PAC are not
  required of JIT code today. [medium — inferred from the doc not mentioning them and from
  arm64e being opt-in]

Encoding basics the emitter needs (ARMv8-A; **[medium]** — standard architecture facts,
not re-verified against the ARM ARM in this run; the two instructions below were verified by
executing them):

- Fixed 32-bit instructions; `mov x0,#42` = `0xD2800540` (`MOVZ`), `ret` = `0xD65F03C0`.
- Immediates are awkward: `MOVZ/MOVK` build 64-bit constants in 1–4 instructions; `ADD/SUB
  (immediate)` take 12-bit unsigned (optionally `<<12`); logical immediates use the
  bitmask encoding (write a validator + table, or load from a constant pool via
  `LDR (literal)` with ±1 MB reach).
- Branches: `B` ±128 MB, `B.cond`/`CBZ/CBNZ` ±1 MB, `TBZ/TBNZ` ±32 KB. Calls to Swift
  builtins via `BL` only within ±128 MB of the JIT region — the region is `mmap`'d
  anywhere, so use `ADRP+ADD`/`LDR` of an absolute address in a per-function constant pool
  plus `BLR`, or reserve the pool near the binary (JSC reserves 128 MB / 512 MB with "jump
  islands" for exactly this reason — see §6.3).
- Tagged-integer fast paths: `ADDS/SUBS` with `B.VS` overflow branch to a slow path;
  `TST x, #tagmask` + `B.NE slow` for tag checks. Shift-based tagging (`x<<1|1` style)
  keeps `ADD/SUB` one instruction plus a tag fix.
- Frame: `STP x29,x30,[sp,#-16]!; MOV x29,sp` prologue; `LDP x29,x30,[sp],#16; RET`.
  Callee-saved `x19–x28` are the natural homes for the VM's `pc`, `sp`, `fp`, `env`,
  `constant pool` and `interp` pointers.
- The emitter in Swift is a `[UInt32]` builder with label/fixup lists; keep every
  instruction behind a named helper (`emitAddImm`, `emitBcond`) and a table-driven
  self-test that assembles each helper and compares against `llvm-mc`-style golden bytes
  (generated once, checked in) — this is the "hand-written emitter" cost centre and is
  where bugs hide.

A minimal baseline JIT for this design is ~3–6k lines of Swift plus the C shim (estimate,
[low]); Reticle's Cranelift backend was 953 lines *because Cranelift did the codegen*. A
Swift port cannot use Cranelift: it has no C API ("the cranelift APIs are Rust only",
[wasmtime#1164](https://github.com/bytecodealliance/wasmtime/issues/1164),
[#9488](https://github.com/bytecodealliance/wasmtime/issues/9488)). [high]

---

## 6. JIT design options, compared

### 6.1 Copy-and-patch (CPython 3.13+)

Design ([PEP 744](https://peps.python.org/pep-0744/), [Xu & Kjolstad OOPSLA 2021](http://fredrikbk.com/copy-and-patch.html)) **[high]**:
build-time Clang compiles C "stencils" (one per micro-op) into object files; a Python
script extracts the machine code and relocations; the runtime `memcpy`s stencils and
patches holes. Stencils are continuation-passing with guaranteed tail calls (`musttail`),
which is why **Clang is mandatory at build time**; there is no runtime LLVM dependency.
PEP 744: build time "3 to 60 seconds", memory "10–20% more… the upper range attributed to
macOS's larger page sizes", ~900 lines of build-time Python + ~500 lines of runtime C;
the JIT updates itself automatically when bytecode definitions change. Paper claims:
compile "two orders of magnitude faster" than LLVM -O0, code "14% faster than LLVM -O0",
4.9–6.5x faster compile than Liftoff with 39–63% faster code on WebAssembly benchmarks.

Results **[high]**: PEP 744 (2024) — "about as fast as the existing specializing
interpreter". [PEP 836](https://peps.python.org/pep-0836/) (June 2026) — "4–12% geometric
mean… M3 Pro macOS: 12.6% faster"; JIT still off by default in 3.15 binaries; roadmap
targets 20% on the free-threaded build by 3.17. The March 2026 write-up credits the gains to
trace recording across bytecodes and reference-count-branch elimination, i.e. to
*optimization*, not to the template mechanism ([mathewsachin blog](https://mathewsachin.github.io/blog/2026/03/18/python-jit-finally-fast.html), [medium]).

For swiftemacs: the mechanism assumes the interpreter's op handlers are C functions
compiled by Clang with `preserve_none`/`musttail`. Swift has neither guaranteed tail calls
nor `preserve_none`; the stencils would have to be a C reimplementation of every VM op,
duplicating the Swift VM. A SwiftPM build-tool plugin could run the stencil extractor, but
nobody has done this; the build complexity is the CPython one plus Swift/C duplication.
**Not recommended.** [medium]

### 6.2 Baseline (template) JIT from bytecode — Sparkplug / JSC Baseline

- V8 Sparkplug ([v8.dev](https://v8.dev/blog/sparkplug)) **[high]**: compiles from bytecode
  with no IR ("a `switch` statement inside a `for` loop, dispatching to fixed per-bytecode
  machine code generation functions"), keeps **interpreter-compatible frames** so
  debugging, profiling and OSR work unchanged, and mostly `call`s pre-built builtins
  rather than inlining. Measured: 5–10% Speedometer, 5–15% of V8 main-thread time in
  browsing benchmarks.
- JSC ([Speculation in JavaScriptCore](https://webkit.org/blog/10308/speculation-in-javascriptcore/)) **[high]**:
  per-bytecode latency LLInt 3.97 ns → Baseline 1.71 ns → DFG 0.349 ns → FTL 0.225 ns.
  Tier-up thresholds: LLInt→Baseline at 500 points, Baseline→DFG at 1,000, DFG→FTL at
  100,000, where a call adds 15 points and a loop iteration 1; thresholds scale with
  function size and double on each recompilation; profiling must be ">75%" populated
  before tier-up; OSR exit counts `100·2^R` trigger jettison. All tiers use polymorphic
  inline caches — self-modifying code that is also the profiler ("negative cost
  profiling").

Take-away: a baseline JIT removes dispatch and operand decoding — roughly a 2x on the
dispatch component, which itself is a fraction of an editor's runtime. Everything beyond
that comes from speculation + inline caching + deoptimization, which JSC needed two more
tiers (and OSR machinery) to exploit. [medium]

### 6.3 Optimizing JIT

Requires: type feedback, speculation with OSR exit back to interpreter-compatible frames,
GC stack maps / safepoints, deopt metadata, register allocation. JSC's FTL gains 1.5x over
DFG on typical code. For Elisp specifically, dynamic binding (`let` of special variables),
`condition-case`/`catch`/`unwind-protect`, advice and redefinition of any function at any
time (Emacs native-comp needed *trampolines* just to preserve `advice-add` on primitives)
and the absence of a static type system make speculation expensive. **Do not plan.** [medium]

JSC platform note (from `Source/JavaScriptCore/jit/ExecutableAllocator.cpp`, **[high]**):
it reserves one fixed executable pool — 512 MB on arm64 with jump islands, 128 MB without,
1 GB on x86_64 — and on Apple platforms uses either the fast per-thread permission switch
or, when unavailable, a separate writable remap of the same physical pages
(`jitWriteSeparateHeaps` via `mach_vm_remap`). The single-pool design is the pattern to copy.

### 6.4 LLVM ORC via C or Swift/C++ interop

- The **C API** covers LLJIT: `LLVMOrcCreateLLJIT`, `LLVMOrcLLJITAddLLVMIRModule`,
  `LLVMOrcLLJITLookup` etc. exist in `llvm-c/LLJIT.h` (verified in the Homebrew LLVM 23.1
  headers on this machine) **[verified]**; JITLink has MachO/arm64 rated "Good"
  ([JITLink docs](https://llvm.org/docs/JITLink.html)) **[high]**. So Swift/C++ interop is
  *not required* — plain C interop suffices for LLJIT. (Swift C++ interop is usable —
  `interoperabilityMode(.Cxx)` — but has no exception bridging, copies containers, and
  renames reference-returning members `Unsafe`; wrapping LLVM's C++ API would be far more
  work than using `llvm-c`.) **[high]** for the interop limits ([swift.org](https://www.swift.org/documentation/cxx-interop/)).
- Cost: `libLLVM.23.1.dylib` from Homebrew is **162 MB** (arm64, measured with `du -m`);
  Xcode does not ship a `libLLVM.dylib` in its toolchain (checked: none present) — the app
  would bundle its own LLVM build. **[verified]** Compile latency is LLVM's (milliseconds per
  function at -O0, tens of ms at -O2 — [medium], not measured here), which forces
  background compilation and therefore all the per-thread W^X coordination.
- Whether LLJIT's in-process memory manager uses `MAP_JIT` and the pthread toggle by default
  on macOS I could **not** confirm from the docs (JITLink docs don't mention it; the ORCv2
  summary I received claimed it does but I could not see the sentence) — see §12.
- **Verdict:** enormous binary, build and notarization surface for a code generator whose
  speed we do not need; only sensible if swiftemacs also wanted an AOT path for Elisp
  packages. Not recommended. [medium]

### 6.5 libgccjit (Emacs's choice)

GPL toolchain dependency (`gcc`, `binutils`) at *run time*, out-of-process compilation into
`.eln` shared objects, `dlopen` — impossible to notarize cleanly and awkward to bundle. §8
covers its track record. Not applicable to a Swift/macOS app. [high]

### 6.6 Summary table

| Option | Codegen quality | Compile latency | Binary/build cost | Swift fit | Verdict |
|---|---|---|---|---|---|
| Hand-written ARM64 baseline JIT | ~2x on dispatch, more with ICs | µs | small (+C shim) | good | *Later, gated by measurement* |
| Copy-and-patch | ≈ LLVM -O0 | µs | needs Clang + extractor; duplicates VM ops in C | poor | No |
| LLVM ORC (LLJIT via `llvm-c`) | -O0…-O2 | ms–tens of ms | +162 MB dylib, own LLVM build | ok (C API) | No |
| Cranelift | good | sub-ms | Rust only, no C API | none | Not possible |
| libgccjit | -O2/-O3 | seconds, out-of-process | GCC at runtime, dlopen'd dylibs | none | No |
| Optimizing JIT (own) | best | ms | large engineering | possible | Do not plan |

---

## 7. Where interpreter engineering gets its wins (the alternative)

| Source | Technique | Measured effect | Confidence |
|---|---|---|---|
| [PEP 659](https://peps.python.org/pep-0659/) | Specializing adaptive interpreter: quickening + inline caches in the bytecode stream, rapid de-specialization | Expected ~50%: "approximately 30% from specialization, much of which comes from specialization of calls… About 10% comes from improved dispatch such as super-instructions"; 3.11 shipped 25% faster than 3.10; cumulative "nearly 50% faster in less than four years" ([LWN](https://lwn.net/Articles/1029307/)) | [high] |
| Ertl & Gregg 2003 ([JILP](https://jilp.org/vol5/v5paper12.pdf)) | Superinstructions and instruction replication to fix indirect-branch prediction | "interpreters… can spend more than half of execution time in indirect branch mispredictions"; BTB accuracy 2–50% on 2003 hardware | [medium] — old hardware; modern Apple cores predict indirect branches far better, so expect a smaller but nonzero effect |
| CPython 3.14 tail-calling interpreter ([Ken Jin](https://fidget-spinner.github.io/posts/apology-tail-call.html), [nelhage](https://blog.nelhage.com/post/cpython-tail-call/)) | `musttail` + `preserve_none` handlers instead of computed goto | Initially "10%", corrected to 1–5% (the rest was an LLVM 19 regression in the baseline) | [high] — and a caution about benchmarking against a broken baseline |
| GNU Emacs `bytecode.c` | Computed-goto threaded dispatch (`BYTE_CODE_THREADED`), stack VM with direct opcodes for hot primitives | (no number) | [medium] |
| Reticle PLAN.md L365-380 | `Add2/Sub2/Car1/Cdr1/Eq2/Cons2` etc. with inlined Int×Int fast paths; peephole; constant folding | Bytecode tier went from ~8x to (unquantified) more over tree-walking; `fib` unaffected because calls dominate | [verified] |

**Swift-specific constraints for a fast VM** [medium — inferences from documented Swift
behaviour, not measured here]:

- No computed goto, no guaranteed tail calls, no `preserve_none`. Dispatch is a `switch`
  over a `UInt8`/`UInt16` opcode — Swift lowers dense switches to jump tables; that is one
  indirect branch per instruction, which is the classic interpreter shape. Superinstructions
  and *replicated* opcodes (PEP 659-style specialization families) are the tools available.
- **ARC is the enemy.** A `Value` enum with class payloads means atomic retain/release on
  every stack push/pop and every argument copy; Apple's own WWDC material and the
  Swift-forums ownership roadmap document that ARC can dominate hot loops. The standard
  mitigations are: represent values as a 64-bit tagged word (`UInt64`/`UnsafeRawPointer`)
  managed by the engine's own GC (not ARC); keep the VM stack in `UnsafeMutablePointer`
  memory; use `borrowing`/`consuming` and `~Copyable` where Swift 6.3 allows; mark hot
  builtins `@inline(__always)`; keep the interpreter loop free of existentials and
  protocol dispatch. Apple's TrueType hinting interpreter example is published as a
  reference for "high performance Swift" in exactly this style ([apple/truetype-hinting-interpreter-example](https://github.com/apple/truetype-hinting-interpreter-example)).
- This is the same representation a baseline JIT needs (native code cannot cheaply
  participate in ARC). Choosing the tagged-word representation in stage 1 is therefore the
  cheapest possible "keep the JIT option open" decision — and it is also the decision that
  fixes Reticle's `Rc`-based GC cycle leaks (CONTEXT.md).
- Calls: contiguous frames on the VM stack, arguments passed in place (no per-call array
  allocation — Reticle's PLAN.md item 6 "smallvec for arguments" was exactly this
  retrofit), `&optional`/`&rest` resolved by the callee's arity table, dynamic bindings on
  a separate specpdl-style stack. This is what turns `fib` from 1.0x into a real speedup.
- Inline caches: a per-call-site slot caching `symbol → function cell` (invalidated by a
  global "function redefined" epoch), per-`symbol-value` site caching the value cell for
  non-special variables, and per-`get-text-property` hot paths that avoid consing. These
  are the editor's real hot sites; they are also what Emacs `advice-add` must keep
  correct, so the invalidation epoch design is a correctness feature, not just speed.
- Builtins in Swift with a uniform C-ABI-shaped fast entry (`(args: UnsafePointer<Word>,
  n: Int, interp: UnsafeMutableRawPointer) -> Word`) so that a later JIT can `BLR` into them
  without marshalling.

---

## 8. Emacs native-comp with libgccjit: design, benefits, complaints

Design ([Corallo, Nassi, Manca — Bringing GNU Emacs to Native Code, ELS 2020](https://arxiv.org/abs/2004.02504)) **[high]**:
takes the byte-compiler's LAP, lifts it into **LIMPLE** (sexp SSA IR with basic blocks,
`(set …)`, `(call …)`, `(phi …)`), runs passes written in Elisp — `spill-lap`, `limplify`,
SSA, forward data-flow (type/value propagation), `call-optim` (replace `funcall`
trampolines with direct primitive calls), dead-code, tail-recursion elimination — and a
`final` pass that emits libgccjit IR. `native-comp-speed` 0–3 map to GCC `-O0…-O3`; level
3 enables intra-unit inlining and "trusting user compiler hints" (type declarations); the
manual documents `-1` = byte-compile only, default 2 ([Native-Compilation Variables](https://www.gnu.org/software/emacs/manual/html_node/elisp/Native_002dCompilation-Variables.html)).

Benchmarks (paper, `comp-speed` 3, Intel i5-4200M, speedup of native over byte-code)
**[high]**: `inclist` 9.2x, `inclist-type-hints` 13.8x, `listlen-tc` 42.1x, `bubble` 5.4x,
`bubble-no-cons` 4.0x, `fibn` 2.3x, `fibn-rec` 2.9x, `fibn-tc` 3.7x, `dhrystone` 2.6x,
`nbody` 6.0x. The manual's summary: "2.5 to 5 times faster than the corresponding
byte-compiled code". Note that **the same `fib`-shaped benchmarks are the bottom of the
table** (2.3–3.7x) and that the top entries are tail-call/list loops with type hints —
consistent with Reticle's finding that call cost dominates.

Complaints (all **[high]** that they were reported; [medium] on prevalence):

- Background compilation: "Emacs keeping running async compilation", "native-comp-async
  always runs, but no eln files are generated" ([Debian #1023440](https://www.mail-archive.com/debian-bugs-dist@lists.debian.org/msg1877828.html)); Doom users report startup slowness and a flood of warnings in `*Async-native-compile-log*` ([Doom discourse](https://discourse.doomemacs.org/t/warnings-and-slowness-at-startup-due-to-native-compilation/3154)). For an editor whose brief says "low power", a compiler that burns cores after every package update is a direct violation.
- Trampolines: advising/redefining a primitive requires generating a trampoline `.eln`; "if a trampoline… is not available and cannot be generated, calls to that primitive from native-compiled Lisp will ignore redefinitions and advices" (manual); trampoline generation failures were bug-reported ([bug#61880](https://lists.gnu.org/archive/html/bug-gnu-emacs/2023-03/msg00076.html)).
- `.eln` cache: non-portable across machines and Emacs versions; cache-location bugs ([bug#53891](https://lists.gnu.org/archive/html/bug-gnu-emacs/2022-02/msg00695.html)); Doom needed `native-compile-target-directory` handling ([doomemacs#7468](https://github.com/doomemacs/doomemacs/issues/7468)).
- macOS specifically: libgccjit packaging failures on Apple Silicon ("libgccjit not supported on M1", "error invoking gcc driver", `@rpath/libgccjit.0.dylib` not found — [emacs-plus #338/#323/#562/#684](https://github.com/d12frosted/homebrew-emacs-plus/issues/562)); a dyld4 crash in `dlopen_from` when loading `.eln` files on macOS 13 with no Apple response ([forums 722590](https://developer.apple.com/forums/thread/722590)); a Doom report that Emacs 29.4 `--with-native-comp` was "two times slower than without" on an Intel Mac, unresolved ([doomemacs/core#8207](https://github.com/doomemacs/core/issues/8207)).
- System-level: Guix bug "native compilation on startup can crash the system" (resource exhaustion) ([guix #57878](https://issues.guix.gnu.org/57878)).

The local Emacs 30.2 (`/opt/homebrew/bin/emacs`) reports `NATIVE_COMP` in
`system-configuration-features` **[verified]** — useful as a comparison baseline for the
benchmark suite, and a reminder that swiftemacs will be compared against native-comp'd
Emacs, not against the byte-code interpreter.

---

## 9. Weighing: JIT vs. a well-designed bytecode VM

| Criterion | Hand-written baseline JIT | VM with superinstructions + ICs + Swift builtins |
|---|---|---|
| Effect on editor hot paths (hooks, font-lock, text props, regex, GC) | Small: those are runtime calls | Direct: cheap calls, cached lookups, no-alloc builtins |
| Effect on Elisp-to-Elisp glue | ~2x on dispatch component (JSC/Sparkplug data) | ~1.3–1.5x from superinstructions/quickening (PEP 659 data) |
| Correctness surface | New: W^X protocol, icache, ABI, deopt, interruption, GC maps, crash symbolication | Same as any VM |
| Debuggability | Frames must be interpreter-compatible or debugger/profiler break | Native |
| Power | Compile work + code memory; JSC keeps 128–512 MB reservations | None extra |
| Shipping | Entitlement, sandbox caveat (macOS 26 thread), C shim for allowlist | None |
| Reversibility | Must be behind a flag with full interpreter fallback anyway | — |

The VM work is a prerequisite for the JIT (a template JIT compiles *this* bytecode and
calls *these* builtins), so the ordering is forced regardless of the final verdict.

---

## 10. Staged plan (recommended)

**Stage 0 — decisions that keep the JIT possible (cost ≈ 0, do in the VM design):**
- 64-bit tagged-word `Value` with engine-managed heap and a precise GC (fixes Reticle's
  cycle leaks; removes ARC from the hot path; is what native code can consume).
- Bytecode with fixed-width operands and reserved inline-cache slots; a contiguous VM stack
  with frames laid out so that a JIT frame can be identical ("interpreter-compatible
  frames", Sparkplug).
- Builtins exported through one C-ABI-shaped Swift entry point; error signalling by
  return-code + interp state, never by Swift `throws` across the boundary (JIT code cannot
  unwind Swift errors; the pthread callback API forbids non-local exits).
- Back-edge and call-entry check for interruption/quit and for tier-up counters (JSC's
  points model: call 15, loop 1 — cheap and proven).
- Function-redefinition epoch for IC invalidation (also the `advice-add` correctness story).

**Stage 1 — the VM (the real performance work):** superinstructions for the Emacs-
bytecode-equivalent hot opcodes (`car/cdr/cons/eq/+/-/1+/aref/…`), quickened
`symbol-value`/`funcall`/`get-text-property` with inline caches, no-allocation call path,
specpdl-style dynamic binding, peephole + constant folding (Reticle's `peephole.rs` is a
reference). Ship with a `(byte-compile)` that runs by default on load.

**Stage 2 — the runtime the Elisp calls into:** regex engine (compile to a matcher
bytecode with a work budget as Reticle did; measure font-lock on real SystemVerilog/org
files), interval tree for text properties, GC pause targets, hook time budgets. This is
where an editor's speed is decided.

**Stage 3 — measurement gate:** an editor-workload benchmark suite run in CI
(fontify 20k-line `.sv`, 10k keystrokes through `post-command-hook` chains, org agenda
parse, `M-x occur` on a large buffer) compared with Emacs 30.2 native-comp. Record the
share of wall time in bytecode dispatch (sampling profiler on the VM loop). **Only if that
share is ≥20% after stages 1–2** proceed to stage 4.

**Stage 4 (conditional) — baseline ARM64 JIT:** Sparkplug-style template JIT from
bytecode, in Swift, calling builtins, with interpreter-compatible frames; `MAP_JIT` single
reservation, C shim with `PTHREAD_JIT_WRITE_ALLOW_CALLBACKS_NP` +
`pthread_jit_write_with_callback_np`, `sys_icache_invalidate` per batch, entitlements
`allow-jit` + `jit-write-allowlist`, compile on the main thread first (no cross-thread
W^X), back-edge checks preserved, opt-in (`native-compile`) then auto by counters; golden-
byte tests for every emitter helper; crash-report symbolication of JIT frames via a
side table. Gate again: ≥20% on the suite or delete it.

**Stage 5 — regex JIT (independent of stage 4):** if profiling shows regex matching
dominating font-lock even after a good bytecode matcher, a regex-specific emitter is the
highest-value JIT in an editor (this is why JSC has Yarr JIT and PCRE2 has sljit — both
`MAP_JIT` users per Apple's entitlement page). Reuses all stage-4 infrastructure.

**Never:** `allow-unsigned-executable-memory`, `disable-executable-page-protection`,
`disable-library-validation`, out-of-process compilers writing dylibs, LLVM in the app.

---

## 11. Pitfalls checklist (for whoever implements stage 4)

1. Test the entitled, hardened, Developer-ID-signed build on every macOS release; the
   failure mode is a silent `EINVAL` from `mmap`, and the macOS 26 sandbox thread shows the
   kernel path changes between releases.
2. Never `mprotect` `MAP_JIT` pages on arm64; use the pthread toggle/callback.
3. Every thread that touches the region must set its own permission state; new threads
   start write-protected; never let two threads hold opposite states on the same pages.
4. `sys_icache_invalidate` after *every* write batch, before execution; ~250 ns each on M4 —
   batch IC patches.
5. Callbacks passed to `pthread_jit_write_with_callback_np` must not throw/longjmp and
   must validate their input (Apple's threat model: attacker-controlled context).
6. `x18` reserved; `x29` frame chain intact; 16-byte `sp`; caller extends sub-32-bit args.
7. Constant pools / absolute `BLR` for builtin calls (region may be >128 MB from the
   binary).
8. Interruptibility (`C-g`) and tier-up counters on back-edges — Reticle's JIT lacked both.
9. GC: JIT frames must be scannable (shadow stack of live `Value`s or stack maps).
10. Errors: no Swift `throws` across native frames; signal via return code and let the
    interpreter-compatible frame unwind.
11. Function redefinition/advice: IC invalidation epoch; a cached direct call into a
    redefined function is a correctness bug users will hit (Emacs trampolines exist for it).
12. Debuggability: crash logs show anonymous addresses inside `MAP_JIT`; keep a
    `[range → function name]` table and dump it in the crash handler.
13. Benchmarks: do not measure against a broken baseline (the CPython tail-call lesson);
    measure editor workloads, not `fib`/`loop-sum`.

---

## 12. Unverified / could not confirm

- Whether LLVM's default in-process JITLink memory manager on macOS/arm64 uses `MAP_JIT`
  and `pthread_jit_write_protect_np` automatically (the ORCv2 doc summary claimed so; the
  JITLink page I read says nothing).
- The "only one MAP_JIT region" rule: my probe created two 16 KB regions under hardened
  runtime + `allow-jit` with **ad-hoc** signing on macOS 26.6; not retested with a
  Developer ID identity, with the App Sandbox, or with large regions.
- That notarization accepts `com.apple.security.cs.allow-jit`: inferred from it being a
  documented Hardened Runtime exception and from Electron/electron-builder practice; no
  Apple page states it explicitly.
- Mac App Store review acceptance of `allow-jit` — secondary sources only.
- Library-validation behaviour for runtime-generated dylibs (relevant only to a rejected
  `.eln`-style design) — not tested.
- Exact per-benchmark numbers in the ELS 2020 paper came from a tool summary of the ar5iv
  HTML; the table shape matches the paper's abstract range (2.3x–42x) but individual rows
  were not eyeballed in the PDF.
- The copy-and-patch OOPSLA paper's numbers come from the author's project page, not the
  PDF (which I could not render).
- LLVM per-function compile latency figures (ms at -O0) are from general experience, not
  measured.
- Emitter size estimate (3–6k lines) is a guess.
- The saagarjha gist's claim that threads start write-protected is consistent with
  Apple's "memory protection for all apps" statement but I did not test a write without the
  toggle (it would crash the probe).

---

## 13. Sources

Apple (primary):
- https://developer.apple.com/documentation/apple-silicon/porting-just-in-time-compilers-to-apple-silicon
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-jit
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-unsigned-executable-memory
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-executable-page-protection
- https://developer.apple.com/documentation/security/hardened-runtime
- https://developer.apple.com/documentation/security/resolving-common-notarization-issues
- https://developer.apple.com/documentation/xcode/writing-arm64-code-for-apple-platforms
- https://developer.apple.com/documentation/swift/using-imported-c-macros-in-swift
- https://developer.apple.com/forums/thread/821584 (macOS 26 sandbox + allow-jit crash)
- https://developer.apple.com/forums/thread/722590 (Emacs .eln dlopen crash, macOS 13)
- macOS 26 SDK headers: `usr/include/pthread/pthread.h`, `usr/include/sys/mman.h`, `usr/include/libkern/OSCacheControl.h`
- https://keith.github.io/xcode-man-pages/pthread_jit_write_protect_np.3.html (man page mirror)

Hardware / community:
- https://blog.svenpeter.dev/posts/m1_sprr_gxf/
- https://gist.github.com/saagarjha/d1ddd98537150e4a09520ed3ede54f5e
- https://github.com/python/cpython/issues/126195

JIT designs:
- https://peps.python.org/pep-0744/ , https://peps.python.org/pep-0836/
- http://fredrikbk.com/copy-and-patch.html (Xu & Kjolstad, OOPSLA 2021)
- https://lwn.net/Articles/1029307/ , https://mathewsachin.github.io/blog/2026/03/18/python-jit-finally-fast.html
- https://fidget-spinner.github.io/posts/apology-tail-call.html , https://blog.nelhage.com/post/cpython-tail-call/
- https://peps.python.org/pep-0659/
- https://webkit.org/blog/10308/speculation-in-javascriptcore/
- https://raw.githubusercontent.com/WebKit/WebKit/main/Source/JavaScriptCore/jit/ExecutableAllocator.cpp
- https://v8.dev/blog/sparkplug
- https://llvm.org/docs/ORCv2.html , https://llvm.org/docs/JITLink.html , local `/opt/homebrew/opt/llvm/include/llvm-c/LLJIT.h`
- https://www.swift.org/documentation/cxx-interop/
- https://github.com/bytecodealliance/wasmtime/issues/1164 , https://github.com/bytecodealliance/wasmtime/issues/9488
- https://jilp.org/vol5/v5paper12.pdf (Ertl & Gregg 2003)

Emacs:
- https://arxiv.org/abs/2004.02504 (Corallo, Nassi, Manca, ELS 2020)
- https://www.gnu.org/software/emacs/manual/html_node/elisp/Native-Compilation.html
- https://www.gnu.org/software/emacs/manual/html_node/elisp/Native_002dCompilation-Variables.html
- https://github.com/emacs-mirror/emacs/blob/master/src/bytecode.c
- https://ianyepan.github.io/posts/emacs-profiling/ , https://elmord.org/blog/?entry=20190913-emacs-gc
- https://200ok.ch/posts/2020-09-29_comprehensive_guide_on_handling_long_lines_in_emacs.html
- https://lists.gnu.org/archive/html/emacs-devel/2023-09/msg00879.html
- https://discourse.doomemacs.org/t/warnings-and-slowness-at-startup-due-to-native-compilation/3154
- https://github.com/doomemacs/core/issues/8207 , https://github.com/doomemacs/doomemacs/issues/7468
- https://github.com/d12frosted/homebrew-emacs-plus/issues/562 (and #323, #338, #684)
- https://lists.gnu.org/archive/html/bug-gnu-emacs/2023-03/msg00076.html , https://lists.gnu.org/archive/html/bug-gnu-emacs/2022-02/msg00695.html
- https://issues.guix.gnu.org/57878 , https://www.mail-archive.com/debian-bugs-dist@lists.debian.org/msg1877828.html

Reticle (owner's project, read-only):
- `/Users/jerrychen/My_Projects/reticle/README.md` (L44-66), `PLAN.md` (L160-212, L365-380, L513-520, L953, L6104-6110), `crates/elisp/src/jit.rs`, `dev/bench-tiers.el`

Local experiments (own code):
- `/private/tmp/claude-501/-Users-jerrychen-My-Projects-swiftemacs/78b49b87-1b91-4d9a-abe1-c2ce2102e33b/scratchpad/jitprobe/{jitprobe.swift,probe2.swift,jit.entitlements}`
