import AppKit
import ChunksTestHarness
@testable import ChunksKit

/// Tests for the two pieces of the answer panel that are pure enough to test without a
/// display: the streaming splitter and the card's sizing arithmetic.
///
/// The panel itself is a view and can only be verified by looking at it. These are the
/// parts where getting it wrong produces a *plausible* panel — one that shows the right
/// words in the wrong place, or the wrong words in the right place — rather than a crash.
public enum AnswerPanelTests {

    public static func register() {
        TestRunner.currentSuite = "Answer streaming"

        // MARK: Splitting speech from detail

        test("speech and detail are separated, not concatenated") {
            let streamer = AnswerStreamer()
            streamer.push("<SAY>This is Xcode's debug navigator.</SAY>")
            streamer.push("The three panes show call stack, variables and breakpoints.")
            let result = streamer.finish()
            expectEqual(result.speech, "This is Xcode's debug navigator.")
            expectEqual(result.detail, "The three panes show call stack, variables and breakpoints.")
        }

        test("a reply with no SAY tag is all detail and nothing is spoken") {
            let streamer = AnswerStreamer()
            streamer.push("Just plain prose, no tags at all.")
            let result = streamer.finish()
            expectEqual(result.speech, "", "nothing was marked for speech")
            expectEqual(result.detail, "Just plain prose, no tags at all.")
        }

        test("streaming text never shows raw tag markup") {
            // The failure this guards: mid-stream the user sees "<SAY>That is the" with
            // the tag still on screen. It looks like a rendering bug and destroys trust in
            // every other character the panel shows.
            let deltas = ["<SA", "Y>This is t", "he Debug Nav", "igator.</SA", "Y> and a list:", " locals, breakpoints"]
            let streamer = AnswerStreamer()
            for (index, delta) in deltas.enumerated() {
                let partial = streamer.push(delta)
                for (label, text) in [("speech", partial.speech), ("detail", partial.detail)] {
                    expect(!text.contains("<"), "raw tag leaked into \(label) after delta \(index): \(text)")
                    expect(!text.contains(">"), "raw tag leaked into \(label) after delta \(index): \(text)")
                }
            }
        }

        // The property that matters: how the reply is cut into deltas must not change the
        // answer. A parser that behaves differently on one-character deltas is a parser
        // that will be wrong against real SSE framing, which is not character-aligned.
        test("streamed text matches the batch parse, character by character") {
            let reply = "<SAY>That is the debug navigator.</SAY>\n"
                + "The left pane is the call stack.\n"
                + "[POINT:412,180,Run button]\n"

            let batch = AnswerStreamer()
            batch.push(reply)
            let expected = batch.finish()

            let perCharacter = AnswerStreamer()
            for character in reply { perCharacter.push(String(character)) }
            let actual = perCharacter.finish()

            expectEqual(actual.speech, expected.speech, "speech differed")
            expectEqual(actual.detail, expected.detail, "detail differed")
            expectEqual(actual.speech, "That is the debug navigator.")
            expectEqual(perCharacter.points.count, 1, "the point was lost in translation")
        }

        // The bug this caught: `ResponseParser` emits `<SAY>` content as both `.speech`
        // and `.text`, because what is spoken is also written to the transcript. Treating
        // every `.text` as detail therefore duplicated every spoken sentence.
        test("spoken words never appear twice, once as speech and once as detail") {
            let streamer = AnswerStreamer()
            streamer.push("<SAY>This is the debug navigator.</SAY>")
            streamer.push("It shows the call stack.")
            let result = streamer.finish()
            expect(!result.detail.contains("debug navigator"),
                   "the spoken sentence leaked into the detail pane: \(result.detail)")
            expect(!result.speech.contains("call stack"),
                   "shown text leaked into the speech: \(result.speech)")
        }

        test("a point streamed mid-reply is still collected") {
            let streamer = AnswerStreamer()
            streamer.push("Press [POINT:412,180,Run button] to build.")
            streamer.finish()
            expectEqual(streamer.points.count, 1)
            expectEqual(streamer.points.first?.label, "Run button")
        }

        test("a memory proposal arrives but never reaches the visible text") {
            let streamer = AnswerStreamer()
            streamer.push("<SAY>Noted.</SAY>")
            streamer.push(#"<MEMORY>{"add":[{"section":"You","fact":"Uses Swift"}],"prune":[]}</MEMORY>"#)
            let result = streamer.finish()
            expectEqual(result.speech, "Noted.")
            expectEqual(result.detail, "", "the memory block must not be shown to the user")
            expectEqual(streamer.proposal?.add.count, 1, "but it must be offered for writing")
        }

        test("an unterminated tag at the end of the stream is still shown") {
            let streamer = AnswerStreamer()
            streamer.push("The answer is 42.")
            streamer.push("<NOTE>save this")
            let result = streamer.finish()
            expect(result.detail.contains("42"), "the real answer must survive: \(result.detail)")
        }

        test("nothing shown means the streamer reports nothing") {
            let streamer = AnswerStreamer()
            expect(!streamer.hasAnything)
        }

        // A real reply is `<SAY>…</SAY>`, a blank line, then a `[POINT]`. The raw buffer
        // picks up those newlines, and the panel rendered them as empty lines of secondary
        // text under the answer.
        test("whitespace around the answer is trimmed for display") {
            let streamer = AnswerStreamer()
            streamer.push("\n<SAY>That's the back button.</SAY>\n\n")
            streamer.finish()
            let displayable = streamer.displayable
            expectEqual(displayable.speech, "That's the back button.")
            expectEqual(displayable.detail, "", "whitespace-only detail should render as nothing")
        }

        test("interior formatting in the detail is preserved") {
            let streamer = AnswerStreamer()
            streamer.push("\nFirst line.\nSecond line.\n")
            streamer.finish()
            let displayable = streamer.displayable
            expectEqual(displayable.detail, "First line.\nSecond line.",
                        "trimming the ends must not flatten interior structure")
        }

        // MARK: Card sizing

        TestRunner.currentSuite = "Answer panel sizing"

        test("a short answer gets a small card") {
            let height = AnswerPanelLayout.measure(speech: "That is the Run button.", detail: "", pointCount: 0)
            expect(height >= 96, "a one-line answer should hit the minimum: \(height)")
            expect(height < 140, "but should not be needlessly tall: \(height)")
        }

        test("a long answer grows the card") {
            let long = String(repeating: "This is a sentence of explanation. ", count: 12)
            let short = AnswerPanelLayout.measure(speech: "Short.", detail: "", pointCount: 0)
            let tall = AnswerPanelLayout.measure(speech: long, detail: "", pointCount: 0)
            expect(tall > short + 60, "a long answer must get more room: \(short) vs \(tall)")
        }

        // A clipped answer is worse than a tall card: the user cannot tell that text is
        // missing, they just read a truncated sentence.
        test("the card never grows past the maximum the panel allows") {
            let enormous = String(repeating: "A very long explanation sentence. ", count: 400)
            let height = AnswerPanelLayout.measure(speech: enormous, detail: enormous, pointCount: 8)
            expect(height <= 420, "the panel would clip this: \(height)")
        }

        test("points add exactly their own height") {
            let base = AnswerPanelLayout.measure(speech: "Here.", detail: "", pointCount: 0)
            let one = AnswerPanelLayout.measure(speech: "Here.", detail: "", pointCount: 1)
            let three = AnswerPanelLayout.measure(speech: "Here.", detail: "", pointCount: 3)
            expect(one > base, "one chip must add height")
            expect(three > one + AnswerPanelLayout.chipHeight,
                   "each extra chip must add a row: \(one) -> \(three)")
        }

        test("detail text adds height only when present") {
            // Long enough to clear the 96pt floor — otherwise both cases clamp to the
            // minimum and the comparison proves nothing.
            let speech = "A reasonably long headline that wraps onto more than one line of the card."
            let noDetail = AnswerPanelLayout.measure(speech: speech, detail: "", pointCount: 0)
            let withDetail = AnswerPanelLayout.measure(
                speech: speech,
                detail: "A list of several things, long enough to occupy a line or two of detail.",
                pointCount: 0)
            expect(withDetail > noDetail, "detail must be accounted for: \(noDetail) -> \(withDetail)")
        }

        test("an empty card is still visible enough to show a status line") {
            let height = AnswerPanelLayout.measure(speech: "", detail: "", pointCount: 0)
            expect(height >= 96, "a working card must have room for its status line: \(height)")
        }
    }
}
