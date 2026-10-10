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
it. Run bundle diagnostics as their own app: `open -n -W build/Chunks.app --args --probe-stt 5`
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
The script assembles `build/Chunks.app` from `.build/debug/chunks` (or `.build/release` with the
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

## Where it stands, and what's next


Verified working on the user's machine: press, launch-and-believe-the-effect, type into WhatsApp's
composer, scroll resolution, open-url, plans, the notch card, memory, push-to-talk (after the
revert).

| # | What | Why it's next |
|---|---|---|
| 31a | ~~`SpeechAnalyzer` behind `BuddyTranscriptionProvider`~~ **done, and the default** | Measured on the user's voice; `dictation` won. Needs one real ⌃⌥ turn on the new engine before it stops being a lab result. |
| 31b | Tap-to-arm instead of hold-to-talk | Still to build. Blocked on one decision: with no key-release edge, what ends a dictation — a second tap, a silence timeout, or the engine's own endpointing. |
| 29 | The app window: sidebar history, chat bubbles, input bar, settings | The user has shown the reference UI twice and said the notch card is not the surface he wants. **He has changes to propose here — ask before building.** |
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

## Not yet built

automations, reminders/planner (Phase 6), the notch face (Phase 7), any consumer
for `<NOTE>` offers, the app window.
