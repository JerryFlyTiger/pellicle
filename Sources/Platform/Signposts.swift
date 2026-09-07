import Foundation
import os

/// Signposts: `os_signpost` handles behind a disable-able `OSLog`, one per subsystem
/// boundary named in PLAN.md 4.14 rule 14 ("os_signpost intervals around every subsystem
/// boundary ... behind a disable-able OSLog handle").
///
/// Every signposter shares the subsystem string `app.pellicle`; the category
/// distinguishes the boundary. Whether logging is active is decided once, at process
/// startup, from the `PELLICLE_SIGNPOSTS` environment variable (`0` disables), rather
/// than checked on every signpost call — that check is not on the hot path.
package enum Signposts {
    /// The subsystem string every `OSSignposter` here shares.
    package static let subsystem = "app.pellicle"

    /// Whether signposts are active, decided once at startup so the hot path never
    /// re-reads the environment. `PELLICLE_SIGNPOSTS=0` disables.
    package static let isEnabled: Bool = isEnabledGiven(
        environment: ProcessInfo.processInfo.environment)

    /// The pure decision `isEnabled` forwards to, exposed separately so a test can check
    /// the `PELLICLE_SIGNPOSTS=0` logic without depending on the current process's
    /// actual environment (which the `static let` above already captured once).
    package static func isEnabledGiven(environment: [String: String]) -> Bool {
        environment["PELLICLE_SIGNPOSTS"] != "0"
    }

    private static func makeLog(category: String) -> OSLog {
        isEnabled ? OSLog(subsystem: subsystem, category: category) : .disabled
    }

    /// Key received to frame committed, and the phases of the input pipeline.
    package static let input = OSSignposter(logHandle: makeLog(category: "input"))
    /// Layout and paint of the display snapshot.
    package static let redisplay = OSSignposter(logHandle: makeLog(category: "redisplay"))
    /// Tree-sitter parse and incremental reparse.
    package static let parse = OSSignposter(logHandle: makeLog(category: "parse"))
    /// LSP request/response round trips.
    package static let lsp = OSSignposter(logHandle: makeLog(category: "lsp"))
    /// Lisp GC slices.
    package static let gc = OSSignposter(logHandle: makeLog(category: "gc"))
}
