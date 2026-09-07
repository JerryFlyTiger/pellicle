/// The rope's leaf payload (PLAN.md 4.5): up to 64 bytes of UTF-8 text stored inline, with
/// no heap allocation.
///
/// Invariant, enforced with `precondition` at every initializer that takes bytes: a chunk
/// holds `1...64` bytes, and those bytes are a whole number of UTF-8 scalars — a chunk
/// never ends in the middle of a multi-byte sequence. An empty chunk must never be stored
/// in the tree; `Rope`'s chunking policy (see `Rope.swift`) is responsible for merging
/// runs that would otherwise produce one.
///
/// `MemoryLayout<Chunk>.stride` was 65 on this machine before the summary cache below was
/// added (an `InlineArray<64, UInt8>` plus a `UInt8` count, no padding); see the
/// implementer's report for the measured stride with `packedSummary` included.
package struct Chunk: Sendable {
    // `private(set)`, not `var`: before the summary cache existed, a stale `packedSummary`
    // was structurally impossible because `summary` recomputed from `bytes`/`count` on every
    // read. Now that it is cached, an external `c.count = 3` would desync the cache silently
    // (only caught after the fact by `Rope.checkTreeInvariants()`'s stale-cache check, not
    // prevented). Read access stays `package`; only `init` can set these.
    package private(set) var bytes: InlineArray<64, UInt8>
    package private(set) var count: UInt8

    /// The chunk's summary, computed once at `init` and packed into seven `UInt8`s rather
    /// than a full `TextSummary` (measured: storing a `TextSummary` — 56 bytes — takes
    /// `MemoryLayout<Chunk>.stride` from 65 to 128 through alignment padding, doubling leaf
    /// memory; every field of a chunk's summary fits in a `UInt8` because a chunk holds at
    /// most 64 bytes). `summary` (below) expands this on read; the packing/unpacking cost is
    /// negligible next to the byte-scan it replaces (`Chunk.summary` used to walk the
    /// chunk's bytes on every access — measured: one single-byte rope insert recomputed
    /// 512-826 chunk summaries from bytes, see `M1.1-perf-findings.md`).
    private var packedSummary: PackedChunkSummary

    /// Builds a chunk from up to 64 bytes, already known to end on a scalar boundary.
    /// Traps (via `precondition`) if `bytes` is empty, longer than 64 bytes, or does not
    /// end on a UTF-8 scalar boundary.
    package init(bytes sourceBytes: some Collection<UInt8>) {
        let n = sourceBytes.count
        precondition((1...64).contains(n), "Chunk must hold 1...64 bytes, got \(n)")
        precondition(
            Chunk.endsOnScalarBoundary(sourceBytes),
            "Chunk must not end in the middle of a UTF-8 scalar"
        )
        var storage = InlineArray<64, UInt8>(repeating: 0)
        var i = 0
        for byte in sourceBytes {
            storage[i] = byte
            i += 1
        }
        self.bytes = storage
        self.count = UInt8(n)
        self.packedSummary = PackedChunkSummary(
            packing: Chunk.scanSummary(storage, count: UInt8(n)))
    }

    /// True if `bytes` does not end with a truncated multi-byte UTF-8 sequence: the last
    /// byte is either itself a complete (ASCII or continuation-terminated) scalar's last
    /// byte. We check this by scanning back from the end for a lead byte and confirming
    /// the expected sequence length fits within the bytes we have.
    private static func endsOnScalarBoundary(_ sourceBytes: some Collection<UInt8>) -> Bool {
        let bytes = Array(sourceBytes)
        guard !bytes.isEmpty else { return true }
        // Walk back from the end to find the most recent lead byte (top bits not 10xxxxxx).
        var i = bytes.count - 1
        var continuationCount = 0
        while i >= 0 && (bytes[i] & 0b1100_0000) == 0b1000_0000 {
            continuationCount += 1
            i -= 1
        }
        guard i >= 0 else { return false }
        let lead = bytes[i]
        let expectedLength: Int
        if lead & 0b1000_0000 == 0 {
            expectedLength = 1
        } else if lead & 0b1110_0000 == 0b1100_0000 {
            expectedLength = 2
        } else if lead & 0b1111_0000 == 0b1110_0000 {
            expectedLength = 3
        } else if lead & 0b1111_1000 == 0b1111_0000 {
            expectedLength = 4
        } else {
            return false
        }
        return expectedLength == continuationCount + 1
    }

    /// Byte access over `0..<Int(count)`, allocation-free.
    package subscript(i: Int) -> UInt8 {
        precondition(i >= 0 && i < Int(count), "Chunk subscript \(i) out of range")
        return bytes[i]
    }

    /// Allocation-free access to the chunk's valid bytes.
    package func withUnsafeBytes<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows
        -> R
    {
        try bytes.span.withUnsafeBufferPointer { buffer in
            try body(UnsafeBufferPointer(rebasing: buffer[0..<Int(count)]))
        }
    }

    /// The summary of this chunk's bytes: O(1), expanded from the packed cache computed
    /// once at `init`. Was a byte-scan on every access before Part D of M1.1's fix round;
    /// see `packedSummary`'s doc comment.
    package var summary: TextSummary { packedSummary.expanded }

    /// Recomputes the summary directly from the chunk's bytes, bypassing the cache
    /// entirely. Exists only so a checker (`Rope.checkTreeInvariants()`) can confirm the
    /// cache agrees with the bytes it is supposed to summarise — a stale cache would
    /// otherwise be undetectable and would silently corrupt every ancestor summary in the
    /// tree. Not `summary`'s implementation: that would defeat the cache it is checking.
    package func recomputedSummaryFromBytes() -> TextSummary {
        Chunk.scanSummary(bytes, count: count)
    }

    /// The one-pass byte scan `summary` used to do on every access. Takes the raw storage
    /// directly (rather than `self`) so `init` can compute the packed cache before any
    /// stored property is fully assigned.
    private static func scanSummary(_ storage: InlineArray<64, UInt8>, count: UInt8) -> TextSummary
    {
        var s = TextSummary()
        storage.span.withUnsafeBufferPointer { full in
            let buffer = UnsafeBufferPointer(rebasing: full[0..<Int(count)])
            var lineStart = 0
            var i = 0
            while i < buffer.count {
                let byte = buffer[i]
                s.utf8 += 1
                if byte == 0x0A {
                    s.lines += 1
                    let lineLen = i - lineStart
                    if s.lines == 1 { s.firstLineLen = lineLen }
                    s.maxLineLen = max(s.maxLineLen, lineLen)
                    lineStart = i + 1
                }
                // UTF-16 and scalar counts: count one scalar (and its UTF-16 width) each
                // time we see a lead byte (top bits not 10xxxxxx).
                if byte & 0b1100_0000 != 0b1000_0000 {
                    s.scalars += 1
                    // 4-byte UTF-8 sequences (lead byte 0b1111_0xxx) encode astral
                    // scalars, which are 2 UTF-16 code units (a surrogate pair); every
                    // other lead byte is 1 UTF-16 code unit.
                    if byte & 0b1111_1000 == 0b1111_0000 {
                        s.utf16 += 2
                    } else {
                        s.utf16 += 1
                    }
                }
                i += 1
            }
            let lastLen = buffer.count - lineStart
            s.lastLineLen = lastLen
            if s.lines == 0 {
                s.firstLineLen = lastLen
            }
            s.maxLineLen = max(s.maxLineLen, lastLen)
        }
        return s
    }
}

/// `Chunk.summary`'s cache, packed into seven `UInt8`s instead of a `TextSummary`'s seven
/// `Int`s — see `Chunk.packedSummary`'s doc comment for why. Every field of a chunk's
/// summary (a chunk holds at most 64 bytes) fits in a `UInt8`.
private struct PackedChunkSummary: Sendable, Equatable {
    var utf8: UInt8 = 0
    var utf16: UInt8 = 0
    var scalars: UInt8 = 0
    var lines: UInt8 = 0
    var firstLineLen: UInt8 = 0
    var lastLineLen: UInt8 = 0
    var maxLineLen: UInt8 = 0

    init() {}

    init(packing s: TextSummary) {
        utf8 = UInt8(s.utf8)
        utf16 = UInt8(s.utf16)
        scalars = UInt8(s.scalars)
        lines = UInt8(s.lines)
        firstLineLen = UInt8(s.firstLineLen)
        lastLineLen = UInt8(s.lastLineLen)
        maxLineLen = UInt8(s.maxLineLen)
    }

    var expanded: TextSummary {
        TextSummary(
            utf8: Int(utf8), utf16: Int(utf16), scalars: Int(scalars), lines: Int(lines),
            firstLineLen: Int(firstLineLen), lastLineLen: Int(lastLineLen),
            maxLineLen: Int(maxLineLen))
    }
}

// `Summable` conformance (the `Item_Summary` typealias; `summary` is already defined
// above) is declared once `SumTree.swift` has introduced the `Summable` protocol.
