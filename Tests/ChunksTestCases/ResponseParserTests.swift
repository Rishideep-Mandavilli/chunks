import ChunksTestHarness
@testable import ChunksKit

public enum ResponseParserTests {

    static func feedAll(_ parser: ResponseParser, _ text: String) -> [ReplyEvent] {
        var out: [ReplyEvent] = []
        for ch in text { out += parser.feed(String(ch)) }
        return out
    }

    static func texts(_ events: [ReplyEvent]) -> String {
        events.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined()
    }
    static func speeches(_ events: [ReplyEvent]) -> String {
        events.compactMap { if case .speech(let s) = $0 { return s }; return nil }.joined(separator: "|")
    }
    static func points(_ events: [ReplyEvent]) -> [PointTarget] {
        events.compactMap { if case .point(let p) = $0 { return p }; return nil }
    }
    static func memory(_ events: [ReplyEvent]) -> MemoryProposal? {
        events.compactMap { if case .memory(let m) = $0 { return m }; return nil }.first
    }
    static func summaries(_ events: [ReplyEvent]) -> String? {
        events.compactMap { if case .summary(let s) = $0 { return s }; return nil }.first
    }
    static func titles(_ events: [ReplyEvent]) -> String? {
        events.compactMap { if case .doneTitle(let t) = $0 { return t }; return nil }.first
    }
    static func actions(_ events: [ReplyEvent]) -> [String] {
        events.compactMap { if case .nextActions(let a) = $0 { return a }; return nil }.first ?? []
    }

    public static func register() {
        TestRunner.currentSuite = "ResponseParser"

        // MARK: Plain text

        test("plain prose passes through as text") {
            let p = ResponseParser()
            let ev = p.feed("This is the Debug Navigator.") + p.finish()
            expectEqual(ResponseParserTests.texts(ev), "This is the Debug Navigator.")
        }

        test("feed() alone holds the prose back; finish() is what releases it") {
            // The tail could still grow into a tag, so nothing is final until the stream ends.
            // A caller that reads the accumulated answer before `finish()` sees an empty one —
            // which is how `chunks --self-test` reported "the reply parsed to nothing" against
            // a perfectly good sentence from the model.
            let p = ResponseParser()
            expect(p.feed("You are looking at a settings window.").isEmpty,
                   "an unflushed stream released text it might still have to hold back")
            let flushed = p.feed("") + p.finish()
            expectEqual(ResponseParserTests.texts(flushed), "You are looking at a settings window.",
                        "the held-back prose was never released")
        }

        test("empty input produces nothing") {
            let p = ResponseParser()
            expect(p.feed("").isEmpty)
            expect(p.finish().isEmpty)
        }

        // MARK: <SAY>

        test("<SAY> content is both spoken and shown") {
            let p = ResponseParser()
            let ev = p.feed("before <SAY>the run button is top left</SAY> after") + p.finish()
            expectEqual(ResponseParserTests.speeches(ev), "the run button is top left")
            expect(ResponseParserTests.texts(ev).contains("before"), "text before tag lost")
            expect(ResponseParserTests.texts(ev).contains("after"), "text after tag lost")
            expect(!ResponseParserTests.texts(ev).contains("<SAY>"), "tag leaked into visible text")
        }

        test("<SAY> spanning a line break works") {
            let p = ResponseParser()
            let ev = p.feed("<SAY>line one\nline two</SAY>") + p.finish()
            expectEqual(ResponseParserTests.speeches(ev), "line one\nline two")
        }

        // MARK: [POINT:…]

        test("parses the original Clicky POINT format") {
            let p = ResponseParser()
            let ev = p.feed("Look: [POINT:412,180,Run button:screen1]") + p.finish()
            let pts = ResponseParserTests.points(ev)
            expectEqual(pts.count, 1, "expected one point, got \(pts.count)")
            if let first = pts.first {
                expectEqual(first.x, 412)
                expectEqual(first.y, 180)
                expectEqual(first.label, "Run button")
                expectEqual(first.display, 1)
            }
        }

        test("display index is read from the screen suffix") {
            let p = ResponseParser()
            let ev = p.feed("[POINT:10,20:Save:screen2]") + p.finish()
            expectEqual(ResponseParserTests.points(ev).first?.display, 2)
        }

        test("label may contain commas and colons") {
            let p = ResponseParser()
            let ev = p.feed("[POINT:5,6:Save, then close: all files:screen1]") + p.finish()
            if let first = ResponseParserTests.points(ev).first {
                expectEqual(first.label, "Save, then close: all files")
                expectEqual(first.x, 5)
                expectEqual(first.y, 6)
            } else {
                expect(false, "no point parsed")
            }
        }

        test("multiple points in one reply") {
            let p = ResponseParser()
            let ev = p.feed("[POINT:1,2:A:screen1] and [POINT:3,4:B:screen1]") + p.finish()
            expectEqual(ResponseParserTests.points(ev).count, 2)
        }

        test("a malformed POINT is shown rather than silently dropped") {
            let p = ResponseParser()
            let ev = p.feed("[POINT:notanumber,20:Thing:screen1]") + p.finish()
            expect(ResponseParserTests.points(ev).isEmpty, "should not have parsed")
            expect(ResponseParserTests.texts(ev).contains("[POINT:"), "malformed tag was swallowed instead of shown")
        }

        test("[POINT:none] is understood, not shown and not pointed") {
            // The prompt tells the model to emit this when pointing would not help, so the
            // fail-open path would put "[POINT:none]" on the card and the cursor would fly
            // wherever a missing coordinate resolved to.
            let p = ResponseParser()
            let ev = p.feed("The run button is top left. [POINT:none]") + p.finish()
            expect(ResponseParserTests.points(ev).isEmpty)
            let shown = ResponseParserTests.texts(ev)
            expect(!shown.contains("[POINT"), "the sentinel leaked into the shown text: \(shown)")
            expect(shown.contains("run button"), "the answer itself must survive: \(shown)")
        }

        // MARK: <MEMORY>

        test("parses a memory proposal") {
            let p = ResponseParser()
            let json = #"{"add":[{"section":"You","fact":"Uses Raycast"}],"prune":["old thing"]}"#
            let ev = p.feed("<MEMORY>\(json)</MEMORY>") + p.finish()

            guard let proposal = ResponseParserTests.memory(ev) else {
                expect(false, "no memory event in \(ev)")
                return
            }
            expectEqual(proposal.add.count, 1)
            expectEqual(proposal.add.first?.section, MemoryStore.Section.you)
            expectEqual(proposal.add.first?.fact, "Uses Raycast")
            expectEqual(proposal.prune, ["old thing"])
        }

        test("a malformed MEMORY block is dropped, never shown to the user") {
            let p = ResponseParser()
            let ev = p.feed("<MEMORY>{not json at all}</MEMORY>") + p.finish()
            let hasMemory = ev.contains { if case .memory = $0 { return true }; return false }
            expect(!hasMemory, "malformed memory should not produce an event")
            expect(!ResponseParserTests.texts(ev).contains("<MEMORY>"), "machine syntax leaked into visible text")
        }

        test("a MEMORY block naming an unknown section drops just that addition") {
            let p = ResponseParser()
            let json = #"{"add":[{"section":"Nope","fact":"x"},{"section":"You","fact":"y"}]}"#
            let ev = p.feed("<MEMORY>\(json)</MEMORY>") + p.finish()
            guard let proposal = ResponseParserTests.memory(ev) else {
                expect(false, "no memory event")
                return
            }
            expectEqual(proposal.add.count, 1, "unknown section should be dropped, valid one kept")
            expectEqual(proposal.add.first?.fact, "y")
        }

        // MARK: Unknown tags

        test("an unknown NOTE block round-trips as plain text, even across deltas") {
            let reply = "Before <NOTE> Debug Navigator\n </NOTE> after."
            let whole = ResponseParser()
            let wholeEvents = whole.feed(reply) + whole.finish()
            expectEqual(wholeEvents, [.text(reply)],
                        "old NOTE offers must remain visible instead of being silently consumed")

            let streamed = ResponseParser()
            let streamedEvents = ResponseParserTests.feedAll(streamed, reply) + streamed.finish()
            expectEqual(ResponseParserTests.texts(streamedEvents), reply,
                        "splitting a retired tag across deltas must not lose its markup or content")
            expect(streamedEvents.allSatisfy { if case .text = $0 { return true }; return false },
                   "NOTE is unknown text, not an instruction to save or speak anything")
        }

        test("an unterminated NOTE block is preserved as unknown text") {
            let parser = ResponseParser()
            let reply = "The answer is 42. <NOTE>save this"
            let events = parser.feed(reply) + parser.finish()
            expectEqual(events, [.text(reply)],
                        "an incomplete legacy NOTE must not swallow the answer or its own contents")
        }

        // MARK: <DRAFT>

        test("a drafted message becomes a draft, whole and not spoken") {
            let p = ResponseParser()
            let ev = p.feed("<DRAFT>Hi Dad — I'll be there at seven.</DRAFT>") + p.finish()
            guard case .draft(let text) = ev.first else {
                expect(false, "no draft in \(ev)")
                return
            }
            expectEqual(text, "Hi Dad — I'll be there at seven.",
                        "the words he copies have to arrive exactly as written")
            let spoken = ev.compactMap { if case .speech(let t) = $0 { t } else { nil } }.joined()
            expect(!spoken.contains("Dad"),
                   "a draft leaked into the spoken answer — it is a payload, not narration")
        }

        test("a draft split across deltas or one character at a time still arrives") {
            let p = ResponseParser()
            var ev = p.feed("<DRA")
            ev += p.feed("FT>call the bank</DRAFT>")
            ev += p.finish()
            expect(ev.contains(.draft("call the bank")), "a split DRAFT was lost: \(ev)")

            let slow = ResponseParser()
            let letters = ResponseParserTests.feedAll(slow, "<DRAFT>two words</DRAFT>")
            expect(letters.contains(.draft("two words")),
                   "a DRAFT streamed one character at a time is the normal case for a real model")
        }

        // Photographed twice on his machine over an empty editor: a contended model writes the
        // aim, closes the bracket, and puts the code after it as plain text. The head is a real
        // aim, so the words that follow are a real payload — gathered from the text stream and
        // turned into the act at finish, because a type that never parses is his words vanishing.
        test("a pipe-less TYPE tag gathers its words from the text that follows") {
            let parser = ResponseParser()
            let events = parser.feed("[TYPE:248,349]#include <stdatomic.h>\nint main(void) { return 0; }")
                + parser.finish()
            let typed = events.compactMap { event -> String? in
                if case .act(let request) = event, let text = request.textToType { return text }
                return nil
            }
            expectEqual(typed.first, "#include <stdatomic.h>\nint main(void) { return 0; }",
                        "the code after the bracket is the payload he asked to type: \(events)")
            expect(events.contains(.text("[TYPE:248,349]")),
                   "the tag itself still reaches him as text — fail-open, unchanged")
        }

        // The exact tag from the 21:39 screenshot: qualified aim, no pipe, code after the
        // bracket. Every part of that shape must survive into one act.
        test("a pipe-less qualified TYPE gathers its code from the text that follows") {
            let streamer = AnswerStreamer()
            streamer.push("[TYPE:app=Google Chrome x=200,y=400]#include <stdio.h>\nint main(void) { return 0; }")
            streamer.finish()
            let request = streamer.actionRequests.first
            expectEqual(request?.textToType, "#include <stdio.h>\nint main(void) { return 0; }",
                        "the code after the bracket is the payload: \(request?.textToType ?? "nil")")
            expectEqual(request?.pointTarget?.appName, "Google Chrome",
                        "the named app must survive the gather, not just the coordinates")
        }

        test("an x= prefix on coordinates is the same aim, not a malformed tag") {
            let parser = ResponseParser()
            let events = parser.feed("[TYPE:x=200,380|hello there]") + parser.finish()
            let request = events.compactMap { event -> ActionRequest? in
                if case .act(let r) = event { return r }
                return nil
            }.first
            expectEqual(request?.textToType, "hello there",
                        "a contended model's keyed coordinates must not cost him the act")
            expectEqual(request?.pointTarget?.x ?? -1, 200, "the x= aim must keep its x")
        }

        // Code contains `]`, which is what used to end the tag — so a payload with an array bracket
        // was typed up to the bracket and lost the rest, and the rejoin that recovered it put a
        // literal `]` into his file. A `]` now closes a type tag only where the reply's structure
        // ends it, so the code keeps its brackets and the payload keeps no stray one.
        test("code after the tag's first closing bracket rejoins the payload") {
            let streamer = AnswerStreamer()
            streamer.push("[TYPE:1,2:box|int x[4];\nreturn x[0];]")
            streamer.finish()
            let typed = streamer.actionRequests.first?.textToType ?? ""
            expect(typed.contains("int x[4];") && typed.contains("return x[0];"),
                   "both brackets in the code are content, not the tag: \(typed)")
            expect(!typed.hasSuffix("]"),
                   "and the tag's own closing bracket must not be typed into the editor: \(typed)")
        }

        test("an act tag that follows a type tag survives it") {
            // Measured 2026-10-29 in his history: a reply asked for code and then for the Run button,
            // and "when i said to click it must perform the click action" is the whole complaint —
            // the type tag's payload ran into the next construct and the click never arrived.
            let streamer = AnswerStreamer()
            streamer.push("[TYPE:1,2:box|int x[4];\n}\n]\n[ACT:9,9:Run button]")
            streamer.finish()
            expectEqual(streamer.actionRequests.count, 2,
                        "two requests, not one: \(streamer.actionRequests.count)")
            let typed = streamer.actionRequests.first?.textToType ?? ""
            expect(typed.contains("int x[4];") && !typed.contains("Run button"),
                   "the field gets the program and none of the next tag: \(typed)")
            expectEqual(streamer.actionRequests.last?.pointTarget?.label, "Run button",
                        "the click survives as its own act")
        }

        test("the aim shapes his replies actually carry all resolve to the same pixel") {
            // Every one of these came out of his own history, and four of the twelve `[TYPE:]` tags
            // this build has been asked to run carried an axis letter the grammar never defined —
            // each failing open as raw markup over an empty editor is the user asking twice.
            for (body, x, y) in [("x:235,y:400", 235.0, 400.0), ("x,625,320", 625.0, 320.0),
                                 ("x=200,380", 200.0, 380.0), ("625,320", 625.0, 320.0),
                                 ("x,230,y:360", 230.0, 360.0)] {
                let request = ActionRequest.parseType("\(body)|select 1;")
                expectEqual(request?.pointTarget?.x ?? -1, x, "\(body) lost its x")
                expectEqual(request?.pointTarget?.y ?? -1, y, "\(body) lost its y")
                expectEqual(request?.textToType, "select 1;", "\(body) lost its payload")
            }
            // The label is the exception: `x,230,y:360:main.c` names the file as well as the point.
            let labelled = ActionRequest.parseType("x,230,y:360:main.c|int main();")
            expectEqual(labelled?.pointTarget?.label, "main.c",
                        "an axis-named aim still has to keep its label")
            // And a colon that is genuinely a label separator with nothing after it stays a refusal,
            // so this leniency does not quietly accept a broken tag.
            expect(ActionRequest.parseType("640,910:|select 1;") == nil,
                   "an explicitly empty label is a broken tag, not a terse one")
            // A label that starts with an axis letter is still a label.
            expectEqual(ActionRequest.parseType("10,20:x-ray machine|hi")?.pointTarget?.label,
                        "x-ray machine", "axis stripping must not eat a real label")
        }

        test("a raw tag line ends a gathered payload instead of joining it") {
            let streamer = AnswerStreamer()
            streamer.push("[TYPE:1,2:box]part one\nrest of it\n[ACT:x=9,9:not a real act]")
            streamer.finish()
            let typed = streamer.actionRequests.first?.textToType ?? ""
            expect(typed.contains("part one") && typed.contains("rest of it"),
                   "the payload is the code, whole: \(typed)")
            expect(!typed.contains("[ACT:"),
                   "a following raw tag must not be typed into the field: \(typed)")
        }

        test("prose on the next line after a well-formed type tag is not typed") {
            let streamer = AnswerStreamer()
            streamer.push("[TYPE:1,2:box|good night]\nthen press send when i say")
            streamer.finish()
            expectEqual(streamer.actionRequests.first?.textToType, "good night",
                        "the extension must re-join same-line code, not the sentence after it")
        }

        test("a draft too long or empty is shown, never swallowed or clipped") {
            let long = ResponseParser()
            let body = String(repeating: "x", count: ResponseParser.maxDraftCharacters + 1)
            let ev = long.feed("<DRAFT>\(body)</DRAFT>") + long.finish()
            let echoed = ev.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
            expect(echoed.contains("<DRAFT>"),
                   "an over-long draft must reach the user as text: half a sentence pasted into a chat "
                        + "is the failure this refuses")
            expect(!ev.contains(where: { if case .draft = $0 { return true } else { return false } }),
                   "an over-cap body must not become a payload")

            let empty = ResponseParser()
            let blank = empty.feed("<DRAFT>   </DRAFT>") + empty.finish()
            expect(blank.contains(where: { event in
                if case .text(let t) = event { return t.contains("<DRAFT>") }
                return false
            }), "an empty draft is a model mistake and he should see it: \(blank)")
        }

        // MARK: Streaming — the hard part

        test("a tag split across two deltas is still parsed") {
            let p = ResponseParser()
            var ev = p.feed("Here it is: [POI")
            ev += p.feed("NT:412,180,Run:screen1]")
            ev += p.finish()
            expectEqual(ResponseParserTests.points(ev).count, 1, "split POINT was lost")
            expectEqual(ResponseParserTests.points(ev).first?.label, "Run")
        }

        test("a tag split one character at a time is parsed") {
            let p = ResponseParser()
            let reply = "<SAY>hello there</SAY> and [POINT:9,9:Thing:screen1]"
            let ev = ResponseParserTests.feedAll(p, reply)
            expectEqual(ResponseParserTests.speeches(ev), "hello there")
            expectEqual(ResponseParserTests.points(ev).count, 1)
        }

        test("only the ambiguous tail is held back, not the whole prefix") {
            let p = ResponseParser()
            // The unambiguous prefix should stream straight through — holding it back would
            // add latency for no correctness gain. Only "<SA" is ambiguous.
            let ev = p.feed("text so far <SA")
            expectEqual(ResponseParserTests.texts(ev), "text so far ")
            expect(!ResponseParserTests.texts(ev).contains("<SA"), "ambiguous tail leaked: \(ResponseParserTests.texts(ev))")
        }

        test("held-back text is released once the tag completes") {
            let p = ResponseParser()
            var ev = p.feed("visible <SA")
            ev += p.feed("Y>spoken</SAY>")
            ev += p.finish()
            expectEqual(ResponseParserTests.texts(ev), "visible spoken")
            expectEqual(ResponseParserTests.speeches(ev), "spoken")
        }

        test("finish() flushes an unterminated tag as text rather than eating it") {
            let p = ResponseParser()
            var ev = p.feed("hello <SAY>never closed")
            ev += p.finish()

            let shown = ResponseParserTests.texts(ev)
            expect(shown.contains("hello"), "prefix was swallowed — got \(shown)")
            expect(shown.contains("<SAY>never closed"), "unterminated tag should be shown, not hidden — got \(shown)")
            expect(ResponseParserTests.speeches(ev).isEmpty, "unterminated tag must not be spoken")
        }

        // MARK: Combined

        test("a realistic full reply parses correctly end to end") {
            let p = ResponseParser()
            let reply = """
            That's the Debug Navigator — it lists every symbol in your project.
            <SAY>The panel on your left is the Debug Navigator.</SAY>
            The toggle is here: [POINT:64,412,Toggle navigator:screen1]
            <MEMORY>{"add":[{"section":"You","fact":"Working on a SwiftUI menu bar app"}]}</MEMORY>
            """
            let ev = ResponseParserTests.feedAll(p, reply) + p.finish()

            let shown = ResponseParserTests.texts(ev)
            expect(shown.contains("Debug Navigator — it lists every symbol"), "prose lost")
            expect(shown.contains("The panel on your left"), "spoken text not shown")
            expect(!shown.contains("<"), "tag markup leaked into visible text: \(shown)")

            expectEqual(ResponseParserTests.speeches(ev), "The panel on your left is the Debug Navigator.")
            expectEqual(ResponseParserTests.points(ev).first?.label, "Toggle navigator")
            expectEqual(ResponseParserTests.points(ev).first?.y, 412)

            let mem = ev.compactMap { if case .memory(let m) = $0 { return m }; return nil }
            expectEqual(mem.count, 1)
            expectEqual(mem.first?.add.first?.fact, "Working on a SwiftUI menu bar app")        }

        // Regression. The drain loop emitted the text preceding a construct but removed
        // only the construct's own range, so that text stayed in the buffer and was
        // emitted a second time. It is invisible when deltas arrive one character at a
        // time — the existing tests all fed the reply that way — and only shows up when a
        // whole reply arrives at once, which is what a fast model does.
        test("text before a construct is shown once, not twice, in a single delta") {
            let p = ResponseParser()
            var events = p.feed("Some explanation here.\n[POINT:10,20,Save]\nAnd more text.")
            events += p.finish()

            let shown = events.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined()
            expectEqual(shown, "Some explanation here.\n\nAnd more text.")
        }

        test("a whole reply fed at once equals the same reply fed a character at a time") {
            let reply = "<SAY>That is the debug navigator.</SAY>\n"
                + "The left pane is the call stack.\n"
                + "[POINT:412,180,Run button]\n"
                + "Press the run button at the top left.\n"

            let whole = ResponseParser()
            var wholeEvents = whole.feed(reply)
            wholeEvents += whole.finish()

            let perCharacter = ResponseParser()
            var characterEvents: [ReplyEvent] = []
            for character in reply {
                characterEvents += perCharacter.feed(String(character))
            }
            characterEvents += perCharacter.finish()

            expectEqual(wholeEvents, characterEvents,
                        "delta framing must not change the parse — SSE chunks are not character-aligned")
        }

        test("text arriving in many small chunks reassembles exactly") {
            let p = ResponseParser()
            let original = "The quick brown fox jumps over the lazy dog."
            var ev: [ReplyEvent] = []
            for chunk in stride(from: 0, to: original.count, by: 3) {
                let s = original.index(original.startIndex, offsetBy: chunk)
                let e = original.index(s, offsetBy: min(3, original.count - chunk))
                ev += p.feed(String(original[s..<e]))
            }
            ev += p.finish()
            expectEqual(ResponseParserTests.texts(ev), original)
        }

        // MARK: Result protocol — <SUMMARY> / <DONE_TITLE> / <NEXT_ACTIONS>

        test("<SUMMARY> is spoken, not shown") {
            let p = ResponseParser()
            let ev = p.feed("Detail text.\n<SUMMARY>The welcome page is ready.</SUMMARY>") + p.finish()
            expectEqual(ResponseParserTests.summaries(ev), "The welcome page is ready.")
            expect(!ResponseParserTests.texts(ev).contains("SUMMARY"),
                   "the completion line belongs to the TTS pipeline; echoing it back reads as the model quoting itself")
            expect(ResponseParserTests.texts(ev).contains("Detail text."), "detail lost")
        }

        test("<DONE_TITLE> becomes a one-line chip label") {
            let p = ResponseParser()
            let ev = p.feed("<DONE_TITLE>Rishideep Welcome Page</DONE_TITLE>") + p.finish()
            expectEqual(ResponseParserTests.titles(ev), "Rishideep Welcome Page")
            expect(ResponseParserTests.texts(ev).isEmpty, "title leaked into the transcript")
        }

        test("a multi-line DONE_TITLE keeps its first line") {
            let p = ResponseParser()
            let ev = p.feed("<DONE_TITLE>Debug Navigator\nprose the model should not have put here</DONE_TITLE>") + p.finish()
            expectEqual(ResponseParserTests.titles(ev), "Debug Navigator")
        }

        test("an over-long DONE_TITLE is cut at a word boundary, not mid-word") {
            let long = String(repeating: "word ", count: 30)
            let p = ResponseParser()
            let ev = p.feed("<DONE_TITLE>\(long)</DONE_TITLE>") + p.finish()
            let title = ResponseParserTests.titles(ev) ?? ""
            expect(title.count <= ResponseParser.titleCharacterLimit + 1,
                   "a title wider than the chip pushes the answer off the card: got \(title.count)")
            expect(!title.contains("wor…"), "truncation sliced a word in half: \(title)")
        }

        test("<NEXT_ACTIONS> parses a bullet list into chips") {
            let p = ResponseParser()
            let ev = p.feed("""
            <NEXT_ACTIONS>
            - Add a CSS-only dark theme
            * Export it as a PDF
            </NEXT_ACTIONS>
            """) + p.finish()
            expectEqual(ResponseParserTests.actions(ev), ["Add a CSS-only dark theme", "Export it as a PDF"])
        }

        test("<NEXT_ACTIONS> tolerates numbering and caps at three chips") {
            let p = ResponseParser()
            let ev = p.feed("""
            <NEXT_ACTIONS>
            1. First action
            2. Second action
            3. Third action
            4. Fourth action
            5. Fifth action
            </NEXT_ACTIONS>
            """) + p.finish()
            let got = ResponseParserTests.actions(ev)
            expectEqual(got.count, ResponseParser.maxNextActions,
                        "more than \(ResponseParser.maxNextActions) chips is a menu the user reads, not one they tap")
            expectEqual(got.first, "First action")
        }

        test("<NEXT_ACTIONS> drops blank and repeated lines") {
            let p = ResponseParser()
            let ev = p.feed("""
            <NEXT_ACTIONS>

            - Open it in Safari

            - Open it in Safari
            - Rename the file
            </NEXT_ACTIONS>
            """) + p.finish()
            expectEqual(ResponseParserTests.actions(ev), ["Open it in Safari", "Rename the file"])
        }

        test("a result tag split across deltas never shows its markup") {
            // The framing a real SSE stream uses: chunk boundaries land mid-token.
            let p = ResponseParser()
            var ev: [ReplyEvent] = []
            for delta in ["Answer. <SUMM", "ARY>It is don", "e.</SUMMARY><DON", "E_TITLE>Done<", "/DONE_TITLE>"] {
                ev += p.feed(delta)
            }
            ev += p.finish()
            expectEqual(ResponseParserTests.summaries(ev), "It is done.")
            expectEqual(ResponseParserTests.titles(ev), "Done")
            let shown = ResponseParserTests.texts(ev)
            expect(!shown.contains("<") && !shown.contains(">"),
                   "partial markup reached the screen: \(shown.debugDescription)")
        }

        test("a whole reply with result tags parses identically at any chunk size") {
            let reply = """
            <SAY>Here is the page.</SAY>
            The five icons sit in a single row.

            [POINT:412,180,Run button]

            <SUMMARY>A one-screen welcome page is ready.</SUMMARY>
            <DONE_TITLE>Welcome Page</DONE_TITLE>
            <NEXT_ACTIONS>
            - Add a dark theme
            </NEXT_ACTIONS>
            """

            let whole = ResponseParser()
            var wholeEvents = whole.feed(reply)
            wholeEvents += whole.finish()

            let perCharacter = ResponseParser()
            var characterEvents: [ReplyEvent] = []
            for character in reply { characterEvents += perCharacter.feed(String(character)) }
            characterEvents += perCharacter.finish()

            expectEqual(wholeEvents, characterEvents,
                        "result tags must parse the same way regardless of delta framing")
            expectEqual(ResponseParserTests.summaries(wholeEvents), "A one-screen welcome page is ready.")
            expectEqual(ResponseParserTests.titles(wholeEvents), "Welcome Page")
            expectEqual(ResponseParserTests.actions(wholeEvents), ["Add a dark theme"])
        }

        test("an unterminated result tag is released as text, not swallowed") {
            // Fail open: the user loses a chip, not their answer.
            let p = ResponseParser()
            var ev = p.feed("<SUMMARY>this never closed")
            ev += p.finish()
            expect(ResponseParserTests.texts(ev).contains("<SUMMARY>this never closed"),
                   "an incomplete SUMMARY ate the reply instead of showing it")
        }

        test("doneTitle parses when closed with </DONE> or </TITLE>") {
            let p1 = ResponseParser()
            let ev1 = p1.feed("<DONE_TITLE>Notes open</DONE>[POINT:500,500:Notes]") + p1.finish()
            expectEqual(ResponseParserTests.titles(ev1), "Notes open")
            expectEqual(ResponseParserTests.points(ev1).count, 1)

            let p2 = ResponseParser()
            let ev2 = p2.feed("<DONE_TITLE>Page loaded</TITLE>") + p2.finish()
            expectEqual(ResponseParserTests.titles(ev2), "Page loaded")
        }

        test("point and type tags recover when coordinates use x or y placeholders") {
            let p = ResponseParser()
            let ev = p.feed("[POINT:x,480:Ask button][TYPE:x,803:Search field|hello]") + p.finish()
            let pts = ResponseParserTests.points(ev)
            expectEqual(pts.count, 1)
            expectEqual(pts.first?.x, 500.0)
            expectEqual(pts.first?.y, 480.0)
            expectEqual(pts.first?.label, "Ask button")

            let acts = ev.compactMap { if case .act(let a) = $0 { return a }; return nil }
            expectEqual(acts.count, 1)
            expectEqual(acts.first?.textToType, "hello")
            expectEqual(acts.first?.pointTarget?.x, 500.0)
            expectEqual(acts.first?.pointTarget?.y, 803.0)
        }

        test("act tag attempting to open an app converts to openApp tool") {
            let p = ResponseParser()
            let ev = p.feed("<SAY>opening notes</SAY>[ACT:app=Notes role=menuitem name=\"Open\"]") + p.finish()
            let tools = ev.compactMap { if case .tool(let t) = $0 { return t }; return nil }
            expectEqual(tools.count, 1)
            if let first = tools.first, case .openApp(let name) = first {
                expectEqual(name, "Notes")
            } else {
                expect(false, "expected openApp tool for Notes")
            }
        }

        test("semantic target parses when extra keys like type or id are present") {
            guard let target = SemanticTarget.parse("app=WhatsApp name=\"Search\" type=\"dad\"") else {
                expect(false, "failed to parse semantic target with extra type field")
                return
            }
            expectEqual(target.app, "WhatsApp")
            expectEqual(target.name, "Search")
        }

        test("act followed by pipeless type tag converts to type act on that target") {
            let p = ResponseParser()
            let ev = p.feed("[ACT:app=Terminal role=textfield name=\"search\"]\n[TYPE:search for how to use sql]") + p.finish()
            let acts = ev.compactMap { if case .act(let a) = $0 { return a }; return nil }
            expectEqual(acts.count, 1)
            expectEqual(acts.first?.textToType, "search for how to use sql")
            expectEqual(acts.first?.semanticTarget?.app, "Terminal")
            expectEqual(acts.first?.semanticTarget?.name, "search")
        }

        test("type tag with colon delimiter parses semantic target") {
            let p = ResponseParser()
            let ev = p.feed("[TYPE:app=WhatsApp name=\"Message\":good night]") + p.finish()
            let acts = ev.compactMap { if case .act(let a) = $0 { return a }; return nil }
            expectEqual(acts.count, 1)
            expectEqual(acts.first?.textToType, "good night")
            expectEqual(acts.first?.semanticTarget?.app, "WhatsApp")
            expectEqual(acts.first?.semanticTarget?.name, "Message")
        }
    }
}
