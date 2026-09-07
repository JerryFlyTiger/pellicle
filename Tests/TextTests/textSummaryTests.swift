import Testing

@testable import Text

/// Covers `TextSummary`'s monoid laws (identity, associativity) and the hand-checked line-
/// and scalar-counting cases that its doc comment promises (PLAN.md 4.5).
@Suite("TextSummary")
struct TextSummaryTests {
    /// Computes a `TextSummary` directly from a `String`, deliberately *not* sharing code
    /// with `Chunk.summary` (which is what production code uses), so this is an
    /// independent check rather than the same logic checking itself.
    static func summary(of string: String) -> TextSummary {
        var result = TextSummary()
        var lineStart = 0
        var byteIndex = 0
        let utf8 = Array(string.utf8)
        while byteIndex < utf8.count {
            let byte = utf8[byteIndex]
            result.utf8 += 1
            if byte == 0x0A {
                result.lines += 1
                let lineLen = byteIndex - lineStart
                if result.lines == 1 { result.firstLineLen = lineLen }
                result.maxLineLen = max(result.maxLineLen, lineLen)
                lineStart = byteIndex + 1
            }
            byteIndex += 1
        }
        let lastLen = utf8.count - lineStart
        result.lastLineLen = lastLen
        if result.lines == 0 { result.firstLineLen = lastLen }
        result.maxLineLen = max(result.maxLineLen, lastLen)
        result.scalars = string.unicodeScalars.count
        result.utf16 = string.utf16.count
        return result
    }

    @Test("identity is a left and right identity")
    func identityLaws() {
        let examples = [
            TextSummary(),
            TextSummary(
                utf8: 5, utf16: 5, scalars: 5, lines: 0,
                firstLineLen: 5, lastLineLen: 5, maxLineLen: 5),
            Self.summary(of: "hello\nworld"),
        ]
        for s in examples {
            #expect(TextSummary.identity + s == s)
            #expect(s + TextSummary.identity == s)
        }
    }

    @Test("associativity over hand-built summaries")
    func associativityHandBuilt() {
        let a = Self.summary(of: "ab\n")
        let b = Self.summary(of: "cd")
        let c = Self.summary(of: "\nef\ngh")
        #expect((a + b) + c == a + (b + c))
    }

    static func randomString(_ rng: inout SplitMix64, length: Int) -> String {
        let pool: [Character] = Array("abc\nde\n字é🙂f\r\n\n")
        var s = ""
        for _ in 0..<length {
            s.append(pool[Int(rng.next() % UInt64(pool.count))])
        }
        return s
    }

    @Test("associativity over random splits of random strings")
    func associativityRandomSplits() {
        var rng = SplitMix64(seed: 0x5EED_1234)
        for _ in 0..<200 {
            let length = Int(rng.next() % 40)
            let s = Self.randomString(&rng, length: length)
            let scalars = Array(s.unicodeScalars)
            let splitIndex = scalars.isEmpty ? 0 : Int(rng.next() % UInt64(scalars.count + 1))
            let left = String(String.UnicodeScalarView(scalars[0..<splitIndex]))
            let right = String(String.UnicodeScalarView(scalars[splitIndex...]))
            let whole = Self.summary(of: s)
            let combined = Self.summary(of: left) + Self.summary(of: right)
            #expect(combined == whole, "split of \(s.debugDescription) at scalar \(splitIndex)")
        }
    }

    @Test("empty string")
    func empty() {
        let s = Self.summary(of: "")
        #expect(s == TextSummary())
    }

    @Test("no newline")
    func noNewline() {
        let s = Self.summary(of: "hello")
        #expect(s.lines == 0)
        #expect(s.firstLineLen == 5)
        #expect(s.lastLineLen == 5)
        #expect(s.maxLineLen == 5)
    }

    @Test("leading newline")
    func leadingNewline() {
        let s = Self.summary(of: "\nhello")
        #expect(s.lines == 1)
        #expect(s.firstLineLen == 0)
        #expect(s.lastLineLen == 5)
        #expect(s.maxLineLen == 5)
    }

    @Test("trailing newline")
    func trailingNewline() {
        let s = Self.summary(of: "hello\n")
        #expect(s.lines == 1)
        #expect(s.firstLineLen == 5)
        #expect(s.lastLineLen == 0)
        #expect(s.maxLineLen == 5)
    }

    @Test("two newlines in a row")
    func doubleNewline() {
        let s = Self.summary(of: "\n\n")
        #expect(s.lines == 2)
        #expect(s.firstLineLen == 0)
        #expect(s.lastLineLen == 0)
        #expect(s.maxLineLen == 0)
    }

    @Test("CRLF: \\r is an ordinary byte, does not end a line")
    func crlf() {
        let s = Self.summary(of: "ab\r\ncd\r\n")
        #expect(s.lines == 2)
        #expect(s.firstLineLen == 3)  // "ab\r"
        #expect(s.lastLineLen == 0)
        #expect(s.maxLineLen == 3)
    }

    @Test("multi-byte scalars: utf8 vs utf16 vs scalars disagree")
    func multiByteScalars() {
        // "é" = 2 UTF-8 bytes, 1 UTF-16 unit, 1 scalar.
        let e = Self.summary(of: "é")
        #expect(e.utf8 == 2)
        #expect(e.utf16 == 1)
        #expect(e.scalars == 1)

        // "字" = 3 UTF-8 bytes, 1 UTF-16 unit, 1 scalar.
        let zi = Self.summary(of: "字")
        #expect(zi.utf8 == 3)
        #expect(zi.utf16 == 1)
        #expect(zi.scalars == 1)

        // An emoji with an astral scalar: 4 UTF-8 bytes, 2 UTF-16 units (surrogate pair),
        // 1 scalar.
        let emoji = Self.summary(of: "🙂")
        #expect(emoji.utf8 == 4)
        #expect(emoji.utf16 == 2)
        #expect(emoji.scalars == 1)

        let mixed = Self.summary(of: "aé字🙂")
        #expect(mixed.utf8 == 1 + 2 + 3 + 4)
        #expect(mixed.utf16 == 1 + 1 + 1 + 2)
        #expect(mixed.scalars == 4)
    }

    @Test("long middle line: maxLineLen is neither first nor last")
    func longMiddleLine() {
        let middle = String(repeating: "x", count: 100)
        let s = Self.summary(of: "short\n\(middle)\ntail")
        #expect(s.lines == 2)
        #expect(s.firstLineLen == 5)
        #expect(s.lastLineLen == 4)
        #expect(s.maxLineLen == 100)
    }
}

/// A small, deterministic, seedable `RandomNumberGenerator`. `SystemRandomNumberGenerator`
/// cannot be seeded, so the randomised tests across `Tests/TextTests/` use this instead —
/// SplitMix64 (Vigna), chosen for being a few lines and good enough for test-fixture
/// generation, not for cryptography.
package struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    package init(seed: UInt64) {
        self.state = seed
    }

    package mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
