import Foundation

/// Which way a request says *what* to act on.
///
/// The two kinds are not interchangeable and the shell has to know which it got, because they fail
/// differently. A pixel is a guess about an image: it needs a screenshot to map against, and it is
/// the only way to reach web content, which Chromium publishes as unnamed groups. A semantic aim is
/// a statement about the accessibility tree: it needs no screenshot at all, so it can name the
/// search box that only exists after the previous step opened it — which is why a multi-step plan
/// could not previously survive one spoken command.
public enum ActAim: Equatable, Sendable {
    case point(PointTarget)
    case semantic(SemanticTarget)

    /// The words the user would use for the thing, whichever kind of aim found them.
    public var label: String {
        switch self {
        case .point(let target): return target.label
        case .semantic(let target): return target.name
        }
    }
}

/// Something the model is asking Chunks to *do* to the user's screen, as opposed to explain.
///
/// Its aim is either a point on the 0–1000 grid over the image the model was shown — the space a
/// vision model can actually reason in — or a control named in the operating system's vocabulary,
/// `app=WhatsApp role=button name=Send`. Nothing here is a screen coordinate yet in the first case
/// (`ScreenshotGeometry` resolves it) and there is no coordinate at all in the second. `PolicyGate`
/// decides whether either may happen at all. An `ActionRequest` is a proposal, never a performed act.
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
    public var aim: ActAim

    /// Set by the shell when the approved type act carries a focus click into web content.
    ///
    /// Not a thing the model can ask for: no parse path sets it, so a tag can never request a
    /// click — only the resolution of a question he already answered can add one, and the question
    /// names the click before it exists.
    public var webFocusClick: Bool = false

    /// Set by the shell when a named act resolved by *ranking the screen* rather than by matching a
    /// name the app publishes, and the words the card quoted with it.
    ///
    /// The same rule as `webFocusClick`: no parse path may set it, so a tag cannot ask to be resolved
    /// by guesswork. It exists because the press re-resolves its target after the card is answered,
    /// and a re-resolution has to be compared against what the card actually said — for a control
    /// whose only identity is the words drawn inside it, `AXElementInfo` alone is not enough to know
    /// that the box still says the same thing.
    public var rankedAim: RankedCandidate? = nil

    /// Set by the shell when the aim landed on a surface that publishes no Accessibility verb at all
    /// — a web `div` with a click handler — and the approved act is therefore a real click at this
    /// point rather than `AXPress` on an element. The pointer moves there; nothing else can click it.
    ///
    /// Shell-set only, like `webFocusClick`: no tag can ask for it, and it is offered with the point
    /// in the question so what he approves is a place, not a promise about a control.
    public var pointerClickPoint: CGPoint? = nil

    public init(verb: Verb = .press, aim: ActAim) {
        self.verb = verb
        self.aim = aim
    }

    /// The card's question for a type into web content that publishes no field of its own.
    ///
    /// Names the click because the click is part of what he is approving: a caret in a Chromium
    /// editor has no Accessibility verb, so the click is the act rather than a shortcut around one.
    public static func webTypeQuestion(label: String, appName: String, characters: Int,
                                       point: CGPoint) -> String {
        let what = label.isEmpty ? "editor" : label
        return "Click the \(what) at (\(Int(point.x)),\(Int(point.y))) in \(appName) and type "
            + "\(characters) characters into it?"
    }

    /// The common case: an act aimed at a point in the screenshot the model was shown.
    public init(verb: Verb = .press, target: PointTarget) {
        self.init(verb: verb, aim: .point(target))
    }

    /// The control's name as the model described it — what the confirm card shows before the
    /// real element has been found.
    public var label: String { aim.label }

    /// The pixel aim, when the request has one. Everything that maps a request through
    /// `ScreenshotGeometry` works only on this, and a semantic request has nothing to map.
    public var pointTarget: PointTarget? {
        if case .point(let target) = aim { return target }
        return nil
    }

    /// The named-control aim, when the request has one.
    public var semanticTarget: SemanticTarget? {
        if case .semantic(let target) = aim { return target }
        return nil
    }

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
    /// Raised from 1,200 the day he watched a buffer struct get offered for copy instead of typed:
    /// typing the whole code into an editor is the capability the product is for, and 6,000 is the
    /// same order as one turn's read budget. The cap stays because an essay-sized dump is still a
    /// model that misunderstood, and synthetic keystrokes into a live form is the one act here that
    /// cannot be undone by pressing one button. Over the cap it is not a request at all: it fails
    /// to parse and reaches the user as text.
    static let maxTypedCharacters = 6_000

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

    /// The direction and distance after the `|`: `down`, `down 3`, `3 down`.
    ///
    /// Shared by both aims, because what comes after the bar means the same thing whether the list
    /// was pointed at or named.
    static func scrollIntent(words: Substring) -> (direction: ScrollDirection, pages: Int)? {
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
        guard let parsedDirection = direction, pages <= maxScrollPages else { return nil }
        return (parsedDirection, pages)
    }

    /// Parse a `[SCROLL:x,y:label|down]` or `[SCROLL:app=… name=…|down]` body, optionally with a
    /// distance: `|down 3`.
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

        // Named first, and the `|` is required: `app=` and a bare direction are separable only when
        // something marks the boundary, and a scroll that guesses the boundary could read
        // "down" as the list's name.
        if let semantic = SemanticTarget.parse(head) {
            guard let words = payload, let intent = scrollIntent(words: words) else { return nil }
            return ActionRequest(verb: .scroll(direction: intent.direction, pages: intent.pages),
                                 aim: .semantic(semantic))
        }

        guard let point = ResponseParser.parsePoint(head) else { return nil }

        var label = point.label
        if payload == nil, let colon = label.firstIndex(of: ":") {
            payload = label[label.index(after: colon)...]
            label = String(label[..<colon]).trimmingCharacters(in: .whitespaces)
        }
        guard let words = payload, !label.isEmpty, let intent = scrollIntent(words: words)
        else { return nil }
        return ActionRequest(verb: .scroll(direction: intent.direction, pages: intent.pages),
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

        // A field named rather than pointed at: `[TYPE:app=WhatsApp name="Message box"|good night]`.
        // This is the form a plan needs, because the message box does not exist in the screenshot
        // the plan was aimed with — it opened one step ago. The `|` is required here: without it
        // there is no way to tell where a quoted name ends and the words begin.
        if let semantic = SemanticTarget.parse(head) {
            guard let raw = typed else { return nil }
            let text = String(raw).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.count <= maxTypedCharacters else { return nil }
            return ActionRequest(verb: .type(text: text), aim: .semantic(semantic))
        }

        // The qualified-coordinate form ACT learned on 2026-10-25 — `app=Google Chrome x=200,y=400`
        // — photographed again on 2026-10-28 written into a `[TYPE:]`, where it failed open as raw
        // text over an empty editor. The grammar is the same evidence the point path already
        // accepts: a pixel aim plus the app the model says owns it, which makes the press stricter,
        // so accepting it here widens the door without loosening anything behind it.
        if let qualified = qualifiedPointAim(head) {
            guard let raw = typed else { return nil }
            let text = String(raw).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.count <= maxTypedCharacters else { return nil }
            return ActionRequest(verb: .type(text: text), target: qualified)
        }

        let aimText = ResponseParser.stripAxisNames(head)
        guard let point = ResponseParser.parsePoint(aimText) else { return nil }

        var label = point.label
        if typed == nil, let colon = label.firstIndex(of: ":") {
            typed = label[label.index(after: colon)...]
            label = String(label[..<colon]).trimmingCharacters(in: .whitespaces)
        }
        // A contended model writes `[TYPE:248,349|…]` with no label at all. The label feeds the
        // name fallback and the card's wording, neither of which needs it when the pixel aim is
        // there — so an absent one becomes "field" rather than refusing the whole act. An
        // explicitly empty one (`640,910:|…`) stays a refusal: that tag is broken, not terse. The
        // test is on the *axis-stripped* aim, because `x:235,y:400|…` is a terse tag with the axes
        // named, not a tag with an empty label.
        if label.isEmpty {
            guard !aimText.contains(":") else { return nil }
            label = "field"
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

    /// The one tool that may lead a plan, or nil when the reply's combination is not allowed.
    ///
    /// A pixel describes the screenshot the tool has just invalidated — the app it launched now
    /// covers that screen, and old pixels land on whatever the new window put there. So a launch is
    /// allowed in front of a plan only when *every* step is named, because a named step is resolved
    /// against the tree as it is then rather than as it was when the picture was taken. That is the
    /// whole difference between the two aims, and why the rule is about aim rather than about which
    /// tool: `[DO:open_app:]` leading a plan of coordinates would be a licence to press blind.
    ///
    /// More than one tool is refused for the reason the card already refuses two questions — nothing
    /// honest can be said about which one the user allowed.
    public static func leadingTool(for steps: [ActionRequest], tools: [DoRequest]) -> DoRequest? {
        guard !steps.isEmpty, tools.count == 1, let tool = tools.first,
              steps.allSatisfy({ $0.semanticTarget != nil }) else { return nil }
        return tool
    }

    /// Parse an `[ACT:…]` body: a named control if it says so, otherwise a point.
    ///
    /// The two shapes are disjoint — `app=… name=…` has no comma pair, `820,540:Run` has no `=` —
    /// so the semantic reading is tried first and a body that fails it is read as a point. What
    /// must not happen is a *partial* semantic read: a target that lost its app would search every
    /// app on the screen for a control called "Send", and with no pixel to corroborate the guess
    /// there is nothing left to catch it. `SemanticTarget.parse` therefore returns nil rather than
    /// a half answer, and the tag reaches the user as text.
    public static func parseAct(_ inner: String) -> ActionRequest? {
        let body = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        if let semantic = SemanticTarget.parse(body) {
            return ActionRequest(aim: .semantic(semantic))
        }
        if let qualified = qualifiedPointAim(body) {
            return ActionRequest(target: qualified)
        }
        guard let point = ResponseParser.parsePoint(body) else { return nil }
        return ActionRequest(target: point)
    }

    /// A pixel aim the model qualified with an application: `app=Qoder x=400,50:file title`.
    ///
    /// Measured 2026-10-25 on a live turn: the reply said *"holding command and clicking the title
    /// now to show that file in finder"*, wrote that tag, and **both** parsers refused it — the
    /// semantic one because `x` is not a field it knows, the point one because the body does not
    /// start with a number. The tag then sat on the card as markup while the spoken summary promised
    /// the click had happened. A model that has learned to name the app will write this form; the
    /// question is whether accepting it is safe, and it is — the app name becomes a second
    /// requirement the hit test has to answer, checked in the shell before the press.
    static func qualifiedPointAim(_ body: String) -> PointTarget? {
        let (fields, tail) = SemanticTarget.scanFields(body)
        guard let app = fields["app"], !tail.isEmpty else { return nil }
        let found = Array(tail.matches(of: #/\d+(?:\.\d+)?/#).prefix(2))
        guard found.count == 2, let x = Double(found[0].output), let y = Double(found[1].output)
        else { return nil }
        // The label is whatever follows the second number, with the separators the model used to
        // introduce it — `:`, `,`, `|` or a space — trimmed off.
        var label = String(tail[found[1].range.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,:|\"'"))
        if label.isEmpty { label = app }
        return PointTarget(x: x, y: y, label: label, appName: app)
    }
}
