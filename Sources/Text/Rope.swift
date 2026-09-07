/// The byte-indexed text value (PLAN.md 4.5): a `SumTree<Chunk>` wrapped with a UTF-8-byte
/// coordinate system and a chunking policy, plus the editing operations a buffer needs.
///
/// **Offsets are UTF-8 byte offsets**, and every offset argument must land on a scalar
/// boundary; a non-boundary offset is a programmer error and `precondition`s rather than
/// silently truncating a multi-byte sequence. `isScalarBoundary` lets a caller check first.
///
/// **`Equatable` compares text content, not tree shape**: two ropes holding the same bytes,
/// built by different edit sequences (and therefore possibly different chunk boundaries
/// and tree balance), compare `==`. This follows from the value-semantic, `Sendable`
/// design — a rope is "the text", not "this particular tree".
///
/// **Chunking policy**: pack greedily to 64 bytes, backing off to the last scalar boundary
/// when a would-be 64-byte cut would split one; and, at every concat seam produced by an
/// edit, merge an undersized pair of chunks when they fit in 64 bytes together. Without
/// that seam merge, a long run of tiny edits (a million one-byte inserts, say) would leave
/// a million one-byte chunks — correct but degenerate — which is exactly what
/// `ropeTests.swift`'s fragmentation guard checks for.
///
/// Known gaps, deliberately out of scope for this sub-milestone:
/// - No character-, UTF-16- or line-based conversion API. `TextSummary` already carries
///   the counts such a conversion would need; turning a byte offset into a line/column or
///   a UTF-16 offset (and back) is M1.2's job.
/// - No marker tree (M1.3) and no snapshot type distinct from `Rope` itself — `Rope` is
///   already `Sendable` with value semantics, so a snapshot in this sub-milestone is just
///   a copy of the struct.
package struct Rope: Sendable, Equatable {
    private var tree: SumTree<Chunk>

    private init(tree: SumTree<Chunk>) {
        self.tree = tree
    }

    package init() {
        self.tree = SumTree<Chunk>()
    }

    package init(_ string: String) {
        self.tree = Rope.buildTree(fromUTF8: Array(string.utf8))
    }

    // MARK: - Chunking

    /// Packs a byte array into well-formed `Chunk`s: greedily up to 64 bytes, backing off
    /// to the last scalar boundary at or before the 64-byte mark if a straight 64-byte cut
    /// would split a multi-byte UTF-8 sequence.
    private static func packChunks(_ bytes: [UInt8]) -> [Chunk] {
        guard !bytes.isEmpty else { return [] }
        var chunks: [Chunk] = []
        var start = 0
        while start < bytes.count {
            let idealEnd = min(start + 64, bytes.count)
            var end = idealEnd
            // Equivalent mutant, recorded rather than chased with a test (CLAUDE.md: where a
            // defence cannot be observed by a test, say so instead of pretending): loosening
            // this floor from `start + 1` to `start` changes nothing for valid UTF-8. A
            // non-final chunk (one that hits `idealEnd == start + 64`) is always exactly 64
            // bytes wide before backoff, and a UTF-8 scalar is at most 4 bytes, so the loop
            // can back off at most 3 steps before finding a boundary — it can never reach
            // `start` at all, let alone need the `start + 1` floor to stop it there.
            while end > start + 1 && !Rope.isScalarBoundary(bytes, end) {
                end -= 1
            }
            chunks.append(Chunk(bytes: bytes[start..<end]))
            start = end
        }
        return chunks
    }

    /// True if `offset` in `bytes` does not fall inside a multi-byte UTF-8 sequence —
    /// either at the very start/end, or on a lead byte (top bits not `10xxxxxx`).
    private static func isScalarBoundary(_ bytes: [UInt8], _ offset: Int) -> Bool {
        if offset == 0 || offset == bytes.count { return true }
        return bytes[offset] & 0b1100_0000 != 0b1000_0000
    }

    private static func buildTree(fromUTF8 bytes: [UInt8]) -> SumTree<Chunk> {
        SumTree<Chunk>(items: Rope.packChunks(bytes))
    }

    /// Builds a tree from already-packed chunks, merging the two chunks at the seam
    /// (`left`'s last chunk, `right`'s first chunk) into one when they fit in 64 bytes
    /// together. This is the chunking policy's other half: without it, many small edits at
    /// the same place leave many undersized chunks.
    private static func concatMergingSeam(_ left: SumTree<Chunk>, _ right: SumTree<Chunk>)
        -> SumTree<Chunk>
    {
        guard !left.isEmpty, !right.isEmpty else {
            return SumTree.concat(left, right)
        }
        // Extract left's last chunk and right's first chunk with `cut`, which (unlike
        // `split`) isolates exactly one item regardless of where in the tree it falls —
        // see `cutNode`'s doc comment for why `split` cannot do this for a *last* item.
        guard let (leftRest, leftLast, _, _) = left.cut(where: { $0.utf8 >= left.summary.utf8 })
        else {
            return SumTree.concat(left, right)
        }
        guard let (_, rightFirst, _, rightRest) = right.cut(where: { $0.utf8 >= 1 }) else {
            return SumTree.concat(left, right)
        }
        let combinedCount = Int(leftLast.count) + Int(rightFirst.count)
        guard combinedCount <= 64 else {
            return SumTree.concat(left, right)
        }
        var combinedBytes: [UInt8] = []
        combinedBytes.reserveCapacity(combinedCount)
        leftLast.withUnsafeBytes { combinedBytes.append(contentsOf: $0) }
        rightFirst.withUnsafeBytes { combinedBytes.append(contentsOf: $0) }
        let mergedChunk = Chunk(bytes: combinedBytes)
        let mergedTree = SumTree<Chunk>(items: [mergedChunk])
        return SumTree.concat(SumTree.concat(leftRest, mergedTree), rightRest)
    }

    // MARK: - Queries

    package var summary: TextSummary { tree.summary }

    package var utf8Count: Int { tree.summary.utf8 }

    package var isEmpty: Bool { tree.isEmpty }

    /// O(1): the underlying tree's root height. Exposed for tests to assert non-degeneracy
    /// (a property test that never drives this above 0 is exercising a single leaf, not a
    /// tree) and because it is generally useful.
    package var height: UInt8 { tree.height }

    /// Forwards to the underlying `SumTree`'s invariant check, plus one check `SumTree`
    /// cannot do itself because it is generic over `Item` and knows nothing about `Chunk`'s
    /// packed summary cache: every chunk's cached `summary` must equal a fresh
    /// recomputation from its bytes (`Chunk.recomputedSummaryFromBytes()`). A stale cache is
    /// otherwise undetectable and would silently corrupt every ancestor summary in the tree.
    /// Exposed for tests (see `ropeTests.swift`'s randomised model test), not part of the
    /// API surface a normal caller needs.
    package func checkTreeInvariants() throws {
        try tree.checkInvariants()
        var staleChunks: [String] = []
        for chunk in tree.items() {
            let cached = chunk.summary
            let fresh = chunk.recomputedSummaryFromBytes()
            if cached != fresh {
                staleChunks.append(
                    "chunk with \(chunk.count) bytes: cached summary \(cached) != "
                        + "recomputed \(fresh)")
            }
        }
        if !staleChunks.isEmpty {
            throw SumTreeInvariantViolation(messages: staleChunks)
        }
    }

    /// True if `byteOffset` does not land inside a multi-byte UTF-8 sequence. `0` and
    /// `utf8Count` (the very ends) are always boundaries.
    package func isScalarBoundary(_ byteOffset: Int) -> Bool {
        precondition(byteOffset >= 0 && byteOffset <= utf8Count, "byte offset out of range")
        if byteOffset == 0 || byteOffset == utf8Count { return true }
        let (chunk, localOffset) = Rope.locate(tree, byteOffset)
        return Rope.isChunkLocalScalarBoundary(chunk, localOffset)
    }

    /// Finds the chunk containing byte offset `byteOffset` (0 < byteOffset < tree total),
    /// and how far into that chunk the offset falls, using `SumTree.find` — genuinely O(h),
    /// never materialising, copying or rebuilding any part of the tree (measured before this
    /// rewrite: 131 µs on a 1 MB rope, because the `cut`-then-discard-the-halves this used
    /// to be built on rebuilds both sides at every level; see `M1.1-perf-findings.md`).
    private static func locate(_ tree: SumTree<Chunk>, _ byteOffset: Int) -> (Chunk, Int) {
        // Equivalent mutant, but only *through this file's current caller* — not in general,
        // and recorded that way rather than chased with a test (CLAUDE.md: where a defence
        // cannot be observed by a test, say so instead of pretending). Two things are true
        // at once:
        //
        // 1. At an *interior* chunk boundary, `>` vs `>=` only changes which chunk gets
        //    returned (`>=` returns the *preceding* chunk with `localOffset == chunk.count`;
        //    `>` returns the *following* chunk with `localOffset == 0`), and
        //    `isScalarBoundary`'s caller-side check (`isChunkLocalScalarBoundary` treats
        //    `offset == 0` and `offset == chunk.count` as unconditionally true, because a
        //    chunk boundary is always a valid scalar boundary by `Chunk`'s own invariant)
        //    cannot tell the two chunks' answers apart. Verified empirically, not just
        //    algebraically: exhaustively checking every offset of a ~5,000-byte, multi-chunk,
        //    height-1 fixture against an independent byte-level oracle found zero observable
        //    difference here.
        // 2. At the *global* endpoint `byteOffset == utf8Count`, the two predicates are NOT
        //    equivalent: `>` can never trigger against the tree's own total summary (see
        //    `SumTree.swift`'s file header — this is exactly why `cut` needs a `>=`-style
        //    predicate to isolate a tree's *last* item), so `find` returns `nil` and this
        //    function traps; `>=` would trigger on the last item and return it. That is a
        //    real, observable divergence — it just cannot be observed *here*, because
        //    `isScalarBoundary` (this function's only caller) early-returns `true` for both
        //    `byteOffset == 0` and `byteOffset == utf8Count` before ever calling `locate`, so
        //    `byteOffset` reaching this line is always strictly interior. Any new caller in
        //    this file that passed a raw endpoint through without that filter would need `>`
        //    to keep trapping (matching this function's own documented `0 < byteOffset <
        //    tree total` contract) rather than silently returning the last chunk.
        //
        // `find`'s own convention (matching `cut`'s, verified by `sumTreeTests.swift`'s
        // `findAgreesWithCut`) is `>`, which is why this stays `>` rather than being
        // arbitrary.
        guard let (chunk, itemPrefix) = tree.find(where: { $0.utf8 > byteOffset })
        else {
            preconditionFailure("byte offset out of range")
        }
        return (chunk, byteOffset - itemPrefix.utf8)
    }

    // MARK: - Splitting at an arbitrary byte offset

    /// Splits the rope's tree at `byteOffset`, which need not be a chunk boundary (it must
    /// be a scalar boundary). Built from `SumTree.cut`/`concat`: the tree-level cursor
    /// extracts the chunk containing the offset, the chunks strictly before and after it,
    /// and the byte count preceding it, in one pass; if the offset lands inside that chunk,
    /// the chunk's own bytes are sliced (not the tree) and the two pieces rejoined with
    /// `concat` — the only place this file looks inside a `Chunk`'s bytes, because the
    /// generic `SumTree` has no way to split an item itself.
    private static func splitTree(
        _ tree: SumTree<Chunk>, at byteOffset: Int
    ) -> (SumTree<Chunk>, SumTree<Chunk>) {
        precondition(byteOffset >= 0 && byteOffset <= tree.summary.utf8)
        if byteOffset == 0 { return (SumTree<Chunk>(), tree) }
        if byteOffset == tree.summary.utf8 { return (tree, SumTree<Chunk>()) }

        guard let (before, chunk, itemPrefix, after) = tree.cut(where: { $0.utf8 > byteOffset })
        else {
            preconditionFailure("byte offset out of range")
        }
        let localOffset = byteOffset - itemPrefix.utf8

        if localOffset == 0 {
            return (before, SumTree.concat(SumTree<Chunk>(items: [chunk]), after))
        }
        if localOffset == Int(chunk.count) {
            return (SumTree.concat(before, SumTree<Chunk>(items: [chunk])), after)
        }

        precondition(
            Rope.isChunkLocalScalarBoundary(chunk, localOffset),
            "byte offset \(byteOffset) is not a scalar boundary")

        var leftBytes: [UInt8] = []
        var rightBytes: [UInt8] = []
        chunk.withUnsafeBytes { buffer in
            leftBytes = Array(buffer[0..<localOffset])
            rightBytes = Array(buffer[localOffset...])
        }
        let leftTree = SumTree<Chunk>(items: [Chunk(bytes: leftBytes)])
        let rightTree = SumTree<Chunk>(items: [Chunk(bytes: rightBytes)])
        return (SumTree.concat(before, leftTree), SumTree.concat(rightTree, after))
    }

    private static func isChunkLocalScalarBoundary(_ chunk: Chunk, _ offset: Int) -> Bool {
        if offset == 0 || offset == Int(chunk.count) { return true }
        return chunk[offset] & 0b1100_0000 != 0b1000_0000
    }

    // MARK: - Editing

    package func slice(_ byteRange: Range<Int>) -> Rope {
        precondition(byteRange.lowerBound >= 0 && byteRange.upperBound <= utf8Count)
        let (_, fromLower) = Rope.splitTree(tree, at: byteRange.lowerBound)
        let innerUpper = byteRange.upperBound - byteRange.lowerBound
        let (result, _) = Rope.splitTree(fromLower, at: innerUpper)
        return Rope(tree: result)
    }

    package mutating func replaceSubrange(_ byteRange: Range<Int>, with other: Rope) {
        precondition(byteRange.lowerBound >= 0 && byteRange.upperBound <= utf8Count)
        let (before, rest) = Rope.splitTree(tree, at: byteRange.lowerBound)
        let (_, after) = Rope.splitTree(rest, at: byteRange.upperBound - byteRange.lowerBound)
        tree = Rope.concatMergingSeam(Rope.concatMergingSeam(before, other.tree), after)
    }

    package mutating func replaceSubrange(_ byteRange: Range<Int>, with string: String) {
        replaceSubrange(byteRange, with: Rope(string))
    }

    package mutating func insert(_ string: String, at byteOffset: Int) {
        replaceSubrange(byteOffset..<byteOffset, with: string)
    }

    package mutating func removeSubrange(_ byteRange: Range<Int>) {
        replaceSubrange(byteRange, with: Rope())
    }

    package mutating func append(_ other: Rope) {
        tree = Rope.concatMergingSeam(tree, other.tree)
    }

    // MARK: - Extraction

    package func chunks() -> some Sequence<Chunk> {
        tree.items()
    }

    package func bytes() -> some Sequence<UInt8> {
        var result: [UInt8] = []
        result.reserveCapacity(utf8Count)
        for chunk in tree.items() {
            chunk.withUnsafeBytes { result.append(contentsOf: $0) }
        }
        return result
    }

    package func toString() -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(utf8Count)
        for chunk in tree.items() {
            chunk.withUnsafeBytes { bytes.append(contentsOf: $0) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Equatable

    package static func == (lhs: Rope, rhs: Rope) -> Bool {
        guard lhs.summary == rhs.summary else { return false }
        return Array(lhs.bytes()) == Array(rhs.bytes())
    }
}
