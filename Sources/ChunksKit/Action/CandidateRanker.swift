import CoreGraphics
import Foundation

/// A pressable thing read out of an app's tree, kept as plain data so *which thing* is a decision
/// that can be tested with no browser open.
///
/// Everything on this type is what the application published, nothing is what the model said.
/// `ownNames` is the element's title and description — the words the app asserts *about* the
/// control. `childrenText` is the words drawn *inside* it, which in web content is the only text a
/// control carries: Chromium hands Chunks an `AXGroup` with no title at all and an `AXStaticText`
/// child that says "Run". A named search that reads only the first half refuses a button the user
/// can see, which is the hole this type exists to fill.
public struct CandidateElement: Equatable, Sendable {
    public var role: String
    public var subrole: String?
    public var ownNames: [String]
    public var childrenText: [String]
    /// Global top-left logical points, exactly as Accessibility reports them.
    public var frame: CGRect?
    /// The verb Chunks would perform — `AXPress`, `AXPick` or `AXOpen` — as the element advertised it.
    public var pressVerb: String

    public init(role: String, subrole: String? = nil, ownNames: [String] = [],
                childrenText: [String] = [], frame: CGRect? = nil, pressVerb: String = "AXPress") {
        self.role = role
        self.subrole = subrole
        self.ownNames = ownNames
        self.childrenText = childrenText
        self.frame = frame
        self.pressVerb = pressVerb
    }

    /// Area in square points, or `.infinity` for an element that publishes no frame.
    ///
    /// A control with no frame cannot be located on the screen, so it may never beat one that can:
    /// the whole method is "smallest thing that carries the words", and an unknown size would win it
    /// by default.
    public var area: CGFloat {
        guard let frame else { return .infinity }
        return frame.width * frame.height
    }
}

/// One candidate that survived the ranking, with the evidence that put it there.
///
/// `evidence` is not a detail of the sort — it is what the card is allowed to claim. A control whose
/// own title is "Run" can be asked about as `"Run" button`; one whose title is empty and whose child
/// text says Run has to be asked about as *the button that says "Run"*, because the app never named
/// it and the user deserves to know which kind of words he is approving.
public struct RankedCandidate: Equatable, Sendable {
    public enum Evidence: String, Equatable, Sendable {
        case publishedName
        case childText

        /// The log's word for how the control was identified, so a press that landed somewhere
        /// unexpected can be reconstructed as "matched the app's own name" or "matched a child".
        public var phrase: String {
            self == .publishedName ? "by its own name" : "from a child"
        }
    }

    public var element: CandidateElement
    public var evidence: Evidence
    public var textScore: Int
    /// The exact words that won, from the channel `evidence` names. The card quotes these and only
    /// these, and the re-read before pressing re-checks these.
    public var matchedText: String
    public var distanceToAim: CGFloat?

    public init(element: CandidateElement, evidence: Evidence, textScore: Int,
                matchedText: String, distanceToAim: CGFloat?) {
        self.element = element
        self.evidence = evidence
        self.textScore = textScore
        self.matchedText = matchedText
        self.distanceToAim = distanceToAim
    }

    /// Whether the app itself calls this a control, rather than a region that answers a verb.
    ///
    /// `AXGroup` answering `AXPress` is what a web page's click handler looks like from outside. It
    /// is pressable, and it is not what a person means by "the button", so between two candidates
    /// carrying the same words the one the app named a control wins.
    public var isKnownControl: Bool {
        CandidateRanker.controlRoles.contains(element.role)
            || element.subrole.map { CandidateRanker.controlRoles.contains($0) } == true
    }
}

/// Which of the things on a page a person's words point at.
///
/// The named route scores an element's *own* name and refuses below `minNameScore`; on web content
/// that score is always zero because the name is always empty, so the route cannot reach a single
/// control on most of the modern web. This ranks on three kinds of evidence in a strict order —
/// words first, then what the app says the thing *is*, then geometry — and geometry never
/// qualifies anything on its own. That last rule is the wrong-row bug (`asked for "Nitesh GVP 2",
/// pressed "Tech Eximius 2026"`) stated as a design constraint: nearness is a tie-breaker between
/// two things that both answer the words, and an aim that answers nothing stays a refusal.
public enum CandidateRanker {
    /// The same bar as a named press aim, shared so the two cannot drift: one point on the screen or
    /// one word in a sentence is not enough to press something.
    public static let minTextScore = SemanticTarget.minNameScore

    /// Roles an app publishes for a thing a person would call a control.
    ///
    /// Deliberately short. `AXImage` and `AXStaticText` answer `AXPress` plenty often — desktop
    /// icons are the first case this codebase ever pressed — but they are not *control* roles, and
    /// an image that merely contains the word loses to the button beside it that a screen reader
    /// would call a button.
    public static let controlRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuButton", "AXComboBox", "AXSlider", "AXStepper", "AXIncrementor",
    ]

    /// The words people use for the roles that carry them, so the card can say "link" and not "AXLink".
    static let roleWords: [String: String] = [
        "AXButton": "button", "AXLink": "link", "AXCheckBox": "checkbox",
        "AXRadioButton": "option", "AXPopUpButton": "menu", "AXMenuButton": "menu",
        "AXComboBox": "field", "AXSlider": "slider", "AXStepper": "stepper",
        "AXIncrementor": "stepper", "AXImage": "icon", "AXStaticText": "text",
        "AXTextArea": "field", "AXTextField": "field", "AXList": "list",
        "AXTable": "table", "AXRow": "row", "AXCell": "cell", "AXGroup": "area",
    ]

    /// Rank every candidate the app published and the user could have meant, best first.
    ///
    /// `aim` is the point a pixel-carrying request aimed at, in the same global top-left space as the
    /// frames, and it is used only to separate candidates the words and the role left level. A nil
    /// `aim` — a named request with no coordinate, which is most of what a plan says — leaves ties
    /// unresolved so `tiedTop` can refuse them, because a card that describes two things equally
    /// well describes neither.
    public static func rank(label: String, aim: CGPoint? = nil, windowBounds: CGRect? = nil,
                            candidates: [CandidateElement]) -> [RankedCandidate] {
        var scored: [(RankedCandidate, Int)] = []
        for (treeOrder, candidate) in candidates.enumerated() {
            guard accept(candidate, windowBounds: windowBounds) else { continue }
            guard let scoredCandidate = score(candidate, label: label, aim: aim) else { continue }
            scored.append((scoredCandidate, treeOrder))
        }
        return scored.sorted { left, right in
            outranks(left.0, right.0) || (!outranks(right.0, left.0) && left.1 < right.1)
        }.map(\.0)
    }

    /// Whether a candidate may be considered at all, before any word is compared.
    ///
    /// Two vetoes, both already the law on the named route and both restated here because this is a
    /// second way to reach a control: a menu's rows are addressable whether or not the menu is open,
    /// and a control outside the window the user is looking at is not the one he pointed at.
    public static func accept(_ candidate: CandidateElement, windowBounds: CGRect?) -> Bool {
        if AXTDriver.isMenuRole(candidate.role) { return false }
        guard let frame = candidate.frame, let windowBounds else { return true }
        return windowBounds.insetBy(dx: -1, dy: -1).intersects(frame)
    }

    /// The score, the winning words and the channel they came from — or nil if the words are not there.
    static func score(_ candidate: CandidateElement, label: String,
                      aim: CGPoint?) -> RankedCandidate? {
        let own = bestMatch(names: candidate.ownNames, label: label)
        let child = bestMatch(names: candidate.childrenText, label: label)
        let evidence: RankedCandidate.Evidence
        let textScore: Int
        let matchedText: String
        if let own, own.score >= (child?.score ?? 0) {
            evidence = .publishedName
            textScore = own.score
            matchedText = own.name
        } else if let child {
            evidence = .childText
            textScore = child.score
            matchedText = child.name
        } else {
            return nil
        }
        guard textScore >= minTextScore else { return nil }
        let distance = aim.flatMap { point in
            candidate.frame.map { hypot($0.midX - point.x, $0.midY - point.y) }
        }
        return RankedCandidate(element: candidate, evidence: evidence, textScore: textScore,
                               matchedText: matchedText, distanceToAim: distance)
    }

    /// The strongest-scoring of a list of published strings, with the string kept for the card.
    private static func bestMatch(names: [String], label: String) -> (score: Int, name: String)? {
        var best: (score: Int, name: String)?
        for name in names {
            let score = AXTDriver.nameScore(label: label, title: name)
            if score > 0, score > best?.score ?? 0 { best = (score, name) }
        }
        return best
    }

    /// Words, then kind, then size, then nearness — in that order, and never the other way round.
    ///
    /// Size before nearness because the failure this guards is a *container* winning: a page-wide
    /// `AXGroup` whose descendants include the word is nearer to any aim than the 90×32 button the
    /// user meant, and it is also the wrong thing. The smallest element carrying the words is the
    /// control; the one nearest the aim is only the control *given* that it carries them and is not
    /// a region.
    static func outranks(_ a: RankedCandidate, _ b: RankedCandidate) -> Bool {
        if a.textScore != b.textScore { return a.textScore > b.textScore }
        if a.isKnownControl != b.isKnownControl { return a.isKnownControl }
        if a.element.area != b.element.area { return a.element.area < b.element.area }
        let da = a.distanceToAim ?? .infinity
        let db = b.distanceToAim ?? .infinity
        if da != db { return da < db }
        return false
    }

    /// Whether the top of a ranked list is a coin toss.
    ///
    /// True when nothing in the ordering separates the first candidate from the second, which means
    /// the card's sentence would describe both. The file-read path already makes this a question
    /// rather than a choice; here there is no list to show — there is no press.
    ///
    /// One exception, measured 2026-10-28 on a live Chrome tab: a web control is published *twice*, a
    /// wrapper `AXGroup` and the `AXButton` inside it, at the identical frame — "Mute (m)" came back
    /// as both, 40×40 at (84, 1079). Two nodes describing one box on the screen are not two things the
    /// user could have meant, and refusing them would refuse every control on the page. The ambiguity
    /// this rule is for is between two *different* boxes that answer the same words, like two rows in
    /// a list.
    public static func tiedTop(_ ranked: [RankedCandidate]) -> Bool {
        guard ranked.count >= 2 else { return false }
        let a = ranked[0]
        let b = ranked[1]
        guard !outranks(a, b), !outranks(b, a) else { return false }
        if let first = a.element.frame, let second = b.element.frame, first == second {
            return false
        }
        return true
    }

    /// The noun phrase the confirm card asks about, built only from what the app published.
    ///
    /// `windowBounds` adds where the thing sits, which is the difference between a question the user
    /// can check and one he has to take on faith: "the button that says Run" is a claim about a word,
    /// "the button that says Run at the top-left" is a claim about a word *and* a place he can look at
    /// before he taps Allow.
    public static func cardDescription(for ranked: RankedCandidate,
                                       windowBounds: CGRect? = nil) -> String {
        let roleWord = roleWord(for: ranked.element)
        let text = quoted(ranked.matchedText)
        let naming = ranked.evidence == .publishedName
            ? "the \(roleWord) \(text)"
            : "the \(roleWord) that says \(text)"
        guard let place = positionPhrase(of: ranked.element.frame, in: windowBounds) else {
            return naming
        }
        return "\(naming) at the \(place)"
    }

    /// The card's question, in the same shape as every other press question.
    public static func question(for ranked: RankedCandidate, app: String,
                                windowBounds: CGRect? = nil) -> String {
        "Press \(cardDescription(for: ranked, windowBounds: windowBounds)) in \(app)?"
    }

    static func roleWord(for candidate: CandidateElement) -> String {
        if let word = roleWords[candidate.role] { return word }
        if let subrole = candidate.subrole, let word = roleWords[subrole] { return word }
        return "control"
    }

    /// Quoted, and capped the way every other control name on this card is capped: a tab title is
    /// not a control name and one line of type is what the question row is measured at.
    private static func quoted(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.count > AXElementInfo.labelCharacterBudget
            ? String(trimmed.prefix(AXElementInfo.labelCharacterBudget))
                .trimmingCharacters(in: .whitespaces) + "…"
            : trimmed
        return "\"\(body)\""
    }

    /// A place in the window in the nine words a person uses, or nil when neither is known — or when
    /// the control's own frame says it is not in that rectangle at all.
    ///
    /// The second half matters more than it looks. Measured 2026-10-28 on this Mac: Chrome publishes
    /// its own toolbar at y = −91, above the display's origin, while the page beneath it reports frames
    /// from y = 34. So the ratio of a real control's centre to a real window can be *negative*, and a
    /// phrase built from it by rounding into the nearest band would say "at the top-left" about a
    /// button whose coordinates the app itself has placed off the screen. Saying nothing is the honest
    /// answer: the card still names the control, and a location he cannot verify is not a location.
    static func positionPhrase(of frame: CGRect?, in bounds: CGRect?) -> String? {
        guard let frame, let bounds, bounds.width > 0, bounds.height > 0,
              bounds.insetBy(dx: -1, dy: -1).contains(CGPoint(x: frame.midX, y: frame.midY))
        else { return nil }
        let x = (frame.midX - bounds.minX) / bounds.width
        let y = (frame.midY - bounds.minY) / bounds.height
        let column = x < 0.34 ? "left" : (x < 0.67 ? "" : "right")
        let row = y < 0.34 ? "top" : (y < 0.67 ? "middle" : "bottom")
        switch (row, column) {
        case ("middle", ""): return "centre"
        case ("middle", let c): return c
        case (let r, ""): return r
        case (let r, let c): return "\(r)-\(c)"
        }
    }

    /// Whether the thing found now is still the thing the card described.
    ///
    /// The rule before pressing anything has always been *read it again and compare it to what was
    /// approved*. For a control with a name that comparison was easy — the name is in `AXElementInfo`
    /// and the info either matches or it does not. Here the card quoted the words of a *child*, and
    /// two elements can share a role and a frame while their children changed underneath. So the
    /// approved words are re-checked in the same channel they were found, exactly: a card that said
    /// "Run" is not answered by a press on whatever now says "Stop" in the same box, and a control
    /// that stopped advertising the verb the card was asked about is not pressable at all.
    public static func stillAnswers(_ approved: RankedCandidate,
                                    now candidate: CandidateElement) -> Bool {
        guard approved.element.role == candidate.role,
              approved.element.frame == candidate.frame,
              approved.element.pressVerb == candidate.pressVerb else { return false }
        let names = approved.evidence == .publishedName ? candidate.ownNames : candidate.childrenText
        return names.contains { AXTDriver.nameScore(label: approved.matchedText, title: $0) == 3 }
    }
}
