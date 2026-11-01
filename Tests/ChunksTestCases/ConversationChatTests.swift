import ChunksKit
import ChunksTestHarness
import Foundation

/// Tests for the middle level of the history: the thread a run of exchanges forms.
///
/// The grouping is derived by a rule, so the rule is the thing under test — and the interesting
/// cases are the ones from the real file, where nine questions in one sitting read as three rows
/// called "Explain this", "I cant" and "?". Those must not become three threads.
public enum ConversationChatTests {

    private static let base = Date(timeIntervalSince1970: 1_800_000_000)

    private static func turn(_ asked: String, _ headline: String = "",
                             minutes: Int = 0,
                             session: UUID? = nil) -> ConversationTurn {
        ConversationTurn(asked: asked, answered: "an answer about it", headline: headline,
                         at: base.addingTimeInterval(TimeInterval(minutes * 60)),
                         sessionID: session)
    }

    public static func register() {
        TestRunner.currentSuite = "Chat threads"

        test("the first question of a sitting opens a thread") {
            expect(!ChatGrouping.continues(open: [], turn("what is this error")),
                   "there is nothing to continue, so a thread has to start")
        }

        test("a pointer keeps going, even when it shares no words") {
            let open = [turn("open whatsapp and search for sathvik", "Found Sathvik")]
            for followUp in ["type good night and leave it for me",
                             "what does the second line mean",
                             "i cant", "?", "explain this", "and the other one"] {
                expect(ChatGrouping.continues(open: open, turn(followUp, minutes: 4)),
                       "\"\(followUp)\" opened a second thread — the task read as two")
            }
        }

        test("a new subject opens a new thread") {
            let open = [turn("open whatsapp and search for sathvik", "Found Sathvik")]
            // Five real words, none of them pointing at anything, none of them in the thread.
            expect(!ChatGrouping.continues(
                open: open, turn("why is the certificate warning showing in chrome", minutes: 4)),
                   "a change of subject continued the old thread")
        }

        test("naming something the thread is about continues it") {
            let open = [turn("read the build log and tell me why it failed", "Reading build log")]
            expect(ChatGrouping.continues(
                open: open, turn("which line of the build log is the real cause", minutes: 3)),
                   "the same subject, said twice, split into two threads")
        }

        test("fifteen minutes away ends a thread whatever was said") {
            let open = [turn("why is the certificate warning showing", "Certificate warning")]
            expect(!ChatGrouping.continues(open: open, turn("this again", minutes: 16)),
                   "he went away and came back to something else; the old thread kept absorbing it")
            expect(ChatGrouping.continues(open: open, turn("this again", minutes: 14)),
                   "a two-minute read of the answer is not a new conversation")
        }

        test("a thread is named from the first thing he was told") {
            let withHeadline = turn("why is this red", "Explained the warning")
            expectEqual(ChatGrouping.title(for: withHeadline), "Explained the warning",
                        "the label is the <DONE_TITLE> he already read, not a new invention")
            let without = turn("why is this red")
            expectEqual(ChatGrouping.title(for: without), "why is this red",
                        "with no headline his own words are the name")
        }

        // MARK: - The store's tree

        test("appending places each turn in a session and a thread") {
            var store = ConversationStore()
            store.beginSession(starting: .launch, at: base)
            store.append(turn("open whatsapp and search for sathvik", "Found Sathvik"))
            store.append(turn("type good night and leave it for me", "Ready to send", minutes: 3))
            store.append(turn("why is the certificate warning showing in chrome",
                              "Explained the warning", minutes: 30))
            expectEqual(store.chats.count, 2, "three questions, two threads")
            expectEqual(store.turns(inChat: store.chats[0].id).count, 2)
            expectEqual(store.turns(inChat: store.chats[1].id).count, 1)
            expectEqual(store.chats(inSession: store.currentSessionID).count, 2)
        }

        test("a thread never spans two sittings") {
            // The measured risk: relaunch the app four minutes after the last question and the first
            // new one joins yesterday's thread, because the words pointed and the gap was short.
            var store = ConversationStore()
            let first = store.beginSession(starting: .launch, at: base)
            store.append(turn("explain this", "Explained", session: first.id))
            let second = store.beginSession(starting: .launch, at: base)
            store.append(turn("and this", minutes: 2, session: second.id))
            expectEqual(store.chats.count, 2, "a new sitting opened the old thread again")
            expectEqual(store.chats.last?.sessionID, second.id)
        }

        test("the boundaries survive the file") {
            var store = ConversationStore()
            store.beginSession(starting: .launch, at: base)
            store.append(turn("open whatsapp and search for sathvik", "Found Sathvik"))
            store.append(turn("type good night and leave it for me", "Ready to send", minutes: 3))
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("chats-\(UUID().uuidString).json")
            store.save(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let reloaded = ConversationStore.load(from: url)
            expectEqual(reloaded.chats.count, 1)
            expectEqual(reloaded.turns.count, 2)
            expectEqual(Set(reloaded.turns.compactMap(\.chatID)),
                        Set(reloaded.chats.map(\.id)),
                        "a turn pointing at a thread that is not in the file is a row that "
                        + "appears in no group at all")
        }

        test("a file of threads-less turns is grouped once and then kept") {
            // Migration: the shape before this level existed. Grouping runs over it, and the result
            // is stored — a boundary recomputed on each load would move under the cursor.
            let legacy = try! JSONEncoder().encode([
                turn("open whatsapp and search for sathvik", "Found Sathvik"),
                turn("type good night and leave it for me", "Ready to send", minutes: 3),
                turn("why is the certificate warning showing in chrome",
                     "Explained the warning", minutes: 40),
            ])
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("legacy-\(UUID().uuidString).json")
            try! legacy.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            let once = ConversationStore.load(from: url)
            expectEqual(once.chats.count, 2, "the migrated file should read as two threads")
            let twice = ConversationStore.load(from: url)
            expectEqual(twice.chats.map(\.title), once.chats.map(\.title),
                        "the same file grouped twice into two different trees")
        }

        test("the last turn of a thread takes the thread with it") {
            var store = ConversationStore()
            store.beginSession(starting: .launch, at: base)
            store.append(turn("why is the certificate warning showing", "Explained"))
            let kept = store.turns.first { $0.asked == "why is the certificate warning showing" }!
            store.remove(id: kept.id)
            expect(store.chats.isEmpty,
                   "an empty thread would render as a heading with nothing under it")
        }

        test("a thread knows its own span") {
            var store = ConversationStore()
            store.beginSession(starting: .launch, at: base)
            store.append(turn("open whatsapp and search for sathvik", "Found Sathvik"))
            store.append(turn("type good night and leave it for me", "Ready to send", minutes: 6))
            let span = store.span(ofChat: store.chats[0].id)
            expect(span != nil)
            expectEqual(store.turns(inChat: store.chats[0].id).count, 2,
                        "the transcript is the thread, not the row he clicked")
        }
    }
}
