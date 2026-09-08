import Foundation
import Testing

@testable import Text

/// The M1 family's million-edit property run, plus the scaling and teardown claims PLAN.md
/// 4.5 makes about the rope (O(log n) edits, no recursive-teardown hazard). Gated behind
/// the `.performance` tag (see `perfTag.swift`): `swift test` skips this file; so does
/// `PELLICLE_PERF=1 swift test` (debug); only `PELLICLE_PERF=1 swift test -c release
/// --filter RopePerfTests` runs it. Each test states the seed it used, so a failure here is
/// reproducible.
///
/// **A perf number from a debug build is not evidence.** `swift test` always builds in
/// debug, which is `-Onone`; only `swift build -c release` passes
/// `-whole-module-optimization` (see `perfTag.swift`'s `isDebugBuild` for how this was
/// verified). Every number this file prints or asserts on should be read as "release build,
/// this machine" — state the build configuration alongside any number quoted from here.
@Suite(
    .tags(.performance),
    .enabled(if: ProcessInfo.processInfo.environment["PELLICLE_PERF"] != nil && !isDebugBuild))
struct RopePerfTests {

    /// Scalar boundaries in `bytes`, used to draw only valid edit offsets — duplicated
    /// (not shared) from `ropeTests.swift`'s helper of the same shape, deliberately: a perf
    /// suite should not depend on the correctness suite's fixtures changing underneath it.
    private static func scalarBoundaries(_ bytes: [UInt8]) -> [Int] {
        var result = [0]
        for i in 0..<bytes.count where bytes[i] & 0b1100_0000 != 0b1000_0000 {
            if i != 0 { result.append(i) }
        }
        result.append(bytes.count)
        return result
    }

    /// Draws a `lo..<hi` range whose width is bounded (`1...64` bytes) regardless of
    /// `model`'s size — duplicated from `ropeTests.swift`'s helper of the same shape for the
    /// same reason `scalarBoundaries` above is: a perf suite should not depend on the
    /// correctness suite's fixtures changing underneath it.
    private static func boundedRange(
        _ boundaries: [Int], using rng: inout SplitMix64
    ) -> (lo: Int, hi: Int)? {
        let loIdx = Int(rng.next() % UInt64(boundaries.count))
        let lo = boundaries[loIdx]
        let rawHi = lo + 1 + Int(rng.next() % 64)
        var hiIdx = loIdx
        while hiIdx + 1 < boundaries.count && boundaries[hiIdx + 1] <= rawHi {
            hiIdx += 1
        }
        if hiIdx == loIdx {
            guard hiIdx + 1 < boundaries.count else { return nil }
            hiIdx += 1
        }
        let hi = boundaries[hiIdx]
        return lo < hi ? (lo, hi) : nil
    }

    /// Runs `operationCount` random insert/delete/replace operations against `rope` and a
    /// parallel `[UInt8]` model, keeping the rope's size within `[minSize, maxSize]`.
    /// Verifies the full byte content every `verifyEvery` operations and `checkInvariants()`
    /// every `invariantsEvery` operations plus once more at the end, failing with the seed
    /// and operation index on the first mismatch (so a failure here is reproducible without
    /// rerunning). Delete/replace widths are bounded to 1...64 bytes regardless of the
    /// rope's size (see `ropeTests.swift`'s `boundedRange` doc comment for why an
    /// *unbounded* width collapses the size random walk); `minSize` is the guard, symmetric
    /// with `maxSize`, that keeps that bounded-width walk from draining down to empty
    /// instead of oscillating in-band.
    ///
    /// `invariantsEvery` here is a **compromise**, not the default tier's "every operation":
    /// checking a rope of this size on every one of a million operations is too expensive
    /// for a perf run. That compromise has a measured cost — with `rewrap`'s split mutated
    /// to produce a malformed one-child interior node, a malformed node self-heals in
    /// ~0.26 operations on average (a later `concat` re-folds and repairs it), so checking
    /// every 1,000 ops caught 0 of the violations that checking every operation would have
    /// caught, and every 50 ops caught only 2. Every-100 plus the unconditional final check
    /// (above) is this file's balance between coverage and run time; see
    /// `M1.1-perf-findings.md` for the measurement.
    private static func runModelProperty(
        seed: UInt64,
        operationCount: Int,
        initialSize: Int,
        minSize: Int,
        maxSize: Int,
        verifyEvery: Int,
        invariantsEvery: Int
    ) {
        var rng = SplitMix64(seed: seed)
        // Pre-populate so the run actually exercises a tree of the intended scale
        // throughout, rather than (say) 20,000 single-character edits slowly drifting up
        // from empty and never approaching `maxSize` at all.
        var model: [UInt8] = Array(String(repeating: "m", count: initialSize).utf8)
        var rope = Rope(String(repeating: "m", count: initialSize))
        let pool: [String] = ["a", "b", "\n", "é", "字", "xy", "line\n"]
        var minModelSize = model.count
        var maxModelSize = model.count

        for opIndex in 0..<operationCount {
            let boundaries = Self.scalarBoundaries(model)
            let kind = rng.next() % 3
            switch kind {
            case 0:
                // Same "guard the result, not the input" fix as the delete/replace cases
                // below, for the upper bound: an insert can add a few bytes, so checking
                // only `model.count < maxSize` beforehand can let the result overshoot.
                let at = boundaries[Int(rng.next() % UInt64(boundaries.count))]
                let text = pool[Int(rng.next() % UInt64(pool.count))]
                if model.count + text.utf8.count <= maxSize {
                    rope.insert(text, at: at)
                    model.insert(contentsOf: Array(text.utf8), at: at)
                }
            case 1:
                // Guard on the *resulting* size (`model.count - (hi - lo) >= minSize`), not
                // just the size going in: `boundedRange` can remove up to 64 bytes, so a
                // pre-op-only guard (`model.count > minSize`) can still let the result
                // undershoot the floor by up to 63 bytes — measured: minModelSize 4033
                // against a 4096 floor before this fix.
                if let (lo, hi) = Self.boundedRange(boundaries, using: &rng),
                    model.count - (hi - lo) >= minSize
                {
                    rope.removeSubrange(lo..<hi)
                    model.removeSubrange(lo..<hi)
                }
            default:
                if let (lo, hi) = Self.boundedRange(boundaries, using: &rng) {
                    let text = pool[Int(rng.next() % UInt64(pool.count))]
                    let resultingSize = model.count - (hi - lo) + text.utf8.count
                    if resultingSize >= minSize && resultingSize <= maxSize {
                        rope.replaceSubrange(lo..<hi, with: text)
                        model.replaceSubrange(lo..<hi, with: Array(text.utf8))
                    }
                }
            }

            minModelSize = min(minModelSize, model.count)
            maxModelSize = max(maxModelSize, model.count)

            if opIndex % verifyEvery == 0 {
                let ropeBytes = Array(rope.bytes())
                #expect(
                    ropeBytes == model,
                    "seed \(seed), op \(opIndex): byte mismatch"
                )
            }
            if opIndex % invariantsEvery == 0 {
                do {
                    try rope.checkTreeInvariants()
                } catch {
                    Issue.record("seed \(seed), op \(opIndex): invariant violation \(error)")
                }
            }
        }
        // Final full check regardless of cadence, so the last operation is never the one
        // that silently goes unverified.
        #expect(Array(rope.bytes()) == model, "seed \(seed): final byte mismatch")
        do {
            try rope.checkTreeInvariants()
        } catch {
            Issue.record("seed \(seed): final invariant violation \(error)")
        }
        // Non-degeneracy: the run must actually have stayed inside the band the caller
        // asked for, not merely started there. See `M1.1-perf-findings.md` for why the size
        // random walk collapses without this.
        let bandMessage =
            "seed \(seed): model size ranged [\(minModelSize),\(maxModelSize)], outside the "
            + "required band [\(minSize),\(maxSize)]"
        #expect(minModelSize >= minSize, "\(bandMessage)")
        #expect(maxModelSize <= maxSize, "\(bandMessage)")
    }

    @Test("1,000,000 operations on a rope bounded to ~8 KB")
    func millionOperationsSmallRope() {
        let seed: UInt64 = 0x1_000_000
        let start = Date()
        Self.runModelProperty(
            seed: seed, operationCount: 1_000_000, initialSize: 6 * 1024, minSize: 4 * 1024,
            maxSize: 8 * 1024, verifyEvery: 1_000, invariantsEvery: 100)
        let elapsed = Date().timeIntervalSince(start)
        print("millionOperationsSmallRope: 1,000,000 ops in \(elapsed)s (seed \(seed))")
    }

    @Test("20,000 operations on a ~4 MB rope")
    func twentyThousandOperationsLargeRope() {
        let seed: UInt64 = 0x4_000_000
        let start = Date()
        Self.runModelProperty(
            seed: seed, operationCount: 20_000, initialSize: 3 * 1024 * 1024,
            minSize: 1024 * 1024, maxSize: 4 * 1024 * 1024, verifyEvery: 1_000,
            invariantsEvery: 100)
        let elapsed = Date().timeIntervalSince(start)
        print("twentyThousandOperationsLargeRope: 20,000 ops in \(elapsed)s (seed \(seed))")
    }

    @Test("scaling: mean cost of a single random insert at n = 10^4 .. 10^7 bytes")
    func scalingRatio() {
        var rng = SplitMix64(seed: 0x5CA1_E000)
        let scales = [10_000, 100_000, 1_000_000, 10_000_000]
        var meanCosts: [Int: Double] = [:]

        for n in scales {
            let base = Rope(String(repeating: "a", count: n))
            let samples = 30
            var total: TimeInterval = 0
            for _ in 0..<samples {
                var rope = base
                let at = Int(rng.next() % UInt64(n + 1))
                let start = Date()
                rope.insert("x", at: at)
                total += Date().timeIntervalSince(start)
            }
            let mean = total / Double(samples)
            meanCosts[n] = mean
            print("scalingRatio: n=\(n) mean insert cost \(mean)s")
        }

        let smallCost = meanCosts[scales.first!]!
        let largeCost = meanCosts[scales.last!]!
        let ratio = largeCost / smallCost
        print("scalingRatio: ratio over three decades = \(ratio)")
        #expect(
            ratio < 8,
            "per-edit cost at 10^7 bytes (\(largeCost)s) is more than 8x the cost at 10^4 bytes (\(smallCost)s): ratio \(ratio)"
        )

        // A ratio across three decades of n is satisfied by an implementation that is
        // uniformly slow — which is exactly what this rope was before the M1.1 fix round:
        // the ratio was a comfortable ~3.7 while every individual operation was ~100x too
        // slow (measured 627 µs for a single-byte insert into a 1 MB rope; see
        // `M1.1-perf-findings.md`). An absolute companion bound is the only thing that
        // catches that. M1.1b stage 1's leaf-local path-copy edit (`SumTree.pathCopyEdit`,
        // `Rope.tryLeafLocalReplace`) is what tightens this from that round's loose 200 µs
        // regression floor to the 10 µs bound below, matching the design's own claim (see
        // `SumTree.swift`'s file header): near-flat cost in `n`, so the same absolute bar
        // applies at both 1 MB and 10 MB, not just a bar that scales with `n`. Do not read
        // a pass here as "the rope is fast in general"; read a failure as "the leaf-local
        // path regressed or stopped being taken," which is what this specific bound is
        // entitled to claim.
        let oneMBCost = meanCosts[1_000_000]!
        let oneMBMessage =
            "single-byte insert into a 1 MB rope took \(oneMBCost)s, over the 10 µs bound "
            + "the M1.1b leaf-local path-copy edit is supposed to guarantee (release build)"
        #expect(oneMBCost < 0.000_010, "\(oneMBMessage)")
        let tenMBCost = meanCosts[10_000_000]!
        let tenMBMessage =
            "single-byte insert into a 10 MB rope took \(tenMBCost)s, over the same 10 µs "
            + "bound as 1 MB — the design's near-flat-in-n claim is what this bound checks "
            + "(release build)"
        #expect(tenMBCost < 0.000_010, "\(tenMBMessage)")
    }

    @Test("release without deep recursion: build and drop a ~64 MB rope a few times")
    func releaseWithoutDeepRecursion() {
        // Smoke test, not a proof: if `Node`'s release recursed per-item rather than
        // per-level, this would crash (stack overflow) rather than merely being slow,
        // since a ~64 MB rope has roughly one million chunks. Passing only shows the
        // teardown completed, not that it was O(log n) — see SumTree.swift's header for
        // the argument that it must be, by construction (height is logarithmic).
        for iteration in 0..<4 {
            let bytes = String(repeating: "a", count: 64 * 1024 * 1024)
            var rope = Rope(bytes)
            rope.insert("x", at: 0)  // touch it, so this is not purely dead-code-eliminated
            _ = rope.utf8Count
            rope = Rope()  // drop the ~64 MB tree
            print("releaseWithoutDeepRecursion: iteration \(iteration) completed")
        }
    }
}
