# Feasibility spikes run on the owner's machine, 2026-09-05

All spikes are own code against the Apple SDK only (no third-party packages fetched or
built). Machine: macOS 26.6.2, Apple M4, Xcode 26.6, Swift 6.3.3, SDK 26.5. Sources sit
next to this file.

## 1. MAP_JIT works, and the entitlement rule is real (spike_jit.swift)

Two ARM64 instructions (mov w0,#42 ; ret) written into MAP_JIT memory via
pthread_jit_write_protect_np(0/1) + sys_icache_invalidate, then called.

| Binary signing | Result |
|---|---|
| plain swiftc output (ad-hoc linker signature, no hardened runtime) | returned 42 |
| codesign --options runtime, no entitlement | mmap(MAP_JIT) fails, errno 22 (EINVAL) |
| codesign --options runtime + com.apple.security.cs.allow-jit | returned 42 |

Consequence for the plan: a JIT is feasible; the shipped .app must carry the allow-jit
entitlement under the hardened runtime (required for notarization). sys_icache_invalidate
is not exposed to Swift by the Darwin module and needs a @_silgen_name shim or a C header.

## 2. macOS 26 SDK surface typechecks from Swift 6.3 (spike_lang.swift, exit 0)

InlineArray, Span, RawSpan, ~Copyable; NSView.displayLink(target:selector:) (CADisplayLink
on AppKit); MTL4CommandQueue via MTLDevice.makeMTL4CommandQueue(); CAMetalLayer
.presentsWithTransaction; NSTextLayoutManager (TextKit 2); FoundationModels
SystemLanguageModel.default; NSGlassEffectView (Liquid Glass in AppKit); ExtensionKit and
ExtensionFoundation import. All present in the SDK's Frameworks directory.

## 3. Lisp value representation cost in Swift (spike_repr.swift, -O -wmo, best of 3)

Workload per representation: cons a 1,000,000-element list, traverse-and-sum it 20 times,
plus a 20M-iteration integer loop through the value type. This isolates representation
cost; it is not an interpreter benchmark.

| Representation | Time | Relative |
|---|---|---|
| A: indirect enum (every cons is an ARC box, payload copied on match) | ~0.55 s | ~27x |
| B: enum { int, cons(final class) } (ARC on class refs) | ~0.10 s | ~5x |
| C: tagged UInt64 word + manual arena, no ARC | ~0.02 s | 1x |

-Ounchecked changes nothing material (A 0.69, B 0.13, C 0.015).

Recursive release: with the naive teardown (let ARC free the 1M-node list on scope exit)
rep A exit status 139, rep B exit status 139, main-thread stack 8176 KB. An
iterative unlink loop before the value goes out of scope avoids it. An interpreter thread
has a 512 KB default stack unless set explicitly, so this bites far earlier there.

Consequence for the plan: ARC-managed cons cells are viable for a first interpreter but
cost ~5x on list traversal and need iterative teardown discipline everywhere a long list
can die; a tagged-word + arena/GC design is the performance ceiling and should be the
target of the engine's value representation from the start (the swap later is the whole
engine). Rep A (indirect enum) is ruled out.

## 4. Mini tree-walking interpreter in Swift (spike_interp.swift, -O -wmo)

A deliberately small Elisp-shaped evaluator: enum values with a final-class cons payload
(rep B above), symbols interned to Ints, dynamic-binding values in a flat array, special
forms let/while/setq/progn and the builtins < + 1+, with a step counter slot for a
deadline check every 64 iterations. It runs Reticle's benchmark form:

    (let ((acc 0) (i 0)) (while (< i n) (setq acc (+ acc i)) (setq i (1+ i))) acc)

| Engine | loop-sum(20,000,000) |
|---|---|
| Reticle tree-walker (Rust, release, from its PLAN.md) | 9.59 s |
| Reticle bytecode VM (Rust, ~8x per its README) | ~1.2 s |
| This Swift mini tree-walker (ARC cons cells, flat symbol array) | 2.37-2.46 s, ~120 ns/iteration |

Caveat, stated plainly: this is not a like-for-like comparison. Reticle's evaluator does
more per node (symbol-table lookups, GC registration on writes, condition handling), so
the number is a lower bound on Swift dispatch cost for this value representation, not a
claim that a full Swift engine beats Reticle 4x. What it does establish: Swift with ARC
values is not intrinsically too slow for a tree-walking Elisp core — ~10 ns per eval node
on the M4 leaves headroom — and a bytecode tier on a tagged representation should land
well under Reticle's VM numbers.

## 5. Toolchain facts for the build gate (verified 2026-09-05)

- `swift format` 6.3.0 ships in the Xcode 26.6 toolchain (no swiftformat/swiftlint needed).
- `swift package init` defaults to swift-tools-version 6.3 and Swift 6 language mode;
  `swift test` on a fresh package runs Swift Testing (library version 1902) in ~5 s cold.
- `xcrun actool`, `notarytool`, `xctrace` present; `/usr/bin/powermetrics` present (needs sudo).
- Homebrew already has `libtree-sitter` / `tree-sitter@0.25`, `harfbuzz`, `libgit2` 1.9,
  `ripgrep`, `fd`; git 2.55; system Python 3.9.6 for dev tooling.
- `import Testing` / `import XCTest` fail under bare `swiftc -typecheck` (module search
  paths); irrelevant under SwiftPM, noted so nobody chases it.
