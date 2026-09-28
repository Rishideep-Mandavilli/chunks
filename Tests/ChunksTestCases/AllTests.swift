import ChunksTestHarness

/// Registers every Chunks test case, then runs them.
/// `chunks-test` calls this. Add new suites here as they are written.

public func runAllChunksTests() -> Bool {
    CoordinateSpaceTests.register()
    SecretSweeperTests.register()
    MemoryStoreTests.register()
    ResponseParserTests.register()
    ProviderRegistryTests.register()
    RetryPolicyTests.register()
    GeminiTransportTests.register()
    RegionResolverTests.register()
    ScreenCaptureTests.register()
    DisplayEnumerationTests.register()
    AnswerPanelTests.register()
    return TestRunner.run()
}
