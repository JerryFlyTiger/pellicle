import Foundation
import Testing

@testable import Text

/// `IntervalTree`'s perf suite (M1.4, `dev/specs/m1.4.md` section 4): one edit benchmark
/// (100k intervals, random offsets) and one query benchmark, with absolute bounds. Gated
/// behind the `.performance` tag exactly like `markerTreePerfTests.swift`: `swift test`
/// skips this file; so does `PELLICLE_PERF=1 swift test` (debug); only `PELLICLE_PERF=1
/// swift test -c release --filter IntervalTreePerfTests` runs it.
///
/// **A perf number from a debug build is not evidence** — `swift test` always builds
/// `-Onone` (see `perfTag.swift`'s `isDebugBuild`). Every number this file prints or asserts
/// on should be read as "release build, this machine." The four measurement rules of the
/// M1.3 record (in `CLAUDE.md`) apply here too: build with `-O -wmo`, `DispatchTime.now()`
/// read once around the whole sample loop (not `Date()`, whose smallest tick on this
/// machine is 0.9537 us), the fixture held with `withExtendedLifetime` so its O(n) release
/// does not land inside the timed region, and an absolute bound rather than only a ratio.
@Suite(
    .tags(.performance),
    .enabled(if: ProcessInfo.processInfo.environment["PELLICLE_PERF"] != nil && !isDebugBuild))
struct IntervalTreePerfTests {

    /// Builds `n` non-overlapping intervals, one every 8 bytes (`(8i, 8i+1)`), spread across
    /// the same shape `markerTreePerfTests.swift`'s `buildMarkers` uses for markers.
    private static func buildIntervals(_ n: Int) -> IntervalTree {
        var sorted: [(range: Range<Int>, id: IntervalID, frontAdvance: Bool, rearAdvance: Bool)] =
            []
        sorted.reserveCapacity(n)
        for i in 0..<n {
            sorted.append(
                (
                    range: (8 * i)..<(8 * i + 1), id: IntervalID(i), frontAdvance: i % 2 == 0,
                    rearAdvance: i % 3 == 0
                ))
        }
        return IntervalTree(sortedIntervals: sorted)
    }

    /// A single-byte insertion at a random offset, against 100,000 intervals — the edit
    /// benchmark `dev/specs/m1.4.md` section 4 asks for. Every sample re-derives `var tree =
    /// base` (an O(1) reference copy of a persistent tree, not a deep copy), and `base`'s
    /// release is held outside the timed region with `withExtendedLifetime` — the exact
    /// shape `markerTreePerfTests.swift`'s `insertBeforeAllMarkers` uses, for the same
    /// reason (that file's fix-round-3 story: an untended release lands inside the timed
    /// region and inflates the mean by a one-off O(n) teardown cost).
    @Test("edit: single-byte insertion at a random offset, n = 100,000")
    func randomOffsetInsertion() {
        let n = 100_000
        let base = Self.buildIntervals(n)
        let samples = 1000
        var rng = SplitMix64(seed: 0x1DEA_1DEA)
        let offsets = (0..<samples).map { _ in Int(rng.next() % UInt64(8 * n)) }
        var touchAccumulator = 0
        withExtendedLifetime(base) {
            let start = DispatchTime.now().uptimeNanoseconds
            for i in 0..<samples {
                var tree = base
                let offset = offsets[i]
                tree = tree.applyEdit(byteRange: offset..<offset, insertedLength: 1)
                touchAccumulator &+= tree.start(ofRank: i % tree.count)
            }
            let elapsedNanos = DispatchTime.now().uptimeNanoseconds - start
            let mean = Double(elapsedNanos) / Double(samples) / 1_000_000_000
            print(
                "randomOffsetInsertion: n=\(n) mean \(mean * 1_000_000) us over \(samples) "
                    + "samples (touchAccumulator=\(touchAccumulator))"
            )
            // Absolute bound, not only a ratio (`CLAUDE.md` "How to measure"): 50 us gives
            // generous headroom over an O(log n) descent (a handful of node visits at this
            // size, per `editVisitsAreConstantWhenNothingStraddles`'s counted evidence) while
            // still catching a fall back to true O(n) (a per-interval shift at 100k, even at
            // an optimistic ~50 ns/interval, is 5 ms -- 100x over this bound).
            let message =
                "single-byte insertion at a random offset among \(n) intervals took "
                + "\(mean * 1_000_000) us, over the 50 us bound (release build)"
            #expect(mean < 0.000_050, "\(message)")
        }
    }

    /// An overlap query at a random point, against 100,000 intervals with a scattering of
    /// straddling ranges so the query's `k` is not always zero. The query benchmark
    /// `dev/specs/m1.4.md` section 4 asks for.
    @Test("query: intervals(overlapping:) at a random point, n = 100,000")
    func randomOverlapQuery() {
        let n = 100_000
        var sorted: [(range: Range<Int>, id: IntervalID, frontAdvance: Bool, rearAdvance: Bool)] =
            []
        sorted.reserveCapacity(n)
        // A mix of short non-overlapping intervals and occasional longer ones that straddle
        // several query points, so the query benchmark is not exclusively measuring the
        // k = 0 case.
        for i in 0..<n {
            let length = i % 500 == 0 ? 400 : 1
            sorted.append(
                (
                    range: (8 * i)..<(8 * i + length), id: IntervalID(i), frontAdvance: false,
                    rearAdvance: false
                ))
        }
        let base = IntervalTree(sortedIntervals: sorted)
        let samples = 1000
        var rng = SplitMix64(seed: 0xBEEF_CAFE)
        let queryPoints = (0..<samples).map { _ in Int(rng.next() % UInt64(8 * n)) }
        var touchAccumulator = 0
        withExtendedLifetime(base) {
            let start = DispatchTime.now().uptimeNanoseconds
            for i in 0..<samples {
                let p = queryPoints[i]
                let results = base.intervals(
                    overlapping: p..<(p + 1), includingEmptyAtUpperBound: false)
                touchAccumulator &+= results.count
            }
            let elapsedNanos = DispatchTime.now().uptimeNanoseconds - start
            let mean = Double(elapsedNanos) / Double(samples) / 1_000_000_000
            print(
                "randomOverlapQuery: n=\(n) mean \(mean * 1_000_000) us over \(samples) "
                    + "samples (touchAccumulator=\(touchAccumulator))"
            )
            // Absolute bound: 50 us, the same headroom rationale as the edit benchmark above
            // -- this query is O(log n + k) with k small at this fixture's density.
            let message =
                "overlap query at a random point among \(n) intervals took "
                + "\(mean * 1_000_000) us, over the 50 us bound (release build)"
            #expect(mean < 0.000_050, "\(message)")
        }
    }

    /// **The guard on piece 1's scan**, which the milestone's central complexity claim rests
    /// on and which nothing else protects. `intervals(overlapping:)`'s first piece walks the
    /// intervals whose start lies inside the query range with one descent and then `k` cursor
    /// steps, reconstructing each absolute start from the record's own `gap`. The
    /// implementation shipped in the first round did a fresh root-to-leaf `find` per scanned
    /// item instead, making the scan O(k log n) — a defect a cold read caught, and one **no
    /// correctness test can see**, because the results are identical either way. The counted
    /// visit tests cannot see it either: they instrument piece 2's prune, and piece 1 does not
    /// go through `visitItems` at all. So the guard has to be a timed one, and it has to have
    /// a `k` large enough for the `log n` factor to show: this fixture puts 100,000 intervals
    /// one byte apart and asks for a 2,000-byte window, so `k` is exactly 2,000 against a tree
    /// of **height 4** — 100,000 items bulk-build to 8,334 leaves, then 695, 58, 5 and the
    /// root, which cross-checks against the marker tree's counted `height + 1` visits of
    /// 4 / 5 / 6 at 10k / 100k / 1M in `PLAN.md` 4.5. (This comment said "height 6 or 7"
    /// until a cold read recomputed it; that figure belongs to `SumTree.swift`'s remark about
    /// a 2 GB *rope*, a different structure at a different scale.)
    @Test("query: a 2,000-result window, the guard on piece 1's O(log n + k) scan, n = 100,000")
    func largeResultOverlapQuery() {
        let n = 100_000
        let sorted: [(range: Range<Int>, id: IntervalID, frontAdvance: Bool, rearAdvance: Bool)] =
            (0..<n).map {
                (range: $0..<($0 + 1), id: IntervalID($0), frontAdvance: false, rearAdvance: false)
            }
        let base = IntervalTree(sortedIntervals: sorted)
        let samples = 200
        let window = 2_000
        var rng = SplitMix64(seed: 0x5EED_1234)
        let queryStarts = (0..<samples).map { _ in Int(rng.next() % UInt64(n - window)) }
        var touchAccumulator = 0
        withExtendedLifetime(base) {
            let start = DispatchTime.now().uptimeNanoseconds
            for i in 0..<samples {
                let p = queryStarts[i]
                let results = base.intervals(
                    overlapping: p..<(p + window), includingEmptyAtUpperBound: false)
                touchAccumulator &+= results.count
            }
            let elapsedNanos = DispatchTime.now().uptimeNanoseconds - start
            let mean = Double(elapsedNanos) / Double(samples) / 1_000_000_000
            print(
                "largeResultOverlapQuery: n=\(n) window=\(window) mean \(mean * 1_000_000) us "
                    + "over \(samples) samples (touchAccumulator=\(touchAccumulator))"
            )
            // Absolute bound, set from measurement rather than from theory, with the
            // per-item-`find` regression measured on this machine for contrast; both numbers
            // are in `PLAN.md` 4.5's query row and nowhere else.
            let message =
                "a \(window)-result overlap query among \(n) intervals took "
                + "\(mean * 1_000_000) us, over the bound (release build)"
            #expect(mean < 0.000_120, "\(message)")
        }
    }
}
