/// Probes for `dev/check-inlining.sh`, the standing regression test for this project's
/// cross-module optimisation convention (PLAN.md 4.2).
///
/// Three shapes, deliberately paired so the check is falsifiable in both directions from a
/// single stock `swift build -c release`:
///
/// - `TextHotProbe` is the `public` promoted shape: a `public` type whose hot member is
///   `@inlinable` and whose storage is `@usableFromInline`. A caller in another module
///   must end up with no reference to it at all.
/// - `TextWarmProbe` is the shape this project actually ships for `SumTreeCursor`: an
///   `@usableFromInline package` type whose hot member is `@inlinable package` — never
///   `public`. Fact 1 in `dev/specs/m1.2-promotion-and-guards.md` measured this identical
///   in speed to the `public` shape (3.49 ns vs 3.56 ns/chunk) with no public API added. A
///   caller in another module must end up with no reference to it at all, same as the hot
///   probe — this is what proves the toolchain still honours the shape `SumTreeCursor`
///   uses, which the hot probe alone cannot: `public` and `@usableFromInline package` are
///   different attributes and either could regress independently.
/// - `TextColdProbe` is the default shape: a `package` type with a plain `package`
///   member. A caller in another module must still emit a real call to it.
///
/// The last is what gives the check teeth: without it, a build in which nothing at all was
/// emitted would pass.
///
/// The body length is load-bearing and must not be "simplified". Measured on this machine
/// (Swift 6.3.3), the optimiser inlines a cross-module call of a body of four statements
/// whether or not it is annotated, inlines an 8-to-16-statement body only when it is
/// `@inlinable`, and inlines neither at 24 statements or more. A shorter probe would pass
/// this check with the annotation deleted, and a longer one would fail it with the
/// annotation present. Twelve statements sits in the middle of the band where the
/// annotation is the only thing that decides. `dev/check-inlining.sh` counts the
/// mixing statements in this file and refuses to run if the body has left that band,
/// so the invariant is enforced where the check that depends on it lives rather than
/// by a constant kept in step by goodwill.
public struct TextHotProbe {
    @usableFromInline let seed: UInt64

    public init(seed: UInt64 = 31) { self.seed = seed }

    @inlinable public func packedByteLength(_ x: UInt64) -> UInt64 {
        var v = x &* seed
        v = (v &* 2_654_435_761) ^ (v >> 1) &+ 0
        v = (v &* 2_654_435_762) ^ (v >> 2) &+ 1
        v = (v &* 2_654_435_763) ^ (v >> 3) &+ 2
        v = (v &* 2_654_435_764) ^ (v >> 4) &+ 3
        v = (v &* 2_654_435_765) ^ (v >> 5) &+ 4
        v = (v &* 2_654_435_766) ^ (v >> 6) &+ 5
        v = (v &* 2_654_435_767) ^ (v >> 7) &+ 6
        v = (v &* 2_654_435_768) ^ (v >> 8) &+ 7
        v = (v &* 2_654_435_769) ^ (v >> 9) &+ 8
        v = (v &* 2_654_435_770) ^ (v >> 10) &+ 9
        v = (v &* 2_654_435_771) ^ (v >> 11) &+ 10
        v = (v &* 2_654_435_772) ^ (v >> 12) &+ 11
        return v
    }
}

@usableFromInline package struct TextWarmProbe {
    @usableFromInline let seed: UInt64

    package init(seed: UInt64 = 31) { self.seed = seed }

    /// Byte-for-byte the same computation as `TextHotProbe.packedByteLength`, so the three
    /// shapes differ only in access level and annotation, never in what they compute.
    @inlinable package func packedByteLength(_ x: UInt64) -> UInt64 {
        var v = x &* seed
        v = (v &* 2_654_435_761) ^ (v >> 1) &+ 0
        v = (v &* 2_654_435_762) ^ (v >> 2) &+ 1
        v = (v &* 2_654_435_763) ^ (v >> 3) &+ 2
        v = (v &* 2_654_435_764) ^ (v >> 4) &+ 3
        v = (v &* 2_654_435_765) ^ (v >> 5) &+ 4
        v = (v &* 2_654_435_766) ^ (v >> 6) &+ 5
        v = (v &* 2_654_435_767) ^ (v >> 7) &+ 6
        v = (v &* 2_654_435_768) ^ (v >> 8) &+ 7
        v = (v &* 2_654_435_769) ^ (v >> 9) &+ 8
        v = (v &* 2_654_435_770) ^ (v >> 10) &+ 9
        v = (v &* 2_654_435_771) ^ (v >> 11) &+ 10
        v = (v &* 2_654_435_772) ^ (v >> 12) &+ 11
        return v
    }
}

package struct TextColdProbe {
    let seed: UInt64

    package init(seed: UInt64 = 31) { self.seed = seed }

    /// Byte-for-byte the same computation as `TextHotProbe.packedByteLength`, so the two
    /// shapes differ only in access level and annotation, never in what they compute.
    package func packedByteLength(_ x: UInt64) -> UInt64 {
        var v = x &* seed
        v = (v &* 2_654_435_761) ^ (v >> 1) &+ 0
        v = (v &* 2_654_435_762) ^ (v >> 2) &+ 1
        v = (v &* 2_654_435_763) ^ (v >> 3) &+ 2
        v = (v &* 2_654_435_764) ^ (v >> 4) &+ 3
        v = (v &* 2_654_435_765) ^ (v >> 5) &+ 4
        v = (v &* 2_654_435_766) ^ (v >> 6) &+ 5
        v = (v &* 2_654_435_767) ^ (v >> 7) &+ 6
        v = (v &* 2_654_435_768) ^ (v >> 8) &+ 7
        v = (v &* 2_654_435_769) ^ (v >> 9) &+ 8
        v = (v &* 2_654_435_770) ^ (v >> 10) &+ 9
        v = (v &* 2_654_435_771) ^ (v >> 11) &+ 10
        v = (v &* 2_654_435_772) ^ (v >> 12) &+ 11
        return v
    }
}
