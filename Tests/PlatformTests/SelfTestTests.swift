import Testing

@testable import Platform

// The dlopen check's pass/fail logic itself has NO `swift test`-level verification: it
// can only be exercised meaningfully against a signed, entitled bundle (hardened
// runtime + com.apple.security.cs.disable-library-validation), which is dev/ci.sh
// stage 4, not this suite. Per CLAUDE.md, a defence a test cannot observe is said so in
// the test comments rather than pretended: the tests below only check the check's
// *shape* (that it exists, is named "dlopen", and that MAP_JIT behaves as expected
// outside the hardened runtime), not that dlopenCheck() correctly distinguishes an
// allowed dlopen from a denied one.
@Suite("SelfTest")
struct SelfTestTests {
    // Running from `.build/debug` outside any bundle: Bundle.main.privateFrameworksURL
    // is nil there, so this check falls through to the "directory of the running
    // executable" search path. libSelfTestProbe.dylib is not necessarily built or
    // co-located with the test binary, so this test only checks the MAP_JIT check
    // (which needs no bundle at all) and that SelfTest.run() returns exactly the two
    // named checks.
    @Test("run() returns MAP_JIT and dlopen checks")
    func returnsTwoChecks() {
        let checks = SelfTest.run()
        #expect(checks.count == 2)
        #expect(checks.map(\.name) == ["MAP_JIT", "dlopen"])
    }

    // The self-test process itself is not running under the hardened runtime (it is a
    // plain `swift test` binary, unsigned, no entitlements), so MAP_JIT is expected to
    // succeed here exactly as it does for any ordinary ad-hoc-signed / unsigned process
    // — the hardened-runtime denial only shows up once the same check runs from inside
    // the signed, entitled app bundle (see the report's --self-test comparison).
    @Test("MAP_JIT check passes outside the hardened runtime")
    func mapJITPasses() {
        let checks = SelfTest.run()
        let mapJIT = checks.first { $0.name == "MAP_JIT" }
        #expect(mapJIT?.passed == true)
    }
}
