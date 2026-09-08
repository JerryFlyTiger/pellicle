import Testing

@testable import Text

/// A trivial `Summable`/`Summary` pair so these tests can exercise `SumTree<Item>` without
/// going through `Chunk`/`TextSummary` — the generic tree's invariants should hold for any
/// item type, and keeping this fixture separate from the rope's own types means a bug in
/// one cannot mask a bug in the other.
private struct IntSummary: Summary {
    var count: Int
    static let identity = IntSummary(count: 0)
    static func + (lhs: IntSummary, rhs: IntSummary) -> IntSummary {
        IntSummary(count: lhs.count + rhs.count)
    }
}

private struct IntItem: Summable {
    typealias Item_Summary = IntSummary
    var value: Int
    var summary: IntSummary { IntSummary(count: 1) }
}

/// Covers `SumTree`'s structural invariants: fill bounds, uniform depth, cached-summary
/// correctness, and persistence under edits (PLAN.md 4.5).
@Suite("SumTree")
struct SumTreeTests {
    fileprivate static func items(_ n: Int) -> [IntItem] {
        (0..<n).map { IntItem(value: $0) }
    }

    @Test(
        "build from 0, 1, B-1, B, B+1, 2B, 2B+1 and a few thousand items; invariants hold; order preserved",
        arguments: [0, 1, 5, 6, 7, 12, 13, 3000]
    )
    func buildAndInvariants(_ n: Int) throws {
        let tree = SumTree<IntItem>(items: Self.items(n))
        try tree.checkInvariants()
        #expect(tree.items().map(\.value) == Array(0..<n))
        #expect(tree.summary.count == n)
    }

    @Test("split at every offset of a medium tree, rejoined by concat, reproduces the original")
    func splitEveryOffsetAndRejoin() throws {
        let n = 130
        let tree = SumTree<IntItem>(items: Self.items(n))
        for k in 0...n {
            let (left, right) = tree.split(where: { $0.count >= k })
            try left.checkInvariants()
            try right.checkInvariants()
            #expect(left.items().map(\.value) == Array(0..<k), "k=\(k)")
            #expect(right.items().map(\.value) == Array(k..<n), "k=\(k)")
            let rejoined = SumTree.concat(left, right)
            try rejoined.checkInvariants()
            #expect(rejoined.items().map(\.value) == Array(0..<n), "k=\(k)")
        }
    }

    @Test("concat of every pair of heights (0..3) you can build cheaply passes the invariants")
    func concatEveryHeightPair() throws {
        // B=6, so height 0 tops out at 12 items, height 1 at up to 12*12=144, height 2 at
        // up to 12*144, height 3 beyond that; pick counts comfortably inside each band.
        let counts = [0, 1, 6, 12, 50, 144, 1000, 2000]
        var trees: [SumTree<IntItem>] = []
        var offset = 0
        for n in counts {
            trees.append(
                SumTree<IntItem>(items: (offset..<(offset + n)).map { IntItem(value: $0) }))
            offset += n
        }
        for a in trees {
            for b in trees {
                let joined = SumTree.concat(a, b)
                try joined.checkInvariants()
                #expect(
                    joined.items().map(\.value) == a.items().map(\.value) + b.items().map(\.value))
            }
        }
    }

    @Test("persistence: editing a copy of a tree does not change the original, deep edit")
    func persistenceDeepEdit() throws {
        let n = 500
        let original = SumTree<IntItem>(items: Self.items(n))
        let originalItemsBefore = original.items().map(\.value)
        let originalSummaryBefore = original.summary

        var copy = original
        // Split deep inside the tree (not at a root-leaf-only offset) and rebuild with
        // different content, so the edit rebuilds a path through at least one interior
        // level rather than only touching a root leaf.
        let (left, right) = copy.split(where: { $0.count >= 250 })
        let replacement = SumTree<IntItem>(items: [IntItem(value: -1)])
        copy = SumTree.concat(SumTree.concat(left, replacement), right)

        #expect(original.items().map(\.value) == originalItemsBefore)
        #expect(original.summary == originalSummaryBefore)
        #expect(copy.items().map(\.value) != originalItemsBefore)
        #expect(copy.summary.count == n + 1)
    }

    @Test("empty tree invariants and properties")
    func emptyTree() throws {
        let tree = SumTree<IntItem>()
        try tree.checkInvariants()
        #expect(tree.isEmpty)
        #expect(tree.items().isEmpty)
        #expect(tree.summary == .identity)
    }

    // MARK: - find

    /// `find` had zero test coverage before this: it has exactly one call site
    /// (`Rope.locate`), which has exactly one caller (`Rope.isScalarBoundary`), which was
    /// never called anywhere in `Tests/`. Two mutations proved it (a reviewer's): changing
    /// `findNode`'s leaf return from `(item, cum)` to `(item, next)` broke no test, and
    /// neither did changing `Rope.locate`'s predicate from `>` to `>=`. This test targets the
    /// first of those directly: `find` must agree with `cut` on both the returned item *and*
    /// its `itemPrefix` (the pre-item cumulative summary) — `(item, next)` would report the
    /// *post*-item cumulative instead, which `cut`'s independently-computed `itemPrefix`
    /// would catch immediately. Sizes cover height 0 (a leaf, up to 12 items), height 1 (up
    /// to 144), and height ≥ 2 (beyond that) — see `concatEveryHeightPair`'s comment for the
    /// branching-factor arithmetic. Every offset of every size is checked, which covers the
    /// first item, the last item, and a predicate that is already true at the first item
    /// (`k == 0`) for free.
    @Test(
        "find agrees with cut on item and itemPrefix for every offset, at several sizes/heights",
        arguments: [1, 6, 12, 50, 144, 1000]
    )
    func findAgreesWithCut(_ n: Int) {
        let tree = SumTree<IntItem>(items: Self.items(n))
        for k in 0..<n {
            let predicate: (IntSummary) -> Bool = { $0.count > k }
            guard let (_, cutItem, cutPrefix, _) = tree.cut(where: predicate) else {
                Issue.record("n=\(n), k=\(k): cut returned nil")
                continue
            }
            guard let (findItem, findPrefix) = tree.find(where: predicate) else {
                Issue.record("n=\(n), k=\(k): find returned nil")
                continue
            }
            #expect(findItem.value == cutItem.value, "n=\(n), k=\(k): item mismatch")
            #expect(findPrefix == cutPrefix, "n=\(n), k=\(k): itemPrefix mismatch")
        }
    }

    @Test("find on an empty tree returns nil")
    func findOnEmptyTree() {
        let tree = SumTree<IntItem>()
        #expect(tree.find(where: { $0.count > 0 }) == nil)
    }

    @Test("find with a predicate that never triggers returns nil")
    func findNeverTriggers() {
        let tree = SumTree<IntItem>(items: Self.items(10))
        #expect(tree.find(where: { $0.count > 100 }) == nil)
    }

    /// `findNeverTriggers` above uses `n = 10`, a single leaf at height 0, so it only ever
    /// exercises `findNode`'s *leaf* `nil` branch. `findNode` has two `return nil` sites
    /// (leaf and interior); this covers the interior one with a height-≥-1 tree.
    ///
    /// Self-checked by mutating that specific interior `return nil` to fabricate an answer
    /// instead of admitting failure — walk to the last leaf reachable from the last child and
    /// return its last item, ignoring `predicate` entirely (a plausible real bug: "nothing
    /// matched in the loop, so fall back to the last item" instead of correctly propagating
    /// failure). A version of this self-check that instead re-called `findNode` with a
    /// forced-`true` predicate was tried first and rejected: it collided with this same
    /// round's other new precondition (`findNode`'s `!predicate(prefix)` guard, which that
    /// forced-`true` predicate trips immediately), turning the self-check into a process
    /// crash rather than a clean `#expect` failure — informative, but not what this specific
    /// test is meant to isolate. See the implementer's report for what was observed under
    /// both.
    @Test("find with a predicate that never triggers returns nil, height >= 1")
    func findNeverTriggersAtHeight() {
        let tree = SumTree<IntItem>(items: Self.items(200))
        #expect(tree.height >= 1)
        #expect(tree.find(where: { $0.count > 1000 }) == nil)
    }

    // MARK: - Rebalancing: the interior overflow branch

    /// 3,000 rounds; each round joins two freshly-built, independently random-sized trees
    /// (1-4,000 items) by `concat` or by splitting one and splicing the other into the
    /// middle, then checks invariants and discards both. Every other test in this file
    /// concatenates only equal-sized or single-item trees, which is why the interior overflow
    /// branch this test is named for is never reached by them: instrumented, it fires 0 times
    /// across the whole existing suite and 171 times across a workload shaped like this one
    /// (measured, seed `0xC0FFEE`; see `M1.1-perf-findings.md`).
    ///
    /// M1.1b stage 2 moved this branch: it used to be `rewrap`'s `let mid = children.count /
    /// 2` (this test's original self-check target); `rewrap` no longer exists as a named
    /// function — `concatNodes` is now a thin wrapper over `TreeBuilder`'s shared join engine
    /// (see `SumTree.swift`'s file header), and the overflow split this test exercises is
    /// `spliceOntoRightSpine`'s own `let mid = all.count / 2` in its interior branch (one of
    /// the two `2B` overflow tests named in the implementer's report). Re-pointed rather than
    /// deleted, per this round's own instruction not to drop a test because its target moved;
    /// the self-check (file backup, targeted edit, `touch`, rerun, restore) was re-run against
    /// the new location, not re-derived from scratch — see the implementer's report.
    @Test("randomised concat/insert of random-sized trees keeps invariants every round")
    func randomizedConcatAppend() throws {
        var rng = SplitMix64(seed: 0xC0FF_EE)

        // Each round builds two fresh, independently-sized trees (1...4,000 items) and
        // joins them, then discards both — deliberately *not* one tree accumulated across
        // all 3,000 rounds. `checkInvariants()` (below) walks the whole tree, which is
        // O(size); a single accumulating tree would grow into the millions of items by the
        // end of the run and make an every-round full-tree walk cost billions of node
        // visits. Bounding each round's tree to a few thousand items is what makes "check
        // every round" tractable while still varying the sizes enough to reach the overflow
        // branch — matching `M1.1-perf-findings.md`'s "randomly-sized ropes" reproduction.
        for round in 0..<3000 {
            let sizeA = 1 + Int(rng.next() % 4000)
            let sizeB = 1 + Int(rng.next() % 4000)
            let treeA = SumTree<IntItem>(items: Self.items(sizeA))
            let treeB = SumTree<IntItem>(items: Self.items(sizeB))

            let combined: SumTree<IntItem>
            if rng.next() % 2 == 0 {
                combined = SumTree.concat(treeA, treeB)
            } else {
                let at = Int(rng.next() % UInt64(sizeA + 1))
                let (left, right) = treeA.split(where: { $0.count >= at })
                combined = SumTree.concat(SumTree.concat(left, treeB), right)
            }

            do {
                try combined.checkInvariants()
            } catch {
                Issue.record("seed 0xC0FFEE, round \(round): invariant violation \(error)")
            }
            #expect(combined.summary.count == sizeA + sizeB, "round \(round): item count drifted")
        }
    }

    /// Reaches the interior overflow branch deterministically in one operation, instead of by
    /// the luck of a random seed — a seeded random test that happens to hit the branch is
    /// not a substitute, because if the op distribution shifts the coverage silently
    /// disappears again (that is exactly how this branch went uncovered in the first
    /// place). Builds an interior node with exactly `2B` (12) children — 11 ordinary leaves
    /// at the minimum fill (`B` = 6 items) and a last leaf that is *full* (`2B` = 12 items,
    /// "one item short of splitting": one more item pushes it over the leaf cap and splits
    /// it in two) — then concats a single-item tree onto it. That growth turns the last
    /// child's one node into two, taking the already-full interior node from `2B` to
    /// `2B + 1` children and forcing a split, growing the tree by one level. Formerly named
    /// for `rewrap`, the function that used to own this branch; see the `MARK` above for
    /// where it lives now (`spliceOntoRightSpine`'s interior branch, as of M1.1b stage 2).
    @Test("deterministic: concat reaches the interior overflow branch in one operation")
    func interiorOverflowBranchDeterministic() throws {
        var value = 0
        var children: [Node<IntItem>] = []
        for _ in 0..<11 {
            let items = (0..<6).map { _ -> IntItem in
                defer { value += 1 }
                return IntItem(value: value)
            }
            children.append(.leaf(items, IntSummary(count: items.count)))
        }
        let fullLeafItems = (0..<12).map { _ -> IntItem in
            defer { value += 1 }
            return IntItem(value: value)
        }
        children.append(.leaf(fullLeafItems, IntSummary(count: fullLeafItems.count)))
        #expect(children.count == 12)

        let totalBefore = children.reduce(0) { $0 + $1.summary.count }
        let bigRoot = Node<IntItem>.interior(children, IntSummary(count: totalBefore), 1)
        let bigTree = SumTree<IntItem>(root: bigRoot)
        try bigTree.checkInvariants()

        let extra = IntItem(value: value)
        let smallTree = SumTree<IntItem>(items: [extra])

        let result = SumTree.concat(bigTree, smallTree)
        try result.checkInvariants()

        #expect(result.height == 2, "expected the overflow split to grow the tree by one level")
        guard case .interior(let topChildren, _, _) = result.root else {
            Issue.record("expected an interior root after the overflow split")
            return
        }
        #expect(
            topChildren.count == 2,
            "expected the 13 overflowing children to have been split in two")

        let expected = Array(0...value)
        #expect(result.items().map(\.value) == expected)
        #expect(result.summary.count == expected.count)
    }

    // MARK: - TreeBuilder / Fragment (M1.1b stage 2)

    /// Mirrors `concatEveryHeightPair`, but through `TreeBuilder.push(subtree:)` rather than
    /// `SumTree.concat` directly — the shape `concatNodes` itself now goes through.
    @Test(
        "TreeBuilder: pushing two well-formed subtrees preserves order and invariants, every height pair (0..3)"
    )
    func builderEveryHeightPair() throws {
        let counts = [0, 1, 6, 12, 50, 144, 1000, 2000]
        var trees: [SumTree<IntItem>] = []
        var offset = 0
        for n in counts {
            trees.append(
                SumTree<IntItem>(items: (offset..<(offset + n)).map { IntItem(value: $0) }))
            offset += n
        }
        for a in trees {
            for b in trees {
                var builder = TreeBuilder<IntItem>()
                builder.push(subtree: a.root)
                builder.push(subtree: b.root)
                let joined = builder.finish()
                try joined.checkInvariants()
                #expect(
                    joined.items().map(\.value) == a.items().map(\.value) + b.items().map(\.value)
                )
            }
        }
    }

    /// The property the whole design rests on: an underfull (but non-empty) `Fragment`
    /// pushed alongside a well-formed subtree, in either push order, still produces a tree
    /// that passes the unmodified invariant checker — because `TreeBuilder` dissolves the
    /// loose group rather than ever wrapping it as a stored `Node` (see `Fragment`'s doc
    /// comment). Covers every count `1...2B-1` (1...11) for both `Fragment` cases, and both
    /// push orders (loose-then-tall, tall-then-loose) for each.
    @Test(
        "TreeBuilder accepts loose Fragment.items/.nodes of every count 1..<2B, in several push orders"
    )
    func builderAcceptsLooseFragments() throws {
        var nextValue = 0
        func drawItems(_ n: Int) -> [IntItem] {
            defer { nextValue += n }
            return (nextValue..<(nextValue + n)).map { IntItem(value: $0) }
        }
        // A well-formed height-0 leaf of exactly B (6) items, for `.nodes` groups — each
        // individual node must be well-formed even though the group of them is not.
        func drawLeaf() -> (Node<IntItem>, [Int]) {
            let items = drawItems(6)
            return (.leaf(items, IntSummary(count: items.count)), items.map(\.value))
        }
        func drawTallSubtree(_ n: Int) -> (Node<IntItem>, [Int]) {
            let items = drawItems(n)
            return (SumTree<IntItem>(items: items).root, items.map(\.value))
        }

        for count in 1...11 {  // 1...2B-1
            let looseItems = drawItems(count)
            let looseItemsValues = looseItems.map(\.value)
            let looseItemsFragment = Fragment<IntItem>.items(looseItems[...])

            var looseNodesValues: [Int] = []
            var looseNodes: [Node<IntItem>] = []
            for _ in 0..<count {
                let (node, values) = drawLeaf()
                looseNodes.append(node)
                looseNodesValues.append(contentsOf: values)
            }
            let looseNodesFragment = Fragment<IntItem>.nodes(looseNodes[...], height: 0)

            let (tall, tallValues) = drawTallSubtree(1000)

            let scenarios: [(name: String, fragment: Fragment<IntItem>, looseValues: [Int])] = [
                ("items", looseItemsFragment, looseItemsValues),
                ("nodes", looseNodesFragment, looseNodesValues),
            ]

            for scenario in scenarios {
                for looseFirst in [true, false] {
                    var builder = TreeBuilder<IntItem>()
                    if looseFirst {
                        builder.push(scenario.fragment)
                        builder.push(subtree: tall)
                    } else {
                        builder.push(subtree: tall)
                        builder.push(scenario.fragment)
                    }
                    let result = builder.finish()
                    let orderName = looseFirst ? "loose-then-tall" : "tall-then-loose"
                    do {
                        try result.checkInvariants()
                    } catch {
                        Issue.record(
                            "count=\(count), \(scenario.name) \(orderName): invariant violation \(error)"
                        )
                    }
                    let expected =
                        looseFirst
                        ? scenario.looseValues + tallValues : tallValues + scenario.looseValues
                    #expect(
                        result.items().map(\.value) == expected,
                        "count=\(count), \(scenario.name) \(orderName): order mismatch")
                }
            }
        }
    }

    @Test(
        "TreeBuilder: finish() with nothing pushed, or only empty fragments, returns the empty tree"
    )
    func builderEmptyCases() throws {
        let builder = TreeBuilder<IntItem>()
        let empty = builder.finish()
        try empty.checkInvariants()
        #expect(empty.isEmpty)
        #expect(empty.items().isEmpty)

        let noItems: [IntItem] = []
        let noNodes: [Node<IntItem>] = []
        var builder2 = TreeBuilder<IntItem>()
        builder2.push(.items(noItems[...]))
        builder2.push(.nodes(noNodes[...], height: 0))
        builder2.push(.items(noItems[...]))
        let stillEmpty = builder2.finish()
        try stillEmpty.checkInvariants()
        #expect(stillEmpty.isEmpty)

        // Empty fragments interleaved with real ones must be no-ops, not disruptions.
        let real = (0..<6).map { IntItem(value: $0) }
        var builder3 = TreeBuilder<IntItem>()
        builder3.push(.nodes(noNodes[...], height: 0))
        builder3.push(.items(real[...]))
        builder3.push(.items(noItems[...]))
        let result = builder3.finish()
        try result.checkInvariants()
        #expect(result.items().map(\.value) == Array(0..<6))
    }

    /// Mirrors `splitEveryOffsetAndRejoin`, but exercises `splitFragments` directly (`cut`'s
    /// shape: the flip item is isolated on its own, not folded into either side — see
    /// `splitFragments`'s doc comment) rather than through `SumTree.split`/`cut`, and rebuilds
    /// both sides through a `TreeBuilder` rather than `concat`. The prototype did exactly
    /// this over 3,926 split points; this is the same property at the same bar, against the
    /// product implementation.
    @Test(
        "splitFragments at every offset, both sides rebuilt through a TreeBuilder, reproduces the original",
        arguments: [0, 1, 5, 6, 7, 12, 13, 50, 144, 145, 1000, 3000]
    )
    func splitFragmentsEveryOffsetAndRejoin(_ n: Int) throws {
        let tree = SumTree<IntItem>(items: Self.items(n))
        for k in 0...n {
            var leftFragments: [Fragment<IntItem>] = []
            var rightFragments: [Fragment<IntItem>] = []
            let predicate: (IntSummary) -> Bool = { $0.count > k }
            let flip = splitFragments(
                tree.root, prefix: .identity, where: predicate,
                left: &leftFragments, right: &rightFragments)

            var leftBuilder = TreeBuilder<IntItem>()
            for fragment in leftFragments { leftBuilder.push(fragment) }
            let left = leftBuilder.finish()
            try left.checkInvariants()

            var rightBuilder = TreeBuilder<IntItem>()
            for fragment in rightFragments { rightBuilder.push(fragment) }
            let right = rightBuilder.finish()
            try right.checkInvariants()

            if k < n {
                guard let (item, itemPrefix) = flip else {
                    Issue.record(
                        "n=\(n), k=\(k): splitFragments returned nil but should have found item \(k)"
                    )
                    continue
                }
                #expect(item.value == k, "n=\(n), k=\(k)")
                #expect(itemPrefix.count == k, "n=\(n), k=\(k)")
                #expect(left.items().map(\.value) == Array(0..<k), "n=\(n), k=\(k)")
                #expect(right.items().map(\.value) == Array((k + 1)..<n), "n=\(n), k=\(k)")
            } else {
                #expect(flip == nil, "n=\(n), k=\(k): expected splitFragments to find nothing")
                #expect(left.items().map(\.value) == Array(0..<n), "n=\(n), k=\(k)")
                #expect(right.items().isEmpty, "n=\(n), k=\(k)")
            }
        }
    }

    // MARK: - checkInvariants() has no negative test without these

    /// Mutations that deleted the leaf lower-bound check and the empty-leaf check both
    /// survived the whole suite before this section existed: nothing constructed a
    /// deliberately malformed tree to prove the checker actually catches what its own doc
    /// comment claims it catches. `Node`'s cases are `package`-visible and `SumTree.init(
    /// root:)` is `package` for exactly this (see `SumTree.swift`'s doc comment on it).
    private static func leaf(_ n: Int, from start: Int = 0) -> Node<IntItem> {
        let items = (start..<(start + n)).map { IntItem(value: $0) }
        return .leaf(items, IntSummary(count: n))
    }

    @Test("checkInvariants() throws on an underfull non-root leaf")
    func checkInvariantsCatchesUnderfullLeaf() throws {
        // Branching factor is 6; a non-root leaf must hold 6...12 items. 2 is underfull.
        let underfull = Self.leaf(2, from: 6)
        let normal = Self.leaf(6)
        let root = Node<IntItem>.interior(
            [normal, underfull], IntSummary(count: 8), 1)
        let tree = SumTree<IntItem>(root: root)
        #expect(throws: SumTreeInvariantViolation.self) {
            try tree.checkInvariants()
        }
    }

    @Test("checkInvariants() throws on an empty non-root leaf")
    func checkInvariantsCatchesEmptyLeaf() throws {
        let empty = Node<IntItem>.leaf([], .identity)
        let normal = Self.leaf(6)
        let root = Node<IntItem>.interior([normal, empty], IntSummary(count: 6), 1)
        let tree = SumTree<IntItem>(root: root)
        #expect(throws: SumTreeInvariantViolation.self) {
            try tree.checkInvariants()
        }
    }

    @Test("checkInvariants() throws on a one-child interior node")
    func checkInvariantsCatchesOneChildInterior() throws {
        // The root interior lower bound is 2 children; 1 is below it.
        let onlyChild = Self.leaf(6)
        let root = Node<IntItem>.interior([onlyChild], IntSummary(count: 6), 1)
        let tree = SumTree<IntItem>(root: root)
        #expect(throws: SumTreeInvariantViolation.self) {
            try tree.checkInvariants()
        }
    }

    @Test("checkInvariants() throws when leaves are at mismatched depth")
    func checkInvariantsCatchesMismatchedDepth() throws {
        // A leaf child (height 0) alongside an interior child (height 1) under the same
        // parent: every leaf under the interior child is one level deeper than the leaf
        // child sitting beside it. `checkNode`'s "children are not all the same height"
        // check is what transitively guarantees uniform leaf depth across the whole tree
        // (see `SumTree.swift`'s file header, "All leaves are at the same depth"): it is
        // enforced locally at every interior node, not by a separate global leaf-depth walk.
        let shallowLeaf = Self.leaf(6)
        let deeperChildren = (0..<6).map { Self.leaf(6, from: 6 + $0 * 6) }
        let deeperSubtree = Node<IntItem>.interior(
            deeperChildren, IntSummary(count: 36), 1)
        let root = Node<IntItem>.interior(
            [shallowLeaf, deeperSubtree], IntSummary(count: 42), 1)
        let tree = SumTree<IntItem>(root: root)
        #expect(throws: SumTreeInvariantViolation.self) {
            try tree.checkInvariants()
        }
    }

    @Test("checkInvariants() throws when a cached summary disagrees with the fold of its items")
    func checkInvariantsCatchesStaleSummary() throws {
        let items = (0..<6).map { IntItem(value: $0) }
        // The correct summary is `count: 6`; claim `count: 999` instead.
        let root = Node<IntItem>.leaf(items, IntSummary(count: 999))
        let tree = SumTree<IntItem>(root: root)
        #expect(throws: SumTreeInvariantViolation.self) {
            try tree.checkInvariants()
        }
    }

    // MARK: - pathCopyEdit (M1.1b stage 1)

    /// A `>=`-style predicate against `IntSummary.count`, the same convention `Rope`'s own
    /// `pathCopyEdit` callers use (see `Rope.tryLeafLocalReplace`) — the flip item is the
    /// one whose *inclusive* cumulative count first reaches `k`.
    private static func atLeast(_ k: Int) -> (IntSummary) -> Bool { { $0.count >= k } }

    @Test(
        "overflow: a leaf at exactly 2B items forced to 2B+1 splits, invariants hold, order preserved"
    )
    func pathCopyEditOverflowSplitsLeaf() throws {
        // A single root leaf at exactly `2B` (12) items — legal (root leaf bound is
        // `[0,2B]`) — edited to add one more, forcing the leaf-level overflow branch.
        let tree = SumTree<IntItem>(items: Self.items(12))
        let edited = try #require(
            tree.pathCopyEdit(
                where: Self.atLeast(12),
                edit: { items, _, _ in items + [IntItem(value: 999)] }))
        try edited.checkInvariants()
        #expect(edited.height == 1, "expected the overflow split to grow the tree by one level")
        #expect(edited.items().map(\.value) == Array(0..<12) + [999])
        #expect(edited.summary.count == 13)
    }

    @Test(
        "underflow by redistribute: a leaf pushed below B whose sibling has more than B ends both in [B,2B], parent child count unchanged"
    )
    func pathCopyEditUnderflowRedistributes() throws {
        // Root interior, two leaf children: left has 8 (> B), right has 6 (exactly B).
        // Removing one item from the right leaf drops it to 5 (< B); combined with the
        // left sibling's 8 that is 13 (> 2B), so the repair must redistribute, not merge.
        let leftItems = (0..<8).map { IntItem(value: $0) }
        let rightItems = (8..<14).map { IntItem(value: $0) }
        let left = Node<IntItem>.leaf(leftItems, IntSummary(count: leftItems.count))
        let right = Node<IntItem>.leaf(rightItems, IntSummary(count: rightItems.count))
        let root = Node<IntItem>.interior([left, right], IntSummary(count: 14), 1)
        let tree = SumTree<IntItem>(root: root)
        try tree.checkInvariants()

        // Trigger on the very last item (value 13), the right leaf's last, and drop it.
        let edited = try #require(
            tree.pathCopyEdit(
                where: Self.atLeast(14),
                edit: { items, _, _ in Array(items.dropLast()) }))
        try edited.checkInvariants()

        guard case .interior(let children, _, _) = edited.root else {
            Issue.record("expected an interior root")
            return
        }
        #expect(children.count == 2, "parent child count should be unchanged by a redistribute")
        for child in children {
            guard case .leaf(let childItems, _) = child else {
                Issue.record("expected both children to remain leaves")
                continue
            }
            #expect(
                (6...12).contains(childItems.count),
                "redistributed leaf has \(childItems.count) items, outside [6,12]")
        }
        #expect(edited.items().map(\.value) == Array(0..<13))
    }

    @Test(
        "underflow by merge, cascading: a sibling at exactly B merges with the underfull node, and the shortfall propagates one level up when the parent is itself at B"
    )
    func pathCopyEditUnderflowMergeCascades() throws {
        // Three interior grandchildren (`parentA`, `parentB`, `parentC`) under one root,
        // each an interior with exactly `B` (6) leaf children of `B` items apiece.
        // `parentA` starts "itself at B" (6 children) — editing its first leaf child down
        // to 5 items merges it with its sibling leaf (also 6, so combined 11 <= 2B: a
        // merge, not a redistribute), dropping `parentA` to 5 children: underfull one
        // level up from the edited leaf. That underflow must then be repaired at the
        // root, one level further up still — the cascade this test is named for.
        var value = 0
        func makeParent() -> Node<IntItem> {
            let leaves = (0..<6).map { _ -> Node<IntItem> in
                let leafItems = (0..<6).map { _ -> IntItem in
                    defer { value += 1 }
                    return IntItem(value: value)
                }
                return Node<IntItem>.leaf(leafItems, IntSummary(count: leafItems.count))
            }
            let total = leaves.reduce(0) { $0 + $1.summary.count }
            return Node<IntItem>.interior(leaves, IntSummary(count: total), 1)
        }
        let parentA = makeParent()
        let parentB = makeParent()
        let parentC = makeParent()
        let totalBefore =
            parentA.summary.count + parentB.summary.count + parentC.summary.count
        let root = Node<IntItem>.interior(
            [parentA, parentB, parentC], IntSummary(count: totalBefore), 2)
        let tree = SumTree<IntItem>(root: root)
        try tree.checkInvariants()
        #expect(tree.height == 2)
        let allValuesBefore = tree.items().map(\.value)

        // Trigger on the very first item (value 0), `parentA`'s first leaf's first item,
        // and drop it.
        let edited = try #require(
            tree.pathCopyEdit(
                where: Self.atLeast(1),
                edit: { items, _, _ in Array(items.dropFirst()) }))
        try edited.checkInvariants()

        #expect(edited.height == 2, "the cascade should not have collapsed the root")
        guard case .interior(let topChildren, _, _) = edited.root else {
            Issue.record("expected an interior root")
            return
        }
        #expect(
            topChildren.count == 2,
            "expected the cascade to reach the root and merge two of its three children into one"
        )
        #expect(
            edited.items().map(\.value) == Array(allValuesBefore.dropFirst()),
            "order should be preserved with only the first item removed")
    }

    @Test(
        "root collapse: deleting a whole leaf child of a two-child root interior collapses the root and decreases height"
    )
    func pathCopyEditRootCollapse() throws {
        let leafA = (0..<6).map { IntItem(value: $0) }
        let leafB = (6..<12).map { IntItem(value: $0) }
        let root = Node<IntItem>.interior(
            [
                Node<IntItem>.leaf(leafA, IntSummary(count: leafA.count)),
                Node<IntItem>.leaf(leafB, IntSummary(count: leafB.count)),
            ], IntSummary(count: 12), 1)
        let tree = SumTree<IntItem>(root: root)
        try tree.checkInvariants()
        #expect(tree.height == 1)

        // Trigger on the last item (value 11), inside the second leaf, and empty it out
        // entirely — that leaf's whole content is deleted, not just reduced.
        let edited = try #require(
            tree.pathCopyEdit(
                where: Self.atLeast(12),
                edit: { _, _, _ in [] }))
        try edited.checkInvariants()

        #expect(
            edited.height == 0, "collapsing a two-child root to one child should drop height by 1")
        #expect(edited.items().map(\.value) == Array(0..<6))
    }
}
