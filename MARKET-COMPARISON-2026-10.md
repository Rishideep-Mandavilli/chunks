# Market comparison — Chunks vs the screen-aware assistants (2026-10-21)

**Sources:** vendor sites and changelogs, GitHub, and third-party reviews dated below. Claims a vendor
makes that nobody independent has checked are marked **(claimed)**. Compiled for the owner's question
"compare it with HeyClicky and all similar applications". HeyClicky's shipping binary is closed —
`farzaa/clicky` is MIT but frozen at 2026-04-28, before the notch and computer use — so its internals,
model lists and user counts are vendor statements.

## The axis that matters

Every product with a screen feature does one of three things: **looks**, **talks**, or **acts**. And
among the ones that act, **all of them aim by pixel coordinates** — Anthropic's computer-use toolset
has no accessibility-tree target at all, and its own published OSWorld success rate is 14.9% with
latency named as the caveat.

Chunks is the only product in this set that resolves `app=WhatsApp role=button name=Send` against the
live accessibility tree. That is not polish: a vision model's aim is good to roughly a row height, a
row is ~70 pt, and the category's headline bug ("it clicked the wrong thing") is that measurement.

## Capability matrix

| can it… | Chunks | HeyClicky | ChatGPT app | Claude | Gemini/Chrome | Raycast | Screenpipe | Superwhisper | CleanShot |
|---|---|---|---|---|---|---|---|---|---|
| answer about the whole screen | ● | ● | ● | ○ | ◐ |  | ● |  | ◐ |
| answer about a drawn region | ● | ● | ○ | ○ | ● | ○ | ○ | ○ | ● |
| press / type / scroll in another app | ● | ● | ○ | ◐ |  | ✕ |  | ✕ |  |
| **aim by control name, not pixels** | **●** | ✕ | ✕ | ✕ | ✕ | ✕ | ✕ | ✕ | ✕ |
| multi-step plan from one sentence | ● | ● | ◐ | ◐ | ◐ | ✕ | ✕ |  | ✕ |
| per-act consent you cannot switch past | **●** | ◐ | ○ | ◐ |  | ✕ |  | ✕ |  |
| voice, push-to-talk, live transcript | ● | ● | ◐ |  | ● |  | ● | ● | ✕ |
| remembers you, on disk, editable | ● | ● | ◐ | ◐ | ◐ |  | ● | ✕ | ✕ |
| runs with no account and no server | **●** | ✕ |  | ✕ |  | ✕ | ● | ◐ |  |
| BYOK, Keychain-held | ● | ✕ | ✕ | ✕ | ✕ | ◐ |  | ◐ |  |
| works fully offline | ● | ✕ | ✕ | ✕ | ✕ | ✕ | ● | ● | ✕ |
| native Swift, no Electron | ● | ● | ◐ | ◐ | ◐ | ● | ● | ● | ● |
| open source | ● MIT | ✕ (old repo MIT) | ✕ |  | ✕ |  | ● |  | ✕ |

● yes · ◐ partial or confined to one surface · ○ announced/beta/narrow · ✕ not offered. ChatGPT and
Claude act on a cloud VM or a background session, not your foreground apps.

## HeyClicky — the reference, as of v1.0.53 (2026-10-02)

Native Swift/AppKit, macOS 14.2+, YC-backed, Apple Silicon and Intel. **The notch is the only home** —
the menu-bar icon was deleted in v1.0.27 (2026-06-20). Hover peeks Clickys and suggestions; ⌃A or the
Dock opens a resizable "Home" chat sheet; running agents get a floating card top-right.

- **Input**: push-to-talk ⌃⌥ (double-tap-modifier since v1.0.48), hold Fn+⌃ to dictate, double-tap hands
  free, ⌃ + draw-on-screen to point or circle ("spatial context", v1.0.33), triple-Control always-on
  realtime with headphones.
- **Does**: explains the screen, flies its own tinted buddy cursor to controls, Excalidraw-style
  drawing, 15-step walkthroughs that detect your clicks (v1.0.48), screen-aware drafting, whole
  document/PDF/web reading (v1.0.47), memory as `PROFILE.md` + `VOLATILE.md`, **Clickys** — persistent
  named agents with their own face, memory and file folder (v1.0.49) — scheduled routines, MCP servers
  (URL or local command), OAuth app connectors. **Skills were removed** in v1.0.49 ("on pause") after a
  ~100-skill community library and 89 app-teaching skills.
- **Architecture**: cloud-only, stated as "nothing is done locally". Screenshot + transcript + prompt →
  HeyClicky backend → Anthropic / OpenAI / Deepgram / Cerebras. Realtime voice `gpt-realtime-2.1`;
  default screen model Claude Fable 5; agents run a bundled Codex on an in-house harness; computer use
  moved off Cua (v1.0.12) to a native driver that never moves your real pointer (v1.0.48/52). No BYOK,
  no model picker.
- **Pricing**: Free 25 talk + 25 agent messages/month; Pro $20 (unlimited talk, 150 agent); Max $100
  (1,000); yearly −20%; Teams v0; $10k MRR claimed 2026-06-28 **(claimed)**.
- **Privacy**: hotkey-only capture; raw screenshots discarded but AI screen analysis and the prompt are
  retained; no training claimed; Keychain for credentials; PostHog + Sentry; a once-a-day read-only
  connector poll feeds proactive suggestions; no SOC 2 / ISO; deletion within 14 days. Proactive agents
  and local activity tracking shipped in v1.0.33 and were **deleted** in v1.0.46 (2026-08-01) over
  privacy unease.
- **What its own changelog records as breakage**: black or covered screenshots and broken Loom/call
  sharing (v1.0.52), wallpaper-only Mission Control thumbnails, system-wide keyboard freezes
  (1,600+ users/month), 36–45% idle CPU (v1.0.49), dead mic until restart (300/month), Bluetooth
  clipping replies (117/month), dropped push-to-talk, stuck agents, computer use failing every step
  until relaunch, a 60 s answer timeout, and billing double-charges (v1.0.33). HokAI 4.2/5 with support
  6.5; The Rundown notes "Always approve" removes a checkpoint and that pointing picks wrong controls.

**What Chunks replicates**: the notch grammar, ⌃, circle-to-explain, the cursor trailer, the act
chain, memory files, tools, routines. **What it deliberately does not**: the agent roster, the cloud
harness, hosted realtime voice, OAuth connectors, billing.

## The others

| product | sees | acts | local? | price | note |
|---|---|---|---|---|---|
| **OpenAI ChatGPT macOS** | Appshots (2026-05): frontmost window screenshot + available text | agent/computer use in a cloud VM, by coordinates | cloud | ChatGPT plans | background Mac capture shown at DevDay 2026 |
| **Anthropic Claude desktop** | screenshots | Cowork/Claude Code computer use, beta, background, per-app prompts | cloud | Pro/Max | API toolset `computer_toolset_20260801` is coordinate-only; OSWorld 14.9% self-reported |
| **Google Gemini / Chrome** | tabs, page, selectable region | Auto Browse in-browser with confirmations | cloud | AI Pro/Ultra, mostly US | **Project Mariner shut down 2026-05-04**, folded into Gemini Agent / AI Mode |
| **Apple onscreen awareness** | app-donated context (View Annotations → App Entities) | only where a developer donated intents | on-device + Private Cloud Compute | free | the only other semantic route, and it is opt-in per app — third parties cannot poke another app's tree |
| **Microsoft Recall / Click to Do** | periodic snapshots / the UIA tree | Click to Do: copy, search, open | local, Copilot+ only, TPM + Hello | Windows | Click to Do is conceptually nearest Chunks' named aim; 2026 reporting says Copilot/Recall scope is being cut |
| **Cluely** | OCR of the screen + call audio, in an overlay | suggests only | cloud | free / $19.99 / $149.99 | repositioned (2026-10) from "knows what's on your screen" to a meeting assistant; headline claim is invisibility to screen share |
| **Screenpipe** | continuous screen + audio, OCR **and** accessibility trees → SQLite, exposed over MCP | nothing | local | free/paid tiers (conflicting: ~$21/mo, $400 lifetime) | 22,003★; the best memory layer here and no act path at all — a plausible substrate, not a rival |
| **Raycast** | Screen Awareness (2026-08-12, v0.71): focused-window context | cannot click or type into another app | cloud, BYOK available | Pro $8/mo | no notch, no region draw, no policy gate |
| **Superwhisper / Wispr Flow / Aqua** | audio; Superwhisper "Super Mode" and Aqua read the active window for style | type at the cursor | local Whisper available | $8.49/mo · ~$12–15/mo · cloud | none touches a control |
| **CleanShot X / Shottr / Xnapper / Capso** | a capture you made | no | mixed; CleanShot's quick actions are cloud AI | ~$29–35 once (conflicting) · Shottr free/$12 · Xnapper sub · Capso free | Capso is **BSL 1.1, not MIT** — its window configuration was imported under that licence; nothing in this group acts on another app |
| **NotchNook / boring.notch / Alcove / MacNotch** | nothing | no | local | $25 / free OSS / $14.99 / $22.99 | docks, shelves and media trays — no AI, no screen understanding |

## Nobody has built this exact thing

Notch + push-to-talk + region vision + accessibility actuation + BYOK/Keychain + no telemetry, native
and MIT, has no open-source owner. Nearest neighbours, each missing a different third:

| project | ★ | licence | has / lacks |
|---|---|---|---|
| tiptour-macos | 681 | custom | ⌃ Gemini realtime voice about your screen, one desktop action per turn. Structurally closest; not MIT, no notch, no plan. |
| AgentiLoop/Agent | 647 | custom | native Swift, drives any app via Accessibility, wake word, local or cloud. Strongest feature match, weakest licence match. |
| nanoMuse | 1,665 | GPL-3.0 | screen-as-hands across devices, confirms irreversible acts — routes through a relay, so not the no-server product. |
| ghost-os · agent-desktop · FluidUse | 1,679 · 1,807 · 523 | MIT · Apache · Apache | accessibility-tree actuation as a toolkit for agents. No voice, no notch, no region capture. |
| LocalNotch · PikoChan · MurMur | 6 · 23 · 5 | MIT | Ollama vision in a notch. Early, small, none can act. |

## The ledger

**Ahead of the field**: named aiming; a consent gate the model cannot talk past (secure fields and
password managers refused outright, permanent acts asked even with asking off); no server, no account,
no meter; offline brains first-class; latency engineered (60 s turn budget, 20 s idle bound, per-model
buckets, a hedged first hop); MIT with read-only probes that print what a point or a name resolves to
before anything is pressed.

**Behind HeyClicky, honestly**: breadth of surface (Home sheet, document/PDF reading, screen-aware
drafting, walkthroughs); the agent roster and integrations (Clickys, MCP, OAuth connectors, routines);
hosted realtime voice, which needs a server and so is not a gap Chunks can close without breaking its
own rule; shipcraft (auto-update, launch-at-login, onboarding, teams, support, a paying user base
finding bugs daily); and the 89-app teaching corpus, which is content rather than code.

**Open gaps in Chunks as of this writing**: no app window with history (the notch card is transient by
decision), no scheduled routines, no launch-at-login or updater, `<NOTE>` offers parsed and dropped,
voice and STT engine choice reachable only by CLI flag.

## What this file is for

The comparison is a decision input, not a backlog. Where Chunks is behind on *breadth*, the answer is
usually yes (app window, routines, launch-at-login). Where it is behind on *cloud* (realtime voice,
OAuth connectors, metering), the answer is no by scope — AGENTS.md rules out a cloud backend, and the
pillars in the last line of that list are the product's position, not its omissions.
