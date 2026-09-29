//
//  LocalTTSClient.swift
//  Chunks
//
//  Stands in for farzaa/clicky's ElevenLabsTTSClient.
//
//  Upstream's client is `speakText(_:) async throws`, exposes `isPlaying` and
//  `stopPlayback()`, and fetches audio from a Cloudflare worker the project ships in
//  `worker/`. Chunks has no backend and is not going to become one — the answer is text
//  the app already has in hand, so it is spoken locally with `AVSpeechSynthesizer`, free
//  and with no audio leaving the machine.
//
//  The interface deliberately matches upstream's exactly (same three members, same
//  signatures) so every call site in `CompanionManager` compiles unchanged.
//

import AVFoundation
import Foundation

final class LocalTTSClient {

    private let synthesizer = AVSpeechSynthesizer()
    private var currentText: String = ""

    /// Slightly faster than the default rate. The answers are short explanations, and
    /// `AVSpeechUtteranceDefaultSpeechRate` reads as hesitant at that length.
    var rateMultiplier: Float = 1.05

    init() {}

    var isPlaying: Bool {
        synthesizer.isSpeaking
    }

    /// Speak `text`, interrupting anything already playing.
    ///
    /// `async throws` to match the upstream client. There is nothing to throw here, but
    /// keeping the shape means the caller's error handling still makes sense if this is
    /// ever swapped for a real service.
    func speakText(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        currentText = trimmed

        // A new answer cancels the previous one rather than queueing behind it. Asking a
        // second question is a decision that the first answer is no longer wanted.
        await MainActor.run {
            if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }

            let utterance = AVSpeechUtterance(string: trimmed)
            utterance.voice = AVSpeechSynthesisVoice(
                language: AVSpeechSynthesisVoice.currentLanguageCode())
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * rateMultiplier
            synthesizer.speak(utterance)
        }
    }

    func stopPlayback() {
        MainActor.assumeIsolated {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
}
