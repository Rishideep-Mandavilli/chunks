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
        enum Kind { case say, memory, note, point }
    }

    private static let constructs: [Construct] = [
        Construct(start: "<SAY>",    end: "</SAY>",    kind: .say),
        Construct(start: "<MEMORY>", end: "</MEMORY>", kind: .memory),
        Construct(start: "<NOTE>",   end: "</NOTE>",   kind: .note),
        Construct(start: "[POINT:",  end: "]",         kind: .point),
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
            case .point:
                if let target = ResponseParser.parsePoint(hit.inner ?? "") {
                    events.append(.point(target))
                } else {
                    // Malformed POINT: show it raw rather than losing it.
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

    // MARK: POINT parsing

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
