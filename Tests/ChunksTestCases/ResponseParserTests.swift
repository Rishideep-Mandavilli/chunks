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

        // MARK: <NOTE>

        test("parses a notebook save offer") {
            let p = ResponseParser()
            let ev = p.feed("<NOTE>Debug Navigator</NOTE>") + p.finish()
            guard case .noteOffer(let title) = ev.first else {
                expect(false, "no note offer in \(ev)")
                return
            }
            expectEqual(title, "Debug Navigator")
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
    }
}
