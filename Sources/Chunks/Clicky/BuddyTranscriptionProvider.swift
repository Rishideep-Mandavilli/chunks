//
//  BuddyTranscriptionProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

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

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

enum BuddyTranscriptionProviderFactory {
    /// Always Apple Speech.
    ///
    /// Upstream chose between AssemblyAI, OpenAI and Apple Speech, preferring whichever
    /// had a key configured. Both paid options are gone, and not only because they cost
    /// money: they work by uploading the user's microphone audio to a third party.
    /// Chunks already sends screenshots to a model, but the microphone is a different
    /// category of data and that should be the user's explicit choice, not a silent
    /// default driven by whether a key happens to be set.
    ///
    /// Apple Speech also runs on-device when the recogniser supports it, so dictation works
    /// with no network at all.
    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = resolveProvider()
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }

    private static func resolveProvider() -> any BuddyTranscriptionProvider {
        AppleSpeechTranscriptionProvider()
    }
}
