

/// Feeds streaming deltas through `ResponseParser` and reports what is safe to show so far.
///
/// The reason this exists separately from `BrainGateway.interpret` is that showing text
/// *while the model is still writing it* requires incremental parsing, and `interpret`
/// only runs once at the end. Reusing the same parser rather than a second, simpler
/// one matters: a second implementation of the tag grammar would drift, and the drift
/// would show up as markup flashing on screen mid-stream — the exact bug the streaming
/// hold-back in `ResponseParser` exists to prevent.
///
/// A class, not a struct, so it can be mutated from inside the streaming callback without
/// the caller needing a `var` captured by an escaping closure. That is a language rule, not
/// a style preference: `AnswerStreamer` is fed from a closure that escapes into the
/// networking layer, and a `struct` cannot be mutated through one.
public final class AnswerStreamer {

    private var parser = ResponseParser()
    public private(set) var speech: String = ""
    public private(set) var detail: String = ""
    public private(set) var points: [PointTarget] = []
    public private(set) var proposal: MemoryProposal?

    /// The turn's completion line, spoken when the stream ends.
    public private(set) var summary: String?

    /// One-line label for the notch chip / panel title.
    public private(set) var doneTitle: String?

    /// Follow-up suggestions, in the order the model offered them.
    public private(set) var nextActions: [String] = []

    /// `[ACT:…]` proposals, in order. Not executed here: the caller runs each through
    /// `PolicyGate` and then asks the user. Deliberately an array rather than one slot — a
    /// model that proposes two presses in one turn should not have the first silently
    /// replaced by the second before the user has seen either.
    public private(set) var actionRequests: [ActionRequest] = []

    /// `[DO:…]` proposals, in order, for the same reason `actionRequests` is an array. A press
    /// and a tool run are two questions, and the gate only holds one — so a reply that proposed
    /// both keeps both visible to the caller, which asks about one and logs the rest rather
    /// than losing track of what the model actually wanted.
    public private(set) var toolRequests: [DoRequest] = []

    /// What to say aloud *for this turn*, resolved.
    ///
    /// `<SUMMARY>` wins when present: it is the model's deliberate completion line, whereas
    /// `<SAY>` blocks are narration interleaved with work and can be several sentences long.
    /// Falling back to the accumulated `<SAY>` text is what keeps a reply that used no
    /// `<SUMMARY>` still speakable — which is every reply from a model that has not learned
    /// the full protocol yet. The last fallback is the shown detail, for a reply that ignored
    /// the tags altogether: plain prose lands there, and silence is the one failure the user
    /// cannot work around.
    public var utterance: String {
        if let summary, !summary.isEmpty { return summary }
        let spoken = speech.trimmingCharacters(in: .whitespacesAndNewlines)
        if !spoken.isEmpty { return spoken }
        return detail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The `<SAY>` body from the most recent `.speech`, when the next `.text` is expected
    /// to be the "also shown" copy of it.
    ///
    /// `ResponseParser` emits `<SAY>` content as **both** `.speech` and `.text`, because
    /// what is spoken is also written to the transcript. Without this, every sentence the
    /// user hears would also appear in the detail pane, duplicated underneath the speech.
    private var pendingSpeechEcho: String?

    public init() {}

    /// Feed one raw delta. Returns the text that is safe to display right now.
    ///
    /// The parser holds back the ambiguous tail of a split tag, so the returned strings
    /// only ever grow by text that is already decided. They can still *change kind* — a
    /// partial tag may resolve into speech rather than detail — which is why the panel
    /// assigns rather than appends.
    @discardableResult
    public func push(_ delta: String) -> (speech: String, detail: String) {
        consume(parser.feed(delta))
        return (speech, detail)
    }

    /// Flush at the end of the stream. Any unterminated tag is released as text.
    @discardableResult
    public func finish() -> (speech: String, detail: String) {
        consume(parser.finish())
        return (speech, detail)
    }

    /// What to render right now.
    ///
    /// Both parts are trimmed. A typical reply is `<SAY>…</SAY>`, a blank line, then a
    /// `[POINT]`, and the raw buffer collects those newlines — so the panel would otherwise
    /// show a couple of empty lines of secondary text under the answer. Trimming the ends
    /// removes formatting noise without touching content.
    public var displayable: (speech: String, detail: String) {
        (speech.trimmingCharacters(in: .whitespacesAndNewlines),
         detail.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func consume(_ events: [ReplyEvent]) {
        for event in events {
            switch event {
            case .speech(let text):
                speech += text
                pendingSpeechEcho = text

            case .text(let text):
                // The echo of the `<SAY>` just emitted, not new detail.
                if let echo = pendingSpeechEcho, echo == text {
                    pendingSpeechEcho = nil
                    break
                }
                pendingSpeechEcho = nil
                detail += text

            case .point(let target):
                points.append(target)

            case .act(let request):
                actionRequests.append(request)

            case .tool(let request):
                // Consumed, never echoed: a `[DO:…]` the streamer dropped would reach the
                // transcript as literal text the user reads aloud as an answer.
                toolRequests.append(request)

            case .memory(let proposed):
                proposal = proposed

            case .noteOffer:
                // A notebook offer is a UI affordance, not text. The panel does not render
                // it yet; dropping it here is why the tag never leaks into the transcript
                // as a literal "<NOTE>".
                break

            case .summary(let text):
                summary = text

            case .doneTitle(let text):
                doneTitle = text

            case .nextActions(let actions):
                // Replace, not append: a model that emits the block twice should not
                // double the chip row.
                nextActions = actions
            }
        }
    }

    public var hasAnything: Bool { !speech.isEmpty || !detail.isEmpty }
}
