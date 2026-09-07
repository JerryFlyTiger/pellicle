import Foundation

// ============================================================================
// PROTOTYPE: `pushTree` — join that accepts an UNDERFULL right-hand argument and
// dissolves it, so a split's per-level node groups never need to be wrapped into a
// well-formed node.  Output is always strictly B...2B.
// ============================================================================
private let PB = 6

extension Node {
    static func loose(_ children: [Node<Item>]) -> Node<Item> {  // may be underfull: transient only
        makeInterior(children)
    }
    var childCount: Int {
        switch self {
        case .leaf(let i, _): return i.count
        case .interior(let c, _, _): return c.count
        }
    }
    var isUnderfull: Bool { childCount < PB }
}

/// Appends `other` to `node`'s right spine. Returns a right sibling if `node` had to split.
/// `other.height <= node.height` required. `other` MAY be underfull; `node` may not.
private func pushRecursive<Item: Summable>(
    _ node: Node<Item>, _ other: Node<Item>
) -> (Node<Item>, Node<Item>?) {
    switch node {
    case .leaf(let items, _):
        guard case .leaf(let otherItems, _) = other else {
            preconditionFailure("push: height agreement violated at leaf level")
        }
        let all = items + otherItems
        if all.count <= 2 * PB { return (.makeLeaf(all), nil) }
        let mid = all.count / 2
        return (.makeLeaf(Array(all[0..<mid])), .makeLeaf(Array(all[mid...])))
    case .interior(let children, _, let height):
        var toAppend: [Node<Item>] = []
        var newChildren = children
        let delta = Int(height) - Int(other.height)
        if delta == 0 {
            // Same height: splice the other node's children in FLAT. This is the step that
            // makes an underfull `other` harmless — its children are all well-formed.
            guard case .interior(let oc, _, _) = other else {
                preconditionFailure("push: equal heights but one leaf, one interior")
            }
            toAppend = oc
        } else if delta == 1 && !other.isUnderfull {
            toAppend = [other]
        } else {
            // `other` is underfull, or more than one level shorter: push it deeper.
            let (repl, split) = pushRecursive(children[children.count - 1], other)
            newChildren[newChildren.count - 1] = repl
            if let split { toAppend = [split] }
        }
        let total = newChildren.count + toAppend.count
        if total <= 2 * PB {
            newChildren.append(contentsOf: toAppend)
            return (.makeInterior(newChildren), nil)
        }
        var all = newChildren
        all.append(contentsOf: toAppend)
        let mid = all.count / 2
        return (.makeInterior(Array(all[0..<mid])), .makeInterior(Array(all[mid...])))
    }
}

/// The public join. `b` may be underfull/loose; `a` must be well-formed (or empty).
func pushTree<Item: Summable>(_ a: Node<Item>, _ b: Node<Item>) -> Node<Item> {
    if b.childCount == 0 { return a }
    if a.childCount == 0 {
        // `a` empty: `b` may be loose, so normalise it by pushing its parts into an empty tree.
        if !b.isUnderfull || b.height == 0 { return b }
        guard case .interior(let bc, _, _) = b else { return b }
        var acc = bc[0]
        for i in 1..<bc.count { acc = pushTree(acc, bc[i]) }
        return acc
    }
    if a.height < b.height {
        guard case .interior(let bc, _, _) = b else { preconditionFailure("taller must be interior") }
        var acc = a
        for child in bc { acc = pushTree(acc, child) }
        return acc
    }
    let (n, split) = pushRecursive(a, b)
    if let split { return .makeInterior([n, split]) }
    return n
}

// ---------------------------------------------------------------------------
// Split producing per-level fragments, rebuilt with pushTree — ONE descent.
// ---------------------------------------------------------------------------
func splitFragments<Item: Summable>(
    _ node: Node<Item>, prefix: Item.Item_Summary, predicate: (Item.Item_Summary) -> Bool,
    left: inout [Node<Item>], right: inout [Node<Item>]
) {
    switch node {
    case .leaf(let items, _):
        var cum = prefix
        for i in 0..<items.count {
            let next = cum + items[i].summary
            if predicate(next) {
                left.append(.makeLeaf(Array(items[0...i])))
                right.append(.makeLeaf(Array(items[(i + 1)...])))
                return
            }
            cum = next
        }
        left.append(node)
        right.append(.makeLeaf([]))
    case .interior(let children, _, _):
        var cum = prefix
        for i in 0..<children.count {
            let next = cum + children[i].summary
            if predicate(next) {
                // groups at THIS level, pushed before descending (left: top-down order)
                if i > 0 { left.append(.loose(Array(children[0..<i]))) }
                var subLeft: [Node<Item>] = [], subRight: [Node<Item>] = []
                splitFragments(children[i], prefix: cum, predicate: predicate,
                               left: &subLeft, right: &subRight)
                left.append(contentsOf: subLeft)
                right.append(contentsOf: subRight)
                if i + 1 < children.count { right.append(.loose(Array(children[(i + 1)...]))) }
                return
            }
            cum = next
        }
        left.append(node)
        right.append(.makeLeaf([]))
    }
}

func splitViaFragments<Item: Summable>(
    _ tree: SumTree<Item>, where predicate: (Item.Item_Summary) -> Bool
) -> (Node<Item>, Node<Item>) {
    var l: [Node<Item>] = [], r: [Node<Item>] = []
    if predicate(.identity) { return (.makeLeaf([]), tree.root) }
    splitFragments(tree.root, prefix: .identity, predicate: predicate, left: &l, right: &r)
    var lt = Node<Item>.makeLeaf([])
    for f in l { lt = pushTree(lt, f) }
    // right fragments are in top-down order too (shallow-first from the descent, then
    // increasing) — they must be joined in the order emitted, which is bottom-up-then-up.
    var rt = Node<Item>.makeLeaf([])
    for f in r { rt = pushTree(rt, f) }
    return (lt, rt)
}
