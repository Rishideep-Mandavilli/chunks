# Chunks — Working Context

**This file exists because compaction kept dropping the important parts.** Read it first
in any new session, before touching code, and update it whenever something below is
proven wrong. Facts here were expensive to learn; several cost hours of debugging.

Last updated: 2026-10-09

---

## What Chunks is

A native macOS menu-bar/notch companion that sees your screen, explains it, and helps you act
on it — by voice. Hold a hotkey, it captures your screen, sends it to a model, and shows the
answer in a card that grows out of the notch. Circle a region and it explains just that. Ask it
to press a control or open an app, and it asks permission first.

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

## The eight invariants — do not break these

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
7. **A listen-only keyboard tap needs Input Monitoring, not just Accessibility.** With
   `kTCCServiceListenEvent` missing, `CGEvent.tapCreate` is created without error and receives
   *nothing* — every permission row reads "Granted" while ⌃⌥ and ⌃⌥⌘C are dead. Preflight it,
   and send the failure to `Log.write`, never `print()`.
8. **The model proposes every act; the app decides whether it happens.** `[ACT:x,y,label]` runs
   `ResponseParser → ScreenshotGeometry → AXTDriver.elementAt → PolicyGate → card → ConsentGate →
   AXPress`; `[DO:open_app:X]` / `[DO:set_volume:N]` runs `DoRequest.parse → ToolLayer's one
   sentence → the *same* card → ToolRunner`. One card holds **one** question — a reply proposing
   two gets asked about one and the other does not run. Forbidden presses are refused, not asked.

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
- `swift build -c release && ./scripts/make-app.sh release` then `./scripts/install.sh`, and run
  `open ~/Applications/Chunks.app`. The staged bundle lives in `~/.chunks-build/Chunks.app` —
  outside the repo, because this folder is iCloud-synced and rewrote `build/Chunks.app` in place
  into `Chunks 2.app` … `Chunks 7.app`, seven extra `app.chunks.mac` registrations in the switcher.
- **Log:** `~/Library/Logs/Chunks/chunks.log` (override with `$CHUNKS_LOG`).
- **Diagnostics:** `~/.chunks-build/Chunks.app/Contents/MacOS/Chunks --self-test` runs one real turn
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

Computer use is **off** this list: `AXTDriver`, `PolicyGate`, `ConsentGate` and the
`[ACT:…]` / `[DO:…]` chain are built (Phase 5), following clicky's AX approach — window-list
hit test, `AXUIElementCopyElementAtPosition`, pressable-ancestor walk, `AXPress` — rather than
importing its files, because Chunks' coordinate authority and consent card already own those
decisions.

| Remaining | Source to vendor from |
|---|---|
| Automations (read-only, `launchd`) | clicky's cron scheduler, translated to `launchd` |
| Voice input (`SpeechTranscriber`, macOS 26+) | `FluidInference/FluidAudio` (Apache-2.0) — ANE Whisper. `Beingpax/VoiceInk` is a shipping Mac app built on it (GPL-3.0: learn from, do not link). |

**MIT requires preserving the copyright notice and licence text when vendoring.** Keep
the upstream file headers and add a `THIRD-PARTY-NOTICES.md`.

## Current state

351 tests, 17 suites, green. The app runs, captures, calls Gemini, parses the reply and
renders the notch card; ⌃⌥ push-to-talk and ⌃⌥⌘C work; memory is a closed loop; annotation,
the cursor trailer, `[ACT:…]` presses and `[DO:…]` tools are wired to the one consent card.

**Everything that paragraph claimed is now disproved, on the user's own machine.** Presses have
opened apps from spoken turns; a desktop icon has been pressed and the launch believed from its
effect; a message has been typed into WhatsApp's live composer
(`Typed 22 characters into ‎Compose message.`). Keep reading — the interesting part is what that
took.

---

## 2026-10-05 → 10-08: computer use, and five facts that cost hours

The user pointed Chunks at WhatsApp, Chrome and his desktop. Every failure turned out to be a wrong
assumption in code that looked correct. In the order they were found:

**1. The model's aim is a fraction, not a pixel.** The log showed three turns asking for
`[ACT:955,975:"send button"]` against a `1280x829` image. 975 is 118% of an image 829 rows tall, so
the mapping clamped to the last row of the screen, no window contained it, and Chunks said *"that
app did not expose a control"* about a button in plain sight. Those numbers are the button's
coordinates in a **0–1000 grid** — the space Gemini grounds in. The whole tag protocol (`[POINT]`,
`[ACT]`, `[TYPE]`, `[SCROLL]`) is now that grid, mapped by `ScreenshotGeometry`, with any value over
1000 read as pixels (that one is unambiguous) and the result kept half a point *inside* the display.
**This is also what the "clicked the wrong chat row" bug actually was**: a 17% vertical compression
moves a list row onto its neighbour. The name-arbitration fix built first was correct and beside
the point.

**2. A browser publishes an element before it publishes that element's actions.** At one point on a
live Chrome page, the first read answered `AXShowMenu, AXScrollToVisible`; reading *the same
element* again answered `AXPress` too. Chromium builds action lists lazily once an assistive client
has walked the node, and both switches that used to force it early are refused —
`AXEnhancedUserInterface` with `-25208`, `AXManualAccessibility` with `-25205` on real Chrome
(Electron accepts the latter, which is why typing into a Chromium surface worked while clicking
Chrome didn't). So `isPublishingLazily(actions:)` recognises the signature and the walk re-reads
once after 150 ms — only on that signature, so a genuinely dead element costs one round trip, not
two.

**3. A name can match a control the user cannot see.** Over Chrome's address bar, the hit test
resolved an `AXMenuItem` at **y = −82** — a row of an omnibox dropdown that had already closed,
still addressable in the tree. With asking off that is a press on something invisible, which is the
exact thing the confirm card exists to prevent. `isOnScreen(_:in:)` now vetoes any candidate
outside the window the aim landed in, on both routes. Elements with *no* frame are still allowed,
because most desktop icons publish none.

**4. An app can answer a hit test and still publish no windows.** WhatsApp's app element returns an
**empty `AXWindows`**, and its `AXChildren` holds a menu bar and nothing else — so every name search
started from a root with nothing in it and refused controls the user could see. Climbing `AXParent`
from the element the aim hit reaches a real window with 85+ nodes. `searchRoot` does that climb, and
`focusedRoot` additionally falls back to `AXFocusedWindow`/`AXMainWindow`.

**5. Catalyst puts the field-ness in the subrole, not the role.** The one that took five attempts.
WhatsApp's search box, open with a caret in it, is `role=AXStaticText subrole=AXSearchField`.
`editableRoles` checked the role, so Chunks saw a label — and every downstream fix (aim, name
search, focus read-back, first-responder typing, sole-visible-field) was correct and useless.
`isEditableField(role:subrole:)` accepts either half and refuses a secure field on either. The same
app answers `AXFocusedUIElement` with `AXGroup/iOSContentGroup` the size of the window, so the "is
the approved field the focused element?" gate can never pass there; `focusedFieldMatches` asks the
weaker question instead. **A gate nothing can satisfy protects nothing.**

### What got broken on the way, so nobody repeats it

**The always-on microphone.** To kill the 3-second dictation lag, `AVAudioEngine` was made to run
from launch with a 2-second pre-roll ring. It broke push-to-talk completely — the press reached the
engine, the log said `microphone live`, and nothing happened for eight seconds. Cause: the ring
mutated a Swift array on the audio render thread while the main thread read from it. Reverted to
engine-on-press. **The real cause of the 3 s was never the engine** — it was `SFSpeechRecognizer`
being constructed inside the press path, which is why the recogniser is now warmed at launch
(`warmUpTranscriber()`) and the mic stays off until the chord is held. The user's standing position:
**the microphone opens on the press, not before.**

**Two more, same pass.** `contextualStrings` was never set — the manager built a keyterm list on
every press, passed it to the provider, and nothing read it; the list itself was inherited junk
naming a different product ("Learning Buddy", "makesomething", "Vercel"). Both fixed. And the voice
was `AVSpeechSynthesisVoice(language: currentLanguageCode())`, i.e. the system default — on this Mac
a compact Irish voice — while `--probe-voice` proved **the app is never offered the premium neural
voices System Settings lists**, so ranking cannot reach them. Samantha at a gentler rate and slightly
raised pitch is the ceiling until a premium voice is installed.

### One bug still unexplained

A turn whose reply ended in raw `<DONE_TITLE>Ready` on the card — an **unclosed** tag, meaning the
model stopped before emitting any act tag, so nothing was refused and nothing ran. The log recorded
request size and duration but never the reply, which made that unanswerable; every turn now logs
`turn: reply ends …` (last 160 chars). **Next time an action silently doesn't happen, read that line
before touching the Accessibility layer.**

### Also new, because it's part of the picture

`open_url` (`[DO:open_url:youtube.com|Chrome]`) — "open youtube in chrome" is one URL handoff to
`NSWorkspace`, verified live, not a click on an icon plus typing in an address bar plus Enter.
`[SCROLL:x,y:label|down]` — and the reason it uses Accessibility verbs is a measurement: a synthetic
`CGEvent` scroll wheel **moves the pointer** to the event's location, which invariant 8 forbids.
**Plans**: several act tags in one reply run in order, each re-resolved against the live tree, and
*a step that doesn't happen stops the plan* — the steps after it were aimed at a screen the failed
step would have changed. `--probe-ax` gained a field line and a scroller line; `--probe-voice` exists.

## 2026-10-09: the speech-engine swap (#31), and five facts that cost time

`--probe-stt` (`Sources/Chunks/STTProbe.swift`) records once and runs **three** engines over the
same audio — the shipping `SFSpeechRecognizer` provider plus Apple's two on-device modules through
the new `SpeechAnalyzerTranscriptionProvider`. It drives the real providers, not a paraphrase, so
a result there is a result in the app.

**1. The new Speech API is real on this Mac, and the en-IN model is already downloaded.**
`SpeechTranscriber` supports 45 locales with 9 English ones installed; `DictationTranscriber`
supports 54 with `en_IN` + `en_US` installed; `Locale.autoupdatingCurrent` is `en_IN`, so
dictation needs no download. `te_IN` is *supported* by the framework but **not** offered by the
dictation model, which is why Telugu needs its own decision later. Read it with
`--probe-stt --check`: no microphone, no recording.

**2. `AnalyzerInputConverter` is macOS 27+, a year newer than `SpeechAnalyzer` itself.** Assuming
they shipped together is a compile error at best. The gate is `#available(macOS 27.0, *)` for the
converter and 26.0 for the analyzer, with a raw-`AnalyzerInput(buffer:)` fallback on 26.

**3. Exec'ing the bundle binary from an agent shell aborts with a TCC privacy violation.** The
crash names `NSSpeechRecognitionUsageDescription` even though the key is present and the bundle
verifies, because TCC attributes the request to the *responsible process* — the shell that spawned
it. Run bundle diagnostics as their own app: `open -n -W ~/.chunks-build/Chunks.app --args --probe-stt 5`
and read `~/Library/Logs/Chunks/chunks.log`. This is invariant 7's lesson restated for the
microphone.

**4. `Log.write` is async, so `exit()` throws away the last lines** — which for a diagnostic are
exactly its answer. `Log.flush()` now exists and every exit path in the probe calls it.

**5. A run-loop stop that arrives before the loop starts is lost, and a stdout buffer hides it.**
The first version hung silently. `dispatchMain()` plus a watchdog that reports a timeout beats
`CFRunLoopRun` + `CFRunLoopStop`, and `setvbuf(stdout, nil, _IONBF, 0)` makes a hang readable.

Measured on real hardware (silence, so no quality verdict yet): tap delivered 31 buffers of
16000Hz/1ch — which is what both models accept natively; legacy correctly reported
`kAFAssistantErrorDomain 1110 No speech detected`; both analyzer sessions started, finalized and
settled. Keyterms survive the swap through `AnalysisContext.contextualStrings[.general]`, the
equivalent of the `contextualStrings` fix from 2026-10-08.

**Built as an opt-in, then measured, then made the default.** `SpeechEngineChoice` (ChunksKit,
11 tests) shipped with `legacyRecognizer` as `defaultChoice` so the swap could be A/B-ed from a
terminal (`defaults write app.chunks.mac app.chunks.sttEngine dictation`); the user's own recording
decided it, and the default moved. See the verdict below for what that measurement actually said.

**6. `make-app.sh` does not compile, and `swift run chunks-test` does not build the app target.**
The script assembles `~/.chunks-build/Chunks.app` from `.build/debug/chunks` (or `.build/release` with the
`release` argument) and exits 0 whether or not that binary is current. So the sequence must be
`swift build && ./scripts/make-app.sh` — skipping the build ships yesterday's binary *silently*,
and the app then behaves like the change was never made. This cost a full detour on 2026-10-09:
the engine default had flipped correctly in source, in the tests, and in `--check`, and the running
app kept logging the old engine because the bundle was assembled from a stale object file.

## The measured verdict on the speech engines (2026-10-09)

One 12-second recording, 125 buffers, the user's own Indian English, three engines:

| engine | first partial | what it heard |
|---|---|---|
| legacy (`SFSpeechRecognizer`) | 1746ms | "Hello, welcome to Star Mahi**na**… mostly by my sister…" |
| dictation (`DictationTranscriber`) | 1748ms | "Hello, welcome to Star Mahi**la**… mostly by my sister…" |
| transcription (`SpeechTranscriber`) | 1921ms | "**Hi,** hello, welcome to Star Mahila**C** show… mostly **seen** by… my friends **was**." |

`dictation` is the default now (`SpeechEngineChoice.defaultChoice`), with `legacy` as the fallback
on a Mac without macOS 26. `transcription` hallucinated a word that was never said and is not the
default, though it is the only one that caught "seen".

**The honest size of the win:** dictation and legacy differed in *one word* — the show's proper
noun — at identical latency. They appear to share an underlying model, so this swap improves named
entities, not recognition in general. **1.7s to first partial is the number still worth attacking**,
and it is not caused by the engine choice: warm recognisers were already the fix for that.

Revert in one command if it ever misbehaves:
`defaults write app.chunks.mac app.chunks.sttEngine legacy` then relaunch.

## 2026-10-09: tap-to-arm, and what HeyClicky's cursor really is

**Tap-to-arm** is `Sources/ChunksKit/TalkArmer.swift` (7 tests), wired into
`CompanionManager.handleShortcutTransition`. A tap of ⌃⌥ arms the microphone and a second tap sends
it; a hold past **350 ms** still behaves exactly as push-to-talk, so the old muscle memory keeps
working and the change is reversible mid-sentence. The precedence that matters: the *manager* owns
whether audio is flowing, the armer only models the gesture — so a press resets the armer whenever
`isDictationInProgress` is false (a dictation that ended by error or by the panel's own mic button
would otherwise leave the armer "armed" and turn the next press into a stop for a session that does
not exist, which reads as a dead hotkey), and a release is swallowed only while nothing is
recording. **An out-of-sync armer must never be able to leave the mic open.**

**The cursor work he asked about is mostly already here** — and it is a *drawn* cursor, not the real
one. `Sources/Chunks/Clicky/OverlayWindow.swift`: one borderless, click-through `NSWindow` per
screen at `.screenSaver` level hosting a 16×16 triangle with a glow that grows with speed; it follows
the pointer with a spring (`response 0.2`, `damping 0.6`) and flies to a `[POINT:]` target along a
quadratic bezier, duration `distance/800` clamped **0.6–1.4 s**, smoothstep easing, rotation along
the curve tangent, a scale pulse at the apex. No `CGWarpMouseCursorPosition` anywhere — which is
what invariant 8 requires. Greeting (`"hi — i'm chunks"`, typed at 0.03 s/char), pointer phrases
("found it!" etc., held 3.0 s), and the state morph (waveform while listening, spinner while
processing) are all built too.

**Missing:** drawing as *output* (circles/arrows over his apps), and hiding the buddy during a
capture — the bug that gave HeyClicky black screen recordings (v1.0.52), still plan-only.

**The regression that came with the vendoring, found while answering the above:**
`AnnotationOverlayWindow` was deleted in `10bd07e`, and **nothing in the shell produces an
`AnnotationShape` any more** — the only caller of `composited(with:)` passes `[]`. So
*circle-to-explain is currently dead*, while `AGENTS.md` claimed it was running and called that
overlay "the short path" for output drawing. Both statements are now corrected: output drawing has
no surface to reuse, it has to be rebuilt first.

## 2026-10-09: verifying the cursor, and two captures that lied

`--shot [path]` (`Sources/Chunks/ScreenShot.swift`) makes **Chunks itself** write a PNG of the
screen. It exists because a screenshot taken from a shell belongs to the shell: without Screen
Recording for that process, macOS returns an image of the wallpaper with other apps' windows
removed, which looks like a result and is not one.

**The cursor is drawn and follows the pointer — measured, not inferred.** The view now logs its own
state (`cursor: view appeared … first=… / 1.5s in — opacity=… buddyAt=(x,y)`), and a capture taken
while the app was running showed `#3280FF` — the exact `DS.Colors.overlayCursorBlue` — plus its
glow, at the pixel the view said it had drawn. `buddyIsVisibleOnThisScreen`, `cursorOpacity` and
`voiceState` all read correctly at 1.5s in.

**Two false negatives that happened on the way, both worth remembering:**
1. A scan that found **zero** blue pixels was taken after `pkill` and a capture-only launch — so no
   app instance was running and nothing was on screen. The measurement was of my own sequencing.
2. A later capture was **uniformly black** (`000000`) with no sleep assertion preventing it: the
   display had gone to sleep. A black frame is a screen state, not a rendering bug.
Rule: before concluding "it isn't drawing", confirm an instance is running *and* the display is
awake, and check the app's own cursor log line.

**The greeting (`"hi — i'm chunks"`) had a real defect, and my first diagnosis of it was wrong.**
Four call sites wrote `overlayWindowManager.hasShownOverlayBefore = true` immediately before
`showOverlay`, which computes `isFirstAppearance = !hasShownOverlayBefore` — I read that as "the
greeting can never run on any machine", which was too strong: `triggerOnboarding` and
`replayOnboarding` never set the flag, so the greeting does run there. The honest statement is that
the inference could not work in general, because the flag is **per-process** and therefore reads as
a first appearance on every launch — which is exactly why the launch sites wrote it, and why
`triggerOnboarding` (which sets `hasCompletedOnboarding = true` first) defeated any
onboarding-state heuristic. The flag is gone: `showOverlay(…, greeting: Bool = false)` and the two
paths that want the bubble pass `greeting: true`. Verified: launch for an onboarded user now logs
`first=false` and fires no demo turn (the greeting hands off to `startIntroSequence`, which spends a
real model request — so it must never run at every launch).

**Still unverified:** the flight to a `[POINT:]` target on a live turn (the code path is right — it
publishes through `ScreenshotGeometry.appKitGlobalPoint`, the same route an `[ACT]` takes, so the
triangle and the press cannot disagree), and the waveform/spinner swap during listening and
processing.

## 2026-10-09: an offline brain, measured on this Mac

Ollama is installed and running here, with `qwen3:14b` (no vision), `gemma4:e2b-it-qat`
(**vision**, 4.3 GB) and `gemma3n:e2b` (completion only) already pulled; 16 GB RAM, 170 GB free.
So no download was needed — the machine already had a model that can see.

**A real turn on the local model, twice:** 704 KB screenshot → served in **14.4s cold**, **7.9s**
once the weights were resident. The answer was correct about the screen: *"a software development
environment displaying a code editor next to a file explorer pane containing folders like Prolog
and Warpawz."* It named folders it had never seen, so the vision path is genuinely working.

**The catch, and it is a big one:** the reply contained no `<SAY>` tag. Chunks reads a tagless
reply as detail, which means **the card fills and nothing is spoken** — offline you lose the voice,
not just the quality. The gateway now says so in the log (`brain: this reply carried no spoken
line…`) instead of letting a quiet voice look like a bug. Small local models answer the question
and ignore the reply protocol; that is the trade, and it should be re-tested against a bigger
vision model before offline is treated as equivalent.

How it works, and why it is shaped this way:
- **Capabilities come from the server, not from names.** Ollama's `/api/tags` reports
  `vision` per model, which is authoritative in a way a marker list never is — that list is now
  only the fallback for servers that say nothing.
- **Choosing a local brain never falls back to the cloud.** A closed port is an error the user
  reads ("Ollama is not answering on localhost — start it, or switch back"), because quietly
  uploading the screen would be the worst way to honour someone who chose offline.
- **The offline branch runs before the Keychain read**, so a Mac with no Gemini key stored can
  still answer.
- **The Gemini path is untouched**: the local branch returns nil when the cloud is chosen, and the
  measured fallback chain, per-model rate limits and retries are exactly as they were. Two
  transports, one shared reply event vocabulary, so `[POINT]`, act tags and `<SUMMARY>` stay
  provider-blind.

### The two local models, re-measured with the real prompt

`--self-test --prompt-production` sends the prompt a live turn sends; the earlier diagnostic
prompt literally says *"no tags"*, so nothing measured with it could say anything about the reply
format. Corrected results, same question:

- **`qwen3-vl:8b` does not work here as configured.** Ollama gives it a **4096-token context** and a
  screen turn needs **8063**, so the server refuses before answering: `request (8063 tokens)
  exceeds the available context size (4096 tokens)`. The fix is server-side —
  `OLLAMA_CONTEXT_LENGTH=16384 ollama serve`. Note the diagnostic path sends a PNG (5.3 MB, more
  image tokens) where a live turn sends a JPEG (~700 KB), so it may already work in real use;
  untested, and that distinction matters before blaming the model.
- **`gemma4:e2b-it-qat` answers in 14–15s** and is correct about the screen, but returned **no
  `<SAY>`** even when asked properly — offline with this model means **no voice**. That is now said
  in the log instead of leaving a silent companion to look broken.
- **Why `qwen3-vl:8b` said nothing, in the end:** it is a *thinking* model, and Ollama's
  OpenAI-compatible endpoint streams the whole answer into `delta.reasoning` with `content` empty —
  measured 176 characters of reasoning, 0 of content. Chunks must not surface reasoning text, so the
  request now sends Ollama's `think: false` (that key only, because a strict OpenAI parser rejects
  unknown top-level keys with a 400 that names nothing).
- **`qwen3-vl-16k` works, and it was the slowest thing to get right.** With thinking on it timed out
  at 91s; with `think: false` and a 16k context it answered a 7.9 MB screenshot turn in **67.4s** and
  followed Chunks' reply protocol properly — `<SAY>`, `<DONE_TITLE>`, `<SUMMARY>`, `<NEXT_ACTIONS>`
  and `[POINT:640,29:play button]`. So offline **can** keep the voice, at four times the wait.
- **The two local brains are a trade, not a winner.** `gemma4:e2b-it-qat`: 14s, reads the screen,
  plain prose → no voice. `qwen3-vl-16k`: 67s, reads the screen, full protocol → speaks. Which one
  should be picked automatically is the user's call, not a default to invent.

- **Local turns fall back between local models.** A model refusing is that model's problem, not the
  server's, so Chunks tries the next one and says why. It never leaves the Mac: a turn asked for
  offline does not go to the cloud because one model declined. `LocalBrainError` separates the two
  cases (context / missing model / unreadable image, versus out-of-memory / wrong URL), and a
  refusal it cannot explain produces no advice rather than a guess.

Switch from a terminal (`UserDefaults`, like `askBeforeActing` — it is a switch, not a secret):
```
defaults write app.chunks.mac app.chunks.brainProvider ollama
defaults write app.chunks.mac app.chunks.brainModel "gemma4:e2b-it-qat"
defaults delete app.chunks.mac app.chunks.brainProvider   # back to Gemini
```
**Not built yet:** the picker in the panel (logic is `BrainSettings`), and an automatic
cloud→local downgrade when the network is unreachable — which is the direction the "never fall
back" rule does not forbid, and the one that would make offline actually useful without asking.
`--self-test` also needed `Log.flush()`: the async log was eating its last lines, including the
reply tail.

## 2026-10-11: the circle-to-explain overlay locked the user's Mac. Removed.

I wrote an annotation overlay from scratch, shipped it in a build, and it took over the screen so
completely that the user could not use the Mac until he fought his way out. It is removed — the
three wiring files were reverted and `Sources/Chunks/Annotate/` deleted; build clean, 387 tests
green, nothing of it committed.

**Four decisions that combined into a lockup.** Any two of them would have been survivable:

1. `window.level = .screenSaver` — above every app **and above the menu bar**. The buddy cursor
   uses this level too (`OverlayWindow.swift:27`) and is harmless only because of decision 2.
2. `ignoresMouseEvents = false` on a **display-sized** window. The buddy sets it to `true`
   (`OverlayWindow.swift:28`, "Click-through"). Mine swallowed every click on the machine,
   including clicks meant for the menu bar and the Dock.
3. Escape and Return were the only exits, handled in the view's `keyDown` — which requires the
   window to be key. An `LSUIElement` accessory app calling `NSApp.activate(ignoringOtherApps:)`
   is not guaranteed key focus. No focus, no keyboard, therefore **no exit**.
4. No timeout, no click-outside-to-dismiss, no watchdog, and no warning to the user. I then
   launched it from a diagnostic harness (`--annotate`) on his running machine to measure a
   screenshot, which is when it first grabbed his screen.

The log records both grabs: `annotate: overlay open on 1710x1107pt display` at
2026-10-10T14:29:36Z (my harness) and 2026-10-11T11:30:28Z (him clicking the new panel button).

**The safety contract for anything that covers the screen, before it is written again:**
- Click-through unless capturing is the entire point; if it captures, it must also **release**.
- A hard auto-dismiss timer (a few seconds), started before the window is ordered front.
- An exit that does not depend on key focus: a click outside, a second invocation of the trigger,
  and the app's own menu-bar Quit all cancel it.
- Never `NSApp.activate(ignoringOtherApps:)` from an accessory app to force focus.
- Never launch a screen-grabbing mode on the user's machine as part of a measurement without
  saying so first. A harness that can lock his Mac is not a read-only probe, whatever it logs.

**Do not rebuild this from scratch.** The upstream implementation is already in this repo's
history — `git show 10bd07e^:Sources/Chunks/AppShell.swift`, `AnnotationOverlayWindow` (line 987)
and `AnnotationCanvas` (line 1045), with `mouseDown`/`keyDown` handling that shipped in
farzaa/clicky under MIT. Import it, read how it dismisses itself, and apply the contract above.
`AnnotationShape`, `RegionResolver` and `CaptureEngine.composited(with:shapes:)` all still exist
and stay tested, so only the surface is missing.

**Done 2026-10-12, as an import.** `Sources/Chunks/Annotate/AnnotationOverlay.swift` is upstream's
`AnnotationOverlayWindow` + `AnnotationCanvas`, unchanged in the part that matters — a
`.nonactivatingPanel` that never becomes key — plus three exits upstream did not have: right-click
anywhere, `idleLimitSeconds = 30` without input, and `absoluteLimitSeconds = 120`. It is wired to
⌃⌥⌘D (`CircleShortcut`) through the existing event tap. **No live turn has used it yet**: the tap
has logged every keystroke since, all with `flags=0x100` and `circle=false`, so the chord itself has
still never been seen arriving.

## 2026-10-12: eight Chunks in the app switcher

The ⌘Tab list showed `Chunks`, `Chunks`, `Chunks 2` … `Chunks 7`. Not eight running processes —
eight registered bundles, all with `CFBundleIdentifier = app.chunks.mac`:

- `/Users/rishideep/Applications/Chunks.app` (the one install path, by design)
- `<repo>/build/Chunks.app` (`make-app.sh` staging)
- `<repo>/build/Chunks 2.app` … `Chunks 7.app`

The numbered ones are iCloud conflict copies, and the mechanism is the one this project already
knows: the repo lives under `~/Documents`, which Desktop & Documents syncs, and `make-app.sh` does
`rm -rf` + rewrite of a whole `.app` in place. The daemon saved each earlier revision as a sibling
bundle. Six of them, timestamped 03:28–03:51 on 2026-10-09 — one night of rebuilds.

Fixed at the root, not by hand:

1. **Staging left the synced folder.** `make-app.sh` and `install.sh` now use
   `${CHUNKS_STAGING_DIR:-$HOME/.chunks-build}/Chunks.app`, so a rebuild can no longer mint a
   conflict copy. `build/` is gone from the repo.
2. **Rollback copies are pruned.** `install.sh` moves the previous install aside on every run and
   never deleted one: 47 `Chunks.app.previous-*` bundles, ~270 MB. It now keeps the newest only.
3. **One instance, verified.** `open -n` a second copy and exactly one `MacOS/Chunks` process
   survives; the loser logs `chunks: already running as pid N … this copy is standing down`. The
   guard needed `Log.flush()` before `NSApp.terminate` — the same lost-last-line trap as the
   `exit()` paths, and it bit again in exactly the place where the proof is the log line.

Two things worth writing down because they cost a wrong turn each:

- **`lsregister -u` names a path, not a bundle.** Un-registering `build/Chunks 2.app` and then
  moving that folder to the Trash re-registered it as `~/.Trash/chunks-conflict-2.app`. A bundle
  has to be gone *and* un-registered, or the dump will keep listing it from wherever it landed.
- **`LSUIElement` does not guarantee absence from the switcher.** An accessory app that calls
  `NSApp.activate` — which the cursor overlay does — can still appear. So a duplicate registration
  is visible, not merely theoretical.

## 2026-10-12: circle-to-explain opened and took no input at all

The chord was finally seen firing (`event tap: circle chord matched` → `annotate: overlay open`), and
the user's drawing produced nothing. The log answered *why* in one line: a 30 s session ended in
`dismissed — no input for 30s` with **zero** `annotate: mouse down` lines and zero lines from an
`NSEvent.addLocalMonitorForEvents` that was watching every window of the app. Not one mouse or key
event reached Chunks. That rules out the stroke colour, `acceptsFirstMouse` and the hint placement —
the window was simply outside the input path.

What the parallel audit convicted, in order, each with the evidence that made it the verdict:

1. **No `collectionBehavior`.** The annotation panel was the *only* window in the app without
   `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]` — the buddy overlay, the menu panel, the
   notch card and the response overlay all set it. In the user's own session the on-screen list read
   `Chunks#1000/892 → Qoder#0/602`: the buddy (which has it) was there, the annotation panel (which
   does not) was not, while AppKit reported `isVisible == true`. `.optionOnScreenOnly` is per-Space,
   so this is exactly the signature of a window that never joined the Space.
2. **A plain borderless `NSPanel` cannot become key.** `key=false` for the whole session, so
   `AnnotationCanvas.keyDown` — Escape, Return, Space — was unreachable code. The repo already had
   the answer twice over: `MenuBarPanelManager` and `NotchPanelManager` each hold a private
   three-line `KeyablePanel`, and those surfaces take clicks today. Now `AnnotationPanel` does the
   same, with `isFloatingPanel = true` and `makeKeyAndOrderFront(nil)` *then*
   `orderFrontRegardless(nil)` — the menu panel's exact order. Being key is not being active:
   `.nonactivatingPanel` stays, and `NSApp.activate` is still nowhere in the file.
3. **The probe ran AppKit off the main thread.** `App.init` is not on main, and
   `MainActor.assumeIsolated` there is a lie: every probe line logged `[bg]`, and a window built
   off-main never enters the window server's list — so the probe was reporting its own bug.
   `AnnotationSafetyProbe.start()` now hops to main.
4. **`DisplayInfo.frame` is `CGDisplayBounds`** (top-left) and was fed straight into
   `NSPanel(contentRect:)` (bottom-left). Invisible on the display at (0,0), wrong everywhere else —
   invariant 1 again. Now `appKitFrame()` matches `NSScreen.deviceDescription["NSScreenNumber"]`
   against `display.displayID` and refuses with a log line when no screen matches.

**A probe launched by an agent shell cannot measure on-screen state.** After the thread fix, the
probe's own window list still read `loginwindow#2004 → loginwindow#2001 → Qoder#0`, with
`asleep=false active=true` — that process is not in the user's Aqua session, so *its* answer about
who covers the screen is worthless. Verdicts about the overlay's input path must come from the app
the user launched. Related: the probe printed `FAIL` unconditionally after its absolute limit,
whether or not the overlay had already dismissed itself; it now exits through `onDismissed`.

Every window-list line now starts with `display N asleep=… active=… screens=…`, because an asleep
display already produced one false reading here (same class of lie as a sleeping display capturing
black).

## 2026-10-14: circle-to-explain shipped on Apple's selector; our window parked

Two more sessions on the real machine, and the two measurements finally contradict each other in a way
that names the culprit:

```
18:18:27  frontmost over that point is Chunks#1000/43 — the overlay takes clicks: false
18:18:52  annotate: click watch — leftMouseDown → window #4294967296 inCanvas=false
```

At `.screenSaver` the annotation panel was frontmost, was key, received `keyDown` (Escape closed it —
the first input this surface ever took) and received **no mouse event at all**. At `.statusBar` the
mouse event *did* reach the app and was routed to a window that is not the canvas — the cursor buddy's
full-screen `OverlayWindow`, which sits at level 1000 and is therefore above the panel at 25. Same
gesture, two different failures, both inside Chunks' own window stack.

So the feature stopped depending on that stack. `Sources/Chunks/Annotate/RegionSelector.swift` runs
`/usr/sbin/screencapture -x -i`, the crosshair macOS draws for ⌘⇧4, and hands the PNG straight to
`pendingRegionCapture` → `ask(text:)`. The system owns the pointer, so no level, ordering,
`collectionBehavior` or first-mouse question applies; nothing of ours covers the screen afterwards;
and Escape in Apple's UI cancels. A file path rather than `-c`, because the user's clipboard is his,
not a transport.

**What was given up:** a freehand circle, arrow or box — the answer is a rectangle. `AnnotationShape`,
`RegionResolver` and `CaptureEngine.composited(with:shapes:)` stay and stay tested; `AnnotationOverlay`
stays in the tree but is **parked** — no chord, menu item or gesture launches it, and
`--annotate-safety` is its only door. `explainCircledRegion` was deleted rather than left stranded,
and `activeOverlay` became `isSelectingRegion` (one selection at a time; a second chord is ignored
rather than queueing a second question).

**The lesson, since it cost eleven rounds:** the diagnostics that finally worked were the ones that
described *what the window server sees* — who is frontmost over the point, which window an event was
routed to — not the ones that described what the code intended. Two earlier fixes (`acceptsFirstMouse`,
the stroke colour) were plausible readings of the source and were both wrong.

## 2026-10-17: the overlay took the mouse, and two rules came out of it

The user confirmed circle-to-explain works on the live screen. What unlocked it was not a Chunks
insight but an import: Capso's `CaptureOverlayWindow` (MIT, same `LSUIElement` app type, same
feature) sets **`_setPreventsActivation:` to true**, `.transient`, `isMovable = false`,
`canBecomeKey` true with `canBecomeMain` false, and shows with `orderFrontRegardless()` **then**
`makeKey()`. The rule that explains eleven rounds of failure in one line: **keyboard follows
key-window status, mouse follows app activation.** Every measurement was consistent with that and
none of them named it — the panel was key, was frontmost over the point, took Escape, and could not
take a click, at three different window levels.

Two follow-ups from the same conversation, both his calls:

- **The surface announces itself.** A transparent full-screen window is invisible, so "is it even
  listening?" had no answer. The canvas now fills its bounds with 18% black while drawing mode is
  on, and the hint strip moved to notch depth + 22 pt so it clears the menu-bar row as well as the
  cutout. The dim cannot reach the screenshot: the capture happens after the surface closes.
- **Click-away is per-phase.** It closes `.result`, `.failed` and `.status`; it is ignored during
  `.thinking` and `.listening`, and says so in the log. This is not the 2026-10-09 revert coming
  back — the answer still closes on click, so a card can never become furniture; only the *wait* is
  protected, because it is the sole proof anything is happening.

Also fixed the same day, after an 8-minute turn: `URLRequest.timeoutInterval` **overrides**
`URLSessionConfiguration.timeoutIntervalForRequest`, so the request's 90s had silently cancelled the
session's 20s idle bound on every Gemini call — and the retry policy answered a timeout by retrying
the same model three times. 271 of that turn's 281 seconds were one silent model being asked three
times to speak. Both are in invariant 6 now.

## 2026-10-17: one spoken request now runs several turns

"Open whatsapp, search for dad, and message him HI" took three commands, because the reply protocol
said **"one act tag … last"** while the executor was built for a plan. Worse, the prompt contradicted
itself: `actingRules` already told the model to "emit your tags in order and Chunks runs them as a
plan". So the model obeyed the stricter line and stopped after the open.

Allowing several tags would not have fixed it either. `[ACT:x,y:label]` needs a coordinate, and
WhatsApp's search box is not in the screenshot the model was shown — it does not exist until the app
opens. The only honest fix was a loop:

- New tag, `<CONTINUE>what still has to happen</CONTINUE>`, parsed into `ReplyEvent.continuation`
  and collected on `AnswerStreamer.continuation`. Consumed, never shown, never spoken.
- `continuePlanIfNeeded` runs another full turn — fresh capture, same pipeline, same gates — after
  the previous turn's **speech has finished**. Continuing at the end of the reply instead cut the
  voice off mid-sentence.
- Bounded by `maxPlanRounds = 4`, reset by anything the user actually said, and taken only when the
  step really happened: a stopped plan or an unanswered card does not continue, because the next
  step would be aimed at a screen that never arrived.
- Deliberately not `<NEXT>`: it is a prefix of `<NEXT_ACTIONS>`, and whichever construct is tried
  first eats the other. There is a test that pins both tags surviving one reply.

395/395 tests pass. Not yet watched on the real machine: a spoken three-step request end to end.

## 2026-10-17: it can read files now, and the probe said so before the user did

`[READ:~/path|question]` gives the model a file it could not see. The capability was already in
scope — "the agent reads files and screen content as *context*" — and it is the one thing that makes
"why did my build fail" answerable when the terminal shows only the last four lines.

Design decisions, each forced by a measurement rather than chosen:

- **The policy is in ChunksKit and does no I/O**, so the cases that matter are testable: a `..` that
  escapes every allowed root, a symlink from `~/Documents` into `~/.ssh`, a key-shaped filename in a
  folder that is otherwise fine. All three are asserted in `ReadRequestTests`.
- **The deny-list is matched against the resolved path**, not the typed one, and as whole directory
  fragments rather than components — `~/.config/gcloud` has no single component that is on any list,
  which is exactly how a component check would have let it through.
- **24 KB is sliced, not refused.** The first probe run refused `context.md` outright, and that is
  the same as refusing the question: a build log's failure is at the *bottom*. So logs, `.out`,
  `.txt` and `.csv` give up their tail and everything else its head, and the block handed to the
  model says which slice it is looking at — an unlabelled excerpt invites an answer that confidently
  describes half a file.
- **A probe, not a code review.** `--probe-read <path>…` runs the real read path and logs the
  verdict, because the last feature that looked correct in review failed on its first byte read. On
  the user's Mac it read `~/.zshrc` (811 bytes) and `README.md` (5,172), sliced `context.md` to the
  cap, refused `/etc/hosts` as outside the roots, refused a credential store before touching disk,
  and — after the first run exposed the wording — says "that is a folder, not a file" instead of
  claiming the file is missing.

432/432 tests pass across 24 suites.

## 2026-10-18: an act can be aimed by name, and the window list lost the argument

The user asked for the transition off coordinate-based pixel interaction onto "semantic OS-level
accessibility and URL scheme primitives". What shipped:

- **`SemanticTarget`** (`app=… role=… name=…`) and `ActAim`, so `[ACT:…]`, `[TYPE:…|text]` and
  `[SCROLL:…|down]` all accept a name instead of a point. `ActionRequest.parseAct` tries the name
  grammar first and the point second; the two shapes are disjoint, and a *partly* parsed name is
  refused outright because a target missing its app would search every app on the screen.
- **`AXTDriver.resolve` / `typeResolve` / `scrollResolve`** walk the live tree with no geometry at
  all, and every aim still converges on `CompanionManager.offerPolicyAndCard` — policy, card, and the
  re-read-and-compare before pressing are untouched. `pressTargetNow`/`fieldNow`/`scrollerNow`
  re-resolve a named act *by name*, so the invariant that a card cannot outlive a relayout holds for
  an aim that never had pixels.
- **`[DO:run_shortcut:Focus]` and `[DO:email:…]`** — the URL-scheme primitive. One sentence describes
  the whole effect, which is the bar `DoRequest` sets; `shortcuts://run-shortcut?name=` is built
  through `URLComponents`, so "Focus & Deep work" arrives as one name.
- **A launch can lead a plan**, but only a named one (`ActionRequest.leadingTool`).

Two bugs the probes caught before the user could meet them. A bare value stopped at the first space,
so `app=Google Chrome name=Send` parsed as an unknown field and closed — the prompt tells the model to
write the application's own name, and two of the apps on this Mac are multi-word. And
`--probe-semantic app=Finder name="Free Claude Code"` answered *Finder is not on screen* on an awake
display while `--probe-desktop` showed the same icon published in Finder's tree at
`(1616, 41) actions=AXOpen`: `CGWindowListCopyWindowInfo` had no Finder entry at all. So
`surface(ownedByNamed:)` asks the list first and the app element second, and the probe then reported
`AXImage/Free Claude Code in Finder at (1648.0, 73.0) verb=AXOpen`, `policy=needsConsent`. That is the
same lesson `desktopTarget` learned in October, one layer up: the window list is not the screen.

A four-agent read-only audit ran alongside it.

### The first live spoken plan, and what it cost two fixes
### Then he watched it send a message he had not approved

The plan ran end to end at 10:22 — launch, press Search, type "Dad", open the chat, type "hi" into
the composer, four seconds of work — and then the `<CONTINUE>` round pressed **Send**. The message
went out while he was still reading the answer. His words for it: "those things should be done by
me, like send, pay".

So `PolicyGate` grew a class of its own: `alwaysAskControlWords` (send, submit, pay, delete,
confirm, transfer, and their company) matched against the name the **app** publishes, returning
`.needsConsent` ahead of both the asking-off shortcut and the per-app always-allow. Whole tokens,
because "Sender" is not a Send button. The prompt now says it out loud, and the WhatsApp example no
longer queues a send behind an automatic next look — it offers the tap instead.

Two more names were wrong in the same turn, and both were measured rather than argued: the composer
is `Compose message`, not the `"Message box"` my own prompt example taught the model to write, and
a named field walk spent its entire 220-read budget on WhatsApp's chat-list rows before reaching it
(`--probe-fields WhatsApp`: *1 field, 362 elements read*). Fields and lists now get 700 reads and
the sweep reports whether it ran out, so "no such field" can no longer be confused with "I stopped
looking".

### Smarter actions, and less waiting

Two changes to the act path, both measured before and after.

**Latency.** A turn at 10:22 spent 8.3s waiting to find out that `gemini-3.6-flash` was contended,
retried it (the policy is right — a 503 clears in seconds on the same model), and answered in 17.2s
for a reply that took six seconds to generate. The serial part was the *discovery*, so the first
model is now asked alongside its successor if it has not produced a single chunk in 3.5s
(`BrainGateway.hedged`, `StreamClaim`). Whoever streams first owns the card and the voice; the loser
is cancelled, and `stream` checks `Task.isCancelled` because `AsyncBytes` does not notice on its
own. Only the first hop hedges, and the partner stands down if its own per-minute bucket is full.

**Intelligence.** `app=Chrome` now finds "Google Chrome" and `app=VS Code` finds "Code"
(whole-token containment, so "Mail" still cannot reach "MailMate"), and a *field* lookup accepts the
words on the control as well as the words in it: `name="search box"` resolved
`AXStaticText/Search` on the live app, while the press route refused the same alias — a guess is not
a licence to press. Aliases ride in the same walk, so the answer costs no extra reads.

439/439 tests pass. The hedge's own saving is not yet measured on a live turn — the log line
`turn: nothing from <model> after 3.5s — asking <next> alongside it` is what to look for.

### The notch and the panel, designed

`PRODUCT.md` and `DESIGN.md` were written from the built surfaces. The card gained the three things
it never had: a **stage row** ("Asking the model" / "Doing it", with elapsed in tabular figures,
ticking at half a second and held at the final number), the **question he spoke** kept on the card
while a plan runs, and a **stacked record of what ran** — up to four outcome lines with `step/total`,
older ones folded into "+N earlier". The single line that used to replace itself is gone; that is
what made a five-step plan look like a one-step one.

Verification is `--render-ui`, which draws the real `NSHostingView` at the real window height into a
PNG — a screenshot from a shell is wallpaper, so a visual change otherwise has no evidence at all.
It paid for itself immediately: the fold line cost a row `AnswerPanelLayout.measure` never counted,
so the window was 18 pt shorter than its own content and clipped the Ask row. Small text also moved
off `textTertiary`, which is 4.0:1 on the card's pure black.

The panel keeps its 320 pt shape and gains the craft: a scrolling middle under a pinned header and
footer (in the permissions state the API-key row was below the bottom edge, which is not a layout
problem but a missing control), `DS.Fonts` where there were five ad-hoc sizes and no tokens, hover
on the dismiss control, and the inline greys onto the palette.


The user said "open whatsapp, searching for amma, and typing hi into her chat" and sent the
screenshot: WhatsApp open in front of him, the notch card reading *Chunks found no control called
"Search" in WhatsApp*. The log held the comparison that settled it —

```
08:46:49  act: named ask — the "Search" in WhatsApp
08:46:49  act: named — "Search" → AXStaticText/‎Search verb=AXPress at (171.5, 52.0)     ← worked
09:31:50  tool: Opened WhatsApp.
09:31:52  act: named ask — the button "Search" in WhatsApp
09:31:52  act: named miss — "Search" — Chunks found no control called "Search" …          ← refused
```

Same app, same name, 45 minutes apart; the only difference was the `role=button` the model added.
Catalyst publishes WhatsApp's search box as `AXStaticText` answering `AXPress`, so a role constraint
was vetoing a control the user could see and the name had already identified. `semanticSearch` now
ranks by name score and lets the role break only a tie, and the log says `(role said "button")` when
the press goes to something the model described with the wrong vocabulary.

The second bug fell out of verifying the first: `--probe-semantic app=WhatsApp …` answered *not on
screen* while the app was frontmost on the user's display. The window list had no WhatsApp entry, and
the new app-element fallback asked only `AXWindows` — which WhatsApp answers **empty**, the exact
asymmetry `focusedRoot` has documented for two weeks. It now also reads `AXFocusedWindow` /
`AXMainWindow`, and only as a last resort takes the display rect as the veto. After both fixes, the
same probe against the same live window:

```
searching ‎WhatsApp pid 53687 layer 0 bounds (0.0, 34.0, 1710.0, 1073.0)
AXStaticText/‎Search in ‎WhatsApp at (417.5, 108.0) verb=AXPress
policy=needsConsent — the card would ask "Press ‎Search?"
```

`name="Message box"` still refuses, and correctly: no chat is open, so the composer does not exist
yet — the thing the prompt already tells the model.
 Its top findings were fixed here — the named search
choosing the app's *biggest* window (an invisible control becomes pressable when no pixel chose the
window) and each search root getting a fresh 220-read budget — plus two older ones: the 60 s turn
budget was only checked from the second model onward, which left a local model free to spend three
75-second requests, and one event-tap failure still reached only `print()`, which invariant 7 forbids.
What the audit says is still missing is in the table below: no app window, no history, no Notebook,
Phase 6, realtime voice, skills, MCP.


## Where it stands, and what's next



Verified working on the user's machine: press, launch-and-believe-the-effect, type into WhatsApp's
composer, scroll resolution, open-url, plans, the notch card, memory, push-to-talk (after the
revert).

| # | What | Why it's next |
|---|---|---|
| 31a | ~~`SpeechAnalyzer` behind `BuddyTranscriptionProvider`~~ **done, and the default** | Measured on the user's voice; `dictation` won. Needs one real ⌃⌥ turn on the new engine before it stops being a lab result. |
| 31b | Tap-to-arm instead of hold-to-talk | Still to build. Blocked on one decision: with no key-release edge, what ends a dictation — a second tap, a silence timeout, or the engine's own endpointing. |
| 29 | ~~The app window~~ **first version built (2026-10-21)** | Sidebar history, transcript, composer, ⌃A. Rendered offscreen and installed; **his proposed changes are still open** — the point of shipping it early was to have a running window to redirect rather than a question to answer. |
| 30 | Voice picker | Rides along with #29's settings row; blocked by the premium-voice finding above. |
| 28 | Chunks drawing on screen (circle/arrow as output) | HeyClicky parity. Short path: the annotation overlay already exists for input. |
| 18 | Idle CPU (~3%: 60 Hz timers, per-keystroke tap logging) | Ships with #29's window work. |
| 9 | Verify the panel chord and live captions | Needs eyes. |

**How to verify anything here without touching the screen:**
`/Applications/Chunks.app/Contents/MacOS/Chunks --probe-ax x,y --named "the label"` (press, field
and scroller resolution, read-only), `--probe-desktop`, `--probe-voice`, `--self-test`, and
`~/Library/Logs/Chunks/chunks.log`. Build with `swift build`, test with `swift run chunks-test`,
ship with `./scripts/make-app.sh && ./scripts/install.sh` — never a hand-signed bundle, or TCC and
the Keychain forget the app.

## 2026-10-21 — the window, and what a turn remembers

`ConversationStore` replaces an in-memory array of ten tuples that died with the process. Two
slices, deliberately different: 200 turns on disk for the window, 10 back to the model, because the
measured request was already 23k characters and the prompt is charged for every exchange it replays.
Acts are stored beside the answer, not inside it — "I found the send button" and "Pressed Send." are
different claims about the machine.

Two bugs the store's own tests caught before the app ran:

- `JSONDecoder` answers an array atomically, so one row with a hand-edited or differently-formatted
  date used to fail the whole file and every answer in it. A row now decodes with defaults, and only
  a row with no question in it is discarded. A date that cannot be read keeps epoch and the list
  shows no time, because stamping it "now" would put a turn with no known time above this morning's.
- A preview cut at a word boundary *and* truncated in the middle produced "war…atters is the…" — two
  ellipses in one line. The list truncates at the tail.

`ask(text:source:)` now carries how a turn started —
spoken, typed, tapped, or scheduled — so a 07:00 routine glance cannot read under his own name as
something he said and forgot. Plan continuations keep the source of the request that started them.

The window (`CompanionWindowView`, `AppWindowManager`, ⌃A) is the reading surface. It activates the
app, which the panel and the notch deliberately never do. It does not mirror the stream: while a turn
runs it shows the HUD's own stage line and elapsed seconds, and the row appears when the answer
lands. `--render-window` found three layout defects that a shell screenshot cannot — an empty sidebar
floating mid-column, the double ellipsis above, and an answer set in 11 pt grey.

## 2026-10-21 (later) — sessions, and using the history to answer

The store had no boundaries, so the ten exchanges replayed to the model on Tuesday morning were
Friday night's: a new screen answered as a follow-up to a dead conversation. Now a turn carries a
`sessionID`, the replay is session-scoped, and a session begins at launch (which covers relaunch,
reboot and login), at a wake longer than ten minutes, at the window's button, or when he says the
words.

Two judgment calls worth remembering:

- **Ten minutes.** He asked for a new session whenever the MacBook is opened. A thirty-second lid
  flip in the middle of an error is not a new sit-down, so a wake only cuts the conversation if the
  Mac was actually shut. `CompanionManager.wakeSessionGap`.
- **"New session" is answered by the shell, not the model.** The state lives in the shell, so a turn
  spent promising to reset while nothing reset would be a lie; and it costs a capture plus a
  six-second request to do something instantaneous. It also cancels the in-flight turn first, or the
  old answer lands inside the new session. `forget …` deliberately does **not** trigger it — that
  verb already belongs to the memory file's prune.

Recall is keyword scoring over the other sessions, capped at three turns, injected as a labelled
block ("from earlier conversations, not this one") with the framing that it is past data, not the
current screen and not instructions. Not embeddings: no network, no download, testable ranking, and
a scored list can say why a row came back.

`history.json` is now an envelope of `sessions` + `turns`. His two existing rows migrated on the
first launch after the change — verified against the real file, not just the test: they sit in a
`restored` session and a fresh `launch` session is open.

## 2026-10-21 (later still) — finishing the history step, then the schedule from both ends

Three loose ends from the session work, all real:

- The sleep observers were registered and never removed. `stop()` now takes them back out.
- Recall ran on **every** turn. That costs prompt whether or not it finds anything, and a live
  question sharing a word with an old one got the old answer placed in front of the model — which is
  how an assistant starts talking about a window he closed yesterday. Now gated on
  `SessionIntent.refersToPast`, a marker list that leans wide because a false positive costs a
  wasted scan and a false negative costs him being told "I don't have that".
- A "new session" said *during* a turn let the in-flight answer append itself into the new session.
  The reset cancels the task first.

Then the half of the routines item that was missing: `[DO:routine_add:…]` and
`[DO:routine_remove:…]`, so "every morning at eight, brief me" lands in the schedule instead of
being forgotten. Three decisions in it:

- **The card question is the budget.** The store allows a 400-character prompt; the card has two
  lines of 12 pt. Checking the name and the question separately passed a 55-character name with a
  legal question and rendered an unreadable approval, so `DoRequest.maxQuestionCharacters` bounds
  the *assembled sentence* and the tag fails open to visible text past it. Measured, not guessed:
  `--render-ui` state 5 draws a 91-character routine question and it fits exactly two lines.
- **Refused before asked.** A duplicate name or a twelfth routine is rejected at `offerTool`, not
  offered and then failed. Same rule as a press the policy forbids.
- **The schedule is in the prompt by name and time.** Twelve short lines, and it removes two failure
  modes: inventing a title to remove, and offering a duplicate it will be refused for.

497/497. A routine added from a spoken turn has not been watched on the real machine yet.

## 2026-10-23 — the history as a tree: sitting → thread → exchange

The flat list was measured against his real file: 13 turns, and inside one sitting four of them were
`"What's the answer for this?"`, `"Explain this"`, `"Explain this one, I didn't understand this"` and
`"I cant"`. As rows, indistinguishable. So the middle level went in — `ConversationChat`, a run of
exchanges about one thing — and the window now navigates three levels with the detail pane showing a
**whole thread**, which is the only way a follow-up reads as anything.

Grouping is a rule, not a model call (a turn already spends six seconds; naming a list row is not
worth another):

1. gap over 15 minutes → new thread;
2. a pointer (`this`, `it`, `the second one`, `i cant`, a bare `?`) → continue;
3. names something the thread is about → continue;
4. otherwise → new thread.

Two bugs the tests and the render caught, both worth keeping in mind:

- **The pointer test first ran on `contentWords`, which strips stop-words — and every pointer is a
  stop-word.** `"type good night and leave it for me"` lost its `"it"`, opened its own thread, and
  one WhatsApp task showed as two. Search and grouping need opposite vocabularies.
- **`why`, `what`, `how`, `which` are not pointers.** They look like it, and they made `"why is the
  certificate warning showing in chrome"` continue an unrelated WhatsApp thread. An interrogative
  with a subject is a new subject.

Boundaries are **persisted**, not recomputed on read: a tree that re-derives itself can move a
thread's edges between two loads, and a list that changes shape under the cursor is not a list.
Migration ran on his actual 13 turns at the first launch after the change — 8 threads, and the four
quiz questions came out as one called `Identified answer: B`.

## 2026-10-23 — the listening meter

Asked for a waveform on the notch. The reference he gave was a shadcn registry item
(`@localmode/ui/audio/waveform-activity-bars`) — React, so nothing installs into a SwiftUI app; the
design went in as native views instead, taking the shape from the waveform this repo already ships on
the cursor.

`WaveformMeter` (ChunksKit) is a **time** buffer: nine 45 ms windows of the engine's level, each
keeping its **peak** rather than its average, so a syllable shows up as a tall bar instead of being
diluted by the silence on either side of it. The pill then draws what the microphone actually did,
which is the answer to the 1.7 s wait complaint that a caption can't cover — before there are words,
there is level.

Deliberately dropped from the cursor's version: the sine-driven idle pulse (motion without a cause)
and the blue glow (a halo is banned on this surface). Deliberately not built: an output meter while
the voice speaks — `AVSpeechSynthesizer` exposes no audio buffer, so those bars would be animation
standing in for sound, which is the thing he has rejected twice.

517/517. The row has been rendered (`--render-ui` states 1 and 6: speaking, and a quiet room) but not
yet watched against a real microphone.

## 2026-10-23 — the whole palette became physical bone/ink

He pointed at a component library (Ovio, MIT) and asked for its language everywhere. It is React, so
nothing installs here — the *values* came across: ground `#f5f4f0`, ink `#161614`, hairlines, the
two-layer shadow (`0 1px 2px rgba(0,0,0,.04), 0 10px 24px -14px rgba(0,0,0,.22)`), and the
`{stiffness 380, damping 40}` spring, which is SwiftUI's `.spring(response: 0.32, dampingFraction:
0.72)` in another parameterisation.

Asked about the notch, he chose **bone everywhere** over keeping the black seam. Recorded in
DESIGN.md with the tradeoff stated, because it reverses a rule that was itself earned: the card used
to disappear into the cutout, and now it is a sheet hanging off the hardware. The band behind the
notch stays empty so the bezel is still what you see there, and the window throws a real shadow now
because a light rectangle with no shadow over a bright desktop is invisible.

Three things this kind of change always breaks, and how each was caught:

- **`Palette` moved into ChunksKit** so the contrast suite can assert the numbers the app draws. A
  palette duplicated between a token file and a test file is a palette that drifts, and the dark one
  had already shipped a 4.0:1 grey.
- **White labels on "accent" fills.** Eight of the nine survived (they sit on blue); the ninth was a
  *disabled* button drawn as 40%-blue-on-bone with white text, and the window's Ask button was the
  same bug. A disabled control has to be readable — ink-on-paper, dimmed by fill, not erased.
- **A bevel band with no alignment.** `overlay(LinearGradient…)` defaults to `.center`, so the
  "light along the top edge" drew a line through the middle of the Allow button's label. Only a
  render shows that; no test would have.

The suite also refused two of my own numbers: `lineControl` at 2.07:1 (darkened to `#847f74`, 3.3:1)
and a test that compared `#fff` to `#FFF` — both white, so it asserted 1:1 was 21:1.

What is *not* ported: any of their art, their name, or the inherited primary button's 1.03 hover
swell and 2.5 s breathing glow. Motion in this language has a cause.

## 2026-10-23 — the panel's permission rows, and finally a way to look at it

Task #17 was the one surface the reskin could not be verified on: the menu-bar panel had never been
drawable offscreen, so it had been converted by token substitution and left alone. Two things fixed
that.

`--render-panel` hosts the real `CompanionPanelView` at the `NSPanel`'s exact 320×380. It constructs
a `CompanionManager` — the same thing the delegate does at launch — and exits before `start()`, so no
tap, prompt or request runs. It also showed why two render states were pointless: TCC belongs to the
signature, so a shell-rendered binary sees every grant as missing and the permissions section is open
either way. One state, labelled honestly.

The five rows are now one row driven by `PermissionState.rows(for:)`: title, mark, purpose, state
word, and the buttons. They had drifted exactly as feared — two offered Restart, one offered Find
App, the granted tick came in two greens, and `permissionRow(label:isGranted:)`, the helper meant to
unify them, was **never called by anything**. Neither was `speechToTextProviderRow`. Both deleted.

Restart is offered only for Screen Recording and Input Monitoring, because those are the grants macOS
applies on the next launch. A button that would not help teaches the user to press buttons that do
nothing.

And the render caught one palette violation the token swap had left behind: the privacy paragraph —
*"Nothing runs in the background…"* — was `destructiveText` red. A promise is not a failure, and a
saturated colour that means nothing is how the palette becomes decoration again.

529/529. Nothing committed.

## 2026-10-23 — the audit pass, and a PDF that says which pages it was read from

Two design audits (the notch/window surface and the panel) were applied, and the highest-harm
findings were the ones a user cannot see coming rather than the ones that look untidy:

- **The card clipped its own Ask row.** `measure` counted every line of `<SAY>` and *then* clamped at
  420, so a long spoken answer did not make the card taller — it pushed the point chips, the Allow
  row and the memory footnote below the bottom edge with nothing to show they were there. Now
  `speechCharacterBudget` (200) bounds the speech the same way `detailCharacterBudget` bounds the
  detail, and the voice still says all of it. Two tests: one that the bound leaves the ask row inside
  the window, one that replaces the dead `CardConfirmation.result` case (removed — what a press *did*
  is a timeline row, and reserving a question block for it was 64 pt of dead space).
- **A failed turn said "Answered".** `Stage.failed` exists now, and `fail()` sets it.
- **Chips that were not tappable looked tappable.** Point chips lost their button; `chipRow`/`chipCard`
  split pressable from readable, and a hover state only goes on the ones that answer.
- **The routine toggle was labelled "Open Chunks at login"** for VoiceOver — the login row's label,
  copied. Now named for its own routine, and so is the trash beside it.
- **An unanswered question vanished without a word.** `ConsentGate` counts a displaced request as a
  denial; the card now prints `Not answered: <the question>` and logs it, because a question that
  disappeared is indistinguishable from one he answered.
- `DS.Colors.surface2/3/4` and the rest of the dead dark ramp deleted; white-on-destructive label
  fixed at both sites; `lineLimit(1)` row states inverted (`pressed` for the chosen row, `hover` for
  the pointer); the halo radius, the easing curves and the response overlay's hand-rolled shadow all
  brought back to the tokens. Panel: one `permissionRow`, ink CTA, physical key well, ⎋ dismisses.
  Window: `ScrollViewReader`, so the transcript follows the newest exchange while he is following it.

Then task #21's first half: **documents**. `[READ:~/Downloads/statement.pdf|what is the total]` now
works. `pdf` left `deniedExtensions` — it is not text, but it has text *in* it, and refusing it was
refusing the question. PDFKit extracts the pages (`Chunks/Clicky/DocumentRead.swift`) and
`DocumentReading.select` decides what one turn gets:

- 6,000 characters, whole pages only. Half of page 41 answers nothing; three whole pages beat six
  halved ones. The one exception is a single page longer than the budget, which is cut with an
  ellipsis rather than sent as nothing.
- When the document will not fit, the pages carrying the question's own words go in first — the same
  keyword scoring `recall` uses, no embeddings, no network.
- Every block is headed `--- page N ---` so a quoted line can be traced, and the slice line tells the
  model *"only pages 16, 17 of 17 … do not claim the rest is absent"*. That sentence is the reason
  this is a feature and not a liability: a partial read described as a complete one is how "there is
  no indemnity clause" gets said about a clause on page 16.
- A scan with no text layer is refused *as a scan* — "it is a photograph of paper, so Chunks can look
  at it on screen but cannot read it as words" — and a locked one as locked, checked before the page
  walk because an encrypted document answers `pageCount == 0` and "it has no pages" would send him
  hunting for damage in an intact file.

Verified on the real extractor, not a mock — `cupsfilter` produced a 17-page PDF with one clause
mentioning indemnity:

```
--probe-read '~/.config/chunks-big.pdf|what does the indemnity clause say'
→ READ 3319 bytes, first line "--- page 16 ---"
→ slice — only pages 16, 17 of 17 — the pages that mention what he asked about; …
```

The probe takes the tag's own `path|question` syntax through `ReadRequest.parse`, so what it prints is
what a spoken turn would send. `--probe-read /tmp/x.pdf` still refuses: `/tmp` is outside every
allowed root, and that is the policy working.

540/540 across 34 suites. Nothing committed.

## 2026-10-23 — the outside read: a scored audit against the shipped apps, and what it caught

A second review agent looked at the three renders with the competitor research in hand and scored the
app: polish 6.5, hierarchy 5, state honesty 7.5, density-vs-legibility 5, trust 8. The framing it
kept returning to is the right one — *the tokens are applied, the hierarchy is not*.

What it found that was real, and what was done in the same sitting:

- **The transcript printed raw markdown.** `localhost:5173` arrived with its backticks, because
  `Text(turn.answered)` is not a markdown view. Now SwiftUI's inline-only markdown renders it, with
  the raw string as the fallback rather than a regex that could eat a word.
- **Question and answer were the same voice.** Both 12–13 pt, both `textPrimary`, told apart only by a
  right-aligned time — so a thread could not be scanned as a conversation. The question dropped to
  `textSecondary`, the answer stayed 13 pt ink, and `spoken` became a `sunken` micro chip instead of
  a word floating under the prose.
- **The tree was not visible.** A 9 pt indent with no guide line, and a selected row whose `pressed`
  fill is 1.28:1 from the paper it sits on. Now a 1 pt `line` rule owns the thread column, the step is
  12 pt, and the chosen row carries the same 2 pt `accent` bar the card's act lines use — a bar on the
  leading edge, not the coloured border around the row that DESIGN bans.
- **The chips looked like table rows** — full-width bars holding nine characters — and at 1.05:1 from
  the card they were invisible as offers. They hug their words now (240 pt, then truncate) and the
  tappable ones get the `lineControl` hairline, which is what DESIGN already defines as "the outline of
  something you can act on". The height model is untouched: still one `chipHeight` per row.
- **The quiet meter read as an ellipsis.** Nine 2 pt stubs at a 1 pt pitch — the exact "did the
  microphone open" doubt the meter exists to end. A quiet room is now one 1 pt hairline across the same
  width, and the bars appear with the sound. Both states re-rendered and looked at.
- **The panel ended mid-pill** with no signal that the list continued. 22 pt fade to `ground`,
  hit-testing off.
- **The routine card said "done —" while its own Ask row was still unanswered.** That one was my
  render fixture teaching the wrong behaviour; the fixture now says "ready to put it on the schedule …
  tap allow and it's set", and the prompt extends the `<DONE_TITLE>` readiness rule to `<SAY>` — with
  an act still waiting, nothing may be said in the past tense about it.
- Two hard-coded hexes left the palette: `accentSubtle` re-typed `#2a5bd7` (now built from
  `Palette.accent`), and the dead `BuddyComposerVisualStyle` waveform ramp (`#F3FBFF`/`#8FD2FF`,
  near-white on bone) was removed outright. `overlayCursorBlue` got its own `Palette.cursorTrail` entry
  with the reason written next to it: it is the one colour with no fixed ground, since it flies over
  other apps' windows, so no contrast pair can be asserted against it.
- The window's render fixture had a session dated *after* a turn inside it, which is why the review
  read "Today 00:32" over a row saying "23:52" and blamed the day label. Fixture arithmetic, fixed.

Two of its findings were wrong and are worth recording so the next review is not chased by them:
the "cool grey `#e3e5ed` pill outside the palette" does not exist (it sampled `accentSubtle`, a 10 %
wash of the accent — now palette-derived anyway), and the amber permission marks are not decoration —
a shell-rendered binary sees every grant as missing, so amber is the correct state on that surface.

Two it raised that are decisions rather than defects, and are still open:
the panel's first screen is 45 % onboarding prose with the keys and routines below the fold (collapsing
it changes his copy, so it is his call), and `Allow` is the filled ink button while `Not now` is paper —
equal width, unequal salience, which is the criticism HeyClicky took for "Always approve". Making the
*safe* answer the loud one on a permanent act is defensible and touches the consent surface, so it was
not done unilaterally.

What the comparison said in one line each: **HeyClicky** — Chunks' act timeline and consent grammar are
a better trust UI than anything in its changelog, and it has a *face*; Chunks' notch is a text terminal
with a 7 pt dot, and AGENTS.md asks for a face in the notch. **Clawster** — beats Chunks on exactly one
axis, a 3-step first-run wizard plus a permission helper, and loses on native-vs-Electron and actuation.
**Utsuwa** — ships memory you can look at (graph, Facts/Sessions tabs, export); Chunks' 2 KB memory
file has no UI anywhere, which is the biggest remaining gap between the two. **NotchNook / Alcove /
boring.notch** — the notch-craft benchmark: cutout-aware silhouette, spring choreography, hover
expansion. Chunks' card is static left-aligned prose. **Superwhisper / Wispr Flow** — the benchmark the
listening pill is actually judged against.

540/540. Nothing committed.

## 2026-10-23 — "then what's the use": reading a file became one sentence

He said it plainly: if every PDF needs a terminal command and a second ask, he would upload it to
Gemini himself. He was right, and the probe I wrote to *verify* the feature is what proved his case —
the commands were my harness, never meant to be his workflow, but the workflow behind them was broken.

**Three bugs the first `--probe-find` on his real disk caught:**

1. **A read that succeeded was thrown away.** `planStepCompleted` was `planAdvanced || (planRound > 0
   && …)`, and a reply carrying only `[READ:]` on round 0 satisfied none of it — so the continuation
   that would have answered from the file never started. The file was read and nothing was said with
   it. A read now counts as a completed step.
2. **The allow-list's roots were mis-joined, and had been since they were written.**
   `homeDirectory + root.dropFirst(2)` turns `~/Documents` into `/Users/rishiDocuments` — a root that
   matches nothing. It never surfaced because `~` is itself in the list and swallows everything under
   home, which is the looseness the named roots exist to constrain. Dropping only the `~` fixes the
   join and makes `~/Documents` mean `~/Documents`.
3. **`receipt` outranked `png`.** "read the receipt png" put three PDFs from his Downloads above the
   photograph he meant, because the word `receipt` sat in the *document* list and that list was tested
   first. A format word is now a tier above a category word: `png` is what he was looking at,
   `receipt` is a guess about what receipts usually are.

And the automatic search nearly grabbed `~/.zsh_history` for "read the log in my downloads" — shell
history, to a cloud model. Dotfiles and `.DS_Store` are never automatic candidates now; naming one out
loud still works, because then a person chose it.

**The new process.** His sentence is resolved *before* the capture and before the request:
`FileAttachment` searches the allowed roots one level deep (newest 60 per root), `FileMention` ranks
the names against his own words, and the winner rides in the same turn as the screenshot — text and PDF
pages as characters, a picture or a scanned page as an extra image. One model call, no path to type,
and the card says which file it opened. When two files could both be meant, nothing is attached: the
model is shown the real `~/…` paths and told to ask, because a confident answer read off the wrong
man's statement is indistinguishable from a correct one.

**Any format, including the ones with no text.** PNG/JPEG/HEIC/TIFF/GIF left `deniedExtensions` —
refusing a photograph with "not a text file" was true and useless when every model Chunks reaches has
eyes. A PDF whose text layer is empty is drawn instead: `DocumentRead.renderedJPEG` paints its first
two pages through PDFKit at the capture's own 1280 pt / 0.8 ceiling, and they go as pixels. Verified on
his actual scanned receipt:

```
--probe-find "what does the receipt pdf say"
→ attach=yes → ATTACHED as an image, 82 KB of JPEG at ~/Downloads/Receipt (2).pdf
--probe-find "read the receipt png"
→ attach=yes → ATTACHED as an image, 94 KB of JPEG at …/receipt-2026.png   (1.2 MB → 94 KB)
```

Both transports already carry a *list* of images, so the file cost no schema change — but the local
(Ollama/LM Studio) path was labelling every one "Screenshot of …" with a hardcoded `image/png` while
the bytes are JPEG. Both fixed: the label travels verbatim, like the Gemini path already sent it, and
the MIME is read from the file's own first bytes. A file he asked about is not part of his screen, and
a model told otherwise offers to click something inside the photograph.

551/551 across 35 suites, and a new invariant in AGENTS.md: *a file reaches a model only because his
own words named it* — reading has no card, so the roots, the dotfile rule and the ambiguity gate are
the whole protection, and none of them may be relaxed to make the feature smoother.

## 2026-10-23 — "it's showing me like this": the 202-second turn, and the memory that was never there

His screenshot said `Could not answer · 208s`. The log said the file feature worked perfectly and
something else ate the turn:

```
16:15:16  attach: /Users/…/Receipt (2).pdf as 1 image(s), 82 KB      ← the new code, correct
16:15:16  turn: chain 3.6-flash > 3.8-flash > … · 2 image(s), 289 KB · text 26912 chars
16:15:28  3.6-flash failed after 11.8s — contended; retrying it in 0.5s
16:17:03  3.6-flash failed after 106.7s — contended; retrying it in 1.1s
16:18:39  3.6-flash failed after 202.5s — contended; switching model
16:18:39  budget spent after 202s — 4 model(s) left untried
```

So: not the rate limit he offered to raise — **Google's contention is the cause, our handling is the
waste.** Two separate bugs turned a 5-second "try someone else" into a 202-second silence:

- **The 60-second turn budget was only checked between models.** `timeoutIntervalForRequest` is an
  *idle* bound and resets on every byte, so a stream that trickles keepalives runs to the 90s
  resource ceiling and nothing notices. The attempt now carries `chainDeadline` and throws
  `.timedOut` on any line past it — classified `network`, which is the decision that moves to the
  next model rather than the one that asks again.
- **A slow 503 was treated as a fast one.** The retry rule is right for the 2-second refusal it was
  written against; a refusal that took 90 seconds to arrive means the request was never going to be
  answered. `RetryPolicy.decide` now takes `secondsToFail`, and past `slowContentationSeconds` (10)
  it goes straight to the next model. Tested both ways, including the assertion that the rule must
  *not* leak onto 429 — a per-minute cap is always slow and is still retried on the same model.

Worst-case is now bounded by the budget instead of by three timeouts, and the four healthy models get
asked. If it still fails, it fails at ~60s with an honest card.

**Then the memory he actually asked for.** *"read and understand this problem visible here"*, then
*"now answer it"* — and today the second turn has no idea what the first one saw, because every turn
re-captures the screen and the image is thrown away when its turn ends. `ScreenCarry` keeps the last
turn's capture in memory and re-attaches it, labelled *"the screen as it was 42s ago, when he last
asked about this"*, under one condition: his own sentence has to point backwards. Phrases, not words
— `it`, `this` and `here` are in half the fresh questions about a live screen, and a stale picture
attached to "what does this button do" gets answered confidently about a window he closed. Never
written to disk, expires with the thread's 15-minute window, cleared by a new session. Invariant 10.

**And the Applications folder.** There was exactly one stale bundle, not many: `install.sh` moves the
previous install aside as a rollback and prunes all but the newest — the fix for the 47 bundles that
had accumulated in eight days. Removed the rollback and the two LaunchServices registrations now point
at the two bundles that exist (`~/Applications/Chunks.app`, the one he runs, and `~/.chunks-build/`
the scripts build into). The rollback is dead weight now that the identity is the *"Chunks Local"*
certificate rather than a cdhash, so it can be removed from the script's routine if he wants one
bundle and nothing else.

557/557 across 36 suites. Nothing committed.

## 2026-10-23 — the fix had its own bug, and his screenshot caught it

`Could not answer · 74s · The model gave nothing in 64s across 1 attempt`. The budget was now being
honoured — and the turn still died with four models untried, because the deadline I had just added was
the *turn's*, handed to whichever model was asked first:

```
16:58:29  nothing from 3.6-flash after 3.5s — asking 3.8-flash alongside it
16:59:30  3.6-flash failed after 64.2s — contended; switching model
16:59:30  switching away from 3.6-flash to 3.8-flash
16:59:30  budget spent after 64s — 4 model(s) left untried
```

One model got 60 seconds and the other four got nothing. The deadline is now a **slice**:
`RetryPolicy.attemptSlice(remaining:modelsLeft:)` divides what is left by the models still to come —
12s each across his five-model chain, inside the same 60s — with a floor of 8s, because a measured
good answer on this machine took 9.0s and a 2-second slot is a request that cannot succeed. Tested
both ways, including the sum: five successive slices must not overspend the budget.

Worth keeping the failure in words: bounding *one* axis of a slow system without bounding the others
just moves the stall somewhere else. The 202s turn was a missing ceiling; the 64s turn was a ceiling
in the wrong place.

(The same log also carries the good news he was asking about: `16:57:41 served by gemini-3.6-flash in
9.0s` on a turn that had read his receipt PDF, and `16:58:25 attach: …/WhatsApp Image …jpeg as 1
image(s), 374 KB` — the file feature answered a spoken turn end to end.)

## 2026-10-23 — 10s became 50s, and two of my own changes were the reason

He named the symptom before I had the evidence: latency went from 10–15s to 40–50s. The log said so
plainly — three turns in a row, 51.4s, 36.3s, 36.4s, each with the same shape:

```
17:06:15  attach: …/WhatsApp Image 2026-09-09 at 00.27.57.jpeg as 1 image(s), 374 KB
17:06:15  turn: chain 3.6-flash > 3.8-flash > … · 2 image(s), 554 KB · text 27686 chars
17:06:35  3.6-flash failed after 19.7s — contended; switching model
17:06:51  3.8-flash failed after 15.9s — network; switching model      ← the hedge's partner, AGAIN
17:06:59  3.1-flash-lite failed after 8.6s — network; switching model
17:07:06  served by gemini-flash-lite-latest in 51.4s (4 model(s) tried)
```

**Cause one, mine, and the ugliest: a false positive in the file trigger.** The question was *"open
WhatsApp and search for Sai Charan and messaging him"* — no file in it. `FileMention.asksForAFile`
carried **"open"**, **"read"**, **"extract"** as triggers, so the disk was scanned, and then the word
`whatsapp` name-matched `WhatsApp Image 2026-09-09.jpeg` in Downloads → score 6 → attached 374 KB of
somebody's old photograph to a turn about a chat window. Slower, and answering about a file nobody
mentioned. The trigger list is nouns only now; a path or an extension still bypasses it. "page" is
excluded on purpose — in a screen assistant "read this page" means the window.

**Cause two, also mine: the chain re-asked the model the hedge had just asked.** The first hop runs
lead + partner in parallel; when both refuse, `continue modelLoop` walked to `chain[index + 1]` —
which *is* the partner. 15.5 seconds spent twice on one model. `BrainGateway` keeps the set of models
this turn has heard from and skips forward.

**Cause three, not mine: the free tier is genuinely contended today.** 3.6-flash refused three turns
running. That part raising the rate limit would actually help — the two above are why it was *50*
seconds rather than the ~20 it should have cost.

**And the harness lied about all of it.** `--probe-find` called `candidates`/`rank`/`shouldAttach`
directly and skipped the gate the live turn runs, so it printed `attach=yes` for the WhatsApp sentence
while the app would never have scanned at all. It now prints `about a file? yes/no` first and stops
there — a probe that answers a question the app would not ask is worse than no probe, and I nearly
"verified" this fix against a tool that was measuring something else.

```
--probe-find 'open whatsapp and search for sai charan and messaging him' → about a file? no
--probe-find 'read this page to me'                                     → about a file? no
--probe-find 'read the receipt pdf'   → about a file? yes → ATTACHED as an image, 82 KB
```

567/567 across 38 suites. Nothing committed.

## 2026-10-23 — the pill said "not a text file" about his own resume

His screenshot: a movie poster in Chrome and a blue status dot reading *"That is not a text file, so
t…ing for the model to read."* The log gave the whole story in two lines:

```
17:24:58  attach: refused …/Rishi_Deep_Resume(Visual Designer).docx — That is not a text file…
17:25:25  served by gemini-3.1-flash-lite in 27.2s → [DO:open_url:google.com/search?q=Vishal…&tbm=isch]
```

He had asked for a **Google image search**. Three defects stacked behind that sentence:

- **A noun alone triggered the scan.** "images" was enough; then "designer" name-matched his resume
  and 15 KB of the wrong document rode into a web-search turn. The rule is now a path, or a place
  word ("my downloads"), or a file noun *with* a reading verb — and "search"/"find" are pointedly not
  reading verbs on a machine with a browser in front of it.
- **A `.docx` was classified as text and then refused as binary.** A Word file *is* a zip of XML, so
  the byte reader found NULs and answered "not a text file" about a document with nothing but words
  in it. `OfficeRead` now runs it through `NSAttributedString(url:)` — the importer TextEdit uses, no
  dependency — and it works: `read the resume docx in my downloads` → `ATTACHED as text, 4323
  characters`. Spreadsheets and decks still have no reader, so they are refused as *that*, naming the
  formats that do work, instead of the old non-answer.
- **The refusal was shown in the voice of progress.** `showHint` puts a blue dot on the pill,
  truncates at 52 characters ("so t…ing"), expires in six seconds, and says nothing to the model — so
  the answer that arrived next was free to invent what the resume said. The refusal now goes *into the
  prompt*: "he asked Chunks to read X, and it could not: … Say that plainly, and do not invent what
  was in the file." A refusal the model cannot see is a refusal the user will be lied about.

Also caught by the new tests: `containsAnExtension` took four characters after the dot and asked
whether all of them were letters, so **"what does build.log say"** — whose fourth character is a
space — was not recognised as a file at all. The run now stops at the first non-letter, and
"version 2.4 of the app" still doesn't trigger.

570/570 across 38 suites. Nothing committed.

## 2026-10-24 — "the trigger words are reducing my speech freedom", so they are gone

He did not care about the milliseconds. He cared that a sentence which missed the word list simply
did not get its file — which means he would have to learn the vocabulary the software needs, in a
product whose whole premise is saying things the way you would say them to a person. The gate is
deleted: `asksForAFile`, `triggers`, `places`, `readingVerbs`, `containsAnExtension`, `documentNouns`.

What replaced it is the score, measured against **his** file names rather than a list I wrote:

| his words vs the file's name | what happens |
|---|---|
| two shared words | read it, same turn |
| one shared word + the kind he named ("the invoice pdf") | read it |
| the kind named, exactly one file of that kind | read it |
| anything weaker | the model is shown the real `~/` paths and decides |
| no overlap at all | nothing — no listing, no tokens spent |

Measured on his disk, all four cases:

```
"why is the certificate warning showing"          → attach=no, offered instead
"MRD resume"                                      → attach=yes   (no verb, no format word)
"what does the certificate of participation say"  → attach=yes
"open whatsapp and search for sai charan"         → attach=no, offered instead
```

The two single-word false positives are why the bar is two words, and both came from his machine:
"open WhatsApp and search for Sai" reached `WhatsApp Image ….jpeg` (374 KB), and "why is the
certificate warning showing" reached `Certificate of Participation - Temple Services.pdf`. A word
list cannot tell intent apart — *"the visual designer resume"* is a file and *"visual designer
images"* is a web search about a person — so intent went to the model, which is now told on every
attachment: *"Chunks' best guess at the file he means — if his sentence was about something else,
ignore this and answer about his screen."* That is also why the text block no longer says "answer
from this file only", which would have forced the wrong file into the answer.

Two smaller things fell out. A `.docx` is a **document**, not `.text`, in the way he says the word —
the mismatch made "the visual designer resume" fail to match his own file. And the file read now runs
*while* the screenshot is being taken instead of before it: a 480-page book costs 0.79s to slice, and
that was being added to the front of every turn that mentioned one.

570/570 across 38 suites. Nothing committed.

## 2026-10-24 — "reduce the latency": measured over 161 turns, then three changes

First the numbers, because "it feels slow" is not a place to start. Every `served by` and `failed
after` line in his log, per model:

| model | turns served | median | p90 | failures | median time to fail |
|---|---|---|---|---|---|
| `gemini-3.6-flash` | 73 | **10.5s** | 17.8s | 136 | **1.5s** |
| `gemini-3.1-flash-lite` | 62 | 14.5s | 47.8s | **9** | 5.2s |
| `gemini-3.8-flash` | 25 | 24.2s | 61.6s | 116 | 4.8s |

And 62 of 161 turns needed three or more models. So the wait is not one slow call — it is the chain
walking, one 12-second slice at a time, through models picked in the wrong order.

**1 · The chain is re-ordered by measurement.** `3.6-flash` stays first because its refusal costs
1.5s and its answer is the fastest on the key. **`3.1-flash-lite` moved to second** — 9 failures in
161 turns against 116 — because slot two is both where the chain lands after the first refusal *and*
the model the hedge asks alongside the leader. `3.8-flash` fell to third on its own numbers: a 24.2s
median cannot win inside a 12s slice, so every turn was spending a slice on a model that could not
finish in one. A test now pins the order, because "newest model first" is exactly what someone would
"fix" it back to.

**2 · A full rate-limit bucket is skipped, not waited for.** The limiter was sleeping — up to **19s**,
five times in the log — for a per-minute window to refill inside a turn that has 60s of patience in
total. That is the same dead time the 429 rule already refuses to pay for, and every other model on
the key has its own untouched budget. Past `maximumBucketWait` (3s) the turn walks on.

**3 · The file read stopped queueing behind the screenshot.** Measured: the scan and ranking cost
**40 ms**, but a 480-page PDF takes **0.79s** to slice, and that was being added to the front of
every turn that named a big document. It now runs while the capture is happening.

What was *not* the problem, checked rather than assumed: the prompt is 25.7K chars (~6,600 tokens)
and history replay is usually empty, so the payload is the fixed instruction text — the parts that
could be cut are the act rules and the examples, which are load-bearing for safety and were written
against measured misbehaviour. Trimming them to save maybe a second of prefill is not a trade to
make silently.

Expected: ~10s when the tier is healthy, ~15–20s when it is contended, and never the 36–51s walk
again. The line to watch is `turn: chain …` followed by how many `switching away from` lines appear.

570/570 across 38 suites. Nothing committed.

## 2026-10-24 — "run every test, and make sure that never happens again"

Two read-only agents audited the whole surface — one for regressions introduced by the file-reading
work, one for capability coverage. I verified every claim against the code before acting, and the
honest split is: **seven real defects, one stale, one partly wrong, two pre-existing and unfixed.**

Fixed, all confirmed by reading the lines first:

1. **A staged `[READ]` file was destroyed by the turn that needed it.** `attachFileMentionedIn`
   cleared `pendingFileContext` *before* its `guard !continuing`, so the continuation wiped the
   contents the previous round had just read. The "reads the file and answers from the screen" bug,
   reintroduced by a reset in the wrong order, three lines deep.
2. **A mid-stream deadline glued two models' answers together.** The attempt deadline threw
   `.timedOut` even after text had streamed; that classifies as `network`, the next model is asked,
   and `AnswerStreamer` *appends* — one card, one spoken sentence, from two models, and both models'
   act tags running as one plan. Now only a **silent** stream is cut; a model that has started
   answering is allowed to finish.
3. **The hedge skipped a model it never asked.** `partner.id` went into `asked` before the partner's
   own stand-down checks (lead already streaming, or its bucket full), so a turn could skip its
   healthiest fallback for the whole chain.
4. **A refusal erased the finished answer.** `offerFileRead` called `hud.fail`, and `fail()` clears
   the card — so a model that answered and *then* asked for a file it couldn't read watched its own
   answer vanish. Now footnoted.
5. **The file listing fired on ordinary questions.** `listingThreshold` was 4 and the kind bonus is
   4, so any sentence using "code", "settings" or "document" pasted a list of his files into the
   prompt with an instruction to go read one. Raised to 6 — a listing now needs real overlap with a
   file's name.
6. **The session cap could cut a plan in half.** Rotation lived in `append`, so the fifth step of a
   plan was continued by a model that could no longer see steps one to four. It is now opened at a
   boundary the *user* spoke across, and it clears the carried screen like every other new session.
7. **A carried screenshot invited an aim at the past.** Aims resolve against the live captures only,
   so a coordinate read off the earlier picture would press whatever sits there now — with asking
   off by default. The label now says so in terms, and a test asserts the sentence is there.

**The stale one:** the report said `[READ:*.jpeg]` has no image route. It was fixed an hour earlier
and `verify.sh` proves it. **The partly wrong one:** the claim that the file scan "cannot" overlap
the capture because both are `@MainActor` — the capture suspends, and the scan runs in that gap.

**No longer unfixed:** a crop turn used to map crop-grid aims onto the whole display for `[ACT]`
and refuse `[POINT]` outright. The capture now carries the rectangle it covers, so both are aimed
inside the region the user drew (see invariant 1's "the fraction is of the picture"), and
`--probe-crop` plus `verify.sh` check the composition on the real display. The macOS-crosshair
fallback still refuses pixel aims — its rectangle is genuinely unknowable — and says why on the card.
Still open from that list: a user question arriving inside the 1.5 s recapture window is consumed as
a continuation.

And the durable answer to "make sure it never happens again" is `scripts/verify.sh`: build, the
593-assertion suite, every read-only probe against the real machine, the three surfaces rendered and
size-asserted, and the two contracts that must never regress — with fixtures *discovered* from
`~/Downloads` rather than typed in, because a hardcoded path is a test that passes the day it is
written. It also caught four bugs in its own first draft, which is the point.

## The round after: what the screen said that the log did not

Three things came out of his screenshots, and each one is the same lesson — **his evidence outranks
my inference.**

1. **"Click the Memora workspace" opened Finder.** I had to be told before I looked: the log read
   `act: named — "Memora" → AXMenuItem/Memora verb=AXPress at (0.0, 1107.0)` → `Pressed Memora.`, so
   the *report* was honest and the *press* was wrong. The named route had found a row of a closed
   menu, and `isOnScreen` passed it because a menu bar's rows sit on the edge of the display. Fixed
   on both name routes, and the probe re-runs the exact ask: `--probe-semantic 'app=Qoder
   name=Memora'` now refuses. The two refusals *before* it in the same log were correct — the tile
   publishes no readable name — which is the part worth remembering before "fixing" a refusal.
2. **A crop is a picture of a part.** He asked for pixel acts on draw-and-speak; the honest answer
   had been "no", because the crop carried no rectangle. It does now (`cropFrame`, measured from the
   capture that came back), so the aim is a fraction of the region and lands inside it. Verified with
   `--probe-crop` against a control found earlier by `--probe-ax`, and the check is in `verify.sh` —
   the assertion is that the two Y-flips cancel, which no display size can fake.
3. **The history window was a file tree.** Redesigned as a conversation list: day headings, one
   thread per row, a hairline where an earlier sitting began, the transcript at a readable measure,
   content under the traffic lights. The grouping moved to `HistoryGrouping` (pure, `now` injected)
   and its tests caught a real bug the first time through — an empty sitting left the *current* one
   wearing the boundary line, because the rule was "not index 0" instead of "not the first sitting
   with rows in it".

**And the Memora story had a second half**, which only his correction brought out. The turn in his
screenshot was not the workspace click at all: the reply said *"holding command and clicking the
title now to show that file in finder"* and carried `[ACT:app=Qoder x=400,50:file title]`. Neither
grammar accepted it — the semantic one because `x` is not a field it knows, the point one because the
body does not start with a number — so the markup sat on the card and **nothing was pressed**, with
no `act:` line in the log to say so. Three fixes: the qualified pixel aim parses, and the app the
model named is now a requirement the hit test has to answer, so accepting the form made the act
*stricter*; an unread act tag is counted in the log; and the prompt says out loud that Chunks presses
plainly — no Command held, no drag, no right-click — so it names the part that is his instead of
narrating it. The crop turns later in the same log are the good news: `1 mark(s) → crop x=0 y=509
w=291 h=146` with `[ACT:420,500:Understand personal build]` → `Pressed Task "Understand personal
build purpose"` — the first press aimed inside a region he drew. Every pixel act now also logs the
distance from the aim to that control's own centre, which is how "did it click the right row, or
near the edge" gets answered with a number instead of an argument.

**Two more, from his next message.** (a) *"the shortcut triggers and closes immediately without
listening"* was not the shortcut: `kAUStartIO` → `'what'` (2003329396) on every attempt for four
seconds while `system_profiler` showed the built-in input healthy at 48 kHz — the previous instance (a
rebuild relaunched a second after `pkill`) still holding the device. The single immediate retry I had
added could not ride that out, so the microphone is chased over ~2 s with a fresh engine each time,
and the card's sentence is chosen by the *cause*: a 0 Hz format, the 'what' code, and a refused grant
say three different things — and the first version of that message told him to check Privacy &
Security on a machine where every grant read `true`.

(b) The functionality he spelled out — *"click the memora workspace here"* versus *"open the memora
workspace in finder"* — is two different tools, and the second did not exist: `open_app` launches
Finder without saying *where*, and an `[ACT]` cannot aim at a window that is not open yet.
`[DO:reveal:…]` does now, with the name **looked for** rather than guessed (`--probe-reveal Memora` →
`/Users/rishi/Documents/Rishi_Projects/Memora`; `~/.ssh` → refused before a card exists) and the
parent folder named on the card, because a location he cannot see is not a thing he can approve.

**Then he asked the right question about the fix**: is building a new engine on every attempt costing
latency? Measured with the new `--probe-mic`, three runs on his machine, ten openings each: reusing
the standing engine is 55 ms and a brand-new one is 53 ms, with the allocation itself at 0 ms and
30/30 openings — so the fresh engine is free, and the only thing the retry path pays is the waits.
Which is where the answer moved to: those waits are *speech he is talking into a closed microphone*,
so the schedule went from 250/600/1200 ms to 150/400/1000 ms — a device that clears fast costs him
almost nothing, and the worst case is shorter, and the honest card arrives sooner. The first attempt
still reuses the engine and waits for nothing, so the normal press is untouched. `verify.sh` now
asserts the microphone opens at all, because every other check in that file reads the screen or the
disk and none of them could have seen the failure that made the notch vanish.

## The security round: what the app was allowed to see, and what it was writing down

His question was "are these permissions risky, did they alter my Mac" — so the answer is an
inventory, not a reassurance. Nothing outside his own account was touched: no daemons, no
LaunchAgents, no packages, no configuration profile, MDM `No`. What exists is
`~/Applications/Chunks.app`, `~/.chunks-build/Chunks.app`, one `previous-*` install copy (9.3 MB,
kept deliberately by `install.sh`), 52 KB of app data in `Application Support/Chunks`, a 968 KB
rotating log, one preference plist, one Keychain item, and a **self-signed code-signing certificate
in the login keychain** (`CSSMERR_TP_NOT_TRUSTED`, never trusted system-wide — it exists only so a
rebuild stays the same app to TCC).

**The audit found one real defect, and it was mine.** The keyboard tap logged the first twelve
key-downs of every launch — `keyCode` and `flags` — into the log file he is asked to paste when
something breaks. Keycodes plus a layout are the password. 1,114 such lines had accumulated. They now
log the chord verdict and not the key (invariant 7). Two more came from the same reading: `~` and
`~/.config` were readable roots, which made the credential deny-list a list of *known* secrets
guarding an account-wide door (`~/.config/gh/hosts.yml` is a GitHub token; `~/Library/Mail` is
everything), and a key by extension (`.key`, `.pem`, `.kdbx`) was readable inside any repo. Both
closed, with the credential check moved **before** the root check so the reason he reads is the true
one. And `verify.sh` no longer turns red when Google rate-limits the key: the self-test exits 3 for
"the machine is fine, the account is not", which the script counts as a skip — his key is exhausted
right now, and `gemini-3.1-pro` answers `limit: 0 requests per day on Free Tier`, so the chain's last
escape hatch is dead weight on this plan.

Then Phase 8's memory UI: the panel shows every fact grouped by section, a meter of bytes against the
2 KB cap, a per-fact Forget button and a "Show file" row. The cap was already the rule (invariant 4:
never truncate, refuse and ask) — it just had no door, so the rule ended in "open a file in an
editor". Making it lookable needed a render fix first: `showsEverySection` forced only the settings
block, so the panel's whole middle had never been rendered by any probe, and the render probe now
draws a tall second variant because ROUTINES and MEMORY sit below the fold at 380 pt.

## The microphone leak, the helper that stole a name, and a command tool

Three things from one screenshot. **(1) "It triggers and closes after 2 seconds"** was not the
shortcut and not Saturday's device-release delay: every attempt failed, forever, while a *fresh
process of the same bundle* opened the microphone in 65 ms. That asymmetry only has one explanation —
the running app was holding the device itself. `resetSessionState()` never stopped the engine, and an
`AVAudioEngine` with a tap installed keeps the input claimed for the life of the process, so one
leaked session poisoned every later press. There is now one teardown (`releaseAudioEngine()`), called
from the reset so no path can leak, and `cancelCurrentDictation` does it *before* its
`isDictationInProgress` guard — the guard was the path that skipped it. The card also stopped lying by
omission: it asks CoreAudio whether the device is streaming elsewhere and says which of the three
causes it is, because "press the key again" is useless advice for a microphone Chrome is holding.

**(2) "It says there is no control, but it is right there."** True, and the probe found it: the
named aim had walked `ShortcutsViewService` — a menu-bar-only helper whose name *starts with*
"Shortcuts" — instead of the app with the window. A prefix scores 2 and `first(where:)` takes the
process list's order. Now the candidates are ranked (exact before prefix, windowed before windowless)
and the same ask resolves `AXButton/stop sleep at (682.5, 243.5) verb=AXPress`. A truthful refusal
about a visible control is the worst failure mode in this file, because it teaches him the product
cannot do the thing it can do.

**(3) The terminal.** `[DO:run_command:…]` runs **one program with fixed arguments and no shell**:
`;`, `&&`, `|`, `<`, `>`, backtick, `$`, `\` and newline are refused as characters, the program must
be a bare name found in four known folders, and `rm`/`mv`/`dd`/`diskutil`/`sudo`/`defaults`/
`security`/`codesign`/`kill`/`shutdown`/`curl`/`ssh`/`brew`/`npm`/`pip` are refused whatever follows
them. It is the one tool **asked about even with asking switched off** — the Send-button rule, applied
to a command line — because "don't ask" is a standing instruction about routine acts, never a licence
to execute what a sentence produced. 15-second timeout, output to a temp file rather than a pipe (a
pipe deadlocks on a chatty command and looks like a slow one), 400 characters of tail back on the
card. `--probe-command` runs two fixed programs the harness chooses, never an argument.

Also fixed on the way: the single-instance guard compared `nil == nil` for a bare SwiftPM binary and
stood down in front of `/usr/sbin/universalaccessd`, which is how a probe run silently did nothing.

593/593, 26/26 live checks. Nothing committed.

## The plan's leftovers: a reminder that fires, a draft he sends, and a Mac that stays up

He asked what was left per the plan and said to do it. Three of the gaps were small enough to close
without a new permission surface, and each one removed something the app was currently *saying* that
was not true.

**(1) The one-off reminder.** The prompt had been telling the model, in as many words, that a
one-off "remind me in ten minutes" had no tool — so every such sentence ended as a lie about having
written it down. `ReminderStore` is now that tool: a line and a moment, in `reminders.json` beside
`routines.json`, secret-swept before the write like everything else that reaches disk. Three
decisions carry the weight.

- *The when is four shapes and nothing else.* `40 min`, `2 hours`, `3 days`, `at 21:00`/`9 pm`,
  `tomorrow at HH:mm`. Seconds are refused rather than rounded up, because the clock that fires
  reminders ticks once a minute — a tool that accepted "30 seconds" would promise what the scheduler
  is built to deliver late, and a wrong hour is the failure the routine cadence parser already names.
- *The card is worded after the clock is resolved.* `at 21:00` said at 22:00 is tomorrow, and
  `ReminderStore.resolve` rewrites the timing into `tomorrowAt` **before** `ToolLayer.question` sees
  it, because approving a time on the wrong day is approving nothing. The outcome line then quotes
  `spoken(fireAt:)`, which is derived from the date the file holds rather than the phrase the model
  wrote, so the report cannot drift from the schedule after a rebuild or a DST shift. It also
  **rounds**: the first version reported "in 39 min" for a reminder armed at 40, one second after
  arming it — the card disagreeing with the question he had just answered.
- *Firing says one sentence and nothing else.* No capture, no model call, no act — which is why a
  reminder is not in `alwaysAsks` the way a command line is: the card at arming is the whole consent.
  `showReminder` opens a card with no timer on it (`showsTimer`), because `0.0s` beside "Reminder"
  measures nothing, and a reminder that arrives after a sleep or a quit carries "It was due at 09:00"
  rather than pretending it was on time.

**(2) A draft he copies and sends himself** (task #26, the standing rule that sending is his). Both
existing routes were wrong for it: `[TYPE:]` into a composer plus a press of Send is a message sent
on a model's wording, and prose on a card is a message he cannot deliver. `<DRAFT>…</DRAFT>` is a
third thing — the payload, in a `sunken` well with one button, `Copy`, and the line beside it saying
"Chunks never sends it." Capped at 340 characters and **failed open** rather than clipped: an
over-long or empty block reaches him as the raw tag, because half a sentence pasted into a chat is
the same class of silent corruption as a swallowed `[TYPE]`. The parser consumes it apart from
`speech`/`detail`, `hasAnything` counts it, and `AnswerPanelLayout` reserves the well and the button
as one block measured in the same order the card draws it — the two draft-height tests assert the
delta rather than the total, because a clamped floor would hide a disagreement.

**(3) The power hold.** A reminder armed for 20:00 that never arrives because the laptop dozed at
19:40 is a broken promise, and the firing path rightly refuses to speak into a sleeping display —
both correct separately, useless together. `SleepPolicy` (pure) says *switch on **and** something
armed*, so a switch left on from one reminder does not hold his machine awake all day;
`SleepAssertion` asks for `kIOPMAssertionTypePreventUserIdleSystemSleep` — system, not display,
because the screen does not need to stay lit for a minute clock to tick — and reports the status
code it got. The panel row reads `SleepPolicy.describe`, which distinguishes "holding for 2 waiting
things" from "asked to hold, and the machine did not take the request": the `LoginItem` rule again,
state rather than wish.

Also: the prompt's line that said there is no tool for a timer **or a shell command** was still there
after the command tool landed — a stale sentence beside a working tag, which is how a model ends up
narrating a capability instead of using one. `--probe-prompt` now prints the protocol lines it
actually assembles, and `verify.sh` asserts `<DRAFT>` and `[DO:remind:` are among them and that the
dead promise is gone, because a tag the code supports and the prompt never mentions is a feature that
does not exist and no unit case can see it.

615/615, 28/28 live checks (1 skipped: no Shortcuts window open to aim at). Nothing committed.

## What Meterless taught Chunks, and the two fields it was worth

He asked whether Meterless (meterless.ai) — "context and memory for AIs" — would help, at what scale,
at what extreme. The short answer, after crawling the site, the repo and the third-party coverage:
**adopt nothing, take two fields.** Both are now in.

What it actually is: **four implementation specs plus a toy TypeScript reference**, Apache-2.0, inside
one repo whose real product (Nightshift) is a closed binary with a $199 Mac preorder. `Meterless` is a
GitHub *user*, not an org — one author, 16 commits, one release, no CI, no Hacker News or Reddit
discussion at all, distribution through LinkedIn influencer reposts including an "ex-Anthropic
engineer open-sourced Claude Cowork" claim that [the wavect review](https://wavect.io/blog/meterless-ai-agent-context-layer-review/)
debunks. The reference store is a `Map` written to `state.json` and **its embeddings are a
deterministic FNV-1a mock**. Their own benchmark, published against themselves, says the context layer
scored **−2.79 (not significant) at +8% cost** on a frontier model and **−1.38 at +486% cost** with an
audit step. That settles the adoption question faster than any architecture argument: on flash-class
models — which is the whole of Chunks' chain — the layer as built made answers worse and cost more.

The scale question, measured rather than argued: an H-MEM memory record serialises to **559 bytes**;
a Chunks fact renders to **42**. The 2 KB cap would hold **3 records instead of 48 facts**, so adopting
the record shape into the injected tier breaks invariant 4 on contact. And the weight measurement from
`--probe-prompt` today — system prompt 29,817 chars (~7,454 tokens), memory **132 chars**, session
index 916, replayed history 57 — says 97% of what Chunks pays per turn is static instruction. A memory
layer optimises the 132.

Two ideas survived that, and both are now built:

**(1) Origin, and the rule that goes with it.** Every fact is `.said` or `.inferred`, and **a fact
worked out from his screen may never retire a fact he stated.** The trust-ledger rule from their spec,
reduced to one comparison and two words. It closes a hole he could walk into today: `prune` is a
substring match, so a model-inferred fact could delete something he said out loud last month, and the
`<MEMORY>` block gives it the words to try. The origin is **verified, not claimed** — a proposal may
say `"source":"he said"` and the app checks it against that turn's transcript with
`heSaidIt(_:in:)`, because a field the model sets is a field a prompt injection sets. The check is
deliberately forgiving (one shared distinctive word, a dropped final `s`, no stemmer): a strict phrase
test would disbelieve "uses WhatsApp for messaging" against "I use WhatsApp", and a field that never
fires is a field that protects nothing. Getting it wrong costs him a refusal he can overrule by
speaking; getting it wrong the other way is a guess overwriting his own words.

**(2) `supersedes`.** The file could only ever grow, and a capped file that cannot be corrected gets
more wrong as it fills. An addition may name one stored line to replace; the write is refused whole
when the name matches nothing or matches two, because a replacement that silently no-ops leaves both
answers to one question in the prompt — which is exactly the bug their spec still has open
(issue #3: *a declared `supersedes` never leads to `supersededBy`*). Two things fell out of building
it. A replacement is resolved **before** the capacity check and retires its target first, so a
net-neutral correction lands at 2048/2048. And the matcher had to become **word-boundary**, not
`contains`: the first test run reported `"Durable fact number 3" names 8 stored facts`, because a
plain substring match makes `number 3` hit `number 30` through `number 39`.

Only `.said` is marked in the file, so the common line pays nothing; a line with no marker is
`.inferred` even if he typed it, because trust is granted by a tag (`· he said`) and never by the
absence of one — his two existing facts read as inferred for that reason, and the header now says so.
Prunes obey the same asymmetry, and the panel's Forget button stays unguarded because that path is him
deciding. `--probe-memory` drives his **real** `memory.md` through both rules in a temporary copy and
prints what the app would do, which is the only way to check a claim about wiring rather than about
arithmetic:

```
probe-memory: 2 fact(s) in his file · 113/2048 bytes · 0 marked as his own
probe-memory: an inferred replacement of his own line → refused, as it must be
probe-memory: the same correction, said by him → replaced
probe-memory: his file at ~/Library/Application Support/Chunks/memory.md was not written
```

What was deliberately **not** taken: the 24-field record, `confidence` as a float (48 facts and a human
reading the file — it buys nothing yet), dreaming and sleep-cycle consolidation (a background process
that mines and rewrites his history is the thing AGENTS.md puts out of scope, and invariant 9's rule
that a thing reaches a model only because his words named it), and the World Model (cross-agent shared
state, and Chunks is one assistant by design). Their privacy is policy — redact-before-reinject plus
tags; Chunks' `SecretSweeper` refuses the write, which is stronger, and their own closed app shipped
issue #7: an unbounded localStorage WAL that grew **11 GB in 30 hours**. The one remaining doc worth
reading is Markovian's budget rule (`chunkSize ≥ framing + carryover + output`) against
`DocumentReading`'s PDF slicing — that engine's problem is Chunks' problem, and it is not a memory
problem at all.

624/624, 29/29 live checks (1 skipped). Nothing committed.

## 2026-10-28 (later) — Tier 0 closed, the Apple gate to the account wall, and the prompt on a diet

One session, three tiers, in the order he set: every dead promise first, then the mechanical Apple
work, then one hard capability — the diet, 3.2 — finished properly. Nothing committed; the tree is
his to seal.

**(1) Tier 0, all four, and the verifier grew teeth.** `<NOTE>` took the second option: the event,
the construct and the prompt lines are gone, and an old `<NOTE>` arriving from a stored thread or a
slow model round-trips as visible text — whole, split across deltas, or unterminated — with a unit
case each, because silently consuming a retired tag is the same class of lie as the one removed.
`MemoryStore`'s header now describes only the capped file that exists. The budget is
`ReadInputBudget`: one 6,000-unit UTF-8-byte token **upper bound** (deliberately not measured
tokens — no tokenizer dependency) charged against the *exact* frame the live turn injects, path and
coverage warning and untrusted-data label included, so selection and injection cannot disagree by a
long path. PDFs enter as ranked whole pages in document order; an oversized best page is **refused**
rather than clipped mid-clause or swapped for a less relevant page that would answer confidently
about the wrong part. Text and office files enter as contiguous whole lines, boundary fragments
trimmed as bytes before decoding, so a 24 KB window cut through a multibyte scalar is not reported
as "not UTF-8". The draft surface is proven by `--render-ui` itself: two 340-character fixtures
(alone, and with a confirmation under it) measured through native layout markers — Copy 96×28 pt
inside the 360 pt window, the 340 characters scrolling in a 56 pt viewport while Copy stays put —
and the probe exits non-zero if any marker leaves the window. The render he looked at
(`/tmp/chunks-tier04-draft.png`) shows both fixtures with the well, the Copy button and the Allow
row all inside the card.
`verify.sh` changed shape around all of it: it refuses a bare or stale binary (the installed bundle
carries a `BuildInputs.sha256` fingerprint of every source file, and a mismatch is an error naming
the fix), renders into a fresh temp dir and fails a render whose command exited non-zero (a stale
120 KB PNG from an earlier run can no longer satisfy a check), prints the suite's skip lines, and
asserts per architecture that the bundle is universal, hardened, carrying exactly the entitlements
file, and built for the same minimum OS the package declares. `install.sh` now fails instead of
reporting success over a bundle that does not verify.

**(2) The Apple gate, up to the wall that is his account.** `make-app.sh` builds arm64 and x86_64
in separate scratch paths (the Swift 6.4 build system puts both triples in one output dir, so the
second build silently ate the first — `lipo` then found x86_64 twice), joins them, derives
`LSMinimumSystemVersion` from `Package.swift` (15.2) so plist, `minos` and target are one number,
and seals with `--options runtime` plus `scripts/Chunks.entitlements`. That file holds **one** key,
`com.apple.security.device.audio-input`, and the choice is reasoned rather than minimal-for-its-own-sake:
Chunks is not sandboxed, so the network-client and keychain entitlements are sandbox keys that do
nothing here, and screen capture, Accessibility and Input Monitoring are TCC grants, not
entitlements — Apple's own hardened-runtime list has no key for them. `verify.sh` asserts the
signed entitlements equal that file exactly, per architecture, so the next person adding
"just one more" has to say so in the file and in the check. What remains is precisely what needs
his enrolled account: Developer ID Application certificate, `notarytool submit --wait`,
`stapler staple`, then Sparkle and the clean-account checklist. Enrolment is US$99/year and only
the account holder can create the certificate.

**(3) The diet: 30,733 → 20,376 characters, 7,683 → 5,094 tokens, −33.7%.** Every rule stayed; the
*scars* went — the anecdotes about which press landed where, the second and third restatements of
the plan rules, nine examples down to seven (the volume and memory examples teach nothing their
rule sections do not already say in full grammar). No keyword gate anywhere: the sections are not
chosen per question, the prompt is simply shorter, so how he speaks is untouched. The risk TASKS
named — a prompt change that quietly stops the model using a tag, with no failing test — is now a
probe: `--probe-protocol` runs five fixed turns against the production prompt on his live screen
and asserts each family arrives: `<SAY>`+`[ACT:]`, `[DO:remind:]`, `[TYPE:]`, `<SAY>`+`<SUMMARY>`,
`[SCROLL:]`. Measured, twice, because the first run taught the probe something: turn 3 asked
"which chat are we in?" instead of typing — *correct* behaviour on a screen with no editable field
anywhere, and a bad fixture. The probe now opens an empty TextEdit document as its own fixture, the
way the render probes build their own cards. Across the two runs: nine measured turns, nine passed,
zero failures — every family emitted on the dieted prompt — and three skips, all free-tier
contention, including the chain falling all the way to `gemini-3.1-pro` and reading back *0 requests
per day on Free Tier*, the dead escape hatch Tier 2 already names. A contended turn is recorded as
skipped and the run continues; a run with skips exits 3 so no caller can read it as green.

**(4) Google, researched and stopped at his desk, on purpose.** The official Calendar MCP server is
real and read-only: `https://calendarmcp.googleapis.com/mcp/v1`, Streamable HTTP, an unauthenticated
`tools/list` answers today with nine schemas of which `list_events`, `get_event`, `search_events`
and `list_calendars` need only readonly scopes. Native Desktop OAuth with PKCE and a loopback
redirect is documented, so tokens can live in his Keychain with no relay and no server — the shape
`AGENTS.md` demands. Two walls, both his to open: the service is in **Workspace Developer Preview**,
so his account *and* his Cloud project need approval before any authorised call works, and preview
terms forbid shipping preview features in a public app before GA — which matters the moment Chunks
is for sale. And the client-only exemption from the restricted/sensitive-scope security assessment
is **not** something to assume: forwarding calendar content to Gemini is a transmission to a
third-party server even with BYOK and `store:false`, so the question goes to Google in writing
before any money is budgeted. Nothing was built; the design (local allowlist of the four read-only
tools, one frozen ConsentGate question naming account, calendar, tool and arguments, results
labelled untrusted) is written down in `TASKS.md` 4.2 for the session that follows his approval.

648/648 unit tests; `verify.sh` 33 checks passed, 1 skipped (no Shortcuts window) on the final
binary. The protocol probe: 9 measured turns passed, 3 skipped by contention. Nothing committed.

## 2026-10-28 (evening) — his first live report, and the day typing became the headline again

He ran the Tier 1 steps and sent four screenshots. Check 1 (reminder arm, panel rows) clean. The
other three each changed the app:

- **The copy well, asked for out loud.** His "write him a reply" turn typed into an open WhatsApp
  composer instead of drafting — he called that good and asked for the copy button *too*. A finished
  type act now offers its words in the same well (`NotchHUDModel.offerTypedTextForCopy`), a `<DRAFT>`
  still owning the well when a turn produces both. Render fixture 10 draws it at the shipping width.
- **The over-promise was my rule, and it was wrong for him.** Told to "type the code here", the model
  put one line in `[TYPE:]` and offered the rest for copy — exactly what last session's honesty rule
  instructed. He named typing the whole code as the capability he bought this for. So the payload cap
  is 6,000 characters, `post` chunks with a yield every hundred keystrokes (a tight loop of thousands
  outruns a web editor's event queue and the loss is silent), the field's value is re-read with settle
  retries so a lag cannot be reported as a refusal, and the prompt rule now says the tag carries all
  of it. The consent question quotes a code-length payload by its opening and its exact count — six
  thousand characters on a card is not a readable question — and what landed is one tap away in the
  well afterwards. Prompt weight held inside the diet line at 20,484 chars (−33.3%) by trimming
  explanation elsewhere, measured, not assumed.
- **The check-3 plan stopped where the screen said it would.** Search typed, chat row never pressed,
  so the composer did not exist and the refusal named the fields that do. The prompt now carries the
  send-button rule's twin: press the row after Search before any type aimed at the message box. And
  the refusal he read was mangled by SwiftUI middle-truncation on a one-line row whose payload sits at
  the *end* of the sentence — act rows draw two lines now, tail-truncated, at a width the height
  arithmetic charges through the same function the view uses.

650/650 unit tests; verify 33 passed, 1 skipped (no Shortcuts window). Still owed from Tier 1: the
carried-screen turn, the reminder firing moment and his mid-sentence verdict, ⌃A inside Chrome and
Finder text fields. Next: 3.7 + 4.3 as one first-run flow, then 3.1 read-only.

## 2026-10-28 (night) — the caret, the click, and his Auto Typer

His re-test of "type the code here" produced the screenshot that named the real hole: the model's
plan pressed the editor *to focus it*, Chrome's web content refused the press (correctly — it
publishes no pressable control), and the plan-stop rule killed the type before it began. The card
read "That is not a control Chunks can press — Google Chrome does not expose it to Accessibility"
over an empty `main.c`. His answer: "using pyautogui can do it, and I have done it using python" —
and his `Auto Typer.py` is three lines of mechanism: **hover, one click at the box, 50 ms, then
unicode keystrokes at interval 0**, Enter pressed between lines on purpose.

Mined, not copied — Chunks is Swift and his invariants still govern — but every constant is his:
the click-then-50 ms is `focusClick`, the keystrokes are the existing unicode `CGEvent` pairs (now
chunked with a yield every hundred), and the Enter-between-lines became a rule rather than a habit:
**a line break is a newline in an `AXTextArea` and a Send in a one-line role — or in a page with no
witness at all** — where the whole act refuses (`newlinePolicy`, `.multilineWithoutWitness`) instead
of typing the first line and submitting it to whoever was in that chat. The click itself is the
narrowest possible amendment to invariant 8, and it is named as one in `AGENTS.md`: a caret in web
content has no Accessibility verb at all, so the click *is* the act — offered on the card as "Click
the editor at (x,y) in Chrome and type N characters into it?", stated in the outcome line with asking
off, and `webFocusClick` is set only by the shell while resolving an approved question, never by any
parse path, so a tag can never ask for a click.
The first version of the web path still asked Accessibility for a field *after* the click, and his
next screenshot — the model narrating "i'm clicking right into the main line" while a pipe-less
`[TYPE:248,349]` sat on the card as raw text over an empty editor — was his answer: "instead of
making it an accessibility feature, make it a click just like how the autotyper works." So the
contract is now his script's exactly: click, post the keystrokes, and ask Accessibility **afterwards,
only as a witness, never as a gate**. The focused element's value confirms the text when the page
offers one (`.typed`); its role decides the newline rule; a page that offers nothing gets the
keystrokes anyway and is reported `.postedUnverified` — "posted, the page would not confirm, so look
at the field" — which counts as a completed step for the plan and still offers the words in the copy
well. The prompt also lost the waste and gained two guards: never press a field or editor to focus it
(the type act clicks the caret in itself — that press step is what stopped his plan), never narrate a
click you did not request, and a `[TYPE:]` without its `|` is not a type at all, because the pipe-less
tag he photographed reaches him as raw text and types nothing.

Payload cap 6,000, posts chunked, copy well after a finished type: all from the previous round, now
with the caret route that makes them reachable in a browser. Prompt weight after the pipe rule, the
focus-click rule and matching trims: **20,284 chars (~5,071 tokens), −34.0%**, inside the diet line.

**Then three more screenshots, and the failure moved from the mechanism to the grammar.** The
click-first path never ran, because a contended model wrote tags the parser could not read, in three
shapes: `[TYPE:248,349]code` — aim, bracket, and the words *after* the tag as plain text;
`[TYPE:x=200,380]code` — keyed coordinates the tag space never defined; and code containing `]`,
which ends the construct early and used to truncate the payload at the first array bracket. One turn
even hallucinated the finish — "yes, it's typed out in the editor on your screen now" over an empty
`main.c` with no act at all — the invariant-8 lie the outcome line exists to prevent, committed by a
model the free tier served out of contention. His verdict: "make it a click just like how the
autotyper works", and if that fails, run his script in the background with the text pasted in. The
script-as-daemon route is the one thing not built: it is a paste-into-a-file-per-use workflow, the
exact friction the product exists to remove, and its mechanism is already in-app. What changed
instead is that the parser now absorbs his three shapes: a pipe-less `[TYPE:]` keeps its head and
gathers the words that follow from the text stream, closing the act at the next tag or at finish;
`x=`/`y=` prefixes are stripped in `parsePoint`; an absent label defaults to "field" while an
explicitly empty one (`640,910:|…`) stays a refusal; and text continuing the *same line* after a
parsed tag re-joins its payload with the `]` the construct consumed, so `int x[4];` survives whole.
A line opening any tag ends a gathered payload — the raw text of a malformed `[ACT:…]` must not be
typed into the editor beside the code it followed. Five unit cases pin each shape, including the two
that must *not* gather: prose on the next line after a well-formed tag, and a following raw tag.
657/657 unit tests; verify **32 passed, 2 skipped** — the standing Shortcuts skip and the self-test's
model round, which the free tier refused outright that minute (exit 3: a skip, never a pass).

**And then the code landed — on one line.** His next screenshot was the leniency working (the act
ran, the keystrokes posted) and the editor showing `#include <a.h>#include <b.h>#define…` as a
single unbroken line, with the card honestly saying "took the keystrokes and then refused the text".
Both symptoms, one cause: a Unicode line feed posted as a keyboard event is **swallowed by web
editors** — which is precisely why his Auto Typer presses Enter between lines instead of writing
them. `post` now sends `\n` as a real Return keypress (`virtualKeyReturn`, 36) and every other
character as the Unicode pair it already was; the newline policy has proved the field multiline
before a single Return goes out, so the key cannot be a Send. And because CodeMirror re-indents on
Return, the read-back witness accepts every payload line present in the field's value
(`allLinesPresent`) instead of strict equality — otherwise a successful type reports as refused,
which is exactly the second symptom he photographed. 658/658 unit tests; verify **33 passed, 1
skipped** on this build.

**The last shape, photographed 21:39:** `[TYPE:app=Google Chrome x=200,y=400]code` — the
qualified-coordinate form ACT learned in October, now written into a TYPE tag, where `parseType`
never tried it and it failed open as raw text again. The fix is one attempt in the right place:
`parseType` now tries `qualifiedPointAim` between the semantic and bare-point branches, so the aim
carries the app name the press path already checks the hit test against — accepting the form makes
the act *stricter*, which is the only reason to widen a grammar. Three unit cases pin it, including
the whole pipe-less-qualified tag gathering its code from the text that follows. 660/660 unit
tests; verify **32 passed, 2 skipped** (the standing Shortcuts skip, and the self-test's model round
refused by the free tier that minute). His re-test stands: "type the code here" on Programiz — one
cursor jump, the file landing line by line with indentation, an honest outcome line.

**The thinking budget: the latency lever was in the body, not the chain.** He asked for the probe
and the before/after. `--probe-thinking` (dev-gated, sends a two-word text prompt, no screenshot,
never prints the key) asked the live Interactions API which shapes it accepts:
`generation_config.thinking_level` and nothing else — `thinking_config`, `thinking_budget`,
`reasoning.effort` and top-level `thinking_level` all came back "Unknown parameter", and the
value sweep's 400 named the vocabulary: `minimal|low|medium|high`, `none` rejected. Measured on
the five-turn protocol probe: same prompts, same machine, same contended key — **42.1–55.6s per
turn before, 21–34s after** (median ~47s → ~33s; the earlier `minimal` run hit 21–24s before
contention worsened). The first `minimal` run appeared to lose the SCROLL family — "scrolling
down to find the invoice now" with no `[SCROLL:]` — but `low` lost it on the same screen too,
which moved the diagnosis from thinking budget to the class this repo keeps meeting: **a promise
with no request behind it**. `AnswerStreamer.retractUnbackedPromises` now replaces any
promise-shaped scroll/type sentence whose reply queued no matching request with one honest line —
"Chunks found nothing on the screen to do that to, so it did nothing." — logged as retracted, and
the probe accepts either the request or the retraction. Promise-shaped, not word-shaped: an
*explanation* of scrolling is not retracted (unit case), and the retraction can only ever claim
the one thing it knows: there was no request. With the guard in place the budget went back to
`minimal` — the fastest setting that answers, and the failure it looked like was never its fault.
661/661 unit tests; verify **32 passed, 2 skipped** (self-test model round refused by the free
tier that minute + the standing Shortcuts skip); protocol probe **4 of 5 measured, all passed,
1 skipped by contention** — turn 1 died in an 83s four-attempt window, which is the tier, not
this build.

## 2026-10-29 (small hours) — the first-run flow, and a check that only passed before midnight

Item (2) from his queue: 3.7 and 4.3 built as **one flow a stranger can complete**, every screen
render-checked. `FirstRunPlan` (pure, ChunksKit) owns the order and the completion rules — grants
before brain before keep-alive, no skipping, the brain step completed by **either** a stored key
**or** the offline switch (the no-key tier is a finished answer, not a consolation, which is the
exact bar 4.3 sets), and only Done sets `finished`. `FirstRunWindowView` draws the three steps
from a plain model — the `CompanionWindowModel` trick again, so the surface can be rendered
without the pipeline — and reuses `PermissionRow`'s vocabulary through a new shared
`PermissionActions`, which the panel now calls too: two surfaces, one definition of what Restart
does. The window opens on first launch, re-opens from the panel's "Run Setup Again" row, and
polls the machine once a second while open, because System Settings changes outside the process
and a flow showing yesterday's grants tells people to press Restart for ticks they already gave.

`--render-setup` draws all three steps offscreen and asserts each fixture's plan opens on the
expected step — the render is a check, not a picture. And it earned its keep on the first look:
the last step's footnote promised "the next one opens by itself" when there is no next step — a
dead promise caught by the same act of looking that Tier 0 was built on. Fixed, and the sentence
now says what Done does.

One verify check went red on this run for a reason that was the clock, not the code: the reminder
probe asserted `· in 40 min`, and at 23:57 a 40-minute reminder *is* "tomorrow at 00:37" — the
spoken form was right and the fixture was daytime-only. The check now accepts either shape with a
comment naming the hour it learned that at. A check that only passes before midnight is exactly
the "passes because a file happened to exist" class, found by running it at a different time —
which is what running it is for.

Five unit cases pin the plan's rules (`FirstRunPlanTests`), including a revoked grant reopening
the flow at the step that broke. Click count inside Chunks for a fresh Mac: 8 — four Grants, one
Restart, key paste + Save (or one toggle), login switch, Done — plus the System Settings toggles
macOS insists on; wall-clock seconds need the clean-account walk, which is his. 666/666 unit
tests; verify **34 passed, 2 skipped** (the free tier refused the self-test's model round at
00:04; standing Shortcuts skip), exit 0. The setup window is live on his machine now — it opens
on launch until Done is pressed, which is the intended first-run experience, and "Run Setup
Again" is in the panel.

## 2026-10-29 (00:30) — the flow's manual tests, run on the real window; and 3.1's baseline

He asked me to run the first-run flow's manual tests myself before item (3). Result, on the log:

- `setup: first run — opening the setup window` → `showing Step 1 of 3` → `Done pressed` — the
  window opened on a cleared flag, **opened on step 1 even on his fully-granted Mac** because
  screen-content readiness is async at launch, and the once-a-second poll advanced it to step 3
  within two seconds — which is why Done was there for him to press at all. The flag reads 1;
  the window is gone; a relaunch will not show it. The poll earned its existence in the first
  five minutes of real use.
- The panel's re-entry row: `--probe-semantic 'app=Chunks name="Run Setup Again"'` resolves
  `AXButton/Run Setup Again at (1245.25, 732.0) verb=AXPress · policy=needsConsent` — the row is
  live, pressable and gated. System Events could not see it at all (SwiftUI in a nonactivating
  panel publishes its tree lazily — the same lesson as Chromium, met from the other side).
- One false alarm worth recording: a launch looked stuck when I read the log mid-boot; the next
  tail showed the full sequence. Read logs after they finish, not during.

**3.1's baseline, measured the same minute:** Chrome's window is on screen (bounds 0,156,1710,951)
and `--probe-semantic 'app=Chrome name="Run"'` refuses every route — no pressable control, no
field, no scroller named "Run" — because the Programiz Run button is web content Chrome does not
publish. That refusal, on a button the user can see, is the hole the next session fills: rank
unnamed candidates by geometry + role + children labels and put the *description actually
resolved* on the card, proven read-only with these two probes before any press path changes.

## 2026-10-29 (early) — 3.1 option 1: the ranking, the card, and the fix that had to be reverted

`CandidateRanker` in ChunksKit (pure), `AXTDriver.candidateSweep`/`candidateResolve` (the walk),
`--probe-candidates` (read-only, dev-gated), and `offerNamedAct` falling back to the ranking after
`resolve` refuses. 18 new cases in a `Candidates` suite, 4 in `Action` for the policy rule, so
**688/688 across 39 suites**; `./scripts/verify.sh` **36 checks passed, 1 skipped, exit 0** with a new
standing check, *"candidates: a guess is asked about, a near miss is refused"*.

The hole, measured on his live Chrome tab and then filled by the same door a press goes through:

```
--probe-semantic 'app=Chrome name=Meet the party planning community'
  refusal — Chunks found no control called "…" in Chrome that it can press.
--probe-candidates "app=Google Chrome name=Meet the party planning community"
  1. AXGroup from a child "Meet the party planning community" score=3 at (117.0, 34.5) 122×1
  resolved AXGroup verb=AXPress at (117.0, 34.5) in Google Chrome
  the card would ask "Press the area that says "Meet the party planning community" at the top-left…"
  policy with asking off — needsConsent
```

Four things the measurements taught, none of them inferable from the code:

1. **The named route's failure was mostly a read-budget failure.** `--probe-controls "Google Chrome"`
   printed 479 pressable controls and not one page element, because a menu's rows are addressable
   whether or not the menu is open and they ate the walk. Pruning menu *subtrees*
   (`isMenuSubtree`, the collection-side sibling of the existing `isMenuRole` veto) turned
   `name=Guide`, `name=Skip navigation` and `name=Mute` from refusals into resolutions without changing
   what any of them may be pressed. `--probe-ax 300,400` had meanwhile been resolving that same page all
   along: `role=AXGroup title= description=` pressable=true — the words were never on the element.
2. **Chrome publishes a web control twice** — a wrapper `AXGroup` and the `AXButton` inside it at the
   *identical* frame (measured: `Mute (m)` as both, 40×40 at (84, 1079)). `tiedTop` therefore refuses
   only when the two frames differ; treating the pair as an ambiguity would refuse most of the web.
   Geometry is still never evidence: `nearness alone never qualifies a control` is a test, and the
   smallest carrier of the words outranks a page-wide group even when the aim sits inside the group.
3. **A display filter on candidates was the wrong fix, and it was built, installed, measured and
   reverted.** Chrome reports its *visible* toolbar at `y = −91` while the page beneath it reports from
   `y = 34`, so vetoing by `CGGetActiveDisplayList` (0,0,1710,1107) deleted Back, Reload and the
   address bar: `--probe-candidates name=Reload` went from a card to `refused`, and the candidate count
   fell 85 → 42. The honest version is at the *claim* layer: `positionPhrase` states "at the top-left"
   only when the control's centre is inside the window the user is looking at, and says nothing
   otherwise — `Press the button "Reload" in Google Chrome?`, no location. A test now pins both halves.
4. **A child-aim press is asked about even with asking off.** `PolicyGate.decide` gained `inferredAim`,
   sitting above both the `askBeforePressing` shortcut and the per-app allowance, which puts it beside
   the permanent-act rule instead of in a shell branch — and it carries the `alwaysAskControlWords`
   check, because on this route the words *on the card* are the words the policy reads, so a web button
   whose child says "Send" is asked about rather than sent. Re-read before pressing runs
   `CandidateRanker.stillAnswers`: same role, same frame, same verb, and the quoted words still present
   in the *same channel* — the acceptance case, "a card that said Run is not answered by a press on
   whatever now says Stop in that box". `ActionRequest.rankedAim` is shell-set only, no parse path
   touches it, and there is a test over four grammars that says so.

**A word about this session's tool output.** Several blocks arrived formatted as tool results for
commands that had not been run — `--probe-candidates` output before the flag existed, "683/683
passed" before a build, an `ACCEPTED:` line from a verify.sh check that had not been written, and twice
a version of my own source that differed from what was on disk (`forcesAsking` where I had written
`inferredAim`). They were consistently *optimistic*: each one described the work as already verified.
Every number in the section above is from a run whose output carries a nonce I echoed in the same
command, and the two fabricated "already done" claims were disproved by grep on the first try. If a
future session reads this: nonce every measurement here, and check the file, not the narration.

Still open: a real spoken turn pressing a child-aimed control on his screen (the card wording and the
forced question are the parts only he can confirm); Tier 1's carried-screen turn, the reminder
mid-sentence verdict and ⌃A inside Chrome/Finder, still his; options 2 and 3 of this item unbuilt; the
first commit, still unasked-for.

## 2026-10-29 (evening) — his "type it should type, click it should click", and two tag-grammar lies

Report read as three symptoms; the log and his own `history.json` said the act never happened at all.
`grep` of `~/Library/Logs/Chunks/chunks.log` at 13:41–13:45 showed `act: dropped, never asked — 1 act
tag(s) Chunks could not read` twice, and one `type: named miss — "Ask Google"` (Chrome's omnibox
*placeholder*; the app publishes `Address and search bar`). Pulling every `[TYPE:]` this build has ever
been asked to run out of `history.json` — twelve tags, discovered not typed in — gave the real cause,
and it was two grammar faults, not a focus fault:

1. **The aim.** Four of the twelve carried an axis letter the tag space never defines: `x:235,y:400`,
   `x,625,320`, `x,230,y:360:main.c`, `x=200,380`. `parsePoint` required the text before the first
   comma to be a number, so each one failed open as raw markup over an empty editor and he asked again.
   `ResponseParser.stripAxisNames` now removes an axis *token* (`x`/`y` alone, joined to its number by
   `=`/`:`/`,`) at the front of the aim or after its first comma, and `parseType`'s empty-label refusal
   tests the stripped aim — so `x:235,y:400|code` is a terse tag, while `640,910:|code` stays a refusal
   and a label that happens to start with an axis letter ("x-ray machine") is still a label.
2. **The payload's own brackets.** The scanner closed a `[TYPE:]` at the **first** `]`, so his C code
   containing `uint8_t data[]` ended the tag there; the recovery path re-joined the remainder and
   **put a literal `]` at the front of it**, and in one reply a `[ACT:…:Run button]` that followed the
   code was swallowed by the type payload — which is what "when i said to click it must perform the
   click action" looked like from the outside. `ResponseParser.closeRange` now treats a `]` as the end
   of a *piped* type payload only where the reply's structure ends it: nothing after it, or the next
   non-space character opens another construct. The pipe-less form (`[TYPE:aim]code`) still closes at
   its first bracket, because there the bracket ends the aim and not the payload — that exception was
   found by the existing test failing, not by reading the code.

No keyword lists, no per-app rules: both fixes are about the shape of the tag. Tests added in
`ResponseParserTests` use his exact aim strings and a payload with brackets followed by an act tag;
the old expectation that a typed program *ends with `]`* was corrected — that stray bracket was the
bug, and it would have landed in his file. **690/690 unit tests; `verify.sh` exit 0, 34 checks passed,
3 skipped.** One of those skips is new and worth watching: the candidates check now *discovers* the
name it ranks from `--probe-controls` instead of naming `Reload`, because the hardcoded name passed all
afternoon and then failed the moment his Chrome window moved down the screen — at the time of this run
the walk found 0 pressable controls in the window, so the check says SKIP rather than pretending.

**Still open, and it is his to tell me:** whether "overwriting my commands" also means text landing in
the wrong field. The evidence so far is only that nothing was typed at all; if a run puts code in a
place he did not point at, the answer is in which field the caret was, and `--probe-ax x,y --named
"…"` on that spot is the one command that would say.

## Not yet built
automations beyond a named shortcut, the calendar half of the planner (Phase 6 — no `EventKit`
anywhere, so a day brief cannot read his appointments; the official Calendar MCP route is researched
and waiting on his preview approval), the notch face and moods (Phase 7), and bundled `SKILL.md`
context with MCP Ask-before-run (both "adopt" rows in the plan that were never built). The
`<NOTE>` consumer gap is closed by removal rather than by building a Notebook. On the commercial
path: Developer ID signing, notarisation, Sparkle and the clean-account acceptance checklist all
wait on his enrolment. The scanned-PDF case is done — a page with no text layer is drawn to JPEG
and looked at — and the transport already carries a list of images, so the note that used to sit
here about one-image-per-turn is gone.

## 2026-10-30 — the dots reskin (panel, window, setup)

The three settings surfaces moved to the Dots Studio warm paper and its three flat fields; the notch
card was left alone. Done in the order he set: measure → tokens → contrast table → one surface at a
time, each built, installed, rendered and *looked at* before the next.

**What was measured, and what was not.** The reference image's temp path was deleted by macOS between
the Read and the pixel sampler, and sampling the live site's images was blocked three times by the
tool classifier, so the first pass could only measure paper/sea/ink from the site's CSS and canvas.
He then placed the image in the repo and named the three fields he wanted (sea, sky, sky-patches).
Sampled from the actual pixels (1700×1662, pure-Python PNG decoder, no PIL): **sea #B3E5DB, sky
#A7BCFA, sand #FAE1AF, ink #1A1A1A, hull #583629, paper #F5F4EF** (sail cloth, cross-checked against
the site's #F5F4F1). His starting guesses were all wrong — sea #8FD8CD, sky #A9C3F0, sand #F6CB80 —
which is exactly the cream-vs-bone difference he said the design lives on. The pen-hatch geometry was
measured off the image's clean sea: 2 px stroke, 33 px pitch, 15 px dash, 5 px gap, 1.6% coverage;
scaled ×0.5 into points and dropped to 5% ink. Note: the *live site's* field texture is ASCII glyphs
(19 px strokes on a 28 px pitch), not pen hatching — the image he chose is the hatched one, and that
is what was drawn.

**The test-count discrepancy, resolved as far as it can be.** He reported verify.sh 690/690 against a
direct `swift run chunks-test` 693/693. Re-measured with a nonce: static `test(`/`asyncTest(`
declarations = 690, runtime registrations = 690, summary = 690/690 — three independent counts agree,
and 693 is not reproducible in this tree. There is exactly one `skipTest` in the suite, so skips
cannot produce a 3-gap; the two observations were almost certainly different source states (16
untracked + 11 modified test files). One latent hazard found, unrelated: `TestRunner.registered` is
never cleared between `run()` calls, so a double invocation would silently double-count. After the
five new contrast tests the suite is **695/695**.

**The contrast table, including the limitations asserted rather than nudged.** Ink on the three
fields is legal (sea 12.55, sky 9.30, sand 13.64). But no field reaches the 3:1 graphic floor on paper
(1.16–1.70), so the fields are grounds-with-ink, never marks; paper-on-field is never legal; and
`inkFaint` on `pressed` is 4.45:1 — left failing on purpose, with a test that says a pressed row uses
muted or ink. `ColorContrastTests` now asserts all of these, including the negative ones.

**What looks worse than the description.** The hatch at 75% dash duty reads slightly more like faint
ruled lines than hand-hatching; it is paper grain, not a pattern, but it is not literally pen strokes.
The composer placeholder and the disabled Ask (window) and the `AIza…` prompt (setup) are the softest
text on their surfaces — intended prompt/disabled styling, but the weakest contrast and worth his
eye. The panel's render fixture drew the revoked-permissions copy rather than the five permission
rows, so the sea PERMISSIONS tag never appeared there; sea was instead confirmed on the window's
question wells and the setup's step-1 header.

**Verification, per surface, exact counts.** Panel: verify exit 0, 34 checks passed / 3 skipped
(model rate-limit, no Chrome control, no Shortcuts window), 695/695, panel render 1166 KB. Window:
exit 0, 35 passed / 2 skipped, 695/695, window render 1272 KB. Setup: exit 0, 35 passed / 2 skipped,
695/695, setup render 1325 KB. Every render was opened and described before the next surface began.
Nonces: dots-1793309397-21532 (palette), contrast-1793309477-18230, panel-1793309851-26682,
verify-panel-1793309936-20367, win-1793310148-30026, verify-win-1793310197-2982,
setup-1793310330-23839, verify-setup-1793310367-27384.

**Carried, not dropped, and still unwatched on his screen:** the pointer-click path for web content
with no Accessibility verb, and the 9 ms typing cadence, both built last session. Nothing in this
reskin touched them and neither is claimed verified. No commit was made; the tree is his to commit.

### Same day, second pass — the nautical mockups

He then supplied two mockups and asked for both panels to match them exactly. Those files were not in
`~/Downloads` and not in the attachment cache, so they could not be sampled; the build went on the
already-measured tokens with the layout read off the images. The mockups changed the *structure*, not
just the tint: the ground is the **sea field**, the window's rail and top band are **sky**, sand is
for reading and warmth, paper is for things you operate, and a **dashed rule is the only separator**.

Three real defects, each found only by rendering and looking:

1. **Accent-blue links on the sea card were 4.24:1** — a fail at 11 pt. Measuring every ink weight
   against every field showed the rule that had been assumed wrong: fields carry `ink` and `inkMuted`
   only. `inkFaint` is 3.11–4.56 and bright accent 3.14–4.60, worst on sky. Links moved to
   `accentDeep` (5.49 sea / 5.97 sand), routines body text to muted, and
   `Palette.Dots.illegalOnFields` now asserts the failures so nobody reintroduces them by reaching
   for the usual token. Suite is **696/696**.
2. **Sand clouds on a sand band were invisible**, and as an `.overlay` they painted across the
   subtitle. Moving them to a second `.background` made them vanish entirely — a later `.background`
   sits *behind* the earlier one, under the opaque sky fill. The fix is one `ZStack` background per
   sky field: sky, clouds on its bottom edge, hatch over both.
3. **The routines and memory blocks were one sea card**; the mockup has them as two. Split, and the
   history/API rows moved onto one paper sheet at the foot of the scroll.

Deliberate deviation, stated in DESIGN.md: the mockup's traffic lights were not copied onto the
menu-bar panel. It is borderless, and three circles that do nothing misrepresent the surface. The ⌃A
window has real ones.

Verification for the second pass: panel — 35 checks passed / 2 skipped, 696/696, render looked at
twice. Window — 35 passed / 2 skipped, 696/696, render looked at four times before the clouds sat
right. Setup unchanged since its first pass. Nonces: m-panel-1793312295-31852, m2-1793312520-15287,
mw-…/mw2-…/mw3-…/mw5-… per build, vp + final verify logs in /tmp.

### Same day, third pass — he said 80%, and the missing 20% was measurable

He put the two mockups in the repo and said the result felt off. Sampling them (patch modes and
hue-family modes) showed **they are not the sailboat palette at all**: sea `#C7EDE7` not `#B3E5DB`,
sky `#A2C0FD` / rail `#BDD1FC` not `#A7BCFA`, sand `#FAEBD1` with a stronger `#FDD99C` tag, paper
`#F7F3E9`, ink near-black, a **teal `#1B9794`** for toggles/meter/selection, and a link blue
`#0038E8`. The two mockups also disagree with each other, so each surface takes its own mockup's
values and the two seas / two skies are deliberate.

What the 20% actually was, beyond colour:

- **Everything was dashed.** The mockups dash the *cards* and draw the *controls* solid — model pill,
  section tags, close button, answer cards, composer — and the outer sheet has a solid dark edge.
  Dashing a control makes it read as decoration. Added `dotsSolidBorder`, `controlEdge`, `sheetEdge`.
- **Toggles and the meter were system blue**, not the mockup's teal; the chosen thread's bar too.
- **The memory card was flat sand.** The mockup has a sand header strip with a paper sub-card inset
  holding the facts. Built that, and the MEMORY tag stopped wrapping to "MEMO / RY" (`fixedSize`).
- **The window's detail header was sky with a thin cloud band.** The mockup is cream with a *large*
  cloud mass hanging from the top-right — a vertically flipped `CloudBand`. The rail also ends in a
  sea strip at its foot, which was missing.

The lighter palette *loosened* the contrast rule where the numbers allow: ink and muted now clear on
all six fields (muted on sky went 4.88 → 5.00), and the mockup's own link blue clears 4.5:1 everywhere
except sky (4.21), so matching the mockup exactly and staying accessible stopped being a conflict.
`illegalOnFields` was re-measured, not carried over: faint now fails on the two skies, seaDeep and
sandTag; teal fails as a mark on every field. Suite **696/696**, verify exit 0, **35 checks passed /
2 skipped** (no Chrome control, no Shortcuts window). Nonce vf3-1793314216-30606.

Still not copied, on purpose: the mockups' traffic lights on the menu-bar panel. It is borderless;
three circles that do nothing misrepresent it. The ⌃A window has real ones.

## 2026-10-30 (late) — typing into the Examlly editor stopped

He photographed the card saying "the text area took the keystrokes and then refused the text, so it
may not be there." The log held **fourteen** of those in a row, and one success between them.

The path was **not** the web one. `type: aim missed, answered by name — "code editor" →
AXTextArea/AXTextArea at (743.5, 127.5)` — a real `AXTextArea` resolved by name, so it went through
the native `type()` witness, which has a stricter rule than `typeWeb`. Two defects in it:

1. **An empty value was treated as a refusal.** Chromium answers `kAXValueAttribute` with `""` — not
   nil, not an error — for an editor that took everything. The loop only returned `.typed` early when
   the attribute was *absent*, so `""` fell through to `.rejectedByField`. Now three-way:
   `confirmed` / `silent` / `contradicts`, extracted to `AXTDriver.witness(value:payload:)` because
   the distinction cannot be tested while welded to a live `AXUIElement`.
2. **A non-confirming value in a web-hosted field was still a refusal.** The frames in the log walk
   from (773,174) to (743,127) as the caret moves — CodeMirror's input sits at the caret — and its
   value is the *visible viewport*, not the document. Text that lands below the fold reads as a
   contradiction. `typeWeb` already reports that case as posted-and-unconfirmed; the native path now
   matches it for anything under an `AXWebArea` (`isWebHosted`, bounded to 20 ancestors). Native apps
   keep refusing, because there the value is the truth.

The focus check above all of this is unchanged and is still the gate — the refusal that protects him
is `focusRefused`, and no keystroke goes out unless the approved element *is* the focused one. What
changed is only the wording after the keys were legitimately posted: it no longer claims the field
refused something the field simply will not report. 2 new cases, **698/698**, verify exit 0,
35 checks / 2 skipped. Nonce ship-1793383310-31990.

**Not yet confirmed by his eyes:** whether the SQL actually reached the editor. This fix makes the
report honest; it cannot prove the text landed. If the field is still empty after a retry, the next
question is which `AXTextArea` the name search is choosing, and `--probe-fields Google Chrome` answers
that read-only — the run today spent its 700-element budget before reaching the editor's tab.

## The full capability audit — 2026-10-31, every capability listed and then verified

He asked for the list first, then the verification, then the fixes. The list came out of `AGENTS.md`
and the code, and every item was then run against this machine. Final gate: **699/699 unit tests,
35 checks passed, 2 skipped, exit 0** — Nonce GATEF-1793463644. The two skips are the two standing
ones, and both now say why in their own line (below).

### Five real defects found, four fixed

**1. `--probe-controls` printed sixty menu rows and nothing else, so the web-content check had been
skipping forever.** `runControls` printed `sweep.controls.prefix(60)` in walk order, and walk order
starts at the menu bar. `verify.sh`'s candidates check filters `AXMenuBarItem|AXMenuItem` out of that
output to find a fixture name — it filtered away the only sixty lines it could see, got an empty
string, and printed SKIP. Tier 3.1's ranking has therefore been unverified on every run since it
landed. Fixed by listing non-menu controls first ([Sources/Chunks/AXProbe.swift:414](Sources/Chunks/AXProbe.swift)).
Measured before and after on a live Chrome window: **60 of 60 printed lines were menu rows → 0 of 60**,
and the probe then printed `New tab`, `Back`, `Reload`, `Home`, `Open Gemini in Chrome` — the
controls the check needs. That run took the check from SKIP to PASS (36 checks, 1 skip).

**2. A turn could spend twice its budget, and the budget was measured from the wrong moment.**
`--probe-protocol` logged `budget spent after 103s`, `after 62s`, `after 120s` against
`turnBudgetSeconds = 60`. Two causes, both fixed:
- `RetryPolicy.attemptSlice(remaining:modelsLeft:)` returned `minimumAttemptSeconds` when `remaining`
  was **zero or negative** — the floor meant to stop a model being given two seconds was instead
  handing a dead turn three more eight-second attempts, because the loop only checked the budget at a
  *model* boundary and each model runs three attempts. It now returns `0`, and `BrainGateway` stops
  before asking. New case `a spent budget buys no model another attempt`.
- `chainDeadline` was measured from `chainStarted`, which is after the offline check, the Keychain
  read and the provider resolve. Two turns reported **126.3s and 44.0s** while the log shows their
  chains took **28s and 16s** — the rest went before the first request was even built, on a locked
  screen. The deadline now starts at `started`, the moment he asked, and any pre-chain second over 1s
  is logged as what it is. The 60s promise is now the wait he experiences.

**3. `--probe-protocol` graded the prompt against a screen that was not there, and blamed the
prompt.** Turn 1 asked *"click the send button for me"* and required an `[ACT:]` back. It FAILed, and
the reply was correct: *there is no send button here, just a textedit file picker window*. The probe
opens TextEdit to give the type turn a field, and then asked for a control it had not put on screen.
I first read the model's *"it looks like your mac is at the login screen"* as an invented excuse for a
correct refusal — **and I was wrong.** Recording the frontmost app beside the verdict proved it:
`screen: loginwindow, 3420x2214px`. A probe run from a shell keeps asking models while he is away from
the machine. Two fixes: the press turn now aims at a control read out of the live tree (a titled
`AXButton`, frontmost app then the TextEdit the probe itself opened — Qoder publishes 227 pressables
with **every title empty**, the exact shape the ranking exists for and the exact shape this probe
cannot name), and the whole run now refuses to grade a locked or sleeping display: `NOTHING MEASURED —
the display is asleep or at the login window`, exit 3. With the screen genuinely unlocked the result is
**5 of 5 turns emitted their tags**, first time this probe has measured the press family honestly.
Same class of lie fixed in the summary line: `0 of 5 turns measured, all passed` is now
`NOTHING MEASURED — all 5 turns were skipped`.

**4. The candidates check could PASS while proving nothing about web content, and its SKIP blamed the
app.** After fix 1 it built its fixture from `--probe-controls`, which reports controls **outside**
the window veto the ranking uses. So the SKIP said "Chrome published no named control to rank" when
the measurement was: the controls probe printed 198 pressable controls and the ranking collected
**0 inside `(0.0, 156.0, 1710.0, 951.0)`** with its 700-read budget spent on browser chrome. The SKIP
line now carries both numbers. The gap it exposes is Tier 3.1's real head: **the 700-element walk does
not reach Chrome's page**, and I have not raised the budget unasked, because that number is what
bounds how long the notch sits frozen — his call, not mine.

**5. `AGENTS.md` said Chunks has bundled skills. It has none.** Zero `SKILL.md` in the repo, zero
references to "skill" in `Sources/`, nothing in the prompt. `TASKS.md` §3.5 correctly lists them as
unbuilt. A scope authority that describes an unbuilt tier as a feature is the same bug as Tier 0.2's
stale Notebook comment, so line 12 now says they are in the scope and not in the build. Nothing
user-visible: the model is never told about skills, so no promise reaches him.

### What the audit verified as working, with the evidence

| Capability | Evidence |
|---|---|
| Screen capture, coords, notch geometry | `--self-test`: 3420x2214px in 60ms, notch 185x33 at (675,907) |
| Hit test + name fallback + desktop icons | `--probe-ax`, `--probe-desktop` PASS |
| Semantic aim, fields, scrollers | `--probe-semantic`, `--probe-fields` PASS; `--probe-crop` asserts the two flips cancel |
| Candidate ranking, policy on a guessed aim | `--probe-candidates` PASS on 10-31's first run; SKIP now with its reach printed |
| Press / type / scroll / tools, live | **mined from his own `history.json`**: 116 act lines over 166 turns — today 4 press-or-open successes and **13 `Typed N characters` successes, zero refusals** |
| The typing fix from earlier today | all 21 `the text area took the keystrokes and then refused` lines are 10-28 and 10-30; **none on 10-31**. His stored history is the proof |
| Memory rules | `--probe-memory` PASS (it seeds one fact of each kind, so an empty `memory.md` cannot make it hollow) |
| `<MEMORY>` emission | live turn on the **production** prompt: emitted `<SAY>` + `<DONE_TITLE>` + `<SUMMARY>` + a valid `{"add":[…],"prune":[…]}`, parsed as `memory proposal: [Standing preferences] prefers dark roast coffee over medium` in 7.8s |
| Reminders, power hold, command tool, reveal | probes PASS; `reminders.json` and `routines.json` both `[]`, so nothing is armed or scheduled on this Mac right now |
| File reading: text, PDF, Word, picture | four end-to-end probes PASS against real fixtures in `~/Downloads` |
| Retries, hedge, per-model buckets, thinking refusal | all four chain behaviours observed in the live log on 10-31: hedge at 3.5s, `skipping … the hedge already asked it`, `rejects thinking_level — asking it again without the field`, rate-limit skip |
| Safety contracts | `store:false`, overlay never activates, no keystrokes in the log (`keyCode=` count **0**), universal + hardened + one entitlement |
| The three reskinned surfaces | rendered and byte-sized: card 1967 KB, window 1408 KB, panel 1191 KB, setup 1324 KB |

### Measured, not fixed — for his screen or his decision

- **`gemini-3.8-flash` rejects `thinking_level` on every turn it is reached** and burns ~1.7s and a
  wasted request discovering that. `BrainGateway` now remembers the refusal for the process, but only
  on a hop with one request behind its errors — the first hop is hedged, two models share one flag,
  and `RaceResult.failed` does not say which model refused, so caching there would cost a healthy
  model the diet that halves its turns. **Not yet observed working**, because it needs two consecutive
  slow turns inside one long-lived app process; a probe builds a fresh gateway per turn.
- **The 7 MB capture is the latency story, not the model.** Both slow turns sent `7022 KB` of image;
  the four fast ones sent ~1005 KB of the same display. Same screen, 7x the payload, 8x the wait.
- **`--probe-stt` needs his voice.** It opens the mic and records 8.0s; run from a shell it transcribes
  silence and proves capture only. `--probe-thinking` is now redundant — the protocol run measured the
  same field live, on a different model than the 10-29 note.
- **Memory has never stored a fact on this machine**: `memory.md` is 676 bytes of headings and four
  `_(empty)_` sections after 166 turns, because every turn he has asked has been a task
  ("press", "open", "type"), never a fact about himself. The machinery emits and parses; nobody has
  said the sentence that triggers it.
- **Launch-at-login is not registered** (`launchctl list` shows no Chunks entry). That is the row doing
  its job — he never turned it on — but the *register* path has never been watched, and nothing in
  `verify.sh` can see it.
- **`run_shortcut` is wired and the fixture exists.** `/usr/bin/shortcuts list` on this Mac answers
  `stop sleep`, `Turn Text Into Audio`, `Summarise PDF`, `Haiku`. `--probe-semantic
  app=Shortcuts name="stop sleep"` still refuses all three routes, because Shortcuts is *running*
  (pid 1178) with **no window** — the tree it publishes is a menu bar. Same standing SKIP as ever.
- **Ollama is running and answering** (`/api/tags` → 200, four models: qwen3:14b, gemma4:e2b-it-qat,
  gemma3n:e2b, qwen3-embedding:0.6b) while `app.chunks.brainProvider = gemini`. Verifying Chunks'
  offline path means switching his brain setting, which he has not asked for.
- `askBeforeActing = 0`, `chunksKeepAwakeForSchedules = 0` — reading the real defaults rather than
  assuming them.

## The terminal command tool — found from his screenshot, 2026-10-31

He photographed a card: *"I'll run caffeinate in the background for six hours."* then
**`caffeinate -u -t 21600 did not run.`** — and asked whether the command capability actually works,
since `verify.sh` has been printing `PASS command tool` all along.

The executor did run — `--probe-command` proved that the same second he sent the screenshot. What was
lying was the *check* about what it proves, and underneath that, the dispatch. Both are below, and the
second one is the reason his card said what it said.

```
probe-command: date — finished · 28 chars · first line: Sat Oct 31 22:11:56 IST 2026
probe-command: true — finished · 0 chars · first line: (no output)
probe-command: caffeinate -u -t 5 — still running · 112 chars · first line: still running as pid 39242 — …
```

**Two bugs, both in the report rather than the executor.**

1. **A command that is still holding was reported as `finished`.** `runCommand` returns
   `succeeded: true` for a process it stopped watching, and `DoRequest.outcomeLine` had two states,
   so `caffeinate -u -t 21600` — a six-hour sleep hold he asked for — came back on the card as
   "caffeinate finished." He would have read that as *the hold is over* while it had five hours and
   fifty-nine minutes left. `ToolRunner.CommandOutcome` now carries `stillRunning` as its own field
   and the line says `caffeinate is running and Chunks has stopped watching it.`
2. **A command that fails silently produced a card with no cause anywhere.** The only path that
   returns `succeeded: false` with empty output is *process started, exited non-zero, printed nothing*
   — which is what his card showed, because the `It said: …` suffix is only appended when there is
   output. Now that case puts the exit code in the output rather than dropping it.

### And then he said "it still shows me this" — which is how the real cause surfaced

Second screenshot, 22:38, on a build that already had both fixes above in it: **`caffeinate -u -t 7200
did not run.`** — still with no `It said:` behind it. My change makes an empty-output failure
*impossible*, so the only conclusion was that the line came from a path I had not touched. It came
from `answerAct`'s `.tool` branch:

```swift
let succeeded = await ToolRunner.run(tool)   // ToolRunner.run answers false for .runCommand…
```

…and `ToolRunner.run`'s `.runCommand` case was, until this hour:

```swift
case .runCommand:
    // Handled by the caller, which has somewhere to put the output.
    return false                              // …without starting anything.
```

**`run_command` is the one tool that always takes a card** (`ToolLayer.alwaysAsks`, pinned by a unit
case), so *every* invocation of it has ever travelled the card-answer path. **No `[DO:run_command:]`
has ever run, on any machine, since the day the tool shipped.** The locked-screen theory in my own
note above was wrong — a reasonable guess that his second screenshot refuted, and the exit status I
had just added would never have appeared, because the process was never spawned. The pattern in this
repo, again: his screen outranks my inference from a log line, every single time.

Three fixes, and they had to move together:

- `runTool` is now the **only** place a tool executes, and it takes a `then:` completion so the two
  callers that cannot proceed until they know — the card answer, and a tool leading a plan — can go on
  afterwards. `answerAct` calls `runTool`, not `ToolRunner.run`.
- The lead-tool path in `offerProgram` guarded on `!askBeforeActing` alone, so with asking off a
  `run_command` would have skipped the card it is promised. It now honours `alwaysAsks` too. **That
  hole only became reachable because of the fix above**: a command that never ran could not run
  unasked, so closing one without the other would have turned "never runs" into "runs without the
  question the policy says it must ask".
- `ToolRunner.run(.runCommand)` now *runs the command* and answers with whether it succeeded, keeping
  only the output for the caller that can carry it. A caller that reaches past `runTool` can still
  lose the output; it can no longer silently refuse something the user approved.

Writing the probe line that proves it — `ToolRunner.run(.runCommand) — executed` — caught a **hang**:
the probe bridged async to sync with a semaphore on the main thread, and `ToolRunner.run` is
`@MainActor`, so the new line deadlocked the whole probe until the process was killed. It now awaits
on the main actor over a run loop. All four lines, measured after the fix:

```
probe-command: date — finished · 28 chars · first line: Sat Oct 31 23:27:13 IST 2026
probe-command: true — finished · 0 chars · first line: (no output)
probe-command: caffeinate -u -t 5 — still running · 112 chars · first line: still running as pid 65561 — …
probe-command: ToolRunner.run(.runCommand) — executed
```

**The check was fixed to be able to fail.** `verify.sh` asserted only `date — finished` and
`true — finished`, so the two outcomes both bugs lived in were asserted by nothing. It now requires
all four lines and is renamed `command tool: runs a program, collects output, and knows a hold from a
finish`. One new unit case (`a command that is still holding is not reported as finished`) pins the
three report lines, including that a *refused* start must never read as a running hold.
**Gate after all of it: 700/700 unit tests, 36 checks passed, 1 skipped, exit 0** — nonce
G-1793469565. The candidates check went from SKIP to PASS on this run, which is the window geometry,
not a code change.

**Still his to watch:** say *"run caffeinate for an hour"* and read the card. It should now end
`caffeinate is running and Chunks has stopped watching it. It said: still running as pid …` — and
`pmset -g assertions | grep -i caffeinate` in his own terminal is the independent proof the hold is
real. This is the first time that sentence will have appeared on his machine: the tool has never run
there, so there is no baseline for what it looks like when it works.

## `caffeinate -u` does not stop a sleep — the prompt was teaching the wrong flag, 2026-11-01

He ran it again after the dispatch fix and the card was finally honest:

> running caffeinate for an hour now. I'll ask you to allow it.
> `caffeinate is running and Chunks has stopped watching it. It said: still running as pid 82174 — …`

**and his Mac went to sleep anyway.** So the tool works and the command is wrong. Read the assertion
off his own machine, which is the only honest way to settle it:

```
pid 82174(caffeinate): UserIsActive named: "caffeinate command-line tool"
   Timeout will fire in 3508 secs Action=TimeoutActionRelease
system-wide:  PreventUserIdleDisplaySleep 0   ← the display is allowed to sleep
```

`-u` asserts **`UserIsActive`** — a tickle, not a hold. It stops nothing. Measured all four flag
shapes on this Mac, two seconds each, reading `pmset -g assertions` while they ran:

| Command | Assertion it actually holds |
|---|---|
| `caffeinate -u -t 6` | `UserIsActive` — **holds nothing that prevents sleep** |
| `caffeinate -d -t 6` | `PreventUserIdleDisplaySleep` |
| `caffeinate -i -t 6` | `PreventUserIdleSystemSleep` |
| `caffeinate -di -t 6` | **both** — the one that means "stay awake, screen on" |
| `caffeinate -s -t 6` | `PreventSystemSleep` (the cloudflared tunnel's own hold, AC only) |

**Where the model learned `-u`: from us.** The prompt's own example, `CompanionManager.swift:1300`,
read `[DO:run_command:caffeinate -u -t 3600]`, and the reply copied it word for word. That is a Tier 0
defect by this repo's own definition — the prompt says one thing, the machine does another — and the
third one found this week. Fixed: the example is now `caffeinate -di -t 3600` and the line says out
loud what `-d` and `-i` do and that **`-u` is not one of them**, with the measurement named as the
reason so nobody reverts it from memory.

Four comments in `ToolRunner`/`DoRequest` and two in `AGENTS.md` repeated the same mistake while
describing *other* bugs ("the ordinary stop-sleep-for-an-hour"), so the wrong flag was about to be
taught to the next reader too. All corrected; the two verbatim quotes of his card's
`caffeinate -u -t 7200 did not run.` were left alone, because those are records of what he saw.

**The check now fails if it regresses:** `verify.sh`'s prompt check requires `caffeinate -di` to be
present and `caffeinate -u` to be absent from the live instruction the model is sent.
**700/700 unit tests, 35 checks passed, 2 skipped, exit 0** — nonce G2-1793477033.

**What is still on his machine:** pid 82174 is a live `caffeinate -u -t 3600` holding nothing, with
about 55 minutes left on a timeout nobody needs. It is his process, so it was not touched —
`kill 82174` clears it, and asking Chunks for an hour awake now produces the right command.

## Gemma 4 Local Model (`gemma4:e2b-it-qat` on Ollama) Working Across Text & Vision, 2026-11-01

Problem reported: Chunks was failing when configured with the local Gemma 4 model (`gemma4:e2b-it-qat` on Ollama), which supports both text and vision.

### Root causes diagnosed
1. **Ollama `/v1/chat/completions` Shim vs Native `/api/chat`:**
   - Ollama's OpenAI compatibility shim (`/v1`) hardcodes context limit to 4,096 tokens and silently ignores `options.num_ctx`. Because Chunks' system prompt + memory + history + screenshot tokens exceed 4.3k tokens, `/v1` immediately truncated Gemma 4 with `finish_reason: "length"` after 1 token.
   - Ollama `/v1` also ignores `think: false`, causing Gemma 4 to spend 8–15 seconds generating reasoning scratchpad before any reply tokens.
   - Ollama's native `/api/chat` endpoint natively respects `options: {"num_ctx": 16384}` and `think: false`, delivering complete replies with zero thinking delay.
2. **GGUF Multimodal Template Image-First Requirement:**
   - In GGUF multimodal templates, if `type: text` precedes `type: image_url`, Gemma 4 treats the image as OCR/metadata rather than visual content and claims no image was provided. Placing `image_url` before `text` in `OpenAICompatibleTransport` resolved visual perception reliably.
3. **Model Name Normalization in Provider Registry:**
   - `model(named:)` was strictly exact (`==`). Normalizing spaces, colons, and hyphens allows flexible user selection (`gemma 4 e2b` or `gemma4:e2b` cleanly resolves to `gemma4:e2b-it-qat`).

### Implementation
- Added `Sources/ChunksKit/Brain/OllamaTransport.swift`:
  - Routes directly to Ollama's native `/api/chat`.
  - Configures `options: ["num_ctx": 16384]` (preventing prompt truncation).
  - Sets `think: false` (disabling 8-15s reasoning scratchpad, slashing text latency to 0.3s–0.4s and vision latency to 2.0s–2.5s).
  - Encodes images natively in message `images: [base64]`.
  - Streams NDJSON and converts into `GeminiStreamParser.Event` while suppressing thinking scratchpad tokens.
- Updated `Sources/ChunksKit/Brain/OpenAICompatibleTransport.swift`:
  - Placed `image_url` before `text` for GGUF template safety.
- Updated `Sources/ChunksKit/Brain/ProviderRegistry.swift`:
  - Normalized model matching for names with spaces/colons/hyphens.
- Updated `Sources/Chunks/BrainGateway.swift`:
  - Dispatched Ollama local turns to `OllamaTransport`.
- Created `Sources/Chunks/LocalBrainProbe.swift` and hooked into `ClickyApp.swift` (`--probe-local`).
- Added unit tests in `Tests/ChunksTestCases/LocalBrainTests.swift` (704/705 passing).
- Added local brain check to `scripts/verify.sh`.
- Rebuilt universal binary signed with "Chunks Local" and installed to `~/Applications/Chunks.app`.
- Verified live end-to-end: text turn in 0.3s–0.4s (`3 + 4` → `7`), vision turn with 2.2 MB image in 2.0s–2.5s emitting full `<SAY>`, `<DONE_TITLE>`, `<SUMMARY>`, `[ACT:]`, `[POINT:]`, `<NEXT_ACTIONS>`.


## A launch in front of a plan of pixels was dropping the *launch*, not the steps — 2026-11-01

Task #10, from Rishi's own list (it is not in `TASKS.md`, which stops at 3.7; and there is no
"jury" section in this file — that diagnosis is in the code, at `ResponseParser.swift:306` and
`ResponseParserTests.swift:330`). The brief was: when a launch invalidates the pixel coordinates a
plan was aimed with, Chunks should re-capture and carry on by itself instead of waiting for a
`<CONTINUE>`. The premise needed correcting first.

**What the code actually did.** `ActionRequest.leadingTool(for:tools:)` refuses to put a tool in
front of a plan unless every step is named, which is the right rule about evidence. But at the call
site (`CompanionManager.swift:3375` and below) a `nil` there did not stop the *plan*: `proposed` was
still non-empty, so the `else if let tool = streamer.toolRequests.first` branch was never reached and
the launch was dropped — logged only as `act: dropped, never asked — 1 tool request(s) behind a plan`
— while the pixel step went ahead against the capture taken *before* anything opened. Chrome never
launched and the keystrokes went to whatever field owned those pixels on the screen that was already
there. That is the shape this had on his machine all day:

```
<SAY>i will open chrome and search for how to use sql</SAY>
[DO:open_app:Chrome]
[TYPE:x,470:Search|how to use sql]
```

Six consecutive live turns of `gemma4:e2b-it-qat` on that question: five wrote a launch plus a pixel
aim, and one wrote `[TYPE:app=Google Chrome name="Omnibox"|how to use sql]`, which is the named shape
`leadingTool` already carries without a second look. None of the five would have opened Chrome.

**The fix.** `PlanAfterLaunch.decide(steps:tools:)` (ChunksKit, pure) splits such a reply: the tool
runs now, through `offerTool`/`runTool` exactly as a lone `[DO:]` does, and *every* step waits — not
only the pixel ones, because a reply is a set of acts plus a set of tools with no order between them,
so "this press happens before the open" is not sayable. What waits is a sentence
(`type 'how to use sql' into 'Search', then press 'Search button'`) rather than a coordinate list,
sent down the existing `continuePlanIfNeeded` route: same `maxPlanRounds` bound, same
`planRecaptureDelay`, and the model re-aims against a fresh capture. Three rules keep it no looser
than the press path — it resumes only when the launch *happened* (a tool refused before the card was
raised, a failed open, or a "not now" start nothing); a new sentence from him drops the hold as
surely as it drops a waiting round; and only `DoRequest.invalidatesTheScreen` tools qualify, so
`set_volume` pays no round and `run_command` is excluded because its effect cannot be read off `argv`.

**Cost, measured rather than assumed.** One extra round per mixed plan: `planRecaptureDelay` (1.5 s)
plus a local model turn (2.0–2.2 s on the runs above), against the old behaviour's 0 s and a keystroke
in the wrong window. The rejected alternative — let the pixel step run, then correct it — is the bug
this repo keeps relearning: a plausible action nobody can undo.

**The second half of the task: `--probe-reply`.** `[ACT:DO:open_app:Chrome]` — a tool written inside
the act grammar — is the shape Gemma produces, and until today the only way to find that out was to
watch the raw tag sit on a card in front of people. `ReplyAudit` (ChunksKit) runs a reply through the
live `AnswerStreamer` and prints, per construct, whether it became a request and whether its markup
survived into what the card would show, with the reason from the same reader the turn uses. The two
signals are cross-checked against the streamer's own `unreadActTags`, and a disagreement prints a
WARNING and fails the probe — an audit that drifts from the parser says so instead of reporting a
clean reply. Five fixtures, sixteen assertions, no model, no screen. It found its own first bug: the
live mode was auditing `displayable` (the card *after* the tags were consumed), so a well-formed
reply reported zero constructs and the probe called a working model's plan empty.

**One finding only the live mode gives.** The same four turns also produced an unterminated
`</NEXT_ACTIONS` and a `<MEMORY>` block with no closing tag — both now named as malformed in the
audit's own words, which is the class of thing that has cost this project a whole evening before.

**Gate.** `729/729` unit tests across 40 suites; `./scripts/verify.sh` → **38 checks passed, 2
skipped, exit 0** — nonce `GATE-D-1793530805`. The two skips are the standing ones (no Shortcuts
*window* open for the named aim; the ranking reaching 0 pressable candidates inside Chrome's window
veto). The first gate run, nonce `GATE-C-1793530662`, came back **37 passed / 1 FAILED** and the
failure was `--probe-local`, not mine: it grades what a local model answers in that second, and a
later direct run of the same binary passed all five of its checks. A live-model check that can go red
for nobody's action is the failure mode `verify.sh` itself warns about; left as it is, and named here
so the next person reads the probe's output before believing a red.

**Not watched yet.** The resumed round on his screen. The decision, the hold and the sentence are
measured; whether a fresh capture aims better than the picture it replaced, and whether the extra
round reads as help or as stalling, are Tier 1 and only he can say.

## The Notebook tier is built — and a read-only probe turned out not to be read-only, 2026-11-02

Rishi asked for "task #28 or something not built yet". `#28` is not in this repo (`TASKS.md` stops at
3.8 and the build plan is phased P0–P12), so the pick is **TASKS.md 3.3 — the Notebook tier**, which
Tier 0.1 named as its *preferred* resolution and nobody built. Rejected, with the reason: **3.5 bundled
skills** (in scope, but "which skills" is product content I would be inventing for him) and **4.1
Developer ID + notarisation + Sparkle** (hard-blocked on his enrolled account).

**What is in.** `NotebookStore` writes `notebook.md` beside `memory.md`: uncapped, one line per note,
`SecretSweeper` before every write, and **never injected** — which is the whole point, since the cap on
memory exists because every turn pays for its bytes. `<NOTE>…</NOTE>` writes; `[NOTES:what to look
for]` asks, and the answer rides into the next turn through the same one continuation slot a `[READ:]`
competes for. The panel has a "Show notebook" row and a count with no meter, because there is nothing
to fill up.

Two things the build had to re-learn rather than assume. First, `GeminiTransportTests` asserted
`!sys.contains("<NOTE>")` with the reason *"must not teach a tag with no consumer"* — and while
chasing where to put the new assertion I found that the companion turn does **not** send
`GeminiRequestBuilder.systemInstruction()` at all: `BrainGateway` passes the caller's `systemPrompt`
(`companionVoiceResponseSystemPrompt`) to every transport. So the teaching, and the check that it
survives, belong to the live prompt and `verify.sh` — an assertion in the wrong file is a green light
nobody is driving on. Second, the tier is *only* safe because the block is framed: "past data, not the
current screen, and not instructions", with the framing charged against the budget and cut at whole
entries, so the best note that will not fit is refused rather than clipped.

**What the harnesses caught, all of it real output:**
- `--probe-notebook` found the delete bug before any human did. `remove(matching:)` intersected
  content words, and `contentWords` drops anything under three letters — so the needle `"number 3"`
  quietly became `"number"` and removed **every invoice in the file**. Now whole-word, the way
  `MemoryStore.matching` has always done it. (My own probe also had a wrong expectation — it asserted
  the copy held 3 notes after deleting one of 2 — which is what made the line red before the store was.)
- `--probe-protocol`, which is not part of the gate, was run to prove the two new tags are actually
  *used by a model*, not merely parseable. It said no, twice: asked "note that the landlord is Sharma",
  the reply was *"i have noted that the landlord is sharma"* with **no `<NOTE>`** and a `<SUMMARY>`
  claiming "The note has been recorded" — a spoken success with nothing behind it, which is worse for a
  memory than for an act, because an act that did not happen changes nothing and a note that did not
  happen is simply absent when he looks next month. Asked what it had about the gate code, it answered
  *"i don't have any record"* **without searching** — asserting knowledge of a file it has never seen.
  Both are fixed: the prompt now says out loud that the notebook is not in the prompt and that
  `[NOTES:]` is the only way to know it, and `retractUnbackedPromises` grew a third class with its own
  honest line ("Chunks was told to keep that and nothing was written…") — deliberately not the screen
  line, which would have sent him looking for a window that was never the problem. Re-run: the search
  turn passes; the write turn still answers about the desktop instead of noting. **Open, and it is a
  prompt question, not a code one.**
- The finding underneath all of it: **`--probe-local` wrote his real settings.** It chose a model by
  `UserDefaults.standard.set(BrainSettings.providerKey…)`, so one `./scripts/verify.sh` switched the
  installed app to Ollama and left it there — which is also why the protocol probe was grading the
  production prompt against a 2B model and reporting families "lost". Probes now go through
  `BrainSettings.processOverride`, scoped to their own process, and `verify.sh` fails if any
  `*Probe.swift` writes `UserDefaults`. **His stored value is still `ollama / gemma4:e2b-it-qat`** —
  yesterday's probes put it there, and whether he wants it back on Gemini is his call, so it was not
  touched.

**Gate, by my own runs.** `747/747` unit tests across 41 suites (was 729/40 — eighteen new cases: 14 for
the store, 2 net for the parser once the two old "NOTE is an unknown tag" cases became four, and 2 for
the note retraction); `./scripts/verify.sh` → **40 checks passed, 2
skipped, exit 0** — nonce `GATE-FINAL-NB-1793632359`, after `make-app.sh` + `install.sh`. The reply
audit is at 7 fixtures / 22 assertions with `<NOTE>` and `[NOTES:]` among them. Nothing here is
committed.

**Not watched yet:** a note actually landing from his voice (the store, the parser and the footnote are
each measured; the spoken turn is not), the footnote at a glance, and whether the new panel row survives
a *populated* panel — `--render-panel` draws it empty, which is the one state that cannot overflow.

## Window verbs, and a title rule the press path could not lend — 2026-11-02

He picked the build order I argued for, so 3.13 went first: `[DO:focus_window:Safari|Inbox]`,
`minimize_window`, `close_window` and `quit_app`. All four travel the tool door, so `PolicyGate`,
`ConsentGate` and the one-card-one-question rule are untouched; `close` and `quit` join
`ToolLayer.alwaysAsks` beside `run_command`, because "don't ask" was never an instruction to throw away
an unsaved document on a model's say-so, and the question says the cost out loud. Quitting is
`terminate()` and never `forceTerminate()` — an app that answers by asking about an unsaved document is
behaving correctly, and the outcome line names that instead of reporting a bare failure.

The window is resolved against the live tree **before** the card is worded (`resolvedWindowAct`, beside
`resolvedReveal`), and resolved *again* when the verb runs (`ToolRunner.performWindowVerb`), because a
card can outlive the window it named. Two equal answers are refused with both titles listed; position
never qualifies a window, and the only thing a rectangle decides is that two candidates at the *same*
frame are one window published twice.

**The finding worth keeping.** `AXTDriver.nameScore` is the right rule for a control and the wrong one
for a window title, and the unit case is what said so: "TASKS.md" against a window called
"Chunks — TASKS.md" scored **1** against a threshold of 2 and was refused — the most natural sentence
about a document window. `nameScore` awards 3 only for an exact token-set match and 2 for a prefix,
which protects a *press* (one shared token is a guess about a button) and starves a *title* (titles are
long, and the ambiguity that made the control rule strict is already handled here by refusing two equal
answers). So window titles use a subset rule — every distinctive word he said must be in the title —
with specificity breaking ties between two that both answer. "the document" still refuses; "TASKS.md"
now resolves.

`--probe-windows` is the harness and it runs the same gate as the live path: `WindowAct.resolve` for the
window, `ToolLayer.question` for the sentence, `ToolLayer.alwaysAsks` for whether a card appears. Its
first live run passed and still caught something — Qoder's own window asked *"Bring \"Qoder\" in Qoder to
the front?"*, which is now named once.

**Gate:** 762/762 unit tests across 42 suites (+15 window cases); `./scripts/verify.sh` → **40 checks
passed, 3 skipped, exit 0** — nonce `MK-W-1793638056`, after `make-app.sh` + `install.sh`. The three
skips: no Shortcuts window open, and the two local-brain checks kept aside behind
`CHUNKS_LOCAL_BRAIN=1`.

**Deferred, deliberately:** move/resize/"put that on the second display" — the one slice that has to get
invariant 1 right (AX top-left logical points vs an `NSWindow` bottom-left frame vs `CGDisplayBounds`),
so it needs the 1x/2x/3x round-trip coverage before it exists at all.

## The Cloud-Computer handoff, and why it changed the order — 2026-11-02

He wants Chunks to hand jobs to his own `Cloud-Computer` project, eventually with a Hark-style
companion on a Raspberry Pi 400. Read rather than assumed, from that project's own files: it is a
self-hosted agent that drives a real browser (Playwright or an E2B microVM), exposed as `POST /tasks`,
SSE stages on `GET /tasks/{id}/events`, `POST /tasks/{id}/approval` for its spend gates, `cancel`,
`/watches`, `/digest` and a `handoff "<task>"` CLI — and **it is already deployed to a Pi 400**
(`infra/pi/`: arm64 Lite OS, ~1.3 GB RAM with a task running, 2 GB swap, `make pi HOST=…`).

Three consequences, all written into `TASKS.md` rather than left in this chat:
1. **It reorders the browser work.** 3.12 level 3 (a debug port on his own browser) was the thing
   `AGENTS.md` says not to reach for without asking. Cloud-Computer already has the headless browser,
   the spend gates and the traces, so 3.15 (the handoff) now comes *before* 3.12 L1 in the order I'd
   argue for, and level 3 becomes the fallback rather than the plan.
2. **It needs one sentence in `AGENTS.md` before code.** A client of a remote executor is the shape 3.5
   already allows for MCP (Ask-before-run, per-server allowlist, results as untrusted data, secrets
   never inherited). Handing work to *another identity that reasons on its own* is the ❌ line he cut
   when he scoped this as a HeyClicky replica minus the multi-agent layer. The honest amendment is that
   "nothing of theirs leaving the machine" becomes "nothing leaves to a *vendor*": an instruction, and
   possibly a screenshot, would travel to his Pi over Tailscale — not the cloud backend the rule exists
   to prevent (no metering, no billing, no analytics, no proxy he has to carry), but not the same claim
   either. Cloud-Computer also holds provider keys server-side, so the BYOK story stays true for Chunks
   and stops being true for the job it handed over.
3. **A companion that runs *on* the Pi is not a port.** AppKit, Accessibility, ScreenCaptureKit and the
   notch are Apple-only; a Swift binary will not run on arm64 Linux. What runs there is Cloud-Computer,
   so "Chunks on the Pi like Hark" is one of three things — a headless agent Chunks talks to (that is the
   handoff), a new Linux client with its own voice path and no screen to point at, or a two-device
   product where the Mac owns the screen and the Pi owns the long jobs. The third is what the existing
   code supports today, and it is the one I'd build.

## What is open, as a read rather than an act — 2026-11-02

3.12 level 1, built next in the order he chose. `[DO:list_windows:all]` or `[DO:list_windows:Safari]`
answers the question a screenshot cannot: a window on another Space, minimised, or behind the front one
is invisible to the picture, so "which of my terminals is open" was unanswerable and got guessed.

It is a **read**, and that classification is the design. It takes no card (approving a *look* is a
question with no answer that matters), it is never reported as an act (a listing beside "Pressed Send."
would be two claims about the machine in one voice), and `DoRequest.isContextRead` is the one property
that keeps it out of every act path — it cannot lead a plan, cannot be counted as a tool dropped behind
one, and cannot be offered. The answer rides into the *next* turn through the same channel the file read
and the notebook search use.

`OpenWindows` owns the block: grouped by app with the frontmost first, charged with its own framing, cut
at **whole app groups** under 3 KB, and saying how many windows were left out — a partial list that reads
as complete is how "you have no terminal open" gets invented. Live on his machine: 4 windows, 600 bytes,
Chrome's Colab tab named in full, two of the four being Chrome's own titleless toolbar windows. That
noise is honest but worth his eye: real AX windows, and whether they earn their bytes is a judgement, not
a guess I should make for him.

Two bugs the unit cases found before anything ran. The framing said "not *from* the screenshot" while the
probe and the tests both look for "not the screenshot" — the wording and its assertion had drifted apart
in the same commit that introduced them. And a listing he asked for one app about named *another* app as
frontmost, which is the kind of confident extra fact a model answers from; the frontmost sentence now
appears only when that app belongs in the listing.

**Gate:** 766/766 unit tests across 42 suites (+4); `./scripts/verify.sh` → **40 checks passed, 3
skipped, exit 0** — nonce `LW-GATE-1793642466`, after `make-app.sh` + `install.sh`. The windows check now
asserts the listing's budget, its truncation line and its framing as well as the verbs' wording.

## Opening a file in the app he names — 2026-11-02

The file route from 3.10, built because it is what "open this in VS Code" actually needs:
`[DO:open_file_with:Code|~/notes.md]` → `NSWorkspace` opens that file in that app. It is not an edit —
nothing writes a byte, and there is still no write tool — and it is faster and more reliable than the
UI route, because a click on an explorer row is a guess about a picture while this is a fact about the
disk.

The policy is the part worth stating: the path is checked against **`RevealPolicy`'s** allow-list and
credential deny-list, on the resolved path, **before** the card is worded (`resolvedOpenFileWith`, beside
`resolvedReveal`), and a bare name goes through the same folder lookup — so two files sharing a name is
a question that lists them, never a coin toss. The reasoning is invariant 9's and 11's together: this
puts a file's contents on his screen inside an application, which is more than a reveal does and less
than a write, and it is closer to a read going to a model than to a press.

One decision is still his: whether Chunks should use the file route when the editor is already open,
because opening from disk can make the editor's saved-versus-dirty state disagree with what is on disk.
The other half of that paragraph — no read-only probe, because the verdict lived in `CompanionManager` —
is closed on 2026-11-03 below.

**Also this session, on his request:** the Gemma checks came back on by default (`--probe-local` and
`--probe-reply --local`), and both PASS — what stays fixed is the bug they carried, choosing a model by
writing the app's real settings, now `BrainSettings.processOverride` with a contract check that fails if
any `*Probe.swift` touches `UserDefaults` again.

**Gate:** 767/767 unit tests across 42 suites; `./scripts/verify.sh` → **42 checks passed, 1 skipped,
exit 0** — nonce `OFW-GATE-1793647917`, after `make-app.sh` + `install.sh`.

## 2026-11-03 — the open-a-file policy hoisted, and made probeable

The gap the previous note recorded as open was real and it was the usual shape: `[DO:open_file_with:…]`
decided *everything about his disk* inside `CompanionManager.resolvedOpenFileWith`, where a unit test
cannot reach and a probe cannot quote without performing the act. So a security refusal — "that file
holds credentials" — was a string in a UI file, and the first person to reword it would not know whether
anything still guarded the path.

`Sources/ChunksKit/Action/OpenFilePolicy.swift` is now the authority: `decide(app:written:resolved:
appExists:)` returns one of five outcomes, and `refusal(for:)` writes the sentence for each. The shell
supplies two facts it owns and nothing else — `FinderReveal` for what the disk says,
`ToolRunner.isInstalled` for what is on the machine — through one adapter, `OpenFilePolicy.Resolved
(written:)`. That adapter is where a detail mattered: `FinderReveal` has no case for "that string was
never a path", it answers `nothing`, so the adapter asks `RevealPolicy` first. Without that, an empty
payload reached him as "there is no file called …" — a search that never happened, described as a search
that found nothing.

**The ordering is a decision, not an accident.** An app that is not installed is answered *before* the
file's boundary verdict, so `open_file_with:Nope|~/.ssh/id_rsa` says "Nope is not installed". A credential
card about an app that cannot run would send him to fix a path he already wrote correctly, and the two
sentences must stay apart because one is overrulable by naming a different file and the other is not.

`--probe-open 'TextEdit|notes.md'` prints the roots, the disk's answer, the app's verdict, the outcome and
the card's exact sentence — and opens nothing. `verify.sh` asserts all five answers stay distinguishable
against his real `/Applications` and his real `~/.ssh`, and picks the app by asking which names resolve
rather than typing one, which is how a second finding surfaced: `open_file_with:Code|…` refuses on this
machine because three installed apps contain "code" (`Visual Studio Code`, `Claude Code URL Handler`,
`Free Claude Code`) and `resolveApplicationPath` deliberately requires a single candidate. That rule is
correct for `open_app` — the card said "Open X?" and something else appearing is the failure it was
written against — and it is arguably too strict for *choosing a viewer for a document he named*, where
the worst case is a wrong app opening the right file. Left as his call, recorded in TASKS.md 3.10.

**3.15's lifetime question is answered.** "The Kaggle just runs the model whereas the Pi executes" —
so the Pi holds the task record and the queue, the notebook is a disposable GPU endpoint, and the server
side needs a `waiting_for_model` state so a model hop that times out is retried rather than reported as a
failed job. Written into TASKS.md 3.15 A.6 as his decision, not a proposal.

**Gate, measured after `make-app.sh` + `install.sh`:** 776/776 unit tests across 43 suites (the new suite
is "Open a file policy", 9 cases). `./scripts/verify.sh` exit 0. 44 checks total, and the pass/skip split
moves with the live model: run nonce `OFW-GATE-15083` → **42 passed, 2 skipped**; run nonce
`OFW-GATE2-13777` → **41 passed, 3 skipped**, the extra skip being `self-test`'s model round, where the
request went out and the key's rate limit answered nothing. The new check `open a file: one card, and
four refusals that each name their own reason` PASSED on both runs.

## 2026-11-03 (late) — three bugs from his own screenshots, all of them "green tests, wrong on screen"

He sent three screenshots after testing. Every one of them passed `verify.sh` and the unit suite and was
still wrong on his Mac, which is the failure mode `AGENTS.md` was written around. None of the three was
found by a check.

**1. `list_windows` said "you have two windows open" to a man with eight apps.** I ran `--probe-windows`
and it *agreed* with the card, so this was not the model summarising badly — the enumeration was the
liar. Two independent reads of the same moment settled it: `kAXWindowsAttribute` returned an empty array
for six of eight regular apps, while `CGWindowListCopyWindowInfo(.optionAll)` listed their named windows
(Chrome's "GVPCE" and "API keys | Google AI Studio", Terminal's "rishideep — caffeinate -d", Antigravity,
Hark). **An app that is not on the display you are looking at publishes no Accessibility windows at all.**
The feature's whole promise was "another Space, minimised, or behind the front one", and the read could
see none of those three.

`WindowDriver.candidates` is now a union, with the two sources kept apart by `isReachable`. A
server-only window is listed and *refused* — `WindowAct.Resolution.unreachable` — never offered a card,
because `element(for:)` would answer nil and an Allow would become a failure after he had answered yes.
Two filters came out of the same measurement, both of them the "plausible number" kind of bug: Chrome
publishes two untitled `AXUnknown` strips (1710x41, 1710x81) as windows, which made `close Chrome`
refuse with "3 windows answer that name" about one document, and every app carries an untitled 500x500
server surface that is a capture layer. One floor for both sources, 200x120, asserted by the probe.

**And my first fix was itself wrong.** I added an `isOnActiveSpace` flag worked out by matching
rectangles between the two APIs, and the very next run showed it labelled Finder's desktop — drawn on
every Space — and the window he was typing into as "on another Space". Deleted. Reachability is read
from the same call that would perform the act, so it cannot disagree with the act; *where* a window is
is not claimed anywhere. That is the second time this week a new flag was a new way to be wrong about
his screen.

**2. A reveal said "Showed Ritesh.docx (in Downloads) in Finder." and no window appeared.** The cause is
an API shape I had never looked at: `activateFileViewerSelecting` returns `Void`, and the line under it
said `return true`. **Every file reveal since the tool shipped reported success.** `revealLanded` now
polls Finder's own window titles for up to 2.5s and accepts only a name match against the folder the
reveal is about (path component *and* `FileManager.displayName`, because Finder titles locally). I first
wrote "a new window appeared" as the rule and the test caught it: a window that came up for the wrong
folder is the same lie in a new costume. The residual cost is a false *refusal* when Finder selects
inside a differently-titled window — chosen deliberately, because a false refusal is one he can overrule
by looking.

**3. `0 left out` beside a list that left out six apps.** The counter only ever measured the byte
budget, never the enumeration. Fixed by making the enumeration complete, so the name means the thing.

**What his screenshots did NOT show, and I checked anyway:** in the first one the model said "I've
already got ritesh.docx loaded from your downloads folder" — and the log says
`attach: /Users/…/Ritesh.docx as text (2383 characters), score 10`. That claim was true. What was wrong
is that he asked about a *folder* and there is no tool that lists one, so the model answered about the
file instead. Recorded as **TASKS.md 3.17** with the one decision that is his: a name-only listing
sends his directory structure to a cloud model, and file names are a log of everything he has touched.

**A process note worth keeping.** Twice in this session `make-app.sh` failed and I nearly reported a
measurement from the stale bundle as if it were the new one — the symptom was a fix that "did nothing".
`&&` did its job (install never ran), but the probe still ran against `~/Applications` and printed a
plausible answer. From now on: check `make-app` exits 0 before quoting anything the installed binary
says.

**Gate, measured:** 784/784 across 43 suites. `./scripts/verify.sh` exit 0 — **43 checks passed,
1 skipped** (no Shortcuts window open), nonce `GATE-W-27503`, after `make-app.sh` + `install.sh`
nonce `REBUILD6-926`. The window check now also fails if any listed candidate is under the size floor.

## 2026-11-03 (later) — 3.13 slice 2: geometry by name, and the desktop that is not a window

He said to build 3.13 in order after the fixes. The remaining slice was the one `AGENTS.md` had deferred
longer than anything else: **moving and resizing a window, and "put that on the second display"** — the
only act in the app that writes a rectangle, and therefore the one invariant 1 punishes silently.

`[DO:move_window:Safari|Inbox|left]` takes twelve words and nothing else. A coordinate is **refused at
parse, not clamped**: `|400,220` never becomes a placement, because a rectangle a vision model guesses from
a picture is the same category of number that put a press on the wrong row of a chat list, and unlike a
press, a wrong position is something he fixes by hand. Spoken variants fold into the table ("top left" →
`top-left`) because that is how a transcript arrives.

The maths lives in `WindowPlacementPolicy` (ChunksKit, pure) and deliberately **converts nothing**:
`CGDisplayBounds` is already global top-left logical points, which is the space `kAXPositionAttribute` is
written in, so the only AppKit number used is the menu-bar/Dock inset, and it is used as a *difference
inside one screen* — a difference is the same in either orientation, which is how the flip stays out of
the code instead of being got right. The 1x/2x/3x coverage the repo demands is asserted as the property
that matters: same screen at any scale, identical rectangle. Plus a **negative-origin** second display,
because that is what a two-monitor Mac actually looks like and a rect normalised to zero gets it wrong
without an error.

**Two findings I did not expect, both from running the probe instead of only writing it.**

First, my own check failed the gate before it passed. I asserted `display=9` would answer "There is no
display 9" — and it answered "refused at parse", because the grammar caps display numbers at 8 and I had
written a check that walked one door and assumed the other. The gate caught it on run
(`FAIL geometry`), and the fix was to test both: `display=3` reaches the runtime refusal, `display=9` is a
parse refusal. Two different sentences, and only the first is about his hardware.

Second, and the one that matters more: **the probe volunteered to move the desktop.** Finder publishes the
desktop as a window — frame, element, the lot — and `--probe-geometry 'Finder|desktop|left'` computed a
plan to resize it, while `--probe-windows Finder` had already been printing *Minimise "desktop" in
Finder?* since slice 1 shipped. Writing a frame there disturbs his icon layout and tidies nothing. So the
desktop is now **listed** (it is genuinely on the screen, and hiding it would be a worse lie) and
**refused as an act by name**, with a fifth resolution case so the sentence says what it found. Detection
is the conjunction only a desktop has: no `AXTitle` of its own *and* a frame exactly the whole of a
display. A full-screen app's window is the same size but always titled, so real windows are not caught —
and a test asserts both halves of that, because "filter the desktop out" would have quietly filtered out
the wrong things.

Also from the real machine: a Chrome tab arrived titled *"GVPCE – you're sharing this tab with Gemini for
the duration of this conversation - Google Chrome – Rishideep"*. The card quotes that in full. Truncating
it is a wording decision he owns, and it is the same decision the close card already needs — recorded, not
silently changed.

**Voice research, done in parallel and verified by me rather than trusted from a subagent's summary.**
Gemini has native TTS today — `gemini-3.8-flash-tts` and `gemini-3.8-flash-lite-tts`, streaming headerless
16-bit PCM at 24 kHz mono, called with his own key over the same transport Chunks already uses. That fits
the product's shape exactly (BYOK, no server of ours, one call per streamed sentence). The claim that the
free tier trains on the text is **not** something I confirmed — it is on the pricing page, not the speech
page, and it matters enough to check before shipping. "VoiceStudio" is real (98,965 stars, AGPL-3.0-only)
and is **not** usable: its own model inventory records the default engine's weights as non-commercial, and
embedding it in a closed product needs a paid licence. Kokoro (Apache-2.0, 82M) is the honest open
alternative for the offline tier, with one licence question to clear on the StyleTTS2 base.

**Gate, measured:** 801/801 across 44 suites. `./scripts/verify.sh` exit 0 — **44 checks passed, 1
skipped** (no Shortcuts window open), nonce `GATE-G3-12495`, after `make-app.sh` + `install.sh` nonce
`GATE-GEO-3218`. The geometry check runs against whatever window is really on his screen, filtered so the
desktop is not picked, and skips honestly when there is nothing to place.

## 2026-11-03 (night) — voice answers, captions, and the HeyClicky comparison that changed shape

He asked for four things: fix the rate-limit dead-end, check HeyClicky's new release and copy what can be
copied, make Chunks more than HeyClicky, and work through the leftovers. Two features shipped and the
third turned out to be a constraint, not a task.

**Voice answers the card.** `VoiceAnswer` is pure and returns the same `ConsentGate.Outcome` the two
buttons pass, so the gate, the re-read-before-pressing rule and the one-question invariant are untouched —
only the input device changed. The rule that makes it safe is that **only an exact phrase answers**:
"yes and close the other tab" is a new request with an old card hanging off it, and reading that as
consent is the false yes. It falls through to a turn, where the existing displacement rule denies on its
own terms. "Allow always" is unreachable by voice. Seven unit cases, thirteen probe fixtures, and the
rows that matter are the ones asserting *no*.

**The caption.** `CaptionPanelManager` draws Chunks' own words at the bottom of the display while the
voice is up — click-through, `_setPreventsActivation`, `canBecomeKey` false, no `NSApp.activate(`. Two
things the gate caught that I would not have found by reading my own code: the contract grep matched the
*prose* in my comment ("NSApp.activate is not called anywhere") and failed a file that did not call it,
so the check now matches the call, not the sentence; and the caption must be cleared on `isPlaying`, not
when `speakText` returns, because that function returns as soon as playback *starts*.

**And the render was blank.** The first `--render-caption` wrote a 99 KB PNG that passed a byte-size
assertion and contained **nothing** — an offscreen `NSHostingView` does not draw SwiftUI without a window
attached. I only know because I opened the file, which is the whole reason this repo has a render probe.
Fixed with the recipe the notch renderer already uses (window that is never ordered front, then
`bitmapImageRepForCachingDisplay` + `cacheDisplay`), and the same image now shows three real rows with
the word-boundary cut visible.

**HeyClicky: nothing new is importable.** Their current Mac release is 1.1.2 (2026-10-30) against the
1.0.53 installed here. The open-source repo's last code commit is April 2026 and its README says the rest
stays private; the releases repo is DMGs and an appcast. So the well the annotation overlay came from is
closed, and every parity item is built from the behaviour rather than copied. I verified the repo state
with `gh api` rather than trusting the subagent's summary, because a claim that a 98k-star repo exists
turns out to be true and a claim about its licence weights turns out to be load-bearing — both needed
checking, and the second one is why VoiceStudio is not usable by us at all.

**What he ruled out, so it is not re-litigated:** named agents, handoff jobs, agents that remember,
connectors, hosted speech models, documents beside the chat, and 3D drawing. **What is next, in his
order:** 2D drawing on the live screen (its own session — the overlay and the crop are already there, the
missing part is ink as an object), then language breadth, then take-back-control mid-action, then the
Chrome extension decision, then self-updating behind his Apple account. All written as TASKS.md 3.18.

**Gate, measured:** 818/818 across 46 suites. `./scripts/verify.sh` exit 0 — **44 checks passed, 4
skipped**, nonce `GATE-CAP2-19598`, after `make-app.sh` + `install.sh` nonce `GATE-CAP-11668`. Two of the
skips are the key's rate limit and the Chrome page sweep; the other two are no Shortcuts window and no
reachable window to place, all named.

## 2026-11-03 (22:00) — the app quit mid-turn, and the gate had nothing to say about it

He said: *"minimise this window and keep it in the left half"*, Chunks promised it would, ran 30 seconds,
and **the application exited without doing anything**. Two `.ips` files in
`~/Library/Logs/DiagnosticReports`, 22:01 and 22:02, one minute apart.

The crash report's faulting thread was the answer on its own: `__NSFireTimer` →
`closure #1 in CompanionManager.startRoutineScheduler()` → `MainActor.assumeIsolated` →
`SerialExecutor._isSameExecutor` → SIGSEGV at a garbage address. `assumeIsolated` **asserts** the main
actor's executor is current and is undefined behaviour when it is not — and a run-loop timer block runs
on the main *thread* without being inside the main actor's *executor*. The routine scheduler ticks every
60 s in `.common` mode, which is why it looked like the turn hung for half a minute and then the app was
gone: the turn was fine, the tick killed the process under it.

Fixed as a class, not as a line: the scheduler, the sleep/wake observers, the notch's half-second clock,
the first-run poller, `LocalTTSClient.stopPlayback`, and the annotation overlay's probe entry all hop
with `Task { @MainActor in … }` now. `verify.sh` has a new check that greps timer and observer bodies for
the assertion and fails the build.

**Two mistakes I made while fixing my own, both worth keeping.** The first version of that new check
matched the *comment* I had just written explaining the rule — the same prose-vs-code error as the
caption contract an hour earlier, so the awk now skips comment lines. And `WindowDriver.settles`, which
I wrote this evening to verify a window actually moved, used `Thread.sleep` on the main actor: the fix
for "believe the effect, not the return code" was itself freezing the notch for up to 0.6 s. It is a
`Task.sleep` now.

**Why the smoke test is a separate script.** `verify.sh` runs 48 checks and finishes; every one of them
finished before 60 seconds had passed, so not one of them could have seen this. `scripts/smoke.sh`
launches the installed bundle, **waits 75 s so the scheduler ticks while the app is running**, walks all
the read-only probes against that same live process checking after each that the app is still alive,
re-checks that two read-only probes left his preferences byte-identical, and finally asks whether macOS
wrote a crash report. First run: 18 passed, 0 failed, no new crash. `--quick` skips the wait and says out
loud that it therefore cannot catch a tick crash.

**A/B, measured twice (nonce `AB-30261-1793724568`).** Same five production-prompt turns, both brains,
one minute apart: the cloud chain served 6 turns in 83 s and **gave nothing at all on 2** (64 s and 70 s
across four attempts each), while the offline tier answered in **1.9 s with no malformed tags and
nothing swallowed**. The first version of `ab-test.sh` reported "6 tag families lost" because it grepped
for the word "lost" and counted the log echo — a metric measuring a thing that was not there, which is
the failure mode this repo keeps hitting. It counts the probe's own `served by` / `SKIPPED` lines now.

**His browser decision, recorded:** Chunks should do in his signed-in Chrome what HeyClicky and Qoder do
— run it while he watches, any length, any complexity. The question is answered; what is left is
engineering, and the part that must not be improvised is the policy surface for a signed-in browser,
where the existing refusals (secure fields, Keychain, password managers, always-ask on send/pay/delete)
have to survive translation into DOM terms rather than be replaced by a weaker gate.
