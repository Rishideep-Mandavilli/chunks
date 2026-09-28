// swift-tools-version: 6.0
import PackageDescription

// Chunks is built as a SwiftPM package rather than an .xcodeproj.
//
// Why: the app needs AppKit, which needs a running process to exercise, but almost all
// of Chunks is pure logic — coordinate maths, memory file handling, response parsing,
// policy rules. Those deserve fast unit tests, and `swift test` gives them on any
// machine with just CommandLineTools. The AppKit shell stays a thin executable.
//
// Layout:
//   Sources/ChunksKit          all logic, fully unit-tested
//   Sources/Chunks             the AppKit shell (menu bar, panels, overlays)
//   Tests/ChunksTestHarness    ~120-line dependency-free test harness
//   Tests/ChunksTestCases      every test case, as plain functions
//   Tests/ChunksTests          `chunks-test` executable that runs them
//
// Build:  swift build          Run:  swift run chunks-test
// App:    swift build && ./scripts/make-app.sh

let package = Package(
    name: "Chunks",
    // 15.2 is the floor for `SCScreenshotManager.captureImage(in:)`, the one-shot
    // display-agnostic capture Chunks is built on. Going lower would mean reintroducing
    // `SCShareableContent` (deprecated in 26) plus a hand-rolled pixel-buffer-to-CGImage
    // path — strictly more code for a narrower audience. The Phase 4 voice features need
    // macOS 26 anyway and gate at runtime.
    //
    // `.custom` rather than `.v15` because SwiftPM's `.v15` means 15.0, which is below
    // the floor.
    platforms: [.macOS("15.2")],
    products: [
        .library(name: "ChunksKit", targets: ["ChunksKit"]),
        .library(name: "ChunksTestHarness", targets: ["ChunksTestHarness"]),
        .library(name: "ChunksTestCases", targets: ["ChunksTestCases"]),
        .executable(name: "chunks", targets: ["Chunks"]),
        .executable(name: "chunks-test", targets: ["ChunksTests"]),
    ],
    targets: [
        .target(name: "ChunksKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "Chunks",
            dependencies: ["ChunksKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(name: "ChunksTestHarness", path: "Tests/ChunksTestHarness", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "ChunksTestCases",
            dependencies: ["ChunksKit", "ChunksTestHarness"],
            path: "Tests/ChunksTestCases",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ChunksTests",
            dependencies: ["ChunksTestCases"],
            path: "Tests/ChunksTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
