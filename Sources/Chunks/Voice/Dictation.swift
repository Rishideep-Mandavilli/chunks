//
//  Dictation.swift
//  Chunks
//
//  Built around PushToTalkMonitor and the vendored transcription providers. The surrounding
//  session management follows farzaa/clicky's BuddyDictationManager, which is where the
//  hard parts of push-to-talk live: the final-transcript race, the audio-tap teardown, and
//  the microphone permission that macOS will re-prompt for if you fan out requests.
//  MIT, Copyright (c) 2026 Farza. See THIRD-PARTY-NOTICES.md.
//

import AppKit
import AVFoundation
import ChunksKit
import Combine
import Foundation
import Speech

/// Records while the push-to-talk shortcut is held, then hands over a transcript.
@MainActor
final class Dictation: ObservableObject {

    @Published private(set) var isListening = false
    @Published private(set) var partialTranscript = ""
    @Published private(set) var errorMessage: String?
    /// 0...1, smoothed, for the listening indicator.
    @Published private(set) var audioLevel: CGFloat = 0

    /// Called with the final transcript when the key comes up.
    var onFinalTranscript: ((String) -> Void)?

    private let provider: any TranscriptionProvider
    private let audioEngine = AVAudioEngine()
    private var session: (any TranscriptionSession)?

    /// Guards against a stale session's callbacks landing after a new one has started.
    /// A rapid double-press otherwise lets the first session's final transcript overwrite
    /// the second's answer, which reads as dictation picking the wrong question.
    private var currentSessionID = UUID()

    /// One in-flight permission request. macOS re-shows the microphone sheet if several
    /// requests are issued before the first resolves, so every press awaits this one task.
    private var permissionTask: Task<Bool, Never>?
    private static let permissionCooldown: TimeInterval = 1.0
    private var lastPermissionRequest = Date.distantPast

    /// Guards `installTap` / `removeTap`, which throw if unbalanced.
    private var hasAudioTap = false

    init(provider: any TranscriptionProvider = TranscriptionProviderFactory.makeDefault()) {
        self.provider = provider
    }

    var unavailableExplanation: String? { provider.unavailableExplanation }

    // MARK: - Permissions

    func requestPermissions() async -> Bool {
        if let existing = permissionTask { return await existing.value }
        guard Date().timeIntervalSince(lastPermissionRequest) > Self.permissionCooldown else {
            return SFSpeechRecognizer.authorizationStatus() == .authorized
        }
        lastPermissionRequest = Date()

        let task = Task<Bool, Never> { await performPermissionRequest() }
        permissionTask = task
        let result = await task.value
        permissionTask = nil
        return result
    }

    private func performPermissionRequest() async -> Bool {
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        guard microphone else {
            errorMessage = "Chunks needs the microphone to hear your question."
            return false
        }
        guard provider.requiresSpeechRecognitionPermission else { return true }

        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speech else {
            errorMessage = "Chunks needs Speech Recognition to turn your voice into text."
            return false
        }
        return true
    }

    var hasPermissions: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && (!provider.requiresSpeechRecognitionPermission
                || SFSpeechRecognizer.authorizationStatus() == .authorized)
    }

    // MARK: - Session

    func start(keyterms: [String]) async {
        guard !isListening else { return }
        guard await requestPermissions() else { return }

        isListening = true
        partialTranscript = ""
        errorMessage = nil
        audioLevel = 0

        let identifier = UUID()
        currentSessionID = identifier
        let isCurrent: @Sendable () -> Bool = { [weak self] in
            MainActor.assumeIsolated { self?.currentSessionID == identifier }
        }

        do {
            let session = try await provider.startSession(
                keyterms: keyterms,
                onUpdate: { [weak self] text in
                    Task { @MainActor in
                        guard isCurrent() else { return }
                        self?.partialTranscript = text
                    }
                },
                onFinal: { [weak self] text in
                    Task { @MainActor in
                        guard isCurrent() else { return }
                        self?.finish(with: text)
                    }
                },
                onError: { [weak self] error in
                    Task { @MainActor in
                        guard isCurrent() else { return }
                        self?.errorMessage = (error as? LocalizedError)?.errorDescription
                            ?? "Couldn't hear that."
                        self?.teardown()
                    }
                })
            self.session = session
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't start dictation."
            teardown()
            return
        }

        startAudio()
    }

    /// Stop recording and wait briefly for the final transcript.
    func stop() {
        guard isListening else { return }
        session?.requestFinalTranscript()
        stopAudio()
        audioLevel = 0

        // Apple frequently fails to deliver `isFinal` after `endAudio()`. Without this
        // deadline the transcript simply never arrives and push-to-talk looks broken.
        let deadline = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.deliverIfStillWaiting() }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(1.8 * 1_000_000_000))
            deadline.perform()
        }
    }

    func cancel() {
        session?.cancel()
        teardown()
    }

    private func deliverIfStillWaiting() {
        let text = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        finish(with: text)
    }

    private func finish(with text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        teardown()
        guard !trimmed.isEmpty else { return }
        onFinalTranscript?(trimmed)
    }

    private func teardown() {
        isListening = false
        partialTranscript = ""
        stopAudio()
        session = nil
        currentSessionID = UUID()
    }

    // MARK: - Audio

    private func startAudio() {
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.session?.append(buffer)
            self?.updateLevel(from: buffer)
        }
        hasAudioTap = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            // The engine failing here is almost always a microphone in use elsewhere.
            errorMessage = "Couldn't open the microphone."
            cancel()
        }
    }

    private func stopAudio() {
        guard hasAudioTap else { return }
        hasAudioTap = false
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    private func updateLevel(from buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        let rootMeanSquare = sqrt(sum / Float(count))
        // Boosted hard because raw RMS for speech sits near 0.05 and an indicator driven
        // straight off it never appears to move.
        let level = CGFloat(min(max(rootMeanSquare * 10.2, 0), 1))

        Task { @MainActor in
            // Asymmetric smoothing: rise fast so speech onset is visible, fall slowly so the
            // indicator does not flicker between syllables.
            self.audioLevel = max(level, self.audioLevel * 0.72)
        }
    }

    deinit {
        if hasAudioTap { audioEngine.inputNode.removeTap(onBus: 0) }
    }
}
