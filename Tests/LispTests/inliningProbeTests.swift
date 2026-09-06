import Testing

@testable import Lisp

/// The probes exist for `dev/check-inlining.sh`, which asserts on the *emitted code*.
/// These tests pin that the two shapes compute the same thing, so the emitted-code check
/// is comparing two forms of one computation rather than two different ones, and that the
/// body is not silently shortened — its length is what makes the inlining check sensitive
/// to the `@inlinable` annotation at all (see the probe file's header).
@Suite("Lisp inlining probe")
struct LispInliningProbeTests {
    @Test("hot and cold probes agree on every input")
    func hotAndColdAgree() {
        let hot = LispHotProbe()
        let cold = LispColdProbe()
        for x in [UInt64(0), 1, 2, 97, 1_000, 1 << 32, UInt64.max] {
            #expect(hot.packedByteLength(x) == cold.packedByteLength(x))
        }
    }

    @Test("the seed reaches the result")
    func seedMatters() {
        #expect(
            LispHotProbe(seed: 31).packedByteLength(7) != LispHotProbe(seed: 32).packedByteLength(7)
        )
        #expect(
            LispColdProbe(seed: 31).packedByteLength(7)
                != LispColdProbe(seed: 32).packedByteLength(7))
    }

}
