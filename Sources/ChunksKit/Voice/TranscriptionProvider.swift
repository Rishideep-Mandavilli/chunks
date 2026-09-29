//
//  TranscriptionProvider.swift
//  ChunksKit
//
//  Adapted from farzaa/clicky — leanring-buddy/BuddyTranscriptionProvider.swift
//  MIT, Copyright (c) 2026 Farza. See THIRD-PARTY-NOTICES.md.
//
//  The shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

/// One dictation session, streaming.
///
/// A session rather than a single `transcribe(_:)` call because push-to-talk wants the
/// text to appear *as the user speaks*, not after they stop.
public protocol TranscriptionSession: AnyObject {
    /// How long to wait for a final transcript before falling back to the last partial.
    ///
    /// macOS regularly fails to deliver `isFinal` after `endAudio()`; without a deadline
    /// the dictation simply never resolves and the hotkey appears to do nothing.
    var finalTranscriptFallbackDelay: TimeInterval { get }

    func append(_ buffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

public protocol TranscriptionProvider {
    var displayName: String { get }
    /// Whether Chunks must hold a Speech Recognition grant for this provider to work.
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    /// Why this provider cannot be used, if it cannot.
    var unavailableExplanation: String? { get }

    func startSession(
        /// Domain words to bias recognition toward — app names, project names, file names.
        keyterms: [String],
        onUpdate: @escaping (String) -> Void,
        onFinal: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any TranscriptionSession
}

/// Chunks has exactly one provider.
///
/// Upstream's factory chose between AssemblyAI, OpenAI and Apple Speech. Both paid
/// options were dropped, and not on cost grounds alone: they work by uploading the user's
/// microphone audio to a third party. Chunks sends screenshots to a model, but the mic is
/// a different kind of data and that choice is the user's to make, not a silent default.
public enum TranscriptionProviderFactory {
    public static func makeDefault() -> any TranscriptionProvider {
        AppleSpeechTranscriptionProvider()
    }
}
