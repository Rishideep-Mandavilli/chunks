import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// Tests for the tap-versus-hold rule.
///
/// This is the part of tap-to-arm that fails without anyone noticing: a release that is swallowed
/// at the wrong moment leaves the microphone open with no way to close it, and a hold that is
/// mistaken for a tap sends half a sentence. Neither is a crash, which is why they are here.
public enum TalkArmerTests {

    public static func register() {
        TestRunner.currentSuite = "Tap to arm"

        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }

        test("a quick tap keeps listening instead of sending a fragment") {
            var armer = TalkArmer()
            expectEqual(armer.press(at: at(0)), .beginListening)
            expectEqual(armer.release(at: at(0.12)), .stayArmed,
                        "holding Control for the length of a sentence is the ergonomics being removed; a tap must not submit the two words said so far")
            expect(armer.isArmed, "the armed state is what tells the next press to close the dictation")
        }

        test("holding past the threshold still stops and sends on release") {
            var armer = TalkArmer()
            _ = armer.press(at: at(0))
            let action = armer.release(at: at(0.9))
            expectEqual(action, .stopAndSubmit,
                        "the muscle memory of the last weeks must keep working, so a deliberate hold means exactly what it meant before")
            expect(!armer.isArmed, "a finished dictation must not leave the armer waiting")
        }

        test("a second tap sends, and its own release does not send twice") {
            var armer = TalkArmer()
            _ = armer.press(at: at(0))
            _ = armer.release(at: at(0.1))
            expectEqual(armer.press(at: at(2.0)), .stopAndSubmit,
                        "tap-to-arm has no key-release edge to end the sentence, so the second tap is the end")
            expectEqual(armer.release(at: at(2.05)), .ignore,
                        "the press that ended the dictation also produces a release; acting on it would submit a second, empty turn")
        }

        test("a release with no dictation behind it does nothing") {
            var armer = TalkArmer()
            expectEqual(armer.release(at: at(0.1)), .ignore,
                        "modifier keys are matched on transitions, so a stray release must not be read as the end of a recording")
        }

        test("pressing again while already recording does not start a second session") {
            var armer = TalkArmer()
            _ = armer.press(at: at(0))
            expectEqual(armer.press(at: at(0.5)), .ignore,
                        "two live sessions would fight over one microphone and the second would win, which looks like audio being dropped")
        }

        test("held exactly at the threshold counts as a hold") {
            var armer = TalkArmer()
            _ = armer.press(at: at(0))
            expectEqual(armer.release(at: at(TalkArmer.defaultTapThresholdSeconds)), .stopAndSubmit,
                        "the boundary has to be pinned, or a 350 ms hold arms on one build and sends on the next")
        }

        test("reset after a failed dictation keeps the hotkey alive") {
            var armer = TalkArmer()
            _ = armer.press(at: at(0))
            _ = armer.release(at: at(0.1))
            armer.reset()
            expectEqual(armer.press(at: at(1.0)), .beginListening,
                        "if the engine died while the armer still believed it was armed, the next press would be read as a stop for a session that does not exist — a dead hotkey with no error")
        }
    }
}
