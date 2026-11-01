# Chunks — the remaining work

Written 2026-10-28 at the hand of the session that built reminders, drafts, the power hold and the
memory trust rule. Read this with `AGENTS.md` (the scope authority — what Chunks is, is not, and the
invariants that must not break) and `context.md` (the running notes, most recent at the end).

The tiers: **0** is a promise the app makes that is not true, **1** needs his screen, **2** needs a
decision from him, **3** is the hard capability work, **4** is the commercial path — selling it, and
connecting to Google Workspace — added after he said on 2026-10-28 that both are wanted.

**Everything below is stated as a user-visible failure, not a task title.** If you cannot say what he
sees when it is missing, you do not understand the item yet.

---

## State of the tree right now — read before you touch anything

- **The tree is dirty: 105 paths differ from HEAD `bd36e2b`** (47 modified, 57 untracked — including
  this file, which is untracked — and **one staged deletion**: `Sources/Chunks/Clicky/
  ElementLocationDetector.swift`, which nothing in `Sources/` or `Tests/` references and which no
  context note explains. It is not this session's doing; the build and the suite are green without
  it, and it stays deleted unless he says otherwise). Do not run `git reset --hard`,
  `git checkout --`, `git stash`, or `git clean` — that work is one command from being gone. If you
  want a checkpoint, ask him; he commits when *he* has verified, not before.
- **699/699 unit tests, 35 verify checks passed, 2 skipped** (2026-10-31, nonce GATEF-1793463644).
  The two skips are the two standing ones and both now print their own reason: no Shortcuts *window*
  open for the named aim, and the ranking reaching 0 pressable candidates inside Chrome's window veto.
- `verify.sh` now refuses to run against a stale or bare binary: it demands the installed signed
  bundle whose embedded source fingerprint matches the tree, renders into a fresh temp dir and
  fails a render whose command exited non-zero, and asserts the bundle is universal, hardened and
  carrying exactly `scripts/Chunks.entitlements`.
- The installed bundle at `~/Applications/Chunks.app` is current with the tree and running.
- `~/Library/Logs/Chunks/chunks.log` no longer holds any pre-redaction keystroke lines (`keyCode=`
  count is 0). That item is closed; do not re-open it.

### The five things that bite in this workspace

1. **`swift test` does not work here** (CommandLineTools, no `XCTest.framework`). The suite is
   `swift run chunks-test`. Full gate is `./scripts/verify.sh` — build, suite, every read-only probe
   against the real machine, three rendered surfaces, and the two contracts that must never regress.
   It takes about a minute. Run it before saying anything is done.
2. **Never build the bundle by hand and never run the bare binary for permission work.**
   `./scripts/make-app.sh && ./scripts/install.sh`. macOS identifies the app to TCC *and* the Keychain
   by its signature, so an ad-hoc-signed rebuild silently revokes his grants and hides his stored key.
3. **The Edit tool in this workspace has reported a spurious failure while still applying the change,
   and once applied one twice.** Verify with `grep` or a build after every edit here. That is not
   paranoia, it is the cost of not shipping a file with duplicated declarations.
4. **A screenshot from a shell is wallpaper.** Screen Recording belongs to the signed app. To see UI,
   render it: `--render-ui`, `--render-window`, `--render-panel`.
5. **`DisplayEnumerationTests` fails while the display is asleep or locked.** Re-run awake before
   believing a red suite.

---

## Tier 0 — a dead promise in the prompt. Do these first.

**All five closed** — 0.1–0.4 on 2026-10-28 and 0.5 on 2026-11-01, verified by `./scripts/verify.sh` (33 checks, 1 skip) and 648/648
unit tests. 0.1 took the second option (stop teaching it): the event, the construct and the prompt
lines are gone, and an old `<NOTE>` in a stored or streamed reply round-trips as visible text —
including split across deltas — with unit cases for whole, streamed and unterminated shapes. 0.2's
header now describes only the capped file that exists. 0.3 is `ReadInputBudget`: one 6,000-unit
UTF-8-byte token **upper bound** (not measured tokens) charged against the exact live frame — path,
coverage warning and untrusted-data label — with PDFs as ranked whole pages (an oversized best page
is refused, never clipped, never swapped for a less relevant one) and text/office files as
contiguous whole lines whose boundary fragments are trimmed as bytes before decoding. 0.4 is in
`--render-ui`: two 340-character draft fixtures (alone and with a confirmation) measured through
native layout markers — Copy 96×28 pt inside the 360 pt window, draft text scrolling in a 56 pt
viewport while Copy stays put — and the probe exits non-zero if any of it moves outside the window;
`verify.sh` runs it as a check with the render's exit status, in a fresh temp dir.

Small, self-contained, no new permission surface, and each one removes something the app currently
*says* that is not true. This class of bug has cost more time than any feature in this repo.

### 0.1 `<NOTE>` is taught to the model and consumed by nothing — DONE

`ResponseParser` emits `.noteOffer(title:)`, `AnswerStreamer` matches it with `break` and a comment
saying the panel does not render it, and the system prompt defines the tag — `GeminiTransportTests`
asserts it is there. So the model writes `<NOTE>Debug Navigator</NOTE>`, and nothing happens, forever.

Pick one, in this order of preference:
- **Consume it** as the Notebook tier Chunks' own `MemoryStore` doc comment already promises:
  unbounded, never auto-injected, searched on demand. `notes.md` beside `memory.md`, written through
  `SecretSweeper` like every other disk in this app, with a `Show notebook` row next to the memory
  panel's `Show file`. Then `<NOTE>` means what it says. (This is 3.3 below, done properly.)
- **Or stop teaching it**: drop the tag from the prompt and the assertion, and delete the dead event.

What you must not do is leave it half-wired. A tag the prompt mentions and the app ignores is the same
lie as "there is no tool for a one-off reminder", which was in the prompt until today.

### 0.2 The stale Notebook promise in `MemoryStore`'s header comment — DONE

The class comment describes two tiers, memory and Notebook, and there is no Notebook type anywhere.
Either 0.1 makes it true, or the comment must go. Comments that describe an unbuilt tier are how the
next person implements the wrong thing.

### 0.3 Give the PDF and long-log slice an explicit token budget — DONE

`DocumentReading` picks the pages carrying the question's words and caps at 6 KB of characters, whole
pages only, each block labelled with its page number and a line saying the rest was not read. What it
has no notion of is a **per-chunk budget**: a 400-page PDF whose named word appears on 60 pages is
still a decision about which 6 KB, made by page order rather than by score. Add the arithmetic
(`framing + selected pages + slice line ≤ budget`, refuse before overflowing rather than truncating
mid-page) and a case that fails if a document can be silently cut in the middle of a clause.

### 0.4 `--probe-*` coverage for the newest tools — DONE

`--probe-memory`, `--probe-remind` and `--probe-awake` landed today and each has a `verify.sh` check.
The draft surface does not: nothing live proves the card sizes the well and its Copy button. Add a
render state assertion or a probe that prints the measured height for a 340-character draft, and make
`verify.sh` fail if the button falls outside the window.

### 0.5 The prompt taught `caffeinate -u`, which does not stop a sleep — DONE 2026-11-01

`[DO:run_command:caffeinate -u -t 3600]` was the prompt's own example of "keep this Mac awake", and
`-u` asserts `UserIsActive` — a tickle, not a hold. Measured on his machine with `pmset -g assertions`
while each flag shape ran: `-d` holds `PreventUserIdleDisplaySleep`, `-i` holds
`PreventUserIdleSystemSleep`, `-di` holds both, `-s` holds `PreventSystemSleep`, and `-u` holds
neither of the three that matter. He got the honest card (`still running as pid 82174`) and his Mac
slept anyway, because the command was copied from us word for word.

Fixed in the prompt (`caffeinate -di -t 3600`, with the flags named and `-u` called out as not one of
them), in six comments across `ToolRunner`/`DoRequest`/`AGENTS.md` that repeated the same mistake while
describing unrelated bugs, and in `verify.sh` — the prompt check now requires `-di` present and
`caffeinate -u` absent from the live instruction, so it fails if anyone reverts from memory. The two
verbatim quotes of his `did not run.` card were left as records. See `context.md` 2026-11-01.

---

## Tier 1 — needs his screen. Code can be written here; nothing is *done* until he looks.

He tests in his own terminal and reports what the screen said. His evidence outranks your inference
from a log line — that has been true every single time it has been tested.

- **Watch a reminder fire.** Say "in ten minutes remind me to stretch", then be there at ten minutes.
  Open question only he can answer: is a reminder that arrives mid-sentence acceptable?
- **Watch a draft copy.** "Write him a reply saying I'll be there at seven" → the well, then **Copy**,
  then ⌘V somewhere. Does the whole message arrive, and does the card's line read honestly?
- **Watch the plan survive a live app.** Every step is re-resolved against the tree as it is *then*;
  the step whose label described a control that only exists after the previous step is the one likely
  to fail first. WhatsApp's list is the fixture only he has.
- **Watch the slow-503 failover and the carried screen** on a real turn (the hedge, the slice, and
  `ScreenCarry` re-attaching yesterday's picture when he says "answer it").
- **The notch card and the window have never been photographed on a real screen.** Geometry is
  unit-tested and both are rendered offscreen; the shape, the halo, the chip hit targets, and whether
  ⌃A survives the apps that already own it all need eyes.
- **The panel's new rows**: "WAITING TO SAY ONCE", the reminder composer, and "Stay awake for
  schedules". The render shows them empty; a populated list has not been looked at.
- **Watch a terminal command run — it has never run once.** Say *"run caffeinate for an hour"* and
  read the card. It should end `caffeinate is running and Chunks has stopped watching it. It said:
  still running as pid …`, and `pmset -g assertions | grep -i caffeinate` is the independent proof the
  hold is real. The cause of his two `did not run.` screenshots is found and fixed (the card-answer
  path called `ToolRunner.run`, which refused commands without starting them — see `context.md`
  2026-10-31), but **there is no baseline on his machine for the success path**, because there never
  was one. If it still refuses, the card now carries the exit status, and that number is the next
  measurement.
- **Two slow turns in a row, to see the thinking-level memory work.** `gemini-3.8-flash` refuses
  `thinking_level` on every request and the chain discovered that afresh each turn (~1.7s and a wasted
  request per turn, in the log all day 2026-10-31). `BrainGateway` now remembers it for the process —
  but a probe builds a fresh gateway per turn, so the only way to watch the line disappear is two
  consecutive real turns that both walk as far as `3.8-flash`. One log line is the whole test:
  `turn: gemini-3.8-flash rejects thinking_level …` should appear **once**, not once per turn.
- **`--probe-stt` has never had a voice to transcribe.** Run from a shell it opens the microphone,
  records its 8.0s of silence across three engines and reports nothing useful. It needs him speaking
  into it, which is the one comparison (SpeechAnalyzer against the two older engines on the same
  audio) that no probe can fake.

---

## Tier 2 — decisions he has now made, and the ones still open

Answered on 2026-10-28, so do not re-ask: **he wants the Developer ID path, he wants to sell the app,
and he wants Google Workspace (calendar, mail, other services) connected.** That is Tier 4 — start
there for the commercial work.

Still open, and it needs him rather than you:

- **Gemini quota.** The key is free-tier and `gemini-3.1-pro` is at 0 requests/day, which makes the
  chain's last escape hatch dead weight. He raises limits rather than having the retry logic engineer
  around a 503 — do not add another fallback for contention.
- **Who the product is for, once it is for sale.** BYOK means the buyer needs their own API key, so
  the honest first market is developers and power users. A hosted key is a decision with a backend, a
  bill, and Google's security assessment attached — see Tier 4.3.
- **The screenshot is the latency, not the model — measured 2026-10-31.** Two `--probe-protocol`
  turns took **126.3s and 44.0s**; four others on the same display took **15.7–16.3s**. The log line
  that separates them is the payload: `1 image(s), 7022 KB` against `1 image(s), 1005 KB`. Same
  display, same resolution (3420x2214), **7x the bytes**, because a PNG of a plain window compresses
  and a PNG of his wallpaper does not. The chain times behind those two slow turns were 28s and 16s,
  so the rest was upload and pre-chain wait, not thinking. Options are his, and they are not free:
  send JPEG (lossy — a small font on a dark page is exactly what gets destroyed), downscale to
  logical points (a 1710x1104 image — the 0–1000 aim grid is scale-independent, so presses survive
  it, but fine text may not), or keep the PNG and stop pretending a 60s budget covers a 126s turn.
  Nothing here is broken today; the budget arithmetic is now honest about it. What is unmeasured is
  what the answer costs in reading quality, and that needs his eyes on two real captures.
- **The planner's scope.** `EventKit` is approved in principle; what it may *write* is not. A day brief
  that reads his calendar is one thing, and an assistant that creates events is another. Ask before
  you build the second.
- **`maxCandidateSearchElements` (700) versus a frozen notch** — see Tier 3.1's 2026-10-31
  measurement. Raising it is the direct fix for "the page is never reached" and it doubles the wait.


---

## Tier 4 — the commercial path. What "hand it to another Mac" and "sell it" actually cost.

Three gates, and they are not interchangeable: **Apple's**, **Google's**, and **the buyer's**.

### 4.1 Apple's gate — cheap, mechanical, do it first

**Done up to the account wall, 2026-10-28.** The bundle is universal (arm64 + x86_64, `lipo`
verified per arch), `LSMinimumSystemVersion` is derived from `Package.swift` (15.2) so the plist,
the executable's `minos` and the package target are one number, and the seal is
`--options runtime` with `scripts/Chunks.entitlements` holding only the microphone entitlement —
`verify.sh` asserts all of it per architecture and fails on any entitlement added later. What
remains is exactly what needs **his enrolled Apple Developer account**: the Developer ID
Application certificate, `notarytool submit --wait` + `stapler staple`, and after that Sparkle and
the clean-account acceptance checklist. Enrolment is US$99/year, individual or organisation, and
the certificate can only be created by the account holder.

None of it needs a policy decision and all of it is prerequisite to everything else.

- **Enrol in the Apple Developer Program** — US$99/year, and it needs a Mac-app-store-free
  individual/team account. Until that exists, nothing below can be tested.
- **Universal binary.** `.build` is `arm64` only (`lipo -archs` confirms). Intel buyers are still a
  real population on macOS 15; build `arm64 + x86_64` or state plainly that Intel is unsupported.
- **Fix the version lie.** `Package.swift` declares `.macOS("15.2")` while the generated plist promises
  `LSMinimumSystemVersion 14.2` — the bundle claims it runs on a system the code was not built for.
  Pick one number and make both say it. This is free and it is a bug.
- **Hardened runtime + entitlements.** There is **no entitlements file at all** today
  (`codesign -dv` reports `flags=0x0`, `TeamIdentifier not set`). Add one with exactly what the app
  uses — screen capture, accessibility, microphone, Keychain access groups, and the network client —
  and sign with `--options runtime`.
- **Developer ID + notarisation.** Replace the self-signed "Chunks Local" identity with a real
  Developer ID, then `notarytool submit --wait` and `stapler staple`. **This is the step that changes
  the product's behaviour on other people's machines**: the whole signing story in `AGENTS.md` exists
  because an ad-hoc signature is a cdhash, so every rebuild silently revokes his TCC grants and hides
  his Keychain item. A real identity fixes that for customers too — their grants stop moving under
  them, which is the single most common reason a utility like this gets uninstalled.
- **Sparkle 2 for updates.** Needs the signed+notarised build, an Ed25519 signing key for the appcast,
  and a static host for the feed. A static file is not "a cloud backend" in the sense `AGENTS.md`
  forbids — no account, no telemetry, no user data. Keep it that way: an appcast that knows who
  installed Chunks is the first step to the thing the scope rule exists to prevent.
- **Acceptance test.** A zip that a **clean user account** on a second Mac can download, open without
  Gatekeeper fighting it, grant five permissions to, and use — with the app still working after a
  software update. Write that as a checklist and run it; nothing in `verify.sh` can see any of it.

### 4.2 Google's gate — where the real cost is, and BYOK is what keeps it small

[Google ships official Workspace MCP servers](https://developers.google.com/workspace/guides/configure-mcp-servers)
for Gmail, Drive, Docs, Sheets and Calendar, and the plan already allows exactly this route
(*"official vendor MCP servers only, Ask-before-run"*). Two facts decide how far it can go:

1. **They run against a Google Cloud project the operator owns**, with the APIs enabled there. For
   *his* machine that is an afternoon. For a thousand customers it is a thousand projects, or one
   project of his that every customer's mail flows through — and the second is the cloud backend
   `AGENTS.md` forbids, with Google's assessment clause attached.
2. **Gmail is a restricted scope, and unverified apps are capped.** Google's own FAQ: *"unverified
   apps that are accessing restricted or sensitive scopes have a 100 new-user cap restriction"*, and in
   testing mode authorisations expire after seven days with users hand-listed on the consent screen.
   The assessment clause is written around servers: an app needing restricted data *"and [having] the
   ability to access data from or through a third-party server must go through a security assessment"*.
   A strictly client-only app with PKCE, tokens in the Keychain and no relay is the case that may pass
   verification without a CASA — **and that boundary is the one thing to get in writing from Google
   before any money is budgeted for it.** Do not assume the client-only exception survives; there were
   reports in 2026 of it being narrowed.

So the build order is: **read-only, his own account, via the official MCP servers, Ask-before-run**
(calendar first — it is the least sensitive, it is what Phase 6's brief actually needs, and it makes
the planner real), then decide about mail with the verification answer in hand. Note that
`PolicyGate` already refuses to touch Keychain and password apps, and the same instinct applies to a
mailbox: reading it is a bigger claim than pressing a button, and it needs its own allow-list, not the
screen one.

### 4.3 The buyer's gate — what a customer actually has to do to use it

**Built 2026-10-28 with 3.7.** The three things this section named as the minimum bar are in: the
five-grant flow with a working restart path (the setup window's first step, `PermissionRow`'s
Restart where macOS actually applies it), the key field that says in one sentence where the key
comes from and where it goes ("aistudio.google.com/apikey … your Mac's Keychain and nowhere
else"), and a no-key tier that completes the step on its own — the offline switch is accepted by
`FirstRunPlan` as a finished brain step, not a downgrade. What remains is the measurement this
section asked for on a **clean account** (the click count inside Chunks is 8; wall-clock seconds
and the System Settings maze need a stranger's Mac, not this one) and the Sparkle/Developer-ID
prerequisites above it.

This is the one nobody thinks about until support email arrives. Today a first run needs: an API key
pasted into the panel, five TCC grants, and — for anything from Google — a GCP project of their own.
That is a developer's onboarding, not a product's.

Before it is sold, the minimum bar is: a first-run flow that gets all five grants with a working
restart path (Tier 3.7), a key field that explains where to get a key in one sentence, and a
**"no key, no cloud" mode that is still useful** — the offline brain answers in 15.2s against a
contended Gemini's 24–32s, so the local path is a real product tier, not a fallback. Measure what a
first-time user sees in seconds and in clicks, and put the number in `context.md`.


---

## Tier 3 — the hard capabilities. This is what a frontier model is for.

Ranked by user-visible payoff, each with the acceptance test that makes "done" checkable.

### 3.1 Act on web content — the biggest hole in the product

`--probe-ax` over Chrome's web content resolves to an unnamed `AXGroup` and Chunks correctly refuses.
Today's partial answer is `isPublishingLazily` + `webActionRetryDelay`: Chromium builds an action list
only after an assistive client has walked the node, so the same element is read twice. That fixed
"click the Usage link" for *some* links. It does not fix a page whose controls publish no name at all,
which is most of the modern web, and it is why the prompt still says coordinates are the fallback for
web content — and a coordinate is a fraction of a picture, so it degrades with the model's aim.

Options, in ascending order of audacity:
1. **Rank unnamed candidates** by geometry + role + children labels instead of refusing on name score,
   and put the *description you actually resolved* on the card ("Press the 3rd row in the sidebar?").
   Strictly better than a silent refusal, and it keeps invariant 8 intact because he still answers.
2. **Region-scoped candidate list**: inside a circled crop, enumerate pressable descendants and let
   the model pick by index rather than by pixel. The crop already carries its rectangle.
3. **A DOM route** (DevTools protocol) — do not reach this without asking. It needs a debug port on
   his browser, which is a bigger security surface than everything else in this app combined.

Acceptance: `--probe-semantic` and `--probe-ax` resolve a named link in a live Chrome tab, and a unit
case proves a card question that names an unnamed control cannot be answered by pressing something
else (the re-read-and-compare rule must survive the change).

**Option 1 is built and wired, measured 2026-10-28/29 on a live Chrome tab; the press itself still
needs his eyes.** `CandidateRanker` (ChunksKit, pure) + `AXTDriver.candidateSweep`/`candidateResolve`
+ `--probe-candidates`, and `offerNamedAct` falls back to it after `resolve` refuses. Evidence at the
time, all of it read-only:

| Measured | Result |
|---|---|
| `--probe-semantic 'app=Chrome name=Meet the party planning community'` | refusal — no control called that |
| `--probe-candidates` for the same words | `resolved AXGroup verb=AXPress at (117.0, 34.5)` · card: `Press the area that says "Meet the party planning community" at the top-left in Google Chrome?` · policy with asking off — **needsConsent** |
| `--probe-candidates "app=Chrome name=Mute"` | ranking picks the player's `Mute (m)` (score 3, exact) over the named route's `Mute tab` (score 2, and at y = −53 out of sight) |
| `--probe-semantic 'app=Chrome name=Guide'` | resolves `AXCheckBox/Guide` — it refused before the menu pruning, because 479 of a Chrome window's first 700 elements are menu rows |
| Suite / verify | **688/688** unit tests, 39 suites · **36 checks passed, 1 skipped, exit 0** (the skip is the standing Shortcuts one: no Shortcuts window open) |

Two rules came out of measurements that contradicted my own inference. A display-filter on candidates
was built, installed, measured and **reverted**: Chrome publishes its *visible* toolbar at `y = −91`,
so filtering by `CGGetActiveDisplayList` deleted Back, Reload and the address bar and turned a working
card into a refusal — the card now states no location when the control's centre lies outside the window
the user is looking at. And a wrapper group plus the button inside it at the identical frame is one
control, not an ambiguity; treating it as two would have refused most of a page.

Still open here: a **real spoken turn** pressing a child-aimed control on his screen (the card wording
and the forced question are the parts only he can confirm), and options 2 and 3 below, unbuilt.

**Measured 2026-10-31, and the hole is wider than the table above suggests.** The check that was
supposed to prove this worked had been **skipping on every run**: `--probe-controls` printed the first
sixty controls in walk order, which is the menu bar, and the check filters menu rows out to find its
fixture — so it filtered away all sixty lines, found nothing, and printed SKIP. That is fixed (non-menu
controls now come first, and the same run went 60-of-60 menu rows → 0-of-60). With the check actually
live, the honest measurement is worse: on a real Chrome window `--probe-controls` reports 198–494
pressable controls and `--probe-candidates` collects **0 inside the veto** —
`(0.0, 156.0, 1710.0, 951.0)` — with the 700-read budget spent on browser chrome before it reaches the
page. So option 1 resolves a *named* toolbar button when the window geometry is kind, and has never in
this session reached a web control at all.

**The decision this needs is his, not an engineer's.** `maxCandidateSearchElements` (700) is what
bounds how long the notch sits frozen mid-turn, and raising it is the direct fix for "the page is never
read". Measured cost of the walk today: `--probe-candidates` takes several seconds against a live
Chrome and spends every read it is allowed. Doubling it doubles the freeze. That is a Tier 2 question
— the same kind as the Gemini quota one — and no amount of code should answer it by himself.

### 3.2 A prompt diet — 7,454 tokens per turn, measured — DONE

Measured 2026-10-28 on the installed bundle: **30,733 → 20,376 chars, 7,683 → 5,094 tokens
(−33.7%)**. Every rule survived; the anecdotes, the restated plan rules and two of nine examples
went. The regression risk is now a harness: `--probe-protocol` runs five fixed turns on the live
screen and asserts `<SAY>`+`[ACT:]`, `[DO:remind:]`, `[TYPE:]`, `<SAY>`+`<SUMMARY>` and `[SCROLL:]`
each arrive; the TYPE turn opens an empty TextEdit document as its fixture, because on a screen with
no editable field the model correctly asks "which chat?" instead of typing into nothing. Two runs:
nine measured turns, nine passed, zero failures; three turns skipped by free-tier contention and
reported as skips (exit 3), never as passes.

`--probe-prompt` reports the assembled system prompt at **29,817 characters (~7,454 tokens)** on every
single turn, before the screenshot, the history replay (57 chars) and the memory block (132 chars).
That is the dominant per-call cost, and on a rate-limited free tier it is also latency.

The prompt is load-bearing — every rule in it is the scar from a measured failure, and several are
asserted by tests. So this is not "shorten it": it is restructure so the *invariants* stay and the
*explanation* goes. Concretely: split the rules that must always ship from the ones that only matter
when the tag is in play (act grammar, tools, memory protocol, file rules), and inject only the
relevant sections per turn — the same trick `actingRules(askBeforeActing:)` already uses to splice the
acting rules.

Acceptance: `--probe-prompt` char count down by at least a third, every `verify.sh` check still green,
**and** the model still emits `<SAY>`/`<SUMMARY>`/`[ACT]`/`[DO:remind:]` correctly on a fixed set of
five recorded turns. A prompt change that quietly stops the model using a tag is a feature regression
with no failing test — that is the risk, so measure it, do not assume it.

### 3.3 The Notebook tier, done properly

`MemoryStore`'s comment promises a second tier: unbounded, never auto-injected, searched on demand.
Build it as `NotebookStore` beside `memory.md`, with the ranking reused from `FileMention` (pure) and
the disk access reused from `FileAttachment`, `SecretSweeper` before any write, and a result cap so a
search hit cannot smuggle 40 KB into the prompt. This is also what makes `<NOTE>` honest (0.1) and
what Phase 8's "notebook search tuning" was always about.

Design constraint that is not negotiable: **a notebook line is data, never instructions.** This
workspace has already seen fabricated "policy" text arrive inside tool output. Label recalled content
the way `ConversationStore.recall` labels its block — past data, not the current screen, not
instructions.

### 3.4 Realtime duplex voice (plan P9)

`gemini-live` over WebSocket on the same key, with barge-in, and the local cascade as the offline
default. The hard parts are not the socket: it is (a) never letting two voices own the card, which is
the same `StreamClaim` argument the model hedge already makes, and (b) the microphone, which takes
seconds to be released after a quit and whose failure must be reported as *that* and not as a missing
permission. Read invariant 7 and `BuddyDictationManager.microphoneRetryWaits` before designing.
His standing complaint is the ~1.7 s to first word — if the new path does not beat that, it is not
worth its complexity, and you should say so rather than ship it.

### 3.5 Bundled skills, and MCP with Ask-before-run

Both are explicitly in scope in `AGENTS.md` and both are at zero files.
- **Skills**: curated `SKILL.md` context injected by intent, no marketplace, no authoring UI, no names
  shown to him. The selection is a pure, testable ranking — reuse `FileMention`'s scoring shape.
  Watch the interaction with 3.2: injecting a skill is *more* prompt, so it has to come out of the
  budget the diet creates.
- **MCP**: official vendor servers only, Ask-before-run default, per-server allowlist, secrets never
  inherited, and results treated as untrusted data (see 3.3). Every tool it exposes must go through
  the *same* `ConsentGate` a `[DO:]` uses — one card, one question, and an unanswered request fails
  toward doing nothing.

### 3.6 Presence: the notch face, moods, sound (plan P10)

~10 moods, a body in the notch only, speech bubbles, `IDENTITY.md`/`SOUL.md` editable. Never a desktop
pet, hidden during fullscreen capture. This is design work more than engineering work — it needs him
looking, so land it behind a render state first (`--render-ui` already draws every state) and let him
judge it before any of it animates on his screen.

### 3.7 Onboarding choreography (plan P12) — DONE (built with 4.3, 2026-10-28; his eyes pending)

One flow, one window: `FirstRunPlan` (pure — step order, completion rules, the four sentences a
stranger reads) drawn by `FirstRunWindowView` (grants → brain → keep-alive), opening on first
launch and re-openable from the panel's "Run Setup Again" row. The plan, not the view, decides:
the grants step completes only when `PermissionState.allGranted` says so (Input Monitoring read
by its own preflight — a tap can be created and hear nothing), the brain step accepts **either**
a stored key **or** the offline switch (4.3's no-key tier is a complete answer, not a
consolation), and only Done sets `finished`. `--render-setup` draws all three steps offscreen and
asserts each fixture's plan opens on the expected step; `verify.sh` runs it as a check; five unit
cases pin the rules, including "a revoked grant reopens the flow at the step that broke". Click
count inside Chunks for a stranger on a fresh Mac: **8** (4 Grants, 1 Restart, key paste + Save —
or 1 toggle — login switch, Done), plus the System Settings toggles macOS insists on. The render
caught one dead promise on its first look — the last step's footnote pointed at a next step that
does not exist — now corrected.

A 3-step permission wizard, Screen-Recording restart guidance, and the launch-at-login row. The
`PermissionRow` vocabulary already exists for all five grants; what is missing is the sequence and the
recovery path. Note the trap in invariant 7: **a tap can be created successfully and hear nothing**
when Input Monitoring is missing, so every row must check `CGPreflightListenEventAccess()` rather than
inferring from a successful grant elsewhere.

---

## How to work with him

- He verifies in his own terminal. Ship the harness, name the honest gap, and give him **numbered
  plain-language steps with the exact command, the expected output, and what to report back**. Prose
  loses him, and a terminal workflow he has to repeat per use is not a feature — the probes are yours.
- Act locally without asking: build, install, relaunch, re-run verify. That is expected. What needs a
  question is anything with a new permission, a new cost, or anything irreversible.
- Latency is a feature and states must be honest: report where an act landed, never show progress you
  cannot account for, and never let a check that did not run report as passed (`skipTest("why")`).
- Measure the alternative you rejected. "Latency down or flat, never up" — with the number.
- No keyword gates in anything voice-facing: a trigger list caps how he can talk.
- Re-derive from first principles after a second miss instead of patching a third time, and revert
  rather than guess again.
- **Commit only when he says it works.** Not before.
