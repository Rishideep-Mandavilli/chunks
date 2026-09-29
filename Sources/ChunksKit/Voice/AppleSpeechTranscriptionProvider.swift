//
//  AppleSpeechTranscriptionProvider.swift
//  ChunksKit
//
//  Adapted from farzaa/clicky — leanring-buddy/AppleSpeechTranscriptionProvider.swift
//  MIT, Copyright (c) 2026 Farza. See THIRD-PARTY-NOTICES.md.
//
//  Local dictation backed by Apple's Speech framework. Runs on-device.
//

import AVFoundation
import Foundation
import Speech

public struct AppleSpeechError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Apple's `Speech` framework, not the newer `SpeechTranscriber` from macOS 26.
///
/// The newer API is better at some things but needs macOS 26; Chunks' floor is 15.2, and
/// dictation that works on more machines is worth more than marginal accuracy.
public final class AppleSpeechTranscriptionProvider: TranscriptionProvider {

    public let displayName = "Apple Speech"
    public let requiresSpeechRecognitionPermission = true
    public let isConfigured = true
    public let unavailableExplanation: String? = nil

    public init() {}

    public func startSession(
        keyterms: [String],
        onUpdate: @escaping (String) -> Void,
        onFinal: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any TranscriptionSession {
        guard let recognizer = Self.bestAvailableRecognizer() else {
            throw AppleSpeechError("Dictation isn't available on this Mac.")
        }
        return try AppleSpeechSession(
            recognizer: recognizer,
            keyterms: keyterms,
            onUpdate: onUpdate,
            onFinal: onFinal,
            onError: onError)
    }

    /// Prefer the user's own language, then en-US, then whatever the system offers.
    private static func bestAvailableRecognizer() -> SFSpeechRecognizer? {
        let preferred = [Locale.autoupdatingCurrent, Locale(identifier: "en-US")]
        for locale in preferred {
            if let recognizer = SFSpeechRecognizer(locale: locale) { return recognizer }
        }
        return SFSpeechRecognizer()
    }
}

private final class AppleSpeechSession: NSObject, TranscriptionSession {

    let finalTranscriptFallbackDelay: TimeInterval = 1.8

    private let request: SFSpeechAudioBufferRecognitionRequest
    private var task: SFSpeechRecognitionTask?
    private let onUpdate: (String) -> Void
    private let onFinal: (String) -> Void
    private let onError: (Error) -> Void

    private var latest = ""
    private var hasRequestedFinal = false
    private var hasDeliveredFinal = false

    init(recognizer: SFSpeechRecognizer,
         keyterms: [String],
         onUpdate: @escaping (String) -> Void,
         onFinal: @escaping (String) -> Void,
         onError: @escaping (Error) -> Void) throws {

        self.request = SFSpeechAudioBufferRecognitionRequest()
        self.onUpdate = onUpdate
        self.onFinal = onFinal
        self.onError = onError
        super.init()

        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true

        // Contextual keyterms bias recognition toward the vocabulary in front of the user.
        // "Chunks", "Rishi_Projects", a project name — these are exactly the words a
        // general-purpose recogniser gets wrong, and a question about a screen full of
        // identifiers is the entire use case.
        if !keyterms.isEmpty { request.contextualStrings = keyterms }

        // Keeps the audio on the machine. This is the difference between dictation that
        // works offline and a feature that silently needs a network round trip.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(result: result, error: error)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard !hasRequestedFinal else { return }
        request.append(buffer)
    }

    func requestFinalTranscript() {
        guard !hasRequestedFinal else { return }
        hasRequestedFinal = true
        request.endAudio()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            latest = result.bestTranscription.formattedString
            onUpdate(latest)
            if result.isFinal {
                deliverFinal(latest)
                return
            }
        }

        guard let error else { return }

        // A common and benign ending: an error arriving *after* `endAudio()` with text
        // already captured. Treating that as a failure loses an answer the user already
        // spoke, which is the most frustrating way for dictation to break.
        if hasRequestedFinal, !latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deliverFinal(latest)
        } else {
            onError(error)
        }
    }

    private func deliverFinal(_ text: String) {
        guard !hasDeliveredFinal else { return }
        hasDeliveredFinal = true
        onFinal(text)
    }

    deinit { cancel() }
}
