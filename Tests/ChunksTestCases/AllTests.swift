import ChunksTestHarness

/// Registers every Chunks test case, then runs them.
/// `chunks-test` calls this. Add new suites here as they are written.

public func runAllChunksTests() -> Bool {
    CoordinateSpaceTests.register()
    SecretSweeperTests.register()
    MemoryStoreTests.register()
    ResponseParserTests.register()
    return TestRunner.run()
}
