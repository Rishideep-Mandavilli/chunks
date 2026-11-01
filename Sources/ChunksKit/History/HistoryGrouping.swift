import Foundation

/// The window's list, as data: threads grouped by the day they were last spoken about.
///
/// Lives here rather than in the view for the same reason `ChatGrouping` does — *which row goes
/// under which heading* is the whole design, and it is the part that can be quietly wrong: a thread
/// that spans midnight, a sitting that crosses it, a day holding two sittings and a day holding
/// eight. A layout file is the wrong place to test any of that.
///
/// The shape is the one every conversation app he already knows — a flat list under `Today`,
/// `Yesterday`, the day's name — with the one thing those apps have no reason to show: a line where
/// an earlier sitting began. A companion's history is not one long chat but a series of sittings,
/// and "when was this" is a question about the machine as much as about the topic.
public enum HistoryGrouping {

    /// One thread, as the list sees it.
    public struct Thread: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let title: String
        /// "3 exchanges · 15:34–15:51", with the act count only when the thread did something.
        public let detail: String
        /// The time on the right of the row — the last thing said in the thread, not its first.
        public let time: String
        public let day: String
        public let exchanges: Int
        public let acts: Int
        /// The thread new questions land in.
        public let open: Bool
        /// When the list needs a boundary line above this row: "19:04 · started when the Mac woke".
        /// Only ever set on a sitting's oldest row, and never on the newest sitting — there is
        /// nothing above it to separate.
        public let earlierSitting: String?
        /// Kept so a caller can re-order without re-reading the store, and so the equality check
        /// says what the row actually is rather than what its strings look like.
        public let lastAt: Date

        public init(id: UUID, title: String, detail: String, time: String, day: String,
                    exchanges: Int, acts: Int, open: Bool, earlierSitting: String?,
                    lastAt: Date) {
            self.id = id
            self.title = title
            self.detail = detail
            self.time = time
            self.day = day
            self.exchanges = exchanges
            self.acts = acts
            self.open = open
            self.earlierSitting = earlierSitting
            self.lastAt = lastAt
        }
    }

    public struct Day: Equatable, Sendable, Identifiable {
        public let id: String
        public let label: String
        public let threads: [Thread]
    }

    /// Days newest first, and inside each day the threads newest first.
    ///
    /// A thread is filed by its **last** exchange, so a conversation begun at 23:50 that ran past
    /// midnight is found under the day he finished it in — which is where a man scrolling back for
    /// "what I asked last night" looks.
    public static func days(store: ConversationStore, now: Date = Date(),
                            calendar: Calendar = Calendar.current) -> [Day] {
        var rows: [Thread] = []
        var oldestRowIndexForSession: [UUID: Int] = [:]
        var listedASitting = false

        for session in store.sessionsReversed() {
            for chat in store.chats(inSession: session.id) {
                let held = store.turns(inChat: chat.id)
                guard let first = held.first, let last = held.last else { continue }
                let acts = held.reduce(0) { $0 + $1.acts.count }
                rows.append(Thread(
                    id: chat.id,
                    title: chat.title,
                    detail: describe(exchanges: held.count, acts: acts,
                                     from: first.at, to: last.at, calendar: calendar),
                    time: clock(last.at, calendar: calendar),
                    day: ConversationStore.dayLabel(for: last.at, now: now, calendar: calendar),
                    exchanges: held.count,
                    acts: acts,
                    open: chat.id == store.currentChatID,
                    earlierSitting: nil,
                    lastAt: last.at))
                // Sittings come newest-first and so do their threads, so the row appended *last* for
                // a sitting is its oldest — the one a boundary belongs above.
                oldestRowIndexForSession[session.id] = rows.count - 1
            }
            guard let at = oldestRowIndexForSession[session.id] else { continue }
            // The newest sitting with anything in it gets no line, because there is nothing above it
            // to separate. Sitting indices are not enough: a wake and a button press that produced no
            // question would otherwise leave the *current* sitting wearing the boundary line.
            if listedASitting {
                rows[at] = labelled(rows[at], session, calendar: calendar)
            } else {
                listedASitting = true
            }
        }

        // Recency decides the order once the sittings are interleaved; the walk position breaks a
        // tie, so two threads stamped in the same second cannot swap between two renders of the
        // same file.
        let ordered = rows.enumerated()
            .sorted { $0.element.lastAt != $1.element.lastAt
                        ? $0.element.lastAt > $1.element.lastAt
                        : $0.offset < $1.offset }
            .map(\.element)

        var days: [Day] = []
        var current: (label: String, threads: [Thread])?
        for row in ordered {
            if var group = current, group.label == row.day {
                group.threads.append(row)
                current = group
            } else {
                if let group = current {
                    days.append(Day(id: group.label, label: group.label, threads: group.threads))
                }
                current = (row.day, [row])
            }
        }
        if let group = current {
            days.append(Day(id: group.label, label: group.label, threads: group.threads))
        }
        return days
    }

    private static func labelled(_ row: Thread, _ session: ConversationSession,
                                 calendar: Calendar) -> Thread {
        Thread(id: row.id, title: row.title, detail: row.detail, time: row.time, day: row.day,
               exchanges: row.exchanges, acts: row.acts, open: row.open,
               earlierSitting: clock(session.startedAt, calendar: calendar) + " · " + session.phrase,
               lastAt: row.lastAt)
    }

    private static func describe(exchanges: Int, acts: Int, from: Date, to: Date,
                                 calendar: Calendar) -> String {
        var line = exchanges == 1 ? "1 exchange" : "\(exchanges) exchanges"
        let first = clock(from, calendar: calendar)
        let last = clock(to, calendar: calendar)
        line += " · " + (first == last ? last : "\(first)–\(last)")
        if acts > 0 { line += " · \(acts) act\(acts == 1 ? "" : "s")" }
        return line
    }

    private static func clock(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        return formatter.string(from: date)
    }
}
