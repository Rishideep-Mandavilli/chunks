<!-- impeccable:product-schema 1 -->

# Product

## Platform

macos

> Native macOS menu-bar/notch companion (AppKit shell + SwiftUI surfaces, SwiftPM). Not web,
> not iOS; `impeccable context` has no enum for a desktop-native target, so this is recorded
> literally rather than forced into the closest wrong value.

## Users

Rishi — the developer and only user. A power user on a 1710×1107 built-in display with a notch,
working in the middle of other people's apps (WhatsApp, Chrome, Finder, Xcode, Qoder). He drives
the machine by voice while his hands stay on the keyboard, and he is usually mid-task in another app
when he asks. He reads logs (`~/Library/Logs/Chunks/chunks.log`) and verifies behaviour on his own
screen rather than taking a report.

## Product Purpose

Chunks sees the screen, explains it, and helps him act on it, by voice. Circle a region and get that
region explained; ask where a control is and the pointer trailer flies there; tell it to do something
and it presses, types or scrolls the real control. Success means one spoken sentence turns into
several completed steps, with nothing happening to his machine that he did not see or agree to.

## Positioning

It acts on the operating system rather than on a picture of it. A request can name a control
(`app=WhatsApp role=button name=Send`) and Chunks resolves it against the live Accessibility tree, so
a window that moved, a display that rescaled, or a screen that only appeared after the previous step
does not misaim the action. Every act still passes a policy gate and a consent card the model cannot
talk past, and keys go direct to the provider with nothing stored.

## Operating Context

- Voice-first: ⌃⌥ tap-to-arm dictation (a second tap sends), ⌃C panel, ⌃⌘D circle-to-explain.
- The notch is the always-present surface; the menu-bar panel is settings.
- Answers arrive as a streamed card, spoken aloud as well as shown, so the two texts are deliberately
  different — what is said is short, what is shown can be thorough.
- Plans run several acts in order and stop at the first step that does not happen.
- He uses it on a machine where "ask before acting" is off by default: routine acts run silently and
  report what happened in one line.

## Capabilities and Constraints

- **One assistant, one tool loop.** No sub-agents, no agent teams, no generated artifacts, no
  marketplace, no cloud backend or analytics. BYOK direct to the provider.
- **Screen capture needs the signed bundle**, and an ad-hoc signature breaks TCC grants and the
  Keychain ACL, so packaging is a product requirement, not trivia.
- **Latency is a feature.** A turn carries a 60-second budget; a 503 retries the same model, a 429 or
  a silent timeout switches. A turn that takes a minute is a bug.
- **Memory is 2 KB, never truncated, and the model cannot write it** — it proposes, the app validates
  and merges, and secrets are rejected before any write.
- **Coordinates remain the fallback** for content with no published name (Chromium web content), so
  both aims live side by side.
- **Permanent acts are never automatic.** A control the app names Send, Pay, Delete, Confirm and
  friends is asked about even with asking switched off and even in an always-allowed app.
- Out of scope by decision: multi-agent orchestration, artifacts, hosted model proxy, timers.

## Brand Commitments

- Name: **Chunks**. Mark: the orange triangle in the menu bar. No logo file was supplied and none may
  be invented.
- Voice: plain, specific, never promotional. It says what happened ("Pressed Search.", "Typed 3
  characters into Search.") and never claims a result it was not told.
- The notch pill carries the recognizer's live transcript while he is talking, then a one-line hint.
- No remote assets are fetched or played anywhere in the app, and that must stay true.

## Evidence on Hand

- Real, current screens: the notch card (streamed answer, `<DONE_TITLE>` label, next-action chips,
  act outcome line), the notch pill, the menu-bar panel (permissions, API key, switches), the
  circle-to-explain overlay and the crop-markup panel.
- `~/Library/Logs/Chunks/chunks.log` holds per-turn timings, the model chain, each failure and the
  decision taken — the honest source for any status the UI shows.
- Read-only probes that print what a real point, name or file resolves to: `--probe-ax`,
  `--probe-semantic`, `--probe-fields`, `--probe-desktop`, `--probe-read`, `--probe-voice`.
- 437 unit assertions across 24 suites, run with `swift run chunks-test`.
- **Absent and not to be fabricated:** users, testimonials, download counts, pricing, benchmarks,
  screenshots of other people's machines, and any voice or icon set beyond what is installed here.

## Product Principles

1. **The user owns the irreversible thing.** Reading, explaining and navigating may be automatic;
   sending, paying, deleting and confirming are his to do.
2. **State what is actually happening.** No progress theatre, no fake "ready" animation to cover
   waiting — the stage and the elapsed time are the real ones from the log.
3. **Fast beats thorough in the notch.** The always-visible surface answers in seconds and lines;
   depth lives where he asks for it.
4. **Nothing is hidden from him.** Every refusal, dropped step and model switch is reported in a line
   he can read and hear.
5. **His machine stays his.** Keys in the Keychain, nothing sent that he did not ask to send, no
   remote asset, no telemetry.

## Accessibility & Inclusion

Single-user desktop tool, so no external conformance target was set. Constraints that do bind: the
notch card sits over the cutout and must stay legible at 320 pt against any wallpaper; text is
spoken as well as shown, so on-screen and spoken wording differ on purpose; and the app must remain
usable with the keyboard alone, since the pointer is the thing Chunks itself moves.

## Confirmed surface decisions (2026-10-18)

- The **notch card is a transient HUD**: answers live there for a moment and dismiss on click-away.
  The durable, richer surface is a future **app window** with history and settings — not built yet.
- Mid-turn, the notch must carry **all four**: real stage + elapsed time, the live transcript, the
  answer text as it streams, and the act outcome lines.
- The **menu-bar panel is settings and keys only** — no answers, no history, no diagnostics feed.
