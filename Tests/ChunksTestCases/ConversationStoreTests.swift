import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// Tests for the persisted conversation.
///
/// Two things go wrong here in real products and both are tested: a history that grows without
/// bound until the file is unopenable, and a history that is fed back to the model whole, so every
/// question pays for the last two hundred answers in tokens.
public enum ConversationStoreTests {

    private static func turn(_ asked: String, _ answered: String,
                             at offset: TimeInterval = 0,
                             source: ConversationTurn.Source = .voice) -> ConversationTurn {
        ConversationTurn(asked: asked, answered: answered,
                         headline: answered.prefix(24).trimmingCharacters(in: .whitespaces),
                         at: Date(timeIntervalSince1970: 1_800_000_000 + offset),
                         source: source)
    }

    public static func register() {
        TestRunner.currentSuite = "Conversation history"

        test("the file is capped by dropping the oldest, never the newest") {
            var store = ConversationStore()
            for index in 0..<(ConversationStore.maxTurns + 25) {
                store.append(turn("q\(index)", "answer \(index)", at: TimeInterval(index)))
            }
            expectEqual(store.turns.count, ConversationStore.maxTurns,
                        "an uncapped history becomes a file nobody can open")
            expectEqual(store.turns.last?.asked, "q\(ConversationStore.maxTurns + 24)",
                        "trimming the wrong end loses the conversation the user is still in")
        }

        // The session cap. What it must never do is cost continuity: the replay carries the last ten
        // of the *current* session, so a cap below ten would cut a conversation off mid-thought, and
        // a cap that discards the closed session's turns would turn a filing rule into amnesia.
        test("a session closes itself at the limit and the next question starts a new one") {
            var store = ConversationStore()
            for index in 0..<ConversationStore.maxTurnsPerSession {
                store.append(turn("q\(index)", "a\(index)", at: TimeInterval(index)))
                expect(store.sessions.count == 1,
                       "it rotated mid-conversation, at exchange \(index + 1) — a plan would lose "
                       + "the steps before it")
            }
            expect(store.closeSessionIfFull(), "a full session did not close")
            expectEqual(store.sessions.count, 2, "the boundary is a session, not a deleted row")
            let closed = store.sessions.first!.id
            expectEqual(store.sessionTurns(closed).count, ConversationStore.maxTurnsPerSession,
                        "the closed session lost turns — a cap must file, not forget")
            expect(store.currentSessionID != closed, "the next question is still in the old one")
            expect(store.sessionTurns().isEmpty,
                   "a new session starts empty, or the model replays a conversation it just closed")
        }

        test("the cap sits above the replay so a boundary costs no context") {
            expect(ConversationStore.maxTurnsPerSession > ConversationStore.promptBudget,
                   "a session that ends before the replay window fills cuts the conversation the "
                   + "model is still holding")
        }

        test("the index names every sitting the model would otherwise not know about") {
            var store = ConversationStore()
            for index in 0..<(ConversationStore.maxTurnsPerSession + 3) {
                store.append(turn("why is q\(index) failing", "because of \(index)",
                                  at: TimeInterval(index) * 60))
                // The cap is a boundary the shell opens between turns, not something `append`
                // does mid-conversation — see `closeSessionIfFull`.
                store.closeSessionIfFull(at: Date(timeIntervalSince1970: 1_800_000_000
                                                  + TimeInterval(index) * 60))
            }
            let index = store.sessionIndex()
            expect(index.contains("his conversations"), "the block has to say what it is: \(index)")
            let lines = index.split(separator: "\n").filter { $0.hasPrefix("- ") }
            expectEqual(lines.count, 2, "two sittings happened and the model should see both")
            expect(index.contains("started when Chunks opened"),
                   "and why each one began, in the words the window uses")
            expect(index.contains("started when the last one filled up"),
                   "including the machine's own boundary — an unexplained gap reads as broken history")
        }

        test("the index is bounded, because it is paid for on every turn") {
            var store = ConversationStore()
            for index in 0..<(ConversationStore.maxTurnsPerSession * 14) {
                store.append(turn("a long question about thing number \(index) that keeps going",
                                  "an answer of some length about \(index)",
                                  at: TimeInterval(index) * 60))
                store.closeSessionIfFull(at: Date(timeIntervalSince1970: 1_800_000_000
                                                  + TimeInterval(index) * 60))
            }
            let index = store.sessionIndex()
            expect(index.count <= ConversationStore.indexCharacterBudget + 240,
                   "the index outgrew its budget: \(index.count) characters")
            let lines = index.split(separator: "\n").filter { $0.hasPrefix("- ") }
            expect(lines.count <= ConversationStore.indexSessionLimit,
                   "every session in the file went into the prompt: \(lines.count) lines")
        }

        test("an empty history indexes nothing rather than an empty promise") {
            expect(ConversationStore().sessionIndex().isEmpty,
                   "a first-run prompt should not carry a header about conversations that did not happen")
        }

        test("only a bounded slice goes back to the model") {            var store = ConversationStore()
            for index in 0...40 { store.append(turn("q\(index)", "a\(index)", at: TimeInterval(index))) }
            let recent = store.recent()
            expectEqual(recent.count, ConversationStore.promptBudget)
            expectEqual(recent.first?.asked, "q31", "the budget takes the newest N, oldest first")
            expectEqual(recent.last?.asked, "q40")
            expect(store.recent(0).isEmpty, "a zero budget means no history, not all of it")
        }

        test("a preview cuts at a word and marks itself short") {
            // Distinct words, on purpose: a repeated "word word word" ends in a complete word
            // whatever the cut, so it cannot tell a clean cut from a mid-word one.
            let long = (1...80).map { "answer\($0)" }.joined(separator: " ")
            let preview = ConversationStore.preview(of: long)
            expect(preview.hasSuffix("…"), "a truncated line must look truncated: \(preview)")
            let body = String(preview.dropLast())
            expect(!body.hasSuffix(" "), "a preview must not end in a bare space: \(preview.suffix(12))")
            expect(long.dropFirst(body.count).first == " ",
                   "cutting mid-word reads as a broken store: …\(body.suffix(12))")
            expect(preview.count <= ConversationStore.previewCharacters + 2)
            expectEqual(ConversationStore.preview(of: "short  answer"), "short answer",
                        "whitespace is collapsed so a list row cannot hold a blank run")
        }

        test("a turn keeps what it did, not only what it said") {
            var store = ConversationStore()
            store.append(ConversationTurn(asked: "message dad", answered: "typed it in",
                                          headline: "Ready to send",
                                          acts: ["Typed hi into Compose message."]))
            let data = store.encoded()!
            let reloaded = ConversationStore(turns: ConversationStore.decode(data))
            expectEqual(reloaded.turns.first?.acts, ["Typed hi into Compose message."],
                        "\"I found the send button\" and \"Pressed Send\" are different claims about the machine")
        }

        test("the source survives, so a scheduled turn is not read as his own words") {
            var store = ConversationStore()
            store.append(turn("brief me", "here's your day", source: .routine))
            let reloaded = ConversationStore(turns: ConversationStore.decode(store.encoded()!))
            expectEqual(reloaded.turns.first?.source, .routine)
            expectEqual(reloaded.turns.first?.source.phrase, "scheduled")
        }

        test("a corrupt file loads as empty and an empty turn is not history") {
            expect(ConversationStore.decode(Data("}}} not json".utf8)).isEmpty)
            let junk = try! JSONEncoder().encode([
                ConversationTurn(asked: "   ", answered: "x", headline: "x"),
                ConversationTurn(asked: "real", answered: "y", headline: "y"),
            ])
            let loaded = ConversationStore.decode(junk)
            expectEqual(loaded.count, 1, "one blank row must not cost the whole history")
            expectEqual(loaded.first?.asked, "real")
        }

        test("one unreadable row costs only itself, not the history") {
            // JSONDecoder answers an array atomically: a row whose date is a number instead of the
            // ISO string this store writes used to fail the whole file, and every answer he ever got
            // disappeared with it.
            let rows = """
            [{"id":"7F2A4C1E-0D3B-4E58-9A11-2B6C8D0E4F11","asked":"what is open","answered":"Notes",\
            "headline":"Notes","at":798194038.4,"source":"voice","acts":[]},\
            {"asked":"keep me","answered":"yes","headline":"yes"},\
            "not even an object"]
            """
            let loaded = ConversationStore.decode(Data(rows.utf8))
            expectEqual(loaded.count, 2, "the two rows with a question in them must survive")
            expectEqual(loaded.first?.asked, "what is open")
            expectEqual(loaded.last?.asked, "keep me", "missing fields default, they do not delete")
            expect(!loaded.last!.hasRecordedDate,
                   "a row with no date must not be shown as a time — the window hides it")
            expect(loaded.first!.hasRecordedDate)
        }

        test("a removed turn stays removed after a reload") {
            var store = ConversationStore()
            let kept = turn("keep", "yes")
            let dropped = turn("drop", "no")
            store.append(kept)
            store.append(dropped)
            store.remove(id: dropped.id)
            expectEqual(store.turns.count, 1)
            expect(store.turns.contains(where: { $0.id == kept.id }))
        }

        // MARK: - Sessions

        test("a turn lands in the session that is open") {
            var store = ConversationStore()
            let first = store.beginSession(starting: .launch, at: Date())
            store.append(turn("what is open", "Notes"))
            expectEqual(store.turns.last?.sessionID, first.id,
                        "without a session on the row, nothing can be scoped out later")
        }

        test("a new session stops the old one being replayed, and keeps it on disk") {
            var store = ConversationStore()
            store.beginSession(starting: .launch, at: Date())
            store.append(turn("first question", "first answer"))
            store.append(turn("second question", "second answer"))
            expectEqual(store.recent().count, 2)

            store.beginSession(starting: .manual, at: Date().addingTimeInterval(600))
            expect(store.recent().isEmpty,
                   "the model must not be told about yesterday's screen as if it were still up")
            expectEqual(store.turns.count, 2,
                        "starting over ends the conversation, it does not delete it")
            expectEqual(store.sessions.count, 2)
        }

        test("starting a session twice with nothing in it adds one row") {
            var store = ConversationStore()
            let opened = store.beginSession(starting: .launch, at: Date())
            let again = store.beginSession(starting: .manual, at: Date().addingTimeInterval(2))
            expectEqual(store.sessions.count, 1,
                        "two taps of the button, or two wakes in a minute, must not fill the list "
                        + "with empty conversations")
            expectEqual(again.id, opened.id)
            expectEqual(store.sessions.last?.start, .manual,
                        "the label says why the session is open now, not why it first appeared")
        }

        test("a file from before sessions still loads, into one restored conversation") {
            // His history.json predates this field. The alternative to migrating it was a window
            // that reads "Nothing asked yet" after an upgrade, which is data loss with a smile on.
            let legacy = try! JSONEncoder().encode([
                ConversationTurn(asked: "old question", answered: "old answer", headline: "old"),
            ])
            var store = ConversationStore(turns: ConversationStore.decode(legacy))
            expect(store.turns.first?.sessionID == nil,
                   "a row read from the old file has no session until the store gives it one")
            store = ConversationStore.loaded(from: legacy)
            expectEqual(store.sessions.count, 1)
            expectEqual(store.sessions.first?.start, .restored)
            expectEqual(store.turns.first?.sessionID, store.sessions.first?.id,
                        "orphan turns cannot be left out of every session — they'd vanish from "
                        + "the list and from recall")
        }

        test("the envelope round-trips both lists") {
            var store = ConversationStore()
            store.beginSession(starting: .launch, at: Date())
            store.append(turn("alpha", "one"))
            store.beginSession(starting: .wake, at: Date().addingTimeInterval(60))
            store.append(turn("beta", "two"))
            let reloaded = ConversationStore.loaded(from: store.encoded()!)
            expectEqual(reloaded.sessions.count, 2)
            expectEqual(reloaded.turns.count, 2)
            expectEqual(reloaded.sessions.last?.start, .wake)
            expectEqual(reloaded.turns.last?.sessionID, reloaded.sessions.last?.id)
            expectEqual(reloaded.recent().map(\.asked), ["beta"],
                        "the current session is the one that survives a reload")
        }

        test("pruning turns prunes the sessions that no longer hold one") {
            var store = ConversationStore()
            let first = store.beginSession(starting: .launch, at: Date())
            store.append(turn("the very first question", "and its answer", at: 0))
            store.beginSession(starting: .manual, at: Date())
            // Enough later turns to push that first row out of the file entirely.
            for index in 1...ConversationStore.maxTurns {
                store.append(turn("q\(index)", "a\(index)", at: TimeInterval(index)))
            }
            expect(!store.turns.contains(where: { $0.sessionID == first.id }),
                   "the cap should have reached the oldest row by now")
            expect(!store.sessions.contains(where: { $0.id == first.id }),
                   "the file would otherwise fill with session headers that head nothing")
            expect(store.sessions.contains(where: { $0.id == store.currentSessionID }),
                   "the open session is kept even while empty — the list needs to say what is now")
        }

        // MARK: - Recalling an older conversation

        test("recall finds the older exchange that answers the words") {
            var store = ConversationStore()
            store.beginSession(starting: .launch, at: Date())
            store.append(turn("why is the certificate warning showing",
                              "the host name does not match the certificate"))
            store.beginSession(starting: .wake, at: Date().addingTimeInterval(3600))
            store.append(turn("what is this button", "it saves the file"))

            let hits = store.recall(query: "what did I ask about the certificate")
            expectEqual(hits.count, 1)
            expectEqual(hits.first?.asked, "why is the certificate warning showing",
                        "this is the whole point: the answer is in a session the model can no "
                        + "longer see, so the shell has to go and get it")
        }

        test("recall never returns the conversation the model is already in") {
            var store = ConversationStore()
            store.beginSession(starting: .launch, at: Date())
            store.append(turn("certificate mismatch", "regenerate it"))
            expect(store.recall(query: "certificate").isEmpty,
                   "the replay already carries it; a second copy costs prompt and invites the "
                   + "model to describe a live turn as a past one")
        }

        test("a follow-up with nothing to match on recalls nothing") {
            var store = ConversationStore()
            store.beginSession(starting: .launch, at: Date())
            store.append(turn("certificate mismatch", "regenerate it"))
            expect(store.recall(query: "what did I ask you about that?").isEmpty,
                   "\"that\" is not a search term — dragging back an unrelated answer is worse "
                   + "than saying nothing")
            expect(store.recall(query: "").isEmpty)
        }

        test("a word he used in the question outranks one that only appears in the answer") {
            var store = ConversationStore()
            store.beginSession(starting: .launch, at: Date())
            store.append(turn("volume too loud", "turned it down"))   // other session
            store.beginSession(starting: .wake, at: Date().addingTimeInterval(60))
            store.append(turn("the mixer", "the volume slider is in System Settings"))

            let hits = store.recall(query: "volume", limit: 2)
            expectEqual(hits.first?.asked, "volume too loud",
                        "he is asking what he asked, so his own words are the stronger evidence")
        }

        test("recall is capped, because prompt costs are real") {
            var store = ConversationStore()
            store.beginSession(starting: .launch, at: Date())
            for index in 0...20 {
                store.append(turn("volume question \(index)", "the volume was set"))
            }
            store.beginSession(starting: .wake, at: Date().addingTimeInterval(60))
            expectEqual(store.recall(query: "volume").count, ConversationStore.recallBudget,
                        "an unbounded recall block would cost more tokens than the live "
                        + "conversation it is meant to supplement")
        }

        // MARK: - Words the list shows

        test("the day label answers \"which sit-down was this\"") {
            let calendar = Calendar(identifier: .gregorian)
            let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21,
                                                         hour: 14))!
            func day(_ offset: Int) -> Date {
                calendar.date(byAdding: .day, value: -offset, to: now)!
            }
            expectEqual(ConversationStore.dayLabel(for: now, now: now, calendar: calendar), "Today")
            expectEqual(ConversationStore.dayLabel(for: day(1), now: now, calendar: calendar),
                        "Yesterday")
            expectEqual(ConversationStore.dayLabel(for: day(2), now: now, calendar: calendar),
                        "Monday",
                        "inside the same week the weekday is the useful word")
            expect(ConversationStore.dayLabel(for: day(40), now: now, calendar: calendar)
                    .contains("Sep"), "beyond the week it needs a date, not a weekday")
            expect(ConversationStore.dayLabel(for: day(500), now: now, calendar: calendar)
                    .contains("2025"), "across a year boundary the year has to be in it")
        }

        test("the sleep gap is said in one unit") {
            expectEqual(ConversationStore.minutesSpentAsleep(45), "45 seconds")
            expectEqual(ConversationStore.minutesSpentAsleep(9 * 60), "9 minutes")
            expect(ConversationStore.minutesSpentAsleep(3 * 3600).contains("hour"))
            expectEqual(ConversationStore.minutesSpentAsleep(3 * 24 * 3600), "3 days")
        }
    }
}

private extension ConversationStore {
    /// Read test data through the door the app uses — a file on disk and `load(from:)`.
    ///
    /// Not a re-implementation of the migration in the test: a helper that copies production logic
    /// passes on the day the real reader breaks.
    static func loaded(from data: Data) -> ConversationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunks-history-test-\(UUID().uuidString).json")
        try? data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return ConversationStore.load(from: url)
    }
}
