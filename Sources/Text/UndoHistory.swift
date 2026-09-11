/// Transaction-based undo (M1.5 stage 1, `dev/specs/m1.5.md`): a branching history of
/// **elementary edits**, held as a flat, append-only array of nodes linked
/// first-child/next-sibling rather than a `class Node { var next: Node? }` chain or a
/// per-node `children: [Int32]` array — see this file's header sections below and the spec's
/// section 1.6 for the full derivation.
///
/// **No retained `BufferSnapshot`s.** Undoing replays the inverse of each elementary edit
/// through the one funnel (`BufferSnapshot.replaceSubrange`); this type holds no
/// `BufferSnapshot` itself and applies nothing — it is pure data plus navigation. `TextBuffer`
/// (`TextBuffer.swift`) is the owner that pairs a live snapshot with this history and does the
/// actual replay (`dev/specs/m1.5.md` 1.1, 1.4).
///
/// **First-child/next-sibling, not `children: [Int32]`.** A per-node array allocates a heap
/// buffer for every node, including the overwhelmingly common single-child one; two `Int32`
/// fields cost nothing, keep `Node` a fixed-size struct, and make enumerating a node's
/// children O(k) (not a hot path). `dev/specs/m1.5.md` 1.6.
///
/// **Indices, not object references.** Releasing a 1M-node linear chain of `class Node { var
/// next: Node? }` recursively segfaults on this machine, measured (`CLAUDE.md`'s "long chains
/// are torn down iteratively" rule). A flat array of structs releases in one pass — this is
/// the most important representation decision in this file and has nothing to do with
/// branching.
///
/// **The invariant that makes `canUndo` a one-liner** (`dev/specs/m1.5.md` 1.9): `edits.
/// isEmpty` holds exactly when `parent == -1`. No node is ever created empty (`TextBuffer.
/// commitTransaction()` appends nothing when there is nothing pending), and all three ways a
/// node becomes empty — the genesis node, a promotion, a tombstone — set `parent = -1`. So
/// `canUndo` is `nodes[current].parent != -1` with no second case, and `checkInvariants()`
/// asserts the equivalence on every node, matching `MarkerTree`/`IntervalTree`'s convention of
/// checking structural invariants rather than trusting them.
///
/// **Stage 1 builds the payload primitives with no policy over them** (`dev/specs/m1.5.md`
/// 1.9, deliverable C): `byteCost` per node, a running total maintained on release (not
/// recomputed by a sweep), and the `tombstone`/`promote` pair. Stage 1 enforces no budget and
/// calls neither primitive from the edit path; stage 2 decides when to call them.
///
/// **`promote` discards only the incoming edge, both its halves.** It clears `node`'s own
/// `parent`/`nextSibling`/`edits`/`byteCost` and keeps `firstChild`, *and* it splices `node`
/// out of its old parent's `firstChild`/`nextSibling` chain and resets that parent's
/// `lastVisitedChild` if it named `node` — mirroring the repair `tombstone` already does for
/// whoever pointed at its root. It deliberately leaves `node`'s own subtree untouched: no
/// descendant's `lastVisitedChild` is touched, because the hazard `tombstone` guards against
/// (a stale pointer into a released subtree) does not arise for a kept one. See `promote`'s
/// own doc comment for the incident that found the old parent's half missing.
package struct UndoHistory: Sendable {
    /// One node in the history tree: the edge from `parent` to here is `edits`, the ordered
    /// elementary edits that transform the buffer at `parent`'s state into the buffer at this
    /// node's state.
    package struct Node: Sendable {
        package var parent: Int32
        package var firstChild: Int32
        package var nextSibling: Int32
        package var lastVisitedChild: Int32
        package var edits: [ElementaryEdit]
        package var byteCost: Int

        package init(
            parent: Int32, firstChild: Int32, nextSibling: Int32, lastVisitedChild: Int32,
            edits: [ElementaryEdit], byteCost: Int
        ) {
            self.parent = parent
            self.firstChild = firstChild
            self.nextSibling = nextSibling
            self.lastVisitedChild = lastVisitedChild
            self.edits = edits
            self.byteCost = byteCost
        }
    }

    /// Append-only, creation order, never reordered (`dev/specs/m1.5.md` 1.6 property 1: this
    /// is what makes GNU's linear `buffer-undo-list` a derivable view — the reverse derivation
    /// is not available, which is why this direction was chosen). A tombstoned slot stays in
    /// place (its payload released); compaction needs node ids that survive renumbering,
    /// which is M5's generation counter with its first real caller (`dev/specs/m1.5.md`
    /// section 8).
    private var nodes: [Node]

    /// The node whose state the buffer is in.
    package private(set) var current: Int32

    /// The running total of every live node's `byteCost`, maintained by each release
    /// (`tombstone`/`promote`) rather than recomputed by a sweep — `dev/specs/m1.5.md` 1.9,
    /// test 19 and test 23 are what this buys.
    package private(set) var totalByteCost: Int

    /// A fresh history: one genesis node (index 0), empty, `parent == -1`.
    package init() {
        self.nodes = [
            Node(
                parent: -1, firstChild: -1, nextSibling: -1, lastVisitedChild: -1, edits: [],
                byteCost: 0)
        ]
        self.current = 0
        self.totalByteCost = 0
    }

    // MARK: - Queries

    package var canUndo: Bool { nodes[Int(current)].parent != -1 }
    package var canRedo: Bool { nodes[Int(current)].lastVisitedChild != -1 }
    package var nodeCount: Int { nodes.count }

    /// Read-only access to a node's payload, for tests and for `TextBuffer`'s traversal.
    package func node(_ id: Int32) -> Node { nodes[Int(id)] }

    /// Every child of `node`, in the order the first-child/next-sibling list holds them
    /// (most-recently-recorded first — `recordTransaction` prepends). O(k), not a hot path.
    package func children(of node: Int32) -> [Int32] {
        var result: [Int32] = []
        var child = nodes[Int(node)].firstChild
        while child != -1 {
            result.append(child)
            child = nodes[Int(child)].nextSibling
        }
        return result
    }

    // MARK: - Recording (`dev/specs/m1.5.md` 1.7)

    /// The fixed per-node overhead in `byteCost`'s formula (`dev/specs/m1.5.md` 1.9): the
    /// `Node` struct's own fixed-size fields (four `Int32` plus one `Int`, `edits`
    /// contributing only its array header — the elements themselves are counted separately
    /// by the formula's other terms). Not an independently measured constant; the reasoned
    /// choice stage 2 inherits as settled per 1.9.
    package static let nodeFixedOverhead = MemoryLayout<Node>.stride

    /// `byteCost` per `dev/specs/m1.5.md` 1.9: the sum of every edit's deleted/inserted byte
    /// counts plus its adjustment-entry counts times each entry type's stride, plus the fixed
    /// per-node overhead once.
    package static func byteCost(of edits: [ElementaryEdit]) -> Int {
        var total = nodeFixedOverhead
        for edit in edits {
            total += edit.deleted.utf8Count
            total += edit.inserted.utf8Count
            total += edit.markerEntries.count * MemoryLayout<MarkerEntry>.stride
            total += edit.intervalEntries.count * MemoryLayout<IntervalEntry>.stride
        }
        return total
    }

    /// Appends a new node as a child of `current` — prepended to `current`'s child list (the
    /// most recently recorded transaction is walked first by `children(of:)`), and sets
    /// `current`'s `lastVisitedChild` to the fresh node, so a subsequent redo prefers the
    /// branch just edited (`dev/specs/m1.5.md` 1.6: "so that edit, undo, redo returns to the
    /// edit just made"). Moves `current` to the new node. No code path differs between the
    /// one-child and the many-child case.
    @discardableResult
    package mutating func recordTransaction(edits: [ElementaryEdit]) -> Int32 {
        precondition(!edits.isEmpty, "UndoHistory.recordTransaction: edits must not be empty")
        let parent = current
        let newIndex = Int32(nodes.count)
        let cost = Self.byteCost(of: edits)
        let newNode = Node(
            parent: parent, firstChild: -1, nextSibling: nodes[Int(parent)].firstChild,
            lastVisitedChild: -1, edits: edits, byteCost: cost)
        nodes.append(newNode)
        nodes[Int(parent)].firstChild = newIndex
        nodes[Int(parent)].lastVisitedChild = newIndex
        current = newIndex
        totalByteCost += cost
        return newIndex
    }

    // MARK: - Traversal

    /// Moves `current` to its parent, applying that node's `edits` backward (the caller's
    /// job — this type applies nothing). Returns the traversed edge's node id (the child end,
    /// same convention `moveToLastVisitedChild` uses) and its `edits`, or `nil` when
    /// `!canUndo`.
    package mutating func moveToParent() -> (node: Int32, edits: [ElementaryEdit])? {
        let child = current
        let parent = nodes[Int(child)].parent
        guard parent != -1 else { return nil }
        let edits = nodes[Int(child)].edits
        current = parent
        return (child, edits)
    }

    /// Moves `current` to its `lastVisitedChild`, applying that node's `edits` forward (the
    /// caller's job). Returns the traversed edge's node id and its `edits`, or `nil` when
    /// `!canRedo`.
    package mutating func moveToLastVisitedChild() -> (node: Int32, edits: [ElementaryEdit])? {
        let child = nodes[Int(current)].lastVisitedChild
        guard child != -1 else { return nil }
        current = child
        return (child, nodes[Int(child)].edits)
    }

    // MARK: - Payload primitives (`dev/specs/m1.5.md` 1.9, deliverable C)

    /// Removes an entire subtree from the reachable graph, **leaves-first**: the worklist
    /// walks the subtree in full before any link is cleared, so the walk cannot lose nodes it
    /// has not reached yet (`dev/specs/m1.5.md` 1.9 — an undo tree is not height-logarithmic,
    /// so this is an explicit worklist, never recursion, matching `CLAUDE.md`'s "long chains
    /// are torn down iteratively" rule). Every tombstoned node's `parent`, `firstChild` and
    /// `nextSibling` become `-1`, its `edits` are released (and `totalByteCost` debited), and
    /// any `lastVisitedChild` elsewhere in the tree that pointed at it is reset to `-1`.
    /// Whoever pointed at `root` itself (its former parent's child list) is repaired so
    /// `root` is no longer reachable at all.
    ///
    /// Caller's responsibility: `root` must not be an ancestor of `current` (tombstoning a
    /// live branch is not this primitive's job to prevent — stage 2 owns the policy that
    /// decides when this is safe to call).
    package mutating func tombstone(_ root: Int32) {
        // Captured before the walk below clears them — `root` may already be a disconnected
        // root-shaped node (the genesis node, or a previously promoted/tombstoned one), in
        // which case `originalParent == -1` and the repair step below is skipped.
        let originalParent = nodes[Int(root)].parent
        let originalNextSibling = nodes[Int(root)].nextSibling

        tombstoneSubtreePayload(root)

        guard originalParent != -1 else { return }
        if nodes[Int(originalParent)].firstChild == root {
            nodes[Int(originalParent)].firstChild = originalNextSibling
        } else {
            var sibling = nodes[Int(originalParent)].firstChild
            while sibling != -1 {
                if nodes[Int(sibling)].nextSibling == root {
                    nodes[Int(sibling)].nextSibling = originalNextSibling
                    break
                }
                sibling = nodes[Int(sibling)].nextSibling
            }
        }
    }

    /// The leaves-first worklist walk shared by `tombstone(_:)`'s two entry shapes: collects
    /// the subtree with a pre-order stack walk, then clears every node's payload and internal
    /// links in the reverse of that order (children before their parent, since a tree's
    /// pre-order visits every parent strictly before its children).
    private mutating func tombstoneSubtreePayload(_ root: Int32) {
        var order: [Int32] = []
        var stack: [Int32] = [root]
        while let n = stack.popLast() {
            order.append(n)
            var child = nodes[Int(n)].firstChild
            while child != -1 {
                stack.append(child)
                child = nodes[Int(child)].nextSibling
            }
        }
        for n in order.reversed() {
            let parent = nodes[Int(n)].parent
            if parent != -1, nodes[Int(parent)].lastVisitedChild == n {
                nodes[Int(parent)].lastVisitedChild = -1
            }
            totalByteCost -= nodes[Int(n)].byteCost
            nodes[Int(n)].edits = []
            nodes[Int(n)].byteCost = 0
            nodes[Int(n)].parent = -1
            nodes[Int(n)].firstChild = -1
            nodes[Int(n)].nextSibling = -1
            nodes[Int(n)].lastVisitedChild = -1
        }
    }

    /// Keeps `node` in the graph and discards only its incoming edge: `parent = -1`, `edits =
    /// []`, `nextSibling = -1`, and **`firstChild` is kept**, so a walk from the promoted root
    /// still reaches `current` (`dev/specs/m1.5.md` 1.9 — a draft that cleared `firstChild`
    /// here would cut the live tree loose; test 18a is the guard). `totalByteCost` is debited
    /// by the released `byteCost`.
    ///
    /// **The old parent's half of the incoming edge is spliced away too, mirroring
    /// `tombstone`.** A fix round found the first version of this function touched only
    /// `node`'s own fields, leaving `node` reachable from `children(of: oldParent)` and, when
    /// `oldParent.lastVisitedChild` named `node`, leaving a `redo()` from `oldParent` walk
    /// into a node whose `edits` are now `[]` — applying nothing to the text while `canUndo`
    /// reports `false`, and a further redo into `node`'s kept children then applying recorded
    /// byte ranges to a buffer that never received `node`'s own edits. So `promote` now
    /// splices `node` out of `oldParent`'s `firstChild`/`nextSibling` chain exactly as
    /// `tombstone` does, and resets `oldParent.lastVisitedChild` to `-1` if it named `node` —
    /// the one place a stale `lastVisitedChild` could point at `node`, since `lastVisitedChild`
    /// is a node's pointer to its own child. **What this deliberately does not do**: it does
    /// not touch `node`'s own `firstChild` or its descendants' `lastVisitedChild` pointers —
    /// `node` and everything under it stay exactly as they were, which is the whole point of
    /// "promote" versus "tombstone" (this discards only the incoming edge, not the subtree).
    /// Stage 2 pairs a promote of the new root with a `tombstone` of whatever else needs to go.
    package mutating func promote(_ node: Int32) {
        let originalParent = nodes[Int(node)].parent
        let originalNextSibling = nodes[Int(node)].nextSibling

        totalByteCost -= nodes[Int(node)].byteCost
        nodes[Int(node)].parent = -1
        nodes[Int(node)].nextSibling = -1
        nodes[Int(node)].edits = []
        nodes[Int(node)].byteCost = 0

        guard originalParent != -1 else { return }
        if nodes[Int(originalParent)].firstChild == node {
            nodes[Int(originalParent)].firstChild = originalNextSibling
        } else {
            var sibling = nodes[Int(originalParent)].firstChild
            while sibling != -1 {
                if nodes[Int(sibling)].nextSibling == node {
                    nodes[Int(sibling)].nextSibling = originalNextSibling
                    break
                }
                sibling = nodes[Int(sibling)].nextSibling
            }
        }
        if nodes[Int(originalParent)].lastVisitedChild == node {
            nodes[Int(originalParent)].lastVisitedChild = -1
        }
    }

    // MARK: - Discard (deliverable I)

    /// Resets the whole history to a fresh genesis node. No policy: this needs none, unlike
    /// pruning (`dev/specs/m1.5.md` deliverable I). Leaves no way to undo past this point.
    package mutating func discardHistory() {
        self = UndoHistory()
    }

    // MARK: - Invariants (deliverable D)

    /// Checks the `edits.isEmpty` / `parent == -1` equivalence of `dev/specs/m1.5.md` 1.9 on
    /// every node, plus the link consistency `tombstone`/`promote` must maintain: every
    /// non-`-1` `parent`/`lastVisitedChild` reference points at an in-bounds node that agrees
    /// about the relationship (the child is reachable in the parent's child list; a
    /// `lastVisitedChild` actually has that node as its `parent`) — **and the converse**:
    /// every node reachable through `children(of: X)` actually has `parent == X`, so a
    /// forward-only check (a fix round found the first version checked only "parent implies
    /// reachable") cannot miss a node that is in some other node's child list without that
    /// other node being its recorded parent. Called from the differential test's cadence, not
    /// from the edit path — matching `MarkerTree`/`IntervalTree`'s own `checkInvariants()`
    /// convention.
    package func checkInvariants() throws {
        var violations: [String] = []
        // Every node's child list, walked once. Once per node and not once per *check* is
        // what keeps one malformed chain from being reported as many identical violations:
        // the forward check needs the parent's list and the reverse check needs the node's
        // own, and before this pass existed a cyclic chain out of one node was walked, and
        // reported, once for the node itself and once for each of its children. A review
        // round counted three copies of one message in a three-node fixture.
        var childLists: [[Int32]] = []
        childLists.reserveCapacity(nodes.count)
        for i in 0..<nodes.count {
            let (list, walkViolations) = safeChildren(of: Int32(i))
            childLists.append(list)
            violations.append(contentsOf: walkViolations)
        }

        for i in 0..<nodes.count {
            let node = nodes[i]
            let isEmpty = node.edits.isEmpty
            let isRoot = node.parent == -1
            if isEmpty != isRoot {
                violations.append(
                    "node \(i): edits.isEmpty (\(isEmpty)) does not match parent == -1 (\(isRoot))"
                )
            }
            if isRoot, node.byteCost != 0 {
                violations.append("node \(i): parent == -1 but byteCost \(node.byteCost) != 0")
            }
            if node.byteCost < 0 {
                violations.append("node \(i): negative byteCost \(node.byteCost)")
            }
            if node.parent != -1 {
                guard node.parent >= 0, Int(node.parent) < nodes.count else {
                    violations.append("node \(i): parent \(node.parent) out of bounds")
                    continue
                }
                let siblings = childLists[Int(node.parent)]
                if !siblings.contains(Int32(i)) {
                    violations.append(
                        "node \(i): not reachable in parent \(node.parent)'s child list")
                }
            }
            if node.lastVisitedChild != -1 {
                guard node.lastVisitedChild >= 0, Int(node.lastVisitedChild) < nodes.count else {
                    violations.append(
                        "node \(i): lastVisitedChild \(node.lastVisitedChild) out of bounds")
                    continue
                }
                if nodes[Int(node.lastVisitedChild)].parent != Int32(i) {
                    violations.append(
                        "node \(i): lastVisitedChild \(node.lastVisitedChild) does not have \(i) as its parent"
                    )
                }
            }
            // The converse of the `parent` check above: every node reachable through node
            // `i`'s child list must actually name `i` as its `parent`, so a node cannot be in
            // some other node's child list without that node being its recorded parent. The
            // walk goes through `safeChildren(of:)` rather than `children(of:)` because a
            // malformed link must be *reported* here, not trapped on: `children(of:)`
            // subscripts `nodes` with each link unchecked, so an out-of-bounds `nextSibling`
            // crashes the process one frame before any guard in this loop could see it, and a
            // cyclic chain never returns at all. A cold review round found the first version
            // of this check bounds-testing indices it had already dereferenced.
            for child in childLists[i] where nodes[Int(child)].parent != Int32(i) {
                violations.append(
                    "node \(i): child list contains \(child), whose parent is \(nodes[Int(child)].parent), not \(i)"
                )
            }
        }
        let sumByteCost = nodes.reduce(0) { $0 + $1.byteCost }
        if sumByteCost != totalByteCost {
            violations.append(
                "totalByteCost \(totalByteCost) does not equal the sum of live nodes' byteCost \(sumByteCost)"
            )
        }
        if !violations.isEmpty {
            throw UndoHistoryInvariantViolation(messages: violations)
        }
    }

    /// `children(of:)`'s defensive twin, for `checkInvariants()` only: walks the same
    /// first-child/next-sibling chain but bounds-checks every link **before** subscripting
    /// `nodes` with it, and stops after `nodes.count` steps. Both guards exist because the
    /// caller's job is to *report* a malformed history rather than trap on one — a checker
    /// that crashes on the corruption it is meant to describe cannot be tested against a
    /// hand-built violation, which is the whole point of `init(testOnlyNodes:)`. Returns the
    /// nodes it reached plus one message per structural fault found while reaching them.
    private func safeChildren(of node: Int32) -> ([Int32], [String]) {
        var result: [Int32] = []
        var violations: [String] = []
        guard node >= 0, Int(node) < nodes.count else {
            return (result, ["child walk: start index \(node) out of bounds"])
        }
        var child = nodes[Int(node)].firstChild
        var steps = 0
        while child != -1 {
            guard child >= 0, Int(child) < nodes.count else {
                violations.append("node \(node): child list contains out-of-bounds index \(child)")
                break
            }
            if steps > nodes.count {
                violations.append(
                    "node \(node): child list does not terminate within \(nodes.count) steps")
                break
            }
            result.append(child)
            steps += 1
            child = nodes[Int(child)].nextSibling
        }
        return (result, violations)
    }

    // MARK: - Test-only affordances

    /// Builds a hand-shaped `UndoHistory` directly from its raw fields, bypassing every
    /// invariant-preserving entry point — `MarkerTree`/`IntervalTree`'s own
    /// `testOnlyTree`/`init(testOnlyTree:)` precedent for the same reason: a test needs a
    /// deliberately malformed instance to prove `checkInvariants()` actually rejects one
    /// (`sumTreeTests.swift`'s negative-test precedent). `internal`, not `private`: visible
    /// only via `@testable import Text`.
    internal init(testOnlyNodes nodes: [Node], current: Int32, totalByteCost: Int) {
        self.nodes = nodes
        self.current = current
        self.totalByteCost = totalByteCost
    }
}

/// Mirrors `SumTreeInvariantViolation`'s shape (`SumTree.swift:589`).
package struct UndoHistoryInvariantViolation: Error, CustomStringConvertible, Sendable {
    package let messages: [String]
    package var description: String { messages.joined(separator: "; ") }
}

// MARK: - The entry set (`dev/specs/m1.5.md` 1.2-1.4)

/// One elementary edit: exactly one funnel call (`dev/specs/m1.5.md` 1.2). `deleted` holds
/// the pre-edit nodes alive — the real memory cost `byteCost` counts; `inserted` shares with
/// the live text and is free while that text stands. `insertBeforeMarkers` is deliberately
/// not a field: 1.5 proves it is unobservable during replay (every item whose behaviour
/// depends on it is in the entry set, out of the tree during the replacement, and restored
/// from the recorded position rather than from the rules).
package struct ElementaryEdit: Sendable {
    /// The range replaced, in pre-edit coordinates.
    package let byteRange: Range<Int>
    /// What was there.
    package let deleted: Rope
    /// What replaced it.
    package let inserted: Rope
    /// The marker entry set (`dev/specs/m1.5.md` 1.3): every marker whose pre-edit offset lay
    /// in the closed `[byteRange.lowerBound, byteRange.upperBound]`, in tree (key) order.
    package let markerEntries: [MarkerEntry]
    /// The interval entry set (`dev/specs/m1.5.md` 1.3): every interval with an endpoint in
    /// that same closed range, in `IntervalTree.undoEntrySet`'s order.
    package let intervalEntries: [IntervalEntry]

    package init(
        byteRange: Range<Int>, deleted: Rope, inserted: Rope, markerEntries: [MarkerEntry],
        intervalEntries: [IntervalEntry]
    ) {
        self.byteRange = byteRange
        self.deleted = deleted
        self.inserted = inserted
        self.markerEntries = markerEntries
        self.intervalEntries = intervalEntries
    }
}

/// One marker's before/after position across an elementary edit (`dev/specs/m1.5.md` 1.4).
/// `bias` never changes under any edit, so it is carried once rather than as a before/after
/// pair; it is needed because re-inserting a marker needs it.
package struct MarkerEntry: Sendable {
    package let id: MarkerID
    package let bias: MarkerBias
    package let beforeOffset: Int
    package let afterOffset: Int

    package init(id: MarkerID, bias: MarkerBias, beforeOffset: Int, afterOffset: Int) {
        self.id = id
        self.bias = bias
        self.beforeOffset = beforeOffset
        self.afterOffset = afterOffset
    }
}

/// One interval's before/after span across an elementary edit (`dev/specs/m1.5.md` 1.4).
///
/// **Deviation from the spec's literal struct** (reported per the fixed clauses): 1.4's text
/// gives `IntervalEntry` four fields — `id`, `beforeStart`, `beforeLength`, `afterStart`,
/// `afterLength` — with no `frontAdvance`/`rearAdvance`. Those two flags never change under
/// any edit (1.4's own sentence establishing that is what justifies omitting a before/after
/// *pair* for them), but re-inserting an interval calls `IntervalTree.inserting(range:id:
/// frontAdvance:rearAdvance:)`, which needs their values, and after `removingIfPresent` takes
/// the item out of the tree there is nowhere else to read them from. The struct below adds
/// both as single fields, exactly the way `MarkerEntry` carries `bias` — the same omission
/// class, not a design disagreement. This is a struct-field-list gap, not an architectural
/// ruling, so it is fixed here and reported rather than escalated.
package struct IntervalEntry: Sendable {
    package let id: IntervalID
    package let beforeStart: Int
    package let beforeLength: Int
    package let afterStart: Int
    package let afterLength: Int
    package let frontAdvance: Bool
    package let rearAdvance: Bool

    package init(
        id: IntervalID, beforeStart: Int, beforeLength: Int, afterStart: Int, afterLength: Int,
        frontAdvance: Bool, rearAdvance: Bool
    ) {
        self.id = id
        self.beforeStart = beforeStart
        self.beforeLength = beforeLength
        self.afterStart = afterStart
        self.afterLength = afterLength
        self.frontAdvance = frontAdvance
        self.rearAdvance = rearAdvance
    }
}
