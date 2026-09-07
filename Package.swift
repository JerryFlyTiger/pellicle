// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "pellicle",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "pellicle", targets: ["App"]),
        .library(name: "SelfTestProbe", type: .dynamic, targets: ["SelfTestProbe"]),
    ],
    targets: [
        .target(
            name: "CPlatform"
        ),
        .target(
            name: "Platform",
            dependencies: ["CPlatform"]
        ),
        .target(
            name: "Text",
            dependencies: ["Platform"]
        ),
        .target(
            name: "Lisp",
            dependencies: ["Platform", "Text"]
        ),
        .target(
            name: "Editor",
            dependencies: ["Text", "Lisp"]
        ),
        .target(
            name: "Canvas",
            dependencies: ["Editor", "Text"]
        ),
        .target(
            name: "Terminal",
            dependencies: ["Editor", "Platform"]
        ),
        .target(
            name: "Lang",
            dependencies: ["Editor", "Lisp"]
        ),
        .target(
            name: "Org",
            dependencies: ["Editor", "Lisp"]
        ),
        .target(
            name: "Git",
            dependencies: ["Editor", "Lisp"]
        ),
        .target(
            name: "Extensions",
            dependencies: ["Lisp", "Editor", "Platform"]
        ),
        .target(
            name: "Chrome",
            dependencies: ["Canvas", "Terminal", "Editor"]
        ),
        .executableTarget(
            name: "App",
            dependencies: ["Chrome", "Platform"]
            // No linkerSettings: CLAUDE.md, PLAN.md 4.2 and dev/check-inlining.sh's own
            // header all state the package builds with no unsafeFlags of any kind.
            // SelfTestProbe is loaded with `dlopen` at an absolute path computed at
            // runtime (Sources/Platform/SelfTest.swift), not linked, so no rpath is
            // load-bearing here. See dev/make-app-bundle.sh's header comment for the
            // full explanation of the route taken, and for when to reintroduce one.
        ),
        .target(
            name: "SelfTestProbe"
        ),
        .testTarget(
            name: "TextTests",
            dependencies: ["Text"]
        ),
        .testTarget(
            name: "LispTests",
            dependencies: ["Lisp"]
        ),
        .testTarget(
            name: "EditorTests",
            dependencies: [
                "Platform", "Text", "Lisp", "Editor", "Canvas", "Terminal", "Lang", "Org",
                "Git", "Extensions", "Chrome", "App",
            ]
        ),
        .testTarget(
            name: "PlatformTests",
            dependencies: ["Platform", "CPlatform"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
