import Foundation

/// Where a window should go, decided in **Accessibility's own coordinate space**.
///
/// This is the slice `AGENTS.md` deferred on purpose. Moving a window is the one act in this app that
/// has to write a rectangle, and invariant 1's whole history is rectangles written in the wrong space:
/// `CGDisplayBounds` is top-left, `NSScreen.frame` is bottom-left, `CGDisplayPixelsWide` returns
/// *points* while a screenshot is *pixels*, and every one of those mistakes produces a plausible number
/// instead of an error. So the rule here is that **nothing in this file converts anything.** A display
/// arrives already in global top-left logical points — the space `AXUIElementSetAttributeValue` is
/// called in and the space `WindowDriver.frame(of:)` reads back — and every number produced here is a
/// fraction of that. There is exactly one place in the app where the flip happens, it is in the shell
/// that builds a `DisplaySurface`, and it is commented.
///
/// The second rule is the one a model cannot break: **a tag names a place, it never states one.**
/// `[DO:move_window:Safari|Inbox|left]` is a thing a person says and a thing that cannot be wrong by
/// arithmetic. `[DO:move_window:Safari|Inbox|400,220]` is refused at parse, because a coordinate a
/// vision model invents for a rectangle it is guessing at is the same class of guess that put a press
/// on the wrong row of a chat list — and unlike a press, a wrong window position is something he then
/// has to fix by hand.
public enum WindowPlacementPolicy {

    /// One display, in global top-left logical points, with the menu bar and the Dock already taken
    /// out of the usable half.
    public struct Surface: Equatable, Sendable {
        /// 1-based, because he counts displays the way he counts them out loud: "the second one".
        /// Assigned after the list is ordered main-first, which is why it is not `let`.
        public var index: Int
        public let name: String
        public let isMain: Bool
        /// The whole display, exactly as `CGDisplayBounds` reports it.
        public let globalFrame: CGRect
        /// The part a window may be put in: the same space, inset for the menu bar and the Dock.
        public let usableFrame: CGRect

        public init(index: Int, name: String, isMain: Bool,
                    globalFrame: CGRect, usableFrame: CGRect) {
            self.index = index
            self.name = name
            self.isMain = isMain
            self.globalFrame = globalFrame
            self.usableFrame = usableFrame
        }
    }

    /// A place a person names.
    public enum Slot: String, Equatable, Sendable, CaseIterable {
        case left, right, top, bottom
        case topLeft = "top-left", topRight = "top-right"
        case bottomLeft = "bottom-left", bottomRight = "bottom-right"
        case full
        /// Keep the window's own size and centre it — the one slot that does not resize.
        case centre

        /// The words a card uses, and the words the prompt teaches.
        public var phrase: String {
            switch self {
            case .left: return "the left half"
            case .right: return "the right half"
            case .top: return "the top half"
            case .bottom: return "the bottom half"
            case .topLeft: return "the top-left corner"
            case .topRight: return "the top-right corner"
            case .bottomLeft: return "the bottom-left corner"
            case .bottomRight: return "the bottom-right corner"
            case .full: return "the whole display"
            case .centre: return "the middle, the same size"
            }
        }

        /// Whether this slot resizes the window. `centre` deliberately does not: "move it to the middle"
        /// is about where, and a slot that also made his editor full-screen would be a second act he
        /// never asked for.
        public var resizes: Bool { self != .centre }
    }

    /// What the tag asked for: a place on the window's own display, or a different display.
    public enum Target: Equatable, Sendable {
        case slot(Slot)
        /// 1-based, as he counts.
        case display(index: Int)
        case main
        case second
    }

    /// The smallest window this will produce.
    ///
    /// A quarter of a small display, or a window the app itself refuses to shrink, can compute to a
    /// rectangle no one can type into. Refusing is better than placing it: `AXSize` writes are not
    /// guaranteed anyway, so a size the app rejects would leave a card claiming a position the window
    /// never took.
    public static let minWindowSize = CGSize(width: 320, height: 200)

    // MARK: - Parsing

    /// Parse the `|where` half of the tag.
    ///
    /// Three families of input are refused rather than guessed at. **Any coordinate** — a comma, a
    /// digit-and-comma pair, or an `x=` — because that is the model stating a place it invented. Any
    /// fraction like `0.5`, which is the same invention in a different dress. And any word we do not
    /// have, which is refused so the answer is a refusal that lists the vocabulary rather than a window
    /// moved somewhere the model meant by "tidy".
    public static func parseTarget(_ raw: String) -> Target? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed.count <= 40 else { return nil }
        // Spoken words arrive with spaces where the written vocabulary has hyphens — "top left",
        // "left half" — and both mean one place. Folding them here means the table below holds one
        // spelling per slot instead of three.
        let text = trimmed.replacingOccurrences(of: " ", with: "-")
        // A comma is the signature of a pixel pair, and a decimal point that of a fraction. Neither is
        // ever part of a name in this vocabulary, so they are refused before any matching, not after.
        guard !text.contains(","), !text.contains("."), !text.contains("x=") else { return nil }

        if text.hasPrefix("display=") || text.hasPrefix("screen=") {
            let digits = text.split(separator: "=").last.map(String.init) ?? ""
            guard let number = Int(digits), number >= 1, number <= 8 else { return nil }
            return .display(index: number)
        }
        switch text {
        case "main", "primary", "first": return .main
        case "second", "other", "external", "two": return .second
        case "left", "l", "lefthalf", "left-half": return .slot(.left)
        case "right", "r", "righthalf", "right-half": return .slot(.right)
        case "top", "upper", "tophalf", "top-half": return .slot(.top)
        case "bottom", "lower", "bottomhalf", "bottom-half": return .slot(.bottom)
        case "topleft", "top-left", "upperleft", "top-left-corner": return .slot(.topLeft)
        case "topright", "top-right", "upperright", "top-right-corner": return .slot(.topRight)
        case "bottomleft", "bottom-left", "lowerleft", "bottom-left-corner": return .slot(.bottomLeft)
        case "bottomright", "bottom-right", "lowerright", "bottom-right-corner": return .slot(.bottomRight)
        case "full", "fullscreen", "full-screen", "maximise", "maximize", "whole": return .slot(.full)
        case "centre", "center", "middle", "centred", "centered": return .slot(.centre)
        default: return nil
        }
    }

    /// The `where` a refusal quotes back, so a wrong word teaches instead of dead-ending.
    public static var vocabulary: String {
        "left, right, top, bottom, top-left, top-right, bottom-left, bottom-right, full, centre, "
            + "main, second, or display=2"
    }

    // MARK: - Deciding

    /// What a placement sentence resolves to: one rectangle, or a reason it will not happen.
    ///
    /// This is the whole decision, hoisted out of the shell so `--probe-geometry` can print the frame a
    /// move *would* make without making it — the same shape every other risky verb in this app uses,
    /// and the reason is the one this slice has to respect: a rectangle is the easiest thing in the app
    /// to get subtly wrong, and a wrong rectangle is not an error, it is a window in a place he then has
    /// to move by hand.
    public enum Decision: Equatable, Sendable {
        case place(candidate: WindowAct.Candidate, surface: Surface, frame: CGRect)
        case refused(String)

        public var frame: CGRect? {
            if case .place(_, _, let rect) = self { return rect }
            return nil
        }
    }

    /// Decide, from the window list and the display list, both of which the caller reads.
    ///
    /// `resolution` comes from `WindowAct`'s own rules — every distinctive word he said must answer the
    /// title, two equal answers are refused *with both names listed*, and position never chooses. A move
    /// is not permanent, so the choice rules are focus's rules rather than close's, and that is what
    /// `resolvePlacement` says by passing `.focus`.
    public static func decide(target: Target, app: String, title: String?,
                              resolution: WindowAct.Resolution,
                              surfaces: [Surface]) -> Decision {
        switch resolution {
        case .one(let candidate):
            let current = currentSurface(of: candidate.frame, among: surfaces)
            guard let surface = surface(for: target, among: surfaces, current: current) else {
                return .refused(refusal(target: target, surfaces: surfaces))
            }
            guard let rect = frame(for: target, on: surface,
                                   currentSize: candidate.frame.size) else {
                return .refused("The display “\(surface.name)” is too small to place a window on it.")
            }
            return .place(candidate: candidate, surface: surface, frame: rect)
        case .ambiguous(let many):
            let names = many.prefix(4).map { "\"\($0.displayName)\"" }.joined(separator: ", ")
            let extra = many.count > 4 ? ", and \(many.count - 4) more" : ""
            return .refused("\(many.count) windows in \(app) could be the one to move: \(names)\(extra). "
                + "Say which one.")
        case .none:
            return .refused("Chunks found no window called \"\(title ?? "")\" in \(app) to move.")
        case .appNotRunning(let name):
            return .refused("\(name) is not running, so there is no window to move.")
        case .unreachable(let candidate):
            // The same sentence a close or a minimise gets, because it is the same fact: there is no
            // element to write a new frame to. Chunks can name the window and cannot touch it.
            return .refused(WindowAct.refusal(verb: .focus, app: app, title: title,
                                              resolution: .unreachable(candidate)))
        case .notAWindow(let candidate):
            // Refused here as well as in the verbs, because a move is the act that would really do it:
            // writing a new frame to Finder's desktop disturbs the layout of his icons and tidies
            // nothing. The probe found this on its first run by volunteering to place the desktop in
            // the left half.
            return .refused(WindowAct.refusal(verb: .focus, app: app, title: title,
                                              resolution: .notAWindow(candidate)))
        }
    }

    /// Which display a window is on now, by the words he used.
    ///
    /// Falls back to the main display when the number is out of range, and returns nil when there is no
    /// second display at all — which is a refusal, not a silent move to the one screen he has.
    public static func surface(for target: Target, among surfaces: [Surface],
                               current: Surface?) -> Surface? {
        switch target {
        case .slot:
            return current
        case .main:
            return surfaces.first(where: { $0.isMain }) ?? surfaces.first
        case .second:
            guard surfaces.count > 1 else { return nil }
            return surfaces.first(where: { !$0.isMain }) ?? surfaces.dropFirst().first
        case .display(let index):
            return surfaces.first(where: { $0.index == index })
        }
    }

    /// The rectangle the window should end up in, in global top-left logical points.
    ///
    /// `currentSize` is what the window is now, because `centre` and every cross-display move keep it.
    /// Returns nil when no honest rectangle exists: a display too small for the minimum window, or a
    /// usable frame the maths cannot fit anything into.
    public static func frame(for target: Target, on surface: Surface,
                             currentSize: CGSize) -> CGRect? {
        let usable = surface.usableFrame
        guard usable.width >= minWindowSize.width, usable.height >= minWindowSize.height
        else { return nil }

        let slot: Slot?
        switch target {
        case .slot(let named): slot = named
        case .display, .main, .second: slot = nil
        }

        // A display change keeps the size and centres it, shrunk only if the new screen is smaller.
        // Moving a 1800-wide window onto a 1280 display without shrinking it puts half of it off the
        // edge, which reads as the move having failed.
        guard let slot else {
            let size = clamped(currentSize, into: usable)
            return CGRect(x: usable.minX + (usable.width - size.width) / 2,
                          y: usable.minY + (usable.height - size.height) / 2,
                          width: size.width, height: size.height)
        }

        switch slot {
        case .centre:
            let size = clamped(currentSize, into: usable)
            return CGRect(x: usable.minX + (usable.width - size.width) / 2,
                          y: usable.minY + (usable.height - size.height) / 2,
                          width: size.width, height: size.height)
        case .full:
            return usable
        case .left:
            return CGRect(x: usable.minX, y: usable.minY,
                          width: usable.width / 2, height: usable.height)
        case .right:
            return CGRect(x: usable.midX, y: usable.minY,
                          width: usable.width / 2, height: usable.height)
        case .top:
            return CGRect(x: usable.minX, y: usable.minY,
                          width: usable.width, height: usable.height / 2)
        case .bottom:
            return CGRect(x: usable.minX, y: usable.midY,
                          width: usable.width, height: usable.height / 2)
        case .topLeft:
            return CGRect(x: usable.minX, y: usable.minY,
                          width: usable.width / 2, height: usable.height / 2)
        case .topRight:
            return CGRect(x: usable.midX, y: usable.minY,
                          width: usable.width / 2, height: usable.height / 2)
        case .bottomLeft:
            return CGRect(x: usable.minX, y: usable.midY,
                          width: usable.width / 2, height: usable.height / 2)
        case .bottomRight:
            return CGRect(x: usable.midX, y: usable.midY,
                          width: usable.width / 2, height: usable.height / 2)
        }
    }

    /// The frame a window is in right now, as a surface — used by the probe and by the refusal that
    /// says where it actually went.
    public static func currentSurface(of frame: CGRect, among surfaces: [Surface]) -> Surface? {
        surfaces.max { left, right in
            overlap(frame, left.globalFrame) < overlap(frame, right.globalFrame)
        }
    }

    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let joined = a.intersection(b)
        return joined.isNull ? 0 : joined.width * joined.height
    }

    /// Fit a size inside a rectangle, keeping it at least `minWindowSize`.
    private static func clamped(_ size: CGSize, into rect: CGRect) -> CGSize {
        CGSize(width: min(max(size.width, minWindowSize.width), rect.width),
               height: min(max(size.height, minWindowSize.height), rect.height))
    }

    // MARK: - Saying

    /// The card's question. A move is reversible and loses nothing, so this is asked about only when
    /// asking is on — and it still names the window, because "Move it to the left half?" is not a
    /// question about a window he can check.
    public static func question(target: Target, candidate: WindowAct.Candidate) -> String {
        let what = candidate.title.isEmpty ||
            candidate.title.caseInsensitiveCompare(candidate.appName) == .orderedSame
            ? candidate.appName : "\"\(candidate.title)\" in \(candidate.appName)"
        return "Move \(what) to \(phrase(for: target))?"
    }

    /// The spoken report, with the place in it: with asking off this is the only record that anything
    /// happened, and "Moved the window." does not tell him where to look.
    public static func outcomeLine(target: Target, candidate: WindowAct.Candidate,
                                   succeeded: Bool) -> String {
        let what = candidate.title.isEmpty ||
            candidate.title.caseInsensitiveCompare(candidate.appName) == .orderedSame
            ? candidate.appName : candidate.title
        return succeeded
            ? "Moved \(what) to \(phrase(for: target))."
            : "\(candidate.appName) did not move \(what) to \(phrase(for: target))."
    }

    public static func phrase(for target: Target) -> String {
        switch target {
        case .slot(let slot): return slot.phrase
        case .display(let index): return "display \(index)"
        case .main: return "the main display"
        case .second: return "the second display"
        }
    }

    /// Why the move did not happen, in his words.
    public static func refusal(target: Target, surfaces: [Surface]) -> String {
        switch target {
        case .display(let index):
            return "There is no display \(index) on this Mac — Chunks can see "
                + "\(surfaces.count) screen\(surfaces.count == 1 ? "" : "s"). "
                + "Say \(vocabulary)."
        case .second:
            return "There is only one display plugged in, so there is no second one to move it to."
        case .main:
            return "Chunks cannot see a main display to move it to."
        case .slot:
            return "The display that window is on is too small to place a window on it."
        }
    }
}
