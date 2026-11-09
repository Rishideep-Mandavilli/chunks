import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// Tests for scheduled routines.
///
/// The schedule arithmetic is the whole feature: a routine that fires twice, or fires at 03:00
/// because the laptop slept through 08:00, or replays forty missed intervals when the lid opens on
/// Monday, is a routine that spends the user's API budget and talks at them for no reason. All of
/// it is date maths, so all of it is testable without waiting for tomorrow.
public enum RoutinesStoreTests {

    /// A fixed calendar, so a test that says "Friday at 20:00" means the same thing in any
    /// timezone the machine happens to be in.
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

    private static func routine(title: String = "Standup brief",
                                cadence: Routine.Cadence = .daily(at: "08:00"),
                                enabled: Bool = true,
                                created: Date? = nil,
                                lastRun: Date? = nil) -> Routine {
        Routine(title: title, prompt: "what is on my screen right now", cadence: cadence,
                isEnabled: enabled, createdAt: created ?? date(2026, 10, 1), lastRunAt: lastRun)
    }

    public static func register() {
        TestRunner.currentSuite = "Routines"

        // AUDIT.md D-04: a tick blocked by an open card, a turn in flight or a sleeping display used
        // to advance the clock past the slot, and the next tick computed tomorrow — the whole day
        // silently lost. The question is now "has it run for this slot".
        test("a blocked tick does not lose the day's slot") {
            let r = routine(lastRun: date(2026, 11, 8, 8, 0))
            let now = date(2026, 11, 9, 8, 5)   // Monday, five minutes past the slot
            expectEqual(RoutinesStore.dueSlot(for: r, now: now, calendar: calendar),
                        date(2026, 11, 9, 8, 0),
                        "yesterday's run must not retire today's slot")
        }

        test("a slot already run for is not owed twice, and a second routine at the same hour still is") {
            let now = date(2026, 11, 9, 8, 5)
            let done = routine(lastRun: date(2026, 11, 9, 8, 0))
            expect(RoutinesStore.dueSlot(for: done, now: now, calendar: calendar) == nil,
                   "a routine that fired at 08:00 must not fire again at 08:05")
            let never = routine(title: "Second at the same hour")
            expectEqual(RoutinesStore.dueSlot(for: never, now: now, calendar: calendar),
                        date(2026, 11, 9, 8, 0),
                        "the one-per-tick break must not cost the second routine its day")
        }

        test("nothing is owed before the hour, and weekdays owe nothing on a Saturday") {
            let r = routine(cadence: .weekdays(at: "08:00"))
            expect(RoutinesStore.dueSlot(for: r, now: date(2026, 11, 9, 7, 59), calendar: calendar) == nil,
                   "07:59 is not 08:00")
            expect(RoutinesStore.dueSlot(for: r, now: date(2026, 11, 14, 8, 5), calendar: calendar) == nil,
                   "Saturday is not a weekday")
        }

        test("a routine added after its hour waits for tomorrow instead of firing retroactively") {
            // AUDIT.md R-05: "every morning at eight" said at 21:00 must not fire on the next tick.
            let fresh = routine(created: date(2026, 11, 9, 21, 0))
            expect(RoutinesStore.dueSlot(for: fresh, now: date(2026, 11, 9, 21, 5), calendar: calendar) == nil,
                   "a brand-new routine owes nothing for a slot before it existed")
            let old = routine(created: date(2026, 11, 1, 9, 0))
            expectEqual(RoutinesStore.dueSlot(for: old, now: date(2026, 11, 9, 21, 5), calendar: calendar),
                        date(2026, 11, 9, 8, 0),
                        "an existing routine still catches up on a slot a blocked tick missed")
        }

        test("a routine is refused with the sentence a user can act on") {
            let cases: [(String, String, Routine.Cadence, String)] = [
                ("", "brief the inbox", .daily(at: "08:00"), "needs a name"),
                (String(repeating: "x", count: 61), "brief the inbox", .daily(at: "08:00"), "60 characters"),
                ("Name", "   ", .daily(at: "08:00"), "needs something to ask"),
                ("Name", "brief", .daily(at: "7am"), "not a time like 07:30"),
                ("Name", "brief", .every(minutes: 5), "shortest interval"),
            ]
            for (title, prompt, cadence, expected) in cases {
                let rejection = RoutinesStore.validate(title: title, prompt: prompt,
                                                       cadence: cadence, existing: [])
                expect(rejection?.reason.contains(expected) == true,
                       "\"\(title)\" / \(cadence) refused with \"\(rejection?.reason ?? "accepted")\", wanted \"\(expected)\"")
            }
        }

        test("a valid routine is accepted and appears in the store") {
            var store = RoutinesStore()
            let result = store.add(title: "Standup brief",
                                   prompt: "read my calendar and tell me what today looks like",
                                   cadence: .weekdays(at: "09:15"))
            if case .failure(let rejection) = result {
                expect(false, "a good routine was refused: \(rejection.reason)")
                return
            }
            expectEqual(store.routines.count, 1)
            expectEqual(store.routines.first?.cadence.phrase, "Weekdays at 09:15")
        }

        test("two routines cannot share a name, in either case") {
            var store = RoutinesStore()
            _ = store.add(title: "Brief", prompt: "one", cadence: .daily(at: "08:00"))
            let clash = store.add(title: "brief", prompt: "two", cadence: .daily(at: "09:00"))
            if case .success = clash {
                expect(false, "a duplicate title was accepted; the panel would show two identical rows")
            }
        }

        test("the store is capped, so a model cannot fill it with routines") {
            var store = RoutinesStore()
            for index in 0..<RoutinesStore.maxRoutines {
                _ = store.add(title: "Routine \(index)", prompt: "ask", cadence: .daily(at: "08:00"))
            }
            expectEqual(store.routines.count, RoutinesStore.maxRoutines)
            let overflow = store.add(title: "One more", prompt: "ask", cadence: .daily(at: "08:00"))
            if case .failure(let rejection) = overflow {
                expect(rejection.reason.contains("at most"), "the cap must be said: \(rejection.reason)")
            } else {
                expect(false, "past the cap and still accepted")
            }
        }

        test("a daily routine fires today if its time is still ahead, tomorrow if not") {
            let morning = routine(cadence: .daily(at: "08:00"))
            let before = RoutinesStore.nextFireDate(for: morning, now: date(2026, 10, 21, 7, 30),
                                                    calendar: calendar)!
            expectEqual(calendar.component(.hour, from: before), 8)
            expectEqual(calendar.component(.day, from: before), 21, "07:30 is before 08:00 today")

            let after = RoutinesStore.nextFireDate(for: morning, now: date(2026, 10, 21, 9, 0),
                                                   calendar: calendar)!
            expectEqual(calendar.component(.day, from: after), 22,
                        "yesterday's slot must not be offered as today's")
        }

        test("a weekday routine skips the weekend") {
            let weekdays = routine(cadence: .weekdays(at: "08:00"))
            // 2026-10-23 is a Friday; 08:00 has passed, so the next run is Monday the 26th.
            let next = RoutinesStore.nextFireDate(for: weekdays, now: date(2026, 10, 23, 20, 0),
                                                  calendar: calendar)!
            expectEqual(calendar.component(.day, from: next), 26,
                        "a Friday-evening weekday routine must not fire on Saturday")
            expect(RoutinesStore.isWeekday(next, calendar: calendar))
        }

        test("a disabled routine is never due") {
            expect(RoutinesStore.nextFireDate(for: routine(enabled: false),
                                              now: date(2026, 10, 21, 7, 0), calendar: calendar) == nil,
                   "a switched-off routine that still fires is not switched off")
        }

        test("a laptop asleep for a week owes one run, not forty") {
            let interval = routine(cadence: .every(minutes: 30),
                                   created: date(2026, 10, 1, 9, 0),
                                   lastRun: date(2026, 10, 1, 9, 0))
            let next = RoutinesStore.nextFireDate(for: interval, now: date(2026, 10, 8, 12, 0),
                                                  calendar: calendar)!
            expect(next > date(2026, 10, 8, 12, 0),
                   "the next run must be in the future or the loop fires on every tick")
            let minutes = next.timeIntervalSince(date(2026, 10, 8, 12, 0)) / 60
            expect(minutes <= 30, "it should resume on the interval, not replay a week: \(minutes) min out")
        }

        test("the soonest routine is the one reported") {
            var store = RoutinesStore(routines: [
                routine(title: "Late", cadence: .daily(at: "21:00")),
                routine(title: "Soon", cadence: .daily(at: "08:00")),
            ])
            let due = store.nextDue(after: date(2026, 10, 21, 6, 0), calendar: calendar)
            expectEqual(due?.routine.title, "Soon")
            store.setEnabled(false, id: store.routines[1].id)
            expectEqual(store.nextDue(after: date(2026, 10, 21, 6, 0), calendar: calendar)?.routine.title,
                        "Late", "a disabled routine must not hold the schedule open")
        }

        test("a hand-edited file keeps what is still valid and drops what is not") {
            let good = routine(title: "Keep me")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let broken = Routine(title: "", prompt: "", cadence: .daily(at: "nope"))
            let data = try! encoder.encode([good, broken])
            let loaded = RoutinesStore.decode(data)
            expectEqual(loaded.count, 1,
                        "one mistyped line must not cost the user every routine they have")
            expectEqual(loaded.first?.title, "Keep me")
        }

        test("a corrupt file loads as empty rather than crashing the panel") {
            expect(RoutinesStore.decode(Data("not json at all".utf8)).isEmpty,
                   "a half-written file must not take the app down on launch")
        }

        test("a stored round trip survives the edit operations") {
            var store = RoutinesStore()
            let added = try? store.add(title: "Evening", prompt: "what did I miss",
                                       cadence: .daily(at: "18:30")).get()
            expect(added != nil)
            guard let data = store.encoded() else {
                expect(false, "the store could not encode what it just accepted"); return
            }
            var reloaded = RoutinesStore(routines: RoutinesStore.decode(data))
            expectEqual(reloaded.routines.first?.cadence, .daily(at: "18:30"))
            expect(reloaded.remove(id: reloaded.routines[0].id))
            expectEqual(reloaded.routines.count, 0)
            expect(!reloaded.remove(id: UUID()), "deleting something that is not there says so")
        }
    }
}
