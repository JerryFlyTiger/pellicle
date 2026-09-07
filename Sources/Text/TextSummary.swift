/// The rope's leaf-and-node monoid (PLAN.md 4.5): a fixed-size summary of a run of UTF-8
/// bytes, cheap enough to cache at every `SumTree` node and fold on every combine.
///
/// All three line-length fields (`firstLineLen`, `lastLineLen`, `maxLineLen`) are counted
/// in **UTF-8 bytes**, not scalars or UTF-16 units — the rope is byte-indexed (see
/// `Rope.swift`), and these fields exist to support that indexing.
///
/// `scalars` counts Unicode scalar values (code points). It is a deliberate addition to
/// the sketch in PLAN.md 4.5, which lists only utf8/utf16/lines/firstLineLen/lastLineLen/
/// maxLineLen. Emacs buffer positions count characters (code points), not UTF-16 code
/// units, so M5 (the Elisp engine, which must report `point` the way Emacs does) needs a
/// scalar count on every summary; adding it after the fact would mean walking every leaf
/// in every rope in the project to recompute it. `utf16` is kept alongside it because the
/// LSP protocol's positions are UTF-16 code units.
///
/// Known gap: no character-, UTF-16- or line-based *conversion* API. `TextSummary` carries
/// the counts a conversion would need, but turning a byte offset into a line/column or a
/// UTF-16 offset (and back) is M1.2's job, not this sub-milestone's.
package struct TextSummary: Sendable, Equatable {
    /// Bytes of UTF-8 text.
    package var utf8: Int
    /// UTF-16 code units — the unit the LSP protocol uses for positions.
    package var utf16: Int
    /// Unicode scalars (code points) — Emacs buffer/character positions count these.
    package var scalars: Int
    /// Count of `"\n"` bytes. The number of lines in the text is `lines + 1`.
    package var lines: Int
    /// UTF-8 bytes before the first `"\n"` (or all of `utf8`, if `lines == 0`).
    package var firstLineLen: Int
    /// UTF-8 bytes after the last `"\n"` (or all of `utf8`, if `lines == 0`).
    package var lastLineLen: Int
    /// UTF-8 bytes in the longest line seen so far.
    package var maxLineLen: Int

    package init(
        utf8: Int = 0,
        utf16: Int = 0,
        scalars: Int = 0,
        lines: Int = 0,
        firstLineLen: Int = 0,
        lastLineLen: Int = 0,
        maxLineLen: Int = 0
    ) {
        self.utf8 = utf8
        self.utf16 = utf16
        self.scalars = scalars
        self.lines = lines
        self.firstLineLen = firstLineLen
        self.lastLineLen = lastLineLen
        self.maxLineLen = maxLineLen
    }
}

extension TextSummary {
    // `Summary` conformance (identity + `+`) is declared in `SumTree.swift`, where the
    // `Summary` protocol itself lives; `identity` is `TextSummary()`, the all-zero value,
    // which is the summary of empty text.

    package static func + (lhs: TextSummary, rhs: TextSummary) -> TextSummary {
        TextSummary(
            utf8: lhs.utf8 + rhs.utf8,
            utf16: lhs.utf16 + rhs.utf16,
            scalars: lhs.scalars + rhs.scalars,
            lines: lhs.lines + rhs.lines,
            firstLineLen: lhs.lines == 0 ? lhs.firstLineLen + rhs.firstLineLen : lhs.firstLineLen,
            lastLineLen: rhs.lines == 0 ? lhs.lastLineLen + rhs.lastLineLen : rhs.lastLineLen,
            maxLineLen: max(lhs.maxLineLen, rhs.maxLineLen, lhs.lastLineLen + rhs.firstLineLen)
        )
    }

    package static func += (lhs: inout TextSummary, rhs: TextSummary) {
        lhs = lhs + rhs
    }
}
