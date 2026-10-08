# Open-Source HeyClicky Alternatives — For Free, Fully-Customizable Mac Automation

**Compiled:** 2026-09-28 · Star counts/licenses/push dates verified via authenticated `gh api` on that date.
**Updated:** 2026-09-30 · Added Clawster + Utsuwa deep-dives (see `CLAWSTER-RESEARCH.md`, `UTSUWA-RESEARCH.md`). Current recommendation = Chunks v2 native plan in `CHUNKS-BUILD-PLAN.md` (notch shell, single assistant, memory-first). Below is preserved research.

---

## 0. The short answer

**No single free open-source project matches HeyClicky feature-for-feature.** But there are two genuinely good paths, and one of them already has the automations feature you asked for.

| Path | What you get | Cost | Effort | Verdict |
|---|---|---|---|---|
| **D. Chunks v2 (current)** | Native notch app, single assistant, memory+reminders+planner, permissioned control, trailer pointer, in-app moods | Free (Gemini free tier) | Medium — fork `farzaa/clicky` + build P1–P8 | ⭐ **Do this** — see `CHUNKS-BUILD-PLAN.md` |
| **A. Fork `clickyX`** | HeyClicky's exact feature set, cross-platform, **with a working cron scheduler already built** | Free, MIT | Low — clone and run | Fallback if native fails |
| **A2. Learn from `clawster`** | Pet UX, hotkeys, onboarding wizard, local tool classifier, Focus tools | Free, MIT | Learn patterns only | Adopt hotkeys/wizard/Focus, reject Electron+cloud lock |
| **A3. Learn from `utsuwa`** | BYOK/offline, app-owns-state memory, local embeddings, MCP hardening, Kokoro-local TTS | Free, **AGPL-3.0** | Learn patterns only — do NOT vendor code | Adopt registry/memory/MCP/consent patterns |
| **B. Fork `farzaa/clicky`** | The authentic HeyClicky ancestor, native Swift, 7.7k LOC, cleanest code | Free, MIT | Medium — base for Chunks v2 | Base for Chunks v2 |
| **C. Assemble from components** | Maximum control, best-of-breed, fully local | Free (API keys optional) | High | Best long-term, slowest to first win |

**Current recommendation (2026-09-30):** do **D. Chunks v2**. It keeps B as the base, takes hotkeys/onboarding/Focus from Clawster and registry/memory/MCP/consent from Utsuwa, stays MIT-clean (no AGPL code), and adds what neither has: notch shell, annotate+trailer-pointer, permissioned AX control, reminders/scheduler/planner.

**My recommendation:** start with **A**, because it is the only option where the feature you specifically asked for — automations — is already implemented, tested, and shipping.

### The one thing that changes the calculus

HeyClicky **was** open source. `github.com/farzaa/clicky` is **MIT, 7,667 stars, Swift, 23 files, 7,751 lines**, frozen 2026-04-28, not archived. The author wrote:

> "Tinker with it, make it yours, start a company out of it, do whatever you want I don't mind."

A clone ecosystem grew around it, and **one of those clones is now a more complete HeyClicky than HeyClicky.**

---

## 1. Tier A — `clickyX` (the closest thing to what you asked for)

**`unn-Known1/clickyX`** · MIT · Rust + Tauri + React · pushed **2026-09-28** (the day of this research) · stable **v0.2.1** with nightly builds.

I verified the automations feature is **real code, not a README claim**. `src-tauri/src/automation/mod.rs` is 574 lines:

```rust
pub enum Schedule {
    #[serde(rename = "interval")]
    Interval { seconds: u64 },
    #[serde(rename = "cron")]
    Cron { expression: String },
}
```

with a working 5-field cron matcher (`matches_cron`, `cron_field_matches`), JSON persistence (`load`/`save`), `AutomationEngine::tick() -> Vec<Automation>`, and unit tests for both schedule variants. Plus `commands/automation_cmds.rs` and a `skills/cron-helper` skill.

### Feature parity vs HeyClicky

| Capability | clickyX | Notes |
|---|---|---|
| Menu-bar / tray UI | ✅ | System tray + floating panel + per-screen overlay |
| Push-to-talk voice | ✅ | 5 hotkey presets |
| Always-on VAD + barge-in | ✅ | Better than HeyClicky's PTT-only |
| Wake word "Hey Clicky" | ✅ | |
| STT | ✅ | Deepgram / Whisper / AssemblyAI |
| TTS | ✅ | **System TTS — offline, no key needed** + ElevenLabs/Cartesia/OpenAI Realtime |
| Animated cursor + overlay | ✅ | Bezier-arc cursor, glow, scribbles, HIGHLIGHT/SHAPE annotation tags |
| Computer use | ✅ | `enigo`-based, **background mode (no cursor warp)** |
| Agent runtime | ✅ | **Codex** sidecar |
| Skills | ✅ | 64 bundled |
| **Automations** | ✅ | **Cron + interval, run history** ← your ask |
| Local HTTP bridge | ✅ | 29+ endpoints on `localhost:32123`, token auth, SSE |
| MCP | ✅ | Real stdio JSON-RPC |
| Google Workspace | ✅ | Status display, OAuth2 setup |
| Cross-platform | ✅ | **macOS + Windows + Linux** |

### What it lacks vs HeyClicky

- **Small numbers.** 25 stars, 3 forks. This is one person's project with nightly builds, not a team. Treat it as a starting codebase, not a dependency.
- **v0.2.x.** Early software. Expect breakage.
- **No procedurally-generated companion characters** — that's HeyClicky's actual differentiator, and it isn't reproducible here.
- **No skills *marketplace*** — 64 bundled skills, but no community economy.
- **Documentation is thinner** than HeyClicky's remarkably well-specified skills.

### Verdict

If your priority is **"HeyClicky's features but mine, with automations instead of agents,"** this is the starting point. Read the Rust before committing — MIT means you can rewrite it in whatever direction you want.

---

## 1b. Clawster — pet UX to learn from (MIT, do not fork wholesale)

**`wuyuwenj/clawster`** · MIT · Electron + React · ~30★ / 1 fork · v0.1.3 / staging 259 commits · `clawster.pet`. Full notes: `CLAWSTER-RESEARCH.md`.

- Was pure OpenClaw client (`127.0.0.1:18789`, `IDENTITY.md`/`SOUL.md`), all-local. Now hybrid: local Qwen 1.5B tool classifier (~200ms) + Cloudflare Worker → `gpt-4o-mini` + LanceDB `~/.clawster/memory/` (facts always-inject + emotional memories top-5, `text-embedding-3-small` 1536-d, dedup 0.92).
- Take: `Cmd+Shift+Space` / `Cmd+Shift+/` / `Cmd+Shift+A` hotkeys, 3-step wizard permission flow, Focus Mode block, tool layer (open/timer/volume), mood model.
- Reject for Chunks: Electron weight, cloud-chat lock (Pro coming), always-on desktop pet, no annotate/point/AX, tiny bus factor.

## 1c. Utsuwa — local-first patterns to learn from (AGPL, do NOT vendor)

**`JuiceBoxxGames/utsuwa`** · **AGPL-3.0-or-later since 0.12.1** (MIT only to 0.12.0) · SvelteKit + Tauri v2 + web `app.utsuwa.ai`. Full notes: `UTSUWA-RESEARCH.md`.

- App owns numbers; LLM suggests bounded JSON deltas; app clamps/applies; extraction fallback for small models. Memory 3-tier on-device (Dexie + localforage, 384-d `Xenova/paraphrase-multilingual-MiniLM-L12-v2` in-browser, 70% sim +30% importance). BYOK (OpenAI/Anthropic/Gemini/DeepSeek/Grok/Ollama/LM Studio) + fully offline (Kokoro-FastAPI, Whisper-local, OmniVoice). MCP built-in with Ask-before-run default + prompt hardening + stdio allowlists fail-closed. Reminders as system events (no sentiment side-effects).
- Take patterns only: registry, clamped deltas, local embeddings (P8 option), MCP gating, Kokoro-local, reminder/event rules.
- Reject: VRM/Three.js/AR/photo/dating-sim weight; photo-attach-only vision (no screen-awareness); no computer-use. **Never paste Utsuwa code into MIT Chunks.**

## 2. Tier B — `farzaa/clicky` (the authentic fork — Chunks v2 base)

**`farzaa/clicky`** · MIT · Swift · 7,667★ / 1,525 forks · 7,751 LOC across 23 files · 20 commits, all from 7–9 April 2026.

I cloned and read it. It ships an unusually complete `AGENTS.md` — every file documented with line counts, plus a `CLAUDE.md` symlink and an `agents.md`-spec header. It's a genuinely well-organised codebase.

### What you get

- Menu-bar-only app (`LSUIElement=true`), no dock icon, no main window
- `NSStatusItem` + custom borderless `NSPanel` for the control panel
- Push-to-talk via a **listen-only `CGEvent` tap** (deliberately chosen over an AppKit global monitor for reliable `ctrl+option` in the background)
- Pluggable STT: AssemblyAI streaming / OpenAI upload / **Apple Speech (local)**
- Claude **and** OpenAI vision clients with SSE streaming
- ElevenLabs TTS
- ScreenCaptureKit multi-monitor capture
- **Animated cursor overlay** — Claude emits `[POINT:x,y:label:screenN]`, the overlay maps coordinates to the right monitor and flies a bezier arc there
- Cloudflare Worker proxy (3 routes: `/chat`, `/tts`, `/transcribe-token`) so **no keys ship in the binary**

### What you must build yourself

| Missing | Effort | Notes |
|---|---|---|
| **Computer use** | Medium | Add Peekaboo or cua-driver (§4) |
| **Automations** | Low | launchd (§5) — you get this for free |
| **Skills** | Low | SKILL.md is just markdown + frontmatter |
| **Integrations** | Low | Official MCP servers (§6) |
| **Realtime duplex voice** | Medium | Pipecat (§3) |

### The most interesting thing in the codebase

Not a feature — a *warning*:

> **Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

If you fork this, know that rebuilding from the CLI will nuke your permissions and force a re-onboarding. Use Xcode's Cmd+R.

### The naming easter egg

The Xcode project is `leanring-buddy.xcodeproj` — a typo for "learning-buddy" that survived three renames (Clicky → Clickys → HeyClicky) and is still in the shipped HeyClicky app's `AGENTS.md`. The repo's `AGENTS.md` says: *"Do not rename the project directory or scheme (the 'leanring' typo is intentional/legacy)."*

---

## 3. Tier C — Voice layer (fully local, no API key)

**Framework: Pipecat, not LiveKit.** `pipecat-ai/pipecat` · BSD-2 · 15,941★ · pushed 2026-09-28.

The reason is concrete: I had a subagent read LiveKit's full plugin table. **All 33 of its STT plugins are hosted APIs** — no whisper.cpp, no Moonshine, no faster-whisper. LiveKit's `TurnDetector` is genuinely the best turn-taking in the space (an *audio* model reading prosody; its own A/B shows a text-based EOT committing at 2.76s where the audio model correctly waits to 6.41s), and `v1-mini` runs locally on CPU. But you'd write a custom STT node.

Pipecat ships the local pieces out of the box:

| Need | Pipecat service | License |
|---|---|---|
| STT | `MoonshineSTTService`, `WhisperSTTService`, `FunASRSTTService` | MIT |
| TTS | `KokoroTTSService`, `PocketTTSService`, `PiperTTSService` | Apache-2.0 / MIT / CC-BY-4.0 |
| LLM | `OLLamaLLMService` | — |
| VAD | `SileroVADAnalyzer` | MIT |
| Transport | **`SmallWebRTCTransport`** — *"serverless peer-to-peer WebRTC, no provider needed"* | BSD-2 |

### Recommended local model picks

| Role | Pick | Why | License |
|---|---|---|---|
| **STT** | **Moonshine Small Streaming** (123M) | Its docs measure **56–83 ms** post-speech latency **on Mac**, 7.84% WER. Quantized accuracy within ~0.3% of float Whisper | MIT |
| STT (alt) | `whisper.cpp` `large-v3-turbo-q5_0` (547 MiB) | Best accuracy/compat; built-in `--vad`; "Apple Silicon first-class citizen" | MIT |
| **TTS** | **pocket-tts** (100M) | ~200 ms to first audio chunk, ~6× realtime on an M4 CPU, **2 cores only**, streaming | MIT / CC-BY-4.0 |
| TTS (alt) | **Kokoro-82M** | Safest license (Apache both sides), near-real-time on M1 | Apache-2.0 |
| Turn detection | Silero VAD + **Smart Turn v3** | Silero segments; Smart Turn endpoints. **Ships a CoreML variant** — matters on Mac | MIT / BSD-2 |
| LLM | `llama.cpp` + `gpt-oss-20b` or Qwen3 | 129,788★, Metal, unified memory | MIT / Apache-2.0 |

**Semantic VAD is worth the extra dependency.** The reasoning, from Pipecat's docs: *"a user might say 'I need to think about that for a moment' and then take a long pause. The user has more to say but a VAD-only system interrupts them anyway."*

### Native Mac shortcut

Apple's new `SpeechTranscriber` / `DictationTranscriber` are excellent **but require macOS 26+**. Only `SFSpeechRecognizer` (10.15+) still reaches macOS 14/15 — and HeyClicky supports 14.2+.

**If you want the ANE (Apple Neural Engine) rather than GPU/MPS**, look at `FluidInference/FluidAudio` (Apache-2.0, 2,923★) — a Swift SDK running Whisper/Kokoro on the ANE with minimal CPU. And **`Beingpax/VoiceInk`** is a *shipping* macOS push-to-talk dictation app built on it (`brew install --cask voiceink`). **Read its source before writing yours from zero** — it's GPL-3.0, so learn from it, don't link it.

### Latency budget for a fully-local PTT flow

```
Silero VAD trim          ~200 ms
Moonshine Small          ~ 80 ms   (post-speech)
llama.cpp 20B TTFB      ~300-600 ms
Kokoro/pocket first chunk~200 ms
                            ─────────
                        ≈ 0.8-1.1 s total
```

---

## 4. Tier C — Computer use layer

**Pick one. They overlap heavily.**

| Project | ★ | License | Lang | Last push | MCP | Notes |
|---|---|---|---|---|---|---|
| **`openclaw/Peekaboo`** | **5,222** | MIT | Swift | **2026-09-28** | ✅ stdio | Most complete single tool. 33 CLI commands |
| **`trycua/cua` → `cua-driver`** | **26,813** | MIT | Rust | **2026-09-28** | ✅ stdio | **What HeyClicky itself uses** |
| `lahfir/agent-desktop` | 1,699 | Apache-2.0 | Rust | 2026-09-28 | — | AX-tree-first, 383-token "skeleton" over 30k |
| `iFurySt/open-codex-computer-use` | 2,270 | MIT | Swift | 2026-09-22 | ✅ | Codex-computer-use clone |
| `minghinmatthewlam/computer-use-mcp` | 46 | MIT | Swift | 2026-08-17 | ✅ | **Best-documented**; per-app leases |
| `browser-use/browser-use` | 116,615 | MIT | Python | 2026-09-26 | ✅ | ❌ **Browser-only** |
| `Skyvern-AI/skyvern` | 23,090 | **AGPL-3.0** | Python | 2026-09-28 | — | ❌ **Browser-only** |

### Peekaboo — the practical default

Note the org: it's **no longer `pegasys-apps`** (404s now). It moved under **`openclaw`**, an org with **94 public repos** run by Peter Steinberger, described as *"Your personal, open source AI assistant."* Latest release **v4.6.0, two days ago**. Install: `brew install openclaw/tap/peekaboo`.

Does both AX-tree *and* vision/OCR/LLM. The clever bit is producer-bound element references — `ps1_` + 32 hex chars — so *"a follow-up action can never be replayed against a stale snapshot."* Background delivery by default; `--foreground` is opt-in. Commands include `see`, `click`, `action`, `set-value`, `press`, `scroll`, `menu`, `window`, `app`, `dialog`, `space`, `verify`, `agent`, `browser`, `permissions`.

### cua-driver — same engine HeyClicky uses

Runs **directly on your Mac** (PyPI wheel is `macosx_13_0_universal2`) — no VM required. `lume` is a separate *optional* component if you want isolation. Python + TypeScript SDKs via UniFFI over a versioned C ABI.

⚠️ **The one licence catch:** `cua-driver` is MIT and needs no model artifacts. The **optional `cua-perception` extension is AGPL-3.0** (OmniParser icon detector). Verbatim: *"If your organization does not accept AGPL components, do not install the extension."*

### Four constraints every one of these documents

1. **TCC binds to the host process, not the tool.** Over SSH the grant goes to `sshd-keygen-wrapper` — handing full UI control to anyone who can SSH in.
2. **A logged-in WindowServer session is required.** Locked screen or headless Mac breaks everything.
3. **"Background" is a ladder, and the bottom rung moves your real cursor.** Ladder is typically: AX action → per-window event → per-PID event → global HID/cursor. Only the last is disruptive.
4. **AX tree presence ≠ AX tree quality.** Electron apps with accessibility disabled, games, and remote-desktop clients have absent or partial trees.

These four constraints are precisely why HeyClicky's Rego policy is as elaborate as it is — it's compensating for a platform that offers no native background-input guarantee.

### Things that are gone or were never what you thought

| Claim | Reality |
|---|---|
| Apple's `computer-use-preview` is available | **Gone.** HF 401; absent from Apple's complete 130-model listing. Only third-party Ferret-UI mirrors exist |
| Open Interpreter does OS automation | **No.** Now a **Rust fork of OpenAI's Codex** (68,465★, Apache-2.0). `computer.py`, `os.py`, `OS_MODE.md` all 404. Delegates to trycua |
| `cua-agent` exists | 404. `cua-driver` replaced it |
| MIT/AGPL split is driver-vs-agent | It's driver (MIT) vs *optional perception extension* (AGPL) |

---

## 5. Automations — the answer is `launchd`

**You do not need a scheduler library. macOS already has the right one, built in, free forever.**

Apple's own `man launchd(8)`:

> "the canonical way to launch a daemon is through launchd as opposed to traditional POSIX and POSIX-like mechanisms... These alternate methods should be considered **deprecated** and not suitable for new projects."

And the decisive advantage for a laptop:

> **"Unlike cron which skips job invocations when the computer is asleep, launchd will start the job the next time the computer wakes up. If multiple intervals transpire before the computer is woken, those events will be coalesced into one event upon wake from sleep."**

Your Mac sleeps. That single quote is why launchd wins.

### The pattern

A **LaunchAgent** (not a LaunchDaemon — LaunchAgents run in your GUI session and can reach `~/`, the Keychain, and AppleScript):

```xml
<!-- ~/Library/LaunchAgents/com.you.agent.morning.plist -->
<key>ProgramArguments</key>
<array>
  <string>/usr/local/bin/claude</string>
  <string>-p</string>
  <string>Summarize overnight Slack + today's calendar, write to Notes.</string>
  <string>--output-format</string>
  <string>json</string>
</array>
<key>StartCalendarInterval</key>
<dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>0</integer></dict>
<key>StandardOutPath</key><string>/tmp/agent.log</string>
<key>StandardErrorPath</key><string>/tmp/agent.err</string>
```

```bash
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.you.agent.morning.plist
launchctl kickstart -k gui/$UID/com.you.agent.morning   # test without waiting for 9am
```

### Confirmed by the community

`jshchnz/claude-code-scheduler` (513★, MIT) — the only mature OSS scheduled-agent wrapper — does exactly this: **launchd on macOS, crontab on Linux, Task Scheduler on Windows.** When 513 people build the same thing, they're converging on the same answer.

### Is there an open-source ChatGPT "Tasks" equivalent?

**Essentially no.** They're all commercial:

- **Claude Code Desktop Scheduled Tasks** — the closest UX. Runs on your machine, **catches up on missed runs** (checks last 7 days, runs one catch-up on wake), per-task permission mode + model, optional isolated git worktree per run, run history with skip reasons. Tasks are files at `~/.claude/scheduled-tasks/<name>/SKILL.md`. ⚠️ Only fires while the app is running *and* the machine is awake; **closing the lid still sleeps it**. Requires a Claude subscription.
- **`/loop`** — ❌ not this. Session-scoped, **recurring tasks auto-expire after 7 days**, no catch-up.
- **Codex** — CLI has no scheduling UI; desktop/web only, proprietary.

⚠️ **HeyClicky's own instructions have this bug.** `ClickyModelInstructions.md` says *"Remote Tasks, scheduled cloud crons... are not part of this shipped child-agent release"* — which is technically true (the *child agent* can't touch them) but reads as "the feature doesn't exist." It does: `/agent/cron/`, `/agent/cron/list`, `clicky-crons-mcp`, and a full `<ROUTINE>` create/update JSON contract are all in the shipped binary.

### Schedulers you should ignore

| Tool | ★ | License | Why not |
|---|---|---|---|
| `supercronic` | 2,654 | MIT | **Docker cron.** Useless on a bare Mac |
| `ofelia` | 3,998 | MIT | "crontab for docker." Same problem |
| `dbader/schedule` | 12,273 | MIT | 🚩 **Last push May 2024.** Dormant ~2.5 yrs, huge stars |
| Prefect / Dagster / Temporal | 16k–24k | various | Data-pipeline infra. Needs servers + Postgres. Absurd for a 9am job |
| Windmill | 18,050 | AGPLv3 + proprietary | AGPL obligation is the heaviest here |
| `goofyne` | — | — | Not a scheduler — it's a Go **GUI toolkit** |

### Event-driven, if you want push instead of poll

- **Mosquitto** (EPL-2.0 OR BSD-3) — local pub/sub, ~200 KB, rock solid
- **cloudflared / ngrok** free tunnel — so Gmail/GitHub/Linear can *push* to your Mac
- **Apple Shortcuts** as a zero-install baseline. It genuinely can call an LLM: `Get Contents of URL` with POST + custom headers + JSON body is a complete API client. Schedule via Personal Automation or `shortcuts run` from launchd. ⚠️ No real retry/timeout/error handling — move to a script once it grows.

---

## 6. Integrations — the 2026 surprise

**Most of the apps HeyClicky connects to now ship their own official MCP server, free.**

| App | Official? | Endpoint |
|---|---|---|
| **Gmail, Drive, Docs, Sheets, Slides, Calendar, Chat** | ✅ Google | `mcp.googleapis.com/workspace/v1/...` (public preview since 2026-05-01) |
| **Slack** | ✅ Slack | `mcp.slack.com` — **GA 2026-02-17** |
| **Linear** | ✅ Linear | Centrally hosted |
| **Notion** | ✅ Notion | `makenotion/notion-mcp-server` (4,650★, MIT) |
| **GitHub** | ✅ GitHub | `github/github-mcp-server` — **33,259★**, largest MCP server on GitHub |
| **Atlassian** | ✅ Atlassian | `atlassian/atlassian-mcp-server` |

Each vendor has already solved its own OAuth. **You can skip the broker entirely.**

### The "open source integration layer" trap

| Project | ★ | Looks like | Reality |
|---|---|---|---|
| **Nango** | 12,390 | "open source, self-host free" | ⚠️ **Elastic License 2.0** (not OSI). Free self-host = **Auth + Proxy only, NO MCP server, no prebuilt tools**. Full self-host is *Enterprise* |
| **Pipedream** | 11,713 | 11.7k★ public repo | ⚠️ Custom source-available license, **runtime not published** (I grepped: no `server/`, no `runtime/`), **not self-hostable**. MCP free for *personal* use |
| **Composio** | 30,348 | MIT! | ⚠️ MIT covers the **SDK only**. Platform is closed SaaS. Free tier is actually generous (100k tool calls/mo, unlimited accounts) but SaaS-only |
| **n8n** | 206,208 | "open source" | ⚠️ "Fair-code"/Sustainable Use License. Free for personal use, not OSI |

**Composio's actual free tier is fine for personal use** — 100,000 tool calls/mo, unlimited connected accounts, no credit card, hard cap. The thing to know is that the MIT on the SDK repo is a common misreading; the toolkits and platform aren't there.

### Community MCP servers worth using

| Need | Repo | ★ | License | Push |
|---|---|---|---|---|
| All Google Workspace locally | `taylorwilsdon/google_workspace_mcp` | 3,245 | MIT | **2026-09-28** |
| Slack (user-token OAuth, no app approval) | `korotovsky/slack-mcp-server` | 1,848 | MIT | 2026-07-16 |
| Apple Notes | `sweetrb/apple-notes-mcp` | 136 | MIT | 2026-09-26 |
| Apple Reminders | `dbmcco/apple-reminders-mcp` | 30 | MIT | 2025-10-25 |
| iMessage (**read-only**) | `anipotts/imessage-mcp` | 25 | MIT | 2026-09-28 |
| Spotify | `varunneal/spotify-mcp` | 615 | MIT | 2026-03-11 |

🚩 **Avoid `lharries/whatsapp-mcp`** despite its **6,325 stars**. Last push **July 2025**, 248 open issues, and it drives WhatsApp **Web** via Puppeteer — violates WhatsApp ToS, breaks often, risks account ban. The star count is badly misleading.

🚩 **`modelcontextprotocol/servers`** (90,645★) no longer has what you need. I listed `src/`: only `everything, fetch, filesystem, git, memory, sequentialthinking, time` remain. All Google/Slack/GitHub/Notion reference servers were **removed**.

**Browse with `punkpeye/awesome-mcp-servers`** (95,632★, MIT). The official registry (`modelcontextprotocol/registry`, 7,292★) is self-hostable with docker-compose.

---

## 7. Feature-by-feature vs HeyClicky

| HeyClicky feature | Free OSS status |
|---|---|
| Menu-bar / notch companion UI | ✅ `farzaa/clicky`, `clickyX`, `tiptour-macos`, `openclicky` |
| Push-to-talk dictation | ✅ All of the above |
| **Fully-local STT/TTS** | ✅ Moonshine + Kokoro/pocket-tts, or macOS `say` |
| Screen awareness (on-demand screenshots) | ✅ ScreenCaptureKit |
| Screen annotation / scribble | ✅ clickyX (`HIGHLIGHT`/`SHAPE` tags) |
| Animated pointing cursor | ✅ `farzaa/clicky` (`[POINT:x,y]`), `tiptour-macos`, `clickyX` |
| **Computer use (GUI automation)** | ✅ Peekaboo, cua-driver, agent-desktop |
| **No-focus-steal background automation** | ⚠️ **Partial.** Ladders exist but the bottom rung moves your cursor. HeyClicky's Rego policy is the only hard guarantee I found — and it's closed source. *Build your own Rego/gate on top.* |
| Realtime duplex voice | ⚠️ Pipecat + local cascade. Fully-open full-duplex (Moshi) is 7B — heavy |
| **Automations / routines / cron** | ✅ **launchd** — better than HeyClicky for a laptop (catches up after sleep) |
| Gmail/Calendar/Drive/Docs/Sheets | ✅ **Official Google MCP**, free |
| Notion / Slack / Linear / GitHub | ✅ **Official MCP servers**, free |
| Apple Notes / Reminders / iMessage read | ✅ Community MCP servers |
| iMessage **sending** | ❌ No good OSS option — needs Full Disk Access + Automation perms; Apple has no Messages API |
| WhatsApp | 🚩 ToS-violating, unmaintained |
| Web research | ✅ Any LLM + Brave/Tavily MCP, or `ddgs` |
| Artifacts (PDF/DOCX/XLSX) | ✅ `pdf`/`doc`/`spreadsheet` SKILL.md skills are just prompts |
| **Skills system** | ✅ SKILL.md is open markdown+frontmatter (Anthropic's format); Nous `hermes-agent` is MIT |
| **Persistent named agents (Clickys)** | ❌ **Explicitly out of scope for you** — this is the thing you're replacing with automations |
| Skills *marketplace* | ❌ No equivalent. Closest: `savka777/jev-use` shows the persona-as-skill pattern |
| Procedural companion characters | ❌ HeyClicky's genuine differentiator, and not reproducible from docs |

---

## 8. 🚩 License traps — the complete list

**Check the *weights*, not the repo.** This is where self-hosters get burned.

### Non-commercial — do not ship these

| Project | Trap |
|---|---|
| **XTTS-v2** | Code is MPL-2.0. **Weights are `coqui-public-model-license` — non-commercial only.** Repo hasn't pushed since Aug 2024 |
| **F5-TTS** | GitHub badge says **MIT**. **Weights are `cc-by-nc-4.0`** |
| **Fish Speech** | "Fish Audio Research License" — *Research, Non-Commercial* |
| **Voxtral-4B-TTS** | `cc-by-nc-4.0` (the *ASR* Voxtral models are Apache-2.0) |
| **AgentiLoop/Agent** (637★) | **PolyForm Noncommercial 1.0.0** — source-available, not OSI |
| **Piper** (`OHF-Voice/piper1-gpl`) | **Engine relicensed MIT → GPL-3.0.** Voices licensed per-file |

### No license at all — legally all-rights-reserved

| Project | ★ | Why it matters |
|---|---|---|
| **`mediar-ai/fazm`** | 339 | Its blog says *"free and open source."* **There is no LICENSE file.** Not open source |
| `skalesapp/skales` | 1,922 | No language, no license detected |
| `Hacker-Valley-Media/Interceptor` | 432 | `NOASSERTION`, no detectable license |

### Ambiguous / non-standard

| Project | Issue |
|---|---|
| `n8n` | "Fair-code" Sustainable Use License. Free personally, not OSI |
| `Windmill` | Mixed AGPLv3 / Apache-2.0 **plus proprietary enterprise features** |
| `Skyvern` | **AGPL-3.0** |
| `cua-perception` extension | **AGPL-3.0** (driver itself is MIT) |
| Moonshine legacy non-English STT | Community License: non-commercial **plus** >$1M revenue cap. **All English + all streaming models are MIT** |
| `nvidia/personaplex-7b-v1` | Gated; must accept NVIDIA's license on HF |
| `zai-org/glm-4-voice-9b` | GitHub says Apache-2.0, **HF weights have no license tag** |
| `livekit/turn-detector` | "Free to use in any context" is a *permission statement*, not an OSI license |

### Clean and commercial-safe

`whisper.cpp` (MIT) · `faster-whisper` (MIT) · `whisperX` (BSD-2) · **Moonshine English/streaming (MIT)** · **Kokoro-82M (Apache both)** · **pocket-tts (MIT/CC-BY-4.0)** · **Dia (Apache)** · **Moshi+Mimi (Apache/CC-BY-4.0)** · **Voxtral ASR (Apache)** · `parakeet-tdt` v2/v3 (CC-BY-4.0) · `Smart Turn v3` (BSD-2) · `Silero VAD` (MIT) · **Pipecat (BSD-2)** · `LiveKit Agents` (Apache-2.0) · `llama.cpp` (MIT) · `gpt-oss` (Apache-2.0) · `cua-driver` (MIT) · **Peekaboo (MIT)** · `taylorwilsdon/google_workspace_mcp` (MIT) · `Mosquitto` (EPL/BSD) · `Node-RED` (Apache-2.0) · `Huginn` (MIT) · `Home Assistant` (Apache-2.0)

---

## 9. What I'd actually build

### Recommended path (superseded 2026-09-30 by Chunks v2 — see `CHUNKS-BUILD-PLAN.md`)

**Do Chunks v2 (native notch, single assistant).** Below preserved for history:

**Start from `clickyX`.** It's MIT, it already has the automations scheduler you asked for, it already has Codex as an agent runtime and 64 skills, and you can run it today without writing code.

```
┌─ clickyX (MIT, Rust + Tauri) ───────────────────┐
│  tray UI · overlay · voice · cursor · skills     │
│  Codex agent runtime                            │
│  computer use (enigo, background)               │
│  AUTOMATION SCHEDULER ← already built           │
│  local HTTP bridge on :32123                    │
└──────────────┬──────────────────────────────────┘
               │
      ┌────────┴─────────┐
      ▼                  ▼
  launchd              Official MCP servers
  (harden/replace      Google · Slack · Linear
   its in-app cron      Notion · GitHub
   so jobs survive      (all free, vendor-run)
   sleep + wake)        │
      │                  └─► taylorwilsdon/google_workspace_mcp
      ▼                     for local Google if you prefer
  claude -p / codex exec
  + mosquitto for
    event-driven
```

**First three moves, in order:**

1. **Run it as-is.** `ClickyX_0.2.1_aarch64.dmg`. Verify the voice, the overlay, and the automation scheduler actually work on your Mac before changing anything.
2. **Move scheduling from its in-process `tick()` to launchd.** Its Rust `AutomationEngine::tick()` only runs while the app is alive. launchd catches up after sleep. This is the single highest-value change and it's ~30 lines.
3. **Add the Rego-style guard.** This is the one HeyClicky capability with no OSS equivalent. Every open computer-use project has a ladder whose bottom rung moves your real cursor. If you're going to run unattended automations — which is the whole point — you need a hard policy layer between the agent and the GUI. Ideas already in the codebase: `delivery_mode: "background"` where supported, deny-list `⌘L`/`⌘1..9`/`⌘⇧G`, and require explicit per-job consent.

### If you'd rather own every line

Fork **`farzaa/clicky`** (7.7k lines, MIT, best-documented native codebase), then add in this order:

1. **launchd** automations — free, ~1 hour
2. **cua-driver** or **Peekaboo** for computer use
3. **Pipecat** with Moonshine + Kokoro for local voice, or keep ElevenLabs/Deepgram if you'd rather pay
4. **Official MCP servers** for Google/Slack/Linear/Notion/GitHub
5. **SKILL.md** skills — it's markdown; port HeyClicky's 15 bundled ones if useful (they're MIT-vendored from Nous `hermes-agent`)

### Don't build

- An OAuth broker for 1,000 apps (Nango/Composio/Pipedream all have paid catches)
- A cron daemon in Docker on a Mac
- Full-duplex speech-to-speech on a 7B model — a cascade is faster and cleaner
- A skills marketplace — that's a business, not a feature

---

## 10. Honest gaps

Things you **cannot** get for free and open source:

1. **A hard no-focus-steal guarantee.** Every OSS driver has a ladder; only HeyClicky's closed-source Rego layer blocks the bottom rung. **You'd have to write it.**
2. **The companion-character layer.** Procedurally generated faces, voices, personalities — that's HeyClicky's actual moat and it's undocumented.
3. **A skills marketplace with real supply.** `hermes-agent` is a great OSS catalog (MIT) but there's no economy around it.
4. **iMessage sending.** Apple has no Messages API.
5. **WhatsApp.** ToS-violating bridges only.
6. **Support.** clickyX is one person. farzaa/clicky is frozen at 20 commits.

And one thing worth naming plainly: **the reason HeyClicky is closed-source is that the safety layer is the hard part, not the code.** The code is 7,751 lines and MIT-licensed. The 25 KB behavioral contract, the Rego policy, the consent gate, and 52 shipped versions of hard-won failure modes are what you can't get — and they're the part that matters most for unattended automations.

---

## Appendix — Method & confidence

**Sources:** authenticated `gh api repos/{owner}/{repo}` for all metadata (stars, license SPDX ID, `pushed_at`, `archived`, forks) on 2026-09-28. Direct clones of `farzaa/clicky` and `unn-Known1/clickyX` automation source. README/docs fetched from raw GitHub. HuggingFace JSON API for model-weight licenses (the `cardData.license_name` field). `man launchd(8)` / `man launchd.plist(5)` read locally. Vendor pricing pages for Composio, Nango, Pipedream.

**Confidence:**

| Claim type | Confidence |
|---|---|
| Star counts, licenses, push dates, archived flags | **Exact** — API, not search snippets |
| clickyX automation implementation | **Very high** — read the 574-line source |
| `farzaa/clicky` feature inventory | **Very high** — cloned and read all 23 files + AGENTS.md |
| launchd behaviour | **Very high** — quoted from local man pages |
| Model weight licenses | **High** — HF JSON API, authoritative |
| LiveKit "no local STT plugin" | **High** — full plugin table read, 33 entries |
| Pipedream "runtime not published" | **Medium-high** — grepped repo root; absence of evidence, but conclusive enough |
| Why Apple pulled `computer-use-preview` | ❌ **Unknown** — HF returns 401 identically for gated and nonexistent repos |
| LiveKit `TurnDetector v1-mini` license | ❌ **Unclear** — "free to use in any context" is a permission, not a license grant |
| `glm-4-voice-9b` license discrepancy | ❌ **Unresolved** — GitHub Apache-2.0 vs no HF tag |
| M-series RTF/WER benchmarks | ❌ **Not verified** — faster-whisper's published numbers are Intel i7-12700K + RTX 3070 Ti. Only Moonshine's own Mac figures and pocket-tts's M4 claim are vendor-stated |

**Corrections made during this research:**

- `openclaw/Peekaboo` is **not** at `pegasys-apps` (that org 404s). It's under `openclaw` (steipete, 94 repos).
- `Open Interpreter` **no longer does OS automation** — it's a Rust fork of Codex and delegates to trycua.
- Apple's `computer-use-preview` is **unavailable**, not merely gated.
- **`fazm` is not open source** despite its blog saying "free and open source" — no LICENSE file.
- Nango's free self-host tier **excludes the MCP server**, which is the only part you'd want.
- Composio's MIT license covers the **SDK only**, not the platform.
- `whatsapp-mcp` at 6,325★ is **effectively dead** (last push Jul 2025) and ToS-violating.
- `modelcontextprotocol/servers` **no longer contains app integrations.**

---

*No project in this document was executed. All behavioural claims come from source code I read or documentation I fetched. Verify anything load-bearing before building on it.*
