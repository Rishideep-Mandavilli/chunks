import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// Tests for deciding when an earlier screen is what a sentence means.
///
/// The cost is asymmetric and both directions hurt: attach yesterday's screenshot to every turn and
/// each answer is a second slower and a thousand tokens fatter; attach none and "now answer it" is
/// answered about whatever happens to be in front of him now, which is the failure he reported.
public enum ScreenCarryTests {

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    public static func register() {
        TestRunner.currentSuite = "Carried screen"

        test("a sentence that points back at what he showed is recognised") {
            for phrase in ["now answer it", "solve that problem", "what was the answer",
                           "read the code i showed you", "continue with the error i said"] {
                expect(ScreenCarry.refersToAShownScreen(phrase), "\"\(phrase)\" was treated as new")
            }
        }

        // The false-positive half, which is the expensive one. `it` and `this` are in every other
        // test's vocabulary, and a rule that fires on them alone would put a stale screenshot in
        // front of every ordinary question about the screen he is looking at.
        test("a fresh question about the live screen carries nothing") {
            for phrase in ["what does this button do", "where is the color inspector",
                           "why is the certificate warning showing", "read the invoice pdf",
                           "click send"] {
                expect(!ScreenCarry.refersToAShownScreen(phrase),
                       "\"\(phrase)\" would have attached an earlier screen it never mentioned")
            }
        }

        test("a carried screen expires with the thread it came from") {
            expect(ScreenCarry.isStillValid(capturedAt: now.addingTimeInterval(-60), now: now),
                   "a minute ago is the case this exists for")
            expect(ScreenCarry.isStillValid(capturedAt: now.addingTimeInterval(-14 * 60), now: now))
            expect(!ScreenCarry.isStillValid(capturedAt: now.addingTimeInterval(-20 * 60), now: now),
                   "after a quarter hour he has moved on, and a stale picture answers confidently wrong")
            expectEqual(ScreenCarry.validFor, ChatGrouping.gapSeconds,
                        "one window for a thread and another for its screen is two truths")
        }

        test("the carried image says what it is, and how old") {
            let label = ScreenCarry.label(age: 42, previous: "read and understand this problem")
            expect(label.contains("42s ago"), "the model has to know which screen is the past: \(label)")
            expect(label.contains("read and understand this problem"),
                   "and what he asked when it was up")
            expect(label.contains("may no longer be visible"),
                   "otherwise two screens in one request read as a bug, not as history")
            // The safety half: aims resolve against the live captures only, so a coordinate read off
            // the carried picture would press something on a screen that has since changed.
            expect(label.contains("NEVER aim at this picture"),
                   "an earlier screen offered as an answer source is also an aim target unless "
                     + "the label says otherwise: \(label)")
        }
    }
}
