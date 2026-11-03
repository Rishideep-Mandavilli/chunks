import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// Tests for the caption line — what Chunks shows at the bottom of the screen while it speaks.
///
/// The case that matters is the cut. A caption that truncates mid-word turns "I pressed the Send
/// button" into "I pressed the Send but…", which is a different sentence about an act on his machine,
/// and he has no way to tell the two apart. So the budget is spent at a word boundary, and the ellipsis
/// appears only when something really was dropped.
public enum CaptionLineTests {

    public static func register() {
        TestRunner.currentSuite = "Captions"

        test("a sentence that fits is shown whole") {
            let line = "The invoice is in your Downloads folder, dated 14 October."
            expectEqual(CaptionLine.shaped(line), line,
                        "nothing was left out, so nothing may be marked as left out")
        }

        test("nothing to say shows no caption") {
            expect(CaptionLine.shaped("") == nil, "an empty caption is a box that promises speech")
            expect(CaptionLine.shaped("   \n\t ") == nil,
                   "whitespace is not a sentence, and a row that appears and says nothing reads as "
                        + "it is about to speak")
        }

        test("a long reply is cut at a word, never through one") {
            let sentence = String(repeating: "word ", count: 60) + "lastly"
            guard let line = CaptionLine.shaped(sentence) else {
                expect(false, "a long sentence must still caption"); return
            }
            expect(line.count <= CaptionLine.maxCharacters + 1,
                   "the budget is the whole point of the rule: \(line.count)")
            expect(!line.contains("wor…"),
                   "a caption that cuts inside a word is a new word: \(line)")
            expect(line.hasSuffix("…"),
                   "and anything dropped has to be marked, or a partial read reads as a complete one")
        }

        test("a single long token is still shown, because half a word still says it is talking") {
            let path = String(repeating: "a", count: 300)
            guard let line = CaptionLine.shaped(path) else {
                expect(false, "no caption for a long token would leave the voice unsynchronised"); return
            }
            expect(line.hasSuffix("…"), "and it is marked as cut")
            expect(line.count == CaptionLine.maxCharacters + 1,
                   "the cut is at the budget, not at the first space that does not exist")
        }

        test("leading and trailing whitespace is not part of the caption") {
            expectEqual(CaptionLine.shaped("  Pressed Send.  "), "Pressed Send.",
                        "the transcript arrives padded, and a caption with stray spaces looks broken")
        }

        test("the budget is a real width, not a number that grew by accident") {
            // Two lines at 15 pt across 720 pt is roughly this many characters. If the surface changes
            // size, this is the line that has to change with it — which is the point of asserting it.
            expect(CaptionLine.maxCharacters == 156,
                   "the caption's budget drifted without a decision: \(CaptionLine.maxCharacters)")
            expect(CaptionLine.minTailCharacters == 40,
                   "below this a word-boundary cut throws away most of the budget")
        }

        test("a real spoken answer either fits or is cut cleanly") {
            // The shape a `<SUMMARY>` line actually arrives in, including the em dashes this app's own
            // answers use, which are punctuation but not spaces.
            let answer = "I opened the file, read the invoice, and found the total — ₹4,200, due on "
                + "14 October — which is later than the date on the purchase order you showed me "
                + "earlier in this conversation, so you may want to check it before you send it back"
            guard let line = CaptionLine.shaped(answer) else {
                expect(false, "an answer this long still needs a caption"); return
            }
            expect(line.hasSuffix("…") && line.count <= CaptionLine.maxCharacters + 1,
                   "cut at a boundary and marked: \(line)")
            expect(!line.contains("₹4,20…"),
                   "the money must not be cut mid-figure: \(line)")
        }
    }
}
