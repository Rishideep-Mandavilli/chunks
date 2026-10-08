# Chunks — Agent Instructions

<!-- Single source of truth for AI coding agents working in this repo. -->

## What Chunks is

A native macOS menu-bar/notch companion that **sees your screen, explains it, and helps you act
on it** — by voice. Circle a region, get an explanation of that region. Ask where a
button is, watch the pointer trailer glide to it. Tell it to do something, confirm, it acts.

Scope is a **HeyClicky replica minus the multi-agent layer** (plan §11). It has one agent with
real tools, bundled skills, memory about you, routines, realtime voice, and a face in the notch.

## What Chunks is NOT

Hard scope boundaries. These are not "nice to have later" — they are out:

- ❌ **No sub-agents, no agent teams, no roster of named agents.** Exactly one assistant, one
  task per turn. It may call tools; it may not spawn workers or hand work to another identity.
- ❌ **No generated files.** No `welcome.html`, PDFs, decks, or `<ARTIFACTS>` tiles. The agent
  reads files and screen content as *context*; it does not emit artifacts.
- ❌ **No skills marketplace.** Skills are bundled `SKILL.md` context files, chosen by intent.
  No authoring economy, no sharing, no catalogue.
- ❌ **No cloud backend.** No model proxy, no metering, no billing, no analytics. BYOK direct
  to the provider, `store:false`, keys in the Keychain.
- ✅ **A single tool-calling agent is in scope** — the native tool loop *is* the product.
- ✅ **Bundled skills, routines (`launchd`, read-only by default), MCP integrations with
  Ask-before-run** — all in scope.

If a change would add anything in the ❌ list, it is out of scope. Say so rather than adding it.

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
./scripts/make-app.sh && ./scripts/install.sh   # the app you actually use
```

**Always build the bundle with `scripts/make-app.sh`, never by hand, and never run the bare
binary from `.build` for permission work.** macOS identifies an app to TCC *and* to the Keychain
by its code signature, so the signature is a product requirement, not packaging trivia:

- An ad-hoc signature **is** its cdhash, so every rebuild is a brand-new app. The grant you just
  ticked stops applying, and the stored Gemini key disappears from view too, because a generic
  password's ACL names the app that wrote it.
- `make-app.sh` therefore finds the "Chunks Local" identity itself. It has to search
  `security find-identity -p codesigning` *without* `-v`: the self-signed certificate reports
  `CSSMERR_TP_NOT_TRUSTED`, which `-v` filters out, while `codesign` happily signs with it.
- The repo lives under `~/Documents`, and iCloud's file provider re-stamps `com.apple.FinderInfo`
  onto the bundle within milliseconds, which makes `codesign` refuse ("resource fork, Finder
  information, or similar detritus not allowed"). Hence the clear/sign/verify retry loop in
  `make-app.sh`, and the re-seal of the copy in `~/Applications` in `install.sh` — that directory
  is not synced, so a seal made there sticks.

**Verifying a screen point without pressing anything:**

```bash
.build/debug/chunks --probe-ax 855,553                  # global top-left logical points
.build/debug/chunks --probe-ax 1287,86 --named "free claude code"   # + what the name fallback finds
```

Read-only by design — a CLI flag that could act anywhere would be the one surface that skips the
confirm card. It prints the layer-0 windows, what the AX hit test resolves the point to, its
role/title/pressability, and what the card would ask or refuse. Add `--named "the label"` to see
what the **name** fallback resolves the same point to — the two differ, and only the second one
finds a desktop icon. Run the *installed* bundle to
test with the real grants:
`/Applications/Chunks.app/Contents/MacOS/Chunks --probe-ax 855,553`.

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

   A third, and the one that broke computer use for a whole evening: **the model's aim is a
   fraction, not a pixel.** The tag space is a 0–1000 grid over the image (`ScreenshotGeometry
   .gridEdge`), because that is the space Gemini answers in — measured 2026-10-04, it asked for
   WhatsApp's send button as `(955, 975)` three turns running when the button sat at image pixel
   `(1238, 814)` of a `1280x829` image. Divided by the image size that aim is 118% down the
   screen, clamps to the last row, no window contains it, and the user reads "did not expose a
   control" about a button in plain sight; a row in the middle of the screen lands on its
   neighbour. A number above 1000 cannot come from the grid, so it is read as pixels — and the
   mapped point is kept half a point *inside* the display, because window bounds and the AX hit
   test are exclusive at the far edge.

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

6. **Retries are mandatory — on the axis that can actually clear.** Gemini free tier returns
   `503 high demand` on roughly half of requests against the newest flash models, and caps at
   ~5 req/min **per model**. So `503` backs off and retries the *same* model (it clears in
   seconds), while `429` switches to the *next* model immediately: a minute-long window will not
   clear inside a turn, and every other model has its own untouched budget. One `RateLimiter` per
   model id, never a shared bucket — shared, a contended model throttled the healthy ones behind
   it. Keep the chain fast-first: `gemini-3.1-pro-preview` measured 55s and still came back
   contended, so Pro is the last escape hatch, not the second slot. `BrainGateway` logs the
   chain, each per-model failure with the decision taken, and the model that served with its
   elapsed seconds. A turn that fails on 503 is a bug, not bad luck — and so is one that takes
   a minute. Measured on the same screenshot: 72.0s before these rules, 6.6s after.

7. **A listen-only keyboard tap needs Input Monitoring, not just Accessibility.**
   `CGEvent.tapCreate` for key events is gated by `kTCCServiceListenEvent`. With Accessibility
   ticked and Input Monitoring missing, the tap is created without error and receives *nothing*
   — so ⌃⌥ push-to-talk and ⌃⌥⌘C are both dead while every permission row reads "Granted".
   Check `CGPreflightListenEventAccess()`, and never let a tap failure reach only `print()`:
   output from an app started by `open` is unreadable. It goes through `Log.write`.

8. **The model proposes every act; the app decides whether it happens.** A `[ACT:x,y,label]` is
   a request, and it travels a fixed chain: `ResponseParser` → `ScreenshotGeometry` (image
   fractions → AppKit bottom-left → AX top-left) → `AXTDriver.target` → `PolicyGate` → the
   confirm card → `ConsentGate` → `AXTDriver.press`. Before pressing, the point is read again and
   the element compared to the one that was approved — a card can outlive a relayout, and pressing
   whatever moved under those pixels is not what the user agreed to. Nothing may shortcut a step,
   and the press
   is always `AXUIElementPerformAction`: posting a synthetic mouse event has to be aimed by
   warping the pointer, which is the one thing the user watches Chunks *not* do. A press the
   policy forbids is **refused, not asked** — offering it would make "Allow" a lie.

   **The user, not the model, owns the question.** `askBeforeActing` (panel toggle, Keychain-free
   `UserDefaults`, default **off**) chooses only whether `.needsConsent` becomes a card or
   `.allowedWithoutAsking`. It cannot reach the two rules above: secure fields, Keychain and
   password managers stay forbidden with asking off, and the re-read-and-compare still runs before
   every press. What a skipped question costs is the card, so the driver's outcome line
   ("Pressed Pluralsight.") is returned by `offerAct` and **spoken** — with no card, an act the
   user cannot hear or see reported is indistinguishable from an act that did not happen. The
   prompt follows the same switch (`CompanionManager.actingRules(askBeforeActing:)`, spliced in
   per turn): on a machine where asking is off, "i'll ask you to allow it — tap Allow" is a promise
   of a question that never arrives, which is what the first Pluralsight turn said out loud.

   `AXTDriver.target(label:at:)` resolves the *pixel* first and falls back to a **name** search of
   the focused window's subtree, because a model that aims a few points off an icon still named the
   right thing. A fallback press is logged as `act: aim missed, answered by name`, capped at
   `maxNameSearchElements` AX reads so a wrong guess on a huge page cannot wedge the notch, and is
   scored by `nameScore` (exact tokens > prefix > single token) with distance only breaking ties.
   **When that fails, ask Finder** (`desktopTarget`): `CGWindowListCopyWindowInfo` stops listing the
   desktop as soon as another app covers it, so the icon route worked at 18:18:00 and died at
   18:18:30 — because the press at 18:18:00 *opened an app*. Finder keeps publishing the icons
   through its own `AXWindows` either way (live dump while an app was frontmost: `AXImage "Free
   Claude Code" at (1616,41 64x64) actions=AXOpen`), so the desktop search goes to the app element
   directly instead of through the window list. It demands `desktopMinNameScore` (2 — a prefix or an
   exact token set), not the 1 that suffices inside the window the aim actually landed on, because
   "the claude thing" matching one word is not a licence to press in another app.
   Two facts cost real probing to find and are the reason refusals used to read as "app not
   supported": desktop icons publish **`AXOpen`**, not `AXPress` (`pressActions` lists all three),
   and the Finder desktop sits at a *negative* window layer, which `CGWindowListCopyWindowInfo`'s
   `.excludeDesktopElements` and the old `layer != 0` filter both threw away — hence
   `candidateWindows(includeDesktop:)` and `currentWindowCandidatesIncludingDesktop()`. Verify
   without pressing: `chunks --probe-ax x,y`, and `--probe-desktop` for the layer/tree dump.
   The name fallback has now run on real hardware and resolved the right control; what has never
   been seen is a press whose own return code said success.

   **An app can answer a hit test and still publish no windows.** WhatsApp — the app the user
   actually points at — returns an *empty* `AXWindows` from its app element, and its `AXChildren`
   holds a menu bar and nothing else, so a name search started there reads an empty room and
   refuses controls the user can see. `AXTDriver.searchRoot` therefore climbs `AXParent` from the
   element the aim hit until it finds an `AXWindow` with children, and searches that. Measured
   2026-10-05 on the live app, frontmost: the point in the input row resolves to
   `AXTextArea "Compose message"` at (1115, 1082) and the row at (244, 851) to
   `AXButton "Nitesh GVP 2"`, `pressable=true`, both by pixel. Three more facts from the same walk,
   all of which contradict what the older code assumed: the human-readable name is in
   **`AXDescription`, not `AXTitle`** (every title came back empty); a chat row is an `AXButton`
   answering `AXPress`, so the press path is right for it; and **there is no Send control while the
   box is empty** — that row publishes Emoji picker and Voice message, and Send only exists after
   something has been typed, which is why "click send" on an empty composer can never resolve and
   why the prompt now says to type first and press send in the next turn.

   **A browser publishes an element before it publishes that element's actions.** Measured
   2026-10-05 at one point on a live Chrome page: the first read answered
   `AXShowMenu, AXScrollToVisible` and reading *the same element* again answered
   `AXPress, AXShowMenu, AXScrollToVisible`. Chromium builds action lists once an assistive client
   has walked the node, and the two switches that used to force it early are both refused —
   `AXEnhancedUserInterface` with `-25208` (not implemented) and `AXManualAccessibility` with
   `-25205` on real Chrome, though Electron apps accept the latter. So `isPublishingLazily(actions:)`
   recognises the "no press verb yet, but `AXScrollToVisible` already" signature and
   `walkToPressable` / the name search read the tree a second time after `webActionRetryDelay`
   (150 ms) — but only on that signature, so a genuinely dead element costs one round trip, not two.
   Without the retry, "click the Usage link" in Chrome answers *"that is not a control Chunks can
   press"* about a link that works.

   **A name can match a control the user cannot see.** Same day, `--probe-ax 900,120 --named
   "search"` over Chrome's address bar resolved an `AXMenuItem` at **y = −82**: a row of an omnibox
   dropdown that had already closed, still addressable in the tree. With asking off that is a press
   on something invisible — the exact failure the confirm card exists to prevent. `AXTDriver
   .isOnScreen(_:in:)` therefore vetoes any candidate whose frame lies outside the window the aim
   landed in, on both the pixel and the name route, and the search then returns the visible
   `AXTextField "Address and search bar"` instead. An element with *no* frame is still allowed,
   because most desktop icons publish none and refusing them would break the presses that work.

   **An advertised action is not a performed one.** Measured 2026-10-04 on two live turns. First: the
   name search found `AXImage/Pluralsight` at (1644,200) — the icon's real frame, so resolution was
   right — `AXOpen` was performed, and Finder answered `-25205`
   (`kAXErrorAttributeUnsupported`; `-25206` is the action code, and the two mean opposite things)
   with **nothing launched**, which `ps` plus `log show --predicate 'eventMessage CONTAINS[c]
   "pluralsight"'` confirmed. `--probe-desktop` explains why: every desktop icon advertises exactly
   `AXOpen, AXShowMenu`, and a double-click on one *selects it first*. So `perform` writes
   `kAXSelectedAttribute` before an `AXOpen` and nothing else (`shouldSelectFirst`) — selecting an
   ordinary button would move focus out from under the user. Second turn, on that build: the same
   `-25205` came back for `AXImage/O'Reilly`, **and the app opened** — the user's photograph showed
   its "Data Access Blocked" privacy dialog. So the capability was fixed and the *report* was the
   remaining bug.

   Two more consequences of the same incident. `.actionFailed` carries the attempted verb and the
   element's advertised action list, because a bare code cannot distinguish "Chunks asked for a verb
   the control never had" from "the app refused the one it did"; and `errorCodeName` spells the code
   out, since one digit separates "answered badly" from "did not run".
   `pressAct` now takes a `pressSnapshot` (frontmost pid + every `.regular` app's pid and name)
   *before* pressing and, when the verb fails with a code `isAmbiguousFailure` accepts (`-25205`,
   `-25204`, `-25200` — never `-25206`, which is answered by trying the next advertised verb inside
   `perform`), gives `waitForLanding` 2.5s to diff a second snapshot. `pressLanded` believes the
   effect: focus moved to a different app, or an app whose name answers the spoken label
   (`nameScore >= 2`) started running. Neither → the failure stands, and the code is always logged
   whichever way the report went. Reading the pressed element's own pid would have been the obvious
   check and is the exact mistake: for a desktop icon that pid is **Finder's**, so it can never see
   the app the user opened. The 1.5s window was too short for the same reason — a cold launch that
   also raises a TCC dialog is seconds. **This rule can only correct a report, never cause a press**;
   its one false-positive route is the user switching apps inside the window, accepted because the
   alternative is what told the user a real launch had been refused.

   `[DO:open_app:X]` and `[DO:set_volume:N]` are the same invariant off-screen: `DoRequest.parse`
   is the only door (an unknown tool, a path-shaped app name or an impossible volume fails to
   parse and reaches the user as plain text), `ToolLayer.question(for:)` is the one honest
   sentence about the effect, and `ToolRunner` performs only what the *same* `ConsentGate`
   released. **One card holds exactly one question**: a reply proposing both a press and a tool
   gets asked about the press, and the tool is logged and **not run** — an unanswered request
   fails toward doing nothing, never toward doing both. With asking off, `offerTool` logs
   `tool: acting —` and runs directly; the outcome line still lands on the card.

   `[SCROLL:x,y:label|down]` is the third verb, and the reason it exists is a measurement: a
   synthetic `CGEvent` scroll wheel **moves the pointer** to the event's location (checked
   2026-10-05 — the cursor jumped from where the user left it to exactly the aimed point), which is
   the one thing invariant 8 forbids. So scrolling goes through the element's own Accessibility
   verbs — `AXScrollDownByPage` and friends, falling back to `AXDecrement`/`AXIncrement` repeated
   `linesPerPage` times — found by climbing from the hit element to the first ancestor that
   advertises one. It never aims at what the point touched: a row is not a scroller.

   **Several act tags in one reply are an ordered plan, not a choice between them.** "message Nitesh
   that good night in whatsapp" is search, open, type, send — and a card that could hold one of the
   four could do none of them. `offerProgram` runs `streamer.actionRequests` in order (capped at
   `ActionRequest.maxProgramSteps`), and each step travels the whole chain on its own: resolved
   against the *live* tree, refused by `PolicyGate`, and with asking on, asked about one at a time
   as "… (step 2 of 5)". A step that does not happen **stops the plan** and says how many steps did
   not run, because the steps after it were aimed at a screen the failed step would have changed;
   a "not now" drops the rest. Half a second between steps is what let a real chat window open
   before the type step looked for its field.

   `[TYPE:x,y:label|text]` is the same invariant with the cursor instead of the pointer, and it is
   the one act whose target is *not* a pressable control: `AXTDriver.typeTarget` looks for an
   `editableRoles` element at the point (walking ancestors), then by name, and — because Chromium
   and Electron publish an empty tree until an assistive client asks — writes `AXManualAccessibility`
   to the app element and retries once. That is why WhatsApp, Slack, VS Code and every browser tab
   can hold a field at all; without it the honest answer is "there is no text field there".
   **Keystrokes land wherever the cursor is, not where they were sent**, so `type` reads the app's
   own `kAXFocusedUIElementAttribute` and refuses to post a single character until the field the
   user approved *is* that element (`focusRefused`, and nothing goes anywhere). The verbs the Auto
   Typer script uses — one unicode `CGEvent` pair per character, no pointer warp — are the mechanism
   only; Chunks never presses Return, so a `[TYPE]` fills a field and cannot submit it. The text
   itself is part of the question (`Type "good night" into the message box in WhatsApp?`), the
   parsed payload is capped at `maxTypedCharacters`, and an over-long or malformed tag fails open
   into visible text rather than typing something the user never read.

   **Catalyst puts the field-ness in the subrole, not the role.** Measured 2026-10-08 on WhatsApp
   with its search box open and a caret blinking in it: the element is
   `role=AXStaticText subrole=AXSearchField`, advertising `AXPress`. A role-only editable check sees
   a label, which is why five consecutive fixes to "there is no text field there" — aim, name
   search, focus read-back, first-responder typing, sole-visible-field — were each correct and each
   useless. `isEditableField(role:subrole:)` accepts either half and refuses a secure field on
   either. The same app answers `AXFocusedUIElement` with `AXGroup/iOSContentGroup` the size of the
   window, so the exact-element focus test can never pass there; `focusedFieldMatches` is the
   escape, asking only the weaker question — does the app's focus answer name *a* field in this app.
   A gate nothing can satisfy protects nothing; it only refuses work the user already approved.

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

**The app runs. 360 tests green across 18 suites.**

Done and tested:

| Component | File | Notes |
|---|---|---|
| Coordinate authority | `Capture/CoordinateSpace.swift` | The only type allowed to convert coords |
| Screen capture | `Capture/CaptureEngine.swift` | `SCScreenshotManager.captureImage(in:)`; scale measured |
| Secret rejection | `Memory/SecretSweeper.swift` | 12 provider prefixes + entropy heuristic |
| Memory store | `Memory/MemoryStore.swift` | Plain markdown, 2 KB cap, never truncated |
| Memory write-back | `Memory/MemoryReport.swift` | `<MEMORY>` proposal → store → one-line footnote on the card |
| Reply protocol | `Brain/ResponseParser.swift` | Streaming `[POINT]` / `[ACT]` / `[TYPE]` / `[DO]` / `<SAY>` / `<MEMORY>` / `<NOTE>` / `<SUMMARY>` / `<DONE_TITLE>` / `<NEXT_ACTIONS>` |
| Provider registry | `Brain/ProviderRegistry.swift` | Capability profiles, `visionCapable: Bool?` |
| Retry + rate limit | `Brain/RetryPolicy.swift` | Backoff with jitter, token bucket |
| Request/SSE | `Brain/GeminiTransport.swift` | Pure builders; `store:false` enforced by test |
| Region resolution | `Annotate/RegionResolver.swift` | Marks → padded, clamped crop rect |
| Card sizing | `AnswerPanelLayout.swift` | One measurement for card height, mirrored by the view |
| Notch anchor | `NotchGeometry.swift` | Cutout from the auxiliary strips; menu-bar fallback; the only place that flips top-left ↔ AppKit for the HUD |
| Image → screen mapping | `Capture/ScreenshotGeometry.swift` | The sanctioned route from the model's 0–1000 aim grid to AppKit and AX point spaces; scale-independent by construction, and it keeps the mapped point inside the display |
| Act proposal | `Action/ActionRequest.swift` | Two verbs on purpose: `press`, and `type(text:)` for one field the user named |
| Policy rules | `Action/PolicyGate.swift` | Secure fields / Keychain / password managers refused even with asking off; unknown metadata fails toward *asking* |
| Consent state machine | `Action/ConsentGate.swift` | One outstanding question; double answers are inert; displacement counts as denial |
| Accessibility press | `Action/AXTDriver.swift` | Window hit test (layer 0, desktop on request) → `AXUIElementCopyElementAtPosition` → walk to a pressable ancestor → `AXPress`/`AXPick`/`AXOpen` (icons are selected first); name search when the pixel misses, then Finder's desktop list when that misses, and an app that answers badly is believed only from a before/after snapshot of what is running and focused. Typing goes through `typeTarget`/`type`: editable-role hit test and name search, `AXManualAccessibility` for Chromium surfaces, focus read back and compared before the first character, unicode `CGEvent` keystrokes that never warp the pointer. Never moves the cursor |
| Tool requests | `Action/DoRequest.swift` | `[DO:open_app:X]` / `[DO:open_url:host\|Chrome]` / `[DO:set_volume:N]`, parsed only into effects that fit one sentence; paths, non-http schemes and unknown tools return `nil` |
| Tool runner | `Action/ToolRunner.swift` | `NSWorkspace` launch from a fixed directory list; a URL handed to the named browser or the default one; CoreAudio output volume. Performs only what the gate released |

Running: menu bar item, ⌃⌥ **tap-to-arm** dictation (a tap arms the microphone and a second tap
sends it; holding past 350 ms still behaves as push-to-talk — `TalkArmer.swift`), ⌃⌥⌘C to open and
close the panel (`PanelShortcut.swift`, matched on the event tap's own `CGEventFlags`), whole-screen
turns, cursor move to a pointed-at control, an API-key field in the panel that writes to the Keychain,
and the **notch HUD** (`Sources/Chunks/HUD/`) — a non-activating card
that grows out of the cutout: streamed answer, `<DONE_TITLE>` as its label, point and
`<NEXT_ACTIONS>` chips, `<SUMMARY>` spoken on completion. Every prompt carries
`MemoryStore.injectedBlock()`, and a `<MEMORY>` proposal at the end of a reply is validated,
written, and reported as a footnote on that same card. The pill above the card carries both
voices: the recognizer's live partial transcript while ⌃⌥ is held, then a one-line hint
(`.status` phase) when nothing is in flight. First run is the cursor welcome plus that notch
hint — clicky's hosted HLS intro video, its background music and its email gate were all
deleted, so nothing in the app fetches or plays a remote asset. A `[ACT:…]` or a `[DO:…]` adds
one more row to that card: the question naming the control the hit test actually found, or the
one sentence of the tool's effect ("Open Notes?", "Set the volume to 40%?"), with **Allow** /
**Not now** buttons half the card's width and the line of what happened replacing it after an
answer. Both kinds go through the same single `ConsentGate`, so the card can never be mid-asking
two things at once. With the panel's **"Ask before acting" switch off** — the default — neither
kind is asked: the press or the tool runs straight away and only the line of what happened lands on
the card, spoken, because there is no question to answer.

**Not yet built** — the parts that need a human looking at them:

- The notch HUD's *card* has never been photographed on a real screen. Its geometry is
  unit-tested and the pill has been checked against the dev machine's cutout
  (185x33 pt at x=855), but the shape,
  the halo beside the notch and the chip hit targets need eyes.
- Voice out is `LocalTTSClient` (vendored). `SpeechTranscriber` (macOS 26+) for higher-fidelity
  dictation is not started; the current path is clicky's Apple-transcription push-to-talk.
- Computer use — the press path is built, and it has now **opened apps from live spoken turns and
  said so correctly**: `act: aim missed, answered by name — "Pluralsight icon" → AXImage/Pluralsight
  at (1644.0, 200.0)` → `act: AXOpen returned -25205 but the effect happened anyway` → `Pressed
  Pluralsight.` The press before that (O'Reilly) launched the app and was *reported* as a refusal,
  which is what the snapshot diff fixed. What has still never been produced is a press whose own
  return code said success — every desktop icon answers `-25205` — so the report is carried by
  `pressLanded`, not by the app. The failure mode left is *resolution*: the same turn that opened
  Pluralsight then aimed 360 pt away from "free claude code" and, because the desktop had dropped
  out of the window list once an app covered it, refused. `desktopTarget` closes that (verified
  read-only: `--probe-ax 1287.84,86.90 --named "free claude code"` → `AXImage/Free Claude Code in
  Finder at (1648.0, 73.0) verb=AXOpen`), and its press has not been watched yet. Probes found
  genuinely pressable controls (`1600,140` → Chrome's `AXPopUpButton "All Bookmarks"`), and points
  over Chrome's web content still resolve to an unnamed `AXGroup` that Chunks correctly refuses —
  web content is not published to Accessibility.
- Typing is built (`[TYPE:x,y:label|text]`) and its resolver has now been seen working on live
  hardware: `--probe-ax 510,306 --named "message box"` answered by *name* inside a Chromium surface
  — `AXTextArea/"Send task message" at (839.0, 969.0) answeredByName=true focusedNow=false`, with the
  card wording `Type … into Send task message?`. That `focusedNow=false` is the rule doing its job:
  the field was found and the keystrokes were still not allowed to go anywhere. What has not been
  watched is a real spoken turn that types — the model has to emit `[TYPE:…]` first, which the
  prompt only learned on 2026-10-05.
- The wrong-row bug the user reported (asked for "Nitesh GVP 2", Chunks pressed "Tech Eximus 2026")
  is fixed in `target(in:window:label:at:)`: a pixel that lands on a control whose published name
  does not answer the label loses to the name search, and the log says `act: aim names "…", asked
  for "…"`. It is unit-tested both ways and needs the same WhatsApp list on screen to be believed.
- The tool layer is built and **both effects have now run on the real machine** from spoken
  turns: `tool: asking — Open Music?` → `tool: Opened Music.`, and `Set the volume to 0%?` →
  `Volume set to 0%.` (log, 2026-10-04). The volume write is additionally covered by a **no-op
  write** test that reads the device's own percent, writes it back and asserts it is unchanged.
  The failure mode seen instead is *selection*: asked to open a screenshot lying on the desktop,
  the model emitted `[DO:open_app:Music]` — the tool block reads as the answer to any "open X",
  so the prompt now says out loud that a thing visible on screen is an `[ACT]`, and `open_app` is
  only for what the screen does not show.
- Not built, on purpose, for now: a `timer` tool (plan §Phase 6 owns reminders, and building it
  twice is worse than waiting) and a `Focus` tool (it needs a Shortcut the *user* owns and names,
  which is a settings surface that does not exist yet).
- Scrolling is built (`[SCROLL:x,y:label|down]`) and goes through the scroller's own Accessibility
  verbs — a synthetic wheel event was measured to move the pointer, so that route is closed. What
  has not been watched is a real spoken turn that scrolls, and whether `AXScrollDownByPage` on the
  element WhatsApp hands back actually moves the list rather than selecting a row.
- Plans are built (several act tags, run in order, stopping at the first step that does not
  happen). What has not been watched is a plan surviving contact with a live app: every step is
  re-resolved against the tree as it is *then*, and the step whose label described a control that
  only exists after the previous step is the one likely to fail first.
- Chunks drawing on the screen (HeyClicky's circles and arrows as an *output*) is not built.
  **And the surface this used to call the short path no longer exists:** the interactive
  `AnnotationOverlayWindow` was deleted with the clicky vendoring (`10bd07e`), so
  *circle-to-explain is currently dead* — `AnnotationShape`, `RegionResolver` and
  `CaptureEngine.composited(with:shapes:)` all survive and stay tested, but nothing in the shell
  produces a shape, and the only caller passes `[]`. Output drawing therefore needs a surface
  rebuilt first; it is not a reuse job. It still needs no consent, because it moves and presses
  nothing.
- `<NOTE>` offers never reach the live pipeline: `AnswerStreamer` collects the offer, nothing
  consumes it yet. There is no Notebook to save into.

**Adding a test suite:** write the cases in `Tests/ChunksTestCases/`, then add
`YourTests.register()` to `AllTests.swift`. `runAllChunksTests()` returns whether the
suite passed.

**Test style:** `test("a sentence describing the behaviour") { ... }`, with `expect`
carrying a message that explains *why* it matters. A failing assertion should tell the
next person what user-visible bug they are looking at, not what condition was false.
Tests that touch the real machine (screen capture, display enumeration) assert against
real hardware deliberately — a mock would have agreed with the `CGDisplayPixelsWide` bug.

See `CHUNKS-BUILD-PLAN.md` for the full phased plan, and `context.md` for the running notes.
