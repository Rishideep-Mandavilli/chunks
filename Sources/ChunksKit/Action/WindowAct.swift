import Foundation

/// Which window a spoken sentence names, and what Chunks may do to it.
///
/// The four verbs here are the honest slice of "control every application": bring a window forward,
/// minimise it, close it, quit the app. None of them needs a new permission — Accessibility already
/// publishes the windows and `NSRunningApplication` already terminates an app — and none of them moves
/// the cursor, which is invariant 8's one non-negotiable.
///
/// This half is pure on purpose. Resolution is the part that decides whether something happens to a
/// window he did not name, so it is the part with the negative cases: an app name that matches two
/// processes, a title that matches two windows, a window that is already minimised, and a quit asked
/// for by an app name that is really a helper's. The driver reads the machine; this decides what the
/// reading means.
public struct WindowAct: Equatable, Sendable {

    public enum Verb: String, Equatable, Sendable, CaseIterable {
        /// Bring the window to the front and activate its app.
        case focus
        /// Minimise the window into the Dock. Reversible, so it is not a permanent act.
        case minimize
        /// Close the window. Anything unsaved in it is gone, which is why the card says so.
        case close
        /// Quit the application. Also permanent, and also the one verb that needs no window at all.
        case quit

        /// Whether this verb is asked about even with "Ask before acting" switched off.
        ///
        /// The same rule `PolicyGate.alwaysAskControlWords` applies to a Send button: "don't ask" is a
        /// standing instruction about routine navigation, never an instruction to throw away unsaved
        /// work on a model's say-so. Closing and quitting are exactly that.
        public var isPermanent: Bool { self == .close || self == .quit }

        /// The word the card uses for the verb.
        public var phrase: String {
            switch self {
            case .focus: return "Bring to the front"
            case .minimize: return "Minimise"
            case .close: return "Close"
            case .quit: return "Quit"
            }
        }
    }

    /// One window Chunks can see, as the driver reports it.
    ///
    /// `frame` is **Accessibility space: global logical points, top-left origin** — the same space
    /// `AXTDriver` hit-tests in, and not the space a screenshot or an `NSWindow` frame is in. Nothing
    /// in this file reads it, and the first thing that does (moving or resizing a window) has to go
    /// through `CoordinateSpace` like every other coordinate in this app. It is carried because a card
    /// that can say *which* of two same-named windows is which has to know where they are, and because
    /// invariant 1's bug is silent: a top-left frame fed to a bottom-left API lands at double the
    /// intended offset on Retina and looks plausible.
    public struct Candidate: Equatable, Sendable {
        public var pid: Int
        public var appName: String
        public var title: String
        public var frame: CGRect
        public var isMinimized: Bool
        /// Whether this is Finder's desktop rather than a window.
        ///
        /// The desktop is published as a window — it has a frame, a title slot and an element — and it
        /// was offered to verbs until 2026-11-03, when the geometry probe cheerfully computed a plan to
        /// "move the desktop to the left half" and `--probe-windows Finder` printed *Minimise "desktop"
        /// in Finder?*. Writing a new frame to it does not tidy anything; it disturbs the layout of his
        /// icons. Listing it is correct (it is genuinely on the screen); acting on it is not.
        ///
        /// Decided in the driver from two facts only an actual desktop has together: no `AXTitle` of its
        /// own, and a frame exactly the whole of a display. A full-screen app's window is the same size
        /// but always has a title, so it is not caught — and must not be, because moving that is real work.
        public var isDesktop: Bool
        /// Whether this window is the one its app has focused, so "the front window" is answerable.
        public var isFocused: Bool
        /// Whether Chunks can *do anything* to this window, which is not the same as seeing it.
        ///
        /// True when Accessibility published it — an element exists, so a verb has something to act on.
        /// False when only the window server knows about it, which is what happens to every window of an
        /// app that is not on the display he is looking at: measured 2026-11-03, Chrome's "GVPCE" tab is
        /// listed by the window server and published as *no window at all* by Accessibility. Such a
        /// window belongs in the listing — the feature exists to answer "what is open", not "what is
        /// visible" — and must never be offered a card, because an Allow that leads to
        /// `element(for:) == nil` is a question that cannot be honoured.
        ///
        /// This is the only spatial claim the listing makes. An earlier version also carried "is this
        /// window on the active Space", worked out by matching rectangles between the two APIs, and it
        /// was wrong twice on the first run: Finder's desktop — drawn on every Space — came back as
        /// "another Space", and so did the window he was typing into while a different app was frontmost.
        /// Reachability is read from the same API that would perform the act, so it cannot disagree with
        /// the act. Where a window is, Chunks does not claim to know.
        public var isReachable: Bool

        public init(pid: Int, appName: String, title: String, frame: CGRect,
                    isMinimized: Bool = false, isFocused: Bool = false,
                    isReachable: Bool = true, isDesktop: Bool = false) {
            self.pid = pid
            self.appName = appName
            self.title = title
            self.frame = frame
            self.isMinimized = isMinimized
            self.isFocused = isFocused
            self.isReachable = isReachable
            self.isDesktop = isDesktop
        }

        /// The name a card shows. A window with no title of its own is named by its app, because
        /// "Close the window in Safari?" is a question he can answer and "Close \"\"?" is not.
        public var displayName: String {
            title.isEmpty ? appName : title
        }
    }

    public enum Resolution: Equatable, Sendable {
        case one(Candidate)
        /// More than one window answered equally. Refused rather than asked about: two windows with
        /// the same name are two different documents, and a card that quoted one of them would be
        /// asking him to approve a guess about which.
        case ambiguous([Candidate])
        case none
        /// The app is not running at all, which is a different sentence from "it has no such window".
        case appNotRunning(String)
        /// The window is there and Chunks can name it, but only the window server knows it — an app on
        /// another Space publishes no Accessibility element, so there is nothing to raise or close. A
        /// fourth answer, because "I can't see it" would be a lie and a card would be a promise Chunks
        /// cannot keep.
        case unreachable(Candidate)
        /// The candidate is the desktop, which is published as a window and must never be treated as
        /// one: a fifth answer rather than a filter, so that "minimise the desktop" is refused with the
        /// reason instead of silently doing nothing or disturbing his icon layout.
        case notAWindow(Candidate)
    }

    /// Resolve a spoken window into one candidate, or say precisely why it could not.
    ///
    /// `title` may be nil — "close Safari" with one window open is answerable, and demanding a title
    /// there would be a refusal about a window he can see. What is never done is choosing between two
    /// equal answers by *where they are*: geometry separates candidates the words left level, it does
    /// not qualify one, which is the rule `CandidateRanker` was written around after a press landed on
    /// the wrong row of a list.
    public static func resolve(verb: Verb, app: String, title: String?,
                               in candidates: [Candidate]) -> Resolution {
        let owned = candidates.filter { AXTDriver.matchesAppName(label: app, owner: $0.appName) }
        guard !owned.isEmpty else { return .appNotRunning(app) }
        // A window only the window server knows about has no element to act on, so it can be *named*
        // but never raised, minimised or closed. Quitting is the exception: `terminate()` talks to the
        // process, not to a window, so an off-Space app quits perfectly well and its window is only
        // ever quoted to say what is about to close.
        let reachable = owned.filter { $0.isReachable }
        let offSpace = owned.filter { !$0.isReachable }
        guard verb != .quit else {
            let nameable = reachable.first(where: { $0.isFocused }) ?? reachable.first ?? owned.first
            return nameable.map { .one($0) } ?? .none
        }
        // The desktop is published as a window and is not one. It stays in the listing — it is genuinely
        // on the screen — but a verb that reached it would be writing a frame to his icon layout, so the
        // only way to it is a refusal that says what it is.
        let actable = reachable.filter { !$0.isDesktop }
        if actable.isEmpty, let desk = reachable.first(where: { $0.isDesktop }) {
            return .notAWindow(desk)
        }
        guard let asked = title?.trimmingCharacters(in: .whitespacesAndNewlines), !asked.isEmpty
        else {
            // No title: only answerable when the app has one window to mean. Two is a refusal that
            // names them, because "close Safari" with three tabs open is three different losses.
            if actable.count == 1 { return .one(actable[0]) }
            if !actable.isEmpty { return .ambiguous(actable) }
            if let one = offSpace.first { return .unreachable(one) }
            return .none
        }
        let scored = actable.compactMap { candidate -> (candidate: Candidate, score: Int)? in
            guard titleAnswers(asked, title: candidate.title) else { return nil }
            return (candidate, specificity(of: candidate.title, asked: asked))
        }
        guard !scored.isEmpty else {
            if let matched = offSpace.first(where: { titleAnswers(asked, title: $0.title) }) {
                return .unreachable(matched)
            }
            return .none
        }
        let best = scored.map(\.score).max() ?? 0
        // Sorted so a refusal lists the same windows in the same order every time it is asked. This is
        // a display order, not a preference: two candidates that reach here are equal by the words, and
        // the answer is a refusal whichever comes first.
        let winners = scored.filter { $0.score == best }.map(\.candidate)
            .sorted { ($0.appName, $0.title, $0.frame.origin.x) < ($1.appName, $1.title, $1.frame.origin.x) }
        // The same frame twice is one window published twice — Chromium does this for controls, and a
        // window server that lists a window and its shadow would otherwise refuse everything.
        let distinct = distinctByFrame(winners)
        if distinct.count == 1 { return .one(distinct[0]) }
        return .ambiguous(distinct)
    }

    /// Which window a *placement* sentence names.
    ///
    /// Deliberately focus's rules rather than close's: a move is reversible and loses nothing, so the
    /// one thing that matters is picking the right window and not picking two. The choice logic is not
    /// reimplemented here, because a second copy of "every distinctive word must answer, two equal
    /// answers are refused with both listed, position never decides" is how the two verbs would start
    /// disagreeing about which window he meant.
    public static func resolvePlacement(app: String, title: String?,
                                        in candidates: [Candidate]) -> Resolution {
        resolve(verb: .focus, app: app, title: title, in: candidates)
    }

    /// Whether a window's title answers the words he said: every distinctive word he used has to be in
    /// it.
    ///
    /// A subset test rather than `AXTDriver.nameScore`, and the difference was measured the day this
    /// was built. `nameScore` is the right rule for a *control* — one shared token there is a guess
    /// about a button, and a wrong guess presses something. A window title is long and specific, so
    /// "TASKS.md" naming a window called "Chunks — TASKS.md" is not a guess, and score-wise it came out
    /// as one: `nameScore` awards 3 only for an exact token-set match and 2 for a prefix, so the most
    /// natural sentence about a document window was refused. The other direction still refuses, which
    /// is the point of keeping a rule at all: "the document" shares no distinctive word with any title,
    /// and an ambiguous answer is caught by the two-match refusal rather than by demanding more words
    /// than he said.
    static func titleAnswers(_ asked: String, title: String) -> Bool {
        let wanted = Set(AXTDriver.tokens(in: asked))
        guard !wanted.isEmpty else { return false }
        return wanted.isSubset(of: Set(AXTDriver.tokens(in: title)))
    }

    /// Between two titles that both answer, the more specific one wins.
    ///
    /// An exact match first, then the title with the fewest extra words — "Inbox" beats "Inbox — 3
    /// unread — Mail" for a request that said "Inbox". Specificity, never position: a tie here is a
    /// refusal, and `distinctByFrame` is the only place a rectangle is allowed to mean anything.
    static func specificity(of title: String, asked: String) -> Int {
        let exact = title.caseInsensitiveCompare(asked) == .orderedSame ? 1_000 : 0
        return exact - AXTDriver.tokens(in: title).count
    }

    /// Candidates that occupy the same rectangle are one window, not a choice between two.
    static func distinctByFrame(_ candidates: [Candidate]) -> [Candidate] {
        var seen: [CGRect] = []
        var out: [Candidate] = []
        for candidate in candidates {
            guard !seen.contains(candidate.frame) else { continue }
            seen.append(candidate.frame)
            out.append(candidate)
        }
        return out
    }

    /// The card's question. One sentence, present tense, names the window and the app that owns it,
    /// and says out loud what a permanent verb costs.
    ///
    /// The cost is in the question rather than in a second line because the question is the thing he
    /// approves: "Close config.yml in Code?" reads as tidying, and the unsaved buffer is the part that
    /// makes it not.
    public static func question(verb: Verb, candidate: Candidate) -> String {
        // A window whose title *is* its app's name is named once. Photographed on the first live run of
        // `--probe-windows`: Qoder's own window answered `"Qoder" in Qoder`, which is the kind of
        // sentence that makes a card unreadable at the exact moment it is asking about closing something.
        let sameName = candidate.title.isEmpty
            || candidate.title.caseInsensitiveCompare(candidate.appName) == .orderedSame
        let what = sameName ? candidate.appName
            : "\"\(candidate.title)\" in \(candidate.appName)"
        switch verb {
        case .focus:
            return "Bring \(what) to the front?"
        case .minimize:
            return "Minimise \(what)?"
        case .close:
            return "Close \(what)? Anything unsaved in it is gone."
        case .quit:
            return "Quit \(candidate.appName)? Anything unsaved in it is gone."
        }
    }

    /// The refusal, in his words, naming what Chunks could see instead.
    ///
    /// A bare "no such window" is the failure `reportNamedMiss` exists to avoid: he cannot tell a
    /// window Chunks cannot see from one he misnamed, and the second is one word away from working.
    public static func refusal(verb: Verb, app: String, title: String?,
                               resolution: Resolution) -> String {
        switch resolution {
        case .one, .ambiguous([]):
            return ""
        case .appNotRunning(let name):
            return "\(name) is not running, so there is no window to \(verb.phrase.lowercased())."
        case .none:
            return "Chunks found no window called \"\(title ?? "")\" in \(app)."
        case .ambiguous(let candidates):
            let names = candidates.prefix(4).map { "\"\($0.displayName)\"" }.joined(separator: ", ")
            let extra = candidates.count > 4 ? ", and \(candidates.count - 4) more" : ""
            return "\(candidates.count) windows in \(app) answer that: \(names)\(extra). "
                + "Say which one and Chunks will \(verb.phrase.lowercased()) it."
        case .unreachable(let candidate):
            // Names the window it found, says Chunks cannot reach it, and does not claim to know why.
            // An earlier draft said "on another Space", which the first run proved twice wrong: it
            // labelled Finder's desktop — drawn on every Space — and the window the user was typing
            // into as being elsewhere. The alternative, offering the card anyway, is the lie this case
            // exists to prevent: the act would resolve to no element and report a failure after he had
            // already answered yes.
            let what = candidate.title.isEmpty ? candidate.appName
                : "\"\(candidate.title)\" in \(candidate.appName)"
            return "Chunks can see \(what), but it is not a window Chunks can reach from here — it is "
                + "on another Space, hidden, or minimised. Bring it into view and ask again."
        case .notAWindow:
            return "That is the desktop, not a window Chunks can \(verb.phrase.lowercased()). "
                + "Name a window in an app instead."
        }
    }
}
