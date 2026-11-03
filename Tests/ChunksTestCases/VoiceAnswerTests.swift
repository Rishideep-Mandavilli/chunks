import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// Tests for answering the confirm card by voice.
///
/// The dangerous direction here is not a missed "yes" — it is a **false yes**, because the thing a card
/// protects is the act the user has not agreed to. So most of these cases assert that something does
/// *not* count as an answer, and one asserts that no phrase can ever reach "allow always", which is a
/// standing instruction about an entire application and stays a button.
public enum VoiceAnswerTests {

    public static func register() {
        TestRunner.currentSuite = "Voice answers the card"

        test("the ordinary yes and no words are answers") {
            for phrase in ["yes", "yeah", "yep", "ok", "sure", "do it", "go ahead",
                           "allow", "confirm", "sounds good", "carry on"] {
                expectEqual(VoiceAnswer.decide(phrase), .allow, "\"\(phrase)\" means do it")
            }
            for phrase in ["no", "nope", "not now", "cancel", "stop", "skip",
                           "never mind", "no thanks", "leave it"] {
                expectEqual(VoiceAnswer.decide(phrase), .deny, "\"\(phrase)\" means do not")
            }
        }

        test("a transcript is not typed text, and the matcher knows it") {
            // The recogniser capitalises the first word, ends the sentence, and writes contractions
            // with an apostrophe U+2019 rather than ASCII. Each of those alone would have made the
            // feature look broken on a real turn while every hand-typed test still passed.
            expectEqual(VoiceAnswer.decide("Yes."), .allow, "a full stop is not part of the answer")
            expectEqual(VoiceAnswer.decide("YES"), .allow, "case is the recogniser's choice")
            expectEqual(VoiceAnswer.decide("  ok  "), .allow, "and its padding")
            expectEqual(VoiceAnswer.decide("Don’t do it."), .deny,
                        "the curly apostrophe is what macOS transcription actually emits")
            expectEqual(VoiceAnswer.decide("don't"), .deny, "and the straight one")
        }

        test("a sentence that merely contains yes is a new question, not a licence") {
            // This is the whole safety property. "Yes and close the other tab" is a request with an old
            // card hanging off it; treating it as an allow would press something he has now asked to go
            // further than, and treating it as a denial would silently drop his sentence. It is neither:
            // it starts a turn, and ConsentGate's displacement rule denies the outstanding act on its
            // own terms, which is the existing behaviour and the conservative one.
            for notAnAnswer in ["yes and close the other tab",
                                "what is this",
                                "no wait, open chrome instead",
                                "can you do it for me",
                                "yes that is what I meant, now scroll down",
                                "maybe later",
                                "I don't know",
                                "ok google what time is it"] {
                expectEqual(VoiceAnswer.decide(notAnAnswer), .notAnAnswer,
                            "\"\(notAnAnswer)\" must not be read as an answer")
            }
        }

        test("an empty or contradictory utterance answers nothing") {
            expectEqual(VoiceAnswer.decide(""), .notAnAnswer, "silence is not consent")
            expectEqual(VoiceAnswer.decide("   "), .notAnAnswer)
            expectEqual(VoiceAnswer.decide("no yes"), .notAnAnswer,
                        "a contradiction is not a coin toss — it is not an answer")
        }

        test("voice can never grant the standing permission") {
            // `alwaysAllowed` stops asking about an entire application. A phrase a mishearing could
            // produce must not be able to set that, so the mapping has exactly two destinations.
            let everything = Array(VoiceAnswer.allowPhrases.union(VoiceAnswer.denyPhrases))
            expect(!everything.isEmpty, "the vocabulary is the contract; an empty set proves nothing")
            for phrase in everything {
                let outcome = VoiceAnswer.outcome(for: phrase)
                expect(outcome == .allowedOnce || outcome == .denied,
                       "\"\(phrase)\" mapped to \(String(describing: outcome)) — only the two "
                            + "button outcomes are reachable by voice")
                expect(outcome != .alwaysAllowed,
                       "\"\(phrase)\" would have stopped asking about the whole app")
            }
        }

        test("the outcome is the same value the buttons pass") {
            expectEqual(VoiceAnswer.outcome(for: "yes"), ConsentGate.Outcome.allowedOnce,
                        "an allow by voice is the Allow button's own call, not a second path")
            expectEqual(VoiceAnswer.outcome(for: "not now"), ConsentGate.Outcome.denied,
                        "and a denial is Not now's")
            expect(VoiceAnswer.outcome(for: "what is the weather") == nil,
                   "a question has no outcome, so the caller starts a turn with it instead")
        }

        test("the vocabulary has no overlap, so a phrase cannot mean both") {
            let shared = VoiceAnswer.allowPhrases.intersection(VoiceAnswer.denyPhrases)
            expect(shared.isEmpty,
                   "a phrase in both lists is an answer that depends on evaluation order: \(shared)")
        }
    }
}
