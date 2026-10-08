import AVFoundation
import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// Covers the voice choice, which is the half of every answer the user has to *listen* to.
///
/// The bug this suite exists for: `AVSpeechSynthesisVoice(language:)` returns the compact voice
/// for the current language, and on a machine holding two premium neural female voices that is how
/// a spoken answer came out sounding far worse than the same words on the card.
public enum SpeechVoiceTests {

    static func voice(_ identifier: String, _ name: String, _ language: String, _ quality: Int)
        -> SpeechVoices.Voice {
        SpeechVoices.Voice(identifier: identifier, name: name, language: language, quality: quality)
    }

    static let machine: [SpeechVoices.Voice] = [
        voice("com.apple.ttsbundle.gryphon-neural_Riya_en-IN_premium", "Voice 1", "en-IN", 2),
        voice("com.apple.ttsbundle.gryphon-neural_Simone_en-US_premium", "Voice 2", "en-US", 2),
        voice("com.apple.voice.super-compact.en-US.Samantha", "Samantha", "en-US", 1),
        voice("com.apple.speech.synthesis.voice.Zarvox", "Zarvox", "en-US", 1),
        voice("com.apple.voice.compact.fr-FR.Amelie", "Amelie", "fr-FR", 1),
    ]

    static func register() {
        test("a premium voice outranks a compact one, whatever its name") {
            let ranked = SpeechVoices.ranked(machine)
            expectEqual(ranked.first?.identifier.contains("Riya") ?? false, true,
                        "the machine has two premium neural voices and the compact one was picked")
            expect(ranked.last?.language == "en-US" || ranked.last?.language == "en-IN",
                   "a French voice must never be offered as an English answer")
            expect(!ranked.contains { $0.language.hasPrefix("fr") },
                   "ranking is over English voices only")
        }

        test("the name the panel shows is a person's, not \"Voice 1\"") {
            // The API's own `name` is literally a placeholder on the two best voices here.
            let riya = SpeechVoices.displayName(for: machine[0])
            expectEqual(riya, "Riya", "the settings row would read \"Voice 1\" for a named voice")
            expectEqual(SpeechVoices.displayName(for: machine[1]), "Simone")
            expectEqual(SpeechVoices.displayName(for: machine[2]), "Samantha",
                        "a voice with a real name keeps it")
        }

        test("a chosen voice is kept, and a deleted one falls back without failing") {
            let chosen = SpeechVoices.pick(from: machine,
                                           storedIdentifier: machine[1].identifier)
            expectEqual(chosen?.identifier ?? "", machine[1].identifier,
                        "the voice the user picked was overridden by the default")
            let gone = SpeechVoices.pick(from: machine, storedIdentifier: "com.apple.removed.Voice")
            expectEqual(gone?.identifier ?? "", machine[0].identifier,
                        "a stored identifier that no longer exists should speak with the best "
                            + "remaining voice, not go silent")
            expect(SpeechVoices.pick(from: [], storedIdentifier: nil) == nil,
                   "no voices at all is the one case with no answer")
        }

        test("the preference list is female English voices, youngest first") {
            // A name list is the only way to ask for this: `AVSpeechSynthesisVoice` has no gender.
            expect(SpeechVoices.preferredEnglish.prefix(3).elementsEqual(["Riya", "Simone", "Ava"]),
                   "the top of the list is the order the user asked for, and it is checked in tests")
            let riya = SpeechVoices.preferredIndex(machine[0])
            let samantha = SpeechVoices.preferredIndex(machine[2])
            expect(riya < samantha, "a listed voice must outrank a voice nobody named")
            expect(SpeechVoices.preferredIndex(machine[3]) > samantha,
                   "Zarvox is a robot voice and must not outrank a person")
        }
        test("the voice Chunks picks is the best English one the machine offers") {
            // Against real hardware on purpose: the whole complaint is that the machine is holding
            // a neural voice the app never used. The assertion is the *rule* rather than a fixed
            // voice, because the set of voices a process can see is not the set System Settings
            // lists — this test binary sees no premium voice at all on this Mac, while the signed
            // app does.
            let real = AVSpeechSynthesisVoice.speechVoices().map {
                SpeechVoices.Voice(identifier: $0.identifier, name: $0.name,
                                   language: $0.language, quality: $0.quality.rawValue)
            }
            let english = real.filter { $0.language.hasPrefix("en") }
            guard let picked = SpeechVoices.pick(from: real) else {
                expect(false, "this Mac has no English voice at all — the app would be silent")
                return
            }
            let best = english.map(\.quality).max() ?? 0
            expect(picked.quality == best,
                   "the pick is quality \(picked.quality) (\(picked.identifier)) while quality "
                       + "\(best) is on this machine — a spoken answer that sounds worse than the "
                       + "same words on the card is the bug this test exists to stop")
            expect(SpeechVoices.displayName(for: picked).count > 2,
                   "the settings row would show a placeholder: \(picked.name)")
        }
    }
}
