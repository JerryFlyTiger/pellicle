import Foundation
import MetricKit
import os

/// Metrics: `MXMetricManager` subscription from day one (PLAN.md 4.14 rule 14). Payloads
/// and diagnostics MetricKit delivers (hangs, CPU exceptions, crashes) are logged as a
/// one-line summary each through `OSLog`; nothing is retained beyond that.
///
/// MetricKit delivers nothing during a normal test run (payloads arrive on the system's
/// own schedule, at most once a day), so the test here only checks the open/close shape:
/// subscribing then unsubscribing leaves no observer behind — PLAN.md 4.14 rule 9's
/// "open-N/close-all/assert-zero-leftovers" pattern.
package final class MetricsSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private static let metricsLog = OSLog(subsystem: Signposts.subsystem, category: "metrics")

    private let lock = NSLock()
    private var subscribed = false

    // Incremented only when start()/close() actually pass the idempotence guard below
    // (i.e. actually call add(self)/remove(self)), not once per call. These exist so
    // MetricsTests can observe the guard itself: `isSubscribed` alone reads identically
    // whether MXMetricManager.shared.add(self) ran once or twice, so a test asserting
    // only on it cannot tell a working guard from a deleted one.
    private var subscribeCountStorage = 0
    private var unsubscribeCountStorage = 0

    /// How many times `start()`/`close()` actually crossed their idempotence guard, as
    /// opposed to how many times they were called. Read under the same lock as
    /// `isSubscribed`: a plain stored property would be the one piece of this
    /// `@unchecked Sendable` type read without it.
    ///
    /// **Taking the lock here is not observable by any test.** The violation it fixes is a
    /// concurrency-contract one, and every existing caller is single-threaded, so the
    /// value returned is identical with or without the lock: a mutation that deletes the
    /// `lock.lock()` from these getters fails nothing. Per `CLAUDE.md`, that is said here
    /// rather than covered by a test that would not notice. What *is* observable is the
    /// counting itself — deleting either increment fails `MetricsTests`.
    package var subscribeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return subscribeCountStorage
    }

    package var unsubscribeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return unsubscribeCountStorage
    }

    package override init() {
        super.init()
    }

    /// Subscribes to `MXMetricManager.shared`. Call once; a second call before `close()`
    /// is a no-op.
    package func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !subscribed else { return }
        MXMetricManager.shared.add(self)
        subscribed = true
        subscribeCountStorage += 1
    }

    /// Unsubscribes. Idempotent: a second call is a no-op.
    package func close() {
        lock.lock()
        defer { lock.unlock() }
        guard subscribed else { return }
        MXMetricManager.shared.remove(self)
        subscribed = false
        unsubscribeCountStorage += 1
    }

    package var isSubscribed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return subscribed
    }

    // MARK: - MXMetricManagerSubscriber

    package func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            os_log(
                "metric payload: period %{public}@ to %{public}@", log: Self.metricsLog,
                type: .info, payload.timeStampBegin.description, payload.timeStampEnd.description)
        }
    }

    package func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            os_log(
                "diagnostic payload: period %{public}@ to %{public}@", log: Self.metricsLog,
                type: .info, payload.timeStampBegin.description, payload.timeStampEnd.description)
        }
    }
}
