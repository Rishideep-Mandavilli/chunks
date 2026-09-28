import AVFoundation
import Foundation

/// Speaks the answer aloud.
///
/// `AVSpeechSynthesizer` rather than the newer `Speech` framework's `AVSpeechSynthesizer`
/// successors, and deliberately so: `AVSpeechSynthesizer` speaks from an utterance queued
/// before generation started, whereas the modern synthesizer is built around streaming
/// audio that is played as it is produced. Chunks already has the text when it needs to
/// speak, so the simpler API is the right fit.
@MainActor
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate {

    static let shared = SpeechOutput()
    private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    func speak(_ utterance: AVSpeechUtterance) {
        // A new turn cancels the previous answer rather than queueing behind it. The user
        // asking a second question is a decision that the first answer is no longer wanted,
        // and hearing both is slower than hearing either.
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in VoiceState.shared.speakingFinished() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in VoiceState.shared.speakingFinished() }
    }
}

/// Whether Chunks is currently speaking, so the menu bar icon and the panel agree.
///
/// Separate from `SpeechOutput` because the synthesizer delegate callbacks arrive on an
/// arbitrary queue and the answer has to reach observable state somewhere on the main
/// actor.
@MainActor
final class VoiceState {
    static let shared = VoiceState()
    private init() {}

    private(set) var isSpeaking = false
    private var observers: [() -> Void] = []

    func speakingStarted() {
        isSpeaking = true
        notify()
    }

    func speakingFinished() {
        isSpeaking = false
        notify()
    }

    func observe(_ block: @escaping () -> Void) {
        observers.append(block)
    }

    private func notify() {
        for block in observers { block() }
    }
}
