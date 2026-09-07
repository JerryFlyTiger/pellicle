import Foundation
import Testing

@testable import Platform

@Suite("Signposts")
struct SignpostsTests {
    @Test("all named handles are constructible")
    func handlesConstructible() {
        // Reaching this line without trapping is most of the test: each is a lazily
        // initialized static, so a bad OSLog construction would trap here.
        _ = Signposts.input
        _ = Signposts.redisplay
        _ = Signposts.parse
        _ = Signposts.lsp
        _ = Signposts.gc
        #expect(Bool(true))
    }

    @Test("PELLICLE_SIGNPOSTS=0 selects the disabled log")
    func envVarDisables() throws {
        // Signposts.isEnabled is a static let, decided once at process startup, so this
        // test cannot flip it live for the current process. Instead it spawns a child
        // `swift test`-adjacent process is overkill; the property itself reads the
        // environment with the same logic under test, so exercise that logic directly
        // via a fresh process environment snapshot is not possible for a `let`. What is
        // testable in-process is the pure decision function the static forwards to.
        #expect(Signposts.isEnabledGiven(environment: ["PELLICLE_SIGNPOSTS": "0"]) == false)
        #expect(Signposts.isEnabledGiven(environment: [:]) == true)
        #expect(Signposts.isEnabledGiven(environment: ["PELLICLE_SIGNPOSTS": "1"]) == true)
    }
}
