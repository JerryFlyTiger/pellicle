import Testing

@testable import Editor

/// `editorHotProbe` and `editorColdProbe` are the cross-module callers that
/// `dev/check-inlining.sh` disassembles. These tests pin that both loops compute the same
/// thing, so the emitted-code check is comparing two shapes of one computation rather than
/// two different ones.
@Suite("Editor inlining probe")
struct EditorInliningProbeTests {
    @Test("hot and cold cross-module loops agree")
    func hotAndColdAgree() {
        for n in [UInt64(0), 1, 2, 17, 1_000] {
            #expect(editorHotProbe(n) == editorColdProbe(n))
        }
    }

    @Test("the loops actually accumulate")
    func accumulates() {
        #expect(editorHotProbe(0) == 0)
        #expect(editorHotProbe(1) != 0)
        #expect(editorHotProbe(2) != editorHotProbe(1))
    }
}
