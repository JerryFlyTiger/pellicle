# Extreme Performance and Power Efficiency for a macOS Editor (Apple Silicon), and Long-Session Stability

Topic key: perf-power. Companion to `apple-text-rendering.md` (frame pacing already covered
there in section 3 — not repeated here, only cross-referenced) and `spikes/RESULTS.md` (JIT,
value representation, interpreter micro-benchmarks — not repeated here).

Research budget used: 16 WebFetch calls (WebSearch was globally exhausted for this session
before this agent started, per CONTEXT.md). Apple's plain `developer.apple.com/documentation/...`
reference pages return only their page title to WebFetch (JS SPA shell) — confirmed again this
session (`coreservices/file_system_events`, `ConcurrencyProgrammingGuide` archive page partially
worked). Apple's **archived** Performance-guide pages
(`developer.apple.com/library/archive/documentation/Performance/...`) and **WWDC video pages**
(`developer.apple.com/videos/play/wwdcNN/NNN/`) both returned full transcript/prose content and
are the highest-quality primary sources below. Several WWDC session-number guesses missed
(wrong session at that number, or a 404 "no video found" for WWDC13); those misses are not
listed as sources. Confidence is marked per claim; a dedicated "Unverified" section closes the
report.

---

## 1. Draw-only-on-change and idle CPU (cross-reference — see apple-text-rendering.md §3)

Not duplicated here. That section covers `CADisplayLink`/`NSView.displayLink`, pausing on no
damage, and `preferredFrameRateRange` for ProMotion (confidence: medium, unverified against a
live Apple reference page this session). This report's own primary-source find that reinforces
the same pattern from a shipping competitor:

- **Zed's GPUI Metal pipeline** (`zed.dev/blog/120fps`, Feb 2024, high confidence — primary
  source, engineering blog by the authors): renders conditionally on a dirty flag
  (`if dirty.get() { cx.draw(); cx.present(); }`), and **deliberately keeps presenting the
  current (unchanged) frame for one extra second after the last input** — not to redraw, but
  "to prevent the display from underclocking" (ProMotion ties refresh rate to sustained
  content changes; an abrupt drop to a fully idle/paused loop right at the last keystroke can
  make the *next* keystroke arrive while the display is still at a low rate, adding latency).
  They also moved from a single Metal instance buffer to a **pool of instance buffers** to
  avoid CPU/GPU race conditions without blocking, and replaced `wait_until_completed` with
  `wait_until_scheduled` and ultimately no CPU-side wait at all before `present_drawable` +
  `commit`, letting the GPU pipeline frames instead of the CPU stalling on each one.
  **Actionable pattern for pellicle**: don't binary-switch "damage → 120 Hz, idle → paused
  link" — add a short (≈1 s) linger period at the previous frame rate after the last input
  before dropping to idle, and use a small pool of reusable GPU buffers (glyph instance
  buffers, vertex buffers) rather than a single buffer guarded by a CPU wait.

## 2. Timer coalescing and leeway

Source: Apple's archived Energy Efficiency Guide, "Minimize Timer Use" page (high confidence —
primary source, full text retrieved):

- **`NSTimer.tolerance`**, **`dispatch_source_set_timer`'s leeway parameter**, and
  **`CFRunLoopTimerSetTolerance`** all do the same thing: they tell the system "this timer may
  fire anywhere between its scheduled fire date and (fire date + tolerance), never earlier."
  The system uses that slack to **coalesce multiple apps'/subsystems' timers to fire together**,
  which "dramatically increases the amount of time the processor spends idling" (quoted).
- **Recommended tolerance: at least 10% of the timer's interval.** Example given: a 3.0 s
  interval → 0.3 s tolerance; a `dispatch_source_set_timer` 1-second interval →
  `NSEC_PER_SEC / 10` leeway.
- Consequence for pellicle: **every recurring, non-input-latency-critical timer** (cursor
  blink, autosave, idle-triggered background reparse trigger, periodic UI polish like a
  "saved" indicator fade) must be created with an explicit ≥10% tolerance/leeway. The only
  timers that should have zero/near-zero tolerance are ones on the direct keystroke-to-pixel
  path, and even those should ideally not be timers at all (driven by the paused/resumed
  display link instead, per §1 and apple-text-rendering.md §3).

## 3. QoS classes and background parse/index scheduling

Confidence: high on the enum semantics and general GCD priority-inheritance mechanism
(long-standing, stable Apple public API, consistent across multiple sources including a
partially-fetched Apple concurrency doc this session — that fetch mostly returned only the
legacy `DISPATCH_QUEUE_PRIORITY_*` constants, not the QoS-class prose, so the QoS-class
specifics below are from general/training knowledge, not a freshly quoted primary source this
session — mark medium on exact wording, high on the architecture recommendation, which is also
independently reinforced by the WWDC21 Swift Concurrency transcript in §4):

- **QoS classes, in priority order**: `.userInteractive` (UI event handling, animation — must
  complete in well under a frame), `.userInitiated` (work the user is actively waiting on, e.g.
  "open this file"), `.default` (unspecified — inherits ambient), `.utility` (long-running work
  with progress, not time-critical — exactly the class for a background parser/indexer),
  `.background` (invisible maintenance work with no user-visible deadline — e.g. a nightly
  "reindex everything" pass, log rotation).
- **Priority inversion**: a lower-QoS task holding a resource a higher-QoS task needs causes the
  system to temporarily boost the lower task (GCD/kernel-level QoS propagation) — but this only
  works cleanly for **actual resource contention** (locks, actor isolation), not for raw CPU
  contention on oversubscribed cores. On Apple Silicon's asymmetric P/E-core scheduler, a
  `.background`/`.utility` task is preferentially placed on E-cores; a `.userInteractive` task
  preferentially gets P-cores — this is the actual mechanism that keeps a background
  parse/index job from starving keystroke handling, more so than priority alone.
- **Concrete scheduling rule for pellicle's background parser/indexer**: run it as
  `.utility` QoS work (not `.background`, unless it is truly invisible maintenance with no
  bearing on the current file's semantic highlighting), on a dedicated serial or low-concurrency
  `DispatchQueue`/`Task` — never inheriting `.userInteractive` by accidentally being invoked
  from a main-actor call site. It must never take a lock that the input-handling / rendering
  path also takes without that lock being extremely short (µs-scale) and held at matching or
  higher QoS to avoid priority inversion. Cancel in-flight parse/index work on every new
  keystroke-driven edit rather than letting stale results race the fresh input (this also
  bounds memory and avoids wasted CPU/energy on discarded work, tying into §12 incremental
  design).
- `taskpolicy(8)` (confirmed present and read locally, `man taskpolicy`, high confidence —
  primary source, local man page) is the command-line lever for the *process-wide* QoS clamp
  (`-c utility|background|maintenance`), useful for **soak-testing** the app under an externally
  imposed low QoS ceiling to verify it degrades gracefully, and for launching a helper
  subprocess (e.g. an LSP server, a Verilog compiler front-end) already clamped to
  utility/background so it can never compete with the editor's own input path even if it
  misbehaves. Not something to invoke on your own process at runtime — that's what
  `DispatchQueue`/`Task` QoS + `Thread.qualityOfService` are for — but a very useful **test
  harness** tool (see §16).

## 4. Swift Concurrency executors and main-actor hops

Source: WWDC21 "Swift concurrency: Behind the scenes" transcript, `developer.apple.com/videos/
play/wwdc2021/10254/` (high confidence — primary source, full transcript retrieved and quoted):

- Swift Concurrency runs on a **cooperative thread pool** sized to the number of CPU cores
  (quoted: "The new thread pool will only spawn as many threads as there are CPU cores, thereby
  making sure not to overcommit the system"), explicitly fixing GCD's thread-explosion failure
  mode where blocking work items caused unbounded thread creation.
- **Hopping between two non-main actors on the cooperative pool is cheap**: the runtime directly
  suspends the current work item and hands it to the target actor without blocking a thread or
  necessarily switching OS threads at all (quoted: "the thread did not block while hopping
  actors... hopping did not require a different thread").
- **Hopping to/from `@MainActor` is comparatively expensive**: the main actor represents the
  real main thread (not a pool thread), so every hop is a genuine context switch. Quoted
  directly: "Each iteration of the loop requires at least two context switches: one to hop from
  the main actor to the database actor and one to hop back... If your application spends a
  large fraction of time in context switching, you should restructure your code so that work
  for the main actor is batched up."
- **Actionable rule for pellicle**: any per-keystroke or per-line hot path that touches both
  background work (parsing, LSP round-trips, syntax highlighting) and UI state must **batch**
  the main-actor crossings — compute a whole result array/diff off the main actor, then do a
  single `await MainActor.run { applyAll(results) }` rather than hopping back to main once per
  token/diagnostic/line. This is the single most concrete, highest-confidence Swift-specific
  performance rule this report can offer, because it is Apple's own stated design rationale, not
  an inference.
- Actors are **reentrant** — a suspended work item does not block newer work items on the same
  actor, which helps priority inversion but means actor state must not assume atomicity across
  `await` points (an editor's buffer/document actor must re-validate state after any `await`,
  e.g. that the cursor/selection or the file version is still what it expected before applying a
  result computed asynchronously — classic "stale async result" bug class, worth a standing code
  rule: version-stamp every document mutation and check the stamp before applying background
  results).

## 5. App Nap

Source: Apple's archived macOS Power Efficiency Guidelines, "App Nap" page (high confidence —
primary source, quoted text retrieved this session):

- **Trigger conditions (all must hold)**, quoted: app "isn't the foreground app," "hasn't
  recently updated content in the visible portion of a window," "isn't audible," "hasn't taken
  any IOKit power management or NSProcessInfo assertions," and "isn't using OpenGL."
- **Effects include timer throttling** — quoted: "Timer throttling, which reduces the frequency
  with which the app's timers are fired." (The page's fetched excerpt did not surface the CPU
  throttling / I/O throttling details verbatim; treat those as **medium confidence** from
  general Apple documentation knowledge, not re-quoted this session.)
- **Opt-out mechanism**: `NSProcessInfo.beginActivity(options:reason:)` /
  `ProcessInfo.performActivity(options:reason:)` with `NSActivityOptions` such as
  `.userInitiated`, `.background`, `.idleSystemSleepDisabled`, `.suddenTerminationDisabled` — the
  archived page names the mechanism ("IOKit power management or NSProcessInfo assertions") but
  the exact option-flag semantics were **not** re-confirmed against a live source this session;
  mark **medium confidence** for the specific flag names (they are stable, long-shipped API, but
  not re-quoted here).
- **Consequence for pellicle, given it is a Metal-rendered app**: "isn't using OpenGL" implies
  a Metal-backed window is *not* automatically exempt the way an OpenGL one historically was —
  App Nap can still throttle a backgrounded Metal-rendering editor window. That is almost
  certainly the **desired** behavior here (a backgrounded editor should nap — it is not doing
  useful work), but it means: (a) do not rely on "we use Metal so we're exempt" as an
  implicit assumption anywhere in the design; (b) any activity that legitimately must continue
  while backgrounded — a long compile/test run launched via `M-!`/`compile`, a background
  index build the user is watching progress of, a running shell in the iTerm2-style terminal
  pane — must explicitly wrap itself in a `beginActivity`/`endActivity` pair with a QoS-and-user-
  intent-appropriate `NSActivityOptions`, or it will be silently throttled the moment the window
  loses focus, which for a terminal-emulating app would be a serious correctness/UX bug (a
  backgrounded shell must keep making progress).

## 6. Energy measurement tooling

### 6a. `powermetrics` (confirmed locally: `man powermetrics`, high confidence, primary source)

- Present at `/usr/bin/powermetrics`, requires sudo (confirmed in spike RESULTS.md).
- Key flags for the measurement protocol (§16): `-i <ms>` sample interval (default 5000 ms —
  use something finer, e.g. 1000 ms, for a keystroke-adjacent measurement window),
  `-n <count>` sample count, `--show-process-energy` (per-process "energy impact" composite —
  Apple's own doc text warns: "estimated and may be inaccurate — hence they should not be used
  for comparison between devices, but can be used to help optimize apps for energy efficiency" —
  quoted, so use it for **before/after regression comparison on the same machine**, never as an
  absolute number to report externally), `--show-process-qos-tiers`, `--show-process-gpu`,
  `--show-cpu-qos` (per-CPU QoS breakdown — directly useful to verify §3's P/E-core placement
  claim empirically), `--show-process-coalition` (groups helper processes, e.g. an LSP server
  child process, with the parent — important for pellicle since it will spawn language-server
  and shell child processes), `-f plist` for machine-readable output the release script can
  parse and diff run-over-run, `--show-pstates`/`--show-plimits` for detecting thermal throttling
  (P-state ceiling hit) during a soak test.
- SIGINFO triggers an immediate sample without stopping the run — useful for taking a snapshot
  at a specific moment (e.g. right after a large paste) inside a longer soak-test capture.

### 6b. Instruments templates (confirmed locally: `xcrun xctrace list templates`, high confidence)

Relevant templates actually present in this Xcode 26.6 install: **Power Profiler** (the modern
successor to the old standalone "Energy Log" instrument — use this, not a separate "Energy Log"
template, which does not appear in this Xcode's template list, so treat any plan reference to a
distinct "Energy Log" instrument as **outdated naming** — medium confidence that Power Profiler
is its full replacement, since this was inferred from the template list rather than confirmed
against release notes), **Time Profiler**, **Allocations**, **Leaks**, **Animation Hitches**,
**Swift Concurrency** (visualizes actor hops/executor hand-offs — directly validates §4's
batching rule), **System Trace**, **Metal System Trace**, **CPU Counters**, **App Launch**,
**Game Performance** / **Game Performance Overview** (despite the name, these are Apple's
general frame-pacing/hitch-detection templates and are relevant to a 120 Hz text renderer),
**File Activity**, **Network**, **Data Persistence**, **Processor Trace**, **Tailspin** (samples
hung/blocked threads system-wide — useful for catching a runaway or deadlocked background
parser without attaching a debugger).

### 6c. `os_signpost` (source: WWDC18 "Measuring Performance Using Logging,"
`developer.apple.com/videos/play/wwdc2018/405/` — high confidence, full transcript quoted)

- Pattern: `os_signpost(.begin/.end, log:, name:, id:)` for intervals; `OSSignpostID(log:object:)`
  to key an interval to a specific in-flight object (e.g. one background parse job) without
  hand-carrying an ID; `os_signpost(.event, ...)` for a single point in time.
- **Points of Interest**: use `category: "os_signpost_points_of_interest"` and Instruments
  surfaces those automatically in the Points of Interest track without a separate OS Signpost
  instrument — cheap way to annotate "keystroke received," "reparse started/finished,"
  "display link paused/resumed" on every trace without extra Instruments setup.
- **Overhead discipline, quoted**: "We built signpost to be lightweight" — emit-time work is
  minimized by the compiler, and an `OSLog` handle set to `.disabled` makes calls "near no-ops."
  **Actionable rule**: gate expensive-to-compute signpost metadata (not the call itself) behind
  `log.signpostsEnabled`, and consider a build-time or environment-variable switch to fully
  disable signpost logs (`.disabled`) in release builds shipped to users, keeping them live only
  in the owner's own profiling builds — cheap enough to leave compiled in either way, per Apple's
  own guidance, but disabling removes even the near-zero residual cost for a "must be literally
  0% idle" requirement.
- **Recording mode matters**: default "Immediate Mode" bypasses OS-level buffering
  optimizations and adds overhead; for high-volume signposts (thousands/sec — plausible for
  per-glyph or per-token instrumentation) switch Instruments to "Last Five Second"/windowed
  recording mode.

### 6d. MetricKit (source: WWDC20 "What's New in MetricKit," `developer.apple.com/videos/play/
wwdc2020/10081/` — high confidence, full transcript quoted; note this is the iOS-oriented
session, and **MetricKit's availability and payload shape on macOS was not independently
re-confirmed this session — medium confidence that the macOS subset (MetricKit has shipped on
macOS Catalyst/macOS since macOS 12/Monterey per general knowledge) covers hangs, CPU
exceptions, and disk-write exceptions the same way; verify against current macOS MetricKit docs
before relying on it for field telemetry design**):

- Passive, OS-aggregated **24-hour payloads** delivered via `MXMetricManagerSubscriber.didReceive
  (_:[MXMetricPayload])`; **diagnostic payloads** (`didReceive(_:[MXDiagnosticPayload])`) cover
  four categories directly relevant to pellicle's stability goals: **Hangs** (main-thread
  unresponsive, with backtraces), **CPU Exceptions** (sustained high CPU with backtraces —
  exactly the "editor gets hot the longer it runs" failure mode the owner named as unacceptable),
  **Disk Write Exceptions** (excessive writes past a 1 GB/day threshold, with backtraces — would
  catch a runaway autosave/logging loop), and **Crash Diagnostics**.
- **Actionable design implication**: build the MXMetricManagerSubscriber hookup into the app
  from day one (it's nearly free to wire up) even though the owner is currently the only user —
  it gives a standing, zero-instrumentation-effort mechanism for catching exactly the class of
  regression ("got slower/hotter over a session") the project must never ship, and the payloads
  persist locally even without any server/network component (they can be read via
  `MXMetricManager.shared.pastPayloads` for the owner's own machine without needing App
  Store/TestFlight distribution — **medium confidence** on `pastPayloads` being available outside
  a TestFlight/App Store context; verify before depending on it for local-only telemetry).

### 6e. Xcode Energy Gauge

Not independently re-verified this session (no fetch attempted found a live description); from
general knowledge, **medium confidence**: the Xcode debug-navigator Energy gauge shows a
composite score (CPU, network, GPU, disk-driven) while running under the debugger, useful as a
quick real-time glance during manual testing but not a substitute for `powermetrics`/Instruments
for the release gate in §16 (it is not machine-readable/scriptable in the same way).

## 7. Memory growth control

General/training knowledge, medium-high confidence (standard, long-stable Apple/Swift patterns,
not re-verified via fresh fetch this session — the two attempted fetches on QoS/FSEvents docs
returned only titles or generic content, and remaining budget was allocated to higher-value
targets in §2-6):

- **`autoreleasepool { }` around any loop that creates autoreleased Objective-C/AppKit/Core
  Foundation objects per iteration** (NSString/NSAttributedString/CTLine construction during
  batch glyph-run shaping, batch file reads via NSFileManager APIs, etc.) — without it, all
  those objects live until the runloop's own drain point, so a single large batch operation
  (e.g. reflowing a 100k-line file's `CTLine`s) can transiently spike memory far above steady
  state. Swift's own value types don't need this, but every AppKit/CoreText/Foundation call in
  a tight loop does.
  - Nuance worth stating: this is a bounded-memory-during-the-loop technique, not a leak fix —
    autoreleased objects were always going to be freed; the pool just moves *when*. Genuine
    growth-that-never-comes-back needs the retain-cycle tooling below.
- **`NSCache` over a hand-rolled dictionary cache** for anything unbounded-by-nature (glyph
  atlas metadata cache, shaped-line cache, per-file syntax-tree cache, LSP symbol cache):
  `NSCache` auto-evicts under memory pressure (registers for system memory-warning-equivalent
  notifications internally) and supports a `countLimit`/`totalCostSize` cap — set both, don't
  rely on the automatic eviction alone, because that only engages under actual system memory
  pressure, which for a "must not grow the longer it runs" requirement is too late a signal; a
  soft cap enforced proactively (LRU eviction at, say, 90% of a chosen ceiling) is the stronger
  design.
- **Retain-cycle detection**: Instruments' **Leaks** template (confirmed present in this Xcode's
  template list, §6b) for classic reference-cycle leaks; the **Memory Graph Debugger**
  (Xcode's "Debug Memory Graph" button) for interactively inspecting live object graphs and
  spotting unexpected retain paths (e.g. a closure captured by a `Timer` or `NotificationCenter`
  observer holding `self` strongly — extremely common editor-app bug: every per-document
  observer/delegate/closure registration must be audited for `[weak self]` or explicit
  unregistration on document close). A **standing rule**: every `NotificationCenter.addObserver`,
  `DispatchSourceTimer`/`Timer` target, and closure stored on a longer-lived object must have an
  explicit teardown path exercised by a test (open-N-documents-then-close-all-then-assert-
  object-count-is-zero is a cheap, high-value regression test class for an editor that opens and
  closes many buffers over a long session).
- **`MallocStackLogging`** (env var `MallocStackLogging=1`, or Instruments Allocations'
  "Record Reference Counts" + malloc stack logging option): lets `leaks(1)`/Instruments show the
  **allocation backtrace** for each live object, not just its type — essential for tracking down
  *which* code path is responsible for a cache that grew unexpectedly, as opposed to just knowing
  "NSData instances: 40,000 and climbing."
- **Swift-specific leak class to design against explicitly**: reference cycles through `Task`
  closures capturing `self` strongly across `await` points, and through `AsyncStream`/
  `AsyncSequence` continuations that outlive their consumer. Both are newer failure modes than
  classic Cocoa retain cycles and are less well covered by older tooling folklore; Instruments'
  **Swift Concurrency** template (confirmed present, §6b) is the modern tool for this — verify it
  surfaces leaked tasks/continuations specifically before relying on it (not independently
  confirmed this session — **medium-low confidence**, flagged in §17).

## 8. GC-induced latency in an interpreter

General/training knowledge plus the project's own spike data (RESULTS.md item 3), medium-high
confidence:

- The spike already ruled out the naive ARC-managed indirect-enum representation on cost grounds
  (~27x) and flagged that even the cheaper ARC representation (rep B, ~5x) needs **iterative
  teardown** to avoid stack overflow freeing long lists recursively — that is itself a latency
  concern: an uncontrolled recursive ARC release of a large list is a single-threaded, unbudgeted
  pause exactly like a GC pause, just implicit. **Design rule directly following from the
  project's own spike**: never let a cons cell's `deinit` chain be the thing that frees a long
  list; maintain an explicit iterative "unlink and drop one at a time" path for any
  interpreter-level list the length of which is not statically bounded (this applies even before
  a real tracing GC exists, because ARC teardown of a long chain is its own unbounded-pause
  hazard).
- If/when the engine moves to the tagged-word + arena design the spike recommends as the
  performance ceiling, the standard technique for keeping GC pauses bounded in an editor context
  (where a pause during a keystroke is directly user-visible, unlike a batch job) is an
  **incremental/generational collector with a per-slice time or work budget**, not a
  stop-the-world full collection: cap each collection increment to a fixed budget (e.g. "collect
  for at most 0.5 ms per invocation, called from the idle portion of the run loop or between
  evaluator steps") and resume the mutator; track "step counter" style deadline checks the same
  way the mini-interpreter spike already does for the evaluator's own deadline check (every 64
  iterations) — the same technique (a cheap counter check on a hot path) generalizes directly to
  "check for GC-due every N allocations, do a bounded increment of work, return." This is
  general GC-engineering knowledge (mirrors, e.g., how V8's incremental/concurrent marking and
  Lua's incremental GC are described in public talks), not verified against a specific fetched
  source this session — **medium confidence** on the specific technique, high confidence that
  "unbounded stop-the-world collection is unacceptable for a keystroke-latency-sensitive
  interpreter" is the correct requirement.
- **Arena-per-generation / bump allocation** for short-lived interpreter garbage (most Elisp
  evaluation garbage is very short-lived — temporary conses from a `let`/loop body) is the
  standard way to make the common case allocate-and-die without ever reaching a mark/sweep pass
  at all; this is consistent with the spike's own C-representation numbers (tagged word + arena
  at 1x baseline vs 5x/27x for ARC-managed representations).

## 9. File watching without polling

General/training knowledge, high confidence (stable, well-documented Darwin APIs; the direct
`developer.apple.com/documentation/coreservices/file_system_events` fetch returned only the page
title this session, so the specifics below are not freshly re-quoted, but are standard, stable
API behavior):

- **FSEvents** (`FSEventStreamCreate` / the higher-level `DispatchSource`-free C API, or the
  newer async `FSEventStream` Swift wrapper) is the right tool for **watching whole directory
  trees** (a project root) for changes made by *any* process, including ones outside the app
  (e.g. `git checkout`, an external formatter, another editor instance) — it is kernel-level,
  coalesces bursts of changes, and reports at a **configurable latency** (seconds-scale
  granularity is fine and is what keeps it cheap — do not set latency near 0 for a whole-project
  watch; that defeats coalescing and increases wakeups). It does not require polling and has
  negligible idle cost.
- **`DispatchSource.makeFileSystemObjectSource` (kqueue-backed under the hood)** is the right
  tool for watching a **small, known set of specific open file descriptors** (e.g. the handful
  of files currently open in editor buffers, to detect external modification for the
  "file changed on disk, reload?" prompt) — lower latency than FSEvents, but does not scale to
  watching an entire tree (one fd/kqueue registration per watched path) and only sees the paths
  you explicitly registered, not new files appearing.
- **Recommended split for pellicle**: one FSEvents stream per open project root (for the
  project browser / "files changed outside the editor" background reindex trigger, tolerant of
  a several-hundred-ms-to-a-few-second latency), plus a `DispatchSourceFileSystemObject` per
  currently-open buffer's file descriptor (for immediate "this exact open file changed under
  you" detection) — never a polling `stat()` loop on a timer, which is both wasteful (constant
  wakeups even at rest) and slower to react than either kernel-notification mechanism.

## 10. Child-process I/O without polling

General/training knowledge, high confidence (stable Foundation/Dispatch APIs):

- **`FileHandle.readabilityHandler`** (simple, one-shot-per-callback closure-based) or the more
  controllable **`DispatchIO` channel** (`DispatchIO.read(fromFileDescriptor:maxLength:
  runningHandlerOn:ioHandler:)`) both deliver data via the kernel's readiness notification
  (kqueue underneath), with zero CPU cost while the child process is silent — this is the
  correct way to stream output from a spawned shell (the iTerm2-style terminal pane), a language
  server process, or a Verilog compiler invocation, versus a `Timer`-driven poll-and-check loop
  on the pipe, which would burn wakeups even when the child is idle and adds latency up to the
  poll interval.
- **`DispatchIO` is the better long-term choice over `FileHandle.readabilityHandler`** for
  pellicle specifically because the editor's whole design (per the brief) includes acting as a
  real terminal with potentially high-throughput/high-frequency output (a `find`, a build log,
  `git log -p`) — `DispatchIO` supports chunked reads with a specified queue/QoS for the handler
  (tie the terminal's own read handler to a QoS matching its visibility: `.userInitiated` while
  the pane is visible/foreground, dropped to `.utility` if the user backgrounds that terminal
  tab but the process keeps running, consistent with §3's scheduling rule and §5's App Nap
  opt-out for a running shell) and back-pressure via `maxLength`, whereas
  `FileHandle.readabilityHandler` has no back-pressure control and no QoS association.
- For **writing** to a child process's stdin (sending a command, sending an LSP request body),
  the symmetric non-blocking write path is `DispatchIO.write(...)` or checking
  `FileHandle.writeabilityHandler`/`Pipe` fd flags before writing — never a blocking `write()`
  call on the pipe from the main actor/thread, since a full pipe buffer (child not reading fast
  enough) would then block UI.

## 11. Text shaping and glyph caching (cross-reference — see apple-text-rendering.md §4)

Not duplicated here (`CTFontDrawGlyphs`, GPU-resident glyph atlas design already covered there in
detail, high confidence). This report's addition is the power/perf framing: a glyph atlas cache
should itself be bounded (`NSCache`-style eviction, §7) keyed by (font, size, glyph ID, subpixel
phase if used), and re-shaping should be triggered only for the changed line range (ties directly
into §12's incremental design) — reshaping a whole 100k-line buffer's runs on every keystroke
would be both a latency and an energy failure even with a fast shaper, since CPU/GPU work done
is proportional to bytes shaped regardless of shaping algorithm quality.

## 12. Incremental everything

General project-design knowledge, high confidence as a principle (specific numbers not sourced
this session):

- Every subsystem that scales with document size — syntax highlighting (tree-sitter-style
  incremental reparse, already part of Reticle's prior design per CONTEXT.md), glyph shaping
  (§11), LSP semantic-token requests (send only changed ranges via textDocument/didChange
  incremental sync, not full-document sync), the Elisp interpreter's own GC (§8), and the file
  watcher's reaction to a change (§9) — must be **damage-range-scoped**, not whole-document, or
  the "must not get slower/hotter the longer the session runs / the bigger the file" requirement
  from CONTEXT.md is unachievable no matter how fast any individual full-document pass is, because
  full-document work scales with file size while user input rate does not.
- Concrete rule: define one shared "damage range" representation (a set of line/byte ranges
  dirtied since the last stable point) that rendering, shaping, syntax highlighting, and LSP
  sync all consume, rather than each subsystem tracking its own ad hoc dirty state — divergence
  between them is a classic source of "works on small files, degrades on big ones" bugs.

## 13. Long-session stability practices

General/training knowledge (industry-standard practice for long-running desktop apps), medium-
high confidence:

- **Soak tests**: an automated, unattended run that keeps the app open for many hours (the
  owner's explicit bar is "must not get slower, hotter, or crash the longer it runs") while
  driving synthetic input (open/close files, type, scroll, run background parses/LSP
  round-trips, spawn/kill child shell processes) at a steady rate, sampling `powermetrics`
  (§6a) and RSS/heap size (via `vmmap`/Instruments Allocations, §6b) at fixed intervals, and
  asserting the trend lines are flat (or bounded/plateauing, e.g. a cache filling to its cap
  once) rather than monotonically increasing. This must run before every release per the
  measurement protocol (§16).
- **Crash reporting**: MetricKit's `MXDiagnosticPayload` crash diagnostics (§6d) plus macOS's
  own `~/Library/Logs/DiagnosticReports/*.ips` crash logs (readable via `log show` locally,
  confirmed present via `man log`/`log show --help` this session) give a zero-infrastructure
  local crash record for a single-user/owner-only project; no third-party crash-reporting SDK is
  needed at this stage.
- **Watchdogs for hung tasks**: the main-thread-hang detection MetricKit already provides
  (§6d) is passive/after-the-fact; for **active** detection during development, a lightweight
  in-process watchdog — a low-priority background timer that pings the main actor and measures
  round-trip latency, logging/asserting if it exceeds a threshold (e.g. 200 ms) — catches a
  main-thread stall (e.g. an accidental synchronous blocking call, a lock held too long) far
  earlier than a user noticing "the editor froze." Apple's own Instruments **Tailspin** template
  (confirmed present, §6b) does the equivalent system-wide by sampling all threads when hangs are
  detected and is the right tool for diagnosing *why* once the watchdog flags *that*.
- **Memory ceilings**: combine the proactive `NSCache` caps (§7) with a hard fallback — if total
  process RSS crosses an outer ceiling (choose one relative to the owner's 24 GB machine, e.g.
  a few GB for a text editor, with headroom for genuinely large files), proactively drop all
  soft caches (glyph atlas beyond the visible viewport, LSP symbol caches for background/closed
  files, undo history beyond a configurable horizon) before the OS's own memory pressure kicks
  in — this is the same "act before the emergency signal" philosophy as §7's NSCache guidance,
  generalized to the whole process.
- **Per-subsystem restart**: for anything spawned as a **child process** (LSP servers, a
  Verilog/Verible backend) this is nearly free to get right, since a crashed/hung child process
  is just a process the app can kill (`taskpolicy`/`Process.terminate()`) and respawn without
  taking the editor down — design every LSP/tool integration assuming its backend process *will*
  occasionally hang or crash, with automatic restart-with-backoff and a visible but
  non-blocking status indicator, never a design where an editor feature's failure can crash or
  hang the host app. For **in-process** subsystems (the Elisp interpreter itself, the renderer)
  a full "restart" is not generally possible without restarting the app, which is why bounding
  GC pauses (§8) and never letting user Elisp code run unbounded on the main thread (deadline
  checks, as the spike's mini-interpreter already demonstrates) matters more there than for
  child-process subsystems.

## 14. Metal vs CPU drawing for text: thermal/energy behaviour (cross-reference)

Primarily covered in apple-text-rendering.md (glyph atlas + Metal compositing recommendation,
§§1,4,6,7 there). This report's addition, from the App Nap findings in §5: a Metal-backed
window is not automatically App Nap-exempt the way legacy OpenGL was, which — combined with
Zed's explicit "keep presenting to avoid ProMotion underclocking" finding (§1) — means the
actual thermal/energy story is not "Metal is free," it is "GPU compositing of already-cached
glyph textures is far cheaper per frame than CPU-side text layout/raster on every frame," but
that cheap-per-frame cost is still not zero-per-frame, so the pause-when-idle discipline (§1,
apple-text-rendering.md §3) remains necessary regardless of renderer choice — a Metal renderer
that free-runs at 120 Hz while idle would still be measurably worse on `powermetrics` than a
CPU renderer that draws once and stops, even though per-frame the Metal path is cheaper. Draw
frequency discipline dominates draw-mechanism choice for the idle-power number specifically.

## 15. Checklist of engineering rules the project must follow

Each rule: **rule — rationale — source/confidence**.

1. **Pause the display link (or equivalent draw trigger) whenever nothing changed; resume only
   on input, buffer mutation, or active animation; keep the previous frame rate for ~1 s after
   the last change before dropping to idle.** — Rationale: §1/§14 — a free-running loop is the
   single biggest idle-CPU/idle-energy cost class for a GUI app, and dropping to idle instantly
   at the wrong moment adds latency to the next input on ProMotion displays. — Source: Zed
   `120fps` blog (high confidence, quoted), apple-text-rendering.md §3 (medium confidence).
2. **Give every non-input-critical recurring timer an explicit tolerance/leeway of at least 10%
   of its interval.** — Rationale: enables system-wide timer coalescing, which the OS documents
   as dramatically increasing idle time. — Source: Apple Energy Efficiency Guide, "Minimize
   Timer Use" (high confidence, quoted).
3. **Schedule background parse/index/reindex work at `.utility` QoS (or `.background` for
   invisible maintenance), on dedicated queues, cancel-on-new-edit, never sharing a lock with
   the input/render path except via very short critical sections.** — Rationale: correct QoS
   placement uses the P/E-core split to structurally prevent background work from starving
   keystroke handling; canceling stale work also bounds memory/CPU spent on discarded results.
   — Source: general QoS/GCD documentation (medium-high confidence) + Swift Concurrency
   transcript's cooperative-pool description (high confidence, quoted).
4. **Batch every `@MainActor` crossing on a hot path — compute off-main, hop to main once per
   logical unit of work, never once per token/line/diagnostic in a loop.** — Rationale: Apple's
   own stated design rationale is that main-actor hops are genuine context switches, unlike
   pool-to-pool actor hops. — Source: WWDC21 "Swift concurrency: Behind the scenes" (high
   confidence, quoted directly).
5. **Any activity that must legitimately continue while the app is backgrounded (a running
   shell, a compile job, a background index the user is watching) must explicitly wrap itself in
   an `NSProcessInfo`/`ProcessInfo` activity assertion; do not assume Metal rendering exempts the
   app from App Nap.** — Rationale: App Nap throttles timers (and by extension, effectively,
   backgrounded work) once all its trigger conditions hold, and Metal use does not appear on the
   list of automatic exemptions the way legacy OpenGL did. — Source: Apple macOS Power Efficiency
   Guidelines, "App Nap" page (high confidence on trigger conditions and the OpenGL detail;
   medium confidence on exact `NSActivityOptions` flag names, not re-quoted this session).
6. **Never free a long interpreter list (or any long ARC-managed chain) via recursive `deinit` at
   scope exit; use an explicit iterative unlink loop.** — Rationale: the project's own spike
   measured a segfault (signal 139, stack overflow) from exactly this pattern on a 1M-node list,
   and an interpreter's default 512 KB thread stack makes it worse than the 8 MB main-thread
   stack the spike used. — Source: `spikes/RESULTS.md` item 3 (high confidence — the project's
   own measured spike).
7. **Design the interpreter's eventual GC (if/when the engine moves off pure ARC cons cells) as
   incremental/budgeted per invocation, never stop-the-world, using the same "cheap counter check
   every N operations" pattern the mini-interpreter spike already uses for its deadline check.**
   — Rationale: an unbounded collection pause during a keystroke is a directly user-visible
   latency spike, unacceptable for an editor. — Source: general GC-engineering knowledge (medium
   confidence) + the project's own spike pattern for deadline checks (high confidence).
8. **Bound every cache (glyph atlas, shaped-line cache, syntax-tree cache, LSP symbol cache,
   undo history) with an explicit proactive limit (NSCache countLimit/totalCostSize or equivalent
   custom LRU), not just reliance on system memory-pressure eviction.** — Rationale: memory-
   pressure-triggered eviction alone is a "too late" signal for a "must not grow over a session"
   requirement; a soft cap enforced before pressure occurs is the stronger design. — Source:
   general Foundation/NSCache documentation (medium-high confidence).
9. **Every `NotificationCenter` observer, `Timer`/`DispatchSourceTimer` target, and long-lived
   closure capture must have an explicit, tested teardown path; add an open-N-documents/close-all
   /assert-zero-leftover-objects test as a standing regression test.** — Rationale: this is the
   most common Cocoa-editor leak class (observers/timers holding `self`), directly relevant to
   an app whose core interaction model is opening and closing many buffers over long sessions.
   — Source: general Cocoa/Instruments knowledge (medium-high confidence).
10. **Watch whole project directory trees with FSEvents (seconds-scale latency, coalesced);
    watch individually open file descriptors with `DispatchSource`/kqueue for immediate
    external-modification detection; never poll with a `stat()` timer loop.** — Rationale:
    both kernel mechanisms have near-zero idle cost and lower latency than any polling interval
    that would also be cheap enough to run constantly. — Source: general Darwin API knowledge
    (high confidence; direct Apple doc fetch returned only a page title this session).
11. **Stream all child-process I/O (shell, LSP, compiler tools) via `DispatchIO`/
    `FileHandle.readabilityHandler`, never via a polling read loop; associate the read handler's
    QoS with the pane's visibility state, and back it with an App Nap activity assertion (rule 5)
    while the process must keep running in the background.** — Rationale: kernel readiness
    notification has zero idle cost versus any poll interval, and QoS/App-Nap alignment prevents
    a backgrounded terminal from starving or being throttled incorrectly. — Source: general
    Dispatch/Foundation API knowledge (high confidence).
12. **Make "damage range" (dirtied line/byte ranges since last stable point) one shared
    representation consumed by rendering, shaping, syntax highlighting, and LSP incremental
    sync — not four independently tracked dirty-state mechanisms.** — Rationale: whole-document
    work scaling with file size, while input rate does not, is the direct mechanism by which an
    editor "gets slower on big files" even when every individual pass is well-optimized. —
    Source: general incremental-editor design knowledge (high confidence as a principle).
13. **Run an unattended multi-hour soak test with synthetic input before every release, sampling
    `powermetrics` and RSS at fixed intervals, and require the trend lines to be flat/bounded, not
    monotonically increasing.** — Rationale: this is the only direct empirical test of the
    owner's explicit "must not get slower/hotter/crash over time" bar; everything else in this
    checklist is a mechanism believed to produce that outcome, not proof of it. — Source: general
    long-running-app engineering practice (medium-high confidence); see §16 for the concrete
    protocol.
14. **Wire up `MXMetricManagerSubscriber` (hangs, CPU exceptions, disk-write exceptions, crashes)
    from day one, even as a single-user app**, and keep `os_signpost` intervals around every
    major subsystem boundary (keystroke received, reparse start/end, display-link pause/resume,
    LSP round-trip) gated behind a cheap `.disabled`-able `OSLog` handle. — Rationale: both are
    near-zero-cost to add early and expensive to retrofit once a regression is already suspected;
    they are the tooling that turns "it feels slower" into a measurable, attributable finding. —
    Source: WWDC20 MetricKit transcript + WWDC18 os_signpost transcript (high confidence, both
    quoted).
15. **Treat every LSP server / external tool subprocess as expected to hang or crash; supervise
    it with automatic restart-with-backoff, never let its failure hang or crash the host app.**
    — Rationale: child-process supervision is nearly free (kill + respawn) and is the only
    tractable "per-subsystem restart" mechanism available to a Swift app (in-process subsystem
    restart generally requires restarting the whole app). — Source: general process-supervision
    engineering practice (high confidence as a principle).

## 16. Measurement protocol for the owner's M4 (deliverable 2)

Run before every release. All commands assume the built `.app` is already installed/running
normally (not under Xcode's debugger, which perturbs energy numbers) unless noted. Where a
step says "record," append the value into a dated results file (e.g.
`release-checks/YYYY-MM-DD.md` in the real project, not this scratchpad) so trend lines across
releases are visible, not just pass/fail on the latest run.

**A. Idle CPU / idle energy (target: as close to 0% as the OS's own baseline allows)**

1. Launch the app, open a mid-size real file (~5-10k lines), let it sit completely untouched
   (no input, foreground) for 60 s to clear any startup transient.
2. `sudo powermetrics -i 1000 -n 60 --show-process-energy --show-cpu-qos -f plist
   --output-file idle.plist` (60 one-second samples = 1 minute window).
3. **Record**: average CPU % for the app's PID over the window (from `--show-process-energy`'s
   per-process breakdown), average "energy impact" composite, whether any P-state above the
   idle floor was sustained (`--show-pstates`).
4. **Pass/fail**: app's average CPU over the window must be indistinguishable from a blank
   TextEdit window doing nothing (run the same capture against TextEdit once per machine/OS
   version to (re-)establish this baseline, not a fixed absolute number, since the "true idle"
   floor is OS/hardware dependent) — flag any regression versus the previous release's recorded
   number even if still "low," since the requirement is monotonic non-regression over time, not
   a one-time bar.

**B. Input-driven CPU/GPU cost (typing burst)**

1. With the same file open, drive a scripted burst of ~200 keystrokes at a natural typing cadence
   (e.g. via a macOS UI-automation script or AppleScript `keystroke`, kept outside this scratchpad
   in the real project) while capturing `sudo powermetrics -i 200 --show-process-gpu
   --show-process-energy -n <enough to cover the burst> -f plist`.
2. **Record**: peak and average CPU%, whether GPU time appears proportional to visible glyph
   count (sanity check against §11/apple-text-rendering.md's incremental-shaping claim), whether
   the display link stayed paused between keystrokes rather than free-running (cross-check via
   an `os_signpost` "display link resumed/paused" Points-of-Interest trace captured in the same
   window via Instruments' Power Profiler or Time Profiler template).
3. **Pass/fail**: no sustained P-state ceiling hit (thermal throttling) from a 200-keystroke
   burst on an M4; CPU returns to the idle-A baseline within roughly 1-2 s of the burst ending
   (allowing for the Zed-style ~1 s linger, §1) — flag if it takes longer.

**C. p99 keystroke latency**

1. Instrument the actual keystroke-to-redraw-committed path with `os_signpost` intervals
   (start at input event delivery, end at `presentDrawable`/frame commit), gated by `.disabled`able
   `OSLog` per rule 14.
2. Capture a Time Profiler + Points of Interest trace during a sustained typing session (real or
   scripted, at least a few hundred keystrokes) via `xcrun xctrace record --template "Time
   Profiler" --launch <bundle-id>` or the equivalent through Instruments.app, then extract the
   interval durations from the Points of Interest summary-of-intervals view (§6c).
3. **Record**: p50, p95, p99, max keystroke-to-frame latency in ms.
4. **Pass/fail**: p99 under one ProMotion frame budget at the display's committed refresh rate
   during typing (≈8.3 ms at 120 Hz) is the aspirational target; treat p99 under ~16.7 ms (one
   60 Hz frame) as the minimum acceptable bar for release, and any regression versus the previous
   release's recorded p99 as a required investigation even if still under the bar.

**D. Long-session memory and thermal soak (multi-hour, run overnight or during owner-idle time)**

1. Launch the app; run a scripted loop for at least 4 hours (longer before a major release) that
   cycles: open a handful of real project files across the languages named in CONTEXT.md
   (Verilog, Swift, Python, C/C++), type bursts, trigger background parse/index, run a couple of
   representative shell commands via the terminal pane (`M-!`-equivalent), close and reopen
   files, run the LSP servers listed in CONTEXT.md's environment section against real files.
2. Every 5 minutes: log RSS via `vmmap --summary <pid>` or `ps -o rss= -p <pid>`, and take a
   `powermetrics -n 1 --show-process-energy` snapshot (SIGINFO against a running long capture is
   an alternative to separate short invocations).
3. **Record**: RSS over time (plot/tabulate — must plateau after caches fill, not climb
   unbounded), CPU%/energy-impact over time (must not trend upward), any P-state ceiling hits
   in the back half of the run (thermal creep), any MetricKit diagnostic payloads generated
   during/after the run (§6d/§13), any crash logs in
   `~/Library/Logs/DiagnosticReports/` timestamped during the run (check via
   `log show --predicate 'process == "<AppName>"' --last 4h --style compact` for correlated
   system log activity around any anomaly, or `ls -lt ~/Library/Logs/DiagnosticReports/ | head`
   for a fast crash check).
4. **Pass/fail**: RSS after N hours must be within a fixed small margin (e.g. +10%) of RSS after
   the first 30 minutes (post-cache-warmup baseline), not still climbing; zero crashes; zero
   sustained P-state ceiling in the back half of the run when the front half didn't have one
   (thermal creep is itself a fail even without a crash); zero unexplained MetricKit hang/CPU-
   exception diagnostics.

**E. Regression tripwire for QoS/scheduling correctness**

1. Run the soak test (D) once more but wrapped with `sudo taskpolicy -c utility <the app>` (per
   §3) to force the whole process to a lower QoS ceiling, simulating "what if the scheduler
   mis-prioritizes us."
2. **Record**: whether foreground typing latency (test C, informally re-run) degrades
   noticeably under this artificial handicap.
3. **Pass/fail**: this is a diagnostic, not a hard gate (a forced global QoS clamp is not a
   realistic runtime scenario) — but a large latency cliff here is a signal that the app is not
   actually getting `.userInteractive` treatment on its real input path even under normal
   conditions, worth investigating before release rather than after a user report.

## 17. Unverified / needs on-device or fresh-source confirmation

- **CADisplayLink/NSView.displayLink exact macOS availability version, CVDisplayLink deprecation
  version, and whether `preferredFrameRateRange` behaves identically on macOS vs iOS.** —
  Already flagged as unverified in apple-text-rendering.md §3; repeated here because it's
  foundational to §1/§14 of this report too. Verify via Xcode's offline documentation before
  locking the architecture.
- **Exact `NSActivityOptions` flag names and semantics for opting out of App Nap** (§5) — the
  mechanism (`NSProcessInfo`/`ProcessInfo` activity assertions) is confirmed from a primary
  source, but the specific flag names (`.userInitiated`, `.background`,
  `.idleSystemSleepDisabled`, `.suddenTerminationDisabled`, etc.) were not re-quoted from a live
  fetch this session — confirm exact names/behavior before implementing rule 5.
- **Whether "Power Profiler" in this Xcode's Instruments template list is a full replacement for
  the older "Energy Log" instrument**, or whether Energy Log still exists under another name/
  location — inferred from the template list not including a separately named "Energy Log,"
  not confirmed against release notes.
- **MetricKit's macOS payload parity with iOS** (§6d) — the fetched WWDC session is iOS-focused;
  whether Hangs/CPU Exceptions/Disk Write Exceptions diagnostics are available identically on
  macOS, and whether `MXMetricManager.shared.pastPayloads` is usable for a locally-run,
  non-TestFlight/App-Store-distributed app (relevant since pellicle will not be App-Store
  distributed, at least initially) — confirm against current macOS MetricKit documentation
  before designing the telemetry hookup around it.
- **Xcode's Energy Gauge** (§6e) — described from general knowledge only; not fetched or
  confirmed this session.
- **QoS class exact semantics and priority-inheritance details** (§3) — the one QoS-specific
  fetch this session returned only legacy `DISPATCH_QUEUE_PRIORITY_*` constants, not the modern
  QoS-class documentation; the QoS enum descriptions and P/E-core placement claim are from
  general/training knowledge, not freshly re-quoted. High confidence they are directionally
  correct (long-stable, widely-documented API), but worth a quick confirmation pass against
  Apple's current Concurrency Programming Guide or a WWDC QoS session before the architecture
  doc cites specific behavior as fact.
- **FSEvents API specifics** (latency parameter name/units, exact coalescing behavior) (§9) —
  the direct Apple doc fetch returned only a page title; specifics given are from general
  knowledge of a long-stable API, not re-quoted from a primary source this session.
- **GC incremental-collection budgeting technique** (§8) — presented as general GC-engineering
  best practice by analogy to other language runtimes' publicly described techniques; not
  something Apple documents (there is no Apple GC to document), and not verified against any
  specific fetched source — treat as a design recommendation to validate against the actual
  engine design once it exists, not an Apple-endorsed pattern.
- **Instruments Swift Concurrency template's ability to surface leaked `Task`/`AsyncStream`
  continuations specifically** (§7) — presence of the template is confirmed locally; its
  capability for this specific leak class is not confirmed.

## Sources consulted

- `zed.dev/blog/120fps` (Feb 2024, Nathan Sobo & Antonio Scandurra) — fetched, quoted. High
  confidence, primary source.
- Apple Energy Efficiency Guide (archived), "Minimize Timer Use" —
  `developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/
  MinimizeTimerUse.html` — fetched, quoted. High confidence.
- Apple Energy Efficiency Guide (archived), index/TOC —
  `.../EnergyGuide-iOS/index.html` — fetched, summarized. High confidence.
- Apple macOS Power Efficiency Guidelines (archived), "App Nap" —
  `.../power_efficiency_guidelines_osx/AppNap.html` — fetched, quoted. High confidence.
- WWDC21 "Swift concurrency: Behind the scenes" —
  `developer.apple.com/videos/play/wwdc2021/10254/` — fetched, quoted extensively. High
  confidence.
- WWDC20 "What's New in MetricKit" — `developer.apple.com/videos/play/wwdc2020/10081/` —
  fetched, quoted. High confidence (iOS-scoped; macOS parity unverified, see §17).
- WWDC18 "Measuring Performance Using Logging" (os_signpost) —
  `developer.apple.com/videos/play/wwdc2018/405/` — fetched, quoted extensively. High
  confidence.
- WWDC19 session 417 (battery/performance metrics overview, XCTest Metrics/MetricKit/Metrics
  Organizer) — `developer.apple.com/videos/play/wwdc2019/417/` — fetched, partial relevant
  content quoted. Medium confidence (transcript itself said the deep API specifics weren't in
  its content).
- Local: `man powermetrics` — full text read. High confidence.
- Local: `xcrun xctrace list templates` — full list read. High confidence.
- Local: `man taskpolicy` — full text read. High confidence.
- Local: `log --help` / `log show` usage — read. High confidence.
- `spikes/RESULTS.md` (this project's own prior spikes) — read in full, cited in §8/§15/§17.
- `apple-text-rendering.md` (this project's companion report) — section 3 read in full and
  cross-referenced, not duplicated, per instructions.
- Attempted but not usable as sources (wrong content returned, noted so nobody re-tries the same
  guess): `developer.apple.com/videos/play/wwdc2020/10078/` (year listing, not a specific
  session's content), `developer.apple.com/videos/play/wwdc2016/406/` (year listing),
  `developer.apple.com/videos/play/wwdc2013/705/` (no video found — WWDC13 videos appear removed
  from Apple's current listing), `developer.apple.com/videos/play/wwdc2021/10073/` (resolved to
  an ARKit session, not a profiling session), `developer.apple.com/documentation/coreservices/
  file_system_events` (JS shell, title only), `developer.apple.com/library/archive/documentation/
  General/Conceptual/ConcurrencyProgrammingGuide/OperationQueues/OperationQueues.html` (returned
  only legacy `DISPATCH_QUEUE_PRIORITY_*` prose, not QoS-class specifics), `ghostty.org/docs/
  install/build` (build instructions only, no performance-design content — a Ghostty
  performance/architecture blog post was not located within the remaining budget).
