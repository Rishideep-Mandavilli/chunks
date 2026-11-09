import Foundation

// A deliberately tiny test harness.
//
// Why not XCTest or swift-testing? Both require a full Xcode install; this machine has
// only CommandLineTools, where XCTest.framework is absent and swift-testing's macro
// plugin is not on SwiftPM's search path. Rather than symlinking into /Library (which
// breaks on any CLT reinstall), Chunks carries its own harness.
//
// It is ~120 lines, has no dependencies, and runs anywhere Swift compiles.
// To move to swift-testing later: delete this file, swap the `Tests/` target for a
// `.testTarget`, and change `import ChunksTestHarness` to `import Testing`.

// MARK: - Assertions

public struct TestFailure: Error, CustomStringConvertible {
    public let message: String
    public let file: String
    public let line: Int
    public var description: String { "\(file):\(line) — \(message)" }
}

/// Assert a condition.
///
/// Returns `Void` on purpose. Returning `Bool` tempts `return expect(...)` inside a
/// `guard ... else`, which does not compile in a `Void` closure — and that pattern
/// recurred enough to be worth removing at the source rather than working around.
public func expect(_ condition: Bool,
                   _ message: @autoclosure () -> String = "condition was false",
                   file: StaticString = #filePath,
                   line: UInt = #line) {
    if !condition {
        TestRunner.record(.failure(TestFailure(message: message(), file: "\(file)", line: Int(line))))
    }
}

public func expectEqual<T: Equatable>(_ actual: T,
                                      _ expected: T,
                                      _ message: @autoclosure () -> String = "",
                                      file: StaticString = #filePath,
                                      line: UInt = #line) {
    if actual != expected {
        let detail = message()
        TestRunner.record(.failure(TestFailure(
            message: detail.isEmpty
                ? "expected \(expected) but got \(actual)"
                : "\(detail) — expected \(expected), got \(actual)",
            file: "\(file)", line: Int(line))))
    }
}

@discardableResult
public func expectThrows(_ body: () throws -> Void,
                         file: StaticString = #filePath,
                         line: UInt = #line) -> Bool {
    do {
        try body()
        TestRunner.record(.failure(TestFailure(message: "expected a thrown error, none was thrown",
                                               file: "\(file)", line: Int(line))))
        return false
    } catch {
        return true
    }
}

/// Say that this check could not run, and why.
///
/// Not a pass, and not a failure: the machine was missing something. The summary counts it
/// separately so nobody can read a green number as full coverage.
public func skipTest(_ reason: String) {
    TestRunner.record(.skipped(reason))
}

// MARK: - Runner

public final class TestRunner {
    public struct Case { public let suite: String; public let name: String; public let body: () -> Void }

    /// A check that did not run is not a check that passed.
    ///
    /// The harness used to have no way to say "skipped", so a test that needed a permission wrote
    /// `expect(true, "skipped: no Screen Recording permission")` and the suite reported green while
    /// the only assertion that could catch the `CGDisplayPixelsWide` class of bug never ran.
    enum Outcome { case pass(String); case failure(TestFailure); case skipped(String) }

    nonisolated(unsafe) static private var registered: [Case] = []
    nonisolated(unsafe) static private var outcomes: [Outcome] = []
    nonisolated(unsafe) static public var currentSuite: String = "Tests"

    public static func add(suite: String, name: String, _ body: @escaping () -> Void) {
        registered.append(Case(suite: suite, name: name, body: body))
    }

    static func record(_ o: Outcome) { outcomes.append(o) }

    public static func reset() { outcomes.removeAll() }

    @discardableResult
    public static func run() -> Bool {
        outcomes.removeAll()
        var currentSuite = ""
        var skippedNames: [String] = []
        var failedTests = 0
        for c in registered {
            if c.suite != currentSuite {
                currentSuite = c.suite
                print("\n\(currentSuite)")
            }
            let before = outcomes.count
            c.body()
            let newOutcomes = Array(outcomes[before...])
            let failures = newOutcomes.compactMap { entry -> TestFailure? in
                if case .failure(let f) = entry { return f } else { return nil }
            }
            let skips = newOutcomes.compactMap { entry -> String? in
                if case .skipped(let reason) = entry { return reason } else { return nil }
            }
            if failures.isEmpty && !skips.isEmpty {
                print("  ⊘ \(c.name) — \(skips.first!)")
                skippedNames.append("\(c.suite): \(c.name)")
            } else if failures.isEmpty {
                print("  ✓ \(c.name)")
            } else {
                failedTests += 1
                print("  ✗ \(c.name)")
                for f in failures { print("      \(f)") }
            }
        }
        let failures = outcomes.compactMap { entry -> TestFailure? in
            if case .failure(let f) = entry { return f } else { return nil }
        }
        let total = registered.count
        let ran = total - skippedNames.count
        // Per-test, not per assertion site: one test with three failing expects used to subtract
        // three from the headline, so "N/M passed" drifted from the suite's real health (F-08).
        print("\n\(ran - failedTests)/\(total) passed" + (skippedNames.isEmpty ? "" : ", \(skippedNames.count) SKIPPED"))
        if !skippedNames.isEmpty {
            // Printed every time, not hidden behind a flag: a green number that quietly excludes
            // checks is how a suite stops meaning anything.
            print("these checks did not run on this machine:")
            for name in skippedNames { print("  ⊘ \(name)") }
        }
        if failures.isEmpty {
            print(skippedNames.isEmpty ? "all tests passed" : "nothing failed — but see the skips above")
            return true
        }
        print("\(failures.count) assertion failure(s)")
        return false
    }
}

// MARK: - Declaration sugar

/// Set the suite name that subsequent `test()` calls belong to.
public func suite(_ name: String) {
    TestRunner.currentSuite = name
}

/// Declare a case within the current suite.
public func test(_ name: String, _ body: @escaping () -> Void) {
    TestRunner.add(suite: TestRunner.currentSuite, name: name, body)
}

/// Declare an async case within the current suite.
///
/// The runner drains each case through a semaphore at run time rather than making the whole
/// runner `async`, so `runAllChunksTests()` stays callable from a synchronous `main`.
public func asyncTest(_ name: String, _ body: @escaping () async -> Void) {
    TestRunner.add(suite: TestRunner.currentSuite, name: name) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await body()
            semaphore.signal()
        }
        semaphore.wait()
    }
}
