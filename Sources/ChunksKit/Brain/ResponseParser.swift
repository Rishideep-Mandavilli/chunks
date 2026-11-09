import Foundation

// MARK: - Point target

/// A thing the model wants Chunks to point at on screen.
///
/// Coordinates are **logical points**, never device pixels. `display` is 1-based to match
/// the `[POINT:…screenN]` wire format, and is resolved to a real `CoordinateSpace` by the
/// caller. Never convert here — `CoordinateSpace` is the only type allowed to.
public struct PointTarget: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var label: String
    public var display: Int

    /// The application the model says the control belongs to, when it named one alongside a
    /// coordinate: `app=Qoder x=400,50:file title`.
    ///
    /// Not decoration. A pixel aim is a guess about a picture, and the picture may show three apps;
    /// the named one is evidence the hit test can be checked against, so the qualifier makes the
    /// press stricter rather than looser — see `ActionRequest.parseAct`.
    public var appName: String?

    public init(x: Double, y: Double, label: String, display: Int = 1, appName: String? = nil) {
        self.x = x
        self.y = y
        self.label = label
        self.display = display
        self.appName = appName
    }

    public var point: LogicalPoint { LogicalPoint(x: x, y: y) }
}

// MARK: - Memory proposal

/// What the model *proposes* to remember. Never applied directly — `MemoryStore` validates.
public struct MemoryProposal: Equatable, Sendable {
    public struct Addition: Equatable, Sendable, Codable {
        public var section: MemoryStore.Section
        public var fact: String

        /// What the model *claims* about where the fact came from.
        ///
        /// A claim, not a fact: `MemoryStore.propose` checks it against the transcript of this turn
        /// and downgrades it if his own words are not in there. It exists because the answer changes
        /// what is allowed to retire the line later — an inference off his screen never overwrites
        /// something he said out loud.
        public var claim: MemoryStore.Origin

        /// A substring naming the one stored fact this one replaces, or nil.
        ///
        /// Without it the file can only grow, and a cap that can only grow is a cap that eventually
        /// refuses every correction. One match, or the whole addition is refused — a supersede that
        /// quietly matched nothing is the bug the H-MEM spec itself still has open.
        public var supersedes: String?

        public init(section: MemoryStore.Section, fact: String,
                    claim: MemoryStore.Origin = .inferred, supersedes: String? = nil) {
            self.section = section
            self.fact = fact
            self.claim = claim
            self.supersedes = supersedes
        }
    }
    public var add: [Addition]
    public var prune: [String]

    public init(add: [Addition] = [], prune: [String] = []) {
        self.add = add
        self.prune = prune
    }

    public var isEmpty: Bool { add.isEmpty && prune.isEmpty }

    /// Tolerant decode: a malformed or partial block yields `nil` rather than throwing, so
    /// a bad turn degrades to "no memory written" instead of an error dialog.
    public static func decode(_ json: String) -> MemoryProposal? {
        guard let data = json.data(using: .utf8) else { return nil }
        struct Wire: Decodable {
            struct Add: Decodable {
                var section: String
                var fact: String
                var source: String?
                var supersedes: String?
            }
            var add: [Add]?
            var prune: [String]?
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }

        var out = MemoryProposal()
        out.add = (wire.add ?? []).compactMap { entry in
            guard let section = MemoryStore.Section(rawValue: entry.section) else { return nil }
            return Addition(section: section, fact: entry.fact,
                            claim: entry.source == "he said" ? .said : .inferred,
                            supersedes: entry.supersedes)
        }
        out.prune = wire.prune ?? []
        return out
    }

    public var encodedJSON: String {
        var additions: [[String: Any]] = []
        for one in add {
            var entry: [String: Any] = ["section": one.section.rawValue, "fact": one.fact]
            // Written back only when set, so a round-trip of an ordinary proposal stays byte-identical
            // to what the protocol has always looked like.
            if one.claim == .said { entry["source"] = "he said" }
            if let supersedes = one.supersedes { entry["supersedes"] = supersedes }
            additions.append(entry)
        }
        let obj: [String: Any] = ["add": additions, "prune": prune]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Events

/// One thing that happened while parsing a streamed reply.
public enum ReplyEvent: Equatable, Sendable {
    /// Text to show in the transcript.
    case text(String)
    /// Text to speak aloud. Superset of `text` — spoken, not shown.
    case speech(String)
    /// Fly the cursor to this.
    case point(PointTarget)
    /// The model proposed a memory change. Validate before applying.
    case memory(MemoryProposal)
    /// Words to be sent, written for him to send himself.
    ///
    /// A separate surface rather than ordinary answer text because the answer *is* the payload: he has
    /// to be able to select the whole of it and put it where it belongs. Chunks fills a field and never
    /// presses Send, so a drafted message that only exists as a paragraph of prose is a paragraph he
    /// cannot deliver. This is the tag that carries it, and the card that carries a Copy button.
    ///
    /// Never spoken: reading a draft aloud while he cannot see all of it is worse than the two seconds
    /// it takes to read it once.
    case draft(String)
    /// The tail of a `[TYPE:]` payload that arrived as plain text, because code contains the `]`
    /// that ends the tag. The streamer re-joins it onto the last type request before anything runs.
    case typeExtension(String)
    /// The one line to speak when the turn finishes.
    ///
    /// Distinct from `.speech`: `<SAY>` is narration the model chose to speak *and* show,
    /// while `<SUMMARY>` is the completion utterance — what Chunks says aloud so a
    /// hands-free user learns the turn ended without reading anything. Not shown, because
    /// showing it would duplicate the answer it summarises.
    case summary(String)
    /// One-line label for the notch/chip title.
    case doneTitle(String)
    /// Follow-up suggestions, rendered as tappable chips.
    case nextActions([String])
    /// "…and this still has to happen." Emitted when a step of the user's request cannot be aimed
    /// at the screenshot the model was shown, because the screen that step needs does not exist
    /// yet — WhatsApp's search box while WhatsApp is still closed. Chunks performs the steps it
    /// can see, looks at the screen again, and carries on without being asked twice.
    ///
    /// One line, and it is never shown or spoken: it is an instruction to the app, not content.
    case continuation(String)
    /// The model is asking to act on a control. A proposal only — `PolicyGate` decides
    /// whether it happens, and the user says yes.
    case act(ActionRequest)
    /// A line he asked Chunks to keep, written into the notebook tier — uncapped, never auto-injected.
    ///
    /// Not a `<MEMORY>` block. Memory is 2 KB and is in every prompt, so it can only hold what changes
    /// how Chunks answers *any* question; a note is a thing worth remembering about one subject, and a
    /// file that refuses to grow is a file that refuses the second kind. The write is still validated
    /// by `NotebookStore` (secrets first, then the one-line shape) and never performed by the model.
    case note(String)
    /// The model wants to know what the notebook already holds about something.
    ///
    /// Answered from disk and returned as context for the *next* turn, which is why it is a request
    /// rather than an answer: the model cannot have had the note in front of it when it wrote this
    /// reply. Keyword scoring, no embeddings, and the block comes back labelled as past data — see
    /// `NotebookStore.block(for:)`.
    case noteSearch(String)
    /// The model wants a file read. Refused or granted by `ReadRequest`'s policy before anything
    /// touches the disk, and the contents come back as context for the next turn.
    case fileRead(ReadRequest)
    /// The model is asking for a tool to run: an app opened, the volume changed. Also a
    /// proposal only, and it goes through the same one-question gate as `.act`.
    ///
    /// Not named `.do` — `do` is a keyword, and a case that cannot be written `ReplyEvent.do`
    /// is a case that will confuse whoever reads the switch.
    case tool(DoRequest)
}

// MARK: - Parser

/// Parses Chunks' tagged reply protocol out of a streamed model response.
///
/// The hard part is that replies arrive as SSE deltas, so **a tag can be split across
/// chunks** — `[POINT:12` in one delta and `34,50,Run]` in the next. This parser buffers
/// and only emits text it is certain is final, holding back anything that might still grow
/// into a tag.
///
/// Design rule: **fail open.** An unterminated or malformed tag is shown as ordinary text,
/// never swallowed. Losing a tag is cosmetic; silently eating half the user's answer is not.
public final class ResponseParser {

    private struct Construct {
        let start: String        // literal that opens it
        let end: String?         // literal that closes it, nil if self-closing (e.g. [POINT:…])
        let kind: Kind
        enum Kind { case say, memory, point, act, type, scroll, tool, summary,
                   doneTitle, nextActions, continuation, read, draft, note, noteSearch }
    }

    private static let constructs: [Construct] = [
        Construct(start: "<SAY>",    end: "</SAY>",    kind: .say),
        Construct(start: "<MEMORY>", end: "</MEMORY>", kind: .memory),
        Construct(start: "[POINT:",  end: "]",         kind: .point),
        // Same body format as [POINT:…] — the model is pointing at a control it wants
        // pressed rather than one it wants flown to.
        Construct(start: "[ACT:",    end: "]",         kind: .act),
        // Typing rather than clicking: `[TYPE:x,y:label|the text]`. Its own tag because the body
        // carries words the user has to be able to read before they go anywhere, and because the
        // thing it aims at is a field, which is usually not a pressable control at all.
        Construct(start: "[TYPE:",   end: "]",         kind: .type),
        // Moving a list rather than clicking it: `[SCROLL:x,y:label|down]`. Its own tag because the
        // thing it aims at is a scroll area, which is usually not a control at all, and because a
        // synthetic wheel event would drag the user's pointer along with it — so this verb goes
        // through the element's own Accessibility scroll actions instead.
        Construct(start: "[SCROLL:", end: "]",         kind: .scroll),
        // A tool run rather than a click: `[DO:open_app:Notes]`, `[DO:set_volume:40]`.
        // Its own tag because the body is a name or a number, not a coordinate — and because
        // the thing being approved is not on screen, so the card must not claim it is.
        Construct(start: "[DO:",     end: "]",         kind: .tool),
        // The result protocol HeyClicky closes a turn with: what to say, what to call it,
        // and what to offer next.
        Construct(start: "<SUMMARY>",       end: "</SUMMARY>",       kind: .summary),
        Construct(start: "<DONE_TITLE>",    end: "</DONE_TITLE>",    kind: .doneTitle),
        Construct(start: "<NEXT_ACTIONS>",  end: "</NEXT_ACTIONS>",  kind: .nextActions),
        // Not `<NEXT>`, which would be a prefix of `<NEXT_ACTIONS>` and get eaten by whichever
        // construct is tried first.
        Construct(start: "<CONTINUE>", end: "</CONTINUE>", kind: .continuation),
        // The same instruction with the wrong bracket. Measured 2026-11-07 on his machine: the local
        // brain ended "open WhatsApp and search" with `[CONTINUE>` — square open, angle close, no
        // closing tag — so it reached the card as prose and the second round never ran, and WhatsApp
        // sat open with nothing searched. A continuation is an instruction to the app, never words
        // for him to read, so the shapes a small model actually writes are consumed like the taught
        // one; the unterminated case is caught at flush by `AnswerStreamer`.
        Construct(start: "[CONTINUE>", end: "]", kind: .continuation),
        Construct(start: "[CONTINUE]", end: "]", kind: .continuation),
        Construct(start: "<CONTINUE]", end: "]", kind: .continuation),
        // A file the model needs in front of it to answer at all: `[READ:~/Downloads/build.log|why
        // did it fail]`. Its own tag rather than a `[DO:]` because reading is not an act on the
        // user's behalf — it changes nothing on screen — and because the answer comes back in the
        // *next* turn, with the contents attached, which no other construct does.
        Construct(start: "[READ:", end: "]", kind: .read),
        // Words to be sent, written so he can send them himself: `<DRAFT>…</DRAFT>`. Its own tag
        // rather than a `<SAY>` block because the payload has to survive intact — a message he is
        // about to paste cannot arrive as prose mixed with the explanation of it — and because the
        // card that holds it needs a Copy button, which no other surface on this card has.
        Construct(start: "<DRAFT>", end: "</DRAFT>", kind: .draft),
        // A line worth keeping and not worth paying for on every turn: `<NOTE>the landlord's name is
        // Sharma</NOTE>`. Its own tag rather than a `<MEMORY>` block because memory is capped at 2 KB
        // and injected into every prompt, and this is neither — which is exactly why the second tier
        // had to exist before the tag could be taught again honestly.
        Construct(start: "<NOTE>", end: "</NOTE>", kind: .note),
        // What the notebook already holds: `[NOTES:the landlord]`. A request rather than an answer,
        // in the same shape as `[READ:]` — the model cannot have had the note when it wrote this
        // reply, so the search runs on disk and the labelled block arrives next turn.
        Construct(start: "[NOTES:", end: "]", kind: .noteSearch),
    ]

    private var buffer = ""

    public init() {}

    /// Feed an incremental delta. Returns whatever is now certain.
    public func feed(_ delta: String) -> [ReplyEvent] {
        buffer += delta
        return drain(final: false)
    }

    /// Flush. Any residue — including a half-written tag — becomes text, and any type payload
    /// still gathering from that text is closed into its act.
    public func finish() -> [ReplyEvent] {
        let rest = buffer
        buffer = ""
        var events: [ReplyEvent] = []
        if !rest.isEmpty { settledText(rest, &events) }
        closeTypePayloads(&events)
        return events
    }

    // MARK: Type payloads that arrive as text

    /// A `[TYPE:]` whose body carried an aim but no `|`: a contended model puts the words after
    /// the closing bracket, as plain text — photographed twice on his machine over an empty
    /// editor. The head is kept here and the words are gathered from the text events that follow,
    /// because a type act that never parses is the user's words vanishing, which is the one loss
    /// this parser exists to prevent.
    private var deferredTypeHead: String?
    private var deferredTypePayload = ""

    /// A `[TYPE:]` that parsed: code contains `]`, which ends the construct early, so the rest of
    /// the payload also arrives as plain text and is re-joined onto the request before it runs.
    /// Armed rather than open: a well-formed tag followed by prose on the next line must not gain
    /// that prose, so only text continuing the *same line* re-joins, and it brings back the `]`
    /// the construct consumed.
    private var typeExtensionArmed = false
    private var typeExtensionOpen = false
    private var typeExtensionPayload = ""

    /// Record settled text, feeding any open type payload from it.
    ///
    /// A line that opens a new tag ends the payload: the raw-tag text of a malformed `[ACT:…]`
    /// must not be typed into the editor beside the code it followed.
    private func settledText(_ s: String, _ events: inout [ReplyEvent]) {
        if typeExtensionArmed {
            typeExtensionArmed = false
            if !s.hasPrefix("\n"), !s.hasPrefix(" "), !s.hasPrefix("["), !s.hasPrefix("<"),
               !s.isEmpty {
                typeExtensionOpen = true
                typeExtensionPayload = "]"
            }
        }
        if deferredTypeHead != nil || typeExtensionOpen {
            var gathered = s
            var closed = false
            if let tag = ResponseParser.tagBoundary(in: gathered) {
                gathered = String(gathered[..<tag])
                closed = true
            }
            if deferredTypeHead != nil { deferredTypePayload += gathered }
            else { typeExtensionPayload += gathered }
            if closed { closeTypePayloads(&events) }
        }
        events.append(.text(s))
    }

    /// Where a gathered payload must stop: the start of a construct, square or angle.
    ///
    /// Measured live on 2026-11-01 in front of a jury: a local model wrote `[TYPE:368,497:area 51]`
    /// with no pipe, the gatherer took the *next* thing it emitted — `<NEXT_ACTIONS> - press enter on
    /// the search bar` — as the text to type, and Chunks typed 61 characters of markup into the
    /// desktop, because the aim resolved to whatever window owned those pixels. The guard recognised
    /// a line opening `[ACT:` but not one opening `<NEXT_ACTIONS>`, which is a one-character-class
    /// bug in a path whose whole job is to guess.
    ///
    /// A `<` mid-line is still payload: `#include <stdatomic.h>` is the reason this cannot be a
    /// blanket test for the character.
    static func tagBoundary(in text: String) -> String.Index? {
        if text.hasPrefix("[") || text.hasPrefix("<") { return text.startIndex }
        var search = text.startIndex
        while let newline = text.range(of: "\n", range: search..<text.endIndex) {
            let after = newline.upperBound
            if after < text.endIndex, text[after] == "[" || text[after] == "<" { return after }
            search = after
        }
        return nil
    }

    /// Turn whatever the text stream carried into the act it belonged to.
    private func closeTypePayloads(_ events: inout [ReplyEvent]) {
        typeExtensionArmed = false
        if let head = deferredTypeHead {
            deferredTypeHead = nil
            let payload = deferredTypePayload.trimmingCharacters(in: .whitespacesAndNewlines)
            deferredTypePayload = ""
            if !payload.isEmpty, payload.count <= ActionRequest.maxTypedCharacters,
               var request = ActionRequest.parseType(head + "|x") {
                request.verb = .type(text: payload)
                events.append(.act(request))
            }
        }
        if typeExtensionOpen {
            typeExtensionOpen = false
            let ext = typeExtensionPayload
            typeExtensionPayload = ""
            if !ext.isEmpty { events.append(.typeExtension(ext)) }
        }
    }

    // MARK: Draining

    private func drain(final: Bool) -> [ReplyEvent] {
        var events: [ReplyEvent] = []

        while true {
            // Find the earliest construct that starts here and is already complete.
            guard let hit = earliestCompleteConstruct() else { break }

            // Anything before the construct is settled text — and may be the tail of a type
            // payload that arrived without its pipe.
            if hit.range.lowerBound > buffer.startIndex {
                settledText(String(buffer[..<hit.range.lowerBound]), &events)
            }
            if hit.kind != .type { closeTypePayloads(&events) }

            switch hit.kind {
            case .say:
                events.append(contentsOf: emitSay(hit))
            case .memory:
                if let json = hit.inner {
                    if let proposal = MemoryProposal.decode(json), !proposal.isEmpty {
                        events.append(.memory(proposal))
                    }
                    // A malformed MEMORY block is dropped, not shown: it is machine
                    // syntax, and echoing it would confuse the user.
                }
            case .draft:
                let body = (hit.inner ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                // Fail open like every act tag: a swallowed draft is the message he asked for and
                // never got. Over the cap it is shown as text rather than cut, because half a
                // sentence pasted into a chat is worse than the whole tag on the card.
                if body.isEmpty || body.count > ResponseParser.maxDraftCharacters {
                    events.append(.text(String(buffer[hit.range])))
                } else {
                    events.append(.draft(body))
                }
            case .summary:
                if let line = ResponseParser.singleLine(hit.inner) { events.append(.summary(line)) }
            case .doneTitle:
                if let line = ResponseParser.singleLine(hit.inner) { events.append(.doneTitle(line)) }
            case .nextActions:
                let actions = ResponseParser.parseActions(hit.inner ?? "")
                if !actions.isEmpty { events.append(.nextActions(actions)) }
            case .continuation:
                // An empty body is still the instruction — "carry on with what he asked" — and the
                // shell supplies his own sentence for it. Emitting nothing here would consume the
                // tag and lose the round, which is the same dead end as not recognising it at all.
                events.append(.continuation(ResponseParser.continuationBody(hit.inner ?? "")))
            case .read:
                if let request = ReadRequest.parse(hit.inner ?? "") {
                    events.append(.fileRead(request))
                } else {
                    // Fail open, as every other tag does: a malformed READ shown as text beats a
                    // silent nothing, which the user reads as the question being ignored.
                    events.append(.text(String(buffer[hit.range])))
                }
            case .note:
                let body = (hit.inner ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                // Fail open, as `<DRAFT>` does: a swallowed note is the thing he asked to be kept,
                // and an over-long one shown as markup is better than half of it on disk. The cap is
                // the store's own, so a note this accepts is a note `NotebookStore` will not refuse.
                if body.isEmpty || body.count > NotebookStore.maxEntryCharacters {
                    events.append(.text(String(buffer[hit.range])))
                } else {
                    events.append(.note(body))
                }
            case .noteSearch:
                let query = (hit.inner ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if query.isEmpty {
                    // An empty search is a tag the model did not finish, not a request for the whole
                    // file — and dumping an uncapped notebook into a turn is the failure the budget
                    // exists to prevent.
                    events.append(.text(String(buffer[hit.range])))
                } else {
                    events.append(.noteSearch(query))
                }
            case .point:
                let inner = hit.inner ?? ""
                if ResponseParser.isNoPoint(inner) {
                    // "[POINT:none]" is the model saying there is nothing to point at. It is a
                    // complete answer, not a parse failure, so it is consumed quietly — the
                    // fail-open path below would put "[POINT:none]" on the user's card.
                } else if let target = ResponseParser.parsePoint(inner) {
                    events.append(.point(target))
                } else {
                    // Malformed POINT: show it raw rather than losing it.
                    events.append(.text(String(buffer[hit.range])))
                }
            case .act:
                let inner = hit.inner ?? ""
                if ResponseParser.isNoPoint(inner) {
                    // Same "none" escape as [POINT:] — the model considered acting and
                    // concluded there is nothing to act on. Consumed quietly.
                } else if let request = ActionRequest.parseAct(inner) {
                    // Check if this semantic act is an attempt by a model to launch/open an app:
                    // e.g. [ACT:app=Notes name="Open"] or [ACT:app=Notes name="Notes"] or role=application
                    if let semantic = request.semanticTarget, request.verb == .press {
                        let n = semantic.name.lowercased().trimmingCharacters(in: .whitespaces)
                        let a = semantic.app.lowercased().trimmingCharacters(in: .whitespaces)
                        let r = semantic.role?.lowercased()
                        if n == "open" || n == "launch" || n == a || r == "application" || r == "app" {
                            events.append(.tool(.openApp(name: semantic.app)))
                            break
                        }
                    }
                    // Either a point in the picture or a control named in the accessibility tree;
                    // `parseAct` decides, and the request carries which so the shell can resolve it
                    // without re-reading the tag.
                    events.append(.act(request))
                } else {
                    // A malformed ACT would, unlike a malformed POINT, have asked for a click.
                    // Showing it raw is still the right failure: the user sees the tag instead
                    // of wondering why nothing happened.
                    events.append(.text(String(buffer[hit.range])))
                }
            case .type:
                closeTypePayloads(&events)
                let inner = hit.inner ?? ""
                if let request = ActionRequest.parseType(inner) {
                    events.append(.act(request))
                    // Code carries `]`, which is what just ended this construct: text continuing
                    // the same line is the rest of the payload until the next tag says otherwise.
                    typeExtensionArmed = true
                } else if !inner.contains("|"), ActionRequest.parseType(inner + "|x") != nil {
                    // Aim yes, pipe no: the words are coming as plain text after the bracket.
                    // The tag is still shown — fail-open, unchanged — and the act arrives at
                    // `finish` or at the next tag, from the text in between.
                    deferredTypeHead = inner
                    events.append(.text(String(buffer[hit.range])))
                } else if let lastActIdx = events.lastIndex(where: {
                    if case .act = $0 { return true }
                    return false
                }) {
                    let trailingNonWhitespace = events[(lastActIdx + 1)...].contains {
                        if case .text(let t) = $0 {
                            return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        }
                        return true
                    }
                    if !trailingNonWhitespace, case .act(var prevAct) = events[lastActIdx], prevAct.verb == .press {
                        var textToType = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let colon = textToType.firstIndex(of: ":") {
                            let prefix = textToType[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
                            if prefix == "text" || prefix == "type" || prefix == prevAct.aim.label.lowercased() {
                                textToType = String(textToType[textToType.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                            }
                        }
                        if !textToType.isEmpty, textToType.count <= ActionRequest.maxTypedCharacters {
                            prevAct.verb = .type(text: textToType)
                            events[lastActIdx] = .act(prevAct)
                            typeExtensionArmed = true
                            buffer.removeSubrange(..<hit.range.upperBound)
                            continue
                        }
                    }
                    events.append(.text(String(buffer[hit.range])))
                } else {
                    // The same visible failure as a malformed ACT. This one matters more: a
                    // swallowed `[TYPE:…]` is words the user asked to send that silently vanished.
                    events.append(.text(String(buffer[hit.range])))
                }
            case .scroll:
                if let request = ActionRequest.parseScroll(hit.inner ?? "") {
                    events.append(.act(request))
                } else {
                    // A `[SCROLL:…]` that does not parse is shown rather than dropped: the user
                    // asked to look further down a list, and a swallowed tag reads as Chunks
                    // deciding not to.
                    events.append(.text(String(buffer[hit.range])))
                }
            case .tool:
                if let request = DoRequest.parse(hit.inner ?? "") {
                    events.append(.tool(request))
                } else {
                    // Fail open, and visibly: an unrecognised tool tag becomes text, so the
                    // user can see the model tried to change something. A silently swallowed
                    // `[DO:…]` reads as Chunks ignoring them.
                    events.append(.text(String(buffer[hit.range])))
                }
            }

            // Consume the leading text **and** the construct. Removing only `hit.range`
            // leaves the leading text in the buffer, where the next iteration — or
            // `finish()` — emits it a second time.
            //
            // The bug is invisible when deltas arrive one character at a time, because the
            // leading text has already been drained between deltas. It only appears when a
            // whole reply, or a large chunk of one, arrives at once — which is what a fast
            // model does — and it silently doubled the visible text.
            buffer.removeSubrange(buffer.startIndex..<hit.range.upperBound)
        }

        // Hold back a possible partial construct, unless we're finishing.
        if final {
            if !buffer.isEmpty { events.append(.text(buffer)); buffer = "" }
        } else if let startOffset = partialConstructStartOffset(), startOffset < buffer.count {
            // Only emit when there is something to emit. While the parser waits on a tag
            // that may still arrive, `startOffset` is 0 for every character of it, so
            // emitting unconditionally produced one empty `.text` per character — hundreds
            // of no-op events per turn, each of which made the panel relayout.
            if startOffset > 0 {
                let split = buffer.index(buffer.startIndex, offsetBy: startOffset)
                events.append(.text(String(buffer[..<split])))
            }
            buffer = String(buffer.dropFirst(startOffset))
        }
        return events
    }

    private struct Hit {
        let range: Range<String.Index>
        let inner: String?
        let kind: Construct.Kind
    }

    /// Where this construct's payload ends.
    ///
    /// For every tag but one it is the first `]` after the open, because an `[ACT:]` body is two
    /// numbers and a label and a `[DO:]` body is a name — neither can contain a bracket. `[TYPE:]` is
    /// the exception, and the reason is his code: measured 2026-10-29 against a reply carrying
    /// `uint8_t data[]`, the construct closed at *that* bracket, the rest of the program arrived as
    /// prose beside the act, and the recovery path put a literal `]` back at the front of the next
    /// chunk. For this tag a `]` ends the payload only where the reply's own structure ends it —
    /// nothing follows it, or what follows is another construct. That is a rule about this grammar,
    /// not about whichever language he is typing.
    ///
    /// When no structural end exists the first `]` still wins, so a payload that closes mid-line and
    /// is followed by prose behaves exactly as it did before rather than losing the whole act.
    private static func closeRange<S: StringProtocol>(of c: Construct, in buffer: S,
                                                      from start: S.Index) -> Range<S.Index>? {
        var endCandidates = [c.end].compactMap { $0 }
        if c.kind == .doneTitle {
            endCandidates = ["</DONE_TITLE>", "</DONE>", "</TITLE>"]
        } else if c.kind == .summary {
            endCandidates = ["</SUMMARY>", "</SUM>"]
        }
        var first: Range<S.Index>?
        for candidate in endCandidates {
            if let r = buffer.range(of: candidate, range: start..<buffer.endIndex) {
                if first == nil || r.lowerBound < first!.lowerBound {
                    first = r
                }
            }
        }
        guard c.kind == .type else { return first }
        var searchFrom = start
        while let candidate = buffer.range(of: "]", range: searchFrom..<buffer.endIndex) {
            searchFrom = candidate.upperBound
            // The pipe-less form — `[TYPE:1,2:box]the code` — has no payload *inside* the brackets at
            // all: this bracket ends the aim, and the code arrives after it and is gathered onto the
            // request. The rule below is only for a bracket that is standing inside a payload.
            if !buffer[start..<candidate.lowerBound].contains("|") { return candidate }
            let tail = buffer[candidate.upperBound...].trimmingCharacters(
                in: .whitespacesAndNewlines)
            if tail.isEmpty || tail.hasPrefix("[") || tail.hasPrefix("<") { return candidate }
        }
        return first
    }

    /// The earliest complete `<TAG>…</TAG>` or `[POINT:…]` starting in the buffer.
    private func earliestCompleteConstruct() -> Hit? {
        var best: Hit?

        for c in ResponseParser.constructs {
            var searchStart = buffer.startIndex
            while let s = buffer.range(of: c.start, range: searchStart..<buffer.endIndex) {
                searchStart = s.upperBound
                let afterOpen = s.upperBound
                guard let e = ResponseParser.closeRange(of: c, in: buffer,
                                                         from: afterOpen) else {
                    // Opened but not closed yet — try a later occurrence of the same tag,
                    // but only if another one could still be complete.
                    continue
                }
                let full = s.lowerBound..<e.upperBound
                if best == nil || full.lowerBound < best!.range.lowerBound {
                    let inner = String(buffer[afterOpen..<e.lowerBound])
                    best = Hit(range: full, inner: inner, kind: c.kind)
                }
                break
            }
        }
        return best
    }

    /// Offset in `buffer` where a possibly-incomplete construct begins, if any.
    ///
    /// Returned as an **absolute character offset**, not a length — holding back is then
    /// `buffer.count - offset`. Two cases:
    ///   a. An opening token with no matching close yet (`<SAY>` present, `</SAY>` not).
    ///   b. A bare prefix of an opening token, because the delta ended mid-token (`<SA`).
    ///
    /// Takes the **earliest** such offset. That is the conservative choice: if `<SAY>` is
    /// unclosed at offset 0, nothing before it is safe to emit either, so holding from the
    /// *latest* candidate would leak the tag markup into visible text.
    private func partialConstructStartOffset() -> Int? {
        var candidate: Int?

        func offer(_ offset: Int) {
            if candidate == nil || offset < candidate! { candidate = offset }
        }

        for c in ResponseParser.constructs {
            guard let endToken = c.end else { continue }
            guard let open = buffer.range(of: c.start, options: .backwards) else { continue }
            var endTokens = [endToken]
            if c.kind == .doneTitle { endTokens = ["</DONE_TITLE>", "</DONE>", "</TITLE>"] }
            else if c.kind == .summary { endTokens = ["</SUMMARY>", "</SUM>"] }
            let isClosed = endTokens.contains { buffer.range(of: $0, range: open.upperBound..<buffer.endIndex) != nil }
            if !isClosed {
                offer(buffer.distance(from: buffer.startIndex, to: open.lowerBound))
            }
        }

        // A delta can end partway through the opening token itself, e.g. "<SA".
        for c in ResponseParser.constructs {
            let maxPrefix = min(c.start.count - 1, buffer.count)
            guard maxPrefix > 0 else { continue }
            for take in stride(from: maxPrefix, through: 1, by: -1) {
                if buffer.hasSuffix(String(c.start.prefix(take))) {
                    offer(buffer.count - take)
                    break
                }
            }
        }
        return candidate
    }

    /// `<SAY>` content is both spoken and shown, so it emits both events.
    private func emitSay(_ hit: Hit) -> [ReplyEvent] {
        let spoken = (hit.inner ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return [] }
        return [.speech(spoken), .text(spoken)]
    }

    // MARK: Result protocol helpers

    /// Longest label a notch chip can carry before it stops being readable.
    public static let titleCharacterLimit = 60

    /// Follow-up chips shown at once. HeyClicky offers a short list for the same reason:
    /// more than this is a menu the user has to read, not a set of one-tap replies.
    public static let maxNextActions = 3

    /// Collapse to one trimmed line, or `nil` if there is nothing to show.
    ///
    /// Both `<DONE_TITLE>` and `<SUMMARY>` are meant to be a single line. A model that
    /// answers with a paragraph gets its first sentence rather than a card that overflows,
    /// and an empty block is dropped rather than emitting a blank title.
    /// The longest draft the card can hold.
    ///
    /// A message he has to read before he sends it. Past about six lines the card is a wall of text
    /// with a button under it, and the alternative to refusing the long one is clipping it — a
    /// truncated draft pasted into a chat is a sentence that ends in the middle of a thought, which is
    /// the exact failure `DoRequest.maxQuestionCharacters` was written against.
    public static let maxDraftCharacters = 340

    static func singleLine(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .split(whereSeparator: { $0.isNewline })
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let line = collapsed, !line.isEmpty else { return nil }
        if line.count <= ResponseParser.titleCharacterLimit { return line }
        let cut = String(line.prefix(ResponseParser.titleCharacterLimit))
        // Cut on a word boundary when one is nearby, so a long title does not end mid-word.
        if let lastSpace = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: lastSpace) > 20 {
            return String(cut[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return cut + "…"
    }

    /// The words of a continuation, with any closing tag the bracket shapes leave inside the body
    /// removed: `[CONTINUE]search[/CONTINUE]` closes at the first `]`, which is inside its own
    /// closing tag, so the residue is markup and not part of the sentence he asked for next.
    /// An empty result is meaningful — the shell carries his own question for it — so this returns
    /// a string rather than an optional.
    static func continuationBody(_ raw: String) -> String {
        var body = raw
        for closer in ["</CONTINUE>", "[/CONTINUE]", "</CONTINUE", "[/CONTINUE"] {
            if let range = body.range(of: closer) { body = String(body[..<range.lowerBound]) }
        }
        return singleLine(body) ?? ""
    }

    /// `<NEXT_ACTIONS>` bodies are bullet lists: "- Add a dark theme". Parse into items.
    ///
    /// Tolerant of the formats models actually emit — hyphen, asterisk, numbered, bare
    /// lines, and bullets split across newlines with surrounding blank lines.
    static func parseActions(_ raw: String) -> [String] {
        var out: [String] = []
        for rawLine in raw.split(whereSeparator: { $0.isNewline }) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            // Strip a leading bullet marker, then any space it left behind.
            for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
                line = String(line.dropFirst(marker.count))
            }
            // "1. " / "2) " — digits followed by a separator, at most two digits deep.
            if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }),
               line.startIndex != dot, line[line.startIndex..<dot].allSatisfy({ $0.isNumber }),
               dot < line.endIndex {
                let after = line.index(after: dot)
                if after < line.endIndex, line[after] == " " {
                    line = String(line[line.index(after: after)...])
                }
            }

            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !out.contains(line) else { continue }
            out.append(line)
            if out.count == ResponseParser.maxNextActions { break }
        }
        return out
    }

    // MARK: POINT parsing

    /// Whether the body of a `[POINT:…]` is the model's "nothing to point at" sentinel.
    static func isNoPoint(_ inner: String) -> Bool {
        inner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "none"
    }

    /// `[POINT:x,y:label:screenN]` — the format inherited from the original open-source
    /// Clicky, so models already trained on it produce it.
    ///
    /// Parsed **from both ends**. The screen suffix is stripped off the tail first, then
    /// the label is whatever remains after the second comma. Splitting on every colon
    /// instead would truncate any label containing one, and splitting on every comma would
    /// truncate any label containing one of those.
    /// The aim's own words, with the axis names a model adds taken out.
    ///
    /// Measured 2026-10-29 against his real history: of the twelve `[TYPE:]` tags this build has been
    /// asked to run, four carried an axis letter the tag space never defined — `x:235,y:400`,
    /// `x,625,320`, `x,230,y:360:main.c`, `x=200,380` — and every one of them failed open as raw
    /// markup over an empty editor, which is the user asking twice for the same code. The rule is
    /// structural, not a list of spellings: an axis name is a token made only of `x`/`y`, optionally
    /// joined to its number by `=`, `:` or a comma, sitting at the front of the aim or just after its
    /// first comma. A token, so a label that begins with "x-ray" and an app called "X" are untouched.
    static func stripAxisNames(_ body: String) -> String {
        var text = body
        // `x,625,320`: the whole leading token is an axis name, so the token and its comma both go
        // only when there is still another comma ahead (two coordinates remaining).
        if let comma = text.firstIndex(of: ","),
           isAxisToken(String(text[..<comma])) {
            let remainder = text[text.index(after: comma)...]
            if remainder.contains(",") {
                text = String(remainder).trimmingCharacters(in: .whitespaces)
            }
        }
        // `x:235,y:400` and `x=200,380`: the axis name is glued to its number by a separator.
        text = dropAxisPrefix(from: text)
        guard let comma = text.firstIndex(of: ",") else { return text }
        // …and the same for the second coordinate, which is where `y:` and `y=` appear.
        let tail = dropAxisPrefix(from: String(text[text.index(after: comma)...]))
        return String(text[..<comma]) + "," + tail
    }

    private static func isAxisToken(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        return !trimmed.isEmpty && trimmed.allSatisfy { $0 == "x" || $0 == "y" }
    }

    /// `x:` / `y=` at the front of a coordinate, and nothing else.
    private static func dropAxisPrefix(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let separator = trimmed.firstIndex(where: { $0 == "=" || $0 == ":" }),
              isAxisToken(String(trimmed[..<separator])) else { return trimmed }
        return String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
    }

    static func parsePoint(_ inner: String) -> PointTarget? {
        var body = stripAxisNames(inner.trimmingCharacters(in: .whitespacesAndNewlines))
        var display = 1

        // 1. Strip a trailing ":screenN", if present. Working from the tail is what lets a
        //    label contain colons without being truncated.
        if let colon = body.lastIndex(of: ":") {
            let tail = String(body[body.index(after: colon)...])
            if tail.lowercased().hasPrefix("screen"), let n = Int(tail.dropFirst("screen".count)) {
                display = max(1, n)
                body = String(body[..<colon])
            }
        }

        // 2. `x` is before the first comma, `y` is the leading numeric run after the first comma.
        //    If a model writes "x" or "y" instead of numbers (e.g. `x,480:Ask` or `x,y:label`),
        //    defaulting to 500.0 (the center) recovers the act instead of dropping the command.
        guard let firstComma = body.firstIndex(of: ",") else { return nil }
        let xPart = body[..<firstComma].trimmingCharacters(in: .whitespaces)
        let x: Double
        if let parsedX = Double(xPart) {
            x = parsedX
        } else if xPart.lowercased() == "x" || xPart.lowercased() == "x=" {
            x = 500.0
        } else {
            return nil
        }

        let afterX = body.index(after: firstComma)
        let numericRun = body[afterX...].prefix { "0123456789.+- ".contains($0) }
        var afterY = body.index(afterX, offsetBy: numericRun.count)
        let yPart = body[afterX..<afterY].trimmingCharacters(in: .whitespaces)
        let y: Double
        if let parsedY = Double(yPart) {
            y = parsedY
        } else {
            let nextWord = String(body[afterX...].prefix(while: { $0 != ":" && $0 != "," && $0 != "|" && $0 != " " }))
                .trimmingCharacters(in: .whitespaces).lowercased()
            if nextWord == "y" || nextWord == "y=" {
                y = 500.0
                afterY = body.index(afterX, offsetBy: nextWord.count)
            } else {
                return nil
            }
        }

        // 3. Skip the separator, then whatever remains is the label.
        var label = String(body[afterY...])
        if let separator = label.firstIndex(where: { $0 == "," || $0 == ":" }) {
            label = String(label[label.index(after: separator)...])
        }

        return PointTarget(x: x, y: y,
                           label: label.trimmingCharacters(in: .whitespaces),
                           display: display)
    }
}
