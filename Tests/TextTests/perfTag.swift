import Foundation
import Testing

/// This project's first performance-test gate. Performance suites are tagged `.performance`
/// and disabled unless `PELLICLE_PERF=1` is set in the environment **and** the build is a
/// release build, so:
///
/// - `swift test` (no env var) **skips** every suite tagged `.performance` — fast, safe for
///   every normal run and for CI.
/// - `PELLICLE_PERF=1 swift test` (debug, the default configuration) still **skips** them:
///   `swift test` always builds in debug, and a perf number from a debug build is not
///   evidence — `swift build -c release --verbose` is the only configuration that passes
///   `-whole-module-optimization` (verified: it appears once there and zero times in the
///   debug build's `--verbose` output on this machine). Every number this suite reports is
///   otherwise measuring `-Onone`, not the optimiser this project ships.
/// - `PELLICLE_PERF=1 swift test -c release` **runs** them.
///
/// Apply it to a suite like this:
/// ```swift
/// @Suite(
///     .tags(.performance),
///     .enabled(if: ProcessInfo.processInfo.environment["PELLICLE_PERF"] != nil && !isDebugBuild))
/// struct RopePerfTests { ... }
/// ```
extension Tag {
    @Tag package static var performance: Self
}

/// `true` in a `swift test`/`swift build -c debug` build, `false` in `-c release`. SwiftPM
/// defines `DEBUG` for the debug configuration and not for release (verified with `swift
/// build --verbose` vs `swift build -c release --verbose`, grepping for `-DDEBUG`); Swift
/// has no *runtime* way to ask "was this compiled with `-O`", so this compile-time flag is
/// the only source of truth available to `.enabled(if:)`.
package let isDebugBuild: Bool = {
    #if DEBUG
        return true
    #else
        return false
    #endif
}()
