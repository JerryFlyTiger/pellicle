/// The generic persistent B+-tree (PLAN.md 4.5): `Rope` is one instance of it (`Item ==
/// Chunk`, `Item_Summary == TextSummary`); M1.4's overlay/interval tree will be another
/// (`Node<OverlayRecord>`), which is why the tree is generic over its item and summary
/// rather than specialised to text from the start.
///
/// **Persistence.** Every mutation rebuilds only the path to the edited leaves and returns
/// a new tree; an existing `SumTree` value is never mutated in place by an edit derived
/// from a copy of it. `Node`'s payload is always a Swift `Array`, which already provides
/// the indirection a tree needs (copying an array is an O(1) retain), so a snapshot is just
/// a struct copy — `Node` is deliberately **not** `indirect`: `indirect enum` costs an extra
/// heap box per node, on top of the box `Array` already gives the payload. Corrected,
/// measured on this machine: `MemoryLayout<Node<Chunk>>.stride` without `indirect` is **72**
/// (size 66) — not the 24 an earlier version of this comment claimed, which came from a
/// probe that used `Int` as the summary type rather than this tree's actual `TextSummary`
/// (56 bytes alone). The argument for not making `Node` indirect still holds regardless: an
/// extra heap allocation per node is the thing being avoided, and that is independent of
/// the struct's own size.
///
/// **Branching factor `B = 6`** (Zed's `sum_tree` constant): every node except the root
/// holds `B...2B` (6...12) items or children; the root holds `0...2B` when it is a leaf
/// (so the whole tree can be empty or small) and `2...2B` when it is interior. All leaves
/// are at the same depth, and every node caches the fold of its children's summaries.
///
/// **No recursive teardown, and that is fine here.** CLAUDE.md's "long chains are torn down
/// iteratively" rule exists because of a measured segfault releasing a 1M-node *linear*
/// chain recursively. A `SumTree` is not a chain: its height is logarithmic in the number
/// of items (a 2 GB rope is height ~7), so releasing one recurses on the order of 7 stack
/// frames deep, not 1,000,000. Do not write a manual teardown or a `close()` for this type;
/// that would be solving a problem this shape does not have.
///
/// Operations below are built from four primitives: `concat` (join two trees of any
/// heights), `split(where:)` (a monotone-predicate cursor that folds the triggering item
/// into its left result and splits there), `cut(where:)` (the cursor's other shape:
/// extracts the triggering item *by itself*, with everything before and after it as
/// separate trees), and `find(where:)` (a read-only cursor that only *looks at* the
/// triggering item — no split, no copy, no rebuild). `split` and `cut` are not redundant
/// with each other: a `>=`-style predicate compared against a tree's own total summary finds
/// the *last* item either way, but only `cut` can hand that single item back on its own —
/// `split`, by construction, always folds the triggering item into its left-hand result, so
/// it can never isolate a tree's last item alone (see `cutNode`'s doc comment). `find` is
/// `cut` without the two halves: genuinely O(h), because it descends without ever calling
/// `buildFromNodes` (see `findNode`'s doc comment) — the only one of the four primitives for
/// which the O(log n) claim below already holds. Bulk build from a sequence of items is
/// implemented on top of `concat` by recursive halving, which is simpler than a bespoke
/// bulk-loader and inherits `concat`'s correctness.
///
/// **`concat` is O(log n) in the taller tree's height; `split`/`cut` are not, yet, despite
/// an earlier version of this comment calling all three "O(log n)".** `splitNode`/`cutNode`
/// call `buildFromNodes` at *every level* of their descent, and `buildFromNodes` folds
/// `concatNodes` across up to `B + 1` sibling nodes, each fold being O(h) and copying arrays
/// of up to 12 `Node`s — so a single cursor walk does O(B · h²) node reconstructions, not
/// O(h). Measured on a 1 MB rope: `Rope.isScalarBoundary` (one `cut`, nothing else) costs
/// 131 µs, and inserting one byte costs ~400 node reconstructions for what a persistent
/// B-tree insert should do in ~5 (see `M1.1-perf-findings.md`). Round 2 of M1.1 is what
/// makes the O(log n) claim true, by replacing `buildFromNodes`'s per-level fold with a
/// path-copy edit that joins the accumulated left/right subtree lists once, bottom-up; that
/// rewrite is out of this round's scope. Do not delete this paragraph once round 2 lands —
/// update it to describe the code as it then is (see `Rope.locate`'s doc comment for the
/// same claim, made about the caller).
///
/// Known gap: `split`/`cut` only ever land on **item boundaries** (whatever `Item` is — a
/// whole `Chunk`, for the rope). Splitting *inside* an item (e.g. a byte offset in the
/// middle of a `Chunk`) is the caller's job; `Rope.swift` does this by extracting the one
/// item in question with `cut`, slicing its payload itself, and rejoining with `concat`.

/// A monoid summarising a run of items. Identity is a two-sided identity for `+`
/// (`identity + x == x + identity == x`), and `+` must be associative — that is what makes
/// a cached summary trustworthy regardless of how the tree balances.
package protocol Summary: Sendable, Equatable {
    static var identity: Self { get }
    static func + (lhs: Self, rhs: Self) -> Self
}

/// Something a `SumTree` can hold at its leaves: anything with a `Summary`.
package protocol Summable: Sendable {
    associatedtype Item_Summary: Summary
    var summary: Item_Summary { get }
}

/// A node of the tree. `leaf` holds items directly; `interior` holds child nodes, plus the
/// node's own height (0 for a leaf, one more than its children's for an interior node) so
/// `concat` and `split` can compare heights without walking down to find them.
package enum Node<Item: Summable>: Sendable {
    case leaf([Item], Item.Item_Summary)
    case interior([Node<Item>], Item.Item_Summary, UInt8)
}

extension Node {
    package var summary: Item.Item_Summary {
        switch self {
        case .leaf(_, let s): return s
        case .interior(_, let s, _): return s
        }
    }

    package var height: UInt8 {
        switch self {
        case .leaf: return 0
        case .interior(_, _, let h): return h
        }
    }

    fileprivate static func makeLeaf(_ items: [Item]) -> Node<Item> {
        .leaf(items, items.reduce(Item.Item_Summary.identity) { $0 + $1.summary })
    }

    fileprivate static func makeInterior(_ children: [Node<Item>]) -> Node<Item> {
        precondition(!children.isEmpty, "an interior node must have at least one child")
        let height = children[0].height + 1
        let summary = children.reduce(Item.Item_Summary.identity) { $0 + $1.summary }
        return .interior(children, summary, height)
    }

    fileprivate var isEmptyLeaf: Bool {
        if case .leaf(let items, _) = self { return items.isEmpty }
        return false
    }
}

/// The branching factor. Fixed at 6 by PLAN.md 4.5 (Zed's `sum_tree` constant).
private let branchingFactor = 6

/// Joins two trees of any heights into one, preserving every invariant. The standard
/// two-tree-join algorithm: equal heights merge (and split again if the merge overflows
/// `2B`); unequal heights descend into the taller tree's near child, recursing until the
/// heights match, then splice the (possibly-grown-by-one-level) result back in.
private func concatNodes<Item: Summable>(_ a: Node<Item>, _ b: Node<Item>) -> Node<Item> {
    // Equivalent mutant, recorded rather than chased with a test (CLAUDE.md: where a defence
    // cannot be observed by a test, say so instead of pretending): removing this short-circuit
    // changes no result. `makeLeaf([] + items)` is `makeLeaf(items)`, and the general descent
    // below rebuilds the identical tree from an empty leaf either way — it just does
    // measurably more work to get there (an extra fold and, at height mismatches, an extra
    // level of recursion). This is a performance guard, not a correctness guard.
    if a.isEmptyLeaf { return b }
    if b.isEmptyLeaf { return a }

    if a.height == b.height {
        switch (a, b) {
        case (.leaf(let aItems, let aSummary), .leaf(let bItems, let bSummary)):
            let combined = aItems + bItems
            if combined.count <= 2 * branchingFactor {
                // No overflow: the answer is just the two cached summaries added, not a
                // re-fold of `combined`'s items from scratch.
                return .leaf(combined, aSummary + bSummary)
            }
            let mid = combined.count / 2
            let left = Node.makeLeaf(Array(combined[0..<mid]))
            let right = Node.makeLeaf(Array(combined[mid...]))
            return .makeInterior([left, right])
        case (
            .interior(let aChildren, let aSummary, let height),
            .interior(let bChildren, let bSummary, _)
        ):
            let combined = aChildren + bChildren
            if combined.count <= 2 * branchingFactor {
                // Same reasoning as the leaf case above: no overflow, so no re-fold.
                return .interior(combined, aSummary + bSummary, height)
            }
            let mid = combined.count / 2
            let left = Node.makeInterior(Array(combined[0..<mid]))
            let right = Node.makeInterior(Array(combined[mid...]))
            return .makeInterior([left, right])
        default:
            preconditionFailure("concat: equal heights but one leaf, one interior")
        }
    } else if a.height > b.height {
        guard case .interior(let aChildren, _, _) = a else {
            preconditionFailure("concat: taller node must be interior")
        }
        let lastChild = aChildren[aChildren.count - 1]
        let merged = concatNodes(lastChild, b)
        var newChildren = Array(aChildren.dropLast())
        if merged.height == lastChild.height {
            newChildren.append(merged)
        } else {
            guard case .interior(let mergedChildren, _, _) = merged, mergedChildren.count == 2
            else {
                preconditionFailure("concat: unexpected growth shape")
            }
            newChildren.append(contentsOf: mergedChildren)
        }
        return rewrap(newChildren)
    } else {
        guard case .interior(let bChildren, _, _) = b else {
            preconditionFailure("concat: taller node must be interior")
        }
        let firstChild = bChildren[0]
        let merged = concatNodes(a, firstChild)
        var newChildren = Array(bChildren.dropFirst())
        if merged.height == firstChild.height {
            newChildren.insert(merged, at: 0)
        } else {
            guard case .interior(let mergedChildren, _, _) = merged, mergedChildren.count == 2
            else {
                preconditionFailure("concat: unexpected growth shape")
            }
            newChildren.insert(contentsOf: mergedChildren, at: 0)
        }
        return rewrap(newChildren)
    }
}

/// Wraps a freshly-spliced children list back into one node, splitting it in two (growing
/// the tree by one level) if it overflowed `2B`.
private func rewrap<Item: Summable>(_ children: [Node<Item>]) -> Node<Item> {
    if children.count <= 2 * branchingFactor {
        return .makeInterior(children)
    }
    let mid = children.count / 2
    let left = Node.makeInterior(Array(children[0..<mid]))
    let right = Node.makeInterior(Array(children[mid...]))
    return .makeInterior([left, right])
}

/// Builds the list of sibling nodes produced by a split back into one tree, by folding
/// `concat` across them left to right.
private func buildFromNodes<Item: Summable>(_ nodes: [Node<Item>]) -> Node<Item> {
    nodes.reduce(Node<Item>.makeLeaf([]), concatNodes)
}

/// Splits `node` at the first point where `predicate` becomes true of the running summary
/// (`prefix` plus everything examined so far). `predicate` must be monotone: false for small
/// accumulations, true from some point on. Returns `(everything before the flip point,
/// everything from it on)`; the flip item itself lands in the **left** tree once its own
/// summary has been folded in, matching a `>=`-style predicate written against a target
/// offset (see `Rope.swift`'s use of this for exact-offset splits via single-item leaves).
private func splitNode<Item: Summable>(
    _ node: Node<Item>,
    prefix: Item.Item_Summary,
    predicate: (Item.Item_Summary) -> Bool
) -> (Node<Item>, Node<Item>) {
    // The split point can be at the very start of `node` (e.g. a predicate like `count >=
    // 0`, which is already true of the empty prefix): check that before looking at any
    // item or child, so the loops below only ever need to check the accumulation *after*
    // adding each item/child, with the invariant that `predicate` is false on entry.
    if predicate(prefix) {
        return (.makeLeaf([]), node)
    }
    switch node {
    case .leaf(let items, _):
        var cum = prefix
        for i in 0..<items.count {
            let next = cum + items[i].summary
            if predicate(next) {
                let left = Array(items[0...i])
                let right = Array(items[(i + 1)...])
                return (.makeLeaf(left), .makeLeaf(right))
            }
            cum = next
        }
        return (node, .makeLeaf([]))
    case .interior(let children, _, _):
        var cum = prefix
        for i in 0..<children.count {
            let next = cum + children[i].summary
            if predicate(next) {
                let (childLeft, childRight) = splitNode(
                    children[i], prefix: cum, predicate: predicate)
                let leftNodes = Array(children[0..<i]) + [childLeft]
                let rightNodes = [childRight] + Array(children[(i + 1)...])
                return (buildFromNodes(leftNodes), buildFromNodes(rightNodes))
            }
            cum = next
        }
        return (node, .makeLeaf([]))
    }
}

/// Extracts the single item at the first point where `predicate` becomes true of the
/// running summary, returning the items strictly before it, the item itself (with its own
/// prefix summary), and the items strictly after it. This is `splitNode`'s sibling, not a
/// composition of two splits: `splitNode` folds the triggering item into its *left* result
/// (so that a `>=`-style predicate against a tree's own total summary can never isolate
/// "everything but the last item" — the trigger only ever fires once every item, including
/// the last, has already been folded in). Extracting one item's neighbourhood needs its own
/// single-pass walk, which is what this function is for. `predicate` must be monotone, and
/// is assumed to be false of `prefix` itself (the caller already knows the target item is
/// within this node's range); returns `nil` if it never triggers (malformed usage).
private func cutNode<Item: Summable>(
    _ node: Node<Item>,
    prefix: Item.Item_Summary,
    predicate: (Item.Item_Summary) -> Bool
) -> (before: Node<Item>, item: Item, itemPrefix: Item.Item_Summary, after: Node<Item>)? {
    // Enforced with a `preconditionFailure`, for symmetry with `splitNode`'s handling of the
    // same assumption (`splitNode` has a valid answer when `predicate(prefix)` is already
    // true — the empty-left-tree case — so it branches instead of trapping; `cutNode` does
    // not, because there is no item left to isolate once the target has already been
    // passed, so a caller that gets here has already broken the contract documented above).
    // Honestly: no mutation of this line can be observed by a test today, because all three
    // current callers of `cut` (`splitTree` and the two `concatMergingSeam` cuts —
    // `Rope.locate` moved to the read-only `find` and no longer calls `cut` at all) satisfy
    // the precondition; it exists for the same reason `splitNode`'s check exists — to fail
    // loudly at the actual misuse site instead of returning a silently wrong item.
    precondition(
        !predicate(prefix),
        "cutNode: predicate must be false of prefix")
    switch node {
    case .leaf(let items, _):
        var cum = prefix
        for i in 0..<items.count {
            let next = cum + items[i].summary
            if predicate(next) {
                let before = Array(items[0..<i])
                let after = Array(items[(i + 1)...])
                return (.makeLeaf(before), items[i], cum, .makeLeaf(after))
            }
            cum = next
        }
        return nil
    case .interior(let children, _, _):
        var cum = prefix
        for i in 0..<children.count {
            let next = cum + children[i].summary
            if predicate(next) {
                guard
                    let (childBefore, item, itemPrefix, childAfter) = cutNode(
                        children[i], prefix: cum, predicate: predicate)
                else {
                    return nil
                }
                let beforeNodes = Array(children[0..<i]) + [childBefore]
                let afterNodes = [childAfter] + Array(children[(i + 1)...])
                return (buildFromNodes(beforeNodes), item, itemPrefix, buildFromNodes(afterNodes))
            }
            cum = next
        }
        return nil
    }
}

/// A read-only descent to the item at the first point where `predicate` becomes true of the
/// running summary, returning the item and the summary accumulated immediately before it.
/// Unlike `splitNode`/`cutNode`, this **allocates nothing, copies nothing and rebuilds
/// nothing**: it does not call `buildFromNodes`, `makeLeaf` or `makeInterior`, so it is
/// genuinely O(h) rather than the O(B · h²) a `cut`-then-discard-the-halves would cost (see
/// `SumTree`'s file header for that measurement). `predicate` must be monotone; returns
/// `nil` if it is never true of the tree's own total.
private func findNode<Item: Summable>(
    _ node: Node<Item>,
    prefix: Item.Item_Summary,
    predicate: (Item.Item_Summary) -> Bool
) -> (item: Item, itemPrefix: Item.Item_Summary)? {
    // Symmetric with `cutNode`'s guard: without it, a predicate already true at `prefix`
    // would silently fall through to the first item's leaf/interior loop below, which still
    // triggers immediately (since `predicate` is monotone) and returns `(firstItem,
    // itemPrefix: prefix)` — a plausible-looking but undefined answer, since the contract
    // documented on `SumTree.find` assumes `predicate(prefix)` is false on entry. No current
    // caller can reach this: `Rope.locate` only ever calls `find` with `0 < byteOffset <
    // utf8Count` (guaranteed by `isScalarBoundary`'s early return for both endpoints), so
    // `predicate(.identity)` (`$0.utf8 > byteOffset` at `utf8 == 0`) is always false; the
    // `sumTreeTests.swift` callers are the same shape. It exists for the same reason
    // `cutNode`'s check does — to fail loudly at the actual misuse site.
    precondition(!predicate(prefix), "findNode: predicate must be false of prefix")
    switch node {
    case .leaf(let items, _):
        var cum = prefix
        for item in items {
            let next = cum + item.summary
            if predicate(next) {
                return (item, cum)
            }
            cum = next
        }
        return nil
    case .interior(let children, _, _):
        var cum = prefix
        for child in children {
            let next = cum + child.summary
            if predicate(next) {
                return findNode(child, prefix: cum, predicate: predicate)
            }
            cum = next
        }
        return nil
    }
}

/// The list of invariant violations `SumTree.checkInvariants()` found, if any.
package struct SumTreeInvariantViolation: Error, CustomStringConvertible, Sendable {
    package let messages: [String]
    package var description: String { messages.joined(separator: "; ") }
}

/// The persistent B+-tree itself. See the file header for the design.
package struct SumTree<Item: Summable>: Sendable {
    package private(set) var root: Node<Item>

    /// Wraps an already-built `Node` directly. `internal`, not `private`, not `package` —
    /// test-only: `Tests/TextTests` reaches this via `@testable import Text`, which upgrades
    /// `internal` to visible, so `package` would only be handing every other module in this
    /// package (`Editor`, `Lisp`, `App`, ...) a way to turn an arbitrary `Node` into a
    /// trusted `SumTree` while bypassing every invariant-preserving entry point
    /// (`init(items:)`/`split`/`cut`/`concat`). Tests use it to build deliberately shaped
    /// (including deliberately malformed) trees to exercise `checkInvariants()` and
    /// rebalancing paths that no sequence of those calls reaches reliably — see
    /// `sumTreeTests.swift`.
    init(root: Node<Item>) {
        self.root = root
    }

    /// The empty tree: a leaf with no items, summary `.identity`.
    package init() {
        self.root = .leaf([], Item.Item_Summary.identity)
    }

    /// Bulk build from a sequence of items, by recursively halving and joining with
    /// `concat` — simpler than a bespoke bulk loader, and correct for free because `concat`
    /// is correct.
    package init(items: [Item]) {
        self.root = SumTree.build(Array(items))
    }

    private static func build(_ items: [Item]) -> Node<Item> {
        if items.count <= 2 * branchingFactor {
            return .makeLeaf(items)
        }
        let mid = items.count / 2
        let left = build(Array(items[0..<mid]))
        let right = build(Array(items[mid...]))
        return concatNodes(left, right)
    }

    /// O(1): the root's cached fold of every item's summary.
    package var summary: Item.Item_Summary { root.summary }

    /// O(1): the root's height (0 for a tree that is just a leaf). Exposed so callers and
    /// tests can observe how deep the tree actually is — a randomised test that never drives
    /// this above 0 is exercising a single leaf, not a tree.
    package var height: UInt8 { root.height }

    package var isEmpty: Bool { root.isEmptyLeaf }

    /// The monotone-predicate cursor. Splits at the first point where `predicate` becomes
    /// true of the accumulated summary; see `splitNode`'s doc comment for the exact
    /// semantics of which side the flip item lands on.
    package func split(where predicate: (Item.Item_Summary) -> Bool) -> (SumTree, SumTree) {
        let (left, right) = splitNode(root, prefix: .identity, predicate: predicate)
        return (SumTree(root: left), SumTree(root: right))
    }

    /// The cursor's other shape: extracts the one item at the first point where `predicate`
    /// becomes true, along with the items strictly before and strictly after it and the
    /// summary accumulated immediately before it. `nil` if `predicate` never triggers (an
    /// empty tree, or a predicate that is never true of the tree's own total).
    package func cut(
        where predicate: (Item.Item_Summary) -> Bool
    ) -> (before: SumTree, item: Item, itemPrefix: Item.Item_Summary, after: SumTree)? {
        guard
            let (before, item, itemPrefix, after) = cutNode(
                root, prefix: .identity, predicate: predicate)
        else {
            return nil
        }
        return (SumTree(root: before), item, itemPrefix, SumTree(root: after))
    }

    /// A read-only cursor: finds the item at the first point where `predicate` becomes true
    /// of the running summary, without building or copying any part of the tree — see
    /// `findNode`'s doc comment. Use this instead of `cut`/`split` whenever the caller only
    /// needs to *look at* the triggering item (its content, or its prefix summary), not to
    /// split the tree there. `predicate` must be monotone; `nil` if it is never true of the
    /// tree's own total (an empty tree, or a predicate that never triggers).
    package func find(
        where predicate: (Item.Item_Summary) -> Bool
    ) -> (item: Item, itemPrefix: Item.Item_Summary)? {
        findNode(root, prefix: .identity, predicate: predicate)
    }

    /// Joins two trees of any heights into one. O(log n) in the taller tree's height.
    package static func concat(_ a: SumTree, _ b: SumTree) -> SumTree {
        SumTree(root: concatNodes(a.root, b.root))
    }

    package func appending(_ other: SumTree) -> SumTree {
        SumTree.concat(self, other)
    }

    /// Every item, in order. Recursion here is bounded by the tree's height (logarithmic),
    /// not by item count — see the file header's note on why this type needs no iterative
    /// teardown.
    package func items() -> [Item] {
        var result: [Item] = []
        Self.collect(root, into: &result)
        return result
    }

    private static func collect(_ node: Node<Item>, into result: inout [Item]) {
        switch node {
        case .leaf(let items, _):
            result.append(contentsOf: items)
        case .interior(let children, _, _):
            for child in children {
                collect(child, into: &result)
            }
        }
    }

    /// Verifies: uniform leaf depth, the `B...2B` fill bounds (with the root exception),
    /// every cached summary equal to the fold of its children, and no empty leaf array
    /// below the root. Not `#if DEBUG`-only — the tests call this directly.
    package func checkInvariants() throws {
        var violations: [String] = []
        Self.checkNode(root, isRoot: true, violations: &violations)
        if !violations.isEmpty {
            throw SumTreeInvariantViolation(messages: violations)
        }
    }

    private static func checkNode(
        _ node: Node<Item>, isRoot: Bool, violations: inout [String]
    ) {
        switch node {
        case .leaf(let items, let summary):
            // Equivalent mutant, recorded rather than chased with a test (CLAUDE.md: where a
            // defence cannot be observed by a test, say so instead of pretending): mutating
            // this condition to `if false` still passes the whole suite, because it is
            // strictly subsumed by the bound check two lines below. A non-root empty leaf
            // has `items.count == 0`, which is always `< branchingFactor` (the non-root
            // lower bound), so the bound-check violation fires regardless of whether this
            // one does. Kept anyway for the clearer, more specific message when it does fire
            // alongside the bound violation.
            if !isRoot && items.isEmpty {
                violations.append("empty leaf array below the root")
            }
            let lowerBound = isRoot ? 0 : branchingFactor
            if items.count < lowerBound || items.count > 2 * branchingFactor {
                violations.append(
                    "leaf item count \(items.count) out of bounds [\(lowerBound),\(2 * branchingFactor)]"
                )
            }
            let folded = items.reduce(Item.Item_Summary.identity) { $0 + $1.summary }
            if folded != summary {
                violations.append("leaf cached summary does not equal the fold of its items")
            }
        case .interior(let children, let summary, let height):
            let lowerBound = isRoot ? 2 : branchingFactor
            if children.isEmpty {
                violations.append("interior node with no children")
            } else {
                if children.count < lowerBound || children.count > 2 * branchingFactor {
                    violations.append(
                        "interior child count \(children.count) out of bounds "
                            + "[\(lowerBound),\(2 * branchingFactor)]")
                }
                let childHeight = children[0].height
                for child in children where child.height != childHeight {
                    violations.append("interior node's children are not all the same height")
                }
                if height != childHeight + 1 {
                    violations.append("interior height field does not match its children")
                }
            }
            let folded = children.reduce(Item.Item_Summary.identity) { $0 + $1.summary }
            if folded != summary {
                violations.append("interior cached summary does not equal the fold of its children")
            }
            for child in children {
                checkNode(child, isRoot: false, violations: &violations)
            }
        }
    }
}

extension TextSummary: Summary {
    package static var identity: Self { TextSummary() }
}

extension Chunk: Summable {
    package typealias Item_Summary = TextSummary
}
