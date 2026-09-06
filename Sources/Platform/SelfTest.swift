import CPlatform
import Darwin
import Foundation

/// SelfTest: the launch-time self-test proving the two hardened-runtime entitlements
/// that swiftemacs needs actually work on this machine.
///
/// - `com.apple.security.cs.allow-jit`: without it, `mmap(..., MAP_JIT, ...)` fails with
///   `EINVAL` under the hardened runtime (established by the 2026-09-05 spike,
///   `dev/spikes/spike_jit.swift`). The Lisp bytecode VM's future JIT path depends on
///   this working.
/// - `com.apple.security.cs.disable-library-validation`: without it, `dlopen` on an
///   ad-hoc-signed dylib bundled inside the app (`libSelfTestProbe.dylib`, from the
///   `SelfTestProbe` SwiftPM product) is refused by the hardened runtime, because the
///   dylib is not signed by the same team as the main executable (there is no signing
///   identity on this machine at all, so every signature here is ad-hoc). This check
///   proves the entitlement actually lets that load through.
///
/// `--self-test` (see `Sources/App`) runs both checks with no `NSApplication` and no
/// window, so `dev/ci.sh` can gate on the exit code.
package enum SelfTest {
    /// One self-test result: a name, pass/fail, and a one-line detail string used both
    /// for the human-readable `--self-test` output and for the GUI-launch log line.
    package struct Check: Sendable {
        package let name: String
        package let passed: Bool
        package let detail: String

        package init(name: String, passed: Bool, detail: String) {
            self.name = name
            self.passed = passed
            self.detail = detail
        }
    }

    package static func run() -> [Check] {
        [mapJITCheck(), dlopenCheck()]
    }

    // MARK: - MAP_JIT

    private static func mapJITCheck() -> Check {
        let name = "MAP_JIT"
        let size = 16384

        guard
            let raw = mmap(
                nil, size, PROT_READ | PROT_WRITE | PROT_EXEC,
                MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0),
            raw != MAP_FAILED
        else {
            let savedErrno = errno
            return Check(
                name: name, passed: false,
                detail:
                    "mmap(MAP_JIT) failed, errno=\(savedErrno) (\(String(cString: strerror(savedErrno))))"
            )
        }

        // From here on, every path must munmap before returning.
        defer { munmap(raw, size) }

        pthread_jit_write_protect_np(0)
        let code: [UInt32] = [0x5280_0540, 0xD65F_03C0]  // mov w0, #42 ; ret
        raw.withMemoryRebound(to: UInt32.self, capacity: code.count) { p in
            for (i, word) in code.enumerated() { p[i] = word }
        }
        pthread_jit_write_protect_np(1)
        swiftemacs_icache_invalidate(raw, size)

        typealias Fn = @convention(c) () -> Int32
        let fn = unsafeBitCast(raw, to: Fn.self)
        let result = fn()

        guard result == 42 else {
            return Check(
                name: name, passed: false,
                detail: "jit call returned \(result), expected 42")
        }
        return Check(name: name, passed: true, detail: "jit call returned 42 as expected")
    }

    // MARK: - dlopen

    private static func dlopenCheck() -> Check {
        let name = "dlopen"
        let libraryName = "libSelfTestProbe.dylib"
        let symbolName = "swiftemacs_selftest_probe"

        var candidates: [URL] = []
        if let frameworksURL = Bundle.main.privateFrameworksURL {
            candidates.append(frameworksURL.appendingPathComponent(libraryName))
        }
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        candidates.append(executableDirectory.appendingPathComponent(libraryName))

        guard
            let foundPath = candidates.first(where: {
                FileManager.default.fileExists(atPath: $0.path)
            })
        else {
            let searched = candidates.map(\.path).joined(separator: ", ")
            return Check(
                name: name, passed: false,
                detail: "\(libraryName) not found; searched: \(searched)")
        }

        guard let handle = dlopen(foundPath.path, RTLD_NOW | RTLD_LOCAL) else {
            let message = dlerror().map { String(cString: $0) } ?? "unknown dlerror"
            return Check(
                name: name, passed: false,
                detail: "dlopen(\(foundPath.path)) failed: \(message)")
        }
        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, symbolName) else {
            let message = dlerror().map { String(cString: $0) } ?? "unknown dlerror"
            return Check(
                name: name, passed: false,
                detail: "dlsym(\(symbolName)) failed: \(message)")
        }

        typealias Fn = @convention(c) () -> Int32
        let fn = unsafeBitCast(symbol, to: Fn.self)
        let result = fn()

        guard result == 42 else {
            return Check(
                name: name, passed: false,
                detail: "\(symbolName)() returned \(result), expected 42")
        }
        return Check(
            name: name, passed: true,
            detail: "loaded \(foundPath.path), \(symbolName)() returned 42 as expected")
    }
}
