# Chunks — Agent Instructions

<!-- Single source of truth for AI coding agents working in this repo. -->

## What Chunks is

A native macOS menu-bar companion that **sees your screen, explains it, and helps you act
on it** — by voice. Circle a region, get an explanation of that region. Ask where a
button is, watch a cursor fly to it. Tell it to do something, confirm, it acts.

## What Chunks is NOT

Hard scope boundaries. These are not "nice to have later" — they are out:

- ❌ **No agents or sub-agents.** No Codex, no Claude Code, no agent runtime.
- ❌ **No code generation.** Chunks explains and points; it does not build things.
- ❌ **No file artifact generation.** No PDFs, decks, websites, or documents as output.
- ❌ **No skills marketplace.** No persona economy, no community catalogue.
- ✅ **Automations are in scope** (`launchd`), read-only by default.

If a change would add any of the above, it is out of scope. Say so rather than adding it.

## Architecture

```
Sources/ChunksKit     all logic — pure, unit-tested, no UI
  Capture/            CoordinateSpace is the ONLY type allowed to convert coords
  Memory/             MemoryStore, SecretSweeper
  Brain/              provider registry, transports, response parsing
  Annotate/           strokes, region resolution
  Action/             AXTDriver, PolicyGate, ConsentGate
Sources/Chunks        the AppKit shell — status item, panels, overlays
Tests/                harness + cases, run via `chunks-test`
```

**The split is deliberate.** Almost all of Chunks is pure logic; only the shell needs a
running AppKit process. Keeping them apart means the logic is testable on any machine
with CommandLineTools.

## Build & test

```bash
swift build              # build everything
swift run chunks-test    # run all tests  (NOT `swift test` — see below)
```

### Why not `swift test` / XCTest / swift-testing

This machine has CommandLineTools, not full Xcode:
- `XCTest.framework` is absent → `import XCTest` fails to resolve.
- swift-testing's `TestingMacros` plugin sits in a subdirectory SwiftPM doesn't scan.

Rather than symlink into `/Library` (which breaks on any CLT reinstall), Chunks ships a
~120-line harness in `Tests/ChunksTestHarness/`.

**To migrate to swift-testing** once full Xcode is installed: delete `TestHarness.swift`,
change the three test targets in `Package.swift` to a single `.testTarget`, and replace
`import ChunksTestHarness` with `import Testing`. The `expect`/`expectEqual` call sites
map almost 1:1 onto `#expect(...)`.

## Invariants — do not break these

1. **All coordinates are `LogicalPoint`.** Screenshots are device pixels (2x); AX reports
   logical points; `NSPanel` frames are logical. Conversion happens exactly once, inside
   `CoordinateSpace` or `ScreenCapture`. Feeding an AX `frame` into a pixel-based call
   lands at double the intended offset on Retina, and it fails *silently*. See the comment
   on `CoordinateSpace`.

   Two traps this codebase has already fallen into, both of which produce a plausible
   number rather than an error:
   - `CGDisplayPixelsWide` returns **points**, not pixels. Use
     `NSScreen.backingScaleFactor`.
   - `CGDisplayBounds` is **top-left** origin. `NSScreen.frame` is bottom-left. Never mix.

2. **The model never writes the memory file.** It emits a proposed block; `MemoryWriter`
   validates and merges. This is structural, not advisory — it is why credentials cannot
   reach disk. Do not "simplify" this into letting the model append text.

3. **Secrets are rejected before any write.** `SecretSweeper` runs on every proposed fact.
   Rejected facts are reported to the user, never silently dropped, and never truncated
   into the file.

4. **Memory is capped at 2 KB and never truncated.** At the cap, writes are *refused and
   the user is asked*. `isFull` reserves headroom so the warning lands before refusals do.

5. **Never send an image to a model that cannot see images.** The provider registry
   carries `visionCapable: Bool?` — `nil` means *unknown*, resolved by runtime probe.
   Degrade loudly ("Muse Spark can't see images, switching to X"), never silently.

6. **Retries are mandatory.** Gemini free tier returns `503 high demand` on roughly half
   of requests against the newest flash models, and caps at ~5 req/min. `BrainClient`
   must do exponential backoff plus a model fallback chain. A turn that fails on 503 is a
   bug, not bad luck.

## Style

- Clear beats clever. Long, specific names — `originalQuestionLastAnsweredDate`, not
  `origAnswered`. No single-character identifiers.
- Comments explain **why**, not what. Especially for AppKit bridging and coordinate maths.
- SwiftUI unless something is AppKit-only (`NSPanel` for floating windows).
- All UI state on `@MainActor`. `async`/`await` for anything asynchronous.
- Match the surrounding file's conventions; don't refactor code you weren't asked to touch.

## Testing expectations

- Every non-trivial pure-logic change gets a test in `Tests/ChunksTestCases/`, registered
  in `AllTests.swift`.
- Coordinate changes need round-trip coverage at 1x, 2x, and 3x.
- `SecretSweeper` and `MemoryStore` need negative cases — including "this ordinary fact
  must NOT be rejected".
- Tests are assertions with messages, not XCTest cases.

## Current state

**The app runs. 142 tests green across 10 suites.**

Done and tested:

| Component | File | Notes |
|---|---|---|
| Coordinate authority | `Capture/CoordinateSpace.swift` | The only type allowed to convert coords |
| Screen capture | `Capture/CaptureEngine.swift` | `SCScreenshotManager.captureImage(in:)`; scale measured |
| Secret rejection | `Memory/SecretSweeper.swift` | 12 provider prefixes + entropy heuristic |
| Memory store | `Memory/MemoryStore.swift` | Plain markdown, 2 KB cap, never truncated |
| Reply protocol | `Brain/ResponseParser.swift` | Streaming `[POINT]` / `<SAY>` / `<MEMORY>` / `<NOTE>` |
| Provider registry | `Brain/ProviderRegistry.swift` | Capability profiles, `visionCapable: Bool?` |
| Retry + rate limit | `Brain/RetryPolicy.swift` | Backoff with jitter, token bucket |
| Request/SSE | `Brain/GeminiTransport.swift` | Pure builders; `store:false` enforced by test |
| Region resolution | `Annotate/RegionResolver.swift` | Marks → padded, clamped crop rect |

Running: menu bar item, ⌃⌥ hotkey, whole-screen and circle-to-explain turns, cursor
move to a pointed-at control, Keychain-backed API key, annotation overlay with pen /
circle / box / arrow.

**Not yet built** — the parts that need a human looking at them:

- Voice in/out — `SpeechTranscriber` (macOS 26+). ⌃⌥ currently runs the turn with the
  default question rather than dictating one.
- The on-screen answer panel. Replies currently land in `transcript` and the menu; there
  is nothing to read while the model is talking.
- Computer use — `AXTDriver`, `PolicyGate`, `ConsentGate`. Not started.
- Automations — `launchd`, read-only by default.

**Adding a test suite:** write the cases in `Tests/ChunksTestCases/`, then add
`YourTests.register()` to `AllTests.swift`. `runAllChunksTests()` returns whether the
suite passed.

**Test style:** `test("a sentence describing the behaviour") { ... }`, with `expect`
carrying a message that explains *why* it matters. A failing assertion should tell the
next person what user-visible bug they are looking at, not what condition was false.
Tests that touch the real machine (screen capture, display enumeration) assert against
real hardware deliberately — a mock would have agreed with the `CGDisplayPixelsWide` bug.

See `CHUNKS-BUILD-PLAN.md` for the full phased plan and `docs/ARCHITECTURE.md` for detail.
