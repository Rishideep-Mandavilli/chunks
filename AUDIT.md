# Chunks — whole-product error audit (2026-11-08)

**Purpose.** A fix-nothing, harsh audit of every capability so any successor agent can pick this up
cold and repair it. Each finding says *what* breaks for the user, *why* (root cause with file:line),
the *evidence*, and a one-line *fix direction*. Nothing here has been fixed.

**How to read.**
- Severity: **P0** = safety/consent bypass, wrong-target act, secret leak, data loss, crash/hang.
  **P1** = capability silently dead, unreachable control, or a lying report/state.
  **P2** = edge-case wrong behaviour, latency, contrast/hit-target. **P3** = polish/docs.
- Verification: **[V]** = re-checked against the code by the consolidating agent after the slice
  audit reported it. **[A]** = slice-audit evidence only (code read, probe output or viewed render);
  re-verify before fixing. **[S]** = suspected, not proven.
- **KNOWN-OPEN** = already documented in AGENTS.md/TASKS.md as open or parked; listed so it is not
  rediscovered as new, not because it is acceptable.
- IDs are stable: A=act/consent, B=brain/protocol, C=shell/crash, D=disk/schedules, E=surfaces,
  F=gate/tests/docs. Fix in ID order within a severity, not slice order.

**Standing rules for whoever fixes these** (from AGENTS.md, still in force): build only via
`./scripts/make-app.sh && ./scripts/install.sh`; run `./scripts/verify.sh` before calling anything
done; never `git reset --hard`/`checkout --`/`stash`/`clean`; ask before committing; nonce every
measurement (tool output in this repo has contained fabricated green runs); a check that did not run
must not report as passed; probes must not write his settings.

---

## E — Rendered surfaces, layout math, states, accessibility

Slice audit executed all five render probes and viewed all five PNGs; the consolidating agent
re-read the cited code for every P1 and for E-06/E-07.

- **E-01 | P1 | Unbounded speech fallback can clip the card [V]**
  what: a reply with no parsed speech/detail falls back to the raw utterance with no character
  budget; the card clamps at 420 pt and the tail vanishes below the window edge.
  why: `Sources/Chunks/HUD/NotchHUDModel.swift:458-461` assigns `speech = utterance` directly, while
  every other speech path bounds it (`:434`, `:502`, `:643`); `AnswerPanelLayout.swift:321` clamps and
  `NotchPanelManager.swift:174` sizes the window from the clamped value.
  evidence: code-confirmed; the render fixtures call `model.apply`, never `hud.finish`
  (`UIRenderProbe.swift:748`), so no green check covers this path.
  fix: bound the fallback with `boundedDetail(…, budget: speechCharacterBudget)`.

- **E-02 | P1 | fail() message unbounded — the retry row can become unreachable [V]**
  what: a long server/model failure text overflows the 420 pt clamp and can push the "Ask again" row
  out of the window — the one way back from a dead turn becomes unclickable.
  why: `NotchHUDModel.swift:484` `speech = message` with no budget; the retry row is charged in
  `AnswerPanelLayout.measure` under `hasRetry` but sits below the unbounded body.
  evidence: code-confirmed; the probe's fail fixture is 62 chars (`UIRenderProbe.swift:865`).
  fix: bound at `speechCharacterBudget`; add a long-failure fixture to `--render-ui`.

- **E-03 | P1 | Pill says "Doing it" forever after a multi-act turn finishes [V]**
  what: after the last act's outcome line the status pill still claims work is in flight.
  why: `reportConfirm` sets `stage = .acting` (`NotchHUDModel.swift:648`); the only `.answered`
  assignments are `:467` (stream end, before acts report) and `:505` (reminders). Nothing marks the
  turn answered once acts finish.
  evidence: exhaustive grep of `stage =` assignments; pill not rendered by any probe.
  fix: set `.answered` + `stopClock()` when the plan's last act reports.

- **E-04 | P1 | Two safety switches announce themselves as "Open Chunks at login" to VoiceOver [V]**
  what: a screen-reader user toggling "Ask before acting" or "Think on this Mac" is told it is the
  login item — the safety gate is mislabelled to the one user who cannot see it.
  why: `Sources/Chunks/Clicky/CompanionPanelView.swift:726` and `:1302` carry a copy-pasted
  `.accessibilityLabel("Open Chunks at login")`; only `:794` (the real login toggle) is correct.
  evidence: code-confirmed; VoiceOver not run (needs a GUI session).
  fix: per-toggle labels.

- **E-05 | P2 | Turn timer freezes at stream end, not answer end [V]**
  what: on act-bearing turns the elapsed seconds understate the real wait.
  why: `NotchHUDModel.swift:466-469` stops the clock when `actLines.isEmpty || stage == .streaming`,
  which is exactly true at stream end before acts report; `beginStep` never restarts it. The comment
  above it states the opposite intent.
  fix: keep the clock running until `.answered`.

- **E-06 | P2 | Caption rebuilds its hosting view every sentence [V]**
  what: flicker risk on the one surface whose doc promises no flicker.
  why: `Sources/Chunks/HUD/CaptionPanelManager.swift:43` assigns a fresh `NSHostingView` on every
  `show()`; only the panel is reused, contradicting its own comment at `:21-23`.
  fix: build the hosting view once in `ensurePanel`; update `model.text` only.

- **E-07 | P2 | Bright accent link on sea fails 4.5:1 at label size [V]**
  what: the reminder "Arm" and routine "Save" links use the bright accent on a field colour.
  why: `CompanionPanelView.swift:1183` and `:1245` use `C.accentText`; the file's own comment
  (`:76-77`) measures it 4.24:1 on sea and calls that a fail at 11 pt; `C.linkOnField` exists and is
  used correctly at `:878/:926/:988/:1007`. The contrast suite has no accent-on-sea pair.
  fix: swap both to `C.linkOnField`; add the pair to `Palette.graphicPairs`.

- **E-08 | P2 | Follow-up chips are 22 pt tall [A]**
  why: `chipCard` frame `chipHeight - 4` = 22 pt (`NotchHUDView.swift:418`,
  `AnswerPanelLayout.swift:91`); they are Buttons (`:388`). Below the macOS control norm.
  fix: full-height capsule as the hit area.

- **E-09 | P2 | Permission Grant/Restart pills ~16-18 pt tall [A]**
  why: `panelPill` = 10 pt micro text + 3 pt vertical padding (`CompanionPanelView.swift:617-620`) —
  the only route to re-grant a revoked permission.
  fix: ≥24 pt content height or a row-wide hit shape.

- **E-10 | P2 | Setting rows: only the mini-switch is clickable [A]**
  why: `labelsHidden` + separate `Text` + `.controlSize(.small)`
  (`CompanionPanelView.swift:722-731`, `790-797`, `1298-1306`); the 44 pt-looking row is not tappable.
  fix: wrap the row in the toggle's label or add a row-wide contentShape action.

- **E-11 | P2 | Waveform rest rail ~1.3:1 against the card — invisible [A]**
  why: 1 pt `lineStrong` (#c9c5ba) on ground (#f5f4f0) (`NotchHUDView.swift:560-564, 596-598`);
  `lineStrong on ground` is absent from `Palette.graphicPairs` (`Palette.swift:80-88`) so the suite
  never checks it. Viewed in the card render, state 6: barely discernible.
  fix: use `lineControl` for the rail, or add the pair and darken it.

- **E-12 | P2 | --render-window / --render-panel assert nothing but "file written" [A]**
  why: `UIRenderProbe.swift:548-553, 627-632` exit 0 after the PNG write — no layout, tap or content
  checks; the exact "plausible byte count" lie the caption probe documents at `:58`.
  fix: port the `--render-ui` real-rect assertion recipe to both.

- **E-13 | P3 | Hard-coded easeOut on the card violates the motion tokens [A]**
  why: `NotchHUDView.swift:228-229` `.easeOut(duration: 0.15)` twice; DESIGN.md mandates `DS.Motion`
  springs and bans ease-out on moves.
  fix: use the token spring, or record the exception in DESIGN.md.

- **E-14 | P3 | Stale dark-palette header comments on light surfaces [A]**
  why: `DesignSystem.swift:5` "blue accent palette on dark surfaces"; `CompanionPanelView.swift:7`
  "Loom's recording panel — dark". Both surfaces are warm paper (verified in renders).
  fix: correct the comments.

- **E-15 | P3 | Palette doc cites hexes that differ from its own tokens [A]**
  why: `Palette.swift:99-101` claims sea #B3E5DB / sky #A7BCFA / sand #FAE1AF / ink #1A1A1A; tokens at
  `:108-114` are #C7EDE7 / #A2C0FD / #FAEBD1 / #16181C.
  fix: regenerate the comment from the tokens.

- **E-16 | P3 | KNOWN-OPEN: notch card never photographed on a real screen [A]**
  why: renders are the only eyes; real-display compositing, halo and hit targets unverified
  (AGENTS.md "Not yet built").
  fix: his screen, once; not a code change.

- **E-17 | P3 | Window live strip ignores the acting phase [A]**
  why: `isTurnInFlight` covers listening/thinking only; while the notch says "Doing it" the window
  shows no in-flight strip — the two surfaces disagree mid-turn.
  fix: include `.acting` in the window's in-flight predicate.

**Clean in this slice (attacked, survived):** asking-order reposition correct in pixels; max draft +
confirmation fits with Allow/Copy inside real rects; caption contract measured live
(prevents-activation / ignoresMouseEvents / canBecomeKey / app-active all correct); caption cuts at
word boundaries; traffic-light clearance present; window empty states render; setup render non-blank;
sitting-line contrast legal; 847/847 tests pass.
**Untested:** VoiceOver announcements; real-display notch compositing; overlay/cursor surfaces (other
slice); Allow-click focus behaviour with another app frontmost; runtime caption flicker.

---

## A — Act & consent chain

Slice audit read all twelve ChunksKit Action files whole plus the shell's act doors, and ran the
read-only probes (keys, voice-answer, windows, open, semantic). The consolidating agent re-read the
cited code for A-01…A-04, A-06 and A-08.

- **A-01 | P0 | A displaced plan's remaining steps run when a later, unrelated card is allowed [V]**
  what: a new card replaces an unanswered plan card; ConsentGate counts the old question denied, but
  the old plan's remaining steps survive in `pendingProgram`. Answering the *new* card then executes
  the old, denied plan — with asking off (the default) each revived step runs silently.
  why: `pendingProgram` is only ever cleared inside `answerAct`
  (`CompanionManager.swift:2483, 2507, 2519, 2536`); `askPolicyAndCard` and `offerTool` clear the gate
  and `pendingPress` but not the program. The press branch (`:2519-2528`) and tool branch
  (`:2536, 2570-2577`) then run `program.steps` after the new act.
  evidence: whole-file read; grep of every `pendingProgram =` site confirms no displacement clear.
  fix: clear `pendingProgram` wherever a question is displaced or withdrawn.

- **A-02 | P1 | run_command's deny list is escapable via `osascript` and `open` [V]**
  what: an approved "Run osascript -e …?" card buys System Events keystrokes/clicks — bypassing
  KeyAction's outright refusals (⌘Q, ⌘⌥Esc), the asking-switch gate on `[DO:key:]`, and
  `do shell script` re-opens the network programs the deny list exists to block; `open ~/.ssh/id_rsa`
  bypasses the credential refusals that reveal/open_file_with enforce.
  why: `DoRequest.swift:524-530` `deniedPrograms` contains neither `osascript` nor `open`; parse only
  rejects metacharacters and paths (`:579-582`), and `osascript -e …` needs neither.
  evidence: exact lines; still requires his Allow (run_command is always-asked), so P1 not P0.
  fix: add `osascript`, `open` and similar meta-programs to `deniedPrograms`.

- **A-03 | P1 | quit_app discards the resolved window's process and quits the first name match [V]**
  what: the card names a resolved window/process, but execution terminates whichever running
  application matches the name first — a helper can die (or be attempted) while the named app stays
  open, and the outcome line still reports the quit.
  why: `resolvedWindowAct` resolves a candidate (`CompanionManager.swift:3167-3183`) but returns
  `.quitApp(name:)`; `ToolRunner.swift:43` and `:276-277` map quit to `WindowDriver.quit(appNamed:)`,
  which takes `runningApplications.first(where: matchesAppName)` with no activation-policy filter.
  fix: carry the candidate's pid through to execution and terminate that process.

- **A-04 | P1 | open_url with an unresolvable named browser silently uses the default and reports "in Chrome" [V]**
  what: the card says Chrome; the machine's default browser opens; the outcome line claims Chrome.
  why: `ToolRunner.swift:344-358` — when `resolveApplicationPath` fails for the named browser it falls
  through to `NSWorkspace.shared.open(target)` and returns true; the comment at `:338-339` states the
  opposite intent; `DoRequest.outcomeLine` prints the named browser regardless.
  fix: refuse, or re-word the outcome, when the named browser did not resolve.

- **A-05 | P2 | type()'s viaFirstResponder branch reports .typed with no witness [A]**
  what: characters are posted and `.typed` returned without any read-back, while the ordinary path
  re-checks focus; if UIKit's first responder is not the approved field the card claims the words
  landed.
  why: `AXTDriver.swift:2260-2263`.
  fix: add a value witness where the app answers one; say "posted, unverified" where it cannot.

- **A-06 | P1 (agent rated P2; upgraded) | The focusedFieldMatches escape hatch is unreachable [V]**
  what: named typing into apps that cannot name their own cursor (WhatsApp/Catalyst — the motivating
  case) can never pass: the hatch admits it at the first guard and the second guard refuses it.
  why: `AXTDriver.swift:2268-2269` passes on `focusedFieldMatches(target)`, then `:2274` requires
  `hasFocus(target.element)` — exactly the test that was already false. A gate nothing can satisfy
  protects nothing; it only refuses approved work.
  fix: when the hatch is what passed, skip or replace the strict re-check with the weaker witness.

- **A-07 | P2 | keys() posts to the global tap with no frontmost re-check at post time [A]**
  what: focus moving between the ≤2 s frontmost poll and the posted events lands an asked-for ⌘-combo
  in whatever is front.
  why: `ToolRunner.runKey` polls frontmost (`ToolRunner.swift:166-196`); `AXTDriver.keys` re-reads
  focus but posts to `.cghidEventTap` (`AXTDriver.swift:2834-2866`) with no ownership check at post.
  fix: re-verify frontmost immediately before the first posted event.

- **A-08 | P2 | Always-ask Send/Submit/Pay detection runs on a label truncated to 42 characters [V]**
  what: a control whose published title puts the commitment word past char 42 escapes the
  even-with-asking-off card, and the card text hides the word.
  why: `AXTDriver.swift:33, 49-56` truncates `elementLabel` at `labelCharacterBudget = 42`;
  `PolicyGate.swift:126` matches consequence words on that truncated label.
  fix: run `isConsequential` on the full title/description; truncate only for display.

- **A-09 | P2 | Scroll reports the requested pages, not the completed ones [A]**
  why: `AXTDriver.scroll` returns `.scrolled(pages:)` from the request even when steps stopped early
  (`AXTDriver.swift:2756-2774`); the shell prints it verbatim (`CompanionManager.swift:2721-2724`).
  fix: report the completed-step count.

- **A-10 | P2 | Card-approved acts run in untracked Tasks with no epoch guard [A]**
  what: answering a card then speaking a new request lets the old plan's steps and the new turn's acts
  interleave in an order nobody approved.
  why: `answerAct` spawns `Task { runAct … offerProgram }` (`CompanionManager.swift:2520-2528`,
  `:2571-2577`) with no `turnEpoch` check and no cancellation by `currentResponseTask`.
  fix: track the answered-card task and epoch-check before each subsequent step.

- **A-11 | P2 | KNOWN-OPEN: name-search budget exhaustion reads as "no such control" [A]**
  why: the 220/700-element budgets end in the same refusal as a genuinely absent name, with no note
  that reading stopped early; Chrome's candidate sweep collects 0 inside the window veto
  (AGENTS.md Tier 3.1).
  fix: distinguish "searched N and stopped" from "searched all and absent".

- **A-12 | P3 | `shift+command` parses as a raw Command-key tap [A]**
  why: `KeyAction.swift:210-228` refuses a bare modifier only as the sole part; `keyCodes["command"]`
  exists (`:57`), so a modifier in the key position posts the modifier key itself, classified routine.
  fix: refuse when the final part is also a modifier name.

- **A-13 | P3 | KNOWN-OPEN: a press is still never confirmed by its own return code [A]**
  why: `pressLanded`/`waitForLanding` (`AXTDriver.swift:640-715`) reclassify ambiguous failures by
  snapshot diff; every desktop icon answers -25205. Documented open in AGENTS.md.

- **A-14 | P2 | The pointer-click exception warps and clicks with no live owner re-check [A]**
  what: the documented web-caret click exception (`CompanionManager.swift:2745-2755` →
  `AXTDriver.click(at:)`, `:2377-2391`) clicks the approved *point*; if a window moved since the card,
  the click lands in another app and the outcome names neither.
  fix: re-hit-test at click time and name what now occupies the point in the outcome line.

- **A-15 | P3 | continuationBehindTool leaks across a held-launch answer [A]**
  why: the `heldBehindLaunch` branch of `answerAct` returns before clearing `continuationBehindTool`
  (`CompanionManager.swift:2546-2568`); the stale sentence survives until his next utterance
  (`:3731-3732`). Narrow window: an exact voice-answer phrase between turns.
  fix: clear both slots at the top of the .tool answer branch.

**Clean in this slice (executed):** 847/847 tests; `--probe-keys` classes and modifier bits correct;
`--probe-voice-answer` 13/13 with no spoken route to always-allow; `--probe-windows` close/quit always
ask and ambiguity resolved before the card; `--probe-open` refusal-before-card holds; PolicyGate
ordering (forbidden → consequential → inferredAim → switch) and the key-switch enforcement at both
doors hold.
**Untested:** live spoken end-to-end turns, real keystroke posting, the A-01/A-10 timing races,
Chrome page-depth sweep — all need his screen (AGENTS.md Tier 1).

---

## B — Brain, transports, retry/latency, reply protocol, prompt

Slice audit read the seven brain files whole and ran build + suite + `--probe-prompt` (nonced).
Consolidating agent re-read the cited code for B-01, B-02, B-03, B-05 and B-07.

- **B-01 | P1 | Backup-key retry is dead after the first minute of app life [V]**
  what: a free-tier 429 never earns the promised second key on a long-running menu-bar app; the user
  gets the quota failure instead.
  why: `Sources/Chunks/BrainGateway.swift:202` `private let backupRetryStarted = Date()` is stamped at
  gateway **init**; `:191` gates the retry on `timeIntervalSince(backupRetryStarted) < 60`;
  `CompanionManager.swift:73` holds one gateway for the app's lifetime.
  fix: stamp the start-of-turn date per call.

- **B-02 | P1 | Cloud stream throws away SSE `.error` events — an API error inside a 200 reads as success [V]**
  what: an in-stream Gemini error (quota, safety) yields an empty reply or a silently truncated one,
  logged as served, with no failover and no backup key.
  why: `BrainGateway.swift:923-928` forwards only `.textDelta`; `.error` (emitted by
  `GeminiTransport.swift:213-216`) is dropped. The local loop handles the same event properly
  (`:620-636`).
  fix: capture `.error` like the local loop and surface/retry it.

- **B-03 | P1 | Two models can write one card when a hop fails mid-stream [V]**
  what: model A streams half an answer, the connection drops, model B appends to the same streamer —
  one garbled card, one utterance from two voices, and both models' act tags run as one plan.
  why: one `AnswerStreamer` per turn (`CompanionManager.swift:3862`) fed by every attempt;
  `BrainGateway.swift:916-922` fences only the *deadline* cut (`accumulated.isEmpty`) — its own comment
  describes this exact hazard — while error-driven failover (`:450-455`) and the backup-key re-walk
  keep pushing into it.
  fix: reset or fence the streamer at each new attempt.

- **B-04 | P2 | A first-hop auth failure shows the user "…HedgedFailure error 1." [A]**
  why: `BrainGateway.swift:831` throws `HedgedFailure`, `:457` rethrows it raw; `Log.swift:41-47`
  matches only `BrainError`/`ChunksError`, so it falls to `localizedDescription`; `worthBackupRetry`
  also silently becomes false.
  fix: unwrap `HedgedFailure.underlying` before it escapes the chain loop.

- **B-05 | P2 | Closed `<CONTINUE]…]` is not consumed — markup on the card and possibly spoken [V]**
  what: the angle-open/bracket-close hybrid, when *closed*, leaks as prose and arms nothing; via the
  `utterance` detail fallback it can be read aloud. (This is a gap in the 2026-11-08 continuation fix:
  the unclosed tail is caught, the closed form is not.)
  why: `ResponseParser.swift:238-246` has `<CONTINUE>`, `[CONTINUE>`, `[CONTINUE]` but no `<CONTINUE]`;
  `AnswerStreamer.swift:159-169` and `ReplyAudit.swift:225` claim all four shapes.
  fix: add the fourth construct (`start: "<CONTINUE]", end: "]"`) and a unit case.

- **B-06 | P2 | The local path ignores the turn budget [A]**
  what: an offline turn can hold the user 75 s per model × N models; the 60 s ceiling is Gemini-only,
  and the shell watchdog never kills the parked call.
  why: `BrainGateway.swift:579` `request.timeoutInterval = 75`; the local stream loop (`:611-626`) has
  no deadline check unlike `:922`; watchdog fires only while `phase == .thinking`
  (`CompanionManager.swift:3654`).
  fix: thread the same deadline into the local loop.

- **B-07 | P2 | Unsynchronized mutable dictionaries on a non-isolated class [V]**
  what: rate buckets and thinking-rejection memory can race when a scheduled turn overlaps a hedged
  voice turn — lost updates or a Dictionary/Set crash.
  why: `BrainGateway.swift:94` is a plain `final class`; `rateLimiters` (`:115`) and `thinkingRejected`
  (`:127`) are mutated from hedge group tasks (`:779-784`) and the race loop (`:813, :819`) with no
  lock, unlike `StreamClaim` (`:690`).
  fix: serialize with a lock or move the state into an actor.

- **B-08 | P3 | RetryPolicy's doc contradicts its own 429 decision [A]**
  why: `RetryPolicy.swift:50-52` says retry the same model; `decide` (`:127-132`) falls back to the
  next model (correct per invariant 6). Stale comment that will mislead the next editor.
  fix: delete the sentence.

- **B-09 | P3 | Hedge partner serves, log credits the lead [A]**
  why: `BrainGateway.swift:377` logs "served by \(candidate.id)" even when `hedged` returned the
  partner's text (`:796-802`).
  fix: propagate the serving model out of `hedged`.

- **B-10 | P3 | AGENTS.md invariant 5 teaches a runtime capability probe that does not exist [A]**
  why: every Gemini entry hardcodes `visionCapable: true` (`ProviderRegistry.swift:138-147`); nothing
  probes capability at runtime.
  fix: amend the invariant to describe the static table.

- **B-11 | P3 | A second coordinate authority survives in the request builder [A]**
  why: `GeminiTransport.swift:81-91` `systemInstruction` teaches "[POINT:x,y] … PIXELS", contradicting
  the production 0–1000 grid; live paths pass the caller's prompt, so it bites only the builder and
  the tests that assert pixels (`GeminiTransportTests.swift:132`).
  fix: unify or delete the builder's instruction.

- **B-12 | P3 | Fail-open detail can be spoken raw [A]**
  why: `AnswerStreamer.swift:87-92` falls back to `detail`, which by design carries fail-opened markup
  for malformed constructs, so `utterance` may read tag debris aloud.
  fix: strip angle/bracket debris from the spoken fallback.

- **B-13 | P3 | Dead TurnRequest built and ignored in stream() [A]**
  why: `BrainGateway.swift:868-872` constructs a request, sets `imagePixelSize = nil`, never uses it.
  fix: remove.

**Clean in this slice (executed):** `store:false` on every Gemini body; key only via header; cloud
request/session timeouts agree at 20 s; attemptSlice/budget math matches the documented promise and a
spent budget is never re-handed; fast/slow 503 and network decisions per invariant 6; thinking-level
400 → one field-dropped retry with a per-model cache; history replay session-scoped; hedge loser
chunk-gated and cancelled, partner not re-dispatched; every taught `[DO:]` verb parses; the three
consumed CONTINUE shapes asserted by tests.
**Untested (needs a live model or a fake SSE server):** real in-stream `.error` payload, mid-stream
drop interleaving, hedge attribution under load, the 429→backup-key sequence.

---

## F — Gate, harness, probes, build/signing, doc drift

Slice audit read the scripts, harness and entitlements whole and ran nonced probes; verify.sh itself
was not run by the slice (forbidden), so gate behaviour is from code plus targeted probe execution.
Consolidating agent re-checked F-01/F-02/F-03/F-15 against code and live probe exits.

- **F-01 | P0 | The gate's hit-test check cannot fail [V]**
  what: "hit test: a point resolves to a control" counts a *refusal* as PASS.
  why: `AXProbe.run(at:)` exits 0 on "the card would refuse" as well as on a resolution; verify.sh's
  `check` passes on exit 0 + non-empty stdout (`scripts/verify.sh:35-51, 96-97`).
  evidence: slice measured `--probe-ax 900,120` → "the card would refuse …" with exit 0; consolidating
  agent's own run at the same point resolved a control (frontmost-dependent), and a notch point gave
  exit 3 — so the pass/fail signal tracks the desktop, not the code.
  fix: require stdout to name a resolved pressable control, else FAIL.

- **F-02 | P1 (slice rated P0; calibrated) | "Probes are inert in release" is false of the shipping artifact [V]**
  what: the documented build command produces a **debug** bundle, so every probe door is live in the
  app he actually runs and would share, without `CHUNKS_DEV`.
  why: `scripts/make-app.sh:7` `CONFIG="${1:-debug}"`; `AXProbe.swift:27-31` `#if DEBUG return true`.
  AGENTS.md's inertness claim is true only of a release build nobody builds by default.
  evidence: slice ran the installed bundle's probe with the env unset and it executed; fingerprint
  matches current source. Probes are read-only by design, hence P1 not P0 — but `--probe-command`
  does spawn programs.
  fix: default make-app to release, or add a gate check that a release probe refuses without the env,
  and correct the doc.

- **F-03 | P1 | The refusal-passes class extends to semantic, fields, voice and crop checks [V]**
  what: `--probe-semantic`, `--probe-fields`, `--probe-voice`, `--probe-crop` all exit 0 on refusals and
  zero results, so their gate lines pass while resolving nothing.
  why: `AXProbe.swift:59, 184, 225, 435` unconditional `exit(0)`; verify.sh:113, 172 count exit 0.
  evidence: slice measured `--probe-semantic 'app=NoSuchApp name="x"'` → exit 0.
  fix: exit non-zero when nothing resolved and the check's name asserts resolution.

- **F-04 | P1 | smoke.sh does not arm the work it claims to test [A]**
  what: its header promises "arms a reminder and a routine so the scheduler has work to do"; the code
  only checks a folder exists, so the 75 s tick wait exercises whatever he happens to have scheduled.
  why: `scripts/smoke.sh:8` vs `:56-62`; no schedule write anywhere.
  fix: arm fixtures, or correct the header.

- **F-05 | P1 | Three contradictory test/gate baselines in tracked docs [A]**
  what: AGENTS.md says 847/47 suites/55 checks (correct today); TASKS.md header says 767/42/42+1 and
  §3.18 says 818/48.
  evidence: slice measured 847/847 and 47 `.register()` calls.
  fix: one generated count line, referenced everywhere.

- **F-06 | P1 | TASKS Tier 4.1 lists closed work as open [A]**
  what: "plist promises LSMinimumSystemVersion 14.2" and "there is no entitlements file at all today"
  are both false of the shipped bundle (15.2; microphone-only entitlements file exists).
  fix: re-mark those bullets done.

- **F-07 | P2 | The unit-suite gate check has no size floor [A]**
  what: `0/0 passed` would PASS the gate if nothing registered.
  why: `TestHarness.swift:130-133` returns true on an empty registry; verify.sh:81-91 greps the shape
  only.
  fix: assert passed ≥ a floor.

- **F-08 | P2 | Harness headline arithmetic lies on failure [A]**
  what: "N/M passed" subtracts unique failing assertion *sites*, not failing tests.
  why: `TestHarness.swift:130-133` dedupes by file:line. Exit code is sound; the number AGENTS treats
  as suite health drifts.
  fix: count per-test outcomes.

- **F-09 | P2 | The assumeIsolated watchdog has a 4-line blind spot [A]**
  what: a timer/observer callback longer than four lines escapes the grep that guards the 22:02 crash
  class; an empty `find` also passes silently.
  why: `scripts/verify.sh:613-621` awk window of 4 lines.
  evidence: slice piped a 7-line synthetic closure with the assertion on line 6 through the identical
  awk → miss.
  fix: brace-depth or function-scope tracking.

- **F-10 | P2 | The probe UserDefaults guard misses indirect writes [A]**
  what: a probe calling a computed settings setter reproduces the 2026-11-02 "probe switched his
  brain" regression while the grep stays green.
  why: verify.sh:633 greps direct `UserDefaults.standard.set|removeObject` in probe files only; real
  writes live behind setters in ChunksCore/CompanionManager.
  fix: ban the setter calls in probe files too.

- **F-11 | P2 | The AXTDriver main-thread grep covers one file [A]**
  what: a new shell file calling AXTDriver synchronously passes the gate.
  why: verify.sh:515-518 watches only `Clicky/CompanionManager.swift`; latent today (only probes and
  CompanionManager call it).
  fix: grep Sources/Chunks minus `*Probe*`.

- **F-12 | P2 | The overlay contract is half-satisfiable by comments [A]**
  what: deleting the real `_setPreventsActivation` call leaves a comment containing the string, and
  the check still passes.
  why: verify.sh:559 greps without stripping comment lines (the NSApp.activate half at :560 does).
  fix: strip comments in both halves.

- **F-13 | P2 | No check ever exercises release inertness [A]**
  what: the flagship sharing-safety property is never tested in its denied state.
  why: verify.sh:24 exports `CHUNKS_DEV=1` for the whole run; zero unset-and-refuse checks.
  fix: one check running a release probe without the env and requiring refusal.

- **F-14 | P3 | "Read-only probes" overstates: they touch machine state [A]**
  what: probes write the live app log, `--probe-mic` opens the microphone, `--probe-command` spawns
  `caffeinate -u -t 5`, `--probe-local` boots Gemma on every gate run.
  fix: document the footprints in one table.

- **F-15 | P3 | Fixed-coordinate fixtures make the tally display-dependent [V]**
  what: `--probe-ax 900,120` hardcodes a point on this display; elsewhere it passes by refusal or
  skips, so "54 pass 1 skip" silently changes meaning on another machine.
  evidence: consolidating agent measured exit 3 at 855,15 and a resolution at 900,120 minutes apart.
  fix: derive points from live window enumeration, as the geometry check already does.

- **F-16 | P3 | The signing chain fails late [A]**
  what: an ad-hoc-signed app is installable; only the gate's per-arch check catches it.
  why: make-app.sh:125-127 downgrades seal failure to a warning; install.sh:47-67 installs anyway.
  fix: refuse install on persistent seal failure.

- **F-17 | P3 | smoke.sh inherits refusal-passes and a flush blind spot [A]**
  why: `run_probe` (smoke.sh:82-97) marks any exit 0 "ok" without reading output; the settings-hash
  delta compares a plist md5 that cfprefsd may not have flushed.
  fix: grep expected verdict words; use `defaults read`.

- **F-18 | P3 | asyncTest can deadlock the suite, latently [A]**
  why: `TestHarness.swift:165-173` blocks the main thread on a semaphore while spawning an
  unstructured Task; an async body that awaits MainActor hangs forever, no timeout. Only one
  asyncTest exists today and it does not hop.
  fix: drain off the waiting thread, or add a watchdog.

**Clean in this slice (executed):** 847/847 with correct exit wiring; 47 registers; fingerprint gate
fail-closed and matching; signing real (runtime flag, Chunks Local authority, universal, minos 15.2,
microphone-only entitlements); the reply-audit assertion-count guard genuinely failable; the
open-file check asserts five distinct refusals; geometry derives its window live; tokens match
DESIGN.md; no `expect(true` anywhere.
**Untested:** verify.sh end-to-end on a locked/display-asleep machine; per-machine tallies.

---

## D — Everything on disk, and everything scheduled

Slice audit ran the memory/notebook/read/find/remind probes (nonced) and the suite; two findings rest
on executed probe output against his real files. Consolidating agent re-read the cited code for
D-01…D-04 and D-06. Severities mapped from the slice's S2/S3/S4 onto this document's P scale.

- **D-01 | P0 | Hand-typed lines without the app's date stamp are silently destroyed [V]**
  what: he adds `- buy milk` to memory.md or notebook.md (the headers invite hand-editing); the next
  model memory-write saves the file without his line. No report.
  why: `MemoryStore.swift:416-417` parse regex requires the `(YYYY-MM-DD)` suffix; `load()` (`:406-410`)
  replaces facts from parse only and `save()` (`:400`) renders from facts; the comment at `:403-405`
  claims hand edits survive — false for undated lines. Same in `NotebookStore.parse` (`:324-343`).
  `adopt()` (`:362`), the function meant to handle hand lines with trust, has **zero call sites**.
  evidence: code + test-coverage inspection (`MemoryStoreTests:120` only round-trips app-format lines).
  fix: preserve unparsed `- ` lines verbatim through render(), or refuse-and-report before a save
  that would drop them; wire or retire `adopt()`.

- **D-02 | P0 | All-lowercase-hex credentials pass the sweeper into plaintext memory.md [V]**
  what: a 32–64-char lowercase-hex secret (Discord client_secret, Slack signing secret, webhook
  secret, session token) is remembered in plain text forever.
  why: `SecretSweeper.swift:91-97` `looksRandom` requires upper AND lower AND digit; lowercase hex has
  no uppercase, so the entropy hit at `:66-73` is discarded. The suite codifies the miss
  (`SecretSweeperTests.swift:55`), while the sweeper's own doc (`:87-90`) says the bias is toward
  rejection.
  fix: add a hex-run rule (long run of hex with digits, no dictionary words) to `looksRandom`.

- **D-03 | P0 | Credential-bearing files inside allowed roots auto-attach to model requests [V, executed]**
  what: his Google/Vercel recovery codes and OAuth client-secret JSON attach to a cloud model on a
  two-word name match, with no content-level check.
  why: `ReadRequest.swift:102-113` deny lists are name/extension only — `Recovery Key.pdf`,
  `vercel-recovery-codes-….txt`, `client_secret_….json` match neither; SecretSweeper guards *writes*,
  not reads.
  evidence: slice executed `--probe-find 'the recovery key'` → `attach=yes … ATTACHED as text,
  491 characters`, and `--probe-read …/Recovery Key.pdf` → READ 495 bytes. The symlink escape and
  deny-before-root ordering were verified closed in the same run.
  fix: content-sweep attachments before they enter a request, and extend the name list with
  recovery-code/client-secret shapes; refuse-and-report rather than attach.

- **D-04 | P1 | Daily/weekday routines silently skip the whole day when a tick is blocked [V]**
  what: a tick while a card is open, a turn is in flight, or the display sleeps advances the clock
  past the slot; the next tick computes tomorrow's slot, so the routine never fires that day. Two
  routines at the same HH:mm lose the second one daily (one-per-tick `break`).
  why: `CompanionManager.swift:636-637` sets `routineClock = now` **before** the guards at `:638-644`;
  `RoutinesStore.swift:215` uses strict `first > now`. The comment at `:633` promises the opposite.
  `.every(minutes)` routines self-heal; daily ones do not.
  fix: advance the clock only when the guards pass, or re-check un-fired daily slots by date.

- **D-05 | P1 | The sleep hold is never re-evaluated when routines change [V]**
  what: add a routine with "keep awake" on and nothing else armed → no hold, the routine fires into a
  sleeping Mac; disable the last routine while holding → the assertion stays held for nothing.
  why: `refreshSleepAssertion()` callers (`CompanionManager.swift:481, 497, 507, 537, 562, 885`) are
  reminder/switch/launch paths only; `addRoutine`/`removeRoutine`/`setRoutine` (`:437-459`) never call
  it. Contradicts `SleepPolicy.swift:5-8`'s own promise.
  fix: call it in the three routine mutators and after a routine fires.

- **D-06 | P2 | "He said" trust is earned with one shared content word [A]**
  what: a model proposal gains maximum trust if his transcript contained any one of its content
  words ("run the python script" → "prefers Python 3" saved as `· he said`, immune to corrections).
  why: `MemoryStore.heSaidIt` (`:274-277`) tests a non-empty intersection, i.e. one word. Deliberate
  tradeoff per its comment, but injection can aim for the shared word.
  fix: require a distinctive phrase or two shared content words, as the recall ranking does.

- **D-07 | P2 | ReminderStore.decode ignores the store's own bounds [A]**
  what: a hand-edited reminders.json loads unlimited reminders of unlimited length; with the
  one-per-minute fire cap, 50 overdue reminders take 50 minutes to drain.
  why: `ReminderStore.swift:327-334`; validation is add-time only.
  fix: validate on decode and report what was refused.

- **D-08 | P3 | Doc/tooling inaccuracies in this area [A]**
  what: the documented `--probe-remind 'stretch|40 min'` always fails at parse (working form is
  `remind:stretch|40 min`); `MemoryStore.adopt` is dead; hand-stripped history rows get a fresh UUID
  each load (`ConversationTurn` init:146), so identity is unstable across restarts.
  fix: correct the docstring, retire or wire adopt, persist ids.

**Clean in this slice (executed):** memory origin/cap rules refuse an inferred replacement of his own
line and allow his own correction, net-neutral at the cap; notebook tier refuses credentials
pre-write, refuses-not-clips over-long, dedupes, whole-word delete, recall framed as data; reads
honest-slice at 24 KB and refuse missing/outside/symlink paths with the right reason; single-word
queries never attach; reminders resolve past times to tomorrow on the card and carry late-arrival
text; history decode is row-tolerant and replay session-scoped; 847/847 tests.
**Untested:** runtime scheduler behaviour (needs app launch); DST spring-forward and Feb-29 slots;
real large PDF/Office bounds (no fixture in roots).

---

## C — Shell lifecycle, concurrency, voice, crash/hang class

First attempt at this slice died from context exhaustion and was re-run with a tighter brief. The
re-run read the smaller shell files whole, targeted windows of the two giant ones, the two newest
crash reports and the log tail, and ran the mainthread/mic/awake/caption probes (nonced).
Consolidating agent re-read the cited code for C-02…C-05. Two entries duplicate other slices and are
cross-referenced rather than counted twice.

- **C-01 | P1 | DUPLICATE of B-01** — backup-key retry dead after the first minute
  (`BrainGateway.swift:191, 202`). Fix once, under B-01.

- **C-02 | P1 | Document reads run synchronously on the main actor [V]**
  what: asking about a big file freezes the notch/caption and the whole main run loop for seconds;
  the 20 s race bounds the turn, not the block, and the watchdog cannot resume while main is inside
  the call.
  why: `CompanionManager.swift:3798-3800` hops *to* MainActor (`Task { @MainActor in
  attachFileMentionedIn(...) }`) and the load inside is synchronous PDFKit/NSAttributedString work
  (`FileRead.swift:147`); `offerFileRead` (`:4069`) likewise mid-turn. The comment above it measures
  0.79 s for one slice — on main.
  fix: run the file slice off the main actor; hop back only to stage the result.

- **C-03 | P1 | The watchdog's spoken fallback plays no sound and leaves voiceState stuck [V]**
  what: after a stalled turn the promised "I can't reach the model" sentence is cut off when the
  local synthesizer deallocs at function return, and the cursor/pill sits in "responding" until the
  next ask.
  why: `CompanionManager.swift:4355-4360` — `let synthesizer = NSSpeechSynthesizer()` with no retained
  reference, no delegate, no completion log; `voiceState = .responding` has no clearing path
  (`bindVoiceStateObservation` refuses to override `.responding`, `:1160`).
  fix: retain the synthesizer and route the fallback through `speakCaptioned`.

- **C-04 | P2 | Crash breadcrumbs stop reaching the log after the first rotation [V]**
  what: the one diagnostic that names the faulting event writes into a deleted inode after the log
  rotates; the next crash reports nothing — recreating the "four reports answered no questions"
  failure.
  why: `CrashBreadcrumb.swift:49-53` opens `logDescriptor` once at install; `Log.swift:139-143`
  `rotateIfNeeded` removes the file; the fd is never reopened.
  fix: rotate by rename so the fd follows content, or reopen per fault.

- **C-05 | P2 | Onboarding typewriter timer violates the hop invariant and cannot be cancelled [V]**
  what: first-run characters keep landing after dismissal, mutating MainActor state from a raw timer
  block.
  why: `CompanionManager.swift:4469` — no `Task { @MainActor in }`, no stored reference to invalidate;
  the gate's awk only flags `assumeIsolated`, not a missing hop (see F-09).
  fix: store the timer, hop the body, invalidate on cancel.

- **C-06 | P2 | DUPLICATE of D-03, with one extra fact** — the *listing* path also offers
  credential-bearing names to the model and writes them to the plaintext log
  (`CompanionManager.swift:1726`; log 2026-11-08T07:19:49Z shows `vercel-recovery-codes-…txt` and
  `client_secret_….json` in a probe-find block). Fix under D-03: filter the deny-list from listings
  as well as from auto-attach.

- **C-07 | P2 | A press parked after Allow is unwatchdogged [A]**
  what: if the Accessibility press after Allow parks, the card shows a stale answer forever.
  why: `askConfirm` sets `phase = .result`; `turnStalled` acts only on `.thinking`
  (`CompanionManager.swift:3654`); the answered-card path arms no deadline.
  fix: arm a sibling deadline around the post-allow act.

- **C-08 | P3 | Caption hide race between overlapping speakCaptioned waiters [A]**
  why: the wait loop (`CompanionManager.swift:4337`) ignores cancellation and shares one caption
  manager with no generation token; a stale waiter's 40 s ceiling can clear a newer sentence.
  fix: stamp each caption with a generation; only hide your own.

- **C-09 | P3 | speakCaptioned logs a critical "never said" line for empty text [A]**
  why: `LocalTTSClient.swift:98` returns early on empty; `CompanionManager.swift:4329-4334` then fails
  the began poll and writes a false forensic line.
  fix: return before the began loop for empty text.

- **C-10 | P3 | tapEnable's result ignored; log claims "created and enabled" regardless [A]**
  why: `GlobalPushToTalkShortcutMonitor.swift:122, 126`.
  fix: check the return and log the failure.

- **C-11 | P3 | _setPreventsActivation: set via perform-with-NSNumber (object→BOOL ABI mismatch) [A]**
  what: works today by luck; a runtime change could silently land false and let the caption steal
  the menu bar.
  why: `CaptionPanelManager.swift:119` and `AnnotationOverlay.swift:119` use
  `perform(sel, with: NSNumber(value: true))` while the getter at `:77-83` already demonstrates the
  correct `@convention(c)` IMP call. Live probe measured prevents-activation=true today.
  fix: call the setter through its real C signature.

- **C-12 | P3 | Crash handler has no sigaltstack [A]**
  what: a stack-overflow SIGSEGV cannot run the handler; breadcrumb lost.
  why: `CrashBreadcrumb.swift:58` uses `signal()`, no alt stack.
  fix: sigaction + an allocated alt-stack at install.

- **C-13 | P3 | Permission poll timer runs in default run-loop mode [A]**
  why: `CompanionManager.swift:1130` vs the `.common` rationale applied to the routine clock at
  `:603`; rows briefly lie while a menu tracks.
  fix: add to `.common`.

- **C-14 | P3 | Stale comment claims an ElevenLabs credits fallback [A]**
  why: `CompanionManager.swift:4279-4282`; no ElevenLabs exists in this tree.
  fix: reword.

- **C-15 | P1 | KNOWN-OPEN: the SwiftUI assumeIsolated SIGSEGV class is instrumented, not fixed [A]**
  what: the app can still die mid-click on the notch/menu surfaces; AGENTS.md itself says the cause
  is unproven.
  evidence: the two newest .ips reports symbolicate to deliberate `CrashProbe.start` debug runs, not
  production faults; the 2026-11-04 production reports remain the real instances; breadcrumb lines
  prove the instrument works.
  fix: none available read-only; keep the ObjC-exception tripwire and wait for the next production
  report's swallowed-exception marker.

**Clean in this slice (executed):** `--probe-mainthread` (150 ms wait costs 1 ms detached);
`--probe-mic` 5/5 openings at ~65 ms; `--probe-awake` takes and releases; caption contract measured
live (prevents-activation / ignoresMouseEvents / canBecomeKey / app-active); 847/847 tests.
**Untested:** live spoken turns, real press landings, overlay click-through under activation, TTS
audibility end-to-end — all need the app running (forbidden to the audit).

---

## Fix priority (cross-slice, harshest first)

1. **A-01** clear `pendingProgram` on displacement — denied steps executing later is a consent bypass.
2. **D-01 / D-02 / D-03** stop destroying hand-typed lines, stop writing lowercase-hex secrets, stop
   attaching credential files (and listing their names) — the three data promises the product sells.
3. **F-01 / F-03** make the resolution probes exit non-zero on refusal, so the gate can fail again.
4. **B-01 / C-01** per-turn backup-key timestamp; **B-02** surface in-stream `.error`;
   **B-03** fence the streamer per attempt.
5. **C-02 / C-03** move file slicing off main; retain the fallback synthesizer.
6. **D-04 / D-05** routine catch-up and sleep-hold refresh.
7. **E-01 / E-02 / E-03 / E-04** bound the two unbounded card texts, clear the post-act stage, fix the
   two VoiceOver labels.
8. **A-02 / A-03 / A-04 / A-06** deny-list meta-programs, carry the quit pid, refuse the silent
   browser fallback, repair the focus escape hatch.
9. **B-05** add the fourth CONTINUE construct (gap in the 2026-11-08 fix).
10. Everything else in ID order within severity.

## Known-open / parked (not new; do not rediscover)

- The SwiftUI `assumeIsolated` crash class (C-15): instrumented, cause unproven; next production
  report's swallowed-exception marker is the test.
- 2D drawing / ink layer / pin / eraser: parked on branch `keep-latest-2026-11-04` at his instruction
  until the crash class closes.
- Notch card never photographed on a real screen (E-16); live presses/keys/types/scrolls never watched
  (AGENTS.md Tier 1); Chrome candidate sweep never reaches page content (A-11).
- Tier 2/3 decisions still his: file writes (3.9), unattended steps (3.14), folder contents (3.17),
  Cloud-Computer handoff (3.15), Chrome extension (3.18 item 4).

## Method and verification legend

Six read-only adversarial slice audits ran in parallel (act/consent, brain/protocol, shell/crash,
disk/schedules, surfaces, gate/docs); the shell slice was re-run once after its first attempt
exhausted its own context. Every slice was forbidden from editing files, committing, launching or
killing the app, running verify.sh/make-app/install, and from live-model or crash probes; measurements
were nonced. The consolidating agent re-read the cited code for every P0 and every P1 marked **[V]**
before publication; **[A]** entries carry slice evidence only and must be re-verified before fixing;
**[S]**/suspected entries are labelled in place. Two cross-slice duplicates (C-01→B-01, C-06→D-03) are
cross-referenced, not double-counted.

**Totals: 84 distinct findings — 5 P0, 21 P1, 31 P2, 27 P3** (four of them marked KNOWN-OPEN).
Nothing in this document has been fixed.

---

## Fixed since this audit (ledger, newest first)

- **F-01 / F-03** — `1c3f589`: resolution probes exit 1 on refusal; gate fixtures derived from a
  running app that publishes a field. Full gate 56 checks / 1 skip on the installed bundle.
- **D-03** — `2356dd1`: recovery-code/client-secret names refused and unlisted; read contents swept
  for provider token shapes (hard patterns only, so checksum logs stay readable).
- **D-02** — `652538a`: lowercase-hex credentials rejected by the sweeper.
- **D-01** — `0c67e73`: undated hand-typed lines preserved verbatim in both stores, charged to the cap.
- **A-01** — `f1f77c1`: a displaced question drops its held steps in both card doors; gate asserts it.
- **B-01 / B-02 / B-03** — `01cb578`: per-turn backup-key bound; in-stream SSE errors kept and
  classified; a failover after emitted text resets the streamer so one card carries one model.
- **C-02 / C-03** — `a870647`: file slicing runs off the main actor; the turn-died fallback goes
  through `speakCaptioned` and clears the responding state.
- **D-04 / D-05** — `a50593a`: daily/weekdays ask "has it run for today's slot", clock moves only on
  an allowed tick; every schedule save re-decides the sleep hold.
- **E-01 / E-02 / E-03 / E-04** — `1d50f57`: both unbounded card texts bounded; last act marks the
  turn answered; the login label is on one toggle.
- **A-02 / A-03 / A-04 / A-06 / B-05** — `d3c4e26` (+ test-only `149fa9b`): interpreters/launchers
  denied; quit picks the regular app and refuses two; uninstalled named browser refuses; the Catalyst
  focus hatch reachable; fourth CONTINUE shape consumed.

All five P0s and all P1s except **C-15** (the crash class, KNOWN-OPEN, instrumented not fixed) are
closed. Full gate after the batch: 57 checks, 2 skips (Chrome page-depth candidates and the Shortcuts
window fixture — both known-open). The P2/P3 lists above remain open, in ID order within severity.