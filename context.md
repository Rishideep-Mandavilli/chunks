# Chunks — Working Context

**This file exists because compaction kept dropping the important parts.** Read it first
in any new session, before touching code, and update it whenever something below is
proven wrong. Facts here were expensive to learn; several cost hours of debugging.

Last updated: 2026-09-29

---

## What Chunks is

A native macOS menu-bar companion that sees your screen, explains it, and points at
things in it. Hold a hotkey, it captures your screen, sends it to a model, and shows the
answer in a floating card. Circle a region and it explains just that.

## Hard scope boundaries — do not add these

Agreed with the user. These are **out**, not "nice to have later":

- ❌ Agents or sub-agents (no Codex, no Claude Code, no agent runtime)
- ❌ Code generation — Chunks explains and points, it does not build
- ❌ File artifact generation (no PDFs, decks, documents as output)
- ❌ Skills marketplace / persona economy
- ✅ Automations **are** in scope, read-only by default

Adding any of the above without asking is a failure, not initiative.

## Fixed decisions

| Decision | Why |
|---|---|
| **Brain: Gemini free tier**, `gemini-3.8-flash` | Verified vision works. OpenCode Zen free models are client-locked to the OpenCode app — they return `403 FreeTierError` to any external caller. Zen paid returns `402`. |
| **SwiftPM package, not `.xcodeproj`** | Lets logic be tested separately from AppKit. |
| **Custom test harness** (`Tests/ChunksTestHarness/`) | Written when only CommandLineTools was installed. **Xcode 27 is installed now**, so migrating to swift-testing is possible but not urgent — do not churn working tests. |
| **macOS 15.2 deployment floor** | Required by `SCScreenshotManager.captureImage(in:)`. |
| `SCScreenshotManager.captureImage(in:)` | One-shot, display-agnostic, takes a rect in points. Replaces the `SCStream` + `FrameCollector` path entirely. |
| `[POINT:x,y,label]` in **image-local pixel coordinates** | Inherited Clicky used *display* logical points. After a circle-to-explain crop the model would have to infer the crop's offset from the screen, and it guesses. Image-local pixels it can only get right. Image size is stated in the prompt. |

## The six invariants — do not break these

1. **All coordinates are `LogicalPoint`.** Screenshots are device pixels (2x); AX reports
   logical points; `NSPanel` frames are logical. Conversion happens exactly once, inside
   `CoordinateSpace` or `ScreenCapture`.
2. **The model never writes the memory file.** It emits a proposal; `MemoryStore`
   validates and merges. Structural, not advisory.
3. **Secrets rejected before any write.** `SecretSweeper` runs on every proposed fact.
   Rejected facts are *reported*, never silently dropped.
4. **Memory capped at 2 KB, never truncated.** At the cap, writes are refused and the user
   asked.
5. **Never send an image to a model that cannot see images.** `visionCapable: Bool?` —
   `nil` means *unknown*, resolved by probe. Degrade loudly, never silently.
6. **Retries are mandatory.** Gemini free tier returns `503 high demand` on roughly half of
   requests against the newest flash models, and caps at **5 req/min**. A turn that fails
   on 503 is a bug, not bad luck.

## Traps already paid for

Each of these returns a **plausible number rather than an error**. That is why they are
written down.

- **`CGDisplayPixelsWide` returns POINTS, not pixels.** On this machine it returns `1710`
  for a display 1710 points wide that captures at `3420` pixels. Deriving a backing scale
  from it yields exactly `1.0` on a Retina display — every click at half the intended
  offset, nothing logged. Use `NSScreen.backingScaleFactor`, keyed by screen number.
- **`CGDisplayBounds` is top-left origin. `NSScreen.frame` is bottom-left.** Never mix.
- **macOS keys the Screen Recording grant to the app's CODE SIGNATURE.** An ad-hoc-signed
  bundle gets a new signature every rebuild, so a grant stops applying. Run from a
  terminal the bundle reports `granted`; launched via `open` it reports `NOT granted`.
  **Only the user can grant this.** Chunks shows an orange triangle + an explanatory card
  when it is missing.
- **`SecItemCopyMatching` on the main thread can block for 9+ seconds**, or indefinitely on
  a consent dialog a menu-bar app cannot show. This presented as "I click the icon and
  nothing happens". Read the Keychain off the main thread, cache it, and use
  `LAContext.interactionNotAllowed` so a would-be prompt fails fast.
- **`ResponseParser` emits `<SAY>` content as BOTH `.speech` and `.text`** — spoken *and*
  written to the transcript. Treating every `.text` as detail duplicates every spoken
  sentence. `AnswerStreamer` handles this; do not write a second event loop.
- **A menu item with `target == nil` is resolved through the responder chain.** `AppShell`
  is not the app delegate, not a window controller, and never first responder, so actions
  are silently dropped. Always set `target` explicitly.
- **A status item with a `menu` assigned never sends its `target`/`action`.** Assigning the
  menu inside the action and calling `performClick` re-enters the action — the icon never
  appears.
- **A global `NSEvent` monitor only sees events for *other* apps.** It goes deaf when
  Chunks becomes frontmost. Install a local monitor too.
- **Read `event.modifierFlags`, not `NSEvent.modifierFlags`.** The latter is a live global
  query, read after an async hop, when the user may already have released the key.
- **Gemini's Interactions API** (`POST /v1beta/interactions`, header `Api-Revision:
  2026-05-20`, `"store": false`, streaming via `?alt=sse` + `"stream": true`).
  `system_instruction` must be a **bare string**, not `{"text": ...}`. `generateContent`
  is retired for new models. Events: `interaction.created` → `interaction.status_update`
  → `step.start` → `step.delta` → `step.stop` → `interaction.completed`.

## Test harness gotcha

`test { }` closures return `Void`, so `guard ... else { return expect(false, ...) }` does
not compile. `expect`/`expectEqual` now return `Void` specifically so that pattern works —
do not change them back to `Bool`.

Tests that touch the real machine (screen capture, display enumeration) assert against
**real hardware deliberately**. A mock would have agreed with the `CGDisplayPixelsWide`
bug.

## Working on the user's machine

- **Never write an API key to a file, a plist, or the repo.** The login Keychain only.
  Both keys pasted into earlier conversation are exposed and should be rotated.
- Commands: `swift build`, `swift run chunks-test` (**not** `swift test`).
- `swift build -c release && ./scripts/make-app.sh release` then `open build/Chunks.app`.
- **Log:** `~/Library/Logs/Chunks/chunks.log` (override with `$CHUNKS_LOG`).
- **Diagnostics:** `build/Chunks.app/Contents/MacOS/Chunks --self-test` runs one real turn
  and prints the raw reply, the parse, the point resolution and timings.
  `--ask "question"` runs a turn in the real GUI.
- To see what the app draws, capture the screen and read the image. Several bugs were
  invisible in code and obvious in a screenshot.

## The method lesson — read this

I guessed instead of running, three times in a row, and each guess produced a confident
"this is fixed" that was wrong:

1. `guard phase == .idle` rejected every turn the hotkey started → stuck on the mic icon.
2. Menu items had no `target` → the menu rendered perfectly and did nothing.
3. `system_instruction` had the wrong shape → every API request was rejected.

All three were invisible until executed. **Verify by running, not by reading.** The
self-test and the file log exist because guessing twice was not working.

## Process decision, current

The user has directed: **vendor existing open-source code and edit it, rather than writing
from scratch.** Specifically `farzaa/clicky` (MIT, 7,667★, 7,751 LOC, 23 files, frozen
2026-04-28) for computer use, coordinate handling and the automation scheduler.

Honest caveat that was discussed: the working core (166 tests, verified capture, verified
Gemini, verified point resolution) is **not** worth replacing, and clicky predates both
`SCScreenshotManager.captureImage(in:)` (macOS 26+) and the Gemini Interactions API. The
remaining work is where vendoring pays:

| Remaining | Source to vendor from |
|---|---|
| Computer use (`AXTDriver`, `AXTManager`, `PolicyGate`, `ConsentGate`) | clicky — working AX code |
| Automations (read-only, `launchd`) | clicky's cron scheduler, translated to `launchd` |
| Voice input (`SpeechTranscriber`, macOS 26+) | `FluidInference/FluidAudio` (Apache-2.0) — ANE Whisper. `Beingpax/VoiceInk` is a shipping Mac app built on it (GPL-3.0: learn from, do not link). |

**MIT requires preserving the copyright notice and licence text when vendoring.** Keep
the upstream file headers and add a `THIRD-PARTY-NOTICES.md`.

## Current state

166 tests, 11 suites, green. The app runs, captures, calls Gemini, parses the reply, and
renders a card. **Known unverified:** the card's appearance after the latest opacity and
spacing fix (the machine locked before it could be screenshotted), the menu items actually
firing when clicked, and the annotation overlay's interactive behaviour — none of which
can be checked without a human or an unlocked screen.

Not yet built: voice in, computer use, automations.
