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
import ChunksKit
import Foundation

final class LocalTTSClient {

    private let synthesizer = AVSpeechSynthesizer()
    private var currentText: String = ""
    private let defaults = UserDefaults.standard

    /// The voice the user last chose, or nil for "the best one this Mac has".
    ///
    /// `UserDefaults` and not the Keychain because it is a preference with no secret in it, and
    /// not a file because the panel changes it live. Same reasoning as `askBeforeActing`.
    private static let voiceKey = "chunks.voiceIdentifier"

    /// Slightly slower than the old default. The answers are short explanations, and a rushed one
    /// reads as a machine clearing a queue rather than a person telling you something.
    var rateMultiplier: Float = 0.97

    /// A touch above the voice's own pitch — the difference between "flat" and "pleasant" on the
    /// compact voices, and small enough not to caricature the neural ones.
    var pitchMultiplier: Float = 1.06

    init() {}

    var isPlaying: Bool {
        synthesizer.isSpeaking
    }

    /// Every English voice on this machine, best-sounding first.
    var availableVoices: [SpeechVoices.Voice] {
        SpeechVoices.ranked(Self.allVoices())
    }

    var chosenVoiceIdentifier: String? {
        get { defaults.string(forKey: Self.voiceKey) }
        set { defaults.set(newValue, forKey: Self.voiceKey) }
    }

    /// The voice to speak with: the stored choice if it still exists, else the best available.
    ///
    /// The old line was `AVSpeechSynthesisVoice(language: currentLanguageCode())`, which asks the
    /// system for *the* voice of the current language and gets the compact one — on this machine
    /// that meant a quality-0/1 voice while two premium neural female voices
    /// (`…_Riya_en-IN_premium`, `…_Simone_en-US_premium`) sat unused, and it is the reason the
    /// spoken half of every answer sounded far worse than the written half.
    private var voice: AVSpeechSynthesisVoice? {
        guard let picked = SpeechVoices.pick(from: availableVoices,
                                             storedIdentifier: chosenVoiceIdentifier),
              let real = AVSpeechSynthesisVoice(identifier: picked.identifier)
        else { return AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode()) }
        if lastSpokenIdentifier != real.identifier {
            // Logged once per voice, not once per sentence: the answer to "why does it still sound
            // wrong" is which voice this signed process was actually offered, and the list a bare
            // test binary sees is not the list System Settings shows.
            Log.write("voice: \(SpeechVoices.displayName(for: picked)) "
                + "quality \(picked.quality) [\(picked.identifier)]")
            lastSpokenIdentifier = real.identifier
        }
        return real
    }

    private var lastSpokenIdentifier: String?

    /// The descriptors `SpeechVoices` ranks. `name` is kept because it is what the panel shows
    /// when the API bothers to give one.
    static func allVoices() -> [SpeechVoices.Voice] {
        AVSpeechSynthesisVoice.speechVoices().map {
            SpeechVoices.Voice(identifier: $0.identifier, name: $0.name,
                               language: $0.language, quality: $0.quality.rawValue)
        }
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
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * rateMultiplier
            // A little above the voice's own pitch, and slower than the old rate: "sweet" is mostly
            // about not being rushed, and the neural voices stay natural at this offset while a
            // compact one gets chipmunk-y past about 1.1.
            utterance.pitchMultiplier = pitchMultiplier
            synthesizer.speak(utterance)
        }
    }

    func stopPlayback() {
        MainActor.assumeIsolated {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
}
