import Foundation
import os

/// MainActorWatchdog: PLAN.md 4.14 rule 15 — "an in-process watchdog pings the UI actor
/// from a low-priority thread and logs any round trip over 200 ms during development."
///
/// Implementation notes:
/// - The ping runs on a dedicated, low-QoS (`.utility`) `Thread` with its own run loop, so
///   "the thread is gone after `close()`" is a real, checkable fact (`Thread.isFinished`),
///   not a metaphor for a GCD worker that may or may not have been reused.
/// - The repeating ping is a `Timer` on that thread's run loop with `.tolerance` set to at
///   least 10% of the interval (PLAN.md 4.14 rule 2), so the OS can coalesce its wake-ups;
///   nothing here polls in a busy loop.
/// - Each ping hops to the main actor with a `Task { @MainActor in }`, times the round
///   trip with `ContinuousClock`, and calls the overrun handler when it exceeds the
///   threshold. The handler is injectable so tests can observe an overrun without
///   scraping log output.
package final class MainActorWatchdog: @unchecked Sendable {
    package typealias OverrunHandler = @Sendable (Duration) -> Void

    /// Enabled by default only in debug builds, or in any build when
    /// `SWIFTEMACS_WATCHDOG=1` is set.
    package static var isEnabledByDefault: Bool {
        #if DEBUG
            return true
        #else
            return ProcessInfo.processInfo.environment["SWIFTEMACS_WATCHDOG"] == "1"
        #endif
    }

    private let threshold: Duration
    private let interval: TimeInterval
    private let onOverrun: OverrunHandler

    private let lock = NSLock()
    private var thread: Thread?
    private var runLoopTimer: Timer?
    private var targetRunLoop: RunLoop?
    private var closed = false
    private let stoppedSemaphore = DispatchSemaphore(value: 0)

    /// - Parameters:
    ///   - threshold: round trips at or under this duration are not reported. Defaults to
    ///     200 ms per PLAN.md 4.14 rule 15.
    ///   - interval: how often the watchdog pings; defaults to `threshold`.
    ///   - enabled: whether to actually start the background thread. Tests pass `true`
    ///     explicitly to exercise the watchdog regardless of build configuration.
    ///   - onOverrun: called (not on the main actor) with the observed round-trip
    ///     duration whenever it exceeds `threshold`.
    ///   - beforePublishHook, afterMarkClosedHook: test seams; see their declarations.
    package init(
        threshold: Duration = .milliseconds(200),
        interval: Duration? = nil,
        enabled: Bool = MainActorWatchdog.isEnabledByDefault,
        onOverrun: @escaping OverrunHandler = MainActorWatchdog.logOverrun,
        beforePublishHook: (@Sendable () -> Void)? = nil,
        afterMarkClosedHook: (@Sendable () -> Void)? = nil
    ) {
        self.threshold = threshold
        self.interval = Self.seconds(interval ?? threshold)
        self.onOverrun = onOverrun
        self.beforePublishHook = beforePublishHook
        self.afterMarkClosedHook = afterMarkClosedHook
        guard enabled else { return }
        start()
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static let watchdogLog = OSLog(subsystem: Signposts.subsystem, category: "watchdog")

    /// The default overrun handler: one `OSLog` line, at `.fault` (development-only
    /// signal — this is not a user-facing error).
    package static func logOverrun(_ duration: Duration) {
        let millis = seconds(duration) * 1000
        os_log(
            "main-actor watchdog: round trip took %.1f ms", log: watchdogLog, type: .fault,
            millis)
    }

    private func start() {
        let t = Thread { [weak self] in
            self?.runOnDedicatedThread()
        }
        t.name = "app.swiftemacs.watchdog"
        t.qualityOfService = .utility
        lock.lock()
        thread = t
        lock.unlock()
        t.start()
    }

    /// Test seams for the `close()` race guarded below. They exist because the race is
    /// not reproducible on demand — fifty back-to-back construct/close pairs did not hit
    /// it on this machine — so without them the guard has no test that can observe it,
    /// and a mutation deleting the guard would pass the suite. `beforePublish` runs on
    /// the watchdog's own thread immediately before it publishes its run loop, i.e.
    /// inside the window; `afterMarkClosed` runs in `close()` just after it has set
    /// `closed` and released the lock. A test parks the thread in the first and waits for
    /// the second, which orders the two sides deterministically.
    ///
    /// They are per-instance and injected at construction, deliberately: as static hooks
    /// they were global state, and Swift Testing runs suites in parallel, so every other
    /// test's watchdog parked in the hook too.
    private let beforePublishHook: (@Sendable () -> Void)?
    private let afterMarkClosedHook: (@Sendable () -> Void)?

    private func runOnDedicatedThread() {
        let runLoop = RunLoop.current

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.ping()
        }
        // At least 10% of the interval (PLAN.md 4.14 rule 2).
        timer.tolerance = interval * 0.1
        runLoop.add(timer, forMode: .common)

        beforePublishHook?()

        lock.lock()
        // Race with close(): start() returns as soon as Thread.start() is called, before
        // this thread reaches here. If close() ran in that window, it already set
        // `closed = true` and (finding both run-loop fields still nil) took the "never
        // started" early return in close() — so nobody else is coming back to stop this
        // run loop. Check `closed` before publishing so this thread notices the race
        // itself instead of committing to `runLoop.run()` with no one left who can stop
        // it. Do not "simplify" this away: without it, close() called in the start()/
        // runOnDedicatedThread() window leaves this thread running for the rest of the
        // process's life while isRunning reports false.
        if closed {
            lock.unlock()
            timer.invalidate()
            stoppedSemaphore.signal()
            return
        }
        targetRunLoop = runLoop
        runLoopTimer = timer
        lock.unlock()

        // Runs until close() invalidates the timer and stops this run loop.
        runLoop.run()
        stoppedSemaphore.signal()
    }

    private func ping() {
        let clock = ContinuousClock()
        let start = clock.now
        let threshold = self.threshold
        let handler = onOverrun
        Task { @MainActor in
            // Measure on the main actor (that is the round trip being timed), but hand
            // the handler off to a detached utility task rather than calling it here:
            // the watchdog exists to detect a stalled main actor, so running an
            // arbitrary caller-supplied handler on that same actor at exactly the
            // moment it is stalled would be the wrong way round.
            let elapsed = clock.now - start
            if elapsed > threshold {
                Task.detached(priority: .utility) {
                    handler(elapsed)
                }
            }
        }
    }

    /// Whether the watchdog's dedicated thread is still alive. `false` before the first
    /// `start()` (i.e. constructed with `enabled: false`) and after `close()`.
    package var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let thread, !closed else { return false }
        return !thread.isFinished
    }

    /// Whether the dedicated thread has actually exited. `isRunning` answers the
    /// *logical* question and turns `false` the moment `close()` sets `closed`, which is
    /// what a caller wants but is useless to a teardown test: under the race guarded in
    /// `runOnDedicatedThread()` it reported `false` while the thread ran forever. This
    /// answers the physical question (PLAN.md 4.14 rule 9).
    package var isThreadAlive: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let thread else { return false }
        return !thread.isFinished
    }

    /// Stops the watchdog's thread deterministically and waits for it to actually exit.
    /// Idempotent: a second call is a no-op.
    package func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        // Distinguish "never started" (enabled: false, start() never called `thread =`)
        // from "started but has not published targetRunLoop/runLoopTimer yet" (the same
        // race runOnDedicatedThread() guards against above): `thread` is set in start()
        // before `t.start()` runs, so it is reliable here even though the run-loop
        // fields may still be nil. Only the "never started" case has no thread to wait
        // on; the "started but not yet published" case still owes stoppedSemaphore a
        // signal, which runOnDedicatedThread()'s closed-check above now guarantees.
        let wasStarted = thread != nil
        let runLoop = targetRunLoop
        let timer = runLoopTimer
        lock.unlock()

        afterMarkClosedHook?()

        guard wasStarted else {
            // Never started (constructed with enabled: false); nothing to tear down.
            return
        }

        if let runLoop, let timer {
            timer.invalidate()
            CFRunLoopStop(runLoop.getCFRunLoop())
        }
        if stoppedSemaphore.wait(timeout: .now() + 5) == .timedOut {
            os_log(
                "MainActorWatchdog.close(): timed out waiting for the dedicated thread to exit",
                log: Self.watchdogLog, type: .fault)
        }
    }
}
