/// A minimal `Rope` + `MarkerTree` pairing (M1.3, `dev/specs/m1.3.md` section 2.C): the two
/// cannot desync because `replaceSubrange` is the only mutator and it edits both from the
/// same `byteRange`/`other`.
///
/// **Not a field on `Rope`.** `Rope` is `Equatable` comparing text (`Rope.swift:1099`); two
/// ropes with equal text and different markers would break that contract, and `Rope.slice`
/// and the `other:` argument of `replaceSubrange` would each need a marker answer that has
/// no sensible one.
///
/// **Not a free-standing tree with deferred pairing.** The rope has exactly one edit funnel
/// (`Rope.replaceSubrange(_:with:)`); if markers were free-standing, every caller would have
/// to remember a second call with the same arguments, and that desync is silent and
/// position-dependent.
///
/// **Not `TextBuffer` yet.** `dev/specs/m1.5.md` 1.8 gives `TextBuffer` its final shape: a
/// `final class` that owns `snapshot`, `history` and the two ID counters — this type stays
/// the value the UI and background readers see, and its `mutating` edit gives atomicity
/// without an ownership model.
///
/// **The ID counters are `TextBuffer`'s, not this type's** (`dev/specs/m1.5.md` 1.8).
/// `BufferSnapshot` is a value; a fork-and-edit-both-branches scenario would let two callers
/// derive a counter from the same starting point and collide, so allocation is the identity-
/// bearing owner's job. What this type keeps instead is a **high-water pair it can only
/// raise**: `createMarker`/`createInterval` take the id and precondition it exceeds the
/// high-water mark, turning a caller's collision into a trap rather than a silent corruption.
/// There is still no `init(text:markers:)` for the same reason as before, plus one more: it
/// would also have to fabricate a high-water mark, and `TextBuffer`'s own contract (1.8 rule
/// 4) is that no initialiser builds a buffer around an existing snapshot for exactly this
/// reason.
package struct BufferSnapshot: Sendable {
    package private(set) var text: Rope
    package private(set) var markers: MarkerTree
    package private(set) var intervals: IntervalTree
    private var markerIDHighWater: MarkerID?
    private var intervalIDHighWater: IntervalID?

    package init() {
        self.text = Rope()
        self.markers = MarkerTree()
        self.intervals = IntervalTree()
        self.markerIDHighWater = nil
        self.intervalIDHighWater = nil
    }

    // No `init(text:markers:)`. It would have to fabricate `nextMarkerID` (colliding with
    // any IDs already in `markers`, since `MarkerID`'s doc comment requires monotone,
    // never-reused IDs) and validate that `markers`' offsets lie inside `text` on scalar
    // boundaries — real work with no caller to justify it yet (every test here uses
    // `BufferSnapshot()`, and `dev/specs/m1.3.md` section 2.C never asked for bulk
    // construction). Add it with a real `nextMarkerID` derivation and real validation when a
    // caller needs it.

    /// The one edit funnel: replaces `byteRange` in `text` with `other`, then applies the
    /// same edit to `markers` and `intervals` via their own `applyEdit` — same `byteRange`,
    /// and `insertedLength` read from `other.utf8Count` (the only two facts `applyEdit` needs,
    /// both already in scope here, matching `Rope.replaceSubrange`'s own funnel comment that
    /// this is the only call site where both are available at once). `markers` and
    /// `intervals` cannot desync from each other or from `text` because both are driven from
    /// this one call, with the one `byteRange`/`insertedLength` pair (`dev/specs/m1.4.md`
    /// deliverable D).
    package mutating func replaceSubrange(
        _ byteRange: Range<Int>, with other: Rope, insertBeforeMarkers: Bool = false
    ) {
        text.replaceSubrange(byteRange, with: other)
        markers = markers.applyEdit(
            byteRange: byteRange, insertedLength: other.utf8Count,
            insertBeforeMarkers: insertBeforeMarkers)
        intervals = intervals.applyEdit(
            byteRange: byteRange, insertedLength: other.utf8Count,
            insertBeforeMarkers: insertBeforeMarkers)
    }

    /// `String` convenience, mirroring `Rope.replaceSubrange(_:with:String)`
    /// (`Rope.swift:1025`), which forwards to the `Rope` overload rather than duplicating its
    /// body. Declared here for the same reason: without it, a caller with a `String` would
    /// have to build a `Rope` by hand to reach the marker-adjusting funnel above, and could
    /// reach `text.replaceSubrange(_:with:String)` directly instead — silently bypassing
    /// `markers`'s edit entirely, exactly the desync this type exists to make impossible
    /// (this file's header, "Not a free-standing tree with deferred pairing").
    package mutating func replaceSubrange(
        _ byteRange: Range<Int>, with string: String, insertBeforeMarkers: Bool = false
    ) {
        replaceSubrange(byteRange, with: Rope(string), insertBeforeMarkers: insertBeforeMarkers)
    }

    /// Creates a new marker `id` at `atByteOffset`, preconditioning the offset is a scalar
    /// boundary via `Rope.isScalarBoundary` — the check `MarkerTree` alone cannot do, since
    /// it does not hold the text (`dev/specs/m1.3.md` section 2.C) — and that `id` exceeds
    /// the high-water mark (`dev/specs/m1.5.md` 1.8 rule 3). Allocation is the caller's
    /// (`TextBuffer`'s); this only validates and inserts.
    package mutating func createMarker(id: MarkerID, atByteOffset byteOffset: Int, bias: MarkerBias)
    {
        precondition(
            byteOffset >= 0 && byteOffset <= text.utf8Count,
            "BufferSnapshot.createMarker: byte offset out of range")
        precondition(
            text.isScalarBoundary(byteOffset),
            "BufferSnapshot.createMarker: byte offset \(byteOffset) is not a scalar boundary")
        precondition(
            markerIDHighWater.map { id > $0 } ?? true,
            "BufferSnapshot.createMarker: id \(id) does not exceed the high-water mark \(String(describing: markerIDHighWater))"
        )
        markerIDHighWater = id
        markers = markers.inserting(byteOffset: byteOffset, bias: bias, id: id)
    }

    /// Creates a new interval `id` spanning `byteRange`, preconditioning both endpoints are
    /// in range and on scalar boundaries via `Rope.isScalarBoundary` — exactly as
    /// `createMarker` does (`dev/specs/m1.4.md` deliverable D) — and that `id` exceeds the
    /// high-water mark, mirroring `createMarker`'s own rule.
    package mutating func createInterval(
        id: IntervalID, byteRange: Range<Int>, frontAdvance: Bool = false, rearAdvance: Bool = false
    ) {
        precondition(
            byteRange.lowerBound >= 0 && byteRange.upperBound <= text.utf8Count,
            "BufferSnapshot.createInterval: byte range out of range")
        precondition(
            text.isScalarBoundary(byteRange.lowerBound),
            "BufferSnapshot.createInterval: lower bound \(byteRange.lowerBound) is not a scalar boundary"
        )
        precondition(
            text.isScalarBoundary(byteRange.upperBound),
            "BufferSnapshot.createInterval: upper bound \(byteRange.upperBound) is not a scalar boundary"
        )
        precondition(
            intervalIDHighWater.map { id > $0 } ?? true,
            "BufferSnapshot.createInterval: id \(id) does not exceed the high-water mark \(String(describing: intervalIDHighWater))"
        )
        intervalIDHighWater = id
        intervals = intervals.inserting(
            range: byteRange, id: id, frontAdvance: frontAdvance, rearAdvance: rearAdvance)
    }

    /// Every interval overlapping `byteRange`, under GNU's `overlays-in` rule
    /// (`dev/specs/m1.4.md` 1.7): `includingEmptyAtUpperBound` is computed here — the only
    /// place that knows the buffer's end — as `byteRange.isEmpty || byteRange.upperBound ==
    /// text.utf8Count`, the clause `IntervalTree` itself takes as a parameter rather than
    /// deciding on its own, since it holds no text (`dev/specs/m1.4.md` 1.6's closing
    /// paragraph, "the `bufferEnd` clause is the caller's, not the tree's").
    package func intervals(overlapping byteRange: Range<Int>) -> [IntervalSpan] {
        intervals.intervals(
            overlapping: byteRange,
            includingEmptyAtUpperBound: byteRange.isEmpty
                || byteRange.upperBound == text.utf8Count)
    }

    // MARK: - Undo replay primitives (`dev/specs/m1.5.md` 1.4)

    /// Removes marker `id` at `byteOffset` if present, doing nothing otherwise — `TextBuffer`
    /// undo/redo's step 1, "an id that is not present is skipped, not a trap" (marker
    /// *removal* is not undoable, so a branch walked after the user deleted one of these must
    /// not crash). Bypasses `createMarker`'s high-water precondition entirely, on purpose:
    /// this re-inserts an id that already exists, through `MarkerTree.inserting` directly,
    /// never through the checked creation path (`dev/specs/m1.5.md` mutation 10's withdrawal
    /// note explains why no undo sequence can make that unsafe).
    @discardableResult
    package mutating func removeMarkerIfPresent(id: MarkerID, atByteOffset byteOffset: Int) -> Bool
    {
        guard let updated = markers.removingIfPresent(id: id, atByteOffset: byteOffset) else {
            return false
        }
        markers = updated
        return true
    }

    /// Re-inserts a marker at a **recorded** position (`dev/specs/m1.5.md` 1.4 step 3) — the
    /// replay counterpart to `removeMarkerIfPresent`, going straight to `MarkerTree.inserting`
    /// rather than `createMarker`, since the id already exists and must not be validated
    /// against the high-water mark again.
    package mutating func insertMarker(id: MarkerID, atByteOffset byteOffset: Int, bias: MarkerBias)
    {
        markers = markers.inserting(byteOffset: byteOffset, bias: bias, id: id)
    }

    /// Removes interval `id` starting at `byteOffset` if present, mirroring
    /// `removeMarkerIfPresent`.
    @discardableResult
    package mutating func removeIntervalIfPresent(id: IntervalID, startingAt byteOffset: Int)
        -> Bool
    {
        guard let updated = intervals.removingIfPresent(id: id, startingAt: byteOffset) else {
            return false
        }
        intervals = updated
        return true
    }

    /// Re-inserts an interval at a recorded span, mirroring `insertMarker`.
    package mutating func insertInterval(
        id: IntervalID, range: Range<Int>, frontAdvance: Bool, rearAdvance: Bool
    ) {
        intervals = intervals.inserting(
            range: range, id: id, frontAdvance: frontAdvance, rearAdvance: rearAdvance)
    }
}
