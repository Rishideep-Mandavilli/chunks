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

    public init(x: Double, y: Double, label: String, display: Int = 1) {
        self.x = x
        self.y = y
        self.label = label
        self.display = display
    }

    public var point: LogicalPoint { LogicalPoint(x: x, y: y) }
}

// MARK: - Memory proposal

/// What the model *proposes* to remember. Never applied directly — `MemoryStore` validates.
public struct MemoryProposal: Equatable, Sendable {
    public struct Addition: Equatable, Sendable, Codable {
        public var section: MemoryStore.Section
        public var fact: String
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
            }
            var add: [Add]?
            var prune: [String]?
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }

        var out = MemoryProposal()
        out.add = (wire.add ?? []).compactMap { entry in
            guard let section = MemoryStore.Section(rawValue: entry.section) else { return nil }
            return Addition(section: section, fact: entry.fact)
        }
        out.prune = wire.prune ?? []
        return out
    }

    public var encodedJSON: String {
        let obj: [String: Any] = [
            "add": add.map { ["section": $0.section.rawValue, "fact": $0.fact] },
            "prune": prune,
        ]
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
    /// The model offered to save an explanation to the Notebook.
    case noteOffer(title: String)
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
        enum Kind { case say, memory, note, point, act, type, scroll, tool, summary,
                   doneTitle, nextActions, continuation, read }
    }

    private static let constructs: [Construct] = [
        Construct(start: "<SAY>",    end: "</SAY>",    kind: .say),
        Construct(start: "<MEMORY>", end: "</MEMORY>", kind: .memory),
        Construct(start: "<NOTE>",   end: "</NOTE>",   kind: .note),
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
        // A file the model needs in front of it to answer at all: `[READ:~/Downloads/build.log|why
        // did it fail]`. Its own tag rather than a `[DO:]` because reading is not an act on the
        // user's behalf — it changes nothing on screen — and because the answer comes back in the
        // *next* turn, with the contents attached, which no other construct does.
        Construct(start: "[READ:", end: "]", kind: .read),
    ]

    private var buffer = ""

    public init() {}

    /// Feed an incremental delta. Returns whatever is now certain.
    public func feed(_ delta: String) -> [ReplyEvent] {
        buffer += delta
        return drain(final: false)
    }

    /// Flush. Any residue — including a half-written tag — becomes text.
    public func finish() -> [ReplyEvent] {
        let rest = buffer
        buffer = ""
        guard !rest.isEmpty else { return [] }
        return [.text(rest)]
    }

    // MARK: Draining

    private func drain(final: Bool) -> [ReplyEvent] {
        var events: [ReplyEvent] = []

        while true {
            // Find the earliest construct that starts here and is already complete.
            guard let hit = earliestCompleteConstruct() else { break }

            // Anything before the construct is settled text.
            if hit.range.lowerBound > buffer.startIndex {
                events.append(.text(String(buffer[..<hit.range.lowerBound])))
            }

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
            case .note:
                let title = (hit.inner ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { events.append(.noteOffer(title: title)) }
            case .summary:
                if let line = ResponseParser.singleLine(hit.inner) { events.append(.summary(line)) }
            case .doneTitle:
                if let line = ResponseParser.singleLine(hit.inner) { events.append(.doneTitle(line)) }
            case .nextActions:
                let actions = ResponseParser.parseActions(hit.inner ?? "")
                if !actions.isEmpty { events.append(.nextActions(actions)) }
            case .continuation:
                if let line = ResponseParser.singleLine(hit.inner) { events.append(.continuation(line)) }
            case .read:
                if let request = ReadRequest.parse(hit.inner ?? "") {
                    events.append(.fileRead(request))
                } else {
                    // Fail open, as every other tag does: a malformed READ shown as text beats a
                    // silent nothing, which the user reads as the question being ignored.
                    events.append(.text(String(buffer[hit.range])))
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
                } else if let target = ResponseParser.parsePoint(inner) {
                    events.append(.act(ActionRequest(target: target)))
                } else {
                    // A malformed ACT would, unlike a malformed POINT, have asked for a click.
                    // Showing it raw is still the right failure: the user sees the tag instead
                    // of wondering why nothing happened.
                    events.append(.text(String(buffer[hit.range])))
                }
            case .type:
                if let request = ActionRequest.parseType(hit.inner ?? "") {
                    events.append(.act(request))
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

    /// The earliest complete `<TAG>…</TAG>` or `[POINT:…]` starting in the buffer.
    private func earliestCompleteConstruct() -> Hit? {
        var best: Hit?

        for c in ResponseParser.constructs {
            var searchStart = buffer.startIndex
            while let s = buffer.range(of: c.start, range: searchStart..<buffer.endIndex) {
                searchStart = s.upperBound
                let afterOpen = s.upperBound
                guard let e = buffer.range(of: c.end ?? "", range: afterOpen..<buffer.endIndex) else {
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
            let isClosed = buffer.range(of: endToken, range: open.upperBound..<buffer.endIndex) != nil
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
    static func parsePoint(_ inner: String) -> PointTarget? {
        var body = inner.trimmingCharacters(in: .whitespacesAndNewlines)
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

        // 2. `y` is the leading numeric run after the first comma. Scanning for it rather
        //    than splitting on a delimiter is what lets the label be introduced by either a
        //    comma or a colon, and lets the label itself contain both.
        guard let firstComma = body.firstIndex(of: ","),
              let x = Double(body[..<firstComma].trimmingCharacters(in: .whitespaces)) else { return nil }

        let afterX = body.index(after: firstComma)
        let numericRun = body[afterX...].prefix { "0123456789.+- ".contains($0) }
        let afterY = body.index(afterX, offsetBy: numericRun.count)
        guard let y = Double(body[afterX..<afterY].trimmingCharacters(in: .whitespaces)) else { return nil }

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
