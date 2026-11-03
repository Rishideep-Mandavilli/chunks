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

- **The tree is dirty against HEAD `ae7fd49`.** Do not run `git reset --hard`, `git checkout --`,
  `git stash`, or `git clean` — that work is one command from being gone. If you want a checkpoint,
  ask him; he commits when *he* has verified, not before.
- **767/767 unit tests across 42 suites; 42 verify checks passed, 1 skipped** (2026-11-02, nonce
  OFW-GATE-1793647917). The local-brain checks are back on by default at his request — the offline tier is
  a product (4.3) and a check that is off by default is a check that rots — and both PASS: `--probe-local`
  and `--probe-reply --local`. What stays fixed is the bug those probes had (they wrote the app's real
  brain settings; now `BrainSettings.processOverride`, asserted by a contract check). The one skip is the
  standing Shortcuts-window one; the Chrome-candidate check came back PASS, which is window geometry.
- **`--probe-local` is a live-model check and it can go red for nobody's action.** Measured the same
  day: one gate run returned 37 passed / 1 FAILED on it, and the next direct run of the same binary
  passed all five of its turns. It grades what a local model answers in that second — an `[ACT:]` or
  a `<CONTINUE>` that does not arrive is a model shrug, not a build regression. Read the probe's own
  output before believing either verdict, and do not loosen an assertion until you have seen which of
  the five turns moved.
- **A probe switched his brain; fixed, and the brain is back on Gemini.** Until 2026-11-02
  `--probe-local` answered "which model is on this Mac?" by writing `app.chunks.brainProvider` and
  `brainModel`, so every gate run left the installed app pointed at Ollama — and `--probe-protocol`,
  run afterwards, graded the production prompt against a 2B local model and reported three tag
  families "lost". The probes now use `BrainSettings.processOverride`, scoped to their own process,
  and `verify.sh` fails if any `*Probe.swift` writes `UserDefaults` again. The stored value was set
  back to `gemini` on 2026-11-02 (the panel's own switch, `setOfflineBrain(false)`, writes the same
  key) and re-measured: **`--probe-protocol` turns 3–7 PASS on Gemini** — `[TYPE:]` 5.9s,
  `<SAY>`+`<SUMMARY>` 35.7s, `[SCROLL:]` 8.6s, `<NOTE>` 5.9s, `[NOTES:]` 10.2s — and **turns 1–2
  SKIP** on `gemini-3.1-pro: 0 input tokens per minute on Free Tier`. So the "i have noted that…"
  answer with no `<NOTE>` behind it was a local-model grammar failure, not the prompt's, and the
  notebook tier round-trips on the brain he is keeping.
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

## Where every task stands — 2026-11-03, at a glance

Read this first if you only want the state, not the argument. **Done-and-watched** = measured on the
machine. **Done-unseen** = code green, `--render-*`/`--probe-*` verified, but no human has looked at it
on a real screen. **Blocked-on-him** = a Tier 2 decision, not an engineering problem.

**Closed 2026-11-03, the two bugs that were still open:** the launch-hold's *other* half (a plan whose
first step is a launch now runs the launch, re-captures and resumes instead of dropping the steps), and
the open-a-file policy, which has moved into ChunksKit as `OpenFilePolicy` with `--probe-open` reading
its real verdict — so the five answers (one card, two matches, no such file, a credential, out of
roots) are now unit-tested and probeable instead of living where neither can reach. 3.15's lifetime
question is **answered, not built**: the Pi executes and holds the job state, the notebook only serves
the model.

**Three more closed the same evening, all from his own screenshots** — which is how they were found:
every one of them passed the gate and the unit suite while being wrong on his screen.
- **`list_windows` under-reported the machine.** He has eight apps running and was told "you have two
  windows open". `--probe-windows` agreed with the card, so it was not a bad summary: Accessibility
  publishes an *empty* window list for every app that is not on the display he is looking at, and the
  enumerator only asked Accessibility. The read is now a union with the window server, and 2 became 7
  with both Chrome tabs distinguished. See `AGENTS.md` invariant 8.
- **A reveal reported a success that had not happened.** `activateFileViewerSelecting` returns `Void`
  and the next line said `return true`, so every file reveal ever attempted wrote
  `tool: Showed … in Finder.` while nothing appeared. `revealLanded` now believes a Finder window whose
  title names the folder — and refuses to count "some window appeared" as success, because a window for
  the *wrong* folder is the same lie in a new costume.
- **The listing claimed `0 left out` while omitting six apps.** `leftOut` only ever measured the byte
  budget, never the enumeration. Fixed by making the enumeration complete; the counter's meaning is now
  what its name says.

**New from the same three screenshots, and it is a gap rather than a bug:** he asked what a *folder*
holds and Chunks answered about the file inside it. There is no tool that lists a folder's contents —
`FileAttachment` finds one file by name and `reveal` opens one folder in Finder, and nothing in between.
Recorded as **3.17 What is in this folder**, with the one decision that has to come from him.

**Tier 0 — dead promises.** 0.1 `<NOTE>` **closed twice over**: first by deleting the tag (2026-10-28),
then properly, by building the tier that consumes it (3.3, 2026-11-02). 0.2, 0.3, 0.4, 0.5
`caffeinate -di` — all done, all asserted by a `verify.sh` check that fails on a revert.

**Tier 1 — needs his screen** (nothing here is broken; all of it is unlooked-at):
- Reminder firing mid-sentence · a `<DRAFT>` copied and pasted somewhere · a plan surviving a live app
  (WhatsApp's list is the only fixture) · the slow-503 failover and `ScreenCarry` on a real turn ·
  the notch card and the window never photographed on his desktop · the panel's new rows populated ·
  **a terminal command that has never once run on his machine** · two consecutive slow turns to see
  the thinking-level memory work · `--probe-stt`, which needs a voice.
- **New since yesterday:** the resumed round after a launch (3.8) · the notebook footnote and a
  *populated* panel row (3.3) · `--probe-protocol` turn 1 and 2, which currently skip on free-tier
  contention rather than proving the press and remind families.

**Tier 2 — decisions only he can make:** Gemini quota (open — `3.1-pro` is still 0 tokens/min) · the
**7× screenshot payload**, which is the real latency and needs his eyes on reading quality · who the
product is for once it is sold · the planner's write scope · `maxCandidateSearchElements` vs a frozen
notch · two Gemini keys — **declined by him 2026-11-02**, recorded so it is not re-litigated ·
**new: whether Chunks may write to
his disk** · **new: the browser DOM port** · **new: concurrency and other agents** — the last three are
the whole of what he asked for today, and each one has a scope argument attached rather than code.

**Tier 3 — the hard capabilities.** 3.1 web content **partly built**: a named toolbar control resolves,
and `--probe-candidates` has still never reached a *page* control (0 candidates inside the window veto).
3.2 prompt diet **done** (~7.4k tokens, harness-backed). 3.3 **Notebook — built 2026-11-02**, unbounded,
never injected, `<NOTE>`/`[NOTES:]` verified live on Gemini. 3.4 realtime duplex voice **not started**.
3.5 bundled skills + MCP **zero files**. 3.6 presence/notch face **not started**. 3.7 onboarding
**done-unseen**. 3.8 launch-hold **done-unseen**. **New 3.9–3.15** from his ask: 3.9 file writes
(blocked-on-him), 3.10 VS Code by name (buildable now), 3.11 PDF stays read-only (a refusal wording),
3.12 browser in three levels (L1 and L2 buildable now, L3 blocked-on-him), 3.13 process and window
choreography (**slices 1 and 2 built** — the four window verbs, then geometry by name with a coordinate
refused at parse; the listing half went to 3.12 level 1), 3.14 a durable job
queue (in-scope shape of "multiple tasks", with one question to answer first), **3.15 hand a browser
job to Cloud-Computer on the Pi** (new 2026-11-02; he already owns the other half, and it is blocked on
the integration-vs-delegation decision), 3.16 agent delegation (**out of scope as stated**; the
in-scope version is driving their windows).

**Tier 4 — the commercial path.** 4.1 Apple's gate: everything up to the account wall **done**
(universal, hardened, exact entitlements, fingerprint-checked) — Developer ID, notarisation and Sparkle
need his enrolment. 4.2 Google's gate **not started**, and it should not be until the client-only
exception is in writing. 4.3 the buyer's gate **built, unmeasured** — the clean-account click count is
still a guess.

**Build order I'd argue for, if he wants one:** 3.13 → 3.15 (once he has picked integration over
delegation) → 3.12 L1 → 3.10 → 3.9 (after the write decision) → 3.14 (after the unattended-steps
decision). 3.13 first because it is the largest felt capability that needs no new permission and no
scope argument; 3.15 second because Cloud-Computer already runs a headless browser on his Pi with
spend gates and traces, which makes it a better answer to browser work than anything built inside
Chunks — and it retires most of 3.12 level 3 before a debug port is ever opened on his machine;
3.14 last because a queue is the item that changes what the product is.

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

### 0.1 `<NOTE>` is taught to the model and consumed by nothing — DONE, properly, on 2026-11-02


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
- **Watch a launch resume the plan.** Say *"open chrome and type 'how to use sql' in the search box"*
  out loud, and watch for the second look: Chrome should open, the card should
  say so, and about 1.5 s later Chunks should ask again and aim the typing at the window it just
  made. `--probe-reply` proves the split (`plan: launch now, 1 step(s) held for a fresh capture`)
  on any reply, and five of six live turns wrote exactly that shape — what has never been seen is
  the resumed round on his screen, and whether it lands on the address bar or on the desktop. Two
  questions only he can answer: is the fresh capture a better aim than the one it replaced, and does
  the extra round read as help or as stalling?
- **Watch the slow-503 failover and the carried screen** on a real turn (the hedge, the slice, and
  `ScreenCarry` re-attaching yesterday's picture when he says "answer it").
- **Watch the window verbs on a real window.** Say *"close that window"* with something unsaved in it
  and read the card: it should name the window and the app, say the cost, and ask even with "Ask before
  acting" off. Then *"minimise Safari"* and *"bring the terminal to the front"*, which should just
  happen and be spoken. `--probe-windows Safari` prints the same enumeration and wording without
  touching anything, so a disagreement between the probe and the card is the interesting result.
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
- **Two Gemini keys, one for answering and one for everything else — DECLINED by him, 2026-11-02.**
  Raised and then dropped the same day ("ok then, leave it"), so this is a record rather than a task:
  it was in scope (BYOK with two keys is still BYOK — no proxy, no metering, nothing leaving the
  machine, so 4.2's CASA clause is untouched), and it would have bought a second untouched free-tier
  bucket, since the cap is ~5 requests/minute **per model per key** and a routine firing currently spends
  the same budget he is about to speak into. It would not have bought speed: `gemini-3.1-pro` answers
  `0 input tokens per minute on Free Tier` because of the *tier*, and the 7× PNG payload is upload time.
  If latency ever becomes the complaint again, the payload is the lever, not a second key. Re-open only
  if background turns start visibly stealing his interactive budget.
- **Whether Chunks may write to his disk.** Every byte-level rule in this repo today is about *reads*
  (invariant 9): allow-listed roots, a credential deny-list on the resolved path, his own words naming
  the file. File editing (3.9 below) is a new capability class, not an extension of that one, and it
  needs the same thinking done fresh: what may be written, where a backup goes, what "undo" means after
  a rebuild, and a card that names the exact lines changing. `run_command` is already an always-asked
  door to anything a shell can do, so the honest question is whether a first-class write tool is safer
  *because* it is checked, or just safer-looking.
- **Handing a job to Cloud-Computer on the Pi — integration or delegation?** Raised 2026-11-02, and
  it is the one open decision that needs a sentence in `AGENTS.md` before code. Facts from his own
  project, not from the name: Cloud-Computer is a self-hosted agent that drives a real browser
  (Playwright locally or an E2B microVM) over `POST /tasks`, streams stages on
  `GET /tasks/{id}/events` (SSE), pauses at spend gates on `POST /tasks/{id}/approval`, keeps NDJSON
  traces, and **is already deployed to a Pi 400** (`infra/pi/`: arm64 Lite OS, ~1.3 GB RAM with a task
  running, 2 GB swap, `make pi HOST=…`). Two readings, and they are not the same product:
  **(a) an integration** — Chunks is a *client* of a remote executor, exactly the shape 3.5 already
  allows for MCP ("Ask-before-run, per-server allowlist, results as untrusted data, secrets never
  inherited"), one card per question, and the remote's own approval gate mirrored rather than
  duplicated; **(b) a delegation** — Chunks hands work to another identity that reasons and acts on its
  own, which is the ❌ line ("no sub-agents… it may not spawn workers or hand work to another
  identity") and the layer he explicitly cut when he scoped this as a HeyClicky replica minus the
  multi-agent part. My reading is that (a) is in scope and worth having, and it needs one honest
  amendment: *"nothing of theirs leaving the machine"* becomes *"nothing leaves to a vendor"* — an
  instruction and possibly a screenshot would travel to **his** Pi over Tailscale/LAN, which is not the
  cloud backend the rule exists to prevent (no metering, no billing, no analytics, no proxy he has to
  carry) but is not the same claim either. Also his to settle: Cloud-Computer holds provider keys
  server-side in `.env`/`.vault.json`, so the "BYOK, keys in the Keychain" story stays true for Chunks
  and becomes *not* true for the job it handed over.
- **A companion that runs on the Pi itself.** Worth saying plainly before it becomes a task: the
  macOS app cannot be ported — AppKit, Accessibility, ScreenCaptureKit and the notch are all
  Apple-only, and a Swift binary will not run on arm64 Linux. What already runs there is
  Cloud-Computer. So "Chunks on the Pi, like hark" is one of three things, and which one is his
  choice: a **headless agent** on the Pi that Chunks talks to (that is the handoff above), a **new
  client** written for Linux with its own voice path and no screen to point at, or a **Pi as the
  always-on half** of a two-device product where the Mac does the screen and the Pi does the long
  jobs. The third is the one the existing code supports today.

- **Concurrency, and whether other agents may do work.** "Assign multiple tasks" and "integrate with
  multiple agents" collide with the scope file head-on: `AGENTS.md` forbids sub-agents, teams and any
  hand-off to another identity — one assistant, one task per turn — and that line is what makes Chunks
  a sellable *app* rather than a service. Three ways through, and they are his to choose between:
  **(a)** amend `AGENTS.md` and design a real job runner (multiple live plans, several cards, several
  screens changing at once — the confirm chain was built one-question-at-a-time for reasons);
  **(b)** keep one agent and add a **sequential durable queue** (3.14), which delivers most of what he
  is asking for — jobs that survive a sleep, run one after another, and report where each stopped —
  without the identity layer; **(c)** have Chunks *drive* another tool's UI (3.10, 3.13): typing into
  VS Code's command palette or starting a build in an IDE's terminal is a press and a type, entirely in
  scope today, and is not the same thing as delegating to that tool's agent.


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

### 3.3 The Notebook tier, done properly — DONE 2026-11-02 (his eyes pending)

`MemoryStore`'s comment promised a second tier: unbounded, never auto-injected, searched on demand.
It is built: `NotebookStore` beside `memory.md`, `<NOTE>` writes it, `[NOTES:…]` searches it and the
labelled block rides into the next turn (the same continuation channel a `[READ:]` uses), and the
panel's "Show notebook" row reveals the file. `SecretSweeper` runs before every write, one line per
note, and a recalled block is charged with its own framing and cut at whole entries under a 4 KB
budget — the best note that will not fit is refused, never clipped, and the count left out is printed.
This is also what makes `<NOTE>` honest again: Tier 0.1 deleted the tag in October because nothing
consumed it, and it is taught again only now that something does.

Measured on the way, both against real output: `--probe-notebook` (7 assertions on a copy plus his
file read-only) caught the whole-word delete first — `contentWords` drops `3` as too short, so the
needle `"number 3"` quietly became `"number"` and removed every invoice in the file, which is exactly
the failure `MemoryStore.matching` was written against. And `--probe-reply` grew two fixtures for the
new tags, so a parser drift that makes `<NOTE>` unreachable fails the gate rather than silently
turning his notes into prose on a card.

Still his to watch (Tier 1): the footnote at a glance, and whether the row survives a *populated*
panel — `--render-panel` draws it empty, which is the one case that cannot overflow.

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

### 3.8 A launch in front of a plan of pixels — DONE 2026-11-01 (his screen pending)

**The failure was not the one named in the brief.** "Auto-continue after a launch drops the rest of a
plan" described the steps being dropped; what the code did was drop the *launch* (`leadingTool`
returns nil for a pixel step, so the branch that offers the tool is never reached) and run the pixel
step against the screenshot taken before anything opened — so the app stayed shut and the keystrokes
went to the wrong window. Six live local-model turns, five with that shape. See `context.md`
2026-11-01.

`PlanAfterLaunch.decide` (ChunksKit, pure) now splits such a reply: the launch runs through the same
`offerTool`/`runTool` door as a lone `[DO:]`, and **every** step waits, because the grammar carries no
order between a tool and an act. What waits is one sentence, not a coordinate list, sent down the
existing `continuePlanIfNeeded` route — same `maxPlanRounds` bound, same `planRecaptureDelay`, the
model re-aims against a fresh capture. Resumes only when the launch happened; `set_volume` and
`run_command` do not qualify (`DoRequest.invalidatesTheScreen`); a new sentence from him drops the
hold.

`--probe-reply` is the other half, and the one that was asked for: a reply in, every construct's
verdict out, with the reason from the same reader the live turn uses, cross-checked against the
streamer's own `unreadActTags` so a drifting audit fails rather than reporting clean. Five fixtures,
sixteen assertions, no model and no screen — plus `--probe-reply --local`, which asks the local model
the plan question and audits its real words, so `[ACT:DO:open_app:Chrome]` and the unterminated
`</NEXT_ACTIONS` it also writes are found by a script instead of in front of an audience. Both are
`verify.sh` checks now. Acceptance held: 729/729 unit tests (16 new), 38 checks / 2 skipped, and the
live mode's first run caught the probe auditing the card instead of the reply.

Still his to watch: the resumed round itself (Tier 1).

### 3.9 Write a file he names — the disk capability, not the screen one

**The failure today:** *"change the port to 8090 in config.yml"* has no answer. Chunks can read that
file, can type into an editor if he has it open, and can be talked into a `run_command` that rewrites
it with `sed` behind a card that says the whole shell line. None of those is the product behaviour.

Build it as `[EDIT:~/path|what to change]` with the same five doors a press travels: roots allow-listed
and the credential deny-list applied to the **resolved** path (invariant 9's rules, reused, not
restated), the change computed as a whole old-text→new-text pair so an ambiguous match is a **question
with the real candidates rather than a choice**, the file re-read immediately before the write and
compared to what the card quoted (the exact analogue of "a card can outlive a relayout" in invariant
8), a copy of the previous bytes kept somewhere he can find, and the outcome line saying which lines
changed. `verify.sh` must assert it cannot touch `~/.ssh`-class fragments or a `.env`.

Blocks on the Tier 2 decision above. Acceptance: `--probe-edit 'path|change'` prints the resolved
path, the diff it would apply, the policy verdict and the card's sentence — and applies nothing.

### 3.10 Drive VS Code, and any Electron editor, by name rather than by pixel

**The failure today:** VS Code is Electron, so `AXManualAccessibility` gets its tree and typing works —
but a *file* edit through the UI means finding the explorer row, opening it, aiming the cursor at a
line, and every one of those is a pixel aim against a screen that changes when the file opens.

Two pieces, both in scope now: **a commands route** — VS Code publishes a command palette, and
`[DO:run_shortcut:…]`/`[ACT:app=Code name="Go to Line"]` already speak this vocabulary, so "open
config.yml in VS Code and go to line 40" is a launch plus named steps; and **a file route** — 3.9's
`[EDIT:]` writes the file and VS Code reloads it, which is faster, verifiable, and never moves his
cursor. His call inside this: whether Chunks should prefer the file route when the editor is already
open (it can make the editor dirty-versus-saved disagree with disk, which is the failure to design
for) or drive the UI so the editor is the authority.

**Update 2026-11-02, part of this is built and it moved the decision.** `[DO:open_file_with:Code|
~/notes.md]` is in — `RevealPolicy`'s roots and credential list applied to the resolved path before the
card, the card naming the file and its parent folder, `NSWorkspace` opening it, two matches a question
rather than a coin toss. So the **file route is the one that works today**, and the editor UI route
(command palette, go-to-line) is now the remainder rather than the foundation. Two gaps left honestly:
there is no read-only probe for it yet (the verdict lives in `CompanionManager.resolvedOpenFileWith`,
and a probe that re-implemented it would be a second opinion about his disk — it needs the resolver
hoisted into ChunksKit first), and whether Chunks should prefer the file route when the editor is already
open is still his call, because that can make the editor's saved-versus-unsaved state disagree with disk.

**Update 2026-11-03: the first of those two gaps is closed.** The decision moved to
`Action/OpenFilePolicy.swift` in ChunksKit — `decide(app:written:resolved:appExists:)` plus the five
sentences — and the shell is now two facts: `FinderReveal` for what the disk says, `ToolRunner.isInstalled`
for what is on the machine. `--probe-open 'TextEdit|notes.md'` prints the disk's answer, the verdict and
the card's exact wording and opens nothing, and `verify.sh` asserts that the five answers stay
distinguishable (a credential, an out-of-roots path, a missing file, an uninstalled app, one open card).
Nine unit cases pin the ordering, including the one that is easy to get wrong: an app that is not
installed is answered *before* the file, because a card about credentials would send him to fix a path
he already wrote correctly. Measured on his machine while writing the check: `open_file_with:Code|…`
refuses, and refuses for a reason that is true — three apps in `/Applications` contain "code"
(`Visual Studio Code`, `Claude Code URL Handler`, `Free Claude Code`), so the strict single-candidate
rule in `resolveApplicationPath` cannot choose. The gate therefore asks which names resolve rather than
typing one. Whether to loosen that rule for a *file* open — where a wrong app is an inconvenience, not
the wrong document on screen — is his call, and it is a different decision from `open_app`, which is
what the rule was written for.

Acceptance: `--probe-controls Code` lists what the app publishes, and a spoken "open the file I named
in VS Code" lands on the right document — his screen for that one.

### 3.11 Read the PDF; say what it is not

Reading is done and tested (pages ranked by his words, whole pages, page numbers, scans drawn as
pixels). **The failure today is the shape of the ask**: "fix the date on page 3 of this PDF" has no
answer, and should not pretend to. PDF *writing* collides with `AGENTS.md`'s ❌ list (no generated
files, no artifacts), and a rewritten PDF without the right provenance is a document that may end up
signed. Keep the read tier honest, offer a `<DRAFT>` of the replacement text or an `.md`/`.txt` sibling
he can edit in place, and refuse the write **as that** — the way the spreadsheet refusal is already
worded. If he wants real PDF editing, that is a scope amendment, not a feature.

### 3.12 Browser work in three levels, and the third needs a decision

- **Level 1 — what is open. DONE 2026-11-02.** `[DO:list_windows:all]` / `[DO:list_windows:Safari]`
  stages a labelled block into the next turn: every window with its title, owner, frame, focused and
  minimised flags, grouped by app with the frontmost first. It is a **read**, so it takes no card and is
  never reported as an act (`DoRequest.isContextRead` keeps it out of the plan, the leading-tool and the
  dropped-tool paths), and `OpenWindows` cuts the block at whole app groups under 3 KB, saying how many
  windows were left out. Measured on his machine: 4 windows, 600 bytes, Chrome's Colab tab named in full.
  Two of those four are Chrome's own titleless toolbar windows (`(no title) (0, 34, 1710x41)`), which are
  real AX windows and honest noise — worth watching for whether they earn their bytes or should be
  filtered, and that is his eye, not a guess. URL extraction is *not* here: reading the address bar is
  level 2 work.
- **Level 2 — the page by the accessibility tree.** Chrome's own AX tree is what 3.1's ranking walks:
  fill this field, press this button, read these words. It works today for *some* pages, fails where the
  app publishes nothing inside the read budget, and its ceiling is the `maxCandidateSearchElements`
  decision, not code. In scope.
- **Level 3 — the DOM.** A debug port or an extension bridge: exact selectors, real page text,
  deterministic. This is 3.1's "do not reach this without asking", and the reason has not changed: a
  port his browser listens on is a bigger security surface than everything else in this app combined,
  and it must be his eyes-open choice — plus it makes every page he visits reachable from Chunks, which
  is a claim the current screen-read model never makes. **And as of 2026-11-02 there is a better
  answer to most of it:** 3.15 hands the job to Cloud-Computer, which already drives a real headless
  browser on his Pi with its own spend gates and NDJSON traces, so a debug port on the browser he reads
  his mail in may never need to be opened at all. Read this level as the fallback, not the plan.

### 3.13 Process and window choreography — slices 1 and 2 DONE 2026-11-03 (his screen pending)

**Slice 1 is built and on his machine.** `[DO:focus_window:Safari|Inbox]`,
`[DO:minimize_window:…]`, `[DO:close_window:…]` and `[DO:quit_app:Safari]` — resolved against the live
tree before the card is worded, `close` and `quit` in `alwaysAsks` beside `run_command`, the cost said
out loud in the question, `terminate()` and never `forceTerminate()`, and nothing that moves the
cursor. `--probe-windows` is the harness: it enumerates, prints each verb's card sentence and asserts
the always-asked contract, performing nothing. First live run on his screen found 2 windows and passed;
it also caught a wording bug on the way — Qoder's own window asked *"Bring \"Qoder\" in Qoder to the
front?"*, now named once.

One real finding from the unit cases, and it is a rule rather than a bug fix: `AXTDriver.nameScore`
cannot match a window title he names partially. It awards 3 for an exact token-set match and 2 for a
prefix, so "TASKS.md" against a window called "Chunks — TASKS.md" scored **1** and was refused — the
most natural sentence about a document window. Window titles now use a subset rule instead (every
distinctive word he said must be in the title), with specificity breaking a tie, because the ambiguity
that made `nameScore` strict for *controls* is already handled here by refusing two equal answers with
both names listed.

**Slice 2, built 2026-11-03 — geometry by name.** `[DO:move_window:Safari|Inbox|left]` puts a window in
one of twelve places a person says out loud: the four halves, the four corners, `full`, `centre`, plus
`main`, `second` and `display=N` for a second monitor. **A coordinate is refused at parse, not clamped** —
`|400,220` never reaches the machine, because a rectangle a vision model guesses is the exact class of
number invariant 1 was written around, and unlike a wrong press a wrong position is dragged back by hand.
`centre` moves without resizing; every other place sizes the window to the slot.

The arithmetic is `WindowPlacementPolicy` (ChunksKit, pure) and converts nothing: displays arrive in
`CGDisplayBounds`, which is already Accessibility's global top-left logical points, and the menu-bar and
Dock insets are taken as a **difference inside one screen**, which is orientation-independent. Coverage is
the 1x/2x/3x round trip the repo demands of any coordinate work, expressed as the property that matters —
the same screen at any backing scale yields the identical rectangle — plus a secondary display at a
**negative origin**, the shape a real two-monitor Mac has. `--probe-geometry 'App|Title|left'` prints the
display list, the window, the frame it *would* write and the card's sentence, and moves nothing; the gate
asserts the frame lands inside the display, that a pixel never parses, and that a display number past the
grammar's cap and one that is simply not plugged in are two different refusals.

Three decisions inside the slice, each argued from the failure it prevents: **the act re-decides at
execution**, not from the card, because a window can move and a monitor can be unplugged while he reads;
**a move the app ignored is reported as a failure**, because both `AXValue` writes answer `.success` even
when a fixed-size panel refuses to resize, and `place` therefore re-reads the window's own frame against a
4 pt tolerance — the reveal's lie, one evening earlier; and **the desktop is listed but refused as an
act**, found by this very probe volunteering to place Finder's desktop in the left half while
`--probe-windows Finder` had been printing *Minimise "desktop" in Finder?* for a day. Detection is two
facts only a desktop has together (no `AXTitle` of its own, and a frame exactly the whole of a display),
so a full-screen app's window — same size, always titled — is not caught.

Honest limits, not gaps: a move needs an element, so a window on **another display** is listed and cannot
be moved, and the answer says so. And a very long window title is quoted in full on the card — measured on
his machine a Chrome tab arrived as *"GVPCE – you're sharing this tab with Gemini for the duration of this
conversation - Google Chrome – Rishideep"*, which no two-line card can show. Truncating it is a wording
decision, and it belongs to the same question as the close card's wording.

**Still to build, in this order:**
- **Quitting an app that refuses** currently reports one line. Whether Chunks should then say *why*
  (the app's own unsaved-document sheet is on screen and could be read) is a question for him.
- **The card's title length**, now that a real tab has broken it. Same question as above, one answer.
- ~~Geometry: move, resize, "put that on the second display"~~ — **built above**, 2026-11-03.
- ~~`open_file_with:App|path`~~ — built 2026-11-02; its policy hoisted into `OpenFilePolicy` and made
  probeable 2026-11-03.
- ~~Listing what is open~~ — built as 3.12 level 1, and it rides the `[READ:]`/`[NOTES:]` channel as
  planned.

Acceptance for what is built: `--probe-windows [App]` prints the enumeration, each verb's question and
the contract verdict, and exits 0; `--probe-geometry 'App|Title|where'` prints the rectangle and exits 0
on a placement, 1 on a tag that will not parse; the unit suite pins parse, wording, ambiguity, the app
filter, the subset title rule, specificity, that position never decides, the twelve places, the pixel
refusal, the scale round trip and the negative-origin second display.

### 3.14 A durable job queue — several tasks, one brain, in order

**The failure today:** a plan that needs six rounds dies at `maxPlanRounds` (4) with "I stopped after 4
steps. Say the word and I'll carry on", and a routine is a prompt plus a time, not a job with state.
So the felt need behind "assign multiple tasks" — start three things, walk away, find out what happened
— is real, and can be met **without** sub-agents: a queue of jobs, each a stored plan with its steps,
its status and its last outcome, run one at a time by the same single agent through the same
`PolicyGate`/`ConsentGate`, resumable after sleep, and never running a step while a card is open or the
display is asleep (the scheduler already refuses that for routines, which is the precedent).

This is the one item on this list that changes what Chunks *is*, so it comes with a question he should
answer before code: how long may an unattended job run, and which steps may run unattended at all. The
rules that make Chunks safe are all about the moment of the press; a queue moves that moment away from
his desk, and `AGENTS.md`'s "a scheduled act that runs while nobody is looking is a remote control for
the machine" is the sentence to argue with first.

### 3.15 Hand a browser job to Cloud-Computer on the Pi

**The failure today:** *"book that slot on the portal and tell me when it's done"* has no answer.
Chunks can press and type in the tab in front of him, but a job that needs a headless browser, several
minutes, a login it must not see, and a spend decision is not a plan of acts — and 3.12 level 3 (a
debug port on his own browser) is the alternative `AGENTS.md` says not to reach for.

He already owns the other half: Cloud-Computer is a self-hosted agent that drives Playwright (or an
E2B microVM), is deployed to his Pi 400, and exposes `POST /tasks`, SSE stages on
`GET /tasks/{id}/events`, `POST /tasks/{id}/approval`, `POST /tasks/{id}/cancel`, `GET /tasks`,
`GET/POST /watches` and `GET /digest`, plus a `handoff "<task>"` CLI. So this is a **client**, not a
new executor: one `[DO:handoff:…]` tool, resolved by `DoRequest.parse` like every other, asked about on
one card ("Send this job to the Pi?"), then reported as it goes.

Four rules, each of them a place this goes wrong if it is not decided first:
1. **One approval system, not two.** Cloud-Computer pauses at its own spend gate and waits on
   `POST /tasks/{id}/approval`. Chunks' `ConsentGate` holds exactly one question, so a remote gate has
   to arrive as *that* card — and while it is waiting, nothing else may ask. A job that needs his money
   is a permanent act and belongs in `alwaysAsks`, beside `run_command`.
2. **The remote's words are data.** Its stage text, its page readings and its traces come back over a
   network and are injected into a turn, so they get the same framing the notebook and `recall` blocks
   get — past data, not the current screen, not instructions. This workspace has already had fabricated
   "policy" text arrive inside tool output.
3. **Secrets are never inherited.** The job description may not carry his Keychain key, and
   Cloud-Computer's own `.vault.json` stays on the Pi. `SecretSweeper` runs on the outgoing
   instruction, which is the first time it guards something leaving the machine rather than landing on
   disk.
4. **Reachability is reported, not assumed.** The Pi is asleep, on another network, or mid-task; each
   of those is a different sentence, and "the Pi did not answer" must never read as "the job failed".

Blocked on the Tier 2 decision above (integration vs delegation, and the `AGENTS.md` sentence it needs).
Acceptance: `--probe-handoff 'book the slot'` prints the resolved URL, the request body, the policy
verdict and the card's sentence **without sending anything** — the same read-only shape as
`--probe-reveal` — and a live run reports stages on the card as the Pi sends them.

**The plan, and the split of the work — 2026-11-02.** He runs the decision model (Microsoft's Fara
weights) on a Kaggle notebook today and the browser on the Pi, and he intends to build the remote side
in another agent/harness and bolt it on afterwards. So the seam has to be written down in both
directions, because a contract nobody wrote down becomes two incompatible halves.

**A. What the other harness owns (Cloud-Computer side). None of it is Chunks' to guess at:**
1. **A token.** The API has no auth today — `POST /tasks` on a LAN or Tailscale address is an open
   remote control for a browser that can log in somewhere. Add a bearer token checked on every route
   except `/health`, and keep it out of `.env` echo in responses.
2. **A stable status contract.** The stages already exist (`running` / `needs_approval` / `finished` /
   `failed` / `cancelled` / `missing_model`). Freeze them: field names, terminal-vs-waiting, and an
   `updated_at`. Chunks renders each differently, and a silent rename on the server reads as a job that
   never started.
3. **Origin, on the task.** Accept `{"source": "chunks", "reply_to": "<his sentence>"}` and echo both
   back, so a job Chunks started is distinguishable from one he started from a terminal or a watch
   fired, and the digest can be answered into the right conversation.
4. **`GET /tasks/{id}`.** A single-task read. Today there is the SSE stream and the whole list; a poll
   that survives the Kaggle notebook restarting needs the one-item read, and so does Chunks after a
   sleep.
5. **The approval body.** `POST /tasks/{id}/approval` should say what it is approving (a cost, a
   destination, an action) in a machine-readable field, because that string is exactly what Chunks puts
   on a card — and Chunks must not paraphrase a spend decision it did not compute.
6. **A lifetime answer — decided by him on 2026-11-03.** *"The Kaggle just runs the model whereas the
   Pi executes."* So the split is not a choice to make later: **the Pi is the durable half** — it owns
   the task records, the queue, the browser and the clock — and **the notebook is a GPU that answers
   questions**, reached over HTTP for one inference at a time. Three consequences for the contract, all
   of them now the harness' job rather than Chunks':
   - **Job state lives on the Pi, never in the notebook's memory.** A Kaggle notebook idle-times-out,
     restarts, and its process dies with it; a job whose "where was I?" lives there is lost, and the
     user reads that as `failed`. The Pi writes the task record before it asks the model anything.
   - **The model hop is disposable and must look like it.** A request to the notebook timing out is a
     retry against a fresh endpoint, not a failed job — so `GET /tasks/{id}` needs to distinguish
     `waiting_for_model` from `running`, or Chunks will report a stall as a loss. `infra/pi/` is already
     provisioned at ~1.3 GB resident with 2 GB of swap, which is why the *record* fits on the Pi even
     though the weights do not.
   - **The Pi answers for both halves.** `--probe-handoff` and the six outcomes talk to the Pi's URL
     only; if the notebook is down, that is `unreachable` *from the Pi's point of view*, reported as the
     model tier being unavailable, and never as "the job failed".
   What is left as his decision is only which endpoint the Pi uses for the model (Kaggle while
   iterating, Modal or a local machine later) — that is a URL in a config file, and none of the above
   changes when it moves.

**B. What Chunks owns (this repo), and the order to do it in:**
1. `RemoteExecutor.swift` in ChunksKit — pure request/response types over the contract above: a task
   request, a status, an approval, a cancel. Zero networking, so every shape is unit-testable and the
   refusal sentences are decided where the negative cases live.
2. One `[DO:handoff:<instruction>]` tool, parsed by `DoRequest` like every other, asking for a card
   that quotes the whole instruction, and `SecretSweeper` run on the outgoing text — the first time that
   sweeper guards something *leaving* rather than landing on disk.
3. `RemoteJobs` in the shell: start, poll on a timer, and stage each stage transition into the
   conversation the way `[READ:]` stages a file — the answer comes back as a labelled block, never as
   an act line.
4. **A remote approval becomes the one card.** `needs_approval` on the SSE map has to arrive as
   `ConsentGate`'s outstanding question with the server's own words, and nothing else may ask while it
   is open. Two approval systems that can both say yes is the hole.
5. **Six outcomes, not two.** `running` / `needs_approval` / `finished` / `failed` / `cancelled` /
   `unreachable` — and `unreachable` is its own sentence, because the Pi is asleep, on another network
   or mid-reboot far more often than a job fails, and "the job failed" about a device that did not
   answer is the same class of lie as "caffeinate finished" about a hold with four hours left.
6. A read-only `--probe-handoff` that prints the URL, the body, the token's absence-or-presence, the
   policy verdict and the card sentence, sending nothing — hoist the resolver into ChunksKit first, the
   same lesson `open_file_with` just taught.

**C. The decision that has to happen before any of it is built.** Chunks as a *client* of a remote
executor fits the rule 3.5 already sets for MCP (Ask-before-run, per-host allowlist, results as
untrusted data, secrets never inherited). Chunks *delegating* to another reasoning identity does not fit
`AGENTS.md`'s "no sub-agents, no worker spawning, no hand-off to another identity", and it also changes
the one sentence that makes this sellable as an app: *"nothing of his leaves the machine"* becomes
*"nothing leaves to a vendor"* — an instruction and possibly a screenshot travelling to his own Pi over
Tailscale is not a metered backend he has to carry, but it is not the same claim either. **Pick one in
writing** — client, or amend the scope file — and note that Cloud-Computer keeps its model's keys
server-side, so BYOK stays true for Chunks and stops being true for the job it handed over.

**D. Explicitly not built here.** No Chunks process that spawns or supervises another agent; no shared
identity between the notch and the Pi; no second voice owning the card; no proxy where Chunks' key
would sit on the Pi. If the remote half ever needs Chunks' Gemini key, that is a different product and
this file says so before the code does.



### 3.16 Integrating with other agents and IDEs — out of scope as stated, in scope as driving

Cursor's agent, Claude Code, a language server: handing work *to* another identity is the ❌ list
("no sub-agents, no agent teams, no roster of named agents"), and it is the layer he explicitly cut
when he scoped this as a HeyClicky replica minus the multi-agent part. What is in scope today is
3.10/3.13 — Chunks driving their windows, typing into their fields, starting their builds, reading
their output through the same tools that read anything else. If he wants the delegation layer after
all, that is an `AGENTS.md` amendment with the sellability argument re-litigated, not a task to pick up
quietly.

### 3.17 What is in this folder — the gap his screenshot showed

Found 2026-11-03 while he was testing the release: he said *"open Ritesh.X in my documents folder or
downloads folder"*, and Chunks answered **"Documents and Downloads folders hold Ritesh.docx, which you
opened earlier with its student record and cleaning activity details."** Every part of that is true —
`FileAttachment` had really attached the `.docx` (the log says `attach: …/Ritesh.docx as text (2383
characters), score 10`) — and none of it answers the question, which was about a **place**, not a file.

The capability map has a hole in the middle of it:

| He asks | Today | Tool |
|---|---|---|
| "read Ritesh.docx" | finds it, reads it, answers | `FileAttachment` + `FileRead` |
| "show me Ritesh.docx in Finder" | opens the parent, selects it | `[DO:reveal:…]` |
| "open Ritesh.docx in TextEdit" | opens it in the app he named | `[DO:open_file_with:…]` |
| **"what's in my Downloads folder"** | **no answer** — the model talks about the file instead | nothing |

So the ask is a **folder listing as context**, which is a *read* in the same shape as
`[DO:list_windows:all]`: nothing moves, no card, a labelled block staged into the next turn, framed as
data and not instructions. `ReadRequest` already owns the roots and the credential deny-list, and
`FileMention` already ranks names against his words, so the parts are here — what is missing is one
entry point that returns *names and sizes and dates for one directory*, capped, with the count of what
was left out.

**The decision that is his, not mine.** A read sends its contents to the model; a *listing* sends only
file names, and file names are the part that can be about other people and other work — a Downloads
folder is a log of everything he has touched this month, and `RevealPolicy`'s roots are wide. Three
options, and the difference is what leaves the machine:
1. **Names only, inside the folders work lives in** (`~/Documents`, `~/Downloads`, `~/Desktop`,
   `~/Projects`, `~/src`), capped at a few dozen entries, dotfiles excluded, and the credential
   deny-list applied to the *folder* — so "what's in `~/.ssh`" is refused even though it is a name-only
   question. This is what I would build.
2. **Names plus what Chunks can already see** — the listing *and* the frontmost window, so "what's in
   Downloads" answers about the Finder window he is looking at rather than the disk. Narrower, no new
   data leaves.
3. **Nothing** — and instead make the model say it cannot, rather than answering about the file. That
   is the honest floor and it is a prompt change, not a tool.

Acceptance either way: `--probe-list-folder '~/Downloads'` prints the entries the tool would hand the
model, the cap, and the refusals, and writes nothing; a spoken *"what's in my downloads folder"* gets a
count and the names rather than a paragraph about one document. And a listing that was cut says how many
were left out, because a partial list described as a complete one is the failure this codebase has
already been burned by twice.

### 3.18 HeyClicky parity — what shipped, what is next, and what will not be copied

He asked, on 2026-11-03: check what HeyClicky released, compare it, copy what can be copied, and make
Chunks **more** than HeyClicky. Two findings first, because they change the shape of the task.

**Nothing new is importable.** The installed app here is 1.0.53 (2026-10-02); their current Mac release is
**1.1.2 (2026-10-30)**. The open-source repo's last code commit is April 2026, and its README says plainly
that everything after it stays private — the releases repo holds signed DMGs and an appcast, no source. So
the well the annotation overlay was drawn from is closed, and every item below is built here from the
behaviour, not copied from the code.

**Built on 2026-11-03, both green and gated:**
- **Voice answers the card** (`VoiceAnswer`, 7 unit cases + a 13-fixture probe). An exact spoken phrase
  maps to the same `ConsentGate.Outcome` the Allow and Not now buttons pass, so nothing about the policy
  changed — only the input device. The interesting cases are the ones that must **not** answer: "yes and
  close the other tab" is a new request with an old card hanging off it, and it falls through to a normal
  turn, where the existing displacement rule denies the outstanding act on its own terms. "Allow always"
  is unreachable by voice, because it is a standing instruction about an entire application and a
  mishearing must not be able to set it.
- **The spoken caption** (`CaptionLine`, `CaptionPanelManager`, 7 unit cases + `--render-caption`). Its
  own words at the bottom of the display while it talks. Click-through, never activating, no key window,
  and cleared on `isPlaying` rather than when `speakText` returns — that call returns as soon as playback
  *starts*, so clearing on it would drop the words two seconds into a five-second sentence.

**Next, in this order — his instruction, 2026-11-03:**
1. **2D drawing on the screen.** Their feature is circles, points and sketches drawn *on the live screen
   while you talk*, with the drawing being what the question is about. Chunks already has the hard half:
   `AnnotationOverlay` takes the mouse on a dimmed full-screen surface, `RegionResolver` turns marks into
   a crop, and `cropFrame` makes an aim inside a region land on the real control. What is missing is the
   **ink as an object** — strokes that persist, a pointer/pin marker, an eraser, and a way to point at
   something you just drew. **3D is not on this list**: it needs a mesh pipeline and nothing in Chunks'
   design language asks for it, and he agreed. This is a session of its own.
   **Built on 2026-11-03, in its own session, green and gated.** The ink is an object now:
   `AnnotationShape.pin` (one click, one point) and `AnnotationSession.erase(at:)` / `shape(at:)`
   (topmost-first, by bounding box) make the marks addressable; the overlay's tool row is six — pen,
   circle, box, arrow, pin, eraser, the eraser rubbing on drag and on release; and `InkLayerManager`
   leaves the same shapes on the live display after the surface closes, click-through and never key,
   cleared by the turn's end, the card's dismissal or its own 120 s cap. The pin's dot, ring and eraser
   reach are three pure numbers in `AnnotationShape` shared by the overlay, the ink and the burn-in,
   with a test asserting the reach is wider than the mark. The prompt is told the marks by kind, carried
   on the capture so it cannot outlive the picture. `--probe-ink` (18 checks, in the gate) proves the
   inertness off the live panel and proves the marks are on the display *and* out of every capture by
   flipping `sharingType` and capturing either side of it — 6528 ink pixels allowed, 0 with none;
   `--render-ink` draws one of every mark to look at. **Unseen, and his to judge:** the ink on his own
   screen during a real turn — whether marks that outlive the gesture read as help or as clutter, and
   whether they should fade rather than vanish.
2. **Language breadth.** `--probe-stt` already enumerates `supportedLocales` and `installedLocales`, and
   `SpeechVoices` ranks English female voices only. A picker plus a de-ranking fix, no new transport.
   He speaks en-IN — worth checking whether any installed voice covers it before promising it.
3. **Take back control mid-action.** Their rule is "move the mouse or speak and you are back". Chunks
   already drops a waiting plan round when a new sentence arrives; what is missing is cancelling the
   **in-flight** turn and the outstanding card on the same signal.
4. **The Chrome extension.** The one real capability gap and the largest lift: an extension, a
   native-messaging host, and a second policy surface for a browser Chunks currently reaches only through
   Accessibility — which, measured, cannot see inside a page's controls at all.
   **He answered the question on 2026-11-03:** Chunks should be able to do in his signed-in browser what
   HeyClicky and Qoder do — run the task while he watches it happen on his own screen, at whatever
   length and complexity, and everything a person could do in that tab. So the decision is made and the
   remaining work is engineering: (a) the extension + native-messaging host, (b) a DOM-level target
   channel that reaches the controls Accessibility does not publish, (c) a policy surface for a
   *signed-in* browser, which is the part that must not be improvised — the existing rules already
   refuse secure fields, Keychain and password managers, and "send / pay / delete" is always asked;
   those have to survive translation into DOM terms rather than be replaced by a new, weaker gate, and
   (d) a long-task surface, because a job that runs for minutes while he watches is the same problem as
   3.14's queue and should be the same mechanism, not a second one.
   This is the largest item in the file. It is not a session's work and it should not be started before
   3.18 items 1–3 are done.

**A/B, measured 2026-11-03 (nonce `AB-30261-1793724568`)** — the same five production-prompt turns, both
brains, one minute apart on his machine: the **cloud chain served 6 turns in 83 s and gave nothing at
all on 2** (64 s and 70 s dead ends across four attempts each), while the **offline tier answered the
plan question in 1.9 s with no malformed tag and nothing swallowed by the parser**. That is not an
argument that a 2B model is better; it is an argument that **a brain that answers is worth more than a
brain that is better and is not there**. It is the measured case for the fallback he asked for, and the
reason `scripts/ab-test.sh` exists: the cloud side's numbers move by an order of magnitude within an
hour on a free key, so any claim about which tier to use has to be re-measured rather than remembered.

5. **Self-updating.** Already Tier 4 (Sparkle 2). Blocked on Developer ID and notarisation, which need
   his enrolled account, not code.

**Will not be copied, and why:** named agents, agent rosters, handoff jobs and agents that remember — the
multi-agent layer he scoped out on day one, and the thing that would make this a service rather than an
app. Connectors and hosted speech models — a proxy is the one architecture that triggers Google's CASA
assessment and puts the sellability argument at risk. Documents beside the chat — an artifact, on the ❌
list. **Where Chunks is ahead, measured against the same list:** BYOK with no account, no billing and no
quota emails; an offline tier they do not have; 818 tests and a 48-check gate they do not publish; memory
with provenance and a secret sweeper, where their changelog says "remembers"; it never moves his pointer,
where their drive does; and every claim about an act derived from the effect on screen rather than from a
return code — which is the difference between the two features above and the three bugs his screenshots
found last night.

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
