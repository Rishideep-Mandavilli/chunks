import Foundation

/// The words that mean "end this conversation and start another".
///
/// Recognised in the shell, before the capture and before the model, for two reasons. Latency: a
/// turn that costs nothing should not cost a screenshot and a 6-second request. And honesty: if the
/// model answers "sure, starting a new conversation!" while the shell still holds the old one, the
/// feature is a lie — so the thing that changes the state has to be the thing that hears the words.
///
/// Deliberately narrow. "forget what I told you" is *not* here, because `forget` already means
/// something else in this product: the memory file's prune verb. A phrase that could belong to
/// either must go to the one that is already built.
public enum SessionIntent {

    /// The whole utterance has to be about starting over.
    ///
    /// Six words is the ceiling: "new session of the podcast is on screen" contains the phrase and
    /// is not a request to reset, while every genuine reset measured so far fits in five.
    static let maxWords = 6

    /// Phrases matched against the normalized utterance, so "a new session" and "new session" are
    /// the same thing and "renew session" is not a match at word boundaries.
    static let phrases: [String] = [
        "new session", "new conversation", "new chat", "fresh session", "fresh conversation",
        "start over", "start again from the beginning",
        "clear this conversation", "clear the conversation",
        "clear this session", "clear the session",
        "end this conversation", "end this session",
    ]

    public static func isNewSession(_ text: String) -> Bool {
        let words = normalized(text)
        guard !words.isEmpty, words.count <= maxWords else { return false }
        let joined = " " + words.joined(separator: " ") + " "
        return phrases.contains { joined.contains(" \($0) ") }
    }

    /// Whether this question points at something he was told *before*, rather than at the screen.
    ///
    /// The gate on cross-session recall. Searching the archive on every turn would cost prompt
    /// whether or not it found anything, and a live question that happened to share a word with an
    /// old one would arrive with the old answer attached — the model would then be describing a
    /// window he closed yesterday while asking about the one in front of him.
    ///
    /// Markers are phrases a person uses to reach backwards. A false positive costs one wasted
    /// search that finds nothing; a false negative costs him being told "I don't have that", so the
    /// list leans wide.
    static let pastMarkers: [String] = [
        "earlier", "before", "yesterday", "last time", "last week", "last night", "this morning",
        "the other day", "previous", "again", "remember when", "you said", "we said", "you told",
        "did i ask", "what did i ask", "did you answer", "did we talk", "we talked", "what we were",
        "where were we", "continue what", "in another session", "the last session", "that session",
        "from before", "way back", "initially", "first thing",
    ]

    public static func refersToPast(_ text: String) -> Bool {
        let words = normalized(text)
        guard !words.isEmpty else { return false }
        let joined = " " + words.joined(separator: " ") + " "
        return pastMarkers.contains { joined.contains(" \($0) ") }
    }

    /// Lowercased, word-only, so "New Session!" and "new session" are the same utterance.
    private static func normalized(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
