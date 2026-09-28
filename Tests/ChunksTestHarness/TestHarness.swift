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

@discardableResult
public func expect(_ condition: Bool,
                   _ message: @autoclosure () -> String = "condition was false",
                   file: StaticString = #filePath,
                   line: UInt = #line) -> Bool {
    if !condition { TestRunner.record(.failure(TestFailure(message: message(), file: "\(file)", line: Int(line)))) }
    return condition
}

@discardableResult
public func expectEqual<T: Equatable>(_ actual: T,
                                      _ expected: T,
                                      _ message: @autoclosure () -> String = "",
                                      file: StaticString = #filePath,
                                      line: UInt = #line) -> Bool {
    if actual != expected {
        let detail = message()
        TestRunner.record(.failure(TestFailure(
            message: detail.isEmpty
                ? "expected \(expected) but got \(actual)"
                : "\(detail) — expected \(expected), got \(actual)",
            file: "\(file)", line: Int(line))))
        return false
    }
    return true
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

// MARK: - Runner

public final class TestRunner {
    public struct Case { public let suite: String; public let name: String; public let body: () -> Void }

    enum Outcome { case pass(String); case failure(TestFailure) }

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
            if failures.isEmpty {
                print("  ✓ \(c.name)")
            } else {
                print("  ✗ \(c.name)")
                for f in failures { print("      \(f)") }
            }
        }
        let failures = outcomes.compactMap { entry -> TestFailure? in
            if case .failure(let f) = entry { return f } else { return nil }
        }
        let total = registered.count
        print("\n\(total - Set(failures.map { "\($0.file):\($0.line)" }).count)/\(total) passed")
        if failures.isEmpty {
            print("all tests passed")
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
