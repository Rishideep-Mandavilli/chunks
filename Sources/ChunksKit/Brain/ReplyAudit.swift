import Foundation

/// Which parts of a model's reply never became anything — and would otherwise only be visible by
/// watching the card.
///
/// The parser fails *open* by design: an `[ACT:]` it cannot read is shown to the user as the markup
/// the model wrote, because a swallowed click request is worse than a visible one. That is the right
/// behaviour on his screen and a terrible one in front of a room — measured 2026-11-01 with a local
/// model, the only way to find out that Gemma writes `[ACT:DO:open_app:Chrome]` (a tool inside the act
/// grammar) was to see the raw tag sit on the card mid-demo.
///
/// So this is the same question asked off the card. It runs the reply through the live
/// `AnswerStreamer` — never a second parser — and reports, for every construct-shaped thing in the
/// text, whether it became a request and whether its markup survived into what the card would show.
/// The verdicts are cross-checked against the streamer's own `unreadActTags`, so an audit that drifts
/// from the parser says so out loud instead of reporting a clean reply.
public struct ReplyAudit: Sendable {

    public struct Finding: Sendable, Equatable {
        /// The construct as the model wrote it, cut to `maxTagDisplayCharacters`.
        public let tag: String
        /// ACT, TYPE, SCROLL, DO, POINT, READ, or the angle-block family.
        public let family: String
        /// A request the shell could run came out of it.
        public let becameARequest: Bool
        /// Its markup is still in the text the card would draw.
        public let visibleOnCard: Bool
        /// Why, in one clause — which reader refused it, or what it filled.
        public let reason: String

        public init(tag: String, family: String, becameARequest: Bool,
                    visibleOnCard: Bool, reason: String) {
            self.tag = tag
            self.family = family
            self.becameARequest = becameARequest
            self.visibleOnCard = visibleOnCard
            self.reason = reason
        }

        /// The failure the user asked to see without a live demo: nothing ran, and the tag sits on
        /// the card under a spoken sentence that promised it had.
        public var isMalformed: Bool { !becameARequest && visibleOnCard }

        /// The quieter kind: consumed, and produced nothing. A malformed `<MEMORY>` block is this on
        /// purpose; a `<SUMMARY>` the parser lost is a bug. The audit cannot tell the two apart, so it
        /// lists the family and lets the reader decide.
        public var isSwallowed: Bool { !becameARequest && !visibleOnCard }
    }

    public let findings: [Finding]
    /// Everything the card would show for this reply — speech and detail together.
    public let cardText: String
    /// The streamer's own count of act-shaped tags it had to show as text, which the findings are
    /// checked against. Zero findings and a non-zero count here means this audit is wrong, not that
    /// the reply was clean.
    public let unreadActTags: Int
    /// The requests the same parse produced, so a caller can ask what the *plan* would do without
    /// running a second streamer that might disagree with this one.
    public let requests: [ActionRequest]
    public let tools: [DoRequest]

    public init(findings: [Finding], cardText: String, unreadActTags: Int,
                requests: [ActionRequest], tools: [DoRequest]) {
        self.findings = findings
        self.cardText = cardText
        self.unreadActTags = unreadActTags
        self.requests = requests
        self.tools = tools
    }

    public var malformed: [Finding] { findings.filter(\.isMalformed) }
    public var swallowed: [Finding] { findings.filter(\.isSwallowed) }

    /// Whether the mismatch between this audit and the streamer's own counter is worth shouting about.
    public var disagreesWithTheStreamer: Bool {
        let visibleActs = findings.filter {
            $0.family == "ACT" || $0.family == "TYPE"
        }.filter { $0.visibleOnCard && !$0.becameARequest }.count
        return visibleActs > 0 ? unreadActTags == 0 : unreadActTags > 0
    }

    /// A tag on a card is read at a glance and so is an audit line, and a 40,000-character C file
    /// quoted back as a `TYPE:` payload would otherwise fill the terminal.
    public static let maxTagDisplayCharacters = 72

    /// Audit one complete reply.
    ///
    /// The whole reply arrives in one push on purpose — that is the shape a fast local model produces,
    /// and the shape that once doubled the visible text — so this is the call a live turn is closest
    /// to when the model answers quickly.
    public static func audit(_ reply: String) -> ReplyAudit {
        let streamer = AnswerStreamer()
        streamer.push(reply)
        streamer.finish()
        let displayable = streamer.displayable
        let card = displayable.speech + "\n" + displayable.detail
        var findings: [Finding] = []

        for construct in squareConstructs(in: reply) {
            findings.append(finding(for: construct, card: card, streamer: streamer))
        }
        for block in angleBlocks(in: reply) {
            findings.append(finding(for: block, card: card, streamer: streamer))
        }
        return ReplyAudit(findings: findings,
                          cardText: card.trimmingCharacters(in: .whitespacesAndNewlines),
                          unreadActTags: streamer.unreadActTags,
                          requests: streamer.actionRequests,
                          tools: streamer.toolRequests)
    }

    // MARK: - Square tags

    struct Construct: Equatable {
        let raw: String
        let family: String
        let body: String
        /// Whether a `]` ever arrived. An unclosed construct is a finding of its own — the parser
        /// releases it as text, so the user reads the markup as part of the answer.
        let closed: Bool
    }

    static let squareFamilies = ["ACT", "TYPE", "SCROLL", "DO", "POINT", "READ", "NOTES"]

    /// The `[NAME:…]` shapes in the text, in order.
    ///
    /// Deliberately looser than `ResponseParser`'s own scanner — this is a witness, not a second
    /// route to the same decision. It only reports; every verdict comes from the live readers.
    static func squareConstructs(in text: String) -> [Construct] {
        var found: [Construct] = []
        var search = text.startIndex
        while let bracket = text.range(of: "[", range: search..<text.endIndex) {
            let head = text.index(after: bracket.lowerBound)
            search = head
            guard let family = squareFamilies.first(where: { text[head...].hasPrefix("\($0):") })
            else { continue }
            let bodyStart = text.index(head, offsetBy: family.count + 1)
            let close = text.range(of: "]", range: bodyStart..<text.endIndex)
            let rawEnd = close?.upperBound ?? text.endIndex
            let body = String(text[bodyStart..<min(close?.lowerBound ?? text.endIndex, text.endIndex)])
            found.append(Construct(raw: String(text[bracket.lowerBound..<rawEnd]),
                                   family: family, body: body, closed: close != nil))
        }
        return found
    }

    /// Ask the reader the live turn asks, and say which one refused.
    static func verdict(for construct: Construct, streamer: AnswerStreamer) -> (Bool, String) {
        guard construct.closed else {
            return (false, "the tag never closed, so the parser releases it as text")
        }
        switch construct.family {
        case "ACT":
            // The Gemma shape this probe exists for, named separately because the fix is different:
            // it is not a bad aim, it is a tool written inside the act grammar.
            if construct.body.hasPrefix("DO:") {
                let inner = String(construct.body.dropFirst("DO:".count))
                return DoRequest.parse(inner) != nil
                    ? (false, "a tool written inside the act grammar — the tag Chunks reads is [DO:\(inner)]")
                    : (false, "an act wrapping a tool, and the body is not a tool either")
            }
            return ActionRequest.parseAct(construct.body) != nil
                ? (true, "a press, type or scroll the shell can aim")
                : (false, "parseAct refused the body — neither a named control nor a point it can read")
        case "TYPE":
            if ActionRequest.parseType(construct.body) != nil {
                return (true, "words to type into a field")
            }
            // The live path's own test for a pipe-less tag whose payload arrived as the next text.
            if ActionRequest.parseType(construct.body + "|x") != nil,
               streamer.actionRequests.contains(where: { $0.textToType != nil }) {
                return (true, "no `|` in the tag; the words were gathered from the text after it")
            }
            return (false, "parseType refused it — an aim with no payload, and nothing after it to gather")
        case "SCROLL":
            return ActionRequest.parseScroll(construct.body) != nil
                ? (true, "a list or page to move")
                : (false, "parseScroll refused it — a scroll needs a direction after the `|`")
        case "DO":
            return DoRequest.parse(construct.body) != nil
                ? (true, "a tool the shell can run")
                : (false, "DoRequest refused it — a tool name Chunks does not have, or an argument that is not an effect it can state in one sentence")
        case "POINT":
            return ResponseParser.parsePoint(construct.body) != nil
                ? (true, "a place to point at")
                : (false, "parsePoint refused the body")
        case "READ":
            return ReadRequest.parse(construct.body) != nil
                ? (true, "a file to read")
                : (false, "ReadRequest refused the path or the question")
        case "NOTES":
            // The live path shows an empty search rather than running it, because an empty query
            // against an uncapped file is a request to dump the file into a prompt.
            return !construct.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (true, "a question for the notebook, answered next turn")
                : (false, "an empty [NOTES:] — shown, because searching for nothing would return everything")
        default:
            return (false, "no tag family called \(construct.family)")
        }
    }

    static func finding(for construct: Construct, card: String,
                        streamer: AnswerStreamer) -> Finding {
        let (ran, reason) = verdict(for: construct, streamer: streamer)
        let visible = construct.closed ? card.contains(construct.raw)
            : card.contains("[\(construct.family):")
        return Finding(tag: shorten(construct.raw), family: construct.family,
                       becameARequest: ran, visibleOnCard: visible, reason: reason)
    }

    // MARK: - Angle blocks

    /// The angle families Chunks consumes, and the field each one lands on.
    ///
    /// This list is the product's reply protocol, not a keyword gate on anything he says — it is only
    /// ever matched against markup a *model* emitted, inside a diagnostic.
    static let angleProtocol: [(name: String, opener: String)] = [
        ("SAY", "<SAY>"), ("MEMORY", "<MEMORY>"), ("SUMMARY", "<SUMMARY>"),
        ("DONE_TITLE", "<DONE_TITLE>"), ("NEXT_ACTIONS", "<NEXT_ACTIONS>"),
        ("CONTINUE", "<CONTINUE>"), ("DRAFT", "<DRAFT>"), ("NOTE", "<NOTE>"),
        ("PLAN", "<PLAN>"),
        // The bracket mistakes a small model makes with the one tag that carries the turn onward.
        // Photographed 2026-11-07: `[CONTINUE>` ended a reply, sat on the card as prose, and the
        // second round never ran. The audit has to witness these shapes too, or a regression that
        // puts the markup back on the card reads as a clean reply here.
        ("CONTINUE", "[CONTINUE>"), ("CONTINUE", "[CONTINUE]"), ("CONTINUE", "<CONTINUE]"),
    ]

    static func angleBlocks(in text: String) -> [(name: String, opener: String)] {
        angleProtocol.filter { text.range(of: $0.opener) != nil }
            .map { ($0.name, $0.opener) }
    }

    /// An angle block is judged by what it filled, because its markup is consumed on success and an
    /// unterminated one is released as text — the `</NEXT_ACTIONS` shape that cost a whole reply its
    /// chips on 2026-11-01.
    static func finding(for block: (name: String, opener: String), card: String,
                        streamer: AnswerStreamer) -> Finding {
        let field: String
        switch block.name {
        case "SAY": field = streamer.speech.isEmpty ? "" : "speech"
        case "MEMORY": field = streamer.proposal == nil ? "" : "a memory proposal"
        case "SUMMARY": field = streamer.summary == nil ? "" : "the completion line"
        case "DONE_TITLE": field = streamer.doneTitle == nil ? "" : "the card's label"
        case "NEXT_ACTIONS": field = streamer.nextActions.isEmpty ? "" : "the chips"
        case "CONTINUE": field = streamer.continuation == nil ? "" : "the next round"
        case "PLAN": field = streamer.planSteps.isEmpty ? "" : "the externalized plan"
        case "DRAFT": field = streamer.draftText == nil ? "" : "the copy well"
        case "NOTE": field = streamer.noteLines.isEmpty ? ""
            : "\(streamer.noteLines.count) note(s) for the notebook"
        default: field = ""
        }
        return Finding(tag: shorten(block.opener), family: block.name,
                       becameARequest: !field.isEmpty,
                       visibleOnCard: card.contains(block.opener),
                       reason: field.isEmpty
                            ? "the block was opened and nothing on the card or in the voice carries it"
                            : "filled \(field)")
    }

    static func shorten(_ tag: String) -> String {
        guard tag.count > maxTagDisplayCharacters else { return tag }
        return String(tag.prefix(maxTagDisplayCharacters)) + "…"
    }
}
