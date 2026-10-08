//
//  BuddyTranscriptionProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import ChunksKit
import Foundation
import Speech

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    /// Pay the provider's one-time setup cost at launch instead of on the first key press.
    func warmUp()

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

extension BuddyTranscriptionProvider {
    /// A provider with nothing to pre-flight says so by not implementing this.
    func warmUp() {}
}

enum BuddyTranscriptionProviderFactory {
    /// The `UserDefaults` switch that picks the speech engine. Keychain-free like
    /// `askBeforeActing`, because it is a surface someone flips from a terminal to compare two
    /// engines on their own voice, not a preference worth syncing.
    static let enginePreferenceKey = "app.chunks.sttEngine"

    /// Always Apple, always on-device.
    ///
    /// Upstream chose between AssemblyAI, OpenAI and Apple Speech, preferring whichever
    /// had a key configured. Both paid options are gone, and not only because they cost
    /// money: they work by uploading the user's microphone audio to a third party.
    /// Chunks already sends screenshots to a model, but the microphone is a different
    /// category of data and that should be the user's explicit choice, not a silent
    /// default driven by whether a key happens to be set.
    ///
    /// Both engines available here run on-device, so the choice between them is about accuracy
    /// and latency and never about where the audio goes.
    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = resolveProvider()
        print("🎙️ Transcription: using \(provider.displayName)")
        Log.write("stt: engine=\(provider.displayName)")
        return provider
    }

    private static func resolveProvider() -> any BuddyTranscriptionProvider {
        let legacy = AppleSpeechTranscriptionProvider()
        let preference = UserDefaults.standard.string(forKey: enginePreferenceKey)
        let choice = SpeechEngineChoice.resolve(
            preference: preference,
            analyzerAvailable: SpeechAnalyzerAvailability.isAvailable
        )
        // Why this engine, not just which: the default is now an engine that only exists on
        // macOS 26+, so "legacy" arriving here without a reason is a fallback nobody would see.
        Log.write("stt: preference=\(preference ?? "unset") analyzerAvailable=\(SpeechAnalyzerAvailability.isAvailable) choice=\(choice.rawValue)")
        if let notice = SpeechEngineChoice.degradationNotice(
            preference: preference,
            analyzerAvailable: SpeechAnalyzerAvailability.isAvailable
        ) {
            Log.write("stt: \(notice)")
        }

        switch choice {
        case .legacyRecognizer:
            return legacy
        case .analyzerDictation, .analyzerTranscription:
            guard #available(macOS 26.0, *), let kind = AnalyzerEngineKind(speechChoice: choice)
            else { return legacy }
            return SpeechAnalyzerTranscriptionProvider(kind: kind)
        }
    }
}

/// Whether this Mac has the macOS 26 speech stack at all.
enum SpeechAnalyzerAvailability {
    static var isAvailable: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return SpeechTranscriber.isAvailable
    }
}
