/// The interval tree for overlays (M1.4, `dev/specs/m1.4.md`): intervals stored gap-encoded
/// in a `SumTree<IntervalRecord>`, ordered by **start**, with an augmented `maxEnd` summary
/// dimension supporting an overlap query. `MarkerTree` is the template this follows (same
/// gap-encoding trick, same "never expose the underlying `SumTree`" rule, same delete-then-
/// insert edit composition); the differences from it are in the encoding (a length rather
/// than a second doubled-key dimension) and in the query (three searches, not one cursor
/// walk) — see this file's header sections below and `dev/specs/m1.4.md` sections 1.1-1.7
/// for the full derivation.
///
/// **The encoding (`dev/specs/m1.4.md` 1.1).** `IntervalRecord.gap` is this item's start
/// minus the previous item's start (never negative); `length` is `end - start` (never
/// negative), stored directly rather than as a second gap, because an interval's end moves
/// for free whenever its start does (`end = start + length`) — only intervals whose *extent*
/// genuinely changes (the ones straddling an edit point) need a `length` edit at all.
///
/// **The augmented summary (`dev/specs/m1.4.md` 1.2).** `maxEnd` is the maximum end among the
/// items summarised, measured **relative to the base of the range it summarises** — the same
/// reason the start is gap-encoded rather than absolute: an absolute `maxEnd` would have to be
/// rewritten in every summary on the path for a shift that changes no item, while a relative
/// one is shift-invariant. `IntervalSummary`'s `+` is the standard affine-max composition;
/// `checkInvariants()` asserts `maxEnd >= span` on every node, the invariant the right
/// identity law needs — see `dev/specs/m1.4.md` 1.2 for the algebraic proof.
///
/// **The query is three searches (`dev/specs/m1.4.md` 1.6), not one traversal.** The obvious
/// single-traversal shape, pruning on `maxEnd >= lo`, does not have the complexity the design
/// promises: `M` intervals all ending at the same point make it O(n) even when the query
/// returns nothing, because their starts are scattered across every rank and no single prune
/// threshold catches that. The result set instead splits into three independently efficient
/// pieces (`intervals(overlapping:includingEmptyAtUpperBound:)` implements all three):
///
/// 1. Starts inside `[lo, hi)` — rank-contiguous, one descent then a cursor scan; every item
///    found is a result with no further filtering needed.
/// 2. Straddlers (`start < lo < end`) — the only piece that needs the augmented summary, and
///    the prune here is **strict** (`maxEnd > lo`), restricted to the rank prefix before piece
///    1's first item, which is what makes every visited node yield a result.
/// 3. The empty interval exactly at `hi`, when `lo == hi` or `hi` is the buffer's end (the
///    caller's fact, not this type's — see `IntervalSpan`/`BufferSnapshot.intervals(
///    overlapping:)` below).
///
/// **The edit rule (`dev/specs/m1.4.md` 1.4-1.5) is a delete-then-insert composition**,
/// exactly as `MarkerTree.applyEdit` is (M1.3's finding, re-verified here against the
/// oracle): GNU has no atomic "replace" primitive, so `applyEdit` runs the deletion rule and
/// then the insertion rule in sequence, never a single fused delta. The insertion rule needs
/// a clamp GNU's own docstring does not mention: an empty interval sitting exactly at the
/// insertion point with `frontAdvance` but neither `rearAdvance` nor `insertBeforeMarkers`
/// does **not** move — moving it would invert the interval (`start > end`), and the tree's
/// gap/length encoding has no representation for a moved-start-only endpoint to invert in
/// the first place, so the clamp is folded directly into the `startMoves` predicate rather
/// than applied after the fact. See `applyEdit`'s own doc comment for the two-stage
/// composition and `startMoves`'s doc comment for the predicate form (`endMoves` is not a
/// separate function here — straddlers, the `endMoves && !startMoves` case, are found
/// directly by `start < p < end` in `applyInsert`, since that is a simpler equivalent
/// restatement once `startMoves` is known false for them).
///
/// **`applyInsert`'s straddler search costs O(log n + k + e), not O(log n + k)**, where `e`
/// is the number of intervals whose end is exactly the insertion offset — a non-strict prune
/// this milestone accepts rather than removes, because the alternative (a strict prune) would
/// silently drop the `length` update an item needs when its end sits exactly on the insertion
/// point with `rearAdvance`. See `visitEndAtOrAfterInclusive`'s doc comment for the full
/// derivation and for the fix not built here (a second augmented dimension over only the
/// `rearAdvance` population); `PLAN.md`'s cost row for this operation is the main
/// conversation's to write from that note, not this implementer's.
///
/// **Known gaps** (`dev/specs/m1.4.md` section 8):
/// - Identity lookup (`removing(id:startingAt:)` aside) is O(n) without the caller's start
///   offset; M5 owns the identity index (`dev/specs/m1.3.md` section 3's obstruction, unchanged
///   for intervals: an edit is contiguous in position order and an arbitrary subset in ID
///   order).
/// - Text properties are not here yet — no Lisp values exist until M2 — but the tree is
///   shaped to hold them alongside overlays (`PLAN.md` 4.5), and the stickiness oracle
///   (default rear-sticky/not-front-sticky, the opposite polarity from an overlay's default)
///   is recorded in `dev/specs/m1.4.md` section 3 so M5 does not have to rediscover it.
/// - A snapshot is a value, so forking one and editing both branches reuses interval IDs —
///   the same gap `MarkerTree` records; M1.5's branching undo owns the allocation story.
/// - Dropping a large interval tree is O(n) in distinct nodes, paid by whoever releases the
///   last reference (`PLAN.md` 4.5's "Close a large buffer" row).
/// - Interval endpoints must be UTF-8 scalar boundaries; the precondition lives in
///   `BufferSnapshot.createInterval`, exactly like `MarkerTree`'s own scalar-boundary
///   precondition, and is untestable in-process for the same reason (`MarkerTree.swift`'s
///   header): it needs an out-of-process crash harness this project does not have.

/// An interval's identity: monotone, never reused — allocation is `BufferSnapshot`'s job
/// (`createInterval`), matching `MarkerID`'s own convention (`MarkerTree.swift:123-126`).
package typealias IntervalID = UInt64

/// `IntervalRecord`'s summary. `count` is the order-statistic dimension (a prefix `count` is
/// a rank); `span` is the prefix-sum dimension (a prefix `span` is the previous item's
/// absolute start, so an item's own `gap` folds up to its absolute start once the running
/// total is added — see `IntervalTree.start(ofRank:)`); `maxEnd` is the augmented dimension
/// this file's header derives, relative to the base of the range it summarises.
package struct IntervalSummary: Summary {
    package var count: Int
    package var span: Int
    package var maxEnd: Int

    package init(count: Int, span: Int, maxEnd: Int) {
        self.count = count
        self.span = span
        self.maxEnd = maxEnd
    }

    package static var identity: IntervalSummary { IntervalSummary(count: 0, span: 0, maxEnd: 0) }

    package static func + (lhs: IntervalSummary, rhs: IntervalSummary) -> IntervalSummary {
        IntervalSummary(
            count: lhs.count + rhs.count,
            span: lhs.span + rhs.span,
            maxEnd: max(lhs.maxEnd, lhs.span + rhs.maxEnd))
    }
}

/// One interval, gap-encoded: `gap` is this item's start minus the previous item's start (or
/// minus zero, for the tree's first item) — never negative, checked by
/// `IntervalTree.checkInvariants()`. `length` is `end - start` — never negative, stored
/// directly rather than gap-encoded, per this file's header. Plain `package` types, not
/// promoted for cross-module inlining, matching `MarkerRecord`'s own note
/// (`MarkerTree.swift:154-156`) — nothing here is on a measured hot cross-module path
/// (`dev/specs/m1.4.md` section 3).
package struct IntervalRecord: Sendable, Equatable {
    package var gap: Int
    package var length: Int
    package var id: IntervalID
    package var frontAdvance: Bool
    package var rearAdvance: Bool

    package init(gap: Int, length: Int, id: IntervalID, frontAdvance: Bool, rearAdvance: Bool) {
        self.gap = gap
        self.length = length
        self.id = id
        self.frontAdvance = frontAdvance
        self.rearAdvance = rearAdvance
    }
}

extension IntervalRecord: Summable {
    package typealias Item_Summary = IntervalSummary
    package var summary: IntervalSummary {
        IntervalSummary(count: 1, span: gap, maxEnd: gap + length)
    }
}

/// One interval as a query result: its absolute range plus everything a caller needs to act
/// on it (`id` to resolve the overlay/text-property object once M2 exists; the two advance
/// flags because a caller applying a further edit by hand — there is none yet, but
/// `applyEdit` itself needs exactly these fields — needs them to repeat the endpoint rule).
package struct IntervalSpan: Sendable, Equatable {
    package var range: Range<Int>
    package var id: IntervalID
    package var frontAdvance: Bool
    package var rearAdvance: Bool

    package init(range: Range<Int>, id: IntervalID, frontAdvance: Bool, rearAdvance: Bool) {
        self.range = range
        self.id = id
        self.frontAdvance = frontAdvance
        self.rearAdvance = rearAdvance
    }
}

/// The interval tree itself. Wraps a `SumTree<IntervalRecord>` and never exposes it — gaps
/// are relative, so a bare `concat` is not interval-safe on its own, exactly as
/// `MarkerTree.swift`'s header explains for its own wrapped tree. The one exception is
/// `testOnlySumTree`, `internal` (not `package`) for the same reason `MarkerTree`'s own
/// escape hatch is: visible only via `@testable import Text`.
package struct IntervalTree: Sendable {
    private var tree: SumTree<IntervalRecord>

    private init(tree: SumTree<IntervalRecord>) {
        self.tree = tree
    }

    package init() {
        self.tree = SumTree<IntervalRecord>()
    }

    /// Bulk build (O(n)): `sortedIntervals` must already be in non-decreasing start order,
    /// which this preconditions rather than sorts — mirroring `MarkerTree.init(sortedMarkers:)`
    /// (`:196`).
    package init(
        sortedIntervals: [(
            range: Range<Int>, id: IntervalID, frontAdvance: Bool, rearAdvance: Bool
        )]
    ) {
        var items: [IntervalRecord] = []
        items.reserveCapacity(sortedIntervals.count)
        var previousStart = 0
        for (index, interval) in sortedIntervals.enumerated() {
            precondition(
                interval.range.lowerBound >= 0,
                "IntervalTree.init(sortedIntervals:): negative start at index \(index)")
            precondition(
                interval.range.lowerBound <= interval.range.upperBound,
                "IntervalTree.init(sortedIntervals:): inverted range at index \(index)")
            let start = interval.range.lowerBound
            precondition(
                start >= previousStart,
                "IntervalTree.init(sortedIntervals:): input not in non-decreasing start order at index \(index)"
            )
            items.append(
                IntervalRecord(
                    gap: start - previousStart, length: interval.range.count, id: interval.id,
                    frontAdvance: interval.frontAdvance, rearAdvance: interval.rearAdvance))
            previousStart = start
        }
        self.tree = SumTree<IntervalRecord>(items: items)
    }

    package var count: Int { tree.summary.count }
    package var isEmpty: Bool { tree.isEmpty }

    // MARK: - Rank-indexed queries

    /// The absolute start of the interval at 0-based rank `r`, via `SumTree.find`'s `>`
    /// convention — matching `MarkerTree.key(ofRank:)`'s own convention for the same reason.
    private func record(ofRank r: Int) -> (record: IntervalRecord, absoluteStart: Int) {
        precondition(r >= 0 && r < count, "IntervalTree.record(ofRank:): rank \(r) out of bounds")
        guard let (item, itemPrefix) = tree.find(where: { $0.count > r }) else {
            preconditionFailure("IntervalTree.record(ofRank:): rank \(r) not found")
        }
        return (item, itemPrefix.span + item.gap)
    }

    package func start(ofRank r: Int) -> Int { record(ofRank: r).absoluteStart }
    package func end(ofRank r: Int) -> Int {
        let (item, absoluteStart) = record(ofRank: r)
        return absoluteStart + item.length
    }
    package func id(ofRank r: Int) -> IntervalID { record(ofRank: r).record.id }

    package func span(ofRank r: Int) -> IntervalSpan {
        let (item, absoluteStart) = record(ofRank: r)
        return IntervalSpan(
            range: absoluteStart..<(absoluteStart + item.length), id: item.id,
            frontAdvance: item.frontAdvance, rearAdvance: item.rearAdvance)
    }

    /// The order statistic: the rank of the first interval whose start is `>= x`, or `count`
    /// when nothing qualifies. Guarded exactly as `MarkerTree.rank(atOrAfterKey:)` is (its own
    /// doc comment explains why the `count > 0` clause is needed to avoid tripping `find`'s
    /// `predicate(.identity)` precondition at `x == 0`). **`package`, not `private`**
    /// (`dev/specs/m1.5.md` deliverable E): the undo entry-set query below is built from this
    /// plus `endAtOrAfterDescendPredicate` (already `internal`), and a test wraps the real
    /// function rather than copying it, per this module's standing convention.
    package func rank(startAtOrAfter x: Int) -> Int {
        guard let (_, itemPrefix) = tree.find(where: { $0.count > 0 && $0.span >= x }) else {
            return count
        }
        return itemPrefix.count
    }

    // MARK: - Overlap query (`dev/specs/m1.4.md` 1.6)

    /// Every interval overlapping `byteRange` under GNU's `overlays-in` rule
    /// (`dev/specs/m1.4.md` 1.7): a non-empty interval is included iff `end > lo && start <
    /// hi`; an empty interval at `s` is included iff `lo <= s < hi`, or `s == hi` and
    /// `includingEmptyAtUpperBound` (the caller's fact — `lo == hi`, or `hi` is the buffer's
    /// end — since this type holds no text of its own; see `BufferSnapshot.intervals(
    /// overlapping:)`).
    ///
    /// Three independent searches, not one traversal — see this file's header and
    /// `dev/specs/m1.4.md` 1.6 for why a single `maxEnd`-pruned walk cannot deliver
    /// `O(log n + k)`.
    package func intervals(
        overlapping byteRange: Range<Int>, includingEmptyAtUpperBound: Bool
    ) -> [IntervalSpan] {
        let lo = byteRange.lowerBound
        let hi = byteRange.upperBound
        var results: [IntervalSpan] = []
        var seenIDs: Set<IntervalID> = []

        // Piece 1: starts inside [lo, hi). Rank-contiguous: one seek (one `find`, O(log n)),
        // then a cursor scan of O(k) steps. The running absolute start is reconstructed from
        // each item's **own** `gap` field as the cursor hands it back — not a second `find`
        // per step (`record(ofRank:)`/`start(ofRank:)` inside the loop, which an earlier
        // version of this function did via a `nextGap(afterRank:)` helper, making this O(k
        // log n) instead of O(log n + k); see the implementer's fix-round report). Only the
        // very first item's absolute start needs a `find` — every later item's own `gap` is
        // exactly the delta from the previous item's start to its own, by construction (this
        // file's header).
        let firstInRangeRank = rank(startAtOrAfter: lo)
        if firstInRangeRank < count {
            var walkCursor = tree.makeCursor()
            walkCursor.seek(where: { $0.count > firstInRangeRank })
            var absoluteStart = start(ofRank: firstInRangeRank)
            var isFirstItem = true
            while let item = walkCursor.next() {
                if !isFirstItem {
                    absoluteStart += item.gap
                }
                isFirstItem = false
                guard absoluteStart < hi else { break }
                results.append(
                    IntervalSpan(
                        range: absoluteStart..<(absoluteStart + item.length), id: item.id,
                        frontAdvance: item.frontAdvance, rearAdvance: item.rearAdvance))
                seenIDs.insert(item.id)
            }
        }

        // Piece 2: straddlers (start < lo < end), restricted to the rank prefix strictly
        // before piece 1's first item. Strict prune `maxEnd > lo`.
        if firstInRangeRank > 0 {
            visitStraddlers(upperRankExclusive: firstInRangeRank, lo: lo) { absoluteStart, item in
                guard absoluteStart < lo, absoluteStart + item.length > lo else { return }
                guard !seenIDs.contains(item.id) else { return }
                results.append(
                    IntervalSpan(
                        range: absoluteStart..<(absoluteStart + item.length), id: item.id,
                        frontAdvance: item.frontAdvance, rearAdvance: item.rearAdvance))
                seenIDs.insert(item.id)
            }
        }

        // Piece 3: the empty interval at `hi`, when the caller says it counts. Also a tie
        // group, also rank-contiguous — same reconstruction-from-the-item's-own-gap shape as
        // piece 1 above, for the same O(log n + k) reason.
        if includingEmptyAtUpperBound {
            let firstAtHiRank = rank(startAtOrAfter: hi)
            if firstAtHiRank < count {
                var walkCursor = tree.makeCursor()
                walkCursor.seek(where: { $0.count > firstAtHiRank })
                var absoluteStart = start(ofRank: firstAtHiRank)
                var isFirstItem = true
                while let item = walkCursor.next() {
                    if !isFirstItem {
                        absoluteStart += item.gap
                    }
                    isFirstItem = false
                    guard absoluteStart == hi else { break }
                    if item.length == 0, !seenIDs.contains(item.id) {
                        results.append(
                            IntervalSpan(
                                range: absoluteStart..<absoluteStart, id: item.id,
                                frontAdvance: item.frontAdvance, rearAdvance: item.rearAdvance))
                        seenIDs.insert(item.id)
                    }
                }
            }
        }

        return results
    }

    /// The strict straddler prune (`dev/specs/m1.4.md` 1.6): every subtree surviving `maxEnd
    /// > lo` (relative to `prefix`, so `prefix.span + subtree.maxEnd` is the absolute maximum
    /// end summarised) holds an item with `end > lo`. `internal`, not `private`, and factored
    /// out to a **single, shared** function rather than inlined at each of its two call sites
    /// (the query's piece 2, `visitStraddlers`, and the delete stage's straddler search,
    /// `visitStraddlersInclusive`) for exactly one reason: so a counted test
    /// (`intervalTreeTests.swift`) can wrap this same function in a counting closure and feed
    /// it to the real `SumTree.visitItems` directly, rather than hand-copying the formula into
    /// the test. A hand-copied replica proves nothing about a regression here — relaxing this
    /// prune from `>` to `>=` changed no *result* in any test before this factoring (every
    /// correctness test still passed), and the test that hand-copied the formula to count
    /// visits was, unknowingly, immune to that exact regression because it was counting its
    /// own copy, not this one (`dev/specs/m1.4.md` section 6, mutation 7b — "only counting can
    /// see it", true only when what is counted is this function itself).
    internal static func straddlerDescendPredicate(
        lo: Int
    ) -> (IntervalSummary, IntervalSummary) -> Bool {
        { prefix, subtree in prefix.span + subtree.maxEnd > lo }
    }

    /// Piece 2 of the overlap query: visits every item in ranks `[0, upperRankExclusive)`
    /// whose end exceeds `lo`, via `SumTree.visitItems` pruning on `straddlerDescendPredicate`
    /// (`dev/specs/m1.4.md` 1.6) — every subtree entirely at or before rank
    /// `upperRankExclusive` and with no item ending after `lo` is skipped whole.
    private func visitStraddlers(
        upperRankExclusive: Int, lo: Int,
        handle: (_ absoluteStart: Int, _ item: IntervalRecord) ->
            Void
    ) {
        let prune = Self.straddlerDescendPredicate(lo: lo)
        tree.visitItems(
            descendInto: { prefix, subtree in
                guard prefix.count < upperRankExclusive else { return false }
                return prune(prefix, subtree)
            },
            visit: { prefix, item in
                guard prefix.count < upperRankExclusive else { return false }
                let absoluteStart = prefix.span + item.gap
                handle(absoluteStart, item)
                return true
            })
    }

    /// `overlays-at P`: `start <= P < end` — excludes empty intervals and anything ending
    /// exactly at `P` (`dev/specs/m1.4.md` 1.7). Reuses the same three-piece machinery as
    /// `intervals(overlapping:includingEmptyAtUpperBound:)` by querying the degenerate range
    /// `[P, P+1)` (which piece 1 alone can answer completely: only a *non-empty* interval
    /// containing byte `P` qualifies, and any such interval has `start <= P < end`) then
    /// filtering to non-empty. `includingEmptyAtUpperBound: false`, since `overlays-at` never
    /// includes an empty interval.
    package func intervals(at byteOffset: Int) -> [IntervalSpan] {
        intervals(overlapping: byteOffset..<(byteOffset + 1), includingEmptyAtUpperBound: false)
            .filter { !$0.range.isEmpty }
    }

    // MARK: - Undo entry-set query (`dev/specs/m1.5.md` 1.3-1.4)

    /// Every interval with an endpoint in the closed `[lo, upperInclusive]` — the set an undo
    /// traversal must remove-then-reinsert around a live edit, derived in `dev/specs/m1.5.md`
    /// 1.3. Two independent pieces, both reusing existing machinery rather than a new
    /// traversal:
    ///
    /// - **Starts in `[lo, upperInclusive]`** — a rank-contiguous range via
    ///   `rank(startAtOrAfter:)`, walked exactly as `intervals(overlapping:
    ///   includingEmptyAtUpperBound:)`'s piece 1 already does.
    /// - **Ends at or after `lo`, among intervals starting before `lo`** — the same
    ///   non-strict `visitEndAtOrAfterInclusive` search `applyInsert` uses, restricted to the
    ///   rank prefix before the first piece's start.
    ///
    /// This is deliberately a **superset** of the rows 1.3 derives as needing an entry (it
    /// also returns row 4's containers, whose position is unaffected by the edit and so need
    /// no entry either way — 1.3 explains why a superset is the safe direction here, unlike
    /// the marker case where the two-query shape already matches exactly).
    ///
    /// **The second piece needs a per-item filter, and its qualifying starts need
    /// tie-group closure — a fix round found both missing.** `visitEndAtOrAfterInclusive`'s
    /// prune (`endAtOrAfterDescendPredicate`) is subtree/leaf granularity
    /// (`prefix.span + subtree.maxEnd >= p`); `SumTree.visitNode`'s leaf case then calls
    /// `visit` for **every item in that leaf**, so without a per-item `end >= lo` guard the
    /// entry set depends on B+-tree leaf packing — measured on this machine, a 200-byte
    /// buffer with 40 one-byte intervals plus one straddler recorded ids `[34...40]` for an
    /// edit whose only qualifying end was `40`, purely because those six shared a leaf with
    /// it. Filtering alone is not enough either: two intervals can share a start below `lo`
    /// while differing in end, so one qualifies for the end search and the other does not —
    /// 1.4 step 3's "the whole tie group is always inside the entry set" argument is written
    /// for markers and is false here, and without closure the survivor stays in the tree
    /// while the reinserted one is prepended in front of it, silently reversing tie order on
    /// undo (measured: two intervals sharing start `0`, `undoEntrySet` returning only the
    /// one found by the end search, reversed the pair's order after an undo). So this piece
    /// walks in two steps: filter the end search's items to `absoluteStart + item.length >=
    /// lo`, collect the **distinct starts** it names (in the order found — ascending, since
    /// the walk is in rank order), then for each such start pull the **whole** tie group via
    /// `rank(startAtOrAfter:)`/`rank(startAtOrAfter: start + 1)`, the same rank-window walk
    /// piece 1 already does. **The cost is O(v + g log n + G)**, where `v` is the items the
    /// pruned end search visits — the `e` term this file's header already names for
    /// `applyInsert`, and what the leaf-packing measurement above is about, since a leaf that
    /// passes the prune is visited whole — `g` is the distinct qualifying starts that search
    /// names, and `G` the items in their tie groups. (`v`, not `m`: this file already spends
    /// `m` on a tie group's size in `removing`'s cost note, and `PLAN.md` spends it on the tie
    /// group at an insertion point.) Per start: two rank searches and a fresh cursor
    /// descent per start, plus one step per item returned. A review round caught an earlier
    /// version of this sentence stating only the closure loop's `g log n + G` as though it
    /// were the whole piece's cost. It is *not* the single tie group `applyInsert` pays for at its
    /// one insertion point — a review round caught this comment claiming that equivalence, and
    /// `g` is not bounded by one: `N` intervals with distinct starts all ending at the same
    /// offset make every one of them a qualifying start for an edit at that offset.
    ///
    /// **Order**: the two pieces cannot tie with each other — the second piece's items all
    /// have `start < lo` strictly (it is restricted to ranks before the first piece's start),
    /// so no reinserted item from one piece shares a key with one from the other. Within the
    /// first piece, and within each tie group the second piece closes over, the walk is in
    /// the tree's own rank order, which is what `dev/specs/m1.5.md` 1.4 step 3's
    /// reverse-iteration reinsertion needs to reconstruct a tie group exactly.
    ///
    /// **Stability across the edit**, so the before- and after-queries return the same id set
    /// (test 13's invariant): every group this closes over has a start `< lo`, and both the
    /// marker and interval delete/insert rules leave starts below `lo` untouched and never
    /// move a start from `>= lo` to `< lo` — so a group at a given `s < lo` has the same
    /// membership whether queried before or after the edit.
    package func undoEntrySet(lo: Int, upperInclusive: Int) -> [IntervalSpan] {
        precondition(
            lo <= upperInclusive, "IntervalTree.undoEntrySet: lo must be <= upperInclusive")
        var results: [IntervalSpan] = []
        var seenIDs: Set<IntervalID> = []

        let startRank = rank(startAtOrAfter: lo)
        let endRankExclusive = rank(startAtOrAfter: upperInclusive + 1)
        if startRank < endRankExclusive {
            var cursor = tree.makeCursor()
            cursor.seek(where: { $0.count > startRank })
            var absoluteStart = start(ofRank: startRank)
            var isFirstItem = true
            var r = startRank
            while r < endRankExclusive, let item = cursor.next() {
                if !isFirstItem {
                    absoluteStart += item.gap
                }
                isFirstItem = false
                results.append(
                    IntervalSpan(
                        range: absoluteStart..<(absoluteStart + item.length), id: item.id,
                        frontAdvance: item.frontAdvance, rearAdvance: item.rearAdvance))
                seenIDs.insert(item.id)
                r += 1
            }
        }

        if startRank > 0 {
            var qualifyingStarts: [Int] = []
            var seenStarts: Set<Int> = []
            visitEndAtOrAfterInclusive(upperRankExclusive: startRank, p: lo) {
                _, absoluteStart, item in
                guard absoluteStart + item.length >= lo else { return }
                guard !seenStarts.contains(absoluteStart) else { return }
                seenStarts.insert(absoluteStart)
                qualifyingStarts.append(absoluteStart)
            }
            for s in qualifyingStarts {
                let groupStartRank = rank(startAtOrAfter: s)
                let groupEndRankExclusive = rank(startAtOrAfter: s + 1)
                guard groupStartRank < groupEndRankExclusive else { continue }
                var cursor = tree.makeCursor()
                cursor.seek(where: { $0.count > groupStartRank })
                var absoluteStart = start(ofRank: groupStartRank)
                var isFirstItem = true
                var r = groupStartRank
                while r < groupEndRankExclusive, let item = cursor.next() {
                    if !isFirstItem {
                        absoluteStart += item.gap
                    }
                    isFirstItem = false
                    if !seenIDs.contains(item.id) {
                        results.append(
                            IntervalSpan(
                                range: absoluteStart..<(absoluteStart + item.length), id: item.id,
                                frontAdvance: item.frontAdvance, rearAdvance: item.rearAdvance))
                        seenIDs.insert(item.id)
                    }
                    r += 1
                }
            }
        }

        return results
    }

    // MARK: - Insert/remove

    /// Inserts one new interval among the existing ones — not an edit (nothing else moves).
    /// Mirrors `MarkerTree.inserting(byteOffset:bias:id:)`: splits at the rank the new start
    /// belongs at (rank-based predicate, not start-based, for the same tie-ordering reason
    /// that function's doc comment gives), then rebases the following item's gap.
    package func inserting(
        range: Range<Int>, id: IntervalID, frontAdvance: Bool, rearAdvance: Bool
    ) -> IntervalTree {
        precondition(range.lowerBound >= 0, "IntervalTree.inserting: negative start")
        let insertRank = rank(startAtOrAfter: range.lowerBound)
        let (left, right) = tree.split(where: { $0.count >= insertRank })
        let leftSpan = left.summary.span
        let newGap = range.lowerBound - leftSpan
        precondition(
            newGap >= 0,
            "IntervalTree.inserting: start \(range.lowerBound) precedes the tree's prefix span \(leftSpan)"
        )
        let newItemTree = SumTree<IntervalRecord>(items: [
            IntervalRecord(
                gap: newGap, length: range.count, id: id, frontAdvance: frontAdvance,
                rearAdvance: rearAdvance)
        ])
        var result = SumTree.concat(left, newItemTree)
        if !right.isEmpty {
            guard let (rBefore, rItem, _, rAfter) = right.cut(where: { $0.count >= 1 }) else {
                preconditionFailure("IntervalTree.inserting: cut on a non-empty tail failed")
            }
            precondition(
                rBefore.isEmpty, "IntervalTree.inserting: rank-0 cut left a non-empty prefix")
            var rebasedItem = rItem
            rebasedItem.gap = rItem.gap - newGap
            let rebased = SumTree<IntervalRecord>(items: [rebasedItem])
            result = SumTree.concat(result, SumTree.concat(rebased, rAfter))
        }
        return IntervalTree(tree: result)
    }

    /// Removes the interval `id` starting at `byteOffset` — the caller pays O(log n + tie
    /// group), not O(n), by supplying the start it already knows (`dev/specs/m1.4.md` section
    /// 3, mirroring `MarkerTree.removing(id:atByteOffset:)`'s own rationale). One `find` (the
    /// initial `rank(startAtOrAfter:)`) plus one cursor seek, then an O(m) walk over the tie
    /// group reading each candidate's `id`/`gap` straight off the cursor's own records — not
    /// `start(ofRank:)`/`id(ofRank:)` per candidate, which each cost a fresh O(log n) `find`
    /// and made this O(m log n) for a tie group of size `m` (see the implementer's fix-round
    /// report; the same shape as the O(k log n) bug the overlap query's piece 1/3 had).
    package func removing(id targetID: IntervalID, startingAt byteOffset: Int) -> IntervalTree {
        guard let result = removingIfPresent(id: targetID, startingAt: byteOffset) else {
            preconditionFailure(
                "IntervalTree.removing: no interval with id \(targetID) starting at \(byteOffset)"
            )
        }
        return result
    }

    /// Like `removing(id:startingAt:)`, but returns `nil` instead of trapping when no
    /// interval with `targetID` starts at `byteOffset` — mirroring
    /// `MarkerTree.removingIfPresent(id:atByteOffset:)` for the same reason (`dev/specs/
    /// m1.5.md` 1.4 step 1).
    package func removingIfPresent(id targetID: IntervalID, startingAt byteOffset: Int)
        -> IntervalTree?
    {
        let firstRank = rank(startAtOrAfter: byteOffset)
        guard firstRank < count else { return nil }
        var cursor = tree.makeCursor()
        cursor.seek(where: { $0.count > firstRank })
        var absoluteStart = start(ofRank: firstRank)
        var r = firstRank
        var isFirstItem = true
        while let item = cursor.next() {
            if !isFirstItem {
                absoluteStart += item.gap
            }
            isFirstItem = false
            guard absoluteStart == byteOffset else { break }
            if item.id == targetID {
                return removingAtRank(r)
            }
            r += 1
        }
        return nil
    }

    private func removingAtRank(_ r: Int) -> IntervalTree {
        guard let (before, removed, _, after) = tree.cut(where: { $0.count >= r + 1 }) else {
            preconditionFailure("IntervalTree.removingAtRank: rank \(r) out of range")
        }
        guard !after.isEmpty else {
            return IntervalTree(tree: before)
        }
        guard let (aBefore, aItem, _, aAfter) = after.cut(where: { $0.count >= 1 }) else {
            preconditionFailure("IntervalTree.removingAtRank: cut on a non-empty tail failed")
        }
        precondition(
            aBefore.isEmpty, "IntervalTree.removingAtRank: rank-0 cut left a non-empty prefix")
        var rebasedItem = aItem
        rebasedItem.gap = aItem.gap + removed.gap
        let rebased = SumTree<IntervalRecord>(items: [rebasedItem])
        return IntervalTree(tree: SumTree.concat(before, SumTree.concat(rebased, aAfter)))
    }

    // MARK: - Invariants

    package func checkInvariants() throws {
        try tree.checkInvariants()
        var violations: [String] = []
        var previousStart = 0
        for item in tree.items() {
            if item.gap < 0 {
                violations.append("negative gap \(item.gap) for interval id \(item.id)")
            }
            if item.length < 0 {
                violations.append("negative length \(item.length) for interval id \(item.id)")
            }
            let start = previousStart + item.gap
            if start < previousStart {
                violations.append(
                    "interval id \(item.id) has start \(start), less than the previous interval's \(previousStart)"
                )
            }
            previousStart = start
        }
        if tree.summary.span != previousStart {
            violations.append(
                "tree summary span \(tree.summary.span) does not match the last interval's start \(previousStart)"
            )
        }
        checkMaxEnd(tree.root, base: 0, violations: &violations)
        if !violations.isEmpty {
            throw SumTreeInvariantViolation(messages: violations)
        }
    }

    /// Checks two things `SumTree.checkInvariants()` cannot see on its own, since it knows
    /// nothing about `maxEnd`'s meaning: every node's `maxEnd >= span` (the right identity
    /// law's requirement — `dev/specs/m1.4.md` 1.2), and every node's cached `maxEnd` equals
    /// the fold of its own children/items — i.e. the same "cached summary agrees with what it
    /// summarises" check `SumTree`'s own `checkNode` does for `count`/`span`, but recomputed
    /// here in absolute terms (`base` is the absolute start immediately before this node) so
    /// the check is meaningful for a maliciously-hand-built tree, not just one built through
    /// this type's own mutators.
    ///
    /// **The interior case recomputes with explicit arithmetic, not `IntervalSummary.+`.**
    /// A first version called `+` (or, equivalently, trusted `SumTree.checkInvariants()`'s own
    /// fold, which also calls `+`) to fold children's summaries and compared the result
    /// against the cached one — which agrees with itself by construction whenever `+`'s
    /// `maxEnd` arithmetic is the thing that is wrong, so a broken combine (`dev/specs/m1.4.md`
    /// section 6, mutation 6) went uncaught at every interior level and was visible only where
    /// a leaf's cached value could be checked against raw `gap`/`length` (see the leaf case
    /// below, which was already independent). The fold here is `+`'s formula spelled out by
    /// hand instead: for each child, its `maxEnd` (relative to *its own* base) is shifted to
    /// be relative to `base` by adding the accumulated span up to that child, and the max of
    /// those shifted values across all children is the expected node `maxEnd` — the same
    /// computation `+` performs, written independently so a bug in `+` cannot cancel against
    /// itself here.
    private func checkMaxEnd(
        _ node: Node<IntervalRecord>, base: Int, violations: inout [String]
    ) {
        let summary = node.summary
        if summary.maxEnd < summary.span {
            violations.append(
                "node maxEnd \(summary.maxEnd) is less than span \(summary.span) (base \(base))")
        }
        switch node {
        case .leaf(let items, _):
            var cum = base
            var maxAbsoluteEnd = base
            var any = false
            for item in items {
                let start = cum + item.gap
                maxAbsoluteEnd = max(maxAbsoluteEnd, start + item.length)
                any = true
                cum = start
            }
            let expectedRelativeMaxEnd = any ? maxAbsoluteEnd - base : 0
            if expectedRelativeMaxEnd != summary.maxEnd {
                violations.append(
                    "leaf cached maxEnd \(summary.maxEnd) does not equal the fold of its items (expected \(expectedRelativeMaxEnd), base \(base))"
                )
            }
        case .interior(let children, _, _):
            var cum = base
            var expectedRelativeMaxEnd = 0
            var any = false
            for child in children {
                checkMaxEnd(child, base: cum, violations: &violations)
                // `child.summary.maxEnd` is relative to `cum` (the child's own base); shift
                // it to be relative to `base` by adding the span already accumulated before
                // this child, then fold with `max` across children — `+`'s formula, spelled
                // out rather than invoked.
                let childMaxEndRelativeToBase = (cum - base) + child.summary.maxEnd
                expectedRelativeMaxEnd =
                    any
                    ? max(expectedRelativeMaxEnd, childMaxEndRelativeToBase)
                    : childMaxEndRelativeToBase
                any = true
                cum += child.summary.span
            }
            if any, expectedRelativeMaxEnd != summary.maxEnd {
                violations.append(
                    "interior cached maxEnd \(summary.maxEnd) does not equal the independently recomputed fold of its children (expected \(expectedRelativeMaxEnd), base \(base))"
                )
            }
        }
    }

    // MARK: - Test-only affordances

    /// Test-only: exposes the internal `SumTree` for a node-visit count, matching
    /// `MarkerTree.testOnlySumTree`'s own rationale.
    internal var testOnlySumTree: SumTree<IntervalRecord> { tree }

    /// Test-only: wraps an already-built `SumTree<IntervalRecord>` directly, bypassing every
    /// invariant-preserving entry point — the deliberately-malformed-tree affordance
    /// `SumTree.init(root:)` itself documents needing (`SumTree.swift`'s doc comment on that
    /// initializer): `maxEndInvariantIsChecked` needs a tree with a stale `maxEnd` to prove
    /// `checkInvariants()` actually rejects it, the same shape as `sumTreeTests.swift`'s
    /// negative-test section. `internal`, not `private`: visible only via `@testable import
    /// Text`, one further step beyond `testOnlySumTree`'s read-only escape hatch (this file's
    /// header lists that as "the only exception" among the deliverable-A API; this initializer
    /// is a deviation from that, made for the same reason `SumTree.init(root:)` itself is not
    /// `private` — see the implementer's report).
    internal init(testOnlyTree tree: SumTree<IntervalRecord>) {
        self.tree = tree
    }

    // MARK: - applyEdit (`dev/specs/m1.4.md` 1.4-1.5)

    /// The two-stage composition this file's header and `dev/specs/m1.4.md` 1.4-1.5 derive:
    /// delete `byteRange`, then insert `insertedLength` bytes at `byteRange.lowerBound` — a
    /// replace is never one fused delta (the M1.3 finding, re-verified for intervals against
    /// the oracle: `dev/specs/m1.4.md` 1.4's twelve replace rows). Stage 1 is skipped entirely
    /// when `byteRange` is empty (a pure insertion needs no delete/collapse step); stage 2 is
    /// skipped entirely when `insertedLength == 0` (a pure deletion needs no insertion-boundary
    /// step) — mirroring `MarkerTree.applyEdit`'s own two skips.
    package func applyEdit(
        byteRange: Range<Int>, insertedLength: Int, insertBeforeMarkers: Bool = false
    ) -> IntervalTree {
        precondition(
            byteRange.lowerBound >= 0 && byteRange.lowerBound <= byteRange.upperBound,
            "IntervalTree.applyEdit: invalid byteRange \(byteRange)")
        precondition(insertedLength >= 0, "IntervalTree.applyEdit: negative insertedLength")
        let lo = byteRange.lowerBound
        let hi = byteRange.upperBound
        let afterDelete = lo == hi ? self : applyDelete(lo: lo, hi: hi)
        guard insertedLength > 0 else { return afterDelete }
        return afterDelete.applyInsert(
            at: lo, length: insertedLength, insertBeforeMarkers: insertBeforeMarkers)
    }

    /// Stage 1 (`dev/specs/m1.4.md` 1.5): delete `[lo, hi)`, `d = hi - lo`, independent of
    /// both flags (oracle-verified: twenty flag/shape combinations give identical positions —
    /// `dev/specs/m1.4.md` 1.4). Two disjoint jobs:
    ///
    /// - **Straddlers** (`start <= lo < end`): only `length` changes (`length -= (min(end,hi)
    ///   - max(start,lo))`, i.e. the deleted portion inside `[start,end)`), via `k`
    ///   independent single-rank `pathCopyEdit`s. Found by the same three-piece search the
    ///   query uses (`visitStraddlers`), restricted to the rank prefix before the first
    ///   interval starting at or after `lo`.
    /// - **Starts inside or after the range**: a contiguous rank range. `lo < start < hi`
    ///   collapses to `lo` (its length recomputed the same way — the portion of `[start,end)`
    ///   inside `[lo,hi)` is removed); `start >= hi` shifts by `-d`. Built like
    ///   `MarkerTree.applyDeleteAndCollapse`: `split`/`items()`/`concat` over the collapsing
    ///   group, then `cut` to rebase the tail's first gap.
    private func applyDelete(lo: Int, hi: Int) -> IntervalTree {
        precondition(lo < hi, "IntervalTree.applyDelete: requires lo < hi")
        let d = hi - lo

        // Straddlers: start <= lo < end, found in the rank prefix before the first interval
        // starting at lo. (Correction, `dev/specs/m1.5.md` 1.3: an earlier version of this
        // comment claimed an interval starting exactly at lo with end > lo "is a straddler
        // too, by this same predicate ... so it must not also be picked up by the collapse
        // group below." Both halves were misleading. `rank(startAtOrAfter: lo)` returns the
        // rank of the first item whose start is `>= lo`, and the straddler walk below is
        // restricted to ranks strictly below it, so a start-at-lo item is *excluded* from
        // this straddler stage and the collapse group is its only handler — which is exactly
        // why its length is cut once, not twice. The code has always been correct; the old
        // comment's stated reason did not establish what it claimed.)
        let firstAtOrAfterLoRank = rank(startAtOrAfter: lo)
        var straddlerRanks: [(rank: Int, newLength: Int)] = []
        if firstAtOrAfterLoRank > 0 {
            visitStraddlersInclusive(upperRankExclusive: firstAtOrAfterLoRank, lo: lo) {
                rank, absoluteStart, item in
                let end = absoluteStart + item.length
                guard absoluteStart <= lo, end > lo else { return }
                let removedInside = min(end, hi) - max(absoluteStart, lo)
                straddlerRanks.append((rank, item.length - removedInside))
            }
        }

        var working = tree
        for (rank, newLength) in straddlerRanks {
            guard
                let edited = working.pathCopyEdit(
                    where: { $0.count > rank },
                    edit: { items, index, _ in
                        var newItems = items
                        newItems[index].length = newLength
                        return newItems
                    })
            else {
                preconditionFailure(
                    "IntervalTree.applyDelete: straddler edit at rank \(rank) failed")
            }
            working = edited
        }
        let result = IntervalTree(tree: working)

        // Collapse group: starts in [lo, hi) collapse to lo (length recomputed the same
        // way); starts >= hi shift by -d.
        let collapseStartRank = result.rank(startAtOrAfter: lo)
        let collapseEndRank = result.rank(startAtOrAfter: hi)
        guard collapseStartRank < result.count else {
            // No interval at or after lo at all: nothing to collapse and nothing to shift.
            return result
        }

        let (beforeGroup, groupPlusRest) = result.tree.split(where: {
            $0.count >= collapseStartRank
        })
        let groupCount = collapseEndRank - collapseStartRank
        let (group, afterGroup) =
            groupCount > 0
            ? groupPlusRest.split(where: { $0.count >= groupCount })
            : (SumTree<IntervalRecord>(), groupPlusRest)

        let leftSpan = beforeGroup.summary.span
        var newGroupRecords: [IntervalRecord] = []
        newGroupRecords.reserveCapacity(group.items().count)
        var previousStart = leftSpan
        var absoluteStart = leftSpan
        for item in group.items() {
            absoluteStart += item.gap
            let end = absoluteStart + item.length
            let removedInside = min(end, hi) - max(absoluteStart, lo)
            let newLength = max(0, item.length - removedInside)
            var newItem = item
            newItem.gap = lo - previousStart
            newItem.length = newLength
            newGroupRecords.append(newItem)
            previousStart = lo
        }
        let newGroupTree = SumTree<IntervalRecord>(items: newGroupRecords)

        var finalAfterGroup = afterGroup
        if !afterGroup.isEmpty {
            guard let (tBefore, tailItem, _, tAfter) = afterGroup.cut(where: { $0.count >= 1 })
            else {
                preconditionFailure("IntervalTree.applyDelete: cut on a non-empty tail failed")
            }
            precondition(
                tBefore.isEmpty, "IntervalTree.applyDelete: rank-0 cut left a non-empty prefix")
            var rebasedItem = tailItem
            // previousStart is either `lo` (group non-empty) or `leftSpan` (group empty, no
            // collapse happened but a shift is still needed for the tail): the tail's new gap
            // is its absolute start minus `d` minus whatever the group rewrote `previousStart`
            // to — i.e. `(originalAbsoluteStart - d) - previousStart`.
            let originalTailAbsoluteStart =
                (group.items().isEmpty ? leftSpan : absoluteStart) + tailItem.gap
            rebasedItem.gap = (originalTailAbsoluteStart - d) - previousStart
            let rebased = SumTree<IntervalRecord>(items: [rebasedItem])
            finalAfterGroup = SumTree.concat(rebased, tAfter)
        }

        let merged = SumTree.concat(beforeGroup, SumTree.concat(newGroupTree, finalAfterGroup))
        return IntervalTree(tree: merged)
    }

    /// Like `visitStraddlers`, but also hands back the rank of each visited item, since
    /// `applyDelete`'s straddler stage needs to target each one individually with a
    /// single-rank `pathCopyEdit`. Uses `straddlerDescendPredicate`, the same shared function
    /// `visitStraddlers` uses — see that function's doc comment for why this must not be its
    /// own hand-copied formula.
    private func visitStraddlersInclusive(
        upperRankExclusive: Int, lo: Int,
        handle: (_ rank: Int, _ absoluteStart: Int, _ item: IntervalRecord) -> Void
    ) {
        let prune = Self.straddlerDescendPredicate(lo: lo)
        tree.visitItems(
            descendInto: { prefix, subtree in
                guard prefix.count < upperRankExclusive else { return false }
                return prune(prefix, subtree)
            },
            visit: { prefix, item in
                guard prefix.count < upperRankExclusive else { return false }
                let absoluteStart = prefix.span + item.gap
                handle(prefix.count, absoluteStart, item)
                return true
            })
    }

    /// The non-strict counterpart of `straddlerDescendPredicate` (`maxEnd >= p`, not `> p`) —
    /// needed only by `applyInsert`'s straddler search, not `applyDelete`'s, and factored out
    /// for the same shared-with-its-test reason. The insertion endpoint rule has a case the
    /// deletion rule does not: an item whose `end` lands *exactly* on the insertion point `p`
    /// still moves when `rearAdvance` or `insertBeforeMarkers` holds (`endMoves`'s `end == P
    /// && (ra || bm)` clause, `dev/specs/m1.4.md` 1.4), and a strict `maxEnd > p` prune throws
    /// such an item's whole subtree away before ever visiting it (deletion's endpoint rule has
    /// no such clause — `x' = x` whenever `x <= lo`, flag-independent — so
    /// `visitStraddlersInclusive`'s strict prune is exact there, never merely conservative).
    ///
    /// **Cost, accepted rather than fixed** (a reviewer independently confirmed the non-strict
    /// prune is necessary given this milestone's summary — a strict one would silently drop
    /// the `length` update for an item whose end lands exactly on the insertion point with
    /// `rearAdvance`): `applyInsert`'s straddler search is **O(log n + k + e)**, not O(log n +
    /// k), where `e` is the number of intervals whose end is exactly the insertion offset `p`
    /// — every one of those subtrees is visited regardless of whether its item actually moves,
    /// because `rearAdvance`/`insertBeforeMarkers` is not a fact this summary carries. This
    /// reintroduces, for insertion's straddler search only, the non-strict-prune pathology
    /// section 1.6 derives for the query (many intervals ending exactly at `p` cost O(that
    /// count) even when none of them actually have `rearAdvance`/`insertBeforeMarkers` set).
    /// Not covered by this milestone's perf tests. **The fix not built here**: a second
    /// augmented dimension carrying the max end restricted to items with `rearAdvance` (an
    /// affine-max fold exactly like `maxEnd` itself, just over a filtered population) would let
    /// this search split into a strict, output-sensitive scan (this file's `maxEnd` dimension,
    /// unchanged) plus a scan over the much smaller rear-advancing population alone — turning
    /// `e` into "rear-advancing intervals ending at `p`" rather than "every interval ending at
    /// `p`". Deliberately not built in M1.4; `PLAN.md`'s cost row for this operation is the
    /// main conversation's to write from this note.
    private func visitEndAtOrAfterInclusive(
        upperRankExclusive: Int, p: Int,
        handle: (_ rank: Int, _ absoluteStart: Int, _ item: IntervalRecord) -> Void
    ) {
        let prune = Self.endAtOrAfterDescendPredicate(p)
        tree.visitItems(
            descendInto: { prefix, subtree in
                guard prefix.count < upperRankExclusive else { return false }
                return prune(prefix, subtree)
            },
            visit: { prefix, item in
                guard prefix.count < upperRankExclusive else { return false }
                let absoluteStart = prefix.span + item.gap
                handle(prefix.count, absoluteStart, item)
                return true
            })
    }

    /// See `visitEndAtOrAfterInclusive`'s doc comment. `internal`, not `private`, for the same
    /// reason `straddlerDescendPredicate` is: a counted test wraps this exact function.
    internal static func endAtOrAfterDescendPredicate(
        _ p: Int
    ) -> (IntervalSummary, IntervalSummary) -> Bool {
        { prefix, subtree in prefix.span + subtree.maxEnd >= p }
    }

    /// Stage 2 (`dev/specs/m1.4.md` 1.5): insert `length` bytes at `P`. Two jobs:
    ///
    /// - **Straddlers** (`endMoves && !startMoves`): `length += L`, via `k` independent
    ///   single-rank `pathCopyEdit`s.
    /// - **Movers** (`startMoves`, `dev/specs/m1.4.md` 1.4): every interval with `start > P`,
    ///   plus the members of the tie group at `P` satisfying `startMoves`'s second clause
    ///   including its clamp (third conjunct). The tie group is stably partitioned into
    ///   non-movers then movers, residents included (M1.3's second correction, reachable here
    ///   for the same reason: stage 1 may just have collapsed intervals onto `P == lo`); the
    ///   movers are then a rank suffix and one gap edit of `+L` at the first of them.
    private func applyInsert(at p: Int, length: Int, insertBeforeMarkers: Bool) -> IntervalTree {
        precondition(length > 0, "IntervalTree.applyInsert: requires positive length")

        // Straddlers: startMoves is false (guaranteed here since start < p), endMoves is
        // true. `endMoves` at `start < p` is `end > p`, unconditionally, **or** `end == p`
        // and (`rearAdvance` || `insertBeforeMarkers`) — the equality clause is why this uses
        // `visitEndAtOrAfterInclusive`'s non-strict prune, not `visitStraddlersInclusive`'s
        // strict one (see that function's doc comment). Found in the rank prefix before the
        // tie group at p.
        let firstAtPRank = rank(startAtOrAfter: p)
        var straddlerEdits: [(rank: Int, newLength: Int)] = []
        if firstAtPRank > 0 {
            visitEndAtOrAfterInclusive(upperRankExclusive: firstAtPRank, p: p) {
                rank, absoluteStart, item in
                let end = absoluteStart + item.length
                guard absoluteStart < p else { return }
                guard end > p || (end == p && (item.rearAdvance || insertBeforeMarkers)) else {
                    return
                }
                straddlerEdits.append((rank, item.length + length))
            }
        }
        var working = tree
        for (rank, newLength) in straddlerEdits {
            guard
                let edited = working.pathCopyEdit(
                    where: { $0.count > rank },
                    edit: { items, index, _ in
                        var newItems = items
                        newItems[index].length = newLength
                        return newItems
                    })
            else {
                preconditionFailure(
                    "IntervalTree.applyInsert: straddler edit at rank \(rank) failed")
            }
            working = edited
        }
        let result = IntervalTree(tree: working)

        // The tie group at p: every interval whose (recomputed, post-straddler-edit) start
        // equals p.
        let groupStartRank = result.rank(startAtOrAfter: p)
        var groupEndRank = groupStartRank
        while groupEndRank < result.count, result.start(ofRank: groupEndRank) == p {
            groupEndRank += 1
        }
        guard groupEndRank > groupStartRank else {
            // Nothing sits exactly at p; every interval with start > p (if any) simply needs
            // the boundary shift below, one gap edit at the first such rank.
            return result.shiftingSuffix(startAtOrAfter: p + 1, by: length)
        }

        let groupSize = groupEndRank - groupStartRank
        if groupSize <= 1 {
            // A uniform group of size 0 or 1 cannot be mixed (`dev/specs/m1.4.md` 1.5): if
            // the sole member moves, one gap edit does it; if not, its *start* does not move,
            // but its end still can (`endMoves`, evaluated at `start == p`: unconditional if
            // `length > 0`, else `rearAdvance || insertBeforeMarkers`) — a non-mover with a
            // moving end is exactly the straddler shape `dev/specs/m1.4.md` 1.5 describes, it
            // just was not caught by the `start < p` restriction above because its start
            // equals `p`, not `< p`. Mutation focus: leaving this branch's length untouched
            // silently drops every "non-empty interval whose start ties the insertion point"
            // case, which `oracleInsertAtBoundaries`'s `pos == start` rows exercise.
            if groupSize == 1 {
                let item = result.record(ofRank: groupStartRank).record
                if startMoves(item: item, p: p, insertBeforeMarkers: insertBeforeMarkers) {
                    return result.shiftingSuffix(startAtOrAfter: p, by: length)
                }
                if item.length > 0 || item.rearAdvance || insertBeforeMarkers {
                    let rank = groupStartRank
                    guard
                        let edited = result.tree.pathCopyEdit(
                            where: { $0.count > rank },
                            edit: { items, index, _ in
                                var newItems = items
                                newItems[index].length += length
                                return newItems
                            })
                    else {
                        preconditionFailure(
                            "IntervalTree.applyInsert: single non-mover length edit at rank \(rank) failed"
                        )
                    }
                    return IntervalTree(tree: edited).shiftingSuffix(
                        startAtOrAfter: p + 1, by: length)
                }
            }
            return result.shiftingSuffix(startAtOrAfter: p + 1, by: length)
        }

        // Mixed group: stably partition into non-movers then movers, residents included.
        let (beforeGroup, groupPlusRest) = result.tree.split(where: { $0.count >= groupStartRank })
        let (group, afterGroup) = groupPlusRest.split(where: { $0.count >= groupSize })
        let groupItems = group.items()

        let nonMovers = groupItems.filter {
            !startMoves(item: $0, p: p, insertBeforeMarkers: insertBeforeMarkers)
        }
        let movers = groupItems.filter {
            startMoves(item: $0, p: p, insertBeforeMarkers: insertBeforeMarkers)
        }

        // `beforeGroup`'s items all have start < p, but its last item's absolute start need
        // not be `p - 1` — the first rewritten record in each bucket must close the gap from
        // `beforeGroup`'s own prefix span, exactly as `applyDelete`'s collapse-group rewrite
        // does (`leftSpan`/`previousStart` there is the same pattern). Getting this wrong (a
        // flat `gap: 0` for every non-mover, as an earlier draft of this function had) leaves
        // the very first non-mover's absolute start wherever `beforeGroup` happened to end,
        // not at `p` — silently corrupting every tie-group edit whose group is not the first
        // rank in the tree.
        let leftSpan = beforeGroup.summary.span
        var newGroupRecords: [IntervalRecord] = []
        newGroupRecords.reserveCapacity(groupItems.count)
        var previousAbsoluteStart = leftSpan
        for item in nonMovers {
            var newItem = item
            newItem.gap = p - previousAbsoluteStart
            // A non-mover's *start* stays at `p`, but its end can still move (`endMoves`,
            // evaluated at `start == p`): unconditionally if it is non-empty, or if it is
            // empty and `rearAdvance`/`insertBeforeMarkers` holds. This is the same straddler
            // shape as the `groupSize == 1` branch above, applied per non-mover here.
            if item.length > 0 || item.rearAdvance || insertBeforeMarkers {
                newItem.length += length
            }
            newGroupRecords.append(newItem)
            previousAbsoluteStart = p
        }
        for item in movers {
            var newItem = item
            newItem.gap = (p + length) - previousAbsoluteStart
            newGroupRecords.append(newItem)
            previousAbsoluteStart = p + length
        }
        let newGroupTree = SumTree<IntervalRecord>(items: newGroupRecords)

        var finalAfterGroup = afterGroup
        if !afterGroup.isEmpty {
            guard let (tBefore, tailItem, _, tAfter) = afterGroup.cut(where: { $0.count >= 1 })
            else {
                preconditionFailure("IntervalTree.applyInsert: cut on a non-empty tail failed")
            }
            precondition(
                tBefore.isEmpty, "IntervalTree.applyInsert: rank-0 cut left a non-empty prefix")
            var rebasedItem = tailItem
            // The tail's absolute start was p + tailItem.gap before this edit; after it, it
            // must be p + length + tailItem.gap (every rank after the group shifts by
            // `length`, since the group's last member's new absolute start is p or p+length,
            // both <= the tail's new absolute start). The new gap is that minus the group's
            // rewritten last absolute start.
            let newTailAbsoluteStart = p + tailItem.gap + length
            let groupLastAbsoluteStart = movers.isEmpty ? p : p + length
            rebasedItem.gap = newTailAbsoluteStart - groupLastAbsoluteStart
            let rebased = SumTree<IntervalRecord>(items: [rebasedItem])
            finalAfterGroup = SumTree.concat(rebased, tAfter)
        }

        let merged = SumTree.concat(beforeGroup, SumTree.concat(newGroupTree, finalAfterGroup))
        return IntervalTree(tree: merged)
    }

    /// Shifts every interval whose start is `>= boundary` by `delta` — one gap edit at the
    /// first such rank, exactly `MarkerTree.shiftingSingleItem`'s own shape. `pathCopyEdit`'s
    /// own `nil` (predicate never true of the tree's total) is `boundary` past every start,
    /// which this turns into an untouched `self`.
    private func shiftingSuffix(startAtOrAfter boundary: Int, by delta: Int) -> IntervalTree {
        guard delta != 0 else { return self }
        let predicate: (IntervalSummary) -> Bool = { $0.count > 0 && $0.span >= boundary }
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
        return IntervalTree(tree: newTree)
    }

    /// `startMoves` (`dev/specs/m1.4.md` 1.4): whether this item's start moves under an
    /// insertion of some positive length at `p`, given this item's start already equals `p`
    /// (the only case this is called for — a start strictly greater than `p` always moves,
    /// and is handled by the boundary shift, not this predicate). The third conjunct is the
    /// clamp: an empty interval (`length == 0`) at `p` with `frontAdvance` but neither
    /// `rearAdvance` nor `insertBeforeMarkers` does not move, because moving it would invert
    /// it (`dev/specs/m1.4.md` 1.4's `(6,5)` example). Mutation focus: dropping this conjunct
    /// (`dev/specs/m1.4.md` section 6, mutation 1).
    private func startMoves(
        item: IntervalRecord, p: Int, insertBeforeMarkers: Bool
    ) -> Bool {
        (item.frontAdvance || insertBeforeMarkers)
            && (item.length > 0 || item.rearAdvance || insertBeforeMarkers)
    }
}
