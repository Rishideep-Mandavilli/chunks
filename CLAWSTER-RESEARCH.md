# Clawster — Research (2026-09-30)

**Sources:** `clawster.pet`, `github.com/wuyuwenj/clawster` (staging, README + `MEMORY-LAYER-PLAN.md` + file tree), `/privacy`. No code executed.

## 1. What it is

Free MIT AI desktop pet for macOS (Electron + React, Apple Silicon + Intel, macOS 12+). Animated lobster, 14 moods (idle/happy/sleep/startle/doze/side-eye/crossed/huff/proud/peek/spin/walking + sleep/doze variants). Lives on desktop, quick chat anywhere, screenshot questions, full assistant panel, chat sessions, Focus Mode, voice input, auto-update from GitHub Releases, 3-step wizard (was 8-step on OpenClaw era). 2nd place humans& hackathon. ~30★, 1 fork — one-person project, beta v0.1.3.

Tagline: "Part pet, part power tool. Sees what you're working on, remembers what matters, actually does things."

## 2. Architecture (staging = current)

```
User message
  ├─ Local Qwen 1.5B fine-tuned → tool classification (~200ms)
  │    └─ open apps, shell, timers, messages, volume, Focus block
  ├─ Cloudflare Worker proxy → GPT-4o-mini (HMAC, rate-limit, moderation)
  └─ LanceDB local ~/.clawster/memory/ → facts + emotional memories (vector search)
```

- Old README era: pure OpenClaw gateway `http://127.0.0.1:18789` + `IDENTITY.md`/`SOUL.md`, all-local, no keys.
- New era: hybrid. Local for tools, cloud for conversation. No Ollama required ("install and it just works").
- Frontend: `src/main` (main.ts, chat/router/providers/tools/memory/sessions, emotion-engine, pet-behaviors, permission-helper, screen-capture, speech native helper, windows) + `src/renderer` (pet/chatbar/pet-chat/assistant/onboarding, Tidepool light theme). `proxy/src/index.ts` (HMAC+limit+moderation, `/v1/chat/completions` + planned `/v1/embeddings`). `personality/` (`IDENTITY.md`, `SOUL.md`). `native/speech-helper`, `eval/`, `test/` (vitest), `e2e/` (playwright).

## 3. Features vs Chunks

| Clawster | Chunks v2 takeaway |
|---|---|
| `Cmd+Shift+Space` quick chat, `Cmd+Shift+/` snap+ask, `Cmd+Shift+A` panel | Adopt verbatim — proven, no reason to invent |
| Active-app/window awareness | Adopt (cheap via NSWorkspace/AX, no full capture needed every turn) |
| Tool calling: open/timer/message/volume/Focus block | Adopt as `ToolLayer` under consent gate |
| Memory: facts (upsert by key, always inject, <100) + emotional journal (append-only, 1536-d `text-embedding-3-small` remote, dedup cosine >0.92 vs last 10, recency fallback offline, `decisions.jsonl` logging) | Adopt shape, but Chunks stays markdown hot-path (hand-editable, no dep). Vectors = P8 option only |
| Safety filter (destructive/prompt-injection block, link scheme allowlist http/https only) | Adopt |
| Personality files, attention-seeking, drag/click reactions, bubbles, Tidepool theme | Adopt personality files + in-app moods only; reject always-on pet, drag physics, attention-seeking (req: trailer + in-app body only) |
| Onboarding wizard + permission helper + auto-update banner | Adopt wizard flow |
| Privacy: `~/.clawster/` local, only chat message leaves, no training-store, opt-out PostHog | Adopt posture; Chunks goes further (`store:false`, Keychain, no analytics) |

## 4. Gaps / risks

- Electron weight + CPU floor vs Chunks native goal.
- Cloud-chat dependency; Pro "coming soon" (unlimited cloud, smarter models) = same meter trap as HeyClicky.
- No annotate/point/trailer, no AX computer-use with policy gate, no reminders/scheduler/planner, no provider registry/BYOK.
- 30★/1 fork, nightly energy, single maintainer. Treat as pattern source, not dependency.
- `MEMORY-LAYER-PLAN.md` is a plan, not all shipped. Verify before trusting.

## 5. What Chunks v2 borrows (patterns only, MIT-safe)

Hotkeys, wizard, Focus/tools shape, two-tier memory shape, safety filter, personality files. Nothing Electron-specific. No cloud-proxy lock-in.
