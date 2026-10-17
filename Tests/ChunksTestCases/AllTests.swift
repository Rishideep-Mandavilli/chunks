import ChunksTestHarness

/// Registers every Chunks test case, then runs them.
/// `chunks-test` calls this. Add new suites here as they are written.

public func runAllChunksTests() -> Bool {
    CoordinateSpaceTests.register()
    SecretSweeperTests.register()
    MemoryStoreTests.register()
    MemoryReportTests.register()
    ResponseParserTests.register()
    ProviderRegistryTests.register()
    RetryPolicyTests.register()
    GeminiTransportTests.register()
    RegionResolverTests.register()
    ScreenCaptureTests.register()
    DisplayEnumerationTests.register()
    AnswerPanelTests.register()
    NotchGeometryTests.register()
    PanelShortcutTests.register()
    CircleShortcutTests.register()
    ReadRequestTests.register()
    ActionTests.register()
    SpeechVoiceTests.register()
    SpeechEngineChoiceTests.register()
    TalkArmerTests.register()
    LocalBrainTests.register()
    LocalBrainErrorTests.register()
    return TestRunner.run()
}
