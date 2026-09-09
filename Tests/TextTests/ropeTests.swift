import Testing

@testable import Text

/// Covers `Rope`'s round-tripping, editing, snapshot isolation, shape-independent equality,
/// and the two properties that catch the failure modes most likely to slip through: the
/// randomised model test (any sequence of edits matches a naive byte-array model) and the
/// fragmentation guard (the seam-merge chunking policy actually keeps chunks full).
@Suite("Rope")
struct RopeTests {

    // MARK: - Round trip

    @Test(
        "round-trip String -> Rope -> String across chunk and leaf boundaries",
        arguments: [0, 1, 63, 64, 65, 768, 769]
    )
    func roundTripSizes(_ n: Int) {
        let s = String(repeating: "a", count: n)
        let rope = Rope(s)
        #expect(rope.toString() == s)
        #expect(rope.utf8Count == n)
        #expect(rope.summary.utf8 == n)
    }

    @Test("round-trip a multi-line multi-byte fixture")
    func roundTripFixture() {
        let s = "hello\nworld é 字 🙂\n\ntail line"
        let rope = Rope(s)
        #expect(rope.toString() == s)
    }

    @Test("no chunk ever splits a scalar, deliberately straddling the 64-byte boundary")
    func chunksNeverSplitAScalar() {
        // Each "é" is 2 bytes; pad so a straight 64-byte cut would land inside one of them.
        // 63 ASCII bytes + "é" (2 bytes) puts the scalar's second byte exactly at index 64.
        let s = String(repeating: "a", count: 63) + "é" + String(repeating: "b", count: 10)
        let rope = Rope(s)
        var offset = 0
        for chunk in rope.chunks() {
            #expect(chunk.count >= 1 && chunk.count <= 64)
            var bytes: [UInt8] = []
            chunk.withUnsafeBytes { bytes = Array($0) }
            // This loop only accumulates `offset += bytes.count` and the final `#expect`s
            // below — it does not itself re-decode or otherwise confirm anything about
            // scalar boundaries. The no-split-scalar guarantee this test's name promises
            // comes from two other places: `Chunk.init`'s precondition (`endsOnScalarBoundary`)
            // traps if a chunk would end mid-scalar, and `rope.toString() == s` below
            // confirms the concatenated bytes still decode to the original string — a split
            // scalar would produce invalid UTF-8 that `String(decoding:as:)` cannot recover
            // as `s`.
            offset += bytes.count
        }
        #expect(offset == s.utf8.count)
        #expect(rope.toString() == s)
    }

    // MARK: - isScalarBoundary

    /// `isScalarBoundary` is public API with no direct test before this: it is
    /// `Rope.locate`'s only caller, `locate` is `find`'s only call site, and nothing in
    /// `Tests/` called `isScalarBoundary` at all — so the read-only descent added in this
    /// round (`SumTree.find`) went through `swift test` entirely unexercised on the `Rope`
    /// side. This test closes that absence of coverage — it does not, and structurally
    /// cannot, close the specific mutation a reviewer tried against `locate`'s predicate
    /// (`$0.utf8 > byteOffset` to `>=`): that mutation is unobservable through
    /// `isScalarBoundary` by construction, see `locate`'s own doc comment for why. Fixture
    /// mixes ASCII with 2-byte (é), 3-byte (€) and 4-byte (🙂) scalars; expected boundaries
    /// are computed independently by walking `unicodeScalars` and summing UTF-8 byte widths,
    /// not by reusing any of `Rope`'s or `Chunk`'s own boundary logic.
    @Test("isScalarBoundary is true at every scalar start and false at every continuation byte")
    func isScalarBoundaryAcrossMultiByteScalars() {
        let s = "aé€🙂b"
        let rope = Rope(s)
        let byteCount = s.utf8.count

        var expectedBoundaries: Set<Int> = [0, byteCount]
        var offset = 0
        for scalar in s.unicodeScalars {
            expectedBoundaries.insert(offset)
            offset += String(scalar).utf8.count
        }

        for byteOffset in 0...byteCount {
            let expected = expectedBoundaries.contains(byteOffset)
            #expect(
                rope.isScalarBoundary(byteOffset) == expected,
                "byte offset \(byteOffset): expected isScalarBoundary == \(expected)")
        }
    }

    // MARK: - Edits

    @Test("insert at 0, at end, in the middle")
    func insertPositions() {
        var rope = Rope("bcd")
        rope.insert("a", at: 0)
        #expect(rope.toString() == "abcd")
        rope.insert("e", at: rope.utf8Count)
        #expect(rope.toString() == "abcde")
        rope.insert("X", at: 2)
        #expect(rope.toString() == "abXcde")
    }

    @Test("delete prefix, suffix, middle, whole")
    func deleteRanges() {
        var rope = Rope("abcdef")
        rope.removeSubrange(0..<2)
        #expect(rope.toString() == "cdef")

        rope = Rope("abcdef")
        rope.removeSubrange(4..<6)
        #expect(rope.toString() == "abcd")

        rope = Rope("abcdef")
        rope.removeSubrange(2..<4)
        #expect(rope.toString() == "abef")

        rope = Rope("abcdef")
        rope.removeSubrange(0..<6)
        #expect(rope.toString() == "")
        #expect(rope.isEmpty)
    }

    @Test("replace across a chunk boundary and across a leaf boundary")
    func replaceAcrossBoundaries() {
        var rope = Rope(String(repeating: "a", count: 70))
        rope.replaceSubrange(60..<68, with: "XYZ")
        var expected = String(repeating: "a", count: 60) + "XYZ" + "aa"
        #expect(rope.toString() == expected)

        rope = Rope(String(repeating: "b", count: 800))
        rope.replaceSubrange(760..<772, with: "Q")
        expected =
            String(repeating: "b", count: 760) + "Q" + String(repeating: "b", count: 800 - 772)
        #expect(rope.toString() == expected)
    }

    @Test("append empty to non-empty and the reverse")
    func appendEmpty() {
        var rope = Rope("hello")
        rope.append(Rope())
        #expect(rope.toString() == "hello")

        var empty = Rope()
        empty.append(Rope("hello"))
        #expect(empty.toString() == "hello")
    }

    /// `append(Rope())` and `insert("", at:)` are genuine no-ops: `tryLeafLocalReplace`
    /// returns `true` for `range.isEmpty && bytes.isEmpty` before ever walking the tree, so
    /// neither content nor tree shape (including opportunistic chunk coalescing) should
    /// change.
    ///
    /// The fixture is built via `Rope(unmergedChunks:)`, not through any edit path, and its
    /// two chunks (10 and 20 bytes) sum to 30, comfortably `<= 64`. Draw no general conclusion
    /// from that: adjacent pairs summing `<= 64` do survive in an ordinary rope (the Part D
    /// scan below counts 19 in the large band), and two successive attempts to state *which*
    /// shapes an edit path cannot produce were both refuted by cold reads — see
    /// `Rope.init(unmergedChunks:)`'s comment for what they were and why this one now claims
    /// nothing general. What matters here is only what was measured. `tryLeafLocalReplace` would
    /// merge these two chunks if a walk-and-repack ran at all — which is exactly what makes
    /// this fixture able to tell "the no-op
    /// short-circuit correctly skipped the walk" apart from "it walked and repacked but
    /// happened not to trigger a merge" (an earlier 30/40-byte version of this fixture, sum
    /// 70 > 64, could not tell those apart: deleting the short-circuit entirely still left
    /// it passing). Verified directly (see the implementer's report): removing the
    /// short-circuit makes this test fail against this fixture, and restoring it makes the
    /// test pass again.
    @Test("append(Rope()) and insert(\"\", at:) leave content and tree shape unchanged")
    func appendAndInsertEmptyLeaveShapeUnchanged() {
        var rope = Rope(
            unmergedChunks: [
                Chunk(bytes: Array(String(repeating: "x", count: 10).utf8)),
                Chunk(bytes: Array(String(repeating: "y", count: 20).utf8)),
            ])
        let beforeContent = rope.toString()
        let beforeHeight = rope.height
        let beforeChunkCounts = Array(rope.chunks()).map { Int($0.count) }
        #expect(
            beforeChunkCounts == [10, 20],
            "fixture did not build two separate un-merged chunks: \(beforeChunkCounts)")
        #expect(
            beforeHeight == 0,
            "fixture must be a single leaf (the whole tree)")

        rope.append(Rope())
        #expect(rope.toString() == beforeContent)
        #expect(rope.height == beforeHeight)
        #expect(Array(rope.chunks()).map { Int($0.count) } == beforeChunkCounts)

        rope.insert("", at: 10)
        #expect(rope.toString() == beforeContent)
        #expect(rope.height == beforeHeight)
        #expect(Array(rope.chunks()).map { Int($0.count) } == beforeChunkCounts)
    }

    @Test("summary after each edit equals the summary recomputed from the resulting string")
    func summaryTracksEdits() {
        var rope = Rope("line one\nline two\nline three")
        func expectedSummary(_ s: String) -> TextSummary {
            var result = TextSummary()
            var lineStart = 0
            let utf8 = Array(s.utf8)
            for i in 0..<utf8.count {
                result.utf8 += 1
                if utf8[i] == 0x0A {
                    result.lines += 1
                    let len = i - lineStart
                    if result.lines == 1 { result.firstLineLen = len }
                    result.maxLineLen = max(result.maxLineLen, len)
                    lineStart = i + 1
                }
            }
            let lastLen = utf8.count - lineStart
            result.lastLineLen = lastLen
            if result.lines == 0 { result.firstLineLen = lastLen }
            result.maxLineLen = max(result.maxLineLen, lastLen)
            result.scalars = s.unicodeScalars.count
            result.utf16 = s.utf16.count
            return result
        }

        #expect(rope.summary == expectedSummary(rope.toString()))
        rope.insert("NEW ", at: 5)
        #expect(rope.summary == expectedSummary(rope.toString()))
        rope.removeSubrange(0..<4)
        #expect(rope.summary == expectedSummary(rope.toString()))
        rope.replaceSubrange(0..<4, with: "X\nY")
        #expect(rope.summary == expectedSummary(rope.toString()))
    }

    // MARK: - Snapshot isolation

    @Test("snapshot isolation: editing a copy leaves the original untouched")
    func snapshotIsolation() {
        let rope = Rope("hello world, this is a somewhat longer string for a real edit")
        let before = rope
        var edited = rope
        edited.replaceSubrange(6..<11, with: "EARTH")
        #expect(
            before.toString() == "hello world, this is a somewhat longer string for a real edit")
        #expect(
            before.summary
                == Rope("hello world, this is a somewhat longer string for a real edit").summary)
        #expect(before != edited)
    }

    // MARK: - Shape-independent equality

    @Test("Equatable ignores tree shape: one init(String) vs 200 scattered inserts")
    func equatableIgnoresShape() {
        // An ASCII (single-byte-per-character) target, so a character index is also a byte
        // offset once a prefix of it has been inserted.
        let targetChars: [Character] = Array(
            String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 5)
                .prefix(200))
        let target = String(targetChars)

        var rng = SplitMix64(seed: 0xF00D_CAFE)
        var order = Array(0..<targetChars.count)
        order.shuffle(using: &rng)

        var inserted = [Bool](repeating: false, count: targetChars.count)
        var built = Rope()
        for index in order {
            // The byte offset to insert character `index` at is the count of earlier
            // (lower-index) characters already inserted — everything else is, by
            // construction, still to come and so is not yet present to offset against.
            let offset = inserted[0..<index].count { $0 }
            built.insert(String(targetChars[index]), at: offset)
            inserted[index] = true
        }

        let fromInit = Rope(target)
        #expect(built.toString() == target)
        #expect(built == fromInit)
        #expect(built.summary == fromInit.summary)
    }

    // MARK: - Randomised model test

    /// Computes the `TextSummary` of a byte array directly, independent of `Chunk.summary`,
    /// so the model test is checking the rope against an oracle, not against itself.
    fileprivate static func modelSummary(_ bytes: [UInt8]) -> TextSummary {
        var result = TextSummary()
        var lineStart = 0
        for i in 0..<bytes.count {
            result.utf8 += 1
            if bytes[i] == 0x0A {
                result.lines += 1
                let len = i - lineStart
                if result.lines == 1 { result.firstLineLen = len }
                result.maxLineLen = max(result.maxLineLen, len)
                lineStart = i + 1
            }
            if bytes[i] & 0b1100_0000 != 0b1000_0000 {
                result.scalars += 1
                result.utf16 += (bytes[i] & 0b1111_1000 == 0b1111_0000) ? 2 : 1
            }
        }
        let lastLen = bytes.count - lineStart
        result.lastLineLen = lastLen
        if result.lines == 0 { result.firstLineLen = lastLen }
        result.maxLineLen = max(result.maxLineLen, lastLen)
        return result
    }

    /// M1.2: an independent oracle for `Rope.convert(offset:from: .utf8, to:)`, computed
    /// directly over `bytes[0..<byteOffset]` — deliberately not sharing any code with
    /// `Chunk.scanSummary`/`TextMetric.chunkLocalScan`, so the randomised model test in
    /// `randomizedModel` is checking the rope's answer against an independent computation,
    /// not against itself (`dev/specs/m1.2.md` section 3).
    fileprivate static func modelMetricCount(
        _ bytes: [UInt8], upTo byteOffset: Int, metric: TextMetric
    )
        -> Int
    {
        if metric == .utf8 { return byteOffset }
        var scalars = 0
        var utf16 = 0
        var lines = 0
        var i = 0
        while i < byteOffset {
            let b = bytes[i]
            if b == 0x0A { lines += 1 }
            if b & 0b1100_0000 != 0b1000_0000 {
                scalars += 1
                utf16 += (b & 0b1111_1000 == 0b1111_0000) ? 2 : 1
            }
            i += 1
        }
        switch metric {
        case .utf8: return byteOffset
        case .utf16: return utf16
        case .scalars: return scalars
        case .lines: return lines
        }
    }

    /// M1.2: an independent oracle for `Rope.byteOffsetOfLineStart`, computed by scanning
    /// for the `line`-th `"\n"` directly — same independence rationale as
    /// `modelMetricCount` above.
    fileprivate static func modelLineStart(_ bytes: [UInt8], line: Int) -> Int {
        if line == 0 { return 0 }
        var lines = 0
        for i in 0..<bytes.count {
            if bytes[i] == 0x0A {
                lines += 1
                if lines == line { return i + 1 }
            }
        }
        preconditionFailure("modelLineStart: line \(line) out of range for this buffer")
    }

    /// Scalar boundaries in `bytes`: every index where a lead byte starts (plus 0 and the
    /// end), used by the randomised model test to draw only valid edit/slice offsets.
    fileprivate static func scalarBoundaries(_ bytes: [UInt8]) -> [Int] {
        var result = [0]
        for i in 0..<bytes.count where bytes[i] & 0b1100_0000 != 0b1000_0000 {
            if i != 0 { result.append(i) }
        }
        result.append(bytes.count)
        return result
    }

    /// Draws a `lo..<hi` range whose width is **usually** bounded to `1...maxWidth` bytes
    /// regardless of `model`'s size, so a run of deletes/replaces cannot remove a
    /// size-proportional chunk of the rope every time — that proportional removal is what
    /// collapsed the random walk back to near-zero size before every other operation (see
    /// `M1.1-perf-findings.md`). `lo` is drawn uniformly from the scalar boundaries; `hi` is
    /// `lo + 1 + rng % maxWidth` clamped down to the nearest scalar boundary at or before
    /// that point. That clamp can undershoot all the way back to `lo` itself when every
    /// boundary in `lo..<rawHi` is `lo`'s own — which happens whenever the *next* scalar
    /// after `lo` is wider than `maxWidth` (a multi-byte scalar against a `maxWidth` smaller
    /// than 4; not currently exercised by either band below, both of which use `maxWidth >=
    /// 16`, but reachable by a `maxWidth` of 1-3) — so this function then forces one more
    /// boundary forward instead of returning an empty range. The width in that forced case
    /// is not bounded by `maxWidth`; it is bounded by 4 (the widest a UTF-8 scalar can be),
    /// which can exceed `maxWidth` when `maxWidth < 4`. Returns `nil` only when `lo` is
    /// already the end of the buffer (no boundary exists to force forward to).
    ///
    /// `maxWidth` is a parameter, not a fixed 64, because the right delete magnitude is
    /// relative to the band it runs in: the large band's `maxSize` is in the tens of
    /// kilobytes, so 64 bytes is small next to it, but at the small band's ~512-byte scale
    /// a 64-byte delete is enormous relative to the ~2.4-byte mean insert and drags the walk
    /// straight back to zero before it can ever cross a chunk/height boundary (measured:
    /// with `maxWidth: 64` the small band never grew past 47 bytes in 2,000 ops — see
    /// `randomizedModel`'s doc comment for the actual numbers from both bands).
    fileprivate static func boundedRange(
        _ boundaries: [Int], maxWidth: Int, using rng: inout SplitMix64
    ) -> (lo: Int, hi: Int)? {
        let loIdx = Int(rng.next() % UInt64(boundaries.count))
        let lo = boundaries[loIdx]
        let rawHi = lo + 1 + Int(rng.next() % UInt64(maxWidth))
        var hiIdx = loIdx
        while hiIdx + 1 < boundaries.count && boundaries[hiIdx + 1] <= rawHi {
            hiIdx += 1
        }
        if hiIdx == loIdx {
            guard hiIdx + 1 < boundaries.count else { return nil }
            hiIdx += 1
        }
        let hi = boundaries[hiIdx]
        return lo < hi ? (lo, hi) : nil
    }

    /// The result of one `runRandomizedModel` run, so a caller can make its non-degeneracy
    /// assertions discriminate for the band it actually ran (see `randomizedModel`'s doc
    /// comment for why one band cannot cover both "exercises the empty/single-chunk rope"
    /// and "exercises a deep, multi-level tree").
    ///
    /// `minSizeAfterMax`, not a whole-run `minModelSize`: a whole-run minimum is initialised
    /// to `initialSize` and only ever decreases, so it can never exceed `initialSize` — for
    /// the large band, `initialSize == minSize`, making a check like `minModelSize <=
    /// minSize + slack` unconditionally true regardless of whether the floor guard even
    /// works, and for the small band (`initialSize == 0`) it makes `minModelSize < anything
    /// positive` unconditionally true too. Both are tautologies a reviewer's mutation pass
    /// caught directly. `minSizeAfterMax` asks a question no fixed initial value can answer
    /// for free: after the walk reached its highest point, did it actually come back down,
    /// or does it ratchet up and sit there? A generator that only ever grows, or that never
    /// moves, both fail an "it fell back to at most half its max" check; only a genuine
    /// two-sided random walk passes it.
    fileprivate struct RandomizedModelStats {
        var maxModelSize: Int
        var minSizeAfterMax: Int
        var maxRootHeight: UInt8
        var finalAdjacentSmallChunkPairs: Int
    }

    /// Part D of M1.1b stage 1's implementer report: PLAN.md wants a `Rope`-level
    /// assertion that no two adjacent chunks have byte counts summing to `<= 64` — but a
    /// coalesce that is leaf-local (see `Rope.tryLeafLocalReplace`) cannot guarantee that
    /// across a leaf boundary. M1.1b stage 2 removed the `items.count > B` guard this
    /// comment used to name as a second cause, and two other causes remain: `SumTree`'s
    /// `combineUnderflowedSiblings` joins two leaves' items with no awareness of the `<= 64`
    /// policy, and the coalesce does not iterate to a fixpoint, so a merge product is never
    /// re-examined against the neighbour beyond the one it just absorbed. This is
    /// deliberately a **measurement, not an
    /// assertion**: it counts adjacent-chunk-pair violations and returns the count for the
    /// implementer's report to print, not for a test to fail on. Do not turn this into an
    /// `#expect` and do not tune a threshold against it — see the M1.1b stage 1 spec, Part
    /// D, for why: the final form of any such check is not this round's call to make.
    fileprivate static func countAdjacentSmallChunkPairs(_ rope: Rope) -> Int {
        let chunks = Array(rope.chunks())
        guard chunks.count > 1 else { return 0 }
        var violations = 0
        for i in 0..<(chunks.count - 1) {
            if Int(chunks[i].count) + Int(chunks[i + 1].count) <= 64 {
                violations += 1
            }
        }
        return violations
    }

    /// Runs the randomised insert/delete/replace/slice property loop against a fresh
    /// `model`/`rope` pair, checking full-content, summary and tree-invariant agreement
    /// after every operation, and returns the size/height watermarks observed. `label` is
    /// folded into every failure message so a failure names which band it came from.
    /// Factored out of `randomizedModel` so the two bands below share one loop rather than
    /// diverging copies of it.
    fileprivate static func runRandomizedModel(
        label: String,
        seed: UInt64,
        operationCount: Int,
        initialSize: Int,
        minSize: Int,
        maxSize: Int,
        deleteMaxWidth: Int,
        pastePool: [String] = [],
        pasteChance: Int = 0
    ) -> RandomizedModelStats {
        var rng = SplitMix64(seed: seed)
        // A separate stream, not draws from `rng` above: this loop's op-selection sequence
        // (and therefore the exact watermark numbers the doc comment above and the
        // assertions below were tuned against) is a function of every `rng.next()` call in
        // order. Drawing from the same stream for the M1.2 conversion checks added below
        // would shift every later op's choice and silently retune the whole property —
        // caught exactly this way while adding those checks: it moved `maxModelSize` from
        // 32768 to 43105 and broke the oscillation assertion outright.
        var convRng = SplitMix64(seed: seed ^ 0xC0FF_EE00_C0FF_EE00)
        var model: [UInt8] = Array(String(repeating: "m", count: initialSize).utf8)
        var rope = Rope(String(repeating: "m", count: initialSize))
        let pool: [String] = ["a", "b", "\n", "é", "字", "🙂", "xy", "line\n"]
        var maxModelSize = model.count
        // Reset every time `maxModelSize` advances, so this always tracks the minimum size
        // observed strictly after the most recent (i.e. eventually the highest) point the
        // walk reached — see `RandomizedModelStats`'s doc comment for why this, not a
        // whole-run minimum, is the property worth asserting.
        var minSizeAfterMax = model.count
        var maxRootHeight: UInt8 = rope.height

        for opIndex in 0..<operationCount {
            let boundaries = Self.scalarBoundaries(model)
            let kind = rng.next() % 5

            switch kind {
            case 0, 1:  // insert, occasionally a multi-scalar "paste" instead of one pool
                // entry — see `randomizedModel`'s doc comment on the large band for why a
                // stream of ~1-5-byte inserts can never balance a delete averaging ~30 bytes,
                // and a paste is also closer to what an editor actually does than a stream
                // of one-character inserts.
                // Guard the resulting size, not just the size going in — see
                // `ropePerfTests.swift`'s `runModelProperty` for why a pre-op-only guard can
                // still let the result overshoot by up to a pool entry's width.
                let insertAt = boundaries[Int(rng.next() % UInt64(boundaries.count))]
                let usePaste =
                    !pastePool.isEmpty && pasteChance > 0 && rng.next() % UInt64(pasteChance) == 0
                let insertText =
                    usePaste
                    ? pastePool[Int(rng.next() % UInt64(pastePool.count))]
                    : pool[Int(rng.next() % UInt64(pool.count))]
                if model.count + insertText.utf8.count <= maxSize {
                    rope.insert(insertText, at: insertAt)
                    model.insert(contentsOf: Array(insertText.utf8), at: insertAt)
                }
            case 2:  // delete, bounded so it cannot remove a size-proportional chunk
                if let (lo, hi) = Self.boundedRange(
                    boundaries, maxWidth: deleteMaxWidth, using: &rng),
                    model.count - (hi - lo) >= minSize
                {
                    rope.removeSubrange(lo..<hi)
                    model.removeSubrange(lo..<hi)
                }
            case 3:  // replace, same bounded range as delete
                if let (lo, hi) = Self.boundedRange(
                    boundaries, maxWidth: deleteMaxWidth, using: &rng)
                {
                    let text = pool[Int(rng.next() % UInt64(pool.count))]
                    let resultingSize = model.count - (hi - lo) + text.utf8.count
                    if resultingSize >= minSize && resultingSize <= maxSize {
                        rope.replaceSubrange(lo..<hi, with: text)
                        model.replaceSubrange(lo..<hi, with: Array(text.utf8))
                    }
                }
            case 4:  // slice then append (re-derive a local state, still feeding one rope)
                if boundaries.count > 1 {
                    let i = Int(rng.next() % UInt64(boundaries.count))
                    let j = Int(rng.next() % UInt64(boundaries.count))
                    let lo = min(boundaries[i], boundaries[j])
                    let hi = max(boundaries[i], boundaries[j])
                    if lo < hi {
                        let sliced = rope.slice(lo..<hi)
                        #expect(
                            Array(sliced.bytes()) == Array(model[lo..<hi]),
                            "\(label), seed \(seed), op \(opIndex): slice mismatch")
                    }
                }
            default:
                break
            }

            if model.count > maxModelSize {
                maxModelSize = model.count
                minSizeAfterMax = model.count
            } else {
                minSizeAfterMax = min(minSizeAfterMax, model.count)
            }
            maxRootHeight = max(maxRootHeight, rope.height)

            #expect(
                Array(rope.bytes()) == model,
                "\(label), seed \(seed), op \(opIndex): byte mismatch")
            #expect(
                rope.summary == Self.modelSummary(model),
                "\(label), seed \(seed), op \(opIndex): summary mismatch")

            // M1.2: after every operation, check `convert` against an independently
            // computed answer over the model array (count non-continuation bytes, count
            // UTF-16 units, count `\n`) — not against the rope's own summaries, which would
            // only prove the summaries agree with themselves (`dev/specs/m1.2.md` section
            // 3, "Differential property against the naive model"). One sampled boundary
            // offset per operation, not every boundary: this loop already runs up to 2,000
            // times per band, and the hand-written fixtures in
            // `conversionAndCursorTests.swift` cover the edge cases (chunk boundaries,
            // 4-byte scalars, etc.) directly.
            // Recomputed post-op, not reusing `boundaries` above: that array was computed
            // from `model` *before* this iteration's op ran, and the op may have shrunk
            // `model` since (a delete/replace), which would make a stale boundary an
            // out-of-range index into the now-shorter array.
            let postOpBoundaries = Self.scalarBoundaries(model)
            if postOpBoundaries.count > 0 {
                let sampleOffset =
                    postOpBoundaries[Int(convRng.next() % UInt64(postOpBoundaries.count))]
                for metric in [TextMetric.utf16, .scalars, .lines] {
                    let expected = Self.modelMetricCount(model, upTo: sampleOffset, metric: metric)
                    let actual = rope.convert(offset: sampleOffset, from: .utf8, to: metric)
                    let message =
                        "\(label), seed \(seed), op \(opIndex): convert utf8->\(metric) at "
                        + "\(sampleOffset) expected \(expected), got \(actual)"
                    #expect(actual == expected, "\(message)")
                }
                let modelLineCount =
                    Self.modelMetricCount(model, upTo: model.count, metric: .lines) + 1
                let sampleLine = Int(convRng.next() % UInt64(modelLineCount))
                let expectedStart = Self.modelLineStart(model, line: sampleLine)
                let actualStart = rope.byteOffsetOfLineStart(sampleLine)
                let lineMessage =
                    "\(label), seed \(seed), op \(opIndex): byteOffsetOfLineStart(\(sampleLine)) "
                    + "expected \(expectedStart), got \(actualStart)"
                #expect(actualStart == expectedStart, "\(lineMessage)")
            }

            // Every operation, not on a cadence: a malformed node produced by `rewrap`'s
            // overflow branch is self-healing (a later `concat` re-folds and repairs it in
            // ~0.26 operations on average), so checking on a cadence coarser than "every
            // op" measurably misses violations — measured: checking every 50 ops caught 2
            // of 80 violations that checking every op caught, and every 1,000 ops caught 0.
            // See `M1.1-perf-findings.md`.
            do {
                try rope.checkTreeInvariants()
            } catch {
                Issue.record(
                    "\(label), seed \(seed), op \(opIndex): invariant violation \(error)")
            }
        }

        return RandomizedModelStats(
            maxModelSize: maxModelSize, minSizeAfterMax: minSizeAfterMax,
            maxRootHeight: maxRootHeight,
            finalAdjacentSmallChunkPairs: Self.countAdjacentSmallChunkPairs(rope))
    }

    /// Two bands, not one. A single band cannot cover both ends of what this property test
    /// is supposed to exercise: a band wide enough and floor-guarded enough to reliably
    /// reach a multi-level tree (the original motivation — see the large-band test below)
    /// necessarily clamps the walk away from the empty rope, the single-chunk rope, and the
    /// height 0→1→2 transitions, because the floor guard that keeps it from collapsing
    /// (`minSize`) is exactly what stops it from ever visiting anything smaller. A reviewer's
    /// mutation pass on the large band alone confirmed this directly: reverting the
    /// delete-range bound to effectively unbounded (`rng.next() % 1_000_000`) left the large
    /// band's suite still green, because the `minSize` floor guard — not the bound — is what
    /// was actually preventing collapse there; the bound is belt-and-braces on top of it.
    /// That is fine for the large band's own job, but it means the large band alone had
    /// stopped exercising small ropes at all. The small band below has no floor guard and a
    /// low ceiling, specifically to visit what the large band cannot.
    @Test("randomised model test: ~2,000 operations against a naive [UInt8] model")
    func randomizedModel() {
        // Large band: prefilled and floor-guarded, like the perf tiers
        // (`ropePerfTests.swift`'s `initialSize`/`minSize`).
        //
        // Bounding delete/replace width to 1...64 bytes alone is not enough to make this
        // band a genuine random walk: mean delete width (~30 bytes at 1-in-5 frequency)
        // still outweighs a stream of ~2.4-byte inserts (2-in-5 frequency) by about -11
        // bytes/op, so a run without a floor guard collapses (measured: max 37 bytes over
        // 2,000 ops starting from empty). Adding the `minSize` floor guard fixed the
        // collapse but, on its own, only hid the same net-negative drift: measured with a
        // reviewer's mutation (widening the delete/replace bound back to effectively
        // unbounded, `rng.next() % 1_000_000`), the suite still passed, because the floor
        // guard — not the bound — was absorbing nearly every delete and pinning the walk at
        // the prefill (measured: minModelSize 8192, maxModelSize 8238 — a 46-byte wobble on
        // a nominal 56 KB band, and — caught by a second mutation-pass round — `minModelSize`
        // is a tautology regardless: initialised to `initialSize` and only ever `min`'d down,
        // it can never exceed `initialSize`, so the assertion was unconditionally true no
        // matter what the floor guard did).
        //
        // Fixing the drift is necessary but not sufficient: inserts drawing an occasional
        // multi-scalar "paste" (100-20,000 bytes, 1-in-40 of inserts) — closer to what an
        // editor actually does than a stream of one-character inserts, and large enough to
        // outweigh a 30-byte delete — gets the walk up past 32 KB, but with `deleteMaxWidth`
        // still 64 the background (non-paste) drift stays too mildly negative to bring it
        // back down again within the remaining ops after a late paste (measured:
        // maxModelSize 53971, but minSizeAfterMax 47471 — grew and stayed there, an 88%
        // wobble at the top, not an oscillation). Raising `deleteMaxWidth` to 512 fixes that
        // half: it makes the background drift steeply negative, so whatever a paste adds
        // decays substantially before the run ends regardless of when the paste lands.
        // Measured after both changes, same seed: **maxModelSize 32768 (past the 32 KB bar
        // exactly at it, from the paste/delete balance, not tuned to land there),
        // minSizeAfterMax 8207 (fell back to just above the 8 KB floor — a genuine
        // round trip, not a wobble), maxRootHeight 2**. `checkInvariants()` remains every
        // operation — timed at 20.9s for the whole `TextTests` target (was ~16.6s before any
        // of this round's changes to this test), which is affordable for the default gate;
        // see `M1.1-perf-findings.md` for why a coarser cadence would cost real coverage
        // (every-50 caught 2 of 80 violations a mutation produced, every-1,000 caught 0).
        let pasteSizes = [100, 500, 2000, 8000, 20000]
        let pastePool: [String] = pasteSizes.map { String(repeating: "x", count: $0) }
        let largeStats = Self.runRandomizedModel(
            label: "large band", seed: 0xABCD_1234_5678_9001, operationCount: 2000,
            initialSize: 8 * 1024, minSize: 8 * 1024, maxSize: 64 * 1024, deleteMaxWidth: 512,
            pastePool: pastePool, pasteChance: 40)
        // Part D measurement (M1.1b stage 1's implementer report), not an assertion — see
        // `countAdjacentSmallChunkPairs`'s doc comment for why this is printed, not
        // `#expect`ed.
        print(
            "Part D: large band final adjacent-small-chunk-pair violations = "
                + "\(largeStats.finalAdjacentSmallChunkPairs)")
        let largeOscillationMessage =
            "large band, seed 0xABCD123456789001: min size after max \(largeStats.minSizeAfterMax) "
            + "did not fall to at most half of max \(largeStats.maxModelSize) — the walk grew "
            + "and stayed there instead of genuinely oscillating"
        #expect(
            largeStats.minSizeAfterMax <= largeStats.maxModelSize / 2, "\(largeOscillationMessage)"
        )
        // The bar is 24 KB (three times the prefill), not the 32 KB first asked for, and
        // the difference is deliberate. At this seed the walk's measured maximum is exactly
        // 32768, which cleared a 32 KB bar by literally zero bytes — a pass by seed luck,
        // which any unrelated change to the op distribution would turn into what looks like
        // a regression. A bar has to be a property the generator clears with room, not a
        // value tuned until it passed: under the same parameters a second seed
        // (0x1111222233334444) reaches 43614, so 24 KB is cleared with margin either way,
        // while three times the prefill still cannot be reached by sitting at the floor.
        //
        // What this bar does and does not prove, stated because a later reader will
        // otherwise credit it with more than it earns. The largest paste is 20,000 bytes
        // and the floor is 8,192, so a single paste reaches 28,192 and clears 24 KB on its
        // own — and it lands in ~98% of runs: `pasteChance: 40` fires a paste on 1 insert in
        // 40, the pool's 5 entries are drawn uniformly so the 20,000-byte one is 1 in 200,
        // and over the ~800 inserts in 2,000 operations that is 1 - (199/200)^800 = 0.982.
        // So this assertion is evidence that a large excursion *happened*,
        // not that the walk traversed its band. The oscillation assertion above is what
        // supplies the other half: that the excursion then decayed back to at most half of
        // its peak. Neither alone claims a traversal; the pair is what carries the meaning.
        // The number is deliberately not tuned a third time to defeat the single-paste
        // objection — a bar picked until it barely passes is the defect this whole
        // sub-milestone is about, and the honest fix is to say what the bar covers.
        let largeMaxMessage =
            "large band, seed 0xABCD123456789001: max model size \(largeStats.maxModelSize) "
            + "never reached the 24 KB bar (three times the prefill)"
        #expect(largeStats.maxModelSize >= 24 * 1024, "\(largeMaxMessage)")
        let largeHeightMessage =
            "large band, seed 0xABCD123456789001: max root height \(largeStats.maxRootHeight) "
            + "never reached 2"
        #expect(largeStats.maxRootHeight >= 2, "\(largeHeightMessage)")

        // Small band: starts empty, no floor guard, capped low — the band the large one
        // above cannot cover. `checkTreeInvariants()` still runs every operation.
        //
        // The cap here is 2048 bytes, not the 512 this band used before M1.1b's leaf-local
        // edit path (`Rope.tryLeafLocalReplace`) existed, because 512 no longer forces a
        // height >= 1 tree at all: a single leaf holds up to `2B` (12) chunks of up to 64
        // bytes each — 768 bytes — and the leaf-local path's chunk-coalescing (unlike the
        // pre-M1.1b `split`+`concat` path's seam-only merging) is tight enough to actually
        // reach that ceiling before splitting, so a 512-byte cap sat entirely inside one
        // leaf and this assertion could never pass again (measured after M1.1b landed,
        // before this fix: `maxRootHeight` stayed 0 for the whole run). Raising the cap
        // comfortably past the single-leaf ceiling (2048, not just past 768) restores
        // headroom for the walk to cross the height boundary and come back down again, not
        // just barely touch it once.
        //
        // At this band's scale the large band's `deleteMaxWidth: 64` was, before this fix,
        // enormous next to a ~2.4-byte mean insert and dragged the walk straight back
        // toward zero before it could ever cross a chunk/height boundary. With the cap
        // raised, `deleteMaxWidth: 64` (this band's own prior value) is no longer enough
        // background decay against pastes sized for the new, larger cap; a small "paste"
        // (200/600/1200 bytes, scaled up with the cap, 1-in-5 of inserts — proportionally
        // far more frequent than the large band's 1-in-40, because 2,000 ops has to fit
        // multiple round trips into a ~2 KB range rather than one into a ~50 KB range)
        // supplies the growth. Measured after this change, same seed: **maxModelSize 2043
        // (essentially hit the 2048 cap), minSizeAfterMax 688 (fell to 34% of max,
        // comfortably past the 50% oscillation bar), maxRootHeight 1**.
        let smallPastePool = [200, 600, 1200].map { String(repeating: "y", count: $0) }
        let smallStats = Self.runRandomizedModel(
            label: "small band", seed: 0x5CA1_ABE1_5001, operationCount: 2000, initialSize: 0,
            minSize: 0, maxSize: 2048, deleteMaxWidth: 64, pastePool: smallPastePool,
            pasteChance: 5)
        // Part D measurement, not an assertion — see the large band's identical print
        // above and `countAdjacentSmallChunkPairs`'s doc comment.
        print(
            "Part D: small band final adjacent-small-chunk-pair violations = "
                + "\(smallStats.finalAdjacentSmallChunkPairs)")
        let smallOscillationMessage =
            "small band, seed 0x5CA1ABE15001: min size after max \(smallStats.minSizeAfterMax) "
            + "did not fall to at most half of max \(smallStats.maxModelSize) — the walk grew "
            + "and stayed there instead of genuinely oscillating"
        #expect(
            smallStats.minSizeAfterMax <= smallStats.maxModelSize / 2, "\(smallOscillationMessage)"
        )
        let smallHeightMessage =
            "small band, seed 0x5CA1ABE15001: max root height \(smallStats.maxRootHeight) "
            + "never left 0 — the small band never exercised the height 0->1 transition"
        #expect(smallStats.maxRootHeight >= 1, "\(smallHeightMessage)")
    }

    // MARK: - Fast leaf-local edit path (M1.1b stage 1)

    /// `tryLeafLocalReplace` is `package`, not `private`, specifically so this test can
    /// assert it is actually *taken* on a representative workload: a silent regression
    /// back to the general `split`+`concat` path would otherwise show up only as a timing
    /// number, not a test failure. 500 single-scalar inserts at random scalar-boundary
    /// offsets into a ~1 MB rope, all-ASCII so every byte offset is a boundary.
    @Test("the fast path is taken: 500 single-scalar inserts into a ~1 MB rope")
    func fastPathIsTaken() {
        var rng = SplitMix64(seed: 0xFA57_0001)
        var rope = Rope(String(repeating: "m", count: 1_000_000))
        for opIndex in 0..<500 {
            let at = Int(rng.next() % UInt64(rope.utf8Count + 1))
            let ok = rope.tryLeafLocalReplace(at..<at, with: Array("x".utf8))
            #expect(ok, "op \(opIndex): fast path declined for a single-scalar insert at \(at)")
        }
    }

    /// Randomised differential (500 ops): the same edit, applied to two copies of the same
    /// starting rope — one through the normal dispatch (`replaceSubrange`, which tries
    /// `tryLeafLocalReplace` first), the other forced through the general `split`+`concat`
    /// path only (`replaceSubrangeGeneralPathOnly`) — must produce byte-identical content
    /// and equal summaries, with invariants holding on both. Tree *shape* is not asserted
    /// equal: the two paths are not required to balance a tree the same way, only to agree
    /// on what the tree means (see this suite's file header).
    @Test("differential: the fast dispatch path and the general split+concat path agree")
    func fastAndGeneralPathsAgree() {
        var rng = SplitMix64(seed: 0xFA57_FA57_0001)
        let initial = String(repeating: "m", count: 4096)
        var fastCopy = Rope(initial)
        var generalCopy = Rope(initial)
        let pool: [String] = [
            "a", "bb", "ccc", "\n", "é", "字", "🙂", String(repeating: "x", count: 40),
        ]

        for opIndex in 0..<500 {
            let byteArray = Array(fastCopy.bytes())
            let boundaries = Self.scalarBoundaries(byteArray)
            guard
                let (lo, hi) = Self.boundedRange(boundaries, maxWidth: 32, using: &rng)
            else {
                continue
            }
            let text = pool[Int(rng.next() % UInt64(pool.count))]
            let other = Rope(text)

            fastCopy.replaceSubrange(lo..<hi, with: other)
            generalCopy.replaceSubrangeGeneralPathOnly(lo..<hi, with: other)

            #expect(
                fastCopy.toString() == generalCopy.toString(),
                "op \(opIndex): content diverged between the fast and general paths")
            #expect(
                fastCopy.summary == generalCopy.summary,
                "op \(opIndex): summary diverged between the fast and general paths")
            do {
                try fastCopy.checkTreeInvariants()
            } catch {
                Issue.record("op \(opIndex): fast-path copy invariant violation \(error)")
            }
            do {
                try generalCopy.checkTreeInvariants()
            } catch {
                Issue.record("op \(opIndex): general-path copy invariant violation \(error)")
            }
        }
    }

    // MARK: - Fast path: declines

    @Test("declines: bytes.count > 64 leaves the rope untouched")
    func declinesOverLongInsert() {
        var rope = Rope(String(repeating: "m", count: 200))
        let before = rope
        let tooLong = Array(String(repeating: "x", count: 65).utf8)
        #expect(rope.tryLeafLocalReplace(10..<10, with: tooLong) == false)
        #expect(rope == before)
        #expect(Array(rope.bytes()) == Array(before.bytes()))
    }

    @Test("declines: a range spanning past one leaf's byte span leaves the rope untouched")
    func declinesRangeSpanningLeaves() {
        // 5,000 bytes is comfortably past a single leaf's `2B * 64 = 768`-byte ceiling, so
        // this rope has multiple leaves; a 2,000-byte range starting at 0 cannot possibly
        // fit inside one.
        var rope = Rope(String(repeating: "m", count: 5_000))
        #expect(rope.height >= 1)
        let before = rope
        #expect(rope.tryLeafLocalReplace(0..<2_000, with: []) == false)
        #expect(rope == before)
        #expect(Array(rope.bytes()) == Array(before.bytes()))
    }

    @Test("declines: a non-scalar-boundary offset leaves the rope untouched")
    func declinesNonScalarBoundary() {
        // "é" is 2 bytes; offset 1 lands inside it.
        var rope = Rope("é" + String(repeating: "m", count: 100))
        let before = rope
        #expect(rope.isScalarBoundary(1) == false)
        #expect(rope.tryLeafLocalReplace(1..<1, with: Array("x".utf8)) == false)
        #expect(rope == before)
        #expect(Array(rope.bytes()) == Array(before.bytes()))
    }

    @Test("declines: a no-op at a non-scalar-boundary offset does not bypass the boundary check")
    func declinesNoOpAtNonScalarBoundary() {
        // "é" is 2 bytes; offset 1 lands inside it. `range.isEmpty && bytes.isEmpty` looks
        // like a genuine no-op, but before the no-op short-circuit was moved to run after
        // the scalar-boundary guards, this call returned `true` here anyway — bypassing the
        // boundary check entirely. This asserts the decline: the general path this falls
        // back to then `precondition`-traps with "byte offset 1 is not a scalar boundary",
        // which is the intended behaviour for a non-boundary offset (see this file's
        // header), but that trap is exercised by the general dispatch path, not by
        // `tryLeafLocalReplace` itself, so it is not what this test asserts.
        var rope = Rope("é" + String(repeating: "m", count: 100))
        let before = rope
        #expect(rope.isScalarBoundary(1) == false)
        #expect(rope.tryLeafLocalReplace(1..<1, with: []) == false)
        #expect(rope == before)
        #expect(Array(rope.bytes()) == Array(before.bytes()))
    }

    @Test("declines: an over-long 3-byte encoding leaves the rope untouched")
    func declinesOverLong3ByteEncoding() {
        var rope = Rope("hello")
        let before = rope
        // 0xE0 0x80 0x80 decodes to U+0000; the minimum scalar a 3-byte encoding may
        // represent is U+0800, so this is an over-long encoding.
        #expect(rope.tryLeafLocalReplace(0..<0, with: [0xE0, 0x80, 0x80]) == false)
        #expect(rope == before)
        #expect(Array(rope.bytes()) == Array(before.bytes()))
    }

    @Test("declines: an over-long 4-byte encoding leaves the rope untouched")
    func declinesOverLong4ByteEncoding() {
        var rope = Rope("hello")
        let before = rope
        // 0xF0 0x80 0x80 0x80 decodes to U+0000; the minimum scalar a 4-byte encoding may
        // represent is U+10000, so this is an over-long encoding.
        #expect(rope.tryLeafLocalReplace(0..<0, with: [0xF0, 0x80, 0x80, 0x80]) == false)
        #expect(rope == before)
        #expect(Array(rope.bytes()) == Array(before.bytes()))
    }

    @Test("declines: a UTF-16 surrogate leaves the rope untouched")
    func declinesSurrogate() {
        var rope = Rope("hello")
        let before = rope
        // 0xED 0xA0 0x80 decodes to U+D800, the first UTF-16 surrogate code point; no
        // surrogate is a valid scalar in UTF-8.
        #expect(rope.tryLeafLocalReplace(0..<0, with: [0xED, 0xA0, 0x80]) == false)
        #expect(rope == before)
        #expect(Array(rope.bytes()) == Array(before.bytes()))
    }

    @Test("declines: a scalar past U+10FFFF leaves the rope untouched")
    func declinesScalarPastMax() {
        var rope = Rope("hello")
        let before = rope
        // 0xF4 0x90 0x80 0x80 decodes to U+110000, one past the maximum valid scalar
        // U+10FFFF.
        #expect(rope.tryLeafLocalReplace(0..<0, with: [0xF4, 0x90, 0x80, 0x80]) == false)
        #expect(rope == before)
        #expect(Array(rope.bytes()) == Array(before.bytes()))
    }

    @Test(
        "declines: a lead byte followed by a present but non-continuation byte leaves the rope untouched"
    )
    func declinesLeadByteFollowedByNonContinuation() {
        var rope = Rope("hello")
        let before = rope
        // 0xC2 is a valid 2-byte lead byte, but 0x41 ('A') is not a continuation byte —
        // unlike `declinesTruncatedTwoByteSequence`, the second byte is present, just wrong.
        #expect(rope.tryLeafLocalReplace(0..<0, with: [0xC2, 0x41]) == false)
        #expect(rope == before)
        #expect(Array(rope.bytes()) == Array(before.bytes()))
    }

    /// Every other `tryLeafLocalReplace` test either asserts a decline, or reaches the fast
    /// path only through `replaceSubrange`/`insert`/`append`, which silently falls back to
    /// the general path whenever the fast path declines. So if `isValidUTF8` ever wrongly
    /// rejected a valid multi-byte scalar, every content assertion in this suite would still
    /// pass — the only symptom would be a quiet fall-through to the slower general path.
    /// Calling `tryLeafLocalReplace` directly and asserting `true` (not just checking the
    /// resulting bytes) is what would catch that false reject.
    @Test("the fast path accepts valid 2-, 3- and 4-byte scalars, not just declines them")
    func fastPathAcceptsValidMultiByteScalars() {
        var rope = Rope(String(repeating: "m", count: 5_000))
        #expect(rope.height >= 1, "fixture must have interior nodes")
        var expectedBytes = Array(String(repeating: "m", count: 5_000).utf8)
        var offset = 10
        for scalar in ["é", "字", "🙂"] {
            let bytes = Array(scalar.utf8)
            let ok = rope.tryLeafLocalReplace(offset..<offset, with: bytes)
            #expect(ok, "fast path declined a valid \(scalar) insert")
            expectedBytes.insert(contentsOf: bytes, at: offset)
            offset += bytes.count
        }
        #expect(Array(rope.bytes()) == expectedBytes)
    }

    @Test("declines: an empty rope leaves the rope untouched")
    func declinesEmptyRope() {
        var rope = Rope()
        let before = rope
        #expect(rope.tryLeafLocalReplace(0..<0, with: Array("x".utf8)) == false)
        #expect(rope == before)
        #expect(Array(rope.bytes()) == Array(before.bytes()))
    }

    /// The empty rope declines even for a *genuine* no-op (empty range, empty bytes), because
    /// the `utf8Count > 0` guard runs before the no-op short-circuit. That ordering is what
    /// the doc comment promises ("declines when the rope is empty"), and the general path
    /// then handles it identically, so this pins behaviour rather than protecting content.
    /// Without it the ordering is unobservable: a change restoring fast-accept here — after
    /// the scalar-boundary guards, so the non-boundary fix stayed intact — passed the entire
    /// suite when a cold reviewer looked for it.
    @Test("declines: an empty rope even for a genuine no-op")
    func declinesEmptyRopeNoOp() {
        var rope = Rope()
        #expect(rope.tryLeafLocalReplace(0..<0, with: []) == false)
        #expect(rope.isEmpty)
    }

    @Test("declines: a lone continuation byte leaves the rope untouched")
    func declinesLoneContinuationByte() {
        var rope = Rope("hello")
        let before = rope
        #expect(rope.tryLeafLocalReplace(0..<0, with: [0x80]) == false)
        #expect(rope == before)
        #expect(Array(rope.bytes()) == Array(before.bytes()))
    }

    @Test("declines: a truncated two-byte sequence leaves the rope untouched")
    func declinesTruncatedTwoByteSequence() {
        var rope = Rope("hello")
        let before = rope
        // 0xC2 is a valid 2-byte lead but there is no following continuation byte.
        #expect(rope.tryLeafLocalReplace(0..<0, with: [0xC2]) == false)
        #expect(rope == before)
        #expect(Array(rope.bytes()) == Array(before.bytes()))
    }

    @Test("declines: an invalid lead byte leaves the rope untouched")
    func declinesInvalidLeadByte() {
        var rope = Rope("hello")
        let before = rope
        // 0xC0 and 0xC1 are never valid UTF-8 lead bytes (over-long 2-byte forms).
        #expect(rope.tryLeafLocalReplace(0..<0, with: [0xC0, 0x80]) == false)
        #expect(rope == before)
        #expect(Array(rope.bytes()) == Array(before.bytes()))
    }

    // MARK: - Leaf-local delete coalescing across the removed run (fix for Part D gap)

    /// Deletes exactly one whole chunk's byte span from between two other chunks inside a
    /// single leaf and asserts the two now-adjacent neighbours were merged, rather than left
    /// as two chunks sitting next to each other unmerged — the case the fast path's
    /// `newChunks.isEmpty` early return used to skip coalescing for entirely.
    ///
    /// The three chunks (30, 40, 30 bytes) are built via three separate general-path
    /// appends, each seam sized so `generalPathReplace`'s seam-merge policy declines to
    /// merge it (every pairwise sum among adjacent originals is 70 > 64) — the only way to
    /// get three genuinely
    /// separate, un-coalesced chunks sitting in one leaf, since any single edit whose total
    /// span is <= 64 bytes gets repacked into one chunk by `packChunks`. Removing the middle
    /// (40-byte) chunk's exact byte span leaves the two 30-byte chunks adjacent, and
    /// 30 + 30 = 60 <= 64, so they are expected to merge.
    @Test("a leaf-local delete that removes a whole chunk coalesces its neighbours")
    func leafLocalDeleteOfWholeChunkCoalesces() {
        var rope = Rope(String(repeating: "x", count: 30))
        rope.replaceSubrangeGeneralPathOnly(
            rope.utf8Count..<rope.utf8Count, with: Rope(String(repeating: "y", count: 40)))
        rope.replaceSubrangeGeneralPathOnly(
            rope.utf8Count..<rope.utf8Count, with: Rope(String(repeating: "z", count: 30)))
        #expect(
            rope.height == 0, "fixture must be a single leaf for this to exercise the fast path")
        let originalChunkCounts = Array(rope.chunks()).map { Int($0.count) }
        #expect(
            originalChunkCounts == [30, 40, 30],
            "fixture did not build three separate un-merged chunks: \(originalChunkCounts)")

        let ok = rope.tryLeafLocalReplace(30..<70, with: [])
        #expect(ok, "fast path declined the whole-chunk delete")
        let expectedContent = String(repeating: "x", count: 30) + String(repeating: "z", count: 30)
        #expect(rope.toString() == expectedContent)

        let finalChunkCounts = Array(rope.chunks()).map { Int($0.count) }
        #expect(
            finalChunkCounts == [60],
            "expected the two 30-byte neighbours to coalesce into one 60-byte chunk, got \(finalChunkCounts)"
        )
    }

    /// The positive case complementing `leafLocalDeleteOfWholeChunkCoalesces` above (that one
    /// is the negative: a pair summing 70 > 64 must not merge). A general-path append whose
    /// boundary chunk pair sums to `<= 64` must still merge — reachable only through
    /// `replaceSubrangeGeneralPathOnly`, since the fast path would otherwise absorb an edit
    /// this small and never reach `generalPathReplace`'s seam-merge policy at all. Both
    /// original chunks are the whole tree (a single leaf, `height == 0`), so the boundary
    /// chunk on each side is a plain array element of a `Fragment.items` group, not one
    /// buried inside a `Fragment.nodes` subtree — the case `generalPathReplace`'s doc comment
    /// says the merge is declined for.
    @Test("general path: an appended chunk pair summing <= 64 at the seam still merges")
    func generalPathMergesSeamUnderThreshold() {
        var rope = Rope(String(repeating: "a", count: 20))
        #expect(rope.height == 0, "fixture must be a single leaf")
        rope.replaceSubrangeGeneralPathOnly(
            rope.utf8Count..<rope.utf8Count, with: Rope(String(repeating: "b", count: 20)))
        #expect(
            rope.toString()
                == String(repeating: "a", count: 20) + String(repeating: "b", count: 20))
        let chunkCounts = Array(rope.chunks()).map { Int($0.count) }
        #expect(
            chunkCounts == [40],
            "expected the two 20-byte chunks to merge into one, got \(chunkCounts)")
    }

    /// The `mergeLeadingSeam` counterpart to `generalPathMergesSeamUnderThreshold` above (that
    /// one only exercises `mergeTrailingSeam`, since its insert lands at the very end where
    /// `suffixFragments` is empty and `mergeLeadingSeam` has nothing to decline *into* — it
    /// declines correctly, but that is not the same as a test asserting it can also *succeed*).
    /// This drives an insert into the middle of a single leaf's first chunk, via
    /// `replaceSubrangeGeneralPathOnly` so the stage-1 fast path cannot absorb it: the
    /// straddling chunk's right remainder (5 bytes) plus the untouched chunk that follows it
    /// (30 bytes) sums to 35 <= 64, so `mergeLeadingSeam` must merge them.
    @Test("general path: an inserted run's trailing edge merges with the following chunk")
    func generalPathMergesLeadingSeamUnderThreshold() {
        var rope = Rope(String(repeating: "a", count: 40))
        rope.replaceSubrangeGeneralPathOnly(
            rope.utf8Count..<rope.utf8Count, with: Rope(String(repeating: "c", count: 30)))
        #expect(rope.height == 0, "fixture must be a single leaf")
        let originalChunkCounts = Array(rope.chunks()).map { Int($0.count) }
        #expect(
            originalChunkCounts == [40, 30],
            "fixture did not build two separate un-merged chunks: \(originalChunkCounts)")

        rope.replaceSubrangeGeneralPathOnly(35..<35, with: Rope(String(repeating: "b", count: 3)))
        #expect(
            rope.toString()
                == String(repeating: "a", count: 35) + String(repeating: "b", count: 3)
                + String(repeating: "a", count: 5) + String(repeating: "c", count: 30))

        let finalChunkCounts = Array(rope.chunks()).map { Int($0.count) }
        #expect(
            finalChunkCounts == [35, 3, 35],
            "expected the 5-byte remainder and the 30-byte following chunk to merge into one 35-byte chunk, got \(finalChunkCounts)"
        )
    }

    /// The seam policy's **boundary**: a pair summing to exactly 64 merges, because the
    /// threshold is `<= 64`. The two tests above both use pairs well under the threshold (40
    /// and 35), so mutating either `mergeTrailingSeam`'s or `mergeLeadingSeam`'s comparison
    /// from `<= 64` to `< 64` left the whole suite green -- a mutation pass by the main
    /// conversation found both survivors. These two tests are what kill them, and they are
    /// the only tests that pin the exact value of the threshold rather than merely that one
    /// exists.
    @Test("general path: a seam pair summing to exactly 64 merges, trailing side")
    func generalPathMergesTrailingSeamAtExactlySixtyFour() {
        var rope = Rope(String(repeating: "a", count: 34))
        #expect(rope.height == 0, "fixture must be a single leaf")
        rope.replaceSubrangeGeneralPathOnly(
            rope.utf8Count..<rope.utf8Count, with: Rope(String(repeating: "b", count: 30)))
        #expect(
            rope.toString()
                == String(repeating: "a", count: 34) + String(repeating: "b", count: 30))
        let chunkCounts = Array(rope.chunks()).map { Int($0.count) }
        #expect(
            chunkCounts == [64],
            "34 + 30 == 64 is exactly the threshold and must merge, got \(chunkCounts)")
    }

    @Test("general path: a seam pair summing to exactly 64 merges, leading side")
    func generalPathMergesLeadingSeamAtExactlySixtyFour() {
        var rope = Rope(String(repeating: "a", count: 40))
        #expect(rope.height == 0, "fixture must be a single leaf")
        rope.replaceSubrangeGeneralPathOnly(
            rope.utf8Count..<rope.utf8Count, with: Rope(String(repeating: "c", count: 30)))
        let originalChunkCounts = Array(rope.chunks()).map { Int($0.count) }
        #expect(
            originalChunkCounts == [40, 30],
            "fixture did not build two separate un-merged chunks: \(originalChunkCounts)")

        // Splitting at 6 leaves a 34-byte remainder; 34 + 30 == 64 is exactly the threshold.
        rope.replaceSubrangeGeneralPathOnly(6..<6, with: Rope(String(repeating: "z", count: 3)))
        #expect(
            rope.toString()
                == String(repeating: "a", count: 6) + String(repeating: "z", count: 3)
                + String(repeating: "a", count: 34) + String(repeating: "c", count: 30))
        let finalChunkCounts = Array(rope.chunks()).map { Int($0.count) }
        #expect(
            finalChunkCounts == [6, 3, 64],
            "34 + 30 == 64 is exactly the threshold and must merge, got \(finalChunkCounts)")
    }

    // MARK: - Fragmentation guard

    @Test("fragmentation guard: mean chunk fill stays healthy after 20,000 scattered inserts")
    func fragmentationGuard() {
        var rng = SplitMix64(seed: 0x5CA1_AB1E)
        var rope = Rope()
        var length = 0
        for _ in 0..<20_000 {
            let at = length == 0 ? 0 : Int(rng.next() % UInt64(length + 1))
            rope.insert("x", at: at)
            length += 1
        }
        let chunkList = Array(rope.chunks())
        #expect(!chunkList.isEmpty)
        let totalBytes = chunkList.reduce(0) { $0 + Int($1.count) }
        let meanFill = Double(totalBytes) / Double(chunkList.count)
        #expect(
            meanFill >= 24,
            "mean chunk fill \(meanFill) of 64 bytes across \(chunkList.count) chunks is below the fragmentation guard's floor of 24"
        )
    }
}
