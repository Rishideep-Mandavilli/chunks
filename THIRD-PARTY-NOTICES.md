# Third-Party Notices

Chunks incorporates and adapts code from the following open-source projects.

---

## farzaa/clicky

- **Upstream:** https://github.com/farzaa/clicky
- **Licence:** MIT
- **Copyright:** Copyright (c) 2026 Farza
- **Retrieved:** 2026-09-29 (commit at `origin/main`, frozen 2026-04-28)

### Files vendored or adapted

| Upstream file | Chunks file | Nature |
|---|---|---|
| `leanring-buddy/GlobalPushToTalkShortcutMonitor.swift` | `Sources/Chunks/Voice/PushToTalkMonitor.swift` | Adapted. Same listen-only `CGEvent` tap design. Retargeted at `ChunksPhase` instead of a `PassthroughSubject`, and the tap's `userInfo` indirection kept so the C callback can reach a Swift object safely. |
| `leanring-buddy/BuddyTranscriptionProvider.swift` | `Sources/ChunksKit/Voice/TranscriptionProvider.swift` | Adapted. The protocol and the Apple Speech provider. The AssemblyAI and OpenAI provider branches were dropped: both are paid and require shipping audio off the machine, which is out of scope for Chunks. |
| `leanring-buddy/AppleSpeechTranscriptionProvider.swift` | `Sources/ChunksKit/Voice/AppleSpeechTranscriptionProvider.swift` | Adapted. Kept `requiresOnDeviceRecognition`, `shouldReportPartialResults`, and the final-transcript-on-error path. |
| `leanring-buddy/BuddyAudioConversionSupport.swift` | referenced, not yet vendored | Read for reference when the microphone pipeline lands. |

### Substantive changes made

1. **`PushToTalkMonitor`** reports transitions through a closure rather than Combine, and
   the "is the shortcut down" flag is still published so the menu-bar icon can react
   immediately rather than waiting on the async dictation pipeline.
2. **Providers dropped.** `BuddyTranscriptionProviderFactory` selected between AssemblyAI,
   OpenAI and Apple Speech. Chunks keeps only Apple Speech, which runs on-device. Sending a
   user's microphone audio to a third party is a decision Chunks must not make on their
   behalf, and neither alternative was free.
3. **Types renamed** (`Buddy*` → `Chunks*`) and made `public` where they cross the
   ChunksKit boundary.

### Why these were vendored rather than rewritten

The push-to-talk monitor handles a failure that is otherwise invisible and permanent: macOS
silently disables a `CGEvent` tap that takes too long in its callback
(`.tapDisabledByTimeout`), and without the re-enable branch the hotkey simply stops
working for the rest of the session. The transcription provider gets
`requiresOnDeviceRecognition` right, which keeps dictation off the network.

Both are things that would have been re-derived by trial and error.

---

## Licence text

MIT License

Copyright (c) 2026 Farza

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
