import Foundation
import Testing

@testable import Text

/// `MarkerTree`'s perf suite (M1.3, `dev/specs/m1.3.md` section 4): the milestone's headline
/// claim (a single-byte insertion before every marker in the tree costs O(log n), not
/// O(n)), the O(k) collapse cost measured rather than hidden, and the 1M-marker memory
/// footprint printed rather than asserted from arithmetic. Gated behind the `.performance`
/// tag (see `perfTag.swift`): `swift test` skips this file; so does `PELLICLE_PERF=1 swift
/// test` (debug); only `PELLICLE_PERF=1 swift test -c release --filter MarkerTreePerfTests`
/// runs it.
///
/// **A perf number from a debug build is not evidence** — `swift test` always builds
/// `-Onone` (see `perfTag.swift`'s `isDebugBuild`). Every number this file prints or asserts
/// on should be read as "release build, this machine."
@Suite(
    .tags(.performance),
    .enabled(if: ProcessInfo.processInfo.environment["PELLICLE_PERF"] != nil && !isDebugBuild))
struct MarkerTreePerfTests {

    /// Builds `n` markers via `init(sortedMarkers:)` (bulk O(n)), one every 8 bytes so the
    /// resulting keys are well spread — matching the shape a real buffer's marker population
    /// would have, rather than every marker packed at the same offset.
    private static func buildMarkers(_ n: Int) -> MarkerTree {
        var sorted: [(byteOffset: Int, bias: MarkerBias, id: MarkerID)] = []
        sorted.reserveCapacity(n)
        for i in 0..<n {
            let bias: MarkerBias = i % 2 == 0 ? .left : .right
            sorted.append((byteOffset: i * 8, bias: bias, id: MarkerID(i)))
        }
        return MarkerTree(sortedMarkers: sorted)
    }

    /// **The milestone's headline test.** A single-byte insertion at byte offset 0 — before
    /// every marker in the tree — is the worst case for "adjust every marker after the
    /// edit": gap encoding makes this a single-item `pathCopyEdit`, O(log n), independent of
    /// how many markers follow (`MarkerTree.swift`'s file header; `dev/specs/m1.3.md` section
    /// 1). Trees are built once per size via the bulk loader (O(n)) outside the timed loop —
    /// 1M sequential `inserting` calls would dominate the measurement and this test would
    /// stop measuring `applyEdit` at all.
    ///
    /// **Re-instrumented (M1.3 fix round 2).** The first version timed each sample
    /// individually with `Date()` and printed the *identical* mean at n=10,000 and n=100,000
    /// to 13 significant figures — the tell that every sample was landing at zero or one
    /// timer tick. Measured on this machine: `Date()`'s smallest non-zero tick is 0.9537 us,
    /// and the reported means (0.5-0.9 us) were sub-tick, so that version was reading how
    /// many of the 30 samples happened to straddle a tick boundary, not the operation's cost.
    /// Re-instrumented in the shape `generalPathInsertCost` uses (`ropePerfTests.swift:289-
    /// 294`, added for M1.1b stage 2 for the same reason): one `DispatchTime.now()` read
    /// (nanosecond resolution) before the whole batch, one after, divided by the sample
    /// count, so the clock-read cost is amortised across the batch instead of dominating each
    /// individual sample.
    ///
    /// **Re-instrumented again (M1.3 fix round 3): the round-2 numbers above were still
    /// wrong, for a second, different reason from the `Date()` tick problem.** `base` is
    /// bound with `let` inside the `for n in sizes` loop, and its last use is inside the
    /// timed sample loop (`var tree = base`); ARC therefore releases `base` — an O(n)
    /// `MarkerTree` teardown, measured directly at 1.7-2.8 ms at 1M and 155 us at 100k —
    /// somewhere inside the timed region, most likely right at the closing clock read, and
    /// that one-off teardown cost was being divided by the sample count along with the real
    /// per-sample work. An architect investigation established this with four independent
    /// lines of evidence, including: total elapsed time is affine in the sample count
    /// (slope 1.11 us/sample, intercept 2.90 ms at 1M, i.e. almost the whole total at low
    /// sample counts is the one-off, not the per-sample cost); a 200-iteration warm-up
    /// changes nothing, ruling out cold cache as the cause; and adding one statement that
    /// keeps `base` alive past the timed loop (`withExtendedLifetime` below) drops the 1M
    /// mean from 95.91 us to 1.07 us in isolation. **`_ = base.count` after the loop is
    /// *not* a fix**: a pure read whose result is discarded can be — and, measured, was —
    /// optimised away, which puts `base`'s release straight back inside the timed region.
    /// `withExtendedLifetime(base) { ... }` wrapping the whole timed region is the only form
    /// that reliably keeps the release outside it; removing it silently reintroduces the
    /// O(n) teardown into the measurement, invisibly from the source, which is why this
    /// comment says so explicitly rather than trusting the next reader to notice.
    ///
    /// Each sample re-derives `var tree = base` from the same bulk-built `base` tree rather
    /// than mutating one tree across the batch: `base` is an immutable, structurally-shared
    /// persistent tree, so `var tree = base` is an O(1) reference copy, not a deep copy, and
    /// every sample therefore does the identical amount of work (single-byte insert before
    /// n markers) rather than n+1, n+2, ... markers as a cumulative version would drift to.
    /// The result is not thrown away: each sample's rank-0 position is accumulated with
    /// `&+=` into `touchAccumulator`, which is printed after the loop, so a compiler cannot
    /// prove the batch's results are unobserved and delete the whole loop.
    ///
    /// **Edits land at varying, precomputed offsets, not always at byte 0 (fix round 3).**
    /// Offset 0 is the leftmost spine of the tree — the one access pattern that never pays
    /// the cache cost a real edit pays, since it revisits the same first-child chain every
    /// sample. Offsets are drawn once, before the timed loop, so the RNG itself is not part
    /// of what is timed. **One-off diagnostic, not re-derived by this suite** (from a
    /// separate calibration run made while diagnosing the round-3 teardown artifact, at a
    /// 3,000,000-marker size this suite does not build): random-offset edits measured +11%
    /// at 10k and +21% at 1M against a fixed offset-0 edit — real but small.
    ///
    /// **Counted, not inferred: node visits are `height + 1`.** `pathCopyEditNode` recurses
    /// into exactly one child per level on this single-item edit, so the number of nodes
    /// visited is the tree's height plus one — counted directly at 4 / 5 / 6 for n =
    /// 10,000 / 100,000 / 1,000,000, with 20-34 summary comparisons for an edit anywhere in
    /// the tree at every size. This is the evidence for the O(log n) headline claim; the
    /// wall-clock numbers below are a consequence of it, not a restatement of it.
    ///
    /// Mean of 1000 samples per size, one process, release build (raised from 30 in fix
    /// round 3: at 30 samples, any residual one-off of tens of microseconds is divided by
    /// only 30 and can dominate the mean the way the teardown bug above did; at 1000 the
    /// whole run costs about a millisecond, and a similarly sized one-off is 30x more
    /// diluted). Absolute bounds at each size — never a ratio alone: this project has
    /// twice paid for a ratio that passed while every operation was ~100x too slow
    /// (`CLAUDE.md` "How to measure").
    ///
    /// **Numbers below are this test's own final run on the shipped code, this machine,
    /// release build, `-c release`, whole-`MarkerTreePerfTests`-file runs (this suite's own
    /// tests interact with each other's allocator state, so numbers taken in isolation from
    /// the rest of the file are not representative — see `memoryForOneMillionMarkers`'s doc
    /// comment for a case where that interaction actually flipped a result) — not the
    /// architect-worktree calibration figures fix round 3's narrative above cites (those
    /// were measured in a separate worktree and are a diagnostic, not a re-run of this
    /// test).** Fix round 4, four whole-file runs: 1.02-1.06 / 1.13-1.24 / 1.58-1.66 us at
    /// n=10,000 / 100,000 / 1,000,000. This *is* the flat-ish, log-shaped band the round-2
    /// comment above expected and did not find — the round-2 numbers (1.5-133 us, growing
    /// 9-19x from 100k to 1M) were the teardown artifact, not the algorithm; with it
    /// removed, the measured growth from 10k to 1M is under 2x, consistent with
    /// `height + 1` growing by one or two per decade. The bound (**10 us at every size**) is
    /// set from the worst of the observed runs (1.66 us at 1M), not the best, and sits
    /// roughly 6x above it — unlike the previous 1000 us bound, this has real power against
    /// a 2-5x constant-factor regression while still catching a fall back to true O(n) (a
    /// per-marker shift at 1M, even at an optimistic ~50 ns/marker, is 50 ms, 5000x over
    /// this bound). **This suite runs n up to 1,000,000 only** — a 3,000,000 size was tried
    /// in this fix round and dropped: adding it to `sizes` made this test build and tear
    /// down an extra 3M-marker tree in the same process before `memoryForOneMillionMarkers`
    /// runs, and that extra allocator traffic was enough to flip that test's net-delta
    /// measurement below its own floor once in two whole-file runs (13.44 bytes/marker
    /// against a 16-byte floor) where it is otherwise stable at the range
    /// `memoryForOneMillionMarkers` records for itself below, across many runs — reproduced by re-running with and without the 3M size several times each. The
    /// bound above is derived only from the sizes this suite actually runs.
    @Test("headline: single-byte insertion before every marker, n = 10^4, 10^5, 10^6")
    func insertBeforeAllMarkers() {
        let sizes = [10_000, 100_000, 1_000_000]
        var means: [Int: Double] = [:]
        for n in sizes {
            let base = Self.buildMarkers(n)
            let samples = 1000
            // Precomputed outside the timed region: varying offsets pay the cache cost a
            // real edit pays (unlike a fixed offset-0 edit, always on the leftmost spine),
            // and precomputing keeps the RNG itself out of what is timed.
            var rng = SplitMix64(seed: 0x517A_C0DE)
            let offsets = (0..<samples).map { _ in Int(rng.next() % UInt64(n * 8 + 1)) }
            var touchAccumulator = 0
            // `withExtendedLifetime(base)` keeps `base`'s release outside the timed region.
            // Without it, `base`'s last use is inside this loop (`var tree = base`), so ARC
            // emits its release here -- an O(n) MarkerTree teardown (measured directly: 1.7-
            // 2.8 ms at 1M) that would otherwise be divided by `samples` and dominate the
            // mean. Do not replace this with `_ = base.count` after the loop: a discarded
            // pure read can be optimised away, which silently puts the release straight back
            // inside the timed region and reintroduces the O(n) cost with no visible sign in
            // the source.
            withExtendedLifetime(base) {
                let start = DispatchTime.now().uptimeNanoseconds
                for i in 0..<samples {
                    var tree = base
                    let offset = offsets[i]
                    tree = tree.applyEdit(byteRange: offset..<offset, insertedLength: 1)
                    // Accumulate a value read from the result so the edit cannot be proven
                    // dead and eliminated by the optimiser; vary the rank touched per sample
                    // so the compiler cannot hoist this out of the loop.
                    touchAccumulator &+= tree.position(ofRank: i % tree.count)
                }
                let elapsedNanos = DispatchTime.now().uptimeNanoseconds - start
                let mean = Double(elapsedNanos) / Double(samples) / 1_000_000_000
                means[n] = mean
                print(
                    "insertBeforeAllMarkers: n=\(n) mean \(mean * 1_000_000) us over "
                        + "\(samples) samples (touchAccumulator=\(touchAccumulator))"
                )
            }
        }
        for n in sizes {
            let mean = means[n] ?? .infinity
            let message =
                "single-byte insertion before all \(n) markers took \(mean * 1_000_000) us, "
                + "over the 10 us bound (release build) -- set from the worst of this test's "
                + "own fix-round-4 runs (1.58-1.66 us at 1M), roughly 6x headroom; see this "
                + "test's doc comment for the bound's basis and the fix-round-3 "
                + "teardown-artifact story"
            #expect(mean < 0.000_010, "\(message)")
        }
    }

    /// **The O(k) collapse, measured rather than hidden.** Deleting a range containing
    /// 100,000 markers is inherent O(k) work under the no-retained-history constraint
    /// (`dev/specs/m1.3.md` section 2.B) -- no representation makes k distinct positions
    /// become equal in less than O(k) without keeping history around, and GNU pays this
    /// linearly too. This prints the count and the time so a reader does not mistake this
    /// cost for a regression; it is not asserted against a tight bound the way the O(log n)
    /// headline test above is, only a loose sanity ceiling.
    ///
    /// **Checked against the same single-tick-resolution failure `insertBeforeAllMarkers`
    /// had, and this one does not have it.** A single `Date()`-timed sample here reported
    /// 1.95-3.6 ms in prior runs, and this file's own final runs measure 2.03-2.07 ms
    /// for 100,000 markers — thousands of `Date()`'s 0.9537 us ticks, not zero or one,
    /// so the measurement is real and this test was left on single-sample `Date()`
    /// timing rather than converted to the batched-nanosecond shape above. That works
    /// out at 20.3-20.7 ns per marker, which is a derived rate rather than a timed
    /// quantity: one marker's share is a fraction of a tick, and nothing here times one.
    @Test("O(k) collapse: deleting a range containing 100,000 markers")
    func collapseHundredThousandMarkers() {
        let n = 100_000
        // Pack all n markers into byte range [0, n) so a single delete of that whole range
        // collapses every one of them -- k == n here, the case section 2.B calls out.
        var sorted: [(byteOffset: Int, bias: MarkerBias, id: MarkerID)] = []
        sorted.reserveCapacity(n)
        for i in 0..<n {
            let bias: MarkerBias = i % 2 == 0 ? .left : .right
            sorted.append((byteOffset: i, bias: bias, id: MarkerID(i)))
        }
        let tree = MarkerTree(sortedMarkers: sorted)
        let start = Date()
        let after = tree.applyEdit(byteRange: 0..<n, insertedLength: 0)
        let elapsed = Date().timeIntervalSince(start)
        print(
            "collapseHundredThousandMarkers: collapsed \(n) markers in \(elapsed * 1000) ms "
                + "(\(elapsed * 1_000_000_000 / Double(n)) ns/marker) -- inherent O(k), matches GNU"
        )
        #expect(after.count == n)
        #expect(after.position(ofRank: 0) == 0)
        #expect(after.position(ofRank: n - 1) == 0)
        // Loose sanity ceiling only, not a tight regression bar -- this cost is expected and
        // documented, not something to shave. 500 ms for 100k markers is generous headroom
        // over any plausible per-marker constant for array partition/rebuild work.
        #expect(
            elapsed < 0.5,
            "collapsing \(n) markers took \(elapsed)s, over the 500 ms loose sanity ceiling")
    }

    /// **Memory for 1M markers, printed and sanity-checked against a floor** (R3, per
    /// `dev/specs/m1.3.md` section 4). `MarkerRecord` is 16 bytes (`Int` gap + `UInt64` id);
    /// a naive "16 bytes * 1M" arithmetic claim as the printed number ignores `SumTree`'s own
    /// per-node overhead and array capacity slop, exactly as `Chunk.swift`'s own stride
    /// comments warn against trusting a size claim nobody measured
    /// (`MemoryLayout<Node<Chunk>>.stride` was wrongly recorded as 24 for the same reason,
    /// `CLAUDE.md`'s M1.2 lesson) -- but `MemoryLayout<MarkerRecord>.stride * n` *is* a valid
    /// floor: a tree cannot use less memory than the raw bytes of the items it holds, so
    /// `#expect(delta >= floor)` below is not the arithmetic claim this comment is warning
    /// against, only a lower bound on it. Technique: Darwin's `malloc_zone_statistics` on the
    /// default zone, `size_in_use` before and after building the tree -- the same net-delta
    /// technique `conversionAndCursorTests.swift`'s `cursorTraversalAllocatesNothing` uses,
    /// with the same whole-process noise caveat (not `.serialized` here since this file has
    /// only one suite and does not run concurrently with `TextTests`' non-perf suites under
    /// the perf gate).
    ///
    /// **Re-instrumented (M1.3 fix round 2).** The previous version (one warm-up build,
    /// discarded, then a single before/after sample) printed 3.24 bytes/marker for 1M
    /// markers when run after this file's other tests in the same process -- below
    /// `MarkerRecord`'s own 16-byte stride, so it could not have been measuring the tree's
    /// allocation; the same code printed 22.05 bytes/marker when run in isolation. The
    /// discrepancy was allocator state left behind by the earlier tests in this suite (which
    /// themselves build and discard multi-megabyte marker trees), not anything about this
    /// tree. Two changes fixed it, verified by re-running this file's full filter four times
    /// (three whole-file runs, one isolated) and getting 22.05 bytes/marker (delta
    /// 22,050,960-22,051,232 bytes) every time, including the whole-file run where this test
    /// runs immediately after `insertBeforeAllMarkers` and `collapseHundredThousandMarkers`:
    /// three warm-up build-and-discard cycles instead of one, and a
    /// `malloc_zone_pressure_relief` call on the default zone between the last warm-up and
    /// the `before` sample, so freed pages from *this test's own* warm-up builds (and,
    /// incidentally, from whatever ran earlier in the process) are returned before the
    /// baseline is taken rather than sitting in the allocator's free list where a later
    /// large allocation could satisfy itself from them without moving `size_in_use` by the
    /// full amount.
    ///
    /// **This test's own fix-round-4 whole-file runs (this machine, release, two runs):
    /// 22.050960-22.064304 bytes/marker.** The round-2 fix above is holding: this is the
    /// same isolation technique, re-measured, and it is still narrow (against the 16-byte
    /// floor) across runs. It is *not* robust to a size this file does not currently build
    /// before this test, though: adding a 3,000,000-marker build to `insertBeforeAllMarkers`
    /// (tried and reverted in this fix round -- see that test's doc comment) put enough
    /// extra allocator traffic ahead of this test's own warm-up that one of two whole-file
    /// runs measured 13.44 bytes/marker, below the floor. This test's three-warm-up-plus-
    /// pressure-relief technique isolates it from the *rest of this file as it stands*, not
    /// from an arbitrary amount of allocator traffic upstream of it in the same process.
    @Test("memory: 1,000,000 markers")
    func memoryForOneMillionMarkers() {
        let n = 1_000_000
        func sizeInUse() -> Int {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(malloc_default_zone(), &stats)
            return Int(stats.size_in_use)
        }
        // Warm-up: build and discard three times (not one -- see the doc comment above for
        // why one was not enough to isolate this test from allocator state left behind by
        // earlier tests in this same process), then return freed pages to the allocator
        // before sampling the baseline.
        for _ in 0..<3 {
            _ = Self.buildMarkers(n)
        }
        malloc_zone_pressure_relief(malloc_default_zone(), 0)
        let before = sizeInUse()
        let tree = Self.buildMarkers(n)
        let after = sizeInUse()
        let delta = after - before
        // Floor: a tree cannot cost less than the raw bytes of the records it holds. Failing
        // loudly here is what this fix round adds -- the previous version printed a number
        // under this floor (3.24 bytes/marker) instead of catching it, which is exactly the
        // "impossible number silently printed into a milestone's evidence" failure mode
        // `CLAUDE.md`'s M1.2 lesson warns about for a different stride miscalculation.
        let floor = MemoryLayout<MarkerRecord>.stride * n
        let floorMessage =
            "memoryForOneMillionMarkers: \(delta) bytes net is below the \(floor)-byte floor "
            + "(MemoryLayout<MarkerRecord>.stride * \(n)) -- this measurement technique "
            + "is not capturing the tree's real allocation; see this test's doc comment"
        #expect(delta >= floor, "\(floorMessage)")
        print(
            "memoryForOneMillionMarkers: \(n) markers cost \(delta) bytes net "
                + "(\(Double(delta) / Double(n)) bytes/marker), size_in_use \(before) -> \(after)"
        )
        #expect(tree.count == n)
    }

    // MARK: - The full-scale differential property test

    /// The reference model, duplicated from `markerTreeTests.swift`'s `ModelMarker`/
    /// `applyModelEdit` rather than shared — the same reason `ropePerfTests.swift`'s
    /// `scalarBoundaries`/`boundedRange` are duplicated from `ropeTests.swift`: a perf suite
    /// should not depend on the correctness suite's fixtures changing underneath it.
    private struct ModelMarker {
        var offset: Int
        var bias: MarkerBias
        let id: MarkerID
    }

    private static func applyModelEdit(
        _ markers: inout [ModelMarker], lo: Int, hi: Int, insertedLength: Int,
        insertBeforeMarkers: Bool
    ) {
        if lo < hi {
            let delta = -(hi - lo)
            for i in markers.indices {
                let key = 2 * markers[i].offset + markers[i].bias.rank
                if key < 2 * lo + 2 {
                    // Unchanged.
                } else if key <= 2 * hi + 1 {
                    markers[i].offset = lo
                } else {
                    markers[i].offset += delta
                }
            }
        }
        if insertedLength > 0 {
            let boundaryKey = insertBeforeMarkers ? 2 * lo : 2 * lo + 1
            for i in markers.indices {
                let key = 2 * markers[i].offset + markers[i].bias.rank
                if key >= boundaryKey {
                    markers[i].offset += insertedLength
                }
            }
        }
    }

    /// **The `dev/specs/m1.3.md` section 4 differential property test at its specified
    /// scale** ("at least 1,000,000 random edits ... mirroring M1's 'property tests against a
    /// naive string model' criterion") -- `markerTreeTests.swift`'s `manyEditDifferential`
    /// carries the same test at 20,000 operations for the plain suite; see that test's doc
    /// comment for why a million-operation run does not fit there (a debug build of this many
    /// persistent-tree edits was killed after 12+ minutes of CPU time, still unfinished — and
    /// for why that was the generator's insertion/deletion sizes being unbalanced, degenerating
    /// into a near-worst-case O(k) collapse on almost every edit, rather than generic debug
    /// slowness). Both axes (live marker count, buffer length) are bounded, exactly as
    /// `manyEditDifferential`'s are and for the same reason `ropePerfTests.swift`'s
    /// `runModelProperty` bounds its own random walk: an unbounded walk drifts to a size that
    /// makes per-operation cost grow across the run instead of staying flat, which is the
    /// wrong shape for a fixed operation count. `checkInvariants()`/model-agreement is
    /// checked on a cadence, not every operation, mirroring the same cadence tradeoff
    /// `runModelProperty`'s doc comment (`ropePerfTests.swift:68-76`) already makes for the
    /// rope, for the same reason: checking a large tree on every one of a million operations
    /// is too expensive even in a release build.
    @Test("differential: 1,000,000 random edits against a naive per-marker model")
    func millionEditDifferentialPerf() {
        let seed: UInt64 = 0xFEED_C0DE_1234
        var rng = SplitMix64(seed: seed)
        var model: [ModelMarker] = []
        var tree = MarkerTree()
        var nextID: MarkerID = 0
        var bufferLength = 0
        let operationCount = 1_000_000
        let checkEvery = 5_000
        let maxMarkers = 20_000
        let maxBufferLength = 65_536
        // Insertion length is drawn from the same range as deletion width (both up to 64
        // bytes) -- see `manyEditDifferential`'s doc comment in `markerTreeTests.swift` for
        // why the earlier `0..<8` insertion range made this walk collapse to an equilibrium
        // of a handful of bytes almost immediately (this file's `final buffer length` print
        // used to read 8 at 1,000,000 ops).
        let insertLengthCap = 64
        var bufferLengthSamples: [Int] = []
        bufferLengthSamples.reserveCapacity(operationCount)

        func modelByID() -> [MarkerID: (Int, MarkerBias)] {
            Dictionary(uniqueKeysWithValues: model.map { ($0.id, ($0.offset, $0.bias)) })
        }
        func treeByID() -> [MarkerID: (Int, MarkerBias)] {
            var result: [MarkerID: (Int, MarkerBias)] = [:]
            result.reserveCapacity(tree.count)
            for r in 0..<tree.count {
                result[tree.id(ofRank: r)] = (tree.position(ofRank: r), tree.bias(ofRank: r))
            }
            return result
        }
        func compare(_ opIndex: Int) {
            let modelMap = modelByID()
            let treeMap = treeByID()
            #expect(
                modelMap.count == treeMap.count,
                "seed \(seed), op \(opIndex): marker count mismatch, model \(modelMap.count) tree \(treeMap.count)"
            )
            for (id, (offset, bias)) in modelMap {
                guard let (tOffset, tBias) = treeMap[id] else {
                    Issue.record("seed \(seed), op \(opIndex): tree missing marker id \(id)")
                    continue
                }
                #expect(
                    tOffset == offset && tBias == bias,
                    "seed \(seed), op \(opIndex): marker id \(id) model=(\(offset),\(bias)) tree=(\(tOffset),\(tBias))"
                )
            }
        }

        let start = Date()
        for opIndex in 0..<operationCount {
            let kind = rng.next() % 5
            switch kind {
            case 0, 1:
                guard model.count < maxMarkers else { break }
                let offset = Int(rng.next() % UInt64(bufferLength + 1))
                let bias: MarkerBias = rng.next() % 2 == 0 ? .left : .right
                let id = nextID
                nextID += 1
                model.append(ModelMarker(offset: offset, bias: bias, id: id))
                tree = tree.inserting(byteOffset: offset, bias: bias, id: id)
            case 2:
                if !model.isEmpty {
                    let idx = Int(rng.next() % UInt64(model.count))
                    let removed = model.remove(at: idx)
                    tree = tree.removing(id: removed.id, atByteOffset: removed.offset)
                }
            default:
                let lo = Int(rng.next() % UInt64(bufferLength + 1))
                let maxWidth = min(64, bufferLength - lo)
                let width = maxWidth > 0 ? Int(rng.next() % UInt64(maxWidth + 1)) : 0
                let hi = lo + width
                var insertedLength = Int(rng.next() % UInt64(insertLengthCap + 1))
                if bufferLength - width + insertedLength > maxBufferLength {
                    insertedLength = 0
                }
                let insertBeforeMarkers = rng.next() % 5 == 0
                Self.applyModelEdit(
                    &model, lo: lo, hi: hi, insertedLength: insertedLength,
                    insertBeforeMarkers: insertBeforeMarkers)
                tree = tree.applyEdit(
                    byteRange: lo..<hi, insertedLength: insertedLength,
                    insertBeforeMarkers: insertBeforeMarkers)
                bufferLength += insertedLength - width
            }

            bufferLengthSamples.append(bufferLength)
            if opIndex % checkEvery == 0 {
                do {
                    try tree.checkInvariants()
                } catch {
                    Issue.record("seed \(seed), op \(opIndex): invariant violation \(error)")
                }
                compare(opIndex)
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        bufferLengthSamples.sort()
        let medianBufferLength = bufferLengthSamples[bufferLengthSamples.count / 2]
        print(
            "millionEditDifferentialPerf: \(operationCount) ops in \(elapsed)s (seed \(seed), "
                + "final marker count \(model.count), final buffer length \(bufferLength), "
                + "median buffer length \(medianBufferLength))")
        do {
            try tree.checkInvariants()
        } catch {
            Issue.record("seed \(seed): final invariant violation \(error)")
        }
        compare(operationCount)

        // See `manyEditDifferential`'s matching assertions in `markerTreeTests.swift` for why
        // these exist (including the fix-round-4 self-check numbers behind the specific
        // thresholds below): checking the workload's health rather than only fixing it once,
        // so a regression back to the degenerate collapse-heavy shape fails the test instead
        // of silently costing whatever time it costs.
        #expect(
            medianBufferLength > maxBufferLength / 40
                && medianBufferLength < maxBufferLength * 9 / 10,
            """
            median buffer length \(medianBufferLength) across the run fell outside the \
            intended band (\(maxBufferLength / 40), \(maxBufferLength * 9 / 10)) -- the low \
            end is the check that the insertion/deletion balance has not drifted back \
            towards collapsing the buffer to a handful of bytes; the high end is the check \
            that insertions have not come to dominate deletions so heavily that the walk \
            pegs near the ceiling instead of oscillating
            """
        )
        let p10BufferLength = bufferLengthSamples[bufferLengthSamples.count / 10]
        let p90BufferLength = bufferLengthSamples[bufferLengthSamples.count * 9 / 10]
        #expect(
            p90BufferLength - p10BufferLength > maxBufferLength / 10,
            """
            buffer length spread (10th percentile \(p10BufferLength), 90th percentile \
            \(p90BufferLength)) across the run is only \(p90BufferLength - p10BufferLength) \
            bytes, at or below 1/10 of the \(maxBufferLength)-byte cap -- this is the check \
            that the walk actually ranges across a wide span of buffer lengths rather than \
            clustering near one value, which the median check above cannot tell apart from \
            a healthy walk on its own
            """
        )
        let liveOffsets = model.map(\.offset)
        let markerSpan = (liveOffsets.max() ?? 0) - (liveOffsets.min() ?? 0)
        #expect(
            markerSpan > 200,
            """
            final live-marker span \(markerSpan) bytes is small enough that markers are \
            effectively all packed together -- this is the check that the differential \
            workload is not silently degenerate
            """
        )
    }
}
