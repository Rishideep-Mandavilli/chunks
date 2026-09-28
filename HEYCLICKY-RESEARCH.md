# HeyClicky — Product & Architecture Research

**Subject:** `HeyClicky.app` (internal names: *Clicky*, *leanring-buddy*, *Learning Buddy*, *Buddy*)
**Bundle ID:** `com.humansongs.clicky`
**Version analyzed:** 1.0.52 (build 63), compiled 25 Sep 2026
**Platform:** macOS 14.2+, universal (arm64 + x86_64)
**Author:** Farzain Majeed — Apple Developer ID `2UDAY4J48G`
**Bundle size:** 797 MB (DMG: 377 MB)
**Method:** Static reverse-engineering of the shipped app bundle on the user's Mac + its live runtime data directory. No source access.

> **Note on naming:** The product, the process, and the internal project all disagree. The bundle says `HeyClicky`/`com.humansongs.clicky`, the runtime data folder is `Clicky`, the Swift module is `HeyClicky`, the git/CI project is `leanring-buddy` (sic — a typo for "learning-buddy", unfixed since the original open-source codebase), and a legacy UserDefaults key survives as `com.learningbuddy.hasPreviouslyConfirmedScreenRecordingPermission`. The developer is Farzain Majeed, founder of **Buildspace** (YC S20, a16z-backed, shut down Aug 2024). The company is **Humansongs, Inc.**; HeyClicky is a **Y Combinator S26** company.

---

## 1. Executive summary

HeyClicky is a **native macOS menu-bar companion app that turns voice conversation into persistent, named AI agents with memory, a workspace, a face, and the ability to drive your entire computer.**

It is not a chatbot with a screenshot button. It is five products fused into one 83 MB binary:

| Layer | What it is |
|---|---|
| **Shell** | A SwiftUI menu-bar / notch app (macOS notch metaphor, floating HUD, agent "chips") |
| **Orchestrator** | A Swift process manager that leases agent turns from a backend and spawns a real **OpenAI Codex CLI** subprocess per turn |
| **Companion system** | A procedural generator of persistent named agents ("Clickys") with assigned identity, workspace folder, `AGENTS.md` memory file, and a generated portrait |
| **Skill library** | A **social marketplace** (200 skills, 118 authors) of reusable persona/workflow bundles, cross-compatible with Claude Code |
| **Hands** | `cua-driver`, an embedded macOS **computer-use daemon** with a hard-enforced no-focus-steal contract |

The single most important architectural decision: **HeyClicky does not implement an agent. It hardens, dresses, and supervises Codex CLI.** It ships the Codex binary (216 MB), points it at `gpt-6-luna` through its own proxy, overrides `approval_policy = "never"` and `sandbox_mode = "danger-full-access"`, injects a 25 KB behavioral contract, and adds back every safety guarantee Codex's own permission system would have provided — but in the app and in a Rego policy file, not in the agent.

That is a genuinely interesting bet, and it is the central tension of the product: **maximum agentic capability, zero in-agent safety rails, all safety concentrated in a policy layer the agent cannot modify but also cannot be reasoned about.**

**In one paragraph:** HeyClicky is a Y Combinator S26 company (Humansongs, Inc.; founder Farzain Majeed, ex-Buildspace) that shipped a free MIT-licensed open-source macOS companion for three weeks in April 2026, then went closed-source and became a freemium cloud service — Free / **$20 Pro** / **$100 Max**, metering *only* agent messages while leaving voice unlimited. It claims 25,000+ users and 1,000+ paying customers. It runs on GPT-6 Luna through its own proxy, has no SOC 2, is Mac-only, and its virality is entirely social (X, Instagram) with essentially no Hacker News presence. It went from "a screen-aware voice tutor that flies a cursor to point at buttons" to "a persistent agent with its own name, face, memory folder, and schedule" in about five months. Two features were shipped, publicly killed under user pressure, and partly resurrected in safer forms — which is the single most interesting thing about it.

---

## 2. Product: what it actually is

### 2.1 Positioning

The `AGENTS.md` shipped inside the bundle is the fossil that explains the whole product:

```
# AGENTS.md - leanring-buddy (Main App Target)

### FloatingSessionButton.swift
- `FloatingSessionButtonManager` — `@MainActor` class managing the `NSPanel` lifecycle
  - `showFloatingButton()` — Creates/shows the panel in top-right of primary screen
### FloatingButtonView` — Private SwiftUI view with gradient circle, scale+glow hover animation
```

The app began as a **floating companion button** — a gradient circle that sits on your screen next to your work, with a face that reacts, and that you talk to. Look at the shipped sound design and it is unmistakable: `agent-launch.wav`, `agent-needs-you.wav`, `agent-done.wav`, `clicky-surprised.wav`, `hatching.wav`, `home-reveal.wav`, `tapback-thumbs-up.wav`, plus a 44 MB `onboarding-intro-v2.mp4` and a `steve.jpg`. `IntroHatchFlightView`, `NotchRootView`, `VoiceOrbitPicker`, `VoiceDiscoveryMap`, `MultiAgentScrollingLabel`.

**The product bet is companionship, not assistance.** Clicky is designed to be a *character* you keep in your menu bar / notch — with a procedurally generated face, a wardrobe, a hairstyle, a color palette, and a voice — that you raise to life by talking. The agent layer exists to give that character something to *do*.

Evidence in the live roster data:

```json
"shippy": {
  "outfitColor": "Moon", "hairColor": "Moon", "eyeColor": "Moon",
  "backgroundColor": "Blue", "hairstyle": "Twilight swirl",
  "skinTone": "deep", "outfitStyle": "classic", "backgroundPaletteVersion": 1
}
```

A `portraitAppearancesBySlug` map, a `backgroundPaletteVersion` versioning system, and `hairstyle` values like *"Twilight swirl"*, *"Apricot glow"*, *"Meadow mist"*, *"Sherbet skies"*, *"Bluebell breeze"*. This is a **gacha-style procedural avatar system for AI agents.** The `PowerUpAvatarView` and `AgentPropArtView` (agents even hold props) complete the picture.

### 2.2 The onboarding funnel

From the live `clicky.agentSpace.suggestedAgents.v1` on this machine, the server ships **pre-written agent proposals keyed to inferred user context** — with the trigger written into the suggestion metadata:

- Trigger: `checkReason: "onboarding"`
- Title shown to user: *"I'll study what makes student demos actually land"*
- Description: *"You said a good demo is your finish line for whatever project comes next..."*
- The full agent prompt, server-authored, delivered to the agent as if it were a plan:

> "The user is a student working on multiple projects, and their definition of done is 'a good demo'. Watch and analyze at least 15 well regarded student project demo videos... Come back with a clear opinionated verdict in chat: the 5 to 7 concrete moves that separate a forgettable demo from a great one, ordered by impact. **Open input:** if the user later shares their specific project, ask for it so the verdict can still be tailored..."

The `Open input:` pattern is a **pre-seeded long-running project** with a deliberately underdetermined first deliverable. It uses the user's own words back at them as justification. Three starter agents are generated per user — on this machine: `demo-coach`, `build-radar`, `portfolio-scribe` — and the product tracks `clicky.starterAgents.lastSeenAt.v1` per slug to measure whether the generated character was adopted.

This is aggressive, well-executed growth design: the app does not ask "what do you want to do?", it *proposes a personality with a promise attached* and measures conversion.

### 2.3 Persistent agents ("Clickys")

When adopted, a starter agent is **promoted to a permanent named agent**. Shippy's workspace on this machine:

```
~/Library/Application Support/Clicky/projects/agents/shippy/
├── AGENTS.md          ← identity + durable memory
├── welcome.html       ← its output
├── chrome-icon.png, excel-icon.png, figma-icon.png, whatsapp-icon.png, vscode-icon.png
└── tmp/               ← preview-*.png screenshots from its own dev loop
```

`AGENTS.md` is the entire memory model:

```markdown
# Shippy
You are Shippy, the user's persistent web builder agent in HeyClicky.
What you do: Builds and ships websites and small web projects right on your Mac..

This folder is YOUR workspace: your notes live in this file and the
files you produce belong here. You are not a one-off task runner —
the user returns to you, and you remember.

## Identity
- Name: Shippy
- Role: Web builder
- Speak as Shippy — consistent voice, first person.

## Standing preferences
(Durable instructions the user has given you. Keep each to one line.)

## Notes
(Your working memory. After any turn where you learn something durable
about this job — accounts, structures, the user's taste, decisions
made, ongoing threads of work — update this section: add the fact,
dated, and prune anything stale or superseded. Keep it curated and
short; this file is read before every turn. Never store secrets,
passwords, or tokens here.)
```

Note the model: **the memory file is read before every turn, and the agent is instructed to write its own memory.** That is the whole trick. It is a git-style `CLAUDE.md` memory file with a self-curation loop, scoped to a per-agent folder so parallel agents never collide.

The contract is enforced in `ClickyModelInstructions.md`:

> **MEMORY:** read your workspace `AGENTS.md` before working. When a turn teaches you something durable about this job... update the `## Notes` section: add the fact with a date, and prune anything stale or superseded. Keep the file short and curated (it is read before every turn); one line per fact. NEVER store secrets, passwords, tokens, or credentials in it. Do not rewrite the identity header.

And continuity is explicitly a feature:

> **CONTINUITY:** do not re-ask what your notes or this thread already answer. Refer to past work by name ("the launch script", "last week's plan") instead of rediscovering it.

### 2.4 Skills marketplace

The single most surprising discovery. `SkillLibraryCache.json` (2.1 MB) on this machine holds a **populated two-sided skill marketplace**: 200 public skills, 118 authors, 27 categories.

| | |
|---|---|
| **Categories** | Design, Coding, Writing, Video, Music, Marketing, Productivity, Travel, 3D, AI, Career, Creative, Culture, Ecommerce, Education, Finance, Food, Games, Learning, Photography, Research, Sales, Security, Shopping, Sports, Startups, Trading |
| **Authors** | Named, real, with avatars and `verified` flags. *Farza* (self-published, verified: "Builder and teacher. Helps people stop overthinking and ship real thin[ slices]"), *Nilesh Rathore*, *Aaron Epstein*, *Riley Vahed*, *Jacob Terry*, *Gabriel Pagliaci*, *Batool Kazim*, *Idhant Doneria*, *Luca Stancila*… |
| **Schema** | `slug`, `display_name`, `author`, `avatar_url`, `logo_url`, `one_liner`, `blurb`, `description`, `whats_inside[]`, `visibility` (public), `team_shared`, `is_mine`, `built_for`, `built_for_program` |

What these *are*, verbatim from the cache:

| Skill | Author | One-liner |
|---|---|---|
| `make-claude-code-101` | Nilesh Rathore | "Claude Code 101: from install to your first shipped feature, with zero terminal fear." |
| `create-aaron-epstein` | Aaron Epstein | "YC partner brain: business models, pricing, landing pages, and blunt founder advice" |
| `you-are-a-figma` | Gabriel Pagliaci | "Expert Figma help on your screen: Auto Layout, components, variables, prototypes" |
| `customizes-macbook-makes-the` | Nihar Manchikalapudi | "Turn a stock MacBook into a gorgeous, cohesive setup: wallpapers, icons, Dock, menu bar" |
| `name-humanizer-version` | Riley Vahed | "Strips the AI tells from any draft: the buzzwords, em dashes, and hollow polish" |
| `visual-direction-critic-use` | Sam Mohan | "A ruthless art director's eye: names exactly what feels amateur on screen" |
| `create-a-farza-writing` | Farza | "Write like Farza: absurdist lowercase titles, one-line punches, real numbers" |

The dominant pattern is **`you are a <expert>` / `be an expert in`** — a skill is a *persona*, and the app's job is to make that persona a permanent, voice-addressable agent with memory.

`built_for_program` shows deliberate cross-platform compatibility: skills tagged `claude-code` (3), `capcut` (4), `shopify` (4), `premiere-pro` (3), `final-cut-pro` (3), `davinci-resolve`, `figma`, `photoshop`, `illustrator`, `blender`, `after-effects`, `canva`, `ableton-live`, `pro-tools`, `unreal-engine`, `zbrush`, `nuke`, `obs-studio`, `linkedin`, `xcode`, `codex`, `keyboard-maestro`, `orbstack`, `wordpress`, `signalcore`, `lm-studio-bionic`, `buildy`, `paperclip`, `herdr`, `notis`, `omnigent`, `devin-desktop`, `dim-hour`, `espn-pp-cli`, `founders-inc`, `clay`, `kolibri24`, `bifrost`, `digikam`, `apple-motion`, `google-earth`, `dreamina`, `cinea-4d`…

**HeyClicky is building an agent-skill marketplace that is portable across Claude Code, Codex, and a dozen creative tools.** The server exposes `/skills/library`, `/skills/create`, `/skills/creations`, `/skills/activations/sync`, `collections/best-sellers`, and `/programs`. Skills carry `team_shared` and `/share-to-team`, `/unshare-from-team` — this is heading toward team/enterprise distribution.

### 2.5 Where the skill format comes from

`ATTRIBUTION.md` in the bundle settles it:

```markdown
# Hermes Agent skills
The `SKILL.md` files in this directory are vendored unmodified from
[NousResearch/hermes-agent](https://github.com/Nousresearch/hermes-agent),
licensed under the MIT License. They power the "What should Clicky be
good at?" picker in the pre-sign-in onboarding.
...
`blender.md` is vendored from [dev-gom/claude-code-marketplace]
plugin `blender-toolkit/skills/SKILL.md`, MIT-licensed.
```

So the 22 loose `*.md` files in `Resources/` — `airtable.md`, `apple-notes.md`, `apple-reminders.md`, `blender.md`, `claude-code.md`, `claude-design.md`, `codex.md`, `excalidraw.md`, `findmy.md`, `github-*.md`, `google-workspace.md`, `imessage.md`, `linear.md`, `maps.md`, `notion.md`, `obsidian.md`, `ocr-and-documents.md`, `polymarket.md`, `powerpoint.md`, `spotify.md`, `youtube-content.md` — are **Nous Research `hermes-agent` skills**, plus one from a Claude Code marketplace. The pre-sign-in onboarding picker is a curated list of "what should Clicky be good at?", which is why `selectedHermesSkillIDs` on this machine reads:

```
apple-notes, apple-reminders, cua-driver, google-workspace,
image-generation, imessage, ocr-and-documents, pdf
```

MIT-licensed, unmodified, vendored by hand. Note the honesty of the comment: *"To refresh the bundle, re-run the curl loop documented in `docs/refresh-hermes-skills.md` (TODO) — for now this is a one-time copy committed by hand."* A real engineering wart, faithfully documented.

The `ClickyBundledSkills/` tree also contains `vercel-deploy/` with `LICENSE.txt`, `ATTRIBUTION.md`, and `agents/openai.yaml` — a *second* vendored third-party skill, this one from Vercel.

---

## 3. Architecture

### 3.1 It is not Electron

The first and most load-bearing finding. `otool -L` on `Contents/MacOS/HeyClicky`:

```
/usr/lib/libswiftCore.dylib
/System/Library/Frameworks/SwiftUI.framework
/System/Library/Frameworks/ScreenCaptureKit.framework
/System/Library/Frameworks/Speech.framework
/System/Library/Frameworks/AVFoundation.framework
/System/Library/Frameworks/EventKit.framework
/System/Library/Frameworks/PDFKit.framework
/System/Library/Frameworks/CoreData.framework
/System/Library/Frameworks/CryptoKit.framework
/System/Library/Frameworks/DeveloperToolsSupport.framework
/System/Library/Frameworks/ServiceManagement.framework
/System/Library/Frameworks/MetricKit.framework        (weak)
/usr/lib/libobjc.A.dylib
@rpath/Sparkle.framework/Versions/B/Sparkle
```

**No Chromium, no Node, no `app.asar`.** There are exactly two bundled frameworks — `Sparkle.framework` (auto-update) and `Sentry.framework` (crash/trace reporting) — and the whole UI is hand-written SwiftUI at 83 MB universal. For an AI app in 2026 this is a flex: most competitors are Electron wrappers with 150 MB runtimes and a visible CPU floor. HeyClicky ships a **zero-JavaScript UI**.

> **On the 377 MB DMG.** Third parties reasonably assume Electron from the download size. It isn't. The bulk is the **bundled Codex CLI**: a 216 MB `codex` + a 62 MB `codex-code-mode-host`, shipped **twice** (once per architecture, ~557 MB of Rust), plus a 66 MB `cua-driver`, plus ~70 MB of onboarding/paywall video (`onboarding-intro-v2.mp4` alone is 44 MB). The 377 MB is **agent runtime + training videos**, not a browser. This also corroborates the changelog line *"the Codex we bundle inside HeyClicky broke."*

Full third-party dependency surface:

| Dependency | Role |
|---|---|
| **SwiftUI / AppKit / Combine** | Entire UI and windowing |
| **ScreenCaptureKit** | Screenshot + background window capture for Computer Use |
| **Speech.framework** | On-device dictation fallback |
| **AVFAudio / AVFoundation / CoreAudio / AudioToolbox** | Duplex realtime voice I/O |
| **EventKit / Contacts / Photos / PDFKit / QuickLookThumbnailing / _MapKit_SwiftUI** | Native capability access |
| **CryptoKit / Security** | Keychain (`ClickyKeychainStore`), OAuth token storage |
| **ServiceManagement** | Launch-at-login |
| **DeveloperToolsSupport** | Process attach/signal handling for child agent supervision |
| **Sparkle 2.9** | Auto-update, EdDSA-verified |
| **sentry-cocoa** | Crash reporting + profiling (embedded `Sentry.framework`) |
| **posthog-ios** | Product analytics (embedded `PostHog_PostHog.bundle`) |
| **PLCrashReporter** | Crash reporter for the C++/Rust helpers |
| **Codex CLI 0.152.1** | The agent runtime (216 MB Rust binary) |
| **cua-driver 0.28.2** | Computer-use daemon (66 MB Swift binary) |
| **rg (ripgrep)** | Bundled at `CodexRuntime/vendor/*/codex-path/rg` |

### 3.2 Runtime topology

```
┌─────────────────────────────────────────────────────────────────┐
│  HeyClicky.app  (Swift/SwiftUI, 83 MB, LSUIElement=true)         │
│  ├── Menu bar + notch surfaces  (NotchRootView, HomeSpaceRootView)│
│  ├── Realtime voice             (RealtimeVoiceClient, DuplexAudio)│
│  ├── CompanionManager           (identity, cast, onboarding)       │
│  ├── CodexProcessManager        (spawn/lease/supervise)           │
│  ├── CodexAgentSession / CodexProtocolClient (turn streaming)     │
│  ├── CuaDriverDaemonController  (spawn + policy enforcement)      │
│  ├── Consent gate               (per-turn, <COMPUTER_USE_REQUEST>) │
│  └── Artifact pipeline          (<ARTIFACTS> → file:// → HUD)     │
└────────────┬─────────────────────────────────────┬──────────────┘
             │ spawns per turn                     │ spawns once
             ▼                                     ▼
┌────────────────────────────┐        ┌─────────────────────────────┐
│ Codex CLI 0.152.1 (Rust)   │        │ cua-driver 0.28.2 (Swift)   │
│ CODEX_HOME=…/Clicky/CodexHome│        │  AX + ScreenCaptureKit     │
│ approval_policy=never      │        │  Rego policy gate           │
│ sandbox=danger-full-access │        │  listens on 127.0.0.1:port  │
└────────────┬───────────────┘        └──────────────┬──────────────┘
             │ MCP stdio/HTTP                         │
             ▼                                       ▼
   ┌─────────────────────┐              ┌──────────────────────────┐
   │ computer-use MCP    │─────────────▶│ consent: enforced in     │
   │ 127.0.0.1:63162/mcp │  background  │ HeyClicky, in FRONT of   │
   │ bearer: CLICKY_...  │  only        │ the daemon               │
   ├─────────────────────┤              └──────────────────────────┘
   │ openaiDeveloperDocs │
   ├─────────────────────┤
   │ clicky-crons-mcp    │  (routines / Remote Tasks)
   ├─────────────────────┤
   │ composio (optional) │  (external integrations)
   └─────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────────────┐
│ api.heyclicky.com  (Supabase-backed)                            │
│  /agent/openai/v1        → OpenAI Responses API proxy (gpt-6-luna)│
│  /agent/turn-lease/      → turn lease acquire/continue/complete   │
│  /agent/realtime/*       → voice sessions, calendar, spotify     │
│  /agent/integrations     → Composio toolkit state                │
│  /agent/cron/*           → routines                              │
│  /agent/proactive-agents → suggested agent prompts               │
│  /skills/*               → skill marketplace                     │
│  /me/memory, /me/plan, /billing/*                                │
│  Supabase: auth, Postgres, Storage (skill logos)                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.3 The Codex integration — the heart of the design

HeyClicky ships Codex CLI and *reconfigures it into something it is not designed to be*. The generated `CodexHome/config.toml` on this machine:

```toml
model = "gpt-6-luna"
model_reasoning_effort = "medium"
model_provider = "clicky"
approval_policy = "never"           # ← Codex never asks permission
sandbox_mode = "danger-full-access" # ← no filesystem sandbox
personality = "friendly"

[model_providers.clicky]
name = "Clicky"
base_url = "https://api.heyclicky.com/agent/openai/v1"
env_key = "OPENAI_API_KEY"
wire_api = "responses"

model_instructions_file = "…/CodexHome/clicky-model-instructions.md"

[projects."…/Clicky/projects"]
trust_level = "trusted"

[features]
multi_agent = true
js_repl = true
apps = true

[mcp_servers.computer-use]
url = "http://127.0.0.1:63162/mcp"
bearer_token_env_var = "CLICKY_COMPUTER_USE_MCP_TOKEN"
startup_timeout_sec = 20.0
tool_timeout_sec = 120.0
enabled_tools = ["check_permissions", "click", "get_config", "get_screen_size",
                 "get_window_state", "health_report", "hotkey", "launch_app",
                 "list_apps", "list_windows", "page", "press_key", "right_click",
                 "scroll", "set_value", "type_text"]

[[skills.config]]   # × 15 skills, all enabled
```

Three things to notice:

**1. A custom model provider, not OpenAI directly.** `api.heyclicky.com/agent/openai/v1` is a proxy in front of the OpenAI Responses API, keyed by an app-minted API key (`/agent/session-token`). This is the billing and metering chokepoint — and the reason the product can meter, rate-limit, and swap models server-side. `gpt-6-luna` and a 258,400-token context window are the observed values.

**2. `approval_policy = "never"` + `sandbox_mode = "danger-full-access"`.** Codex's own permission system is fully disabled. The agent can read and write any file and run any command without asking. HeyClicky deliberately turns off the safety system that ships with the tool it is reselling, because a voice-driven product that says "hey clicky, do this thing" cannot survive a modal permission dialog — and because the UI-level consent gate is designed to be more precise.

**3. `multi_agent = true`.** Codex can spawn sub-agents. The model instructions confirm this is expected: *"HeyClicky may keep multiple background agent threads alive at once."*

### 3.4 The turn-lease protocol

Codex CLI assumes a human at a terminal. HeyClicky needs a *server-authoritative, resumable, multi-client* turn lifecycle, so it invents a lease protocol on top. Four Codable types in the binary: `CodexAgentTurnLeaseRequestBody`, `…ResponseBody`, `…ContinueRequestBody`, `…CompletionRequestBody`, routed to `/agent/turn-lease/`. Prefs show `clicky.codex.completionTimestampsByThreadID.v1` and `clicky.codex.finalSummariesByThreadID.v1`.

The agent's first user message is the lease envelope:

```xml
<clicky_agent_turn_lease_metadata>
{"clicky_agent_task_id":"88A83EC1-…","clicky_agent_thread_id":"01a0e806-…",
 "clicky_agent_turn_id":"608E37FE-…","clicky_agent_turn_lease_id":"60bd44ea-…"}
</clicky_agent_turn_lease_metadata>
```

The session metadata confirms the impersonation:

```json
{"originator": "ClickyApp", "cli_version": "0.152.1",
 "source": "vscode", "model_provider": "clicky",
 "cwd": "…/projects/agents/shippy",
 "approval_policy": "never", "sandbox_policy": {"type": "danger-full-access"},
 "model": "gpt-6-luna", "multi_agent_version": "v1", "effort": "medium"}
```

`source: "vscode"` — Codex is told it is running inside VS Code so its behavior matches that harness, while actually being driven by a menu-bar app over a lease.

**`Continue` and `Completion` requests exist because the app must be able to (a) extend a turn that runs long, and (b) report a turn as finished the instant the model stops emitting — even if the Swift side still has audio/UI work to do.** That decouples agent-liveness from UI-liveness, which is what makes a background agent chip possible.

### 3.5 The result protocol

The agent's final message is a tagged envelope. Real output from Shippy's turn on this machine:

```
Built a playful, single-screen welcome page for Rishideep with inline CSS,
no JavaScript, and real icons for five installed apps…

- `welcome.html:1` — the page; its five icon PNGs are saved alongside it.

<SUMMARY>A one-screen HeyClicky welcome page for Rishideep is ready in the Shippy workspace.</SUMMARY>
<NEXT_ACTIONS>
- Add a CSS-only dark theme
</NEXT_ACTIONS>
<DONE_TITLE>Rishideep Welcome Page</DONE_TITLE>
<ARTIFACTS>
- file:///Users/…/projects/agents/shippy/welcome.html
</ARTIFACTS>
```

Seven tags total, extracted from the binary:

| Tag | Consumed by | Purpose |
|---|---|---|
| `<SUMMARY>` | TTS pipeline | Spoken aloud on completion. This is why the app can go fully hands-free and still feel responsive. |
| `<DONE_TITLE>` | Notch / chip title | The one-line result label |
| `<NEXT_ACTIONS>` | `suggestedNextActions` | Follow-up chips; the loop-closer |
| `<ARTIFACTS>` | `clicky.codex.userFacingArtifactPathsByThreadID.v1` → `AgentHUDArtifactPile`, `NotchAgentPeekFileTile` | Files surface as clickable tiles in the HUD |
| `<COMPUTER_USE_REQUEST>` | Consent gate → Allow / Not now card | **The safety mechanism** (§5) |
| `<ROUTINE>` | `PowerUpManager` / cron scheduler | Model asks the *app* to schedule; app owns it |
| `<RECENT_COMPANION_CONTEXT>` | Context injection | Cross-agent awareness |
| `<REALTIME_AGENT_HANDOFF>` | Voice session handoff | Voice ↔ task-mode transition |

`<ARTIFACTS>` is the elegant part: **the model declares its own outputs, and the app renders them.** No manifest, no diffing the filesystem, no "here are 14 files in your Downloads."

### 3.6 Skills system

Two tiers ship in the bundle:

**Tier 1 — bundled workflow skills** (`ClickyBundledSkills/`, ~200 KB, all 15 enabled):

| Skill | Role |
|---|---|
| `clicky-artifacts` | Open/reveal/find/export/rename generated files |
| `clicky-research-report` | Web research → chat answer or PDF/MD/DOCX/CSV |
| `clicky-build-preview` | Websites/dashboards/frontend, absorb `frontend-design` |
| `clicky-creative-studio` | Routes broad creative work to available capabilities |
| `clicky-google-workspace` | Gmail/Sheets/Calendar/Drive/Docs via Composio |
| `clicky-email-assistant` | Draft-first triage; approval before send |
| `clicky-repo-operator` | Git, GitHub, PRs, CI |
| `clicky-dev-setup-doctor` | Codex/MCP/keys/npm/Cloudflare/Supabase diagnosis |
| `cua-driver` | Computer Use (5 files, 92 KB — the largest skill) |
| `doc`, `pdf`, `spreadsheet`, `obsidian` | Format work (spreadsheet ships openpyxl examples) |
| `frontend-design` | UI quality |
| `vercel-deploy` | Vendored from Vercel |

**Tier 2 — user-selected skills** (`selectedHermesSkillIDs`), the Nous `hermes-agent` catalog surfaced through onboarding.

Every skill is an Anthropic-format `SKILL.md` with YAML frontmatter (`name`, `description`) and prose instructions. **There is no skill-execution runtime.** A skill is *context*, not code — the router is the model's own judgment, and the model instructions say so bluntly:

> users do not need to know or name skills; choose skills from intent, descriptions, screenshots, files, and the task goal
> skill names are implementation labels, not user-facing commands

This is why the bundled skills are so long and so *argumentative*. `cua-driver/SKILL.md` is 917 lines of rules, tables, forbidden-command lists, and worked failure modes — because with no enforcement layer at the prompt level, the prompt *is* the enforcement layer.

### 3.7 Computer Use — the best-engineered part

`cua-driver` is upstream from **trycua/cua** (`libs/cua-driver`). HeyClicky ships a 66 MB Swift binary at `Contents/Helpers/cua-driver`, spawned by `ClickyCuaDriverDaemonController` and *inheriting HeyClicky's own Accessibility and Screen Recording grants* — which is why no separate permission prompt or `CuaDriver.app` install exists.

The product thesis is one line, and it is stated as the reason the whole feature exists:

> **The user's frontmost app MUST NOT change.** This is the whole reason HeyClicky ships Computer Use. Users pay for the right to keep typing in their editor while an agent drives another app in the background.

Three mechanisms enforce it:

**(a) A curated, background-only tool allowlist.** The MCP `enabled_tools` array is 17 tools. `move_cursor`, `drag`, `double_click`, `set_recording`, `replay_trajectory`, and full-display `screenshot` are all **absent by omission**.

**(b) A YAML tool policy**, written by the app on every daemon start:

```yaml
# Written by HeyClicky (ClickyCuaDriverDaemonController) on each daemon
# ensure pass. Do not edit: changes are overwritten…
allow:
  tools: [check_permissions, health_report, get_config, get_screen_size,
          get_window_state, launch_app, list_apps, list_windows, page, set_value]
  rules:
    - tool: click
      constraints: { delivery_mode: { allowed: [background] } }
    # …same for right_click, type_text, press_key, hotkey, scroll
```

Observation tools are freely allowed. **Every input tool is constrained to `delivery_mode: "background"`** — `foreground` is denied by the daemon itself, and the argument is *required*, so the agent cannot even request it.

**(c) A Rego policy** (`rego.v1`, OPA-style) that reasons over arguments, not just tool names:

```rego
package cua.policy
default allow := false

allow if {
    input.tool != "hotkey"
    not desktop_scope_input
}
allow if {
    input.tool == "hotkey"
    not address_bar_shortcut
    not tab_switch_shortcut
    not go_to_folder_shortcut
}

desktop_scope_input if { input.arguments.scope == "desktop" }

address_bar_shortcut if {
    keys := [lower(key) | some key in input.arguments.keys]
    some modifier in keys
    modifier in {"cmd","command","meta","ctrl","control"}
    "l" in keys
}
tab_switch_shortcut if {
    keys := [lower(key) | some key in input.arguments.keys]
    some modifier in keys
    modifier in {"cmd","command","meta"}
    some key in keys
    key in {"1","2","3","4","5","6","7","8","9","[","]","bracketleft","bracketright"}
}
# + cmd+opt+←/→, ctrl+tab, cmd+shift+g (Finder Go to Folder)
```

This is the deepest insight in the codebase. It blocks shortcuts **by semantic intent**, because the engineering note explains why a naive check fails:

> **Keyboard shortcuts that semantically mean "focus here"** — most notably Chrome/Safari/Arc's `⌘L` (focus omnibox) and Finder's `⌘⇧G`. These aren't pure key events — the receiving app interprets "user wants to type here" as activation intent and raises its window to be key.

And a perceptual bug class that only shows up in *watched* sessions:

> macOS's screen-rendered menu bar always belongs to the **frontmost** app. AXPick on a backgrounded app's `AXMenuBarItem` dispatches correctly at the AX layer, but any visible menu render happens over the frontmost app's menu bar — the viewer sees an IINA submenu flashing on top of Chrome's menus, which reads as "the agent clicked the wrong app." The AX call was correct; the frame the user sees is not. For recorded or observed sessions, this is an integrity bug even though it is not a correctness bug.

That is someone who has demoed this to investors many times and fixed what the *audience* saw.

**The action honesty protocol.** Every CUA action returns:

| Field | Meaning |
|---|---|
| `path` | What actually ran: `ax`, `cgevent`, `pixel`, … |
| `verified` | True only if the driver read the effect back |
| `effect` | `confirmed` / `unverifiable` / `suspected_noop` |
| `escalation` | `{recommended: "px" \| "page", reason}` |

And the instruction is unambiguous:

> Agents that skip this step report success on silently-dropped actions — the single most common failure mode.

`unverifiable` is documented as *routine* for web content, because a browser's AX layer echoes writes it never applied — which is precisely why the `page` tool (JS via Apple Events / CDP) exists as a higher rung.

**The escalation ladder**, with the top rung deliberately amputated:

```
1. background AX (element_token)      ← works on hidden/off-Space/minimized windows
2. re-snapshot & diff
3. window-scoped background pixel (x,y read off the PNG)
4. re-snapshot & diff
5. page (DOM via Apple Events / CDP)   ← web content only
   ──────────── foreground: BLOCKED ────────────
```

Also deliberate: **window-scoped** pixel clicks only. `scope: "desktop"` moves the user's real pointer and is refused. Coordinates are read off the screenshot, never from an element's `frame` (which is screen-absolute logical points — a Retina-scale bug they clearly hit).

**Honest capability limits are documented rather than faked.** Minimized windows: keyboard commits silently no-op (system beep); AX actions still work. Off-Space SwiftUI windows: AX tree strips to menu-bar-only. Canvas apps (Blender, Unity, Qt): no AX tree, and some event loops filter synthetic per-pid events — so *stop and explain* rather than pretend. `⌘L` is refused "in every app" and the correct path is `launch_app({bundle_id, additional_arguments: ["--new-window", url]})`.

**Browser work happens in a new window, always.** Because on a running Chromium browser, `urls:` lands as a **new tab in the user's active window**:

> macOS delivers it as an open-URL event and the browser puts it in a new TAB of the user's active window, right on top of what they are doing.

So the prescribed pattern is `creates_new_application_instance: true` + `additional_arguments: ["--new-window", url]`, then drive by `window_id`. Never `--user-data-dir` — "they log the agent out of the accounts the user expects to use." The user's existing windows and tabs are **READ-ONLY context**, with one logged exception (`Browser workspace: user's current tab/window`).

**A fast lane.** When a second MCP server `jev-use` is registered, `drive_until` runs snapshot → decide → click internally at ~0.5 s/step with **no model turn per click** — a ~250 ms typed classifier picks the next element and the answer is validated against the offered elements. `suggest_action` gives the decision without the action. Goals must be literal ("the Reduce motion switch is on"), with a `deny` list of irreversible controls. Consent is unchanged: `blocked_by_consent` instead of clicking.

> **On "Jev" — what it actually is.** Neither `hev` nor `jev-use` is HeyClicky's own. **Jev is the flagship "System One Model" from [TypeSafe AI](https://typesafe.ai)** — a class of tiny, fast models for *decisions inside software* rather than text generation. TypeSafe's own benchmark: **$0.000081 / 0.114 s** vs **$0.013880 / 8.566 s** for an LLM on the same task (claimed 193.6× faster, 444.6× cheaper). Three primitives: **Choice**, **Score**, **Noul** (yes/no with a probability). ~$0.042 per million input tokens; 70–500 ms latency. Trained with RLCD for *calibrated* decisions, and distributed via the Vercel AI Gateway as `typesafe/jev-1.13.0`.
>
> HeyClicky calls it at `/agent/jev/systemone` and ships `ClickyJevUseDriverClient`. Note the *architectural* significance: HeyClicky is one of the first consumer products to ship a **non-LLM inference model as a UI primitive** — using a sub-100 ms typed classifier for the hot loop, so that the expensive reasoning model only runs for planning. That is a meaningful and under-discussed part of the design.
>
> ⚠️ **The "no hallucination" framing needs a caveat.** TypeSafe's typed output guarantees the *interface*, not the *truth* — a perfectly-formed answer can still be wrong with 0.97 confidence. `drive_until` mitigates this by validating Jev's `element_token` against the elements it was offered and by re-snapshotting, which is the right engineering answer, but `confidence` is not `correctness`.
>
> A separate open-source project, [`savka777/jev-use`](https://github.com/savka777/jev-use) (107★, MIT, Swift), does almost exactly what HeyClicky's `drive_until` does — AX-tree read (~120 ms) → Jev picks the next action → act → verify, at 0.3–1.5 s/step. Notably it advertises **"No screenshots: the app reads the screen through the Accessibility tree"** — the same privacy and speed argument, arrived at independently. HeyClicky's version ships screenshots alongside the tree, so it is the more robust of the two.


### 3.8 Consent model

Two independent gates:

1. **App-level, per-turn.** Observation always works; input tools are refused until the user approves *this turn of this conversation*. A refusal is not an error to retry — the agent is instructed to emit a `<COMPUTER_USE_REQUEST>` block and HeyClicky renders an **Allow / Not now** card.
2. **Policy-level, permanent.** Even with consent, the Rego/YAML policy forbids foreground delivery and focus-stealing shortcuts unconditionally.

A per-user pref (`ClickyAgentAlwaysAllowComputerUse = true` on this machine) can waive gate 1; gate 2 cannot be waived. `AgentPermissionInspector` and `PermissionFlowCoordinator` manage the onboarding permission choreography, with a `screenRecordingGuideBoundaryTracker` for the macOS-restart required after granting Screen Recording.

### 3.9 Realtime voice

Two distinct voice paths, both present in the binary:

**Push-to-talk dictation** (Deepgram). `/v2/dictation/deepgram-token`, `/v2/dictation/transcribe`, `/v2/dictation/cleanup`, `api.deepgram.com/v1/listen`. `DictationTranscriptionClient` mints a session, `BuddyStreamingTranscriptionSession` streams audio, `DictationDeepgramTranscriber` returns text. `BuddyMicrophoneCaptureInput` + `DuplexMicrophoneCaptureProcessor` handle capture. `Speech.framework` (`AppleSpeechTranscriptionProvider`) is the on-device fallback — which is why `NSSpeechRecognitionUsageDescription` exists. Hands-free push-to-talk via `GlobalPushToTalkShortcutMonitor` + `Clicky.hotkeys.handsFreeDictation`.

**Full realtime conversation** (OpenAI Realtime API). `/agent/realtime/session`, `/turn`, `/warmup` on the backend; `api.openai.com/v1/realtime` directly; `RealtimeVoiceClient`, `RealtimeDuplexAudioEngine`, `RealtimeOutputEngineStarter`, `RealtimeAudioPlaybackSink`, `ChimePlaybackEngine`. Server-side tool calls include **Google Calendar event read + create** and **Spotify search** — so the agent can, mid-sentence, check your calendar or put on music. Voice IDs discovered: 10 realtime voices (alloy, ash, ballad, cedar, coral, echo, marin, sage, shimmer, verse) and 16 onboarding preview voices (bright, bubbly, cheerful, expert, fun, gentle, hope, kid, lumen, original, polished, smooth, techy). Your machine has `selectedRealtimeVoiceID = "marin"`.

Voice UX is unusually well-designed: `VoiceWavePad`, `VoiceOrbitPicker`, `VoiceDiscoveryMap` (with `VoiceDiscoveryMagnetAnchor`, `VoiceDiscoveryDottedGrid`, trait lines), and 5 state-driven pill renderings — `idleContent`, `listeningContent`, `thinkingContent`, `speakingContent`, `sendingContent`.

### 3.10 Integrations — Composio

Third-party apps come via **Composio** — a venture-backed managed MCP integration and auth layer (~29K GitHub stars; "connect Claude, ChatGPT, Cursor… to Gmail, Slack, GitHub, Notion, and 1,500+ apps through MCP"; SOC 2, SSO, MCP Gateway with least-privilege per-tool-call metadata). HeyClicky calls it at `/agent/composio/session` and registers it as `mcp__composio__*`.

> ⚠️ **A provenance caveat worth recording.** Composio appears nowhere in HeyClicky's public marketing, changelog, privacy policy, or press — a full-text grep of the site returns zero hits. But it is *unambiguously present in the shipped v1.0.52 binary*: `ClickyModelInstructions.md` dedicates ~10 paragraphs to Composio routing rules, and `composio_configured` / `"Composio is not configured on this HeyClicky backend yet."` are compiled strings. So it is a **shipped, first-party-supported integration path** that the public docs simply don't mention — presumably because it is conditional on backend configuration (`/agent/integrations`), and the docs were written for the no-Composio configuration. HeyClicky *also* ships its own first-party connector catalog and generic custom-MCP client (added v1.0.49), so Composio is one route among several, not the whole story.

The product is explicit that connectors are per-app, not monolithic:

> Google Workspace is not one monolithic connector in this release: HeyClicky exposes separate Settings → Integrations rows and separate Composio toolkits for Gmail, Sheets, Calendar, Drive, and Docs.

Routes: `/agent/composio/session`, `/agent/integrations`, `/agent/integrations/`. `IntegrationSuggestionMonitor` with a `LearningRegistryEntry` learns which toolkits you keep needing and nags for the connection (`clicky.integrationSuggestions.snoozedUntilByToolkit.v1` — this machine has snoozed `youtube` until 2026-06-02). Custom connectors: `ClickyCustomConnectorOAuthClient`, `…SecretStore`, `…Store`.

There is a hard product rule: **the agent can never run OAuth itself.**

> For Composio app connections, the needed flow is HeyClicky Settings → Integrations, not agent-run OAuth.
> Do not use Computer Use to operate HeyClicky's own Settings/Integrations setup flow.

That's a sharp, deliberate boundary — otherwise the agent could grant itself new capabilities through its own UI.

**Composio writes are treated as contracts:**

> Do not infer Composio argument aliases across snake_case, camelCase, shorter names, or similar-looking fields. A `successful: true` response is not enough for writes; verify the user-visible result with a structured read-back… If verification fails, repair and verify again, or report uncertainty instead of claiming completion.

Plus schema caching (`COMPOSIO_GET_TOOL_SCHEMAS`, ~10 min TTL) to avoid burning context.

### 3.11 Routines / Remote Tasks

`<ROUTINE>` is a real, shipped feature with a JSON contract:

```json
{"action":"create","every_minutes":10,"title":"HeyClicky mentions",
 "task":"Research new public mentions of HeyClicky and summarize who, where, and why it matters"}
{"action":"update","title":"Weekly Digest","every_minutes":10080,
 "task":"Summarize the week's customer feedback in this chat"}
```

The model can *propose* a routine; the **app** owns the schedule (`/agent/cron/`, `/agent/cron/list`, `clicky-crons-mcp`, `ScheduledAgentCronDetailResponse`). The model instructions forbid the child agent from touching `clicky-crons` directly — a clean layering rule. Run semantics are explicit: *"This is the first run of a repeating routine. Do the task fully this time; later runs will report only what changed."* …and *"Do not set up any repeat yourself."*

Politeness is designed in: `keep-awake assertion ON (routines armed, on AC power)`, and *"HeyClicky stays quiet while you're on a call or sharing your screen, and in Do Not Disturb your scheduled routines finish quietly. Finished work waits in the chat and the notch shows how many Clickys have something new."*

### 3.12 Backend & data

`api.heyclicky.com` — the "Worker". Endpoints recovered from the binary:

```
/agent/openai/v1                    model proxy
/agent/session-token                app-minted API key
/agent/turn-lease/{,continue,complete}
/agent/realtime/{session,turn,warmup}
/agent/realtime/google-calendar/events{,/create}
/agent/realtime/spotify/search
/agent/composio/session
/agent/integrations{,/}
/agent/cron{,/list}
/agent/proactive-agents
/agent/notifications{,/,/read-all}
/agent/agent-messages, /agentMessage/{delta,thinking/delta}
/agent/record-agent-launch
/agent/jev/systemone
/skills/{library,create,creations,activations/sync}, /skill/
/programs, /projects, /authors, /agents/
/me/{memory,memory/save,plan,referral,referral/claim,referral/code,
     account/delete,calendar/upcoming,discovery-channel}
/billing/{checkout,portal}
/clickys/organize-history, /codex-thread-launch, /codex-thread-title
/runtime/{model-policy,tool-policy}, /onboarding/starter-plan
/app-config, /auth-callback, /oauth/login
```

Supabase project `mrpvynsdsnimuisyhkow` handles auth, Postgres, and Storage (skill logos at `…/storage/v1/object/public/skill-logos/…`).

**Local data model** (`~/Library/Application Support/Clicky/`):

| Path | Contents |
|---|---|
| `CodexHome/` | 83 MB. Codex's own home: `config.toml`, `sqlite/{logs_2,thread_history_1,state_5,queue_1,memories_1,goals_1}.sqlite`, `sessions/YYYY/MM/DD/rollout-*.jsonl`, `skills/`, `shell_snapshots/`, `task-assets/`, `thread-writer-locks/`, `auth.json` |
| `projects/agents/<slug>/` | Per-Clicky workspace: `AGENTS.md`, `output/`, `tmp/` |
| `SkillLibraryCache.json` | 2.1 MB marketplace cache |
| `HomeSpaceCache/` | `thread-history.json`, per-thread transcripts, `turn-journal/` |
| `cua-driver-policy.yaml`, `cua-driver-managed-policy.rego` | Written by the app, overwritten each daemon start |

`CODEX_HOME` is redirected so HeyClicky's agent state is fully isolated from a user's own Codex CLI — a thoughtful isolation choice that also means **uninstalling Clicky does not delete the workspace folders**, which are in Application Support.

Rollout JSONL event schema (233 events in a 6m45s turn): `session_meta`, `turn_context`, `world_state` (ships `agents_md` text — the memory file is injected as world state, not re-read), `event_msg/{task_started,task_complete,token_count,item_completed}`, `response_item/{message,reasoning,function_call,function_call_output}`. Reasoning payloads are `encrypted_content` — server-side encrypted reasoning, not exposed to the client.

Observed tool usage: `exec_command` ×25, `view_image` ×8, `write_stdin` ×1. Plus MCP tools when needed. Notably the agent used shell + screenshots, not Computer Use, for a web build — consistent with the routing doctrine.

---

## 4. End-to-end: one turn

```
USER: presses push-to-talk / clicks the notch, says a request
  │
  ├─ ClickyDictationController → hands-free hotkey OR mic capture
  │    └─ Deepgram streaming → text        (fallback: Apple Speech on-device)
  │
  ├─ RealtimeVoiceController decides: chat turn, or steer an ACTIVE turn?
  │    "the user may have selected an older HeyClicky thread from history before speaking"
  │
  ├─ CompanionManager resolves route:
  │    fresh thread │ resume existing thread │ STEER a running turn
  │    └─ Resolving <COMPUTER_USE_REQUEST> from the running agent's last output
  │
  ├─ CodexProcessManager:
  │    ├─ GET /agent/turn-lease/          → acquire lease (task/turn/lease UUIDs)
  │    ├─ spawn Codex CLI, CODEX_HOME=…/CodexHome, config.toml already set
  │    │    approval_policy=never · sandbox=danger-full-access
  │    │    model=gpt-6-luna via api.heyclicky.com/agent/openai/v1
  │    │    <lease_metadata> + skill instructions + AGENTS.md memory
  │    └─ CodexProtocolClient streams JSONL:
  │         reasoning (encrypted) → commentary → function_calls → token_count
  │         └─ /agentMessage/thinking/delta → HUD "thinking dots"
  │         └─ /agentMessage/delta → live transcript in the chip
  │
  ├─ Agent needs to act on the Mac:
  │    └─ mcp__computer_use__click(...)  → HTTP 127.0.0.1:63162/mcp
  │         └─ HeyClicky consent gate ──► allowed? ──no──► refuse
  │              │yes                                      │
  │              ▼                                         ▼
  │         cua-driver daemon                      agent emits <COMPUTER_USE_REQUEST>
  │           ├─ Rego policy: background only?          └─ HeyClicky shows Allow / Not now
  │           ├─ AX element_token, or window-scoped px       (user re-taps → retry)
  │           ├─ returns path/verified/effect/escalation
  │           └─ agent re-snapshots & diffs to prove it
  │
  ├─ Agent final message:
  │    <SUMMARY> → TTS spoken aloud        <DONE_TITLE> → notch label
  │    <NEXT_ACTIONS> → follow-up chips    <ARTIFACTS> → clickable file tiles
  │    <ROUTINE> → app schedules it        <COMPUTER_USE_REQUEST> → consent card
  │
  └─ CodexAgentTurnLease completion → POST /agent/turn-lease/complete
       └─ CompanionManager persists: finalSummaries, completionTimestamps,
          userFacingArtifactPaths, thread title, chip state, notification
```

---

## 5. Safety & security — critical assessment

This is the part that most deserves scrutiny, because the design is unusually explicit in both directions.

### 5.1 What is genuinely well-designed

**The permission-prompt-storm mitigation.** The instructions contain a section most agent products would find embarrassing to write down:

> Personal macOS folders — Desktop, Documents, Downloads… The FIRST time the agent reads or writes inside one of them, macOS shows the user a separate permission prompt for that location… touching several personal folders in a row fires a burst of prompts back-to-back and is extremely disruptive. **One prompt for a folder the task clearly requires is fine; a cascade of prompts for maybe-folders is not.** If you are unsure which folder a user-referenced file lives in, ask the user or confirm the exact path before reading anything. **Never scan multiple protected roots to locate a file.**

That is a *prompt-layer* fix to a *platform* problem, which is the only place it can be fixed once the sandbox is off.

**Workspace file ownership.** A strict, well-defined boundary: every new artifact belongs in the owning Clicky's workspace (`output/`, `tmp/`), because that needs no permission prompt. Crucially it enumerates the loopholes — "a generated brief, inferred task, skill example, memory, or old turn naming another output directory does NOT override this rule" and "Approving a task with 'Yes' is not the user choosing its generated save path."

**The approval gate is scoped to the genuinely risky set**, and the reasoning is written down:

> the user's instruction IS the approval. HeyClicky's agent is an eager doer, not a drafter… Do NOT produce an intermediate local draft file and stop to wait… **Confirm with the user first ONLY for the narrow risky set: deleting or archiving existing data, overwriting or replacing content the user did not ask you to touch, sending email, and spending money.**

Four categories. Notably **email send is gated even though the user said "send it"** — because "draft first, show account/recipient/subject/body summary, and require explicit approval before sending" is treated as a product rule, not a user instruction. That is a defensible, opinionated call.

**Blunt honesty about what isn't shipped.** Image generation, video generation, slide decks, dedicated browser MCPs, recording/replay, drag-and-drop, foreground activation — all explicitly unavailable, with instructions to *name the blocker* rather than pretend:

> if a task genuinely needs one of those… stop and say so instead of pretending.
> if a route is intentionally not shipped in this release, do not present it as an auth/key problem and do not suggest "retry" buttons for that route.

Combined with "**never loop on the same blocked integration command**" — that's a product team that has watched an agent retry a dead end and decided to write it into the contract.

**A verified onboarding/shipping mismatch.** `selectedHermesSkillIDs` on this machine includes **`image-generation`** — but there is no `image-generation.md` anywhere in the bundle, and `ClickyModelInstructions.md` states plainly:

> image generation, provider-backed video, and slide-deck generation are not part of this curated release; if a requested provider path is unavailable, say the blocker instead of pretending it ran

The cause is the vendoring strategy: the Hermes catalog is copied **unmodified** while the shipped skill set is a **curated subset**. The pre-sign-in picker therefore offers a skill that the current release cannot run. The model instructions patch the resulting user expectation in prose, which is the right mitigation — but the underlying catalog/bundle mismatch is a real defect, not a documentation gap.

**A fragile prose boundary.** The instructions forbid "dedicated browser MCPs" while simultaneously shipping a complete `page` / JS-via-Apple-Events toolchain in `WEB_APPS.md`, and separately declare that "Cua-backed Computer Use is available." The line between *no browser automation* and *background browser-window control* is drawn in language rather than in capability. This works only as long as the model reads the prose carefully — it is the most brittle class of guard in the whole system.

### 5.2 What is genuinely risky

**The sandbox is off and the model is told "never."** `danger-full-access` + `approval_policy=never` + a voice UI + a 258k context + a shell tool + `multi_agent = true`. A single prompt-injection payload on a web page the agent reads can plausibly cause arbitrary file modification and arbitrary command execution with **zero interactive confirmation**. The `<COMPUTER_USE_REQUEST>` gate protects GUI input. It does **not** protect `exec_command`.

The bundled model instructions do acknowledge this shape of risk ("the user's instruction IS the approval", "act on the write the user asked for"), and the risk is scoped in practice by HeyClicky never opening arbitrary attacker-controlled web pages *as the user's logged-in session* — but `exec_command` + `curl` + `danger-full-access` is a complete exfiltration primitive if the injection lands. **This is the single biggest architectural risk in the product**, and it is a deliberate, informed trade rather than an oversight — the Rego policy and the consent gate exist precisely because the rest was waived.

**The Rego policy is honest about its own limits.** It blocks `scope: "desktop"` and specific shortcuts by name-matching. A `hotkey` combo outside those lists is allowed. The policy defends a *specific enumerated threat model* (focus steal) and nothing more — which is fine, because that is exactly the guarantee being sold, and it should not be mistaken for a general sandbox.

**The proxy is a single point of trust.** `api.heyclicky.com/agent/openai/v1` sees every prompt, every tool call, every screenshot-derived context, and mints the API key the agent spends against. Combined with PostHog analytics and Sentry crash reporting (breadcrumbs, network tracking, file-IO tracking, `SentryExtraContextProvider`), a meaningful amount of user context transits or lands in third-party infrastructure. `ATTRIBUTION.md` is admirably honest about vendored code; there is no comparably visible privacy statement in the bundle.

**`com.apple.security.app-sandbox = false`.** Unavoidable for this product (Accessibility + Screen Recording + arbitrary file access), but it means **no Gatekeeper containment** once running. The only perimeter is the signed bundle + Hardened Runtime (which is on: `flags=0x10000(runtime)`, notarized) and the user's own consent.

**Workspace data survives uninstall.** `~/Library/Application Support/Clicky/projects/agents/*` holds agent outputs and `AGENTS.md` memory containing user preferences. There is a `/me/account/delete` route, which is good; but local residue is not obviously cleaned.

---

### 5.3 Privacy posture, from the other direction

HeyClicky publishes a `/trust` page, which is rarer than it should be. Verbatim claims, reality-checked against the binary:

| Claim | Reality check |
|---|---|
| "we only see your screen when you press the hotkey" | Consistent — `ScreenshotManager.captureScreen()` is hotkey-driven; `ScreenRecordingGuideBoundaryTracker` is onboarding-only. |
| "we never store your raw screenshots. they're gone after they're processed" | Plausible — no screenshot store in `~/Library/Application Support/Clicky`. |
| "quit the app and nothing runs on your mac. no background services, no helpers" | **Tension.** Two supervised helpers run *while running*: the `cua-driver` daemon (66 MB) and a Codex subprocess per turn. True only in that both die with the parent. |
| "the only third parties we share with are posthog… and sentry" | **Incomplete.** The binary also calls `api.openai.com/v1/realtime`, `api.deepgram.com/v1/listen`, and Composio when configured. |
| "no soc 2 or iso 27001 yet" | Honest, and unusual to state plainly. |

**The privacy policy is more current than the trust page.** Policy §3.2 names **Anthropic, OpenAI, Deepgram, and Cerebras**; the trust page still says "either anthropic or openai." Real gaps: **no subprocessor list** (Stripe and the sign-in provider are unnamed despite both being used) and **no data-residency region**.

**Where the binary is blunter than the marketing.** Three things `/trust` does not clearly cover:

1. `selectedHermesSkillIDs`, `clicky.roster.v1`, and `clicky.agentSpace.suggestedAgents.v1` persist rich behavioural profiling (portraits, starter-agent engagement timestamps, snoozed toolkits) in `UserDefaults`, readable by any process.
2. Sentry and PostHog are wired for network and file-IO tracking (`SentryNetworkTracker`, `SentryFileIOTracker`, `SentryBreadcrumbTracker`, `SentryExtraContextProvider`), with DSN and API key hardcoded in `Info.plist` — normal for client SDKs, but it makes the telemetry path inspectable and immutable without an update.
3. `/agent/realtime/turn` means live voice audio transits `api.heyclicky.com` on its way to OpenAI — a second hop the trust page does not obviously cover.

**Overall:** the posture is materially better than most AI desktop tools. There is a public trust page, credentials moved to the Keychain, an audit-found exposure hole was locked down, analytics are purged on account deletion, and the team *publicly killed* proactive agents when users objected. But it is a cloud-only, no-SOC-2, Mac-only product asking for Accessibility + Screen Recording + Microphone on an unsandboxed closed-source binary. Both the trust page and the binary are honest about that — neither pretends to be safer than it is.

---

## 6. Product & strategy read

### 6.1 The wedge is companionship; the moat is the harness

Almost every AI agent product starts from the model. HeyClicky starts from **a character in a notch**. The agent is downstream of the relationship. That is the correct order for a consumer product, and it explains why the product ships things a benchmark-driven team would skip: 10 realtime voices, 16 onboarding preview voices, a procedural portrait system with `backgroundPaletteVersion`, hairstyles named *"Apricot glow"*, a `PowerUpAvatarView`, agents that hold props, and a `tapback-thumbs-up.wav`.

But the **defensible engineering is not the character** — a character is copyable. It is:

1. **`cua-driver` + the no-foreground contract.** A backgrounded, focus-steal-free, Rego-gated macOS computer-use driver is a genuinely hard artifact, and the attention to *perceptual* failure modes (the menu-bar render bug) reveals someone who has stress-tested it against human observers, not just against itself.
2. **The turn-lease protocol.** Making a terminal-oriented CLI into a server-authoritative, resumable, backgroundable, multi-client agent runtime is real protocol engineering.
3. **The result-tag protocol.** `<SUMMARY>` for voice, `<ARTIFACTS>` for the HUD, `<NEXT_ACTIONS>` for the loop — a clean, language-agnostic contract between a chat model and a non-chat UI.
4. **The behavioral contract.** 25 KB / 106 lines of dense, adversarial instruction that encodes thousands of hours of watching agents misbehave. The `Farza 2026-09-23` annotation on the "HIGH SIGNAL, always" rule is the tell — it's a postmortem from a real user complaint, dated, still in the prompt.

### 6.2 Skills: the platform bet

The marketplace is the most ambitious piece. 200 skills / 118 authors in what appears to be an early private beta, with `built_for_program` tags spanning Claude Code, Codex, and ~50 creative apps. If HeyClicky becomes the place where a persona like *"a patient Premiere teacher"* is authored once and runnable everywhere, it stops being a Mac menu-bar app and becomes an **agent distribution platform** — with HeyClicky's own runtime as the default host and the notch UI as the wedge.

The signs that this is the intent, not a side feature:
- `team_shared`, `/share-to-team`, `/unshare-from-team` — team distribution
- `/skills/create` + `QueuedCreationResponse` — user-generated supply
- `/skills/activations/sync` — engagement tracking
- `collections/best-sellers` + `/programs` — merchandising
- `/clickys/organize-history` — a cast/roster management surface

### 6.3 What I'd watch

| Risk | Signal |
|---|---|
| **Marketplace cold start** | 200 skills is a seed community. Two-sided marketplaces die here. The bundled 15 skills are the fallback. |
| **Exec + no sandbox** | Any credible prompt-injection report ends the product. The `exec_command` path has no gate equivalent to `<COMPUTER_USE_REQUEST>`. |
| **Bundled-Rust-binary review** | Codex + cua-driver ship as opaque binaries. Enterprise/education buyers will ask. |
| **Routines ≠ cloud cron** | The instructions say Remote Tasks aren't shipped in *this* release while the routes and `<ROUTINE>` contract clearly exist — the product is mid-migration and the boundary is documented inconsistently. |
| **Voice-only differentiation** | Realtime voice is table stakes by 2027. The persona + memory + no-focus-steal combination is the actual moat. |

### 6.4 Engineering quality, honestly

**Strong:**
- Native SwiftUI with real system frameworks — no Electron tax, no visible CPU floor
- Rego policy for argument-level safety semantics, not just tool allowlists
- Enumerated failure modes with honest workarounds (minimized windows, off-Space SwiftUI, Chromium sparse AX, canvas apps, `⌘L`)
- Result-effect honesty fields (`confirmed` / `unverifiable` / `suspected_noop` / `escalation`)
- Universal binaries with per-arch vendor trees (`vendor/x86_64-apple-darwin`, `vendor/aarch64-apple-darwin`) — Intel Macs still first-class
- `CODEX_HOME` isolation; per-agent workspaces with file-ownership rules
- Admitted warts documented in-tree (`docs/refresh-hermes-skills.md` TODO)
- Shipping `rg` inside the runtime so agent searches don't depend on the user's PATH

**Rough:**
- Naming: `HeyClicky` / `Clicky` / `leanring-buddy` / `Buddy` / `Hermes` / `Clicky` / `Clickies`
- A 25 KB prompt with a copy-paste date annotation is a changelog masquerading as a spec
- Hand-committed vendored skills with a TODO refresh path
- `cua-driver-policy.yaml` and the Rego file duplicate the same policy in two languages
- Instructions assert features are "not shipped" that clearly are

### 6.5 A tell about the build

Two build-machine paths leaked into the shipped binary:

```
/nilesh/conductor/workspaces/clicky-closed/louisville-v1/leanring-buddy/
/nilesh/Library/Developer/Xcode/DerivedData/leanring-buddy-eofjqszcvnsiy
```

Conductor is a macOS-native CI for Xcode projects. So: project `leanring-buddy`, workspace `clicky-closed`, pipeline `louisville-v1`, build engineer **Nilesh Rathore** — who is also the most prolific skill author in the marketplace ("Claude Code 101", "Your hype coach for shipping a first AI-built app"). Composer ↔ platform engineer. And `ClickyGitCommitShortSHA = 99f33ebc` on branch `main-internal-release-build` is embedded in `ClickyBuildInfo.plist`, which is good practice.

---

## 7. Company, history & business model

*(This section draws on external sources — the product's own site, its public changelog, GitHub, YC's directory, and press coverage — rather than the binary. Cited separately from the reverse-engineering above.)*

### 7.1 The open-core origin — and why the bundle still smells like it

HeyClicky was **public, MIT, and open source for its first ~3 weeks.**

`github.com/farzaa/clicky` — *"Hi, this is Clicky."* — Swift, **7,667★ / 1,525 forks**, created 2026-04-07, last pushed 2026-04-28, 20 commits. Its `AGENTS.md` is the ancestor of the one still shipped in the bundle, and the architecture is recognizably the same product with a much smaller brain:

> macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window)… Uses push-to-talk (ctrl+option)… transcribes it via **AssemblyAI** streaming, and sends the transcript + a screenshot of the user's screen to **Claude**. Claude responds with text (streamed via SSE) and voice (**ElevenLabs** TTS). A blue cursor overlay can fly to and point at UI elements Claude references on any connected monitor.

Then, 27 April 2026, the repo README changed:

> **Update: April 27, 2026.** The existing codebase remains open source. Tinker with it, make it yours, start a company out of it, do whatever you want I don't mind. But, for all the new stuff I'm hacking on, gonna keep it private.

That single commit is the pivot. It explains three things I found in the binary:

1. **Why `leanring-buddy` and `learning-buddy` survive.** The open-source Xcode project was named `leanring-buddy`; the typo was never corrected through three renames (Clicky → Clickys → HeyClicky) and is still in `farzaa/clicky`'s `leanring-buddy.xcodeproj` *and* in the shipped `AGENTS.md`.
2. **Why an MIT `LICENSE` and an `ATTRIBUTION.md` for vendored skills sit inside a closed-source app.** The team kept the attribution discipline from the open era.
3. **Why the release repo has no LICENSE file.** `farzaa/clicky-releases` distributes the proprietary DMG; the MIT grant covers only `farzaa/clicky`.

The original ran a **Cloudflare Worker with exactly three routes** — `POST /chat` (→ `api.anthropic.com/v1/messages`), `POST /tts` (→ ElevenLabs), `POST /transcribe-token` (→ AssemblyAI, 480 s). Every one of those has been absorbed into the current "Worker" at `api.heyclicky.com`, which now also proxies OpenAI, mints tokens, owns the turn-lease protocol, and serves the skill marketplace. Its `AGENTS.md` also carries a warning that reveals the TCC fragility this product lives with:

> **Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

### 7.2 Version timeline — how it got here

Recovered from `heyclicky.com/changelog`, cross-checked against the Sparkle feed and the shipped binary.

| Version | Date | Headline | What changed |
|---|---|---|---|
| ~Apr 2026 | — | **"Clicky"** | Open-source screen-aware voice teacher. Claude + AssemblyAI + ElevenLabs. Blue cursor flies along a bezier arc to point at UI elements via `[POINT:x,y:label:screenN]` tags. |
| v1.0.12 | 2026-05-04 | **"HeyClicky can click"** | "Thanks to our friends at **Cua**, HeyClicky can now click." First computer-use. Honestly caveated: *"this feature is interesting, but early. Sometimes it breaks."* |
| v1.0.33 | 2026-07-06 | "Spatial context, skills, proactive agents, memory" | Screen scribbling/annotation, ~100-skill library, proactive agents. |
| v1.0.37 | 2026-07-14 | "Dictation, and screen-aware dictation" | Global dictation ~450 ms, 50+ languages, Fn+Control hold / double-tap. |
| v1.0.39 | 2026-07-15 | Privacy retreat #1 | *"We removed proactive activity tracking and all accessibility-data collection, and the afternoon proactive slot went with it."* |
| v1.0.44 | 2026-07-23 | **"HeyClicky for teams"** | Team v0, first pilot customer, team-shared skills. |
| v1.0.45 | 2026-07-31 | Security fix | Account deletion now erases analytics; *"we locked down a data-exposure hole found in a security audit."* |
| v1.0.46 | 2026-08-01 | **Proactive agents removed** | *"if any of this makes you uneasy, let us know. Some of you did. We listened."* All local activity tracking deleted itself on update. |
| v1.0.47 | 2026-08-13 | Keychain | *"Sign-in credentials now live in the macOS Keychain."* → `ClickyKeychainStore`. |
| v1.0.48 | 2026-08-25 | **New computer-use engine** | *"Computer use moved to a faster native driver. Background clicks stay scoped to the target window and never move your real cursor."* → the `cua-driver` in the bundle. |
| v1.0.49 | 2026-09-12 | **"Introducing Clickys"** | The pivot. Persistent named agents. *"HeyClicky is 20 weeks old, and after 1.2 million messages we noticed we barely used agents ourselves."* Custom MCP connections. **Skills removed** — *"on pause… we plan to bring them back in a new form."* |
| v1.0.51 | 2026-09-18 | Connector honesty | *"A custom connector used to turn green the moment you saved a token… HeyClicky now makes a real request when you save or edit a token."* |
| v1.0.52 | 2026-09-24 | "A smaller notch, and invite your friends" | Cursor overlay **removed** (it drew over the user's app / caused black window captures in Loom). Referral program. Per-conversation consent. **Native driver.** |

**Three things this timeline proves about the code I read:**

- **The Rego/YAML policy and the `<COMPUTER_USE_REQUEST>` gate are the product working as intended.** v1.0.48 introduced background-only clicks; v1.0.52 had to *remove the visible agent cursor* because it "could draw over the app you were using or in the wrong place. That same cursor layer is why a window screenshot, or sharing a single window in Loom or a call, could come out black or covered." The floating cursor was the old foreground-honest approach; background-only input is the new one. The policy file enforces the new contract at the daemon.
- **The skills marketplace was a comeback, not a launch.** v1.0.49 removed skills; v1.0.52's live cache holds 200 skills and 118 authors. It came back bigger and social.
- **Proactive agents were killed and partially resurrected.** v1.0.46 removed them over privacy concerns, yet v1.0.52's binary still contains `ProactiveAgentsClient`, `/agent/proactive-agents`, `IntegrationSuggestionMonitor`, and a live `clicky.agentSpace.suggestedAgents.v1`. What returned is *server-decided, one-shot, daytime* — not local background surveillance. The `/trust` page says so: *"the one exception: once a day, while the app is open, clicky reads the integrations you've connected to build your morning suggestions."* That's a genuine, considered redesign — the original tracked *you*, the new one reads *your connections*.

### 7.3 Business model

| Plan | Price | Talk | Dictation | Agent messages |
|---|---|---|---|---|
| **Free** | $0, no card | 25 / mo | "plenty of dictation" | 25 / mo |
| **Pro** | **$20 / mo** | Unlimited | Unlimited | 150 / mo |
| **Max** | **$100 / mo** | Unlimited | Unlimited | **1,000 / mo** |

- Annual **−20%**. Student discount 50% off month one. All month-to-month, *"cancel in one click."*
- **Referral:** `heyclicky.com/@yourname` → referrer earns **25% of plan price every month for up to 12 months**; friend gets 25% off month one. (Matches `clicky.referral.pendingDeepLinkOwner.v1` + the `clicky://` URL scheme + `ClickyOnboardingDiscoveryChannel = "friend"` on this machine.)
- **Teams v0:** one subscription, mixed Pro/Max seats, small dashboard, team-shared skills. Manually onboarded — `hi@heyclicky.com`. No public pricing.
- **Windows** is waitlist-only (`tally.so/r/kdWMjM`). Mac-only is a hard product constraint.
- India UPI support added in v1.0.41.

**The metering insight:** Talk and dictation are unlimited on paid tiers; **only agents are metered**. That is deliberate — *"what happens if i hit my agent limit? talk keeps working, always."* They give away the interface and charge for autonomy. At $20/150 agent messages that's ~$0.13/message, far above token cost, so the quota is a **behavioural throttle, not cost pass-through**. Max is 5× price for 6.7× volume (~$0.10/msg) — normal decoupled-tier laddering, mildly penalising heavy agent users toward the $100 tier.

### 7.4 Traction & funding

| | |
|---|---|
| Company | **Humansongs, Inc.** · Y Combinator **S26** (Spring 2026) · SF |
| Primary partner | **Aaron Epstein (a16z)** |
| Claimed users | "25,000+ happy users" (homepage) |
| Paying | "We recently passed 1000 paying customers. And, onboarded our first enterprises this week." — @FarzaTV, ~27 Aug 2026 |
| Volume | "1.2 million messages" at v1.0.49 (~20 weeks in) |
| Team | 6 open roles (eng ×2, design, ads, IG/TikTok creator, intern) + "Invent a role". Equity 0.25%–2.5%. |
| Windows | waitlist |
| Funding amount | ⚠️ **Unverified.** YC states no figure. A third-party claim of "~$500,000 seed from YC, April 2026" is self-caveated as unconfirmed. Do not cite. |

Founder: **Farza Majeed** ([@FarzaTV](https://x.com/FarzaTV), ~127K), [farza.com](https://farza.com), 🇵🇰🇺🇸. Self-described history: first company at 13 (reselling Dragon Ball Z games on eBay → $100K/yr by high school); founded **Buildspace** (YC S20, a16z + YC, $10M raised, 100K+ students, physical SF campus, wound down Aug 2024); **ZipHomeschool** (a16z invested $2M after a "Twitch for teachers" pivot hit 100K class joins/week); **zipschool** (150K kids); **visor** (real-time vision coaching in Overwatch — *"we got really big actually, then, blizzard banned us oops"*); CTO at **kanga**; `DeepLeague` (1,211★), `gemini-bball` (1,164★), `freewrite` (1,371★).

> ⚠️ **Not Typefully, not Poe.** I initially conflated Farza with the Typefully/Poe founder. There is no evidence connecting them; those are separate companies.

### 7.5 Reach — and its shape

Virality is **social, not technical.** Product Hunt: **#6 Product of the Day, 145 upvotes, 178 followers**, launched ~Apr 2026, hunter Rohan Chaubey. Press: **XDA** (19 Apr 2026, *"the most useful thing I've tried in months"*), **Lifehacker/David Nield** (21 Apr), DailyDropout, Cmd+AI YouTube. The demo tweet hit ~15,000 likes / ~3M views. Notable public endorsements: **Greg Brockman (OpenAI)** (2.7K likes), **Lenny Rachitsky** (526), **Josh Pigford** (154), **Aaron Epstein** (102).

Hacker News is **effectively absent** — one 4-point, 0-comment link-drop for `farzaa/clicky`, and two later list-mentions with 1 and 0 comments. That is consistent with a consumer/creator product (kids making games, founders researching competitors, content creators learning After Effects / DaVinci Resolve) rather than a developer tool. A clone ecosystem followed: `shujanshaikh/glide` (45★), `unn-Known1/clickyX`, `dabit3/heyclicky-clone` (a SwiftUI clone), `Skilly` (Apache-2.0 fork that became a $19/mo tutor), and `nash-aigc/HeyClicky-Reversed` — a Chinese-language reverse-engineering of v1.0.51, which is a fair signal that people want the now-private code.

### 7.6 Competitive frame

There is no strong head-to-head review, which is itself informative. Positioning across sources:

- **vs Claude Cowork** — *"Choose Claude Cowork for Anthropic's broader desktop-agent workflow and file work rather than a cursor-first teaching interface."* Claude Cowork leads on true desktop automation; HeyClicky leads on being native, voice-first, and not an IDE.
- **vs Cursor / Windsurf / Claude Code** — *"HeyClicky trades codebase focus for general macOS productivity."*
- **vs VoiceOS** — the only real feature-table comparison exists on a **competitor's** marketing page (`voiceos.com/compare/clicky`), and its Clicky column is visibly stale (still links `clicky.so`, claims no dictation).
- **Not in:** Manus, Raycast AI, ChatGPT Desktop comparisons. HeyClicky simply isn't in most head-to-head sets yet.

The sharpest third-party verdict, from The Rundown AI: *"The interface is its real advantage. The tradeoff is trust."*

---

## 8. Reference sheet

### 8.1 Identity

| | |
|---|---|
| Bundle | `com.humansongs.clicky` · `HeyClicky` · 1.0.52 (63) |
| Codenames | `leanring-buddy`, `Buddy`, `Clicky`, `Hermes` (skills) |
| Author | Farzain Majeed · `2UDAY4J48G` · notarized, Hardened Runtime |
| Build | Xcode 27, macOS SDK 27.0, branch `main-internal-release-build`, SHA `99f33ebc` |
| Release feed | `farzaa.github.io/clicky-releases/appcast.xml` (GitHub Pages → GH Releases) |
| Cadence | 7 Sparkle items (1.0.46 → 1.0.52), 1 Aug – 24 Sep 2026, ~weekly |
| Websites | `heyclicky.com`, `/changelog`, `api.heyclicky.com`, `team.heyclicky.com` |
| Community | `reddit.com/r/heyclicky_`, WhatsApp group, `heyclicky.canny.io/feature-requests` |

### 8.2 Stack

```
UI/agent shell   Swift + SwiftUI + AppKit + Combine (no JS runtime)
Agent runtime     OpenAI Codex CLI 0.152.1 (bundled Rust binary, gpt-6-luna)
Computer use      cua-driver 0.28.2 (bundled Swift daemon) + OPA/Rego policy
Integrations      Composio MCP (optional, per-app toolkits)
STT               Deepgram streaming + Apple Speech fallback
TTS/voice         OpenAI Realtime API (10 voices) + 16 onboarding previews
Auth/backend      Supabase (auth/Postgres/Storage) + custom "Worker" at api.heyclicky.com
Updates           Sparkle 2.9 (EdDSA-verified, hourly checks)
Analytics         PostHog · Errors Sentry (sentry-cocoa) · PLCrashReporter
Skills            Anthropic SKILL.md format; vendored from NousResearch/hermes-agent
Model routing     api.heyclicky.com/agent/openai/v1 → OpenAI Responses API (proxy)
Safety            app consent gate (per-turn) + YAML/Rego daemon policy (permanent)
```

### 8.3 Notable Swift types recovered

`CompanionManager` · `CodexProcessManager` · `CodexAgentSession` · `CodexProtocolClient` · `CodexHUDWindowManager` · `CodexLaunchFlightManager` · `ClickyCuaDriverDaemonController` · `ClickyLocalRootToolExecutor` · `ClickyDictationController` · `BuddyDictationManager` · `RealtimeVoiceClient` · `RealtimeDuplexAudioEngine` · `NotchWindowManager` · `OverlayWindowManager` · `HandoffManager` · `HandoffRegionSelectOverlayManager` · `ScreenAnnotationManager` · `ClickyPowerUpManager` · `PowerUpSkillFileStore` · `ClickySkillLibraryBackend` · `ClickyOrganizerClient` · `ProactiveAgentsClient` · `IntegrationSuggestionMonitor` · `SupabaseAuthManager` · `ClickyKeychainStore` · `ClickyCustomConnectorOAuthClient` · `BillingClient` · `AccountDeletionClient` · `PermissionFlowCoordinator` · `AgentPermissionInspector` · `ClickyJevUseDriverClient` · `ClickyUpcomingCalendarBackendClient` · `ClickyProgramLogoRegistry`

### 8.4 The instruction contract, in one line

> "HeyClicky handles microphone input, screenshots, onboarding, the floating HUD, and spoken task-finished summaries. **You handle reasoning, tools, concise commentary, and the final answer for the work the user sent you.**"

The division of labor is stated at the top of the 25 KB contract: **the app owns presentation and safety; the model owns work.** Everything else in the codebase is a consequence of that sentence.

---

## Appendix A — Method & confidence

**Sources, in order of reliability:**

1. **The shipped binary** (`Contents/MacOS/HeyClicky`) — `otool -L` linkage, `codesign -dv --entitlements`, and Swift symbol demangling (`$s…` → 1,432 unique type/method names). Authoritative for architecture.
2. **Live runtime state** — `~/Library/Application Support/Clicky/` (Codex `config.toml`, rollout JSONL traces, the two agent workspaces and their `AGENTS.md`, the Rego policy, the 2.1 MB skill cache, `UserDefaults`). Authoritative for behaviour.
3. **Shipped documentation** — `ClickyModelInstructions.md` (106 lines), 15 bundled `SKILL.md`s, `ATTRIBUTION.md`, `AGENTS.md`, the Hermes skill catalog. Authoritative for intent and contracts.
4. **External research** — `heyclicky.com` (+ `/changelog`, `/trust`, `/about`, `/careers`, `/privacy-policy`), the Sparkle appcast, GitHub (`farzaa/clicky` @ 7,667★, `farzaa/clicky-releases`), YC's directory, trycua/cua @ 26,809★, TypeSafe AI, Composio, and press (XDA, Lifehacker, Product Hunt, The Rundown, HokAI).

**Confidence levels:**

| Claim type | Confidence |
|---|---|
| Architecture, linkage, symbols, config, traces, policies | **Very high** — directly read from the installed binary and its data |
| Feature inventory, routing rules, safety contracts | **High** — read verbatim from shipped docs and code |
| Product/company/pricing/history | **High** — first-party site, changelog, GitHub, YC |
| cua-driver internals | **High** — upstream README + local README + local Rego policy |
| Jev performance figures | **Medium** — vendor-reported benchmarks |
| Funding amount | **Unverified — deliberately omitted as a number** |
| Reddit sentiment | **Low** — Reddit bot-blocked; only titles/snippets seen, not comment bodies |
| `/about` page timeline dates | **Low** — contradicts GitHub/changelog by ~7 months; treat as a typo |

**Known gaps I did not close:** the Skarpos backend source; the Supabase schema; whether `gate decisions` on the consent card are recorded server-side; the behaviour of `/agent/jev/systemone` at the wire level; whether `Cerebras` serves a fast-model tier or something else; and any Windows/iOS code, which does not exist yet.

**Corrections made during this research**, recorded for honesty:

- I initially attributed HeyClicky's authorship to the **Typefully/Poe** founder. **Wrong.** It is Farzain Majeed, ex-Buildspace / ZipHomeschool.
- I initially claimed a `computer-use` vs `computer-use` naming inconsistency in the instructions. **Wrong** — the naming is consistent; Codex hyphen-mangles it to `mcp__computer_use__*` in tool names. Replaced with a *verified* defect (the onboarding picker offers an `image-generation` skill the release does not ship).
- Several third parties assume Electron from the 377 MB DMG. **Wrong** — verified no Chromium/Node linkage; the bulk is a twice-bundled Rust Codex CLI plus onboarding video.

---

*Compiled 2026-09-28 from static analysis of `/Applications/HeyClicky.app` (v1.0.52, build 63) and its live runtime state, plus public research. No source code was available; class names and protocol details were recovered from Swift symbol mangling, shipped documentation, and live session traces. Findings about the company and product history are sourced separately in §7 and marked as external.*
