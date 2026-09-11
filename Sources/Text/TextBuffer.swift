/// The undo-aware buffer owner (M1.5 stage 1, `dev/specs/m1.5.md` 1.8): pairs one live
/// `BufferSnapshot` with an `UndoHistory` and the two marker/interval ID counters (moved here
/// from `BufferSnapshot`, per 1.8 rule 1). A `final class`, not `Sendable`: undo is inherently
/// a thing that changes over time, `PLAN.md` 4.5 already sketches `TextBuffer` as a class, and
/// M5's Elisp buffer object needs a stable identity to map onto. `BufferSnapshot` stays the
/// `Sendable` value handed to the UI and to background readers — the UI actor never touches a
/// buffer, and that rule does not move.
///
/// **The one edit funnel stays `BufferSnapshot.replaceSubrange`.** This type becomes the only
/// production caller of it: every mutation here queries the undo entry set, calls the funnel,
/// then queries again — never a second mutator. Replay (`undo`/`redo`) is the same funnel
/// driven backward/forward by the recorded entries, per `dev/specs/m1.5.md` 1.4.
///
/// **There is no initialiser that builds a `TextBuffer` around an existing `BufferSnapshot`**
/// (1.8 rule 4): two owners over one ancestor snapshot would each start a counter from the
/// same high-water mark and collide. `TextBuffer` is constructed empty.
package final class TextBuffer {
    package private(set) var snapshot: BufferSnapshot
    package private(set) var history: UndoHistory

    /// The implicit open transaction (`dev/specs/m1.5.md` 1.7): the first edit after a commit
    /// starts it; `commitTransaction()` is idempotent, a no-op when this is empty.
    package private(set) var pendingEdits: [ElementaryEdit]

    /// When `false`, edits are applied but nothing is recorded — the history is left
    /// untouched, and an edit made while this is `false` is not undoable (test 16).
    package var isRecordingUndo: Bool

    /// Stage 1 enforces no budget (`dev/specs/m1.5.md` 1.9); this field exists so stage 2's
    /// policy has somewhere to read its configuration from without another milestone's worth
    /// of plumbing.
    package var undoByteBudget: Int

    private var nextMarkerID: MarkerID
    private var nextIntervalID: IntervalID

    package init() {
        self.snapshot = BufferSnapshot()
        self.history = UndoHistory()
        self.pendingEdits = []
        self.isRecordingUndo = true
        self.undoByteBudget = 2 * 1024 * 1024
        self.nextMarkerID = 0
        self.nextIntervalID = 0
    }

    // MARK: - Edit entry points

    /// The funnel, undo-recording wrapper (`dev/specs/m1.5.md` 1.4's "live edit" half): with
    /// `isRecordingUndo`, queries the marker/interval entry set **before** the edit, applies
    /// the funnel normally (never removing anything from the trees — that is replay's job,
    /// not the live edit's), queries the same-shape entry set **after**, and appends the
    /// combined `ElementaryEdit` to `pendingEdits`. With `isRecordingUndo == false`, applies
    /// the funnel and records nothing.
    package func replaceSubrange(
        _ byteRange: Range<Int>, with other: Rope, insertBeforeMarkers: Bool = false
    ) {
        guard isRecordingUndo else {
            snapshot.replaceSubrange(
                byteRange, with: other, insertBeforeMarkers: insertBeforeMarkers)
            return
        }
        let lo = byteRange.lowerBound
        let hi = byteRange.upperBound
        let insertedLength = other.utf8Count

        let markersBefore = snapshot.markers.markers(in: lo..<(hi + 1))
        let intervalsBefore = snapshot.intervals.undoEntrySet(lo: lo, upperInclusive: hi)
        let deleted = snapshot.text.slice(byteRange)

        snapshot.replaceSubrange(byteRange, with: other, insertBeforeMarkers: insertBeforeMarkers)

        let afterLo = lo
        let afterHi = lo + insertedLength
        let markersAfter = snapshot.markers.markers(in: afterLo..<(afterHi + 1))
        let intervalsAfter = snapshot.intervals.undoEntrySet(lo: afterLo, upperInclusive: afterHi)
        // `other`, not `snapshot.text.slice(afterLo..<afterHi)`: the funnel inserts exactly
        // the rope it was handed, so slicing the same bytes back out of the buffer buys
        // nothing and costs a full `Rope.slice`, which is two whole-tree splits. Measured on
        // this machine on a 1 MB buffer: a one-byte `slice` is 34.9 us against 0.02-0.03 us
        // for both entry-set queries and 3.2 us for the funnel itself, so the two slices this
        // path used to make were essentially the whole cost of recording a transaction. The
        // `deleted` slice above is not removable this way — those bytes are about to stop
        // existing — and `Rope.slice`'s own constant is recorded as a gap in `PLAN.md` 4.5.
        let inserted = other

        let markerEntries = Self.buildMarkerEntries(before: markersBefore, after: markersAfter)
        let intervalEntries = Self.buildIntervalEntries(
            before: intervalsBefore, after: intervalsAfter)

        pendingEdits.append(
            ElementaryEdit(
                byteRange: byteRange, deleted: deleted, inserted: inserted,
                markerEntries: markerEntries, intervalEntries: intervalEntries))
    }

    /// `String` convenience mirroring `BufferSnapshot.replaceSubrange(_:with:String)`.
    package func replaceSubrange(
        _ byteRange: Range<Int>, with string: String, insertBeforeMarkers: Bool = false
    ) {
        replaceSubrange(byteRange, with: Rope(string), insertBeforeMarkers: insertBeforeMarkers)
    }

    /// Pairs the before/after marker query results into `MarkerEntry`s by id. Test 13 asserts
    /// the two id sets are equal (`dev/specs/m1.5.md` 1.4); a marker present in only one side
    /// here would be dropped silently, which is why that invariant is tested directly rather
    /// than trusted.
    private static func buildMarkerEntries(
        before: [(offset: Int, bias: MarkerBias, id: MarkerID)],
        after: [(offset: Int, bias: MarkerBias, id: MarkerID)]
    ) -> [MarkerEntry] {
        var afterByID: [MarkerID: (offset: Int, bias: MarkerBias)] = [:]
        afterByID.reserveCapacity(after.count)
        for a in after { afterByID[a.id] = (a.offset, a.bias) }
        var entries: [MarkerEntry] = []
        entries.reserveCapacity(before.count)
        for b in before {
            guard let a = afterByID[b.id] else { continue }
            entries.append(
                MarkerEntry(id: b.id, bias: b.bias, beforeOffset: b.offset, afterOffset: a.offset))
        }
        return entries
    }

    /// Pairs the before/after interval query results into `IntervalEntry`s by id, mirroring
    /// `buildMarkerEntries`.
    private static func buildIntervalEntries(
        before: [IntervalSpan], after: [IntervalSpan]
    ) -> [IntervalEntry] {
        var afterByID: [IntervalID: IntervalSpan] = [:]
        afterByID.reserveCapacity(after.count)
        for a in after { afterByID[a.id] = a }
        var entries: [IntervalEntry] = []
        entries.reserveCapacity(before.count)
        for b in before {
            guard let a = afterByID[b.id] else { continue }
            entries.append(
                IntervalEntry(
                    id: b.id, beforeStart: b.range.lowerBound, beforeLength: b.range.count,
                    afterStart: a.range.lowerBound, afterLength: a.range.count,
                    frontAdvance: b.frontAdvance, rearAdvance: b.rearAdvance))
        }
        return entries
    }

    // MARK: - Markers and intervals (`dev/specs/m1.5.md` 1.8 rules 1-2)

    @discardableResult
    package func createMarker(atByteOffset byteOffset: Int, bias: MarkerBias) -> MarkerID {
        let id = nextMarkerID
        nextMarkerID += 1
        snapshot.createMarker(id: id, atByteOffset: byteOffset, bias: bias)
        return id
    }

    @discardableResult
    package func createInterval(
        byteRange: Range<Int>, frontAdvance: Bool = false, rearAdvance: Bool = false
    ) -> IntervalID {
        let id = nextIntervalID
        nextIntervalID += 1
        snapshot.createInterval(
            id: id, byteRange: byteRange, frontAdvance: frontAdvance, rearAdvance: rearAdvance)
        return id
    }

    /// Removes marker `id` at `byteOffset`, if present. **Deliberately not undo-recorded**,
    /// matching GNU and `dev/specs/m1.5.md` section 3's "never" row: marker/interval removal
    /// is not part of the undo model at all, so this bypasses `pendingEdits` entirely — the
    /// same reason `createMarker`/`createInterval` above do. A minor addition beyond
    /// deliverable B's enumerated method list, added because section 3's row presupposes a
    /// removal path exists to *not* undo; reported as a deviation, not escalated, since it is
    /// mechanical plumbing within this already-in-scope file, not an architectural choice.
    package func removeMarker(id: MarkerID, atByteOffset byteOffset: Int) {
        snapshot.removeMarkerIfPresent(id: id, atByteOffset: byteOffset)
    }

    /// Removes interval `id` starting at `byteOffset`, if present. Mirrors `removeMarker`.
    package func removeInterval(id: IntervalID, startingAt byteOffset: Int) {
        snapshot.removeIntervalIfPresent(id: id, startingAt: byteOffset)
    }

    // MARK: - Grouping (`dev/specs/m1.5.md` 1.7)

    /// Idempotent: a no-op when nothing is pending, appending no node. Otherwise appends one
    /// `UndoHistory` node holding `pendingEdits` and clears the pending list.
    package func commitTransaction() {
        guard !pendingEdits.isEmpty else { return }
        history.recordTransaction(edits: pendingEdits)
        pendingEdits = []
    }

    // MARK: - Undo/redo (`dev/specs/m1.5.md` 1.4, 1.6)

    /// One replacement actually applied by a traversal, in absolute post-that-step
    /// coordinates — `undo()`/`redo()`'s ordered return value (`dev/specs/m1.5.md` 1.6, test
    /// 12).
    package struct AppliedReplacement: Sendable {
        package let byteRange: Range<Int>
        package let inserted: Rope

        package init(byteRange: Range<Int>, inserted: Rope) {
            self.byteRange = byteRange
            self.inserted = inserted
        }
    }

    /// Commits the pending transaction first (`dev/specs/m1.5.md` 1.7: otherwise typing three
    /// characters and immediately undoing would undo nothing, since the transaction holding
    /// them was never closed), then moves `history` to its parent, applying each of the
    /// traversed node's elementary edits **newest first**, each by the four-step traversal
    /// `dev/specs/m1.5.md` 1.4 derives. Returns `nil` when there is nothing to undo.
    @discardableResult
    package func undo() -> (node: Int32, applied: [AppliedReplacement])? {
        commitTransaction()
        guard let (node, edits) = history.moveToParent() else { return nil }
        var applied: [AppliedReplacement] = []
        applied.reserveCapacity(edits.count)
        for edit in edits.reversed() {
            applied.append(applyInverse(of: edit))
        }
        return (node, applied)
    }

    /// Commits the pending transaction first, then moves `history` to its `lastVisitedChild`,
    /// applying each of the traversed node's elementary edits **oldest first** — the forward
    /// direction. Returns `nil` when there is nothing to redo.
    @discardableResult
    package func redo() -> (node: Int32, applied: [AppliedReplacement])? {
        commitTransaction()
        guard let (node, edits) = history.moveToLastVisitedChild() else { return nil }
        var applied: [AppliedReplacement] = []
        applied.reserveCapacity(edits.count)
        for edit in edits {
            applied.append(applyForward(of: edit))
        }
        return (node, applied)
    }

    /// The undo direction of `dev/specs/m1.5.md` 1.4's four-step traversal: remove each
    /// entry's item at its **after** position (skipping an id that is no longer present —
    /// marker/interval *removal* is not undoable, so a branch walked after the user deleted
    /// one of these must not trap), apply the inverse text replacement (`replace [lo, lo+L)
    /// with the original d bytes`), then re-insert **only the entries step 1 actually
    /// removed** at their **before** position, iterating the entry list **in reverse** (1.4
    /// step 3 — load-bearing for tie order, since both `MarkerTree.inserting`/
    /// `IntervalTree.inserting` prepend to a tie group, so front-to-back reinsertion would
    /// reverse it).
    ///
    /// **The removed/reinserted sets must match, or "removal is not undoable" breaks.** An id
    /// step 1 could not find (the user removed it on this branch) must not come back in step
    /// 3 either — reinserting it unconditionally would resurrect a marker/interval the user
    /// explicitly deleted the moment any nearby transaction is walked, silently undoing a
    /// removal the model documents as never undoable (test 15).
    private func applyInverse(of edit: ElementaryEdit) -> AppliedReplacement {
        var presentMarkerIDs: Set<MarkerID> = []
        for entry in edit.markerEntries {
            if snapshot.removeMarkerIfPresent(id: entry.id, atByteOffset: entry.afterOffset) {
                presentMarkerIDs.insert(entry.id)
            }
        }
        var presentIntervalIDs: Set<IntervalID> = []
        for entry in edit.intervalEntries {
            if snapshot.removeIntervalIfPresent(id: entry.id, startingAt: entry.afterStart) {
                presentIntervalIDs.insert(entry.id)
            }
        }

        let insertedLength = edit.inserted.utf8Count
        let replaceRange = edit.byteRange.lowerBound..<(edit.byteRange.lowerBound + insertedLength)
        snapshot.replaceSubrange(replaceRange, with: edit.deleted)

        for entry in edit.markerEntries.reversed() where presentMarkerIDs.contains(entry.id) {
            snapshot.insertMarker(id: entry.id, atByteOffset: entry.beforeOffset, bias: entry.bias)
        }
        for entry in edit.intervalEntries.reversed() where presentIntervalIDs.contains(entry.id) {
            snapshot.insertInterval(
                id: entry.id, range: entry.beforeStart..<(entry.beforeStart + entry.beforeLength),
                frontAdvance: entry.frontAdvance, rearAdvance: entry.rearAdvance)
        }

        return AppliedReplacement(byteRange: replaceRange, inserted: edit.deleted)
    }

    /// The redo direction: the mirror of `applyInverse`, removing at the **before** position
    /// and re-inserting at the **after** position, applying the edit's own forward
    /// replacement (`replace byteRange with edit.inserted`). Only reinserts what step 1
    /// actually removed, for the same "removal is not undoable" reason `applyInverse`
    /// documents.
    private func applyForward(of edit: ElementaryEdit) -> AppliedReplacement {
        var presentMarkerIDs: Set<MarkerID> = []
        for entry in edit.markerEntries {
            if snapshot.removeMarkerIfPresent(id: entry.id, atByteOffset: entry.beforeOffset) {
                presentMarkerIDs.insert(entry.id)
            }
        }
        var presentIntervalIDs: Set<IntervalID> = []
        for entry in edit.intervalEntries {
            if snapshot.removeIntervalIfPresent(id: entry.id, startingAt: entry.beforeStart) {
                presentIntervalIDs.insert(entry.id)
            }
        }

        snapshot.replaceSubrange(edit.byteRange, with: edit.inserted)

        for entry in edit.markerEntries.reversed() where presentMarkerIDs.contains(entry.id) {
            snapshot.insertMarker(id: entry.id, atByteOffset: entry.afterOffset, bias: entry.bias)
        }
        for entry in edit.intervalEntries.reversed() where presentIntervalIDs.contains(entry.id) {
            snapshot.insertInterval(
                id: entry.id, range: entry.afterStart..<(entry.afterStart + entry.afterLength),
                frontAdvance: entry.frontAdvance, rearAdvance: entry.rearAdvance)
        }

        return AppliedReplacement(byteRange: edit.byteRange, inserted: edit.inserted)
    }

    // MARK: - Discard

    /// Resets `history` to a fresh genesis node and drops any pending (uncommitted) edits —
    /// there is nothing left to undo back through them once the history that would record
    /// them is gone. Leaves `snapshot` untouched (deliverable I, test 18c).
    package func discardHistory() {
        history.discardHistory()
        pendingEdits = []
    }
}
