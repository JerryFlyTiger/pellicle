import Testing

@testable import Platform

@Suite("MetricsSubscriber")
struct MetricsTests {
    @Test("subscribing then closing leaves no observer behind")
    func openCloseBalanced() {
        let subscriber = MetricsSubscriber()
        #expect(subscriber.isSubscribed == false)

        subscriber.start()
        #expect(subscriber.isSubscribed == true)
        #expect(subscriber.subscribeCount == 1)

        // A second start() before close() is a no-op, not a double-add: subscribeCount
        // — unlike isSubscribed, which reads identically either way — is what makes the
        // idempotence guard in start() mutation-observable.
        subscriber.start()
        #expect(subscriber.isSubscribed == true)
        #expect(subscriber.subscribeCount == 1)

        subscriber.close()
        #expect(subscriber.isSubscribed == false)
        #expect(subscriber.unsubscribeCount == 1)

        // Idempotent: a second close() must not trap (MXMetricManager.remove on an
        // already-removed subscriber), and must not double-count.
        subscriber.close()
        #expect(subscriber.isSubscribed == false)
        #expect(subscriber.unsubscribeCount == 1)
    }

    @Test("open-N/close-all leaves zero leftover subscribers")
    func openNCloseAll() {
        let subscribers = (0..<5).map { _ in MetricsSubscriber() }
        for s in subscribers { s.start() }
        for s in subscribers { #expect(s.isSubscribed == true) }
        for s in subscribers { s.close() }
        for s in subscribers { #expect(s.isSubscribed == false) }
    }
}
