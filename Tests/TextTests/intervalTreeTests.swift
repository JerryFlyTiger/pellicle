import Testing

@testable import Text

/// Covers `IntervalTree` and its `BufferSnapshot` wiring (M1.4, `dev/specs/m1.4.md`).
///
/// **Positions transfer, numbers do not** — the same convention `markerTreeTests.swift`
/// documents: GNU Emacs positions are 1-based **character** positions; this project's are
/// 0-based **byte** offsets. Every oracle transcript below is quoted verbatim from GNU Emacs
/// 30.2 (`/opt/homebrew/bin/emacs -Q --batch`), and each expectation converts the 1-based GNU
/// position to a 0-based byte offset explicitly at the call site (`position - 1`, since every
/// buffer used here is pure ASCII, one byte per character).
@Suite("IntervalTree")
struct IntervalTreeTests {

    // MARK: - Oracle-backed conformance

    /// One row of the endpoint-rule oracle: a `(frontAdvance, rearAdvance)` combination, the
    /// 1-based position an edit lands at, and the overlay's 1-based `(start, end)` afterward.
    private struct FlagRow {
        let frontAdvance: Bool
        let rearAdvance: Bool
        let position: Int
        let expectedStart: Int
        let expectedEnd: Int
    }

    /// Builds a fresh 10-byte ASCII buffer ("0123456789") with one interval spanning 1-based
    /// `(3, 7)` (0-based byte range `2..<6`) with the given advance flags, and returns the
    /// buffer plus the interval's id.
    private func buildOverlayFixture(
        frontAdvance: Bool, rearAdvance: Bool
    ) -> (buffer: BufferSnapshot, id: IntervalID) {
        var buffer = BufferSnapshot()
        buffer.replaceSubrange(0..<0, with: "0123456789")
        let id = buffer.createInterval(
            byteRange: 2..<6, frontAdvance: frontAdvance, rearAdvance: rearAdvance)
        return (buffer, id)
    }

    /// ```
    /// emacs -Q --batch --eval '
    /// (dolist (fa (list nil t))
    ///   (dolist (ra (list nil t))
    ///     (dolist (pos (list 3 5 7))
    ///       (with-temp-buffer
    ///         (insert "0123456789")
    ///         (let ((ov (make-overlay 3 7 nil fa ra)))
    ///           (goto-char pos) (insert "X")
    ///           (message "fa=%S ra=%S pos=%d -> (%d,%d)" fa ra pos
    ///                    (overlay-start ov) (overlay-end ov)))))))'
    /// =>
    /// fa=nil ra=nil pos=3 -> (3,8)     fa=nil ra=nil pos=5 -> (3,8)     fa=nil ra=nil pos=7 -> (3,7)
    /// fa=nil ra=t   pos=3 -> (3,8)     fa=nil ra=t   pos=5 -> (3,8)     fa=nil ra=t   pos=7 -> (3,8)
    /// fa=t   ra=nil pos=3 -> (4,8)     fa=t   ra=nil pos=5 -> (3,8)     fa=t   ra=nil pos=7 -> (3,7)
    /// fa=t   ra=t   pos=3 -> (4,8)     fa=t   ra=t   pos=5 -> (3,8)     fa=t   ra=t   pos=7 -> (3,8)
    /// ```
    @Test(
        "oracle: insert 1 byte at start/middle/end of the overlay, all four advance-flag combinations"
    )
    func oracleInsertAtBoundaries() {
        let rows: [FlagRow] = [
            FlagRow(
                frontAdvance: false, rearAdvance: false, position: 3, expectedStart: 3,
                expectedEnd: 8),
            FlagRow(
                frontAdvance: false, rearAdvance: false, position: 5, expectedStart: 3,
                expectedEnd: 8),
            FlagRow(
                frontAdvance: false, rearAdvance: false, position: 7, expectedStart: 3,
                expectedEnd: 7),
            FlagRow(
                frontAdvance: false, rearAdvance: true, position: 3, expectedStart: 3,
                expectedEnd: 8),
            FlagRow(
                frontAdvance: false, rearAdvance: true, position: 5, expectedStart: 3,
                expectedEnd: 8),
            FlagRow(
                frontAdvance: false, rearAdvance: true, position: 7, expectedStart: 3,
                expectedEnd: 8),
            FlagRow(
                frontAdvance: true, rearAdvance: false, position: 3, expectedStart: 4,
                expectedEnd: 8),
            FlagRow(
                frontAdvance: true, rearAdvance: false, position: 5, expectedStart: 3,
                expectedEnd: 8),
            FlagRow(
                frontAdvance: true, rearAdvance: false, position: 7, expectedStart: 3,
                expectedEnd: 7),
            FlagRow(
                frontAdvance: true, rearAdvance: true, position: 3, expectedStart: 4, expectedEnd: 8
            ),
            FlagRow(
                frontAdvance: true, rearAdvance: true, position: 5, expectedStart: 3, expectedEnd: 8
            ),
            FlagRow(
                frontAdvance: true, rearAdvance: true, position: 7, expectedStart: 3, expectedEnd: 8
            ),
        ]
        for row in rows {
            var (buffer, id) = buildOverlayFixture(
                frontAdvance: row.frontAdvance, rearAdvance: row.rearAdvance)
            let insertAt = row.position - 1
            buffer.replaceSubrange(insertAt..<insertAt, with: "X")
            let span = buffer.intervals.rankSpan(of: id)
            #expect(
                span?.range == (row.expectedStart - 1)..<(row.expectedEnd - 1),
                "fa=\(row.frontAdvance) ra=\(row.rearAdvance) pos=\(row.position)")
        }
    }

    /// ```
    /// emacs -Q --batch --eval '
    /// (dolist (fa (list nil t))
    ///   (dolist (ra (list nil t))
    ///     (dolist (pos (list 3 5 7))
    ///       (with-temp-buffer
    ///         (insert "0123456789")
    ///         (let ((ov (make-overlay 3 7 nil fa ra)))
    ///           (goto-char pos) (insert "XYZ")
    ///           (message "L3 fa=%S ra=%S pos=%d -> (%d,%d)" fa ra pos
    ///                    (overlay-start ov) (overlay-end ov)))))))'
    /// =>
    /// L3 fa=nil ra=nil pos=3 -> (3,10)   L3 fa=nil ra=nil pos=5 -> (3,10)   L3 fa=nil ra=nil pos=7 -> (3,7)
    /// L3 fa=nil ra=t   pos=3 -> (3,10)   L3 fa=nil ra=t   pos=5 -> (3,10)   L3 fa=nil ra=t   pos=7 -> (3,10)
    /// L3 fa=t   ra=nil pos=3 -> (6,10)   L3 fa=t   ra=nil pos=5 -> (3,10)   L3 fa=t   ra=nil pos=7 -> (3,7)
    /// L3 fa=t   ra=t   pos=3 -> (6,10)   L3 fa=t   ra=t   pos=5 -> (3,10)   L3 fa=t   ra=t   pos=7 -> (3,10)
    /// ```
    /// Same shape as `oracleInsertAtBoundaries`, with `L = 3` — so no rule accidentally
    /// hardcodes `L = 1`.
    @Test(
        "oracle: insert 3 bytes at start/middle/end of the overlay, all four advance-flag combinations"
    )
    func oracleInsertMultiByte() {
        let rows: [FlagRow] = [
            FlagRow(
                frontAdvance: false, rearAdvance: false, position: 3, expectedStart: 3,
                expectedEnd: 10),
            FlagRow(
                frontAdvance: false, rearAdvance: false, position: 5, expectedStart: 3,
                expectedEnd: 10),
            FlagRow(
                frontAdvance: false, rearAdvance: false, position: 7, expectedStart: 3,
                expectedEnd: 7),
            FlagRow(
                frontAdvance: false, rearAdvance: true, position: 3, expectedStart: 3,
                expectedEnd: 10),
            FlagRow(
                frontAdvance: false, rearAdvance: true, position: 5, expectedStart: 3,
                expectedEnd: 10),
            FlagRow(
                frontAdvance: false, rearAdvance: true, position: 7, expectedStart: 3,
                expectedEnd: 10),
            FlagRow(
                frontAdvance: true, rearAdvance: false, position: 3, expectedStart: 6,
                expectedEnd: 10),
            FlagRow(
                frontAdvance: true, rearAdvance: false, position: 5, expectedStart: 3,
                expectedEnd: 10),
            FlagRow(
                frontAdvance: true, rearAdvance: false, position: 7, expectedStart: 3,
                expectedEnd: 7),
            FlagRow(
                frontAdvance: true, rearAdvance: true, position: 3, expectedStart: 6,
                expectedEnd: 10),
            FlagRow(
                frontAdvance: true, rearAdvance: true, position: 5, expectedStart: 3,
                expectedEnd: 10),
            FlagRow(
                frontAdvance: true, rearAdvance: true, position: 7, expectedStart: 3,
                expectedEnd: 10),
        ]
        for row in rows {
            var (buffer, id) = buildOverlayFixture(
                frontAdvance: row.frontAdvance, rearAdvance: row.rearAdvance)
            let insertAt = row.position - 1
            buffer.replaceSubrange(insertAt..<insertAt, with: "XYZ")
            let span = buffer.intervals.rankSpan(of: id)
            #expect(
                span?.range == (row.expectedStart - 1)..<(row.expectedEnd - 1),
                "L3 fa=\(row.frontAdvance) ra=\(row.rearAdvance) pos=\(row.position)")
        }
    }

    /// ```
    /// emacs -Q --batch --eval '
    /// (dolist (fa (list nil t))
    ///   (dolist (ra (list nil t))
    ///     (dolist (pos (list 3 5 7))
    ///       (with-temp-buffer
    ///         (insert "0123456789")
    ///         (let ((ov (make-overlay 3 7 nil fa ra)))
    ///           (goto-char pos) (insert-before-markers "X")
    ///           (message "ibm fa=%S ra=%S pos=%d -> (%d,%d)" fa ra pos
    ///                    (overlay-start ov) (overlay-end ov)))))))'
    /// =>
    /// ibm fa=nil ra=nil pos=3 -> (4,8)   ibm fa=nil ra=nil pos=5 -> (3,8)   ibm fa=nil ra=nil pos=7 -> (3,8)
    /// ibm fa=nil ra=t   pos=3 -> (4,8)   ibm fa=nil ra=t   pos=5 -> (3,8)   ibm fa=nil ra=t   pos=7 -> (3,8)
    /// ibm fa=t   ra=nil pos=3 -> (4,8)   ibm fa=t   ra=nil pos=5 -> (3,8)   ibm fa=t   ra=nil pos=7 -> (3,8)
    /// ibm fa=t   ra=t   pos=3 -> (4,8)   ibm fa=t   ra=t   pos=5 -> (3,8)   ibm fa=t   ra=t   pos=7 -> (3,8)
    /// ```
    /// Every one of these twelve rows differs from the plain-insert row at the same
    /// `(fa, ra, pos)` in `oracleInsertAtBoundaries` — `insert-before-markers` overrides both
    /// flags, not just the one whose endpoint it names. Plus the four empty-overlay rows below
    /// (`oracleEmptyIntervalInsertClamp`'s fixture, under `insertBeforeMarkers: true`):
    /// ```
    /// emacs -Q --batch --eval '
    /// (dolist (fa (list nil t))
    ///   (dolist (ra (list nil t))
    ///     (with-temp-buffer
    ///       (insert "0123456789")
    ///       (let ((ov (make-overlay 5 5 nil fa ra)))
    ///         (goto-char 5) (insert-before-markers "X")
    ///         (message "empty-ibm fa=%S ra=%S -> (%d,%d)" fa ra
    ///                  (overlay-start ov) (overlay-end ov))))))'
    /// => empty-ibm fa=nil ra=nil -> (6,6)   empty-ibm fa=nil ra=t -> (6,6)
    ///    empty-ibm fa=t   ra=nil -> (6,6)   empty-ibm fa=t   ra=t -> (6,6)
    /// ```
    @Test("oracle: insert-before-markers overrides both advance flags at every endpoint")
    func oracleInsertBeforeMarkersOverridesBothFlags() {
        let rows: [FlagRow] = [
            FlagRow(
                frontAdvance: false, rearAdvance: false, position: 3, expectedStart: 4,
                expectedEnd: 8),
            FlagRow(
                frontAdvance: false, rearAdvance: false, position: 5, expectedStart: 3,
                expectedEnd: 8),
            FlagRow(
                frontAdvance: false, rearAdvance: false, position: 7, expectedStart: 3,
                expectedEnd: 8),
            FlagRow(
                frontAdvance: false, rearAdvance: true, position: 3, expectedStart: 4,
                expectedEnd: 8),
            FlagRow(
                frontAdvance: false, rearAdvance: true, position: 5, expectedStart: 3,
                expectedEnd: 8),
            FlagRow(
                frontAdvance: false, rearAdvance: true, position: 7, expectedStart: 3,
                expectedEnd: 8),
            FlagRow(
                frontAdvance: true, rearAdvance: false, position: 3, expectedStart: 4,
                expectedEnd: 8),
            FlagRow(
                frontAdvance: true, rearAdvance: false, position: 5, expectedStart: 3,
                expectedEnd: 8),
            FlagRow(
                frontAdvance: true, rearAdvance: false, position: 7, expectedStart: 3,
                expectedEnd: 8),
            FlagRow(
                frontAdvance: true, rearAdvance: true, position: 3, expectedStart: 4, expectedEnd: 8
            ),
            FlagRow(
                frontAdvance: true, rearAdvance: true, position: 5, expectedStart: 3, expectedEnd: 8
            ),
            FlagRow(
                frontAdvance: true, rearAdvance: true, position: 7, expectedStart: 3, expectedEnd: 8
            ),
        ]
        for row in rows {
            var (buffer, id) = buildOverlayFixture(
                frontAdvance: row.frontAdvance, rearAdvance: row.rearAdvance)
            let insertAt = row.position - 1
            buffer.replaceSubrange(insertAt..<insertAt, with: "X", insertBeforeMarkers: true)
            let span = buffer.intervals.rankSpan(of: id)
            #expect(
                span?.range == (row.expectedStart - 1)..<(row.expectedEnd - 1),
                "ibm fa=\(row.frontAdvance) ra=\(row.rearAdvance) pos=\(row.position)")
        }

        // The four empty-overlay rows: insertBeforeMarkers makes every combination (6,6).
        for fa in [false, true] {
            for ra in [false, true] {
                var buffer = BufferSnapshot()
                buffer.replaceSubrange(0..<0, with: "0123456789")
                let id = buffer.createInterval(byteRange: 4..<4, frontAdvance: fa, rearAdvance: ra)
                buffer.replaceSubrange(4..<4, with: "X", insertBeforeMarkers: true)
                let span = buffer.intervals.rankSpan(of: id)
                #expect(span?.range == 5..<5, "empty-ibm fa=\(fa) ra=\(ra)")
            }
        }
    }

    /// ```
    /// emacs -Q --batch --eval '
    /// (dolist (fa (list nil t))
    ///   (dolist (ra (list nil t))
    ///     (with-temp-buffer
    ///       (insert "0123456789")
    ///       (let ((ov (make-overlay 5 5 nil fa ra)))
    ///         (goto-char 5) (insert "X")
    ///         (message "empty-plain fa=%S ra=%S -> (%d,%d)" fa ra
    ///                  (overlay-start ov) (overlay-end ov))))))'
    /// => empty-plain fa=nil ra=nil -> (5,5)   empty-plain fa=nil ra=t -> (5,6)
    ///    empty-plain fa=t   ra=nil -> (5,5)   empty-plain fa=t   ra=t -> (6,6)
    /// ```
    /// `(fa=t, ra=nil)` is the row that needs the clamp: the per-endpoint rule alone would
    /// give `(6,5)`, an inverted interval; GNU (and this tree, via `startMoves`'s third
    /// conjunct) clamps it to `(5,5)`.
    @Test(
        "oracle: the empty-interval-at-the-insertion-point clamp, all four advance-flag combinations"
    )
    func oracleEmptyIntervalInsertClamp() {
        let rows: [(fa: Bool, ra: Bool, expectedStart: Int, expectedEnd: Int)] = [
            (false, false, 5, 5),
            (false, true, 5, 6),
            (true, false, 5, 5),
            (true, true, 6, 6),
        ]
        for row in rows {
            var buffer = BufferSnapshot()
            buffer.replaceSubrange(0..<0, with: "0123456789")
            let id = buffer.createInterval(
                byteRange: 4..<4, frontAdvance: row.fa, rearAdvance: row.ra)
            buffer.replaceSubrange(4..<4, with: "X")
            let span = buffer.intervals.rankSpan(of: id)
            #expect(
                span?.range == (row.expectedStart - 1)..<(row.expectedEnd - 1),
                "empty-plain fa=\(row.fa) ra=\(row.ra)")
        }
    }

    /// ```
    /// emacs -Q --batch --eval '
    /// (dolist (fa (list nil t))
    ///   (dolist (ra (list nil t))
    ///     (dolist (range (list (cons 1 3) (cons 2 5) (cons 2 9) (cons 4 6) (cons 8 10)))
    ///       (with-temp-buffer
    ///         (insert "0123456789")
    ///         (let ((ov (make-overlay 3 7 nil fa ra)))
    ///           (delete-region (car range) (cdr range))
    ///           (message "del fa=%S ra=%S range=%S -> (%d,%d)" fa ra range
    ///                    (overlay-start ov) (overlay-end ov)))))))'
    /// =>
    /// range (1.3) -> (1,5) for all 4 flag combos      range (2.5) -> (2,4) for all 4
    /// range (2.9) -> (2,2) for all 4                   range (4.6) -> (3,5) for all 4
    /// range (8.10) -> (3,7) for all 4
    /// ```
    /// Twenty rows (five shapes x four flag combinations); the results are identical across
    /// every flag combination at a given shape, which this test asserts directly rather than
    /// only checking the numbers.
    @Test("oracle: deletion adjusts an overlay independent of both advance flags, five shapes")
    func oracleDeletionIsFlagIndependent() throws {
        // (deleteRange 1-based, expectedRange 1-based)
        let shapes: [(delete: Range<Int>, expected: Range<Int>)] = [
            (1..<3, 1..<5),
            (2..<5, 2..<4),
            (2..<9, 2..<2),
            (4..<6, 3..<5),
            (8..<10, 3..<7),
        ]
        for shape in shapes {
            var results: [Range<Int>] = []
            for fa in [false, true] {
                for ra in [false, true] {
                    var (buffer, id) = buildOverlayFixture(frontAdvance: fa, rearAdvance: ra)
                    let delete = (shape.delete.lowerBound - 1)..<(shape.delete.upperBound - 1)
                    buffer.replaceSubrange(delete, with: "")
                    let span = buffer.intervals.rankSpan(of: id)
                    let range = try #require(span).range
                    results.append(range)
                    #expect(
                        range == (shape.expected.lowerBound - 1)..<(shape.expected.upperBound - 1),
                        "del fa=\(fa) ra=\(ra) range=\(shape.delete)")
                }
            }
            #expect(Set(results).count == 1, "del range=\(shape.delete): flag-independence failed")
        }
    }

    /// From `oracleDeletionIsFlagIndependent`'s `(2,9)` row: deleting `[2,9)` (1-based) empties
    /// overlay `(3,7)` to `(2,2)` (0-based) — `overlay-buffer` stays non-nil in GNU (there is
    /// no such concept here; this tree simply keeps the interval, `start == end`), not removed.
    @Test("oracle: an interval the deletion empties stays in the tree with start == end")
    func oracleDeletionKeepsEmptiedIntervals() {
        var (buffer, id) = buildOverlayFixture(frontAdvance: false, rearAdvance: false)
        buffer.replaceSubrange(1..<8, with: "")
        #expect(buffer.intervals.count == 1)
        let span = buffer.intervals.rankSpan(of: id)
        #expect(span?.range == 1..<1)
        #expect(span?.range.isEmpty == true)
    }

    /// The M1.3 refutation re-run for intervals: a replace is delete-then-insert, never one
    /// fused delta. Three shapes, four flag combinations each (twelve rows).
    ///
    /// ```
    /// emacs -Q --batch --eval '
    /// (dolist (fa (list nil t)) (dolist (ra (list nil t))
    ///   (with-temp-buffer (insert "0123456789")
    ///     (let ((ov (make-overlay 3 7 nil fa ra)))
    ///       (goto-char 3) (delete-region 3 7) (insert "XY")
    ///       (message "replaceB fa=%S ra=%S -> (%d,%d)" fa ra (overlay-start ov) (overlay-end ov))))))'
    /// => replaceB fa=nil ra=nil -> (3,3)   replaceB fa=nil ra=t -> (3,5)
    ///    replaceB fa=t   ra=nil -> (3,3)   replaceB fa=t   ra=t -> (5,5)
    ///
    /// emacs -Q --batch --eval '
    /// (dolist (fa (list nil t)) (dolist (ra (list nil t))
    ///   (with-temp-buffer (insert "0123456789")
    ///     (let ((ov (make-overlay 3 7 nil fa ra)))
    ///       (goto-char 2) (delete-region 2 5) (insert "XYZ")
    ///       (message "replaceC fa=%S ra=%S -> (%d,%d)" fa ra (overlay-start ov) (overlay-end ov))))))'
    /// => replaceC fa=nil ra=nil -> (2,7)   replaceC fa=nil ra=t -> (2,7)
    ///    replaceC fa=t   ra=nil -> (5,7)   replaceC fa=t   ra=t -> (5,7)
    ///
    /// emacs -Q --batch --eval '
    /// (dolist (fa (list nil t)) (dolist (ra (list nil t))
    ///   (with-temp-buffer (insert "0123456789")
    ///     (let ((ov (make-overlay 3 7 nil fa ra)))
    ///       (goto-char 8) (delete-region 8 10) (insert "X")
    ///       (message "replaceD fa=%S ra=%S -> (%d,%d)" fa ra (overlay-start ov) (overlay-end ov))))))'
    /// => replaceD fa=nil ra=nil -> (3,7)   replaceD fa=nil ra=t -> (3,7)
    ///    replaceD fa=t   ra=nil -> (3,7)   replaceD fa=t   ra=t -> (3,7)
    /// ```
    @Test("oracle: replace is delete-then-insert, three shapes x four advance-flag combinations")
    func oracleReplaceIsDeleteThenInsert() {
        struct ReplaceRow {
            let delete: Range<Int>  // 1-based
            let insertText: String
            let expectedStart: [Bool: [Bool: Int]]
            let expectedEnd: [Bool: [Bool: Int]]
        }
        let cases:
            [(
                name: String, delete: Range<Int>, insertText: String,
                results: [(Bool, Bool, Int, Int)]
            )] =
                [
                    (
                        "replaceB", 3..<7, "XY",
                        [
                            (false, false, 3, 3), (false, true, 3, 5), (true, false, 3, 3),
                            (true, true, 5, 5),
                        ]
                    ),
                    (
                        "replaceC", 2..<5, "XYZ",
                        [
                            (false, false, 2, 7), (false, true, 2, 7), (true, false, 5, 7),
                            (true, true, 5, 7),
                        ]
                    ),
                    (
                        "replaceD", 8..<10, "X",
                        [
                            (false, false, 3, 7), (false, true, 3, 7), (true, false, 3, 7),
                            (true, true, 3, 7),
                        ]
                    ),
                ]
        for testCase in cases {
            for (fa, ra, expectedStart, expectedEnd) in testCase.results {
                var (buffer, id) = buildOverlayFixture(frontAdvance: fa, rearAdvance: ra)
                let delete = (testCase.delete.lowerBound - 1)..<(testCase.delete.upperBound - 1)
                buffer.replaceSubrange(delete, with: testCase.insertText)
                let span = buffer.intervals.rankSpan(of: id)
                #expect(
                    span?.range == (expectedStart - 1)..<(expectedEnd - 1),
                    "\(testCase.name) fa=\(fa) ra=\(ra)")
            }
        }
    }

    /// Builds the five-overlay fixture of `dev/specs/m1.4.md` 1.7 directly (not through
    /// `BufferSnapshot`): buffer `"0123456789"` (10 bytes, `bufferEnd = 10`), overlays
    /// `A(3,7) B(5,5) C(3,3) D(11,11) E(7,7)` (1-based), converted to 0-based `A(2,6) B(4,4)
    /// C(2,2) D(10,10) E(6,6)`. `A` and `C` share start `2`; `tieOrder` picks which comes
    /// first in the underlying tree, and both orders must give the same query results (1.3:
    /// no query depends on tie order) — this is also mutation 6's load-bearing case (see this
    /// suite's `maxEndInvariantIsChecked` and the mutation notes in `dev/specs/m1.4.md`
    /// section 6, item 6).
    private func buildFiveOverlayFixture(tieOrder: [String]) -> (
        tree: IntervalTree, ids: [String: IntervalID]
    ) {
        // 0-based ranges, keyed by name.
        let ranges: [String: Range<Int>] = [
            "A": 2..<6, "B": 4..<4, "C": 2..<2, "D": 10..<10, "E": 6..<6,
        ]
        let ids: [String: IntervalID] = ["A": 0, "B": 1, "C": 2, "D": 3, "E": 4]
        // Non-decreasing-start order: A/C tie at 2 (order given by `tieOrder`), then B(4),
        // E(6), D(10).
        var order = tieOrder + ["B", "E", "D"]
        precondition(Set(order) == Set(ranges.keys), "buildFiveOverlayFixture: incomplete order")
        let sorted = order.map {
            (range: ranges[$0]!, id: ids[$0]!, frontAdvance: false, rearAdvance: false)
        }
        order = []  // silence "never mutated" if the compiler complains; order is read above
        return (IntervalTree(sortedIntervals: sorted), ids)
    }

    /// ```
    /// emacs -Q --batch --eval '
    /// (with-temp-buffer (insert "0123456789")
    ///   (let* ((a (make-overlay 3 7)) (b (make-overlay 5 5)) (c (make-overlay 3 3))
    ///          (d (make-overlay 11 11)) (e (make-overlay 7 7)))
    ///     (overlay-put a (quote name) "A") (overlay-put b (quote name) "B")
    ///     (overlay-put c (quote name) "C") (overlay-put d (quote name) "D")
    ///     (overlay-put e (quote name) "E")
    ///     (dolist (r (list (cons 5 5) (cons 3 3) (cons 7 7) (cons 11 11) (cons 3 7)
    ///                       (cons 5 6) (cons 1 11)))
    ///       (message "overlays-in %S -> %S" r
    ///                (sort (mapcar (lambda (o) (overlay-get o (quote name)))
    ///                               (overlays-in (car r) (cdr r))) (function string<)))))))'
    /// =>
    /// overlays-in (5 . 5) -> ("A" "B")      overlays-in (3 . 3) -> ("C")
    /// overlays-in (7 . 7) -> ("E")          overlays-in (11 . 11) -> ("D")
    /// overlays-in (3 . 7) -> ("A" "B" "C")  overlays-in (5 . 6) -> ("A" "B")
    /// overlays-in (1 . 11) -> ("A" "B" "C" "D" "E")
    /// ```
    /// The `(5,5)` row refutes `overlays-in`'s own docstring ("at least one character
    /// contained within the overlay and also contained within the specified region"): `A`, a
    /// **non-empty** overlay, is returned for a region containing no character. `(3,3)` keeps
    /// the rule honest in the other direction: `A` is *not* returned there (`start < hi`
    /// fails). `bufferEnd = 10` (0-based) is what makes `D` (at the buffer's end) show up in
    /// the `(11,11)`/1-based (`10..<10`/0-based) row.
    @Test(
        "oracle: overlays-in boundaries, seven ranges against five overlays, both tie orders of A/C"
    )
    func oracleOverlapQueryBoundaries() {
        let bufferEnd = 10
        // 1-based ranges converted to 0-based.
        let queries: [(range: Range<Int>, expected: Set<String>)] = [
            (4..<4, ["A", "B"]),
            (2..<2, ["C"]),
            (6..<6, ["E"]),
            (10..<10, ["D"]),
            (2..<6, ["A", "B", "C"]),
            (4..<5, ["A", "B"]),
            (0..<10, ["A", "B", "C", "D", "E"]),
        ]
        for tieOrder in [["A", "C"], ["C", "A"]] {
            let (tree, ids) = buildFiveOverlayFixture(tieOrder: tieOrder)
            let nameByID = Dictionary(uniqueKeysWithValues: ids.map { ($1, $0) })
            for query in queries {
                let includingEmptyAtUpperBound =
                    query.range.isEmpty || query.range.upperBound == bufferEnd
                let results = tree.intervals(
                    overlapping: query.range,
                    includingEmptyAtUpperBound: includingEmptyAtUpperBound)
                let names = Set(results.map { nameByID[$0.id]! })
                #expect(
                    names == query.expected,
                    "tieOrder=\(tieOrder) range=\(query.range): got \(names), want \(query.expected)"
                )
            }
        }
    }

    /// ```
    /// emacs -Q --batch --eval '... (dolist (p (list 3 5 7 11))
    ///   (message "overlays-at %d -> %S" p
    ///            (sort (mapcar (lambda (o) (overlay-get o (quote name))) (overlays-at p))
    ///                  (function string<)))) ...'
    /// => overlays-at 3 -> ("A")   overlays-at 5 -> ("A")   overlays-at 7 -> nil   overlays-at 11 -> nil
    /// ```
    /// `overlays-at P` is `start <= P < end`: excludes empty intervals and anything ending
    /// exactly at `P` — `overlays-at 7` is nil even though `overlays-in (7,7)` finds `E`.
    @Test("oracle: overlays-at, four positions against five overlays")
    func oracleIntervalsAt() {
        let (tree, ids) = buildFiveOverlayFixture(tieOrder: ["A", "C"])
        let nameByID = Dictionary(uniqueKeysWithValues: ids.map { ($1, $0) })
        let queries: [(position: Int, expected: Set<String>)] = [
            (2, ["A"]),
            (4, ["A"]),
            (6, []),
            (10, []),
        ]
        for query in queries {
            let names = Set(tree.intervals(at: query.position).map { nameByID[$0.id]! })
            #expect(names == query.expected, "overlays-at \(query.position)")
        }
    }

    // MARK: - Structural

    @Test("invariants hold after a few hundred random edits")
    func invariantsHoldAfterRandomEdits() throws {
        var rng = SplitMix64(seed: 0xABCD_1234)
        var tree = IntervalTree()
        var nextID: IntervalID = 0
        var bufferLength = 0
        for _ in 0..<400 {
            let kind = rng.next() % 3
            switch kind {
            case 0:
                let start = Int(rng.next() % UInt64(bufferLength + 1))
                let maxLength = min(20, bufferLength - start)
                let length = maxLength > 0 ? Int(rng.next() % UInt64(maxLength + 1)) : 0
                let fa = rng.next() % 2 == 0
                let ra = rng.next() % 2 == 0
                tree = tree.inserting(
                    range: start..<(start + length), id: nextID, frontAdvance: fa,
                    rearAdvance: ra)
                nextID += 1
            case 1:
                let lo = Int(rng.next() % UInt64(bufferLength + 1))
                let maxWidth = min(20, bufferLength - lo)
                let width = maxWidth > 0 ? Int(rng.next() % UInt64(maxWidth + 1)) : 0
                let hi = lo + width
                let insertedLength = Int(rng.next() % 12)
                let ibm = rng.next() % 4 == 0
                tree = tree.applyEdit(
                    byteRange: lo..<hi, insertedLength: insertedLength, insertBeforeMarkers: ibm)
                bufferLength += insertedLength - width
            default:
                let insertAt = Int(rng.next() % UInt64(bufferLength + 1))
                let length = Int(rng.next() % 10)
                tree = tree.applyEdit(byteRange: insertAt..<insertAt, insertedLength: length)
                bufferLength += length
            }
            try tree.checkInvariants()
        }
    }

    /// The negative-test precedent from `sumTreeTests.swift:477-553`: an invariant checker
    /// nobody has seen fail is not evidence. Hand-builds a leaf with a `maxEnd` that
    /// disagrees with the fold of its own items.
    @Test("checkInvariants() throws on a stale maxEnd")
    func maxEndInvariantIsChecked() throws {
        let items = (0..<6).map {
            IntervalRecord(
                gap: $0 == 0 ? 0 : 1, length: 1, id: IntervalID($0), frontAdvance: false,
                rearAdvance: false)
        }
        // Correct maxEnd for this leaf (base 0): starts 0,1,2,3,4,5, each length 1, so ends
        // 1,2,3,4,5,6 -- correct maxEnd is 6. Claim 2 instead.
        let staleSummary = IntervalSummary(count: 6, span: 5, maxEnd: 2)
        let root = Node<IntervalRecord>.leaf(items, staleSummary)
        let sumTree = SumTree<IntervalRecord>(root: root)
        let tree = IntervalTree(testOnlyTree: sumTree)
        #expect(throws: SumTreeInvariantViolation.self) {
            try tree.checkInvariants()
        }
    }

    /// Intervals at the same start with mixed `frontAdvance`, some already resident before an
    /// edit and some newly collapsed onto that start by the same edit's delete stage — the
    /// tie group `dev/specs/m1.4.md` 1.5's "residents included" rule is about. Fixture and
    /// derivation are in the implementer's report; asserted here: starts stay non-decreasing,
    /// and each subset (non-movers stay at 5; movers land at 5 + insertedLength) lands where
    /// the oracle-derived rule says.
    @Test("tie-group partition at an edit boundary keeps order, residents and newcomers mixed")
    func tieGroupPartitionKeepsOrder() throws {
        // R: resident, empty, frontAdvance false -- non-mover.
        // R2: resident, frontAdvance true, long enough to survive the delete as a straddler
        //     (endpoint rule end' = end - d) rather than being swallowed entirely.
        // M, N2: not yet at the edit boundary -- their starts fall inside the deleted range
        //     and collapse onto it, becoming newcomers at the same position as R/R2.
        // P is here so the tie group is **not** at rank 0 and the group's first member is a
        // **mover** (R2 sorts before R at the shared start 5). Both matter: with the group at
        // rank 0, or with a non-mover first, the rewritten gap `p - previousAbsoluteStart`
        // coincides with the item's own pre-existing gap, and a mutation that keeps the
        // original gap instead of rebasing it -- the "flat gap" bug this function's own
        // comment records as an earlier draft's -- passes unnoticed. The mutation pass found
        // this test blind to exactly that; with P present and R2 first, the first non-mover
        // lands at P's start instead of at p, and the two expectations below fail.
        let sorted: [(range: Range<Int>, id: IntervalID, frontAdvance: Bool, rearAdvance: Bool)] = [
            (1..<2, 4, false, false),  // P: before the edit, untouched, makes leftSpan == 1
            (5..<10, 1, true, false),  // R2
            (5..<5, 0, false, false),  // R
            (6..<9, 2, true, false),  // M
            (7..<10, 3, false, false),  // N2
        ]
        let tree = IntervalTree(sortedIntervals: sorted)
        let edited = tree.applyEdit(byteRange: 5..<8, insertedLength: 2)
        try edited.checkInvariants()

        func span(_ id: IntervalID) -> IntervalSpan? { edited.rankSpan(of: id) }
        #expect(span(4)?.range == 1..<2, "P, before the edit, is untouched")
        #expect(span(0)?.range == 5..<5, "R (empty non-mover) should stay at 5, untouched")
        // N2's *start* does not move (it is a non-mover: frontAdvance false), but its end
        // (7, after the delete stage) is strictly greater than the insertion point (5), so
        // endMoves holds unconditionally and its length grows by the inserted length -- the
        // same straddler shape as `straddlersAreTheOnlyLengthChanges`, just reached through a
        // tie group instead of a strict `start < p`.
        #expect(span(3)?.range == 5..<9, "N2 (non-mover, newcomer): start stays, end still moves")
        #expect(span(1)?.range == 7..<9, "R2 (mover) should shift to 5 + insertedLength")
        #expect(span(2)?.range == 7..<8, "M (mover, newcomer) should shift to 5 + insertedLength")

        // Non-decreasing starts, and the non-movers ranked before the movers (stable
        // partition preserves each subset's original relative order, and non-movers come
        // first in the rewritten group).
        let starts = (0..<edited.count).map { edited.start(ofRank: $0) }
        #expect(starts == starts.sorted(), "starts must stay non-decreasing")
        let rankByID = Dictionary(
            uniqueKeysWithValues: (0..<edited.count).map { (edited.id(ofRank: $0), $0) })
        #expect(rankByID[0]! < rankByID[1]!, "non-mover R ranked before mover R2")
        #expect(rankByID[3]! < rankByID[2]!, "non-mover N2 ranked before mover M")
    }

    /// An edit inside one interval (a straddler, whose `length` alone changes) and outside a
    /// second interval that ranks after it (a pure gap shift). The mutation this guards
    /// against (`dev/specs/m1.4.md` section 6, item 8) shifts the straddler's *gap* instead of
    /// its length: every stored `length` in the tree stays correct, but every *later* item's
    /// absolute start is wrong — a gap error cascades forward only, so the neighbour (ranked
    /// after the straddler) is exactly where that corruption would show and a neighbour ranked
    /// before it would not.
    @Test(
        "an edit straddling one interval leaves a later interval's length untouched and its position correct"
    )
    func straddlersAreTheOnlyLengthChanges() throws {
        let sorted: [(range: Range<Int>, id: IntervalID, frontAdvance: Bool, rearAdvance: Bool)] = [
            (2..<8, 0, false, false),  // straddler: edit point 5 is strictly inside it
            (10..<15, 1, false, false),  // neighbour, ranked after
        ]
        let tree = IntervalTree(sortedIntervals: sorted)
        let edited = tree.applyEdit(byteRange: 5..<5, insertedLength: 3)
        try edited.checkInvariants()

        let straddler = try #require(edited.rankSpan(of: 0))
        let neighbour = try #require(edited.rankSpan(of: 1))
        #expect(
            straddler.range == 2..<11, "the straddler's length should grow by the inserted length")
        #expect(neighbour.range.count == 5, "the neighbour's length must be untouched")
        #expect(
            neighbour.range == 13..<18,
            "the neighbour's absolute position must shift by the inserted length")
    }

    @Test("empty tree: every query and edit; empty query ranges on a non-empty tree")
    func emptyTreeAndEmptyQueries() throws {
        let empty = IntervalTree()
        #expect(empty.isEmpty)
        #expect(empty.count == 0)
        #expect(empty.intervals(overlapping: 0..<10, includingEmptyAtUpperBound: true).isEmpty)
        #expect(empty.intervals(at: 0).isEmpty)
        let editedEmpty = empty.applyEdit(byteRange: 0..<0, insertedLength: 5)
        #expect(editedEmpty.isEmpty)
        try editedEmpty.checkInvariants()

        let sorted: [(range: Range<Int>, id: IntervalID, frontAdvance: Bool, rearAdvance: Bool)] = [
            (2..<8, 0, false, false)
        ]
        let tree = IntervalTree(sortedIntervals: sorted)
        // An empty *query range* strictly inside a non-empty interval still returns it
        // (`dev/specs/m1.4.md` 1.7's own point: a non-empty overlay is returned for a region
        // containing no character, e.g. the `(5,5)` oracle row) -- what this asserts is that
        // an empty range *outside* every interval returns nothing.
        #expect(
            tree.intervals(overlapping: 3..<3, includingEmptyAtUpperBound: false).map(\.id) == [0])
        #expect(tree.intervals(overlapping: 20..<20, includingEmptyAtUpperBound: true).isEmpty)
    }

    /// The `MarkerTree` test of the same name, for intervals.
    @Test("removing an id at its start removes exactly that interval and rebases the tail")
    func removingRebasesTail() throws {
        let sorted: [(range: Range<Int>, id: IntervalID, frontAdvance: Bool, rearAdvance: Bool)] = [
            (5..<5, 1, false, false),
            (5..<6, 2, false, false),
            (9..<11, 3, false, false),
        ]
        var tree = IntervalTree(sortedIntervals: sorted)
        tree = tree.removing(id: 2, startingAt: 5)
        try tree.checkInvariants()
        #expect(tree.count == 2)
        #expect(tree.id(ofRank: 0) == 1)
        #expect(tree.start(ofRank: 0) == 5)
        #expect(tree.id(ofRank: 1) == 3)
        #expect(tree.start(ofRank: 1) == 9)
        #expect(tree.end(ofRank: 1) == 11)
    }

    @Test("edits through BufferSnapshot.replaceSubrange keep text, markers and intervals in step")
    func bufferSnapshotFunnelKeepsTreesInStep() throws {
        var buffer = BufferSnapshot()
        buffer.replaceSubrange(0..<0, with: "0123456789")
        let markerID = buffer.createMarker(atByteOffset: 5, bias: .left)
        let intervalID = buffer.createInterval(
            byteRange: 3..<7, frontAdvance: true, rearAdvance: false)

        buffer.replaceSubrange(2..<2, with: "XY")
        try buffer.markers.checkInvariants()
        try buffer.intervals.checkInvariants()
        #expect(buffer.text.toString() == "01XY23456789")
        // Marker at 5 (frontAdvance-equivalent .left, i.e. stays before) shifts to 7.
        #expect(buffer.markers.rankPosition(of: markerID) == 7)
        // Interval (3,7) has frontAdvance true, so its start shifts (insertion at 2 is
        // strictly before it): (5,9).
        let span = try #require(buffer.intervals.rankSpan(of: intervalID))
        #expect(span.range == 5..<9)

        buffer.replaceSubrange(0..<12, with: "")
        try buffer.markers.checkInvariants()
        try buffer.intervals.checkInvariants()
        #expect(buffer.text.utf8Count == 0)
        #expect(buffer.intervals.rankSpan(of: intervalID)?.range == 0..<0)
    }

    /// This is the `find`-versus-`seek` trap of `dev/specs/m1.4.md` 1.2: `MarkerTree`'s
    /// equivalent guard had no test until a cold read found it (`markerTreeTests.swift:428-
    /// 444`). Every query and edit here happens at an offset beyond the last interval's end,
    /// where the `maxEnd` predicate this tree's straddler search relies on is never true.
    @Test("queries and edits past the last interval's end do not trap")
    func queriesPastTheLastInterval() throws {
        let sorted: [(range: Range<Int>, id: IntervalID, frontAdvance: Bool, rearAdvance: Bool)] = [
            (0..<5, 0, false, false)
        ]
        var tree = IntervalTree(sortedIntervals: sorted)
        #expect(tree.intervals(overlapping: 100..<200, includingEmptyAtUpperBound: false).isEmpty)
        #expect(tree.intervals(overlapping: 100..<200, includingEmptyAtUpperBound: true).isEmpty)
        #expect(tree.intervals(at: 100).isEmpty)
        tree = tree.applyEdit(byteRange: 100..<100, insertedLength: 5)
        try tree.checkInvariants()
        #expect(
            tree.rankSpan(of: 0)?.range == 0..<5, "an edit past the end must not touch anything")
        tree = tree.applyEdit(byteRange: 200..<210, insertedLength: 0)
        try tree.checkInvariants()
        #expect(tree.rankSpan(of: 0)?.range == 0..<5)
    }

    // MARK: - Counted, not timed

    private final class CallCounter {
        var count = 0
    }

    /// Feeds a counting wrapper **around the real, `internal` `IntervalTree.
    /// straddlerDescendPredicate(lo:)`** to the real `SumTree.visitItems` — not a hand-copied
    /// replica of the formula. A prior draft of this test wrote `prefix.span + subtree.maxEnd
    /// > lo` inline, which is a plausible-looking copy of `visitStraddlers`'s own predicate
    /// but a *different piece of code*: relaxing the production prune from `>` to `>=` (`dev/
    /// specs/m1.4.md` section 6, mutation 7b) changed no result in this file and, because the
    /// replica was a separate closure, changed nothing this test counted either — the mutation
    /// was invisible end to end. Wrapping the shared function instead means a change to that
    /// one function's body is what both `IntervalTree` and this test see. Asserts, for a query
    /// whose straddlers are rank-contiguous, that visits stay within `height + k` — derived
    /// from the tree's own `height`, never hardcoded. The scattered-results case is recorded
    /// as a number, not asserted as a bound (`dev/specs/m1.4.md` section 4, test 18).
    @Test("visitItems for an overlap query's straddler search is output-sensitive")
    func queryVisitsAreOutputSensitive() throws {
        let n = 5000
        var sorted: [(range: Range<Int>, id: IntervalID, frontAdvance: Bool, rearAdvance: Bool)] =
            []
        sorted.reserveCapacity(n)
        // Contiguous case: intervals (i, i+3) for i in 0..<n -- neighbouring starts, so a
        // straddler query near the middle finds a rank-contiguous run of results.
        for i in 0..<n {
            sorted.append(
                (range: i..<(i + 3), id: IntervalID(i), frontAdvance: false, rearAdvance: false))
        }
        let tree = IntervalTree(sortedIntervals: sorted)
        let sumTree = tree.testOnlySumTree
        let height = Int(sumTree.height)

        let lo = n / 2
        let upperRankExclusive = lo  // ranks strictly before rank `lo` (start `lo`)
        let prune = IntervalTree.straddlerDescendPredicate(lo: lo)
        let counter = CallCounter()
        var resultCount = 0
        sumTree.visitItems(
            descendInto: { prefix, subtree in
                counter.count += 1
                guard prefix.count < upperRankExclusive else { return false }
                return prune(prefix, subtree)
            },
            visit: { prefix, item in
                counter.count += 1
                guard prefix.count < upperRankExclusive else { return false }
                let absoluteStart = prefix.span + item.gap
                if absoluteStart < lo, absoluteStart + item.length > lo {
                    resultCount += 1
                }
                return true
            })
        #expect(resultCount == 2, "intervals (lo-2,lo+1) and (lo-1,lo+2) should straddle lo=\(lo)")
        // `counter.count` includes both descendInto and visit calls at every level touched,
        // so a generous but still meaningful bound is a small constant times height plus k.
        #expect(
            counter.count <= 4 * (height + resultCount + 2),
            "visits=\(counter.count) height=\(height) k=\(resultCount): not output-sensitive")

        // Scattered case, recorded rather than bounded: many intervals all ending at the same
        // point Q with starts spread across every rank (1.6's counterexample for a
        // non-strict prune).
        var scattered:
            [(range: Range<Int>, id: IntervalID, frontAdvance: Bool, rearAdvance: Bool)] = []
        let q = n
        for i in 0..<n {
            scattered.append(
                (range: i..<(q + 1), id: IntervalID(i), frontAdvance: false, rearAdvance: false))
        }
        let scatteredTree = IntervalTree(sortedIntervals: scattered)
        let scatteredSumTree = scatteredTree.testOnlySumTree
        let scatteredUpperRankExclusive = scatteredTree.count
        let scatteredPrune = IntervalTree.straddlerDescendPredicate(lo: q)
        var scatteredVisits = 0
        var scatteredResults = 0
        scatteredSumTree.visitItems(
            descendInto: { prefix, subtree in
                scatteredVisits += 1
                guard prefix.count < scatteredUpperRankExclusive else { return false }
                return scatteredPrune(prefix, subtree)
            },
            visit: { prefix, item in
                scatteredVisits += 1
                guard prefix.count < scatteredUpperRankExclusive else { return false }
                let absoluteStart = prefix.span + item.gap
                if absoluteStart < q, absoluteStart + item.length > q {
                    scatteredResults += 1
                }
                return true
            })
        // Recorded, not bounded: every one of the n intervals straddles q, so this query's
        // own k is n and there is nothing to catch here -- the point of this second fixture
        // is only that it does not crash and produces the expected result count.
        #expect(scatteredResults == n)
        _ = scatteredVisits
    }

    /// The delete-path counterpart of `queryVisitsAreOutputSensitive`: `applyDelete`'s
    /// straddler search (`visitStraddlersInclusive`) uses the same shared
    /// `IntervalTree.straddlerDescendPredicate(lo:)`. **What this test adds is a second
    /// fixture, not a second call site**: like the query's counted test it wraps the shared
    /// factory rather than `visitStraddlersInclusive`, which is `private` and unreachable even
    /// with `@testable import`, so a mutation of the shared predicate is already caught next
    /// door. What it covers that the query's fixture does not is the delete path's own
    /// boundary — its rank restriction is `<=`, not `<` (`dev/specs/m1.4.md`
    /// section 6, mutation 7b names the query; the same gap existed on the delete side and
    /// the reviewer found it separately). Same fixture shape as the contiguous case above
    /// (intervals `(i, i+3)`), restricted to the rank prefix before the first interval
    /// starting at or after `lo` — exactly `applyDelete`'s own restriction.
    @Test("visitItems for the delete path's straddler search is output-sensitive")
    func deleteStraddlerVisitsAreOutputSensitive() throws {
        let n = 5000
        var sorted: [(range: Range<Int>, id: IntervalID, frontAdvance: Bool, rearAdvance: Bool)] =
            []
        sorted.reserveCapacity(n)
        for i in 0..<n {
            sorted.append(
                (range: i..<(i + 3), id: IntervalID(i), frontAdvance: false, rearAdvance: false))
        }
        let tree = IntervalTree(sortedIntervals: sorted)
        let sumTree = tree.testOnlySumTree
        let height = Int(sumTree.height)

        // Delete a small range in the middle: [lo, lo+1). The rank restriction is
        // `firstAtOrAfterLoRank`, the rank of the first interval starting at or after `lo` --
        // reproduced here via a linear property of this fixture (interval i starts at i), not
        // by calling into `IntervalTree`'s private machinery.
        let lo = n / 2
        let upperRankExclusive = lo
        let prune = IntervalTree.straddlerDescendPredicate(lo: lo)
        let counter = CallCounter()
        var resultCount = 0
        sumTree.visitItems(
            descendInto: { prefix, subtree in
                counter.count += 1
                guard prefix.count < upperRankExclusive else { return false }
                return prune(prefix, subtree)
            },
            visit: { prefix, item in
                counter.count += 1
                guard prefix.count < upperRankExclusive else { return false }
                let absoluteStart = prefix.span + item.gap
                if absoluteStart <= lo, absoluteStart + item.length > lo {
                    resultCount += 1
                }
                return true
            })
        // The item starting exactly at `lo` (rank `upperRankExclusive`) is excluded by the
        // rank restriction, matching `applyDelete`'s own comment: it is handled by the
        // collapse-group rewrite, not the straddler search, even though it also satisfies
        // `start <= lo < end`. So only the two items with `start < lo` count here.
        #expect(resultCount == 2, "intervals starting at lo-2 and lo-1 straddle lo=\(lo)")
        #expect(
            counter.count <= 4 * (height + resultCount + 2),
            "visits=\(counter.count) height=\(height) k=\(resultCount): not output-sensitive")
    }

    /// A line-for-line replica of `pathCopyEditNode`'s descent control flow — see
    /// `markerTreeTests.swift`'s `countedDescent` for the full rationale (this is that same
    /// function, retyped over `IntervalSummary`, since it is not exported from that file).
    private func countedDescent(
        _ node: Node<IntervalRecord>, prefix: IntervalSummary,
        predicate: (IntervalSummary) -> Bool, visits: inout Int
    ) {
        visits += 1
        switch node {
        case .leaf(let items, _):
            var cum = prefix
            for item in items {
                let next = cum + item.summary
                if predicate(next) { return }
                cum = next
            }
            preconditionFailure("countedDescent: predicate never true within this leaf")
        case .interior(let children, _, _):
            var cum = prefix
            for child in children {
                let next = cum + child.summary
                if predicate(next) {
                    countedDescent(child, prefix: cum, predicate: predicate, visits: &visits)
                    return
                }
                cum = next
            }
            preconditionFailure("countedDescent: predicate never true within this interior node")
        }
    }

    /// An edit with `k = 0` (nothing straddles the boundary) costs one `pathCopyEdit` descent
    /// of `height + 1` nodes, at 10^4/10^5 intervals — the shift `shiftingSuffix` performs,
    /// mirroring `markerTreeTests.swift`'s `nodeVisitsAreHeightPlusOne`.
    @Test("edit visits are height + 1 when nothing straddles the edit point, n = 10^4/10^5")
    func editVisitsAreConstantWhenNothingStraddles() throws {
        for n in [10_000, 100_000] {
            var sorted:
                [(range: Range<Int>, id: IntervalID, frontAdvance: Bool, rearAdvance: Bool)] = []
            sorted.reserveCapacity(n)
            // Non-overlapping, well-separated intervals: (8i, 8i+1) for i in 0..<n. An edit
            // at any multiple of 8 straddles nothing.
            for i in 0..<n {
                sorted.append(
                    (
                        range: (8 * i)..<(8 * i + 1), id: IntervalID(i), frontAdvance: false,
                        rearAdvance: false
                    ))
            }
            let tree = IntervalTree(sortedIntervals: sorted)
            let sumTree = tree.testOnlySumTree
            let expectedVisits = Int(sumTree.height) + 1

            let boundary = 4 * n  // a multiple of 8, inside the tree's span, on no interval
            let predicate: (IntervalSummary) -> Bool = { $0.count > 0 && $0.span >= boundary }
            var visits = 0
            countedDescent(sumTree.root, prefix: .identity, predicate: predicate, visits: &visits)
            #expect(
                visits == expectedVisits,
                "n=\(n): expected height + 1 = \(expectedVisits), got \(visits)")

            let counter = CallCounter()
            let countingPredicate: (IntervalSummary) -> Bool = { summary in
                counter.count += 1
                return predicate(summary)
            }
            let realResult = sumTree.pathCopyEdit(
                where: countingPredicate, edit: { items, _, _ in items })
            #expect(
                realResult != nil,
                "n=\(n): the real pathCopyEdit should have found the boundary item")
        }
    }

    /// One fixture, two assertions on two different queries — `dev/specs/m1.4.md` 1.6's two
    /// independent failure modes are not visible to the same assertion. Many non-empty
    /// intervals share `end == Q` while their starts are scattered across every rank (the
    /// counterexample that defeats a non-strict `maxEnd >= lo` prune), plus empty intervals
    /// placed at chosen `lo`/`hi` positions.
    @Test("empty intervals and a scattered-end fixture at scale: results and visit count")
    func boundaryEmptyIntervalsAtScale() throws {
        let n = 4000
        // Every scattered start below must stay strictly below `q` (`(n - 1) * 20 < q`).
        let q = 100_000
        precondition((n - 1) * 20 < q)
        var sorted: [(range: Range<Int>, id: IntervalID, frontAdvance: Bool, rearAdvance: Bool)] =
            []
        sorted.reserveCapacity(n + 3)
        // Scattered starts, all ending at q, starts 0, 20, 40, ... spread across the whole
        // rank space.
        for i in 0..<n {
            sorted.append(
                (range: (i * 20)..<(q), id: IntervalID(i), frontAdvance: false, rearAdvance: false))
        }
        // Empty intervals at two chosen positions, inserted in start order alongside the
        // scattered starts (both well inside the scattered range). Deliberately **none** at
        // `q` itself: part (b) below queries `[q, q+1)` and needs that to return nothing, so
        // an interval starting exactly at `q` (which piece 1 would legitimately find) is not
        // placed there.
        let emptyLoID = IntervalID(n)
        let emptyHiID = IntervalID(n + 1)
        sorted.append((range: 10..<10, id: emptyLoID, frontAdvance: false, rearAdvance: false))
        sorted.append((range: 30..<30, id: emptyHiID, frontAdvance: false, rearAdvance: false))
        sorted.sort { $0.range.lowerBound < $1.range.lowerBound }

        let tree = IntervalTree(sortedIntervals: sorted)
        try tree.checkInvariants()

        // (a) Results: query the positions carrying empty intervals, compare against a
        // brute-force filter using 1.7's rule.
        func bruteForce(_ range: Range<Int>, includingEmptyAtUpperBound: Bool) -> Set<IntervalID> {
            var result: Set<IntervalID> = []
            for r in 0..<tree.count {
                let span = tree.span(ofRank: r)
                if span.range.isEmpty {
                    let s = span.range.lowerBound
                    let included =
                        (range.lowerBound <= s && s < range.upperBound)
                        || (s == range.upperBound && includingEmptyAtUpperBound)
                    if included { result.insert(span.id) }
                } else if span.range.upperBound > range.lowerBound
                    && span.range.lowerBound < range.upperBound
                {
                    result.insert(span.id)
                }
            }
            return result
        }
        // Both of `10..<10`/`30..<30` are **empty** query ranges, so piece 1 (starts inside
        // `[lo, hi)`) contributes nothing to either of them — its scan breaks immediately
        // when `lo == hi`. A mutation that filters piece 1's items by `end > lo`
        // (`dev/specs/m1.4.md` section 6, mutation 7a) is therefore invisible to this pair:
        // only test 8 (`oracleOverlapQueryBoundaries`) would catch it. `10..<40` is a
        // **non-empty** range whose `lo` carries the empty interval at 10 -- piece 1 must
        // find it there, which is exactly what mutation 7a removes.
        for (query, includingEmptyAtUpperBound) in [
            (10..<10, true), (30..<30, true), (10..<40, false),
        ] {
            let real = Set(
                tree.intervals(
                    overlapping: query, includingEmptyAtUpperBound: includingEmptyAtUpperBound
                ).map(\.id))
            let expected = bruteForce(
                query, includingEmptyAtUpperBound: includingEmptyAtUpperBound)
            #expect(real == expected, "query \(query): got \(real), want \(expected)")
        }

        // (b) Visits: query **[Q, Q+1)**, `lo == Q` exactly — this is 1.6's own
        // counterexample, and it needs `lo` to land exactly where every scattered interval's
        // end does, not one byte off it (an earlier draft of this test queried `[Q+1, Q+2)`
        // to dodge the fixture's empty-interval-at-Q entry, which also silently made the
        // query insensitive to the very mutation it exists to catch: with `lo == Q + 1`, no
        // scattered interval's `maxEnd` (`== Q`) is `>= lo` either, so relaxing the prune from
        // `>` to `>=` changed nothing to visit either way. With `lo == Q`, every scattered
        // interval's `maxEnd` equals `lo` exactly, so a non-strict prune (`>=`) enters every
        // one of their subtrees while the strict one (`>`) enters none — that gap is what
        // this test's visit-count bound is checking). Returns nothing: no interval starts in
        // `[Q, Q+1)` (the fixture deliberately has none at `Q`), and no non-empty interval's
        // end exceeds `Q` (every scattered interval ends *at* `Q`, not after it).
        let visitQuery = q..<(q + 1)
        let real = tree.intervals(overlapping: visitQuery, includingEmptyAtUpperBound: false)
        #expect(real.isEmpty, "query \(visitQuery) should return nothing")

        let sumTree = tree.testOnlySumTree
        let height = Int(sumTree.height)
        let firstInRangeRank = { () -> Int in
            for r in 0..<tree.count where tree.start(ofRank: r) >= visitQuery.lowerBound {
                return r
            }
            return tree.count
        }()
        // Wraps the real, shared `IntervalTree.straddlerDescendPredicate(lo:)` — not a
        // hand-copied `prefix.span + subtree.maxEnd > lo` closure — for the same reason
        // `queryVisitsAreOutputSensitive` does (see that test's doc comment): a replica here
        // would make this test blind to a regression in the production prune, which is
        // exactly the failure mode `dev/specs/m1.4.md` section 6 mutation 7b describes.
        let prune = IntervalTree.straddlerDescendPredicate(lo: visitQuery.lowerBound)
        let counter = CallCounter()
        sumTree.visitItems(
            descendInto: { prefix, subtree in
                counter.count += 1
                guard prefix.count < firstInRangeRank else { return false }
                return prune(prefix, subtree)
            },
            visit: { prefix, _ in
                counter.count += 1
                return prefix.count < firstInRangeRank
            })
        // Generous bound: height plus the tie groups scanned (a handful of empty-interval
        // entries), definitely not proportional to n.
        #expect(
            counter.count < 10 * (height + 10),
            "visits=\(counter.count) height=\(height): not output-sensitive for a query with no results"
        )
    }

    // MARK: - Differential

    private struct ModelInterval {
        var start: Int
        var length: Int
        var id: IntervalID
        var frontAdvance: Bool
        var rearAdvance: Bool
    }

    /// The section 1.4/1.5 rules applied by brute force, per endpoint, independently.
    private static func applyModelDelete(_ model: inout [ModelInterval], lo: Int, hi: Int) {
        let d = hi - lo
        for i in model.indices {
            let start = model[i].start
            let end = start + model[i].length
            func adjust(_ x: Int) -> Int {
                if x <= lo { return x }
                if x < hi { return lo }
                return x - d
            }
            let newStart = adjust(start)
            let newEnd = adjust(end)
            model[i].start = newStart
            model[i].length = newEnd - newStart
        }
    }

    private static func applyModelInsert(
        _ model: inout [ModelInterval], p: Int, length: Int, insertBeforeMarkers: Bool
    ) {
        for i in model.indices {
            let start = model[i].start
            let end = start + model[i].length
            let fa = model[i].frontAdvance
            let ra = model[i].rearAdvance
            var newStart =
                (start > p || (start == p && (fa || insertBeforeMarkers))) ? start + length : start
            let newEnd =
                (end > p || (end == p && (ra || insertBeforeMarkers))) ? end + length : end
            if newStart > newEnd { newStart = newEnd }
            model[i].start = newStart
            model[i].length = newEnd - newStart
        }
    }

    /// 20,000 random edits against a naive per-interval model, comparing the full interval
    /// set after each edit through both the rank accessors and a random `intervals(
    /// overlapping:)` query — `maxEnd` feeds only the query, so a rank-only comparison is
    /// blind to every corruption of it. Drives `IntervalTree` directly, not through
    /// `BufferSnapshot`: `includingEmptyAtUpperBound` is computed from the model's own
    /// maintained `bufferLength`, the same variable that bounds the random offsets drawn
    /// below, not a second length source.
    @Test("differential: 20,000 random edits against a naive per-interval model")
    func manyEditDifferential() throws {
        let seed: UInt64 = 0x1234_5678_ABCD
        var rng = SplitMix64(seed: seed)
        var model: [ModelInterval] = []
        var tree = IntervalTree()
        var nextID: IntervalID = 0
        var bufferLength = 0
        let operationCount = 20_000
        // `dev/specs/m1.4.md`'s own cadence is "every hundredth edit" (matching
        // `manyEditDifferential`'s own header comment above) -- this was 200 in an earlier
        // draft, disagreeing with the spec it quotes; fixed to agree rather than asking the
        // spec to change, since 100 is what the spec says and there is no stated reason to
        // prefer 200.
        let checkEvery = 100

        var sawStraddle = false
        var sawNest = false
        var sawSharedStart = false
        var sawSharedEnd = false
        var sawEmpty = false

        func recordShapes() {
            for a in model {
                if a.length == 0 { sawEmpty = true }
                for b in model where a.id != b.id {
                    let aEnd = a.start + a.length
                    let bEnd = b.start + b.length
                    if a.start == b.start { sawSharedStart = true }
                    if aEnd == bEnd { sawSharedEnd = true }
                    if a.start < b.start && aEnd > b.start && aEnd < bEnd { sawStraddle = true }
                    if a.start <= b.start && aEnd >= bEnd && a.id != b.id { sawNest = true }
                }
            }
        }

        func modelResults() -> [(id: IntervalID, range: Range<Int>)] {
            model.sorted { $0.start < $1.start }.map { ($0.id, $0.start..<($0.start + $0.length)) }
        }
        func treeResults() -> [(id: IntervalID, range: Range<Int>)] {
            (0..<tree.count).map { r in
                let span = tree.span(ofRank: r)
                return (span.id, span.range)
            }
        }
        func compareRanks(_ opIndex: Int) {
            let modelR = modelResults()
            let treeR = treeResults()
            #expect(
                modelR.count == treeR.count,
                "seed \(seed), op \(opIndex): count mismatch, model \(modelR.count) tree \(treeR.count)"
            )
            let modelByID = Dictionary(uniqueKeysWithValues: modelR.map { ($0.id, $0.range) })
            let treeByID = Dictionary(uniqueKeysWithValues: treeR.map { ($0.id, $0.range) })
            for (id, range) in modelByID {
                guard let treeRange = treeByID[id] else {
                    Issue.record("seed \(seed), op \(opIndex): tree missing interval id \(id)")
                    continue
                }
                #expect(
                    treeRange == range,
                    "seed \(seed), op \(opIndex): id \(id) model=\(range) tree=\(treeRange)")
            }
        }
        func compareQuery(_ opIndex: Int) {
            guard bufferLength > 0 else { return }
            let lo = Int(rng.next() % UInt64(bufferLength + 1))
            let maxWidth = bufferLength - lo
            let width = maxWidth > 0 ? Int(rng.next() % UInt64(maxWidth + 1)) : 0
            let hi = lo + width
            let includingEmptyAtUpperBound = (lo == hi) || (hi == bufferLength)
            let modelMatches = Set(
                model.filter {
                    let end = $0.start + $0.length
                    if $0.length == 0 {
                        return (lo <= $0.start && $0.start < hi)
                            || ($0.start == hi && includingEmptyAtUpperBound)
                    }
                    return end > lo && $0.start < hi
                }.map(\.id))
            let treeMatches = Set(
                tree.intervals(
                    overlapping: lo..<hi, includingEmptyAtUpperBound: includingEmptyAtUpperBound
                )
                .map(\.id))
            #expect(
                modelMatches == treeMatches,
                "seed \(seed), op \(opIndex): query \(lo)..<\(hi) model=\(modelMatches) tree=\(treeMatches)"
            )
        }

        let maxIntervals = 2_000
        let maxBufferLength = 8_192
        let widthCap = 64

        for opIndex in 0..<operationCount {
            let kind = rng.next() % 5
            switch kind {
            case 0, 1:
                guard model.count < maxIntervals else { break }
                let start = Int(rng.next() % UInt64(bufferLength + 1))
                let maxLength = min(widthCap, bufferLength - start)
                let length = maxLength > 0 ? Int(rng.next() % UInt64(maxLength + 1)) : 0
                let fa = rng.next() % 2 == 0
                let ra = rng.next() % 2 == 0
                let id = nextID
                nextID += 1
                model.append(
                    ModelInterval(
                        start: start, length: length, id: id, frontAdvance: fa, rearAdvance: ra))
                tree = tree.inserting(
                    range: start..<(start + length), id: id, frontAdvance: fa, rearAdvance: ra)
            case 2:
                if !model.isEmpty {
                    let idx = Int(rng.next() % UInt64(model.count))
                    let removed = model.remove(at: idx)
                    tree = tree.removing(id: removed.id, startingAt: removed.start)
                }
            default:
                let lo = Int(rng.next() % UInt64(bufferLength + 1))
                let maxWidth = min(widthCap, bufferLength - lo)
                let width = maxWidth > 0 ? Int(rng.next() % UInt64(maxWidth + 1)) : 0
                let hi = lo + width
                var insertedLength = Int(rng.next() % UInt64(widthCap + 1))
                if bufferLength - width + insertedLength > maxBufferLength {
                    insertedLength = 0
                }
                let insertBeforeMarkers = rng.next() % 5 == 0
                Self.applyModelDelete(&model, lo: lo, hi: hi)
                if insertedLength > 0 {
                    Self.applyModelInsert(
                        &model, p: lo, length: insertedLength,
                        insertBeforeMarkers: insertBeforeMarkers)
                }
                tree = tree.applyEdit(
                    byteRange: lo..<hi, insertedLength: insertedLength,
                    insertBeforeMarkers: insertBeforeMarkers)
                bufferLength += insertedLength - width
            }

            // `dev/specs/m1.4.md` 1.6's own cadence: every hundredth edit, and after every
            // edit that empties an interval (`checkInvariants()` is O(n), too expensive for
            // every one of 20,000 edits, but an emptied interval is exactly the shape that
            // needs a fresh invariant check most). `emptied` itself is only O(model.count)
            // per op -- cheap enough to check every time, unlike `recordShapes()` below.
            let emptied = model.contains { $0.length == 0 }
            if emptied { sawEmpty = true }
            if opIndex % checkEvery == 0 || emptied {
                do {
                    try tree.checkInvariants()
                } catch {
                    Issue.record("seed \(seed), op \(opIndex): invariant violation \(error)")
                }
            }
            // `recordShapes()` is O(model.count^2) (every pair, to notice straddling/
            // nesting/shared-start/shared-end shapes): with `model.count` up to `maxIntervals`
            // (2,000) and `emptied` true on a large fraction of the 20,000 edits (deletions
            // routinely swallow whole short intervals at this generator's widths), riding the
            // same "every hundredth edit or emptied" cadence as `checkInvariants()` above
            // measured in the billions of comparisons and did not finish in reasonable time
            // in a debug build. It rides the strictly periodic cadence alone instead (100
            // calls over the whole run), same as `compareRanks`/`compareQuery` below.
            if opIndex % checkEvery == 0 {
                recordShapes()
                compareRanks(opIndex)
                compareQuery(opIndex)
            }
        }
        do {
            try tree.checkInvariants()
        } catch {
            Issue.record("seed \(seed): final invariant violation \(error)")
        }
        compareRanks(operationCount)
        compareQuery(operationCount)

        #expect(sawStraddle, "the workload never produced a straddling pair")
        #expect(sawNest, "the workload never produced a nesting pair")
        #expect(sawSharedStart, "the workload never produced a shared-start pair")
        #expect(sawSharedEnd, "the workload never produced a shared-end pair")
        #expect(sawEmpty, "the workload never produced an empty interval")
    }
}

extension IntervalTree {
    /// Test-only convenience: the current span of the interval `id`, found by a linear scan
    /// over ranks — mirrors `MarkerTree.rankPosition(of:)`/`rankBias(of:)`
    /// (`markerTreeTests.swift`).
    func rankSpan(of id: IntervalID) -> IntervalSpan? {
        for r in 0..<count where self.id(ofRank: r) == id {
            return span(ofRank: r)
        }
        return nil
    }
}
