# Chunks — Build Plan v2

A native macOS **notch-resident** companion that **sees your screen, explains it, and helps you act on it** — by voice. Single assistant. You are its main preference.

**Status:** v3 scope correction 2026-10-03 — see **§11**. v2 stands for everything §11 doesn't override.
**Phase 0:** complete — Chunks can see your screen for $0 (ground-truth tested, see §6).

---

## 0. Locked decisions v2

| Area | Decision (v2 = current) |
|---|---|
| Shell | **Notch-anchored.** `NotchRootView`-style NSPanel bulging out from the notch + HUD chips + full window. MenuBar `NSStatusItem` is fallback on non-notch Macs. No dock icon (`LSUIElement`). |
| Brain | **Pluggable provider registry.** Gemini (Google Pro OAuth → free API tier, default), OpenCode Zen, Anthropic, OpenAI, Ollama. One-click switch. Learned from Utsuwa: true BYOK + fully-offline path, no proxy lock-in. |
| Scope | **HeyClicky parity minus parallel builders.** Screen annotate+explain, region + full-screen modes, `[POINT]` cursor search, voice reply, permissioned computer-use, routines, skills-as-context. **Out:** parallel sub-agents, multi-agent website/app builders, skills marketplace economy, proactive background surveillance. Single assistant does one task at a time, declares its own `<ARTIFACTS>`. |
| Voice in | `SpeechTranscriber` (macOS 26+, on-device, free) primary → whisper.cpp fallback. Desktop push-to-talk `Ctrl+Shift+Space` (Utsuwa/Clawster convention). |
| Voice out | **Kokoro** default → `AVSpeechSynthesizer` toggle. Utsuwa confirms local Kokoro-FastAPI pattern works. |
| Computer use | **Permissioned control of Mac + all apps (Clawster-style).** `AXTDriver` + tool layer (open app, timer, volume, Focus block) + per-turn **Allow / Not now** consent card + per-app toggles. `Always allow` off by default. Background-only delivery + no-focus-steal `PolicyGate` I write. |
| Memory + assistant | **First-class, highest priority.** Memory (facts/preferences/corrections, 2 KB cap) + Notebook (saved explanations) + **ReminderStore + Scheduler (launchd) + Planner (day brief)**. You are the main preference; everything resolves to you. See §4. |
| Presence | **Moods + small physical body, in-app only, late phase.** ~10 moods in notch window/HUD bubbles (not 14 to start). No always-on desktop pet. `IDENTITY.md`/`SOUL.md`-style personality files, local. Learned from Utsuwa/Clawster, scoped to Chunks window per req §5–6. |
| Pointer | **Cursor-trailer underneath cursor** (not behind it). Small badge/dot at +14–20px y-offset, follows cursor, easily identifiable, auto-retracts. Replaces HeyClicky's foreground cursor that caused black Loom captures. |
| Platform | Native Swift/SwiftUI. No Electron/Tauri. |
| Base | Fork `farzaa/clicky` (MIT) — reuse NSPanel overlay, CGEvent tap, ScreenCaptureKit, SSE plumbing. |
| Hotkeys | `Cmd+Shift+Space` chat · `Cmd+Shift+/` snap+ask · `Cmd+Shift+A` full panel (Clawster convention, proven). `Cmd+M` memory viewer. |
| Explicitly out | Parallel sub-agents/builders, skills marketplace, desktop pet on screen, proactive surveillance, code-gen agent teams, Docker schedulers, OAuth broker business. |

**Target machine:** MacBook Air M5 · 10 cores · 16 GB · arm64 · macOS 27.0 · single 2880×1864 Retina display (notch).

---

## 1. The provider registry — the core abstraction

Unchanged from v1. Everything hinges on this for paid↔free switching. Each provider declares a **capability profile**; Chunks degrades gracefully.

```swift
struct BrainProvider: Identifiable {
    let id: String
    let displayName: String
    let transport: Transport      // .openAICompatible | .anthropicMessages | .geminiInteractions | .ollama
    let baseURL: URL
    let auth: AuthKind           // .none | .bearerKey | .oauthGoogle | .headerKey(name:)
    let supportsVision: Bool
    let supportsStreaming: Bool
    let models: [BrainModel]
    let freeTier: Bool
    let notes: String
}

struct BrainModel {
    let id: String
    let displayName: String
    let visionCapable: Bool?     // nil = unknown, verify at runtime
    let costPerMTokIn: Double
    let costPerMTokOut: Double
}
```

### Why `visionCapable: Bool?` and not `Bool`

`nil` = unknown; app **probes at runtime** with a 1×1 test image. Settings shows a live matrix. Utsuwa validates this approach: vision-gating by provider flag + model-name check, never silently send a text-only model a screenshot.

### Graceful degradation

1. Annotated region / "explain this" → **needs vision**.
2. If selected provider lacks vision → auto-route to last vision-capable provider or say plainly: *"Muse Spark can't see images — switching to Gemini."*
3. Never silently send text-only model a screenshot.

**Anti-pattern avoided:** HeyClicky instructs *"say the blocker instead of pretending it ran."* Same rule here, enforced in code not prose.

---

## 2. Model catalogue (verified 2026-09-29 via `opencode.models`)

### OpenCode Zen — free tier

| Model ID | In/Out ($/MTok) |
|---|---|
| `opencode/muse-spark-1.3-contributor-free` | 0 / 0 |
| `opencode/big-pickle` | 0 / 0 |
| `opencode/longcat-2.5-preview-free` | 0 / 0 |
| `opencode/nemotron-3.5-lightning-free` | 0 / 0 |
| `opencode/ling-3.0-flash-fin-free` | 0 / 0 |
| `opencode/mimo-v2.6-flash-free` | 0 / 0 |

### OpenCode Zen — cheap paid tiers worth knowing

| Model ID | In/Out | Note |
|---|---|---|
| `opencode/gpt-6-luna` | 0.10 / 0.50 | 272k context. Best price/quality here |
| `opencode/glm-5.3-flash` | 0.15 / 0.50 | |
| `opencode/qwen3.8-flash` | 0.15 / 0.47 | |
| `opencode/deepseek-v4.1-flash` | 0.30 / 1.20 | |
| `opencode/gemini-3.5-flash-lite` | 0.30 / 2.50 | |
| `opencode/muse-spark-1.3` | 1.25 / 4.25 | Paid sibling of the free model |

### Your Google Pro path

- **With Google AI Pro:** Gemini CLI-style OAuth sign-in, no API key, generous quota.
- **After it lapses:** Gemini Developer API free tier from AI Studio.
- **Always:** direct API key if you prefer.

Gemini is the default provider and the auto-fallback for vision.

---

## 3. Architecture v2

```
┌──────────────────────── Chunks.app (Swift/SwiftUI) ───────────────────────┐
│                                                                            │
│  NotchShell ─────── NSStatusItem + notch-anchored NSPanel (bulging window) │
│       │            fallback: menu-bar panel on non-notch Macs               │
│       ├── SettingsPane   · provider picker · voice picker · hotkeys        │
│       ├── TranscriptHUD  · streaming text, phase indicator, chips          │
│       └── PresenceView   · (P7) mini-body + mood + speech bubbles IN-APP   │
│                                                                            │
│  CaptureEngine ──── ScreenCaptureKit, 2880×1864, single display           │
│       │            CoordinateSpace: one authority for Retina scaling       │
│       ▼                                                                    │
│  AnnotationOverlay ── full-screen NSPanel, joins all Spaces, non-activating │
│       │   Tools: pen · arrow · ellipse(circle) · rect(highlight) · clear   │
│       │   Undo stack · live-region preview · "explain this" submit          │
│       ▼                                                                    │
│  RegionResolver ──── strokes/ellipses → bbox → tight crop + padded context │
│       ▼                                                                    │
│  PromptBuilder ───── modes: .wholeScreen | .region(box) | .concept         │
│       │            emits: image(s) + question + [POINT:x,y:label] contract │
│       ▼                                                                    │
│  BrainClient ────── provider registry → transport adapter → SSE stream      │
│       │              Interactions API, store:false, backoff + fallback chain│
│       ├──► ResponseParser · [POINT:x,y:label] · <SAY> · <MEMORY>           │
│       │                   · <REMINDER> · <ARTIFACTS> · <ROUTINE>            │
│       ├──► TrailerEngine  · badge UNDER cursor (+14–20px), follows, retract│
│       ├──► TTSEngine      · Kokoro (default) | AVSpeechSynthesizer         │
│       └──► ActionEngine   · single-task, declares <ARTIFACTS>              │
│                                                                            │
│  DictationController ─ CGEvent tap, hold-to-talk / toggle / wake word       │
│                                                                            │
│  ┌── Memory + Assistant (Phase 1, refined every phase) ────────────────┐   │
│  │  MemoryStore  · markdown, hand-editable, 2 KB cap, git-friendly     │   │
│  │  MemoryInjector· curated slice prepended to EVERY prompt             │   │
│  │  MemoryWriter · model emits <MEMORY>; app validates + merges        │   │
│  │  SecretSweeper· regex+keyword reject before every write             │   │
│  │  Notebook     · saved explanations, searchable, on-demand only      │   │
│  │  ReminderStore· [reminder:..] tags + poll loop, survives reload     │   │
│  │  Scheduler    · launchd LaunchAgents, read-only default             │   │
│  │  Planner      · day brief from calendar + reminders + memory        │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                            │
│  ┌── ComputerUse (Phase 5, permissioned) ─────────────────────────────┐    │
│  │  ActionEngine → ToolLayer → AXTDriver → PolicyGate → ConsentGate   │    │
│  │  ToolLayer: open app, timer, volume, Focus block (Clawster-style)  │    │
│  │  AXTDriver: AX snapshot → element_token → AXPress/setValue         │    │
│  │             window-scoped pixel fallback (no real-cursor move)     │    │
│  │  PolicyGate: blocks desktop scope, ⌘L, ⌘1..9, ⌘⇧G, ⌥←/→, ctrl+tab │    │
│  │  ConsentGate: Allow / Not now per turn + per-app toggles           │    │
│  └────────────────────────────────────────────────────────────────────┘    │
└────────────────────────────────────────────────────────────────────────────┘
```

Single assistant, one task at a time. No sub-agents. No parallel builders.

---

## 4. Memory + personal assistant — the core feature

### The problem with the obvious design

1. **Prompt bloat** — unchecked memory drowns the question and costs every turn.
2. **Secret leakage** — model happily writes API keys/passwords you read aloud.
3. **Drift** — nobody prunes; prose contracts ("prune stale") are followed inconsistently.

### The design: app owns the file, model proposes the edits

```
Turn N:  MemoryInjector prepends CURATED slice ──┐
                                                 ├──▶ prompt ──▶ model
Turn N:  model replies with optional <MEMORY> ───┘                │
                                                                  ▼
                                        MemoryWriter parses, validates, merges
                                                                  ▼
                                                  MemoryStore (markdown on disk)
```

**Model never writes the file.** Utsuwa proves the same principle at scale: app is game master, LLM suggests bounded deltas, app clamps and applies. Extraction fallback (second forced-JSON call) covers small models that skip the block.

### Storage: plain markdown, deliberately

`~/Library/Application Support/Chunks/memory.md`

```markdown
# Chunks Memory
Human-editable. Chunks reads this before every turn and proposes edits.
Never store passwords, tokens, or API keys here.

## You
- Prefers short answers, no preamble          (2026-09-29)
- Working on a SwiftUI menu bar app           (2026-09-29)
- Uses Figma, not Sketch                      (2026-09-29)

## Corrections
- Don't call it "Spotlight" — means Raycast   (2026-09-29)

## Standing preferences
- Explain code before explaining concept       (2026-09-29)

## Schedule (managed by Scheduler, read-only here)
- Standup weekdays 09:30
- Gym Tue/Thu 18:00
```

Plain text: readable, greppable, git-friendly, survives app deletion. No DB migration. (Clawster uses LanceDB + Utsuwa uses IndexedDB+vectors; Chunks stays markdown for the hot path — simpler, hand-editable, zero-dependency. Semantic vector search is a P8 option, not a requirement.)

### Tiers

| | **Memory** | **Notebook** | **Reminders/Schedules** |
|---|---|---|---|
| Holds | Facts about you, preferences, corrections | Concepts explained to you | Timers, reminders, recurring jobs, day plan |
| Size | Hard cap ~2 KB (~40 lines) | Unbounded | Unbounded, one file per job |
| Injected | Every turn | On demand (search) | On demand (due + today's slice) |
| Lifetime | Continuously pruned | Append-only, you delete | Fires once / recurs per schedule |
| Store | `memory.md` | `notebook/` markdown | `reminders.json` + `~/Library/LaunchAgents/com.chunks.*.plist` |

**Notebook is the sleeper feature.** Every explanation can be saved ("Want me to remember this as 'Debug Navigator'?"). Six months in, a personal knowledge base built from your own questions.

**Reminders:** model emits `[reminder:5min]...[/reminder]` or natural "remind me in 10 min" → client-side fallback schedules it. Poll loop every 10s, atomic claim so one window fires, missed-while-asleep surface on wake. Fired reminder enters as system event (no relationship/sentiment side effects — Utsuwa rule, adopted).

**Scheduler:** launchd LaunchAgents (not in-process cron — survives sleep, coalesces on wake). Jobs read-only by default (*"every weekday 9:05 tell me what's new on my screen"* → notification). Actions require per-job opt-in. HeyClicky's own rule adopted: routines never silently escalate to writes.

**Planner:** day brief = today's calendar + due reminders +Memory slice. Local-first; calendar via EventKit (no OAuth broker). Google/Slack/Linear later via official MCP servers (free, vendor-run), Ask-before-run default.

### The write contract

```
<MEMORY>
{"add":{"section":"You","fact":"Uses Raycast, not Spotlight"},"prune":["..."]}
</MEMORY>
```

`MemoryWriter` enforces, in order:

1. **Reject secrets.** Regex (`sk-`, `ghp_`, `AKIA`, long base64/hex) + keywords. Log, never write.
2. **Enforce cap.** Over 2 KB → refuse adds, surface "memory full — prune something?" Never silently truncate.
3. **One line per fact.** Reject multi-line.
4. **Dedupe.** Normalize + skip near-duplicates (cosine ≥0.9 if vectors enabled in P8, else normalized-text match).
5. **Timestamp everything.** `(YYYY-MM-DD)`.
6. **Never rewrite header/scaffolding.**

### Recall

- **Always:** curated Memory block, verbatim.
- **On demand:** Notebook lookup via one extra call when question references prior work.
- **Explicit:** `Cmd+M` memory/notebook/reminder viewer. Chunks is never the only way to edit.

---

## 5. The hardest engineering problems

### 5.1 Retina coordinate authority

Screenshots 2880×1864 px vs AX 1440×932 points. Single `CoordinateSpace` type, one conversion function at the boundary. Round-trip tests 1x/2x/3x. Trailer offset (+14–20px y) lives here too — one place to get "underneath but identifiable" right.

### 5.2 Notch-anchored overlay that never steals focus

`NSPanel` `.nonactivatingPanel` + `canJoinAllSpaces` + `fullScreenAuxiliary`, never `NSApp.activate()`. Notch panel + annotation overlay + trailer all share this rule. Fork already solved most of it (`OverlayWindow.swift`, 881 lines) — reuse, add notch anchor + trailer layer.

### 5.3 No-focus-steal policy gate + consent

Input ladder AX → per-window event → per-PID event → global HID. Only the last moves the real cursor. `PolicyGate` mirrors HeyClicky's closed Rego logic:

```
DENY  scope == "desktop"
DENY  hotkey ⌘/ctrl + L
DENY  hotkey ⌘ + [1-9] / [ ] / ⌘⇧[ ⌘⇧]
DENY  hotkey ⌘ + ⌥ + ←/→ / ⌃ + Tab
DENY  hotkey ⌘⇧ + G
ALLOW everything else, background-delivered only
```

Plus `ConsentGate`: observation free; any input needs Allow/Not-now for that turn. Per-app toggles. `Always allow` off by default.

### 5.4 Trailer that tracks without jitter

CGEvent-tap cursor polling + display-link follow, offset transform in `CoordinateSpace`, fade/retract on idle. Must not draw over fullscreen capture (the bug that forced HeyClicky v1.0.52 to remove its cursor) — trailer hides during capture.

---

## 6. Phase plan v2

### Phase 0 — Vision spike ✅ COMPLETE

| Probe | Result |
|---|---|
| Zen free + image → `/chat/completions` | ❌ 403 `FreeTierError` |
| Zen free + image → `/responses` | ❌ 403 `FreeTierError` |
| Zen free, text only | ❌ 403 → lock is on tier, not images |
| Zen paid (`gpt-6-luna`, `muse-spark-1.3`) | ❌ 402 `Insufficient account funds` |
| Gemini `models?pageSize=100` | ✅ 200 — 61 models |
| Gemini `gemini-2.5-flash:generateContent` | ❌ 404 — retired |
| **Gemini Interactions + synthetic probe.png** | ✅ **200 — 100% correct** |
| **Gemini Interactions + real 3420×2214 shot** | ✅ **200 — 1,066 image tokens** |
| **Gemini Interactions, SSE streaming** | ✅ `step.delta` ×4, clean |

Ground truth (red square / green triangle / blue circle on pale yellow): perfect, incl. triangle orientation. Real screenshots: correctly ID'd Terminal + OpenCode session + project name.

| Metric | Measured |
|---|---|
| Full screenshot cost | 1,066 image tokens (3420×2214 PNG, 1.7 MB) |
| Per turn | ~1,085 in + ~100 out ≈ 1,200 tokens |
| Latency | 7.4s (`3.1-flash-lite`) · 12.4s (`flash-lite-latest`) · 18.4s (`3.6-flash`) — SSE makes perceived much lower |
| Cost | $0 Gemini free · ~$0.0002/turn Zen vision · ~$1/mo at 100 turns/day |

API: `POST .../v1beta/interactions` + `Api-Revision: 2026-05-20`, `{"store":false,...}`, `?alt=sse` + `"stream":true` for streaming. `previous_interaction_id` for multi-turn; JSON-schema structured output replaces `<MEMORY>` regex later.

Constraints: 503 high-demand on newest flash (~50%) → backoff + fallback chain (`3.8-flash → 3.6-flash → 3.1-flash-lite → flash-lite-latest`); 5 req/min free-tier → client token-bucket queue.

### Phase 1 — Notch shell + explain + memory core (3–4 days)

> **Progress (2026-10-04).** Done: the result-tag protocol (`<SUMMARY>`, `<DONE_TITLE>`,
> `<NEXT_ACTIONS>`, plus `[POINT:none]`) in `ResponseParser`/`AnswerStreamer`; the notch shell
> — `NotchGeometry` (pure, 14 cases, checked against the measured 185x33.5 pt cutout) and
> `Sources/Chunks/HUD/` — is on screen and driven by the live turn: streamed card, chips that
> start a new turn, `<SUMMARY>` spoken on completion. Memory is closed the loop: every prompt
> carries the injected block, a `<MEMORY>` proposal goes through `MemoryStore.propose` after
> the reply, and the outcome lands as a footnote on the card (`MemoryReport`, 12 cases). Still
> open in this phase: the HUD's pixels need a human, and `<NOTE>` offers have no Notebook to
> save into yet.

- Fork `farzaa/clicky`, rename Chunks, new bundle id + icon
- Strip: ElevenLabs, AssemblyAI, Cloudflare Worker, PostHog
- `NotchShell` (notch panel + fallback menu-bar) + `TranscriptHUD` + chips
- `CaptureEngine` + `CoordinateSpace`
- `BrainClient` registry + streaming + `<SAY>` extraction
- `MemoryStore` + `MemoryInjector` + `MemoryWriter` + `SecretSweeper`
- PTT via CGEvent tap, `Cmd+M` viewer, hotkeys `Cmd+Shift+Space / / /A`
- **Milestone:** summon from notch, ask "what am I looking at?", hear answer. "I use Raycast" sticks next turn.

### Phase 2 — Annotate (3 days) ⭐ headline

- Overlay NSPanel, pen/arrow/ellipse/rect + undo + clear
- `RegionResolver` → tight crop + padded context crop
- Two submits: *"explain this"* (crop) / *"in context of my screen"* (full + crop)
- Notebook save offer, one-tap accept
- **Milestone:** circle → spoken explanation → saved.

### Phase 3 — Trailer point (1–2 days)

- Parse `[POINT:x,y:label]`, multi-point
- Trailer badge under cursor (+14–20px), follow + caption, auto-retract, hidden during capture
- **Milestone:** "where's the run button?" → trailer glides there + says it.

### Phase 4 — Voice (1.5 days)

- `SpeechTranscriber` + vocabulary biasing, whisper.cpp fallback
- Kokoro + `AVSpeechSynthesizer` toggle, barge-in
- **Milestone:** hands-free local conversation.

### Phase 5 — Permissioned act (3 days)

- `ToolLayer` (open/timer/volume/Focus) + `AXTDriver` (AX → window-pixel → page)
- `PolicyGate` + `ConsentGate` (Allow/Not-now per turn, per-app toggles)
- **Milestone:** "click the blue button in this app" → card → clicks, real cursor never moves.

> **Progress (2026-10-04).** Built: `[ACT:…]` / `[DO:…]` parsed out of the stream into
> `ActionRequest` / `DoRequest`; `ScreenshotGeometry` (image fractions → AppKit → AX points);
> `AXTDriver` (layer-0 window hit test → `AXUIElementCopyElementAtPosition` → pressable ancestor →
> `AXPress`, never warps the pointer); `PolicyGate`; a one-question `ConsentGate`; and the
> **Allow / Not now** row on the notch card that both kinds of request share. The tool half is
> open-app + set-volume — a timer is deliberately left to Phase 6's `ReminderStore` rather than
> built twice, and Focus needs a Shortcut name the user owns, which has no settings surface yet.
> Verified on live hardware: the *refusal* path via `chunks --probe-ax`, and the volume write via
> a no-op write to the real output device. Still unobserved: a successful press, and a launched
> app — every app on screen during development was Electron, so every point resolved to an
> unpressable `AXGroup` and Chunks correctly refused.

### Phase 6 — Reminders + scheduler + planner (2 days)

- `ReminderStore` + poll loop + `[reminder:]` tags + natural-language fallback
- launchd LaunchAgents, read-only default, per-job action opt-in
- `Planner` day brief (calendar EventKit + reminders + memory)
- **Milestone:** "remind me in 10 min" fires; weekday 9:05 brief notifies, never writes silently.

### Phase 7 — Presence in-app (2 days, late)

- Mood engine (~10 moods), mini-body in notch window/HUD only, speech bubbles, `IDENTITY.md`/`SOUL.md` personality edit
- Never a desktop pet; hidden during fullscreen capture
- **Milestone:** moods shift with day, body reacts in-window, no screen clutter.

### Phase 8 — Memory depth (ongoing)

- Notebook search tuning, compaction proposals near cap, optional per-project scopes, optional local embeddings (Utsuwa-style 384-d) if markdown search proves insufficient.

---

## 7. File layout v2

```
chunks/
├── Chunks.xcodeproj
├── CLAUDE.md / AGENTS.md
├── Sources/
│   ├── App/                  ChunksApp
│   ├── NotchShell/           NotchPanelManager, SettingsPane, TranscriptHUD, Chips
│   ├── Presence/             (P7) MoodEngine, MiniBodyView, Bubbles, PersonalityFiles
│   ├── Capture/              CaptureEngine, CoordinateSpace
│   ├── Annotate/             OverlayWindow, AnnotationCanvas, ToolPalette, RegionResolver
│   ├── Point/                TrailerEngine, TrailerOverlay
│   ├── Voice/                DictationController, STTProvider, TTSEngine
│   ├── Brain/                BrainClient, ProviderRegistry, Transports/, PromptBuilder,
│   │                         ResponseParser, CapabilityProbe
│   ├── Memory/               MemoryStore, MemoryInjector, MemoryWriter,
│   │                         SecretSweeper, NotebookStore, NotebookSearch
│   ├── Assistant/            ReminderStore, SchedulerJobStore, LaunchAgentPlanner, Planner
│   ├── Action/               ToolLayer, AXTDriver, ActionEngine, PolicyGate, ConsentGate
│   └── DesignSystem/
├── Tests/
│   ├── CoordinateSpaceTests · TrailerOffsetTests
│   ├── PolicyGateTests · ConsentGateTests
│   ├── RegionResolverTests · ResponseParserTests
│   └── MemoryWriterTests · ReminderTests · PlannerTests
└── docs/
    ├── ARCHITECTURE.md · PROVIDERS.md · MEMORY.md · PRESENCE.md
```

---

## 8. What we learned from Clawster + Utsuwa (2026-09-30)

- **Clawster** (`clawster.pet`, MIT, Electron, 30★): validates pet + hotkeys + onboarding wizard + local tool classification (Qwen 1.5B ~200ms) + LanceDB memory. Adopt: hotkey conventions, wizard permission flow, Focus tools. Reject: Electron weight, cloud-chat dependency, desktop-pet-always-on.
- **Utsuwa** (`utsuwa.ai`, AGPL-3.0 since 0.12.1 — learn, don't paste): validates BYOK + offline, app-owns-numbers + clamped LLM deltas + extraction fallback, local embeddings (384-d MiniLM), MCP with Ask-before-run + hardening + allowlists, Kokoro-local TTS, reminder-as-system-event. Adopt patterns; do not copy code (AGPL viral). Reject 3D/VRM/AR weight for Chunks.
- Both confirm: markdown hot-path (Chunks) beats DB hot-path for hand-editability; vectors optional later. Both confirm consent gating is the hard part, not the model.

See `CLAWSTER-RESEARCH.md` and `UTSUWA-RESEARCH.md` for full notes.

---

## 9. Risks, honestly (v2)

| Risk | Severity | Mitigation |
|---|---|---|
| Memory bloat / prompt drown | High | 2 KB cap, refuse-at-cap + ask, Notebook never auto-injected |
| Secret into memory | High | `SecretSweeper` structural, model proposes / app disposes |
| AX trees missing (canvas/Qt) | High | Window-pixel fallback + honest "can't see controls" |
| Trailer jitter / capture-black (HeyClicky v1.0.52 bug) | Medium | Display-link follow, hide during capture, offset in one place |
| Notch geometry across Macs | Medium | Fallback menu-bar panel, Spaces/fullscreen testing |
| On-device STT on 16 GB | Medium | SpeechTranscriber M5 + whisper.cpp fallback, measure P4 |
| Scope creep to agent teams | Medium | Hard rule: single assistant, no sub-agents, no marketplace |
| Zen vision claim false | Low now | Gemini fallback proven; registry degrades loudly |
| AGPL contamination (Utsuwa) | High if copied | Learn patterns only; MIT fork stays clean; no Utsuwa code vendored |
| Fork frozen (20 commits) | Low | 7.7k lines + good AGENTS.md = feature |

---

## 10. Explicitly rejected

- Electron/Tauri shell (~150 MB + CPU floor for a notch app).
- Bundling Codex/Claude Code (saves 216 MB + whole safety surface; single-assistant rule).
- Python sidecar (native covers it).
- Self-hosted OAuth broker (official MCP servers free, vendor-maintained).
- Docker cron (launchd catches up after sleep, real logs).
- Skills marketplace / companion marketplace (a business, not a feature).
- Always-on desktop pet (req: trailer under cursor + body in-app only).
- Copying Utsuwa code (AGPL). Patterns only.

---

## 11. v3 — HeyClicky parity (scope correction, 2026-10-03)

User direction: *"I just wanted the HeyClicky exact replica without the sub agents / sub Clickys."* v2 removed too much. v3 restores the full HeyClicky surface and cuts **only** the multi-agent layer.

### Locked decisions v3 (these override §0 where they differ)

| Area | v3 decision |
|---|---|
| Work engine | **Native single-agent tool loop.** Gemini/OpenAI function-calling drives Chunks' own tools (app control, AX input, read/search files, calendar, MCP). One task per turn, never spawns, no Codex binary, no `multi_agent`. |
| Output | **No generated files.** `welcome.html`-style artifacts, PDFs, decks, and the `<ARTIFACTS>` tile pipeline are out. The agent may *read* files and screen content as context; answers land in the panel + voice. |
| Skills | **Bundled skills as context only.** ~15 curated `SKILL.md` domains (portable from the MIT `hermes-agent` catalog HeyClicky itself vendored). Model picks by intent; no names shown to the user. **No marketplace, no authoring UI, no sharing.** |
| Persona | **Full companion layer, in-window.** Notch face + ~10 moods + speech bubbles + sound design (`agent-done`, `needs-you`, `listening`) + `IDENTITY.md`/`SOUL.md`. Not a desktop pet, no procedural gacha wardrobe/portraits. |
| Voice | Two paths, as HeyClicky has: **PTT dictation** (on-device) and **realtime duplex conversation** — `gemini-3.8-live` over WebSocket on the same key (§6 discovery below), with the local cascade as fallback. |
| Safety | Two gates exactly as HeyClicky ships them: per-turn **Allow / Not now** consent, plus a permanent **`PolicyGate`** (background-only delivery, no desktop scope, focus-steal shortcuts denied). Gate 2 is not waivable. |
| Backend | **None.** No `api.heyclicky.com` equivalent, no model proxy, no turn-lease protocol, no Supabase, no billing/referrals/analytics. BYOK straight to the provider, `store:false`, Keychain. |

### What is now IN that v2 listed as OUT

Realtime duplex voice · bundled skills · tool-calling agent loop · read-only file + calendar context · sound design · routines with real task bodies · integrations via official MCP servers · onboarding permission wizard.

### Still OUT (the only things that remain removed)

Parallel sub-agents and agent teams · persistent named agents / Clicky roster / per-agent workspaces · skills marketplace and its authoring economy · server-decided proactive agents and background surveillance · generated artifact files · cloud model proxy, metering, billing, referrals · Electron/Tauri · Docker cron · bundled Codex/Claude Code · self-hosted OAuth broker · copying Utsuwa (AGPL) code.

### Feature parity matrix

| HeyClicky | v3 Chunks | Build cost |
|---|---|---|
| Notch + menu-bar shell, agent chips, HUD | ✅ adopt | `NotchShell` + chips on the fork's panels |
| PTT dictation, global hotkey, multi-language | ✅ adopt | mostly vendored already (`BuddyDictationManager`) |
| Realtime duplex voice + barge-in | ✅ adopt via `gemini-3.8-live` | Medium |
| Screen capture on hotkey, no raw screenshots stored | ✅ adopt (already built) | done |
| Scribble/annotate → explain region | ✅ adopt (already built) | done |
| `[POINT:x,y]` pointing | ✅ adopt as **trailer under cursor** (v1.0.52 killed the foreground cursor for black captures — don't re-import that bug) | Small |
| Computer use, background-only, Rego-gated | ✅ adopt as `PolicyGate` + `ConsentGate` + action-honesty fields (`path`/`verified`/`effect`/`escalation`) | **Large — the hard part** |
| `<SUMMARY>` → TTS, `<DONE_TITLE>`, `<NEXT_ACTIONS>` chips | ✅ adopt | Small (parser exists) |
| `<ARTIFACTS>` file tiles | ❌ **out** (no generated files) | — |
| `<ROUTINE>` + cron backend | ✅ adopt, launchd instead of server cron | Medium |
| Codex subprocess per turn + turn-lease protocol | ❌ out — replaced by native tool loop | — |
| Per-agent `AGENTS.md` memory | ✅ single user-level `memory.md` (already built) | done |
| Skills marketplace (200 skills, 118 authors) | ❌ out; bundled set only | Small |
| Procedural faces, `hairstyle: "Twilight swirl"` | ❌ out; fixed notch body + moods | Small |
| Composio + custom MCP connectors | ✅ official vendor MCP servers only, Ask-before-run | Medium |
| Onboarding wizard, permission choreography, Screen-Recording-restart guide | ✅ adopt | Medium |
| Sparkle auto-update | ✅ later (needs a signed feed) | Small |
| PostHog + Sentry | ❌ out by design | — |
| Quiet while on a call / screen sharing; keep-awake while routines armed | ✅ adopt | Small |
| Free/Pro/Max metering | ❌ out — local-first, $0 on Gemini free tier | — |

### The one-key stack (restored from v1 — load-bearing for P-voice)

Enumerating the 61 models on the Gemini key turns up more than a brain. This is what makes "full HeyClicky voice" cheap:

| Model | Purpose | Phase |
|---|---|---|
| `gemini-3.5-transcribe`, `-transcribe-live` | STT | P4 |
| `gemini-3.8-flash-tts`, `-flash-lite-tts` | TTS with voice design | P4 |
| `gemini-3.8-live`, `gemini-3.1-flash-live-preview` | **Bidirectional realtime voice** (`bidiGenerateContent`) | P9 |
| `gemini-2.5-computer-use-preview-10-2025` | Google's computer-use model | P5 option |
| `gemini-robotics-er-2-preview` / `-streaming` | Spatial reasoning for pointing | P3 option |

So: **local-first, with Gemini as the zero-setup higher-quality path on the key you already have.**

### Revised phase plan

Phases P1–P8 in §6 stand. Three additions and one reordering:

- **P5 grows** from "click the button" to the full **agent tool loop**: `ToolRegistry` → function-calling → act → **re-snapshot and diff to verify** → report honestly. Tools: `open_app`, `ax_press`/`set_value`, `type_text`, `press_key` (gate-checked), `read_file`/`search_files` (scoped to user-approved roots, one-prompt-per-folder rule), `calendar_read`, `mcp_call`. Everything write-capable is behind consent; the loop never chains without per-step confirmation.
- **P9 — Realtime voice:** `gemini-3.8-live` WebSocket duplex, barge-in, server-side tool calls for calendar + reminders. Local cascade remains the offline default.
- **P10 — Skills + persona:** bundled `SKILL.md` set injected by intent, mood engine + notch body + sound design, `IDENTITY.md`/`SOUL.md` editable.
- **P11 — Integrations:** official Google Workspace / Slack / GitHub / Notion MCP servers, Ask-before-run default, results treated as untrusted data, per-server allowlist, secrets never inherited.
- **P12 — Onboarding + ship:** 3-step permission wizard (`PermissionFlowCoordinator` equivalent), Screen-Recording restart guidance, launch-at-login, Sparkle.

**Sequence note:** P5 (the agent loop) is now the critical path — it is the single biggest artifact and everything downstream (routines with real actions, integrations, presence reacting to work) touches it. P9–P12 are additive and can interleave.

---

## Next step

1. **Rewrite `AGENTS.md`'s "What Chunks is NOT"** — it currently forbids the agent tool loop, skills, and the companion layer that v3 now requires. That document is the scope authority for every future session, so it must match v3 before code is written.
2. **Rotate both keys** pasted during Phase 0 (Gemini → macOS Keychain, never files).
3. **Then build in order:** P1 notch shell (chips + `<SUMMARY>`/`<DONE_TITLE>`/`<NEXT_ACTIONS>` parsing) → P5 agent loop + `PolicyGate`/`ConsentGate` → P9 realtime voice → P10 skills/persona → P11 integrations.

Zen stays optional; skip the top-up (Gemini covers brain + STT + TTS + live + vision for $0).
