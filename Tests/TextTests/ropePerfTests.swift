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
        // regression floor to the bound below, matching the design's own claim (see
        // `SumTree.swift`'s file header): near-flat cost in `n`, so the same absolute bar
        // applies at both 1 MB and 10 MB, not just a bar that scales with `n`. Do not read
        // a pass here as "the rope is fast in general"; read a failure as "the leaf-local
        // path regressed or stopped being taken," which is what this specific bound is
        // entitled to claim.
        // The bar was 10 µs until 2026-09-09 (M1.2), when it was found to cut straight
        // through this suite's own noise band rather than sitting above it. Measured on this
        // machine, release, whole-suite runs (which is how this assertion is actually
        // executed, never on its own): the 10 MB fast-path cost ranges 5.4-13.1 µs on
        // unchanged code, and two of six consecutive runs failed at 10.26 and 10.39 µs. What
        // this bound exists to catch is the leaf-local path regressing or ceasing to be
        // taken, and that failure costs 200-627 µs (see the comment above) -- so 25 µs is
        // still 8-25x below the thing it guards while clearing the observed spread. Both
        // sizes keep the *same* bar deliberately: that shared bar is how the design's
        // near-flat-in-n claim is checked, and moving one size alone would silently retire
        // it. Known limitation, recorded rather than papered over: a tighter near-flat check
        // needs a lower-variance measurement method than this suite has today, and a ratio
        // between the two sizes is not it -- dividing two independently noisy numbers grows
        // more likely to fire the better one of them gets.
        let fastPathBound = 0.000_025
        let oneMBCost = meanCosts[1_000_000]!
        let oneMBMessage =
            "single-byte insert into a 1 MB rope took \(oneMBCost)s, over the 25 µs bound "
            + "the M1.1b leaf-local path-copy edit is supposed to guarantee (release build)"
        #expect(oneMBCost < fastPathBound, "\(oneMBMessage)")
        let tenMBCost = meanCosts[10_000_000]!
        let tenMBMessage =
            "single-byte insert into a 10 MB rope took \(tenMBCost)s, over the same 25 µs "
            + "bound as 1 MB — the design's near-flat-in-n claim is what this bound checks "
            + "(release build)"
        #expect(tenMBCost < fastPathBound, "\(tenMBMessage)")
    }

    /// The **general** path's edit cost -- the path M1.1b stage 2 rewrote, and the one no
    /// other benchmark here touches: `scalingRatio` above measures the stage-1 fast path,
    /// which absorbs any edit of at most 64 bytes and so never reaches this code.
    /// `replaceSubrangeGeneralPathOnly` is the `@testable` door that forces the general path,
    /// and a single-scalar insert keeps the number comparable with the ~115 us the M1.1b
    /// design recorded for the old `split`+`concat` implementation at 1 MB.
    ///
    /// Measured when it was added (release, this machine, median of three runs): **12.8 us at
    /// 1 MB and 16.7 at 10 MB**, against 96.8 and 139.2 for the pre-stage-2 code in a
    /// `git worktree` of the previous commit. The bound below is deliberately loose against
    /// those numbers -- it is a regression tripwire, not a target, and the milestone record
    /// warns that this operation has been seen to vary 94-352 us across separate binaries
    /// built from identical source. Assert absolutely at both sizes, never as a ratio: a
    /// uniformly slow implementation has an excellent ratio.
    @Test("general path: single-scalar insert cost at 1 MB and 10 MB")
    func generalPathInsertCost() {
        for n in [1_000_000, 10_000_000] {
            var rng = SplitMix64(seed: 0xBEEF_1234)
            var rope = Rope(String(repeating: "abcdefgh", count: n / 8))
            let one = Rope("x")
            for _ in 0..<3 {
                let at = Int(rng.next() % UInt64(rope.utf8Count))
                rope.replaceSubrangeGeneralPathOnly(at..<at, with: one)
            }
            let samples = 30
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<samples {
                let at = Int(rng.next() % UInt64(rope.utf8Count))
                rope.replaceSubrangeGeneralPathOnly(at..<at, with: one)
            }
            let mean = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(samples)
            print("generalPathInsertCost: n=\(n) mean \(mean / 1000.0) us")
            #expect(
                mean < 60_000,
                "general-path insert at n=\(n) cost \(mean / 1000.0) us, over the 60 us bound")
        }
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

    /// The iteration side of the milestone (M1.1b stage 2 asks for this so the B re-sweep
    /// can see traversal cost, not only edit cost): full traversal of a ~1 MB and a ~10 MB
    /// rope via `chunks()` and via `bytes()`, several repetitions, reporting ns/chunk and
    /// ns/byte. Before M1.2, `chunks()`/`bytes()` flattened the whole tree into an
    /// `[Chunk]` via `SumTree.items()` before the caller ever saw the first one — stage 2
    /// measured that flatten at 6.4 ns/chunk and 0.176 ns/byte (`PLAN.md:1934-1935`). M1.2's
    /// `SumTreeCursor` (`SumTreeCursor.swift`) is what `chunks()`/`bytes()` are built on now
    /// (this test's own code did not change; it is exercising the new lazy path simply by
    /// calling the same production entry points), so a number from here going forward is
    /// measuring the cursor, and the numbers quoted in this doc comment are the pre-M1.2
    /// flatten baseline the cursor was built to beat.
    ///
    /// Prints only; asserts a loose absolute ceiling justified by what was actually measured
    /// on this machine (`-O -wmo`, `swift build -c release`, one process — see this file's
    /// header), not an invented number: an invented bound is worse than none (CLAUDE.md).
    ///
    /// `chunks()`'s ceiling has to be tight enough to catch the thing it exists to catch:
    /// `SumTreeCursor` and its call chain (`next`/`descendLeftmost`/`advanceToNextLeaf`)
    /// crossing `Text`'s module boundary un-inlined if the `@usableFromInline`/`@inlinable`
    /// promotion described in `dev/specs/m1.2-promotion-and-guards.md` is silently reverted.
    /// Measured on this machine: **promoted** 3.5-4.0 ns/chunk (quiet and noisy windows
    /// alike); **de-promoted** (the promotion reverted, cursor calls opaque across the
    /// boundary) 27-57 ns/chunk. A 60 ns/chunk ceiling sits above both bands and cannot tell
    /// them apart — it was measured green with the promotion silently reverted, which is
    /// the specific regression this test exists to catch. **15 ns/chunk** sits clear of both
    /// bands: comfortably above the promoted band's noise, comfortably below the
    /// de-promoted band's floor. If you trip this, the first thing to check is whether the
    /// 14 `@usableFromInline`/`@inlinable` attributes the promotion added to
    /// `SumTreeCursor.swift`/`SumTree.swift` are still there — `dev/check-inlining.sh`'s
    /// task-2b grep checks the same thing from the other side.
    ///
    /// `bytes()`'s ceiling is left alone at 2 ns/byte: it measured ~0.17 ns/byte before and
    /// after the promotion, because `bytes()` materialises its `[UInt8]` result inside
    /// `Text` and hands the caller a finished array — the cross-module boundary the
    /// promotion is about is only crossed by `chunks()`, which streams items one at a time
    /// across it. This asymmetry — a batching API absorbs a per-call boundary cost that a
    /// streaming API cannot — is the shape of every inlining-promotion decision in this
    /// project, not particular to this one test.
    @Test("iteration cost: full traversal via chunks() and bytes(), ~1 MB and ~10 MB")
    func iterationCost() {
        let sizes = [1_000_000, 10_000_000]
        let repetitions = 20
        for n in sizes {
            let rope = Rope(String(repeating: "a", count: n))

            var chunksTotal: TimeInterval = 0
            var chunkCount = 0
            for _ in 0..<repetitions {
                let start = Date()
                var count = 0
                for chunk in rope.chunks() {
                    count += 1
                    _ = chunk.count  // touch each chunk, not just the sequence
                }
                chunksTotal += Date().timeIntervalSince(start)
                chunkCount = count
            }
            let nsPerChunkIteration =
                (chunksTotal / Double(repetitions)) * 1_000_000_000 / Double(chunkCount)
            print(
                "iterationCost: n=\(n) chunks() \(chunkCount) chunks, "
                    + "\(nsPerChunkIteration) ns/chunk")
            let chunkMessage =
                "chunks() traversal of a \(n)-byte rope cost \(nsPerChunkIteration) ns/chunk, "
                + "over the 15 ns/chunk ceiling (release build). Promoted measured "
                + "3.5-4.0 ns/chunk on this machine; de-promoted (the SumTreeCursor "
                + "@usableFromInline/@inlinable promotion reverted) measured 27-57 ns/chunk. "
                + "15 sits clear of both — if this trips, check whether "
                + "dev/check-inlining.sh's task-2b grep also trips, and whether "
                + "SumTreeCursor.swift/SumTree.swift still carry their attributes."
            #expect(nsPerChunkIteration < 15, "\(chunkMessage)")

            var bytesTotal: TimeInterval = 0
            for _ in 0..<repetitions {
                let start = Date()
                var count = 0
                for byte in rope.bytes() {
                    count += Int(byte) & 0  // touch each byte without affecting the count
                    count += 1
                }
                bytesTotal += Date().timeIntervalSince(start)
                #expect(count == n)
            }
            let nsPerByteIteration =
                (bytesTotal / Double(repetitions)) * 1_000_000_000 / Double(n)
            print("iterationCost: n=\(n) bytes() \(n) bytes, \(nsPerByteIteration) ns/byte")
            let byteMessage =
                "bytes() traversal of a \(n)-byte rope cost \(nsPerByteIteration) ns/byte, "
                + "over the 2 ns/byte ceiling (release build)"
            #expect(nsPerByteIteration < 2, "\(byteMessage)")
        }
    }

    /// M1.2 deliverable B's benchmark: `Rope(String)` throughput at 1 MB and 10 MB. There
    /// was **no bulk-build benchmark before this round** — the ~91 MB/s figure the spec
    /// cites (`PLAN.md:1719`) lived only in prose, not in any `@Test`. Asserts absolute
    /// bounds at both sizes (1 MB under 6 ms, 10 MB under 40 ms — see the constants' own
    /// comments below for how each was calibrated against whole-suite noise), with
    /// linearity expressed by the two absolute bounds together rather than by a ratio
    /// assertion, which is exactly the trap M1.1's scaling test fell into (`dev/specs/m1.2.md`
    /// section 1.B, `CLAUDE.md` "How to measure") — see the comment at the bottom of this
    /// function for why a ratio check was tried and removed.
    @Test("bulk-build throughput: Rope(String) at 1 MB and 10 MB")
    func bulkBuildThroughput() {
        let sizes = [1_000_000, 10_000_000]
        let samples = 5
        var medians: [Int: Double] = [:]
        for n in sizes {
            let s = String(repeating: "a", count: n)
            var times: [TimeInterval] = []
            for _ in 0..<samples {
                let start = Date()
                let rope = Rope(s)
                _ = rope.utf8Count  // touch, so this cannot be entirely optimised away
                times.append(Date().timeIntervalSince(start))
            }
            times.sort()
            let median = times[times.count / 2]
            medians[n] = median
            print("bulkBuildThroughput: n=\(n) median \(median * 1000) ms over \(samples) samples")
        }
        let oneMB = medians[1_000_000]!
        let tenMB = medians[10_000_000]!
        // Bounds set from how this suite is actually run, not from this test in isolation.
        // Measured on this machine 2026-09-09, release, twenty runs: run alone (six runs),
        // the 1 MB median sits at 1.72-1.94 ms; run after the rest of RopePerfTests it
        // drifts to 1.85-3.86 ms across fourteen whole-suite runs on identical code (this said
        // 1.92-3.51 while only the first six had been taken; the eight run after the bound
        // was raised widened it, and PLAN.md's record quotes the full range), because the
        // earlier benchmarks leave the
        // allocator in a different state. The original 3 ms bound was taken from the
        // isolated figure and cut straight through the middle of that band: three of six
        // whole-suite runs failed on code that meets its target. A gate that cries wolf on
        // a third of runs stops being read, so the bound is set above the observed
        // whole-suite spread and still far below a gross regression. **It does not catch a
        // revert to the recursive-halving build this milestone replaced, and an earlier
        // version of this comment claimed it did.** That claim rested on PLAN.md's 91 MB/s
        // (~11 ms at 1 MB), which was measured in M1.1b *stage 1*; stage 2's `joinNodes`
        // rewrite sped the old build up as a side effect, and measured in the current tree
        // it costs 2.60 ms at 1 MB and 25.72 ms at 10 MB -- inside both bounds. A mutation
        // that reverts `build` to recursive halving therefore survives this test, which was
        // found by running it. What these bounds do guard is a gross regression (something
        // superlinear or an accidental O(n log n) with a large constant), not this specific
        // change; distinguishing the two builds needs a direct A/B, not a bound.
        let oneMBMessage =
            "1 MB Rope(String) took \(oneMB * 1000) ms, over the 6 ms bound (release build; "
            + "whole-suite spread measured at 1.9-3.9 ms). This is a gross-regression bound: "
            + "it does not distinguish this build from the recursive-halving one it replaced, "
            + "which measures 2.60 ms here"
        #expect(oneMB < 0.006, "\(oneMBMessage)")
        // 10 MB bound, calibrated the same way as the 1 MB one above rather than assumed:
        // the main conversation measured this whole-suite (not in isolation, for the same
        // reason the 1 MB bound above is set from the whole-suite spread) at 20.9-24.5 ms,
        // leaving only ~22% headroom under the original 30 ms bound -- too tight against a
        // spread this suite has already shown drifts under load. Raised to 40 ms.
        // **It does not catch a revert to the recursive-halving build.** An earlier version
        // of this comment said it did, citing ~110 ms at 10 MB -- a linear extrapolation
        // from PLAN.md's 91 MB/s that was never measured at 10 MB and is now wrong at any
        // size: measured in the current tree, that build costs 25.72 ms at 10 MB, inside
        // this bound. Stage 2's `joinNodes` rewrite sped it up long before M1.2 touched it.
        // A mutation reverting `build` was run and survived. Gross-regression bound only.
        let tenMBMessage =
            "10 MB Rope(String) took \(tenMB * 1000) ms, over the 40 ms bound (release build; "
            + "whole-suite spread measured at 20.9-24.5 ms). Gross-regression bound: it does "
            + "not distinguish this build from the recursive-halving one, which measures "
            + "25.72 ms here"
        #expect(tenMB < 0.040, "\(tenMBMessage)")
        // Linearity is asserted by the two absolute bounds together, not by their ratio:
        // 40 ms at 10 MB is less than ten times the 6 ms bound at 1 MB (60 ms), so a
        // *grossly* superlinear build cannot pass both, and that relationship must keep
        // holding whenever either bound is changed. Do not read more into it than that.
        // The build this one replaced was itself near-linear in practice (2.60 ms at 1 MB
        // against 25.72 at 10 MB, a 9.9x for 10x the input), so superlinear scaling was
        // never the failure mode actually on the table here. A ratio assertion was tried here and removed: it
        // divides two independently noisy measurements, so it grows *more* likely to fire
        // the better the 1 MB number gets, which is backwards for a guard -- one
        // whole-suite run failed it while the 1 MB median was a healthy 2.3 ms.
    }

    /// M1.2 deliverable A's benchmark: `Rope.convert` cost at 1 MB and 10 MB, asserted as an
    /// absolute bound (`dev/specs/m1.2.md` section 3) -- this is the O(log n) claim
    /// `PLAN.md:460`/`PLAN.md:592` make: reach the containing chunk via `SumTree.find` (O(h),
    /// allocation-free), then scan within it (O(64)). A conversion that scanned from the
    /// start of the buffer would still pass a *ratio* check (uniformly slower at both sizes)
    /// but fail this absolute one.
    @Test("conversion cost: Rope.convert(utf8 -> utf16) at 1 MB and 10 MB")
    func conversionCost() {
        for n in [1_000_000, 10_000_000] {
            var rng = SplitMix64(seed: 0x517A_1234)
            let rope = Rope(String(repeating: "abcdefgh", count: n / 8))
            let samples = 30
            var total: TimeInterval = 0
            for _ in 0..<samples {
                let offset = Int(rng.next() % UInt64(rope.utf8Count))
                let start = Date()
                _ = rope.convert(offset: offset, from: .utf8, to: .utf16)
                total += Date().timeIntervalSince(start)
            }
            let mean = total / Double(samples)
            print("conversionCost: n=\(n) mean \(mean * 1_000_000) us")
            let message =
                "Rope.convert at n=\(n) cost \(mean * 1_000_000) us, over the 60 us bound "
                + "(release build) -- a regression tripwire, not a target: it should stay near "
                + "the same O(h) cost `SumTree.find` itself has, not grow with n"
            #expect(mean < 0.000_060, "\(message)")
        }
    }
}
