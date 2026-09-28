# Chunks — Build Plan

A native macOS menu-bar companion that **sees your screen, explains it, and helps you act on it** — by voice.

**Status:** planning complete, awaiting Phase 0 spike approval.

---

## 0. Locked decisions

| Area | Decision |
|---|---|
| Brain | **Pluggable provider registry.** Gemini (Google Pro OAuth → free API tier), OpenCode Zen, Anthropic, OpenAI, Ollama. Switchable in one click. |
| Voice in | `SpeechTranscriber` (macOS 26+, on-device, free) primary → whisper.cpp fallback |
| Voice out | **Kokoro** default → `AVSpeechSynthesizer` toggle in settings |
| Computer use | **Click + type, every action behind an Allow / Not now confirmation gate, plus a no-focus-steal policy layer I write.** Scope fixed — no additions here. |
| **Memory** | **First-class, the highest-priority feature.** Designed in Phase 1 and threaded through every later phase — not deferred to the end. See §4. |
| Platform | Native Swift/SwiftUI, `LSUIElement`, no dock icon |
| Base | Fork `farzaa/clicky` (MIT) — reuse its NSPanel overlay, CGEvent tap, ScreenCaptureKit, SSE plumbing |
| Explicitly out | No agents, no sub-clickys, no code generation, no artifact files, no skills marketplace, no agent memory workspaces |

**Target machine:** MacBook Air M5 · 10 cores · 16 GB · arm64 · macOS 27.0 · single 2880×1864 Retina display.

---

## 1. The provider registry — the core abstraction

Everything hinges on this, because you asked for easy switching between paid and free models. Each provider declares a **capability profile**, and Chunks degrades gracefully when a provider can't do something.

```swift
struct BrainProvider: Identifiable {
    let id: String
    let displayName: String
    let transport: Transport      // .openAICompatible | .anthropicMessages | .geminiGenerateContent | .ollama
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

Because I genuinely don't know yet. `nil` means *unknown*, and the app **probes at runtime**: send a 1×1 test image, record whether it errored. Settings shows a live capability matrix:

```
Provider              Vision   Streaming   Free
──────────────────────────────────────────────────
Gemini 3.1 Pro        ✅       ✅          —
Gemini (API key)      ✅       ✅          ✅
OpenCode Zen          ?        ✅          ✅ muse-spark-1.3-contributor-free
Anthropic Sonnet 5    ✅       ✅          —
OpenAI GPT-5.5        ✅       ✅          —
Ollama (local)        ✅       ❌          ✅
```

### Graceful degradation

The prompt builder asks each turn what it needs, then picks a brain:

1. User drew/annotated a region, or said "explain this" → **needs vision**
2. If the selected provider lacks vision, Chunks either auto-routes to the last vision-capable provider or says so plainly: *"Muse Spark can't see images — switching to Gemini."*
3. Never silently send a text-only model a screenshot and act like it worked.

**Anti-pattern I'm explicitly avoiding:** HeyClicky's instructions tell the agent to *"say the blocker instead of pretending it ran."* Same rule here, enforced in code not prose.

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

Full Zen catalogue is 36 models. The gateway also appears to be OpenAI-compatible, which means a single transport may cover Zen + OpenAI + Ollama.

### Your Google Pro path

- **With Google AI Pro:** Gemini CLI-style OAuth sign-in with the Google account — no API key, generous quota.
- **After it lapses:** Gemini Developer API free tier from AI Studio, no subscription needed.
- **Always:** direct API key if you prefer.

This is the cleanest "paid → free" transition available, which is why Gemini is the default provider and the auto-fallback for vision.

---

## 3. Architecture

```
┌──────────────────────── Chunks.app (Swift/SwiftUI) ───────────────────────┐
│                                                                            │
│  MenuBarPanel ───── NSStatusItem + borderless NSPanel (no dock icon)      │
│       │                                                                    │
│       ├── SettingsPane   · provider picker · voice picker · hotkeys        │
│       └── TranscriptHUD · streaming text, phase indicator                  │
│                                                                            │
│  CaptureEngine ──── ScreenCaptureKit, 2880×1864, single display           │
│       │            CoordinateSpace: one authority for Retina scaling       │
│       ▼                                                                    │
│  AnnotationOverlay ── full-screen NSPanel, joins all Spaces, non-activating │
│       │   Tools: pen · arrow · ellipse(circle) · rect(highlight) · clear   │
│       │   Undo stack · live-region preview · "explain this" submit          │
│       ▼                                                                    │
│  RegionResolver ──── annotation strokes/ellipses → bounding box            │
│       │            → crop strategy: tight crop + padded context crop        │
│       ▼                                                                    │
│  PromptBuilder ───── modes: .wholeScreen | .region(box) | .concept         │
│       │            emits: image(s) + question + [POINT:x,y:label] contract │
│       ▼                                                                    │
│  BrainClient ────── provider registry → transport adapter → SSE stream      │
│       │                                                                    │
│       ├──► ResponseParser  · strips [POINT:x,y:label:screenN] tags         │
│       │    · strips <SAY>…</SAY> blocks for TTS                             │
│       ├──► PointEngine     · bezier arc flight + caption, then retract     │
│       ├──► TTSEngine       · Kokoro (default) | AVSpeechSynthesizer        │
│       └──► ActionEngine    · when the reply carries a proposed action      │
│                                                                            │
│  DictationController ─ CGEvent tap, hold-to-talk / toggle / wake word       │
│                                                                            │
│  ┌── MemoryEngine (loaded from Phase 1, refined every phase) ──────────┐   │
│  │  MemoryStore  · plain markdown, hand-editable, git-friendly          │   │
│  │  MemoryInjector· curated slice prepended to EVERY prompt              │   │
│  │  MemoryWriter · model emits <MEMORY> blocks; app validates + merges │   │
│  │  Notebook     · concepts Chunks explained, searchable, revisitable   │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                            │
│  ┌── ComputerUse (Phase 5) ──────────────────────────────────────────┐    │
│  │  ActionEngine → AXTDriver → PolicyGate → Allow/Not-now card        │    │
│  │  AXTDriver: AX snapshot → element_token → AXPress/setValue         │    │
│  │             window-scoped pixel fallback (no real-cursor move)     │    │
│  │  PolicyGate: blocks desktop scope, ⌘L, ⌘1..9, ⌘⇧G, ⌥←/→, ctrl+tab │    │
│  └────────────────────────────────────────────────────────────────────┘    │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Memory — the core feature

You said memory is the main thing. That's the right call, and it changes the build order, so let me be explicit about it.

### The problem with the obvious design

The naive approach — let the model append whatever it wants to a notes file — fails in three specific ways:

1. **Prompt bloat.** If memory is injected into every prompt and it grows unchecked, you pay for it on every single turn *and* you drown the actual question in stale context.
2. **Secret leakage.** A model asked to "remember this" will happily write down an API key you read aloud, a password, or a customer name.
3. **Drift.** Nobody prunes. HeyClicky's own instruction contract has to *beg* the model to "prune anything stale or superseded" — prose that models follow inconsistently.

### The design: app owns the file, model proposes the edits

```
Turn N:  MemoryInjector prepends a CURATED slice  ──┐
                                                   ├──▶ prompt ──▶ model
Turn N:  model replies with optional <MEMORY> block ─┘                │
                                                                    ▼
                                          MemoryWriter parses, validates, merges
                                                                    │
                                                                    ▼
                                                    MemoryStore (markdown on disk)
```

**The model never writes the file.** It emits a structured block; the app decides what's admissible. That kills all three failure modes structurally rather than by asking nicely.

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
```

Plain text on purpose: you can read it, edit it, grep it, put it in git, and it survives every app update. No database, no migration, no opaque store. If Chunks ever gets deleted or replaced, this file is still yours.

### Two tiers, because they have different mechanics

| | **Memory** | **Notebook** |
|---|---|---|
| Holds | Facts about *you*, your projects, your preferences, your corrections | Concepts Chunks has *explained* to you |
| Size | Hard cap ~2 KB (≈40 lines) | Unbounded, grows over months |
| Injected | Every turn | Never — fetched on demand by search |
| Lifetime | Continuously pruned | Append-only, you delete entries |
| Why split | Must be tiny enough to always inject | Would destroy the prompt if always injected |

**The Notebook is the sleeper feature.** Every time Chunks explains something on your screen, it can offer to save it:

> *"Want me to remember this? I'll keep it as 'Debug Navigator' so you can ask me about it later."*

Six months in, you have a personal knowledge base built from your own questions — every Xcode panel you've been confused by, every keyboard shortcut you've forgotten, explained in context at the moment you needed it. That's the thing HeyClicky's Clickys approximate with per-agent `AGENTS.md` files, but scoped to *you* instead of split across agents.

### The write contract

The model may emit:

```
<MEMORY>
{"add":{"section":"You","fact":"Uses Raycast, not Spotlight"},"prune":["..."]}
</MEMORY>
```

`MemoryWriter` then enforces, in this order:

1. **Reject secrets.** Regex sweep for API-key shapes (`sk-`, `ghp_`, `AKIA`, long base64/hex blobs) plus a keyword blocklist (password, token, secret, credential, api key). Rejected facts are logged, never written.
2. **Enforce the cap.** Over 2 KB? Refuse new adds and surface "memory is full — prune something?" in the HUD. Never silently truncate.
3. **One line per fact.** Reject multi-line entries.
4. **Dedupe.** Normalize and skip near-duplicates rather than accumulating.
5. **Timestamp everything.** Append `(YYYY-MM-DD)`.
6. **Never rewrite the header or the `## You` scaffolding.**

### Recall

- **Always:** the curated Memory block, injected verbatim.
- **On demand:** before answering a question that touches prior work, one extra model call does a Notebook lookup. Only fires when the question looks like it references something previous ("remind me what that Xcode thing was").
- **Explicit:** `Cmd+M` opens the memory/notebook viewer for search, edit, and delete. Chunks must never be the only way to change memory.

### Why this is worth building first

Memory is what makes Chunks stop being a screenshot narrator and start being *your* tutor. Without it, every circle you draw starts from zero. With it, Chunks accumulates — and because the Notebook is yours in plain text, it's the one part of this that gets more valuable the longer you keep it, and survives everything else being deleted.

---

## 5. The three hardest engineering problems


### 5.1 Retina coordinate authority (get this wrong and everything drifts)

Screenshots are **2880×1864** (device pixels). The Accessibility API reports **1440×932 logical points**. macOS windows report in yet another frame. Mixing them is the single most common bug in this category — HeyClicky's own skill file says:

> *"Never feed an element's `frame` values into `x, y` — frames are screen-absolute logical points, pixel args are screenshot pixels."*

**Plan:** a single `CoordinateSpace` type that is the only thing allowed to convert. Every layer stores points; conversion to pixels happens once, at the boundary, in exactly one function. Round-trip tests at 1x/2x/3x.

### 5.2 Overlay that never steals focus

Annotations have to be drawn over *other* apps — including fullscreen ones. Requirements:
- `NSPanel` with `.nonactivatingPanel`, `canJoinAllSpaces`, `fullScreenAuxiliary`
- Never calls `NSApp.activate()`
- Mouse events accepted while `ignoresMouseEvents == false`, but the window must not become key
- On completion, fade out and release

This is the part the MIT fork already solved (`OverlayWindow.swift`, 881 lines). I'm reusing it, not reimplementing it.

### 5.3 The no-focus-steal policy gate

Every open-source computer-use driver has an input ladder: `AX action → per-window event → per-PID event → global HID/cursor`. **Only the last rung moves your real cursor**, and it's the only one a user would notice and hate.

I'm writing a `PolicyGate` that mirrors HeyClicky's closed-source Rego logic:

```
DENY  scope == "desktop"                      # moves real pointer
DENY  hotkey ⌘/ctrl + L                       # browser address bar — apps self-activate
DENY  hotkey ⌘ + [1-9]                        # tab switching — visibly flips user's tabs
DENY  hotkey ⌘ + [ ]  / ⌘⇧[ ⌘⇧]             # tab switching
DENY  hotkey ⌘ + ⌥ + ←/→                     # Chrome/Safari prev/next tab
DENY  hotkey ⌘⇧ + G                          # Finder "Go to Folder" — activates Finder
DENY  hotkey ⌃ + Tab                          # cross-browser tab switch
ALLOW everything else, background-delivered only
```

Plus the confirmation gate: observation is always free; any *input* tool requires an explicit **Allow / Not now** card for that turn. A `Always allow` toggle exists per-category but is **off by default**.

Rationale, from HeyClicky's engineering note on why this must be argument-level rather than name-level:

> "These aren't pure key events — the receiving app interprets 'user wants to type here' as activation intent and raises its window to be key."

---

## 6. Phase plan

### Phase 0 — Vision spike ✅ **COMPLETE**

**Verdict: Chunks can see your screen for $0. Confirmed with a ground-truth test.**

#### Probe log

| Probe | Result |
|---|---|
| Zen free + image → `/chat/completions` | ❌ 403 `FreeTierError` |
| Zen free + image → `/responses` (correct endpoint) | ❌ 403 `FreeTierError` |
| Zen free, **text only** — isolates image from lock | ❌ 403 → **lock is on the tier, not on images** |
| Zen paid (`gpt-6-luna`, `muse-spark-1.3`) | ❌ 402 `Insufficient account funds` |
| Gemini `models?pageSize=100` | ✅ 200 — **61 models** |
| Gemini `gemini-2.5-flash:generateContent` | ❌ 404 — *"no longer available to new users"* |
| **Gemini Interactions + synthetic probe.png** | ✅ **200 — description 100% correct** |
| **Gemini Interactions + real 3420×2214 screenshot** | ✅ **200 — 1,066 image tokens** |
| **Gemini Interactions, SSE streaming** | ✅ 200 — `step.delta` ×4, text assembled cleanly |

#### Ground-truth vision test

Synthetic image: pale-yellow background, red square upper-left, green right-angled triangle centre, blue circle lower-right. Asked the model to enumerate shapes, colours, positions.

Model's answer, verbatim:

> 1. **Square** — Colour: Red — Location: Upper-left region
> 2. **Triangle** (Right-angled triangle) — Colour: Green — Location: Center / middle region, with its horizontal top edge extending to the right
> 3. **Circle** — Colour: Blue — Location: Lower-right region
> *(Background: Pale yellow)*

**Perfect score, including the triangle's orientation.** Real screenshots tested across `gemini-3.1-flash-lite`, `gemini-flash-lite-latest`, and `gemini-3.6-flash` — all three correctly identified the foreground app (Terminal), the OpenCode session, and the project name on screen.

#### The numbers that matter

| Metric | Measured |
|---|---|
| **Real full-screen screenshot cost** | **1,066 image tokens** (3420×2214 PNG, 1.7 MB) |
| Total tokens per Chunks turn | ~1,085 in + ~100 out ≈ **1,200** |
| Latency, full screenshot | 7.4 s (`3.1-flash-lite`) · 12.4 s (`flash-lite-latest`) · 18.4 s (`3.6-flash`, 587 thought tokens) |
| Perceived latency | **Much lower with SSE streaming** — first `step.delta` arrives well before completion |

At ~1,200 tokens/turn, Chunks costs **$0 on Gemini's free tier**, or **~$0.0002/turn** on Zen's `deepseek-v4-flash-vision-exp` ($0.14/$0.28 per MTok) — roughly **$1/month** at 100 turns/day.

#### The API changed — use Interactions, not generateContent

Google has migrated new models to the **Interactions API**. `generateContent` returns *"no longer available to new users"* for retired models and is the wrong surface going forward.

```
POST https://generativelanguage.googleapis.com/v1beta/interactions
Headers: x-goog-api-key: <key>
         Content-Type: application/json
         Api-Revision: 2026-05-20

{ "model": "gemini-3.8-flash",
  "store": false,
  "input": [ { "type": "text",  "text": "..." },
             { "type": "image", "data": "<base64>", "mime_type": "image/png" } ] }
```

Streaming: append `?alt=sse` and set `"stream": true`. Event sequence observed:
`interaction.created` → `interaction.status_update` → `step.start` → `step.delta` ×N → `step.stop` → `interaction.completed`.

**Three properties that matter for Chunks specifically:**

- **`"store": false`** — nothing is retained server-side. Screenshots are not kept by Google. Verified working. This is the default we ship.
- **`previous_interaction_id`** — server-side multi-turn state, so we don't resend the whole transcript each turn.
- **JSON-schema structured output** — the `<MEMORY>` block from §4 becomes a validated schema rather than regex-parsed prose. Much more reliable.

#### Two operational constraints we must design for

Both were hit repeatedly during testing. Neither is a blocker; both are design inputs.

**1. `503 UNAVAILABLE` — "high demand".** The newest flash models (`3.8-flash`, `3.7`, `3.6`, `3.5-flash`) returned 503 on roughly half of attempts. This is contention, not a bad key.

→ `BrainClient` needs **exponential backoff + a model fallback chain**, e.g.
`gemini-3.8-flash` → `gemini-3.6-flash` → `gemini-3.1-flash-lite` → `gemini-flash-lite-latest`.
The registry already carries a model list per provider, so this is a natural fit.

**2. `Rate limit exceeded ... (limit: 5 req/min)`.** The free tier allows ~5 requests per minute per model.

→ A client-side **request queue** with per-model token-bucket limiting. At Chunks' interaction rate (a few turns per minute, user-initiated) this is rarely hit, but a queued background automation could trip it. Read-only automations must share the same queue.

#### The unexpected win: one key covers the whole stack

Enumerating the 61 models on this key turned up far more than a text/vision brain:

| Model | Purpose | Chunks phase |
|---|---|---|
| `gemini-3.5-transcribe`, `gemini-3.5-transcribe-live` | **STT** | Phase 4 |
| `gemini-3.8-flash-tts`, `gemini-3.8-flash-lite-tts` | **TTS with voice design** | Phase 4 |
| `gemini-3.8-live`, `gemini-3.1-flash-live-preview` | **Bidirectional realtime voice** (`bidiGenerateContent`) | Phase 4 |
| `gemini-2.5-computer-use-preview-10-2025` | **Google's own computer-use model** | Phase 5 |
| `gemini-robotics-er-2-preview` / `-streaming-preview` | **Spatial reasoning** | Phase 3 (pointing) |
| `gemini-3.8-flash` + `previous_interaction_id` | Brain + memory | Phases 1–7 |
| Google Search tool, Maps grounding, URL context | Built-in tools | Optional |

**This materially simplifies the plan.** Phases 4 and 5 no longer need Kokoro + a separate STT binary + Peekaboo as the *only* path. They become: *local-first, with Gemini as a zero-setup, better-quality fallback on the same key you already have.*

Revised voice stack:
- **STT:** Apple `SpeechTranscriber` on-device (free, private) → `gemini-3.5-transcribe` if quality is lacking → whisper.cpp if offline matters most
- **TTS:** Kokoro local (default) → `gemini-3.8-flash-tts` (free, natural, and it has *voice design* — pick a voice by description)
- **Realtime:** `gemini-3.8-live` via WebSocket if we want true duplex

#### Zen: still useful, still not free

Muse Spark 1.3 Free is genuinely multimodal (confirmed: `modalities.input: [text, image, video, pdf, audio]`, 1M context) — but **client-locked to the OpenCode app**, so Chunks can't reach it.

Zen's paid tier stays worth having for one reason: **30+ models on one OpenAI-compatible key**, including Claude and GPT, for when you want to *switch brains*. That directly serves the "switchable, paid→free" requirement.

⚠️ **Privacy flag, restated.** Zen's docs: *"Muse Spark 1.3 Contributor Free: …permission to use your prompts and completions to train future Meta models."* For a screen-reading app that's a real trade-off. `Space Bunny Free` and `LongCat 2.5 Preview Free` are documented **zero-retention, no training**; `Big Pickle`, `MiMo`, `Ling`, and `Nemotron` free tiers are **not**.

#### Final brain recommendation

| Route | Cost/turn | Vision | Privacy | Role |
|---|---|---|---|---|
| **`gemini-3.8-flash` free** ⭐ | **$0** | ✅ proven | `store:false`, nothing retained | **Default** |
| `gemini-3.1-flash-lite` free | $0 | ✅ proven | same | Fallback under 503 |
| `gemini-3.1-pro-preview` free | $0 | ✅ | same | Quality tier when it isn't contended |
| Zen `deepseek-v4-flash-vision-exp` | ~$0.0002 | ✅ | zero-retention | Cheap 2nd opinion |
| Zen `gpt-6-luna` / `claude-haiku-4-5` | ~$0.0001–0.0006 | ✅ | provider retention | "Switch brain" escape hatch |
| Ollama local | $0 | ✅ | **fully private** | Air-gap option |

**Chunks is free by default.** Zen is optional and earns its place only as the model switcher.



### Phase 1 — Shell + explain + **memory core** (3 days)

- Fork `farzaa/clicky`, rename to Chunks, new bundle id + icon
- Strip: ElevenLabs, AssemblyAI, Cloudflare Worker dependency, PostHog
- `CaptureEngine` + `CoordinateSpace`
- `BrainClient` with provider registry, streaming, `<SAY>` tag extraction
- **`MemoryStore` + `MemoryInjector` + `MemoryWriter` + secret-rejection** (§4)
- Menu bar panel, PTT via CGEvent tap, `Cmd+M` memory viewer
- **Milestone:** hold a key, ask "what am I looking at?", hear the answer. Tell it "I use Raycast not Spotlight" — next turn it knows.

### Phase 2 — Annotate (3 days) ⭐ the headline feature

- Overlay `NSPanel`, tool palette, four tools + undo + clear
- `RegionResolver` → crop with context padding
- Two submit paths: *"explain this"* (crop only) and *"explain this in the context of my screen"* (full + annotated crop)
- Notebook integration: offer to save the explanation, one-tap accept
- **Milestone:** circle something on screen, get a spoken explanation of that circle, save it.

### Phase 3 — Point (1 day)

- Parse `[POINT:x,y:label:screenN]` from streamed replies
- Bezier-arc cursor flight + caption, auto-retract
- Multi-point support
- **Milestone:** ask "where's the run button?", watch the cursor fly there and say it aloud.

### Phase 4 — Voice (1.5 days)

- `SpeechTranscriber` (macOS 26+) with `AnalysisContext` vocabulary biasing
- Kokoro integration + settings toggle to `AVSpeechSynthesizer`
- Barge-in: speak over the answer to interrupt
- **Milestone:** fully hands-free local conversation, zero API keys.

### Phase 5 — Act — scope fixed (3 days)

- `AXTDriver`: AX snapshot → element tokens → `AXPress`/`setValue`/`focus`
- Window-scoped pixel fallback for canvas/AX-less targets
- `PolicyGate` + Allow/Not-now card
- **Milestone:** "click the blue button in this app" → confirmation card → clicks the right thing, your cursor never moves.
- **No additions to this scope.** No proactive actions, no unattended clicking, no multi-step chains without per-step confirmation.

### Phase 6 — Automations (1 day)

- `launchd` LaunchAgent wrapper, one plist per job
- Jobs are read-only by default: *"every weekday at 9:05, tell me what's new on my screen"* → notification, no action
- Actions require per-job opt-in
- **Rationale:** HeyClicky's own docs ship this as a rule — routines must never silently escalate to writes.

### Phase 7 — Memory depth (ongoing, never "done")

- Notebook search and recall-quality tuning
- Memory compaction — propose prunes as it nears the 2 KB cap
- Optional per-project memory scopes
- **This is the phase that compounds.** Every other feature is a tool you use; this is the reason Chunks still knows you in six months.

---

## 7. File layout

```
chunks/
├── Package.swift                    # or .xcodeproj, fork preserves the latter
├── Chunks.xcodeproj
├── CLAUDE.md / AGENTS.md           # from farzaa/clicky, extended with Chunks conventions
├── Sources/
│   ├── App/                         leanring_buddyApp → ChunksApp
│   ├── Shell/                       MenuBarPanelManager, SettingsPane, TranscriptHUD
│   ├── Capture/                     CaptureEngine, CoordinateSpace  ← Retina truth lives here
│   ├── Annotate/                    OverlayWindow, AnnotationCanvas, ToolPalette, RegionResolver
│   ├── Point/                       PointEngine, CursorOverlay
│   ├── Voice/                       DictationController, STTProvider, TTSEngine
│   ├── Brain/                       BrainClient, ProviderRegistry, Transports/, PromptBuilder,
│   │                                ResponseParser, CapabilityProbe
│   ├── Memory/                      MemoryStore, MemoryInjector, MemoryWriter,
│   │                                SecretSweeper, NotebookStore, NotebookSearch
│   ├── Action/                      AXTDriver, ActionEngine, PolicyGate, ConsentGate
│   ├── Automations/                 LaunchAgentPlanner, JobStore
│   └── DesignSystem/                from fork
├── Tests/
│   ├── CoordinateSpaceTests         ← 1x/2x/3x round-trip
│   ├── PolicyGateTests              ← every deny rule
│   ├── RegionResolverTests
│   ├── ResponseParserTests
│   ├── MemoryWriterTests            ← secret rejection, cap enforcement, dedupe
│   └── MemoryStoreTests             ← hand-edit round-trip, no data loss
└── docs/
    ├── ARCHITECTURE.md
    ├── PROVIDERS.md
    └── MEMORY.md                    ← the memory format spec
```

---

## 8. Risks, honestly

| Risk | Severity | Mitigation |
|---|---|---|
| **Zen vision claim turns out false** | High, but now low-probability | Phase 0 gate. Gemini is the fallback. Registry degrades loudly, never silently |
| **Memory grows unbounded / bloats every prompt** | **High** | Hard 2 KB cap. Refuse adds at cap and *ask*. Never truncate silently. Notebook is separate and never auto-injected |
| **Model writes a secret into memory** | **High** | Structural: `SecretSweeper` regex+keyword filter runs before every write. Model proposes, app disposes |
| **Memory drift / contradiction** | Medium | Dedupe + timestamps + you can hand-edit. `Cmd+M` viewer is always one keystroke away |
| **On-device STT quality on 16 GB** | Medium | `SpeechTranscriber` on M5 is good; whisper.cpp fallback. Measure in Phase 4 |
| **Kokoro bundle size** | Low | ~300 MB, optional — system voice is the fallback |
| **AX trees missing/partial** | High for canvas apps | Window-scoped pixel fallback + honest "this app doesn't expose controls" message |
| **Overlay vs fullscreen apps** | Medium | `fullScreenAuxiliary` + Spaces testing. The fork already handles most of it |
| **Fork is frozen at 20 commits** | Low | It's 7.7k lines with a good `AGENTS.md`. That's a feature, not a liability |
| **Scope creep toward agents** | Medium | Hard rule in `AGENTS.md`: no code generation, no file artifacts, no sub-agents |

---

## 9. Explicitly rejected

- **Electron/Tauri shell** — adds ~150 MB and a CPU floor to a menu-bar app that must be invisible. Native Swift is the right call.
- **Bundling Codex/Claude Code** — you said no agents. 216 MB saved and a whole safety surface removed.
- **A second process (Python sidecar)** — everything needed is available natively. A sidecar doubles the failure modes for no gain.
- **Self-hosting an OAuth broker** — official MCP servers (Google, Slack, Notion, GitHub) are free and vendor-maintained.
- **Docker-based scheduling** — `launchd` is built in, catches up after sleep, and writes real logs.
- **A skills marketplace** — not a feature, a business.

---

## Next step

**Phase 0 is done — Chunks is confirmed to see your screen, for $0.** Both keys have been shredded from disk; neither is in the repo.

**Rotate both keys.** They were pasted into this conversation. The Gemini key in particular is now the app's production brain — regenerate it at [aistudio.google.com/api-keys](https://aistudio.google.com/api-keys) before we ship, and I'll wire the replacement into the macOS Keychain rather than any file.

**One decision left, and it's small:** Zen. It costs you nothing to skip and nothing to keep.

- **Skip Zen** — Chunks is already free on Gemini alone, with 4 fallback tiers under 503.
- **Keep Zen** (top up ~$5) — you get Claude and GPT in the same provider switcher, so "switch my brain easily" becomes literal rather than aspirational. Cost with `gpt-6-luna` ≈ **$1/month** at heavy use.

My suggestion: **skip it for now.** Gemini alone covers every feature in the plan, and I'd rather not have two keys in the codebase while we're still building. Add Zen later if you want model choice — the registry is designed for it and adding a provider later is a one-file change.

**Then Phase 1 starts:** fork `farzaa/clicky`, rename to Chunks, strip the paid dependencies, and build shell + capture + `CoordinateSpace` + the memory core — because every prompt path after that depends on memory existing.
