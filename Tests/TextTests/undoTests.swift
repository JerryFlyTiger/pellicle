import Testing

@testable import Text

/// Covers `TextBuffer`, `UndoHistory` and the `MarkerTree`/`IntervalTree` undo entry-set
/// machinery (M1.5 stage 1, `dev/specs/m1.5.md`). Section numbers below are that spec's.
///
/// **Test numbering follows the spec's section 4.2/4.1 list**, skipping the perf tests
/// (4.3, deliverable J — a later pass's job) and the differential's million-operation tier
/// (4.1, deliverable M — stage 2's, since it needs a budget to exist before it can bound the
/// history it builds).
@Suite("TextBuffer undo")
struct UndoTests {

    /// A fresh `TextBuffer` seeded with `text`, with the seeding itself **not** undo-recorded
    /// (`isRecordingUndo == false` during the seed) — matching a buffer freshly loaded from a
    /// file, where there is nothing to undo back past. Every test below builds on top of
    /// this, so the history each test starts from is a single genesis node holding this text.
    private func makeBuffer(_ text: String) -> TextBuffer {
        let buffer = TextBuffer()
        buffer.isRecordingUndo = false
        buffer.replaceSubrange(0..<0, with: text)
        buffer.isRecordingUndo = true
        return buffer
    }

    // MARK: - Test 1

    @Test("undo a pure insertion, redo it, undo again — with and without an explicit commit")
    func undoPureInsertion() {
        for explicitCommit in [false, true] {
            let buffer = makeBuffer("abcdef")
            buffer.replaceSubrange(3..<3, with: "XYZ")
            if explicitCommit { buffer.commitTransaction() }
            #expect(buffer.snapshot.text.toString() == "abcXYZdef", "commit=\(explicitCommit)")

            #expect(buffer.undo() != nil, "commit=\(explicitCommit)")
            #expect(buffer.snapshot.text.toString() == "abcdef", "commit=\(explicitCommit)")

            #expect(buffer.redo() != nil, "commit=\(explicitCommit)")
            #expect(buffer.snapshot.text.toString() == "abcXYZdef", "commit=\(explicitCommit)")

            #expect(buffer.undo() != nil, "commit=\(explicitCommit)")
            #expect(buffer.snapshot.text.toString() == "abcdef", "commit=\(explicitCommit)")
        }
    }

    // MARK: - Test 2

    @Test("undo a pure deletion restores markers strictly inside it")
    func undoDeletionRestoresInsideMarkers() {
        let buffer = makeBuffer("abcdefgh")
        let m1 = buffer.createMarker(atByteOffset: 3, bias: .left)
        let m2 = buffer.createMarker(atByteOffset: 4, bias: .right)

        buffer.replaceSubrange(2..<6, with: "")
        #expect(buffer.snapshot.text.toString() == "abgh")
        // Both collapsed to the deletion's start.
        #expect(buffer.snapshot.markers.rankPosition(of: m1) == 2)
        #expect(buffer.snapshot.markers.rankPosition(of: m2) == 2)

        buffer.undo()
        #expect(buffer.snapshot.text.toString() == "abcdefgh")
        #expect(buffer.snapshot.markers.rankPosition(of: m1) == 3)
        #expect(buffer.snapshot.markers.rankBias(of: m1) == .left)
        #expect(buffer.snapshot.markers.rankPosition(of: m2) == 4)
        #expect(buffer.snapshot.markers.rankBias(of: m2) == .right)
    }

    // MARK: - Test 3

    @Test("row 3: a .right marker exactly at lo returns to lo, not hi, after undoing a deletion")
    func undoDeletionRow3Trap() {
        let buffer = makeBuffer("abcdefgh")
        let m = buffer.createMarker(atByteOffset: 2, bias: .right)
        buffer.replaceSubrange(2..<5, with: "")
        buffer.undo()
        #expect(buffer.snapshot.text.toString() == "abcdefgh")
        #expect(buffer.snapshot.markers.rankPosition(of: m) == 2)
    }

    // MARK: - Test 4

    @Test("row 5: a .left marker exactly at hi returns to hi, not lo, after undoing a deletion")
    func undoDeletionRow5Mirror() {
        let buffer = makeBuffer("abcdefgh")
        let m = buffer.createMarker(atByteOffset: 5, bias: .left)
        buffer.replaceSubrange(2..<5, with: "")
        buffer.undo()
        #expect(buffer.snapshot.text.toString() == "abcdefgh")
        #expect(buffer.snapshot.markers.rankPosition(of: m) == 5)
    }

    // MARK: - Test 5

    @Test("rows 2 and 6: lo/.left and hi/.right markers, which the inverse would restore anyway")
    func undoDeletionRows2And6() {
        let buffer = makeBuffer("abcdefgh")
        let mLo = buffer.createMarker(atByteOffset: 2, bias: .left)
        let mHi = buffer.createMarker(atByteOffset: 5, bias: .right)
        buffer.replaceSubrange(2..<5, with: "")
        buffer.undo()
        #expect(buffer.snapshot.markers.rankPosition(of: mLo) == 2)
        #expect(buffer.snapshot.markers.rankBias(of: mLo) == .left)
        #expect(buffer.snapshot.markers.rankPosition(of: mHi) == 5)
        #expect(buffer.snapshot.markers.rankBias(of: mHi) == .right)
    }

    // MARK: - Test 6

    @Test(
        "interval row 2: an end-exactly-at-lo interval with rearAdvance returns to its original length after undo"
    )
    func undoIntervalRow2EndAtLo() {
        let buffer = makeBuffer("0123456789")
        let id = buffer.createInterval(byteRange: 2..<5, frontAdvance: false, rearAdvance: true)

        buffer.replaceSubrange(5..<5, with: "XY")
        #expect(buffer.snapshot.intervals.rankSpan(of: id)?.range == 2..<7)

        buffer.undo()
        #expect(buffer.snapshot.text.toString() == "0123456789")
        #expect(buffer.snapshot.intervals.rankSpan(of: id)?.range == 2..<5)
    }

    // MARK: - Test 7

    @Test(
        "interval rows 3, 5, 6: straddlers and tie-group starts survive a replace/undo round trip")
    func undoIntervalRows356() {
        let buffer = makeBuffer("0123456789ABCDEF")
        // Row 3: s < lo < e <= hi.
        let straddler = buffer.createInterval(
            byteRange: 2..<6, frontAdvance: false, rearAdvance: false)
        // Row 5: s in [lo, hi).
        let insideStart = buffer.createInterval(
            byteRange: 5..<7, frontAdvance: true, rearAdvance: false)
        // Row 6, moves: s == hi, frontAdvance true (startMoves true).
        let atHiMoves = buffer.createInterval(
            byteRange: 10..<13, frontAdvance: true, rearAdvance: true)
        // Row 6, stays: s == hi, frontAdvance false (startMoves false).
        let atHiStays = buffer.createInterval(
            byteRange: 10..<13, frontAdvance: false, rearAdvance: false)

        let beforeStraddler = buffer.snapshot.intervals.rankSpan(of: straddler)
        let beforeInsideStart = buffer.snapshot.intervals.rankSpan(of: insideStart)
        let beforeAtHiMoves = buffer.snapshot.intervals.rankSpan(of: atHiMoves)
        let beforeAtHiStays = buffer.snapshot.intervals.rankSpan(of: atHiStays)

        buffer.replaceSubrange(4..<10, with: "XYZ")
        buffer.undo()

        #expect(buffer.snapshot.text.toString() == "0123456789ABCDEF")
        #expect(buffer.snapshot.intervals.rankSpan(of: straddler) == beforeStraddler)
        #expect(buffer.snapshot.intervals.rankSpan(of: insideStart) == beforeInsideStart)
        #expect(buffer.snapshot.intervals.rankSpan(of: atHiMoves) == beforeAtHiMoves)
        #expect(buffer.snapshot.intervals.rankSpan(of: atHiStays) == beforeAtHiStays)
    }

    // MARK: - Test 8

    @Test("a replace with markers and intervals on every endpoint, undone and redone")
    func replaceWithEndpointsUndoneAndRedone() {
        let buffer = makeBuffer("0123456789")
        let mLo = buffer.createMarker(atByteOffset: 3, bias: .left)
        let mHi = buffer.createMarker(atByteOffset: 6, bias: .right)
        let mInside = buffer.createMarker(atByteOffset: 4, bias: .left)
        let iLo = buffer.createInterval(byteRange: 3..<5, frontAdvance: false, rearAdvance: false)
        let iHi = buffer.createInterval(byteRange: 1..<6, frontAdvance: false, rearAdvance: true)

        let beforeText = buffer.snapshot.text.toString()
        let beforeMLo = buffer.snapshot.markers.rankPosition(of: mLo)
        let beforeMHi = buffer.snapshot.markers.rankPosition(of: mHi)
        let beforeMInside = buffer.snapshot.markers.rankPosition(of: mInside)
        let beforeILo = buffer.snapshot.intervals.rankSpan(of: iLo)
        let beforeIHi = buffer.snapshot.intervals.rankSpan(of: iHi)

        buffer.replaceSubrange(3..<6, with: "QQQQ")  // d = 3, L = 4
        let afterText = buffer.snapshot.text.toString()
        #expect(afterText != beforeText)

        buffer.undo()
        #expect(buffer.snapshot.text.toString() == beforeText)
        #expect(buffer.snapshot.markers.rankPosition(of: mLo) == beforeMLo)
        #expect(buffer.snapshot.markers.rankPosition(of: mHi) == beforeMHi)
        #expect(buffer.snapshot.markers.rankPosition(of: mInside) == beforeMInside)
        #expect(buffer.snapshot.intervals.rankSpan(of: iLo) == beforeILo)
        #expect(buffer.snapshot.intervals.rankSpan(of: iHi) == beforeIHi)

        buffer.redo()
        #expect(buffer.snapshot.text.toString() == afterText)
    }

    // MARK: - Test 9

    @Test(
        "a multi-edit transaction's inverses apply newest-first: the spatially earlier, length-changing edit must change the buffer's length"
    )
    func multiEditTransactionOrderMatters() {
        let buffer = makeBuffer("0123456789")
        // Edit A: replace [2,5) with "XY" — length-changing (d=3, L=2).
        buffer.replaceSubrange(2..<5, with: "XY")
        #expect(buffer.snapshot.text.toString() == "01XY56789")
        // Edit B: insert "Q" at offset 7, in the post-edit-A buffer.
        buffer.replaceSubrange(7..<7, with: "Q")
        #expect(buffer.snapshot.text.toString() == "01XY567Q89")
        buffer.commitTransaction()

        buffer.undo()
        #expect(buffer.snapshot.text.toString() == "0123456789")
    }

    // MARK: - Test 10

    @Test("commit grouping on a non-empty history, and the node count a spurious append would move")
    func commitGroupingOnNonEmptyHistory() {
        let buffer = makeBuffer("")
        buffer.replaceSubrange(0..<0, with: "seed")
        buffer.commitTransaction()
        #expect(buffer.history.nodeCount == 2)

        buffer.replaceSubrange(4..<4, with: "AB")
        buffer.replaceSubrange(6..<6, with: "CD")
        buffer.commitTransaction()
        #expect(buffer.snapshot.text.toString() == "seedABCD")

        buffer.replaceSubrange(8..<8, with: "EF")
        buffer.replaceSubrange(10..<10, with: "GH")
        buffer.commitTransaction()
        #expect(buffer.snapshot.text.toString() == "seedABCDEFGH")
        #expect(buffer.history.nodeCount == 4)

        // Idempotent: nothing pending, so no node is appended.
        buffer.commitTransaction()
        #expect(buffer.history.nodeCount == 4)

        buffer.undo()
        #expect(buffer.snapshot.text.toString() == "seedABCD")
        buffer.undo()
        #expect(buffer.snapshot.text.toString() == "seed")
    }

    // MARK: - Test 11

    @Test("branching: two children from the same state, redo prefers the most recent")
    func branching() {
        let buffer = makeBuffer("base")
        buffer.replaceSubrange(4..<4, with: "A")
        buffer.commitTransaction()
        let nodeA = buffer.history.current

        buffer.undo()
        #expect(buffer.snapshot.text.toString() == "base")

        buffer.replaceSubrange(4..<4, with: "B")
        buffer.commitTransaction()
        let nodeB = buffer.history.current
        #expect(buffer.snapshot.text.toString() == "baseB")

        let root = buffer.history.node(nodeA).parent
        #expect(root == buffer.history.node(nodeB).parent)
        #expect(Set(buffer.history.children(of: root)) == Set([nodeA, nodeB]))

        buffer.undo()
        #expect(buffer.redo() != nil)
        #expect(buffer.snapshot.text.toString() == "baseB")

        // A's branch is not the active one, but its recorded edit is still exact data — stage
        // 1 builds no branch-switching command (that is M5's, `dev/specs/m1.5.md` 1.6
        // property 1), so "reachable" is checked at the data level here.
        let aEdits = buffer.history.node(nodeA).edits
        #expect(aEdits.count == 1)
        var reconstructed = Rope("base")
        reconstructed.replaceSubrange(aEdits[0].byteRange, with: aEdits[0].inserted)
        #expect(reconstructed.toString() == "baseA")
    }

    // MARK: - Test 12

    @Test("undo()'s applied-replacement list is the transaction's edits inverted, newest first")
    func traversalReturnValue() {
        let buffer = makeBuffer("0123456789")
        buffer.replaceSubrange(2..<5, with: "XY")
        buffer.replaceSubrange(7..<7, with: "Q")
        buffer.commitTransaction()
        #expect(buffer.snapshot.text.toString() == "01XY567Q89")

        let result = buffer.undo()
        let applied = result?.applied ?? []
        #expect(applied.count == 2)
        #expect(applied[0].byteRange == 7..<8)
        #expect(applied[0].inserted.toString() == "")
        #expect(applied[1].byteRange == 2..<4)
        #expect(applied[1].inserted.toString() == "234")
        #expect(buffer.snapshot.text.toString() == "0123456789")
    }

    // MARK: - Test 13

    @Test(
        "the before/after entry-set queries return the same id set, and it is what TextBuffer.replaceSubrange actually recorded"
    )
    func entrySetQueriesAgree() {
        let buffer = makeBuffer("0123456789")
        let mLo = buffer.createMarker(atByteOffset: 3, bias: .left)
        let mHi = buffer.createMarker(atByteOffset: 6, bias: .right)
        let iStraddle = buffer.createInterval(
            byteRange: 1..<4, frontAdvance: false, rearAdvance: false)
        let iAtLo = buffer.createInterval(byteRange: 3..<5, frontAdvance: true, rearAdvance: false)
        let iAtHi = buffer.createInterval(byteRange: 6..<8, frontAdvance: false, rearAdvance: true)

        let lo = 3
        let hi = 6
        // Independent derivation, kept as a cross-check (`dev/specs/m1.5.md` 1.4's "the two
        // queries return the same id set" argument) — computed with the test's own hardcoded
        // ranges, not by calling `TextBuffer.replaceSubrange`, so it is unaffected by a
        // narrowing bug in that production path.
        let markersBefore = Set(buffer.snapshot.markers.markers(in: lo..<(hi + 1)).map { $0.id })
        let intervalsBefore = Set(
            buffer.snapshot.intervals.undoEntrySet(lo: lo, upperInclusive: hi).map { $0.id })

        buffer.replaceSubrange(lo..<hi, with: "QQ")

        let afterLo = lo
        let afterHi = lo + 2
        let markersAfter = Set(
            buffer.snapshot.markers.markers(in: afterLo..<(afterHi + 1)).map { $0.id })
        let intervalsAfter = Set(
            buffer.snapshot.intervals.undoEntrySet(lo: afterLo, upperInclusive: afterHi).map {
                $0.id
            })

        #expect(markersBefore == markersAfter)
        #expect(markersBefore.contains(mLo))
        #expect(markersBefore.contains(mHi))
        #expect(intervalsBefore == intervalsAfter)
        #expect(intervalsBefore.isSuperset(of: [iStraddle, iAtLo, iAtHi]))

        // **The production path.** `TextBuffer.replaceSubrange` (`TextBuffer.swift:67`, `:75`)
        // runs its own before/after queries and keeps only the ids `buildMarkerEntries`/
        // `buildIntervalEntries` find on both sides (`TextBuffer.swift`'s pairing functions
        // drop an id present on only one side). A narrowing of either query — `lo..<(hi + 1)`
        // to `lo..<hi`, or `afterLo..<(afterHi + 1)` to `afterLo..<afterHi` — would make that
        // production-side before/after pair disagree and drop an id from what gets recorded,
        // invisible to the independent computation above because that computation does not
        // call the mutated line at all. Reading `pendingEdits` is what closes that gap.
        #expect(buffer.pendingEdits.count == 1)
        let recordedMarkerIDs = Set(buffer.pendingEdits[0].markerEntries.map { $0.id })
        let recordedIntervalIDs = Set(buffer.pendingEdits[0].intervalEntries.map { $0.id })
        #expect(recordedMarkerIDs == markersBefore)
        #expect(recordedIntervalIDs == intervalsBefore)
    }

    // MARK: - Test 13b

    @Test("tie order at one offset survives an undo/redo round trip")
    func tieOrderSurvivesTraversal() {
        let buffer = makeBuffer("0123456789")
        let lo = 3
        let m1 = buffer.createMarker(atByteOffset: lo, bias: .left)
        let m2 = buffer.createMarker(atByteOffset: lo, bias: .left)
        let m3 = buffer.createMarker(atByteOffset: lo, bias: .left)
        let i1 = buffer.createInterval(byteRange: lo..<lo, frontAdvance: false, rearAdvance: false)
        let i2 = buffer.createInterval(byteRange: lo..<lo, frontAdvance: false, rearAdvance: false)

        func markerOrder() -> [MarkerID] {
            (0..<buffer.snapshot.markers.count).map { buffer.snapshot.markers.id(ofRank: $0) }
                .filter { [m1, m2, m3].contains($0) }
        }
        func intervalOrder() -> [IntervalID] {
            (0..<buffer.snapshot.intervals.count).map { buffer.snapshot.intervals.id(ofRank: $0) }
                .filter { [i1, i2].contains($0) }
        }

        // `MarkerTree.inserting`/`IntervalTree.inserting` each prepend a new key to an
        // existing tie group (`MarkerTree.swift`'s own doc comment: "places a new key before
        // the first item whose key is greater than or equal to it"), so creating m1, m2, m3
        // front-to-back leaves them in *reverse* creation order — [m3, m2, m1], not [m1, m2,
        // m3]. The order under test here is round-trip stability, not creation order.
        let beforeMarkerOrder = markerOrder()
        let beforeIntervalOrder = intervalOrder()
        #expect(beforeMarkerOrder == [m3, m2, m1])
        #expect(beforeIntervalOrder == [i2, i1])

        buffer.replaceSubrange(lo..<(lo + 2), with: "ZZZZ")
        buffer.undo()
        #expect(markerOrder() == beforeMarkerOrder)
        #expect(intervalOrder() == beforeIntervalOrder)

        buffer.redo()
        #expect(markerOrder() == beforeMarkerOrder)
        #expect(intervalOrder() == beforeIntervalOrder)
    }

    @Test("a multi-chunk insertion round-trips through undo and redo byte for byte")
    func multiChunkInsertionRoundTrips() {
        // Every other test here inserts a few bytes, which takes `Rope.replaceSubrange`'s
        // leaf-local fast path (`other.utf8Count <= 64`). An insertion above that ceiling
        // takes the general path, where the caller's rope enters the tree as a **subtree**
        // rather than being copied byte-wise — and M1.5 records `inserted` as exactly that
        // rope rather than slicing the same bytes back out of the buffer. A review round
        // pointed out nothing exercised that branch through undo and redo, so this test's
        // failure mode is the one the shortcut could have: a redo that re-applies something
        // other than what was inserted.
        let buffer = TextBuffer()
        let base = String(repeating: "abcdefgh", count: 64)  // 512 bytes, many chunks
        buffer.replaceSubrange(0..<0, with: base)
        buffer.commitTransaction()

        // Markers at both endpoints of the edit and inside it, an interval starting inside
        // it, and one straddling it from outside. The straddler is the spec's row 4, a
        // container that needs no entry for correctness — and it is worth having because
        // `undoEntrySet` is a deliberate superset that returns it anyway, so on undo and redo
        // it goes through the same remove-and-reinsert path as the rest rather than through
        // the length adjustment its shape would suggest. (A review round caught this comment
        // claiming the opposite: the automatic length adjustment runs only on the live
        // forward edit, because by the time a traversal's inverse edit runs, the entry set
        // has already taken this interval out of the tree.) The general path is otherwise exercised only for text: a review
        // round found no test anywhere combining an insertion above the fast-path ceiling
        // with a live marker or interval through undo and redo, so the entry-set machinery
        // had never run on this branch.
        //
        // The comparisons go through `rankBias`/`rankSpan`, not through a local helper that
        // reads positions out of a range query: bias and the two advance flags are carried by
        // the entry and re-applied on reinsertion, so a restoration that lands the right
        // offset with the wrong bias is a real failure mode, and the first version of this
        // test compared offsets and ranges only — a review round caught that, and pointed out
        // these helpers were already in scope and already return the whole record. They also
        // return `nil` rather than trapping when an id has gone missing.
        let atLo = buffer.createMarker(atByteOffset: 200, bias: .right)
        let inside = buffer.createMarker(atByteOffset: 230, bias: .left)
        let atHi = buffer.createMarker(atByteOffset: 260, bias: .left)
        let straddler = buffer.createInterval(byteRange: 150..<300)
        let startsInside = buffer.createInterval(byteRange: 210..<240)
        // Two parallel arrays rather than one struct: `MarkerState` below is this file's
        // own non-optional shape, and these lookups have to be able to report a marker that
        // has gone missing as `nil` instead of trapping.
        func markerOffsets() -> [Int?] {
            [atLo, inside, atHi].map { buffer.snapshot.markers.rankPosition(of: $0) }
        }
        func markerBiases() -> [MarkerBias?] {
            [atLo, inside, atHi].map { buffer.snapshot.markers.rankBias(of: $0) }
        }
        func intervalStates() -> [IntervalSpan?] {
            [straddler, startsInside].map { buffer.snapshot.intervals.rankSpan(of: $0) }
        }
        let offsetsBefore = markerOffsets()
        let biasesBefore = markerBiases()
        let intervalsBefore = intervalStates()
        #expect(offsetsBefore == [200, 230, 260])
        #expect(biasesBefore == [.right, .left, .left])
        #expect(intervalsBefore.allSatisfy { $0 != nil })

        let big = String(repeating: "0123456789", count: 40)  // 400 bytes, general path
        buffer.replaceSubrange(200..<260, with: big)
        buffer.commitTransaction()
        let afterEdit = buffer.snapshot.text.toString()
        #expect(afterEdit.utf8.count == base.utf8.count - 60 + big.utf8.count)
        let offsetsAfterEdit = markerOffsets()
        let biasesAfterEdit = markerBiases()
        let intervalsAfterEdit = intervalStates()

        buffer.undo()
        #expect(buffer.snapshot.text.toString() == base)
        #expect(markerOffsets() == offsetsBefore)
        #expect(markerBiases() == biasesBefore)
        #expect(intervalStates() == intervalsBefore)

        buffer.redo()
        #expect(buffer.snapshot.text.toString() == afterEdit)
        #expect(markerOffsets() == offsetsAfterEdit)
        #expect(markerBiases() == biasesAfterEdit)
        #expect(intervalStates() == intervalsAfterEdit)

        buffer.undo()
        #expect(buffer.snapshot.text.toString() == base)
        #expect(markerOffsets() == offsetsBefore)
        #expect(markerBiases() == biasesBefore)
        #expect(intervalStates() == intervalsBefore)
    }

    // MARK: - F1(a): undoEntrySet's end search must filter per item, not by leaf co-residence

    @Test(
        "undoEntrySet's end search filters per item rather than accepting a whole leaf"
    )
    func undoEntrySetEndSearchFiltersPerItem() {
        let buffer = makeBuffer(String(repeating: "x", count: 200))
        var pointIntervalIDs: [IntervalID] = []
        for i in 0..<40 {
            let id = buffer.createInterval(
                byteRange: i..<(i + 1), frontAdvance: false, rearAdvance: false)
            pointIntervalIDs.append(id)
        }
        let straddler = buffer.createInterval(
            byteRange: 50..<150, frontAdvance: false, rearAdvance: false)

        buffer.replaceSubrange(100..<110, with: "")
        #expect(buffer.pendingEdits.count == 1)
        let recorded = Set(buffer.pendingEdits[0].intervalEntries.map { $0.id })

        // None of the 40 point intervals (ends 1...40) have an endpoint anywhere near [100,
        // 110]; only the straddler (start 50 < lo, end 150 >= lo, a row-4 container the query
        // is a deliberate superset over) belongs. Measured on this machine before the
        // per-item filter was added: the recorded set was `{34, 35, ..., 39, straddler}` —
        // six point intervals swept in purely because they shared a B+-tree leaf with the
        // straddler under `visitEndAtOrAfterInclusive`'s subtree-granularity prune.
        #expect(recorded == Set([straddler]))
        #expect(Set(pointIntervalIDs).isDisjoint(with: recorded))
    }

    @Test(
        "undoEntrySet's tie-group window is exactly [s, s+1): a neighbour one byte past a qualifying start stays out"
    )
    func undoEntrySetTieGroupWindowIsExact() {
        let buffer = makeBuffer(String(repeating: "x", count: 60))
        // Two groups one byte apart. Only `qualifying` reaches lo = 40, so only the group at
        // start 10 is closed over; `neighbour` starts at 11 and ends far short of lo, so a
        // window that ran to `rank(startAtOrAfter: s + 2)` instead of `s + 1` would sweep it
        // in — a review round found every earlier test blind to that bound, because none of
        // them had anything at `s + 1` at all.
        let qualifying = buffer.createInterval(byteRange: 10..<50)
        let tieMate = buffer.createInterval(byteRange: 10..<12)
        let neighbour = buffer.createInterval(byteRange: 11..<13)

        buffer.replaceSubrange(40..<45, with: "")
        #expect(buffer.pendingEdits.count == 1)
        let recorded = Set(buffer.pendingEdits[0].intervalEntries.map { $0.id })
        #expect(recorded == Set([qualifying, tieMate]))
        #expect(!recorded.contains(neighbour))
    }

    @Test("undoEntrySet closes every qualifying start, not only the first one found")
    func undoEntrySetClosesEveryQualifyingStart() {
        let buffer = makeBuffer(String(repeating: "x", count: 80))
        // Two distinct starts below lo both reach it, each with a tie-mate that does not.
        // Every earlier test has exactly one qualifying start, so none of them can see a
        // closure loop that stops after the first.
        let reachA = buffer.createInterval(byteRange: 5..<50)
        let mateA = buffer.createInterval(byteRange: 5..<6)
        let reachB = buffer.createInterval(byteRange: 20..<60)
        let mateB = buffer.createInterval(byteRange: 20..<21)
        let farAway = buffer.createInterval(byteRange: 30..<31)

        let beforeOrder = buffer.snapshot.intervals.intervals(
            overlapping: 0..<80, includingEmptyAtUpperBound: false
        ).map { $0.id }
        buffer.replaceSubrange(45..<48, with: "")
        buffer.commitTransaction()
        let recorded = Set(buffer.pendingEdits.first?.intervalEntries.map { $0.id } ?? [])
        #expect(buffer.history.node(buffer.history.current).edits.count == 1)
        let committed = Set(
            buffer.history.node(buffer.history.current).edits[0].intervalEntries.map { $0.id })
        #expect(recorded.isEmpty)
        #expect(committed == Set([reachA, mateA, reachB, mateB]))
        #expect(!committed.contains(farAway))

        buffer.undo()
        #expect(
            buffer.snapshot.intervals.intervals(
                overlapping: 0..<80, includingEmptyAtUpperBound: false
            ).map { $0.id } == beforeOrder)
    }

    // MARK: - F1(b): undoEntrySet must close tie groups at a start below lo

    @Test(
        "undoEntrySet closes the tie group at a qualifying start, so undo does not reverse their order"
    )
    func undoEntrySetTieGroupClosure() {
        let buffer = makeBuffer("0123456789")
        // Both start at 0, below every `lo` used below; `y` created first, `x` second, so
        // `IntervalTree.inserting`'s prepend-to-tie-group rule leaves `x` before `y`.
        let y = buffer.createInterval(byteRange: 0..<10, frontAdvance: false, rearAdvance: false)
        let x = buffer.createInterval(byteRange: 0..<2, frontAdvance: false, rearAdvance: false)

        func order() -> [IntervalID] {
            (0..<buffer.snapshot.intervals.count).map { buffer.snapshot.intervals.id(ofRank: $0) }
                .filter { [x, y].contains($0) }
        }
        let beforeOrder = order()
        #expect(beforeOrder == [x, y])

        // `y`'s end (10) is at or after lo=5, so it qualifies for the end search; `x`'s end
        // (2) does not. Without tie-group closure only `y` is in the entry set: `y` is
        // removed and reinserted by the traversal while `x` (never touched) stays put, so
        // reinsertion prepends `y` in front of `x` — reversing the pair to `[y, x]`. Measured
        // on this machine before closure was added: exactly that reversal, after commit and
        // undo.
        buffer.replaceSubrange(5..<7, with: "")
        buffer.commitTransaction()
        buffer.undo()

        #expect(buffer.snapshot.text.toString() == "0123456789")
        #expect(order() == beforeOrder)
    }

    // MARK: - Test 14

    @Test(
        "insertBeforeMarkers is unobservable during replay: each variant round-trips through undo/redo exactly"
    )
    func insertBeforeMarkersUnobservable() {
        var livePositions: [Bool: Int] = [:]

        for ibm in [false, true] {
            let buffer = makeBuffer("0123456789")
            let m = buffer.createMarker(atByteOffset: 4, bias: .left)
            let i = buffer.createInterval(byteRange: 4..<4, frontAdvance: true, rearAdvance: false)

            buffer.replaceSubrange(4..<4, with: "XY", insertBeforeMarkers: ibm)
            let livePosition = buffer.snapshot.markers.rankPosition(of: m)
            let liveRange = buffer.snapshot.intervals.rankSpan(of: i)?.range
            livePositions[ibm] = livePosition

            buffer.undo()
            #expect(buffer.snapshot.text.toString() == "0123456789")
            #expect(buffer.snapshot.markers.rankPosition(of: m) == 4)
            #expect(buffer.snapshot.intervals.rankSpan(of: i)?.range == 4..<4)

            buffer.redo()
            #expect(buffer.snapshot.text.toString() == "0123XY456789")
            #expect(buffer.snapshot.markers.rankPosition(of: m) == livePosition)
            #expect(buffer.snapshot.intervals.rankSpan(of: i)?.range == liveRange)
        }

        // The two variants really do differ live — otherwise this test would be vacuous.
        #expect(livePositions[false] != livePositions[true])
    }

    // MARK: - Test 15

    @Test("a removed marker does not break a traversal")
    func removedMarkerDoesNotBreakTraversal() {
        let buffer = makeBuffer("0123456789")
        let mSurvivor = buffer.createMarker(atByteOffset: 4, bias: .left)
        let mRemoved = buffer.createMarker(atByteOffset: 4, bias: .right)
        buffer.replaceSubrange(4..<4, with: "XY")
        buffer.commitTransaction()
        buffer.undo()
        #expect(buffer.snapshot.text.toString() == "0123456789")

        // Marker removal is never undoable (3's "never" row); remove it directly.
        buffer.removeMarker(id: mRemoved, atByteOffset: 4)

        let redone = buffer.redo()
        #expect(redone != nil)
        #expect(buffer.snapshot.text.toString() == "0123XY456789")
        #expect(buffer.snapshot.markers.rankPosition(of: mSurvivor) != nil)
        #expect(buffer.snapshot.markers.rankPosition(of: mRemoved) == nil)
    }

    // MARK: - F4: the "removal is not undoable" guard, in each of its four directions

    @Test("a removed marker does not come back on undo")
    func removedMarkerDoesNotBreakUndo() {
        let buffer = makeBuffer("0123456789")
        let mSurvivor = buffer.createMarker(atByteOffset: 4, bias: .left)
        let mRemoved = buffer.createMarker(atByteOffset: 4, bias: .right)
        buffer.replaceSubrange(4..<4, with: "XY")
        buffer.commitTransaction()
        #expect(buffer.snapshot.text.toString() == "0123XY456789")

        // Marker removal is never undoable (section 3's "never" row); remove it at its
        // current (post-edit) position, then undo the transaction that moved it there.
        let removedOffset = buffer.snapshot.markers.rankPosition(of: mRemoved)!
        buffer.removeMarker(id: mRemoved, atByteOffset: removedOffset)

        let undone = buffer.undo()
        #expect(undone != nil)
        #expect(buffer.snapshot.text.toString() == "0123456789")
        #expect(buffer.snapshot.markers.rankPosition(of: mSurvivor) != nil)
        #expect(buffer.snapshot.markers.rankPosition(of: mRemoved) == nil)
    }

    @Test("a removed interval does not come back on undo")
    func removedIntervalDoesNotBreakUndo() {
        let buffer = makeBuffer("0123456789")
        let iSurvivor = buffer.createInterval(
            byteRange: 4..<4, frontAdvance: true, rearAdvance: false)
        let iRemoved = buffer.createInterval(
            byteRange: 4..<4, frontAdvance: false, rearAdvance: true)
        buffer.replaceSubrange(4..<4, with: "XY")
        buffer.commitTransaction()

        let removedSpan = buffer.snapshot.intervals.rankSpan(of: iRemoved)!
        buffer.removeInterval(id: iRemoved, startingAt: removedSpan.range.lowerBound)

        let undone = buffer.undo()
        #expect(undone != nil)
        #expect(buffer.snapshot.text.toString() == "0123456789")
        #expect(buffer.snapshot.intervals.rankSpan(of: iSurvivor) != nil)
        #expect(buffer.snapshot.intervals.rankSpan(of: iRemoved) == nil)
    }

    @Test("a removed interval does not come back on redo")
    func removedIntervalDoesNotBreakRedo() {
        let buffer = makeBuffer("0123456789")
        let iSurvivor = buffer.createInterval(
            byteRange: 4..<4, frontAdvance: true, rearAdvance: false)
        let iRemoved = buffer.createInterval(
            byteRange: 4..<4, frontAdvance: false, rearAdvance: true)
        buffer.replaceSubrange(4..<4, with: "XY")
        buffer.commitTransaction()
        buffer.undo()
        #expect(buffer.snapshot.text.toString() == "0123456789")

        // Both intervals are back at their pre-edit (before-edit) position here; remove one,
        // then redo the edge that would otherwise have reinserted it.
        let removedSpan = buffer.snapshot.intervals.rankSpan(of: iRemoved)!
        buffer.removeInterval(id: iRemoved, startingAt: removedSpan.range.lowerBound)

        let redone = buffer.redo()
        #expect(redone != nil)
        #expect(buffer.snapshot.text.toString() == "0123XY456789")
        #expect(buffer.snapshot.intervals.rankSpan(of: iSurvivor) != nil)
        #expect(buffer.snapshot.intervals.rankSpan(of: iRemoved) == nil)
    }

    // MARK: - Test 16

    @Test("isRecordingUndo == false records nothing and the edit is not undoable")
    func isRecordingUndoFalse() {
        let buffer = makeBuffer("0123456789")
        let nodeCountBefore = buffer.history.nodeCount

        buffer.isRecordingUndo = false
        buffer.replaceSubrange(3..<3, with: "XY")
        #expect(buffer.snapshot.text.toString() == "012XY3456789")
        #expect(buffer.pendingEdits.isEmpty)

        buffer.commitTransaction()
        #expect(buffer.history.nodeCount == nodeCountBefore)
        #expect(buffer.history.canUndo == false)

        buffer.isRecordingUndo = true
        #expect(buffer.undo() == nil)
        #expect(buffer.snapshot.text.toString() == "012XY3456789")
    }

    // MARK: - Test 17

    @Test(
        "empty and degenerate edits: no-op commit, undo/redo at the ends, zero-length and boundary edits"
    )
    func emptyAndDegenerateEdits() {
        let buffer = makeBuffer("")
        let nodeCountBefore = buffer.history.nodeCount
        buffer.commitTransaction()
        #expect(buffer.history.nodeCount == nodeCountBefore)
        #expect(buffer.undo() == nil)

        buffer.replaceSubrange(0..<0, with: "abc")
        buffer.commitTransaction()
        #expect(buffer.redo() == nil)

        buffer.replaceSubrange(1..<1, with: "")
        buffer.commitTransaction()
        #expect(buffer.snapshot.text.toString() == "abc")
        #expect(buffer.undo() != nil)
        #expect(buffer.snapshot.text.toString() == "abc")

        buffer.replaceSubrange(0..<0, with: "X")
        buffer.commitTransaction()
        #expect(buffer.snapshot.text.toString() == "Xabc")
        #expect(buffer.undo() != nil)
        #expect(buffer.snapshot.text.toString() == "abc")

        let end = buffer.snapshot.text.utf8Count
        buffer.replaceSubrange(end..<end, with: "Z")
        buffer.commitTransaction()
        #expect(buffer.snapshot.text.toString() == "abcZ")
        #expect(buffer.undo() != nil)
        #expect(buffer.snapshot.text.toString() == "abc")
    }

    // MARK: - Test 18a

    @Test("payload primitives: tombstone and promote")
    func payloadPrimitives() throws {
        let buffer = makeBuffer("0")
        buffer.replaceSubrange(1..<1, with: "1")
        buffer.commitTransaction()
        let n1 = buffer.history.current

        buffer.replaceSubrange(2..<2, with: "2")
        buffer.commitTransaction()
        let n2 = buffer.history.current

        buffer.replaceSubrange(3..<3, with: "3")
        buffer.commitTransaction()
        let n3 = buffer.history.current

        let genesis = buffer.history.node(n1).parent
        let nodeCountBefore = buffer.history.nodeCount
        let totalBefore = buffer.history.totalByteCost

        var tombstoned = buffer.history
        // n1 is one level under genesis and n3 is two levels under n1 — the "at least two
        // levels deep" fixture 18a requires, so the leaves-first walk is exercised.
        tombstoned.tombstone(n1)

        #expect(tombstoned.children(of: genesis).isEmpty)
        for n in [n1, n2, n3] {
            let node = tombstoned.node(n)
            #expect(node.parent == -1)
            #expect(node.firstChild == -1)
            #expect(node.nextSibling == -1)
            #expect(node.edits.isEmpty)
            #expect(node.byteCost == 0)
        }
        #expect(tombstoned.totalByteCost < totalBefore)
        #expect(tombstoned.nodeCount == nodeCountBefore)
        try tombstoned.checkInvariants()

        var promoted = buffer.history
        promoted.promote(n1)
        let promotedNode = promoted.node(n1)
        #expect(promotedNode.parent == -1)
        #expect(promotedNode.nextSibling == -1)
        #expect(promotedNode.edits.isEmpty)
        #expect(promotedNode.byteCost == 0)
        // `firstChild` is kept: a walk from the promoted root still reaches n3.
        #expect(promotedNode.firstChild == n2)
        #expect(promoted.node(n2).firstChild == n3)
        // `promote` now splices `n1` out of `genesis`'s child list too — the old parent's
        // half of the incoming edge — so a bare `promote()` leaves the whole tree
        // invariant-clean on its own (`dev/specs/m1.5.md` 1.9; a fix round found the first
        // version left this half untouched).
        #expect(!promoted.children(of: genesis).contains(n1))
        try promoted.checkInvariants()
    }

    // MARK: - F2: promote splices out of the old parent, both halves of the incoming edge

    @Test("promote removes the node from the old parent's child list, keeping an older sibling")
    func promoteSplicesOutOfOldParentChildList() throws {
        var history = UndoHistory()
        let root = history.current
        func dummyEdit(_ tag: String) -> ElementaryEdit {
            ElementaryEdit(
                byteRange: 0..<0, deleted: Rope(), inserted: Rope(tag), markerEntries: [],
                intervalEntries: [])
        }

        history.recordTransaction(edits: [dummyEdit("c1")])
        let c1 = history.current
        _ = history.moveToParent()

        history.recordTransaction(edits: [dummyEdit("c2")])
        let c2 = history.current
        _ = history.moveToParent()

        history.recordTransaction(edits: [dummyEdit("c3")])
        let c3 = history.current
        _ = history.moveToParent()

        #expect(Set(history.children(of: root)) == Set([c1, c2, c3]))

        // Promote the middle-recorded child (c2). An older sibling (c1) must stay reachable.
        history.promote(c2)
        let childrenAfter = Set(history.children(of: root))
        #expect(!childrenAfter.contains(c2))
        #expect(childrenAfter.contains(c1))
        #expect(childrenAfter.contains(c3))
        try history.checkInvariants()
    }

    @Test(
        "promote clears a lastVisitedChild that named the promoted node, so redo cannot walk into it"
    )
    func promoteClearsDanglingLastVisitedChild() throws {
        var history = UndoHistory()
        let root = history.current
        let edit = ElementaryEdit(
            byteRange: 0..<0, deleted: Rope(), inserted: Rope("x"), markerEntries: [],
            intervalEntries: [])

        history.recordTransaction(edits: [edit])
        let child = history.current
        _ = history.moveToParent()

        // Recording set `root.lastVisitedChild` to `child` — the node F2's traced consequence
        // (i) is about: `moveToLastVisitedChild()` from `root` would walk into it.
        #expect(history.canRedo)

        history.promote(child)

        // A `redo()`-shaped traversal from `root` must not walk into the promoted node.
        #expect(history.canRedo == false)
        #expect(history.moveToLastVisitedChild() == nil)
        #expect(history.current == root)
        try history.checkInvariants()
    }

    // MARK: - Test 18b

    @Test(
        "checkInvariants: edits.isEmpty <=> parent == -1, and it can actually fail on a hand-built violation"
    )
    func invariantChecking() throws {
        let buffer = makeBuffer("0")
        try buffer.history.checkInvariants()

        buffer.replaceSubrange(1..<1, with: "1")
        buffer.commitTransaction()
        try buffer.history.checkInvariants()

        buffer.discardHistory()
        try buffer.history.checkInvariants()

        buffer.replaceSubrange(2..<2, with: "2")
        buffer.commitTransaction()
        var afterTombstone = buffer.history
        afterTombstone.tombstone(afterTombstone.current)
        try afterTombstone.checkInvariants()

        // Negative test (`sumTreeTests.swift`'s precedent): a hand-built violation — a node
        // with non-empty edits but `parent == -1` — must actually fail.
        let nonEmptyEdit = ElementaryEdit(
            byteRange: 0..<0, deleted: Rope(), inserted: Rope("x"), markerEntries: [],
            intervalEntries: [])
        let malformed = UndoHistory(
            testOnlyNodes: [
                UndoHistory.Node(
                    parent: -1, firstChild: -1, nextSibling: -1, lastVisitedChild: -1,
                    edits: [nonEmptyEdit], byteCost: 0)
            ], current: 0, totalByteCost: 0)
        #expect(throws: (any Error).self) { try malformed.checkInvariants() }
    }

    // MARK: - F3: the reverse invariant — every child in a parent's child list names that parent

    @Test(
        "checkInvariants fails when a node is reachable through a parent's child list without naming that parent"
    )
    func invariantCheckingCatchesDanglingForwardReference() throws {
        // Node 0 is a root whose `firstChild` claims node 1, but node 1's own `parent` is -1
        // (also a root, with empty `edits` to keep the edits.isEmpty/parent==-1 equivalence
        // consistent on its own). The forward check (does every non-`-1` `parent` land in the
        // named parent's child list?) has nothing to complain about here, since node 1's
        // `parent` is `-1` and so is never checked against node 0's child list at all — only
        // the reverse direction (does everything *in* node 0's child list actually have node
        // 0 as its `parent`?) can catch this.
        let malformed = UndoHistory(
            testOnlyNodes: [
                UndoHistory.Node(
                    parent: -1, firstChild: 1, nextSibling: -1, lastVisitedChild: -1, edits: [],
                    byteCost: 0),
                UndoHistory.Node(
                    parent: -1, firstChild: -1, nextSibling: -1, lastVisitedChild: -1, edits: [],
                    byteCost: 0),
            ], current: 0, totalByteCost: 0)
        #expect(throws: (any Error).self) { try malformed.checkInvariants() }
    }

    /// The messages `checkInvariants()` reported, or an empty list if it did not throw — so a
    /// negative test can assert **which** violation fired rather than only that one did.
    private func messagesFromCheckingInvariants(of history: UndoHistory) -> [String] {
        do {
            try history.checkInvariants()
            return []
        } catch let violation as UndoHistoryInvariantViolation {
            return violation.messages
        } catch {
            return ["unexpected error: \(error)"]
        }
    }

    @Test("checkInvariants reports a malformed child chain instead of trapping on it")
    func invariantCheckingSurvivesAMalformedChildChain() throws {
        // Both shapes below crash `children(of:)`, which subscripts `nodes` with each link
        // unchecked: an out-of-bounds `nextSibling` traps, and a cycle never returns. A
        // review round found the first version of the reverse check bounds-testing indices
        // `children(of:)` had already dereferenced, so the guard could never run — which
        // also meant a negative test like this one would have taken the process down rather
        // than failing. `checkInvariants()` walks the chain itself for exactly this reason.
        // Every non-root node below carries a real edit, and the byte costs and running total
        // agree with it, so `edits.isEmpty <=> parent == -1`, the byte-cost checks and the sum
        // check all hold: the **only** thing left to throw about is the child chain. A review
        // round found the first version of these fixtures giving the child nodes empty
        // `edits`, which violates that equivalence on its own — the test then passed whether
        // or not the chain walk noticed anything, which is the failure mode this file's other
        // negative test documents avoiding. The messages are asserted for the same reason.
        let edit = ElementaryEdit(
            byteRange: 0..<0, deleted: Rope(), inserted: Rope("a"), markerEntries: [],
            intervalEntries: [])
        let cost = UndoHistory.byteCost(of: [edit])

        let outOfBounds = UndoHistory(
            testOnlyNodes: [
                UndoHistory.Node(
                    parent: -1, firstChild: 1, nextSibling: -1, lastVisitedChild: -1, edits: [],
                    byteCost: 0),
                UndoHistory.Node(
                    parent: 0, firstChild: -1, nextSibling: 99, lastVisitedChild: -1,
                    edits: [edit], byteCost: cost),
            ], current: 0, totalByteCost: cost)
        let outOfBoundsMessages = messagesFromCheckingInvariants(of: outOfBounds)
        // Exactly one message, not "contains one": that is what makes the fixture's own
        // cleanliness load-bearing. A review round pointed out that `contains` alone passes
        // just as well against the sloppier fixture this test used to have, where a second,
        // unrelated violation fired beside the one being asserted.
        #expect(outOfBoundsMessages.count == 1)
        #expect(outOfBoundsMessages.contains { $0.contains("out-of-bounds index 99") })

        // Node 1 and node 2 name each other as `nextSibling`, so the chain from node 0 never
        // reaches `-1`.
        let cyclic = UndoHistory(
            testOnlyNodes: [
                UndoHistory.Node(
                    parent: -1, firstChild: 1, nextSibling: -1, lastVisitedChild: -1, edits: [],
                    byteCost: 0),
                UndoHistory.Node(
                    parent: 0, firstChild: -1, nextSibling: 2, lastVisitedChild: -1,
                    edits: [edit], byteCost: cost),
                UndoHistory.Node(
                    parent: 0, firstChild: -1, nextSibling: 1, lastVisitedChild: -1,
                    edits: [edit], byteCost: cost),
            ], current: 0, totalByteCost: 2 * cost)
        let cyclicMessages = messagesFromCheckingInvariants(of: cyclic)
        // One message, and one copy of it. The count is the regression test for
        // `checkInvariants()`'s single child-list pre-pass: walked per check instead of once
        // per node, this very fixture reported the same non-termination three times — once
        // for node 0's own child list and once for each child's forward check.
        #expect(cyclicMessages.count == 1)
        #expect(cyclicMessages.filter { $0.contains("does not terminate") }.count == 1)
    }

    // MARK: - Test 18c

    @Test("discardHistory leaves the text untouched, disables undo, and zeroes the running total")
    func discardHistoryTest() {
        let buffer = makeBuffer("0123")
        buffer.replaceSubrange(4..<4, with: "45")
        buffer.commitTransaction()
        #expect(buffer.history.canUndo == true)
        #expect(buffer.history.totalByteCost > 0)
        let textBefore = buffer.snapshot.text.toString()

        buffer.discardHistory()

        #expect(buffer.snapshot.text.toString() == textBefore)
        #expect(buffer.history.canUndo == false)
        #expect(buffer.history.totalByteCost == 0)
        #expect(buffer.pendingEdits.isEmpty)
    }

    // MARK: - Test 19

    @Test("byteCost and the running total")
    func byteCostAndRunningTotal() {
        let buffer = makeBuffer("0123456789")
        // A pure insertion at a point carrying many intervals — the case an earlier draft's
        // formula reported as a constant.
        for _ in 0..<5 {
            buffer.createInterval(byteRange: 4..<4, frontAdvance: true, rearAdvance: true)
        }
        buffer.replaceSubrange(4..<4, with: "XYZ")
        let pending = buffer.pendingEdits
        #expect(pending.count == 1)
        let edit = pending[0]
        #expect(edit.deleted.utf8Count == 0)
        #expect(edit.inserted.utf8Count == 3)
        #expect(edit.intervalEntries.count == 5)

        let expectedCost =
            UndoHistory.nodeFixedOverhead + 3 + 5 * MemoryLayout<IntervalEntry>.stride
        #expect(UndoHistory.byteCost(of: [edit]) == expectedCost)

        buffer.commitTransaction()
        let node = buffer.history.node(buffer.history.current)
        #expect(node.byteCost == expectedCost)

        buffer.replaceSubrange(0..<0, with: "Q")
        buffer.commitTransaction()

        // The running total equals the sum over live nodes.
        var sum = 0
        var n = buffer.history.current
        while buffer.history.node(n).parent != -1 {
            sum += buffer.history.node(n).byteCost
            n = buffer.history.node(n).parent
        }
        #expect(buffer.history.totalByteCost == sum)

        // Maintained by release, not by a sweep: tombstoning the most recent node debits
        // exactly its own byteCost.
        var afterRelease = buffer.history
        let last = afterRelease.current
        let lastCost = afterRelease.node(last).byteCost
        let totalBefore = afterRelease.totalByteCost
        afterRelease.tombstone(last)
        #expect(afterRelease.totalByteCost == totalBefore - lastCost)
    }

    // MARK: - 4.1 differential property test

    private struct MarkerState: Equatable {
        let id: MarkerID
        let offset: Int
        let bias: MarkerBias
    }

    private struct IntervalState: Equatable {
        let id: IntervalID
        let range: Range<Int>
        let frontAdvance: Bool
        let rearAdvance: Bool
    }

    private func markerSequence(_ snapshot: BufferSnapshot) -> [MarkerState] {
        (0..<snapshot.markers.count).map {
            MarkerState(
                id: snapshot.markers.id(ofRank: $0), offset: snapshot.markers.position(ofRank: $0),
                bias: snapshot.markers.bias(ofRank: $0))
        }
    }

    private func intervalSequence(_ snapshot: BufferSnapshot) -> [IntervalState] {
        (0..<snapshot.intervals.count).map {
            let span = snapshot.intervals.span(ofRank: $0)
            return IntervalState(
                id: span.id, range: span.range, frontAdvance: span.frontAdvance,
                rearAdvance: span.rearAdvance)
        }
    }

    /// A random walk of text edits, commits, undos and redos against **a retained real
    /// `BufferSnapshot` for every visited state**, held in a sliding window of the 64 most
    /// recent — `dev/specs/m1.5.md` 4.1's oracle: undoing back to a visited state must
    /// reproduce that snapshot exactly, compared as a sequence in rank order (not a set), so
    /// the tie order of 1.4 step 3 is covered too.
    ///
    /// **Markers and intervals are created once, up front, before any commit** — not
    /// interleaved with the walk. Creation is deliberately not undo-recorded (section 3's
    /// "never" row), so a marker created after some node N was visited would still be present
    /// when N is revisited later via undo, diverging from N's retained snapshot for a reason
    /// that has nothing to do with the entry-set arithmetic this test exists to check. Fixing
    /// them before the walk starts means every retained snapshot agrees about which markers
    /// and intervals exist, and only their *positions* (driven by the entry-set machinery)
    /// vary across the walk — exactly what this test is for.
    ///
    /// **20,000 operations, not 1,000,000** — the million-operation tier is stage 2's
    /// (deliverable M), which needs a budget to exist before it can bound the history it
    /// builds (`dev/specs/m1.5.md` 4.1).
    @Test("differential: retained-snapshot oracle across 20,000 edits, commits, undos and redos")
    func differentialAgainstRetainedSnapshots() {
        let seed: UInt64 = 0xF00D_CAFE_1357
        var rng = SplitMix64(seed: seed)

        let buffer = TextBuffer()
        buffer.isRecordingUndo = false
        buffer.replaceSubrange(0..<0, with: "the quick brown fox jumps over the lazy dog")
        for _ in 0..<20 {
            let length = buffer.snapshot.text.utf8Count
            let at = Int(rng.next() % UInt64(length + 1))
            buffer.createMarker(atByteOffset: at, bias: rng.next() % 2 == 0 ? .left : .right)
        }
        for _ in 0..<12 {
            let length = buffer.snapshot.text.utf8Count
            let s = Int(rng.next() % UInt64(length + 1))
            let e = s + Int(rng.next() % UInt64(length - s + 1))
            buffer.createInterval(
                byteRange: s..<e, frontAdvance: rng.next() % 2 == 0,
                rearAdvance: rng.next() % 2 == 0)
        }
        buffer.isRecordingUndo = true

        struct Visited {
            let nodeID: Int32
            let snapshot: BufferSnapshot
        }
        var window: [Visited] = []
        let windowLimit = 64
        func recordVisit() {
            window.append(Visited(nodeID: buffer.history.current, snapshot: buffer.snapshot))
            if window.count > windowLimit { window.removeFirst() }
        }
        func verify(against visited: Visited, opIndex: Int) {
            #expect(
                buffer.snapshot.text == visited.snapshot.text,
                "seed \(seed), op \(opIndex): text mismatch")
            #expect(
                markerSequence(buffer.snapshot) == markerSequence(visited.snapshot),
                "seed \(seed), op \(opIndex): marker sequence mismatch")
            #expect(
                intervalSequence(buffer.snapshot) == intervalSequence(visited.snapshot),
                "seed \(seed), op \(opIndex): interval sequence mismatch")
        }
        // Deliverable D / `dev/specs/m1.5.md` 1.9: `checkInvariants()` runs from the
        // differential test's own cadence, not from the edit path. **A fixed cadence of every
        // 20th operation, not every operation** — measured on this machine, this file's other
        // assertions unchanged: every operation took the run from 29.1 s to 98.3 s (`swift
        // test --filter differentialAgainstRetainedSnapshots`), a 3.4x cost this project's
        // "the gate is cheap" convention does not accept for one test; every 20th operation
        // (1,001 checks: the 1,000 multiples of 20 in `0..<20,000`, plus the last iteration,
        // 19,999, which is not one of them; `checkInvariants` itself is O(node count) so the
        // cost tracks the
        // history's own growth either way) measured 31.1 s, close enough to the 29.1 s
        // baseline to keep. `checkInvariants` runs unconditionally on the last iteration too,
        // so the walk's final state is always checked regardless of where the cadence lands.
        func checkInvariants(opIndex: Int) {
            do {
                try buffer.history.checkInvariants()
            } catch {
                Issue.record("seed \(seed), op \(opIndex): invariant violation \(error)")
            }
        }

        recordVisit()

        let operationCount = 20_000
        for opIndex in 0..<operationCount {
            // `defer`, not a check at the bottom of the body: two of the switch's cases
            // `continue` on an empty buffer, and a bottom-of-body check is skipped whenever
            // one of them fires — so a scheduled tick could be dropped silently. A cold
            // review round found that in the first version of this cadence.
            defer {
                if opIndex % 20 == 0 || opIndex == operationCount - 1 {
                    checkInvariants(opIndex: opIndex)
                }
            }
            let length = buffer.snapshot.text.utf8Count
            let choice = Int(rng.next() % 100)
            switch choice {
            case 0..<40:
                let at = length == 0 ? 0 : Int(rng.next() % UInt64(length + 1))
                let insertLength = Int(rng.next() % 8) + 1
                var bytes: [UInt8] = []
                bytes.reserveCapacity(insertLength)
                for _ in 0..<insertLength { bytes.append(UInt8(97 + rng.next() % 26)) }
                buffer.replaceSubrange(at..<at, with: Rope(String(decoding: bytes, as: UTF8.self)))
            case 40..<65:
                guard length > 0 else { continue }
                let lo = Int(rng.next() % UInt64(length))
                let width = min(length - lo, Int(rng.next() % 8) + 1)
                buffer.replaceSubrange(lo..<(lo + width), with: Rope())
            case 65..<85:
                guard length > 0 else { continue }
                let lo = Int(rng.next() % UInt64(length))
                let width = min(length - lo, Int(rng.next() % 6) + 1)
                let insertLength = Int(rng.next() % 6) + 1
                var bytes: [UInt8] = []
                bytes.reserveCapacity(insertLength)
                for _ in 0..<insertLength { bytes.append(UInt8(97 + rng.next() % 26)) }
                buffer.replaceSubrange(
                    lo..<(lo + width), with: Rope(String(decoding: bytes, as: UTF8.self)))
            case 85..<91:
                buffer.commitTransaction()
                recordVisit()
            case 91..<95:
                if buffer.undo() != nil {
                    if let visited = window.first(where: { $0.nodeID == buffer.history.current }) {
                        verify(against: visited, opIndex: opIndex)
                    }
                    recordVisit()
                }
            default:
                if buffer.redo() != nil {
                    if let visited = window.first(where: { $0.nodeID == buffer.history.current }) {
                        verify(against: visited, opIndex: opIndex)
                    }
                    recordVisit()
                }
            }
        }
    }
}
