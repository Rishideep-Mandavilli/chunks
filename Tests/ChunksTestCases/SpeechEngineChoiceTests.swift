import ChunksTestHarness
@testable import ChunksKit

/// Tests for the speech-engine switch.
///
/// Every case is about a fallback, because that is the only way this logic fails in front of a
/// user: a typo, an empty value, or a Mac without the newer stack must all still produce a
/// working microphone path — and must never pretend the engine the user asked for is the one that
/// answered him.
public enum SpeechEngineChoiceTests {

    public static func register() {
        TestRunner.currentSuite = "Speech engine choice"

        test("no preference runs the dictation model the user measured as better") {
            let chosen = SpeechEngineChoice.resolve(preference: nil, analyzerAvailable: true)
            expectEqual(chosen, .analyzerDictation,
                        "on his own voice this model heard \"Star Mahila\" where the recogniser heard \"Mahina\", at the same latency — the default is the measured winner, not the historical one")
        }

        test("no preference on a Mac without the analyser still dictates") {
            let chosen = SpeechEngineChoice.resolve(preference: nil, analyzerAvailable: false)
            expectEqual(chosen, .legacyRecognizer,
                        "the default became macOS 26-only in 2026-10-09 while the deployment floor is 15.2; a default that cannot run must fall back, not fail")
        }

        test("an empty preference is no preference, not an unknown engine") {
            let chosen = SpeechEngineChoice.resolve(preference: "   ", analyzerAvailable: true)
            expectEqual(chosen, .analyzerDictation,
                        "a blank field in a settings surface must not read as a request the code cannot honour")
        }

        test("a typo in the switch keeps dictation working") {
            let chosen = SpeechEngineChoice.resolve(preference: "dictaion", analyzerAvailable: true)
            expectEqual(chosen, SpeechEngineChoice.defaultChoice,
                        "someone flipping this from a terminal is debugging by ear; losing the microphone as well as the experiment doubles the bug")
        }

        test("asking for the newer engine on a Mac without it falls back") {
            let chosen = SpeechEngineChoice.resolve(preference: "dictation", analyzerAvailable: false)
            expectEqual(chosen, .legacyRecognizer,
                        "the analyser is macOS 26+; the only safe answer on an older system is the older API")
        }

        test("asking for legacy on a Mac that has the analyser is honoured") {
            let chosen = SpeechEngineChoice.resolve(preference: "legacy", analyzerAvailable: true)
            expectEqual(chosen, .legacyRecognizer,
                        "the switch exists so a comparison can be re-run; \"legacy\" must mean legacy even when something better is installed")
        }

        test("the fallback out to an unavailable engine is reported, not swallowed") {
            let notice = SpeechEngineChoice.degradationNotice(
                preference: "transcription",
                analyzerAvailable: false
            )
            expect(notice != nil,
                   "invariant 5's rule: degrading is fine, degrading quietly is not — the user must know which engine just answered him")
        }

        test("choosing legacy on purpose never warns") {
            let notice = SpeechEngineChoice.degradationNotice(
                preference: "legacy",
                analyzerAvailable: true
            )
            expect(notice == nil,
                   "an ordinary fact must not be treated as a failure; warning here would teach the user to ignore the warnings")
        }

        test("a working preference does not warn about an engine it got") {
            let notice = SpeechEngineChoice.degradationNotice(
                preference: "dictation",
                analyzerAvailable: true
            )
            expect(notice == nil,
                   "the notice is about a substitution, not about which engine is running")
        }

        test("the two spellings of the analyser mean the dictation model") {
            let chosen = SpeechEngineChoice.resolve(preference: "analyzer", analyzerAvailable: true)
            expectEqual(chosen, .analyzerDictation,
                        "the shorter alias is what someone types at a prompt; it must not silently mean the other model")
        }

        test("the engine list and its parser agree with each other") {
            expectEqual(SpeechEngineChoice.allCases.count, 3,
                        "adding an engine without a mapping is the drift this enum exists to prevent")
        }
    }
}
