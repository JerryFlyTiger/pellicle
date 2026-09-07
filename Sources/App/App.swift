import AppKit
import Foundation
import Platform
import os

/// App: the .app target: NSApplication delegate, windows, menus, panels. Depends on:
/// Chrome, Platform. (PLAN.md 4.2)
///
/// `--self-test` and `--version` are handled with no `NSApplication` and no window, so
/// `dev/ci.sh` can gate on the self-test's exit code without a display. Any other
/// invocation launches the real GUI: `M0.2` is a real `NSApplication`, a titled window,
/// and a minimal menu with nothing drawn in the content view — the Metal canvas arrives
/// in M6.
package enum AppModule {
    package static let moduleName = "App"
}

private let appLog = OSLog(subsystem: Signposts.subsystem, category: "app")

@main
struct PellicleApp {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--self-test") {
            runSelfTestCLI()
        } else if arguments.contains("--version") {
            print(versionString())
            exit(0)
        } else {
            runGUI()
        }
    }

    /// Runs `SelfTest.run()`, prints one `PASS`/`FAIL` line per check, and exits 0 only
    /// if every check passed. No `NSApplication`, no window — this is the machine-
    /// checkable form `dev/ci.sh` gates on.
    private static func runSelfTestCLI() {
        let checks = SelfTest.run()
        var allPassed = true
        for check in checks {
            let status = check.passed ? "PASS" : "FAIL"
            print("\(status) \(check.name) \(check.detail)")
            if !check.passed {
                allPassed = false
            }
        }
        exit(allPassed ? 0 : 1)
    }

    /// `CFBundleShortVersionString` when running from a bundle; otherwise (running
    /// unbundled, e.g. `.build/debug/pellicle` or `.build/release/pellicle`, where
    /// there is no `Info.plist`) walks up from the running executable looking for the
    /// repository's root `VERSION` file.
    private static func versionString() -> String {
        if let bundled = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            !bundled.isEmpty
        {
            return bundled
        }
        let executableURL =
            Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        var directory = executableURL.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("VERSION")
            if let contents = try? String(contentsOf: candidate, encoding: .utf8) {
                return contents.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        return "unknown"
    }

    @MainActor
    private static func runGUI() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.mainMenu = AppDelegate.buildMainMenu()
        app.run()
    }
}

/// The NSApplication delegate. Owns the self-test/telemetry/watchdog lifecycle and the
/// single main window. M0.2's window is deliberately empty — M6 brings the canvas.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var watchdog: MainActorWatchdog?
    private var metricsSubscriber: MetricsSubscriber?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A failing self-test at GUI launch is logged and does not prevent the window
        // from appearing; --self-test's exit code is the machine-checkable form of this
        // same check.
        for check in SelfTest.run() {
            os_log(
                "self-test %{public}@: %{public}@ (%{public}@)", log: appLog,
                type: check.passed ? .info : .error, check.name,
                check.passed ? "PASS" : "FAIL", check.detail)
        }

        let subscriber = MetricsSubscriber()
        subscriber.start()
        metricsSubscriber = subscriber

        watchdog = MainActorWatchdog()

        window = Self.buildWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        watchdog?.close()
        watchdog = nil
        metricsSubscriber?.close()
        metricsSubscriber = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @MainActor
    private static func buildWindow() -> NSWindow {
        let contentRect = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "pellicle"
        // Remembers its frame across launches under this autosave name.
        window.setFrameAutosaveName("MainWindow")
        return window
    }

    /// A minimal main menu: the `pellicle` application menu (About, Hide, Quit ⌘Q)
    /// and a File menu with Close ⌘W.
    @MainActor
    static func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(
            NSMenuItem(
                title: "About pellicle",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(
            NSMenuItem(
                title: "Hide pellicle", action: #selector(NSApplication.hide(_:)),
                keyEquivalent: "h"))
        appMenu.addItem(
            NSMenuItem(
                title: "Quit pellicle", action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"))

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(
            NSMenuItem(
                title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))

        return mainMenu
    }
}
