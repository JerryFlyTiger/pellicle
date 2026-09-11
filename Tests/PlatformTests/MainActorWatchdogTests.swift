import Dispatch
import Foundation
import Testing

@testable import Platform

@Suite("MainActorWatchdog")
struct MainActorWatchdogTests {
    @Test("open/close: the dedicated thread is gone after close(), idempotently")
    func openCloseStopsThread() {
        let watchdog = MainActorWatchdog(
            threshold: .milliseconds(50), enabled: true, onOverrun: { _ in })
        #expect(watchdog.isRunning == true)

        watchdog.close()
        // `isRunning` turns false the instant close() sets `closed`, so asserting on it
        // here would be a tautology that holds even when the thread is still running —
        // which is precisely how the race Fix 2 closes stayed invisible. Ask the physical
        // question instead.
        expectThreadGone(watchdog)
        #expect(watchdog.isRunning == false)

        // Idempotent: a second close() must not hang or trap.
        watchdog.close()
        expectThreadGone(watchdog)
        #expect(watchdog.isRunning == false)
    }

    @Test("disabled watchdog never starts a thread")
    func disabledNeverStarts() {
        let watchdog = MainActorWatchdog(enabled: false, onOverrun: { _ in })
        #expect(watchdog.isRunning == false)
        watchdog.close()
        #expect(watchdog.isRunning == false)
    }

    @Test("open-N/close-all leaves zero leftover threads")
    func openNCloseAll() {
        let watchdogs = (0..<5).map { _ in
            MainActorWatchdog(threshold: .milliseconds(50), enabled: true, onOverrun: { _ in })
        }
        for w in watchdogs { #expect(w.isRunning == true) }
        for w in watchdogs { w.close() }
        // The physical question, for the reason given in openCloseStopsThread().
        for w in watchdogs { expectThreadGone(w) }
    }

    @Test("close() immediately after construction never leaves the thread running")
    func closeImmediatelyAfterStartNeverLeaksTheThread() {
        // Reproduces Fix 2's race directly: start() returns as soon as Thread.start()
        // is called, before the new thread reaches runOnDedicatedThread() and publishes
        // targetRunLoop/runLoopTimer under lock. Before Fix 2, a close() landing in that
        // window set `closed = true`, found both fields nil, and took the "never
        // started" early return — its own idempotence guard then blocked any later
        // close() from trying again, so the thread went on to arm its timer and call
        // runLoop.run() with nobody left able to stop it: it pinged the main actor for
        // the rest of the process's life while isRunning reported false. This is a race
        // by design, so it is run in a loop rather than once.
        for _ in 0..<50 {
            let watchdog = MainActorWatchdog(
                threshold: .milliseconds(50), enabled: true, onOverrun: { _ in })
            watchdog.close()
            expectThreadGone(watchdog)
        }
    }

    @Test("a blocked main actor produces at least one recorded overrun")
    func blockedMainActorRecordsOverrun() async {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var overruns: [Duration] = []
            func record(_ d: Duration) {
                lock.lock()
                overruns.append(d)
                lock.unlock()
            }
            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return overruns.count
            }
        }
        let box = Box()

        let watchdog = MainActorWatchdog(
            threshold: .milliseconds(20), interval: .milliseconds(20), enabled: true,
            onOverrun: { duration in box.record(duration) })
        defer { watchdog.close() }

        // Block the main actor well past the 20ms threshold, several times over, so a
        // ping queued behind it observes a large round trip.
        await Task { @MainActor in
            // A plain C sleep, not `Thread.sleep`: the latter is unavailable from an
            // async context, but this closure still needs to *synchronously* occupy the
            // main actor for the watchdog's queued ping to see a large round trip.
            _ = usleep(400_000)
        }.value

        // Give the watchdog's thread a moment to deliver any ping that was queued
        // behind the block and complete its (now-unblocked) main-actor hop.
        try? await Task.sleep(for: .milliseconds(300))

        #expect(box.count >= 1)
    }

    @Test("close() landing inside the publish window still stops the thread")
    func closeInsideThePublishWindowStopsTheThread() {
        // The deterministic form of the race the loop test above only gambles on. The
        // watchdog thread is parked in `beforePublishHookForTesting`, i.e. after
        // `start()` has returned but before `targetRunLoop`/`runLoopTimer` are published;
        // close() is then run from another thread and allowed to get past the point where
        // it sets `closed` (the second seam) before the watchdog thread is released. That
        // ordering is exactly the window in which close() finds both run-loop fields nil.
        // Without the guard in runOnDedicatedThread(), the released thread publishes,
        // enters runLoop.run(), and never exits: close()'s semaphore wait times out after
        // five seconds and `isThreadAlive` stays true.
        // **The deadlines below are starvation margins, not assertions about speed.** Each
        // one waits for a hop onto another thread; none of them is measuring how long the
        // product takes. They were 5, 5 and 10 seconds and the middle one timed out twice
        // during M1.5's gate runs, both times inside a heavily loaded `swift test --parallel`
        // -- the first had its slowest suite at 247 s, and the second's log was overwritten
        // by the next gate run before anyone read it, so it has no quotable figure.
        // `close()` is dispatched to the global queue, and under a saturated machine it need
        // not be scheduled promptly. Measured on this machine at the same commit: run alone,
        // the whole suite is 0.70-0.75 s, 12 runs out of 12 green; the failing run that was
        // captured took 5.775 s, i.e. exactly the deadline. A regression that really
        // leaves the thread running still fails here, it just takes the full deadline to do
        // it -- the same trade `expectThreadGone` documents below.
        let reachedWindow = DispatchSemaphore(value: 0)
        let releaseThread = DispatchSemaphore(value: 0)
        let markedClosed = DispatchSemaphore(value: 0)
        let closeReturned = DispatchSemaphore(value: 0)

        let watchdog = MainActorWatchdog(
            threshold: .milliseconds(50), enabled: true, onOverrun: { _ in },
            beforePublishHook: {
                reachedWindow.signal()
                releaseThread.wait()
            },
            afterMarkClosedHook: { markedClosed.signal() })

        #expect(reachedWindow.wait(timeout: DispatchTime.now() + 60) == .success)
        DispatchQueue.global().async {
            watchdog.close()
            closeReturned.signal()
        }
        #expect(markedClosed.wait(timeout: DispatchTime.now() + 60) == .success)
        releaseThread.signal()

        #expect(closeReturned.wait(timeout: DispatchTime.now() + 60) == .success)
        expectThreadGone(watchdog)
        #expect(watchdog.isRunning == false)
    }

    /// `Thread.isFinished` is not guaranteed to be true at the instant a semaphore the
    /// thread signalled on its last line is observed: measured 0-3 stale reads per 2000
    /// iterations on this machine. Retry against a deadline rather than asserting on the
    /// first read. A mutation that really leaves the thread running still fails, it just
    /// takes the full deadline to do it.
    private func expectThreadGone(
        _ watchdog: MainActorWatchdog, within seconds: Double = 2,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let deadline = Date().addingTimeInterval(seconds)
        while watchdog.isThreadAlive && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        #expect(watchdog.isThreadAlive == false, sourceLocation: sourceLocation)
    }

}
