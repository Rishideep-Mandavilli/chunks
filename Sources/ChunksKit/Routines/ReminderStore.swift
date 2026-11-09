import Foundation

/// Something to tell him once, at a time he said in words.
///
/// The half of the schedule a routine cannot cover. A routine is a *recurring* question Chunks asks
/// itself; "in ten minutes remind me to stretch" is neither recurring nor a question. Mapping it onto
/// one would be worse than not having it: the shortest legal cadence is 15 minutes, it never stops
/// firing, and each firing spends a screen capture and a model call for a note meant to be read once.
///
/// Deliberately not an EventKit reminder and not a `Calendar` event: nothing here touches another
/// app's data, so arming one cannot put anything in his iCloud or on a phone. It lives in this app's
/// own file and fires into this app's own card.
public struct Reminder: Equatable, Sendable, Codable, Identifiable {

    public var id: UUID
    /// The words he gets back. This is the whole payload — a reminder never captures the screen,
    /// calls a model, or proposes an act when it fires.
    public var text: String
    /// The moment it is due, resolved once at arming so the file states a time rather than a rule
    /// that has to be re-evaluated against a clock that has since moved.
    public var fireAt: Date
    public var createdAt: Date

    public init(id: UUID = UUID(), text: String, fireAt: Date, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.fireAt = fireAt
        self.createdAt = createdAt
    }
}

/// When a one-off reminder is due, in the shape he said it.
///
/// Three cases and nothing else, for the reason `routineCadence` gives: a time Chunks guessed is a
/// notification at the wrong hour, so a phrase that does not land in one of these shapes fails to
/// parse, reaches the user as text, and gets said again in words the tool understands.
public enum ReminderTiming: Equatable, Sendable, Codable {
    /// N minutes from the moment it was armed.
    case inMinutes(Int)
    /// A clock time today, or tomorrow if that hour has already gone.
    case clockTime(hour: Int, minute: Int)
    /// A clock time on the next calendar day, whatever the hour.
    case tomorrowAt(hour: Int, minute: Int)

    /// The words on the card that asks for it.
    public var phrase: String {
        switch self {
        case .inMinutes(let minutes):
            let hours = minutes / 60
            let rest = minutes % 60
            if hours == 0 { return "in \(minutes) min" }
            return rest == 0 ? "in \(hours) h" : "in \(hours)h \(rest) min"
        case .clockTime(let hour, let minute):
            return "at \(ReminderStore.clock(hour: hour, minute: minute))"
        case .tomorrowAt(let hour, let minute):
            return "tomorrow at \(ReminderStore.clock(hour: hour, minute: minute))"
        }
    }

    /// The moment this really fires, given the clock at arming.
    public func date(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .inMinutes(let minutes):
            return now.addingTimeInterval(TimeInterval(minutes * 60))

        case .clockTime(let hour, let minute):
            let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
            guard today > now else {
                return calendar.date(byAdding: .day, value: 1, to: today) ?? today
            }
            return today

        case .tomorrowAt(let hour, let minute):
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return now }
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: tomorrow) ?? tomorrow
        }
    }

    /// `in 40 minutes`, `40 min`, `2 h`, `at 21:00`, `21:00`, `9 pm`, `tomorrow at 07:30`.
    ///
    /// Deliberately narrow, and seconds are refused rather than rounded up: the clock that fires
    /// reminders ticks once a minute, so a tool that accepted "30 seconds" would promise something
    /// the scheduler is built to deliver late.
    public static func parse(_ text: String) -> ReminderTiming? {
        var words = text.lowercased()
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ")
            .map(String.init)
        guard !words.isEmpty else { return nil }

        var tomorrow = false
        if words.first == "tomorrow" {
            tomorrow = true
            words = Array(words.dropFirst())
        }
        // "in" belongs to an interval and "at"/"by" to a clock; either way it is not a value.
        if let lead = words.first, lead == "in" || lead == "at" || lead == "by" {
            words = Array(words.dropFirst())
        }
        guard !words.isEmpty else { return nil }

        if let (hour, minute) = Self.clock(from: words) {
            return tomorrow
                ? .tomorrowAt(hour: hour, minute: minute)
                : .clockTime(hour: hour, minute: minute)
        }
        // "tomorrow" only ever points at a clock; "tomorrow 40 minutes" is nothing anyone meant.
        guard !tomorrow, words.count == 2, let amount = Int(words[0]) else { return nil }
        let minutes: Int
        if words[1].hasPrefix("min") { minutes = amount }
        else if words[1].hasPrefix("h") { minutes = amount * 60 }
        else if words[1].hasPrefix("d") { minutes = amount * 1_440 }
        else { return nil }
        guard (1...maxMinutes).contains(minutes) else { return nil }
        return .inMinutes(minutes)
    }

    /// The furthest ahead a one-off is worth arming: past a month it is a routine, not a reminder.
    public static let maxMinutes = 43_200

    /// `21:00`, `9`, `9 pm`, `7:30 am`. A bare number without a meridiem is not a clock, which is
    /// what keeps "in 40" from being read as 00:40 instead of an interval.
    static func clock(from words: [String]) -> (hour: Int, minute: Int)? {
        guard let first = words.first else { return nil }
        var isPM: Bool?
        if words.count == 2 {
            let tail = words[1]
            if tail == "pm" || tail == "p.m." { isPM = true }
            else if tail == "am" || tail == "a.m." { isPM = false }
            else { return nil }
        } else if words.count > 2 {
            return nil
        }

        let parts = first.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let hour: Int
        let minute: Int
        if parts.count == 2 {
            guard let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
            hour = h
            minute = m
        } else if isPM != nil, let h = Int(first) {
            hour = h
            minute = 0
        } else {
            return nil
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        guard let isPM else { return (hour, minute) }
        // `12 pm` is midday and `12 am` is midnight; every other pm hour is twelve later.
        if hour == 12 { return (isPM ? 12 : 0, minute) }
        guard (1...11).contains(hour) else { return nil }
        return (isPM ? hour + 12 : hour, minute)
    }
}

/// Why a reminder was not accepted, said as a sentence for the card and the panel row.
public enum ReminderRejection: Equatable, Sendable, Error {
    case emptyText
    case textTooLong(limit: Int)
    case tooMany(limit: Int)
    case holdsSecret

    public var reason: String {
        switch self {
        case .emptyText: return "A reminder needs something to say."
        case .textTooLong(let limit): return "That reminder is longer than \(limit) characters."
        case .tooMany(let limit): return "Chunks holds \(limit) reminders at a time."
        // Invariant 3, applied to a new file: a reminder is written to disk, so a line that reads
        // like a credential is refused rather than parked in plain text next to `memory.md`.
        case .holdsSecret: return "A reminder is written to a file, so Chunks will not put a "
            + "credential in it."
        }
    }
}

/// The reminders, on disk, and the arithmetic of which ones are due.
public struct ReminderStore: Equatable, Sendable {

    /// Few enough that the panel shows every one without scrolling, and a misheard "remind me X"
    /// cannot become a pile nobody reads.
    public static let maxReminders = 8

    /// Shorter than a routine's question because a reminder's whole payload is one line, and the
    /// card wraps it in `Remind "…" tomorrow at 09:00?` — that frame is 27 characters, so 66 leaves
    /// the whole question inside the 100 the card measures (`DoRequest.maxQuestionCharacters`) *even
    /// after* the shell turns `at 09:00` into `tomorrow at 09:00`. Two limits seen from one rule:
    /// a question the shell has to clip to fit is a question he approved without finishing reading.
    public static let maxTextCharacters = 66

    /// Earliest first, so the next one due is always `reminders.first`.
    public private(set) var reminders: [Reminder]

    public init(reminders: [Reminder] = []) {
        self.reminders = reminders.sorted { $0.fireAt < $1.fireAt }
    }

    // MARK: - Validation

    public static func validate(text: String, existing: [Reminder]) -> ReminderRejection? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return .emptyText }
        if clean.count > maxTextCharacters { return .textTooLong(limit: maxTextCharacters) }
        if !SecretSweeper.inspect(clean).isAcceptable { return .holdsSecret }
        if existing.count >= maxReminders { return .tooMany(limit: maxReminders) }
        return nil
    }

    /// The timing as it will *really* fire, from the clock at arming.
    ///
    /// `at 21:00` written at 22:00 means tomorrow, and the card has to say so before he taps Allow —
    /// approving a time on the wrong day is approving nothing. Resolving here rather than in
    /// `DoRequest.parse` is the same move `[DO:reveal:]` makes: the pure parser keeps the user's
    /// words, and the shell turns them into the thing it is about to do before it describes it.
    public static func resolve(_ timing: ReminderTiming, now: Date = Date(),
                               calendar: Calendar = .current) -> ReminderTiming {
        let date = timing.date(from: now, calendar: calendar)
        guard case .clockTime(let hour, let minute) = timing,
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
              calendar.isDate(date, sameDayAs: tomorrow)
        else { return timing }
        return .tomorrowAt(hour: hour, minute: minute)
    }

    // MARK: - Mutation

    /// Arm one, or hand back the reason it was refused. The fire date is resolved here, once, so the
    /// file and the card can never disagree about when it goes off.
    public mutating func add(text: String, timing: ReminderTiming, now: Date = Date(),
                             calendar: Calendar = .current) -> Result<Reminder, ReminderRejection> {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rejection = Self.validate(text: clean, existing: reminders) {
            return .failure(rejection)
        }
        let reminder = Reminder(text: clean, fireAt: timing.date(from: now, calendar: calendar))
        reminders.append(reminder)
        reminders.sort { $0.fireAt < $1.fireAt }
        return .success(reminder)
    }

    public mutating func remove(id: UUID) -> Bool {
        let before = reminders.count
        reminders.removeAll { $0.id == id }
        return reminders.count != before
    }

    /// Take out the one he named, by the words he gave it.
    ///
    /// Exact match first, then one that starts with what he said, and never more than one: a model
    /// told to "cancel the recycling reminder" must not clear the schedule because two texts shared
    /// a word. Returns nil when nothing answers, which the caller reports rather than guesses at.
    @discardableResult
    public mutating func cancel(matching phrase: String) -> Reminder? {
        let wanted = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        guard let match = reminders.first(where: { $0.text.lowercased() == wanted })
            ?? reminders.first(where: { $0.text.lowercased().hasPrefix(wanted) })
        else { return nil }
        reminders.removeAll { $0.id == match.id }
        return match
    }

    // MARK: - When

    /// Everything whose moment has arrived, earliest first.
    public func due(before now: Date) -> [Reminder] {
        reminders.filter { $0.fireAt <= now }
    }

    public func nextDue(after now: Date) -> Reminder? {
        reminders.first { $0.fireAt > now }
    }

    /// When this is due, in the words a spoken line uses: "in 40 min", "at 21:00", "tomorrow at
    /// 09:00", "Mon 07:30".
    ///
    /// Derived from the stored date rather than the timing that produced it, so a line saying
    /// "tomorrow at 21:00" describes the moment that will actually happen — even after a rebuild, a
    /// DST shift, or a reminder armed at 22:00 for "at 21:00".
    public static func spoken(fireAt: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = fireAt.timeIntervalSince(now)
        if seconds <= 90 { return "now" }
        let sameDay = calendar.isDate(fireAt, inSameDayAs: now)
        if sameDay, seconds < 3_600 {
            // Rounded, not floored: a reminder armed for "40 min" read back as "in 39 min" one second
            // later is the card disagreeing with the question he just answered.
            return "in \(Int((seconds / 60).rounded())) min"
        }
        let clock = clockFormatter.string(from: fireAt)
        if sameDay { return "at \(clock)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(fireAt, sameDayAs: tomorrow) {
            return "tomorrow at \(clock)"
        }
        return "\(dayFormatter.string(from: fireAt)) \(clock)"
    }

    /// The hour a due reminder should be reported with when it arrived late — after a sleep, or
    /// after the app was closed. Saying "now" for something that was due at 09:00 hides the fact
    /// that the machine was asleep, which is the one thing he would want to know about it.
    public static func lateText(fireAt: Date, now: Date, calendar: Calendar = .current) -> String? {
        guard now.timeIntervalSince(fireAt) > 120 else { return nil }
        let sameDay = calendar.isDate(fireAt, inSameDayAs: now)
        return sameDay
            ? "was due at \(clockFormatter.string(from: fireAt))"
            : "was due \(dayFormatter.string(from: fireAt)) \(clockFormatter.string(from: fireAt))"
    }

    static func clock(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()

    // MARK: - The file

    public static func decode(_ data: Data) -> [Reminder] {
        bounded(data).kept
    }

    /// What a hand-edited file asked for that the store will not honour, in the same words the add
    /// path uses. The reader is held to `validate`'s bounds (AUDIT.md D-07): a file edited to fifty
    /// overdue lines would otherwise take fifty minutes to drain at one fire a minute, and a line
    /// longer than the card can show is a promise nobody finished reading.
    public static func decodeRefusals(_ data: Data) -> [String] {
        bounded(data).refused
    }

    private static func bounded(_ data: Data) -> (kept: [Reminder], refused: [String]) {
        guard let decoded = try? JSONDecoder.reminders().decode([Reminder].self, from: data)
        else { return ([], []) }
        var kept: [Reminder] = []
        var refused: [String] = []
        // A line whose time has gone is kept, because "it was due at 09:00 and arrives when the Mac
        // wakes" is a truer report than losing the promise without a word.
        for reminder in decoded.sorted(by: { $0.fireAt < $1.fireAt }) {
            let clean = reminder.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty {
                refused.append("a reminder with no words")
            } else if clean.count > maxTextCharacters {
                refused.append("a reminder longer than \(maxTextCharacters) characters")
            } else if !SecretSweeper.inspect(clean).isAcceptable {
                refused.append("a reminder that holds a credential")
            } else if kept.count >= maxReminders {
                refused.append("more than \(maxReminders) reminders")
            } else {
                kept.append(Reminder(id: reminder.id, text: clean,
                                     fireAt: reminder.fireAt, createdAt: reminder.createdAt))
            }
        }
        return (kept, refused)
    }

    public func encoded() -> Data? {
        try? JSONEncoder.reminders().encode(reminders)
    }
}

private extension Calendar {
    /// `isDate(_:inSameDayAs:)` with the argument order this file reads in.
    func isDate(_ a: Date, sameDayAs b: Date) -> Bool {
        isDate(a, inSameDayAs: b)
    }
}

private extension JSONDecoder {
    static func reminders() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static func reminders() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension ReminderStore {

    /// Next to `memory.md` and `routines.json`, for the same reason: a plain file he can open,
    /// read, and edit by hand.
    public static var defaultURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chunks", isDirectory: true)
        return base.appendingPathComponent("reminders.json")
    }

    public static func load(from url: URL = ReminderStore.defaultURL) -> ReminderStore {
        guard let data = try? Data(contentsOf: url) else { return ReminderStore() }
        return ReminderStore(reminders: decode(data))
    }

    @discardableResult
    public func save(to url: URL = ReminderStore.defaultURL) -> Bool {
        guard let data = encoded() else { return false }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
