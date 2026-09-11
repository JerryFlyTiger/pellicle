import Testing

@testable import Text

/// Covers `MarkerTree` and `BufferSnapshot` (M1.3, `dev/specs/m1.3.md`): the twelve oracle
/// rows from section 4, structural invariants, and a differential property test against a
/// naive model.
///
/// **Positions transfer, numbers do not.** GNU Emacs positions are 1-based **character**
/// positions; this project's are 0-based **byte** offsets. Every oracle command below is
/// quoted verbatim with its GNU Emacs 30.2 (`/opt/homebrew/bin/emacs -Q --batch`) output, and
/// each expectation converts the GNU 1-based char position to this project's 0-based byte
/// offset explicitly at the call site, exactly as `conversionAndCursorTests.swift` already
/// does for the same reason.
///
/// **This file also checks the two-stage correction `MarkerTree.swift`'s header derives**:
/// `dev/specs/m1.3.md` section 2.B's single-fused-Δ table does not reproduce
/// `replace-at-marker` below (nor an additional oracle probe, `insideDelTypeTPushedByLaterInsert`,
/// that this file adds beyond the spec's own list) — see that header for the full algebraic
/// proof of why, and why the fix does not change either perf test's shape.
///
/// **The last four oracle rows are worth a stated conclusion**: `atPointMax`,
/// `deleteWholeBuffer`, `zeroLengthOps`, and `multibyteAfter` all fall out of the general
/// rules with no special case — insertion at the buffer's end, deleting everything, a
/// zero-length insert or delete, and a multibyte shift all behave exactly as
/// `MarkerTree.applyEdit`'s composition predicts. `multibyteAfter` additionally settles that
/// the shift unit is the inserted **byte** count (not scalar or character count), which is
/// the unit this tree already uses throughout.
@Suite("MarkerTree")
struct MarkerTreeTests {

    // MARK: - Oracle-backed conformance

    /// ```
    /// emacs -Q --batch --eval '
    /// (with-temp-buffer
    ///   (insert "abcdef")
    ///   (let ((m1 (copy-marker 3 nil)) (m2 (copy-marker 3 t)))
    ///     (goto-char 3) (insert "XY")
    ///     (message "insert-at-marker buffer=%S type-nil=%d type-t=%d"
    ///              (buffer-string) (marker-position m1) (marker-position m2))))'
    /// => insert-at-marker buffer="abXYcdef" type-nil=3 type-t=5
    /// ```
    /// 1-based char 3 -> 0-based byte 2 (both markers start there, before "XY" is inserted);
    /// GNU's final 3/5 -> 0-based 2/4.
    @Test("oracle: insert-at-marker")
    func oracleInsertAtMarker() {
        var buffer = BufferSnapshot()
        buffer.replaceSubrange(0..<0, with: "abcdef")
        let mNil: MarkerID = 0
        buffer.createMarker(id: mNil, atByteOffset: 2, bias: .left)
        let mT: MarkerID = 1
        buffer.createMarker(id: mT, atByteOffset: 2, bias: .right)
        buffer.replaceSubrange(2..<2, with: "XY")
        #expect(buffer.text.toString() == "abXYcdef")
        #expect(buffer.markers.rankPosition(of: mNil) == 2)
        #expect(buffer.markers.rankPosition(of: mT) == 4)
    }

    /// ```
    /// emacs -Q --batch --eval '
    /// (with-temp-buffer
    ///   (insert "abcdef")
    ///   (let ((m (copy-marker 4 nil)))
    ///     (goto-char 2) (insert "ZZ")
    ///     (message "insert-before buffer=%S marker=%d" (buffer-string) (marker-position m))))'
    /// => insert-before buffer="aZZbcdef" marker=6
    /// ```
    /// A marker strictly after the insertion point shifts by the inserted length regardless
    /// of bias. 1-based char 4 -> 0-based byte 3; insertion at 1-based 2 -> 0-based 1; final
    /// 6 -> 0-based 5.
    @Test("oracle: insert-before")
    func oracleInsertBefore() {
        var buffer = BufferSnapshot()
        buffer.replaceSubrange(0..<0, with: "abcdef")
        let m: MarkerID = 0
        buffer.createMarker(id: m, atByteOffset: 3, bias: .left)
        buffer.replaceSubrange(1..<1, with: "ZZ")
        #expect(buffer.text.toString() == "aZZbcdef")
        #expect(buffer.markers.rankPosition(of: m) == 5)
    }

    /// ```
    /// emacs -Q --batch --eval '
    /// (with-temp-buffer
    ///   (insert "abcdefgh")
    ///   (let ((m (copy-marker 4 nil)))
    ///     (delete-region 3 6)
    ///     (message "marker-inside-del buffer=%S marker=%d" (buffer-string) (marker-position m))))'
    /// => marker-inside-del buffer="abfgh" marker=3
    /// ```
    /// A marker strictly inside a deleted range collapses to the range's start. 1-based char
    /// 4 -> byte 3; delete [3,6) 1-based -> [2,5) 0-based; final 3 -> byte 2.
    @Test("oracle: marker-inside-del")
    func oracleMarkerInsideDel() {
        var buffer = BufferSnapshot()
        buffer.replaceSubrange(0..<0, with: "abcdefgh")
        let m: MarkerID = 0
        buffer.createMarker(id: m, atByteOffset: 3, bias: .left)
        buffer.replaceSubrange(2..<5, with: "")
        #expect(buffer.text.toString() == "abfgh")
        #expect(buffer.markers.rankPosition(of: m) == 2)
    }

    /// ```
    /// emacs -Q --batch --eval '
    /// (with-temp-buffer
    ///   (insert "abcdefgh")
    ///   (let ((mlo (copy-marker 3 nil)) (mhi (copy-marker 6 nil)) (mafter (copy-marker 7 nil)))
    ///     (delete-region 3 6)
    ///     (message "marker-at-bounds buffer=%S at-lo=%d at-hi=%d after=%d"
    ///              (buffer-string) (marker-position mlo) (marker-position mhi)
    ///              (marker-position mafter))))'
    /// => marker-at-bounds buffer="abfgh" at-lo=3 at-hi=3 after=4
    /// ```
    /// A marker exactly at the deleted range's upper bound collapses too — the range is
    /// half-open for text, not for markers.
    @Test("oracle: marker-at-bounds")
    func oracleMarkerAtBounds() {
        var buffer = BufferSnapshot()
        buffer.replaceSubrange(0..<0, with: "abcdefgh")
        let mLo: MarkerID = 0
        buffer.createMarker(id: mLo, atByteOffset: 2, bias: .left)
        let mHi: MarkerID = 1
        buffer.createMarker(id: mHi, atByteOffset: 5, bias: .left)
        let mAfter: MarkerID = 2
        buffer.createMarker(id: mAfter, atByteOffset: 6, bias: .left)
        buffer.replaceSubrange(2..<5, with: "")
        #expect(buffer.text.toString() == "abfgh")
        #expect(buffer.markers.rankPosition(of: mLo) == 2)
        #expect(buffer.markers.rankPosition(of: mHi) == 2)
        #expect(buffer.markers.rankPosition(of: mAfter) == 3)
    }

    /// ```
    /// emacs -Q --batch --eval '
    /// (with-temp-buffer
    ///   (insert "abcdefgh")
    ///   (let ((mlo (copy-marker 3 t)) (minside (copy-marker 4 t)) (mhi (copy-marker 6 t)))
    ///     (delete-region 3 6)
    ///     (message "del-with-type-t buffer=%S at-lo=%d inside=%d at-hi=%d"
    ///              (buffer-string) (marker-position mlo) (marker-position minside)
    ///              (marker-position mhi))))'
    /// => del-with-type-t buffer="abfgh" at-lo=3 inside=3 at-hi=3
    /// ```
    /// Type `t` (right bias) collapses on a pure deletion exactly as type `nil` does — the
    /// bias only matters once there is a following insertion (see `oracleReplaceAtMarker`
    /// and `insideDelTypeTPushedByLaterInsert` below).
    @Test("oracle: del-with-type-t")
    func oracleDelWithTypeT() {
        var buffer = BufferSnapshot()
        buffer.replaceSubrange(0..<0, with: "abcdefgh")
        let mLo: MarkerID = 0
        buffer.createMarker(id: mLo, atByteOffset: 2, bias: .right)
        let mInside: MarkerID = 1
        buffer.createMarker(id: mInside, atByteOffset: 3, bias: .right)
        let mHi: MarkerID = 2
        buffer.createMarker(id: mHi, atByteOffset: 5, bias: .right)
        buffer.replaceSubrange(2..<5, with: "")
        #expect(buffer.text.toString() == "abfgh")
        #expect(buffer.markers.rankPosition(of: mLo) == 2)
        #expect(buffer.markers.rankPosition(of: mInside) == 2)
        #expect(buffer.markers.rankPosition(of: mHi) == 2)
    }

    /// ```
    /// emacs -Q --batch --eval '
    /// (with-temp-buffer
    ///   (insert "abcdefgh")
    ///   (let ((m1 (copy-marker 3 nil)) (m2 (copy-marker 3 t)))
    ///     (goto-char 3) (delete-region 3 6) (insert "WXYZ")
    ///     (message "replace-at-marker buffer=%S type-nil=%d type-t=%d"
    ///              (buffer-string) (marker-position m1) (marker-position m2))))'
    /// => replace-at-marker buffer="abWXYZfgh" type-nil=3 type-t=7
    /// ```
    /// **This is the row that refutes the spec's single-fused-Δ table** — see
    /// `MarkerTree.swift`'s file header for the full derivation. The type-t marker, sitting
    /// exactly at the replace's lower bound, is untouched by the delete stage but pushed by
    /// the full inserted length in the following insertion stage; the type-nil marker is
    /// untouched by both.
    @Test("oracle: replace-at-marker (refutes the spec's single-fused-Δ table)")
    func oracleReplaceAtMarker() {
        var buffer = BufferSnapshot()
        buffer.replaceSubrange(0..<0, with: "abcdefgh")
        let mNil: MarkerID = 0
        buffer.createMarker(id: mNil, atByteOffset: 2, bias: .left)
        let mT: MarkerID = 1
        buffer.createMarker(id: mT, atByteOffset: 2, bias: .right)
        buffer.replaceSubrange(2..<5, with: "WXYZ")
        #expect(buffer.text.toString() == "abWXYZfgh")
        #expect(buffer.markers.rankPosition(of: mNil) == 2)
        #expect(buffer.markers.rankPosition(of: mT) == 6)
    }

    /// A second oracle probe, beyond the spec's own list, isolating the same mechanism from a
    /// different starting position — a right-bias marker **strictly inside** the deleted
    /// range (not at its lower bound) is *also* pushed by the following insertion, not merely
    /// collapsed, because after the delete stage it is indistinguishable from any other
    /// right-bias marker already sitting at `lo`.
    /// ```
    /// emacs -Q --batch --eval '
    /// (with-temp-buffer
    ///   (insert "abcdefgh")
    ///   (let ((m (copy-marker 4 t)))
    ///     (goto-char 3) (delete-region 3 6) (insert "WXYZ")
    ///     (message "inside-del-type-t buffer=%S marker=%d" (buffer-string) (marker-position m))))'
    /// => inside-del-type-t buffer="abWXYZfgh" marker=7
    /// ```
    @Test("oracle: a right-bias marker inside a replaced range is pushed by the insertion")
    func insideDelTypeTPushedByLaterInsert() {
        var buffer = BufferSnapshot()
        buffer.replaceSubrange(0..<0, with: "abcdefgh")
        let m: MarkerID = 0
        buffer.createMarker(id: m, atByteOffset: 3, bias: .right)
        buffer.replaceSubrange(2..<5, with: "WXYZ")
        #expect(buffer.text.toString() == "abWXYZfgh")
        #expect(buffer.markers.rankPosition(of: m) == 6)
    }

    /// ```
    /// emacs -Q --batch --eval '(message "default-types copy-marker=%S make-marker=%S"
    ///   (marker-insertion-type (copy-marker 1)) (marker-insertion-type (make-marker)))'
    /// => default-types copy-marker=nil make-marker=nil
    /// ```
    @Test("oracle: default-types (createMarker's default bias is .left)")
    func oracleDefaultTypes() {
        var buffer = BufferSnapshot()
        buffer.replaceSubrange(0..<0, with: "a")
        let m: MarkerID = 0
        buffer.createMarker(id: m, atByteOffset: 0, bias: .left)
        #expect(buffer.markers.rankBias(of: m) == .left)
    }

    /// ```
    /// emacs -Q --batch --eval '
    /// (with-temp-buffer
    ///   (insert "abcdef")
    ///   (let ((m1 (copy-marker 3 nil)) (m2 (copy-marker 3 t)))
    ///     (goto-char 3) (insert-before-markers "XY")
    ///     (message "insert-before-markers type-nil=%d type-t=%d"
    ///              (marker-position m1) (marker-position m2))))'
    /// => insert-before-markers type-nil=5 type-t=5
    /// ```
    /// With `insertBeforeMarkers: true`, **both** biases at the insertion point are pushed.
    @Test("oracle: insert-before-markers")
    func oracleInsertBeforeMarkers() {
        var buffer = BufferSnapshot()
        buffer.replaceSubrange(0..<0, with: "abcdef")
        let mNil: MarkerID = 0
        buffer.createMarker(id: mNil, atByteOffset: 2, bias: .left)
        let mT: MarkerID = 1
        buffer.createMarker(id: mT, atByteOffset: 2, bias: .right)
        buffer.replaceSubrange(2..<2, with: "XY", insertBeforeMarkers: true)
        #expect(buffer.markers.rankPosition(of: mNil) == 4)
        #expect(buffer.markers.rankPosition(of: mT) == 4)
    }

    /// ```
    /// emacs -Q --batch --eval '
    /// (with-temp-buffer
    ///   (insert "abc")
    ///   (let ((mmax-nil (copy-marker (point-max) nil)) (mmax-t (copy-marker (point-max) t))
    ///         (mmin (copy-marker (point-min) nil)))
    ///     (goto-char (point-max)) (insert "Z")
    ///     (message "at-point-max max-nil=%d max-t=%d min=%d buffer=%S"
    ///              (marker-position mmax-nil) (marker-position mmax-t) (marker-position mmin)
    ///              (buffer-string))))'
    /// => at-point-max max-nil=4 max-t=5 min=1 buffer="abcZ"
    /// ```
    @Test("oracle: at-point-max")
    func oracleAtPointMax() {
        var buffer = BufferSnapshot()
        buffer.replaceSubrange(0..<0, with: "abc")
        let mMaxNil: MarkerID = 0
        buffer.createMarker(id: mMaxNil, atByteOffset: 3, bias: .left)
        let mMaxT: MarkerID = 1
        buffer.createMarker(id: mMaxT, atByteOffset: 3, bias: .right)
        let mMin: MarkerID = 2
        buffer.createMarker(id: mMin, atByteOffset: 0, bias: .left)
        buffer.replaceSubrange(3..<3, with: "Z")
        #expect(buffer.text.toString() == "abcZ")
        #expect(buffer.markers.rankPosition(of: mMaxNil) == 3)
        #expect(buffer.markers.rankPosition(of: mMaxT) == 4)
        #expect(buffer.markers.rankPosition(of: mMin) == 0)
    }

    /// ```
    /// emacs -Q --batch --eval '
    /// (with-temp-buffer
    ///   (insert "abcdef")
    ///   (let ((m1 (copy-marker 1 nil)) (m2 (copy-marker 3 nil)) (m3 (copy-marker 6 t)))
    ///     (delete-region (point-min) (point-max))
    ///     (message "delete-whole-buffer (%d %d %d) buffer=%S"
    ///              (marker-position m1) (marker-position m2) (marker-position m3)
    ///              (buffer-string))))'
    /// => delete-whole-buffer (1 1 1) buffer=""
    /// ```
    @Test("oracle: delete-whole-buffer")
    func oracleDeleteWholeBuffer() {
        var buffer = BufferSnapshot()
        buffer.replaceSubrange(0..<0, with: "abcdef")
        let m1: MarkerID = 0
        buffer.createMarker(id: m1, atByteOffset: 0, bias: .left)
        let m2: MarkerID = 1
        buffer.createMarker(id: m2, atByteOffset: 2, bias: .left)
        let m3: MarkerID = 2
        buffer.createMarker(id: m3, atByteOffset: 5, bias: .right)
        buffer.replaceSubrange(0..<6, with: "")
        #expect(buffer.text.toString() == "")
        #expect(buffer.markers.rankPosition(of: m1) == 0)
        #expect(buffer.markers.rankPosition(of: m2) == 0)
        #expect(buffer.markers.rankPosition(of: m3) == 0)
    }

    /// ```
    /// emacs -Q --batch --eval '
    /// (with-temp-buffer
    ///   (insert "abcdef")
    ///   (let ((m1 (copy-marker 2 nil)) (m2 (copy-marker 2 t)))
    ///     (goto-char 2) (insert "") (delete-region 2 2)
    ///     (message "zero-length-ops type-nil=%d type-t=%d"
    ///              (marker-position m1) (marker-position m2))))'
    /// => zero-length-ops type-nil=2 type-t=2
    /// ```
    @Test("oracle: zero-length-ops")
    func oracleZeroLengthOps() {
        var buffer = BufferSnapshot()
        buffer.replaceSubrange(0..<0, with: "abcdef")
        let mNil: MarkerID = 0
        buffer.createMarker(id: mNil, atByteOffset: 1, bias: .left)
        let mT: MarkerID = 1
        buffer.createMarker(id: mT, atByteOffset: 1, bias: .right)
        buffer.replaceSubrange(1..<1, with: "")
        buffer.replaceSubrange(1..<1, with: "")
        #expect(buffer.text.toString() == "abcdef")
        #expect(buffer.markers.rankPosition(of: mNil) == 1)
        #expect(buffer.markers.rankPosition(of: mT) == 1)
    }

    /// ```
    /// emacs -Q --batch --eval '
    /// (with-temp-buffer
    ///   (insert "aé漢b")
    ///   (let ((m (copy-marker 3 nil)))
    ///     (goto-char 2) (insert "漢")
    ///     (message "multibyte-after charpos=%d bytepos=%d buffer=%S"
    ///              (marker-position m) (position-bytes (marker-position m)) (buffer-string))))'
    /// => multibyte-after charpos=4 bytepos=7 buffer="a漢é漢b"
    /// ```
    /// The shift is the inserted **byte** count (3, for one 3-byte "漢"), not the scalar or
    /// character count (1) — this is the unit `MarkerTree` already uses throughout, and this
    /// row is the one that settles it against the oracle rather than by convention alone.
    @Test("oracle: multibyte-after (the shift unit is bytes)")
    func oracleMultibyteAfter() {
        var buffer = BufferSnapshot()
        buffer.replaceSubrange(0..<0, with: "aé漢b")
        // Marker at 1-based char 3 == "before 漢" == byte offset 3 ("a"=1 byte, "é"=2 bytes).
        let m: MarkerID = 0
        buffer.createMarker(id: m, atByteOffset: 3, bias: .left)
        // Insert "漢" (3 bytes) at 1-based char 2 == byte offset 1 (right after "a").
        buffer.replaceSubrange(1..<1, with: "漢")
        #expect(buffer.text.toString() == "a漢é漢b")
        // 1-based bytepos 7 -> 0-based byte offset 6.
        #expect(buffer.markers.rankPosition(of: m) == 6)
    }

    // MARK: - Structural

    @Test("gaps are never negative and total span equals the last marker's key")
    func gapsNonNegativeAndSpanMatches() throws {
        var tree = MarkerTree()
        for i in 0..<50 {
            tree = tree.inserting(
                byteOffset: i * 3, bias: i % 2 == 0 ? .left : .right, id: MarkerID(i))
        }
        try tree.checkInvariants()
        var lastKey = -1
        for r in 0..<tree.count {
            let key = 2 * tree.position(ofRank: r) + tree.bias(ofRank: r).rank
            #expect(key >= lastKey, "rank \(r): key \(key) precedes previous key \(lastKey)")
            lastKey = key
        }
    }

    @Test(
        "rank ordering is consistent with key parity: .left group before .right group at a shared offset"
    )
    func tieGroupOrdering() throws {
        var tree = MarkerTree()
        // Interleave insertion order deliberately, so a correct answer cannot be an accident
        // of insertion order.
        tree = tree.inserting(byteOffset: 10, bias: .right, id: 1)
        tree = tree.inserting(byteOffset: 10, bias: .left, id: 2)
        tree = tree.inserting(byteOffset: 10, bias: .right, id: 3)
        tree = tree.inserting(byteOffset: 10, bias: .left, id: 4)
        try tree.checkInvariants()
        #expect(tree.count == 4)
        let biases = (0..<4).map { tree.bias(ofRank: $0) }
        // Every .left rank precedes every .right rank.
        let firstRightIndex = biases.firstIndex(of: .right) ?? biases.count
        #expect(biases[0..<firstRightIndex].allSatisfy { $0 == .left })
        #expect(biases[firstRightIndex...].allSatisfy { $0 == .right })
        for r in 0..<4 { #expect(tree.position(ofRank: r) == 10) }
    }

    @Test(
        "a stable collapse preserves id order within a tie group (mutation focus: an unstable partition still gets positions right)"
    )
    func collapsePreservesIDOrderWithinTieGroup() throws {
        // Three .right-bias markers, in id order 10, 20, 30, strictly inside a deleted range
        // at different original offsets -- after the collapse they all tie at `lo`, and a
        // *stable* partition must keep them in that same relative order.
        var tree = MarkerTree(sortedMarkers: [
            (byteOffset: 3, bias: .right, id: 10),
            (byteOffset: 4, bias: .right, id: 20),
            (byteOffset: 5, bias: .right, id: 30),
        ])
        tree = tree.applyEdit(byteRange: 2..<6, insertedLength: 0)
        try tree.checkInvariants()
        #expect(tree.count == 3)
        #expect((0..<3).map { tree.position(ofRank: $0) } == [2, 2, 2])
        #expect((0..<3).map { tree.id(ofRank: $0) } == [10, 20, 30])
    }

    @Test("markers(in:) matches a linear scan over all ranks")
    func markersInRangeMatchesLinearScan() throws {
        var tree = MarkerTree()
        for i in 0..<40 {
            tree = tree.inserting(
                byteOffset: i * 2, bias: i % 3 == 0 ? .right : .left, id: MarkerID(i))
        }
        try tree.checkInvariants()
        let all = (0..<tree.count).map {
            (
                offset: tree.position(ofRank: $0), bias: tree.bias(ofRank: $0),
                id: tree.id(ofRank: $0)
            )
        }
        let range = 10..<50
        let expected = all.filter { $0.offset >= range.lowerBound && $0.offset < range.upperBound }
        let actual = tree.markers(in: range)
        #expect(actual.map(\.id) == expected.map(\.id))
        #expect(actual.map(\.offset) == expected.map(\.offset))
        #expect(actual.map(\.bias) == expected.map(\.bias))
    }

    // These two exist because `markers(in:)`'s existence guard (`MarkerTree.swift:265-268`)
    // is otherwise unobservable: `SumTreeCursor.seek` (`SumTreeCursor.swift:139`)
    // `preconditionFailure`s when its predicate never triggers, and the only other test
    // calling `markers(in:)` (`markersInRangeMatchesLinearScan` above) queries a range that
    // always contains a match, so it would not notice if the guard were deleted.

    @Test("markers(in:) on an empty tree returns [] rather than trapping the cursor seek")
    func markersInRangeOnEmptyTreeReturnsEmpty() throws {
        let tree = MarkerTree()
        #expect(tree.markers(in: 0..<10).isEmpty)
    }

    @Test(
        "markers(in:) on a range entirely past the last marker returns [] rather than trapping the cursor seek"
    )
    func markersInRangePastLastMarkerReturnsEmpty() throws {
        var tree = MarkerTree()
        for i in 0..<5 {
            tree = tree.inserting(byteOffset: i * 2, bias: .left, id: MarkerID(i))
        }
        try tree.checkInvariants()
        #expect(tree.markers(in: 100..<200).isEmpty)
    }

    // This is the exact counterexample the reviewer constructed proving the widened collapse
    // group (`MarkerTree.swift:462-474`'s derivation) is genuinely necessary, not defensive:
    // with the *narrow* group `[2*lo+2, 2*hi+1]`, a `.right`-bias marker already resident at
    // `lo` (key `2*lo+1`) is left in `beforeGroup`, while the newly-collapsed `.left` marker
    // from inside the deleted range gets key `2*lo` -- placing it, in tree order, *after* the
    // resident `.right` marker despite having the smaller key, violating the non-decreasing-
    // key invariant. Every other collapse test in this file uses markers of a single uniform
    // bias, so this mixed-bias-at-the-boundary case is otherwise reachable only by chance
    // through the randomised differential test.
    @Test(
        "a marker already resident at lo with .right bias, mixed with a marker collapsing in with .left bias, does not violate key order (the widened-collapse-group case)"
    )
    func collapseWidenedGroupHandlesMixedBiasAtBoundary() throws {
        var tree = MarkerTree(sortedMarkers: [
            (byteOffset: 2, bias: .right, id: 1),
            (byteOffset: 3, bias: .left, id: 2),
        ])
        tree = tree.applyEdit(byteRange: 2..<6, insertedLength: 0)
        try tree.checkInvariants()
        #expect(tree.count == 2)
        #expect((0..<2).map { tree.position(ofRank: $0) } == [2, 2])
        // The pre-existing .right marker (id 1) must still sort at or after the collapsed
        // .left marker (id 2) at the same offset: key(.left) < key(.right) at a tie.
        #expect(tree.bias(ofRank: 0) == .left)
        #expect(tree.id(ofRank: 0) == 2)
        #expect(tree.bias(ofRank: 1) == .right)
        #expect(tree.id(ofRank: 1) == 1)
    }

    @Test("removing an id at its byte offset removes exactly that marker and rebases the tail")
    func removingRebasesTail() throws {
        var tree = MarkerTree(sortedMarkers: [
            (byteOffset: 5, bias: .left, id: 1),
            (byteOffset: 5, bias: .right, id: 2),
            (byteOffset: 9, bias: .left, id: 3),
        ])
        tree = tree.removing(id: 2, atByteOffset: 5)
        try tree.checkInvariants()
        #expect(tree.count == 2)
        #expect(tree.id(ofRank: 0) == 1)
        #expect(tree.position(ofRank: 0) == 5)
        #expect(tree.id(ofRank: 1) == 3)
        #expect(tree.position(ofRank: 1) == 9)
    }

    // MARK: - Node-visit count (the O(log n) claim's regression test)

    /// A line-for-line replica of `pathCopyEditNode`'s own descent control flow
    /// (`SumTree.swift`), minus the rebuild: scan a node's items/children in order, calling
    /// `predicate` on the running summary after each one, descend into the first one where it
    /// becomes true, and stop. `pathCopyEditNode` has no other way to choose which child to
    /// descend into, so for the same tree and the same monotone predicate this necessarily
    /// follows the same path — but a hand-written replica walking the tree's own structure
    /// would report `height + 1` regardless of what the *real* `pathCopyEditNode` actually
    /// does (every root-to-leaf path in a well-formed `SumTree` has that many nodes on it by
    /// the uniform-leaf-depth invariant alone), so this function's `visits` return value is
    /// not, by itself, evidence about the real code. What ties it to the real code is
    /// `predicateCalls`: `nodeVisitsAreHeightPlusOne` feeds a counting wrapper of the *same*
    /// predicate to the real `SumTree.pathCopyEdit` and asserts the real call count equals
    /// this replica's prediction. Since both this replica's and `pathCopyEditNode`'s predicate
    /// calls happen in the same order-scan-until-true shape, node for node, item for item, an
    /// exact match is only possible if the real code visited the same nodes in the same
    /// order — a regression that visits an extra node, re-checks a sibling, or fans out to a
    /// second child changes the total, and the test fails.
    ///
    /// `preconditionFailure`s if `predicate` never becomes true within `node`, mirroring
    /// `pathCopyEditNode`'s own implicit assumption (a caller of `pathCopyEdit` whose
    /// predicate never triggers gets `nil` back untouched, one level up — this replica has no
    /// such caller, so it traps instead, which is what a test wants from a broken assumption).
    private func countedDescent<Item: Summable>(
        _ node: Node<Item>, prefix: Item.Item_Summary, predicate: (Item.Item_Summary) -> Bool,
        visits: inout Int, predicateCalls: inout Int
    ) {
        visits += 1
        switch node {
        case .leaf(let items, _):
            var cum = prefix
            for item in items {
                let next = cum + item.summary
                predicateCalls += 1
                if predicate(next) { return }
                cum = next
            }
            preconditionFailure("countedDescent: predicate never true within this leaf")
        case .interior(let children, _, _):
            var cum = prefix
            for child in children {
                let next = cum + child.summary
                predicateCalls += 1
                if predicate(next) {
                    countedDescent(
                        child, prefix: cum, predicate: predicate, visits: &visits,
                        predicateCalls: &predicateCalls)
                    return
                }
                cum = next
            }
            preconditionFailure(
                "countedDescent: predicate never true within this interior node")
        }
    }

    /// Reference-type counter for the wrapped predicate below — a `var` captured by a
    /// non-escaping-looking-but-actually-stored closure needs a box, not a local `var`, since
    /// the closure is handed to `SumTree.pathCopyEdit` and called from inside it, not inline.
    private final class CallCounter {
        var count = 0
    }

    /// **The gap this closes.** M1.3's evidence for "adjusting every marker after an edit is
    /// O(log n)" was a *count of node visits* (`pathCopyEditNode` recurses into exactly one
    /// child per level, so a single-item edit visits `height + 1` nodes) taken from
    /// instrumentation in a throwaway git worktree that no longer exists — `PLAN.md`'s M1.3
    /// record says so honestly. The shipped perf test
    /// (`markerTreePerfTests.swift`'s `insertBeforeAllMarkers`) only re-measures *time*,
    /// asserting `mean < 10 us` at 1M against a measured 1.58-1.66 us — about 6x headroom. A
    /// regression that **doubled** the visit count (say, `pathCopyEditNode` fanning out to two
    /// children per level instead of one, the pre-M1.1b `O(B * h^2)` shape `SumTree.swift`'s
    /// file header describes) would roughly double the time to ~3.2 us at 1M and still **pass**
    /// that bound. This test counts visits directly — deterministic, no release build, no
    /// warm-up, no timing noise — so it catches exactly the doubled-constant case the timing
    /// bound cannot, *and* it catches it in the real code, not only in a replica: see
    /// `countedDescent`'s doc comment for why counting a replica's own traversal alone would
    /// not have been enough.
    ///
    /// **Approach: replica plus agreement**, the task brief's first option — but the agreement
    /// checked is against the real function's *call pattern*, not only its final result. A
    /// counting wrapper around exactly `shiftingSingleItem`'s own predicate
    /// (`{ $0.count > 0 && $0.span >= boundary }`, `boundary = 2 * offset + 1` for
    /// `insertBeforeMarkers == false`, `applyEdit`'s default) is passed to the real
    /// `SumTree.pathCopyEdit`, called on `MarkerTree.testOnlySumTree` — the actual tree
    /// `applyEdit` operates on, not a separately built stand-in. The real call count is
    /// asserted equal to `countedDescent`'s prediction for the same tree and predicate; a
    /// result-only agreement check (the edited marker's id and position, via the real
    /// `MarkerTree.applyEdit`) is kept alongside it as a second, independent signal.
    ///
    /// **Holds anywhere in the tree, not only at offset 0.** The investigation this follows up
    /// on reported 20-34 *summary comparisons* (predicate evaluations) for edits at 1/4, 2/4
    /// and 3/4 of the buffer at every size — a different, larger number from the *node-visit*
    /// count `height + 1`, because one node visit can cost more than one predicate call (a
    /// node's own loop checks each item/child in turn until the predicate fires, so an interior
    /// node with up to `2B = 12` children can cost up to 12 predicate calls for one visit).
    /// This test asserts `visits == height + 1` at five positions spanning the tree (start,
    /// 1/4, 1/2, 3/4, and the last marker) at each size, and finds it holds **everywhere
    /// tested** — which follows from `SumTree`'s own structural invariant (uniform leaf depth,
    /// checked by `checkInvariants()`): every root-to-leaf path in a well-formed tree has
    /// exactly `height + 1` nodes on it, regardless of which leaf it ends at. What is *not*
    /// structurally guaranteed, and what the real-call-count check above actually stands guard
    /// over, is that the descent visits only **one** node per level rather than fanning out to
    /// more.
    @Test(
        "node visits for a single-marker-edit descent are height + 1, at five offsets, n = 10^4/10^5/10^6"
    )
    func nodeVisitsAreHeightPlusOne() throws {
        for n in [10_000, 100_000, 1_000_000] {
            var sorted: [(byteOffset: Int, bias: MarkerBias, id: MarkerID)] = []
            sorted.reserveCapacity(n)
            for i in 0..<n {
                let bias: MarkerBias = i % 2 == 0 ? .left : .right
                sorted.append((byteOffset: i * 8, bias: bias, id: MarkerID(i)))
            }
            let tree = MarkerTree(sortedMarkers: sorted)
            let sumTree = tree.testOnlySumTree
            let expectedVisits = Int(sumTree.height) + 1

            // n is even at every size tested here, so the last rank (n - 1, odd index) is
            // always .right bias -- its own key equals `boundary` below, so the predicate is
            // guaranteed to fire on it even at the tree's last item. An odd n would need a
            // different last sample offset to avoid `countedDescent`'s trap.
            let sampleRanks = [0, n / 4, n / 2, (3 * n) / 4, n - 1]
            for rank in sampleRanks {
                let offset = tree.position(ofRank: rank)
                let bias = tree.bias(ofRank: rank)
                let id = tree.id(ofRank: rank)
                let boundary = 2 * offset + 1  // insertBeforeMarkers == false, applyEdit's default
                let predicate: (MarkerSummary) -> Bool = { $0.count > 0 && $0.span >= boundary }

                var visits = 0
                var predicateCalls = 0
                countedDescent(
                    sumTree.root, prefix: .identity, predicate: predicate, visits: &visits,
                    predicateCalls: &predicateCalls)
                let visitMessage =
                    "n=\(n) rank=\(rank) offset=\(offset): descent visited \(visits) nodes, "
                    + "expected height + 1 = \(expectedVisits)"
                #expect(visits == expectedVisits, "\(visitMessage)")

                // Ties the replica's prediction to the real code: the real `pathCopyEdit`
                // (the one `MarkerTree.shiftingSingleItem` calls) is invoked here directly,
                // with a counting wrapper around the identical predicate and an `edit` closure
                // that leaves the leaf's items unchanged (no need to actually edit anything to
                // observe the call count). An `edit` returning the leaf untouched still
                // produces `.ok`, never `.declined`, so `pathCopyEdit` cannot return `nil` here.
                let counter = CallCounter()
                let countingPredicate: (MarkerSummary) -> Bool = { summary in
                    counter.count += 1
                    return predicate(summary)
                }
                let realResult = sumTree.pathCopyEdit(
                    where: countingPredicate, edit: { items, _, _ in items })
                let nilMessage =
                    "n=\(n) rank=\(rank) offset=\(offset): the real pathCopyEdit returned nil "
                    + "for a predicate the replica above proved triggers"
                #expect(realResult != nil, "\(nilMessage)")
                // `pathCopyEdit` itself calls `predicate(.identity)` once, up front, as its own
                // `!predicate(.identity)` precondition check (`SumTree.swift`) -- one call this
                // replica's descent never makes, since it starts scanning from the root's first
                // item/child rather than probing the bare prefix. `+ 1` accounts for exactly
                // that one call, confirmed by running this check before adding the `+ 1`: every
                // sample failed with `counter.count` exactly one over `predicateCalls`, never
                // any other delta -- see this task's report for that raw run.
                let expectedRealCalls = predicateCalls + 1
                let callMessage =
                    "n=\(n) rank=\(rank) offset=\(offset): the real SumTree.pathCopyEdit made "
                    + "\(counter.count) predicate calls, expected \(expectedRealCalls) "
                    + "(replica's \(predicateCalls) node/item-scan calls + 1 for pathCopyEdit's "
                    + "own precondition check) -- a mismatch means the real descent visited a "
                    + "different set of nodes/items than height + 1 accounts for"
                #expect(counter.count == expectedRealCalls, "\(callMessage)")

                let edited = tree.applyEdit(byteRange: offset..<offset, insertedLength: 1)
                #expect(edited.id(ofRank: rank) == id)
                let expectedOffset = bias == .right ? offset + 1 : offset
                let editMessage =
                    "n=\(n) rank=\(rank) offset=\(offset) bias=\(bias): applyEdit produced "
                    + "\(edited.position(ofRank: rank)), expected \(expectedOffset)"
                #expect(edited.position(ofRank: rank) == expectedOffset, "\(editMessage)")
            }
        }
    }

    // MARK: - Differential property test

    /// The reference model: a plain array, applying the same rules `MarkerTree.applyEdit`
    /// does (`MarkerTree.swift`'s two-stage composition), directly against offsets rather
    /// than gap-encoded keys. Independent of `MarkerTree`'s implementation -- it does not
    /// call into `Text` at all -- so an agreement between the two is real evidence, not a
    /// tautology.
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

    /// `MarkerTree` has no coordinate system of its own (no text), so scalar-boundary drawing
    /// (as `Rope`-backed randomised tests in this module do) is not meaningful at this layer
    /// -- byte offsets here are plain integers over an abstract, unbounded-length buffer, not
    /// positions into real UTF-8 text. The oracle tests above (`oracleMultibyteAfter` in
    /// particular) already exercise the pairing against a real, multibyte-capable `Rope` via
    /// `BufferSnapshot`; this test's job is `applyEdit`'s own correctness at volume.
    ///
    /// **20,000 operations here, not `dev/specs/m1.3.md` section 4's "at least 1,000,000"** —
    /// found to be impractical in a debug build: even with both axes bounded (see below), a
    /// million-operation run of this test was killed after 12+ minutes of CPU time still not
    /// finished. **That was not generic debug-build slowness** (the attribution an earlier
    /// version of this comment made): the generator's insertion/deletion sizes were
    /// unbalanced (deletion width up to 64 bytes, insertion length up to 7), so a run of any
    /// length drifted the buffer down to an equilibrium of a handful of bytes and kept nearly
    /// every one of `maxMarkers` markers packed into that tiny span — meaning almost every
    /// deleting edit collapsed on the order of `maxMarkers` markers, each an O(k) operation
    /// (`MarkerTree.swift`'s `applyDeleteAndCollapse` doc comment), for a run cost closer to
    /// O(operationCount * maxMarkers) than the O(operationCount * log n) a healthy random
    /// walk gives. The generator below now draws insertion length from the same range as
    /// deletion width so the walk does not degenerate; a debug build of 1,000,000 balanced
    /// operations is still slow enough (`swift test` always builds `-Onone`, per `CLAUDE.md`'s
    /// "How to measure") that the split below stands, just for the ordinary reason.
    /// `millionEditDifferentialPerf` in `markerTreePerfTests.swift` carries the full
    /// 1,000,000-operation run, gated behind `PELLICLE_PERF=1 swift test -c release` exactly
    /// like every other number this milestone's perf claims depend on — this split mirrors
    /// `ropePerfTests.swift`'s own `millionOperationsSmallRope`, which is also perf-gated
    /// rather than part of the plain suite. This is a scope narrowing from the spec's literal
    /// instruction, flagged here and in the implementer's report rather than silently
    /// reducing "1,000,000" everywhere.
    @Test("differential: 20,000 random edits against a naive per-marker model")
    func manyEditDifferential() {
        let seed: UInt64 = 0xFEED_C0DE_1234
        var rng = SplitMix64(seed: seed)
        var model: [ModelMarker] = []
        var tree = MarkerTree()
        var nextID: MarkerID = 0
        var bufferLength = 0
        let operationCount = 20_000
        let checkEvery = 200

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

        // Both axes are bounded (mirroring `ropePerfTests.swift`'s own bounded random walk —
        // see `runModelProperty`'s doc comment there for why an *unbounded* walk is the wrong
        // shape for a fixed operation count): without a cap, marker creation (2/5 of ops)
        // outpaces removal (1/5) and net buffer growth is similarly one-sided, so by the
        // millionth operation both the live marker count and the buffer length would have
        // drifted to a size that makes every single op — and every `checkEvery`-cadence
        // O(m) comparison against the model — expensive enough that 1,000,000 iterations
        // does not finish in a debug build in reasonable time. The cap keeps each operation's
        // cost close to flat across the whole run, which is what lets this test actually
        // reach 1,000,000 operations rather than asserting a much smaller number instead.
        let maxMarkers = 2_000
        let maxBufferLength = 8_192
        // Insertion length is drawn from the *same* range as deletion width (both up to 64
        // bytes), not the narrower `0..<8` an earlier version of this generator used. That
        // earlier asymmetry (expected width ~32 once the buffer exceeds 64 bytes, against
        // expected insertion ~3.5) made the buffer's expected change per edit about -28.5
        // bytes, so the walk collapsed to an equilibrium in the low tens of bytes almost
        // immediately and stayed there — packing nearly all `maxMarkers` live markers into a
        // handful of bytes for essentially the whole run, which is not the shape
        // `dev/specs/m1.3.md` section 4 asks this test to exercise. `bufferLengthSamples`
        // below and the assertions after the loop are what make a regression back to that
        // degenerate shape a test failure instead of a silent drift.
        let insertLengthCap = 64
        var bufferLengthSamples: [Int] = []
        bufferLengthSamples.reserveCapacity(operationCount)

        for opIndex in 0..<operationCount {
            let kind = rng.next() % 5
            switch kind {
            case 0, 1:
                // Create a marker at a random offset, unless already at the population cap.
                guard model.count < maxMarkers else { break }
                let offset = Int(rng.next() % UInt64(bufferLength + 1))
                let bias: MarkerBias = rng.next() % 2 == 0 ? .left : .right
                let id = nextID
                nextID += 1
                model.append(ModelMarker(offset: offset, bias: bias, id: id))
                tree = tree.inserting(byteOffset: offset, bias: bias, id: id)
            case 2:
                // Remove a random existing marker, if any.
                if !model.isEmpty {
                    let idx = Int(rng.next() % UInt64(model.count))
                    let removed = model.remove(at: idx)
                    tree = tree.removing(id: removed.id, atByteOffset: removed.offset)
                }
            default:
                // Apply a random edit: insert, delete, or replace.
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
        do {
            try tree.checkInvariants()
        } catch {
            Issue.record("seed \(seed): final invariant violation \(error)")
        }
        compare(operationCount)

        // The workload's health, checked rather than only fixed: a regression back to the
        // unbalanced draw above would silently repack every live marker into a handful of
        // bytes again with nothing here to notice. `bufferLengthSamples`' median is a robust
        // summary of where the walk actually spent its time (unlike the final value alone,
        // which is one sample of a random walk and noisy on its own); the marker span is the
        // direct check that markers themselves are not all packed together.
        bufferLengthSamples.sort()
        let medianBufferLength = bufferLengthSamples[bufferLengthSamples.count / 2]
        // Upper half tightened from the original `< maxBufferLength` (fix round 4): that
        // form was near-tautological, since `bufferLength` is clamped so it can never exceed
        // `maxBufferLength` in the first place -- the median could only fail it by pegging
        // exactly at the cap, and a walk that saturates a few bytes under the cap and
        // oscillates in a narrow band there would sail through. `9 * maxBufferLength / 10`
        // is a real ceiling: reaching it needs the median sample to sit above 90% of the cap.
        // Verified this can fail: with deletion width capped at `min(4, bufferLength - lo)`
        // while insertion stayed at up to 64 bytes (insertions dominating, the degenerate
        // mode this half exists to catch), a self-check run of this generator measured
        // median 8180 against an 8192 cap -- above this tightened ceiling (7372) though not
        // the original untightened one.
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
        // Spread (fix round 4, added alongside the tightened median ceiling above): the
        // median alone cannot distinguish a walk that ranges broadly across the band from
        // one that clusters tightly near a single value inside it -- a walk pegged just
        // under the 90%-of-cap line above would still pass the median check. The 10th/90th
        // percentiles bracket where the middle 80% of samples actually fell; requiring a
        // real gap between them is the check that the walk visits a wide range of buffer
        // lengths, not a narrow one. Verified this can fail on the same self-check run as
        // above: spread there was 21 bytes (p10 8168, p90 8189) against a healthy run's 4649
        // (p10 1368, p90 6017, `maxBufferLength` 8192).
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

extension MarkerTree {
    /// Test-only convenience: the current byte offset/bias of the marker `id`, found by a
    /// linear scan over ranks. `internal`, not `private`: used only from
    /// `@testable import Text` test files, which need a way to look a marker up by id without
    /// `MarkerTree`'s public API growing an id-indexed lookup this milestone deliberately does
    /// not build (`dev/specs/m1.3.md` section 3: resolving by identity is out of scope until
    /// M5's `Anchor`).
    func rankPosition(of id: MarkerID) -> Int? {
        for r in 0..<count where self.id(ofRank: r) == id {
            return position(ofRank: r)
        }
        return nil
    }

    func rankBias(of id: MarkerID) -> MarkerBias? {
        for r in 0..<count where self.id(ofRank: r) == id {
            return bias(ofRank: r)
        }
        return nil
    }
}
