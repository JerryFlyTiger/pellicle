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
/// **Not `TextBuffer` yet.** `PLAN.md` 4.5 sketches it as a class with `overlays`, `history`
/// and `clock` — three fields that do not exist yet. A value type with a `mutating` edit
/// gives atomicity without inventing an ownership model before there is an owner. No
/// `clock`/`version` field either: nothing would read it yet, and an unread field is a
/// standing chance to be wrong (M1.5 adds it with its first consumer).
///
/// The monotone marker-ID counter lives here, not on `MarkerTree`, because a `MarkerTree` is
/// a value with no notion of "the next ID this buffer has not yet handed out" — forking a
/// snapshot and editing both branches reuses IDs (`MarkerTree.swift`'s known-gaps list; M1.5's
/// branching undo is the milestone that must decide the allocation story).
package struct BufferSnapshot: Sendable {
    package private(set) var text: Rope
    package private(set) var markers: MarkerTree
    private var nextMarkerID: MarkerID

    package init() {
        self.text = Rope()
        self.markers = MarkerTree()
        self.nextMarkerID = 0
    }

    // No `init(text:markers:)`. It would have to fabricate `nextMarkerID` (colliding with
    // any IDs already in `markers`, since `MarkerID`'s doc comment requires monotone,
    // never-reused IDs) and validate that `markers`' offsets lie inside `text` on scalar
    // boundaries — real work with no caller to justify it yet (every test here uses
    // `BufferSnapshot()`, and `dev/specs/m1.3.md` section 2.C never asked for bulk
    // construction). Add it with a real `nextMarkerID` derivation and real validation when a
    // caller needs it.

    /// The one edit funnel: replaces `byteRange` in `text` with `other`, then applies the
    /// same edit to `markers` via `MarkerTree.applyEdit` — same `byteRange`, and
    /// `insertedLength` read from `other.utf8Count` (the only two facts `applyEdit` needs,
    /// both already in scope here, matching `Rope.replaceSubrange`'s own funnel comment that
    /// this is the only call site where both are available at once).
    package mutating func replaceSubrange(
        _ byteRange: Range<Int>, with other: Rope, insertBeforeMarkers: Bool = false
    ) {
        text.replaceSubrange(byteRange, with: other)
        markers = markers.applyEdit(
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

    /// Creates a new marker at `atByteOffset`, preconditioning the offset is a scalar
    /// boundary via `Rope.isScalarBoundary` — the check `MarkerTree` alone cannot do, since
    /// it does not hold the text (`dev/specs/m1.3.md` section 2.C). Returns the fresh,
    /// never-reused id.
    package mutating func createMarker(atByteOffset byteOffset: Int, bias: MarkerBias) -> MarkerID {
        precondition(
            byteOffset >= 0 && byteOffset <= text.utf8Count,
            "BufferSnapshot.createMarker: byte offset out of range")
        precondition(
            text.isScalarBoundary(byteOffset),
            "BufferSnapshot.createMarker: byte offset \(byteOffset) is not a scalar boundary")
        let id = nextMarkerID
        nextMarkerID += 1
        markers = markers.inserting(byteOffset: byteOffset, bias: bias, id: id)
        return id
    }
}
