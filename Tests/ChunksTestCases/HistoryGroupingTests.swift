import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// Which thread sits under which heading — the window's whole organisation, tested apart from the
/// pixels that draw it.
///
/// The failure modes here are invisible rather than loud: a thread that spans midnight filed under
/// the day it started (so it is not where he looks for it), a sitting boundary on every row instead
/// of one, an empty sitting rendering as a heading with nothing under it. Each one leaves the list
/// looking plausible.
public enum HistoryGroupingTests {

    /// A fixed "now", because every case here is about how far back a row is.
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)   // a Sunday, 08:00 UTC

    private static func daysAgo(_ days: Double) -> TimeInterval { days * 24 * 3600 }
    private static func hoursAgo(_ hours: Double) -> TimeInterval { hours * 3600 }
    private static func minutesAgo(_ minutes: Double) -> TimeInterval { minutes * 60 }

    /// A store built by hand, so the sittings, the threads and the timestamps are exactly the ones
    /// the case is about. `ConversationStore(turns:sessions:chats:)` is the door the file loader uses.
    private struct Fixture {
        private var turns: [ConversationTurn] = []
        private var chats: [ConversationChat] = []
        private var sessions: [ConversationSession] = []

        private func date(_ since: TimeInterval) -> Date {
            now.addingTimeInterval(-since)
        }

        mutating func session(_ start: ConversationSession.Start,
                              since: TimeInterval) -> ConversationSession {
            let session = ConversationSession(id: UUID(), startedAt: date(since), start: start)
            sessions.append(session)
            return session
        }

        @discardableResult
        mutating func thread(_ title: String, in session: ConversationSession,
                             since: TimeInterval) -> ConversationChat {
            let chat = ConversationChat(id: UUID(), sessionID: session.id,
                                        startedAt: date(since), title: title)
            chats.append(chat)
            return chat
        }

        mutating func exchange(_ asked: String, _ answered: String, since: TimeInterval,
                               in chat: ConversationChat, acts: [String] = []) {
            turns.append(ConversationTurn(asked: asked, answered: answered, headline: answered,
                                          at: date(since), acts: acts,
                                          sessionID: chat.sessionID, chatID: chat.id))
        }

        func store() -> ConversationStore {
            ConversationStore(turns: turns, sessions: sessions, chats: chats,
                              currentSessionID: sessions.last?.id,
                              currentChatID: chats.last?.id)
        }
    }

    public static func register() {
        TestRunner.currentSuite = "History list"

        test("a day heading is the day the thread was last spoken about") {
            // A question at 23:56 and its follow-up eight minutes later cross midnight together. He
            // looks for that conversation under the day he finished it in — filing it under the day
            // it began hides it behind everything from a day he thinks of as over.
            var fix = Fixture()
            let lastNight = fix.session(.launch, since: hoursAgo(9))
            let thread = fix.thread("The certificate warning", in: lastNight, since: hoursAgo(9))
            fix.exchange("why is the certificate warning showing", "It is Chrome's own clock.",
                         since: hoursAgo(9), in: thread)                    // yesterday 23:00
            fix.exchange("what about the second line", "The issuer is expired.",
                         since: hoursAgo(8), in: thread)                    // today 00:00

            let days = HistoryGrouping.days(store: fix.store(), now: now)
            expectEqual(days.first?.label, "Today",
                        "a thread whose last word was said after midnight belongs to today")
            expectEqual(days.count, 1, "one thread cannot be two day groups")
        }

        test("today is today and yesterday is yesterday") {
            for (since, want) in [(minutesAgo(30), "Today"), (hoursAgo(26), "Yesterday")] {
                var fix = Fixture()
                let s = fix.session(.launch, since: since)
                let t = fix.thread("Anything", in: s, since: since)
                fix.exchange("anything", "Something.", since: since, in: t)
                let days = HistoryGrouping.days(store: fix.store(), now: now)
                expectEqual(days.first?.label, want,
                            "a row \(Int(since / 60)) minutes old was not filed where he would look")
            }
            var older = Fixture()
            let s = older.session(.launch, since: daysAgo(4))
            let t = older.thread("Anything", in: s, since: daysAgo(4))
            older.exchange("anything", "Something.", since: daysAgo(4), in: t)
            // Four days back is still this week on a Sunday, so the list names the weekday instead.
            expect(HistoryGrouping.days(store: older.store(), now: now).first?.label != "Today",
                   "a day that is not today must not be labelled as if it were")
        }

        test("one boundary line per earlier sitting, and none above the current one") {
            var fix = Fixture()
            let morning = fix.session(.wake, since: hoursAgo(7))
            let log = fix.thread("The build log", in: morning, since: hoursAgo(7))
            fix.exchange("what failed in build.log", "Signing.", since: hoursAgo(7), in: log)
            let card = fix.thread("The notch card", in: morning, since: hoursAgo(6))
            fix.exchange("why is the card short", "Height.", since: hoursAgo(6), in: card)
            let sitting = fix.session(.manual, since: minutesAgo(40))
            let chat = fix.thread("WhatsApp", in: sitting, since: minutesAgo(40))
            fix.exchange("open whatsapp", "It is open.", since: minutesAgo(40), in: chat)

            let rows = HistoryGrouping.days(store: fix.store(), now: now).flatMap(\.threads)
            expectEqual(rows.count, 3, "three threads were built and the list lost one")
            let labelled = rows.compactMap(\.earlierSitting)
            expectEqual(labelled.count, 1,
                        "a boundary on every row is the tree this design replaced")
            expect(labelled.first?.contains("started when the Mac woke") == true,
                   "the line has to say why a sitting ended, not just that it did")
            // The line belongs on the *oldest* thread of that sitting, because everything below it
            // reads as belonging to the sitting the line names.
            expectEqual(rows.last?.title, "The build log",
                        "the boundary sat on the wrong row, so it separates the wrong half of the list")
            expect(rows.last?.earlierSitting != nil,
                   "the oldest thread of the older sitting is the one carrying the line")
            expectEqual(rows.first?.earlierSitting, nil,
                        "the newest sitting has nothing above it to separate")
        }

        test("newest first inside a day, and days newest first") {
            var fix = Fixture()
            let yesterday = fix.session(.launch, since: hoursAgo(30))
            let old = fix.thread("Yesterday's thread", in: yesterday, since: hoursAgo(30))
            fix.exchange("what is this", "Old.", since: hoursAgo(30), in: old)
            let today = fix.session(.launch, since: hoursAgo(5))
            let early = fix.thread("The earlier one today", in: today, since: hoursAgo(5))
            fix.exchange("explain the pdf", "Page two.", since: hoursAgo(5), in: early)
            let late = fix.thread("The later one today", in: today, since: minutesAgo(60))
            fix.exchange("and now this", "Done.", since: minutesAgo(60), in: late)

            let days = HistoryGrouping.days(store: fix.store(), now: now)
            expectEqual(days.count, 2, "yesterday and today are two groups")
            expectEqual(days.first?.label, "Today")
            expectEqual(days.first?.threads.first?.title, "The later one today",
                        "a list that opens with the oldest thread of the day is read upside down")
            expectEqual(days.last?.label, "Yesterday")
        }

        test("the row says what happened in the thread, including nothing") {
            var fix = Fixture()
            let s = fix.session(.launch, since: hoursAgo(2))
            let quiet = fix.thread("A question only", in: s, since: hoursAgo(2))
            fix.exchange("what does this screen say", "A table.", since: hoursAgo(2), in: quiet)
            let busy = fix.thread("A plan", in: s, since: minutesAgo(70))
            fix.exchange("open it and click send", "Sent.", since: minutesAgo(70), in: busy,
                         acts: ["Pressed Send.", "Typed \"hi\"."])

            let rows = HistoryGrouping.days(store: fix.store(), now: now).flatMap(\.threads)
            expectEqual(rows.count, 2, "both threads must be listed")
            let quietRow = rows.first { $0.id == quiet.id }
            let busyRow = rows.first { $0.id == busy.id }
            expect(quietRow?.detail.contains("act") == false,
                   "\"1 exchange · 06:00\" is the whole story; an act count of zero is noise")
            expect(busyRow?.detail.contains("2 acts") == true,
                   "a thread that moved the pointer has to say so — it is what he is looking for")
            expect(quietRow?.detail.contains("1 exchange") == true,
                   "one exchange, not one exchanges")
        }

        test("an open thread is marked, and only one thread is open") {
            var fix = Fixture()
            let s = fix.session(.launch, since: hoursAgo(2))
            let first = fix.thread("First", in: s, since: hoursAgo(2))
            fix.exchange("first", "One.", since: hoursAgo(2), in: first)
            let second = fix.thread("Second", in: s, since: minutesAgo(60))
            fix.exchange("second", "Two.", since: minutesAgo(60), in: second)

            let rows = HistoryGrouping.days(store: fix.store(), now: now).flatMap(\.threads)
            expectEqual(rows.filter(\.open).count, 1,
                        "two rows marked ongoing is two places new questions could land")
            expect(rows.first { $0.open }?.id == second.id,
                   "the open thread is the newest one, not the newest row of a day")
        }

        test("a sitting with no threads contributes no rows and no boundary") {
            var fix = Fixture()
            let used = fix.session(.launch, since: hoursAgo(5))
            let t = fix.thread("Asked once", in: used, since: hoursAgo(5))
            fix.exchange("asked once", "Answered.", since: hoursAgo(5), in: t)
            _ = fix.session(.manual, since: minutesAgo(60))     // pressed the button, said nothing
            _ = fix.session(.wake, since: minutesAgo(30))       // woke, said nothing

            let days = HistoryGrouping.days(store: fix.store(), now: now)
            expectEqual(days.flatMap(\.threads).count, 1,
                        "an empty sitting must not become a heading with nothing under it")
            expectEqual(days.flatMap(\.threads).first?.earlierSitting, nil,
                        "and must not put a boundary line on a thread it never held")
        }

        test("the same file renders the same list twice") {
            var fix = Fixture()
            let a = fix.session(.wake, since: hoursAgo(6))
            let ta = fix.thread("One", in: a, since: hoursAgo(6))
            fix.exchange("one", "First.", since: hoursAgo(6), in: ta)
            let b = fix.session(.manual, since: hoursAgo(3))
            let tb = fix.thread("Two", in: b, since: hoursAgo(3))
            fix.exchange("two", "Second.", since: hoursAgo(3), in: tb)
            let store = fix.store()
            expectEqual(HistoryGrouping.days(store: store, now: now),
                        HistoryGrouping.days(store: store, now: now),
                        "a list that re-orders itself between two reads moves under his cursor")
        }
    }
}
