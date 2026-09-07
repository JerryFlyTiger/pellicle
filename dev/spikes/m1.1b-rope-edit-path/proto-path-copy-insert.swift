import Foundation

// ============================================================================
// PROTOTYPE (d): path-copy insert with local overflow split and leaf-local repack.
// No split, no join, no fragments: descend once, rebuild h+1 nodes, propagate a
// sibling upward only on overflow.  B...2B preserved by construction.
// ============================================================================
private let QB = 6

private func repack(_ bytes: [UInt8]) -> [Chunk] {
    var out: [Chunk] = []
    var start = 0
    while start < bytes.count {
        var end = min(start + 64, bytes.count)
        while end > start + 1 && end < bytes.count && (bytes[end] & 0b1100_0000) == 0b1000_0000 { end -= 1 }
        out.append(Chunk(bytes: bytes[start..<end]))
        start = end
    }
    return out
}

/// Returns the rebuilt node and, on overflow, its new right sibling.
private func insertGo(_ node: Node<Chunk>, _ prefix: Int, _ offset: Int, _ new: [UInt8])
    -> (Node<Chunk>, Node<Chunk>?)
{
    switch node {
    case .leaf(let items, _):
        var cum = prefix
        var i = 0
        while i < items.count {
            let next = cum + Int(items[i].count)
            if next > offset || (i == items.count - 1 && next == offset) { break }
            cum = next
            i += 1
        }
        if i == items.count {  // append at the very end
            var bytes: [UInt8] = []
            if let last = items.last { last.withUnsafeBytes { bytes.append(contentsOf: $0) } }
            bytes.append(contentsOf: new)
            var newItems = items
            let repacked = repack(bytes)
            if items.isEmpty { newItems = repacked } else { newItems.replaceSubrange((items.count - 1)..., with: repacked) }
            if newItems.count <= 2 * QB { return (.makeLeaf(newItems), nil) }
            let mid = newItems.count / 2
            return (.makeLeaf(Array(newItems[0..<mid])), .makeLeaf(Array(newItems[mid...])))
        }
        let local = offset - cum
        // Repack the straddling chunk together with its right neighbour when they are
        // small: this is the fragmentation policy, done leaf-locally instead of by two
        // extra tree walks at the seams.
        var bytes: [UInt8] = []
        bytes.reserveCapacity(128 + new.count)
        items[i].withUnsafeBytes { bytes.append(contentsOf: $0[0..<local]) }
        bytes.append(contentsOf: new)
        items[i].withUnsafeBytes { bytes.append(contentsOf: $0[local...]) }
        var replacedRange = i...i
        // Coalescing removes an item, so it must not push the leaf below B: that is the
        // underflow this design has to respect, and the reason a naive 'always coalesce'
        // breaks the fill bound even though nothing was deleted.
        if i + 1 < items.count && items.count > QB && bytes.count + Int(items[i + 1].count) <= 128 {
            items[i + 1].withUnsafeBytes { bytes.append(contentsOf: $0) }
            replacedRange = i...(i + 1)
        }
        var newItems = items
        newItems.replaceSubrange(replacedRange, with: repack(bytes))
        if newItems.count <= 2 * QB { return (.makeLeaf(newItems), nil) }
        let mid = newItems.count / 2
        return (.makeLeaf(Array(newItems[0..<mid])), .makeLeaf(Array(newItems[mid...])))

    case .interior(let children, _, _):
        var cum = prefix
        var i = 0
        while i < children.count {
            let next = cum + children[i].summary.utf8
            if next > offset || i == children.count - 1 { break }
            cum = next
            i += 1
        }
        let (child, sib) = insertGo(children[i], cum, offset, new)
        var nc = children
        nc[i] = child
        if let sib { nc.insert(sib, at: i + 1) }
        if nc.count <= 2 * QB { return (.makeInterior(nc), nil) }
        let mid = nc.count / 2
        return (.makeInterior(Array(nc[0..<mid])), .makeInterior(Array(nc[mid...])))
    }
}

func insertPathCopy(_ tree: SumTree<Chunk>, _ new: [UInt8], at offset: Int) -> SumTree<Chunk> {
    if new.isEmpty { return tree }
    let (n, sib) = insertGo(tree.root, 0, offset, new)
    if let sib { return SumTree(debugRoot: .makeInterior([n, sib])) }
    return SumTree(debugRoot: n)
}
