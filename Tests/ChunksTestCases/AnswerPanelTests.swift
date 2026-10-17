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

        // MARK: Result protocol through the streamer

        test("SUMMARY, DONE_TITLE and NEXT_ACTIONS are all resolved by the streamer") {
            let streamer = AnswerStreamer()
            streamer.push("The icons are saved beside the page.\n")
            streamer.push("<SUMMARY>Your welcome page is ready.</SUMMARY>")
            streamer.push("<DONE_TITLE>Welcome Page</DONE_TITLE>")
            streamer.push("<NEXT_ACTIONS>\n- Add a dark theme\n</NEXT_ACTIONS>")
            let result = streamer.finish()
            expectEqual(streamer.summary, "Your welcome page is ready.")
            expectEqual(streamer.doneTitle, "Welcome Page")
            expectEqual(streamer.nextActions, ["Add a dark theme"])
            expectEqual(result.detail.trimmingCharacters(in: .whitespacesAndNewlines),
                        "The icons are saved beside the page.",
                        "result tags must not become transcript text: \(result.detail)")
        }

        test("SUMMARY wins the utterance over SAY, and SAY is the fallback") {
            // Two models, one UI: a model that closes with SUMMARY should be heard saying
            // that line, not the three sentences of narration it emitted while working.
            let withSummary = AnswerStreamer()
            withSummary.push("<SAY>Let me look. Building now.</SAY>")
            withSummary.push("<SUMMARY>The page is ready.</SUMMARY>")
            withSummary.finish()
            expectEqual(withSummary.utterance, "The page is ready.")

            let withoutSummary = AnswerStreamer()
            withoutSummary.push("<SAY>The page is ready.</SAY>")
            withoutSummary.finish()
            expectEqual(withoutSummary.utterance, "The page is ready.",
                        "a reply with no SUMMARY must still be spoken aloud")
        }

        test("a reply that ignores every tag is still spoken") {
            // The pipeline speaks `utterance`. If a model answers in plain prose, that prose
            // parses to detail only — and returning "" here would leave the user hearing
            // nothing while a card full of text sits on screen.
            let streamer = AnswerStreamer()
            streamer.push("The run button is in the toolbar, top left.")
            streamer.finish()
            expectEqual(streamer.utterance, "The run button is in the toolbar, top left.")
        }

        test("a second NEXT_ACTIONS block replaces the chips instead of doubling them") {
            let streamer = AnswerStreamer()
            streamer.push("<NEXT_ACTIONS>\n- First\n</NEXT_ACTIONS>")
            streamer.push("<NEXT_ACTIONS>\n- Second\n- Third\n</NEXT_ACTIONS>")
            streamer.finish()
            expectEqual(streamer.nextActions, ["Second", "Third"])
        }

        // "Open WhatsApp, search for Dad, message him HI" cannot be aimed at one screenshot: the
        // search box does not exist until the app is open. `<CONTINUE>` is how the model hands the
        // rest to the next look, and the tag is an instruction to the app — never content.
        test("CONTINUE carries the rest of a plan to the next look, and is never shown") {
            let streamer = AnswerStreamer()
            streamer.push("<SAY>opening whatsapp.</SAY> [DO:open_app:WhatsApp] "
                + "<CONTINUE>search for Dad, then type HI and press send</CONTINUE>")
            let result = streamer.finish()
            expectEqual(streamer.continuation, "search for Dad, then type HI and press send",
                        "a plan the user has to say twice is not a plan")
            expect(!result.detail.contains("CONTINUE"),
                   "the tag leaked onto the card the user reads: \(result.detail)")
            expect(!streamer.utterance.contains("CONTINUE"),
                   "the tag would be spoken aloud: \(streamer.utterance)")
        }

        // `<NEXT>` would be a prefix of `<NEXT_ACTIONS>`, and whichever construct is tried first
        // would eat the other. This is the test that keeps that mistake out of a rename.
        test("CONTINUE and NEXT_ACTIONS survive the same reply without eating each other") {
            let streamer = AnswerStreamer()
            streamer.push("<NEXT_ACTIONS>\n- press send\n</NEXT_ACTIONS>")
            streamer.push("<CONTINUE>press send in the chat window</CONTINUE>")
            streamer.finish()
            expectEqual(streamer.nextActions, ["press send"],
                        "the chip was eaten by the continuation tag")
            expectEqual(streamer.continuation, "press send in the chat window",
                        "the continuation was eaten by the chip tag")
        }

        test("a reply with no CONTINUE asks for no further look") {
            let streamer = AnswerStreamer()
            streamer.push("<SAY>done.</SAY> <DONE_TITLE>Finished</DONE_TITLE> [POINT:none]")
            streamer.finish()
            expect(streamer.continuation == nil,
                   "an absent tag must not schedule another turn and burn a plan round")
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

        test("next-action chips share the point chips' stack, including its one gap") {
            // Measured as deltas between chip counts, not against the chipless card: a
            // one-word answer is clamped up to `minimumHeight`, so its raw height is not
            // the number the arithmetic says and a difference from zero hides that.
            let oneAction = AnswerPanelLayout.measure(speech: "Here.", detail: "",
                                                      pointCount: 0, actionCount: 1)
            let twoActions = AnswerPanelLayout.measure(speech: "Here.", detail: "",
                                                       pointCount: 0, actionCount: 2)
            let mixed = AnswerPanelLayout.measure(speech: "Here.", detail: "",
                                                  pointCount: 1, actionCount: 2)
            expect(oneAction > AnswerPanelLayout.minimumHeight,
                   "a chip row must clear the clamped floor or the next assertion proves nothing")
            expectEqual(twoActions - oneAction, AnswerPanelLayout.chipHeight,
                        "each action chip must reserve its own row, not overlap the answer")
            expectEqual(mixed - twoActions, AnswerPanelLayout.chipHeight,
                        "points and actions are one stack: adding a point adds a row, not a row plus a second gap")
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

        TestRunner.currentSuite = "Answer panel detail bounding"

        // A live run produced a 195pt wall of small bulleted type that pushed the point
        // chips to the very bottom of the card and made the whole thing hard to read. The
        // spoken answer already carried the headline, so a bounded summary beats a
        // half-readable list.
        test("a very long detail is bounded and marked as truncated") {
            let long = String(repeating: "- A bullet point with some detail in it. ", count: 30)
            let bounded = AnswerPanelLayout.boundedDetail(long)
            expect(bounded.count < long.count, "detail was not bounded: \(bounded.count) chars")
            expect(bounded.hasSuffix("…"), "truncation must be visible, not silent: \(bounded.suffix(20))")
        }

        test("short detail is left alone") {
            let short = "Just one line."
            expectEqual(AnswerPanelLayout.boundedDetail(short), short)
        }

        test("bounding detail keeps the card inside its maximum") {
            let long = String(repeating: "Detail text that goes on. ", count: 200)
            let bounded = AnswerPanelLayout.boundedDetail(long)
            let height = AnswerPanelLayout.measure(
                speech: "A headline.", detail: bounded, pointCount: 2)
            expect(height <= AnswerPanelLayout.maximumHeight,
                   "a bounded card must still fit: \(height)")
        }

        test("truncation prefers a line boundary over a mid-sentence cut") {
            let line = String(repeating: "A line of detail. ", count: 12)   // ~204 chars
            let bounded = AnswerPanelLayout.boundedDetail(line + "\n" + String(repeating: "x", count: 400))
            expect(bounded.hasSuffix("…"))
            expect(!bounded.contains("xx"),
                   "a whole-line cut was expected, got a slice: \(bounded.suffix(40))")
        }

        // MARK: Live caption for the user's own voice

        // The notch pill is one line of 12pt type at the HUD width. A caption longer than
        // that wraps, and a wrapped pill is a second card appearing mid-sentence — the one
        // surface that must stay glanceable while the user is still talking.
        test("a caption is bounded to one pill line") {
            let spoken = "can you tell me what this error in the xcode console means and how I should fix it"
            let bounded = AnswerPanelLayout.boundedDetail(spoken,
                                                          budget: AnswerPanelLayout.captionCharacterBudget)
            expect(bounded.count <= AnswerPanelLayout.captionCharacterBudget + 1,
                   "caption overflows the pill: \(bounded.count) chars — \(bounded)")
            expect(bounded.hasSuffix("…"), "the cut must be visible: \(bounded)")
        }

        test("the caption budget stays smaller than the card's detail budget") {
            expect(AnswerPanelLayout.captionCharacterBudget < AnswerPanelLayout.detailCharacterBudget,
                   "the pill is narrower than the card; a caption budget that outgrows the card's "
                     + "means someone raised the wrong number")
        }

        test("a short caption is shown whole") {
            let spoken = "what is this button"
            expectEqual(AnswerPanelLayout.boundedDetail(spoken,
                                                       budget: AnswerPanelLayout.captionCharacterBudget),
                        spoken, "a question that fits must not be elided")
        }

        // MARK: The press question row

        test("a pending press question makes the card exactly one question block taller") {
            // Tall enough that neither measurement is sitting on `minimumHeight`: the clamp
            // would absorb the growth and the assertion would pass or fail on the floor value
            // instead of on the row.
            let speech = String(repeating: "a fairly long spoken answer. ", count: 12)
            let base = AnswerPanelLayout.measure(speech: speech, detail: "", pointCount: 0)
            let asking = AnswerPanelLayout.measure(speech: speech, detail: "", pointCount: 0,
                                                   confirmation: .question)
            expect(asking > AnswerPanelLayout.minimumHeight + 20,
                   "the fixture is clamped, so it proves nothing: \(asking)")
            expectEqual(asking - base,
                        AnswerPanelLayout.sectionGap + AnswerPanelLayout.confirmHeight,
                        "the card must grow by the row the view actually draws, not an estimate")
        }

        test("the answer line after a press is shorter than the question it replaces") {
            let speech = String(repeating: "a fairly long spoken answer. ", count: 12)
            let asking = AnswerPanelLayout.measure(speech: speech, detail: "", pointCount: 0,
                                                   confirmation: .question)
            let answered = AnswerPanelLayout.measure(speech: speech, detail: "", pointCount: 0,
                                                     confirmation: .result)
            expect(answered < asking,
                   "a one-line result must not keep the buttons' height or the card has dead space")
            let base = AnswerPanelLayout.measure(speech: speech, detail: "", pointCount: 0)
            expectEqual(answered - base,
                        AnswerPanelLayout.sectionGap + AnswerPanelLayout.confirmQuestionHeight,
                        "the result row is one measured line")
        }

        test("a question cannot push the card past its maximum") {
            let long = String(repeating: "a fairly long spoken answer. ", count: 60)
            let height = AnswerPanelLayout.measure(speech: long, detail: long, pointCount: 3,
                                                   actionCount: 3,
                                                   confirmation: .question)
            expect(height <= AnswerPanelLayout.maximumHeight,
                   "the confirm buttons would be drawn below the window and unclickable: \(height)")
        }

        test("the question block is tall enough for two real buttons") {
            // 28 pt is the smallest tap that is not a mis-tap risk on a card this dense, and
            // the row it lives in is the one thing the user must be able to hit deliberately.
            expect(AnswerPanelLayout.confirmButtonRowHeight >= 26,
                   "the Allow / Not now targets are too small to tap safely")
            expectEqual(AnswerPanelLayout.confirmHeight,
                        AnswerPanelLayout.confirmQuestionHeight + AnswerPanelLayout.confirmGap
                        + AnswerPanelLayout.confirmButtonRowHeight,
                        "the measured block must be the sum of the rows the view draws")
        }
    }
}
