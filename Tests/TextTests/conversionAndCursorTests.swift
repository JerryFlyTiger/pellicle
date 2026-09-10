import Darwin
import Foundation
import Testing

@testable import Text

/// M1.2's three deliverables that don't already have a home in an existing file
/// (`dev/specs/m1.2.md`):
///
/// - **A (metric conversions)**: hand-written fixtures, a round-trip property, and an
///   oracle-checked line/column test. The differential property against the randomised
///   `[UInt8]` model lives in `ropeTests.swift`'s `randomizedModel`, not here (extending an
///   existing property loop rather than duplicating one, per the spec).
/// - **B (bulk loader)**: a differential test against the pre-M1.2 recursive-halving build
///   (`SumTree.buildViaRecursiveHalvingForTesting`), at the sizes the spec names (`0, 1,
///   B-1, B, B+1, 2B, 2B+1`, plus a few thousand items).
/// - **C (lazy cursor)**: correctness (agrees with `SumTree.items()`) and a zero-allocation
///   observation, demonstrated rather than asserted in prose. The defence against "the
///   cursor copies a leaf on every descent" is `cursorTraversalSharesLeafStorage` (storage
///   identity, deterministic); `cursorTraversalAllocatesNothing` (net `blocks_in_use`) is
///   kept as a supplementary signal only — see both doc comments for why the net counter
///   alone is not a defence (M1.2 fix round task 4: the main conversation ran the
///   materialise-per-descent mutation and it survived the net-counter test).
@Suite("M1.2: conversions, bulk loader, cursor", .serialized)
struct ConversionAndCursorTests {

    // MARK: - A: hand-written fixtures

    @Test("empty rope")
    func emptyRope() {
        let r = Rope("")
        #expect(r.lineCount == 1)
        #expect(r.byteOffsetOfLineStart(0) == 0)
        let (line, col) = r.lineAndByteColumn(atByteOffset: 0)
        #expect(line == 0 && col == 0)
        #expect(r.convert(offset: 0, from: .utf8, to: .utf16) == 0)
        #expect(r.convert(offset: 0, from: .utf8, to: .scalars) == 0)
        #expect(r.convert(offset: 0, from: .utf8, to: .lines) == 0)
    }

    @Test("no trailing newline: one line, lineCount 1")
    func noTrailingNewline() {
        let r = Rope("hello")
        #expect(r.lineCount == 1)
        #expect(r.byteOffsetOfLineStart(0) == 0)
        let (line, col) = r.lineAndByteColumn(atByteOffset: 5)
        #expect(line == 0 && col == 5)
    }

    @Test("leading newline: line 0 is empty, line 1 starts right after it")
    func leadingNewline() {
        let r = Rope("\nhello")
        #expect(r.lineCount == 2)
        #expect(r.byteOffsetOfLineStart(0) == 0)
        #expect(r.byteOffsetOfLineStart(1) == 1)
        let (line0, col0) = r.lineAndByteColumn(atByteOffset: 0)
        #expect(line0 == 0 && col0 == 0)
        let (line1, col1) = r.lineAndByteColumn(atByteOffset: 1)
        #expect(line1 == 1 && col1 == 0)
    }

    @Test("consecutive newlines: every one is its own empty line")
    func consecutiveNewlines() {
        let r = Rope("\n\n\n")
        #expect(r.lineCount == 4)
        #expect(r.byteOffsetOfLineStart(0) == 0)
        #expect(r.byteOffsetOfLineStart(1) == 1)
        #expect(r.byteOffsetOfLineStart(2) == 2)
        #expect(r.byteOffsetOfLineStart(3) == 3)
        for line in 0..<4 {
            let (l, c) = r.lineAndByteColumn(atByteOffset: r.byteOffsetOfLineStart(line))
            #expect(l == line && c == 0)
        }
    }

    @Test("CRLF: \\r is an ordinary byte, does not end a line or its own column")
    func crlf() {
        let r = Rope("ab\r\ncd\r\n")
        #expect(r.lineCount == 3)
        #expect(r.byteOffsetOfLineStart(1) == 4)  // right after the first "\n"
        let (line, col) = r.lineAndByteColumn(atByteOffset: 2)  // the "\r"
        #expect(line == 0 && col == 2)
    }

    @Test("4-byte scalars: utf8, utf16 and scalars all disagree")
    func fourByteScalars() {
        // "a" (1 byte, 1 scalar, 1 utf16) + "🙂" (4 bytes, 1 scalar, 2 utf16) + "b" (1/1/1).
        let r = Rope("a🙂b")
        #expect(r.utf8Count == 6)
        #expect(r.convert(offset: 0, from: .utf8, to: .scalars) == 0)
        #expect(r.convert(offset: 1, from: .utf8, to: .scalars) == 1)  // right after "a"
        #expect(r.convert(offset: 5, from: .utf8, to: .scalars) == 2)  // right after "🙂"
        #expect(r.convert(offset: 6, from: .utf8, to: .scalars) == 3)  // right after "b"
        #expect(r.convert(offset: 1, from: .utf8, to: .utf16) == 1)
        #expect(r.convert(offset: 5, from: .utf8, to: .utf16) == 3)  // 1 ("a") + 2 (surrogate pair)
        #expect(r.convert(offset: 6, from: .utf8, to: .utf16) == 4)
        // Round trip through utf16 and back.
        #expect(
            r.convert(
                offset: r.convert(offset: 5, from: .utf8, to: .utf16), from: .utf16, to: .utf8) == 5
        )
        #expect(
            r.convert(
                offset: r.convert(offset: 5, from: .utf8, to: .scalars), from: .scalars, to: .utf8)
                == 5)
    }

    @Test("offset exactly on a chunk boundary")
    func exactlyOnChunkBoundary() {
        // 64 bytes fill exactly one chunk; the next chunk starts at byte 64.
        let r = Rope(String(repeating: "a", count: 64) + String(repeating: "b", count: 64))
        #expect(r.convert(offset: 64, from: .utf8, to: .scalars) == 64)
        let (line, col) = r.lineAndByteColumn(atByteOffset: 64)
        #expect(line == 0 && col == 64)
    }

    @Test("offset on the last byte")
    func offsetOnLastByte() {
        let r = Rope("hello")
        #expect(r.convert(offset: r.utf8Count, from: .utf8, to: .scalars) == 5)
        let (line, col) = r.lineAndByteColumn(atByteOffset: r.utf8Count)
        #expect(line == 0 && col == 5)
    }

    @Test("lineCount with and without a trailing newline")
    func lineCountTrailingNewline() {
        #expect(Rope("a\nb\nc").lineCount == 3)  // no trailing newline: 3 lines
        #expect(Rope("a\nb\nc\n").lineCount == 4)  // trailing newline: a 4th, empty, line
    }

    // MARK: - A: byteOffset(line:byteColumn:) validation (M1.2 fix round task A1)

    /// `byteOffset(line:byteColumn:)` is `lineAndByteColumn`'s inverse; check the round trip
    /// at every scalar-boundary offset of a multi-line, mixed-scalar-width fixture, so every
    /// legal `byteColumn` this function can be asked for (including one at the very end of a
    /// line, `lineAndByteColumn`'s own output for a `"\n"`-position offset) is exercised.
    @Test("byteOffset(line:byteColumn:) is lineAndByteColumn's inverse, every scalar boundary")
    func byteOffsetIsInverseOfLineAndByteColumn() {
        let r = Rope(Self.oracleFixture)
        let boundaries = Self.scalarByteBoundaries(Array(Self.oracleFixture.utf8))
        for offset in boundaries {
            let (line, col) = r.lineAndByteColumn(atByteOffset: offset)
            let back = r.byteOffset(line: line, byteColumn: col)
            #expect(back == offset, "offset \(offset): line \(line) col \(col) -> \(back)")
        }
    }

    /// The one legal edge this file's contract calls out by name (`Rope.swift`'s doc
    /// comment on `byteOffset(line:byteColumn:)`): `byteColumn` equal to a line's own
    /// length names the position of the `"\n"` that ends it (or the buffer's end, for the
    /// last line) — still legal, not "one past the line".
    @Test(
        "byteOffset(line:byteColumn:): byteColumn == line length names the line's own newline or the buffer's end"
    )
    func byteOffsetAtLineEndIsLegal() {
        let r = Rope("ab\ncde\n")
        #expect(r.byteOffset(line: 0, byteColumn: 2) == 2)  // "ab"'s length: its own "\n"
        #expect(r.byteOffset(line: 1, byteColumn: 3) == 6)  // "cde"'s length: its own "\n"
        #expect(r.byteOffset(line: 2, byteColumn: 0) == 7)  // the empty last line: buffer end
    }

    // MARK: - A: round-trip property

    /// For every ordered pair of the three *positional* metrics (`utf8`, `utf16`,
    /// `scalars`), converting an offset out and back is the identity, over randomised ropes
    /// and offsets drawn from the `from` metric's own valid boundary set (`dev/specs/m1.2.md`
    /// section 3).
    ///
    /// `.lines` is deliberately **not** included in this generic all-pairs loop: it counts a
    /// byte *value*, not units consumed (see `Rope.convert`'s doc comment), so many byte
    /// positions share one `.lines` count and "convert a `.lines` value out and back" is not
    /// invertible in general — only `.lines` used as the *source* of a round trip, starting
    /// from one of its own boundaries (an actual line number), is well-defined:
    /// `byteOffsetOfLineStart(line)` then `convert(..., from: .utf8, to: .lines)` must give
    /// back `line`. That direction is checked separately below
    /// (`roundTripLineNumberViaLineStart`); a generic `(X, .lines)` round trip starting from
    /// an arbitrary `X` offset is not attempted, because there is no reason to expect it to
    /// return to the same `X` (only to *a* position on the same line).
    @Test("round-trip: utf8/utf16/scalars, every ordered pair, random ropes and offsets")
    func roundTripPositionalMetrics() {
        var rng = SplitMix64(seed: 0x1234_5678_9ABC)
        let pool: [String] = ["a", "b", "\n", "é", "字", "🙂", "xy"]
        let positional: [TextMetric] = [.utf8, .utf16, .scalars]
        for _ in 0..<40 {
            let length = Int(rng.next() % 60)
            var s = ""
            for _ in 0..<length { s += pool[Int(rng.next() % UInt64(pool.count))] }
            let r = Rope(s)
            let boundaries = Self.scalarByteBoundaries(Array(s.utf8))
            for from in positional {
                for to in positional {
                    for byteOffset in boundaries {
                        let fromOffset = r.convert(offset: byteOffset, from: .utf8, to: from)
                        let toOffset = r.convert(offset: fromOffset, from: from, to: to)
                        let back = r.convert(offset: toOffset, from: to, to: from)
                        let message =
                            "\(from) -> \(to) -> \(from) at byte \(byteOffset) of \(s.debugDescription): "
                            + "expected \(fromOffset), got \(back)"
                        #expect(back == fromOffset, "\(message)")
                    }
                }
            }
        }
    }

    @Test("round-trip: every line number -> byteOffsetOfLineStart -> back to the same line number")
    func roundTripLineNumberViaLineStart() {
        var rng = SplitMix64(seed: 0xFEED_5EED)
        let pool: [String] = ["a", "\n", "bb", "\n\n", "é\n", "字🙂\n"]
        for _ in 0..<40 {
            let length = Int(rng.next() % 30)
            var s = ""
            for _ in 0..<length { s += pool[Int(rng.next() % UInt64(pool.count))] }
            let r = Rope(s)
            for line in 0..<r.lineCount {
                let byteStart = r.byteOffsetOfLineStart(line)
                let back = r.convert(offset: byteStart, from: .utf8, to: .lines)
                #expect(back == line, "line \(line) of \(s.debugDescription): got back \(back)")
            }
        }
    }

    fileprivate static func scalarByteBoundaries(_ bytes: [UInt8]) -> [Int] {
        var result = [0]
        for i in 0..<bytes.count where bytes[i] & 0b1100_0000 != 0b1000_0000 {
            if i != 0 { result.append(i) }
        }
        result.append(bytes.count)
        return result
    }

    // MARK: - A: oracle for line/column (GNU Emacs, `-Q --batch`)

    /// Fixture bytes (37 bytes, verified with `xxd`): `"hello world\ncaf\xC3\xA9 au lait\n` +
    /// `"third line\n"` — three lines, the second holding one 2-byte UTF-8 scalar (`é`,
    /// U+00E9) so the line/column arithmetic is exercised across a multi-byte scalar, not
    /// only over ASCII.
    private static let oracleFixture = "hello world\ncafé au lait\nthird line\n"

    /// Transcript, `emacs -Q --batch -l oracle.el` on this machine (GNU Emacs 30.2), reading
    /// the fixture above with `coding-system-for-read` forced to `utf-8` (elisp, run once to
    /// produce this table — not re-run by this test, which only checks the numbers below):
    /// ```elisp
    /// (let ((coding-system-for-read 'utf-8)) (find-file "oracle_fixture.txt"))
    /// (dolist (pt '(1 7 12 13 25 26 31 36 37))
    ///   (goto-char pt)
    ///   (princ (format "pt=%d byte=%d line=%d col=%d\n"
    ///                  pt (position-bytes pt) (line-number-at-pos) (current-column))))
    /// ```
    /// Output:
    /// ```
    /// pt=1 byte=1 line=1 col=0
    /// pt=7 byte=7 line=1 col=6
    /// pt=12 byte=12 line=1 col=11
    /// pt=13 byte=13 line=2 col=0
    /// pt=25 byte=26 line=2 col=13
    /// pt=26 byte=27 line=3 col=0
    /// pt=31 byte=32 line=3 col=5
    /// pt=36 byte=37 line=3 col=10
    /// pt=37 byte=38 line=4 col=0
    /// ```
    /// `position-bytes` is Emacs's own 1-based byte offset; this project's `byteOffset` is
    /// 0-based, so every value below subtracts 1 from `position-bytes`'s output, **visibly,
    /// in this test** (`dev/specs/m1.2.md` section 3's requirement), not silently inside the
    /// implementation. `line-number-at-pos` is 1-based; this project's `line` is 0-based, so
    /// every expected line below is the transcript's line minus 1.
    ///
    /// **A width discovery, not assumed from memory**: running this actually surfaced that
    /// `current-column` in this batch environment reports `é` (U+00E9) as **2 display
    /// columns**, not 1 (`(char-width ?é)` => `2`, `(string-width "café")` => `5`) — an
    /// ambiguous-width default this `-Q --batch` config picked with no display attached.
    /// `current-column` counts *display width*, a different unit from this API's *byte*
    /// column in general regardless of that quirk, so the two are never directly
    /// comparable on a line containing `é`. The line-number and byte-offset columns of the
    /// transcript (`position-bytes`, `line-number-at-pos`) are unaffected by display width
    /// and are asserted for every point; `current-column` is asserted only at the points on
    /// the two pure-ASCII lines (line 1 and line 3, transcript's 1-based numbering), where
    /// byte column, scalar column and display column all coincide.
    @Test("oracle: line and byte-column conventions match GNU Emacs's, 0-based per this API")
    func oracleLineAndColumn() {
        let r = Rope(Self.oracleFixture)
        #expect(Array(Self.oracleFixture.utf8).count == 37)

        // (emacsPositionBytes, emacsLine, emacsCurrentColumn, checkColumn)
        let transcript:
            [(emacsPositionBytes: Int, emacsLine: Int, emacsCurrentColumn: Int, checkColumn: Bool)] =
                [
                    (1, 1, 0, true),
                    (7, 1, 6, true),
                    (12, 1, 11, true),
                    (13, 2, 0, true),  // col 0 is trivially byte-column-independent of width
                    (26, 2, 13, false),  // line 2 contains "é": current-column counts display width
                    (27, 3, 0, true),
                    (32, 3, 5, true),
                    (37, 3, 10, true),
                    (38, 4, 0, true),
                ]
        for row in transcript {
            let byteOffset = row.emacsPositionBytes - 1
            let (line, col) = r.lineAndByteColumn(atByteOffset: byteOffset)
            #expect(
                line == row.emacsLine - 1,
                "byte \(byteOffset): line \(line) != oracle \(row.emacsLine - 1)")
            if row.checkColumn {
                #expect(
                    col == row.emacsCurrentColumn,
                    "byte \(byteOffset): column \(col) != oracle \(row.emacsCurrentColumn)")
            }
        }
    }

    // MARK: - B: bulk loader differential test

    /// M1.2 deliverable B's acceptance test: the bottom-up bulk build (`SumTree.build`,
    /// reached via `SumTree.init(items:)`) produces a tree `Equatable`-equal to the
    /// pre-M1.2 recursive-halving-plus-`concat` build for the same input, at the sizes the
    /// spec names — `0, 1, B-1, B, B+1, 2B, 2B+1` — plus a few larger ones, and both pass
    /// `checkTreeInvariants()`. `Chunk` (this file's `Item`) is not itself `Equatable`, so
    /// comparison is by each chunk's own bytes, in order — this is exactly what `Rope`'s own
    /// `Equatable` does (`Rope.swift`'s `==`: compare summary, then compare bytes).
    @Test(
        "bulk loader agrees with the old recursive-halving build",
        arguments: [0, 1, 5, 6, 7, 12, 13, 50, 6000])
    func bulkLoaderMatchesRecursiveHalving(itemCount: Int) throws {
        var rng = SplitMix64(seed: UInt64(itemCount) &+ 0x51DE_1234)
        var bytes: [UInt8] = []
        for _ in 0..<itemCount { bytes.append(UInt8(rng.next() % 26) + 97) }
        let chunks = Self.packChunksForTest(bytes)

        let newTree = SumTree<Chunk>(items: chunks)
        let oldTree = SumTree<Chunk>(
            root: SumTree<Chunk>.buildViaRecursiveHalvingForTesting(chunks))

        try newTree.checkInvariants()
        try oldTree.checkInvariants()

        let newBytes = newTree.items().map { chunk in chunk.withUnsafeBytes { Array($0) } }
        let oldBytes = oldTree.items().map { chunk in chunk.withUnsafeBytes { Array($0) } }
        #expect(
            newBytes == oldBytes,
            "itemCount \(itemCount): chunk sequence differs from the old build")
    }

    /// The mutation this spec names by name (section 5, "Bulk loader fill target"): a loader
    /// that packs leaves at `B` instead of "as full as the invariant allows" still passes
    /// every invariant and every equality check above (`B...2B` is legal either way), so
    /// only a fill assertion notices it. Checks that a bulk build of `10 * 2B` items — large
    /// enough to need more than one leaf, small enough to stay one level — uses the fewest
    /// leaves that keep every leaf non-underfull, i.e. mean fill strictly above `B`.
    @Test("bulk loader packs leaves toward 2B, not toward B")
    func bulkLoaderFillTarget() throws {
        let itemCount = 10 * 2 * 6  // 10 * 2B, B = 6
        // One-byte chunks, built directly (not via `packChunksForTest`, which would merge
        // many bytes into far fewer 64-byte chunks): this test needs to control the *leaf
        // item count* directly, not the byte count.
        let chunks: [Chunk] = (0..<itemCount).map { Chunk(bytes: [UInt8(97 + $0 % 26)]) }
        let tree = SumTree<Chunk>(items: chunks)
        try tree.checkInvariants()
        guard case .interior(let leaves, _, let height) = tree.root, height == 1 else {
            Issue.record("expected a single-level-of-leaves tree for \(itemCount) items")
            return
        }
        let meanFill = Double(itemCount) / Double(leaves.count)
        let message =
            "mean leaf fill \(meanFill) is not above B=6 -- the loader is packing toward B, "
            + "not toward the fullest fill the invariant allows"
        #expect(meanFill > 6.0, "\(message)")
    }

    fileprivate static func packChunksForTest(_ bytes: [UInt8]) -> [Chunk] {
        guard !bytes.isEmpty else { return [] }
        var chunks: [Chunk] = []
        var start = 0
        while start < bytes.count {
            let end = min(start + 64, bytes.count)
            chunks.append(Chunk(bytes: bytes[start..<end]))
            start = end
        }
        return chunks
    }

    // MARK: - C: lazy cursor correctness

    /// **`viaItems` must be an independent implementation, not another cursor traversal.**
    /// An earlier version of this test compared `rope.chunks()` against
    /// `Array(rope.makeCursor())` — both `SumTreeCursor` traversals, since M1.2 re-expressed
    /// `chunks()`/`bytes()` on the cursor. A walking bug shared by all three (e.g.
    /// `descendLeftmost` skipping a leaf's first item) would corrupt every arm identically
    /// and this test would still pass, checking nothing. `itemsViaTree()` (`Rope.swift`,
    /// test-only) is `SumTree.items()`'s own recursive `collect`, which never touches
    /// `SumTreeCursor` at all, so it is a genuine independent oracle for the cursor.
    @Test("cursor traversal agrees with SumTree.items(), several sizes")
    func cursorAgreesWithItems() {
        for n in [0, 1, 100, 10_000] {
            let rope = Rope(String(repeating: "ab\n", count: n))
            let viaCursor = Array(rope.chunks())
            let viaItems = rope.itemsViaTree()
            #expect(viaCursor.count == viaItems.count)
            let cursorBytes = viaCursor.flatMap { chunk in chunk.withUnsafeBytes { Array($0) } }
            let treeBytes = viaItems.flatMap { chunk in chunk.withUnsafeBytes { Array($0) } }
            #expect(cursorBytes == treeBytes, "n=\(n)")
            #expect(cursorBytes == Array(rope.bytes()), "n=\(n)")
        }
    }

    @Test("cursor seek positions resumably: next() after seek continues from the found item")
    func cursorSeekIsResumable() {
        let s = String(repeating: "0123456789", count: 2000)  // 20,000 bytes, several chunks
        let rope = Rope(s)
        var cursor = rope.makeCursor()
        cursor.seek(to: 10_000, metric: .utf8)
        var collected: [UInt8] = []
        while let chunk = cursor.next() {
            chunk.withUnsafeBytes { collected.append(contentsOf: $0) }
        }
        let allBytes = Array(rope.bytes())
        // The chunk containing byte 10,000 may start at or before that offset (chunks are
        // <= 64 bytes), so the collected suffix starts at the *chunk* boundary at or before
        // 10,000, not necessarily at 10,000 itself.
        #expect(allBytes.suffix(collected.count) == ArraySlice(collected))
        #expect(collected.count >= s.utf8.count - 10_000)
    }

    /// M1.2 fix round task A2: `seek(to:metric:)`'s `.lines` case needs the same
    /// off-by-one shift `Rope.convert`/`byteOffsetOfLineStart` apply, or it lands one line
    /// past `offset` (see `Rope.swift`'s doc comment on the fix). Checks every seek lands at
    /// or before `byteOffsetOfLineStart(line)`'s own chunk boundary — never after it, which
    /// is exactly what the un-shifted bug did — at several line numbers including 0 (the
    /// special case the shift itself must not break; see that same doc comment).
    @Test("cursor seek by .lines lands at the start of that line's chunk, not one line ahead")
    func cursorSeekLinesMatchesLineStart() {
        let s = String(repeating: "0123456789\n", count: 2000)  // 22,000 bytes, several chunks
        let rope = Rope(s)
        let allBytes = Array(rope.bytes())
        for line in [0, 1, 5, 100, rope.lineCount - 1] {
            let expectedByteStart = rope.byteOffsetOfLineStart(line)
            var cursor = rope.makeCursor()
            cursor.seek(to: line, metric: .lines)
            var collected: [UInt8] = []
            while let chunk = cursor.next() {
                chunk.withUnsafeBytes { collected.append(contentsOf: $0) }
            }
            // Same tolerance as cursorSeekIsResumable above: the collected suffix starts at
            // the *chunk* boundary at or before `expectedByteStart` (chunks are <= 64
            // bytes), never strictly after it -- landing strictly after is the bug this
            // test exists to catch.
            #expect(allBytes.suffix(collected.count) == ArraySlice(collected), "line \(line)")
            let shortfallMessage =
                "line \(line): seek landed after byte \(expectedByteStart), only got "
                + "\(collected.count) of \(allBytes.count - expectedByteStart) expected bytes"
            #expect(collected.count >= allBytes.count - expectedByteStart, "\(shortfallMessage)")
        }
    }

    /// Snapshot isolation: a cursor built from a rope value must not observe a later edit to
    /// a *copy* of that rope (`dev/specs/m1.2.md` section 5, "Cursor staleness" mutation
    /// focus) — value semantics, consistent with the rest of the module.
    @Test("cursor staleness: editing a copy after taking a cursor does not change the traversal")
    func cursorSnapshotIsolation() {
        var rope = Rope("hello world")
        let cursor = rope.makeCursor()
        rope.insert("XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX", at: 0)
        var c = cursor
        var collected: [UInt8] = []
        while let chunk = c.next() {
            chunk.withUnsafeBytes { collected.append(contentsOf: $0) }
        }
        #expect(String(decoding: collected, as: UTF8.self) == "hello world")
    }

    /// **No longer the defence against the per-descent-copy mutation** (M1.2 fix round task
    /// 4) — `cursorTraversalSharesLeafStorage` below is. This test measures a **net** gauge
    /// (`blocks_in_use` before and after a full traversal), and the main conversation ran
    /// the mutation this test was written to catch (section 5: "materialise the current
    /// leaf's items into an array on each descent") against it directly: **it survived, all
    /// 99 tests passed.** The mutation's arrays are transient — freed as stack frames pop —
    /// so the net delta at the end stays under the bound below while the allocation traffic
    /// it was supposed to detect happens freely in between. Kept anyway as a supplementary,
    /// coarser signal (a regression that leaks rather than frees would still show here), not
    /// because it can be trusted alone.
    ///
    /// Technique: Darwin's `malloc_zone_statistics` on the default zone, counting
    /// `blocks_in_use` before and after a full traversal of an already-built ~1.6 MB rope
    /// (built and warmed up beforehand, so the traversal itself is the only thing being
    /// measured).
    ///
    /// This is a **whole-process** counter, not scoped to this call: inside the full test run
    /// (where `swift-testing` runs suites concurrently by default) other tests' allocations
    /// land in the same window. This suite is marked `.serialized` (above), which only keeps
    /// its own tests from overlapping each other and does not stop other suites — hence the
    /// isolation gate documented below.
    ///
    /// **Why this test is gated on an environment variable and run alone** (2026-09-10).
    /// It failed the gate twice in six full `swift test --parallel` runs, at deltas of 2,669
    /// and 4,429 against the 1,250 bound, while passing 3/3 when run alone — a false failure
    /// every time, since no product code had changed. Two repairs were measured before this
    /// one, and the numbers are worth keeping because they bound what any in-suite repair can
    /// achieve:
    ///
    /// - *Raising the bound* was rejected on arithmetic: individual windows reached **7,409**,
    ///   and a bound above a burst is within 3.4x of the 25,000 signal the test exists to
    ///   catch — and still unbounded, because the noise is other suites' allocation traffic,
    ///   not a property of this code.
    /// - *Ten windows, take the minimum* was measured and shipped, then refuted. Five
    ///   instrumented full runs gave a minimum ≤ 0 every time (-451, -352, -351, -228, -500;
    ///   negative because other threads free blocks inside the window too), which looked
    ///   conclusive — bursts appeared to last a few windows, never all ten. A sixth run then
    ///   failed with all ten windows contaminated: `[2060, 6680, 2572, 1533, 2997, 2916,
    ///   1473, 3549, 4465, 2585]`, minimum **1,473**. A concurrent suite can allocate steadily
    ///   for longer than the whole sampling period, so no order statistic over windows inside
    ///   the parallel run is safe.
    ///
    /// What is left is isolation: `malloc_zone_statistics` counts the **whole process**, so
    /// the measurement is only meaningful when nothing else in the process is allocating.
    /// `dev/gate.sh` therefore runs this test in its own `swift test --filter` invocation
    /// with `PELLICLE_ALLOC_PROBE=1`, after the parallel run; the default `swift test` skips
    /// it, and the gate checks this test's own result line rather than the run summary,
    /// because swift-testing prints "Test run with 1 test in 1 suite passed" for a *skipped*
    /// test too.
    ///
    /// **Isolation makes the measurement exact, and the bound absolute.** Run this way, fifty
    /// windows over five runs each read **1** block, with no spread at all, so the bound is an
    /// absolute **64** rather than the `chunkCount / 20` (1,250) it had to be while sharing a
    /// process.
    ///
    /// **What this test can and cannot see, measured rather than assumed.** Retaining a fixed
    /// number of extra allocations inside each window and reading the ten samples gives:
    ///
    ///     20, 70, 200 one-byte arrays  ->  minimum 2, i.e. not observed at all
    ///     500                          ->  343
    ///     2,000                        ->  1,707
    ///     8,000                        ->  7,845
    ///     one one-byte array per chunk ->  24,894 over 25,000 chunks
    ///     200 one-kilobyte arrays      ->  201-203, every one of them
    ///
    /// The last row identifies the mechanism, and it is the **allocation size**, not a coarse
    /// counter: `malloc_default_zone()` is `DefaultMallocZone` (printed with
    /// `malloc_get_zone_name`), while small allocations on this platform are served by the
    /// separate nano allocator, so they do not enter this zone's `blocks_in_use` one at a
    /// time. Kilobyte allocations bypass nano and are counted exactly, one for one. In bulk
    /// the small ones do surface, but not exactly: the shortfall between retained and counted
    /// is 157, 293, 155 and 106 across the four small-allocation rows — neither constant nor a
    /// multiple of any step — so this comment claims only what the rows show, that small
    /// allocations become visible somewhere between 200 and 500 retained and are then counted
    /// to within a few hundred. Two earlier versions of this paragraph claimed more: one
    /// blamed "the counter's granularity", refuted by the 1-kilobyte row and by the quiet
    /// reading of exactly 1 above; the next named a recurring step "of about 343", refuted by
    /// those four shortfalls.
    ///
    /// So this test sees a leak of large blocks one for one, and a leak of small blocks only
    /// once it reaches the hundreds; it is blind to a handful of small ones, and no choice of
    /// bound changes that. 64 sits above the quiet reading of 1 and below the smallest
    /// small-allocation reading observed — 343, at 500 retained; the 200-to-500 interval was
    /// not sampled, so where inside it the transition happens is not known.
    /// `cursorTraversalSharesLeafStorage` below, which compares storage identity, is the
    /// deterministic defence and depends on none of this.
    ///
    /// The ten windows are kept because they cost nothing and put the whole distribution into
    /// the failure message, which is what made the contamination above diagnosable at all.
    @Test(
        "cursor traversal allocates roughly no more than its own construction, not one per chunk",
        .enabled(if: ProcessInfo.processInfo.environment["PELLICLE_ALLOC_PROBE"] != nil))
    func cursorTraversalAllocatesNothing() {
        let rope = Rope(String(repeating: "abcdefgh", count: 200_000))  // ~1.6 MB, ~25,000 chunks
        // Warm-up pass: absorbs any one-time cost (e.g. the process's own malloc zone
        // growing its own bookkeeping) that would otherwise show up as noise in the
        // measured pass below.
        var warm = rope.makeCursor()
        while warm.next() != nil {}

        func blocksInUse() -> Int {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(malloc_default_zone(), &stats)
            return Int(stats.blocks_in_use)
        }

        var samples: [Int] = []
        var chunkCount = 0
        for _ in 0..<10 {
            let before = blocksInUse()
            var cursor = rope.makeCursor()
            var traversed = 0
            while let chunk = cursor.next() {
                traversed += 1
                _ = chunk.count  // touch, so this cannot be entirely optimised away
            }
            let after = blocksInUse()
            chunkCount = traversed
            samples.append(after - before)
        }
        let delta = samples.min() ?? Int.max
        #expect(chunkCount > 20_000, "expected several thousand chunks, got \(chunkCount)")
        let bound = 64
        let message =
            "the quietest of ten traversals allocated \(delta) additional malloc blocks over "
            + "\(chunkCount) chunks (bound \(bound)) -- expected the cursor's own "
            + "construction and nothing per chunk; all ten windows were \(samples)"
        #expect(delta < bound, "\(message)")
    }

    /// **The defence against "the cursor materialises the current leaf's items into an
    /// array on each descent"** (section 5), replacing `cursorTraversalAllocatesNothing`
    /// above in that role (M1.2 fix round task 4). Deterministic rather than statistical:
    /// compares the *storage identity* of what the cursor holds against the tree's own leaf
    /// arrays, via `SumTreeCursor.currentLeafBaseAddress` (a test-only `@testable`-visible
    /// hook — see its doc comment) and `withUnsafeBufferPointer { $0.baseAddress }` on the
    /// leaf arrays reached by walking the tree directly. If the cursor shares the tree's
    /// storage, the addresses are equal; if a descent copies (`Array(items)`, say, instead
    /// of `items`), the copy gets a new buffer and the addresses differ — regardless of
    /// whether the copy is later freed, which is exactly the case the net-counter test above
    /// cannot see.
    ///
    /// Builds a multi-leaf tree (a few hundred one-byte chunks, several times `2B`) so this
    /// exercises more than one leaf transition, walks `Node.leaf` directly (in the same
    /// left-to-right order the cursor visits) to get the expected addresses, then drives a
    /// fresh cursor over the same tree sampling `currentLeafBaseAddress` after every `next()`
    /// and de-duplicating consecutive repeats (many items share one leaf) into the sequence
    /// of leaves actually visited.
    @Test("cursor traversal shares the tree's own leaf storage, never copies it")
    func cursorTraversalSharesLeafStorage() {
        let itemCount = 40 * 2 * 6  // 40 * 2B, B = 6 -- several leaves, one level of leaves
        let chunks: [Chunk] = (0..<itemCount).map { Chunk(bytes: [UInt8(97 + $0 % 26)]) }
        let tree = SumTree<Chunk>(items: chunks)

        func leafArrays(_ node: Node<Chunk>) -> [[Chunk]] {
            switch node {
            case .leaf(let items, _): return [items]
            case .interior(let children, _, _): return children.flatMap(leafArrays)
            }
        }
        let expected = leafArrays(tree.root).map { items in
            items.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
        }
        #expect(expected.count > 1, "expected several leaves, got \(expected.count)")

        var cursor = tree.makeCursor()
        var observed: [UnsafeRawPointer?] = []
        var last: UnsafeRawPointer?? = .none  // outer Optional: "no leaf observed yet"
        var itemsSeen = 0
        while cursor.next() != nil {
            itemsSeen += 1
            let addr = cursor.currentLeafBaseAddress
            if last == nil || addr != last! {
                observed.append(addr)
                last = .some(addr)
            }
        }
        #expect(itemsSeen == itemCount)
        let mismatchMessage =
            "cursor visited leaf storage \(String(describing: observed)) but the tree's own "
            + "leaves are at \(String(describing: expected)) -- a mismatch means the cursor "
            + "copied a leaf instead of sharing the tree's array"
        #expect(observed == expected, "\(mismatchMessage)")
    }

    /// **The `seek` path's own storage-identity defence** (M1.2 fix round task C2):
    /// `cursorTraversalSharesLeafStorage` above only exercises `next()`/`descendLeftmost`.
    /// `descendSeek`'s leaf branch (`SumTreeCursor.swift`) has its own independent
    /// `currentLeaf = items` assignment, which makes the same "shares, does not copy"
    /// promise; nothing previously checked it, so turning that assignment into a copy (e.g.
    /// `currentLeaf = Array(items)`) would pass every other test in this file (functional
    /// correctness is unaffected by copying, and `cursorTraversalAllocatesNothing` has
    /// already disclaimed itself as a defence against exactly this shape of mutation).
    /// Seeks to a representative item in every leaf of a multi-leaf tree (`itemCount / 2`,
    /// the middle) and compares `currentLeafBaseAddress` against that leaf's own array
    /// address, walked directly from the tree exactly as `cursorTraversalSharesLeafStorage`
    /// does above.
    @Test("cursor seek shares the tree's own leaf storage too, not just next()")
    func cursorSeekSharesLeafStorage() {
        let itemCount = 40 * 2 * 6  // 40 * 2B, B = 6 -- several leaves, one level of leaves
        let chunks: [Chunk] = (0..<itemCount).map { Chunk(bytes: [UInt8(97 + $0 % 26)]) }
        let tree = SumTree<Chunk>(items: chunks)

        func leafArrays(_ node: Node<Chunk>) -> [[Chunk]] {
            switch node {
            case .leaf(let items, _): return [items]
            case .interior(let children, _, _): return children.flatMap(leafArrays)
            }
        }
        let leaves = leafArrays(tree.root)
        #expect(leaves.count > 1, "expected several leaves, got \(leaves.count)")

        // Each chunk here is exactly one byte, so a leaf's item index and its cumulative
        // `.utf8` count coincide -- `seek(where: { $0.utf8 > target })` lands on item
        // `target` (0-based) with no further arithmetic needed.
        var cumulative = 0
        for (leafIndex, leaf) in leaves.enumerated() {
            let targetGlobalIndex = cumulative + leaf.count / 2
            var cursor = tree.makeCursor()
            cursor.seek(where: { $0.utf8 > targetGlobalIndex })
            let expectedAddr = leaf.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
            let mismatchMessage =
                "leaf \(leafIndex): seek positioned the cursor at a different leaf array "
                + "than the tree's own -- descendSeek's leaf branch copied instead of sharing"
            #expect(cursor.currentLeafBaseAddress == expectedAddr, "\(mismatchMessage)")
            cumulative += leaf.count
        }
    }
}

/// An independent-oracle conversion suite, added by the main conversation's M1.2
/// mutation pass. Mutation M1 of `dev/specs/m1.2.md` section 5 (flip the conversion
/// predicate from `>` to `>=`) survived the whole suite, and the question that raised
/// -- coverage gap, or equivalent mutant? -- could not be settled by the randomised
/// tests, which sample offsets rather than exhausting them. This suite exhausts them:
/// every scalar-boundary offset of a multi-chunk, multi-line, mixed-scalar-width rope,
/// every ordered pair of positional metrics, checked against counts recomputed by
/// scanning the raw bytes -- never against the rope's own summaries, which would be
/// the summaries checking themselves. It reported 14,409 identical conversions with
/// the predicate both ways, which is what established M1 as **equivalent** rather
/// than uncaught. It stays because exhaustive-offset coverage is worth having
/// regardless of the mutant that prompted it.
@Suite("Conversion oracle")
struct ConversionOracleTests {
    /// Independent oracle: recompute every metric by scanning the raw bytes, then compare
    /// `convert` at EVERY scalar-boundary offset for every ordered metric pair.
    @Test("convert agrees with a byte-scan oracle at every scalar boundary")
    func convertAgreesWithScanOracleAtEveryOffset() {
        // Multi-chunk, multi-line, mixed-width scalars so chunk boundaries land in
        // interesting places. ~40 chunks at 64 bytes.
        let unit = "abc\n\u{00E9}\u{4E2D}\u{1F600}xy\n"
        let text = String(repeating: unit, count: 160)
        let rope = Rope(text)
        let bytes = Array(text.utf8)

        // Oracle: prefix counts per byte offset.
        var utf8At = [Int]()
        var utf16At = [Int]()
        var scalarsAt = [Int]()
        var isBoundary = [Bool]()
        var u16 = 0
        var sc = 0
        for i in 0...bytes.count {
            let cont = i < bytes.count && (bytes[i] & 0xC0) == 0x80
            isBoundary.append(!cont)
            utf8At.append(i)
            utf16At.append(u16)
            scalarsAt.append(sc)
            if i < bytes.count && !cont {
                sc += 1
                u16 += (bytes[i] & 0xF8) == 0xF0 ? 2 : 1
            }
        }
        func oracle(_ m: TextMetric, at i: Int) -> Int {
            switch m {
            case .utf8: return utf8At[i]
            case .utf16: return utf16At[i]
            case .scalars: return scalarsAt[i]
            case .lines: return bytes[0..<i].filter { $0 == 0x0A }.count
            }
        }
        let positional: [TextMetric] = [.utf8, .utf16, .scalars]
        for i in 0...bytes.count where isBoundary[i] {
            for from in positional {
                for to in positional {
                    let got = rope.convert(offset: oracle(from, at: i), from: from, to: to)
                    #expect(got == oracle(to, at: i), "i=\(i) \(from)->\(to)")
                }
            }
        }
    }
}
