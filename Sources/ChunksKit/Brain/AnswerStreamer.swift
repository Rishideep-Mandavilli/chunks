

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

    /// What the model says still has to happen after the acts in this reply. Set when a step of
    /// the user's request could not be aimed at *this* screenshot — the window it needs is not
    /// open yet — so the caller takes a fresh look and continues the same request unasked.
    public private(set) var continuation: String?

    /// The model's `<PLAN>` checklist, parsed into steps. Kept by the shell outside the message
    /// history and re-injected on each continuation so the whole task stays in view (plan-and-execute).
    public private(set) var planSteps: [String] = []

    /// The file the model asked to read, if it asked. One per reply: a turn that wants three
    /// files is a turn that should be asked again after the first is in.
    public private(set) var fileRead: ReadRequest?

    /// `[ACT:…]` proposals, in order. Not executed here: the caller runs each through
    /// `PolicyGate` and then asks the user. Deliberately an array rather than one slot — a
    /// model that proposes two presses in one turn should not have the first silently
    /// replaced by the second before the user has seen either.
    public private(set) var actionRequests: [ActionRequest] = []

    /// How many act-shaped tags arrived that neither grammar could read.
    ///
    /// They are shown to the user as text — the deliberate fail-open — and this is the only trace
    /// that a *promise* was made and no request exists to keep it.
    public private(set) var unreadActTags = 0

    /// `[DO:…]` proposals, in order, for the same reason `actionRequests` is an array. A press
    /// and a tool run are two questions, and the gate only holds one — so a reply that proposed
    /// both keeps both visible to the caller, which asks about one and logs the rest rather
    /// than losing track of what the model actually wanted.
    public private(set) var toolRequests: [DoRequest] = []

    /// Words drafted for him to send himself, last block winning.
    ///
    /// One slot rather than an array because a reply that drafts twice is correcting itself, and two
    /// halves of one message above one Copy button would copy whichever the user did not read.
    public private(set) var draftText: String?

    /// `<NOTE>` lines, in the order they arrived — an array because the notebook is uncapped and two
    /// notes in one reply are two things worth keeping, not one correcting the other.
    ///
    /// Collected, never applied here: `NotebookStore.add` is the only door to the file, and it runs
    /// `SecretSweeper` before anything is written. A streamer that wrote the note itself would be the
    /// model writing his disk, which is invariant 2's rule for memory and applies exactly as hard here.
    public private(set) var noteLines: [String] = []

    /// What the model asked the notebook about, last one winning, for the same reason `fileRead` is
    /// one slot: the answer arrives next turn, and two searches would be two continuations.
    public private(set) var noteSearch: String?

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

    /// Forget everything this reply has accumulated, so a *new* model attempt starts from an empty
    /// card instead of appending to a half answer (AUDIT.md B-03). The panel assigns rather than
    /// appends what the streamer reports, so a reset replaces the half sentence cleanly; without it,
    /// a mid-stream drop made two models write one card and run both their act tags as one plan.
    public func reset() {
        parser = ResponseParser()
        speech = ""
        detail = ""
        points = []
        proposal = nil
        summary = nil
        doneTitle = nil
        nextActions = []
        continuation = nil
        planSteps = []
        fileRead = nil
        actionRequests = []
        unreadActTags = 0
        toolRequests = []
        draftText = nil
        noteLines = []
        noteSearch = nil
        pendingSpeechEcho = nil
        endedMidConstruct = false
    }

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

    /// Set when the stream stopped inside a construct, so the caller can say so out loud.
    public private(set) var endedMidConstruct = false

    /// Flush at the end of the stream. Any unterminated tag is released as text.
    ///
    /// One case is treated as what it is rather than as markup: an unclosed `<SAY>` is a sentence the
    /// model was *saying* when the stream stopped. Measured 2026-11-04 at 15:00, a turn ended exactly
    /// like that — `reply ends ‣ <SAY>you're looking at qoder, where` — and the result was raw markup
    /// on the card and **no speech at all**, because the words never reached `speech`, and the caller
    /// only speaks a non-empty sentence. Silence with nothing in the log is the failure this project
    /// already refuses for an act: something he can neither hear nor find recorded is indistinguishable
    /// from something that never happened. So the partial sentence is spoken as far as it goes, and the
    /// truncation is recorded.
    @discardableResult
    public func finish() -> (speech: String, detail: String) {
        for event in parser.finish() {
            if case .text(let text) = event, let words = Self.unclosedSayContent(text) {
                speech += words
                pendingSpeechEcho = nil
                endedMidConstruct = true
                continue
            }
            // The same rule for the instruction that carries the turn onward. Measured 2026-11-07:
            // the reply ended `[CONTINUE>` — wrong bracket, no closing tag — and because the parser
            // released it as prose the card showed raw markup and the second round never ran, so
            // "open WhatsApp and search" opened the app and stopped there. A continuation is never
            // words for him to read, so an unclosed one is consumed as the instruction it is; an
            // empty body means "carry on with what he asked", which the shell supplies.
            if case .text(let text) = event, let split = Self.unclosedContinuation(text) {
                if !split.before.isEmpty { consume([.text(split.before)]) }
                continuation = split.body
                endedMidConstruct = true
                continue
            }
            consume([event])
        }
        return (speech, detail)
    }

    /// An opening continuation tag with no closing tag anywhere after it, and the prose before it.
    /// nil when this text is not one. The four openers are the taught one plus the three bracket
    /// mistakes a small model makes; a *closed* tag of any shape never reaches here, because the
    /// parser consumes those while streaming.
    static func unclosedContinuation(_ text: String) -> (before: String, body: String)? {
        let openers = ["<CONTINUE>", "[CONTINUE>", "[CONTINUE]", "<CONTINUE]"]
        guard let opening = openers.compactMap({ text.range(of: $0) })
            .min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let after = String(text[opening.upperBound...])
        guard !after.contains("</CONTINUE>"), !after.contains("[/CONTINUE]") else { return nil }
        let before = String(text[..<opening.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = after.trimmingCharacters(in: .whitespacesAndNewlines)
        return (before, body)
    }

    /// The words inside a `<SAY>` that never closed, or nil when this text is not one.
    static func unclosedSayContent(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<SAY>"), !trimmed.contains("</SAY>") else { return nil }
        let body = String(trimmed.dropFirst("<SAY>".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
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
                // A malformed `[ACT:…]`/`[TYPE:…]` reaches the user as text on purpose — see
                // `ResponseParser`. Counting it here is what lets the caller say so in the log,
                // because a reply that promised a click and produced no request is otherwise
                // indistinguishable from a reply that never asked for one.
                if text.contains("[ACT:") || text.contains("[TYPE:") { unreadActTags += 1 }
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

            case .draft(let text):
                // Collected, never appended to `speech` or `detail`: the message is a payload the
                // card holds whole, and prose about it is a different thing. Last block wins, so a
                // reply that drafts twice hands the user one Copy button for the second version.
                draftText = text

            case .typeExtension(let tail):
                // Code carries `]`, which ends the tag early; the rest of the payload arrived as
                // text and is re-joined here, before the act runs, so the field gets the whole of
                // it rather than everything up to the first array bracket.
                if let last = actionRequests.indices.last,
                   case .type(let current) = actionRequests[last].verb {
                    actionRequests[last].verb = .type(text: current + tail)
                }

            case .summary(let text):
                summary = text

            case .doneTitle(let text):
                doneTitle = text

            case .nextActions(let actions):
                // Replace, not append: a model that emits the block twice should not
                // double the chip row.
                nextActions = actions

            case .fileRead(let request):
                fileRead = request

            case .continuation(let line):
                // Last one wins, for the same reason as the chips: a repeated block is the model
                // correcting itself, not a plan that grew.
                continuation = line

            case .plan(let body):
                // Last plan wins: a re-emitted checklist is the model replanning, not a second plan.
                planSteps = TaskPlan.parse(body)

            case .note(let line):
                noteLines.append(line)

            case .noteSearch(let query):
                noteSearch = query
            }
        }
    }

    /// Whether this reply has anything to put on a card.
    ///
    /// A draft counts: "write him a reply" answered with only `<DRAFT>` and no prose is a complete
    /// turn, and a caller that read it as empty would report nothing happened.
    public var hasAnything: Bool { !speech.isEmpty || !detail.isEmpty || draftText != nil }

    /// The line that replaces a promise the machine cannot keep.
    public static let retractionLine =
        "Chunks found nothing on the screen to do that to, so it did nothing."

    /// …and the one for a note he asked to be kept, which cannot use the line above: nothing on the
    /// screen was looked for, and a notebook failure described as a screen failure sends him hunting
    /// for a window that was never the problem.
    public static let noteRetractionLine =
        "Chunks was told to keep that and nothing was written — say it again and I'll note it."

    /// Replace a spoken promise of a scroll, a type or a kept note with an honest line when the reply
    /// queued no such request — and say whether it happened, so the caller can put it in the log.
    ///
    /// Photographed on the five-turn probe under every thinking budget: "scrolling down to find
    /// the invoice now" arrived with no `[SCROLL:]` behind it, because the screen held nothing
    /// scrollable and the model answered the request it imagined rather than the one on screen. A
    /// promise the user can hear and the machine will never keep is the failure this codebase keeps
    /// meeting — with no card to answer, an act nobody reports is indistinguishable from an act that
    /// did not happen, and worse when it never could. The patterns are deliberately promise-shaped
    /// rather than word-shaped, so an *explanation* of scrolling is not retracted; what is left is the
    /// small risk that a first-person promise phrased unusually becomes this line. That line is never
    /// wrong about the one thing it claims: there was no request.
    ///
    /// The note class was added on 2026-11-02, measured the day the tier shipped: asked to "note that
    /// the landlord is Sharma", the local model said *"i have noted that the landlord is sharma"* and
    /// emitted no `<NOTE>` at all. A memory promise is worse than an act promise — an act that did not
    /// happen changes nothing, and a note that did not happen means the thing is not there when he
    /// looks for it a month from now, with nothing on record saying it ever was.
    public func retractUnbackedPromises() -> Bool {
        let text = (speech + " " + (summary ?? "")).lowercased()
        // Promise-shaped, not word-shaped: "scrolling down a list is how you read old chats" is
        // an explanation and must survive; "scrolling down to find the invoice" is a promise the
        // machine will keep or break, and only the promise is retracted.
        let promisedScroll = ["scrolling down to", "scrolling down the", "scrolling up to",
                              "scrolling up the", "scrolling that", "i'll scroll",
                              "i'm scrolling"]
            .contains { text.contains($0) }
        let promisedType = ["i'll type", "i'm typing", "typing that", "typing the",
                            "typing it", "typed that", "typed it"]
            .contains { text.contains($0) }
        let promisedNote = ["i have noted", "i've noted", "i noted", "note that i have",
                            "i'll note", "i'm noting", "i have kept", "i've kept that",
                            "saved to your notebook", "in your notebook now"]
            .contains { text.contains($0) }
        let hasScroll = actionRequests.contains { if case .scroll = $0.verb { return true }
                                                   return false }
        let hasType = actionRequests.contains { if case .type = $0.verb { return true }
                                                return false }
        let hasNote = !noteLines.isEmpty
        let needsScreen = (promisedScroll && !hasScroll) || (promisedType && !hasType)
        let needsNote = promisedNote && !hasNote
        guard needsScreen || needsNote else { return false }
        // Two different failures, two different sentences. The screen line is only right when the
        // screen is what was missing.
        speech = needsNote && !needsScreen ? Self.noteRetractionLine : Self.retractionLine
        summary = nil
        return true
    }
}
