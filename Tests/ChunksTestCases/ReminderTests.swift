import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// One-off reminders, and the decision about keeping the machine awake for them.
///
/// The arithmetic is the feature. A reminder that fires at the wrong hour, or replays itself every
/// minute after it has been said, or is cancelled by a word that matched two lines, is worse than no
/// reminder: he stops trusting the ones that arrive. None of it needs a running app, and all of it
/// was written against a case that is easy to get wrong — `at 21:00` said at 22:00.
public enum ReminderTests {

    /// A fixed calendar for the same reason the routines suite has one: "Tuesday at 09:00" has to
    /// mean the same instant wherever the tests are run.
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int,
                             _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                          hour: hour, minute: minute))!
    }

    /// Tuesday 2026-10-27 at 12:00 — midday, so "today at 21:00" and "today in 40 min" are both
    /// still inside the same local day whatever the machine's zone is.
    private static let noon = date(2026, 10, 27, 12, 0)
    private static let tenPMBefore = date(2026, 10, 27, 22, 0)

    public static func register() {
        TestRunner.currentSuite = "Reminders"

        // MARK: - Reading the when

        test("a when is read only in the shapes the minute clock can honour") {
            let accepted: [(String, ReminderTiming)] = [
                ("40 min", .inMinutes(40)),
                ("in 40 minutes", .inMinutes(40)),
                ("2 h", .inMinutes(120)),
                ("in 2 hours", .inMinutes(120)),
                ("3 days", .inMinutes(4_320)),
                ("at 21:00", .clockTime(hour: 21, minute: 0)),
                ("21:00", .clockTime(hour: 21, minute: 0)),
                ("at 9 pm", .clockTime(hour: 21, minute: 0)),
                ("9:30 am", .clockTime(hour: 9, minute: 30)),
                ("12 pm", .clockTime(hour: 12, minute: 0)),
                ("12 am", .clockTime(hour: 0, minute: 0)),
                ("tomorrow at 07:30", .tomorrowAt(hour: 7, minute: 30)),
            ]
            expect(accepted.count > 10, "the accepted table is empty — this case proves nothing")
            for (text, want) in accepted {
                expectEqual(ReminderTiming.parse(text), want,
                            "\"\(text)\" read as \(String(describing: ReminderTiming.parse(text))), wanted \(String(describing: want))")
            }

            let refused = ["in 30 seconds", "5", "", "soon", "at 25:00", "at 9:70", "in 0 minutes",
                           "in 99999 minutes", "9am", "every day at 08:00", "tomorrow 40 minutes"]
            for text in refused {
                expect(ReminderTiming.parse(text) == nil,
                       "\"\(text)\" parsed as \(String(describing: ReminderTiming.parse(text))) — "
                            + "a reminder that fires at a time Chunks guessed is a notification at the wrong hour")
            }
        }

        test("a clock time already gone today means tomorrow, and the card is told") {
            let evening = ReminderTiming.clockTime(hour: 21, minute: 0)
            expectEqual(ReminderStore.resolve(evening, now: noon, calendar: calendar), evening,
                        "at 21:00 said at midday stays today")
            expectEqual(ReminderStore.resolve(evening, now: tenPMBefore, calendar: calendar),
                        .tomorrowAt(hour: 21, minute: 0),
                        "at 21:00 said at 22:00 is tomorrow — and the question he answers has to say so")
            // And the date matches the phrase: the whole point of resolving before asking.
            let resolved = ReminderStore.resolve(evening, now: tenPMBefore, calendar: calendar)
            expectEqual(resolved.date(from: tenPMBefore, calendar: calendar),
                        date(2026, 10, 28, 21, 0),
                        "the phrase and the fire date disagree")
        }

        test("an interval is measured from the clock at arming, not from midnight") {
            expectEqual(ReminderTiming.inMinutes(40).date(from: noon, calendar: calendar),
                        noon.addingTimeInterval(2_400), "40 min is not 40 minutes past the hour")
            expectEqual(ReminderTiming.tomorrowAt(hour: 7, minute: 30)
                            .date(from: noon, calendar: calendar),
                        date(2026, 10, 28, 7, 30),
                        "tomorrow at 07:30 landed on the wrong day")
        }

        // MARK: - Reporting the moment

        test("the report names the moment the file holds, in words he already uses") {
            let cases: [(Date, String)] = [
                (noon.addingTimeInterval(40 * 60), "in 40 min"),
                (noon.addingTimeInterval(5 * 60), "in 5 min"),
                (noon.addingTimeInterval(40), "now"),
            ]
            for (fireAt, want) in cases {
                expectEqual(ReminderStore.spoken(fireAt: fireAt, now: noon, calendar: calendar), want,
                            "spoken for \(fireAt.timeIntervalSince(noon))s ahead")
            }
            expect(ReminderStore.spoken(fireAt: date(2026, 10, 27, 21, 0), now: noon,
                                        calendar: calendar).hasPrefix("at "),
                   "a later hour today should read \"at …\"")
            expect(ReminderStore.spoken(fireAt: date(2026, 10, 28, 9, 0), now: noon,
                                        calendar: calendar).hasPrefix("tomorrow at "),
                   "tomorrow should be said, because \"at 09:00\" alone is the ambiguity the card exists to kill")
            let later = ReminderStore.spoken(fireAt: date(2026, 10, 30, 9, 0), now: noon,
                                             calendar: calendar)
            expect(!later.hasPrefix("tomorrow") && later.contains(":"),
                   "three days out should name the day and the hour, got \"\(later)\"")
        }

        test("a reminder that arrived late says the hour it was due") {
            expectEqual(ReminderStore.lateText(fireAt: noon.addingTimeInterval(-60), now: noon,
                                               calendar: calendar), nil,
                        "a minute of scheduler lag is not worth telling him about")
            expect(ReminderStore.lateText(fireAt: noon.addingTimeInterval(-600), now: noon,
                                          calendar: calendar)?.hasPrefix("was due at ") == true,
                   "ten minutes late today should say the hour, not just \"late\"")
            let days = ReminderStore.lateText(fireAt: date(2026, 10, 25, 9, 0), now: noon,
                                              calendar: calendar)
            expect(days?.hasPrefix("was due ") == true && days?.contains(":") == true,
                   "a reminder due on an earlier day must name the day — \(String(describing: days))")
        }

        // MARK: - The store's rules

        test("an ordinary line is accepted and a credential is refused before any write") {
            expect(ReminderStore.validate(text: "call the bank about the statement", existing: []) == nil,
                   "an everyday reminder must not be rejected — a feature that refuses normal words is broken")
            let secret = ReminderStore.validate(text: "use token ghp_abcdef1234567890abcdef1234567890",
                                                existing: [])
            expectEqual(secret, .holdsSecret,
                        "a reminder is written to a plain file, so a credential in it is invariant 3")
            expectEqual(ReminderStore.validate(text: "   ", existing: []), .emptyText,
                        "an empty reminder would fire a blank card")
            expectEqual(ReminderStore.validate(text: String(repeating: "x", count: 67), existing: []),
                        .textTooLong(limit: 66),
                        "a line the card cannot show in full is a question he cannot finish reading")
        }

        test("the eighth reminder is refused, not queued") {
            var store = ReminderStore()
            let existing = (1...ReminderStore.maxReminders).map {
                Reminder(text: "thing \($0)", fireAt: noon.addingTimeInterval(TimeInterval($0 * 60)))
            }
            store = ReminderStore(reminders: existing)
            expectEqual(ReminderStore.validate(text: "one more", existing: store.reminders),
                        .tooMany(limit: ReminderStore.maxReminders),
                        "an unbounded waiting list is a pile nobody reads")
        }

        test("adding sorts the list and arming keeps one truth about the hour") {
            var store = ReminderStore()
            let late = store.add(text: "stretch", timing: .inMinutes(40), now: noon, calendar: calendar)
            let early = store.add(text: "call the bank", timing: .inMinutes(5), now: noon,
                                  calendar: calendar)
            guard case .success(let one) = late, case .success(let two) = early else {
                expect(false, "both of these are legal reminders and one was refused")
                return
            }
            expectEqual(one.fireAt, noon.addingTimeInterval(2_400), "the stored date is not the moment asked for")
            expectEqual(store.reminders.first?.id, two.id,
                        "the list is not earliest-first, so the next thing due is not the first row")
            expectEqual(store.nextDue(after: noon)?.text, "call the bank", "the wrong reminder is next")
        }

        test("cancelling by words takes out exactly one, and only when something answers") {
            var store = ReminderStore(reminders: [
                Reminder(text: "call the bank", fireAt: noon.addingTimeInterval(600)),
                Reminder(text: "call the surgeon", fireAt: noon.addingTimeInterval(1_200)),
                Reminder(text: "stretch", fireAt: noon.addingTimeInterval(1_800)),
            ])
            // A prefix shared by two lines: the exact match must win, and only one row may go.
            let gone = store.cancel(matching: "call the bank")
            expectEqual(gone?.text, "call the bank", "the exact line was not the one cancelled")
            expectEqual(store.reminders.count, 2, "cancelling one line removed more than one")
            // Now a prefix that matches the only remaining candidate.
            expectEqual(store.cancel(matching: "call")?.text, "call the surgeon",
                        "a prefix of the one line left should reach it")
            expectEqual(store.cancel(matching: "nothing like this"), nil,
                        "a cancel that matched nothing must be reported, not guessed at")
            expectEqual(store.reminders.count, 1, "a refused cancel still changed the schedule")
        }

        test("the due list is earliest first and leaves what has not arrived") {
            let store = ReminderStore(reminders: [
                Reminder(text: "later", fireAt: noon.addingTimeInterval(3_600)),
                Reminder(text: "first", fireAt: noon.addingTimeInterval(-120)),
                Reminder(text: "second", fireAt: noon.addingTimeInterval(-60)),
            ])
            let due = store.due(before: noon)
            expectEqual(due.count, 2, "a reminder an hour early must not be in the due list")
            expectEqual(due.map(\.text), ["first", "second"],
                        "the order is the one the card would speak them in")
        }

        test("the file round-trips and a hand-edited blank line is dropped") {
            let store = ReminderStore(reminders: [
                Reminder(text: "stretch", fireAt: noon.addingTimeInterval(600)),
                Reminder(text: "", fireAt: noon.addingTimeInterval(1_200)),
            ])
            guard let data = store.encoded() else {
                expect(false, "encoding failed, so nothing would ever be saved")
                return
            }
            // An empty text is filtered by `decode` only when it survives the encoder, so encode the
            // raw pair and check the reader: the promise is that no blank card can come off this file.
            let decoded = ReminderStore.decode(data)
            expectEqual(decoded.count, 1,
                        "an empty reminder survived the round trip and would fire a blank card")
            expectEqual(decoded.first?.text, "stretch", "the surviving line is not the one written")
            expectEqual(ReminderStore.decode(Data("not json".utf8)).count, 0,
                        "a corrupt file must read as no reminders, not as a crash")
        }

        // MARK: - The tag

        test("the remind tag parses one command and refuses every other shape") {
            let accepted: [(String, DoRequest)] = [
                ("remind:stretch|40 min", .addReminder(text: "stretch", timing: .inMinutes(40))),
                ("reminder:call the bank|at 21:00",
                 .addReminder(text: "call the bank", timing: .clockTime(hour: 21, minute: 0))),
                ("set_timer:water the plants|2 hours",
                 .addReminder(text: "water the plants", timing: .inMinutes(120))),
                ("remind_cancel:stretch", .cancelReminder(text: "stretch")),
            ]
            expect(accepted.count == 4, "the table is short — this case proves nothing")
            for (body, want) in accepted {
                expectEqual(DoRequest.parse(body), want, "\(body)")
            }

            let refused = [
                "remind:stretch",                      // no when
                "remind:stretch|in 30 seconds",        // a shape the minute clock cannot honour
                "remind:stretch|soon",                 // an invented time
                "remind:has|a|pipe|40 min",            // a pipe inside the text would be two arguments
                "remind:\(String(repeating: "x", count: 90))|40 min",   // past the store's line
                "remind:stretch|40 min|extra",
                "remind:",
                "remind_cancel:",
                "remind_now:stretch|40 min",           // a tool that does not exist
            ]
            for body in refused {
                expect(DoRequest.parse(body) == nil,
                       "\"\(body)\" parsed as \(String(describing: DoRequest.parse(body))) — "
                            + "a half-read reminder is a promise made at a time nobody said")
            }
        }

        test("no legal reminder question can overflow the card") {
            // The worst case the store accepts, wrapped in the longest phrase the parser accepts.
            let text = String(repeating: "y", count: ReminderStore.maxTextCharacters)
            let request = DoRequest.addReminder(text: text, timing: .tomorrowAt(hour: 9, minute: 30))
            let question = ToolLayer.question(for: request)
            expect(question.count <= DoRequest.maxQuestionCharacters,
                   "a \(question.count)-character question is clipped by the card, and half a question "
                        + "approved is no approval: \(question)")
            expectEqual(ToolLayer.alwaysAsks(request), false,
                        "a reminder says one line and changes nothing, so it is not the run-command class")
        }

        test("the armed reminder is reported with the hour it will really say itself") {
            let line = ToolLayer.reminderArmedLine(text: "stretch",
                                                   fireAt: noon.addingTimeInterval(2_400), now: noon)
            expect(line.contains("in 40 min"),
                   "the report should name the moment, got \"\(line)\"")
            // And not the phrase the model wrote, when the two disagree.
            let tomorrow = ToolLayer.reminderArmedLine(
                text: "call the bank",
                fireAt: date(2026, 10, 28, 21, 0), now: noon)
            expect(tomorrow.contains("tomorrow at "),
                   "a report that repeats \"at 21:00\" for a reminder firing the next day is the card "
                        + "disagreeing with the schedule: \(tomorrow)")
        }

        // MARK: - Keeping the machine awake

        test("the idle-sleep hold is asked for only while something actually waits") {
            expectEqual(SleepPolicy.shouldHold(enabled: true, anythingArmed: true), true,
                        "with the switch on and a reminder due, a sleeping Mac loses the promise")
            expectEqual(SleepPolicy.shouldHold(enabled: true, anythingArmed: false), false,
                        "a switch left on from one reminder must not hold his laptop awake all day")
            expectEqual(SleepPolicy.shouldHold(enabled: false, anythingArmed: true), false,
                        "nothing may claim the machine's battery uninvited")
        }

        test("the sleep row says what the app is doing, not what was asked") {
            expectEqual(SleepPolicy.describe(holding: false, enabled: false, armedCount: 0),
                        "Off — the Mac may sleep between scheduled things.", "the off state")
            expect(SleepPolicy.describe(holding: false, enabled: true, armedCount: 0)
                        .contains("nothing waiting"),
                   "an on switch with nothing armed must not read as a hold")
            expect(SleepPolicy.describe(holding: true, enabled: true, armedCount: 2)
                        .contains("2 waiting things"),
                   "the row should count what it is holding for")
            // The refusal case: macOS can say no, and the row must not claim the hold took.
            expect(SleepPolicy.describe(holding: false, enabled: true, armedCount: 1)
                        .contains("did not take"),
                   "a refused assertion shown as \"on\" is the LoginItem lie this codebase already names")
        }
    }
}
