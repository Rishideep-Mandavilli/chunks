import Foundation
import ChunksTestHarness
import ChunksTestCases

// `chunks-test` — runs every registered case and exits non-zero on failure.
// Swap this for `swift test` once full Xcode is installed; see Tests/ChunksTestHarness.

let ok = runAllChunksTests()
exit(ok ? 0 : 1)
