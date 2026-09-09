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
/// - No marker tree (M1.3) and no snapshot type distinct from `Rope` itself — `Rope` is
///   already `Sendable` with value semantics, so a snapshot in this sub-milestone is just
///   a copy of the struct.
///
/// **M1.2 added** metric conversions (`TextMetric`, `convert`, `lineAndByteColumn`,
/// `byteOffset(line:byteColumn:)`, `byteOffsetOfLineStart`, `lineCount` — see below), a
/// bottom-up bulk loader (`SumTree.swift`), and a lazy cursor (`SumTreeCursor.swift`,
/// re-expressing `chunks()`/`bytes()`/`toString()`).
///
/// **Conversion offsets inherit this file's own scalar-boundary contract** (`isScalarBoundary`
/// above): every offset argument to `convert`/`lineAndByteColumn`/`byteOffset` must land on a
/// scalar boundary in whichever metric it is expressed in, and a non-boundary offset is a
/// programmer error that `precondition`/`preconditionFailure`s inside the chunk-local scan
/// rather than silently truncating. **Nothing regression-tests that trap**, for the same
/// reason the two in `generalPathReplace` are not covered (see this file's header there, and
/// `PLAN.md:1969-1974`): every randomised and property test in this file and
/// `conversionAndCursorTests.swift` draws its offsets from a metric's own valid boundary set,
/// and asserting the trap itself would need an out-of-process crash harness this project does
/// not have.

/// The four coordinate systems M1.2's conversions move between (`dev/specs/m1.2.md`
/// deliverable A). `@frozen`, not a protocol: this is a hot path (`PLAN.md:340-351` names
/// the snapshot cursor as a future inlining-promotion candidate, and this metric is the
/// type it is parameterised over), and a protocol boundary was measured non-devirtualised
/// in every configuration M0 tried (decision log item 4.16). `TextMetric` is a promotion
/// candidate whose benchmark has not asked for it yet — see `count(in:)` below for why it
/// carries no `@inlinable` today. Eight hand-written `utf8ToUTF16`/`utf16ToScalars`/...
/// functions were rejected for the same reason stage 2 gave when it deleted
/// `buildFromNodes`: one implementation, not `4 × 3` of them that must all agree.
@frozen
package enum TextMetric: Sendable, Equatable {
    case utf8, utf16, scalars, lines
}

extension TextMetric {
    /// Reads this metric's running count out of a `TextSummary`.
    ///
    /// `TextMetric` is a promotion candidate whose benchmark has not asked for it yet: the
    /// `@inlinable` this carried was removed because a plain-`package` `@inlinable` is
    /// unchecked by the compiler and reads as "promoted" to anyone skimming, when it does
    /// nothing across a module boundary (`dev/specs/m1.2-promotion-and-guards.md` task 1).
    package func count(in summary: TextSummary) -> Int {
        switch self {
        case .utf8: return summary.utf8
        case .utf16: return summary.utf16
        case .scalars: return summary.scalars
        case .lines: return summary.lines
        }
    }

    fileprivate static func current(
        _ metric: TextMetric, utf8: Int, utf16: Int, scalars: Int, lines: Int
    ) -> Int {
        switch metric {
        case .utf8: return utf8
        case .utf16: return utf16
        case .scalars: return scalars
        case .lines: return lines
        }
    }

    /// The chunk-local half of `Rope.convert` for `from` in `{utf8, utf16, scalars}` (see
    /// `Rope.convert`'s doc comment for why `.lines` is handled separately). Scans `chunk`
    /// scalar by scalar — never stopping mid-scalar, so a multi-byte scalar's UTF-16 width
    /// and scalar-count contribution are never read half-formed — tracking all four running
    /// counts in lockstep (mirroring `Chunk.scanSummary`'s own byte walk), until `from`'s
    /// running count equals `target`; returns `to`'s running count at that same point.
    /// `from == .utf8` skips the scan: a byte count already *is* the byte position, so only
    /// `to`'s count over that byte range needs computing (`chunkLocalCount` below).
    static func chunkLocalScan(_ chunk: Chunk, target: Int, from: TextMetric, to: TextMetric)
        -> Int
    {
        if from == .utf8 {
            return chunkLocalCount(chunk, upToByte: target, of: to)
        }
        if target == 0 { return 0 }
        var utf8 = 0
        var utf16 = 0
        var scalars = 0
        var lines = 0
        var p = 0
        let n = Int(chunk.count)
        while p < n {
            let lead = chunk[p]
            let scalarLen = Rope.utf8ScalarByteLength(lead)
            utf8 += scalarLen
            scalars += 1
            utf16 += scalarLen == 4 ? 2 : 1
            if scalarLen == 1 && lead == 0x0A { lines += 1 }
            p += scalarLen
            if TextMetric.current(from, utf8: utf8, utf16: utf16, scalars: scalars, lines: lines)
                == target
            {
                return TextMetric.current(
                    to, utf8: utf8, utf16: utf16, scalars: scalars, lines: lines)
            }
        }
        preconditionFailure(
            "TextMetric.chunkLocalScan: target \(target) is not a valid \(from) boundary in this chunk"
        )
    }

    /// The `.lines`-only local search `Rope.convert`/`byteOffsetOfLineStart` use: the first
    /// local byte position where the chunk's own running newline count *exceeds* `target`,
    /// matching `SumTree.find`'s `>` convention one level down. `.lines` is not positional
    /// (see `Rope.convert`'s doc comment on why it is handled separately from the other
    /// three): "leftmost local position whose newline count equals `target`" is not what a
    /// line start means (it would answer with the position *before* the line even starts,
    /// wherever the count last held that value); "leftmost position after the count's last
    /// increase" is.
    static func chunkLocalLineStart(_ chunk: Chunk, target: Int, to: TextMetric) -> Int {
        var utf8 = 0
        var utf16 = 0
        var scalars = 0
        var lines = 0
        var p = 0
        let n = Int(chunk.count)
        while p < n {
            let lead = chunk[p]
            let scalarLen = Rope.utf8ScalarByteLength(lead)
            utf8 += scalarLen
            scalars += 1
            utf16 += scalarLen == 4 ? 2 : 1
            if scalarLen == 1 && lead == 0x0A { lines += 1 }
            p += scalarLen
            if lines > target {
                return TextMetric.current(
                    to, utf8: utf8, utf16: utf16, scalars: scalars, lines: lines)
            }
        }
        preconditionFailure(
            "TextMetric.chunkLocalLineStart: line start \(target + 1) is not within this chunk")
    }

    /// The `from == .utf8` fast path's second half: the `to`-metric count over exactly the
    /// first `byteCount` bytes of `chunk` (a plain forward scan, no target to stop at other
    /// than the byte count itself — `from == .utf8` never needs the `==`/`>`-driven search
    /// `chunkLocalScan`/`chunkLocalLineStart` do, because a byte count already names a byte
    /// position with no ambiguity).
    private static func chunkLocalCount(
        _ chunk: Chunk, upToByte byteCount: Int, of metric: TextMetric
    )
        -> Int
    {
        if metric == .utf8 { return byteCount }
        var utf16 = 0
        var scalars = 0
        var lines = 0
        var p = 0
        while p < byteCount {
            let lead = chunk[p]
            let scalarLen = Rope.utf8ScalarByteLength(lead)
            scalars += 1
            utf16 += scalarLen == 4 ? 2 : 1
            if scalarLen == 1 && lead == 0x0A { lines += 1 }
            p += scalarLen
        }
        precondition(
            p == byteCount,
            "TextMetric.chunkLocalCount: byte offset \(byteCount) is not a scalar boundary")
        switch metric {
        case .utf8: return byteCount
        case .utf16: return utf16
        case .scalars: return scalars
        case .lines: return lines
        }
    }
}

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

    /// Test-only: builds a rope directly from already-formed chunks via `SumTree.init(items:)`
    /// (a single leaf when `chunks.count <= 2 * branchingFactor`), skipping `packChunks` and
    /// the general path's seam-merge policy entirely. `internal`, not `package`: reached only
    /// via `@testable import Text` from `ropeTests.swift`, which needs it to build a *root*
    /// leaf holding two adjacent chunks whose sum is `<= 64`.
    ///
    /// An earlier version of this comment said that pair is "a shape no edit path can
    /// produce". That is false, and the counter-evidence was already in the tree: the Part D
    /// scan in `ropeTests.swift` counts **19** such adjacent pairs in the large band and 6 in
    /// the small band after an ordinary randomised run (15 and 2 when that sentence was first
    /// written, before M1.1b stage 2; re-measured here rather than carried over, because this
    /// comment block has twice been rewritten for stating something it had not checked).
    /// Coalescing is leaf-local, so two things still leave such a pair standing — the coalesce
    /// does not iterate to a fixpoint, so a merge product is never re-examined against the
    /// neighbour beyond the one it just absorbed; and `SumTree`'s `combineUnderflowedSiblings`,
    /// which concatenates two sibling
    /// leaves' items during underflow repair with no awareness of the `<= 64` policy at all,
    /// so nothing ever inspects the pair it creates at the join — that path can even leave
    /// such a pair in a *root* leaf, by merging two sibling leaves and then collapsing the
    /// single-child root onto the result.
    ///
    /// A second version of this comment then replaced the false claim with a narrower one,
    /// that any edit path reaching a root leaf would merge the pair. A cold read refuted that
    /// too, by the mechanism just described. So this comment now claims nothing general at
    /// all: the reason the fixture is built here is simply that the test needs this shape, and
    /// the only property it relies on is measured rather than argued — removing the no-op
    /// short-circuit makes `appendAndInsertEmptyLeaveShapeUnchanged` fail and restoring it
    /// makes it pass. Two false claims in a row is the argument for making none.
    ///
    /// It validates nothing beyond `Chunk.init`'s own `1...64`-byte and scalar-boundary
    /// preconditions: like `SumTree.init(root:)`, it can build a rope whose *chunking policy*
    /// is unreachable by any edit path, so a test using it must say why the shape it wants is
    /// legitimate.
    init(unmergedChunks chunks: [Chunk]) {
        self.tree = SumTree<Chunk>(items: chunks)
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

    /// The two bytes-arrays of `a` and `b` concatenated into one `Chunk` — the seam-merge
    /// policy's actual byte work, shared by both directions it is applied in below.
    private static func mergedChunk(_ a: Chunk, _ b: Chunk) -> Chunk {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Int(a.count) + Int(b.count))
        a.withUnsafeBytes { bytes.append(contentsOf: $0) }
        b.withUnsafeBytes { bytes.append(contentsOf: $0) }
        return Chunk(bytes: bytes)
    }

    /// The seam-merge policy's trailing side: if `fragments`' last chunk is directly
    /// accessible — the last element of a plain `Fragment.items` group, not buried inside a
    /// `Fragment.nodes` subtree — and it fits with `chunk` in 64 bytes together, removes it
    /// from `fragments` and returns the merged replacement; otherwise leaves `fragments`
    /// untouched and returns `nil`. A `Fragment.nodes` group is declined rather than walked
    /// into: that would reintroduce a cursor descent into a subtree this rewrite specifically
    /// avoids walking twice, in exchange for a merge this policy already treats as an
    /// optimisation, not a correctness requirement (see `generalPathReplace`'s doc comment).
    private static func mergeTrailingSeam(
        _ fragments: inout [Fragment<Chunk>], with chunk: Chunk
    ) -> Chunk? {
        guard case .items(let slice)? = fragments.last, let last = slice.last else { return nil }
        // mutation focus: the seam `<= 64` comparison, trailing side.
        guard Int(last.count) + Int(chunk.count) <= 64 else { return nil }
        let merged = Rope.mergedChunk(last, chunk)
        let remainder = slice.dropLast()
        if remainder.isEmpty {
            fragments.removeLast()
        } else {
            fragments[fragments.count - 1] = .items(remainder)
        }
        return merged
    }

    /// The seam-merge policy's leading side, symmetric with `mergeTrailingSeam` above.
    private static func mergeLeadingSeam(
        _ fragments: inout [Fragment<Chunk>], with chunk: Chunk
    ) -> Chunk? {
        guard case .items(let slice)? = fragments.first, let first = slice.first else {
            return nil
        }
        // mutation focus: the seam `<= 64` comparison, leading side.
        guard Int(chunk.count) + Int(first.count) <= 64 else { return nil }
        let merged = Rope.mergedChunk(chunk, first)
        let remainder = slice.dropFirst()
        if remainder.isEmpty {
            fragments.removeFirst()
        } else {
            fragments[0] = .items(remainder)
        }
        return merged
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

    // MARK: - Metric conversions (M1.2)

    /// A byte offset within a single `Chunk` (a lead byte, or the very end) as scalars of
    /// its UTF-8 encoding: `0x00...0x7F` is 1 byte, `0xC2...0xDF` is 2, `0xE0...0xEF` is 3,
    /// `0xF0...0xF4` is 4. Assumes `chunk`'s bytes are well-formed UTF-8 (`Chunk`'s own
    /// invariant, enforced at every initializer), so no other lead-byte range is possible.
    /// Shared by `TextMetric.chunkLocalScan`/`chunkLocalLineStart`, which both need to walk
    /// a chunk scalar by scalar rather than byte by byte, so a multi-byte scalar's UTF-16
    /// width and scalar count are never read from a byte in the middle of it.
    @inlinable
    static func utf8ScalarByteLength(_ lead: UInt8) -> Int {
        if lead & 0b1000_0000 == 0 { return 1 }
        if lead & 0b1110_0000 == 0b1100_0000 { return 2 }
        if lead & 0b1111_0000 == 0b1110_0000 { return 3 }
        return 4
    }

    /// Converts an offset expressed in `from` units to the equivalent offset in `to` units,
    /// at O(log n) — reach the chunk containing it via `SumTree.find` (O(h), allocates
    /// nothing — see `SumTree.swift`'s file header), then scan within that one chunk
    /// (O(64) — see `Chunk`'s size invariant). `PLAN.md:460` promises this complexity, and
    /// `PLAN.md:592` (LSP UTF-16 positions "converted by rope summaries, never by scanning")
    /// depends on it: a conversion that scanned from the start of the buffer would fail this
    /// even if its answers were right.
    ///
    /// **`.lines` is not like the other three.** `utf8`/`utf16`/`scalars` each advance by
    /// exactly one unit per scalar (`utf16` by two for an astral scalar) and never revisit a
    /// value, so a valid boundary offset in one of them names exactly one byte position —
    /// converting between any pair of these three, or between one of them and `.lines`, is
    /// unambiguous and handled by the general path below. `.lines` counts a *byte value*
    /// (`"\n"`), not units consumed: every byte position within one line shares the same
    /// `.lines` count, so "the position where `.lines`'s count equals N" is not
    /// well-defined — what M1.2's public surface actually wants from `.lines` as a `from`
    /// metric is "the start of line N" (`byteOffsetOfLineStart`, which this delegates to);
    /// see that function's doc comment for the one-off shift this requires.
    package func convert(offset: Int, from: TextMetric, to: TextMetric) -> Int {
        if from == .lines {
            return byteOffsetOfLineStart(offset, resultMetric: to)
        }
        let total = from.count(in: summary)
        precondition(
            offset >= 0 && offset <= total,
            "Rope.convert: offset \(offset) out of range for \(from) (total \(total))")
        if from == to { return offset }
        if offset == 0 { return 0 }
        if offset == total { return to.count(in: summary) }
        guard let (chunk, itemPrefix) = tree.find(where: { from.count(in: $0) > offset })
        else {
            preconditionFailure("Rope.convert: offset \(offset) out of range for \(from)")
        }
        let localTarget = offset - from.count(in: itemPrefix)
        let localResult = TextMetric.chunkLocalScan(chunk, target: localTarget, from: from, to: to)
        return to.count(in: itemPrefix) + localResult
    }

    /// `byteOffsetOfLineStart`'s actual implementation, generalised to return the start of
    /// `line` in any metric (not just `utf8`) so `convert(offset:from:.lines,to:)` can share
    /// it. `line == 0` is always offset 0 in every metric, with no descent. For `line > 0`:
    /// finds the chunk containing the boundary between line `line - 1` and line `line` (the
    /// chunk whose own newline count first pushes the running total past `line - 1`, i.e.
    /// `>= line`, via the same `>`-predicate `SumTree.find` uses everywhere else in this
    /// file), then `chunkLocalLineStart` finds the exact byte within it — see that
    /// function's doc comment for why this needs the `>` convention rather than `==`.
    private func byteOffsetOfLineStart(_ line: Int, resultMetric: TextMetric) -> Int {
        precondition(
            line >= 0 && line < lineCount, "Rope.byteOffsetOfLineStart: line \(line) out of range")
        if line == 0 { return 0 }
        let target = line - 1
        guard let (chunk, itemPrefix) = tree.find(where: { $0.lines > target }) else {
            preconditionFailure("Rope.byteOffsetOfLineStart: line \(line) out of range")
        }
        let localTarget = target - itemPrefix.lines
        let localResult = TextMetric.chunkLocalLineStart(
            chunk, target: localTarget, to: resultMetric)
        return resultMetric.count(in: itemPrefix) + localResult
    }

    /// The number of lines in the buffer: `summary.lines` (the newline count) plus one,
    /// since the text after the last newline (possibly empty) is always itself a line.
    package var lineCount: Int { summary.lines + 1 }

    /// The 0-based line and UTF-8-byte column of `byteOffset`. **Both are 0-based** — GNU
    /// Emacs's `line-number-at-pos`/`current-column` oracle this project's tests check
    /// against uses 1-based lines, so a test comparing the two applies that offset itself,
    /// visibly, rather than this function silently matching Emacs's convention (see
    /// `conversionAndCursorTests.swift`'s oracle test). The column is in **UTF-8 bytes**,
    /// the unit `firstLineLen`/`lastLineLen`/`maxLineLen` already use (`TextSummary.swift`)
    /// — a caller wanting a UTF-16 (LSP) or scalar (Emacs `current-column`) column composes
    /// this with `convert`; M1.2 does not add a second column unit (see `dev/specs/m1.2.md`
    /// section 1.A).
    package func lineAndByteColumn(atByteOffset byteOffset: Int) -> (line: Int, byteColumn: Int) {
        precondition(byteOffset >= 0 && byteOffset <= utf8Count)
        let line = convert(offset: byteOffset, from: .utf8, to: .lines)
        let lineStart = byteOffsetOfLineStart(line)
        return (line, byteOffset - lineStart)
    }

    /// The byte offset of the first byte of `line` (0-based) — `0` for `line == 0`, and
    /// otherwise the byte right after line `line - 1`'s trailing `"\n"`.
    package func byteOffsetOfLineStart(_ line: Int) -> Int {
        byteOffsetOfLineStart(line, resultMetric: .utf8)
    }

    /// The byte offset of `(line, byteColumn)` — the inverse composition
    /// `lineAndByteColumn` decomposes into. Inherits this file's scalar-boundary contract
    /// (see the file header): the result must land on a scalar boundary, or this traps.
    ///
    /// **`byteColumn` may equal the line's own length, but no more.** A line's byte span
    /// runs from its start up to (but not including) the `"\n"` that ends it, or up to
    /// `utf8Count` for the last line (`TextSummary`'s `firstLineLen`/`lastLineLen` count the
    /// same way: bytes *before* the terminating `"\n"`). `byteColumn == length` therefore
    /// names the position of that `"\n"` byte itself (or the buffer's end, for the last
    /// line) — still `lineAndByteColumn`'s inverse at that point, since converting that same
    /// offset back reports it as column `length` of this same line, the `"\n"` not yet
    /// having incremented the line count. `byteColumn > length` would name a position at or
    /// past the start of the *next* line, which is not this line's inverse to give back, so
    /// it traps rather than silently answering with a different line's position.
    package func byteOffset(line: Int, byteColumn: Int) -> Int {
        precondition(byteColumn >= 0)
        let lineStart = byteOffsetOfLineStart(line)
        let lineEnd = line + 1 < lineCount ? byteOffsetOfLineStart(line + 1) - 1 : utf8Count
        let result = lineStart + byteColumn
        precondition(
            result <= lineEnd,
            "Rope.byteOffset: byteColumn \(byteColumn) is past the end of line \(line) "
                + "(\(lineEnd - lineStart) bytes)")
        precondition(
            isScalarBoundary(result),
            "Rope.byteOffset: line \(line), byteColumn \(byteColumn) is not a scalar boundary")
        return result
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

    /// True if `bytes` is a well-formed sequence of UTF-8 scalar encodings end to end (an
    /// empty array is well-formed). Rejects: a leading continuation byte; a lead byte whose
    /// declared continuation-byte count runs past the end of `bytes` (a truncated
    /// sequence); a lead byte followed by a byte that is not a continuation byte; the
    /// never-valid lead bytes `0xC0`, `0xC1`, and `0xF5`...`0xFF`; and, for the multi-byte
    /// forms, an over-long encoding, a surrogate codepoint (`0xD800`...`0xDFFF`), or a
    /// scalar past `0x10FFFF` — checked via the same per-length minimum/maximum table
    /// `String(decoding:as:)` implicitly enforces. Does not reject anything else: this is a
    /// well-formedness check, not a semantic one (e.g. it has no opinion on which scalars
    /// are appropriate for text content).
    private static func isValidUTF8(_ bytes: [UInt8]) -> Bool {
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            let (length, minScalar, maxScalar): (Int, UInt32, UInt32)
            switch byte {
            case 0x00...0x7F:
                i += 1
                continue
            case 0xC2...0xDF:
                (length, minScalar, maxScalar) = (2, 0x80, 0x7FF)
            case 0xE0...0xEF:
                (length, minScalar, maxScalar) = (3, 0x800, 0xFFFF)
            case 0xF0...0xF4:
                (length, minScalar, maxScalar) = (4, 0x1_0000, 0x10_FFFF)
            default:
                // Continuation byte with no lead (0x80...0xBF), or a byte that is never a
                // valid lead (0xC0, 0xC1, 0xF5...0xFF).
                return false
            }
            guard i + length <= bytes.count else { return false }
            var scalar = UInt32(byte & (0xFF >> (length + 1)))
            for k in 1..<length {
                let cont = bytes[i + k]
                guard cont & 0b1100_0000 == 0b1000_0000 else { return false }
                scalar = (scalar << 6) | UInt32(cont & 0b0011_1111)
            }
            guard scalar >= minScalar && scalar <= maxScalar else { return false }
            guard !(scalar >= 0xD800 && scalar <= 0xDFFF) else { return false }
            i += length
        }
        return true
    }

    // MARK: - Fast path: leaf-local edit (M1.1b stage 1)

    /// The path-copy leaf-local edit path (M1.1b stage 1): when the whole edit — the
    /// removed range plus `bytes` — fits inside one leaf, rewrites that leaf directly via
    /// `SumTree.pathCopyEdit`, touching only the `O(h)` nodes on the path to it instead of
    /// falling back to `generalPathReplace`'s two `O(h)` `splitFragments` descents plus one
    /// `O(h)` `TreeBuilder` join (M1.1b stage 2 — see `SumTree.swift`'s file header; before
    /// that round this fallback was `O(B * h^2)`, not `O(h)`, which was this fast path's
    /// original reason to exist and still is: a constant number of `O(h)` walks is cheaper
    /// than one, just not by the same margin the old fallback made it look).
    /// Returns `true` if it performed the edit; `false` if it declined, in which case
    /// `self` is left byte-identical and the caller must fall back to the general path.
    /// `package`, not `private`: a test asserts this fast path is actually taken on a
    /// representative workload, so a silent regression back to the fallback shows up as a
    /// test failure rather than only as a timing regression.
    ///
    /// Declines (returns `false`, never traps) when: `bytes.count > 64`; the rope is empty;
    /// `range.lowerBound`/`range.upperBound` is not a scalar boundary; `range.upperBound`
    /// falls outside the leaf containing `range.lowerBound`'s byte span; or `bytes` is not
    /// well-formed UTF-8 (see `Rope.isValidUTF8`). The only preconditions are the
    /// range-bounds ones
    /// `replaceSubrange` already has (`range.lowerBound >= 0`, `range.upperBound <=
    /// utf8Count`) — a bounds violation still traps, matching the fallback path exactly.
    package mutating func tryLeafLocalReplace(_ range: Range<Int>, with bytes: [UInt8]) -> Bool {
        precondition(range.lowerBound >= 0 && range.upperBound <= utf8Count)
        guard bytes.count <= 64 else { return false }
        guard utf8Count > 0 else { return false }
        guard isScalarBoundary(range.lowerBound), isScalarBoundary(range.upperBound) else {
            return false
        }
        // A genuine no-op (nothing removed, nothing inserted): accept immediately, now that
        // both bounds are confirmed to be scalar boundaries, rather than re-walking and
        // re-packing the last leaf for no reason. An empty `bytes` with a *non-empty* range
        // is a delete, not a no-op, and must not take this path. This must come *after* the
        // boundary checks above: a "no-op" at a non-boundary offset (e.g. offset 1 inside a
        // 2-byte scalar) is not a real no-op, it is a programmer error, and must decline here
        // so the caller falls back to the general path, which `precondition`-traps on it
        // (see this file's header).
        if range.isEmpty && bytes.isEmpty { return true }
        guard Rope.isValidUTF8(bytes) else { return false }

        let lowerBound = range.lowerBound
        let upperBound = range.upperBound
        let total = utf8Count
        let predicate: (TextSummary) -> Bool =
            lowerBound < total
            ? { $0.utf8 > lowerBound }
            : { $0.utf8 >= total }

        guard
            let newTree = tree.pathCopyEdit(
                where: predicate,
                edit: { items, index, leafPrefix in
                    // Find the item containing `lowerBound` (guaranteed to be `index`, by
                    // `predicate`'s own convention — see `Rope.locate`'s doc comment for
                    // the identical `>` convention) and, walking forward from it, the item
                    // containing `upperBound`. Declines (returns `nil`) if that walk runs
                    // off the end of this leaf's items: the edit straddles a leaf boundary,
                    // which this fast path does not handle.
                    let leafStart = leafPrefix.utf8
                    var cum = leafStart
                    for k in 0..<index { cum += Int(items[k].count) }
                    let localLower = lowerBound - cum
                    guard localLower >= 0 && localLower <= Int(items[index].count) else {
                        return nil
                    }

                    var j = index
                    var itemEnd = cum + Int(items[index].count)
                    while itemEnd < upperBound {
                        j += 1
                        guard j < items.count else { return nil }
                        itemEnd += Int(items[j].count)
                    }
                    let jStart = itemEnd - Int(items[j].count)
                    let localUpper = upperBound - jStart
                    guard localUpper >= 0 && localUpper <= Int(items[j].count) else {
                        return nil
                    }

                    // Build the replacement bytes: the untouched prefix of the first
                    // touched chunk, the new bytes, and the untouched suffix of the last
                    // touched chunk — then repack with the same policy as a fresh build.
                    var replacement: [UInt8] = []
                    replacement.reserveCapacity(
                        localLower + bytes.count + (Int(items[j].count) - localUpper))
                    items[index].withUnsafeBytes {
                        replacement.append(contentsOf: $0[0..<localLower])
                    }
                    replacement.append(contentsOf: bytes)
                    items[j].withUnsafeBytes {
                        replacement.append(contentsOf: $0[localUpper...])
                    }

                    let newChunks = Rope.packChunks(replacement)
                    var newItems = items
                    newItems.replaceSubrange(index...j, with: newChunks)
                    guard !newChunks.isEmpty else {
                        // The whole replaced run vanished (e.g. deleting exactly one whole
                        // chunk's byte span): `index - 1` and `index` are now adjacent in
                        // `newItems` where they were not before, so try to coalesce them
                        // on the same terms as the two blocks below. Handle
                        // the removed run having been at the very start (no left neighbour)
                        // or the very end (no right neighbour) of the leaf.
                        if index > 0, index < newItems.count {
                            let preceding = newItems[index - 1]
                            let following = newItems[index]
                            if Int(preceding.count) + Int(following.count) <= 64 {
                                var combined: [UInt8] = []
                                combined.reserveCapacity(
                                    Int(preceding.count) + Int(following.count))
                                preceding.withUnsafeBytes {
                                    combined.append(contentsOf: $0)
                                }
                                following.withUnsafeBytes {
                                    combined.append(contentsOf: $0)
                                }
                                newItems.replaceSubrange(
                                    (index - 1)...index, with: [Chunk(bytes: combined)])
                            }
                        }
                        return newItems
                    }

                    // Coalescing: merge the new run's last chunk with the item following
                    // it, and its first chunk with the item preceding it, whenever the pair
                    // fits in 64 bytes together. **Unconditionally** — an earlier version
                    // also required the leaf to keep at least `branchingFactor` items
                    // afterward unless it was the whole tree. M1.1b stage 2 measured that
                    // guard and removed it: it is not a correctness defence (stage 1's
                    // mutation pass showed a relaxed guard genuinely takes a leaf from 6
                    // items to 5 and no test fails, because `pathCopyEditNode`'s underflow
                    // repair absorbs it), and dropping it improves fill at no measured cost
                    // — over 40,000 sustained fast-path edits, adjacent chunk pairs summing
                    // to <= 64 fell from 176 to 56 and mean fill rose from 45.5 to 47.0, with
                    // the single-insert benchmark moving in opposite directions at 1 MB and
                    // 10 MB inside a noise band, i.e. showing no cost rather than a gain. On
                    // the mixed randomised workload the picture is different and is recorded
                    // too: the Part D pair count is 25 either way, redistributed 25/0 to 19/6
                    // across the two bands rather than reduced. The fill gain is real on a
                    // fast-path-dominated workload and a wash on a mixed one.
                    let runStart = index
                    let runEnd = runStart + newChunks.count
                    if runEnd < newItems.count {
                        let last = newItems[runEnd - 1]
                        let following = newItems[runEnd]
                        if Int(last.count) + Int(following.count) <= 64 {
                            var combined: [UInt8] = []
                            combined.reserveCapacity(Int(last.count) + Int(following.count))
                            last.withUnsafeBytes { combined.append(contentsOf: $0) }
                            following.withUnsafeBytes { combined.append(contentsOf: $0) }
                            newItems.replaceSubrange(
                                (runEnd - 1)...runEnd, with: [Chunk(bytes: combined)])
                        }
                    }
                    if runStart > 0 {
                        let first = newItems[runStart]
                        let preceding = newItems[runStart - 1]
                        if Int(preceding.count) + Int(first.count) <= 64 {
                            var combined: [UInt8] = []
                            combined.reserveCapacity(Int(preceding.count) + Int(first.count))
                            preceding.withUnsafeBytes { combined.append(contentsOf: $0) }
                            first.withUnsafeBytes { combined.append(contentsOf: $0) }
                            newItems.replaceSubrange(
                                (runStart - 1)...runStart, with: [Chunk(bytes: combined)])
                        }
                    }
                    return newItems
                })
        else {
            return false
        }
        tree = newTree
        return true
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
        // Fast path first (M1.1b stage 1): only worth trying when `other` itself is small
        // enough to ever fit inside one leaf; `tryLeafLocalReplace` declines cheaply
        // (leaving `self` untouched) for every shape it cannot handle, so falling through
        // to the general path below on `false` is always correct, just slower.
        if other.utf8Count <= 64, tryLeafLocalReplace(byteRange, with: Array(other.bytes())) {
            return
        }
        generalPathReplace(byteRange, with: other)
    }

    /// Pushes `chunks` into `builder` in groups of at most `2B`, the bound `Fragment.items`
    /// carries in its doc comment: `chunks` here can be arbitrarily long (the untouched
    /// straddling remainders plus a small `other`'s own items, concatenated), and a single
    /// `Fragment.items` over more than `2B` of them would hand `TreeBuilder` a leaf-shaped
    /// argument its own contract does not allow — see `SumTree.swift`'s `Fragment` doc
    /// comment for why the bound exists at all.
    private static func pushChunks(
        _ chunks: ArraySlice<Chunk>, into builder: inout TreeBuilder<Chunk>
    ) {
        var remaining = chunks
        while !remaining.isEmpty {
            let end = remaining.index(
                remaining.startIndex, offsetBy: min(2 * branchingFactor, remaining.count))
            builder.push(.items(remaining[remaining.startIndex..<end]))
            remaining = remaining[end...]
        }
    }

    /// The general path's body (M1.1b stage 2), shared by `replaceSubrange(_:with:)` (once
    /// the fast path has declined) and `replaceSubrangeGeneralPathOnly` below, so the two
    /// can never diverge — see that function's doc comment for why divergence would be
    /// silent rather than a build error.
    ///
    /// Two `splitFragments` descents into the **original**, unmodified `tree` — one at
    /// `range.lowerBound`, one at `range.upperBound` — replace the six cursor walks
    /// (`splitTree`×2, each a `cut`, plus `concatMergingSeam`×2, each two more `cut`s) the
    /// old `splitTree`+`concatMergingSeam` implementation needed, with two. The straddling
    /// chunk each descent returns is sliced by hand exactly as `splitTree` slices one today;
    /// the untouched remainder of each becomes a `Fragment.items` pushed alongside the
    /// per-level groups the descent already collected, and the seam-merge policy (merge an
    /// adjacent pair when they fit in 64 bytes together) is applied once on each side of the
    /// inserted run via `mergeTrailingSeam`/`mergeLeadingSeam` before any of it is pushed
    /// into the one `TreeBuilder` that replaces both old `concat` calls.
    ///
    /// `other` is handled two ways, chosen by whether it is small enough to seam-merge at
    /// all: when `other.tree` is a single leaf (`height == 0`, `<= 2B` chunks — comfortably
    /// the common case, a `Chunk` alone holds up to 64 bytes), its items are flattened
    /// alongside the two straddling remainders and both seams are attempted normally. A
    /// taller `other` is pushed as a whole subtree (`push(subtree:)`, no flattening) with no
    /// seam merge attempted at either of its two ends, for the same reason
    /// `mergeTrailingSeam`/`mergeLeadingSeam` decline a boundary chunk buried inside a
    /// `Fragment.nodes` group: reaching `other`'s actual first/last chunk would mean walking
    /// into it, which is exactly the extra cursor work this rewrite exists to stop doing.
    ///
    /// This is a real, intentional narrowing from the old `concatMergingSeam` (which used
    /// `cut` and so found the true last/first chunk regardless of tree shape, on every call,
    /// including into `other`) — `checkTreeInvariants()` cannot observe it (a merge this
    /// declines still leaves a perfectly valid, just marginally less packed, tree) and
    /// `fragmentationGuard` does not either at its 24-byte floor (most of that test's edits
    /// are single-byte inserts the fast path takes, never reaching here at all; see this
    /// file's report for why this was not chased with an exact-shape test instead). A second
    /// narrowing, also not chased: the old implementation could chain two merges into one
    /// chunk when `other` was itself a single small chunk (its first merge's output became
    /// its second merge's input); this implementation applies the two seams independently
    /// except when the flattened middle run has exactly one chunk, where the same chaining
    /// still happens because both merges act on that one array slot in sequence.
    private mutating func generalPathReplace(_ range: Range<Int>, with other: Rope) {
        var prefixFragments: [Fragment<Chunk>] = []
        var discardedRight: [Fragment<Chunk>] = []
        let lowerFlip = splitFragments(
            tree.root, prefix: .identity, where: { $0.utf8 > range.lowerBound },
            left: &prefixFragments, right: &discardedRight)

        var discardedLeft: [Fragment<Chunk>] = []
        var suffixFragments: [Fragment<Chunk>] = []
        let upperFlip = splitFragments(
            tree.root, prefix: .identity, where: { $0.utf8 > range.upperBound },
            left: &discardedLeft, right: &suffixFragments)

        // The two `precondition`s below are the general path's scalar-boundary contract (see
        // this file's header): a non-boundary offset is a programmer error and traps rather
        // than silently truncating a scalar. They are restored here because M1.1b stage 2's
        // first version omitted them, and omitting them is **silent data corruption, not a
        // loud failure**: `removeSubrange(0..<1)` on `Rope("é" + String(repeating: "m",
        // count: 100))` stored a chunk beginning with the lone continuation byte `0xA9`,
        // decoding to U+FFFD, while `checkTreeInvariants()` passed — a chunk's cached summary
        // and its recomputed summary are both derived from the same corrupted bytes, so they
        // agree and the tree oracle cannot see it.
        //
        // **Nothing regression-tests these two lines.** A cold review checked, and every
        // randomised and differential test in `ropeTests.swift` draws its offsets from
        // `scalarBoundaries`, so none can present a non-boundary offset to this path;
        // asserting the trap itself needs an out-of-process crash harness, which this project
        // does not have yet (`PLAN.md`'s M1.1b stage 2 record carries this as a known gap,
        // with the repro above as its first case). Deleting either line leaves the suite
        // green. Do not treat their survival of a mutation run as evidence that they are
        // unnecessary.
        var leftPiece: Chunk?
        if let (chunk, itemPrefix) = lowerFlip {
            let localOffset = range.lowerBound - itemPrefix.utf8
            if localOffset > 0 {
                precondition(
                    Rope.isChunkLocalScalarBoundary(chunk, localOffset),
                    "byte offset \(range.lowerBound) is not a scalar boundary")
                var bytes: [UInt8] = []
                chunk.withUnsafeBytes { bytes = Array($0[0..<localOffset]) }
                leftPiece = Chunk(bytes: bytes)
            }
        }
        var rightPiece: Chunk?
        if let (chunk, itemPrefix) = upperFlip {
            let localOffset = range.upperBound - itemPrefix.utf8
            if localOffset < Int(chunk.count) {
                precondition(
                    Rope.isChunkLocalScalarBoundary(chunk, localOffset),
                    "byte offset \(range.upperBound) is not a scalar boundary")
                var bytes: [UInt8] = []
                chunk.withUnsafeBytes { bytes = Array($0[localOffset...]) }
                rightPiece = Chunk(bytes: bytes)
            }
        }

        var builder = TreeBuilder<Chunk>()

        if !other.tree.isEmpty, other.tree.height > 0 {
            // Large `other`: push its subtree directly (no flattening, no seam merge — see
            // this function's doc comment).
            for fragment in prefixFragments { builder.push(fragment) }
            if let leftPiece { builder.push(.items(ArraySlice([leftPiece]))) }
            builder.push(subtree: other.tree.root)
            if let rightPiece { builder.push(.items(ArraySlice([rightPiece]))) }
            for fragment in suffixFragments { builder.push(fragment) }
        } else {
            // `other` is empty or a single leaf: flatten it (at most `2B` chunks) alongside
            // the two straddling remainders and attempt both seams normally.
            var middle: [Chunk] = []
            if let leftPiece { middle.append(leftPiece) }
            middle.append(contentsOf: other.tree.items())
            if let rightPiece { middle.append(rightPiece) }

            if middle.isEmpty {
                // Nothing survives between the prefix and the suffix: the only seam is
                // directly between what remains of each.
                if let firstFragment = suffixFragments.first,
                    case .items(let slice) = firstFragment,
                    let head = slice.first,
                    let merged = Rope.mergeTrailingSeam(&prefixFragments, with: head)
                {
                    let remainder = slice.dropFirst()
                    if remainder.isEmpty {
                        suffixFragments.removeFirst()
                    } else {
                        suffixFragments[0] = .items(remainder)
                    }
                    prefixFragments.append(.items(ArraySlice([merged])))
                }
            } else {
                if let merged = Rope.mergeTrailingSeam(&prefixFragments, with: middle[0]) {
                    middle[0] = merged
                }
                let lastIndex = middle.count - 1
                if let merged = Rope.mergeLeadingSeam(&suffixFragments, with: middle[lastIndex]) {
                    middle[lastIndex] = merged
                }
            }

            for fragment in prefixFragments { builder.push(fragment) }
            if !middle.isEmpty { Rope.pushChunks(middle[...], into: &builder) }
            for fragment in suffixFragments { builder.push(fragment) }
        }

        tree = builder.finish()
    }

    /// Test-only: performs the same edit as `replaceSubrange(_:with:)` but always through
    /// the general `split`+`concat` path, never trying `tryLeafLocalReplace` first —
    /// something the production dispatcher cannot do for an input the fast path would
    /// accept (it always prefers the fast path when eligible). `internal`, not `package`:
    /// reached only via `@testable import Text` from `ropeTests.swift`'s differential
    /// test, which runs the *same* edit through both paths on separate copies to compare
    /// them directly. Forwards to `generalPathReplace` rather than duplicating its body, so
    /// a fix to the general path can never leave this copy stale (and the differential
    /// test comparing against it silently stale too).
    mutating func replaceSubrangeGeneralPathOnly(_ byteRange: Range<Int>, with other: Rope) {
        precondition(byteRange.lowerBound >= 0 && byteRange.upperBound <= utf8Count)
        generalPathReplace(byteRange, with: other)
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
        // Routed through `replaceSubrange` (an empty range at the very end), not a direct
        // call into `generalPathReplace`'s seam-merge logic, so this reaches
        // `tryLeafLocalReplace`'s fast path the same way `insert`/`removeSubrange` do,
        // instead of duplicating the dispatch.
        replaceSubrange(utf8Count..<utf8Count, with: other)
    }

    // MARK: - Extraction

    /// A lazy, allocation-free traversal of this rope's chunks, in order (M1.2 deliverable
    /// C, `SumTreeCursor`). Before this round, `chunks()` returned `tree.items()`, which
    /// flattens the whole tree into an `[Chunk]` before the caller ever sees the first one;
    /// `bytes()`/`toString()` below are built on the same cursor for the same reason.
    package func chunks() -> SumTreeCursor<Chunk> {
        tree.makeCursor()
    }

    package func bytes() -> some Sequence<UInt8> {
        var result: [UInt8] = []
        result.reserveCapacity(utf8Count)
        for chunk in tree.makeCursor() {
            chunk.withUnsafeBytes { result.append(contentsOf: $0) }
        }
        return result
    }

    package func toString() -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(utf8Count)
        for chunk in tree.makeCursor() {
            chunk.withUnsafeBytes { bytes.append(contentsOf: $0) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// **Test-only hook**, not `package`/`public`: an independent reference for a test to
    /// check the cursor against. `SumTree.items()` walks the tree with its own recursive
    /// `collect`, never touching `SumTreeCursor` — unlike `chunks()`/`bytes()` above, which
    /// (since M1.2) are both re-expressed on the cursor and so cannot serve as an
    /// independent oracle for it (a cursor traversal bug that skips or duplicates an item
    /// would corrupt all three identically, and a test comparing them would see agreement
    /// with nothing actually checked). `internal`, not `private`: reached only via
    /// `@testable import Text` from `conversionAndCursorTests.swift`'s
    /// `cursorAgreesWithItems`.
    func itemsViaTree() -> [Chunk] {
        tree.items()
    }

    /// A cursor over this rope's chunks, seekable by byte offset or by any `TextMetric` —
    /// exposed for a caller that wants to stream from an arbitrary starting point, or
    /// convert many offsets in increasing order without paying `convert`'s O(h) descent
    /// from the root each time (see `SumTreeCursor.seek`'s doc comment for the one
    /// optimisation this does not yet do). `convert` itself does not route through this —
    /// it is a single, stateless conversion, and `SumTree.find` is already O(h) and
    /// allocation-free on its own.
    package func makeCursor() -> SumTreeCursor<Chunk> {
        tree.makeCursor()
    }

    // MARK: - Equatable

    package static func == (lhs: Rope, rhs: Rope) -> Bool {
        guard lhs.summary == rhs.summary else { return false }
        return Array(lhs.bytes()) == Array(rhs.bytes())
    }
}

extension SumTreeCursor where Item == Chunk {
    /// Repositions a `Rope` cursor at the chunk containing `offset` in `metric`'s units, via
    /// `SumTreeCursor.seek` — the same descent `Rope.convert` does, kept resumable (see that
    /// method's doc comment for the from-root narrowing this inherits).
    ///
    /// **`.lines` needs the same off-by-one shift `Rope.convert`/`byteOffsetOfLineStart`
    /// apply and this used not to**: `.lines` counts a byte *value* (`"\n"`), not units
    /// consumed (see `Rope.convert`'s doc comment), so "the chunk where the running line
    /// count first exceeds `offset`" is the chunk holding line `offset`'s *own* content, one
    /// line short of "the start of line `offset`" — `convert`'s `.lines` special case
    /// searches for `offset - 1`, not `offset`, for exactly this reason. An earlier version
    /// of this function used `metric.count(in: $0) > offset` unconditionally for every
    /// metric, including `.lines`, and landed one line past `offset`; fixed here by applying
    /// the same shift `byteOffsetOfLineStart` does, so `seek(to:metric: .lines)` and
    /// `convert(offset:from: .utf8,to: .lines)`'s inverse agree. `line == 0` is a further
    /// special case, matching `byteOffsetOfLineStart(0)`'s own no-descent shortcut: shifting
    /// naively would search for `.lines`'s count exceeding `-1`, which is true already of
    /// `.identity` and would trip `seek`'s own precondition before ever descending. Line 0
    /// always starts at byte 0, in the first chunk, the same chunk any other metric's
    /// `offset == 0` seeks to — so this reuses that same "first chunk" predicate rather than
    /// a `.lines`-specific one.
    package mutating func seek(to offset: Int, metric: TextMetric) {
        if metric == .lines {
            if offset == 0 {
                seek(where: { $0.utf8 > 0 })
            } else {
                seek(where: { TextMetric.lines.count(in: $0) > offset - 1 })
            }
        } else {
            seek(where: { metric.count(in: $0) > offset })
        }
    }
}
