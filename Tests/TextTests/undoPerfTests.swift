import Foundation
import Testing

@testable import Text

/// M1.5 stage 1's perf suite (`dev/specs/m1.5.md` section 4.3, tests 20-24): the cost of
/// recording a transaction, undo/redo of a single-character transaction, memory per retained
/// transaction, the post-commit cost of maintaining `UndoHistory.totalByteCost`, and the cost
/// of discarding a large history. Gated behind the `.performance` tag exactly like this
/// project's other perf files (`perfTag.swift`): `swift test` skips this file; so does
/// `PELLICLE_PERF=1 swift test` (debug); only `PELLICLE_PERF=1 swift test -c release --filter
/// UndoPerfTests` runs it. Test 22 additionally requires `PELLICLE_ALLOC_PROBE=1` and must be
/// run alone — see its own doc comment.
///
/// **A perf number from a debug build is not evidence** — `swift test` always builds
/// `-Onone` (see `perfTag.swift`'s `isDebugBuild`). Every number this file prints or asserts
/// on should be read as "release build, this machine," and every bound here is preliminary:
/// the main conversation re-measures authoritatively on a quiet machine (`CLAUDE.md`,
/// "Performance numbers").
///
/// **Nanosecond clock, once around the whole sample loop, never per operation** — `Date()`'s
/// smallest non-zero tick on this machine is 0.9537 us, so timing a sub-microsecond operation
/// with it reads the tick-straddle fraction, not the operation's cost (`CLAUDE.md`, "How to
/// measure"). Every timed test below reads `DispatchTime.now().uptimeNanoseconds` exactly
/// once before a batch of samples and once after, the same shape `ropePerfTests.swift`'s
/// `generalPathInsertCost` and `intervalTreePerfTests.swift` use.
///
/// **Tests 22 and 24 are the inverse of every other perf test here: they measure a release,
/// not a computation.** Every other test in this file (and every perf test elsewhere in the
/// tree) holds its fixture with `withExtendedLifetime` so an O(n) teardown cannot land inside
/// the timed region by surprise. Tests 22 and 24 need the opposite: the release itself is
/// the thing being measured, so the subject must be *inside* the timed/counted region.
/// **Two defences are mandatory**, per the architect pass's own experience building the
/// measurement 1.1 cites (`dev/specs/m1.5.md` 1.1, 4.3): its first probe, without these,
/// read a plausible but wrong **zero bytes and five microseconds**, because the optimiser
/// proved the built-and-immediately-dropped value had no observer and elided the work
/// producing it. `globalUndoPerfSubject` below holds the subject in file scope so the
/// optimiser cannot sink or delete the release, and `sinkUndoPerfValue(_:)` is an
/// `@inline(never)` function that reads something derived from the subject after the timed
/// region, so the whole sequence has an observable effect the optimiser cannot prove away.
/// There is no template for this shape elsewhere in the tree; `ropePerfTests.swift:315`
/// (`releaseWithoutDeepRecursion`) is a crash smoke test that times nothing.
/// **`.serialized`**: unlike most of this tree's perf suites, several tests here (20, 21,
/// 23) time short (microsecond-scale) operations by wall clock; Swift Testing parallelises
/// tests within a suite by default, and running this suite's five tests concurrently was
/// measured to inflate and destabilise every timing here (`recordTransactionCost` alone: 55-
/// 60 us run in isolation, 80-118 us run concurrently with this suite's other tests, same
/// code, same machine) — the same class of contamination `conversionAndCursorTests.swift`'s
/// `.serialized` trait exists to prevent, just from this suite's own tests rather than
/// unrelated ones.
@Suite(
    .tags(.performance), .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["PELLICLE_PERF"] != nil && !isDebugBuild))
struct UndoPerfTests {

    // MARK: - Test 20

    /// **Cost of recording a transaction**, against the same edit with `isRecordingUndo ==
    /// false` as the baseline arm in the same process (`dev/specs/m1.5.md` 4.3 test 20). The
    /// two arms alternate in blocks of `samplesPerBlock`, rather than each running once
    /// start-to-finish, so a systematic drift over the test's lifetime (allocator warm-up,
    /// thermal throttling) lands on both arms rather than favouring whichever ran first;
    /// each block still reads the clock once before and once after its own loop, never per
    /// operation, matching every other test in this file.
    ///
    /// The edit itself is a single-byte overwrite at a fixed offset into a pre-built 1 MB
    /// buffer, alternating between two source bytes so the fast leaf-local rope path (`b`)
    /// does not see a no-op replacement — `PLAN.md`'s complexity table gives that path's own
    /// cost as 2.57-3.90 us at 1 MB, which is what the baseline arm here is expected to
    /// roughly track; the recording arm's excess over it is `TextBuffer.replaceSubrange`'s
    /// own overhead (`dev/specs/m1.5.md` 1.4's before/after entry-set queries plus
    /// `commitTransaction()`'s node append).
    @Test("cost of recording a transaction: isRecordingUndo true vs. false, alternating")
    func recordTransactionCost() {
        let buffer = TextBuffer()
        buffer.isRecordingUndo = false
        buffer.replaceSubrange(0..<0, with: String(repeating: "a", count: 1_000_000))

        let blocks = 8
        let samplesPerBlock = 250
        let bytes = ["a", "b"]
        var recordingNanos: UInt64 = 0
        var baselineNanos: UInt64 = 0

        for _ in 0..<blocks {
            buffer.isRecordingUndo = true
            let startRecording = DispatchTime.now().uptimeNanoseconds
            for i in 0..<samplesPerBlock {
                buffer.replaceSubrange(0..<1, with: bytes[i % 2])
                buffer.commitTransaction()
            }
            recordingNanos += DispatchTime.now().uptimeNanoseconds - startRecording

            buffer.isRecordingUndo = false
            let startBaseline = DispatchTime.now().uptimeNanoseconds
            for i in 0..<samplesPerBlock {
                buffer.replaceSubrange(0..<1, with: bytes[i % 2])
            }
            baselineNanos += DispatchTime.now().uptimeNanoseconds - startBaseline
        }
        buffer.isRecordingUndo = true

        let totalSamples = blocks * samplesPerBlock
        let recordingMean = Double(recordingNanos) / Double(totalSamples)
        let baselineMean = Double(baselineNanos) / Double(totalSamples)
        print(
            "recordTransactionCost: recording \(recordingMean / 1000.0) us/op, baseline "
                + "\(baselineMean / 1000.0) us/op over \(totalSamples) samples/arm")

        // Absolute bound, with headroom. **The measured figure lives in `PLAN.md` 4.5's
        // "Record one transaction" row and nowhere else** — this comment names the bound and
        // why it sits where it does, not the measurement, because a second copy of a number
        // is the thing this project's reviews find disagreeing with itself most often. An
        // earlier version of this comment did exactly that: it quoted 56.6-58.8 us/op and
        // said the arm "slices `deleted`/`inserted` out of the rope twice", both of which the
        // row had already superseded — the inserted-text slice is gone (`TextBuffer.swift`
        // records the rope the funnel was handed) and the figure is a third lower. What this
        // arm does beyond the baseline: two marker/interval entry-set queries before and
        // after, one `Rope.slice` for the deleted text, and one appended `UndoHistory` node.
        // 150 us is roughly four times the recorded cost and also clears the ~118 us/op this
        // test read when it shared a process with the suite's other tests, before
        // `.serialized`.
        let absoluteBound = 150_000.0
        let absoluteBoundMessage =
            "recording a transaction cost \(recordingMean / 1000.0) us/op, over the "
            + "\(absoluteBound / 1000.0) us bound (release build)"
        #expect(recordingMean < absoluteBound, "\(absoluteBoundMessage)")

        // Ratio bound, not read as "recording is free" but as "recording does not fall off
        // the fast path onto something asymptotically worse" — a uniformly slow
        // implementation would pass an absolute-only check just as easily, so the ratio is
        // kept alongside it per `CLAUDE.md`'s "assert an absolute bound as well as any
        // ratio." The measured ratio follows from `PLAN.md` 4.5's two figures for this row's
        // arms and is not restated here; 60x leaves headroom over it.
        let ratio = recordingMean / max(baselineMean, 1)
        let ratioMessage =
            "recording cost \(recordingMean / 1000.0) us/op is \(ratio)x the "
            + "\(baselineMean / 1000.0) us/op baseline, over the 60x bound"
        #expect(ratio < 60, "\(ratioMessage)")
    }

    // MARK: - Test 21

    /// **Cost of one undo and one redo** of a single-character transaction at 1 MB
    /// (`dev/specs/m1.5.md` 4.3 test 21), against 4.5's existing per-edit rows (`PLAN.md`:
    /// single-scalar fast-path insert 2.57-3.90 us at 1 MB). `samples` transactions are
    /// committed first, untimed, so the timed loops below measure only `undo()`/`redo()`
    /// themselves — each one-hop `UndoHistory` traversal plus one inverse/forward text
    /// replacement, which is O(1) in this file's transaction depth (`moveToParent`/
    /// `moveToLastVisitedChild` are single-hop), so walking further into an already-built
    /// chain is not expected to change the per-step cost.
    @Test("cost of one undo and one redo: single-character transaction at 1 MB")
    func undoRedoCost() {
        let buffer = TextBuffer()
        buffer.isRecordingUndo = false
        buffer.replaceSubrange(0..<0, with: String(repeating: "a", count: 1_000_000))
        buffer.isRecordingUndo = true

        let samples = 2000
        let bytes = ["a", "b"]
        for i in 0..<samples {
            buffer.replaceSubrange(0..<1, with: bytes[i % 2])
            buffer.commitTransaction()
        }

        // `#expect` on each result is deliberately outside the timed region below (it would
        // add its own per-call overhead to the measured cost); `undoFailures`/`redoFailures`
        // carry the check across instead, checked once after each timed loop.
        var undoFailures = 0
        let startUndo = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<samples {
            if buffer.undo() == nil { undoFailures += 1 }
        }
        let undoNanos = DispatchTime.now().uptimeNanoseconds - startUndo
        #expect(undoFailures == 0, "\(undoFailures) of \(samples) undo() calls returned nil")

        var redoFailures = 0
        let startRedo = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<samples {
            if buffer.redo() == nil { redoFailures += 1 }
        }
        let redoNanos = DispatchTime.now().uptimeNanoseconds - startRedo
        #expect(redoFailures == 0, "\(redoFailures) of \(samples) redo() calls returned nil")

        let undoMean = Double(undoNanos) / Double(samples)
        let redoMean = Double(redoNanos) / Double(samples)
        print(
            "undoRedoCost: undo \(undoMean / 1000.0) us/op, redo \(redoMean / 1000.0) us/op "
                + "over \(samples) samples")

        // Preliminary absolute bound, with headroom over the ~3-4 us fast-path insert cost
        // this wraps: undo/redo additionally query and re-insert the (empty here)
        // marker/interval entry sets and traverse one `UndoHistory` node. The measured range
        // is `PLAN.md` 4.5's "Undo or redo one transaction" row, not restated here; its upper
        // end is scheduling noise rather than size, and 60 us clears it several times over.
        let bound = 60_000.0
        let undoMessage =
            "undo of a single-character 1 MB transaction cost \(undoMean / 1000.0) us/op, "
            + "over the \(bound / 1000.0) us bound (release build)"
        #expect(undoMean < bound, "\(undoMessage)")
        let redoMessage =
            "redo of a single-character 1 MB transaction cost \(redoMean / 1000.0) us/op, "
            + "over the \(bound / 1000.0) us bound (release build)"
        #expect(redoMean < bound, "\(redoMessage)")
    }

    // MARK: - Test 22

    /// **Memory per retained transaction** (`dev/specs/m1.5.md` 4.3 test 22), by the
    /// allocation-counting route the architect pass used for the same measurement in 1.1: a
    /// file-scope global (`globalUndoPerfSubject`) holding the built `TextBuffer` so the
    /// optimiser cannot prove the local build sequence has no observer, and
    /// `sinkUndoPerfValue(_:)` — `@inline(never)` — reading something derived from it after
    /// the measured region. See this file's header for why both are mandatory rather than
    /// belt-and-braces.
    ///
    /// Technique: Darwin's `malloc_zone_statistics` `size_in_use` before/after building `n`
    /// committed single-byte transactions, the same net-delta approach
    /// `markerTreePerfTests.swift`'s `memoryForOneMillionMarkers` uses, including its
    /// three-warm-up-plus-`malloc_zone_pressure_relief` isolation (that test's own doc
    /// comment records why one warm-up was not enough to isolate it from allocator state
    /// left behind by earlier tests in the same process).
    ///
    /// **Environment-gated and run alone**, the way `conversionAndCursorTests.swift`'s
    /// `cursorTraversalAllocatesNothing` is: `malloc_zone_statistics` counts the whole
    /// process, so under `swift test --parallel` every other suite's concurrent allocation
    /// traffic lands in this window too (`CLAUDE.md`'s M1.4 lesson, commit `2820c79`, which
    /// this spec's own review round found this test's first draft did not carry over).
    /// `dev/gate.sh` runs this test alone, in its own `swift test -c release` invocation with
    /// both `PELLICLE_PERF=1` (this suite's own gate) and `PELLICLE_ALLOC_PROBE=1` (this
    /// test's own gate) set.
    @Test(
        "memory per retained transaction",
        .enabled(if: ProcessInfo.processInfo.environment["PELLICLE_ALLOC_PROBE"] != nil))
    func memoryPerRetainedTransaction() {
        let n = 2_000

        func sizeInUse() -> Int {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(malloc_default_zone(), &stats)
            return Int(stats.size_in_use)
        }

        func buildAndCommit() -> TextBuffer {
            let buffer = TextBuffer()
            buffer.isRecordingUndo = true
            for _ in 0..<n {
                buffer.replaceSubrange(0..<0, with: "x")
                buffer.commitTransaction()
            }
            return buffer
        }

        // Three warm-up build-and-discard cycles, then return freed pages to the allocator,
        // mirroring `memoryForOneMillionMarkers`'s isolation technique exactly.
        for _ in 0..<3 {
            let warm = buildAndCommit()
            sinkUndoPerfValue(warm.history.nodeCount)
        }
        malloc_zone_pressure_relief(malloc_default_zone(), 0)

        let before = sizeInUse()
        globalUndoPerfSubject = buildAndCommit()
        let after = sizeInUse()
        sinkUndoPerfValue(globalUndoPerfSubject!.history.nodeCount)

        let delta = after - before
        let perTransaction = Double(delta) / Double(n)
        print(
            "memoryPerRetainedTransaction: n=\(n) delta=\(delta) bytes, "
                + "\(perTransaction) B/transaction")

        // Floor: a history cannot cost less than the fixed struct overhead of the nodes it
        // holds, the same reasoning `memoryForOneMillionMarkers`'s
        // `MemoryLayout<MarkerRecord>.stride * n` floor uses.
        let floor = n * UndoHistory.nodeFixedOverhead
        let floorMessage =
            "retaining \(n) transactions used \(delta) bytes, under the \(floor)-byte floor "
            + "of \(n) nodes' own fixed overhead -- the measurement is not isolated"
        #expect(delta >= floor, "\(floorMessage)")

        // 600 B, not the 1,000 B this test first carried. **The measured figure is `PLAN.md`
        // 4.5's "Memory per retained transaction" row and is not restated here** — a review
        // round found this comment carrying two ranges in adjacent paragraphs, one of them
        // from a draft that a later revision was meant to replace. 600 leaves headroom of
        // more than half the recorded measurement again while still being a bound a
        // regression would cross. **The measurement is about 2x `dev/specs/m1.5.md`
        // 1.9's ~190 B formula figure for the same shape**, and that gap is the point of this
        // test: a single-character transaction retains one or two small `Rope`s, whose fixed
        // per-node cost (72 B per `Node<Chunk>`, 64-80 B per `Chunk`, `PLAN.md` 4.16) dwarfs
        // the byte counts the formula adds up. 1.9 records the undercount as 20-40% for a
        // large multi-chunk deletion; for the smallest transactions it is 2x, in the same
        // direction, and stage 2's budget arithmetic has to start from this number.
        let ceiling = 600.0
        let ceilingMessage =
            "retaining a transaction cost \(perTransaction) B, over the \(ceiling) B "
            + "preliminary ceiling (release build)"
        #expect(perTransaction < ceiling, "\(ceilingMessage)")

        globalUndoPerfSubject = nil
    }

    // MARK: - Test 23

    /// **The post-commit cost of maintaining the running total** (`dev/specs/m1.5.md` 4.3
    /// test 23): committing into a history of thousands of nodes against committing into an
    /// empty one, both arms in the same process, asserting the two are within noise of each
    /// other. **Thousands, not a handful** — at a small node count an implementation that
    /// recomputes `totalByteCost` by sweeping the whole `nodes` array would be indistinguishable
    /// in cost from the running total this file's `UndoHistory` actually maintains, so the
    /// assertion would be vacuous at a small size; `largeBuffer` below is pre-filled with
    /// `prefill` (thousands) of committed transactions before either timed loop runs.
    @Test("post-commit cost of the running total: thousands of nodes vs. an empty history")
    func postCommitRunningTotalCost() {
        func makeBuffer() -> TextBuffer {
            let buffer = TextBuffer()
            buffer.isRecordingUndo = false
            buffer.replaceSubrange(0..<0, with: String(repeating: "a", count: 10_000))
            buffer.isRecordingUndo = true
            return buffer
        }

        let largeBuffer = makeBuffer()
        let prefill = 5_000
        let bytes = ["a", "b"]
        for i in 0..<prefill {
            largeBuffer.replaceSubrange(0..<1, with: bytes[i % 2])
            largeBuffer.commitTransaction()
        }
        #expect(
            largeBuffer.history.nodeCount > prefill,
            "expected thousands of pre-filled nodes, got \(largeBuffer.history.nodeCount)")

        let emptyBuffer = makeBuffer()

        let samples = 4_000
        let startLarge = DispatchTime.now().uptimeNanoseconds
        for i in 0..<samples {
            largeBuffer.replaceSubrange(0..<1, with: bytes[i % 2])
            largeBuffer.commitTransaction()
        }
        let largeNanos = DispatchTime.now().uptimeNanoseconds - startLarge

        let startEmpty = DispatchTime.now().uptimeNanoseconds
        for i in 0..<samples {
            emptyBuffer.replaceSubrange(0..<1, with: bytes[i % 2])
            emptyBuffer.commitTransaction()
        }
        let emptyNanos = DispatchTime.now().uptimeNanoseconds - startEmpty

        let largeMean = Double(largeNanos) / Double(samples)
        let emptyMean = Double(emptyNanos) / Double(samples)
        print(
            "postCommitRunningTotalCost: large-history \(largeMean / 1000.0) us/op "
                + "(\(largeBuffer.history.nodeCount) nodes), empty-history "
                + "\(emptyMean / 1000.0) us/op")

        // "Within noise" is expressed as an absolute bound on the difference, not a ratio:
        // both means are only a few microseconds, and dividing two independently noisy
        // small numbers is the trap `CLAUDE.md`'s `bulkBuildThroughput` comment describes.
        // The measured arms are `PLAN.md` 4.5's "Maintain the byte-cost running total" row
        // and are not restated here; a review round found the figures this comment used to
        // carry matching neither that row nor the raw runs behind it. 40 us leaves headroom
        // over the spread the row records.
        let absoluteDifferenceBound = 40_000.0
        let difference = abs(largeMean - emptyMean)
        let differenceMessage =
            "committing into a \(largeBuffer.history.nodeCount)-node history cost "
            + "\(largeMean / 1000.0) us/op against \(emptyMean / 1000.0) us/op into an "
            + "empty one -- a \(difference / 1000.0) us difference, over the "
            + "\(absoluteDifferenceBound / 1000.0) us bound. A sweep-based total would grow "
            + "with node count, which this bound exists to catch"
        #expect(difference < absoluteDifferenceBound, "\(differenceMessage)")

        // Both arms are also bounded absolutely, so a uniformly slow implementation (which
        // would pass the difference check above trivially) cannot pass silently.
        let perArmBound = 150_000.0
        let largeArmMessage =
            "committing into the large history cost \(largeMean / 1000.0) us/op, over the "
            + "\(perArmBound / 1000.0) us bound"
        #expect(largeMean < perArmBound, "\(largeArmMessage)")
        let emptyArmMessage =
            "committing into the empty history cost \(emptyMean / 1000.0) us/op, over the "
            + "\(perArmBound / 1000.0) us bound"
        #expect(emptyMean < perArmBound, "\(emptyArmMessage)")
    }

    // MARK: - Test 24

    /// **Discarding a large history** (`dev/specs/m1.5.md` 4.3 test 24): thousands of
    /// transactions, which needs no budget and so is stage 1's. Absolute bound under 1 ms,
    /// with the measured basis in `PLAN.md` 4.5's discard row; plus a
    /// no-super-linear ratio between 1,000 and 5,000 entries.
    ///
    /// **This measures a release** (`discardHistory()`'s `self = UndoHistory()` drops the
    /// whole `nodes` array, releasing every retained `ElementaryEdit`'s `deleted`/`inserted`
    /// Ropes) — see this file's header for why `globalUndoPerfSubject`/
    /// `sinkUndoPerfValue(_:)` are mandatory here. Each sample rebuilds the history from
    /// scratch (untimed) and times only the `discardHistory()` call itself, since discarding
    /// is not repeatable against the same history.
    @Test("discarding a large history: thousands of one-kilobyte transactions")
    func discardLargeHistoryCost() {
        let entryCounts = [1_000, 5_000]
        var mediansUs: [Int: Double] = [:]
        let oneKB = String(repeating: "k", count: 1024)
        // Fifteen samples and the **median**, not five and the mean: measured on this
        // machine, five-sample means of the same n=1,000 fixture came out 167, 232 and 692 us
        // on three consecutive runs — a 4x spread in the statistic itself, against a 1,000 us
        // bound, which is a false red waiting to happen. One sample is one whole-history
        // teardown, so a single scheduling or allocator excursion moves a five-sample mean a
        // long way; the median of fifteen does not move.
        let sampleCount = 15

        for n in entryCounts {
            var samplesUs: [Double] = []
            for _ in 0..<sampleCount {
                let buffer = TextBuffer()
                buffer.isRecordingUndo = true
                // **Each transaction deletes its kilobyte rather than only inserting one**,
                // and that is what makes this test measure a release at all. A review round
                // traced the first version, which only ever prepended: an insert of more
                // than 64 bytes takes `Rope.replaceSubrange`'s large-`other` branch, which
                // pushes the caller's rope in as a subtree, and since M1.5 records `inserted`
                // as the rope it was handed, every retained entry shared its nodes with the
                // live text that still held them — so `discardHistory()` dropped retain
                // counts and released almost nothing but the bookkeeping arrays. Deleted text
                // has no such sharing: the buffer no longer holds it, so the history's
                // `deleted` rope is its sole owner, which is the case `PLAN.md`'s row is
                // about and the one a real session accumulates.
                for _ in 0..<n {
                    buffer.replaceSubrange(0..<0, with: oneKB)
                    buffer.replaceSubrange(0..<1024, with: "")
                    buffer.commitTransaction()
                }
                #expect(buffer.history.nodeCount > n)
                // **The fixture's shape is asserted, because its cost is not.** Reverting
                // the delete above would leave both bounds below satisfied — the insert-only
                // version measured *less*, since it released almost nothing — so timing
                // cannot defend this fixture. What can: every recorded transaction really
                // carries a kilobyte of deleted text, which is the memory the row claims is
                // released here. A review round designed the reverting mutation and found
                // nothing red; this is the assertion that answers it.
                // The sum, not the node: binding the `Node` would keep a copy of its
                // `edits` array alive across the timed region below, and where the optimiser
                // puts that release is not stable (`CLAUDE.md`, and this file's header on the
                // two release-measuring tests). One node out of thousands could not flip the
                // assertion, but the discipline is cheap and a review round asked for it.
                let deletedBytes = buffer.history.node(buffer.history.current).edits
                    .reduce(0) { $0 + $1.deleted.utf8Count }
                #expect(deletedBytes == 1024)
                globalUndoPerfSubject = buffer

                let start = DispatchTime.now().uptimeNanoseconds
                globalUndoPerfSubject!.discardHistory()
                sinkUndoPerfValue(globalUndoPerfSubject!.history.nodeCount)
                samplesUs.append(
                    Double(DispatchTime.now().uptimeNanoseconds - start) / 1000.0)

                globalUndoPerfSubject = nil
            }
            samplesUs.sort()
            let medianUs = samplesUs[samplesUs.count / 2]
            mediansUs[n] = medianUs
            print(
                "discardLargeHistoryCost: n=\(n) median \(medianUs) us, min \(samplesUs.first!) us, "
                    + "max \(samplesUs.last!) us over \(sampleCount) samples")
        }

        let smallN = entryCounts.first!
        let largeN = entryCounts.last!
        let smallCost = mediansUs[smallN]!
        let largeCost = mediansUs[largeN]!

        // Absolute bound: `dev/specs/m1.5.md` 4.3 test 24 states this directly -- under 1 ms.
        // **The measured figures are `PLAN.md` 4.5's "Discard a buffer's undo history" row
        // and are not restated here**; every number this comment used to carry predated the
        // fixture change above and disagreed with that row, which a review round caught. 1 ms
        // leaves several times the recorded median in headroom.
        let absoluteBoundUs = 1_000.0
        let absoluteBoundMessage =
            "discarding a \(smallN)-entry history cost \(smallCost) us, over the "
            + "\(absoluteBoundUs) us bound (see PLAN.md 4.5's discard row for the basis)"
        #expect(smallCost < absoluteBoundUs, "\(absoluteBoundMessage)")

        // No-super-linear ratio: entryCounts.last is 5x entryCounts.first, so a linear (or
        // better) release should cost well under 5x more; generous headroom against noise at
        // these small absolute times. The measured ratio follows from `PLAN.md` 4.5's two
        // figures for this row and is not restated here.
        let countRatio = Double(largeN) / Double(smallN)
        let costRatio = largeCost / max(smallCost, 0.001)
        let ratioBoundMessage =
            "discarding \(largeN) entries cost \(costRatio)x discarding \(smallN) (entry "
            + "count ratio \(countRatio)x), over the \(countRatio * 3)x super-linear bound"
        #expect(costRatio < countRatio * 3, "\(ratioBoundMessage)")
    }
}

/// Holds the subject of a release measurement in file scope (tests 22 and 24) — see
/// `UndoPerfTests`'s header for why. `nil` outside the measured region of whichever test is
/// using it. `nonisolated(unsafe)`: `TextBuffer` is not `Sendable` (it is inherently mutable
/// state, per its own doc comment), and this global is never touched concurrently — each
/// perf test that uses it runs to completion, single-threaded, before the next does, and
/// this file's tests are never run under `swift test --parallel` (the `.performance` gate
/// keeps every perf suite out of the default and CI runs).
nonisolated(unsafe) private var globalUndoPerfSubject: TextBuffer?

/// `@inline(never)` sink read after a release measurement's timed region, so the optimiser
/// cannot prove the built-and-dropped subject had no observer and elide the work producing
/// it — see `UndoPerfTests`'s header. Deliberately does nothing but observe `value`.
@inline(never)
private func sinkUndoPerfValue(_ value: Int) {
    if value == Int.min {
        fatalError("sinkUndoPerfValue: unreachable, exists only to defeat dead-code elimination")
    }
}
