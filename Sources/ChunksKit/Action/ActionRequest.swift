import Foundation

/// Something the model is asking Chunks to *do* to the user's screen, as opposed to explain.
///
/// It carries the same aim a `[POINT]` does — a point on the 0–1000 grid over the image the model
/// was shown, because that is the space the model can actually reason in. Nothing here is a
/// screen coordinate yet: `ScreenshotGeometry` resolves it, and `PolicyGate` decides whether
/// it may happen at all. An `ActionRequest` is a proposal, never a performed act.
public struct ActionRequest: Equatable, Sendable {

    public enum Verb: Equatable, Sendable {
        /// Press the control the target lands on.
        case press

        /// Type `text` into the field the target lands on.
        ///
        /// Its own verb, not a flag on `press`, because the two approve different things: a card
        /// for a press asks about a *control* ("Press Send?") and a card for typing asks about
        /// *words going somewhere* ("Type \"good night\" into the message field?"), and the second
        /// one has to be read before it is allowed. It is also the only verb that can put text the
        /// user never wrote into a form, which is why `AXTDriver` refuses to type until the field
        /// it was asked about is demonstrably the field that has focus.
        case type(text: String)

        /// Move the list or page under the target by `pages` of a page.
        ///
        /// A third verb because the mechanism is different in kind, not just in direction: a
        /// synthetic scroll wheel event moves the user's pointer to the event's location, which is
        /// the one thing invariant 8 forbids, so this goes through the scroll area's own
        /// Accessibility actions and touches no cursor at all.
        case scroll(direction: ScrollDirection, pages: Int)
    }

    /// Which way a scroll moves. Named for what the user says, not for what a delta sign means.
    public enum ScrollDirection: String, Equatable, Sendable, CaseIterable {
        case up, down, left, right

        /// The word the card uses.
        public var phrase: String { rawValue }

        /// Every way the model tends to write a direction.
        static func parse(_ text: String) -> ScrollDirection? {
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "down", "d", "bottom", "forwards", "next": return .down
            case "up", "u", "top", "backwards", "previous", "back": return .up
            case "left", "l", "backward": return .left
            case "right", "r", "forward": return .right
            default: return nil
            }
        }
    }

    public var verb: Verb
    public var target: PointTarget

    public init(verb: Verb = .press, target: PointTarget) {
        self.verb = verb
        self.target = target
    }

    /// The control's name as the model described it — what the confirm card shows before the
    /// real element has been found.
    public var label: String { target.label }

    /// The text to type, or nil for every verb that types nothing.
    public var textToType: String? {
        if case .type(let text) = verb { return text }
        return nil
    }

    /// The direction and distance of a scroll, or nil for every verb that scrolls nothing.
    public var scrollIntent: (direction: ScrollDirection, pages: Int)? {
        if case .scroll(let direction, let pages) = verb { return (direction, pages) }
        return nil
    }

    /// How many acts one reply may queue.
    ///
    /// Five covers "search, open, type, send" with room for a scroll. Beyond that a "plan" is a
    /// model improvising an app's whole workflow from one screenshot, and every step past the first
    /// is aimed at a screen it has not seen. Longer than this stops at the limit and says so.
    public static let maxProgramSteps = 5

    /// The longest block Chunks will type in one act.
    ///
    /// A model that dumps an essay into a `[TYPE:…]` has either misunderstood the request or been
    /// led somewhere the user did not ask for, and thousands of synthetic keystrokes into a live
    /// form is the one act here that cannot be undone by pressing one button. Over the cap it is
    /// not a request at all: it fails to parse and reaches the user as text.
    static let maxTypedCharacters = 1_200

    /// The card's question for a scroll: what moves, which way, how far.
    ///
    /// Lives next to the verb rather than in the shell because the sentence has to be testable
    /// against the words the user asked with, and `--probe-ax` has to print the same question the
    /// card will show — which it cannot do from a main-actor type.
    public static func scrollQuestion(elementLabel: String, direction: ScrollDirection,
                                      pages: Int) -> String {
        let distance = pages == 1 ? "" : " \(pages) pages"
        return "Scroll \(elementLabel) \(direction.phrase)\(distance)?"
    }

    /// The furthest one scroll act may go, in pages.
    ///
    /// A page is an app's own `AXScrollDownByPage`, so ten of them is already a long way down a
    /// list; beyond that the model has stopped asking to *find* something and started asking to
    /// empty a view the user is looking at.
    static let maxScrollPages = 10

    /// Parse a `[SCROLL:x,y:label|down]` body, optionally with a distance: `|down 3`.
    ///
    /// The direction and the number may come in either order, because a model that has just typed
    /// `[TYPE:…]` and `[ACT:…]` in the same conversation writes this tag three ways. Anything that
    /// is not a direction at all returns nil and reaches the user as plain text — the same
    /// fail-open rule as every other tag, and the reason a mistyped scroll never becomes a press.
    public static func parseScroll(_ inner: String) -> ActionRequest? {
        let body = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        let head: String
        var payload: Substring?
        if let bar = body.firstIndex(of: "|") {
            head = String(body[..<bar])
            payload = body[body.index(after: bar)...]
        } else {
            head = body
        }
        guard let point = ResponseParser.parsePoint(head) else { return nil }

        var label = point.label
        if payload == nil, let colon = label.firstIndex(of: ":") {
            payload = label[label.index(after: colon)...]
            label = String(label[..<colon]).trimmingCharacters(in: .whitespaces)
        }
        guard let words = payload else { return nil }

        var direction: ScrollDirection?
        var pages = 1
        for token in words.split(whereSeparator: { $0 == " " || $0 == "," }) {
            let text = token.trimmingCharacters(in: .whitespaces)
            if let parsed = ScrollDirection.parse(text) {
                direction = parsed
            } else if let number = Int(text), number > 0 {
                pages = number
            } else {
                return nil
            }
        }

        guard let parsedDirection = direction, !label.isEmpty,
              pages <= maxScrollPages else { return nil }
        return ActionRequest(verb: .scroll(direction: parsedDirection, pages: pages),
                             target: PointTarget(x: point.x, y: point.y,
                                                 label: label, display: point.display))
    }

    /// Parse a `[TYPE:x,y:label|the text]` body into a request.
    ///
    /// Two label/text separators are accepted because the model writes both: a `|`, which is the
    /// form the prompt teaches and the only one that can carry a text with a colon in it without
    /// argument, and a plain `:` after the label, which is what `[ACT:…]` looks like and what a
    /// model reaches for when it has no `|` in mind. Coordinates come from `parsePoint`, so the
    /// same screen suffix and the same leniency about the label apply.
    ///
    /// Anything that does not fit — no text, an empty label, a text over `maxTypedCharacters` —
    /// returns nil, and the tag is shown to the user as the text it failed to become.
    public static func parseType(_ inner: String) -> ActionRequest? {
        let body = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        let head: String
        var typed: Substring?
        if let bar = body.firstIndex(of: "|") {
            head = String(body[..<bar])
            typed = body[body.index(after: bar)...]
        } else {
            head = body
        }
        guard let point = ResponseParser.parsePoint(head) else { return nil }

        var label = point.label
        if typed == nil, let colon = label.firstIndex(of: ":") {
            typed = label[label.index(after: colon)...]
            label = String(label[..<colon]).trimmingCharacters(in: .whitespaces)
        }

        guard let raw = typed else { return nil }
        var text = String(raw).trimmingCharacters(in: .whitespaces)
        var display = point.display

        // A model that was told "same rules as [ACT:…], including :screenN" writes the screen
        // suffix at the end of the *tag*, which with a `|` separator lands it inside the words to
        // type. Without this the user asks "tell him good night" on the second display and
        // WhatsApp receives "good night:screen2" — text is not a coordinate, so it only moves
        // across when it is the suffix the point parser would have taken.
        if display == 1, let colon = text.lastIndex(of: ":") {
            let tail = String(text[text.index(after: colon)...])
            if tail.lowercased().hasPrefix("screen"), let screen = Int(tail.dropFirst("screen".count)),
               screen >= 1 {
                display = screen
                text = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
            }
        }

        guard !label.isEmpty, !text.isEmpty, text.count <= maxTypedCharacters else { return nil }
        return ActionRequest(verb: .type(text: text),
                             target: PointTarget(x: point.x, y: point.y,
                                                 label: label, display: display))
    }
}
