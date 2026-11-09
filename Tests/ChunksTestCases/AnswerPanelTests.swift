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

        // AUDIT.md B-03: a failover after a mid-stream drop must replace the half reply. The panel
        // assigns what the streamer reports, so reset is what keeps two models off one card.
        test("reset forgets the half reply so the next model starts from an empty card") {
            let streamer = AnswerStreamer()
            streamer.push("<SAY>half a sentence from the first model</SAY> [ACT:100,200:Send]")
            streamer.reset()
            expect(streamer.speech.isEmpty && streamer.detail.isEmpty,
                   "reset left the first model's words on the card")
            expect(streamer.actionRequests.isEmpty,
                   "reset left the first model's act request in the plan")
            streamer.push("<SAY>the whole answer from the second model</SAY>")
            streamer.finish()
            expectEqual(streamer.speech, "the whole answer from the second model",
                        "the second model appended to the first instead of replacing it")
            expect(streamer.actionRequests.isEmpty,
                   "the dropped model's press must not run as part of the new reply")
        }

        // Measured 2026-11-07 on his machine: "Open WhatsApp and search for any new messages" was
        // served by the local brain ending `… [DO:open_app:WhatsApp] … [CONTINUE>` — square open,
        // angle close, no closing tag. The old parser released it as prose, the card showed raw
        // markup, and the second round never ran: WhatsApp sat open with nothing searched.
        test("the bracket-shaped CONTINUE a small model writes still carries the round") {
            let streamer = AnswerStreamer()
            streamer.push("<SAY>opening whatsapp now.</SAY> [DO:open_app:WhatsApp] "
                + "<DONE_TITLE>Found app open</DONE_TITLE> [CONTINUE>")
            let result = streamer.finish()
            expectEqual(streamer.continuation, "",
                        "an empty body is 'carry on with what he asked', not 'the turn is finished'")
            expect(streamer.endedMidConstruct,
                   "a reply that stopped inside its own instruction must say so in the log")
            expect(!result.detail.contains("CONTINUE"),
                   "the instruction leaked onto the card as prose: \(result.detail)")
            expectEqual(streamer.toolRequests.count, 1,
                        "the launch before the malformed tag must still parse")
        }

        test("a closed bracket CONTINUE is consumed while streaming, not at flush") {
            let streamer = AnswerStreamer()
            streamer.push("[CONTINUE>search for new messages] and that is all")
            let result = streamer.finish()
            expectEqual(streamer.continuation, "search for new messages",
                        "the hybrid bracket shape must carry the same sentence as the taught one")
            expect(!result.detail.contains("CONTINUE"),
                   "the tag leaked: \(result.detail)")
            expect(result.detail.contains("and that is all"),
                   "prose after a closed tag is still his answer")
        }

        test("a square-bracket CONTINUE does not keep its own closing tag in the sentence") {
            let streamer = AnswerStreamer()
            streamer.push("[CONTINUE]search for new messages[/CONTINUE]")
            streamer.finish()
            expectEqual(streamer.continuation, "search for new messages",
                        "the first ] is inside the closing tag; the markup is not the sentence")
        }

        test("an unclosed taught CONTINUE keeps the words it had") {
            let streamer = AnswerStreamer()
            streamer.push("<SAY>one moment.</SAY> <CONTINUE>search the chat list for unread messages")
            let result = streamer.finish()
            expectEqual(streamer.continuation, "search the chat list for unread messages",
                        "the stream stopped mid-instruction; the instruction is still the instruction")
            expect(!result.detail.contains("CONTINUE"),
                   "raw markup on the card: \(result.detail)")
        }

        test("prose before an unclosed CONTINUE stays on the card, the tag does not") {
            let streamer = AnswerStreamer()
            streamer.push("the window is open now\n[CONTINUE>")
            let result = streamer.finish()
            expect(result.detail.contains("the window is open now"),
                   "his answer must not vanish with the tag: \(result.detail)")
            expectEqual(streamer.continuation, "",
                        "the empty body still asks for the next look")
        }

        test("an empty taught CONTINUE is a carry-on, not an absent one") {
            let streamer = AnswerStreamer()
            streamer.push("<CONTINUE></CONTINUE>")
            streamer.finish()
            expectEqual(streamer.continuation, "",
                        "nil here would end the turn at the launch, which is the bug being fixed")
        }

        test("READ puts a file request on the streamer and stays off the card") {
            let streamer = AnswerStreamer()
            streamer.push("<SAY>let me look at that log.</SAY> "
                + "[READ:~/Downloads/build.log|why did it fail]")
            let result = streamer.finish()
            expectEqual(streamer.fileRead?.path, "~/Downloads/build.log",
                        "the file he asked about has to survive to the reader")
            expectEqual(streamer.fileRead?.question, "why did it fail")
            expect(!result.detail.contains("READ:"),
                   "the tag leaked onto the card the user reads: \(result.detail)")
        }

        test("a malformed READ is shown as text rather than swallowed") {
            let streamer = AnswerStreamer()
            streamer.push("[READ:]")
            let result = streamer.finish()
            expect(streamer.fileRead == nil, "an empty path must not become a read request")
            expect(result.detail.contains("[READ:]"),
                   "fail open: the user should see what was asked, not silence: \(result.detail)")
        }

        test("an unterminated tag at the end of the stream is still shown") {
            // The property this case was written for is *nothing is swallowed*, and it still holds —
            // but where the words go changed. Released as text, an unfinished `<SAY>` put markup on the
            // card and left `speech` empty, and a turn with an empty sentence is not spoken at all: on
            // 2026-11-04 at 15:00 that was "it was loading for a while and not even speaking a word".
            // So the words of an unclosed SAY are now speech, the markup is not shown, and the turn
            // records that the reply was cut. A malformed `[ACT:]` still fails open as raw text — that
            // one is a broken request the user has to see, and this is not a licence to hide those.
            let streamer = AnswerStreamer()
            streamer.push("The answer is 42.")
            streamer.push("<SAY>never finished")
            let result = streamer.finish()
            expect(result.detail.contains("The answer is 42."),
                   "the answer that arrived before the tag must survive: \(result.detail)")
            expect(result.speech.contains("never finished"),
                   "and the unfinished sentence must survive as the words they are, not vanish: "
                   + "\(result.speech)")
            expect(!result.detail.contains("<SAY>"),
                   "the markup itself is not content he asked for: \(result.detail)")
            expect(streamer.endedMidConstruct,
                   "the truncation is recorded rather than silently repaired")
        }

        // Photographed on the five-turn probe: "scrolling down to find the invoice now" with no
        // `[SCROLL:]` behind it — a promise the user can hear and the machine will never keep.
        // The streamer replaces it with one honest line, and only when no request exists.
        test("a spoken promise with no request behind it is retracted, not spoken") {
            let liar = AnswerStreamer()
            liar.push("<SAY>scrolling down to find the invoice now.</SAY>")
            liar.finish()
            expect(liar.retractUnbackedPromises(),
                   "a scroll promise with no [SCROLL:] must not reach the voice")
            expectEqual(liar.displayable.speech, AnswerStreamer.retractionLine,
                        "the retraction says what is true: nothing on screen answered to it")

            let honest = AnswerStreamer()
            honest.push("<SAY>scrolling down the list now.</SAY>[SCROLL:10,20:list|down]")
            honest.finish()
            expect(!honest.retractUnbackedPromises(),
                   "a promise backed by a request is a normal turn and must survive untouched")

            let teacher = AnswerStreamer()
            teacher.push("<SAY>scrolling down a list is just the browser moving rows "
                       + "off the top — nothing is typed or clicked.</SAY>")
            teacher.finish()
            expect(!teacher.retractUnbackedPromises(),
                   "an explanation of scrolling is not a promise to scroll")
        }

        // The notebook's turn of the same rule, measured on 2026-11-02 the day the tier shipped: asked
        // to "note that the landlord is Sharma", a local model said *"i have noted that the landlord
        // is sharma"* and emitted no `<NOTE>`. A memory promise costs more than an act promise — an act
        // that did not happen changes nothing, a note that did not happen is simply not there when he
        // looks for it next month, with nothing on record saying it ever was.
        test("a promise to keep a note with no <NOTE> behind it is retracted, in notebook words") {
            let liar = AnswerStreamer()
            liar.push("<SAY>i have noted that the landlord is Sharma.</SAY>")
            liar.push("<SUMMARY>The note has been recorded.</SUMMARY>")
            liar.finish()
            expect(liar.retractUnbackedPromises(),
                   "a kept-note promise with no <NOTE> must not reach the voice as a success")
            expectEqual(liar.displayable.speech, AnswerStreamer.noteRetractionLine,
                   "and the line must be about the notebook, not the screen — the screen line would "
                   + "send him looking for a window that was never the problem")

            let backed = AnswerStreamer()
            backed.push("<SAY>i have noted that the landlord is Sharma.</SAY>")
            backed.push("<NOTE>the landlord is Sharma</NOTE>")
            backed.finish()
            expect(!backed.retractUnbackedPromises(),
                   "a promise with the tag behind it is a normal turn")
            expectEqual(backed.noteLines, ["the landlord is Sharma"],
                        "and the note is what the store receives")
        }

        test("reporting that he noted something is not a promise, and survives") {
            // The false-positive trap: "noted that" on its own matches a sentence about *him*, and
            // retracting that would tell him Chunks failed to save something he never asked it to
            // save. The patterns are first-person promises only.
            let reporter = AnswerStreamer()
            reporter.push("<SAY>he noted that the wifi is slow at night, in the group chat.</SAY>")
            reporter.finish()
            expect(!reporter.retractUnbackedPromises(),
                   "an account of what he said is not a claim that Chunks kept a note")
        }

        test("a NOTE split across deltas is joined into one note, not three text events") {
            // The shape that made this tag dangerous when it had no consumer: the streamer holds back
            // anything that might still grow, so `<NO` + `TE>…` must resolve to one line. Now that the
            // Notebook exists, resolving *is* the requirement — a note that reaches the card as markup
            // is a thing he asked to be kept and was not.
            let streamer = AnswerStreamer()
            streamer.push("<SAY>The answer is 42.</SAY><NO")
            streamer.push("TE>The landlord is Sharma</NO")
            streamer.push("TE>")
            let result = streamer.finish()
            expectEqual(result.speech, "The answer is 42.", "the spoken line is untouched by the tag")
            expectEqual(streamer.noteLines, ["The landlord is Sharma"],
                        "the whole note arrives, assembled across three deltas")
            expect(!result.detail.contains("<NOTE>"),
                   "and its markup is not left on the card: \(result.detail)")
        }

        test("a draft is collected apart from the answer, and the last one owns the button") {
            let streamer = AnswerStreamer()
            streamer.push("<SAY>Here — short enough to send as is.</SAY>")
            streamer.push("<DRAFT>On my way, save me a seat.</DRAFT>")
            streamer.finish()
            expectEqual(streamer.draftText, "On my way, save me a seat.",
                        "the drafted words must survive intact for the Copy button")
            let display = streamer.displayable
            expect(!display.speech.contains("save me a seat")
                    && !display.detail.contains("save me a seat"),
                   "the draft leaked into the prose: \(display.detail)")
            // A reply that drafts twice is correcting itself, and one button can only copy one thing.
            let twice = AnswerStreamer()
            twice.push("<DRAFT>first version</DRAFT>")
            twice.push("<DRAFT>second version</DRAFT>")
            twice.finish()
            expectEqual(twice.draftText, "second version", "the wrong half of the reply owns the button")
            expect(twice.hasAnything,
                   "a reply that is only a draft is still an answer, and must not read as nothing")
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
        test("a drafted message reserves its padded well and Copy at the 360pt HUD width") {
            // Long enough to clear `minimumHeight`: a clamped floor would swallow part of the delta
            // and the assertion below would fail for the wrong reason.
            let answer = String(repeating: "A sentence of answer that wraps. ", count: 4)
            let without = AnswerPanelLayout.measure(speech: answer, detail: "", pointCount: 0, width: 360)
            let with = AnswerPanelLayout.measure(speech: answer, detail: "", pointCount: 0,
                                                 hasDraft: true, width: 360)
            expect(without > AnswerPanelLayout.minimumHeight,
                   "the base card is at the clamped floor, so this delta proves nothing")
            expect(with < AnswerPanelLayout.maximumHeight,
                   "the drafted card hit the ceiling, so the delta below is not the block's own height")
            expectEqual(with - without, AnswerPanelLayout.sectionGap + AnswerPanelLayout.draftHeight,
                        "the measurement and the card disagree about what a draft costs, which is how "
                            + "a Copy button ends up below the bottom of the window")
            expectEqual(AnswerPanelLayout.draftWellHeight, CGFloat(68),
                        "the 56pt viewport has 6pt of padding on both sides, not inside its frame")
            expectEqual(AnswerPanelLayout.draftHeight, CGFloat(102),
                        "the old 90pt allowance lost 12pt of well padding and stole room from Copy")
        }

        test("a draft and a question each reserve their space at the 360pt HUD width") {
            let answer = String(repeating: "A sentence of answer that wraps. ", count: 4)
            let base = AnswerPanelLayout.measure(speech: answer, detail: "", pointCount: 0,
                                                 confirmation: .question, width: 360)
            let both = AnswerPanelLayout.measure(speech: answer, detail: "", pointCount: 0,
                                                 hasDraft: true, confirmation: .question, width: 360)
            expect(base > AnswerPanelLayout.minimumHeight, "the base is at the floor, so read nothing here")
            expect(both < AnswerPanelLayout.maximumHeight, "the pair hit the ceiling")
            expectEqual(both - base, AnswerPanelLayout.sectionGap + AnswerPanelLayout.draftHeight,
                        "the ask row and the draft block must be counted apart, or one of them is "
                            + "drawn where the window has no room for it")
        }

        test("a real 340-character draft survives parsing and fits beside consent at 360pt") {
            let draft = """
            Hi Dad — Thursday at seven works for me. I'll bring the photos from last month so we can look \
            through them after dinner. Please let me know if you'd like me to pick up anything on the way. \
            I may be ten minutes late if the train is delayed, but I'll send you a quick update before I \
            leave. Looking forward to catching up with you both again.
            """
            expectEqual(draft.count, 340, "the fixture must really reach the limit, not just claim it")
            expectEqual(draft.count, ResponseParser.maxDraftCharacters)
            let streamer = AnswerStreamer()
            streamer.push("<SAY>Here is your reply.</SAY><DRAFT>\(draft)</DRAFT>")
            let display = streamer.finish()
            expectEqual(streamer.draftText, draft, "Copy must receive every character, including the last line")
            expectEqual(display.detail, "", "draft text belongs in its scrollable well, not the answer body")
            let question = "write him a reply about Thursday"
            let alone = AnswerPanelLayout.measure(speech: display.speech, detail: display.detail,
                pointCount: 0, hasDraft: streamer.draftText != nil, question: question, width: 360)
            let withConsent = AnswerPanelLayout.measure(speech: display.speech, detail: display.detail,
                pointCount: 0, hasDraft: streamer.draftText != nil, confirmation: .question,
                question: question, width: 360)
            expectEqual(alone, CGFloat(196), "stage, question, answer, padded well and Copy must all be counted")
            expectEqual(withConsent, CGFloat(314),
                        "consent needs its own 118pt — the well, its ordinal, the question and the "
                        + "two targets; it cannot borrow Copy's space")
            expect(withConsent < AnswerPanelLayout.maximumHeight,
                   "the fixture must not hide missing space behind the card's ceiling")
            let textWidth = CGFloat(360) - 2 * AnswerPanelLayout.inset
                - 2 * AnswerPanelLayout.draftTextHorizontalInset
            let textHeight = AnswerPanelLayout.lines(draft, font: NSFont.systemFont(ofSize: 11),
                lineHeight: 14, width: textWidth) * 14
            expect(textHeight > AnswerPanelLayout.draftTextHeight,
                   "this fixture must need scrolling; the native render probe checks that it actually scrolls")
        }

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

        // The outcome of a press is a timeline row, and the card pays for it once. `.result` used to
        // reserve a whole question block for a line that the timeline already counted, so a card that
        // had just answered a question carried 64 pt of empty space above its chips.
        test("what a press did is counted with the timeline, not as a second block") {
            let speech = String(repeating: "a fairly long spoken answer. ", count: 12)
            let width = AnswerPanelLayout.defaultWidth - 2 * AnswerPanelLayout.inset
            let base = AnswerPanelLayout.measure(speech: speech, detail: "", pointCount: 0)
            let withOutcome = AnswerPanelLayout.measure(speech: speech, detail: "", pointCount: 0,
                                                        timelineTexts: ["Pressed Search."],
                                                        timelineTotal: 1)
            expectEqual(withOutcome - base,
                        AnswerPanelLayout.timelineHeight(rows: ["Pressed Search."], folded: false,
                                                         width: width),
                        "one outcome line must cost exactly the row the view draws")
            let asking = AnswerPanelLayout.measure(speech: speech, detail: "", pointCount: 0,
                                                   confirmation: .question)
            expect(withOutcome < asking,
                   "a question is taller than the line that replaced it")
        }

        // The row a refusal writes is the one he has to read: it names the fields the app actually
        // publishes, and that list sits at the end of the sentence. One middle-truncated line showed
        // "Chunks found no field calle…earch" — neither half — so the row earns a second line and
        // the card pays for it in the same arithmetic the view draws from.
        test("a refusal that names the fields gets two lines, measured and drawn alike") {
            let width = AnswerPanelLayout.defaultWidth - 2 * AnswerPanelLayout.inset
            let refusal = "Chunks found no field called \"Message box\". The only fields Chunks "
                + "can see in WhatsApp: \"Search\", \"Compose message\"."
            expect(AnswerPanelLayout.timelineRowCount(for: refusal, width: width) == 2,
                   "the field list at the end of a refusal must not vanish into an ellipsis")
            expect(AnswerPanelLayout.timelineRowCount(for: "Pressed Search.", width: width) == 1,
                   "an ordinary outcome still costs one line")
            expectEqual(AnswerPanelLayout.timelineHeight(rows: [refusal], folded: false, width: width),
                        AnswerPanelLayout.timelineGap + 2 * AnswerPanelLayout.timelineRowHeight,
                        "the card must pay for both lines the view draws")
        }

        test("a long spoken answer is bounded so the Ask row stays on the card") {
            let enormous = String(repeating: "A very long explanation sentence. ", count: 400)
            let bounded = AnswerPanelLayout.boundedDetail(
                enormous, budget: AnswerPanelLayout.speechCharacterBudget)
            expect(bounded.count <= AnswerPanelLayout.speechCharacterBudget + 1,
                   "the card shows more speech than it was allowed: \(bounded.count)")
            expect(bounded.hasSuffix("…"), "a clipped answer has to say so")

            let unbounded = AnswerPanelLayout.measure(speech: enormous, detail: "", pointCount: 2,
                                                      confirmation: .question,
                                                      question: "Press Send in Mail?")
            let clamped = AnswerPanelLayout.measure(speech: bounded, detail: "", pointCount: 2,
                                                    confirmation: .question,
                                                    question: "Press Send in Mail?")
            expect(unbounded >= AnswerPanelLayout.maximumHeight,
                   "the fixture is not the bug this test guards: \(unbounded)")
            expect(clamped < AnswerPanelLayout.maximumHeight,
                   "an unclamped speech line pushed the Allow row below the window: \(clamped)")
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
                        2 * AnswerPanelLayout.confirmWellInset + AnswerPanelLayout.confirmOrdinalHeight
                        + AnswerPanelLayout.confirmOrdinalGap + AnswerPanelLayout.confirmQuestionHeight
                        + AnswerPanelLayout.confirmGap + AnswerPanelLayout.confirmButtonRowHeight,
                        "the measured block must be the sum of the rows the view draws")
            // The ordinal is drawn, so it must be paid for. A pending step labelled above a question
            // the window was sized without is a question whose tap lands in the cutout.
            expect(AnswerPanelLayout.confirmHeight > AnswerPanelLayout.confirmQuestionHeight
                    + AnswerPanelLayout.confirmGap + AnswerPanelLayout.confirmButtonRowHeight,
                   "the ask block reserves no room for the well and its ordinal")
        }

        test("a failed card reserves its one way back") {
            // Long enough to clear the floor: a one-line card is clamped to the minimum height, and a
            // clamped base would make the delta a lie about the row rather than about the arithmetic.
            let failure = "Chunks could not reach the model. The reply was going to be about the "
                + "chart in your spreadsheet, and everything it would have said about the totals "
                + "never arrived."
            let without = AnswerPanelLayout.measure(speech: failure, detail: "", pointCount: 0)
            let withRetry = AnswerPanelLayout.measure(speech: failure, detail: "", pointCount: 0,
                                                      hasRetry: true)
            expect(without > AnswerPanelLayout.minimumHeight,
                   "the fixture sits on the floor, so the delta would not be the row's own height")
            expectEqual(withRetry - without,
                        AnswerPanelLayout.sectionGap + AnswerPanelLayout.retryRowHeight,
                        "the retry row must be paid for exactly once, at its own height")
            // A control the window was not sized for is a control he cannot tap, and the
            // "Ask again" row is the whole recovery — a failed card without it names the problem
            // and offers nothing.
            expect(AnswerPanelLayout.retryRowHeight >= 26,
                   "the retry target is too small to tap safely")
        }
    }
}
