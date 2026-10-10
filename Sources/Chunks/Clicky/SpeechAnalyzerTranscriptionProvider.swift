import AVFoundation
import ChunksKit
import Foundation
import Speech

/// A deep copy of a tap buffer, safe to hand to another thread.
///
/// `AVAudioEngine`'s tap hands over a buffer that is valid only for the duration of the callback.
/// Every consumer here reads it later, on its own queue, so each gets its own copy — sharing one
/// buffer across consumers is a race whose symptom is garbled audio with no error, which is the
/// shape this codebase has already been bitten by twice.
enum AudioBufferCopy {
    static func deepCopied(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard source.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength)
        else { return nil }
        copy.frameLength = source.frameLength
        let channels = Int(source.format.channelCount)

        if let from = source.floatChannelData, let to = copy.floatChannelData {
            let bytes = Int(source.frameLength) * MemoryLayout<Float>.stride
            for channel in 0..<channels { memcpy(to[channel], from[channel], bytes) }
        } else if let from = source.int16ChannelData, let to = copy.int16ChannelData {
            let bytes = Int(source.frameLength) * MemoryLayout<Int16>.stride
            for channel in 0..<channels { memcpy(to[channel], from[channel], bytes) }
        } else {
            return nil
        }
        return copy
    }
}

/// Apple's on-device `SpeechAnalyzer` transcription path.
///
/// Conforms to the same `BuddyTranscriptionProvider` seam as the `SFSpeechRecognizer` provider,
/// so the microphone, the `AVAudioEngine` tap and the hotkey path in `BuddyDictationManager` are
/// untouched: swapping engines is one line in the factory, not a re-plumbing. That seam is why
/// the always-on-microphone experiment could be reverted in one commit.
///
/// Not the default yet, deliberately. Which of Apple's two models transcribes an Indian English
/// voice better, and by how much, is a listening judgement — `--probe-stt` exists to make it, and
/// `SpeechEngineChoice` decides until that verdict is in.
@available(macOS 26.0, *)
final class SpeechAnalyzerTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Apple SpeechAnalyzer"
    let requiresSpeechRecognitionPermission = true

    private let kind: AnalyzerEngineKind
    private let resolutionLock = NSLock()
    private var storedResolution: LocaleResolution = .unknown

    /// Whether this Mac has a model this provider can run, decided by `resolveLocale`.
    enum LocaleResolution {
        case unknown
        case available(Locale)
        case unavailable
    }

    init(kind: AnalyzerEngineKind = .dictation) {
        self.kind = kind
    }

    /// Read under the lock: `warmUp` writes it from a task, and a resolution racing an unread
    /// copy is the same class of bug that took dictation down on 2026-10-07.
    private var resolution: LocaleResolution {
        get {
            resolutionLock.lock()
            defer { resolutionLock.unlock() }
            return storedResolution
        }
        set {
            resolutionLock.lock()
            storedResolution = newValue
            resolutionLock.unlock()
        }
    }

    /// Unknown counts as configured: `startStreamingSession` resolves the locale on the fly and
    /// throws if there is nothing to run. Reporting *not* configured before anyone asked would
    /// make `--probe-stt` skip an engine that was about to work.
    var isConfigured: Bool {
        if case .unavailable = resolution { return false }
        return true
    }

    var unavailableExplanation: String? {
        guard case .unavailable = resolution else { return nil }
        return "no on-device speech model for your language yet — using the older recogniser."
    }

    /// Resolve the model at launch, not on the first key press.
    ///
    /// `supportedLocale(equivalentTo:)` is async, and the press path may not await it, so the
    /// answer is cached here by `warmUp()`. This is the same shape that fixed the three-second
    /// dictation lag: whatever costs a round trip with a service belongs before the press.
    func warmUp() {
        Task {
            let resolved = await Self.resolveLocale(for: kind)
            resolution = resolved.map(LocaleResolution.available) ?? .unavailable
        }
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        var resolved: Locale?
        if case .available(let known) = resolution { resolved = known }
        if resolved == nil { resolved = await Self.resolveLocale(for: kind) }
        guard let resolved else {
            resolution = .unavailable
            throw AppleSpeechTranscriptionProviderError(
                message: "dictation is not available on this mac."
            )
        }
        resolution = .available(resolved)

        return try await SpeechAnalyzerSession(
            kind: kind,
            locale: resolved,
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }

    /// The locale the analyser will actually run, or nil when nothing on this Mac answers the
    /// system language.
    ///
    /// Falling back to `en-US` silently — which is what the legacy provider's preference list
    /// does — would transcribe a Telugu sentence with an American model and report success. A
    /// nil here is what makes the factory degrade out loud.
    static func resolveLocale(for kind: AnalyzerEngineKind) async -> Locale? {
        let current = Locale.autoupdatingCurrent
        for candidate in [current, Locale(identifier: "en_IN")] {
            if let matched = await kind.supportedLocale(equivalentTo: candidate) { return matched }
        }
        return nil
    }
}

/// Which of Apple's two ASR modules to load. Their result types differ, so this is also the
/// switch that knows how to read each one.
@available(macOS 26.0, *)
enum AnalyzerEngineKind: String, CaseIterable {
    case dictation
    case transcription

    func makeModule(locale: Locale) -> any SpeechModule {
        switch self {
        case .dictation:
            return DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
        case .transcription:
            return SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        }
    }

    func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
        switch self {
        case .dictation:
            return await DictationTranscriber.supportedLocale(equivalentTo: locale)
        case .transcription:
            return await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        }
    }
}

/// One dictation, fed through a stream the audio thread only ever yields into.
///
/// `appendAudioBuffer` is called on the render thread. Its whole job is to copy the buffer and
/// hand it to an `AsyncStream` continuation; conversion and consumption happen in tasks. The
/// alternative — mutating shared state from the tap — is what broke push-to-talk outright on
/// 2026-10-07, when a Swift array was written on the audio thread while the main thread drained
/// it.
@available(macOS 26.0, *)
private final class SpeechAnalyzerSession: BuddyStreamingTranscriptionSession {
    /// Shorter than the legacy provider's 1.8s: the analyser answers end-of-speech on its own,
    /// so this is only the safety net for a finalisation that never reports back.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 1.5

    private let analyzer: SpeechAnalyzer
    private let module: any SpeechModule
    private let rawStream: AsyncStream<AudioBufferPacket>
    private let rawContinuation: AsyncStream<AudioBufferPacket>.Continuation
    private let inputStream: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation

    private let lock = NSLock()
    private var latestText = ""
    private var hasRequestedFinal = false
    private var hasDeliveredFinal = false
    private var analysisFailed: Error?

    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    init(
        kind: AnalyzerEngineKind,
        locale: Locale,
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws {
        let module = kind.makeModule(locale: locale)
        self.module = module
        self.analyzer = SpeechAnalyzer(modules: [module])
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError

        let raw = AsyncStream.makeStream(of: AudioBufferPacket.self, bufferingPolicy: .unbounded)
        let input = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        rawStream = raw.0
        rawContinuation = raw.1
        inputStream = input.0
        inputContinuation = input.1

        // The words the caller said to expect. `contextualStrings` on the old request was the
        // fix for "message Nitesh" hearing a random word instead of *Nitesh*; the analyser's
        // equivalent is this dictionary, and dropping it here would undo that fix silently.
        if !keyterms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = keyterms
            try? await analyzer.setContext(context)
        }

        let results = Self.hits(from: module)
        let inputStream = self.inputStream

        Task { [weak self] in
            do {
                for try await hit in results { self?.handle(hit) }
            } catch {
                self?.noteFailure(error)
            }
            self?.analysisEnded()
        }

        Task { [weak self] in
            guard let self else { return }
            // `AnalyzerInputConverter` is a year newer than the analyser itself, so the fallback
            // hands over the raw buffer rather than refusing to run on macOS 26.
            if #available(macOS 27.0, *) {
                let converter = try? await AnalyzerInputConverter.converter(compatibleWith: [module])
                for await packet in self.rawStream {
                    for input in (try? converter?.convert(packet.buffer, at: nil)) ?? [] {
                        self.inputContinuation.yield(input)
                    }
                }
                for input in (try? converter?.flush()) ?? [] {
                    self.inputContinuation.yield(input)
                }
            } else {
                for await packet in self.rawStream {
                    self.inputContinuation.yield(AnalyzerInput(buffer: packet.buffer))
                }
            }
            self.inputContinuation.finish()
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.analyzer.start(inputSequence: inputStream)
            } catch {
                self.noteFailure(error)
            }
        }
    }

    /// A progressive result. Not every result that says `isFinal` ends the dictation: with a
    /// progressive preset it marks a *segment* that will no longer change, while the speaker is
    /// still talking. Delivering the transcript on the first one would answer the user mid-sentence,
    /// so finality here means "the user stopped talking *and* the engine stopped changing its mind".
    private func handle(_ hit: SpeechHit) {
        lock.lock()
        latestText = hit.text
        let requested = hasRequestedFinal
        lock.unlock()
        onTranscriptUpdate(hit.text)
        if hit.isFinal && requested { deliverFinalIfPossible() }
    }

    private func analysisEnded() {
        lock.lock()
        let requested = hasRequestedFinal
        lock.unlock()
        if requested { deliverFinalIfPossible() }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        lock.lock()
        let closed = hasRequestedFinal
        lock.unlock()
        guard !closed else { return }
        guard let copy = AudioBufferCopy.deepCopied(audioBuffer) else { return }
        rawContinuation.yield(AudioBufferPacket(buffer: copy))
    }

    func requestFinalTranscript() {
        lock.lock()
        let already = hasRequestedFinal
        hasRequestedFinal = true
        lock.unlock()
        guard !already else { return }

        rawContinuation.finish()
        let analyzer = self.analyzer
        Task { [weak self] in
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                self?.noteFailure(error)
            }
        }
    }

    func cancel() {
        rawContinuation.finish()
        let analyzer = self.analyzer
        Task {
            await analyzer.cancelAndFinishNow()
        }
    }

    // MARK: - Result plumbing

    private func noteFailure(_ error: Error) {
        lock.lock()
        analysisFailed = error
        lock.unlock()
        deliverFinalIfPossible()
    }

    private func deliverFinalIfPossible() {
        lock.lock()
        let text = latestText
        let done = hasDeliveredFinal
        hasDeliveredFinal = true
        let failure = analysisFailed
        lock.unlock()
        guard !done else { return }

        if !text.isEmpty {
            onFinalTranscriptReady(text)
        } else if let failure {
            onError(failure)
        } else {
            onFinalTranscriptReady("")
        }
    }

    private static func hits(from module: any SpeechModule) -> AsyncThrowingStream<SpeechHit, Error> {
        if let dictation = module as? DictationTranscriber {
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await result in dictation.results {
                            continuation.yield(SpeechHit(
                                text: String(result.text.characters),
                                isFinal: result.isFinal
                            ))
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        if let transcriber = module as? SpeechTranscriber {
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await result in transcriber.results {
                            continuation.yield(SpeechHit(
                                text: String(result.text.characters),
                                isFinal: result.isFinal
                            ))
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        return AsyncThrowingStream { $0.finish() }
    }
}

/// A buffer that has crossed a thread boundary by being copied, not by being shared.
private struct AudioBufferPacket: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

private struct SpeechHit: Sendable {
    let text: String
    let isFinal: Bool
}

@available(macOS 26.0, *)
extension AnalyzerEngineKind {
    /// nil for `.legacyRecognizer`: the caller is supposed to have already decided not to build
    /// an analyser, and going through the enum instead of reading the string twice is what keeps
    /// the preference parser and the engine list from drifting apart.
    init?(speechChoice: SpeechEngineChoice) {
        switch speechChoice {
        case .analyzerDictation: self = .dictation
        case .analyzerTranscription: self = .transcription
        case .legacyRecognizer: return nil
        }
    }
}
