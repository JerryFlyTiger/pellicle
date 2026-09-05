# Swift 6.3 as an implementation language for a fast Lisp interpreter and editor core

Topic key: `swift-interpreter-perf`. Scope: Swift 6.3.3 (Xcode 26.6), evaluating feasibility
of a fast Emacs Lisp interpreter + editor core in Swift on macOS. This report builds on,
and does not repeat, the measured numbers in `../spikes/RESULTS.md` (value-representation
costs A/B/C, the recursive-release crash under naive ARC teardown, and the mini
tree-walker timing of ~120 ns/iteration vs Reticle's Rust tree-walker/VM).

**Research method note:** WebSearch was unavailable for almost this entire run (session-wide
quota exhausted after 3 queries). Findings below therefore come from direct `WebFetch` of
primary sources whose URLs I already knew (Swift Evolution proposals on GitHub, swift.org
blog, `apple/swift` docs in-tree) plus well-established Swift language knowledge, the latter
explicitly flagged as such. Two fetch attempts failed and are noted where relevant (a forum
thread guess that hit an unrelated topic; a swift.org blog URL that 404'd).

---

## 1. Value representation choices

Already measured empirically for this project (see spikes RESULTS.md #3): indirect enum
(~27x), enum-with-final-class-cons (~5x), tagged UInt64 + arena (1x baseline, no ARC). This
section adds primary-source context for *why*.

- **Indirect enum**: every case with `indirect` (or any enum where the compiler must make a
  case indirect because of size) boxes the payload on the heap and manages it with ARC like
  a class. Confirms the spike's finding that this is the most expensive of the three shapes.
- **`~Copyable` (noncopyable) structs/enums** (SE-0390, implemented Swift 5.9): "An instance
  of a noncopyable type always has unique ownership... no object needs to be allocated; only
  a simple struct... needs to be stored." This is the language's own answer to "avoid
  ARC/heap for a value with unique-ownership semantics" — confidence **high** that it
  eliminates ARC for the value itself, but it composes awkwardly with a classic mutable
  Lisp heap (cons cells that outlive their creating scope, get mutated via `setcar`/`setcdr`,
  and are referenced from multiple live bindings) — ownership must be threaded explicitly.
  A `~Copyable` cons cell is a good fit for an arena slot's *content* struct, not for a
  freely-aliased boxed value. [SE-0390](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0390-noncopyable-structs-and-enums.md).
- **`InlineArray`** (SE-0453, implemented Swift 6.2): fixed-size, stack-or-inline storage,
  "will never introduce an implicit heap allocation just for its storage alone"; explicitly
  motivated by avoiding `Array`'s "retain/release traffic" from CoW buffer headers. Useful
  for e.g. a fixed-arity argument-vector scratch buffer in the evaluator, or SIMD-style
  fixed slots in a value's inline payload — not a general cons/list solution since Lisp
  lists are variable length and shared/mutated. [SE-0453](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0453-vector.md).
- **Tagged UInt64 + manual arena (rep C in the spike)**: matches the "GC/VM value
  representation" pattern used by essentially every fast dynamic-language runtime (JS
  engines' NaN-boxing, OCaml's boxed/unboxed ints). Confirmed by the spike as the
  performance ceiling (1x vs 5x vs 27x) and by Apple's own guidance (§2 below) that ARC
  traffic on graph-shaped data is the dominant cost to eliminate.

**Recommendation for this section**: tagged-word representation with a manual arena is the
target design (confirmed by measurement, not just paper reasoning); `~Copyable` is a good
tool for owning arena *slabs* or single-owner interpreter state, not for a generally-aliased
cons cell. Confidence: high (spike-measured) + high (SE-0390/SE-0453 text confirms intent).

## 2. ARC retain/release cost in hot loops and how to avoid it

Primary source: `apple/swift` in-tree `docs/OptimizationTips.rst` (fetched directly).

- The document states plainly: "Every time we move the reference Swift will increment the
  reference count of the `next` object and decrement the reference count of the previous
  object. These reference count operations are expensive" — this is Apple's own framing of
  exactly the cost the spike measured on linked-list traversal.
- **`Unmanaged<T>`** is the documented escape hatch for hot traversal loops that don't need
  ARC because a longer-lived reference already keeps the object alive:
  ```swift
  withExtendedLifetime(Head) {
    var Ref: Unmanaged<Node> = Unmanaged.passUnretained(Head)
    while let Next = Ref._withUnsafeGuaranteedRef({ $0.next }) {
      // Process node
      Ref = Unmanaged.passUnretained(Next)
    }
  }
  ```
  The doc itself warns `_withUnsafeGuaranteedRef` "is not public and may change" — treat as
  an unstable/internal API, not something to build the production interpreter on; the
  *pattern* (hold one strong root via `withExtendedLifetime`, walk with `Unmanaged` pointers
  that skip retain/release) is the stable takeaway, using only public `Unmanaged` methods
  (`passUnretained`, `takeUnretainedValue`) in the real implementation. Confidence: high for
  the pattern, medium for continuing to rely on the underscored helper itself.
- **`final` classes and restricted access levels enable devirtualization**, which in turn
  lets the optimizer prove exclusive ownership and elide ARC pairs: "Applying the `private`
  or `fileprivate` keywords to a declaration restricts the visibility... the absence of any
  such declarations enables the compiler to infer the `final` keyword automatically." With
  whole-module optimization on, this extends to `internal` (the Swift default) too: "by
  enabling Whole Module Optimization, one can gain additional devirtualization without any
  further work." Practical guidance: build the interpreter as a single module (or a
  `package`-scoped set of modules, §3) with WMO on, mark hot classes `final`, and default to
  `internal`/`private` — never `open`/`public` on hot-path types.
- **Unsafe pointer arenas** (`UnsafeMutablePointer<T>` / `UnsafeMutableRawPointer`) sidestep
  ARC entirely because raw pointers are invisible to the reference-counting runtime — this
  is standard Swift knowledge (medium confidence, not independently re-verified via fetch
  this session beyond the OptimizationTips excerpt confirming ARC's cost is what's being
  avoided): an arena of untyped memory holding tagged words or POD cons structs never
  triggers retain/release traffic because no `class` reference is stored there. This is
  consistent with, and is the general form of, spike representation C.
- **`unowned(unsafe)`**: standard Swift feature (not independently re-fetched this session)
  — an `unowned(unsafe)` reference is compiled like a raw pointer with no retain/release and
  no runtime liveness check (unlike plain `unowned`, which does a runtime check in
  non-`-Ounchecked` builds). Confidence: medium (well-established language feature, but not
  re-confirmed against current documentation this session — flagged per the "mark
  unconfirmed" rule).
- **`withExtendedLifetime`**: documented pattern above; keeps a strong reference alive across
  a region where inner code uses unmanaged/unsafe access to the same object, without extra
  retain/release inside the region. High confidence (directly quoted from Apple's own doc).

**Consequence for the plan**: none of these require abandoning ARC everywhere — only on the
identified hot paths (cons traversal, symbol lookup, eval dispatch). The rest of the
interpreter (parser, GUI glue, LSP client, file I/O) can stay plain ARC Swift.

## 3. Exclusivity checking, `-Ounchecked`, WMO, cross-module inlining

- **Exclusivity enforcement** (swift.org blog, fetched): checks that "a variable cannot be
  accessed via a different name for the duration in which the same variable is being
  modified as an `inout` argument or as `self` within a `mutating` method"; covers inout
  aliasing, escaping closures over mutated variables, and class/global/static property
  conflicts. The blog post explicitly declines to give numbers: "The overhead of the memory
  access checks could affect the performance of the Release binary. The impact should be
  small in most cases" — no measured percentage is given (**unverified as a quantified
  cost**, only qualitatively described as small).
- Two flags disable it: `-enforce-exclusivity=unchecked` (checks still run in debug, dropped
  in release) and `-enforce-exclusivity=none` (compile-time only, no runtime check ever). The
  blog **strongly warns** against disabling runtime checks in release: "if the program
  violates exclusivity, then it could exhibit unpredictable behavior, including crashes or
  memory corruption." High confidence this is Apple's own stated position — treat this flag
  as a last-resort, narrowly-scoped optimization (e.g. only on a hand-audited hot function),
  not a blanket project setting.
- **`-Ounchecked`**: not independently re-fetched this session (the swift.org URL guessed for
  it 404'd) — medium-confidence recollection from established Swift documentation: it removes
  integer overflow traps, array-bounds-check traps, and force-unwrap/precondition traps in
  addition to whatever exclusivity setting is combined with it. The project's own spike
  (RESULTS.md #3) measured `-Ounchecked` changing *representation* cost negligibly (A 0.55→0.69s anomaly noted, B 0.10→0.13s, C 0.02→0.015s) — i.e. on this workload the checks
  removed by `-Ounchecked` were not the bottleneck; ARC was. This is a useful empirical
  correction to the intuition that `-Ounchecked` is a major lever: **it is not**, for
  value-representation-bound code; it matters more for tight numeric kernels doing bounds-
  checked array indexing (e.g. a rope/gap-buffer inner loop), which this project has not yet
  measured. **Unverified**: exact quantified effect of `-Ounchecked` on a buffer-indexing
  loop specifically — flagged as a follow-up spike, not asserted here.
- **Whole-module optimization (WMO)**: confirmed by OptimizationTips.rst as enabling
  cross-file devirtualization and specialization within a module ("place generic
  declarations in the same module as usage, or use `-whole-module-optimization`"). High
  confidence, primary source.
- **`package` access level** (SE-0386, implemented Swift 5.9, fetched): lets a symbol be
  visible across module boundaries *within a package* without becoming fully `public`, and
  crucially "a package can be treated as a resilience domain" where modules "will always be
  rebuilt together and do not require a resilient ABI boundary between them" — this removes
  the ABI-resilience overhead (opaque/indirect access patterns) that `public` API in a
  resilient library would otherwise pay. `@inlinable package` functions let
  `@usableFromInline package` symbols be inlined across module boundaries in the same
  package. **Practical implication for swiftemacs**: split the interpreter into a few
  modules (e.g. `LispCore`, `LispBuiltins`, `EditorCore`) inside one Swift package rather
  than one giant module, using `package`/`@inlinable package` for the hot cross-module
  calls (value construction, eval dispatch), to get WMO-like inlining without giving up
  modular structure. Confidence: high (direct proposal text).
- **`@_transparent`**: standard Swift attribute (not independently re-fetched) forcing
  unconditional inlining before diagnostics/optimization, stronger than `@inlinable`, used
  in the standard library itself for things like arithmetic operators. Medium confidence
  (well-established but not re-verified this session) — appropriate for the smallest,
  hottest leaf functions in the value representation (tag extraction, pointer arithmetic on
  the arena) where even a normal-inlined call has measurable overhead.

## 4. Existential/protocol dispatch costs and generic specialization

Primary source: `apple/swift` `docs/OptimizationTips.rst` (fetched). It frames the
generics-vs-protocol tradeoff directly:

> "The Swift compiler emits one block of concrete code that can perform `MySwiftFunc<T>` for
> any `T`... Any differences in behavior... are accounted for by passing a different table
> of function pointers" — i.e. generics compile to a single body plus witness-table
> parameter-passing, and when the concrete type is statically known **and visible to the
> optimizer**, the compiler specializes: "If the generic function's definition is visible to
> the optimizer and the concrete type is known, the Swift compiler will emit a version of the
> generic function specialized to the specific type." This requires the generic's definition
> to be in the same module (or WMO/package-inlinable) as the call site — reinforcing the §3
> module-layout recommendation.

- The document did **not** (in the fetched excerpt) give the existential container's inline
  buffer size or boxing threshold in bytes — **unverified this session**. Well-established
  Swift knowledge (medium confidence, not re-confirmed by fetch) is that an existential
  (`any Protocol`) value has a fixed-size inline buffer (historically 3 machine words) and
  spills to a heap box when the concrete type is larger, plus carries witness-table/type-
  metadata pointers alongside — meaning `any LispValue`-style existentials would both risk
  heap boxing *and* pay indirect witness-table calls per operation, on top of whatever ARC
  the boxed payload needs. For a hot value type, this argues against protocol existentials
  and for a concrete enum/tagged representation, consistent with the spike's own finding.
- Class-only protocols (`protocol P: AnyObject`) get "special treatment" per the doc: the
  optimizer can assume every conformer is a class and reason about it more precisely
  (relevant if some interpreter subsystem — e.g. pluggable built-ins — is protocol-based by
  design; constraining it to class-only reduces the optimizer's uncertainty).

**Guidance**: keep the core `LispValue` representation a concrete enum/tagged word, never an
existential; reserve protocols for genuinely pluggable, cold-path extension points (e.g. a
`BuiltinFunction` registry can be protocol-based without hurting eval-loop throughput, since
each call there is already crossing a function-call boundary).

## 5. Copy-on-write (CoW) containers in interpreters

From the same primary source:

> "The easiest way to implement copy-on-write is to compose existing copy-on-write data
> structures, such as Array." For a custom CoW type, use `isKnownUniquelyReferenced`:

```swift
var value: T {
  get { return ref.val }
  set {
    if !isKnownUniquelyReferenced(&ref) {
      ref = Ref(newValue)
      return
    }
    ref.val = newValue
  }
}
```

Implication for an editor core: if buffer text or a large environment/obarray is represented
as a Swift `Array`/`String`/`Dictionary` (all CoW), every mutation implicitly does an
`isKnownUniquelyReferenced` check plus a possible full-buffer copy on first write after a
share (e.g. after undo snapshotting or multiple-cursor operations aliasing the buffer).
For a gap buffer or rope specifically, this argues for **not** using stock `Array<UInt8>` as
the storage once buffers get large and are shared/snapshotted often (undo, autosave, LSP
sync) — either wrap a manually-managed arena (own `isKnownUniquelyReferenced` check on a
custom class, same pattern) or design the undo/snapshot representation so it doesn't force
uniqueness checks in the hot typing path. This is inference from the documented pattern, not
independently benchmarked in this session — flagged medium confidence for the buffer-specific
conclusion, high confidence for the CoW mechanism itself (directly quoted primary source).

## 6. String performance

Primary source: swift.org blog "Swift 5's UTF-8 String implementation" (fetched):

- Swift 5+ uses a **single internal UTF-8 representation** (previously UTF-16/ASCII were
  separate), with forms: large strings (heap, tail-allocated), **small strings** (content
  packed inline in the struct, up to 15 UTF-8 code units on 64-bit, no allocation — extended
  in Swift 5 to cover non-ASCII, e.g. `"smol 🐶! 😍"` fits inline), indirect strings (bridged
  foreign backing via resilient calls), and opaque strings (fully resilient future-proofing
  form).
- Measured real-world win cited in the post: "SwiftNIO saw a 20% speed improvement when
  serving up the homepage of swift.org by just upgrading to Swift 5, due to skipping
  [UTF-16] transcoding" — high confidence, directly quoted, though it is a networking
  workload, not an editor/interpreter one.
- UTF-8 is called out as "the *ideal* representation" for scanning ASCII-metacharacter-heavy
  text (exactly the shape of Lisp-reader / mode-line / syntax-table scanning), because such
  scans can walk raw UTF-8 bytes and only need decoding on the rare non-ASCII run.
- The post did **not** give a quantitative comparison of `String.UTF8View` vs
  `UnicodeScalarView` vs (grapheme-cluster) `String` iteration cost — **unverified this
  session**. Well-established Swift knowledge (medium confidence): grapheme-cluster
  iteration (`for c in someString`) is the most expensive of the three because it must run
  full Unicode grapheme-breaking; `unicodeScalars` avoids grapheme breaking but still
  decodes UTF-8 to scalars; `utf8` is a near-zero-cost view over the underlying storage's
  bytes (a contiguous buffer walk for native/large strings). **Guidance**: an Elisp reader,
  a syntax-table scanner, and a gap-buffer's byte-offset arithmetic should all operate on
  the `utf8` view (or a raw byte buffer, §9), reserving grapheme-cluster-aware String APIs
  for cursor motion / display-column computation where grapheme correctness genuinely
  matters (this matches how Reticle presumably had to draw a similar line in Rust, though
  that comparison was not independently checked this session).

## 7. Swift 6 strict concurrency and an interpreter thread

- **`nonisolated(unsafe)`** (SE-0412, implemented Swift 5.10, default-on in Swift 6 mode,
  fetched): opts a global or local var out of static isolation checking "to enable the
  developer to rely upon their own data isolation management, such as with an associated
  global lock." The proposal itself warns that without correct manual synchronization,
  "dynamic run-time analysis from exclusivity enforcement or tools such as Thread Sanitizer
  could still identify failures" — i.e. this attribute removes only the *compile-time*
  check, not runtime exclusivity/TSan detection of an actual race. High confidence, direct
  quote. Relevant if the interpreter's obarray/global environment lives on a single
  dedicated interpreter thread and is touched from elsewhere (e.g. UI) only through an
  explicit queue — `nonisolated(unsafe)` plus a hand-rolled single-writer discipline is the
  documented sanctioned escape hatch, not a workaround being fought against.
- **Custom actor executors** (SE-0392, implemented Swift 5.9, fetched): lets an `actor`
  bind itself to a specific execution context via `SerialExecutor` (`enqueue(_:)`,
  `asUnownedSerialExecutor()`), enabling patterns like "pinning actors to the main thread"
  or, by extension, pinning an "interpreter actor" to one dedicated OS thread rather than
  letting the concurrency runtime schedule its jobs onto the general cooperative thread
  pool. This is directly relevant: an Elisp interpreter with re-entrant dynamic-binding
  stacks and a step counter (per the mini-interpreter spike) wants to run on **one
  consistent thread**, not be hopped between threads by the default executor — a custom
  `SerialExecutor` bound to one pthread is the documented way to get that guarantee inside
  Swift's actor model rather than bypassing it with raw `DispatchQueue`/pthread code that
  strict concurrency can't reason about.
- **Isolated deinit** (SE-0371, implemented Swift 6.2, fetched): lets `deinit` on an actor
  or global-actor class access isolated state safely, running on the actor's executor; the
  proposal explicitly warns isolated deinits "must potentially be enqueued and executed
  'later' rather than directly inline," making them "unsuitable for managing scarce
  resources like file descriptors, where predictable cleanup timing is critical." Direct
  relevance: if cons cells / interpreter values are ever represented as actor-isolated
  classes (not recommended for the hot path per §1-2, but relevant for any actor-owned
  subsystem, e.g. an LSP client actor or a background-indexer actor), do not rely on
  isolated `deinit` timing for anything resource-critical — use explicit `close()`/teardown
  methods instead, matching the exact workaround SE-0371 itself describes projects using
  before the feature existed.
- **General framing (medium confidence, not independently re-verified beyond the two
  proposals above)**: Swift 6 strict concurrency's data-race checking is a compile-time
  discipline over sendability of *types crossing isolation domains*; it should have
  approximately zero runtime cost for code that stays within one isolation domain (e.g. the
  entire interpreter hot loop running unisolated/actor-isolated on its own thread, never
  passing raw mutable interpreter state across an `await` boundary). The cost model to
  design around is: keep the eval loop's live state (register file, dynamic-binding stack,
  the arena) inside one isolation domain and only cross domains with small,
  Sendable messages (a submitted form, a resulting value, a cancellation token) — this is
  the same "single-writer thread with a mailbox" shape recommended independent of Swift's
  concurrency model, but here it is also the shape Swift 6 checking pushes you toward
  for free.

## 8. Swift/C and C++ interop for hot kernels

Primary source: swift.org C++ interoperability documentation (fetched):

- C++ functions, member functions, constructors, `struct`/`class` (mapped to Swift structs
  by default), enums, templates (concrete instantiations only), and standard-library types
  (`std::string`, `std::optional`, `std::function`, containers) are callable directly from
  Swift; Swift types (functions, structs, classes, enums, `String`/`Array`/`Optional`) are
  exposed to C++ symmetrically. Enable via `-enable-cxx-interop` (automatic for SPM/Xcode
  C++ targets).
- **Explicit performance caveat, directly quoted**: "Swift currently does not provide
  explicit performance guarantees when using C++ containers that conform to
  `RandomAccessCollection`. Swift will most likely make a deep copy of the container" in a
  `for-in` loop or with sequence methods like `filter` — the documented workaround is to use
  `forEach`, pass containers via `inout`, or use subscript access, to avoid the copy. High
  confidence, direct quote — **important pitfall** if any plan involves wrapping a C++
  container (e.g. a third-party rope or tree-sitter's C structures) and iterating it the
  "natural" Swift way.
- Limitations noted: no C++20 modules import, no virtual methods on C++ value types, raw
  pointer/reference-returning APIs are exposed only via unsafe (`__`-prefixed,
  `Unsafe`-suffixed) wrappers, C++ iterators should be avoided from Swift.
- **Plain C interop** (not re-verified this session, but foundational and stable Swift
  knowledge, high confidence): C headers import directly with no interop flag needed;
  `UnsafeMutablePointer`/`UnsafeRawPointer` bridge to C pointers with no ARC or bounds-check
  overhead, making a thin C shim the lowest-friction way to reach a hand-tuned kernel (e.g.
  SIMD-ish byte-scanning, or the `sys_icache_invalidate` call the JIT spike already needed a
  `@_silgen_name` shim for, per RESULTS.md #1 — direct evidence from this project's own
  spike that some system calls are not exposed to Swift and need a thin C/`@_silgen_name`
  bridge).

**Guidance**: prefer plain **C** (not C++) for any hand-written hot kernel that needs to be
called from Swift with zero interop ceremony and no risk of an implicit container copy —
C++ interop is more useful for *consuming an existing C++ library* (e.g. if a future
tree-sitter-adjacent or ICU-adjacent dependency is C++) than for authoring new hot-path code,
where a small `.c`/`.h` pair exposed via a Swift module map is simpler and has fewer
surprising-copy footguns than the C++ bridge.

## 9. Garbage-collector implementation concerns in Swift

**This section is the weakest-sourced** — WebSearch was unavailable for the entire session
after the third query, and a targeted forum-thread fetch (guessed URL) returned an unrelated
PowerPC CI thread rather than the intended discussion. Everything below is therefore
**medium-to-low confidence, general Swift/runtime knowledge, not verified by fetch this
session** — flagged explicitly per the ground rules rather than presented as fact:

- Swift has **no general tracing garbage collector**; memory management is ARC (reference
  counting) for classes plus, since the noncopyable-types work (§1), single-ownership value
  types. Building an actual mark-and-sweep or copying GC for Lisp values *on top of* Swift
  means Swift's own runtime is not a tool that helps — you'd be writing a GC in Swift the
  same way you'd write one in C, using `UnsafeMutableRawPointer` arenas that are invisible
  to ARC (this is consistent with, and was the design direction implied by, the spike's
  representation-C tagged-word/arena approach; RESULTS.md itself calls this "the
  performance ceiling" and "the swap later is the whole engine").
  - **Precise roots without stack scanning**: because Swift does not expose stack-map/root
    metadata the way a GC-aware runtime (JVM, CLR, Go) does, a Lisp GC written in Swift
    cannot conservatively-or-precisely scan the *native Swift call stack* for roots the way
    Go's runtime scans goroutine stacks. The practical consequence (my inference, not a
    verified Apple statement): roots must be tracked **explicitly** — a handle stack /
    shadow stack that the interpreter itself pushes/pops as it evaluates, mirroring how
    e.g. CPython's GC or a hand-rolled Scheme VM in C tracks roots — rather than relying on
    any host-language stack-scanning facility, because none exists for arbitrary Swift
    frames. This should be treated as an architectural assumption to validate with a small
    spike (e.g., confirm there is no public API for stack root enumeration) before
    committing, not as confirmed fact.
  - **The optimizer moving/copying references**: Swift class references are pointers to a
    fixed heap allocation and the object does not move (Swift is not a compacting-GC
    language for its own ARC objects), so a *simple* non-relocating mark-sweep collector
    layered on a manual arena does not have to worry about "the optimizer moved my object
    out from under a raw pointer" in the way a relocating collector would. However, if the
    tagged-word arena design (§1) is later evolved into a *moving/compacting* collector for
    density, every live pointer to arena slots (including ones held via `Unmanaged`/raw
    pointers per §2) must be one of the explicitly-tracked roots above, since nothing in
    Swift will fix up an `UnsafeMutablePointer` after a move — this is a direct consequence
    of using raw pointers (well-established: raw/unsafe pointers are opaque values to
    Swift, never adjusted by anything), not something specific to Swift's optimizer.
  - **Unsafe pointers hidden from ARC**: confirmed indirectly by OptimizationTips.rst's own
    `Unmanaged`-based examples (§2) — the documented pattern already relies on the fact
    that `Unmanaged`/raw-pointer access is invisible to ARC bookkeeping. This is a two-edged
    tool for a GC author: it's exactly what you want for a manually-collected arena (ARC
    won't fight the collector over ownership of arena-internal pointers), but it means the
    GC gets **zero help** from ARC for its own arena contents — cross-arena references need
    the GC's own liveness tracking end to end.

**Bottom line for §9 (explicitly qualified)**: writing a real GC in Swift is architecturally
the same problem as writing one in C — Swift's runtime provides no scaffolding (no root
enumeration, no relocation support, no write barriers) for a *second*, Lisp-level collector;
you get a clean substrate (raw arenas untouched by ARC) but no assistance. This matches the
spike's own conclusion that the tagged-word/arena design is "the swap later is the whole
engine" — i.e., this is recognized in the project's own prior work as a large, self-contained
undertaking, not a small delta.

## 10. Known benchmarks of interpreters written in Swift

**Unverified / not found this session.** WebSearch access was lost after 3 queries (session-
wide budget exhausted) before any targeted search for "Swift Lisp/Scheme interpreter
benchmark" could run, and a DuckDuckGo HTML fetch attempt was blocked by a CAPTCHA page
rather than returning results. I have **no verified external benchmark** of a Lisp/Scheme/
similar interpreter written in Swift to report, and explicitly did not fabricate one. The
only concrete Swift-interpreter timing available to this report is this project's own spike
(`../spikes/RESULTS.md` #4: ~120 ns/iteration, 2.37-2.46s for a 20M-iteration loop-sum, vs
Reticle's Rust tree-walker at 9.59s and bytecode VM at ~1.2s for the same form) — cited
there, not repeated in full here. Treat "known external Swift interpreter benchmarks" as an
open research gap for a future pass with WebSearch available, not as covered by this report.

## 11. Conclusion: what should be pure Swift, what should drop to unsafe Swift, and whether any part should be C

| Layer | Recommendation | Confidence / basis |
|---|---|---|
| Cons cells / `LispValue` representation | Tagged 64-bit word + manual `UnsafeMutableRawPointer` arena (spike rep C) | High — directly measured (27x/5x/1x) |
| GC over that arena | Hand-written in Swift using raw pointers + an explicit root/handle stack; no reliance on stack scanning | Medium — architectural inference, flagged as unverified assumption to spike-test |
| Eval-loop dispatch, symbol table, dynamic-binding stack | Pure Swift, `final` classes / concrete enums, single module or `package`-scoped with `@inlinable package`, WMO on | High — OptimizationTips.rst + SE-0386, primary sources |
| Built-in function registry (cold/pluggable path) | Protocol-based is acceptable here; keep it `AnyObject`-constrained if class-based | Medium-high — OptimizationTips.rst on class-only protocols |
| Buffer text storage (gap buffer / rope) | Not stock CoW `Array`/`String` once buffers are large and frequently snapshotted (undo/autosave/LSP sync); manual arena or custom `isKnownUniquelyReferenced`-gated CoW | Medium — inferred from documented CoW mechanism, not independently benchmarked |
| Lexing/reading/syntax scanning | Operate on `String.utf8` view / raw bytes, not grapheme-cluster `String` iteration | Medium-high — swift.org UTF-8 blog's "ideal representation for ASCII metacharacter scanning" framing |
| Interpreter execution thread | Single dedicated thread; if modeled as a Swift actor, give it a custom `SerialExecutor` bound to that thread rather than the default cooperative pool; guard genuinely shared globals with `nonisolated(unsafe)` + explicit discipline | High — SE-0392, SE-0412 primary sources |
| Any actor/class holding resources whose teardown timing matters | Explicit `close()`, not `isolated deinit` | High — SE-0371 explicitly warns about this |
| JIT machine-code emission, `sys_icache_invalidate` and similar syscalls not exposed to Swift | Thin C shim / `@_silgen_name`, as already required by this project's own JIT spike | High — RESULTS.md #1, this project's own measurement |
| Wrapping any future C++ dependency (e.g. a C++ tree-sitter binding) | C++ interop is fine for *consuming* it, but iterate via `forEach`/`inout`/subscript, never plain `for-in`/`filter`, to avoid the documented implicit deep-copy | High — swift.org C++ interop docs, direct quote |
| New hand-written hot kernels needing zero-ceremony calling | Plain **C**, not C++ — simpler ABI, no container-copy footgun, matches the JIT spike's own C-shim need | Medium-high |
| `-Ounchecked` / `-enforce-exclusivity=unchecked` project-wide | **Do not** set project-wide; Apple's own docs call disabling exclusivity checks in release "strongly discouraged," and this project's own spike shows `-Ounchecked` did not move the needle on the ARC-bound workload. Reserve for a specific, hand-audited hot function if a *future* spike shows a real win (e.g. buffer-indexing) | High for the "don't blanket-enable" guidance (primary source + own spike); explicitly unverified for any specific future win |

### Must / Should / Could

**Must:**
- Use a tagged-word + manual-arena value representation for `LispValue`, not an indirect
  enum or existential (confirmed by measurement + OptimizationTips.rst).
- Keep the eval loop, symbol table, and dynamic-binding stack single-module/package-scoped,
  `final`, with WMO on.
- Run the interpreter on one dedicated thread/executor; never let default actor scheduling
  hop it between threads mid-evaluation.
- Use plain C (with `@_silgen_name` where needed) for any syscall or hand-tuned kernel not
  exposed to Swift, following the pattern the JIT spike already required.

**Should:**
- Model buffer storage and any large shared data structure with an eye to CoW's
  `isKnownUniquelyReferenced` cost under undo/snapshot sharing; avoid stock `Array`/`String`
  for the hottest buffer-mutation path if a future spike shows it matters.
- Use `String.utf8`/raw bytes for lexing, syntax scanning, and Lisp-reader work; reserve
  grapheme-aware `String` APIs for cursor/display logic.
- Use `package`/`@inlinable package` access to split the interpreter into a few modules
  without losing cross-module inlining.
- Bind any actor holding resources with must-be-prompt teardown to explicit `close()`
  methods rather than `isolated deinit`.

**Could:**
- Reach for `Unmanaged`/`unowned(unsafe)`/raw-pointer traversal in additional hot loops
  beyond cons traversal, if profiling after the core arena design lands still shows ARC
  pressure elsewhere (e.g. a hot closure-capture path).
- Explore `~Copyable` types for single-owner interpreter subsystems (e.g. a per-thread
  scratch buffer or the arena-slab owner itself), not for generally-aliased Lisp values.
- Revisit `-Ounchecked` narrowly, only after a targeted spike on a bounds-check-heavy buffer
  kernel shows a measurable win — not as a default build setting.

### Key pitfalls (all cross-referenced above, collected here)

1. Existential/protocol types (`any LispValue`-shaped design) risk both heap boxing and
   witness-table dispatch — do not use for the core value type.
2. C++ container iteration via `for-in`/`filter` from Swift can silently deep-copy — a real
   correctness-adjacent performance trap if a future C++ dependency (e.g. tree-sitter C++
   bindings, if ever used instead of the C API) is wrapped naively.
3. `isolated deinit` timing is non-deterministic — never rely on it for resource cleanup.
4. Disabling exclusivity enforcement or using `-Ounchecked` project-wide is against Apple's
   own guidance and, per this project's own spike, does not address the actual bottleneck
   (ARC), only masks a different, smaller set of costs.
5. A Lisp-level GC gets no scaffolding from Swift's runtime (no stack-root scanning, no
   relocation support) — this is a from-scratch systems-programming undertaking inside
   Swift, not a "use a Swift feature" task; budget it as such.

### Unverified claims (explicitly, collected)

- Exact quantified runtime cost of exclusivity checking (Apple's own post declines to give a
  number).
- Exact behavior/overhead of `-Ounchecked` beyond what this project's own spike measured
  (which showed no material effect on the ARC-bound workload tested; effect on a
  bounds-check-bound workload is untested).
- Existential container inline-buffer size / exact boxing threshold in current Swift
  (medium-confidence recollection, not re-confirmed by fetch this session).
- `String.UTF8View`/`UnicodeScalarView`/grapheme-iteration relative costs (no quantitative
  primary source found this session; qualitative ordering only, from general knowledge).
- Whether Swift exposes any public API for stack-based GC root enumeration (assumed "no"
  based on general knowledge of the runtime's design goals; not confirmed against current
  runtime source this session — recommend a dedicated spike or Swift-runtime-source read
  before committing to the "explicit root stack" GC architecture).
- No verified external benchmark of a Lisp/Scheme interpreter written in Swift was found
  (WebSearch was unavailable for essentially the whole session); the only Swift-interpreter
  number in this report is the project's own spike.
- `unowned(unsafe)` and plain C interop semantics above are stated from general Swift
  knowledge, not re-fetched from current documentation this session.

---

*Sources fetched directly this session (primary sources, all high-confidence for the quoted
content):*
- [SE-0390 Noncopyable Structs and Enums](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0390-noncopyable-structs-and-enums.md)
- [SE-0447 Span](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md)
- [SE-0453 InlineArray](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0453-vector.md)
- [SE-0386 Package Access Modifier](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0386-package-access-modifier.md)
- [SE-0371 Isolated Synchronous Deinit](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0371-isolated-synchronous-deinit.md)
- [SE-0412 nonisolated(unsafe) / Strict Concurrency for Global Variables](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0412-strict-concurrency-for-global-variables.md)
- [SE-0392 Custom Actor Executors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md)
- [Swift 5 Exclusivity Enforcement (swift.org blog)](https://www.swift.org/blog/swift-5-exclusivity/)
- [Swift/C++ Interoperability (swift.org)](https://www.swift.org/documentation/cxx-interop/)
- [Swift 5's UTF-8 String implementation (swift.org blog)](https://www.swift.org/blog/utf8-string/)
- [apple/swift OptimizationTips.rst](https://github.com/apple/swift/blob/main/docs/OptimizationTips.rst)
- [apple/swift HighLevelSILOptimizations.rst](https://github.com/apple/swift/blob/main/docs/HighLevelSILOptimizations.rst) (low yield — mostly `@_semantics` container optimizations, not ARC/exclusivity)

*Fetch attempts that failed or were off-target (noted for transparency):* a swift.org blog
URL guessed for `-Ounchecked`/Swift 6 mode details (404); a guessed Swift Forums thread URL
intended for GC/stack-scanning discussion (returned an unrelated PowerPC CI thread); a
DuckDuckGo HTML search (blocked by CAPTCHA, no results obtained). WebSearch itself returned
"session budget exhausted" after 3 queries early in this run and was unavailable for the
remainder.
