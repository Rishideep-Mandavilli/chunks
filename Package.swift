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
    platforms: [.macOS(.v14)],   // ScreenCaptureKit floor. Apple Speech 26+ APIs gate at runtime.
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
