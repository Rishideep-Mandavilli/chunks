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

**The app runs. 142 tests passing.**

| | |
|---|---|
| Coordinate authority | ✅ tested at 1x/2x/3x, incl. negative-origin displays |
| Screen capture | ✅ `SCScreenshotManager`, backing scale measured not assumed |
| Secret rejection | ✅ 12 provider prefixes + entropy heuristic |
| Memory store | ✅ plain markdown, 2 KB cap, never truncated |
| Reply protocol parser | ✅ streaming, fail-open, split-tag safe |
| Provider registry | ✅ capability profiles, `$0` fallback chain |
| Retry + rate limiting | ✅ jittered backoff, 5 req/min token bucket |
| Gemini request/SSE | ✅ `store:false` enforced by test |
| Region resolver | ✅ marks → padded, clamped crop |
| Menu bar + hotkey | ✅ running |
| Circle-to-explain | ✅ overlay draws, marks burn into the screenshot |
| Point resolution | ✅ image-local pixels → global points, round-trip tested |
| Answer panel | ⏳ replies land in the menu, nothing to read on screen |
| Voice in/out | ⏳ Phase 4 |
| Computer use | ⏳ Phase 5 |

### Build and run

```bash
swift build                       # everything
swift run chunks-test             # 142 tests (NOT `swift test`)

swift build -c release            # then assemble the bundle
./scripts/make-app.sh release
open build/Chunks.app
```

Requires Xcode. Then grant Screen Recording when prompted, and **quit and reopen Chunks**
— macOS only applies a newly granted capture permission after relaunch.

Put a Gemini API key in via the menu (stored in the login Keychain, never in a plist), or:

```bash
CHUNKS_GEMINI_KEY=... open build/Chunks.app
```

See `CHUNKS-BUILD-PLAN.md` §6 for the full phase breakdown.

## Licence

Chunks is an independent project. It borrows ideas from, but does not include code from,
`farzaa/clicky` (MIT) — the original open-source HeyClicky.
