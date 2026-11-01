import Foundation

/// One stretch of conversation, with a beginning he can point at.
///
/// Sessions exist because the alternative was measured: with one flat list, the ten exchanges
/// replayed to the model on Tuesday morning were Friday night's, so Chunks answered a question about
/// a new screen as a follow-up to a conversation that ended two days earlier. A session is the
/// boundary that fixes it, and the reason it started is stored because "opened when the Mac woke"
/// explains to him why the context is gone.
public struct ConversationSession: Equatable, Sendable, Codable, Identifiable {

    /// How this stretch of conversation began.
    public enum Start: String, Equatable, Sendable, Codable {
        /// The app process started — covers a relaunch, a reboot and a login.
        case launch
        /// The Mac woke and had genuinely been asleep.
        case wake
        /// The window's button.
        case manual
        /// He said or typed it.
        case asked
        /// Turns loaded from a file written before sessions existed.
        case restored
        /// The previous one reached `ConversationStore.maxTurnsPerSession`.
        ///
        /// A boundary the machine chose, and it is labelled as one: a list where a sitting ends
        /// after 25 exchanges with no reason given reads as history being lost.
        case capped
    }

    public var id: UUID
    public var startedAt: Date
    public var start: Start

    public init(id: UUID = UUID(), startedAt: Date = Date(), start: Start = .launch) {
        self.id = id
        self.startedAt = startedAt
        self.start = start
    }

    /// The words the window shows beside the time.
    public var phrase: String {
        switch start {
        case .launch: return "started when Chunks opened"
        case .wake: return "started when the Mac woke"
        case .manual: return "started by you"
        case .asked: return "started when you asked"
        case .restored: return "earlier"
        case .capped: return "started when the last one filled up"
        }
    }
}

/// One question and the answer Chunks gave to it.
///
/// Persisted, because the in-memory list this replaces held ten exchanges and died with the
/// process: a companion that answers a question about your screen and then cannot tell you what it
/// said an hour ago is a tool you have to keep re-asking. The window's whole reason to exist is
/// being the place those answers live.
public struct ConversationTurn: Equatable, Sendable, Codable, Identifiable {

    /// How the turn started, which the history list shows as a glyph.
    ///
    /// Worth separating because a turn Chunks asked itself is not the same kind of thing as one he
    /// spoke: on a morning glance, "07:00 — brief me" arriving under his own name would read as
    /// something he said and forgot.
    public enum Source: String, Equatable, Sendable, Codable {
        case voice
        case typed
        case chip
        case routine

        public var phrase: String {
            switch self {
            case .voice: return "spoken"
            case .typed: return "typed"
            case .chip: return "tapped"
            case .routine: return "scheduled"
            }
        }
    }

    public var id: UUID
    public var asked: String
    /// What the card showed — the spoken line and the expansion together, tags resolved.
    public var answered: String
    /// `<DONE_TITLE>` when the model produced one, else the first line of the answer. This is the
    /// list label, so it is stored rather than recomputed from text that may be long.
    public var headline: String
    public var at: Date
    public var source: Source
    /// What the acts in this turn actually did, one line each.
    ///
    /// Stored apart from the answer because it is the part with consequences: "I found the send
    /// button" and "Pressed Send." are different claims about the machine, and a history that
    /// merges them tells a story that did not happen.
    public var acts: [String]
    /// The stretch of conversation this belongs to.
    ///
    /// Optional because the file on disk predates sessions: a turn with no session is not thrown
    /// away, it is read as belonging to the one restored session.
    public var sessionID: UUID?
    /// The thread inside that session — the thing he was looking at.
    ///
    /// Optional for the same migration reason, and because a turn written by hand into the file has
    /// no thread until the store gives it one.
    public var chatID: UUID?

    public init(id: UUID = UUID(), asked: String, answered: String, headline: String,
                at: Date = Date(), source: Source = .voice, acts: [String] = [],
                sessionID: UUID? = nil, chatID: UUID? = nil) {
        self.id = id
        self.asked = asked
        self.answered = answered
        self.headline = headline
        self.at = at
        self.source = source
        self.acts = acts
        self.sessionID = sessionID
        self.chatID = chatID
    }

    /// The one line the history list shows under the headline.
    public var preview: String {
        ConversationStore.preview(of: answered.isEmpty ? asked : answered)
    }

    /// Whether this row knows when it happened.
    ///
    /// A row whose date could not be read keeps epoch rather than being stamped "now", so the list
    /// has one honest way to say *unknown*: show no time. Displaying "01/01/1970" would be the
    /// store inventing a fact it does not have.
    public var hasRecordedDate: Bool {
        at.timeIntervalSince1970 >= 1
    }

    /// Read one row as generously as its fields allow.
    ///
    /// The synthesized conformance throws on a missing key or a differently-formatted date, and
    /// because `JSONDecoder` decodes an array atomically, that single row used to take the entire
    /// history with it. The schema will still be moving while this file sits in `Application
    /// Support`, and he can open it in a text editor — so a row is answered with defaults, and the
    /// only rows the store discards are the ones with no question in them.
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? fields.decode(UUID.self, forKey: .id)) ?? UUID()
        asked = (try? fields.decode(String.self, forKey: .asked)) ?? ""
        answered = (try? fields.decode(String.self, forKey: .answered)) ?? ""
        headline = (try? fields.decode(String.self, forKey: .headline)) ?? ""
        source = (try? fields.decode(Source.self, forKey: .source)) ?? .voice
        acts = (try? fields.decode([String].self, forKey: .acts)) ?? []
        sessionID = try? fields.decode(UUID.self, forKey: .sessionID)
        chatID = try? fields.decode(UUID.self, forKey: .chatID)
        at = ConversationStore.readDate(fields, forKey: .at)
    }

    private enum CodingKeys: String, CodingKey {
        case id, asked, answered, headline, at, source, acts, sessionID, chatID
    }
}

/// The turns, and the sessions they fall into, on disk.
public struct ConversationStore: Equatable, Sendable {

    /// Two hundred turns, not "unbounded". A screen assistant asked anything forever would grow a
    /// file nobody can open, and the value of history is the last few days, not the last few years.
    public static let maxTurns = 200

    /// Characters of the answer kept for the list's second line.
    public static let previewCharacters = 120

    /// How many past exchanges of *this session* go back to the model.
    ///
    /// Deliberately smaller than the file: the prompt is charged for every one of these on every
    /// turn, and the measured request was already 23k characters. Ten is the number that keeps a
    /// conversation going without paying for it on every question.
    public static let promptBudget = 10

    /// How many older turns a recalled question may bring back.
    ///
    /// Three. Enough to answer "what did I ask about the certificate?" with the actual exchange,
    /// few enough that the recall block never costs more prompt than the live conversation does.
    public static let recallBudget = 3

    /// How many exchanges one session holds before the next one opens by itself.
    ///
    /// Twenty-five, and deliberately *above* `promptBudget`: the replay only ever carries the last
    /// ten, so a cap that fired sooner would cut a conversation in half and leave the model without
    /// the context it is supposed to have. At 25 the boundary is a filing decision, not a memory
    /// loss — the closed session keeps every turn, stays in the window, and stays recallable.
    public static let maxTurnsPerSession = 25

    /// How many sessions the model is shown as an index, and how many of their threads.
    ///
    /// Eight sittings at three thread names each is roughly 250 characters per line — a fraction of
    /// one screenshot — and it is the only thing that tells the model a whole *other* conversation
    /// happened. The live replay cannot, by construction; `recall` only runs when he refers back.
    public static let indexSessionLimit = 8
    public static let indexTitlesPerSession = 3
    /// The index's own ceiling, so a long thread title cannot make the block bigger than the
    /// conversation it is summarising.
    public static let indexCharacterBudget = 900

    public private(set) var turns: [ConversationTurn]
    public private(set) var sessions: [ConversationSession]
    public private(set) var chats: [ConversationChat]

    /// The session new turns land in. Always set — a store with no session is only possible before
    /// `load`, and `beginSession` runs at launch either way.
    public private(set) var currentSessionID: UUID

    /// The thread new turns land in. Nil means the next turn opens one — which is what a fresh
    /// session, a long gap, and a change of subject all look like from here.
    public private(set) var currentChatID: UUID?

    public init(turns: [ConversationTurn] = [],
                sessions: [ConversationSession] = [],
                chats: [ConversationChat] = [],
                currentSessionID: UUID? = nil,
                currentChatID: UUID? = nil) {
        self.turns = turns
        // The session new turns land in has to *exist*. It used to be invented here and never filed,
        // which was harmless while `beginSession` runs at launch and a real bug for anything else:
        // the turns pointed at a session the list did not contain, so the window had no header to
        // file them under, the index could not see them, and a cap that closed them opened the first
        // session the store had ever had.
        var filed = sessions
        if filed.isEmpty { filed.append(ConversationSession()) }
        self.sessions = filed
        self.chats = chats
        self.currentSessionID = currentSessionID ?? filed.last?.id
            ?? ConversationSession().id
        self.currentChatID = currentChatID ?? chats.last?.id
    }

    /// The session new turns are going into.
    public var currentSession: ConversationSession? {
        sessions.first(where: { $0.id == currentSessionID })
    }

    /// Start a new session. Returns it, because the caller logs *why* a conversation ended and
    /// needs the id to say which one began.
    @discardableResult
    public mutating func beginSession(starting: ConversationSession.Start,
                                      at date: Date = Date()) -> ConversationSession {
        // An empty session is not worth a boundary: pressing the button twice, or waking twice
        // inside a minute, would add rows to the list that hold nothing. The one already open is
        // re-dated instead and its reason replaced — "earlier" on a session that has never been
        // used would describe a conversation that did not happen.
        if var open = sessions.last, open.id == currentSessionID, !hasTurns(open.id) {
            open.startedAt = date
            open.start = starting
            sessions[sessions.count - 1] = open
            // Cleared here too: a session that has never been used can still hold the pointer to a
            // thread loaded from an older one, and the first question of a new sitting would have
            // joined that thread when the app was relaunched inside the gap.
            currentChatID = nil
            return open
        }
        let session = ConversationSession(startedAt: date, start: starting)
        sessions.append(session)
        currentSessionID = session.id
        // A new sitting never continues an old thread, however well the words would have matched.
        currentChatID = nil
        return session
    }

    private func hasTurns(_ id: UUID) -> Bool {
        turns.contains { $0.sessionID == id }
    }

    /// Append, trimming from the oldest end so the newest answers are always kept.
    ///
    /// The turn is placed in a session and in a thread on the way in, so the tree is a fact of the
    /// data rather than something each reader works out — a grouping recomputed on every load would
    /// let a chat's boundaries move when the file is re-read, and a list whose rows change shape
    /// under the cursor is not a list.
    ///
    public mutating func append(_ turn: ConversationTurn) {
        var stored = turn
        if stored.sessionID == nil { stored.sessionID = currentSessionID }
        stored.chatID = chatID(for: stored)
        turns.append(stored)
        if turns.count > Self.maxTurns {
            turns.removeFirst(turns.count - Self.maxTurns)
        }
        pruneContainers()
    }

    /// Open a new session when the current one has held all it will hold. True when it did.
    ///
    /// Called at the start of a turn the *user* began, never from `append`. A plan runs several
    /// exchanges deep and each round replays the session's own history — rotate in the middle of one
    /// and the fifth step of a WhatsApp plan is continued by a model that can no longer see steps
    /// one to four, which is how an assistant types into the wrong window.
    ///
    /// The caller reports it. A conversation that ends on the machine's count rather than his has to
    /// be labelled, or a gap in the middle of a list reads as the history being broken — which is the
    /// exact reason the window already says *why* every session began.
    @discardableResult
    public mutating func closeSessionIfFull(at date: Date = Date()) -> Bool {
        guard sessionTurns().count >= Self.maxTurnsPerSession else { return false }
        beginSession(starting: .capped, at: date)
        return true
    }

    /// The thread this turn belongs to, opening a new one when it does not continue the last.
    private mutating func chatID(for turn: ConversationTurn) -> UUID {
        // A thread never spans two sittings, so the open chat is only a candidate while it belongs
        // to the session this turn is landing in.
        let open = turns(inOpenChatOf: turn.sessionID ?? currentSessionID)
        if ChatGrouping.continues(open: open, turn), let existing = currentChatID {
            return existing
        }
        let chat = ConversationChat(sessionID: turn.sessionID ?? currentSessionID,
                                    startedAt: turn.at,
                                    title: ChatGrouping.title(for: turn))
        chats.append(chat)
        currentChatID = chat.id
        return chat.id
    }

    /// The turns of the thread new questions would join, when that thread is in this session.
    private func turns(inOpenChatOf sessionID: UUID) -> [ConversationTurn] {
        guard let currentChatID,
              let chat = chats.first(where: { $0.id == currentChatID }),
              chat.sessionID == sessionID else { return [] }
        return turns.filter { $0.chatID == currentChatID }
    }

    public mutating func remove(id: UUID) {
        turns.removeAll { $0.id == id }
        pruneContainers()
    }

    /// Chats and sessions that no longer hold a turn are dropped, so the file cannot fill with empty
    /// rows while history trims from the other end.
    private mutating func pruneContainers() {
        let keptTurns = turns
        // A thread with no exchanges is a heading with nothing under it, so it goes — including the
        // open one. Keeping the empty current chat would leave a stale title in the file, and the
        // next question could not join it anyway: an empty thread is not a continuation of anything.
        let keptChats = Set(keptTurns.compactMap { $0.chatID })
        chats = chats.filter { keptChats.contains($0.id) }
        let keptSessions = Set(keptTurns.compactMap { $0.sessionID })
        sessions = sessions.filter { keptSessions.contains($0.id) || $0.id == currentSessionID }
        if let currentChatID, !chats.contains(where: { $0.id == currentChatID }) {
            self.currentChatID = nil
        }
    }

    /// The turns of one session, oldest first.
    public func sessionTurns(_ id: UUID? = nil) -> [ConversationTurn] {
        let target = id ?? currentSessionID
        return turns.filter { $0.sessionID == target }
    }

    /// The most recent turns *of the current session*, oldest first — the order a prompt replays
    /// them in.
    ///
    /// Session-scoped on purpose. Before this, the ten exchanges sent back to the model were simply
    /// the last ten, which after a restart meant yesterday's screen being answered as if he were
    /// still looking at it.
    public func recent(_ count: Int = Self.promptBudget) -> [ConversationTurn] {
        Array(sessionTurns().suffix(max(0, count)))
    }

    /// Newest first, for a list that reads downward through time.
    public func reversed() -> [ConversationTurn] {
        turns.reversed()
    }

    /// Sessions newest first, for the list's dividers.
    public func sessionsReversed() -> [ConversationSession] {
        sessions.reversed()
    }

    /// Every sitting the model should know about, as one line each.
    ///
    /// This is what makes the file the *real* memory of the conversations rather than the last ten
    /// exchanges. The replay is session-scoped on purpose, and `recall` only runs when he points at
    /// the past — so without an index the model genuinely does not know another sitting happened, and
    /// "did we not discuss this yesterday?" has nothing to answer from.
    ///
    /// Thread names are the `<DONE_TITLE>`s he already saw on the card, never a summary a model had
    /// to be charged for: Chunks answers in seconds, and a per-session digest would mean a call per
    /// session, per day, forever, to describe conversations it already had.
    public func sessionIndex(now: Date = Date()) -> String {
        var lines: [String] = []
        var spent = 0
        for session in sessionsReversed() {
            if lines.count >= Self.indexSessionLimit { break }
            let held = sessionTurns(session.id)
            guard !held.isEmpty else { continue }
            let titles = chats(inSession: session.id).prefix(Self.indexTitlesPerSession)
                .map { ConversationStore.preview(of: $0.title) }
            let line = "- \(ConversationStore.dayLabel(for: session.startedAt, now: now)) "
                + Self.clock.string(from: session.startedAt)
                + " · \(session.phrase) · \(held.count) exchange" + (held.count == 1 ? "" : "s")
                + (titles.isEmpty ? "" : " · " + titles.joined(separator: " / "))
            spent += line.count
            guard spent <= Self.indexCharacterBudget else { break }
            lines.append(line)
        }
        guard !lines.isEmpty else { return "" }
        return "his conversations, newest first — this is what Chunks remembers of the earlier ones, "
            + "by name rather than by transcript. if he asks what came of one, say you need to look at "
            + "that window again or read it from the history window; do not invent what was said.\n"
            + lines.joined(separator: "\n")
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        return formatter
    }()

    /// The threads of one session, newest first — the level the sidebar actually lists.
    public func chats(inSession id: UUID? = nil) -> [ConversationChat] {
        let target = id ?? currentSessionID
        return chats.filter { $0.sessionID == target }.sorted { $0.startedAt > $1.startedAt }
    }

    /// The exchanges of one thread, oldest first — the order a transcript is read in.
    public func turns(inChat id: UUID) -> [ConversationTurn] {
        turns.filter { $0.chatID == id }
    }

    public func chat(_ id: UUID?) -> ConversationChat? {
        guard let id else { return nil }
        return chats.first(where: { $0.id == id })
    }

    /// How many threads a session holds, for its sidebar line.
    public func chatCount(inSession id: UUID) -> Int {
        chats.filter { $0.sessionID == id }.count
    }

    /// The span a thread covers, first exchange to last. A chat is a thing with a beginning and an
    /// end, and the transcript's header has to say so.
    public func span(ofChat id: UUID) -> (first: Date, last: Date)? {
        let held = turns(inChat: id)
        guard let first = held.first?.at, let last = held.last?.at else { return nil }
        return (first, last)
    }

    public func session(for turn: ConversationTurn) -> ConversationSession? {
        sessions.first(where: { $0.id == turn.sessionID })
    }

    // MARK: - Recalling an older conversation

    /// Turns from *other* sessions whose words answer this question.
    ///
    /// This is what makes the history more than an archive he has to scroll: asked "what did I ask
    /// about the certificate warning", the answer is in a session the model can no longer see, so
    /// the shell finds it and puts it in front of the model as data.
    ///
    /// Keyword scoring, not embeddings, for three reasons that are all this project's rules: it
    /// works with no network and no model download, it is deterministic enough to unit-test the
    /// ranking, and a scored list can say *why* a row came back where a cosine similarity cannot.
    public func recall(query: String, limit: Int = Self.recallBudget) -> [ConversationTurn] {
        let words = Self.contentWords(in: query)
        guard !words.isEmpty else { return [] }
        let live = Set(sessionTurns().map(\.id))
        var scored: [(turn: ConversationTurn, score: Int)] = []
        for turn in turns where !live.contains(turn.id) {
            let asked = Self.contentWords(in: turn.asked)
            let body = Self.contentWords(in: turn.headline + " " + turn.answered)
            var score = 0
            for word in words {
                if asked.contains(word) { score += 3 }   // he asked it in the same words
                else if body.contains(word) { score += 1 }
            }
            guard score > 0 else { continue }
            scored.append((turn, score))
        }
        // Score first, recency only to break a tie — an older row that matches the words better is
        // still the better answer.
        let ranked = scored.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.turn.at > $1.turn.at
        }
        return Array(ranked.prefix(max(0, limit)).map(\.turn))
    }

    /// Words worth matching on: lowercased, unpunctuated, no stop-words, at least three letters.
    ///
    /// The stop list is the reason "what did I ask you about that" recalls nothing instead of
    /// dragging back every turn that contains "ask".
    static func contentWords(in text: String) -> Set<String> {
        Set(text.lowercaseComponents()
            .filter { $0.count >= 3 && !stopWords.contains($0) })
    }

    private static let stopWords: Set<String> = [
        "the", "and", "was", "were", "are", "this", "that", "with", "for", "you", "your", "what",
        "when", "where", "which", "who", "how", "why", "did", "does", "have", "had", "has", "not",
        "but", "can", "will", "would", "could", "should", "about", "from", "into", "out", "asked",
        "ask", "said", "told", "remind", "again", "just", "then", "than", "them", "they", "there",
        "here", "some", "any", "all", "one", "two", "get", "got", "say", "tell", "before",
        "yesterday", "today", "earlier", "conversation", "chunks",
    ]

    /// How far back a date is, in the words a list can head a group with.
    ///
    /// "Today" and "Yesterday" beat dates because the question a scrolled list answers is "was this
    /// this sit-down or the last one". Pure and injected with `now`/`calendar` for the same reason
    /// `RoutinesStore.nextFireDate` is: a boundary that crosses midnight and a daylight-saving week
    /// are both testable only if the clock is an argument.
    public static func dayLabel(for date: Date, now: Date = Date(),
                                calendar: Calendar = Calendar.current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        if calendar.dateInterval(of: .weekOfYear, for: now)?.contains(date) == true {
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
        } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
        }
        return formatter.string(from: date)
    }

    /// How long the Mac was shut, in the one unit a person would say.
    ///
    /// Lives with the store rather than the shell because it is the same arithmetic the session
    /// boundary is decided by, and a pill that reads "1290 minutes later" is a bug in the copy, not
    /// a fact about the machine.
    public static func minutesSpentAsleep(_ seconds: TimeInterval) -> String {
        if seconds < 90 { return "\(Int(seconds)) seconds" }
        let minutes = seconds / 60
        if minutes < 90 { return "\(Int(minutes)) minutes" }
        let hours = minutes / 60
        if hours < 36 { return String(format: hours < 10 ? "%.1f hours" : "%.0f hours", hours) }
        return "\(Int(hours / 24)) days"
    }

    /// Collapse whitespace and cut at a word boundary. A preview that ends mid-word looks like a
    /// bug in the store rather than a short answer.
    public static func preview(of text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard flattened.count > previewCharacters else { return flattened }
        let cut = String(flattened.prefix(previewCharacters))
        if let lastSpace = cut.lastIndex(of: " "),
           cut.distance(from: cut.startIndex, to: lastSpace) > previewCharacters / 2 {
            return String(cut[..<lastSpace]).trimmingCharacters(in: .whitespaces) + "…"
        }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Read the date a row carries, in whichever of the two shapes JSON holds.
    ///
    /// ISO-8601 is what this store writes; the plain number is what `JSONEncoder` produces by
    /// default, so a row appended by hand or by another tool still lands. A row with no readable
    /// date keeps epoch rather than being stamped "now" — inventing recency would put a turn with no
    /// time on it above this morning's.
    static func readDate<Key: CodingKey>(_ fields: KeyedDecodingContainer<Key>,
                                          forKey key: Key) -> Date {
        if let date = try? fields.decode(Date.self, forKey: key) { return date }
        if let seconds = try? fields.decode(Double.self, forKey: key) {
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
        return Date(timeIntervalSince1970: 0)
    }

    /// Give every turn a thread, keeping the ones that already have one.
    ///
    /// This is the migration for a file written before chats existed, and it is also what runs when a
    /// hand-edited row arrives without a thread. Deterministic in both directions: the same turns in
    /// the same order always produce the same boundaries, because `ChatGrouping` reads only the words
    /// and the timestamps in the file — never the clock, never a model.
    public static func assignChats(to original: [ConversationTurn])
        -> (turns: [ConversationTurn], chats: [ConversationChat]) {
        var rebuilt: [ConversationTurn] = []
        var chats: [ConversationChat] = []
        var open: [ConversationTurn] = []
        var currentID: UUID?
        var currentSession: UUID?

        for turn in original {
            var stored = turn
            if let existing = stored.chatID {
                // Already placed. Adopt it as the open thread so the next turn continues the chat the
                // file says it belongs to, rather than the one the rule would have chosen.
                currentID = existing
                currentSession = stored.sessionID
                open = rebuilt.filter { $0.chatID == existing }
                open.append(stored)
                rebuilt.append(stored)
                continue
            }
            let continues = stored.sessionID == currentSession
                && ChatGrouping.continues(open: open, stored)
            if continues, let id = currentID {
                stored.chatID = id
                open.append(stored)
            } else {
                let chat = ConversationChat(sessionID: stored.sessionID ?? currentSession
                                                    ?? ConversationSession().id,
                                            startedAt: stored.at,
                                            title: ChatGrouping.title(for: stored))
                chats.append(chat)
                currentID = chat.id
                currentSession = stored.sessionID
                open = [stored]
                stored.chatID = chat.id
            }
            rebuilt.append(stored)
        }
        return (rebuilt, chats)
    }

    // MARK: - The file

    public static var defaultURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chunks", isDirectory: true)
        return base.appendingPathComponent("history.json")
    }

    /// The file's two lists, read from either shape.
    ///
    /// The envelope (`{"sessions": […], "turns": […]}`) is what this writes now; a bare array is
    /// what was on disk before sessions existed, and it is still read — the alternative was telling
    /// him his history vanished because a field was added.
    public static func file(in data: Data)
        -> (turns: [ConversationTurn], sessions: [ConversationSession],
            chats: [ConversationChat]) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let rows = array(in: data, key: "turns") else {
            return (decode(data), [], [])
        }
        let turns = rows.compactMap { decodeTurn($0, with: decoder) }
        let sessions = (array(in: data, key: "sessions") ?? [])
            .compactMap { decodeSession($0, with: decoder) }
        let chats = (array(in: data, key: "chats") ?? [])
            .compactMap { decodeChat($0, with: decoder) }
        return (turns, sessions, chats)
    }

    /// The turns of a file, in whichever shape it was written.
    ///
    /// Row by row, on purpose: `JSONDecoder` answers an array atomically, so one hand-edited or
    /// differently-formatted row used to fail the whole file and take every answer in it with it.
    /// Unparseable JSON still gives an empty history — there is nothing to keep.
    public static func decode(_ data: Data) -> [ConversationTurn] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Either the bare array of the old file or the `turns` list of the envelope — the reader
        // that only knew one of the two returned nothing for the other, which is how an upgrade
        // would have emptied the window.
        let rows = array(in: data, key: nil) ?? array(in: data, key: "turns") ?? []
        return rows.compactMap { decodeTurn($0, with: decoder) }
    }

    /// Every element of the JSON array in this document — the top level, or the value under `key`.
    private static func array(in data: Data, key: String?) -> [Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let key {
            guard let envelope = object as? [String: Any],
                  let nested = envelope[key] as? [Any] else { return nil }
            return nested
        }
        return object as? [Any]
    }

    private static func decodeTurn(_ row: Any, with decoder: JSONDecoder) -> ConversationTurn? {
        guard JSONSerialization.isValidJSONObject(row),
              let rowData = try? JSONSerialization.data(withJSONObject: row),
              let turn = try? decoder.decode(ConversationTurn.self, from: rowData),
              isRealTurn(turn)
        else { return nil }
        return turn
    }

    private static func decodeSession(_ row: Any,
                                      with decoder: JSONDecoder) -> ConversationSession? {
        guard JSONSerialization.isValidJSONObject(row),
              let rowData = try? JSONSerialization.data(withJSONObject: row),
              let session = try? decoder.decode(ConversationSession.self, from: rowData),
              session.startedAt.timeIntervalSince1970 >= 1
        else { return nil }
        return session
    }

    private static func decodeChat(_ row: Any,
                                   with decoder: JSONDecoder) -> ConversationChat? {
        guard JSONSerialization.isValidJSONObject(row),
              let rowData = try? JSONSerialization.data(withJSONObject: row),
              let chat = try? decoder.decode(ConversationChat.self, from: rowData),
              !chat.title.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return chat
    }

    /// A turn with nothing in it is not history: the list would show a blank row that crashes
    /// nothing but looks broken.
    private static func isRealTurn(_ turn: ConversationTurn) -> Bool {
        !turn.asked.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Read the file, and give the turns it holds a session and a thread.
    public static func load(from url: URL = ConversationStore.defaultURL) -> ConversationStore {
        guard let data = try? Data(contentsOf: url) else { return ConversationStore() }
        let file = file(in: data)
        var sessions = file.sessions
        var turns = file.turns
        // Turns written before sessions existed belong to one restored session, dated by the oldest
        // of them. Losing the history to a schema change is the worse option; labelling it
        // "earlier" is the honest one.
        if sessions.isEmpty, !turns.isEmpty {
            let started = turns.map(\.at).min() ?? Date()
            sessions = [ConversationSession(startedAt: started, start: .restored)]
        }
        if sessions.isEmpty {
            sessions = [ConversationSession(startedAt: Date(), start: .launch)]
        }
        let restoredID = sessions.first?.id
        for index in turns.indices where turns[index].sessionID == nil {
            turns[index].sessionID = restoredID
        }
        // Same for the level inside the session. A file with turns and no chats predates threads, so
        // the grouping runs over it once and the result is written back on the next save — from then
        // on the boundaries are fixed data, not a re-derivation.
        var chats = file.chats
        if turns.contains(where: { $0.chatID == nil }) || (chats.isEmpty && !turns.isEmpty) {
            let assigned = assignChats(to: turns)
            turns = assigned.turns
            chats.append(contentsOf: assigned.chats)
        }
        return ConversationStore(turns: turns, sessions: sessions, chats: chats,
                                 currentSessionID: sessions.last?.id,
                                 currentChatID: chats.last?.id)
    }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        return try? encoder.encode(File(sessions: sessions, chats: chats, turns: turns))
    }

    /// The on-disk shape. A struct rather than a dictionary so the three lists cannot be written
    /// with keys that drift from the reader's.
    private struct File: Codable {
        var sessions: [ConversationSession]
        var chats: [ConversationChat]
        var turns: [ConversationTurn]
    }

    @discardableResult
    public func save(to url: URL = ConversationStore.defaultURL) -> Bool {
        guard let data = encoded() else { return false }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}

private extension String {
    /// Lowercased word components with punctuation stripped, so "Compose message." and "message"
    /// are the same token to the recall scorer.
    func lowercaseComponents() -> [String] {
        lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
