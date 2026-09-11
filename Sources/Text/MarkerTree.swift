/// The marker tree (M1.3, `dev/specs/m1.3.md`): markers stored gap-encoded in a
/// `SumTree<MarkerRecord>`, ordered by a doubled key
///
/// ```
/// key = 2 * byteOffset + biasRank        biasRank: .left = 0, .right = 1
/// byteOffset = key >> 1                  biasRank = key & 1
/// ```
///
/// `.left` is GNU's `marker-insertion-type nil` (stays before inserted text) and is the
/// default; `.right` is type `t`. The bias is not stored separately from the key, so the two
/// cannot disagree. Doubling the key means every `.left` marker at position `p` sorts
/// immediately before every `.right` marker at the same `p` — the whole of GNU's
/// insertion-type behaviour becomes a choice of which numeric key to seek to (`dev/specs/
/// m1.3.md` section 1).
///
/// **Gaps, not absolute keys.** `MarkerRecord.gap` is this item's key minus the previous
/// item's key (or minus zero, for the first item) — never negative. An item's absolute key
/// is the prefix sum of gaps up to and including it. This is what makes "shift every marker
/// at or after K by δ" a change to **one item's gap**: every later item's absolute key is
/// defined relative to it, so the shift propagates for free. See `shiftingSingleItem` below.
///
/// **This file corrects one algorithmic claim in `dev/specs/m1.3.md` section 2.B, found by
/// running the oracle it names, not assumed.** The spec's `applyEdit` table describes a
/// single fused pass with one `Δ = 2 * (L - (hi - lo))` applied uniformly: keys below the
/// collapse range unchanged, keys inside collapsed to `lo`, keys above shifted by `Δ`. Run
/// against real GNU Emacs, this does not reproduce the spec's own oracle row:
///
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
///
/// With `lo=2, hi=5, L=4` (0-based bytes; buffer sizes fix these numbers unambiguously), the
/// fused `Δ = 2 * (4 - 3) = 2` cannot produce `type-t=7` from any starting key consistent
/// with the table's own row boundaries: `type-t`'s key (5, right bias at `lo`) sits in the
/// table's "unchanged" row (`k < 2*lo+2 = 6`), and no row shifts a key by enough to reach 7's
/// byte offset (6) from any candidate origin without contradicting another row. A second,
/// independent oracle probe confirms the mechanism — a marker with **right** bias strictly
/// **inside** a deleted range, which the table says should merely collapse to `lo`, is
/// instead pushed further, by the *full* inserted length:
///
/// ```
/// emacs -Q --batch --eval '
/// (with-temp-buffer
///   (insert "abcdefgh")
///   (let ((m (copy-marker 4 t)))
///     (goto-char 3) (delete-region 3 6) (insert "WXYZ")
///     (message "inside-del-type-t buffer=%S marker=%d" (buffer-string) (marker-position m))))'
/// => inside-del-type-t buffer="abWXYZfgh" marker=7
/// ```
///
/// **The reason**: GNU has no atomic "replace" primitive with its own marker rule. A
/// replace is a delete followed by an insert, and each adjusts markers by its own rule in
/// sequence — a marker that survives the delete sitting exactly at `lo`, or one that
/// collapses there, is afterward indistinguishable from any other marker already at `lo`,
/// and is pushed by the subsequent insertion exactly as `insert-before-markers`'s own oracle
/// row already establishes. `applyEdit` below is therefore implemented as that same
/// two-stage composition — a delete-and-collapse stage using the spec's own row table with
/// `L` folded to 0 (verified correct on its own by the `marker-inside-del`/`del-with-type-t`
/// oracle rows, neither of which involves a subsequent insertion), followed by a single-item
/// shift at the insertion's own boundary (`2*lo` or `2*lo+1`) — rather than the single fused
/// pass the spec describes. This is a narrowly-scoped correction, not a redesign: the same
/// gap-encoded `SumTree`, the same `split`/`concat`/`pathCopyEdit` primitives, and the same
/// complexity bounds (`dev/specs/m1.3.md` section 2.B's two named perf cases — a pure
/// insertion, and a pure deletion spanning k markers — both reduce to exactly one of the two
/// stages, so neither benchmark's shape changes). Re-verified against every oracle row in
/// `dev/specs/m1.3.md` section 4 plus the two probes above; see `markerTreeTests.swift`.
///
/// **A related correction inside the collapse stage itself**, found while proving the fix
/// above safe against the tree's own ordering invariant (not from an oracle — GNU exposes no
/// observable order among markers tied at one position): the collapse step must widen its
/// extracted group to include any markers *already* sitting exactly at `lo` (both biases),
/// not only the ones collapsing in from inside the deleted range or from `hi`. Repartitioning
/// only the inside/at-`hi` markers by bias and assigning them keys `2*lo`/`2*lo+1` can place
/// a newly-collapsed `.left` marker (key `2*lo`) after an already-resident `.right` marker at
/// `lo` (key `2*lo+1`) that a narrower group leaves untouched in `beforeGroup` — non-decreasing
/// key order (and, with it, non-negative gaps) requires every marker that ends up at the same
/// final position to be repartitioned together. Proven safe algebraically (see
/// `applyDeleteAndCollapse`'s comments) and checked by the randomised property test's
/// `checkInvariants()` cadence, not by a GNU oracle (no such scenario is oracle-checkable).
///
/// **Known gaps** (`dev/specs/m1.3.md` section 8): marker offsets are UTF-8 byte offsets and
/// must be scalar boundaries — untested by construction, exactly as `Rope.swift` records for
/// its own scalar-boundary preconditions, because reaching the trap needs an out-of-process
/// crash harness this project does not have; every randomised test here draws offsets from a
/// rope's valid boundary set. Keys are `2 * byteOffset`, so a 2 GB buffer reaches about 2^32
/// — `Int` is 64-bit on this target, comfortably inside range, but this is the bound M1.6's
/// mmap view must not silently break. A `MarkerTree` is a value: forking one and editing both
/// branches reuses marker IDs (M1.5's branching undo is the milestone that must decide the
/// allocation story). Deleting a range containing k markers costs O(k) — inherent under the
/// no-retained-history constraint (`dev/specs/m1.3.md` section 2.B), and GNU pays it linearly
/// too.

/// A marker's insertion type: which side of inserted text it stays on. `.left` is GNU's
/// `marker-insertion-type nil` (the default — `copy-marker`/`make-marker` both produce it,
/// confirmed against the oracle: `emacs -Q --batch --eval '(message "%S %S"
/// (marker-insertion-type (copy-marker 1)) (marker-insertion-type (make-marker)))'` =>
/// `nil nil`); `.right` is type `t`. `rank`/`init(rank:)` are the encoding into/out of the
/// doubled key's low bit — see this file's header.
package enum MarkerBias: Sendable, Equatable {
    case left
    case right

    package var rank: Int {
        switch self {
        case .left: return 0
        case .right: return 1
        }
    }

    package init(rank: Int) {
        precondition(rank == 0 || rank == 1, "MarkerBias.init(rank:): rank must be 0 or 1")
        self = rank == 0 ? .left : .right
    }
}

/// A marker's identity: monotone, never reused (the allocation itself is `BufferSnapshot`'s
/// job — see that file). Plain `UInt64`, not a wrapper struct: nothing here needs anything a
/// wrapper would add over the built-in type's own `Equatable`/`Hashable`/`Sendable`.
package typealias MarkerID = UInt64

/// `MarkerRecord`'s summary: `count` is the order-statistic dimension (1 per item, so a
/// prefix `count` is a rank), `span` is the prefix-sum dimension (a prefix `span` is the
/// previous item's absolute key, and an item's own summary `span == gap` folds up to that
/// item's absolute key once its own `count`/`span` are on top of the running total — see
/// `MarkerRecord.summary`).
package struct MarkerSummary: Summary {
    package var count: Int
    package var span: Int

    package init(count: Int, span: Int) {
        self.count = count
        self.span = span
    }

    package static var identity: MarkerSummary { MarkerSummary(count: 0, span: 0) }

    package static func + (lhs: MarkerSummary, rhs: MarkerSummary) -> MarkerSummary {
        MarkerSummary(count: lhs.count + rhs.count, span: lhs.span + rhs.span)
    }
}

/// One marker, gap-encoded: `gap` is this marker's key minus the previous marker's key (or
/// minus zero, for the tree's first marker) — never negative; the invariant is checked by
/// `MarkerTree.checkInvariants()`, not enforced per-mutation, matching this module's existing
/// convention for its other `Summable` item (`Chunk`'s bytes are validated by `Rope`'s own
/// invariant check, not on every field write). 16 bytes: an `Int` gap plus a `UInt64` id.
/// `MarkerRecord`/`MarkerSummary` are plain `package` types — not promoted for cross-module
/// inlining, exactly as `Chunk` is not (`dev/check-inlining.sh` greps `SumTreeCursor`/`Node`/
/// `Summary`/`Summable` by name, and this type adds nothing to that list).
package struct MarkerRecord: Sendable, Equatable {
    package var gap: Int
    package var id: MarkerID

    package init(gap: Int, id: MarkerID) {
        self.gap = gap
        self.id = id
    }
}

extension MarkerRecord: Summable {
    package typealias Item_Summary = MarkerSummary
    package var summary: MarkerSummary { MarkerSummary(count: 1, span: gap) }
}

/// The marker tree itself. Wraps a `SumTree<MarkerRecord>` and never exposes it: gaps are
/// relative, so `SumTree.concat` is not marker-safe on its own (joining two marker trees
/// produces silently wrong positions everywhere after the seam unless the right-hand tree's
/// first gap is rebased against the left-hand total span first) — every split/concat inside
/// this type rebases, so no caller can reach one that does not. The one exception is
/// `testOnlySumTree` below, an `internal` read-only accessor: it cannot put a tree back,
/// because `init(tree:)` stays `private`, and `internal` keeps it invisible outside a
/// `@testable import`.
package struct MarkerTree: Sendable {
    private var tree: SumTree<MarkerRecord>

    private init(tree: SumTree<MarkerRecord>) {
        self.tree = tree
    }

    package init() {
        self.tree = SumTree<MarkerRecord>()
    }

    /// Bulk build (O(n), via `SumTree.init(items:)`): `sortedMarkers` must already be in
    /// non-decreasing key order (`2 * byteOffset + bias.rank`), which this preconditions
    /// rather than sorting itself — a caller building from an already-ordered source (the
    /// common case: markers loaded alongside a rope built the same way) should not pay for a
    /// sort it does not need.
    package init(sortedMarkers: [(byteOffset: Int, bias: MarkerBias, id: MarkerID)]) {
        var items: [MarkerRecord] = []
        items.reserveCapacity(sortedMarkers.count)
        var previousKey = 0
        for (index, marker) in sortedMarkers.enumerated() {
            precondition(
                marker.byteOffset >= 0,
                "MarkerTree.init(sortedMarkers:): negative byte offset at index \(index)")
            let key = 2 * marker.byteOffset + marker.bias.rank
            precondition(
                key >= previousKey,
                "MarkerTree.init(sortedMarkers:): input not in non-decreasing key order at index \(index)"
            )
            items.append(MarkerRecord(gap: key - previousKey, id: marker.id))
            previousKey = key
        }
        self.tree = SumTree<MarkerRecord>(items: items)
    }

    package var count: Int { tree.summary.count }
    package var isEmpty: Bool { tree.isEmpty }

    // MARK: - Rank-indexed queries

    /// The absolute key of the marker at 0-based rank `r`, via `SumTree.find`'s `>`
    /// convention (matching `Rope.locate`'s own use of `>` — see that function's doc
    /// comment): prefix `count > r` first becomes true exactly at the item whose own index
    /// is `r`.
    private func key(ofRank r: Int) -> Int {
        precondition(r >= 0 && r < count, "MarkerTree.key(ofRank:): rank \(r) out of bounds")
        guard let (item, itemPrefix) = tree.find(where: { $0.count > r }) else {
            preconditionFailure("MarkerTree.key(ofRank:): rank \(r) not found")
        }
        return itemPrefix.span + item.gap
    }

    package func position(ofRank r: Int) -> Int { key(ofRank: r) >> 1 }
    package func bias(ofRank r: Int) -> MarkerBias { MarkerBias(rank: key(ofRank: r) & 1) }

    package func id(ofRank r: Int) -> MarkerID {
        precondition(r >= 0 && r < count, "MarkerTree.id(ofRank:): rank \(r) out of bounds")
        guard let (item, _) = tree.find(where: { $0.count > r }) else {
            preconditionFailure("MarkerTree.id(ofRank:): rank \(r) not found")
        }
        return item.id
    }

    /// The order statistic: the rank of the first marker with key `>= k`, or `count` when
    /// nothing qualifies. The seek predicate is `{ $0.count > 0 && $0.span >= k }` —
    /// `dev/specs/m1.3.md` section 0's precondition 1: without the `count > 0` clause,
    /// `.identity` is `(0, 0)` and `0 >= 0` is true, so an edit at byte offset 0 (`k == 0`)
    /// would trip `SumTree.find`'s `predicate(.identity)` precondition.
    package func rank(atOrAfterKey k: Int) -> Int {
        guard let (_, itemPrefix) = tree.find(where: { $0.count > 0 && $0.span >= k }) else {
            return count
        }
        return itemPrefix.count
    }

    /// Markers with byte offset in `byteRange` (half-open, the ordinary text-range sense —
    /// contrast `applyEdit`'s collapse rule, which is deliberately *not* half-open for
    /// markers). O(log n + k): one `find` to reach the first qualifying marker (also the
    /// guard `dev/specs/m1.3.md` section 0's precondition 2 requires before any cursor
    /// `seek` — "no marker at or after p" is the ordinary case near the end of a buffer, so
    /// `seek` is never called unguarded), then a cursor walk collecting markers until the key
    /// leaves the range.
    package func markers(in byteRange: Range<Int>) -> [(
        offset: Int, bias: MarkerBias, id: MarkerID
    )] {
        precondition(byteRange.lowerBound >= 0, "MarkerTree.markers(in:): negative lower bound")
        let startKey = 2 * byteRange.lowerBound
        let endKey = 2 * byteRange.upperBound
        guard let (_, itemPrefix) = tree.find(where: { $0.count > 0 && $0.span >= startKey })
        else {
            return []
        }
        var cursor = tree.makeCursor()
        cursor.seek(where: { $0.count > 0 && $0.span >= startKey })
        var currentKey = itemPrefix.span
        var results: [(offset: Int, bias: MarkerBias, id: MarkerID)] = []
        while let item = cursor.next() {
            currentKey += item.gap
            if currentKey >= endKey { break }
            results.append(
                (offset: currentKey >> 1, bias: MarkerBias(rank: currentKey & 1), id: item.id))
        }
        return results
    }

    // MARK: - Single-marker insert/remove

    /// Inserts one new marker at `byteOffset`/`bias` among the existing ones — not an edit
    /// (nothing else moves). Finds the rank at which the new key belongs via
    /// `rank(atOrAfterKey:)`, splits there via the **rank**-based predicate
    /// (`{ $0.count >= insertRank }`) rather than a key-based one — `dev/specs/m1.3.md`
    /// section 2.B's warning applies here too: `split`'s flip-item-goes-left rule means a
    /// key-based split predicate lands the wrong item on the wrong side at a tie, while a
    /// rank-based one partitions exactly at the intended index regardless of ties. Rebases
    /// the following item's gap so its absolute key is unchanged.
    package func inserting(byteOffset: Int, bias: MarkerBias, id: MarkerID) -> MarkerTree {
        precondition(byteOffset >= 0, "MarkerTree.inserting: negative byte offset")
        let key = 2 * byteOffset + bias.rank
        let insertRank = rank(atOrAfterKey: key)
        let (left, right) = tree.split(where: { $0.count >= insertRank })
        let leftSpan = left.summary.span
        let newGap = key - leftSpan
        precondition(
            newGap >= 0,
            "MarkerTree.inserting: key \(key) precedes the tree's prefix span \(leftSpan)")
        let newItemTree = SumTree<MarkerRecord>(items: [MarkerRecord(gap: newGap, id: id)])
        var result = SumTree.concat(left, newItemTree)
        if !right.isEmpty {
            guard let (rBefore, rItem, _, rAfter) = right.cut(where: { $0.count >= 1 }) else {
                preconditionFailure("MarkerTree.inserting: cut on a non-empty tail failed")
            }
            precondition(
                rBefore.isEmpty, "MarkerTree.inserting: rank-0 cut left a non-empty prefix")
            let rebased = SumTree<MarkerRecord>(
                items: [MarkerRecord(gap: rItem.gap - newGap, id: rItem.id)])
            result = SumTree.concat(result, SumTree.concat(rebased, rAfter))
        }
        return MarkerTree(tree: result)
    }

    /// Removes the marker `id` at `byteOffset` — `atByteOffset`, not `atByteOffset:bias:`,
    /// because `MarkerRecord` carries no bias field of its own (it is folded entirely into
    /// the key), so locating the one to remove needs only a linear scan across the (usually
    /// tiny) tie group at that offset, not a second coordinate. Traps if no marker with that
    /// id sits at that offset — a caller mismatching the two is a programmer error, the same
    /// convention `Rope`'s own offset preconditions use throughout this module. Implemented
    /// as `removingIfPresent` plus the trap, so the tie-group search exists once
    /// (`dev/specs/m1.5.md` deliverable E).
    package func removing(id targetID: MarkerID, atByteOffset byteOffset: Int) -> MarkerTree {
        guard let result = removingIfPresent(id: targetID, atByteOffset: byteOffset) else {
            preconditionFailure(
                "MarkerTree.removing: no marker with id \(targetID) at byte offset \(byteOffset)")
        }
        return result
    }

    /// Like `removing(id:atByteOffset:)`, but returns `nil` instead of trapping when no
    /// marker with `targetID` sits at `byteOffset` (`dev/specs/m1.5.md` 1.4 step 1: a
    /// traversal that walks a branch after the user removed one of the entry set's markers
    /// must skip it, not crash — marker removal is itself not undoable).
    package func removingIfPresent(id targetID: MarkerID, atByteOffset byteOffset: Int)
        -> MarkerTree?
    {
        var r = rank(atOrAfterKey: 2 * byteOffset)
        while r < count, position(ofRank: r) == byteOffset {
            if id(ofRank: r) == targetID {
                return removingAtRank(r)
            }
            r += 1
        }
        return nil
    }

    private func removingAtRank(_ r: Int) -> MarkerTree {
        guard let (before, removed, _, after) = tree.cut(where: { $0.count >= r + 1 }) else {
            preconditionFailure("MarkerTree.removingAtRank: rank \(r) out of range")
        }
        guard !after.isEmpty else {
            return MarkerTree(tree: before)
        }
        guard let (aBefore, aItem, _, aAfter) = after.cut(where: { $0.count >= 1 }) else {
            preconditionFailure("MarkerTree.removingAtRank: cut on a non-empty tail failed")
        }
        precondition(
            aBefore.isEmpty, "MarkerTree.removingAtRank: rank-0 cut left a non-empty prefix")
        let rebased = SumTree<MarkerRecord>(
            items: [MarkerRecord(gap: aItem.gap + removed.gap, id: aItem.id)])
        return MarkerTree(tree: SumTree.concat(before, SumTree.concat(rebased, aAfter)))
    }

    // MARK: - Invariants

    /// Checks the underlying `SumTree`'s own structural invariants, plus what it cannot see
    /// on its own: no negative gap, and non-decreasing absolute keys (equivalently: rank
    /// order agrees with key order, including the parity/bias dimension, since a key
    /// encodes both).
    package func checkInvariants() throws {
        try tree.checkInvariants()
        var violations: [String] = []
        var previousKey = 0
        for item in tree.items() {
            if item.gap < 0 {
                violations.append("negative gap \(item.gap) for marker id \(item.id)")
            }
            let key = previousKey + item.gap
            if key < previousKey {
                violations.append(
                    "marker id \(item.id) has key \(key), less than the previous marker's \(previousKey)"
                )
            }
            previousKey = key
        }
        if tree.summary.span != previousKey {
            violations.append(
                "tree summary span \(tree.summary.span) does not match the last marker's key \(previousKey)"
            )
        }
        if !violations.isEmpty {
            throw SumTreeInvariantViolation(messages: violations)
        }
    }

    // MARK: - Test-only affordances

    /// Test-only: exposes the internal `SumTree` itself so a test can walk its actual node
    /// structure and count how many nodes one `applyEdit`'s underlying `pathCopyEdit` descent
    /// visits — the follow-up to M1.3's "adjust every marker is O(log n)" claim, whose only
    /// evidence was a node-visit count taken in a throwaway worktree (`PLAN.md`'s M1.3
    /// record). `internal`, not `private`: `@testable import Text` upgrades this to visible
    /// from `Tests/TextTests/markerTreeTests.swift`, the same convention this module already
    /// uses for test-only affordances elsewhere (`SumTree.init(root:)`, `Rope.
    /// tryLeafLocalReplace`) — a plain accessor rather than a counting mechanism itself, so
    /// the counting logic (and its proof that it walks the same path `pathCopyEditNode`
    /// would) lives entirely in the test, not here.
    internal var testOnlySumTree: SumTree<MarkerRecord> { tree }

    // MARK: - applyEdit

    /// The one operation the milestone is judged on (`dev/specs/m1.3.md` section 2.B) —
    /// **implemented as the two-stage composition this file's header derives and justifies
    /// against the GNU oracle**, not the single fused pass the spec's table describes (which
    /// does not reproduce that oracle — see the header for the full derivation).
    ///
    /// Stage 1 (skipped entirely when `byteRange` is empty — a pure insertion needs no
    /// delete/collapse step at all): `applyDeleteAndCollapse` folds `insertedLength` to zero
    /// in the spec's own row table, exactly the shape the `marker-inside-del`/`del-with-
    /// type-t` oracle rows check (see `markerTreeTests.swift`), and is correct on its own —
    /// neither of those rows involves a following insertion.
    ///
    /// Stage 2 (skipped entirely when `insertedLength == 0` — a pure deletion needs no
    /// insertion-boundary step): one single-item shift at the insertion's own boundary,
    /// `B = 2 * lo` when `insertBeforeMarkers` else `2 * lo + 1`, by `2 * insertedLength` —
    /// exactly `shiftingSingleItem`'s existing machinery, the same the pure-insertion case
    /// always needed. Because a pure insertion is `byteRange` empty (stage 1 a no-op) plus
    /// this stage, this composition also *retires* pure insertion as a special case: it falls
    /// out of the general composition rather than needing its own branch.
    ///
    /// Complexity: a pure insertion is exactly stage 2 alone — one `rank`/`find` plus one
    /// `pathCopyEdit`, O(log n), the path `markerTreePerfTests.swift`'s headline benchmark
    /// measures. A pure deletion is exactly stage 1 alone — O(log n) when no marker sits in
    /// the collapsed range, O(k + log n) when k do, the path that same file's collapse
    /// benchmark measures. A true replace (both non-empty `byteRange` and `insertedLength >
    /// 0`) costs the sum of both, which `dev/specs/m1.3.md` section 2.B does not itself
    /// benchmark.
    package func applyEdit(
        byteRange: Range<Int>, insertedLength: Int, insertBeforeMarkers: Bool = false
    ) -> MarkerTree {
        precondition(
            byteRange.lowerBound >= 0 && byteRange.lowerBound <= byteRange.upperBound,
            "MarkerTree.applyEdit: invalid byteRange \(byteRange)")
        precondition(insertedLength >= 0, "MarkerTree.applyEdit: negative insertedLength")
        let lo = byteRange.lowerBound
        let hi = byteRange.upperBound
        let afterDelete = lo == hi ? self : applyDeleteAndCollapse(lo: lo, hi: hi)
        guard insertedLength > 0 else { return afterDelete }
        let boundary = insertBeforeMarkers ? 2 * lo : 2 * lo + 1
        return afterDelete.shiftingSingleItem(atOrAfterKey: boundary, by: 2 * insertedLength)
    }

    /// Adds `delta` to the gap of the single item at or after `boundary`, which propagates
    /// to every later item's absolute key for free (see this file's header on gap encoding).
    /// `pathCopyEdit` is its own guard here, so there is no separate rank check: it returns
    /// `nil` when its predicate is never true of the tree's total (`SumTree.swift:914`'s doc
    /// comment and its `return nil`), which is exactly the "no marker at or after the
    /// boundary" case, and the `guard let` below turns that into an untouched `self`. An
    /// earlier revision also called `rank(atOrAfterKey:)` first; the mutation pass found that
    /// guard survived deletion with every test still passing, and reading `pathCopyEdit`
    /// confirmed why — it was redundant, and it cost a second full O(log n) descent on the
    /// one path every edit takes. `dev/specs/m1.3.md` section 0's precondition 2 is about
    /// `SumTreeCursor.seek`, which *does* trap and is guarded where it is used, in
    /// `markers(in:)`.
    private func shiftingSingleItem(atOrAfterKey boundary: Int, by delta: Int) -> MarkerTree {
        guard delta != 0 else { return self }
        let predicate: (MarkerSummary) -> Bool = { $0.count > 0 && $0.span >= boundary }
        guard
            let newTree = tree.pathCopyEdit(
                where: predicate,
                edit: { items, index, _ in
                    var newItems = items
                    newItems[index].gap += delta
                    return newItems
                })
        else {
            return self
        }
        return MarkerTree(tree: newTree)
    }

    /// Stage 1 of `applyEdit`: the spec's own row table (`dev/specs/m1.3.md` section 2.B)
    /// with `L` folded to 0 — `Δ = -2 * (hi - lo)`. Markers with key `< 2*lo + 2` (offset
    /// `<= lo`) are untouched; markers with key in `[2*lo + 2, 2*hi + 1]` (offset in
    /// `(lo, hi]`) collapse to `lo`, keeping their own bias; markers with key `>= 2*hi + 2`
    /// (offset `> hi`) shift by `Δ`.
    ///
    /// **The collapse group is widened to `[2*lo, 2*hi + 1]`, not `[2*lo + 2, 2*hi + 1]`** —
    /// this is the "related correction" this file's header derives algebraically: any marker
    /// already sitting exactly at `lo` (either bias) must be repartitioned together with the
    /// markers collapsing in from inside the range, because otherwise a newly-collapsed
    /// `.left` marker (new key `2*lo`) can land, in tree order, *after* an already-resident
    /// `.right` marker at `lo` (key `2*lo + 1`) that a narrower group leaves untouched in
    /// `beforeGroup` — violating the tree's non-decreasing-key invariant. Proof this cannot
    /// happen with the widened group: `beforeGroup` then holds only keys `< 2*lo` strictly,
    /// so `leftSpan = beforeGroup.summary.span < 2*lo`, giving the first rewritten item a
    /// strictly positive gap either way (`2*lo - leftSpan >= 1`, or `2*lo+1 - leftSpan >= 2`
    /// if the `.left` bucket is empty). This does not change the result when no marker is
    /// already at `lo` (the common case): `rank(atOrAfterKey: 2*lo)` then equals
    /// `rank(atOrAfterKey: 2*lo+2)`, so the group is identical to the narrower one.
    ///
    /// Two paths, exactly as the spec names them: no marker in the (unwidened) collapse
    /// range `[2*lo+2, 2*hi+1]` is the fast path (one `pathCopyEdit`, O(log n) — this is also
    /// exactly the path a pure deletion with no markers inside it takes); otherwise the k
    /// markers in the range are extracted, stably partitioned by bias (preserving each
    /// sub-group's original relative order — the "stable" part is what
    /// `markerTreeTests.swift`'s tie-order test checks), rewritten with keys `2*lo`/`2*lo+1`,
    /// and the tail's first gap is rebased by `Δ` (O(k + log n), inherent under the
    /// no-retained-history constraint — see `dev/specs/m1.3.md` section 2.B). Proof neither
    /// rewrite ever produces a negative gap is in the implementer's report, not restated
    /// here at each step; the randomised property test's `checkInvariants()` cadence is the
    /// standing check.
    private func applyDeleteAndCollapse(lo: Int, hi: Int) -> MarkerTree {
        precondition(lo < hi, "MarkerTree.applyDeleteAndCollapse: requires lo < hi")
        let delta = -2 * (hi - lo)
        let collapseLow = 2 * lo + 2
        let collapseHigh = 2 * hi + 1
        let shiftBoundary = 2 * hi + 2

        let firstCollapseRank = rank(atOrAfterKey: collapseLow)
        let needsCollapse =
            firstCollapseRank < count && key(ofRank: firstCollapseRank) <= collapseHigh
        guard needsCollapse else {
            return shiftingSingleItem(atOrAfterKey: shiftBoundary, by: delta)
        }

        // Widened group: see this function's doc comment for why the start is `2*lo`, not
        // `collapseLow`.
        let groupStartRank = rank(atOrAfterKey: 2 * lo)
        let groupEndRank = rank(atOrAfterKey: collapseHigh + 1)
        let (beforeGroup, groupPlusRest) = tree.split(where: { $0.count >= groupStartRank })
        let (group, afterGroup) = groupPlusRest.split(where: {
            $0.count >= (groupEndRank - groupStartRank)
        })

        let leftSpan = beforeGroup.summary.span
        var absoluteKey = leftSpan
        var withKey: [(id: MarkerID, key: Int)] = []
        for item in group.items() {
            absoluteKey += item.gap
            withKey.append((id: item.id, key: absoluteKey))
        }
        guard let originalGroupLastKey = withKey.last?.key else {
            preconditionFailure(
                "MarkerTree.applyDeleteAndCollapse: collapse group unexpectedly empty")
        }

        // Stable filter: `Array.filter` preserves the original relative order of the
        // elements it keeps, which is what makes this partition stable — mutation focus
        // (`dev/specs/m1.3.md` section 6, item 5): sorting instead would still put every
        // marker at the right *position*, only scrambling the id order within a tie group.
        let leftBias = withKey.filter { $0.key & 1 == 0 }
        let rightBias = withKey.filter { $0.key & 1 == 1 }

        var newGroupRecords: [MarkerRecord] = []
        newGroupRecords.reserveCapacity(withKey.count)
        var previousKey = leftSpan
        for entry in leftBias {
            newGroupRecords.append(MarkerRecord(gap: 2 * lo - previousKey, id: entry.id))
            previousKey = 2 * lo
        }
        for entry in rightBias {
            newGroupRecords.append(MarkerRecord(gap: (2 * lo + 1) - previousKey, id: entry.id))
            previousKey = 2 * lo + 1
        }
        let newGroupTree = SumTree<MarkerRecord>(items: newGroupRecords)

        var finalAfterGroup = afterGroup
        if !afterGroup.isEmpty {
            guard let (tBefore, tailItem, _, tAfter) = afterGroup.cut(where: { $0.count >= 1 })
            else {
                preconditionFailure(
                    "MarkerTree.applyDeleteAndCollapse: cut on a non-empty tail failed")
            }
            precondition(
                tBefore.isEmpty,
                "MarkerTree.applyDeleteAndCollapse: rank-0 cut left a non-empty prefix"
            )
            let originalTailFirstKey = originalGroupLastKey + tailItem.gap
            let newTailFirstKey = originalTailFirstKey + delta
            let rebasedGap = newTailFirstKey - previousKey
            let rebasedItem = SumTree<MarkerRecord>(
                items: [MarkerRecord(gap: rebasedGap, id: tailItem.id)])
            finalAfterGroup = SumTree.concat(rebasedItem, tAfter)
        }

        let merged = SumTree.concat(beforeGroup, SumTree.concat(newGroupTree, finalAfterGroup))
        return MarkerTree(tree: merged)
    }
}
