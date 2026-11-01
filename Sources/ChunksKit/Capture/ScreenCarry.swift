import Foundation

/// Carrying what was on screen into the turn that comes after it.
///
/// The gap this closes is the most ordinary one in a conversation: *"read and understand this
/// problem"* — Chunks looks, thinks, says nothing yet — and then *"now answer it"*. Every turn
/// captures the screen afresh, so on the second turn the only pixels in the request are whatever is
/// up now, which after a switch of windows is not the problem. The answer has to come from the
/// picture he was shown, and today it cannot: the image is thrown away when its turn ends.
///
/// So the last turn's captures are kept, and re-attached **only when his words point back at them**.
/// That condition is the whole design — an extra screenshot costs a thousand tokens and a second of
/// latency on every turn, and a companion that pays it constantly is slower to answer the questions
/// that never referred to anything.
public enum ScreenCarry {

    /// How long a carried screen may still be treated as what he meant.
    ///
    /// The same window a thread uses (`ChatGrouping.gapSeconds`), on purpose: past a quarter hour he
    /// has almost certainly moved on, and answering from a stale picture is worse than asking again.
    public static let validFor: TimeInterval = 15 * 60

    /// Words that point at what he showed rather than at what is on screen now.
    ///
    /// Deliberately phrases rather than single words. `it`, `this` and `here` are how a back-reference
    /// is *written*, and they are also in half the fresh questions about a live screen — "what does
    /// this button do" must not pay for yesterday's screenshot.
    static let phrases: [String] = [
        "i showed", "i showed you", "that i showed", "what i showed",
        "i asked", "what i asked", "that i asked",
        "i said", "what i said", "the problem i", "the question i", "the code i", "the error i",
        "that problem", "that question", "that error", "that screenshot", "that page", "that file",
        "the problem from", "earlier", "just now", "a minute ago", "before this", "the previous",
        "answer it", "solve it", "solve this", "answer this", "do it now", "now answer",
        "now solve", "what was the answer", "still the same",
    ]

    /// Whether this sentence is about a screen he has already shown.
    public static func refersToAShownScreen(_ question: String) -> Bool {
        let lower = question.lowercased()
        return phrases.contains { lower.contains($0) }
    }

    /// Whether a capture this old may still be attached as "what he meant".
    public static func isStillValid(capturedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(capturedAt) <= validFor
    }

    /// The label the carried image is given in the request.
    ///
    /// It has to say *why there are two screens*, or the model reads the second one as a mistake and
    /// answers about the wrong window — the same reason every image on this path carries a label.
    public static func label(age: TimeInterval, previous: String) -> String {
        "the screen as it was \(Int(age))s ago, when he last asked about this — "
            + (previous.isEmpty ? "" : "his question then was \"\(previous)\". ")
            + "the thing he is asking about may no longer be visible; if it is not, answer from "
            + "this picture and say you are reading the earlier screen. "
            // The sentence that matters for safety. Every aim in the reply is resolved against the
            // *live* captures, so a coordinate taken from this picture would land on whatever sits
            // in that spot now — on a screen that has since changed. Pointing at the past is the
            // one thing this image must not invite.
            + "NEVER aim at this picture: point and act only at the live screen, or not at all."
    }
}
