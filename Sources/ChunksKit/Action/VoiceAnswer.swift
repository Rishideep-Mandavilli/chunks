import Foundation

/// Whether a spoken sentence is an **answer to the open card**, or a new question.
///
/// The card today is answered with a mouse: two buttons, half the card's width each. That is fine at a
/// desk and useless when the reason you are talking to the app is that your hands are busy — and the
/// act it is asking about is the one you asked for out loud a second ago. This is the matcher that
/// closes that gap, and it is pure and in ChunksKit for the reason every other safety rule in this app
/// is: the decision of *whether something happens to his machine* has to be testable without a
/// microphone, a screen or a second person.
///
/// **The design rule is that only an exact phrase answers.** A sentence that merely *contains* "yes"
/// is not an answer — "yes and also close the other tab" is a new request with an old question
/// hanging off it, and the safe reading of that is a new turn, not a licence to press. When a new
/// sentence arrives, `ConsentGate` already treats the displaced question as a denial, so the ambiguous
/// case fails toward doing nothing, which is the direction every rule in this file points.
///
/// Deliberately not offered by voice: **"allow always"**. That is a standing instruction about an
/// entire application, and a phrase a mishearing could say. It stays a button.
public enum VoiceAnswer {

    public enum Decision: Equatable, Sendable {
        /// Do the act this card is asking about — the same route as tapping Allow.
        case allow
        /// Do not, and say nothing more — the same route as tapping Not now.
        case deny
        /// Not an answer at all. It is a question, and it starts a turn like any other.
        case notAnAnswer
    }

    /// Whole-utterance phrases that mean yes.
    public static let allowPhrases: Set<String> = [
        "yes", "yeah", "yep", "ok", "okay", "sure", "fine", "alright",
        "allow", "approved", "confirm", "do it", "do that", "go ahead", "go for it",
        "yes please", "please do", "sounds good", "carry on", "keep going", "do",
    ]

    /// Whole-utterance phrases that mean no.
    public static let denyPhrases: Set<String> = [
        "no", "nope", "nah", "not now", "dont", "do not", "dont do it", "dont bother",
        "cancel", "stop", "skip", "ignore", "no thanks", "never mind", "nevermind",
        "hold off", "not yet", "discard", "leave it",
    ]

    /// Decide. `text` is the transcript, exactly as it arrived.
    ///
    /// Punctuation and case are stripped because a transcript is neither: the recogniser capitalises
    /// the first word and ends sentences with a full stop, and "Yes." must mean the same as "yes".
    /// An apostrophe is kept out of the comparison too, which is why "don't" reaches "dont" — the
    /// recogniser writes the contracted form and nobody types it that way.
    public static func decide(_ text: String) -> Decision {
        let phrase = normalise(text)
        guard !phrase.isEmpty else { return .notAnAnswer }
        // Both lists is a contradiction ("no yes"), and one answer neither way is not an answer.
        let isAllow = allowPhrases.contains(phrase)
        let isDeny = denyPhrases.contains(phrase)
        if isAllow && isDeny { return .notAnAnswer }
        if isAllow { return .allow }
        if isDeny { return .deny }
        return .notAnAnswer
    }

    /// The normalised form a phrase is compared in: lowercase, no punctuation, single-spaced.
    static func normalise(_ text: String) -> String {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = lowered.unicodeScalars.filter { scalar in
            !CharacterSetPunctuation.contains(scalar)
        }
        let stripped = String(String.UnicodeScalarView(scalars))
        return stripped.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .joined(separator: " ")
    }

    private static let CharacterSetPunctuation = CharacterSet.punctuationCharacters

    /// The consent outcome this utterance means, or nil when it is not an answer.
    ///
    /// Returns `ConsentGate.Outcome` rather than `Decision` because the caller is the shell, and the
    /// thing it must not get wrong is which button it is pressing: this is the same value the Allow
    /// and Not now rows hand to `answerConfirm`, so a voice answer cannot take a route the card
    /// does not already offer. `alwaysAllowed` is deliberately unreachable from here.
    public static func outcome(for text: String) -> ConsentGate.Outcome? {
        switch decide(text) {
        case .allow: return .allowedOnce
        case .deny: return .denied
        case .notAnAnswer: return nil
        }
    }

    /// What to say back when a voice answer is taken.
    ///
    /// Said out loud because with a card on screen the user is not always looking at it, and an act
    /// he cannot hear is an act he cannot tell apart from one that did not happen — the same rule
    /// that makes the no-card path speak its outcome line.
    public static func acknowledged(_ decision: Decision, question: String) -> String {
        switch decision {
        case .allow:
            return "Allowed: \(question)"
        case .deny:
            return "Not now: \(question)"
        case .notAnAnswer:
            return ""
        }
    }
}
