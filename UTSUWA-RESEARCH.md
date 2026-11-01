# Utsuwa — Research (2026-09-30)

**Sources:** `utsuwa.ai`, `docs.utsuwa.ai` (architecture, companion-system, memory, MCP, voice-providers, introduction), `app.utsuwa.ai` (JS shell, not executed), blog `moving-to-agpl`. No code executed.

## 0. License warning (load-bearing)

**AGPL-3.0-or-later since 0.12.1** (MIT only to 0.12.0). Reason stated: prevent hosted closed-service clones without sharing back. Rule: offering modified Utsuwa (incl. hosted/network) → must publish modifications same license.

**For Chunks (MIT): learn patterns, DO NOT vendor/paste Utsuwa code.** Clean-room reimplementation of ideas is fine; copying files is not.

## 1. What it is

Free open AI companion (Juice Boxx Games LLC, CJ Dyas) with 3D VRM avatar (Tsuki/Yuki/Momo, any `.vrm` + `.vrma`), voice chat, long memory, photo/AR modes. SvelteKit web + Tauri v2 desktop (macOS/Win/Linux, transparent overlay, two windows `main`/`overlay`, global hotkeys) + browser build. "Utsuwa = vessel. We built the body, you decide what fills it." No accounts, no subscriptions, local-first.

## 2. Architecture

```
Client (browser/Tauri webview)
  Chat UI → Turn pipeline (companion-chat.ts, companion-turn.ts)
    memory retrieval → prompt builder → LLM (direct fetch desktop / /api/chat web)
    → response parser → extraction fallback → state merge → events → speech
  3D scene (Threlte/three-vrm) ← Svelte5 rune stores → Voice (TTS queue, STT)
  IndexedDB Dexie (utsuwa-db v6) + localforage + localStorage
Server (web only, no storage): /api/chat, /api/providers/models,
  /api/tts/fish-audio, /api/tts/local (gated), /api/mcp/* (gated)
Providers: LLM cloud/local, TTS cloud/local, STT cloud/local, MCP opt-in
```

Key files: `prompt-builder.ts`, `response-parser.ts`, `transport.ts` (+`retry.ts`), `engine/` (heuristics, stages, memory, events, moments, action-gate), `character.svelte.ts`, `db/index.ts` + `export.ts`, `platform/`, `mcp/` client (no SDK, JSON-RPC).

## 3. Companion system (the part to steal)

- **App is game master.** App owns every number; LLM writes dialogue + suggests JSON deltas; app bounds before applying.
- Modes: Companion (assistant, no progression) vs Dating Sim (default, 8 stages Stranger→Soulmate, 5 stats affection/trust/intimacy/comfort/respect + energy + mood 12 emotions + streaks + decay + milestone/random/romantic/time/strain events + generated moments from memories).
- Heuristics baseline + LLM override: baseline (−2 energy, +1 affection, sentiment/topic/emotion/question multipliers, clamped) merged with sanitized LLM deltas (mood replace; affection/trust capped 2× baseline min 5/3; others −3..5; energy always baseline; non-Latin messages skip caps and trust LLM). Demotion hysteresis 85%, strain event on demotion.
- Output: in-character text + fenced JSON (`mood_change`, `*_delta`, `new_memory` 3rd-person 1-sent, `triggered_event`, `action` anim-id, `expression` flash). Tolerant parse (strip `<think>`, trailing commas/comments, stop tokens, fake turns, emotion normalize, clamp). Missing block → `completeJson()` extraction call.
- Face layers: photo/emote > flash (1.4× mood weight cap 0.9, hold 2.5s/8s speaking) > resting mood (scaled by intensity) > lip-sync visemes (aa/ee/ih/oh/ou). Action gate: unknown/repeat<20s/any<8s dropped; photo/emote win.
- Reminders `[reminder:5min]...[/reminder]` + natural fallback → poll 10s, atomic claim, missed surface on launch, delivered as **system event** (no sentiment/stat/streak/fact/event side-effects). Adopt this rule.

## 4. Memory (best local-first ref)

- 3 tiers: working 20 turns (refilled from saved) + facts (IndexedDB, 384-d `Xenova/paraphrase-multilingual-MiniLM-L12-v2` via Transformers.js in-browser, up to 500 candidates, 70% sim +30% importance min 0.3 top-10; triggered "remember when…"/Names 60/40 min 0.5 top-5 keep 3; keyword+top-5 fallback offline) + sessions (per-run, frequency-word summaries, no LLM).
- Fact: `{content, category user/relationship/shared_experience, importance 0-100, confidence, referenceCount, embedding+model}`. Importance from length/emotion/personal/sentiment. Dedup same-normalized or cosine ≥0.9 (+refcount, max importance). Budget by ctx window (≤4k: 6 turns/3 facts; ≤8k: 10/5; larger: 20/10). Export strips vectors, backfills after import. Graph (force-graph), Facts/Sessions/State/Parser-test tabs. Facts uneditable in place (delete+re-add); chat "actually I moved…" adds new but old stays till deleted.
- Privacy: runs locally, nothing sent to search. Photos stay on device except the one vision request (notice first cloud use).

## 5. Voice + MCP

- TTS: ElevenLabs/OpenAI/Fish-Audio/Local Kokoro-FastAPI (`:8880/v1/`) /OmniVoice (`:8881/v1/`, streaming while model writes, multilingual `speak_segment` tools or inline `speak()`). Others wait for full reply → sentence-split, 1-ahead synth. Lip-sync via WebAudio analyser. Speed only in OmniVoice (0.5–2.0 shared).
- STT priority (no picker): local server (any OpenAI-compatible Whisper, timeout 5–600s def 30) → Groq (`whisper-large-v3-turbo`) → OpenAI (`whisper-1`) → Web Speech (US-English, no desktop). Desktop PTT `Ctrl+Shift+Space` hold/release.
- LLM: OpenAI/Anthropic/Gemini/DeepSeek/xAI/OpenRouter-compatible/Ollama/LM Studio. Vision-gated (provider flag + model-name; local relies on name e.g. LLaVA/gemma3/qwen2.5-vl); images ≤1568px longest edge, HEIC→JPEG, keepsakes locally.
- MCP: HTTP+stdio server / HTTP-only desktop (Tauri HTTP plugin, unrestricted `http(s)://**` by necessity). Off by default (`MCP_ENABLED=server|both`, 404 otherwise, hidden nav). Per-server switch, Refresh tool list, bearer only, flat namespace (first wins). ≤5 tool rounds, ≤8 calls/round, 15s timeout, 8k chars/result. Hardening: Ask-before-run default on (queued dialogs, decline = "don't retry" result), `PUBLIC_MCP_PROMPT_HARDENING` default on (results = untrusted data), `PUBLIC_MCP_CONFIRM_TOOLS` never auto-run (403 direct), stdio fail-closed (`MCP_STDIO_ALLOWED_COMMANDS` exact + `*` rest, `MCP_STDIO_ENV_ALLOWLIST`, secrets never inherited, `PATH/HOME/NODE_OPTIONS…` always dropped). Unauthenticated routes — never expose MCP-enabled deploy without auth proxy; startup warnings.

## 6. What Chunks v2 borrows (patterns only)

Provider registry + direct-fetch desktop, clamped LLM deltas + extraction fallback, memory budget + dedup + reminder-as-system-event, MCP Ask-before-run + hardening + allowlists shape, Kokoro-local + Whisper-local priority, vision-gating honesty. No VRM/3D/AR/photo/dating-sim. No code copied.

## 7. Gaps for Chunks goals

No screen-awareness (attach-only), no annotate/trailer/point, no AX computer-use/policy gate, no notch shell, no launchd scheduler. Desktop+web data separate; save excludes settings/avatars/photos/reminders. Heavy 3D stack irrelevant to menu-bar tutor.
