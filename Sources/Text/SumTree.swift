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
/// it can never isolate a tree's last item alone (see `splitFragments`'s doc comment, which
/// now carries this same distinction). `find` is `cut` without the two halves: genuinely
/// O(h), because it descends without ever allocating, copying or rebuilding any part of the
/// tree (see `findNode`'s doc comment) — cheaper even than `split`/`cut`'s O(h), which still
/// builds O(h) worth of new nodes. Bulk build from a sequence of items (M1.2) is a
/// **bottom-up, level-by-level pack**: items are packed into leaves at a chosen fill, then
/// the previous level's nodes are packed into interiors, repeated until one root remains —
/// see `SumTree.build`. This replaced the original recursive-halving-plus-`concat` build
/// (kept as `buildViaRecursiveHalvingForTesting` for the differential test comparing the
/// two): the old build cost O(n log n) total `concat` work (each of the O(log n) levels of
/// the halving recursion re-joining through `concat`'s O(h) splice), where the new one
/// costs O(n) — every item and every intermediate node is visited exactly once, with no
/// `concat` call at all. Measured at 1 MB: ~11 ms with the old build
/// (`PLAN.md:1719-1723`, ~91 MB/s); the implementer's report carries the new number.
///
/// **`concat`, `split` and `cut` are all O(h) in the tree's height** (M1.1b stage 2; an
/// earlier version of this comment measured `split`/`cut` at O(B · h²), before this round).
/// The fix was not making the descent itself cheaper — `splitNode`/`cutNode`'s single
/// descent was already O(h) — but replacing what happened *after* it: they called
/// `buildFromNodes` at every level to fold `concatNodes` across up to `B + 1` sibling nodes,
/// each fold being O(h) and copying arrays of up to 12 `Node`s, so a single cursor walk did
/// O(B · h²) node reconstructions for O(h) worth of real work. `split`/`cut` are now
/// `splitFragments` (one descent, still O(h), but it only *slices* the per-level sibling
/// groups into `Fragment`s rather than rebuilding them) followed by pushing those fragments
/// into a `TreeBuilder`: at most two fragments per level, so O(h) fragments in total, and
/// `TreeBuilder.push`'s right-spine join costs O(height difference) per push — which sums to
/// O(h) for the whole monotone-height run a `splitFragments` call produces (see
/// `TreeBuilder`'s doc comment for why this is not the O(1)-amortised cost a per-height-slot
/// builder would have, and why that distinction does not matter here). Measured before this
/// round, on a 1 MB rope: `Rope.isScalarBoundary` (one `cut`, nothing else) cost 131 µs, and
/// inserting one byte cost ~400 node reconstructions for what a persistent B-tree insert
/// should do in ~5 (see `M1.1-perf-findings.md`); re-measuring this claim against the
/// current code is the main conversation's job, not this comment's.
///
/// Known gap: `split`/`cut` only ever land on **item boundaries** (whatever `Item` is — a
/// whole `Chunk`, for the rope). Splitting *inside* an item (e.g. a byte offset in the
/// middle of a `Chunk`) is the caller's job; `Rope.swift` does this by extracting the one
/// item in question with `cut`, slicing its payload itself, and rejoining with `concat`.

/// A monoid summarising a run of items. Identity is a two-sided identity for `+`
/// (`identity + x == x + identity == x`), and `+` must be associative — that is what makes
/// a cached summary trustworthy regardless of how the tree balances.
@usableFromInline package protocol Summary: Sendable, Equatable {
    static var identity: Self { get }
    static func + (lhs: Self, rhs: Self) -> Self
}

/// Something a `SumTree` can hold at its leaves: anything with a `Summary`.
@usableFromInline package protocol Summable: Sendable {
    associatedtype Item_Summary: Summary
    var summary: Item_Summary { get }
}

/// A node of the tree. `leaf` holds items directly; `interior` holds child nodes, plus the
/// node's own height (0 for a leaf, one more than its children's for an interior node) so
/// `concat` and `split` can compare heights without walking down to find them.
@usableFromInline package enum Node<Item: Summable>: Sendable {
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

    /// Items for a leaf, children for an interior — the count `TreeBuilder`'s join checks
    /// against `branchingFactor` to decide whether a node (or a loose group standing in for
    /// one) is underfull.
    fileprivate var childCount: Int {
        switch self {
        case .leaf(let items, _): return items.count
        case .interior(let children, _, _): return children.count
        }
    }

    fileprivate var isUnderfull: Bool { childCount < branchingFactor }
}

/// The branching factor. Fixed at 6 by PLAN.md 4.5 (Zed's `sum_tree` constant).
///
/// `internal`, not `private`: `Rope.swift` reads it directly rather than keeping its own
/// copy that could drift out of sync if this one were ever changed. Its reader used to be
/// the leaf-local coalescing guard in `tryLeafLocalReplace`; M1.1b stage 2 measured that
/// guard and removed it, and the reader is now `pushChunks`, which must not hand
/// `TreeBuilder.push` a `Fragment` holding more than `2B` items. Deliberately not
/// `package`: nothing outside this module needs it.
internal let branchingFactor = 6

/// A **transient** group of `0...2B` items or same-height nodes — never stored in a tree,
/// only ever an argument to `TreeBuilder.push`. The type distinction is the enforcement
/// mechanism `checkInvariants()` relies on: an underfull (or empty) group is representable
/// as a `Fragment` and not representable as a stored `Node`, so a caller that has one on its
/// hands (a per-level sibling group `splitFragments` peeled off mid-descent, say) is never
/// tempted to wrap it in a `Node` and smuggle it past the checker. `case nodes` carries the
/// common height explicitly because an empty slice cannot report one.
package enum Fragment<Item: Summable>: Sendable {
    case items(ArraySlice<Item>)
    case nodes(ArraySlice<Node<Item>>, height: UInt8)
}

/// The n-ary join builder (M1.1b stage 2): accepts loose `Fragment`s or well-formed subtrees
/// in any push order and produces one well-formed tree in `finish()`, every node of which
/// satisfies `checkNode`'s bounds (root looseness collapsed the same way `pathCopyEdit`
/// already does — see `collapseRoot`, reused rather than duplicated). This is what lets
/// `split`/`cut` reconstruct both sides of a cut in one pass each, instead of `concatNodes`
/// once per level (see the file header).
///
/// **Shape actually shipped, not "O(1) amortised".** A per-height-slot builder (one open
/// node per height, closed and carried up on overflow) would be O(1) amortised per push.
/// This is not that: each push descends the accumulator's right spine until the heights
/// agree, then splices there, so one push costs O(height difference) and a whole
/// monotone-height run of pushes — exactly what `splitFragments` produces, one `Fragment`
/// per level — costs O(h) in total. That is the bound this design needs (`split`/`cut`
/// become O(h), not O(1) per push); do not read "right-spine join" as a defect to fix.
package struct TreeBuilder<Item: Summable>: ~Copyable {
    private var accumulator: Node<Item>?

    package init() {
        accumulator = nil
    }

    /// Pushes a possibly-underfull-or-empty group. See `Fragment`'s doc comment for why the
    /// looseness is legal here and only here.
    package mutating func push(_ fragment: Fragment<Item>) {
        switch fragment {
        case .items(let slice):
            // Equivalent mutant, recorded rather than chased with a test (CLAUDE.md: where a
            // defence cannot be observed by a test, say so instead of pretending): this guard
            // is a performance early-out, not a correctness guard. Removing it still produces
            // `.makeLeaf([])`, which `joinNodes`'s `isEmptyLeaf` short-circuit and
            // `normalizeLooseNode` both already treat as a no-op — no observable difference.
            guard !slice.isEmpty else { return }  // mutation focus: empty-fragment early-out
            precondition(slice.count <= 2 * branchingFactor, "Fragment.items exceeds 2B")
            appendNode(.makeLeaf(Array(slice)))
        case .nodes(let slice, _):
            guard !slice.isEmpty else { return }  // mutation focus: empty-fragment early-out
            precondition(slice.count <= 2 * branchingFactor, "Fragment.nodes exceeds 2B")
            appendNode(.makeInterior(Array(slice)))
        }
    }

    /// Pushes an already well-formed subtree (every level within its own non-root `B...2B`
    /// bounds) — the shape `TreeBuilder.push(subtree:)`'s doc comment on the `SumTree.swift`
    /// header promises its caller.
    package mutating func push(subtree: Node<Item>) {
        guard !subtree.isEmptyLeaf else { return }
        appendNode(subtree)
    }

    private mutating func appendNode(_ node: Node<Item>) {
        if let acc = accumulator {
            accumulator = joinNodes(acc, node)
        } else {
            accumulator = normalizeLooseNode(node)
        }
    }

    /// The tree whose in-order item sequence is the concatenation, in push order, of
    /// everything pushed; the empty tree if nothing (or only empty fragments) was pushed.
    package consuming func finish() -> SumTree<Item> {
        guard let acc = accumulator else { return SumTree<Item>() }
        return SumTree(root: SumTree.collapseRoot(acc))
    }
}

/// Joins two trees of any heights into one well-formed node, preserving every invariant.
/// `a` may be empty (an empty leaf); `b` may be **loose** — underfull, or an interior
/// wrapper standing in for an unattached sibling group (exactly what `TreeBuilder.push`
/// builds from a `Fragment`) — but must not be taller than `a` unless `a` is empty. This is
/// `concatNodes`/`TreeBuilder`'s shared engine: there is one rebalancing implementation, not
/// two (see the file header).
private func joinNodes<Item: Summable>(_ a: Node<Item>, _ b: Node<Item>) -> Node<Item> {
    // Equivalent mutant, recorded rather than chased with a test (CLAUDE.md: where a defence
    // cannot be observed by a test, say so instead of pretending): removing this short-circuit
    // changes no result, only how much work the general descent below does to reach it. This
    // is a performance guard, not a correctness guard.
    if b.isEmptyLeaf { return a }
    if a.isEmptyLeaf { return normalizeLooseNode(b) }
    if a.height < b.height {
        guard case .interior(let bChildren, _, _) = b else {
            preconditionFailure("joinNodes: taller argument must be interior")
        }
        var acc = a
        for child in bChildren { acc = joinNodes(acc, child) }
        return acc
    }
    let (spliced, split) = spliceOntoRightSpine(a, b)
    if let split { return .makeInterior([spliced, split]) }
    return spliced
}

/// The case `joinNodes` cannot express as a recursive splice: starting an empty accumulator
/// from a loose node has nothing well-formed to splice onto yet. A leaf, or a well-formed
/// (non-underfull) interior, is used as-is; an underfull interior wrapper is dissolved by
/// pushing its children in one at a time — each one individually well-formed even though
/// the group as a whole was not (see `Fragment`'s doc comment).
private func normalizeLooseNode<Item: Summable>(_ node: Node<Item>) -> Node<Item> {
    guard case .interior(let children, _, _) = node, node.isUnderfull else { return node }
    var acc = children[0]
    for child in children.dropFirst() { acc = joinNodes(acc, child) }
    return acc
}

/// Appends `other` onto `node`'s right spine, descending until the heights agree and
/// splicing there; returns a right sibling if that splice overflowed `2B`. `node` is
/// well-formed and non-empty; `other` may be loose (see `joinNodes`) but no taller than
/// `node`.
private func spliceOntoRightSpine<Item: Summable>(
    _ node: Node<Item>, _ other: Node<Item>
) -> (Node<Item>, Node<Item>?) {
    switch node {
    case .leaf(let items, _):
        guard case .leaf(let otherItems, _) = other else {
            preconditionFailure("spliceOntoRightSpine: height agreement violated at leaf level")
        }
        let all = items + otherItems
        if all.count <= 2 * branchingFactor {  // mutation focus: 2B overflow test, leaf branch
            return (.makeLeaf(all), nil)
        }
        let mid = all.count / 2
        return (.makeLeaf(Array(all[0..<mid])), .makeLeaf(Array(all[mid...])))
    case .interior(let children, _, let height):
        var toAppend: [Node<Item>] = []
        var newChildren = children
        let delta = Int(height) - Int(other.height)
        if delta == 0 {
            // Same height: splice `other`'s children in flat. This is the step that
            // dissolves an underfull `other` harmlessly — every one of its children is
            // individually well-formed even though the group as a whole was not.
            // Mutation focus: this branch vs. the `delta == 1 && !isUnderfull` branch below.
            guard case .interior(let otherChildren, _, _) = other else {
                preconditionFailure(
                    "spliceOntoRightSpine: equal heights but one leaf, one interior")
            }
            toAppend = otherChildren
        } else if delta == 1 && !other.isUnderfull {
            toAppend = [other]
        } else {
            let (replacement, split) = spliceOntoRightSpine(children[children.count - 1], other)
            newChildren[newChildren.count - 1] = replacement
            if let split { toAppend = [split] }
        }
        let total = newChildren.count + toAppend.count
        if total <= 2 * branchingFactor {  // mutation focus: 2B overflow test, interior branch
            newChildren.append(contentsOf: toAppend)
            return (.makeInterior(newChildren), nil)
        }
        var all = newChildren
        all.append(contentsOf: toAppend)
        let mid = all.count / 2
        return (.makeInterior(Array(all[0..<mid])), .makeInterior(Array(all[mid...])))
    }
}

/// Joins two trees of any heights into one, preserving every invariant. A thin wrapper over
/// `joinNodes` — `TreeBuilder`'s engine — so there is one rebalancing implementation, not
/// two (see the file header). `rewrap`, `concatNodes`'s old sibling that spliced a modified
/// children list back into one node, has no separate existence any more: its job is now
/// `spliceOntoRightSpine`'s own `2B` overflow check, done inline instead of by a second
/// function (see `rewrapOverflowBranchDeterministic` in `sumTreeTests.swift`, re-pointed at
/// that check rather than at a function of this name).
private func concatNodes<Item: Summable>(_ a: Node<Item>, _ b: Node<Item>) -> Node<Item> {
    joinNodes(a, b)
}

/// `cut` in fragment form: one descent that, instead of rebuilding each side into a tree via
/// `buildFromNodes` at every level (as `splitNode`/`cutNode` used to — see the file header),
/// collects the per-level sibling groups on either side of the flip point as `Fragment`s for
/// the caller to push into a `TreeBuilder`. Isolates the flip item itself and returns it
/// (with the summary of everything strictly before it) — this is `cut`'s shape, not
/// `split`'s: the flip item is never folded into either side here, unlike a `>=`-style
/// predicate against a tree's own total summary applied by `splitNode`, which can never
/// isolate "everything but the last item" this way (see `SumTree.split`'s doc comment for
/// why `split` and `cut` need separate implementations at all).
///
/// **Fragment order is part of the contract.** `left` is emitted highest-level-first
/// (root-ward groups before leaf-ward ones) and `right` is emitted deepest-first-then-upward
/// (leaf-ward groups before root-ward ones) — a consequence of appending each level's
/// leftover group before descending on the left and after returning from the descent on the
/// right, not something either caller can recover from the types alone. Both must be pushed
/// into a `TreeBuilder` in the order emitted. Mutation focus: this emission order, and the
/// push order at each of `splitFragments`'s consumers (`SumTree.split`, `SumTree.cut`,
/// `Rope.generalPathReplace`).
///
/// `predicate` must be monotone and false of `prefix`, exactly as `cutNode` used to require
/// (same precondition, same reason — see `SumTree.cut`'s doc comment for why `predicate`
/// already true of `.identity` is `split`'s case to special-case, not this function's).
/// Returns `nil` when `predicate` never fires: `left` then receives a single `Fragment`
/// wrapping the whole of `node`, and `right` receives nothing.
package func splitFragments<Item: Summable>(
    _ node: Node<Item>, prefix: Item.Item_Summary,
    where predicate: (Item.Item_Summary) -> Bool,
    left: inout [Fragment<Item>], right: inout [Fragment<Item>]
) -> (item: Item, itemPrefix: Item.Item_Summary)? {
    precondition(!predicate(prefix), "splitFragments: predicate must be false of prefix")
    switch node {
    case .leaf(let items, _):
        var cum = prefix
        for i in 0..<items.count {
            let next = cum + items[i].summary
            if predicate(next) {
                if i > 0 { left.append(.items(items[0..<i])) }
                if i + 1 < items.count { right.append(.items(items[(i + 1)...])) }
                return (items[i], cum)
            }
            cum = next
        }
        left.append(.items(items[...]))
        return nil
    case .interior(let children, _, let height):
        var cum = prefix
        for i in 0..<children.count {
            let next = cum + children[i].summary
            if predicate(next) {
                if i > 0 { left.append(.nodes(children[0..<i], height: height - 1)) }
                let result = splitFragments(
                    children[i], prefix: cum, where: predicate, left: &left, right: &right)
                if i + 1 < children.count {
                    right.append(.nodes(children[(i + 1)...], height: height - 1))
                }
                return result
            }
            cum = next
        }
        left.append(.nodes(children[...], height: height - 1))
        return nil
    }
}

/// A read-only descent to the item at the first point where `predicate` becomes true of the
/// running summary, returning the item and the summary accumulated immediately before it.
/// Unlike `splitFragments`, this **allocates nothing, copies nothing and rebuilds
/// nothing**: it does not call `makeLeaf` or `makeInterior`, so it is genuinely O(h) rather
/// than the O(h) `splitFragments` plus a `TreeBuilder` pass would cost to get the same
/// answer and then discard both halves (see `SumTree`'s file header). `predicate` must be
/// monotone; returns `nil` if it is never true of the tree's own total.
private func findNode<Item: Summable>(
    _ node: Node<Item>,
    prefix: Item.Item_Summary,
    predicate: (Item.Item_Summary) -> Bool
) -> (item: Item, itemPrefix: Item.Item_Summary)? {
    // Symmetric with `splitFragments`'s guard: without it, a predicate already true at
    // `prefix` would silently fall through to the first item's leaf/interior loop below,
    // which still triggers immediately (since `predicate` is monotone) and returns
    // `(firstItem, itemPrefix: prefix)` — a plausible-looking but undefined answer, since the
    // contract documented on `SumTree.find` assumes `predicate(prefix)` is false on entry. No
    // current caller can reach this: `Rope.locate` only ever calls `find` with `0 <
    // byteOffset < utf8Count` (guaranteed by `isScalarBoundary`'s early return for both
    // endpoints), so `predicate(.identity)` (`$0.utf8 > byteOffset` at `utf8 == 0`) is always
    // false; the `sumTreeTests.swift` callers are the same shape. It exists for the same
    // reason `splitFragments`'s check does — to fail loudly at the actual misuse site.
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

/// The outcome of `pathCopyEditNode`'s descent into one node: what the caller one level up
/// needs to do to splice the (possibly-changed-shape) result back into its own children/
/// items list. Bounds quoted below (`B...2B`) are always the **non-root** bounds
/// (`branchingFactor...2*branchingFactor`); root looseness is handled once, at
/// `SumTree.pathCopyEdit`'s top level, not here — see that function's doc comment.
private enum PathCopyOutcome<Item: Summable> {
    /// `edit` declined; the whole operation aborts and the tree is untouched.
    case declined
    /// The node was rebuilt with `B...2B` entries (items for a leaf, children for an
    /// interior), same height as the input.
    case ok(Node<Item>)
    /// The node overflowed and split into two nodes, each `B...2B` entries, same height as
    /// the input. The caller splices both in, in place of the one it passed down.
    case split(Node<Item>, Node<Item>)
    /// The node underflowed: `0...B-1` entries, same height as the input. The caller must
    /// repair this before it can accept the node as one of its own entries — see
    /// `pathCopyEditNode`'s interior case.
    case underfull(Node<Item>)
}

/// Combines two same-height, same-kind (both leaf or both interior) sibling nodes that
/// together cover between `B+1` and `3B-1` entries (one of them was underfull, the other a
/// normal `B...2B`) into either one merged node (`<= 2B` entries) or two redistributed
/// nodes (`> 2B` entries, split down the middle so both land in `B...2B`). `left`/`right`
/// must already be in tree order. Used only by `pathCopyEditNode`'s underflow repair.
private func combineUnderflowedSiblings<Item: Summable>(
    _ left: Node<Item>, _ right: Node<Item>
) -> [Node<Item>] {
    switch (left, right) {
    case (.leaf(let a, _), .leaf(let b, _)):
        let combined = a + b
        if combined.count <= 2 * branchingFactor {
            return [.makeLeaf(combined)]
        }
        let mid = combined.count / 2
        return [.makeLeaf(Array(combined[0..<mid])), .makeLeaf(Array(combined[mid...]))]
    case (.interior(let a, _, _), .interior(let b, _, _)):
        let combined = a + b
        if combined.count <= 2 * branchingFactor {
            return [.makeInterior(combined)]
        }
        let mid = combined.count / 2
        return [.makeInterior(Array(combined[0..<mid])), .makeInterior(Array(combined[mid...]))]
    default:
        preconditionFailure("combineUnderflowedSiblings: siblings must have equal height/kind")
    }
}

/// The recursive descent behind `SumTree.pathCopyEdit`. Returns `nil` if `predicate` never
/// becomes true within `node` (mirrors `cutNode`/`findNode`'s "not found" `nil`); otherwise
/// an outcome describing what `node` became. See `pathCopyEdit`'s doc comment for the
/// overall contract, and the type header comments above for what each outcome means to a
/// caller one level up.
private func pathCopyEditNode<Item: Summable>(
    _ node: Node<Item>,
    prefix: Item.Item_Summary,
    predicate: (Item.Item_Summary) -> Bool,
    edit: (_ items: [Item], _ index: Int, _ leafPrefix: Item.Item_Summary) -> [Item]?
) -> PathCopyOutcome<Item>? {
    switch node {
    case .leaf(let items, _):
        var cum = prefix
        for i in 0..<items.count {
            let next = cum + items[i].summary
            if predicate(next) {
                guard let newItems = edit(items, i, prefix) else { return .declined }
                // One split suffices because a leaf is only ever handed to `edit` at its
                // own `B...2B` cap and the replacement is built from those same items plus
                // a small bounded splice — nowhere near `4B`, which is the point at which
                // one split at the midpoint could fail to land both halves in `B...2B`.
                // `Rope.tryLeafLocalReplace` is not this function's only caller's caller any
                // more: `MarkerTree.shiftingSingleItem` (M1.3) also reaches `pathCopyEdit`,
                // but only ever to add a delta to one existing gap in place — the edited
                // leaf's item count never changes, so it stays at most `2B`, well inside the
                // bound either caller needs.
                precondition(
                    newItems.count <= 4 * branchingFactor,
                    "pathCopyEdit: edit grew a leaf beyond what one split can repair")
                if newItems.count > 2 * branchingFactor {
                    let mid = newItems.count / 2
                    return .split(
                        .makeLeaf(Array(newItems[0..<mid])), .makeLeaf(Array(newItems[mid...])))
                } else if newItems.count < branchingFactor {
                    return .underfull(.makeLeaf(newItems))
                } else {
                    return .ok(.makeLeaf(newItems))
                }
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
                    let childOutcome = pathCopyEditNode(
                        children[i], prefix: cum, predicate: predicate, edit: edit)
                else {
                    return nil
                }
                var cs = children
                switch childOutcome {
                case .declined:
                    return .declined
                case .ok(let n):
                    cs[i] = n
                    return .ok(.makeInterior(cs))
                case .split(let a, let b):
                    cs[i] = a
                    cs.insert(b, at: i + 1)
                    if cs.count > 2 * branchingFactor {
                        let mid = cs.count / 2
                        return .split(
                            .makeInterior(Array(cs[0..<mid])), .makeInterior(Array(cs[mid...])))
                    }
                    return .ok(.makeInterior(cs))
                case .underfull(let u):
                    let isEmptyEntries: Bool
                    switch u {
                    case .leaf(let items, _): isEmptyEntries = items.isEmpty
                    case .interior(let uc, _, _): isEmptyEntries = uc.isEmpty
                    }
                    if isEmptyEntries {
                        cs.remove(at: i)
                    } else if i > 0 {
                        let combined = combineUnderflowedSiblings(cs[i - 1], u)
                        cs.replaceSubrange((i - 1)...i, with: combined)
                    } else {
                        let combined = combineUnderflowedSiblings(u, cs[i + 1])
                        cs.replaceSubrange(i...(i + 1), with: combined)
                    }
                    if cs.count < branchingFactor {
                        return .underfull(.makeInterior(cs))
                    }
                    return .ok(.makeInterior(cs))
                }
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

    /// Bulk build from a sequence of items (M1.2): bottom-up, level by level — see the file
    /// header and `build`'s own doc comment.
    package init(items: [Item]) {
        self.root = SumTree.build(Array(items))
    }

    /// Packs `n` entries (leaf items, or same-height nodes at an interior level) into the
    /// **fewest groups that keep every group in `B...2B`** — the fill target this loader
    /// commits to is "as full as the invariant allows", not `B` (a loader that only ever
    /// filled to `B` would still pass every invariant and equality check and just build a
    /// taller, sparser tree — mutation focus, see `dev/specs/m1.2.md` section 5). `n <= 2B`
    /// is one group (however small — non-root looseness is legal, and `build` only ever
    /// calls this for a level that might end up being the whole tree). Above that, the
    /// group count is `ceil(n / 2B)` (as few groups as fit within the `2B` ceiling) with no
    /// further adjustment needed: for `n > 2B`, `count0 = ceil(n / 2B)` always already
    /// satisfies `n / count0 >= B` — an earlier version of this function walked `count`
    /// down by one at a time to enforce that, on the belief that `count0` could still leave
    /// the last group under `B`; a cold read proved that belief false (verified both
    /// algebraically and by exhaustive check of every `n` up to 200,000 against `B = 6`: the
    /// loop's condition was never once true, and disabling it outright leaves every test
    /// green), so the walk-down step is removed rather than kept as unreachable code.
    /// Remaining entries are then split as evenly as possible (`n / count` per group, the
    /// first `n % count` groups getting one extra), so every group lands within one of
    /// `base` and `base + 1`, both inside `[B, 2B]` by construction.
    private static func groupSizes(for n: Int) -> [Int] {
        guard n > 0 else { return [] }
        if n <= 2 * branchingFactor { return [n] }
        let count = (n + 2 * branchingFactor - 1) / (2 * branchingFactor)
        let base = n / count
        let remainder = n % count
        return (0..<count).map { $0 < remainder ? base + 1 : base }
    }

    private static func packLeaves(_ items: [Item]) -> [Node<Item>] {
        var result: [Node<Item>] = []
        let groups = groupSizes(for: items.count)
        result.reserveCapacity(groups.count)
        var start = 0
        for size in groups {
            result.append(.makeLeaf(Array(items[start..<(start + size)])))
            start += size
        }
        return result
    }

    private static func packInteriors(_ nodes: [Node<Item>]) -> [Node<Item>] {
        var result: [Node<Item>] = []
        let groups = groupSizes(for: nodes.count)
        result.reserveCapacity(groups.count)
        var start = 0
        for size in groups {
            result.append(.makeInterior(Array(nodes[start..<(start + size)])))
            start += size
        }
        return result
    }

    /// The bottom-up bulk build itself (M1.2): pack `items` into a leaf level via
    /// `packLeaves`, then repeatedly pack the previous level's nodes into an interior level
    /// via `packInteriors` until one node remains. O(n) total — `groupSizes` is O(1) per
    /// level and every item/node is copied into exactly one new array slot per level it
    /// belongs to, and the number of levels is O(log n) with a geometrically shrinking node
    /// count, so the total work across all levels is O(n), not O(n log n) (contrast the old
    /// recursive-halving-plus-`concat` build this replaced — see the file header).
    ///
    /// A per-height-slot `TreeBuilder` was considered and rejected without being written:
    /// `TreeBuilder.push`'s own doc comment says it is not an amortised-O(1)-per-height-slot
    /// builder, and feeding it a whole leaf level one node at a time (`push(subtree:)`
    /// descending the accumulator's right spine for every single node) would reproduce the
    /// O(n log n) cost this round exists to remove, just spelled differently. This is a
    /// second construction path alongside `TreeBuilder`'s, not a violation of "one
    /// rebalancing implementation" (see the file header): `TreeBuilder` exists to join
    /// *loose fragments produced by a single cursor descent* (`split`/`cut`,
    /// `Rope.generalPathReplace`) in push order, a shape this bulk build never has — it
    /// starts from a flat, already-ordered item list with no fragments to reconcile.
    private static func build(_ items: [Item]) -> Node<Item> {
        guard !items.isEmpty else { return .makeLeaf([]) }
        var level = packLeaves(items)
        while level.count > 1 {
            level = packInteriors(level)
        }
        return level[0]
    }

    /// Test-only: the pre-M1.2 recursive-halving-plus-`concat` bulk build, kept so a
    /// differential test can confirm the new bottom-up `build` above produces a tree equal
    /// to (not just as valid as) what the old path produced for the same input — see the
    /// file header. `internal`, not `private`: reached only via `@testable import Text`
    /// from `sumTreeTests.swift`/`ropePerfTests.swift`.
    internal static func buildViaRecursiveHalvingForTesting(_ items: [Item]) -> Node<Item> {
        if items.count <= 2 * branchingFactor {
            return .makeLeaf(items)
        }
        let mid = items.count / 2
        let left = buildViaRecursiveHalvingForTesting(Array(items[0..<mid]))
        let right = buildViaRecursiveHalvingForTesting(Array(items[mid...]))
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
    /// true of the accumulated summary; the flip item itself lands in the **left** result
    /// once its own summary has been folded in, matching a `>=`-style predicate written
    /// against a target offset (see `Rope.swift`'s use of this for exact-offset splits via
    /// single-item leaves). Built on `splitFragments` plus two `TreeBuilder`s: one descent,
    /// not one `buildFromNodes` fold per level (see the file header). `split` and `cut`
    /// are not redundant with each other: `split` always folds the triggering item into its
    /// left-hand result, so it can never isolate a tree's *last* item alone the way `cut`
    /// can — see `splitFragments`'s doc comment.
    ///
    /// The `predicate(.identity)` case (already true of the empty tree) is `split`'s to
    /// special-case, not `splitFragments`'s: `splitFragments` shares `cutNode`'s old
    /// precondition that `predicate` is false of `prefix` on entry, because `cut` has no
    /// well-defined answer for an already-triggered predicate (there is no item left to
    /// isolate), whereas `split` does (the trivial `(empty, self)`).
    package func split(where predicate: (Item.Item_Summary) -> Bool) -> (SumTree, SumTree) {
        if predicate(.identity) {
            return (SumTree(), self)
        }
        var leftFragments: [Fragment<Item>] = []
        var rightFragments: [Fragment<Item>] = []
        guard
            let (item, _) = splitFragments(
                root, prefix: .identity, where: predicate,
                left: &leftFragments, right: &rightFragments)
        else {
            // Never triggers: `splitFragments` already put the whole tree into
            // `leftFragments` — mutation focus: this push order (and the two below).
            var builder = TreeBuilder<Item>()
            for fragment in leftFragments { builder.push(fragment) }
            return (builder.finish(), SumTree())
        }
        var leftBuilder = TreeBuilder<Item>()
        for fragment in leftFragments { leftBuilder.push(fragment) }
        leftBuilder.push(.items(ArraySlice([item])))
        var rightBuilder = TreeBuilder<Item>()
        for fragment in rightFragments { rightBuilder.push(fragment) }
        return (leftBuilder.finish(), rightBuilder.finish())
    }

    /// The cursor's other shape: extracts the one item at the first point where `predicate`
    /// becomes true, along with the items strictly before and strictly after it and the
    /// summary accumulated immediately before it. `nil` if `predicate` never triggers (an
    /// empty tree, or a predicate that is never true of the tree's own total) — including
    /// `predicate(.identity)`, via `splitFragments`'s own precondition trap for that case
    /// matching `cutNode`'s old one (see `split`'s doc comment for why `split` and `cut`
    /// disagree about that case). Built on `splitFragments` plus two `TreeBuilder`s.
    package func cut(
        where predicate: (Item.Item_Summary) -> Bool
    ) -> (before: SumTree, item: Item, itemPrefix: Item.Item_Summary, after: SumTree)? {
        var leftFragments: [Fragment<Item>] = []
        var rightFragments: [Fragment<Item>] = []
        guard
            let (item, itemPrefix) = splitFragments(
                root, prefix: .identity, where: predicate,
                left: &leftFragments, right: &rightFragments)
        else {
            return nil
        }
        var leftBuilder = TreeBuilder<Item>()
        for fragment in leftFragments { leftBuilder.push(fragment) }
        var rightBuilder = TreeBuilder<Item>()
        for fragment in rightFragments { rightBuilder.push(fragment) }
        return (leftBuilder.finish(), item, itemPrefix, rightBuilder.finish())
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

    /// Visits items in order, skipping any subtree the caller declines. `prefix` is the summary
    /// of everything strictly before the node or item being offered, so a caller with a
    /// prefix-sum dimension can compute absolute positions. Returning `false` from `visit` stops
    /// the traversal. `descendInto` is given the prefix and the candidate subtree's own summary.
    ///
    /// `find`, `cut` and `seek` all follow a single path because their predicate is monotone
    /// over the prefix: exactly one child can be entered per level. This primitive is for
    /// callers whose query can enter *several* children at one level (M1.4's overlap query);
    /// it knows nothing about what `descendInto`/`visit` decide, only how to walk the tree
    /// while respecting their answers. Recursion is bounded by height, like `items()`.
    package func visitItems(
        descendInto: (_ prefix: Item.Item_Summary, _ subtree: Item.Item_Summary) -> Bool,
        visit: (_ prefix: Item.Item_Summary, _ item: Item) -> Bool
    ) {
        _ = Self.visitNode(root, prefix: .identity, descendInto: descendInto, visit: visit)
    }

    /// The recursion behind `visitItems`. Returns `false` to mean "stop the whole traversal"
    /// (propagated up from a `visit` that returned `false`), `true` to mean "keep going" —
    /// including the case where `descendInto` declined this node, which is not a stop, just a
    /// skip. Mutation focus: the `descendInto` guard below (test 18/mutation 10 in
    /// `dev/specs/m1.4.md`) — dropping it makes every subtree visited regardless of what the
    /// caller asked to prune.
    private static func visitNode(
        _ node: Node<Item>, prefix: Item.Item_Summary,
        descendInto: (Item.Item_Summary, Item.Item_Summary) -> Bool,
        visit: (Item.Item_Summary, Item) -> Bool
    ) -> Bool {
        guard descendInto(prefix, node.summary) else { return true }
        switch node {
        case .leaf(let items, _):
            var cum = prefix
            for item in items {
                if !visit(cum, item) { return false }
                cum = cum + item.summary
            }
            return true
        case .interior(let children, _, _):
            var cum = prefix
            for child in children {
                if !visitNode(child, prefix: cum, descendInto: descendInto, visit: visit) {
                    return false
                }
                cum = cum + child.summary
            }
            return true
        }
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

extension SumTree {
    /// The path-copy edit (M1.1b stage 1): descends once to the leaf containing the flip
    /// item of `predicate`, replaces that leaf's items via `edit`, and rebuilds only the
    /// `h+1` nodes on the path back to the root — every off-path subtree is shared
    /// verbatim, and neither `joinNodes` nor `TreeBuilder` is ever invoked (contrast
    /// `split`/`cut`; see the file header). Both overflow (the edited leaf grows past `2B`)
    /// and underflow (it shrinks below `B`, and that shortfall may cascade up through a
    /// chain of ancestors) are repaired in the same descent, not just overflow.
    ///
    /// `predicate` must be monotone, exactly as `find`/`cut` require, with
    /// `!predicate(.identity)` — a precondition enforces this, matching `splitFragments`'s
    /// own convention for the same reason: a predicate already true of the empty prefix has
    /// no well-defined flip item for a leaf-local editor to be handed. Returns `nil` if
    /// `predicate` never becomes true (including on an empty tree) or if `edit` declines.
    ///
    /// `edit` is handed the flip leaf's *whole* items array, the flip item's index within
    /// it, and the summary of everything strictly before that leaf (not before the flip
    /// item within the leaf); it returns the leaf's complete replacement items array, or
    /// `nil` to decline, in which case `self` is left untouched (signalled by this
    /// function's own `nil`).
    package func pathCopyEdit(
        where predicate: (Item.Item_Summary) -> Bool,
        edit: (_ items: [Item], _ index: Int, _ leafPrefix: Item.Item_Summary) -> [Item]?
    ) -> SumTree<Item>? {
        precondition(!predicate(.identity), "pathCopyEdit: predicate must be false of .identity")
        guard
            let outcome = pathCopyEditNode(
                root, prefix: .identity, predicate: predicate, edit: edit)
        else {
            return nil
        }
        switch outcome {
        case .declined:
            return nil
        case .split(let a, let b):
            return SumTree(root: SumTree.collapseRoot(.makeInterior([a, b])))
        case .ok(let n), .underfull(let n):
            return SumTree(root: SumTree.collapseRoot(n))
        }
    }

    /// The root-only special case `pathCopyEditNode` deliberately does not handle (see its
    /// type header): an underfull root is legal by construction (`checkNode` uses lower
    /// bound 0 for a root leaf, 2 for a root interior), so the only repair a root itself
    /// ever needs is collapsing away a now-pointless single-child level — the shape an
    /// interior root is left in after an underflow repair removed one of its two children
    /// entirely rather than merging or redistributing it.
    // `fileprivate`, not `private`: `TreeBuilder.finish()` (a separate type declared
    // earlier in this same file) reuses this rather than duplicating it, per this round's
    // design ("reuse it rather than writing a second one") — `private` would only be
    // visible within this `extension SumTree` block itself.
    fileprivate static func collapseRoot(_ node: Node<Item>) -> Node<Item> {
        var current = node
        while case .interior(let children, _, _) = current, children.count == 1 {
            current = children[0]
        }
        return current
    }
}

extension TextSummary: Summary {
    package static var identity: Self { TextSummary() }
}

extension Chunk: Summable {
    package typealias Item_Summary = TextSummary
}
