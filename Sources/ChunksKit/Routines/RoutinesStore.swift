import Foundation

/// Something Chunks should ask itself, on a schedule.
///
/// A routine is a *prompt with a time attached*, not a script: when it fires it goes through the
/// same turn a spoken question goes through, which means it sees the screen then, gets an answer
/// spoken and drawn, and — critically — still has to ask before it presses anything. A routine that
/// could act unattended would be a remote control for the machine, left running by a model that
/// guessed wrong at 07:30 while nobody was looking.
public struct Routine: Equatable, Sendable, Codable, Identifiable {

    public enum Cadence: Equatable, Sendable, Codable {
        /// Every day at "HH:mm".
        case daily(at: String)
        /// Monday to Friday at "HH:mm".
        case weekdays(at: String)
        /// Every N minutes from whenever it was created or last ran.
        case every(minutes: Int)

        /// The line the panel shows.
        public var phrase: String {
            switch self {
            case .daily(let at): return "Every day at \(at)"
            case .weekdays(let at): return "Weekdays at \(at)"
            case .every(let minutes):
                return minutes < 60 ? "Every \(minutes) min" : "Every \(minutes / 60) h"
            }
        }

        /// The same words with a lower-case first letter, for the middle of a card's sentence.
        ///
        /// A card reading `Add "Morning glance" — Every day at 08:00 — …` looks like three labels
        /// stapled together; the sentence form is what makes it one question.
        public var inSentence: String {
            guard let first = phrase.first else { return phrase }
            return String(first).lowercased() + phrase.dropFirst()
        }
    }

    public var id: UUID
    public var title: String
    /// What Chunks is asked when the routine fires. This is the whole payload: the turn it starts
    /// can read the screen, explain it, and propose acts.
    public var prompt: String
    public var cadence: Cadence
    public var isEnabled: Bool
    public var createdAt: Date
    public var lastRunAt: Date?

    public init(id: UUID = UUID(), title: String, prompt: String, cadence: Cadence,
                isEnabled: Bool = true, createdAt: Date = Date(), lastRunAt: Date? = nil) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.cadence = cadence
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
    }
}

/// Why a routine was not accepted. Said as a sentence because it goes on the card and into the
/// panel row, and a user who is told "invalid" learns nothing.
public enum RoutineRejection: Equatable, Sendable, Error {
    case emptyTitle
    case titleTooLong(limit: Int)
    case emptyPrompt
    case promptTooLong(limit: Int)
    case intervalTooShort(minimumMinutes: Int)
    case badTime(String)
    case tooMany(limit: Int)
    case duplicateTitle(String)

    public var reason: String {
        switch self {
        case .emptyTitle: return "A routine needs a name."
        case .titleTooLong(let limit): return "That name is longer than \(limit) characters."
        case .emptyPrompt: return "A routine needs something to ask."
        case .promptTooLong(let limit): return "That question is longer than \(limit) characters."
        case .intervalTooShort(let minimum): return "The shortest interval is \(minimum) minutes."
        case .badTime(let given): return "\"\(given)\" is not a time like 07:30."
        case .tooMany(let limit): return "Chunks keeps \(limit) routines at most."
        case .duplicateTitle(let title): return "There is already a routine called \"\(title)\"."
        }
    }
}

/// The routines, on disk, and the arithmetic of when the next one is due.
///
/// Deliberately a plain JSON file rather than a `launchd` plist, and an in-process timer rather
/// than the OS scheduler. A `launchd` job runs whether or not Chunks is open, and so would fire a
/// screen capture and a model call into a machine whose owner is not there; an in-process schedule
/// stops when the app stops, which is the honest reading of "my assistant reminds me". The
/// launch-at-login row is what makes that a feature rather than a limitation.
public struct RoutinesStore: Equatable, Sendable {

    public static let maxRoutines = 12
    public static let maxTitleCharacters = 60
    public static let maxPromptCharacters = 400
    /// Below this, an "interval" routine is a busy loop that spends the user's API budget.
    public static let minIntervalMinutes = 15

    public private(set) var routines: [Routine]

    public init(routines: [Routine] = []) {
        self.routines = routines
    }

    // MARK: - Validation

    /// The rules are one function so the panel, the file loader and the model's proposal all
    /// refuse for the same reason.
    public static func validate(title: String, prompt: String, cadence: Routine.Cadence,
                                existing: [Routine]) -> RoutineRejection? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanTitle.isEmpty { return .emptyTitle }
        if cleanTitle.count > maxTitleCharacters { return .titleTooLong(limit: maxTitleCharacters) }
        if cleanPrompt.isEmpty { return .emptyPrompt }
        if cleanPrompt.count > maxPromptCharacters {
            return .promptTooLong(limit: maxPromptCharacters)
        }
        if existing.contains(where: { $0.title.lowercased() == cleanTitle.lowercased() }) {
            return .duplicateTitle(cleanTitle)
        }
        if existing.count >= maxRoutines { return .tooMany(limit: maxRoutines) }
        switch cadence {
        case .every(let minutes):
            guard minutes >= minIntervalMinutes else {
                return .intervalTooShort(minimumMinutes: minIntervalMinutes)
            }
        case .daily(let at), .weekdays(let at):
            guard timeOfDay(from: at) != nil else { return .badTime(at) }
        }
        return nil
    }

    /// `HH:mm` in any spacing, with a leading zero optional. Returns the hour and minute, or nil.
    public static func timeOfDay(from text: String) -> (hour: Int, minute: Int)? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        return (hour, minute)
    }

    // MARK: - Mutation

    /// Add, or refuse with the reason. Never clamps a value into range instead.
    public mutating func add(title: String, prompt: String, cadence: Routine.Cadence) -> Result<Routine, RoutineRejection> {
        if let rejection = Self.validate(title: title, prompt: prompt, cadence: cadence,
                                         existing: routines) {
            return .failure(rejection)
        }
        let routine = Routine(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                              prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                              cadence: cadence)
        routines.append(routine)
        return .success(routine)
    }

    public mutating func remove(id: UUID) -> Bool {
        let before = routines.count
        routines.removeAll { $0.id == id }
        return routines.count != before
    }

    @discardableResult
    public mutating func setEnabled(_ enabled: Bool, id: UUID) -> Bool {
        guard let index = routines.firstIndex(where: { $0.id == id }) else { return false }
        routines[index].isEnabled = enabled
        return true
    }

    public mutating func markRun(id: UUID, at date: Date) {
        guard let index = routines.firstIndex(where: { $0.id == id }) else { return }
        routines[index].lastRunAt = date
    }

    // MARK: - When

    /// The next moment this routine is due after `now`, or nil when it never will be.
    ///
    /// Pure and calendar-based on purpose: DST, a machine asleep at the firing minute, and "the app
    /// was closed when it was due" all come out of `Calendar` plus a comparison, and each one is
    /// testable without waiting for tomorrow.
    public static func nextFireDate(for routine: Routine, now: Date,
                                    calendar: Calendar = .current) -> Date? {
        guard routine.isEnabled else { return nil }
        switch routine.cadence {
        case .every(let minutes):
            let anchor = routine.lastRunAt ?? routine.createdAt
            let interval = TimeInterval(minutes * 60)
            var next = anchor.addingTimeInterval(interval)
            // A machine asleep for three days owes one run, not forty: the schedule resumes from
            // now rather than replaying every interval that passed in the dark.
            if next < now {
                let missed = now.timeIntervalSince(next) / interval
                next = next.addingTimeInterval((floor(missed) + 1) * interval)
            }
            return next

        case .daily(let at), .weekdays(let at):
            guard let (hour, minute) = timeOfDay(from: at),
                  let first = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now)
            else { return nil }
            let weekdaysOnly: Bool
            if case .weekdays = routine.cadence { weekdaysOnly = true } else { weekdaysOnly = false }

            // Today if its time is still ahead, tomorrow otherwise; then step a day at a time so a
            // Friday-evening weekdays routine lands on Monday. Seven steps is a week plus a day, so
            // the loop can only end by returning or by a calendar that cannot add a day.
            var day = first > now ? first : (calendar.date(byAdding: .day, value: 1, to: first) ?? first)
            for _ in 0...7 {
                if !weekdaysOnly || Self.isWeekday(day, calendar: calendar) { return day }
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            }
            return nil
        }
    }

    static func isWeekday(_ date: Date, calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        return weekday != 1 && weekday != 7   // Sunday = 1, Saturday = 7
    }

    /// The slot a daily/weekdays routine owes *now*: today's time when it has not already run for
    /// it, nil otherwise. `nextFireDate` answers "when is the next one", which loses the day whenever
    /// a firing tick was blocked and the clock moved past the slot (AUDIT.md D-04); this answers
    /// "has it run for this slot", which a blocked tick cannot erase.
    public static func dueSlot(for routine: Routine, now: Date,
                               calendar: Calendar = .current) -> Date? {
        guard routine.isEnabled else { return nil }
        switch routine.cadence {
        case .every:
            return nextFireDate(for: routine, now: now, calendar: calendar)
        case .daily(let at), .weekdays(let at):
            guard let (hour, minute) = timeOfDay(from: at),
                  let slot = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now)
            else { return nil }
            if case .weekdays = routine.cadence, !isWeekday(slot, calendar: calendar) { return nil }
            guard slot <= now else { return nil }
            // A routine added after its hour owes nothing today: "every morning at eight" said at
            // 21:00 must wait for tomorrow, not fire on the next tick (AUDIT.md R-05). Existing
            // routines were created before their slot, so the catch-up rule still holds for them.
            guard routine.createdAt <= slot else { return nil }
            if let last = routine.lastRunAt, last >= slot { return nil }
            return slot
        }
    }

    /// The soonest thing due, among the enabled routines.
    public func nextDue(after now: Date, calendar: Calendar = .current)
        -> (routine: Routine, date: Date)? {
        var best: (routine: Routine, date: Date)?
        for routine in routines {
            guard let date = Self.nextFireDate(for: routine, now: now, calendar: calendar)
            else { continue }
            if best == nil || date < best!.date { best = (routine, date) }
        }
        return best
    }

    // MARK: - The file

    public static func decode(_ data: Data) -> [Routine] {
        guard let decoded = try? JSONDecoder.chunks().decode([Routine].self, from: data)
        else { return [] }
        // A file edited by hand can hold a routine that would not validate today. Keep the ones
        // that still make sense and drop the rest rather than refusing to load anything: the
        // alternative is losing every routine because one line was mistyped.
        return decoded.filter { routine in
            Self.validate(title: routine.title, prompt: routine.prompt, cadence: routine.cadence,
                          existing: []).map { _ in false } ?? true
        }
    }

    public func encoded() -> Data? {
        guard let data = try? JSONEncoder.chunks().encode(routines) else { return nil }
        return data
    }
}

private extension JSONDecoder {
    static func chunks() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static func chunks() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension RoutinesStore {

    /// Next to `memory.md`, for the same reason: a plain file the user can open, read and edit.
    public static var defaultURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chunks", isDirectory: true)
        return base.appendingPathComponent("routines.json")
    }

    /// Read the file. A missing one is an empty schedule, not an error — first launch looks like
    /// this, and so does a file the user deleted by hand.
    public static func load(from url: URL = RoutinesStore.defaultURL) -> RoutinesStore {
        guard let data = try? Data(contentsOf: url) else { return RoutinesStore() }
        return RoutinesStore(routines: decode(data))
    }

    @discardableResult
    public func save(to url: URL = RoutinesStore.defaultURL) -> Bool {
        guard let data = encoded() else { return false }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
