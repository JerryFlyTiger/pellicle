/// The lazy, allocation-free traversal cursor M1.2 adds (`dev/specs/m1.2.md` deliverable C).
/// Before this file, nothing in the module streamed a `SumTree`: `SumTree.items()` (and
/// everything built on it — `Rope.chunks()`, `Rope.bytes()`, `Rope.toString()`) flattened
/// the whole tree into an `[Item]` first. Stage 2 measured that flatten at 6.4 ns/chunk and
/// 0.176 ns/byte (`PLAN.md:1934-1935`); this cursor exists to beat that, and `Rope.chunks()`
/// / `Rope.bytes()` are re-expressed on it below rather than duplicated.
///
/// **Allocates nothing per traversal step.** The descent stack is sized once, from the
/// tree's height (`SumTree.height`, logarithmic in item count — see `SumTree.swift`'s file
/// header for why that bound is small), not from the item count; growing it during
/// `init`/`seek` never reallocates past that reserved capacity because height only ever
/// shrinks going *down* the same tree. Holding a `Node`'s own `[Item]`/`[Node<Item>]` array
/// (or a slice of one) costs a retain, not a copy — `Array` is copy-on-write and this
/// cursor never mutates what it holds.
///
/// **Value semantics, matching the rest of the module.** A `SumTree`/`Node` is persistent:
/// an edit never mutates an existing node in place, it builds new ones and leaves the old
/// tree's nodes untouched (see `SumTree.swift`'s file header, "Persistence"). A cursor built
/// from a snapshot therefore holds its own references to that snapshot's actual nodes
/// forever, unaffected by whatever the `Rope`/`SumTree` value it came from is edited into
/// afterward — there is no live reference back to a mutable "current tree" for a later edit
/// to be observed through.
@usableFromInline package struct SumTreeCursor<Item: Summable>: Sendable, IteratorProtocol, Sequence
{
    /// One still-open interior node on the path from the root to the current leaf:
    /// `children` is that node's own child list (a retained slice of the tree's storage, not
    /// a copy), `index` is the child to descend into *next* once the current subtree is
    /// exhausted.
    @usableFromInline struct Frame: Sendable {
        @usableFromInline var children: [Node<Item>]
        @usableFromInline var index: Int
        @usableFromInline init(children: [Node<Item>], index: Int) {
            self.children = children
            self.index = index
        }
    }

    /// The root this cursor was built from, kept only so `seek` can restart a descent from
    /// it; never mutated after `init` (see this type's "value semantics" doc comment above).
    @usableFromInline let root: Node<Item>
    @usableFromInline var stack: [Frame]
    @usableFromInline var currentLeaf: [Item]
    @usableFromInline var leafIndex: Int
    @usableFromInline var exhausted: Bool

    /// Builds a cursor positioned at the first item of `tree` (or immediately exhausted, for
    /// an empty tree).
    package init(_ tree: SumTree<Item>) {
        root = tree.root
        stack = []
        stack.reserveCapacity(Int(tree.height) + 1)
        currentLeaf = []
        leafIndex = 0
        exhausted = false
        descendLeftmost(root)
        if currentLeaf.isEmpty { advanceToNextLeaf() }
    }

    /// Descends `node`'s left spine, pushing one `Frame` per interior level, until it
    /// reaches a leaf, which becomes `currentLeaf`. Never allocates beyond what `stack`
    /// already reserved: `stack.append` stays within that capacity because this is only
    /// ever called with a subtree no taller than the tree `init` measured, and `seek`
    /// (below) never descends into a taller one either.
    @inlinable mutating func descendLeftmost(_ node: Node<Item>) {
        var current = node
        while case .interior(let children, _, _) = current {
            stack.append(Frame(children: children, index: 1))
            current = children[0]
        }
        if case .leaf(let items, _) = current {
            currentLeaf = items
            leafIndex = 0
        }
    }

    /// Pops frames until it finds one with an unvisited sibling, descends that sibling's
    /// left spine, and leaves the cursor positioned at its first item; marks the cursor
    /// `exhausted` if the stack runs out first (there is no next leaf).
    @inlinable mutating func advanceToNextLeaf() {
        while !stack.isEmpty {
            var frame = stack.removeLast()
            if frame.index < frame.children.count {
                let child = frame.children[frame.index]
                frame.index += 1
                stack.append(frame)
                descendLeftmost(child)
                return
            }
        }
        currentLeaf = []
        leafIndex = 0
        exhausted = true
    }

    /// **Test-only hook**, not `package`/`public` — nothing but a test should call this.
    /// The storage identity of the `[Item]` this cursor currently holds as `currentLeaf`,
    /// exposed so `cursorTraversalAllocatesNothing`
    /// (`Tests/TextTests/conversionAndCursorTests.swift`, M1.2 fix round task 4) can compare
    /// it against the tree's own leaf array by address rather than by a net allocation
    /// count. A net `blocks_in_use` delta cannot see a transient per-descent copy that is
    /// freed before the after-measurement — this can, because a copy's base address differs
    /// from the original's even if both are gone by the time anyone measures blocks in use.
    var currentLeafBaseAddress: UnsafeRawPointer? {
        currentLeaf.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
    }

    @inlinable package mutating func next() -> Item? {
        guard !exhausted else { return nil }
        if leafIndex >= currentLeaf.count {
            advanceToNextLeaf()
            guard !exhausted else { return nil }
        }
        let item = currentLeaf[leafIndex]
        leafIndex += 1
        return item
    }

    /// Repositions the cursor at the item where `predicate` first becomes true of the
    /// accumulated summary — the same descent `SumTree.find` does, kept **resumable**: a
    /// `next()` call after `seek` continues from the found item onward, rather than
    /// discarding the cursor. Unlike `find`, this always restarts the descent from the
    /// tree's root (it does not yet exploit a monotonically increasing sequence of seeks to
    /// resume from the *current* position instead — a known narrowing, not a correctness
    /// gap: this is still O(h) per call, the same bound `find` itself has, just without the
    /// further amortisation a from-current-position seek could add for the common case of
    /// many increasing offsets in a row).
    ///
    /// `predicate` must be monotone and false of `.identity`, exactly as `SumTree.find`
    /// requires (same precondition, same reason — see `findNode`'s doc comment). Traps if
    /// `predicate` never becomes true of the tree's own total.
    package mutating func seek(where predicate: (Item.Item_Summary) -> Bool) {
        precondition(
            !predicate(.identity), "SumTreeCursor.seek: predicate must be false of .identity")
        stack.removeAll(keepingCapacity: true)
        currentLeaf = []
        leafIndex = 0
        exhausted = false
        guard descendSeek(root, prefix: .identity, predicate: predicate) else {
            preconditionFailure("SumTreeCursor.seek: predicate never true of the tree's own total")
        }
    }

    /// Descends `node` looking for the first point where `predicate` becomes true, pushing
    /// `Frame`s exactly as `descendLeftmost` does so the cursor remains resumable, and
    /// leaving `currentLeaf`/`leafIndex` positioned at the triggering item. `prefix` is the
    /// summary of everything strictly before `node` — threaded through the recursion exactly
    /// as `findNode`/`splitFragments` thread it (`SumTree.swift`), because `predicate` is
    /// evaluated against the tree's *global* accumulated summary, not a subtree-local reset;
    /// an earlier version of this function passed no prefix and reset to `.identity` at every
    /// level, which made every seek past the first child of the root fail (a predicate whose
    /// target lies beyond that first child's own local summary would never see the global
    /// count needed to trigger). Returns `false` (rather than trapping itself) if `predicate`
    /// never triggers within `node`, so the public `seek` can report a single, clear
    /// precondition failure at the top rather than one buried at an arbitrary recursion depth.
    private mutating func descendSeek(
        _ node: Node<Item>, prefix: Item.Item_Summary, predicate: (Item.Item_Summary) -> Bool
    ) -> Bool {
        switch node {
        case .leaf(let items, _):
            var cum = prefix
            for i in 0..<items.count {
                cum = cum + items[i].summary
                if predicate(cum) {
                    currentLeaf = items
                    leafIndex = i
                    return true
                }
            }
            return false
        case .interior(let children, _, _):
            var cum = prefix
            for i in 0..<children.count {
                let next = cum + children[i].summary
                if predicate(next) {
                    stack.append(Frame(children: children, index: i + 1))
                    return descendSeek(children[i], prefix: cum, predicate: predicate)
                }
                cum = next
            }
            return false
        }
    }
}

extension SumTree {
    /// A lazy, allocation-free cursor over this tree's items, in order — see
    /// `SumTreeCursor`'s doc comment.
    package func makeCursor() -> SumTreeCursor<Item> {
        SumTreeCursor(self)
    }
}
