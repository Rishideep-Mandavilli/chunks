# Chunks

A native macOS menu-bar companion that sees your screen, explains it, and helps you act
on it — by voice.

Hold a key, ask a question about whatever's on screen, and get an answer spoken back.
Circle a region to ask about just that region. Draw on the screen and ask "what's going
on here?". Ask where a button is and watch a cursor fly to it.

## Why it exists

This is an independent reimplementation of the idea behind
[HeyClicky](https://heyclicky.com) — a screen-aware companion that explains what you're
looking at — with two deliberate differences:

- **No agents.** No sub-agents, no code generation, no "build me a website". Chunks
  explains and points; it does not build things.
- **Memory is the centre.** Chunks remembers who you are, what you're working on, and
  what it's explained to you before — in a plain-text file you own and can edit.

## Requirements

- macOS 14.2+ (ScreenCaptureKit floor)
- Apple Silicon or Intel
- A Gemini API key from [AI Studio](https://aistudio.google.com/apikey) — the free tier
  is enough

## Build

```bash
swift build              # build
swift run chunks-test    # run the test suite
```

Full Xcode is **not** required. Chunks builds with CommandLineTools alone. See
`AGENTS.md` for why the test runner is custom.

## Cost

| | |
|---|---|
| Brain | **$0** — Gemini free tier, ~1,200 tokens per turn |
| Voice in | **$0** — on-device (`SpeechTranscriber`) |
| Voice out | **$0** — Kokoro, local |
| Everything else | **$0** |

A measured full-screen screenshot (3420×2214) costs **1,066 image tokens**. A typical
turn is ~1,200 tokens total.

## Memory

Your memory lives at:

```
~/Library/Application Support/Chunks/memory.md
```

It is plain markdown. Open it in any editor. Chunks reads it before every turn and
*proposes* edits — you always have the final say, and you can delete anything at any time.

```markdown
# Chunks Memory

## You
- Working on a SwiftUI menu bar app (2026-09-29)
- Uses Raycast, not Spotlight (2026-09-29)

## Corrections
- Don't call it "Spotlight" — I mean Raycast (2026-09-29)
```

Three guarantees:

1. **Credentials are never stored.** Every proposed fact is scanned before it's written.
   Anything resembling an API key, token, JWT, or private key is refused and reported.
2. **Memory is capped at 2 KB and never truncated.** When full, writes are refused and
   you're asked to prune — nothing is ever silently dropped.
3. **The model proposes; the app disposes.** It can't write the file directly, so it
   can't smuggle anything into it.

## Privacy

- Screenshots go to the Gemini API with `store: false` — Google does not retain them.
- Voice recognition and speech synthesis are on-device by default.
- Nothing is written anywhere except your own memory file.

## Layout

```
Sources/ChunksKit/     all logic, unit-tested
  Capture/             CoordinateSpace — the single coord-conversion authority
  Memory/              MemoryStore, SecretSweeper
  Brain/               provider registry + transports
Sources/Chunks/        the AppKit shell (status item, panels, overlays)
Tests/                 harness + test cases
docs/                  ARCHITECTURE.md
CHUNKS-BUILD-PLAN.md   the full phased plan
AGENTS.md              conventions and invariants for AI coding agents
```

## Status

Phase 1 in progress. Complete and tested: coordinate authority, secret rejection, memory
store. See `CHUNKS-BUILD-PLAN.md` §6 for the phase breakdown.

## Licence

Chunks is an independent project. It borrows ideas from, but does not include code from,
`farzaa/clicky` (MIT) — the original open-source HeyClicky.
