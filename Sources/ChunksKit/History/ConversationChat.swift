import Foundation

/// A run of exchanges about one thing, inside one session.
///
/// This is the level the history was missing. A session says *when* he sat down; a turn says *what
/// he asked*; neither says what he was looking at, and the real file proved the gap — nine turns in
/// one session, three of them "Explain this", "I cant" and "?", which as a flat list are three rows
/// that cannot be told apart from three unrelated questions. An application groups those into one
/// thread with one title, and that is what this type is.
///
/// The title is taken from the first exchange, never invented: `ChatGPT` can summarise a thread
/// because it makes a model call per thread. Chunks answers in seconds and would have to spend one
/// to name a list row, so the title is the `<DONE_TITLE>` he already saw, or his own words.
public struct ConversationChat: Equatable, Sendable, Codable, Identifiable {

    public var id: UUID
    public var sessionID: UUID
    public var startedAt: Date
    /// The row label. Set once, from the first turn, and then kept — a chat whose name changes as
    /// more is said in it is a list that moves under the cursor.
    public var title: String

    public init(id: UUID = UUID(), sessionID: UUID, startedAt: Date = Date(), title: String) {
        self.id = id
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.title = title
    }
}

/// Which chat a turn belongs to.
///
/// Derived by a rule rather than by a model, for three reasons that are all this project's: it costs
/// no round trip (a turn already spends six seconds, and naming a list row is not worth another), it
/// is deterministic enough to test every branch, and it can be *explained* — "this is the same chat
/// because he said 'this'".
public enum ChatGrouping {

    /// Longer than this and he went away and came back to something else.
    ///
    /// Fifteen minutes, not five: the measured pattern in a screen tutor is a question, a two-minute
    /// read of the answer, then a follow-up. Five minutes split one explanation into three chats.
    public static let gapSeconds: TimeInterval = 15 * 60

    /// A question with no more than this many real words is pointing at something, not naming it.
    ///
    /// "explain this", "i cant", "and the second one", "?" — none of them introduce a subject, so
    /// they continue whatever is open. This is the rule that keeps a thread together when the words
    /// themselves share nothing.
    public static let followUpWordLimit = 3

    /// Words that refer instead of naming.
    ///
    /// Note that most of these are stop-words to the *search* scorer — "it", "what", "this" carry no
    /// subject to match on. That is exactly why they are the signal here: a question built out of
    /// pointers is not introducing a new thing, it is still looking at the one it was pointed at.
    static let demonstratives: Set<String> = [
        "this", "that", "these", "those", "here", "there", "one", "ones", "same", "again", "it",
        "them", "cant", "cannot", "ok", "okay", "sure", "keep", "continue", "more",
        "second", "third", "first", "next",
    ]

    /// What is *not* in that list, and why it matters.
    ///
    /// "why", "what", "how" and "which" look like pointers and are not: "why is the certificate
    /// warning showing in chrome" has a subject, and treating the interrogative as a pointer filed a
    /// new question under whatever thread happened to be open. Only words that cannot carry a
    /// subject are allowed to decide this.

    /// Whether `turn` continues the chat that is already open.
    ///
    /// - Parameter open: the turns of the chat so far, oldest first. Empty means there is nothing
    ///   open, which is the only case where the answer cannot be "yes".
    public static func continues(open: [ConversationTurn], _ turn: ConversationTurn) -> Bool {
        guard let last = open.last else { return false }

        // 1. He left and came back. The screen will have changed, so the thread is over even though
        //    the words would have matched.
        if turn.at.timeIntervalSince(last.at) > gapSeconds { return false }

        // 2. A pointer, not a subject. Read from the *whole* question, because the words that point
        //    are the ones a search scorer throws away. Measured on the render: with this test run on
        //    content words instead, "type good night and leave it for me" opened its own chat and a
        //    single WhatsApp task read as two unrelated threads.
        let spoken = turn.asked.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if spoken.count <= followUpWordLimit || spoken.contains(where: demonstratives.contains) {
            return true
        }

        // 3. It names something the thread is already about.
        let words = ConversationStore.contentWords(in: turn.asked)
        if words.isEmpty { return true }        // nothing to name, so it must be pointing
        let about = open.reduce(into: Set<String>()) { gathered, existing in
            gathered.formUnion(ConversationStore.contentWords(in: existing.asked))
            gathered.formUnion(ConversationStore.contentWords(in: existing.headline))
        }
        return !words.isDisjoint(with: about)
    }

    /// The label a new chat gets, from the exchange that opened it.
    public static func title(for turn: ConversationTurn) -> String {
        let headline = turn.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        if !headline.isEmpty { return ConversationStore.preview(of: headline) }
        return ConversationStore.preview(of: turn.asked)
    }
}
